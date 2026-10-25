//! A top-level window. Each window hosts one or more tabs (Tab.zig), each
//! a container of terminal panes; only the active tab's container is shown.
const Window = @This();

const std = @import("std");
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const CoreSurface = @import("../../Surface.zig");

const c = @import("c.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const TabBar = @import("TabBar.zig");

const log = std.log.scoped(.win32_window);

pub const class_name = c.L("GhosttyWindow");

/// Default client size in device-independent pixels.
const default_width = 960;
const default_height = 600;

app: *App,
hwnd: c.HWND,

/// Identifies the window in App requests, which may outlive it.
id: u64,

/// The tabs, in display order, and the selected one.
tabs: std.ArrayList(*Tab) = .empty,
active: usize = 0,

tab_bar: TabBar = .{},

/// Client size limits from the core, in device pixels.
size_limit: ?apprt.action.SizeLimit = null,

/// Saved placement and style while fullscreen.
fullscreen: ?Saved = null,

/// What applyChrome last set, for the GUI tests' state dump.
chrome: Chrome = .{},

pub const Chrome = struct {
    dark: bool = false,
    /// The caption color, or null for the system's.
    caption: ?c.COLORREF = null,
};

const Saved = struct {
    placement: c.WINDOWPLACEMENT,
    style: isize,
};

pub fn registerClass(instance: c.HINSTANCE) !void {
    const wc: c.WNDCLASSEXW = .{
        .lpfnWndProc = &wndProc,
        .hInstance = instance,
        .hIcon = c.LoadIconW(instance, 1),
        .hCursor = c.LoadCursorW(null, c.IDC_ARROW),
        .lpszClassName = class_name,
    };
    if (c.RegisterClassExW(&wc) == 0) return error.RegisterClassFailed;
}

/// Create and show a new window with a single tab.
pub fn create(app: *App, parent: ?*CoreSurface) !*Window {
    const alloc = app.core_app.alloc;
    const self = try alloc.create(Window);
    errdefer alloc.destroy(self);
    self.* = .{ .app = app, .hwnd = undefined, .id = app.next_window_id };
    app.next_window_id += 1;

    self.hwnd = c.CreateWindowExW(
        c.WS_EX_APPWINDOW,
        class_name,
        c.L("Ghostty"),
        c.WS_OVERLAPPEDWINDOW | c.WS_CLIPCHILDREN,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        default_width,
        default_height,
        null,
        null,
        app.instance,
        self,
    ) orelse {
        log.err("failed to create window err={}", .{c.GetLastError()});
        return error.CreateWindowFailed;
    };
    errdefer {
        _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA, 0);
        _ = c.DestroyWindow(self.hwnd);
        self.tabs.deinit(alloc);
        self.tab_bar.deinit();
    }

    // Size the client area for the monitor's DPI (setClientSize scales).
    self.tab_bar.setDpi(c.GetDpiForWindow(self.hwnd));
    self.setClientSize(default_width, default_height);
    self.applyChrome();

    try app.windows.append(alloc, self);
    errdefer _ = app.windows.pop();

    _ = try self.addTab(parent, .window);

    const config = &app.config;
    _ = c.ShowWindow(self.hwnd, if (config.maximize) c.SW_SHOWMAXIMIZED else c.SW_SHOWNORMAL);
    if (config.fullscreen != .false) self.toggleFullscreen();
    _ = c.SetForegroundWindow(self.hwnd);
    self.focusActive();

    return self;
}

/// Add a tab after the active one and select it. Returns its pane.
pub fn addTab(
    self: *Window,
    parent: ?*CoreSurface,
    context: apprt.surface.NewSurfaceContext,
) !*Surface {
    const alloc = self.app.core_app.alloc;

    // Make room for the tab bar first so the new pane starts at its
    // final size.
    const index = if (self.tabs.items.len == 0) 0 else self.active + 1;
    try self.tabs.ensureUnusedCapacity(alloc, 1);
    const had_bar = self.tabBarVisible();

    const tab = try Tab.create(self, self.tabRect(self.tabs.items.len + 1), parent, context);
    self.tabs.insertAssumeCapacity(index, tab);
    if (had_bar != self.tabBarVisible()) _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
    self.select(index);
    return tab.focused;
}

