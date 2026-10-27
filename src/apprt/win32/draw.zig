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
    /// The split button's divider (30%, as GTK's measures).
    divider: c.COLORREF,
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
    /// The window's background (libadwaita's window-bg-color): a flat
    /// bar's, and the split dividers'.
    window: Color,
    /// Menus' background and text (libadwaita's popover colors).
    popover: Color,
    popover_fg: Color,
    /// The opacity of the shade color (`shade_color`), which the top bars
    /// cast onto the content (`shadeAlpha`).
    shade: f32,
    dark: bool,

    /// What the top bars cast onto the content for `style`
    /// (gtk-toolbar-style): nothing, the shadow, or a line in the darker
    /// shade color (rgb(0 0 12 / 90%) dark, rgb(0 0 6 / 12%) light).
    pub fn shadeFor(self: Theme, style: ToolbarStyle) Shade {
        return switch (style) {
            .flat => .none,
            .raised => .{ .shadow = self.shade },
            .@"raised-border" => .{ .border = if (self.dark)
                .{ .color = .{ .r = 0, .g = 0, .b = 12 }, .alpha = 0.9 }
            else
                .{ .color = ink, .alpha = 0.12 } },
        };
    }
};

pub const ToolbarStyle = configpkg.Config.GtkToolbarStyle;

/// libadwaita's colors (its stylesheet, 1.8): the header bar, its text
/// (rgb(0 0 6 / 80%) over it, in light), the window's background (the
/// backdrop), the shade's opacity.
pub fn adwaita(dark: bool) Theme {
    return if (dark) .{
        .bar = .{ .r = 0x2e, .g = 0x2e, .b = 0x32 },
        .fg = .{ .r = 0xff, .g = 0xff, .b = 0xff },
        .backdrop = .{ .r = 0x22, .g = 0x22, .b = 0x26 },
        .window = .{ .r = 0x22, .g = 0x22, .b = 0x26 },
        .popover = .{ .r = 0x36, .g = 0x36, .b = 0x3a },
        .popover_fg = .{ .r = 0xff, .g = 0xff, .b = 0xff },
        .shade = 0.36,
        .dark = true,
    } else .{
        .bar = .{ .r = 0xff, .g = 0xff, .b = 0xff },
        .fg = blend(.{ .r = 0xff, .g = 0xff, .b = 0xff }, ink, 0.8),
        .backdrop = .{ .r = 0xfa, .g = 0xfa, .b = 0xfb },
        .window = .{ .r = 0xfa, .g = 0xfa, .b = 0xfb },
        .popover = .{ .r = 0xff, .g = 0xff, .b = 0xff },
        .popover_fg = blend(.{ .r = 0xff, .g = 0xff, .b = 0xff }, ink, 0.8),
        .shade = 0.12,
        .dark = false,
    };
}

/// GTK's `window-theme = ghostty`: the bar and the window's background in
/// the terminal's (or the titlebar options') colors, the bar's backdrop
/// that background at 90% of its OKLab lightness.
pub fn ghosttyTheme(bg: Color, fg: Color) Theme {
    const dark = isDark(bg);
    return .{
        .bar = bg,
        .fg = fg,
        .backdrop = scaleLightness(bg, 0.9),
        .window = bg,
        .popover = bg,
        .popover_fg = fg,
        .shade = if (dark) 0.36 else 0.12,
        .dark = dark,
    };
}

/// A menu's colors (libadwaita's popover menu, as measured on GTK's): the
/// text over the popover, a binding at 55%, a grayed item at 50%, a
/// hovered row 10%, separators 15%.
pub const MenuPalette = struct {
    bg: c.COLORREF,
    text: c.COLORREF,
    dim: c.COLORREF,
    disabled: c.COLORREF,
    hover: c.COLORREF,
    separator: c.COLORREF,
};

/// An alert dialog's colors (libadwaita's stylesheet): the dialog's
/// background and text, its plain buttons at 10% of the text (15% hovered,
/// 30% pressed), a destructive one's text in the destructive color over
/// 15% of it, a suggested one white over the accent (GNOME's blue).
pub const DialogPalette = struct {
    bg: c.COLORREF,
    text: c.COLORREF,
    button: c.COLORREF,
    button_hover: c.COLORREF,
    button_pressed: c.COLORREF,
    destructive_text: c.COLORREF,
    destructive: c.COLORREF,
    destructive_pressed: c.COLORREF,
    suggested_text: c.COLORREF,
    suggested: c.COLORREF,
    suggested_pressed: c.COLORREF,
    /// The keyboard focus ring: the accent at half opacity.
    focus: c.COLORREF,
    /// A text box's background (libadwaita's view color), a card's (the
    /// "Remember choice" row), a row's subtitle at 55%, a switch's track
    /// off (15% of the text) and on (the accent), and its knob.
    view: c.COLORREF,
    card: c.COLORREF,
    subtitle: c.COLORREF,
    switch_off: c.COLORREF,
    switch_on: c.COLORREF,
    knob: c.COLORREF,
};

