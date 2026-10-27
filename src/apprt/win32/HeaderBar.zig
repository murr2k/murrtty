//! GTK's header bar as the window's title bar (roadmap 4.3): the split
//! button ("+" and the arrow opening the split menu) at the left, the
//! window's title centered in bold, the tab list's and the main menu's
//! buttons, then the window's buttons, drawn as libadwaita's round window
//! controls (with minimize and maximize, as GTK shows them when the button
//! layout has them). Metrics in DIP from libadwaita's stylesheet: a 46 px
//! title bar, 34 px buttons 6 apart, 7 px at the sides, controls 3 apart.
//!
//! The Window draws it while the window has client-side decorations;
//! between the buttons it is the caption (WM_NCHITTEST), and the window's
//! buttons answer as the caption's would (HTMINBUTTON and the rest).
const HeaderBar = @This();

const std = @import("std");
const c = @import("c.zig");
const draw = @import("draw.zig");
const Hit = @import("TabBar.zig").Hit;

/// Unscaled metrics, in device-independent pixels.
const bar_height = 46;
const pad_x = 7;
const pad_top = 6;
const button = 34;
const spacing = 6;
/// The split button's arrow part.
const arrow_width = 20;
const control_spacing = 3;
const control_circle = 24;
const button_radius = 9;

dpi: c.UINT = c.USER_DEFAULT_SCREEN_DPI,
title_font: ?c.HFONT = null,

pub fn deinit(self: *HeaderBar) void {
    if (self.title_font) |f| _ = c.DeleteObject(f);
    self.title_font = null;
}

/// Recreate the title's font for `dpi`: bold, in `family` if set
/// (window-title-font-family).
pub fn setDpi(self: *HeaderBar, dpi: c.UINT, family: ?[]const u8) void {
    self.dpi = dpi;
    if (self.title_font) |f| _ = c.DeleteObject(f);
    self.title_font = draw.chromeFont(dpi, family, true);
}

fn scale(self: *const HeaderBar, v: c_int) c_int {
    return draw.scale(self.dpi, v);
}

pub fn height(self: *const HeaderBar) c_int {
    return self.scale(bar_height);
}

/// Where the buttons go in a bar `width` pixels wide.
pub const Place = struct {
    new_tab: c.RECT,
    new_tab_menu: c.RECT,
    list: c.RECT,
    menu: c.RECT,
    minimize: c.RECT,
    maximize: c.RECT,
    window_close: c.RECT,
};

pub fn place(self: *const HeaderBar, width: c_int) Place {
    const b = self.scale(button);
    const top = self.scale(pad_top);
    const bottom = top + b;
    const new_tab: c.RECT = .{ .left = self.scale(pad_x), .top = top, .right = self.scale(pad_x) + b, .bottom = bottom };
    const close_right = width - self.scale(pad_x);
    const window_close: c.RECT = .{ .left = close_right - b, .top = top, .right = close_right, .bottom = bottom };
    const maximize_right = window_close.left - self.scale(control_spacing);
    const minimize_right = maximize_right - b - self.scale(control_spacing);
    const menu_right = minimize_right - b - self.scale(spacing);
    const list_right = menu_right - b - self.scale(spacing);
    return .{
        .new_tab = new_tab,
        .new_tab_menu = .{ .left = new_tab.right, .top = top, .right = new_tab.right + self.scale(arrow_width), .bottom = bottom },
        .list = .{ .left = list_right - b, .top = top, .right = list_right, .bottom = bottom },
        .menu = .{ .left = menu_right - b, .top = top, .right = menu_right, .bottom = bottom },
        .minimize = .{ .left = minimize_right - b, .top = top, .right = minimize_right, .bottom = bottom },
        .maximize = .{ .left = maximize_right - b, .top = top, .right = maximize_right, .bottom = bottom },
        .window_close = window_close,
    };
}

/// The item at (`x`, `y`), or `.none` for the caption. A button takes the
/// bar's whole height (a click at the top edge of a maximized window hits
/// it), and close reaches the right edge, as Windows' does.
pub fn hitTest(self: *const HeaderBar, x: c_int, y: c_int, width: c_int) Hit {
    if (y < 0 or y >= self.height() or x < 0 or x >= width) return .none;
    const p = self.place(width);
    const columns = [_]struct { Hit, c.RECT }{
        .{ .new_tab, p.new_tab },
        .{ .new_tab_menu, p.new_tab_menu },
        .{ .list, p.list },
        .{ .menu, p.menu },
        .{ .minimize, p.minimize },
        .{ .maximize, p.maximize },
        .{ .window_close, .{ .left = p.window_close.left, .top = 0, .right = width, .bottom = 0 } },
    };
    for (columns) |col| {
        if (x >= col[1].left and x < col[1].right) return col[0];
    }
    return .none;
}

