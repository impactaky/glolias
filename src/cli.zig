const std = @import("std");

const clap = @import("clap");

const alias_name = @import("alias_name.zig");
const aliases_mod = @import("aliases.zig");
const config = @import("config.zig");
const credential_runner = @import("credential_runner.zig");
const credential_tty = @import("credential_tty.zig");
const credentials_mod = @import("credentials.zig");
const doctor_mod = @import("doctor.zig");
const main = @import("main.zig");
const paths = @import("paths.zig");
const setup_mod = @import("setup.zig");
const sys = @import("sys.zig");

const Command = enum {
    add,
    credential,
    remove,
    sync,
    list,
    path,
    setup,
    doctor,
};

const CmdInfo = struct {
    tag: Command,
    name: []const u8,
    usage_args: []const u8,
    summary: []const u8,
    run: *const fn (std.mem.Allocator, []const []const u8) anyerror!void,
    details: []const u8 = "",
};

const commands = [_]CmdInfo{
    .{ .tag = .add, .name = "add", .usage_args = "[--force] [--credential <credential>]... <name> <cmd>...", .summary = "Define an alias + create its shim", .run = add, .details = add_help_details },
    .{ .tag = .credential, .name = "credential", .usage_args = "<set|attach|detach|list|remove> ...", .summary = "Manage named sealed credentials", .run = credential, .details = credential_help_details },
    .{ .tag = .remove, .name = "remove", .usage_args = "<name>", .summary = "Delete an alias and its shim", .run = remove },
    .{ .tag = .sync, .name = "sync", .usage_args = "", .summary = "Recreate/prune shims to match config", .run = sync },
    .{ .tag = .list, .name = "list", .usage_args = "[--plain]", .summary = "List configured aliases", .run = list },
    .{ .tag = .path, .name = "path", .usage_args = "", .summary = "Print the shims directory", .run = printPath },
    .{ .tag = .doctor, .name = "doctor", .usage_args = "", .summary = "Check setup; exit 1 on inconsistencies", .run = doctor, .details = doctor_help_details },
    .{ .tag = .setup, .name = "setup", .usage_args = "[--remove] [--apply]", .summary = "Preview or apply persistent user setup", .run = configureSetup, .details = setup_help_details },
};

const add_help_details =
    \\
    \\Alias names must match [A-Za-z0-9_][A-Za-z0-9_-]*;
    \\'glolias' is reserved.
    \\
    \\Tokens after <name> are stored verbatim; leading-dash args are safe
    \\and not parsed by glolias.
    \\
;

const credential_help_details =
    \\Credential values are accepted only from /dev/tty with echo disabled.
    \\There is no get, show-secret, or export operation. Run
    \\'glolias credential --help' for lifecycle commands.
    \\
;

const doctor_help_details =
    \\
    \\Runs every inspectable check without changing config, shims, or PATH.
    \\Exits 0 when the setup is healthy and 1 when any inconsistency is found.
    \\Run 'glolias sync' to repair reported shim inconsistencies.
    \\
    \\The diagnosis reflects the current shell environment only; GUI IDE
    \\environments may differ.
    \\
;

const setup_help_details =
    \\
    \\Preview is the default and never changes files. --apply is the sole
    \\authorization to apply the complete preflighted plan. --remove previews
    \\only glolias-owned state; combine it with --apply to remove that state.
    \\
    \\Setup never changes the current PATH or OS session. Applied changes take
    \\effect after a new login/session.
    \\
;

const command_params = clap.parseParamsComptime(
    \\-h, --help  Display help and exit.
    \\<command>
    \\
);

const command_parsers = .{
    .command = clap.parsers.string,
};

const add_params = clap.parseParamsComptime(
    \\-h, --help  Display help for this command and exit.
    \\--force    Replace an existing alias with different tokens.
    \\--credential <credential>...  Bind an existing Credential (repeatable).
    \\<name>     Alias name (the shim to create).
    \\
);

const add_parsers = .{
    .credential = clap.parsers.string,
    .name = clap.parsers.string,
};

const credential_set_params = clap.parseParamsComptime(
    \\-h, --help  Display help for this command and exit.
    \\--force     Allow changing an existing Credential's environment name.
    \\<credential>  Credential name.
    \\<ENV_NAME>    Portable environment-variable name.
    \\
);

