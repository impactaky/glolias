const std = @import("std");
const alias_name = @import("alias_name.zig");
const credential_name = @import("credential_name.zig");
const env_name = @import("env_name.zig");

pub const current_version: u32 = 2;

pub const Credential = struct {
    name: []const u8,
    env_name: []const u8,
};

pub const Alias = struct {
    name: []const u8,
    tokens: [][]const u8,
    credential_names: [][]const u8,
};

pub const Document = struct {
    source_version: u32,
    aliases: []Alias,
    credentials: []Credential,

    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        for (self.aliases) |alias| {
            allocator.free(alias.name);
            freeStrings(allocator, alias.tokens);
            freeStrings(allocator, alias.credential_names);
        }
        allocator.free(self.aliases);
        for (self.credentials) |credential| {
            allocator.free(credential.name);
            allocator.free(credential.env_name);
        }
        allocator.free(self.credentials);
    }
};

pub const AliasView = struct {
    name: []const u8,
    tokens: []const []const u8,
    credential_names: []const []const u8,
};

pub const CredentialView = struct {
    name: []const u8,
    env_name: []const u8,
};

const Table = enum { root, aliases, credentials };

const AliasBuilder = struct {
    name: []const u8,
    tokens: ?[][]const u8 = null,
    credential_names: ?[][]const u8 = null,

    fn deinit(self: *AliasBuilder, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.tokens) |values| freeStrings(allocator, values);
        if (self.credential_names) |values| freeStrings(allocator, values);
    }
};

pub fn parseConfig(allocator: std.mem.Allocator, text: []const u8) !Document {
    const source_version = try parseVersion(text);
    if (source_version != 1 and source_version != current_version) return error.UnsupportedConfigVersion;

    var builders = std.ArrayList(AliasBuilder).empty;
    errdefer {
        for (builders.items) |*builder| builder.deinit(allocator);
        builders.deinit(allocator);
    }
    var credentials = std.ArrayList(Credential).empty;
    errdefer {
        for (credentials.items) |credential| {
            allocator.free(credential.name);
            allocator.free(credential.env_name);
        }
        credentials.deinit(allocator);
    }

    var table: Table = .root;
    var version_seen = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, stripComment(raw_line), " \t\r");
        if (line.len == 0) continue;

        if (std.mem.eql(u8, line, "[aliases]")) {
            table = .aliases;
            continue;
        }
        if (std.mem.eql(u8, line, "[credentials]")) {
            if (source_version == 1) return error.UnsupportedConfigTable;
            table = .credentials;
            continue;
        }
        if (std.mem.startsWith(u8, line, "[")) return error.UnsupportedConfigTable;

        const assignment = try splitAssignment(line);
        switch (table) {
            .root => {
                if (!std.mem.eql(u8, assignment.key, "version") or version_seen) return error.InvalidConfig;
                version_seen = true;
                if (try std.fmt.parseInt(u32, assignment.value, 10) != source_version) return error.InvalidConfig;
            },
            .credentials => try parseCredential(allocator, &credentials, assignment.key, assignment.value),
            .aliases => if (source_version == 1)
                try parseV1Alias(allocator, &builders, assignment.key, assignment.value)
            else
                try parseV2AliasField(allocator, &builders, assignment.key, assignment.value),
        }
    }
    if (!version_seen) return error.InvalidConfig;

    var aliases = try allocator.alloc(Alias, builders.items.len);
    var alias_count: usize = 0;
    errdefer {
        for (aliases[0..alias_count]) |alias| {
            allocator.free(alias.name);
            freeStrings(allocator, alias.tokens);
            freeStrings(allocator, alias.credential_names);
        }
        allocator.free(aliases);
    }
    for (builders.items, 0..) |*builder, i| {
        const tokens = builder.tokens orelse return error.InvalidConfig;
        const bound = builder.credential_names orelse return error.InvalidConfig;
        if (tokens.len == 0) return error.InvalidConfig;
        try validateBindings(bound, credentials.items);
        aliases[i] = .{ .name = builder.name, .tokens = tokens, .credential_names = bound };
        builder.name = &.{};
        builder.tokens = null;
        builder.credential_names = null;
        alias_count += 1;
    }
    builders.deinit(allocator);

    return .{
        .source_version = source_version,
        .aliases = aliases,
        .credentials = try credentials.toOwnedSlice(allocator),
    };
}

