//! Graphics API wrapper for Direct3D 11 (murrtty's roadmap 7.8): the
//! Windows renderer that needs no OpenGL driver. Each pane draws with a
//! device of its own (WARP without a GPU, in the same process) into a
//! frame, which the present pass puts into a flip-model swap chain made for
//! composition and shown by a DirectComposition visual on the pane's
//! window, under the window's own children (the layered overlays) and with
//! per-pixel alpha. The frames are OpenGL's pixel for pixel: murrtty looks
//! like GTK's app, which draws with OpenGL (render-parity checks it).
pub const D3D11 = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const d3d11 = @import("d3d11");
const com = d3d11.com;
const d3d = d3d11.d3d;
const dxgi = d3d11.dxgi;
const dcomp = d3d11.dcomp;
const shadertoy = @import("shadertoy.zig");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(D3D11);
const win32_present = @import("win32_present.zig");

pub const GraphicsAPI = D3D11;
pub const Device = @import("d3d11/Device.zig");
pub const Target = @import("d3d11/Target.zig");
pub const Frame = @import("d3d11/Frame.zig");
pub const RenderPass = @import("d3d11/RenderPass.zig");
pub const Pipeline = @import("d3d11/Pipeline.zig");
const bufferpkg = @import("d3d11/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("d3d11/Sampler.zig");
pub const Texture = @import("d3d11/Texture.zig");
pub const shaders = @import("d3d11/shaders.zig");

// Custom shaders: GLSL to SPIR-V to HLSL (spirv-cross), compiled when
// the shaders are made.
pub const custom_shader_target: shadertoy.Target = .hlsl;
// SV_Position's origin is the top left.
pub const custom_shader_y_is_down = true;

/// Frames in flight, as the other backends.
pub const swap_chain_count = 3;

pub const Overlay = win32_present.Overlay;
pub const Background = win32_present.Background;

const log = std.log.scoped(.d3d11);

alloc: Allocator,

/// Alpha blending mode
blending: configpkg.Config.AlphaBlending,

/// The shared render device.
device: *Device,

/// This pane's device and its immediate context, used by its render
/// thread alone (and the UI thread before it starts and after it ends).
gpu: *d3d.Device,
ctx: *d3d.DeviceContext,
/// The frames are drawn on the CPU (WARP, Microsoft's Basic Render
/// Driver).
software: bool,

/// The pane's window, which the swap chain's visual sits on.
hwnd: *anyopaque,
swap: Swap,
common: Common,
/// The present pass's programs, made at the first present.
presenter: ?Presenter = null,

/// The surface's size, as the renderer last set it.
viewport: [2]u32,

/// What the Windows runtime shares with the present (win32_present.zig).
present_state: win32_present.State,

/// A lost device (a GPU driver reset or removal, or the tests' fake): the
/// renderer builds itself again on a new one (`contextLost`,
/// `replaceContext`, `dropLostContext`). `lost` holds until one is made
/// (`tries` so far, the last at `last_try`, in milliseconds since boot);
/// `old` is the lost one's, until the renderer has released what it made.
lost: bool = false,
tries: u32 = 0,
last_try: u64 = 0,
old: ?Old = null,

const Old = struct {
    gpu: *d3d.Device,
    ctx: *d3d.DeviceContext,
    swap: Swap,
    common: Common,
    presenter: ?Presenter,
};

pub fn init(
    alloc: Allocator,
    device: *Device,
    opts: rendererpkg.Options,
) !D3D11 {
    if (comptime !@hasDecl(apprt.Surface, "nativeWindow")) {
        @compileError("the apprt must provide nativeWindow() for the Direct3D 11 renderer");
    }
    const hwnd = opts.rt_surface.nativeWindow();
    const size = clientSize(hwnd);

    const made = try device.createDevice(.{});
    errdefer {
        com.release(made.ctx);
        com.release(made.gpu);
    }
    var swap = try Swap.create(made.gpu, made.ctx, hwnd, size[0], size[1]);
    errdefer swap.release();
    var common = try Common.create(made.gpu);
    errdefer common.release();

    var name_buf: [256]u8 = undefined;
    log.info("drawing with Direct3D 11 on {s}{s}", .{ Device.adapterName(made.gpu, &name_buf), if (made.software) " (software)" else "" });

    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .device = device,
        .gpu = made.gpu,
        .ctx = made.ctx,
        .software = made.software,
        .hwnd = hwnd,
        .swap = swap,
        .common = common,
        .viewport = size,
        // A pane opening in a translucent window presents so from its
        // first frame. Direct3D always reports a lost device: robust.
        .present_state = .init(
            if (@hasDecl(apprt.Surface, "translucent")) opts.rt_surface.translucent() else false,
            true,
        ),
    };
}

