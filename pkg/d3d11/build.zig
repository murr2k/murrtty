const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = b.addModule("d3d11", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The build-time shader compiler (dxbc.zig), for the build machine:
    // murrtty's DxbcStep runs it.
    const tool = b.addExecutable(.{
        .name = "murrtty-dxbc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("dxbc.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    b.installArtifact(tool);
}
