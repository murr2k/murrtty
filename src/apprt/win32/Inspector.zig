//! The terminal inspector (roadmap 5.12), GTK's: a window of its own for a
//! pane, "murrtty: Terminal Inspector", 1000x600, showing Ghostty's
//! inspector (Dear ImGui) for it. The core owns the inspector's data
//! (activateInspector, deactivateInspector); this owns the window, a WGL
//! 4.3 context of its own and the ImGui context, drawn by ImGui's OpenGL 3
//! backend, as the embedded runtime's Inspector does with Metal. Input is
//! fed to ImGui by hand, as GTK's widget does (with the ImGuiMod_ keys it
//! leaves out), and it draws 30 times a second while shown, as macOS's
//! view, and at once after input.
const Inspector = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const cimgui = @import("dcimgui");
const gl = @import("opengl");
const wgl = gl.wgl;

const c = @import("c.zig");
const key = @import("key.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const test_hooks = @import("test_hooks.zig");
const CoreInspector = @import("../../inspector/main.zig").Inspector;
const global = @import("../../global.zig");

const log = std.log.scoped(.win32_inspector);

pub const class_name = c.L("MurrttyInspector");

/// GTK's default size, in DIPs.
const default_width = 1000;
const default_height = 600;
/// About 30 frames a second, as macOS's view draws.
const frame_ms = 33;
const timer_id = 1;

app: *App,
surface: *Surface,
hwnd: c.HWND,
hdc: ?c.HDC = null,
glrc: ?wgl.HGLRC = null,
ig: ?*cimgui.c.ImGuiContext = null,
/// ImGui's OpenGL 3 backend is set up in `ig`.
backend: bool = false,
/// The core's inspector is on for the pane.
active: bool = false,
dpi: c.UINT = 96,
/// The last frame's time, for ImGui's delta.
instant: ?std.Io.Timestamp = null,
/// The cursor ImGui asked for in the last frame.
cursor: cimgui.c.ImGuiMouseCursor = cimgui.c.ImGuiMouseCursor_Arrow,
tracking_leave: bool = false,
/// ImGui's mouse buttons held, by bit; the window holds the mouse while
/// any is.
buttons: u8 = 0,
/// What ImGui last read from the clipboard, kept until its next read.
clipboard: ?[:0]u8 = null,
/// Frames drawn (the GUI tests' dump).
frames: u32 = 0,
/// GL 1.1's own functions, from the opengl32 murrtty loaded (roadmap 6.3:
/// linked, they would load Windows' at start, whichever MURRTTY_OPENGL
/// names).
gl11: ?Gl11 = null,

const Gl11 = struct {
    viewport: *const fn (c_int, c_int, c_int, c_int) callconv(.winapi) void,
    clearColor: *const fn (f32, f32, f32, f32) callconv(.winapi) void,
    clear: *const fn (u32) callconv(.winapi) void,

    fn load() ?Gl11 {
        return .{
            .viewport = @ptrCast(wgl.libraryProc("glViewport") orelse return null),
            .clearColor = @ptrCast(wgl.libraryProc("glClearColor") orelse return null),
            .clear = @ptrCast(wgl.libraryProc("glClear") orelse return null),
        };
    }
};

pub fn registerClass(instance: c.HINSTANCE) !void {
    const wc: c.WNDCLASSEXW = .{
        // Its own DC for its GL context.
        .style = c.CS_OWNDC,
        .lpfnWndProc = &wndProc,
        .hInstance = instance,
        .hCursor = c.LoadCursorW(null, c.IDC_ARROW),
        .lpszClassName = class_name,
    };
    if (c.RegisterClassExW(&wc) == 0) return error.RegisterClassFailed;
}

/// Open the inspector for `surface`, shown and in front.
pub fn create(surface: *Surface) !*Inspector {
    const app = surface.app;
    const alloc = app.core_app.alloc;
    const ext = try app.wglExtensions();
    const self = try alloc.create(Inspector);
    // Until its window exists: then the window's destroy frees it.
    var owned = true;
    errdefer if (owned) alloc.destroy(self);
    self.* = .{ .app = app, .surface = surface, .hwnd = undefined };

    _ = c.CreateWindowExW(
        0,
        class_name,
        c.L("murrtty: Terminal Inspector"),
        c.WS_OVERLAPPEDWINDOW,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        default_width,
        default_height,
        null,
        null,
        app.instance,
        self,
    ) orelse return error.CreateWindowFailed;
    owned = false;
    errdefer _ = c.DestroyWindow(self.hwnd);

    self.dpi = c.GetDpiForWindow(self.hwnd);
    self.sizeForDpi();
    const hdc = c.GetDC(self.hwnd) orelse return error.GetDCFailed;
    self.hdc = hdc;
    const whdc: wgl.HDC = @ptrCast(hdc);
    try ext.setPixelFormat(whdc);
    self.glrc = (try ext.createContext(whdc, 4, 3, false)).handle;
    self.gl11 = Gl11.load();
    if (wgl.wglMakeCurrent(whdc, self.glrc) == 0) return error.MakeCurrentFailed;
    defer _ = wgl.wglMakeCurrent(null, null);
    // No waiting on the display in SwapBuffers: it runs on the UI thread,
    // and the timer paces it (the terminals' renderers do the same).
    if (ext.swapInterval) |swapInterval| _ = swapInterval(0);

    const ig = cimgui.c.ImGui_CreateContext(null) orelse return error.OutOfMemory;
    self.ig = ig;
    const scope = self.enter().?;
    defer scope.leave();
    const ig_io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
    ig_io.BackendPlatformName = "murrtty_win32";
    // The clipboard through murrtty's (it retries while others hold it).
    const pio: *cimgui.c.ImGuiPlatformIO = cimgui.c.ImGui_GetPlatformIO();
    pio.Platform_ClipboardUserData = self;
    pio.Platform_GetClipboardTextFn = &getClipboardText;
    pio.Platform_SetClipboardTextFn = &setClipboardText;
    // A 4.3 core context: GLSL 4.10's shaders.
    if (!cimgui.ImGui_ImplOpenGL3_Init("#version 410")) return error.ImGuiBackendFailed;
    self.backend = true;
    CoreInspector.setup();
    self.applyStyle();

    try surface.core_surface.activateInspector();
    self.active = true;

    _ = c.SetTimer(self.hwnd, timer_id, frame_ms, null);
    _ = c.ShowWindow(self.hwnd, c.SW_SHOWNORMAL);
    _ = c.SetForegroundWindow(self.hwnd);
    return self;
}

/// Close it (its window's destroy frees it).
pub fn destroy(self: *Inspector) void {
    _ = c.DestroyWindow(self.hwnd);
}

/// Bring it to the front.
pub fn present(self: *Inspector) void {
    if (c.IsIconic(self.hwnd) != 0) _ = c.ShowWindow(self.hwnd, c.SW_RESTORE);
    _ = c.SetForegroundWindow(self.hwnd);
}

fn onDestroy(self: *Inspector) void {
    _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA, 0);
    _ = c.KillTimer(self.hwnd, timer_id);
    if (self.ig) |ig| {
        const prev = cimgui.c.ImGui_GetCurrentContext();
        if (self.glrc) |glrc| if (self.hdc) |hdc| {
            _ = wgl.wglMakeCurrent(@ptrCast(hdc), glrc);
        };
        cimgui.c.ImGui_SetCurrentContext(ig);
        // Not ShutdownWithLoaderCleanup: its GL function table is the
        // process's, and another inspector still drawing would call GL
        // through it zeroed (opengl32 stays loaded, so it stays right).
        if (self.backend) cimgui.ImGui_ImplOpenGL3_Shutdown();
        cimgui.c.ImGui_DestroyContext(ig);
        cimgui.c.ImGui_SetCurrentContext(if (prev == ig) null else prev);
        if (self.glrc != null) _ = wgl.wglMakeCurrent(null, null);
    }
    if (self.glrc) |glrc| _ = wgl.wglDeleteContext(glrc);
    if (self.hdc) |hdc| _ = c.ReleaseDC(self.hwnd, hdc);
    if (self.active) self.surface.core_surface.deactivateInspector();
    if (self.surface.inspector == self) self.surface.inspector = null;
    const alloc = self.app.core_app.alloc;
    if (self.clipboard) |text| alloc.free(text);
    alloc.destroy(self);
}