pub fn deinit(self: *D3D11) void {
    self.dropLostContext();
    self.ctx.clearState();
    self.ctx.flush();
    if (self.presenter) |*p| p.release();
    self.common.release();
    self.swap.release();
    com.release(self.ctx);
    com.release(self.gpu);
    self.* = undefined;
}

fn clientSize(hwnd: *anyopaque) [2]u32 {
    var client: RECT = .{};
    _ = GetClientRect(hwnd, &client);
    return .{ @intCast(@max(client.right, 1)), @intCast(@max(client.bottom, 1)) };
}

/// murrtty: whether the device was lost (removed, reset, or the tests'
/// fake) and no new one made yet. At each frame's start, on the render
/// thread.
pub fn contextLost(self: *D3D11) bool {
    if (self.lost) return true;
    const fake = self.present_state.fake_reset.swap(false, .acq_rel);
    const reason = self.gpu.getDeviceRemovedReason();
    if (!fake and com.succeeded(reason)) return false;
    log.warn("the Direct3D device was lost reason=0x{x:0>8}; making a new one", .{@as(u32, @bitCast(reason))});
    self.lost = true;
    return true;
}

/// murrtty: a new device, swap chain and composition for the pane. The
/// lost one's are kept for `dropLostContext`, released after the renderer
/// has released what it made with them. False if none could be made, or
/// the last try was under a second ago: the renderer draws nothing until
/// a later try.
pub fn replaceContext(self: *D3D11) bool {
    const now = GetTickCount64();
    if (self.tries > 0 and now -% self.last_try < 1000) return false;
    self.last_try = now;
    self.tries +|= 1;
    // The window holds one composition target per layer: the old one goes
    // before a new one is made.
    self.swap.releaseComposition();
    const size = clientSize(self.hwnd);
    // The GPU for the first 5 tries (a second apart: a driver reset takes
    // about 2 s), then WARP for this pane alone.
    const made = self.device.createDevice(.{ .recovering = true, .gpu_only = self.tries <= 5 }) catch |err| {
        if (self.tries == 1) log.err("no new Direct3D device after the loss err={}; trying again each second", .{err});
        return false;
    };
    var swap = Swap.create(made.gpu, made.ctx, self.hwnd, size[0], size[1]) catch |err| {
        if (self.tries == 1) log.err("no swap chain on the new device err={}", .{err});
        com.release(made.ctx);
        com.release(made.gpu);
        return false;
    };
    const common = Common.create(made.gpu) catch {
        swap.release();
        com.release(made.ctx);
        com.release(made.gpu);
        return false;
    };
    // A loss before the last one's leftovers went: those first.
    self.dropLostContext();
    self.old = .{
        .gpu = self.gpu,
        .ctx = self.ctx,
        .swap = self.swap,
        .common = self.common,
        .presenter = self.presenter,
    };
    self.gpu = made.gpu;
    self.ctx = made.ctx;
    self.software = made.software;
    self.swap = swap;
    self.common = common;
    self.presenter = null;
    self.lost = false;
    self.tries = 0;
    _ = self.present_state.contexts.fetchAdd(1, .monotonic);
    log.info("made a new Direct3D device after the loss", .{});
    return true;
}

/// murrtty: release the lost device's leftovers.
pub fn dropLostContext(self: *D3D11) void {
    var old = self.old orelse return;
    self.old = null;
    old.ctx.clearState();
    if (old.presenter) |*p| p.release();
    old.common.release();
    old.swap.release();
    com.release(old.ctx);
    com.release(old.gpu);
}

/// The surface's size, as the renderer set it (setViewport).
pub fn surfaceSize(self: *const D3D11) !struct { width: u32, height: u32 } {
    return .{ .width = self.viewport[0], .height = self.viewport[1] };
}

