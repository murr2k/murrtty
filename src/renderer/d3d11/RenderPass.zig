//! A render pass (opengl/RenderPass.zig's counterpart). Bindings as
//! OpenGL's and Metal's: the uniforms at b1, kept bound for the whole pass
//! (the image steps pass none and draw with the last); a step's buffer 0
//! is its per-instance data, the rest storage buffers at t2 on; textures
//! at t0 and t1; samplers at s0 on, linear and clamped by default.
const Self = @This();

const std = @import("std");
const d3d11 = @import("d3d11");
const com = d3d11.com;
const d3d = d3d11.d3d;

const Sampler = @import("Sampler.zig");
const Target = @import("Target.zig");
const Texture = @import("Texture.zig");
const Pipeline = @import("Pipeline.zig");
const Raw = @import("buffer.zig").Raw;

pub const Options = struct {
    /// Color attachments for this render pass.
    attachments: []const Attachment,

    pub const Attachment = struct {
        target: union(enum) {
            texture: Texture,
            target: Target,
        },
        clear_color: ?[4]f32 = null,
    };
};

pub const Primitive = enum { triangle, triangle_strip };

/// Describes a step in a render pass.
pub const Step = struct {
    pipeline: Pipeline,
    uniforms: ?Raw = null,
    buffers: []const ?Raw = &.{},
    textures: []const ?Texture = &.{},
    samplers: []const ?Sampler = &.{},
    draw: Draw,

    /// Describes the draw call for this step.
    pub const Draw = struct {
        type: Primitive,
        vertex_count: usize,
        instance_count: usize = 1,
    };
};

/// What every pass shares, the pane's (D3D11.Common).
pub const Defaults = struct {
    raster: *d3d.RasterizerState,
    sampler: *d3d.SamplerState,
};

/// Texture and storage buffer slots a step may bind (t0 to t3).
const views = 4;

ctx: *d3d.DeviceContext,
attachments: []const Options.Attachment,
step_number: usize = 0,

pub fn begin(opts: Options, ctx: *d3d.DeviceContext, defaults: Defaults) Self {
    const self: Self = .{ .ctx = ctx, .attachments = opts.attachments };
    // What the last pass sampled may be drawn into now (the custom shaders'
    // textures): unbind it first.
    const none: [views]?*d3d.ShaderResourceView = @splat(null);
    ctx.vsSetShaderResources(0, &none);
    ctx.psSetShaderResources(0, &none);
    const view = self.renderTargetView();
    ctx.omSetRenderTargets(&.{view});
    const extent = self.attachmentSize();
    ctx.rsSetViewports(&.{.{ .Width = @floatFromInt(extent[0]), .Height = @floatFromInt(extent[1]) }});
    ctx.rsSetState(defaults.raster);
    ctx.psSetSamplers(0, &.{defaults.sampler});
    return self;
}

fn renderTargetView(self: *const Self) *d3d.RenderTargetView {
    return switch (self.attachments[0].target) {
        .target => |t| t.rtv,
        .texture => |t| t.rtv.?,
    };
}

fn attachmentSize(self: *const Self) [2]usize {
    return switch (self.attachments[0].target) {
        .target => |t| .{ @max(t.width, 1), @max(t.height, 1) },
        .texture => |t| .{ @max(t.width, 1), @max(t.height, 1) },
    };
}

/// Add a step to this render pass.
pub fn step(self: *Self, s: Step) void {
    if (s.draw.instance_count == 0) return;
    const ctx = self.ctx;
    defer self.step_number += 1;

    // The attachment's clear color, at the pass's first step.
    if (self.step_number == 0) if (self.attachments[0].clear_color) |c| {
        ctx.clearRenderTargetView(self.renderTargetView(), &c);
    };

    if (s.uniforms) |u| {
        ctx.vsSetConstantBuffers(1, &.{u.buf});
        ctx.psSetConstantBuffers(1, &.{u.buf});
    }

    for (s.textures, 0..) |t, i| if (t) |tex| {
        ctx.vsSetShaderResources(@intCast(i), &.{tex.srv});
        ctx.psSetShaderResources(@intCast(i), &.{tex.srv});
    };

    for (s.samplers, 0..) |sm, i| if (sm) |sampler| {
        ctx.psSetSamplers(@intCast(i), &.{sampler.sampler});
    };

    if (s.buffers.len > 0) {
        if (s.buffers[0]) |vb| {
            ctx.iaSetVertexBuffers(0, &.{vb.buf}, &.{s.pipeline.stride}, &.{0});
        }
        for (s.buffers[1..], 1..) |b, i| if (b) |buf| if (buf.srv) |srv| {
            ctx.vsSetShaderResources(@intCast(1 + i), &.{srv});
            ctx.psSetShaderResources(@intCast(1 + i), &.{srv});
        };
    }

    ctx.iaSetInputLayout(s.pipeline.layout);
    ctx.iaSetPrimitiveTopology(switch (s.draw.type) {
        .triangle => .triangle_list,
        .triangle_strip => .triangle_strip,
    });
    ctx.vsSetShader(s.pipeline.vs);
    ctx.psSetShader(s.pipeline.ps);
    ctx.omSetBlendState(s.pipeline.blend);

    ctx.drawInstanced(
        @intCast(s.draw.vertex_count),
        @intCast(s.draw.instance_count),
        0,
        0,
    );
}

/// Complete this render pass.
pub fn complete(self: *const Self) void {
    _ = self;
}
