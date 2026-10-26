//! A small text overlay: the resize overlay, the status overlays of
//! roadmap 3.6 (the link preview, the read-only badge, the key state, the
//! renderer panel) over a pane, and the toasts over a window. It is a
//! layered child window of its parent (spike S1): DWM composes it above the
//! GL surface, which keeps drawing underneath, so it never flickers, leaves
//! no ghost where it was, and needs no repaint when the pane resizes. Its
//! owner (a Surface, or a Window for toasts) sets the look once and shows
//! it; the window is created the first time it shows and destroyed with its
//! parent.
const Overlay = @This();

const std = @import("std");
const c = @import("c.zig");
const configpkg = @import("../../config.zig");

const log = std.log.scoped(.win32_overlay);

pub const class_name = c.L("MurrttyOverlay");

/// Where in the parent it sits.
pub const Position = configpkg.Config.ResizeOverlayPosition;

/// The whole window's opacity, out of 255.
const opacity = 235;

/// SetTimer id of the timer that hides it.
const hide_timer = 1;

hwnd: ?c.HWND = null,
position: Position = .center,
/// Metrics in device-independent pixels (the defaults are GTK's resize
/// overlay's): from the parent's edges, around the text, the corners (0
/// for square, a negative value for a pill).
margin: c_int = 12,
pad_x: c_int = 8,
pad_y: c_int = 4,
radius: c_int = 6,
/// Its colors: the background (the terminal's, blended), the text and the
/// outline.
bg: c.COLORREF = c.rgb(0x30, 0x30, 0x30),
fg: c.COLORREF = c.rgb(0xff, 0xff, 0xff),
border: c.COLORREF = c.rgb(0x55, 0x55, 0x55),
/// A Segoe MDL2 Assets glyph before the text (a lock, a keyboard), or 0.
icon: u16 = 0,
/// Text that wraps, within half the parent's width (the renderer panel);
/// otherwise one line, cut with an ellipsis to fit the parent.
wrap: bool = false,
/// The text, UTF-16.
text: [512]u16 = undefined,
text_len: usize = 0,
font: ?c.HFONT = null,
icon_font: ?c.HFONT = null,
font_dpi: c.UINT = 0,

pub fn registerClass(instance: c.HINSTANCE) !void {
    const wc: c.WNDCLASSEXW = .{
        .lpfnWndProc = &wndProc,
        .hInstance = instance,
        .lpszClassName = class_name,
    };
    if (c.RegisterClassExW(&wc) == 0) return error.RegisterClassFailed;
}

pub fn deinit(self: *Overlay) void {
    // The window goes with its parent.
    if (self.hwnd) |h| _ = c.SetWindowLongPtrW(h, c.GWLP_USERDATA, 0);
    self.hwnd = null;
    for ([_]?c.HFONT{ self.font, self.icon_font }) |f| if (f) |o| {
        _ = c.DeleteObject(o);
    };
    self.font = null;
    self.icon_font = null;
}

/// Whether it is on screen, for the GUI tests' dump.
pub fn visible(self: *const Overlay) bool {
    const h = self.hwnd orelse return false;
    return c.IsWindowVisible(h) != 0;
}

/// Whether it is shown, though its parent may be hidden (a background
/// tab's pane): it still needs placing when the parent resizes.
pub fn shown(self: *const Overlay) bool {
    const h = self.hwnd orelse return false;
    const style: usize = @bitCast(c.GetWindowLongPtrW(h, c.GWL_STYLE));
    return style & c.WS_VISIBLE != 0;
}

/// Back on top of its siblings (a tab created after it).
pub fn raise(self: *const Overlay) void {
    const h = self.hwnd orelse return;
    _ = c.SetWindowPos(h, c.HWND_TOP, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOACTIVATE);
}

/// The text, for the GUI tests' dump.
pub fn textUtf16(self: *const Overlay) []const u16 {
    return self.text[0..self.text_len];
}

