//! A custom-drawn tab strip along the top of a window's client area.
//!
//! Drawn with GDI rather than the common tab control so it can follow
//! the terminal's colors and the dark title bar. The Window owns the
//! tabs; this only lays them out, paints and hit-tests.
//!
//! Left to right: the tabs, "+" and the arrow beside it (the split menu),
//! then at the right end the tab list's button and the main menu's. Tabs
//! share the room between 64 and 240 DIP each; when they don't fit at 64
//! they scroll (by `scroll`) between a "‹" and a "›", and "+" moves to
//! just left of the list button (roadmap 3.8). Laid out for no tabs, it is
//! GTK's header bar alone: the buttons, "+" at the left end.
const TabBar = @This();

const std = @import("std");
const configpkg = @import("../../config.zig");
const c = @import("c.zig");

/// Unscaled metrics, in device-independent pixels.
const bar_height = 34;
const tab_max_width = 240;
const tab_min_width = 64;
const button_width = 34;
/// The arrow beside "+" opening the split menu (GTK's split button).
const dropdown_width = 18;
/// The "‹" and "›" scrolling an overflowing strip.
const chevron_width = 22;
const close_size = 18;
const text_inset = 12;

font: ?c.HFONT = null,
dpi: c.UINT = c.USER_DEFAULT_SCREEN_DPI,

/// The item under the mouse, for hover highlighting.
hover: Hit = .none,
tracking: bool = false,

/// How far the tabs are scrolled, in pixels, while they overflow.
scroll: c_int = 0,

pub const Hit = union(enum) {
    none,
    tab: usize,
    close: usize,
    new_tab,
    /// The arrow beside "+": the split menu.
    new_tab_menu,
    /// The tab list's button.
    list,
    /// The main menu's button at the right end.
    menu,
    /// The chevrons of an overflowing strip.
    scroll_left,
    scroll_right,

    pub fn eql(a: Hit, b: Hit) bool {
        return std.meta.eql(a, b);
    }
};

/// Where everything goes for `n` tabs in a bar `width` pixels wide.
const Place = struct {
    tab_width: c_int,
    /// The tabs don't fit at their narrowest: they scroll between the
    /// chevrons.
    overflow: bool,
    /// The span the tabs show in.
    view_left: c_int,
    view_right: c_int,
    new_tab_left: c_int,
    list_left: c_int,
    menu_left: c_int,
};

fn place(self: *const TabBar, n: usize, width: c_int) Place {
    const button = self.scale(button_width);
    const plus = button + self.scale(dropdown_width);
    const menu_left = width - button;
    const list_left = menu_left - button;
    const count: c_int = @intCast(@max(n, 1));
    const avail = @max(0, list_left - plus);
    const per = @divTrunc(avail, count);
    if (per >= self.scale(tab_min_width) or n <= 1) {
        const w = std.math.clamp(per, self.scale(tab_min_width), self.scale(tab_max_width));
        // No tabs (only the header's buttons): "+" at the left end.
        const tabs_right = if (n == 0) 0 else w * count;
        return .{
            .tab_width = w,
            .overflow = false,
            .view_left = 0,
            .view_right = tabs_right,
            .new_tab_left = tabs_right,
            .list_left = list_left,
            .menu_left = menu_left,
        };
    }
    const chevron = self.scale(chevron_width);
    const new_tab_left = @max(0, list_left - plus);
    return .{
        .tab_width = self.scale(tab_min_width),
        .overflow = true,
        .view_left = chevron,
        .view_right = @max(chevron, new_tab_left - chevron),
        .new_tab_left = new_tab_left,
        .list_left = list_left,
        .menu_left = menu_left,
    };
}

/// The furthest the tabs scroll.
fn maxScroll(self: *const TabBar, n: usize, width: c_int) c_int {
    const p = self.place(n, width);
    if (!p.overflow) return 0;
    return @max(0, p.tab_width * @as(c_int, @intCast(n)) - (p.view_right - p.view_left));
}

