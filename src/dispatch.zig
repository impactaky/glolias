const std = @import("std");
const config = @import("config.zig");
const credential_runner = @import("credential_runner.zig");
const main = @import("main.zig");
const real_command = @import("real_command.zig");
const sys = @import("sys.zig");

const guard_env = "GLOLIAS_GUARD";

pub fn run(allocator: std.mem.Allocator, name: []const u8, rest_args: []const []const u8) !void {
    var cfg = config.load(allocator) catch |err| main.fail("glolias: unable to load config: {s}\n", .{@errorName(err)}, 127);
    defer cfg.deinit(allocator);
    const alias = cfg.aliases.getPtr(name) orelse main.fail("glolias: no alias '{s}' - run 'glolias sync'\n", .{name}, 127);
    if (alias.tokens.len == 0) main.fail("glolias: alias '{s}' has no command\n", .{name}, 127);

    const guard_value = sys.getenvOwned(allocator, guard_env) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(guard_value);

    if (alias.credential_names.len != 0) {
        config.validateAliasEnvironments(&cfg, alias) catch |err| failCredential(name, err);
        const ready = credential_runner.consumeReady(allocator, &cfg, name, alias) catch |err| failCredential(name, err);
        if (!ready) {
            const active = if (guardContains(guard_value, name))
                credential_runner.hasActiveAuth(allocator, &cfg, name, alias) catch |err| failCredential(name, err)
            else
                false;
            if (active) return execReal(allocator, &cfg, name, rest_args);
            credential_runner.beginChain(allocator, &cfg, name, alias, rest_args) catch |err| failCredential(name, err);
        }
    } else if (guardContains(guard_value, name)) {
        return execReal(allocator, &cfg, name, rest_args);
    }

    const new_guard = try appendGuard(allocator, guard_value, name);
    defer allocator.free(new_guard);
    try sys.setenvOwned(allocator, guard_env, new_guard);
    const argv = try makePrependedArgv(allocator, alias.tokens, rest_args);
    defer freeArgv(allocator, argv);
    sys.execvpFile(std.heap.page_allocator, alias.tokens[0], argv);
}

fn execReal(allocator: std.mem.Allocator, cfg: *const config.Config, name: []const u8, rest_args: []const []const u8) noreturn {
    const real = real_command.resolve(allocator, name, cfg.shims_dir) catch |err| {
        main.fail("glolias: {s}: command not found ({s})\n", .{ name, @errorName(err) }, 127);
    };
    const argv = makeArgv(allocator, name, rest_args) catch main.fail("glolias: {s}: out of memory\n", .{name}, 127);
    sys.execvPath(std.heap.page_allocator, real, argv);
}

fn failCredential(alias: []const u8, err: anyerror) noreturn {
    main.fail("glolias: credential injection for alias '{s}' refused: {s}\n", .{ alias, @errorName(err) }, 127);
}

pub fn guardContains(guard: []const u8, name: []const u8) bool {
    var parts = std.mem.splitScalar(u8, guard, ':');
    while (parts.next()) |part| if (std.mem.eql(u8, part, name)) return true;
    return false;
}

pub fn appendGuard(allocator: std.mem.Allocator, guard: []const u8, name: []const u8) ![]const u8 {
    if (guardContains(guard, name)) return allocator.dupe(u8, guard);
    if (guard.len == 0) return allocator.dupe(u8, name);
    return std.mem.concat(allocator, u8, &.{ guard, ":", name });
}

fn makeArgv(allocator: std.mem.Allocator, arg0: []const u8, rest: []const []const u8) ![][]const u8 {
    var argv = try allocator.alloc([]const u8, rest.len + 1);
    argv[0] = try allocator.dupe(u8, arg0);
    for (rest, 0..) |arg, i| argv[i + 1] = try allocator.dupe(u8, arg);
    return argv;
}

fn makePrependedArgv(allocator: std.mem.Allocator, tokens: []const []const u8, rest: []const []const u8) ![][]const u8 {
    var argv = try allocator.alloc([]const u8, tokens.len + rest.len);
    for (tokens, 0..) |token, i| argv[i] = try allocator.dupe(u8, token);
    for (rest, 0..) |arg, i| argv[tokens.len + i] = try allocator.dupe(u8, arg);
    return argv;
}

fn freeArgv(allocator: std.mem.Allocator, argv: [][]const u8) void {
    for (argv) |arg| allocator.free(arg);
    allocator.free(argv);
}

test "guard set is name scoped" {
    try std.testing.expect(guardContains("gh:gs", "gh"));
    try std.testing.expect(!guardContains("gh:gs", "g"));
    const next = try appendGuard(std.testing.allocator, "gh", "gs");
    defer std.testing.allocator.free(next);
    try std.testing.expectEqualStrings("gh:gs", next);
}
