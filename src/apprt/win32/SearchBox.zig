//! The search box (roadmap 3.2), GTK's: an edit field, an "n/m" counter
//! and previous, next and close buttons over the pane's top-right corner.
//! It is a layered child window of the pane (spike S1) holding real
//! controls, so typing, the caret and the IME work as in any edit field.
//! The core runs the search and highlights the matches; this sends it the
//! text and the navigation, and shows what it reports. The Surface owns
//! it; its windows are created the first time it opens and destroyed with
//! the pane.
const SearchBox = @This();

const std = @import("std");
const c = @import("c.zig");
const Surface = @import("Surface.zig");

const log = std.log.scoped(.win32_search);

pub const class_name = c.L("MurrttySearch");

/// Metrics in device-independent pixels.
const margin = 8;
const box_height = 34;
const pad = 5;
const edit_width = 200;
const counter_width = 56;
const button_size = 24;
const radius = 6;
/// The whole window's opacity, out of 255.
const opacity = 245;
const border_color = c.rgb(0x55, 0x55, 0x55);

const id_edit = 1;
const id_previous = 2;
const id_next = 3;
const id_close = 4;

/// The timer that runs the search once typing pauses, after GTK's search
/// entry (150 ms).
const search_timer = 1;
const search_delay_ms = 150;

/// Segoe MDL2 Assets glyphs: ChevronUp, ChevronDown, Cancel.
const glyphs = [3]u16{ 0xE70E, 0xE70D, 0xE711 };

surface: ?*Surface = null,
hwnd: ?c.HWND = null,
edit: ?c.HWND = null,
/// Previous, next and close.
buttons: [3]?c.HWND = .{ null, null, null },
/// The edit field's own window procedure, which the box's wraps.
edit_proc: isize = 0,
/// Whether a search is on: from the core's start_search to its end_search.
active: bool = false,
/// What the core last reported: the number of matches and the selected
/// one (0-based, as GTK reads it).
total: ?usize = null,
selected: ?usize = null,
font: ?c.HFONT = null,
glyph_font: ?c.HFONT = null,
font_dpi: c.UINT = 0,
/// Colors from the terminal's: the box, the field, the text.
bg: c.COLORREF = c.rgb(0x30, 0x30, 0x30),
field_bg: c.COLORREF = c.rgb(0x20, 0x20, 0x20),
fg: c.COLORREF = c.rgb(0xff, 0xff, 0xff),
field_brush: ?c.HBRUSH = null,

pub fn registerClass(instance: c.HINSTANCE) !void {
    const wc: c.WNDCLASSEXW = .{
        .lpfnWndProc = &wndProc,
        .hInstance = instance,
        .hCursor = c.LoadCursorW(null, c.IDC_ARROW),
        .lpszClassName = class_name,
    };
    if (c.RegisterClassExW(&wc) == 0) return error.RegisterClassFailed;
}

pub fn deinit(self: *SearchBox) void {
    // The windows go with their parent, the surface.
    if (self.hwnd) |h| {
        _ = c.KillTimer(h, search_timer);
        _ = c.SetWindowLongPtrW(h, c.GWLP_USERDATA, 0);
    }
    if (self.edit) |e| _ = c.SetWindowLongPtrW(e, c.GWLP_USERDATA, 0);
    self.hwnd = null;
    self.edit = null;
    for ([_]?c.HGDIOBJ{ self.font, self.glyph_font, self.field_brush }) |obj| {
        if (obj) |o| _ = c.DeleteObject(o);
    }
    self.font = null;
    self.glyph_font = null;
    self.field_brush = null;
}

/// Whether it shows, for the GUI tests' dump.
pub fn visible(self: *const SearchBox) bool {
    const h = self.hwnd orelse return false;
    return c.IsWindowVisible(h) != 0;
}

/// The window that takes the keyboard for the pane while the box is open.
pub fn focusTarget(self: *const SearchBox) ?c.HWND {
    return if (self.active) self.edit else null;
}

/// The field's text as UTF-8 into `buf`, for the tests' dump.
pub fn textUtf8(self: *const SearchBox, buf: []u8) []const u8 {
    const edit = self.edit orelse return "";
    var wide: [256]u16 = undefined;
    const n = c.GetWindowTextW(edit, &wide, wide.len);
    const len = std.unicode.utf16LeToUtf8(buf, wide[0..@intCast(@max(n, 0))]) catch return "";
    return buf[0..len];
}

