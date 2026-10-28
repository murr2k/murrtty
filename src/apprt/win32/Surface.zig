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
const unicode = @import("../../unicode/main.zig");
const CoreSurface = @import("../../Surface.zig");

const c = @import("c.zig");
const key = @import("key.zig");
const split_layout = @import("split_layout.zig");
const App = @import("App.zig");
const ContextMenu = @import("ContextMenu.zig");
const Banner = @import("Banner.zig");
const ClipboardDialog = @import("ClipboardDialog.zig");
const cf_html = @import("cf_html.zig");
const draw = @import("draw.zig");
const ipc = @import("ipc.zig");
const taskbar_mod = @import("taskbar.zig");
const KeyState = @import("KeyState.zig");
const DropTarget = @import("DropTarget.zig");
const Overlay = @import("Overlay.zig");
const PaneDrag = @import("PaneDrag.zig");
const Inspector = @import("Inspector.zig");
const input_pane = @import("input_pane.zig");
const Uia = @import("Uia.zig");
const Scrollbar = @import("Scrollbar.zig");
const SearchBox = @import("SearchBox.zig");
const Window = @import("Window.zig");
const test_hooks = @import("test_hooks.zig");
const text_util = @import("text.zig");

const log = std.log.scoped(.win32_surface);

pub const class_name = c.L("MurrttySurface");

/// Private message posted to the surface window: show the queued
/// clipboard confirmations (see clipboard_pending).
const WM_CLIPBOARD_CONFIRM = c.WM_APP + 2;

/// Private message posted to the surface window: tell the core that the
/// keyboard focus changed (see `has_focus`).
const WM_FOCUS_CHANGED = c.WM_APP + 3;

/// Private message posted to the surface window: draw a frame for the
/// shapes over it (see updateOverlay).
const WM_FORCE_FRAME = c.WM_APP + 4;

app: *App,
window: *Window,
hwnd: c.HWND,

/// The core surface. Only valid when `core_initialized` is true.
core_surface: CoreSurface = undefined,
core_initialized: bool = false,

/// The title the program set (OSC 0/2, or set_surface_title), and the
/// user's name for the pane over it (prompt_surface_title).
title: ?[:0]const u8 = null,
title_override: ?[:0]const u8 = null,

/// Whether the bell rang here since the pane last had the keyboard or
/// input (bell-features title: a bell before its tab's title, GTK's).
bell_ringing: bool = false,

/// The terminal's background and foreground as they are now, which the
/// window's caption and tab strip follow: the surface's config's until a
/// program changes them (OSC 10/11) or the config changes.
colors: Colors = .{ .bg = .{ .r = 0, .g = 0, .b = 0 }, .fg = .{ .r = 255, .g = 255, .b = 255 } },

/// The grid size shown while the pane resizes (resize-overlay), and when
/// the core surface started (GetTickCount64), for after-first.
resize_overlay: Overlay = .{},
created_at: u64 = 0,

/// The size a new window would open with for this pane (the core's
/// initial_size, in points, sent again on font size changes), which
/// reset_window_size goes back to, as macOS keeps it per terminal.
initial_size: ?[2]u32 = null,

/// The search box (start_search to end_search).
search: SearchBox = .{},

/// The overlay scrollbar (the core's scrollbar action).
scrollbar: Scrollbar = .{},

/// The status overlays (roadmap 3.6, GTK's): the link under the mouse at a
/// bottom corner, the read-only badge at the top right, the key sequence
/// and tables at the bottom center, the renderer's failure in the middle,
/// and the banner once the program has ended.
link_overlay: Overlay = .{ .position = .@"bottom-left", .margin = 0, .radius = 0 },
readonly_overlay: Overlay = .{ .position = .@"top-right", .margin = 8, .pad_x = 8, .pad_y = 8, .icon = 0xE72E },
key_overlay: Overlay = .{ .position = .@"bottom-center", .margin = 8, .pad_x = 10, .pad_y = 6, .radius = 8, .icon = 0xE765 },
health_overlay: Overlay = .{ .position = .center, .pad_x = 16, .pad_y = 12, .radius = 8, .wrap = true },
banner: Banner = .{},
key_state: KeyState = .{},

content_scale: apprt.ContentScale = .{ .x = 1, .y = 1 },
size: apprt.SurfaceSize = .{ .width = 0, .height = 0 },

/// Whether the pane is shown (setVisible): not in a hidden tab, a
/// minimized window, or behind another pane's zoom.
shown: bool = true,

/// The color (sRGB, alpha) the pane is dimmed with as an unfocused pane of
/// a split tab, or null (Tab.syncDim).
dim_color: ?[4]f32 = null,
/// The shade the window's top bars cast onto the pane, none when it
/// doesn't reach them (Tab.layoutPanes), and the DPI its rows were worked
/// out for.
shade: draw.Shade = .none,
shade_dpi: c.UINT = 0,
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

/// The menu's Notify on Next Command Finish (roadmap 5.3): the next
/// command to finish notifies whatever notify-on-command-finish says, then
/// this clears.
notify_next_command: bool = false,

/// OSC 9;4's progress (roadmap 5.4), as GTK's bar over the pane shows it,
/// or null with none.
progress: ?Progress = null,
/// The bar is in the error color: set by an error report and cleared only
/// by a set, so it outlasts the bar's removal (GTK's `error` class).
progress_err: bool = false,
core_focus: bool = true,
focus_posted: bool = false,
/// A WM_FORCE_FRAME is queued.
frame_posted: bool = false,

/// Clipboard confirmations waiting to be shown, oldest first. They are
/// shown from the message loop, never inside a core callback. The surface
/// owns them, so closing it answers (denies) and frees what is still queued.
clipboard_pending: std.ArrayList(PendingClipboard) = .empty,
/// Files and text dropped on the pane (roadmap 5.8); null if OLE refused.
drop_target: ?*DropTarget = null,
/// The mouse is over its drag handle (roadmap 1.10), which shows then.
handle_hover: bool = false,
/// A dragged pane would go to this side of it (GTK's drop overlay).
drop_dir: ?PaneDrag.Direction = null,
/// The left release after this pane's drag lost the mouse goes nowhere:
/// the terminal never saw its press.
drag_release: bool = false,
/// This pane's terminal inspector window (roadmap 5.12), while open.
inspector: ?*Inspector = null,
/// Its UI Automation element (roadmap 6.4), once a client asked for it.
uia: ?*Uia.Provider = null,

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
    // A UI Automation client may ask for the pane before it is whole.
    errdefer Uia.detach(self);
    self.drop_target = DropTarget.register(app.core_app.alloc, self);
    errdefer if (self.drop_target) |d| d.revoke(self.hwnd);

    self.updateSize();
    self.updateContentScale();

    try app.core_app.addSurface(self);
    errdefer app.core_app.deleteSurface(self);

    var config = try apprt.surface.newConfig(app.core_app, &app.config, context);
    defer config.deinit();
    // An IPC request's command, directory and title (roadmap 5.1), for the
    // first pane created only.
    const overrides = app.ipc_overrides;
    app.ipc_overrides = null;
    if (overrides) |o| try o.apply(&config);
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
    if (overrides) |o| if (o.title) |t| {
        self.title_override = try app.core_app.alloc.dupeSentinel(u8, t, 0);
    };

    // The window may have been resized by an initial_size action
    // while the core surface was initializing.
    self.updateSize();
    self.core_surface.sizeCallback(self.size) catch |err| {
        log.warn("error in size callback err={}", .{err});
    };
    // Shapes given before the renderer existed (the pane is laid out, and
    // so shaded, first).
    if (self.shade != .none or self.dim_color != null) self.updateOverlay();
    self.created_at = c.GetTickCount64();
    if (app.config.@"resize-overlay" == .always) self.showResizeOverlay();

    // Focus gained, or lost, before the core surface existed reaches it
    // now.
    if (self.has_focus) app.core_app.focusSurface(&self.core_surface);
    self.queueFocus();
}

/// The inspector action (roadmap 5.12): toggle, show or hide this pane's
/// inspector window, as GTK's.
pub fn controlInspector(self: *Surface, mode: apprt.action.Inspector) bool {
    if (!self.core_initialized) return false;
    const open = self.inspector != null;
    const want = switch (mode) {
        .toggle => !open,
        .show => true,
        .hide => false,
    };
    if (!want) {
        self.closeInspector();
        return true;
    }
    if (self.inspector) |i| {
        i.present();
        return true;
    }
    self.inspector = Inspector.create(self) catch |err| {
        log.warn("error opening the inspector err={}", .{err});
        return false;
    };
    return true;
}

