const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const clap = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("clap", clap.module("clap"));

    const exe = b.addExecutable(.{
        .name = "glolias",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const glolias_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    glolias_mod.addImport("clap", clap.module("clap"));

    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/unit.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "glolias", .module = glolias_mod },
        },
    });

    const unit_tests = b.addTest(.{
        .name = "unit",
        .root_module = test_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const e2e = b.addSystemCommand(&.{ "tests/bats/bin/bats", "tests" });
    e2e.setEnvironmentVariable("GLOLIAS_BIN", b.getInstallPath(.bin, "glolias"));
    e2e.step.dependOn(b.getInstallStep());

    const e2e_step = b.step("e2e", "Run bats end-to-end tests");
    e2e_step.dependOn(&e2e.step);
}