pub fn serializeConfig(
    allocator: std.mem.Allocator,
    aliases: []const AliasView,
    credentials: []const CredentialView,
) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.print(allocator, "version = {d}\n\n", .{current_version});
    try out.appendSlice(allocator, "[credentials]\n");
    for (credentials) |credential| {
        try credential_name.validate(credential.name);
        try env_name.validate(credential.env_name);
        try out.appendSlice(allocator, credential.name);
        try out.appendSlice(allocator, " = \"");
        try appendEscapedString(&out, allocator, credential.env_name);
        try out.appendSlice(allocator, "\"\n");
    }

    try out.appendSlice(allocator, "\n[aliases]\n");
    for (aliases) |alias| {
        try alias_name.validate(alias.name);
        try validateBindingNames(alias.credential_names);
        try out.appendSlice(allocator, alias.name);
        try out.appendSlice(allocator, ".tokens = ");
        try appendStringArray(&out, allocator, alias.tokens);
        try out.append(allocator, '\n');
        try out.appendSlice(allocator, alias.name);
        try out.appendSlice(allocator, ".credentials = ");
        try appendStringArray(&out, allocator, alias.credential_names);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

fn parseVersion(text: []const u8) !u32 {
    var table: Table = .root;
    var found: ?u32 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, stripComment(raw_line), " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            table = .aliases;
            continue;
        }
        if (table != .root) continue;
        const assignment = try splitAssignment(line);
        if (!std.mem.eql(u8, assignment.key, "version")) continue;
        if (found != null) return error.InvalidConfig;
        found = try std.fmt.parseInt(u32, assignment.value, 10);
    }
    return found orelse error.InvalidConfig;
}

const Assignment = struct { key: []const u8, value: []const u8 };

fn splitAssignment(line: []const u8) !Assignment {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfig;
    const key = std.mem.trim(u8, line[0..eq], " \t");
    const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
    if (key.len == 0 or value.len == 0) return error.InvalidConfig;
    return .{ .key = key, .value = value };
}

fn parseCredential(
    allocator: std.mem.Allocator,
    credentials: *std.ArrayList(Credential),
    name: []const u8,
    value: []const u8,
) !void {
    try credential_name.validate(name);
    for (credentials.items) |credential| {
        if (std.mem.eql(u8, credential.name, name)) return error.DuplicateCredential;
    }
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const environment = try parseString(allocator, value);
    errdefer allocator.free(environment);
    try env_name.validate(environment);
    try credentials.append(allocator, .{ .name = owned_name, .env_name = environment });
}

fn parseV1Alias(
    allocator: std.mem.Allocator,
    builders: *std.ArrayList(AliasBuilder),
    name: []const u8,
    value: []const u8,
) !void {
    try alias_name.validate(name);
    if (findBuilder(builders.items, name) != null) return error.DuplicateAlias;
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const tokens = try parseStringArray(allocator, value);
    errdefer freeStrings(allocator, tokens);
    const bound = try allocator.alloc([]const u8, 0);
    errdefer allocator.free(bound);
    try builders.append(allocator, .{
        .name = owned_name,
        .tokens = tokens,
        .credential_names = bound,
    });
}

fn parseV2AliasField(
    allocator: std.mem.Allocator,
    builders: *std.ArrayList(AliasBuilder),
    key: []const u8,
    value: []const u8,
) !void {
    const dot = std.mem.lastIndexOfScalar(u8, key, '.') orelse return error.InvalidConfig;
    const name = key[0..dot];
    const field = key[dot + 1 ..];
    try alias_name.validate(name);
    if (!std.mem.eql(u8, field, "tokens") and !std.mem.eql(u8, field, "credentials")) return error.InvalidConfig;

    var index = findBuilder(builders.items, name);
    if (index == null) {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        try builders.append(allocator, .{ .name = owned_name });
        index = builders.items.len - 1;
    }
    const values = try parseStringArray(allocator, value);
    errdefer freeStrings(allocator, values);
    const builder = &builders.items[index.?];
    if (std.mem.eql(u8, field, "tokens")) {
        if (builder.tokens != null) return error.DuplicateAliasField;
        builder.tokens = values;
    } else {
        if (builder.credential_names != null) return error.DuplicateAliasField;
        try validateBindingNames(values);
        builder.credential_names = values;
    }
}

fn findBuilder(builders: []const AliasBuilder, name: []const u8) ?usize {
    for (builders, 0..) |builder, i| {
        if (std.mem.eql(u8, builder.name, name)) return i;
    }
    return null;
}

fn validateBindingNames(names: []const []const u8) !void {
    for (names, 0..) |name, i| {
        try credential_name.validate(name);
        for (names[0..i]) |prior| {
            if (std.mem.eql(u8, prior, name)) return error.DuplicateCredentialBinding;
        }
    }
}

