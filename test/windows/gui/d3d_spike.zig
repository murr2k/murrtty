//! Spike S7 (roadmap 7.8): how a Direct3D 11 swap chain presents for a
//! terminal pane. A top-level window with a GDI-painted background holds a
//! child "pane" window, which holds a layered child "overlay" (as
//! murrtty's search box and banners are). Run by the `d3d-spike` scenario
//! on the hidden desktop and on the user's desktop off-screen.
//!
//!   ghostty-gui-d3d.exe present <comp|hwnd|blt> <hw|warp> [capture]
//!   ghostty-gui-d3d.exe commit <hw|warp> <panes>
//!   ghostty-gui-d3d.exe dll
//!
//! Prints `key value` lines.
const std = @import("std");
const d3d11 = @import("d3d11");
const com = d3d11.com;
const dxgi = d3d11.dxgi;
const d3d = d3d11.d3d;
const dcomp = d3d11.dcomp;
const compiler = d3d11.compiler;

const HWND = *anyopaque;
const BOOL = i32;
const RECT = extern struct { left: i32 = 0, top: i32 = 0, right: i32 = 0, bottom: i32 = 0 };
const POINT = extern struct { x: i32 = 0, y: i32 = 0 };
const MSG = extern struct { hwnd: ?HWND, message: u32, wParam: usize, lParam: isize, time: u32, pt: POINT, private: u32 };
const WNDPROC = *const fn (HWND, u32, usize, isize) callconv(.winapi) isize;
const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?*anyopaque = null,
    hIcon: ?*anyopaque = null,
    hCursor: ?*anyopaque = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?*anyopaque = null,
};
const PAINTSTRUCT = extern struct { hdc: ?*anyopaque, fErase: BOOL, rcPaint: RECT, fRestore: BOOL, fIncUpdate: BOOL, rgbReserved: [32]u8 };
const BITMAPINFOHEADER = extern struct {
    biSize: u32 = @sizeOf(BITMAPINFOHEADER),
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16 = 1,
    biBitCount: u16 = 32,
    biCompression: u32 = 0,
    biSizeImage: u32 = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: u32 = 0,
    biClrImportant: u32 = 0,
};
const DWM_BLURBEHIND = extern struct { dwFlags: u32, fEnable: BOOL, hRgnBlur: ?*anyopaque, fTransitionOnMaximized: BOOL };
const PROCESS_MEMORY_COUNTERS_EX = extern struct {
    cb: u32 = @sizeOf(PROCESS_MEMORY_COUNTERS_EX),
    PageFaultCount: u32 = 0,
    PeakWorkingSetSize: usize = 0,
    WorkingSetSize: usize = 0,
    QuotaPeakPagedPoolUsage: usize = 0,
    QuotaPagedPoolUsage: usize = 0,
    QuotaPeakNonPagedPoolUsage: usize = 0,
    QuotaNonPagedPoolUsage: usize = 0,
    PagefileUsage: usize = 0,
    PeakPagefileUsage: usize = 0,
    PrivateUsage: usize = 0,
};

extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(u32, [*:0]const u16, [*:0]const u16, u32, i32, i32, i32, i32, ?HWND, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.winapi) ?HWND;
extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
extern "user32" fn DefWindowProcW(HWND, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn PeekMessageW(*MSG, ?HWND, u32, u32, u32) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) isize;
extern "user32" fn BeginPaint(HWND, *PAINTSTRUCT) callconv(.winapi) ?*anyopaque;
extern "user32" fn EndPaint(HWND, *const PAINTSTRUCT) callconv(.winapi) BOOL;
extern "user32" fn FillRect(*anyopaque, *const RECT, *anyopaque) callconv(.winapi) i32;
extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) BOOL;
extern "user32" fn GetWindowRect(HWND, *RECT) callconv(.winapi) BOOL;
extern "user32" fn MoveWindow(HWND, i32, i32, i32, i32, BOOL) callconv(.winapi) BOOL;
extern "user32" fn SetLayeredWindowAttributes(HWND, u32, u8, u32) callconv(.winapi) BOOL;
extern "user32" fn PrintWindow(HWND, *anyopaque, u32) callconv(.winapi) BOOL;
extern "user32" fn GetDC(?HWND) callconv(.winapi) ?*anyopaque;
extern "user32" fn ReleaseDC(?HWND, *anyopaque) callconv(.winapi) i32;
extern "user32" fn SetProcessDPIAware() callconv(.winapi) BOOL;
extern "user32" fn GetThreadDesktop(u32) callconv(.winapi) ?*anyopaque;
extern "user32" fn GetUserObjectInformationW(*anyopaque, i32, ?*anyopaque, u32, ?*u32) callconv(.winapi) BOOL;
extern "gdi32" fn CreateSolidBrush(u32) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn CreateCompatibleDC(?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn CreateDIBSection(*anyopaque, *const BITMAPINFOHEADER, u32, *?*anyopaque, ?*anyopaque, u32) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn SelectObject(*anyopaque, *anyopaque) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn DeleteObject(*anyopaque) callconv(.winapi) BOOL;
extern "gdi32" fn DeleteDC(*anyopaque) callconv(.winapi) BOOL;
extern "gdi32" fn CreateRectRgn(i32, i32, i32, i32) callconv(.winapi) ?*anyopaque;
extern "dwmapi" fn DwmEnableBlurBehindWindow(HWND, *const DWM_BLURBEHIND) callconv(.winapi) com.HRESULT;
extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) *anyopaque;
extern "kernel32" fn K32GetProcessMemoryInfo(*anyopaque, *PROCESS_MEMORY_COUNTERS_EX, u32) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObjectEx(*anyopaque, u32, BOOL) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn QueryPerformanceCounter(*i64) callconv(.winapi) BOOL;
extern "kernel32" fn QueryPerformanceFrequency(*i64) callconv(.winapi) BOOL;
extern "kernel32" fn GetSystemDirectoryW([*]u16, u32) callconv(.winapi) u32;
extern "kernel32" fn Sleep(u32) callconv(.winapi) void;

const WS_OVERLAPPEDWINDOW: u32 = 0x00CF0000;
const WS_VISIBLE: u32 = 0x10000000;
const WS_CHILD: u32 = 0x40000000;
const WS_CLIPCHILDREN: u32 = 0x02000000;
const WS_EX_LAYERED: u32 = 0x00080000;
const WS_EX_NOREDIRECTIONBITMAP: u32 = 0x00200000;
const LWA_ALPHA: u32 = 2;
const WM_PAINT: u32 = 0x000F;
const WM_ERASEBKGND: u32 = 0x0014;
const PM_REMOVE: u32 = 1;
const PW_RENDERFULLCONTENT: u32 = 2;
const DWM_BB_ENABLE: u32 = 1;
const DWM_BB_BLURREGION: u32 = 2;

const L = std.unicode.utf8ToUtf16LeStringLiteral;

// GDI colors are 0x00BBGGRR.
const green_gdi: u32 = 0x00004000;
const magenta_gdi: u32 = 0x00ff00ff;

extern "kernel32" fn GetStdHandle(u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn WriteFile(*anyopaque, [*]const u8, u32, ?*u32, ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]const u16;
extern "shell32" fn CommandLineToArgvW([*:0]const u16, *i32) callconv(.winapi) ?[*][*:0]const u16;
extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?*anyopaque) callconv(.winapi) *anyopaque;
extern "kernel32" fn ReadFile(*anyopaque, [*]u8, u32, ?*u32, ?*anyopaque) callconv(.winapi) BOOL;
const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));
const GENERIC_READ: u32 = 0x80000000;
const FILE_SHARE_READ: u32 = 1;
const OPEN_EXISTING: u32 = 3;
const INVALID_HANDLE: usize = std.math.maxInt(usize);

/// One line to stdout at once (the harness reads it through a pipe).
fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    const stdout = GetStdHandle(STD_OUTPUT_HANDLE) orelse return;
    _ = WriteFile(stdout, line.ptr, @intCast(line.len), null, null);
}

fn topProc(hwnd: HWND, msg: u32, wp: usize, lp: isize) callconv(.winapi) isize {
    return paintSolid(hwnd, msg, wp, lp, green_gdi);
}

fn overlayProc(hwnd: HWND, msg: u32, wp: usize, lp: isize) callconv(.winapi) isize {
    return paintSolid(hwnd, msg, wp, lp, magenta_gdi);
}

