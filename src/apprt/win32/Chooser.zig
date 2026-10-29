//! A chooser for the config editor's pages (roadmap F1c): fonts, themes,
//! a key binding's action. GTK has no such window to match, so it is drawn
//! as libadwaita's dialogs are (AlertDialog): a heading, a search entry,
//! the items in a rounded list, each a row with a title and a dimmer
//! subtitle or a preview of its own, then Cancel and Select (the suggested
//! response), over the owner dimmed.
//!
//! It is a real dialog, from a template built in memory: the entry, a
//! list box holding no data of its own (LBS_NODATA: a row is an index into
//! the items left by the search) and owner-drawn buttons with IDCANCEL and
//! IDOK, so Enter, Escape, Tab, a double click and the GUI tests work as
//! with any dialog. Up, Down, Page Up and Page Down in the entry move the
//! list's selection. A search lists a title it matches whole first, then
//! titles starting with it, holding it, and subtitles holding it, each in
//! the items' order. The caller runs it in a modal scope (App.beginModal).
const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig");
const draw = @import("draw.zig");
const text_util = @import("text.zig");
const AlertDialog = @import("AlertDialog.zig");
const TitleDialog = @import("TitleDialog.zig");

const log = std.log.scoped(.win32_chooser);

pub const Item = struct {
    /// What the row shows first and the search matches.
    title: []const u8,
    /// A dimmer line beneath it, also searched ("" for none).
    subtitle: []const u8 = "",
};

/// Draws a row's content instead of its title and subtitle: a font's
/// name in that font, a theme's colors.
pub const Preview = struct {
    ctx: *anyopaque,
    paint: *const fn (ctx: *anyopaque, dc: c.HDC, row: c.RECT, index: usize, look: *const Look) void,
};

/// What a preview draws with: the dialog's colors, fonts and DPI.
pub const Look = struct {
    dpi: c.UINT,
    pal: *const draw.DialogPalette,
    title_font: ?c.HFONT,
    subtitle_font: ?c.HFONT,
    selected: bool,

    pub fn scale(self: *const Look, v: c_int) c_int {
        return draw.scale(self.dpi, v);
    }
};

pub const Options = struct {
    owner: ?c.HWND,
    heading: []const u8,
    items: []const Item,
    /// The item selected at first, scrolled to.
    initial: ?usize = null,
    dark: bool,
    /// A row's height, in DIP.
    row_height: c_int = 50,
    preview: ?Preview = null,
    /// The suggested response's label (ASCII).
    select_label: []const u8 = "Select",
};

/// The search entry's and the list's control ids, for the GUI tests.
pub const id_search = 100;
pub const id_list = 101;

/// Unscaled metrics, in DIP: libadwaita's dialog spacing (AlertDialog's),
/// a list 340 tall in a card rounded 12.
const width = 460;
const list_height = 340;
const pad_top = 24;
const pad_side = 24;
const gap = 12;
const entry_height = 34;
const entry_radius = 6;
const entry_pad_x = 9;
const card_radius = 12;
const card_inset = 6;
const row_pad = 12;
const button_height = 44;
const button_gap = 12;
const button_radius = 12;

const State = struct {
    alloc: Allocator,
    opts: Options,
    heading: [:0]const u16,
    pal: draw.DialogPalette,
    dpi: c.UINT = c.USER_DEFAULT_SCREEN_DPI,
    heading_font: ?c.HFONT = null,
    title_font: ?c.HFONT = null,
    subtitle_font: ?c.HFONT = null,
    button_font: ?c.HFONT = null,
    entry_brush: ?c.HBRUSH = null,
    view_brush: ?c.HBRUSH = null,
    /// The items the search leaves, by index into opts.items.
    shown: std.ArrayList(usize) = .empty,
    heading_rect: c.RECT = .{},
    entry_rect: c.RECT = .{},
    card_rect: c.RECT = .{},
    entry_focused: bool = false,
    edit_proc: isize = 0,
    button_proc: isize = 0,
    chosen: ?usize = null,

    fn scale(self: *const State, v: c_int) c_int {
        return draw.scale(self.dpi, v);
    }

    fn deinit(self: *State) void {
        for ([_]?c.HFONT{ self.heading_font, self.title_font, self.subtitle_font, self.button_font }) |f| if (f) |font| {
            _ = c.DeleteObject(font);
        };
        for ([_]?c.HBRUSH{ self.entry_brush, self.view_brush }) |b| if (b) |brush| {
            _ = c.DeleteObject(brush);
        };
        self.shown.deinit(self.alloc);
    }
};

