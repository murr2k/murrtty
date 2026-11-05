//! murrtty: a selection that always shows and text that can always be read
//! (roadmap F3). Ghostty draws a selection in the colors the config (or its
//! theme) names, and text in the theme's foreground, whatever the
//! background: 108 of the bundled themes name a selection background
//! within a color difference of 10 (CIE76) of their own background (four
//! of them that background exactly), 99 name selected text below 3:1
//! against it, and any theme meets the same with a background color of the
//! user's own, or one a program sets (OSC 11).
//!
//! The renderer asks here once a frame (`Frame.update`) which colors to
//! draw: a highlight too close to the background moves away from it, on
//! along its own way or toward the foreground; selected text below 3:1
//! against the highlight takes the theme's foreground or background, or
//! black or white; default text below 1.5:1 against the background, where
//! a cell has no background of its own, is drawn black or white, and so is
//! a cursor below 1.5:1. Colors that pass are drawn as configured, and
//! nothing in the configuration changes (the file stays Ghostty's). When
//! the default colors change (a program's OSC 10 or 11) every row is built
//! again, as rows already built hold the old choice.
const std = @import("std");
const terminal = @import("../terminal/main.zig");
const configpkg = @import("../config.zig");

const RGB = terminal.color.RGB;
const TerminalColor = configpkg.Config.TerminalColor;

/// The smallest color difference (CIE76) a selection's highlight keeps
/// from the background: below it a block of selected cells is hard to tell
/// from the rest.
pub const min_highlight: f64 = 10;

/// The smallest contrast (WCAG) selected text keeps against its highlight.
pub const min_selected_text: f64 = 3;

/// The contrast (WCAG) below which text in the default foreground is drawn
/// black or white instead: only text no one can read, as with a background
/// set to the theme's foreground.
pub const min_text: f64 = 1.5;

const black: RGB = .{ .r = 0, .g = 0, .b = 0 };
const white: RGB = .{ .r = 255, .g = 255, .b = 255 };

/// The selection colors to draw, as the config's fields (null as Ghostty
/// takes them: the foreground as the highlight, the background as the
/// text).
pub const Selection = struct {
    background: ?TerminalColor,
    foreground: ?TerminalColor,
};

/// The colors chosen for a frame, and the default colors they were chosen
/// for.
pub const Frame = struct {
    background: RGB = .{},
    foreground: RGB = .{},
    selection: Selection = .{ .background = null, .foreground = null },
    /// The default foreground to draw where a cell has no background of its
    /// own.
    text: RGB = .{},
    chosen: bool = false,

    /// Choose for this frame's `background` and `foreground` and the
    /// configured selection colors; true when the default colors differ
    /// from the last frame's, so every row must be built again.
    pub fn update(
        self: *Frame,
        bg_cfg: ?TerminalColor,
        fg_cfg: ?TerminalColor,
        background: RGB,
        foreground: RGB,
    ) bool {
        const changed = !self.chosen or !eql(self.background, background) or !eql(self.foreground, foreground);
        self.* = .{
            .background = background,
            .foreground = foreground,
            .selection = selection(bg_cfg, fg_cfg, background, foreground),
            .text = text(foreground, background),
            .chosen = true,
        };
        return changed;
    }
};

/// The selection colors to draw over `background` with `foreground` the
/// default text, from the configured `bg_cfg` and `fg_cfg`. A highlight
/// following each cell (`cell-foreground`, `cell-background`) is drawn as
/// configured: its colors are the cell's own. Selected text following each
/// cell is too, unless the highlight had to move, when it takes a color
/// readable on it.
pub fn selection(
    bg_cfg: ?TerminalColor,
    fg_cfg: ?TerminalColor,
    background: RGB,
    foreground: RGB,
) Selection {
    const configured: RGB = if (bg_cfg) |v| switch (v) {
        .color => |c| c.toTerminalRGB(),
        .@"cell-foreground", .@"cell-background" => return .{ .background = bg_cfg, .foreground = fg_cfg },
    } else foreground;
    const shown = highlight(configured, background, foreground);
    const wanted_text: RGB = if (fg_cfg) |v| switch (v) {
        .color => |c| c.toTerminalRGB(),
        .@"cell-foreground", .@"cell-background" => return .{
            .background = colorOf(shown),
            .foreground = if (eql(shown, configured))
                fg_cfg
            else
                colorOf(selectedText(foreground, shown, background, foreground)),
        },
    } else background;
    return .{
        .background = colorOf(shown),
        .foreground = colorOf(selectedText(wanted_text, shown, background, foreground)),
    };
}