/// Its ImGui context made current, the one before put back by `leave`: a
/// message sent to it (from another thread, while a frame of another
/// inspector waits in the clipboard) must not switch that frame's context.
const Scope = struct {
    prev: ?*cimgui.c.ImGuiContext,

    fn leave(self: Scope) void {
        cimgui.c.ImGui_SetCurrentContext(self.prev);
    }
};

fn enter(self: *Inspector) ?Scope {
    const ig = self.ig orelse return null;
    const scope: Scope = .{ .prev = cimgui.c.ImGui_GetCurrentContext() };
    cimgui.c.ImGui_SetCurrentContext(ig);
    return scope;
}

/// The window at GTK's size for its DPI.
fn sizeForDpi(self: *Inspector) void {
    var r: c.RECT = .{
        .right = @intCast(@divTrunc(default_width * self.dpi, 96)),
        .bottom = @intCast(@divTrunc(default_height * self.dpi, 96)),
    };
    _ = c.AdjustWindowRectExForDpi(&r, c.WS_OVERLAPPEDWINDOW, c.FALSE, 0, self.dpi);
    _ = c.SetWindowPos(self.hwnd, null, 0, 0, r.right - r.left, r.bottom - r.top, c.SWP_NOMOVE | c.SWP_NOZORDER | c.SWP_NOACTIVATE);
}

