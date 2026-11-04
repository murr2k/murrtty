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
//!
//! murrtty's own: after the split button, a bell for each pane waiting for
//! its user (Waiting), up to where the title is centered, so their coming
//! never moves it. Before the tab list's button, the update pill (roadmap
//! 7.6a), macOS Ghostty's: hidden when there is nothing to say.
const HeaderBar = @This();

const std = @import("std");
const c = @import("c.zig");
const draw = @import("draw.zig");
const text_util = @import("text.zig");
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
/// A waiting pane's bell: as tall as a button, narrower, so more fit.
const bell_width = 28;
/// The update pill: a capsule as macOS Ghostty's (its 11 pt text, 8 and 4
/// px of padding, a 14 px badge), in libadwaita's metrics.
const pill_height = 26;
const pill_pad = 10;
const pill_icon = 14;
const pill_gap = 6;
const pill_max = 64;

/// How the update pill looks, by what it says (macOS Ghostty's colors):
/// the window controls' gray while checking, the accent for an update, the
/// accent darkened for the permission request and "no updates", orange for
/// a failure.
pub const PillLook = enum { hidden, plain, accent, accent_dim, accent_dark, warning };

dpi: c.UINT = c.USER_DEFAULT_SCREEN_DPI,
title_font: ?c.HFONT = null,
/// gtk-titlebar-style = tabs: the buttons go in the tab row, which is the
/// title bar (GTK's tab bar then holds the split button at its start and
/// the tab list's and menu's buttons and the window's at its end, those
/// side by side), and the tabs take the title's place.
tabs_style: bool = false,
/// Whether the window's buttons show (client-side decorations).
controls: bool = true,
/// How many panes wait (Waiting): a bell each, as many as fit (bellPlace).
bells: usize = 0,
/// The title's width as last painted, in pixels (0 for none): the bells
/// stop where it is centered.
title_px: c_int = 0,
/// The update pill: its look, its text (UTF-16) and that text's width in
/// pixels, measured as it is set (setPill), so placing it needs no DC; at
/// least the width of `pill_widest` (a progress's "Downloading: 100%", as
/// macOS Ghostty's, so the pill keeps its size as the number grows).
pill: PillLook = .hidden,
pill_text: [pill_max]u16 = undefined,
pill_len: usize = 0,
pill_widest: [pill_max]u16 = undefined,
pill_widest_len: usize = 0,
pill_px: c_int = 0,
pill_font: ?c.HFONT = null,

pub fn deinit(self: *HeaderBar) void {
    if (self.title_font) |f| _ = c.DeleteObject(f);
    self.title_font = null;
    if (self.pill_font) |f| _ = c.DeleteObject(f);
    self.pill_font = null;
}

/// Recreate the title's font for `dpi`: bold, in `family` if set
/// (window-title-font-family).
pub fn setDpi(self: *HeaderBar, dpi: c.UINT, family: ?[]const u8) void {
    self.dpi = dpi;
    if (self.title_font) |f| _ = c.DeleteObject(f);
    self.title_font = draw.chromeFont(dpi, family, true);
    if (self.pill_font) |f| _ = c.DeleteObject(f);
    self.pill_font = draw.chromeFontSized(dpi, null, 9, true);
    self.measurePill();
}

/// Show the update pill as `look` with `text` (UTF-8), at least as wide as
/// `widest` would be ("" for no minimum), or hide it.
pub fn setPill(self: *HeaderBar, look: PillLook, text: []const u8, widest: []const u8) void {
    var wide: [pill_max]u16 = undefined;
    const w = text_util.utf16Into(&wide, if (look == .hidden) "" else text);
    var wide_widest: [pill_max]u16 = undefined;
    const ww = text_util.utf16Into(&wide_widest, if (look == .hidden) "" else widest);
    if (look == self.pill and std.mem.eql(u16, w, self.pill_text[0..self.pill_len]) and
        std.mem.eql(u16, ww, self.pill_widest[0..self.pill_widest_len])) return;
    self.pill = look;
    @memcpy(self.pill_text[0..w.len], w);
    self.pill_len = w.len;
    @memcpy(self.pill_widest[0..ww.len], ww);
    self.pill_widest_len = ww.len;
    self.measurePill();
}

