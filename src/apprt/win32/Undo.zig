//! Undo and redo of closes (roadmap 5.11), macOS's (GTK has none): a pane,
//! tab or window closed (not by its program ending) is parked, its
//! processes running, in the shelf, a window never shown and not among
//! App.windows, for `undo-timeout`. Undo brings the latest close back where
//! it was; redo closes it again. One app-wide history, as macOS's
//! AppDelegate.undoManager, and a close of several things (close_tab:other
//! or :right, close_all_windows) is one entry. Entries expire with their
//! timeout, and what they parked is freed then, from the message loop.
const Undo = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("c.zig");
const App = @import("App.zig");
const PaneDrag = @import("PaneDrag.zig");
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.win32_undo);

/// The wakeup window's timer that expires entries.
pub const timer_id = 0x5B11;

/// What an entry undoes, as macOS names them.
pub const Name = enum { close_terminal, close_tab, close_tabs, close_window, close_all_windows, close_all_but };

app: *App,
/// Where parked tabs live; made at the first park (Window.createShelf).
shelf: ?*Window = null,
undos: std.ArrayList(Entry) = .empty,
redos: std.ArrayList(Entry) = .empty,
/// A close of several things, recorded as one entry, and how deep in
/// begin/end calls (a redo of closes runs closes that group too).
group: ?Entry = null,
group_depth: u32 = 0,
/// Undo or redo running: undo records nothing, redo's closes go on the
/// undo history without clearing redo's.
replaying: enum { none, undo, redo } = .none,
timer_on: bool = false,

pub const Entry = struct {
    name: Name,
    /// When it was recorded (GetTickCount64).
    since: u64,
    ops: std.ArrayList(Op) = .empty,

    fn deinit(self: *Entry, undo: *Undo) void {
        for (self.ops.items) |*op| op.deinit(undo);
        self.ops.deinit(undo.alloc());
    }
};

const Op = union(enum) {
    /// A closed split's pane, parked as a tab of its own: back into the tab
    /// holding `beside` (a pane that stayed), as `tree` had it if that tab's
    /// panes are still its others; else beside that tab's focused pane, or
    /// a tab of its own in `window` (or a new window).
    pane: struct { parked: *Tab, beside: ?u64, window: u64, tree: Tab.Tree },
    /// A closed tab: back into `window` at `index`, or a new window.
    tab: struct { parked: *Tab, window: u64, index: usize },
    /// A closed window: its tabs, in a new window where it was.
    window: struct { tabs: std.ArrayList(*Tab), placement: c.WINDOWPLACEMENT, active: usize },
    /// Redo's: close again, by a pane's core id or a window's id.
    close_pane: u64,
    close_tab: u64,
    close_window: u64,

    fn deinit(self: *Op, undo: *Undo) void {
        switch (self.*) {
            .pane => |*p| {
                p.tree.deinit();
                undo.free(p.parked);
            },
            .tab => |p| undo.free(p.parked),
            .window => |*p| {
                for (p.tabs.items) |t| undo.free(t);
                p.tabs.deinit(undo.alloc());
            },
            .close_pane, .close_tab, .close_window => {},
        }
    }
};

fn alloc(self: *const Undo) Allocator {
    return self.app.core_app.alloc;
}

/// Whether closes park now: an undo-timeout, and murrtty not quitting.
pub fn enabled(self: *const Undo) bool {
    return self.timeoutMs() > 0 and !self.app.quitting;
}

fn timeoutMs(self: *const Undo) u64 {
    return self.app.config.@"undo-timeout".asMilliseconds();
}

pub fn canUndo(self: *const Undo) bool {
    return self.undos.items.len > 0;
}

pub fn canRedo(self: *const Undo) bool {
    return self.redos.items.len > 0;
}

/// The entries, oldest first (the GUI tests' dump).
pub fn entries(self: *const Undo, which: enum { undo, redo }) []const Entry {
    return switch (which) {
        .undo => self.undos.items,
        .redo => self.redos.items,
    };
}

