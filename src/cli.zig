const std = @import("std");

const clap = @import("clap");

const config = @import("config.zig");
const main = @import("main.zig");
const paths = @import("paths.zig");
const sys = @import("sys.zig");

const Command = enum {
    add,
    remove,
    sync,
    list,
    path,
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
    .{ .tag = .doctor, .name = "doctor", .usage_args = "", .summary = "Diagnose PATH and shim setup", .run = doctor },
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
    validateName(name) catch |err| {
        main.fail("glolias: invalid alias name '{s}': {s}\n", .{ name, @errorName(err) }, 2);
    };

    var cfg = try config.loadOrInit(allocator);
    defer cfg.deinit(allocator);

    if (cfg.aliases.get(name)) |existing| {
        if (!sameTokens(existing, tokens)) {
            if (!force) {
                main.fail("glolias: alias '{s}' exists with different tokens (use --force)\n", .{name}, 1);
            }
            if (cfg.aliases.fetchOrderedRemove(name)) |old| {
                allocator.free(old.key);
                freeTokens(allocator, old.value);
            }
        } else {
            try config.save(allocator, &cfg);
            try ensureSymlink(allocator, cfg.shims_dir, name);
            return;
        }
    }

    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_tokens = try copyTokens(allocator, tokens);
    errdefer freeTokens(allocator, owned_tokens);
    try cfg.aliases.put(allocator, owned_name, owned_tokens);

    try config.save(allocator, &cfg);
    try ensureSymlink(allocator, cfg.shims_dir, name);
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

    var cfg = config.load(allocator) catch |err| {
        main.fail("glolias: unable to load config: {s}\n", .{@errorName(err)}, 127);
    };
    defer cfg.deinit(allocator);

    const old = cfg.aliases.fetchOrderedRemove(name) orelse {
        main.fail("glolias: no alias '{s}'\n", .{name}, 1);
    };
    allocator.free(old.key);
    freeTokens(allocator, old.value);

    try config.save(allocator, &cfg);

    const link_path = try std.fs.path.join(allocator, &.{ cfg.shims_dir, name });
    defer allocator.free(link_path);
    sys.unlinkPath(allocator, link_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn sync(allocator: std.mem.Allocator, args: []const []const u8) !void {
    parseNoArgCommand(allocator, args, "sync");

    var cfg = config.load(allocator) catch |err| {
        main.fail("glolias: unable to load config: {s}\n", .{@errorName(err)}, 127);
    };
    defer cfg.deinit(allocator);

    try sys.mkdirp(allocator, cfg.shims_dir);

    var it = cfg.aliases.iterator();
    while (it.next()) |entry| {
        try ensureSymlink(allocator, cfg.shims_dir, entry.key_ptr.*);
    }

    const symlinks = try sys.listSymlinks(allocator, cfg.shims_dir);
    defer {
        for (symlinks) |entry_name| allocator.free(entry_name);
        allocator.free(symlinks);
    }

    for (symlinks) |entry_name| {
        if (!cfg.aliases.contains(entry_name)) {
            const path = try std.fs.path.join(allocator, &.{ cfg.shims_dir, entry_name });
            defer allocator.free(path);
            try sys.unlinkPath(allocator, path);
        }
    }
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

fn doctor(allocator: std.mem.Allocator, args: []const []const u8) !void {
    parseNoArgCommand(allocator, args, "doctor");

    try main.stdout(allocator, "doctor: current shell environment only; GUI IDE environments may differ\n", .{});

    var cfg = config.load(allocator) catch |err| {
        try main.stdout(allocator, "config: error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer cfg.deinit(allocator);
    try main.stdout(allocator, "config: ok\n", .{});

    if (sys.isDir(allocator, cfg.shims_dir)) {
        try main.stdout(allocator, "shims_dir: ok: {s}\n", .{cfg.shims_dir});
    } else {
        try main.stdout(allocator, "shims_dir: missing or not a directory: {s}\n", .{cfg.shims_dir});
    }

    const path_value = sys.getenvOwned(allocator, "PATH") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(path_value);

    const shims_index = findPathIndex(allocator, path_value, cfg.shims_dir);
    if (shims_index) |idx| {
        try main.stdout(allocator, "path: shims_dir present at position {d}\n", .{idx});
    } else {
        try main.stdout(allocator, "path: shims_dir is not on PATH\n", .{});
    }

    var aliases = cfg.aliases.iterator();
    while (aliases.next()) |entry| {
        if (findFirstExecutableDir(allocator, path_value, entry.key_ptr.*)) |found| {
            defer allocator.free(found.dir);
            if (shims_index) |idx| {
                if (found.index < idx) {
                    try main.stdout(allocator, "shadowing: {s} is shadowed by {s}/{s}\n", .{ entry.key_ptr.*, found.dir, entry.key_ptr.* });
                }
            }
        }
    }

    const symlinks = sys.listSymlinks(allocator, cfg.shims_dir) catch |err| switch (err) {
        error.OpenDirFailed => {
            try main.stdout(allocator, "orphans: unable to inspect shims_dir\n", .{});
            return;
        },
        else => return err,
    };
    defer {
        for (symlinks) |entry_name| allocator.free(entry_name);
        allocator.free(symlinks);
    }

    var orphan_count: usize = 0;
    for (symlinks) |entry_name| {
        if (!cfg.aliases.contains(entry_name)) {
            orphan_count += 1;
            try main.stdout(allocator, "orphan: {s}\n", .{entry_name});
        }
    }
    if (orphan_count == 0) try main.stdout(allocator, "orphans: none\n", .{});
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
        .help => {},
    }
    switch (info.tag) {
        .add => writer.writeAll(
            \\
            \\Tokens after <name> are stored verbatim; leading-dash args are safe
            \\and not parsed by glolias.
            \\
        ) catch {},
        .doctor => writer.writeAll(
            \\
            \\This diagnosis reflects the current shell environment only; GUI IDE
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

pub fn validateName(name: []const u8) !void {
    if (name.len == 0) return error.EmptyName;
    if (std.mem.eql(u8, name, "glolias")) return error.ReservedName;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return error.ContainsSlash;
    if (name[0] == '-') return error.LeadingDash;
}

fn ensureSymlink(allocator: std.mem.Allocator, shims_dir: []const u8, name: []const u8) !void {
    try sys.mkdirp(allocator, shims_dir);
    const target = try paths.selfExePath(allocator);
    defer allocator.free(target);

    const link_path = try std.fs.path.join(allocator, &.{ shims_dir, name });
    defer allocator.free(link_path);

    sys.unlinkPath(allocator, link_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try sys.symlinkPath(allocator, target, link_path);
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

fn sameTokens(lhs: []const []const u8, rhs: []const []const u8) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |l, r| {
        if (!std.mem.eql(u8, l, r)) return false;
    }
    return true;
}

const FoundExecutable = struct {
    index: usize,
    dir: []const u8,
};

fn findPathIndex(allocator: std.mem.Allocator, path_value: []const u8, needle: []const u8) ?usize {
    var dirs = std.mem.splitScalar(u8, path_value, ':');
    var index: usize = 0;
    while (dirs.next()) |raw_dir| : (index += 1) {
        const dir = if (raw_dir.len == 0) "." else raw_dir;
        if (sameDir(allocator, dir, needle)) return index;
    }
    return null;
}

fn findFirstExecutableDir(allocator: std.mem.Allocator, path_value: []const u8, name: []const u8) ?FoundExecutable {
    var dirs = std.mem.splitScalar(u8, path_value, ':');
    var index: usize = 0;
    while (dirs.next()) |raw_dir| : (index += 1) {
        const dir = if (raw_dir.len == 0) "." else raw_dir;
        const candidate = std.fs.path.join(allocator, &.{ dir, name }) catch return null;
        defer allocator.free(candidate);
        if (sys.isExecutableFile(allocator, candidate)) {
            return .{
                .index = index,
                .dir = allocator.dupe(u8, dir) catch return null,
            };
        }
    }
    return null;
}

fn sameDir(allocator: std.mem.Allocator, lhs: []const u8, rhs: []const u8) bool {
    const lhs_real = sys.realpathAlloc(allocator, lhs) catch return std.mem.eql(u8, lhs, rhs);
    defer allocator.free(lhs_real);
    const rhs_real = sys.realpathAlloc(allocator, rhs) catch return std.mem.eql(u8, lhs, rhs);
    defer allocator.free(rhs_real);
    return std.mem.eql(u8, lhs_real, rhs_real);
}

test "validateName rejects reserved and degenerate names" {
    try std.testing.expectError(error.EmptyName, validateName(""));
    try std.testing.expectError(error.ReservedName, validateName("glolias"));
    try std.testing.expectError(error.ContainsSlash, validateName("a/b"));
    try std.testing.expectError(error.LeadingDash, validateName("-x"));
    try validateName("gh");
}
