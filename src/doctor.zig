const std = @import("std");

const config = @import("config.zig");
const credential_runner = @import("credential_runner.zig");
const paths = @import("paths.zig");
const real_command = @import("real_command.zig");
const sys = @import("sys.zig");

const SubjectDetail = struct {
    subject: []const u8,
    detail: []const u8,
};

const SubjectKind = struct {
    subject: []const u8,
    kind: sys.PathKind,
};

const Finding = union(enum) {
    config_ok,
    config_error: []const u8,
    shims_dir_ok: []const u8,
    shims_dir_missing: []const u8,
    shims_dir_not_directory: SubjectKind,
    shims_dir_inspect_error: SubjectDetail,
    path_present: usize,
    path_missing,
    shadowing: SubjectDetail,
    binary_error: []const u8,
    shim_missing: []const u8,
    shim_wrong_kind: SubjectKind,
    shim_inspect_error: SubjectDetail,
    shim_dangling: []const u8,
    shim_wrong_target: SubjectDetail,
    orphan: []const u8,
    no_orphans,
    orphans_skipped,
    shims_inspect_error,
    credentials_dir_ok: []const u8,
    credentials_dir_missing: []const u8,
    credentials_dir_not_directory: SubjectKind,
    credentials_dir_inspect_error: SubjectDetail,
    credential_runner_ok: []const u8,
    credential_runner_error: SubjectDetail,
    credential_runner_stale: []const u8,
    credential_duplicate_environment: SubjectDetail,
    credential_orphan: []const u8,
    credential_no_orphans,
    credential_orphans_skipped,
    credentials_inspect_error,

    fn deinit(self: *Finding, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .config_error,
            .shims_dir_ok,
            .shims_dir_missing,
            .binary_error,
            .shim_missing,
            .shim_dangling,
            .orphan,
            .credentials_dir_ok,
            .credentials_dir_missing,
            .credential_runner_ok,
            .credential_runner_stale,
            .credential_orphan,
            => |value| allocator.free(value),
            .shims_dir_not_directory,
            .shim_wrong_kind,
            .credentials_dir_not_directory,
            => |value| allocator.free(value.subject),
            .shims_dir_inspect_error,
            .shadowing,
            .shim_inspect_error,
            .shim_wrong_target,
            .credentials_dir_inspect_error,
            .credential_runner_error,
            .credential_duplicate_environment,
            => |value| {
                allocator.free(value.subject);
                allocator.free(value.detail);
            },
            .config_ok,
            .path_present,
            .path_missing,
            .no_orphans,
            .orphans_skipped,
            .shims_inspect_error,
            .credential_no_orphans,
            .credential_orphans_skipped,
            .credentials_inspect_error,
            => {},
        }
        self.* = undefined;
    }
};

const ReportState = struct {
    entries: std.ArrayList(Finding) = .empty,
};