pub fn setViewport(self: *D3D11, width: u32, height: u32) void {
    self.viewport = .{ width, height };
}

pub fn drawFrameStart(self: *D3D11) void {
    _ = self;
}

pub fn drawFrameEnd(self: *D3D11) void {
    _ = self;
}

pub fn initShaders(
    self: *const D3D11,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    _ = alloc;
    return try shaders.Shaders.init(self.alloc, self.gpu, self.device, custom_shaders);
}

/// A new frame of `width` x `height`.
pub fn initTarget(self: *const D3D11, width: usize, height: usize) !Target {
    return Target.init(.{ .gpu = self.gpu, .width = width, .height = height });
}

/// What every render pass binds.
pub fn passDefaults(self: *const D3D11) RenderPass.Defaults {
    return .{ .raster = self.common.raster, .sampler = self.common.linear };
}

/// Put the frame into the pane's swap chain and present it (OpenGL.zig's
/// presentWgl is the spec): the frame (premultiplied) over the opaque
/// terminal background, or with its own alpha when the window is
/// translucent, at the top left, the background where it doesn't reach
/// (a resize under way); then the shapes; then the tests' read-back.
pub fn present(self: *D3D11, target: Target, background: Background) !void {
    const ps = &self.present_state;
    const probe_point = ps.takeProbe();
    // At most one frame queued (latency 1): wait for its turn, briefly.
    if (self.swap.waitable) |h| _ = WaitForSingleObjectEx(h, 100, 0);

    const size = clientSize(self.hwnd);
    // Also when a view is missing: a resize that failed partway (the
    // buffers' resize, or the views after it) left them released.
    if (size[0] != self.swap.width or size[1] != self.swap.height or
        self.swap.rtv == null or self.swap.rtv_srgb == null)
    {
        try self.swap.resize(self.gpu, self.ctx, size[0], size[1]);
    }
    const p = self.presenter orelse made: {
        self.presenter = try Presenter.create(self.gpu, self.device);
        break :made self.presenter.?;
    };
    const ctx = self.ctx;
    const transparent = ps.transparent.load(.monotonic);

    var bg: [4]f32 = .{ 0, 0, 0, 1 };
    for (background.rgb, bg[0..3]) |v, *out| {
        const f = @as(f32, @floatFromInt(v)) / 255.0;
        out.* = if (background.linear) srgbToLinear(f) else f;
    }
    {
        var mapped: d3d.MappedSubresource = .{};
        if (!com.succeeded(ctx.map(p.constants.resource(), 0, .write_discard, &mapped))) return error.D3D11Failed;
        const c: *PresentConstants = @ptrCast(@alignCast(mapped.pData.?));
        c.* = .{
            .background = bg,
            .frame_size = .{ @floatFromInt(target.width), @floatFromInt(target.height) },
            .background_alpha = @as(f32, @floatFromInt(background.alpha)) / 255.0,
            .flags = (if (transparent) @as(u32, 1) else 0) | (if (background.linear) @as(u32, 2) else 0),
        };
        ctx.unmap(p.constants.resource(), 0);
    }

    // A linear frame (linear blending) is stored through the sRGB view,
    // which encodes on write, as OpenGL's GL_FRAMEBUFFER_SRGB does. With
    // native blending it already holds sRGB values, and a translucent
    // window's are encoded by the shader (premultiplied): the plain view.
    const srgb_off = !background.linear or transparent;
    ctx.omSetRenderTargets(&.{if (srgb_off) self.swap.rtv.? else self.swap.rtv_srgb.?});
    ctx.rsSetViewports(&.{.{ .Width = @floatFromInt(size[0]), .Height = @floatFromInt(size[1]) }});
    ctx.rsSetState(self.common.raster);
    ctx.iaSetInputLayout(null);
    ctx.iaSetPrimitiveTopology(.triangle_list);
    ctx.vsSetShader(p.vs);
    ctx.psSetShader(p.ps);
    ctx.psSetConstantBuffers(0, &.{p.constants});
    ctx.psSetShaderResources(0, &.{target.srv});
    ctx.omSetBlendState(null);
    ctx.draw(3, 0);
    ctx.psSetShaderResources(0, &.{null});

    const overlay = ps.overlayNow();
    if (overlay.len > 0) try self.drawShapes(p, &overlay, size);

    ps.readBack(probe_point, size[0], size[1], BackBuffer{ .api = self }, BackBuffer.pixel, BackBuffer.whole);
    ctx.omSetRenderTargets(&.{});

    const hr = self.swap.chain.present(0, 0);
    if (dxgi.deviceLost(hr)) {
        self.lost = true;
        return error.DeviceLost;
    }
    // DXGI_STATUS_OCCLUDED (a hidden desktop, a minimized window) is a
    // success: nothing to do.
    if (!com.succeeded(hr)) {
        log.warn("Present failed hr=0x{x:0>8}", .{@as(u32, @bitCast(hr))});
        return error.PresentFailed;
    }
    // Counted once on the window: UI Automation's poll takes it as new
    // text.
    _ = ps.presented.fetchAdd(1, .monotonic);
}

