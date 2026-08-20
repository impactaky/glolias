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

    try cfg.replaceCredential(allocator, name, environment);
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
    try preflightConfig(allocator, &cfg);
    try cfg.updateCredentialBindings(allocator, credential, alias_names, adding);
    try config.save(allocator, &cfg);
}

pub fn remove(allocator: std.mem.Allocator, name: []const u8) !void {
    try credential_name.validate(name);
    var cfg = try config.load(allocator);
    defer cfg.deinit(allocator);
    if (!cfg.credentials.contains(name)) return error.CredentialNotFound;
    try preflightConfig(allocator, &cfg);
    const path = try paths.credentialRunnerPath(allocator, cfg.credentials_dir, name);
    defer allocator.free(path);
    const runner_exists = switch (try sys.pathKind(allocator, path)) {
        .missing => false,
        .regular_file => true,
        else => return error.RunnerMissingOrUnsafe,
    };
    try cfg.removeCredential(allocator, name);
    try config.save(allocator, &cfg);
    if (runner_exists) try credential_runner.remove(allocator, path);
}

fn preflightConfig(allocator: std.mem.Allocator, cfg: *const config.Config) !void {
    if (std.fs.path.dirname(cfg.config_path)) |parent| try sys.mkdirp(parent);
    switch (try sys.pathKind(allocator, cfg.config_path)) {
        .missing, .regular_file => {},
        else => return error.UnsafeConfigTarget,
    }
}