/// Close its inspector window, if open (its destroy clears `inspector`).
pub fn closeInspector(self: *Surface) void {
    if (self.inspector) |i| i.destroy();
}

/// Closed but kept for undo (roadmap 5.11): its window is the shelf.
pub fn parked(self: *const Surface) bool {
    return self.window.shelf;
}

/// Its program has ended.
pub fn programEnded(self: *const Surface) bool {
    return self.core_initialized and self.core_surface.child_exited;
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
    self.updateOverlay();
}

/// Cast the top bars' shade onto the pane, or none: libadwaita's top bar,
/// which GTK draws over the content below it (roadmap 4.3). Forces a frame
/// if it changes.
pub fn setShade(self: *Surface, shade: draw.Shade) void {
    const dpi = c.GetDpiForWindow(self.hwnd);
    if (std.meta.eql(shade, self.shade) and (shade == .none or dpi == self.shade_dpi)) return;
    self.shade = shade;
    self.shade_dpi = dpi;
    self.updateOverlay();
}

/// Hand the renderer the shapes it draws over the pane's frames (3.0's
/// shape layer): the scrollbar, the dimming over it all, then the top
/// bars' shade, as GTK draws the bars over the content. A frame
/// follows from the message loop (WM_FORCE_FRAME), one for any number of
/// changes before it, and never with the terminal's lock taken here: this
/// runs from WM_SIZE and setting changes, which a cross-process sent
/// message can bring while the core holds that lock (copy-on-select writes
/// the clipboard with it held).
pub fn updateOverlay(self: *Surface) void {
    if (!self.core_initialized) return;
    const api = &self.core_surface.renderer.api;
    var rects: [Shapes.max]Shapes.Rect = undefined;
    var n = self.scrollbar.rects(self, rects[0..2]);
    // Under the dimming and the bars' shade, as GTK's unfocused-split
    // overlay and header bar lie over its progress bar.
    n += self.progressRects(rects[n..]);
    if (self.dim_color) |col| {
        // The whole window, whatever its size later.
        rects[n] = .{
            .x = 0,
            .y = 0,
            .width = std.math.maxInt(i16),
            .height = std.math.maxInt(i16),
            .color = col,
        };
        n += 1;
    }
    n += self.dragRects(rects[n..]);
    const ink = self.shade.color();
    var row: u32 = 0;
    while (row < self.shade.rows(self.shade_dpi) and n < rects.len) : (row += 1) {
        rects[n] = .{
            .x = 0,
            .y = @intCast(row),
            .width = std.math.maxInt(i16),
            .height = 1,
            .color = .{
                @as(f32, @floatFromInt(ink.r)) / 255.0,
                @as(f32, @floatFromInt(ink.g)) / 255.0,
                @as(f32, @floatFromInt(ink.b)) / 255.0,
                self.shade.alpha(self.shade_dpi, row),
            },
        };
        n += 1;
    }
    api.setOverlay(rects[0..n]);
    self.postFrame();
}

/// What GTK's progress bar shows (roadmap 5.4).
pub const Progress = struct {
    /// 0 to 100 (a first report with none is an empty bar, GTK's fraction
    /// 0), or null for a block that moves with each report (GTK's bar
    /// pulses).
    value: ?u8 = 0,
    /// The last report's kind, which the taskbar button shows, as Windows
    /// Terminal does.
    last: enum { normal, err, paused, pulse } = .normal,
    /// The moving block's left edge, as a fraction of the width, and its
    /// direction.
    pulse: f32 = 0,
    forward: bool = true,

    /// GtkProgressBar's: a fifth of the width, a tenth a step.
    const block = 0.2;
    const step = 0.1;

    fn advance(self: *Progress) void {
        // Entering the pulse starts the block at the left, as GTK's
        // act_mode_enter does.
        if (self.value != null) {
            self.value = null;
            self.pulse = 0;
            self.forward = true;
            return;
        }
        if (self.forward) self.pulse += step else self.pulse -= step;
        if (self.pulse >= 1.0 - block) {
            self.pulse = 1.0 - block;
            self.forward = false;
        } else if (self.pulse <= 0) {
            self.pulse = 0;
            self.forward = true;
        }
    }

    /// What the window's taskbar button shows for it.
    pub fn taskbar(self: Progress) taskbar_mod.Progress {
        return switch (self.last) {
            .err => .{ .state = .@"error", .value = self.value orelse 100 },
            .paused => .{ .state = .paused, .value = self.value orelse 100 },
            .pulse => .{ .state = .indeterminate },
            .normal => if (self.value) |v| .{ .state = .normal, .value = v } else .{ .state = .indeterminate },
        };
    }
};

/// The progress report that removes a stalled program's bar goes after
/// this, as GTK's.
const progress_timer_id = 0x5404;
const progress_timeout_ms = 15000;

/// OSC 9;4 (roadmap 5.4): GTK's setProgressReport, for the bar over the
/// pane and the window's taskbar button. progress-style = false shows
/// none.
pub fn setProgress(self: *Surface, report: terminal.osc.Command.ProgressReport) void {
    _ = c.KillTimer(self.hwnd, progress_timer_id);
    if (!self.app.config.@"progress-style" or report.state == .remove) {
        self.progress = null;
    } else {
        var p = self.progress orelse Progress{};
        switch (report.state) {
            .set, .@"error" => {
                const err = report.state == .@"error";
                self.progress_err = err;
                p.last = if (err) .err else .normal;
                if (report.progress) |v| p.value = @min(v, 100) else p.advance();
            },
            .indeterminate => {
                p.last = .pulse;
                p.advance();
            },
            .pause => {
                p.last = .paused;
                if (report.progress) |v| p.value = @min(v, 100);
            },
            .remove => unreachable,
        }
        self.progress = p;
        _ = c.SetTimer(self.hwnd, progress_timer_id, progress_timeout_ms, null);
    }
    self.updateOverlay();
    self.window.syncProgress();
}

/// The progress bar's rectangle at the pane's top (none without progress):
/// libadwaita's `osd` bar, 3 px per 96 DPI over a clear trough, in the
/// accent, or the error color at half opacity as GTK's CSS mixes it.
fn progressRects(self: *const Surface, out: []Shapes.Rect) usize {
    const p = self.progress orelse return 0;
    if (out.len == 0) return 0;
    const width: f32 = @floatFromInt(self.size.width);
    const height = draw.scale(c.GetDpiForWindow(self.hwnd), 3);
    const left: f32, const span: f32 = if (p.value) |v|
        .{ 0, width * @as(f32, @floatFromInt(v)) / 100.0 }
    else
        .{ width * p.pulse, width * Progress.block };
    const dark = self.window.chromeTheme().dark;
    const color: [4]f32 = if (self.progress_err)
        // libadwaita's error_bg_color, mixed half with transparent.
        if (dark) .{ 0xc0.0 / 255.0, 0x1c.0 / 255.0, 0x28.0 / 255.0, 0.5 } else .{ 0xe0.0 / 255.0, 0x1b.0 / 255.0, 0x24.0 / 255.0, 0.5 }
    else
        // accent_bg_color.
        .{ 0x35.0 / 255.0, 0x84.0 / 255.0, 0xe4.0 / 255.0, 1 };
    out[0] = .{
        .x = @intFromFloat(@round(left)),
        .y = 0,
        .width = @intFromFloat(@round(span)),
        .height = height,
        .color = color,
    };
    return 1;
}

const Shapes = renderer.OpenGL.Overlay;

/// The drag handle's band (roadmap 1.10): GTK's, a CenterBox holding a 16
/// px icon along the pane's top.
const handle_dip = 16;

/// Whether the pane has a drag handle: drag-handle `always`, or `auto` while
/// its tab is split (GTK's is-split).
pub fn handleShown(self: *const Surface) bool {
    return switch (self.app.config.@"drag-handle") {
        .always => true,
        .never => false,
        .auto => if (self.window.tabIndexOf(self)) |i| self.window.tabs.items[i].tree.isSplit() else false,
    };
}

fn handleHeight(self: *const Surface) i32 {
    return draw.scale(c.GetDpiForWindow(self.hwnd), handle_dip);
}

/// Whether the client point (`x`, `y`) is on the drag handle.
fn inHandle(self: *const Surface, x: i32, y: i32) bool {
    if (!self.handleShown() or y < 0 or y >= self.handleHeight() or x < 0) return false;
    return x < @as(i32, @intCast(self.size.width)) and !self.scrollbar.takesMouse(self, x);
}

