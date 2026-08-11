const std = @import("std");

const config = @import("config.zig");
const paths = @import("paths.zig");
const real_command = @import("real_command.zig");
const sys = @import("sys.zig");

pub const SubjectDetail = struct {
    subject: []const u8,
    detail: []const u8,
};

pub const SubjectKind = struct {
    subject: []const u8,
    kind: sys.PathKind,
};

pub const Finding = union(enum) {
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

    fn deinit(self: *Finding, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .config_error,
            .shims_dir_ok,
            .shims_dir_missing,
            .binary_error,
            .shim_missing,
            .shim_dangling,
            .orphan,
            => |value| allocator.free(value),
            .shims_dir_not_directory,
            .shim_wrong_kind,
            => |value| allocator.free(value.subject),
            .shims_dir_inspect_error,
            .shadowing,
            .shim_inspect_error,
            .shim_wrong_target,
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
            => {},
        }
        self.* = undefined;
    }
};

const ReportState = struct {
    entries: std.ArrayList(Finding) = .empty,
};

pub const Report = opaque {
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

pub fn inspect(allocator: std.mem.Allocator) !*Report {
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

    return report;
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
}