fn measurePill(self: *HeaderBar) void {
    self.pill_px = 0;
    if (self.pill == .hidden or self.pill_len == 0) return;
    const dc = c.GetDC(null) orelse return;
    defer _ = c.ReleaseDC(null, dc);
    const old = if (self.pill_font) |f| c.SelectObject(dc, f) else null;
    defer if (old) |o| {
        _ = c.SelectObject(dc, o);
    };
    var r: c.RECT = .{};
    _ = c.DrawTextW(dc, &self.pill_text, @intCast(self.pill_len), &r, c.DT_CALCRECT | c.DT_SINGLELINE | c.DT_NOPREFIX);
    self.pill_px = @max(0, r.right - r.left);
    if (self.pill_widest_len > 0) {
        var rw: c.RECT = .{};
        _ = c.DrawTextW(dc, &self.pill_widest, @intCast(self.pill_widest_len), &rw, c.DT_CALCRECT | c.DT_SINGLELINE | c.DT_NOPREFIX);
        self.pill_px = @max(self.pill_px, rw.right - rw.left);
    }
}

/// Where the update pill goes in a bar `width` pixels wide: before the tab
/// list's button, GTK's spacing apart. Null while it is hidden, or with no
/// room for it after the split button (in the tab row, and a narrowest
/// tab's): the title then ellipsizes first.
pub fn pillPlace(self: *const HeaderBar, width: c_int) ?c.RECT {
    if (self.pill == .hidden or self.pill_px <= 0) return null;
    const p = self.place(width);
    const w = self.scale(2 * pill_pad + pill_icon + pill_gap) + self.pill_px;
    const right = p.list.left - self.scale(spacing);
    const left = right - w;
    const lo = p.new_tab_menu.right + self.scale(spacing) + (if (self.tabs_style) self.scale(min_tab) else 0);
    if (left < lo) return null;
    const top = self.scale(pad_top) + @divTrunc(self.scale(button) - self.scale(pill_height), 2);
    return .{ .left = left, .top = top, .right = right, .bottom = top + self.scale(pill_height) };
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

/// tabsInset in a row `width` pixels wide, after the bells shown there.
pub fn tabsInsetAt(self: *const HeaderBar, width: c_int) [2]c_int {
    var inset = self.tabsInset();
    const b = self.bellPlace(width);
    if (b.shown > 0) inset[0] = b.end();
    // The update pill takes the tabs' end.
    if (self.pillPlace(width)) |r| inset[1] = width - r.left + self.scale(spacing);
    return inset;
}

/// The waiting panes' bells (Waiting): after the split button, side by
/// side, oldest first, `shown` of them from `start`. With `more`, the last
/// stands for every pane from it on (more wait than fit), showing their
/// count.
pub const Bells = struct {
    start: c_int,
    width: c_int,
    shown: usize = 0,
    more: bool = false,

    /// Bell `i`'s column, from `top` to `bottom`.
    pub fn rect(b: Bells, i: usize, top: c_int, bottom: c_int) c.RECT {
        const left = b.start + b.width * @as(c_int, @intCast(i));
        return .{ .left = left, .top = top, .right = left + b.width, .bottom = bottom };
    }

    /// Where the bells end (their start with none).
    pub fn end(b: Bells) c_int {
        return b.start + b.width * @as(c_int, @intCast(b.shown));
    }

    /// Whether bell `i` stands for the rest.
    pub fn isMore(b: Bells, i: usize) bool {
        return b.more and i + 1 == b.shown;
    }
};

/// Where the bells go in a bar `width` pixels wide: in the header bar up
/// to where the title is centered without them, so their coming never
/// moves it (the owner's design), and at least one while there is room
/// before the tab list's button, the title then making way; in the tab row
/// as the title bar (tabs_style), in the first half of the tabs' span and
/// leaving a narrowest tab's room, so many waiting never crowd the tabs
/// out (the rest share the last bell).
pub fn bellPlace(self: *const HeaderBar, width: c_int) Bells {
    const p = self.place(width);
    const bw = self.scale(bell_width);
    const start = p.new_tab_menu.right + self.scale(spacing);
    var b: Bells = .{ .start = start, .width = bw };
    if (self.bells == 0) return b;
    const room = (if (self.pillPlace(width)) |r| r.left else p.list.left) - self.scale(spacing);
    const edge = if (self.pillPlace(width)) |r| r.left else p.list.left;
    const limit = if (self.tabs_style)
        @min(edge - self.scale(min_tab), start + @divTrunc(edge - start, 2))
    else if (self.titlePlace(p, width, b)) |t|
        t[0] - self.scale(spacing)
    else
        room;
    var fit: usize = if (limit > start) @intCast(@divTrunc(limit - start, bw)) else 0;
    if (fit == 0 and !self.tabs_style and start + bw <= room) fit = 1;
    b.shown = @min(self.bells, fit);
    b.more = self.bells > b.shown and b.shown > 0;
    return b;
}

/// Where the title goes in a bar `width` pixels wide, as last measured:
/// after the bells that show, or as if none did (the test hooks').
pub fn titleAt(self: *const HeaderBar, width: c_int, with_bells: bool) ?[2]c_int {
    const p = self.place(width);
    const none: Bells = .{ .start = 0, .width = 0 };
    return self.titlePlace(p, width, if (with_bells) self.bellPlace(width) else none);
}

/// Where the title goes (`title_px` wide): centered on the bar between
/// the split button and the tab list's button, and after the bells that
/// show. Its left edge and width, or null with no title or no room.
fn titlePlace(self: *const HeaderBar, p: Place, width: c_int, bells: Bells) ?[2]c_int {
    var lo = p.new_tab_menu.right + self.scale(spacing + 12);
    const hi = (if (self.pillPlace(width)) |r| r.left else p.list.left) - self.scale(spacing + 12);
    if (bells.shown > 0) lo = @max(lo, bells.end() + self.scale(spacing));
    if (self.title_px <= 0 or hi <= lo) return null;
    const tw = @min(self.title_px, hi - lo);
    return .{ std.math.clamp(@divTrunc(width - tw, 2), lo, hi - tw), tw };
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
    if (self.pillPlace(width)) |r| if (x >= r.left and x < r.right) return .update;
    const b = self.bellPlace(width);
    for (0..b.shown) |i| {
        const r = b.rect(i, 0, 0);
        if (x >= r.left and x < r.right) return .{ .bell = i };
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
/// Keeps the title's width (title_px), which places the bells.
pub fn paint(
    self: *HeaderBar,
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

    // The title's font, for the title and the overflowing bell's count;
    // the title measured first, as the bells stop where it goes.
    const old_font = if (self.title_font) |f| c.SelectObject(mem, f) else null;
    defer if (old_font) |f| {
        _ = c.SelectObject(mem, f);
    };
    self.title_px = 0;
    if (title.len > 0 and !self.tabs_style) {
        var measure: c.RECT = .{ .right = width, .bottom = h };
        _ = c.DrawTextW(mem, title.ptr, @intCast(title.len), &measure, c.DT_SINGLELINE | c.DT_CALCRECT | c.DT_NOPREFIX);
        self.title_px = @max(0, measure.right - measure.left);
    }
    const bells = self.bellPlace(width);

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

    // The waiting panes' bells; the last, when more wait than fit, the
    // count of those it stands for.
    _ = c.SetTextColor(mem, pal.text);
    for (0..bells.shown) |i| {
        const r = bells.rect(i, p.new_tab.top, p.new_tab.bottom);
        _ = self.buttonBack(mem, r, state(.{ .bell = i }, hover, pressed), pal);
        if (bells.isMore(i)) {
            var buf: [12]u8 = undefined;
            const label = std.fmt.bufPrint(&buf, "+{d}", .{self.bells - i}) catch "+";
            var wide: [12]u16 = undefined;
            for (label, 0..) |ch, k| wide[k] = ch;
            var box = r;
            _ = c.DrawTextW(mem, &wide, @intCast(label.len), &box, c.DT_SINGLELINE | c.DT_VCENTER | c.DT_CENTER | c.DT_NOPREFIX);
        } else self.bellGlyph(mem, r, bellColor(pal));
    }

    // The title, bold, centered on the bar, between the buttons.
    if (self.titlePlace(p, width, bells)) |t| {
        var rect: c.RECT = .{ .left = t[0], .top = 0, .right = t[0] + t[1], .bottom = h };
        _ = c.DrawTextW(mem, title.ptr, @intCast(title.len), &rect, c.DT_SINGLELINE | c.DT_VCENTER | c.DT_END_ELLIPSIS | c.DT_NOPREFIX);
    }

    if (self.pillPlace(width)) |r| self.paintPill(mem, r, state(.update, hover, pressed), pal);

    _ = c.BitBlt(hdc, 0, 0, width, h, mem, 0, 0, c.SRCCOPY);
}

/// A bell (notification-symbolic's shape on its 16 px grid: a crown, the
/// dome flaring to a brim, the clapper below), centered in `r`.
fn bellGlyph(self: *const HeaderBar, hdc: c.HDC, r: c.RECT, color: c.COLORREF) void {
    const g: Glyph = .{
        .bar = self,
        .hdc = hdc,
        .x = r.left + @divTrunc(r.right - r.left - self.scale(16), 2),
        .y = r.top + self.scale(icon_inset),
        .color = color,
    };
    g.fill(7, 0, 9, 2);
    draw.roundRect(hdc, g.rect(4, 1, 12, 9), self.scale(4), color, null, 0);
    const top = g.rect(4, 5, 12, 10);
    const bottom = g.rect(2, 5, 14, 10);
    draw.polygon(hdc, &.{
        .{ .x = top.left, .y = top.top },
        .{ .x = top.right, .y = top.top },
        .{ .x = bottom.right, .y = bottom.bottom },
        .{ .x = bottom.left, .y = bottom.bottom },
    }, color);
    g.fill(1, 10, 15, 12);
    draw.roundRect(hdc, g.rect(6, 13, 10, 16), self.scale(2), color, null, 0);
}

/// The update pill: a capsule in its look's colors (lighter hovered,
/// more pressed), a badge for what it says, and its text.
fn paintPill(self: *const HeaderBar, hdc: c.HDC, r: c.RECT, s: State, pal: draw.Palette) void {
    const accent = c.rgb(0x35, 0x84, 0xe4);
    const white = c.rgb(0xff, 0xff, 0xff);
    const black = c.rgb(0, 0, 0);
    // Adwaita's orange 2 on a dark bar, its orange 5 on a light one.
    const warn = if (isDark(pal.bar)) c.rgb(0xff, 0xa3, 0x48) else c.rgb(0xc6, 0x46, 0x00);
    const colors: [2]c.COLORREF = switch (self.pill) {
        .hidden => return,
        .plain => .{ pal.control, pal.text },
        .accent => .{ accent, white },
        .accent_dim => .{ mix(accent, black, 0.3), white },
        .accent_dark => .{ mix(accent, black, 0.5), white },
        .warning => .{ mix(pal.bar, warn, 0.2), warn },
    };
    const fore = colors[1];
    const back = switch (s) {
        .normal => colors[0],
        .hover => mix(colors[0], fore, 0.1),
        .pressed => mix(colors[0], fore, 0.2),
    };
    draw.roundRect(hdc, r, @divTrunc(r.bottom - r.top, 2), back, null, 0);

    const icon = self.scale(pill_icon);
    const g: Glyph = .{
        .bar = self,
        .hdc = hdc,
        .x = r.left + self.scale(pill_pad),
        .y = r.top + @divTrunc(r.bottom - r.top - icon, 2),
        .color = fore,
    };
    switch (self.pill) {
        .hidden => {},
        // An arrow down to a tray: something to download.
        .accent => {
            g.fill(6, 1, 8, 7);
            const tri = g.rect(3, 6, 11, 10);
            draw.polygon(hdc, &.{
                .{ .x = tri.left, .y = tri.top },
                .{ .x = tri.right, .y = tri.top },
                .{ .x = @divTrunc(tri.left + tri.right, 2), .y = tri.bottom },
            }, fore);
            g.fill(2, 12, 12, 14);
        },
        // A ring open at the top right: going round.
        .plain => {
            draw.roundRect(hdc, g.rect(1, 1, 13, 13), self.scale(6), fore, null, 0);
            draw.roundRect(hdc, g.rect(3, 3, 11, 11), self.scale(4), back, null, 0);
            draw.fill(hdc, g.rect(7, 0, 14, 6), back);
        },
        // A ring around a dot: a question.
        .accent_dim => {
            draw.roundRect(hdc, g.rect(1, 1, 13, 13), self.scale(6), fore, null, 0);
            draw.roundRect(hdc, g.rect(3, 3, 11, 11), self.scale(4), back, null, 0);
            draw.roundRect(hdc, g.rect(5, 5, 9, 9), self.scale(2), fore, null, 0);
        },
        // A check mark: nothing to do.
        .accent_dark => {
            const a = g.rect(2, 7, 5, 10);
            const b = g.rect(5, 10, 12, 3);
            const stroke = @max(1, self.scale(2));
            draw.line(hdc, a.left, a.top, a.right, a.bottom, fore, stroke);
            draw.line(hdc, b.left, b.top, b.right, b.bottom, fore, stroke);
        },
        // A warning triangle.
        .warning => {
            const tri = g.rect(1, 1, 13, 13);
            draw.polygon(hdc, &.{
                .{ .x = @divTrunc(tri.left + tri.right, 2), .y = tri.top },
                .{ .x = tri.right, .y = tri.bottom },
                .{ .x = tri.left, .y = tri.bottom },
            }, fore);
            draw.fill(hdc, g.rect(6, 5, 8, 9), back);
            draw.fill(hdc, g.rect(6, 10, 8, 12), back);
        },
    }

    const old = if (self.pill_font) |f| c.SelectObject(hdc, f) else null;
    defer if (old) |o| {
        _ = c.SelectObject(hdc, o);
    };
    _ = c.SetTextColor(hdc, fore);
    var tr: c.RECT = .{
        .left = g.x + icon + self.scale(pill_gap),
        .top = r.top,
        .right = r.right - self.scale(pill_pad) + 1,
        .bottom = r.bottom,
    };
    _ = c.DrawTextW(hdc, &self.pill_text, @intCast(self.pill_len), &tr, c.DT_SINGLELINE | c.DT_VCENTER | c.DT_NOPREFIX | c.DT_END_ELLIPSIS);
}

/// `a` toward `b` by `t` (0 to 1), channel by channel.
fn mix(a: c.COLORREF, b: c.COLORREF, t: f32) c.COLORREF {
    const ch = struct {
        fn f(x: c.COLORREF, y: c.COLORREF, shift: u5, k: f32) u8 {
            const xa: f32 = @floatFromInt((x >> shift) & 0xFF);
            const ya: f32 = @floatFromInt((y >> shift) & 0xFF);
            return @intFromFloat(@round(xa + (ya - xa) * k));
        }
    }.f;
    return c.rgb(ch(a, b, 0, t), ch(a, b, 8, t), ch(a, b, 16, t));
}

fn isDark(color: c.COLORREF) bool {
    const r: u32 = color & 0xFF;
    const g: u32 = (color >> 8) & 0xFF;
    const b: u32 = (color >> 16) & 0xFF;
    return r * 299 + g * 587 + b * 114 < 128 * 1000;
}

/// The bell's color: yellow, as the bell emoji is drawn (Adwaita's yellow 2
/// on a dark bar, its darker yellow 5 on a light one).
fn bellColor(pal: draw.Palette) c.COLORREF {
    return if (isDark(pal.bar)) c.rgb(0xf6, 0xd3, 0x2d) else c.rgb(0xe5, 0xa5, 0x0a);
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

test "pillPlace: before the tab list's button; the title and bells make way" {
    const testing = std.testing;
    var bar: HeaderBar = .{ .pill = .accent, .pill_px = 120, .title_px = 5000 };
    const width = 1000;
    const p = bar.place(width);
    const r = bar.pillPlace(width).?;
    try testing.expectEqual(p.list.left - spacing, r.right);
    try testing.expect(r.left > p.new_tab_menu.right and r.bottom <= p.list.bottom and r.top >= p.list.top);
    try testing.expectEqual(Hit.update, bar.hitTest(@divTrunc(r.left + r.right, 2), 20, width));
    // A title too long to center ends before the pill.
    const t = bar.titleAt(width, true).?;
    try testing.expect(t[0] + t[1] <= r.left - spacing);
    // Hidden, or with no room: nothing there.
    bar.pill = .hidden;
    try testing.expect(bar.pillPlace(width) == null);
    bar.pill = .accent;
    try testing.expect(bar.pillPlace(bar.minWidth()) == null);
    // In the tab row the tabs end before it.
    bar.tabs_style = true;
    const rr = bar.pillPlace(width).?;
    try testing.expectEqual(width - rr.left + spacing, bar.tabsInsetAt(width)[1]);
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

test "bellPlace: bells never move a centered title" {
    const testing = std.testing;
    const width = 1000;
    var bar: HeaderBar = .{ .title_px = 200 };
    const p = bar.place(width);
    const alone = bar.titlePlace(p, width, bar.bellPlace(width)).?;
    try testing.expectEqual(@as(c_int, 400), alone[0]);
    for ([_]usize{ 1, 3, 9 }) |n| {
        bar.bells = n;
        const b = bar.bellPlace(width);
        try testing.expectEqual(n, b.shown);
        try testing.expect(!b.more);
        try testing.expect(b.start >= p.new_tab_menu.right);
        try testing.expect(b.end() <= alone[0] - bar.scale(spacing));
        try testing.expectEqual(alone, bar.titlePlace(p, width, b).?);
        // Each bell hit-tests as itself, and the caption stays between
        // the last and the title.
        for (0..n) |i| {
            const r = b.rect(i, 0, 0);
            try testing.expectEqual(Hit{ .bell = i }, bar.hitTest(r.left, 20, width));
            try testing.expectEqual(Hit{ .bell = i }, bar.hitTest(r.right - 1, 20, width));
        }
        try testing.expectEqual(Hit.none, bar.hitTest(b.end(), 20, width));
    }
    // More than fit: the last stands for the rest, still clear of the
    // title.
    bar.bells = 40;
    const b = bar.bellPlace(width);
    try testing.expect(b.more and b.shown < 40);
    try testing.expect(b.isMore(b.shown - 1) and !b.isMore(0));
    try testing.expect(b.end() <= alone[0] - bar.scale(spacing));
    try testing.expectEqual(alone, bar.titlePlace(p, width, b).?);
}

test "bellPlace: a title too long to center makes way for one bell" {
    const testing = std.testing;
    const width = 800;
    var bar: HeaderBar = .{ .title_px = 5000, .bells = 2 };
    const p = bar.place(width);
    const b = bar.bellPlace(width);
    try testing.expectEqual(@as(usize, 1), b.shown);
    try testing.expect(b.more);
    const t = bar.titlePlace(p, width, b).?;
    try testing.expect(t[0] >= b.end() + bar.scale(spacing));
    try testing.expect(t[0] + t[1] <= p.list.left);
    // No title: the bells go up to the tab list's button.
    bar.title_px = 0;
    bar.bells = 100;
    const all = bar.bellPlace(width);
    try testing.expect(all.end() <= p.list.left - bar.scale(spacing));
    try testing.expect(all.end() + all.width > p.list.left - bar.scale(spacing));
    // None waiting: none shown, nothing hit.
    bar.bells = 0;
    try testing.expectEqual(@as(usize, 0), bar.bellPlace(width).shown);
    try testing.expectEqual(Hit.none, bar.hitTest(all.start + 2, 20, width));
}

test "tabsInsetAt: the tabs start after the bells in the tab row" {
    const testing = std.testing;
    var bar: HeaderBar = .{ .tabs_style = true };
    try testing.expectEqual(bar.tabsInset(), bar.tabsInsetAt(794));
    bar.bells = 2;
    const b = bar.bellPlace(794);
    try testing.expectEqual(@as(usize, 2), b.shown);
    try testing.expectEqual([2]c_int{ b.end(), 794 - 612 }, bar.tabsInsetAt(794));
    // Many waiting take at most the first half of the tabs' span.
    bar.bells = 50;
    const many = bar.bellPlace(794);
    try testing.expect(many.more);
    try testing.expect(many.end() <= many.start + @divTrunc(612 - many.start, 2));
    try testing.expect(many.end() <= 612 - bar.scale(min_tab));
    // At the narrowest row there is none to spare.
    try testing.expectEqual(@as(usize, 0), bar.bellPlace(bar.minWidth()).shown);
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
