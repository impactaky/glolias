const std = @import("std");
const config = @import("config.zig");
const paths = @import("paths.zig");
const sys = @import("sys.zig");

const c = std.c;
const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;

pub const max_secret_len: usize = 8192;
const max_runner_len: usize = 128 * 1024 * 1024;
const format_version: u16 = 1;
const payload_magic = "GLOLIAS-CRED-V1";
const footer_magic = "GLCR-END-V1!";
const footer_len = 8 + footer_magic.len;
const fixed_payload_len = payload_magic.len + 2 + 2 + 2 + 4 + Aead.nonce_length + Aead.key_length + Aead.key_length + Aead.tag_length;

const chain_env = "GLOLIAS_CREDENTIAL_CHAIN";
const dispatcher_env = "GLOLIAS_CREDENTIAL_DISPATCHER";
const ready_env = "GLOLIAS_CREDENTIAL_READY";
const auth_env_prefix = "GLOLIAS_CREDENTIAL_AUTH_";

const Parsed = struct {
    bytes: []u8,
    base_len: usize,
    payload_start: usize,
    name: []const u8,
    env_name: []const u8,
    ciphertext: []const u8,
    nonce: [Aead.nonce_length]u8,
    key_mask: [Aead.key_length]u8,
    masked_key: [Aead.key_length]u8,
    tag: [Aead.tag_length]u8,

    pub fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn trailer(self: *const Parsed) []const u8 {
        return self.bytes[self.base_len..];
    }

    fn recoveryKey(self: *const Parsed) [Aead.key_length]u8 {
        var key: [Aead.key_length]u8 = undefined;
        for (&key, self.key_mask, self.masked_key) |*out, mask, masked| out.* = mask ^ masked;
        return key;
    }

    pub fn decryptSecret(self: *const Parsed, allocator: std.mem.Allocator) ![]u8 {
        var key = self.recoveryKey();
        defer std.crypto.secureZero(u8, &key);
        const aad = try identityAad(allocator, self.name, self.env_name);
        defer allocator.free(aad);
        const secret = try allocator.alloc(u8, self.ciphertext.len);
        errdefer {
            std.crypto.secureZero(u8, secret);
            allocator.free(secret);
        }
        Aead.decrypt(secret, self.ciphertext, self.tag, aad, self.nonce, key) catch return error.RunnerAuthenticationFailed;
        return secret;
    }
};

pub const Status = enum { valid, stale };
pub const AliasDispatch = enum { alias_command, real_command };

pub fn isSelfRunner(allocator: std.mem.Allocator) !bool {
    const self_path = try paths.selfExePath(allocator);
    defer allocator.free(self_path);
    if (try hasFooter(allocator, self_path)) return true;

    const credentials_dir = try paths.defaultCredentialsDir(allocator);
    defer allocator.free(credentials_dir);
    const resolved_dir = sys.realpathAlloc(allocator, credentials_dir) catch return false;
    defer allocator.free(resolved_dir);
    const parent = std.fs.path.dirname(self_path) orelse return false;
    return std.mem.eql(u8, parent, resolved_dir);
}

pub fn create(
    allocator: std.mem.Allocator,
    runner_path: []const u8,
    credential: []const u8,
    environment: []const u8,
    secret: []const u8,
) !void {
    if (secret.len == 0) return error.EmptySecret;
    if (secret.len > max_secret_len) return error.SecretTooLong;
    if (std.mem.indexOfScalar(u8, secret, 0) != null) return error.SecretContainsNul;
    try preflightTarget(allocator, runner_path);

    const self_path = try paths.selfExePath(allocator);
    defer allocator.free(self_path);
    const base = try sys.readFileAlloc(allocator, self_path, max_runner_len);
    defer allocator.free(base);
    if (try hasFooter(allocator, self_path)) return error.RunnerCannotCreateRunner;
    if (std.mem.indexOf(u8, base, secret) != null) return error.SecretMatchesExecutableBytes;

    var attempts: usize = 0;
    while (attempts < 16) : (attempts += 1) {
        const bytes = try buildBytes(allocator, base, credential, environment, secret);
        defer allocator.free(bytes);
        if (std.mem.indexOf(u8, bytes, secret) != null) continue;
        try writeAtomicRunner(allocator, runner_path, bytes);
        return;
    }
    return error.SecretCiphertextCollision;
}

