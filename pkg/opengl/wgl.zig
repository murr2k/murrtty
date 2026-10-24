//! Thin WGL bindings.
//!
//! Only the types and functions used in Ghostty are modelled. The
//! WGL_ARB_* entry points can only be resolved with a current context,
//! so `Extensions.load` bootstraps a throwaway legacy context on a
//! hidden window to look them up once.

const std = @import("std");

const log = std.log.scoped(.opengl_wgl);

pub const BOOL = c_int;
pub const HDC = *opaque {};
pub const HGLRC = *opaque {};
pub const HWND = *opaque {};
pub const HMODULE = *opaque {};
pub const PROC = *const fn () callconv(.c) void;

pub const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: u16 = @sizeOf(PIXELFORMATDESCRIPTOR),
    nVersion: u16 = 1,
    dwFlags: u32 = 0,
    iPixelType: u8 = 0,
    cColorBits: u8 = 0,
    cRedBits: u8 = 0,
    cRedShift: u8 = 0,
    cGreenBits: u8 = 0,
    cGreenShift: u8 = 0,
    cBlueBits: u8 = 0,
    cBlueShift: u8 = 0,
    cAlphaBits: u8 = 0,
    cAlphaShift: u8 = 0,
    cAccumBits: u8 = 0,
    cAccumRedBits: u8 = 0,
    cAccumGreenBits: u8 = 0,
    cAccumBlueBits: u8 = 0,
    cAccumAlphaBits: u8 = 0,
    cDepthBits: u8 = 0,
    cStencilBits: u8 = 0,
    cAuxBuffers: u8 = 0,
    iLayerType: u8 = 0,
    bReserved: u8 = 0,
    dwLayerMask: u32 = 0,
    dwVisibleMask: u32 = 0,
    dwDamageMask: u32 = 0,
};

pub const PFD_DOUBLEBUFFER = 0x00000001;
pub const PFD_DRAW_TO_WINDOW = 0x00000004;
pub const PFD_SUPPORT_OPENGL = 0x00000020;
pub const PFD_TYPE_RGBA = 0;

// WGL_ARB_pixel_format / WGL_ARB_framebuffer_sRGB
pub const WGL_DRAW_TO_WINDOW_ARB = 0x2001;
pub const WGL_ACCELERATION_ARB = 0x2003;
pub const WGL_SUPPORT_OPENGL_ARB = 0x2010;
pub const WGL_DOUBLE_BUFFER_ARB = 0x2011;
pub const WGL_PIXEL_TYPE_ARB = 0x2013;
pub const WGL_COLOR_BITS_ARB = 0x2014;
pub const WGL_ALPHA_BITS_ARB = 0x201B;
pub const WGL_DEPTH_BITS_ARB = 0x2022;
pub const WGL_STENCIL_BITS_ARB = 0x2023;
pub const WGL_FULL_ACCELERATION_ARB = 0x2027;
pub const WGL_TYPE_RGBA_ARB = 0x202B;
pub const WGL_FRAMEBUFFER_SRGB_CAPABLE_ARB = 0x20A9;

// WGL_ARB_create_context / WGL_ARB_create_context_profile
pub const WGL_CONTEXT_MAJOR_VERSION_ARB = 0x2091;
pub const WGL_CONTEXT_MINOR_VERSION_ARB = 0x2092;
pub const WGL_CONTEXT_FLAGS_ARB = 0x2094;
pub const WGL_CONTEXT_PROFILE_MASK_ARB = 0x9126;
pub const WGL_CONTEXT_CORE_PROFILE_BIT_ARB = 0x00000001;
pub const WGL_CONTEXT_DEBUG_BIT_ARB = 0x00000001;

pub extern "opengl32" fn wglCreateContext(hdc: HDC) callconv(.winapi) ?HGLRC;
pub extern "opengl32" fn wglDeleteContext(hglrc: HGLRC) callconv(.winapi) BOOL;
pub extern "opengl32" fn wglMakeCurrent(hdc: ?HDC, hglrc: ?HGLRC) callconv(.winapi) BOOL;
pub extern "opengl32" fn wglGetProcAddress(name: [*:0]const u8) callconv(.winapi) ?PROC;

