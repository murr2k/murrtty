//! The win32 application runtime. Owns the Win32 message loop and the
//! top-level windows.
const App = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const input = @import("../../input.zig");
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");

const c = @import("c.zig");
const Overlay = @import("Overlay.zig");
const SearchBox = @import("SearchBox.zig");
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const text_util = @import("text.zig");
const test_hooks = @import("test_hooks.zig");
const url = @import("url.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.win32);

const wakeup_class_name = c.L("MurrttyWakeup");

/// The taskbar groups windows, and pins shortcuts, by this. Never change
/// it: pinned taskbar icons would stop matching.
const app_user_model_id = c.L("murrtty.murrtty");
const WM_WAKEUP = c.WM_APP + 1;
const WM_RUN_REQUESTS = c.WM_APP + 2;
const WM_RAISE_MODAL = c.WM_APP + 3;

/// A request that closes tabs or windows, or opens a link. These never run
/// inside a callback from the core or while a modal dialog is open: the
/// core or the dialog's caller may still be using what a close would free,
/// and the core asks to open links with the renderer lock held, which a
/// dialog's nested loop would keep held. `request` queues them and the
/// message loop runs them. Targets are identified by id, so closing
/// something already gone does nothing.
pub const Request = union(enum) {
    /// The core asked to close a surface (e.g. its process exited).
    close_surface: struct { id: u64, process_active: bool },
    close_tabs: struct { id: u64, mode: apprt.action.CloseTabMode },
    /// Close a window, confirming if a process is running.
    close_window: u64,
    close_all_windows,
    quit,
    open_url: OpenUrl,
    /// Open the config file in an editor (see openConfig).
    open_config,
    /// Show the config's errors (see showConfigErrors).
    config_errors,

    fn deinit(self: Request, alloc: Allocator) void {
        switch (self) {
            .open_url => |v| alloc.free(v.url),
            else => {},
        }
    }
};

pub const OpenUrl = struct {
    /// The surface the link is in, whose window owns any dialog.
    surface: ?u64,
    kind: apprt.action.OpenUrl.Kind,
    /// Owned.
    url: []u8,
};

/// Button ids for the link dialogs.
const id_open_link = 100;
const id_copy_link = 101;

/// Button ids for the config errors dialog.
const id_open_config = 110;
const id_reload_config = 111;
const id_ignore_config = 112;

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

/// Where the mouse was last seen, in screen coordinates: over any of
/// Ghostty's windows, or where the cursor was when panes were last laid
/// out (see mouseMoved and Surface.followMouse).
mouse_screen: ?c.POINT = null,

/// Set once we've begun quitting so we don't quit twice.
quitting: bool = false,

/// Whether OleInitialize succeeded, so terminate balances it.
ole_initialized: bool = false,

/// The config errors last shown (a hash of their text), so that a soft
/// reload with the same errors doesn't show them again; whether the next
/// config change shows them regardless (after a reload the user asked
/// for); and whether a request to show them is already queued.
config_errors_shown: ?u64 = null,
config_errors_force: bool = false,
config_errors_queued: bool = false,

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

    // Before any window exists, so all of them take it.
    const aumid = c.SetCurrentProcessExplicitAppUserModelID(app_user_model_id);
    if (aumid < 0) log.warn("SetCurrentProcessExplicitAppUserModelID failed hr=0x{x}", .{@as(u32, @bitCast(aumid))});
    allowDarkMenus();

    // OLE, and with it single-threaded COM, for this UI thread. Shell, task
    // dialog and taskbar APIs need COM, and drag and drop needs OLE itself:
    // RegisterDragDrop fails if COM was started with CoInitializeEx instead.
    const ole = c.OleInitialize(null);
    if (ole < 0) log.warn("OleInitialize failed hr=0x{x}", .{@as(u32, @bitCast(ole))});
    errdefer if (ole >= 0) c.OleUninitialize();

    const instance = c.GetModuleHandleW(null) orelse return error.NoModuleHandle;
    try Window.registerClass(instance);
    try Tab.registerClass(instance);
    try Surface.registerClass(instance);
    try Overlay.registerClass(instance);
    try SearchBox.registerClass(instance);

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
    self.core_app.colorSchemeEvent(self, self.colorScheme()) catch |err| {
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
            "murrtty could not open a window ({t}).\n\n" ++
                "murrtty needs a graphics driver with OpenGL 4.3. Virtual machines " ++
                "and Remote Desktop sessions often don't provide it.\n\n" ++
                "To see the log, start murrtty from a shell with: murrtty.exe 2> murrtty.log",
            .{err},
        ) catch return err;
        defer self.core_app.alloc.free(msg);
        _ = Surface.messageBox(self.core_app.alloc, null, msg, "murrtty", c.MB_OK | c.MB_ICONERROR);
        return err;
    };

    // A GUI program's log goes nowhere, so show any config errors.
    self.queueConfigErrors();

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
    for (self.requests.items) |req| req.deinit(self.core_app.alloc);
    self.requests.deinit(self.core_app.alloc);
    _ = c.DestroyWindow(self.wakeup_hwnd);
    test_hooks.deinit(&self.test_state, self.core_app.alloc);
    self.config.deinit();
    if (self.ole_initialized) c.OleUninitialize();
}