/// Show the chooser; the index of the item chosen, or null (Cancel,
/// Escape, or it couldn't be shown).
pub fn run(alloc: Allocator, opts: Options) ?usize {
    var template: std.ArrayList(u8) = .empty;
    defer template.deinit(alloc);
    buildTemplate(alloc, &template, opts) catch return null;
    const heading = text_util.utf16Lossy(alloc, opts.heading) catch return null;
    defer alloc.free(heading);
    var state: State = .{ .alloc = alloc, .opts = opts, .heading = heading, .pal = draw.dialogPalette(opts.dark) };
    defer state.deinit();

    const dim = if (opts.owner) |owner| AlertDialog.dimOver(owner, if (opts.dark) 128 else 36) else null;
    defer if (dim) |d| {
        _ = c.DestroyWindow(d);
    };
    const ret = c.DialogBoxIndirectParamW(c.GetModuleHandleW(null), @ptrCast(template.items.ptr), opts.owner, &dialogProc, @bitCast(@intFromPtr(&state)));
    if (ret == -1) {
        log.warn("chooser failed err={}", .{c.GetLastError()});
        return null;
    }
    return if (ret == c.IDOK) state.chosen else null;
}

/// How well `item` matches the search `query`, ignoring case: 0 its title
/// whole (or an empty search), 1 its title's start, 2 its title, 3 its
/// subtitle; null not at all.
pub fn rank(item: Item, query: []const u8) ?u2 {
    const q = std.mem.trim(u8, query, " \t");
    if (q.len == 0 or std.ascii.eqlIgnoreCase(item.title, q)) return 0;
    if (std.ascii.startsWithIgnoreCase(item.title, q)) return 1;
    if (std.ascii.findIgnoreCase(item.title, q) != null) return 2;
    if (std.ascii.findIgnoreCase(item.subtitle, q) != null) return 3;
    return null;
}

/// A popup with no caption: the entry, the list, Cancel and Select, in
/// that order (Tab's), sized and placed when it starts.
fn buildTemplate(alloc: Allocator, out: *std.ArrayList(u8), opts: Options) !void {
    const put16 = TitleDialog.put16;
    const put32 = TitleDialog.put32;
    try put32(alloc, out, c.WS_POPUP | c.WS_CLIPCHILDREN);
    try put32(alloc, out, 0);
    try put16(alloc, out, 4);
    for ([_]i16{ 0, 0, 200, 100 }) |v| try put16(alloc, out, @bitCast(v));
    try put16(alloc, out, 0); // no menu
    try put16(alloc, out, 0); // the standard dialog class
    try TitleDialog.putString(alloc, out, "murrtty");
    const edit_class = 0x0081;
    const button_class = 0x0080;
    const listbox_class = 0x0083;
    const shown = c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP;
    try TitleDialog.putItem(alloc, out, shown | c.ES_AUTOHSCROLL, .{ 0, 0, 10, 10 }, id_search, edit_class, "");
    try TitleDialog.putItem(alloc, out, shown | c.WS_VSCROLL | c.LBS_NOTIFY | c.LBS_OWNERDRAWFIXED | c.LBS_NODATA | c.LBS_NOINTEGRALHEIGHT, .{ 0, 0, 10, 10 }, id_list, listbox_class, "");
    try TitleDialog.putItem(alloc, out, shown | c.BS_OWNERDRAW, .{ 0, 0, 10, 10 }, c.IDCANCEL, button_class, "Cancel");
    try TitleDialog.putItem(alloc, out, shown | c.BS_OWNERDRAW, .{ 0, 0, 10, 10 }, c.IDOK, button_class, opts.select_label);
}

fn fromHwnd(hwnd: c.HWND) ?*State {
    const ptr: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA));
    return if (ptr != 0) @ptrFromInt(ptr) else null;
}

