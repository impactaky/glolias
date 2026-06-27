const std = @import("std");
const config_toml = @import("config_toml.zig");

const paths = @import("paths.zig");
const sys = @import("sys.zig");

pub const AliasMap = std.StringArrayHashMapUnmanaged([][]const u8);

pub const Config = struct {
    version: u32 = 1,
    config_path: []const u8,
    shims_dir: []const u8,
    aliases: AliasMap,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.config_path);
        allocator.free(self.shims_dir);

        var it = self.aliases.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.*) |token| allocator.free(token);
            allocator.free(entry.value_ptr.*);
        }
        self.aliases.deinit(allocator);
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
            break :blk Config{
                .config_path = config_path,
                .shims_dir = shims_dir,
                .aliases = .empty,
            };
        },
        else => return err,
    };
}

pub fn save(allocator: std.mem.Allocator, cfg: *const Config) !void {
    try paths.ensureParentDir(allocator, cfg.config_path);

    const keys = try sortedAliasKeys(allocator, cfg);
    defer allocator.free(keys);

    var aliases = try allocator.alloc(config_toml.AliasView, keys.len);
    defer allocator.free(aliases);
    for (keys, 0..) |key, i| {
        aliases[i] = .{
            .name = key,
            .tokens = cfg.aliases.get(key).?,
        };
    }

    const out = try config_toml.serializeConfig(allocator, cfg.version, aliases);
    defer allocator.free(out);
    try sys.writeFileTruncate(allocator, cfg.config_path, out);
}

pub fn parse(allocator: std.mem.Allocator, config_path: []const u8, text: []const u8) !Config {
    var doc = try config_toml.parseConfig(allocator, text);
    defer doc.deinit(allocator);

    if (doc.version != 1) return error.UnsupportedConfigVersion;

    var cfg = Config{
        .version = doc.version,
        .config_path = try allocator.dupe(u8, config_path),
        .shims_dir = try paths.defaultShimsDir(allocator),
        .aliases = .empty,
    };
    errdefer cfg.deinit(allocator);

    for (doc.aliases) |alias| {
        const owned_key = try allocator.dupe(u8, alias.name);
        errdefer allocator.free(owned_key);
        const tokens = try copyTokens(allocator, alias.tokens);
        errdefer freeTokens(allocator, tokens);
        try cfg.aliases.put(allocator, owned_key, tokens);
    }

    return cfg;
}

pub fn sortedAliasKeys(allocator: std.mem.Allocator, cfg: *const Config) ![][]const u8 {
    var keys = try allocator.alloc([]const u8, cfg.aliases.count());
    var i: usize = 0;
    var it = cfg.aliases.iterator();
    while (it.next()) |entry| : (i += 1) keys[i] = entry.key_ptr.*;
    std.mem.sort([]const u8, keys, {}, lessThanString);
    return keys;
}

fn lessThanString(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

fn copyTokens(allocator: std.mem.Allocator, tokens: []const []const u8) ![][]const u8 {
    var out = try allocator.alloc([]const u8, tokens.len);
    errdefer allocator.free(out);
    for (tokens, 0..) |token, i| {
        out[i] = try allocator.dupe(u8, token);
    }
    return out;
}

fn freeTokens(allocator: std.mem.Allocator, tokens: [][]const u8) void {
    for (tokens) |token| allocator.free(token);
    allocator.free(tokens);
}

test "parse preserves token boundaries" {
    const allocator = std.testing.allocator;
    var cfg = try parse(allocator, "/tmp/config.toml",
        \\version = 1
        \\
        \\[aliases]
        \\gh = ["echo", "a b", "-x"]
    );
    defer cfg.deinit(allocator);

    const expected = try paths.defaultShimsDir(allocator);
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, cfg.shims_dir);
    const tokens = cfg.aliases.get("gh").?;
    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expectEqualStrings("a b", tokens[1]);
}

test "parse rejects shims_dir in config" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidConfig, parse(allocator, "/tmp/config.toml",
        \\version = 1
        \\shims_dir = "/tmp/machine-specific"
        \\
        \\[aliases]
        \\gh = ["echo", "hi"]
    ));
}
