//! The child-exited banner (roadmap 3.6), GTK's: a bar across the bottom
//! of the pane once its program has ended, "Command Succeeded" on a green
//! wash or "Command Failed" on a red one, with a Close button that closes
//! the pane. It is a layered child window of the pane (spike S1) holding
//! a real button. The Surface owns it; the window is created the first time
//! it shows and destroyed with the pane.
const Banner = @This();

const std = @import("std");
const c = @import("c.zig");

const log = std.log.scoped(.win32_banner);

pub const class_name = c.L("MurrttyBanner");

/// Metrics in device-independent pixels.
const height = 40;
const pad = 12;
const button_width = 76;
const button_height = 26;
/// The whole window's opacity, out of 255.
const opacity = 240;

const id_close = 1;

hwnd: ?c.HWND = null,
button: ?c.HWND = null,
/// Whether the command failed (its title, and the red wash).
failed: bool = false,
/// The wash: the terminal's background mixed half with green or red, as
/// GTK's banner mixes Adwaita's success and error colors.
bg: c.COLORREF = c.rgb(0x30, 0x60, 0x30),
fg: c.COLORREF = c.rgb(0xff, 0xff, 0xff),
font: ?c.HFONT = null,
font_dpi: c.UINT = 0,
/// Called with `ctx` when Close is clicked (the pane closes itself).
on_close: ?*const fn (ctx: *anyopaque) void = null,
ctx: ?*anyopaque = null,

pub fn registerClass(instance: c.HINSTANCE) !void {
    const wc: c.WNDCLASSEXW = .{
        .lpfnWndProc = &wndProc,
        .hInstance = instance,
        .hCursor = c.LoadCursorW(null, c.IDC_ARROW),
        .lpszClassName = class_name,
    };
    if (c.RegisterClassExW(&wc) == 0) return error.RegisterClassFailed;
}

pub fn deinit(self: *Banner) void {
    // The windows go with their parent, the pane.
    if (self.hwnd) |h| _ = c.SetWindowLongPtrW(h, c.GWLP_USERDATA, 0);
    self.hwnd = null;
    self.button = null;
    if (self.font) |f| _ = c.DeleteObject(f);
    self.font = null;
}

pub fn visible(self: *const Banner) bool {
    const h = self.hwnd orelse return false;
    return c.IsWindowVisible(h) != 0;
}

/// Whether it is shown, though its pane may be hidden (a background tab).
pub fn shown(self: *const Banner) bool {
    const h = self.hwnd orelse return false;
    const style: usize = @bitCast(c.GetWindowLongPtrW(h, c.GWL_STYLE));
    return style & c.WS_VISIBLE != 0;
}

/// GTK's title for it.
pub fn title(self: *const Banner) []const u8 {
    return if (self.failed) "Command Failed" else "Command Succeeded";
}

