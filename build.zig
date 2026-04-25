const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --------------------------- IMPORTS -----------------------------
    const clap = b.dependency("clap", .{}).module("clap");
    const build_zig_zon = b.createModule(.{
        .root_source_file = b.path("build.zig.zon"),
        .target = target,
        .optimize = optimize,
    });

    // --------------------------- ZLOCK MODULE ---------------------------
    // note: zlock module is created so that other projects can use it with zig fetch and @import("zwol").
    const zlock = b.addModule("zlock", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --------------------------- EXECUTABLE ---------------------------
    const exe = b.addExecutable(.{
        .name = "zlock",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zlock", .module = zlock },
                .{ .name = "clap", .module = clap },
                .{ .name = "build_zig_zon", .module = build_zig_zon },
            },
        }),
    });
    b.installArtifact(exe);

    // ------------------------------ RUN -------------------------------
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // ------------------------------ TEST ------------------------------
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
