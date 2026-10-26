//! The scrollbar (roadmap 3.4), after GTK's overlay scrollbar: a thin
//! thumb at the pane's right edge that shows when the pane scrolls or the
//! mouse moves over it, widens (with a faint track) when the mouse is over
//! the band at the edge, and fades out a second after the last of those.
//! It is drawn in the renderer's present pass (OpenGL.setOverlay, 3.0's
//! shape layer), over the grid, so the terminal keeps its width.
//!
//! The core reports the scrollable area (the `scrollbar` action: rows in
//! all, the viewport's first row and its height); dragging the thumb sends
//! `scroll_to_row`, and a click on the track above or below it pages. With
//! no scrollback, as on the alternate screen, there is nothing to show.
//! `scrollbar = never` turns it off; with Windows set to always show
//! scroll bars (Accessibility > Visual effects) it doesn't fade.
//!
//! The Surface owns it and forwards its mouse messages and fade timer.
const Scrollbar = @This();

const std = @import("std");
const c = @import("c.zig");
const terminal = @import("../../terminal/main.zig");
const Surface = @import("Surface.zig");

const log = std.log.scoped(.win32_scrollbar);

/// The pane's timer for fading.
pub const timer_id = 0x5CB0;

/// Metrics in device-independent pixels (GTK's overlay indicator, then its
/// slider when hovered).
const thin_width = 3;
const wide_width = 8;
const thin_margin = 3;
const wide_margin = 2;
/// The band at the right edge where the mouse widens it and it takes clicks.
const band_width = 14;
const min_thumb = 24;
const end_margin = 3;

/// How long it stays after the last scroll or mouse move, then how long
/// it takes to fade, and the step.
const idle_ms = 1000;
const fade_ms = 200;
const fade_step_ms = 33;

/// From the core's scrollbar action: rows in all, the viewport's first row
/// and its height.
total: usize = 0,
offset: usize = 0,
len: usize = 0,
/// Whether the mouse is over the band at the right edge.
hover: bool = false,
/// A press on the band that the scrollbar took, and while it drags the
/// thumb, where the thumb was grabbed (pixels from its top) and the last
/// row sent.
pressed: bool = false,
drag: ?Drag = null,
/// 1 shown, 0 hidden, between while fading.
alpha: f32 = 0,
/// When it last had a reason to show (GetTickCount64).
active_at: u64 = 0,

const Drag = struct { grab: i32, row: usize };

/// Where it draws, in the pane's pixels.
pub const Geometry = struct {
    track: c.RECT,
    thumb: c.RECT,
};

/// Whether there is anything to scroll.
pub fn scrollable(self: *const Scrollbar) bool {
    return self.total > self.len;
}

/// Whether it shows now, for the GUI tests' dump.
pub fn visible(self: *const Scrollbar) bool {
    return self.alpha > 0 and self.scrollable();
}

fn enabled(surface: *const Surface) bool {
    return surface.app.config.scrollbar != .never;
}

/// The core reported the scrollable area.
pub fn update(self: *Scrollbar, surface: *Surface, value: terminal.Scrollbar) void {
    if (value.total == self.total and value.offset == self.offset and value.len == self.len) return;
    self.total = value.total;
    self.offset = value.offset;
    self.len = value.len;
    if (!self.scrollable()) {
        self.reset(surface);
    } else {
        _ = self.wake(surface);
    }
    surface.updateOverlay();
}

/// Show it fully and restart the idle clock. Returns whether that changed
/// how it looks.
fn wake(self: *Scrollbar, surface: *Surface) bool {
    if (!enabled(surface) or !self.scrollable()) return false;
    self.active_at = c.GetTickCount64();
    const was = self.alpha;
    self.alpha = 1;
    if (!surface.app.scrollbars_always) _ = c.SetTimer(surface.hwnd, timer_id, idle_ms, null);
    return was != 1;
}

/// Hide it at once (nothing to scroll, or turned off).
fn reset(self: *Scrollbar, surface: *Surface) void {
    self.alpha = 0;
    self.hover = false;
    if (self.pressed) {
        self.pressed = false;
        self.drag = null;
        if (c.GetCapture() == surface.hwnd) _ = c.ReleaseCapture();
    }
    _ = c.KillTimer(surface.hwnd, timer_id);
}

