//! The panes waiting for their user (murrtty's own, the owner's design of
//! 2026-10-29): a bell or a notification from a pane without the keyboard (an agent asking for input in a
//! background tab or split, say) puts a bell for it in every window's
//! header bar (HeaderBar.bellPlace), oldest first. A left click on one goes
//! to its pane, a right click dismisses it where it is; it goes too when
//! the pane gets the keyboard, closes or is parked for undo. No option
//! turns it off: Ghostty's config has none to read (the config stays
//! Ghostty's).
const Waiting = @This();

const std = @import("std");
const c = @import("c.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const text_util = @import("text.zig");

/// Oldest first, one per pane, by its core surface's id.
list: std.ArrayList(Entry) = .empty,

pub const Entry = struct {
    surface: u64,
    /// The latest notification's text (its title, then its body), for the
    /// bell's tooltip; null when only the bell rang.
    note: ?[]u8 = null,
};

/// A notification's text.
pub const Note = struct {
    title: []const u8,
    body: []const u8,
};

/// Room for a notification's text in a tooltip line or two.
const note_max = 300;
/// How many panes the overflow bell's tooltip names before "and N more".
const listed_max = 8;

pub fn deinit(self: *Waiting, alloc: std.mem.Allocator) void {
    for (self.list.items) |e| if (e.note) |n| alloc.free(n);
    self.list.deinit(alloc);
}

pub fn count(self: *const Waiting) usize {
    return self.list.items.len;
}

fn indexOf(self: *const Waiting, id: u64) ?usize {
    for (self.list.items, 0..) |e, i| if (e.surface == id) return i;
    return null;
}

/// `surface` rang its bell or sent a notification (`note`): a bell for it,
/// unless it has the keyboard (its user is there; a shell's bell on Tab
/// completion) or is parked for undo. A pane already waiting keeps its
/// place, taking the newer notification's text.
pub fn add(self: *Waiting, app: *App, surface: *Surface, note: ?Note) void {
    if (surface.has_focus or surface.parked() or !surface.core_initialized) return;
    const alloc = app.core_app.alloc;
    const text = if (note) |n| noteText(alloc, n) catch null else null;
    if (self.indexOf(surface.core_surface.id)) |i| {
        const e = &self.list.items[i];
        if (text) |t| {
            if (e.note) |old| alloc.free(old);
            e.note = t;
        }
        return;
    }
    self.list.append(alloc, .{ .surface = surface.core_surface.id, .note = text }) catch {
        if (text) |t| alloc.free(t);
        return;
    };
    self.changed(app);
}

fn noteText(alloc: std.mem.Allocator, n: Note) ![]u8 {
    const title = std.mem.trim(u8, n.title, " \t\r\n");
    const body = std.mem.trim(u8, n.body, " \t\r\n");
    const joined = if (title.len > 0 and body.len > 0)
        try std.fmt.allocPrint(alloc, "{s}\n{s}", .{ title, body })
    else
        try alloc.dupe(u8, if (title.len > 0) title else body);
    const cut = text_util.truncate(joined, note_max);
    if (cut.len == joined.len) return joined;
    defer alloc.free(joined);
    return alloc.dupe(u8, cut);
}

/// The pane with core surface `id` got the keyboard or closed: no bell.
pub fn remove(self: *Waiting, app: *App, id: u64) void {
    const i = self.indexOf(id) orelse return;
    self.removeAt(app, i);
    self.changed(app);
}

/// Drop the bells of panes no window has any more (parked for undo).
pub fn prune(self: *Waiting, app: *App) void {
    var dropped = false;
    var i: usize = self.list.items.len;
    while (i > 0) {
        i -= 1;
        if (app.findSurface(self.list.items[i].surface) == null) {
            self.removeAt(app, i);
            dropped = true;
        }
    }
    if (dropped) self.changed(app);
}

/// The pane bell `index` stands for (the oldest of the rest for the bell
/// that counts them), as a click on it is pressed.
pub fn idAt(self: *const Waiting, index: usize) ?u64 {
    if (index >= self.list.items.len) return null;
    return self.list.items[index].surface;
}

/// A left click on the bell of pane `id`: it goes, and its pane comes
/// forward (its tab selected, a zoom hiding it ended, its window raised).
pub fn visit(self: *Waiting, app: *App, id: u64) void {
    const i = self.indexOf(id) orelse return;
    self.removeAt(app, i);
    self.changed(app);
    const surface = app.findSurface(id) orelse return;
    surface.window.presentSurface(surface);
}

/// A right click on the bell of pane `id`: it goes, and the keyboard
/// stays.
pub fn dismiss(self: *Waiting, app: *App, id: u64) void {
    self.remove(app, id);
}

fn removeAt(self: *Waiting, app: *App, index: usize) void {
    const e = self.list.orderedRemove(index);
    if (e.note) |n| app.core_app.alloc.free(n);
}

/// Every window's header bar shows the bells anew. Not a window being
/// destroyed (onDestroy cleared its pointer first), whose tabs go one by
/// one as their panes leave the list.
fn changed(self: *Waiting, app: *App) void {
    _ = self;
    for (app.windows.items) |w| {
        if (c.GetWindowLongPtrW(w.hwnd, c.GWLP_USERDATA) == 0) continue;
        w.bellsChanged();
    }
}

/// What bell `index`'s tooltip says: the pane's title, where it is, and
/// the notification's text if one came. With `more` the bell stands for
/// every pane from `index` on (more wait than fit): their titles and
/// places, a line each.
pub fn describe(self: *const Waiting, app: *App, w: *std.Io.Writer, index: usize, more: bool) !void {
    if (index >= self.list.items.len) return;
    if (!more) {
        const e = self.list.items[index];
        const s = app.findSurface(e.surface) orelse return;
        try w.writeAll(s.effectiveTitle() orelse "murrtty");
        try w.writeAll("\n");
        try writePlace(app, w, s);
        if (e.note) |n| try w.print("\n{s}", .{n});
        return;
    }
    const rest = self.list.items[index..];
    try w.print("{d} {s}waiting", .{ rest.len, if (index > 0) "more " else "" });
    for (rest[0..@min(rest.len, listed_max)]) |e| {
        const s = app.findSurface(e.surface) orelse continue;
        try w.print("\n{s} (", .{s.effectiveTitle() orelse "murrtty"});
        try writePlace(app, w, s);
        try w.writeAll(")");
    }
    if (rest.len > listed_max) try w.print("\nand {d} more", .{rest.len - listed_max});
}

/// Where `s` is, as the command palette's focus entries say it: "Tab 2",
/// or with several windows "Window 1, tab 2"; the quick terminal by name.
fn writePlace(app: *App, w: *std.Io.Writer, s: *Surface) !void {
    const window = s.window;
    const ti = (window.tabIndexOf(s) orelse 0) + 1;
    if (window.quick != null) {
        try w.writeAll("Quick terminal");
        if (window.tabs.items.len > 1) try w.print(", tab {d}", .{ti});
        return;
    }
    if (app.windows.items.len > 1) {
        for (app.windows.items, 1..) |other, wi| if (other == window) {
            return w.print("Window {d}, tab {d}", .{ wi, ti });
        };
    }
    try w.print("Tab {d}", .{ti});
}

test "noteText: the title, then the body, cut to fit" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const both = try noteText(alloc, .{ .title = "Claude Code", .body = " Claude is waiting for your input\n" });
    defer alloc.free(both);
    try testing.expectEqualStrings("Claude Code\nClaude is waiting for your input", both);
    const body = try noteText(alloc, .{ .title = "", .body = "done" });
    defer alloc.free(body);
    try testing.expectEqualStrings("done", body);
    // A long body is cut on a character's boundary: an é across the cut
    // goes whole.
    var long: [note_max + 4]u8 = @splat('x');
    long[note_max - 1] = 0xC3;
    long[note_max] = 0xA9;
    const cut = try noteText(alloc, .{ .title = "", .body = &long });
    defer alloc.free(cut);
    try testing.expectEqual(note_max - 1, cut.len);
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
}