/// ImGui's default style scaled for the window's DPI, as GTK and the
/// embedded runtime do; and the text too (the core loads its font at 32 px,
/// a 2x scale's 16), so it is 16 px at 96 DPI. Its context current.
fn applyStyle(self: *Inspector) void {
    const scale: f32 = @as(f32, @floatFromInt(self.dpi)) / 96.0;
    var style: cimgui.c.ImGuiStyle = undefined;
    cimgui.ext.ImGuiStyle_ImGuiStyle(&style);
    cimgui.c.ImGuiStyle_ScaleAllSizes(&style, scale);
    style.FontScaleDpi = scale / 2.0;
    cimgui.c.ImGui_GetStyle().* = style;
}

/// Draw a frame: the core's inspector for the pane, through ImGui.
fn render(self: *Inspector) void {
    const hdc = self.hdc orelse return;
    if (!self.backend or c.IsIconic(self.hwnd) != 0) return;
    if (wgl.wglMakeCurrent(@ptrCast(hdc), self.glrc) == 0) return;
    defer _ = wgl.wglMakeCurrent(null, null);
    const scope = self.enter() orelse return;
    defer scope.leave();

    var r: c.RECT = .{};
    _ = c.GetClientRect(self.hwnd, &r);
    const ig_io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
    ig_io.DisplaySize = .{ .x = @floatFromInt(r.right), .y = @floatFromInt(r.bottom) };
    ig_io.DisplayFramebufferScale = .{ .x = 1, .y = 1 };

    // Twice, as the other runtimes do: ImGui settles some state only on
    // the frame after.
    const core = &self.surface.core_surface;
    for (0..2) |_| {
        cimgui.ImGui_ImplOpenGL3_NewFrame();
        self.newFrame(ig_io);
        cimgui.c.ImGui_NewFrame();
        if (core.inspector) |i| i.render(core);
        self.cursor = cimgui.c.ImGui_GetMouseCursor();
        cimgui.c.ImGui_Render();
    }

    if (self.gl11) |g| {
        g.viewport(0, 0, r.right, r.bottom);
        g.clearColor(0, 0, 0, 1);
        g.clear(c.GL_COLOR_BUFFER_BIT);
    }
    cimgui.ImGui_ImplOpenGL3_RenderDrawData(cimgui.c.ImGui_GetDrawData());
    _ = wgl.SwapBuffers(@ptrCast(hdc));
    self.frames +%= 1;
}