const Report = opaque {
    fn state(self: *Report) *ReportState {
        return @ptrCast(@alignCast(self));
    }

    fn stateConst(self: *const Report) *const ReportState {
        return @ptrCast(@alignCast(self));
    }

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        const report_state = self.state();
        for (report_state.entries.items) |*entry| entry.deinit(allocator);
        report_state.entries.deinit(allocator);
        allocator.destroy(report_state);
    }

    pub fn findings(self: *const Report) []const Finding {
        return self.stateConst().entries.items;
    }

    pub fn healthy(self: *const Report) bool {
        for (self.stateConst().entries.items) |entry| switch (entry) {
            .config_ok,
            .shims_dir_ok,
            .path_present,
            .no_orphans,
            .orphans_skipped,
            .credentials_dir_ok,
            .credential_runner_ok,
            .credential_no_orphans,
            .credential_orphans_skipped,
            => {},
            else => return false,
        };
        return true;
    }

    pub fn needsShimRepair(self: *const Report) bool {
        for (self.stateConst().entries.items) |entry| switch (entry) {
            .shims_dir_missing,
            .shims_dir_not_directory,
            .shims_dir_inspect_error,
            .shim_missing,
            .shim_wrong_kind,
            .shim_inspect_error,
            .shim_dangling,
            .shim_wrong_target,
            .orphan,
            .shims_inspect_error,
            => return true,
            else => {},
        };
        return false;
    }

    pub fn needsCredentialSync(self: *const Report) bool {
        for (self.stateConst().entries.items) |entry| switch (entry) {
            .credential_runner_stale => return true,
            else => {},
        };
        return false;
    }

    pub fn needsCredentialReset(self: *const Report) bool {
        for (self.stateConst().entries.items) |entry| switch (entry) {
            .credential_runner_error => return true,
            else => {},
        };
        return false;
    }

    fn addSimple(self: *Report, allocator: std.mem.Allocator, finding: Finding) !void {
        try self.state().entries.append(allocator, finding);
    }

    fn addText(
        self: *Report,
        allocator: std.mem.Allocator,
        comptime tag: std.meta.Tag(Finding),
        text: []const u8,
    ) !void {
        const owned = try allocator.dupe(u8, text);
        errdefer allocator.free(owned);
        try self.state().entries.append(allocator, @unionInit(Finding, @tagName(tag), owned));
    }

    fn addDetail(
        self: *Report,
        allocator: std.mem.Allocator,
        comptime tag: std.meta.Tag(Finding),
        subject: []const u8,
        detail: []const u8,
    ) !void {
        const owned_subject = try allocator.dupe(u8, subject);
        errdefer allocator.free(owned_subject);
        const owned_detail = try allocator.dupe(u8, detail);
        errdefer allocator.free(owned_detail);
        try self.state().entries.append(allocator, @unionInit(Finding, @tagName(tag), SubjectDetail{
            .subject = owned_subject,
            .detail = owned_detail,
        }));
    }

    fn addKind(
        self: *Report,
        allocator: std.mem.Allocator,
        comptime tag: std.meta.Tag(Finding),
        subject: []const u8,
        kind: sys.PathKind,
    ) !void {
        const owned_subject = try allocator.dupe(u8, subject);
        errdefer allocator.free(owned_subject);
        try self.state().entries.append(allocator, @unionInit(Finding, @tagName(tag), SubjectKind{
            .subject = owned_subject,
            .kind = kind,
        }));
    }
};

fn initReport(allocator: std.mem.Allocator) !*Report {
    const state = try allocator.create(ReportState);
    state.* = .{};
    return @ptrCast(state);
}

fn inspect(allocator: std.mem.Allocator) !*Report {
    const report = try initReport(allocator);
    errdefer report.deinit(allocator);

    var cfg_opt: ?config.Config = config.load(allocator) catch |err| blk: {
        try report.addText(allocator, .config_error, @errorName(err));
        break :blk null;
    };
    defer if (cfg_opt) |*cfg| cfg.deinit(allocator);
    if (cfg_opt != null) try report.addSimple(allocator, .config_ok);

    const shims_dir = try paths.defaultShimsDir(allocator);
    defer allocator.free(shims_dir);

    const shims_kind = sys.pathKind(allocator, shims_dir) catch |err| blk: {
        try report.addDetail(
            allocator,
            .shims_dir_inspect_error,
            shims_dir,
            @errorName(err),
        );
        break :blk null;
    };
    const shims_is_dir = sys.isDir(allocator, shims_dir);
    if (shims_is_dir) {
        try report.addText(allocator, .shims_dir_ok, shims_dir);
    } else if (shims_kind) |kind| switch (kind) {
        .missing => try report.addText(allocator, .shims_dir_missing, shims_dir),
        else => try report.addKind(
            allocator,
            .shims_dir_not_directory,
            shims_dir,
            kind,
        ),
    };

    const path_value = sys.getenvOwned(allocator, "PATH") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(path_value);

    const shims_index = real_command.indexOfDir(allocator, path_value, shims_dir);
    if (shims_index) |index| {
        try report.addSimple(allocator, .{ .path_present = index });
    } else {
        try report.addSimple(allocator, .path_missing);
    }

    if (cfg_opt) |*cfg| {
        var alias_entries = cfg.aliases.iterator();
        while (alias_entries.next()) |entry| {
            var found = (try real_command.firstExecutable(
                allocator,
                path_value,
                entry.key_ptr.*,
                null,
            )) orelse continue;
            defer found.deinit(allocator);
            if (shims_index) |index| {
                if (found.index < index) {
                    try report.addDetail(
                        allocator,
                        .shadowing,
                        entry.key_ptr.*,
                        found.dir,
                    );
                }
            }
        }
    }

    const current_binary = paths.selfExePath(allocator) catch |err| blk: {
        try report.addText(allocator, .binary_error, @errorName(err));
        break :blk null;
    };
    defer if (current_binary) |binary| allocator.free(binary);

    if (cfg_opt) |*cfg| {
        var alias_entries = cfg.aliases.iterator();
        while (alias_entries.next()) |entry| {
            try inspectConfiguredShim(
                allocator,
                report,
                shims_dir,
                entry.key_ptr.*,
                current_binary,
            );
        }
    }

    if (shims_is_dir) {
        const symlinks = sys.listSymlinks(allocator, shims_dir) catch |err| switch (err) {
            error.OpenDirFailed => blk: {
                try report.addSimple(allocator, .shims_inspect_error);
                break :blk null;
            },
            else => return err,
        };
        defer if (symlinks) |entries| {
            for (entries) |entry_name| allocator.free(entry_name);
            allocator.free(entries);
        };

        if (symlinks) |entries| {
            if (cfg_opt) |*cfg| {
                var orphan_count: usize = 0;
                for (entries) |entry_name| {
                    if (!cfg.aliases.contains(entry_name)) {
                        orphan_count += 1;
                        try report.addText(allocator, .orphan, entry_name);
                    }
                }
                if (orphan_count == 0) {
                    try report.addSimple(allocator, .no_orphans);
                }
            } else {
                for (entries) |entry_name| {
                    const link_path = try std.fs.path.join(allocator, &.{ shims_dir, entry_name });
                    defer allocator.free(link_path);
                    try inspectSymlinkTarget(allocator, report, link_path, entry_name, current_binary);
                }
                try report.addSimple(allocator, .orphans_skipped);
            }
        }
    }

    try inspectCredentials(allocator, report, if (cfg_opt) |*cfg| cfg else null);

    return report;
}