/// Show `text` over `parent` for `ms` milliseconds, or (0) until hidden,
/// replacing what it showed.
pub fn show(self: *Overlay, parent: c.HWND, text: []const u8, ms: u32) void {
    const hwnd = self.hwnd orelse created: {
        const h = c.CreateWindowExW(
            c.WS_EX_LAYERED | c.WS_EX_TRANSPARENT,
            class_name,
            c.L(""),
            c.WS_CHILD | c.WS_CLIPSIBLINGS,
            0,
            0,
            1,
            1,
            parent,
            null,
            c.GetModuleHandleW(null),
            null,
        ) orelse {
            log.warn("overlay window not created err={d}", .{c.GetLastError()});
            return;
        };
        _ = c.SetWindowLongPtrW(h, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        _ = c.SetLayeredWindowAttributes(h, 0, opacity, c.LWA_ALPHA);
        self.hwnd = h;
        break :created h;
    };

    self.text_len = utf16Prefix(&self.text, text);
    self.layout();
    // Above its siblings (another overlay, a pane's search box).
    _ = c.SetWindowPos(hwnd, c.HWND_TOP, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOACTIVATE);
    _ = c.InvalidateRect(hwnd, null, c.FALSE);
    _ = c.ShowWindow(hwnd, c.SW_SHOWNA);
    // A newer show restarts the countdown.
    if (ms > 0) {
        _ = c.SetTimer(hwnd, hide_timer, ms, null);
    } else {
        _ = c.KillTimer(hwnd, hide_timer);
    }
}

/// As much of `text` as fits `buf` as UTF-16, never cutting a character;
/// each invalid byte becomes U+FFFD (a URL or title can hold them).
fn utf16Prefix(buf: []u16, text: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        var cp: u21 = 0xFFFD;
        var len: usize = 1;
        if (std.unicode.utf8ByteSequenceLength(text[i])) |l| {
            if (i + l <= text.len) {
                if (std.unicode.utf8Decode(text[i .. i + l])) |v| {
                    cp = v;
                    len = l;
                } else |_| {}
            }
        } else |_| {}
        if (cp > 0xFFFF) {
            if (n + 2 > buf.len) break;
            const v = cp - 0x10000;
            buf[n] = @intCast(0xD800 + (v >> 10));
            buf[n + 1] = @intCast(0xDC00 + (v & 0x3FF));
            n += 2;
        } else {
            if (n + 1 > buf.len) break;
            buf[n] = @intCast(cp);
            n += 1;
        }
        i += len;
    }
    return n;
}

pub fn hide(self: *Overlay) void {
    const hwnd = self.hwnd orelse return;
    _ = c.KillTimer(hwnd, hide_timer);
    _ = c.ShowWindow(hwnd, c.SW_HIDE);
}

/// Move it to `position` (the link preview's corners).
pub fn moveTo(self: *Overlay, position: Position) void {
    if (self.position == position) return;
    self.position = position;
    self.layout();
}

/// Its rectangle in its parent's client coordinates.
pub fn rect(self: *const Overlay) ?c.RECT {
    const hwnd = self.hwnd orelse return null;
    const parent = c.GetParent(hwnd) orelse return null;
    var r: c.RECT = .{};
    if (c.GetWindowRect(hwnd, &r) == 0) return null;
    var pts = [2]c.POINT{ .{ .x = r.left, .y = r.top }, .{ .x = r.right, .y = r.bottom } };
    _ = c.MapWindowPoints(null, parent, &pts, 2);
    return .{ .left = pts[0].x, .top = pts[0].y, .right = pts[1].x, .bottom = pts[1].y };
}

/// Size it to its text and place it in its parent. The owner calls this
/// when the parent resizes.
pub fn layout(self: *Overlay) void {
    const hwnd = self.hwnd orelse return;
    const parent = c.GetParent(hwnd) orelse return;
    const dpi = c.GetDpiForWindow(parent);
    self.ensureFonts(dpi);

    var area: c.RECT = .{};
    _ = c.GetClientRect(parent, &area);
    const m = scale(self.margin, dpi);
    const size = self.measure(hwnd, dpi, area.right - 2 * m);
    const x = switch (self.position) {
        .@"top-left", .@"bottom-left" => m,
        .center, .@"top-center", .@"bottom-center" => @divTrunc(area.right - size.cx, 2),
        .@"top-right", .@"bottom-right" => area.right - m - size.cx,
    };
    const y = switch (self.position) {
        .@"top-left", .@"top-center", .@"top-right" => m,
        .center => @divTrunc(area.bottom - size.cy, 2),
        .@"bottom-left", .@"bottom-center", .@"bottom-right" => area.bottom - m - size.cy,
    };
    _ = c.SetWindowPos(hwnd, null, x, y, size.cx, size.cy, c.SWP_NOZORDER | c.SWP_NOACTIVATE);

    // Rounded corners: the window takes ownership of the region.
    const r = self.cornerDiameter(dpi, size.cy);
    const rgn = if (r > 0) c.CreateRoundRectRgn(0, 0, size.cx + 1, size.cy + 1, r, r) else c.CreateRectRgn(0, 0, size.cx, size.cy);
    if (rgn) |g| {
        if (c.SetWindowRgn(hwnd, g, c.TRUE) == 0) _ = c.DeleteObject(g);
    }
}

