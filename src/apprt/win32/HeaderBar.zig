//! GTK's header bar as the window's title bar (roadmap 4.3): the split
//! button ("+" and the arrow opening the split menu) at the left, the
//! window's title centered in bold, the tab list's and the main menu's
//! buttons, then the window's buttons, drawn as libadwaita's round window
//! controls (with minimize and maximize, as GTK shows them when the button
//! layout has them).
//!
//! Geometry and glyphs as measured on the GTK app at 96 DPI (a headless
//! reference capture, roadmap 4.3 step 4), in DIP: a 46 px bar, 34 px
//! buttons 6 px from its edges and 6 px from the window's buttons, the tab
//! list and menu buttons side by side (GTK's box has no spacing), the
//! split arrow 21 px wide past a 22 px divider, the controls 3 apart with
//! 24 px circles. Icons are GTK's symbolic ones on their 16 px grid, drawn
//! as filled shapes so they land on whole pixels.
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
const pad_x = 6;
const pad_top = 6;
const button = 34;
const spacing = 6;
/// The split button's arrow part.
const arrow_width = 21;
const control_spacing = 3;
const control_circle = 24;
const button_radius = 9;
/// Where a 16 px icon sits in a 34 px button.
const icon_inset = 9;

dpi: c.UINT = c.USER_DEFAULT_SCREEN_DPI,
title_font: ?c.HFONT = null,
/// gtk-titlebar-style = tabs: the buttons go in the tab row, which is the
/// title bar (GTK's tab bar then holds the split button at its start and
/// the tab list's and menu's buttons and the window's at its end, those
/// side by side), and the tabs take the title's place.
tabs_style: bool = false,
/// Whether the window's buttons show (client-side decorations).
controls: bool = true,

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
    const end = width - self.scale(pad_x);
    // Without the window's buttons, theirs are empty at the end.
    const none: c.RECT = .{ .left = width, .top = top, .right = width, .bottom = bottom };
    const window_close: c.RECT = if (self.controls) .{ .left = end - b, .top = top, .right = end, .bottom = bottom } else none;
    const maximize_right = window_close.left - self.scale(control_spacing);
    const minimize_right = maximize_right - b - self.scale(control_spacing);
    const menu_right = if (!self.controls)
        end
    else if (self.tabs_style)
        minimize_right - b
    else
        minimize_right - b - self.scale(spacing);
    const list_right = menu_right - b;
    return .{
        .new_tab = new_tab,
        .new_tab_menu = .{ .left = new_tab.right, .top = top, .right = new_tab.right + self.scale(arrow_width), .bottom = bottom },
        .list = .{ .left = list_right - b, .top = top, .right = list_right, .bottom = bottom },
        .menu = .{ .left = menu_right - b, .top = top, .right = menu_right, .bottom = bottom },
        .minimize = if (self.controls) .{ .left = minimize_right - b, .top = top, .right = minimize_right, .bottom = bottom } else none,
        .maximize = if (self.controls) .{ .left = maximize_right - b, .top = top, .right = maximize_right, .bottom = bottom } else none,
        .window_close = window_close,
    };
}

/// With tabs_style, where the tabs go: their span's distance from the
/// row's left and right edges (between the split button and the tab
/// list's button, unpadded, as GTK's).
pub fn tabsInset(self: *const HeaderBar) [2]c_int {
    const p = self.place(0);
    return .{ p.new_tab_menu.right, -p.list.left };
}

/// The narrowest bar that holds its buttons apart: the split button, then
/// GTK's spacing (or, in the tab row, room for a tab at its narrowest),
/// then the buttons at the right (their place doesn't depend on the
/// width). The title ellipsizes to nothing between.
pub fn minWidth(self: *const HeaderBar) c_int {
    const inset = self.tabsInset();
    return inset[0] + inset[1] + self.scale(if (self.tabs_style) min_tab else spacing);
}

/// The narrowest tab (TabBar's).
const min_tab = 64;

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

/// A glyph drawn on a grid of `unit`-DIP cells from an origin, scaled.
const Glyph = struct {
    bar: *const HeaderBar,
    hdc: c.HDC,
    x: c_int,
    y: c_int,
    color: c.COLORREF,

    /// The rectangle from (x0, y0) to (x1, y1) of the grid, scaled.
    fn rect(g: Glyph, x0: c_int, y0: c_int, x1: c_int, y1: c_int) c.RECT {
        return .{
            .left = g.x + g.bar.scale(x0),
            .top = g.y + g.bar.scale(y0),
            .right = g.x + g.bar.scale(x1),
            .bottom = g.y + g.bar.scale(y1),
        };
    }

    fn fill(g: Glyph, x0: c_int, y0: c_int, x1: c_int, y1: c_int) void {
        draw.fill(g.hdc, g.rect(x0, y0, x1, y1), g.color);
    }

    /// An outlined square, `stroke` thick, with rounded corners.
    fn outline(g: Glyph, x0: c_int, y0: c_int, x1: c_int, y1: c_int, stroke: c_int, radius: c_int, back: c.COLORREF) void {
        draw.roundRect(g.hdc, g.rect(x0, y0, x1, y1), g.bar.scale(radius), g.color, null, 0);
        const inner = g.rect(x0 + stroke, y0 + stroke, x1 - stroke, y1 - stroke);
        if (radius > stroke) {
            draw.roundRect(g.hdc, inner, g.bar.scale(radius - stroke), back, null, 0);
        } else {
            draw.fill(g.hdc, inner, back);
        }
    }
};

