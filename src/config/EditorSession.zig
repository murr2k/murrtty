//! What the config editor (roadmap F1) edits: the files the loader reads at
//! start (murrtty's own, else Ghostty's: `edit.defaultFiles`, a legacy
//! `config` before `config.ghostty`) and the files they include
//! (`config-file`), in the order the loader applies them, each held as an
//! `EditableFile`. A change goes where the loader would take it from:
//!
//! - a single-valued option into the last file that sets it, since an
//!   included file applies after the whole file including it, or the main
//!   file (the one `edit.openPath` opens) when none does;
//! - a list into the main file's lines for it (the other files' entries
//!   are shown and kept).
//!
//! Everything written is Ghostty's own syntax, and only the lines of the
//! keys changed, so a Ghostty configuration stays one Ghostty reads. No file
//! is written here: the caller writes what `changedFiles` hands back, then
//! calls `saved`. Files are read through the caller's `Reader`, at the start
//! and when a `config-file` change includes another.
//!
//! One difference from the loader remains: it resolves a relative include
//! against the folder of the file that names it after following links
//! (`realPathFile`); here it is the folder the path names.
const EditorSession = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("Config.zig");
const EditableFile = @import("EditableFile.zig");
const option_list = @import("option_list.zig");

pub const File = struct {
    /// Absolute.
    path: []u8,
    /// Its text when read (or last saved), to tell whether it changed on
    /// disk meanwhile.
    original: []u8,
    doc: EditableFile,
    dirty: bool = false,

    fn deinit(self: *File, alloc: Allocator) void {
        alloc.free(self.path);
        alloc.free(self.original);
        self.doc.deinit();
    }
};

/// A file read: its text (allocated with the allocator given), or that it
/// isn't there, or why it couldn't be read.
pub const ReadResult = union(enum) {
    text: []u8,
    not_found,
    failed: []const u8,
};

/// Reads the files the session opens.
pub const Reader = struct {
    ctx: *anyopaque,
    /// The file at `path` (absolute), allocated with `alloc`.
    read: *const fn (ctx: *anyopaque, alloc: Allocator, path: []const u8) ReadResult,
};

/// An included file not edited: not there (`reason` null), unreadable, or
/// holding a line the loader can't read.
pub const Missing = struct {
    path: []u8,
    reason: ?[]const u8,
};

/// A file the loader reads at start, and its text.
pub const Top = struct {
    path: []const u8,
    text: []const u8,
};

/// An entry of a list, and the file it is in.
pub const ListEntry = struct {
    value: ?[]const u8,
    file: usize,
};

alloc: Allocator,
/// Every file read: the top-level files first, then included ones as they
/// were found. An include taken out of the configuration stays here (an
/// edit made in it is still saved) but leaves `order`.
files: std.ArrayList(File) = .empty,
/// The files the loader reads now, by index into `files`, in its order.
order: std.ArrayList(usize) = .empty,
/// How many of `files` are top-level (the first ones).
tops: usize = 0,
/// The file a key no file sets goes in, and a list's lines: one of the
/// top-level files.
main: usize = 0,
/// Included files not edited, for the editor to say so.
missing: std.ArrayList(Missing) = .empty,
/// The defaults, for options no file sets.
defaults: Config,
reader: Reader,

/// Open `path` (absolute), whose text is `text`, and the files it
/// includes, read through `reader`.
pub fn init(alloc: Allocator, path: []const u8, text: []const u8, reader: Reader) !EditorSession {
    return initFiles(alloc, &.{.{ .path = path, .text = text }}, 0, reader);
}

/// Open the top-level files `tops`, in the order the loader reads them,
/// with `tops[main]` the main file, and the files they include.
pub fn initFiles(alloc: Allocator, tops: []const Top, main: usize, reader: Reader) !EditorSession {
    std.debug.assert(tops.len > 0 and main < tops.len);
    var self: EditorSession = .{ .alloc = alloc, .defaults = try .default(alloc), .reader = reader };
    errdefer self.deinit();
    for (tops) |t| try self.addFile(t.path, t.text);
    self.tops = tops.len;
    self.main = main;
    try self.discover();
    return self;
}

