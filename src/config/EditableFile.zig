//! A configuration file held as its lines, so the config editor (roadmap
//! F1) can change it in place. Only the lines of the keys that change are
//! rewritten. Comments, blank lines, the order of entries, repeated keys,
//! includes, a byte order mark and each line's own line ending are kept
//! byte for byte, so a file saved without changes is identical.
//!
//! Lines are read the way the loader reads them (`cli.args.LineIterator`):
//! trimmed of spaces, tabs and carriage returns, a `#` comment only at the
//! start of a line, `key = value` split at the first `=`, and a value's
//! outer double quotes removed. A file with a line the loader can't read
//! (longer than its buffer, where it stops reading the file) is refused,
//! and no edit writes one.
//!
//! Keys are matched as written: an old spelling the loader still takes
//! (`Config.compatibility`, such as `scrollback-limit`) is another key
//! here, which the editor maps.
const EditableFile = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const LineIterator = @import("../cli/args.zig").LineIterator;
const whitespace = @import("../cli/args.zig").whitespace;

/// The longest line the loader reads: its buffer holds the line with any
/// carriage return, after the two bytes of its "--" prefix.
pub const max_line = LineIterator.MAX_LINE_SIZE - 2;

const bom_bytes = "\xEF\xBB\xBF";

pub const Error = error{
    /// A line is longer than the loader reads (`max_line`).
    LineTooLong,

    /// A value holds a line break, which a line can't.
    LineBreakInValue,
} || Allocator.Error;

pub const Ending = enum {
    none,
    lf,
    crlf,

    fn bytes(self: Ending) []const u8 {
        return switch (self) {
            .none => "",
            .lf => "\n",
            .crlf => "\r\n",
        };
    }
};

pub const Line = struct {
    /// The line's bytes, without its ending.
    text: []u8,
    ending: Ending,
};

/// A line's key and value as the loader reads them. The value is null for
/// a key with no `=` (true for a boolean).
pub const Entry = struct {
    key: []const u8,
    value: ?[]const u8,
};

alloc: Allocator,
lines: std.ArrayList(Line) = .empty,
bom: bool = false,

/// Read a file's text. The lines are copies, so `text` can go.
pub fn parse(alloc: Allocator, text: []const u8) Error!EditableFile {
    var self: EditableFile = .{ .alloc = alloc };
    errdefer self.deinit();

    var rest = text;
    if (std.mem.startsWith(u8, rest, bom_bytes)) {
        self.bom = true;
        rest = rest[bom_bytes.len..];
    }

    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const raw = rest[0 .. nl orelse rest.len];
        rest = if (nl) |i| rest[i + 1 ..] else rest[rest.len..];
        if (raw.len > max_line) return error.LineTooLong;

        const crlf = nl != null and raw.len > 0 and raw[raw.len - 1] == '\r';
        const body = if (crlf) raw[0 .. raw.len - 1] else raw;
        const owned = try alloc.dupe(u8, body);
        errdefer alloc.free(owned);
        try self.lines.append(alloc, .{
            .text = owned,
            .ending = if (nl == null) .none else if (crlf) .crlf else .lf,
        });
    }

    return self;
}

pub fn deinit(self: *EditableFile) void {
    for (self.lines.items) |line| self.alloc.free(line.text);
    self.lines.deinit(self.alloc);
    self.* = undefined;
}

/// Write the file's text.
pub fn write(self: *const EditableFile, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (self.bom) try writer.writeAll(bom_bytes);
    for (self.lines.items) |line| {
        try writer.writeAll(line.text);
        try writer.writeAll(line.ending.bytes());
    }
}

/// The file's text, owned by the caller.
pub fn toOwnedText(self: *const EditableFile, alloc: Allocator) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    self.write(&out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// A line's entry as the loader reads it, or null for a blank line or a
/// comment.
pub fn entry(text: []const u8) ?Entry {
    const line = std.mem.trim(u8, text, whitespace ++ "\r");
    if (line.len == 0 or line[0] == '#') return null;

    const eq = std.mem.indexOfScalar(u8, line, '=') orelse
        return .{ .key = line, .value = null };
    var value = std.mem.trim(u8, line[eq + 1 ..], whitespace);
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        value = value[1 .. value.len - 1];
    }
    return .{
        .key = std.mem.trim(u8, line[0..eq], whitespace),
        .value = value,
    };
}

