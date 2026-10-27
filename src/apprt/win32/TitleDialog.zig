//! The title prompt (roadmap 3.5), GTK's: "Change Terminal Title" (or Tab,
//! or Window) with "Leave blank to restore the default title.", an edit
//! field holding the current title, selected, and OK and Cancel. It is a
//! real dialog (from a template built in memory), so Enter, Escape and Tab
//! work as in any Windows dialog, and the GUI tests drive it as one.
//!
//! The caller runs it in a modal scope (App.beginModal) from the message
//! loop, never from inside a core callback.
const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const c = @import("c.zig");
const text_util = @import("text.zig");

const log = std.log.scoped(.win32_title_dialog);

/// The edit field's control id, for the GUI tests.
pub const id_edit = 100;

const State = struct {
    alloc: Allocator,
    owner: ?c.HWND,
    initial: []const u8,
    /// What OK left in the field, as UTF-8.
    result: ?[]u8 = null,
    /// The field couldn't be read (out of memory, a lone surrogate): taken
    /// as Cancel, never as a blank name that would clear the title.
    failed: bool = false,
};

/// The dialog's heading, GTK's.
pub fn heading(which: apprt.action.PromptTitle) []const u8 {
    return switch (which) {
        .surface => "Change Terminal Title",
        .tab => "Change Tab Title",
        .window => "Change Window Title",
    };
}

/// Ask for a title, showing `initial`. Returns what OK left in the field
/// (empty to restore the default title; the caller frees it), or null for
/// Cancel.
pub fn ask(
    alloc: Allocator,
    owner: ?c.HWND,
    which: apprt.action.PromptTitle,
    initial: []const u8,
) Allocator.Error!?[]u8 {
    var template: std.ArrayList(u8) = .empty;
    defer template.deinit(alloc);
    try buildTemplate(alloc, &template, heading(which));

    var state: State = .{ .alloc = alloc, .owner = owner, .initial = initial };
    const ret = c.DialogBoxIndirectParamW(
        c.GetModuleHandleW(null),
        @ptrCast(template.items.ptr),
        owner,
        &dialogProc,
        @bitCast(@intFromPtr(&state)),
    );
    if (ret == -1) {
        log.warn("title dialog failed err={}", .{c.GetLastError()});
        return null;
    }
    if (ret != c.IDOK or state.failed) {
        if (state.result) |r| alloc.free(r);
        return null;
    }
    return state.result orelse try alloc.dupe(u8, "");
}

/// A dialog template: a caption, the hint, the edit field, OK and Cancel,
/// in dialog units, in Segoe UI 9.
fn buildTemplate(alloc: Allocator, out: *std.ArrayList(u8), caption: []const u8) !void {
    const style: u32 = c.WS_POPUP | c.WS_CAPTION | c.WS_SYSMENU | c.DS_MODALFRAME | c.DS_SETFONT;
    try put32(alloc, out, style);
    try put32(alloc, out, 0); // extended style
    try put16(alloc, out, 4); // items
    for ([_]i16{ 0, 0, 220, 64 }) |v| try put16(alloc, out, @bitCast(v));
    try put16(alloc, out, 0); // no menu
    try put16(alloc, out, 0); // the standard dialog class
    try putString(alloc, out, caption);
    try put16(alloc, out, 9); // point size
    try putString(alloc, out, "Segoe UI");

    const static_class = 0x0082;
    const edit_class = 0x0081;
    const button_class = 0x0080;
    const child = c.WS_CHILD | c.WS_VISIBLE;
    try putItem(alloc, out, child, .{ 7, 7, 206, 10 }, 0xFFFF, static_class, "Leave blank to restore the default title.");
    try putItem(alloc, out, child | c.WS_BORDER | c.WS_TABSTOP | c.ES_AUTOHSCROLL, .{ 7, 20, 206, 14 }, id_edit, edit_class, "");
    try putItem(alloc, out, child | c.WS_TABSTOP | c.BS_DEFPUSHBUTTON, .{ 109, 43, 50, 14 }, c.IDOK, button_class, "OK");
    try putItem(alloc, out, child | c.WS_TABSTOP, .{ 163, 43, 50, 14 }, c.IDCANCEL, button_class, "Cancel");
}