fn inspectExpected(
    allocator: std.mem.Allocator,
    runner_path: []const u8,
    credential: []const u8,
    environment: []const u8,
) !Parsed {
    if (try sys.pathKind(allocator, runner_path) != .regular_file) return error.RunnerNotRegular;
    if (!sys.isExecutableFile(allocator, runner_path)) return error.RunnerNotExecutable;
    var parsed = try parseFile(allocator, runner_path);
    errdefer parsed.deinit(allocator);
    if (!std.mem.eql(u8, parsed.name, credential)) return error.RunnerCredentialMismatch;
    if (!std.mem.eql(u8, parsed.env_name, environment)) return error.RunnerEnvironmentMismatch;
    const secret = try parsed.decryptSecret(allocator);
    std.crypto.secureZero(u8, secret);
    allocator.free(secret);
    return parsed;
}

fn statusAgainstCurrent(allocator: std.mem.Allocator, parsed: *const Parsed) !Status {
    const self_path = try paths.selfExePath(allocator);
    defer allocator.free(self_path);
    const current = try sys.readFileAlloc(allocator, self_path, max_runner_len);
    defer allocator.free(current);
    if (current.len == parsed.base_len and std.mem.eql(u8, current, parsed.bytes[0..parsed.base_len])) return .valid;
    return .stale;
}

pub fn expectedStatus(
    allocator: std.mem.Allocator,
    runner_path: []const u8,
    credential: []const u8,
    environment: []const u8,
) !Status {
    var parsed = try inspectExpected(allocator, runner_path, credential, environment);
    defer parsed.deinit(allocator);
    return statusAgainstCurrent(allocator, &parsed);
}

pub fn expectedStatusOrStale(
    allocator: std.mem.Allocator,
    runner_path: []const u8,
    credential: []const u8,
    environment: []const u8,
) !Status {
    var parsed = try inspectExpected(allocator, runner_path, credential, environment);
    defer parsed.deinit(allocator);
    return statusAgainstCurrent(allocator, &parsed) catch .stale;
}

pub fn refresh(
    allocator: std.mem.Allocator,
    runner_path: []const u8,
    credential: []const u8,
    environment: []const u8,
) !void {
    var parsed = try inspectExpected(allocator, runner_path, credential, environment);
    defer parsed.deinit(allocator);
    if (try statusAgainstCurrent(allocator, &parsed) == .valid) return;
    const self_path = try paths.selfExePath(allocator);
    defer allocator.free(self_path);
    const current = try sys.readFileAlloc(allocator, self_path, max_runner_len);
    defer allocator.free(current);
    const bytes = try std.mem.concat(allocator, u8, &.{ current, parsed.trailer() });
    defer allocator.free(bytes);
    try writeAtomicRunner(allocator, runner_path, bytes);
}

pub fn remove(allocator: std.mem.Allocator, runner_path: []const u8) !void {
    const kind = try sys.pathKind(allocator, runner_path);
    switch (kind) {
        .missing => return error.RunnerMissing,
        .regular_file => try sys.unlinkPath(allocator, runner_path),
        else => return error.UnsafeRunnerTarget,
    }
}

pub fn prepareAliasDispatch(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    alias_name: []const u8,
    alias: *const config.Alias,
    guarded: bool,
    rest_args: []const []const u8,
) !AliasDispatch {
    try config.validateAliasEnvironments(cfg, alias);
    if (try consumeReady(allocator, cfg, alias_name, alias)) return .alias_command;
    if (guarded and try hasActiveAuth(allocator, cfg, alias_name, alias)) return .real_command;
    try beginChain(allocator, cfg, alias_name, alias, rest_args);
}

fn preflightAlias(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    alias: *const config.Alias,
    dispatcher: []const u8,
) !void {
    try config.validateAliasEnvironments(cfg, alias);
    const dispatcher_bytes = try sys.readFileAlloc(allocator, dispatcher, max_runner_len);
    defer allocator.free(dispatcher_bytes);
    for (alias.credential_names) |name| {
        const metadata = cfg.credentials.get(name) orelse return error.DanglingCredentialBinding;
        const path = try paths.credentialRunnerPath(allocator, cfg.credentials_dir, name);
        defer allocator.free(path);
        var parsed = try inspectExpected(allocator, path, name, metadata.env_name);
        defer parsed.deinit(allocator);
        if (dispatcher_bytes.len != parsed.base_len or !std.mem.eql(u8, dispatcher_bytes, parsed.bytes[0..parsed.base_len])) {
            return error.StaleCredentialRunner;
        }
    }
}