/// Keep the scroll in range (after the bar or the tabs change).
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
    self.font = null;

    var ncm: c.NONCLIENTMETRICSW = .{};
    if (c.SystemParametersInfoForDpi(c.SPI_GETNONCLIENTMETRICS, @sizeOf(c.NONCLIENTMETRICSW), &ncm, 0, dpi) != 0) {
        var lf = ncm.lfMessageFont;
        if (family) |name| setFace(&lf, name);
        self.font = c.CreateFontIndirectW(&lf);
    }
}

/// `name` as the font's face, if it fits LOGFONT's 31 characters.
fn setFace(lf: *c.LOGFONTW, name: []const u8) void {
    var wide: [32]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(wide[0..31], name) catch return;
    if (n == 0) return;
    lf.lfFaceName = @splat(0);
    @memcpy(lf.lfFaceName[0..n], wide[0..n]);
}

/// The font's face, for the GUI tests' dump.
pub fn faceName(self: *const TabBar, buf: []u8) []const u8 {
    const font = self.font orelse return "";
    var lf: c.LOGFONTW = undefined;
    if (c.GetObjectW(font, @sizeOf(c.LOGFONTW), &lf) == 0) return "";
    const face = std.mem.sliceTo(&lf.lfFaceName, 0);
    const n = std.unicode.utf16LeToUtf8(buf, face) catch return "";
    return buf[0..n];
}

fn scale(self: *const TabBar, v: c_int) c_int {
    return @intCast(@divTrunc(@as(i64, v) * self.dpi, c.USER_DEFAULT_SCREEN_DPI));
}

pub fn height(self: *const TabBar) c_int {
    return self.scale(bar_height);
}

/// The rectangle of tab `i` of `n` in a bar `width` pixels wide; scrolled,
/// it may lie partly or wholly outside the span tabs show in.
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
    return .{ .left = p.view_right, .top = 0, .right = p.new_tab_left, .bottom = self.height() };
}

/// The main menu's button, at the right end of the bar.
pub fn menuRect(self: *const TabBar, width: c_int) c.RECT {
    return .{ .left = width - self.scale(button_width), .top = 0, .right = width, .bottom = self.height() };
}

/// The tab list's button, left of the main menu's.
pub fn listRect(self: *const TabBar, width: c_int) c.RECT {
    const m = self.menuRect(width);
    return .{ .left = m.left - self.scale(button_width), .top = 0, .right = m.left, .bottom = self.height() };
}

pub fn closeRect(self: *const TabBar, tab: c.RECT) c.RECT {
    const s = self.scale(close_size);
    const right = tab.right - self.scale(8);
    const top = @divTrunc(tab.bottom - s, 2);
    return .{ .left = right - s, .top = top, .right = right, .bottom = top + s };
}

/// "+", after the last tab, or left of the list button when they overflow.
pub fn newTabRect(self: *const TabBar, n: usize, width: c_int) c.RECT {
    const left = self.place(n, width).new_tab_left;
    return .{ .left = left, .top = 0, .right = left + self.scale(button_width), .bottom = self.height() };
}

/// The arrow beside "+".
pub fn newTabMenuRect(self: *const TabBar, n: usize, width: c_int) c.RECT {
    const nt = self.newTabRect(n, width);
    return .{ .left = nt.right, .top = 0, .right = nt.right + self.scale(dropdown_width), .bottom = self.height() };
}

fn contains(r: c.RECT, x: c_int, y: c_int) bool {
    return x >= r.left and x < r.right and y >= r.top and y < r.bottom;
}

