//! libadwaita's about dialog (AdwAboutDialog, which Ghostty's GTK app shows
//! for About Ghostty), as murrtty's About: a header with the close button,
//! the app's icon at 128 DIP, its name in libadwaita's title-1, the
//! developer, the version as a pill that copies it (a toast says so), then
//! boxed lists of rows: Website and Report an Issue open their links,
//! Credits and Legal open pages of their own (a back button in the header;
//! Alt+Left or Backspace go back too).
//!
//! Sizes are libadwaita's stylesheet's (its about dialog's template and
//! CSS), in DIP: 360 wide; a 46 header whose close button is a 24 circle in
//! a 34 button, 6 from the edges; the main page's box 12 in, its parts 6
//! apart; the name ExtraBold at 181% of 11 pt; the version padded 3 by 18,
//! 3 below the developer; the lists 18 below it and 18 apart, cards rounded
//! 12 holding 50 tall rows (a 4% wash hovered, 8% pressed, a line between
//! rows), their title 12 in, a 16 icon 12 from the end; a subpage's box 18
//! from the top and 12 at the sides, its parts 18 apart; the toast a pill
//! 24 above the bottom.
//!
//! As AlertDialog, it is a real dialog from a template built in memory:
//! the close button (IDCANCEL; Escape, and IDOK as the GUI tests send it,
//! close too), the version and each row are owner-drawn buttons, so Tab,
//! Enter, Alt+the underlined letter, screen readers and the GUI tests work
//! as with any dialog. The caller runs it in a modal scope
//! (App.beginModal). The frame's rounded corners are Windows 11's (DWM),
//! not libadwaita's.
const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig");
const draw = @import("draw.zig");
const text_util = @import("text.zig");
const AlertDialog = @import("AlertDialog.zig");
const TitleDialog = @import("TitleDialog.zig");

const log = std.log.scoped(.win32_about_dialog);

/// A row that opens something: a URL, or a file (`file`).
pub const Link = struct {
    label: []const u8,
    target: []const u8,
    file: bool = false,
};

/// A subpage's content, top to bottom: paragraphs, headings (a group's
/// title, libadwaita's .heading) and boxed lists of link rows.
pub const Block = union(enum) {
    text: []const u8,
    heading: []const u8,
    links: []const Link,
};

pub const Options = struct {
    owner: ?c.HWND,
    /// libadwaita's dark colors, or its light ones.
    dark: bool,
    /// The window's (Alt+Tab's) title.
    title: []const u8,
    name: []const u8,
    developer: []const u8,
    version: []const u8,
    website: []const u8,
    issues: []const u8,
    credits: []const Block,
    legal: []const Block,
    ctx: *anyopaque,
    /// Open a row's link.
    open: *const fn (ctx: *anyopaque, link: Link) void,
    /// Copy the version (true if the clipboard took it).
    copy: *const fn (ctx: *anyopaque, text: []const u8) bool,
    /// A row for update checks (roadmap 7.6a), its label saying their
    /// state ("Updates: Off"): its click closes the dialog and runs
    /// `open_updates`.
    updates: ?[]const u8 = null,
    open_updates: ?*const fn (ctx: *anyopaque) void = null,
};

/// The controls' ids, for the GUI tests: the close button is IDCANCEL.
pub const id_back = 200;
pub const id_version = 201;
pub const id_website = 210;
pub const id_issues = 211;
pub const id_credits = 212;
pub const id_legal = 213;
pub const id_updates = 214;
/// The toast's static: no size (the dialog and the controls under the
/// toast draw it, as an overlay), shown while the toast is, for screen
/// readers and the GUI tests.
pub const id_toast = 240;
/// The subpages' link rows: the credits' from 300 in order, the legal
/// page's from 400.
pub const id_credit_links = 300;
pub const id_legal_links = 400;

const Page = enum { main, credits, legal };

/// Unscaled metrics, in DIP (see the file's comment).
const width = 360;
const header_height = 46;
const header_pad = 6;
const header_button = 34;
const close_circle = 24;
const main_margin = 12;
const main_spacing = 6;
const icon_size = 128;
const name_percent = 181;
const version_pad_x = 18;
const version_pad_y = 3;
const version_margin_top = 3;
const lists_margin_top = 18;
const lists_spacing = 18;
const lists_margin_bottom = 6;
const card_radius = 12;
const row_height = 50;
const row_pad = 12;
const row_icon = 16;
const sub_margin_top = 18;
const sub_margin_x = 12;
const sub_spacing = 18;
const heading_gap = 6;
const toast_margin_bottom = 24;
const toast_pad_y = 6;
const toast_pad_x = 12;
/// How long the toast stays (libadwaita's default).
const toast_ms = 5000;
const toast_timer = 1;

/// A control's place and how it draws.
const Kind = enum { close, back, version, row, toast };

const Control = struct {
    id: u16,
    page: ?Page,
    kind: Kind,
    /// Its group's card, and whether a line runs below it (not the last).
    card: c.RECT = .{},
    rect: c.RECT = .{},
    last_in_card: bool = true,
    icon: enum { none, link, next } = .none,
    link: ?Link = null,
};

const State = struct {
    alloc: Allocator,
    opts: Options,
    title: [:0]const u16,
    name: [:0]const u16,
    developer: [:0]const u16,
    version: [:0]const u16,
    /// The subpages' texts and headings, in their order (UTF-16).
    blocks: std.ArrayList(TextBlock) = .empty,
    controls: std.ArrayList(Control) = .empty,
    page: Page = .main,
    dpi: c.UINT = c.USER_DEFAULT_SCREEN_DPI,
    pal: draw.DialogPalette,
    accent_text: c.COLORREF = 0,
    border: c.COLORREF = 0,
    row_hover: c.COLORREF = 0,
    row_pressed: c.COLORREF = 0,
    flat_hover: c.COLORREF = 0,
    flat_pressed: c.COLORREF = 0,
    body_font: ?c.HFONT = null,
    bold_font: ?c.HFONT = null,
    name_font: ?c.HFONT = null,
    icon: ?c.HICON = null,
    icon_rect: c.RECT = .{},
    name_rect: c.RECT = .{},
    developer_rect: c.RECT = .{},
    /// The procedure the buttons had (Button's).
    button_proc: isize = 0,
    /// The button under the mouse.
    hover: u16 = 0,
    /// The toast, over whatever lies under it (libadwaita's toast overlay
    /// holds the whole dialog), and its place in the dialog.
    toast_on: bool = false,
    toast_rect: c.RECT = .{},

    const TextBlock = struct {
        page: Page,
        text: [:0]const u16,
        heading: bool,
        rect: c.RECT = .{},
    };

    fn scale(self: *const State, v: c_int) c_int {
        return draw.scale(self.dpi, v);
    }

    fn find(self: *State, id: u16) ?*Control {
        for (self.controls.items) |*ctl| if (ctl.id == id) return ctl;
        return null;
    }

    fn deinit(self: *State) void {
        for (self.blocks.items) |b| self.alloc.free(b.text);
        self.blocks.deinit(self.alloc);
        self.controls.deinit(self.alloc);
        for ([_]?c.HFONT{ self.body_font, self.bold_font, self.name_font }) |f| if (f) |font| {
            _ = c.DeleteObject(font);
        };
        if (self.icon) |i| _ = c.DestroyIcon(i);
    }
};