fn beginChain(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    alias_name: []const u8,
    alias: *const config.Alias,
    rest_args: []const []const u8,
) !noreturn {
    if (alias.credential_names.len == 0) return error.EmptyCredentialChain;
    const dispatcher = try paths.selfExePath(allocator);
    defer allocator.free(dispatcher);
    try preflightAlias(allocator, cfg, alias, dispatcher);

    var nonce: [16]u8 = undefined;
    try std.Io.Threaded.global_single_threaded.io().randomSecure(&nonce);
    const first_name = alias.credential_names[0];
    const first_meta = cfg.credentials.get(first_name) orelse return error.DanglingCredentialBinding;
    const first_path = try paths.credentialRunnerPath(allocator, cfg.credentials_dir, first_name);
    defer allocator.free(first_path);
    var first = try inspectExpected(allocator, first_path, first_name, first_meta.env_name);
    defer first.deinit(allocator);
    var key = first.recoveryKey();
    defer std.crypto.secureZero(u8, &key);
    const state = try makeChainState(allocator, cfg, alias_name, alias, 0, nonce, dispatcher, key);
    defer allocator.free(state);
    try sys.setenvOwned(allocator, dispatcher_env, dispatcher);
    try sys.setenvOwned(allocator, chain_env, state);
    try sys.setenvOwned(allocator, ready_env, "");

    const argv = try makeArgv(allocator, alias_name, rest_args);
    sys.execvPath(std.heap.page_allocator, first_path, argv);
}

pub fn run(allocator: std.mem.Allocator, argv: []const []const u8) !noreturn {
    const self_path = try paths.selfExePath(allocator);
    defer allocator.free(self_path);
    var self = try parseFile(allocator, self_path);
    defer self.deinit(allocator);

    const dispatcher = try sys.getenvOwned(allocator, dispatcher_env);
    defer allocator.free(dispatcher);
    const chain_text = try sys.getenvOwned(allocator, chain_env);
    defer allocator.free(chain_text);
    const state = try parseChainState(chain_text);

    var cfg = try config.load(allocator);
    defer cfg.deinit(allocator);
    const alias = cfg.aliases.getPtr(state.alias) orelse return error.UnauthorizedCredentialRunner;
    try config.validateAliasEnvironments(&cfg, alias);
    if (state.index >= alias.credential_names.len) return error.InvalidCredentialChain;
    const expected_name = alias.credential_names[state.index];
    const metadata = cfg.credentials.get(expected_name) orelse return error.DanglingCredentialBinding;
    if (!std.mem.eql(u8, expected_name, self.name) or !std.mem.eql(u8, metadata.env_name, self.env_name)) {
        return error.UnauthorizedCredentialRunner;
    }

    const dispatcher_bytes = try sys.readFileAlloc(allocator, dispatcher, max_runner_len);
    defer allocator.free(dispatcher_bytes);
    if (dispatcher_bytes.len != self.base_len or !std.mem.eql(u8, dispatcher_bytes, self.bytes[0..self.base_len])) {
        return error.StaleCredentialRunner;
    }
    var key = self.recoveryKey();
    defer std.crypto.secureZero(u8, &key);
    try verifyChainState(allocator, &cfg, state, alias, dispatcher, key);

    const secret = try self.decryptSecret(allocator);
    defer {
        std.crypto.secureZero(u8, secret);
        allocator.free(secret);
    }
    try sys.setenvOwned(allocator, self.env_name, secret);

    const next_index = state.index + 1;
    if (next_index < alias.credential_names.len) {
        const next_name = alias.credential_names[next_index];
        const next_meta = cfg.credentials.get(next_name) orelse return error.DanglingCredentialBinding;
        const next_path = try paths.credentialRunnerPath(allocator, cfg.credentials_dir, next_name);
        defer allocator.free(next_path);
        var next = try inspectExpected(allocator, next_path, next_name, next_meta.env_name);
        defer next.deinit(allocator);
        if (next.base_len != dispatcher_bytes.len or !std.mem.eql(u8, next.bytes[0..next.base_len], dispatcher_bytes)) {
            return error.StaleCredentialRunner;
        }
        var next_key = next.recoveryKey();
        defer std.crypto.secureZero(u8, &next_key);
        const next_state = try makeChainState(allocator, &cfg, state.alias, alias, next_index, state.nonce, dispatcher, next_key);
        defer allocator.free(next_state);
        try sys.setenvOwned(allocator, chain_env, next_state);
        sys.execvPath(std.heap.page_allocator, next_path, argv);
    }

    const first_name = alias.credential_names[0];
    const first_meta = cfg.credentials.get(first_name) orelse return error.DanglingCredentialBinding;
    const first_path = try paths.credentialRunnerPath(allocator, cfg.credentials_dir, first_name);
    defer allocator.free(first_path);
    var first = try inspectExpected(allocator, first_path, first_name, first_meta.env_name);
    defer first.deinit(allocator);
    var first_key = first.recoveryKey();
    defer std.crypto.secureZero(u8, &first_key);
    const auth_value = try makeAuthValue(allocator, &cfg, state.alias, alias, state.nonce, dispatcher, first_key);
    defer allocator.free(auth_value);
    const auth_name = try authEnvName(allocator, state.alias);
    defer allocator.free(auth_name);
    try sys.setenvOwned(allocator, auth_name, auth_value);
    try sys.setenvOwned(allocator, ready_env, state.alias);
    try sys.setenvOwned(allocator, chain_env, "");
    sys.execvPath(std.heap.page_allocator, dispatcher, argv);
}

