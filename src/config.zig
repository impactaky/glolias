const std = @import("std");
const config_toml = @import("config_toml.zig");
const paths = @import("paths.zig");
const sys = @import("sys.zig");

pub const Alias = struct {
    tokens: [][]const u8,
    credential_names: [][]const u8,
};

pub const Credential = struct {
    env_name: []const u8,
};

pub const AliasMap = std.StringArrayHashMapUnmanaged(Alias);
pub const CredentialMap = std.StringArrayHashMapUnmanaged(Credential);

pub const Config = struct {
    source_version: u32 = config_toml.current_version,
    config_path: []const u8,
    shims_dir: []const u8,
    credentials_dir: []const u8,
    aliases: AliasMap,
    credentials: CredentialMap,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.config_path);
        allocator.free(self.shims_dir);
        allocator.free(self.credentials_dir);
        var aliases = self.aliases.iterator();
        while (aliases.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            freeStrings(allocator, entry.value_ptr.tokens);
            freeStrings(allocator, entry.value_ptr.credential_names);
        }
        self.aliases.deinit(allocator);
        var credentials = self.credentials.iterator();
        while (credentials.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.env_name);
        }
        self.credentials.deinit(allocator);
    }

    pub fn replaceAlias(
        self: *Config,
        allocator: std.mem.Allocator,
        name: []const u8,
        tokens: []const []const u8,
        credential_names: []const []const u8,
    ) !void {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        var owned_alias = try cloneAlias(allocator, tokens, credential_names);
        errdefer deinitAlias(allocator, &owned_alias);

        if (self.aliases.fetchOrderedRemove(name)) |old| {
            allocator.free(old.key);
            var old_alias = old.value;
            deinitAlias(allocator, &old_alias);
        }
        try self.aliases.put(allocator, owned_name, owned_alias);
    }

    pub fn removeAlias(self: *Config, allocator: std.mem.Allocator, name: []const u8) bool {
        const old = self.aliases.fetchOrderedRemove(name) orelse return false;
        allocator.free(old.key);
        var old_alias = old.value;
        deinitAlias(allocator, &old_alias);
        return true;
    }

    pub fn replaceCredential(
        self: *Config,
        allocator: std.mem.Allocator,
        name: []const u8,
        environment: []const u8,
    ) !void {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_environment = try allocator.dupe(u8, environment);
        errdefer allocator.free(owned_environment);

        if (self.credentials.fetchOrderedRemove(name)) |old| {
            allocator.free(old.key);
            allocator.free(old.value.env_name);
        }
        try self.credentials.put(allocator, owned_name, .{ .env_name = owned_environment });
    }

    pub fn removeCredential(self: *Config, allocator: std.mem.Allocator, name: []const u8) !void {
        var aliases = self.aliases.iterator();
        while (aliases.next()) |entry| {
            if (indexOf(entry.value_ptr.credential_names, name) != null) return error.CredentialInUse;
        }
        const old = self.credentials.fetchOrderedRemove(name) orelse return error.CredentialNotFound;
        allocator.free(old.key);
        allocator.free(old.value.env_name);
    }

    pub fn updateCredentialBindings(
        self: *Config,
        allocator: std.mem.Allocator,
        credential: []const u8,
        alias_names: []const []const u8,
        adding: bool,
    ) !void {
        if (!self.credentials.contains(credential)) return error.CredentialNotFound;
        for (alias_names, 0..) |alias_name, i| {
            if (self.aliases.get(alias_name) == null) return error.AliasNotFound;
            for (alias_names[0..i]) |prior| if (std.mem.eql(u8, prior, alias_name)) return error.DuplicateAliasArgument;
        }

        for (alias_names) |alias_name| {
            const alias = self.aliases.getPtr(alias_name).?;
            const index = indexOf(alias.credential_names, credential);
            if (adding and index == null) {
                const updated = try allocator.alloc([]const u8, alias.credential_names.len + 1);
                for (alias.credential_names, 0..) |value, i| updated[i] = value;
                updated[updated.len - 1] = try allocator.dupe(u8, credential);
                allocator.free(alias.credential_names);
                alias.credential_names = updated;
            } else if (!adding and index != null) {
                const removed = index.?;
                const updated = try allocator.alloc([]const u8, alias.credential_names.len - 1);
                var output: usize = 0;
                for (alias.credential_names, 0..) |value, i| {
                    if (i == removed) continue;
                    updated[output] = value;
                    output += 1;
                }
                allocator.free(alias.credential_names[removed]);
                allocator.free(alias.credential_names);
                alias.credential_names = updated;
            }
        }
    }

    pub fn boundAliases(self: *const Config, allocator: std.mem.Allocator, credential: []const u8) ![][]const u8 {
        var names = std.ArrayList([]const u8).empty;
        errdefer names.deinit(allocator);
        var map = self.aliases;
        var aliases = map.iterator();
        while (aliases.next()) |entry| {
            if (indexOf(entry.value_ptr.credential_names, credential) != null) try names.append(allocator, entry.key_ptr.*);
        }
        std.mem.sort([]const u8, names.items, {}, lessThanString);
        return names.toOwnedSlice(allocator);
    }
};