/// Close a pane, confirming first if `confirm` and a process is running.
/// Closing a tab's last pane closes the tab, and the last tab the window.
/// Only call this from the message loop (see App.Request), never from
/// inside a core callback.
pub fn closeSurface(self: *Window, surface: *Surface, confirm: bool) void {
    if (confirm and self.needsConfirm(surface) and !self.app.confirm(
        self.hwnd,
        "A process is still running in this terminal. Close it anyway?",
        "Ghostty: Close Tab",
    )) return;

    const index = self.tabIndexOf(surface) orelse return;
    const tab = self.tabs.items[index];
    if (!tab.tree.isSplit()) {
        _ = self.removeTab(index);
        return;
    }

    // Closing a background pane leaves the focus alone; the focused pane's
    // passes to its neighbor.
    const refocus = tab.closePane(surface) catch |err| {
        log.err("error closing pane err={}", .{err});
        return;
    };
    if (refocus and index == self.active) {
        self.focusActive();
        self.syncTitle();
        self.applyChrome();
    }
    self.invalidateTabBar();
}

/// Split `surface`'s pane for the new_split action: the new pane opens
/// `direction` of it and takes the focus. Runs inside a core callback,
/// which is fine for creating a pane (the core's focus change is deferred).
pub fn newSplit(self: *Window, surface: *Surface, direction: apprt.action.SplitDirection) !void {
    const index = self.tabIndexOf(surface) orelse return error.PaneNotFound;
    const tab = self.tabs.items[index];
    const pane = try tab.newSplit(surface, direction, &surface.core_surface);
    tab.focused = pane;
    if (index == self.active) {
        self.focusActive();
        self.syncTitle();
        self.applyChrome();
    }
    self.invalidateTabBar();
}

/// A pane got the keyboard focus: it becomes its tab's focused pane, whose
/// title and colors the tab and the window show.
pub fn surfaceFocused(self: *Window, surface: *Surface) void {
    const index = self.tabIndexOf(surface) orelse return;
    const tab = self.tabs.items[index];
    if (tab.focused == surface) return;
    tab.focused = surface;
    if (index == self.active) {
        self.syncTitle();
        self.applyChrome();
    }
    self.invalidateTabBar();
    // The dividers follow the focused pane's background.
    _ = c.InvalidateRect(tab.hwnd, null, c.FALSE);
}

fn invalidateTabBar(self: *Window) void {
    if (!self.tabBarVisible()) return;
    var r = self.tabBarRect();
    _ = c.InvalidateRect(self.hwnd, &r, c.FALSE);
}

/// Close tabs relative to the one holding `surface`, for the close_tab
/// action, confirming first if a process is running in any of them.
pub fn closeTabs(self: *Window, surface: *Surface, mode: apprt.action.CloseTabMode) void {
    const index = self.tabIndexOf(surface) orelse return;
    const alloc = self.app.core_app.alloc;
    var targets: std.ArrayList(*Tab) = .empty;
    defer targets.deinit(alloc);
    for (self.tabs.items, 0..) |t, i| {
        const close = switch (mode) {
            .this => i == index,
            .other => i != index,
            .right => i > index,
        };
        if (close) targets.append(alloc, t) catch return;
    }
    if (targets.items.len == 0) return;

    var confirm = false;
    for (targets.items) |t| confirm = confirm or self.tabNeedsConfirm(t);
    if (confirm and !self.app.confirm(
        self.hwnd,
        if (mode == .this)
            "A process is still running in this terminal. Close it anyway?"
        else
            "Processes are still running in the tabs being closed. Close them anyway?",
        if (mode == .this) "Ghostty: Close Tab" else "Ghostty: Close Tabs",
    )) return;

    for (targets.items) |t| {
        const i = std.mem.indexOfScalar(*Tab, self.tabs.items, t) orelse continue;
        if (self.removeTab(i) == .window_destroyed) return;
    }
}

