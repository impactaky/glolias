const std = @import("std");
const alias_name = @import("alias_name.zig");
const credential_name = @import("credential_name.zig");
const env_name = @import("env_name.zig");

const toml = @cImport({
    @cInclude("tomlc17.h");
});

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
        freeAliases(allocator, self.aliases);
        freeCredentials(allocator, self.credentials);
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

pub fn parseConfig(allocator: std.mem.Allocator, text: []const u8) !Document {
    if (text.len > std.math.maxInt(c_int)) return error.InvalidConfig;
    const result = toml.toml_parse(text.ptr, @intCast(text.len));
    defer toml.toml_free(result);
    if (!result.ok) return error.InvalidConfig;

    const root = result.toptab;
    try expectTable(root);
    try validateRootFields(root);

    const version_value = findField(root, "version") orelse return error.InvalidConfig;
    if (version_value.type != toml.TOML_INT64) return error.InvalidConfig;
    const source_version = std.math.cast(u32, version_value.u.int64) orelse return error.UnsupportedConfigVersion;
    if (source_version != 1 and source_version != current_version) return error.UnsupportedConfigVersion;

    const credential_value = findField(root, "credentials");
    if (source_version == 1 and credential_value != null) return error.UnsupportedConfigTable;
    const credentials = if (credential_value) |value|
        try parseCredentials(allocator, value)
    else
        try allocator.alloc(Credential, 0);
    errdefer freeCredentials(allocator, credentials);

    const aliases = if (findField(root, "aliases")) |value|
        try parseAliases(allocator, value, source_version, credentials)
    else
        try allocator.alloc(Alias, 0);
    errdefer freeAliases(allocator, aliases);

    return .{
        .source_version = source_version,
        .aliases = aliases,
        .credentials = credentials,
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

fn validateRootFields(root: toml.toml_datum_t) !void {
    const size = try tableSize(root);
    for (0..size) |i| {
        const key = tableKey(root, i);
        if (!std.mem.eql(u8, key, "version") and
            !std.mem.eql(u8, key, "aliases") and
            !std.mem.eql(u8, key, "credentials")) return error.InvalidConfig;
    }
}

fn parseCredentials(allocator: std.mem.Allocator, value: toml.toml_datum_t) ![]Credential {
    const size = try tableSize(value);
    const credentials = try allocator.alloc(Credential, size);
    var initialized: usize = 0;
    errdefer {
        for (credentials[0..initialized]) |credential| {
            allocator.free(credential.name);
            allocator.free(credential.env_name);
        }
        allocator.free(credentials);
    }

    for (0..size) |i| {
        const name = tableKey(value, i);
        try credential_name.validate(name);
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const environment = try dupeString(allocator, tableValue(value, i));
        errdefer allocator.free(environment);
        try env_name.validate(environment);
        credentials[i] = .{ .name = owned_name, .env_name = environment };
        initialized += 1;
    }
    return credentials;
}

fn parseAliases(
    allocator: std.mem.Allocator,
    value: toml.toml_datum_t,
    source_version: u32,
    credentials: []const Credential,
) ![]Alias {
    const size = try tableSize(value);
    const aliases = try allocator.alloc(Alias, size);
    var initialized: usize = 0;
    errdefer {
        for (aliases[0..initialized]) |alias| freeAlias(allocator, alias);
        allocator.free(aliases);
    }

    for (0..size) |i| {
        const name = tableKey(value, i);
        try alias_name.validate(name);
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);

        const alias_value = tableValue(value, i);
        const tokens, const bindings = if (source_version == 1) values: {
            const tokens = try dupeStringArray(allocator, alias_value);
            errdefer freeStrings(allocator, tokens);
            const bindings = try allocator.alloc([]const u8, 0);
            break :values .{ tokens, bindings };
        } else values: {
            try validateAliasFields(alias_value);
            const token_value = findField(alias_value, "tokens") orelse return error.InvalidConfig;
            const binding_value = findField(alias_value, "credentials") orelse return error.InvalidConfig;
            const tokens = try dupeStringArray(allocator, token_value);
            errdefer freeStrings(allocator, tokens);
            const bindings = try dupeStringArray(allocator, binding_value);
            errdefer freeStrings(allocator, bindings);
            try validateBindings(bindings, credentials);
            break :values .{ tokens, bindings };
        };
        errdefer freeStrings(allocator, tokens);
        errdefer freeStrings(allocator, bindings);
        if (tokens.len == 0) return error.InvalidConfig;

        aliases[i] = .{
            .name = owned_name,
            .tokens = tokens,
            .credential_names = bindings,
        };
        initialized += 1;
    }
    return aliases;
}

fn validateAliasFields(value: toml.toml_datum_t) !void {
    const size = try tableSize(value);
    for (0..size) |i| {
        const key = tableKey(value, i);
        if (!std.mem.eql(u8, key, "tokens") and
            !std.mem.eql(u8, key, "credentials")) return error.InvalidConfig;
    }
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
        for (credentials) |credential| {
            if (std.mem.eql(u8, credential.name, name)) break;
        } else return error.DanglingCredentialBinding;
    }
}

fn findField(table: toml.toml_datum_t, name: []const u8) ?toml.toml_datum_t {
    const size = tableSize(table) catch return null;
    for (0..size) |i| {
        if (std.mem.eql(u8, tableKey(table, i), name)) return tableValue(table, i);
    }
    return null;
}

fn expectTable(value: toml.toml_datum_t) !void {
    if (value.type != toml.TOML_TABLE) return error.InvalidConfig;
}