pub fn hitTest(self: *const TabBar, x: c_int, y: c_int, n: usize, width: c_int) Hit {
    if (y < 0 or y >= self.height()) return .none;
    if (contains(self.menuRect(width), x, y)) return .menu;
    if (contains(self.listRect(width), x, y)) return .list;
    if (contains(self.newTabRect(n, width), x, y)) return .new_tab;
    if (contains(self.newTabMenuRect(n, width), x, y)) return .new_tab_menu;
    if (self.overflowing(n, width)) {
        if (contains(self.scrollLeftRect(n, width), x, y)) return .scroll_left;
        if (contains(self.scrollRightRect(n, width), x, y)) return .scroll_right;
    }
    // Only where tabs show: scrolled away, they are under the chevrons.
    if (!contains(self.viewRect(n, width), x, y)) return .none;
    for (0..n) |i| {
        const r = self.tabRect(i, n, width);
        if (contains(r, x, y)) {
            return if (contains(self.closeRect(r), x, y)) .{ .close = i } else .{ .tab = i };
        }
    }
    return .none;
}

const Palette = struct {
    bar: c.COLORREF,
    active: c.COLORREF,
    hover: c.COLORREF,
    text: c.COLORREF,
    text_dim: c.COLORREF,
    separator: c.COLORREF,
};

const Color = configpkg.Config.Color;

fn blend(a: Color, b: Color, t: f32) Color {
    const f = struct {
        fn ch(x: u8, y: u8, k: f32) u8 {
            const v = @as(f32, @floatFromInt(x)) * (1 - k) + @as(f32, @floatFromInt(y)) * k;
            return @intFromFloat(@round(v));
        }
    }.ch;
    return .{ .r = f(a.r, b.r, t), .g = f(a.g, b.g, t), .b = f(a.b, b.b, t) };
}

fn ref(v: Color) c.COLORREF {
    return c.rgb(v.r, v.g, v.b);
}

/// Derive the colors from the terminal's background and foreground so the
/// active tab merges with the terminal below it.
fn palette(bg: Color, fg: Color) Palette {
    const bar = blend(bg, .{ .r = 0, .g = 0, .b = 0 }, 0.25);
    return .{
        .bar = ref(bar),
        .active = ref(bg),
        .hover = ref(blend(bar, fg, 0.08)),
        .text = ref(fg),
        .text_dim = ref(blend(fg, bg, 0.45)),
        .separator = ref(blend(fg, bg, 0.8)),
    };
}

fn fill(hdc: c.HDC, r: c.RECT, color: c.COLORREF) void {
    const brush = c.CreateSolidBrush(color) orelse return;
    defer _ = c.DeleteObject(brush);
    _ = c.FillRect(hdc, &r, brush);
}

fn line(hdc: c.HDC, x0: c_int, y0: c_int, x1: c_int, y1: c_int, color: c.COLORREF, width: c_int) void {
    const pen = c.CreatePen(c.PS_SOLID, width, color) orelse return;
    defer _ = c.DeleteObject(pen);
    const old = c.SelectObject(hdc, pen);
    defer _ = c.SelectObject(hdc, old);
    _ = c.MoveToEx(hdc, x0, y0, null);
    _ = c.LineTo(hdc, x1, y1);
}