const credential_set_parsers = .{
    .credential = clap.parsers.string,
    .ENV_NAME = clap.parsers.string,
};

const credential_binding_params = clap.parseParamsComptime(
    \\-h, --help  Display help for this command and exit.
    \\<credential>  Existing Credential name.
    \\<alias>...    One or more existing Alias names.
    \\
);

const credential_binding_parsers = .{
    .credential = clap.parsers.string,
    .alias = clap.parsers.string,
};

const credential_remove_params = clap.parseParamsComptime(
    \\-h, --help  Display help for this command and exit.
    \\<credential>  Unused Credential name to remove.
    \\
);

const credential_remove_parsers = .{
    .credential = clap.parsers.string,
};

const remove_params = clap.parseParamsComptime(
    \\-h, --help  Display help for this command and exit.
    \\<name>      Alias name to delete.
    \\
);

const remove_parsers = .{
    .name = clap.parsers.string,
};

const no_arg_params = clap.parseParamsComptime(
    \\-h, --help  Display help for this command and exit.
    \\
);

const list_params = clap.parseParamsComptime(
    \\-h, --help   Display help for this command and exit.
    \\--plain      Tab-separated, header-less output for scripts.
    \\
);
const setup_params = clap.parseParamsComptime(
    \\-h, --help  Display help for this command and exit.
    \\--remove    Plan removal of glolias-owned setup state.
    \\--apply     Apply the complete preflighted plan.
    \\
);

const help_params = clap.parseParamsComptime(
    \\-h, --help  Display help and exit.
    \\<command>   Command to show help for.
    \\
);

const help_parsers = .{
    .command = clap.parsers.string,
};

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) topLevelHelp(0);

    var iter = clap.args.SliceIterator{ .args = args };
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &command_params, command_parsers, &iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
        .terminating_positional = 0,
    }) catch |err| failParseWithHelp("glolias", &command_params, diag, err);
    defer res.deinit();

    if (res.args.help != 0) topLevelHelp(0);

    const cmd_text = res.positionals[0] orelse topLevelHelp(0);
    if (std.mem.eql(u8, cmd_text, "help")) {
        return helpCommand(allocator, args[iter.index..]);
    }

    const info = findCommand(cmd_text) orelse {
        main.fail("glolias: unknown command '{s}'\n", .{cmd_text}, 2);
    };
    return info.run(allocator, args[iter.index..]);
}

fn findCommand(cmd: []const u8) ?*const CmdInfo {
    for (&commands) |*info| {
        if (std.mem.eql(u8, cmd, info.name)) return info;
    }
    return null;
}

fn topLevelHelp(code: u8) noreturn {
    const fd: std.c.fd_t = if (code == 0) std.posix.STDOUT_FILENO else std.posix.STDERR_FILENO;
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    writer.writeAll(
        \\glolias — global aliases as PATH-resident shims
        \\
        \\usage:
        \\  glolias <command> [args...]
        \\
        \\commands:
        \\
    ) catch {};

    const width = commandWidth();
    for (commands) |info| {
        writer.writeAll("  ") catch {};
        writer.writeAll(info.name) catch {};
        if (info.usage_args.len != 0) {
            writer.writeAll(" ") catch {};
            writer.writeAll(info.usage_args) catch {};
        }
        const used = info.name.len + @intFromBool(info.usage_args.len != 0) + info.usage_args.len;
        writer.splatByteAll(' ', width - used + 2) catch {};
        writer.writeAll(info.summary) catch {};
        writer.writeByte('\n') catch {};
    }
    writer.writeAll(
        \\
        \\Run 'glolias <command> --help' for details on a command.
        \\
    ) catch {};

    sys.writeAll(fd, writer.buffered()) catch {};
    std.process.exit(code);
}

fn commandWidth() usize {
    var width: usize = 0;
    for (commands) |info| {
        const len = info.name.len + @intFromBool(info.usage_args.len != 0) + info.usage_args.len;
        width = @max(width, len);
    }
    return width;
}

fn helpCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) topLevelHelp(0);

    var iter = clap.args.SliceIterator{ .args = args };
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &help_params, help_parsers, &iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| failParseWithHelp("glolias help", &help_params, diag, err);
    defer res.deinit();

    if (res.args.help != 0) topLevelHelp(0);
    if (iter.index != args.len) failUsageWithHelp("glolias help: expected exactly one command\n", "glolias help", &help_params);

    const cmd_text = res.positionals[0] orelse topLevelHelp(0);
    const info = findCommand(cmd_text) orelse {
        main.fail("glolias: unknown command '{s}'\n", .{cmd_text}, 2);
    };
    commandHelp(info, 0);
}

