//! The handler the links-open scenario registers for its test protocol and
//! file type:
//!
//!   ghostty-gui-record <marker file> <target>
//!
//! writes the target the shell passed (a URL or a path) to the marker file
//! as UTF-8, and exits. It is a Windows-subsystem program, so it opens no
//! console (which Windows could hand to Windows Terminal on the user's
//! desktop) and no window, and it never interprets its argument the way a
//! shell would.
const std = @import("std");
const w = @import("win.zig");

pub fn main() void {
    var argc: c_int = 0;
    const argv = w.CommandLineToArgvW(w.GetCommandLineW(), &argc) orelse return;
    defer _ = w.LocalFree(@ptrCast(argv));
    if (argc != 3) return;

    const target = std.mem.span(argv[2]);
    var buf: [16384]u8 = undefined;
    // UTF-8 needs at most three bytes per UTF-16 unit.
    if (target.len * 3 > buf.len) return;
    const n = std.unicode.utf16LeToUtf8(&buf, target) catch return;

    const file = w.CreateFileW(argv[1], w.GENERIC_WRITE, 0, null, w.CREATE_ALWAYS, w.FILE_ATTRIBUTE_NORMAL, null);
    if (file == w.INVALID_HANDLE_VALUE) return;
    defer _ = w.CloseHandle(file);
    var written: w.DWORD = 0;
    _ = w.WriteFile(file, &buf, @intCast(n), &written, null);
}