/// Queue a request to run from the message loop. It takes ownership of
/// what the request owns.
pub fn request(self: *App, req: Request) void {
    self.requests.append(self.core_app.alloc, req) catch |err| {
        log.err("error queueing request {t} err={}", .{ req, err });
        req.deinit(self.core_app.alloc);
        return;
    };
    if (self.modal_depth == 0) _ = c.PostMessageW(self.wakeup_hwnd, WM_RUN_REQUESTS, 0, 0);
}

/// A WM_MOUSEMOVE at client (x, y) of `hwnd` (a pane, a tab's container or
/// a window's tab bar): records where the mouse is, in screen coordinates,
/// and returns whether it moved since it was last seen. A window laid out
/// again under a still cursor gets WM_MOUSEMOVE too, which this tells apart.
pub fn mouseMoved(self: *App, hwnd: c.HWND, x: i32, y: i32) bool {
    var pt = [1]c.POINT{.{ .x = x, .y = y }};
    _ = c.MapWindowPoints(hwnd, null, &pt, 1);
    const moved = if (self.mouse_screen) |last| last.x != pt[0].x or last.y != pt[0].y else true;
    self.mouse_screen = pt[0];
    return moved;
}

/// Before panes move: record where the cursor is now, so the WM_MOUSEMOVE
/// a pane that moves under it then gets is no move, wherever the mouse was
/// last seen (outside the window, say). GetCursorPos fails off the input
/// desktop (the GUI tests' hidden one); what was last seen stands then.
pub fn syncMouse(self: *App) void {
    var pt: c.POINT = .{};
    if (c.GetCursorPos(&pt) != 0) self.mouse_screen = pt;
}

fn runRequests(self: *App) void {
    // Requests made while a dialog was open run when it closes.
    while (self.modal_depth == 0 and self.requests.items.len > 0) {
        const req = self.requests.orderedRemove(0);
        switch (req) {
            .close_surface => |v| if (self.findSurface(v.id)) |s| s.window.closeSurface(s, v.process_active),
            .close_tabs => |v| if (self.findSurface(v.id)) |s| s.window.closeTabs(s, v.mode),
            .close_window => |id| if (self.findWindow(id)) |w| w.requestClose(),
            .close_all_windows => if (self.confirmCloseAll(
                "All terminal sessions will be terminated. Close all windows?",
                "murrtty:Close All Windows",
            )) self.closeAllWindows(),
            .quit => self.quit(),
            .open_config => {
                // The shell can show dialogs of its own.
                var modal = self.beginModal(null, .{});
                defer modal.end();
                _ = self.openConfig();
            },
            .config_errors => {
                self.config_errors_queued = false;
                self.showConfigErrors();
            },
            .open_url => |v| {
                defer req.deinit(self.core_app.alloc);
                self.openUrl(v);
            },
        }
    }
}

