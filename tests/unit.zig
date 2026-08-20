const std = @import("std");
const glolias = @import("glolias");

test {
    std.testing.refAllDecls(glolias.alias_name);
    std.testing.refAllDecls(glolias.config);
    std.testing.refAllDecls(glolias.config_toml);
    std.testing.refAllDecls(glolias.dispatch);
    std.testing.refAllDecls(glolias.doctor);
    std.testing.refAllDecls(glolias.real_command);
    std.testing.refAllDecls(glolias.aliases);
    std.testing.refAllDecls(glolias.setup);
    std.testing.refAllDecls(glolias.cli);
}

test "every representative CLI-valid Alias name serializes" {
    const allocator = std.testing.allocator;
    const tokens = [_][]const u8{"echo"};

    for ([_][]const u8{ "a", "A0", "_local", "foo-bar" }) |name| {
        try glolias.alias_name.validate(name);
        const out = try glolias.config_toml.serializeConfig(allocator, &.{
            .{ .name = name, .tokens = &tokens, .credential_names = &.{} },
        }, &.{});
        defer allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, name) != null);
    }
}

test "CLI validation and TOML serialization reject the same Alias names" {
    const allocator = std.testing.allocator;
    const tokens = [_][]const u8{"echo"};
    const cases = [_]struct { name: []const u8, expected: anyerror }{
        .{ .name = "", .expected = error.EmptyName },
        .{ .name = "glolias", .expected = error.ReservedName },
        .{ .name = "-x", .expected = error.InvalidInitialCharacter },
        .{ .name = "foo.bar", .expected = error.InvalidCharacter },
        .{ .name = "é", .expected = error.InvalidInitialCharacter },
    };

    for (cases) |case| {
        try std.testing.expectError(case.expected, glolias.alias_name.validate(case.name));
        try std.testing.expectError(case.expected, glolias.config_toml.serializeConfig(allocator, &.{
            .{ .name = case.name, .tokens = &tokens, .credential_names = &.{} },
        }, &.{}));
    }
}

test "quoted TOML Alias keys use the same decoded name contract" {
    const allocator = std.testing.allocator;
    var doc = try glolias.config_toml.parseConfig(allocator,
        \\version = 1
        \\
        \\[aliases]
        \\"foo" = ["echo"]
    );
    defer doc.deinit(allocator);
    try std.testing.expectEqualStrings("foo", doc.aliases[0].name);
}

test "config TOML adapter serializes glolias schema canonically" {
    const allocator = std.testing.allocator;
    var doc = try glolias.config_toml.parseConfig(allocator,
        \\version = 1
        \\
        \\[aliases]
        \\gh = ["echo", "hi"]
    );
    defer doc.deinit(allocator);

    const out = try glolias.config_toml.serializeConfig(allocator, &.{
        .{ .name = doc.aliases[0].name, .tokens = doc.aliases[0].tokens, .credential_names = doc.aliases[0].credential_names },
    }, &.{});
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "shims_dir") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "gh.tokens = [\"echo\", \"hi\"]") != null);
}
