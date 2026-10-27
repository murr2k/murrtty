//! libadwaita's alert dialog (roadmap 4.3b), for murrtty's confirmations:
//! a heading and a body centered in the dialog's color, an extra child (an
//! entry, or a text box and a "remember" row), then its responses as
//! rounded buttons in a row (stacked when they don't fit), a destructive
//! one in the destructive color and a suggested one on the accent, over
//! the owner window dimmed as libadwaita dims behind a dialog. Sizes are
//! the current stylesheet's: 32 DIP above the heading, 10 between it and
//! the body, 24 at the sides, a response area padded 24 (12 above) with
//! buttons 44 tall, 12 apart and rounded 12, the heading 15 pt bold, the
//! rest 11 pt, the buttons bold; 372 DIP wide, or the text box's 500 and
//! the sides.
//!
//! It is a real dialog, from a template built in memory: its buttons are
//! controls with the responses' ids, so Enter (the default response),
//! Escape (IDCANCEL), Tab and the GUI tests work as with any dialog. The
//! caller runs it in a modal scope (App.beginModal). The frame's rounded
//! corners are Windows 11's (DWM), not libadwaita's 18 px.
const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig");
const draw = @import("draw.zig");
const text_util = @import("text.zig");
const CommandPalette = @import("CommandPalette.zig");
const TitleDialog = @import("TitleDialog.zig");

const log = std.log.scoped(.win32_alert_dialog);

pub const Response = struct {
    id: u16,
    /// ASCII (it goes in the template as is).
    label: []const u8,
    appearance: enum { normal, suggested, destructive } = .normal,
};

pub const Options = struct {
    owner: ?c.HWND,
    heading: []const u8,
    body: []const u8 = "",
    responses: []const Response,
    /// The response Enter picks.
    default: u16,
    /// The colors: libadwaita's dark or light.
    dark: bool,
    /// An entry under the body (the extra child of GTK's title prompt),
    /// holding this text selected, with the keyboard in it.
    entry: ?[]const u8 = null,
    /// A read-only text box under the body (the clipboard confirmation's,
    /// the config errors').
    text: ?Text = null,
    /// A row under the text box with a switch, off at first.
    remember: ?Remember = null,
    /// Responses that run `action` and leave the dialog open.
    stay: ?Stay = null,

    pub const Text = struct {
        /// Shown as is: lines broken with CRLF.
        content: [:0]const u16,
        /// In DIP: GTK's widths and heights.
        min_width: c_int = 500,
        height: c_int = 200,
        monospace: bool = false,
    };

    pub const Remember = struct {
        title: []const u8,
        subtitle: []const u8,
    };

    pub const Stay = struct {
        ids: []const u16,
        ctx: *anyopaque,
        action: *const fn (*anyopaque, u16) void,
    };
};

/// The entry's or text box's control id, and the remember switch's, for
/// the GUI tests.
pub const id_entry = 100;
pub const id_text = 100;
pub const id_remember = 101;
/// The body: a static control, so screen readers read it (and it names
/// the entry after it).
const id_body = 102;

/// The response chosen, what the entry held then (the caller frees it;
/// null without an entry, or if it couldn't be read), and the switch.
pub const Result = struct {
    id: c_int,
    text: ?[]u8 = null,
    remember: bool = false,
};

/// Unscaled metrics, in DIP.
const width = 372;
const pad_top = 32;
const pad_side = 24;
const heading_gap = 10;
const pad_message_bottom = 9;
const area_pad = 24;
const area_pad_top = 12;
const button_height = 44;
const button_gap = 12;
const button_pad_x = 20;
const button_radius = 12;
/// The extra child: 8 below the usual spacing; an entry 34 tall, rounded
/// 6, its text 9 in; a text box rounded 10 (Ghostty's), its text 8 in; the
/// remember row 12 below it, a card rounded 12 with 12 inside, its switch
/// 46 x 26.
const child_gap = heading_gap + 8;
const entry_height = 34;
const entry_radius = 6;
const entry_pad_x = 9;
const text_radius = 10;
const text_margin = 8;
const row_gap = 12;
const row_pad = 12;
const row_radius = 12;
const switch_width = 46;
const switch_height = 26;