fn inspectCredentials(allocator: std.mem.Allocator, report: *Report, cfg: ?*const config.Config) !void {
    const credentials_dir = try paths.defaultCredentialsDir(allocator);
    defer allocator.free(credentials_dir);
    const kind = sys.pathKind(allocator, credentials_dir) catch |err| {
        try report.addDetail(allocator, .credentials_dir_inspect_error, credentials_dir, @errorName(err));
        return;
    };
    switch (kind) {
        .missing => {
            if (cfg) |loaded| {
                if (loaded.credentials.count() == 0) {
                    try report.addSimple(allocator, .credential_no_orphans);
                    return;
                }
                try report.addText(allocator, .credentials_dir_missing, credentials_dir);
                const names = try config.sortedCredentialKeys(allocator, loaded);
                defer allocator.free(names);
                for (names) |name| try report.addDetail(allocator, .credential_runner_error, name, "RunnerMissing");
            } else {
                try report.addSimple(allocator, .credential_orphans_skipped);
            }
            return;
        },
        .directory => try report.addText(allocator, .credentials_dir_ok, credentials_dir),
        else => {
            try report.addKind(allocator, .credentials_dir_not_directory, credentials_dir, kind);
            return;
        },
    }

    if (cfg) |loaded| {
        var aliases = loaded.aliases.iterator();
        while (aliases.next()) |entry| {
            config.validateAliasEnvironments(loaded, entry.value_ptr) catch |err| {
                try report.addDetail(allocator, .credential_duplicate_environment, entry.key_ptr.*, @errorName(err));
            };
        }
        const names = try config.sortedCredentialKeys(allocator, loaded);
        defer allocator.free(names);
        for (names) |name| {
            const metadata = loaded.credentials.get(name).?;
            const runner_path = try paths.credentialRunnerPath(allocator, credentials_dir, name);
            defer allocator.free(runner_path);
            const status = credential_runner.expectedStatus(allocator, runner_path, name, metadata.env_name) catch |err| {
                try report.addDetail(allocator, .credential_runner_error, name, @errorName(err));
                continue;
            };
            switch (status) {
                .valid => try report.addText(allocator, .credential_runner_ok, name),
                .stale => try report.addText(allocator, .credential_runner_stale, name),
            }
        }
    }

    const entries = sys.listEntries(allocator, credentials_dir) catch {
        try report.addSimple(allocator, .credentials_inspect_error);
        return;
    };
    defer {
        for (entries) |entry| allocator.free(entry);
        allocator.free(entries);
    }
    if (cfg) |loaded| {
        var orphan_count: usize = 0;
        for (entries) |entry| {
            if (!loaded.credentials.contains(entry)) {
                orphan_count += 1;
                try report.addText(allocator, .credential_orphan, entry);
            }
        }
        if (orphan_count == 0) try report.addSimple(allocator, .credential_no_orphans);
    } else {
        try report.addSimple(allocator, .credential_orphans_skipped);
    }
}