fn paintSolid(hwnd: HWND, msg: u32, wp: usize, lp: isize, color: u32) isize {
    if (msg == WM_ERASEBKGND) return 1;
    if (msg == WM_PAINT) {
        var ps: PAINTSTRUCT = undefined;
        const dc = BeginPaint(hwnd, &ps) orelse return 0;
        var r: RECT = .{};
        _ = GetClientRect(hwnd, &r);
        if (CreateSolidBrush(color)) |brush| {
            _ = FillRect(dc, &r, brush);
            _ = DeleteObject(brush);
        }
        _ = EndPaint(hwnd, &ps);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

/// The pane draws nothing with GDI: what shows is Direct3D's.
fn paneProc(hwnd: HWND, msg: u32, wp: usize, lp: isize) callconv(.winapi) isize {
    if (msg == WM_ERASEBKGND) return 1;
    if (msg == WM_PAINT) {
        var ps: PAINTSTRUCT = undefined;
        _ = BeginPaint(hwnd, &ps);
        _ = EndPaint(hwnd, &ps);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

extern "kernel32" fn GetLastError() callconv(.winapi) u32;

fn windowFailed() error{Window} {
    say("window_failed {d}", .{GetLastError()});
    return error.Window;
}

fn pump() void {
    var msg: MSG = undefined;
    while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0) {
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }
}

fn registerClasses() void {
    const inst = GetModuleHandleW(null);
    _ = RegisterClassExW(&.{ .lpfnWndProc = &topProc, .hInstance = inst, .lpszClassName = L("D3DSpikeTop") });
    _ = RegisterClassExW(&.{ .lpfnWndProc = &paneProc, .hInstance = inst, .lpszClassName = L("D3DSpikePane") });
    _ = RegisterClassExW(&.{ .lpfnWndProc = &overlayProc, .hInstance = inst, .lpszClassName = L("D3DSpikeOverlay") });
}

const Mode = enum { comp, hwnd, blt };
const Driver = enum { hw, warp };

const pane_x = 10;
const pane_y = 40;
const pane_w = 400;
const pane_h = 300;
const bg = [4]f32{ 0x28.0 / 255.0, 0x2c.0 / 255.0, 0x34.0 / 255.0, 1.0 };

const shader_src =
    \\cbuffer Globals : register(b1) { float4 color; };
    \\float4 vs_main(uint id : SV_VertexID) : SV_Position {
    \\    float2 uv = float2((id << 1) & 2, id & 2);
    \\    return float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    \\}
    \\float4 ps_main() : SV_Target { return color; }
;

const Gpu = struct {
    device: *d3d.Device,
    ctx: *d3d.DeviceContext,
    dxgi_device: *dxgi.Device,
    factory: *dxgi.Factory2,
    vs: *d3d.VertexShader,
    ps: *d3d.PixelShader,
    cbuf: *d3d.Buffer,

    fn init(alloc: std.mem.Allocator, driver: Driver) !Gpu {
        var device: ?*d3d.Device = null;
        var level: d3d.FeatureLevel = undefined;
        const levels = [_]d3d.FeatureLevel{.@"11_0"};
        const hr = d3d.D3D11CreateDevice(null, if (driver == .hw) .hardware else .warp, null, d3d.CREATE_DEVICE_BGRA_SUPPORT, &levels, levels.len, d3d.SDK_VERSION, &device, &level, null);
        if (!com.succeeded(hr)) {
            say("device_failed 0x{x:0>8}", .{@as(u32, @bitCast(hr))});
            return error.NoDevice;
        }
        const dev = device.?;
        const dxgi_device = com.query(dev, dxgi.Device) orelse return error.NoDxgi;
        const adapter = dxgi_device.getAdapter() orelse return error.NoDxgi;
        defer com.release(adapter);
        var desc: dxgi.AdapterDesc1 = undefined;
        _ = adapter.getDesc1(&desc);
        var name_buf: [256]u8 = undefined;
        const name_len = std.unicode.utf16LeToUtf8(&name_buf, std.mem.sliceTo(&desc.Description, 0)) catch 0;
        say("adapter {s}", .{name_buf[0..name_len]});
        say("software {}", .{desc.Flags & dxgi.ADAPTER_FLAG_SOFTWARE != 0});
        say("feature_level 0x{x}", .{@intFromEnum(level)});
        const factory = adapter.getParentFactory() orelse return error.NoDxgi;

        var messages: std.ArrayList(u8) = .empty;
        defer messages.deinit(alloc);
        const vs_code = compiler.compile(shader_src, "spike", "vs_main", "vs_5_0", 0, &messages, alloc) catch |err| {
            say("compile_failed {s}", .{messages.items});
            return err;
        };
        defer vs_code.deinit();
        const ps_code = try compiler.compile(shader_src, "spike", "ps_main", "ps_5_0", 0, &messages, alloc);
        defer ps_code.deinit();
        var vs: ?*d3d.VertexShader = null;
        var ps: ?*d3d.PixelShader = null;
        if (!com.succeeded(dev.createVertexShader(vs_code.bytes(), &vs))) return error.Shader;
        if (!com.succeeded(dev.createPixelShader(ps_code.bytes(), &ps))) return error.Shader;
        var cbuf: ?*d3d.Buffer = null;
        if (!com.succeeded(dev.createBuffer(&.{ .ByteWidth = 16, .Usage = .dynamic, .BindFlags = d3d.BIND_CONSTANT_BUFFER, .CPUAccessFlags = d3d.CPU_ACCESS_WRITE }, null, &cbuf))) return error.Buffer;
        return .{
            .device = dev,
            .ctx = dev.getImmediateContext(),
            .dxgi_device = dxgi_device,
            .factory = factory,
            .vs = vs.?,
            .ps = ps.?,
            .cbuf = cbuf.?,
        };
    }

    fn setColor(self: *const Gpu, color: [4]f32) void {
        var mapped: d3d.MappedSubresource = .{};
        if (!com.succeeded(self.ctx.map(self.cbuf.resource(), 0, .write_discard, &mapped))) return;
        const p: *[4]f32 = @ptrCast(@alignCast(mapped.pData.?));
        p.* = color;
        self.ctx.unmap(self.cbuf.resource(), 0);
    }
};

const Pane = struct {
    top: HWND,
    pane: HWND,
    overlay: HWND,
    swap: *dxgi.SwapChain1,
    waitable: ?*anyopaque = null,
    comp_device: ?*dcomp.Device = null,
    target: ?*dcomp.Target = null,
    visual: ?*dcomp.Visual = null,
    width: u32 = pane_w,
    height: u32 = pane_h,

    fn create(gpu: *const Gpu, mode: Mode, at: POINT) !Pane {
        const top = CreateWindowExW(0, L("D3DSpikeTop"), L("d3d spike"), WS_OVERLAPPEDWINDOW | WS_VISIBLE | WS_CLIPCHILDREN, at.x, at.y, 640, 480, null, null, GetModuleHandleW(null), null) orelse return windowFailed();
        if (mode == .blt) {
            // As murrtty's translucent windows: blur-behind with an empty
            // region, so DWM reads the window's alpha.
            const rgn = CreateRectRgn(0, 0, -1, -1);
            const hr = DwmEnableBlurBehindWindow(top, &.{ .dwFlags = DWM_BB_ENABLE | DWM_BB_BLURREGION, .fEnable = 1, .hRgnBlur = rgn, .fTransitionOnMaximized = 0 });
            say("blur_behind 0x{x:0>8}", .{@as(u32, @bitCast(hr))});
            if (rgn) |r| _ = DeleteObject(r);
        }
        const pane = CreateWindowExW(0, L("D3DSpikePane"), L(""), WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN, pane_x, pane_y, pane_w, pane_h, top, null, GetModuleHandleW(null), null) orelse return windowFailed();
        const overlay = CreateWindowExW(WS_EX_LAYERED, L("D3DSpikeOverlay"), L(""), WS_CHILD | WS_VISIBLE, 300, 20, 60, 30, pane, null, GetModuleHandleW(null), null) orelse return windowFailed();
        _ = SetLayeredWindowAttributes(overlay, 0, 255, LWA_ALPHA);
        pump();

        var self: Pane = .{ .top = top, .pane = pane, .overlay = overlay, .swap = undefined };
        var swap: ?*dxgi.SwapChain1 = null;
        const hr = switch (mode) {
            .comp => gpu.factory.createSwapChainForComposition(gpu.device, &.{
                .Width = pane_w,
                .Height = pane_h,
                .Format = .b8g8r8a8_unorm,
                .BufferCount = 2,
                .Scaling = .stretch,
                .SwapEffect = .flip_sequential,
                .AlphaMode = .premultiplied,
                .Flags = dxgi.SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT,
            }, &swap),
            .hwnd => gpu.factory.createSwapChainForHwnd(gpu.device, pane, &.{
                .Width = pane_w,
                .Height = pane_h,
                .Format = .b8g8r8a8_unorm,
                .BufferCount = 2,
                .Scaling = .none,
                .SwapEffect = .flip_discard,
                .AlphaMode = .ignore,
                .Flags = dxgi.SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT,
            }, &swap),
            .blt => gpu.factory.createSwapChainForHwnd(gpu.device, pane, &.{
                .Width = pane_w,
                .Height = pane_h,
                .Format = .b8g8r8a8_unorm,
                .BufferCount = 1,
                .Scaling = .stretch,
                .SwapEffect = .discard,
                .AlphaMode = .unspecified,
            }, &swap),
        };
        if (!com.succeeded(hr)) {
            say("swapchain_failed 0x{x:0>8}", .{@as(u32, @bitCast(hr))});
            return error.SwapChain;
        }
        self.swap = swap.?;
        if (mode != .blt) {
            if (com.query(self.swap, dxgi.SwapChain2)) |sc2| {
                defer com.release(sc2);
                _ = sc2.setMaximumFrameLatency(1);
                self.waitable = sc2.getFrameLatencyWaitableObject();
            }
        }
        if (mode == .comp) {
            const cd = dcomp.Device.create(gpu.dxgi_device) orelse return error.Composition;
            self.comp_device = cd;
            var target: ?*dcomp.Target = null;
            var thr = cd.createTargetForHwnd(pane, false, &target);
            say("comp_target 0x{x:0>8}", .{@as(u32, @bitCast(thr))});
            if (!com.succeeded(thr)) return error.Composition;
            self.target = target;
            var visual: ?*dcomp.Visual = null;
            if (!com.succeeded(cd.createVisual(&visual))) return error.Composition;
            self.visual = visual;
            _ = visual.?.setContent(self.swap);
            _ = target.?.setRoot(visual.?);
            thr = cd.commit();
            say("comp_commit 0x{x:0>8}", .{@as(u32, @bitCast(thr))});
        }
        return self;
    }

    /// One frame: the background, a red 16 x 16 square at the top left.
    /// With `sample`, its pixels read back before presenting.
    fn frame(self: *Pane, gpu: *const Gpu, sample: bool) struct { hr: com.HRESULT, wait: u32, tl: u32 = 0, mid: u32 = 0 } {
        var wait: u32 = 0;
        if (self.waitable) |h| wait = WaitForSingleObjectEx(h, 1000, 1);
        const buf = self.swap.getBuffer(0, d3d.Texture2D) orelse return .{ .hr = com.E_FAIL, .wait = wait };
        defer com.release(buf);
        var rtv: ?*d3d.RenderTargetView = null;
        if (!com.succeeded(gpu.device.createRenderTargetView(buf.resource(), null, &rtv))) return .{ .hr = com.E_FAIL, .wait = wait };
        defer com.release(rtv.?);
        const ctx = gpu.ctx;
        ctx.clearRenderTargetView(rtv.?, &bg);
        ctx.omSetRenderTargets(&.{rtv.?});
        ctx.rsSetViewports(&.{.{ .Width = 16, .Height = 16 }});
        gpu.setColor(.{ 1, 0, 0, 1 });
        ctx.iaSetPrimitiveTopology(.triangle_list);
        ctx.vsSetShader(gpu.vs);
        ctx.psSetShader(gpu.ps);
        ctx.psSetConstantBuffers(1, &.{gpu.cbuf});
        ctx.draw(3, 0);
        var result: @TypeOf(self.frame(gpu, false)) = .{ .hr = 0, .wait = wait };
        if (sample) {
            result.tl = readPixel(gpu, buf, 4, 4);
            result.mid = readPixel(gpu, buf, 200, 150);
        }
        ctx.omSetRenderTargets(&.{});
        result.hr = self.swap.present(0, 0);
        return result;
    }

    fn resize(self: *Pane, gpu: *const Gpu, width: u32, height: u32) com.HRESULT {
        gpu.ctx.clearState();
        gpu.ctx.flush();
        self.width = width;
        self.height = height;
        return self.swap.resizeBuffers(0, width, height, .unknown, if (self.waitable != null) dxgi.SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT else 0);
    }

    fn deinit(self: *Pane) void {
        if (self.waitable) |h| _ = CloseHandle(h);
        if (self.visual) |v| com.release(v);
        if (self.target) |tg| com.release(tg);
        if (self.comp_device) |cd| com.release(cd);
        com.release(self.swap);
        _ = DestroyWindow(self.top);
    }
};

/// A pixel of `tex` as 0xRRGGBB (alpha dropped), through a staging copy.
fn readPixel(gpu: *const Gpu, tex: *d3d.Texture2D, x: u32, y: u32) u32 {
    var staging: ?*d3d.Texture2D = null;
    if (!com.succeeded(gpu.device.createTexture2D(&.{ .Width = 1, .Height = 1, .Format = .b8g8r8a8_unorm, .Usage = .staging, .BindFlags = 0, .CPUAccessFlags = d3d.CPU_ACCESS_READ }, null, &staging))) return 0xdeadbe;
    defer com.release(staging.?);
    gpu.ctx.copySubresourceRegion(staging.?.resource(), 0, 0, 0, tex.resource(), 0, &.{ .left = x, .top = y, .right = x + 1, .bottom = y + 1 });
    var mapped: d3d.MappedSubresource = .{};
    if (!com.succeeded(gpu.ctx.map(staging.?.resource(), 0, .read, &mapped))) return 0xdeadbe;
    defer gpu.ctx.unmap(staging.?.resource(), 0);
    const px: [*]const u8 = @ptrCast(mapped.pData.?);
    return @as(u32, px[2]) << 16 | @as(u32, px[1]) << 8 | px[0];
}

/// PrintWindow(PW_RENDERFULLCONTENT) of the top-level window, sampled at
/// window-relative points, as 0xRRGGBB.
fn captureSamples(top: HWND, points: []const POINT, samples: []u32) bool {
    var r: RECT = .{};
    _ = GetWindowRect(top, &r);
    const width = r.right - r.left;
    const height = r.bottom - r.top;
    const screen = GetDC(null) orelse return false;
    defer _ = ReleaseDC(null, screen);
    const dc = CreateCompatibleDC(screen) orelse return false;
    defer _ = DeleteDC(dc);
    var bits: ?*anyopaque = null;
    const bmp = CreateDIBSection(dc, &.{ .biWidth = width, .biHeight = -height }, 0, &bits, null, 0) orelse return false;
    defer _ = DeleteObject(bmp);
    const old = SelectObject(dc, bmp);
    defer if (old) |o| {
        _ = SelectObject(dc, o);
    };
    if (PrintWindow(top, dc, PW_RENDERFULLCONTENT) == 0) return false;
    const px: [*]const u32 = @ptrCast(@alignCast(bits.?));
    for (points, samples) |p, *s| {
        s.* = if (p.x < width and p.y < height) px[@intCast(p.y * width + p.x)] & 0xffffff else 0xdeadbe;
    }
    return true;
}

fn desktopName(buf: []u8) []const u8 {
    const desk = GetThreadDesktop(GetCurrentThreadId()) orelse return "?";
    var name: [128]u16 = undefined;
    var needed: u32 = 0;
    if (GetUserObjectInformationW(desk, 2, &name, @sizeOf(@TypeOf(name)), &needed) == 0) return "?";
    const n = std.unicode.utf16LeToUtf8(buf, std.mem.sliceTo(&name, 0)) catch return "?";
    return buf[0..n];
}

fn now() i64 {
    var v: i64 = 0;
    _ = QueryPerformanceCounter(&v);
    return v;
}

fn present(alloc: std.mem.Allocator, mode: Mode, driver: Driver, capture: bool) !void {
    var name_buf: [256]u8 = undefined;
    say("desktop {s}", .{desktopName(&name_buf)});
    say("mode {t} {t}", .{ mode, driver });
    var gpu = try Gpu.init(alloc, driver);
    registerClasses();
    var pane = try Pane.create(&gpu, mode, .{ .x = -20000, .y = -20000 });
    defer pane.deinit();

    var freq: i64 = 0;
    _ = QueryPerformanceFrequency(&freq);
    var fails: u32 = 0;
    var timeouts: u32 = 0;
    var occluded: u32 = 0;
    var last_hr: com.HRESULT = 0;
    const frames = 60;
    const start = now();
    var worst: i64 = 0;
    for (0..frames) |i| {
        const t0 = now();
        const f = pane.frame(&gpu, i == frames / 2);
        worst = @max(worst, now() - t0);
        if (f.wait != 0) timeouts += 1;
        if (f.hr == dxgi.STATUS_OCCLUDED) occluded += 1 else if (!com.succeeded(f.hr)) {
            fails += 1;
            last_hr = f.hr;
        }
        if (i == frames / 2) say("readback tl={x:0>6} mid={x:0>6}", .{ f.tl, f.mid });
        pump();
    }
    const elapsed = now() - start;
    say("presents {d} failed={d} occluded={d} wait_timeouts={d} last_hr=0x{x:0>8}", .{ frames, fails, occluded, timeouts, @as(u32, @bitCast(last_hr)) });
    say("frame_ms avg={d:.2} worst={d:.2}", .{
        @as(f64, @floatFromInt(elapsed)) * 1000.0 / @as(f64, @floatFromInt(freq)) / frames,
        @as(f64, @floatFromInt(worst)) * 1000.0 / @as(f64, @floatFromInt(freq)),
    });
    say("removed_reason 0x{x:0>8}", .{@as(u32, @bitCast(gpu.device.getDeviceRemovedReason()))});
    if (pane.comp_device) |cd| say("comp_device_valid {}", .{cd.checkDeviceState()});

    if (!capture) return;
    // What DWM shows: the pane's top left (red), its middle (background),
    // the overlay (magenta, above the pane's content), the window's own
    // background (green). Window coordinates: the client area starts below
    // the caption, so find it.
    var wr: RECT = .{};
    var cr: RECT = .{};
    _ = GetWindowRect(pane.top, &wr);
    _ = GetWindowRect(pane.pane, &cr);
    const px = cr.left - wr.left;
    const py = cr.top - wr.top;
    const points = [_]POINT{
        .{ .x = px + 4, .y = py + 4 },
        .{ .x = px + 200, .y = py + 150 },
        .{ .x = px + 330, .y = py + 35 },
        .{ .x = px + pane_w + 20, .y = py + 20 },
        .{ .x = px + 450, .y = py + 320 },
    };
    var samples: [points.len]u32 = undefined;
    for (0..3) |_| {
        _ = pane.frame(&gpu, false);
        pump();
        Sleep(100);
    }
    if (captureSamples(pane.top, &points, &samples)) {
        say("capture red={x:0>6} bg={x:0>6} overlay={x:0>6} window={x:0>6}", .{ samples[0], samples[1], samples[2], samples[3] });
    } else say("capture failed", .{});

    // A resize in flight: the pane grows, the swap chain doesn't yet.
    _ = MoveWindow(pane.pane, pane_x, pane_y, 500, 350, 1);
    pump();
    _ = pane.frame(&gpu, false);
    pump();
    Sleep(150);
    if (captureSamples(pane.top, &points, &samples)) {
        say("resize_pending red={x:0>6} bg={x:0>6} grown={x:0>6}", .{ samples[0], samples[1], samples[4] });
    }
    const rhr = pane.resize(&gpu, 500, 350);
    say("resize_buffers 0x{x:0>8}", .{@as(u32, @bitCast(rhr))});
    for (0..3) |_| {
        _ = pane.frame(&gpu, false);
        pump();
        Sleep(100);
    }
    if (captureSamples(pane.top, &points, &samples)) {
        say("resized red={x:0>6} bg={x:0>6} grown={x:0>6}", .{ samples[0], samples[1], samples[4] });
    }
}

fn privateUsage() usize {
    var c: PROCESS_MEMORY_COUNTERS_EX = .{};
    _ = K32GetProcessMemoryInfo(GetCurrentProcess(), &c, @sizeOf(PROCESS_MEMORY_COUNTERS_EX));
    return c.PrivateUsage;
}

/// What a pane costs: a device, a composition swap chain and its visual
/// each, one frame presented.
fn commit(alloc: std.mem.Allocator, driver: Driver, count: usize) !void {
    registerClasses();
    // The first device loads the driver's DLLs: not a pane's cost.
    var warm = try Gpu.init(alloc, driver);
    _ = &warm;
    const before = privateUsage();
    var panes: std.ArrayList(struct { gpu: Gpu, pane: Pane }) = .empty;
    defer panes.deinit(alloc);
    for (0..count) |i| {
        var gpu = try Gpu.init(alloc, driver);
        var pane = try Pane.create(&gpu, .comp, .{ .x = -20000 + @as(i32, @intCast(i)) * 10, .y = -20000 });
        _ = pane.frame(&gpu, false);
        pump();
        try panes.append(alloc, .{ .gpu = gpu, .pane = pane });
    }
    Sleep(200);
    const after = privateUsage();
    say("commit panes={d} total_mb={d:.1} per_pane_mb={d:.1}", .{
        count,
        @as(f64, @floatFromInt(after -| before)) / (1024 * 1024),
        @as(f64, @floatFromInt(after -| before)) / (1024 * 1024) / @as(f64, @floatFromInt(count)),
    });
}

/// System32's d3dcompiler_47.dll: its machine type.
fn dllInfo() !void {
    var buf: [300]u16 = undefined;
    const n = GetSystemDirectoryW(&buf, buf.len);
    const name = L("\\d3dcompiler_47.dll");
    if (n == 0 or n + name.len + 1 > buf.len) return say("d3dcompiler no_system_dir", .{});
    @memcpy(buf[n..][0..name.len], name);
    buf[n + name.len] = 0;
    const file = CreateFileW(@ptrCast(&buf), GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, 0, null);
    if (@intFromPtr(file) == INVALID_HANDLE) return say("d3dcompiler missing", .{});
    defer _ = CloseHandle(file);
    var head: [4096]u8 = undefined;
    var got32: u32 = 0;
    _ = ReadFile(file, &head, head.len, &got32, null);
    const got: usize = got32;
    if (got < 0x40) return say("d3dcompiler unreadable", .{});
    const pe = std.mem.readInt(u32, head[0x3c..0x40], .little);
    if (pe + 6 > got) return say("d3dcompiler unreadable", .{});
    const machine = std.mem.readInt(u16, head[pe + 4 ..][0..2], .little);
    say("d3dcompiler machine=0x{x:0>4} ({s})", .{ machine, switch (machine) {
        0x8664 => "x64",
        0xaa64 => "arm64",
        0xa641 => "arm64ec",
        0x014c => "x86",
        else => "other",
    } });
    say("compiler_loads {}", .{compiler.compileFn() != null});
}

pub fn main() void {
    const alloc = std.heap.page_allocator;
    _ = SetProcessDPIAware();
    var argc: i32 = 0;
    const argv = CommandLineToArgvW(GetCommandLineW(), &argc) orelse return;
    var args_buf: [8][]const u8 = undefined;
    const count: usize = @intCast(@min(argc, 8));
    for (0..count) |i| {
        args_buf[i] = std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(argv[i])) catch return;
    }
    const args = args_buf[0..count];
    if (args.len < 2) return say("usage: present|commit|dll", .{});
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "dll")) return dllInfo() catch {};
    if (std.mem.eql(u8, cmd, "present") and args.len >= 4) {
        const mode = std.meta.stringToEnum(Mode, args[2]) orelse return say("bad mode", .{});
        const driver = std.meta.stringToEnum(Driver, args[3]) orelse return say("bad driver", .{});
        const capture = args.len >= 5 and std.mem.eql(u8, args[4], "capture");
        present(alloc, mode, driver, capture) catch |err| say("error {t}", .{err});
        return;
    }
    if (std.mem.eql(u8, cmd, "commit") and args.len >= 4) {
        const driver = std.meta.stringToEnum(Driver, args[2]) orelse return say("bad driver", .{});
        const panes = std.fmt.parseInt(usize, args[3], 10) catch 8;
        commit(alloc, driver, panes) catch |err| say("error {t}", .{err});
        return;
    }
    say("usage: present|commit|dll", .{});
}