pub fn load(allocator: std.mem.Allocator) !Config {
    const config_path = try paths.configFilePath(allocator);
    errdefer allocator.free(config_path);
    const text = sys.readFileAlloc(allocator, config_path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return error.ConfigNotFound,
        else => return err,
    };
    defer allocator.free(text);
    const cfg = try parse(allocator, config_path, text);
    allocator.free(config_path);
    return cfg;
}

pub fn loadOrInit(allocator: std.mem.Allocator) !Config {
    return load(allocator) catch |err| switch (err) {
        error.ConfigNotFound => blk: {
            const config_path = try paths.configFilePath(allocator);
            errdefer allocator.free(config_path);
            const shims_dir = try paths.defaultShimsDir(allocator);
            errdefer allocator.free(shims_dir);
            const credentials_dir = try paths.defaultCredentialsDir(allocator);
            errdefer allocator.free(credentials_dir);
            break :blk .{
                .config_path = config_path,
                .shims_dir = shims_dir,
                .credentials_dir = credentials_dir,
                .aliases = .empty,
                .credentials = .empty,
            };
        },
        else => return err,
    };
}

pub fn save(allocator: std.mem.Allocator, cfg: *const Config) !void {
    try paths.ensureParentDir(cfg.config_path);
    const alias_keys = try sortedAliasKeys(allocator, cfg);
    defer allocator.free(alias_keys);
    const credential_keys = try sortedCredentialKeys(allocator, cfg);
    defer allocator.free(credential_keys);

    var aliases = try allocator.alloc(config_toml.AliasView, alias_keys.len);
    defer allocator.free(aliases);
    for (alias_keys, 0..) |key, i| {
        const alias = cfg.aliases.get(key).?;
        aliases[i] = .{
            .name = key,
            .tokens = alias.tokens,
            .credential_names = alias.credential_names,
        };
    }
    var credentials = try allocator.alloc(config_toml.CredentialView, credential_keys.len);
    defer allocator.free(credentials);
    for (credential_keys, 0..) |key, i| {
        credentials[i] = .{ .name = key, .env_name = cfg.credentials.get(key).?.env_name };
    }

    const out = try config_toml.serializeConfig(allocator, aliases, credentials);
    defer allocator.free(out);
    try sys.writeFileAtomic(allocator, cfg.config_path, out);
}

pub fn parse(allocator: std.mem.Allocator, config_path: []const u8, text: []const u8) !Config {
    var doc = try config_toml.parseConfig(allocator, text);
    defer doc.deinit(allocator);
    var cfg = Config{
        .source_version = doc.source_version,
        .config_path = try allocator.dupe(u8, config_path),
        .shims_dir = try paths.defaultShimsDir(allocator),
        .credentials_dir = try paths.defaultCredentialsDir(allocator),
        .aliases = .empty,
        .credentials = .empty,
    };
    errdefer cfg.deinit(allocator);

    for (doc.credentials) |credential| {
        const key = try allocator.dupe(u8, credential.name);
        errdefer allocator.free(key);
        const environment = try allocator.dupe(u8, credential.env_name);
        errdefer allocator.free(environment);
        try cfg.credentials.put(allocator, key, .{ .env_name = environment });
    }
    for (doc.aliases) |alias| {
        const key = try allocator.dupe(u8, alias.name);
        errdefer allocator.free(key);
        const tokens = try copyStrings(allocator, alias.tokens);
        errdefer freeStrings(allocator, tokens);
        const bindings = try copyStrings(allocator, alias.credential_names);
        errdefer freeStrings(allocator, bindings);
        try cfg.aliases.put(allocator, key, .{ .tokens = tokens, .credential_names = bindings });
    }
    return cfg;
}

pub fn sortedAliasKeys(allocator: std.mem.Allocator, cfg: *const Config) ![][]const u8 {
    return sortedKeys(AliasMap, allocator, &cfg.aliases);
}

pub fn sortedCredentialKeys(allocator: std.mem.Allocator, cfg: *const Config) ![][]const u8 {
    return sortedKeys(CredentialMap, allocator, &cfg.credentials);
}

