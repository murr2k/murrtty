//! Hand-written bindings for Direct3D 11, DXGI, DirectComposition and the
//! HLSL compiler, for murrtty's Direct3D 11 renderer (roadmap 7.8).
pub const com = @import("com.zig");
pub const dxgi = @import("dxgi.zig");
pub const d3d = @import("d3d.zig");
pub const dcomp = @import("dcomp.zig");
pub const compiler = @import("compiler.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("test.zig");
}
