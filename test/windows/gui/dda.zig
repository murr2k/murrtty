//! What the display shows, through DXGI desktop duplication: the frames
//! DWM sends to the monitor. Unlike a GDI capture (BitBlt, PrintWindow) it
//! includes content a driver presents outside a window's GDI surface (on
//! screen, NVIDIA presents OpenGL through a DXGI swap chain). The primary
//! adapter's first output only.
const std = @import("std");
const w = @import("win.zig");

const HRESULT = c_long;

const GUID = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };
const IID_IDXGIDevice: GUID = .{ .a = 0x54ec77fa, .b = 0x1377, .c = 0x44e6, .d = .{ 0x8c, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c } };
const IID_IDXGIOutput1: GUID = .{ .a = 0x00cddea8, .b = 0x939b, .c = 0x4b83, .d = .{ 0xa3, 0x40, 0xa6, 0x85, 0x22, 0x66, 0x66, 0xcc } };
const IID_ID3D11Texture2D: GUID = .{ .a = 0x6f15aaf2, .b = 0xd208, .c = 0x4e89, .d = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c } };

const D3D_DRIVER_TYPE_HARDWARE = 1;
const D3D11_CREATE_DEVICE_BGRA_SUPPORT = 0x20;
const D3D11_SDK_VERSION = 7;
const D3D11_USAGE_STAGING = 3;
const D3D11_CPU_ACCESS_READ = 0x20000;
const D3D11_MAP_READ = 1;
const DXGI_FORMAT_B8G8R8A8_UNORM = 87;
const DXGI_ERROR_WAIT_TIMEOUT: HRESULT = @bitCast(@as(u32, 0x887A0027));

const OUTPUT_DESC = extern struct {
    DeviceName: [32]u16,
    DesktopCoordinates: w.RECT,
    AttachedToDesktop: w.BOOL,
    Rotation: u32,
    Monitor: ?*anyopaque,
};

const FRAME_INFO = extern struct {
    LastPresentTime: i64,
    LastMouseUpdateTime: i64,
    AccumulatedFrames: u32,
    RectsCoalesced: w.BOOL,
    ProtectedContentMaskedOut: w.BOOL,
    PointerPosition: extern struct { Position: w.POINT, Visible: w.BOOL },
    TotalMetadataBufferSize: u32,
    PointerShapeBufferSize: u32,
};

const TEXTURE2D_DESC = extern struct {
    Width: u32,
    Height: u32,
    MipLevels: u32,
    ArraySize: u32,
    Format: u32,
    SampleDesc: extern struct { Count: u32, Quality: u32 },
    Usage: u32,
    BindFlags: u32,
    CPUAccessFlags: u32,
    MiscFlags: u32,
};

const MAPPED_SUBRESOURCE = extern struct { pData: ?*anyopaque, RowPitch: u32, DepthPitch: u32 };

extern "d3d11" fn D3D11CreateDevice(
    adapter: ?*anyopaque,
    driver_type: u32,
    software: ?*anyopaque,
    flags: u32,
    levels: ?[*]const u32,
    level_count: u32,
    sdk: u32,
    device: *?*anyopaque,
    level: ?*u32,
    context: *?*anyopaque,
) callconv(.winapi) HRESULT;

/// Slot `index` of a COM object's vtable, as a function of type `F`.
fn method(obj: *anyopaque, comptime index: usize, comptime F: type) F {
    const vtbl: *const [*]const *const anyopaque = @ptrCast(@alignCast(obj));
    return @ptrCast(vtbl.*[index]);
}

fn release(obj: ?*anyopaque) void {
    const o = obj orelse return;
    _ = method(o, 2, *const fn (*anyopaque) callconv(.winapi) u32)(o);
}

fn queryInterface(obj: *anyopaque, iid: *const GUID) ?*anyopaque {
    var out: ?*anyopaque = null;
    const hr = method(obj, 0, *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT)(obj, iid, &out);
    return if (hr < 0) null else out;
}

fn check(hr: HRESULT, comptime what: []const u8) !void {
    if (hr >= 0) return;
    std.debug.print("    desktop duplication: {s} failed (hr 0x{x:0>8})\n", .{ what, @as(u32, @bitCast(hr)) });
    return error.CaptureFailed;
}

