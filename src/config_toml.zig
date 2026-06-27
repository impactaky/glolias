const std = @import("std");

pub const Alias = struct {
    name: []const u8,
    tokens: [][]const u8,
};

pub const Document = struct {
    version: u32 = 1,
    shims_dir: ?[]const u8 = null,
    aliases: []Alias,

    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        if (self.shims_dir) |value| allocator.free(value);
        for (self.aliases) |alias| {
            allocator.free(alias.name);
            for (alias.tokens) |token| allocator.free(token);
            allocator.free(alias.tokens);
        }
        allocator.free(self.aliases);
    }
};

pub const AliasView = struct {
    name: []const u8,
    tokens: []const []const u8,
};

pub fn parseConfig(allocator: std.mem.Allocator, text: []const u8) !Document {
    var aliases = std.ArrayList(Alias).empty;
    errdefer {
        for (aliases.items) |alias| {
            allocator.free(alias.name);
            for (alias.tokens) |token| allocator.free(token);
            allocator.free(alias.tokens);
        }
        aliases.deinit(allocator);
    }

    var doc = Document{
        .version = 1,
        .shims_dir = null,
        .aliases = &.{},
    };
    errdefer if (doc.shims_dir) |value| allocator.free(value);

    var in_aliases = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const without_comment = stripComment(raw_line);
        const line = std.mem.trim(u8, without_comment, " \t\r");
        if (line.len == 0) continue;

        if (std.mem.eql(u8, line, "[aliases]")) {
            in_aliases = true;
            continue;
        }

        if (std.mem.startsWith(u8, line, "[")) {
            return error.UnsupportedConfigTable;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfig;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (!in_aliases) {
            if (std.mem.eql(u8, key, "version")) {
                doc.version = try std.fmt.parseInt(u32, value, 10);
            } else if (std.mem.eql(u8, key, "shims_dir")) {
                if (doc.shims_dir) |old| allocator.free(old);
                doc.shims_dir = try parseString(allocator, value);
            } else {
                return error.InvalidConfig;
            }
        } else {
            try validateBareKey(key);
            const owned_name = try allocator.dupe(u8, key);
            errdefer allocator.free(owned_name);
            const tokens = try parseStringArray(allocator, value);
            errdefer {
                for (tokens) |token| allocator.free(token);
                allocator.free(tokens);
            }
            try aliases.append(allocator, .{
                .name = owned_name,
                .tokens = tokens,
            });
        }
    }

    doc.aliases = try aliases.toOwnedSlice(allocator);
    return doc;
}

pub fn serializeConfig(
    allocator: std.mem.Allocator,
    version: u32,
    shims_dir: []const u8,
    aliases: []const AliasView,
) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.print(allocator, "version = {d}\n", .{version});
    try out.appendSlice(allocator, "shims_dir = \"");
    try appendEscapedString(&out, allocator, shims_dir);
    try out.appendSlice(allocator, "\"\n\n");
    try out.appendSlice(allocator, "[aliases]\n");

    for (aliases) |alias| {
        try validateBareKey(alias.name);
        try out.appendSlice(allocator, alias.name);
        try out.appendSlice(allocator, " = [");
        for (alias.tokens, 0..) |token, i| {
            if (i > 0) try out.appendSlice(allocator, ", ");
            try out.append(allocator, '"');
            try appendEscapedString(&out, allocator, token);
            try out.append(allocator, '"');
        }
        try out.appendSlice(allocator, "]\n");
    }

    return out.toOwnedSlice(allocator);
}

fn stripComment(line: []const u8) []const u8 {
    var in_string = false;
    var escaped = false;
    for (line, 0..) |c, i| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (in_string and c == '\\') {
            escaped = true;
            continue;
        }
        if (c == '"') {
            in_string = !in_string;
            continue;
        }
        if (!in_string and c == '#') return line[0..i];
    }
    return line;
}

fn parseStringArray(allocator: std.mem.Allocator, input: []const u8) ![][]const u8 {
    const trimmed = std.mem.trim(u8, input, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') {
        return error.InvalidStringArray;
    }

    var list = std.ArrayList([]const u8).empty;
    errdefer {
        for (list.items) |token| allocator.free(token);
        list.deinit(allocator);
    }

    var i: usize = 1;
    while (i < trimmed.len - 1) {
        while (i < trimmed.len - 1 and isSpace(trimmed[i])) i += 1;
        if (i < trimmed.len - 1 and trimmed[i] == ',') {
            i += 1;
            continue;
        }
        if (i >= trimmed.len - 1) break;
        if (trimmed[i] != '"') return error.InvalidStringArray;

        const start = i;
        i += 1;
        var escaped = false;
        while (i < trimmed.len - 1) : (i += 1) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (trimmed[i] == '\\') {
                escaped = true;
                continue;
            }
            if (trimmed[i] == '"') {
                i += 1;
                break;
            }
        }
        if (i > trimmed.len - 1) return error.InvalidStringArray;
        try list.append(allocator, try parseString(allocator, trimmed[start..i]));

        while (i < trimmed.len - 1 and isSpace(trimmed[i])) i += 1;
        if (i < trimmed.len - 1) {
            if (trimmed[i] != ',') return error.InvalidStringArray;
            i += 1;
        }
    }

    return list.toOwnedSlice(allocator);
}

fn parseString(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, input, " \t");
    if (trimmed.len < 2 or trimmed[0] != '"' or trimmed[trimmed.len - 1] != '"') {
        return error.InvalidString;
    }

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var i: usize = 1;
    while (i < trimmed.len - 1) : (i += 1) {
        const c = trimmed[i];
        if (c != '\\') {
            try out.append(allocator, c);
            continue;
        }

        i += 1;
        if (i >= trimmed.len - 1) return error.InvalidString;
        const escaped: u8 = switch (trimmed[i]) {
            'b' => '\x08',
            't' => '\t',
            'n' => '\n',
            'f' => '\x0c',
            'r' => '\r',
            '"' => '"',
            '\\' => '\\',
            else => return error.UnsupportedEscape,
        };
        try out.append(allocator, escaped);
    }

    return out.toOwnedSlice(allocator);
}

fn appendEscapedString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    for (value) |c| {
        switch (c) {
            '\x08' => try out.appendSlice(allocator, "\\b"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\x0c' => try out.appendSlice(allocator, "\\f"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            else => try out.append(allocator, c),
        }
    }
}

fn validateBareKey(key: []const u8) !void {
    if (key.len == 0) return error.InvalidBareKey;
    for (key) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') {
            return error.InvalidBareKey;
        }
    }
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

test "parse and serialize glolias config schema" {
    const allocator = std.testing.allocator;
    var doc = try parseConfig(allocator,
        \\version = 1
        \\shims_dir = "/tmp/glolias shims"
        \\
        \\[aliases]
        \\gh = ["echo", "a b", "-x"]
    );
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), doc.version);
    try std.testing.expectEqualStrings("/tmp/glolias shims", doc.shims_dir.?);
    try std.testing.expectEqual(@as(usize, 1), doc.aliases.len);
    try std.testing.expectEqualStrings("a b", doc.aliases[0].tokens[1]);

    const text = try serializeConfig(allocator, doc.version, doc.shims_dir.?, &.{
        .{ .name = doc.aliases[0].name, .tokens = doc.aliases[0].tokens },
    });
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "gh = [\"echo\", \"a b\", \"-x\"]") != null);
}
