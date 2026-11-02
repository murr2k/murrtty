//! The GUI test harness builds on its own, so it needs no changes to
//! Ghostty's build.zig. From the repository root:
//!
//!   zig build --build-file test\windows\gui\build.zig run -- --ghostty zig-out\bin\murrtty.exe
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

    // The handler that the links-open scenario registers (see record.zig),
    // installed beside the harness, which finds it there.
    const record = b.addExecutable(.{
        .name = "ghostty-gui-record",
        .root_module = b.createModule(.{
            .root_source_file = b.path("record.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    record.subsystem = .windows;
    b.installArtifact(record);

    // The uia scenario's UI Automation client (see uia_client.zig), run on
    // the hidden desktop as a screen reader would read a pane.
    const uia = b.addExecutable(.{
        .name = "ghostty-gui-uia",
        .root_module = b.createModule(.{
            .root_source_file = b.path("uia_client.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(uia);

    // The d3d-spike scenario's Direct3D 11 probe (spike S7, roadmap 7.8),
    // on murrtty's own bindings.
    const d3d11 = b.createModule(.{
        .root_source_file = b.path("../../../pkg/d3d11/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const d3d = b.addExecutable(.{
        .name = "ghostty-gui-d3d",
        .root_module = b.createModule(.{
            .root_source_file = b.path("d3d_spike.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "d3d11", .module = d3d11 }},
        }),
    });
    // murrtty's manifest: layered child windows need its Windows 10
    // supportedOS entry, and its DPI awareness is murrtty's.
    d3d.win32_manifest = b.path("../../../dist/windows/murrtty.manifest");
    b.installArtifact(d3d);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the GUI tests").dependOn(&run.step);
}
