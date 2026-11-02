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
        return .opengl;
    }
};