fn sortedKeys(comptime Map: type, allocator: std.mem.Allocator, map: *const Map) ![][]const u8 {
    var keys = try allocator.alloc([]const u8, map.count());
    var i: usize = 0;
    var copy = map.*;
    var it = copy.iterator();
    while (it.next()) |entry| : (i += 1) keys[i] = entry.key_ptr.*;
    std.mem.sort([]const u8, keys, {}, lessThanString);
    return keys;
}

pub fn validateAliasEnvironments(cfg: *const Config, alias: *const Alias) !void {
    for (alias.credential_names, 0..) |name, i| {
        const environment = cfg.credentials.get(name) orelse return error.DanglingCredentialBinding;
        for (alias.credential_names[0..i]) |prior_name| {
            const prior = cfg.credentials.get(prior_name) orelse return error.DanglingCredentialBinding;
            if (std.mem.eql(u8, prior.env_name, environment.env_name)) return error.DuplicateCredentialEnvironment;
        }
    }
}

fn cloneAlias(allocator: std.mem.Allocator, tokens: []const []const u8, credential_names: []const []const u8) !Alias {
    const owned_tokens = try copyStrings(allocator, tokens);
    errdefer freeStrings(allocator, owned_tokens);
    const owned_bindings = try copyStrings(allocator, credential_names);
    errdefer freeStrings(allocator, owned_bindings);
    return .{ .tokens = owned_tokens, .credential_names = owned_bindings };
}

fn deinitAlias(allocator: std.mem.Allocator, alias: *Alias) void {
    freeStrings(allocator, alias.tokens);
    freeStrings(allocator, alias.credential_names);
    alias.* = undefined;
}

fn lessThanString(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

fn indexOf(values: []const []const u8, needle: []const u8) ?usize {
    for (values, 0..) |value, i| if (std.mem.eql(u8, value, needle)) return i;
    return null;
}

fn copyStrings(allocator: std.mem.Allocator, values: []const []const u8) ![][]const u8 {
    var out = try allocator.alloc([]const u8, values.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |value| allocator.free(value);
        allocator.free(out);
    }
    for (values, 0..) |value, i| {
        out[i] = try allocator.dupe(u8, value);
        initialized += 1;
    }
    return out;
}

fn freeStrings(allocator: std.mem.Allocator, values: [][]const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

test "parse preserves version 1 behavior without rewriting" {
    const allocator = std.testing.allocator;
    var cfg = try parse(allocator, "/tmp/config.toml",
        \\version = 1
        \\
        \\[aliases]
        \\gh = ["echo", "a b", "-x"]
    );
    defer cfg.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 1), cfg.source_version);
    const alias = cfg.aliases.get("gh").?;
    try std.testing.expectEqualStrings("a b", alias.tokens[1]);
    try std.testing.expectEqual(@as(usize, 0), alias.credential_names.len);
}

test "duplicate environment names are rejected at dispatch preflight" {
    const allocator = std.testing.allocator;
    var cfg = try parse(allocator, "/tmp/config.toml",
        \\version = 2
        \\[credentials]
        \\one = "TOKEN"
        \\two = "TOKEN"
        \\[aliases]
        \\gh.tokens = ["echo"]
        \\gh.credentials = ["one", "two"]
    );
    defer cfg.deinit(allocator);
    const alias = cfg.aliases.getPtr("gh").?;
    try std.testing.expectError(error.DuplicateCredentialEnvironment, validateAliasEnvironments(&cfg, alias));
}

test "Config owns Alias Credential and Binding mutations" {
    const allocator = std.testing.allocator;
    var cfg = try parse(allocator, "/tmp/config.toml",
        \\version = 2
        \\[credentials]
        \\op = "OLD_TOKEN"
        \\[aliases]
        \\a.tokens = ["old"]
        \\a.credentials = []
        \\b.tokens = ["echo"]
        \\b.credentials = []
    );
    defer cfg.deinit(allocator);

    try cfg.replaceCredential(allocator, "op", "OP_SERVICE_ACCOUNT_TOKEN");
    try cfg.replaceAlias(allocator, "a", &.{"new"}, &.{"op"});
    try cfg.updateCredentialBindings(allocator, "op", &.{"b"}, true);

    const bound = try cfg.boundAliases(allocator, "op");
    defer allocator.free(bound);
    try std.testing.expectEqual(@as(usize, 2), bound.len);
    try std.testing.expectEqualStrings("a", bound[0]);
    try std.testing.expectEqualStrings("b", bound[1]);
    try std.testing.expectError(error.CredentialInUse, cfg.removeCredential(allocator, "op"));

    try cfg.updateCredentialBindings(allocator, "op", &.{ "a", "b" }, false);
    try cfg.removeCredential(allocator, "op");
    try std.testing.expect(!cfg.credentials.contains("op"));
    try std.testing.expect(cfg.removeAlias(allocator, "a"));
    try std.testing.expect(!cfg.removeAlias(allocator, "a"));
}