pub fn dialogPalette(dark: bool) DialogPalette {
    const bg: Color = if (dark) .{ .r = 0x36, .g = 0x36, .b = 0x3a } else .{ .r = 0xfa, .g = 0xfa, .b = 0xfb };
    const white: Color = .{ .r = 0xff, .g = 0xff, .b = 0xff };
    const fg: Color = if (dark) white else blend(white, ink, 0.8);
    // destructive-bg is red_4 in dark, red_3 in light; the destructive
    // color its OKLab lightness raised to 0.85 in dark, lowered to 0.5 in
    // light.
    const red: Color = if (dark) .{ .r = 0xc0, .g = 0x1c, .b = 0x28 } else .{ .r = 0xe0, .g = 0x1b, .b = 0x24 };
    const destructive = clampLightness(red, if (dark) 0.85 else 0.0, if (dark) 1.0 else 0.5);
    const accent: Color = .{ .r = 0x35, .g = 0x84, .b = 0xe4 };
    return .{
        .bg = ref(bg),
        .text = ref(fg),
        .button = ref(blend(bg, fg, 0.10)),
        .button_hover = ref(blend(bg, fg, 0.15)),
        .button_pressed = ref(blend(bg, fg, 0.30)),
        .destructive_text = ref(destructive),
        .destructive = ref(blend(bg, destructive, 0.15)),
        .destructive_pressed = ref(blend(bg, destructive, 0.35)),
        .suggested_text = ref(white),
        .suggested = ref(accent),
        .suggested_pressed = ref(blend(accent, white, 0.10)),
        .focus = ref(blend(bg, accent, 0.5)),
        // view-bg #1d1d20 in dark; card-bg white at 8% over the dialog.
        .view = ref(if (dark) .{ .r = 0x1d, .g = 0x1d, .b = 0x20 } else white),
        .card = ref(if (dark) blend(bg, white, 0.08) else white),
        .subtitle = ref(blend(bg, fg, 0.55)),
        .switch_off = ref(blend(bg, fg, 0.15)),
        .switch_on = ref(accent),
        .knob = ref(white),
    };
}

/// `color` with its OKLab lightness kept between `lo` and `hi`, as CSS's
/// `oklab(from color max(l, lo) a b)` and `min(l, hi)`.
pub fn clampLightness(color: Color, lo: f32, hi: f32) Color {
    const r = toLinear(color.r);
    const g = toLinear(color.g);
    const b = toLinear(color.b);
    const l_ = std.math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    const m_ = std.math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    const s_ = std.math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    const L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_;
    if (L <= 0) return color;
    return scaleLightness(color, std.math.clamp(L, lo, hi) / L);
}

pub fn menuPalette(theme: Theme) MenuPalette {
    const bg = theme.popover;
    const fg = theme.popover_fg;
    return .{
        .bg = ref(bg),
        .text = ref(fg),
        .dim = ref(blend(bg, fg, 0.55)),
        .disabled = ref(blend(bg, fg, 0.5)),
        .hover = ref(blend(bg, fg, 0.10)),
        .separator = ref(blend(bg, fg, 0.15)),
    };
}

/// libadwaita's near-black, rgb(0 0 6).
const ink: Color = .{ .r = 0, .g = 0, .b = 6 };

/// The shade's color, at the theme's `shade` opacity.
pub const shade_color = ink;

/// What the top bars cast onto the content below (Theme.shadeFor).
pub const Shade = union(enum) {
    none,
    /// libadwaita's raised bar: the shadow (`shadeAlpha`) of the shade
    /// color at this opacity.
    shadow: f32,
    /// raised-border: a 1 px line.
    border: struct { color: Color, alpha: f32 },

    /// The rows from the bars' edge it covers at `dpi`.
    pub fn rows(self: Shade, dpi: c.UINT) u32 {
        return switch (self) {
            .none => 0,
            .shadow => shadeRows(dpi),
            .border => (dpi + c.USER_DEFAULT_SCREEN_DPI - 1) / c.USER_DEFAULT_SCREEN_DPI,
        };
    }

    pub fn color(self: Shade) Color {
        return switch (self) {
            .none, .shadow => ink,
            .border => |b| b.color,
        };
    }

    /// Its opacity `row` pixels from the bars' edge at `dpi`.
    pub fn alpha(self: Shade, dpi: c.UINT, row: u32) f32 {
        return switch (self) {
            .none => 0,
            .shadow => |a| shadeAlpha(a, dpi, row),
            .border => |b| b.alpha * std.math.clamp(@as(f32, @floatFromInt(dpi)) / c.USER_DEFAULT_SCREEN_DPI - @as(f32, @floatFromInt(row)), 0, 1),
        };
    }

    /// `under` beneath its `row`.
    pub fn over(self: Shade, under: Color, dpi: c.UINT, row: u32) Color {
        return blend(under, self.color(), self.alpha(dpi, row));
    }
};