/// The default foreground to draw text in over `background`, or the
/// cursor in: below `min_text` black or white.
pub fn text(foreground: RGB, background: RGB) RGB {
    if (foreground.contrast(background) >= min_text) return foreground;
    return farthest(background);
}

/// A highlight at least `min_highlight` from `background`: `wanted` if it
/// is, else `wanted` carried further from the background, else a blend of
/// the background toward `foreground`, else black or white.
fn highlight(wanted: RGB, background: RGB, foreground: RGB) RGB {
    if (deltaE(wanted, background) >= min_highlight) return wanted;
    if (!eql(wanted, background)) {
        for ([_]f64{ 1.5, 2, 3, 4, 6, 8, 12 }) |k| {
            const c = lerp(background, wanted, k);
            if (deltaE(c, background) >= min_highlight) return c;
        }
    }
    for ([_]f64{ 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.7, 1 }) |t| {
        const c = lerp(background, foreground, t);
        if (deltaE(c, background) >= min_highlight) return c;
    }
    return farthest(background);
}

/// Selected text at least `min_selected_text` against `shown`: `wanted` if
/// it is, else the first of the theme's foreground, its background, black
/// and white that is, else the one of them with the most contrast.
fn selectedText(wanted: RGB, shown: RGB, background: RGB, foreground: RGB) RGB {
    if (wanted.contrast(shown) >= min_selected_text) return wanted;
    var best = wanted;
    var best_contrast = wanted.contrast(shown);
    for ([_]RGB{ foreground, background, black, white }) |c| {
        const r = c.contrast(shown);
        if (r >= min_selected_text) return c;
        if (r > best_contrast) {
            best = c;
            best_contrast = r;
        }
    }
    return best;
}

/// Black or white, whichever is farther from `c` (by contrast).
fn farthest(c: RGB) RGB {
    return if (black.contrast(c) >= white.contrast(c)) black else white;
}

fn colorOf(c: RGB) TerminalColor {
    return .{ .color = .{ .r = c.r, .g = c.g, .b = c.b } };
}

fn eql(a: RGB, b: RGB) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b;
}

/// `from` + (`to` - `from`) * `t` per channel, clamped (`t` above 1 carries
/// on past `to`).
fn lerp(from: RGB, to: RGB, t: f64) RGB {
    return .{
        .r = channel(from.r, to.r, t),
        .g = channel(from.g, to.g, t),
        .b = channel(from.b, to.b, t),
    };
}

fn channel(from: u8, to: u8, t: f64) u8 {
    const a: f64 = @floatFromInt(from);
    const b: f64 = @floatFromInt(to);
    const v = std.math.clamp(@round(a + (b - a) * t), 0, 255);
    return @intFromFloat(v);
}

/// The CIE76 color difference between `a` and `b` (Euclidean in CIELAB,
/// D65): about 2.3 is just noticeable side by side.
pub fn deltaE(a: RGB, b: RGB) f64 {
    const la = lab(a);
    const lb = lab(b);
    const dl = la[0] - lb[0];
    const da = la[1] - lb[1];
    const db = la[2] - lb[2];
    return @sqrt(dl * dl + da * da + db * db);
}

fn lab(c: RGB) [3]f64 {
    const r = linear(c.r);
    const g = linear(c.g);
    const b = linear(c.b);
    const x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047;
    const y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    const z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883;
    const fx = labF(x);
    const fy = labF(y);
    const fz = labF(z);
    return .{ 116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz) };
}

fn linear(v: u8) f64 {
    const s = @as(f64, @floatFromInt(v)) / 255;
    return if (s <= 0.04045) s / 12.92 else std.math.pow(f64, (s + 0.055) / 1.055, 2.4);
}

fn labF(t: f64) f64 {
    return if (t > 0.008856) std.math.cbrt(t) else 7.787 * t + 16.0 / 116.0;
}

fn rgb(hex: u24) RGB {
    return .{ .r = @truncate(hex >> 16), .g = @truncate(hex >> 8), .b = @truncate(hex) };
}

fn rgbOf(c: ?TerminalColor) RGB {
    return c.?.toTerminalRGB().?;
}

