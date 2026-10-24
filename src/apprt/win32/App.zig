//! The win32 application runtime. Owns the Win32 message loop and the
//! top-level windows.
const App = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const input = @import("../../input.zig");
const internal_os = @import("../../os/main.zig");
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");

const c = @import("c.zig");
const Surface = @import("Surface.zig");
const text_util = @import("text.zig");
const test_hooks = @import("test_hooks.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.win32);

const wakeup_class_name = c.L("GhosttyWakeup");
const WM_WAKEUP = c.WM_APP + 1;
const WM_RUN_REQUESTS = c.WM_APP + 2;
const WM_RAISE_MODAL = c.WM_APP + 3;

/// A request that closes tabs or windows. These never run inside a
/// callback from the core or while a modal dialog is open, because the
/// core or the dialog's caller may still be using what they would free:
/// `request` queues them and the message loop runs them. Targets are
/// identified by id, so a request for something already gone does nothing.
pub const Request = union(enum) {
    /// The core asked to close a surface (e.g. its process exited).
    close_surface: struct { id: u64, process_active: bool },
    close_tabs: struct { id: u64, mode: apprt.action.CloseTabMode },
    /// Close a window, confirming if a process is running.
    close_window: u64,
    close_all_windows,
    quit,
};

/// HWND_MESSAGE: the parent for message-only windows.
const HWND_MESSAGE: c.HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));

core_app: *CoreApp,
config: Config,
instance: c.HINSTANCE,

/// Message-only window that receives wakeups from other threads.
wakeup_hwnd: c.HWND,
wakeup_pending: std.atomic.Value(bool) = .init(false),

windows: std.ArrayList(*Window) = .empty,
next_window_id: u64 = 1,

/// Pending close requests, and how many modal dialogs are open.
requests: std.ArrayList(Request) = .empty,
modal_depth: u32 = 0,

/// The owner of the open dialog, so that a click on another (disabled)
/// window can bring the dialog forward.
modal_owner: ?c.HWND = null,

/// Whether the system uses a dark app theme.
dark: bool = false,

/// Set once we've begun quitting so we don't quit twice.
quitting: bool = false,

/// Whether OleInitialize succeeded, so terminate balances it.
ole_initialized: bool = false,

/// The GUI test harness's state dump (Debug builds only; see test_hooks).
test_state: test_hooks.State = .{},

