const std = @import("std");

const alias_name = @import("alias_name.zig");
const config = @import("config.zig");
const paths = @import("paths.zig");
const sys = @import("sys.zig");

pub const RemoveResult = union(enum) {
    removed,
    not_found,
    load_failed: anyerror,
    directory_failed: DirectoryFailure,
};

pub const SyncResult = union(enum) {
    synced,
    load_failed: anyerror,
    directory_failed: DirectoryFailure,
};

pub const AddResult = union(enum) {
    added,
    directory_failed: DirectoryFailure,
};

pub const DirectoryTarget = enum { config, shims };

pub const DirectoryFailure = struct {
    target: DirectoryTarget,
    err: sys.CreateDirPathError,
};

pub fn add(
    allocator: std.mem.Allocator,
    name: []const u8,
    tokens: []const []const u8,
    force: bool,
) !AddResult {
    try alias_name.validate(name);
    if (tokens.len == 0) return error.EmptyTokens;

    var cfg = try config.loadOrInit(allocator);
    defer cfg.deinit(allocator);

    if (cfg.aliases.get(name)) |existing| {
        if (!sameTokens(existing, tokens)) {
            if (!force) return error.AliasExistsWithDifferentTokens;
            if (cfg.aliases.fetchOrderedRemove(name)) |old| {
                allocator.free(old.key);
                freeTokens(allocator, old.value);
            }
        } else {
            if (try saveConfig(allocator, &cfg)) |failure| return .{ .directory_failed = failure };
            if (try ensureShim(allocator, cfg.shims_dir, name)) |failure| return .{ .directory_failed = failure };
            return .added;
        }
    }

    try putOwnedAlias(allocator, &cfg.aliases, name, tokens);
    if (try saveConfig(allocator, &cfg)) |failure| return .{ .directory_failed = failure };
    if (try ensureShim(allocator, cfg.shims_dir, name)) |failure| return .{ .directory_failed = failure };
    return .added;
}

pub fn remove(allocator: std.mem.Allocator, name: []const u8) !RemoveResult {
    var cfg = config.load(allocator) catch |err| return .{ .load_failed = err };
    defer cfg.deinit(allocator);

    const old = cfg.aliases.fetchOrderedRemove(name) orelse return .not_found;
    allocator.free(old.key);
    freeTokens(allocator, old.value);

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

    var it = cfg.aliases.iterator();
    while (it.next()) |entry| {
        if (try ensureShim(allocator, cfg.shims_dir, entry.key_ptr.*)) |failure| {
            return .{ .directory_failed = failure };
        }
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
    return .synced;
}

fn ensureShim(allocator: std.mem.Allocator, shims_dir: []const u8, name: []const u8) !?DirectoryFailure {
    if (try ensureShimsDir(shims_dir)) |failure| return failure;
    const target = try paths.selfExePath(allocator);
    defer allocator.free(target);

    const link_path = try std.fs.path.join(allocator, &.{ shims_dir, name });
    defer allocator.free(link_path);

    sys.unlinkPath(allocator, link_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try sys.symlinkPath(allocator, target, link_path);
    return null;
}

fn saveConfig(allocator: std.mem.Allocator, cfg: *const config.Config) !?DirectoryFailure {
    config.save(allocator, cfg) catch |err| {
        if (sys.isCreateDirPathError(err)) {
            const directory_err: sys.CreateDirPathError = @errorCast(err);
            return .{ .target = .config, .err = directory_err };
        }
        return err;
    };
    return null;
}

fn ensureShimsDir(shims_dir: []const u8) !?DirectoryFailure {
    sys.mkdirp(shims_dir) catch |err| return .{ .target = .shims, .err = err };
    return null;
}

fn putOwnedAlias(
    allocator: std.mem.Allocator,
    alias_map: *config.AliasMap,
    name: []const u8,
    tokens: []const []const u8,
) !void {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_tokens = try copyTokens(allocator, tokens);
    errdefer freeTokens(allocator, owned_tokens);

    try alias_map.put(allocator, owned_name, owned_tokens);
}

fn copyTokens(allocator: std.mem.Allocator, tokens: []const []const u8) ![][]const u8 {
    var out = try allocator.alloc([]const u8, tokens.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |token| allocator.free(token);
        allocator.free(out);
    }
    for (tokens, 0..) |token, i| {
        out[i] = try allocator.dupe(u8, token);
        initialized += 1;
    }
    return out;
}

fn freeTokens(allocator: std.mem.Allocator, tokens: [][]const u8) void {
    for (tokens) |token| allocator.free(token);
    allocator.free(tokens);
}

fn sameTokens(lhs: []const []const u8, rhs: []const []const u8) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |l, r| {
        if (!std.mem.eql(u8, l, r)) return false;
    }
    return true;
}

test "add rejects an Alias without command tokens before loading Config" {
    try std.testing.expectError(
        error.EmptyTokens,
        add(std.testing.allocator, "empty", &.{}, false),
    );
}