/// How many tabs are parked.
pub fn parkedCount(self: *const Undo) usize {
    return if (self.shelf) |s| s.tabs.items.len else 0;
}

/// Several closes (`name`) to record as one entry, until `end`.
pub fn begin(self: *Undo, name: Name) void {
    self.group_depth += 1;
    if (self.group == null) self.group = .{ .name = name, .since = c.GetTickCount64() };
}

pub fn end(self: *Undo) void {
    self.group_depth -|= 1;
    if (self.group_depth > 0) return;
    var g = self.group orelse return;
    self.group = null;
    if (g.ops.items.len == 0) return g.deinit(self);
    self.undos.append(self.alloc(), g) catch {
        g.deinit(self);
        return;
    };
    self.armTimer();
}

/// Room for one op of a close named `name`: in the group, else in an entry
/// of its own. A close the user made (not redo's) clears the redo history.
fn slot(self: *Undo, name: Name) !*Op {
    if (self.replaying == .none) self.clearRedos();
    const a = self.alloc();
    if (self.group) |*g| return try g.ops.addOne(a);
    try self.undos.ensureUnusedCapacity(a, 1);
    var e: Entry = .{ .name = name, .since = c.GetTickCount64() };
    _ = try e.ops.addOne(a);
    self.undos.appendAssumeCapacity(e);
    return &self.undos.items[self.undos.items.len - 1].ops.items[0];
}

/// Take back the slot just made, unfilled.
fn dropSlot(self: *Undo) void {
    if (self.group) |*g| {
        _ = g.ops.pop();
        return;
    }
    var e = self.undos.pop() orelse return;
    e.ops.deinit(self.alloc());
}

fn shelfWindow(self: *Undo) !*Window {
    if (self.shelf) |s| return s;
    self.shelf = try Window.createShelf(self.app);
    return self.shelf.?;
}

/// Close pane `surface` of split tab `tab` into the shelf. Returns whether
/// the tab's focus moved (as closePane), or null if it couldn't be parked:
/// then nothing changed, and the caller closes it for good.
pub fn parkPane(self: *Undo, tab: *Tab, surface: *Surface) ?bool {
    const a = self.alloc();
    const shelf = self.shelfWindow() catch return null;
    shelf.tabs.ensureUnusedCapacity(a, 1) catch return null;
    var old = tab.tree.clone(a) catch return null;
    old.zoomed = null;
    var single = Tab.Tree.init(a, surface) catch {
        old.deinit();
        return null;
    };
    const parked = Tab.createEmpty(shelf) catch {
        single.deinit();
        old.deinit();
        return null;
    };
    const op = self.slot(.close_terminal) catch {
        parked.destroy(true);
        single.deinit();
        old.deinit();
        return null;
    };
    // A drag of it or over it ends here, while it can still be found.
    if (surface.core_initialized) PaneDrag.surfaceGone(self.app, surface.core_surface.id);
    // A pane that stays, to find the tab by again.
    var beside: ?u64 = null;
    var it = tab.tree.iterator();
    while (it.next()) |entry| if (entry.view != surface and entry.view.core_initialized) {
        beside = entry.view.core_surface.id;
        break;
    };
    const refocus = tab.detach(surface) catch {
        self.dropSlot();
        parked.destroy(true);
        single.deinit();
        old.deinit();
        return null;
    };
    parked.hold(surface, single);
    shelf.tabs.appendAssumeCapacity(parked);
    tab.layoutPanes();
    op.* = .{ .pane = .{ .parked = parked, .beside = beside, .window = tab.window.id, .tree = old } };
    self.armTimer();
    // A parked pane waits for no one (its bell would visit nothing).
    self.app.waiting.prune(self.app);
    return refocus;
}

