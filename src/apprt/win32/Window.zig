//! A top-level window. Each window hosts one or more tabs (Tab.zig), each
//! a container of terminal panes; only the active tab's container is shown.
const Window = @This();

const std = @import("std");
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const input = @import("../../input.zig");
const CoreSurface = @import("../../Surface.zig");

const c = @import("c.zig");
const draw = @import("draw.zig");
const split_layout = @import("split_layout.zig");
const taskbar = @import("taskbar.zig");
const text_util = @import("text.zig");
const HeaderBar = @import("HeaderBar.zig");
const App = @import("App.zig");
const CommandPalette = @import("CommandPalette.zig");
const ContextMenu = @import("ContextMenu.zig");
const Overlay = @import("Overlay.zig");
const QuickTerminal = @import("QuickTerminal.zig");
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const TabBar = @import("TabBar.zig");
const test_hooks = @import("test_hooks.zig");

const log = std.log.scoped(.win32_window);

pub const class_name = c.L("MurrttyWindow");

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

/// The command palette (toggle_command_palette).
palette: CommandPalette = .{},

/// The user's name for the window (prompt_window_title, set_window_title),
/// shown in the caption instead of its active tab's title.
title_override: ?[:0]u8 = null,

/// In-app notifications (app-notifications), GTK's toasts: a pill at the
/// bottom center for 3 seconds, the latest replacing the one before.
toast: Overlay = .{ .position = .@"bottom-center", .margin = 24, .pad_x = 16, .pad_y = 8, .radius = -1 },

/// What the last press on the tab bar hit: a double click renames a tab
/// only if both its presses were on it.
last_press: TabBar.Hit = .none,

/// A tab pressed, and dragged once the mouse moves past the system's drag
/// distance (roadmap 4.5).
tab_drag: ?TabDrag = null,

/// The tabs (by index, the first 64) whose label the tab bar last painted
/// with the bell, and with the bell's mark, for the GUI tests' dump.
painted_bell: u64 = 0,
painted_attention: u64 = 0,

/// Client size limits from the core, in device pixels: from the first
/// pane, which is initialized before its tab exists.
size_limit: ?apprt.action.SizeLimit = null,

/// Saved placement and style while fullscreen.
fullscreen: ?Saved = null,
/// The chrome's height, the client's width and whether the window was
/// maximized at the last layout.
chrome_shown: c_int = -1,
chrome_width: c_int = -1,
chrome_zoomed: bool = false,
/// Whether the window is the active one: inactive, the chrome takes
/// libadwaita's backdrop colors.
active_window: bool = true,
/// Whether the frame was last computed without the caption (captionless).
captionless_frame: bool = false,
/// toggle_window_decorations' choice for this window over the config's
/// window-decoration, as GTK keeps it (null: the config's).
decoration_override: ?configpkg.WindowDecoration = null,
/// Asked to stay above other windows (float_window; roadmap 4.6).
floating: bool = false,
/// The progress its taskbar button shows, or would once Windows made it
/// (TaskbarButtonCreated; roadmap 5.4).
taskbar_progress: taskbar.Progress = .{},
taskbar_ready: bool = false,
/// What showing it last returned, for the GUI tests (1, S_FALSE, before
/// any).
taskbar_hr: c.HRESULT = 1,
/// Whether the window is translucent (App.translucent), as last applied
/// by syncTranslucent.
translucent: bool = false,
/// How it blurs what shows through, as last applied by syncBlur.
blur: Blur = .none,
/// DWM refused Acrylic once: the accent policy's blur from then on, rather
/// than asking again on every activation.
acrylic_refused: bool = false,
/// GTK's header bar, the title bar with client-side decorations.
header: HeaderBar = .{},
/// The window's button pressed (a press on the header bar's minimize,
/// maximize or close, until its release) and the non-client mouse
/// tracking that clears it when the mouse leaves.
pressed: TabBar.Hit = .none,
nc_tracking: bool = false,
/// Wheel movement over the strip short of a notch, toward its end.
wheel_rest: c_int = 0,
/// A tab was selected while the strip had no width (minimized): bring it
/// into view at the next layout with some.
reveal_active: bool = false,

/// What applyChrome last set, for the GUI tests' state dump.
chrome: Chrome = .{},

/// The tab strip's tooltip (a tab's title and directory, a button's name),
/// its text asked for when it shows (TTN_GETDISPINFOW).
tooltip: ?c.HWND = null,
tooltip_text: [512:0]u16 = @splat(0),

/// The icons at the window's DPI (the class's would be scaled from 32 px),
/// and the widths asked for, for the GUI tests' dump.
small_icon: ?c.HICON = null,
big_icon: ?c.HICON = null,
icon_widths: [2]c_int = .{ 0, 0 },

/// murrtty's items in the system menu (Alt+Space).
system_menu: ContextMenu.SystemMenu = .{},
/// Open while the system menu's loop runs: closes wait until it ends, as
/// for every other nested loop.
menu_modal: ?App.Modal = null,

/// The quick terminal's state, if this is it (roadmap 5.7): borderless,
/// topmost, no taskbar button or header bar, placed by its config and
/// never resized otherwise.
quick: ?QuickTerminal = null,

const TabDrag = struct {
    /// The tab pressed, found again on each move: tabs can close or move
    /// meanwhile (a middle click, a process ending, a binding), which
    /// would leave a position naming another tab, or none.
    tab: *Tab,
    /// Where the press was, in client coordinates.
    start: c.POINT,
    /// Past the drag distance.
    dragging: bool = false,
};

/// background-blur's ways (App.blurMethod).
pub const Blur = enum {
    none,
    /// DWM's Acrylic system backdrop (DWMSBT_TRANSIENTWINDOW).
    backdrop,
    /// The accent policy's blur (ACCENT_ENABLE_BLURBEHIND).
    accent,
};

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
        // Double clicks: a double click on a tab renames it.
        .style = c.CS_DBLCLKS,
        .hIcon = c.LoadIconW(instance, 1),
        .hCursor = c.LoadCursorW(null, c.IDC_ARROW),
        .lpszClassName = class_name,
    };
    if (c.RegisterClassExW(&wc) == 0) return error.RegisterClassFailed;
}

/// Create and show a new window with a single tab.
pub fn create(app: *App, parent: ?*CoreSurface) !*Window {
    const self = try createEmpty(app, .normal);
    errdefer self.discard();
    // Before the pane, which then opens at that monitor's DPI and the
    // first size fits its work area.
    self.placeAsConfigured();
    _ = try self.addTab(parent, .window);
    self.show();
    return self;
}

/// Create the quick terminal (roadmap 5.7) with a single tab, and slide it
/// in. It is made (hidden) where it shows, so its pane opens at that
/// monitor's DPI and its final size.
pub fn createQuick(app: *App) !*Window {
    const self = try createEmpty(app, .quick);
    errdefer self.discard();
    _ = try self.addTab(null, .window);
    self.quick.?.show(self);
    return self;
}

/// window-position-x and -y, both set: the window's visible top left there
/// (the frame's, not the invisible resize border around it), in pixels from
/// the primary monitor's top left, as macOS has it for every new window
/// (GTK can't place windows). Off every monitor, it moves into the nearest
/// one's work area.
fn placeAsConfigured(self: *Window) void {
    const config = &self.app.config;
    const px = config.@"window-position-x" orelse return;
    const py = config.@"window-position-y" orelse return;
    var r: c.RECT = .{};
    _ = c.GetWindowRect(self.hwnd, &r);
    // DWM's frame lies inside the window rectangle by the resize border.
    var visible: c.RECT = r;
    if (c.DwmGetWindowAttribute(self.hwnd, c.DWMWA_EXTENDED_FRAME_BOUNDS, &visible, @sizeOf(c.RECT)) < 0) visible = r;
    const w = r.right - r.left;
    const h = r.bottom - r.top;
    var x = @as(c_int, px) - (visible.left - r.left);
    var y = @as(c_int, py) - (visible.top - r.top);
    const there: c.RECT = .{ .left = x, .top = y, .right = x + w, .bottom = y + h };
    if (c.MonitorFromRect(&there, c.MONITOR_DEFAULTTONULL) == null) {
        var mi: c.MONITORINFO = .{};
        if (c.MonitorFromRect(&there, c.MONITOR_DEFAULTTONEAREST)) |m| if (c.GetMonitorInfoW(m, &mi) != 0) {
            const work = mi.rcWork;
            x = @max(work.left, @min(x, work.right - w));
            y = @max(work.top, @min(y, work.bottom - h));
        };
    }
    _ = c.SetWindowPos(self.hwnd, null, x, y, 0, 0, c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE);
}

/// The taskbar button shows the active tab's focused pane's progress
/// (roadmap 5.4).
pub fn syncProgress(self: *Window) void {
    const wanted: taskbar.Progress = if (self.activeSurface()) |s|
        if (s.progress) |p| p.taskbar() else .{}
    else
        .{};
    if (std.meta.eql(wanted, self.taskbar_progress)) return;
    self.taskbar_progress = wanted;
    self.showProgress();
}

/// Put `taskbar_progress` on the button, once Windows has made it.
fn showProgress(self: *Window) void {
    if (!self.taskbar_ready) return;
    const list = self.app.taskbarList() orelse return;
    self.taskbar_hr = list.show(self.hwnd, self.taskbar_progress);
}

/// float_window (toggle_window_float_on_top): kept above other windows, or
/// not, as macOS's floating level (GTK lacks it).
pub fn setFloat(self: *Window, mode: apprt.action.FloatWindow) void {
    // The quick terminal is always above.
    if (self.quick != null) return;
    // As the window is: another program (Always On Top) may have changed it.
    if (self.isTopmost()) self.floating = true;
    self.floating = switch (mode) {
        .on => true,
        .off => false,
        .toggle => !self.floating,
    };
    const after = if (self.floating) c.HWND_TOPMOST else c.HWND_NOTOPMOST;
    // Windows may refuse it without saying so (it does on the GUI tests'
    // hidden desktop): `floating` is what was asked, isTopmost what is.
    if (c.SetWindowPos(self.hwnd, after, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOACTIVATE) == 0) {
        log.warn("SetWindowPos for floating failed err={}", .{c.GetLastError()});
    }
}

/// quick-terminal-autohide may hide the quick terminal now: no dialog is
/// open, and something can bring it back.
pub fn wantsAutohide(self: *const Window) bool {
    return self.quick != null and self.app.config.@"quick-terminal-autohide" and
        self.app.modal_depth == 0 and self.app.canShowQuick();
}

/// Whether Windows keeps the window above others now.
pub fn isTopmost(self: *const Window) bool {
    return c.GetWindowLongPtrW(self.hwnd, c.GWL_EXSTYLE) & c.WS_EX_TOPMOST != 0;
}

/// reset_window_size: the size a new window would open with for the
/// focused pane (window-width and -height at its current font, its last
/// initial_size; else the default), as macOS's; restored first if
/// maximized, nothing fullscreen or minimized. Returns whether it resized.
pub fn resetSize(self: *Window) bool {
    if (self.quick != null or self.fullscreen != null or c.IsIconic(self.hwnd) != 0) return false;
    if (c.IsZoomed(self.hwnd) != 0) {
        // Restoring shows the window: with those toggle_visibility hid.
        self.app.showWindows();
        _ = c.ShowWindow(self.hwnd, c.SW_RESTORE);
    }
    const pane = if (self.activeSurface()) |s| s.initial_size else null;
    const size = pane orelse .{ default_width, default_height };
    self.setClientSize(size[0], size[1]);
    return true;
}

