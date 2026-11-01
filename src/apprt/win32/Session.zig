//! Session restore (roadmap 5.10b, the owner's design): what the windows
//! hold is saved whenever it changes and brought back when murrtty starts.
//!
//! Saved: each window (its restored rectangle, maximized or fullscreen,
//! its name), its tabs (order, names, the active one) and each tab's split
//! tree (layout, sizes, the focused pane), and each pane's directory, its
//! program when it is a shell of its own, and its name. Not saved:
//! scrollback, what runs in a pane, program-set titles and the
//! environment.
//!
//! The state is `session.json` in murrtty's state folder, written whole
//! (a temporary file, then a replace) and only when it differs from what
//! was last written. A snapshot is taken soon after the changes murrtty
//! hears of (`changed`) and once a second for the ones it doesn't (a
//! directory cmd moved to), never while something is dragged: a drag is
//! saved once, on its release, and one cut short leaves the state as it
//! was. Once murrtty quits, or Windows asks to end its session, the state
//! is written a last time and frozen, so the windows closing on the way out
//! (their shells ending first) don't empty it. Nothing is written before
//! murrtty has started, and a saved window that fails to come back stays
//! in the file for the next start. Only the murrtty holding the single
//! instance's pipe keeps the session.
//!
//! A restored pane gets a fresh shell in its directory, or in the home
//! folder with a notice when the directory is gone. `window-save-state =
//! never` neither saves nor restores. With `initial-window = false` the
//! session waits for the first window asked for, and the quick terminal's
//! for it to be summoned; what waits stays in what is saved meanwhile.
const Session = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const configpkg = @import("../../config.zig");
const global = @import("../../global.zig");
const internal_os = @import("../../os/main.zig");
const build_config = @import("../../build_config.zig");

const c = @import("c.zig");
const text_util = @import("text.zig");
const ipc = @import("ipc.zig");
const App = @import("App.zig");
const AlertDialog = @import("AlertDialog.zig");
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const Window = @import("Window.zig");
const test_hooks = @import("test_hooks.zig");

const log = std.log.scoped(.win32_session);

/// The wakeup window's timer: the snapshot after a change, and the poll.
pub const timer_id = 0x5E55;
const poll_ms = 1000;
const soon_ms = 100;
/// How long a restore's notice (a gone folder, a skipped session) shows.
pub const notice_ms = 8000;
/// How long the crash marker outlives a restore: a crash in the restored
/// windows' first layouts and frames counts as one while restoring.
const marker_ms = 5000;
/// Writes failing in a row before the dialog: a moment's failure (a
/// scanner holding the file) passes unsaid.
const warn_after = 3;
/// How often the history's garbage collector runs while murrtty does.
const gc_ms = 5 * 60 * 1000;
/// The commands a pane's history keeps (PowerShell's integration cuts a
/// restored pane's file to them too).
const history_keep = 1000;

/// The state file's format.
pub const format_version = 1;

/// Bounds on what a state file may hold: past them it isn't one of ours.
const max_file = 8 * 1024 * 1024;
const max_windows = 64;
const max_tabs = 256;
const max_nodes = 511;

/// A pane's id: 16 hexadecimal digits, the name of its history file.
pub const Id = [16]u8;

// ---------------------------------------------------------------- the state

pub const State = struct {
    version: u32 = format_version,
    /// The window in front, by index.
    front: ?u32 = null,
    windows: []const SavedWindow = &.{},
};

pub const SavedWindow = struct {
    /// The quick terminal: its tabs, not its place (its config places it).
    quick: bool = false,
    name: ?[]const u8 = null,
    /// The restored rectangle, as GetWindowPlacement has it (workspace
    /// coordinates), and how it shows.
    left: i32 = 0,
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,
    maximized: bool = false,
    fullscreen: bool = false,
    active: u32 = 0,
    tabs: []const SavedTab = &.{},
};

pub const SavedTab = struct {
    name: ?[]const u8 = null,
    /// The focused pane, by node.
    focused: u32 = 0,
    /// The split tree's nodes as SplitTree holds them, the root first.
    nodes: []const SavedNode = &.{},
};

pub const SavedNode = struct {
    pane: ?SavedPane = null,
    split: ?SavedSplit = null,
};

pub const SavedSplit = struct {
    layout: enum { horizontal, vertical } = .horizontal,
    ratio: f32 = 0.5,
    left: u32 = 0,
    right: u32 = 0,
};

pub const SavedPane = struct {
    id: []const u8 = "",
    directory: ?[]const u8 = null,
    /// The program it runs when that is a shell of its own (cmd, wsl,
    /// pwsh) rather than the configured `command`.
    program: ?SavedProgram = null,
    name: ?[]const u8 = null,
};

pub const SavedProgram = union(enum) {
    direct: []const []const u8,
    shell: []const u8,
};

// ---------------------------------------------------------------- the session

app: *App,
/// The state folder (murrtty's under XDG_STATE_HOME, else %LOCALAPPDATA%),
/// absolute; null where it couldn't be worked out.
dir: ?[]u8 = null,
/// This murrtty keeps the session: it holds the single instance's pipe
/// (another instance would restore the same windows and write over them).
owner: bool = false,
/// It is kept: the owner, a state folder, window-save-state not `never`.
enabled: bool = false,
/// murrtty is quitting, or Windows is ending its session: the state stays
/// as last written; `ending` while Windows may still call that off.
frozen: bool = false,
ending: bool = false,
/// Restoring: the changes it makes aren't saved one by one.
restoring: bool = false,
/// The text last written (or read at start), to write only what changed.
last: ?[]u8 = null,
/// Writes failed in a row; whether a failure was said this run; what waits
/// to be said (a dialog was open, or no window yet).
failures: u32 = 0,
warned: bool = false,
warn_pending: ?[]const u8 = null,
/// The saved session not brought back yet: its windows (restore on first
/// use), its quick terminal (until summoned), and the saved windows that
/// failed to come back (by index), kept for the next start.
pending: ?std.json.Parsed(State) = null,
pending_windows: bool = false,
pending_quick: ?usize = null,
unrestored: std.ArrayList(u32) = .empty,
/// When the crash marker of a restore goes (GetTickCount64).
marker_until: ?u64 = null,
/// The history's garbage collector: when it next runs (GetTickCount64),
/// and held for the run when the saved session is there but couldn't be
/// read, or was put aside (it may name histories that would look
/// dangling).
gc_next: u64 = 0,
gc_hold: bool = false,
/// The last start crashed while restoring: its session was put aside, and
/// a toast says so once there is a window.
skipped: bool = false,
skip_notice: bool = false,

pub fn init(app: *App) Session {
    return .{ .app = app };
}

pub fn deinit(self: *Session) void {
    const alloc = self.app.core_app.alloc;
    // Quitting isn't crashing (the marker's name needs `dir`).
    self.clearMarker();
    if (self.dir) |d| alloc.free(d);
    if (self.last) |l| alloc.free(l);
    if (self.pending) |*p| p.deinit();
    self.unrestored.deinit(alloc);
    self.* = .{ .app = self.app };
}

/// Before any window (App.run): whether this murrtty keeps the session,
/// where it goes, and the saved session, read. The timer starts.
pub fn start(self: *Session, owner: bool) void {
    self.owner = owner;
    if (!owner) {
        log.info("another murrtty holds the single instance: this one keeps no session", .{});
        return;
    }
    _ = c.SetTimer(self.app.wakeup_hwnd, timer_id, poll_ms, null);
    if (self.app.config.@"window-save-state" == .never) return;
    self.dir = stateDir(self.app.core_app.alloc) catch |err| {
        log.warn("no state folder: the session isn't saved err={}", .{err});
        self.warn_pending = "murrtty's state folder (XDG_STATE_HOME, else %LOCALAPPDATA%) can't be found";
        return;
    };
    self.enabled = true;
    self.load();
    self.collectGarbage();
}

