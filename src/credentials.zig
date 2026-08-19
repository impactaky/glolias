const std = @import("std");
const config = @import("config.zig");
const credential_name = @import("credential_name.zig");
const credential_runner = @import("credential_runner.zig");
const env_name = @import("env_name.zig");
const paths = @import("paths.zig");
const sys = @import("sys.zig");

pub fn preflightSet(allocator: std.mem.Allocator, name: []const u8, environment: []const u8, force: bool) !void {
    try credential_name.validate(name);
    try env_name.validate(environment);
    var cfg = try config.loadOrInit(allocator);
    defer cfg.deinit(allocator);
    if (cfg.credentials.get(name)) |existing| {
        if (!std.mem.eql(u8, existing.env_name, environment) and !force) return error.CredentialEnvironmentConflict;
    }
    try preflightConfig(allocator, &cfg);
    switch (try sys.pathKind(allocator, cfg.credentials_dir)) {
        .missing => try sys.mkdirp(cfg.credentials_dir),
        .directory => {},
        else => return error.UnsafeCredentialsDirectory,
    }
    const runner_path = try paths.credentialRunnerPath(allocator, cfg.credentials_dir, name);
    defer allocator.free(runner_path);
    switch (try sys.pathKind(allocator, runner_path)) {
        .missing, .regular_file => {},
        else => return error.UnsafeRunnerTarget,
    }
}

pub fn set(
    allocator: std.mem.Allocator,
    name: []const u8,
    environment: []const u8,
    secret: []const u8,
    force: bool,
) !void {
    try preflightSet(allocator, name, environment, force);
    var cfg = try config.loadOrInit(allocator);
    defer cfg.deinit(allocator);
    const metadata_unchanged = if (cfg.credentials.get(name)) |existing|
        std.mem.eql(u8, existing.env_name, environment)
    else
        false;
    const runner_path = try paths.credentialRunnerPath(allocator, cfg.credentials_dir, name);
    defer allocator.free(runner_path);
    try credential_runner.create(allocator, runner_path, name, environment, secret);
    if (metadata_unchanged) return;

    if (cfg.credentials.fetchOrderedRemove(name)) |old| {
        allocator.free(old.key);
        allocator.free(old.value.env_name);
    }
    {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_env = try allocator.dupe(u8, environment);
        errdefer allocator.free(owned_env);
        try cfg.credentials.put(allocator, owned_name, .{ .env_name = owned_env });
    }
    try config.save(allocator, &cfg);
}

pub fn attach(allocator: std.mem.Allocator, credential: []const u8, alias_names: []const []const u8) !void {
    try updateBindings(allocator, credential, alias_names, true);
}

pub fn detach(allocator: std.mem.Allocator, credential: []const u8, alias_names: []const []const u8) !void {
    try updateBindings(allocator, credential, alias_names, false);
}

fn updateBindings(
    allocator: std.mem.Allocator,
    credential: []const u8,
    alias_names: []const []const u8,
    adding: bool,
) !void {
    try credential_name.validate(credential);
    if (alias_names.len == 0) return error.MissingAlias;
    var cfg = try config.load(allocator);
    defer cfg.deinit(allocator);
    if (!cfg.credentials.contains(credential)) return error.CredentialNotFound;
    for (alias_names, 0..) |alias_name, i| {
        if (cfg.aliases.get(alias_name) == null) return error.AliasNotFound;
        for (alias_names[0..i]) |prior| if (std.mem.eql(u8, prior, alias_name)) return error.DuplicateAliasArgument;
    }
    try preflightConfig(allocator, &cfg);
    for (alias_names) |alias_name| {
        const alias = cfg.aliases.getPtr(alias_name).?;
        const index = indexOf(alias.credential_names, credential);
        if (adding and index == null) {
            const updated = try allocator.alloc([]const u8, alias.credential_names.len + 1);
            for (alias.credential_names, 0..) |value, i| updated[i] = value;
            updated[updated.len - 1] = try allocator.dupe(u8, credential);
            allocator.free(alias.credential_names);
            alias.credential_names = updated;
        } else if (!adding and index != null) {
            const removed = index.?;
            const updated = try allocator.alloc([]const u8, alias.credential_names.len - 1);
            var output: usize = 0;
            for (alias.credential_names, 0..) |value, i| {
                if (i == removed) continue;
                updated[output] = value;
                output += 1;
            }
            allocator.free(alias.credential_names[removed]);
            allocator.free(alias.credential_names);
            alias.credential_names = updated;
        }
    }
    try config.save(allocator, &cfg);
}

pub fn remove(allocator: std.mem.Allocator, name: []const u8) !void {
    try credential_name.validate(name);
    var cfg = try config.load(allocator);
    defer cfg.deinit(allocator);
    if (!cfg.credentials.contains(name)) return error.CredentialNotFound;
    var aliases = cfg.aliases.iterator();
    while (aliases.next()) |entry| {
        if (indexOf(entry.value_ptr.credential_names, name) != null) return error.CredentialInUse;
    }
    try preflightConfig(allocator, &cfg);
    const path = try paths.credentialRunnerPath(allocator, cfg.credentials_dir, name);
    defer allocator.free(path);
    const runner_exists = switch (try sys.pathKind(allocator, path)) {
        .missing => false,
        .regular_file => true,
        else => return error.RunnerMissingOrUnsafe,
    };
    const old = cfg.credentials.fetchOrderedRemove(name).?;
    allocator.free(old.key);
    allocator.free(old.value.env_name);
    try config.save(allocator, &cfg);
    if (runner_exists) try credential_runner.remove(allocator, path);
}

pub fn boundAliases(allocator: std.mem.Allocator, cfg: *const config.Config, credential: []const u8) ![][]const u8 {
    var names = std.ArrayList([]const u8).empty;
    errdefer names.deinit(allocator);
    var map = cfg.aliases;
    var aliases = map.iterator();
    while (aliases.next()) |entry| {
        if (indexOf(entry.value_ptr.credential_names, credential) != null) try names.append(allocator, entry.key_ptr.*);
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    return names.toOwnedSlice(allocator);
}

fn preflightConfig(allocator: std.mem.Allocator, cfg: *const config.Config) !void {
    if (std.fs.path.dirname(cfg.config_path)) |parent| try sys.mkdirp(parent);
    switch (try sys.pathKind(allocator, cfg.config_path)) {
        .missing, .regular_file => {},
        else => return error.UnsafeConfigTarget,
    }
}

fn indexOf(values: []const []const u8, needle: []const u8) ?usize {
    for (values, 0..) |value, i| if (std.mem.eql(u8, value, needle)) return i;
    return null;
}

fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}