/// Close tab `index` of `window` (not its last) into the shelf. False if it
/// couldn't be parked: then it is still there, and the caller frees it.
pub fn parkTab(self: *Undo, window: *Window, index: usize) bool {
    const shelf = self.shelfWindow() catch return false;
    shelf.tabs.ensureUnusedCapacity(self.alloc(), 1) catch return false;
    const op = self.slot(.close_tab) catch return false;
    PaneDrag.tabGoing(self.app, window.tabs.items[index]);
    const tab = window.tabs.orderedRemove(index);
    shelf.shelve(tab);
    op.* = .{ .tab = .{ .parked = tab, .window = window.id, .index = index } };
    self.armTimer();
    self.app.waiting.prune(self.app);
    return true;
}

/// Take every tab of `window`, which is closing (its destroy follows), into
/// the shelf, with its place on the screen. Not the quick terminal's: it
/// opens again from its toggle. Left as they are if they couldn't be
/// parked (the window's destroy frees them).
pub fn parkWindow(self: *Undo, window: *Window) void {
    if (window.quick != null or window.tabs.items.len == 0) return;
    const a = self.alloc();
    const shelf = self.shelfWindow() catch return;
    shelf.tabs.ensureUnusedCapacity(a, window.tabs.items.len) catch return;
    var tabs = std.ArrayList(*Tab).initCapacity(a, window.tabs.items.len) catch return;
    const op = self.slot(.close_window) catch {
        tabs.deinit(a);
        return;
    };
    PaneDrag.windowGoing(self.app, window);
    var placement: c.WINDOWPLACEMENT = .{ .length = @sizeOf(c.WINDOWPLACEMENT) };
    _ = c.GetWindowPlacement(window.hwnd, &placement);
    for (window.tabs.items) |t| {
        shelf.shelve(t);
        tabs.appendAssumeCapacity(t);
    }
    window.tabs.clearRetainingCapacity();
    op.* = .{ .window = .{ .tabs = tabs, .placement = placement, .active = window.active } };
    self.armTimer();
    self.app.waiting.prune(self.app);
}

/// Undo the latest close. From the message loop (App.Request).
pub fn runUndo(self: *Undo) void {
    var entry = self.undos.pop() orelse return;
    defer entry.ops.deinit(self.alloc());
    var redo: Entry = .{ .name = entry.name, .since = c.GetTickCount64() };
    self.replaying = .undo;
    defer self.replaying = .none;
    var i = entry.ops.items.len;
    while (i > 0) {
        i -= 1;
        const inverse = self.restore(&entry.ops.items[i]) orelse continue;
        redo.ops.append(self.alloc(), inverse) catch {};
    }
    if (redo.ops.items.len == 0) return redo.deinit(self);
    self.redos.append(self.alloc(), redo) catch return redo.deinit(self);
    self.armTimer();
}

/// Redo the latest undone close: close it again, at once (no question, as
/// macOS's). From the message loop.
pub fn runRedo(self: *Undo) void {
    var entry = self.redos.pop() orelse return;
    defer entry.deinit(self);
    self.replaying = .redo;
    defer self.replaying = .none;
    self.begin(entry.name);
    defer self.end();
    var i = entry.ops.items.len;
    while (i > 0) {
        i -= 1;
        switch (entry.ops.items[i]) {
            .close_pane => |id| if (self.app.findSurface(id)) |s| s.window.closeSurface(s, false),
            .close_tab => |id| if (self.app.findSurface(id)) |s| s.window.closeTabsNow(s, .this),
            .close_window => |id| if (self.app.findWindow(id)) |w| w.closeNow(),
            .pane, .tab, .window => {},
        }
    }
}

/// Bring back what `op` parked (taking it from the op), returning redo's
/// op that closes it again; null if it is lost (out of memory).
fn restore(self: *Undo, op: *Op) ?Op {
    const taken = op.*;
    // What it held is the windows' again (or freed).
    op.* = .{ .close_pane = 0 };
    switch (taken) {
        .pane => |p| {
            const id = paneId(p.parked) orelse 0;
            self.unshelve(p.parked);
            // Its tab gone (or full of others): a tab of its own.
            if (!self.restorePane(p.parked, p.tree, p.beside) and
                !self.restoreTab(p.parked, p.window, null)) return null;
            return .{ .close_pane = id };
        },
        .tab => |p| {
            const id = paneId(p.parked) orelse 0;
            self.unshelve(p.parked);
            if (!self.restoreTab(p.parked, p.window, p.index)) return null;
            return .{ .close_tab = id };
        },
        .window => |p| {
            var tabs = p.tabs;
            defer tabs.deinit(self.alloc());
            for (tabs.items) |t| self.unshelve(t);
            const w = Window.createRestored(self.app, p.placement, tabs.items, p.active) catch |err| {
                log.warn("error reopening a window err={}", .{err});
                for (tabs.items) |t| t.destroy(true);
                return null;
            };
            return .{ .close_window = w.id };
        },
        .close_pane, .close_tab, .close_window => return null,
    }
}

