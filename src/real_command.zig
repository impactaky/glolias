const std = @import("std");

const sys = @import("sys.zig");

pub const LocatedExecutable = struct {
    index: usize,
    dir: []const u8,
    path: []const u8,

    pub fn deinit(self: *LocatedExecutable, allocator: std.mem.Allocator) void {
        allocator.free(self.dir);
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub fn resolve(allocator: std.mem.Allocator, name: []const u8, shims_dir: []const u8) ![]const u8 {
    const path_value = sys.getenvOwned(allocator, "PATH") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.CommandNotFound,
        else => return err,
    };
    defer allocator.free(path_value);

    const found = (try findExecutable(allocator, path_value, name, shims_dir)) orelse {
        return error.CommandNotFound;
    };
    return found.path;
}

pub fn firstExecutable(
    allocator: std.mem.Allocator,
    path_value: []const u8,
    name: []const u8,
    excluded_dir: ?[]const u8,
) !?LocatedExecutable {
    const found = (try findExecutable(allocator, path_value, name, excluded_dir)) orelse return null;
    errdefer allocator.free(found.path);
    return .{
        .index = found.index,
        .dir = try allocator.dupe(u8, found.dir),
        .path = found.path,
    };
}

const ExecutableMatch = struct {
    index: usize,
    dir: []const u8,
    path: []const u8,
};

fn findExecutable(
    allocator: std.mem.Allocator,
    path_value: []const u8,
    name: []const u8,
    excluded_dir: ?[]const u8,
) !?ExecutableMatch {
    var dirs = std.mem.splitScalar(u8, path_value, ':');
    var index: usize = 0;
    while (dirs.next()) |raw_dir| : (index += 1) {
        const dir = if (raw_dir.len == 0) "." else raw_dir;
        if (excluded_dir) |excluded| {
            if (sameDir(allocator, dir, excluded)) continue;
        }

        const candidate = try std.fs.path.join(allocator, &.{ dir, name });
        if (!sys.isExecutableFile(allocator, candidate)) {
            allocator.free(candidate);
            continue;
        }
        return .{
            .index = index,
            .dir = dir,
            .path = candidate,
        };
    }
    return null;
}

pub fn indexOfDir(allocator: std.mem.Allocator, path_value: []const u8, needle: []const u8) ?usize {
    var dirs = std.mem.splitScalar(u8, path_value, ':');
    var index: usize = 0;
    while (dirs.next()) |raw_dir| : (index += 1) {
        const dir = if (raw_dir.len == 0) "." else raw_dir;
        if (sameDir(allocator, dir, needle)) return index;
    }
    return null;
}

fn sameDir(allocator: std.mem.Allocator, lhs: []const u8, rhs: []const u8) bool {
    const lhs_real = sys.realpathAlloc(allocator, lhs) catch return std.mem.eql(u8, lhs, rhs);
    defer allocator.free(lhs_real);
    const rhs_real = sys.realpathAlloc(allocator, rhs) catch return std.mem.eql(u8, lhs, rhs);
    defer allocator.free(rhs_real);
    return std.mem.eql(u8, lhs_real, rhs_real);
}

test "lookup skips a directory-equivalent Shims entry and preserves PATH indexes" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(relative_root);
    const root = try sys.realpathAlloc(allocator, relative_root);
    defer allocator.free(root);
    const shims_dir = try std.fs.path.join(allocator, &.{ root, "shims" });
    defer allocator.free(shims_dir);
    const linked_shims_dir = try std.fs.path.join(allocator, &.{ root, "linked-shims" });
    defer allocator.free(linked_shims_dir);
    const real_dir = try std.fs.path.join(allocator, &.{ root, "real" });
    defer allocator.free(real_dir);
    try sys.mkdirp(allocator, shims_dir);
    try sys.mkdirp(allocator, real_dir);
    try sys.symlinkPath(allocator, shims_dir, linked_shims_dir);

    const name = "glolias-real-command-test";
    const shim = try std.fs.path.join(allocator, &.{ shims_dir, name });
    defer allocator.free(shim);
    const real = try std.fs.path.join(allocator, &.{ real_dir, name });
    defer allocator.free(real);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = shim,
        .data = "#!/bin/sh\n",
        .flags = .{ .permissions = .fromMode(0o755) },
    });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = real,
        .data = "#!/bin/sh\n",
        .flags = .{ .permissions = .fromMode(0o755) },
    });

    const path_value = try std.mem.concat(allocator, u8, &.{ linked_shims_dir, ":", real_dir });
    defer allocator.free(path_value);
    var found = (try firstExecutable(allocator, path_value, name, shims_dir)).?;
    defer found.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), found.index);
    try std.testing.expectEqualStrings(real, found.path);

    const path_with_empty_entry = try std.mem.concat(allocator, u8, &.{ ":", real_dir });
    defer allocator.free(path_with_empty_entry);
    var after_empty = (try firstExecutable(allocator, path_with_empty_entry, name, null)).?;
    defer after_empty.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), after_empty.index);
}
