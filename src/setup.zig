const std = @import("std");
const builtin = @import("builtin");

const paths = @import("paths.zig");
const sys = @import("sys.zig");

const start_marker = "# >>> glolias setup v1 >>>";
const end_marker = "# <<< glolias setup v1 <<<";
const environment_file_name = "60-glolias.conf";
const launch_agent_name = "com.github.impactaky.glolias-path.plist";

const Platform = enum {
    linux,
    macos,
};

const Mode = enum {
    add,
    remove,
};

const TargetKind = enum {
    profile,
    owned_file,
};

const Action = enum {
    create,
    update,
    remove,
    no_op,
    conflict,
};

const Facts = struct {
    platform: Platform,
    home: []const u8,
    config_home: []const u8,
    shims_dir: []const u8,
    systemd_user: bool,
};

const FactsError = error{
    UnsafeHome,
    UnsafeConfigHome,
    UnsafeShimsDir,
};

const Target = struct {
    label: []const u8,
    path: []const u8,
    kind: TargetKind,
    action: Action,
    before_kind: sys.PathKind,
    before_content: ?[]const u8,
    after_content: ?[]const u8,
    display_content: ?[]const u8,
    detail: []const u8,

    fn deinit(self: *Target, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.path);
        if (self.before_content) |value| allocator.free(value);
        if (self.after_content) |value| allocator.free(value);
        if (self.display_content) |value| allocator.free(value);
        allocator.free(self.detail);
        self.* = undefined;
    }
};

const Plan = struct {
    mode: Mode,
    platform: Platform,
    targets: std.ArrayList(Target) = .empty,
    manuals: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        for (self.targets.items) |*target| target.deinit(allocator);
        self.targets.deinit(allocator);
        for (self.manuals.items) |manual| allocator.free(manual);
        self.manuals.deinit(allocator);
        self.* = undefined;
    }

    fn hasConflicts(self: *const Plan) bool {
        for (self.targets.items) |target| {
            if (target.action == .conflict) return true;
        }
        return false;
    }

    fn changeCount(self: *const Plan) usize {
        var count: usize = 0;
        for (self.targets.items) |target| {
            if (isMutation(target.action)) count += 1;
        }
        return count;
    }
};

const Snapshot = struct {
    kind: sys.PathKind,
    content: ?[]const u8 = null,

    fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        if (self.content) |value| allocator.free(value);
        self.* = undefined;
    }
};

const ProfileState = union(enum) {
    absent,
    valid: struct {
        block_start: usize,
        block_end: usize,
        owned_start: usize,
    },
    malformed,
};

const ApplyOptions = struct {
    fail_before_target_index: ?usize = null,
};

const ApplyFailure = struct {
    target_index: usize,
    applied_changes: usize,
    err: anyerror,
};

const ApplyResult = union(enum) {
    success: usize,
    preflight_changed: usize,
    failed: ApplyFailure,
};

pub const ExecuteOptions = struct {
    remove: bool = false,
    apply: bool = false,
};