pub fn deinit(self: *EditorSession) void {
    for (self.files.items) |*f| f.deinit(self.alloc);
    self.files.deinit(self.alloc);
    self.order.deinit(self.alloc);
    for (self.missing.items) |m| self.alloc.free(m.path);
    self.missing.deinit(self.alloc);
    self.defaults.deinit();
}

fn addFile(self: *EditorSession, path: []const u8, text: []const u8) !void {
    var doc = try EditableFile.parse(self.alloc, text);
    errdefer doc.deinit();
    const p = try self.alloc.dupe(u8, path);
    errdefer self.alloc.free(p);
    const original = try self.alloc.dupe(u8, text);
    errdefer self.alloc.free(original);
    try self.files.append(self.alloc, .{ .path = p, .original = original, .doc = doc });
}

fn indexOf(self: *const EditorSession, path: []const u8) ?usize {
    for (self.files.items, 0..) |f, i| if (std.ascii.eqlIgnoreCase(f.path, path)) return i;
    return null;
}

fn noteMissing(self: *EditorSession, path: []const u8, reason: ?[]const u8) !void {
    for (self.missing.items) |m| if (std.ascii.eqlIgnoreCase(m.path, path)) return;
    const p = try self.alloc.dupe(u8, path);
    errdefer self.alloc.free(p);
    try self.missing.append(self.alloc, .{ .path = p, .reason = reason });
}

/// The files the loader reads, in its order, as Config builds its
/// `config-file` list and loadRecursiveFiles walks it: every top-level
/// file's entries in turn, then each file the list names, whose own
/// entries join the list as it goes (an empty value empties it; a file is
/// read once, though a top-level file named again applies again). A file
/// read before is taken as it stands (with its edits); a new one is read.
fn discover(self: *EditorSession) !void {
    const alloc = self.alloc;
    self.order.clearRetainingCapacity();
    for (self.missing.items) |m| alloc.free(m.path);
    self.missing.clearRetainingCapacity();

    var list: std.ArrayList([]u8) = .empty;
    defer {
        for (list.items) |p| alloc.free(p);
        list.deinit(alloc);
    }
    for (0..self.tops) |i| {
        try self.order.append(alloc, i);
        try self.addIncludes(&list, i);
    }

    var loaded: std.ArrayList([]u8) = .empty;
    defer {
        for (loaded.items) |p| alloc.free(p);
        loaded.deinit(alloc);
    }
    var k: usize = 0;
    while (k < list.items.len) : (k += 1) {
        const target = list.items[k];
        const seen = for (loaded.items) |p| {
            if (std.mem.eql(u8, p, target)) break true;
        } else false;
        if (seen) continue;
        try loaded.ensureUnusedCapacity(alloc, 1);
        loaded.appendAssumeCapacity(try alloc.dupe(u8, target));
        const index = self.indexOf(target) orelse index: {
            switch (self.reader.read(self.reader.ctx, alloc, target)) {
                .not_found => try self.noteMissing(target, null),
                .failed => |reason| try self.noteMissing(target, reason),
                .text => |content| {
                    defer alloc.free(content);
                    self.addFile(target, content) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        // A line the loader can't read: it isn't edited.
                        else => try self.noteMissing(target, "a line is longer than murrtty reads"),
                    };
                    if (self.indexOf(target)) |i| break :index i;
                },
            }
            continue;
        };
        try self.order.append(alloc, index);
        // May empty the list: `target` goes with it.
        try self.addIncludes(&list, index);
    }
}

/// File `index`'s `config-file` entries, onto the loader's `list`: a path
/// (relative to the file's folder) added, an empty value emptying it, a
/// bare key or an empty optional path changing nothing.
fn addIncludes(self: *EditorSession, list: *std.ArrayList([]u8), index: usize) !void {
    const alloc = self.alloc;
    const values_ = try self.files.items[index].doc.values(alloc, "config-file");
    defer alloc.free(values_);
    for (values_) |value| {
        const v = value orelse continue;
        if (v.len == 0) {
            for (list.items) |p| alloc.free(p);
            list.clearRetainingCapacity();
            continue;
        }
        const target = try resolveInclude(alloc, self.files.items[index].path, v) orelse continue;
        errdefer alloc.free(target);
        try list.append(alloc, target);
    }
}

