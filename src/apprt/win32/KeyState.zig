//! The key state indicator's state (roadmap 3.6), GTK's KeyStateOverlay:
//! the key tables in effect (activate_key_table, a stack) and the leader
//! keys of a key sequence typed so far. While either is there, the pane
//! shows them in a pill at its bottom center: the tables, outermost first,
//! joined by " > ", then a "›" when there are both, then the keys, each
//! as Windows names them ("Ctrl+Shift+A").
const KeyState = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("../../input.zig");
const ContextMenu = @import("ContextMenu.zig");

/// The leader keys so far, and the active tables, outermost first.
sequence: std.ArrayList([]u8) = .empty,
tables: std.ArrayList([]u8) = .empty,

pub fn deinit(self: *KeyState, alloc: Allocator) void {
    self.clearSequence(alloc);
    self.sequence.deinit(alloc);
    self.clearTables(alloc);
    self.tables.deinit(alloc);
}

/// Whether there is anything to show.
pub fn active(self: *const KeyState) bool {
    return self.sequence.items.len > 0 or self.tables.items.len > 0;
}

/// A leader key of a pending sequence (key_sequence .trigger).
pub fn sequenceKey(self: *KeyState, alloc: Allocator, trigger: input.Binding.Trigger) Allocator.Error!void {
    var w: std.Io.Writer.Allocating = .init(alloc);
    errdefer w.deinit();
    // A trigger with no name (catch_all) is left out, as GTK leaves it.
    ContextMenu.writeTrigger(&w.writer, trigger) catch {
        w.deinit();
        return;
    };
    const key = try w.toOwnedSlice();
    errdefer alloc.free(key);
    try self.sequence.append(alloc, key);
}

/// The sequence ended (key_sequence .end).
pub fn clearSequence(self: *KeyState, alloc: Allocator) void {
    for (self.sequence.items) |s| alloc.free(s);
    self.sequence.clearRetainingCapacity();
}

/// key_table: a table activated, the innermost deactivated, or all.
pub fn tableActivate(self: *KeyState, alloc: Allocator, name: []const u8) Allocator.Error!void {
    const copy = try alloc.dupe(u8, name);
    errdefer alloc.free(copy);
    try self.tables.append(alloc, copy);
}

pub fn tableDeactivate(self: *KeyState, alloc: Allocator) void {
    if (self.tables.pop()) |name| alloc.free(name);
}

pub fn clearTables(self: *KeyState, alloc: Allocator) void {
    for (self.tables.items) |s| alloc.free(s);
    self.tables.clearRetainingCapacity();
}

/// The indicator's text into `buf` (cut short if it doesn't fit).
pub fn text(self: *const KeyState, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    for (self.tables.items, 0..) |name, i| {
        if (i > 0) w.writeAll(" > ") catch break;
        w.writeAll(name) catch break;
    }
    if (self.tables.items.len > 0 and self.sequence.items.len > 0) w.writeAll(" \u{203A} ") catch {};
    for (self.sequence.items, 0..) |key, i| {
        if (i > 0) w.writeAll(" ") catch break;
        w.writeAll(key) catch break;
    }
    return w.buffered();
}

test "key state text: tables, then the chevron, then the keys" {
    const alloc = std.testing.allocator;
    var ks: KeyState = .{};
    defer ks.deinit(alloc);
    var buf: [128]u8 = undefined;
    try std.testing.expect(!ks.active());

    try ks.sequenceKey(alloc, .{ .key = .{ .unicode = 'a' }, .mods = .{ .ctrl = true } });
    try std.testing.expectEqualStrings("Ctrl+A", ks.text(&buf));
    try ks.sequenceKey(alloc, .{ .key = .{ .unicode = 'b' }, .mods = .{} });
    try std.testing.expectEqualStrings("Ctrl+A B", ks.text(&buf));

    try ks.tableActivate(alloc, "resize");
    try ks.tableActivate(alloc, "fine");
    try std.testing.expectEqualStrings("resize > fine \u{203A} Ctrl+A B", ks.text(&buf));

    ks.clearSequence(alloc);
    try std.testing.expectEqualStrings("resize > fine", ks.text(&buf));
    ks.tableDeactivate(alloc);
    try std.testing.expectEqualStrings("resize", ks.text(&buf));
    ks.clearTables(alloc);
    try std.testing.expect(!ks.active());
}