const State = struct {
    alloc: Allocator,
    opts: Options,
    heading: [:0]const u16,
    body: [:0]const u16,
    remember_title: [:0]const u16,
    remember_subtitle: [:0]const u16,
    dpi: c.UINT = c.USER_DEFAULT_SCREEN_DPI,
    pal: draw.DialogPalette,
    heading_font: ?c.HFONT = null,
    body_font: ?c.HFONT = null,
    button_font: ?c.HFONT = null,
    small_font: ?c.HFONT = null,
    mono_font: ?c.HFONT = null,
    entry_brush: ?c.HBRUSH = null,
    view_brush: ?c.HBRUSH = null,
    bg_brush: ?c.HBRUSH = null,
    /// The procedure the response buttons had (Button's).
    button_proc: isize = 0,
    heading_rect: c.RECT = .{},
    body_rect: c.RECT = .{},
    /// The entry's or the text box's.
    child_rect: c.RECT = .{},
    entry_focused: bool = false,
    /// What the entry held when a response was chosen.
    entry_text: ?[]u8 = null,
    /// The switch, and the procedure its button had.
    remember: bool = false,
    remember_proc: isize = 0,

    fn scale(self: *const State, v: c_int) c_int {
        return draw.scale(self.dpi, v);
    }

    fn deinit(self: *State) void {
        for ([_]?c.HFONT{ self.heading_font, self.body_font, self.button_font, self.small_font, self.mono_font }) |f| if (f) |font| {
            _ = c.DeleteObject(font);
        };
        for ([_]?c.HBRUSH{ self.entry_brush, self.view_brush, self.bg_brush }) |b| if (b) |brush| {
            _ = c.DeleteObject(brush);
        };
    }
};

/// Show the dialog and return the chosen response (IDCANCEL for Escape or
/// Alt+F4), or null if it couldn't be shown.
pub fn run(alloc: Allocator, opts: Options) ?Result {
    var template: std.ArrayList(u8) = .empty;
    defer template.deinit(alloc);
    buildTemplate(alloc, &template, opts) catch return null;

    const heading = text_util.utf16Lossy(alloc, opts.heading) catch return null;
    defer alloc.free(heading);
    const body = text_util.utf16Lossy(alloc, opts.body) catch return null;
    defer alloc.free(body);
    const remember = opts.remember orelse Options.Remember{ .title = "", .subtitle = "" };
    const title = text_util.utf16Lossy(alloc, remember.title) catch return null;
    defer alloc.free(title);
    const subtitle = text_util.utf16Lossy(alloc, remember.subtitle) catch return null;
    defer alloc.free(subtitle);
    var state: State = .{
        .alloc = alloc,
        .opts = opts,
        .heading = heading,
        .body = body,
        .remember_title = title,
        .remember_subtitle = subtitle,
        .pal = draw.dialogPalette(opts.dark),
    };
    defer state.deinit();

    // libadwaita dims the window behind a dialog: its shade color at
    // twice its opacity (50% in dark, 14% in light).
    const dim = if (opts.owner) |owner| dimOver(owner, if (opts.dark) 128 else 36) else null;
    defer if (dim) |d| {
        _ = c.DestroyWindow(d);
    };

    const ret = c.DialogBoxIndirectParamW(
        c.GetModuleHandleW(null),
        @ptrCast(template.items.ptr),
        opts.owner,
        &dialogProc,
        @bitCast(@intFromPtr(&state)),
    );
    if (ret == -1) {
        log.warn("alert dialog failed err={}", .{c.GetLastError()});
        if (state.entry_text) |t| alloc.free(t);
        return null;
    }
    return .{ .id = @intCast(ret), .text = state.entry_text, .remember = state.remember };
}

/// A layered child over `owner`'s client area, black at `alpha`.
fn dimOver(owner: c.HWND, alpha: u8) ?c.HWND {
    var client: c.RECT = .{};
    _ = c.GetClientRect(owner, &client);
    const dim = c.CreateWindowExW(
        c.WS_EX_LAYERED,
        CommandPalette.dim_class_name,
        c.L(""),
        c.WS_CHILD | c.WS_CLIPSIBLINGS,
        0,
        0,
        client.right,
        client.bottom,
        owner,
        null,
        c.GetModuleHandleW(null),
        null,
    ) orelse return null;
    _ = c.SetLayeredWindowAttributes(dim, 0, alpha, c.LWA_ALPHA);
    _ = c.SetWindowPos(dim, c.HWND_TOP, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOACTIVATE | c.SWP_SHOWWINDOW);
    return dim;
}