pub fn execute(allocator: std.mem.Allocator, options: ExecuteOptions) !u8 {
    const home = sys.getenvOwned(allocator, "HOME") catch return error.MissingHome;
    defer allocator.free(home);
    const config_home = sys.getenvOwned(allocator, "XDG_CONFIG_HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try std.fs.path.join(allocator, &.{ home, ".config" }),
        else => return err,
    };
    defer allocator.free(config_home);
    const shims_dir = try paths.defaultShimsDir(allocator);
    defer allocator.free(shims_dir);

    const platform: Platform = switch (builtin.os.tag) {
        .linux => .linux,
        .macos => .macos,
        else => return error.UnsupportedPlatform,
    };
    const mode: Mode = if (options.remove) .remove else .add;
    var plan = try buildPlan(allocator, .{
        .platform = platform,
        .home = home,
        .config_home = config_home,
        .shims_dir = shims_dir,
        .systemd_user = systemdUserAvailable(allocator),
    }, mode);
    defer plan.deinit(allocator);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const writer = &output.writer;

    try writePlan(writer, &plan, options.apply);
    try flushOutput(&output);
    if (plan.hasConflicts()) {
        try writer.writeAll("setup: conflict; no files changed\n");
        try flushOutput(&output);
        return 1;
    }
    if (!options.apply) {
        try writer.writeAll("setup: preview complete; no files changed. Re-run with --apply to authorize this exact plan.\n");
        try flushOutput(&output);
        return 0;
    }

    const exit_code: u8 = switch (applyPlan(&plan, allocator, .{})) {
        .success => |count| blk: {
            if (count == 0) {
                try writer.writeAll("setup: apply complete; everything was already in the requested state\n");
            } else {
                try writer.print("setup: apply complete; {d} atomic file action(s) applied\n", .{count});
            }
            try writer.writeAll(
                "setup: the current PATH and OS session were not changed; start a new login/session for persistent changes to take effect\n",
            );
            break :blk 0;
        },
        .preflight_changed => |index| blk: {
            try writer.print(
                "setup: preflight conflict: {s} changed after planning; no files changed\n",
                .{plan.targets.items[index].path},
            );
            break :blk 1;
        },
        .failed => |failure| blk: {
            try writeApplyFailure(writer, &plan, failure);
            break :blk 1;
        },
    };
    try flushOutput(&output);
    return exit_code;
}

fn flushOutput(output: *std.Io.Writer.Allocating) !void {
    try sys.writeAll(std.posix.STDOUT_FILENO, output.written());
    output.clearRetainingCapacity();
}

fn systemdUserAvailable(allocator: std.mem.Allocator) bool {
    const runtime_dir = sys.getenvOwned(allocator, "XDG_RUNTIME_DIR") catch return false;
    defer allocator.free(runtime_dir);
    const systemd_dir = std.fs.path.join(allocator, &.{ runtime_dir, "systemd" }) catch return false;
    defer allocator.free(systemd_dir);
    return sys.isDir(allocator, systemd_dir);
}

fn writePlan(writer: *std.Io.Writer, plan: *const Plan, apply: bool) !void {
    try writer.print(
        "setup: {s} {s} plan ({s})\n",
        .{
            if (apply) "apply" else "read-only preview",
            if (plan.mode == .add) "addition" else "removal",
            if (plan.platform == .linux) "linux" else "macos",
        },
    );

    for (plan.targets.items) |target| {
        try writer.print("target: {s}\n", .{target.label});
        try writer.print("path: {s}\n", .{target.path});
        try writer.print("action: {s}\n", .{actionName(target.action)});
        try writer.print("detail: {s}\n", .{target.detail});
        if (target.display_content) |content| {
            try writer.print("managed-content-begin\n{s}", .{content});
            if (content.len == 0 or content[content.len - 1] != '\n') {
                try writer.writeByte('\n');
            }
            try writer.writeAll("managed-content-end\n");
        }
    }

    for (plan.manuals.items) |manual| {
        try writer.print("manual: {s}\n", .{manual});
    }
    try writer.print(
        "summary: {d} change(s), {s}\n",
        .{ plan.changeCount(), if (plan.hasConflicts()) "conflicts present" else "preflight clean" },
    );
}

fn writeApplyFailure(writer: *std.Io.Writer, plan: *const Plan, failure: ApplyFailure) !void {
    var mutation_ordinal: usize = 0;
    for (plan.targets.items, 0..) |target, index| {
        if (!isMutation(target.action)) continue;
        if (mutation_ordinal < failure.applied_changes) {
            try writer.print("applied: {s}\n", .{target.path});
        } else if (index == failure.target_index) {
            try writer.print("failed: {s}: {s}\n", .{ target.path, @errorName(failure.err) });
        } else {
            try writer.print("pending: {s}\n", .{target.path});
        }
        mutation_ordinal += 1;
    }
    try writer.print(
        "setup: apply stopped after {d} applied action(s); rerun --apply after fixing the failure to converge\n",
        .{failure.applied_changes},
    );
}

