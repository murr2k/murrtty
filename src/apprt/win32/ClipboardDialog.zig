//! The clipboard confirmation (roadmap 3.9), GTK's: a heading and body for
//! what the program asked, the text in a scrollable monospace box, Allow
//! and Deny (the default; Escape too), and for OSC 52 "Remember choice for
//! this split", which holds until the configuration is reloaded. A real
//! dialog from a template in memory, like TitleDialog, so the GUI tests
//! answer it with WM_COMMAND.
//!
//! The caller runs it in a modal scope (App.beginModal) from the message
//! loop, never from inside a core callback.
const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig");
const text_util = @import("text.zig");
const TitleDialog = @import("TitleDialog.zig");

const log = std.log.scoped(.win32_clipboard_dialog);

/// Control ids, for the GUI tests. Allow and Deny are IDYES and IDNO, the
/// answers of the message box this replaced.
pub const id_text = 100;
pub const id_remember = 101;
pub const id_allow = c.IDYES;
pub const id_deny = c.IDNO;

/// What the program asked for.
pub const Kind = enum {
    read,
    write,
    paste,

    pub fn heading(self: Kind) []const u8 {
        return switch (self) {
            .read, .write => "Authorize Clipboard Access",
            .paste => "Warning: Potentially Unsafe Paste",
        };
    }

    pub fn body(self: Kind) []const u8 {
        return switch (self) {
            .read => "An application is attempting to read from the clipboard. The current clipboard contents are shown below.",
            // GTK's says the current contents are shown; it shows these.
            .write => "An application is attempting to write to the clipboard. The text it would write is shown below.",
            .paste => "Pasting this text into the terminal may be dangerous as it looks like some commands may be executed.",
        };
    }
};

pub const Answer = struct {
    allow: bool = false,
    /// Remember the answer for the split (only offered for OSC 52).
    remember: bool = false,
};

/// The most text the box shows; Allow still uses all of it.
const max_shown = 256 * 1024;

const State = struct {
    alloc: Allocator,
    owner: ?c.HWND,
    text: []const u8,
    answer: Answer = .{},
    font: ?c.HFONT = null,
};

/// Ask about `text`. Anything but Allow (Deny, Escape, the close box, a
/// dialog that couldn't be shown) denies.
pub fn ask(
    alloc: Allocator,
    owner: ?c.HWND,
    kind: Kind,
    text: []const u8,
    can_remember: bool,
) Answer {
    var template: std.ArrayList(u8) = .empty;
    defer template.deinit(alloc);
    buildTemplate(alloc, &template, kind, can_remember) catch return .{};

    var state: State = .{ .alloc = alloc, .owner = owner, .text = text };
    const ret = c.DialogBoxIndirectParamW(
        c.GetModuleHandleW(null),
        @ptrCast(template.items.ptr),
        owner,
        &dialogProc,
        @bitCast(@intFromPtr(&state)),
    );
    // The box used the font until it was destroyed with the dialog.
    if (state.font) |f| _ = c.DeleteObject(f);
    if (ret == -1) {
        log.warn("clipboard dialog failed err={}", .{c.GetLastError()});
        return .{};
    }
    return state.answer;
}