/// The values `key` is given in this file, in order. They point into the
/// file's lines, so they last until the next change.
pub fn values(
    self: *const EditableFile,
    alloc: Allocator,
    key: []const u8,
) Allocator.Error![]?[]const u8 {
    var out: std.ArrayList(?[]const u8) = .empty;
    errdefer out.deinit(alloc);
    for (self.lines.items) |line| {
        const e = entry(line.text) orelse continue;
        if (std.mem.eql(u8, e.key, key)) try out.append(alloc, e.value);
    }
    return out.toOwnedSlice(alloc);
}

/// Whether this file gives `key` a value.
pub fn has(self: *const EditableFile, key: []const u8) bool {
    return self.lastIndex(key) != null;
}

/// Give a single-valued option `value` (null for a bare key). The last line
/// that sets it changes, as the loader takes the last; earlier ones stay.
/// The value must be whole, as `option_list.values` formats it: a type
/// parsed field by field (`mouse-scroll-multiplier`) starts from the value
/// the lines before gave it, so a partial value would keep theirs. A key
/// the file lacks is added at its end.
pub fn set(self: *EditableFile, key: []const u8, value: ?[]const u8) Error!void {
    if (self.lastIndex(key)) |i| {
        const line = &self.lines.items[i];
        const text = try formatLine(self.alloc, indentOf(line.text), key, value, line.ending);
        self.alloc.free(line.text);
        line.text = text;
        return;
    }
    try self.insertLine(self.lines.items.len, key, value);
}

/// Give a repeatable option exactly `new` as this file's lines for it (an
/// empty string resets the list, as in the file). Lines whose values stay
/// (the longest run kept in order) aren't touched, those dropped go, and
/// new ones are added beside their neighbors: before the next kept line,
/// after the last, or where the first dropped one was.
pub fn setList(self: *EditableFile, key: []const u8, new: []const ?[]const u8) Error!void {
    const alloc = self.alloc;

    // The lines that set the key, and their values.
    var at: std.ArrayList(usize) = .empty;
    defer at.deinit(alloc);
    for (self.lines.items, 0..) |line, i| {
        const e = entry(line.text) orelse continue;
        if (std.mem.eql(u8, e.key, key)) try at.append(alloc, i);
    }
    const old = try alloc.alloc(?[]const u8, at.items.len);
    defer alloc.free(old);
    for (at.items, old) |i, *v| v.* = entry(self.lines.items[i].text).?.value;

    // Which old value each kept one is: the longest common subsequence.
    const keep = try alloc.alloc(?usize, old.len);
    defer alloc.free(keep);
    try commonSubsequence(alloc, old, new, keep);
    const kept_new = try alloc.alloc(bool, new.len);
    defer alloc.free(kept_new);
    @memset(kept_new, false);
    for (keep) |kept| {
        if (kept) |j| kept_new[j] = true;
    }

    // The new lines first, so a failure changes nothing; kept ones keep
    // their own text. Each one moved into the file is left empty here, so
    // the cleanup frees only the rest.
    const ending = self.newLineEnding();
    try self.checkEndingFits(ending);
    const made = try alloc.alloc([]u8, new.len);
    var made_count: usize = 0;
    defer {
        for (made[0..made_count]) |t| alloc.free(t);
        alloc.free(made);
    }
    for (new, kept_new) |v, kept| {
        made[made_count] = if (kept) &.{} else try formatLine(alloc, "", key, v, ending);
        made_count += 1;
    }

    var out: std.ArrayList(Line) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, self.lines.items.len + new.len);
    var next_new: usize = 0;
    var anchor: ?usize = null;
    var dropped: std.ArrayList([]u8) = .empty;
    defer dropped.deinit(alloc);
    try dropped.ensureTotalCapacity(alloc, at.items.len);
    var k: usize = 0;
    for (self.lines.items, 0..) |line, i| {
        if (k < at.items.len and at.items[k] == i) {
            defer k += 1;
            if (keep[k]) |j| {
                // New values before this kept one go ahead of it.
                while (next_new < j) : (next_new += 1) {
                    if (kept_new[next_new]) continue;
                    out.appendAssumeCapacity(.{ .text = made[next_new], .ending = ending });
                    made[next_new] = made[next_new][0..0];
                }
                next_new = j + 1;
                out.appendAssumeCapacity(line);
                anchor = out.items.len;
            } else {
                dropped.appendAssumeCapacity(line.text);
                if (anchor == null) anchor = out.items.len;
            }
            continue;
        }
        out.appendAssumeCapacity(line);
    }

    // The rest after the last kept line, else where the first dropped one
    // was, else at the end.
    var insert_at = anchor orelse out.items.len;
    if (insert_at == out.items.len and insert_at > 0 and next_new < new.len) {
        const last = &out.items[insert_at - 1];
        if (last.ending == .none) last.ending = ending;
    }
    while (next_new < new.len) : (next_new += 1) {
        if (kept_new[next_new]) continue;
        out.insertAssumeCapacity(insert_at, .{ .text = made[next_new], .ending = ending });
        made[next_new] = made[next_new][0..0];
        insert_at += 1;
    }

    // Nothing can fail from here.
    for (dropped.items) |t| alloc.free(t);
    self.lines.deinit(alloc);
    self.lines = out;
}