fn validateBindings(names: []const []const u8, credentials: []const Credential) !void {
    try validateBindingNames(names);
    for (names) |name| {
        var found = false;
        for (credentials) |credential| {
            if (std.mem.eql(u8, credential.name, name)) {
                found = true;
                break;
            }
        }
        if (!found) return error.DanglingCredentialBinding;
    }
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
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') return error.InvalidStringArray;
    var list = std.ArrayList([]const u8).empty;
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }
    var i: usize = 1;
    var expect_value = true;
    while (i < trimmed.len - 1) {
        while (i < trimmed.len - 1 and isSpace(trimmed[i])) i += 1;
        if (i >= trimmed.len - 1) break;
        if (!expect_value or trimmed[i] != '"') return error.InvalidStringArray;
        const start = i;
        i += 1;
        var escaped = false;
        var closed = false;
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
                closed = true;
                break;
            }
        }
        if (!closed) return error.InvalidStringArray;
        try list.append(allocator, try parseString(allocator, trimmed[start..i]));
        expect_value = false;
        while (i < trimmed.len - 1 and isSpace(trimmed[i])) i += 1;
        if (i < trimmed.len - 1) {
            if (trimmed[i] != ',') return error.InvalidStringArray;
            i += 1;
            expect_value = true;
        }
    }
    if (expect_value and list.items.len != 0) return error.InvalidStringArray;
    return list.toOwnedSlice(allocator);
}

fn parseString(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, input, " \t");
    if (trimmed.len < 2 or trimmed[0] != '"' or trimmed[trimmed.len - 1] != '"') return error.InvalidString;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 1;
    while (i < trimmed.len - 1) : (i += 1) {
        const c = trimmed[i];
        if (c != '\\') {
            if (c == 0) return error.InvalidString;
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

fn appendStringArray(out: *std.ArrayList(u8), allocator: std.mem.Allocator, values: []const []const u8) !void {
    try out.append(allocator, '[');
    for (values, 0..) |value, i| {
        if (i > 0) try out.appendSlice(allocator, ", ");
        try out.append(allocator, '"');
        try appendEscapedString(out, allocator, value);
        try out.append(allocator, '"');
    }
    try out.append(allocator, ']');
}

fn appendEscapedString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    for (value) |c| switch (c) {
        '\x08' => try out.appendSlice(allocator, "\\b"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\x0c' => try out.appendSlice(allocator, "\\f"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '"' => try out.appendSlice(allocator, "\\\""),
        '\\' => try out.appendSlice(allocator, "\\\\"),
        0 => return error.InvalidString,
        else => try out.append(allocator, c),
    };
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn freeStrings(allocator: std.mem.Allocator, values: [][]const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

test "version 1 loads with no Credential bindings and serializes as version 2" {
    const allocator = std.testing.allocator;
    var doc = try parseConfig(allocator,
        \\version = 1
        \\
        \\[aliases]
        \\gh = ["echo", "a b", "-x"]
    );
    defer doc.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 1), doc.source_version);
    try std.testing.expectEqual(@as(usize, 0), doc.aliases[0].credential_names.len);
    const out = try serializeConfig(allocator, &.{.{
        .name = doc.aliases[0].name,
        .tokens = doc.aliases[0].tokens,
        .credential_names = doc.aliases[0].credential_names,
    }}, &.{});
    defer allocator.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "version = 2\n"));
}

test "version 2 round trips Credential metadata and ordered bindings" {
    const allocator = std.testing.allocator;
    var doc = try parseConfig(allocator,
        \\version = 2
        \\
        \\[credentials]
        \\op = "OP_SERVICE_ACCOUNT_TOKEN"
        \\api = "API_TOKEN"
        \\
        \\[aliases]
        \\gh.tokens = ["echo", "ok"]
        \\gh.credentials = ["op", "api"]
    );
    defer doc.deinit(allocator);
    try std.testing.expectEqualStrings("API_TOKEN", doc.credentials[1].env_name);
    try std.testing.expectEqualStrings("api", doc.aliases[0].credential_names[1]);
}

test "version 2 rejects dangling and duplicate bindings" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.DanglingCredentialBinding, parseConfig(allocator,
        \\version = 2
        \\[credentials]
        \\op = "TOKEN"
        \\[aliases]
        \\gh.tokens = ["echo"]
        \\gh.credentials = ["missing"]
    ));
    try std.testing.expectError(error.DuplicateCredentialBinding, parseConfig(allocator,
        \\version = 2
        \\[credentials]
        \\op = "TOKEN"
        \\[aliases]
        \\gh.tokens = ["echo"]
        \\gh.credentials = ["op", "op"]
    ));
}