/// "selected/total", or "0/0" with no matches, as GTK shows it.
pub fn counterText(self: *const SearchBox, buf: []u8) []const u8 {
    const total = self.total orelse 0;
    if (total == 0) return "0/0";
    const shown: usize = if (self.selected) |s| s + 1 else 0;
    return std.fmt.bufPrint(buf, "{d}/{d}", .{ shown, total }) catch "";
}

/// The core started a search (start_search): show the box, with `needle`
/// in the field if it is given (search_selection), and focus the field.
pub fn open(self: *SearchBox, surface: *Surface, needle: []const u8) void {
    self.surface = surface;
    if (self.hwnd == null) self.create(surface) catch |err| {
        log.warn("search box not created err={}", .{err});
        return;
    };
    const hwnd = self.hwnd.?;
    const edit = self.edit.?;
    self.setColors(surface);

    const was_active = self.active;
    self.active = true;
    if (needle.len > 0) {
        var wide: [256:0]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&wide, needle[0..@min(needle.len, 255)]) catch 0;
        wide[n] = 0;
        // EN_CHANGE then runs the search after the usual delay; GTK runs
        // it at once.
        _ = c.SetWindowTextW(edit, &wide);
        self.runSearch();
    } else if (!was_active and c.GetWindowTextLengthW(edit) > 0) {
        // Opening again searches for what the field still holds, as GTK.
        self.runSearch();
    }

    self.layout();
    _ = c.ShowWindow(hwnd, c.SW_SHOWNA);
    _ = c.InvalidateRect(hwnd, null, c.TRUE);
    _ = c.SetFocus(edit);
    _ = c.SendMessageW(edit, c.EM_SETSEL, 0, -1);
}

/// The core ended the search (end_search): hide the box, and give the
/// keyboard back to the pane if the box had it.
pub fn close(self: *SearchBox) void {
    self.active = false;
    self.total = null;
    self.selected = null;
    const hwnd = self.hwnd orelse return;
    _ = c.KillTimer(hwnd, search_timer);
    const had_focus = self.ownsFocus();
    _ = c.ShowWindow(hwnd, c.SW_HIDE);
    if (had_focus) if (self.surface) |s| {
        _ = c.SetFocus(s.hwnd);
    };
}

pub fn setTotal(self: *SearchBox, total: ?usize) void {
    self.total = total;
    if (self.hwnd) |h| _ = c.InvalidateRect(h, null, c.FALSE);
}

pub fn setSelected(self: *SearchBox, selected: ?usize) void {
    self.selected = selected;
    if (self.hwnd) |h| _ = c.InvalidateRect(h, null, c.FALSE);
}

/// Whether the keyboard focus is in the box.
pub fn ownsFocus(self: *const SearchBox) bool {
    const focus = c.GetFocus() orelse return false;
    if (self.edit) |e| if (focus == e) return true;
    for (self.buttons) |b| if (b) |h| if (focus == h) return true;
    return if (self.hwnd) |h| focus == h else false;
}

