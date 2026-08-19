const std = @import("std");
const credential_runner = @import("credential_runner.zig");
const sys = @import("sys.zig");

const c = std.c;
const watched_signals = [_]std.posix.SIG{ .INT, .TERM, .HUP, .QUIT };

var restore_fd: c.fd_t = -1;
var restore_termios: c.termios = undefined;

pub fn readSecret(allocator: std.mem.Allocator) ![]u8 {
    const fd = c.open("/dev/tty", .{ .ACCMODE = .RDWR, .NOCTTY = true });
    if (fd < 0) return error.TtyUnavailable;
    defer _ = c.close(fd);
    return readSecretFromTty(allocator, fd);
}

pub fn readSecretFromTty(allocator: std.mem.Allocator, fd: c.fd_t) ![]u8 {
    var original: c.termios = undefined;
    if (c.tcgetattr(fd, &original) != 0) return error.TtyUnavailable;
    var hidden = original;
    hidden.lflag.ECHO = false;

    var old_actions: [watched_signals.len]std.posix.Sigaction = undefined;
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = restoreOnSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    for (watched_signals, 0..) |signal, i| std.posix.sigaction(signal, &action, &old_actions[i]);
    defer for (watched_signals, 0..) |signal, i| std.posix.sigaction(signal, &old_actions[i], null);

    restore_fd = fd;
    restore_termios = original;
    defer restore_fd = -1;

    if (c.tcsetattr(fd, .FLUSH, &hidden) != 0) return error.TtyUnavailable;
    defer _ = c.tcsetattr(fd, .FLUSH, &original);

    try sys.writeAll(fd, "Secret: ");
    defer sys.writeAll(fd, "\n") catch {};

    var secret = std.ArrayList(u8).empty;
    errdefer {
        std.crypto.secureZero(u8, secret.items);
        secret.deinit(allocator);
    }
    while (true) {
        var byte: [1]u8 = undefined;
        const count = c.read(fd, &byte, 1);
        if (count < 0) {
            if (c.errno(-1) == .INTR) return error.SecretEntryInterrupted;
            return error.TtyReadFailed;
        }
        if (count == 0) return error.TtyClosed;
        if (byte[0] == '\n') break;
        if (byte[0] == 0) return error.SecretContainsNul;
        if (secret.items.len == credential_runner.max_secret_len) return error.SecretTooLong;
        try secret.append(allocator, byte[0]);
    }
    if (secret.items.len > 0 and secret.items[secret.items.len - 1] == '\r') _ = secret.pop();
    if (secret.items.len == 0) return error.EmptySecret;
    return secret.toOwnedSlice(allocator);
}

fn restoreOnSignal(signal: std.posix.SIG) callconv(.c) void {
    if (restore_fd >= 0) _ = c.tcsetattr(restore_fd, .FLUSH, &restore_termios);
    const default_action: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(signal, &default_action, null);
    std.posix.raise(signal) catch std.process.exit(128 + @as(u8, @intCast(@intFromEnum(signal))));
}