/// The config changed (a reload): window-save-state turned on starts
/// saving the windows as they are; `never` stops it, the file kept.
pub fn configChanged(self: *Session) void {
    if (!self.owner or self.frozen) return;
    const want = self.app.config.@"window-save-state" != .never;
    if (want == self.enabled) return;
    if (!want) {
        self.enabled = false;
        return;
    }
    if (self.dir == null) self.dir = stateDir(self.app.core_app.alloc) catch |err| {
        log.warn("no state folder: the session isn't saved err={}", .{err});
        return;
    };
    self.enabled = true;
    self.changed();
}

/// murrtty's state folder: XDG_STATE_HOME's or %LOCALAPPDATA%'s murrtty.
fn stateDir(alloc: Allocator) ![]u8 {
    var environ_map = try global.environMap();
    defer environ_map.deinit();
    const dir = try internal_os.xdg.state(global.io(), alloc, &environ_map, .{ .subdir = build_config.product_id });
    errdefer alloc.free(dir);
    std.mem.replaceScalar(u8, dir, '/', '\\');
    return dir;
}

/// The state file's name for this murrtty: a `--class` instance keeps its
/// own.
fn fileName(self: *const Session, a: Allocator, comptime suffix: []const u8) ![]u8 {
    const dir = self.dir orelse return error.NoDirectory;
    if (self.app.config.class) |class| {
        return std.fmt.allocPrint(a, "{s}\\session-{s}" ++ suffix, .{ dir, try safeName(a, class) });
    }
    return std.fmt.allocPrint(a, "{s}\\session" ++ suffix, .{dir});
}

/// A class as part of a file name.
fn safeName(a: Allocator, class: []const u8) ![]u8 {
    const safe = try a.dupe(u8, class);
    for (safe) |*ch| if (!std.ascii.isAlphanumeric(ch.*) and ch.* != '-' and ch.* != '_' and ch.* != '.') {
        ch.* = '_';
    };
    return safe;
}

// ---------------------------------------------------------------- history

/// The folder of the panes' history files: `history` in the state folder
/// (`history-<class>` for a class's murrtty).
fn historyDir(self: *const Session, a: Allocator) ?[]u8 {
    const dir = self.dir orelse return null;
    if (self.app.config.class) |class| {
        const safe = safeName(a, class) catch return null;
        return std.fmt.allocPrint(a, "{s}\\history-{s}", .{ dir, safe }) catch null;
    }
    return std.fmt.allocPrint(a, "{s}\\history", .{dir}) catch null;
}

/// A pane's own command history (roadmap 5.10b part C): the file its
/// shell's integration keeps (MURRTTY_HISTORY_FILE: PowerShell's), null
/// while nothing is saved.
pub fn historyPath(self: *const Session, a: Allocator, id: Id) ?[]u8 {
    if (!self.enabled) return null;
    const dir = self.historyDir(a) orelse return null;
    return std.fmt.allocPrint(a, "{s}\\{s}.txt", .{ dir, &id }) catch null;
}

/// The Clink history label of a pane: Clink keeps a history of its own for
/// each (CLINK_HISTORY_LABEL, up to 32 letters and digits), in
/// `clink_history-<label>` beside its master history.
pub fn clinkLabel(id: Id) [label_prefix.len + 16]u8 {
    var out: [label_prefix.len + 16]u8 = undefined;
    @memcpy(out[0..label_prefix.len], label_prefix);
    @memcpy(out[label_prefix.len..], &id);
    return out;
}

pub const label_prefix = "murrtty";

/// A pane given its Clink label: a marker beside the history files
/// (`<id>.clink`), so that murrtty removes Clink's history for the labels
/// it gave out, never another's (collectGarbage).
pub fn markClink(self: *Session, id: Id) void {
    var arena: std.heap.ArenaAllocator = .init(self.app.core_app.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = self.historyDir(a) orelse return;
    const marker = std.fmt.allocPrint(a, "{s}\\{s}.clink", .{ dir, &id }) catch return;
    if (exists(a, marker)) return;
    makeDirs(a, dir) catch return;
    writeFile(a, marker, "") catch |err| log.warn("no Clink marker for a pane err={}", .{err});
}

/// A pane closed for good (not parked for undo, not murrtty quitting or
/// Windows ending its session, not a restore that failed): its history
/// goes, and Clink's for it.
pub fn paneClosed(self: *Session, id: Id) void {
    if (!self.enabled or self.frozen or self.restoring) return;
    var arena: std.heap.ArenaAllocator = .init(self.app.core_app.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = self.historyDir(a) orelse return;
    forgetPane(a, dir, id);
}

/// A pane's history files gone: its own, and its Clink history with the
/// marker (kept while any of Clink's files stays, a shell of the label
/// still holding one, so the garbage collector tries again).
fn forgetPane(a: Allocator, dir: []const u8, id: Id) void {
    if (std.fmt.allocPrint(a, "{s}\\{s}.txt", .{ dir, &id })) |path| deleteFile(a, path) else |_| {}
    const marker = std.fmt.allocPrint(a, "{s}\\{s}.clink", .{ dir, &id }) catch return;
    if (exists(a, marker) and deleteClinkHistory(a, id)) deleteFile(a, marker);
}

/// The history's garbage collector (roadmap 5.10b part C), at start and
/// every few minutes while murrtty runs; held for the run while the saved
/// session is there but unreadable. A history (or Clink marker) whose pane
/// is nowhere (not open, not parked for undo, not waiting to be restored)
/// goes, with the marked label's Clink history: one a pane's close
/// couldn't remove (a shell still held it) is tried again, and one
/// murrtty left behind (killed, a pane parked as it quit) goes. A history
/// whose pane waits to be restored, which no shell writes meanwhile, is cut
/// to its last commands and rid of lines with NUL bytes (a write cut short
/// leaves them), so PowerShell gets a clean file back. A file a live
/// pane's shell writes is never touched: one writer per file. murrtty's
/// own temporary files (`.tmp`, a rewrite cut short) go too.
pub fn collectGarbage(self: *Session) void {
    if (!self.enabled or self.frozen or self.restoring or self.gc_hold) return;
    self.gc_next = c.GetTickCount64() + gc_ms;
    var arena: std.heap.ArenaAllocator = .init(self.app.core_app.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = self.historyDir(a) orelse return;

    var live: std.StringHashMapUnmanaged(void) = .empty;
    for (self.app.core_app.surfaces.items) |s| {
        live.put(a, a.dupe(u8, &s.session_id) catch return, {}) catch return;
    }
    var waiting: std.StringHashMapUnmanaged(void) = .empty;
    if (self.pending) |p| for (p.value.windows, 0..) |sw, i| {
        const restoring_later = (self.pending_windows and !sw.quick) or
            (self.pending_quick != null and self.pending_quick.? == i) or
            std.mem.indexOfScalar(u32, self.unrestored.items, @intCast(i)) != null;
        if (!restoring_later) continue;
        for (sw.tabs) |t| for (t.nodes) |n| if (n.pane) |pane| {
            if (paneId(pane) != null) waiting.put(a, pane.id, {}) catch return;
        };
    };

    const pattern = std.fmt.allocPrint(a, "{s}\\*", .{dir}) catch return;
    const pattern_w = text_util.utf16Lossy(a, pattern) catch return;
    var data: c.WIN32_FIND_DATAW = undefined;
    const find = c.FindFirstFileExW(pattern_w.ptr, c.FindExInfoBasic, &data, c.FindExSearchNameMatch, null, 0);
    if (find == c.INVALID_HANDLE_VALUE) return;
    defer _ = c.FindClose(find);
    while (true) {
        entry: {
            if (data.dwFileAttributes & 0x10 != 0) break :entry;
            const name_w = std.mem.sliceTo(&data.cFileName, 0);
            const name = std.unicode.utf16LeToUtf8Alloc(a, name_w) catch break :entry;
            const path = std.fmt.allocPrint(a, "{s}\\{s}", .{ dir, name }) catch break :entry;
            if (std.ascii.endsWithIgnoreCase(name, ".tmp")) {
                deleteFile(a, path);
                break :entry;
            }
            const file = historyFile(name_w) orelse break :entry;
            if (live.contains(&file.id)) break :entry;
            if (waiting.contains(&file.id)) {
                if (file.kind == .txt) repairHistory(a, path);
                break :entry;
            }
            forgetPane(a, dir, file.id);
        }
        if (c.FindNextFileW(find, &data) == 0) break;
    }
}

/// A waiting pane's history file cut and cleaned (trimHistory), rewritten
/// whole through a file beside it only when that changes it.
fn repairHistory(a: Allocator, path: []const u8) void {
    const text = readFile(a, path) orelse return;
    const fixed = (trimHistory(a, text, history_keep) catch return) orelse return;
    writeFile(a, path, fixed) catch |err| log.warn("a pane's history couldn't be cut err={}", .{err});
}

/// PowerShell's history file text cut to its last `keep` commands (a line
/// ending in a backtick goes on in the next, as PSReadLine writes them),
/// lines holding NUL bytes dropped; null when it needs no change.
fn trimHistory(a: Allocator, text: []const u8, keep: usize) !?[]u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var dropped = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.indexOfScalar(u8, line, 0) != null) {
            dropped = true;
            continue;
        }
        try lines.append(a, line);
    }
    // The text's last newline leaves an empty last piece.
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) _ = lines.pop();
    var starts: std.ArrayList(usize) = .empty;
    for (lines.items, 0..) |line, i| {
        _ = line;
        if (i == 0 or !std.mem.endsWith(u8, lines.items[i - 1], "`")) try starts.append(a, i);
    }
    const from = if (starts.items.len > keep) starts.items[starts.items.len - keep] else 0;
    if (!dropped and from == 0) return null;
    var out: std.ArrayList(u8) = .empty;
    for (lines.items[from..]) |line| {
        try out.appendSlice(a, line);
        try out.append(a, '\n');
    }
    return out.items;
}

