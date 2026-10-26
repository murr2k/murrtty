//! A small text overlay over a pane: the resize overlay, and later the
//! status overlays of roadmap 3.6. It is a layered child window of the
//! pane's surface (spike S1): DWM composes it above the GL surface, which
//! keeps drawing underneath, so it never flickers, leaves no ghost where it
//! was, and needs no repaint when the pane resizes. The Surface owns it;
//! the window is created the first time it shows and destroyed with the
//! pane.
const Overlay = @This();

const std = @import("std");
const c = @import("c.zig");
const configpkg = @import("../../config.zig");

const log = std.log.scoped(.win32_overlay);

pub const class_name = c.L("MurrttyOverlay");

/// Where in the pane it sits.
pub const Position = configpkg.Config.ResizeOverlayPosition;

/// Metrics in device-independent pixels, after GTK's resize overlay.
const margin = 12;
const pad_x = 8;
const pad_y = 4;
const radius = 6;
/// The whole window's opacity, out of 255.
const opacity = 235;
const border_color = c.rgb(0x55, 0x55, 0x55);

/// SetTimer id of the timer that hides it.
const hide_timer = 1;

hwnd: ?c.HWND = null,
position: Position = .center,
/// Its colors: the terminal's background (blended) and foreground.
bg: c.COLORREF = c.rgb(0x30, 0x30, 0x30),
fg: c.COLORREF = c.rgb(0xff, 0xff, 0xff),
/// The text, UTF-16.
text: [64]u16 = undefined,
text_len: usize = 0,
font: ?c.HFONT = null,
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
    // The window goes with its parent, the surface.
    if (self.hwnd) |h| _ = c.SetWindowLongPtrW(h, c.GWLP_USERDATA, 0);
    self.hwnd = null;
    if (self.font) |f| _ = c.DeleteObject(f);
    self.font = null;
}

/// Whether it is on screen, for the GUI tests' dump.
pub fn visible(self: *const Overlay) bool {
    const h = self.hwnd orelse return false;
    return c.IsWindowVisible(h) != 0;
}

/// The text, for the GUI tests' dump.
pub fn textUtf16(self: *const Overlay) []const u16 {
    return self.text[0..self.text_len];
}

/// Show `text` over `parent` (the pane's surface) for `ms` milliseconds,
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

    self.text_len = std.unicode.utf8ToUtf16Le(&self.text, text[0..@min(text.len, self.text.len)]) catch 0;
    self.layout();
    _ = c.InvalidateRect(hwnd, null, c.FALSE);
    _ = c.ShowWindow(hwnd, c.SW_SHOWNA);
    // A newer show restarts the countdown.
    _ = c.SetTimer(hwnd, hide_timer, @max(ms, 1), null);
}

pub fn hide(self: *Overlay) void {
    const hwnd = self.hwnd orelse return;
    _ = c.KillTimer(hwnd, hide_timer);
    _ = c.ShowWindow(hwnd, c.SW_HIDE);
}

/// Size it to its text and place it in its parent. The pane calls this
/// when it resizes.
pub fn layout(self: *Overlay) void {
    const hwnd = self.hwnd orelse return;
    const parent = c.GetParent(hwnd) orelse return;
    const dpi = c.GetDpiForWindow(parent);
    self.ensureFont(dpi);

    const size = self.measure(hwnd, dpi);
    var area: c.RECT = .{};
    _ = c.GetClientRect(parent, &area);
    const m = scale(margin, dpi);
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
    const r = scale(radius, dpi) * 2;
    if (c.CreateRoundRectRgn(0, 0, size.cx + 1, size.cy + 1, r, r)) |rgn| {
        if (c.SetWindowRgn(hwnd, rgn, c.TRUE) == 0) _ = c.DeleteObject(rgn);
    }
}

fn ensureFont(self: *Overlay, dpi: c.UINT) void {
    if (self.font != null and self.font_dpi == dpi) return;
    if (self.font) |f| _ = c.DeleteObject(f);
    self.font = null;
    self.font_dpi = dpi;
    var ncm: c.NONCLIENTMETRICSW = .{};
    if (c.SystemParametersInfoForDpi(c.SPI_GETNONCLIENTMETRICS, @sizeOf(c.NONCLIENTMETRICSW), &ncm, 0, dpi) != 0) {
        self.font = c.CreateFontIndirectW(&ncm.lfMessageFont);
    }
}

fn measure(self: *Overlay, hwnd: c.HWND, dpi: c.UINT) c.SIZE {
    var r: c.RECT = .{};
    if (c.GetDC(hwnd)) |dc| {
        defer _ = c.ReleaseDC(hwnd, dc);
        const old = if (self.font) |f| c.SelectObject(dc, f) else null;
        defer if (old) |o| {
            _ = c.SelectObject(dc, o);
        };
        _ = c.DrawTextW(dc, &self.text, @intCast(self.text_len), &r, c.DT_CALCRECT | c.DT_SINGLELINE | c.DT_NOPREFIX);
    }
    return .{
        .cx = r.right + 2 * scale(pad_x, dpi),
        .cy = r.bottom + 2 * scale(pad_y, dpi),
    };
}

fn paint(self: *Overlay, hwnd: c.HWND) void {
    var ps: c.PAINTSTRUCT = undefined;
    const hdc = c.BeginPaint(hwnd, &ps) orelse return;
    defer _ = c.EndPaint(hwnd, &ps);
    var rect: c.RECT = .{};
    _ = c.GetClientRect(hwnd, &rect);

    // Double buffered.
    const mem = c.CreateCompatibleDC(hdc) orelse return;
    defer _ = c.DeleteDC(mem);
    const bmp = c.CreateCompatibleBitmap(hdc, rect.right, rect.bottom) orelse return;
    defer _ = c.DeleteObject(bmp);
    const old_bmp = c.SelectObject(mem, bmp);
    defer _ = c.SelectObject(mem, old_bmp);

    if (c.CreateSolidBrush(self.bg)) |brush| {
        defer _ = c.DeleteObject(brush);
        _ = c.FillRect(mem, &rect, brush);
    }
    // The outline, inside the rounded region.
    const dpi = c.GetDpiForWindow(hwnd);
    const r = scale(radius, dpi) * 2;
    if (c.CreateRoundRectRgn(0, 0, rect.right, rect.bottom, r, r)) |rgn| {
        defer _ = c.DeleteObject(rgn);
        if (c.CreateSolidBrush(border_color)) |brush| {
            defer _ = c.DeleteObject(brush);
            const w = @max(1, scale(1, dpi));
            _ = c.FrameRgn(mem, rgn, brush, w, w);
        }
    }

    const old_font = if (self.font) |f| c.SelectObject(mem, f) else null;
    defer if (old_font) |f| {
        _ = c.SelectObject(mem, f);
    };
    _ = c.SetBkMode(mem, c.TRANSPARENT);
    _ = c.SetTextColor(mem, self.fg);
    var text_rect = rect;
    _ = c.DrawTextW(mem, &self.text, @intCast(self.text_len), &text_rect, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX);

    _ = c.BitBlt(hdc, 0, 0, rect.right, rect.bottom, mem, 0, 0, c.SRCCOPY);
}

fn scale(v: c_int, dpi: c.UINT) c_int {
    return @intCast(@divTrunc(@as(i64, v) * dpi, c.USER_DEFAULT_SCREEN_DPI));
}

fn wndProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const ptr: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA));
    const self: ?*Overlay = if (ptr != 0) @ptrFromInt(ptr) else null;
    switch (msg) {
        c.WM_ERASEBKGND => return 1,
        // The pane under it takes the mouse.
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