fn newFrame(self: *Inspector, ig_io: *cimgui.c.ImGuiIO) void {
    const now: std.Io.Timestamp = .now(global.io(), .awake);
    ig_io.DeltaTime = if (self.instant) |prev| delta: {
        const ns: f64 = @floatFromInt(prev.durationTo(now).toNanoseconds());
        break :delta @max(0.00001, @as(f32, @floatCast(ns / std.time.ns_per_s)));
    } else 1.0 / 60.0;
    self.instant = now;
}

/// ImGui's clipboard read, through murrtty's (Surface.openClipboard).
fn getClipboardText(ctx: ?*cimgui.c.ImGuiContext) callconv(.c) [*c]const u8 {
    _ = ctx;
    const pio: *cimgui.c.ImGuiPlatformIO = cimgui.c.ImGui_GetPlatformIO();
    const self: *Inspector = @ptrCast(@alignCast(pio.Platform_ClipboardUserData orelse return null));
    const alloc = self.app.core_app.alloc;
    const text = (Surface.readClipboardText(alloc, self.hwnd) catch return null) orelse return null;
    defer alloc.free(text);
    const owned = alloc.dupeSentinel(u8, text, 0) catch return null;
    if (self.clipboard) |old| alloc.free(old);
    self.clipboard = owned;
    return owned.ptr;
}

/// ImGui's clipboard write, through murrtty's.
fn setClipboardText(ctx: ?*cimgui.c.ImGuiContext, text: [*c]const u8) callconv(.c) void {
    _ = ctx;
    const pio: *cimgui.c.ImGuiPlatformIO = cimgui.c.ImGui_GetPlatformIO();
    const self: *Inspector = @ptrCast(@alignCast(pio.Platform_ClipboardUserData orelse return));
    if (text == null) return;
    Surface.writeClipboardText(self.app.core_app.alloc, self.hwnd, std.mem.sliceTo(text, 0)) catch |err| {
        log.warn("error writing the clipboard err={}", .{err});
    };
}

/// Draw soon: input changed something.
fn queueRender(self: *Inspector) void {
    _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
}

fn mouseButton(self: *Inspector, button: c_int, down: bool) void {
    const scope = self.enter() orelse return;
    defer scope.leave();
    const bit = @as(u8, 1) << @intCast(button);
    if (down) {
        if (self.buttons == 0) _ = c.SetCapture(self.hwnd);
        self.buttons |= bit;
    } else {
        self.buttons &= ~bit;
        if (self.buttons == 0 and c.GetCapture() == self.hwnd) _ = c.ReleaseCapture();
    }
    cimgui.c.ImGuiIO_AddMouseButtonEvent(cimgui.c.ImGui_GetIO(), button, down);
    self.queueRender();
}

/// The mouse taken away (another window took it): what ImGui thinks is
/// still held comes up.
fn mouseLost(self: *Inspector) void {
    if (self.buttons == 0) return;
    const scope = self.enter() orelse return;
    defer scope.leave();
    const ig_io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
    for (0..3) |b| if (self.buttons & (@as(u8, 1) << @intCast(b)) != 0) {
        cimgui.c.ImGuiIO_AddMouseButtonEvent(ig_io, @intCast(b), false);
    };
    self.buttons = 0;
    self.queueRender();
}

/// The modifiers' state, as ImGui's keys (its Win32 backend sends both the
/// ImGuiMod_ keys, which set io.KeyCtrl and the rest, and the left keys).
fn sendMods(ig_io: *cimgui.c.ImGuiIO) void {
    const mods = key.currentMods();
    cimgui.c.ImGuiIO_AddKeyEvent(ig_io, cimgui.c.ImGuiMod_Ctrl, mods.ctrl);
    cimgui.c.ImGuiIO_AddKeyEvent(ig_io, cimgui.c.ImGuiMod_Shift, mods.shift);
    cimgui.c.ImGuiIO_AddKeyEvent(ig_io, cimgui.c.ImGuiMod_Alt, mods.alt);
    cimgui.c.ImGuiIO_AddKeyEvent(ig_io, cimgui.c.ImGuiMod_Super, mods.super);
}