fn buildPlan(allocator: std.mem.Allocator, facts: Facts, mode: Mode) !Plan {
    try validateFacts(facts);

    var plan = Plan{
        .mode = mode,
        .platform = facts.platform,
    };
    errdefer plan.deinit(allocator);

    const profile_block = renderProfileBlock(allocator, facts.shims_dir) catch |err| switch (err) {
        error.UnsafePath => null,
        else => return err,
    };
    defer if (profile_block) |value| allocator.free(value);

    const profile_path = try std.fs.path.join(allocator, &.{ facts.home, ".profile" });
    defer allocator.free(profile_path);
    const zprofile_path = try std.fs.path.join(allocator, &.{ facts.home, ".zprofile" });
    defer allocator.free(zprofile_path);

    try addProfileTarget(allocator, &plan, "Bash/POSIX login profile", profile_path, profile_block, mode);

    switch (facts.platform) {
        .linux => {
            const environment_path = try std.fs.path.join(
                allocator,
                &.{ facts.config_home, "environment.d", environment_file_name },
            );
            defer allocator.free(environment_path);

            if (mode == .remove or facts.systemd_user) {
                const environment_content = renderEnvironmentFile(allocator, facts.shims_dir) catch |err| switch (err) {
                    error.UnsafePath => null,
                    else => return err,
                };
                defer if (environment_content) |value| allocator.free(value);
                try addOwnedTarget(
                    allocator,
                    &plan,
                    "systemd user environment",
                    environment_path,
                    environment_content,
                    mode,
                );
            } else {
                const quoted = try shellSingleQuote(allocator, facts.shims_dir);
                defer allocator.free(quoted);
                try addManual(
                    allocator,
                    &plan,
                    try std.fmt.allocPrint(
                        allocator,
                        "Non-systemd Linux session: add {s} as one complete PATH component in that session's user startup configuration.",
                        .{quoted},
                    ),
                );
            }
        },
        .macos => {
            const launch_agent_path = try std.fs.path.join(
                allocator,
                &.{ facts.home, "Library", "LaunchAgents", launch_agent_name },
            );
            defer allocator.free(launch_agent_path);
            const launch_agent_content = renderLaunchAgent(allocator, facts.shims_dir) catch |err| switch (err) {
                error.UnsafePath => null,
                else => return err,
            };
            defer if (launch_agent_content) |value| allocator.free(value);
            try addOwnedTarget(
                allocator,
                &plan,
                "macOS user LaunchAgent",
                launch_agent_path,
                launch_agent_content,
                mode,
            );
        },
    }
    try addProfileTarget(allocator, &plan, "Zsh login profile", zprofile_path, profile_block, mode);

    if (mode == .add) {
        const quoted = try shellSingleQuote(allocator, facts.shims_dir);
        defer allocator.free(quoted);
        try addManual(
            allocator,
            &plan,
            try std.fmt.allocPrint(
                allocator,
                "Other shells: add {s} as one complete PATH component ahead of commands it should shadow; glolias edits only .profile and .zprofile.",
                .{quoted},
            ),
        );
    }

    return plan;
}

fn validateFacts(facts: Facts) FactsError!void {
    if (!isAbsoluteSetupPath(facts.home)) return error.UnsafeHome;
    if (!isAbsoluteSetupPath(facts.config_home)) return error.UnsafeConfigHome;
    if (!isAbsoluteSetupPath(facts.shims_dir)) return error.UnsafeShimsDir;
}