pub extern "gdi32" fn ChoosePixelFormat(hdc: HDC, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) c_int;
pub extern "gdi32" fn SetPixelFormat(hdc: HDC, format: c_int, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) BOOL;
pub extern "gdi32" fn DescribePixelFormat(hdc: HDC, format: c_int, n: u32, ppfd: ?*PIXELFORMATDESCRIPTOR) callconv(.winapi) c_int;
pub extern "gdi32" fn SwapBuffers(hdc: HDC) callconv(.winapi) BOOL;

extern "kernel32" fn GetModuleHandleA(name: ?[*:0]const u8) callconv(.winapi) ?HMODULE;
extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.winapi) ?HMODULE;
extern "kernel32" fn GetProcAddress(module: HMODULE, name: [*:0]const u8) callconv(.winapi) ?PROC;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

// Just enough user32 to create the hidden bootstrap window.
const WNDCLASSEXA = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXA),
    style: u32 = 0,
    lpfnWndProc: *const fn (HWND, u32, usize, isize) callconv(.winapi) isize,
    cbClsExtra: c_int = 0,
    cbWndExtra: c_int = 0,
    hInstance: ?HMODULE = null,
    hIcon: ?*anyopaque = null,
    hCursor: ?*anyopaque = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u8 = null,
    lpszClassName: [*:0]const u8,
    hIconSm: ?*anyopaque = null,
};
extern "user32" fn RegisterClassExA(*const WNDCLASSEXA) callconv(.winapi) u16;
extern "user32" fn CreateWindowExA(
    ex_style: u32,
    class: [*:0]const u8,
    name: [*:0]const u8,
    style: u32,
    x: c_int,
    y: c_int,
    w: c_int,
    h: c_int,
    parent: ?HWND,
    menu: ?*anyopaque,
    instance: ?HMODULE,
    param: ?*anyopaque,
) callconv(.winapi) ?HWND;
extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
extern "user32" fn DefWindowProcA(HWND, u32, usize, isize) callconv(.winapi) isize;
pub extern "user32" fn GetDC(?HWND) callconv(.winapi) ?HDC;
pub extern "user32" fn ReleaseDC(?HWND, HDC) callconv(.winapi) c_int;
pub const RECT = extern struct { left: c_long = 0, top: c_long = 0, right: c_long = 0, bottom: c_long = 0 };
pub extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetEnvironmentVariableW([*:0]const u16, ?[*]u16, u32) callconv(.winapi) u32;

/// Resolve a GL function for GLAD. `wglGetProcAddress` only returns
/// functions above OpenGL 1.1, and some drivers return small sentinel
/// values instead of null on failure, so fall back to opengl32.dll.
pub fn getProcAddress(name: [*c]const u8) callconv(.c) ?PROC {
    const n: [*:0]const u8 = @ptrCast(name);
    if (wglGetProcAddress(n)) |p| switch (@intFromPtr(p)) {
        1, 2, 3, std.math.maxInt(usize) => {},
        else => return p,
    };
    const module = GetModuleHandleA("opengl32.dll") orelse
        LoadLibraryA("opengl32.dll") orelse return null;
    return GetProcAddress(module, n);
}

pub const Error = error{
    WindowCreateFailed,
    PixelFormatFailed,
    ContextCreateFailed,
    MakeCurrentFailed,
    ExtensionMissing,
};

