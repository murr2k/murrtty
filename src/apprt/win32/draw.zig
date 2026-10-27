//! GDI drawing shared by the window's chrome: the header bar (roadmap 4.3)
//! and the tab strip. Colors, the chrome's fonts, and the shapes GTK's
//! symbolic icons are drawn with.
const std = @import("std");
const configpkg = @import("../../config.zig");
const c = @import("c.zig");

pub const Color = configpkg.Config.Color;

/// The chrome's colors.
pub const Palette = struct {
    bar: c.COLORREF,
    active: c.COLORREF,
    hover: c.COLORREF,
    pressed: c.COLORREF,
    text: c.COLORREF,
    text_dim: c.COLORREF,
    separator: c.COLORREF,
    /// The line under the header bar (libadwaita's shade).
    shade: c.COLORREF,
    /// The window controls' circles: at rest, hovered, pressed.
    control: c.COLORREF,
    control_hover: c.COLORREF,
    control_pressed: c.COLORREF,
};

pub fn blend(a: Color, b: Color, t: f32) Color {
    const f = struct {
        fn ch(x: u8, y: u8, k: f32) u8 {
            const v = @as(f32, @floatFromInt(x)) * (1 - k) + @as(f32, @floatFromInt(y)) * k;
            return @intFromFloat(@round(v));
        }
    }.ch;
    return .{ .r = f(a.r, b.r, t), .g = f(a.g, b.g, t), .b = f(a.b, b.b, t) };
}

pub fn ref(v: Color) c.COLORREF {
    return c.rgb(v.r, v.g, v.b);
}

/// Derive the colors from the terminal's background and foreground so the
/// active tab merges with the terminal below it.
pub fn palette(bg: Color, fg: Color) Palette {
    const bar = blend(bg, .{ .r = 0, .g = 0, .b = 0 }, 0.25);
    return .{
        .bar = ref(bar),
        .active = ref(bg),
        .hover = ref(blend(bar, fg, 0.08)),
        .pressed = ref(blend(bar, fg, 0.16)),
        .text = ref(fg),
        .text_dim = ref(blend(fg, bg, 0.45)),
        .separator = ref(blend(fg, bg, 0.8)),
        .shade = ref(blend(bar, .{ .r = 0, .g = 0, .b = 0 }, 0.36)),
        .control = ref(blend(bar, fg, 0.10)),
        .control_hover = ref(blend(bar, fg, 0.15)),
        .control_pressed = ref(blend(bar, fg, 0.30)),
    };
}

/// `v` device-independent pixels at `dpi`.
pub fn scale(dpi: c.UINT, v: c_int) c_int {
    return @intCast(@divTrunc(@as(i64, v) * dpi, c.USER_DEFAULT_SCREEN_DPI));
}

pub fn contains(r: c.RECT, x: c_int, y: c_int) bool {
    return x >= r.left and x < r.right and y >= r.top and y < r.bottom;
}

pub fn fill(hdc: c.HDC, r: c.RECT, color: c.COLORREF) void {
    const brush = c.CreateSolidBrush(color) orelse return;
    defer _ = c.DeleteObject(brush);
    _ = c.FillRect(hdc, &r, brush);
}

pub fn line(hdc: c.HDC, x0: c_int, y0: c_int, x1: c_int, y1: c_int, color: c.COLORREF, width: c_int) void {
    const pen = c.CreatePen(c.PS_SOLID, width, color) orelse return;
    defer _ = c.DeleteObject(pen);
    const old = c.SelectObject(hdc, pen);
    defer _ = c.SelectObject(hdc, old);
    _ = c.MoveToEx(hdc, x0, y0, null);
    _ = c.LineTo(hdc, x1, y1);
}

