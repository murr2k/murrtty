//! GDI drawing shared by the window's chrome: the header bar (roadmap 4.3)
//! and the tab strip. Colors, the chrome's fonts, and the shapes GTK's
//! symbolic icons are drawn with.
const std = @import("std");
const configpkg = @import("../../config.zig");
const c = @import("c.zig");

pub const Color = configpkg.Config.Color;

/// The chrome's colors, as libadwaita mixes them from a bar and its text
/// (`theme`, `palette`).
pub const Palette = struct {
    bar: c.COLORREF,
    /// A selected tab, and hovered.
    active: c.COLORREF,
    active_hover: c.COLORREF,
    /// A flat button or tab hovered, and pressed.
    hover: c.COLORREF,
    pressed: c.COLORREF,
    text: c.COLORREF,
    /// Text at libadwaita's dim opacity.
    text_dim: c.COLORREF,
    /// Separators between tabs, at its border opacity.
    separator: c.COLORREF,
    /// The line under the header bar (libadwaita's shade).
    shade: c.COLORREF,
    /// The window controls' circles: at rest, hovered, pressed.
    control: c.COLORREF,
    control_hover: c.COLORREF,
    control_pressed: c.COLORREF,
};

/// What the chrome's colors come from (roadmap 4.3, the Look rule).
pub const Theme = struct {
    /// The header bar's background and text color.
    bar: Color,
    fg: Color,
    /// The bar while the window is inactive (libadwaita's backdrop).
    backdrop: Color,
    /// How dark the shade under the bar is.
    shade: f32,
    dark: bool,
};

/// libadwaita's colors (its stylesheet, 1.8): the header bar, its text
/// (rgb(0 0 6 / 80%) over it, in light), the window's background (the
/// backdrop), the shade's opacity.
pub fn adwaita(dark: bool) Theme {
    return if (dark) .{
        .bar = .{ .r = 0x2e, .g = 0x2e, .b = 0x32 },
        .fg = .{ .r = 0xff, .g = 0xff, .b = 0xff },
        .backdrop = .{ .r = 0x22, .g = 0x22, .b = 0x26 },
        .shade = 0.36,
        .dark = true,
    } else .{
        .bar = .{ .r = 0xff, .g = 0xff, .b = 0xff },
        .fg = blend(.{ .r = 0xff, .g = 0xff, .b = 0xff }, ink, 0.8),
        .backdrop = .{ .r = 0xfa, .g = 0xfa, .b = 0xfb },
        .shade = 0.12,
        .dark = false,
    };
}

/// GTK's `window-theme = ghostty`: the bar in the terminal's (or the
/// titlebar options') colors, its backdrop that background at 90% of its
/// OKLab lightness.
pub fn ghosttyTheme(bg: Color, fg: Color) Theme {
    const dark = isDark(bg);
    return .{ .bar = bg, .fg = fg, .backdrop = scaleLightness(bg, 0.9), .shade = if (dark) 0.36 else 0.12, .dark = dark };
}

/// libadwaita's near-black, rgb(0 0 6).
const ink: Color = .{ .r = 0, .g = 0, .b = 6 };

/// The chrome's colors from `theme`, as libadwaita mixes them: hover 7%,
/// pressed 16%, selected 10% (13% hovered) of the text over the bar, the
/// window controls 10/15/30%, separators 15%, dim text 55%. An inactive
/// window shows the backdrop with its contents at half opacity.
pub fn palette(theme: Theme, backdrop: bool) Palette {
    const bar = if (backdrop) theme.backdrop else theme.bar;
    const fg = if (backdrop) blend(bar, theme.fg, 0.5) else theme.fg;
    return .{
        .bar = ref(bar),
        .active = ref(blend(bar, fg, 0.10)),
        .active_hover = ref(blend(bar, fg, 0.13)),
        .hover = ref(blend(bar, fg, 0.07)),
        .pressed = ref(blend(bar, fg, 0.16)),
        .text = ref(fg),
        .text_dim = ref(blend(bar, fg, 0.55)),
        .separator = ref(blend(bar, fg, 0.15)),
        .shade = ref(blend(bar, ink, theme.shade)),
        .control = ref(blend(bar, fg, 0.10)),
        .control_hover = ref(blend(bar, fg, 0.15)),
        .control_pressed = ref(blend(bar, fg, 0.30)),
    };
}

