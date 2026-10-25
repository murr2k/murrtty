//! A terminal surface: a child window that hosts one core surface.
//!
//! The renderer draws straight into this window with WGL (see
//! renderer/OpenGL.zig), so the window class is CS_OWNDC and the
//! window is dedicated to the surface.
const Surface = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const global = @import("../../global.zig");
const input = @import("../../input.zig");
const renderer = @import("../../renderer.zig");
const terminal = @import("../../terminal/main.zig");
const CoreSurface = @import("../../Surface.zig");

const c = @import("c.zig");
const key = @import("key.zig");
const split_layout = @import("split_layout.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const test_hooks = @import("test_hooks.zig");
const text_util = @import("text.zig");

const log = std.log.scoped(.win32_surface);

pub const class_name = c.L("GhosttySurface");

/// Private message posted to the surface window: show the queued
/// clipboard confirmations (see clipboard_pending).
const WM_CLIPBOARD_CONFIRM = c.WM_APP + 2;

/// Private message posted to the surface window: tell the core that the
/// keyboard focus changed (see `has_focus`).
const WM_FOCUS_CHANGED = c.WM_APP + 3;

app: *App,
window: *Window,
hwnd: c.HWND,

/// The core surface. Only valid when `core_initialized` is true.
core_surface: CoreSurface = undefined,
core_initialized: bool = false,

title: ?[:0]const u8 = null,

/// The terminal's background and foreground as they are now, which the
/// window's caption and tab strip follow: the surface's config's until a
/// program changes them (OSC 10/11) or the config changes.
colors: Colors = .{ .bg = .{ .r = 0, .g = 0, .b = 0 }, .fg = .{ .r = 255, .g = 255, .b = 255 } },

content_scale: apprt.ContentScale = .{ .x = 1, .y = 1 },
size: apprt.SurfaceSize = .{ .width = 0, .height = 0 },

/// Whether the pane is shown (setVisible): not in a hidden tab, a
/// minimized window, or behind another pane's zoom.
shown: bool = true,

/// The color (sRGB, alpha) the pane is dimmed with as an unfocused pane of
/// a split tab, or null (Tab.syncDim).
dim_color: ?[4]f32 = null,
cursor_pos: apprt.CursorPos = .{ .x = -1, .y = -1 },

/// Mouse state.
tracking_leave: bool = false,
buttons_down: u8 = 0,
cursor: ?c.HCURSOR = null,
mouse_hidden: bool = false,

/// Keyboard and IME state.
high_surrogate: u16 = 0,
ime_composing: bool = false,
/// An Esc press cancelled a divider drag (see escapeTaken).
escape_taken: bool = false,
/// Key events passed to the core, for the GUI tests' state dump.
keys_sent: u32 = 0,
/// Commands the shell reported finished (OSC 133;D after 133;C) and the
/// last one's exit code, for the same dump. Nothing shows them yet.
commands_finished: u32 = 0,
last_exit: ?u8 = null,

/// Whether this window has the keyboard focus, as Windows last said, and
/// whether the core was last told it has (a core surface starts out
/// focused). The core hears from a posted message, never inside
/// WM_SETFOCUS/WM_KILLFOCUS: those arrive inside SetFocus, and a core
/// callback that moves the focus (goto_split) would otherwise re-enter the
/// surface it is running on.
has_focus: bool = false,
core_focus: bool = true,
focus_posted: bool = false,

/// Clipboard confirmations waiting to be shown, oldest first. They are
/// shown from the message loop, never inside a core callback. The surface
/// owns them, so closing it answers (denies) and frees what is still queued.
clipboard_pending: std.ArrayList(PendingClipboard) = .empty,

pub const Colors = struct {
    bg: configpkg.Config.Color,
    fg: configpkg.Config.Color,

    pub fn fromConfig(config: *const configpkg.Config) Colors {
        return .{ .bg = config.background, .fg = config.foreground };
    }
};

/// Register the window class. Called once by the App.
pub fn registerClass(instance: c.HINSTANCE) !void {
    const wc: c.WNDCLASSEXW = .{
        .style = c.CS_OWNDC,
        .lpfnWndProc = &wndProc,
        .hInstance = instance,
        .hCursor = c.LoadCursorW(null, c.IDC_IBEAM),
        .lpszClassName = class_name,
    };
    if (c.RegisterClassExW(&wc) == 0) return error.RegisterClassFailed;
}

pub fn init(
    self: *Surface,
    app: *App,
    window: *Window,
    /// The parent window: its tab's container.
    parent_hwnd: c.HWND,
    context: apprt.surface.NewSurfaceContext,
    parent: ?*CoreSurface,
    /// Initial position within the parent's client area.
    rect: c.RECT,
) !void {
    self.* = .{
        .app = app,
        .window = window,
        .hwnd = undefined,
        .cursor = c.LoadCursorW(null, c.IDC_IBEAM),
    };

    self.hwnd = c.CreateWindowExW(
        0,
        class_name,
        c.L(""),
        c.WS_CHILD | c.WS_VISIBLE | c.WS_CLIPSIBLINGS | c.WS_CLIPCHILDREN,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        parent_hwnd,
        null,
        app.instance,
        self,
    ) orelse {
        log.err("failed to create surface window err={}", .{c.GetLastError()});
        return error.CreateWindowFailed;
    };
    errdefer _ = c.DestroyWindow(self.hwnd);

    self.updateSize();
    self.updateContentScale();

    try app.core_app.addSurface(self);
    errdefer app.core_app.deleteSurface(self);

    var config = try apprt.surface.newConfig(app.core_app, &app.config, context);
    defer config.deinit();
    self.colors = .fromConfig(&config);

    // Initializing the core surface creates the renderer, which sets
    // the pixel format on our window and starts the render thread.
    try self.core_surface.init(
        app.core_app.alloc,
        &config,
        app.core_app,
        app,
        self,
    );
    self.core_initialized = true;
    errdefer {
        self.core_initialized = false;
        self.core_surface.deinit();
    }

    if (parent) |p| if (app.config.@"window-inherit-font-size") {
        try self.core_surface.setFontSize(p.font_size);
    };

    // The window may have been resized by an initial_size action
    // while the core surface was initializing.
    self.updateSize();
    self.core_surface.sizeCallback(self.size) catch |err| {
        log.warn("error in size callback err={}", .{err});
    };

    // Focus gained, or lost, before the core surface existed reaches it
    // now.
    if (self.has_focus) app.core_app.focusSurface(&self.core_surface);
    self.queueFocus();
}

/// The view interface of the tabs' split trees (Tab.Tree). References do
/// nothing: panes are freed only by the close queue (see Tab.tree).
pub fn ref(self: *Surface) *Surface {
    return self;
}

pub fn unref(self: *Surface) void {
    _ = self;
}

pub fn eql(a: *const Surface, b: *const Surface) bool {
    return a == b;
}

/// Dim the pane with a translucent `color` over its frames, or stop
/// (null). Forces a frame so the change shows at once.
pub fn setDim(self: *Surface, color: ?[4]f32) void {
    if (std.meta.eql(self.dim_color, color)) return;
    self.dim_color = color;
    if (!self.core_initialized) return;
    const api = &self.core_surface.renderer.api;
    const Rect = @TypeOf(api.*).Overlay.Rect;
    // The whole window, whatever its size later.
    const rects: []const Rect = if (color) |col| &.{.{
        .x = 0,
        .y = 0,
        .width = std.math.maxInt(i16),
        .height = std.math.maxInt(i16),
        .color = col,
    }} else &.{};
    api.setOverlay(rects);
    self.forceFrame();
}

/// Make the renderer draw a frame though the terminal didn't change.
fn forceFrame(self: *Surface) void {
    const cs = &self.core_surface;
    cs.renderer_state.mutex.lockUncancelable(global.io());
    cs.renderer_state.terminal.flags.dirty.clear = true;
    cs.renderer_state.mutex.unlock(global.io());
    cs.renderer_thread.wakeup.notify() catch {};
}

/// The smallest the pane may be laid out (split_layout's view interface):
/// the core's minimum grid at the current cell size, plus padding. Worked
/// out each time, since the core sends its size_limit only once and the
/// cells change with the font size and the DPI (App relays the tab out on
/// cell_size). The padding is the core's own, except when balanced, which
/// grows with the pane: then the configured padding, scaled as the core
/// scales it.
pub fn layoutMin(self: *const Surface) split_layout.Size {
    if (!self.core_initialized) return .{};
    const cs = &self.core_surface;
    const cfg = &cs.config;
    const pad_x: u32, const pad_y: u32 = if (cfg.window_padding_balance == .false) .{
        // A config reload doesn't change a terminal's padding; this does.
        cs.size.padding.left + cs.size.padding.right,
        cs.size.padding.top + cs.size.padding.bottom,
    } else .{
        scaledPadding(cfg.window_padding_left, self.content_scale.x) +
            scaledPadding(cfg.window_padding_right, self.content_scale.x),
        scaledPadding(cfg.window_padding_top, self.content_scale.y) +
            scaledPadding(cfg.window_padding_bottom, self.content_scale.y),
    };
    const width = cs.size.cell.width * CoreSurface.min_window_width_cells + pad_x;
    const height = cs.size.cell.height * CoreSurface.min_window_height_cells + pad_y;
    return .{
        .width = @intCast(@min(width, std.math.maxInt(u16))),
        .height = @intCast(@min(height, std.math.maxInt(u16))),
    };
}

/// Padding `points` in pixels at content scale `scale`, as the core scales
/// window-padding-*: rounded down.
fn scaledPadding(points: u32, scale: f32) u32 {
    const dpi = scale * 96;
    return @intFromFloat(@floor(@as(f32, @floatFromInt(points)) * dpi / 72));
}

/// Tear down the core surface. The window itself is destroyed along
/// with its parent.
pub fn deinit(self: *Surface) void {
    _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA, 0);

    // Answer and free confirmations that were never shown.
    for (self.clipboard_pending.items) |p| self.dropClipboardConfirm(p);
    self.clipboard_pending.deinit(self.app.core_app.alloc);

    if (self.core_initialized) {
        self.core_initialized = false;
        self.app.core_app.deleteSurface(self);
        self.core_surface.deinit();
    }

    if (self.title) |v| self.app.core_app.alloc.free(v);
    self.title = null;
}