/// The fade timer.
pub fn tick(self: *Scrollbar, surface: *Surface) void {
    // Kept while the mouse is on it or Windows always shows scroll bars.
    if (self.hover or self.pressed or surface.app.scrollbars_always) {
        self.active_at = c.GetTickCount64();
        if (surface.app.scrollbars_always) {
            _ = c.KillTimer(surface.hwnd, timer_id);
        } else {
            _ = c.SetTimer(surface.hwnd, timer_id, idle_ms, null);
        }
        return;
    }
    const idle = c.GetTickCount64() -| self.active_at;
    if (idle < idle_ms) {
        _ = c.SetTimer(surface.hwnd, timer_id, @intCast(idle_ms - idle), null);
        return;
    }
    const faded: f32 = @as(f32, @floatFromInt(idle - idle_ms)) / fade_ms;
    if (faded >= 1) {
        self.alpha = 0;
        _ = c.KillTimer(surface.hwnd, timer_id);
    } else {
        self.alpha = 1 - faded;
        _ = c.SetTimer(surface.hwnd, timer_id, fade_step_ms, null);
    }
    surface.updateOverlay();
}

/// Windows' "always show scroll bars" changed, or the config did.
pub fn settingsChanged(self: *Scrollbar, surface: *Surface) void {
    if (!enabled(surface)) {
        self.reset(surface);
    } else if (surface.app.scrollbars_always and self.scrollable()) {
        self.alpha = 1;
        _ = c.KillTimer(surface.hwnd, timer_id);
    } else if (self.alpha > 0) {
        _ = self.wake(surface);
    }
    surface.updateOverlay();
}

fn px(v: c_int, dpi: c.UINT) c_int {
    return @intCast(@divTrunc(@as(i64, v) * dpi, c.USER_DEFAULT_SCREEN_DPI));
}

/// Where the track and thumb are, or null with nothing to show.
pub fn geometry(self: *const Scrollbar, surface: *const Surface) ?Geometry {
    if (!self.scrollable()) return null;
    var client: c.RECT = .{};
    _ = c.GetClientRect(surface.hwnd, &client);
    const dpi = c.GetDpiForWindow(surface.hwnd);
    const wide = self.hover or self.pressed;
    const width = px(if (wide) wide_width else thin_width, dpi);
    const right = client.right - px(if (wide) wide_margin else thin_margin, dpi);
    const top = px(end_margin, dpi);
    const track_h: i64 = client.bottom - 2 * top;
    if (track_h <= 0 or right - width <= 0) return null;

    const total: i64 = @intCast(self.total);
    const len: i64 = @intCast(self.len);
    const range = total - len;
    const thumb_h = std.math.clamp(@divTrunc(track_h * len, total), @min(px(min_thumb, dpi), track_h), track_h);
    const travel = track_h - thumb_h;
    const offset: i64 = @min(@as(i64, @intCast(self.offset)), range);
    const thumb_top = top + @divTrunc(travel * offset, range);
    return .{
        .track = .{ .left = right - width, .top = top, .right = right, .bottom = top + @as(c_int, @intCast(track_h)) },
        .thumb = .{
            .left = right - width,
            .top = @intCast(thumb_top),
            .right = right,
            .bottom = @intCast(thumb_top + thumb_h),
        },
    };
}

/// The rectangles to draw over the pane's frames into `out` (the
/// renderer's Overlay.Rect), the track while widened and the thumb, in the
/// terminal's foreground at `alpha`. Returns how many.
pub fn rects(self: *const Scrollbar, surface: *const Surface, out: anytype) usize {
    if (!enabled(surface) or self.alpha <= 0) return 0;
    const g = self.geometry(surface) orelse return 0;
    const fg = surface.colors.fg;
    const rgb = [3]f32{
        @as(f32, @floatFromInt(fg.r)) / 255,
        @as(f32, @floatFromInt(fg.g)) / 255,
        @as(f32, @floatFromInt(fg.b)) / 255,
    };
    var n: usize = 0;
    if (self.hover or self.pressed) {
        out[n] = .{
            .x = g.track.left,
            .y = g.track.top,
            .width = g.track.right - g.track.left,
            .height = g.track.bottom - g.track.top,
            .color = .{ rgb[0], rgb[1], rgb[2], 0.12 * self.alpha },
        };
        n += 1;
    }
    const strength: f32 = if (self.drag != null) 0.8 else if (self.hover) 0.65 else 0.45;
    out[n] = .{
        .x = g.thumb.left,
        .y = g.thumb.top,
        .width = g.thumb.right - g.thumb.left,
        .height = g.thumb.bottom - g.thumb.top,
        .color = .{ rgb[0], rgb[1], rgb[2], strength * self.alpha },
    };
    return n + 1;
}

