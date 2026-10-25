//! A tab: its terminal panes, as a split tree, in a container window that
//! parents the panes' windows. The window shows one tab's container and
//! hides the others. (Until splits land a tab has one pane.)
const Tab = @This();

const std = @import("std");
const apprt = @import("../../apprt.zig");
const CoreSurface = @import("../../Surface.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;

const c = @import("c.zig");
const Window = @import("Window.zig");
const Surface = @import("Surface.zig");

const log = std.log.scoped(.win32_tab);

pub const class_name = c.L("GhosttyTab");

pub const Tree = SplitTree(Surface);

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

/// Size the panes' windows to the container.
fn layoutPanes(self: *Tab) void {
    var r: c.RECT = .{};
    _ = c.GetClientRect(self.hwnd, &r);
    const flags = c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_NOCOPYBITS;
    var it = self.tree.iterator();
    while (it.next()) |entry| {
        _ = c.SetWindowPos(entry.view.hwnd, null, 0, 0, r.right, r.bottom, flags);
    }
}

/// Fill what the panes don't cover yet (while resizing) with the
/// terminal's background rather than leaving it black. WS_CLIPCHILDREN
/// keeps this off the panes.
fn paint(self: *Tab) void {
    var ps: c.PAINTSTRUCT = undefined;
    const hdc = c.BeginPaint(self.hwnd, &ps) orelse return;
    defer _ = c.EndPaint(self.hwnd, &ps);
    const bg = self.focused.colors.bg;
    if (c.CreateSolidBrush(c.rgb(bg.r, bg.g, bg.b))) |brush| {
        defer _ = c.DeleteObject(brush);
        _ = c.FillRect(hdc, &ps.rcPaint, brush);
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
