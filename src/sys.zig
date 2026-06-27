const std = @import("std");

const c = std.c;
const dirent = c.dirent;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn readdir(dir: *c.DIR) ?*dirent;
extern "c" fn realpath(path: [*:0]const u8, resolved: ?[*]u8) ?[*:0]u8;
extern "c" fn free(ptr: ?*anyopaque) void;

pub fn getenvOwned(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const z_name = try allocator.dupeZ(u8, name);
    defer allocator.free(z_name);
    const ptr = c.getenv(z_name.ptr) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

pub fn setenvOwned(allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
    const z_name = try allocator.dupeZ(u8, name);
    defer allocator.free(z_name);
    const z_value = try allocator.dupeZ(u8, value);
    defer allocator.free(z_value);
    if (setenv(z_name.ptr, z_value.ptr, 1) != 0) return error.SetEnvFailed;
}

pub fn writeAll(fd: c.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0) return error.WriteFailed;
        if (n == 0) return error.WriteFailed;
        offset += @intCast(n);
    }
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    const z_path = try allocator.dupeZ(u8, path);
    defer allocator.free(z_path);

    const fd = c.open(z_path.ptr, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return errnoToOpenError();
    defer _ = c.close(fd);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        if (out.items.len + @as(usize, @intCast(n)) > limit) return error.FileTooBig;
        try out.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    return out.toOwnedSlice(allocator);
}

pub fn writeFileTruncate(allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    try ensureParentDir(allocator, path);

    const z_path = try allocator.dupeZ(u8, path);
    defer allocator.free(z_path);

    const fd = c.open(z_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o644));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    try writeAll(fd, data);
}

pub fn mkdirp(allocator: std.mem.Allocator, path: []const u8) !void {
    if (path.len == 0) return;
    var partial = std.ArrayList(u8).empty;
    defer partial.deinit(allocator);

    if (path[0] == '/') try partial.append(allocator, '/');

    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (partial.items.len > 0 and partial.items[partial.items.len - 1] != '/') {
            try partial.append(allocator, '/');
        }
        try partial.appendSlice(allocator, part);
        const z_path = try allocator.dupeZ(u8, partial.items);
        defer allocator.free(z_path);
        if (c.mkdir(z_path.ptr, 0o755) != 0) {
            switch (c.errno(-1)) {
                .EXIST => {},
                else => return error.MkdirFailed,
            }
        }
    }
}

pub fn ensureParentDir(allocator: std.mem.Allocator, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try mkdirp(allocator, parent);
    }
}

pub fn unlinkPath(allocator: std.mem.Allocator, path: []const u8) !void {
    const z_path = try allocator.dupeZ(u8, path);
    defer allocator.free(z_path);
    if (c.unlink(z_path.ptr) != 0) {
        switch (c.errno(-1)) {
            .NOENT => return error.FileNotFound,
            else => return error.UnlinkFailed,
        }
    }
}

pub fn symlinkPath(allocator: std.mem.Allocator, target: []const u8, link_path: []const u8) !void {
    const z_target = try allocator.dupeZ(u8, target);
    defer allocator.free(z_target);
    const z_link = try allocator.dupeZ(u8, link_path);
    defer allocator.free(z_link);
    if (c.symlink(z_target.ptr, z_link.ptr) != 0) return error.SymlinkFailed;
}

pub fn isDir(allocator: std.mem.Allocator, path: []const u8) bool {
    const z_path = allocator.dupeZ(u8, path) catch return false;
    defer allocator.free(z_path);
    const dir = c.opendir(z_path.ptr) orelse return false;
    _ = c.closedir(dir);
    return true;
}

pub fn isExecutableFile(allocator: std.mem.Allocator, path: []const u8) bool {
    const z_path = allocator.dupeZ(u8, path) catch return false;
    defer allocator.free(z_path);
    return c.access(z_path.ptr, c.X_OK) == 0;
}

pub fn realpathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const z_path = try allocator.dupeZ(u8, path);
    defer allocator.free(z_path);
    const resolved = realpath(z_path.ptr, null) orelse return error.RealpathFailed;
    defer free(resolved);
    return allocator.dupe(u8, std.mem.span(resolved));
}

pub fn cwdAlloc(allocator: std.mem.Allocator) ![]const u8 {
    var buf: [4096]u8 = undefined;
    const ptr = c.getcwd(&buf, buf.len) orelse return error.GetCwdFailed;
    return allocator.dupe(u8, ptr[0..cStringLen(ptr)]);
}

pub fn selfExePath(allocator: std.mem.Allocator) ![]const u8 {
    return realpathAlloc(allocator, "/proc/self/exe");
}

pub fn listSymlinks(allocator: std.mem.Allocator, dir_path: []const u8) ![][]const u8 {
    const z_dir = try allocator.dupeZ(u8, dir_path);
    defer allocator.free(z_dir);
    const dir = c.opendir(z_dir.ptr) orelse return error.OpenDirFailed;
    defer _ = c.closedir(dir);

    var out = std.ArrayList([]const u8).empty;
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit(allocator);
    }

    while (readdir(dir)) |entry| {
        const name_ptr: [*]const u8 = @ptrCast(&entry.name);
        const name = name_ptr[0..cStringLen(name_ptr)];
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (entry.type == c.DT.LNK) {
            try out.append(allocator, try allocator.dupe(u8, name));
        }
    }

    return out.toOwnedSlice(allocator);
}

pub fn execvPath(allocator: std.mem.Allocator, path: []const u8, argv: []const []const u8) noreturn {
    const c_path = allocator.dupeZ(u8, path) catch std.process.exit(1);
    const c_argv = toSentinelArgv(allocator, argv) catch std.process.exit(1);
    _ = execv(c_path.ptr, c_argv.ptr);
    exitForErrno(path);
}

pub fn execvpFile(allocator: std.mem.Allocator, file: []const u8, argv: []const []const u8) noreturn {
    const c_file = allocator.dupeZ(u8, file) catch std.process.exit(1);
    const c_argv = toSentinelArgv(allocator, argv) catch std.process.exit(1);
    _ = execvp(c_file.ptr, c_argv.ptr);
    exitForErrno(file);
}

fn toSentinelArgv(allocator: std.mem.Allocator, argv: []const []const u8) ![:null]?[*:0]const u8 {
    var out = try allocator.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |arg, i| out[i] = (try allocator.dupeZ(u8, arg)).ptr;
    return out;
}

fn exitForErrno(cmd: []const u8) noreturn {
    switch (c.errno(-1)) {
        .NOENT => {
            std.debug.print("glolias: {s}: command not found\n", .{cmd});
            std.process.exit(127);
        },
        .ACCES => {
            std.debug.print("glolias: {s}: permission denied\n", .{cmd});
            std.process.exit(126);
        },
        else => {
            std.debug.print("glolias: {s}: exec failed\n", .{cmd});
            std.process.exit(1);
        },
    }
}

fn errnoToOpenError() anyerror {
    return switch (c.errno(-1)) {
        .NOENT => error.FileNotFound,
        else => error.OpenFailed,
    };
}

fn cStringLen(ptr: [*]const u8) usize {
    var i: usize = 0;
    while (ptr[i] != 0) : (i += 1) {}
    return i;
}