fn add(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var iter = clap.args.SliceIterator{ .args = args };
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &add_params, add_parsers, &iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
        .terminating_positional = 0,
    }) catch |err| failParseWithHelp("glolias add", &add_params, diag, err);
    defer res.deinit();

    if (res.args.help != 0) commandHelp(findCommand("add").?, 0);

    const force = res.args.force != 0;
    const name = res.positionals[0] orelse {
        failUsageWithHelp("glolias: add requires <name> and <command>\n", "glolias add", &add_params);
    };

    const tokens = args[iter.index..];
    if (tokens.len == 0) {
        failUsageWithHelp("glolias: add requires <name> and <command>\n", "glolias add", &add_params);
    }
    const result = aliases_mod.add(allocator, name, tokens, res.args.credential, force) catch |err| switch (err) {
        error.EmptyName,
        error.ReservedName,
        error.InvalidInitialCharacter,
        error.InvalidCharacter,
        => main.fail("glolias: invalid alias name '{s}': {s}\n", .{ name, alias_name.contract }, 2),
        error.AliasExistsWithDifferentTokens => main.fail(
            "glolias: alias '{s}' exists with different tokens (use --force)\n",
            .{name},
            1,
        ),
        error.CredentialNotFound => main.fail("glolias: add references an unknown Credential\n", .{}, 1),
        error.DuplicateCredentialBinding => main.fail("glolias: add repeats a Credential binding\n", .{}, 2),
        error.ShimTargetBlocked => main.fail("glolias add: shim target is blocked by a non-symlink entry\n", .{}, 1),
        error.UnsafeConfigTarget => main.fail("glolias add: config target is not a regular file\n", .{}, 1),
        else => main.fail("glolias add: mutation failed: {s}\n", .{@errorName(err)}, 1),
    };
    switch (result) {
        .added => {},
        .directory_failed => |failure| failDirectoryCreation(allocator, "add", failure),
    }
}

fn credential(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) credentialHelp(0);
    const subcommand = args[0];
    const rest = args[1..];
    if (std.mem.eql(u8, subcommand, "set")) return credentialSet(allocator, rest);
    if (std.mem.eql(u8, subcommand, "attach")) return credentialBindings(allocator, rest, true);
    if (std.mem.eql(u8, subcommand, "detach")) return credentialBindings(allocator, rest, false);
    if (std.mem.eql(u8, subcommand, "list")) return credentialList(allocator, rest);
    if (std.mem.eql(u8, subcommand, "remove")) return credentialRemove(allocator, rest);
    main.fail("glolias credential: unknown command '{s}'\n", .{subcommand}, 2);
}

fn credentialSet(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var iter = clap.args.SliceIterator{ .args = args };
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &credential_set_params, credential_set_parsers, &iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| failCredentialParse("set", &credential_set_params, diag, err);
    defer res.deinit();
    if (res.args.help != 0) credentialSubcommandHelp("set", &credential_set_params, 0);
    if (iter.index != args.len or res.positionals[0] == null or res.positionals[1] == null) {
        failCredentialUsage("set", &credential_set_params);
    }
    const name = res.positionals[0].?;
    const environment = res.positionals[1].?;
    credentials_mod.preflightSet(allocator, name, environment, res.args.force != 0) catch |err| failCredentialMutation("set", name, err);
    const secret = credential_tty.readSecret(allocator) catch |err| failCredentialMutation("set", name, err);
    defer {
        std.crypto.secureZero(u8, secret);
        allocator.free(secret);
    }
    credentials_mod.set(allocator, name, environment, secret, res.args.force != 0) catch |err| failCredentialMutation("set", name, err);
    try main.stdout(allocator, "credential: {s}: sealed runner installed\n", .{name});
}

