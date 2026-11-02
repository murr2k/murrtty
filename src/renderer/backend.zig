const std = @import("std");
const WasmTarget = @import("../os/wasm/target.zig").Target;

/// Possible implementations, used for build options.
pub const Backend = enum {
    opengl,
    metal,
    /// murrtty's Windows renderer (roadmap 7.8).
    d3d11,

    pub fn default(
        target: std.Target,
        wasm_target: WasmTarget,
    ) Backend {
        _ = wasm_target;
        if (target.os.tag.isDarwin()) return .metal;
        // murrtty: Direct3D 11 on Windows (roadmap 7.8, step 6), drawing
        // what OpenGL draws pixel for pixel (render-parity), on any
        // Direct3D 11 device or Windows' WARP. -Drenderer=opengl remains.
        if (target.os.tag == .windows) return .d3d11;
        return .opengl;
    }
};