/// The items the search leaves, into the list; the selection kept if its
/// item stays, else the first row.
fn refilter(hwnd: c.HWND, state: *State) void {
    const list = c.GetDlgItem(hwnd, id_list) orelse return;
    const edit = c.GetDlgItem(hwnd, id_search);
    var buf: [256]u16 = undefined;
    const n: usize = if (edit) |e| @intCast(@max(c.GetWindowTextW(e, &buf, buf.len), 0)) else 0;
    const query = std.unicode.utf16LeToUtf8Alloc(state.alloc, buf[0..n]) catch return;
    defer state.alloc.free(query);
    const before = selectedItem(hwnd, state);
    state.shown.clearRetainingCapacity();
    for (0..4) |pass| {
        for (state.opts.items, 0..) |item, i| {
            const r = rank(item, query) orelse continue;
            if (r == pass) state.shown.append(state.alloc, i) catch break;
        }
    }
    _ = c.SendMessageW(list, c.LB_SETCOUNT, state.shown.items.len, 0);
    const row: usize = if (before) |b| (std.mem.indexOfScalar(usize, state.shown.items, b) orelse 0) else 0;
    if (state.shown.items.len > 0) _ = c.SendMessageW(list, c.LB_SETCURSEL, row, 0);
    _ = c.InvalidateRect(list, null, c.FALSE);
}

/// The item the list's selection is, if any.
fn selectedItem(hwnd: c.HWND, state: *const State) ?usize {
    const list = c.GetDlgItem(hwnd, id_list) orelse return null;
    const row = c.SendMessageW(list, c.LB_GETCURSEL, 0, 0);
    if (row < 0 or row >= state.shown.items.len) return null;
    return state.shown.items[@intCast(row)];
}

fn choose(hwnd: c.HWND, state: *State) void {
    state.chosen = selectedItem(hwnd, state) orelse return;
    _ = c.EndDialog(hwnd, c.IDOK);
}