fn credentialBindings(allocator: std.mem.Allocator, args: []const []const u8, adding: bool) !void {
    const verb = if (adding) "attach" else "detach";
    var iter = clap.args.SliceIterator{ .args = args };
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &credential_binding_params, credential_binding_parsers, &iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| failCredentialParseDynamic(verb, &credential_binding_params, diag, err);
    defer res.deinit();
    if (res.args.help != 0) credentialSubcommandHelpDynamic(verb, &credential_binding_params, 0);
    const name = res.positionals[0] orelse failCredentialUsageDynamic(verb, &credential_binding_params);
    if (res.positionals[1].len == 0 or iter.index != args.len) failCredentialUsageDynamic(verb, &credential_binding_params);
    if (adding)
        credentials_mod.attach(allocator, name, res.positionals[1]) catch |err| failCredentialMutation(verb, name, err)
    else
        credentials_mod.detach(allocator, name, res.positionals[1]) catch |err| failCredentialMutation(verb, name, err);
}

fn credentialList(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 1 and (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h"))) {
        credentialSubcommandHelp("list", &no_arg_params, 0);
    }
    if (args.len != 0) failCredentialUsage("list", &no_arg_params);
    var cfg = config.loadOrInit(allocator) catch |err| main.fail("glolias credential list: unable to load config: {s}\n", .{@errorName(err)}, 1);
    defer cfg.deinit(allocator);
    const names = try config.sortedCredentialKeys(allocator, &cfg);
    defer allocator.free(names);
    try main.stdout(allocator, "CREDENTIAL\tENVIRONMENT\tALIASES\tSTATUS\n", .{});
    for (names) |name| {
        const metadata = cfg.credentials.get(name).?;
        const bound = try cfg.boundAliases(allocator, name);
        defer allocator.free(bound);
        const runner_path = try paths.credentialRunnerPath(allocator, cfg.credentials_dir, name);
        defer allocator.free(runner_path);
        const status = credential_runner.expectedStatusOrStale(allocator, runner_path, name, metadata.env_name) catch |err| {
            try main.stdout(allocator, "{s}\t{s}\t", .{ name, metadata.env_name });
            try writeJoined(allocator, bound, ",");
            try main.stdout(allocator, "\t{s}\n", .{@errorName(err)});
            continue;
        };
        try main.stdout(allocator, "{s}\t{s}\t", .{ name, metadata.env_name });
        try writeJoined(allocator, bound, ",");
        try main.stdout(allocator, "\t{s}\n", .{@tagName(status)});
    }
}

fn credentialRemove(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var iter = clap.args.SliceIterator{ .args = args };
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &credential_remove_params, credential_remove_parsers, &iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| failCredentialParse("remove", &credential_remove_params, diag, err);
    defer res.deinit();
    if (res.args.help != 0) credentialSubcommandHelp("remove", &credential_remove_params, 0);
    if (iter.index != args.len or res.positionals[0] == null) failCredentialUsage("remove", &credential_remove_params);
    const name = res.positionals[0].?;
    credentials_mod.remove(allocator, name) catch |err| failCredentialMutation("remove", name, err);
    try main.stdout(allocator, "credential: {s}: removed; recovery requires 'credential set' and entering the secret again\n", .{name});
}

fn failCredentialMutation(verb: []const u8, name: []const u8, err: anyerror) noreturn {
    const guidance: []const u8 = switch (err) {
        error.CredentialEnvironmentConflict => "environment name differs; use --force to change it",
        error.CredentialNotFound => "Credential does not exist",
        error.CredentialInUse => "Credential is still attached; detach it first",
        error.AliasNotFound => "one or more Aliases do not exist",
        error.TtyUnavailable => "/dev/tty is unavailable; run from an interactive SSH TTY",
        error.EmptySecret => "empty secrets are refused",
        error.SecretTooLong => "secret exceeds the maximum length",
        error.SecretContainsNul => "secret contains NUL",
        error.RunnerMissingOrUnsafe, error.RunnerMissing => "runner is missing or unsafe; enter the secret again with credential set",
        error.UnsafeCredentialsDirectory => "credentials directory is not a real directory",
        else => @errorName(err),
    };
    main.fail("glolias credential {s}: {s}: {s}\n", .{ verb, name, guidance }, 1);
}

fn writeJoined(allocator: std.mem.Allocator, values: []const []const u8, separator: []const u8) !void {
    for (values, 0..) |value, i| {
        if (i != 0) try main.stdout(allocator, "{s}", .{separator});
        try main.stdout(allocator, "{s}", .{value});
    }
}