/// Whether the client point is in the band at the right edge.
fn inBand(self: *const Scrollbar, surface: *const Surface, x: i32) bool {
    _ = self;
    var client: c.RECT = .{};
    _ = c.GetClientRect(surface.hwnd, &client);
    return x >= client.right - px(band_width, c.GetDpiForWindow(surface.hwnd));
}

/// Whether the scrollbar takes the mouse at the client point: over the
/// band while there is something to scroll, or while it drags.
pub fn takesMouse(self: *const Scrollbar, surface: *const Surface, x: i32) bool {
    if (self.pressed) return true;
    return enabled(surface) and self.scrollable() and self.inBand(surface, x);
}

/// The mouse moved over the pane, to the client point (`x`, `y`). It
/// shows the scrollbar, widens it over the band, and drags the thumb.
/// Returns whether the scrollbar takes the move (the core shouldn't see
/// it).
pub fn mouseMove(self: *Scrollbar, surface: *Surface, x: i32, y: i32) bool {
    if (self.drag) |*d| {
        if (self.geometry(surface)) |g| {
            const travel: i64 = (g.track.bottom - g.track.top) - (g.thumb.bottom - g.thumb.top);
            const range: i64 = @intCast(self.total - self.len);
            const top = std.math.clamp(@as(i64, y - d.grab), g.track.top, g.track.top + travel);
            const row: usize = if (travel <= 0) 0 else @intCast(@divTrunc((top - g.track.top) * range + @divTrunc(travel, 2), travel));
            if (row != d.row) {
                d.row = row;
                scrollTo(surface, row);
            }
        }
        return true;
    }
    if (!enabled(surface) or !self.scrollable()) return false;
    const over = self.inBand(surface, x);
    var changed = self.wake(surface);
    if (over != self.hover) {
        self.hover = over;
        changed = true;
    }
    if (changed) surface.updateOverlay();
    return over;
}

/// Show it, as a mouse move does, without taking the move (the terminal
/// is dragging a selection).
pub fn show(self: *Scrollbar, surface: *Surface) void {
    if (self.wake(surface)) surface.updateOverlay();
}

/// The mouse left the pane.
pub fn mouseLeave(self: *Scrollbar, surface: *Surface) void {
    if (!self.hover or self.pressed) return;
    self.hover = false;
    surface.updateOverlay();
}

/// A left press at the client point. On the thumb it starts a drag, on
/// the track above or below it pages. Returns whether the scrollbar took
/// it.
pub fn mouseDown(self: *Scrollbar, surface: *Surface, x: i32, y: i32) bool {
    if (!self.takesMouse(surface, x)) return false;
    self.hover = true;
    _ = self.wake(surface);
    const g = self.geometry(surface) orelse return false;
    self.pressed = true;
    _ = c.SetCapture(surface.hwnd);
    if (y >= g.thumb.top and y < g.thumb.bottom) {
        self.drag = .{ .grab = y - g.thumb.top, .row = self.offset };
    } else {
        const range = self.total - self.len;
        const row = if (y < g.thumb.top) self.offset -| self.len else @min(self.offset + self.len, range);
        scrollTo(surface, row);
    }
    surface.updateOverlay();
    return true;
}

/// A left release. Returns whether it ends a press the scrollbar took.
pub fn mouseUp(self: *Scrollbar, surface: *Surface, x: i32) bool {
    if (!self.pressed) return false;
    self.pressed = false;
    self.drag = null;
    if (c.GetCapture() == surface.hwnd) _ = c.ReleaseCapture();
    self.hover = self.inBand(surface, x);
    _ = self.wake(surface);
    surface.updateOverlay();
    return true;
}

/// Capture went elsewhere mid-press (a dialog, Alt+Tab).
pub fn captureLost(self: *Scrollbar, surface: *Surface) void {
    if (!self.pressed) return;
    self.pressed = false;
    self.drag = null;
    surface.updateOverlay();
}

fn scrollTo(surface: *Surface, row: usize) void {
    if (!surface.core_initialized) return;
    _ = surface.core_surface.performBindingAction(.{ .scroll_to_row = row }) catch |err| {
        log.warn("scrolling failed err={}", .{err});
    };
}