fn consumeReady(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    alias_name: []const u8,
    alias: *const config.Alias,
) !bool {
    const ready = sys.getenvOwned(allocator, ready_env) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return false,
        else => return err,
    };
    defer allocator.free(ready);
    if (!std.mem.eql(u8, ready, alias_name)) return false;
    if (!try hasActiveAuth(allocator, cfg, alias_name, alias)) return error.InvalidCredentialChain;
    try sys.setenvOwned(allocator, ready_env, "");
    return true;
}

fn hasActiveAuth(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    alias_name: []const u8,
    alias: *const config.Alias,
) !bool {
    if (alias.credential_names.len == 0) return false;
    const auth_name = try authEnvName(allocator, alias_name);
    defer allocator.free(auth_name);
    const value = sys.getenvOwned(allocator, auth_name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return false,
        else => return err,
    };
    defer allocator.free(value);
    const auth = parseAuthValue(value) catch return false;
    const dispatcher = sys.getenvOwned(allocator, dispatcher_env) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return false,
        else => return err,
    };
    defer allocator.free(dispatcher);
    const first_name = alias.credential_names[0];
    const first_meta = cfg.credentials.get(first_name) orelse return error.DanglingCredentialBinding;
    const path = try paths.credentialRunnerPath(allocator, cfg.credentials_dir, first_name);
    defer allocator.free(path);
    var first = inspectExpected(allocator, path, first_name, first_meta.env_name) catch return false;
    defer first.deinit(allocator);
    var key = first.recoveryKey();
    defer std.crypto.secureZero(u8, &key);
    const expected = try authMac(allocator, cfg, alias_name, alias, auth.nonce, dispatcher, key);
    return std.crypto.timing_safe.eql([Hmac.mac_length]u8, expected, auth.mac);
}