/// The display's pixels in `rect` (screen pixels), 0xAARRGGBB top-down, in
/// `out` (rect's width times height). `poke` runs while waiting for a
/// frame: duplication delivers one only when DWM presents, which a still
/// screen never does.
pub fn capture(rect: w.RECT, out: []u32, ctx: anytype, comptime poke: fn (@TypeOf(ctx)) void) !void {
    var device: ?*anyopaque = null;
    var context: ?*anyopaque = null;
    try check(D3D11CreateDevice(null, D3D_DRIVER_TYPE_HARDWARE, null, D3D11_CREATE_DEVICE_BGRA_SUPPORT, null, 0, D3D11_SDK_VERSION, &device, null, &context), "D3D11CreateDevice");
    defer release(device);
    defer release(context);

    const dxgi_device = queryInterface(device.?, &IID_IDXGIDevice) orelse return error.CaptureFailed;
    defer release(dxgi_device);
    var adapter: ?*anyopaque = null;
    try check(method(dxgi_device, 7, *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT)(dxgi_device, &adapter), "GetAdapter");
    defer release(adapter);
    var output: ?*anyopaque = null;
    try check(method(adapter.?, 7, *const fn (*anyopaque, u32, *?*anyopaque) callconv(.winapi) HRESULT)(adapter.?, 0, &output), "EnumOutputs");
    defer release(output);
    var desc: OUTPUT_DESC = undefined;
    try check(method(output.?, 7, *const fn (*anyopaque, *OUTPUT_DESC) callconv(.winapi) HRESULT)(output.?, &desc), "GetDesc");
    const output1 = queryInterface(output.?, &IID_IDXGIOutput1) orelse return error.CaptureFailed;
    defer release(output1);
    var dup: ?*anyopaque = null;
    try check(method(output1, 22, *const fn (*anyopaque, *anyopaque, *?*anyopaque) callconv(.winapi) HRESULT)(output1, device.?, &dup), "DuplicateOutput");
    defer release(dup);

    const acquire = method(dup.?, 8, *const fn (*anyopaque, u32, *FRAME_INFO, *?*anyopaque) callconv(.winapi) HRESULT);
    const release_frame = method(dup.?, 14, *const fn (*anyopaque) callconv(.winapi) HRESULT);
    var resource: ?*anyopaque = null;
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        if (tries >= 100) {
            std.debug.print("    desktop duplication: no frame in 10 s\n", .{});
            // DWM presents nothing: no monitor is on (off, or showing
            // another input), whatever Windows' own power settings say.
            return error.NoDisplayFrames;
        }
        var info: FRAME_INFO = undefined;
        const hr = acquire(dup.?, 100, &info, &resource);
        if (hr == DXGI_ERROR_WAIT_TIMEOUT) {
            poke(ctx);
            continue;
        }
        try check(hr, "AcquireNextFrame");
        // A frame with only a pointer update carries no desktop image.
        if (info.LastPresentTime != 0) break;
        release(resource);
        resource = null;
        _ = release_frame(dup.?);
        poke(ctx);
    }
    defer _ = release_frame(dup.?);
    defer release(resource);

    const texture = queryInterface(resource.?, &IID_ID3D11Texture2D) orelse return error.CaptureFailed;
    defer release(texture);
    var tdesc: TEXTURE2D_DESC = undefined;
    method(texture, 10, *const fn (*anyopaque, *TEXTURE2D_DESC) callconv(.winapi) void)(texture, &tdesc);
    if (tdesc.Format != DXGI_FORMAT_B8G8R8A8_UNORM) {
        std.debug.print("    desktop duplication: format {d}, not BGRA\n", .{tdesc.Format});
        return error.CaptureFailed;
    }
    var sdesc = tdesc;
    sdesc.MipLevels = 1;
    sdesc.ArraySize = 1;
    sdesc.SampleDesc = .{ .Count = 1, .Quality = 0 };
    sdesc.Usage = D3D11_USAGE_STAGING;
    sdesc.BindFlags = 0;
    sdesc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    sdesc.MiscFlags = 0;
    var staging: ?*anyopaque = null;
    try check(method(device.?, 5, *const fn (*anyopaque, *const TEXTURE2D_DESC, ?*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT)(device.?, &sdesc, null, &staging), "CreateTexture2D");
    defer release(staging);
    method(context.?, 47, *const fn (*anyopaque, *anyopaque, *anyopaque) callconv(.winapi) void)(context.?, staging.?, texture);
    var mapped: MAPPED_SUBRESOURCE = undefined;
    try check(method(context.?, 14, *const fn (*anyopaque, *anyopaque, u32, u32, u32, *MAPPED_SUBRESOURCE) callconv(.winapi) HRESULT)(context.?, staging.?, 0, D3D11_MAP_READ, 0, &mapped), "Map");
    defer method(context.?, 15, *const fn (*anyopaque, *anyopaque, u32) callconv(.winapi) void)(context.?, staging.?, 0);

    // The area in the output's own pixels.
    const width: usize = @intCast(rect.right - rect.left);
    const height: usize = @intCast(rect.bottom - rect.top);
    const x0 = rect.left - desc.DesktopCoordinates.left;
    const y0 = rect.top - desc.DesktopCoordinates.top;
    if (x0 < 0 or y0 < 0 or x0 + @as(c_int, @intCast(width)) > @as(c_int, @intCast(tdesc.Width)) or
        y0 + @as(c_int, @intCast(height)) > @as(c_int, @intCast(tdesc.Height)))
    {
        std.debug.print("    desktop duplication: the area isn't all on the first output\n", .{});
        return error.CaptureFailed;
    }
    const base: [*]const u8 = @ptrCast(mapped.pData orelse return error.CaptureFailed);
    for (0..height) |y| {
        const row: [*]align(1) const u32 = @ptrCast(base + (@as(usize, @intCast(y0)) + y) * mapped.RowPitch + @as(usize, @intCast(x0)) * 4);
        for (0..width) |x| out[y * width + x] = row[x];
    }
}