pub fn putItem(alloc: Allocator, out: *std.ArrayList(u8), style: u32, rect: [4]i16, id: u16, class: u16, text: []const u8) !void {
    // Each item starts on a DWORD boundary.
    while (out.items.len % 4 != 0) try out.append(alloc, 0);
    try put32(alloc, out, style);
    try put32(alloc, out, 0);
    for (rect) |v| try put16(alloc, out, @bitCast(v));
    try put16(alloc, out, id);
    try put16(alloc, out, 0xFFFF);
    try put16(alloc, out, class);
    try putString(alloc, out, text);
    try put16(alloc, out, 0); // no creation data
}

pub fn put16(alloc: Allocator, out: *std.ArrayList(u8), v: u16) !void {
    try out.appendSlice(alloc, &std.mem.toBytes(std.mem.nativeToLittle(u16, v)));
}

pub fn put32(alloc: Allocator, out: *std.ArrayList(u8), v: u32) !void {
    try out.appendSlice(alloc, &std.mem.toBytes(std.mem.nativeToLittle(u32, v)));
}

/// A NUL-terminated UTF-16 string (ASCII here).
pub fn putString(alloc: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |b| try put16(alloc, out, b);
    try put16(alloc, out, 0);
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
            const edit = c.GetDlgItem(hwnd, id_edit) orelse return 1;
            // The current title, selected, with the keyboard in it (a
            // program's title may hold invalid UTF-8: U+FFFD for it).
            const wide = text_util.utf16Lossy(state.alloc, state.initial) catch null;
            defer if (wide) |w| state.alloc.free(w);
            if (wide) |w| _ = c.SetWindowTextW(edit, w.ptr);
            _ = c.SendMessageW(edit, c.EM_SETSEL, 0, -1);
            center(hwnd, state.owner);
            _ = c.SetFocus(edit);
            // Not the default focus: it is set.
            return 0;
        },
        c.WM_COMMAND => switch (c.loword(wparam)) {
            c.IDOK => {
                if (fromHwnd(hwnd)) |state| if (c.GetDlgItem(hwnd, id_edit)) |edit| {
                    var buf: [1024]u16 = undefined;
                    const n: usize = @intCast(@max(c.GetWindowTextW(edit, &buf, buf.len), 0));
                    state.result = std.unicode.utf16LeToUtf8Alloc(state.alloc, buf[0..n]) catch blk: {
                        state.failed = true;
                        break :blk null;
                    };
                };
                _ = c.EndDialog(hwnd, c.IDOK);
                return 1;
            },
            c.IDCANCEL => {
                _ = c.EndDialog(hwnd, c.IDCANCEL);
                return 1;
            },
            else => {},
        },
        else => {},
    }
    return 0;
}

/// Center the dialog over its owner (dialogs otherwise open at the top left
/// of the screen).
pub fn center(dialog: c.HWND, owner: ?c.HWND) void {
    const o = owner orelse return;
    var orect: c.RECT = .{};
    var drect: c.RECT = .{};
    if (c.GetWindowRect(o, &orect) == 0 or c.GetWindowRect(dialog, &drect) == 0) return;
    const w = drect.right - drect.left;
    const h = drect.bottom - drect.top;
    const x = orect.left + @divTrunc(orect.right - orect.left - w, 2);
    const y = orect.top + @divTrunc(orect.bottom - orect.top - h, 3);
    _ = c.SetWindowPos(dialog, null, x, y, 0, 0, c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE);
}

test "title dialog template: items start on DWORD boundaries" {
    const alloc = std.testing.allocator;
    var t: std.ArrayList(u8) = .empty;
    defer t.deinit(alloc);
    try buildTemplate(alloc, &t, heading(.tab));
    // The header: style, extended style, then 4 items.
    try std.testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, t.items[8..10], .little));
    try std.testing.expect(t.items.len % 2 == 0);
}
