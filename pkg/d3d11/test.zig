//! Calls every bound method once, on a WARP device (no GPU needed), so a
//! wrong vtable index fails here rather than in the renderer.
const std = @import("std");
const com = @import("com.zig");
const dxgi = @import("dxgi.zig");
const d3d = @import("d3d.zig");
const dcomp = @import("dcomp.zig");
const compiler = @import("compiler.zig");

const t = std.testing;

extern "user32" fn CreateWindowExW(ex: u32, class: [*:0]const u16, title: [*:0]const u16, style: u32, x: i32, y: i32, w: i32, h: i32, parent: ?*anyopaque, menu: ?*anyopaque, instance: ?*anyopaque, param: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "user32" fn DestroyWindow(hwnd: *anyopaque) callconv(.winapi) com.BOOL;
extern "kernel32" fn WaitForSingleObject(h: *anyopaque, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(h: *anyopaque) callconv(.winapi) com.BOOL;
const WS_POPUP: u32 = 0x80000000;

const shader_src =
    \\cbuffer Globals : register(b1) { float4 color; };
    \\StructuredBuffer<uint> cells : register(t2);
    \\Texture2D atlas : register(t0);
    \\SamplerState linear_clamp : register(s0);
    \\struct VsIn { uint id : SV_VertexID; float2 offset : OFFSET; };
    \\struct VsOut { float4 pos : SV_Position; nointerpolation uint cell : CELL; };
    \\VsOut vs_main(VsIn i) {
    \\    VsOut o;
    \\    float2 uv = float2((i.id << 1) & 2, i.id & 2);
    \\    o.pos = float4(uv * float2(2, -2) + float2(-1, 1) + i.offset, 0, 1);
    \\    o.cell = cells[0];
    \\    return o;
    \\}
    \\float4 ps_main(VsOut i) : SV_Target {
    \\    float4 a = atlas.SampleLevel(linear_clamp, float2(0.5, 0.5), 0);
    \\    return color * (i.cell == 7u ? 1.0 : 0.0) + a * 0.0;
    \\}
;

fn ok(hr: com.HRESULT) !void {
    if (!com.succeeded(hr)) {
        std.debug.print("HRESULT 0x{x:0>8}\n", .{@as(u32, @bitCast(hr))});
        return error.TestUnexpectedResult;
    }
}

test "every bound method, on WARP" {
    const alloc = t.allocator;
    var device_opt: ?*d3d.Device = null;
    var level: d3d.FeatureLevel = undefined;
    const levels = [_]d3d.FeatureLevel{.@"11_0"};
    try ok(d3d.D3D11CreateDevice(null, .warp, null, d3d.CREATE_DEVICE_BGRA_SUPPORT, &levels, levels.len, d3d.SDK_VERSION, &device_opt, &level, null));
    const device = device_opt.?;
    defer com.release(device);
    try t.expectEqual(d3d.FeatureLevel.@"11_0", device.getFeatureLevel());
    try t.expectEqual(d3d.FeatureLevel.@"11_0", level);
    const ctx = device.getImmediateContext();
    defer com.release(ctx);
    try t.expectEqual(@as(com.HRESULT, 0), device.getDeviceRemovedReason());

    // DXGI: the adapter (WARP is a software one), its factory.
    const dxgi_device = com.query(device, dxgi.Device) orelse return error.NoDxgiDevice;
    defer com.release(dxgi_device);
    const adapter = dxgi_device.getAdapter() orelse return error.NoAdapter;
    defer com.release(adapter);
    var adesc: dxgi.AdapterDesc1 = undefined;
    try ok(adapter.getDesc1(&adesc));
    try t.expect(adesc.Flags & dxgi.ADAPTER_FLAG_SOFTWARE != 0);
    const factory = adapter.getParentFactory() orelse return error.NoFactory;
    defer com.release(factory);
    try t.expect(factory.isCurrent());
    const fresh = dxgi.createFactory() orelse return error.NoFactory;
    defer com.release(fresh);
    if (fresh.enumAdapters1(0)) |first| com.release(first);

    // Shaders, layout, states.
    var messages: std.ArrayList(u8) = .empty;
    defer messages.deinit(alloc);
    const vs_code = compiler.compile(shader_src, "test", "vs_main", "vs_5_0", 0, &messages, alloc) catch |err| {
        std.debug.print("{s}\n", .{messages.items});
        return err;
    };
    defer vs_code.deinit();
    const ps_code = try compiler.compile(shader_src, "test", "ps_main", "ps_5_0", 0, &messages, alloc);
    defer ps_code.deinit();
    var vs: ?*d3d.VertexShader = null;
    try ok(device.createVertexShader(vs_code.bytes(), &vs));
    defer com.release(vs.?);
    var ps: ?*d3d.PixelShader = null;
    try ok(device.createPixelShader(ps_code.bytes(), &ps));
    defer com.release(ps.?);
    var layout: ?*d3d.InputLayout = null;
    const elements = [_]d3d.InputElementDesc{.{
        .SemanticName = "OFFSET",
        .Format = .r32g32_float,
        .AlignedByteOffset = 0,
        .InputSlotClass = .per_instance,
        .InstanceDataStepRate = 1,
    }};
    try ok(device.createInputLayout(&elements, vs_code.bytes(), &layout));
    defer com.release(layout.?);
    var blend: ?*d3d.BlendState = null;
    var bdesc: d3d.BlendDesc = .{};
    bdesc.RenderTarget[0] = .{ .BlendEnable = com.TRUE, .SrcBlend = .one, .DestBlend = .inv_src_alpha, .SrcBlendAlpha = .one, .DestBlendAlpha = .inv_src_alpha };
    try ok(device.createBlendState(&bdesc, &blend));
    defer com.release(blend.?);
    var raster: ?*d3d.RasterizerState = null;
    try ok(device.createRasterizerState(&.{ .ScissorEnable = com.TRUE }, &raster));
    defer com.release(raster.?);
    var sampler: ?*d3d.SamplerState = null;
    try ok(device.createSamplerState(&.{ .Filter = .min_mag_mip_linear }, &sampler));
    defer com.release(sampler.?);

    // Buffers: constants (dynamic, mapped), an instance buffer, a
    // structured buffer and its view.
    var cbuf: ?*d3d.Buffer = null;
    try ok(device.createBuffer(&.{ .ByteWidth = 16, .Usage = .dynamic, .BindFlags = d3d.BIND_CONSTANT_BUFFER, .CPUAccessFlags = d3d.CPU_ACCESS_WRITE }, null, &cbuf));
    defer com.release(cbuf.?);
    {
        var mapped: d3d.MappedSubresource = .{};
        try ok(ctx.map(cbuf.?.resource(), 0, .write_discard, &mapped));
        const color: *[4]f32 = @ptrCast(@alignCast(mapped.pData.?));
        color.* = .{ 0.25, 0.5, 0.75, 1.0 };
        ctx.unmap(cbuf.?.resource(), 0);
    }
    const offsets_data = [_][2]f32{.{ 0, 0 }};
    var vbuf: ?*d3d.Buffer = null;
    try ok(device.createBuffer(&.{ .ByteWidth = @sizeOf(@TypeOf(offsets_data)), .BindFlags = d3d.BIND_VERTEX_BUFFER }, &.{ .pSysMem = &offsets_data }, &vbuf));
    defer com.release(vbuf.?);
    const cells_data = [_]u32{ 7, 0, 0, 0 };
    var sbuf: ?*d3d.Buffer = null;
    try ok(device.createBuffer(&.{ .ByteWidth = @sizeOf(@TypeOf(cells_data)), .BindFlags = d3d.BIND_SHADER_RESOURCE, .MiscFlags = d3d.RESOURCE_MISC_BUFFER_STRUCTURED, .StructureByteStride = 4 }, &.{ .pSysMem = &cells_data }, &sbuf));
    defer com.release(sbuf.?);
    var sview: ?*d3d.ShaderResourceView = null;
    try ok(device.createShaderResourceView(sbuf.?.resource(), &.{ .Format = .unknown, .ViewDimension = .buffer, .u = .{ .Buffer = .{ .FirstElement = 0, .NumElements = cells_data.len } } }, &sview));
    defer com.release(sview.?);

    // A texture to sample (updated in place), and the target with an sRGB
    // view (as the renderer's composite) and a plain one.
    var atlas: ?*d3d.Texture2D = null;
    try ok(device.createTexture2D(&.{ .Width = 4, .Height = 4, .Format = .r8_unorm, .BindFlags = d3d.BIND_SHADER_RESOURCE }, null, &atlas));
    defer com.release(atlas.?);
    const texels: [16]u8 = @splat(0xff);
    ctx.updateSubresource(atlas.?.resource(), 0, &.{ .left = 0, .top = 0, .right = 4, .bottom = 4 }, &texels, 4, 0);
    var atlas_view: ?*d3d.ShaderResourceView = null;
    try ok(device.createShaderResourceView(atlas.?.resource(), null, &atlas_view));
    defer com.release(atlas_view.?);

    // Typeless: a texture takes views of another format only then (DXGI
    // allows it for swap chain buffers alone, below).
    var target: ?*d3d.Texture2D = null;
    try ok(device.createTexture2D(&.{ .Width = 8, .Height = 8, .Format = .b8g8r8a8_typeless, .BindFlags = d3d.BIND_RENDER_TARGET | d3d.BIND_SHADER_RESOURCE }, null, &target));
    defer com.release(target.?);
    var tdesc: d3d.Texture2DDesc = undefined;
    target.?.getDesc(&tdesc);
    try t.expectEqual(@as(u32, 8), tdesc.Width);
    var rtv: ?*d3d.RenderTargetView = null;
    try ok(device.createRenderTargetView(target.?.resource(), &.{ .Format = .b8g8r8a8_unorm, .ViewDimension = .texture2d, .u = .{ .Texture2D = .{ .MipSlice = 0 } } }, &rtv));
    defer com.release(rtv.?);
    var rtv_srgb: ?*d3d.RenderTargetView = null;
    try ok(device.createRenderTargetView(target.?.resource(), &.{ .Format = .b8g8r8a8_unorm_srgb, .ViewDimension = .texture2d, .u = .{ .Texture2D = .{ .MipSlice = 0 } } }, &rtv_srgb));
    defer com.release(rtv_srgb.?);

    // Draw: clear, then the triangle (instanced) over all of it.
    ctx.clearRenderTargetView(rtv_srgb.?, &.{ 0, 0, 0, 1 });
    ctx.clearRenderTargetView(rtv.?, &.{ 0, 0, 0, 1 });
    ctx.omSetRenderTargets(&.{rtv.?});
    ctx.omSetBlendState(null);
    ctx.omSetBlendState(blend.?);
    ctx.omSetBlendState(null);
    ctx.rsSetState(raster.?);
    ctx.rsSetViewports(&.{.{ .Width = 8, .Height = 8 }});
    ctx.rsSetScissorRects(&.{.{ .left = 0, .top = 0, .right = 8, .bottom = 8 }});
    ctx.iaSetInputLayout(layout.?);
    ctx.iaSetVertexBuffers(0, &.{vbuf.?}, &.{8}, &.{0});
    ctx.iaSetPrimitiveTopology(.triangle_list);
    ctx.vsSetShader(vs.?);
    ctx.psSetShader(ps.?);
    ctx.vsSetConstantBuffers(1, &.{cbuf.?});
    ctx.psSetConstantBuffers(1, &.{cbuf.?});
    ctx.vsSetShaderResources(2, &.{sview.?});
    ctx.psSetShaderResources(0, &.{atlas_view.?});
    ctx.vsSetSamplers(0, &.{sampler.?});
    ctx.psSetSamplers(0, &.{sampler.?});
    ctx.drawInstanced(3, 1, 0, 0);
    ctx.draw(0, 0);

    // Read a pixel back through a staging copy (as the test hooks do).
    var staging: ?*d3d.Texture2D = null;
    try ok(device.createTexture2D(&.{ .Width = 8, .Height = 8, .Format = .b8g8r8a8_unorm, .Usage = .staging, .BindFlags = 0, .CPUAccessFlags = d3d.CPU_ACCESS_READ }, null, &staging));
    defer com.release(staging.?);
    ctx.copyResource(staging.?.resource(), target.?.resource());
    ctx.copySubresourceRegion(staging.?.resource(), 0, 0, 0, target.?.resource(), 0, &.{ .left = 0, .top = 0, .right = 1, .bottom = 1 });
    {
        var mapped: d3d.MappedSubresource = .{};
        try ok(ctx.map(staging.?.resource(), 0, .read, &mapped));
        defer ctx.unmap(staging.?.resource(), 0);
        const px: [*]const u8 = @ptrCast(mapped.pData.?);
        // B, G, R, A of (0.25, 0.5, 0.75, 1) in a UNORM target.
        try t.expectEqualSlices(u8, &.{ 191, 128, 64, 255 }, px[0..4]);
    }
    ctx.clearState();
    ctx.flush();

    // A composition swap chain with its latency wait, and its visual.
    var sc_opt: ?*dxgi.SwapChain1 = null;
    try ok(factory.createSwapChainForComposition(device, &.{
        .Width = 64,
        .Height = 32,
        .Format = .b8g8r8a8_unorm,
        .BufferCount = 2,
        .Scaling = .stretch,
        .SwapEffect = .flip_sequential,
        .AlphaMode = .premultiplied,
        .Flags = dxgi.SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT,
    }, &sc_opt));
    const sc = sc_opt.?;
    defer com.release(sc);
    const sc2 = com.query(sc, dxgi.SwapChain2) orelse return error.NoSwapChain2;
    defer com.release(sc2);
    try ok(sc2.setMaximumFrameLatency(1));
    const waitable = sc2.getFrameLatencyWaitableObject() orelse return error.NoWaitable;
    defer _ = CloseHandle(waitable);
    try t.expectEqual(@as(u32, 0), WaitForSingleObject(waitable, 1000));
    {
        const buf = sc.getBuffer(0, d3d.Texture2D) orelse return error.NoBuffer;
        defer com.release(buf);
        var view: ?*d3d.RenderTargetView = null;
        try ok(device.createRenderTargetView(buf.resource(), null, &view));
        ctx.clearRenderTargetView(view.?, &.{ 0, 0, 0, 0 });
        com.release(view.?);
        // The sRGB view on the UNORM buffer the composite draws through.
        var srgb: ?*d3d.RenderTargetView = null;
        try ok(device.createRenderTargetView(buf.resource(), &.{ .Format = .b8g8r8a8_unorm_srgb, .ViewDimension = .texture2d, .u = .{ .Texture2D = .{ .MipSlice = 0 } } }, &srgb));
        com.release(srgb.?);
    }
    try ok(sc.present(0, 0));
    try ok(sc.resizeBuffers(0, 32, 16, .unknown, dxgi.SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT));
    var scdesc: dxgi.SwapChainDesc1 = undefined;
    try ok(sc.getDesc1(&scdesc));
    try t.expectEqual(@as(u32, 32), scdesc.Width);

    const hwnd = CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral("d3d11 test"), WS_POPUP, 0, 0, 64, 32, null, null, null, null) orelse return error.NoWindow;
    defer _ = DestroyWindow(hwnd);
    const comp = dcomp.Device.create(dxgi_device) orelse return error.NoCompositionDevice;
    defer com.release(comp);
    var ctarget: ?*dcomp.Target = null;
    try ok(comp.createTargetForHwnd(hwnd, false, &ctarget));
    defer com.release(ctarget.?);
    var visual: ?*dcomp.Visual = null;
    try ok(comp.createVisual(&visual));
    defer com.release(visual.?);
    try ok(visual.?.setOffsetX(0));
    try ok(visual.?.setOffsetY(0));
    try ok(visual.?.setContent(sc));
    try ok(ctarget.?.setRoot(visual.?));
    try ok(comp.commit());
    try t.expect(comp.checkDeviceState());

    // A window's own (flip-model, opaque) swap chain.
    const hwnd2 = CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral("d3d11 test"), WS_POPUP, 0, 0, 64, 32, null, null, null, null) orelse return error.NoWindow;
    defer _ = DestroyWindow(hwnd2);
    var hsc: ?*dxgi.SwapChain1 = null;
    try ok(factory.createSwapChainForHwnd(device, hwnd2, &.{
        .Width = 64,
        .Height = 32,
        .Format = .b8g8r8a8_unorm,
        .BufferCount = 2,
        .Scaling = .none,
        .SwapEffect = .flip_discard,
        .AlphaMode = .ignore,
    }, &hsc));
    defer com.release(hsc.?);
    try ok(hsc.?.present(0, 0));
}
