//! A render target: the frame the passes draw into, which the present
//! pass then puts in the pane's swap chain (opengl/Target.zig's
//! counterpart). sRGB, as OpenGL's SRGB8_ALPHA8 target with
//! GL_FRAMEBUFFER_SRGB always on: writes encode, blending and loads
//! decode, whatever the alpha-blending mode (the frames are compared with
//! OpenGL's).
const Self = @This();

const std = @import("std");
const d3d11 = @import("d3d11");
const com = d3d11.com;
const d3d = d3d11.d3d;

const log = std.log.scoped(.d3d11);

pub const Options = struct {
    gpu: *d3d.Device,
    width: usize,
    height: usize,
};

tex: *d3d.Texture2D,
rtv: *d3d.RenderTargetView,
srv: *d3d.ShaderResourceView,

/// Current width of this target.
width: usize,
/// Current height of this target.
height: usize,

pub fn init(opts: Options) !Self {
    const desc: d3d.Texture2DDesc = .{
        .Width = @intCast(@max(opts.width, 1)),
        .Height = @intCast(@max(opts.height, 1)),
        .Format = .r8g8b8a8_unorm_srgb,
        .BindFlags = d3d.BIND_RENDER_TARGET | d3d.BIND_SHADER_RESOURCE,
    };
    var tex: ?*d3d.Texture2D = null;
    const hr = opts.gpu.createTexture2D(&desc, null, &tex);
    if (!com.succeeded(hr)) {
        log.warn("creating a {d}x{d} target failed hr=0x{x:0>8}", .{ opts.width, opts.height, @as(u32, @bitCast(hr)) });
        return error.D3D11Failed;
    }
    errdefer com.release(tex.?);
    var rtv: ?*d3d.RenderTargetView = null;
    if (!com.succeeded(opts.gpu.createRenderTargetView(tex.?.resource(), null, &rtv))) return error.D3D11Failed;
    errdefer com.release(rtv.?);
    var srv: ?*d3d.ShaderResourceView = null;
    if (!com.succeeded(opts.gpu.createShaderResourceView(tex.?.resource(), null, &srv))) return error.D3D11Failed;
    return .{
        .tex = tex.?,
        .rtv = rtv.?,
        .srv = srv.?,
        .width = opts.width,
        .height = opts.height,
    };
}

pub fn deinit(self: *Self) void {
    com.release(self.srv);
    com.release(self.rtv);
    com.release(self.tex);
}
