const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = b.addModule("d3d11", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
}