fn dialogProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) isize {
    switch (msg) {
        c.WM_INITDIALOG => {
            const state: *State = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, lparam);
            _ = c.SetWindowTextW(hwnd, state.heading.ptr);
            for ([_]c_int{ c.IDCANCEL, c.IDOK }) |id| if (c.GetDlgItem(hwnd, id)) |button| {
                const prev = c.SetWindowLongPtrW(button, c.GWLP_WNDPROC, @bitCast(@intFromPtr(&buttonProc)));
                if (state.button_proc == 0) state.button_proc = prev;
            };
            if (c.GetDlgItem(hwnd, id_search)) |edit| {
                state.edit_proc = c.SetWindowLongPtrW(edit, c.GWLP_WNDPROC, @bitCast(@intFromPtr(&editProc)));
                _ = c.SendMessageW(edit, c.EM_SETCUEBANNER, 1, @bitCast(@intFromPtr(c.L("Search").ptr)));
            }
            layout(hwnd, state);
            const corner = c.DWMWCP_ROUND;
            _ = c.DwmSetWindowAttribute(hwnd, c.DWMWA_WINDOW_CORNER_PREFERENCE, &corner, @sizeOf(c_int));
            _ = c.SendMessageW(hwnd, c.DM_SETDEFID, c.IDOK, 0);
            refilter(hwnd, state);
            if (state.opts.initial) |i| if (std.mem.indexOfScalar(usize, state.shown.items, i)) |row| {
                if (c.GetDlgItem(hwnd, id_list)) |list| {
                    _ = c.SendMessageW(list, c.LB_SETCURSEL, row, 0);
                    // A few rows above it showing, where there are.
                    _ = c.SendMessageW(list, c.LB_SETTOPINDEX, row -| 3, 0);
                }
            };
            if (c.GetDlgItem(hwnd, id_search)) |edit| _ = c.SetFocus(edit);
            return 0;
        },
        c.WM_MEASUREITEM => {
            // Before WM_INITDIALOG, the list asks with no state yet: layout
            // sets the height at the DPI.
            const m: *c.MEASUREITEMSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            m.itemHeight = 40;
            return 1;
        },
        c.WM_CTLCOLOREDIT => {
            const state = fromHwnd(hwnd) orelse return 0;
            const dc: c.HDC = @ptrFromInt(wparam);
            _ = c.SetTextColor(dc, state.pal.text);
            _ = c.SetBkColor(dc, state.pal.button);
            return @bitCast(@intFromPtr(state.entry_brush));
        },
        c.WM_CTLCOLORLISTBOX => {
            const state = fromHwnd(hwnd) orelse return 0;
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
            if (item.CtlID == id_list) drawRow(state, item) else drawButton(state, item);
            return 1;
        },
        c.WM_COMMAND => {
            const id = c.loword(wparam);
            const code = c.hiword(wparam);
            const state = fromHwnd(hwnd) orelse return 0;
            switch (id) {
                id_search => switch (code) {
                    c.EN_CHANGE => refilter(hwnd, state),
                    c.EN_SETFOCUS, c.EN_KILLFOCUS => {
                        state.entry_focused = code == c.EN_SETFOCUS;
                        const ring = state.scale(4);
                        const r = state.entry_rect;
                        _ = c.InvalidateRect(hwnd, &.{ .left = r.left - ring, .top = r.top - ring, .right = r.right + ring, .bottom = r.bottom + ring }, c.TRUE);
                    },
                    else => {},
                },
                id_list => if (code == c.LBN_DBLCLK) choose(hwnd, state),
                c.IDOK => choose(hwnd, state),
                c.IDCANCEL => _ = c.EndDialog(hwnd, c.IDCANCEL),
                else => {},
            }
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

/// The entry: Up, Down, Page Up and Page Down move the list's selection
/// (the keyboard stays in the entry, as in GTK's choosers).
fn editProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const dialog = c.GetParent(hwnd);
    const state = if (dialog) |d| fromHwnd(d) else null;
    const s = state orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    switch (msg) {
        c.WM_KEYDOWN => switch (wparam) {
            c.VK_UP, c.VK_DOWN, c.VK_PRIOR, c.VK_NEXT => {
                if (c.GetDlgItem(dialog.?, id_list)) |list| {
                    _ = c.SendMessageW(list, c.WM_KEYDOWN, wparam, lparam);
                }
                return 0;
            },
            else => {},
        },
        else => {},
    }
    return c.CallWindowProcW(s.edit_proc, hwnd, msg, wparam, lparam);
}

/// Enter clicks a button that has the keyboard (owner-drawn buttons never
/// become the default), as AlertDialog's do.
fn buttonProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const dialog = c.GetParent(hwnd);
    const state = if (dialog) |d| fromHwnd(d) else null;
    const s = state orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    switch (msg) {
        c.WM_GETDLGCODE => if (lparam != 0) {
            const m: *const c.MSG = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (m.message == c.WM_KEYDOWN and m.wParam == c.VK_RETURN) return c.DLGC_WANTALLKEYS;
        },
        c.WM_KEYDOWN => if (wparam == c.VK_RETURN) {
            const id: usize = @intCast(c.GetDlgCtrlID(hwnd));
            _ = c.SendMessageW(dialog.?, c.WM_COMMAND, id, @bitCast(@intFromPtr(hwnd)));
            return 0;
        },
        else => {},
    }
    return c.CallWindowProcW(s.button_proc, hwnd, msg, wparam, lparam);
}

fn paint(state: *const State, dc: c.HDC) void {
    _ = c.SetBkMode(dc, c.TRANSPARENT);
    _ = c.SetTextColor(dc, state.pal.text);
    {
        const old = if (state.heading_font) |f| c.SelectObject(dc, f) else null;
        defer if (old) |o| {
            _ = c.SelectObject(dc, o);
        };
        var hr = state.heading_rect;
        _ = c.DrawTextW(dc, state.heading.ptr, @intCast(state.heading.len), &hr, c.DT_CENTER | c.DT_SINGLELINE | c.DT_NOPREFIX | c.DT_END_ELLIPSIS);
    }
    const radius = state.scale(entry_radius);
    const r = state.entry_rect;
    if (state.entry_focused) {
        const ring = @max(1, state.scale(2));
        draw.roundRect(dc, .{ .left = r.left - ring, .top = r.top - ring, .right = r.right + ring, .bottom = r.bottom + ring }, radius + ring, state.pal.focus, null, 0);
    }
    draw.roundRect(dc, r, radius, state.pal.button, null, 0);
    draw.roundRect(dc, state.card_rect, state.scale(card_radius), state.pal.view, null, 0);
}