/// The WGL extension entry points we need. These are resolved once at
/// startup; on Windows the ICD returns the same pointers for every
/// context on the same device, which is all we support.
pub const Extensions = struct {
    choosePixelFormat: *const fn (
        hdc: HDC,
        int_attribs: ?[*]const c_int,
        float_attribs: ?[*]const f32,
        max_formats: u32,
        formats: *c_int,
        num_formats: *u32,
    ) callconv(.winapi) BOOL,

    createContextAttribs: *const fn (
        hdc: HDC,
        share: ?HGLRC,
        attribs: [*]const c_int,
    ) callconv(.winapi) ?HGLRC,

    swapInterval: ?*const fn (interval: c_int) callconv(.winapi) BOOL,

    pub fn load() Error!Extensions {
        const instance = GetModuleHandleA(null);
        const class_name = "GhosttyWglBootstrap";
        _ = RegisterClassExA(&.{
            .style = 0x0020, // CS_OWNDC
            .lpfnWndProc = &DefWindowProcA,
            .hInstance = instance,
            .lpszClassName = class_name,
        });

        const hwnd = CreateWindowExA(0, class_name, "", 0, 0, 0, 1, 1, null, null, instance, null) orelse {
            log.err("failed to create WGL bootstrap window err={}", .{GetLastError()});
            return error.WindowCreateFailed;
        };
        defer _ = DestroyWindow(hwnd);
        const hdc = GetDC(hwnd) orelse return error.WindowCreateFailed;
        defer _ = ReleaseDC(hwnd, hdc);

        const pfd: PIXELFORMATDESCRIPTOR = .{
            .dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER,
            .iPixelType = PFD_TYPE_RGBA,
            .cColorBits = 32,
        };
        const format = ChoosePixelFormat(hdc, &pfd);
        if (format == 0 or SetPixelFormat(hdc, format, &pfd) == 0) return error.PixelFormatFailed;

        const ctx = wglCreateContext(hdc) orelse return error.ContextCreateFailed;
        defer _ = wglDeleteContext(ctx);
        if (wglMakeCurrent(hdc, ctx) == 0) return error.MakeCurrentFailed;
        defer _ = wglMakeCurrent(null, null);

        const choose = wglGetProcAddress("wglChoosePixelFormatARB") orelse {
            log.err("WGL_ARB_pixel_format is not supported by the OpenGL driver", .{});
            return error.ExtensionMissing;
        };
        const create = wglGetProcAddress("wglCreateContextAttribsARB") orelse {
            log.err("WGL_ARB_create_context is not supported by the OpenGL driver", .{});
            return error.ExtensionMissing;
        };

        return .{
            .choosePixelFormat = @ptrCast(choose),
            .createContextAttribs = @ptrCast(create),
            .swapInterval = if (wglGetProcAddress("wglSwapIntervalEXT")) |p| @ptrCast(p) else null,
        };
    }

    /// Choose and set an sRGB-capable, double-buffered RGBA8 pixel
    /// format on the given device context. A window's pixel format can
    /// only be set once, so this must be called once per window.
    pub fn setPixelFormat(self: *const Extensions, hdc: HDC) Error!void {
        const attribs = [_]c_int{
            WGL_DRAW_TO_WINDOW_ARB,           1,
            WGL_SUPPORT_OPENGL_ARB,           1,
            WGL_DOUBLE_BUFFER_ARB,            1,
            WGL_ACCELERATION_ARB,             WGL_FULL_ACCELERATION_ARB,
            WGL_PIXEL_TYPE_ARB,               WGL_TYPE_RGBA_ARB,
            WGL_COLOR_BITS_ARB,               24,
            WGL_ALPHA_BITS_ARB,               8,
            WGL_DEPTH_BITS_ARB,               0,
            WGL_STENCIL_BITS_ARB,             0,
            WGL_FRAMEBUFFER_SRGB_CAPABLE_ARB, 1,
            0,
        };
        var format: c_int = 0;
        var count: u32 = 0;
        if (self.choosePixelFormat(hdc, &attribs, null, 1, &format, &count) == 0 or count == 0) {
            log.err("no suitable WGL pixel format err={}", .{GetLastError()});
            return error.PixelFormatFailed;
        }

        var pfd: PIXELFORMATDESCRIPTOR = .{};
        _ = DescribePixelFormat(hdc, format, @sizeOf(PIXELFORMATDESCRIPTOR), &pfd);
        if (SetPixelFormat(hdc, format, &pfd) == 0) {
            log.err("SetPixelFormat failed err={}", .{GetLastError()});
            return error.PixelFormatFailed;
        }
    }

    /// Create an OpenGL core profile context of at least the given version.
    pub fn createContext(
        self: *const Extensions,
        hdc: HDC,
        major: c_int,
        minor: c_int,
        debug: bool,
    ) Error!HGLRC {
        const attribs = [_]c_int{
            WGL_CONTEXT_MAJOR_VERSION_ARB, major,
            WGL_CONTEXT_MINOR_VERSION_ARB, minor,
            WGL_CONTEXT_PROFILE_MASK_ARB,  WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
            WGL_CONTEXT_FLAGS_ARB,         if (debug) WGL_CONTEXT_DEBUG_BIT_ARB else 0,
            0,
        };
        return self.createContextAttribs(hdc, null, &attribs) orelse {
            log.err("wglCreateContextAttribsARB failed err={x}", .{GetLastError()});
            return error.ContextCreateFailed;
        };
    }
};