//---------------------------------------------------------------
// apprt.Surface interface

pub fn core(self: *Surface) *CoreSurface {
    return &self.core_surface;
}

pub fn rtApp(self: *const Surface) *App {
    return self.app;
}

/// The window the renderer draws into.
pub fn nativeWindow(self: *const Surface) *anyopaque {
    return self.hwnd;
}

pub fn close(self: *Surface, process_active: bool) void {
    // The core is still using this surface, so close it later from the
    // message loop (and confirm there, outside the core).
    self.app.request(.{ .close_surface = .{
        .id = self.core_surface.id,
        .process_active = process_active,
    } });
}

pub fn getTitle(self: *Surface) ?[:0]const u8 {
    return self.title;
}

pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
    return self.content_scale;
}

pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
    return self.size;
}

pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
    return self.cursor_pos;
}

pub fn supportsClipboard(self: *const Surface, clipboard_type: apprt.Clipboard) bool {
    _ = self;
    // Windows has a single system clipboard.
    return clipboard_type == .standard;
}

pub fn clipboardRequest(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !apprt.ClipboardReadResult {
    if (!self.supportsClipboard(clipboard_type)) return .unsupported;

    // Kitty clipboard writes carry their own contents and read nothing.
    if (state == .kitty_write) {
        self.completeClipboard(state, .{}, null);
        return .started;
    }

    const alloc = self.app.core_app.alloc;
    const text = readClipboardText(alloc, self.hwnd) catch |err| {
        log.warn("error reading clipboard err={}", .{err});
        return .unavailable;
    };
    defer if (text) |t| alloc.free(t);

    const contents: []const terminal.clipboard.Content = if (text) |t|
        &.{.{ .mime = "text/plain", .data = t }}
    else
        &.{};
    const available: []const []const u8 = if (text != null) &.{"text/plain"} else &.{};

    self.completeClipboard(state, .{
        .contents = contents,
        .available = available,
    }, text);
    return .started;
}

/// Complete a clipboard request. If the core asks for confirmation the
/// request is queued and confirmed from the message loop.
fn completeClipboard(
    self: *Surface,
    state: apprt.ClipboardRequest,
    complete: CoreSurface.CompleteClipboard,
    text: ?[]const u8,
) void {
    self.core_surface.completeClipboardRequest(state, complete) catch |err| switch (err) {
        error.UnsafePaste, error.UnauthorizedPaste => {
            const alloc = self.app.core_app.alloc;
            self.queueClipboardConfirm(.{
                .request = state,
                .text = if (text) |t| alloc.dupe(u8, t) catch null else null,
                .unsafe = err == error.UnsafePaste,
            });
        },
        else => log.err("error completing clipboard request err={}", .{err}),
    };
}

const PendingClipboard = struct {
    /// The read to complete, or null for an OSC 52 write confirmation.
    request: ?apprt.ClipboardRequest,
    /// The clipboard text (read) or the text to write (write).
    text: ?[]u8,
    unsafe: bool = false,
};

fn queueClipboardConfirm(self: *Surface, pending: PendingClipboard) void {
    self.clipboard_pending.append(self.app.core_app.alloc, pending) catch {
        self.dropClipboardConfirm(pending);
        return;
    };
    _ = c.PostMessageW(self.hwnd, WM_CLIPBOARD_CONFIRM, 0, 0);
}

/// Deny a queued read (a write needs no answer) and free its text.
fn dropClipboardConfirm(self: *Surface, pending: PendingClipboard) void {
    if (pending.request) |req| {
        if (self.core_initialized) self.core_surface.denyClipboardRequest(req);
    }
    if (pending.text) |t| self.app.core_app.alloc.free(t);
}

/// Post WM_CLIPBOARD_CONFIRM again for confirmations that waited for
/// another dialog to close.
pub fn resumeClipboardConfirms(self: *Surface) void {
    if (self.clipboard_pending.items.len > 0) {
        _ = c.PostMessageW(self.hwnd, WM_CLIPBOARD_CONFIRM, 0, 0);
    }
}

/// Show the queued confirmations, one dialog at a time.
fn runClipboardConfirms(self: *Surface) void {
    // Only one dialog is open at a time, app-wide. A dialog's message
    // loop can dispatch WM_CLIPBOARD_CONFIRM, from this surface or
    // another; those wait, and the modal scope reposts them when it ends
    // (App.resumeAfterModal).
    if (self.app.modal_depth > 0) return;

    // Nothing can close this surface while a dialog is open (see
    // App.Request), so it stays valid across iterations.
    while (self.core_initialized and self.clipboard_pending.items.len > 0) {
        const pending = self.clipboard_pending.orderedRemove(0);
        defer if (pending.text) |t| self.app.core_app.alloc.free(t);
        if (pending.request) |req| {
            self.confirmClipboardRead(req, pending.text, pending.unsafe);
        } else if (pending.text) |t| {
            self.confirmClipboardWrite(t);
        }
    }
}

fn confirmClipboardRead(
    self: *Surface,
    req: apprt.ClipboardRequest,
    text: ?[]const u8,
    unsafe: bool,
) void {
    const alloc = self.app.core_app.alloc;
    const preview = text orelse "";
    const message = std.fmt.allocPrint(alloc, "{s}\n\n{s}{s}", .{
        if (unsafe)
            "Pasting this text into the terminal may be dangerous as it looks like some commands may be executed. Paste anyway?"
        else
            "An application is attempting to access the clipboard. Allow it?",
        text_util.truncate(preview, 512),
        if (preview.len > 512) "..." else "",
    }) catch return self.core_surface.denyClipboardRequest(req);
    defer alloc.free(message);

    if (!self.app.confirm(self.window.hwnd, message, "Ghostty: Clipboard")) {
        self.core_surface.denyClipboardRequest(req);
        return;
    }

    const contents: []const terminal.clipboard.Content = if (text) |t|
        &.{.{ .mime = "text/plain", .data = t }}
    else
        &.{};
    self.core_surface.completeClipboardRequest(req, .{
        .contents = contents,
        .available = if (text != null) &.{"text/plain"} else &.{},
        .confirmed = true,
    }) catch |err| log.err("error completing clipboard request err={}", .{err});
}

pub fn setClipboard(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm: bool,
) !void {
    if (clipboard_type != .standard) return;

    const text: [:0]const u8 = for (contents) |content| {
        if (std.mem.eql(u8, content.mime, "text/plain")) break content.data;
    } else return;

    const alloc = self.app.core_app.alloc;
    if (confirm) {
        // Confirm from the message loop, not inside the core callback.
        self.queueClipboardConfirm(.{ .request = null, .text = try alloc.dupe(u8, text) });
        return;
    }

    try writeClipboardText(alloc, self.hwnd, text);
}

fn confirmClipboardWrite(self: *Surface, text: []const u8) void {
    const alloc = self.app.core_app.alloc;
    const message = std.fmt.allocPrint(
        alloc,
        "An application is attempting to write to the clipboard. Allow it?\n\n{s}{s}",
        .{ text_util.truncate(text, 512), if (text.len > 512) "..." else "" },
    ) catch return;
    defer alloc.free(message);
    if (!self.app.confirm(self.window.hwnd, message, "Ghostty: Clipboard")) return;

    writeClipboardText(alloc, self.hwnd, text) catch |err| {
        log.warn("error writing clipboard err={}", .{err});
    };
}

pub fn defaultTermioEnv(self: *Surface) !std.process.Environ.Map {
    _ = self;
    return try global.environMap();
}

pub fn redrawInspector(self: *Surface) void {
    _ = self;
}

pub fn renderDeviceOptions(self: *Surface) !renderer.Device.Options {
    _ = self;
    return .{};
}

//---------------------------------------------------------------
// Helpers used by App and Window

pub fn setTitle(self: *Surface, title: [:0]const u8) void {
    const alloc = self.app.core_app.alloc;
    if (self.title) |v| alloc.free(v);
    self.title = alloc.dupeSentinel(u8, title, 0) catch null;
    self.window.surfaceTitleChanged(self);
}

/// Show or hide this surface (tab switches, minimize). Hidden surfaces
/// tell the core they are occluded so their renderer stops drawing.
pub fn setVisible(self: *Surface, visible: bool) void {
    self.shown = visible;
    _ = c.ShowWindow(self.hwnd, if (visible) c.SW_SHOW else c.SW_HIDE);
    if (!self.core_initialized) return;
    self.core_surface.occlusionCallback(visible) catch |err| {
        log.warn("error in occlusion callback err={}", .{err});
    };
    if (visible) self.core_surface.refreshCallback() catch {};
}

pub fn setMouseShape(self: *Surface, shape: terminal.MouseShape) void {
    const id: usize = switch (shape) {
        .default, .context_menu, .alias, .copy, .cell, .vertical_text => c.IDC_ARROW,
        .text => c.IDC_IBEAM,
        .pointer, .grab, .grabbing => c.IDC_HAND,
        .help => c.IDC_HELP,
        .progress => c.IDC_APPSTARTING,
        .wait => c.IDC_WAIT,
        .crosshair => c.IDC_CROSS,
        .move, .all_scroll => c.IDC_SIZEALL,
        .no_drop, .not_allowed => c.IDC_NO,
        .col_resize, .ew_resize, .e_resize, .w_resize => c.IDC_SIZEWE,
        .row_resize, .ns_resize, .n_resize, .s_resize => c.IDC_SIZENS,
        .nesw_resize, .ne_resize, .sw_resize => c.IDC_SIZENESW,
        .nwse_resize, .nw_resize, .se_resize => c.IDC_SIZENWSE,
        .zoom_in, .zoom_out => c.IDC_ARROW,
    };
    self.cursor = c.LoadCursorW(null, id);
    if (!self.mouse_hidden and self.cursorInClient()) _ = c.SetCursor(self.cursor);
}

pub fn setMouseVisibility(self: *Surface, visible: bool) void {
    self.mouse_hidden = !visible;
    if (self.cursorInClient()) _ = c.SetCursor(if (visible) self.cursor else null);
}

fn cursorInClient(self: *const Surface) bool {
    return self.cursor_pos.x >= 0 and self.cursor_pos.y >= 0 and
        self.cursor_pos.x < @as(f32, @floatFromInt(self.size.width)) and
        self.cursor_pos.y < @as(f32, @floatFromInt(self.size.height));
}

pub fn colorSchemeCallback(self: *Surface, scheme: apprt.ColorScheme) void {
    if (!self.core_initialized) return;
    self.core_surface.colorSchemeCallback(scheme) catch |err| {
        log.warn("error setting color scheme err={}", .{err});
    };
}

fn updateSize(self: *Surface) void {
    var rect: c.RECT = .{};
    _ = c.GetClientRect(self.hwnd, &rect);
    self.size = .{
        .width = @intCast(@max(0, rect.right - rect.left)),
        .height = @intCast(@max(0, rect.bottom - rect.top)),
    };
}

fn updateContentScale(self: *Surface) void {
    const dpi: f32 = @floatFromInt(c.GetDpiForWindow(self.hwnd));
    const scale = if (dpi > 0) dpi / c.USER_DEFAULT_SCREEN_DPI else 1;
    self.content_scale = .{ .x = scale, .y = scale };
}

/// Called by the Window when the monitor DPI changes.
pub fn dpiChanged(self: *Surface) void {
    self.updateContentScale();
    if (!self.core_initialized) return;
    self.core_surface.contentScaleCallback(self.content_scale) catch |err| {
        log.warn("error in content scale callback err={}", .{err});
    };
}

/// The sides whose grip band holds (x, y), in client pixels: the band a
/// drag of that side's divider can start in, the pane's margin on a side
/// that borders a divider, at most split_layout.grip_reach from the edge.
/// The margin is the padding before the first cell and whatever the grid
/// leaves after the last, so the band never takes a click meant for a cell
/// (as GTK's once took the first column's, Ghostty #3020).
pub fn dividerBand(self: *const Surface, x: i32, y: i32) split_layout.Sides {
    if (!self.core_initialized) return .{};
    const parent = c.GetParent(self.hwnd) orelse return .{};
    var outer: c.RECT = .{};
    _ = c.GetClientRect(parent, &outer);
    var r: c.RECT = .{};
    _ = c.GetClientRect(self.hwnd, &r);
    var corners = [2]c.POINT{ .{ .x = 0, .y = 0 }, .{ .x = r.right, .y = r.bottom } };
    _ = c.MapWindowPoints(self.hwnd, parent, &corners, 2);

    const size = self.core_surface.size;
    const grid = size.grid();
    const left: i32 = @intCast(size.padding.left);
    const top: i32 = @intCast(size.padding.top);
    const text_right: i32 = @intCast(size.padding.left + grid.columns * size.cell.width);
    const text_bottom: i32 = @intCast(size.padding.top + grid.rows * size.cell.height);
    const reach = split_layout.grip_reach;
    return .{
        .left = corners[0].x > 0 and x < @min(left, reach),
        .right = corners[1].x < outer.right and x >= @max(text_right, r.right - reach),
        .top = corners[0].y > 0 and y < @min(top, reach),
        .bottom = corners[1].y < outer.bottom and y >= @max(text_bottom, r.bottom - reach),
    };
}

/// Whether an Esc key message is taken for a divider drag (the drag never
/// takes the focus): a press cancels the drag, and that keystroke's
/// auto-repeats and release go nowhere either, so the program never sees
/// half of it. A fresh press ends that, in case the release went elsewhere.
fn escapeTaken(self: *Surface, msg: c.UINT, lparam: c.LPARAM) bool {
    const up = msg == c.WM_KEYUP or msg == c.WM_SYSKEYUP;
    const repeat = !up and c.hiword(lparam) & c.KF_REPEAT != 0;
    if (self.escape_taken) {
        if (up) self.escape_taken = false;
        if (up or repeat) return true;
        self.escape_taken = false;
    }
    if (msg != c.WM_KEYDOWN or repeat) return false;
    const i = self.window.tabIndexOf(self) orelse return false;
    if (!self.window.tabs.items[i].cancelDrag()) return false;
    self.escape_taken = true;
    return true;
}

/// Post WM_FOCUS_CHANGED unless one is already queued; it reports the focus
/// as it is when it runs, so a quick loss and regain is one message.
fn queueFocus(self: *Surface) void {
    if (self.focus_posted) return;
    if (c.PostMessageW(self.hwnd, WM_FOCUS_CHANGED, 0, 0) != 0) self.focus_posted = true;
}

/// Tell the core about the focus if it changed since it last heard.
fn deliverFocus(self: *Surface) void {
    if (!self.core_initialized or self.core_focus == self.has_focus) return;
    self.core_focus = self.has_focus;
    self.core_surface.focusCallback(self.has_focus) catch |err| {
        log.warn("error in focus callback err={}", .{err});
    };
}

//---------------------------------------------------------------
// Window procedure

fn fromHwnd(hwnd: c.HWND) ?*Surface {
    const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (ptr == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(ptr)));
}

