const std = @import("std");

const cli = @import("cli.zig");
const dispatch = @import("dispatch.zig");
const sys = @import("sys.zig");

const Exit = error{Exit};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var iter = std.process.Args.Iterator.init(init.minimal.args);
    var args_list = std.ArrayList([]const u8).empty;
    defer args_list.deinit(allocator);
    while (iter.next()) |arg| try args_list.append(allocator, arg);
    const args = args_list.items;

    const argv0 = if (args.len > 0) args[0] else "";
    const name = std.fs.path.basename(argv0);

    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "/")) {
        stderr("glolias: cannot determine alias name (empty argv[0])\n", .{});
        std.process.exit(127);
    }

    if (std.mem.eql(u8, name, "glolias")) {
        try cli.run(allocator, args[1..]);
        return;
    }

    try dispatch.run(allocator, name, args[1..]);
}

pub fn fail(comptime fmt: []const u8, args: anytype, code: u8) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(code);
}

pub fn stderr(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

pub fn stdout(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try sys.writeAll(std.posix.STDOUT_FILENO, text);
}