fn applyPlan(plan: *const Plan, allocator: std.mem.Allocator, options: ApplyOptions) ApplyResult {
    if (plan.hasConflicts()) {
        for (plan.targets.items, 0..) |target, index| {
            if (target.action == .conflict) return .{ .preflight_changed = index };
        }
        unreachable;
    }

    for (plan.targets.items, 0..) |target, index| {
        var current = inspect(allocator, target.path) catch |err| {
            return .{ .failed = .{ .target_index = index, .applied_changes = 0, .err = err } };
        };
        defer current.deinit(allocator);
        if (!snapshotMatchesTarget(current, target)) return .{ .preflight_changed = index };
    }

    var applied: usize = 0;
    for (plan.targets.items, 0..) |target, index| {
        if (!isMutation(target.action)) continue;
        if (options.fail_before_target_index == index) {
            return .{ .failed = .{
                .target_index = index,
                .applied_changes = applied,
                .err = error.InjectedApplyFailure,
            } };
        }

        applyTarget(allocator, target) catch |err| {
            return .{ .failed = .{
                .target_index = index,
                .applied_changes = applied,
                .err = err,
            } };
        };
        applied += 1;
    }
    return .{ .success = applied };
}

fn actionName(action: Action) []const u8 {
    return switch (action) {
        .create => "create",
        .update => "update",
        .remove => "remove",
        .no_op => "no-op",
        .conflict => "conflict",
    };
}

fn renderProfileBlock(allocator: std.mem.Allocator, shims_dir: []const u8) ![]const u8 {
    try validatePathComponent(shims_dir);
    const quoted = try shellSingleQuote(allocator, shims_dir);
    defer allocator.free(quoted);

    return std.fmt.allocPrint(allocator,
        \\{s}
        \\# Managed by glolias. Preview removal with: glolias setup --remove
        \\_glolias_shims={s}
        \\case ":${{PATH-}}:" in
        \\  *:"${{_glolias_shims}}":*) ;;
        \\  *) PATH="${{_glolias_shims}}${{PATH:+:${{PATH}}}}"; export PATH ;;
        \\esac
        \\unset _glolias_shims
        \\{s}
        \\
    , .{ start_marker, quoted, end_marker });
}

fn renderEnvironmentFile(allocator: std.mem.Allocator, shims_dir: []const u8) ![]const u8 {
    try validatePathComponent(shims_dir);
    if (!std.unicode.utf8ValidateSlice(shims_dir)) return error.UnsafePath;
    if (std.mem.indexOfScalar(u8, shims_dir, '$') != null) return error.UnsafePath;
    return std.fmt.allocPrint(
        allocator,
        "PATH={s}${{PATH:+:${{PATH}}}}\n",
        .{shims_dir},
    );
}

fn renderLaunchAgent(allocator: std.mem.Allocator, shims_dir: []const u8) ![]const u8 {
    try validatePathComponent(shims_dir);
    if (!std.unicode.utf8ValidateSlice(shims_dir)) return error.UnsafePath;

    const quoted = try shellSingleQuote(allocator, shims_dir);
    defer allocator.free(quoted);
    const script = try std.fmt.allocPrint(
        allocator,
        "shims={s}; case \":${{PATH-}}:\" in *:\"${{shims}}\":*) exit 0 ;; *) exec /bin/launchctl setenv PATH \"${{shims}}${{PATH:+:${{PATH}}}}\" ;; esac",
        .{quoted},
    );
    defer allocator.free(script);
    const escaped_script = try xmlEscape(allocator, script);
    defer allocator.free(escaped_script);

    return std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>Label</key>
        \\  <string>com.github.impactaky.glolias-path</string>
        \\  <key>ProgramArguments</key>
        \\  <array>
        \\    <string>/bin/sh</string>
        \\    <string>-c</string>
        \\    <string>{s}</string>
        \\  </array>
        \\  <key>RunAtLoad</key>
        \\  <true/>
        \\</dict>
        \\</plist>
        \\
    , .{escaped_script});
}

