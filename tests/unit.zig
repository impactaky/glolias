const std = @import("std");
const glolias = @import("glolias");

test {
    std.testing.refAllDecls(glolias.config);
    std.testing.refAllDecls(glolias.config_toml);
    std.testing.refAllDecls(glolias.dispatch);
    std.testing.refAllDecls(glolias.cli);
}

test "internal config TOML parser serializes glolias schema" {
    const allocator = std.testing.allocator;
    var doc = try glolias.config_toml.parseConfig(allocator,
        \\version = 1
        \\shims_dir = "/tmp/shims"
        \\
        \\[aliases]
        \\gh = ["echo", "hi"]
    );
    defer doc.deinit(allocator);

    try std.testing.expectEqualStrings("/tmp/shims", doc.shims_dir.?);
    const out = try glolias.config_toml.serializeConfig(allocator, doc.version, doc.shims_dir.?, &.{
        .{ .name = doc.aliases[0].name, .tokens = doc.aliases[0].tokens },
    });
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "gh = [\"echo\", \"hi\"]") != null);
}
