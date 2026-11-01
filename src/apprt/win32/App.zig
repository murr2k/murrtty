//! The win32 application runtime. Owns the Win32 message loop and the
//! top-level windows.
const App = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const build_config = @import("../../build_config.zig");
const global = @import("../../global.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const input = @import("../../input.zig");
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");

const c = @import("c.zig");
const Banner = @import("Banner.zig");
const AlertDialog = @import("AlertDialog.zig");
const CommandPalette = @import("CommandPalette.zig");
const ContextMenu = @import("ContextMenu.zig");
const draw = @import("draw.zig");
const GlobalKeys = @import("GlobalKeys.zig");
const ipc = @import("ipc.zig");
const Notifications = @import("Notifications.zig");
const Overlay = @import("Overlay.zig");
const PaneDrag = @import("PaneDrag.zig");
const Session = @import("Session.zig");
const Undo = @import("Undo.zig");
const Waiting = @import("Waiting.zig");
const Inspector = @import("Inspector.zig");
const ConfigEditor = @import("ConfigEditor.zig");
const wgl = @import("opengl").wgl;
const gl_diagnosis = @import("gl_diagnosis.zig");
const software_gl = @import("software_gl.zig");
const taskbar = @import("taskbar.zig");
const SearchBox = @import("SearchBox.zig");
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const text_util = @import("text.zig");
const test_hooks = @import("test_hooks.zig");
const url = @import("url.zig");
const TitleDialog = @import("TitleDialog.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.win32);

const wakeup_class_name = c.L("MurrttyWakeup");

/// The taskbar groups windows, and pins shortcuts, by this, and toasts go
/// under it (roadmap 5.2b). Never change it: pinned taskbar icons would
/// stop matching.
pub const app_user_model_id_utf8 = "murrtty.murrtty";
pub const app_user_model_id = c.L(app_user_model_id_utf8);
const WM_WAKEUP = c.WM_APP + 1;
const WM_RUN_REQUESTS = c.WM_APP + 2;
const WM_RAISE_MODAL = c.WM_APP + 3;
/// An IPC request (ipc.zig) from the pipe's thread: lparam is an
/// *ipc.Received, ours to free.
const WM_IPC = c.WM_APP + 4;

/// The wakeup window's timer for a murrtty started for an IPC request
/// (`ipc_launch`).
const ipc_launch_timer = 1;
/// GTK's quit timer (quit-after-last-window-closed-delay).
const quit_timer_id = 2;

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
    /// Ask for a pane's, its tab's or its window's title (TitleDialog).
    prompt_title: struct { id: u64, which: apprt.action.PromptTitle },
    /// +new-window, +new-tab or a launch handing off (runIpc).
    ipc: *ipc.Received,
    /// A notification's pane, by core id, once its toast was clicked.
    present_surface: u64,
    /// Undo or redo a close (roadmap 5.11).
    undo,
    redo,
    /// Save the inspector's Terminal IO events (roadmap 5.12), owned.
    export_io: struct { surface: u64, contents: []u8 },

    fn deinit(self: Request, alloc: Allocator) void {
        switch (self) {
            .open_url => |v| alloc.free(v.url),
            .export_io => |v| alloc.free(v.contents),
            .ipc => |v| v.destroy(alloc),
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

/// A close confirmation's Close button: IDYES, the answer of the message
/// box it replaced (no Yes button shares the dialog).
const id_close = c.IDYES;

/// What a close confirmation is for: GTK's targets (app, window, tab,
/// split), and murrtty's for closing all windows and several tabs at once.
pub const CloseTarget = enum {
    app,
    all_windows,
    window,
    tab,
    tabs,
    split,

    /// GTK's heading.
    pub fn heading(self: CloseTarget) []const u8 {
        return switch (self) {
            .app => "Quit murrtty?",
            .all_windows => "Close All Windows?",
            .window => "Close Window?",
            .tab => "Close Tab?",
            .tabs => "Close Tabs?",
            .split => "Close Split?",
        };
    }

    /// GTK's body.
    pub fn body(self: CloseTarget) []const u8 {
        return switch (self) {
            .app, .all_windows => "All terminal sessions will be terminated.",
            .window => "All terminal sessions in this window will be terminated.",
            .tab => "All terminal sessions in this tab will be terminated.",
            .tabs => "All terminal sessions in these tabs will be terminated.",
            .split => "The currently running process in this split will be terminated.",
        };
    }
};

const HWND_MESSAGE = c.HWND_MESSAGE;

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

/// Whether Windows always shows scroll bars (Accessibility > Visual
/// effects): then the scrollbar doesn't fade.
scrollbars_always: bool = false,

/// toggle_background_opacity made the windows opaque despite a
/// background-opacity below 1 (`translucent`).
force_opaque: bool = false,

/// Whether BufferedPaintInit succeeded (draw.AlphaPaint), so terminate
/// balances it.
buffered_paint: bool = false,

/// Windows' build number, which picks how a window blurs (`blurMethod`).
windows_build: u32 = 0,

/// Where the mouse was last seen, in screen coordinates: over any of
/// Ghostty's windows, or where the cursor was when panes were last laid
/// out (see mouseMoved and Surface.followMouse).
mouse_screen: ?c.POINT = null,

/// Set once we've begun quitting so we don't quit twice.
quitting: bool = false,

/// Whether OleInitialize succeeded, so terminate balances it.
ole_initialized: bool = false,

/// The chrome's bundled font, registered for this process (draw.zig).
fonts: ?c.HANDLE = null,

/// The config errors last shown (a hash of their text), so that a soft
/// reload with the same errors doesn't show them again; whether the next
/// config change shows them regardless (after a reload the user asked
/// for); and whether a request to show them is already queued.
config_errors_shown: ?u64 = null,
config_errors_force: bool = false,
config_errors_queued: bool = false,

/// The single instance's pipe (ipc.zig), served from another thread.
ipc_server: ?*ipc.Server = null,

/// The overrides of an IPC request (or open_config:new_window) for the
/// pane being created, which Surface.init takes.
ipc_overrides: ?*const ipc.Overrides = null,

/// A client started this murrtty for its request (ipc.launch_env): the
/// request opens the first window, and without one it quits.
ipc_launch: bool = false,

/// Desktop notifications (roadmap 5.2), set up in init.
notifications: Notifications = undefined,

/// `global:` bindings as hot keys (roadmap 5.5), set up in init.
global_keys: GlobalKeys = undefined,
/// Undo and redo of closes (roadmap 5.11), set up in init.
undo: Undo = undefined,
/// Session restore (roadmap 5.10b), set up in init.
session: Session = undefined,
/// The panes waiting for their user: the header bars' bells.
waiting: Waiting = .{},
/// The id of the pane a restore is making (its history's), which
/// Surface.init takes; else the pane gets a new one.
restore_id: ?Session.Id = null,
/// WGL's extensions, for the inspector's windows (roadmap 5.12), loaded at
/// the first.
wgl_ext: ?wgl.Extensions = null,
/// toggle_visibility hid the windows: the ids of those it hid, and of the
/// one in front then, to show them as they were.
windows_hidden: bool = false,
hidden_windows: std.ArrayList(u64) = .empty,
hidden_front: ?u64 = null,
/// The window last activated (WM_NCACTIVATE), which toggle_visibility
/// brings forward.
last_window: ?u64 = null,

/// GTK's quit timer (roadmap 5.6): started when the core says the last
/// surface went, with quit-after-last-window-closed; it runs for
/// quit-after-last-window-closed-delay, or has expired at once without one.
quit_timer: enum { off, active, expired } = .off,
/// A window was opened (GTK's requested_window): with no delay, closing the
/// last window quits only once one was, so initial-window = false waits.
requested_window: bool = false,
/// closeAllWindows is closing them: no hidden quick terminal comes back.
closing_all: bool = false,
/// A pane being dragged (roadmap 1.10).
pane_drag: ?PaneDrag = null,
/// murrtty's selection clipboard (roadmap 5.9): Windows has no primary
/// selection, so copy-on-select, middle-click paste and
/// paste_from_selection share this, between murrtty's panes only.
selection: ?[]u8 = null,
/// This murrtty was started again on its software OpenGL (Mesa) by one
/// whose graphics have no OpenGL 4.3 (software_gl.zig).
software_start: ?software_gl.Started = null,
/// run() has opened the first window or the tray. Before, nothing quits:
/// the color scheme's soft reload at start (a dark system) reaches the
/// config change, with no window yet.
started: bool = false,

/// The taskbar's message that a window's button exists, and its list for
/// progress on the buttons (roadmap 5.4), made at such a message.
taskbar_button_msg: c.UINT = 0,
taskbar_list: ?*taskbar.List = null,

/// The configuration editor (roadmap F1), while it is open; it keeps
/// murrtty running (checkQuit).
config_editor: ?*ConfigEditor = null,
/// The config editor's preview is being applied (roadmap F1d): the config
/// change only takes the configuration and redraws the windows, with no
/// "Reloaded" toast, errors, tray, hot keys or session work, as it comes
/// at up to 30 a second while a slider moves. Its revert (the files read
/// again, which may have changed since) runs the whole change, only
/// without the toast.
config_preview: enum { off, preview, revert } = .off,

/// STARTUPINFO's flags as this process was started, before its
/// AppUserModelID changed them (software_gl's second start must not get
/// STARTF_TITLEISAPPID from the first).
startup_flags: u32 = 0,

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

    // How this process was started, before setting the ID changes what
    // GetStartupInfo says (software_gl passes it on; the GUI tests' check).
    var startup: c.STARTUPINFOW = .{};
    c.GetStartupInfoW(&startup);

    // Before any window exists, so all of them take it.
    const aumid = c.SetCurrentProcessExplicitAppUserModelID(app_user_model_id);
    if (aumid < 0) log.warn("SetCurrentProcessExplicitAppUserModelID failed hr=0x{x}", .{@as(u32, @bitCast(aumid))});
    // The common controls' classes (the tab strip's tooltip).
    _ = c.InitCommonControlsEx(&.{ .dwICC = c.ICC_WIN95_CLASSES });

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
    try CommandPalette.registerClass(instance);
    try Banner.registerClass(instance);
    try Notifications.registerClass(instance);
    try Inspector.registerClass(instance);
    try ConfigEditor.registerClass(instance);

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
        .scrollbars_always = scrollbarsAlwaysShown(),
        .ole_initialized = ole >= 0,
        // Keeps the buffers a translucent window paints through.
        .buffered_paint = c.BufferedPaintInit() >= 0,
        .windows_build = windowsBuild(),
        .fonts = draw.registerFonts(),
        .ipc_launch = takeLaunchEnv(),
        // Before anything loads OpenGL (the first window).
        .software_start = software_gl.take(),
        .startup_flags = startup.dwFlags,
        .test_state = test_hooks.init(alloc),
    };
    if (self.fonts == null) log.warn("the chrome's font (Adwaita Sans) could not be registered", .{});
    // Before any menu shows.
    self.syncMenuTheme();
    self.notifications.init(self);
    self.global_keys = .{ .app = self };
    self.undo = .{ .app = self };
    self.session = .init(self);
    self.taskbar_button_msg = c.RegisterWindowMessageW(c.L("TaskbarButtonCreated"));
    _ = c.SetWindowLongPtrW(wakeup_hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
}

pub fn run(self: *App) !void {
    // Apply the color scheme before the first surface so it starts
    // with the right conditional config.
    self.core_app.colorSchemeEvent(self, self.colorScheme()) catch |err| {
        log.warn("error setting initial color scheme err={}", .{err});
    };

    // The pipe first: it is claimed at once if free, so of two launches
    // together one holds it. Then gtk-single-instance (roadmap 5.1): the
    // window goes to the murrtty holding it, as GTK's application hands
    // it over. Without an initial window there is nothing to hand over,
    // and GTK's second instance just ends: the first already runs.
    self.startIpc();
    const holding = if (self.ipc_server) |s| s.listening.load(.acquire) else false;
    if (!self.ipc_launch and !holding and self.config.@"gtk-single-instance" == .true) handoff: {
        var arena: std.heap.ArenaAllocator = .init(self.core_app.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        const msg: ipc.Message = switch (handOffRequest(a)) {
            .separate => {
                log.info("this launch's options are its own: it runs as a murrtty of its own", .{});
                break :handoff;
            },
            .present => .{ .kind = .present },
            .new_window => .{ .kind = .new_window },
            .new_tab => |args| .{ .kind = .new_tab, .arguments = args },
        };
        if (!self.config.@"initial-window" and msg.kind != .new_tab) {
            // Only if one really does (not a pipe squatted, or one going).
            if (ipc.serverRunning(self.core_app.alloc, self.ipcClass())) {
                log.info("murrtty already runs, and there is no initial window to hand it", .{});
                return;
            }
        } else if (ipc.handOff(a, self.ipcClass(), msg)) {
            log.info("handed the launch to the running murrtty", .{});
            return;
        }
    }
    self.global_keys.start();
    // The tray (roadmap 5.6) before any window: murrtty may run without.
    self.syncTray();
    // The saved session (roadmap 5.10b), read before any window: kept by
    // the murrtty holding the pipe (another instance would restore it again
    // and write over it), or by one with no pipe at all.
    self.session.start(holding or self.ipc_server == null);

    if (self.ipc_launch) {
        // The request brings the window, and the session with it (runIpc);
        // without it, don't linger.
        _ = c.SetTimer(self.wakeup_hwnd, ipc_launch_timer, ipc.launch_timeout_ms, null);
    } else if (!self.config.@"initial-window") {
        // In the tray, until a window is asked for. With a delay it quits
        // when that passes with none (the option's documentation).
        if (self.config.@"quit-after-last-window-closed-delay" != null) self.startQuitTimer();
    } else if (self.session.restoreAtStart() > 0) {
        // A launch with a command opens it in a tab of its own.
        self.openLaunchTab();
    } else {
        // A launch's command (-e) runs in the first pane as an IPC
        // request's would: shell integration only for a shell it detects,
        // for that pane alone (this murrtty carries on as the instance).
        const launch_cmd: ipc.Overrides = .{ .command = self.config.@"initial-command" };
        if (launch_cmd.command != null) self.ipc_overrides = &launch_cmd;
        defer self.ipc_overrides = null;
        _ = Window.create(self, null) catch |err| {
            // A GUI program has no console, so say why it can't start: for
            // OpenGL, what is missing and what to do (roadmap 6.3).
            if (gl_diagnosis.isGlError(err)) {
                // No hand-offs to an instance that can't open a window: a
                // murrtty started meanwhile opens its own.
                if (self.ipc_server) |s| s.stop();
                self.ipc_server = null;
                // Started on Mesa, which can't draw either: the murrtty
                // that started this one says why, or this one if that one
                // no longer waits (roadmap 6.3b).
                if (self.software_start) |*started| {
                    log.err("murrtty's software OpenGL can't draw either err={}", .{err});
                    if (!software_gl.failed(started)) software_gl.tellFailed(self, started.kind, err);
                    return err;
                }
                // murrtty again on its software OpenGL, if it has one.
                switch (software_gl.relaunch(self, err)) {
                    .took_over => return,
                    .failed => gl_diagnosis.show(self, err, .failed),
                    .unavailable, .not_started => gl_diagnosis.show(self, err, .none),
                    .ended => {},
                }
                return err;
            }
            const msg = std.fmt.allocPrint(
                self.core_app.alloc,
                "murrtty could not open a window ({t}).\n\n" ++
                    "To see the log, start murrtty from a shell with: murrtty.exe 2> murrtty.log",
                .{err},
            ) catch return err;
            defer self.core_app.alloc.free(msg);
            _ = Surface.messageBox(self.core_app.alloc, null, msg, "murrtty", c.MB_OK | c.MB_ICONERROR);
            return err;
        };
    }

    // A GUI program's log goes nowhere, so show any config errors.
    self.queueConfigErrors();
    self.started = true;
    self.registerRestart();
    // On murrtty's software OpenGL: once a pane has drawn, the murrtty that
    // started this one can end and the window says why it draws in
    // software (6.3b); the shaders are only built for the first frame.
    if (self.software_start != null) software_gl.startWatch(self);

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
    // No first-frame watch (6.3b) through the teardown's messages.
    software_gl.stopWatch(self);
    // The session stays as last written while the windows go.
    self.session.freeze();
    // With the requests it queued that the loop never took.
    if (self.ipc_server) |s| s.stop();
    self.ipc_server = null;
    if (self.config_editor) |editor| editor.destroy();
    while (self.windows.items.len > 0) {
        _ = c.DestroyWindow(self.windows.items[self.windows.items.len - 1].hwnd);
    }
    self.windows.deinit(self.core_app.alloc);
    // Empty, not freed, for what the shelf's panes do as they go (a bell
    // leaving the waiting list walks the windows).
    self.windows = .empty;
    // What undo kept, and the shelf.
    self.undo.deinit();
    self.session.deinit();
    self.waiting.deinit(self.core_app.alloc);
    // After the windows, whose teardown can still ask for a refresh.
    self.global_keys.deinit();
    self.hidden_windows.deinit(self.core_app.alloc);
    if (self.selection) |s| self.core_app.alloc.free(s);
    self.selection = null;
    // Its icon goes with murrtty.
    self.notifications.deinit();
    if (self.taskbar_list) |list| list.release();
    self.taskbar_list = null;
    for (self.requests.items) |req| req.deinit(self.core_app.alloc);
    self.requests.deinit(self.core_app.alloc);
    _ = c.DestroyWindow(self.wakeup_hwnd);
    test_hooks.deinit(&self.test_state, self.core_app.alloc);
    self.config.deinit();
    if (self.buffered_paint) _ = c.BufferedPaintUnInit();
    if (self.ole_initialized) c.OleUninitialize();
    if (self.fonts) |h| _ = c.RemoveFontMemResourceEx(h);
}

/// Whether the windows let the desktop show through the terminal's
/// background (roadmap 4.1): background-opacity below 1, unless
/// toggle_background_opacity made them opaque. GTK keeps it fullscreen
/// too.
pub fn translucent(self: *const App) bool {
    return self.config.@"background-opacity" < 1 and !self.force_opaque;
}

/// background-opacity as an alpha byte, as the renderer rounds it.
pub fn backgroundAlpha(self: *const App) u8 {
    const opacity = std.math.clamp(self.config.@"background-opacity", 0, 1);
    return @intFromFloat(@round(opacity * 255.0));
}

/// How a translucent window blurs what shows through it (roadmap 4.2):
/// Acrylic, DWM's system backdrop for transient windows, from Windows 11
/// 22H2 (build 22621); before it the accent policy's blur, from Windows 10
/// 1809 (build 17763), as Tauri's window-vibrancy does; else none.
pub fn blurMethod(self: *const App) Window.Blur {
    if (comptime test_hooks.enabled) switch (self.test_state.force_blur) {
        .none => {},
        .accent => return if (accentFn() != null) .accent else .none,
        .acrylic => return .backdrop,
    };
    if (self.windows_build >= 22621) return .backdrop;
    if (self.windows_build >= 17763 and accentFn() != null) return .accent;
    return .none;
}

/// user32's undocumented SetWindowCompositionAttribute, or null.
pub fn accentFn() ?c.SetWindowCompositionAttributeFn {
    const S = struct {
        var resolved = false;
        var func: ?c.SetWindowCompositionAttributeFn = null;
    };
    if (!S.resolved) {
        S.resolved = true;
        if (c.GetModuleHandleW(c.L("user32.dll"))) |lib| {
            if (c.GetProcAddress(lib, "SetWindowCompositionAttribute")) |p| S.func = @ptrCast(@alignCast(p));
        }
        if (S.func == null) log.warn("SetWindowCompositionAttribute unavailable, no blur before Windows 11 22H2", .{});
    }
    return S.func;
}

fn windowsBuild() u32 {
    var info: c.OSVERSIONINFOW = .{};
    if (c.RtlGetVersion(&info) != 0) return 0;
    return info.dwBuildNumber;
}

/// The taskbar's list for progress on window buttons (roadmap 5.4), made
/// when a button exists (`taskbarButtonCreated`); null until then, or
/// where COM or Explorer gives none.
pub fn taskbarList(self: *App) ?*taskbar.List {
    return self.taskbar_list;
}

/// A window's taskbar button exists: make the list if there isn't one yet
/// (Explorer may still have been starting at the last try).
pub fn taskbarButtonCreated(self: *App) void {
    if (self.taskbar_list == null) self.taskbar_list = taskbar.List.create();
}

/// Whether a client started this murrtty for its request (ipc.launch_env),
/// clearing the variable so that nothing this murrtty starts sees it.
fn takeLaunchEnv() bool {
    const name = c.L(ipc.launch_env);
    if (c.GetEnvironmentVariableW(name, null, 0) == 0) return false;
    _ = c.SetEnvironmentVariableW(name, null);
    return true;
}

/// The class whose single instance this murrtty is (ipc.zig): `class` from
/// the config, else murrtty's own. With the GUI tests' hooks on, each
/// murrtty has its own, so that test instances never reach one another or
/// a developer's; the tests name theirs.
fn ipcClass(self: *App) ?[]const u8 {
    if (self.config.class) |class| return class;
    if (comptime test_hooks.enabled) if (test_hooks.active()) {
        const S = struct {
            var buf: [32]u8 = undefined;
        };
        return std.fmt.bufPrint(&S.buf, "murrtty-test-{d}", .{c.GetCurrentProcessId()}) catch null;
    };
    return null;
}

/// Serve the single instance's pipe. A release of murrtty's own class also
/// keeps the taskbar's Jump List (New Window) once it holds the pipe.
fn startIpc(self: *App) void {
    const class = self.ipcClass();
    const jump_list: ?c.LPCWSTR = if (builtin.mode != .debug and class == null) app_user_model_id else null;
    self.ipc_server = ipc.Server.start(self.core_app.alloc, class, self.wakeup_hwnd, WM_IPC, jump_list) catch |err| {
        log.warn("no single instance: the pipe could not be set up err={}", .{err});
        return;
    };
}

/// What a launch asks of the murrtty already running (gtk-single-instance,
/// roadmap 5.10b), by its arguments.
const HandOff = union(enum) {
    /// Options only a murrtty of its own takes (its configuration's:
    /// `--font-size=20`): run apart.
    separate,
    /// None: the running murrtty's windows to the front.
    present,
    /// `--gtk-single-instance=true` alone (the Jump List's New Window).
    new_window,
    /// A command or a pane's options: a new tab in the front window, with
    /// them and the launch's directory.
    new_tab: []const [:0]const u8,
};

fn handOffRequest(a: Allocator) HandOff {
    const argv = global.args().toSlice(a) catch return .separate;
    const cwd = currentDirectory(a);
    var args: std.ArrayList([:0]const u8) = .empty;
    // The launch's directory first: a later --working-directory wins, and
    // `inherit` keeps it.
    if (cwd) |d| args.append(a, a.printSentinel("--working-directory={s}", .{d}, 0) catch return .separate) catch return .separate;
    var explicit = false;
    var command = false;
    var any = false;
    if (argv.len > 1) for (argv[1..]) |given| {
        var arg = given;
        // A command's own arguments are its.
        if (!command) {
            if (std.mem.startsWith(u8, arg, "--class=")) continue;
            if (std.mem.startsWith(u8, arg, "--gtk-single-instance")) {
                explicit = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "-e")) {
                command = true;
            } else if (std.mem.cutPrefix(u8, arg, "--working-directory=")) |v| {
                // Relative to this launch's directory, not the running
                // murrtty's.
                const keyword = std.mem.eql(u8, v, "home") or std.mem.eql(u8, v, "inherit");
                if (!keyword and v.len > 0 and v[0] != '~' and !std.fs.path.isAbsoluteWindows(v)) if (cwd) |d| {
                    arg = a.printSentinel("--working-directory={s}\\{s}", .{ d, v }, 0) catch return .separate;
                };
            } else if (!std.mem.startsWith(u8, arg, "--title=") and
                !std.mem.startsWith(u8, arg, "--command=") and
                !std.mem.startsWith(u8, arg, "--shell-integration="))
            {
                return .separate;
            }
        }
        any = true;
        args.append(a, arg) catch return .separate;
    };
    if (!any) return if (explicit) .new_window else .present;
    return .{ .new_tab = args.items };
}

/// This process's current directory, as Windows has it (a mapped drive's
/// letter kept, unlike a resolved path), or null.
fn currentDirectory(a: Allocator) ?[]const u8 {
    const len = c.GetCurrentDirectoryW(0, null);
    if (len == 0) return null;
    const buf = a.alloc(u16, len) catch return null;
    const got = c.GetCurrentDirectoryW(len, buf.ptr);
    if (got == 0 or got >= len) return null;
    return std.unicode.utf16LeToUtf8Alloc(a, buf[0..got]) catch null;
}

/// Windows' restart of murrtty after an update or a reboot, where its
/// "restart apps" setting is on (roadmap 5.10b): it comes back and restores
/// its session. Only the instance keeping the session, and never under the
/// GUI tests.
fn registerRestart(self: *App) void {
    if (comptime test_hooks.enabled) if (test_hooks.active()) return;
    if (!self.session.owner) return;
    // Nothing to restore: nothing to restart for (window-save-state =
    // never, or no state folder).
    if (!self.session.enabled) {
        _ = c.UnregisterApplicationRestart();
        return;
    }
    const alloc = self.core_app.alloc;
    var line: std.ArrayList(u16) = .empty;
    defer line.deinit(alloc);
    if (self.config.class) |class| {
        const text = std.fmt.allocPrint(alloc, "--class={s}", .{class}) catch return;
        defer alloc.free(text);
        const wide = std.unicode.utf8ToUtf16LeAlloc(alloc, text) catch return;
        defer alloc.free(wide);
        ipc.appendQuoted(alloc, &line, wide) catch return;
    }
    line.append(alloc, 0) catch return;
    const args: ?[*:0]const u16 = if (line.items.len > 1) @ptrCast(line.items.ptr) else null;
    const hr = c.RegisterApplicationRestart(args, c.RESTART_NO_CRASH | c.RESTART_NO_HANG);
    if (hr < 0) log.warn("Windows won't restart murrtty after an update hr=0x{x}", .{@as(u32, @bitCast(hr))});
}

/// After restoring a session at start (roadmap 5.10b): a launch with a
/// command (`-e`) opens it in a tab of its own in the front window, with
/// no splits, rather than in the first restored pane.
fn openLaunchTab(self: *App) void {
    const command = self.config.@"initial-command" orelse return;
    const window = self.frontWindow() orelse return;
    const overrides: ipc.Overrides = .{ .command = command };
    self.ipc_overrides = &overrides;
    defer self.ipc_overrides = null;
    _ = window.addTab(null, .tab) catch |err| {
        log.warn("error opening the launch's command in a tab err={}", .{err});
        return;
    };
    window.present();
}

/// An IPC request: +new-window's window, or +new-tab's tab in the window of
/// the pane it names (else the focused one's, else a window, as GTK), with
/// the request's overrides, in front.
fn runIpc(self: *App, msg: ipc.Message) void {
    var arena: std.heap.ArenaAllocator = .init(self.core_app.alloc);
    defer arena.deinit();
    const overrides: ipc.Overrides = if (msg.arguments) |args|
        ipc.Overrides.parse(arena.allocator(), args) catch .{}
    else
        .{};

    // Started for this request, with no window to show for it: quit.
    defer if (self.ipc_launch and self.windows.items.len == 0) self.quitNow();

    // The first window asked for brings the saved session back (roadmap
    // 5.10b, initial-window = false); a plain +new-window (the CLI always
    // sends its directory) wants no more.
    if (msg.kind != .toggle_quick_terminal and msg.kind != .present and self.session.hasPending()) {
        const plain = overrides.command == null and overrides.title == null and overrides.shell_integration == null;
        if (self.session.restorePending() > 0 and msg.kind == .new_window and plain) return;
    }
    self.ipc_overrides = &overrides;
    defer self.ipc_overrides = null;

    // A second plain launch (roadmap 5.10b): as a click on the tray icon,
    // the windows forward, or a window (the session's) when there is none.
    if (msg.kind == .present) {
        self.trayActivate();
        return;
    }
    // +toggle-quick-terminal (roadmap 5.7).
    if (msg.kind == .toggle_quick_terminal) {
        _ = self.toggleQuickTerminal(.ipc);
        return;
    }
    if (msg.kind == .new_tab) if (self.ipcTabTarget(msg.surface_id)) |s| {
        const window = s.window;
        _ = window.addTab(&s.core_surface, .tab) catch |err| {
            log.warn("error creating the requested tab err={}", .{err});
            return;
        };
        window.present();
        return;
    };
    _ = Window.create(self, null) catch |err| {
        log.warn("error creating the requested window err={}", .{err});
    };
}

fn ipcTabTarget(self: *App, id: u64) ?*Surface {
    if (id != 0) {
        if (self.findSurface(id)) |s| return s;
        log.warn("new-tab: no surface 0x{x:0>16}, using the focused one", .{id});
    }
    // Else the front window's, as GTK's goes to its active window (a launch
    // handed over comes while another program has the keyboard). The core
    // keeps the last focused pane after murrtty loses the keyboard; the
    // quick terminal's (often hidden by then) isn't taken.
    if (self.core_app.focusedSurface()) |focused| if (self.findSurface(focused.id)) |s| {
        if (s.window.quick == null) return s;
    };
    const window = self.frontWindow() orelse return null;
    return window.activeSurface();
}

/// open_config:new_window: the config file in a new window running $VISUAL
/// or $EDITOR, titled as GTK's. With neither set it opens as open_config
/// does: GTK runs vi then, which Windows lacks.
fn openConfigInWindow(self: *App) void {
    var arena: std.heap.ArenaAllocator = .init(self.core_app.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const editor = editor: for ([_][]const u8{ "VISUAL", "EDITOR" }) |name| {
        const value = global.environ().getAlloc(alloc, name) catch continue;
        if (std.mem.trim(u8, value, " ").len > 0) break :editor value;
    } else {
        self.request(.open_config);
        return;
    };
    const open_path = configpkg.edit.openPath(alloc) catch |err| {
        log.warn("error getting config file path: {t}", .{err});
        return;
    };
    // It joins the file name with a slash.
    const path = alloc.dupeSentinel(u8, open_path, 0) catch return;
    std.mem.replaceScalar(u8, path, '/', '\\');
    // The editor as Windows splits a command (quotes group), then the file.
    var command: configpkg.Command = undefined;
    command.parseCLI(alloc, std.fmt.allocPrint(alloc, "direct:{s}", .{editor}) catch return) catch |err| {
        log.warn("error reading the editor command err={}", .{err});
        return;
    };
    const argv = std.mem.concat(alloc, [:0]const u8, &.{ command.direct, &.{path} }) catch return;
    const overrides: ipc.Overrides = .{
        .command = .{ .direct = argv },
        .title = alloc.printSentinel("Editing configuration file {s}", .{path}, 0) catch null,
    };
    self.ipc_overrides = &overrides;
    defer self.ipc_overrides = null;
    _ = Window.create(self, null) catch |err| {
        log.warn("error creating the config editor's window err={}", .{err});
    };
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

/// Ask for the title of `surface`, its tab or its window (prompt_title, a
/// double click on a tab), from the message loop: the core calls with a
/// key or a click still being handled.
pub fn promptTitle(self: *App, surface: *Surface, which: apprt.action.PromptTitle) void {
    if (!surface.core_initialized) return;
    self.request(.{ .prompt_title = .{ .id = surface.core_surface.id, .which = which } });
}

fn runTitlePrompt(self: *App, surface: *Surface, which: apprt.action.PromptTitle) void {
    const alloc = self.core_app.alloc;
    const window = surface.window;
    const tab = if (window.tabIndexOf(surface)) |i| window.tabs.items[i] else return;
    // The current title, GTK's: the pane's or tab's as shown, the window's
    // caption.
    const initial: []const u8 = switch (which) {
        .surface => surface.effectiveTitle() orelse "",
        .tab => tab.title(),
        .window => window.title_override orelse tab.title(),
    };
    // Closes wait until it ends, so the pane, tab and window stay.
    var modal = self.beginModal(window.hwnd, .{});
    defer modal.end();
    const name = TitleDialog.ask(alloc, window.hwnd, which, initial, self.chromeTheme().dark) catch |err| {
        log.warn("title prompt failed err={}", .{err});
        return;
    } orelse return;
    defer alloc.free(name);
    switch (which) {
        .surface => surface.setTitleOverride(name),
        .tab => tab.setTitleOverride(name),
        .window => window.setTitleOverride(name),
    }
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
            // Not in a window: parked for undo, its program ended.
            .close_surface => |v| if (self.findSurface(v.id)) |s| s.window.closeSurface(s, v.process_active) else self.undo.surfaceExited(v.id),
            .close_tabs => |v| if (self.findSurface(v.id)) |s| s.window.closeTabs(s, v.mode),
            .close_window => |id| if (self.findWindow(id)) |w| w.requestClose(),
            .close_all_windows => if (self.confirmCloseAll(.all_windows)) self.closeAllWindows(true),
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
            .prompt_title => |v| if (self.findSurface(v.id)) |s| self.runTitlePrompt(s, v.which),
            .open_url => |v| {
                defer req.deinit(self.core_app.alloc);
                self.openUrl(v);
            },
            .ipc => |v| {
                defer req.deinit(self.core_app.alloc);
                self.runIpc(v.message);
            },
            .present_surface => |id| if (self.findSurface(id)) |s| s.window.presentSurface(s),
            .undo => self.undo.runUndo(),
            .redo => self.undo.runRedo(),
            .export_io => |v| {
                defer req.deinit(self.core_app.alloc);
                self.exportTerminalIo(v.surface, v.contents);
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

/// murrtty's About box, from the main menu (GTK's About dialog, which no
/// core action shows).
pub fn showAbout(self: *App, owner: ?c.HWND) void {
    const alloc = self.core_app.alloc;
    const content = std.fmt.allocPrint(alloc,
        \\Version {s}, based on Ghostty {s}
        \\
        \\A native Windows terminal forked from Ghostty, open source under the MIT license. Ghostty is by Mitchell Hashimoto and its contributors; murrtty is not affiliated with the Ghostty project.
    , .{ build_config.version_string, build_config.ghostty_version_string }) catch return;
    defer alloc.free(content);
    _ = self.taskDialog(.{
        .owner = owner,
        .title = "About murrtty",
        .instruction = "murrtty",
        .content = content,
        .icon = .information,
        .common_buttons = c.TDCBF_OK_BUTTON,
        .default_button = c.IDOK,
    }) orelse {
        var modal = self.beginModal(owner, .{});
        defer modal.end();
        _ = Surface.messageBox(alloc, owner, content, "About murrtty", c.MB_OK | c.MB_ICONINFORMATION);
    };
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
    /// The quick terminal (by id), taken out of the topmost band so that a
    /// dialog of another window doesn't open under it.
    lowered_quick: ?u64 = null,

    pub fn end(self: *Modal) void {
        const app = self.app;
        if (self.ended) return;
        self.ended = true;
        std.debug.assert(app.modal_depth == self.depth);
        if (self.lowered_quick) |id| if (app.findWindow(id)) |w| if (w.quick) |*q| {
            q.lowered = false;
            _ = c.SetWindowPos(w.hwnd, c.HWND_TOPMOST, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOACTIVATE);
        };
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
        // A dialog of another window would open under the topmost quick
        // terminal (roadmap 5.7): out of the topmost band until it closes.
        if (self.quickWindow()) |q| if (c.IsWindowVisible(q.hwnd) != 0 and (owner == null or owner.? != q.hwnd) and !q.quick.?.lowered) {
            _ = c.SetWindowPos(q.hwnd, c.HWND_NOTOPMOST, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOACTIVATE);
            q.quick.?.lowered = true;
            modal.lowered_quick = q.id;
        };
        const alloc = self.core_app.alloc;
        var others: std.ArrayList(c.HWND) = .empty;
        defer others.deinit(alloc);
        for (self.windows.items) |w| others.append(alloc, w.hwnd) catch {};
        // The configuration editor too: its own dialogs and a reload must
        // not run inside another dialog's loop.
        if (self.config_editor) |e| others.append(alloc, e.hwnd) catch {};
        for (others.items) |hwnd| {
            if (owner != null and hwnd == owner.?) continue;
            // EnableWindow returns 0 if the window was enabled before.
            if (c.EnableWindow(hwnd, c.FALSE) == 0) {
                modal.disabled.append(alloc, hwnd) catch {
                    _ = c.EnableWindow(hwnd, c.TRUE);
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

/// GTK's close confirmation, a libadwaita alert dialog (AlertDialog): its
/// heading and body, then Cancel (the default; Escape too) and Close, in
/// the destructive color. True to close. Close requests made while it is
/// open are held until it closes.
pub fn confirmClose(self: *App, owner: ?c.HWND, target: CloseTarget) bool {
    {
        test_hooks.recordDialog(&self.test_state, target.heading(), target.body());
        var modal = self.beginModal(owner, .{});
        defer modal.end();
        if (AlertDialog.run(self.core_app.alloc, .{
            .owner = owner,
            .heading = target.heading(),
            .body = target.body(),
            .responses = &.{
                .{ .id = c.IDCANCEL, .label = "Cancel" },
                .{ .id = id_close, .label = "Close", .appearance = .destructive },
            },
            .default = c.IDCANCEL,
            .dark = self.chromeTheme().dark,
        })) |chosen| return chosen.id == id_close;
    }
    const chosen = self.taskDialog(.{
        .owner = owner,
        .title = "murrtty",
        .instruction = target.heading(),
        .content = target.body(),
        .icon = .warning,
        .buttons = &.{.{ .id = id_close, .text = "&Close" }},
        .common_buttons = c.TDCBF_CANCEL_BUTTON,
        .default_button = c.IDCANCEL,
    }) orelse {
        const alloc = self.core_app.alloc;
        const text = std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ target.heading(), target.body() }) catch return false;
        defer alloc.free(text);
        return self.confirm(owner, text, "murrtty");
    };
    return chosen == id_close;
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

    test_hooks.recordDialog(&self.test_state, td.instruction, td.content);
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
            if (c.GetProcAddress(lib, "TaskDialogIndirect")) |p| S.func = @ptrCast(@alignCast(p));
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

/// Run what waited for a dialog to close: close requests, global bindings'
/// hot keys, clipboard confirmations that need a dialog of their own, and
/// commands chosen in a command palette.
fn resumeAfterModal(self: *App) void {
    if (self.requests.items.len > 0 or self.global_keys.hasPending()) {
        _ = c.PostMessageW(self.wakeup_hwnd, WM_RUN_REQUESTS, 0, 0);
    }
    for (self.windows.items) |w| {
        var it = w.panes();
        while (it.next()) |s| s.resumeClipboardConfirms();
        w.palette.resumeAfterModal();
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

/// Run the queued requests and hot keys from the message loop.
pub fn postRunRequests(self: *App) void {
    _ = c.PostMessageW(self.wakeup_hwnd, WM_RUN_REQUESTS, 0, 0);
}

/// raiseModal, from the message loop: for use while handling an
/// activation, which shouldn't start another.
pub fn postRaiseModal(self: *App) void {
    _ = c.PostMessageW(self.wakeup_hwnd, WM_RAISE_MODAL, 0, 0);
}

pub fn findWindow(self: *App, id: u64) ?*Window {
    for (self.windows.items) |w| {
        if (w.id == id) return w;
    }
    return null;
}

pub fn findSurface(self: *App, id: u64) ?*Surface {
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
                WM_RUN_REQUESTS => {
                    self.runRequests();
                    self.global_keys.runPending();
                },
                else => self.raiseModal(),
            }
            return 0;
        },
        // The pipe's requests, queued again here so that they wait for any
        // dialog. The message carries nothing: any process on the desktop
        // can post it.
        WM_IPC => {
            const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
            if (ptr == 0) return 0;
            const self: *App = @ptrFromInt(@as(usize, @bitCast(ptr)));
            const server = self.ipc_server orelse return 0;
            while (server.take()) |received| {
                // Its window comes, even after a dialog: no need to quit.
                if (self.ipc_launch) _ = c.KillTimer(hwnd, ipc_launch_timer);
                // A second launch while a dialog is open raises the dialog
                // now (requests wait for it), as a click on the tray icon.
                if (received.message.kind == .present and self.modal_depth > 0) {
                    received.destroy(self.core_app.alloc);
                    self.raiseModal();
                    continue;
                }
                self.request(.{ .ipc = received });
            }
            return 0;
        },
        // A global binding's hot key (roadmap 5.5).
        c.WM_HOTKEY => {
            const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
            if (ptr == 0) return 0;
            const self: *App = @ptrFromInt(@as(usize, @bitCast(ptr)));
            self.global_keys.hotkey(lparam);
            return 0;
        },
        c.WM_TIMER => {
            const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
            if (ptr == 0) return 0;
            const self: *App = @ptrFromInt(@as(usize, @bitCast(ptr)));
            switch (wparam) {
                ipc_launch_timer => {
                    _ = c.KillTimer(hwnd, ipc_launch_timer);
                    if (self.windows.items.len == 0) {
                        log.warn("started for a request that never came, quitting", .{});
                        self.quitNow();
                    }
                },
                quit_timer_id => {
                    _ = c.KillTimer(hwnd, quit_timer_id);
                    self.quit_timer = .expired;
                    self.checkQuit();
                },
                GlobalKeys.retry_timer => self.global_keys.retry(),
                Undo.timer_id => self.undo.tick(),
                Session.timer_id => self.session.tick(),
                software_gl.timer_id => software_gl.tick(self),
                else => {},
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
    // A window toggle_visibility hid is gone (its shell exited): once all
    // are, nothing is hidden, and a tray click opens a window again.
    if (std.mem.indexOfScalar(u64, self.hidden_windows.items, window.id)) |i| {
        _ = self.hidden_windows.orderedRemove(i);
        if (self.hidden_front == window.id) self.hidden_front = null;
        if (self.hidden_windows.items.len == 0) self.windows_hidden = false;
    }
    self.rescueQuick();

    self.session.changed();
    // Quitting with the last window: what undo keeps goes first, so the
    // core sees its last surface go (and its quit timer starts).
    if (self.windows.items.len == 0 and self.config.@"quit-after-last-window-closed") self.undo.clear();
    self.checkQuit();
}

/// Quit once nothing keeps murrtty running, as GTK's loop decides (roadmap
/// 5.6): with quit-after-last-window-closed, when the quit timer has
/// expired, or (with no delay) once the last window has closed; and with no
/// window and no tray to reach murrtty by, unless a delay runs. Not before
/// run() has opened the first window or the tray.
fn checkQuit(self: *App) void {
    if (!self.started or self.quitting or self.windows.items.len > 0) return;
    // The configuration editor open: it asks before its changes go.
    if (self.config_editor != null) return;
    // Started for a request: its own timer decides.
    if (self.ipc_launch and !self.requested_window) return;
    const config = &self.config;
    if (config.@"quit-after-last-window-closed") {
        if (self.quit_timer == .expired) return self.quitNow();
        if (config.@"quit-after-last-window-closed-delay" == null and self.requested_window) return self.quitNow();
    }
    if (!self.notifications.tray and self.quit_timer != .active) self.quitNow();
}

fn startQuitTimer(self: *App) void {
    self.stopQuitTimer();
    const config = &self.config;
    if (!config.@"quit-after-last-window-closed") return;
    if (config.@"quit-after-last-window-closed-delay") |delay| {
        // At least 1 s, as documented; SetTimer's longest is about 24 days.
        const ms = std.math.clamp(delay.asMilliseconds(), 1000, 0x7FFF_FFFF);
        _ = c.SetTimer(self.wakeup_hwnd, quit_timer_id, ms, null);
        self.quit_timer = .active;
    } else self.quit_timer = .expired;
}

fn stopQuitTimer(self: *App) void {
    if (self.quit_timer == .active) _ = c.KillTimer(self.wakeup_hwnd, quit_timer_id);
    self.quit_timer = .off;
}

/// Open the configuration editor (roadmap F1), or bring it forward.
pub fn openConfigEditor(self: *App) void {
    if (self.modal_depth > 0) return self.raiseModal();
    ConfigEditor.open(self);
}

/// The configuration editor closed: murrtty may now quit (checkQuit).
pub fn configEditorClosed(self: *App) void {
    self.checkQuit();
}

/// Reload the configuration from its files, as a reload_config the user
/// asked for: the config editor's save.
pub fn reloadConfigFiles(self: *App) void {
    self.reloadConfig(.app, false) catch |err| {
        log.warn("error reloading the configuration err={}", .{err});
    };
}

/// The config editor's preview (roadmap F1d): the configuration in use
/// with `name` taken as `value` (checked by the editor), applied as a
/// reload applies one, while no file holds it yet.
pub fn previewConfig(self: *App, name: []const u8, value: []const u8) void {
    const alloc = self.core_app.alloc;
    var config = self.config.clone(alloc) catch |err| {
        log.warn("error previewing the configuration err={}", .{err});
        return;
    };
    defer config.deinit();
    // The value goes in without a replay step: steps would pile up, one per
    // preview, in every clone after (and after a `-e`'s marker they would
    // fold into initial-command). A light/dark switch mid-preview rebuilds
    // from the files' steps, without it, until the next preview.
    const steps = config._replay_steps.items.len;
    configpkg.option_list.apply(alloc, &config, name, value) catch |err| {
        log.warn("error previewing {s}={s} err={}", .{ name, value, err });
        return;
    };
    config._replay_steps.shrinkRetainingCapacity(steps);
    self.config_preview = .preview;
    defer self.config_preview = .off;
    self.core_app.updateConfig(self, &config) catch |err| {
        log.warn("error previewing the configuration err={}", .{err});
    };
}

/// The config editor closed without saving what it previewed: the files'
/// configuration back, quietly (no "Reloaded" toast, no errors shown again),
/// as this isn't a reload the user asked for.
pub fn revertConfigPreview(self: *App) void {
    var config = Config.load(self.core_app.alloc) catch |err| {
        log.warn("error reloading the configuration err={}", .{err});
        return;
    };
    defer config.deinit();
    self.config_preview = .revert;
    defer self.config_preview = .off;
    self.core_app.updateConfig(self, &config) catch |err| {
        log.warn("error reloading the configuration err={}", .{err});
    };
}

/// The tray (roadmap 5.6), while murrtty can run with no window:
/// quit-after-last-window-closed = false or initial-window = false.
fn syncTray(self: *App) void {
    const config = &self.config;
    self.notifications.setTray(!config.@"quit-after-last-window-closed" or !config.@"initial-window");
}

/// A click on the tray icon: the hidden windows back, murrtty's windows
/// forward, or a new window when there is none, as a click on macOS's dock
/// icon reopens one. With a dialog open, the dialog.
pub fn trayActivate(self: *App) void {
    if (self.modal_depth > 0) return self.raiseModal();
    if (self.windows_hidden) return self.showWindows();
    if (self.frontWindow()) |w| self.raiseWindows(w) else self.runAppAction(.new_window);
}

/// The window last activated, else the newest; never the quick terminal.
fn frontWindow(self: *App) ?*Window {
    if (self.last_window) |id| if (self.findWindow(id)) |w| return w;
    var i = self.windows.items.len;
    while (i > 0) {
        i -= 1;
        if (self.windows.items[i].quick == null) return self.windows.items[i];
    }
    return null;
}

/// The quick terminal's window, if it is open.
pub fn quickWindow(self: *App) ?*Window {
    for (self.windows.items) |w| if (w.quick != null) return w;
    return null;
}

/// toggle_quick_terminal (roadmap 5.7), GTK's: hide it or show it again,
/// or open it. Hiding needs a way back (a global binding with it, the tray,
/// another window's bindings, or the command that toggled it), or murrtty
/// would be out of reach. One autohide has just hidden (the click opening
/// the tray's menu took the keyboard) stays hidden.
fn toggleQuickTerminal(self: *App, from: enum { binding, ipc }) bool {
    const w = self.quickWindow() orelse {
        const created = Window.createQuick(self) catch |err| {
            log.warn("error creating the quick terminal err={}", .{err});
            return false;
        };
        if (from == .ipc) created.quick.?.ipc_toggled = true;
        return true;
    };
    const q = &w.quick.?;
    if (from == .ipc) q.ipc_toggled = true;
    if (!q.shown) {
        if (!q.justAutohidden()) q.show(w);
        return true;
    }
    if (!self.canShowQuick()) return false;
    q.hide(w);
    return true;
}

/// Put `text` in murrtty's selection clipboard (roadmap 5.9).
pub fn setSelection(self: *App, text: []const u8) !void {
    const alloc = self.core_app.alloc;
    const copy = try alloc.dupe(u8, text);
    if (self.selection) |old| alloc.free(old);
    self.selection = copy;
}

/// Whether a hidden quick terminal can come back: a global binding with
/// toggle_quick_terminal, the tray's menu, another window, or the command
/// that toggled it before.
pub fn canShowQuick(self: *App) bool {
    if (self.global_keys.binds(.toggle_quick_terminal) or self.notifications.tray) return true;
    for (self.windows.items) |w| {
        if (w.quick == null) return true;
        if (w.quick.?.ipc_toggled) return true;
    }
    return false;
}

/// A hidden quick terminal that nothing can bring back any more (its last
/// other window closed, a reload took the binding or the tray) shows; not
/// while everything closes.
fn rescueQuick(self: *App) void {
    if (self.quitting or self.closing_all) return;
    const w = self.quickWindow() orelse return;
    if (!w.quick.?.shown and !self.canShowQuick()) w.quick.?.show(w);
}

/// Whether `hwnd` is one of murrtty's (this process's).
pub fn ownsWindow(_: *const App, hwnd: c.HWND) bool {
    var pid: c.DWORD = 0;
    _ = c.GetWindowThreadProcessId(hwnd, &pid);
    return pid == c.GetCurrentProcessId();
}

/// The tray icon's menu at `at` (owned by its window, `owner`), then the
/// action chosen. One dialog or menu at a time.
pub fn trayMenu(self: *App, owner: c.HWND, at: c.POINT) void {
    if (self.modal_depth > 0) return self.raiseModal();
    switch (ContextMenu.trackTray(self, owner, at) orelse return) {
        .action => |action| self.runAppAction(action),
        .config_editor => self.openConfigEditor(),
        .about, .notify_next, .fit_screen => {},
    }
}

fn runAppAction(self: *App, action: input.Binding.Action) void {
    const scoped = action.scoped(.app) orelse return;
    self.core_app.performAction(self, scoped) catch |err| {
        log.warn("error running {s} err={}", .{ @tagName(action), err });
    };
}

/// Whether windows toggle_visibility hides can come back: through a global
/// binding with it, or the tray's click.
pub fn canShowHidden(self: *const App) bool {
    return self.global_keys.canShow() or self.notifications.tray;
}

/// Quit without asking (software_gl's failure too, which has no windows to
/// close otherwise).
pub fn quitNow(self: *App) void {
    if (self.quitting) return;
    self.quitting = true;
    c.PostQuitMessage(0);
}

/// True if closing every window may go ahead: nothing needs confirming,
/// or the user said yes.
fn confirmCloseAll(self: *App, target: CloseTarget) bool {
    if (!self.core_app.needsConfirmQuit() or
        self.config.@"confirm-close-surface" == .false) return true;

    // Show it over the window the user is in, which then gets the focus
    // back if they answer no.
    const foreground = c.GetForegroundWindow();
    var owner: ?c.HWND = if (self.windows.items.len > 0) self.windows.items[0].hwnd else null;
    for (self.windows.items) |w| {
        if (foreground == w.hwnd) owner = w.hwnd;
    }
    return self.confirmClose(owner, target);
}

fn quit(self: *App) void {
    // The configuration editor's changes first: Save, Discard or Cancel.
    if (self.config_editor) |editor| if (!editor.allowQuit()) return;
    if (!self.confirmCloseAll(.app)) return;
    // The session as it is: the windows closing now don't empty it.
    self.session.freeze();
    self.closeAllWindows(false);
    self.quitNow();
}

/// WGL's extensions (the inspector's windows, roadmap 5.12), loaded once.
pub fn wglExtensions(self: *App) !*const wgl.Extensions {
    if (self.wgl_ext == null) self.wgl_ext = try wgl.Extensions.load();
    return &self.wgl_ext.?;
}

/// Save the inspector's Terminal IO events where the user says, as GTK's:
/// a save dialog, "Export Terminal IO Events", over the pane's inspector
/// (else its window). With the test hooks, GHOSTTY_WIN32_TEST_EXPORT names
/// the file instead and no dialog shows.
fn exportTerminalIo(self: *App, id: u64, contents: []const u8) void {
    var path: [1024:0]u16 = @splat(0);
    const default_name = std.unicode.utf8ToUtf16LeStringLiteral("murrtty-terminal-io.txt");
    @memcpy(path[0..default_name.len], default_name);
    const from_test = test_hooks.enabled and
        c.GetEnvironmentVariableW(c.L("GHOSTTY_WIN32_TEST_EXPORT"), &path, path.len) > 0;
    if (!from_test) {
        const owner: ?c.HWND = if (self.findSurface(id)) |s|
            if (s.inspector) |i| i.hwnd else s.window.hwnd
        else
            null;
        var ofn: c.OPENFILENAMEW = .{
            .hwndOwner = owner,
            .lpstrFilter = c.L("Text files (*.txt)\x00*.txt\x00All files\x00*.*\x00"),
            .lpstrFile = &path,
            .nMaxFile = path.len,
            .lpstrTitle = c.L("Export Terminal IO Events"),
            .Flags = c.OFN_OVERWRITEPROMPT | c.OFN_PATHMUSTEXIST | c.OFN_NOCHANGEDIR | c.OFN_EXPLORER,
            .lpstrDefExt = c.L("txt"),
        };
        var modal = self.beginModal(owner, .{});
        defer modal.end();
        if (c.GetSaveFileNameW(&ofn) == 0) return;
    }
    const file = c.CreateFileW(&path, c.GENERIC_WRITE, 0, null, c.CREATE_ALWAYS, c.FILE_ATTRIBUTE_NORMAL, null);
    if (file == c.INVALID_HANDLE_VALUE) {
        log.warn("error creating the Terminal IO file err={}", .{c.GetLastError()});
        return;
    }
    defer _ = c.CloseHandle(file);
    var rest = contents;
    while (rest.len > 0) {
        var written: c.DWORD = 0;
        const n: c.DWORD = @intCast(@min(rest.len, 1 << 30));
        if (c.WriteFile(file, rest.ptr, n, &written, null) == 0 or written == 0) {
            log.warn("error writing the Terminal IO file err={}", .{c.GetLastError()});
            return;
        }
        rest = rest[written..];
    }
}

/// Close every window, kept for undo as one close if `park` (roadmap 5.11;
/// not when quitting).
fn closeAllWindows(self: *App, park: bool) void {
    self.closing_all = true;
    defer self.closing_all = false;
    self.undo.begin(.close_all_windows);
    defer self.undo.end();
    while (self.windows.items.len > 0) {
        const w = self.windows.items[self.windows.items.len - 1];
        if (park and self.undo.enabled()) self.undo.parkWindow(w);
        w.destroy();
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
    self.syncMenuTheme();
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

/// A system setting changed (WM_SETTINGCHANGE, which names few of them):
/// read again the one the scrollbar follows.
pub fn systemSettingChanged(self: *App) void {
    self.setScrollbarsAlways(scrollbarsAlwaysShown());
}

/// Whether Windows always shows scroll bars (or the GUI tests say so).
pub fn setScrollbarsAlways(self: *App, always: bool) void {
    if (always == self.scrollbars_always) return;
    self.scrollbars_always = always;
    for (self.windows.items) |w| {
        var it = w.panes();
        while (it.next()) |s| s.scrollbar.settingsChanged(s);
    }
}

/// Windows' "Always show scrollbars": DynamicScrollbars 0. Unset, they
/// hide (the default).
fn scrollbarsAlwaysShown() bool {
    var value: c.DWORD = 1;
    var size: c.DWORD = @sizeOf(c.DWORD);
    const status = c.RegGetValueW(
        c.HKEY_CURRENT_USER,
        c.L("Control Panel\\Accessibility"),
        c.L("DynamicScrollbars"),
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
        // As GTK does: a pane's soft reload (its conditional state changed,
        // say its color scheme) updates that pane alone, not the whole app
        // (which, on a light/dark switch, every pane asks for).
        switch (target) {
            .app => try self.core_app.updateConfig(self, &self.config),
            .surface => |core| try core.updateConfig(&self.config),
        }
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

    // GTK's dialog, a libadwaita alert dialog (AlertDialog): every error in
    // a box under its body, Ignore and Reload Configuration (suggested),
    // and murrtty's Open Configuration, which leaves it open.
    alert: {
        const heading = "Configuration Errors";
        const body = "One or more configuration errors were found. Please review the errors below, and either reload your configuration or ignore these errors.";
        var lines: std.ArrayList(u8) = .empty;
        defer lines.deinit(alloc);
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, all.items, "\n"), '\n');
        while (it.next()) |line| lines.print(alloc, "{s}\r\n", .{line}) catch break :alert;
        const wide = text_util.utf16Lossy(alloc, lines.items) catch break :alert;
        defer alloc.free(wide);
        test_hooks.recordDialog(&self.test_state, heading, body);
        var modal = self.beginModal(owner, .{});
        defer modal.end();
        const result = AlertDialog.run(alloc, .{
            .owner = owner,
            .heading = heading,
            .body = body,
            .responses = &.{
                .{ .id = id_ignore_config, .label = "Ignore" },
                .{ .id = id_open_config, .label = "Open Configuration" },
                .{ .id = id_reload_config, .label = "Reload Configuration", .appearance = .suggested },
            },
            .default = id_ignore_config,
            .dark = self.chromeTheme().dark,
            .text = .{ .content = wide, .height = 100 },
            .stay = .{ .ids = &.{id_open_config}, .ctx = self, .action = openConfigFromAlert },
        }) orelse break :alert;
        modal.end();
        if (result.id == id_reload_config) self.reloadConfig(.app, false) catch |err| {
            log.warn("error reloading the config err={}", .{err});
        };
        return;
    }

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

fn openConfigFromAlert(ctx: *anyopaque, _: u16) void {
    const self: *App = @ptrCast(@alignCast(ctx));
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

/// goto_window: the next or previous window, never the quick terminal
/// (roadmap 5.7, which has its own toggle; GTK's and macOS's cycle through
/// theirs too). From the quick terminal, the first or the last window.
fn gotoWindow(self: *App, target: apprt.Target, direction: apprt.action.GotoWindow) bool {
    const current = windowFromTarget(target) orelse return false;
    var list: std.ArrayList(*Window) = .empty;
    defer list.deinit(self.core_app.alloc);
    for (self.windows.items) |w| if (w.quick == null) list.append(self.core_app.alloc, w) catch return false;
    const n = list.items.len;
    const i = std.mem.indexOfScalar(*Window, list.items, current) orelse {
        if (n == 0) return false;
        list.items[if (direction == .next) 0 else n - 1].present();
        return true;
    };
    if (n < 2) return false;
    const next = switch (direction) {
        .next => (i + 1) % n,
        .previous => (i + n - 1) % n,
    };
    list.items[next].present();
    return true;
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    // A pane parked for undo (roadmap 5.11) has no window to act on or to
    // show anything in: what its program asks for goes nowhere, and an
    // `all:` binding (the core's loop visits every pane) passes it by.
    if (surfaceFromTarget(target)) |s| if (s.parked()) switch (action) {
        // Handled: open_url's false would have the core open the link
        // itself (an `all:write_screen_file:open`, say).
        .ring_bell, .desktop_notification, .command_finished, .open_url => return true,
        .new_window,
        .new_tab,
        .new_split,
        .close_tab,
        .close_window,
        .goto_tab,
        .goto_split,
        .goto_window,
        .move_tab,
        .move_tab_to_new_window,
        .resize_split,
        .equalize_splits,
        .toggle_split_zoom,
        .toggle_fullscreen,
        .toggle_maximize,
        .toggle_window_decorations,
        .toggle_background_opacity,
        .toggle_tab_overview,
        .toggle_command_palette,
        .float_window,
        .present_terminal,
        .inspector,
        .reset_window_size,
        .prompt_title,
        .start_search,
        .show_on_screen_keyboard,
        => return false,
        else => {},
    };

    switch (action) {
        // Closing runs from the message loop: the core is still using
        // the surface that triggered these (see Request).
        .quit => self.request(.quit),

        // The terminal inspector (roadmap 5.12): its window, as GTK's.
        .inspector => {
            const surface = surfaceFromTarget(target) orelse return false;
            return surface.controlInspector(value);
        },

        // The core calls mid-frame of the inspector, with the terminal's
        // lock held: a copy, saved from the message loop (a dialog's loop
        // would draw the inspector again inside its own frame).
        .export_terminal_io => {
            const surface = surfaceFromTarget(target) orelse return false;
            if (!surface.core_initialized) return false;
            const copy = try self.core_app.alloc.dupe(u8, value.contents);
            self.request(.{ .export_io = .{ .surface = surface.core_surface.id, .contents = copy } });
        },

        // Undo and redo of closes (roadmap 5.11), from the message loop:
        // what they bring back or close the core may be using now. False
        // with nothing to do, so a performable binding's key goes on.
        .undo => {
            if (!self.undo.canUndo()) return false;
            self.request(.undo);
        },
        .redo => {
            if (!self.undo.canRedo()) return false;
            self.request(.redo);
        },

        .new_window => {
            const parent: ?*CoreSurface = switch (target) {
                .app => null,
                .surface => |v| v,
            };
            // The first window asked for brings a session that waited
            // (initial-window = false, roadmap 5.10b), also from the quick
            // terminal's pane while it is the only window.
            if ((parent == null or self.frontWindow() == null) and self.session.hasPending()) {
                if (self.session.restorePending() > 0) return true;
            }
            _ = try Window.create(self, parent);
        },

        // Created at once, so that a chained action (new_tab then
        // goto_tab) finds it. The core's `all:` loop copes with surfaces
        // added while it runs.
        .new_tab => switch (target) {
            .app => {
                // A tab with no window: a session that waited, else a window.
                if (self.session.hasPending() and self.session.restorePending() > 0) return true;
                _ = try Window.create(self, null);
            },
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

        // Its panes keep running in the new window (roadmap 4.5); nothing
        // is freed, so this runs inside the core's callback.
        .move_tab_to_new_window => {
            const surface = surfaceFromTarget(target) orelse return false;
            return surface.window.moveTabToNewWindow(surface);
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

        // This window only, as GTK's (roadmap 4.4).
        .toggle_window_decorations => {
            const window = windowFromTarget(target) orelse return false;
            window.toggleDecorations();
        },

        // As macOS (GTK leaves it out): every window at once, and new ones
        // follow; nothing to toggle while background-opacity is 1.
        .toggle_background_opacity => {
            if (self.config.@"background-opacity" >= 1) return false;
            self.force_opaque = !self.force_opaque;
            for (self.windows.items) |w| w.syncTranslucent();
        },

        .initial_size => {
            // Only the window's first surface sizes the window; a new
            // tab must not resize an existing window. (A tab joins the
            // list once its first pane is initialized.)
            // Each time (the core sends it again on font size changes):
            // reset_window_size comes back to it.
            if (surfaceFromTarget(target)) |s| s.initial_size = .{ value.width, value.height };
            const window = windowFromTarget(target) orelse return false;
            if (window.tabs.items.len > 0) return false;
            window.setClientSize(value.width, value.height);
        },

        // As macOS (GTK leaves them out; roadmap 4.6).
        .float_window => {
            const window = windowFromTarget(target) orelse return false;
            window.setFloat(value);
        },
        .reset_window_size => {
            const window = windowFromTarget(target) orelse return false;
            return window.resetSize();
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
            // bell-features title (roadmap 3.7a), and the header bars'
            // bell for a pane without the keyboard.
            if (surfaceFromTarget(target)) |s| {
                s.ringBell();
                self.waiting.add(self, s, null);
            }
        },

        .toggle_visibility => return self.toggleVisibility(),
        .toggle_quick_terminal => return self.toggleQuickTerminal(.binding),

        // OSC 9;4 (roadmap 5.4): the pane's bar and its window's taskbar
        // button.
        .progress_report => {
            const surface = surfaceFromTarget(target) orelse return false;
            surface.setProgress(value);
        },

        // OSC 9 and OSC 777 (roadmap 5.2); the core has checked
        // desktop-notifications and limited the rate.
        .desktop_notification => {
            const surface = surfaceFromTarget(target);
            self.notifications.send(
                if (surface) |s| s.core_surface.id else null,
                if (surface) |s| s.has_focus else false,
                value.title,
                value.body,
            );
            if (surface) |s| self.waiting.add(self, s, .{ .title = value.title, .body = value.body });
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
        // core is using the surface that triggered this. A window opens at
        // once, as new_window's.
        .open_config => switch (value) {
            .os_open => self.request(.open_config),
            .new_window => self.openConfigInWindow(),
        },

        .reload_config => try self.reloadConfig(target, value.soft),

        .config_change => switch (target) {
            // A surface's own config (after a reload, or its conditional
            // state changing) resets the colors its tab and caption show.
            .surface => |core| {
                const surface = core.rt_surface;
                surface.colors = .fromConfig(value.config);
                surface.window.colorsChanged(surface);
                // The scrollbar's thumb is in the foreground color.
                surface.updateOverlay();
            },
            .app => {
                const config = try value.config.clone(self.core_app.alloc);
                self.config.deinit();
                self.config = config;
                // window-theme or the colors may have changed.
                self.syncMenuTheme();
                for (self.windows.items) |w| {
                    w.configChanged();
                    // `scrollbar` may have changed.
                    var it = w.panes();
                    while (it.next()) |s| s.scrollbar.settingsChanged(s);
                    // GTK's toast, in every window, for a reload of any
                    // kind (the light/dark switch reloads it too), but not
                    // the config editor's preview.
                    if (self.config_preview == .off and self.config.@"app-notifications".@"config-reload") w.showToast("Reloaded the configuration");
                }
                // A preview changes only what its window draws.
                if (self.config_preview == .preview) return true;
                // window-theme may now force a different scheme.
                self.reportColorScheme();
                self.queueConfigErrors();
                // The tray and the global bindings may have changed (with
                // nothing left to show hidden windows, they come back), and
                // with them what keeps murrtty running.
                self.syncTray();
                self.global_keys.refresh(.config);
                // window-save-state may have changed, and with it Windows'
                // restart.
                self.session.configChanged();
                if (self.started) self.registerRestart();
                if (self.windows_hidden and !self.canShowHidden()) self.showWindows();
                // The tray gone with no window: as if the last had just
                // closed (a delay still applies).
                if (self.started and self.windows.items.len == 0 and !self.notifications.tray and
                    self.quit_timer == .off) self.startQuitTimer();
                self.rescueQuick();
                self.checkQuit();
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
            if (value.kind == .foreground) surface.updateOverlay();
        },

        .quit_timer => switch (value) {
            .start => {
                self.startQuitTimer();
                self.checkQuit();
            },
            .stop => self.stopQuitTimer(),
        },

        // The status overlays (roadmap 3.6).
        .renderer_health => {
            log.info("renderer health={}", .{value});
            const surface = surfaceFromTarget(target) orelse return false;
            surface.setRendererHealth(value);
        },
        // For UI Automation's listeners (roadmap 6.4).
        .selection_changed => {
            const surface = surfaceFromTarget(target) orelse return false;
            @import("Uia.zig").selectionChanged(surface);
        },
        .show_on_screen_keyboard => {
            const surface = surfaceFromTarget(target) orelse return false;
            return surface.showOnScreenKeyboard();
        },
        .mouse_over_link => {
            const surface = surfaceFromTarget(target) orelse return false;
            surface.setLinkPreview(value.url);
        },
        .readonly => {
            const surface = surfaceFromTarget(target) orelse return false;
            surface.setReadonly(value == .on);
        },
        .key_sequence => {
            const surface = surfaceFromTarget(target) orelse return false;
            surface.keySequence(value);
        },
        .key_table => {
            const surface = surfaceFromTarget(target) orelse return false;
            surface.keyTable(value);
        },
        .show_child_exited => {
            const surface = surfaceFromTarget(target) orelse return false;
            return surface.childExited(value);
        },

        // notify-on-command-finish (roadmap 5.3); counted for the GUI
        // tests' dump too.
        .command_finished => {
            const surface = surfaceFromTarget(target) orelse return false;
            surface.commands_finished +%= 1;
            surface.last_exit = value.exit_code;
            self.commandFinished(surface, value);
            // A command may have moved its shell (roadmap 5.10b).
            self.session.changed();
        },

        // A shell reported its directory: the session keeps it.
        .pwd => self.session.changed(),

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

        // Titles (roadmap 3.5): the user's names over the program's.
        .prompt_title => {
            const surface = surfaceFromTarget(target) orelse return false;
            self.promptTitle(surface, value);
        },
        .set_tab_title => {
            const surface = surfaceFromTarget(target) orelse return false;
            const i = surface.window.tabIndexOf(surface) orelse return false;
            surface.window.tabs.items[i].setTitleOverride(value.title);
        },
        .set_window_title => {
            const surface = surfaceFromTarget(target) orelse return false;
            surface.window.setTitleOverride(value.title);
        },
        .copy_title_to_clipboard => {
            const surface = surfaceFromTarget(target) orelse return false;
            const title = surface.effectiveTitle() orelse return false;
            if (title.len == 0) return false;
            try surface.setClipboard(.standard, &.{.{ .mime = "text/plain", .data = title }}, false);
        },

        // The scrollbar (roadmap 3.4): the scrollable area changed.
        .scrollbar => {
            const surface = surfaceFromTarget(target) orelse return false;
            surface.scrollbar.update(surface, value);
        },

        // The command palette (roadmap 3.3), one per window.
        .toggle_command_palette => {
            const surface = surfaceFromTarget(target) orelse return false;
            surface.window.palette.toggle(surface.window, surface);
        },

        // The tab list (roadmap 3.8), also without a tab strip.
        .toggle_tab_overview => {
            const surface = surfaceFromTarget(target) orelse return false;
            surface.window.toggleTabList();
        },

        else => {
            log.debug("unimplemented action={}", .{action});
            return false;
        },
    }

    return true;
}

/// toggle_visibility, macOS's (GTK lacks it): with murrtty in front, hide
/// every window; otherwise bring murrtty forward, the hidden windows as
/// they were. Hiding needs a way to show them again (roadmap 5.5): a
/// global binding with it, or the tray (5.6); hidden with no way back, the
/// process would be out of reach.
fn toggleVisibility(self: *App) bool {
    if (comptime test_hooks.enabled) self.test_state.toggles += 1;
    if (self.windows_hidden) {
        self.showWindows();
        return true;
    }
    if (!self.inFront()) {
        self.raiseWindows(self.frontWindow() orelse return false);
        return true;
    }
    if (!self.canShowHidden()) return false;
    const alloc = self.core_app.alloc;
    self.hidden_windows.clearRetainingCapacity();
    self.hidden_front = null;
    const foreground = c.GetForegroundWindow();
    const front_root = if (foreground) |f| c.GetAncestor(f, c.GA_ROOTOWNER) else null;
    for (self.windows.items) |w| {
        // Windows out of sight already (a tab torn off, not yet shown)
        // stay so, and the quick terminal has its own toggle.
        if (c.IsWindowVisible(w.hwnd) == 0 or w.quick != null) continue;
        self.hidden_windows.append(alloc, w.id) catch return false;
        if (w.hwnd == foreground or w.hwnd == front_root) self.hidden_front = w.id;
    }
    self.windows_hidden = true;
    for (self.hidden_windows.items) |id| if (self.findWindow(id)) |w| {
        _ = c.ShowWindow(w.hwnd, c.SW_HIDE);
    };
    return true;
}

/// Whether murrtty has the foreground: one of its windows, or a dialog or
/// menu of its own.
fn inFront(self: *App) bool {
    if (comptime test_hooks.enabled) switch (self.test_state.in_front) {
        .real => {},
        .yes => return true,
        .no => return false,
    };
    const foreground = c.GetForegroundWindow() orelse return false;
    var pid: c.DWORD = 0;
    _ = c.GetWindowThreadProcessId(foreground, &pid);
    return pid == c.GetCurrentProcessId();
}

/// Show the windows toggle_visibility hid, the one in front then in front
/// again: for the binding, for a window brought forward (a notification's
/// click, the pipe's request, a new window), and once no binding could.
pub fn showWindows(self: *App) void {
    if (!self.windows_hidden) return;
    self.windows_hidden = false;
    for (self.hidden_windows.items) |id| if (self.findWindow(id)) |w| {
        _ = c.ShowWindow(w.hwnd, c.SW_SHOWNA);
    };
    const front = if (self.hidden_front) |id| self.findWindow(id) else null;
    const last = if (self.hidden_windows.items.len > 0) self.findWindow(self.hidden_windows.items[self.hidden_windows.items.len - 1]) else null;
    self.hidden_windows.clearRetainingCapacity();
    self.hidden_front = null;
    if (front orelse last) |w| self.raiseWindows(w);
}

/// Bring `front` forward and murrtty's other windows just behind it, above
/// other programs, as activating an app does on macOS. The foreground
/// (which a hot key's press grants) lets the others move up too.
fn raiseWindows(self: *App, front: *Window) void {
    front.present();
    for (self.windows.items) |w| {
        // Placed behind a window, the topmost quick terminal would stop
        // being topmost.
        if (w == front or w.quick != null or c.IsWindowVisible(w.hwnd) == 0 or c.IsIconic(w.hwnd) != 0) continue;
        _ = c.SetWindowPos(w.hwnd, front.hwnd, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOACTIVATE);
    }
}

/// A command finished in `surface` (shell integration's OSC 133;D after
/// its 133;C): GTK's commandFinished. The pane's Notify on Next Command
/// Finish, or notify-on-command-finish (`always`, or `unfocused` while the
/// pane lacks the keyboard), for one that took longer than
/// notify-on-command-finish-after, rings the bell and notifies as
/// notify-on-command-finish-action says.
fn commandFinished(self: *App, surface: *Surface, value: apprt.action.CommandFinished) void {
    const next = surface.notify_next_command;
    surface.notify_next_command = false;
    const config = &self.config;
    if (!next) switch (config.@"notify-on-command-finish") {
        .never => return,
        .unfocused => if (surface.has_focus) return,
        .always => {},
    };
    if (value.duration.lte(config.@"notify-on-command-finish-after")) return;
    const action = config.@"notify-on-command-finish-action";
    if (action.bell) {
        surface.window.ringBell();
        surface.ringBell();
        self.waiting.add(self, surface, null);
    }
    if (!action.notify) return;
    const title: [:0]const u8 = if (value.exit_code) |code|
        if (code == 0) "Command Succeeded" else "Command Failed"
    else
        "Command Finished";
    var buf: [128]u8 = undefined;
    const rounded = value.duration.round(std.time.ns_per_ms);
    const body = (if (value.exit_code) |code|
        std.fmt.bufPrintSentinel(&buf, "Command took {f} and exited with code {d}.", .{ rounded, code }, 0)
    else
        std.fmt.bufPrintSentinel(&buf, "Command took {f}.", .{rounded}, 0)) catch return;
    self.notifications.send(surface.core_surface.id, surface.has_focus, title, body);
    self.waiting.add(self, surface, .{ .title = title, .body = body });
}

/// The chrome's colors for `window-theme`, GTK's (roadmap 4.3, the Look
/// rule):
/// - `auto` (the default): Adwaita's, light or dark by the configured
///   background's luminance (not following programs that change it).
/// - `ghostty`: `window-titlebar-background`/`-foreground`, or the
///   configured background and foreground.
/// - `system`: Adwaita's, following the system's light or dark setting.
/// - `light`, `dark`: Adwaita's, as named.
pub fn chromeTheme(self: *const App) draw.Theme {
    const config = &self.config;
    var theme = switch (config.@"window-theme") {
        .auto => draw.adwaita(draw.isDark(config.background)),
        .ghostty => draw.ghosttyTheme(
            config.@"window-titlebar-background" orelse config.background,
            config.@"window-titlebar-foreground" orelse config.foreground,
        ),
        .system => draw.adwaita(self.dark),
        .light => draw.adwaita(false),
        .dark => draw.adwaita(true),
    };
    // A flat top bar has no background of its own, so the window's shows
    // (gtk-toolbar-style = flat). Ghostty's stylesheet for the ghostty
    // theme colors the header's window handle anyway.
    if (config.@"gtk-toolbar-style" == .flat and config.@"window-theme" != .ghostty) theme.bar = theme.window;
    return theme;
}

/// Popup menus' frames light or dark as the chrome is (the items are
/// murrtty's own, ContextMenu), whatever Windows uses for apps. Windows
/// has no public API for it; this uses uxtheme's exports by ordinal, as
/// Windows Terminal and File Explorer do: 135 is SetPreferredAppMode (2
/// ForceDark, 3 ForceLight) since Windows 10 1903 (before, it was
/// AllowDarkModeForApp, which takes only on or off), 136 FlushMenuThemes.
/// Missing, it does nothing.
fn syncMenuTheme(self: *const App) void {
    const uxtheme = c.LoadLibraryW(c.L("uxtheme.dll")) orelse return;
    if (c.GetProcAddress(uxtheme, @ptrFromInt(135))) |p| {
        const setMode: *const fn (c_int) callconv(.winapi) c_int = @ptrCast(@alignCast(p));
        _ = setMode(if (self.chromeTheme().dark) 2 else 3);
    }
    if (c.GetProcAddress(uxtheme, @ptrFromInt(136))) |p| {
        const flush: *const fn () callconv(.winapi) void = @ptrCast(@alignCast(p));
        flush();
    }
}

/// Whether a key-binding action does anything here: the core performs it
/// itself, or it becomes a runtime action this runtime implements (see
/// performAction). Menus gray out, and the command palette hides, the
/// actions it doesn't (roadmap 3.0). Kept in step with performAction.
pub fn supportsAction(action: input.Binding.Action) bool {
    return switch (action) {
        // Runtime actions not implemented (Windows has nothing secure
        // input could use; roadmap 6.5), or not yet.
        .show_gtk_inspector,
        .toggle_secure_input,
        .check_for_updates,
        => false,

        // Only from a global binding (roadmap 5.5), which can also bring
        // the windows back: menus and the palette don't offer it.
        .toggle_visibility => false,

        else => true,
    };
}

/// A CLI action's request to the running murrtty (`+new-window`,
/// `+new-tab`, `+toggle-quick-terminal`), over the single instance's pipe;
/// a murrtty is started for it if none runs (ipc.request).
pub fn performIpc(
    alloc: Allocator,
    target: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    value: apprt.ipc.Action.Value(action),
) (Allocator.Error || apprt.ipc.Errors)!bool {
    const msg: ipc.Message = switch (action) {
        .new_window => .{ .kind = .new_window, .arguments = value.arguments },
        .new_tab => .{ .kind = .new_tab, .surface_id = value.surface_id, .arguments = value.arguments },
        .toggle_quick_terminal => .{ .kind = .toggle_quick_terminal },
    };
    try ipc.request(alloc, switch (target) {
        .class => |class| class,
        .detect => null,
    }, msg);
    return true;
}

pub fn redrawInspector(_: *App, _: *Surface) void {}

pub fn keyboardLayout(_: *const App) input.KeyboardLayout {
    return .unknown;
}