/// The opacity of the shade the top bars cast onto the content below,
/// `row` pixels from their edge at `dpi`, for a shade color of opacity
/// `shade`. libadwaita's raised top bar (toolbarview > .top-bar.raised)
/// casts `0 1px` and `0 2px 4px`, both in the shade color at half its
/// opacity; a CSS blur of 4 px is a Gaussian of deviation 2 px.
pub fn shadeAlpha(shade: f32, dpi: c.UINT, row: u32) f32 {
    const s = @as(f32, @floatFromInt(dpi)) / c.USER_DEFAULT_SCREEN_DPI;
    const top: f32 = @floatFromInt(row);
    const half = shade * 0.5;
    const edge = std.math.clamp(s - top, 0, 1);
    const blur = normalCdf((2 * s - (top + 0.5)) / (2 * s));
    return 1 - (1 - half * edge) * (1 - half * blur);
}

/// The rows the shade covers at `dpi`: as far as CSS draws the blurred
/// copy, its offset and blur radius (6 px).
pub fn shadeRows(dpi: c.UINT) u32 {
    return (6 * dpi + c.USER_DEFAULT_SCREEN_DPI - 1) / c.USER_DEFAULT_SCREEN_DPI;
}

/// The standard normal distribution's CDF (Abramowitz and Stegun 7.1.26,
/// within 1.5e-7).
fn normalCdf(x: f32) f32 {
    const z = @abs(x) / std.math.sqrt2;
    const t = 1 / (1 + 0.3275911 * z);
    const poly = ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t;
    const erf = 1 - poly * @exp(-z * z);
    return if (x >= 0) 0.5 * (1 + erf) else 0.5 * (1 - erf);
}

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
        .divider = ref(blend(bar, fg, 0.30)),
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

/// A filled polygon in `color`, without an outline.
pub fn polygon(hdc: c.HDC, pts: []const c.POINT, color: c.COLORREF) void {
    const brush = c.CreateSolidBrush(color) orelse return;
    defer _ = c.DeleteObject(brush);
    const old_pen = c.SelectObject(hdc, c.GetStockObject(c.NULL_PEN));
    defer _ = c.SelectObject(hdc, old_pen);
    const old_brush = c.SelectObject(hdc, @ptrCast(brush));
    defer _ = c.SelectObject(hdc, old_brush);
    _ = c.Polygon(hdc, pts.ptr, @intCast(pts.len));
}