fn remove(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var iter = clap.args.SliceIterator{ .args = args };
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &remove_params, remove_parsers, &iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| failParseWithHelp("glolias remove", &remove_params, diag, err);
    defer res.deinit();

    if (res.args.help != 0) commandHelp(findCommand("remove").?, 0);
    if (iter.index != args.len) failUsageWithHelp("glolias: remove requires exactly one alias name\n", "glolias remove", &remove_params);

    const name = res.positionals[0] orelse {
        failUsageWithHelp("glolias: remove requires exactly one alias name\n", "glolias remove", &remove_params);
    };

    const result = aliases_mod.remove(allocator, name) catch |err| switch (err) {
        error.ShimTargetBlocked => main.fail("glolias remove: shim target is blocked by a non-symlink entry\n", .{}, 1),
        error.UnsafeConfigTarget => main.fail("glolias remove: config target is not a regular file\n", .{}, 1),
        else => main.fail("glolias remove: mutation failed: {s}\n", .{@errorName(err)}, 1),
    };
    switch (result) {
        .removed => {},
        .not_found => main.fail("glolias: no alias '{s}'\n", .{name}, 1),
        .load_failed => |err| main.fail("glolias: unable to load config: {s}\n", .{@errorName(err)}, 127),
        .directory_failed => |failure| failDirectoryCreation(allocator, "remove", failure),
    }
}

fn sync(allocator: std.mem.Allocator, args: []const []const u8) !void {
    parseNoArgCommand(allocator, args, "sync");

    const result = try aliases_mod.sync(allocator);
    switch (result) {
        .synced => {},
        .load_failed => |err| main.fail("glolias: unable to load config: {s}\n", .{@errorName(err)}, 127),
        .directory_failed => |failure| failDirectoryCreation(allocator, "sync", failure),
        .credential_failed => |failure| main.fail(
            "glolias sync: Credential '{s}' runner cannot be refreshed: {s}; run 'glolias credential set {s} <ENV_NAME>'\n",
            .{ failure.name, @errorName(failure.err), failure.name },
            1,
        ),
    }
}

fn failDirectoryCreation(
    allocator: std.mem.Allocator,
    command: []const u8,
    failure: aliases_mod.DirectoryFailure,
) noreturn {
    const reason = directoryErrorDescription(failure.err);
    switch (failure.target) {
        .config => {
            const config_path = paths.configFilePath(allocator) catch {
                main.fail(
                    "glolias {s}: cannot create the config directory: {s}; check XDG_CONFIG_HOME or HOME\n",
                    .{ command, reason },
                    1,
                );
            };
            const config_dir = std.fs.path.dirname(config_path) orelse config_path;
            main.fail(
                "glolias {s}: cannot create config directory '{s}': {s}\n",
                .{ command, config_dir, reason },
                1,
            );
        },
        .shims => {
            const shims_dir = paths.defaultShimsDir(allocator) catch {
                main.fail(
                    "glolias {s}: cannot create the shims directory: {s}; check XDG_DATA_HOME or HOME\n",
                    .{ command, reason },
                    1,
                );
            };
            main.fail(
                "glolias {s}: cannot create shims directory '{s}': {s}\n",
                .{ command, shims_dir, reason },
                1,
            );
        },
        .credentials => main.fail(
            "glolias {s}: cannot create credentials directory: {s}\n",
            .{ command, reason },
            1,
        ),
    }
}

fn directoryErrorDescription(err: sys.CreateDirPathError) []const u8 {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.DiskQuota => "disk quota exceeded",
        error.PathAlreadyExists, error.NotDir => "a parent path is not a directory",
        error.SymLinkLoop => "too many symbolic links",
        error.LinkQuotaExceeded => "link quota exceeded",
        error.FileNotFound => "a parent path was not found",
        error.SystemResources => "insufficient system resources",
        error.NoSpaceLeft => "no space left on device",
        error.ReadOnlyFileSystem => "read-only filesystem",
        error.NoDevice => "device is unavailable",
        error.NetworkNotFound => "network path was not found",
        error.NameTooLong => "path is too long",
        error.BadPathName => "invalid path",
        error.Canceled => "operation canceled",
        error.Unexpected => "unexpected filesystem error",
        error.PipeBusy => "pipe is busy",
        error.AntivirusInterference => "antivirus software blocked the operation",
        error.ProcessFdQuotaExceeded => "process file descriptor limit reached",
        error.SystemFdQuotaExceeded => "system file descriptor limit reached",
        error.FileTooBig => "file is too large",
        error.IsDir => "a path component has the wrong file type",
        error.DeviceBusy => "device is busy",
        error.FileLocksUnsupported => "file locking is unsupported",
        error.FileBusy => "file is busy",
        error.WouldBlock => "operation would block",
        error.Streaming => "path refers to a non-file stream",
    };
}