fn wndProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (msg == c.WM_NCCREATE) {
        const cs: *const c.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(cs.lpCreateParams)));
        return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const self = fromHwnd(hwnd) orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    if (self.handleMessage(msg, wparam, lparam)) |result| return result;
    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// Returns null to fall through to DefWindowProc.
fn handleMessage(self: *Surface, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) ?c.LRESULT {
    switch (msg) {
        c.WM_ERASEBKGND => return 1,

        c.WM_PAINT => {
            _ = c.ValidateRect(self.hwnd, null);
            if (self.core_initialized) self.core_surface.refreshCallback() catch {};
            return 0;
        },

        c.WM_SIZE => {
            if (wparam == c.SIZE_MINIMIZED) return 0;
            const old = self.size;
            self.updateSize();
            if (self.core_initialized and
                (old.width != self.size.width or old.height != self.size.height))
            {
                self.core_surface.sizeCallback(self.size) catch |err| {
                    log.warn("error in size callback err={}", .{err});
                };
            }
            return 0;
        },

        c.WM_SETFOCUS, c.WM_KILLFOCUS => {
            self.has_focus = msg == c.WM_SETFOCUS;
            // Which surface the app counts as focused (what a new tab or
            // split inherits from) is only a pointer, so it changes at
            // once: a click on "+" in an inactive window is handled before
            // the posted message.
            if (self.has_focus and self.core_initialized) {
                self.app.core_app.focusSurface(&self.core_surface);
            }
            // The tab's focused pane, whose title and colors it shows.
            if (self.has_focus) self.window.surfaceFocused(self);
            self.queueFocus();
            return 0;
        },

        WM_FOCUS_CHANGED => {
            self.focus_posted = false;
            self.deliverFocus();
            return 0;
        },

        c.WM_SETCURSOR => {
            if (c.loword(lparam) == c.HTCLIENT) {
                _ = c.SetCursor(if (self.mouse_hidden) null else self.cursor);
                return 1;
            }
            return null;
        },

        // In the grip band next to a divider the mouse goes to the tab's
        // container, which shows the resize cursor and drags the divider.
        c.WM_NCHITTEST => {
            var pt = [1]c.POINT{.{ .x = c.xParam(lparam), .y = c.yParam(lparam) }};
            _ = c.MapWindowPoints(null, self.hwnd, &pt, 1);
            if (self.dividerBand(pt[0].x, pt[0].y).any()) return c.HTTRANSPARENT;
            return null;
        },

        c.WM_KEYDOWN, c.WM_SYSKEYDOWN, c.WM_KEYUP, c.WM_SYSKEYUP => {
            if (wparam == c.VK_ESCAPE and self.escapeTaken(msg, lparam)) return 0;
            return self.handleKey(msg, wparam, lparam);
        },

        c.WM_CHAR, c.WM_SYSCHAR => {
            // Characters not preceded by a key down we consumed: IME
            // commits, Alt+Numpad entry, and injected text.
            self.handleChar(@truncate(wparam));
            return 0;
        },

        c.WM_UNICHAR => {
            if (wparam == c.UNICODE_NOCHAR) return 1;
            var buf: [4]u8 = undefined;
            const cp = std.math.cast(u21, wparam) orelse return 0;
            const n = std.unicode.utf8Encode(cp, &buf) catch return 0;
            self.sendText(buf[0..n]);
            return 0;
        },

        c.WM_DEADCHAR, c.WM_SYSDEADCHAR => return 0,

        c.WM_IME_STARTCOMPOSITION => {
            self.ime_composing = true;
            self.positionIme();
            return null;
        },

        c.WM_IME_COMPOSITION => {
            if (lparam & c.GCS_COMPSTR != 0) self.updatePreedit();
            self.positionIme();
            // Let DefWindowProc turn the result string into WM_CHARs.
            return null;
        },

        c.WM_IME_ENDCOMPOSITION => {
            self.ime_composing = false;
            if (self.core_initialized) self.core_surface.preeditCallback(null) catch {};
            return null;
        },

        c.WM_MOUSEMOVE => {
            if (!self.tracking_leave) {
                var tme: c.TRACKMOUSEEVENT = .{ .dwFlags = c.TME_LEAVE, .hwndTrack = self.hwnd };
                if (c.TrackMouseEvent(&tme) != 0) self.tracking_leave = true;
            }
            self.followMouse(c.xParam(lparam), c.yParam(lparam), wparam);
            self.cursorPosCallback(@floatFromInt(c.xParam(lparam)), @floatFromInt(c.yParam(lparam)));
            return 0;
        },

        c.WM_MOUSELEAVE => {
            self.tracking_leave = false;
            // Keep reporting while a button is held and we have capture.
            if (self.buttons_down == 0) self.cursorPosCallback(-1, -1);
            return 0;
        },

        c.WM_LBUTTONDOWN => return self.mouseButton(.press, .left, lparam),
        c.WM_LBUTTONUP => return self.mouseButton(.release, .left, lparam),
        c.WM_RBUTTONDOWN => return self.mouseButton(.press, .right, lparam),
        c.WM_RBUTTONUP => return self.mouseButton(.release, .right, lparam),
        c.WM_MBUTTONDOWN => return self.mouseButton(.press, .middle, lparam),
        c.WM_MBUTTONUP => return self.mouseButton(.release, .middle, lparam),
        c.WM_XBUTTONDOWN, c.WM_XBUTTONUP => {
            const button: input.MouseButton = if (c.hiword(wparam) == c.XBUTTON1) .four else .five;
            _ = self.mouseButton(if (msg == c.WM_XBUTTONDOWN) .press else .release, button, lparam);
            return 1; // XBUTTON messages must return TRUE.
        },

        c.WM_CAPTURECHANGED => {
            self.buttons_down = 0;
            return 0;
        },

        c.WM_MOUSEWHEEL, c.WM_MOUSEHWHEEL => {
            if (!self.core_initialized) return 0;
            const delta: i16 = @bitCast(c.hiword(wparam));
            // Precision touchpads deliver fractions of a notch.
            const precision = @rem(delta, c.WHEEL_DELTA) != 0;
            const ticks = @as(f64, @floatFromInt(delta)) / c.WHEEL_DELTA;
            const amount: f64 = if (precision)
                ticks * @as(f64, @floatFromInt(self.core_surface.size.cell.height))
            else
                ticks;
            const xoff: f64, const yoff: f64 = if (msg == c.WM_MOUSEWHEEL)
                .{ 0, amount }
            else
                .{ -amount, 0 };
            self.core_surface.scrollCallback(xoff, yoff, .{ .precision = precision }) catch |err| {
                log.warn("error in scroll callback err={}", .{err});
            };
            return 0;
        },

        WM_CLIPBOARD_CONFIRM => {
            self.runClipboardConfirms();
            return 0;
        },

        else => return null,
    }
}