pub fn init(
    self: *App,
    core_app: *CoreApp,

    // Required by the apprt interface but we don't use it.
    opts: struct {},
) !void {
    _ = opts;
    const alloc = core_app.alloc;

    var config = Config.load(alloc) catch |err| err: {
        var def: Config = try .default(alloc);
        errdefer def.deinit();
        try def.addDiagnosticFmt("error loading user configuration: {}", .{err});
        break :err def;
    };
    errdefer config.deinit();
    for (config._diagnostics.items()) |diag| {
        var buf: [1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        diag.format(&writer) catch {};
        log.warn("config: {s}", .{writer.buffered()});
    }

    // Whether Ctrl+C is ignored is inherited by child processes. If our
    // launcher had it ignored (e.g. it started us in a new process group),
    // shells and programs in our terminals would never receive Ctrl+C.
    // Restore normal processing so children always inherit it.
    _ = c.SetConsoleCtrlHandler(null, c.FALSE);

    // OLE, and with it single-threaded COM, for this UI thread. Shell, task
    // dialog and taskbar APIs need COM, and drag and drop needs OLE itself:
    // RegisterDragDrop fails if COM was started with CoInitializeEx instead.
    const ole = c.OleInitialize(null);
    if (ole < 0) log.warn("OleInitialize failed hr=0x{x}", .{@as(u32, @bitCast(ole))});
    errdefer if (ole >= 0) c.OleUninitialize();

    const instance = c.GetModuleHandleW(null) orelse return error.NoModuleHandle;
    try Window.registerClass(instance);
    try Surface.registerClass(instance);

    const wc: c.WNDCLASSEXW = .{
        .lpfnWndProc = &wakeupWndProc,
        .hInstance = instance,
        .lpszClassName = wakeup_class_name,
    };
    if (c.RegisterClassExW(&wc) == 0) return error.RegisterClassFailed;

    const wakeup_hwnd = c.CreateWindowExW(
        0,
        wakeup_class_name,
        c.L(""),
        0,
        0,
        0,
        0,
        0,
        HWND_MESSAGE,
        null,
        instance,
        null,
    ) orelse return error.CreateWindowFailed;

    self.* = .{
        .core_app = core_app,
        .config = config,
        .instance = instance,
        .wakeup_hwnd = wakeup_hwnd,
        .dark = systemDark(),
        .ole_initialized = ole >= 0,
        .test_state = test_hooks.init(alloc),
    };
    _ = c.SetWindowLongPtrW(wakeup_hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
}

pub fn run(self: *App) !void {
    // Apply the color scheme before the first surface so it starts
    // with the right conditional config.
    self.core_app.colorSchemeEvent(self, if (self.dark) .dark else .light) catch |err| {
        log.warn("error setting initial color scheme err={}", .{err});
    };

    // There is no IPC, tray or dock to open a window later, and the app
    // exits with its last window, so starting without one would leave an
    // invisible process behind. (The option is documented as Linux and
    // macOS only.)
    if (!self.config.@"initial-window") {
        log.warn("initial-window = false is not supported on Windows, ignoring it", .{});
    }

    _ = Window.create(self, null) catch |err| {
        // A GUI program has no console, so say why it can't start.
        const msg = std.fmt.allocPrint(
            self.core_app.alloc,
            "Ghostty could not open a window ({t}).\n\n" ++
                "Ghostty needs a graphics driver with OpenGL 4.3. Virtual machines " ++
                "and Remote Desktop sessions often don't provide it.\n\n" ++
                "To see the log, start Ghostty from a shell with: ghostty.exe 2> ghostty.log",
            .{err},
        ) catch return err;
        defer self.core_app.alloc.free(msg);
        _ = Surface.messageBox(self.core_app.alloc, null, msg, "Ghostty", c.MB_OK | c.MB_ICONERROR);
        return err;
    };

    var msg: c.MSG = undefined;
    while (true) {
        const ret = c.GetMessageW(&msg, null, 0, 0);
        if (ret == 0) break; // WM_QUIT
        if (ret == -1) return error.GetMessageFailed;
        _ = c.TranslateMessage(&msg);
        _ = c.DispatchMessageW(&msg);
    }
}

pub fn terminate(self: *App) void {
    while (self.windows.items.len > 0) {
        _ = c.DestroyWindow(self.windows.items[self.windows.items.len - 1].hwnd);
    }
    self.windows.deinit(self.core_app.alloc);
    self.requests.deinit(self.core_app.alloc);
    _ = c.DestroyWindow(self.wakeup_hwnd);
    test_hooks.deinit(&self.test_state, self.core_app.alloc);
    self.config.deinit();
    if (self.ole_initialized) c.OleUninitialize();
}

/// Queue a close request to run from the message loop.
pub fn request(self: *App, req: Request) void {
    self.requests.append(self.core_app.alloc, req) catch |err| {
        log.err("error queueing request {t} err={}", .{ req, err });
        return;
    };
    if (self.modal_depth == 0) _ = c.PostMessageW(self.wakeup_hwnd, WM_RUN_REQUESTS, 0, 0);
}

fn runRequests(self: *App) void {
    // Requests made while a dialog was open run when it closes.
    while (self.modal_depth == 0 and self.requests.items.len > 0) {
        const req = self.requests.orderedRemove(0);
        switch (req) {
            .close_surface => |v| if (self.findSurface(v.id)) |s| s.window.closeTab(s, v.process_active),
            .close_tabs => |v| if (self.findSurface(v.id)) |s| s.window.closeTabs(s, v.mode),
            .close_window => |id| if (self.findWindow(id)) |w| w.requestClose(),
            .close_all_windows => if (self.confirmCloseAll(
                "All terminal sessions will be terminated. Close all windows?",
                "Ghostty: Close All Windows",
            )) self.closeAllWindows(),
            .quit => self.quit(),
        }
    }
}

/// A nested modal loop in progress: a dialog, a popup menu or a file
/// picker. While one is open, close requests and clipboard confirmations
/// wait (see Request), because the loop can dispatch messages that would
/// otherwise free a window or surface the caller is still using. Every
/// nested loop runs inside one of these, opened with beginModal and closed
/// with end, usually through defer.
pub const Modal = struct {
    app: *App,
    prev_owner: ?c.HWND,
    disabled: std.ArrayList(c.HWND),
    /// modal_depth while this scope is open, to catch scopes ended out of
    /// order or twice (either would leave close requests held forever).
    depth: u32,
    ended: bool = false,

    pub fn end(self: *Modal) void {
        const app = self.app;
        if (self.ended) return;
        self.ended = true;
        std.debug.assert(app.modal_depth == self.depth);
        for (self.disabled.items) |hwnd| _ = c.EnableWindow(hwnd, c.TRUE);
        self.disabled.deinit(app.core_app.alloc);
        app.modal_owner = self.prev_owner;
        app.modal_depth -= 1;
        if (app.modal_depth == 0) app.resumeAfterModal();
    }
};

pub const ModalOptions = struct {
    /// Disable the windows other than the owner. Dialogs want this: they
    /// disable only their owner, and requests from every window wait while
    /// they are open, so the other windows' close buttons would look
    /// broken. A popup menu, which closes on any click outside it, does not.
    disable_others: bool = true,
};

pub fn beginModal(self: *App, owner: ?c.HWND, opts: ModalOptions) Modal {
    var modal: Modal = .{
        .app = self,
        .prev_owner = self.modal_owner,
        .disabled = .empty,
        .depth = self.modal_depth + 1,
    };
    if (opts.disable_others) {
        const alloc = self.core_app.alloc;
        for (self.windows.items) |w| {
            if (owner != null and w.hwnd == owner.?) continue;
            // EnableWindow returns 0 if the window was enabled before.
            if (c.EnableWindow(w.hwnd, c.FALSE) == 0) {
                modal.disabled.append(alloc, w.hwnd) catch {
                    _ = c.EnableWindow(w.hwnd, c.TRUE);
                };
            }
        }
    }
    self.modal_owner = owner;
    self.modal_depth += 1;
    return modal;
}

/// Ask a yes/no question with a modal dialog. Close requests made while
/// it is open are held until it closes.
pub fn confirm(self: *App, owner: ?c.HWND, text: []const u8, caption: []const u8) bool {
    var modal = self.beginModal(owner, .{});
    defer modal.end();
    return Surface.messageBox(
        self.core_app.alloc,
        owner,
        text,
        caption,
        c.MB_YESNO | c.MB_ICONWARNING | c.MB_DEFBUTTON2,
    );
}

pub const TaskDialog = struct {
    owner: ?c.HWND,
    /// The window caption.
    title: []const u8,
    /// The main instruction, shown large at the top.
    instruction: []const u8,
    content: []const u8 = "",
    /// Shown when the user expands "See details".
    expanded: []const u8 = "",
    icon: enum { none, information, warning, @"error" } = .none,
    /// Custom buttons, by id. Ids must not clash with the IDOK-style
    /// values of any common buttons also requested.
    buttons: []const Button = &.{},
    /// TDCBF_* flags.
    common_buttons: c_int = 0,
    /// The button chosen by Enter; 0 for the first one.
    default_button: c_int = 0,

    pub const Button = struct { id: c_int, text: []const u8 };
};

/// Show a task dialog in a modal scope. Returns the id of the chosen
/// button (IDCANCEL when dismissed with Escape or the close box), or null
/// if the dialog could not be shown; callers then fall back to confirm or
/// a MessageBox.
pub fn taskDialog(self: *App, td: TaskDialog) ?c_int {
    const taskDialogIndirect = resolveTaskDialog() orelse return null;

    var arena_state: std.heap.ArenaAllocator = .init(self.core_app.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const buttons = arena.alloc(c.TASKDIALOG_BUTTON, td.buttons.len) catch return null;
    for (td.buttons, buttons) |b, *out| out.* = .{
        .nButtonID = b.id,
        .pszButtonText = text_util.utf16Lossy(arena, b.text) catch return null,
    };

    const config: c.TASKDIALOGCONFIG = .{
        .hwndParent = td.owner,
        .dwFlags = c.TDF_ALLOW_DIALOG_CANCELLATION | c.TDF_POSITION_RELATIVE_TO_WINDOW,
        .dwCommonButtons = td.common_buttons,
        .pszWindowTitle = utf16Opt(arena, td.title) catch return null,
        .pszMainIcon = switch (td.icon) {
            .none => null,
            .information => c.TD_INFORMATION_ICON,
            .warning => c.TD_WARNING_ICON,
            .@"error" => c.TD_ERROR_ICON,
        },
        .pszMainInstruction = utf16Opt(arena, td.instruction) catch return null,
        .pszContent = utf16Opt(arena, td.content) catch return null,
        .cButtons = @intCast(buttons.len),
        .pButtons = if (buttons.len > 0) buttons.ptr else null,
        .nDefaultButton = td.default_button,
        .pszExpandedInformation = utf16Opt(arena, td.expanded) catch return null,
    };

    var modal = self.beginModal(td.owner, .{});
    defer modal.end();
    var chosen: c_int = 0;
    const hr = taskDialogIndirect(&config, &chosen, null, null);
    if (hr < 0) {
        log.warn("TaskDialogIndirect failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
        return null;
    }
    return chosen;
}

/// TaskDialogIndirect from comctl32 v6, or null where only v5 is loaded
/// (no manifest). Resolved once, on the UI thread.
fn resolveTaskDialog() ?c.TaskDialogIndirectFn {
    const S = struct {
        var resolved = false;
        var func: ?c.TaskDialogIndirectFn = null;
    };
    if (!S.resolved) {
        S.resolved = true;
        // The activation context from the exe's manifest makes this load
        // version 6.
        if (c.LoadLibraryW(c.L("comctl32.dll"))) |lib| {
            if (c.GetProcAddress(lib, "TaskDialogIndirect")) |p| S.func = @ptrCast(p);
        }
        if (S.func == null) log.warn("TaskDialogIndirect unavailable (comctl32 v6 not loaded)", .{});
    }
    return S.func;
}

/// UTF-16 copy of a string, or null for an empty one.
fn utf16Opt(alloc: Allocator, s: []const u8) !?c.LPCWSTR {
    if (s.len == 0) return null;
    return try text_util.utf16Lossy(alloc, s);
}

/// Run what waited for a dialog to close: close requests, and clipboard
/// confirmations that need a dialog of their own.
fn resumeAfterModal(self: *App) void {
    if (self.requests.items.len > 0) {
        _ = c.PostMessageW(self.wakeup_hwnd, WM_RUN_REQUESTS, 0, 0);
    }
    for (self.windows.items) |w| {
        for (w.surfaces.items) |s| s.resumeClipboardConfirms();
    }
}

/// Bring the open dialog forward. The windows it disabled don't own it,
/// so Windows doesn't do this for a click on them.
pub fn raiseModal(self: *App) void {
    const owner = self.modal_owner orelse return;
    // Minimizing the owner hides the dialog with it. Restore the owner so
    // the dialog is visible again, and never hand the keyboard to a hidden
    // one: a typed "y" would answer it.
    if (c.IsIconic(owner) != 0) _ = c.ShowWindow(owner, c.SW_RESTORE);
    const popup = c.GetLastActivePopup(owner);
    if (popup == owner or c.IsWindowVisible(popup) == 0) return;
    _ = c.SetForegroundWindow(popup);
}

/// raiseModal, from the message loop: for use while handling an
/// activation, which shouldn't start another.
pub fn postRaiseModal(self: *App) void {
    _ = c.PostMessageW(self.wakeup_hwnd, WM_RAISE_MODAL, 0, 0);
}

fn findWindow(self: *App, id: u64) ?*Window {
    for (self.windows.items) |w| {
        if (w.id == id) return w;
    }
    return null;
}

fn findSurface(self: *App, id: u64) ?*Surface {
    for (self.windows.items) |w| {
        for (w.surfaces.items) |s| {
            if (s.core_initialized and s.core_surface.id == id) return s;
        }
    }
    return null;
}

/// Called by CoreApp from any thread to wake up the event loop.
pub fn wakeup(self: *App) void {
    // Coalesce: one queued wakeup drains the whole mailbox.
    if (self.wakeup_pending.swap(true, .acq_rel)) return;
    _ = c.PostMessageW(self.wakeup_hwnd, WM_WAKEUP, 0, 0);
}

fn wakeupWndProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        WM_WAKEUP, WM_RUN_REQUESTS, WM_RAISE_MODAL => {
            const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
            if (ptr == 0) return 0;
            const self: *App = @ptrFromInt(@as(usize, @bitCast(ptr)));
            switch (msg) {
                WM_WAKEUP => {
                    self.wakeup_pending.store(false, .release);
                    self.core_app.tick(self) catch |err| {
                        log.err("error in app tick err={}", .{err});
                    };
                },
                WM_RUN_REQUESTS => self.runRequests(),
                else => self.raiseModal(),
            }
            return 0;
        },
        else => {
            if (comptime test_hooks.enabled) {
                const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
                if (ptr != 0) {
                    const self: *App = @ptrFromInt(@as(usize, @bitCast(ptr)));
                    if (test_hooks.isDump(&self.test_state, msg)) return test_hooks.dump(self);
                }
            }
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
    }
}

/// Called by a Window once it has been destroyed.
pub fn windowDestroyed(self: *App, window: *Window) void {
    for (self.windows.items, 0..) |w, i| {
        if (w == window) {
            _ = self.windows.orderedRemove(i);
            break;
        }
    }

    // There is no dock or tray to reopen a window from, so the app
    // exits with its last window.
    if (self.windows.items.len == 0) self.quitNow();
}

fn quitNow(self: *App) void {
    if (self.quitting) return;
    self.quitting = true;
    c.PostQuitMessage(0);
}

/// True if closing every window may go ahead: nothing needs confirming,
/// or the user said yes.
fn confirmCloseAll(self: *App, text: []const u8, caption: []const u8) bool {
    if (!self.core_app.needsConfirmQuit() or
        self.config.@"confirm-close-surface" == .false) return true;

    // Show it over the window the user is in, which then gets the focus
    // back if they answer no.
    const foreground = c.GetForegroundWindow();
    var owner: ?c.HWND = if (self.windows.items.len > 0) self.windows.items[0].hwnd else null;
    for (self.windows.items) |w| {
        if (foreground == w.hwnd) owner = w.hwnd;
    }
    return self.confirm(owner, text, caption);
}

fn quit(self: *App) void {
    if (!self.confirmCloseAll(
        "All terminal sessions will be terminated. Quit Ghostty?",
        "Ghostty: Quit",
    )) return;
    self.closeAllWindows();
    self.quitNow();
}

fn closeAllWindows(self: *App) void {
    while (self.windows.items.len > 0) {
        self.windows.items[self.windows.items.len - 1].destroy();
    }
}

/// Re-read the system light/dark preference and notify the core.
pub fn systemThemeChanged(self: *App) void {
    const dark = systemDark();
    if (dark == self.dark) return;
    self.dark = dark;
    for (self.windows.items) |w| w.applyTheme(dark);
    self.core_app.colorSchemeEvent(self, if (dark) .dark else .light) catch |err| {
        log.warn("error updating color scheme err={}", .{err});
    };
}

fn systemDark() bool {
    var value: c.DWORD = 1;
    var size: c.DWORD = @sizeOf(c.DWORD);
    const status = c.RegGetValueW(
        c.HKEY_CURRENT_USER,
        c.L("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
        c.L("AppsUseLightTheme"),
        c.RRF_RT_REG_DWORD,
        null,
        &value,
        &size,
    );
    return status == 0 and value == 0;
}

fn surfaceFromTarget(target: apprt.Target) ?*Surface {
    return switch (target) {
        .app => null,
        .surface => |core| core.rt_surface,
    };
}

fn windowFromTarget(target: apprt.Target) ?*Window {
    const surface = surfaceFromTarget(target) orelse return null;
    return surface.window;
}

fn reloadConfig(self: *App, target: apprt.Target, soft: bool) !void {
    if (soft) {
        try self.core_app.updateConfig(self, &self.config);
        return;
    }

    var config = try Config.load(self.core_app.alloc);
    defer config.deinit();
    switch (target) {
        .app => try self.core_app.updateConfig(self, &config),
        .surface => |core| try core.updateConfig(&config),
    }
}

fn openConfig(self: *App) bool {
    const alloc = self.core_app.alloc;
    const path = configpkg.edit.openPath(alloc) catch |err| {
        log.warn("error getting config file path: {t}", .{err});
        return false;
    };
    defer alloc.free(path);
    internal_os.open(.text, path) catch |err| {
        log.warn("unable to open config file: {}", .{err});
        return false;
    };
    return true;
}

fn gotoWindow(self: *App, target: apprt.Target, direction: apprt.action.GotoWindow) bool {
    const current = windowFromTarget(target) orelse return false;
    const n = self.windows.items.len;
    if (n < 2) return false;
    const i = std.mem.indexOfScalar(*Window, self.windows.items, current) orelse return false;
    const next = switch (direction) {
        .next => (i + 1) % n,
        .previous => (i + n - 1) % n,
    };
    self.windows.items[next].present();
    return true;
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    switch (action) {
        // Closing runs from the message loop: the core is still using
        // the surface that triggered these (see Request).
        .quit => self.request(.quit),

        .new_window => {
            const parent: ?*CoreSurface = switch (target) {
                .app => null,
                .surface => |v| v,
            };
            _ = try Window.create(self, parent);
        },

        .new_tab => switch (target) {
            .app => _ = try Window.create(self, null),
            .surface => |core| _ = try core.rt_surface.window.addTab(core, .tab),
        },

        .close_tab => switch (target) {
            .app => return false,
            .surface => |core| self.request(.{ .close_tabs = .{ .id = core.id, .mode = value } }),
        },

        .close_window => {
            const window = windowFromTarget(target) orelse return false;
            self.request(.{ .close_window = window.id });
        },

        .goto_tab => {
            const window = windowFromTarget(target) orelse return false;
            return window.gotoTab(value);
        },

        .move_tab => {
            const surface = surfaceFromTarget(target) orelse return false;
            return surface.window.moveTab(surface, value.amount);
        },

        .close_all_windows => self.request(.close_all_windows),

        .set_title => {
            const surface = surfaceFromTarget(target) orelse return false;
            surface.setTitle(value.title);
        },

        .mouse_shape => {
            const surface = surfaceFromTarget(target) orelse return false;
            surface.setMouseShape(value);
        },

        .mouse_visibility => {
            const surface = surfaceFromTarget(target) orelse return false;
            surface.setMouseVisibility(value == .visible);
        },

        .toggle_fullscreen => {
            const window = windowFromTarget(target) orelse return false;
            window.toggleFullscreen();
        },

        .toggle_maximize => {
            const window = windowFromTarget(target) orelse return false;
            window.toggleMaximize();
        },

        .initial_size => {
            // Only the window's first surface sizes the window; a new
            // tab must not resize an existing window.
            const window = windowFromTarget(target) orelse return false;
            if (window.surfaces.items.len > 0) return false;
            window.setClientSize(value.width, value.height);
        },

        .resize_window => {
            const window = windowFromTarget(target) orelse return false;
            window.setClientSize(value.width, value.height);
        },

        .size_limit => {
            const window = windowFromTarget(target) orelse return false;
            window.size_limit = value;
        },

        .present_terminal => {
            const surface = surfaceFromTarget(target) orelse return false;
            surface.window.presentSurface(surface);
        },

        .goto_window => return self.gotoWindow(target, value),

        .ring_bell => {
            const window = windowFromTarget(target) orelse return false;
            window.ringBell();
        },

        .open_url => internal_os.open(value.kind, value.url) catch |err| {
            log.warn("unable to open url err={}", .{err});
            return false;
        },

        .open_config => return self.openConfig(),

        .reload_config => try self.reloadConfig(target, value.soft),

        .config_change => switch (target) {
            .surface => {},
            .app => {
                const config = try value.config.clone(self.core_app.alloc);
                self.config.deinit();
                self.config = config;
                for (self.windows.items) |w| w.configChanged();
            },
        },

        .quit_timer => switch (value) {
            .start => if (self.windows.items.len == 0) self.quitNow(),
            .stop => {},
        },

        .renderer_health => log.info("renderer health={}", .{value}),

        // The renderer draws on its own thread; nothing to schedule.
        .render => {},

        else => {
            log.debug("unimplemented action={}", .{action});
            return false;
        },
    }

    return true;
}

/// IPC to a running instance is not supported yet.
pub fn performIpc(
    _: Allocator,
    _: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    _: apprt.ipc.Action.Value(action),
) (Allocator.Error || apprt.ipc.Errors)!bool {
    return false;
}

pub fn redrawInspector(_: *App, _: *Surface) void {}

pub fn keyboardLayout(_: *const App) input.KeyboardLayout {
    return .unknown;
}
