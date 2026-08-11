const std = @import("std");

const clap = @import("clap");

const alias_name = @import("alias_name.zig");
const aliases_mod = @import("aliases.zig");
const config = @import("config.zig");
const doctor_mod = @import("doctor.zig");
const main = @import("main.zig");
const paths = @import("paths.zig");
const setup_mod = @import("setup.zig");
const sys = @import("sys.zig");

const Command = enum {
    add,
    remove,
    sync,
    list,
    path,
    setup,
    doctor,
    help,
};

const CmdInfo = struct {
    tag: Command,
    name: []const u8,
    usage_args: []const u8,
    summary: []const u8,
    run: *const fn (std.mem.Allocator, []const []const u8) anyerror!void,
};

const commands = [_]CmdInfo{
    .{ .tag = .add, .name = "add", .usage_args = "[--force] <name> <cmd>...", .summary = "Define an alias + create its shim", .run = add },
    .{ .tag = .remove, .name = "remove", .usage_args = "<name>", .summary = "Delete an alias and its shim", .run = remove },
    .{ .tag = .sync, .name = "sync", .usage_args = "", .summary = "Recreate/prune shims to match config", .run = sync },
    .{ .tag = .list, .name = "list", .usage_args = "[--plain]", .summary = "List configured aliases", .run = list },
    .{ .tag = .path, .name = "path", .usage_args = "", .summary = "Print the shims directory", .run = printPath },
    .{ .tag = .doctor, .name = "doctor", .usage_args = "", .summary = "Check setup; exit 1 on inconsistencies", .run = doctor },
    .{ .tag = .setup, .name = "setup", .usage_args = "[--remove] [--apply]", .summary = "Preview or apply persistent user setup", .run = configureSetup },
};

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
    \\<name>     Alias name (the shim to create).
    \\
);

const add_parsers = .{
    .name = clap.parsers.string,
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
    const result = aliases_mod.add(allocator, name, tokens, force) catch |err| switch (err) {
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
        else => return err,
    };
    switch (result) {
        .added => {},
        .directory_failed => |failure| failDirectoryCreation(allocator, "add", failure),
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

    const result = try aliases_mod.remove(allocator, name);
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
            const tokens = cfg.aliases.get(key).?;
            try writeListPrettyRow(allocator, alias_width, key, tokens);
        }
        return;
    }

    for (keys) |key| {
        const tokens = cfg.aliases.get(key).?;
        try writeListPlainRow(allocator, key, tokens);
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

    try main.stdout(allocator, "doctor: current shell environment only; GUI IDE environments may differ\n", .{});

    const report = try doctor_mod.inspect(allocator);
    defer report.deinit(allocator);

    for (report.findings()) |finding| switch (finding) {
        .config_ok => try main.stdout(allocator, "config: ok\n", .{}),
        .config_error => |error_name| try main.stdout(allocator, "config: error: {s}\n", .{error_name}),
        .shims_dir_ok => |path| try main.stdout(allocator, "shims_dir: ok: {s}\n", .{path}),
        .shims_dir_missing => |path| try main.stdout(allocator, "shims_dir: missing: {s}\n", .{path}),
        .shims_dir_not_directory => |finding_data| try main.stdout(
            allocator,
            "shims_dir: not a directory ({s}): {s}\n",
            .{ pathKindName(finding_data.kind), finding_data.subject },
        ),
        .shims_dir_inspect_error => |finding_data| try main.stdout(
            allocator,
            "shims_dir: unable to inspect: {s}: {s}\n",
            .{ finding_data.subject, finding_data.detail },
        ),
        .path_present => |position| try main.stdout(
            allocator,
            "path: shims_dir present at position {d}\n",
            .{position},
        ),
        .path_missing => {
            try main.stdout(allocator, "path: shims_dir is not on PATH\n", .{});
            try main.stdout(allocator, "guidance: run 'glolias setup' to preview persistent PATH setup\n", .{});
        },
        .shadowing => |finding_data| try main.stdout(
            allocator,
            "shadowing: {s} is shadowed by {s}/{s}\n",
            .{ finding_data.subject, finding_data.detail, finding_data.subject },
        ),
        .binary_error => |error_name| try main.stdout(
            allocator,
            "binary: unable to resolve current glolias binary: {s}\n",
            .{error_name},
        ),
        .shim_missing => |name| try main.stdout(allocator, "shim: {s}: missing\n", .{name}),
        .shim_wrong_kind => |finding_data| try main.stdout(
            allocator,
            "shim: {s}: not a symlink ({s})\n",
            .{ finding_data.subject, pathKindName(finding_data.kind) },
        ),
        .shim_inspect_error => |finding_data| try main.stdout(
            allocator,
            "shim: {s}: unable to inspect: {s}\n",
            .{ finding_data.subject, finding_data.detail },
        ),
        .shim_dangling => |name| try main.stdout(
            allocator,
            "shim: {s}: dangling or unresolvable symlink\n",
            .{name},
        ),
        .shim_wrong_target => |finding_data| try main.stdout(
            allocator,
            "shim: {s}: points to a different glolias binary: {s}\n",
            .{ finding_data.subject, finding_data.detail },
        ),
        .orphan => |name| try main.stdout(allocator, "orphan: {s}\n", .{name}),
        .no_orphans => try main.stdout(allocator, "orphans: none\n", .{}),
        .orphans_skipped => try main.stdout(allocator, "orphans: skipped because config is unavailable\n", .{}),
        .shims_inspect_error => try main.stdout(allocator, "shims: unable to inspect shims_dir\n", .{}),
    };

    if (report.needsShimRepair()) {
        try main.stdout(allocator, "repair: run 'glolias sync' to repair shims (remove blocking files or directories first)\n", .{});
    }

    if (!report.healthy()) {
        try main.stdout(allocator, "doctor: inconsistencies found\n", .{});
        std.process.exit(1);
    }
    try main.stdout(allocator, "doctor: ok\n", .{});
}