/// window-step-resize: `rect`, the window being resized by its `edge`
/// (WM_SIZING), cut so the focused pane's grid fills its tab area in whole
/// cells, as macOS's resize increments (GTK lacks it). The edge dragged
/// moves; the opposite one stays.
fn stepResize(self: *Window, rect: *c.RECT, edge: c.WPARAM) void {
    const surface = self.activeSurface() orelse return;
    const g = surface.cellGeometry() orelse return;
    var frame: c.RECT = .{};
    self.adjustFrame(&frame, c.GetDpiForWindow(self.hwnd));
    const extra_w = frame.right - frame.left;
    const extra_h = frame.bottom - frame.top + self.chromeHeight();
    const w = split_layout.snapToCells(rect.right - rect.left - extra_w, g.pad_x, g.cell_w) + extra_w;
    const h = split_layout.snapToCells(rect.bottom - rect.top - extra_h, g.pad_y, g.cell_h) + extra_h;
    // Only the sides dragged.
    switch (edge) {
        c.WMSZ_LEFT, c.WMSZ_TOPLEFT, c.WMSZ_BOTTOMLEFT => rect.left = rect.right - w,
        c.WMSZ_RIGHT, c.WMSZ_TOPRIGHT, c.WMSZ_BOTTOMRIGHT => rect.right = rect.left + w,
        else => {},
    }
    switch (edge) {
        c.WMSZ_TOP, c.WMSZ_TOPLEFT, c.WMSZ_TOPRIGHT => rect.top = rect.bottom - h,
        c.WMSZ_BOTTOM, c.WMSZ_BOTTOMLEFT, c.WMSZ_BOTTOMRIGHT => rect.bottom = rect.top + h,
        else => {},
    }
}

/// A new window, not yet shown, with no tab: for create to add one to, or
/// for a tab moved out of another window (tearOff); or the quick terminal.
fn createEmpty(app: *App, kind: enum { normal, quick }) !*Window {
    const alloc = app.core_app.alloc;
    const self = try alloc.create(Window);
    errdefer alloc.destroy(self);
    self.* = .{ .app = app, .hwnd = undefined, .id = app.next_window_id };
    app.next_window_id += 1;
    // Closing the last window may now quit (App.checkQuit).
    app.requested_window = true;

    // The quick terminal: a topmost popup tool window (no frame, no
    // taskbar button), made (hidden) where it shows, so its pane opens at
    // that monitor's DPI and its final size.
    var at: c.RECT = .{ .left = c.CW_USEDEFAULT, .top = c.CW_USEDEFAULT, .right = default_width, .bottom = default_height };
    if (kind == .quick) {
        self.quick = .{};
        self.quick.?.chooseScreen(&app.config);
        const shown = self.quick.?.placement(&app.config).shown;
        at = .{ .left = shown.left, .top = shown.top, .right = shown.right - shown.left, .bottom = shown.bottom - shown.top };
    }
    self.hwnd = c.CreateWindowExW(
        if (kind == .quick) c.WS_EX_TOOLWINDOW | c.WS_EX_TOPMOST else c.WS_EX_APPWINDOW,
        class_name,
        c.L("murrtty"),
        if (kind == .quick) c.WS_POPUP | c.WS_CLIPCHILDREN else c.WS_OVERLAPPEDWINDOW | c.WS_CLIPCHILDREN,
        at.left,
        at.top,
        at.right,
        at.bottom,
        null,
        null,
        app.instance,
        self,
    ) orelse {
        log.err("failed to create window err={}", .{c.GetLastError()});
        return error.CreateWindowFailed;
    };
    // WM_NCCALCSIZE gave the new window its frame by captionless().
    self.captionless_frame = self.captionless();
    // Explorer runs below an elevated murrtty, whose windows would refuse
    // its TaskbarButtonCreated.
    if (app.taskbar_button_msg != 0) _ = c.ChangeWindowMessageFilterEx(self.hwnd, app.taskbar_button_msg, c.MSGFLT_ALLOW, null);
    self.syncBars();
    errdefer {
        _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA, 0);
        _ = c.DestroyWindow(self.hwnd);
        self.tabs.deinit(alloc);
        self.tab_bar.deinit();
        self.header.deinit();
        // onDestroy, which frees them otherwise, doesn't run.
        for ([_]?c.HICON{ self.small_icon, self.big_icon }) |icon| if (icon) |i| {
            _ = c.DestroyIcon(i);
        };
    }

    // Size the client area for the monitor's DPI (setClientSize scales).
    const dpi = c.GetDpiForWindow(self.hwnd);
    self.tab_bar.setDpi(dpi, app.config.@"window-title-font-family");
    self.header.setDpi(dpi, app.config.@"window-title-font-family");
    self.loadIcons(dpi);
    self.createTooltip();
    // The window's own copy of the system menu, made now: until a window
    // asks for it, Windows shows the shared one, and asking while it opens
    // makes a copy other than the menu showing (WM_INITMENUPOPUP).
    _ = c.GetSystemMenu(self.hwnd, c.FALSE);
    if (kind == .normal) self.setClientSize(default_width, default_height);
    self.applyChrome();
    // Before the first pane, which takes it up.
    self.syncTranslucent();

    try app.windows.append(alloc, self);
    return self;
}

/// Undo createEmpty for a window that got no tab (its first failed).
fn discard(self: *Window) void {
    const app = self.app;
    const alloc = app.core_app.alloc;
    _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA, 0);
    _ = c.DestroyWindow(self.hwnd);
    self.tabs.deinit(alloc);
    self.tab_bar.deinit();
    self.header.deinit();
    for ([_]?c.HICON{ self.small_icon, self.big_icon }) |icon| if (icon) |i| {
        _ = c.DestroyIcon(i);
    };
    if (std.mem.indexOfScalar(*Window, app.windows.items, self)) |i| _ = app.windows.orderedRemove(i);
    alloc.destroy(self);
}

/// Show a new window as the config has it (maximized, fullscreen), in
/// front, with the keyboard in its pane.
fn show(self: *Window) void {
    const config = &self.app.config;
    // With the windows toggle_visibility hid, behind it.
    self.app.showWindows();
    _ = c.ShowWindow(self.hwnd, if (config.maximize) c.SW_SHOWMAXIMIZED else c.SW_SHOWNORMAL);
    if (config.fullscreen != .false) self.toggleFullscreen();
    _ = c.SetForegroundWindow(self.hwnd);
    self.focusActive();
}

/// Add a tab after the active one and select it. Returns its pane.
pub fn addTab(
    self: *Window,
    parent: ?*CoreSurface,
    context: apprt.surface.NewSurfaceContext,
) !*Surface {
    const alloc = self.app.core_app.alloc;

    // Make room for the tab bar first so the new pane starts at its
    // final size. After the active tab, or at the end
    // (window-new-tab-position).
    const index = if (self.tabs.items.len == 0) 0 else switch (self.app.config.@"window-new-tab-position") {
        .current => self.active + 1,
        .end => self.tabs.items.len,
    };
    try self.tabs.ensureUnusedCapacity(alloc, 1);
    const had_bar = self.tabBarVisible();

    const tab = try Tab.create(self, self.tabRect(self.tabs.items.len + 1), parent, context);
    self.tabs.insertAssumeCapacity(index, tab);
    if (had_bar != self.tabBarVisible()) _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
    // The pane took the bars' shade before the tab counted (Tab.create):
    // the row this tab brings casts one too. Created at its final size, it
    // hears no WM_SIZE to lay it out again.
    tab.focused.setShade(self.shade());
    self.select(index);
    return tab.focused;
}

/// Close a pane, confirming first if `confirm` and a process is running.
/// Closing a tab's last pane closes the tab, and the last tab the window.
/// Only call this from the message loop (see App.Request), never from
/// inside a core callback.
pub fn closeSurface(self: *Window, surface: *Surface, confirm: bool) void {
    if (confirm and self.needsConfirm(surface)) {
        // Worded for what closes: the split, or the tab a lone pane takes
        // with it (GTK says Close Split? for that too).
        const i = self.tabIndexOf(surface) orelse return;
        const target: App.CloseTarget = if (self.tabs.items[i].tree.isSplit()) .split else .tab;
        if (!self.app.confirmClose(self.hwnd, target)) return;
    }

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
    tab.syncDim();
    if (refocus and index == self.active) {
        self.focusActive();
        self.applyChrome();
    }
    // The title follows a new focused pane, or the zoom a last pane drops.
    if (index == self.active) self.syncTitle();
    self.invalidateTabBar();
}

/// Split `surface`'s pane for the new_split action: the new pane opens
/// `direction` of it and takes the focus. Runs inside a core callback,
/// which is fine for creating a pane (the core's focus change is deferred,
/// and its `all:` loop copes with surfaces added while it runs).
pub fn newSplit(self: *Window, surface: *Surface, direction: apprt.action.SplitDirection) !void {
    const index = self.tabIndexOf(surface) orelse return error.PaneNotFound;
    const tab = self.tabs.items[index];
    const pane = try tab.newSplit(surface, direction, &surface.core_surface);
    tab.focused = pane;
    tab.syncDim();
    if (index == self.active) {
        self.focusActive();
        self.syncTitle();
        self.applyChrome();
    }
    self.invalidateTabBar();
}

/// goto_split from `surface`. Returns false when the focus doesn't move,
/// so the key reaches the program.
pub fn gotoSplit(self: *Window, surface: *Surface, to: apprt.action.GotoSplit) bool {
    const index = self.tabIndexOf(surface) orelse return false;
    const tab = self.tabs.items[index];
    _ = (tab.goto(surface, to) catch |err| {
        log.err("error moving between panes err={}", .{err});
        return false;
    }) orelse return false;
    self.focusedPaneChanged(index);
    return true;
}

/// toggle_split_zoom for `surface`'s tab.
pub fn toggleSplitZoom(self: *Window, surface: *Surface) bool {
    const index = self.tabIndexOf(surface) orelse return false;
    if (!self.tabs.items[index].toggleZoom()) return false;
    // The tab strip and the title show a magnifier on a zoomed tab.
    self.invalidateTabBar();
    if (index == self.active) self.syncTitle();
    return true;
}

pub fn equalizeSplits(self: *Window, surface: *Surface) bool {
    const index = self.tabIndexOf(surface) orelse return false;
    return self.tabs.items[index].equalize() catch |err| {
        log.err("error equalizing panes err={}", .{err});
        return false;
    };
}

pub fn resizeSplit(self: *Window, surface: *Surface, value: apprt.action.ResizeSplit) bool {
    const index = self.tabIndexOf(surface) orelse return false;
    const resized = self.tabs.items[index].resize(surface, value) catch |err| {
        log.err("error resizing panes err={}", .{err});
        return false;
    };
    // Resizing ends a zoom.
    if (resized) {
        self.invalidateTabBar();
        if (index == self.active) self.syncTitle();
    }
    return resized;
}

/// The focused pane of tab `index` changed: give it the keyboard focus if
/// it is this active window's active tab, and follow its title and colors.
fn focusedPaneChanged(self: *Window, index: usize) void {
    self.tabs.items[index].syncDim();
    if (index == self.active) {
        self.focusActive();
        self.syncTitle();
        self.applyChrome();
    }
    self.invalidateTabBar();
    _ = c.InvalidateRect(self.tabs.items[index].hwnd, null, c.FALSE);
}

/// A pane got the keyboard focus: it becomes its tab's focused pane, whose
/// title and colors the tab and the window show.
pub fn surfaceFocused(self: *Window, surface: *Surface) void {
    const index = self.tabIndexOf(surface) orelse return;
    const tab = self.tabs.items[index];
    if (tab.focused == surface) return;
    tab.focused = surface;
    tab.syncDim();
    if (index == self.active) {
        self.syncTitle();
        self.applyChrome();
    }
    self.invalidateTabBar();
    // The dividers follow the focused pane's background.
    _ = c.InvalidateRect(tab.hwnd, null, c.FALSE);
}

/// The smallest the tab area may be: every pane of every tab at its
/// minimum, with the dividers between them (so no tab is squeezed below
/// its panes' minimums), or the core's size limit before any tab exists.
fn minimumTabArea(self: *const Window) ?split_layout.Size {
    if (self.tabs.items.len == 0) {
        const limit = self.size_limit orelse return null;
        return .{
            .width = @intCast(@min(limit.min_width, std.math.maxInt(u16))),
            .height = @intCast(@min(limit.min_height, std.math.maxInt(u16))),
        };
    }
    var min: ?split_layout.Size = null;
    const alloc = self.app.core_app.alloc;
    for (self.tabs.items) |t| {
        const m = Tab.Layout.minimum(alloc, &t.tree, t.dividerWidth()) catch continue;
        min = if (min) |cur| .{
            .width = @max(cur.width, m.width),
            .height = @max(cur.height, m.height),
        } else m;
    }
    return min;
}

