//! Text helpers for showing UTF-8 from the core in Win32 dialogs.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// UTF-16 copy of UTF-8 text for display, with each invalid byte replaced
/// by U+FFFD instead of failing. Clipboard and program text is not always
/// valid UTF-8, and a confirmation dialog that fails to appear denies the
/// request without asking.
pub fn utf16Lossy(alloc: Allocator, s: []const u8) Allocator.Error![:0]u16 {
    var out: std.ArrayList(u16) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, s.len + 1);

    var i: usize = 0;
    while (i < s.len) {
        var cp: u21 = 0xFFFD;
        var len: usize = 1;
        if (std.unicode.utf8ByteSequenceLength(s[i])) |n| {
            if (i + n <= s.len) {
                if (std.unicode.utf8Decode(s[i..][0..n])) |decoded| {
                    cp = decoded;
                    len = n;
                } else |_| {}
            }
        } else |_| {}

        if (cp < 0x10000) {
            try out.append(alloc, @intCast(cp));
        } else {
            const v = cp - 0x10000;
            try out.append(alloc, @intCast(0xD800 + (v >> 10)));
            try out.append(alloc, @intCast(0xDC00 + (v & 0x3FF)));
        }
        i += len;
    }

    return out.toOwnedSliceSentinel(alloc, 0);
}

/// At most the first `max` bytes of `s`, cut back to a character boundary
/// so a multibyte character is never split.
pub fn truncate(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return s[0..n];
}

/// Where Ctrl+Backspace at `caret` deletes back to: past the spaces before
/// it, then past the word before those.
pub fn wordStart(text: []const u16, caret: usize) usize {
    var i = @min(caret, text.len);
    while (i > 0 and text[i - 1] == ' ') i -= 1;
    while (i > 0 and text[i - 1] != ' ') i -= 1;
    return i;
}

test "wordStart: the word before the caret, and the spaces after it" {
    const s = std.unicode.utf8ToUtf16LeStringLiteral("new tab  ");
    try std.testing.expectEqual(@as(usize, 4), wordStart(s, s.len));
    try std.testing.expectEqual(@as(usize, 4), wordStart(s, 7));
    try std.testing.expectEqual(@as(usize, 4), wordStart(s, 5));
    try std.testing.expectEqual(@as(usize, 0), wordStart(s, 4));
    try std.testing.expectEqual(@as(usize, 0), wordStart(s, 0));
}

test "utf16Lossy: valid text" {
    const alloc = std.testing.allocator;
    const out = try utf16Lossy(alloc, "h\xc3\xa9 \xf0\x9f\x9a\x80");
    defer alloc.free(out);
    try std.testing.expectEqualSlices(u16, &.{ 'h', 0xE9, ' ', 0xD83D, 0xDE80 }, out);
}

test "utf16Lossy: invalid bytes become U+FFFD" {
    const alloc = std.testing.allocator;
    // A stray continuation byte, a truncated sequence at the end, and an
    // encoded surrogate (not valid UTF-8).
    const out = try utf16Lossy(alloc, "a\x80b\xed\xa0\x80c\xe2\x82");
    defer alloc.free(out);
    try std.testing.expectEqualSlices(
        u16,
        &.{ 'a', 0xFFFD, 'b', 0xFFFD, 0xFFFD, 0xFFFD, 'c', 0xFFFD, 0xFFFD },
        out,
    );
}

test "truncate: never splits a character" {
    // "é" is two bytes; cutting at 2 would split it.
    try std.testing.expectEqualStrings("a", truncate("a\xc3\xa9b", 2));
    try std.testing.expectEqualStrings("a\xc3\xa9", truncate("a\xc3\xa9b", 3));
    try std.testing.expectEqualStrings("ab", truncate("ab", 10));
    try std.testing.expectEqualStrings("", truncate("\xf0\x9f\x9a\x80", 3));
}
