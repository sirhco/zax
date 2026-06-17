const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Forward -Dtrace-latency to the zax path dependency so the bench server
    // can be built with phase timers: `zig build -Dtrace-latency=true -Doptimize=ReleaseFast`
    const trace_latency = b.option(bool, "trace-latency", "Enable compile-time phase timers in handleConn (default: false)") orelse false;

    // zax is pulled in as a path dependency on the repo root (see build.zig.zon).
    const zax = b.dependency("zax", .{
        .target = target,
        .optimize = optimize,
        .@"trace-latency" = trace_latency,
    });

    const exe = b.addExecutable(.{
        .name = "zax-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zax", .module = zax.module("zax") },
            },
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run the zax cross-bench server");
    run_step.dependOn(&run.step);
}