/// ImGui's key for a key message: letters and digits as the layout has
/// them (its shortcuts, Ctrl+A, Ctrl+Z, follow the layout, as GTK's keyval
/// and ImGui's own Win32 backend do), anything else by its place.
fn imguiKey(wparam: c.WPARAM, lparam: c.LPARAM) ?cimgui.c.ImGuiKey {
    if (wparam >= 'A' and wparam <= 'Z') return cimgui.c.ImGuiKey_A + @as(cimgui.c.ImGuiKey, @intCast(wparam - 'A'));
    if (wparam >= '0' and wparam <= '9') return cimgui.c.ImGuiKey_0 + @as(cimgui.c.ImGuiKey, @intCast(wparam - '0'));
    const native = key.nativeKeycode(wparam, lparam);
    return key.remapKeypad(key.physicalKey(native), wparam).imguiKey();
}

fn keyEvent(self: *Inspector, wparam: c.WPARAM, lparam: c.LPARAM, down: bool) void {
    const scope = self.enter() orelse return;
    defer scope.leave();
    const ig_io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
    sendMods(ig_io);
    if (imguiKey(wparam, lparam)) |k| cimgui.c.ImGuiIO_AddKeyEvent(ig_io, k, down);
    self.queueRender();
}

fn setCursor(self: *Inspector) void {
    const id: ?usize = switch (self.cursor) {
        cimgui.c.ImGuiMouseCursor_None => null,
        cimgui.c.ImGuiMouseCursor_TextInput => c.IDC_IBEAM,
        cimgui.c.ImGuiMouseCursor_ResizeAll => c.IDC_SIZEALL,
        cimgui.c.ImGuiMouseCursor_ResizeEW => c.IDC_SIZEWE,
        cimgui.c.ImGuiMouseCursor_ResizeNS => c.IDC_SIZENS,
        cimgui.c.ImGuiMouseCursor_ResizeNESW => c.IDC_SIZENESW,
        cimgui.c.ImGuiMouseCursor_ResizeNWSE => c.IDC_SIZENWSE,
        cimgui.c.ImGuiMouseCursor_Hand => c.IDC_HAND,
        cimgui.c.ImGuiMouseCursor_NotAllowed => c.IDC_NO,
        else => c.IDC_ARROW,
    };
    _ = c.SetCursor(if (id) |i| c.LoadCursorW(null, i) else null);
}

fn fromHwnd(hwnd: c.HWND) ?*Inspector {
    const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (ptr == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(ptr)));
}

