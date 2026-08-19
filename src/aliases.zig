const std = @import("std");
const alias_name = @import("alias_name.zig");
const config = @import("config.zig");
const credential_name = @import("credential_name.zig");
const credential_runner = @import("credential_runner.zig");
const paths = @import("paths.zig");
const sys = @import("sys.zig");

pub const RemoveResult = union(enum) {
    removed,
    not_found,
    load_failed: anyerror,
    directory_failed: DirectoryFailure,
};

pub const CredentialSyncFailure = struct { name: []const u8, err: anyerror };

pub const SyncResult = union(enum) {
    synced,
    load_failed: anyerror,
    directory_failed: DirectoryFailure,
    credential_failed: CredentialSyncFailure,
};

pub const AddResult = union(enum) { added, directory_failed: DirectoryFailure };
pub const DirectoryTarget = enum { config, shims, credentials };
pub const DirectoryFailure = struct { target: DirectoryTarget, err: sys.CreateDirPathError };

pub fn add(
    allocator: std.mem.Allocator,
    name: []const u8,
    tokens: []const []const u8,
    credential_names: []const []const u8,
    force: bool,
) !AddResult {
    try alias_name.validate(name);
    if (tokens.len == 0) return error.EmptyTokens;
    try validateCredentialArguments(credential_names);

    var cfg = try config.loadOrInit(allocator);
    defer cfg.deinit(allocator);
    for (credential_names) |credential| {
        if (!cfg.credentials.contains(credential)) return error.CredentialNotFound;
    }
    if (cfg.aliases.get(name)) |existing| {
        if (!sameStrings(existing.tokens, tokens) and !force) return error.AliasExistsWithDifferentTokens;
        if (sameStrings(existing.tokens, tokens) and sameStrings(existing.credential_names, credential_names)) {
            if (try preflightMutationPaths(allocator, &cfg, name)) |failure| return .{ .directory_failed = failure };
            if (try ensureShim(allocator, cfg.shims_dir, name)) |failure| return .{ .directory_failed = failure };
            return .added;
        }
    }

    if (try preflightMutationPaths(allocator, &cfg, name)) |failure| return .{ .directory_failed = failure };
    {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        var owned_alias = try config.cloneAlias(allocator, tokens, credential_names);
        errdefer config.deinitAlias(allocator, &owned_alias);
        if (cfg.aliases.fetchOrderedRemove(name)) |old| {
            allocator.free(old.key);
            var old_alias = old.value;
            config.deinitAlias(allocator, &old_alias);
        }
        try cfg.aliases.put(allocator, owned_name, owned_alias);
    }
    if (try saveConfig(allocator, &cfg)) |failure| return .{ .directory_failed = failure };
    if (try ensureShim(allocator, cfg.shims_dir, name)) |failure| return .{ .directory_failed = failure };
    return .added;
}