fn buildBytes(
    allocator: std.mem.Allocator,
    base: []const u8,
    credential: []const u8,
    environment: []const u8,
    secret: []const u8,
) ![]u8 {
    if (credential.len > std.math.maxInt(u16) or environment.len > std.math.maxInt(u16) or secret.len > std.math.maxInt(u32)) {
        return error.RunnerFieldTooLong;
    }
    var key: [Aead.key_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    var mask: [Aead.key_length]u8 = undefined;
    var nonce: [Aead.nonce_length]u8 = undefined;
    const io = std.Io.Threaded.global_single_threaded.io();
    try io.randomSecure(&key);
    try io.randomSecure(&mask);
    try io.randomSecure(&nonce);
    var masked: [Aead.key_length]u8 = undefined;
    for (&masked, key, mask) |*out, key_byte, mask_byte| out.* = key_byte ^ mask_byte;
    const ciphertext = try allocator.alloc(u8, secret.len);
    defer allocator.free(ciphertext);
    var tag: [Aead.tag_length]u8 = undefined;
    const aad = try identityAad(allocator, credential, environment);
    defer allocator.free(aad);
    Aead.encrypt(ciphertext, &tag, secret, aad, nonce, key);

    const payload_len = fixed_payload_len + credential.len + environment.len + ciphertext.len;
    var out = try allocator.alloc(u8, base.len + payload_len + footer_len);
    errdefer allocator.free(out);
    @memcpy(out[0..base.len], base);
    var cursor = base.len;
    copyAdvance(out, &cursor, payload_magic);
    writeIntAdvance(u16, out, &cursor, format_version);
    writeIntAdvance(u16, out, &cursor, @intCast(credential.len));
    writeIntAdvance(u16, out, &cursor, @intCast(environment.len));
    writeIntAdvance(u32, out, &cursor, @intCast(ciphertext.len));
    copyAdvance(out, &cursor, &nonce);
    copyAdvance(out, &cursor, &mask);
    copyAdvance(out, &cursor, &masked);
    copyAdvance(out, &cursor, &tag);
    copyAdvance(out, &cursor, credential);
    copyAdvance(out, &cursor, environment);
    copyAdvance(out, &cursor, ciphertext);
    writeIntAdvance(u64, out, &cursor, payload_len);
    copyAdvance(out, &cursor, footer_magic);
    std.debug.assert(cursor == out.len);
    return out;
}

fn parseFile(allocator: std.mem.Allocator, path: []const u8) !Parsed {
    const bytes = try sys.readFileAlloc(allocator, path, max_runner_len);
    errdefer allocator.free(bytes);
    if (bytes.len < footer_len or !std.mem.eql(u8, bytes[bytes.len - footer_magic.len ..], footer_magic)) return error.NotCredentialRunner;
    const payload_len = std.mem.readInt(u64, bytes[bytes.len - footer_len ..][0..8], .little);
    if (payload_len > bytes.len - footer_len or payload_len < fixed_payload_len) return error.MalformedCredentialRunner;
    const base_len = bytes.len - footer_len - @as(usize, @intCast(payload_len));
    const payload = bytes[base_len .. bytes.len - footer_len];
    var cursor: usize = 0;
    if (!takeEquals(payload, &cursor, payload_magic)) return error.MalformedCredentialRunner;
    const version = try readIntAdvance(u16, payload, &cursor);
    if (version != format_version) return error.UnsupportedRunnerVersion;
    const name_len = try readIntAdvance(u16, payload, &cursor);
    const env_len = try readIntAdvance(u16, payload, &cursor);
    const cipher_len = try readIntAdvance(u32, payload, &cursor);
    const nonce = try takeArray(Aead.nonce_length, payload, &cursor);
    const mask = try takeArray(Aead.key_length, payload, &cursor);
    const masked = try takeArray(Aead.key_length, payload, &cursor);
    const tag = try takeArray(Aead.tag_length, payload, &cursor);
    const name = try take(payload, &cursor, name_len);
    const environment = try take(payload, &cursor, env_len);
    const ciphertext = try take(payload, &cursor, cipher_len);
    if (cursor != payload.len or name.len == 0 or environment.len == 0 or ciphertext.len == 0) return error.MalformedCredentialRunner;
    return .{
        .bytes = bytes,
        .base_len = base_len,
        .payload_start = base_len,
        .name = name,
        .env_name = environment,
        .ciphertext = ciphertext,
        .nonce = nonce,
        .key_mask = mask,
        .masked_key = masked,
        .tag = tag,
    };
}

fn hasFooter(allocator: std.mem.Allocator, path: []const u8) !bool {
    const z_path = try allocator.dupeZ(u8, path);
    defer allocator.free(z_path);
    const fd = c.open(z_path.ptr, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    const end = c.lseek(fd, 0, c.SEEK.END);
    if (end < footer_magic.len) return false;
    if (c.lseek(fd, end - footer_magic.len, c.SEEK.SET) < 0) return error.SeekFailed;
    var magic: [footer_magic.len]u8 = undefined;
    const count = c.read(fd, &magic, magic.len);
    return count == magic.len and std.mem.eql(u8, &magic, footer_magic);
}

fn preflightTarget(allocator: std.mem.Allocator, path: []const u8) !void {
    switch (try sys.pathKind(allocator, path)) {
        .missing, .regular_file => {},
        else => return error.UnsafeRunnerTarget,
    }
    if (std.fs.path.dirname(path)) |parent| try sys.mkdirp(parent);
}

fn writeAtomicRunner(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    try preflightTarget(allocator, path);
    try sys.writeFileAtomicMode(path, bytes, 0o500);
}

const ChainState = struct {
    alias: []const u8,
    index: usize,
    nonce: [16]u8,
    mac: [Hmac.mac_length]u8,
};

fn makeChainState(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    alias_name: []const u8,
    alias: *const config.Alias,
    index: usize,
    nonce: [16]u8,
    dispatcher: []const u8,
    key: [Aead.key_length]u8,
) ![]const u8 {
    const mac = try chainMac(allocator, cfg, alias_name, alias, index, nonce, dispatcher, key);
    const nonce_hex = std.fmt.bytesToHex(nonce, .lower);
    const mac_hex = std.fmt.bytesToHex(mac, .lower);
    return std.fmt.allocPrint(allocator, "v1:{s}:{d}:{s}:{s}", .{ alias_name, index, &nonce_hex, &mac_hex });
}

fn parseChainState(value: []const u8) !ChainState {
    var parts = std.mem.splitScalar(u8, value, ':');
    if (!std.mem.eql(u8, parts.next() orelse return error.InvalidCredentialChain, "v1")) return error.InvalidCredentialChain;
    const alias = parts.next() orelse return error.InvalidCredentialChain;
    const index = try std.fmt.parseInt(usize, parts.next() orelse return error.InvalidCredentialChain, 10);
    const nonce = try parseHexArray(16, parts.next() orelse return error.InvalidCredentialChain);
    const mac = try parseHexArray(Hmac.mac_length, parts.next() orelse return error.InvalidCredentialChain);
    if (parts.next() != null) return error.InvalidCredentialChain;
    return .{ .alias = alias, .index = index, .nonce = nonce, .mac = mac };
}

fn verifyChainState(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    state: ChainState,
    alias: *const config.Alias,
    dispatcher: []const u8,
    key: [Aead.key_length]u8,
) !void {
    const expected = try chainMac(allocator, cfg, state.alias, alias, state.index, state.nonce, dispatcher, key);
    if (!std.crypto.timing_safe.eql([Hmac.mac_length]u8, expected, state.mac)) return error.InvalidCredentialChain;
}

fn chainMac(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    alias_name: []const u8,
    alias: *const config.Alias,
    index: usize,
    nonce: [16]u8,
    dispatcher: []const u8,
    key: [Aead.key_length]u8,
) ![Hmac.mac_length]u8 {
    var message = std.ArrayList(u8).empty;
    defer message.deinit(allocator);
    try message.appendSlice(allocator, "chain\x00");
    try appendAuthContext(&message, allocator, cfg, alias_name, alias, nonce, dispatcher);
    try message.print(allocator, "\x00{d}", .{index});
    var mac: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&mac, message.items, &key);
    return mac;
}

fn makeAuthValue(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    alias_name: []const u8,
    alias: *const config.Alias,
    nonce: [16]u8,
    dispatcher: []const u8,
    key: [Aead.key_length]u8,
) ![]const u8 {
    const mac = try authMac(allocator, cfg, alias_name, alias, nonce, dispatcher, key);
    const nonce_hex = std.fmt.bytesToHex(nonce, .lower);
    const mac_hex = std.fmt.bytesToHex(mac, .lower);
    return std.fmt.allocPrint(allocator, "v1:{s}:{s}", .{ &nonce_hex, &mac_hex });
}

const AuthValue = struct { nonce: [16]u8, mac: [Hmac.mac_length]u8 };

fn parseAuthValue(value: []const u8) !AuthValue {
    var parts = std.mem.splitScalar(u8, value, ':');
    if (!std.mem.eql(u8, parts.next() orelse return error.InvalidAuth, "v1")) return error.InvalidAuth;
    const nonce = try parseHexArray(16, parts.next() orelse return error.InvalidAuth);
    const mac = try parseHexArray(Hmac.mac_length, parts.next() orelse return error.InvalidAuth);
    if (parts.next() != null) return error.InvalidAuth;
    return .{ .nonce = nonce, .mac = mac };
}

fn authMac(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    alias_name: []const u8,
    alias: *const config.Alias,
    nonce: [16]u8,
    dispatcher: []const u8,
    key: [Aead.key_length]u8,
) ![Hmac.mac_length]u8 {
    var message = std.ArrayList(u8).empty;
    defer message.deinit(allocator);
    try message.appendSlice(allocator, "active\x00");
    try appendAuthContext(&message, allocator, cfg, alias_name, alias, nonce, dispatcher);
    var mac: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&mac, message.items, &key);
    return mac;
}

