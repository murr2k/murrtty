//! The local paths working-directory reports name on Windows. OSC 7 sends a
//! `file://` URL whose path is `/C:/dir`; OSC 9;9 (ConEmu's, which Windows
//! Terminal documents for shells) and iTerm2's `CurrentDir` send the path
//! itself, `C:\dir`, possibly in double quotes. Only a local drive path is
//! taken: not a UNC path (`\\server\share`, another computer), a device
//! path (`\\?\`, `\\.\`), a drive-relative (`C:dir`) or rooted (`\dir`)
//! one, nor anything a directory name can't contain (a DOS device name such
//! as NUL, a name over 255 UTF-16 units, `.` or `..`). Spelling alone
//! decides; the file system is never asked, since terminal output supplies
//! the text. A path taken here can still be unusable as a process's
//! directory (it may not exist, or be too long for CreateProcessW): Exec
//! checks before starting a shell there.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// The drive path an OSC 7 URL's (percent-decoded) path names: `/C:/dir`
/// becomes `C:\dir`. Null if it names none. The caller owns the result.
pub fn fromUrlPath(alloc: Allocator, path: []const u8) Allocator.Error!?[]u8 {
    if (path.len == 0 or path[0] != '/') return null;
    return normalize(alloc, path[1..]);
}

/// The drive path a raw report (OSC 9;9, iTerm2's CurrentDir) names, with
/// surrounding double quotes removed and slashes turned into backslashes.
/// Null if it names none. The caller owns the result.
pub fn fromRaw(alloc: Allocator, raw: []const u8) Allocator.Error!?[]u8 {
    const unquoted = if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"')
        raw[1 .. raw.len - 1]
    else
        raw;
    return normalize(alloc, unquoted);
}

fn normalize(alloc: Allocator, s: []const u8) Allocator.Error!?[]u8 {
    // X:\ or X:/, then the rest.
    if (s.len < 3 or !std.ascii.isAlphabetic(s[0]) or s[1] != ':') return null;
    if (s[2] != '\\' and s[2] != '/') return null;
    for (s[3..]) |b| switch (b) {
        // Control characters, another colon (an alternate data stream) and
        // the characters a name can't contain, wildcards included.
        0...0x1f, 0x7f, ':', '*', '?', '"', '<', '>', '|' => return null,
        else => {},
    };
    if (!std.unicode.utf8ValidateSlice(s)) return null;
    // Each name: names Windows rejects make std's file calls panic in Debug
    // builds when this becomes a new terminal's directory.
    var names = std.mem.tokenizeAny(u8, s[3..], "\\/");
    while (names.next()) |name| {
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return null;
        if ((std.unicode.calcUtf16LeLen(name) catch return null) > 255) return null;
        if (isDeviceName(name)) return null;
    }
    const out = try alloc.dupe(u8, s);
    std.mem.replaceScalar(u8, out, '/', '\\');
    return out;
}

/// Whether Windows reserves `name` for a device (NUL, CON, COM1 and so on,
/// with or without an extension or trailing dots and spaces).
fn isDeviceName(name: []const u8) bool {
    const base = std.mem.trimEnd(u8, name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len], " ");
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$" }) |device| {
        if (std.ascii.eqlIgnoreCase(base, device)) return true;
    }
    if (base.len < 4) return false;
    if (!std.ascii.startsWithIgnoreCase(base, "COM") and !std.ascii.startsWithIgnoreCase(base, "LPT")) return false;
    // A digit, superscripts 1 to 3 included.
    const n = base[3..];
    if (n.len == 1) return std.ascii.isDigit(n[0]);
    for ([_][]const u8{ "\u{b9}", "\u{b2}", "\u{b3}" }) |digit| {
        if (std.mem.eql(u8, n, digit)) return true;
    }
    return false;
}

const testing = std.testing;

fn expectPath(want: ?[]const u8, got: ?[]u8) !void {
    defer if (got) |g| testing.allocator.free(g);
    if (want) |w| {
        try testing.expect(got != null);
        try testing.expectEqualStrings(w, got.?);
    } else {
        try testing.expect(got == null);
    }
}