const PresentConstants = extern struct {
    background: [4]f32,
    frame_size: [2]f32,
    background_alpha: f32,
    flags: u32,
};

const ShapesConstants = extern struct {
    window_size: [2]f32,
    _pad: [2]f32 = .{ 0, 0 },
};

/// One shape: its rect (window pixels) and premultiplied sRGB color.
const ShapeInstance = extern struct {
    rect: [4]f32,
    color: [4]f32,
};

/// The overlay's rectangles over the presented frame, blending in the
/// stored (sRGB) values as GTK's CSS does: through the plain view.
fn drawShapes(self: *D3D11, p: Presenter, overlay: *const Overlay, size: [2]u32) !void {
    const ctx = self.ctx;
    {
        var mapped: d3d.MappedSubresource = .{};
        if (!com.succeeded(ctx.map(p.shapes.resource(), 0, .write_discard, &mapped))) return error.D3D11Failed;
        defer ctx.unmap(p.shapes.resource(), 0);
        const out: [*]ShapeInstance = @ptrCast(@alignCast(mapped.pData.?));
        for (overlay.rects[0..overlay.len], 0..) |r, i| {
            const a = r.color[3];
            out[i] = .{
                .rect = .{ @floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.width), @floatFromInt(r.height) },
                .color = .{ r.color[0] * a, r.color[1] * a, r.color[2] * a, a },
            };
        }
    }
    {
        var mapped: d3d.MappedSubresource = .{};
        if (!com.succeeded(ctx.map(p.shapes_constants.resource(), 0, .write_discard, &mapped))) return error.D3D11Failed;
        const c: *ShapesConstants = @ptrCast(@alignCast(mapped.pData.?));
        c.* = .{ .window_size = .{ @floatFromInt(size[0]), @floatFromInt(size[1]) } };
        ctx.unmap(p.shapes_constants.resource(), 0);
    }
    ctx.omSetRenderTargets(&.{self.swap.rtv.?});
    ctx.iaSetInputLayout(p.shapes_layout);
    ctx.iaSetVertexBuffers(0, &.{p.shapes}, &.{@sizeOf(ShapeInstance)}, &.{0});
    ctx.iaSetPrimitiveTopology(.triangle_list);
    ctx.vsSetShader(p.shapes_vs);
    ctx.psSetShader(p.shapes_ps);
    ctx.vsSetConstantBuffers(0, &.{p.shapes_constants});
    ctx.omSetBlendState(self.common.premultiplied);
    ctx.drawInstanced(6, @intCast(overlay.len), 0, 0);
    ctx.omSetBlendState(null);
}

