//! Thin WGL bindings.
//!
//! Only the types and functions used in Ghostty are modelled. The
//! WGL_ARB_* entry points can only be resolved with a current context,
//! so `Extensions.load` bootstraps a throwaway legacy context on a
//! hidden window to look them up once.
//!
//! opengl32 itself is loaded at run time (murrtty's roadmap 6.3), by full
//! path: Windows' own from System32, the opengl32.dll `MURRTTY_OPENGL`
//! names (a full path), such as a software OpenGL's (Mesa's llvmpipe)
//! standing in for Windows', or the program's own (`useBundled`: murrtty's
//! Mesa, roadmap 6.3b). gdi32 (pixel formats, SwapBuffers) and the
//! inspector's loader then find that same module by its name.

const std = @import("std");
const builtin = @import("builtin");

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

// WGL_ARB_create_context_robustness
pub const WGL_CONTEXT_ROBUST_ACCESS_BIT_ARB = 0x00000004;
pub const WGL_CONTEXT_RESET_NOTIFICATION_STRATEGY_ARB = 0x8256;
pub const WGL_LOSE_CONTEXT_ON_RESET_ARB = 0x8252;

/// opengl32, as `loadLibrary` loaded it.
var library: ?Library = null;

const Library = struct {
    module: HMODULE,
    createContext: *const fn (HDC) callconv(.winapi) ?HGLRC,
    deleteContext: *const fn (HGLRC) callconv(.winapi) BOOL,
    makeCurrent: *const fn (?HDC, ?HGLRC) callconv(.winapi) BOOL,
    getProcAddress: *const fn ([*:0]const u8) callconv(.winapi) ?PROC,
    getString: *const fn (u32) callconv(.winapi) ?[*:0]const u8,
};

/// The variable naming another opengl32.dll, by full path.
pub const library_variable = "MURRTTY_OPENGL";

/// Which opengl32 `loadLibrary` loaded.
pub const Source = enum {
    /// Windows' own (System32's), which routes to the graphics driver.
    system,
    /// The one MURRTTY_OPENGL names.
    variable,
    /// The program's own, named by `useBundled` (murrtty's Mesa).
    bundled,
};
var loaded_source: ?Source = null;
var bundled_path: ?[*:0]const u16 = null;

/// Load `path` (a full path to a file named opengl32.dll, which must stay
/// valid) in place of Windows' own and MURRTTY_OPENGL's: the program's own
/// software OpenGL. Before anything loads OpenGL.
pub fn useBundled(path: [*:0]const u16) void {
    std.debug.assert(library == null);
    bundled_path = path;
}

/// Which opengl32 is loaded, null before `loadLibrary`.
pub fn loadedSource() ?Source {
    return loaded_source;
}

/// Load opengl32 (see the file's comment) once. On the UI thread, before
/// any context exists.
pub fn loadLibrary() Error!void {
    if (library != null) return;
    var buf: [1024]u16 = undefined;
    var source: Source = .system;
    const module = module: {
        if (bundled_path) |path| {
            source = .bundled;
            // What it loads from its own folder (Mesa's opengl32.dll its
            // gallium DLL) and System32, nothing from anywhere else.
            break :module LoadLibraryExW(path, null, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32) orelse {
                log.err("could not load the bundled OpenGL err={}", .{GetLastError()});
                return error.LibraryMissing;
            };
        }
        if (libraryOverridden()) {
            source = .variable;
            // A path that isn't a full one is refused rather than ignored:
            // the search would find some other opengl32.dll.
            const path = libraryOverride(&buf) orelse {
                log.err("{s} must be the full path of a file named opengl32.dll", .{library_variable});
                return error.LibraryMissing;
            };
            // Its own folder is searched for what it loads (Mesa's
            // opengl32.dll loads a gallium DLL beside it).
            break :module LoadLibraryExW(path, null, LOAD_WITH_ALTERED_SEARCH_PATH) orelse {
                log.err("could not load the OpenGL {s} names err={}", .{ library_variable, GetLastError() });
                return error.LibraryMissing;
            };
        }
        const system = std.unicode.utf8ToUtf16LeStringLiteral("opengl32.dll");
        break :module LoadLibraryExW(system, null, LOAD_LIBRARY_SEARCH_SYSTEM32) orelse {
            log.err("could not load opengl32.dll err={}", .{GetLastError()});
            return error.LibraryMissing;
        };
    };
    library = .{
        .module = module,
        .createContext = @ptrCast(GetProcAddress(module, "wglCreateContext") orelse return error.LibraryMissing),
        .deleteContext = @ptrCast(GetProcAddress(module, "wglDeleteContext") orelse return error.LibraryMissing),
        .makeCurrent = @ptrCast(GetProcAddress(module, "wglMakeCurrent") orelse return error.LibraryMissing),
        .getProcAddress = @ptrCast(GetProcAddress(module, "wglGetProcAddress") orelse return error.LibraryMissing),
        .getString = @ptrCast(GetProcAddress(module, "glGetString") orelse return error.LibraryMissing),
    };
    loaded_source = source;
}