/// Open a link: links from Ghostty itself as they are, links from terminal
/// output as url.zig decides.
fn openUrl(self: *App, req: OpenUrl) void {
    const alloc = self.core_app.alloc;
    const owner: ?c.HWND = if (req.surface) |id|
        if (self.findSurface(id)) |s| s.window.hwnd else null
    else
        null;
    const decision: url.Decision = switch (req.kind) {
        .text, .html => .{ .open = .{ .value = alloc.dupe(u8, req.url) catch return } },
        .unknown, .osc8 => url.decide(alloc, req.url) catch |err| {
            log.warn("error vetting a link err={}", .{err});
            return;
        },
    };
    defer decision.deinit(alloc);
    switch (decision) {
        .open => |t| self.launch(owner, t),
        .confirm => |t| if (self.confirmLink(owner, t)) self.launch(owner, t),
        .deny => |d| self.linkBlocked(owner, d),
    }
}

fn launch(self: *App, owner: ?c.HWND, target: url.Target) void {
    if (test_hooks.recordLaunch(&self.test_state, self.core_app.alloc, @tagName(target.verb), target.value)) return;
    // The shell can show dialogs of its own.
    var modal = self.beginModal(owner, .{});
    defer modal.end();
    _ = url.launch(self.core_app.alloc, owner, target);
}

/// Ask before opening a link with a scheme nothing vetted, or a file of a
/// type not known to be inert. Cancel is the default.
fn confirmLink(self: *App, owner: ?c.HWND, target: url.Target) bool {
    const alloc = self.core_app.alloc;
    const handler = url.handlerName(alloc, target);
    defer if (handler) |h| alloc.free(h);
    // decide() already refused targets with characters that could disguise
    // them; escaping here keeps it that way for anything that skips it.
    const shown = url.display(alloc, target.value) catch return false;
    defer alloc.free(shown);
    const what = if (target.item) "file" else "link";
    const instruction = if (target.item)
        "Open this file from terminal output?"
    else
        "Open this link from terminal output?";
    const content = std.fmt.allocPrint(
        alloc,
        "This {s} will open in {s}. Only continue if you recognize and trust it.\n\n{s}",
        .{ what, handler orelse "the application registered for it", shown },
    ) catch return false;
    defer alloc.free(content);
    const chosen = self.taskDialog(.{
        .owner = owner,
        .title = "murrtty:Open Link",
        .instruction = instruction,
        .content = content,
        .icon = .warning,
        .buttons = &.{.{ .id = id_open_link, .text = if (target.item) "&Open File" else "&Open Link" }},
        .common_buttons = c.TDCBF_CANCEL_BUTTON,
        .default_button = c.IDCANCEL,
    }) orelse {
        const text = std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ instruction, content }) catch return false;
        defer alloc.free(text);
        return self.confirm(owner, text, "murrtty:Open Link");
    };
    return chosen == id_open_link;
}