test "cwd_report: OSC 7 URL paths" {
    const alloc = testing.allocator;
    try expectPath("C:\\Users\\x", try fromUrlPath(alloc, "/C:/Users/x"));
    try expectPath("c:\\a b\\", try fromUrlPath(alloc, "/c:/a b/"));
    try expectPath("D:\\", try fromUrlPath(alloc, "/D:/"));
    try expectPath("C:\\été", try fromUrlPath(alloc, "/C:/été"));
    // Not a drive path.
    try expectPath(null, try fromUrlPath(alloc, "/home/x"));
    try expectPath(null, try fromUrlPath(alloc, "/C:"));
    try expectPath(null, try fromUrlPath(alloc, "/C:x"));
    try expectPath(null, try fromUrlPath(alloc, "C:/x"));
    try expectPath(null, try fromUrlPath(alloc, "//server/share"));
    try expectPath(null, try fromUrlPath(alloc, ""));
    // Spellings a directory name can't have.
    try expectPath(null, try fromUrlPath(alloc, "/C:/x:stream"));
    try expectPath(null, try fromUrlPath(alloc, "/C:/a\x00b"));
    try expectPath(null, try fromUrlPath(alloc, "/C:/a\nb"));
    try expectPath(null, try fromUrlPath(alloc, "/C:/a*"));
    try expectPath(null, try fromUrlPath(alloc, "/C:/\xff"));
}

test "cwd_report: raw paths" {
    const alloc = testing.allocator;
    try expectPath("C:\\Windows", try fromRaw(alloc, "C:\\Windows"));
    try expectPath("C:\\Program Files", try fromRaw(alloc, "\"C:\\Program Files\""));
    try expectPath("C:\\Windows\\System32", try fromRaw(alloc, "C:/Windows/System32"));
    try expectPath("C:\\", try fromRaw(alloc, "C:\\"));
    // Another computer, device paths, relative forms.
    try expectPath(null, try fromRaw(alloc, "\\\\server\\share"));
    try expectPath(null, try fromRaw(alloc, "\\\\?\\C:\\x"));
    try expectPath(null, try fromRaw(alloc, "\\\\.\\pipe\\x"));
    try expectPath(null, try fromRaw(alloc, "C:x"));
    try expectPath(null, try fromRaw(alloc, "\\Windows"));
    try expectPath(null, try fromRaw(alloc, "relative"));
    try expectPath(null, try fromRaw(alloc, "\""));
    try expectPath(null, try fromRaw(alloc, "\"C:\\x"));
    try expectPath(null, try fromRaw(alloc, ""));
}

test "cwd_report: names Windows rejects" {
    const alloc = testing.allocator;
    // Devices, in any case, with an extension or trailing dots and spaces.
    for ([_][]const u8{
        "C:\\NUL",    "C:\\Windows\\nul", "C:\\con.txt",  "C:\\x\\AUX \\y",
        "C:\\prn.",   "C:\\COM1",         "C:\\lpt9.log", "C:\\COM\u{b9}",
        "C:\\conin$", "C:\\CONOUT$.x",    "C:\\x\\.",     "C:\\x\\..\\y",
    }) |raw| try expectPath(null, try fromRaw(alloc, raw));
    // Names that only look like one.
    try expectPath("C:\\COM10", try fromRaw(alloc, "C:\\COM10"));
    try expectPath("C:\\nullable", try fromRaw(alloc, "C:\\nullable"));
    try expectPath("C:\\.git", try fromRaw(alloc, "C:\\.git"));
    try expectPath("C:\\a..b", try fromRaw(alloc, "C:\\a..b"));
    // 255 UTF-16 units is the longest name.
    const long: [256]u8 = @splat('a');
    try expectPath(null, try fromRaw(alloc, "C:\\" ++ long));
    try expectPath("C:\\" ++ long[0..255], try fromRaw(alloc, "C:\\" ++ long[0..255]));
    const accented = comptime accented: {
        var b: [512]u8 = undefined;
        for (0..256) |i| b[i * 2 ..][0..2].* = "\u{e9}".*;
        break :accented b;
    };
    try expectPath(null, try fromRaw(alloc, "C:\\" ++ accented));
}
