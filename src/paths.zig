const std = @import("std");
const sys = @import("sys.zig");

pub fn configFilePath(allocator: std.mem.Allocator) ![]const u8 {
    const config_home = getEnvOwned(allocator, "XDG_CONFIG_HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => blk: {
            const home = try homeDir(allocator);
            defer allocator.free(home);
            break :blk try std.fs.path.join(allocator, &.{ home, ".config" });
        },
        else => return err,
    };
    defer allocator.free(config_home);

    return std.fs.path.join(allocator, &.{ config_home, "glolias", "config.toml" });
}

pub fn defaultShimsDir(allocator: std.mem.Allocator) ![]const u8 {
    const data_home = getEnvOwned(allocator, "XDG_DATA_HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => blk: {
            const home = try homeDir(allocator);
            defer allocator.free(home);
            break :blk try std.fs.path.join(allocator, &.{ home, ".local", "share" });
        },
        else => return err,
    };
    defer allocator.free(data_home);

    return std.fs.path.join(allocator, &.{ data_home, "glolias", "shims" });
}

pub fn expandPath(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (std.mem.eql(u8, input, "~")) {
        return homeDir(allocator);
    }

    if (std.mem.startsWith(u8, input, "~/")) {
        const home = try homeDir(allocator);
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, input[2..] });
    }

    if (std.mem.startsWith(u8, input, "$HOME/")) {
        const home = try homeDir(allocator);
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, input[6..] });
    }

    if (std.fs.path.isAbsolute(input)) {
        return allocator.dupe(u8, input);
    }

    const cwd = try sys.cwdAlloc(allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, input });
}

pub fn selfExePath(allocator: std.mem.Allocator) ![]const u8 {
    return sys.selfExePath(allocator);
}

pub fn ensureParentDir(allocator: std.mem.Allocator, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try sys.mkdirp(allocator, parent);
    }
}

fn homeDir(allocator: std.mem.Allocator) ![]const u8 {
    return getEnvOwned(allocator, "HOME") catch error.MissingHome;
}

fn getEnvOwned(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return sys.getenvOwned(allocator, name);
}
