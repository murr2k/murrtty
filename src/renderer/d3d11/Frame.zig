//! A frame (opengl/Frame.zig's counterpart): its render passes, then the
//! present into the pane's swap chain.
const Self = @This();

const std = @import("std");

const Renderer = @import("../generic.zig").Renderer(D3D11);
const D3D11 = @import("../D3D11.zig");
const Target = @import("Target.zig");
const RenderPass = @import("RenderPass.zig");

const Health = @import("../../renderer.zig").Health;

const log = std.log.scoped(.d3d11);

pub const Options = struct {};

renderer: *Renderer,
target: *Target,

pub fn begin(
    opts: Options,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Self {
    _ = opts;
    return .{
        .renderer = renderer,
        .target = target,
    };
}

/// A render pass into `attachments`.
pub inline fn renderPass(
    self: *const Self,
    attachments: []const RenderPass.Options.Attachment,
) RenderPass {
    const api = &self.renderer.api;
    return RenderPass.begin(.{ .attachments = attachments }, api.ctx, api.passDefaults());
}

/// Present the target and report the frame's health; `frameCompleted` is
/// called exactly once, or the swap chain's semaphore blocks the next
/// frame. Never blocks on the GPU (`sync` doesn't matter here).
pub fn complete(self: *const Self, sync: bool) void {
    _ = sync;
    const uniforms = &self.renderer.uniforms;
    var health: Health = .healthy;
    self.renderer.api.present(self.target.*, .{
        .rgb = uniforms.bg_color[0..3].*,
        .alpha = uniforms.bg_color[3],
        .linear = uniforms.bools.use_linear_blending,
    }) catch |err| {
        log.warn("failed to present the frame err={}", .{err});
        health = .unhealthy;
    };
    self.renderer.frameCompleted(health);
}
