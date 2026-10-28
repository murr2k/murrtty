//! The terminal's text as UI Automation reads it (roadmap 6.4): positions,
//! text units and text over the core's screen, apart from the COM objects
//! (Uia.zig), so it can be tested on a terminal of its own.
//!
//! A position is a cell of the screen, scrollback included: row `y` from
//! the scrollback's top and column `x`. A range runs from its start up to
//! (not including) its end. Rows are UI Automation's lines, a soft-wrapped
//! line being several as on screen, and paragraphs too; a character is a
//! cell, but for the cell a wide character spills into; a word starts at
//! text after a blank (or at a row's start, unless the row before wraps
//! into it with text); a page is the viewport's height. The document runs
//! to the end of the last row with text or the cursor.
//!
//! Positions count rows from the scrollback's top, so they shift when the
//! scrollback is full and its oldest rows go, as Windows Terminal's do.
const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("../../terminal/main.zig");

const Screen = terminal.Screen;
const Pin = terminal.Pin;
const Cell = terminal.page.Cell;

pub const Pos = struct {
    y: u32 = 0,
    x: u16 = 0,

    pub fn order(a: Pos, b: Pos) std.math.Order {
        if (a.y != b.y) return std.math.order(a.y, b.y);
        return std.math.order(a.x, b.x);
    }

    pub fn lessThan(a: Pos, b: Pos) bool {
        return a.order(b) == .lt;
    }

    pub fn eql(a: Pos, b: Pos) bool {
        return a.y == b.y and a.x == b.x;
    }

    pub fn min(a: Pos, b: Pos) Pos {
        return if (a.lessThan(b)) a else b;
    }

    pub fn max(a: Pos, b: Pos) Pos {
        return if (a.lessThan(b)) b else a;
    }
};

/// TextUnit.
pub const Unit = enum(c_int) {
    character = 0,
    format = 1,
    word = 2,
    line = 3,
    paragraph = 4,
    page = 5,
    document = 6,
    _,

    /// The unit used for this one: an unknown or unsupported unit goes to
    /// the next larger one that is (Format to Word, Paragraph is Line).
    pub fn used(self: Unit) Unit {
        return switch (self) {
            .character => .character,
            .format, .word => .word,
            .line, .paragraph => .line,
            .page => .page,
            else => .document,
        };
    }
};

/// A character of the text and where it is, for mapping found text back
/// to positions.
pub const Mark = struct { offset: u32, pos: Pos };