/// The template: the body, the text box, the remember box if offered,
/// Allow and Deny, in dialog units, in Segoe UI 9.
fn buildTemplate(alloc: Allocator, out: *std.ArrayList(u8), kind: Kind, can_remember: bool) !void {
    const buttons_y: i16 = if (can_remember) 183 else 167;
    const style: u32 = c.WS_POPUP | c.WS_CAPTION | c.WS_SYSMENU | c.DS_MODALFRAME | c.DS_SETFONT;
    try TitleDialog.put32(alloc, out, style);
    try TitleDialog.put32(alloc, out, 0); // extended style
    try TitleDialog.put16(alloc, out, if (can_remember) 5 else 4); // items
    for ([_]i16{ 0, 0, 320, buttons_y + 21 }) |v| try TitleDialog.put16(alloc, out, @bitCast(v));
    try TitleDialog.put16(alloc, out, 0); // no menu
    try TitleDialog.put16(alloc, out, 0); // the standard dialog class
    try TitleDialog.putString(alloc, out, kind.heading());
    try TitleDialog.put16(alloc, out, 9); // point size
    try TitleDialog.putString(alloc, out, "Segoe UI");

    const static_class = 0x0082;
    const edit_class = 0x0081;
    const button_class = 0x0080;
    const child = c.WS_CHILD | c.WS_VISIBLE;
    try TitleDialog.putItem(alloc, out, child | c.SS_NOPREFIX, .{ 7, 7, 306, 20 }, 0xFFFF, static_class, kind.body());
    try TitleDialog.putItem(
        alloc,
        out,
        child | c.WS_BORDER | c.WS_TABSTOP | c.WS_VSCROLL | c.WS_HSCROLL |
            c.ES_MULTILINE | c.ES_READONLY | c.ES_AUTOVSCROLL | c.ES_AUTOHSCROLL,
        .{ 7, 31, 306, 128 },
        id_text,
        edit_class,
        "",
    );
    if (can_remember) try TitleDialog.putItem(
        alloc,
        out,
        child | c.WS_TABSTOP | c.BS_AUTOCHECKBOX,
        .{ 7, 167, 306, 10 },
        id_remember,
        button_class,
        "&Remember choice for this split (until the configuration is reloaded)",
    );
    try TitleDialog.putItem(alloc, out, child | c.WS_TABSTOP, .{ 209, buttons_y, 50, 14 }, id_allow, button_class, "&Allow");
    try TitleDialog.putItem(alloc, out, child | c.WS_TABSTOP | c.BS_DEFPUSHBUTTON, .{ 263, buttons_y, 50, 14 }, id_deny, button_class, "&Deny");
}

/// The text as the box shows it, NUL-terminated UTF-16: cut at max_shown
/// with a note; every line break (LF, CR or CRLF) as CRLF, the only one
/// the edit control breaks at; other control characters as their Control
/// Pictures (U+2400 + code, DEL U+2421), so none hides what follows (a
/// NUL would end the text) or runs two lines into one.
fn displayText(alloc: Allocator, text: []const u8) Allocator.Error![:0]u16 {
    const shown = text_util.truncate(text, max_shown);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, shown.len + shown.len / 8 + 64);
    var i: usize = 0;
    while (i < shown.len) : (i += 1) {
        const b = shown[i];
        switch (b) {
            '\r' => {
                if (i + 1 < shown.len and shown[i + 1] == '\n') i += 1;
                try out.appendSlice(alloc, "\r\n");
            },
            '\n' => try out.appendSlice(alloc, "\r\n"),
            '\t' => try out.append(alloc, b),
            0...8, 11...12, 14...0x1F => try out.appendSlice(alloc, &.{ 0xE2, 0x90, 0x80 + b }),
            0x7F => try out.appendSlice(alloc, "\u{2421}"),
            else => try out.append(alloc, b),
        }
    }
    if (shown.len < text.len) {
        try out.print(alloc, "\r\n\r\n... ({d} more bytes not shown)", .{text.len - shown.len});
    }
    return text_util.utf16Lossy(alloc, out.items);
}

fn fromHwnd(hwnd: c.HWND) ?*State {
    const ptr: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA));
    return if (ptr != 0) @ptrFromInt(ptr) else null;
}

/// Fill the box: the text, in a monospace font at the dialog's DPI.
fn fill(state: *State, hwnd: c.HWND, edit: c.HWND) void {
    var lf: c.LOGFONTW = std.mem.zeroes(c.LOGFONTW);
    const dpi: c_long = @intCast(c.GetDpiForWindow(hwnd));
    lf.lfHeight = -@divTrunc(9 * dpi + 36, 72);
    lf.lfWeight = 400;
    lf.lfQuality = 5; // CLEARTYPE_QUALITY
    lf.lfPitchAndFamily = 0x31; // FIXED_PITCH | FF_MODERN, if Consolas is missing
    const face = std.unicode.utf8ToUtf16LeStringLiteral("Consolas");
    @memcpy(lf.lfFaceName[0..face.len], face);
    state.font = c.CreateFontIndirectW(&lf);
    if (state.font) |f| _ = c.SendMessageW(edit, c.WM_SETFONT, @intFromPtr(f), 0);

    const wide = displayText(state.alloc, state.text) catch return;
    defer state.alloc.free(wide);
    _ = c.SetWindowTextW(edit, wide.ptr);
}