/// Show the dialog until it closes. False if it couldn't be shown (the
/// caller falls back to a plain message).
pub fn run(alloc: Allocator, opts: Options) bool {
    var state: State = .{
        .alloc = alloc,
        .opts = opts,
        .title = text_util.utf16Lossy(alloc, opts.title) catch return false,
        .name = undefined,
        .developer = undefined,
        .version = undefined,
        .pal = draw.dialogPalette(opts.dark),
    };
    defer alloc.free(state.title);
    state.name = text_util.utf16Lossy(alloc, opts.name) catch return false;
    defer alloc.free(state.name);
    state.developer = text_util.utf16Lossy(alloc, opts.developer) catch return false;
    defer alloc.free(state.developer);
    state.version = text_util.utf16Lossy(alloc, opts.version) catch return false;
    defer alloc.free(state.version);
    defer state.deinit();
    buildControls(&state) catch return false;

    var template: std.ArrayList(u8) = .empty;
    defer template.deinit(alloc);
    buildTemplate(alloc, &template, &state) catch return false;

    // libadwaita dims the window behind a dialog (as AlertDialog does).
    const dim = if (opts.owner) |owner| AlertDialog.dimOver(owner, if (opts.dark) 128 else 36) else null;
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
        log.warn("about dialog failed err={}", .{c.GetLastError()});
        return false;
    }
    return true;
}

/// Every control of every page, and the subpages' texts, in Tab's order.
fn buildControls(state: *State) !void {
    const alloc = state.alloc;
    try state.controls.append(alloc, .{ .id = c.IDCANCEL, .page = null, .kind = .close });
    try state.controls.append(alloc, .{ .id = id_back, .page = null, .kind = .back });
    try state.controls.append(alloc, .{ .id = id_version, .page = .main, .kind = .version });
    try state.controls.append(alloc, .{ .id = id_website, .page = .main, .kind = .row, .icon = .link, .link = .{ .label = "&Website", .target = state.opts.website } });
    try state.controls.append(alloc, .{ .id = id_issues, .page = .main, .kind = .row, .icon = .link, .link = .{ .label = "&Report an Issue", .target = state.opts.issues } });
    if (state.opts.updates != null) try state.controls.append(alloc, .{ .id = id_updates, .page = .main, .kind = .row, .icon = .next, .last_in_card = false });
    try state.controls.append(alloc, .{ .id = id_credits, .page = .main, .kind = .row, .icon = .next, .last_in_card = false });
    try state.controls.append(alloc, .{ .id = id_legal, .page = .main, .kind = .row, .icon = .next });
    for ([_]struct { Page, []const Block, u16 }{
        .{ .credits, state.opts.credits, id_credit_links },
        .{ .legal, state.opts.legal, id_legal_links },
    }) |entry| {
        var next_id = entry[2];
        for (entry[1]) |block| switch (block) {
            .text, .heading => |t| {
                const wide = try text_util.utf16Lossy(alloc, t);
                errdefer alloc.free(wide);
                try state.blocks.append(alloc, .{ .page = entry[0], .text = wide, .heading = block == .heading });
            },
            .links => |links| for (links, 0..) |link, i| {
                try state.controls.append(alloc, .{
                    .id = next_id,
                    .page = entry[0],
                    .kind = .row,
                    .icon = .link,
                    .link = link,
                    .last_in_card = i + 1 == links.len,
                });
                next_id += 1;
            },
        };
    }
    try state.controls.append(alloc, .{ .id = id_toast, .page = null, .kind = .toast });
}

/// A popup with no caption, then the controls; their texts and places are
/// set when it starts (WM_INITDIALOG).
fn buildTemplate(alloc: Allocator, out: *std.ArrayList(u8), state: *const State) !void {
    const put16 = TitleDialog.put16;
    const put32 = TitleDialog.put32;
    try put32(alloc, out, c.WS_POPUP | c.WS_CLIPCHILDREN);
    try put32(alloc, out, 0);
    try put16(alloc, out, @intCast(state.controls.items.len));
    for ([_]i16{ 0, 0, 200, 100 }) |v| try put16(alloc, out, @bitCast(v));
    try put16(alloc, out, 0); // no menu
    try put16(alloc, out, 0); // the standard dialog class
    try TitleDialog.putString(alloc, out, "About");
    const button_class = 0x0080;
    const static_class = 0x0082;
    for (state.controls.items) |ctl| {
        if (ctl.kind == .toast) {
            try TitleDialog.putItem(alloc, out, c.WS_CHILD | c.WS_CLIPSIBLINGS | c.SS_OWNERDRAW, .{ 0, 0, 10, 10 }, ctl.id, static_class, "");
        } else {
            try TitleDialog.putItem(alloc, out, c.WS_CHILD | c.WS_CLIPSIBLINGS | c.WS_TABSTOP | c.BS_OWNERDRAW, .{ 0, 0, 10, 10 }, ctl.id, button_class, "");
        }
    }
}

fn fromHwnd(hwnd: c.HWND) ?*State {
    const ptr: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA));
    return if (ptr != 0) @ptrFromInt(ptr) else null;
}