fn addProfileTarget(
    allocator: std.mem.Allocator,
    plan: *Plan,
    label: []const u8,
    path: []const u8,
    desired_block: ?[]const u8,
    mode: Mode,
) !void {
    var before = try inspect(allocator, path);
    defer before.deinit(allocator);

    if (desired_block == null) {
        return appendTarget(
            allocator,
            plan,
            label,
            path,
            .profile,
            .conflict,
            before,
            null,
            null,
            "the Shims directory is not representable as one safe PATH component",
        );
    }

    switch (before.kind) {
        .missing => {
            if (mode == .add) {
                try appendTarget(
                    allocator,
                    plan,
                    label,
                    path,
                    .profile,
                    .create,
                    before,
                    desired_block,
                    desired_block,
                    "add the versioned glolias managed block",
                );
            } else {
                try appendTarget(
                    allocator,
                    plan,
                    label,
                    path,
                    .profile,
                    .no_op,
                    before,
                    null,
                    desired_block,
                    "managed block is already absent",
                );
            }
        },
        .regular_file => {
            const existing = before.content.?;
            switch (analyzeProfile(existing)) {
                .malformed => try appendTarget(
                    allocator,
                    plan,
                    label,
                    path,
                    .profile,
                    .conflict,
                    before,
                    null,
                    desired_block,
                    "malformed or duplicate glolias managed-block markers",
                ),
                .absent => {
                    if (mode == .remove) {
                        try appendTarget(
                            allocator,
                            plan,
                            label,
                            path,
                            .profile,
                            .no_op,
                            before,
                            null,
                            desired_block,
                            "managed block is already absent; unrelated profile bytes are untouched",
                        );
                    } else {
                        const after = if (existing.len == 0)
                            try allocator.dupe(u8, desired_block.?)
                        else
                            try std.mem.concat(allocator, u8, &.{ existing, "\n", desired_block.? });
                        defer allocator.free(after);
                        try appendTarget(
                            allocator,
                            plan,
                            label,
                            path,
                            .profile,
                            .update,
                            before,
                            after,
                            desired_block,
                            "append the managed block while preserving all existing bytes",
                        );
                    }
                },
                .valid => |state| {
                    const current_block = existing[state.block_start..state.block_end];
                    if (mode == .add) {
                        if (std.mem.eql(u8, current_block, desired_block.?)) {
                            try appendTarget(
                                allocator,
                                plan,
                                label,
                                path,
                                .profile,
                                .no_op,
                                before,
                                null,
                                desired_block,
                                "exact managed block is already present",
                            );
                        } else {
                            const after = try std.mem.concat(
                                allocator,
                                u8,
                                &.{
                                    existing[0..state.block_start],
                                    desired_block.?,
                                    existing[state.block_end..],
                                },
                            );
                            defer allocator.free(after);
                            try appendTarget(
                                allocator,
                                plan,
                                label,
                                path,
                                .profile,
                                .update,
                                before,
                                after,
                                desired_block,
                                "replace the one well-formed managed block; preserve all outside bytes",
                            );
                        }
                    } else {
                        const after = try std.mem.concat(
                            allocator,
                            u8,
                            &.{ existing[0..state.owned_start], existing[state.block_end..] },
                        );
                        defer allocator.free(after);
                        try appendTarget(
                            allocator,
                            plan,
                            label,
                            path,
                            .profile,
                            .remove,
                            before,
                            after,
                            current_block,
                            "remove only the valid glolias managed block",
                        );
                    }
                },
            }
        },
        .symlink => try appendTarget(
            allocator,
            plan,
            label,
            path,
            .profile,
            .conflict,
            before,
            null,
            desired_block,
            "profile target is a symlink; glolias will not follow or replace it",
        ),
        .directory, .other => try appendTarget(
            allocator,
            plan,
            label,
            path,
            .profile,
            .conflict,
            before,
            null,
            desired_block,
            "profile target is not a regular file",
        ),
    }
}

