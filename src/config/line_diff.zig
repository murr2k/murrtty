//! What saving would change in a configuration file, line by line: the
//! config editor's Review & Save (roadmap F1f) and the count of unsaved
//! changes in its status line. Files are small, so the longest common
//! subsequence of the lines between the common start and end is taken
//! whole; past a size it doesn't try, and shows that middle as removed then
//! added.
const std = @import("std");
const Allocator = std.mem.Allocator;
const EditableFile = @import("EditableFile.zig");

pub const Op = enum { same, removed, added };

pub const Line = struct {
    op: Op,
    /// The line's number in the old text (removed, same) or the new one
    /// (added), from 1.
    number: usize,
    text: []const u8,
};

/// The middle the subsequence is worked out for, at most (its table's
/// cells).
const max_cells = 4_000_000;

/// The lines of `text`, without their line ends.
fn splitLines(alloc: Allocator, text: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        // The empty piece after a final line end is no line.
        if (it.index == null and raw.len == 0) break;
        try out.append(alloc, std.mem.trimEnd(u8, raw, "\r"));
    }
    return out.toOwnedSlice(alloc);
}

/// Every line of `old` and `new` in order, each marked same, removed or
/// added. The texts must outlive the result (its lines point into them).
pub fn diff(alloc: Allocator, old: []const u8, new: []const u8) ![]Line {
    const a = try splitLines(alloc, old);
    defer alloc.free(a);
    const b = try splitLines(alloc, new);
    defer alloc.free(b);

    var out: std.ArrayList(Line) = .empty;
    errdefer out.deinit(alloc);
    var start: usize = 0;
    while (start < a.len and start < b.len and std.mem.eql(u8, a[start], b[start])) start += 1;
    var end_a = a.len;
    var end_b = b.len;
    while (end_a > start and end_b > start and std.mem.eql(u8, a[end_a - 1], b[end_b - 1])) {
        end_a -= 1;
        end_b -= 1;
    }
    for (0..start) |i| try out.append(alloc, .{ .op = .same, .number = i + 1, .text = a[i] });

    const ma = a[start..end_a];
    const mb = b[start..end_b];
    if (ma.len * mb.len <= max_cells and ma.len > 0 and mb.len > 0) {
        // lcs[i][j]: the longest common subsequence of ma[i..] and mb[j..].
        const w = mb.len + 1;
        const lcs = try alloc.alloc(u32, (ma.len + 1) * w);
        defer alloc.free(lcs);
        @memset(lcs, 0);
        var i = ma.len;
        while (i > 0) {
            i -= 1;
            var j = mb.len;
            while (j > 0) {
                j -= 1;
                lcs[i * w + j] = if (std.mem.eql(u8, ma[i], mb[j]))
                    lcs[(i + 1) * w + j + 1] + 1
                else
                    @max(lcs[(i + 1) * w + j], lcs[i * w + j + 1]);
            }
        }
        i = 0;
        var j: usize = 0;
        while (i < ma.len or j < mb.len) {
            if (i < ma.len and j < mb.len and std.mem.eql(u8, ma[i], mb[j])) {
                try out.append(alloc, .{ .op = .same, .number = start + i + 1, .text = ma[i] });
                i += 1;
                j += 1;
            } else if (j < mb.len and (i == ma.len or lcs[i * w + j + 1] > lcs[(i + 1) * w + j])) {
                // On a tie the old line goes first, as a diff shows a
                // changed line: removed, then added.
                try out.append(alloc, .{ .op = .added, .number = start + j + 1, .text = mb[j] });
                j += 1;
            } else {
                try out.append(alloc, .{ .op = .removed, .number = start + i + 1, .text = ma[i] });
                i += 1;
            }
        }
    } else {
        for (ma, 0..) |l, i| try out.append(alloc, .{ .op = .removed, .number = start + i + 1, .text = l });
        for (mb, 0..) |l, j| try out.append(alloc, .{ .op = .added, .number = start + j + 1, .text = l });
    }
    for (end_a..a.len) |i| try out.append(alloc, .{ .op = .same, .number = i + 1, .text = a[i] });
    return out.toOwnedSlice(alloc);
}