/// A control's text: its label, the version, or what screen readers say.
fn label(state: *const State, ctl: Control) []const u8 {
    if (ctl.link) |l| return l.label;
    return switch (ctl.id) {
        c.IDCANCEL => "Close",
        id_back => "Back",
        id_credits => "&Credits",
        id_updates => state.opts.updates orelse "",
        id_legal => "&Legal",
        id_toast => "Copied to clipboard",
        else => state.opts.version,
    };
}

fn dialogProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) isize {
    switch (msg) {
        c.WM_INITDIALOG => {
            const state: *State = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, lparam);
            _ = c.SetWindowTextW(hwnd, state.title.ptr);
            for (state.controls.items) |ctl| {
                const child = c.GetDlgItem(hwnd, ctl.id) orelse continue;
                if (ctl.kind != .toast) {
                    const prev = c.SetWindowLongPtrW(child, c.GWLP_WNDPROC, @bitCast(@intFromPtr(&buttonProc)));
                    if (state.button_proc == 0) state.button_proc = prev;
                }
                const text = text_util.utf16Lossy(state.alloc, label(state, ctl)) catch continue;
                defer state.alloc.free(text);
                _ = c.SetWindowTextW(child, text.ptr);
            }
            layout(hwnd, state);
            const corner = c.DWMWCP_ROUND;
            _ = c.DwmSetWindowAttribute(hwnd, c.DWMWA_WINDOW_CORNER_PREFERENCE, &corner, @sizeOf(c_int));
            showPage(hwnd, state, .main);
            return 0;
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
            drawToast(state, dc, .{});
            return 0;
        },
        c.WM_DRAWITEM => {
            const state = fromHwnd(hwnd) orelse return 0;
            const item: *const c.DRAWITEMSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const ctl = state.find(@intCast(item.CtlID)) orelse return 0;
            drawControl(state, ctl.*, item);
            return 1;
        },
        c.WM_TIMER => {
            if (wparam == toast_timer) if (fromHwnd(hwnd)) |state| setToast(hwnd, state, false);
            return 1;
        },
        c.WM_COMMAND => {
            const state = fromHwnd(hwnd) orelse return 0;
            const id = c.loword(wparam);
            const code = c.hiword(wparam);
            // Escape (IDCANCEL), the close button, and IDOK as the GUI tests
            // send it.
            if (id == c.IDCANCEL or id == c.IDOK) {
                _ = c.KillTimer(hwnd, toast_timer);
                _ = c.EndDialog(hwnd, c.IDCANCEL);
                return 1;
            }
            // A click, not a double click's second one (a link would open
            // twice).
            if (code != c.BN_CLICKED) return 0;
            activate(hwnd, state, id);
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

/// A button's click: back, the version (copied, the toast), a page's row
/// (that page), or a link.
fn activate(hwnd: c.HWND, state: *State, id: u16) void {
    switch (id) {
        id_back => showPage(hwnd, state, .main),
        id_credits => showPage(hwnd, state, .credits),
        id_legal => showPage(hwnd, state, .legal),
        id_updates => {
            _ = c.KillTimer(hwnd, toast_timer);
            _ = c.EndDialog(hwnd, id_updates);
            if (state.opts.open_updates) |f| f(state.opts.ctx);
        },
        id_version => if (state.opts.copy(state.opts.ctx, state.opts.version)) setToast(hwnd, state, true),
        else => if (state.find(id)) |ctl| if (ctl.link) |l| state.opts.open(state.opts.ctx, l),
    }
}

/// Show the toast (for toast_ms) or take it away: the dialog and every
/// control repaint, those under it with their part of it.
fn setToast(hwnd: c.HWND, state: *State, on: bool) void {
    _ = c.KillTimer(hwnd, toast_timer);
    state.toast_on = on;
    if (c.GetDlgItem(hwnd, id_toast)) |t| _ = c.ShowWindow(t, if (on) c.SW_SHOWNA else c.SW_HIDE);
    if (on) _ = c.SetTimer(hwnd, toast_timer, toast_ms, null);
    _ = c.RedrawWindow(hwnd, null, null, c.RDW_INVALIDATE | c.RDW_ERASE | c.RDW_ALLCHILDREN);
}

/// The toast's part in a DC whose origin is `origin` in the dialog: a
/// pill of rgba(29, 29, 29, 0.975) (drawn opaque) holding the message in
/// white.
fn drawToast(state: *const State, dc: c.HDC, origin: c.POINT) void {
    if (!state.toast_on) return;
    const t = state.toast_rect;
    const r: c.RECT = .{ .left = t.left - origin.x, .top = t.top - origin.y, .right = t.right - origin.x, .bottom = t.bottom - origin.y };
    draw.roundRect(dc, r, @divTrunc(r.bottom - r.top, 2), c.rgb(0x1d, 0x1d, 0x1d), null, 0);
    _ = c.SetBkMode(dc, c.TRANSPARENT);
    _ = c.SetTextColor(dc, c.rgb(0xff, 0xff, 0xff));
    drawText(dc, state.body_font, std.unicode.utf8ToUtf16LeStringLiteral("Copied to clipboard"), r, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX);
}

/// Show `page`'s controls and texts, the back button on a subpage, the
/// keyboard on its first control (the back button on a subpage).
fn showPage(hwnd: c.HWND, state: *State, page: Page) void {
    state.page = page;
    state.hover = 0;
    var first: ?c.HWND = null;
    for (state.controls.items) |ctl| {
        const child = c.GetDlgItem(hwnd, ctl.id) orelse continue;
        const shown = switch (ctl.kind) {
            .close => true,
            .back => page != .main,
            .toast => continue,
            else => ctl.page == page,
        };
        _ = c.ShowWindow(child, if (shown) c.SW_SHOWNA else c.SW_HIDE);
        if (shown and first == null and ctl.kind != .close) first = child;
    }
    if (first) |f| _ = c.SetFocus(f);
    _ = c.InvalidateRect(hwnd, null, c.TRUE);
}

/// The header's title on a subpage, the main page's icon, name and
/// developer, a subpage's paragraphs and headings.
fn paint(state: *const State, dc: c.HDC) void {
    _ = c.SetBkMode(dc, c.TRANSPARENT);
    _ = c.SetTextColor(dc, state.pal.text);
    if (state.page == .main) {
        if (state.icon) |icon| {
            const r = state.icon_rect;
            _ = c.DrawIconEx(dc, r.left, r.top, icon, r.right - r.left, r.bottom - r.top, 0, null, c.DI_NORMAL);
        }
        drawText(dc, state.name_font, state.name, state.name_rect, c.DT_CENTER | c.DT_WORDBREAK | c.DT_NOPREFIX);
        drawText(dc, state.body_font, state.developer, state.developer_rect, c.DT_CENTER | c.DT_WORDBREAK | c.DT_NOPREFIX);
        return;
    }
    const title: []const u8 = if (state.page == .credits) "Credits" else "Legal";
    var wide: [16]u16 = undefined;
    for (title, 0..) |ch, i| wide[i] = ch;
    const w = state.scale(width);
    drawText(dc, state.bold_font, wide[0..title.len], .{ .left = 0, .top = 0, .right = w, .bottom = state.scale(header_height) }, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX);
    for (state.blocks.items) |b| if (b.page == state.page) {
        drawText(dc, if (b.heading) state.bold_font else state.body_font, b.text, b.rect, c.DT_LEFT | c.DT_WORDBREAK | c.DT_NOPREFIX);
    };
}

fn drawText(dc: c.HDC, font: ?c.HFONT, text: []const u16, rect: c.RECT, flags: c.UINT) void {
    if (text.len == 0) return;
    const old = if (font) |f| c.SelectObject(dc, f) else null;
    defer if (old) |o| {
        _ = c.SelectObject(dc, o);
    };
    var r = rect;
    _ = c.DrawTextW(dc, text.ptr, @intCast(text.len), &r, flags);
}

fn textHeight(dc: c.HDC, font: ?c.HFONT, text: []const u16, w: c_int, flags: c.UINT) c_int {
    if (text.len == 0) return 0;
    const old = if (font) |f| c.SelectObject(dc, f) else null;
    defer if (old) |o| {
        _ = c.SelectObject(dc, o);
    };
    var r: c.RECT = .{ .right = w };
    _ = c.DrawTextW(dc, text.ptr, @intCast(text.len), &r, flags | c.DT_CALCRECT);
    return r.bottom - r.top;
}

/// The name's font: title-1, Adwaita Sans's ExtraBold at 181% of 11 pt
/// (bold where that instance is missing).
fn nameFont(dpi: c.UINT) ?c.HFONT {
    var lf: c.LOGFONTW = std.mem.zeroes(c.LOGFONTW);
    // 11 pt at 181%, in pixels at `dpi`.
    lf.lfHeight = -@as(c_long, @intCast((11 * name_percent * dpi + 3600) / 7200));
    lf.lfWeight = 400;
    lf.lfCharSet = 1; // DEFAULT_CHARSET
    lf.lfQuality = 4; // ANTIALIASED_QUALITY
    const face = std.unicode.utf8ToUtf16LeStringLiteral(draw.chrome_family ++ " ExtraBold");
    @memcpy(lf.lfFaceName[0..face.len], face);
    const font = c.CreateFontIndirectW(&lf) orelse return null;
    var buf: [64]u8 = undefined;
    if (std.mem.eql(u8, draw.faceName(font, &buf), draw.chrome_family ++ " ExtraBold")) return font;
    _ = c.DeleteObject(font);
    lf.lfWeight = 800;
    const plain = std.unicode.utf8ToUtf16LeStringLiteral(draw.chrome_family);
    lf.lfFaceName = @splat(0);
    @memcpy(lf.lfFaceName[0..plain.len], plain);
    return c.CreateFontIndirectW(&lf);
}

/// Fonts and the icon at the owner's DPI, every page's places, the dialog's
/// size (the tallest page's), centered over its owner.
fn layout(hwnd: c.HWND, state: *State) void {
    state.dpi = c.GetDpiForWindow(state.opts.owner orelse hwnd);
    state.body_font = draw.chromeFont(state.dpi, null, false);
    state.bold_font = draw.chromeFont(state.dpi, null, true);
    state.name_font = nameFont(state.dpi);
    colors(state);

    const w = state.scale(width);
    // The owner's monitor's work area: the dialog has no caption to drag,
    // so it must fit (libadwaita's would scroll).
    var owner_rect: c.RECT = .{};
    if (state.opts.owner) |owner| {
        _ = c.GetWindowRect(owner, &owner_rect);
        if (c.IsIconic(owner) != 0) {
            var placement: c.WINDOWPLACEMENT = .{};
            if (c.GetWindowPlacement(owner, &placement) != 0) owner_rect = placement.rcNormalPosition;
        }
    }
    var work: ?c.RECT = null;
    if (c.MonitorFromRect(&owner_rect, c.MONITOR_DEFAULTTONEAREST)) |monitor| {
        var info: c.MONITORINFO = .{};
        if (c.GetMonitorInfoW(monitor, &info) != 0) work = info.rcWork;
    }
    const dc = c.GetDC(hwnd) orelse return;
    defer _ = c.ReleaseDC(hwnd, dc);

    // The header's buttons.
    const hb = state.scale(header_button);
    const hp = state.scale(header_pad);
    place(state, c.IDCANCEL, .{ .left = w - hp - hb, .top = hp, .right = w - hp, .bottom = hp + hb });
    place(state, id_back, .{ .left = hp, .top = hp, .right = hp + hb, .bottom = hp + hb });

    // The main page.
    const m = state.scale(main_margin);
    const inner_w = w - 2 * m;
    var y = state.scale(header_height) + m;
    const icon_top = y;
    var icon_px = state.scale(icon_size);
    y += icon_px + state.scale(main_spacing);
    const name_h = textHeight(dc, state.name_font, state.name, inner_w, c.DT_CENTER | c.DT_WORDBREAK | c.DT_NOPREFIX);
    state.name_rect = .{ .left = m, .top = y, .right = m + inner_w, .bottom = y + name_h };
    y += name_h + state.scale(main_spacing);
    const dev_h = textHeight(dc, state.body_font, state.developer, inner_w, c.DT_CENTER | c.DT_WORDBREAK | c.DT_NOPREFIX);
    state.developer_rect = .{ .left = m, .top = y, .right = m + inner_w, .bottom = y + dev_h };
    y += dev_h + state.scale(main_spacing) + state.scale(version_margin_top);
    {
        const line = textHeight(dc, state.body_font, state.version, w, c.DT_SINGLELINE | c.DT_NOPREFIX);
        const tw = textWidth(dc, state.body_font, state.version);
        const pw = @min(inner_w, tw + 2 * state.scale(version_pad_x));
        const ph = line + 2 * state.scale(version_pad_y);
        place(state, id_version, .{ .left = @divTrunc(w - pw, 2), .top = y, .right = @divTrunc(w - pw, 2) + pw, .bottom = y + ph });
        y += ph;
    }
    y += state.scale(main_spacing) + state.scale(lists_margin_top);
    const rh = state.scale(row_height);
    const pages: []const u16 = if (state.opts.updates != null) &.{ id_updates, id_credits, id_legal } else &.{ id_credits, id_legal };
    for ([_][]const u16{ &.{id_website}, &.{id_issues}, pages }, 0..) |group, gi| {
        if (gi > 0) y += state.scale(lists_spacing);
        y = placeCard(state, dc, group, m, inner_w, y, rh);
    }
    y += state.scale(lists_margin_bottom) + m;
    // Too tall for the work area: the icon shrinks by the overflow (to 48
    // DIP at least), the main page's rest moving up with it.
    if (work) |wa| {
        const overflow = y - (wa.bottom - wa.top);
        if (overflow > 0) {
            const smaller = @max(state.scale(48), icon_px - overflow);
            const up = icon_px - smaller;
            icon_px = smaller;
            for ([_]*c.RECT{ &state.name_rect, &state.developer_rect }) |r| {
                r.top -= up;
                r.bottom -= up;
            }
            for (state.controls.items) |*ctl| if (ctl.page == .main) {
                ctl.rect.top -= up;
                ctl.rect.bottom -= up;
                ctl.card.top -= up;
                ctl.card.bottom -= up;
            };
            y -= up;
        }
    }
    state.icon_rect = .{ .left = @divTrunc(w - icon_px, 2), .top = icon_top, .right = @divTrunc(w - icon_px, 2) + icon_px, .bottom = icon_top + icon_px };
    if (c.LoadImageW(c.GetModuleHandleW(null), 1, c.IMAGE_ICON, icon_px, icon_px, 0)) |h| state.icon = @ptrCast(h);
    var height = y;

    // The subpages.
    for ([_]Page{ .credits, .legal }) |page| {
        const sx = state.scale(sub_margin_x);
        const sw = w - 2 * sx;
        var sy = state.scale(header_height) + state.scale(sub_margin_top);
        // Parts 18 apart; a heading's list 6 below it.
        var first = true;
        var after_heading = false;
        var block_i: usize = 0;
        var ctl_i: usize = 0;
        const blocks = if (page == .credits) state.opts.credits else state.opts.legal;
        for (blocks) |block| {
            if (!first and !after_heading) sy += state.scale(sub_spacing);
            first = false;
            after_heading = false;
            switch (block) {
                .text, .heading => {
                    const tb = nthBlock(state, page, block_i) orelse continue;
                    block_i += 1;
                    const pad: c_int = if (tb.heading) state.scale(6) else 0;
                    const h = textHeight(dc, if (tb.heading) state.bold_font else state.body_font, tb.text, sw - pad, c.DT_LEFT | c.DT_WORDBREAK | c.DT_NOPREFIX);
                    tb.rect = .{ .left = sx + pad, .top = sy, .right = sx + sw, .bottom = sy + h };
                    sy += h;
                    if (tb.heading) {
                        sy += state.scale(heading_gap);
                        after_heading = true;
                    }
                },
                .links => |links| {
                    // This list's rows: the page's next `links.len`.
                    var ids: std.ArrayList(u16) = .empty;
                    defer ids.deinit(state.alloc);
                    for (state.controls.items) |ctl| {
                        if (ctl.page != page or ctl.link == null) continue;
                        const k = countBefore(state, page, ctl.id);
                        if (k >= ctl_i and k < ctl_i + links.len) ids.append(state.alloc, ctl.id) catch break;
                    }
                    ctl_i += links.len;
                    sy = placeCard(state, dc, ids.items, sx, sw, sy, rh);
                },
            }
        }
        sy += state.scale(sub_margin_top);
        height = @max(height, sy);
    }

    // The toast: a pill 24 above the bottom, centered.
    {
        const tw = textWidth(dc, state.body_font, std.unicode.utf8ToUtf16LeStringLiteral("Copied to clipboard"));
        const line = textHeight(dc, state.body_font, std.unicode.utf8ToUtf16LeStringLiteral("Ag"), w, c.DT_SINGLELINE);
        const tw_all = tw + 2 * state.scale(toast_pad_x);
        const th = line + 2 * state.scale(toast_pad_y) + state.scale(4);
        const top = height - state.scale(toast_margin_bottom) - th;
        state.toast_rect = .{ .left = @divTrunc(w - tw_all, 2), .top = top, .right = @divTrunc(w - tw_all, 2) + tw_all, .bottom = top + th };
        place(state, id_toast, .{ .left = @divTrunc(w, 2), .top = top, .right = @divTrunc(w, 2), .bottom = top });
    }

    for (state.controls.items) |ctl| if (c.GetDlgItem(hwnd, ctl.id)) |child| {
        const r = ctl.rect;
        _ = c.SetWindowPos(child, null, r.left, r.top, r.right - r.left, r.bottom - r.top, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
    };

    // Centered over the owner (libadwaita's floating dialog), inside its
    // monitor's work area.
    var x: c_int = 0;
    var top: c_int = 0;
    if (state.opts.owner != null) {
        const o = owner_rect;
        x = o.left + @divTrunc(o.right - o.left - w, 2);
        top = o.top + @divTrunc(o.bottom - o.top - height, 2);
    }
    if (work) |wa| {
        x = std.math.clamp(x, wa.left, @max(wa.left, wa.right - w));
        top = std.math.clamp(top, wa.top, @max(wa.top, wa.bottom - height));
    }
    _ = c.SetWindowPos(hwnd, null, x, top, w, height, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
}

/// The `i`th text or heading of `page`.
fn nthBlock(state: *State, page: Page, i: usize) ?*State.TextBlock {
    var n: usize = 0;
    for (state.blocks.items) |*b| if (b.page == page) {
        if (n == i) return b;
        n += 1;
    };
    return null;
}

/// How many of `page`'s link rows come before `id`.
fn countBefore(state: *const State, page: Page, id: u16) usize {
    var n: usize = 0;
    for (state.controls.items) |ctl| {
        if (ctl.page != page or ctl.link == null) continue;
        if (ctl.id == id) return n;
        n += 1;
    }
    return n;
}

/// A card at `y` holding the rows `ids`, one under another, each at least
/// `rh` tall and as tall as its title wrapped (libadwaita's row titles
/// wrap rather than end in an ellipsis), 12 above and below it; returns
/// the card's bottom.
fn placeCard(state: *State, dc: c.HDC, ids: []const u16, x: c_int, w: c_int, y: c_int, rh: c_int) c_int {
    var top = y;
    for (ids, 0..) |id, i| {
        const ctl = state.find(id) orelse continue;
        const text_h = rowTextHeight(state, dc, ctl.*, w);
        const h = @max(rh, text_h + 2 * state.scale(row_pad));
        ctl.rect = .{ .left = x, .top = top, .right = x + w, .bottom = top + h };
        ctl.last_in_card = i + 1 == ids.len;
        top += h;
    }
    const card: c.RECT = .{ .left = x, .top = y, .right = x + w, .bottom = top };
    for (ids) |id| if (state.find(id)) |ctl| {
        ctl.card = card;
    };
    return card.bottom;
}

/// The width a row's title wraps in: the row less its padding and icon.
fn rowTextWidth(state: *const State, row_w: c_int) c_int {
    return row_w - 3 * state.scale(row_pad) - state.scale(row_icon);
}

/// A row's title's height, wrapped to the row (its access key's & not
/// counted).
fn rowTextHeight(state: *const State, dc: c.HDC, ctl: Control, row_w: c_int) c_int {
    const text = text_util.utf16Lossy(state.alloc, label(state, ctl)) catch return 0;
    defer state.alloc.free(text);
    return textHeight(dc, state.body_font, text, rowTextWidth(state, row_w), c.DT_LEFT | c.DT_WORDBREAK);
}

fn place(state: *State, id: u16, r: c.RECT) void {
    if (state.find(id)) |ctl| ctl.rect = r;
}

fn textWidth(dc: c.HDC, font: ?c.HFONT, text: []const u16) c_int {
    const old = if (font) |f| c.SelectObject(dc, f) else null;
    defer if (old) |o| {
        _ = c.SelectObject(dc, o);
    };
    var r: c.RECT = .{};
    _ = c.DrawTextW(dc, text.ptr, @intCast(text.len), &r, c.DT_SINGLELINE | c.DT_NOPREFIX | c.DT_CALCRECT);
    return r.right - r.left;
}

/// The colors libadwaita adds to the alert dialog's: the accent as text
/// (its OKLab lightness at most 0.5 in light, at least 0.85 in dark), the
/// cards' border at 15% of the text (light only, for its shadow), a row
/// washed 4% hovered and 8% pressed, a flat button 7% and 16%.
fn colors(state: *State) void {
    const dark = state.opts.dark;
    const accent: draw.Color = .{ .r = 0x35, .g = 0x84, .b = 0xe4 };
    state.accent_text = draw.ref(draw.clampLightness(accent, if (dark) 0.85 else 0.0, if (dark) 1.0 else 0.5));
    const bg = fromRef(state.pal.bg);
    const card = fromRef(state.pal.card);
    const fg = fromRef(state.pal.text);
    state.border = draw.ref(draw.blend(card, fg, 0.15));
    state.row_hover = draw.ref(draw.blend(card, fg, 0.04));
    state.row_pressed = draw.ref(draw.blend(card, fg, 0.08));
    state.flat_hover = draw.ref(draw.blend(bg, fg, 0.07));
    state.flat_pressed = draw.ref(draw.blend(bg, fg, 0.16));
}

fn fromRef(v: c.COLORREF) draw.Color {
    return .{ .r = @truncate(v), .g = @truncate(v >> 8), .b = @truncate(v >> 16) };
}

fn drawControl(state: *const State, ctl: Control, item: *const c.DRAWITEMSTRUCT) void {
    const dc = item.hDC;
    const r = item.rcItem;
    const pal = state.pal;
    const pressed = item.itemState & c.ODS_SELECTED != 0;
    const hovered = state.hover == ctl.id;
    const focused = item.itemState & c.ODS_FOCUS != 0 and item.itemState & c.ODS_NOFOCUSRECT == 0;
    const ring = @max(1, state.scale(2));
    switch (ctl.kind) {
        .close => {
            draw.fill(dc, r, pal.bg);
            // libadwaita's window control: a 24 circle at 10% (15%
            // hovered, 30% pressed), the X in an 8 box 13 in.
            const circle = state.scale(close_circle);
            const off = @divTrunc(r.right - r.left - circle, 2);
            const round: c.RECT = .{ .left = r.left + off, .top = r.top + off, .right = r.left + off + circle, .bottom = r.top + off + circle };
            if (focused) draw.roundRect(dc, .{ .left = round.left - ring, .top = round.top - ring, .right = round.right + ring, .bottom = round.bottom + ring }, @divTrunc(circle, 2) + ring, pal.focus, null, 0);
            draw.roundRect(dc, round, @divTrunc(circle, 2), if (pressed) pal.button_pressed else if (hovered) pal.button_hover else pal.button, null, 0);
            const g = state.scale(13);
            const e = state.scale(21);
            draw.cross(dc, .{ .left = r.left + g, .top = r.top + g, .right = r.left + e, .bottom = r.top + e }, state.dpi, pal.text);
        },
        .back => {
            draw.fill(dc, r, pal.bg);
            const radius = state.scale(9);
            if (focused) draw.roundRect(dc, r, radius, pal.focus, null, 0);
            const inset: c.RECT = if (focused) .{ .left = r.left + ring, .top = r.top + ring, .right = r.right - ring, .bottom = r.bottom - ring } else r;
            if (pressed or hovered) {
                draw.roundRect(dc, inset, radius, if (pressed) state.flat_pressed else state.flat_hover, null, 0);
            } else if (focused) {
                draw.roundRect(dc, inset, radius, pal.bg, null, 0);
            }
            chevron(state, dc, r, true, pal.text);
        },
        .version => {
            draw.fill(dc, r, pal.bg);
            const radius = @divTrunc(r.bottom - r.top, 2);
            const back = if (pressed) pal.button_pressed else if (hovered) pal.button_hover else pal.button;
            if (focused) {
                draw.roundRect(dc, r, radius, pal.focus, null, 0);
                draw.roundRect(dc, .{ .left = r.left + ring, .top = r.top + ring, .right = r.right - ring, .bottom = r.bottom - ring }, radius - ring, back, null, 0);
            } else {
                draw.roundRect(dc, r, radius, back, null, 0);
            }
            _ = c.SetTextColor(dc, state.accent_text);
            drawLabel(dc, state.body_font, item.hwndItem, r, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX);
        },
        .row => drawRow(state, ctl, item, pressed, hovered, focused),
        .toast => return,
    }
    // The toast's part over this control.
    const t = state.toast_rect;
    if (t.left < ctl.rect.right and t.right > ctl.rect.left and t.top < ctl.rect.bottom and t.bottom > ctl.rect.top) {
        drawToast(state, dc, .{ .x = ctl.rect.left, .y = ctl.rect.top });
    }
}

/// A row: its part of its card (the card's shape drawn whole and clipped
/// to the row, so only the card's corners round), washed when hovered or
/// pressed, a line under it unless it is the card's last, its title 12 in
/// and its icon 12 from the end.
fn drawRow(state: *const State, ctl: Control, item: *const c.DRAWITEMSTRUCT, pressed: bool, hovered: bool, focused: bool) void {
    const dc = item.hDC;
    const r = item.rcItem;
    const pal = state.pal;
    draw.fill(dc, r, pal.bg);
    // The card in the row's coordinates.
    const card: c.RECT = .{
        .left = ctl.card.left - ctl.rect.left,
        .top = ctl.card.top - ctl.rect.top,
        .right = ctl.card.right - ctl.rect.left,
        .bottom = ctl.card.bottom - ctl.rect.top,
    };
    const radius = state.scale(card_radius);
    const fill_color = if (pressed) state.row_pressed else if (hovered) state.row_hover else pal.card;
    draw.roundRect(dc, card, radius, fill_color, null, 0);
    if (!state.opts.dark) draw.roundRect(dc, card, radius, null, state.border, 1);
    if (!ctl.last_in_card) draw.fill(dc, .{ .left = r.left, .top = r.bottom - 1, .right = r.right, .bottom = r.bottom }, state.border);
    if (focused) {
        const ring = @max(1, state.scale(2));
        const first = ctl.card.top == ctl.rect.top;
        const only = first and ctl.last_in_card;
        draw.roundRect(dc, .{ .left = r.left + ring, .top = r.top + ring, .right = r.right - ring, .bottom = r.bottom - ring }, if (only) radius - ring else state.scale(6), null, pal.focus, ring);
    }
    const pad = state.scale(row_pad);
    const icon = state.scale(row_icon);
    _ = c.SetTextColor(dc, pal.text);
    // The title wrapped and centered as a whole, as libadwaita's.
    const hide: c.UINT = if (item.itemState & c.ODS_NOACCEL != 0) c.DT_HIDEPREFIX else 0;
    const text_w = rowTextWidth(state, r.right - r.left);
    const text_h = rowTextHeight(state, dc, ctl, r.right - r.left);
    const text_top = r.top + @divTrunc(r.bottom - r.top - text_h, 2);
    drawLabel(dc, state.body_font, item.hwndItem, .{ .left = r.left + pad, .top = text_top, .right = r.left + pad + text_w, .bottom = text_top + text_h }, c.DT_LEFT | c.DT_WORDBREAK | hide);
    const box: c.RECT = .{ .left = r.right - pad - icon, .top = r.top + @divTrunc(r.bottom - r.top - icon, 2), .right = r.right - pad, .bottom = r.top + @divTrunc(r.bottom - r.top - icon, 2) + icon };
    switch (ctl.icon) {
        .link => externalLink(state, dc, box, pal.text),
        .next => chevron(state, dc, .{ .left = box.left - state.scale(9), .top = box.top - state.scale(9), .right = box.right + state.scale(9), .bottom = box.bottom + state.scale(9) }, false, pal.text),
        .none => {},
    }
}

fn drawLabel(dc: c.HDC, font: ?c.HFONT, hwnd: c.HWND, r: c.RECT, flags: c.UINT) void {
    var buf: [256]u16 = undefined;
    const n: usize = @intCast(@max(c.GetWindowTextW(hwnd, &buf, buf.len), 0));
    const old = if (font) |f| c.SelectObject(dc, f) else null;
    defer if (old) |o| {
        _ = c.SelectObject(dc, o);
    };
    _ = c.SetBkMode(dc, c.TRANSPARENT);
    var tr = r;
    _ = c.DrawTextW(dc, &buf, @intCast(n), &tr, flags);
}

/// A point on a 16 DIP icon grid at the box's top left.
fn gridPoint(state: *const State, box: c.RECT, x: f32, y: f32) c.POINT {
    const s = @as(f32, @floatFromInt(state.dpi)) / 96.0;
    return .{ .x = box.left + @as(c_int, @intFromFloat(@round(x * s))), .y = box.top + @as(c_int, @intFromFloat(@round(y * s))) };
}

/// go-next-symbolic (or go-previous-symbolic, `back`): a chevron of 2 DIP
/// strokes, centered in `r` (a 34 button, or a row icon's box widened by 9).
fn chevron(state: *const State, dc: c.HDC, r: c.RECT, back: bool, color: c.COLORREF) void {
    const icon = state.scale(row_icon);
    const box: c.RECT = .{ .left = r.left + @divTrunc(r.right - r.left - icon, 2), .top = r.top + @divTrunc(r.bottom - r.top - icon, 2), .right = 0, .bottom = 0 };
    const pts: [6][2]f32 = if (back)
        .{ .{ 11.4, 2.6 }, .{ 10.0, 1.2 }, .{ 3.2, 8.0 }, .{ 10.0, 14.8 }, .{ 11.4, 13.4 }, .{ 6.0, 8.0 } }
    else
        .{ .{ 4.6, 2.6 }, .{ 6.0, 1.2 }, .{ 12.8, 8.0 }, .{ 6.0, 14.8 }, .{ 4.6, 13.4 }, .{ 10.0, 8.0 } };
    var poly: [6]c.POINT = undefined;
    for (pts, 0..) |p, i| poly[i] = gridPoint(state, box, p[0], p[1]);
    draw.polygon(dc, &poly, color);
}

/// adw-external-link-symbolic: a box open at its top right corner, and an
/// arrow from its middle out through that corner, 2 DIP strokes on the 16
/// grid.
fn externalLink(state: *const State, dc: c.HDC, box: c.RECT, color: c.COLORREF) void {
    const rects = [_][4]f32{
        // The box: left, bottom, the top's start, the right's end.
        .{ 1, 3, 3, 15 },
        .{ 1, 13, 13, 15 },
        .{ 1, 3, 7, 5 },
        .{ 11, 9, 13, 15 },
        // The arrow's head: along the top and down the right.
        .{ 8, 1, 15, 3 },
        .{ 13, 1, 15, 8 },
    };
    for (rects) |q| {
        const a = gridPoint(state, box, q[0], q[1]);
        const b = gridPoint(state, box, q[2], q[3]);
        draw.fill(dc, .{ .left = a.x, .top = a.y, .right = b.x, .bottom = b.y }, color);
    }
    // The shaft: a 2 DIP band from the middle to the corner.
    const band = [_][2]f32{ .{ 5.6, 9.0 }, .{ 7.0, 10.4 }, .{ 14.4, 3.0 }, .{ 13.0, 1.6 } };
    var poly: [4]c.POINT = undefined;
    for (band, 0..) |p, i| poly[i] = gridPoint(state, box, p[0], p[1]);
    draw.polygon(dc, &poly, color);
}

/// Every button: Enter clicks the one with the keyboard (owner-drawn
/// buttons never become the default), Alt+Left or Backspace go back from a
/// subpage, and the mouse over it washes it (hover).
fn buttonProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const dialog = c.GetParent(hwnd) orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const s = fromHwnd(dialog) orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const id: u16 = @intCast(c.GetDlgCtrlID(hwnd));
    switch (msg) {
        c.WM_GETDLGCODE => if (lparam != 0) {
            const m: *const c.MSG = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (m.message == c.WM_KEYDOWN and (m.wParam == c.VK_RETURN or (m.wParam == c.VK_BACK and s.page != .main))) return c.DLGC_WANTALLKEYS;
        },
        c.WM_KEYDOWN => {
            // Held, the key repeats: it acts once (each repeat would open
            // the link again, or move on to the next page's control).
            const repeat = lparam & (1 << 30) != 0;
            if (repeat and (wparam == c.VK_RETURN or wparam == c.VK_BACK)) return 0;
            if (wparam == c.VK_RETURN) {
                _ = c.SendMessageW(dialog, c.WM_COMMAND, id, @bitCast(@intFromPtr(hwnd)));
                return 0;
            }
            if (wparam == c.VK_BACK and s.page != .main) {
                showPage(dialog, s, .main);
                return 0;
            }
        },
        c.WM_SYSKEYDOWN => if (wparam == c.VK_LEFT and s.page != .main) {
            showPage(dialog, s, .main);
            return 0;
        },
        c.WM_MOUSEMOVE => if (s.hover != id) {
            const prev = s.hover;
            s.hover = id;
            if (prev != 0) if (c.GetDlgItem(dialog, prev)) |p| {
                _ = c.InvalidateRect(p, null, c.FALSE);
            };
            _ = c.InvalidateRect(hwnd, null, c.FALSE);
            var tme: c.TRACKMOUSEEVENT = .{ .dwFlags = c.TME_LEAVE, .hwndTrack = hwnd };
            _ = c.TrackMouseEvent(&tme);
        },
        c.WM_MOUSELEAVE => if (s.hover == id) {
            s.hover = 0;
            _ = c.InvalidateRect(hwnd, null, c.FALSE);
        },
        else => {},
    }
    return c.CallWindowProcW(s.button_proc, hwnd, msg, wparam, lparam);
}

test "about dialog template: every page's controls" {
    const alloc = std.testing.allocator;
    const Ctx = struct {
        fn open(_: *anyopaque, _: Link) void {}
        fn copy(_: *anyopaque, _: []const u8) bool {
            return true;
        }
    };
    var dummy: u8 = 0;
    var state: State = .{
        .alloc = alloc,
        .opts = .{
            .owner = null,
            .dark = true,
            .title = "About",
            .name = "murrtty",
            .developer = "Someone",
            .version = "1.0.0",
            .website = "https://example.org",
            .issues = "https://example.org/issues",
            .credits = &.{ .{ .text = "intro" }, .{ .heading = "By" }, .{ .links = &.{ .{ .label = "A", .target = "a" }, .{ .label = "B", .target = "b" } } } },
            .legal = &.{ .{ .text = "terms" }, .{ .links = &.{.{ .label = "License", .target = "c" }} } },
            .ctx = &dummy,
            .open = Ctx.open,
            .copy = Ctx.copy,
        },
        .title = std.unicode.utf8ToUtf16LeStringLiteral(""),
        .name = std.unicode.utf8ToUtf16LeStringLiteral(""),
        .developer = std.unicode.utf8ToUtf16LeStringLiteral(""),
        .version = std.unicode.utf8ToUtf16LeStringLiteral(""),
        .pal = draw.dialogPalette(true),
    };
    defer state.deinit();
    try buildControls(&state);
    // Close, back, version, four main rows, three links, the toast.
    try std.testing.expectEqual(@as(usize, 11), state.controls.items.len);
    try std.testing.expectEqual(@as(usize, 3), state.blocks.items.len);
    try std.testing.expect(state.find(id_credit_links + 1) != null);
    try std.testing.expect(state.find(id_legal_links) != null);
    var t: std.ArrayList(u8) = .empty;
    defer t.deinit(alloc);
    try buildTemplate(alloc, &t, &state);
    try std.testing.expectEqual(@as(u16, 11), std.mem.readInt(u16, t.items[8..10], .little));
    try std.testing.expect(t.items.len % 2 == 0);
}