/// Remove every line that sets `key`, so the option takes what an included
/// file or its default gives.
pub fn remove(self: *EditableFile, key: []const u8) void {
    var i: usize = 0;
    while (i < self.lines.items.len) {
        const line = self.lines.items[i];
        const e = entry(line.text) orelse {
            i += 1;
            continue;
        };
        if (!std.mem.eql(u8, e.key, key)) {
            i += 1;
            continue;
        }
        self.alloc.free(line.text);
        _ = self.lines.orderedRemove(i);
    }
}

fn lastIndex(self: *const EditableFile, key: []const u8) ?usize {
    var i = self.lines.items.len;
    while (i > 0) {
        i -= 1;
        const e = entry(self.lines.items[i].text) orelse continue;
        if (std.mem.eql(u8, e.key, key)) return i;
    }
    return null;
}

/// Add a line for `key` before line `index` (the end for the line count).
fn insertLine(self: *EditableFile, index: usize, key: []const u8, value: ?[]const u8) Error!void {
    const ending = self.newLineEnding();
    try self.checkEndingFits(ending);
    const text = try formatLine(self.alloc, "", key, value, ending);
    errdefer self.alloc.free(text);
    try self.lines.ensureUnusedCapacity(self.alloc, 1);
    if (index == self.lines.items.len and index > 0) {
        const last = &self.lines.items[index - 1];
        if (last.ending == .none) last.ending = ending;
    }
    self.lines.insertAssumeCapacity(index, .{ .text = text, .ending = ending });
}

/// Whether the last line, if it has no ending, can take `ending` (an
/// addition at the end gives it one) and still be read whole.
fn checkEndingFits(self: *const EditableFile, ending: Ending) Error!void {
    const last = self.lines.getLastOrNull() orelse return;
    if (last.ending == .none and !fits(last.text, ending)) return error.LineTooLong;
}

/// Whether the loader reads `text` with `ending` whole: its buffer holds a
/// line's carriage return too.
fn fits(text: []const u8, ending: Ending) bool {
    return text.len + @as(usize, if (ending == .crlf) 1 else 0) <= max_line;
}

/// The ending new lines get: the first line's that has one, else a line
/// feed.
fn newLineEnding(self: *const EditableFile) Ending {
    for (self.lines.items) |line| if (line.ending != .none) return line.ending;
    return .lf;
}

