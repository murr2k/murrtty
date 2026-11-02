//! The Direct3D 11 renderer's programs (src/renderer/shaders/hlsl),
//! compiled to DXBC at build time (roadmap 7.8) by pkg/d3d11's tool,
//! which loads System32's d3dcompiler_47.dll: on a Windows build machine
//! only. Elsewhere the module is a stub, and the renderer compiles them
//! at run time. The list mirrors `src/renderer/d3d11/shaders.zig`'s
//! `sources`; a unit test there fails when a program is missing.
const std = @import("std");

const Program = struct {
    name: []const u8,
    vs: []const u8,
    /// "-": no pixel stage.
    ps: []const u8,
    files: []const []const u8,
};

const programs = [_]Program{
    .{ .name = "bg_color", .vs = "full_screen_vs", .ps = "ps_main", .files = &.{ "common.hlsl", "bg_color.hlsl" } },
    .{ .name = "cell_bg", .vs = "full_screen_vs", .ps = "ps_main", .files = &.{ "common.hlsl", "cell_bg.hlsl" } },
    .{ .name = "cell_text", .vs = "vs_main", .ps = "ps_main", .files = &.{ "common.hlsl", "cell_text.hlsl" } },
    .{ .name = "image", .vs = "vs_main", .ps = "ps_main", .files = &.{ "common.hlsl", "image.hlsl" } },
    .{ .name = "bg_image", .vs = "vs_main", .ps = "ps_main", .files = &.{ "common.hlsl", "bg_image.hlsl" } },
    .{ .name = "present", .vs = "vs_main", .ps = "ps_main", .files = &.{"present.hlsl"} },
    .{ .name = "shapes", .vs = "vs_main", .ps = "ps_main", .files = &.{"shapes.hlsl"} },
    .{ .name = "post", .vs = "full_screen_vs", .ps = "-", .files = &.{"common.hlsl"} },
};

/// The "murrtty_dxbc" module's root: the generated dxbc.zig, or the stub.
pub fn module(b: *std.Build, dep: *std.Build.Dependency) std.Build.LazyPath {
    if (b.graph.host.result.os.tag != .windows) return b.path("src/renderer/d3d11/dxbc_none.zig");
    const run = b.addRunArtifact(dep.artifact("murrtty-dxbc"));
    run.setName("compile the Direct3D 11 shaders");
    const out = run.addOutputDirectoryArg("dxbc");
    for (programs) |p| {
        run.addArgs(&.{ "--program", p.name, p.vs, p.ps });
        for (p.files) |file| {
            run.addArg("--file");
            run.addFileArg(b.path(b.fmt("src/renderer/shaders/hlsl/{s}", .{file})));
        }
    }
    return out.path(b, "dxbc.zig");
}