/// The swap chain's buffer, read for the GUI tests (win32_present's
/// readBack) through staging copies.
const BackBuffer = struct {
    api: *D3D11,

    /// A pixel as 0x00RRGGBB, as stored.
    fn pixel(self: BackBuffer, x: u32, y: u32) u32 {
        var px: [4]u8 = undefined;
        if (!self.copy(x, y, 1, 1, &px, 4)) return 0;
        // BGRA.
        return @as(u32, px[2]) << 16 | @as(u32, px[1]) << 8 | px[0];
    }

    /// The whole of it, BGRA rows top first (page_allocator).
    fn whole(self: BackBuffer, w: u32, h: u32) ?[]u8 {
        if (w == 0 or h == 0) return null;
        const pixels = std.heap.page_allocator.alloc(u8, @as(usize, w) * h * 4) catch return null;
        if (!self.copy(0, 0, w, h, pixels, w * 4)) {
            std.heap.page_allocator.free(pixels);
            return null;
        }
        return pixels;
    }

    fn copy(self: BackBuffer, x: u32, y: u32, w: u32, h: u32, out: []u8, pitch: u32) bool {
        const api = self.api;
        const buf = api.swap.buffer orelse return false;
        var staging: ?*d3d.Texture2D = null;
        if (!com.succeeded(api.gpu.createTexture2D(&.{
            .Width = w,
            .Height = h,
            .Format = .b8g8r8a8_unorm,
            .Usage = .staging,
            .BindFlags = 0,
            .CPUAccessFlags = d3d.CPU_ACCESS_READ,
        }, null, &staging))) return false;
        defer com.release(staging.?);
        api.ctx.copySubresourceRegion(staging.?.resource(), 0, 0, 0, buf.resource(), 0, &.{ .left = x, .top = y, .right = x + w, .bottom = y + h });
        var mapped: d3d.MappedSubresource = .{};
        if (!com.succeeded(api.ctx.map(staging.?.resource(), 0, .read, &mapped))) return false;
        defer api.ctx.unmap(staging.?.resource(), 0);
        const src: [*]const u8 = @ptrCast(mapped.pData.?);
        for (0..h) |row| {
            @memcpy(out[row * pitch ..][0 .. w * 4], src[row * mapped.RowPitch ..][0 .. w * 4]);
        }
        return true;
    }
};