/// Remove tab `index` and free its panes. Removing the last tab destroys
/// the window, which frees `self`: callers must return at once.
fn removeTab(self: *Window, index: usize) enum { removed, window_destroyed } {
    if (self.tabs.items.len == 1) {
        self.destroy();
        return .window_destroyed;
    }

    const tab = self.tabs.orderedRemove(index);
    tab.destroy(true);

    if (self.active > index or self.active >= self.tabs.items.len) {
        self.active -|= 1;
    }
    self.select(self.active);
    _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
    return .removed;
}

fn tabNeedsConfirm(self: *Window, tab: *const Tab) bool {
    var it = tab.panes();
    while (it.next()) |entry| if (self.needsConfirm(entry.view)) return true;
    return false;
}

fn needsConfirm(self: *Window, surface: *Surface) bool {
    if (!surface.core_initialized) return false;
    return switch (self.app.config.@"confirm-close-surface") {
        .false => false,
        .true => surface.core_surface.needsConfirmQuit(),
        .always => true,
    };
}

/// Select tab `index`: show it, hide the rest.
pub fn select(self: *Window, index: usize) void {
    if (index >= self.tabs.items.len) return;
    self.active = index;
    self.layout();
    for (self.tabs.items, 0..) |t, i| t.setVisible(i == index);
    self.focusActive();
    self.syncTitle();
    // The chrome follows the active tab's colors.
    self.applyChrome();
    _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
}

pub fn gotoTab(self: *Window, tab: apprt.action.GotoTab) bool {
    const total = self.tabs.items.len;
    if (total == 0) return false;
    const current = self.active;
    const target: usize = switch (tab) {
        .previous => if (current > 0) current - 1 else total - 1,
        .next => if (current + 1 < total) current + 1 else 0,
        .last => total - 1,
        _ => n: {
            // 1-indexed
            const n = std.math.cast(usize, @intFromEnum(tab)) orelse return false;
            if (n == 0) return false;
            break :n @min(n - 1, total - 1);
        },
    };
    if (target == current) return false;
    self.select(target);
    return true;
}

pub fn moveTab(self: *Window, surface: *Surface, amount: isize) bool {
    const total: isize = @intCast(self.tabs.items.len);
    if (total < 2) return false;
    const from_u = self.tabIndexOf(surface) orelse return false;
    const from: isize = @intCast(from_u);
    const to: usize = @intCast(@mod(from + amount, total));
    if (to == from_u) return false;

    const tab = self.tabs.orderedRemove(from_u);
    self.tabs.insertAssumeCapacity(to, tab);
    self.select(to);
    return true;
}

pub fn activeTab(self: *const Window) ?*Tab {
    if (self.active >= self.tabs.items.len) return null;
    return self.tabs.items[self.active];
}

/// The active tab's focused pane.
pub fn activeSurface(self: *const Window) ?*Surface {
    const tab = self.activeTab() orelse return null;
    return tab.focused;
}

/// The index of the tab holding `surface`.
pub fn tabIndexOf(self: *const Window, surface: *const Surface) ?usize {
    for (self.tabs.items, 0..) |t, i| if (t.contains(surface)) return i;
    return null;
}

/// Every pane of every tab.
pub fn panes(self: *const Window) PaneIterator {
    return .{ .tabs = self.tabs.items };
}

pub const PaneIterator = struct {
    tabs: []const *Tab,
    next_tab: usize = 0,
    current: ?Tab.Tree.Iterator = null,

    pub fn next(self: *PaneIterator) ?*Surface {
        while (true) {
            if (self.current) |*it| if (it.next()) |entry| return entry.view;
            if (self.next_tab >= self.tabs.len) return null;
            self.current = self.tabs[self.next_tab].panes();
            self.next_tab += 1;
        }
    }
};