fn list(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var iter = clap.args.SliceIterator{ .args = args };
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &list_params, clap.parsers.default, &iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| failParseWithHelp("glolias list", &list_params, diag, err);
    defer res.deinit();

    if (res.args.help != 0) commandHelp(findCommand("list").?, 0);
    if (iter.index != args.len) failUsageWithHelp("glolias list: unexpected argument\n", "glolias list", &list_params);

    var cfg = config.loadOrInit(allocator) catch |err| {
        main.fail("glolias: unable to load config: {s}\n", .{@errorName(err)}, 127);
    };
    defer cfg.deinit(allocator);

    const keys = try config.sortedAliasKeys(allocator, &cfg);
    defer allocator.free(keys);

    const plain = res.args.plain != 0;
    if (!plain) {
        const alias_width = listAliasWidth(keys);
        try writeListPrettyHeader(allocator, alias_width);
        for (keys) |key| {
            const alias = cfg.aliases.get(key).?;
            try writeListPrettyRow(allocator, alias_width, key, alias.tokens);
        }
        return;
    }

    for (keys) |key| {
        const alias = cfg.aliases.get(key).?;
        try writeListPlainRow(allocator, key, alias.tokens);
    }
}

fn listAliasWidth(keys: []const []const u8) usize {
    var longest_alias: usize = 0;
    for (keys) |key| longest_alias = @max(longest_alias, key.len);
    return @max("ALIAS".len + 3, longest_alias + 2);
}

fn writeListPrettyHeader(allocator: std.mem.Allocator, alias_width: usize) !void {
    try writePaddedCell(allocator, "ALIAS", alias_width);
    try main.stdout(allocator, "COMMAND\n", .{});
}

fn writeListPrettyRow(allocator: std.mem.Allocator, alias_width: usize, key: []const u8, tokens: []const []const u8) !void {
    try writePaddedCell(allocator, key, alias_width);
    try writeJoinedTokens(allocator, tokens);
    try main.stdout(allocator, "\n", .{});
}

fn writeListPlainRow(allocator: std.mem.Allocator, key: []const u8, tokens: []const []const u8) !void {
    try main.stdout(allocator, "{s}\t", .{key});
    try writeJoinedTokens(allocator, tokens);
    try main.stdout(allocator, "\n", .{});
}

fn writePaddedCell(allocator: std.mem.Allocator, text: []const u8, width: usize) !void {
    try main.stdout(allocator, "{s}", .{text});
    var i: usize = text.len;
    while (i < width) : (i += 1) {
        try main.stdout(allocator, " ", .{});
    }
}

fn writeJoinedTokens(allocator: std.mem.Allocator, tokens: []const []const u8) !void {
    for (tokens, 0..) |token, i| {
        if (i > 0) try main.stdout(allocator, " ", .{});
        try main.stdout(allocator, "{s}", .{token});
    }
}

fn printPath(allocator: std.mem.Allocator, args: []const []const u8) !void {
    parseNoArgCommand(allocator, args, "path");

    var cfg = config.loadOrInit(allocator) catch |err| {
        main.fail("glolias: unable to load config: {s}\n", .{@errorName(err)}, 127);
    };
    defer cfg.deinit(allocator);
    try main.stdout(allocator, "{s}\n", .{cfg.shims_dir});
}

