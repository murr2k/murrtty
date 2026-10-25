//! A tab: its terminal panes, as a split tree, in a container window that
//! parents the panes' windows and paints the dividers between them. The
//! window shows one tab's container and hides the others.
const Tab = @This();

const std = @import("std");
const apprt = @import("../../apprt.zig");
const CoreSurface = @import("../../Surface.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;

const c = @import("c.zig");
const split_layout = @import("split_layout.zig");
const Window = @import("Window.zig");
const Surface = @import("Surface.zig");

const log = std.log.scoped(.win32_tab);

pub const class_name = c.L("GhosttyTab");

pub const Tree = SplitTree(Surface);
pub const Layout = split_layout.Layout(Surface);

window: *Window,
hwnd: c.HWND,

/// The panes. Surface's ref and unref do nothing: the tree is only an
/// index of the layout, and panes are freed solely by the close queue
/// (App.Request), never wherever a tree reference happens to drop (which
/// could be inside a core callback).
tree: Tree = .empty,

/// The pane that has the focus, or had it last.
focused: *Surface,

/// Bumped whenever panes are added or removed, so an operation that
/// started before (a divider drag) can tell that its panes changed.
generation: u64 = 0,

pub fn registerClass(instance: c.HINSTANCE) !void {
    const wc: c.WNDCLASSEXW = .{
        .lpfnWndProc = &wndProc,
        .hInstance = instance,
        .hCursor = c.LoadCursorW(null, c.IDC_ARROW),
        .lpszClassName = class_name,
    };
    if (c.RegisterClassExW(&wc) == 0) return error.RegisterClassFailed;
}

/// Create a tab in `window` at `rect` (in the window's client area) with
/// one new pane.
pub fn create(
    window: *Window,
    rect: c.RECT,
    parent: ?*CoreSurface,
    context: apprt.surface.NewSurfaceContext,
) !*Tab {
    const app = window.app;
    const alloc = app.core_app.alloc;
    const self = try alloc.create(Tab);
    errdefer alloc.destroy(self);
    self.* = .{ .window = window, .hwnd = undefined, .focused = undefined };

    self.hwnd = c.CreateWindowExW(
        0,
        class_name,
        c.L(""),
        c.WS_CHILD | c.WS_VISIBLE | c.WS_CLIPSIBLINGS | c.WS_CLIPCHILDREN,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        window.hwnd,
        null,
        app.instance,
        self,
    ) orelse {
        log.err("failed to create tab window err={}", .{c.GetLastError()});
        return error.CreateWindowFailed;
    };
    // Destroys the pane's window with it.
    errdefer {
        _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA, 0);
        _ = c.DestroyWindow(self.hwnd);
    }

    const surface = try alloc.create(Surface);
    errdefer alloc.destroy(surface);
    try surface.init(app, window, self.hwnd, context, parent, .{
        .right = rect.right - rect.left,
        .bottom = rect.bottom - rect.top,
    });
    errdefer surface.deinit();

    self.tree = try Tree.init(alloc, surface);
    self.focused = surface;
    return self;
}

/// Free the panes and the tab. `destroy_window` is false while the window
/// is being destroyed, which destroys its child windows itself.
pub fn destroy(self: *Tab, destroy_window: bool) void {
    const alloc = self.window.app.core_app.alloc;
    _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA, 0);

    // Take the panes out of the tree before freeing them.
    var freeing: std.ArrayList(*Surface) = .empty;
    defer freeing.deinit(alloc);
    var it = self.tree.iterator();
    while (it.next()) |entry| freeing.append(alloc, entry.view) catch {
        // Out of memory: free this one now; the tree's unref is a no-op.
        entry.view.deinit();
        alloc.destroy(entry.view);
    };
    self.tree.deinit();
    for (freeing.items) |s| {
        s.deinit();
        alloc.destroy(s);
    }

    // The panes' renderers have stopped, so their windows can go.
    if (destroy_window) _ = c.DestroyWindow(self.hwnd);
    alloc.destroy(self);
}

/// The panes, in tree order.
pub fn panes(self: *const Tab) Tree.Iterator {
    return self.tree.iterator();
}