/// A popup with no caption: the body, the entry or text box, the remember
/// switch and one owner-drawn button per response, in that order (Tab's),
/// sized and placed when it starts (WM_INITDIALOG).
fn buildTemplate(alloc: Allocator, out: *std.ArrayList(u8), opts: Options) !void {
    const put16 = TitleDialog.put16;
    const put32 = TitleDialog.put32;
    const child = opts.entry != null or opts.text != null;
    const items = opts.responses.len + @intFromBool(opts.body.len > 0) + @intFromBool(child) + @intFromBool(opts.remember != null);
    try put32(alloc, out, c.WS_POPUP | c.WS_CLIPCHILDREN);
    try put32(alloc, out, 0);
    try put16(alloc, out, @intCast(items));
    for ([_]i16{ 0, 0, 200, 100 }) |v| try put16(alloc, out, @bitCast(v));
    try put16(alloc, out, 0); // no menu
    try put16(alloc, out, 0); // the standard dialog class
    // Replaced by the heading (WM_INITDIALOG).
    try TitleDialog.putString(alloc, out, "murrtty");
    const edit_class = 0x0081;
    const button_class = 0x0080;
    const static_class = 0x0082;
    const shown = c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP;
    // Its text is set at the start (it needn't be ASCII).
    if (opts.body.len > 0) {
        try TitleDialog.putItem(alloc, out, c.WS_CHILD | c.WS_VISIBLE | c.SS_CENTER | c.SS_NOPREFIX, .{ 0, 0, 10, 10 }, id_body, static_class, "");
    }
    if (opts.entry != null) {
        try TitleDialog.putItem(alloc, out, shown | c.ES_AUTOHSCROLL, .{ 0, 0, 10, 10 }, id_entry, edit_class, "");
    } else if (opts.text != null) {
        const style = shown | c.WS_VSCROLL | c.WS_HSCROLL | c.ES_MULTILINE | c.ES_READONLY | c.ES_AUTOVSCROLL | c.ES_AUTOHSCROLL;
        try TitleDialog.putItem(alloc, out, style, .{ 0, 0, 10, 10 }, id_text, edit_class, "");
    }
    if (opts.remember != null) {
        try TitleDialog.putItem(alloc, out, shown | c.BS_OWNERDRAW, .{ 0, 0, 10, 10 }, id_remember, button_class, "");
    }
    for (opts.responses) |r| {
        try TitleDialog.putItem(alloc, out, shown | c.BS_OWNERDRAW, .{ 0, 0, 10, 10 }, r.id, button_class, r.label);
    }
}

fn fromHwnd(hwnd: c.HWND) ?*State {
    const ptr: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA));
    return if (ptr != 0) @ptrFromInt(ptr) else null;
}