/// A row: the selection's highlight, then the preview or the title and
/// subtitle.
fn drawRow(state: *const State, item: *const c.DRAWITEMSTRUCT) void {
    const dc = item.hDC;
    const r = item.rcItem;
    const pal = &state.pal;
    draw.fill(dc, r, pal.view);
    if (item.itemID >= state.shown.items.len) return;
    const index = state.shown.items[item.itemID];
    const selected = item.itemState & c.ODS_SELECTED != 0;
    if (selected) draw.roundRect(dc, r, state.scale(entry_radius), pal.button_pressed, null, 0);
    _ = c.SetBkMode(dc, c.TRANSPARENT);
    const look: Look = .{ .dpi = state.dpi, .pal = pal, .title_font = state.title_font, .subtitle_font = state.subtitle_font, .selected = selected };
    if (state.opts.preview) |p| return p.paint(p.ctx, dc, r, index, &look);
    paintText(dc, r, state.opts.items[index], &look);
}

/// An item's title, and its subtitle beneath it when it has one, at the
/// row's left: the rows' look without a preview, and for previews that
/// want it beside their own drawing.
pub fn paintText(dc: c.HDC, r: c.RECT, item: Item, look: *const Look) void {
    const pad = look.scale(row_pad);
    var buf: [256]u16 = undefined;
    const has_sub = item.subtitle.len > 0;
    const mid = @divTrunc(r.top + r.bottom, 2);
    {
        const old = if (look.title_font) |f| c.SelectObject(dc, f) else null;
        defer if (old) |o| {
            _ = c.SelectObject(dc, o);
        };
        const t = text_util.utf16Into(&buf, item.title);
        var tr: c.RECT = if (has_sub)
            .{ .left = r.left + pad, .top = r.top, .right = r.right - pad, .bottom = mid + look.scale(1) }
        else
            .{ .left = r.left + pad, .top = r.top, .right = r.right - pad, .bottom = r.bottom };
        _ = c.SetTextColor(dc, look.pal.text);
        const place: c.UINT = if (has_sub) c.DT_BOTTOM else c.DT_VCENTER;
        _ = c.DrawTextW(dc, t.ptr, @intCast(t.len), &tr, c.DT_SINGLELINE | c.DT_NOPREFIX | c.DT_END_ELLIPSIS | place);
    }
    if (has_sub) {
        const old = if (look.subtitle_font) |f| c.SelectObject(dc, f) else null;
        defer if (old) |o| {
            _ = c.SelectObject(dc, o);
        };
        const s = text_util.utf16Into(&buf, item.subtitle);
        var sr: c.RECT = .{ .left = r.left + pad, .top = mid + look.scale(3), .right = r.right - pad, .bottom = r.bottom };
        _ = c.SetTextColor(dc, look.pal.subtitle);
        _ = c.DrawTextW(dc, s.ptr, @intCast(s.len), &sr, c.DT_SINGLELINE | c.DT_NOPREFIX | c.DT_END_ELLIPSIS | c.DT_TOP);
    }
}