fn appendAuthContext(
    message: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    alias_name: []const u8,
    alias: *const config.Alias,
    nonce: [16]u8,
    dispatcher: []const u8,
) !void {
    try message.appendSlice(allocator, alias_name);
    try message.append(allocator, 0);
    try message.appendSlice(allocator, &nonce);
    try message.append(allocator, 0);
    try message.appendSlice(allocator, dispatcher);
    for (alias.credential_names) |name| {
        const metadata = cfg.credentials.get(name) orelse return error.DanglingCredentialBinding;
        try message.append(allocator, 0);
        try message.appendSlice(allocator, name);
        try message.append(allocator, '=');
        try message.appendSlice(allocator, metadata.env_name);
    }
}

fn authEnvName(allocator: std.mem.Allocator, alias_name: []const u8) ![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(alias_name, &digest, .{});
    const encoded = std.fmt.bytesToHex(digest[0..12].*, .lower);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ auth_env_prefix, &encoded });
}

fn identityAad(allocator: std.mem.Allocator, credential: []const u8, environment: []const u8) ![]const u8 {
    return std.mem.concat(allocator, u8, &.{ payload_magic, "\x00", credential, "\x00", environment });
}

fn makeArgv(allocator: std.mem.Allocator, arg0: []const u8, rest: []const []const u8) ![][]const u8 {
    var argv = try allocator.alloc([]const u8, rest.len + 1);
    argv[0] = try allocator.dupe(u8, arg0);
    for (rest, 0..) |arg, i| argv[i + 1] = try allocator.dupe(u8, arg);
    return argv;
}