/// Paint the bar into `hdc` at the top, double buffered. `title` is
/// UTF-16, as the window's caption holds it.
pub fn paint(
    self: *const HeaderBar,
    hdc: c.HDC,
    width: c_int,
    title: []const u16,
    hover: Hit,
    pressed: Hit,
    maximized: bool,
    pal: draw.Palette,
) void {
    const h = self.height();
    const mem = c.CreateCompatibleDC(hdc) orelse return;
    defer _ = c.DeleteDC(mem);
    const bmp = c.CreateCompatibleBitmap(hdc, width, h) orelse return;
    defer _ = c.DeleteObject(bmp);
    const old_bmp = c.SelectObject(mem, bmp);
    defer _ = c.SelectObject(mem, old_bmp);
    _ = c.SetBkMode(mem, c.TRANSPARENT);

    draw.fill(mem, .{ .right = width, .bottom = h }, pal.bar);
    // libadwaita's shade under the bar.
    draw.fill(mem, .{ .top = h - 1, .right = width, .bottom = h }, pal.shade);

    const p = self.place(width);
    const pen_w = @max(1, self.scale(1));
    const stroke = @max(1, self.scale(2));
    const half = self.scale(7);

    // New tab: tab-new, a rounded square holding a plus.
    self.buttonBack(mem, p.new_tab, state(.new_tab, hover, pressed), pal);
    var cx = @divTrunc(p.new_tab.left + p.new_tab.right, 2);
    var cy = @divTrunc(p.new_tab.top + p.new_tab.bottom, 2);
    draw.roundRect(mem, .{ .left = cx - half, .top = cy - half, .right = cx + half + 1, .bottom = cy + half + 1 }, self.scale(3), null, pal.text, stroke);
    const arm = self.scale(3);
    draw.line(mem, cx - arm, cy, cx + arm + 1, cy, pal.text, stroke);
    draw.line(mem, cx, cy - arm, cx, cy + arm + 1, pal.text, stroke);

    // Its arrow: pan-down, a filled triangle, past a thin divider (GTK's
    // split button).
    self.buttonBack(mem, p.new_tab_menu, state(.new_tab_menu, hover, pressed), pal);
    const inset = self.scale(9);
    draw.line(mem, p.new_tab_menu.left, p.new_tab_menu.top + inset, p.new_tab_menu.left, p.new_tab_menu.bottom - inset, pal.separator, pen_w);
    cx = @divTrunc(p.new_tab_menu.left + p.new_tab_menu.right, 2);
    cy = @divTrunc(p.new_tab_menu.top + p.new_tab_menu.bottom, 2);
    const tw = self.scale(4);
    draw.triangleDown(mem, cx, cy, tw, @divTrunc(tw + 1, 2) + 1, pal.text);

    // The tab list's button: view-grid, four squares (GTK's overview).
    self.buttonBack(mem, p.list, state(.list, hover, pressed), pal);
    cx = @divTrunc(p.list.left + p.list.right, 2);
    cy = @divTrunc(p.list.top + p.list.bottom, 2);
    const cell = self.scale(6);
    const gap = self.scale(2);
    for ([_]c_int{ -1, 1 }) |sy| for ([_]c_int{ -1, 1 }) |sx| {
        const left = if (sx < 0) cx - @divTrunc(gap, 2) - cell else cx + gap - @divTrunc(gap, 2);
        const top = if (sy < 0) cy - @divTrunc(gap, 2) - cell else cy + gap - @divTrunc(gap, 2);
        draw.roundRect(mem, .{ .left = left, .top = top, .right = left + cell, .bottom = top + cell }, @max(1, self.scale(1)), pal.text, null, 0);
    };

    // The main menu's button: open-menu, three lines.
    self.buttonBack(mem, p.menu, state(.menu, hover, pressed), pal);
    cx = @divTrunc(p.menu.left + p.menu.right, 2);
    cy = @divTrunc(p.menu.top + p.menu.bottom, 2);
    const step = self.scale(5);
    for ([_]c_int{ cy - step, cy, cy + step }) |y| {
        draw.line(mem, cx - half + 1, y, cx + half, y, pal.text, stroke);
    }

    // The window's buttons: libadwaita's round controls.
    for ([_]struct { Hit, c.RECT }{
        .{ .minimize, p.minimize },
        .{ .maximize, p.maximize },
        .{ .window_close, p.window_close },
    }) |control| {
        const r = control[1];
        cx = @divTrunc(r.left + r.right, 2);
        cy = @divTrunc(r.top + r.bottom, 2);
        const radius = @divTrunc(self.scale(control_circle), 2);
        const back = switch (state(control[0], hover, pressed)) {
            .normal => pal.control,
            .hover => pal.control_hover,
            .pressed => pal.control_pressed,
        };
        draw.roundRect(mem, .{ .left = cx - radius, .top = cy - radius, .right = cx + radius, .bottom = cy + radius }, radius, back, null, 0);
        const g = self.scale(4);
        switch (control[0]) {
            // window-minimize: a line low in the circle.
            .minimize => draw.line(mem, cx - g, cy + self.scale(2), cx + g + 1, cy + self.scale(2), pal.text, stroke),
            // window-maximize, or window-restore when maximized.
            .maximize => if (maximized) {
                const s = self.scale(3);
                draw.roundRect(mem, .{ .left = cx - g, .top = cy - g + s, .right = cx + g - s + 1, .bottom = cy + g + 1 }, 0, null, pal.text, pen_w);
                draw.line(mem, cx - g + s, cy - g, cx + g, cy - g, pal.text, pen_w);
                draw.line(mem, cx + g, cy - g, cx + g, cy + g - s, pal.text, pen_w);
            } else {
                draw.roundRect(mem, .{ .left = cx - g, .top = cy - g, .right = cx + g + 1, .bottom = cy + g + 1 }, @max(1, self.scale(1)), null, pal.text, pen_w);
            },
            // window-close: an X.
            else => {
                draw.line(mem, cx - g, cy - g, cx + g + 1, cy + g + 1, pal.text, stroke);
                draw.line(mem, cx + g, cy - g, cx - g - 1, cy + g + 1, pal.text, stroke);
            },
        }
    }

    // The title, bold, centered on the bar, between the buttons.
    if (title.len > 0) {
        const old_font = if (self.title_font) |f| c.SelectObject(mem, f) else null;
        defer if (old_font) |f| {
            _ = c.SelectObject(mem, f);
        };
        const lo = p.new_tab_menu.right + self.scale(spacing + 12);
        const hi = p.list.left - self.scale(spacing + 12);
        if (hi > lo) {
            var measure: c.RECT = .{ .right = hi - lo, .bottom = h };
            _ = c.DrawTextW(mem, title.ptr, @intCast(title.len), &measure, c.DT_SINGLELINE | c.DT_CALCRECT | c.DT_NOPREFIX);
            const tw_px = @min(measure.right - measure.left, hi - lo);
            const left = std.math.clamp(@divTrunc(width - tw_px, 2), lo, hi - tw_px);
            var rect: c.RECT = .{ .left = left, .top = 0, .right = left + tw_px, .bottom = h };
            _ = c.SetTextColor(mem, pal.text);
            _ = c.DrawTextW(mem, title.ptr, @intCast(title.len), &rect, c.DT_SINGLELINE | c.DT_VCENTER | c.DT_END_ELLIPSIS | c.DT_NOPREFIX);
        }
    }

    _ = c.BitBlt(hdc, 0, 0, width, h, mem, 0, 0, c.SRCCOPY);
}