/// focus-follows-mouse: the mouse moving over the pane focuses it, in the
/// active window only (never raising another window), and not while a
/// button is held, wherever it was pressed (`wparam`'s MK_ flags). Only a
/// real move counts: a pane laid out again under a still cursor (a split, a
/// divider moving) gets WM_MOUSEMOVE too, with new client coordinates but
/// the same screen position (App.mouseMoved).
fn followMouse(self: *Surface, x: i32, y: i32, wparam: c.WPARAM) void {
    const app = self.app;
    if (!app.mouseMoved(self.hwnd, x, y) or !app.config.@"focus-follows-mouse") return;
    const buttons = c.MK_LBUTTON | c.MK_RBUTTON | c.MK_MBUTTON | c.MK_XBUTTON1 | c.MK_XBUTTON2;
    if (self.has_focus or wparam & buttons != 0) return;
    if (c.GetActiveWindow() != self.window.hwnd) return;
    _ = c.SetFocus(self.hwnd);
}

fn cursorPosCallback(self: *Surface, x: f32, y: f32) void {
    if (!self.core_initialized) return;

    // Avoid phantom motion events where the cursor didn't move.
    if (@abs(self.cursor_pos.x - x) < 1 and @abs(self.cursor_pos.y - y) < 1) return;
    self.cursor_pos = .{ .x = x, .y = y };

    self.core_surface.cursorPosCallback(self.cursor_pos, key.currentMods()) catch |err| {
        log.warn("error in cursor pos callback err={}", .{err});
    };
}