/// A `config-file` value's file: an optional one's `?` and quotes taken
/// off as the loader's Path.parse does, and a relative one resolved against
/// the including file's folder. Null for an empty value.
fn resolveInclude(alloc: Allocator, from: []const u8, value: []const u8) !?[]u8 {
    var v = value;
    if (v.len > 0 and v[0] == '?') v = v[1..];
    if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') v = v[1 .. v.len - 1];
    if (v.len == 0) return null;
    if (std.fs.path.isAbsolute(v)) return try std.fs.path.resolve(alloc, &.{v});
    const dir = std.fs.path.dirname(from) orelse return try alloc.dupe(u8, v);
    return try std.fs.path.resolve(alloc, &.{ dir, v });
}

/// The main file's own lines for list `name`, in order (what the editor's
/// field for it holds). They point into the file's lines, so they last
/// until the next change.
pub fn mainEntries(self: *const EditorSession, alloc: Allocator, name: []const u8) ![]?[]const u8 {
    return self.files.items[self.main].doc.values(alloc, name);
}

/// Whether the loader reads file `index` now.
pub fn isActive(self: *const EditorSession, index: usize) bool {
    return std.mem.indexOfScalar(usize, self.order.items, index) != null;
}

/// The file whose line the loader takes for a single-valued `name`: the
/// last that sets it. Null when none does.
pub fn source(self: *const EditorSession, name: []const u8) ?usize {
    var k = self.order.items.len;
    while (k > 0) {
        k -= 1;
        const i = self.order.items[k];
        if (self.files.items[i].doc.has(name)) return i;
    }
    return null;
}

/// Whether any file sets `name`.
pub fn isSet(self: *const EditorSession, name: []const u8) bool {
    return self.source(name) != null;
}

/// `name`'s value as the editor shows it: what the files give it, else its
/// default. A list has its entries from every file, in the loader's order;
/// anything else its value from `source`. The caller frees it with
/// `option_list.freeValues`.
pub fn values(self: *const EditorSession, alloc: Allocator, name: []const u8) ![][]u8 {
    const option = option_list.find(name) orelse return error.UnknownOption;
    if (option.kind == .list) {
        const entries = try self.listEntries(alloc, name);
        defer alloc.free(entries);
        if (entries.len > 0) {
            var out: std.ArrayList([]u8) = .empty;
            errdefer {
                for (out.items) |v| alloc.free(v);
                out.deinit(alloc);
            }
            for (entries) |e| try out.append(alloc, try alloc.dupe(u8, e.value orelse ""));
            return out.toOwnedSlice(alloc);
        }
    } else if (self.source(name)) |i| {
        const given = try self.files.items[i].doc.values(alloc, name);
        defer alloc.free(given);
        const last = given[given.len - 1];
        // A bare key: true for a boolean.
        const text = last orelse if (option.kind == .toggle) "true" else "";
        const out = try alloc.alloc([]u8, 1);
        errdefer alloc.free(out);
        out[0] = try alloc.dupe(u8, text);
        return out;
    }
    return option_list.values(alloc, &self.defaults, name);
}

/// A list's entries in every file the loader reads, in its order. They
/// point into the files' lines, so they last until the next change.
pub fn listEntries(self: *const EditorSession, alloc: Allocator, name: []const u8) ![]ListEntry {
    var out: std.ArrayList(ListEntry) = .empty;
    errdefer out.deinit(alloc);
    for (self.order.items) |i| {
        const given = try self.files.items[i].doc.values(alloc, name);
        defer alloc.free(given);
        for (given) |v| try out.append(alloc, .{ .value = v, .file = i });
    }
    return out.toOwnedSlice(alloc);
}

/// Give a single-valued option `value` where the loader takes it from.
pub fn set(self: *EditorSession, name: []const u8, value: ?[]const u8) !void {
    const i = self.source(name) orelse self.main;
    try self.files.items[i].doc.set(name, value);
    self.files.items[i].dirty = true;
}

/// Give a list exactly `entries` as the main file's lines for it; the other
/// files' entries stay. A change of `config-file` finds the includes again.
pub fn setList(self: *EditorSession, name: []const u8, entries: []const ?[]const u8) !void {
    try self.files.items[self.main].doc.setList(name, entries);
    self.files.items[self.main].dirty = true;
    if (std.mem.eql(u8, name, "config-file")) try self.discover();
}

