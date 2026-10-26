//! Console attachment for CLI actions.
//!
//! murrtty.exe uses the GUI subsystem, so when it is started from a
//! console it gets no standard handles and `ghostty +version` would
//! print nothing. When a CLI action is requested and output isn't
//! already redirected, attach to the parent console.
const std = @import("std");
const c = @import("c.zig");

const STD_OUTPUT_HANDLE: c.DWORD = @bitCast(@as(i32, -11));
const STD_ERROR_HANDLE: c.DWORD = @bitCast(@as(i32, -12));
const GENERIC_READ = 0x80000000;
const GENERIC_WRITE = 0x40000000;
const FILE_SHARE_READ = 0x00000001;
const FILE_SHARE_WRITE = 0x00000002;
const OPEN_EXISTING = 3;
const INVALID_HANDLE_VALUE: c.HANDLE = @ptrFromInt(std.math.maxInt(usize));

extern "kernel32" fn GetCommandLineW() callconv(.winapi) c.LPCWSTR;
extern "kernel32" fn LocalFree(?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn SetStdHandle(c.DWORD, c.HANDLE) callconv(.winapi) c.BOOL;
extern "kernel32" fn CreateFileW(
    c.LPCWSTR,
    c.DWORD,
    c.DWORD,
    ?*anyopaque,
    c.DWORD,
    c.DWORD,
    ?c.HANDLE,
) callconv(.winapi) c.HANDLE;
extern "shell32" fn CommandLineToArgvW(c.LPCWSTR, *c_int) callconv(.winapi) ?[*][*:0]u16;

pub fn attachForCli() void {
    // Redirected (pipe, file) or inherited handles: leave them alone.
    const params = std.os.windows.peb().ProcessParameters;
    if (@intFromPtr(params.hStdOutput) != 0) return;
    if (!hasCliAction()) return;

    if (c.AttachConsole(c.ATTACH_PARENT_PROCESS) == 0) return;
    const out = CreateFileW(
        c.L("CONOUT$"),
        GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        null,
        OPEN_EXISTING,
        0,
        null,
    );
    if (out == INVALID_HANDLE_VALUE) return;
    _ = SetStdHandle(STD_OUTPUT_HANDLE, out);
    _ = SetStdHandle(STD_ERROR_HANDLE, out);
}

/// True if any argument starts with '+', i.e. a CLI action.
fn hasCliAction() bool {
    var argc: c_int = 0;
    const argv = CommandLineToArgvW(GetCommandLineW(), &argc) orelse return false;
    defer _ = LocalFree(@ptrCast(argv));
    for (argv[1..@intCast(@max(argc, 1))]) |arg| {
        if (arg[0] == '+') return true;
    }
    return false;
}