/// A rounded rectangle, filled with `fill_color` and/or outlined in
/// `outline`, `width` pixels wide.
pub fn roundRect(hdc: c.HDC, r: c.RECT, radius: c_int, fill_color: ?c.COLORREF, outline: ?c.COLORREF, width: c_int) void {
    const pen = if (outline) |o| c.CreatePen(c.PS_SOLID, width, o) else null;
    defer if (pen) |p| {
        _ = c.DeleteObject(p);
    };
    const brush = if (fill_color) |f| c.CreateSolidBrush(f) else null;
    defer if (brush) |b| {
        _ = c.DeleteObject(b);
    };
    const old_pen = c.SelectObject(hdc, pen orelse c.GetStockObject(c.NULL_PEN));
    defer _ = c.SelectObject(hdc, old_pen);
    const old_brush = c.SelectObject(hdc, if (brush) |b| @ptrCast(b) else c.GetStockObject(c.NULL_BRUSH));
    defer _ = c.SelectObject(hdc, old_brush);
    // RoundRect's edge runs inside the right and bottom bounds.
    const extra: c_int = if (outline != null) 0 else 1;
    _ = c.RoundRect(hdc, r.left, r.top, r.right + extra, r.bottom + extra, radius * 2, radius * 2);
}

/// A filled triangle pointing down, `half` pixels either side of x and
/// `tall` pixels tall, centered on (x, y).
pub fn triangleDown(hdc: c.HDC, x: c_int, y: c_int, half: c_int, tall: c_int, color: c.COLORREF) void {
    const top = y - @divTrunc(tall, 2);
    const pts = [_]c.POINT{
        .{ .x = x - half, .y = top },
        .{ .x = x + half, .y = top },
        .{ .x = x, .y = top + tall },
    };
    const pen = c.CreatePen(c.PS_SOLID, 1, color) orelse return;
    defer _ = c.DeleteObject(pen);
    const brush = c.CreateSolidBrush(color) orelse return;
    defer _ = c.DeleteObject(brush);
    const old_pen = c.SelectObject(hdc, pen);
    defer _ = c.SelectObject(hdc, old_pen);
    const old_brush = c.SelectObject(hdc, @ptrCast(brush));
    defer _ = c.SelectObject(hdc, old_brush);
    _ = c.Polygon(hdc, &pts, pts.len);
}

/// The chrome's font at `dpi`: the system's message font, in `family` if
/// set (window-title-font-family), bold if asked.
pub fn chromeFont(dpi: c.UINT, family: ?[]const u8, bold: bool) ?c.HFONT {
    var ncm: c.NONCLIENTMETRICSW = .{};
    if (c.SystemParametersInfoForDpi(c.SPI_GETNONCLIENTMETRICS, @sizeOf(c.NONCLIENTMETRICSW), &ncm, 0, dpi) == 0) return null;
    var lf = ncm.lfMessageFont;
    if (family) |name| setFace(&lf, name);
    if (bold) lf.lfWeight = 700;
    return c.CreateFontIndirectW(&lf);
}

/// `name` as the font's face, if it fits LOGFONT's 31 characters.
fn setFace(lf: *c.LOGFONTW, name: []const u8) void {
    // utf8ToUtf16Le assumes the output fits: measure first.
    const len = std.unicode.calcUtf16LeLen(name) catch return;
    if (len == 0 or len > 31) return;
    var wide: [31]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, name) catch return;
    lf.lfFaceName = @splat(0);
    @memcpy(lf.lfFaceName[0..n], wide[0..n]);
}

/// A font's face, for the GUI tests' dump.
pub fn faceName(font: ?c.HFONT, buf: []u8) []const u8 {
    const f = font orelse return "";
    var lf: c.LOGFONTW = undefined;
    if (c.GetObjectW(f, @sizeOf(c.LOGFONTW), &lf) == 0) return "";
    const face = std.mem.sliceTo(&lf.lfFaceName, 0);
    const n = std.unicode.utf16LeToUtf8(buf, face) catch return "";
    return buf[0..n];
}

test "setFace: a family longer than LOGFONT holds leaves the face alone" {
    const testing = std.testing;
    var lf: c.LOGFONTW = std.mem.zeroes(c.LOGFONTW);
    setFace(&lf, "Consolas");
    const consolas = std.unicode.utf8ToUtf16LeStringLiteral("Consolas");
    try testing.expectEqualSlices(u16, consolas, std.mem.sliceTo(&lf.lfFaceName, 0));
    // 34 characters: this used to write past the conversion buffer.
    setFace(&lf, "Segoe UI Variable Display Semibold");
    try testing.expectEqualSlices(u16, consolas, std.mem.sliceTo(&lf.lfFaceName, 0));
    setFace(&lf, "abcdefghijklmnopqrstuvwxyz01234");
    try testing.expectEqual(@as(usize, 31), std.mem.sliceTo(&lf.lfFaceName, 0).len);
}