/// What the first OpenGL 4.3 context reported (GL_RENDERER and
/// GL_VERSION), for the log and murrtty's GUI tests.
var renderer_buf: [256]u8 = undefined;
var renderer_text: ?[]const u8 = null;

/// Note the current context's renderer, once (logged). On the UI thread,
/// with a context just made current.
pub fn noteRenderer() void {
    if (renderer_text != null) return;
    const lib = library orelse return;
    const GL_RENDERER = 0x1F01;
    const GL_VERSION = 0x1F02;
    const r: []const u8 = if (lib.getString(GL_RENDERER)) |p| std.mem.span(p) else "";
    const v: []const u8 = if (lib.getString(GL_VERSION)) |p| std.mem.span(p) else "";
    const text = std.fmt.bufPrint(&renderer_buf, "{s}, {s}", .{ r[0..@min(r.len, 120)], v[0..@min(v.len, 120)] }) catch return;
    renderer_text = text;
    log.info("OpenGL from {t} opengl32: {s}", .{ loaded_source orelse .system, text });
}

/// What `noteRenderer` noted, null before a context was made.
pub fn rendererText() ?[]const u8 {
    return renderer_text;
}

/// The opengl32.dll `MURRTTY_OPENGL` names, into `buf` (forward slashes
/// made back ones, as the loader takes the DLL's folder from the path):
/// null if it is unset, not a full path (a drive's root or a share), which
/// would let the search find another, or not a file named opengl32.dll,
/// which gdi32 (pixel formats, SwapBuffers) wouldn't find by its name.
pub fn libraryOverride(buf: *[1024]u16) ?[*:0]const u16 {
    const n = GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral(library_variable), buf, buf.len);
    if (n == 0 or n >= buf.len) return null;
    buf[n] = 0;
    for (buf[0..n]) |*u| if (u.* == '/') {
        u.* = '\\';
    };
    const full = (n >= 3 and buf[1] == ':' and buf[2] == '\\') or
        (n >= 2 and buf[0] == '\\' and buf[1] == '\\');
    if (!full) return null;
    const base = buf[(std.mem.lastIndexOfScalar(u16, buf[0..n], '\\') orelse 0) + 1 .. n];
    const want = std.unicode.utf8ToUtf16LeStringLiteral("opengl32.dll");
    if (base.len != want.len) return null;
    for (base, want) |a, b| {
        const lower = if (a >= 'A' and a <= 'Z') a + 32 else a;
        if (lower != b) return null;
    }
    return @ptrCast(buf);
}

/// Whether `MURRTTY_OPENGL` is set to anything (a path refused by
/// `libraryOverride` still counts: loading then fails, rather than finding
/// another opengl32.dll).
pub fn libraryOverridden() bool {
    // The length with its terminator: 1 for an empty value.
    return GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral(library_variable), null, 0) > 1;
}

/// An export of the opengl32 loaded (GL 1.1's own functions), for callers
/// outside glad: linking any would load Windows' opengl32 at start,
/// whichever one MURRTTY_OPENGL names.
pub fn libraryProc(name: [*:0]const u8) ?PROC {
    const lib = library orelse return null;
    return GetProcAddress(lib.module, name);
}

pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

pub fn wglCreateContext(hdc: HDC) ?HGLRC {
    const lib = library orelse return null;
    return lib.createContext(hdc);
}

pub fn wglDeleteContext(hglrc: HGLRC) BOOL {
    const lib = library orelse return 0;
    return lib.deleteContext(hglrc);
}

pub fn wglMakeCurrent(hdc: ?HDC, hglrc: ?HGLRC) BOOL {
    const lib = library orelse return 0;
    return lib.makeCurrent(hdc, hglrc);
}

pub fn wglGetProcAddress(name: [*:0]const u8) ?PROC {
    const lib = library orelse return null;
    return lib.getProcAddress(name);
}

pub extern "gdi32" fn ChoosePixelFormat(hdc: HDC, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) c_int;
pub extern "gdi32" fn SetPixelFormat(hdc: HDC, format: c_int, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) BOOL;
pub extern "gdi32" fn DescribePixelFormat(hdc: HDC, format: c_int, n: u32, ppfd: ?*PIXELFORMATDESCRIPTOR) callconv(.winapi) c_int;
pub extern "gdi32" fn SwapBuffers(hdc: HDC) callconv(.winapi) BOOL;