fn pathKindName(kind: sys.PathKind) []const u8 {
    return switch (kind) {
        .missing => "missing",
        .symlink => "symlink",
        .directory => "directory",
        .regular_file => "regular file",
        .other => "other file type",
    };
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
    switch (info.tag) {
        .add => {
            writer.writeAll(" ") catch {};
            clap.usage(&writer, clap.Help, &add_params) catch {};
            writer.writeAll(" <cmd>...") catch {};
        },
        .remove => {
            writer.writeAll(" ") catch {};
            clap.usage(&writer, clap.Help, &remove_params) catch {};
        },
        .sync, .path, .doctor => {
            writer.writeAll(" ") catch {};
            clap.usage(&writer, clap.Help, &no_arg_params) catch {};
        },
        .setup => {
            writer.writeAll(" ") catch {};
            clap.usage(&writer, clap.Help, &setup_params) catch {};
        },
        .list => {
            writer.writeAll(" ") catch {};
            clap.usage(&writer, clap.Help, &list_params) catch {};
        },
        .help => {},
    }
    writer.writeAll("\n\n") catch {};
    switch (info.tag) {
        .add => clap.help(&writer, clap.Help, &add_params, helpOptions()) catch {},
        .remove => clap.help(&writer, clap.Help, &remove_params, helpOptions()) catch {},
        .sync, .path, .doctor => clap.help(&writer, clap.Help, &no_arg_params, helpOptions()) catch {},
        .list => clap.help(&writer, clap.Help, &list_params, helpOptions()) catch {},
        .setup => clap.help(&writer, clap.Help, &setup_params, helpOptions()) catch {},
        .help => {},
    }
    switch (info.tag) {
        .add => writer.writeAll(
            \\
            \\Alias names must match [A-Za-z0-9_][A-Za-z0-9_-]*;
            \\'glolias' is reserved.
            \\
            \\Tokens after <name> are stored verbatim; leading-dash args are safe
            \\and not parsed by glolias.
            \\
        ) catch {},
        .setup => writer.writeAll(
            \\
            \\Preview is the default and never changes files. --apply is the sole
            \\authorization to apply the complete preflighted plan. --remove previews
            \\only glolias-owned state; combine it with --apply to remove that state.
            \\
            \\Setup never changes the current PATH or OS session. Applied changes take
            \\effect after a new login/session.
            \\
        ) catch {},
        .doctor => writer.writeAll(
            \\
            \\Runs every inspectable check without changing config, shims, or PATH.
            \\Exits 0 when the setup is healthy and 1 when any inconsistency is found.
            \\Run 'glolias sync' to repair reported shim inconsistencies.
            \\
            \\The diagnosis reflects the current shell environment only; GUI IDE
            \\environments may differ.
            \\
        ) catch {},
        else => {},
    }

    sys.writeAll(fd, writer.buffered()) catch {};
    std.process.exit(code);
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