/// Paint the bar into `hdc` (which covers exactly the bar), double
/// buffered to avoid flicker.
pub fn paint(
    self: *const TabBar,
    hdc: c.HDC,
    width: c_int,
    titles: []const []const u8,
    /// The tabs the bell rang in while in the background (underlined, as
    /// GTK marks a tab needing attention).
    attention: []const bool,
    active: usize,
    /// The active terminal's background and foreground.
    bg: Color,
    fg: Color,
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

    const pal = palette(bg, fg);
    fill(mem, .{ .right = width, .bottom = h }, pal.bar);

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
            fill(mem, r, pal.active);
        } else if (hovered) {
            fill(mem, r, pal.hover);
        } else if (i + 1 != active and i + 1 < n) {
            // Separators between inactive tabs.
            const inset = self.scale(9);
            line(mem, r.right - 1, r.top + inset, r.right - 1, r.bottom - inset, pal.separator, pen_w);
        }

        // Title
        var text_rect: c.RECT = .{
            .left = r.left + self.scale(text_inset),
            .top = r.top,
            .right = r.right - self.scale(close_size + 12),
            .bottom = r.bottom,
        };
        var buf: [256]u16 = undefined;
        const len = std.unicode.utf8ToUtf16Le(&buf, title[0..@min(title.len, 200)]) catch 0;
        _ = c.SetTextColor(mem, if (is_active) pal.text else pal.text_dim);
        _ = c.DrawTextW(mem, &buf, @intCast(len), &text_rect, c.DT_SINGLELINE | c.DT_VCENTER | c.DT_END_ELLIPSIS | c.DT_NOPREFIX);

        // The bell's mark: a line under the tab's title.
        if (i < attention.len and attention[i]) {
            const y = r.bottom - self.scale(4);
            const w = @max(2, self.scale(2));
            line(mem, text_rect.left, y, text_rect.right, y, pal.text, w);
        }

        // Close button on the active and hovered tabs.
        if (is_active or hovered) {
            const cr = self.closeRect(r);
            if (std.meta.eql(self.hover, Hit{ .close = i })) fill(mem, cr, pal.hover);
            const pad = self.scale(5);
            const color = if (is_active) pal.text else pal.text_dim;
            line(mem, cr.left + pad, cr.top + pad, cr.right - pad, cr.bottom - pad, color, pen_w);
            line(mem, cr.right - pad - 1, cr.top + pad, cr.left + pad - 1, cr.bottom - pad, color, pen_w);
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
            fill(mem, r, if (std.meta.eql(self.hover, chev[0]) and chev[2]) pal.hover else pal.bar);
            const x = @divTrunc(r.left + r.right, 2);
            const y = @divTrunc(r.top + r.bottom, 2);
            const arm = self.scale(4);
            const color = if (chev[2]) pal.text_dim else pal.separator;
            // "‹" points left (-1), "›" right (1).
            line(mem, x + arm * chev[3] * -1, y - arm, x + arm * chev[3], y + 1, color, pen_w);
            line(mem, x + arm * chev[3] * -1, y + arm, x + arm * chev[3], y - 1, color, pen_w);
        }
    }

    // New tab button
    const nr = self.newTabRect(n, width);
    fill(mem, nr, if (std.meta.eql(self.hover, Hit.new_tab)) pal.hover else pal.bar);
    const cx = @divTrunc(nr.left + nr.right, 2);
    const cy = @divTrunc(nr.top + nr.bottom, 2);
    const arm = self.scale(6);
    line(mem, cx - arm, cy, cx + arm + 1, cy, pal.text_dim, pen_w);
    line(mem, cx, cy - arm, cx, cy + arm + 1, pal.text_dim, pen_w);

    // Its arrow, a small chevron.
    const dr = self.newTabMenuRect(n, width);
    fill(mem, dr, if (std.meta.eql(self.hover, Hit.new_tab_menu)) pal.hover else pal.bar);
    const dx = @divTrunc(dr.left + dr.right, 2);
    const dy = @divTrunc(dr.top + dr.bottom, 2);
    const v = self.scale(3);
    line(mem, dx - v, dy - @divTrunc(v, 2), dx, dy + @divTrunc(v, 2) + 1, pal.text_dim, pen_w);
    line(mem, dx + v, dy - @divTrunc(v, 2), dx - 1, dy + @divTrunc(v, 2) + 1, pal.text_dim, pen_w);

    // The main menu's button: three lines.
    const mr = self.menuRect(width);
    fill(mem, mr, if (std.meta.eql(self.hover, Hit.menu)) pal.hover else pal.bar);
    const mx = @divTrunc(mr.left + mr.right, 2);
    const my = @divTrunc(mr.top + mr.bottom, 2);
    const half = self.scale(7);
    const gap = self.scale(5);
    for ([_]c_int{ my - gap, my, my + gap }) |ly| {
        line(mem, mx - half, ly, mx + half + 1, ly, pal.text_dim, pen_w);
    }

    // The tab list's button: three rows, each a dot and a line.
    const lr = self.listRect(width);
    fill(mem, lr, if (std.meta.eql(self.hover, Hit.list)) pal.hover else pal.bar);
    const lx = @divTrunc(lr.left + lr.right, 2);
    const ly0 = @divTrunc(lr.top + lr.bottom, 2);
    const dot = @max(2, self.scale(2));
    for ([_]c_int{ ly0 - gap, ly0, ly0 + gap }) |ly| {
        fill(mem, .{ .left = lx - half, .top = ly - @divTrunc(dot, 2), .right = lx - half + dot, .bottom = ly - @divTrunc(dot, 2) + dot }, pal.text_dim);
        line(mem, lx - half + dot + self.scale(3), ly, lx + half + 1, ly, pal.text_dim, pen_w);
    }

    _ = c.BitBlt(hdc, 0, 0, width, h, mem, 0, 0, c.SRCCOPY);
}