/// Repaint the chrome: the header bar (its title) and the tab row.
pub fn invalidateTabBar(self: *Window) void {
    var r = self.chromeRect();
    if (r.bottom > 0) _ = c.InvalidateRect(self.hwnd, &r, c.FALSE);
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
    // One question for them all (GTK asks for each tab in turn).
    if (confirm and !self.app.confirmClose(self.hwnd, if (targets.items.len > 1) .tabs else .tab)) return;

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
    // In view on an overflowing strip; while minimized (no width to scroll
    // in), once restored.
    const width = self.clientWidth();
    if (width > 0) self.tab_bar.ensureVisible(index, self.tabs.items.len, width) else self.reveal_active = true;
    // Seen: the bell's mark goes.
    self.tabs.items[index].attention = false;
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

/// move_tab_to_new_window: the pane's tab into a new window, as GTK's;
/// nothing for a window's only tab.
pub fn moveTabToNewWindow(self: *Window, surface: *Surface) bool {
    const index = self.tabIndexOf(surface) orelse return false;
    self.tearOff(index, null) catch |err| {
        log.warn("error moving a tab to a new window err={}", .{err});
        return false;
    };
    return true;
}

/// Move tab `index` into a new window of the default size, as GTK's new
/// window has (not this one's, which may be maximized or fullscreen), its
/// top left at `at` (screen) within that monitor's work area, or as any
/// new window (window-position-x/-y, or where Windows places it); nothing
/// (an error) for the only tab, which would leave this window empty.
fn tearOff(self: *Window, index: usize, at: ?c.POINT) !void {
    if (self.tabs.items.len < 2) return error.OnlyTab;
    const target = try createEmpty(self.app, .normal);
    if (at == null) target.placeAsConfigured();
    if (at) |p| {
        var r: c.RECT = .{};
        _ = c.GetWindowRect(target.hwnd, &r);
        const w = r.right - r.left;
        const h = r.bottom - r.top;
        var x = p.x;
        var y = p.y;
        const spot: c.RECT = .{ .left = p.x, .top = p.y, .right = p.x + 1, .bottom = p.y + 1 };
        var mi: c.MONITORINFO = .{};
        if (c.MonitorFromRect(&spot, c.MONITOR_DEFAULTTONEAREST)) |monitor| if (c.GetMonitorInfoW(monitor, &mi) != 0) {
            const work = mi.rcWork;
            x = @max(work.left, @min(x, work.right - w));
            y = @max(work.top, @min(y, work.bottom - h));
        };
        _ = c.SetWindowPos(target.hwnd, null, x, y, 0, 0, c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE);
    }
    self.moveTabTo(index, target, 0) catch |err| {
        target.discard();
        return err;
    };
    target.show();
}

/// Move tab `index` to `target` at `at` (or its end), panes and all, still
/// running: its container moves to the other window (SetParent; spike S5,
/// a GL child keeps presenting). A window left without tabs closes
/// through the request queue, hidden meanwhile.
fn moveTabTo(self: *Window, index: usize, target: *Window, at: usize) !void {
    try target.tabs.ensureUnusedCapacity(self.app.core_app.alloc, 1);
    const tab = self.tabs.orderedRemove(index);
    self.setHover(.none);
    if (self.tabs.items.len == 0) {
        _ = c.ShowWindow(self.hwnd, c.SW_HIDE);
        self.app.request(.{ .close_window = self.id });
    } else {
        if (self.active > index or self.active >= self.tabs.items.len) self.active -|= 1;
        self.select(self.active);
    }
    target.adoptTab(tab, at);
}

/// Take in `tab` from another window at `at` (or the end) and select it;
/// room for it is the caller's to make.
fn adoptTab(self: *Window, tab: *Tab, at: usize) void {
    tab.window = self;
    var it = tab.panes();
    while (it.next()) |entry| entry.view.window = self;
    _ = c.SetParent(tab.hwnd, self.hwnd);
    const index = @min(at, self.tabs.items.len);
    const had_bar = self.tabBarVisible();
    self.tabs.insertAssumeCapacity(index, tab);
    if (had_bar != self.tabBarVisible()) _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
    // This window's DPI and translucency; select lays the tab out, and the
    // panes take the bars' shade from it.
    it = tab.panes();
    while (it.next()) |entry| {
        entry.view.dpiChanged();
        entry.view.setTranslucent(self.translucent);
    }
    self.select(index);
    tab.layoutPanes();
}

/// The other murrtty window whose title bar or tab row is at `screen`, and
/// the place a tab dropped there takes.
fn dropTargetAt(self: *Window, screen: c.POINT) ?struct { window: *Window, index: usize } {
    const hit = c.WindowFromPoint(screen) orelse return null;
    const root = c.GetAncestor(hit, c.GA_ROOT) orelse hit;
    for (self.app.windows.items) |w| {
        if (w == self or w.hwnd != root or c.IsWindowEnabled(w.hwnd) == 0) continue;
        var pt = screen;
        _ = c.ScreenToClient(w.hwnd, &pt);
        // The caption (server decorations) above the client counts too.
        if (pt.y >= w.chromeHeight()) return null;
        return .{ .window = w, .index = w.dropIndex(pt.x) };
    }
    return null;
}

/// Where a tab dropped at `x` (client) goes: before the first tab whose
/// middle is right of it, or at the end.
fn dropIndex(self: *const Window, x: c_int) usize {
    const n = self.tabs.items.len;
    if (!self.tabBarVisible()) return n;
    const width = self.clientWidth();
    for (0..n) |i| {
        const r = self.tab_bar.tabRect(i, n, width);
        if (x < @divTrunc(r.left + r.right, 2)) return i;
    }
    return n;
}

/// The mouse moved with a tab pressed: past the drag distance the tab
/// follows it along the strip, taking the place of the tab it is over.
fn dragTab(self: *Window, x: c_int, y: c_int) void {
    const d = if (self.tab_drag) |*v| v else return;
    const index = std.mem.indexOfScalar(*Tab, self.tabs.items, d.tab) orelse return self.endTabDrag();
    if (!d.dragging) {
        const dpi = c.GetDpiForWindow(self.hwnd);
        if (@abs(x - d.start.x) < c.GetSystemMetricsForDpi(c.SM_CXDRAG, dpi) and
            @abs(y - d.start.y) < c.GetSystemMetricsForDpi(c.SM_CYDRAG, dpi)) return;
        d.dragging = true;
    }
    if (!self.nearStrip(y)) return;
    const row = self.tabBarRect();
    const over = switch (self.chromeHit(x, @divTrunc(row.top + row.bottom, 2))) {
        .tab, .close => |i| i,
        else => return,
    };
    if (over == index or over >= self.tabs.items.len) return;
    const tab = self.tabs.orderedRemove(index);
    self.tabs.insertAssumeCapacity(over, tab);
    self.select(over);
}

/// Released: a tab dragged away from the strip moves onto another window's
/// bar, or out into a new window under the mouse; dropped on its own
/// window's terminal, nothing.
fn dropTab(self: *Window, x: c_int, y: c_int) void {
    const d = self.tab_drag orelse return;
    self.endTabDrag();
    if (!d.dragging or self.nearStrip(y)) return;
    const index = std.mem.indexOfScalar(*Tab, self.tabs.items, d.tab) orelse return;
    var screen: c.POINT = .{ .x = x, .y = y };
    _ = c.ClientToScreen(self.hwnd, &screen);
    if (self.dropTargetAt(screen)) |t| {
        self.moveTabTo(index, t.window, t.index) catch |err| log.warn("error moving a tab err={}", .{err});
        _ = c.SetForegroundWindow(t.window.hwnd);
        return;
    }
    var r: c.RECT = .{};
    _ = c.GetWindowRect(self.hwnd, &r);
    if (screen.x >= r.left and screen.x < r.right and screen.y >= r.top and screen.y < r.bottom) return;
    // The new window's first tab under the mouse, about.
    const dpi = c.GetDpiForWindow(self.hwnd);
    const at: c.POINT = .{ .x = screen.x - draw.scale(dpi, 60), .y = screen.y - draw.scale(dpi, 16) };
    self.tearOff(index, at) catch |err| switch (err) {
        error.OnlyTab => {},
        else => log.warn("error tearing a tab off err={}", .{err}),
    };
}

/// Whether `y` (client) is within a tab row's height of the strip, where a
/// dragged tab reorders rather than leaving the window.
fn nearStrip(self: *const Window, y: c_int) bool {
    if (!self.tabBarVisible()) return false;
    const row = self.tabBarRect();
    const h = row.bottom - row.top;
    return y >= row.top - h and y < row.bottom + h;
}

fn endTabDrag(self: *Window) void {
    if (self.tab_drag == null) return;
    self.tab_drag = null;
    if (c.GetCapture() == self.hwnd) _ = c.ReleaseCapture();
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
    // An open command palette keeps the keyboard.
    if (self.palette.focusTarget()) |f| {
        _ = c.SetFocus(f);
        return;
    }
    if (self.activeSurface()) |s| _ = c.SetFocus(s.focusTarget());
}

/// Destroy the window. Its tabs and memory are released when the window
/// receives WM_DESTROY.
pub fn destroy(self: *Window) void {
    _ = c.DestroyWindow(self.hwnd);
}

fn onDestroy(self: *Window) void {
    const alloc = self.app.core_app.alloc;
    _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA, 0);
    // Destroyed inside its system menu's loop (closes wait for it, but
    // another program can destroy a window): end the scope while the
    // panes it resumes are still here.
    self.endMenuModal();

    // The child windows are destroyed by the system after this.
    for (self.tabs.items) |tab| tab.destroy(false);
    self.tabs.deinit(alloc);
    self.tab_bar.deinit();
    self.header.deinit();
    self.palette.deinit(alloc);
    self.system_menu.deinit(alloc);
    self.toast.deinit();
    if (self.title_override) |v| alloc.free(v);
    // The tooltip, owned by the window, goes with it; the icons don't.
    for ([_]?c.HICON{ self.small_icon, self.big_icon }) |icon| if (icon) |i| {
        _ = c.DestroyIcon(i);
    };

    self.app.windowDestroyed(self);
    alloc.destroy(self);
}