fn addOwnedTarget(
    allocator: std.mem.Allocator,
    plan: *Plan,
    label: []const u8,
    path: []const u8,
    desired_content: ?[]const u8,
    mode: Mode,
) !void {
    var before = try inspect(allocator, path);
    defer before.deinit(allocator);

    if (desired_content == null) {
        return appendTarget(
            allocator,
            plan,
            label,
            path,
            .owned_file,
            .conflict,
            before,
            null,
            null,
            "the Shims directory cannot be represented losslessly in this target format",
        );
    }

    switch (before.kind) {
        .missing => try appendTarget(
            allocator,
            plan,
            label,
            path,
            .owned_file,
            if (mode == .add) .create else .no_op,
            before,
            if (mode == .add) desired_content else null,
            desired_content,
            if (mode == .add) "create this glolias-owned file" else "glolias-owned file is already absent",
        ),
        .regular_file => {
            if (!std.mem.eql(u8, before.content.?, desired_content.?)) {
                try appendTarget(
                    allocator,
                    plan,
                    label,
                    path,
                    .owned_file,
                    .conflict,
                    before,
                    null,
                    desired_content,
                    "unexpected content in a glolias-owned file; refusing to overwrite it",
                );
            } else {
                try appendTarget(
                    allocator,
                    plan,
                    label,
                    path,
                    .owned_file,
                    if (mode == .add) .no_op else .remove,
                    before,
                    null,
                    desired_content,
                    if (mode == .add) "exact glolias-owned content is already present" else "remove this exact glolias-owned file",
                );
            }
        },
        .symlink => try appendTarget(
            allocator,
            plan,
            label,
            path,
            .owned_file,
            .conflict,
            before,
            null,
            desired_content,
            "glolias-owned target is a symlink; refusing to follow or replace it",
        ),
        .directory, .other => try appendTarget(
            allocator,
            plan,
            label,
            path,
            .owned_file,
            .conflict,
            before,
            null,
            desired_content,
            "glolias-owned target is not a regular file",
        ),
    }
}

fn appendTarget(
    allocator: std.mem.Allocator,
    plan: *Plan,
    label: []const u8,
    path: []const u8,
    kind: TargetKind,
    action: Action,
    before: Snapshot,
    after_content: ?[]const u8,
    display_content: ?[]const u8,
    detail: []const u8,
) !void {
    var target = Target{
        .label = try allocator.dupe(u8, label),
        .path = try allocator.dupe(u8, path),
        .kind = kind,
        .action = action,
        .before_kind = before.kind,
        .before_content = if (before.content) |value| try allocator.dupe(u8, value) else null,
        .after_content = if (after_content) |value| try allocator.dupe(u8, value) else null,
        .display_content = if (display_content) |value| try allocator.dupe(u8, value) else null,
        .detail = try allocator.dupe(u8, detail),
    };
    errdefer target.deinit(allocator);
    try plan.targets.append(allocator, target);
}

fn addManual(allocator: std.mem.Allocator, plan: *Plan, owned_detail: []const u8) !void {
    errdefer allocator.free(owned_detail);
    try plan.manuals.append(allocator, owned_detail);
}

fn inspect(allocator: std.mem.Allocator, path: []const u8) !Snapshot {
    const kind = try sys.pathKind(allocator, path);
    return .{
        .kind = kind,
        .content = if (kind == .regular_file)
            try sys.readFileAlloc(allocator, path, 1024 * 1024)
        else
            null,
    };
}

fn analyzeProfile(content: []const u8) ProfileState {
    const start_count = countOccurrences(content, start_marker);
    const end_count = countOccurrences(content, end_marker);
    if (start_count == 0 and end_count == 0) return .absent;
    if (start_count != 1 or end_count != 1) return .malformed;

    const start = std.mem.indexOf(u8, content, start_marker).?;
    const end = std.mem.indexOf(u8, content, end_marker).?;
    if (end <= start) return .malformed;
    if (!isLineMarker(content, start, start_marker.len)) return .malformed;
    if (!isLineMarker(content, end, end_marker.len)) return .malformed;

    var block_end = end + end_marker.len;
    if (block_end < content.len and content[block_end] == '\n') block_end += 1;
    const owned_start = if (block_end == content.len and start > 0 and content[start - 1] == '\n')
        start - 1
    else
        start;
    return .{ .valid = .{
        .block_start = start,
        .block_end = block_end,
        .owned_start = owned_start,
    } };
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |index| {
        count += 1;
        offset = index + needle.len;
    }
    return count;
}

fn isLineMarker(content: []const u8, start: usize, marker_len: usize) bool {
    if (start > 0 and content[start - 1] != '\n') return false;
    const after = start + marker_len;
    return after == content.len or content[after] == '\n';
}