/// Perceived luminance below half (the core's RGB.perceivedLuminance),
/// GTK's test for a dark background.
pub fn isDark(color: Color) bool {
    const r: f64 = @floatFromInt(color.r);
    const g: f64 = @floatFromInt(color.g);
    const b: f64 = @floatFromInt(color.b);
    return (0.299 * r + 0.587 * g + 0.114 * b) / 255.0 < 0.5;
}

/// `color` with its OKLab lightness times `k`, as CSS's
/// `oklab(from color calc(l * k) a b)`.
pub fn scaleLightness(color: Color, k: f32) Color {
    const r = toLinear(color.r);
    const g = toLinear(color.g);
    const b = toLinear(color.b);
    const l_ = std.math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    const m_ = std.math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    const s_ = std.math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    const L = (0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_) * k;
    const A = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_;
    const B = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_;
    const l2 = L + 0.3963377774 * A + 0.2158037573 * B;
    const m2 = L - 0.1055613458 * A - 0.0638541728 * B;
    const s2 = L - 0.0894841775 * A - 1.2914855480 * B;
    const l3 = l2 * l2 * l2;
    const m3 = m2 * m2 * m2;
    const s3 = s2 * s2 * s2;
    return .{
        .r = toSrgb(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3),
        .g = toSrgb(-1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3),
        .b = toSrgb(-0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3),
    };
}

fn toLinear(v: u8) f32 {
    const x = @as(f32, @floatFromInt(v)) / 255.0;
    return if (x <= 0.04045) x / 12.92 else std.math.pow(f32, (x + 0.055) / 1.055, 2.4);
}

fn toSrgb(v: f32) u8 {
    const x = std.math.clamp(v, 0, 1);
    const s = if (x <= 0.0031308) 12.92 * x else 1.055 * std.math.pow(f32, x, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(std.math.clamp(s, 0, 1) * 255.0));
}

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

test "scaleLightness: the same color at 1, darker below" {
    const testing = std.testing;
    for ([_]Color{ .{ .r = 0x28, .g = 0x2c, .b = 0x34 }, .{ .r = 0xfa, .g = 0xfa, .b = 0xfa }, .{ .r = 0x11, .g = 0x22, .b = 0x33 } }) |col| {
        const same = scaleLightness(col, 1.0);
        try testing.expect(@abs(@as(i16, same.r) - col.r) <= 1 and @abs(@as(i16, same.g) - col.g) <= 1 and @abs(@as(i16, same.b) - col.b) <= 1);
        const darker = scaleLightness(col, 0.9);
        try testing.expect(darker.r <= col.r and darker.g <= col.g and darker.b <= col.b);
    }
}

test "palette: libadwaita's mixes" {
    const testing = std.testing;
    // Light text: rgb(0 0 6 / 80%) over white.
    try testing.expectEqual(Color{ .r = 51, .g = 51, .b = 56 }, adwaita(false).fg);
    const dark = palette(adwaita(true), false);
    try testing.expectEqual(ref(blend(.{ .r = 0x2e, .g = 0x2e, .b = 0x32 }, .{ .r = 0xff, .g = 0xff, .b = 0xff }, 0.07)), dark.hover);
    try testing.expectEqual(c.rgb(0x2e, 0x2e, 0x32), dark.bar);
    // Inactive: the window's background.
    try testing.expectEqual(c.rgb(0x22, 0x22, 0x26), palette(adwaita(true), true).bar);
    try testing.expect(isDark(.{ .r = 0x28, .g = 0x2c, .b = 0x34 }) and !isDark(.{ .r = 0xfa, .g = 0xfa, .b = 0xfa }));
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
