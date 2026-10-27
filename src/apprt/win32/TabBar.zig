//! The tab row: a custom-drawn strip of tabs below the header bar, GTK's
//! tab bar as libadwaita draws it (roadmap 3.8, 4.3).
//!
//! Drawn with GDI rather than the common tab control so it can look like
//! libadwaita's: in the header bar's color, a 34 DIP tab box with 6 below
//! and, as the top bar (no header bar above), 6 above (40 or 46 DIP, as
//! measured on GTK's), tabs as rounded buttons (radius 9) with the title
//! centered, the selected one tinted, a round close button on the
//! selected and hovered tabs, separators between the others. The Window
//! owns the tabs; this only lays them out, paints and hit-tests.
//! Tabs fill the row (`gtk-wide-tabs`, as GTK's do by default) or take up
//! to 240 DIP each; below 64 DIP they scroll (by `scroll`) between a "‹"
//! and a "›". The header bar's buttons are HeaderBar's.
const TabBar = @This();

const std = @import("std");
const c = @import("c.zig");
const draw = @import("draw.zig");
const text_util = @import("text.zig");

/// Unscaled metrics, in device-independent pixels.
const tab_pad = 6;
const tab_height = 34;
const pad_x = 6;
const tab_max_width = 240;
const tab_min_width = 64;
/// The "‹" and "›" scrolling an overflowing row.
const chevron_width = 22;
const close_size = 24;
const tab_radius = 9;
const text_inset = 12;

font: ?c.HFONT = null,
dpi: c.UINT = c.USER_DEFAULT_SCREEN_DPI,
/// Tabs share the whole row (gtk-wide-tabs), rather than stopping at 240
/// DIP each.
wide: bool = true,
/// The row is the top bar (no header bar above it): libadwaita pads its
/// tab box above as well as below.
top_bar: bool = false,
/// The row is the title bar (gtk-titlebar-style = tabs): the tabs go only
/// in this span, its distance in pixels from the row's left and right
/// edges, unpadded, between the header bar's buttons (HeaderBar.tabsInset).
inset: ?[2]c_int = null,
/// gtk-tabs-inverted: a tab's close button at its start.
inverted: bool = false,

/// The item under the mouse, in this row or the header bar, for hover
/// highlighting.
hover: Hit = .none,
tracking: bool = false,

/// How far the tabs are scrolled, in pixels, while they overflow.
scroll: c_int = 0,

/// An item of the window's chrome: the tab row's or the header bar's.
pub const Hit = union(enum) {
    none,
    tab: usize,
    close: usize,
    /// The chevrons of an overflowing row.
    scroll_left,
    scroll_right,
    /// The header bar's "+", and the arrow beside it: the split menu.
    new_tab,
    new_tab_menu,
    /// The tab list's button.
    list,
    /// The main menu's button.
    menu,
    /// The window's buttons.
    minimize,
    maximize,
    window_close,

    pub fn eql(a: Hit, b: Hit) bool {
        return std.meta.eql(a, b);
    }
};

/// Where the tabs go for `n` of them in a row `width` pixels wide.
const Place = struct {
    tab_width: c_int,
    /// The tabs don't fit at their narrowest: they scroll between the
    /// chevrons.
    overflow: bool,
    /// The span the tabs show in.
    view_left: c_int,
    view_right: c_int,
};

/// The span the tabs and chevrons share in a row `width` pixels wide.
fn span(self: *const TabBar, width: c_int) [2]c_int {
    if (self.inset) |in| return .{ in[0], @max(in[0], width - in[1]) };
    const pad = self.scale(pad_x);
    return .{ pad, @max(pad, width - pad) };
}

fn place(self: *const TabBar, n: usize, width: c_int) Place {
    const count: c_int = @intCast(@max(n, 1));
    const lo, const hi = self.span(width);
    const per = @divTrunc(hi - lo, count);
    if (per >= self.scale(tab_min_width) or n <= 1) {
        const w = if (self.wide)
            @max(per, self.scale(tab_min_width))
        else
            std.math.clamp(per, self.scale(tab_min_width), self.scale(tab_max_width));
        return .{ .tab_width = w, .overflow = false, .view_left = lo, .view_right = lo + w * count };
    }
    const chevron = self.scale(chevron_width);
    // Unpadded, the chevrons start at the row's edge.
    const outer_lo = if (self.inset) |in| in[0] else 0;
    const outer_hi = if (self.inset != null) hi else width;
    return .{
        .tab_width = self.scale(tab_min_width),
        .overflow = true,
        .view_left = outer_lo + chevron,
        .view_right = @max(outer_lo + chevron, outer_hi - chevron),
    };
}

