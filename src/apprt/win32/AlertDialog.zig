//! libadwaita's alert dialog (roadmap 4.3b), for murrtty's confirmations:
//! a heading and a body centered in the dialog's color, then its responses
//! as rounded buttons in a row (stacked when they don't fit), a destructive
//! one in the destructive color and a suggested one on the accent, over
//! the owner window dimmed as libadwaita dims behind a dialog. Sizes are
//! the current stylesheet's: 32 DIP above the heading, 10 between it and
//! the body, 24 at the sides, a response area padded 24 (12 above) with
//! buttons 44 tall, 12 apart and rounded 12, the heading 15 pt bold, the
//! rest 11 pt, the buttons bold.
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
};

/// The entry's control id, for the GUI tests.
pub const id_entry = 100;

/// The response chosen, and what the entry held then (the caller frees
/// it; null without an entry, or if it couldn't be read).
pub const Result = struct {
    id: c_int,
    text: ?[]u8 = null,
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
/// 6, its text 9 in.
const child_gap = heading_gap + 8;
const entry_height = 34;
const entry_radius = 6;
const entry_pad_x = 9;

const State = struct {
    alloc: Allocator,
    opts: Options,
    heading: [:0]const u16,
    body: [:0]const u16,
    dpi: c.UINT = c.USER_DEFAULT_SCREEN_DPI,
    pal: draw.DialogPalette,
    heading_font: ?c.HFONT = null,
    body_font: ?c.HFONT = null,
    button_font: ?c.HFONT = null,
    entry_brush: ?c.HBRUSH = null,
    heading_rect: c.RECT = .{},
    body_rect: c.RECT = .{},
    entry_rect: c.RECT = .{},
    entry_focused: bool = false,
    /// What the entry held when a response was chosen.
    entry_text: ?[]u8 = null,

    fn scale(self: *const State, v: c_int) c_int {
        return draw.scale(self.dpi, v);
    }

    fn deinit(self: *State) void {
        for ([_]?c.HFONT{ self.heading_font, self.body_font, self.button_font }) |f| if (f) |font| {
            _ = c.DeleteObject(font);
        };
        if (self.entry_brush) |b| _ = c.DeleteObject(b);
    }
};

/// Show the dialog and return the chosen response (IDCANCEL for Escape or
/// Alt+F4), or null if it couldn't be shown.
pub fn run(alloc: Allocator, opts: Options) ?Result {
    var template: std.ArrayList(u8) = .empty;
    defer template.deinit(alloc);
    buildTemplate(alloc, &template, opts.responses, opts.entry != null) catch return null;

    const heading = text_util.utf16Lossy(alloc, opts.heading) catch return null;
    defer alloc.free(heading);
    const body = text_util.utf16Lossy(alloc, opts.body) catch return null;
    defer alloc.free(body);
    var state: State = .{ .alloc = alloc, .opts = opts, .heading = heading, .body = body, .pal = draw.dialogPalette(opts.dark) };
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
    return .{ .id = @intCast(ret), .text = state.entry_text };
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

/// A popup with no caption, one owner-drawn button per response and the
/// entry, if any, sized and placed when it starts (WM_INITDIALOG).
fn buildTemplate(alloc: Allocator, out: *std.ArrayList(u8), responses: []const Response, entry: bool) !void {
    const put16 = TitleDialog.put16;
    const put32 = TitleDialog.put32;
    try put32(alloc, out, c.WS_POPUP | c.WS_CLIPCHILDREN);
    try put32(alloc, out, 0);
    try put16(alloc, out, @intCast(responses.len + @intFromBool(entry)));
    for ([_]i16{ 0, 0, 200, 100 }) |v| try put16(alloc, out, @bitCast(v));
    try put16(alloc, out, 0); // no menu
    try put16(alloc, out, 0); // the standard dialog class
    // Its text for Alt+Tab and the taskbar's.
    try TitleDialog.putString(alloc, out, "murrtty");
    // The entry first: Tab goes from it to the buttons.
    const edit_class = 0x0081;
    if (entry) try TitleDialog.putItem(alloc, out, c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.ES_AUTOHSCROLL, .{ 0, 0, 10, 10 }, id_entry, edit_class, "");
    const button_class = 0x0080;
    for (responses) |r| {
        try TitleDialog.putItem(alloc, out, c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_OWNERDRAW, .{ 0, 0, 10, 10 }, r.id, button_class, r.label);
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
            layout(hwnd, state);
            const corner = c.DWMWCP_ROUND;
            _ = c.DwmSetWindowAttribute(hwnd, c.DWMWA_WINDOW_CORNER_PREFERENCE, &corner, @sizeOf(c_int));
            _ = c.SendMessageW(hwnd, c.DM_SETDEFID, state.opts.default, 0);
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
            _ = c.SetBkMode(dc, c.TRANSPARENT);
            _ = c.SetTextColor(dc, state.pal.text);
            const flags: c.UINT = c.DT_CENTER | c.DT_WORDBREAK | c.DT_NOPREFIX;
            for ([_]struct { []const u16, ?c.HFONT, c.RECT }{
                .{ state.heading, state.heading_font, state.heading_rect },
                .{ state.body, state.body_font, state.body_rect },
            }) |part| {
                if (part[0].len == 0) continue;
                const old = if (part[1]) |f| c.SelectObject(dc, f) else null;
                defer if (old) |o| {
                    _ = c.SelectObject(dc, o);
                };
                var r = part[2];
                _ = c.DrawTextW(dc, part[0].ptr, @intCast(part[0].len), &r, flags);
            }
            // The entry's box (libadwaita's entry, 10% of the text), ringed
            // in the accent while it has the keyboard.
            if (state.opts.entry != null) {
                const r = state.entry_rect;
                const radius = state.scale(entry_radius);
                if (state.entry_focused) {
                    const ring = @max(1, state.scale(2));
                    draw.roundRect(dc, .{ .left = r.left - ring, .top = r.top - ring, .right = r.right + ring, .bottom = r.bottom + ring }, radius + ring, state.pal.focus, null, 0);
                }
                draw.roundRect(dc, r, radius, state.pal.button, null, 0);
            }
            return 0;
        },
        c.WM_DRAWITEM => {
            const state = fromHwnd(hwnd) orelse return 0;
            drawButton(state, @ptrFromInt(@as(usize, @bitCast(lparam))));
            return 1;
        },
        c.WM_COMMAND => {
            const id = c.loword(wparam);
            const state = fromHwnd(hwnd) orelse return 0;
            if (id == id_entry) {
                switch (c.hiword(wparam)) {
                    c.EN_SETFOCUS, c.EN_KILLFOCUS => {
                        state.entry_focused = c.hiword(wparam) == c.EN_SETFOCUS;
                        const ring = state.scale(4);
                        const r = state.entry_rect;
                        _ = c.InvalidateRect(hwnd, &.{ .left = r.left - ring, .top = r.top - ring, .right = r.right + ring, .bottom = r.bottom + ring }, c.TRUE);
                    },
                    else => {},
                }
                return 0;
            }
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

/// What the entry holds, as UTF-8, into `state.entry_text` (left null if
/// it can't be read: a lone surrogate, no memory).
fn readEntry(hwnd: c.HWND, state: *State) void {
    if (state.opts.entry == null or state.entry_text != null) return;
    const edit = c.GetDlgItem(hwnd, id_entry) orelse return;
    var buf: [1024]u16 = undefined;
    const n: usize = @intCast(@max(c.GetWindowTextW(edit, &buf, buf.len), 0));
    state.entry_text = std.unicode.utf16LeToUtf8Alloc(state.alloc, buf[0..n]) catch null;
}

/// Fonts at the owner's DPI, the heading's and body's places, the buttons
/// in their row, the dialog's size, centered over its owner.
fn layout(hwnd: c.HWND, state: *State) void {
    state.dpi = c.GetDpiForWindow(state.opts.owner orelse hwnd);
    state.heading_font = draw.chromeFontSized(state.dpi, null, 15, true);
    state.body_font = draw.chromeFont(state.dpi, null, false);
    state.button_font = draw.chromeFont(state.dpi, null, true);
    state.entry_brush = c.CreateSolidBrush(state.pal.button);

    const w = state.scale(width);
    const text_w = w - 2 * state.scale(pad_side);
    const dc = c.GetDC(hwnd) orelse return;
    defer _ = c.ReleaseDC(hwnd, dc);
    var y = state.scale(pad_top);
    const heading_h = textHeight(dc, state.heading_font, state.heading, text_w);
    state.heading_rect = .{ .left = state.scale(pad_side), .top = y, .right = state.scale(pad_side) + text_w, .bottom = y + heading_h };
    y += heading_h;
    if (state.body.len > 0) {
        y += state.scale(heading_gap);
        const body_h = textHeight(dc, state.body_font, state.body, text_w);
        state.body_rect = .{ .left = state.scale(pad_side), .top = y, .right = state.scale(pad_side) + text_w, .bottom = y + body_h };
        y += body_h;
    }
    if (state.opts.entry != null) if (c.GetDlgItem(hwnd, id_entry)) |edit| {
        y += state.scale(child_gap);
        state.entry_rect = .{ .left = state.scale(pad_side), .top = y, .right = state.scale(pad_side) + text_w, .bottom = y + state.scale(entry_height) };
        // The edit control inside the box, its text 9 in, centered.
        _ = c.SendMessageW(edit, c.WM_SETFONT, @intFromPtr(state.body_font), 0);
        const line = textHeight(dc, state.body_font, std.unicode.utf8ToUtf16LeStringLiteral("Ag"), text_w) + 2;
        const r = state.entry_rect;
        _ = c.SetWindowPos(edit, null, r.left + state.scale(entry_pad_x), r.top + @divTrunc(r.bottom - r.top - line, 2), r.right - r.left - 2 * state.scale(entry_pad_x), line, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
        y += state.scale(entry_height);
    };
    y += state.scale(pad_message_bottom) + state.scale(area_pad_top);

    // The buttons share the row, or stack when a label doesn't fit.
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
    for (responses, 0..) |r, i| {
        const button = c.GetDlgItem(hwnd, r.id) orelse continue;
        const k: c_int = @intCast(i);
        const rect: c.RECT = if (fits)
            .{ .left = state.scale(area_pad) + k * (each + gap), .top = y, .right = state.scale(area_pad) + k * (each + gap) + each, .bottom = y + bh }
        else
            .{ .left = state.scale(area_pad), .top = y + k * (bh + gap), .right = state.scale(area_pad) + row_w, .bottom = y + k * (bh + gap) + bh };
        _ = c.SetWindowPos(button, null, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
    }
    y += if (fits) bh else n * bh + (n - 1) * gap;
    y += state.scale(area_pad);

    // Centered over the owner (libadwaita's floating dialog).
    var x: c_int = 0;
    var top: c_int = 0;
    if (state.opts.owner) |owner| {
        var o: c.RECT = .{};
        _ = c.GetWindowRect(owner, &o);
        x = o.left + @divTrunc(o.right - o.left - w, 2);
        top = o.top + @divTrunc(o.bottom - o.top - y, 2);
    }
    _ = c.SetWindowPos(hwnd, null, x, top, w, y, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
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

test "alert dialog template: one button per response, and the entry" {
    const alloc = std.testing.allocator;
    const responses: []const Response = &.{ .{ .id = c.IDCANCEL, .label = "Cancel" }, .{ .id = c.IDYES, .label = "Close", .appearance = .destructive } };
    for ([_]bool{ false, true }) |entry| {
        var t: std.ArrayList(u8) = .empty;
        defer t.deinit(alloc);
        try buildTemplate(alloc, &t, responses, entry);
        try std.testing.expectEqual(@as(u16, if (entry) 3 else 2), std.mem.readInt(u16, t.items[8..10], .little));
        try std.testing.expect(t.items.len % 2 == 0);
    }
}