fn configureSetup(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var iter = clap.args.SliceIterator{ .args = args };
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &setup_params, clap.parsers.default, &iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| failParseWithHelp("glolias setup", &setup_params, diag, err);
    defer res.deinit();

    if (res.args.help != 0) commandHelp(findCommand("setup").?, 0);
    if (iter.index != args.len or res.args.remove > 1 or res.args.apply > 1) {
        failUsageWithHelp(
            "glolias setup: expected only [--remove] [--apply]\n",
            "glolias setup",
            &setup_params,
        );
    }

    const exit_code = setup_mod.execute(allocator, .{
        .remove = res.args.remove != 0,
        .apply = res.args.apply != 0,
    }) catch |err| switch (err) {
        error.MissingHome => main.fail("glolias setup: HOME is required\n", .{}, 1),
        error.UnsafeHome => main.fail("glolias setup: HOME must resolve to a non-empty absolute path\n", .{}, 1),
        error.UnsafeConfigHome => main.fail("glolias setup: XDG_CONFIG_HOME must resolve to a non-empty absolute path\n", .{}, 1),
        error.UnsafeShimsDir => main.fail("glolias setup: XDG_DATA_HOME must resolve to a non-empty absolute path\n", .{}, 1),
        error.UnsupportedPlatform => main.fail("glolias setup: unsupported platform\n", .{}, 1),
        else => return err,
    };
    if (exit_code != 0) {
        std.process.exit(exit_code);
    }
}

fn doctor(allocator: std.mem.Allocator, args: []const []const u8) !void {
    parseNoArgCommand(allocator, args, "doctor");

    var diagnosis = try doctor_mod.diagnose(allocator);
    defer diagnosis.deinit(allocator);
    try main.stdout(allocator, "{s}", .{diagnosis.text});
    if (!diagnosis.healthy) std.process.exit(1);
}

fn parseNoArgCommand(allocator: std.mem.Allocator, args: []const []const u8, comptime command_name: []const u8) void {
    var iter = clap.args.SliceIterator{ .args = args };
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &no_arg_params, clap.parsers.default, &iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| failParseWithHelp("glolias " ++ command_name, &no_arg_params, diag, err);
    defer res.deinit();

    if (res.args.help != 0) commandHelp(findCommand(command_name).?, 0);
    if (iter.index != args.len) failUsageWithHelp("glolias " ++ command_name ++ ": unexpected argument\n", "glolias " ++ command_name, &no_arg_params);
}

fn commandHelp(info: *const CmdInfo, code: u8) noreturn {
    const fd: std.c.fd_t = if (code == 0) std.posix.STDOUT_FILENO else std.posix.STDERR_FILENO;
    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    writer.print("glolias {s} — {s}\n\n", .{ info.name, info.summary }) catch {};
    writer.print("usage: glolias {s}", .{info.name}) catch {};
    writeCommandParameterHelp(&writer, info.tag);
    writer.writeAll(info.details) catch {};

    sys.writeAll(fd, writer.buffered()) catch {};
    std.process.exit(code);
}

fn writeCommandParameterHelp(writer: *std.Io.Writer, tag: Command) void {
    switch (tag) {
        .add => writeClapCommandParameterHelp(writer, &add_params, " <cmd>..."),
        .credential => {
            writer.writeAll(" <set|attach|detach|list|remove> ...") catch {};
            writer.writeAll("\n\n") catch {};
        },
        .remove => writeClapCommandParameterHelp(writer, &remove_params, ""),
        .sync, .path, .doctor => writeClapCommandParameterHelp(writer, &no_arg_params, ""),
        .setup => writeClapCommandParameterHelp(writer, &setup_params, ""),
        .list => writeClapCommandParameterHelp(writer, &list_params, ""),
    }
}

fn writeClapCommandParameterHelp(
    writer: *std.Io.Writer,
    comptime params: []const clap.Param(clap.Help),
    suffix: []const u8,
) void {
    writer.writeAll(" ") catch {};
    clap.usage(writer, clap.Help, params) catch {};
    writer.writeAll(suffix) catch {};
    writer.writeAll("\n\n") catch {};
    clap.help(writer, clap.Help, params, helpOptions()) catch {};
}

fn credentialHelp(code: u8) noreturn {
    const fd: std.c.fd_t = if (code == 0) std.posix.STDOUT_FILENO else std.posix.STDERR_FILENO;
    const message =
        \\glolias credential — manage named sealed credentials
        \\
        \\usage:
        \\  glolias credential set [--force] <credential> <ENV_NAME>
        \\  glolias credential attach <credential> <alias>...
        \\  glolias credential detach <credential> <alias>...
        \\  glolias credential list
        \\  glolias credential remove <credential>
        \\
        \\Secrets are entered only through /dev/tty with echo disabled. Credential list
        \\shows public metadata and runner health only; glolias has no reveal or export API.
        \\
    ;
    sys.writeAll(fd, message) catch {};
    std.process.exit(code);
}