fn inspectConfiguredShim(
    allocator: std.mem.Allocator,
    report: *Report,
    shims_dir: []const u8,
    name: []const u8,
    current_binary: ?[]const u8,
) !void {
    const link_path = try std.fs.path.join(allocator, &.{ shims_dir, name });
    defer allocator.free(link_path);

    const kind = sys.pathKind(allocator, link_path) catch |err| {
        try report.addDetail(
            allocator,
            .shim_inspect_error,
            name,
            @errorName(err),
        );
        return;
    };
    switch (kind) {
        .missing => try report.addText(allocator, .shim_missing, name),
        .symlink => try inspectSymlinkTarget(allocator, report, link_path, name, current_binary),
        .directory, .regular_file, .other => try report.addKind(
            allocator,
            .shim_wrong_kind,
            name,
            kind,
        ),
    }
}

fn inspectSymlinkTarget(
    allocator: std.mem.Allocator,
    report: *Report,
    link_path: []const u8,
    name: []const u8,
    current_binary: ?[]const u8,
) !void {
    const resolved = sys.realpathAlloc(allocator, link_path) catch {
        try report.addText(allocator, .shim_dangling, name);
        return;
    };
    defer allocator.free(resolved);

    const binary = current_binary orelse return;
    if (!std.mem.eql(u8, resolved, binary)) {
        try report.addDetail(
            allocator,
            .shim_wrong_target,
            name,
            resolved,
        );
    }
}