/// The screen as one call sees it, taken with the terminal's lock held,
/// which every use needs too.
pub const View = struct {
    screen: *const Screen,
    cols: u16,
    /// Rows in the screen, scrollback included.
    total: u32,
    viewport_top: u32,
    /// The viewport's rows.
    rows: u16,
    cursor: Pos,
    /// The document's end: the start of the row after the last one with
    /// text or the cursor.
    end: Pos,
    /// The row looked up last, for its neighbors: a pin from the
    /// scrollback's top walks every page before it.
    cache_y: u32 = std.math.maxInt(u32),
    cache_pin: ?Pin = null,

    pub fn init(screen: *const Screen) View {
        const pages = &screen.pages;
        const total: u32 = @intCast(pages.total_rows);
        const viewport_top: u32 = if (pages.pointFromPin(.screen, pages.getTopLeft(.viewport))) |p| p.screen.y else 0;
        const cursor_y: u32 = if (pages.pointFromPin(.screen, screen.cursor.page_pin.*)) |p| p.screen.y else 0;
        var view: View = .{
            .screen = screen,
            .cols = @intCast(pages.cols),
            .total = total,
            .viewport_top = viewport_top,
            .rows = @intCast(pages.rows),
            .cursor = .{ .y = cursor_y, .x = @intCast(screen.cursor.x) },
            .end = .{},
        };
        var last = cursor_y;
        var y = total;
        while (y > cursor_y + 1) {
            y -= 1;
            const cells = view.rowCells(y) orelse continue;
            if (Cell.hasTextAny(cells)) {
                last = y;
                break;
            }
        }
        view.end = .{ .y = @min(total, last + 1), .x = 0 };
        return view;
    }

    /// The pin of row `y`'s first cell.
    fn rowPin(self: *View, y: u32) ?Pin {
        if (y >= self.total) return null;
        if (self.cache_pin) |p| {
            if (y == self.cache_y) return p;
            const near: ?Pin = if (y == self.cache_y +| 1) p.down(1) else if (y + 1 == self.cache_y) p.up(1) else null;
            if (near) |n| {
                self.cache_y = y;
                self.cache_pin = n;
                return n;
            }
        }
        const found = self.screen.pages.pin(.{ .screen = .{ .x = 0, .y = y } }) orelse return null;
        self.cache_y = y;
        self.cache_pin = found;
        return found;
    }

    fn rowCells(self: *View, y: u32) ?[]const Cell {
        const p = self.rowPin(y) orelse return null;
        return p.cells(.all);
    }

    /// Whether row `y` soft-wraps into the next.
    fn wraps(self: *View, y: u32) bool {
        const p = self.rowPin(y) orelse return false;
        return p.rowAndCell().row.wrap;
    }

    pub fn pin(self: *View, pos: Pos) ?Pin {
        if (pos.y >= self.total or pos.x >= self.cols) return null;
        var p = self.rowPin(pos.y) orelse return null;
        if (pos.x >= p.node.cols()) return null;
        p.x = pos.x;
        return p;
    }

    pub fn posOf(self: *View, p: Pin) ?Pos {
        const pt = self.screen.pages.pointFromPin(.screen, p) orelse return null;
        return .{ .y = @intCast(pt.screen.y), .x = @intCast(pt.screen.x) };
    }

    /// `pos` kept within the document.
    pub fn clamp(self: *View, pos: Pos) Pos {
        if (!pos.lessThan(self.end)) return self.end;
        return .{ .y = pos.y, .x = @min(pos.x, self.cols -| 1) };
    }

    fn cellAt(self: *View, pos: Pos) ?Cell {
        const cells = self.rowCells(pos.y) orelse return null;
        if (pos.x >= cells.len) return null;
        return cells[pos.x];
    }

    /// Whether a character starts at `pos` (not a wide character's second
    /// cell, or the blank a wide character left at a wrapped row's end).
    fn isCharStart(self: *View, pos: Pos) bool {
        const cell = self.cellAt(pos) orelse return true;
        return switch (cell.wide) {
            .spacer_tail, .spacer_head => false,
            else => true,
        };
    }

    fn isBlank(self: *View, pos: Pos) bool {
        const cell = self.cellAt(pos) orelse return true;
        if (!cell.hasText()) return true;
        const cp = cell.codepoint();
        return cp == ' ' or cp == '\t';
    }

    /// The next character's start after `pos`; the document's end at most.
    pub fn nextChar(self: *View, pos: Pos) Pos {
        var p = pos;
        while (true) {
            if (!p.lessThan(self.end)) return self.end;
            p = if (p.x + 1 < self.cols) .{ .y = p.y, .x = p.x + 1 } else .{ .y = p.y + 1, .x = 0 };
            if (!p.lessThan(self.end)) return self.end;
            if (self.isCharStart(p)) return p;
        }
    }

    /// The character's start before `pos`; the document's start at least.
    pub fn prevChar(self: *View, pos: Pos) Pos {
        var p = self.clamp(pos);
        while (true) {
            if (p.y == 0 and p.x == 0) return p;
            p = if (p.x > 0) .{ .y = p.y, .x = p.x - 1 } else .{ .y = p.y - 1, .x = self.cols - 1 };
            if (self.isCharStart(p)) return p;
        }
    }

    /// The start of the character holding `pos`.
    fn charStart(self: *View, pos: Pos) Pos {
        var p = self.clamp(pos);
        while (!self.isCharStart(p) and p.x > 0) p.x -= 1;
        return p;
    }

    fn isWordStart(self: *View, pos: Pos) bool {
        if (self.isBlank(pos) or !self.isCharStart(pos)) return false;
        if (pos.x > 0) return self.isBlank(self.prevChar(pos));
        // A row's start: a word, unless the row before runs into it.
        if (pos.y == 0 or !self.wraps(pos.y - 1)) return true;
        return self.isBlank(self.prevChar(pos));
    }

    /// The start of the unit holding `pos`.
    pub fn unitStart(self: *View, unit: Unit, pos: Pos) Pos {
        const p = self.clamp(pos);
        return switch (unit.used()) {
            .character => if (p.eql(self.end)) p else self.charStart(p),
            .word => word: {
                var q = if (p.eql(self.end)) self.prevChar(p) else self.charStart(p);
                while (true) {
                    if (self.isWordStart(q)) break :word q;
                    if (q.y == 0 and q.x == 0) break :word q;
                    q = self.prevChar(q);
                }
            },
            .line => .{ .y = if (p.eql(self.end) and p.y > 0) p.y - 1 else p.y, .x = 0 },
            .page => page: {
                const rows: i64 = @max(1, self.rows);
                const rel = @as(i64, p.y) - @as(i64, self.viewport_top);
                const start = @as(i64, self.viewport_top) + @divFloor(rel, rows) * rows;
                break :page .{ .y = @intCast(@max(0, start)), .x = 0 };
            },
            else => .{},
        };
    }

    /// The start of the unit after the one holding `pos`; the document's
    /// end at most.
    pub fn unitNext(self: *View, unit: Unit, pos: Pos) Pos {
        const p = self.clamp(pos);
        if (p.eql(self.end)) return p;
        return switch (unit.used()) {
            .character => self.nextChar(self.charStart(p)),
            .word => word: {
                var q = self.nextChar(self.charStart(p));
                while (q.lessThan(self.end)) : (q = self.nextChar(q)) {
                    if (self.isWordStart(q)) break :word q;
                }
                break :word self.end;
            },
            .line => self.clamp(.{ .y = p.y + 1, .x = 0 }),
            .page => self.clamp(.{ .y = self.unitStart(.page, p).y + @max(1, self.rows), .x = 0 }),
            else => self.end,
        };
    }

    /// `pos` moved by `count` units (to unit starts), as far as the
    /// document goes; and the units actually moved. `to_end`: a move may
    /// end at the document's end (an endpoint may; a whole range moved
    /// there would hold no unit, so it stops at the last).
    pub fn move(self: *View, unit: Unit, pos: Pos, count: i32, to_end: bool) struct { pos: Pos, moved: i32 } {
        var p = self.clamp(pos);
        var moved: i32 = 0;
        if (count > 0) {
            while (moved < count) : (moved += 1) {
                const next = self.unitNext(unit, p);
                if (next.eql(p)) break;
                if (!to_end and next.eql(self.end)) break;
                p = next;
            }
        } else if (count < 0) {
            while (moved > count) : (moved -= 1) {
                var start = self.unitStart(unit, p);
                if (start.eql(p)) {
                    if (p.y == 0 and p.x == 0) break;
                    start = self.unitStart(unit, self.prevChar(p));
                }
                p = start;
            }
        }
        return .{ .pos = p, .moved = moved };
    }

    /// The text from `start` up to `end`: rows apart by "\r\n", but for a
    /// soft-wrapped row, which runs on; a row's trailing blanks left out
    /// where the range runs past them; a blank cell as a space. `marks`,
    /// when given, gets each character's place in the text and position.
    /// `limit`: at most that many characters.
    pub fn text(self: *View, alloc: Allocator, range_start: Pos, range_end: Pos, marks: ?*std.ArrayList(Mark), limit: ?usize) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        const start = self.clamp(range_start);
        const end = self.clamp(range_end);
        if (!start.lessThan(end)) return out.toOwnedSlice(alloc);
        var row_pin = self.rowPin(start.y) orelse return out.toOwnedSlice(alloc);
        var chars: usize = 0;
        var y = start.y;
        while (y < self.total and (y < end.y or (y == end.y and end.x > 0))) : (y += 1) {
            if (limit) |l| if (chars >= l) break;
            if (y > start.y) row_pin = row_pin.down(1) orelse break;
            const cells = row_pin.cells(.all);
            const wrap = row_pin.rowAndCell().row.wrap;
            const past = y != end.y;
            const x0: usize = if (y == start.y) start.x else 0;
            var x1: usize = if (past) cells.len else @min(end.x, cells.len);
            if (past and !wrap) {
                while (x1 > x0 and !cells[x1 - 1].hasText()) x1 -= 1;
            }
            var x = x0;
            while (x < x1) : (x += 1) {
                const cell = &cells[x];
                switch (cell.wide) {
                    .spacer_tail, .spacer_head => continue,
                    else => {},
                }
                if (limit) |l| if (chars >= l) break;
                chars += 1;
                if (marks) |m| try m.append(alloc, .{ .offset = @intCast(out.items.len), .pos = .{ .y = y, .x = @intCast(x) } });
                const cp: u21 = if (cell.hasText()) cell.codepoint() else ' ';
                try appendCodepoint(alloc, &out, cp);
                if (cell.hasGrapheme()) if (row_pin.grapheme(cell)) |extra| {
                    for (extra) |e| try appendCodepoint(alloc, &out, e);
                };
            }
            if (past and !wrap) try out.appendSlice(alloc, "\r\n");
        }
        return out.toOwnedSlice(alloc);
    }

    /// Where `needle` first (or, `backward`, last) appears in the range:
    /// its start and end. `ignore_case` folds ASCII letters.
    pub fn find(self: *View, alloc: Allocator, start: Pos, end: Pos, needle: []const u8, backward: bool, ignore_case: bool) !?struct { start: Pos, end: Pos } {
        if (needle.len == 0) return null;
        var marks: std.ArrayList(Mark) = .empty;
        defer marks.deinit(alloc);
        const hay = try self.text(alloc, start, end, &marks, null);
        defer alloc.free(hay);
        if (needle.len > hay.len) return null;
        const at: usize = at: {
            var i: usize = if (backward) hay.len - needle.len else 0;
            while (true) {
                const slice = hay[i .. i + needle.len];
                const same = if (ignore_case) std.ascii.eqlIgnoreCase(slice, needle) else std.mem.eql(u8, slice, needle);
                if (same) break :at i;
                if (backward) {
                    if (i == 0) return null;
                    i -= 1;
                } else {
                    i += 1;
                    if (i + needle.len > hay.len) return null;
                }
            }
        };
        // From the first character at or after the match's start to just
        // past its last character (a match can begin or end in a row's
        // "\r\n", which has no position of its own).
        var found_start: ?Pos = null;
        var last: ?Pos = null;
        for (marks.items) |m| {
            if (m.offset >= at + needle.len) break;
            if (found_start == null and m.offset >= at) found_start = m.pos;
            if (m.offset >= at) last = m.pos;
        }
        const first = found_start orelse return null;
        return .{ .start = first, .end = self.nextChar(last.?) };
    }

    /// The range's part on each visible row: column ranges (start column,
    /// end column, exclusive) on viewport rows, a row's trailing blanks
    /// left out where the range runs past them; one empty part for an
    /// empty range in view.
    pub fn visibleParts(self: *View, alloc: Allocator, range_start: Pos, range_end: Pos) ![]Part {
        var parts: std.ArrayList(Part) = .empty;
        errdefer parts.deinit(alloc);
        const start = self.clamp(range_start);
        const end = self.clamp(range_end);
        const bottom = self.viewport_top + self.rows;
        if (start.eql(end)) {
            if (start.y >= self.viewport_top and start.y < bottom) {
                try parts.append(alloc, .{ .row = @intCast(start.y - self.viewport_top), .x0 = start.x, .x1 = start.x });
            }
            return parts.toOwnedSlice(alloc);
        }
        var y = @max(start.y, self.viewport_top);
        while (y < bottom and (y < end.y or (y == end.y and end.x > 0))) : (y += 1) {
            const cells = self.rowCells(y) orelse break;
            const past = y != end.y;
            const x0: u16 = if (y == start.y) start.x else 0;
            var x1: u16 = if (past) @intCast(cells.len) else @min(end.x, @as(u16, @intCast(cells.len)));
            if (past) {
                while (x1 > x0 and !cells[x1 - 1].hasText()) x1 -= 1;
            }
            // A page narrower than the screen (a reflow not finished).
            x1 = @max(x1, x0);
            try parts.append(alloc, .{ .row = @intCast(y - self.viewport_top), .x0 = x0, .x1 = x1 });
        }
        return parts.toOwnedSlice(alloc);
    }

    pub const Part = struct { row: u16, x0: u16, x1: u16 };
};