extern "kernel32" fn GetModuleHandleA(name: ?[*:0]const u8) callconv(.winapi) ?HMODULE;
extern "kernel32" fn LoadLibraryExW(name: [*:0]const u16, file: ?*anyopaque, flags: u32) callconv(.winapi) ?HMODULE;
const LOAD_WITH_ALTERED_SEARCH_PATH = 0x00000008;
const LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR = 0x00000100;
const LOAD_LIBRARY_SEARCH_SYSTEM32 = 0x00000800;
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
/// values instead of null on failure, so fall back to opengl32's exports.
pub fn getProcAddress(name: [*c]const u8) callconv(.c) ?PROC {
    const n: [*:0]const u8 = @ptrCast(name);
    if (wglGetProcAddress(n)) |p| switch (@intFromPtr(p)) {
        1, 2, 3, std.math.maxInt(usize) => {},
        else => return p,
    };
    const lib = library orelse return null;
    return GetProcAddress(lib.module, n);
}

pub const Error = error{
    WindowCreateFailed,
    PixelFormatFailed,
    ContextCreateFailed,
    MakeCurrentFailed,
    ExtensionMissing,
    /// opengl32 (Windows', or the one MURRTTY_OPENGL names) didn't load.
    LibraryMissing,
};

/// A failure the GUI tests ask for (GHOSTTY_WIN32_TEST_WGL in a Debug
/// build): "extensions" (Extensions.load as without WGL_ARB_*, as
/// Windows' own OpenGL 1.1) or "context" (no 4.3 context, as an old
/// driver), whichever opengl32 is loaded; "system-extensions" and
/// "system-context" only with Windows' own (murrtty's Mesa works).
fn testFailure() enum { none, extensions, context } {
    if (comptime builtin.mode != .debug) return .none;
    var buf: [32]u16 = undefined;
    const n = GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("GHOSTTY_WIN32_TEST_WGL"), &buf, buf.len);
    if (n == 0 or n >= buf.len) return .none;
    var value: []const u16 = buf[0..n];
    const system = std.unicode.utf8ToUtf16LeStringLiteral("system-");
    if (std.mem.startsWith(u16, value, system)) {
        if (loaded_source != .system) return .none;
        value = value[system.len..];
    }
    if (std.mem.eql(u16, value, std.unicode.utf8ToUtf16LeStringLiteral("extensions"))) return .extensions;
    if (std.mem.eql(u16, value, std.unicode.utf8ToUtf16LeStringLiteral("context"))) return .context;
    return .none;
}

/// What a legacy context reports of the OpenGL Windows offers here:
/// vendor, renderer and version, into `buf`. Windows' own fallback, where
/// no driver offers OpenGL, is "GDI Generic" OpenGL 1.1. For telling why
/// a 4.3 context can't be had (murrtty's roadmap 6.3).
pub const Info = struct { vendor: []const u8, renderer: []const u8, version: []const u8 };

pub fn info(buf: *[512]u8) ?Info {
    loadLibrary() catch return null;
    const lib = library.?;
    const bootstrap = Bootstrap.init() catch return null;
    defer bootstrap.deinit();
    var fba: std.heap.FixedBufferAllocator = .init(buf);
    const alloc = fba.allocator();
    const GL_VENDOR = 0x1F00;
    const GL_RENDERER = 0x1F01;
    const GL_VERSION = 0x1F02;
    var out: [3][]const u8 = undefined;
    for ([_]u32{ GL_VENDOR, GL_RENDERER, GL_VERSION }, &out) |name, *o| {
        const s: []const u8 = if (lib.getString(name)) |p| std.mem.span(p) else "";
        o.* = alloc.dupe(u8, s[0..@min(s.len, 160)]) catch "";
    }
    return .{ .vendor = out[0], .renderer = out[1], .version = out[2] };
}