fn credentialSubcommandHelp(comptime verb: []const u8, comptime params: []const clap.Param(clap.Help), code: u8) noreturn {
    credentialSubcommandHelpDynamic(verb, params, code);
}

fn credentialSubcommandHelpDynamic(verb: []const u8, comptime params: []const clap.Param(clap.Help), code: u8) noreturn {
    const fd: std.c.fd_t = if (code == 0) std.posix.STDOUT_FILENO else std.posix.STDERR_FILENO;
    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    writer.print("usage: glolias credential {s} ", .{verb}) catch {};
    clap.usage(&writer, clap.Help, params) catch {};
    writer.writeAll("\n\n") catch {};
    clap.help(&writer, clap.Help, params, helpOptions()) catch {};
    sys.writeAll(fd, writer.buffered()) catch {};
    std.process.exit(code);
}

fn failCredentialParse(comptime verb: []const u8, comptime params: []const clap.Param(clap.Help), diag: clap.Diagnostic, err: anyerror) noreturn {
    failCredentialParseDynamic(verb, params, diag, err);
}

fn failCredentialParseDynamic(verb: []const u8, comptime params: []const clap.Param(clap.Help), diag: clap.Diagnostic, err: anyerror) noreturn {
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    diag.report(&writer, err) catch {};
    std.debug.print("glolias credential {s}: {s}\n", .{ verb, writer.buffered() });
    credentialSubcommandHelpDynamic(verb, params, 2);
}

fn failCredentialUsage(comptime verb: []const u8, comptime params: []const clap.Param(clap.Help)) noreturn {
    credentialSubcommandHelpDynamic(verb, params, 2);
}

fn failCredentialUsageDynamic(verb: []const u8, comptime params: []const clap.Param(clap.Help)) noreturn {
    credentialSubcommandHelpDynamic(verb, params, 2);
}

fn helpOptions() clap.HelpOptions {
    return .{
        .description_on_new_line = false,
        .description_indent = 3,
        .indent = 2,
        .spacing_between_parameters = 0,
    };
}

fn failParseWithHelp(comptime context: []const u8, comptime params: []const clap.Param(clap.Help), diag: clap.Diagnostic, err: anyerror) noreturn {
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    diag.report(&writer, err) catch {};
    const msg = writer.buffered();
    if (msg.len == 0) {
        std.debug.print("{s}: unable to parse arguments: {s}\n", .{ context, @errorName(err) });
        writeFallbackHelp(context, params);
        std.process.exit(2);
    }
    std.debug.print("{s}: {s}\n", .{ context, msg });
    writeFallbackHelp(context, params);
    std.process.exit(2);
}

fn failUsageWithHelp(comptime message: []const u8, comptime context: []const u8, comptime params: []const clap.Param(clap.Help)) noreturn {
    std.debug.print(message, .{});
    writeFallbackHelp(context, params);
    std.process.exit(2);
}

fn writeFallbackHelp(comptime context: []const u8, comptime params: []const clap.Param(clap.Help)) void {
    if (std.mem.eql(u8, context, "glolias")) {
        topLevelHelp(2);
    }

    const info = commandInfoFromContext(context);
    if (info) |cmd| {
        commandHelp(cmd, 2);
    }

    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    writer.print("usage: {s} ", .{context}) catch {};
    clap.usage(&writer, clap.Help, params) catch {};
    writer.writeAll("\n\n") catch {};
    clap.help(&writer, clap.Help, params, helpOptions()) catch {};
    sys.writeAll(std.posix.STDERR_FILENO, writer.buffered()) catch {};
}

fn commandInfoFromContext(comptime context: []const u8) ?*const CmdInfo {
    inline for (&commands) |*info| {
        if (std.mem.eql(u8, context, "glolias " ++ info.name)) return info;
    }
    return null;
}

test "directory errors have human-readable descriptions" {
    try std.testing.expectEqualStrings("permission denied", directoryErrorDescription(error.AccessDenied));
    try std.testing.expectEqualStrings("a parent path is not a directory", directoryErrorDescription(error.NotDir));
    try std.testing.expectEqualStrings("read-only filesystem", directoryErrorDescription(error.ReadOnlyFileSystem));
    try std.testing.expectEqualStrings("no space left on device", directoryErrorDescription(error.NoSpaceLeft));
}