fn appendCodepoint(alloc: Allocator, out: *std.ArrayList(u8), cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return;
    try out.appendSlice(alloc, buf[0..n]);
}

const testing = std.testing;

fn testTerminal(cols: u16, rows: u16, content: []const u8) !terminal.Terminal {
    var t = try terminal.Terminal.init(testing.io, testing.allocator, .{ .cols = cols, .rows = rows });
    errdefer t.deinit(testing.allocator);
    try t.printString(content);
    return t;
}

test "text and the document" {
    // 10 columns: "hello world" wraps after "worl".
    var t = try testTerminal(10, 5, "hello world\nab cd");
    defer t.deinit(testing.allocator);
    var view = View.init(t.screens.active);
    try testing.expectEqual(Pos{ .y = 3, .x = 0 }, view.end);
    const doc = try view.text(testing.allocator, .{}, view.end, null, null);
    defer testing.allocator.free(doc);
    try testing.expectEqualStrings("hello world\r\nab cd\r\n", doc);
    // Part of a row, then a row's end without its newline.
    const part = try view.text(testing.allocator, .{ .y = 0, .x = 6 }, .{ .y = 1, .x = 1 }, null, null);
    defer testing.allocator.free(part);
    try testing.expectEqualStrings("world", part);
    const empty = try view.text(testing.allocator, .{ .y = 2, .x = 1 }, .{ .y = 2, .x = 1 }, null, null);
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("", empty);
}