/// Say why a link was not opened. Copying it is the way forward, rather
/// than a button that opens it anyway.
fn linkBlocked(self: *App, owner: ?c.HWND, denial: url.Denial) void {
    const alloc = self.core_app.alloc;
    // Very long targets are cut in the dialog, never in what is copied.
    const shown = text_util.truncate(denial.target, 1024);
    const cut = shown.len < denial.target.len or !denial.complete;
    const content = std.fmt.allocPrint(alloc, "{s}\n\n{s}{s}", .{
        denial.reason.message(),
        shown,
        if (cut) "... (truncated)" else "",
    }) catch return;
    defer alloc.free(content);
    const chosen = self.taskDialog(.{
        .owner = owner,
        .title = "murrtty:Link Blocked",
        .instruction = "murrtty blocked this link",
        .content = content,
        .icon = .warning,
        // Copying only part of a link would look like copying it.
        .buttons = if (denial.complete) &.{.{ .id = id_copy_link, .text = "&Copy Link" }} else &.{},
        .common_buttons = c.TDCBF_OK_BUTTON,
        .default_button = c.IDOK,
    }) orelse {
        var modal = self.beginModal(owner, .{});
        defer modal.end();
        _ = Surface.messageBox(alloc, owner, content, "murrtty:Link Blocked", c.MB_OK | c.MB_ICONWARNING);
        return;
    };
    if (chosen == id_copy_link) {
        Surface.writeClipboardText(alloc, owner orelse self.wakeup_hwnd, denial.target) catch |err| {
            log.warn("error copying a blocked link err={}", .{err});
        };
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
    /// Buttons that run an action and leave the dialog open.
    stay: ?Stay = null,

    pub const Button = struct { id: c_int, text: []const u8 };
    pub const Stay = struct {
        ids: []const c_int,
        /// Runs inside the dialog's modal loop.
        action: *const fn (*App, c_int) void,
    };
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

    var config: c.TASKDIALOGCONFIG = .{
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

    var stay: StayContext = undefined;
    if (td.stay) |s| {
        stay = .{ .app = self, .stay = s };
        config.pfCallback = @ptrCast(&taskDialogCallback);
        config.lpCallbackData = @bitCast(@intFromPtr(&stay));
    }

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

const StayContext = struct { app: *App, stay: TaskDialog.Stay };

fn taskDialogCallback(
    _: c.HWND,
    msg: c.UINT,
    wparam: c.WPARAM,
    _: c.LPARAM,
    data: isize,
) callconv(.winapi) c.HRESULT {
    if (msg != c.TDN_BUTTON_CLICKED) return c.S_OK;
    const ctx: *const StayContext = @ptrFromInt(@as(usize, @bitCast(data)));
    for (ctx.stay.ids) |id| {
        if (wparam != @as(c.WPARAM, @intCast(id))) continue;
        ctx.stay.action(ctx.app, id);
        // Not S_OK: the dialog stays open.
        return c.S_FALSE;
    }
    return c.S_OK;
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
        var it = w.panes();
        while (it.next()) |s| s.resumeClipboardConfirms();
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
        var it = w.panes();
        while (it.next()) |s| {
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
                    if (test_hooks.isDump(&self.test_state, msg)) return test_hooks.dump(self, wparam, lparam);
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
        "All terminal sessions will be terminated. Quit murrtty?",
        "murrtty:Quit",
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
    self.setSystemDark(systemDark());
}

/// The system preference changed to `dark` (or the GUI tests say so).
pub fn setSystemDark(self: *App, dark: bool) void {
    if (dark == self.dark) return;
    self.dark = dark;
    for (self.windows.items) |w| w.applyChrome();
    self.reportColorScheme();
}

/// The color scheme the core sees, for conditional themes and DEC mode
/// 2031: the system's, unless `window-theme` forces light or dark. Never
/// derived from the chrome's colors: a theme that depends on the scheme
/// would then change the colors that set the scheme, and the config would
/// reload in a loop.
fn colorScheme(self: *const App) apprt.ColorScheme {
    return switch (self.config.@"window-theme") {
        .light => .light,
        .dark => .dark,
        .auto, .system, .ghostty => if (self.dark) .dark else .light,
    };
}

/// Tell the core, and every surface, the current color scheme. Each does
/// nothing if it is the one it already has.
fn reportColorScheme(self: *App) void {
    const scheme = self.colorScheme();
    self.core_app.colorSchemeEvent(self, scheme) catch |err| {
        log.warn("error updating color scheme err={}", .{err});
    };
    for (self.windows.items) |w| {
        var it = w.panes();
        while (it.next()) |s| s.colorSchemeCallback(scheme);
    }
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
        .app => {
            // The user asked for this reload, so show its errors even if
            // they are the ones shown before.
            self.config_errors_force = true;
            try self.core_app.updateConfig(self, &config);
        },
        .surface => |core| try core.updateConfig(&config),
    }
}

/// Queue the config errors dialog if the config has errors that weren't
/// just shown (see config_errors_shown).
fn queueConfigErrors(self: *App) void {
    const force = self.config_errors_force;
    self.config_errors_force = false;
    const diags = self.config._diagnostics.items();
    if (diags.len == 0) {
        // Fixed: if the same errors come back, show them again.
        self.config_errors_shown = null;
        return;
    }
    if (!force and self.config_errors_shown == diagnosticsHash(diags)) return;
    if (self.config_errors_queued) return;
    self.config_errors_queued = true;
    self.request(.config_errors);
}

fn diagnosticsHash(diags: anytype) u64 {
    var hasher: std.hash.Wyhash = .init(0);
    for (diags) |diag| {
        var buf: [1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        diag.format(&writer) catch {};
        hasher.update(writer.buffered());
        hasher.update("\n");
    }
    return hasher.final();
}

/// Show the config's errors, with Open Configuration (which leaves the
/// dialog up, so the file can be fixed and then reloaded), Reload and
/// Ignore. Config errors otherwise only reach the log, which a GUI
/// program's user never sees.
fn showConfigErrors(self: *App) void {
    const alloc = self.core_app.alloc;
    const diags = self.config._diagnostics.items();
    if (diags.len == 0) return;
    self.config_errors_shown = diagnosticsHash(diags);

    // The first few in the content, all of them under "See details".
    const shown_max = 10;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(alloc);
    for (diags, 0..) |diag, i| {
        var buf: [1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        diag.format(&writer) catch {};
        const line = writer.buffered();
        all.print(alloc, "{s}\n", .{line}) catch return;
        if (i < shown_max) content.print(alloc, "{s}\n", .{line}) catch return;
    }
    if (diags.len > shown_max) content.print(alloc, "...and {d} more.", .{diags.len - shown_max}) catch return;

    const owner: ?c.HWND = if (self.windows.items.len > 0) self.windows.items[0].hwnd else null;
    const chosen = self.taskDialog(.{
        .owner = owner,
        .title = "murrtty:Configuration Errors",
        .instruction = if (diags.len == 1)
            "The configuration has an error"
        else
            "The configuration has errors",
        .content = content.items,
        .expanded = if (diags.len > shown_max) all.items else "",
        .icon = .warning,
        .buttons = &.{
            .{ .id = id_open_config, .text = "&Open Configuration" },
            .{ .id = id_reload_config, .text = "&Reload" },
            .{ .id = id_ignore_config, .text = "&Ignore" },
        },
        .default_button = id_ignore_config,
        .stay = .{ .ids = &.{id_open_config}, .action = openConfigFromDialog },
    }) orelse {
        const text = std.fmt.allocPrint(alloc, "{s}\nFix the configuration file, then reload it with Ctrl+Shift+Comma.", .{all.items}) catch return;
        defer alloc.free(text);
        var modal = self.beginModal(owner, .{});
        defer modal.end();
        _ = Surface.messageBox(alloc, owner, text, "murrtty:Configuration Errors", c.MB_OK | c.MB_ICONWARNING);
        return;
    };
    if (chosen == id_reload_config) self.reloadConfig(.app, false) catch |err| {
        log.warn("error reloading the config err={}", .{err});
    };
}

fn openConfigFromDialog(self: *App, _: c_int) void {
    _ = self.openConfig();
}

/// Open the config file in an editor: the program registered to edit its
/// type, else the one registered to open it, else Notepad. The generic
/// opener showed Windows' "How do you want to open this file?" chooser on
/// a machine where nothing is registered for `.ghostty` files. Run it from
/// the message loop in a modal scope: the shell can pump messages.
fn openConfig(self: *App) bool {
    const alloc = self.core_app.alloc;
    const path = configpkg.edit.openPath(alloc) catch |err| {
        log.warn("error getting config file path: {t}", .{err});
        return false;
    };
    defer alloc.free(path);
    if (test_hooks.recordLaunch(&self.test_state, alloc, "edit-config", path)) return true;

    const path16 = text_util.utf16Lossy(alloc, path) catch return false;
    defer alloc.free(path16);
    for ([_]c.LPCWSTR{ c.L("edit"), c.L("open") }) |verb| {
        var info: c.SHELLEXECUTEINFOW = .{
            // No UI: if nothing is registered, fall through quietly.
            .fMask = c.SEE_MASK_NOASYNC | c.SEE_MASK_FLAG_NO_UI,
            .lpVerb = verb,
            .lpFile = path16,
            .nShow = c.SW_SHOWNORMAL,
        };
        if (c.ShellExecuteExW(&info) != 0) return true;
    }

    const params = std.fmt.allocPrint(alloc, "\"{s}\"", .{path}) catch return false;
    defer alloc.free(params);
    const params16 = text_util.utf16Lossy(alloc, params) catch return false;
    defer alloc.free(params16);
    var info: c.SHELLEXECUTEINFOW = .{
        .fMask = c.SEE_MASK_NOASYNC,
        .lpFile = c.L("notepad.exe"),
        .lpParameters = params16,
        .nShow = c.SW_SHOWNORMAL,
    };
    if (c.ShellExecuteExW(&info) != 0) return true;
    log.warn("unable to open the config file err={d}", .{c.GetLastError()});
    return false;
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

        // Created at once, so that a chained action (new_tab then
        // goto_tab) finds it. The core's `all:` loop copes with surfaces
        // added while it runs.
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
            // tab must not resize an existing window. (A tab joins the
            // list once its first pane is initialized.)
            const window = windowFromTarget(target) orelse return false;
            if (window.tabs.items.len > 0) return false;
            window.setClientSize(value.width, value.height);
        },

        .resize_window => {
            const window = windowFromTarget(target) orelse return false;
            return window.resizeFromTerminal(value.width, value.height);
        },

        // Sent once, by a surface being created (panes work out their
        // minimums themselves, see Surface.layoutMin).
        .size_limit => {
            const surface = surfaceFromTarget(target) orelse return false;
            surface.window.size_limit = value;
        },

        // The font size or the DPI changed the pane's cells, and with them
        // its minimum: lay its tab out again.
        .cell_size => {
            const surface = surfaceFromTarget(target) orelse return false;
            const window = surface.window;
            if (window.tabIndexOf(surface)) |i| window.tabs.items[i].layoutPanes();
        },

        .new_split => {
            const surface = surfaceFromTarget(target) orelse return false;
            try surface.window.newSplit(surface, value);
        },

        // Each returns false when it does nothing (one pane, nowhere to
        // go), so a performable key reaches the program.
        .goto_split => {
            const surface = surfaceFromTarget(target) orelse return false;
            return surface.window.gotoSplit(surface, value);
        },

        .toggle_split_zoom => {
            const surface = surfaceFromTarget(target) orelse return false;
            return surface.window.toggleSplitZoom(surface);
        },

        .equalize_splits => {
            const surface = surfaceFromTarget(target) orelse return false;
            return surface.window.equalizeSplits(surface);
        },

        .resize_split => {
            const surface = surfaceFromTarget(target) orelse return false;
            return surface.window.resizeSplit(surface, value);
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

        // Every link is taken, even one that will be blocked: if this
        // returned false the core would open it with the generic opener,
        // which opens anything.
        .open_url => self.request(.{ .open_url = .{
            .surface = switch (target) {
                .app => null,
                .surface => |core| core.id,
            },
            .kind = value.kind,
            .url = try self.core_app.alloc.dupe(u8, value.url),
        } }),

        // From the message loop: the shell can pump messages, and the
        // core is using the surface that triggered this.
        .open_config => self.request(.open_config),

        .reload_config => try self.reloadConfig(target, value.soft),

        .config_change => switch (target) {
            // A surface's own config (after a reload, or its conditional
            // state changing) resets the colors its tab and caption show.
            .surface => |core| {
                const surface = core.rt_surface;
                surface.colors = .fromConfig(value.config);
                surface.window.colorsChanged(surface);
            },
            .app => {
                const config = try value.config.clone(self.core_app.alloc);
                self.config.deinit();
                self.config = config;
                for (self.windows.items) |w| w.configChanged();
                // window-theme may now force a different scheme.
                self.reportColorScheme();
                self.queueConfigErrors();
            },
        },

        // A program changed the terminal's background or foreground
        // (OSC 10/11), which the caption and tab strip follow.
        .color_change => {
            const surface = surfaceFromTarget(target) orelse return false;
            switch (value.kind) {
                .background => surface.colors.bg = .{ .r = value.r, .g = value.g, .b = value.b },
                .foreground => surface.colors.fg = .{ .r = value.r, .g = value.g, .b = value.b },
                else => return false,
            }
            surface.window.colorsChanged(surface);
        },

        .quit_timer => switch (value) {
            .start => if (self.windows.items.len == 0) self.quitNow(),
            .stop => {},
        },

        .renderer_health => log.info("renderer health={}", .{value}),

        // Not shown yet (notify-on-command-finish); kept for the GUI
        // tests' dump.
        .command_finished => {
            const surface = surfaceFromTarget(target) orelse return false;
            surface.commands_finished +%= 1;
            surface.last_exit = value.exit_code;
            return false;
        },

        // The renderer draws on its own thread; nothing to schedule.
        .render => {},

        // The search box (roadmap 3.2); the core runs the search.
        .start_search => {
            const surface = surfaceFromTarget(target) orelse return false;
            surface.search.open(surface, value.needle);
        },
        .end_search => {
            const surface = surfaceFromTarget(target) orelse return false;
            surface.search.close();
        },
        .search_total => {
            const surface = surfaceFromTarget(target) orelse return false;
            surface.search.setTotal(value.total);
        },
        .search_selected => {
            const surface = surfaceFromTarget(target) orelse return false;
            surface.search.setSelected(value.selected);
        },

        else => {
            log.debug("unimplemented action={}", .{action});
            return false;
        },
    }

    return true;
}

/// Dark popup menus (the context menu) while Windows uses dark mode for
/// apps. Windows has no public API for it; this uses uxtheme's exports by
/// ordinal, as Windows Terminal and File Explorer do: 135 is
/// SetPreferredAppMode (1, AllowDark) since Windows 10 1903 and
/// AllowDarkModeForApp (1, true) before, 136 FlushMenuThemes. Missing, it
/// does nothing.
fn allowDarkMenus() void {
    const uxtheme = c.LoadLibraryW(c.L("uxtheme.dll")) orelse return;
    if (c.GetProcAddress(uxtheme, @ptrFromInt(135))) |p| {
        const setMode: *const fn (c_int) callconv(.winapi) c_int = @ptrCast(p);
        _ = setMode(1);
    }
    if (c.GetProcAddress(uxtheme, @ptrFromInt(136))) |p| {
        const flush: *const fn () callconv(.winapi) void = @ptrCast(p);
        flush();
    }
}

/// Whether a key-binding action does anything here: the core performs it
/// itself, or it becomes a runtime action this runtime implements (see
/// performAction). Menus gray out, and the command palette hides, the
/// actions it doesn't (roadmap 3.0). Kept in step with performAction.
pub fn supportsAction(action: input.Binding.Action) bool {
    return switch (action) {
        // Runtime actions not implemented yet.
        .copy_title_to_clipboard,
        .move_tab_to_new_window,
        .toggle_tab_overview,
        .prompt_surface_title,
        .prompt_tab_title,
        .prompt_window_title,
        .set_tab_title,
        .set_window_title,
        .reset_window_size,
        .inspector,
        .show_gtk_inspector,
        .show_on_screen_keyboard,
        .toggle_window_decorations,
        .toggle_window_float_on_top,
        .toggle_secure_input,
        .toggle_command_palette,
        .toggle_quick_terminal,
        .toggle_visibility,
        .toggle_background_opacity,
        .check_for_updates,
        .undo,
        .redo,
        => false,
        else => true,
    };
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