/// Show (or hide) where a dragged pane would go.
pub fn setDropOverlay(self: *Surface, dir: ?PaneDrag.Direction) void {
    if (std.meta.eql(self.drop_dir, dir)) return;
    self.drop_dir = dir;
    self.updateOverlay();
}

pub fn setHandleHover(self: *Surface, hover: bool) void {
    if (self.handle_hover == hover) return;
    self.handle_hover = hover;
    self.updateOverlay();
}

/// The drag handle while the mouse is on it, GTK's: a band of black at 15%
/// with the three dots of view-more-horizontal-symbolic centered in the
/// window's text color (libadwaita's); and over the half a dragged pane
/// would take, the accent at half opacity (GTK's drop overlay).
fn dragRects(self: *const Surface, out: []Shapes.Rect) usize {
    var n: usize = 0;
    const dpi = c.GetDpiForWindow(self.hwnd);
    if (self.handle_hover and self.handleShown() and out.len >= 4) {
        const band = self.handleHeight();
        out[0] = .{ .x = 0, .y = 0, .width = std.math.maxInt(i16), .height = band, .color = .{ 0, 0, 0, 0.15 } };
        const dot = draw.scale(dpi, 3);
        const gap = draw.scale(dpi, 5);
        const cx: i32 = @divTrunc(@as(i32, @intCast(self.size.width)), 2);
        const fg = self.app.chromeTheme().fg;
        const ink: [4]f32 = .{ @as(f32, @floatFromInt(fg.r)) / 255.0, @as(f32, @floatFromInt(fg.g)) / 255.0, @as(f32, @floatFromInt(fg.b)) / 255.0, 1 };
        for (0..3) |i| {
            const offset: i32 = (@as(i32, @intCast(i)) - 1) * gap;
            out[1 + i] = .{ .x = cx + offset - @divTrunc(dot, 2), .y = @divTrunc(band - dot, 2), .width = dot, .height = dot, .color = ink };
        }
        n = 4;
    }
    if (self.drop_dir) |dir| if (n < out.len) {
        const w: i32 = @intCast(self.size.width);
        const h: i32 = @intCast(self.size.height);
        const accent: [4]f32 = .{ 0x35.0 / 255.0, 0x84.0 / 255.0, 0xe4.0 / 255.0, 0.5 };
        out[n] = switch (dir) {
            .left => .{ .x = 0, .y = 0, .width = @divTrunc(w, 2), .height = h, .color = accent },
            .right => .{ .x = @divTrunc(w, 2), .y = 0, .width = w - @divTrunc(w, 2), .height = h, .color = accent },
            .up => .{ .x = 0, .y = 0, .width = w, .height = @divTrunc(h, 2), .color = accent },
            .down => .{ .x = 0, .y = @divTrunc(h, 2), .width = w, .height = h - @divTrunc(h, 2), .color = accent },
        };
        n += 1;
    };
    return n;
}

/// Present the frame with its own alpha (the window is translucent,
/// roadmap 4.1) or over the opaque background, from the next frame.
pub fn setTranslucent(self: *Surface, on: bool) void {
    if (!self.core_initialized) return;
    self.core_surface.renderer.api.wgl_state.transparent.store(on, .monotonic);
    self.postFrame();
}

/// Ask for a frame from the message loop (WM_FORCE_FRAME), once for any
/// number of asks before it runs.
fn postFrame(self: *Surface) void {
    if (self.frame_posted) return;
    if (c.PostMessageW(self.hwnd, WM_FORCE_FRAME, 0, 0) != 0) self.frame_posted = true;
}

/// The window that takes the keyboard when this pane is focused: the pane
/// itself, or an interactive overlay open over it (the search box, roadmap
/// 3.2), so the overlay keeps the focus across window activation.
pub fn focusTarget(self: *Surface) c.HWND {
    return self.search.focusTarget() orelse self.hwnd;
}

/// How long after it starts a pane's size still counts as its first, for
/// resize-overlay = after-first: a new pane settles (the tab bar appears, a
/// split lays out) in its first moments. GTK waits as long.
const resize_overlay_first_ms = 250;

/// Show the grid size over the pane for resize-overlay-duration, as GTK
/// does while a pane resizes.
fn showResizeOverlay(self: *Surface) void {
    if (!self.core_initialized) return;
    const config = &self.app.config;
    switch (config.@"resize-overlay") {
        .never => return,
        .@"after-first" => if (c.GetTickCount64() -| self.created_at < resize_overlay_first_ms) return,
        .always => {},
    }
    const grid = self.core_surface.size.grid();
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d} x {d}", .{ grid.columns, grid.rows }) catch return;
    const o = &self.resize_overlay;
    o.position = config.@"resize-overlay-position";
    const bg = self.colors.bg;
    const fg = self.colors.fg;
    o.bg = c.rgb(mix(bg.r, fg.r), mix(bg.g, fg.g), mix(bg.b, fg.b));
    o.fg = c.rgb(fg.r, fg.g, fg.b);
    // At least a millisecond: 0 would show it until hidden.
    o.show(self.hwnd, text, @max(config.@"resize-overlay-duration".asMilliseconds(), 1));
}

/// 15% of the way from `a` to `b`: a background a little off the
/// terminal's.
fn mix(a: u8, b: u8) u8 {
    const af: f32 = @floatFromInt(a);
    const bf: f32 = @floatFromInt(b);
    return @intFromFloat(@round(af + (bf - af) * 0.15));
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
    const g = self.cellGeometry() orelse return .{};
    const width = g.cell_w * CoreSurface.min_window_width_cells + g.pad_x;
    const height = g.cell_h * CoreSurface.min_window_height_cells + g.pad_y;
    return .{
        .width = @intCast(@min(width, std.math.maxInt(u16))),
        .height = @intCast(@min(height, std.math.maxInt(u16))),
    };
}

/// The pane's cell and its padding (both sides together), in pixels.
pub const CellGeometry = struct { cell_w: u32, cell_h: u32, pad_x: u32, pad_y: u32 };

/// The cell size and padding a size for this pane is made of (layoutMin;
/// window-step-resize): the core's applied padding, or the configured
/// padding when balanced, which grows with the pane.
pub fn cellGeometry(self: *const Surface) ?CellGeometry {
    if (!self.core_initialized) return null;
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
    return .{ .cell_w = cs.size.cell.width, .cell_h = cs.size.cell.height, .pad_x = pad_x, .pad_y = pad_y };
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
    // UI Automation's clients drop the element while the pane is whole.
    Uia.detach(self);
    // Its inspector first, while the core surface it deactivates is here.
    self.closeInspector();
    if (self.core_initialized) PaneDrag.surfaceGone(self.app, self.core_surface.id);
    if (self.drop_target) |d| d.revoke(self.hwnd);
    self.drop_target = null;

    // Answer and free confirmations that were never shown.
    for (self.clipboard_pending.items) |p| self.dropClipboardConfirm(p);
    self.clipboard_pending.deinit(self.app.core_app.alloc);

    if (self.core_initialized) {
        self.core_initialized = false;
        // Nothing left to bring forward.
        self.app.notifications.surfaceDone(self.core_surface.id);
        self.app.core_app.deleteSurface(self);
        self.core_surface.deinit();
    }

    if (self.title) |v| self.app.core_app.alloc.free(v);
    self.title = null;
    if (self.title_override) |v| self.app.core_app.alloc.free(v);
    self.title_override = null;
    self.resize_overlay.deinit();
    self.search.deinit();
    for ([_]*Overlay{ &self.link_overlay, &self.readonly_overlay, &self.key_overlay, &self.health_overlay }) |o| o.deinit();
    self.banner.deinit();
    self.key_state.deinit(self.app.core_app.alloc);
}

//---------------------------------------------------------------
// Status overlays (roadmap 3.6)

/// The overlays' background: the terminal's, a little toward its
/// foreground (as the resize overlay's).
fn overlayColors(self: *const Surface, o: *Overlay) void {
    const bg = self.colors.bg;
    const fg = self.colors.fg;
    o.bg = c.rgb(mix(bg.r, fg.r), mix(bg.g, fg.g), mix(bg.b, fg.b));
    o.fg = c.rgb(fg.r, fg.g, fg.b);
}

/// The core's mouse_over_link: the link under the mouse (link-previews),
/// or none (empty). GTK shows it at the bottom left, and at the bottom
/// right while the mouse is over that spot.
pub fn setLinkPreview(self: *Surface, url: []const u8) void {
    if (url.len == 0) return self.link_overlay.hide();
    self.overlayColors(&self.link_overlay);
    self.link_overlay.position = .@"bottom-left";
    self.link_overlay.show(self.hwnd, url, 0);
    self.linkPreviewFollow(self.cursor_pos.x, self.cursor_pos.y);
}