/// A file of the history folder by its name: a pane's history
/// (`<id>.txt`) or its Clink marker (`<id>.clink`).
fn historyFile(name_w: []const u16) ?struct { id: Id, kind: enum { txt, clink } } {
    var buf: [32]u8 = undefined;
    if (name_w.len > buf.len) return null;
    for (name_w, buf[0..name_w.len]) |ch, *o| o.* = if (ch < 128) @intCast(ch) else return null;
    const name = buf[0..name_w.len];
    if (name.len < 18 or name[16] != '.') return null;
    const id = paneId(.{ .id = name[0..16] }) orelse return null;
    if (std.mem.eql(u8, name[17..], "txt")) return .{ .id = id, .kind = .txt };
    if (std.mem.eql(u8, name[17..], "clink")) return .{ .id = id, .kind = .clink };
    return null;
}

/// Clink's history file names for a label, as a FindFirstFile pattern:
/// `clink_history-<label>` and the files beside it.
fn clinkPattern(a: Allocator, profile: []const u8, id: Id) ![]u8 {
    const label = clinkLabel(id);
    return std.fmt.allocPrint(a, "{s}\\clink_history-{s}*", .{ profile, &label });
}

/// Clink's history for a pane's label, in Clink's profile: CLINK_PROFILE's,
/// else its default (%LOCALAPPDATA%\clink). One a launcher's `--profile`
/// chose elsewhere stays. Whether none of its files is left.
fn deleteClinkHistory(a: Allocator, id: Id) bool {
    var environ_map = global.environMap() catch return false;
    defer environ_map.deinit();
    const dir = if (environ_map.get("CLINK_PROFILE")) |p|
        a.dupe(u8, p) catch return false
    else if (environ_map.get("LOCALAPPDATA")) |local|
        std.fmt.allocPrint(a, "{s}\\clink", .{local}) catch return false
    else
        return true;
    const pattern = clinkPattern(a, dir, id) catch return false;
    const pattern_w = text_util.utf16Lossy(a, pattern) catch return false;
    var data: c.WIN32_FIND_DATAW = undefined;
    const find = c.FindFirstFileExW(pattern_w.ptr, c.FindExInfoBasic, &data, c.FindExSearchNameMatch, null, 0);
    if (find == c.INVALID_HANDLE_VALUE) return true;
    defer _ = c.FindClose(find);
    var all = true;
    while (true) {
        const name = std.unicode.utf16LeToUtf8Alloc(a, std.mem.sliceTo(&data.cFileName, 0)) catch return false;
        const path = std.fmt.allocPrint(a, "{s}\\{s}", .{ dir, name }) catch return false;
        const path_w = text_util.utf16Lossy(a, path) catch return false;
        if (c.DeleteFileW(path_w.ptr) == 0) all = false;
        if (c.FindNextFileW(find, &data) == 0) break;
    }
    return all;
}

/// The saved session into `pending`. A start that crashed while restoring
/// (its marker left) puts the session aside instead, kept as
/// `session-skipped.json`.
fn load(self: *Session) void {
    const alloc = self.app.core_app.alloc;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const path = self.fileName(a, ".json") catch return;
    const marker = self.fileName(a, ".restoring") catch return;
    // Started again on murrtty's software OpenGL by a murrtty that found
    // the marker and put the session aside itself (software_gl.zig).
    const carried = if (self.app.software_start) |s| s.session_skipped else false;
    if (carried or exists(a, marker)) {
        self.skipped = true;
        self.skip_notice = true;
        // The session put aside may come back by hand: its histories stay.
        self.gc_hold = true;
        const aside = self.fileName(a, "-skipped.json") catch return;
        if (!carried) _ = moveFile(a, path, aside);
        deleteFile(a, marker);
        log.warn("the last start crashed while restoring: its session is kept as {s}", .{aside});
        return;
    }
    const text = readFile(a, path) orelse {
        // No session: no pane's history is wanted (collectGarbage). One
        // that couldn't be read (a scanner holding it) keeps them.
        if (!missing(a, path)) self.gc_hold = true;
        return;
    };
    self.last = alloc.dupe(u8, text) catch null;
    const parsed = std.json.parseFromSlice(State, alloc, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        // Its histories stay this run; the next save replaces it, and the
        // start after that clears what it doesn't name.
        log.warn("the saved session can't be read, starting without it err={}", .{err});
        self.gc_hold = true;
        return;
    };
    self.pending = parsed;
    const windows = parsed.value.windows;
    for (windows, 0..) |w, i| {
        if (w.quick) {
            if (self.pending_quick == null) self.pending_quick = i;
        } else self.pending_windows = true;
    }
}

/// At start (App.run): the saved windows back. Returns how many came. With
/// `initial-window = false` they wait for the first window asked for.
pub fn restoreAtStart(self: *Session) usize {
    if (!self.enabled or !self.pending_windows) return 0;
    if (!self.app.config.@"initial-window") return 0;
    return self.restorePending();
}

/// Whether windows of the saved session wait to come back.
pub fn hasPending(self: *const Session) bool {
    return self.pending_windows;
}