fn mouseButton(
    self: *Surface,
    action: input.MouseButtonState,
    button: input.MouseButton,
    lparam: c.LPARAM,
) c.LRESULT {
    // Button messages carry their own position; make sure the core
    // sees the click where it happened.
    self.cursorPosCallback(@floatFromInt(c.xParam(lparam)), @floatFromInt(c.yParam(lparam)));

    const bit: u8 = @as(u8, 1) << @intCast(@intFromEnum(button) & 7);
    switch (action) {
        .press => {
            if (self.buttons_down == 0) _ = c.SetCapture(self.hwnd);
            self.buttons_down |= bit;
            if (c.GetFocus() != self.hwnd) _ = c.SetFocus(self.hwnd);
        },
        .release => {
            self.buttons_down &= ~bit;
            if (self.buttons_down == 0) _ = c.ReleaseCapture();
        },
    }

    if (!self.core_initialized) return 0;
    _ = self.core_surface.mouseButtonCallback(action, button, key.currentMods()) catch |err| {
        log.warn("error in mouse button callback err={}", .{err});
    };
    return 0;
}

/// Handle a key down/up message. Text for a key down is collected from
/// the WM_CHAR messages TranslateMessage queued right behind it, so the
/// core sees one event with both the physical key and its text.
fn handleKey(self: *Surface, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) ?c.LRESULT {
    const vk = wparam;
    const flags = c.hiword(lparam);
    const is_down = msg == c.WM_KEYDOWN or msg == c.WM_SYSKEYDOWN;
    const is_sys = msg == c.WM_SYSKEYDOWN or msg == c.WM_SYSKEYUP;

    // The IME is processing this key; it will send composition messages.
    if (vk == c.VK_PROCESSKEY) return null;

    const mods = key.currentMods();

    // Keep the standard window manager shortcuts working.
    if (is_down and is_sys and mods.alt and !mods.ctrl and (vk == c.VK_F4 or vk == c.VK_SPACE)) {
        return null;
    }

    // Collect the text queued by TranslateMessage for this key.
    var text16: [16]u16 = undefined;
    var text16_len: usize = 0;
    var dead = false;
    if (is_down) {
        // Only take the char messages directly behind this key down:
        // stop at the next key message so we never steal text that
        // belongs to a later key or was posted independently.
        var m: c.MSG = undefined;
        while (c.PeekMessageW(&m, self.hwnd, c.WM_KEYFIRST, c.WM_KEYLAST, c.PM_NOREMOVE) != 0) {
            switch (m.message) {
                c.WM_CHAR, c.WM_SYSCHAR, c.WM_DEADCHAR, c.WM_SYSDEADCHAR => {},
                else => break,
            }
            _ = c.PeekMessageW(&m, self.hwnd, m.message, m.message, c.PM_REMOVE);
            switch (m.message) {
                c.WM_DEADCHAR, c.WM_SYSDEADCHAR => dead = true,
                else => if (text16_len < text16.len) {
                    text16[text16_len] = @truncate(m.wParam);
                    text16_len += 1;
                },
            }
        }
    }

    if (!self.core_initialized) return 0;

    const native = key.nativeKeycode(vk, lparam);
    const scancode = native & 0xFF;
    const action: input.Action = if (!is_down)
        .release
    else if (flags & c.KF_REPEAT != 0)
        .repeat
    else
        .press;

    // Determine the text and which modifiers it consumed. AltGr text is
    // used as-is. With Ctrl or Alt held otherwise, report the text the
    // key makes without them (e.g. "c" for Ctrl+C), as the encoder
    // applies Ctrl and Alt itself.
    var consumed: input.Mods = .{};
    var text_slice: []const u16 = text16[0..text16_len];
    var alt_buf: [8]u16 = undefined;
    if (is_down and !dead) {
        const altgr = key.altGrDown() and text16_len > 0 and !key.isControl(text_slice);
        if (altgr) {
            consumed.ctrl = true;
            consumed.alt = true;
        } else if (mods.ctrl or mods.alt) {
            const n = key.textWithoutCtrlAlt(vk, scancode, &alt_buf);
            text_slice = alt_buf[0..n];
        }
        if (key.isControl(text_slice)) text_slice = &.{};
    } else {
        text_slice = &.{};
    }

    const unshifted = key.unshiftedCodepoint(vk, scancode);
    if (mods.shift and text_slice.len > 0) {
        if (key.firstCodepoint(text_slice)) |cp| {
            if (cp != unshifted) consumed.shift = true;
        }
    }

    var utf8_buf: [64]u8 = undefined;
    const utf8_len = std.unicode.utf16LeToUtf8(&utf8_buf, text_slice) catch 0;

    self.keys_sent +%= 1;
    const effect = self.core_surface.keyCallback(.{
        .action = action,
        .key = key.physicalKey(native),
        .mods = mods,
        .consumed_mods = consumed,
        .composing = dead,
        .utf8 = utf8_buf[0..utf8_len],
        .unshifted_codepoint = unshifted,
    }) catch |err| {
        log.warn("error in key callback err={}", .{err});
        return 0;
    };

    // Unhandled system keys (e.g. Alt+key bindings the core ignores)
    // go to DefWindowProc, except Alt and F10 on their own, which would
    // open the (nonexistent) window menu and steal keyboard focus.
    if (effect == .ignored and is_sys and is_down and vk != c.VK_MENU and vk != c.VK_F10) {
        return null;
    }
    return 0;
}