fn cornerDiameter(self: *const Overlay, dpi: c.UINT, height: c_int) c_int {
    if (self.radius < 0) return height;
    return scale(self.radius, dpi) * 2;
}

fn ensureFonts(self: *Overlay, dpi: c.UINT) void {
    if (self.font != null and self.font_dpi == dpi) return;
    for ([_]?c.HFONT{ self.font, self.icon_font }) |f| if (f) |o| {
        _ = c.DeleteObject(o);
    };
    self.font = null;
    self.icon_font = null;
    self.font_dpi = dpi;
    var ncm: c.NONCLIENTMETRICSW = .{};
    if (c.SystemParametersInfoForDpi(c.SPI_GETNONCLIENTMETRICS, @sizeOf(c.NONCLIENTMETRICSW), &ncm, 0, dpi) == 0) return;
    self.font = c.CreateFontIndirectW(&ncm.lfMessageFont);
    var glyph = ncm.lfMessageFont;
    glyph.lfFaceName = @splat(0);
    const face = c.L("Segoe MDL2 Assets");
    @memcpy(glyph.lfFaceName[0..face.len], face);
    self.icon_font = c.CreateFontIndirectW(&glyph);
}

/// The text's flags: one line cut with an ellipsis, or wrapped.
fn textFlags(self: *const Overlay) c.UINT {
    return if (self.wrap) c.DT_WORDBREAK | c.DT_NOPREFIX | c.DT_CENTER else c.DT_SINGLELINE | c.DT_NOPREFIX | c.DT_END_ELLIPSIS;
}

/// The window's size for its text, at most `max_width` wide.
fn measure(self: *Overlay, hwnd: c.HWND, dpi: c.UINT, max_width: c_int) c.SIZE {
    const px = scale(self.pad_x, dpi);
    const py = scale(self.pad_y, dpi);
    var icon_w: c_int = 0;
    var text_r: c.RECT = .{};
    if (c.GetDC(hwnd)) |dc| {
        defer _ = c.ReleaseDC(hwnd, dc);
        if (self.icon != 0) if (self.icon_font) |f| {
            const old = c.SelectObject(dc, f);
            defer _ = c.SelectObject(dc, old);
            var r: c.RECT = .{};
            _ = c.DrawTextW(dc, &[_]u16{self.icon}, 1, &r, c.DT_CALCRECT | c.DT_SINGLELINE | c.DT_NOPREFIX);
            icon_w = r.right + scale(6, dpi);
        };
        const old = if (self.font) |f| c.SelectObject(dc, f) else null;
        defer if (old) |o| {
            _ = c.SelectObject(dc, o);
        };
        const room = @max(max_width - 2 * px - icon_w, scale(40, dpi));
        // Wrapped text gets half the room, so it reads as a panel.
        text_r.right = if (self.wrap) @max(@divTrunc(room, 2), scale(240, dpi)) else room;
        _ = c.DrawTextW(dc, &self.text, @intCast(self.text_len), &text_r, c.DT_CALCRECT | (self.textFlags() & ~@as(c.UINT, c.DT_END_ELLIPSIS)));
        if (!self.wrap) text_r.right = @min(text_r.right, room);
    }
    return .{
        .cx = text_r.right + icon_w + 2 * px,
        .cy = text_r.bottom + 2 * py,
    };
}