/// Parked tab `parked`'s pane back into the tab holding pane `beside`: as
/// `tree` had them if that tab's panes are still the others of it, else
/// beside its focused pane; `parked` goes. Takes `tree`. False, with
/// `parked` as it was, if that pane is gone or there was no room.
fn restorePane(self: *Undo, parked: *Tab, tree: Tab.Tree, beside: ?u64) bool {
    var old = tree;
    const surface = parked.focused;
    const found: ?*Surface = if (beside) |id| self.app.findSurface(id) else null;
    const b = found orelse {
        old.deinit();
        return false;
    };
    const window = b.window;
    const index = window.tabIndexOf(b) orelse {
        old.deinit();
        return false;
    };
    const tab = window.tabs.items[index];
    if (sameOthers(&tab.tree, &old, surface)) {
        tab.takeTree(surface, old);
    } else {
        old.deinit();
        tab.insertPane(surface, tab.focused, .right) catch |err| {
            log.warn("error putting a pane back err={}", .{err});
            return false;
        };
    }
    // Emptied: its pane is the tab's now.
    parked.tree.deinit();
    parked.tree = .empty;
    parked.destroy(true);
    if (index != window.active) window.select(index);
    return true;
}

/// Whether `tree` holds just `current`'s panes and `extra`.
fn sameOthers(current: *const Tab.Tree, tree: *const Tab.Tree, extra: *const Surface) bool {
    var count: usize = 0;
    var it = tree.iterator();
    var has_extra = false;
    while (it.next()) |entry| {
        count += 1;
        if (entry.view == extra) {
            has_extra = true;
            continue;
        }
        if (current.locate(entry.view) == null) return false;
    }
    var current_count: usize = 0;
    var cit = current.iterator();
    while (cit.next()) |_| current_count += 1;
    return has_extra and count == current_count + 1;
}

/// `tab` into window `window` at `index` (or after its active tab), else
/// into a new window. False if it couldn't (then it is freed).
fn restoreTab(self: *Undo, tab: *Tab, window: u64, index: ?usize) bool {
    if (self.app.findWindow(window)) |w| if (w.quick == null) {
        w.restoreTab(tab, index orelse w.active + 1) catch |err| {
            log.warn("error putting a tab back err={}", .{err});
            tab.destroy(true);
            return false;
        };
        return true;
    };
    _ = Window.createRestored(self.app, null, &.{tab}, 0) catch |err| {
        log.warn("error reopening a tab err={}", .{err});
        tab.destroy(true);
        return false;
    };
    return true;
}

fn paneId(tab: *const Tab) ?u64 {
    return if (tab.focused.core_initialized) tab.focused.core_surface.id else null;
}

/// Take `tab` out of the shelf's list (the caller places or frees it).
fn unshelve(self: *Undo, tab: *Tab) void {
    const shelf = self.shelf orelse return;
    if (std.mem.indexOfScalar(*Tab, shelf.tabs.items, tab)) |i| _ = shelf.tabs.orderedRemove(i);
}

/// Free parked `tab` and its panes.
fn free(self: *Undo, tab: *Tab) void {
    self.unshelve(tab);
    tab.destroy(true);
}