/// A WM_CHAR that arrived on its own (IME commit, Alt+Numpad, injected
/// text). Surrogate pairs arrive as two messages.
fn handleChar(self: *Surface, unit: u16) void {
    if (std.unicode.utf16IsHighSurrogate(unit)) {
        self.high_surrogate = unit;
        return;
    }

    var units: [2]u16 = undefined;
    const slice: []const u16 = if (std.unicode.utf16IsLowSurrogate(unit)) slice: {
        if (self.high_surrogate == 0) return;
        units = .{ self.high_surrogate, unit };
        break :slice &units;
    } else slice: {
        units[0] = unit;
        break :slice units[0..1];
    };
    self.high_surrogate = 0;

    if (key.isControl(slice)) return;

    var buf: [8]u8 = undefined;
    const n = std.unicode.utf16LeToUtf8(&buf, slice) catch return;
    self.sendText(buf[0..n]);
}

/// Send committed text as a key event with no physical key.
fn sendText(self: *Surface, text: []const u8) void {
    if (!self.core_initialized or text.len == 0) return;
    _ = self.core_surface.keyCallback(.{
        .action = .press,
        .key = .unidentified,
        .mods = .{},
        .consumed_mods = .{},
        .composing = false,
        .utf8 = text,
    }) catch |err| {
        log.warn("error in key callback err={}", .{err});
    };
}