fn paint(self: *Overlay, hwnd: c.HWND) void {
    var ps: c.PAINTSTRUCT = undefined;
    const hdc = c.BeginPaint(hwnd, &ps) orelse return;
    defer _ = c.EndPaint(hwnd, &ps);
    var area: c.RECT = .{};
    _ = c.GetClientRect(hwnd, &area);

    // Double buffered.
    const mem = c.CreateCompatibleDC(hdc) orelse return;
    defer _ = c.DeleteDC(mem);
    const bmp = c.CreateCompatibleBitmap(hdc, area.right, area.bottom) orelse return;
    defer _ = c.DeleteObject(bmp);
    const old_bmp = c.SelectObject(mem, bmp);
    defer _ = c.SelectObject(mem, old_bmp);

    if (c.CreateSolidBrush(self.bg)) |brush| {
        defer _ = c.DeleteObject(brush);
        _ = c.FillRect(mem, &area, brush);
    }
    // The outline, inside the region.
    const dpi = c.GetDpiForWindow(hwnd);
    const d = self.cornerDiameter(dpi, area.bottom);
    const rgn = if (d > 0) c.CreateRoundRectRgn(0, 0, area.right, area.bottom, d, d) else c.CreateRectRgn(0, 0, area.right, area.bottom);
    if (rgn) |g| {
        defer _ = c.DeleteObject(g);
        if (c.CreateSolidBrush(self.border)) |brush| {
            defer _ = c.DeleteObject(brush);
            const w = @max(1, scale(1, dpi));
            _ = c.FrameRgn(mem, g, brush, w, w);
        }
    }

    _ = c.SetBkMode(mem, c.TRANSPARENT);
    _ = c.SetTextColor(mem, self.fg);
    var inner: c.RECT = .{
        .left = scale(self.pad_x, dpi),
        .top = scale(self.pad_y, dpi),
        .right = area.right - scale(self.pad_x, dpi),
        .bottom = area.bottom - scale(self.pad_y, dpi),
    };
    if (self.icon != 0) if (self.icon_font) |f| {
        const old = c.SelectObject(mem, f);
        defer _ = c.SelectObject(mem, old);
        var r = inner;
        _ = c.DrawTextW(mem, &[_]u16{self.icon}, 1, &r, c.DT_CALCRECT | c.DT_SINGLELINE | c.DT_NOPREFIX);
        var icon_r: c.RECT = .{ .left = inner.left, .top = inner.top, .right = inner.left + (r.right - r.left), .bottom = inner.bottom };
        _ = c.DrawTextW(mem, &[_]u16{self.icon}, 1, &icon_r, c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX);
        inner.left += (r.right - r.left) + scale(6, dpi);
    };
    const old_font = if (self.font) |f| c.SelectObject(mem, f) else null;
    defer if (old_font) |f| {
        _ = c.SelectObject(mem, f);
    };
    const centered: c.UINT = if (self.icon == 0) c.DT_CENTER else 0;
    const flags = if (self.wrap) self.textFlags() else self.textFlags() | c.DT_VCENTER | centered;
    _ = c.DrawTextW(mem, &self.text, @intCast(self.text_len), &inner, flags);

    _ = c.BitBlt(hdc, 0, 0, area.right, area.bottom, mem, 0, 0, c.SRCCOPY);
}

fn scale(v: c_int, dpi: c.UINT) c_int {
    return @intCast(@divTrunc(@as(i64, v) * dpi, c.USER_DEFAULT_SCREEN_DPI));
}

fn wndProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const ptr: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA));
    const self: ?*Overlay = if (ptr != 0) @ptrFromInt(ptr) else null;
    switch (msg) {
        c.WM_ERASEBKGND => return 1,
        // What is under it takes the mouse.
        c.WM_NCHITTEST => return c.HTTRANSPARENT,
        c.WM_PAINT => {
            if (self) |s| {
                s.paint(hwnd);
                return 0;
            }
        },
        c.WM_TIMER => if (wparam == hide_timer) {
            if (self) |s| s.hide() else _ = c.KillTimer(hwnd, hide_timer);
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

test "overlay text: whole characters only" {
    var buf: [3]u16 = undefined;
    // "a", then U+1F512 (a surrogate pair) doesn't fit after "ab".
    try std.testing.expectEqual(@as(usize, 2), utf16Prefix(&buf, "ab\u{1F512}"));
    try std.testing.expectEqual(@as(usize, 3), utf16Prefix(&buf, "a\u{1F512}"));
    try std.testing.expectEqual(@as(u16, 0xD83D), buf[1]);
}