/// The furthest the tabs scroll.
fn maxScroll(self: *const TabBar, n: usize, width: c_int) c_int {
    const p = self.place(n, width);
    if (!p.overflow) return 0;
    return @max(0, p.tab_width * @as(c_int, @intCast(n)) - (p.view_right - p.view_left));
}

/// Keep the scroll in range (after the row or the tabs change).
pub fn clampScroll(self: *TabBar, n: usize, width: c_int) void {
    self.scroll = std.math.clamp(self.scroll, 0, self.maxScroll(n, width));
}

/// Scroll by `tabs` tabs (negative: towards the first). Returns whether
/// anything moved.
pub fn scrollTabs(self: *TabBar, tabs: c_int, n: usize, width: c_int) bool {
    const before = self.scroll;
    self.scroll += tabs * self.place(n, width).tab_width;
    self.clampScroll(n, width);
    return self.scroll != before;
}

/// Scroll so tab `i` shows whole.
pub fn ensureVisible(self: *TabBar, i: usize, n: usize, width: c_int) void {
    const p = self.place(n, width);
    if (!p.overflow) {
        self.scroll = 0;
        return;
    }
    const left = p.tab_width * @as(c_int, @intCast(i));
    const view = p.view_right - p.view_left;
    if (left < self.scroll) self.scroll = left;
    if (left + p.tab_width > self.scroll + view) self.scroll = left + p.tab_width - view;
    self.clampScroll(n, width);
}

pub fn deinit(self: *TabBar) void {
    if (self.font) |f| _ = c.DeleteObject(f);
    self.font = null;
}

/// Recreate the font for the given DPI: the system's message font, in
/// `family` if set (window-title-font-family).
pub fn setDpi(self: *TabBar, dpi: c.UINT, family: ?[]const u8) void {
    self.dpi = dpi;
    if (self.font) |f| _ = c.DeleteObject(f);
    self.font = draw.chromeFont(dpi, family, false);
}

/// The font's face, for the GUI tests' dump.
pub fn faceName(self: *const TabBar, buf: []u8) []const u8 {
    return draw.faceName(self.font, buf);
}

fn scale(self: *const TabBar, v: c_int) c_int {
    return draw.scale(self.dpi, v);
}

/// The tab box's top: padded only as the top bar.
fn tabTop(self: *const TabBar) c_int {
    return if (self.top_bar) self.scale(tab_pad) else 0;
}

pub fn height(self: *const TabBar) c_int {
    return self.tabTop() + self.scale(tab_height + tab_pad);
}

/// The rectangle of tab `i` of `n` in a row `width` pixels wide, in the
/// row's coordinates; scrolled, it may lie partly or wholly outside the
/// span tabs show in.
pub fn tabRect(self: *const TabBar, i: usize, n: usize, width: c_int) c.RECT {
    const p = self.place(n, width);
    const offset = if (p.overflow) self.scroll else 0;
    const left = p.view_left + p.tab_width * @as(c_int, @intCast(i)) - offset;
    const top = self.tabTop();
    return .{ .left = left, .top = top, .right = left + p.tab_width, .bottom = top + self.scale(tab_height) };
}

/// The span tabs show in (between the chevrons, when they overflow), the
/// row's whole height.
pub fn viewRect(self: *const TabBar, n: usize, width: c_int) c.RECT {
    const p = self.place(n, width);
    return .{ .left = p.view_left, .top = 0, .right = p.view_right, .bottom = self.height() };
}

/// Whether the tabs overflow (and the chevrons show).
pub fn overflowing(self: *const TabBar, n: usize, width: c_int) bool {
    return self.place(n, width).overflow;
}

/// The chevrons, when the tabs overflow.
pub fn scrollLeftRect(self: *const TabBar, n: usize, width: c_int) c.RECT {
    const p = self.place(n, width);
    const left = if (self.inset) |in| in[0] else 0;
    return .{ .left = left, .top = 0, .right = p.view_left, .bottom = self.height() };
}

pub fn scrollRightRect(self: *const TabBar, n: usize, width: c_int) c.RECT {
    const p = self.place(n, width);
    const right = if (self.inset != null) self.span(width)[1] else width;
    return .{ .left = p.view_right, .top = 0, .right = right, .bottom = self.height() };
}