fn updatePreedit(self: *Surface) void {
    if (!self.core_initialized) return;
    const himc = c.ImmGetContext(self.hwnd) orelse return;
    defer _ = c.ImmReleaseContext(self.hwnd, himc);

    var buf16: [256]u16 = undefined;
    const bytes = c.ImmGetCompositionStringW(himc, c.GCS_COMPSTR, &buf16, @sizeOf(@TypeOf(buf16)));
    if (bytes < 0) return;
    const len: usize = @intCast(@divTrunc(bytes, 2));

    var buf8: [1024]u8 = undefined;
    const n = std.unicode.utf16LeToUtf8(&buf8, buf16[0..len]) catch return;
    self.core_surface.preeditCallback(if (n > 0) buf8[0..n] else null) catch |err| {
        log.warn("error in preedit callback err={}", .{err});
    };
}

/// Place the IME composition and candidate windows at the cursor.
fn positionIme(self: *Surface) void {
    if (!self.core_initialized) return;
    const himc = c.ImmGetContext(self.hwnd) orelse return;
    defer _ = c.ImmReleaseContext(self.hwnd, himc);

    // Window coordinates are device pixels, so don't unscale.
    const pos = self.core_surface.imePointScaled(.{ .x = 1, .y = 1 });
    const pt: c.POINT = .{
        .x = @intFromFloat(pos.x),
        .y = @intFromFloat(pos.y),
    };
    _ = c.ImmSetCompositionWindow(himc, &.{ .dwStyle = c.CFS_POINT, .ptCurrentPos = pt });
    _ = c.ImmSetCandidateWindow(himc, &.{
        .dwIndex = 0,
        .dwStyle = c.CFS_CANDIDATEPOS,
        .ptCurrentPos = .{ .x = pt.x, .y = pt.y + @as(c_long, @intFromFloat(pos.height)) },
    });
}