fn parseHexArray(comptime len: usize, text: []const u8) ![len]u8 {
    if (text.len != len * 2) return error.InvalidHex;
    var out: [len]u8 = undefined;
    for (&out, 0..) |*byte, i| byte.* = try std.fmt.parseInt(u8, text[i * 2 .. i * 2 + 2], 16);
    return out;
}

fn copyAdvance(out: []u8, cursor: *usize, value: []const u8) void {
    @memcpy(out[cursor.* .. cursor.* + value.len], value);
    cursor.* += value.len;
}

fn writeIntAdvance(comptime T: type, out: []u8, cursor: *usize, value: T) void {
    std.mem.writeInt(T, out[cursor.*..][0..@sizeOf(T)], value, .little);
    cursor.* += @sizeOf(T);
}

fn readIntAdvance(comptime T: type, input: []const u8, cursor: *usize) !T {
    const bytes = try take(input, cursor, @sizeOf(T));
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

fn take(input: []const u8, cursor: *usize, count: usize) ![]const u8 {
    if (count > input.len -| cursor.*) return error.MalformedCredentialRunner;
    const value = input[cursor.* .. cursor.* + count];
    cursor.* += count;
    return value;
}

fn takeArray(comptime len: usize, input: []const u8, cursor: *usize) ![len]u8 {
    const value = try take(input, cursor, len);
    return value[0..len].*;
}

fn takeEquals(input: []const u8, cursor: *usize, expected: []const u8) bool {
    const value = take(input, cursor, expected.len) catch return false;
    return std.mem.eql(u8, value, expected);
}

test "runner trailer encrypts identity-bound synthetic secrets" {
    const allocator = std.testing.allocator;
    const base = "synthetic executable bytes";
    const secret = "SYNTHETIC_SECRET_DO_NOT_USE_123";
    const bytes = try buildBytes(allocator, base, "op", "OP_TOKEN", secret);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, secret) == null);
}

test "Runner atomic write rejects unsafe targets and installs mode 0500" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const parent = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer allocator.free(parent);
    const unsafe = try std.fs.path.join(allocator, &.{ parent, "unsafe" });
    defer allocator.free(unsafe);
    const runner = try std.fs.path.join(allocator, &.{ parent, "runner" });
    defer allocator.free(runner);

    try std.Io.Dir.cwd().createDir(io, unsafe, .fromMode(0o755));
    try std.testing.expectError(error.UnsafeRunnerTarget, writeAtomicRunner(allocator, unsafe, "bytes"));
    try writeAtomicRunner(allocator, runner, "bytes");
    try std.Io.Dir.cwd().setFilePermissions(io, runner, .fromMode(0o700), .{});
    try writeAtomicRunner(allocator, runner, "replacement");
    const info = try std.Io.Dir.cwd().statFile(io, runner, .{});
    try std.testing.expectEqual(@as(u32, 0o500), info.permissions.toMode() & 0o777);
}
