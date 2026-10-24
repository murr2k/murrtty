//! The GUI test harness builds on its own, so it needs no changes to
//! Ghostty's build.zig. From the repository root:
//!
//!   zig build --build-file test\windows\gui\build.zig run -- --ghostty zig-out\bin\ghostty.exe
//!
//! or test\windows\gui\run.cmd, which also builds a Debug Ghostty first.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu });
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "ghostty-gui-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the GUI tests").dependOn(&run.step);
}