/// A hidden window with a legacy context current, to ask WGL what can
/// only be asked with one.
const Bootstrap = struct {
    hwnd: HWND,
    hdc: HDC,
    ctx: HGLRC,

    fn init() Error!Bootstrap {
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
        errdefer _ = DestroyWindow(hwnd);
        const hdc = GetDC(hwnd) orelse return error.WindowCreateFailed;
        errdefer _ = ReleaseDC(hwnd, hdc);

        const pfd: PIXELFORMATDESCRIPTOR = .{
            .dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER,
            .iPixelType = PFD_TYPE_RGBA,
            .cColorBits = 32,
        };
        const format = ChoosePixelFormat(hdc, &pfd);
        if (format == 0 or SetPixelFormat(hdc, format, &pfd) == 0) return error.PixelFormatFailed;

        const ctx = wglCreateContext(hdc) orelse return error.ContextCreateFailed;
        errdefer _ = wglDeleteContext(ctx);
        if (wglMakeCurrent(hdc, ctx) == 0) return error.MakeCurrentFailed;
        return .{ .hwnd = hwnd, .hdc = hdc, .ctx = ctx };
    }

    fn deinit(self: Bootstrap) void {
        _ = wglMakeCurrent(null, null);
        _ = wglDeleteContext(self.ctx);
        _ = ReleaseDC(self.hwnd, self.hdc);
        _ = DestroyWindow(self.hwnd);
    }
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

    /// WGL_ARB_create_context_robustness: contexts can be asked to report
    /// a GPU driver reset (murrtty's roadmap 6.3), and the renderer then
    /// builds itself again in a new one.
    robust: bool = false,

    pub fn load() Error!Extensions {
        try loadLibrary();
        const bootstrap = try Bootstrap.init();
        defer bootstrap.deinit();

        if (testFailure() == .extensions) return error.ExtensionMissing;
        const choose = wglGetProcAddress("wglChoosePixelFormatARB") orelse {
            log.err("WGL_ARB_pixel_format is not supported by the OpenGL driver", .{});
            return error.ExtensionMissing;
        };
        const create = wglGetProcAddress("wglCreateContextAttribsARB") orelse {
            log.err("WGL_ARB_create_context is not supported by the OpenGL driver", .{});
            return error.ExtensionMissing;
        };
        const robust = robust: {
            const get = wglGetProcAddress("wglGetExtensionsStringARB") orelse break :robust false;
            const getExtensions: *const fn (HDC) callconv(.winapi) ?[*:0]const u8 = @ptrCast(get);
            const list = std.mem.span(getExtensions(bootstrap.hdc) orelse break :robust false);
            var it = std.mem.tokenizeScalar(u8, list, ' ');
            while (it.next()) |name| if (std.mem.eql(u8, name, "WGL_ARB_create_context_robustness")) break :robust true;
            break :robust false;
        };

        return .{
            .choosePixelFormat = @ptrCast(choose),
            .createContextAttribs = @ptrCast(create),
            .swapInterval = if (wglGetProcAddress("wglSwapIntervalEXT")) |p| @ptrCast(p) else null,
            .robust = robust,
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
    /// Where the driver can, it reports a GPU driver reset by losing the
    /// context (`Context.robust`); else, or if the driver refuses that, a
    /// plain one.
    pub fn createContext(
        self: *const Extensions,
        hdc: HDC,
        major: c_int,
        minor: c_int,
        debug: bool,
    ) Error!Context {
        if (testFailure() == .context) return error.ContextCreateFailed;
        const flags: c_int = if (debug) WGL_CONTEXT_DEBUG_BIT_ARB else 0;
        if (self.robust) {
            const attribs = [_]c_int{
                WGL_CONTEXT_MAJOR_VERSION_ARB,               major,
                WGL_CONTEXT_MINOR_VERSION_ARB,               minor,
                WGL_CONTEXT_PROFILE_MASK_ARB,                WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
                WGL_CONTEXT_FLAGS_ARB,                       flags | WGL_CONTEXT_ROBUST_ACCESS_BIT_ARB,
                WGL_CONTEXT_RESET_NOTIFICATION_STRATEGY_ARB, WGL_LOSE_CONTEXT_ON_RESET_ARB,
                0,
            };
            if (self.createContextAttribs(hdc, null, &attribs)) |ctx| return .{ .handle = ctx, .robust = true };
            log.warn("no robust OpenGL context err={x}; without one, a driver reset can't be recovered from", .{GetLastError()});
        }
        const attribs = [_]c_int{
            WGL_CONTEXT_MAJOR_VERSION_ARB, major,
            WGL_CONTEXT_MINOR_VERSION_ARB, minor,
            WGL_CONTEXT_PROFILE_MASK_ARB,  WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
            WGL_CONTEXT_FLAGS_ARB,         flags,
            0,
        };
        const ctx = self.createContextAttribs(hdc, null, &attribs) orelse {
            log.err("wglCreateContextAttribsARB failed err={x}", .{GetLastError()});
            return error.ContextCreateFailed;
        };
        return .{ .handle = ctx, .robust = false };
    }

    /// A context `createContext` made, and whether it reports resets.
    pub const Context = struct { handle: HGLRC, robust: bool };
};