fn dialogProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) isize {
    switch (msg) {
        c.WM_INITDIALOG => {
            const state: *State = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, lparam);
            // No caption shows it; Alt+Tab and the GUI tests read it.
            _ = c.SetWindowTextW(hwnd, state.heading.ptr);
            if (c.GetDlgItem(hwnd, id_body)) |body| _ = c.SetWindowTextW(body, state.body.ptr);
            // The switch named by its title, for screen readers.
            if (c.GetDlgItem(hwnd, id_remember)) |sw| _ = c.SetWindowTextW(sw, state.remember_title.ptr);
            // Enter clicks the response button with the keyboard, not the
            // default one (owner-drawn buttons never become the default).
            for (state.opts.responses) |r| if (c.GetDlgItem(hwnd, r.id)) |button| {
                const prev = c.SetWindowLongPtrW(button, c.GWLP_WNDPROC, @bitCast(@intFromPtr(&buttonProc)));
                if (state.button_proc == 0) state.button_proc = prev;
            };
            layout(hwnd, state);
            const corner = c.DWMWCP_ROUND;
            _ = c.DwmSetWindowAttribute(hwnd, c.DWMWA_WINDOW_CORNER_PREFERENCE, &corner, @sizeOf(c_int));
            _ = c.SendMessageW(hwnd, c.DM_SETDEFID, state.opts.default, 0);
            if (state.opts.text) |t| if (c.GetDlgItem(hwnd, id_text)) |edit| {
                _ = c.SetWindowTextW(edit, t.content.ptr);
                // Its scroll bars light or dark as the dialog is.
                _ = c.SetWindowTheme(edit, if (state.opts.dark) c.L("DarkMode_Explorer") else c.L("Explorer"), null);
            };
            // The switch answers BM_GETCHECK and BM_SETCHECK as a check box
            // would (the GUI tests set it so).
            if (c.GetDlgItem(hwnd, id_remember)) |button| {
                state.remember_proc = c.SetWindowLongPtrW(button, c.GWLP_WNDPROC, @bitCast(@intFromPtr(&rememberProc)));
            }
            if (state.opts.entry) |initial| if (c.GetDlgItem(hwnd, id_entry)) |edit| {
                // The text, selected, with the keyboard in it (a program's
                // title may hold invalid UTF-8: U+FFFD for it).
                const wide = text_util.utf16Lossy(state.alloc, initial) catch null;
                defer if (wide) |wd| state.alloc.free(wd);
                if (wide) |wd| _ = c.SetWindowTextW(edit, wd.ptr);
                _ = c.SendMessageW(edit, c.EM_SETSEL, 0, -1);
                _ = c.SetFocus(edit);
                return 0;
            };
            if (c.GetDlgItem(hwnd, state.opts.default)) |b| _ = c.SetFocus(b);
            // Not the default focus: it is set.
            return 0;
        },
        c.WM_CTLCOLOREDIT => {
            const state = fromHwnd(hwnd) orelse return 0;
            const dc: c.HDC = @ptrFromInt(wparam);
            _ = c.SetTextColor(dc, state.pal.text);
            _ = c.SetBkColor(dc, state.pal.button);
            return @bitCast(@intFromPtr(state.entry_brush));
        },
        // The body on the dialog's color, the read-only text box on the
        // view's.
        c.WM_CTLCOLORSTATIC => {
            const state = fromHwnd(hwnd) orelse return 0;
            const dc: c.HDC = @ptrFromInt(wparam);
            _ = c.SetTextColor(dc, state.pal.text);
            const body = c.GetDlgItem(hwnd, id_body);
            if (body != null and lparam == @as(c.LPARAM, @bitCast(@intFromPtr(body.?)))) {
                _ = c.SetBkColor(dc, state.pal.bg);
                return @bitCast(@intFromPtr(state.bg_brush));
            }
            _ = c.SetBkColor(dc, state.pal.view);
            return @bitCast(@intFromPtr(state.view_brush));
        },
        c.WM_ERASEBKGND => {
            const state = fromHwnd(hwnd) orelse return 0;
            var r: c.RECT = .{};
            _ = c.GetClientRect(hwnd, &r);
            draw.fill(@ptrFromInt(wparam), r, state.pal.bg);
            return 1;
        },
        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = undefined;
            const dc = c.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = c.EndPaint(hwnd, &ps);
            const state = fromHwnd(hwnd) orelse return 0;
            paint(state, dc);
            return 0;
        },
        c.WM_DRAWITEM => {
            const state = fromHwnd(hwnd) orelse return 0;
            const item: *const c.DRAWITEMSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (item.CtlID == id_remember) drawRemember(state, item) else drawButton(state, item);
            return 1;
        },
        c.WM_COMMAND => {
            const id = c.loword(wparam);
            const code = c.hiword(wparam);
            const state = fromHwnd(hwnd) orelse return 0;
            if (id == id_entry and state.opts.entry != null) {
                switch (c.hiword(wparam)) {
                    c.EN_SETFOCUS, c.EN_KILLFOCUS => {
                        state.entry_focused = c.hiword(wparam) == c.EN_SETFOCUS;
                        const ring = state.scale(4);
                        const r = state.child_rect;
                        _ = c.InvalidateRect(hwnd, &.{ .left = r.left - ring, .top = r.top - ring, .right = r.right + ring, .bottom = r.bottom + ring }, c.TRUE);
                    },
                    else => {},
                }
                return 0;
            }
            if (id == id_text or id == id_body) return 0;
            if (id == id_remember) {
                // A double click's second click comes as BN_DOUBLECLICKED.
                if (code == c.BN_CLICKED or code == c.BN_DOUBLECLICKED) {
                    state.remember = !state.remember;
                    if (c.GetDlgItem(hwnd, id_remember)) |b| _ = c.InvalidateRect(b, null, c.FALSE);
                }
                return 0;
            }
            // A response's click, not a double click's second one (Open
            // Configuration would open the file twice).
            if (code != c.BN_CLICKED) return 0;
            if (state.opts.stay) |stay| for (stay.ids) |s| if (s == id) {
                stay.action(stay.ctx, id);
                return 1;
            };
            // A response, or Escape (IDCANCEL).
            const chosen = for (state.opts.responses) |r| {
                if (r.id == id) break id;
            } else if (id == c.IDCANCEL) c.IDCANCEL else return 0;
            readEntry(hwnd, state);
            _ = c.EndDialog(hwnd, chosen);
            return 1;
        },
        c.WM_CLOSE => {
            _ = c.EndDialog(hwnd, c.IDCANCEL);
            return 1;
        },
        else => {},
    }
    return 0;
}