fn tableSize(table: toml.toml_datum_t) !usize {
    try expectTable(table);
    return std.math.cast(usize, table.u.tab.size) orelse error.InvalidConfig;
}

fn tableKey(table: toml.toml_datum_t, index: usize) []const u8 {
    const len: usize = @intCast(table.u.tab.len[index]);
    return table.u.tab.key[index][0..len];
}

fn tableValue(table: toml.toml_datum_t, index: usize) toml.toml_datum_t {
    return table.u.tab.value[index];
}

fn dupeStringArray(allocator: std.mem.Allocator, value: toml.toml_datum_t) ![][]const u8 {
    if (value.type != toml.TOML_ARRAY) return error.InvalidConfig;
    const size = std.math.cast(usize, value.u.arr.size) orelse return error.InvalidConfig;
    const strings = try allocator.alloc([]const u8, size);
    var initialized: usize = 0;
    errdefer {
        for (strings[0..initialized]) |string| allocator.free(string);
        allocator.free(strings);
    }
    for (0..size) |i| {
        strings[i] = try dupeString(allocator, value.u.arr.elem[i]);
        initialized += 1;
    }
    return strings;
}

fn dupeString(allocator: std.mem.Allocator, value: toml.toml_datum_t) ![]const u8 {
    if (value.type != toml.TOML_STRING) return error.InvalidConfig;
    const len = std.math.cast(usize, value.u.str.len) orelse return error.InvalidConfig;
    const string = value.u.str.ptr[0..len];
    if (std.mem.indexOfScalar(u8, string, 0) != null) return error.InvalidConfig;
    return allocator.dupe(u8, string);
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
    for (value) |byte| switch (byte) {
        '\x08' => try out.appendSlice(allocator, "\\b"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\x0c' => try out.appendSlice(allocator, "\\f"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '"' => try out.appendSlice(allocator, "\\\""),
        '\\' => try out.appendSlice(allocator, "\\\\"),
        0 => return error.InvalidString,
        else => try out.append(allocator, byte),
    };
}

fn freeAlias(allocator: std.mem.Allocator, alias: Alias) void {
    allocator.free(alias.name);
    freeStrings(allocator, alias.tokens);
    freeStrings(allocator, alias.credential_names);
}

fn freeAliases(allocator: std.mem.Allocator, aliases: []Alias) void {
    for (aliases) |alias| freeAlias(allocator, alias);
    allocator.free(aliases);
}

fn freeCredentials(allocator: std.mem.Allocator, credentials: []Credential) void {
    for (credentials) |credential| {
        allocator.free(credential.name);
        allocator.free(credential.env_name);
    }
    allocator.free(credentials);
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

test "schema-equivalent standard TOML forms load through tomlc17" {
    const allocator = std.testing.allocator;
    var doc = try parseConfig(allocator,
        \\"version" = 2
        \\
        \\[credentials]
        \\'op' = 'OP_TOKEN'
        \\
        \\[aliases."gh"]
        \\tokens = [
        \\  'echo',
        \\  "ok",
        \\]
        \\credentials = ['op']
    );
    defer doc.deinit(allocator);
    try std.testing.expectEqualStrings("OP_TOKEN", doc.credentials[0].env_name);
    try std.testing.expectEqualStrings("ok", doc.aliases[0].tokens[1]);
    try std.testing.expectEqualStrings("op", doc.aliases[0].credential_names[0]);
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

    const out = try serializeConfig(allocator, &.{.{
        .name = doc.aliases[0].name,
        .tokens = doc.aliases[0].tokens,
        .credential_names = doc.aliases[0].credential_names,
    }}, &.{
        .{ .name = doc.credentials[0].name, .env_name = doc.credentials[0].env_name },
        .{ .name = doc.credentials[1].name, .env_name = doc.credentials[1].env_name },
    });
    defer allocator.free(out);
    var reparsed = try parseConfig(allocator, out);
    defer reparsed.deinit(allocator);
    try std.testing.expectEqualStrings("API_TOKEN", reparsed.credentials[1].env_name);
    try std.testing.expectEqualStrings("api", reparsed.aliases[0].credential_names[1]);
}

test "TOML and schema failures are rejected" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidConfig, parseConfig(allocator, "version = 2\n[aliases\n"));
    try std.testing.expectError(error.UnsupportedConfigVersion, parseConfig(allocator, "version = 3\n"));

    for ([_][]const u8{
        "version = 2\nversion = 2\n",
        "version = 2\nunknown = 1\n",
        "version = \"2\"\n",
        "version = 2\n[credentials]\nop = 1\n",
        "version = 2\n[credentials.op]\nenv = \"TOKEN\"\n",
        "version = 2\n[aliases]\ngh.tokens = [\"echo\"]\ngh.credentials = []\ngh.extra = true\n",
        "version = 2\n[aliases]\ngh.tokens = \"echo\"\ngh.credentials = []\n",
        "version = 2\n[aliases]\ngh.tokens = [\"echo\"]\n",
        "version = 2\n[aliases]\ngh.credentials = []\n",
        "version = 2\n[aliases]\ngh.tokens = []\ngh.credentials = []\n",
    }) |text| try std.testing.expectError(error.InvalidConfig, parseConfig(allocator, text));

    try std.testing.expectError(error.UnsupportedConfigTable, parseConfig(allocator,
        \\version = 1
        \\[credentials]
        \\op = "TOKEN"
    ));
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
