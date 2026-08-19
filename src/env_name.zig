const std = @import("std");

pub const contract = "[A-Za-z_][A-Za-z0-9_]*";

pub fn validate(name: []const u8) !void {
    if (name.len == 0) return error.EmptyName;
    if (!isInitial(name[0])) return error.InvalidInitialCharacter;
    for (name[1..]) |c| {
        if (!isInitial(c) and !(c >= '0' and c <= '9')) return error.InvalidCharacter;
    }
}

fn isInitial(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        c == '_';
}

test "environment names use the strict portable identifier contract" {
    for ([_][]const u8{ "TOKEN", "_TOKEN", "Token_2" }) |name| try validate(name);
    try std.testing.expectError(error.EmptyName, validate(""));
    try std.testing.expectError(error.InvalidInitialCharacter, validate("2TOKEN"));
    try std.testing.expectError(error.InvalidCharacter, validate("A-B"));
}