/// The heading (the body is its own control), and the entry's or text
/// box's rounded box.
fn paint(state: *const State, dc: c.HDC) void {
    _ = c.SetBkMode(dc, c.TRANSPARENT);
    _ = c.SetTextColor(dc, state.pal.text);
    if (state.heading.len > 0) {
        const old = if (state.heading_font) |f| c.SelectObject(dc, f) else null;
        defer if (old) |o| {
            _ = c.SelectObject(dc, o);
        };
        var hr = state.heading_rect;
        _ = c.DrawTextW(dc, state.heading.ptr, @intCast(state.heading.len), &hr, c.DT_CENTER | c.DT_WORDBREAK | c.DT_NOPREFIX);
    }
    const r = state.child_rect;
    if (state.opts.entry != null) {
        // libadwaita's entry, 10% of the text, ringed in the accent while
        // it has the keyboard.
        const radius = state.scale(entry_radius);
        if (state.entry_focused) {
            const ring = @max(1, state.scale(2));
            draw.roundRect(dc, .{ .left = r.left - ring, .top = r.top - ring, .right = r.right + ring, .bottom = r.bottom + ring }, radius + ring, state.pal.focus, null, 0);
        }
        draw.roundRect(dc, r, radius, state.pal.button, null, 0);
    } else if (state.opts.text != null) {
        draw.roundRect(dc, r, state.scale(text_radius), state.pal.view, null, 0);
    }
}

/// The switch's button: answers BM_GETCHECK and BM_SETCHECK from the
/// dialog's state, and toggles on Enter as on a click (libadwaita's row
/// activates), else is the button it was.
fn rememberProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const dialog = c.GetParent(hwnd);
    const state = if (dialog) |d| fromHwnd(d) else null;
    if (state) |s| {
        if (enterClick(hwnd, dialog.?, msg, wparam, lparam)) |r| return r;
        switch (msg) {
            c.BM_GETCHECK => return if (s.remember) c.BST_CHECKED else 0,
            c.BM_SETCHECK => {
                s.remember = wparam == c.BST_CHECKED;
                _ = c.InvalidateRect(hwnd, null, c.FALSE);
                return 0;
            },
            else => return c.CallWindowProcW(s.remember_proc, hwnd, msg, wparam, lparam),
        }
    }
    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// A response's button: Enter clicks it while it has the keyboard, as in
/// GTK's dialogs, where Windows would take the default response (it never
/// makes an owner-drawn button the default). Else the button it was.
fn buttonProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const dialog = c.GetParent(hwnd);
    const state = if (dialog) |d| fromHwnd(d) else null;
    if (state) |s| {
        if (enterClick(hwnd, dialog.?, msg, wparam, lparam)) |r| return r;
        return c.CallWindowProcW(s.button_proc, hwnd, msg, wparam, lparam);
    }
    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// Enter on a focused button: it asks the dialog manager for the key
/// (WM_GETDLGCODE) and, given it, clicks itself. Null for anything else.
fn enterClick(hwnd: c.HWND, dialog: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) ?c.LRESULT {
    switch (msg) {
        c.WM_GETDLGCODE => if (lparam != 0) {
            const m: *const c.MSG = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (m.message == c.WM_KEYDOWN and m.wParam == c.VK_RETURN) return c.DLGC_WANTALLKEYS;
        },
        c.WM_KEYDOWN => if (wparam == c.VK_RETURN) {
            const id: usize = @intCast(c.GetDlgCtrlID(hwnd));
            _ = c.SendMessageW(dialog, c.WM_COMMAND, id, @bitCast(@intFromPtr(hwnd)));
            return 0;
        },
        else => {},
    }
    return null;
}

/// What the entry holds, as UTF-8, into `state.entry_text` (left null if
/// it can't be read: a lone surrogate, no memory).
fn readEntry(hwnd: c.HWND, state: *State) void {
    if (state.opts.entry == null or state.entry_text != null) return;
    const edit = c.GetDlgItem(hwnd, id_entry) orelse return;
    var buf: [1024]u16 = undefined;
    const n: usize = @intCast(@max(c.GetWindowTextW(edit, &buf, buf.len), 0));
    state.entry_text = std.unicode.utf16LeToUtf8Alloc(state.alloc, buf[0..n]) catch null;
}

