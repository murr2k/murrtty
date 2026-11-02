//! A texture (opengl/Texture.zig's counterpart): a view to sample it, and
//! a render target view for those drawn into (the custom shaders').
const Self = @This();

const std = @import("std");
const d3d11 = @import("d3d11");
const com = d3d11.com;
const d3d = d3d11.d3d;
const dxgi = d3d11.dxgi;

const log = std.log.scoped(.d3d11);

pub const Options = struct {
    gpu: *d3d.Device,
    ctx: *d3d.DeviceContext,
    /// An sRGB format decodes as it is sampled (and encodes as it is drawn
    /// into), as OpenGL's sRGB internal formats do.
    format: dxgi.Format,
    bytes_per_pixel: u32,
    render_target: bool = false,
};

tex: *d3d.Texture2D,
srv: *d3d.ShaderResourceView,
rtv: ?*d3d.RenderTargetView,
ctx: *d3d.DeviceContext,
bytes_per_pixel: u32,

/// The width of this texture.
width: usize,
/// The height of this texture.
height: usize,

pub const Error = error{
    /// A Direct3D 11 call failed.
    D3D11Failed,
};

pub fn init(
    opts: Options,
    width: usize,
    height: usize,
    data: ?[]const u8,
) Error!Self {
    const w: u32 = @intCast(@max(width, 1));
    const h: u32 = @intCast(@max(height, 1));
    const desc: d3d.Texture2DDesc = .{
        .Width = w,
        .Height = h,
        .Format = opts.format,
        .BindFlags = d3d.BIND_SHADER_RESOURCE | if (opts.render_target) d3d.BIND_RENDER_TARGET else 0,
    };
    const initial: ?d3d.SubresourceData = if (data) |d| .{ .pSysMem = d.ptr, .SysMemPitch = w * opts.bytes_per_pixel } else null;
    var tex: ?*d3d.Texture2D = null;
    const hr = opts.gpu.createTexture2D(&desc, if (initial) |*i| i else null, &tex);
    if (!com.succeeded(hr)) {
        log.warn("creating a {d}x{d} {t} texture failed hr=0x{x:0>8}", .{ w, h, opts.format, @as(u32, @bitCast(hr)) });
        return error.D3D11Failed;
    }
    errdefer com.release(tex.?);
    var srv: ?*d3d.ShaderResourceView = null;
    if (!com.succeeded(opts.gpu.createShaderResourceView(tex.?.resource(), null, &srv))) return error.D3D11Failed;
    errdefer com.release(srv.?);
    var rtv: ?*d3d.RenderTargetView = null;
    if (opts.render_target) {
        if (!com.succeeded(opts.gpu.createRenderTargetView(tex.?.resource(), null, &rtv))) return error.D3D11Failed;
    }
    return .{
        .tex = tex.?,
        .srv = srv.?,
        .rtv = rtv,
        .ctx = opts.ctx,
        .bytes_per_pixel = opts.bytes_per_pixel,
        .width = width,
        .height = height,
    };
}

pub fn deinit(self: Self) void {
    if (self.rtv) |v| com.release(v);
    com.release(self.srv);
    com.release(self.tex);
}

/// Replace a region of the texture with `data` (rows of `width` pixels,
/// tightly packed). The dimensions are not checked.
pub fn replaceRegion(
    self: Self,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    data: []const u8,
) Error!void {
    if (width == 0 or height == 0) return;
    const box: d3d.Box = .{
        .left = @intCast(x),
        .top = @intCast(y),
        .right = @intCast(x + width),
        .bottom = @intCast(y + height),
    };
    self.ctx.updateSubresource(self.tex.resource(), 0, &box, data.ptr, @intCast(width * self.bytes_per_pixel), 0);
}