pub fn contains(self: *const Tab, surface: *const Surface) bool {
    return self.tree.locate(surface) != null;
}

/// The tab's title: its focused pane's.
pub fn title(self: *const Tab) []const u8 {
    return self.focused.title orelse "Ghostty";
}

/// Show or hide the tab (tab switches, minimize). Hidden panes tell the
/// core they are occluded, so their renderers stop drawing.
pub fn setVisible(self: *Tab, visible: bool) void {
    if (visible) _ = c.ShowWindow(self.hwnd, c.SW_SHOW);
    var it = self.tree.iterator();
    while (it.next()) |entry| entry.view.setVisible(visible);
    if (!visible) _ = c.ShowWindow(self.hwnd, c.SW_HIDE);
}

/// Split pane `at`: a new pane `direction` of it, inheriting from `parent`
/// (a new split's config, font size and so on), created at its final
/// rectangle. The tab's focus doesn't move; the caller decides.
pub fn newSplit(
    self: *Tab,
    at: *Surface,
    direction: apprt.action.SplitDirection,
    parent: *CoreSurface,
) !*Surface {
    const app = self.window.app;
    const alloc = app.core_app.alloc;
    const handle = self.tree.locate(at) orelse return error.PaneNotFound;
    const dir: Tree.Split.Direction = switch (direction) {
        .right => .right,
        .down => .down,
        .left => .left,
        .up => .up,
    };
    const rect = try self.newPaneRect(handle, dir);

    const surface = try alloc.create(Surface);
    errdefer alloc.destroy(surface);
    try surface.init(app, self.window, self.hwnd, .split, parent, rect);
    errdefer {
        surface.deinit();
        _ = c.DestroyWindow(surface.hwnd);
    }

    var single = try Tree.init(alloc, surface);
    defer single.deinit();
    const next = try self.tree.split(alloc, handle, dir, 0.5, &single);
    self.tree.deinit();
    self.tree = next;
    self.generation +%= 1;
    self.layoutPanes();
    return surface;
}

/// Where a new pane split off `at` in `dir` will go: lay out the split
/// with `at`'s pane standing in for the new one (a new split inherits its
/// font, so its minimum size).
fn newPaneRect(self: *Tab, at: Tree.Node.Handle, dir: Tree.Split.Direction) !c.RECT {
    const alloc = self.window.app.core_app.alloc;
    const stand_in = switch (self.tree.nodes[at.idx()]) {
        .leaf => |v| v,
        .split => return error.PaneNotFound,
    };
    var single = try Tree.init(alloc, stand_in);
    defer single.deinit();
    var trial = try self.tree.split(alloc, at, dir, 0.5, &single);
    defer trial.deinit();
    var layout = try Layout.compute(alloc, &trial, self.area(), self.dividerWidth());
    defer layout.deinit(alloc);
    // SplitTree.split puts the inserted tree right after the old nodes.
    for (layout.panes) |p| if (p.handle.idx() == self.tree.nodes.len) return toRect(p.rect);
    return error.PaneNotFound;
}

/// Remove pane `surface` from the tab (never its last pane) and free it.
/// If it was the tab's focused pane, the one before it, else the one after
/// it, becomes focused. Returns whether the focused pane changed.
pub fn closePane(self: *Tab, surface: *Surface) !bool {
    const alloc = self.window.app.core_app.alloc;
    const handle = self.tree.locate(surface) orelse return false;
    const refocus = self.focused == surface;
    const focus = if (refocus)
        (try Layout.focusAfterClose(alloc, &self.tree, handle)) orelse return error.LastPane
    else
        self.focused;

    const next = try self.tree.remove(alloc, handle);
    self.tree.deinit();
    self.tree = next;
    self.focused = focus;
    self.generation +%= 1;

    // Its renderer stops before its window goes. Destroying a window with
    // the focus moves it to the container, which hands it to `focus`.
    const hwnd = surface.hwnd;
    surface.deinit();
    alloc.destroy(surface);
    _ = c.DestroyWindow(hwnd);
    self.layoutPanes();
    return refocus;
}