/// A tab's close button: a circle at its right end (its glyph 31 DIP from
/// the row's right edge, as GTK's), or its left with gtk-tabs-inverted.
pub fn closeRect(self: *const TabBar, tab: c.RECT) c.RECT {
    const s = self.scale(close_size);
    const left = if (self.inverted) tab.left + self.scale(9) else tab.right - self.scale(9) - s;
    const top = tab.top + @divTrunc(tab.bottom - tab.top - s, 2);
    return .{ .left = left, .top = top, .right = left + s, .bottom = top + s };
}

/// The item at (`x`, `y`) in the row's coordinates. A tab takes the row's
/// whole height.
pub fn hitTest(self: *const TabBar, x: c_int, y: c_int, n: usize, width: c_int) Hit {
    if (y < 0 or y >= self.height()) return .none;
    if (self.overflowing(n, width)) {
        if (draw.contains(self.scrollLeftRect(n, width), x, y)) return .scroll_left;
        if (draw.contains(self.scrollRightRect(n, width), x, y)) return .scroll_right;
    }
    // Only where tabs show: scrolled away, they are under the chevrons.
    if (!draw.contains(self.viewRect(n, width), x, y)) return .none;
    for (0..n) |i| {
        const r = self.tabRect(i, n, width);
        if (x >= r.left and x < r.right) {
            return if (draw.contains(self.closeRect(r), x, y)) .{ .close = i } else .{ .tab = i };
        }
    }
    return .none;
}