/// The saved windows back (at start, or the first window asked for with
/// `initial-window = false`), the front one in front. Returns how many
/// came.
pub fn restorePending(self: *Session) usize {
    if (!self.pending_windows) return 0;
    self.pending_windows = false;
    const parsed = self.pending orelse return 0;
    const alloc = self.app.core_app.alloc;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    self.markRestoring(a);

    // Restored panes take their own commands: the launch's -e opens a tab
    // of its own (App.run), never in the first of them.
    const was_first = self.app.core_app.first;
    self.app.core_app.first = false;
    self.restoring = true;
    defer self.restored();

    var front: ?*Window = null;
    var count: usize = 0;
    for (parsed.value.windows[0..@min(parsed.value.windows.len, max_windows)], 0..) |sw, i| {
        if (sw.quick) continue;
        const w = self.restoreWindow(a, sw) catch |err| {
            // Kept in what is saved, for the next start (no OpenGL now,
            // say).
            log.warn("a saved window wasn't restored err={}", .{err});
            self.unrestored.append(alloc, @intCast(i)) catch {};
            continue;
        };
        count += 1;
        if (parsed.value.front) |f| if (f == i) {
            front = w;
        };
    }
    if (front) |w| w.present();
    // None came: the window made instead takes the launch's command.
    if (count == 0) self.app.core_app.first = was_first;
    return count;
}

/// Restoring once crashed murrtty: a marker says so to the next start
/// until murrtty has run a while after it (marker_ms), so a crash in the
/// restored windows' first layouts and frames counts too.
fn markRestoring(self: *Session, a: Allocator) void {
    const marker = self.fileName(a, ".restoring") catch return;
    writeFile(a, marker, "") catch |err| log.warn("no crash marker for the restore err={}", .{err});
    self.marker_until = c.GetTickCount64() + marker_ms;
}