const State = enum { normal, hover, pressed };

fn state(item: Hit, hover: Hit, pressed: Hit) State {
    if (pressed.eql(item)) return .pressed;
    if (hover.eql(item)) return .hover;
    return .normal;
}

/// A button's background: the bar, and a rounded highlight when hovered or
/// pressed (libadwaita's flat button).
fn buttonBack(self: *const HeaderBar, hdc: c.HDC, r: c.RECT, s: State, pal: draw.Palette) void {
    draw.fill(hdc, r, pal.bar);
    const color = switch (s) {
        .normal => return,
        .hover => pal.hover,
        .pressed => pal.pressed,
    };
    draw.roundRect(hdc, r, self.scale(button_radius), color, null, 0);
}

test "hitTest: the buttons, the caption between them, close to the edge" {
    const testing = std.testing;
    const bar: HeaderBar = .{};
    const width = 1000;
    const p = bar.place(width);
    try testing.expectEqual(Hit.new_tab, bar.hitTest(p.new_tab.left + 2, 20, width));
    try testing.expectEqual(Hit.new_tab_menu, bar.hitTest(p.new_tab_menu.left + 2, 20, width));
    try testing.expectEqual(Hit.list, bar.hitTest(p.list.left + 2, 20, width));
    try testing.expectEqual(Hit.menu, bar.hitTest(p.menu.left + 2, 20, width));
    try testing.expectEqual(Hit.minimize, bar.hitTest(p.minimize.left + 2, 20, width));
    try testing.expectEqual(Hit.maximize, bar.hitTest(p.maximize.left + 2, 20, width));
    try testing.expectEqual(Hit.window_close, bar.hitTest(p.window_close.left + 2, 20, width));
    // The bar's top edge and the right edge still hit close.
    try testing.expectEqual(Hit.window_close, bar.hitTest(width - 1, 0, width));
    // Between the buttons: the caption.
    try testing.expectEqual(Hit.none, bar.hitTest(width / 2, 20, width));
    try testing.expectEqual(Hit.none, bar.hitTest(width / 2, bar_height, width));
    // Left to right, no overlaps.
    try testing.expect(p.new_tab_menu.left >= p.new_tab.right);
    try testing.expect(p.list.right <= p.menu.left and p.menu.right <= p.minimize.left);
    try testing.expect(p.minimize.right <= p.maximize.left and p.maximize.right <= p.window_close.left);
}