/// Back to its default: every line for `name` goes, in each file the loader
/// reads (a list's only in the main file, as `setList` edits only that).
pub fn reset(self: *EditorSession, name: []const u8) !void {
    const option = option_list.find(name) orelse return;
    for (self.order.items) |i| {
        if (option.kind == .list and i != self.main) continue;
        const f = &self.files.items[i];
        if (!f.doc.has(name)) continue;
        f.doc.remove(name);
        f.dirty = true;
    }
    if (std.mem.eql(u8, name, "config-file")) try self.discover();
}

/// Whether anything changed since the files were read or saved.
pub fn dirty(self: *const EditorSession) bool {
    for (self.files.items) |f| if (f.dirty) return true;
    return false;
}

/// A changed file to write: its path and new text (the caller frees the
/// text), by its index for `saved`.
pub const Changed = struct { index: usize, path: []const u8, text: []u8 };

/// The changed files and their new text, owned by the caller (free each
/// text, then the slice).
pub fn changedFiles(self: *const EditorSession, alloc: Allocator) ![]Changed {
    var out: std.ArrayList(Changed) = .empty;
    errdefer {
        for (out.items) |ch| alloc.free(ch.text);
        out.deinit(alloc);
    }
    for (self.files.items, 0..) |f, i| {
        if (!f.dirty) continue;
        const text = try f.doc.toOwnedText(alloc);
        errdefer alloc.free(text);
        try out.append(alloc, .{ .index = i, .path = f.path, .text = text });
    }
    return out.toOwnedSlice(alloc);
}

/// File `index` was written with `text`: it is what is on disk now.
pub fn saved(self: *EditorSession, index: usize, text: []const u8) !void {
    const f = &self.files.items[index];
    const copy = try self.alloc.dupe(u8, text);
    self.alloc.free(f.original);
    f.original = copy;
    f.dirty = false;
}

const testing = std.testing;

/// Files in memory, by path.
const TestFiles = struct {
    map: []const struct { []const u8, []const u8 },

    fn reader(self: *const TestFiles) Reader {
        return .{ .ctx = @constCast(self), .read = read };
    }

    fn read(ctx: *anyopaque, alloc: Allocator, path: []const u8) ReadResult {
        const self: *const TestFiles = @ptrCast(@alignCast(ctx));
        for (self.map) |entry| if (std.ascii.eqlIgnoreCase(entry[0], path)) {
            if (std.mem.eql(u8, entry[1], "<locked>")) return .{ .failed = "another program is using it" };
            return .{ .text = alloc.dupe(u8, entry[1]) catch return .{ .failed = "out of memory" } };
        };
        return .not_found;
    }
};

