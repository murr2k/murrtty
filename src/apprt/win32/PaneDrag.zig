//! Dragging a pane to another place (roadmap 1.10), GTK's: a press on its
//! drag handle along its top (drag-handle `always`, or `auto` while its tab
//! is split) starts a drag. Over another pane, the half nearest the pointer
//! is where it goes (shown in the accent, as GTK's drop overlay), and the
//! release moves it there, into that pane's tab, in any window. Over a tab
//! in a tab row, that tab comes forward after a moment, as libadwaita's tab
//! bar does for things dragged over tabs. Escape cancels; losing the mouse
//! ends the drag. One drag at a time: App.pane_drag.
const PaneDrag = @This();

const std = @import("std");

const c = @import("c.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.win32_pane_drag);

pub const Direction = Tab.Tree.Split.Direction;

/// The source pane's timer for tab hovering.
pub const timer_id = 0x5A10;
/// A tab hovered this long comes forward (libadwaita's timeout).
const tab_hover_ms = 500;

/// The pane dragged, by core surface id (it can close mid-drag).
source: u64,
/// Where the press was, in screen pixels.
start: c.POINT,
/// Past the system's drag distance.
dragging: bool = false,
/// Escape: nothing moves, and the source keeps the mouse until the
/// release, which then goes nowhere (the terminal never saw the press).
cancelled: bool = false,
/// The pane under the pointer and the side it would go to.
target: ?u64 = null,
dir: Direction = .right,
/// A tab under the pointer that isn't its window's active one, and since
/// when. The tab is only compared, never followed: it may have closed.
hover: ?struct { window: u64, tab: *Tab, since: u64 } = null,

/// A press on `source`'s handle at `screen`.
pub fn begin(app: *App, source: *Surface, screen: c.POINT) void {
    if (!source.core_initialized) return;
    if (app.pane_drag != null) end(app);
    app.pane_drag = .{ .source = source.core_surface.id, .start = screen };
    _ = c.SetCapture(source.hwnd);
}

/// The pointer at `screen` while the button is held.
pub fn move(app: *App, screen: c.POINT) void {
    const d = if (app.pane_drag) |*p| p else return;
    if (d.cancelled) return;
    if (!d.dragging) {
        const dx = @abs(screen.x - d.start.x);
        const dy = @abs(screen.y - d.start.y);
        if (dx <= c.GetSystemMetrics(c.SM_CXDRAG) and dy <= c.GetSystemMetrics(c.SM_CYDRAG)) return;
        d.dragging = true;
        if (app.findSurface(d.source)) |s| _ = c.SetTimer(s.hwnd, timer_id, 100, null);
    }
    // Over a pane: the side nearest the pointer; never the pane itself.
    var target: ?*Surface = null;
    var dir: Direction = .right;
    if (paneAt(app, screen)) |s| if (s.core_initialized and s.core_surface.id != d.source) {
        var pt = screen;
        _ = c.ScreenToClient(s.hwnd, &pt);
        target = s;
        dir = direction(s.size.width, s.size.height, pt.x, pt.y);
    };
    const target_id: ?u64 = if (target) |s| s.core_surface.id else null;
    if (target_id != d.target or (target != null and dir != d.dir)) {
        if (d.target) |old| if (app.findSurface(old)) |s| s.setDropOverlay(null);
        if (target) |s| s.setDropOverlay(dir);
        d.target = target_id;
        d.dir = dir;
    }
    _ = c.SetCursor(c.LoadCursorW(null, if (target != null) c.IDC_SIZEALL else c.IDC_NO));
    // Over another tab of a tab row: it comes forward after a moment.
    if (tabAt(app, screen)) |t| {
        const same = if (d.hover) |h| h.window == t.window.id and h.tab == t.tab else false;
        if (!same) d.hover = .{ .window = t.window.id, .tab = t.tab, .since = c.GetTickCount64() };
    } else d.hover = null;
}

/// The timer: a tab hovered long enough comes forward.
pub fn tick(app: *App) void {
    const d = if (app.pane_drag) |*p| p else return;
    const h = d.hover orelse return;
    if (c.GetTickCount64() -% h.since < tab_hover_ms) return;
    d.hover = null;
    const w = findWindow(app, h.window) orelse return;
    const index = std.mem.indexOfScalar(*Tab, w.tabs.items, h.tab) orelse return;
    if (index == w.active) return;
    // The source keeps the mouse while its tab hides (Windows leaves a
    // child's capture alone when its parent hides).
    w.select(index);
}

/// The release: the pane moves where the overlay showed.
pub fn finish(app: *App) void {
    const d = app.pane_drag orelse return;
    end(app);
    if (!d.dragging or d.cancelled) return;
    const target_id = d.target orelse return;
    const source = app.findSurface(d.source) orelse return;
    const target = app.findSurface(target_id) orelse return;
    const window = target.window;
    const index = window.tabIndexOf(target) orelse return;
    const from_window = source.window;
    const had_keyboard = if (c.GetFocus()) |f| f == source.hwnd or c.IsChild(source.hwnd, f) != 0 else false;
    window.tabs.items[index].movePane(source, target, d.dir) catch |err| {
        log.warn("error moving a pane err={}", .{err});
        return;
    };
    // The keyboard stays where it was, as GTK's, and no window comes
    // forward; unless it went with the pane into another window, when it
    // goes to its old window's focused pane.
    if (had_keyboard and window != from_window) from_window.focusActive();
}

/// Escape: the marks go and nothing will move; the release ends it.
pub fn cancel(app: *App) void {
    const d = if (app.pane_drag) |*p| p else return;
    if (d.target) |id| if (app.findSurface(id)) |s| s.setDropOverlay(null);
    d.target = null;
    d.hover = null;
    d.cancelled = true;
    _ = c.SetCursor(c.LoadCursorW(null, c.IDC_ARROW));
}

/// The source lost the mouse (a dialog, another program): the drag ends.
pub fn abort(app: *App) void {
    end(app);
}

/// A pane closes: a drag of it ends; one over it goes on over nothing.
pub fn surfaceGone(app: *App, id: u64) void {
    const d = if (app.pane_drag) |*p| p else return;
    if (d.source == id) return end(app);
    if (d.target == id) d.target = null;
}

/// `window` is about to free its panes, its trees still whole: as
/// surfaceGone for each, before anything walks a freed tree (end looks
/// panes up in every window's).
pub fn windowGoing(app: *App, window: *Window) void {
    if (app.pane_drag == null) return;
    var it = window.panes();
    while (it.next()) |s| if (s.core_initialized) surfaceGone(app, s.core_surface.id);
}

/// The same for one tab.
pub fn tabGoing(app: *App, tab: *Tab) void {
    if (app.pane_drag == null) return;
    var it = tab.tree.iterator();
    while (it.next()) |entry| if (entry.view.core_initialized) surfaceGone(app, entry.view.core_surface.id);
}

fn end(app: *App) void {
    const d = app.pane_drag orelse return;
    // Cleared first: releasing the capture comes back as WM_CAPTURECHANGED.
    app.pane_drag = null;
    if (d.target) |id| if (app.findSurface(id)) |s| s.setDropOverlay(null);
    if (app.findSurface(d.source)) |s| {
        // The pointer is elsewhere now.
        s.setHandleHover(false);
        _ = c.KillTimer(s.hwnd, timer_id);
        if (c.GetCapture() == s.hwnd) _ = c.ReleaseCapture();
    }
}

/// The pane whose window (or a child of it: its search box, an overlay)
/// is at `screen`, visible, in any of murrtty's windows.
fn paneAt(app: *App, screen: c.POINT) ?*Surface {
    var h: ?c.HWND = c.WindowFromPoint(screen);
    while (h) |hwnd| : (h = c.GetParent(hwnd)) {
        for (app.windows.items) |w| {
            var it = w.panes();
            while (it.next()) |s| if (s.hwnd == hwnd) {
                return if (c.IsWindowVisible(hwnd) != 0) s else null;
            };
        }
    }
    return null;
}

/// The tab of a tab row at `screen`, if it isn't its window's active one.
fn tabAt(app: *App, screen: c.POINT) ?struct { window: *Window, tab: *Tab } {
    const hit = c.WindowFromPoint(screen) orelse return null;
    const root = c.GetAncestor(hit, c.GA_ROOT) orelse hit;
    for (app.windows.items) |w| if (w.hwnd == root) {
        const i = w.tabAtScreen(screen) orelse return null;
        return if (i != w.active) .{ .window = w, .tab = w.tabs.items[i] } else null;
    };
    return null;
}

fn findWindow(app: *App, id: u64) ?*Window {
    for (app.windows.items) |w| if (w.id == id) return w;
    return null;
}

/// GTK's calcDropDirection: the side of the pane nearest (`x`, `y`).
pub fn direction(width: u32, height: u32, x: i32, y: i32) Direction {
    const w: f64 = @floatFromInt(@max(width, 1));
    const h: f64 = @floatFromInt(@max(height, 1));
    const l = @as(f64, @floatFromInt(x)) / w;
    const t = @as(f64, @floatFromInt(y)) / h;
    const r = 1 - l;
    const b = 1 - t;
    const min = @min(@min(l, t), @min(r, b));
    if (min == l) return .left;
    if (min == r) return .right;
    if (min == t) return .up;
    return .down;
}

test "direction: the nearest side" {
    const testing = std.testing;
    try testing.expectEqual(Direction.left, direction(100, 100, 10, 50));
    try testing.expectEqual(Direction.right, direction(100, 100, 90, 50));
    try testing.expectEqual(Direction.up, direction(100, 100, 50, 10));
    try testing.expectEqual(Direction.down, direction(100, 100, 50, 90));
    // A wide pane: its middle third is up or down.
    try testing.expectEqual(Direction.down, direction(400, 100, 200, 80));
}