/// A parked pane's program ended (the core asked to close it, and no
/// window has it): it closes for good. A tab it leaves empty goes, with
/// what would bring it back.
pub fn surfaceExited(self: *Undo, id: u64) void {
    const shelf = self.shelf orelse return;
    const tab, const surface = found: for (shelf.tabs.items) |t| {
        var it = t.tree.iterator();
        while (it.next()) |entry| if (entry.view.core_initialized and entry.view.core_surface.id == id) {
            break :found .{ t, entry.view };
        };
    } else return;
    if (tab.tree.isSplit()) {
        _ = tab.closePane(surface) catch |err| log.warn("error closing a parked pane err={}", .{err});
        return;
    }
    self.forget(tab);
    self.free(tab);
}

/// Drop what would bring `tab` back (it is going).
fn forget(self: *Undo, tab: *Tab) void {
    for ([_]*std.ArrayList(Entry){ &self.undos, &self.redos }) |list| {
        var e: usize = 0;
        while (e < list.items.len) {
            const entry = &list.items[e];
            var o: usize = 0;
            while (o < entry.ops.items.len) {
                const op = &entry.ops.items[o];
                const drop = switch (op.*) {
                    .pane => |*p| if (p.parked == tab) blk: {
                        p.tree.deinit();
                        break :blk true;
                    } else false,
                    .tab => |p| p.parked == tab,
                    .window => |*p| blk: {
                        if (std.mem.indexOfScalar(*Tab, p.tabs.items, tab)) |i| {
                            _ = p.tabs.orderedRemove(i);
                            // The same tab active, unless it was this one.
                            if (i < p.active) p.active -= 1;
                            if (p.active >= p.tabs.items.len) p.active = p.tabs.items.len -| 1;
                        }
                        if (p.tabs.items.len > 0) break :blk false;
                        p.tabs.deinit(self.alloc());
                        break :blk true;
                    },
                    else => false,
                };
                if (drop) _ = entry.ops.orderedRemove(o) else o += 1;
            }
            if (entry.ops.items.len == 0) {
                var gone = list.orderedRemove(e);
                gone.ops.deinit(self.alloc());
            } else e += 1;
        }
    }
}

fn clearRedos(self: *Undo) void {
    for (self.redos.items) |*e| e.deinit(self);
    self.redos.clearRetainingCapacity();
}

/// Forget everything, freeing what is parked (murrtty quitting, its last
/// window closed).
pub fn clear(self: *Undo) void {
    for (self.undos.items) |*e| e.deinit(self);
    self.undos.clearRetainingCapacity();
    self.clearRedos();
    // A close still being recorded (the last window going inside it): what
    // it parked so far goes too, and its end finds nothing to keep.
    if (self.group) |*g| {
        for (g.ops.items) |*op| op.deinit(self);
        g.ops.clearRetainingCapacity();
    }
    self.disarmTimer();
}

pub fn deinit(self: *Undo) void {
    self.clear();
    if (self.group) |*g| g.ops.deinit(self.alloc());
    self.group = null;
    self.undos.deinit(self.alloc());
    self.redos.deinit(self.alloc());
    if (self.shelf) |s| s.destroy();
    self.shelf = null;
}

fn armTimer(self: *Undo) void {
    if (self.timer_on) return;
    if (c.SetTimer(self.app.wakeup_hwnd, timer_id, 500, null) != 0) self.timer_on = true;
}

fn disarmTimer(self: *Undo) void {
    if (!self.timer_on) return;
    _ = c.KillTimer(self.app.wakeup_hwnd, timer_id);
    self.timer_on = false;
}

/// The timer: entries past undo-timeout go, with what they parked. Not
/// while a dialog is open (its loop runs timers too).
pub fn tick(self: *Undo) void {
    if (self.app.modal_depth > 0 or self.group != null) return;
    const now = c.GetTickCount64();
    const ms = self.timeoutMs();
    for ([_]*std.ArrayList(Entry){ &self.undos, &self.redos }) |list| {
        while (list.items.len > 0 and now -% list.items[0].since >= ms) {
            var e = list.orderedRemove(0);
            e.deinit(self);
        }
    }
    if (self.undos.items.len == 0 and self.redos.items.len == 0) self.disarmTimer();
}