fn dialogProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) isize {
    switch (msg) {
        c.WM_INITDIALOG => {
            const state: *State = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, lparam);
            TitleDialog.center(hwnd, state.owner);
            if (c.GetDlgItem(hwnd, id_text)) |edit| fill(state, hwnd, edit);
            // Deny has the keyboard, GTK's suggested answer.
            if (c.GetDlgItem(hwnd, id_deny)) |deny| _ = c.SetFocus(deny);
            // Not the default focus: it is set.
            return 0;
        },
        c.WM_CTLCOLORSTATIC => {
            // The read-only box on the window's color, not the dialog's.
            const edit = c.GetDlgItem(hwnd, id_text) orelse return 0;
            if (lparam != @as(c.LPARAM, @bitCast(@intFromPtr(edit)))) return 0;
            const hdc: c.HDC = @ptrFromInt(wparam);
            _ = c.SetTextColor(hdc, c.GetSysColor(c.COLOR_WINDOWTEXT));
            _ = c.SetBkColor(hdc, c.GetSysColor(c.COLOR_WINDOW));
            const brush = c.GetSysColorBrush(c.COLOR_WINDOW) orelse return 0;
            return @bitCast(@intFromPtr(brush));
        },
        c.WM_COMMAND => switch (c.loword(wparam)) {
            id_allow, id_deny, c.IDCANCEL => |id| {
                if (fromHwnd(hwnd)) |state| {
                    // Escape and the close box decide nothing to remember.
                    const box = c.GetDlgItem(hwnd, id_remember);
                    state.answer = .{
                        .allow = id == id_allow,
                        .remember = id != c.IDCANCEL and box != null and
                            c.SendMessageW(box.?, c.BM_GETCHECK, 0, 0) == c.BST_CHECKED,
                    };
                }
                _ = c.EndDialog(hwnd, id);
                return 1;
            },
            else => {},
        },
        else => {},
    }
    return 0;
}

test "clipboard dialog: line breaks become CRLF, control characters show" {
    const alloc = std.testing.allocator;
    const got = try displayText(alloc, "a\nb\r\nc\rd\x00e\x1bf\x7f\tg");
    defer alloc.free(got);
    const want = try text_util.utf16Lossy(alloc, "a\r\nb\r\nc\r\nd\u{2400}e\u{241B}f\u{2421}\tg");
    defer alloc.free(want);
    try std.testing.expectEqualSlices(u16, want, got);
}

test "clipboard dialog: long text is cut with a note" {
    const alloc = std.testing.allocator;
    const text = try alloc.alloc(u8, max_shown + 10);
    defer alloc.free(text);
    @memset(text, 'x');
    const got = try displayText(alloc, text);
    defer alloc.free(got);
    const tail = try text_util.utf16Lossy(alloc, "x\r\n\r\n... (10 more bytes not shown)");
    defer alloc.free(tail);
    try std.testing.expect(std.mem.endsWith(u16, got, tail));
}

test "clipboard dialog template: items start on DWORD boundaries" {
    const alloc = std.testing.allocator;
    for ([_]bool{ false, true }) |remember| {
        var t: std.ArrayList(u8) = .empty;
        defer t.deinit(alloc);
        try buildTemplate(alloc, &t, .read, remember);
        try std.testing.expectEqual(@as(u16, if (remember) 5 else 4), std.mem.readInt(u16, t.items[8..10], .little));
        try std.testing.expect(t.items.len % 2 == 0);
    }
}