fn create(self: *SearchBox, surface: *Surface) !void {
    const instance = c.GetModuleHandleW(null);
    const hwnd = c.CreateWindowExW(
        c.WS_EX_LAYERED,
        class_name,
        c.L(""),
        c.WS_CHILD | c.WS_CLIPSIBLINGS | c.WS_CLIPCHILDREN,
        0,
        0,
        1,
        1,
        surface.hwnd,
        null,
        instance,
        null,
    ) orelse return error.CreateWindowFailed;
    errdefer _ = c.DestroyWindow(hwnd);
    _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    _ = c.SetLayeredWindowAttributes(hwnd, 0, opacity, c.LWA_ALPHA);

    const edit = c.CreateWindowExW(
        0,
        c.L("EDIT"),
        c.L(""),
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.ES_AUTOHSCROLL,
        0,
        0,
        1,
        1,
        hwnd,
        @ptrFromInt(id_edit),
        instance,
        null,
    ) orelse return error.CreateWindowFailed;
    _ = c.SetWindowLongPtrW(edit, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.edit_proc = c.SetWindowLongPtrW(edit, c.GWLP_WNDPROC, @bitCast(@intFromPtr(&editProc)));

    for (&self.buttons, [_]usize{ id_previous, id_next, id_close }) |*b, id| {
        b.* = c.CreateWindowExW(
            0,
            c.L("BUTTON"),
            c.L(""),
            c.WS_CHILD | c.WS_VISIBLE | c.BS_OWNERDRAW,
            0,
            0,
            1,
            1,
            hwnd,
            @ptrFromInt(id),
            instance,
            null,
        );
    }
    self.hwnd = hwnd;
    self.edit = edit;
}

fn setColors(self: *SearchBox, surface: *Surface) void {
    const bg = surface.colors.bg;
    const fg = surface.colors.fg;
    self.bg = c.rgb(mix(bg.r, fg.r, 0.12), mix(bg.g, fg.g, 0.12), mix(bg.b, fg.b, 0.12));
    self.field_bg = c.rgb(bg.r, bg.g, bg.b);
    self.fg = c.rgb(fg.r, fg.g, fg.b);
    if (self.field_brush) |b| _ = c.DeleteObject(b);
    self.field_brush = c.CreateSolidBrush(self.field_bg);
}

fn mix(a: u8, b: u8, t: f32) u8 {
    const af: f32 = @floatFromInt(a);
    const bf: f32 = @floatFromInt(b);
    return @intFromFloat(@round(af + (bf - af) * t));
}

/// Place the box at the pane's top-right corner and its controls in it.
/// The pane calls this when it resizes.
pub fn layout(self: *SearchBox) void {
    const hwnd = self.hwnd orelse return;
    const parent = c.GetParent(hwnd) orelse return;
    const dpi = c.GetDpiForWindow(parent);
    self.ensureFonts(dpi);

    const s = struct {
        dpi: c.UINT,
        fn px(this: @This(), v: c_int) c_int {
            return @intCast(@divTrunc(@as(i64, v) * this.dpi, c.USER_DEFAULT_SCREEN_DPI));
        }
    }{ .dpi = dpi };
    const width = s.px(pad) * 2 + s.px(edit_width) + s.px(counter_width) + s.px(button_size) * 3;
    const height = s.px(box_height);
    var area: c.RECT = .{};
    _ = c.GetClientRect(parent, &area);
    const x = @max(0, area.right - s.px(margin) - width);
    _ = c.SetWindowPos(hwnd, null, x, s.px(margin), width, height, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
    const r = s.px(radius) * 2;
    if (c.CreateRoundRectRgn(0, 0, width + 1, height + 1, r, r)) |rgn| {
        if (c.SetWindowRgn(hwnd, rgn, c.TRUE) == 0) _ = c.DeleteObject(rgn);
    }

    // The field: the edit control, its text's height, centered in it.
    const field = self.fieldRect(dpi);
    const text_h = self.textHeight();
    if (self.edit) |e| {
        _ = c.SetWindowPos(e, null, field.left + s.px(6), @divTrunc(height - text_h, 2), field.right - field.left - s.px(12), text_h, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
    }
    var bx = field.right + s.px(counter_width);
    const by = @divTrunc(height - s.px(button_size), 2);
    for (self.buttons) |b| if (b) |h| {
        _ = c.SetWindowPos(h, null, bx, by, s.px(button_size), s.px(button_size), c.SWP_NOZORDER | c.SWP_NOACTIVATE);
        bx += s.px(button_size);
    };
}

fn fieldRect(self: *const SearchBox, dpi: c.UINT) c.RECT {
    _ = self;
    const px = struct {
        fn f(v: c_int, d: c.UINT) c_int {
            return @intCast(@divTrunc(@as(i64, v) * d, c.USER_DEFAULT_SCREEN_DPI));
        }
    }.f;
    return .{ .left = px(pad, dpi), .top = px(pad, dpi), .right = px(pad, dpi) + px(edit_width, dpi), .bottom = px(box_height - pad, dpi) };
}

fn textHeight(self: *const SearchBox) c_int {
    const hwnd = self.hwnd orelse return 16;
    const dc = c.GetDC(hwnd) orelse return 16;
    defer _ = c.ReleaseDC(hwnd, dc);
    const old = if (self.font) |f| c.SelectObject(dc, f) else null;
    defer if (old) |o| {
        _ = c.SelectObject(dc, o);
    };
    var r: c.RECT = .{};
    const probe = [_]u16{ 'A', 'g' };
    _ = c.DrawTextW(dc, &probe, probe.len, &r, c.DT_CALCRECT | c.DT_SINGLELINE | c.DT_NOPREFIX);
    return @max(r.bottom, 1);
}

fn ensureFonts(self: *SearchBox, dpi: c.UINT) void {
    if (self.font != null and self.font_dpi == dpi) return;
    for ([_]?c.HFONT{ self.font, self.glyph_font }) |f| if (f) |h| {
        _ = c.DeleteObject(h);
    };
    self.font = null;
    self.glyph_font = null;
    self.font_dpi = dpi;
    var ncm: c.NONCLIENTMETRICSW = .{};
    if (c.SystemParametersInfoForDpi(c.SPI_GETNONCLIENTMETRICS, @sizeOf(c.NONCLIENTMETRICSW), &ncm, 0, dpi) == 0) return;
    self.font = c.CreateFontIndirectW(&ncm.lfMessageFont);
    var glyph = ncm.lfMessageFont;
    glyph.lfFaceName = @splat(0);
    const face = std.unicode.utf8ToUtf16LeStringLiteral("Segoe MDL2 Assets");
    @memcpy(glyph.lfFaceName[0..face.len], face);
    self.glyph_font = c.CreateFontIndirectW(&glyph);
    if (self.edit) |e| if (self.font) |f| {
        _ = c.SendMessageW(e, c.WM_SETFONT, @intFromPtr(f), 1);
    };
}

/// Send the field's text to the core's search.
fn runSearch(self: *SearchBox) void {
    const surface = self.surface orelse return;
    if (!surface.core_initialized) return;
    var buf: [1024]u8 = undefined;
    const text = self.textUtf8(&buf);
    _ = surface.core_surface.performBindingAction(.{ .search = text }) catch |err| {
        log.warn("search failed err={}", .{err});
    };
}

fn navigate(self: *SearchBox, direction: @import("../../input.zig").Binding.Action.NavigateSearch) void {
    const surface = self.surface orelse return;
    if (!surface.core_initialized) return;
    _ = surface.core_surface.performBindingAction(.{ .navigate_search = direction }) catch |err| {
        log.warn("search navigation failed err={}", .{err});
    };
}

/// End the search; the core then sends end_search, which closes the box.
fn end(self: *SearchBox) void {
    const surface = self.surface orelse return;
    if (!surface.core_initialized) return;
    _ = surface.core_surface.performBindingAction(.end_search) catch |err| {
        log.warn("ending the search failed err={}", .{err});
    };
}

fn paint(self: *SearchBox, hwnd: c.HWND) void {
    var ps: c.PAINTSTRUCT = undefined;
    const hdc = c.BeginPaint(hwnd, &ps) orelse return;
    defer _ = c.EndPaint(hwnd, &ps);
    var rect: c.RECT = .{};
    _ = c.GetClientRect(hwnd, &rect);
    const dpi = c.GetDpiForWindow(hwnd);

    const mem = c.CreateCompatibleDC(hdc) orelse return;
    defer _ = c.DeleteDC(mem);
    const bmp = c.CreateCompatibleBitmap(hdc, rect.right, rect.bottom) orelse return;
    defer _ = c.DeleteObject(bmp);
    const old_bmp = c.SelectObject(mem, bmp);
    defer _ = c.SelectObject(mem, old_bmp);

    fill(mem, rect, self.bg);
    fill(mem, self.fieldRect(dpi), self.field_bg);
    const r = @as(c_int, @intCast(@divTrunc(@as(i64, radius) * dpi, c.USER_DEFAULT_SCREEN_DPI))) * 2;
    if (c.CreateRoundRectRgn(0, 0, rect.right, rect.bottom, r, r)) |rgn| {
        defer _ = c.DeleteObject(rgn);
        if (c.CreateSolidBrush(border_color)) |brush| {
            defer _ = c.DeleteObject(brush);
            _ = c.FrameRgn(mem, rgn, brush, 1, 1);
        }
    }

    // The counter, between the field and the buttons.
    const field = self.fieldRect(dpi);
    var counter: c.RECT = .{
        .left = field.right,
        .top = 0,
        .right = field.right + @as(c_int, @intCast(@divTrunc(@as(i64, counter_width) * dpi, c.USER_DEFAULT_SCREEN_DPI))),
        .bottom = rect.bottom,
    };
    var buf: [32]u8 = undefined;
    const text = self.counterText(&buf);
    var wide: [32]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, text) catch 0;
    const old_font = if (self.font) |f| c.SelectObject(mem, f) else null;
    defer if (old_font) |f| {
        _ = c.SelectObject(mem, f);
    };
    _ = c.SetBkMode(mem, c.TRANSPARENT);
    _ = c.SetTextColor(mem, self.fg);
    _ = c.DrawTextW(mem, &wide, @intCast(n), &counter, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX);

    _ = c.BitBlt(hdc, 0, 0, rect.right, rect.bottom, mem, 0, 0, c.SRCCOPY);
}

fn drawButton(self: *SearchBox, item: *const c.DRAWITEMSTRUCT) void {
    const index: usize = switch (item.CtlID) {
        id_previous => 0,
        id_next => 1,
        else => 2,
    };
    const pressed = item.itemState & c.ODS_SELECTED != 0;
    fill(item.hDC, item.rcItem, if (pressed) self.field_bg else self.bg);
    const old = if (self.glyph_font) |f| c.SelectObject(item.hDC, f) else null;
    defer if (old) |o| {
        _ = c.SelectObject(item.hDC, o);
    };
    _ = c.SetBkMode(item.hDC, c.TRANSPARENT);
    _ = c.SetTextColor(item.hDC, self.fg);
    var r = item.rcItem;
    _ = c.DrawTextW(item.hDC, &[_]u16{glyphs[index]}, 1, &r, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX);
}

fn fill(hdc: c.HDC, r: c.RECT, color: c.COLORREF) void {
    const brush = c.CreateSolidBrush(color) orelse return;
    defer _ = c.DeleteObject(brush);
    _ = c.FillRect(hdc, &r, brush);
}

fn fromHwnd(hwnd: c.HWND) ?*SearchBox {
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
        c.WM_COMMAND => {
            const id = c.loword(wparam);
            const code = c.hiword(wparam);
            if (id == id_edit and code == c.EN_CHANGE) {
                // Search once typing pauses.
                _ = c.SetTimer(hwnd, search_timer, search_delay_ms, null);
            } else if (code == c.BN_CLICKED) {
                switch (id) {
                    id_previous => self.navigate(.previous),
                    id_next => self.navigate(.next),
                    id_close => self.end(),
                    else => {},
                }
                // A click focuses the button; the field keeps the keyboard.
                if (self.active) if (self.edit) |e| {
                    _ = c.SetFocus(e);
                };
            }
            return 0;
        },
        c.WM_TIMER => if (wparam == search_timer) {
            _ = c.KillTimer(hwnd, search_timer);
            self.runSearch();
            return 0;
        },
        c.WM_CTLCOLOREDIT => {
            const dc: c.HDC = @ptrFromInt(wparam);
            _ = c.SetTextColor(dc, self.fg);
            _ = c.SetBkColor(dc, self.field_bg);
            if (self.field_brush) |b| return @bitCast(@intFromPtr(b));
        },
        c.WM_DRAWITEM => {
            const item: *const c.DRAWITEMSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            self.drawButton(item);
            return 1;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// The edit field's keys: Enter for the next match, Shift+Enter for the
/// previous, Escape to end the search (GTK's); the rest is the field's.
fn editProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const self = fromHwnd(hwnd) orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    switch (msg) {
        c.WM_KEYDOWN => switch (wparam) {
            c.VK_RETURN => {
                const shift = c.GetKeyState(c.VK_SHIFT) < 0;
                self.navigate(if (shift) .previous else .next);
                return 0;
            },
            c.VK_ESCAPE => {
                self.end();
                return 0;
            },
            else => {},
        },
        // Their characters would only beep.
        c.WM_CHAR => if (wparam == '\r' or wparam == 0x1b) return 0,
        else => {},
    }
    return c.CallWindowProcW(self.edit_proc, hwnd, msg, wparam, lparam);
}
