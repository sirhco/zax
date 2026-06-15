const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Pull in the Zax dependency declared in build.zig.zon and grab its public
    // "zax" module. This is the canonical consumer wiring.
    const zax = b.dependency("zax", .{
        .target = target,
        .optimize = optimize,
    }).module("zax");

    const exe = b.addExecutable(.{
        .name = "hello-service",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zax", .module = zax },
            },
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run the hello-service");
    run_step.dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run hello-service tests");
    test_step.dependOn(&run_tests.step);
}