fn expectValues(session: *const EditorSession, name: []const u8, want: []const []const u8) !void {
    const got = try session.values(testing.allocator, name);
    defer option_list.freeValues(testing.allocator, got);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "EditorSession: includes in the loader's order, each once" {
    const files: TestFiles = .{ .map = &.{
        .{ "C:\\cfg\\colors", "config-file = sub\\more\nbackground = #111111\n" },
        .{ "C:\\cfg\\sub\\more", "config-file = ../colors\nforeground = #eeeeee\n" },
        .{ "D:\\abs.conf", "font-size = 20\n" },
    } };
    var session = try init(testing.allocator, "C:\\cfg\\config.ghostty",
        \\font-size = 12
        \\config-file = colors
        \\config-file = ?"D:\abs.conf"
        \\config-file = ?missing
        \\
    , files.reader());
    defer session.deinit();

    try testing.expectEqual(4, session.files.items.len);
    try testing.expectEqualStrings("C:\\cfg\\colors", session.files.items[1].path);
    try testing.expectEqualStrings("D:\\abs.conf", session.files.items[2].path);
    try testing.expectEqualStrings("C:\\cfg\\sub\\more", session.files.items[3].path);
    try testing.expectEqual(1, session.missing.items.len);

    // The included file applies last, so its font-size is the one taken.
    try testing.expectEqual(@as(?usize, 2), session.source("font-size"));
    try expectValues(&session, "font-size", &.{"20"});
    try expectValues(&session, "background", &.{"#111111"});
    try testing.expectEqual(@as(?usize, null), session.source("cursor-color"));
}

test "EditorSession: a change goes where the loader takes it from" {
    const files: TestFiles = .{ .map = &.{
        .{ "C:\\cfg\\theme", "background = #111111\nkeybind = ctrl+b=paste_from_clipboard\n" },
    } };
    var session = try init(testing.allocator, "C:\\cfg\\config", "config-file = theme\nkeybind = ctrl+a=copy_to_clipboard\n", files.reader());
    defer session.deinit();
    try testing.expect(!session.dirty());

    // Set in the include: changed there.
    try session.set("background", "#222222");
    try testing.expect(session.files.items[1].dirty and !session.files.items[0].dirty);
    // Set nowhere: in the opened file.
    try session.set("font-size", "15");
    try testing.expect(session.files.items[0].dirty);

    // A list: every file's entries, the opened file's edited.
    const entries = try session.listEntries(testing.allocator, "keybind");
    defer testing.allocator.free(entries);
    try testing.expectEqual(2, entries.len);
    try testing.expectEqual(1, entries[1].file);
    try session.setList("keybind", &.{ "ctrl+a=copy_to_clipboard", "ctrl+n=new_window" });
    try expectValues(&session, "keybind", &.{ "ctrl+a=copy_to_clipboard", "ctrl+n=new_window", "ctrl+b=paste_from_clipboard" });

    const changed = try session.changedFiles(testing.allocator);
    defer {
        for (changed) |ch| testing.allocator.free(ch.text);
        testing.allocator.free(changed);
    }
    try testing.expectEqual(2, changed.len);
    try testing.expectEqualStrings("config-file = theme\nkeybind = ctrl+a=copy_to_clipboard\nkeybind = ctrl+n=new_window\nfont-size = 15\n", changed[0].text);
    try testing.expectEqualStrings("background = #222222\nkeybind = ctrl+b=paste_from_clipboard\n", changed[1].text);

    try session.saved(changed[0].index, changed[0].text);
    try session.saved(changed[1].index, changed[1].text);
    try testing.expect(!session.dirty());
    try testing.expectEqualStrings(changed[1].text, session.files.items[1].original);
}

test "EditorSession: defaults, a bare key and reset" {
    const files: TestFiles = .{ .map = &.{
        .{ "C:\\cfg\\inc", "focus-follows-mouse = false\n" },
    } };
    var session = try init(testing.allocator, "C:\\cfg\\config", "focus-follows-mouse\nconfig-file = inc\nwindow-decoration\n", files.reader());
    defer session.deinit();

    // Unset: its default, formatted as the file holds it.
    try expectValues(&session, "window-theme", &.{"auto"});
    // The include's line is the one taken.
    try expectValues(&session, "focus-follows-mouse", &.{"false"});
    try testing.expect(session.isSet("focus-follows-mouse"));

    // Reset takes the option out of every file.
    try session.reset("focus-follows-mouse");
    try testing.expect(!session.isSet("focus-follows-mouse"));
    try testing.expect(session.files.items[0].dirty and session.files.items[1].dirty);
    try expectValues(&session, "focus-follows-mouse", &.{"false"});

    // Saving unchanged files writes nothing.
    var fresh = try init(testing.allocator, "C:\\cfg\\config", "font-size = 12\n", files.reader());
    defer fresh.deinit();
    const changed = try fresh.changedFiles(testing.allocator);
    defer testing.allocator.free(changed);
    try testing.expectEqual(0, changed.len);
}

test "EditorSession: two top-level files, as the loader reads them" {
    const files: TestFiles = .{ .map = &.{} };
    // A legacy `config` read first, then `config.ghostty`, the main file.
    var session = try initFiles(testing.allocator, &.{
        .{ .path = "C:\\cfg\\config", .text = "font-size = 11\ncursor-style = bar\n" },
        .{ .path = "C:\\cfg\\config.ghostty", .text = "font-size = 12\n" },
    }, 1, files.reader());
    defer session.deinit();

    // The later file's line is the one taken; the first file's stands
    // where nothing later sets it.
    try expectValues(&session, "font-size", &.{"12"});
    try testing.expectEqual(@as(?usize, 0), session.source("cursor-style"));
    try session.set("cursor-style", "block");
    try testing.expect(session.files.items[0].dirty and !session.files.items[1].dirty);
    // A key neither sets: the main file.
    try session.set("window-theme", "dark");
    try testing.expect(session.files.items[1].dirty);
    // Reset reaches both.
    try session.reset("font-size");
    try testing.expect(!session.isSet("font-size"));
}

test "EditorSession: a config-file change finds the includes again" {
    const files: TestFiles = .{ .map = &.{
        .{ "C:\\cfg\\theme", "background = #111111\n" },
        .{ "C:\\cfg\\other", "background = #333333\n" },
    } };
    var session = try init(testing.allocator, "C:\\cfg\\config", "config-file = theme\n", files.reader());
    defer session.deinit();
    try testing.expectEqual(@as(?usize, 1), session.source("background"));
    try session.set("background", "#222222");

    // The include taken out: background comes from nowhere, and a change
    // goes to the main file; the edit made in theme is still saved.
    try session.setList("config-file", &.{});
    try testing.expect(!session.isActive(1));
    try testing.expectEqual(@as(?usize, null), session.source("background"));
    try session.set("background", "#444444");
    try testing.expectEqual(@as(?usize, 0), session.source("background"));
    try testing.expect(session.files.items[1].dirty);

    // Another included: read, and it applies after the main file.
    try session.setList("config-file", &.{"other"});
    try testing.expectEqual(3, session.files.items.len);
    try testing.expectEqual(@as(?usize, 2), session.source("background"));
    try expectValues(&session, "background", &.{"#333333"});

    // The first one back, with its edit.
    try session.setList("config-file", &.{ "other", "theme" });
    try testing.expect(session.isActive(1));
    try expectValues(&session, "background", &.{"#222222"});
}

test "EditorSession: config-file as the loader builds its list" {
    const files: TestFiles = .{ .map = &.{
        .{ "C:\\cfg\\theme", "background = #111111\n" },
        .{ "C:\\cfg\\other", "background = #333333\n" },
        .{ "C:\\cfg\\again", "font-size = 14\nconfig-file = config.ghostty\n" },
        .{ "C:\\cfg\\locked", "<locked>" },
        .{ "C:\\cfg\\reset", "config-file =\nconfig-file = theme\n" },
    } };
    // An empty value empties the list: the legacy file's theme isn't read.
    {
        var session = try initFiles(testing.allocator, &.{
            .{ .path = "C:\\cfg\\config", .text = "config-file = theme\n" },
            .{ .path = "C:\\cfg\\config.ghostty", .text = "config-file = \"\"\nconfig-file = other\n" },
        }, 1, files.reader());
        defer session.deinit();
        try testing.expect(session.indexOf("C:\\cfg\\theme") == null);
        try testing.expectEqual(3, session.order.items.len);
        try expectValues(&session, "background", &.{"#333333"});
    }
    // A top-level file named by an include applies again, after it.
    {
        var session = try init(testing.allocator, "C:\\cfg\\config.ghostty", "font-size = 12\nconfig-file = again\n", files.reader());
        defer session.deinit();
        try testing.expectEqual(3, session.order.items.len);
        try testing.expectEqual(@as(usize, 0), session.order.items[2]);
        try expectValues(&session, "font-size", &.{"12"});
        try testing.expectEqual(@as(?usize, 0), session.source("font-size"));
    }
    // An unreadable include is missing with why; one not there, without.
    {
        var session = try init(testing.allocator, "C:\\cfg\\config", "config-file = locked\nconfig-file = ?gone\n", files.reader());
        defer session.deinit();
        try testing.expectEqual(2, session.missing.items.len);
        try testing.expectEqualStrings("another program is using it", session.missing.items[0].reason.?);
        try testing.expect(session.missing.items[1].reason == null);
    }
    // An include emptying the list ends the walk there, as in the loader:
    // neither what was queued after it nor what it names next is read.
    {
        var session = try init(testing.allocator, "C:\\cfg\\config", "config-file = reset\nconfig-file = other\n", files.reader());
        defer session.deinit();
        try testing.expect(session.indexOf("C:\\cfg\\other") == null);
        try testing.expect(session.indexOf("C:\\cfg\\theme") == null);
        try testing.expect(!session.isSet("background"));
    }
}