/// Close the window, confirming if a process is running. Only call this
/// from the message loop (see App.Request).
pub fn requestClose(self: *Window) void {
    var confirm = false;
    var it = self.panes();
    while (it.next()) |s| confirm = confirm or self.needsConfirm(s);
    if (confirm and !self.app.confirmClose(self.hwnd, .window)) return;
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

/// Name the window, or (null, or empty) go back to its active tab's title.
pub fn setTitleOverride(self: *Window, name: ?[]const u8) void {
    const alloc = self.app.core_app.alloc;
    if (self.title_override) |v| alloc.free(v);
    self.title_override = null;
    if (name) |t| if (t.len > 0) {
        self.title_override = alloc.dupeSentinel(u8, t, 0) catch null;
    };
    self.syncTitle();
}

/// The caption: the user's name for the window, else its active tab's
/// title (GTK's).
pub fn syncTitle(self: *Window) void {
    // The taskbar button's progress follows the same pane.
    self.syncProgress();
    const alloc = self.app.core_app.alloc;
    // The active tab's label: its bell and zoom marks as on its tab (GTK
    // marks both).
    const shown: []u8 = if (self.title_override) |t|
        alloc.dupe(u8, t) catch return
    else if (self.activeTab()) |t|
        t.label(alloc) catch return
    else
        alloc.dupe(u8, "murrtty") catch return;
    defer alloc.free(shown);
    const title16 = std.unicode.utf8ToUtf16LeAllocZ(alloc, shown) catch return;
    defer alloc.free(title16);
    _ = c.SetWindowTextW(self.hwnd, title16);
    // The header bar shows it too.
    self.invalidateTabBar();
}

//---------------------------------------------------------------
// Layout

/// Whether GTK's tab bar would show `count` tabs (window-show-tab-bar).
fn tabsShownFor(self: *const Window, count: usize) bool {
    const config = &self.app.config;
    // The tab row as the title bar always shows, as GTK's, unless a
    // maximized window hides its title bar.
    if (self.tabsTitlebar()) return !(config.@"gtk-titlebar-hide-when-maximized" and c.IsZoomed(self.hwnd) != 0);
    return switch (config.@"window-show-tab-bar") {
        .always => true,
        .never => false,
        .auto => count > 1,
    };
}

/// gtk-titlebar-style = tabs: the tab row is the title bar, with the
/// header bar's buttons in it (HeaderBar.tabs_style), and no header bar.
pub fn tabsTitlebar(self: *const Window) bool {
    return self.quick == null and self.app.config.@"gtk-titlebar-style" == .tabs;
}

/// Lay the bars out for the window's style: the tab row is the top bar
/// without a header above it, and with gtk-titlebar-style = tabs holds the
/// header's buttons (the window's only with client-side decorations)
/// around its tabs.
fn syncBars(self: *Window) void {
    const tabs_style = self.tabsTitlebar();
    self.header.tabs_style = tabs_style;
    self.header.controls = self.csd();
    self.tab_bar.top_bar = self.headerHeight() == 0;
    self.tab_bar.inset = if (tabs_style) self.header.tabsInset() else null;
    self.tab_bar.inverted = self.app.config.@"gtk-tabs-inverted";
}

/// The title bar's height: the header bar's, or the tab row's when it is
/// the title bar (gtk-titlebar-style = tabs); 0 without client-side
/// decorations.
fn titleBarHeight(self: *const Window) c_int {
    if (!self.csd()) return 0;
    if (self.tabsTitlebar()) return if (self.tabBarVisible()) self.tab_bar.height() else 0;
    return self.header.height();
}

/// Whether the window draws GTK's header bar as its title bar (client-side
/// decorations; roadmap 4.3). GTK draws its header bar only with
/// `window-decoration` `auto` or `client`, and not with gtk-titlebar off,
/// fullscreen, or maximized with gtk-titlebar-hide-when-maximized. Without
/// it the system's caption shows, and no header buttons, as GTK's tab bar
/// then has none.
pub fn csd(self: *const Window) bool {
    // The quick terminal has no title bar, as GTK's never shows its header.
    if (self.quick != null) return false;
    const config = &self.app.config;
    switch (self.decoration()) {
        .auto, .client => {},
        .server, .none => return false,
    }
    if (!config.@"gtk-titlebar" or self.fullscreen != null) return false;
    return !(config.@"gtk-titlebar-hide-when-maximized" and c.IsZoomed(self.hwnd) != 0);
}

/// window-decoration, or what toggle_window_decorations chose instead.
pub fn decoration(self: *const Window) configpkg.WindowDecoration {
    return self.decoration_override orelse self.app.config.@"window-decoration";
}

/// Whether the frame has no caption: under the header bar (csd), or with
/// window-decoration = none (roadmap 4.4), where GTK's window has no
/// decorations at all; it keeps Windows' resize borders, shadow and
/// rounded corners, and the tab row becomes the top bar. Fullscreen has
/// no frame anyway.
pub fn captionless(self: *const Window) bool {
    // The quick terminal's popup has no frame to take the caption from.
    if (self.quick != null) return false;
    return self.csd() or (self.decoration() == .none and self.fullscreen == null);
}

/// Whether `screen` lies in the resize band along the top of a captionless
/// window with no bar there (window-decoration = none, no tab row): the
/// panes and their tab pass it on (HTTRANSPARENT), so the window's own
/// hit test answers HTTOP, as over a header bar.
pub fn inTopBand(self: *const Window, screen: c.POINT) bool {
    if (!self.captionless() or self.chromeHeight() != 0 or c.IsZoomed(self.hwnd) != 0) return false;
    var pt = screen;
    _ = c.ScreenToClient(self.hwnd, &pt);
    return pt.y >= 0 and pt.y < self.frameY();
}

/// toggle_window_decorations, as GTK's: from window-decoration = none to
/// auto, from anything else to none, and back to the config's on the next
/// toggle. The terminal area keeps its size, so the grid doesn't change,
/// unless the window is maximized or fullscreen.
pub fn toggleDecorations(self: *Window) void {
    if (self.quick != null) return;
    const before = self.tabRect(self.tabs.items.len);
    self.decoration_override = if (self.decoration_override != null) null else switch (self.app.config.@"window-decoration") {
        .none => .auto,
        .auto, .client, .server => .none,
    };
    // The caption's colors (server decorations), the bars, the frame.
    self.applyChrome();
    self.layout();
    if (c.IsZoomed(self.hwnd) == 0 and self.fullscreen == null) {
        self.resizeTabArea(before.right - before.left, before.bottom - before.top, false);
    }
    _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
}

/// Whether the tab row shows (window-show-tab-bar).
pub fn tabBarVisible(self: *const Window) bool {
    return self.tabsShownFor(self.tabs.items.len);
}

pub fn headerHeight(self: *const Window) c_int {
    return if (self.csd() and !self.tabsTitlebar()) self.header.height() else 0;
}

/// The header bar's and the tab row's height with `count` tabs.
fn chromeHeightFor(self: *const Window, count: usize) c_int {
    return self.headerHeight() + @as(c_int, if (self.tabsShownFor(count)) self.tab_bar.height() else 0);
}

pub fn chromeHeight(self: *const Window) c_int {
    return self.chromeHeightFor(self.tabs.items.len);
}

fn clientWidth(self: *const Window) c_int {
    var client: c.RECT = .{};
    _ = c.GetClientRect(self.hwnd, &client);
    return client.right;
}

/// The tab row, in client coordinates: below the header bar.
pub fn tabBarRect(self: *const Window) c.RECT {
    const top = self.headerHeight();
    return .{ .top = top, .right = self.clientWidth(), .bottom = top + self.tab_bar.height() };
}

/// The header bar and the tab row together.
fn chromeRect(self: *const Window) c.RECT {
    return .{ .right = self.clientWidth(), .bottom = self.chromeHeight() };
}

/// The area tabs occupy when the window has `count` tabs.
fn tabRect(self: *const Window, count: usize) c.RECT {
    var r: c.RECT = .{};
    _ = c.GetClientRect(self.hwnd, &r);
    r.top = @min(r.bottom, self.chromeHeightFor(count));
    return r;
}

/// The resize band along the top, inside the client area once the header
/// bar replaces the caption.
fn frameY(self: *const Window) c_int {
    const dpi = c.GetDpiForWindow(self.hwnd);
    return c.GetSystemMetricsForDpi(c.SM_CYSIZEFRAME, dpi) + c.GetSystemMetricsForDpi(c.SM_CXPADDEDBORDER, dpi);
}

/// Whether (`x`, `y`), in client coordinates, is the window's own frame
/// over the header bar: the caption between its buttons, the window's
/// buttons, or the resize band along the top. An overlay over the bar
/// leaves those to the window (the command palette's dimming).
pub fn isFrameAt(self: *const Window, x: c_int, y: c_int) bool {
    // The resize band, also without decorations (4.4).
    if (!self.captionless() or y < 0) return false;
    if (c.IsZoomed(self.hwnd) == 0 and y < self.frameY()) return true;
    if (!self.csd() or y >= self.titleBarHeight()) return false;
    return switch (self.chromeHit(x, y)) {
        .none, .minimize, .maximize, .window_close => true,
        else => false,
    };
}

/// A maximized client area that covers its monitor reads to the shell as
/// a fullscreen window, which keeps an auto-hide taskbar from sliding in:
/// leave it 2 px at each edge where one hides (as Windows Terminal does;
/// with an auto-hide taskbar the work area is the whole monitor). The
/// monitor is the one `rect`, the new client area, is on: WM_NCCALCSIZE
/// comes before the window moves (Win+Shift+arrow to another monitor).
fn insetForAutoHideTaskbars(rect: *c.RECT) void {
    const monitor = c.MonitorFromRect(rect, c.MONITOR_DEFAULTTONEAREST) orelse return;
    var info: c.MONITORINFO = .{};
    if (c.GetMonitorInfoW(monitor, &info) == 0) return;
    const inset = 2;
    for ([_]c.UINT{ c.ABE_LEFT, c.ABE_TOP, c.ABE_RIGHT, c.ABE_BOTTOM }) |edge| {
        var bar: c.APPBARDATA = .{ .uEdge = edge, .rc = info.rcMonitor };
        if (c.SHAppBarMessage(c.ABM_GETAUTOHIDEBAREX, &bar) == 0) continue;
        switch (edge) {
            c.ABE_LEFT => rect.left += inset,
            c.ABE_TOP => rect.top += inset,
            c.ABE_RIGHT => rect.right -= inset,
            else => rect.bottom -= inset,
        }
    }
}

/// `rect`, a client area, grown to the window around it: the system's
/// frame, less the caption while the header bar replaces it
/// (WM_NCCALCSIZE).
fn adjustFrame(self: *const Window, rect: *c.RECT, dpi: c.UINT) void {
    const top = rect.top;
    const style: c.DWORD = @truncate(@as(usize, @bitCast(c.GetWindowLongPtrW(self.hwnd, c.GWL_STYLE))));
    _ = c.AdjustWindowRectExForDpi(rect, style, c.FALSE, c.WS_EX_APPWINDOW, dpi);
    if (self.captionless()) rect.top = top;
}

/// Size every tab to the tab area, all in one step (so they never show at
/// different sizes), discarding their old contents rather than copying
/// them, which left trails while resizing; the renderers redraw. Each tab
/// sizes its panes as it is resized.
fn layout(self: *Window) void {
    // A wider window may show more tabs: keep the scroll in range (not the
    // active tab in view, which would undo the chevrons; select does that).
    // Below the header bar, or the top bar itself (its height differs).
    self.syncBars();
    const strip_width = self.clientWidth();
    self.tab_bar.clampScroll(self.tabs.items.len, strip_width);
    if (self.reveal_active and strip_width > 0) {
        self.reveal_active = false;
        self.tab_bar.ensureVisible(self.active, self.tabs.items.len, strip_width);
    }
    // A reload or toggle that changes the decorations: the frame again
    // (maximizing and fullscreen recompute it as they happen).
    const captionless_now = self.captionless();
    if (captionless_now != self.captionless_frame) {
        self.captionless_frame = captionless_now;
        _ = c.SetWindowPos(self.hwnd, null, 0, 0, 0, 0, c.SWP_FRAMECHANGED | c.SWP_NOMOVE |
            c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE);
    }
    // The chrome changes height (the tab row comes or goes, the header bar
    // with a maximize or fullscreen): paint it, or the terminal where it
    // was.
    const chrome = self.chromeHeight();
    const zoomed = c.IsZoomed(self.hwnd) != 0;
    if (chrome != self.chrome_shown) {
        self.chrome_shown = chrome;
        _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
    } else if (strip_width != self.chrome_width or zoomed != self.chrome_zoomed) {
        // Windows keeps the old pixels and repaints only what a wider
        // window adds: the right-aligned buttons, the centered title and
        // the maximize button's glyph would stay where they were.
        const r = self.chromeRect();
        _ = c.InvalidateRect(self.hwnd, &r, c.FALSE);
    }
    self.chrome_width = strip_width;
    self.chrome_zoomed = zoomed;
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
    self.placeTooltip();
    if (self.palette.isOpen()) self.palette.layout();
    if (self.toast.visible()) {
        self.toast.layout();
        // Above a tab created after it.
        self.toast.raise();
    }
}

/// Show an in-app notification (GTK's toast) for 3 seconds, in the active
/// pane's colors.
pub fn showToast(self: *Window, text: []const u8) void {
    if (self.activeSurface()) |s| {
        const bg = s.colors.bg;
        const fg = s.colors.fg;
        // A dark pill on a dark terminal, as GTK's OSD toasts: a little
        // toward the foreground.
        self.toast.bg = c.rgb(blend(bg.r, fg.r), blend(bg.g, fg.g), blend(bg.b, fg.b));
        self.toast.fg = c.rgb(fg.r, fg.g, fg.b);
    }
    self.toast.show(self.hwnd, text, 3000);
}

fn blend(a: u8, b: u8) u8 {
    return @intCast((@as(u16, a) * 4 + b) / 5);
}

/// The toast's text, for the GUI tests' dump.
pub fn toastText(self: *const Window) []const u16 {
    return if (self.toast.visible()) self.toast.textUtf16() else &.{};
}

/// Resize the window so its surface area is the given size in points
/// (1/96 inch), the unit of the core's initial_size and resize_window
/// actions: it divides pixel sizes by the content scale. A zero
/// dimension keeps its current size, as resize_window requires.
pub fn setClientSize(self: *Window, width: u32, height: u32) void {
    // The quick terminal's config sizes it.
    if (self.quick != null or (width == 0 and height == 0)) return;
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
    self.resizeTabArea(w, h, true);
}

/// Size the window so its tab area is `w` x `h` device pixels: within the
/// monitor's work area as setClientSize asks (`fit`), or exactly, where it
/// is (toggleDecorations, which must keep the grid of a window spanning
/// monitors or partly off screen).
fn resizeTabArea(self: *Window, w: c_int, h: c_int, fit: bool) void {
    const dpi = c.GetDpiForWindow(self.hwnd);
    var rect: c.RECT = .{ .right = w, .bottom = h + self.chromeHeight() };
    self.adjustFrame(&rect, dpi);
    var win_w = rect.right - rect.left;
    var win_h = rect.bottom - rect.top;
    // Within the monitor's work area: never larger, and moved back in if
    // the new size would run off its right or bottom edge. A window placed
    // off every monitor on purpose (the GUI tests' captures) stays there.
    var pos: c.RECT = .{};
    _ = c.GetWindowRect(self.hwnd, &pos);
    var x = pos.left;
    var y = pos.top;
    var mi: c.MONITORINFO = .{};
    if (fit) if (c.MonitorFromWindow(self.hwnd, c.MONITOR_DEFAULTTONEAREST)) |monitor| {
        if (c.GetMonitorInfoW(monitor, &mi) != 0) {
            const work = mi.rcWork;
            win_w = @min(win_w, work.right - work.left);
            win_h = @min(win_h, work.bottom - work.top);
            const on_monitor = pos.left < work.right and pos.right > work.left and
                pos.top < work.bottom and pos.bottom > work.top;
            if (on_monitor) {
                x = @max(work.left, @min(x, work.right - win_w));
                y = @max(work.top, @min(y, work.bottom - win_h));
            }
        }
    };
    const moved = x != pos.left or y != pos.top;
    _ = c.SetWindowPos(
        self.hwnd,
        null,
        x,
        y,
        win_w,
        win_h,
        @as(c.UINT, if (moved) 0 else c.SWP_NOMOVE) | c.SWP_NOZORDER | c.SWP_NOACTIVATE,
    );
}

/// A program asked to resize the window (resize_window, from CSI 8 t when
/// `vt-window-resize-allowed` is on). As that option documents, it is
/// ignored in a split or in a window with several tabs, and while the
/// window is maximized or fullscreen; setClientSize keeps it within the
/// monitor's work area. Returns whether the window was resized.
pub fn resizeFromTerminal(self: *Window, width: u32, height: u32) bool {
    if (self.quick != null or self.tabs.items.len > 1) return false;
    if (self.activeTab()) |t| if (t.tree.isSplit()) return false;
    if (c.IsZoomed(self.hwnd) != 0 or self.fullscreen != null) return false;
    self.setClientSize(width, height);
    return true;
}

pub fn toggleMaximize(self: *Window) void {
    if (self.quick != null) return;
    // Both show the window: with those toggle_visibility hid.
    self.app.showWindows();
    _ = c.ShowWindow(self.hwnd, if (c.IsZoomed(self.hwnd) != 0) c.SW_RESTORE else c.SW_MAXIMIZE);
}

pub fn toggleFullscreen(self: *Window) void {
    if (self.quick != null) return;
    // `fullscreen` changes first: the layouts the moves cause show or hide
    // the strip by it (headerShown).
    if (self.fullscreen) |saved| {
        self.fullscreen = null;
        _ = c.SetWindowLongPtrW(self.hwnd, c.GWL_STYLE, saved.style);
        _ = c.SetWindowPlacement(self.hwnd, &saved.placement);
        _ = c.SetWindowPos(self.hwnd, null, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE |
            c.SWP_NOZORDER | c.SWP_NOOWNERZORDER | c.SWP_FRAMECHANGED);
        self.layout();
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

    self.fullscreen = saved;
    const style: usize = @bitCast(saved.style);
    _ = c.SetWindowLongPtrW(self.hwnd, c.GWL_STYLE, @bitCast(style & ~@as(usize, c.WS_OVERLAPPEDWINDOW)));
    const r = mi.rcMonitor;
    _ = c.SetWindowPos(self.hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, c.SWP_NOOWNERZORDER | c.SWP_FRAMECHANGED);
    self.layout();
}

pub fn present(self: *Window) void {
    // The quick terminal slides in, and leaves what toggle_visibility hid
    // hidden (its own toggle).
    if (self.quick) |*q| {
        if (!q.shown) return q.show(self);
    } else {
        // Coming forward brings back what toggle_visibility hid, as on
        // macOS.
        self.app.showWindows();
    }
    if (c.IsIconic(self.hwnd) != 0) _ = c.ShowWindow(self.hwnd, c.SW_RESTORE);
    _ = c.SetForegroundWindow(self.hwnd);
    // Activating the window is the point here.
    self.focusActiveNow();
}

/// Bring the tab holding `surface` to the front.
pub fn presentSurface(self: *Window, surface: *Surface) void {
    if (self.tabIndexOf(surface)) |i| {
        const tab = self.tabs.items[i];
        // End a zoom that hides the pane, and focus it.
        if (tab.tree.zoomed) |zoomed| {
            const handle = tab.tree.locate(surface).?;
            if (!Tab.Layout.isWithin(&tab.tree, handle, zoomed)) _ = tab.unzoom();
        }
        tab.focused = surface;
        if (i != self.active) self.select(i);
        self.focusedPaneChanged(i);
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

/// The chrome's colors (App.chromeTheme).
pub fn chromeTheme(self: *const Window) draw.Theme {
    return self.app.chromeTheme();
}

/// Color the window for `window-theme` (chromeTheme): the header bar and
/// tab row as they paint, and what DWM draws, the system caption (without
/// client-side decorations), the border and the light or dark frame and
/// menus. Caption colors need Windows 11; Windows 10 only gets light or
/// dark.
pub fn applyChrome(self: *Window) void {
    const theme = self.chromeTheme();
    const chrome: Chrome = .{ .dark = theme.dark, .caption = draw.ref(theme.bar) };
    const dark: c.BOOL = @intFromBool(chrome.dark);
    // Attribute 20 is honored from Windows 10 2004 (build 19041); earlier
    // supported builds only know the undocumented 19.
    if (c.DwmSetWindowAttribute(self.hwnd, c.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, @sizeOf(c.BOOL)) < 0) {
        _ = c.DwmSetWindowAttribute(self.hwnd, c.DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1, &dark, @sizeOf(c.BOOL));
    }
    const caption = chrome.caption.?;
    const text_color = draw.ref(theme.fg);
    _ = c.DwmSetWindowAttribute(self.hwnd, c.DWMWA_CAPTION_COLOR, &caption, @sizeOf(c.COLORREF));
    _ = c.DwmSetWindowAttribute(self.hwnd, c.DWMWA_BORDER_COLOR, &caption, @sizeOf(c.COLORREF));
    _ = c.DwmSetWindowAttribute(self.hwnd, c.DWMWA_TEXT_COLOR, &text_color, @sizeOf(c.COLORREF));
    self.chrome = chrome;
    self.tab_bar.wide = self.app.config.@"gtk-wide-tabs";
    self.invalidateTabBar();
}

pub fn isDark(color: configpkg.Config.Color) bool {
    return draw.isDark(color);
}

/// The shade the header bar or tab row casts onto the content below
/// (gtk-toolbar-style), none without either.
pub fn shade(self: *const Window) draw.Shade {
    if (self.chromeHeight() == 0) return .none;
    return self.chromeTheme().shadeFor(self.app.config.@"gtk-toolbar-style");
}

/// A surface's colors changed (a program set them, or its config changed).
pub fn colorsChanged(self: *Window, surface: *Surface) void {
    if (self.tabIndexOf(surface)) |i| {
        const tab = self.tabs.items[i];
        // A pane dims toward its own background by default, and the
        // dividers follow the focused pane's.
        tab.syncDim();
        if (tab.focused == surface) _ = c.InvalidateRect(tab.hwnd, null, c.FALSE);
    }
    if (self.activeSurface() != surface) return;
    self.applyChrome();
    self.invalidateTabBar();
}

/// The config changed: the chrome, the tab bar's colors and visibility,
/// the panes' minimums (padding) and the dividers' color may differ.
pub fn configChanged(self: *Window) void {
    // window-title-font-family may have changed.
    self.tab_bar.setDpi(self.tab_bar.dpi, self.app.config.@"window-title-font-family");
    self.header.setDpi(self.header.dpi, self.app.config.@"window-title-font-family");
    self.applyChrome();
    // background-opacity and background-blur may have changed.
    self.syncTranslucent();
    self.syncBlur();
    for (self.tabs.items) |t| t.syncDim();
    // The quick terminal's position and size may have changed.
    if (self.quick) |*q| q.replace(self);
    self.layout();
    // An unchanged tab rectangle sends the tabs no WM_SIZE.
    for (self.tabs.items) |t| t.layoutPanes();
    _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
}

/// Make the window translucent, or opaque again, as App.translucent says
/// (roadmap 4.1, Phase A; spike S2). Blur-behind with an empty region
/// makes DWM compose the window with per-pixel alpha, blurring nothing
/// (4.2 brings the blur); the panes then present their frames' own alpha,
/// and what GDI paints goes through draw.AlphaPaint (the chrome and the
/// dividers opaque, as GTK's).
pub fn syncTranslucent(self: *Window) void {
    const on = self.app.translucent();
    if (on == self.translucent) return;
    // Without the empty region, blur-behind would blur the whole window.
    const region: ?c.HRGN = if (on) (c.CreateRectRgn(0, 0, -1, -1) orelse return) else null;
    defer if (region) |r| {
        _ = c.DeleteObject(r);
    };
    const bb: c.DWM_BLURBEHIND = .{
        .dwFlags = c.DWM_BB_ENABLE | @as(c.DWORD, if (on) c.DWM_BB_BLURREGION else 0),
        .fEnable = @intFromBool(on),
        .hRgnBlur = region,
    };
    const hr = c.DwmEnableBlurBehindWindow(self.hwnd, &bb);
    if (hr < 0) {
        // The window stays as DWM composes it: turning on, frames with
        // their own alpha would show darker, not see-through; turning off,
        // GDI's alpha 0 would show the backdrop through the chrome.
        log.warn("DwmEnableBlurBehindWindow failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
        return;
    }
    self.translucent = on;
    var it = self.panes();
    while (it.next()) |s| s.setTranslucent(on);
    _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
    for (self.tabs.items) |t| _ = c.InvalidateRect(t.hwnd, null, c.FALSE);
    self.syncBlur();
}

/// Blur what shows through the translucent window while background-blur
/// is on (roadmap 4.2), as App.blurMethod says: over the blur-behind that
/// makes it translucent, as Tauri's window-vibrancy does. As GTK, the
/// blur's intensity is ignored and fullscreen keeps it; an opaque window
/// (toggled, or at an opacity of 1) has none. Windows draws Acrylic in its
/// solid color while the window is inactive (documented for background
/// acrylic; kitty's and PowerToys' Windows ports met it), where GTK's blur
/// stays, so an inactive window takes the accent policy's plain blur
/// instead. That one lags while a window is dragged or resized on 22H2
/// and later, which only an active window is.
pub fn syncBlur(self: *Window) void {
    const method = self.app.blurMethod();
    // The test hooks can ask for Acrylic while inactive, to see it.
    const keep_acrylic = if (comptime test_hooks.enabled) self.app.test_state.force_blur == .acrylic else false;
    const want: Blur = if (!self.translucent or !self.app.config.@"background-blur".enabled())
        .none
    else if (method == .backdrop and !keep_acrylic and (!self.active_window or self.acrylic_refused) and App.accentFn() != null)
        .accent
    else
        method;
    if (want == self.blur) return;
    // Take the one in place off first. If that fails it stays as it is,
    // and the next change tries again.
    const removed = switch (self.blur) {
        .none => true,
        .backdrop => self.setBackdrop(c.DWMSBT_AUTO),
        .accent => self.setAccent(c.ACCENT_DISABLED),
    };
    if (!removed) return;
    self.blur = .none;
    switch (want) {
        .none => {},
        // Acrylic refused: the accent policy's blur, where there is one.
        .backdrop => if (self.setBackdrop(c.DWMSBT_TRANSIENTWINDOW)) {
            self.blur = .backdrop;
        } else {
            self.acrylic_refused = true;
            if (self.setAccent(c.ACCENT_ENABLE_BLURBEHIND)) self.blur = .accent;
        },
        .accent => if (self.setAccent(c.ACCENT_ENABLE_BLURBEHIND)) {
            self.blur = .accent;
        },
    }
}

/// DWM's system backdrop: Acrylic, or the default (no backdrop under the
/// client) again. Whether DWM took it.
fn setBackdrop(self: *Window, kind: c.DWORD) bool {
    const hr = c.DwmSetWindowAttribute(self.hwnd, c.DWMWA_SYSTEMBACKDROP_TYPE, &kind, @sizeOf(c.DWORD));
    if (hr < 0) log.warn("DWMWA_SYSTEMBACKDROP_TYPE {d} failed hr=0x{x}", .{ kind, @as(u32, @bitCast(hr)) });
    return hr >= 0;
}

/// The accent policy: its blur behind the window (untinted, the flags
/// window-vibrancy passes), or off. Whether user32 took it.
fn setAccent(self: *Window, state: c.DWORD) bool {
    const set = App.accentFn() orelse return false;
    var policy: c.ACCENT_POLICY = .{ .AccentState = state, .AccentFlags = if (state == c.ACCENT_DISABLED) 0 else 2 };
    var data: c.WINDOWCOMPOSITIONATTRIBDATA = .{ .Attrib = c.WCA_ACCENT_POLICY, .pvData = &policy, .cbData = @sizeOf(c.ACCENT_POLICY) };
    if (set(self.hwnd, &data) == 0) {
        log.warn("SetWindowCompositionAttribute accent {d} failed err={}", .{ state, c.GetLastError() });
        return false;
    }
    return true;
}

//---------------------------------------------------------------
// Tab bar input and painting

/// Paint the header bar and the tab row, and anything of the client area
/// the tabs don't cover yet (while resizing) in the terminal's background
/// rather than leaving it black. WS_CLIPCHILDREN keeps this off the tabs.
fn paint(self: *Window) void {
    var ps: c.PAINTSTRUCT = undefined;
    const hdc = c.BeginPaint(self.hwnd, &ps) orelse return;
    defer _ = c.EndPaint(self.hwnd, &ps);
    self.paintTo(hdc, ps.rcPaint);
}

/// What `paint` draws over `rect`, into `hdc` (also the test hooks'
/// read-back of the chrome). Translucent, through a buffer that makes the
/// chrome opaque, as GTK's bars are, and what the tabs don't cover yet the
/// background at its opacity.
pub fn paintTo(self: *Window, hdc: c.HDC, rect: c.RECT) void {
    const buffer = if (self.translucent) draw.AlphaPaint.begin(hdc, rect) else null;
    const buf = buffer orelse return self.paintChrome(hdc);
    defer buf.end();
    self.paintChrome(buf.dc);
    buf.setAlpha(null, 255);
    const alpha = self.app.backgroundAlpha();
    const below = self.tabRect(self.tabs.items.len);
    draw.fill(buf.dc, below, draw.ref(draw.premultiply(self.chromeColors().bg, alpha)));
    buf.setAlpha(&below, alpha);
}

/// The chrome, and what the tabs don't cover yet, into `hdc`.
fn paintChrome(self: *Window, hdc: c.HDC) void {
    const colors = self.chromeColors();
    var below = self.tabRect(self.tabs.items.len);
    if (c.CreateSolidBrush(c.rgb(colors.bg.r, colors.bg.g, colors.bg.b))) |brush| {
        defer _ = c.DeleteObject(brush);
        _ = c.FillRect(hdc, &below, brush);
    }
    const pal = draw.palette(self.chromeTheme(), !self.active_window);
    const width = self.clientWidth();
    const maximized = c.IsZoomed(self.hwnd) != 0;
    if (self.headerHeight() > 0) {
        // The caption's text, which syncTitle keeps.
        var title: [512]u16 = undefined;
        const n = c.GetWindowTextW(self.hwnd, &title, title.len);
        self.header.paint(hdc, width, self.header.height(), title[0..@intCast(@max(n, 0))], self.tab_bar.hover, self.pressed, maximized, pal);
    }
    if (!self.tabBarVisible()) return;

    // Every title: the row is laid out (and hit-tested) for all the tabs.
    const alloc = self.app.core_app.alloc;
    const titles = alloc.alloc([]const u8, self.tabs.items.len) catch return;
    defer alloc.free(titles);
    const attention = alloc.alloc(bool, self.tabs.items.len) catch return;
    defer alloc.free(attention);
    @memset(titles, "");
    defer for (titles) |t| if (t.len > 0) alloc.free(t);
    // The labels: the bell and zoom marks before the title.
    for (self.tabs.items, titles, attention) |tab, *t, *a| {
        t.* = tab.label(alloc) catch "";
        a.* = tab.attention;
    }

    if (self.tabsTitlebar()) {
        // The tab row as the title bar: the header's buttons around the
        // tabs, put together off screen and shown at once, so no frame
        // shows the row without its tabs.
        const h = self.tab_bar.height();
        const mem = c.CreateCompatibleDC(hdc);
        defer if (mem) |m| {
            _ = c.DeleteDC(m);
        };
        const bmp = if (mem != null) c.CreateCompatibleBitmap(hdc, width, h) else null;
        defer if (bmp) |b| {
            _ = c.DeleteObject(b);
        };
        if (mem != null and bmp != null) {
            const old = c.SelectObject(mem.?, bmp);
            defer _ = c.SelectObject(mem.?, old);
            self.header.paint(mem.?, width, h, &.{}, self.tab_bar.hover, self.pressed, maximized, pal);
            self.tab_bar.paint(mem.?, 0, width, titles, attention, self.active, pal);
            _ = c.BitBlt(hdc, 0, 0, width, h, mem.?, 0, 0, c.SRCCOPY);
        } else {
            // No bitmap to spare: straight to the window, as before.
            self.header.paint(hdc, width, h, &.{}, self.tab_bar.hover, self.pressed, maximized, pal);
            self.tab_bar.paint(hdc, 0, width, titles, attention, self.active, pal);
        }
    } else {
        self.tab_bar.paint(hdc, self.headerHeight(), width, titles, attention, self.active, pal);
    }
    self.painted_bell = 0;
    self.painted_attention = 0;
    for (titles, attention, 0..) |t, a, i| {
        if (i >= 64) break;
        const bit = @as(u64, 1) << @intCast(i);
        if (std.mem.startsWith(u8, t, "\u{1F514}")) self.painted_bell |= bit;
        if (a) self.painted_attention |= bit;
    }
}

/// The tab strip's menu for tab `index`, at the press in `lparam`. What
/// was chosen runs on the tab's focused pane.
fn tabMenu(self: *Window, index: usize, lparam: c.LPARAM) void {
    const surface = self.tabs.items[index].focused;
    var pt: c.POINT = .{ .x = c.xParam(lparam), .y = c.yParam(lparam) };
    _ = c.ClientToScreen(self.hwnd, &pt);
    const chosen = ContextMenu.trackTab(surface, .{ .index = index, .count = self.tabs.items.len }, pt) orelse return;
    self.performOnPane(surface, chosen);
}

/// Scroll an overflowing strip by `tabs` tabs.
fn scrollTabs(self: *Window, tabs: c_int) void {
    if (self.tab_bar.scrollTabs(tabs, self.tabs.items.len, self.clientWidth())) {
        self.invalidateTabBar();
    }
}

/// The list button and toggle_tab_overview: the command palette listing
/// this window's tabs (roadmap 3.8; decided 2026-10-25, a list rather
/// than GTK's overview of live thumbnails).
pub fn toggleTabList(self: *Window) void {
    const surface = self.activeSurface() orelse return;
    self.palette.toggleTabs(self, surface);
}

/// The menu on the arrow beside "+": splits of the active tab's pane.
fn splitMenu(self: *Window) void {
    const surface = self.activeSurface() orelse return;
    const r = self.header.place(self.clientWidth()).new_tab_menu;
    var pt: c.POINT = .{ .x = r.left, .y = r.bottom };
    _ = c.ClientToScreen(self.hwnd, &pt);
    const chosen = ContextMenu.trackSplit(surface, pt) orelse return;
    self.performOnPane(surface, chosen);
}

/// The main menu, under its button in the header bar, for the active tab's
/// focused pane.
fn mainMenu(self: *Window) void {
    const surface = self.activeSurface() orelse return;
    const r = self.header.place(self.clientWidth()).menu;
    var pt: c.POINT = .{ .x = r.right, .y = r.bottom };
    _ = c.ClientToScreen(self.hwnd, &pt);
    self.runChoice(surface, ContextMenu.trackMain(surface, pt) orelse return);
}

/// Run what was chosen from the main menu or the system menu.
fn runChoice(self: *Window, surface: *Surface, choice: ContextMenu.Choice) void {
    switch (choice) {
        .action => |a| self.performOnPane(surface, a),
        .about => self.app.showAbout(self.hwnd),
        .notify_next => surface.notify_next_command = !surface.notify_next_command,
    }
}

/// The window's button a non-client hit code names.
fn controlHit(code: c.WPARAM) TabBar.Hit {
    return switch (code) {
        c.HTMINBUTTON => .minimize,
        c.HTMAXBUTTON => .maximize,
        c.HTCLOSE => .window_close,
        else => .none,
    };
}

fn isControl(hit: TabBar.Hit) bool {
    return switch (hit) {
        .minimize, .maximize, .window_close => true,
        else => false,
    };
}

/// A click on one of the window's buttons in the header bar: what the
/// caption's would do.
fn runControl(self: *Window, hit: TabBar.Hit) void {
    const cmd: c.WPARAM = switch (hit) {
        .minimize => c.SC_MINIMIZE,
        .maximize => if (c.IsZoomed(self.hwnd) != 0) c.SC_RESTORE else c.SC_MAXIMIZE,
        .window_close => c.SC_CLOSE,
        else => return,
    };
    _ = c.PostMessageW(self.hwnd, c.WM_SYSCOMMAND, cmd, 0);
}

/// The system menu at screen point (x, y), as DefWindowProc shows it over
/// its own caption: murrtty's items current, Windows' enabled for the
/// window's state, the choice run as WM_SYSCOMMAND.
fn systemMenuAt(self: *Window, x: c_int, y: c_int) void {
    const menu = c.GetSystemMenu(self.hwnd, c.FALSE) orelse return;
    if (self.activeSurface()) |s| self.system_menu.refresh(s, menu);
    const zoomed = c.IsZoomed(self.hwnd) != 0;
    for ([_]struct { c.UINT, bool }{
        .{ c.SC_RESTORE, zoomed },
        .{ c.SC_MOVE, !zoomed },
        .{ c.SC_SIZE, !zoomed },
        .{ c.SC_MINIMIZE, true },
        .{ c.SC_MAXIMIZE, !zoomed },
        .{ c.SC_CLOSE, true },
    }) |item| {
        _ = c.EnableMenuItem(menu, item[0], if (item[1]) c.MF_STRING else c.MF_GRAYED);
    }
    self.beginMenuModal();
    const cmd = c.TrackPopupMenuEx(menu, c.TPM_RETURNCMD | c.TPM_RIGHTBUTTON, x, y, self.hwnd, null);
    // WM_EXITMENULOOP has ended it already, unless the loop never began.
    self.endMenuModal();
    // So the menu closes properly the next time (KB135788).
    _ = c.PostMessageW(self.hwnd, c.WM_NULL, 0, 0);
    if (cmd > 0) _ = c.PostMessageW(self.hwnd, c.WM_SYSCOMMAND, @intCast(cmd), 0);
}

fn beginMenuModal(self: *Window) void {
    if (self.menu_modal == null) self.menu_modal = self.app.beginModal(self.hwnd, .{ .disable_others = false });
}

fn endMenuModal(self: *Window) void {
    if (self.menu_modal) |*m| m.end();
    self.menu_modal = null;
}

/// Run a menu's choice on `surface` after the menu's loop, during which
/// closes wait (App.request), so the pane is still there.
fn performOnPane(self: *Window, surface: *Surface, action: input.Binding.Action) void {
    _ = self;
    if (!surface.core_initialized) return;
    _ = surface.core_surface.performBindingAction(action) catch |err| {
        log.warn("error performing a menu action err={}", .{err});
    };
}

/// The chrome's item at the client point in `lparam`: the header bar's
/// (its buttons; the window's come as non-client messages) or the tab
/// row's.
fn tabBarHit(self: *const Window, lparam: c.LPARAM) TabBar.Hit {
    return self.chromeHit(c.xParam(lparam), c.yParam(lparam));
}

/// The chrome's item at (`x`, `y`) in client coordinates: a header bar
/// button (in the tab row when it is the title bar) or a tab's.
fn chromeHit(self: *const Window, x: c_int, y: c_int) TabBar.Hit {
    const width = self.clientWidth();
    const n = self.tabs.items.len;
    if (self.tabsTitlebar()) {
        if (!self.tabBarVisible()) return .none;
        const hit = self.header.hitTest(x, y, width);
        if (hit != .none) return hit;
        return self.tab_bar.hitTest(x, y, n, width);
    }
    const header = self.headerHeight();
    if (y < header) return self.header.hitTest(x, y, width);
    if (!self.tabBarVisible()) return .none;
    return self.tab_bar.hitTest(x, y - header, n, width);
}

fn setHover(self: *Window, hit: TabBar.Hit) void {
    if (hit.eql(self.tab_bar.hover)) return;
    self.tab_bar.hover = hit;
    self.invalidateTabBar();
    // Another item: hide the tooltip, which asks for its text again when
    // it next shows.
    if (self.tooltip) |tip| _ = c.SendMessageW(tip, c.TTM_POP, 0, 0);
}

/// The icons at `dpi`, from the executable's icon (whose sizes run from 16
/// to 256 px), so neither the caption's nor the taskbar's is a scaled one.
fn loadIcons(self: *Window, dpi: c.UINT) void {
    const instance = self.app.instance;
    const small = c.LoadImageW(instance, 1, c.IMAGE_ICON, c.GetSystemMetricsForDpi(c.SM_CXSMICON, dpi), c.GetSystemMetricsForDpi(c.SM_CYSMICON, dpi), 0);
    const big = c.LoadImageW(instance, 1, c.IMAGE_ICON, c.GetSystemMetricsForDpi(c.SM_CXICON, dpi), c.GetSystemMetricsForDpi(c.SM_CYICON, dpi), 0);
    if (small) |h| _ = c.SendMessageW(self.hwnd, c.WM_SETICON, c.ICON_SMALL, @bitCast(@intFromPtr(h)));
    if (big) |h| _ = c.SendMessageW(self.hwnd, c.WM_SETICON, c.ICON_BIG, @bitCast(@intFromPtr(h)));
    // The old ones once the new are set.
    for ([_]struct { ?c.HICON, ?c.HANDLE }{ .{ self.small_icon, small }, .{ self.big_icon, big } }) |pair| {
        if (pair[1] != null) if (pair[0]) |old| {
            _ = c.DestroyIcon(old);
        };
    }
    if (small) |h| {
        self.small_icon = @ptrCast(h);
        self.icon_widths[0] = c.GetSystemMetricsForDpi(c.SM_CXSMICON, dpi);
    }
    if (big) |h| {
        self.big_icon = @ptrCast(h);
        self.icon_widths[1] = c.GetSystemMetricsForDpi(c.SM_CXICON, dpi);
    }
}

/// The tab strip's tooltip: one tool over the strip, its text asked for
/// when it shows (WM_NOTIFY, TTN_GETDISPINFOW) for the item under the mouse.
fn createTooltip(self: *Window) void {
    const tip = c.CreateWindowExW(0, c.TOOLTIPS_CLASSW, c.L(""), c.WS_POPUP | c.TTS_ALWAYSTIP | c.TTS_NOPREFIX, c.CW_USEDEFAULT, c.CW_USEDEFAULT, c.CW_USEDEFAULT, c.CW_USEDEFAULT, self.hwnd, null, self.app.instance, null) orelse {
        log.warn("tab strip tooltip not created err={d}", .{c.GetLastError()});
        return;
    };
    var info: c.TTTOOLINFOW = .{
        .uFlags = c.TTF_SUBCLASS,
        .hwnd = self.hwnd,
        .uId = 1,
        .rect = self.chromeRect(),
        .lpszText = c.LPSTR_TEXTCALLBACKW,
    };
    _ = c.SendMessageW(tip, c.TTM_ADDTOOLW, 0, @bitCast(@intFromPtr(&info)));
    // Lines: a tab's title, then its directory.
    _ = c.SendMessageW(tip, c.TTM_SETMAXTIPWIDTH, 0, 600);
    self.tooltip = tip;
}

/// The tool covers the header bar and the tab row.
fn placeTooltip(self: *Window) void {
    const tip = self.tooltip orelse return;
    var info: c.TTTOOLINFOW = .{
        .hwnd = self.hwnd,
        .uId = 1,
        .rect = self.chromeRect(),
    };
    _ = c.SendMessageW(tip, c.TTM_NEWTOOLRECTW, 0, @bitCast(@intFromPtr(&info)));
}

/// What the tooltip says over `hit`: a tab's title and, beneath, its
/// directory (decided 2026-10-25; GTK's shows only the directory); a
/// button's name and its key binding. Empty for nothing.
pub fn tooltipText(self: *Window, alloc: std.mem.Allocator, hit: TabBar.Hit) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    switch (hit) {
        .none => {},
        .tab, .close => |i| if (i < self.tabs.items.len) {
            const tab = self.tabs.items[i];
            const title = tab.title();
            try w.writeAll(title);
            const s = tab.focused;
            if (s.core_initialized) if (try s.core_surface.pwd(alloc)) |pwd| {
                defer alloc.free(pwd);
                if (pwd.len > 0 and std.mem.indexOf(u8, title, pwd) == null) try w.print("\n{s}", .{pwd});
            };
        },
        .new_tab => try self.writeButton(w, "New Tab", .new_tab),
        .new_tab_menu => try w.writeAll("Split"),
        .list => try self.writeButton(w, "Tab List", .toggle_tab_overview),
        .menu => try w.writeAll("Menu"),
        .scroll_left => try w.writeAll("Scroll Tabs Left"),
        .scroll_right => try w.writeAll("Scroll Tabs Right"),
        // The window's buttons are the caption's: Windows' own tips.
        .minimize, .maximize, .window_close => {},
    }
    return out.toOwnedSlice();
}

/// A button's name, then its action's binding in parentheses, if any.
fn writeButton(self: *Window, w: *std.Io.Writer, name: []const u8, action: input.Binding.Action) !void {
    try w.writeAll(name);
    const trigger = self.app.config.keybind.set.getTrigger(action) orelse return;
    try w.writeAll(" (");
    try ContextMenu.writeTrigger(w, trigger);
    try w.writeAll(")");
}

/// The tooltip asks for its text: the item under the mouse's.
fn tooltipNeedsText(self: *Window, info: *c.NMTTDISPINFOW) void {
    const alloc = self.app.core_app.alloc;
    self.tooltip_text[0] = 0;
    info.lpszText = &self.tooltip_text;
    const text = self.tooltipText(alloc, self.tab_bar.hover) catch return;
    defer alloc.free(text);
    const n = std.unicode.utf8ToUtf16Le(self.tooltip_text[0 .. self.tooltip_text.len - 1], text_util.truncate(text, 400)) catch 0;
    self.tooltip_text[n] = 0;
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
        // CreateWindowExW sends WM_SIZE (and the layout using the handle)
        // before it returns it.
        if (cs.lpCreateParams) |p| {
            const self: *Window = @ptrCast(@alignCast(p));
            self.hwnd = hwnd;
        }
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
            _ = self.app.mouseMoved(hwnd, c.xParam(lparam), c.yParam(lparam));
            if (!self.tab_bar.tracking) {
                var tme: c.TRACKMOUSEEVENT = .{ .dwFlags = c.TME_LEAVE, .hwndTrack = hwnd };
                if (c.TrackMouseEvent(&tme) != 0) self.tab_bar.tracking = true;
            }
            self.setHover(self.tabBarHit(lparam));
            if (self.tab_drag != null) self.dragTab(c.xParam(lparam), c.yParam(lparam));
            return 0;
        },

        // A tab dragged (roadmap 4.5) is dropped.
        c.WM_LBUTTONUP => {
            self.dropTab(c.xParam(lparam), c.yParam(lparam));
            return 0;
        },

        // Another window took the mouse: the tab stays where it got to.
        c.WM_CAPTURECHANGED => {
            if (lparam != @as(c.LPARAM, @bitCast(@intFromPtr(hwnd)))) self.tab_drag = null;
            return 0;
        },

        c.WM_MOUSELEAVE => {
            self.tab_bar.tracking = false;
            // Leaving for a window button, whose WM_NCMOUSEMOVE may come
            // first: that hover is the non-client tracking's to end.
            if (!isControl(self.tab_bar.hover)) self.setHover(.none);
            return 0;
        },

        c.WM_LBUTTONDOWN => {
            const hit = self.tabBarHit(lparam);
            self.last_press = hit;
            switch (hit) {
                // The window's buttons come as non-client messages.
                .none, .minimize, .maximize, .window_close => {},
                // Selected, and maybe dragged (dragTab).
                .tab => |i| {
                    self.select(i);
                    self.tab_drag = .{ .tab = self.tabs.items[i], .start = .{ .x = c.xParam(lparam), .y = c.yParam(lparam) } };
                    _ = c.SetCapture(hwnd);
                },
                .close => |i| self.requestCloseTab(i),
                .new_tab => self.newTabFromActive(),
                .new_tab_menu => self.splitMenu(),
                .menu => self.mainMenu(),
                .list => self.toggleTabList(),
                .scroll_left => self.scrollTabs(-1),
                .scroll_right => self.scrollTabs(1),
            }
            return 0;
        },

        // The second press of a double click: on the tab the first press
        // was on, it renames the tab (murrtty's; from the message loop, as
        // any prompt). Anything else is just another click: the first
        // press may have moved the tabs ("+" adds one, "x" closes one).
        c.WM_LBUTTONDBLCLK => {
            const hit = self.tabBarHit(lparam);
            const same_tab = switch (hit) {
                .tab => |i| std.meta.eql(self.last_press, TabBar.Hit{ .tab = i }),
                else => false,
            };
            self.last_press = hit;
            switch (hit) {
                .none, .minimize, .maximize, .window_close => {},
                .tab => |i| {
                    self.select(i);
                    if (same_tab) if (self.activeSurface()) |s| self.app.promptTitle(s, .tab);
                },
                .close => |i| self.requestCloseTab(i),
                .new_tab => self.newTabFromActive(),
                .new_tab_menu => self.splitMenu(),
                .menu => self.mainMenu(),
                .list => self.toggleTabList(),
                .scroll_left => self.scrollTabs(-1),
                .scroll_right => self.scrollTabs(1),
            }
            return 0;
        },

        // The wheel over the strip scrolls an overflowing one, a tab a notch
        // (towards the end for the wheel's down and right).
        c.WM_MOUSEWHEEL, c.WM_MOUSEHWHEEL => {
            var pt: c.POINT = .{ .x = c.xParam(lparam), .y = c.yParam(lparam) };
            _ = c.ScreenToClient(self.hwnd, &pt);
            const row = self.tabBarRect();
            if (!self.tabBarVisible() or pt.y < row.top or pt.y >= row.bottom) {
                return c.DefWindowProcW(hwnd, msg, wparam, lparam);
            }
            // Touchpads and smooth wheels send less than a notch at a time:
            // the rest waits for the next.
            const delta: i16 = @bitCast(c.hiword(wparam));
            self.wheel_rest += if (msg == c.WM_MOUSEWHEEL) -@as(c_int, delta) else delta;
            const toward_end = @divTrunc(self.wheel_rest, c.WHEEL_DELTA);
            self.wheel_rest -= toward_end * c.WHEEL_DELTA;
            if (toward_end != 0) self.scrollTabs(toward_end);
            return 0;
        },

        c.WM_MBUTTONUP => {
            switch (self.tabBarHit(lparam)) {
                .tab, .close => |i| self.requestCloseTab(i),
                else => {},
            }
            return 0;
        },

        // A tab's menu, on the press as the terminal's (GTK opens menus on
        // the press).
        c.WM_RBUTTONDOWN => {
            switch (self.tabBarHit(lparam)) {
                .tab, .close => |i| self.tabMenu(i, lparam),
                else => {},
            }
            return 0;
        },

        c.WM_ACTIVATE => {
            if (c.loword(wparam) == c.WA_INACTIVE) if (self.quick) |*q| {
                // quick-terminal-autohide, as GTK's: another window took
                // the keyboard (not one of its own dialogs; while it slides
                // in, the slide's end checks).
                const to: ?c.HWND = if (lparam != 0) @ptrFromInt(@as(usize, @bitCast(lparam))) else null;
                const own = if (to) |t| c.GetAncestor(t, c.GA_ROOTOWNER) == hwnd else false;
                if (q.shown and q.slide == null and !own and self.wantsAutohide()) q.autohide(self);
            };
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

        // window-step-resize (roadmap 4.6): whole cells as it is dragged.
        c.WM_SIZING => {
            if (!self.app.config.@"window-step-resize") return c.DefWindowProcW(hwnd, msg, wparam, lparam);
            self.stepResize(@ptrFromInt(@as(usize, @bitCast(lparam))), wparam);
            return 1;
        },

        c.WM_GETMINMAXINFO => {
            // The quick terminal's config sizes it.
            if (self.quick != null) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
            const min = self.minimumTabArea() orelse return 0;
            const info: *c.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
            // The header bar's buttons side by side, as GTK's minimum
            // width holds them: narrower, they would overlap.
            const width = if (self.csd() or self.tabsTitlebar()) @max(min.width, self.header.minWidth()) else min.width;
            var rect: c.RECT = .{ .right = width, .bottom = min.height + self.chromeHeight() };
            self.adjustFrame(&rect, c.GetDpiForWindow(hwnd));
            info.ptMinTrackSize = .{ .x = rect.right - rect.left, .y = rect.bottom - rect.top };
            return 0;
        },

        // Client-side decorations (roadmap 4.3): no caption, the header
        // bar drawn in its place; or none at all (4.4). Maximized, the
        // window reaches past the monitor by its frame, so the client
        // starts that far down.
        c.WM_NCCALCSIZE => {
            if (wparam == 0 or !self.captionless()) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
            const params: *c.NCCALCSIZE_PARAMS = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const top = params.rgrc[0].top;
            const ret = c.DefWindowProcW(hwnd, msg, wparam, lparam);
            params.rgrc[0].top = top;
            if (c.IsZoomed(hwnd) != 0) {
                params.rgrc[0].top += self.frameY();
                insetForAutoHideTaskbars(&params.rgrc[0]);
            }
            return ret;
        },

        // Over the header bar: the caption between its buttons, the
        // caption's buttons over the window's (Windows 11 shows Snap
        // Layouts over HTMAXBUTTON), its own buttons as client clicks, and
        // the resize band along the top that the caption had, which a
        // window without decorations keeps too (over the tab row, or
        // passed on by the panes: inTopBand).
        c.WM_NCHITTEST => {
            const def = c.DefWindowProcW(hwnd, msg, wparam, lparam);
            if (def != c.HTCLIENT or !self.captionless()) return def;
            var pt: c.POINT = .{ .x = c.xParam(lparam), .y = c.yParam(lparam) };
            _ = c.ScreenToClient(hwnd, &pt);
            const width = self.clientWidth();
            const band = self.frameY();
            if (c.IsZoomed(hwnd) == 0 and pt.y < band) {
                if (pt.x < band) return c.HTTOPLEFT;
                if (pt.x >= width - band) return c.HTTOPRIGHT;
                return c.HTTOP;
            }
            if (pt.y >= self.titleBarHeight()) return def;
            return switch (self.chromeHit(pt.x, pt.y)) {
                .none => c.HTCAPTION,
                .minimize => c.HTMINBUTTON,
                .maximize => c.HTMAXBUTTON,
                .window_close => c.HTCLOSE,
                else => c.HTCLIENT,
            };
        },

        // The window's buttons, drawn by the header bar: hover, press and
        // click here, not in DefWindowProc, which would draw the old
        // caption buttons and run their loop. Other non-client mouse
        // messages (the caption's drag, double click and menu) are its.
        c.WM_NCMOUSEMOVE => {
            const hit = controlHit(wparam);
            if (hit != .none and !self.nc_tracking) {
                var tme: c.TRACKMOUSEEVENT = .{ .dwFlags = c.TME_LEAVE | c.TME_NONCLIENT, .hwndTrack = hwnd };
                if (c.TrackMouseEvent(&tme) != 0) self.nc_tracking = true;
            }
            if (hit != .none or isControl(self.tab_bar.hover)) self.setHover(hit);
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        c.WM_NCMOUSELEAVE => {
            self.nc_tracking = false;
            if (isControl(self.tab_bar.hover)) self.setHover(.none);
            if (self.pressed != .none) {
                self.pressed = .none;
                self.invalidateTabBar();
            }
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        c.WM_NCLBUTTONDOWN, c.WM_NCLBUTTONDBLCLK => {
            const hit = controlHit(wparam);
            if (hit == .none) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
            self.pressed = hit;
            self.invalidateTabBar();
            return 0;
        },
        c.WM_NCLBUTTONUP => {
            const was = self.pressed;
            if (was == .none) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
            self.pressed = .none;
            self.invalidateTabBar();
            if (controlHit(wparam).eql(was)) self.runControl(was);
            return 0;
        },

        // Active or not: the chrome's colors follow (libadwaita's backdrop),
        // and the blur (Acrylic only while active, syncBlur).
        c.WM_NCACTIVATE => {
            const active = wparam != 0;
            // The window toggle_visibility brings forward (never the quick
            // terminal, which comes with its own toggle).
            if (active and self.quick == null) self.app.last_window = self.id;
            if (active != self.active_window) {
                self.active_window = active;
                self.invalidateTabBar();
                self.syncBlur();
            }
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        // A right-click on the header bar's caption (WM_NCRBUTTONUP becomes
        // this): the system menu, which DefWindowProc shows only over a
        // caption it drew.
        c.WM_CONTEXTMENU => {
            if (self.csd() and lparam != -1) {
                var pt: c.POINT = .{ .x = c.xParam(lparam), .y = c.yParam(lparam) };
                _ = c.ScreenToClient(hwnd, &pt);
                if (pt.y >= 0 and pt.y < self.titleBarHeight() and
                    self.chromeHit(pt.x, pt.y) == .none)
                {
                    self.systemMenuAt(c.xParam(lparam), c.yParam(lparam));
                    return 0;
                }
            }
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        c.WM_DPICHANGED => {
            // The quick terminal keeps the DPI of the monitor it shows on
            // while it slides across another's edge.
            if (self.quick) |*q| if (!q.takesDpi(self, c.hiword(wparam))) return 0;
            self.tab_bar.setDpi(c.hiword(wparam), self.app.config.@"window-title-font-family");
            self.header.setDpi(c.hiword(wparam), self.app.config.@"window-title-font-family");
            self.loadIcons(c.hiword(wparam));
            // The panes first: the suggested size is checked against the
            // window's minimum (WM_GETMINMAXINFO), which their cells and
            // padding at the new DPI make up.
            var it = self.panes();
            while (it.next()) |s| s.dpiChanged();
            const r: *const c.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            // The quick terminal keeps its own place (it may cross a
            // monitor's edge as it slides).
            if (self.quick) |*q| {
                q.replace(self);
            } else _ = c.SetWindowPos(hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
            // An unchanged size sends the tabs no WM_SIZE.
            for (self.tabs.items) |t| t.layoutPanes();
            return 0;
        },

        c.WM_SETTINGCHANGE => {
            if (lparam != 0) {
                const name: [*:0]const u16 = @ptrFromInt(@as(usize, @bitCast(lparam)));
                if (std.mem.eql(u16, std.mem.span(name), c.L("ImmersiveColorSet"))) {
                    self.app.systemThemeChanged();
                }
            }
            self.app.systemSettingChanged();
            // The work area may have changed (the taskbar moved).
            if (self.quick) |*q| q.replace(self);
            return 0;
        },

        // The quick terminal's slide, and monitors changing under it.
        c.WM_TIMER => {
            if (wparam == QuickTerminal.timer_id) if (self.quick) |*q| q.tick(self);
            return 0;
        },
        c.WM_DISPLAYCHANGE => {
            if (self.quick) |*q| q.replace(self);
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        c.WM_CLOSE => {
            self.app.request(.{ .close_window = self.id });
            return 0;
        },

        // The strip's and header's menus, owner-drawn (ContextMenu).
        c.WM_MEASUREITEM => {
            if (ContextMenu.measureItem(lparam)) return 1;
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        c.WM_DRAWITEM => {
            if (ContextMenu.drawItem(lparam)) return 1;
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        c.WM_MENUCHAR => {
            if (ContextMenu.menuChar(wparam, lparam)) |r| return r;
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        // The system menu: murrtty's items, current, as it opens (not its
        // submenus, which open inside it), and its loop in a modal scope.
        // The scope opens on WM_ENTERMENULOOP (wparam FALSE; TrackPopupMenu
        // menus, wparam TRUE, have their own) or, for a way in that doesn't
        // say so (the taskbar's), when the system menu itself opens; it
        // ends with the loop. Only one menu loop runs at a time.
        c.WM_INITMENUPOPUP => {
            const menu: c.HMENU = @ptrFromInt(wparam);
            if (c.hiword(lparam) != 0) if (c.GetSystemMenu(hwnd, c.FALSE)) |sys| if (sys == menu) {
                self.beginMenuModal();
                if (self.activeSurface()) |s| self.system_menu.refresh(s, menu);
            };
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        c.WM_ENTERMENULOOP => {
            if (wparam == 0) self.beginMenuModal();
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        c.WM_EXITMENULOOP => {
            self.endMenuModal();
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        c.WM_SYSCOMMAND => {
            if (self.system_menu.choice(wparam)) |choice| {
                if (self.activeSurface()) |s| self.runChoice(s, choice);
                return 0;
            }
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        c.WM_NOTIFY => {
            const hdr: *const c.NMHDR = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (self.tooltip != null and hdr.hwndFrom == self.tooltip and hdr.code == c.TTN_GETDISPINFOW) {
                self.tooltipNeedsText(@ptrFromInt(@as(usize, @bitCast(lparam))));
                return 0;
            }
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        c.WM_DESTROY => {
            self.onDestroy();
            return 0;
        },

        else => {
            // The keyboard layout changed: a global binding's character may
            // be on another key now (roadmap 5.5).
            if (msg == c.WM_INPUTLANGCHANGE) self.app.global_keys.refresh(.layout);
            // The taskbar made the window's button (again, after Explorer
            // restarted): ITaskbarList3 can show progress on it now.
            if (msg == self.app.taskbar_button_msg and msg != 0) {
                self.taskbar_ready = true;
                self.app.taskbarButtonCreated();
                self.showProgress();
                return 0;
            }
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
    }
}