test "readable: a selection the background hides shows" {
    // Everblush: the selection background is the background itself.
    const bg = rgb(0x141b1e);
    const fg = rgb(0xdadada);
    const s = selection(colorOf(bg), colorOf(fg), bg, fg);
    const shown = rgbOf(s.background);
    try std.testing.expect(deltaE(shown, bg) >= min_highlight);
    try std.testing.expect(rgbOf(s.foreground).contrast(shown) >= min_selected_text);
}

test "readable: a faint selection goes on its own way" {
    // Nearly the background, a little warmer: it stays that hue, further.
    const bg = rgb(0xfdf6e3);
    const sel = rgb(0xf6efda);
    const s = selection(colorOf(sel), null, bg, rgb(0x657b83));
    const shown = rgbOf(s.background);
    try std.testing.expect(deltaE(shown, bg) >= min_highlight);
    try std.testing.expect(shown.r <= sel.r and shown.g <= sel.g and shown.b <= sel.b);
}

test "readable: a visible selection is drawn as configured" {
    const bg = rgb(0x282c34);
    const sel = rgb(0x5c6370);
    const sel_fg = rgb(0xffffff);
    const s = selection(colorOf(sel), colorOf(sel_fg), bg, rgb(0xabb2bf));
    try std.testing.expect(eql(rgbOf(s.background), sel));
    try std.testing.expect(eql(rgbOf(s.foreground), sel_fg));
}

test "readable: no selection colors are Ghostty's inverse" {
    const bg = rgb(0x282c34);
    const fg = rgb(0xffffff);
    const s = selection(null, null, bg, fg);
    try std.testing.expect(eql(rgbOf(s.background), fg));
    try std.testing.expect(eql(rgbOf(s.foreground), bg));
}

test "readable: unreadable selected text takes a readable color" {
    const bg = rgb(0x000000);
    const sel = rgb(0x808080);
    const s = selection(colorOf(sel), colorOf(rgb(0x8a8a8a)), bg, rgb(0xeeeeee));
    try std.testing.expect(rgbOf(s.foreground).contrast(rgbOf(s.background)) >= min_selected_text);
}

test "readable: a background equal to the foreground still shows a selection" {
    // A background set to the theme's foreground, no selection colors.
    const c = rgb(0xc0c0c0);
    const s = selection(null, null, c, c);
    try std.testing.expect(deltaE(rgbOf(s.background), c) >= min_highlight);
    try std.testing.expect(rgbOf(s.foreground).contrast(rgbOf(s.background)) >= min_selected_text);
}

test "readable: per-cell selection colors pass through" {
    const s = selection(.@"cell-foreground", .@"cell-background", rgb(0), rgb(0xffffff));
    try std.testing.expect(s.background.? == .@"cell-foreground");
    try std.testing.expect(s.foreground.? == .@"cell-background");
}

test "readable: per-cell selected text reads on a highlight that moved" {
    // A background equal to the foreground: the highlight moves to black
    // or white, and the cell's own text (the default, substituted the same
    // way) would vanish on it.
    const c = rgb(0x111111);
    const s = selection(colorOf(c), .@"cell-foreground", c, c);
    const shown = rgbOf(s.background);
    try std.testing.expect(rgbOf(s.foreground).contrast(shown) >= min_selected_text);
    // A highlight that didn't move keeps the per-cell text.
    const kept = selection(colorOf(rgb(0x5c6370)), .@"cell-foreground", rgb(0x282c34), rgb(0xabb2bf));
    try std.testing.expect(kept.foreground.? == .@"cell-foreground");
}

test "readable: a frame says when the default colors change" {
    var f: Frame = .{};
    try std.testing.expect(f.update(null, null, rgb(0x141b1e), rgb(0xdadada)));
    try std.testing.expect(!f.update(null, null, rgb(0x141b1e), rgb(0xdadada)));
    // A program's OSC 11.
    try std.testing.expect(f.update(null, null, rgb(0xdadada), rgb(0xdadada)));
    try std.testing.expect(eql(f.text, black));
}

test "readable: default text no one can read is drawn black or white" {
    try std.testing.expect(eql(text(rgb(0x202020), rgb(0x222222)), white));
    try std.testing.expect(eql(text(rgb(0xf0f0f0), rgb(0xeeeeee)), black));
    // Dim but readable stays (Darkermatrix's 1.9:1).
    const dim = rgb(0x35451a);
    try std.testing.expect(eql(text(dim, rgb(0x070c0e)), dim));
}