/// Lay out the panes' windows in the container, all in one step, and
/// repaint the dividers.
pub fn layoutPanes(self: *Tab) void {
    const alloc = self.window.app.core_app.alloc;
    var layout = Layout.compute(alloc, &self.tree, self.area(), self.dividerWidth()) catch |err| {
        log.err("error laying out panes err={}", .{err});
        return;
    };
    defer layout.deinit(alloc);

    const flags = c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_NOCOPYBITS;
    var hdwp = c.BeginDeferWindowPos(@intCast(layout.panes.len));
    for (layout.panes) |p| {
        const r = toRect(p.rect);
        if (hdwp) |h| {
            hdwp = c.DeferWindowPos(h, p.view.hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, flags);
        }
        // If deferring failed (it then frees the batch), move it directly.
        if (hdwp == null) _ = c.SetWindowPos(p.view.hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, flags);
    }
    if (hdwp) |h| _ = c.EndDeferWindowPos(h);
    // WS_CLIPCHILDREN limits this to the dividers and any gap.
    _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
}

/// The container's client area, for the layout.
pub fn area(self: *const Tab) split_layout.Rect {
    var r: c.RECT = .{};
    _ = c.GetClientRect(self.hwnd, &r);
    return .{ .right = r.right, .bottom = r.bottom };
}

pub fn dividerWidth(self: *const Tab) i32 {
    return split_layout.dividerWidth(c.GetDpiForWindow(self.hwnd));
}

fn toRect(r: split_layout.Rect) c.RECT {
    return .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.bottom };
}

/// The dividers' color: `split-divider-color`, else macOS's rule, the
/// focused pane's background darkened 40% on a dark theme, 8% on a light
/// one.
fn dividerColor(self: *const Tab) c.COLORREF {
    if (self.window.app.config.@"split-divider-color") |col| return c.rgb(col.r, col.g, col.b);
    const bg = self.focused.colors.bg;
    const keep: f32 = if (Window.isDark(bg)) 0.6 else 0.92;
    return c.rgb(
        @intFromFloat(@as(f32, @floatFromInt(bg.r)) * keep),
        @intFromFloat(@as(f32, @floatFromInt(bg.g)) * keep),
        @intFromFloat(@as(f32, @floatFromInt(bg.b)) * keep),
    );
}

/// Paint the dividers, and fill what the panes don't cover yet (while
/// resizing) with the terminal's background rather than leaving it black.
/// WS_CLIPCHILDREN keeps this off the panes.
fn paint(self: *Tab) void {
    var ps: c.PAINTSTRUCT = undefined;
    const hdc = c.BeginPaint(self.hwnd, &ps) orelse return;
    defer _ = c.EndPaint(self.hwnd, &ps);
    const bg = self.focused.colors.bg;
    if (c.CreateSolidBrush(c.rgb(bg.r, bg.g, bg.b))) |brush| {
        defer _ = c.DeleteObject(brush);
        _ = c.FillRect(hdc, &ps.rcPaint, brush);
    }
    if (!self.tree.isSplit()) return;

    const alloc = self.window.app.core_app.alloc;
    var layout = Layout.compute(alloc, &self.tree, self.area(), self.dividerWidth()) catch return;
    defer layout.deinit(alloc);
    const brush = c.CreateSolidBrush(self.dividerColor()) orelse return;
    defer _ = c.DeleteObject(brush);
    for (layout.splits) |s| {
        const r = toRect(s.divider);
        _ = c.FillRect(hdc, &r, brush);
    }
}

fn fromHwnd(hwnd: c.HWND) ?*Tab {
    const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (ptr == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(ptr)));
}

fn wndProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (msg == c.WM_NCCREATE) {
        const cs: *const c.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(cs.lpCreateParams)));
        return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const self = fromHwnd(hwnd) orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    switch (msg) {
        c.WM_ERASEBKGND => return 1,

        c.WM_PAINT => {
            self.paint();
            return 0;
        },

        c.WM_SIZE => {
            if (wparam != c.SIZE_MINIMIZED) self.layoutPanes();
            return 0;
        },

        // The container itself never keeps the focus: it gets it when a
        // focused pane is destroyed, say.
        c.WM_SETFOCUS => {
            if (!self.tree.isEmpty()) _ = c.SetFocus(self.focused.hwnd);
            return 0;
        },

        else => return c.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