/// Give the active tab's surface the keyboard focus, if this window is
/// the active one. SetFocus also activates the window it is called on, so
/// closing a tab in a background window (its process exited, say) used to
/// pull that window in front of the one in use. A background window
/// focuses its tab when it is activated (WM_ACTIVATE).
fn focusActive(self: *Window) void {
    if (c.GetActiveWindow() != self.hwnd) return;
    self.focusActiveNow();
}

fn focusActiveNow(self: *Window) void {
    if (self.activeSurface()) |s| _ = c.SetFocus(s.hwnd);
}

/// Destroy the window. Its tabs and memory are released when the window
/// receives WM_DESTROY.
pub fn destroy(self: *Window) void {
    _ = c.DestroyWindow(self.hwnd);
}

fn onDestroy(self: *Window) void {
    const alloc = self.app.core_app.alloc;
    _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA, 0);

    // The child windows are destroyed by the system after this.
    for (self.tabs.items) |tab| tab.destroy(false);
    self.tabs.deinit(alloc);
    self.tab_bar.deinit();

    self.app.windowDestroyed(self);
    alloc.destroy(self);
}

/// Close the window, confirming if a process is running. Only call this
/// from the message loop (see App.Request).
pub fn requestClose(self: *Window) void {
    var confirm = false;
    var it = self.panes();
    while (it.next()) |s| confirm = confirm or self.needsConfirm(s);
    if (confirm and !self.app.confirm(
        self.hwnd,
        if (self.tabs.items.len > 1)
            "Processes are still running in this window's tabs. Close it anyway?"
        else
            "A process is still running in this terminal. Close it anyway?",
        "Ghostty: Close Window",
    )) return;
    self.destroy();
}

/// Queue closing tab `i` (from a click on the tab bar).
fn requestCloseTab(self: *Window, i: usize) void {
    const s = self.tabs.items[i].focused;
    if (!s.core_initialized) return;
    self.app.request(.{ .close_tabs = .{ .id = s.core_surface.id, .mode = .this } });
}

/// Called by a surface when its title changes.
pub fn surfaceTitleChanged(self: *Window, surface: *Surface) void {
    if (self.activeSurface() == surface) self.syncTitle();
    self.invalidateTabBar();
}

pub fn syncTitle(self: *Window) void {
    const title: []const u8 = if (self.activeSurface()) |s| s.title orelse "Ghostty" else "Ghostty";
    const alloc = self.app.core_app.alloc;
    const title16 = std.unicode.utf8ToUtf16LeAllocZ(alloc, title) catch return;
    defer alloc.free(title16);
    _ = c.SetWindowTextW(self.hwnd, title16);
}

//---------------------------------------------------------------
// Layout

fn tabBarVisibleFor(self: *const Window, count: usize) bool {
    return switch (self.app.config.@"window-show-tab-bar") {
        .always => true,
        .never => false,
        .auto => count > 1,
    };
}

pub fn tabBarVisible(self: *const Window) bool {
    return self.tabBarVisibleFor(self.tabs.items.len);
}

fn tabBarRect(self: *const Window) c.RECT {
    var client: c.RECT = .{};
    _ = c.GetClientRect(self.hwnd, &client);
    return .{ .right = client.right, .bottom = self.tab_bar.height() };
}

/// The area tabs occupy when the window has `count` tabs.
fn tabRect(self: *const Window, count: usize) c.RECT {
    var r: c.RECT = .{};
    _ = c.GetClientRect(self.hwnd, &r);
    if (self.tabBarVisibleFor(count)) r.top = @min(r.bottom, self.tab_bar.height());
    return r;
}

/// Size every tab to the tab area, all in one step (so they never show at
/// different sizes), discarding their old contents rather than copying
/// them, which left trails while resizing; the renderers redraw. Each tab
/// sizes its panes as it is resized.
fn layout(self: *Window) void {
    const r = self.tabRect(self.tabs.items.len);
    const flags = c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_NOCOPYBITS;
    var hdwp = c.BeginDeferWindowPos(@intCast(self.tabs.items.len));
    for (self.tabs.items) |t| {
        if (hdwp) |h| {
            hdwp = c.DeferWindowPos(h, t.hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, flags);
        }
        // If deferring failed (it then frees the batch), move it directly.
        if (hdwp == null) _ = c.SetWindowPos(t.hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, flags);
    }
    if (hdwp) |h| _ = c.EndDeferWindowPos(h);
}