/// A response's button: AlertDialog's rounded pill, Select on the accent.
fn drawButton(state: *const State, item: *const c.DRAWITEMSTRUCT) void {
    const dc = item.hDC;
    const r = item.rcItem;
    const pal = state.pal;
    const pressed = item.itemState & c.ODS_SELECTED != 0;
    const suggested = item.CtlID == c.IDOK;
    const back = if (suggested) (if (pressed) pal.suggested_pressed else pal.suggested) else (if (pressed) pal.button_pressed else pal.button);
    const text = if (suggested) pal.suggested_text else pal.text;
    draw.fill(dc, r, pal.bg);
    const radius = state.scale(button_radius);
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

/// Fonts at the owner's DPI, the parts' places, the dialog's size,
/// centered over its owner inside its monitor's work area.
fn layout(hwnd: c.HWND, state: *State) void {
    state.dpi = c.GetDpiForWindow(state.opts.owner orelse hwnd);
    state.heading_font = draw.chromeFontSized(state.dpi, null, 15, true);
    state.title_font = draw.chromeFont(state.dpi, null, false);
    state.subtitle_font = draw.chromeFontSized(state.dpi, null, 9, false);
    state.button_font = draw.chromeFont(state.dpi, null, true);
    state.entry_brush = c.CreateSolidBrush(state.pal.button);
    state.view_brush = c.CreateSolidBrush(state.pal.view);

    const w = state.scale(width);
    const side = state.scale(pad_side);
    const inner = w - 2 * side;
    var y = state.scale(pad_top);
    const heading_h = state.scale(26);
    state.heading_rect = .{ .left = side, .top = y, .right = side + inner, .bottom = y + heading_h };
    y += heading_h + state.scale(gap);

    state.entry_rect = .{ .left = side, .top = y, .right = side + inner, .bottom = y + state.scale(entry_height) };
    if (c.GetDlgItem(hwnd, id_search)) |edit| {
        _ = c.SendMessageW(edit, c.WM_SETFONT, @intFromPtr(state.title_font), 0);
        const line = lineHeight(hwnd, state.title_font) + 2;
        const r = state.entry_rect;
        _ = c.SetWindowPos(edit, null, r.left + state.scale(entry_pad_x), r.top + @divTrunc(r.bottom - r.top - line, 2), r.right - r.left - 2 * state.scale(entry_pad_x), line, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
        _ = c.SetWindowTheme(edit, if (state.opts.dark) c.L("DarkMode_Explorer") else c.L("Explorer"), null);
    }
    y += state.scale(entry_height) + state.scale(gap);

    state.card_rect = .{ .left = side, .top = y, .right = side + inner, .bottom = y + state.scale(list_height) };
    if (c.GetDlgItem(hwnd, id_list)) |list| {
        const k = state.scale(card_inset);
        const r = state.card_rect;
        // A list box's rows are at most 255 px.
        _ = c.SendMessageW(list, c.LB_SETITEMHEIGHT, 0, @min(255, state.scale(state.opts.row_height)));
        _ = c.SetWindowPos(list, null, r.left + k, r.top + k, r.right - r.left - 2 * k, r.bottom - r.top - 2 * k, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
        _ = c.SetWindowTheme(list, if (state.opts.dark) c.L("DarkMode_Explorer") else c.L("Explorer"), null);
    }
    y += state.scale(list_height) + state.scale(pad_side);

    const bh = state.scale(button_height);
    const bgap = state.scale(button_gap);
    const each = @divTrunc(inner - bgap, 2);
    for ([_]c_int{ c.IDCANCEL, c.IDOK }, 0..) |id, i| if (c.GetDlgItem(hwnd, id)) |button| {
        const k: c_int = @intCast(i);
        _ = c.SetWindowPos(button, null, side + k * (each + bgap), y, each, bh, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
    };
    y += bh + state.scale(pad_side);

    var x: c_int = 0;
    var top: c_int = 0;
    if (state.opts.owner) |owner| {
        var o: c.RECT = .{};
        _ = c.GetWindowRect(owner, &o);
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

fn lineHeight(hwnd: c.HWND, font: ?c.HFONT) c_int {
    const dc = c.GetDC(hwnd) orelse return 16;
    defer _ = c.ReleaseDC(hwnd, dc);
    const old = if (font) |f| c.SelectObject(dc, f) else null;
    defer if (old) |o| {
        _ = c.SelectObject(dc, o);
    };
    var r: c.RECT = .{};
    _ = c.DrawTextW(dc, c.L("Ag"), 2, &r, c.DT_SINGLELINE | c.DT_CALCRECT);
    return r.bottom - r.top;
}

test "chooser: the search ranks a whole title, its start, the title, the subtitle" {
    const item: Item = .{ .title = "Cascadia Mono", .subtitle = "Monospace" };
    try std.testing.expectEqual(@as(?u2, 0), rank(item, ""));
    try std.testing.expectEqual(@as(?u2, 0), rank(item, "cascadia mono"));
    try std.testing.expectEqual(@as(?u2, 1), rank(item, " cascadia "));
    try std.testing.expectEqual(@as(?u2, 2), rank(item, "Mono"));
    try std.testing.expectEqual(@as(?u2, 3), rank(item, "space"));
    try std.testing.expectEqual(@as(?u2, null), rank(item, "consolas"));
}

test "chooser template: the entry, the list and two responses" {
    const alloc = std.testing.allocator;
    var t: std.ArrayList(u8) = .empty;
    defer t.deinit(alloc);
    try buildTemplate(alloc, &t, .{ .owner = null, .heading = "", .items = &.{}, .dark = false });
    try std.testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, t.items[8..10], .little));
    try std.testing.expect(t.items.len % 2 == 0);
}