fn wndProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (msg == c.WM_NCCREATE) {
        const cs: *const c.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(cs.lpCreateParams)));
        if (cs.lpCreateParams) |p| {
            const self: *Inspector = @ptrCast(@alignCast(p));
            self.hwnd = hwnd;
        }
        return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    }
    const self = fromHwnd(hwnd) orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    switch (msg) {
        c.WM_ERASEBKGND => return 1,
        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = undefined;
            _ = c.BeginPaint(hwnd, &ps);
            _ = c.EndPaint(hwnd, &ps);
            self.render();
            return 0;
        },
        c.WM_TIMER => {
            if (wparam == timer_id) self.render();
            return 0;
        },
        c.WM_SIZE => {
            self.queueRender();
            return 0;
        },
        c.WM_DPICHANGED => {
            self.dpi = c.hiword(wparam);
            const r: *const c.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = c.SetWindowPos(hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
            if (self.enter()) |scope| {
                defer scope.leave();
                self.applyStyle();
            }
            self.queueRender();
            return 0;
        },
        c.WM_MOUSEMOVE => {
            if (!self.tracking_leave) {
                var tme: c.TRACKMOUSEEVENT = .{ .dwFlags = c.TME_LEAVE, .hwndTrack = hwnd };
                if (c.TrackMouseEvent(&tme) != 0) self.tracking_leave = true;
            }
            const scope = self.enter() orelse return 0;
            defer scope.leave();
            cimgui.c.ImGuiIO_AddMousePosEvent(cimgui.c.ImGui_GetIO(), @floatFromInt(c.xParam(lparam)), @floatFromInt(c.yParam(lparam)));
            self.queueRender();
            return 0;
        },
        c.WM_MOUSELEAVE => {
            self.tracking_leave = false;
            // The GUI tests' posted moves (Harness.pinMouse), as a pane's.
            if (comptime test_hooks.enabled) if (self.app.test_state.pin_mouse) return 0;
            const scope = self.enter() orelse return 0;
            defer scope.leave();
            cimgui.c.ImGuiIO_AddMousePosEvent(cimgui.c.ImGui_GetIO(), -std.math.floatMax(f32), -std.math.floatMax(f32));
            self.queueRender();
            return 0;
        },
        c.WM_LBUTTONDOWN, c.WM_LBUTTONDBLCLK => self.mouseButton(cimgui.c.ImGuiMouseButton_Left, true),
        c.WM_LBUTTONUP => self.mouseButton(cimgui.c.ImGuiMouseButton_Left, false),
        c.WM_RBUTTONDOWN, c.WM_RBUTTONDBLCLK => self.mouseButton(cimgui.c.ImGuiMouseButton_Right, true),
        c.WM_RBUTTONUP => self.mouseButton(cimgui.c.ImGuiMouseButton_Right, false),
        c.WM_MBUTTONDOWN, c.WM_MBUTTONDBLCLK => self.mouseButton(cimgui.c.ImGuiMouseButton_Middle, true),
        c.WM_MBUTTONUP => self.mouseButton(cimgui.c.ImGuiMouseButton_Middle, false),
        c.WM_CAPTURECHANGED => self.mouseLost(),
        c.WM_MOUSEWHEEL, c.WM_MOUSEHWHEEL => {
            const scope = self.enter() orelse return 0;
            defer scope.leave();
            const ig_io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
            const delta: f32 = @as(f32, @floatFromInt(@as(i16, @bitCast(c.hiword(wparam))))) / 120.0;
            // ImGui's x wheel is positive to the left (its Win32 backend's).
            if (msg == c.WM_MOUSEWHEEL)
                cimgui.c.ImGuiIO_AddMouseWheelEvent(ig_io, 0, delta)
            else
                cimgui.c.ImGuiIO_AddMouseWheelEvent(ig_io, -delta, 0);
            self.queueRender();
            return 0;
        },
        c.WM_KEYDOWN, c.WM_KEYUP => {
            self.keyEvent(wparam, lparam, msg == c.WM_KEYDOWN);
            return 0;
        },
        // ImGui hears them; Windows' own (Alt+F4, Alt+Space) still work.
        c.WM_SYSKEYDOWN, c.WM_SYSKEYUP => {
            self.keyEvent(wparam, lparam, msg == c.WM_SYSKEYDOWN);
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        // Alt+letter: ImGui's, without Windows' beep for a menu it lacks.
        c.WM_SYSCHAR => return 0,
        c.WM_SYSCOMMAND => {
            // A bare Alt or F10 would put the window in menu mode, which
            // swallows the next key; Alt+Space's menu still opens.
            if (wparam & 0xFFF0 == c.SC_KEYMENU and lparam == 0) return 0;
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        c.WM_CHAR => {
            const scope = self.enter() orelse return 0;
            defer scope.leave();
            if (wparam > 0 and wparam < 0x10000) cimgui.c.ImGuiIO_AddInputCharacterUTF16(cimgui.c.ImGui_GetIO(), @intCast(wparam));
            self.queueRender();
            return 0;
        },
        c.WM_SETFOCUS, c.WM_KILLFOCUS => {
            const scope = self.enter() orelse return 0;
            defer scope.leave();
            cimgui.c.ImGuiIO_AddFocusEvent(cimgui.c.ImGui_GetIO(), msg == c.WM_SETFOCUS);
            self.queueRender();
            return 0;
        },
        c.WM_SETCURSOR => {
            if (c.loword(@as(usize, @bitCast(lparam))) == c.HTCLIENT) {
                self.setCursor();
                return 1;
            }
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        c.WM_DESTROY => {
            self.onDestroy();
            return 0;
        },
        else => return c.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
    return 0;
}