/// Resize the window so its surface area is the given size in points
/// (1/96 inch), the unit of the core's initial_size and resize_window
/// actions: it divides pixel sizes by the content scale. A zero
/// dimension keeps its current size, as resize_window requires.
pub fn setClientSize(self: *Window, width: u32, height: u32) void {
    if (width == 0 and height == 0) return;
    const dpi = c.GetDpiForWindow(self.hwnd);
    const current = self.tabRect(self.tabs.items.len);
    // Round up so the grid doesn't lose a column or row.
    const w: c_int = if (width == 0)
        current.right - current.left
    else
        @intCast((@as(u64, width) * dpi + 95) / 96);
    const h: c_int = if (height == 0)
        current.bottom - current.top
    else
        @intCast((@as(u64, height) * dpi + 95) / 96);
    const bar: c_int = if (self.tabBarVisible()) self.tab_bar.height() else 0;
    var rect: c.RECT = .{ .right = w, .bottom = h + bar };
    const style: c.DWORD = @truncate(@as(usize, @bitCast(c.GetWindowLongPtrW(self.hwnd, c.GWL_STYLE))));
    _ = c.AdjustWindowRectExForDpi(&rect, style, c.FALSE, c.WS_EX_APPWINDOW, dpi);
    var win_w = rect.right - rect.left;
    var win_h = rect.bottom - rect.top;
    // Never larger than the monitor's work area.
    var mi: c.MONITORINFO = .{};
    if (c.MonitorFromWindow(self.hwnd, c.MONITOR_DEFAULTTONEAREST)) |monitor| {
        if (c.GetMonitorInfoW(monitor, &mi) != 0) {
            win_w = @min(win_w, mi.rcWork.right - mi.rcWork.left);
            win_h = @min(win_h, mi.rcWork.bottom - mi.rcWork.top);
        }
    }
    _ = c.SetWindowPos(
        self.hwnd,
        null,
        0,
        0,
        win_w,
        win_h,
        c.SWP_NOMOVE | c.SWP_NOZORDER | c.SWP_NOACTIVATE,
    );
}

/// A program asked to resize the window (resize_window, from CSI 8 t when
/// `vt-window-resize-allowed` is on). As that option documents, it is
/// ignored in a split or in a window with several tabs, and while the
/// window is maximized or fullscreen; setClientSize keeps it within the
/// monitor. Returns whether the window was resized.
pub fn resizeFromTerminal(self: *Window, width: u32, height: u32) bool {
    if (self.tabs.items.len > 1) return false;
    if (self.activeTab()) |t| if (t.tree.isSplit()) return false;
    if (c.IsZoomed(self.hwnd) != 0 or self.fullscreen != null) return false;
    self.setClientSize(width, height);
    return true;
}

pub fn toggleMaximize(self: *Window) void {
    _ = c.ShowWindow(self.hwnd, if (c.IsZoomed(self.hwnd) != 0) c.SW_RESTORE else c.SW_MAXIMIZE);
}