test "characters, words and lines" {
    var t = try testTerminal(10, 5, "hello world\nab cd");
    defer t.deinit(testing.allocator);
    var view = View.init(t.screens.active);

    try testing.expectEqual(Pos{ .y = 0, .x = 1 }, view.nextChar(.{}));
    try testing.expectEqual(Pos{ .y = 1, .x = 0 }, view.nextChar(.{ .y = 0, .x = 9 }));
    try testing.expectEqual(Pos{ .y = 0, .x = 9 }, view.prevChar(.{ .y = 1, .x = 0 }));
    try testing.expectEqual(view.end, view.nextChar(view.end));

    // Words: "world" runs on into the next row; "ab", "cd".
    var r = view.move(.word, .{}, 1, true);
    try testing.expectEqual(Pos{ .y = 0, .x = 6 }, r.pos);
    r = view.move(.word, r.pos, 1, true);
    try testing.expectEqual(Pos{ .y = 2, .x = 0 }, r.pos);
    r = view.move(.word, r.pos, 5, true);
    try testing.expectEqual(view.end, r.pos);
    try testing.expectEqual(@as(i32, 2), r.moved);
    // A whole range moved stops at the last word.
    r = view.move(.word, .{ .y = 2, .x = 0 }, 5, false);
    try testing.expectEqual(Pos{ .y = 2, .x = 3 }, r.pos);
    try testing.expectEqual(@as(i32, 1), r.moved);
    r = view.move(.word, view.end, -2, true);
    try testing.expectEqual(Pos{ .y = 2, .x = 0 }, r.pos);
    try testing.expectEqual(@as(i32, -2), r.moved);
    try testing.expectEqual(Pos{ .y = 0, .x = 6 }, view.unitStart(.word, .{ .y = 1, .x = 0 }));
    // Format is taken as Word.
    try testing.expectEqual(Pos{ .y = 2, .x = 3 }, view.unitNext(.format, .{ .y = 2, .x = 0 }));

    // Lines are rows.
    try testing.expectEqual(Pos{ .y = 1, .x = 0 }, view.unitStart(.line, .{ .y = 1, .x = 0 }));
    try testing.expectEqual(Pos{ .y = 2, .x = 0 }, view.unitNext(.paragraph, .{ .y = 1, .x = 0 }));
    r = view.move(.line, .{}, 10, true);
    try testing.expectEqual(view.end, r.pos);
    try testing.expectEqual(@as(i32, 3), r.moved);
    try testing.expectEqual(Pos{}, view.unitStart(.document, .{ .y = 2, .x = 2 }));
    try testing.expectEqual(view.end, view.unitNext(.document, .{}));
}

