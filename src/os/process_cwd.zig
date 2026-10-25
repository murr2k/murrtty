//! Windows: a process's current directory, read from its PEB, for a shell
//! that never reports its own (roadmap 2.4). cmd's `cd` changes it;
//! PowerShell's Set-Location and WSL don't (their locations are their own),
//! so for those it stays where they started and would name the wrong folder.
const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const Allocator = std.mem.Allocator;
const cwd_report = @import("cwd_report.zig");

/// The rights `get` needs on the process handle: PROCESS_VM_READ and
/// PROCESS_QUERY_LIMITED_INFORMATION.
pub const access: windows.DWORD = 0x0010 | 0x1000;

/// The current directory of `process` as a drive path (taken as
/// cwd_report takes a report), or null if it can't be read or isn't one.
/// A 32-bit process on 64-bit Windows keeps its directory in its own PEB,
/// which this doesn't read. The caller owns the result.
pub fn get(alloc: Allocator, process: windows.HANDLE) Allocator.Error!?[]u8 {
    var wow64: usize = 0;
    if (windows.ntdll.NtQueryInformationProcess(process, .Wow64Information, &wow64, @sizeOf(usize), null) != .SUCCESS) return null;
    if (wow64 != 0) return null;
    var info: windows.PROCESS.BASIC_INFORMATION = undefined;
    if (windows.ntdll.NtQueryInformationProcess(process, .BasicInformation, &info, @sizeOf(windows.PROCESS.BASIC_INFORMATION), null) != .SUCCESS) return null;

    var params: usize = undefined;
    if (!read(process, @intFromPtr(info.PebBaseAddress) + @offsetOf(windows.PEB, "ProcessParameters"), std.mem.asBytes(&params))) return null;
    const dos_path = params +
        @offsetOf(windows.RTL_USER_PROCESS_PARAMETERS, "CurrentDirectory") +
        @offsetOf(windows.CURDIR, "DosPath");

    // The shell can change directory while this reads, so the string's
    // header is read again after its text; one more try if it moved.
    for (0..2) |_| {
        var str: windows.UNICODE_STRING = undefined;
        if (!read(process, dos_path, std.mem.asBytes(&str))) return null;
        if (str.Length == 0 or str.Length % 2 != 0) return null;
        const text = @intFromPtr(str.Buffer orelse return null);
        const path = try alloc.alloc(u16, str.Length / 2);
        defer alloc.free(path);
        if (!read(process, text, std.mem.sliceAsBytes(path))) return null;
        var again: windows.UNICODE_STRING = undefined;
        if (!read(process, dos_path, std.mem.asBytes(&again))) return null;
        if (again.Length != str.Length or again.Buffer != str.Buffer) continue;

        // The PEB keeps a trailing backslash (C:\dir\); a root keeps it.
        const end = if (path.len > 3 and path[path.len - 1] == '\\') path.len - 1 else path.len;
        const wtf8 = try std.unicode.wtf16LeToWtf8Alloc(alloc, path[0..end]);
        defer alloc.free(wtf8);
        return cwd_report.fromRaw(alloc, wtf8);
    }
    return null;
}

fn read(process: windows.HANDLE, address: usize, buf: []u8) bool {
    var n: usize = 0;
    const status = windows.ntdll.NtReadVirtualMemory(process, @ptrFromInt(address), buf.ptr, buf.len, &n);
    return status == .SUCCESS and n == buf.len;
}

test "process_cwd: this process" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const want = try std.process.currentPathAlloc(testing.io, alloc);
    defer alloc.free(want);
    const got = (try get(alloc, windows.GetCurrentProcess())) orelse return error.TestUnexpectedResult;
    defer alloc.free(got);
    try testing.expectEqualStrings(want, got);
}