fn validatePathComponent(path: []const u8) !void {
    if (path.len == 0) return error.UnsafePath;
    for (path) |byte| {
        if (byte == 0 or byte == '\n' or byte == '\r' or byte == ':') return error.UnsafePath;
    }
}

fn isAbsoluteSetupPath(path: []const u8) bool {
    return path.len != 0 and std.fs.path.isAbsolute(path);
}

fn shellSingleQuote(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (value) |byte| {
        if (byte == '\'') {
            try out.appendSlice(allocator, "'\"'\"'");
        } else {
            try out.append(allocator, byte);
        }
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

fn xmlEscape(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (value) |byte| {
        switch (byte) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&apos;"),
            0...8, 11, 12, 14...31 => return error.UnsafePath,
            else => try out.append(allocator, byte),
        }
    }
    return out.toOwnedSlice(allocator);
}

fn snapshotMatchesTarget(snapshot: Snapshot, target: Target) bool {
    if (snapshot.kind != target.before_kind) return false;
    if (snapshot.content == null and target.before_content == null) return true;
    if (snapshot.content == null or target.before_content == null) return false;
    return std.mem.eql(u8, snapshot.content.?, target.before_content.?);
}

fn applyTarget(allocator: std.mem.Allocator, target: Target) !void {
    switch (target.action) {
        .create, .update => try sys.writeFileAtomic(allocator, target.path, target.after_content.?),
        .remove => switch (target.kind) {
            .profile => try sys.writeFileAtomic(allocator, target.path, target.after_content.?),
            .owned_file => try sys.unlinkPath(allocator, target.path),
        },
        .no_op, .conflict => unreachable,
    }
}

fn isMutation(action: Action) bool {
    return switch (action) {
        .create, .update, .remove => true,
        .no_op, .conflict => false,
    };
}

test "renderers quote special characters and reject unsafe components" {
    const allocator = std.testing.allocator;
    const shims = "/tmp/glolias path/'quoted'&<dir>";

    const profile = try renderProfileBlock(allocator, shims);
    defer allocator.free(profile);
    try std.testing.expect(std.mem.indexOf(u8, profile, "'\"'\"'") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "*:\"${_glolias_shims}\":*") != null);

    const environment = try renderEnvironmentFile(allocator, shims);
    defer allocator.free(environment);
    try std.testing.expectEqualStrings(
        "PATH=/tmp/glolias path/'quoted'&<dir>${PATH:+:${PATH}}\n",
        environment,
    );

    const plist = try renderLaunchAgent(allocator, shims);
    defer allocator.free(plist);
    try std.testing.expect(std.mem.indexOf(u8, plist, "&amp;") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "&lt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "/bin/launchctl setenv") != null);

    try std.testing.expectError(error.UnsafePath, renderProfileBlock(allocator, "/tmp/a:b"));
    try std.testing.expectError(error.UnsafePath, renderEnvironmentFile(allocator, "/tmp/$unsafe"));
}

test "profile planning detects exact, malformed, duplicate, and removable blocks" {
    const allocator = std.testing.allocator;
    const block = try renderProfileBlock(allocator, "/tmp/shims");
    defer allocator.free(block);

    try std.testing.expect(analyzeProfile("export PATH=/unrelated\n") == .absent);
    try std.testing.expect(analyzeProfile(start_marker ++ "\n" ++ end_marker ++ "\n") == .valid);
    try std.testing.expect(analyzeProfile(start_marker ++ "\n") == .malformed);
    try std.testing.expect(analyzeProfile(
        start_marker ++ "\n" ++ end_marker ++ "\n" ++ start_marker ++ "\n" ++ end_marker,
    ) == .malformed);

    const original = "export PATH=/unrelated";
    const installed = try std.mem.concat(allocator, u8, &.{ original, "\n", block });
    defer allocator.free(installed);
    switch (analyzeProfile(installed)) {
        .valid => |state| {
            const after = try std.mem.concat(
                allocator,
                u8,
                &.{ installed[0..state.owned_start], installed[state.block_end..] },
            );
            defer allocator.free(after);
            try std.testing.expectEqualStrings(original, after);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "fake platform facts produce Linux and macOS target plans" {
    const allocator = std.testing.allocator;
    const fake_root = "/tmp/glolias-unit-facts-path-that-does-not-exist";

    var linux = try buildPlan(allocator, .{
        .platform = .linux,
        .home = fake_root,
        .config_home = fake_root,
        .shims_dir = "/tmp/shims",
        .systemd_user = true,
    }, .add);
    defer linux.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), linux.targets.items.len);
    try std.testing.expect(std.mem.endsWith(u8, linux.targets.items[1].path, environment_file_name));

    var macos = try buildPlan(allocator, .{
        .platform = .macos,
        .home = fake_root,
        .config_home = fake_root,
        .shims_dir = "/tmp/shims",
        .systemd_user = false,
    }, .add);
    defer macos.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), macos.targets.items.len);
    try std.testing.expect(std.mem.endsWith(u8, macos.targets.items[1].path, launch_agent_name));
    try std.testing.expect(std.mem.indexOf(
        u8,
        macos.targets.items[1].display_content.?,
        "/bin/launchctl setenv",
    ) != null);
}