/// Keep the link preview out from under the mouse at (`x`, `y`).
fn linkPreviewFollow(self: *Surface, x: f32, y: f32) void {
    if (!self.link_overlay.visible()) return;
    const r = self.link_overlay.rect() orelse return;
    var client: c.RECT = .{};
    _ = c.GetClientRect(self.hwnd, &client);
    // Where it shows at the bottom left (it sits on the edges): the same
    // size wherever it is.
    const over = x < @as(f32, @floatFromInt(r.right - r.left)) and
        y >= @as(f32, @floatFromInt(client.bottom - (r.bottom - r.top)));
    self.link_overlay.moveTo(if (over) .@"bottom-right" else .@"bottom-left");
}

/// The core's readonly action: GTK's badge, a lock and "Read-only" at the
/// top right in its tan, while input is held back.
pub fn setReadonly(self: *Surface, on: bool) void {
    if (!on) return self.readonly_overlay.hide();
    const o = &self.readonly_overlay;
    const bg = self.colors.bg;
    o.bg = c.rgb(bg.r, bg.g, bg.b);
    // hsl(25, 50%, 75%), GTK's.
    o.fg = c.rgb(0xdf, 0xba, 0x9f);
    o.border = o.fg;
    o.show(self.hwnd, "Read-only", 0);
}

pub fn readonlyShown(self: *const Surface) bool {
    return self.readonly_overlay.visible();
}

/// The core's key_sequence and key_table actions.
pub fn keySequence(self: *Surface, value: apprt.action.KeySequence) void {
    const alloc = self.app.core_app.alloc;
    switch (value) {
        .trigger => |t| self.key_state.sequenceKey(alloc, t) catch {},
        .end => self.key_state.clearSequence(alloc),
    }
    self.syncKeyOverlay();
}

pub fn keyTable(self: *Surface, value: apprt.action.KeyTable) void {
    const alloc = self.app.core_app.alloc;
    switch (value) {
        .activate => |name| self.key_state.tableActivate(alloc, name) catch {},
        .deactivate => self.key_state.tableDeactivate(alloc),
        .deactivate_all => self.key_state.clearTables(alloc),
    }
    self.syncKeyOverlay();
}

fn syncKeyOverlay(self: *Surface) void {
    if (!self.key_state.active()) return self.key_overlay.hide();
    var buf: [512]u8 = undefined;
    self.overlayColors(&self.key_overlay);
    self.key_overlay.show(self.hwnd, self.key_state.text(&buf), 0);
}

/// The renderer failed (renderer_health), or recovered. GTK shows nothing;
/// this shows macOS's panel.
pub fn setRendererHealth(self: *Surface, health: renderer.Health) void {
    switch (health) {
        .healthy => self.health_overlay.hide(),
        .unhealthy => {
            self.overlayColors(&self.health_overlay);
            self.health_overlay.show(self.hwnd, "Oh, no. The renderer has failed. This is usually due to exhausting available GPU memory. Please free up available resources.", 0);
        },
    }
}

/// The core's show_child_exited: the program ended. GTK's banner across
/// the bottom, "Command Succeeded" or "Command Failed", with Close; the
/// pane stays until it is closed or a key is pressed.
pub fn childExited(self: *Surface, value: apprt.surface.Message.ChildExited) bool {
    const bg = self.colors.bg;
    const fg = self.colors.fg;
    self.banner.on_close = &closeFromBanner;
    self.banner.ctx = self;
    self.banner.show(self.hwnd, value.exit_code, .{ bg.r, bg.g, bg.b }, .{ fg.r, fg.g, fg.b });
    return true;
}

fn closeFromBanner(ctx: *anyopaque) void {
    const self: *Surface = @ptrCast(@alignCast(ctx));
    if (!self.core_initialized) return;
    // From the message loop, as every close.
    self.app.request(.{ .close_surface = .{ .id = self.core_surface.id, .process_active = false } });
}