fn srgbToLinear(v: f32) f32 {
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

/// The pane's swap chain (flip model, made for composition: premultiplied
/// alpha, latency 1) and the composition target and visual showing it on
/// the pane's window, under the window's children.
const Swap = struct {
    chain: *dxgi.SwapChain1,
    waitable: ?*anyopaque = null,
    comp: ?*dcomp.Device = null,
    target: ?*dcomp.Target = null,
    visual: ?*dcomp.Visual = null,
    width: u32,
    height: u32,
    /// Buffer 0 (the runtime turns it as frames present) and views of it:
    /// plain, and sRGB, which encodes on write.
    buffer: ?*d3d.Texture2D = null,
    rtv: ?*d3d.RenderTargetView = null,
    rtv_srgb: ?*d3d.RenderTargetView = null,

    const flags = dxgi.SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;

    fn create(gpu: *d3d.Device, ctx: *d3d.DeviceContext, hwnd: *anyopaque, width: u32, height: u32) !Swap {
        _ = ctx;
        const dxgi_device = com.query(gpu, dxgi.Device) orelse return error.D3D11Failed;
        defer com.release(dxgi_device);
        const adapter = dxgi_device.getAdapter() orelse return error.D3D11Failed;
        defer com.release(adapter);
        const factory = adapter.getParentFactory() orelse return error.D3D11Failed;
        defer com.release(factory);
        var chain: ?*dxgi.SwapChain1 = null;
        const hr = factory.createSwapChainForComposition(gpu, &.{
            .Width = width,
            .Height = height,
            .Format = .b8g8r8a8_unorm,
            .BufferCount = 2,
            .Scaling = .stretch,
            .SwapEffect = .flip_sequential,
            .AlphaMode = .premultiplied,
            .Flags = flags,
        }, &chain);
        if (!com.succeeded(hr)) {
            log.err("no swap chain hr=0x{x:0>8}", .{@as(u32, @bitCast(hr))});
            return error.D3D11Failed;
        }
        var self: Swap = .{ .chain = chain.?, .width = width, .height = height };
        errdefer self.release();
        if (com.query(self.chain, dxgi.SwapChain2)) |sc2| {
            defer com.release(sc2);
            _ = sc2.setMaximumFrameLatency(1);
            self.waitable = sc2.getFrameLatencyWaitableObject();
        }
        try self.compose(dxgi_device, hwnd);
        try self.makeViews(gpu);
        return self;
    }

    fn compose(self: *Swap, dxgi_device: *dxgi.Device, hwnd: *anyopaque) !void {
        const comp = dcomp.Device.create(dxgi_device) orelse return error.D3D11Failed;
        self.comp = comp;
        var target: ?*dcomp.Target = null;
        // Not topmost: above the window's own content, below its children.
        var hr = comp.createTargetForHwnd(hwnd, false, &target);
        if (!com.succeeded(hr)) {
            log.err("no composition target hr=0x{x:0>8}", .{@as(u32, @bitCast(hr))});
            return error.D3D11Failed;
        }
        self.target = target;
        var visual: ?*dcomp.Visual = null;
        if (!com.succeeded(comp.createVisual(&visual))) return error.D3D11Failed;
        self.visual = visual;
        if (!com.succeeded(visual.?.setContent(self.chain))) return error.D3D11Failed;
        if (!com.succeeded(target.?.setRoot(visual.?))) return error.D3D11Failed;
        hr = comp.commit();
        if (!com.succeeded(hr)) return error.D3D11Failed;
    }

    fn makeViews(self: *Swap, gpu: *d3d.Device) !void {
        const buf = self.chain.getBuffer(0, d3d.Texture2D) orelse return error.D3D11Failed;
        self.buffer = buf;
        var rtv: ?*d3d.RenderTargetView = null;
        if (!com.succeeded(gpu.createRenderTargetView(buf.resource(), null, &rtv))) return error.D3D11Failed;
        self.rtv = rtv;
        var srgb: ?*d3d.RenderTargetView = null;
        const desc: d3d.RenderTargetViewDesc = .{
            .Format = .b8g8r8a8_unorm_srgb,
            .ViewDimension = .texture2d,
            .u = .{ .Texture2D = .{ .MipSlice = 0 } },
        };
        if (!com.succeeded(gpu.createRenderTargetView(buf.resource(), &desc, &srgb))) return error.D3D11Failed;
        self.rtv_srgb = srgb;
    }

    fn releaseViews(self: *Swap) void {
        if (self.rtv_srgb) |v| com.release(v);
        if (self.rtv) |v| com.release(v);
        if (self.buffer) |b| com.release(b);
        self.rtv_srgb = null;
        self.rtv = null;
        self.buffer = null;
    }

    /// The window's new size: nothing may hold the buffers then.
    fn resize(self: *Swap, gpu: *d3d.Device, ctx: *d3d.DeviceContext, width: u32, height: u32) !void {
        ctx.omSetRenderTargets(&.{});
        self.releaseViews();
        ctx.flush();
        const hr = self.chain.resizeBuffers(0, width, height, .unknown, flags);
        if (dxgi.deviceLost(hr)) return error.DeviceLost;
        if (!com.succeeded(hr)) {
            log.warn("ResizeBuffers failed hr=0x{x:0>8}", .{@as(u32, @bitCast(hr))});
            return error.D3D11Failed;
        }
        self.width = width;
        self.height = height;
        try self.makeViews(gpu);
    }

    fn releaseComposition(self: *Swap) void {
        if (self.visual) |v| com.release(v);
        if (self.target) |t| com.release(t);
        if (self.comp) |c| {
            _ = c.commit();
            com.release(c);
        }
        self.visual = null;
        self.target = null;
        self.comp = null;
    }

    fn release(self: *Swap) void {
        self.releaseViews();
        self.releaseComposition();
        if (self.waitable) |h| _ = CloseHandle(h);
        self.waitable = null;
        com.release(self.chain);
    }
};

/// States every pass and the present use.
const Common = struct {
    /// No culling (the quads' winding is whatever the vertex order gives).
    raster: *d3d.RasterizerState,
    /// Linear and clamped: images, the custom shaders' input.
    linear: *d3d.SamplerState,
    /// The shapes' premultiplied blending.
    premultiplied: *d3d.BlendState,

    fn create(gpu: *d3d.Device) !Common {
        var raster: ?*d3d.RasterizerState = null;
        if (!com.succeeded(gpu.createRasterizerState(&.{ .CullMode = .none }, &raster))) return error.D3D11Failed;
        errdefer com.release(raster.?);
        var linear: ?*d3d.SamplerState = null;
        if (!com.succeeded(gpu.createSamplerState(&.{ .Filter = .min_mag_mip_linear }, &linear))) return error.D3D11Failed;
        errdefer com.release(linear.?);
        var blend: ?*d3d.BlendState = null;
        var desc: d3d.BlendDesc = .{};
        desc.RenderTarget[0] = .{
            .BlendEnable = com.TRUE,
            .SrcBlend = .one,
            .DestBlend = .inv_src_alpha,
            .SrcBlendAlpha = .one,
            .DestBlendAlpha = .inv_src_alpha,
        };
        if (!com.succeeded(gpu.createBlendState(&desc, &blend))) return error.D3D11Failed;
        return .{ .raster = raster.?, .linear = linear.?, .premultiplied = blend.? };
    }

    fn release(self: *Common) void {
        com.release(self.premultiplied);
        com.release(self.linear);
        com.release(self.raster);
    }
};

/// The present pass's programs and buffers.
const Presenter = struct {
    vs: *d3d.VertexShader,
    ps: *d3d.PixelShader,
    constants: *d3d.Buffer,
    shapes_vs: *d3d.VertexShader,
    shapes_ps: *d3d.PixelShader,
    shapes_layout: *d3d.InputLayout,
    shapes_constants: *d3d.Buffer,
    /// Room for every shape (Overlay.max instances).
    shapes: *d3d.Buffer,

    fn create(gpu: *d3d.Device, device: *Device) !Presenter {
        const present_code = try device.bytecode(.present);
        const shapes_code = try device.bytecode(.shapes);
        var self: Presenter = undefined;
        var vs: ?*d3d.VertexShader = null;
        if (!com.succeeded(gpu.createVertexShader(present_code.vs, &vs))) return error.D3D11Failed;
        errdefer com.release(vs.?);
        var ps: ?*d3d.PixelShader = null;
        if (!com.succeeded(gpu.createPixelShader(present_code.ps, &ps))) return error.D3D11Failed;
        errdefer com.release(ps.?);
        const constants = try dynamicBuffer(gpu, @sizeOf(PresentConstants), d3d.BIND_CONSTANT_BUFFER);
        errdefer com.release(constants);
        var svs: ?*d3d.VertexShader = null;
        if (!com.succeeded(gpu.createVertexShader(shapes_code.vs, &svs))) return error.D3D11Failed;
        errdefer com.release(svs.?);
        var sps: ?*d3d.PixelShader = null;
        if (!com.succeeded(gpu.createPixelShader(shapes_code.ps, &sps))) return error.D3D11Failed;
        errdefer com.release(sps.?);
        var layout: ?*d3d.InputLayout = null;
        const elements = [_]d3d.InputElementDesc{
            .{ .SemanticName = "ATTR", .SemanticIndex = 0, .Format = .r32g32b32a32_float, .AlignedByteOffset = 0, .InputSlotClass = .per_instance, .InstanceDataStepRate = 1 },
            .{ .SemanticName = "ATTR", .SemanticIndex = 1, .Format = .r32g32b32a32_float, .AlignedByteOffset = 16, .InputSlotClass = .per_instance, .InstanceDataStepRate = 1 },
        };
        if (!com.succeeded(gpu.createInputLayout(&elements, shapes_code.vs, &layout))) return error.D3D11Failed;
        errdefer com.release(layout.?);
        const shapes_constants = try dynamicBuffer(gpu, @sizeOf(ShapesConstants), d3d.BIND_CONSTANT_BUFFER);
        errdefer com.release(shapes_constants);
        const shapes = try dynamicBuffer(gpu, @sizeOf(ShapeInstance) * Overlay.max, d3d.BIND_VERTEX_BUFFER);
        self = .{
            .vs = vs.?,
            .ps = ps.?,
            .constants = constants,
            .shapes_vs = svs.?,
            .shapes_ps = sps.?,
            .shapes_layout = layout.?,
            .shapes_constants = shapes_constants,
            .shapes = shapes,
        };
        return self;
    }

    fn release(self: *Presenter) void {
        com.release(self.shapes);
        com.release(self.shapes_constants);
        com.release(self.shapes_layout);
        com.release(self.shapes_ps);
        com.release(self.shapes_vs);
        com.release(self.constants);
        com.release(self.ps);
        com.release(self.vs);
    }
};

fn dynamicBuffer(gpu: *d3d.Device, bytes: usize, bind: u32) !*d3d.Buffer {
    var buf: ?*d3d.Buffer = null;
    const desc: d3d.BufferDesc = .{
        .ByteWidth = std.mem.alignForward(u32, @intCast(bytes), 16),
        .Usage = .dynamic,
        .BindFlags = bind,
        .CPUAccessFlags = d3d.CPU_ACCESS_WRITE,
    };
    if (!com.succeeded(gpu.createBuffer(&desc, null, &buf))) return error.D3D11Failed;
    return buf.?;
}

fn bufferOptions(self: *const D3D11, kind: bufferpkg.Options.Kind) bufferpkg.Options {
    return .{ .gpu = self.gpu, .ctx = self.ctx, .kind = kind };
}

pub fn instanceBufferOptions(self: *const D3D11) bufferpkg.Options {
    return self.bufferOptions(.vertex);
}
pub fn uniformBufferOptions(self: *const D3D11) bufferpkg.Options {
    return self.bufferOptions(.constant);
}
pub fn fgBufferOptions(self: *const D3D11) bufferpkg.Options {
    return self.bufferOptions(.vertex);
}
pub fn bgBufferOptions(self: *const D3D11) bufferpkg.Options {
    return self.bufferOptions(.storage);
}
pub fn imageBufferOptions(self: *const D3D11) bufferpkg.Options {
    return self.bufferOptions(.vertex);
}
pub fn bgImageBufferOptions(self: *const D3D11) bufferpkg.Options {
    return self.bufferOptions(.vertex);
}

/// The custom shaders' textures: drawn into and sampled, sRGB.
pub fn textureOptions(self: *const D3D11) Texture.Options {
    return .{
        .gpu = self.gpu,
        .ctx = self.ctx,
        .format = .r8g8b8a8_unorm_srgb,
        .bytes_per_pixel = 4,
        .render_target = true,
    };
}

/// The custom shaders' sampler.
pub fn samplerOptions(self: *const D3D11) Sampler.Options {
    return .{ .gpu = self.gpu };
}

/// Pixel format for image texture options.
pub const ImageTextureFormat = enum {
    /// 1 byte per pixel grayscale.
    gray,
    /// 4 bytes per pixel RGBA.
    rgba,
    /// 4 bytes per pixel BGRA.
    bgra,
};

/// Images' textures (sampled linearly; the background image repeats in
/// its shader).
pub fn imageTextureOptions(
    self: *const D3D11,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    return .{
        .gpu = self.gpu,
        .ctx = self.ctx,
        .format = switch (format) {
            .gray => .r8_unorm,
            .rgba => if (srgb) .r8g8b8a8_unorm_srgb else .r8g8b8a8_unorm,
            .bgra => if (srgb) .b8g8r8a8_unorm_srgb else .b8g8r8a8_unorm,
        },
        .bytes_per_pixel = if (format == .gray) 1 else 4,
    };
}

/// A texture for a font atlas, loaded by pixel (nearest).
pub fn initAtlasTexture(
    self: *const D3D11,
    atlas: *const font.Atlas,
) Texture.Error!Texture {
    const format: dxgi.Format, const bpp: u32 = switch (atlas.format) {
        .grayscale => .{ .r8_unorm, 1 },
        .bgra => .{ .b8g8r8a8_unorm_srgb, 4 },
        else => @panic("unsupported atlas format for the Direct3D 11 renderer"),
    };
    return try Texture.init(.{
        .gpu = self.gpu,
        .ctx = self.ctx,
        .format = format,
        .bytes_per_pixel = bpp,
    }, atlas.size, atlas.size, null);
}

/// Begin a frame.
pub inline fn beginFrame(
    self: *const D3D11,
    renderer: *Renderer,
    target: *Target,
) !Frame {
    _ = self;
    return try Frame.begin(.{}, renderer, target);
}

test {
    _ = Pipeline;
    _ = shaders;
}

const RECT = extern struct { left: i32 = 0, top: i32 = 0, right: i32 = 0, bottom: i32 = 0 };
extern "user32" fn GetClientRect(hwnd: *anyopaque, rect: *RECT) callconv(.winapi) com.BOOL;
extern "kernel32" fn WaitForSingleObjectEx(handle: *anyopaque, ms: u32, alertable: com.BOOL) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(handle: *anyopaque) callconv(.winapi) com.BOOL;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