/// Paint the row into `hdc` at (0, `top`), double buffered to avoid
/// flicker.
pub fn paint(
    self: *const TabBar,
    hdc: c.HDC,
    top: c_int,
    width: c_int,
    titles: []const []const u8,
    /// The tabs the bell rang in while in the background (underlined, as
    /// GTK marks a tab needing attention).
    attention: []const bool,
    active: usize,
    pal: draw.Palette,
) void {
    const h = self.height();
    const mem = c.CreateCompatibleDC(hdc) orelse return;
    defer _ = c.DeleteDC(mem);
    const bmp = c.CreateCompatibleBitmap(hdc, width, h) orelse return;
    defer _ = c.DeleteObject(bmp);
    const old_bmp = c.SelectObject(mem, bmp);
    defer _ = c.SelectObject(mem, old_bmp);
    const old_font = if (self.font) |f| c.SelectObject(mem, f) else null;
    defer if (old_font) |f| {
        _ = c.SelectObject(mem, f);
    };
    _ = c.SetBkMode(mem, c.TRANSPARENT);

    draw.fill(mem, .{ .right = width, .bottom = h }, pal.bar);

    const n = titles.len;
    const pen_w = @max(1, self.scale(1));
    const stroke = @max(1, self.scale(2));
    const radius = self.scale(tab_radius);
    // Tabs only where they show; scrolled away, they are cut at the
    // chevrons.
    const view = self.viewRect(n, width);
    _ = c.IntersectClipRect(mem, view.left, view.top, view.right, view.bottom);
    for (titles, 0..) |title, i| {
        const r = self.tabRect(i, n, width);
        if (r.right <= view.left or r.left >= view.right) continue;
        const selected = i == active;
        const hovered = switch (self.hover) {
            .tab, .close => |hi| hi == i,
            else => false,
        };

        // A lone tab has no background (libadwaita's single tab).
        const back: ?c.COLORREF = if (selected and n > 1)
            (if (hovered) pal.active_hover else pal.active)
        else if (hovered) pal.hover else null;
        if (back) |color| draw.roundRect(mem, r, radius, color, null, 0);

        // Separators between tabs neither selected nor hovered.
        if (i + 1 < n) {
            const next_hovered = switch (self.hover) {
                .tab, .close => |hi| hi == i + 1,
                else => false,
            };
            if (!selected and !hovered and i + 1 != active and !next_hovered) {
                const inset = self.scale(3) + self.scale(3);
                draw.line(mem, r.right, r.top + inset, r.right, r.bottom - inset, pal.separator, pen_w);
            }
        }

        // The title, centered, clear of the close button on either side.
        const show_close = selected or hovered;
        const side = self.scale(text_inset) + (if (r.right - r.left > self.scale(close_size * 4)) self.scale(close_size) else 0);
        var text_rect: c.RECT = .{ .left = r.left + side, .top = r.top, .right = r.right - side, .bottom = r.bottom };
        if (text_rect.right <= text_rect.left) text_rect = .{ .left = r.left + self.scale(text_inset), .top = r.top, .right = r.right - self.scale(close_size + 6), .bottom = r.bottom };
        var buf: [256]u16 = undefined;
        // Cut between characters: a cut inside one would fail the whole title.
        const len = std.unicode.utf8ToUtf16Le(&buf, text_util.truncate(title, 200)) catch 0;
        _ = c.SetTextColor(mem, pal.text);
        _ = c.DrawTextW(mem, &buf, @intCast(len), &text_rect, c.DT_SINGLELINE | c.DT_VCENTER | c.DT_CENTER | c.DT_END_ELLIPSIS | c.DT_NOPREFIX);

        // The bell's mark: a line under the tab's title.
        if (i < attention.len and attention[i]) {
            const y = r.bottom - self.scale(4);
            draw.line(mem, text_rect.left, y, text_rect.right, y, pal.text, @max(2, self.scale(2)));
        }

        // The close button on the selected and hovered tabs: a round
        // button, tinted when hovered.
        if (show_close) {
            const cr = self.closeRect(r);
            if (std.meta.eql(self.hover, Hit{ .close = i })) {
                draw.roundRect(mem, cr, @divTrunc(cr.right - cr.left, 2), pal.pressed, null, 0);
            }
            // window-close's 8 DIP X in the middle of the circle.
            const off = self.scale(8);
            draw.cross(mem, .{ .left = cr.left + off, .top = cr.top + off, .right = cr.left + off + self.scale(8), .bottom = cr.top + off + self.scale(8) }, self.dpi, pal.text);
        }
    }
    _ = c.SelectClipRgn(mem, null);

    // The chevrons, dimmed at either end of the scroll.
    if (self.overflowing(n, width)) {
        const max = self.maxScroll(n, width);
        for ([_]struct { Hit, c.RECT, bool, c_int }{
            .{ .scroll_left, self.scrollLeftRect(n, width), self.scroll > 0, -1 },
            .{ .scroll_right, self.scrollRightRect(n, width), self.scroll < max, 1 },
        }) |chev| {
            const r = chev[1];
            draw.fill(mem, r, pal.bar);
            if (std.meta.eql(self.hover, chev[0]) and chev[2]) {
                const t = self.tabTop();
                draw.roundRect(mem, .{ .left = r.left, .top = t, .right = r.right, .bottom = t + self.scale(tab_height) }, radius, pal.hover, null, 0);
            }
            const x = @divTrunc(r.left + r.right, 2);
            const y = @divTrunc(r.top + r.bottom, 2);
            const arm = self.scale(4);
            const color = if (chev[2]) pal.text else pal.text_dim;
            // "‹" points left (-1), "›" right (1).
            draw.line(mem, x + arm * chev[3] * -1, y - arm, x + arm * chev[3], y + 1, color, stroke);
            draw.line(mem, x + arm * chev[3] * -1, y + arm, x + arm * chev[3], y - 1, color, stroke);
        }
    }

    // In the title bar, only the span: the header bar's buttons are
    // around it.
    if (self.inset != null) {
        const lo, const hi = self.span(width);
        _ = c.BitBlt(hdc, lo, top, hi - lo, h, mem, lo, 0, c.SRCCOPY);
    } else {
        _ = c.BitBlt(hdc, 0, top, width, h, mem, 0, 0, c.SRCCOPY);
    }
}

test "hitTest: wide tabs share the row" {
    const testing = std.testing;
    const bar: TabBar = .{};
    const width = 2000;
    // Two tabs: each takes half the row, less its padding.
    const half = @divTrunc(width - 2 * pad_x, 2);
    try testing.expectEqual(Hit{ .tab = 0 }, bar.hitTest(pad_x + 10, 20, 2, width));
    try testing.expectEqual(Hit{ .tab = 1 }, bar.hitTest(pad_x + half + 10, 20, 2, width));
    try testing.expectEqual(Hit{ .close = 0 }, bar.hitTest(pad_x + half - 9 - close_size / 2, tab_height / 2, 2, width));
    // The row's top and bottom margins still hit the tab.
    try testing.expectEqual(Hit{ .tab = 0 }, bar.hitTest(pad_x + 10, 1, 2, width));
    try testing.expectEqual(Hit.none, bar.hitTest(2, 20, 2, width));
    try testing.expectEqual(Hit.none, bar.hitTest(10, bar.height() + 1, 2, width));
    try testing.expect(!bar.overflowing(2, width));
}