/// GTK's window-close glyph: an X of two 2-DIP strokes from corner to
/// corner of `box`, each a filled parallelogram.
pub fn cross(hdc: c.HDC, box: c.RECT, dpi: c.UINT, color: c.COLORREF) void {
    // A band ±t about the box's diagonal is √2·t across: 2 DIP.
    const t: c_int = @intFromFloat(@round(1.414 * @as(f32, @floatFromInt(dpi)) / 96.0));
    polygon(hdc, &.{
        .{ .x = box.left, .y = box.top + t },
        .{ .x = box.left + t, .y = box.top },
        .{ .x = box.right, .y = box.bottom - t },
        .{ .x = box.right - t, .y = box.bottom },
    }, color);
    polygon(hdc, &.{
        .{ .x = box.right - t, .y = box.top },
        .{ .x = box.right, .y = box.top + t },
        .{ .x = box.left + t, .y = box.bottom },
        .{ .x = box.left, .y = box.bottom - t },
    }, color);
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

/// GNOME's interface font, bundled (res/README.md) and registered for this
/// process at startup (registerFonts).
const adwaita_sans = @embedFile("res/AdwaitaSans-Regular.ttf");
/// Its family as GDI names it: a variable font's named instances take the
/// optical size's name too, and Pango's 11 pt is the "Text" size (opsz
/// 14), regular and bold in this family, the other weights in their own
/// ("Adwaita Sans Text SemiBold"). "Adwaita Sans" alone finds nothing.
pub const chrome_family = "Adwaita Sans Text";
/// GNOME's interface font size ("Adwaita Sans 11"), in points.
const chrome_points = 11;

/// Make the bundled font available to this process's GDI, never
/// installed. The handle removes it again; null if Windows refused it.
pub fn registerFonts() ?c.HANDLE {
    var count: c.DWORD = 0;
    const handle = c.AddFontMemResourceEx(@constCast(adwaita_sans.ptr), adwaita_sans.len, null, &count);
    return if (count > 0) handle else null;
}

/// The chrome's font at `dpi`: GNOME's interface font at its size, Adwaita
/// Sans 11, or `family` (window-title-font-family), bold if asked, with
/// grayscale antialiasing as GTK draws text.
pub fn chromeFont(dpi: c.UINT, family: ?[]const u8, bold: bool) ?c.HFONT {
    return chromeFontSized(dpi, family, chrome_points, bold);
}

/// The chrome's font at `points` (an alert dialog's heading is 15).
pub fn chromeFontSized(dpi: c.UINT, family: ?[]const u8, points: c.UINT, bold: bool) ?c.HFONT {
    var lf: c.LOGFONTW = std.mem.zeroes(c.LOGFONTW);
    lf.lfHeight = -@as(c_long, @intCast((points * dpi + 36) / 72));
    lf.lfWeight = if (bold) 700 else 400;
    lf.lfCharSet = 1; // DEFAULT_CHARSET
    lf.lfQuality = 4; // ANTIALIASED_QUALITY
    setFace(&lf, chrome_family);
    if (family) |name| setFace(&lf, name);
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

/// The face GDI chose for a font (a missing family comes out as its
/// substitute), for the GUI tests' dump.
pub fn faceName(font: ?c.HFONT, buf: []u8) []const u8 {
    const f = font orelse return "";
    const dc = c.CreateCompatibleDC(null) orelse return "";
    defer _ = c.DeleteDC(dc);
    const old = c.SelectObject(dc, f);
    defer _ = c.SelectObject(dc, old);
    var face: [64]u16 = undefined;
    const n = c.GetTextFaceW(dc, face.len, &face);
    if (n <= 0) return "";
    const len = std.mem.indexOfScalar(u16, face[0..@intCast(n)], 0) orelse @as(usize, @intCast(n));
    const m = std.unicode.utf16LeToUtf8(buf, face[0..len]) catch return "";
    return buf[0..m];
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

test "shadeAlpha: GTK's shade under its bar at 96 DPI" {
    const testing = std.testing;
    // Measured on GTK's (test/windows/look): the dark shade over the
    // default background, row by row, then nothing.
    const bg: Color = .{ .r = 0x28, .g = 0x2c, .b = 0x34 };
    const want = [_]u8{ 0x1c, 0x24, 0x25, 0x26, 0x27, 0x28 };
    const raised = adwaita(true).shadeFor(.raised);
    try testing.expectEqual(6, raised.rows(96));
    for (want, 0..) |r, k| try testing.expectEqual(r, raised.over(bg, 96, @intCast(k)).r);
    // raised-border: one line of the darker shade (GTK 1.5's measured
    // #040405 in black; the current stylesheet's is rgb(0 0 12)); flat:
    // nothing.
    const border = adwaita(true).shadeFor(.@"raised-border");
    try testing.expectEqual(1, border.rows(96));
    try testing.expectEqual(Color{ .r = 4, .g = 4, .b = 16 }, border.over(bg, 96, 0));
    try testing.expectEqual(2, border.rows(120));
    try testing.expectEqual(0, adwaita(true).shadeFor(.flat).rows(96));
    // Twice the pixels at twice the DPI, as dark at the edge.
    try testing.expectEqual(12, shadeRows(192));
    try testing.expect(@abs(shadeAlpha(0.36, 192, 0) - shadeAlpha(0.36, 96, 0)) < 0.02);
    try testing.expect(shadeAlpha(0.36, 192, 9) > shadeAlpha(0.36, 192, 10));
}

test "chromeFont: the bundled Adwaita Sans, regular and bold" {
    const testing = std.testing;
    const handle = registerFonts() orelse return error.FontNotRegistered;
    defer _ = c.RemoveFontMemResourceEx(handle);
    for ([_]bool{ false, true }) |bold| {
        const font = chromeFont(96, null, bold) orelse return error.NoFont;
        defer _ = c.DeleteObject(font);
        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings(chrome_family, faceName(font, &buf));
    }
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