/// Paint the bar into `hdc` at the top, `h` pixels tall (its own height,
/// or the tab row's with tabs_style, whose tabs are then painted over the
/// span between the buttons), double buffered. `title` is UTF-16, as the
/// window's caption holds it; with tabs_style the tabs take its place.
pub fn paint(
    self: *const HeaderBar,
    hdc: c.HDC,
    width: c_int,
    h: c_int,
    title: []const u16,
    hover: Hit,
    pressed: Hit,
    maximized: bool,
    pal: draw.Palette,
) void {
    const mem = c.CreateCompatibleDC(hdc) orelse return;
    defer _ = c.DeleteDC(mem);
    const bmp = c.CreateCompatibleBitmap(hdc, width, h) orelse return;
    defer _ = c.DeleteObject(bmp);
    const old_bmp = c.SelectObject(mem, bmp);
    defer _ = c.SelectObject(mem, old_bmp);
    _ = c.SetBkMode(mem, c.TRANSPARENT);

    // The shade below falls on the content (Surface.setShade).
    draw.fill(mem, .{ .right = width, .bottom = h }, pal.bar);

    const p = self.place(width);
    const inset = self.scale(icon_inset);

    // New tab: tab-new, a rounded square holding a plus.
    var back = self.buttonBack(mem, p.new_tab, state(.new_tab, hover, pressed), pal);
    var g: Glyph = .{ .bar = self, .hdc = mem, .x = p.new_tab.left + inset, .y = p.new_tab.top + inset, .color = pal.text };
    g.outline(0, 0, 16, 16, 2, 3, back);
    g.fill(7, 4, 9, 12);
    g.fill(4, 7, 12, 9);

    // Its arrow: pan-down, a 12 x 6 triangle, past the split button's
    // divider (in the button's last column, 6 from its top and bottom).
    back = self.buttonBack(mem, p.new_tab_menu, state(.new_tab_menu, hover, pressed), pal);
    const divider_x = p.new_tab_menu.left - 1;
    draw.fill(mem, .{
        .left = divider_x,
        .top = p.new_tab_menu.top + self.scale(6),
        .right = divider_x + @max(1, self.scale(1)),
        .bottom = p.new_tab_menu.bottom - self.scale(6),
    }, pal.divider);
    g = .{ .bar = self, .hdc = mem, .x = p.new_tab_menu.left, .y = p.new_tab_menu.top, .color = pal.text };
    const tri = g.rect(5, 14, 17, 20);
    draw.polygon(mem, &.{
        .{ .x = tri.left, .y = tri.top },
        .{ .x = tri.right, .y = tri.top },
        .{ .x = @divTrunc(tri.left + tri.right, 2), .y = tri.bottom },
    }, pal.text);

    // The tab list's button: view-grid, four squares (GTK's overview).
    back = self.buttonBack(mem, p.list, state(.list, hover, pressed), pal);
    g = .{ .bar = self, .hdc = mem, .x = p.list.left + inset, .y = p.list.top + inset, .color = pal.text };
    for ([_]c_int{ 1, 9 }) |y0| for ([_]c_int{ 1, 9 }) |x0| g.fill(x0, y0, x0 + 6, y0 + 6);

    // The main menu's button: open-menu, three bars.
    back = self.buttonBack(mem, p.menu, state(.menu, hover, pressed), pal);
    g = .{ .bar = self, .hdc = mem, .x = p.menu.left + inset, .y = p.menu.top + inset, .color = pal.text };
    for ([_]c_int{ 2, 7, 12 }) |y0| g.fill(1, y0, 15, y0 + 2);

    // The window's buttons: libadwaita's round controls, their 8 px
    // glyphs 13 px into the button.
    if (self.controls) for ([_]struct { Hit, c.RECT }{
        .{ .minimize, p.minimize },
        .{ .maximize, p.maximize },
        .{ .window_close, p.window_close },
    }) |control| {
        const r = control[1];
        draw.fill(mem, r, pal.bar);
        const circle = self.scale(control_circle);
        const off = @divTrunc(r.right - r.left - circle, 2);
        const disc = switch (state(control[0], hover, pressed)) {
            .normal => pal.control,
            .hover => pal.control_hover,
            .pressed => pal.control_pressed,
        };
        const round: c.RECT = .{ .left = r.left + off, .top = r.top + off, .right = r.left + off + circle, .bottom = r.top + off + circle };
        draw.roundRect(mem, round, @divTrunc(circle, 2), disc, null, 0);
        g = .{ .bar = self, .hdc = mem, .x = r.left, .y = r.top, .color = pal.text };
        switch (control[0]) {
            // window-minimize: a bar low in the box.
            .minimize => g.fill(13, 19, 21, 21),
            // window-maximize, or window-restore when maximized: one
            // square, or two overlapping.
            .maximize => if (maximized) {
                g.outline(13, 15, 19, 21, 2, 0, disc);
                g.fill(15, 13, 21, 15);
                g.fill(19, 13, 21, 19);
            } else {
                g.outline(13, 13, 21, 21, 2, 0, disc);
            },
            // window-close: an X.
            else => draw.cross(mem, g.rect(13, 13, 21, 21), self.dpi, pal.text),
        }
    };

    // The title, bold, centered on the bar, between the buttons.
    if (title.len > 0 and !self.tabs_style) {
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
/// pressed (libadwaita's flat button). Returns the color behind its icon.
fn buttonBack(self: *const HeaderBar, hdc: c.HDC, r: c.RECT, s: State, pal: draw.Palette) c.COLORREF {
    draw.fill(hdc, r, pal.bar);
    const color = switch (s) {
        .normal => return pal.bar,
        .hover => pal.hover,
        .pressed => pal.pressed,
    };
    draw.roundRect(hdc, r, self.scale(button_radius), color, null, 0);
    return color;
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
    // Left to right, no overlaps; the list and menu buttons side by side.
    try testing.expect(p.new_tab_menu.left >= p.new_tab.right);
    try testing.expect(p.list.right == p.menu.left and p.menu.right <= p.minimize.left);
    try testing.expect(p.minimize.right <= p.maximize.left and p.maximize.right <= p.window_close.left);
}

test "place: GTK's geometry at 96 DPI" {
    const testing = std.testing;
    const bar: HeaderBar = .{};
    // The reference capture's 794 px bar, measured from its left edge.
    const p = bar.place(794);
    try testing.expectEqual(@as(c_int, 6), p.new_tab.left);
    try testing.expectEqual(@as(c_int, 61), p.new_tab_menu.right);
    try testing.expectEqual(@as(c_int, 606), p.list.left);
    try testing.expectEqual(@as(c_int, 680), p.minimize.left);
    try testing.expectEqual(@as(c_int, 754), p.window_close.left);
    try testing.expectEqual(@as(c_int, 788), p.window_close.right);
}

test "place: GTK's tab row as the title bar (gtk-titlebar-style = tabs)" {
    const testing = std.testing;
    const bar: HeaderBar = .{ .tabs_style = true };
    // The reference's 794 px row: the menu button touches minimize, and
    // the tabs fill 61 to 612.
    const p = bar.place(794);
    try testing.expectEqual(@as(c_int, 612), p.list.left);
    try testing.expectEqual(@as(c_int, 680), p.menu.right);
    try testing.expectEqual(@as(c_int, 680), p.minimize.left);
    try testing.expectEqual([2]c_int{ 61, 794 - 612 }, bar.tabsInset());
    // Without the window's buttons (no client-side decorations) the menu
    // ends the row, and no column hits a window button.
    const plain: HeaderBar = .{ .tabs_style = true, .controls = false };
    const q = plain.place(794);
    try testing.expectEqual(@as(c_int, 788), q.menu.right);
    try testing.expectEqual(Hit.menu, plain.hitTest(787, 20, 794));
    try testing.expectEqual(Hit.none, plain.hitTest(793, 20, 794));
    try testing.expectEqual(@as(c_int, 61 + 6 + 68 + 64), plain.minWidth());
}

test "minWidth: the buttons stay apart at the narrowest bar" {
    const testing = std.testing;
    for ([_]c.UINT{ 96, 120, 144, 192 }) |dpi| {
        const bar: HeaderBar = .{ .dpi = dpi };
        const min = bar.minWidth();
        const p = bar.place(min);
        try testing.expectEqual(p.new_tab_menu.right + bar.scale(spacing), p.list.left);
        // Each column hit-tests as itself.
        try testing.expectEqual(Hit.new_tab_menu, bar.hitTest(p.new_tab_menu.right - 1, 20, min));
        try testing.expectEqual(Hit.list, bar.hitTest(p.list.left, 20, min));
        try testing.expectEqual(Hit.minimize, bar.hitTest(p.minimize.left, 20, min));
    }
    // 61 px of split button, 6 of spacing, 188 of buttons at the right.
    try testing.expectEqual(@as(c_int, 255), (HeaderBar{}).minWidth());
}