/// Fonts at the owner's DPI, the heading's, body's and child's places, the
/// buttons in their row, the dialog's size, centered over its owner.
fn layout(hwnd: c.HWND, state: *State) void {
    state.dpi = c.GetDpiForWindow(state.opts.owner orelse hwnd);
    state.heading_font = draw.chromeFontSized(state.dpi, null, 15, true);
    state.body_font = draw.chromeFont(state.dpi, null, false);
    state.button_font = draw.chromeFont(state.dpi, null, true);
    state.small_font = draw.chromeFontSized(state.dpi, null, 9, false);
    state.entry_brush = c.CreateSolidBrush(state.pal.button);
    state.view_brush = c.CreateSolidBrush(state.pal.view);
    state.bg_brush = c.CreateSolidBrush(state.pal.bg);

    const content_w = if (state.opts.text) |t| t.min_width + 2 * pad_side else 0;
    const w = state.scale(@max(width, content_w));
    const side = state.scale(pad_side);
    const text_w = w - 2 * side;
    const dc = c.GetDC(hwnd) orelse return;
    defer _ = c.ReleaseDC(hwnd, dc);
    var y = state.scale(pad_top);
    const heading_h = textHeight(dc, state.heading_font, state.heading, text_w);
    state.heading_rect = .{ .left = side, .top = y, .right = side + text_w, .bottom = y + heading_h };
    y += heading_h;
    if (state.body.len > 0) {
        y += state.scale(heading_gap);
        const body_h = textHeight(dc, state.body_font, state.body, text_w);
        state.body_rect = .{ .left = side, .top = y, .right = side + text_w, .bottom = y + body_h };
        if (c.GetDlgItem(hwnd, id_body)) |body| {
            _ = c.SendMessageW(body, c.WM_SETFONT, @intFromPtr(state.body_font), 0);
            _ = c.SetWindowPos(body, null, side, y, text_w, body_h, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
        }
        y += body_h;
    }
    if (state.opts.entry != null) if (c.GetDlgItem(hwnd, id_entry)) |edit| {
        y += state.scale(child_gap);
        state.child_rect = .{ .left = side, .top = y, .right = side + text_w, .bottom = y + state.scale(entry_height) };
        // The edit control inside the box, its text 9 in, centered.
        _ = c.SendMessageW(edit, c.WM_SETFONT, @intFromPtr(state.body_font), 0);
        const line = textHeight(dc, state.body_font, std.unicode.utf8ToUtf16LeStringLiteral("Ag"), text_w) + 2;
        const r = state.child_rect;
        _ = c.SetWindowPos(edit, null, r.left + state.scale(entry_pad_x), r.top + @divTrunc(r.bottom - r.top - line, 2), r.right - r.left - 2 * state.scale(entry_pad_x), line, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
        y += state.scale(entry_height);
    };
    if (state.opts.text) |t| if (c.GetDlgItem(hwnd, id_text)) |edit| {
        y += state.scale(child_gap);
        state.child_rect = .{ .left = side, .top = y, .right = side + text_w, .bottom = y + state.scale(t.height) };
        if (t.monospace) state.mono_font = monoFont(state.dpi);
        _ = c.SendMessageW(edit, c.WM_SETFONT, @intFromPtr(state.mono_font orelse state.body_font), 0);
        // Inside the rounded box, the text 8 in (the scroll bars within).
        const m = state.scale(text_margin);
        const r = state.child_rect;
        _ = c.SetWindowPos(edit, null, r.left + m, r.top + m, r.right - r.left - 2 * m, r.bottom - r.top - 2 * m, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
        y += state.scale(t.height);
    };
    if (state.opts.remember != null) if (c.GetDlgItem(hwnd, id_remember)) |button| {
        y += state.scale(row_gap);
        const pad = state.scale(row_pad);
        // As drawRemember lays the text out: clear of the switch.
        const line_w = text_w - 3 * pad - state.scale(switch_width);
        const title_h = textHeight(dc, state.body_font, state.remember_title, line_w);
        const subtitle_h = textHeight(dc, state.small_font, state.remember_subtitle, line_w);
        const row_h = @max(state.scale(50), pad + title_h + state.scale(2) + subtitle_h + pad);
        _ = c.SetWindowPos(button, null, side, y, text_w, row_h, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
        y += row_h;
    };
    y += state.scale(pad_message_bottom) + state.scale(area_pad_top);

    // The buttons share the row, or stack, the first at the bottom, when a
    // label doesn't fit.
    const responses = state.opts.responses;
    const n: c_int = @intCast(responses.len);
    const row_w = w - 2 * state.scale(area_pad);
    const gap = state.scale(button_gap);
    const each = @divTrunc(row_w - gap * (n - 1), @max(n, 1));
    var fits = true;
    for (responses) |r| {
        const label_w = labelWidth(dc, state.button_font, r.label);
        if (label_w + 2 * state.scale(button_pad_x) > each) fits = false;
    }
    const bh = state.scale(button_height);
    const left = state.scale(area_pad);
    for (responses, 0..) |r, i| {
        const button = c.GetDlgItem(hwnd, r.id) orelse continue;
        const k: c_int = @intCast(i);
        const rect: c.RECT = if (fits)
            .{ .left = left + k * (each + gap), .top = y, .right = left + k * (each + gap) + each, .bottom = y + bh }
        else
            .{ .left = left, .top = y + (n - 1 - k) * (bh + gap), .right = left + row_w, .bottom = y + (n - 1 - k) * (bh + gap) + bh };
        _ = c.SetWindowPos(button, null, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
    }
    y += if (fits) bh else n * bh + (n - 1) * gap;
    y += state.scale(area_pad);

    // Centered over the owner (libadwaita's floating dialog), where it is
    // when restored if it is minimized (its rectangle is then far off
    // screen), and inside its monitor's work area.
    var x: c_int = 0;
    var top: c_int = 0;
    if (state.opts.owner) |owner| {
        var o: c.RECT = .{};
        _ = c.GetWindowRect(owner, &o);
        if (c.IsIconic(owner) != 0) {
            var placement: c.WINDOWPLACEMENT = .{};
            if (c.GetWindowPlacement(owner, &placement) != 0) o = placement.rcNormalPosition;
        }
        x = o.left + @divTrunc(o.right - o.left - w, 2);
        top = o.top + @divTrunc(o.bottom - o.top - y, 2);
    }
    const wanted: c.RECT = .{ .left = x, .top = top, .right = x + w, .bottom = top + y };
    if (c.MonitorFromRect(&wanted, c.MONITOR_DEFAULTTONEAREST)) |monitor| {
        var info: c.MONITORINFO = .{};
        if (c.GetMonitorInfoW(monitor, &info) != 0) {
            const work = info.rcWork;
            x = std.math.clamp(x, work.left, @max(work.left, work.right - w));
            top = std.math.clamp(top, work.top, @max(work.top, work.bottom - y));
        }
    }
    _ = c.SetWindowPos(hwnd, null, x, top, w, y, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
}

/// A monospace font for a text box: Consolas 11 pt (GNOME's monospace is
/// 11 pt too).
fn monoFont(dpi: c.UINT) ?c.HFONT {
    var lf: c.LOGFONTW = std.mem.zeroes(c.LOGFONTW);
    lf.lfHeight = -@as(c_long, @intCast((11 * dpi + 36) / 72));
    lf.lfWeight = 400;
    lf.lfQuality = 4; // ANTIALIASED_QUALITY, as the chrome's text
    lf.lfPitchAndFamily = 0x31; // FIXED_PITCH | FF_MODERN, if Consolas is missing
    const face = std.unicode.utf8ToUtf16LeStringLiteral("Consolas");
    @memcpy(lf.lfFaceName[0..face.len], face);
    return c.CreateFontIndirectW(&lf);
}

fn textHeight(dc: c.HDC, font: ?c.HFONT, text: []const u16, w: c_int) c_int {
    if (text.len == 0) return 0;
    const old = if (font) |f| c.SelectObject(dc, f) else null;
    defer if (old) |o| {
        _ = c.SelectObject(dc, o);
    };
    var r: c.RECT = .{ .right = w };
    _ = c.DrawTextW(dc, text.ptr, @intCast(text.len), &r, c.DT_CENTER | c.DT_WORDBREAK | c.DT_NOPREFIX | c.DT_CALCRECT);
    return r.bottom - r.top;
}

fn labelWidth(dc: c.HDC, font: ?c.HFONT, label: []const u8) c_int {
    const old = if (font) |f| c.SelectObject(dc, f) else null;
    defer if (old) |o| {
        _ = c.SelectObject(dc, o);
    };
    var buf: [64]u16 = undefined;
    const n = @min(label.len, buf.len);
    for (label[0..n], 0..) |b, i| buf[i] = b;
    var r: c.RECT = .{};
    _ = c.DrawTextW(dc, &buf, @intCast(n), &r, c.DT_SINGLELINE | c.DT_CALCRECT);
    return r.right - r.left;
}

/// The remember row: libadwaita's switch row, a card holding the title and
/// a dimmer subtitle, the switch at its end.
fn drawRemember(state: *const State, item: *const c.DRAWITEMSTRUCT) void {
    const dc = item.hDC;
    const r = item.rcItem;
    const pal = state.pal;
    draw.fill(dc, r, pal.bg);
    draw.roundRect(dc, r, state.scale(row_radius), pal.card, null, 0);
    if (item.itemState & c.ODS_FOCUS != 0 and item.itemState & c.ODS_NOFOCUSRECT == 0) {
        draw.roundRect(dc, r, state.scale(row_radius), null, pal.focus, @max(1, state.scale(2)));
    }
    const pad = state.scale(row_pad);
    const sw = state.scale(switch_width);
    const sh = state.scale(switch_height);
    const text_right = r.right - pad - sw - pad;
    _ = c.SetBkMode(dc, c.TRANSPARENT);
    var y = r.top + pad;
    for ([_]struct { []const u16, ?c.HFONT, c.COLORREF }{
        .{ state.remember_title, state.body_font, pal.text },
        .{ state.remember_subtitle, state.small_font, pal.subtitle },
    }) |line| {
        const old = if (line[1]) |f| c.SelectObject(dc, f) else null;
        defer if (old) |o| {
            _ = c.SelectObject(dc, o);
        };
        _ = c.SetTextColor(dc, line[2]);
        var tr: c.RECT = .{ .left = r.left + pad, .top = y, .right = text_right, .bottom = r.bottom };
        const h = c.DrawTextW(dc, line[0].ptr, @intCast(line[0].len), &tr, c.DT_WORDBREAK | c.DT_NOPREFIX);
        y += h + state.scale(2);
    }
    // The switch: a pill track, the accent when on, a white knob.
    const track: c.RECT = .{ .left = r.right - pad - sw, .top = r.top + @divTrunc(r.bottom - r.top - sh, 2), .right = r.right - pad, .bottom = r.top + @divTrunc(r.bottom - r.top - sh, 2) + sh };
    draw.roundRect(dc, track, @divTrunc(sh, 2), if (state.remember) pal.switch_on else pal.switch_off, null, 0);
    const inset = state.scale(3);
    const knob = sh - 2 * inset;
    const kx = if (state.remember) track.right - inset - knob else track.left + inset;
    draw.roundRect(dc, .{ .left = kx, .top = track.top + inset, .right = kx + knob, .bottom = track.top + inset + knob }, @divTrunc(knob, 2), pal.knob, null, 0);
}

/// A response's button: a rounded pill, its label bold and centered.
fn drawButton(state: *const State, item: *const c.DRAWITEMSTRUCT) void {
    const dc = item.hDC;
    const r = item.rcItem;
    const pal = state.pal;
    const pressed = item.itemState & c.ODS_SELECTED != 0;
    const appearance = for (state.opts.responses) |resp| {
        if (resp.id == item.CtlID) break resp.appearance;
    } else .normal;
    const back, const text = switch (appearance) {
        .normal => .{ if (pressed) pal.button_pressed else pal.button, pal.text },
        .destructive => .{ if (pressed) pal.destructive_pressed else pal.destructive, pal.destructive_text },
        .suggested => .{ if (pressed) pal.suggested_pressed else pal.suggested, pal.suggested_text },
    };
    draw.fill(dc, r, pal.bg);
    const radius = state.scale(button_radius);
    // The keyboard's focus: libadwaita's ring, the accent around it.
    if (item.itemState & c.ODS_FOCUS != 0 and item.itemState & c.ODS_NOFOCUSRECT == 0) {
        draw.roundRect(dc, r, radius, pal.focus, null, 0);
        const ring = @max(1, state.scale(2));
        draw.roundRect(dc, .{ .left = r.left + ring, .top = r.top + ring, .right = r.right - ring, .bottom = r.bottom - ring }, radius - ring, back, null, 0);
    } else {
        draw.roundRect(dc, r, radius, back, null, 0);
    }
    var label: [64]u16 = undefined;
    const n: usize = @intCast(@max(c.GetWindowTextW(item.hwndItem, &label, label.len), 0));
    const old = if (state.button_font) |f| c.SelectObject(dc, f) else null;
    defer if (old) |o| {
        _ = c.SelectObject(dc, o);
    };
    _ = c.SetBkMode(dc, c.TRANSPARENT);
    _ = c.SetTextColor(dc, text);
    var tr = r;
    _ = c.DrawTextW(dc, &label, @intCast(n), &tr, c.DT_SINGLELINE | c.DT_VCENTER | c.DT_CENTER | c.DT_NOPREFIX);
}

test "alert dialog template: the child, the switch, a button per response" {
    const alloc = std.testing.allocator;
    const responses: []const Response = &.{ .{ .id = c.IDCANCEL, .label = "Cancel" }, .{ .id = c.IDYES, .label = "Close", .appearance = .destructive } };
    const text = std.unicode.utf8ToUtf16LeStringLiteral("text");
    for ([_]Options{
        .{ .owner = null, .heading = "", .responses = responses, .default = c.IDCANCEL, .dark = true },
        .{ .owner = null, .heading = "", .responses = responses, .default = c.IDCANCEL, .dark = true, .entry = "x" },
        .{ .owner = null, .heading = "", .responses = responses, .default = c.IDCANCEL, .dark = true, .text = .{ .content = text }, .remember = .{ .title = "a", .subtitle = "b" } },
    }, [_]u16{ 2, 3, 4 }) |opts, want| {
        var t: std.ArrayList(u8) = .empty;
        defer t.deinit(alloc);
        try buildTemplate(alloc, &t, opts);
        try std.testing.expectEqual(want, std.mem.readInt(u16, t.items[8..10], .little));
        try std.testing.expect(t.items.len % 2 == 0);
    }
}