test "apply reports partial progress and an idempotent rerun converges" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_root = try std.fs.path.join(
        allocator,
        &.{ ".zig-cache", "tmp", &tmp.sub_path },
    );
    defer allocator.free(relative_root);
    const root = try sys.realpathAlloc(allocator, relative_root);
    defer allocator.free(root);
    const config_home = try std.fs.path.join(allocator, &.{ root, "config" });
    defer allocator.free(config_home);

    const facts = Facts{
        .platform = .linux,
        .home = root,
        .config_home = config_home,
        .shims_dir = "/tmp/shims",
        .systemd_user = true,
    };
    var first = try buildPlan(allocator, facts, .add);
    defer first.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), first.changeCount());

    const failed = applyPlan(&first, allocator, .{ .fail_before_target_index = 1 });
    switch (failed) {
        .failed => |failure| {
            try std.testing.expectEqual(@as(usize, 1), failure.applied_changes);
            try std.testing.expectEqual(@as(usize, 1), failure.target_index);
        },
        else => return error.TestUnexpectedResult,
    }

    var retry = try buildPlan(allocator, facts, .add);
    defer retry.deinit(allocator);
    try std.testing.expectEqual(.no_op, retry.targets.items[0].action);
    try std.testing.expectEqual(@as(usize, 2), retry.changeCount());
    switch (applyPlan(&retry, allocator, .{})) {
        .success => |count| try std.testing.expectEqual(@as(usize, 2), count),
        else => return error.TestUnexpectedResult,
    }

    var noop = try buildPlan(allocator, facts, .add);
    defer noop.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), noop.changeCount());
}

test "planning rejects empty or relative setup roots before filesystem inspection" {
    const allocator = std.testing.allocator;
    const safe = "/tmp/glolias-safe-root";
    const base = Facts{
        .platform = .linux,
        .home = safe,
        .config_home = safe,
        .shims_dir = safe,
        .systemd_user = false,
    };

    var facts = base;
    facts.home = "";
    try std.testing.expectError(error.UnsafeHome, buildPlan(allocator, facts, .add));
    facts.home = "relative-home";
    try std.testing.expectError(error.UnsafeHome, buildPlan(allocator, facts, .add));

    facts = base;
    facts.config_home = "";
    try std.testing.expectError(error.UnsafeConfigHome, buildPlan(allocator, facts, .add));
    facts.config_home = "relative-config";
    try std.testing.expectError(error.UnsafeConfigHome, buildPlan(allocator, facts, .add));

    facts = base;
    facts.shims_dir = "";
    try std.testing.expectError(error.UnsafeShimsDir, buildPlan(allocator, facts, .add));
    facts.shims_dir = "relative-shims";
    try std.testing.expectError(error.UnsafeShimsDir, buildPlan(allocator, facts, .add));
}