test "inset: the tabs fill the title bar's span (gtk-titlebar-style = tabs)" {
    const testing = std.testing;
    // GTK's 794 px row: the tab runs from the split arrow (61) to the tab
    // list's button (612), its close glyph at 588 to 593.
    const bar: TabBar = .{ .top_bar = true, .inset = .{ 61, 794 - 612 } };
    const r = bar.tabRect(0, 1, 794);
    try testing.expectEqual(@as(c_int, 61), r.left);
    try testing.expectEqual(@as(c_int, 612), r.right);
    const cr = bar.closeRect(r);
    try testing.expectEqual(@as(c_int, 579), cr.left);
    try testing.expectEqual(Hit.none, bar.hitTest(40, 20, 1, 794));
    try testing.expectEqual(Hit.none, bar.hitTest(700, 20, 1, 794));
    // Overflowing, the chevrons stay inside the span too.
    try testing.expect(bar.overflowing(20, 794));
    try testing.expectEqual(@as(c_int, 61), bar.scrollLeftRect(20, 794).left);
    try testing.expectEqual(@as(c_int, 612), bar.scrollRightRect(20, 794).right);
}

test "inverted: the close button at the tab's start (gtk-tabs-inverted)" {
    const testing = std.testing;
    // GTK's lone tab, 6 to 788: its close glyph at 24 to 29.
    const bar: TabBar = .{ .inverted = true };
    const r = bar.tabRect(0, 1, 794);
    try testing.expectEqual(@as(c_int, 15), bar.closeRect(r).left);
    try testing.expectEqual(Hit{ .close = 0 }, bar.hitTest(27, 17, 1, 794));
    try testing.expectEqual(Hit{ .tab = 0 }, bar.hitTest(770, 17, 1, 794));
}

test "height: 40 below a header bar, 46 as the top bar (GTK's)" {
    const testing = std.testing;
    try testing.expectEqual(@as(c_int, 40), (TabBar{}).height());
    try testing.expectEqual(@as(c_int, 46), (TabBar{ .top_bar = true }).height());
    try testing.expectEqual(@as(c_int, 6), (TabBar{ .top_bar = true }).tabRect(0, 1, 500).top);
}

test "hitTest: without gtk-wide-tabs, tabs stop at 240" {
    const testing = std.testing;
    const bar: TabBar = .{ .wide = false };
    try testing.expectEqual(Hit{ .tab = 1 }, bar.hitTest(pad_x + tab_max_width + 10, 20, 2, 2000));
    try testing.expectEqual(Hit.none, bar.hitTest(1500, 20, 2, 2000));
}

test "overflow: 40 tabs scroll between the chevrons, all reachable" {
    const testing = std.testing;
    var bar: TabBar = .{};
    const n = 40;
    const width = 500;
    try testing.expect(bar.overflowing(n, width));
    // [‹ 0..22][tabs 22..478][› 478..500]
    try testing.expectEqual(Hit.scroll_left, bar.hitTest(5, 20, n, width));
    try testing.expectEqual(Hit.scroll_right, bar.hitTest(width - 5, 20, n, width));
    try testing.expectEqual(Hit{ .tab = 0 }, bar.hitTest(30, 20, n, width));

    // Scrolling by a tab, never past either end.
    try testing.expect(!bar.scrollTabs(-1, n, width));
    try testing.expect(bar.scrollTabs(1, n, width));
    try testing.expectEqual(Hit{ .tab = 1 }, bar.hitTest(30, 20, n, width));
    try testing.expect(bar.scrollTabs(1000, n, width));
    try testing.expectEqual(bar.maxScroll(n, width), bar.scroll);

    // Every tab can be brought into view and clicked.
    for (0..n) |i| {
        bar.ensureVisible(i, n, width);
        const r = bar.tabRect(i, n, width);
        const view = bar.viewRect(n, width);
        try testing.expect(r.left >= view.left and r.right <= view.right);
        try testing.expectEqual(Hit{ .tab = i }, bar.hitTest(r.left + 8, 20, n, width));
    }

    // Fewer tabs fit again: no scroll left over.
    bar.ensureVisible(0, 2, width);
    try testing.expectEqual(@as(c_int, 0), bar.scroll);
}
