const std = @import("std");

pub const contract = "[A-Za-z0-9_][A-Za-z0-9_-]*";

pub fn validate(name: []const u8) !void {
    if (name.len == 0) return error.EmptyName;
    if (!isInitial(name[0])) return error.InvalidInitialCharacter;
    for (name[1..]) |c| {
        if (!isInitial(c) and c != '-') return error.InvalidCharacter;
    }
}

fn isInitial(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '_';
}

test "Credential names are deterministic safe filenames" {
    for ([_][]const u8{ "op", "OP_1", "shared-token" }) |name| try validate(name);
    try std.testing.expectError(error.EmptyName, validate(""));
    try std.testing.expectError(error.InvalidInitialCharacter, validate("-bad"));
    try std.testing.expectError(error.InvalidCharacter, validate("a/b"));
}