pub fn toggleFullscreen(self: *Window) void {
    if (self.fullscreen) |saved| {
        _ = c.SetWindowLongPtrW(self.hwnd, c.GWL_STYLE, saved.style);
        _ = c.SetWindowPlacement(self.hwnd, &saved.placement);
        _ = c.SetWindowPos(self.hwnd, null, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE |
            c.SWP_NOZORDER | c.SWP_NOOWNERZORDER | c.SWP_FRAMECHANGED);
        self.fullscreen = null;
        return;
    }

    var saved: Saved = .{
        .placement = .{},
        .style = c.GetWindowLongPtrW(self.hwnd, c.GWL_STYLE),
    };
    _ = c.GetWindowPlacement(self.hwnd, &saved.placement);

    var mi: c.MONITORINFO = .{};
    const monitor = c.MonitorFromWindow(self.hwnd, c.MONITOR_DEFAULTTONEAREST) orelse return;
    if (c.GetMonitorInfoW(monitor, &mi) == 0) return;

    const style: usize = @bitCast(saved.style);
    _ = c.SetWindowLongPtrW(self.hwnd, c.GWL_STYLE, @bitCast(style & ~@as(usize, c.WS_OVERLAPPEDWINDOW)));
    const r = mi.rcMonitor;
    _ = c.SetWindowPos(self.hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, c.SWP_NOOWNERZORDER | c.SWP_FRAMECHANGED);
    self.fullscreen = saved;
}

pub fn present(self: *Window) void {
    if (c.IsIconic(self.hwnd) != 0) _ = c.ShowWindow(self.hwnd, c.SW_RESTORE);
    _ = c.SetForegroundWindow(self.hwnd);
    // Activating the window is the point here.
    self.focusActiveNow();
}

/// Bring the tab holding `surface` to the front.
pub fn presentSurface(self: *Window, surface: *Surface) void {
    if (self.tabIndexOf(surface)) |i| {
        if (i != self.active) self.select(i);
    }
    self.present();
}

pub fn ringBell(self: *Window) void {
    const features = self.app.config.@"bell-features";
    if (features.system) _ = c.MessageBeep(c.MB_OK);
    if (features.attention and c.GetForegroundWindow() != self.hwnd) {
        _ = c.FlashWindowEx(&.{
            .hwnd = self.hwnd,
            .dwFlags = c.FLASHW_TRAY | c.FLASHW_TIMERNOFG,
            .uCount = 0,
        });
    }
}

/// The colors the chrome follows: the active tab's.
fn chromeColors(self: *const Window) Surface.Colors {
    if (self.activeSurface()) |s| return s.colors;
    return .fromConfig(&self.app.config);
}

/// Color the title bar for `window-theme`:
/// - `auto` (the default): the caption takes the terminal's background
///   and foreground, following programs that change them (OSC 10/11), as
///   macOS's transparent title bar does; light or dark by the background.
/// - `ghostty`: `window-titlebar-background`/`-foreground`, or the
///   configured background and foreground.
/// - `system`, `light`, `dark`: the system's caption, light or dark as
///   named (`system` follows the system setting).
/// Caption colors need Windows 11; Windows 10 ignores them and only gets
/// the light or dark caption.
pub fn applyChrome(self: *Window) void {
    const config = &self.app.config;
    const colors = self.chromeColors();
    var chrome: Chrome = .{};
    var text: ?c.COLORREF = null;
    switch (config.@"window-theme") {
        .system => chrome.dark = self.app.dark,
        .light => chrome.dark = false,
        .dark => chrome.dark = true,
        .auto => {
            chrome.dark = isDark(colors.bg);
            chrome.caption = rgbRef(colors.bg);
            text = rgbRef(colors.fg);
        },
        .ghostty => {
            const bg = config.@"window-titlebar-background" orelse config.background;
            chrome.dark = isDark(bg);
            chrome.caption = rgbRef(bg);
            text = rgbRef(config.@"window-titlebar-foreground" orelse config.foreground);
        },
    }

    const dark: c.BOOL = @intFromBool(chrome.dark);
    // Attribute 20 is honored from Windows 10 2004 (build 19041); earlier
    // supported builds only know the undocumented 19.
    if (c.DwmSetWindowAttribute(self.hwnd, c.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, @sizeOf(c.BOOL)) < 0) {
        _ = c.DwmSetWindowAttribute(self.hwnd, c.DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1, &dark, @sizeOf(c.BOOL));
    }
    const caption = chrome.caption orelse c.DWMWA_COLOR_DEFAULT;
    const text_color = text orelse c.DWMWA_COLOR_DEFAULT;
    _ = c.DwmSetWindowAttribute(self.hwnd, c.DWMWA_CAPTION_COLOR, &caption, @sizeOf(c.COLORREF));
    _ = c.DwmSetWindowAttribute(self.hwnd, c.DWMWA_BORDER_COLOR, &caption, @sizeOf(c.COLORREF));
    _ = c.DwmSetWindowAttribute(self.hwnd, c.DWMWA_TEXT_COLOR, &text_color, @sizeOf(c.COLORREF));
    self.chrome = chrome;
}

