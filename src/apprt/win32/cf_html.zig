//! HTML as Windows' clipboard holds it (roadmap 6.5): the registered
//! "HTML Format" (CF_HTML), a header of byte offsets into the data, then a
//! document with the copied fragment between StartFragment and EndFragment
//! comments, all UTF-8. Rich editors (Word, Outlook, browsers) paste it.
const std = @import("std");
const Allocator = std.mem.Allocator;

const header_format = "Version:0.9\r\nStartHTML:{d:0>10}\r\nEndHTML:{d:0>10}\r\nStartFragment:{d:0>10}\r\nEndFragment:{d:0>10}\r\n";
const before = "<html>\r\n<body>\r\n<!--StartFragment-->";
const after = "<!--EndFragment-->\r\n</body>\r\n</html>";

/// `fragment` (the core's HTML for a selection) as CF_HTML, NUL-terminated
/// as the clipboard's text formats are.
pub fn encode(alloc: Allocator, fragment: []const u8) Allocator.Error![:0]u8 {
    // The offsets are ten digits each, so the header's length is fixed.
    const header_len = std.fmt.count(header_format, .{ 0, 0, 0, 0 });
    const start_fragment = header_len + before.len;
    const end_fragment = start_fragment + fragment.len;
    return std.fmt.allocPrintSentinel(alloc, header_format ++ "{s}{s}{s}", .{
        header_len,
        end_fragment + after.len,
        start_fragment,
        end_fragment,
        before,
        fragment,
        after,
    }, 0);
}

/// The value of header field `name` in CF_HTML `data`.
fn field(data: []const u8, name: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, data, "\r\n");
    while (lines.next()) |line| {
        if (line.len > name.len and std.mem.startsWith(u8, line, name) and line[name.len] == ':')
            return std.fmt.parseInt(usize, line[name.len + 1 ..], 10) catch null;
    }
    return null;
}

test "encode: the offsets find the document and the fragment" {
    const testing = std.testing;
    const fragment = "<div style=\"white-space: pre;\">h\xc3\xa9llo &amp; bye</div>";
    const data = try encode(testing.allocator, fragment);
    defer testing.allocator.free(data);

    try testing.expect(std.mem.startsWith(u8, data, "Version:0.9\r\n"));
    const start_html = field(data, "StartHTML").?;
    const end_html = field(data, "EndHTML").?;
    const start_fragment = field(data, "StartFragment").?;
    const end_fragment = field(data, "EndFragment").?;
    try testing.expectEqualStrings(fragment, data[start_fragment..end_fragment]);
    try testing.expect(std.mem.startsWith(u8, data[start_html..], "<html>"));
    try testing.expectEqual(data.len, end_html);
    try testing.expect(std.mem.endsWith(u8, data[0..end_html], "</html>"));
    try testing.expect(std.mem.endsWith(u8, data[0..start_fragment], "<!--StartFragment-->"));
    try testing.expect(std.mem.startsWith(u8, data[end_fragment..], "<!--EndFragment-->"));
}

test "encode: an empty fragment" {
    const testing = std.testing;
    const data = try encode(testing.allocator, "");
    defer testing.allocator.free(data);
    try testing.expectEqual(field(data, "StartFragment").?, field(data, "EndFragment").?);
}