test "wide characters take one character" {
    var t = try testTerminal(10, 3, "\u{65E5}\u{672C}x");
    defer t.deinit(testing.allocator);
    var view = View.init(t.screens.active);
    try testing.expectEqual(Pos{ .y = 0, .x = 2 }, view.nextChar(.{}));
    try testing.expectEqual(Pos{ .y = 0, .x = 4 }, view.nextChar(.{ .y = 0, .x = 2 }));
    try testing.expectEqual(Pos{ .y = 0, .x = 2 }, view.prevChar(.{ .y = 0, .x = 4 }));
    try testing.expectEqual(Pos{}, view.unitStart(.character, .{ .y = 0, .x = 1 }));
    const all = try view.text(testing.allocator, .{}, view.end, null, null);
    defer testing.allocator.free(all);
    try testing.expectEqualStrings("\u{65E5}\u{672C}x\r\n", all);
}

test "find" {
    var t = try testTerminal(10, 5, "hello world\nab cd ab");
    defer t.deinit(testing.allocator);
    var view = View.init(t.screens.active);
    const a = (try view.find(testing.allocator, .{}, view.end, "WORLD", false, true)).?;
    try testing.expectEqual(Pos{ .y = 0, .x = 6 }, a.start);
    try testing.expectEqual(Pos{ .y = 1, .x = 1 }, a.end);
    try testing.expect(try view.find(testing.allocator, .{}, view.end, "WORLD", false, false) == null);
    const b = (try view.find(testing.allocator, .{}, view.end, "ab", true, false)).?;
    try testing.expectEqual(Pos{ .y = 2, .x = 6 }, b.start);
    try testing.expectEqual(Pos{ .y = 2, .x = 8 }, b.end);
}

test "visible parts" {
    var t = try testTerminal(10, 5, "hello world\nab cd");
    defer t.deinit(testing.allocator);
    var view = View.init(t.screens.active);
    const parts = try view.visibleParts(testing.allocator, .{}, view.end);
    defer testing.allocator.free(parts);
    try testing.expectEqual(@as(usize, 3), parts.len);
    try testing.expectEqual(View.Part{ .row = 0, .x0 = 0, .x1 = 10 }, parts[0]);
    try testing.expectEqual(View.Part{ .row = 1, .x0 = 0, .x1 = 1 }, parts[1]);
    try testing.expectEqual(View.Part{ .row = 2, .x0 = 0, .x1 = 5 }, parts[2]);
    const caret = try view.visibleParts(testing.allocator, .{ .y = 2, .x = 5 }, .{ .y = 2, .x = 5 });
    defer testing.allocator.free(caret);
    try testing.expectEqual(@as(usize, 1), caret.len);
    try testing.expectEqual(View.Part{ .row = 2, .x0 = 5, .x1 = 5 }, caret[0]);
}