fn clearMarker(self: *Session) void {
    if (self.marker_until == null) return;
    self.marker_until = null;
    var arena: std.heap.ArenaAllocator = .init(self.app.core_app.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const marker = self.fileName(a, ".restoring") catch return;
    deleteFile(a, marker);
}

/// The quick terminal's saved tabs into `window`, the quick terminal being
/// made (Window.createQuick). Whether any came.
pub fn restoreQuick(self: *Session, window: *Window) bool {
    const index = self.pending_quick orelse return false;
    self.pending_quick = null;
    const parsed = self.pending orelse return false;
    if (index >= parsed.value.windows.len) return false;
    const sw = parsed.value.windows[index];
    var arena: std.heap.ArenaAllocator = .init(self.app.core_app.alloc);
    defer arena.deinit();
    self.markRestoring(arena.allocator());
    const was_first = self.app.core_app.first;
    self.app.core_app.first = false;
    self.restoring = true;
    defer self.restored();
    var gone: Gone = .{};
    for (sw.tabs[0..@min(sw.tabs.len, max_tabs)]) |st| self.restoreTab(arena.allocator(), window, st, &gone) catch |err| {
        log.warn("a saved tab of the quick terminal wasn't restored err={}", .{err});
    };
    if (window.tabs.items.len == 0) {
        self.unrestored.append(self.app.core_app.alloc, @intCast(index)) catch {};
        self.app.core_app.first = was_first;
        return false;
    }
    window.select(@min(sw.active, window.tabs.items.len - 1));
    gone.tell(window);
    return true;
}

/// Directories that were gone, for the notice.
const Gone = struct {
    count: usize = 0,
    first: [256]u8 = undefined,
    first_len: usize = 0,

    fn add(self: *Gone, dir: []const u8) void {
        if (self.count == 0) {
            const cut = text_util.truncate(dir, self.first.len);
            @memcpy(self.first[0..cut.len], cut);
            self.first_len = cut.len;
        }
        self.count += 1;
    }

    fn tell(self: *const Gone, window: *Window) void {
        if (self.count == 0) return;
        var buf: [400]u8 = undefined;
        const text = if (self.count == 1)
            std.fmt.bufPrint(&buf, "{s} is gone: started in your home folder", .{self.first[0..self.first_len]}) catch return
        else
            std.fmt.bufPrint(&buf, "{d} folders are gone: those terminals started in your home folder", .{self.count}) catch return;
        window.showToastFor(text, notice_ms);
    }
};

fn restoreWindow(self: *Session, a: Allocator, sw: SavedWindow) !*Window {
    const window = try Window.createForRestore(self.app, placementOf(sw));
    var gone: Gone = .{};
    for (sw.tabs[0..@min(sw.tabs.len, max_tabs)]) |st| self.restoreTab(a, window, st, &gone) catch |err| {
        log.warn("a saved tab wasn't restored err={}", .{err});
    };
    if (window.tabs.items.len == 0) {
        window.discardRestore();
        return error.NoTab;
    }
    if (sw.name) |n| window.setTitleOverride(n);
    window.showRestored(sw.maximized, sw.fullscreen, @min(sw.active, window.tabs.items.len - 1));
    gone.tell(window);
    return window;
}

/// A saved tab into `window`: its first pane, then each split made off the
/// pane at its left or top, the way the tree was built, with its ratio.
fn restoreTab(self: *Session, a: Allocator, window: *Window, st: SavedTab, gone: *Gone) !void {
    const nodes = st.nodes;
    try validate(a, nodes);
    const made = try a.alloc(?*Surface, nodes.len);
    @memset(made, null);
    const first = leftmost(nodes, 0);
    made[first] = try self.makePane(a, nodes[first].pane.?, gone, window, null);
    const tab = window.activeTab() orelse return error.NoTab;
    try self.build(a, tab, nodes, 0, made, gone, 0);
    if (st.focused < nodes.len) if (made[st.focused]) |s| {
        tab.focused = s;
    };
    if (st.name) |n| tab.setTitleOverride(n);
    tab.layoutPanes();
    window.tabChanged(tab);
}

fn build(self: *Session, a: Allocator, tab: *Tab, nodes: []const SavedNode, at: usize, made: []?*Surface, gone: *Gone, depth: usize) !void {
    if (depth > max_nodes) return error.TooDeep;
    const split = nodes[at].split orelse return;
    const existing = made[leftmost(nodes, split.left)] orelse return error.NoPane;
    const right_first = leftmost(nodes, split.right);
    const handle = tab.tree.locate(existing) orelse return error.NoPane;
    made[right_first] = try self.makePane(a, nodes[right_first].pane.?, gone, null, .{
        .tab = tab,
        .from = existing,
        .right = split.layout == .horizontal,
    });
    // SplitTree.split put the new split where the pane was.
    tab.tree.resizeInPlace(handle, @floatCast(std.math.clamp(split.ratio, 0.05, 0.95)));
    try self.build(a, tab, nodes, split.left, made, gone, depth + 1);
    try self.build(a, tab, nodes, split.right, made, gone, depth + 1);
}

/// The leaf a subtree's leftmost pane is.
fn leftmost(nodes: []const SavedNode, at: usize) usize {
    var i = at;
    var steps: usize = 0;
    while (nodes[i].split) |s| : (steps += 1) {
        if (steps > nodes.len) break;
        i = s.left;
    }
    return i;
}

/// Whether `nodes` is a tree we can build: every node a pane or a split,
/// the splits' children in range, each node reached once from the root.
fn validate(a: Allocator, nodes: []const SavedNode) !void {
    if (nodes.len == 0 or nodes.len > max_nodes) return error.BadTree;
    const seen = try a.alloc(bool, nodes.len);
    defer a.free(seen);
    @memset(seen, false);
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(a);
    try stack.append(a, 0);
    while (stack.pop()) |i| {
        if (seen[i]) return error.BadTree;
        seen[i] = true;
        const n = nodes[i];
        if ((n.pane == null) == (n.split == null)) return error.BadTree;
        if (n.split) |s| {
            if (s.left >= nodes.len or s.right >= nodes.len) return error.BadTree;
            try stack.append(a, s.left);
            try stack.append(a, s.right);
        }
    }
}

/// A saved pane made: a tab's first pane in `window`, or a split off
/// `split.from`. The pane takes its overrides and id from the app as it is
/// made (Surface.init); what the app held before (an IPC request's) is put
/// back after.
fn makePane(
    self: *Session,
    a: Allocator,
    pane: SavedPane,
    gone: *Gone,
    window: ?*Window,
    split: ?struct { tab: *Tab, from: *Surface, right: bool },
) !*Surface {
    var ov = try self.overridesFor(a, pane, gone);
    const prev_overrides = self.app.ipc_overrides;
    const prev_id = self.app.restore_id;
    self.app.ipc_overrides = &ov;
    self.app.restore_id = paneId(pane);
    defer {
        self.app.ipc_overrides = prev_overrides;
        self.app.restore_id = prev_id;
    }
    if (split) |sp| return sp.tab.newSplit(sp.from, if (sp.right) .right else .down, &sp.from.core_surface);
    const w = window.?;
    return w.addTab(null, if (w.tabs.items.len == 0) .window else .tab);
}

/// A saved pane's id, if it is one (else the pane gets a new one).
fn paneId(pane: SavedPane) ?Id {
    if (pane.id.len != 16) return null;
    for (pane.id) |ch| if (!std.ascii.isHex(ch)) return null;
    var id: Id = undefined;
    @memcpy(&id, pane.id);
    return id;
}

/// A new pane's id.
pub fn newId() Id {
    var bytes: [8]u8 = undefined;
    global.io().random(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

/// What a restored pane is made with: its directory (home when it is gone),
/// its program when it has one of its own, its name.
fn overridesFor(self: *Session, a: Allocator, pane: SavedPane, gone: *Gone) !ipc.Overrides {
    var ov: ipc.Overrides = .{};
    if (pane.directory) |d| {
        if (directoryUsable(a, d)) {
            ov.working_directory = .{ .path = try a.dupeSentinel(u8, d, 0) };
        } else {
            gone.add(d);
            if (homeDir(a)) |h| ov.working_directory = .{ .path = h };
        }
    }
    if (pane.program) |p| ov.command = switch (p) {
        .shell => |s| .{ .shell = try a.dupeSentinel(u8, s, 0) },
        .direct => |argv| direct: {
            if (argv.len == 0) break :direct null;
            const out = try a.alloc([:0]const u8, argv.len);
            for (argv, out) |arg, *o| o.* = try a.dupeSentinel(u8, arg, 0);
            break :direct .{ .direct = out };
        },
    };
    if (pane.name) |n| ov.title = try a.dupeSentinel(u8, n, 0);
    _ = self;
    return ov;
}

/// Whether `dir` names a directory that is there, checked as Exec checks a
/// shell's (GetFileAttributesW, so no name std would panic on is asked).
fn directoryUsable(a: Allocator, dir: []const u8) bool {
    if (dir.len == 0 or dir.len > 32000) return false;
    return isDir(a, dir);
}

fn homeDir(a: Allocator) ?[:0]const u8 {
    var environ_map = global.environMap() catch return null;
    defer environ_map.deinit();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = (internal_os.home(global.io(), &environ_map, &buf) catch return null) orelse return null;
    return a.dupeSentinel(u8, home, 0) catch null;
}

/// Where a saved window goes: its rectangle, pulled into a monitor's work
/// area when its top edge (its caption) is out of reach there or it is
/// bigger than the work area.
fn placementOf(sw: SavedWindow) ?c.WINDOWPLACEMENT {
    // Past this a rectangle isn't one Windows made (and the sums below
    // stay in range).
    const limit = 1 << 20;
    for ([_]i32{ sw.left, sw.top, sw.right, sw.bottom }) |v| if (@abs(v) > limit) return null;
    if (sw.right <= sw.left or sw.bottom <= sw.top) return null;
    const off = workOffset();
    var screen: c.RECT = .{ .left = sw.left + off.x, .top = sw.top + off.y, .right = sw.right + off.x, .bottom = sw.bottom + off.y };
    var mi: c.MONITORINFO = .{};
    if (c.MonitorFromRect(&screen, c.MONITOR_DEFAULTTONEAREST)) |m| if (c.GetMonitorInfoW(m, &mi) != 0) {
        const work = mi.rcWork;
        const ww = work.right - work.left;
        const wh = work.bottom - work.top;
        var w = screen.right - screen.left;
        var h = screen.bottom - screen.top;
        // Room enough on the work area to take the caption by the mouse.
        const grab = 48;
        const reachable = screen.top >= work.top and screen.top <= work.bottom - grab and
            screen.right >= work.left + grab and screen.left <= work.right - grab;
        if (!reachable or w > ww or h > wh) {
            w = @min(w, ww);
            h = @min(h, wh);
            const x = std.math.clamp(screen.left, work.left, work.right - w);
            const y = std.math.clamp(screen.top, work.top, work.bottom - h);
            screen = .{ .left = x, .top = y, .right = x + w, .bottom = y + h };
        }
    };
    return .{ .showCmd = c.SW_HIDE, .rcNormalPosition = .{
        .left = screen.left - off.x,
        .top = screen.top - off.y,
        .right = screen.right - off.x,
        .bottom = screen.bottom - off.y,
    } };
}

/// Workspace coordinates' origin on the screen: the primary monitor's
/// work area's corner (WINDOWPLACEMENT's rectangles are in them).
fn workOffset() c.POINT {
    var primary: c.MONITORINFO = .{};
    const origin: c.POINT = .{ .x = 0, .y = 0 };
    if (c.MonitorFromPoint(origin, c.MONITOR_DEFAULTTOPRIMARY)) |m| if (c.GetMonitorInfoW(m, &primary) != 0) {
        return .{ .x = primary.rcWork.left - primary.rcMonitor.left, .y = primary.rcWork.top - primary.rcMonitor.top };
    };
    return origin;
}

// ---------------------------------------------------------------- saving

/// Something changed: a snapshot soon (coalescing a burst of changes).
pub fn changed(self: *Session) void {
    if (!self.enabled or self.frozen or self.restoring) return;
    _ = c.SetTimer(self.app.wakeup_hwnd, timer_id, soon_ms, null);
}

/// A restore ended: what came is saved (soon, from the timer: a restore
/// can run inside a core callback).
fn restored(self: *Session) void {
    self.restoring = false;
    self.changed();
}

/// The timer: the snapshot asked for, or the poll's.
pub fn tick(self: *Session) void {
    _ = c.SetTimer(self.app.wakeup_hwnd, timer_id, poll_ms, null);
    if (self.marker_until) |t| if (c.GetTickCount64() >= t) self.clearMarker();
    if (self.frozen) return;
    self.notices();
    if (!self.enabled or self.restoring or self.dragging()) return;
    self.save(.fresh);
    if (c.GetTickCount64() >= self.gc_next) self.collectGarbage();
}

/// What waits to be said, once murrtty runs with a window and no dialog
/// is open: a session put aside, a failure.
fn notices(self: *Session) void {
    if (!self.app.started or self.app.modal_depth > 0) return;
    const window = for (self.app.windows.items) |w| {
        if (w.quick == null and w.tabs.items.len > 0) break w;
    } else return;
    // On murrtty's software OpenGL, its notice takes this one along once
    // the first frame is drawn (software_gl.tick): one toast, not two.
    if (self.app.software_start) |s| if (!s.told) return;
    var buf: [400]u8 = undefined;
    if (self.takeSkipNotice(&buf)) |text| window.showToastFor(text, notice_ms);
    if (self.warn_pending) |reason| {
        self.warn_pending = null;
        self.showWarning(reason);
    }
}

/// The notice that the last session was put aside, into `buf`, if it is
/// still to be said (once).
pub fn takeSkipNotice(self: *Session, buf: []u8) ?[]const u8 {
    if (!self.skip_notice) return null;
    self.skip_notice = false;
    var arena: std.heap.ArenaAllocator = .init(self.app.core_app.alloc);
    defer arena.deinit();
    const aside: []const u8 = self.fileName(arena.allocator(), "-skipped.json") catch "session-skipped.json";
    return std.fmt.bufPrint(buf, "Your last session wasn't restored: restoring it failed. It's kept as {s}.", .{std.fs.path.basenameWindows(aside)}) catch
        "Your last session wasn't restored: restoring it failed.";
}

/// murrtty quits (Quit, the session ending): the state written a last
/// time, then left as it is. The directories are those last read (no
/// renderer lock now: Windows' messages can come while the UI thread holds
/// it), and a failure is only logged: no dialog on the way out.
pub fn freeze(self: *Session) void {
    self.clearMarker();
    self.ending = false;
    if (self.frozen) return;
    self.frozen = true;
    _ = c.KillTimer(self.app.wakeup_hwnd, timer_id);
    if (self.enabled and !self.dragging()) self.save(.cached);
}

/// Windows asks whether its session may end (WM_QUERYENDSESSION): frozen
/// before the shells end and their panes close, until it ends or
/// `endCancelled` says it goes on.
pub fn queryEnd(self: *Session) void {
    if (self.frozen) return;
    self.freeze();
    self.ending = true;
}

pub fn endCancelled(self: *Session) void {
    if (!self.ending) return;
    self.ending = false;
    self.frozen = false;
    _ = c.SetTimer(self.app.wakeup_hwnd, timer_id, poll_ms, null);
    self.changed();
}

/// Whether something is being dragged: a window moved or sized, a divider,
/// a tab, a pane.
fn dragging(self: *const Session) bool {
    if (self.app.pane_drag != null) return true;
    for (self.app.windows.items) |w| {
        if (w.in_size_move) return true;
        if (w.tab_drag) |d| if (d.dragging) return true;
        for (w.tabs.items) |t| if (t.drag != null) return true;
    }
    return false;
}

/// Whether a snapshot reads each pane's directory afresh (taking the
/// renderer's lock) or takes the one last read.
const Read = enum { fresh, cached };

/// The snapshot, written if it differs from what was last. Nothing before
/// murrtty has started: a start that fails (no OpenGL, its dialog's loop
/// running the timer) leaves the file as it was.
fn save(self: *Session, read: Read) void {
    if (!self.app.started) return;
    const alloc = self.app.core_app.alloc;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const state = self.snapshot(a, read) catch |err| {
        log.warn("no snapshot of the session err={}", .{err});
        return;
    };
    const text = std.json.Stringify.valueAlloc(a, state, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }) catch return;
    if (self.last) |l| if (std.mem.eql(u8, l, text)) return;
    const path = self.fileName(a, ".json") catch return;
    self.write(a, path, text) catch |err| {
        self.warn(path, err);
        return;
    };
    self.failures = 0;
    const copy = alloc.dupe(u8, text) catch return;
    if (self.last) |l| alloc.free(l);
    self.last = copy;
}

/// The windows as they are, and what waits to come back.
fn snapshot(self: *Session, a: Allocator, read: Read) !State {
    var windows: std.ArrayList(SavedWindow) = .empty;
    var front: ?u32 = null;
    const front_id = self.app.last_window orelse 0;
    const front_hwnd = if (self.liveWindow(front_id)) null else self.topWindow();
    var quick_live = false;
    for (self.app.windows.items) |w| {
        if (w.tabs.items.len == 0) continue;
        if (w.quick != null) quick_live = true;
        if (w.id == front_id or (front_hwnd != null and w.hwnd == front_hwnd.?)) {
            front = @intCast(windows.items.len);
        }
        try windows.append(a, try saveWindow(a, w, read));
    }
    // What waits to come back stays saved, and what failed to.
    if (self.pending) |p| {
        const saved = p.value.windows;
        if (self.pending_windows) for (saved) |sw| {
            if (!sw.quick) try windows.append(a, sw);
        };
        if (self.pending_quick) |i| if (!quick_live and i < saved.len) try windows.append(a, saved[i]);
        for (self.unrestored.items) |i| if (i < saved.len and !(saved[i].quick and quick_live)) {
            try windows.append(a, saved[i]);
        };
    }
    return .{ .front = front, .windows = windows.items };
}

/// Whether a window (not the quick terminal) with this id is open. Ids
/// start at 1.
fn liveWindow(self: *const Session, id: u64) bool {
    for (self.app.windows.items) |w| if (w.id == id and w.quick == null) return true;
    return false;
}

/// The topmost of murrtty's windows (not the quick terminal) in the
/// z-order: the front one while none was activated (a restored front
/// window before it has the keyboard).
fn topWindow(self: *const Session) ?c.HWND {
    var next = c.GetTopWindow(null);
    var steps: usize = 0;
    while (next) |hwnd| : (steps += 1) {
        if (steps > 10000) break;
        for (self.app.windows.items) |w| {
            if (w.hwnd == hwnd and w.quick == null and w.tabs.items.len > 0) return hwnd;
        }
        next = c.GetWindow(hwnd, c.GW_HWNDNEXT);
    }
    return null;
}

fn saveWindow(a: Allocator, w: *Window, read: Read) !SavedWindow {
    var out: SavedWindow = .{ .quick = w.quick != null, .active = @intCast(w.active) };
    if (w.title_override) |n| out.name = try a.dupe(u8, n);
    if (w.quick == null) {
        var wp: c.WINDOWPLACEMENT = .{};
        if (w.fullscreen) |saved| {
            wp = saved.placement;
            out.fullscreen = true;
        } else {
            _ = c.GetWindowPlacement(w.hwnd, &wp);
            // A window shown normally is saved where it is: one snapped to
            // a side or corner has its pre-snap rectangle there.
            var actual: c.RECT = .{};
            if (wp.showCmd == c.SW_SHOWNORMAL and c.GetWindowRect(w.hwnd, &actual) != 0) {
                const off = workOffset();
                wp.rcNormalPosition = .{
                    .left = actual.left - off.x,
                    .top = actual.top - off.y,
                    .right = actual.right - off.x,
                    .bottom = actual.bottom - off.y,
                };
            }
        }
        const r = wp.rcNormalPosition;
        out.left = r.left;
        out.top = r.top;
        out.right = r.right;
        out.bottom = r.bottom;
        out.maximized = wp.showCmd == c.SW_SHOWMAXIMIZED or
            (wp.showCmd == c.SW_SHOWMINIMIZED and wp.flags & c.WPF_RESTORETOMAXIMIZED != 0);
    }
    const tabs = try a.alloc(SavedTab, w.tabs.items.len);
    for (w.tabs.items, tabs) |t, *st| st.* = try saveTab(a, t, read);
    out.tabs = tabs;
    return out;
}

fn saveTab(a: Allocator, t: *Tab, read: Read) !SavedTab {
    const nodes = try a.alloc(SavedNode, t.tree.nodes.len);
    for (t.tree.nodes, nodes) |n, *out| out.* = switch (n) {
        .leaf => |s| .{ .pane = try savePane(a, s, read) },
        .split => |s| .{ .split = .{
            .layout = if (s.layout == .horizontal) .horizontal else .vertical,
            .ratio = @floatCast(s.ratio),
            .left = @intCast(s.left.idx()),
            .right = @intCast(s.right.idx()),
        } },
    };
    var out: SavedTab = .{ .nodes = nodes };
    if (t.tree.locate(t.focused)) |h| out.focused = @intCast(h.idx());
    if (t.title_override) |n| out.name = try a.dupe(u8, n);
    return out;
}

fn savePane(a: Allocator, s: *Surface, read: Read) !SavedPane {
    var out: SavedPane = .{ .id = try a.dupe(u8, &s.session_id) };
    // The directory read now is kept for the saves that can't read it; one
    // the shell no longer knows keeps the last known.
    if (read == .fresh and s.core_initialized) fresh: {
        const dir = (s.core_surface.pwd(a) catch break :fresh) orelse break :fresh;
        if (s.session_dir) |old| if (std.mem.eql(u8, old, dir)) break :fresh;
        const alloc = s.app.core_app.alloc;
        const copy = alloc.dupe(u8, dir) catch break :fresh;
        if (s.session_dir) |old| alloc.free(old);
        s.session_dir = copy;
    }
    if (s.session_dir) |d| out.directory = try a.dupe(u8, d);
    if (s.title_override) |n| out.name = try a.dupe(u8, n);
    if (s.program) |p| if (ownShell(p)) {
        out.program = switch (p) {
            .shell => |v| .{ .shell = try a.dupe(u8, v) },
            .direct => |argv| .{ .direct = argv: {
                const copy = try a.alloc([]const u8, argv.len);
                for (argv, copy) |arg, *o| o.* = try a.dupe(u8, arg);
                break :argv copy;
            } },
        };
    };
    return out;
}

/// Whether a pane's program is a shell of its own, which comes back with
/// it, rather than a one-off command (`ssh host`, `-e`), whose pane comes
/// back with the configured shell.
pub fn ownShell(cmd: configpkg.Command) bool {
    const first: []const u8 = switch (cmd) {
        .direct => |argv| if (argv.len > 0) argv[0] else return false,
        .shell => |s| first: {
            const t = std.mem.trim(u8, s, " \t");
            if (t.len > 0 and t[0] == '"') {
                const end = std.mem.indexOfScalarPos(u8, t, 1, '"') orelse t.len;
                break :first t[1..end];
            }
            break :first t[0 .. std.mem.indexOfAny(u8, t, " \t") orelse t.len];
        },
    };
    var name = std.fs.path.basenameWindows(first);
    if (std.ascii.endsWithIgnoreCase(name, ".exe")) name = name[0 .. name.len - 4];
    for ([_][]const u8{ "cmd", "powershell", "pwsh", "wsl", "bash", "zsh", "fish", "nu", "elvish", "xonsh" }) |shell| {
        if (std.ascii.eqlIgnoreCase(name, shell)) return true;
    }
    return false;
}

/// Write `text` to `path` whole: a file beside it, then in its place. The
/// folder is made if it is missing.
fn write(self: *Session, a: Allocator, path: []const u8, text: []const u8) !void {
    if (self.dir) |d| try makeDirs(a, d);
    try writeFile(a, path, text);
}

/// A write that failed: logged always, said in a dialog once a run when
/// writes keep failing (with a window and no dialog open; else as soon as
/// that holds).
fn warn(self: *Session, path: []const u8, err: anyerror) void {
    log.warn("the session couldn't be saved to {s} err={}", .{ path, err });
    self.failures += 1;
    if (self.warned or self.frozen or self.failures < warn_after) return;
    self.warned = true;
    const reason = switch (err) {
        error.AccessDenied => "access is denied",
        error.Busy => "another program is using it",
        error.Full => "the disk is full",
        error.NoFolder => "its folder can't be made",
        else => "Windows couldn't write it",
    };
    self.warn_pending = reason;
    self.notices();
}

fn showWarning(self: *Session, reason: []const u8) void {
    const alloc = self.app.core_app.alloc;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const body = if (self.fileName(a, ".json")) |path|
        std.fmt.allocPrint(a, "murrtty can't save its session to {s}: {s}. It keeps trying; until it can, closing murrtty loses the windows' layout.", .{ path, reason }) catch return
    else |_|
        std.fmt.allocPrint(a, "murrtty can't save its session: {s}. Closing murrtty loses the windows' layout.", .{reason}) catch return;
    test_hooks.recordDialog(&self.app.test_state, "Session Not Saved", body);
    const owner: ?c.HWND = for (self.app.windows.items) |w| {
        if (w.quick == null) break w.hwnd;
    } else null;
    var modal = self.app.beginModal(owner, .{});
    defer modal.end();
    _ = AlertDialog.run(alloc, .{
        .owner = owner,
        .heading = "Session Not Saved",
        .body = body,
        .responses = &.{.{ .id = c.IDCANCEL, .label = "Close" }},
        .default = c.IDCANCEL,
        .dark = self.app.chromeTheme().dark,
    });
}

// ---------------------------------------------------------------- files

/// Whether `path` is surely not there (not just unreadable now).
fn missing(a: Allocator, path: []const u8) bool {
    const w = text_util.utf16Lossy(a, path) catch return false;
    if (c.GetFileAttributesW(w.ptr) != 0xFFFFFFFF) return false;
    const err = c.GetLastError();
    return err == 2 or err == 3; // ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND
}

fn exists(a: Allocator, path: []const u8) bool {
    const w = text_util.utf16Lossy(a, path) catch return false;
    return c.GetFileAttributesW(w.ptr) != 0xFFFFFFFF;
}

fn isDir(a: Allocator, path: []const u8) bool {
    const w = text_util.utf16Lossy(a, path) catch return false;
    const attrs = c.GetFileAttributesW(w.ptr);
    return attrs != 0xFFFFFFFF and attrs & 0x10 != 0;
}

fn deleteFile(a: Allocator, path: []const u8) void {
    const w = text_util.utf16Lossy(a, path) catch return;
    _ = c.DeleteFileW(w.ptr);
}

fn moveFile(a: Allocator, from: []const u8, to: []const u8) bool {
    const f = text_util.utf16Lossy(a, from) catch return false;
    const t = text_util.utf16Lossy(a, to) catch return false;
    return c.MoveFileExW(f.ptr, t.ptr, c.MOVEFILE_REPLACE_EXISTING) != 0;
}

/// The file at `path`, or null (absent, unreadable, too big).
fn readFile(a: Allocator, path: []const u8) ?[]u8 {
    const w = text_util.utf16Lossy(a, path) catch return null;
    const handle = c.CreateFileW(w.ptr, c.GENERIC_READ, c.FILE_SHARE_READ | c.FILE_SHARE_WRITE | c.FILE_SHARE_DELETE, null, c.OPEN_EXISTING, c.FILE_ATTRIBUTE_NORMAL, null);
    if (handle == c.INVALID_HANDLE_VALUE) return null;
    defer _ = c.CloseHandle(handle);
    var out: std.ArrayList(u8) = .empty;
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        var n: c.DWORD = 0;
        if (c.ReadFile(handle, &buf, buf.len, &n, null) == 0) return null;
        if (n == 0) break;
        out.appendSlice(a, buf[0..n]) catch return null;
        if (out.items.len > max_file) return null;
    }
    return out.items;
}

/// Write `text` to `path` through a file beside it, flushed, then moved
/// over it, so a failure leaves the old file whole.
fn writeFile(a: Allocator, path: []const u8, text: []const u8) !void {
    const dest = try text_util.utf16Lossy(a, path);
    const tmp = try std.mem.concatWithSentinel(a, u16, &.{ dest, c.L(".tmp") }, 0);
    const handle = c.CreateFileW(tmp.ptr, c.GENERIC_WRITE, 0, null, c.CREATE_ALWAYS, c.FILE_ATTRIBUTE_NORMAL, null);
    if (handle == c.INVALID_HANDLE_VALUE) return errorOf(c.GetLastError());
    var ok = true;
    var err: c.DWORD = 0;
    var off: usize = 0;
    while (off < text.len) {
        var n: c.DWORD = 0;
        const chunk: c.DWORD = @intCast(@min(text.len - off, 1 << 20));
        if (c.WriteFile(handle, text[off..].ptr, chunk, &n, null) == 0 or n == 0) {
            err = c.GetLastError();
            ok = false;
            break;
        }
        off += n;
    }
    if (ok and c.FlushFileBuffers(handle) == 0) {
        err = c.GetLastError();
        ok = false;
    }
    _ = c.CloseHandle(handle);
    if (!ok) {
        _ = c.DeleteFileW(tmp.ptr);
        return errorOf(err);
    }
    if (c.MoveFileExW(tmp.ptr, dest.ptr, c.MOVEFILE_REPLACE_EXISTING | c.MOVEFILE_WRITE_THROUGH) == 0) {
        err = c.GetLastError();
        _ = c.DeleteFileW(tmp.ptr);
        return errorOf(err);
    }
}

fn errorOf(err: c.DWORD) anyerror {
    return switch (err) {
        c.ERROR_ACCESS_DENIED => error.AccessDenied,
        c.ERROR_SHARING_VIOLATION => error.Busy,
        3 => error.NoFolder, // ERROR_PATH_NOT_FOUND
        112 => error.Full, // ERROR_DISK_FULL
        else => error.WriteFailed,
    };
}

/// Make `dir` and the folders above it that are missing. A file in a
/// folder's place fails it.
fn makeDirs(a: Allocator, dir: []const u8) !void {
    if (isDir(a, dir)) return;
    // A UNC path's server and share are never made: past them.
    var i: usize = 0;
    if (std.mem.startsWith(u8, dir, "\\\\")) {
        var seps: usize = 0;
        i = 2;
        while (i < dir.len) : (i += 1) if (dir[i] == '\\') {
            seps += 1;
            if (seps == 2) break;
        };
        i += 1;
    }
    while (i <= dir.len) : (i += 1) {
        if (i < dir.len and dir[i] != '\\') continue;
        const part = dir[0..i];
        // Past the drive ("C:") and a UNC share's server and share.
        if (part.len <= 3 or std.mem.endsWith(u8, part, ":")) continue;
        const w = try text_util.utf16Lossy(a, part);
        if (c.CreateDirectoryW(w.ptr, null) == 0) {
            const err = c.GetLastError();
            // ERROR_ALREADY_EXISTS for a file in the folder's place.
            if (!isDir(a, part)) return if (err == 183) error.NoFolder else errorOf(err);
        }
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "Session: a saved tree is checked before it is built" {
    const a = testing.allocator;
    const pane: SavedNode = .{ .pane = .{ .id = "0123456789abcdef" } };
    try validate(a, &.{pane});
    try validate(a, &.{ .{ .split = .{ .left = 1, .right = 2 } }, pane, pane });
    // Out of range, a cycle, a node reached twice, neither or both.
    try testing.expectError(error.BadTree, validate(a, &.{.{ .split = .{ .left = 1, .right = 5 } }}));
    try testing.expectError(error.BadTree, validate(a, &.{ .{ .split = .{ .left = 0, .right = 1 } }, pane }));
    try testing.expectError(error.BadTree, validate(a, &.{ .{ .split = .{ .left = 1, .right = 1 } }, pane }));
    try testing.expectError(error.BadTree, validate(a, &.{.{}}));
    try testing.expectError(error.BadTree, validate(a, &.{}));
    try testing.expectEqual(@as(usize, 2), leftmost(&.{ .{ .split = .{ .left = 2, .right = 1 } }, pane, pane }, 0));
}

test "Session: the state reads back as it was written" {
    const a = testing.allocator;
    const nodes = [_]SavedNode{
        .{ .split = .{ .layout = .vertical, .ratio = 0.25, .left = 1, .right = 2 } },
        .{ .pane = .{ .id = "0123456789abcdef", .directory = "C:\\Users\\x", .name = "logs" } },
        .{ .pane = .{ .id = "fedcba9876543210", .program = .{ .direct = &.{ "wsl.exe", "-d", "Ubuntu" } } } },
    };
    const tabs = [_]SavedTab{.{ .name = "work", .focused = 2, .nodes = &nodes }};
    const windows = [_]SavedWindow{.{ .name = "main", .left = 10, .top = 20, .right = 980, .bottom = 700, .maximized = true, .tabs = &tabs }};
    const state: State = .{ .front = 0, .windows = &windows };
    const text = try std.json.Stringify.valueAlloc(a, state, .{ .emit_null_optional_fields = false });
    defer a.free(text);
    const parsed = try std.json.parseFromSlice(State, a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    defer parsed.deinit();
    const w = parsed.value.windows[0];
    try testing.expectEqualStrings("main", w.name.?);
    try testing.expect(w.maximized and w.right == 980);
    const t = w.tabs[0];
    try testing.expectEqual(@as(u32, 2), t.focused);
    try testing.expectEqual(@as(f32, 0.25), t.nodes[0].split.?.ratio);
    try testing.expectEqualStrings("C:\\Users\\x", t.nodes[1].pane.?.directory.?);
    try testing.expectEqualStrings("Ubuntu", t.nodes[2].pane.?.program.?.direct[2]);
    try validate(a, t.nodes);
    // A newer murrtty's fields are passed over.
    const newer = try std.json.parseFromSlice(State, a, "{\"version\":2,\"windows\":[],\"tomorrow\":1}", .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    defer newer.deinit();
    try testing.expectEqual(@as(usize, 0), newer.value.windows.len);
}

test "Session: a shell of its own comes back, a one-off command doesn't" {
    try testing.expect(ownShell(.{ .direct = &.{ "C:\\Windows\\System32\\wsl.exe", "-d", "Ubuntu" } }));
    try testing.expect(ownShell(.{ .direct = &.{"cmd.exe"} }));
    try testing.expect(ownShell(.{ .shell = "\"C:\\Program Files\\PowerShell\\7\\pwsh.exe\" -NoLogo" }));
    try testing.expect(ownShell(.{ .shell = "pwsh -NoLogo" }));
    try testing.expect(!ownShell(.{ .direct = &.{ "ssh", "host" } }));
    try testing.expect(!ownShell(.{ .shell = "vim notes.txt" }));
    try testing.expect(!ownShell(.{ .direct = &.{} }));
}

test "Session: a pane's Clink history label" {
    const id: Id = "0123456789abcdef".*;
    const label = clinkLabel(id);
    try testing.expectEqualStrings("murrtty0123456789abcdef", &label);
    // Clink takes up to 32 letters and digits.
    try testing.expect(label.len <= 32);
    for (label) |ch| try testing.expect(std.ascii.isAlphanumeric(ch));
    // Clink 1.9 names it clink_history-<label> (`clink info` says so).
    const pattern = try clinkPattern(testing.allocator, "C:\\p", id);
    defer testing.allocator.free(pattern);
    try testing.expectEqualStrings("C:\\p\\clink_history-murrtty0123456789abcdef*", pattern);
}

test "Session: a waiting pane's history cut and cleaned" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Fine as it is: nothing to change.
    try testing.expect(try trimHistory(a, "echo 1\necho 2\n", 5) == null);
    // Five commands, the second on two lines, cut to the last three.
    const five = "echo 1\nfirst `\nsecond\necho 3\r\necho 4\necho 5\n";
    try testing.expectEqualStrings("echo 3\necho 4\necho 5\n", (try trimHistory(a, five, 3)).?);
    // A command on two lines is kept whole.
    try testing.expectEqualStrings("first `\nsecond\necho 3\necho 4\necho 5\n", (try trimHistory(a, five, 4)).?);
    // A line a cut-short write left with NUL bytes goes.
    try testing.expectEqualStrings("echo 1\necho 2\n", (try trimHistory(a, "echo 1\n\x00\x00\x00\necho 2\n", 5)).?);
}

test "Session: the history folder's files" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    const txt = historyFile(L("0123456789abcdef.txt")).?;
    try testing.expect(txt.kind == .txt and std.mem.eql(u8, &txt.id, "0123456789abcdef"));
    try testing.expect(historyFile(L("0123456789abcdef.clink")).?.kind == .clink);
    try testing.expect(historyFile(L("0123456789abcdeg.txt")) == null);
    try testing.expect(historyFile(L("0123456789abcdef.txt.tmp")) == null);
    try testing.expect(historyFile(L("notes.txt")) == null);
}

test "Session: pane ids" {
    try testing.expect(paneId(.{ .id = "0123456789abcdef" }) != null);
    try testing.expect(paneId(.{ .id = "0123" }) == null);
    try testing.expect(paneId(.{ .id = "0123456789abcdeg" }) == null);
    const id = newId();
    try testing.expect(paneId(.{ .id = &id }) != null);
}
