//! The quick terminal (roadmap 5.7): one window that toggle_quick_terminal
//! shows and hides, as GTK's (a layer shell surface) and macOS's, sliding
//! in from an edge of a monitor and out again as macOS's does. It is a
//! topmost, borderless tool window (no taskbar button, no header bar; tabs
//! as any window's), placed and sized per quick-terminal-position, -size
//! and -screen in the monitor's work area, sliding over
//! quick-terminal-animation-duration, and with quick-terminal-autohide
//! hiding when another window takes the keyboard. Hidden, it gives the
//! keyboard back to the window that had it.
const QuickTerminal = @This();

const std = @import("std");
const configpkg = @import("../../config.zig");

const c = @import("c.zig");
const draw = @import("draw.zig");
const Window = @import("Window.zig");

const Position = configpkg.Config.QuickTerminalPosition;
const Size = configpkg.Config.QuickTerminalSize;

/// The window's timer for the slide.
pub const timer_id = 0x5701;
const frame_ms = 10;

/// Logically shown, also while it slides in.
shown: bool = false,
slide: ?Slide = null,
/// The work area it shows in, and that monitor's DPI, chosen as it shows.
work: c.RECT = .{},
dpi: c.UINT = 96,
/// The window that had the keyboard before it showed.
previous: ?c.HWND = null,
/// It had the keyboard as it began to slide in (autohide checks again as
/// the slide ends, having let it be meanwhile).
had_keyboard: bool = false,
/// When autohide last hid it: a toggle right after (the tray's menu, whose
/// click took the keyboard) leaves it hidden rather than bringing it back.
autohidden_at: u64 = 0,
/// +toggle-quick-terminal toggled it: whatever runs that command can bring
/// it back, so it may hide with nothing else to.
ipc_toggled: bool = false,
/// Out of the topmost band while another window's dialog is open
/// (App.beginModal), back in it as the dialog closes.
lowered: bool = false,

const Slide = struct {
    from: c.POINT,
    to: c.POINT,
    start: u64,
    ms: u32,
    hiding: bool,
};

pub const Placement = struct {
    /// Where it shows.
    shown: c.RECT,
    /// Where it slides from and back to: just past the work area's edge on
    /// its side (above it for center, as macOS's).
    hidden: c.RECT,
};

/// The quick terminal's place in `work` at `dpi`, as QuickTerminalSize
/// sizes it: a percentage of the work area (as macOS's visible frame),
/// pixel sizes and the defaults (400 and 800) in DIPs, as GTK's logical
/// pixels and macOS's points. It never exceeds the work area, and is
/// centered across its side.
pub fn place(position: Position, size: Size, work: c.RECT, dpi: c.UINT) Placement {
    const ww: u32 = @intCast(@max(0, work.right - work.left));
    const wh: u32 = @intCast(@max(0, work.bottom - work.top));
    // QuickTerminalSize.calculate's choice of axes and defaults, in pixels.
    const landscape = ww >= wh;
    const dims: [2]u32 = switch (position) {
        .left, .right => .{ axis(size.primary, ww, 400, dpi), axis(size.secondary, wh, null, dpi) },
        .top, .bottom => .{ axis(size.secondary, ww, null, dpi), axis(size.primary, wh, 400, dpi) },
        .center => if (landscape)
            .{ axis(size.primary, ww, 800, dpi), axis(size.secondary, wh, 400, dpi) }
        else
            .{ axis(size.secondary, ww, 400, dpi), axis(size.primary, wh, 800, dpi) },
    };
    const w: c_int = @intCast(@min(ww, dims[0]));
    const h: c_int = @intCast(@min(wh, dims[1]));
    const cx = work.left + @divTrunc(@as(c_int, @intCast(ww)) - w, 2);
    const cy = work.top + @divTrunc(@as(c_int, @intCast(wh)) - h, 2);
    const at: c.POINT = switch (position) {
        .top => .{ .x = cx, .y = work.top },
        .bottom => .{ .x = cx, .y = work.bottom - h },
        .left => .{ .x = work.left, .y = cy },
        .right => .{ .x = work.right - w, .y = cy },
        .center => .{ .x = cx, .y = cy },
    };
    const from: c.POINT = switch (position) {
        .top, .center => .{ .x = at.x, .y = work.top - h },
        .bottom => .{ .x = at.x, .y = work.bottom },
        .left => .{ .x = work.left - w, .y = at.y },
        .right => .{ .x = work.right, .y = at.y },
    };
    return .{ .shown = rectAt(at, w, h), .hidden = rectAt(from, w, h) };
}