test "hitTest" {
    const testing = std.testing;
    const bar: TabBar = .{};
    // Two tabs in a wide bar: each is tab_max_width wide.
    try testing.expectEqual(Hit{ .tab = 0 }, bar.hitTest(10, 10, 2, 2000));
    try testing.expectEqual(Hit{ .tab = 1 }, bar.hitTest(tab_max_width + 10, 10, 2, 2000));
    try testing.expectEqual(Hit{ .close = 0 }, bar.hitTest(tab_max_width - 12, bar_height / 2, 2, 2000));
    try testing.expectEqual(Hit.new_tab, bar.hitTest(2 * tab_max_width + 5, 10, 2, 2000));
    try testing.expectEqual(Hit.new_tab_menu, bar.hitTest(2 * tab_max_width + button_width + 5, 10, 2, 2000));
    try testing.expectEqual(Hit.menu, bar.hitTest(2000 - 5, 10, 2, 2000));
    try testing.expectEqual(Hit.list, bar.hitTest(2000 - button_width - 5, 10, 2, 2000));
    try testing.expectEqual(Hit.none, bar.hitTest(1500, 10, 2, 2000));
    try testing.expectEqual(Hit.none, bar.hitTest(10, bar_height + 1, 2, 2000));
    try testing.expect(!bar.overflowing(2, 2000));
}

test "no tabs: the header's buttons, + at the left end" {
    const testing = std.testing;
    const bar: TabBar = .{};
    try testing.expectEqual(Hit.new_tab, bar.hitTest(5, 10, 0, 2000));
    try testing.expectEqual(Hit.new_tab_menu, bar.hitTest(button_width + 5, 10, 0, 2000));
    try testing.expectEqual(Hit.menu, bar.hitTest(2000 - 5, 10, 0, 2000));
    try testing.expectEqual(Hit.list, bar.hitTest(2000 - button_width - 5, 10, 0, 2000));
    try testing.expectEqual(Hit.none, bar.hitTest(500, 10, 0, 2000));
    try testing.expect(!bar.overflowing(0, 2000));
}

test "overflow: 40 tabs scroll between the chevrons, all reachable" {
    const testing = std.testing;
    var bar: TabBar = .{};
    const n = 40;
    const width = 500;
    try testing.expect(bar.overflowing(n, width));
    // [‹ 0..22][tabs 22..358][› 358..380][+ 380..414][▾ 414..432][list 432..466][≡ 466..500]
    try testing.expectEqual(Hit.menu, bar.hitTest(width - 5, 10, n, width));
    try testing.expectEqual(Hit.list, bar.hitTest(width - button_width - 5, 10, n, width));
    try testing.expectEqual(Hit.new_tab_menu, bar.hitTest(420, 10, n, width));
    try testing.expectEqual(Hit.new_tab, bar.hitTest(390, 10, n, width));
    try testing.expectEqual(Hit.scroll_left, bar.hitTest(5, 10, n, width));
    try testing.expectEqual(Hit.scroll_right, bar.hitTest(365, 10, n, width));
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
