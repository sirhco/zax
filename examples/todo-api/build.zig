const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zax = b.dependency("zax", .{ .target = target, .optimize = optimize }).module("zax");
    const exe = b.addExecutable(.{
        .name = "todo-api",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zax", .module = zax }},
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the todo-api").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = exe.root_module });
    b.step("test", "Run todo-api tests").dependOn(&b.addRunArtifact(tests).step);
}