/// One side's pixels: a percentage of `px`, pixels as DIPs at `dpi`, else
/// the default in DIPs, or all of `px` (the secondary axis by an edge).
fn axis(size: ?Size.Size, px: u32, default_dip: ?u32, dpi: c.UINT) u32 {
    if (size) |s| return switch (s) {
        .percentage => s.toPixels(px),
        .pixels => |v| fromDip(v, dpi),
    };
    return if (default_dip) |d| fromDip(d, dpi) else px;
}

fn rectAt(p: c.POINT, w: c_int, h: c_int) c.RECT {
    return .{ .left = p.x, .top = p.y, .right = p.x + w, .bottom = p.y + h };
}

fn fromDip(dip: u32, dpi: c.UINT) u32 {
    return @intCast(@min(@as(u64, dip) * dpi / 96, std.math.maxInt(u31)));
}

/// The monitor quick-terminal-screen names: the primary one (Windows' main
/// screen; `macos-menu-bar` is the same here), or the one under the mouse.
fn monitor(screen: configpkg.Config.QuickTerminalScreen) ?c.HMONITOR {
    var pt: c.POINT = .{};
    switch (screen) {
        .main, .@"macos-menu-bar" => return c.MonitorFromPoint(pt, c.MONITOR_DEFAULTTOPRIMARY),
        .mouse => {
            _ = c.GetCursorPos(&pt);
            return c.MonitorFromPoint(pt, c.MONITOR_DEFAULTTONEAREST);
        },
    }
}

/// Choose where it shows now (each time it shows: the mouse's monitor may
/// have changed, or the work area).
pub fn chooseScreen(self: *QuickTerminal, config: *const configpkg.Config) void {
    self.useMonitor(monitor(config.@"quick-terminal-screen") orelse return);
}

fn useMonitor(self: *QuickTerminal, mon: c.HMONITOR) void {
    var mi: c.MONITORINFO = .{};
    if (c.GetMonitorInfoW(mon, &mi) == 0) return;
    self.work = mi.rcWork;
    self.dpi = draw.monitorDpi(mon, 96);
}

pub fn placement(self: *const QuickTerminal, config: *const configpkg.Config) Placement {
    return place(config.@"quick-terminal-position", config.@"quick-terminal-size", self.work, self.dpi);
}

/// Slide in (or back in, if it was sliding out), in front, with the
/// keyboard.
pub fn show(self: *QuickTerminal, window: *Window) void {
    const config = &window.app.config;
    const hwnd = window.hwnd;
    const visible = c.IsWindowVisible(hwnd) != 0;
    if (!self.shown and !visible) {
        self.chooseScreen(config);
        const fg = c.GetForegroundWindow();
        self.previous = if (fg != null and !window.app.ownsWindow(fg.?)) fg else null;
    }
    self.shown = true;
    const p = self.placement(config);
    const from = if (visible) currentOrigin(hwnd) else origin(p.hidden);
    _ = c.SetWindowPos(hwnd, c.HWND_TOPMOST, from.x, from.y, p.shown.right - p.shown.left, p.shown.bottom - p.shown.top, c.SWP_NOACTIVATE);
    self.clip(hwnd);
    _ = c.ShowWindow(hwnd, c.SW_SHOWNA);
    window.present();
    self.had_keyboard = c.GetForegroundWindow() == hwnd;
    self.start(window, from, origin(p.shown), false);
}

/// Slide out, then hide, giving the keyboard back to the window that had
/// it before (if the quick terminal still has it).
pub fn hide(self: *QuickTerminal, window: *Window) void {
    if (!self.shown) return;
    self.shown = false;
    const p = self.placement(&window.app.config);
    self.start(window, currentOrigin(window.hwnd), origin(p.hidden), true);
}