fn rgbRef(color: configpkg.Config.Color) c.COLORREF {
    return c.rgb(color.r, color.g, color.b);
}

pub fn isDark(color: configpkg.Config.Color) bool {
    const r: f64 = @floatFromInt(color.r);
    const g: f64 = @floatFromInt(color.g);
    const b: f64 = @floatFromInt(color.b);
    // Perceived luminance (the core's RGB.perceivedLuminance).
    return (0.299 * r + 0.587 * g + 0.114 * b) / 255.0 < 0.5;
}

/// A surface's colors changed (a program set them, or its config changed).
pub fn colorsChanged(self: *Window, surface: *Surface) void {
    if (self.activeSurface() != surface) return;
    self.applyChrome();
    var r = self.tabBarRect();
    _ = c.InvalidateRect(self.hwnd, &r, c.FALSE);
}

/// The config changed: the chrome, and the tab bar's colors and
/// visibility, may differ.
pub fn configChanged(self: *Window) void {
    self.applyChrome();
    self.layout();
    _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
}

//---------------------------------------------------------------
// Tab bar input and painting

/// Paint the tab bar, and anything of the client area the tabs don't
/// cover yet (while resizing) in the terminal's background rather than
/// leaving it black. WS_CLIPCHILDREN keeps this off the tabs.
fn paint(self: *Window) void {
    var ps: c.PAINTSTRUCT = undefined;
    const hdc = c.BeginPaint(self.hwnd, &ps) orelse return;
    defer _ = c.EndPaint(self.hwnd, &ps);

    const colors = self.chromeColors();
    var below = self.tabRect(self.tabs.items.len);
    if (c.CreateSolidBrush(c.rgb(colors.bg.r, colors.bg.g, colors.bg.b))) |brush| {
        defer _ = c.DeleteObject(brush);
        _ = c.FillRect(hdc, &below, brush);
    }
    if (!self.tabBarVisible()) return;

    // Every title: the bar is laid out (and hit-tested) for all the tabs.
    const alloc = self.app.core_app.alloc;
    const titles = alloc.alloc([]const u8, self.tabs.items.len) catch return;
    defer alloc.free(titles);
    for (self.tabs.items, titles) |tab, *t| t.* = tab.title();

    const r = self.tabBarRect();
    self.tab_bar.paint(hdc, r.right, titles, self.active, colors.bg, colors.fg);
}

fn tabBarHit(self: *const Window, lparam: c.LPARAM) TabBar.Hit {
    if (!self.tabBarVisible()) return .none;
    return self.tab_bar.hitTest(
        c.xParam(lparam),
        c.yParam(lparam),
        self.tabs.items.len,
        self.tabBarRect().right,
    );
}

fn setHover(self: *Window, hit: TabBar.Hit) void {
    if (hit.eql(self.tab_bar.hover)) return;
    self.tab_bar.hover = hit;
    var r = self.tabBarRect();
    _ = c.InvalidateRect(self.hwnd, &r, c.FALSE);
}

fn newTabFromActive(self: *Window) void {
    const parent: ?*CoreSurface = if (self.activeSurface()) |s|
        (if (s.core_initialized) &s.core_surface else null)
    else
        null;
    _ = self.addTab(parent, .tab) catch |err| {
        log.err("error creating tab err={}", .{err});
    };
}