/// The changes of `lines` as Review & Save shows them: each run of changed
/// lines with the line before and after it, a removed line marked `-`, an
/// added one `+`, after its number. Lines end with CR LF (a text box's).
pub fn writeChanges(alloc: Allocator, out: *std.ArrayList(u8), lines: []const Line) !void {
    var shown_to: usize = 0;
    var i: usize = 0;
    while (i < lines.len) {
        if (lines[i].op == .same) {
            i += 1;
            continue;
        }
        var end = i;
        while (end < lines.len and lines[end].op != .same) end += 1;
        const from = if (i > 0 and i - 1 >= shown_to) i - 1 else i;
        if (shown_to > 0 and from > shown_to) try out.appendSlice(alloc, "    ...\r\n");
        const to = @min(lines.len, end + 1);
        for (lines[from..to]) |l| {
            const mark: []const u8 = switch (l.op) {
                .same => " ",
                .removed => "-",
                .added => "+",
            };
            try out.print(alloc, "{d:>5} {s} {s}\r\n", .{ l.number, mark, l.text });
        }
        shown_to = to;
        i = end;
    }
}

/// How many options `lines` change: the distinct keys of the lines removed
/// or added (a comment or blank line counts for none).
pub fn changedKeys(alloc: Allocator, lines: []const Line, seen: *std.StringHashMapUnmanaged(void)) !void {
    for (lines) |l| {
        if (l.op == .same) continue;
        const e = EditableFile.entry(l.text) orelse continue;
        try seen.put(alloc, e.key, {});
    }
}

const testing = std.testing;

fn expectOps(lines: []const Line, want: []const struct { Op, usize, []const u8 }) !void {
    try testing.expectEqual(want.len, lines.len);
    for (lines, want) |l, w| {
        try testing.expectEqual(w[0], l.op);
        try testing.expectEqual(w[1], l.number);
        try testing.expectEqualStrings(w[2], l.text);
    }
}

test "diff: a changed line, one added, one removed" {
    const old = "a = 1\r\nb = 2\nc = 3\n";
    const new = "a = 1\nb = 5\nd = 4\n";
    const lines = try diff(testing.allocator, old, new);
    defer testing.allocator.free(lines);
    try expectOps(lines, &.{
        .{ .same, 1, "a = 1" },
        .{ .removed, 2, "b = 2" },
        .{ .removed, 3, "c = 3" },
        .{ .added, 2, "b = 5" },
        .{ .added, 3, "d = 4" },
    });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try writeChanges(testing.allocator, &out, lines);
    try testing.expectEqualStrings(
        "    1   a = 1\r\n    2 - b = 2\r\n    3 - c = 3\r\n    2 + b = 5\r\n    3 + d = 4\r\n",
        out.items,
    );

    var keys: std.StringHashMapUnmanaged(void) = .empty;
    defer keys.deinit(testing.allocator);
    try changedKeys(testing.allocator, lines, &keys);
    try testing.expectEqual(3, keys.count());
}

test "diff: unchanged lines between changes, and a text with no end" {
    const old = "# mine\nx = 1\ny = 2\nz = 3\nw = 4\n";
    const new = "# mine\nx = 9\ny = 2\nz = 3\nw = 4\nv = 5";
    const lines = try diff(testing.allocator, old, new);
    defer testing.allocator.free(lines);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try writeChanges(testing.allocator, &out, lines);
    try testing.expectEqualStrings(
        "    1   # mine\r\n    2 - x = 1\r\n    2 + x = 9\r\n    3   y = 2\r\n    ...\r\n    5   w = 4\r\n    6 + v = 5\r\n",
        out.items,
    );
    var none: std.ArrayList(u8) = .empty;
    defer none.deinit(testing.allocator);
    const same = try diff(testing.allocator, old, old);
    defer testing.allocator.free(same);
    try writeChanges(testing.allocator, &none, same);
    try testing.expectEqual(0, none.items.len);
}