/// quick-terminal-autohide's hide: another window took the keyboard.
pub fn autohide(self: *QuickTerminal, window: *Window) void {
    self.autohidden_at = c.GetTickCount64();
    self.hide(window);
}

/// Whether autohide hid it just now (the click that opened the tray's menu,
/// say): a toggle then means "hide", which is done.
pub fn justAutohidden(self: *const QuickTerminal) bool {
    return !self.shown and c.GetTickCount64() -% self.autohidden_at < 500;
}

/// Put it where it belongs again at once, on the monitor it is on (the
/// config, the DPI or the work area changed).
pub fn replace(self: *QuickTerminal, window: *Window) void {
    if (!self.shown or self.slide != null) return;
    self.useMonitor(c.MonitorFromWindow(window.hwnd, c.MONITOR_DEFAULTTONEAREST) orelse return);
    const p = self.placement(&window.app.config);
    _ = c.SetWindowPos(window.hwnd, null, p.shown.left, p.shown.top, p.shown.right - p.shown.left, p.shown.bottom - p.shown.top, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
}

/// WM_DPICHANGED: whether to take the new DPI. Mid-slide, or placed past
/// the edge to slide from, the window can lie mostly on the neighboring
/// monitor, whose DPI isn't the one it shows at: its panes keep theirs.
/// Settled in its place, the monitor's own DPI changed.
pub fn takesDpi(self: *const QuickTerminal, window: *const Window, dpi: c.UINT) bool {
    if (dpi == self.dpi) return true;
    if (!self.shown or self.slide != null) return false;
    var r: c.RECT = .{};
    _ = c.GetWindowRect(window.hwnd, &r);
    return std.meta.eql(r, self.placement(&window.app.config).shown);
}

fn start(self: *QuickTerminal, window: *Window, from: c.POINT, to: c.POINT, hiding: bool) void {
    const seconds = window.app.config.@"quick-terminal-animation-duration";
    const ms: u32 = if (std.math.isFinite(seconds) and seconds > 0) @intFromFloat(@min(seconds, 10) * 1000) else 0;
    self.slide = .{ .from = from, .to = to, .start = c.GetTickCount64(), .ms = ms, .hiding = hiding };
    if (ms == 0) return self.finish(window);
    _ = c.SetTimer(window.hwnd, timer_id, frame_ms, null);
}

/// A step of the slide (WM_TIMER): eased out sliding in, in sliding out.
pub fn tick(self: *QuickTerminal, window: *Window) void {
    const s = self.slide orelse {
        _ = c.KillTimer(window.hwnd, timer_id);
        return;
    };
    const elapsed: f64 = @floatFromInt(c.GetTickCount64() - s.start);
    const t = @min(1.0, elapsed / @as(f64, @floatFromInt(s.ms)));
    const e = if (s.hiding) t * t * t else 1 - (1 - t) * (1 - t) * (1 - t);
    const x = s.from.x + @as(c_int, @intFromFloat(@round(@as(f64, @floatFromInt(s.to.x - s.from.x)) * e)));
    const y = s.from.y + @as(c_int, @intFromFloat(@round(@as(f64, @floatFromInt(s.to.y - s.from.y)) * e)));
    _ = c.SetWindowPos(window.hwnd, null, x, y, 0, 0, c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE);
    self.clip(window.hwnd);
    if (t >= 1) self.finish(window);
}

fn finish(self: *QuickTerminal, window: *Window) void {
    _ = c.KillTimer(window.hwnd, timer_id);
    const s = self.slide orelse return;
    self.slide = null;
    const hwnd = window.hwnd;
    _ = c.SetWindowPos(hwnd, null, s.to.x, s.to.y, 0, 0, c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE);
    if (!s.hiding) {
        _ = c.SetWindowRgn(hwnd, null, c.TRUE);
        // Another window took the keyboard while it slid in (autohide let
        // it be meanwhile).
        if (self.had_keyboard and window.wantsAutohide() and !window.app.ownsWindow(c.GetForegroundWindow() orelse hwnd)) self.autohide(window);
        return;
    }
    // The keyboard back first: hidden first, Windows would give it to some
    // other window meanwhile.
    if (c.GetForegroundWindow() == hwnd) if (self.previous) |prev| {
        if (c.IsWindow(prev) != 0 and c.IsWindowVisible(prev) != 0) _ = c.SetForegroundWindow(prev);
    };
    self.previous = null;
    _ = c.ShowWindow(hwnd, c.SW_HIDE);
    _ = c.SetWindowRgn(hwnd, null, c.FALSE);
}

/// Show only what lies in the work area while it slides: past the edge it
/// would show on a neighboring monitor, or over the taskbar.
fn clip(self: *const QuickTerminal, hwnd: c.HWND) void {
    var r: c.RECT = .{};
    if (c.GetWindowRect(hwnd, &r) == 0) return;
    const region = c.CreateRectRgn(self.work.left - r.left, self.work.top - r.top, self.work.right - r.left, self.work.bottom - r.top) orelse return;
    // The window owns the region from here.
    if (c.SetWindowRgn(hwnd, region, c.TRUE) == 0) _ = c.DeleteObject(region);
}

fn origin(r: c.RECT) c.POINT {
    return .{ .x = r.left, .y = r.top };
}

fn currentOrigin(hwnd: c.HWND) c.POINT {
    var r: c.RECT = .{};
    _ = c.GetWindowRect(hwnd, &r);
    return origin(r);
}

test "place: edges, sizes in DIPs, never past the work area" {
    const testing = std.testing;
    const work: c.RECT = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1040 };
    // Top, the default: 400 DIP tall across the work area; from above it.
    var p = place(.top, .{}, work, 96);
    try testing.expectEqual(c.RECT{ .left = 0, .top = 0, .right = 1920, .bottom = 400 }, p.shown);
    try testing.expectEqual(c.RECT{ .left = 0, .top = -400, .right = 1920, .bottom = 0 }, p.hidden);
    // At 150%: 600 px.
    p = place(.top, .{}, work, 144);
    try testing.expectEqual(@as(c_int, 600), p.shown.bottom);
    // Bottom, half the height and 800 px wide: centered across.
    p = place(.bottom, .{ .primary = .{ .percentage = 50 }, .secondary = .{ .pixels = 800 } }, work, 96);
    try testing.expectEqual(c.RECT{ .left = 560, .top = 520, .right = 1360, .bottom = 1040 }, p.shown);
    try testing.expectEqual(@as(c_int, 1040), p.hidden.top);
    // Right, 30% wide: from past the right edge.
    p = place(.right, .{ .primary = .{ .percentage = 30 } }, work, 96);
    try testing.expectEqual(c.RECT{ .left = 1344, .top = 0, .right = 1920, .bottom = 1040 }, p.shown);
    try testing.expectEqual(@as(c_int, 1920), p.hidden.left);
    // Center: 800 x 400 in the middle, from above.
    p = place(.center, .{}, work, 96);
    try testing.expectEqual(c.RECT{ .left = 560, .top = 320, .right = 1360, .bottom = 720 }, p.shown);
    try testing.expectEqual(@as(c_int, -400), p.hidden.top);
    // Larger than the work area: cut to it.
    p = place(.left, .{ .primary = .{ .pixels = 5000 } }, work, 96);
    try testing.expectEqual(@as(c_int, 1920), p.shown.right - p.shown.left);
    // A work area off the origin (a second monitor).
    p = place(.top, .{}, .{ .left = 1920, .top = 40, .right = 3840, .bottom = 1080 }, 96);
    try testing.expectEqual(c.RECT{ .left = 1920, .top = 40, .right = 3840, .bottom = 440 }, p.shown);
    // A fractional DPI loses no pixel across, or down a side.
    p = place(.top, .{}, .{ .left = 0, .top = 0, .right = 3840, .bottom = 2100 }, 168);
    try testing.expectEqual(@as(c_int, 3840), p.shown.right);
    p = place(.left, .{}, .{ .left = 0, .top = 0, .right = 2560, .bottom = 1432 }, 144);
    try testing.expectEqual(@as(c_int, 1432), p.shown.bottom);
}
