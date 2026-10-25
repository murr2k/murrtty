const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const LocalHostnameValidationError = error{
    PermissionDenied,
    Unexpected,
};

/// Checks if a hostname is local to the current machine. This matches
/// both "localhost" and the current hostname of the machine (as returned
/// by `gethostname`).
pub fn isLocal(hostname: []const u8) LocalHostnameValidationError!bool {
    // A 'localhost' hostname is always considered local.
    if (std.mem.eql(u8, "localhost", hostname)) return true;

    // If hostname is not "localhost" it must match our hostname.
    switch (builtin.target.os.tag) {
        .windows => return isLocalWindows(hostname),
        else => {
            var buf: [posix.HOST_NAME_MAX]u8 = undefined;
            const ourHostname = try posix.gethostname(&buf);
            return std.mem.eql(u8, hostname, ourHostname);
        },
    }
}

/// Windows compares computer names without case, and a sender may use any
/// of them: the NetBIOS name (what GetComputerName returns, upper case and
/// at most 15 characters), the DNS host name or the fully qualified one.
fn isLocalWindows(hostname: []const u8) bool {
    const windows = @import("windows.zig");
    if (std.ascii.eqlIgnoreCase(hostname, "localhost")) return true;
    for ([_]windows.COMPUTER_NAME_FORMAT{ .NetBIOS, .DnsHostname, .DnsFullyQualified }) |format| {
        var buf16: [256]u16 = undefined;
        var len16: windows.DWORD = buf16.len;
        if (windows.exp.kernel32.GetComputerNameExW(format, &buf16, &len16) == windows.FALSE) continue;
        var buf8: [buf16.len * 3]u8 = undefined;
        const len8 = std.unicode.utf16LeToUtf8(&buf8, buf16[0..len16]) catch continue;
        if (len8 > 0 and std.ascii.eqlIgnoreCase(hostname, buf8[0..len8])) return true;
    }
    return false;
}

test "isLocal returns true when provided hostname is localhost" {
    try std.testing.expect(try isLocal("localhost"));
}

test "isLocal returns true when hostname is local" {
    switch (builtin.target.os.tag) {
        .windows => {
            const windows = @import("windows.zig");
            var buf: [256:0]u8 = undefined;
            var nSize: windows.DWORD = buf.len;
            if (windows.exp.kernel32.GetComputerNameA(&buf, &nSize) == windows.FALSE)
                return error.GetComputerNameFailed;
            const localHostname = buf[0..nSize];
            try std.testing.expect(try isLocal(localHostname));
        },
        else => {
            var buf: [posix.HOST_NAME_MAX]u8 = undefined;
            const localHostname = try posix.gethostname(&buf);
            try std.testing.expect(try isLocal(localHostname));
        },
    }
}

test "isLocal on Windows ignores case and takes the DNS names" {
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;
    const windows = @import("windows.zig");
    try std.testing.expect(try isLocal("LocalHost"));
    for ([_]windows.COMPUTER_NAME_FORMAT{ .NetBIOS, .DnsHostname, .DnsFullyQualified }) |format| {
        var buf16: [256]u16 = undefined;
        var len16: windows.DWORD = buf16.len;
        if (windows.exp.kernel32.GetComputerNameExW(format, &buf16, &len16) == windows.FALSE) continue;
        // A machine outside a domain has no fully qualified name to add.
        if (len16 == 0) continue;
        var buf8: [buf16.len * 3]u8 = undefined;
        const name = buf8[0..try std.unicode.utf16LeToUtf8(&buf8, buf16[0..len16])];
        var lower: [buf8.len]u8 = undefined;
        var upper: [buf8.len]u8 = undefined;
        try std.testing.expect(try isLocal(std.ascii.lowerString(&lower, name)));
        try std.testing.expect(try isLocal(std.ascii.upperString(&upper, name)));
    }
}

test "isLocal returns false when hostname is not local" {
    try std.testing.expectEqual(
        false,
        try isLocal("not-the-local-hostname"),
    );
}
