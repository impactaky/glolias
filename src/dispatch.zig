const std = @import("std");

const config = @import("config.zig");
const main = @import("main.zig");
const sys = @import("sys.zig");

const guard_env = "GLOLIAS_GUARD";

pub fn run(allocator: std.mem.Allocator, name: []const u8, rest_args: []const []const u8) !void {
    var cfg = config.load(allocator) catch |err| {
        main.fail("glolias: unable to load config: {s}\n", .{@errorName(err)}, 127);
    };
    defer cfg.deinit(allocator);

    const guard_value = sys.getenvOwned(allocator, guard_env) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(guard_value);

    if (guardContains(guard_value, name)) {
        const real = resolveReal(allocator, name, cfg.shims_dir) catch |err| {
            main.fail("glolias: {s}: command not found ({s})\n", .{ name, @errorName(err) }, 127);
        };
        defer allocator.free(real);

        const argv = try makeArgv(allocator, name, rest_args);
        defer freeArgv(allocator, argv);
        execv(real, argv);
    }

    const tokens = cfg.aliases.get(name) orelse {
        main.fail("glolias: no alias '{s}' - run 'glolias sync'\n", .{name}, 127);
    };
    if (tokens.len == 0) {
        main.fail("glolias: alias '{s}' has no command\n", .{name}, 127);
    }

    const new_guard = try appendGuard(allocator, guard_value, name);
    defer allocator.free(new_guard);
    try sys.setenvOwned(allocator, guard_env, new_guard);

    const argv = try makePrependedArgv(allocator, tokens, rest_args);
    defer freeArgv(allocator, argv);
    execvp(tokens[0], argv);
}

pub fn guardContains(guard: []const u8, name: []const u8) bool {
    var parts = std.mem.splitScalar(u8, guard, ':');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, name)) return true;
    }
    return false;
}

pub fn appendGuard(allocator: std.mem.Allocator, guard: []const u8, name: []const u8) ![]const u8 {
    if (guardContains(guard, name)) return allocator.dupe(u8, guard);
    if (guard.len == 0) return allocator.dupe(u8, name);
    return std.mem.concat(allocator, u8, &.{ guard, ":", name });
}

pub fn resolveReal(allocator: std.mem.Allocator, name: []const u8, shims_dir: []const u8) ![]const u8 {
    const path_value = sys.getenvOwned(allocator, "PATH") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.CommandNotFound,
        else => return err,
    };
    defer allocator.free(path_value);

    var dirs = std.mem.splitScalar(u8, path_value, ':');
    while (dirs.next()) |raw_dir| {
        const dir = if (raw_dir.len == 0) "." else raw_dir;
        if (sameDir(allocator, dir, shims_dir)) continue;

        const candidate = try std.fs.path.join(allocator, &.{ dir, name });
        if (sys.isExecutableFile(allocator, candidate)) {
            return candidate;
        }
        allocator.free(candidate);
    }
    return error.CommandNotFound;
}

fn sameDir(allocator: std.mem.Allocator, lhs: []const u8, rhs: []const u8) bool {
    const lhs_real = sys.realpathAlloc(allocator, lhs) catch return std.mem.eql(u8, lhs, rhs);
    defer allocator.free(lhs_real);
    const rhs_real = sys.realpathAlloc(allocator, rhs) catch return std.mem.eql(u8, lhs, rhs);
    defer allocator.free(rhs_real);
    return std.mem.eql(u8, lhs_real, rhs_real);
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

fn execvp(file: []const u8, argv: []const []const u8) noreturn {
    sys.execvpFile(std.heap.page_allocator, file, argv);
}

fn execv(path: []const u8, argv: []const []const u8) noreturn {
    sys.execvPath(std.heap.page_allocator, path, argv);
}

test "guard set is name scoped" {
    try std.testing.expect(guardContains("gh:gs", "gh"));
    try std.testing.expect(!guardContains("gh:gs", "g"));

    const allocator = std.testing.allocator;
    const next = try appendGuard(allocator, "gh", "gs");
    defer allocator.free(next);
    try std.testing.expectEqualStrings("gh:gs", next);
}
