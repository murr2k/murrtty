//! A custom-drawn tab strip along the top of a window's client area.
//!
//! Drawn with GDI rather than the common tab control so it can follow
//! the terminal's colors and the dark title bar. The Window owns the
//! tabs; this only lays them out, paints and hit-tests.
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
const close_size = 18;
const text_inset = 12;

font: ?c.HFONT = null,
dpi: c.UINT = c.USER_DEFAULT_SCREEN_DPI,

/// The item under the mouse, for hover highlighting.
hover: Hit = .none,
tracking: bool = false,

pub const Hit = union(enum) {
    none,
    tab: usize,
    close: usize,
    new_tab,
    /// The arrow beside "+": the split menu.
    new_tab_menu,
    /// The main menu's button at the right end.
    menu,

    pub fn eql(a: Hit, b: Hit) bool {
        return std.meta.eql(a, b);
    }
};

pub fn deinit(self: *TabBar) void {
    if (self.font) |f| _ = c.DeleteObject(f);
    self.font = null;
}

/// Recreate the font for the given DPI.
pub fn setDpi(self: *TabBar, dpi: c.UINT) void {
    self.dpi = dpi;
    if (self.font) |f| _ = c.DeleteObject(f);
    self.font = null;

    var ncm: c.NONCLIENTMETRICSW = .{};
    if (c.SystemParametersInfoForDpi(c.SPI_GETNONCLIENTMETRICS, @sizeOf(c.NONCLIENTMETRICSW), &ncm, 0, dpi) != 0) {
        self.font = c.CreateFontIndirectW(&ncm.lfMessageFont);
    }
}

fn scale(self: *const TabBar, v: c_int) c_int {
    return @intCast(@divTrunc(@as(i64, v) * self.dpi, c.USER_DEFAULT_SCREEN_DPI));
}

pub fn height(self: *const TabBar) c_int {
    return self.scale(bar_height);
}

/// The rectangle of tab `i` of `n` in a bar `width` pixels wide.
pub fn tabRect(self: *const TabBar, i: usize, n: usize, width: c_int) c.RECT {
    const avail = @max(0, width - self.scale(button_width + dropdown_width) - self.scale(button_width));
    const per: c_int = @intCast(@divTrunc(avail, @as(c_int, @intCast(@max(n, 1)))));
    const w = std.math.clamp(per, self.scale(tab_min_width), self.scale(tab_max_width));
    const left: c_int = w * @as(c_int, @intCast(i));
    return .{ .left = left, .top = 0, .right = left + w, .bottom = self.height() };
}

/// The main menu's button, at the right end of the bar.
pub fn menuRect(self: *const TabBar, width: c_int) c.RECT {
    return .{ .left = width - self.scale(button_width), .top = 0, .right = width, .bottom = self.height() };
}

pub fn closeRect(self: *const TabBar, tab: c.RECT) c.RECT {
    const s = self.scale(close_size);
    const right = tab.right - self.scale(8);
    const top = @divTrunc(tab.bottom - s, 2);
    return .{ .left = right - s, .top = top, .right = right, .bottom = top + s };
}

/// "+", after the last tab, but never under the menu button (tabs that
/// don't fit run under it until 3.8c's overflow).
pub fn newTabRect(self: *const TabBar, n: usize, width: c_int) c.RECT {
    const last = self.tabRect(n -| 1, n, width);
    const max_left = self.menuRect(width).left - self.scale(button_width + dropdown_width);
    const left = @max(0, @min(if (n == 0) 0 else last.right, max_left));
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
    // The buttons first: tabs that don't fit run under them.
    if (contains(self.menuRect(width), x, y)) return .menu;
    if (contains(self.newTabRect(n, width), x, y)) return .new_tab;
    if (contains(self.newTabMenuRect(n, width), x, y)) return .new_tab_menu;
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
    for (titles, 0..) |title, i| {
        const r = self.tabRect(i, n, width);
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
    try testing.expectEqual(Hit.none, bar.hitTest(1500, 10, 2, 2000));
    try testing.expectEqual(Hit.none, bar.hitTest(10, bar_height + 1, 2, 2000));
    // Many tabs: "+" and its arrow stay clear of the menu button.
    try testing.expectEqual(Hit.menu, bar.hitTest(500 - 5, 10, 40, 500));
    try testing.expectEqual(Hit.new_tab_menu, bar.hitTest(500 - button_width - 5, 10, 40, 500));
}