//---------------------------------------------------------------
// Clipboard and dialogs

/// Read CF_UNICODETEXT from the clipboard as UTF-8. Returns null if the
/// clipboard has no text.
fn readClipboardText(alloc: Allocator, hwnd: c.HWND) !?[]u8 {
    if (c.OpenClipboard(hwnd) == 0) return error.ClipboardOpenFailed;
    defer _ = c.CloseClipboard();

    const handle = c.GetClipboardData(c.CF_UNICODETEXT) orelse return null;
    const ptr: [*]const u16 = @ptrCast(@alignCast(c.GlobalLock(handle) orelse return null));
    defer _ = c.GlobalUnlock(handle);

    const max_units = c.GlobalSize(handle) / 2;
    const units = std.mem.sliceTo(ptr[0..max_units], 0);
    return try std.unicode.utf16LeToUtf8Alloc(alloc, units);
}

pub fn writeClipboardText(alloc: Allocator, hwnd: c.HWND, text: []const u8) !void {
    const utf16 = try std.unicode.utf8ToUtf16LeAllocZ(alloc, text);
    defer alloc.free(utf16);

    const bytes = (utf16.len + 1) * 2;
    const handle = c.GlobalAlloc(c.GMEM_MOVEABLE, bytes) orelse return error.OutOfMemory;
    {
        const dst: [*]u16 = @ptrCast(@alignCast(c.GlobalLock(handle) orelse {
            _ = c.GlobalFree(handle);
            return error.OutOfMemory;
        }));
        @memcpy(dst[0 .. utf16.len + 1], utf16[0 .. utf16.len + 1]);
        _ = c.GlobalUnlock(handle);
    }

    // Another program (a clipboard manager, clipboard history) may have the
    // clipboard open for a moment.
    var tries: usize = 0;
    while (c.OpenClipboard(hwnd) == 0) : (tries += 1) {
        if (tries == 5) {
            _ = c.GlobalFree(handle);
            return error.ClipboardOpenFailed;
        }
        c.Sleep(10);
    }
    defer _ = c.CloseClipboard();
    _ = c.EmptyClipboard();
    // On success the system owns the memory.
    if (c.SetClipboardData(c.CF_UNICODETEXT, handle) == null) {
        _ = c.GlobalFree(handle);
        return error.ClipboardWriteFailed;
    }

    // Under the GUI tests, keep what they make us copy out of the user's
    // clipboard history and cloud clipboard.
    if (test_hooks.active()) {
        const format = c.RegisterClipboardFormatW(c.L("ExcludeClipboardContentFromMonitorProcessing"));
        if (format != 0) if (c.GlobalAlloc(c.GMEM_MOVEABLE, 1)) |marker| {
            if (c.SetClipboardData(format, marker) == null) _ = c.GlobalFree(marker);
        };
    }
}

/// Show a message box. Returns true for OK/Yes.
pub fn messageBox(
    alloc: Allocator,
    owner: ?c.HWND,
    text: []const u8,
    caption: []const u8,
    flags: c.UINT,
) bool {
    const text16 = text_util.utf16Lossy(alloc, text) catch return false;
    defer alloc.free(text16);
    const caption16 = text_util.utf16Lossy(alloc, caption) catch return false;
    defer alloc.free(caption16);
    const result = c.MessageBoxW(owner, text16, caption16, flags);
    return result == c.IDOK or result == c.IDYES;
}