pub fn remove(allocator: std.mem.Allocator, name: []const u8) !RemoveResult {
    var cfg = config.load(allocator) catch |err| return .{ .load_failed = err };
    defer cfg.deinit(allocator);
    if (!cfg.aliases.contains(name)) return .not_found;
    if (try preflightMutationPaths(allocator, &cfg, name)) |failure| return .{ .directory_failed = failure };
    const old = cfg.aliases.fetchOrderedRemove(name).?;
    allocator.free(old.key);
    var old_alias = old.value;
    config.deinitAlias(allocator, &old_alias);
    if (try saveConfig(allocator, &cfg)) |failure| return .{ .directory_failed = failure };
    const link_path = try std.fs.path.join(allocator, &.{ cfg.shims_dir, name });
    defer allocator.free(link_path);
    sys.unlinkPath(allocator, link_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    return .removed;
}

pub fn sync(allocator: std.mem.Allocator) !SyncResult {
    var cfg = config.load(allocator) catch |err| return .{ .load_failed = err };
    defer cfg.deinit(allocator);
    if (try ensureShimsDir(cfg.shims_dir)) |failure| return .{ .directory_failed = failure };
    var aliases = cfg.aliases.iterator();
    while (aliases.next()) |entry| {
        if (try ensureShim(allocator, cfg.shims_dir, entry.key_ptr.*)) |failure| return .{ .directory_failed = failure };
    }
    const symlinks = try sys.listSymlinks(allocator, cfg.shims_dir);
    defer {
        for (symlinks) |entry_name| allocator.free(entry_name);
        allocator.free(symlinks);
    }
    for (symlinks) |entry_name| {
        if (!cfg.aliases.contains(entry_name)) {
            const path = try std.fs.path.join(allocator, &.{ cfg.shims_dir, entry_name });
            defer allocator.free(path);
            try sys.unlinkPath(allocator, path);
        }
    }

    const credential_keys = try config.sortedCredentialKeys(allocator, &cfg);
    defer allocator.free(credential_keys);
    for (credential_keys) |name| {
        const path = try paths.credentialRunnerPath(allocator, cfg.credentials_dir, name);
        defer allocator.free(path);
        credential_runner.refresh(allocator, path, name, cfg.credentials.get(name).?.env_name) catch |err| {
            return .{ .credential_failed = .{ .name = try allocator.dupe(u8, name), .err = err } };
        };
    }
    return .synced;
}

fn validateCredentialArguments(names: []const []const u8) !void {
    for (names, 0..) |name, i| {
        try credential_name.validate(name);
        for (names[0..i]) |prior| if (std.mem.eql(u8, prior, name)) return error.DuplicateCredentialBinding;
    }
}

fn preflightMutationPaths(allocator: std.mem.Allocator, cfg: *const config.Config, alias: []const u8) !?DirectoryFailure {
    if (std.fs.path.dirname(cfg.config_path)) |parent| {
        sys.mkdirp(parent) catch |err| return .{ .target = .config, .err = err };
    }
    switch (try sys.pathKind(allocator, cfg.config_path)) {
        .missing, .regular_file => {},
        else => return error.UnsafeConfigTarget,
    }
    if (try ensureShimsDir(cfg.shims_dir)) |failure| return failure;
    const link_path = try std.fs.path.join(allocator, &.{ cfg.shims_dir, alias });
    defer allocator.free(link_path);
    switch (try sys.pathKind(allocator, link_path)) {
        .missing, .symlink => {},
        else => return error.ShimTargetBlocked,
    }
    return null;
}

fn ensureShim(allocator: std.mem.Allocator, shims_dir: []const u8, name: []const u8) !?DirectoryFailure {
    if (try ensureShimsDir(shims_dir)) |failure| return failure;
    const target = try paths.selfExePath(allocator);
    defer allocator.free(target);
    const link_path = try std.fs.path.join(allocator, &.{ shims_dir, name });
    defer allocator.free(link_path);
    switch (try sys.pathKind(allocator, link_path)) {
        .missing => {},
        .symlink => try sys.unlinkPath(allocator, link_path),
        else => return error.ShimTargetBlocked,
    }
    try sys.symlinkPath(allocator, target, link_path);
    return null;
}

fn saveConfig(allocator: std.mem.Allocator, cfg: *const config.Config) !?DirectoryFailure {
    config.save(allocator, cfg) catch |err| {
        if (sys.isCreateDirPathError(err)) return .{ .target = .config, .err = @errorCast(err) };
        return err;
    };
    return null;
}

fn ensureShimsDir(shims_dir: []const u8) !?DirectoryFailure {
    sys.mkdirp(shims_dir) catch |err| return .{ .target = .shims, .err = err };
    return null;
}

fn sameStrings(lhs: []const []const u8, rhs: []const []const u8) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| if (!std.mem.eql(u8, left, right)) return false;
    return true;
}

test "add rejects an Alias without command tokens before loading Config" {
    try std.testing.expectError(error.EmptyTokens, add(std.testing.allocator, "empty", &.{}, &.{}, false));
}