/// Place the status overlays again (the pane resized), also those of a
/// tab in the background, which isn't laid out again when it comes back.
fn layoutOverlays(self: *Surface) void {
    for ([_]*Overlay{ &self.link_overlay, &self.readonly_overlay, &self.key_overlay, &self.health_overlay }) |o| {
        if (o.shown()) o.layout();
    }
    if (self.banner.shown()) self.banner.layout();
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

/// Whether the pane's window is translucent, which the renderer reads as
/// it starts (setTranslucent changes it later).
pub fn translucent(self: *const Surface) bool {
    return self.window.translucent;
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
    // The system clipboard, and murrtty's own selection clipboard (roadmap
    // 5.9; Windows has no primary selection), for both of the core's
    // selection kinds, as GTK takes both for its primary clipboard.
    return switch (clipboard_type) {
        .standard, .selection, .primary => true,
    };
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

    // An empty selection clipboard has nothing to disclose or paste: a
    // binding with `performable:` passes its key on, as GTK's does.
    if (clipboard_type != .standard and self.app.selection == null) return .unavailable;

    const alloc = self.app.core_app.alloc;
    const text = if (clipboard_type != .standard)
        (if (self.app.selection) |s| try alloc.dupe(u8, s) else null)
    else
        readClipboardText(alloc, self.hwnd) catch |err| {
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

/// Whether the pane's shell is cmd: a drop's paths are quoted for it
/// (roadmap 5.8).
pub fn shellIsCmd(self: *const Surface) bool {
    if (!self.core_initialized) return false;
    return switch (self.core_surface.io.backend) {
        .exec => |*e| e.shellIsCmd(),
    };
}

/// Paste `text` as a paste from the clipboard would (a drop, roadmap 5.8;
/// GTK's Surface.paste): bracketed paste, and paste protection's
/// confirmation, queued for the message loop.
pub fn pasteText(self: *Surface, text: []const u8) void {
    if (!self.core_initialized or text.len == 0) return;
    self.completeClipboard(.{ .paste = .standard }, .{
        .contents = &.{.{ .mime = "text/plain", .data = text }},
        .available = &.{"text/plain"},
    }, text);
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
    /// The clipboard a write goes to.
    target: apprt.Clipboard = .standard,
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
            self.confirmClipboardWrite(t, pending.target);
        }
    }
}

/// GTK's clipboard confirmation over this pane's window, in a modal scope.
/// A remembered answer holds for this split until the configuration is
/// reloaded (the core rebuilds its config then), as GTK's does.
fn askClipboard(self: *Surface, kind: ClipboardDialog.Kind, text: []const u8, can_remember: bool) ClipboardDialog.Answer {
    // Parked for undo (roadmap 5.11): no window to ask over, so no.
    if (self.parked()) return .{};
    var modal = self.app.beginModal(self.window.hwnd, .{});
    defer modal.end();
    return ClipboardDialog.ask(self.app.core_app.alloc, self.window.hwnd, kind, text, can_remember, self.app.chromeTheme().dark);
}

fn confirmClipboardRead(
    self: *Surface,
    req: apprt.ClipboardRequest,
    text: ?[]const u8,
    unsafe: bool,
) void {
    // What the box shows: the clipboard's text, or what a Kitty write
    // would put there: its text, or without any its HTML, since an allowed
    // write puts what the program offered (HTML too, roadmap 6.5).
    const shown: []const u8 = text orelse switch (req) {
        .kitty_write => |k| for (k.contents) |content| {
            if (std.mem.eql(u8, content.mime, "text/plain")) break content.data;
        } else for (k.contents) |content| {
            if (std.mem.eql(u8, content.mime, "text/html")) break content.data;
        } else "",
        else => "",
    };
    const kind: ClipboardDialog.Kind = if (unsafe) .paste else switch (req) {
        .kitty_write => .write,
        else => .read,
    };
    // GTK offers to remember only OSC 52's answers.
    const answer = self.askClipboard(kind, shown, req == .osc_52_read);
    if (answer.remember) self.core_surface.config.clipboard_read = if (answer.allow) .allow else .deny;
    if (!answer.allow) {
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
    // Text and HTML (copy_to_clipboard's mixed and html; roadmap 6.5).
    var text: ?[:0]const u8 = null;
    var html: ?[:0]const u8 = null;
    for (contents) |content| {
        if (text == null and std.mem.eql(u8, content.mime, "text/plain")) text = content.data;
        if (html == null and std.mem.eql(u8, content.mime, "text/html")) html = content.data;
    }

    const alloc = self.app.core_app.alloc;
    if (confirm) {
        // Confirm from the message loop, not inside the core callback. The
        // dialog shows the text, and an allowed write puts only that, as
        // GTK and macOS do.
        const t = text orelse return;
        self.queueClipboardConfirm(.{ .request = null, .text = try alloc.dupe(u8, t), .target = clipboard_type });
        return;
    }

    if (text == null and html == null) return;
    try self.writeTo(clipboard_type, text, html);
}

/// Write `text`, `html` or both to the system clipboard, with GTK's toast,
/// or the text to murrtty's selection clipboard (roadmap 5.9), quietly:
/// GTK's toast is for the system clipboard.
fn writeTo(self: *Surface, clipboard_type: apprt.Clipboard, text: ?[]const u8, html: ?[]const u8) !void {
    if (clipboard_type != .standard) {
        if (text) |t| return self.app.setSelection(t);
        return;
    }
    try writeClipboard(self.app.core_app.alloc, self.hwnd, text, html);
    self.clipboardWritten(if (text) |t| t.len > 0 else html != null);
}

/// GTK's toast for a write to the clipboard (app-notifications's
/// clipboard-copy): "Copied to clipboard", or for nothing, "Cleared
/// clipboard". In the pane's window, whether or not it is in front (a
/// program's OSC 52 write too).
fn clipboardWritten(self: *Surface, copied: bool) void {
    if (!self.app.config.@"app-notifications".@"clipboard-copy") return;
    self.window.showToast(if (copied) "Copied to clipboard" else "Cleared clipboard");
}

/// show_on_screen_keyboard (roadmap 6.5): Windows' touch keyboard, for
/// the pane's window, as GTK asks its input method. Whether it showed.
/// With the test hooks on, the window's input pane is only looked up
/// (GHOSTTY_WIN32_TEST_OSK asks for real).
pub fn showOnScreenKeyboard(self: *Surface) bool {
    const ask: input_pane.Ask = if (test_hooks.recordsOsk(&self.app.test_state)) .none else .show;
    const result = input_pane.request(self.window.hwnd, ask);
    test_hooks.recordOsk(&self.app.test_state, result.hr, result.done);
    if (result.hr < 0) log.warn("no touch keyboard hr=0x{x}", .{@as(u32, @bitCast(result.hr))});
    return if (ask == .none) result.hr >= 0 else result.done;
}

/// Windows' "lines to scroll at a time" (the mouse settings): the rows a
/// wheel notch scrolls, at most a page ("one screen at a time" is
/// WHEEL_PAGESCROLL), none for 0.
fn wheelLines(self: *Surface) f64 {
    var lines: c.UINT = 3;
    if (test_hooks.wheelLines()) |l| {
        lines = l;
    } else if (c.SystemParametersInfoW(c.SPI_GETWHEELSCROLLLINES, 0, &lines, 0) == 0) {
        lines = 3;
    }
    const page: c.UINT = self.core_surface.size.grid().rows;
    return @floatFromInt(@min(lines, page));
}

/// An OSC 52 write the configuration says to ask about (clipboard-write =
/// ask).
fn confirmClipboardWrite(self: *Surface, text: []const u8, target: apprt.Clipboard) void {
    const answer = self.askClipboard(.write, text, true);
    if (answer.remember) self.core_surface.config.clipboard_write = if (answer.allow) .allow else .deny;
    if (!answer.allow) return;

    self.writeTo(target, text, null) catch |err| {
        log.warn("error writing clipboard err={}", .{err});
    };
}

pub fn defaultTermioEnv(self: *Surface) !std.process.Environ.Map {
    _ = self;
    var env = try global.environMap();
    // A murrtty started for a request doesn't pass that on: a murrtty
    // started from its shells would wait for one too.
    _ = env.orderedRemove(ipc.launch_env);
    return env;
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

/// Name the pane over the program's title, or (null, or empty) go back to
/// the program's (GTK's prompt_surface_title).
pub fn setTitleOverride(self: *Surface, title: ?[]const u8) void {
    const alloc = self.app.core_app.alloc;
    if (self.title_override) |v| alloc.free(v);
    self.title_override = null;
    if (title) |t| if (t.len > 0) {
        self.title_override = alloc.dupeSentinel(u8, t, 0) catch null;
    };
    self.window.surfaceTitleChanged(self);
}

/// The bell rang here (ring_bell), GTK's way: in a background tab, a mark
/// on the tab until it is selected, whatever bell-features says; with its
/// `title`, a bell before the tab's title and the caption until the pane
/// gets the keyboard, a key or a click, though not for the pane that has
/// the keyboard now (a shell's bell on Tab completion).
pub fn ringBell(self: *Surface) void {
    const window = self.window;
    if (window.tabIndexOf(self)) |i| {
        if (i != window.active and !window.tabs.items[i].attention) {
            window.tabs.items[i].attention = true;
            window.invalidateTabBar();
        }
    }
    if (!self.app.config.@"bell-features".title or self.has_focus) return;
    self.bell_ringing = true;
    window.surfaceTitleChanged(self);
}

/// The pane got the keyboard or input: the bell is answered.
fn clearBell(self: *Surface) void {
    if (!self.bell_ringing) return;
    self.bell_ringing = false;
    self.window.surfaceTitleChanged(self);
}

/// What the pane is called: the user's name for it, else the program's
/// title (GTK's effective title).
pub fn effectiveTitle(self: *const Surface) ?[:0]const u8 {
    return self.title_override orelse self.title;
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

        // The terminal's menu, owner-drawn (ContextMenu).
        c.WM_MEASUREITEM => return if (ContextMenu.measureItem(lparam)) 1 else null,
        c.WM_DRAWITEM => return if (ContextMenu.drawItem(lparam)) 1 else null,
        c.WM_MENUCHAR => return ContextMenu.menuChar(wparam, lparam),

        c.WM_PAINT => {
            _ = c.ValidateRect(self.hwnd, null);
            if (self.core_initialized) self.core_surface.refreshCallback() catch {};
            return 0;
        },

        c.WM_WINDOWPOSCHANGED => {
            if (comptime test_hooks.enabled) test_hooks.paneMoved(self.app, self.hwnd);
            // DefWindowProc sends WM_SIZE.
            return null;
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
                self.showResizeOverlay();
                // The thumb follows the pane's height, the progress bar its
                // width (and the DPI that came with it).
                if (self.scrollbar.visible() or self.progress != null) self.updateOverlay();
            }
            self.search.layout();
            self.layoutOverlays();
            return 0;
        },

        // UI Automation (roadmap 6.4): the terminal as a text control.
        c.WM_GETOBJECT => return Uia.getObject(self, wparam, lparam),

        c.WM_TIMER => {
            if (wparam == Uia.timer_id) Uia.tick(self);
            if (wparam == Scrollbar.timer_id) self.scrollbar.tick(self);
            if (wparam == PaneDrag.timer_id) PaneDrag.tick(self.app);
            // No report for 15 s: a program that stalled, or left.
            if (wparam == progress_timer_id) self.setProgress(.{ .state = .remove });
            return 0;
        },

        c.WM_SETFOCUS, c.WM_KILLFOCUS => {
            self.has_focus = msg == c.WM_SETFOCUS;
            // The pane, not its search field, now has the keyboard last.
            if (self.has_focus) self.search.field_focused = false;
            if (self.has_focus) self.clearBell();
            // Its notification has been seen (GTK's take them back then).
            if (self.has_focus and self.core_initialized) self.app.notifications.surfaceDone(self.core_surface.id);
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

        WM_FORCE_FRAME => {
            self.frame_posted = false;
            if (self.core_initialized) self.forceFrame();
            return 0;
        },

        c.WM_SETCURSOR => {
            // Over the pane itself; the search box's controls (which ask
            // their parent first) show their own.
            if (c.loword(lparam) == c.HTCLIENT and wparam == @intFromPtr(self.hwnd)) {
                // The arrow over the scrollbar's band.
                var pt = [1]c.POINT{.{ .x = 0, .y = 0 }};
                _ = c.GetCursorPos(&pt[0]);
                _ = c.MapWindowPoints(null, self.hwnd, &pt, 1);
                if (self.scrollbar.takesMouse(self, pt[0].x)) {
                    _ = c.SetCursor(c.LoadCursorW(null, c.IDC_ARROW));
                    return 1;
                }
                // The drag handle's (GTK's "grab").
                if (self.inHandle(pt[0].x, pt[0].y)) {
                    _ = c.SetCursor(c.LoadCursorW(null, c.IDC_SIZEALL));
                    return 1;
                }
                _ = c.SetCursor(if (self.mouse_hidden) null else self.cursor);
                return 1;
            }
            return null;
        },

        // In the grip band next to a divider the mouse goes to the tab's
        // container, which shows the resize cursor and drags the divider.
        c.WM_NCHITTEST => {
            var pt = [1]c.POINT{.{ .x = c.xParam(lparam), .y = c.yParam(lparam) }};
            // The window's top resize band, without decorations (4.4).
            if (self.window.inTopBand(pt[0])) return c.HTTRANSPARENT;
            _ = c.MapWindowPoints(null, self.hwnd, &pt, 1);
            // Except over the scrollbar's band, which lies in the right grip
            // band (the pane's margin) and the bottom one's corner.
            if (self.scrollbar.takesMouse(self, pt[0].x)) return null;
            if (self.dividerBand(pt[0].x, pt[0].y).any()) return c.HTTRANSPARENT;
            return null;
        },

        c.WM_KEYDOWN, c.WM_SYSKEYDOWN, c.WM_KEYUP, c.WM_SYSKEYUP => {
            // Escape cancels a pane's drag; its repeats and release go
            // nowhere, as a divider drag's.
            if (wparam == c.VK_ESCAPE and msg == c.WM_KEYDOWN) if (self.app.pane_drag) |d| if (d.dragging and !d.cancelled) {
                PaneDrag.cancel(self.app);
                self.escape_taken = true;
                return 0;
            };
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

        // murrtty draws the composition itself, in the terminal at the
        // cursor (the core's preedit), as GTK has the terminal draw its
        // input method's preedit: the IME's own composition window would
        // show it a second time beside it. Its candidate window stays.
        c.WM_IME_SETCONTEXT => return c.DefWindowProcW(self.hwnd, msg, wparam, lparam & ~c.ISC_SHOWUICOMPOSITIONWINDOW),

        c.WM_IME_REQUEST => return self.imeRequest(wparam, lparam),

        c.WM_MOUSEMOVE => {
            if (!self.tracking_leave) {
                var tme: c.TRACKMOUSEEVENT = .{ .dwFlags = c.TME_LEAVE, .hwndTrack = self.hwnd };
                if (c.TrackMouseEvent(&tme) != 0) self.tracking_leave = true;
            }
            const x = c.xParam(lparam);
            const y = c.yParam(lparam);
            // A pane's drag (this pane holds the mouse).
            if (self.app.pane_drag != null) {
                var pt: c.POINT = .{ .x = x, .y = y };
                _ = c.ClientToScreen(self.hwnd, &pt);
                PaneDrag.move(self.app, pt);
                return 0;
            }
            // Over the drag handle, which takes the mouse there, as GTK's
            // (its terminal sees the mouse leave, and focus-follows-mouse
            // waits; the move is still recorded for App.syncMouse).
            const on_handle = self.buttons_down == 0 and self.inHandle(x, y);
            self.setHandleHover(on_handle);
            if (on_handle) {
                _ = self.app.mouseMoved(self.hwnd, x, y);
                self.cursorPosCallback(-1, -1);
                return 0;
            }
            self.followMouse(x, y, wparam);
            // The scrollbar takes moves over its band and its drags, unless
            // the terminal is in a drag of its own (a selection).
            const taken = if (self.buttons_down == 0 or self.scrollbar.pressed)
                self.scrollbar.mouseMove(self, x, y)
            else taken: {
                self.scrollbar.show(self);
                break :taken false;
            };
            if (taken) {
                // To the core, the mouse left the terminal.
                self.cursorPosCallback(-1, -1);
                return 0;
            }
            self.cursorPosCallback(@floatFromInt(x), @floatFromInt(y));
            self.linkPreviewFollow(@floatFromInt(x), @floatFromInt(y));
            return 0;
        },

        c.WM_MOUSELEAVE => {
            self.tracking_leave = false;
            if (comptime test_hooks.enabled) if (self.app.test_state.pin_mouse) return 0;
            self.setHandleHover(false);
            self.scrollbar.mouseLeave(self);
            // Keep reporting while a button is held and we have capture.
            if (self.buttons_down == 0) self.cursorPosCallback(-1, -1);
            return 0;
        },

        c.WM_LBUTTONDOWN => {
            self.drag_release = false;
            if (self.buttons_down == 0 and self.scrollbar.mouseDown(self, c.xParam(lparam), c.yParam(lparam))) return 0;
            // The drag handle: a pane's drag (roadmap 1.10).
            if (self.buttons_down == 0 and self.inHandle(c.xParam(lparam), c.yParam(lparam))) {
                var pt: c.POINT = .{ .x = c.xParam(lparam), .y = c.yParam(lparam) };
                _ = c.ClientToScreen(self.hwnd, &pt);
                PaneDrag.begin(self.app, self, pt);
                return 0;
            }
            return self.mouseButton(.press, .left, lparam);
        },
        c.WM_LBUTTONUP => {
            if (self.app.pane_drag != null) {
                PaneDrag.finish(self.app);
                return 0;
            }
            if (self.drag_release) {
                self.drag_release = false;
                return 0;
            }
            if (self.scrollbar.mouseUp(self, c.xParam(lparam))) return 0;
            return self.mouseButton(.release, .left, lparam);
        },
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
            if (self.app.pane_drag) |d| if (self.core_initialized and d.source == self.core_surface.id) {
                PaneDrag.abort(self.app);
                self.drag_release = true;
            };
            self.buttons_down = 0;
            self.scrollbar.captureLost(self);
            return 0;
        },

        c.WM_MOUSEWHEEL, c.WM_MOUSEHWHEEL => {
            if (!self.core_initialized) return 0;
            const delta: i16 = @bitCast(c.hiword(wparam));
            // Precision touchpads deliver fractions of a notch.
            const precision = @rem(delta, c.WHEEL_DELTA) != 0;
            const ticks = @as(f64, @floatFromInt(delta)) / c.WHEEL_DELTA;
            const cell_height: f64 = @floatFromInt(self.core_surface.size.cell.height);
            const xoff: f64, const yoff: f64 = if (msg == c.WM_MOUSEWHEEL) vertical: {
                // A notch scrolls Windows' "lines to scroll at a time" at
                // mouse-scroll-multiplier's defaults (3 a notch, 1 a
                // touchpad's pixel), which scale it (roadmap 6.5). The
                // core multiplies again and truncates to rows, so a third
                // of the lines could come back a hair under a whole row
                // (1 or 4 lines lost one at some cell heights): nudge it,
                // by far less than a row.
                const lines = self.wheelLines();
                if (lines == 0) return 0;
                const amount = if (precision) ticks * lines * cell_height else ticks * lines / 3;
                break :vertical .{ 0, amount * (1 + 1e-9) };
            } else .{ -(if (precision) ticks * cell_height else ticks), 0 };
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
    // Nor away from the pane's own search field.
    if (c.GetFocus()) |f| if (c.IsChild(self.hwnd, f) != 0) return;
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
            // A click answers the bell (GTK's).
            self.clearBell();
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
    const consumed = self.core_surface.mouseButtonCallback(action, button, key.currentMods()) catch |err| consumed: {
        log.warn("error in mouse button callback err={}", .{err});
        break :consumed true;
    };
    // A right press the core leaves alone (it selected the word under the
    // mouse; a program reporting the mouse would have taken it) opens the
    // context menu, on the press as in GTK.
    if (button == .right and action == .press and !consumed and
        self.core_surface.config.right_click_action == .@"context-menu")
    {
        self.contextMenu(c.xParam(lparam), c.yParam(lparam));
    }
    return 0;
}

/// Show the context menu at the client point (`x`, `y`) and perform what
/// was chosen.
fn contextMenu(self: *Surface, x: c_int, y: c_int) void {
    // The menu takes the button's release: let go of the mouse as that
    // release would have.
    const right: u8 = @as(u8, 1) << @intCast(@intFromEnum(input.MouseButton.right) & 7);
    self.buttons_down &= ~right;
    if (self.buttons_down == 0) _ = c.ReleaseCapture();

    var pt: c.POINT = .{ .x = x, .y = y };
    _ = c.ClientToScreen(self.hwnd, &pt);
    const choice = ContextMenu.track(self, pt);

    // The core saw the press; it hears the release now.
    if (self.core_initialized) {
        _ = self.core_surface.mouseButtonCallback(.release, .right, key.currentMods()) catch |err| {
            log.warn("error in mouse button callback err={}", .{err});
        };
    }
    // Performed here, after the menu's loop: closing actions queue their
    // close (App.request), so this surface outlives the call.
    switch (choice orelse return) {
        .action => |a| if (self.core_initialized) {
            _ = self.core_surface.performBindingAction(a) catch |err| {
                log.warn("error performing a context menu action err={}", .{err});
            };
        },
        .notify_next => self.notify_next_command = !self.notify_next_command,
        .about => {},
    }
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
    // It is a keystroke all the same: scroll to the bottom as one does
    // (scroll-to-bottom), or the composition, drawn at the cursor, wouldn't
    // show while the view is scrolled back.
    if (vk == c.VK_PROCESSKEY) {
        if (is_down and self.core_initialized and self.core_surface.config.scroll_to_bottom.keystroke) {
            _ = self.core_surface.performBindingAction(.scroll_to_bottom) catch |err| {
                log.warn("error scrolling for an IME key err={}", .{err});
            };
        }
        return null;
    }

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

    // Determine the text and which modifiers it consumed. AltGr text
    // (also Ctrl+Alt's, key.altGrText) is used as-is. With Ctrl or Alt
    // held otherwise, report the text the key makes without them (e.g.
    // "c" for Ctrl+C), as the encoder applies Ctrl and Alt itself.
    var consumed: input.Mods = .{};
    var text_slice: []const u16 = text16[0..text16_len];
    var alt_buf: [8]u16 = undefined;
    if (is_down and !dead) {
        const altgr = key.altGrText(mods, text_slice);
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

    // The key as a Windows key event, for win32-input-mode (ConPTY asks
    // for it): the character Windows made of it, as its WM_CHAR. Not for a
    // dead key, nor for a key that made more than one code unit (a dead
    // key's leftovers, a surrogate pair), which the core sends as text.
    const win32_event: ?input.KeyEvent.Win32 = if (dead or text16_len > 1) null else .{
        .vk = @truncate(vk),
        .scan_code = @intCast(scancode),
        .char = if (is_down and text16_len == 1) text16[0] else 0,
        .control_state = key.controlKeyState(flags),
        .repeat = @max(1, @as(u16, @truncate(@as(usize, @bitCast(lparam))))),
    };

    // Input answers the bell (GTK's).
    if (action == .press) self.clearBell();
    self.keys_sent +%= 1;
    const effect = self.core_surface.keyCallback(.{
        .action = action,
        .key = key.remapKeypad(key.physicalKey(native), vk),
        .mods = mods,
        .consumed_mods = consumed,
        .composing = dead,
        .utf8 = utf8_buf[0..utf8_len],
        .unshifted_codepoint = unshifted,
        .win32 = win32_event,
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

/// The pane's search field took the keyboard: the pane becomes the window's
/// focused one (what its tab and caption show, what a new tab inherits),
/// as when it takes the keyboard itself, though the core hears that the
/// terminal lost it.
pub fn fieldFocused(self: *Surface) void {
    if (self.core_initialized) self.app.core_app.focusSurface(&self.core_surface);
    self.window.surfaceFocused(self);
}

/// GTK's application accelerators: the bindings that still work while a
/// field has the keyboard (this pane's search box, or the window's command
/// palette). A key down in `field` with Ctrl, Alt or Win held that is bound
/// to one of them runs that action here, and the characters the key queued
/// for the field are dropped; every other key stays the field's. Returns
/// whether it ran.
pub fn fieldShortcut(self: *Surface, field: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) bool {
    if (!self.core_initialized) return false;
    if (msg != c.WM_KEYDOWN and msg != c.WM_SYSKEYDOWN) return false;
    const mods = key.currentMods();
    if (!mods.ctrl and !mods.alt and !mods.super) return false;

    const native = key.nativeKeycode(wparam, lparam);
    const scancode = native & 0xFF;
    var text16: [8]u16 = undefined;
    const n16 = key.textWithoutCtrlAlt(wparam, scancode, &text16);
    var utf8_buf: [32]u8 = undefined;
    const utf8_len = if (key.isControl(text16[0..n16])) 0 else std.unicode.utf16LeToUtf8(&utf8_buf, text16[0..n16]) catch 0;
    var event: input.KeyEvent = .{
        .action = if (c.hiword(lparam) & c.KF_REPEAT != 0) .repeat else .press,
        .key = key.remapKeypad(key.physicalKey(native), wparam),
        .mods = mods,
        .consumed_mods = .{},
        .composing = false,
        .utf8 = utf8_buf[0..utf8_len],
        .unshifted_codepoint = key.unshiftedCodepoint(wparam, scancode),
    };
    // As the core looks keys up (keyEventIsBinding).
    const config = &self.core_surface.config;
    if (config.key_remaps.isRemapped(mods)) event.mods = config.key_remaps.apply(mods);
    const entry = config.keybind.set.getEvent(event) orelse return false;
    const leaf = switch (entry.value_ptr.*) {
        .leader => return false,
        inline .leaf, .leaf_chained => |*l| l.generic(),
    };
    const actions = leaf.actionsSlice();
    if (actions.len == 0 or !isAccelerator(actions[0])) return false;
    // GTK runs the accelerator's own action, not a chain bound with it.
    const action = actions[0];

    var m: c.MSG = undefined;
    while (c.PeekMessageW(&m, field, c.WM_KEYFIRST, c.WM_KEYLAST, c.PM_NOREMOVE) != 0) {
        switch (m.message) {
            c.WM_CHAR, c.WM_SYSCHAR, c.WM_DEADCHAR, c.WM_SYSDEADCHAR => {},
            else => break,
        }
        _ = c.PeekMessageW(&m, field, m.message, m.message, c.PM_REMOVE);
    }
    _ = self.core_surface.performBindingAction(action) catch |err| {
        log.warn("error performing a shortcut from a field err={}", .{err});
    };
    return true;
}

/// The actions GTK gives application accelerators (Application's
/// syncActionAccelerators), whatever their argument.
fn isAccelerator(action: input.Binding.Action) bool {
    return switch (action) {
        .quit,
        .open_config,
        .reload_config,
        .inspector,
        .toggle_command_palette,
        .close_window,
        .new_window,
        .new_tab,
        .close_tab,
        .new_split,
        .copy_to_clipboard,
        .paste_from_clipboard,
        .reset,
        .clear_screen,
        .prompt_surface_title,
        => true,
        else => false,
    };
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

/// Place the IME's windows at the composition: its composition window
/// (hidden while murrtty draws the composition, WM_IME_SETCONTEXT) where
/// the composition starts, and its candidate window below the cursor's
/// row, kept off the composition.
fn positionIme(self: *Surface) void {
    const place = self.imePlace(0) orelse return;
    const himc = c.ImmGetContext(self.hwnd) orelse return;
    defer _ = c.ImmReleaseContext(self.hwnd, himc);
    _ = c.ImmSetCompositionWindow(himc, &.{ .dwStyle = c.CFS_POINT, .ptCurrentPos = .{ .x = place.x, .y = place.top } });
    _ = c.ImmSetCandidateWindow(himc, &place.candidateForm(0));
}

/// Where the composition is drawn, in the pane's client pixels: on the
/// cursor's row from `left` to `right` (one cell with nothing composing),
/// and `x`, where one of its characters starts.
const ImePlace = struct {
    x: c_int,
    top: c_int,
    left: c_int,
    right: c_int,
    height: c_int,

    /// The candidate window below the cursor's row, kept off the
    /// composition (CFS_EXCLUDE: where below doesn't fit, an IME puts it
    /// above).
    fn candidateForm(self: ImePlace, index: u32) c.CANDIDATEFORM {
        return .{
            .dwIndex = index,
            .dwStyle = c.CFS_EXCLUDE,
            .ptCurrentPos = .{ .x = self.left, .y = self.top + self.height },
            .rcArea = .{ .left = self.left, .top = self.top, .right = self.right, .bottom = self.top + self.height },
        };
    }
};

/// Where the composition is drawn, as the renderer draws the core's
/// preedit (`Preedit.range`: from the cursor, shifted left to fit the row,
/// leading characters dropped where it can't), with `x` at the character
/// at UTF-16 offset `char_pos` (the composition's end past it).
fn imePlace(self: *Surface, char_pos: u32) ?ImePlace {
    if (!self.core_initialized) return null;
    const size = self.core_surface.size;
    const cell_w: c_int = @intCast(size.cell.width);
    const pad: c_int = @intCast(size.padding.left);
    const cols = size.grid().columns;
    if (cols == 0 or cell_w == 0) return null;
    // The middle of the cursor cell's bottom, in device pixels.
    const pos = self.core_surface.imePointScaled(.{ .x = 1, .y = 1 });
    const height: c_int = @intFromFloat(pos.height);
    const top: c_int = @as(c_int, @intFromFloat(@round(pos.y))) - height;
    const cursor_left: c_int = @intFromFloat(@round(pos.x - @as(f64, @floatFromInt(cell_w)) / 2));
    const cursor_col: terminal.size.CellCountInt = @intCast(std.math.clamp(@divTrunc(cursor_left - pad, cell_w), 0, @as(c_int, cols) - 1));

    // The composition, as the core keeps it for its preedit (zero-width
    // characters left out), with each character's UTF-16 offset.
    const Codepoint = renderer.State.Preedit.Codepoint;
    var cps: [256]Codepoint = undefined;
    var offsets: [256]u32 = undefined;
    var n: usize = 0;
    if (c.ImmGetContext(self.hwnd)) |himc| {
        defer _ = c.ImmReleaseContext(self.hwnd, himc);
        var units: [256]u16 = undefined;
        const bytes = c.ImmGetCompositionStringW(himc, c.GCS_COMPSTR, &units, @sizeOf(@TypeOf(units)));
        if (bytes > 0) {
            const len: usize = @min(units.len, @as(usize, @intCast(@divTrunc(bytes, 2))));
            var it = std.unicode.Utf16LeIterator.init(units[0..len]);
            while (n < cps.len) {
                const offset: u32 = @intCast(it.i / 2);
                const cp = (it.nextCodepoint() catch break) orelse break;
                const width = unicode.table.get(cp).width;
                if (width <= 0) continue;
                cps[n] = .{ .codepoint = cp, .wide = width >= 2 };
                offsets[n] = offset;
                n += 1;
            }
        }
    }
    const preedit: renderer.State.Preedit = .{ .codepoints = cps[0..n] };
    const range = preedit.range(cursor_col, cols - 1);
    var col: c_int = range.start;
    for (range.cp_offset..n) |i| {
        if (offsets[i] >= char_pos) break;
        col += if (cps[i].wide) 2 else 1;
    }
    const end: c_int = if (n == 0) range.start else range.end;
    return .{
        .x = pad + col * cell_w,
        .top = top,
        .left = pad + @as(c_int, range.start) * cell_w,
        .right = pad + (end + 1) * cell_w,
        .height = height,
    };
}

/// Answer an IME's WM_IME_REQUEST. IMEs built on the Text Services
/// Framework ask where text is rather than read what positionIme set:
/// where a character of the composition is (IMR_QUERYCHARPOSITION, in
/// screen pixels, with its line's height and the pane as the document),
/// and the composition and candidate windows' places. Null for others
/// (DefWindowProc's).
fn imeRequest(self: *Surface, wparam: c.WPARAM, lparam: c.LPARAM) ?c.LRESULT {
    const ptr: usize = @bitCast(lparam);
    if (ptr == 0) return null;
    // The place is worked out only for the requests answered (it takes the
    // terminal's lock for the cursor).
    switch (wparam) {
        c.IMR_QUERYCHARPOSITION => {
            const pos: *c.IMECHARPOSITION = @ptrFromInt(ptr);
            if (pos.dwSize < @sizeOf(c.IMECHARPOSITION)) return null;
            const place = self.imePlace(pos.dwCharPos) orelse return null;
            var pt: c.POINT = .{ .x = place.x, .y = place.top };
            _ = c.ClientToScreen(self.hwnd, &pt);
            var r: c.RECT = .{};
            _ = c.GetClientRect(self.hwnd, &r);
            var corners = [2]c.POINT{ .{ .x = r.left, .y = r.top }, .{ .x = r.right, .y = r.bottom } };
            _ = c.MapWindowPoints(self.hwnd, null, &corners, 2);
            pos.pt = pt;
            pos.cLineHeight = @intCast(place.height);
            pos.rcDocument = .{ .left = corners[0].x, .top = corners[0].y, .right = corners[1].x, .bottom = corners[1].y };
            return 1;
        },
        c.IMR_COMPOSITIONWINDOW => {
            const place = self.imePlace(0) orelse return null;
            const form: *c.COMPOSITIONFORM = @ptrFromInt(ptr);
            form.* = .{ .dwStyle = c.CFS_POINT, .ptCurrentPos = .{ .x = place.x, .y = place.top } };
            return 1;
        },
        c.IMR_CANDIDATEWINDOW => {
            const place = self.imePlace(0) orelse return null;
            const form: *c.CANDIDATEFORM = @ptrFromInt(ptr);
            form.* = place.candidateForm(form.dwIndex);
            return 1;
        },
        else => return null,
    }
}

//---------------------------------------------------------------
// Clipboard and dialogs

/// Open the clipboard for `hwnd`. Another program (a clipboard manager,
/// clipboard history, Remote Desktop's clipboard sync) may have it open for
/// a moment, so try for about 100 ms before giving up: a paste that failed
/// at once lost the paste.
fn openClipboard(hwnd: c.HWND) bool {
    var tries: usize = 0;
    while (c.OpenClipboard(hwnd) == 0) : (tries += 1) {
        if (tries == 10) return false;
        c.Sleep(10);
    }
    return true;
}

/// Read CF_UNICODETEXT from the clipboard as UTF-8. Returns null if the
/// clipboard has no text.
pub fn readClipboardText(alloc: Allocator, hwnd: c.HWND) !?[]u8 {
    if (!openClipboard(hwnd)) return error.ClipboardOpenFailed;
    defer _ = c.CloseClipboard();

    const handle = c.GetClipboardData(c.CF_UNICODETEXT) orelse return null;
    const ptr: [*]const u16 = @ptrCast(@alignCast(c.GlobalLock(handle) orelse return null));
    defer _ = c.GlobalUnlock(handle);

    const max_units = c.GlobalSize(handle) / 2;
    const units = std.mem.sliceTo(ptr[0..max_units], 0);
    return try std.unicode.utf16LeToUtf8Alloc(alloc, units);
}

pub fn writeClipboardText(alloc: Allocator, hwnd: c.HWND, text: []const u8) !void {
    return writeClipboard(alloc, hwnd, text, null);
}

/// Put `text` (CF_UNICODETEXT), `html` (Windows' "HTML Format",
/// cf_html.zig) or both on the clipboard, in place of what it held.
pub fn writeClipboard(alloc: Allocator, hwnd: c.HWND, text: ?[]const u8, html: ?[]const u8) !void {
    var text_mem: ?c.HGLOBAL = null;
    defer if (text_mem) |m| {
        _ = c.GlobalFree(m);
    };
    if (text) |t| {
        const utf16 = try std.unicode.utf8ToUtf16LeAllocZ(alloc, t);
        defer alloc.free(utf16);
        text_mem = try globalCopy(std.mem.sliceAsBytes(utf16[0 .. utf16.len + 1]));
    }
    var html_mem: ?c.HGLOBAL = null;
    defer if (html_mem) |m| {
        _ = c.GlobalFree(m);
    };
    var html_format: c.UINT = 0;
    if (html) |h| {
        html_format = c.RegisterClipboardFormatW(c.L("HTML Format"));
        if (html_format == 0) return error.ClipboardWriteFailed;
        const data = try cf_html.encode(alloc, h);
        defer alloc.free(data);
        html_mem = try globalCopy(data[0 .. data.len + 1]);
    }

    if (!openClipboard(hwnd)) return error.ClipboardOpenFailed;
    defer _ = c.CloseClipboard();
    _ = c.EmptyClipboard();
    // On success the system owns the memory.
    if (text_mem) |m| {
        if (c.SetClipboardData(c.CF_UNICODETEXT, m) == null) return error.ClipboardWriteFailed;
        text_mem = null;
    }
    if (html_mem) |m| {
        if (c.SetClipboardData(html_format, m) == null) return error.ClipboardWriteFailed;
        html_mem = null;
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

/// `bytes` in moveable global memory, as the clipboard takes it.
fn globalCopy(bytes: []const u8) !c.HGLOBAL {
    const handle = c.GlobalAlloc(c.GMEM_MOVEABLE, bytes.len) orelse return error.OutOfMemory;
    const dst: [*]u8 = @ptrCast(c.GlobalLock(handle) orelse {
        _ = c.GlobalFree(handle);
        return error.OutOfMemory;
    });
    @memcpy(dst[0..bytes.len], bytes);
    _ = c.GlobalUnlock(handle);
    return handle;
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
