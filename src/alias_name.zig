const std = @import("std");

pub const pattern = "[A-Za-z0-9_][A-Za-z0-9_-]*";
pub const reserved = "glolias";
pub const contract = "must match " ++ pattern ++ "; '" ++ reserved ++ "' is reserved";

pub fn validate(name: []const u8) !void {
    if (name.len == 0) return error.EmptyName;
    if (std.mem.eql(u8, name, reserved)) return error.ReservedName;
    if (!isInitial(name[0])) return error.InvalidInitialCharacter;
    for (name[1..]) |c| {
        if (!isContinuation(c)) return error.InvalidCharacter;
    }
}

fn isInitial(c: u8) bool {
    return isAsciiAlphanumeric(c) or c == '_';
}

fn isContinuation(c: u8) bool {
    return isInitial(c) or c == '-';
}

fn isAsciiAlphanumeric(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9');
}

test "Alias name contract accepts its boundary forms" {
    for ([_][]const u8{ "a", "A0", "_local", "foo-bar" }) |name| {
        try validate(name);
    }
}

test "Alias name contract rejects unsupported forms" {
    try std.testing.expectError(error.EmptyName, validate(""));
    try std.testing.expectError(error.ReservedName, validate("glolias"));
    try std.testing.expectError(error.InvalidInitialCharacter, validate("-x"));
    try std.testing.expectError(error.InvalidInitialCharacter, validate("."));
    try std.testing.expectError(error.InvalidInitialCharacter, validate("é"));
    for ([_][]const u8{ "a/b", "a b", "a:b" }) |name| {
        try std.testing.expectError(error.InvalidCharacter, validate(name));
    }
}