fn indentOf(text: []const u8) []const u8 {
    var n: usize = 0;
    while (n < text.len and (text[n] == ' ' or text[n] == '\t')) n += 1;
    return text[0..n];
}

/// `key = value` as a line, quoted when the loader would otherwise change
/// the value: surrounding spaces or tabs, or quotes of its own at both
/// ends (the loader removes one pair).
fn formatLine(
    alloc: Allocator,
    indent: []const u8,
    key: []const u8,
    value: ?[]const u8,
    ending: Ending,
) Error![]u8 {
    const v = value orelse {
        const text = try std.mem.concat(alloc, u8, &.{ indent, key });
        if (!fits(text, ending)) {
            alloc.free(text);
            return error.LineTooLong;
        }
        return text;
    };
    if (std.mem.indexOfAny(u8, v, "\r\n") != null) return error.LineBreakInValue;
    const quote = v.len > 0 and (std.mem.indexOfScalar(u8, whitespace, v[0]) != null or
        std.mem.indexOfScalar(u8, whitespace, v[v.len - 1]) != null or
        (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"'));
    const q: []const u8 = if (quote) "\"" else "";
    const sep: []const u8 = if (v.len == 0) " =" else " = ";
    const text = try std.mem.concat(alloc, u8, &.{ indent, key, sep, q, v, q });
    if (!fits(text, ending)) {
        alloc.free(text);
        return error.LineTooLong;
    }
    return text;
}

/// Fill `keep[i]` with the index in `b` that `a[i]` stays as, along the
/// longest common subsequence of the two, else null.
fn commonSubsequence(
    alloc: Allocator,
    a: []const ?[]const u8,
    b: []const ?[]const u8,
    keep: []?usize,
) Allocator.Error!void {
    @memset(keep, null);
    const w = b.len + 1;
    const table = try alloc.alloc(u32, (a.len + 1) * w);
    defer alloc.free(table);
    @memset(table, 0);
    var i = a.len;
    while (i > 0) {
        i -= 1;
        var j = b.len;
        while (j > 0) {
            j -= 1;
            table[i * w + j] = if (sameValue(a[i], b[j]))
                table[(i + 1) * w + j + 1] + 1
            else
                @max(table[(i + 1) * w + j], table[i * w + j + 1]);
        }
    }
    var x: usize = 0;
    var y: usize = 0;
    while (x < a.len and y < b.len) {
        if (sameValue(a[x], b[y])) {
            keep[x] = y;
            x += 1;
            y += 1;
        } else if (table[(x + 1) * w + y] >= table[x * w + y + 1]) {
            x += 1;
        } else {
            y += 1;
        }
    }
}

fn sameValue(a: ?[]const u8, b: ?[]const u8) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    return std.mem.eql(u8, x, y);
}

const testing = std.testing;

fn expectText(file: *const EditableFile, expected: []const u8) !void {
    const text = try file.toOwnedText(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(expected, text);
}

/// The loader's reading of `text`, as "--key=value" arguments joined by
/// newlines.
fn loaderReads(text: []const u8) ![]u8 {
    var body = text;
    if (std.mem.startsWith(u8, body, bom_bytes)) body = body[bom_bytes.len..];
    var reader: std.Io.Reader = .fixed(body);
    var iter: LineIterator = .init(&reader);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    while (iter.next()) |arg| {
        try out.writer.writeAll(arg);
        try out.writer.writeByte('\n');
    }
    return out.toOwnedSlice();
}

fn expectLoaderReads(file: *const EditableFile, expected: []const u8) !void {
    const text = try file.toOwnedText(testing.allocator);
    defer testing.allocator.free(text);
    const read = try loaderReads(text);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings(expected, read);
}

test "EditableFile: saving without changes keeps every byte" {
    const cases = [_][]const u8{
        "",
        "\n",
        "a = 1",
        "a = 1\n",
        "\xEF\xBB\xBF# with a BOM\r\nfont-size = 13\r\n",
        "# mixed\r\nkeybind = ctrl+a=copy\n\n  indented=  x  \r\nlast-line-no-newline = \"q\"",
        "\t# tab comment\n\n\n=\nbare-key\n",
    };
    for (cases) |text| {
        var file = try parse(testing.allocator, text);
        defer file.deinit();
        try expectText(&file, text);
    }
}

test "EditableFile: a line the loader can't read is refused" {
    const long = try testing.allocator.alloc(u8, max_line + 1);
    defer testing.allocator.free(long);
    @memset(long, 'a');
    try testing.expectError(error.LineTooLong, parse(testing.allocator, long));

    // A line of the most the loader takes is fine, carriage return included.
    @memset(long[max_line - 1 ..], '\r');
    const longest = try std.mem.concat(testing.allocator, u8, &.{ long[0..max_line], "\n" });
    defer testing.allocator.free(longest);
    var file = try parse(testing.allocator, longest);
    file.deinit();
}

test "EditableFile: entries read as the loader reads them" {
    const text =
        \\# comment = no
        \\  font-family =  "  Fira Code  "
        \\theme=dark:x,light:y
        \\window-decoration
        \\title = has # no comment
        \\empty =
        \\quoted = "a"b"
    ;
    var file = try parse(testing.allocator, text);
    defer file.deinit();

    const ff = try file.values(testing.allocator, "font-family");
    defer testing.allocator.free(ff);
    try testing.expectEqual(1, ff.len);
    try testing.expectEqualStrings("  Fira Code  ", ff[0].?);

    const wd = try file.values(testing.allocator, "window-decoration");
    defer testing.allocator.free(wd);
    try testing.expectEqual(@as(?[]const u8, null), wd[0]);

    try expectLoaderReads(&file, "--font-family=  Fira Code  \n" ++
        "--theme=dark:x,light:y\n" ++
        "--window-decoration\n" ++
        "--title=has # no comment\n" ++
        "--empty=\n" ++
        "--quoted=a\"b\n");
    try testing.expect(file.has("theme"));
    try testing.expect(!file.has("comment"));
}

test "EditableFile: set changes the last line for the key, nothing else" {
    var file = try parse(testing.allocator,
        \\font-size = 12
        \\# keep me
        \\  font-size=14
        \\background = #000000
        \\
    );
    defer file.deinit();
    try file.set("font-size", "16");
    try expectText(&file,
        \\font-size = 12
        \\# keep me
        \\  font-size = 16
        \\background = #000000
        \\
    );
}

test "EditableFile: set adds a missing key at the end, with the file's line ending" {
    {
        var file = try parse(testing.allocator, "a = 1\r\nb = 2");
        defer file.deinit();
        try file.set("c", "3");
        try expectText(&file, "a = 1\r\nb = 2\r\nc = 3\r\n");
    }
    {
        var file = try parse(testing.allocator, "");
        defer file.deinit();
        try file.set("font-size", "13");
        try file.set("window-decoration", null);
        try expectText(&file, "font-size = 13\nwindow-decoration\n");
    }
}

test "EditableFile: values the loader would change are quoted" {
    var file = try parse(testing.allocator, "");
    defer file.deinit();
    try file.set("a", " padded ");
    try file.set("b", "\"quoted\"");
    try file.set("c", "");
    try file.set("d", "plain \"inner\" text");
    try expectText(&file,
        \\a = " padded "
        \\b = ""quoted""
        \\c =
        \\d = plain "inner" text
        \\
    );
    try expectLoaderReads(&file, "--a= padded \n" ++
        "--b=\"quoted\"\n" ++
        "--c=\n" ++
        "--d=plain \"inner\" text\n");
    try testing.expectError(error.LineBreakInValue, file.set("e", "two\nlines"));
}

test "EditableFile: setList keeps the lines that stay" {
    const text =
        \\keybind = ctrl+a=copy
        \\# paste
        \\keybind = ctrl+b=paste
        \\font-size = 12
        \\keybind = ctrl+c=quit
        \\
    ;

    // Remove the middle one: its comment and the rest stay put.
    {
        var file = try parse(testing.allocator, text);
        defer file.deinit();
        try file.setList("keybind", &.{ "ctrl+a=copy", "ctrl+c=quit" });
        try expectText(&file,
            \\keybind = ctrl+a=copy
            \\# paste
            \\font-size = 12
            \\keybind = ctrl+c=quit
            \\
        );
    }

    // Add one between two kept, and one at the end.
    {
        var file = try parse(testing.allocator, text);
        defer file.deinit();
        try file.setList("keybind", &.{ "ctrl+a=copy", "ctrl+b=paste", "ctrl+d=new_tab", "ctrl+c=quit", "ctrl+e=new_window" });
        try expectText(&file,
            \\keybind = ctrl+a=copy
            \\# paste
            \\keybind = ctrl+b=paste
            \\font-size = 12
            \\keybind = ctrl+d=new_tab
            \\keybind = ctrl+c=quit
            \\keybind = ctrl+e=new_window
            \\
        );
    }

    // Replace them all: the new ones go where the first old one was.
    {
        var file = try parse(testing.allocator, text);
        defer file.deinit();
        try file.setList("keybind", &.{ "", "ctrl+x=copy" });
        try expectText(&file,
            \\keybind =
            \\keybind = ctrl+x=copy
            \\# paste
            \\font-size = 12
            \\
        );
    }

    // Unchanged: identical.
    {
        var file = try parse(testing.allocator, text);
        defer file.deinit();
        try file.setList("keybind", &.{ "ctrl+a=copy", "ctrl+b=paste", "ctrl+c=quit" });
        try expectText(&file, text);
    }

    // None in the file yet: added at the end, after a line with no ending.
    {
        var file = try parse(testing.allocator, "font-size = 12");
        defer file.deinit();
        try file.setList("palette", &.{ "0=#000000", "1=#ff0000" });
        try expectText(&file, "font-size = 12\npalette = 0=#000000\npalette = 1=#ff0000\n");
        try expectLoaderReads(&file, "--font-size=12\n--palette=0=#000000\n--palette=1=#ff0000\n");
    }

    // Emptied: every line goes.
    {
        var file = try parse(testing.allocator, text);
        defer file.deinit();
        try file.setList("keybind", &.{});
        try expectText(&file, "# paste\nfont-size = 12\n");
    }
}

test "EditableFile: no edit writes a line the loader can't read" {
    const alloc = testing.allocator;
    // "b = " and 4,090 bytes: 4,094 with a line feed, 4,095 with a CRLF.
    const long = try alloc.alloc(u8, max_line - 4);
    defer alloc.free(long);
    @memset(long, 'x');
    {
        var file = try parse(alloc, "a = 1\n");
        defer file.deinit();
        try file.set("b", long);
    }
    {
        var file = try parse(alloc, "a = 1\r\n");
        defer file.deinit();
        try testing.expectError(error.LineTooLong, file.set("b", long));
        try testing.expectError(error.LineTooLong, file.setList("b", &.{long}));
        try expectText(&file, "a = 1\r\n");
    }

    // A kept line isn't written again, so it isn't measured again: "k=" and
    // 4,092 bytes read whole, but "k = " and the same 4,092 wouldn't.
    const wide = try alloc.alloc(u8, max_line - 2);
    defer alloc.free(wide);
    @memset(wide, 'x');
    const compact = try std.mem.concat(alloc, u8, &.{ "k=", wide });
    defer alloc.free(compact);
    const text = try std.mem.concat(alloc, u8, &.{ compact, "\n" });
    defer alloc.free(text);
    var file = try parse(alloc, text);
    defer file.deinit();
    try file.setList("k", &.{ wide, "y" });
    const out = try file.toOwnedText(alloc);
    defer alloc.free(out);
    try testing.expect(std.mem.startsWith(u8, out, compact));
}

test "EditableFile: remove drops every line for the key" {
    var file = try parse(testing.allocator, "a = 1\nb = 2\n# a\n a=3\n");
    defer file.deinit();
    file.remove("a");
    try expectText(&file, "b = 2\n# a\n");
    try testing.expect(!file.has("a"));
}