/// Show it over `parent` (the pane): the command ended, with `exit_code`.
/// `bg` is the terminal's background.
pub fn show(self: *Banner, parent: c.HWND, exit_code: u32, bg: [3]u8, fg: [3]u8) void {
    self.failed = exit_code != 0;
    // Half the terminal's background, half Adwaita's success or error.
    const wash: [3]u8 = if (self.failed) .{ 0xe0, 0x1b, 0x24 } else .{ 0x26, 0xa2, 0x69 };
    self.bg = c.rgb(half(bg[0], wash[0]), half(bg[1], wash[1]), half(bg[2], wash[2]));
    self.fg = c.rgb(fg[0], fg[1], fg[2]);

    const hwnd = self.hwnd orelse created: {
        const instance = c.GetModuleHandleW(null);
        const h = c.CreateWindowExW(c.WS_EX_LAYERED, class_name, c.L(""), c.WS_CHILD | c.WS_CLIPSIBLINGS | c.WS_CLIPCHILDREN, 0, 0, 1, 1, parent, null, instance, null) orelse {
            log.warn("banner not created err={d}", .{c.GetLastError()});
            return;
        };
        _ = c.SetWindowLongPtrW(h, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        _ = c.SetLayeredWindowAttributes(h, 0, opacity, c.LWA_ALPHA);
        self.button = c.CreateWindowExW(0, c.L("BUTTON"), c.L("Close"), c.WS_CHILD | c.WS_VISIBLE, 0, 0, 1, 1, h, @ptrFromInt(id_close), instance, null);
        if (self.button) |b| {
            const old = c.SetWindowLongPtrW(b, c.GWLP_WNDPROC, @bitCast(@intFromPtr(&buttonProc)));
            if (button_proc == 0) button_proc = old;
        }
        self.hwnd = h;
        break :created h;
    };
    self.layout();
    _ = c.InvalidateRect(hwnd, null, c.TRUE);
    _ = c.ShowWindow(hwnd, c.SW_SHOWNA);
}

pub fn hide(self: *Banner) void {
    if (self.hwnd) |h| _ = c.ShowWindow(h, c.SW_HIDE);
}

fn half(a: u8, b: u8) u8 {
    return @intCast((@as(u16, a) + b) / 2);
}

fn px(v: c_int, dpi: c.UINT) c_int {
    return @intCast(@divTrunc(@as(i64, v) * dpi, c.USER_DEFAULT_SCREEN_DPI));
}

/// Across the bottom of the pane. The pane calls this when it resizes.
pub fn layout(self: *Banner) void {
    const hwnd = self.hwnd orelse return;
    const parent = c.GetParent(hwnd) orelse return;
    const dpi = c.GetDpiForWindow(parent);
    self.ensureFont(dpi);
    var area: c.RECT = .{};
    _ = c.GetClientRect(parent, &area);
    const h = px(height, dpi);
    _ = c.SetWindowPos(hwnd, null, 0, area.bottom - h, area.right, h, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
    if (self.button) |b| {
        const bw = px(button_width, dpi);
        const bh = px(button_height, dpi);
        _ = c.SetWindowPos(b, null, area.right - px(pad, dpi) - bw, @divTrunc(h - bh, 2), bw, bh, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
        if (self.font) |f| _ = c.SendMessageW(b, c.WM_SETFONT, @intFromPtr(f), 1);
    }
}

fn ensureFont(self: *Banner, dpi: c.UINT) void {
    if (self.font != null and self.font_dpi == dpi) return;
    if (self.font) |f| _ = c.DeleteObject(f);
    self.font = null;
    self.font_dpi = dpi;
    var ncm: c.NONCLIENTMETRICSW = .{};
    if (c.SystemParametersInfoForDpi(c.SPI_GETNONCLIENTMETRICS, @sizeOf(c.NONCLIENTMETRICSW), &ncm, 0, dpi) == 0) return;
    // GTK's banner title is bold.
    var lf = ncm.lfMessageFont;
    lf.lfWeight = 700;
    self.font = c.CreateFontIndirectW(&lf);
}

fn paint(self: *Banner, hwnd: c.HWND) void {
    var ps: c.PAINTSTRUCT = undefined;
    const hdc = c.BeginPaint(hwnd, &ps) orelse return;
    defer _ = c.EndPaint(hwnd, &ps);
    var rect: c.RECT = .{};
    _ = c.GetClientRect(hwnd, &rect);
    if (c.CreateSolidBrush(self.bg)) |brush| {
        defer _ = c.DeleteObject(brush);
        _ = c.FillRect(hdc, &rect, brush);
    }
    const old = if (self.font) |f| c.SelectObject(hdc, f) else null;
    defer if (old) |o| {
        _ = c.SelectObject(hdc, o);
    };
    _ = c.SetBkMode(hdc, c.TRANSPARENT);
    _ = c.SetTextColor(hdc, self.fg);
    var wide: [32]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, self.title()) catch 0;
    const dpi = c.GetDpiForWindow(hwnd);
    // Centered, as GTK's banner title, in the room the button leaves.
    var text_rect: c.RECT = .{ .left = px(pad, dpi), .top = 0, .right = rect.right - px(pad + button_width + pad, dpi), .bottom = rect.bottom };
    if (text_rect.right < text_rect.left) text_rect.right = rect.right;
    _ = c.DrawTextW(hdc, &wide, @intCast(n), &text_rect, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX | c.DT_END_ELLIPSIS);
}

fn fromHwnd(hwnd: c.HWND) ?*Banner {
    const ptr: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA));
    return if (ptr != 0) @ptrFromInt(ptr) else null;
}

fn wndProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const self = fromHwnd(hwnd) orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    switch (msg) {
        c.WM_ERASEBKGND => return 1,
        c.WM_PAINT => {
            self.paint(hwnd);
            return 0;
        },
        c.WM_COMMAND => if (c.loword(wparam) == id_close) switch (c.hiword(wparam)) {
            c.BN_CLICKED => {
                if (self.on_close) |f| if (self.ctx) |ctx| f(ctx);
                return 0;
            },
            else => {},
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// The button class's own procedure (every BUTTON shares it).
var button_proc: isize = 0;

/// A press on Close takes the keyboard from the pane, where a key closes it
/// once its program has ended: give it back when the press is over. Not
/// sooner: a button that loses the keyboard while pressed drops the click.
/// Needs no Banner, so it is safe while the pane is torn down.
fn buttonProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const result = c.CallWindowProcW(button_proc, hwnd, msg, wparam, lparam);
    switch (msg) {
        c.WM_LBUTTONUP, c.WM_CAPTURECHANGED => if (c.GetFocus() == hwnd) {
            if (c.GetParent(hwnd)) |banner| if (c.GetParent(banner)) |pane| {
                _ = c.SetFocus(pane);
            };
        },
        else => {},
    }
    return result;
}
