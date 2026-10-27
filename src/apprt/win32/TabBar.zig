//! The tab row: a custom-drawn strip of tabs below the header bar (GTK's
//! tab bar; roadmap 3.8, 4.3).
//!
//! Drawn with GDI rather than the common tab control so it can follow
//! the terminal's colors. The Window owns the tabs; this only lays them
//! out, paints and hit-tests. Tabs share the row between 64 and 240 DIP
//! each; when they don't fit at 64 they scroll (by `scroll`) between a "‹"
//! and a "›". The header bar's buttons are HeaderBar's.
const TabBar = @This();

const std = @import("std");
const c = @import("c.zig");
const draw = @import("draw.zig");
const text_util = @import("text.zig");

/// Unscaled metrics, in device-independent pixels.
const bar_height = 34;
const tab_max_width = 240;
const tab_min_width = 64;
/// The "‹" and "›" scrolling an overflowing row.
const chevron_width = 22;
const close_size = 18;
const text_inset = 12;

font: ?c.HFONT = null,
dpi: c.UINT = c.USER_DEFAULT_SCREEN_DPI,

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

fn place(self: *const TabBar, n: usize, width: c_int) Place {
    const count: c_int = @intCast(@max(n, 1));
    const per = @divTrunc(@max(0, width), count);
    if (per >= self.scale(tab_min_width) or n <= 1) {
        const w = std.math.clamp(per, self.scale(tab_min_width), self.scale(tab_max_width));
        return .{ .tab_width = w, .overflow = false, .view_left = 0, .view_right = w * count };
    }
    const chevron = self.scale(chevron_width);
    return .{
        .tab_width = self.scale(tab_min_width),
        .overflow = true,
        .view_left = chevron,
        .view_right = @max(chevron, width - chevron),
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

pub fn height(self: *const TabBar) c_int {
    return self.scale(bar_height);
}

/// The rectangle of tab `i` of `n` in a row `width` pixels wide, in the
/// row's coordinates; scrolled, it may lie partly or wholly outside the
/// span tabs show in.
pub fn tabRect(self: *const TabBar, i: usize, n: usize, width: c_int) c.RECT {
    const p = self.place(n, width);
    const offset = if (p.overflow) self.scroll else 0;
    const left = p.view_left + p.tab_width * @as(c_int, @intCast(i)) - offset;
    return .{ .left = left, .top = 0, .right = left + p.tab_width, .bottom = self.height() };
}

/// The span tabs show in (between the chevrons, when they overflow).
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
    return .{ .left = 0, .top = 0, .right = p.view_left, .bottom = self.height() };
}

pub fn scrollRightRect(self: *const TabBar, n: usize, width: c_int) c.RECT {
    const p = self.place(n, width);
    return .{ .left = p.view_right, .top = 0, .right = width, .bottom = self.height() };
}

pub fn closeRect(self: *const TabBar, tab: c.RECT) c.RECT {
    const s = self.scale(close_size);
    const right = tab.right - self.scale(8);
    const top = tab.top + @divTrunc(tab.bottom - tab.top - s, 2);
    return .{ .left = right - s, .top = top, .right = right, .bottom = top + s };
}

/// The item at (`x`, `y`) in the row's coordinates.
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
        if (draw.contains(r, x, y)) {
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
    // Tabs only where they show; scrolled away, they are cut at the
    // chevrons.
    const view = self.viewRect(n, width);
    _ = c.IntersectClipRect(mem, view.left, view.top, view.right, view.bottom);
    for (titles, 0..) |title, i| {
        const r = self.tabRect(i, n, width);
        if (r.right <= view.left or r.left >= view.right) continue;
        const is_active = i == active;
        const hovered = switch (self.hover) {
            .tab, .close => |hi| hi == i,
            else => false,
        };

        if (is_active) {
            draw.fill(mem, r, pal.active);
        } else if (hovered) {
            draw.fill(mem, r, pal.hover);
        } else if (i + 1 != active and i + 1 < n) {
            // Separators between inactive tabs.
            const inset = self.scale(9);
            draw.line(mem, r.right - 1, r.top + inset, r.right - 1, r.bottom - inset, pal.separator, pen_w);
        }

        // Title
        var text_rect: c.RECT = .{
            .left = r.left + self.scale(text_inset),
            .top = r.top,
            .right = r.right - self.scale(close_size + 12),
            .bottom = r.bottom,
        };
        var buf: [256]u16 = undefined;
        // Cut between characters: a cut inside one would fail the whole title.
        const len = std.unicode.utf8ToUtf16Le(&buf, text_util.truncate(title, 200)) catch 0;
        _ = c.SetTextColor(mem, if (is_active) pal.text else pal.text_dim);
        _ = c.DrawTextW(mem, &buf, @intCast(len), &text_rect, c.DT_SINGLELINE | c.DT_VCENTER | c.DT_END_ELLIPSIS | c.DT_NOPREFIX);

        // The bell's mark: a line under the tab's title.
        if (i < attention.len and attention[i]) {
            const y = r.bottom - self.scale(4);
            const w = @max(2, self.scale(2));
            draw.line(mem, text_rect.left, y, text_rect.right, y, pal.text, w);
        }

        // Close button on the active and hovered tabs.
        if (is_active or hovered) {
            const cr = self.closeRect(r);
            if (std.meta.eql(self.hover, Hit{ .close = i })) draw.fill(mem, cr, pal.hover);
            const pad = self.scale(5);
            const color = if (is_active) pal.text else pal.text_dim;
            draw.line(mem, cr.left + pad, cr.top + pad, cr.right - pad, cr.bottom - pad, color, pen_w);
            draw.line(mem, cr.right - pad - 1, cr.top + pad, cr.left + pad - 1, cr.bottom - pad, color, pen_w);
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
            draw.fill(mem, r, if (std.meta.eql(self.hover, chev[0]) and chev[2]) pal.hover else pal.bar);
            const x = @divTrunc(r.left + r.right, 2);
            const y = @divTrunc(r.top + r.bottom, 2);
            const arm = self.scale(4);
            const color = if (chev[2]) pal.text_dim else pal.separator;
            // "‹" points left (-1), "›" right (1).
            draw.line(mem, x + arm * chev[3] * -1, y - arm, x + arm * chev[3], y + 1, color, pen_w);
            draw.line(mem, x + arm * chev[3] * -1, y + arm, x + arm * chev[3], y - 1, color, pen_w);
        }
    }

    _ = c.BitBlt(hdc, 0, top, width, h, mem, 0, 0, c.SRCCOPY);
}

test "hitTest" {
    const testing = std.testing;
    const bar: TabBar = .{};
    // Two tabs in a wide row: each is tab_max_width wide, from the left.
    try testing.expectEqual(Hit{ .tab = 0 }, bar.hitTest(10, 10, 2, 2000));
    try testing.expectEqual(Hit{ .tab = 1 }, bar.hitTest(tab_max_width + 10, 10, 2, 2000));
    try testing.expectEqual(Hit{ .close = 0 }, bar.hitTest(tab_max_width - 12, bar_height / 2, 2, 2000));
    try testing.expectEqual(Hit.none, bar.hitTest(1500, 10, 2, 2000));
    try testing.expectEqual(Hit.none, bar.hitTest(10, bar_height + 1, 2, 2000));
    try testing.expect(!bar.overflowing(2, 2000));
}

test "overflow: 40 tabs scroll between the chevrons, all reachable" {
    const testing = std.testing;
    var bar: TabBar = .{};
    const n = 40;
    const width = 500;
    try testing.expect(bar.overflowing(n, width));
    // [‹ 0..22][tabs 22..478][› 478..500]
    try testing.expectEqual(Hit.scroll_left, bar.hitTest(5, 10, n, width));
    try testing.expectEqual(Hit.scroll_right, bar.hitTest(width - 5, 10, n, width));
    try testing.expectEqual(Hit{ .tab = 0 }, bar.hitTest(30, 10, n, width));

    // Scrolling by a tab, never past either end.
    try testing.expect(!bar.scrollTabs(-1, n, width));
    try testing.expect(bar.scrollTabs(1, n, width));
    try testing.expectEqual(Hit{ .tab = 1 }, bar.hitTest(30, 10, n, width));
    try testing.expect(bar.scrollTabs(1000, n, width));
    try testing.expectEqual(bar.maxScroll(n, width), bar.scroll);

    // Every tab can be brought into view and clicked.
    for (0..n) |i| {
        bar.ensureVisible(i, n, width);
        const r = bar.tabRect(i, n, width);
        const view = bar.viewRect(n, width);
        try testing.expect(r.left >= view.left and r.right <= view.right);
        try testing.expectEqual(Hit{ .tab = i }, bar.hitTest(r.left + 8, 10, n, width));
    }

    // Fewer tabs fit again: no scroll left over.
    bar.ensureVisible(0, 2, width);
    try testing.expectEqual(@as(c_int, 0), bar.scroll);
}