pub const Diagnosis = struct {
    text: []u8,
    healthy: bool,

    pub fn deinit(self: *Diagnosis, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub fn diagnose(allocator: std.mem.Allocator) !Diagnosis {
    const report = try inspect(allocator);
    defer report.deinit(allocator);
    return renderDiagnosis(allocator, report);
}

fn renderDiagnosis(allocator: std.mem.Allocator, report: *const Report) !Diagnosis {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "doctor: current shell environment only; GUI IDE environments may differ\n");
    for (report.findings()) |finding| switch (finding) {
        .config_ok => try out.appendSlice(allocator, "config: ok\n"),
        .config_error => |error_name| try out.print(allocator, "config: error: {s}\n", .{error_name}),
        .shims_dir_ok => |path| try out.print(allocator, "shims_dir: ok: {s}\n", .{path}),
        .shims_dir_missing => |path| try out.print(allocator, "shims_dir: missing: {s}\n", .{path}),
        .shims_dir_not_directory => |finding_data| try out.print(
            allocator,
            "shims_dir: not a directory ({s}): {s}\n",
            .{ pathKindName(finding_data.kind), finding_data.subject },
        ),
        .shims_dir_inspect_error => |finding_data| try out.print(
            allocator,
            "shims_dir: unable to inspect: {s}: {s}\n",
            .{ finding_data.subject, finding_data.detail },
        ),
        .path_present => |position| try out.print(allocator, "path: shims_dir present at position {d}\n", .{position}),
        .path_missing => {
            try out.appendSlice(allocator, "path: shims_dir is not on PATH\n");
            try out.appendSlice(allocator, "guidance: run 'glolias setup' to preview persistent PATH setup\n");
        },
        .shadowing => |finding_data| try out.print(
            allocator,
            "shadowing: {s} is shadowed by {s}/{s}\n",
            .{ finding_data.subject, finding_data.detail, finding_data.subject },
        ),
        .binary_error => |error_name| try out.print(
            allocator,
            "binary: unable to resolve current glolias binary: {s}\n",
            .{error_name},
        ),
        .shim_missing => |name| try out.print(allocator, "shim: {s}: missing\n", .{name}),
        .shim_wrong_kind => |finding_data| try out.print(
            allocator,
            "shim: {s}: not a symlink ({s})\n",
            .{ finding_data.subject, pathKindName(finding_data.kind) },
        ),
        .shim_inspect_error => |finding_data| try out.print(
            allocator,
            "shim: {s}: unable to inspect: {s}\n",
            .{ finding_data.subject, finding_data.detail },
        ),
        .shim_dangling => |name| try out.print(allocator, "shim: {s}: dangling or unresolvable symlink\n", .{name}),
        .shim_wrong_target => |finding_data| try out.print(
            allocator,
            "shim: {s}: points to a different glolias binary: {s}\n",
            .{ finding_data.subject, finding_data.detail },
        ),
        .orphan => |name| try out.print(allocator, "orphan: {s}\n", .{name}),
        .no_orphans => try out.appendSlice(allocator, "orphans: none\n"),
        .orphans_skipped => try out.appendSlice(allocator, "orphans: skipped because config is unavailable\n"),
        .shims_inspect_error => try out.appendSlice(allocator, "shims: unable to inspect shims_dir\n"),
        .credentials_dir_ok => |path| try out.print(allocator, "credentials_dir: ok: {s}\n", .{path}),
        .credentials_dir_missing => |path| try out.print(allocator, "credentials_dir: missing: {s}\n", .{path}),
        .credentials_dir_not_directory => |finding_data| try out.print(
            allocator,
            "credentials_dir: not a directory ({s}): {s}\n",
            .{ pathKindName(finding_data.kind), finding_data.subject },
        ),
        .credentials_dir_inspect_error => |finding_data| try out.print(
            allocator,
            "credentials_dir: unable to inspect: {s}: {s}\n",
            .{ finding_data.subject, finding_data.detail },
        ),
        .credential_runner_ok => |name| try out.print(allocator, "credential: {s}: runner ok\n", .{name}),
        .credential_runner_error => |finding_data| try out.print(
            allocator,
            "credential: {s}: runner invalid: {s}\n",
            .{ finding_data.subject, finding_data.detail },
        ),
        .credential_runner_stale => |name| try out.print(allocator, "credential: {s}: runner stale\n", .{name}),
        .credential_duplicate_environment => |finding_data| try out.print(
            allocator,
            "credential: alias {s}: duplicate environment providers: {s}\n",
            .{ finding_data.subject, finding_data.detail },
        ),
        .credential_orphan => |name| try out.print(allocator, "credential orphan: {s}\n", .{name}),
        .credential_no_orphans => try out.appendSlice(allocator, "credential orphans: none\n"),
        .credential_orphans_skipped => try out.appendSlice(allocator, "credential orphans: skipped because config is unavailable\n"),
        .credentials_inspect_error => try out.appendSlice(allocator, "credentials: unable to inspect credentials_dir\n"),
    };

    if (report.needsShimRepair()) {
        try out.appendSlice(allocator, "repair: run 'glolias sync' to repair shims (remove blocking files or directories first)\n");
    }
    if (report.needsCredentialSync()) {
        try out.appendSlice(allocator, "repair: run 'glolias sync' to refresh stale Credential Runners\n");
    }
    if (report.needsCredentialReset()) {
        try out.appendSlice(allocator, "repair: run 'glolias credential set <credential> <ENV_NAME>' to recreate missing or invalid runners\n");
    }

    const healthy = report.healthy();
    try out.appendSlice(allocator, if (healthy) "doctor: ok\n" else "doctor: inconsistencies found\n");
    return .{ .text = try out.toOwnedSlice(allocator), .healthy = healthy };
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

test "Report derives health and Shim repair guidance from findings" {
    const allocator = std.testing.allocator;
    const report = try initReport(allocator);
    defer report.deinit(allocator);

    try report.addSimple(allocator, .config_ok);
    try std.testing.expect(report.healthy());
    try std.testing.expect(!report.needsShimRepair());

    try report.addSimple(allocator, .path_missing);
    try std.testing.expect(!report.healthy());
    try std.testing.expect(!report.needsShimRepair());

    try report.addText(allocator, .shim_missing, "gh");
    try std.testing.expect(report.needsShimRepair());

    var diagnosis = try renderDiagnosis(allocator, report);
    defer diagnosis.deinit(allocator);
    try std.testing.expect(!diagnosis.healthy);
    try std.testing.expect(std.mem.indexOf(u8, diagnosis.text, "shim: gh: missing\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnosis.text, "repair: run 'glolias sync'") != null);
}