fn fromHwnd(hwnd: c.HWND) ?*Window {
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
            const minimized = wparam == c.SIZE_MINIMIZED;
            if (!minimized) self.layout();
            if (self.activeTab()) |t| t.setVisible(!minimized);
            return 0;
        },

        c.WM_MOUSEMOVE => {
            if (!self.tab_bar.tracking) {
                var tme: c.TRACKMOUSEEVENT = .{ .dwFlags = c.TME_LEAVE, .hwndTrack = hwnd };
                if (c.TrackMouseEvent(&tme) != 0) self.tab_bar.tracking = true;
            }
            self.setHover(self.tabBarHit(lparam));
            return 0;
        },

        c.WM_MOUSELEAVE => {
            self.tab_bar.tracking = false;
            self.setHover(.none);
            return 0;
        },

        c.WM_LBUTTONDOWN => {
            switch (self.tabBarHit(lparam)) {
                .none => {},
                .tab => |i| self.select(i),
                .close => |i| self.requestCloseTab(i),
                .new_tab => self.newTabFromActive(),
            }
            return 0;
        },

        c.WM_MBUTTONUP => {
            switch (self.tabBarHit(lparam)) {
                .tab, .close => |i| self.requestCloseTab(i),
                else => {},
            }
            return 0;
        },

        c.WM_ACTIVATE => {
            if (c.loword(wparam) != c.WA_INACTIVE) {
                // Activated (from the taskbar, say) while a dialog has
                // it disabled: bring the dialog forward instead.
                if (c.IsWindowEnabled(hwnd) == 0) {
                    self.app.postRaiseModal();
                } else {
                    self.focusActiveNow();
                }
            }
            return 0;
        },

        c.WM_SETCURSOR => {
            // A click on a window that a dialog of another window has
            // disabled. Windows only looks for a dialog among the
            // clicked window's own popups, so find it for it.
            if (c.loword(lparam) == c.HTERROR) switch (c.hiword(lparam)) {
                c.WM_LBUTTONDOWN,
                c.WM_RBUTTONDOWN,
                c.WM_MBUTTONDOWN,
                c.WM_XBUTTONDOWN,
                => self.app.raiseModal(),
                else => {},
            };
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        c.WM_SETFOCUS => {
            // Only an active window gets the focus.
            self.focusActiveNow();
            return 0;
        },

        c.WM_ACTIVATEAPP => {
            self.app.core_app.focusEvent(wparam != 0);
            return 0;
        },

        c.WM_GETMINMAXINFO => {
            const limit = self.size_limit orelse return 0;
            const info: *c.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const bar: c_int = if (self.tabBarVisible()) self.tab_bar.height() else 0;
            var rect: c.RECT = .{
                .right = @intCast(limit.min_width),
                .bottom = @as(c_int, @intCast(limit.min_height)) + bar,
            };
            const style: c.DWORD = @truncate(@as(usize, @bitCast(c.GetWindowLongPtrW(hwnd, c.GWL_STYLE))));
            _ = c.AdjustWindowRectExForDpi(&rect, style, c.FALSE, c.WS_EX_APPWINDOW, c.GetDpiForWindow(hwnd));
            info.ptMinTrackSize = .{ .x = rect.right - rect.left, .y = rect.bottom - rect.top };
            return 0;
        },

        c.WM_DPICHANGED => {
            self.tab_bar.setDpi(c.hiword(wparam));
            const r: *const c.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = c.SetWindowPos(hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
            var it = self.panes();
            while (it.next()) |s| s.dpiChanged();
            return 0;
        },

        c.WM_SETTINGCHANGE => {
            if (lparam != 0) {
                const name: [*:0]const u16 = @ptrFromInt(@as(usize, @bitCast(lparam)));
                if (std.mem.eql(u16, std.mem.span(name), c.L("ImmersiveColorSet"))) {
                    self.app.systemThemeChanged();
                }
            }
            return 0;
        },

        c.WM_CLOSE => {
            self.app.request(.{ .close_window = self.id });
            return 0;
        },

        c.WM_DESTROY => {
            self.onDestroy();
            return 0;
        },

        else => return c.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
