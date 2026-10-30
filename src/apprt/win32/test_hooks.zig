//! Hooks for the GUI test harness (test/windows/gui), in Debug builds only.
//!
//! When the environment variable GHOSTTY_WIN32_TEST_DUMP names a file, the
//! wakeup window answers the registered message "GhosttyWin32TestDump" by
//! writing the app's state to that file as JSON: windows, tabs, tab-bar
//! geometry, titles, grid sizes and each terminal's visible text. The
//! harness sends the message with SendMessageTimeout, so the file is
//! complete when the call returns.
//!
//! While the hooks are on, links that would open (a browser, Explorer, a
//! protocol handler) are recorded in the dump instead, so the tests can
//! check what would have opened without anything appearing on the user's
//! screen. GHOSTTY_WIN32_TEST_LAUNCH=1 opens them for real, for a test
//! whose handlers are its own. What Ghostty copies is kept out of the
//! user's clipboard history. Release builds compile none of this.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const c = @import("c.zig");
const draw = @import("draw.zig");
const global = @import("../../global.zig");
const App = @import("App.zig");
const ContextMenu = @import("ContextMenu.zig");
const Notifications = @import("Notifications.zig");
const DropTarget = @import("DropTarget.zig");
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.win32_test_hooks);

pub const enabled = builtin.mode == .debug;

pub const State = if (enabled) struct {
    /// The registered message, or 0 when the hooks are off.
    msg: c.UINT = 0,
    /// Where to write the dump, as UTF-16 for CreateFileW.
    path: ?[:0]u16 = null,
    /// What would have opened, as "verb target".
    launches: std.ArrayList([]u8) = .empty,
    /// Whether launches are recorded instead of performed.
    record_launches: bool = true,
    /// Spike S1's overlays (see setOverlays).
    overlays: std.ArrayList(Overlay) = .empty,
    overlay_class: bool = false,
    /// Context menus shown (ContextMenu.track).
    menus_shown: u32 = 0,
    /// The last task dialog's heading and body (App.taskDialog), which
    /// can't be read from outside (a DirectUIHWND draws them).
    dialog_heading: [128]u8 = undefined,
    dialog_heading_len: usize = 0,
    dialog_body: [256]u8 = undefined,
    dialog_body_len: usize = 0,
    /// Panes ignore WM_MOUSELEAVE (dump wparam 7): on the hidden desktop
    /// the real cursor is never over a window, so Windows answers a posted
    /// move's leave tracking at once, and hover state (a link's preview)
    /// would go before a test could see it.
    pin_mouse: bool = false,
    /// Blur with the accent policy, as before Windows 11 22H2, whatever
    /// the build, so that path runs here too; or with Acrylic even while
    /// inactive, to see what Windows draws then (dump wparam 13).
    force_blur: enum { none, accent, acrylic } = .none,
    /// Desktop notifications, as they would show (roadmap 5.2), recorded
    /// instead of shown unless GHOSTTY_WIN32_TEST_NOTIFY is set.
    notifications: std.ArrayList(Notified) = .empty,
    record_notifications: bool = true,
    /// Whether murrtty counts as in front for toggle_visibility (dump
    /// wparam 16): on the hidden desktop the foreground window is always
    /// the user desktop's.
    in_front: enum { real, yes, no } = .real,
    /// toggle_visibility's runs, and the global bindings' registrations
    /// (roadmap 5.5), to tell an action refused from one never run.
    toggles: u32 = 0,
    global_refreshes: u32 = 0,
    /// The last test drop's effect (dump wparam 17; roadmap 5.8): 1 a
    /// copy, 0 refused, -1 none made.
    drop_effect: i32 = -1,
    /// show_on_screen_keyboard's requests (roadmap 6.5), and the last
    /// one's result. The window's input pane is only looked up unless
    /// GHOSTTY_WIN32_TEST_OSK is set.
    osk_asks: u32 = 0,
    osk_hr: i32 = 0,
    osk_done: bool = false,
    record_osk: bool = true,
} else struct {};

pub const Notified = struct {
    /// The pane's core id, 0 for murrtty's own.
    surface: u64,
    /// As the balloon shows them, cut to its fields.
    title: []u8,
    body: []u8,
};

/// Crash for the crash report scenario: the report must come from Sentry's
/// in-process backend (an exception) or the panic handler.
fn crashForTest(kind: c.LPARAM) noreturn {
    // No "murrtty has stopped working" from Windows Error Reporting.
    _ = c.SetErrorMode(c.SEM_FAILCRITICALERRORS | c.SEM_NOGPFAULTERRORBOX);
    if (kind == 1) @panic("murrtty test panic (roadmap 7.5)");
    const p: *volatile u8 = @ptrFromInt(0x10);
    p.* = 1;
    unreachable;
}

/// Whether the hooks are on, for code with no App at hand.
var on = false;

/// The rows a wheel notch scrolls in place of Windows' setting
/// (GHOSTTY_WIN32_TEST_WHEEL_LINES: a number, or "page"; roadmap 6.5).
var wheel_lines: ?u32 = null;

pub fn wheelLines() ?u32 {
    if (comptime !enabled) return null;
    return wheel_lines;
}

fn wheelLinesFromEnv() ?u32 {
    var buf: [16]u16 = undefined;
    const n = c.GetEnvironmentVariableW(c.L("GHOSTTY_WIN32_TEST_WHEEL_LINES"), &buf, buf.len);
    if (n == 0 or n >= buf.len) return null;
    var ascii: [16]u8 = undefined;
    for (buf[0..n], ascii[0..n]) |unit, *a| a.* = if (unit < 0x80) @intCast(unit) else '?';
    if (std.mem.eql(u8, ascii[0..n], "page")) return c.WHEEL_PAGESCROLL;
    return std.fmt.parseInt(u32, ascii[0..n], 10) catch null;
}

/// Whether show_on_screen_keyboard only looks the input pane up.
pub fn recordsOsk(state: *const State) bool {
    if (comptime !enabled) return false;
    return state.msg != 0 and state.record_osk;
}

/// Record a show_on_screen_keyboard request's result.
pub fn recordOsk(state: *State, hr: i32, done: bool) void {
    if (comptime !enabled) return;
    if (state.msg == 0) return;
    state.osk_asks += 1;
    state.osk_hr = hr;
    state.osk_done = done;
}

pub fn active() bool {
    if (comptime !enabled) return false;
    return on;
}

/// Turn the hooks on if GHOSTTY_WIN32_TEST_DUMP is set.
pub fn init(alloc: Allocator) State {
    if (comptime !enabled) return .{};
    const name = c.L("GHOSTTY_WIN32_TEST_DUMP");
    const len = c.GetEnvironmentVariableW(name, null, 0);
    if (len == 0) return .{};
    const path = alloc.allocSentinel(u16, len - 1, 0) catch return .{};
    if (c.GetEnvironmentVariableW(name, path.ptr, len) != len - 1) {
        alloc.free(path);
        return .{};
    }
    log.warn("test hooks enabled", .{});
    on = true;
    wheel_lines = wheelLinesFromEnv();
    return .{
        .msg = c.RegisterWindowMessageW(c.L("GhosttyWin32TestDump")),
        .path = path,
        .record_launches = c.GetEnvironmentVariableW(c.L("GHOSTTY_WIN32_TEST_LAUNCH"), null, 0) == 0,
        .record_notifications = c.GetEnvironmentVariableW(c.L("GHOSTTY_WIN32_TEST_NOTIFY"), null, 0) == 0,
        .record_osk = c.GetEnvironmentVariableW(c.L("GHOSTTY_WIN32_TEST_OSK"), null, 0) == 0,
    };
}

/// Whether notifications are recorded instead of shown.
pub fn recordsNotifications(state: *const State) bool {
    if (comptime !enabled) return false;
    return state.msg != 0 and state.record_notifications;
}

/// Record a notification as it shows (its title and body as UTF-16, cut).
pub fn recordNotification(state: *State, alloc: Allocator, surface: ?u64, title: []const u16, body: []const u16) void {
    if (comptime !enabled) return;
    if (state.msg == 0) return;
    const t = std.unicode.utf16LeToUtf8Alloc(alloc, title) catch return;
    const b = std.unicode.utf16LeToUtf8Alloc(alloc, body) catch {
        alloc.free(t);
        return;
    };
    state.notifications.append(alloc, .{ .surface = surface orelse 0, .title = t, .body = b }) catch {
        alloc.free(t);
        alloc.free(b);
    };
}

pub fn deinit(state: *State, alloc: Allocator) void {
    if (comptime !enabled) return;
    if (state.path) |p| alloc.free(p);
    state.path = null;
    for (state.launches.items) |l| alloc.free(l);
    state.launches.deinit(alloc);
    for (state.notifications.items) |n| {
        alloc.free(n.title);
        alloc.free(n.body);
    }
    state.notifications.deinit(alloc);
    state.overlays.deinit(alloc);
}

/// Record a task dialog's heading and body as it shows (cut to fit).
pub fn recordDialog(state: *State, heading: []const u8, body: []const u8) void {
    if (comptime !enabled) return;
    state.dialog_heading_len = @min(heading.len, state.dialog_heading.len);
    @memcpy(state.dialog_heading[0..state.dialog_heading_len], heading[0..state.dialog_heading_len]);
    state.dialog_body_len = @min(body.len, state.dialog_body.len);
    @memcpy(state.dialog_body[0..state.dialog_body_len], body[0..state.dialog_body_len]);
}

/// Record a launch instead of performing it, if the hooks are on. Returns
/// whether it was taken.
pub fn recordLaunch(state: *State, alloc: Allocator, verb: []const u8, target: []const u8) bool {
    if (comptime !enabled) return false;
    if (state.msg == 0 or !state.record_launches) return false;
    const entry = std.fmt.allocPrint(alloc, "{s} {s}", .{ verb, target }) catch return true;
    state.launches.append(alloc, entry) catch alloc.free(entry);
    return true;
}

/// Whether `msg` is the dump request.
pub fn isDump(state: *const State, msg: c.UINT) bool {
    if (comptime !enabled) return false;
    return state.msg != 0 and msg == state.msg;
}

/// Write the app's state to the dump file. Returns 1 on success. First,
/// with `wparam`:
/// - 1: ask every surface's renderer to read back the pixel at `lparam`
///   (x in the low word, y in the high word, client pixels from the top
///   left) from the frames it presents next ("probe").
/// - 2: act as if the system's light/dark setting changed to dark
///   (`lparam` 1) or light (0), without touching the user's setting.
/// - 3 (posted, not sent): no dump; signal the event
///   Local\GhosttyGuiSync-<pid>. Posted after input, it is handled after
///   that input too, so the harness knows when Ghostty has read the
///   modifier state it set.
/// - 4: replace spike S1's overlays (see setOverlays): none (`lparam` 0),
///   or one per pane as a sibling of the surface (1), a child of it (2) or
///   a layered child of it (3).
/// - 6: every pane's renderer failed (`lparam` 1) or recovered (0), through
///   the core's renderer_health action.
/// - 7: panes ignore WM_MOUSELEAVE (`lparam` 1) or act on it (0).
/// - 8: Windows' "Always show scrollbars" on (`lparam` 1) or off (0).
/// - 10: ask every pane's renderer for the whole frame it presents next
///   (each pane's `frame_ready` reports it read).
/// - 11: write the frames read as `frame-<n>.bmp` beside the dump file, n
///   counting the panes window by window, tab by tab.
/// - 12: paint each window's chrome (header bar and tab row) into a bitmap
///   and write it as `chrome-<n>.bmp` beside the dump file, and its active
///   tab's container (the dividers) as `tab-<n>.bmp`: what WM_PAINT draws,
///   alpha included, where captures can't see it (the hidden desktop).
/// - 13: blur with the accent policy whatever Windows' build (`lparam` 1),
///   with Acrylic even while inactive (2), or as the build says (0).
/// - 14: resize each window by its bottom right corner as a drag would,
///   WM_SIZING first: `lparam` holds dx (low word) and dy (high), signed.
/// - 15: click the latest desktop notification, as its toast's click
///   does (NIN_BALLOONUSERCLICK; `lparam` 0), or take it back without
///   presenting its pane (1), which would take the foreground.
/// - 16: toggle_visibility takes murrtty as in front (`lparam` 1), as not
///   (2), or asks Windows (0).
/// - 17: drop what the clipboard holds on the first window's active pane,
///   through its drop target (DragEnter, then Drop): OLE wraps the
///   clipboard as the data object a drag would bring (roadmap 5.8).
/// - 21 (posted, not sent): crash on purpose (roadmap 7.5), with Windows'
///   error dialog off: an access violation on the UI thread (`lparam` 0),
///   or a Zig panic (1).
/// - 22: open the configuration editor (roadmap F1), or bring it forward.
/// - 23: paint the configuration editor's top bar and page as WM_PAINT does
///   and write them as `editor-bar-0.bmp` and `editor-list-0.bmp` beside
///   the dump file.
/// (5 was spike S2's transparency switch, now background-opacity itself;
/// 9 is the perf-trace branch's.)
pub fn dump(app: *App, wparam: c.WPARAM, lparam: c.LPARAM) c.LRESULT {
    if (comptime !enabled) return 0;
    if (wparam == 21) crashForTest(lparam);
    if (wparam == 3) {
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "Local\\GhosttyGuiSync-{d}", .{c.GetCurrentProcessId()}) catch return 0;
        var name_w: [64:0]u16 = undefined;
        const len = std.unicode.utf8ToUtf16Le(&name_w, name) catch return 0;
        name_w[len] = 0;
        const event = c.OpenEventW(c.EVENT_MODIFY_STATE, c.FALSE, &name_w) orelse return 0;
        defer _ = c.CloseHandle(event);
        _ = c.SetEvent(event);
        return 1;
    }
    const alloc = app.core_app.alloc;
    if (wparam == 2) app.setSystemDark(lparam != 0);
    if (wparam == 7) app.test_state.pin_mouse = lparam != 0;
    // As if every renderer failed (lparam 1) or recovered (0): the renderer
    // panel (roadmap 3.6), which no test can bring about for real. Through
    // the core's action, as the renderer's report comes.
    if (wparam == 6) for (app.windows.items) |w| {
        var it = w.panes();
        while (it.next()) |s| {
            if (!s.core_initialized) continue;
            _ = app.performAction(.{ .surface = &s.core_surface }, .renderer_health, if (lparam != 0) .unhealthy else .healthy) catch {};
        }
    };
    // As if Windows' "Always show scrollbars" changed (lparam 1 on).
    if (wparam == 8) app.setScrollbarsAlways(lparam != 0);
    // Grow (or shrink) each window by its bottom right corner as a drag of
    // it would: WM_SIZING first (window-step-resize), then the size it
    // leaves. lparam: dx in the low word, dy in the high, signed.
    if (wparam == 14) for (app.windows.items) |w| {
        const bits: u32 = @truncate(@as(usize, @bitCast(lparam)));
        const dx: i16 = @bitCast(@as(u16, @truncate(bits)));
        const dy: i16 = @bitCast(@as(u16, @truncate(bits >> 16)));
        var r: c.RECT = .{};
        _ = c.GetWindowRect(w.hwnd, &r);
        r.right += dx;
        r.bottom += dy;
        _ = c.SendMessageW(w.hwnd, c.WM_SIZING, c.WMSZ_BOTTOMRIGHT, @bitCast(@intFromPtr(&r)));
        _ = c.SetWindowPos(w.hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
    };
    // The accent policy's blur whatever the build (lparam 1), Acrylic even
    // while inactive (2), or the build's own (0); the windows switch at
    // once.
    if (wparam == 13) {
        app.test_state.force_blur = switch (lparam) {
            1 => .accent,
            2 => .acrylic,
            else => .none,
        };
        for (app.windows.items) |w| w.syncBlur();
    }
    if (wparam == 4) setOverlays(app, std.enums.fromInt(OverlayKind, lparam));
    // Hide the touch keyboard for the first window (roadmap 6.5), after a
    // test asked for it.
    if (wparam == 20) if (app.windows.items.len > 0) {
        const r = @import("input_pane.zig").request(app.windows.items[0].hwnd, .hide);
        recordOsk(&app.test_state, r.hr, r.done);
    };
    if (wparam == 17) {
        app.test_state.drop_effect = -1;
        if (app.windows.items.len > 0) if (app.windows.items[0].activeSurface()) |s| if (s.drop_target) |d| {
            // OLE's clipboard object reads the clipboard as DragEnter asks
            // for its formats, so another program holding it then (a
            // clipboard manager reading what the harness just put there)
            // made a text drop read as refused on the desktop CI
            // (2026-10-28). A real drag's data object is the source's own.
            // Wait for the clipboard to be free, and try again after a
            // refusal (a drop with nothing to take still ends refused).
            for (0..3) |attempt| {
                if (attempt > 0) c.Sleep(50);
                for (0..20) |_| {
                    if (c.OpenClipboard(null) != 0) {
                        _ = c.CloseClipboard();
                        break;
                    }
                    c.Sleep(10);
                }
                var obj: ?*anyopaque = null;
                if (c.OleGetClipboard(&obj) >= 0) if (obj) |o| {
                    const data: *DropTarget.DataObject = @ptrCast(@alignCast(o));
                    defer data.release();
                    app.test_state.drop_effect = @intCast(d.simulate(data));
                };
                if (app.test_state.drop_effect > 0) break;
            }
        };
    }
    // The inspector's export (roadmap 5.12) of the first window's active
    // pane, as its Export button asks: through the action, as the core
    // calls it (GHOSTTY_WIN32_TEST_EXPORT names the file).
    if (wparam == 18) if (app.windows.items.len > 0) if (app.windows.items[0].activeSurface()) |s| if (s.core_initialized) {
        _ = app.performAction(.{ .surface = &s.core_surface }, .export_terminal_io, .{ .contents = "Seq\tKind\tDescription\n1\tpty\ttest-export\n" }) catch {};
    };
    if (wparam == 16) app.test_state.in_front = switch (lparam) {
        1 => .yes,
        2 => .no,
        else => .real,
    };
    if (wparam == 15) if (app.notifications.hwnd) |hwnd| {
        if (lparam == 0) {
            _ = c.SendMessageW(hwnd, Notifications.WM_ICON, 0, c.NIN_BALLOONUSERCLICK);
        } else app.notifications.withdraw();
    };
    if (wparam == 1) {
        const point: u32 = @truncate(@as(usize, @bitCast(lparam)));
        for (app.windows.items) |w| {
            var it = w.panes();
            while (it.next()) |s| {
                if (!s.core_initialized) continue;
                const state = &s.core_surface.renderer.api.wgl_state;
                state.probe.store(0, .monotonic);
                state.probe_point.store(point, .monotonic);
                redraw(s);
            }
        }
    }
    if (wparam == 10) for (app.windows.items) |w| {
        var it = w.panes();
        while (it.next()) |s| {
            if (!s.core_initialized) continue;
            const state = &s.core_surface.renderer.api.wgl_state;
            // A frame read is the UI thread's to free; one still asked for
            // is the render thread's to write.
            if (state.frame_ready.swap(false, .acquire)) {
                std.heap.page_allocator.free(state.frame);
                state.frame = &.{};
            }
            state.frame_wanted.store(true, .release);
            redraw(s);
        }
    };
    if (wparam == 11) saveFrames(app);
    // A GPU driver reset (roadmap 6.3), faked for each pane: its renderer
    // takes its context as lost at the next frame and builds itself again
    // in a new one, as after a real reset.
    if (wparam == 19) for (app.windows.items) |w| {
        var it = w.panes();
        while (it.next()) |s| {
            if (!s.core_initialized) continue;
            s.core_surface.renderer.api.wgl_state.fake_reset.store(true, .release);
            redraw(s);
        }
    };
    if (wparam == 12) saveChrome(app);
    if (wparam == 22) app.openConfigEditor();
    // The history's garbage collector now (roadmap 5.10b), not in minutes.
    if (wparam == 24) app.session.collectGarbage();
    if (wparam == 23) if (app.config_editor) |editor| {
        var client: c.RECT = .{};
        _ = c.GetClientRect(editor.hwnd, &client);
        savePaint(app, "editor-bar", 0, client.right, client.bottom, editor, @import("ConfigEditor.zig").paintBarTo);
        const list = editor.listSize();
        savePaint(app, "editor-list", 0, list.right, list.bottom, editor, @import("ConfigEditor.zig").paintListTo);
    };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    write(app, alloc, &out) catch |err| {
        log.err("test dump failed err={}", .{err});
        return 0;
    };

    const path = app.test_state.path orelse return 0;
    const file = c.CreateFileW(path, c.GENERIC_WRITE, 0, null, c.CREATE_ALWAYS, c.FILE_ATTRIBUTE_NORMAL, null);
    if (file == c.INVALID_HANDLE_VALUE) return 0;
    defer _ = c.CloseHandle(file);
    var written: c.DWORD = 0;
    if (c.WriteFile(file, out.items.ptr, @intCast(out.items.len), &written, null) == 0) return 0;
    return if (written == out.items.len) 1 else 0;
}

fn write(app: *App, alloc: Allocator, out: *std.ArrayList(u8)) !void {
    const ts = &app.test_state;
    try out.print(alloc, "{{\"modal_depth\":{d},\"menus_shown\":{d},\"dialog\":{{\"heading\":", .{ app.modal_depth, ts.menus_shown });
    try writeString(alloc, out, ts.dialog_heading[0..ts.dialog_heading_len]);
    try out.appendSlice(alloc, ",\"body\":");
    try writeString(alloc, out, ts.dialog_body[0..ts.dialog_body_len]);
    try out.appendSlice(alloc, "},\"windows\":[");
    for (app.windows.items, 0..) |w, wi| {
        if (wi > 0) try out.append(alloc, ',');
        var client: c.RECT = .{};
        _ = c.GetClientRect(w.hwnd, &client);
        try out.print(alloc, "{{\"id\":{d},\"hwnd\":{d},\"enabled\":{},\"active\":{d},\"client\":[{d},{d}],", .{
            w.id,
            @intFromPtr(w.hwnd),
            c.IsWindowEnabled(w.hwnd) != 0,
            w.active,
            client.right,
            client.bottom,
        });
        // The title bar as applyChrome set it; the caption as 0xRRGGBB,
        // or -1 for the system's.
        const caption: i64 = if (w.chrome.caption) |ref| rgbOf(ref) else -1;
        try out.print(alloc, "\"chrome\":{{\"dark\":{},\"caption\":{d}}},", .{ w.chrome.dark, caption });
        try out.print(alloc, "\"translucent\":{},", .{w.translucent});
        try out.print(alloc, "\"decoration\":\"{t}\",\"captionless\":{},", .{ w.decoration(), w.captionless() });
        try out.print(alloc, "\"active_window\":{},\"floating\":{},\"topmost\":{},", .{ w.active_window, w.floating, w.isTopmost() });
        // Where it is, whether it is shown, and the quick terminal's state
        // (roadmap 5.7): shown, sliding, the work area and DPI it chose.
        {
            var r: c.RECT = .{};
            _ = c.GetWindowRect(w.hwnd, &r);
            const ex = c.GetWindowLongPtrW(w.hwnd, c.GWL_EXSTYLE);
            try out.print(alloc, "\"rect\":[{d},{d},{d},{d}],\"visible\":{},\"toolwindow\":{},", .{ r.left, r.top, r.right, r.bottom, c.IsWindowVisible(w.hwnd) != 0, ex & c.WS_EX_TOOLWINDOW != 0 });
            if (w.quick) |q| {
                try out.print(alloc, "\"quick\":{{\"shown\":{},\"sliding\":{},\"lowered\":{},\"work\":[{d},{d},{d},{d}],\"dpi\":{d}}},", .{ q.shown, q.slide != null, q.lowered, q.work.left, q.work.top, q.work.right, q.work.bottom, q.dpi });
            } else try out.appendSlice(alloc, "\"quick\":null,");
        }
        // Its taskbar button's progress (roadmap 5.4), shown once ready.
        try out.print(alloc, "\"taskbar\":{{\"state\":\"{t}\",\"value\":{d},\"ready\":{},\"hr\":{d}}},", .{
            w.taskbar_progress.state,
            w.taskbar_progress.value,
            w.taskbar_ready,
            w.taskbar_hr,
        });
        // The blur applied, and the system backdrop DWM reports (-1 when it
        // can't say, before Windows 11 22H2).
        var backdrop: c.DWORD = 0;
        const backdrop_type: i64 = if (c.DwmGetWindowAttribute(w.hwnd, c.DWMWA_SYSTEMBACKDROP_TYPE, &backdrop, @sizeOf(c.DWORD)) >= 0) backdrop else -1;
        try out.print(alloc, "\"blur\":\"{t}\",\"backdrop_type\":{d},", .{ w.blur, backdrop_type });
        // The caption's text, and the user's name for the window ("" for
        // none).
        {
            var wide: [512]u16 = undefined;
            const n: usize = @intCast(@max(c.GetWindowTextW(w.hwnd, &wide, wide.len), 0));
            // A long title may be cut inside a surrogate pair.
            const text = std.unicode.utf16LeToUtf8Alloc(alloc, wide[0..n]) catch try alloc.dupe(u8, "?");
            defer alloc.free(text);
            try out.appendSlice(alloc, "\"caption\":");
            try writeString(alloc, out, text);
            try out.appendSlice(alloc, ",\"window_name\":");
            try writeString(alloc, out, w.title_override orelse "");
            // The toast showing, "" for none.
            const toast = try std.unicode.utf16LeToUtf8Alloc(alloc, w.toastText());
            defer alloc.free(toast);
            try out.appendSlice(alloc, ",\"toast\":");
            try writeString(alloc, out, toast);
            try out.append(alloc, ',');
        }

        // The command palette: open, whether it has the keyboard, its
        // windows (to type into and click), a row's height, the filter's
        // text, the listed titles (best match first) with the lines beneath
        // them, and the selected row.
        {
            const p = &w.palette;
            var text_buf: [1024]u8 = undefined;
            const selected: i64 = if (p.selected()) |s| @intCast(s) else -1;
            try out.print(alloc, "\"palette\":{{\"open\":{},\"focused\":{},\"edit\":{d},\"list\":{d},\"dim\":{d},\"row_height\":{d},\"selected\":{d},\"text\":", .{
                p.isOpen(),
                p.ownsFocus(),
                if (p.edit) |e| @intFromPtr(e) else 0,
                if (p.list) |l| @intFromPtr(l) else 0,
                if (p.dim) |d| @intFromPtr(d) else 0,
                p.rowHeight(),
                selected,
            });
            try writeString(alloc, out, p.filterText(&text_buf));
            try out.appendSlice(alloc, ",\"items\":[");
            for (0..p.shownCount()) |i| {
                if (i > 0) try out.append(alloc, ',');
                try writeString(alloc, out, p.shownTitle(i));
            }
            try out.appendSlice(alloc, "],\"details\":[");
            for (0..p.shownCount()) |i| {
                if (i > 0) try out.append(alloc, ',');
                try writeString(alloc, out, p.shownDetail(i));
            }
            try out.appendSlice(alloc, "]},");
        }

        // The icons' widths at the window's DPI, and whether the strip has
        // its tooltip.
        try out.print(alloc, "\"icon_widths\":[{d},{d}],\"has_tooltip\":{},", .{
            w.icon_widths[0],
            w.icon_widths[1],
            w.tooltip != null,
        });

        // The header bar (client-side decorations): its height, its title's
        // font, "+"'s tooltip, its buttons in client coordinates.
        var face_buf: [128]u8 = undefined;
        {
            const p = w.header.place(client.right);
            try out.print(alloc, "\"header\":{{\"visible\":{},\"in_row\":{},\"height\":{d},\"font\":", .{
                w.headerHeight() > 0,
                w.tabsTitlebar() and w.tabBarVisible(),
                w.headerHeight(),
            });
            try writeString(alloc, out, draw.faceName(w.header.title_font, &face_buf));
            const tip = try w.tooltipText(alloc, .new_tab);
            defer alloc.free(tip);
            try out.appendSlice(alloc, ",\"new_tab_tooltip\":");
            try writeString(alloc, out, tip);
            inline for (.{ "new_tab", "new_tab_menu", "list", "menu", "minimize", "maximize", "window_close" }) |name| {
                const r = @field(p, name);
                try out.print(alloc, ",\"" ++ name ++ "\":[{d},{d},{d},{d}]", .{ r.left, r.top, r.right, r.bottom });
            }
            // The waiting panes' bells as hit-tested (Waiting): each one's
            // pane, its rectangle, whether it stands for the rest, its
            // tooltip; and the title's painted width.
            const bells = w.header.bellPlace(client.right);
            const title_at = w.header.titleAt(client.right, true) orelse .{ 0, 0 };
            const title_alone = w.header.titleAt(client.right, false) orelse .{ 0, 0 };
            try out.print(alloc, ",\"title_px\":{d},\"title_at\":[{d},{d}],\"title_alone\":[{d},{d}],\"bells\":[", .{
                w.header.title_px,
                title_at[0],
                title_at[1],
                title_alone[0],
                title_alone[1],
            });
            for (0..bells.shown) |i| {
                if (i > 0) try out.append(alloc, ',');
                const r = bells.rect(i, p.new_tab.top, p.new_tab.bottom);
                const id = if (i < app.waiting.list.items.len) app.waiting.list.items[i].surface else 0;
                try out.print(alloc, "{{\"surface\":{d},\"rect\":[{d},{d},{d},{d}],\"more\":{},\"tooltip\":", .{
                    id,
                    r.left,
                    r.top,
                    r.right,
                    r.bottom,
                    bells.isMore(i),
                });
                const bell_tip = try w.tooltipText(alloc, .{ .bell = i });
                defer alloc.free(bell_tip);
                try writeString(alloc, out, bell_tip);
                try out.append(alloc, '}');
            }
            try out.appendSlice(alloc, "]},");
        }

        // The tab row's geometry in client coordinates, for clicks; every
        // tab's tooltip; the row's font.
        const n = w.tabs.items.len;
        const top = w.headerHeight();
        try out.print(alloc, "\"tab_bar\":{{\"visible\":{},\"tabs_shown\":{},\"top\":{d},\"height\":{d},\"font\":", .{
            w.tabBarVisible(),
            w.tabBarVisible(),
            top,
            w.tab_bar.height(),
        });
        try writeString(alloc, out, w.tab_bar.faceName(&face_buf));
        try out.appendSlice(alloc, ",\"tabs\":[");
        for (0..n) |i| {
            if (i > 0) try out.append(alloc, ',');
            const in_row = w.tab_bar.tabRect(i, n, client.right);
            const r = below(in_row, top);
            const x = below(w.tab_bar.closeRect(in_row), top);
            try out.print(alloc, "{{\"rect\":[{d},{d},{d},{d}],\"close\":[{d},{d},{d},{d}],\"tooltip\":", .{
                r.left, r.top, r.right, r.bottom, x.left, x.top, x.right, x.bottom,
            });
            const tip = try w.tooltipText(alloc, .{ .tab = i });
            defer alloc.free(tip);
            try writeString(alloc, out, tip);
            try out.append(alloc, '}');
        }
        const sl = below(w.tab_bar.scrollLeftRect(n, client.right), top);
        const sr = below(w.tab_bar.scrollRightRect(n, client.right), top);
        const view = w.tab_bar.viewRect(n, client.right);
        // An overflowing row's chevrons, the span tabs show in, the scroll.
        try out.print(alloc, "],\"overflow\":{},\"scroll_left\":[{d},{d},{d},{d}],\"scroll_right\":[{d},{d},{d},{d}],\"view\":[{d},{d}],\"scroll\":{d}}},\"tabs\":[", .{
            w.tab_bar.overflowing(n, client.right),
            sl.left,
            sl.top,
            sl.right,
            sl.bottom,
            sr.left,
            sr.top,
            sr.right,
            sr.bottom,
            view.left,
            view.right,
            w.tab_bar.scroll,
        });

        // Each tab as its focused pane.
        for (w.tabs.items, 0..) |tab, si| {
            const s = tab.focused;
            if (si > 0) try out.append(alloc, ',');
            try out.print(alloc, "{{\"hwnd\":{d},\"visible\":{},\"title\":", .{
                @intFromPtr(s.hwnd),
                c.IsWindowVisible(s.hwnd) != 0,
            });
            try writeString(alloc, out, s.title orelse "");
            // What the tab shows, and the user's names for the tab and its
            // focused pane ("" for none).
            const label = try tab.label(alloc);
            defer alloc.free(label);
            try out.appendSlice(alloc, ",\"label\":");
            try writeString(alloc, out, label);
            // The bell (roadmap 3.7a): ringing in the focused pane, and the
            // tab's mark for a bell while it was in the background; and
            // what the tab bar last painted of them.
            const bit = if (si < 64) @as(u64, 1) << @intCast(si) else 0;
            try out.print(alloc, ",\"bell\":{},\"attention\":{},\"painted_bell\":{},\"painted_attention\":{}", .{
                s.bell_ringing,
                tab.attention,
                w.painted_bell & bit != 0,
                w.painted_attention & bit != 0,
            });
            try out.appendSlice(alloc, ",\"tab_name\":");
            try writeString(alloc, out, tab.title_override orelse "");
            try out.appendSlice(alloc, ",\"pane_name\":");
            try writeString(alloc, out, s.title_override orelse "");
            if (s.core_initialized) {
                // Cell size and padding in pixels, to click on a cell.
                const size = s.core_surface.size;
                const grid = size.grid();
                // The last presented frame's pixel near the bottom-right
                // corner (see OpenGL.Wgl.sample).
                const wgl_state = &s.core_surface.renderer.api.wgl_state;
                try out.print(alloc, ",\"scheme\":\"{t}\"", .{s.core_surface.config_conditional_state.theme});
                // Whether the core surface thinks it has the focus.
                try out.print(alloc, ",\"focused\":{}", .{s.core_surface.focused});
                try out.print(alloc, ",\"cols\":{d},\"rows\":{d},\"cell\":[{d},{d}],\"padding\":[{d},{d}],\"pixel\":{d},\"probe\":{d},\"frames\":{d},\"text\":", .{
                    grid.columns,
                    grid.rows,
                    size.cell.width,
                    size.cell.height,
                    size.padding.left,
                    size.padding.top,
                    wgl_state.sample.load(.monotonic),
                    wgl_state.probe.load(.monotonic),
                    wgl_state.frames.load(.monotonic),
                });
                const text = text: {
                    s.core_surface.renderer_state.mutex.lockUncancelable(global.io());
                    defer s.core_surface.renderer_state.mutex.unlock(global.io());
                    break :text try s.core_surface.io.terminal.plainString(alloc);
                };
                defer alloc.free(text);
                try writeString(alloc, out, text);
            }
            try writePanes(alloc, out, tab);
            try out.append(alloc, '}');
        }
        try out.appendSlice(alloc, "]}");
    }
    try out.appendSlice(alloc, "],\"launches\":[");
    for (app.test_state.launches.items, 0..) |l, i| {
        if (i > 0) try out.append(alloc, ',');
        try writeString(alloc, out, l);
    }
    try out.appendSlice(alloc, "],\"overlays\":[");
    for (app.test_state.overlays.items, 0..) |o, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.print(alloc, "{{\"kind\":{d},\"hwnd\":{d},\"surface\":{d},\"paints\":{d}}}", .{
            @intFromEnum(o.kind),
            @intFromPtr(o.hwnd),
            @intFromPtr(o.surface),
            o.paints,
        });
    }
    // The single instance's pipe (roadmap 5.1).
    try out.appendSlice(alloc, "],\"ipc\":{\"pipe\":");
    if (app.ipc_server) |s| {
        try writeString(alloc, out, s.name_utf8);
        try out.print(alloc, ",\"listening\":{},\"received\":{d},\"launch\":{}}}", .{
            s.listening.load(.acquire),
            s.received.load(.monotonic),
            app.ipc_launch,
        });
    } else try out.print(alloc, "\"\",\"listening\":false,\"received\":0,\"launch\":{}}}", .{app.ipc_launch});
    // Desktop notifications (roadmap 5.2): those sent, and whether the
    // icon standing for the latest is there.
    try out.appendSlice(alloc, ",\"notifications\":[");
    for (app.test_state.notifications.items, 0..) |n, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.print(alloc, "{{\"surface\":{d},\"title\":", .{n.surface});
        try writeString(alloc, out, n.title);
        try out.appendSlice(alloc, ",\"body\":");
        try writeString(alloc, out, n.body);
        try out.append(alloc, '}');
    }
    try out.print(alloc, "],\"notify_icon\":{},\"notify_pending\":{},\"notify_surface\":{d}", .{
        app.notifications.shown,
        app.notifications.pending,
        app.notifications.surface orelse 0,
    });
    // The panes waiting for their user, oldest first (the header bars'
    // bells).
    try out.appendSlice(alloc, ",\"waiting\":[");
    for (app.waiting.list.items, 0..) |e, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.print(alloc, "{d}", .{e.surface});
    }
    try out.append(alloc, ']');
    // The tray and what keeps murrtty running (roadmap 5.6).
    try out.print(alloc, ",\"tray\":{},\"quit_timer\":\"{t}\",\"requested_window\":{}", .{
        app.notifications.tray,
        app.quit_timer,
        app.requested_window,
    });
    // Global bindings' hot keys (roadmap 5.5): each trigger as menus write
    // it, with the MOD_* and virtual key WM_HOTKEY reports it by; whether
    // toggle_visibility hid the windows, and which; hot keys waiting for a
    // dialog to close.
    try out.appendSlice(alloc, ",\"globals\":[");
    for (app.global_keys.bound.items, 0..) |b, i| {
        if (i > 0) try out.append(alloc, ',');
        var buf: [96]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        ContextMenu.writeTrigger(&w, b.trigger) catch {};
        try out.appendSlice(alloc, "{\"trigger\":");
        try writeString(alloc, out, w.buffered());
        try out.print(alloc, ",\"mods\":{d},\"vk\":{d}}}", .{ b.mods, b.vk });
    }
    try out.print(alloc, "],\"windows_hidden\":{},\"hidden_windows\":[", .{app.windows_hidden});
    for (app.hidden_windows.items, 0..) |id, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.print(alloc, "{d}", .{id});
    }
    try out.print(alloc, "],\"hidden_front\":{d},\"last_window\":{d},\"hotkeys_pending\":{d},\"globals_waiting\":{d},\"toggles\":{d},\"global_refreshes\":{d}", .{
        app.hidden_front orelse 0,
        app.last_window orelse 0,
        app.global_keys.pending.items.len,
        app.global_keys.waiting.items.len,
        app.test_state.toggles,
        app.test_state.global_refreshes,
    });
    try out.print(alloc, ",\"drop_effect\":{d}", .{app.test_state.drop_effect});
    try out.print(alloc, ",\"sentry_ready\":{}", .{@import("../../crash/main.zig").sentry.ready()});
    try out.print(alloc, ",\"osk\":{{\"asks\":{d},\"hr\":{d},\"done\":{}}},\"click_interval\":{d}", .{
        app.test_state.osk_asks,
        app.test_state.osk_hr,
        app.test_state.osk_done,
        app.config.@"click-repeat-interval",
    });
    // murrtty's selection clipboard (roadmap 5.9).
    try out.appendSlice(alloc, ",\"selection\":");
    try writeString(alloc, out, app.selection orelse "");
    // Undo's history (roadmap 5.11), oldest first, and the tabs parked.
    try out.appendSlice(alloc, ",\"undo\":{\"undo\":[");
    for (app.undo.entries(.undo), 0..) |e, i| try out.print(alloc, "{s}\"{s}\"", .{ if (i > 0) "," else "", @tagName(e.name) });
    try out.appendSlice(alloc, "],\"redo\":[");
    for (app.undo.entries(.redo), 0..) |e, i| try out.print(alloc, "{s}\"{s}\"", .{ if (i > 0) "," else "", @tagName(e.name) });
    try out.print(alloc, "],\"parked\":{d}}}", .{app.undo.parkedCount()});
    // A pane's drag (roadmap 1.10): its pane, the one under the pointer and
    // the side it would take.
    if (app.pane_drag) |d| {
        try out.print(alloc, ",\"pane_drag\":{{\"active\":true,\"dragging\":{},\"source\":{d},\"target\":{d},\"dir\":\"{s}\"}}", .{
            d.dragging,
            d.source,
            d.target orelse 0,
            if (d.target != null) @tagName(d.dir) else "",
        });
    }
    // The configuration editor (roadmap F1), while open.
    if (app.config_editor) |editor| {
        try out.appendSlice(alloc, ",\"config_editor\":");
        try editor.writeDump(alloc, out);
    } else try out.appendSlice(alloc, ",\"config_editor\":null");
    try out.append(alloc, '}');
}

/// A tab's panes in layout order (left to right, top to bottom, as the
/// tree nests them, the same while one is zoomed), where their windows
/// really are in the tab's container, and its dividers as the layout
/// places them.
fn writePanes(alloc: Allocator, out: *std.ArrayList(u8), tab: *Tab) !void {
    const area = tab.area();
    var layout = try Tab.Layout.compute(alloc, &tab.tree, area, tab.dividerWidth());
    defer layout.deinit(alloc);
    // The order without the zoom (a copy sharing the nodes).
    var unzoomed_tree = tab.tree;
    unzoomed_tree.zoomed = null;
    var order = try Tab.Layout.compute(alloc, &unzoomed_tree, area, tab.dividerWidth());
    defer order.deinit(alloc);
    // The dividers' color as last painted, 0xRRGGBB, or -1 before any.
    const divider_color: i64 = if (tab.painted_divider) |ref| rgbOf(ref) else -1;
    try out.print(alloc, ",\"zoomed\":{},\"area\":[{d},{d}],\"divider_color\":{d},\"panes\":[", .{
        tab.tree.zoomed != null,
        area.right,
        area.bottom,
        divider_color,
    });
    for (order.panes, 0..) |pane, i| {
        const s = pane.view;
        if (i > 0) try out.append(alloc, ',');
        var r: c.RECT = .{};
        _ = c.GetClientRect(s.hwnd, &r);
        var corners = [2]c.POINT{ .{ .x = r.left, .y = r.top }, .{ .x = r.right, .y = r.bottom } };
        _ = c.MapWindowPoints(s.hwnd, tab.hwnd, &corners, 2);
        // OSC 9;4's progress (roadmap 5.4): value -1 while it pulses.
        if (s.progress) |p| {
            try out.print(alloc, "{{\"progress\":{{\"value\":{d},\"err\":{},\"paused\":{},\"pulse\":{d:.2}}},", .{
                if (p.value) |v| @as(i32, v) else -1,
                s.progress_err,
                p.last == .paused,
                p.pulse,
            });
        } else try out.appendSlice(alloc, "{");
        // Its inspector (roadmap 5.12): the window, frames drawn, the core's
        // inspector on, and where ImGui has the mouse.
        if (s.inspector) |insp| {
            const pos = if (insp.ig) |ig| pos: {
                const cimgui = @import("dcimgui");
                // Put back: a dump is a sent message, which can come in the
                // middle of an inspector's frame.
                const prev = cimgui.c.ImGui_GetCurrentContext();
                defer cimgui.c.ImGui_SetCurrentContext(prev);
                cimgui.c.ImGui_SetCurrentContext(ig);
                const ig_io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
                break :pos ig_io.MousePos;
            } else @import("dcimgui").c.ImVec2{ .x = 0, .y = 0 };
            try out.print(alloc, "\"inspector\":{{\"hwnd\":{d},\"frames\":{d},\"mouse\":[{d:.0},{d:.0}]}},", .{
                @intFromPtr(insp.hwnd), insp.frames, pos.x, pos.y,
            });
        }
        try out.print(alloc, "\"inspector_active\":{},", .{s.core_initialized and s.core_surface.inspector != null});
        // What an IME asking (WM_IME_REQUEST, roadmap 6.2) is told: where
        // a composition's first character goes (screen pixels), its
        // line's height, the document (the pane, on screen), and the
        // candidate window's style and place (client pixels).
        {
            var pos: c.IMECHARPOSITION = .{ .dwCharPos = 0 };
            const answered = c.SendMessageW(s.hwnd, c.WM_IME_REQUEST, c.IMR_QUERYCHARPOSITION, @bitCast(@intFromPtr(&pos))) != 0;
            var cand: c.CANDIDATEFORM = .{ .dwIndex = 0, .dwStyle = 0, .ptCurrentPos = .{ .x = 0, .y = 0 } };
            _ = c.SendMessageW(s.hwnd, c.WM_IME_REQUEST, c.IMR_CANDIDATEWINDOW, @bitCast(@intFromPtr(&cand)));
            try out.print(alloc, "\"ime\":{{\"answered\":{},\"char\":[{d},{d}],\"line\":{d},\"doc\":[{d},{d},{d},{d}],\"cand\":[{d},{d},{d}]}},", .{
                answered,
                pos.pt.x,
                pos.pt.y,
                pos.cLineHeight,
                pos.rcDocument.left,
                pos.rcDocument.top,
                pos.rcDocument.right,
                pos.rcDocument.bottom,
                cand.dwStyle,
                cand.ptCurrentPos.x,
                cand.ptCurrentPos.y,
            });
        }
        try out.print(alloc, "\"handle\":{{\"shown\":{},\"hover\":{}}},\"drop\":\"{s}\",\"dimmed\":{},", .{
            s.handleShown(),
            s.handle_hover,
            if (s.drop_dir) |dir| @tagName(dir) else "",
            s.dim_color != null,
        });
        // Its picture's number for saveFrames (`frame-<n>.bmp`), which counts
        // every pane of every window in tree order, not this layout order.
        const frame_index = frame: {
            var n: usize = 0;
            for (tab.window.app.windows.items) |win| {
                var it = win.panes();
                while (it.next()) |p| : (n += 1) if (p == s) break :frame n;
            }
            break :frame n;
        };
        try out.print(alloc, "\"frame\":{d},", .{frame_index});
        try out.print(alloc, "\"drop_target\":{},\"hwnd\":{d},\"surface_id\":{d},\"rect\":[{d},{d},{d},{d}],\"focused\":{},\"visible\":{}", .{
            s.drop_target != null,
            @intFromPtr(s.hwnd),
            if (s.core_initialized) s.core_surface.id else 0,
            corners[0].x,
            corners[0].y,
            corners[1].x,
            corners[1].y,
            tab.focused == s,
            c.IsWindowVisible(s.hwnd) != 0,
        });
        // The resize overlay: whether it shows, and what.
        {
            const text16 = s.resize_overlay.textUtf16();
            const text = try std.unicode.utf16LeToUtf8Alloc(alloc, text16);
            defer alloc.free(text);
            try out.print(alloc, ",\"resize_overlay\":{{\"visible\":{},\"text\":", .{s.resize_overlay.visible()});
            try writeString(alloc, out, text);
            try out.append(alloc, '}');
        }
        // The search box: on, shown, its field (and the field's window, to
        // type into), the counter and whether it has the keyboard.
        {
            var text_buf: [1024]u8 = undefined;
            var counter_buf: [32]u8 = undefined;
            try out.print(alloc, ",\"search\":{{\"active\":{},\"visible\":{},\"edit\":{d},\"focused\":{},\"text\":", .{
                s.search.active,
                s.search.visible(),
                if (s.search.edit) |e| @intFromPtr(e) else 0,
                s.search.ownsFocus(),
            });
            try writeString(alloc, out, s.search.textUtf8(&text_buf));
            try out.appendSlice(alloc, ",\"counter\":");
            try writeString(alloc, out, s.search.counterText(&counter_buf));
            try out.append(alloc, '}');
        }
        // The scrollbar: the core's area (rows in all, the viewport's first
        // row and height), shown, widened over the band or pressed, its
        // opacity while fading, and the thumb's rectangle in the pane.
        {
            const sb = &s.scrollbar;
            const thumb: c.RECT = if (sb.geometry(s)) |g| g.thumb else .{};
            try out.print(alloc, ",\"scrollbar\":{{\"total\":{d},\"offset\":{d},\"len\":{d},\"visible\":{},\"hover\":{},\"pressed\":{},\"alpha\":{d:.2},\"thumb\":[{d},{d},{d},{d}]}}", .{
                sb.total,
                sb.offset,
                sb.len,
                sb.visible(),
                sb.hover,
                sb.pressed,
                sb.alpha,
                thumb.left,
                thumb.top,
                thumb.right,
                thumb.bottom,
            });
        }
        // The status overlays (roadmap 3.6): the link preview (its text,
        // "" when hidden, and whether it moved to the right), the read-only
        // badge, the key state's text, the renderer panel, the banner's
        // title ("" when hidden).
        {
            const link = try overlayText(alloc, &s.link_overlay);
            defer alloc.free(link);
            const keys = try overlayText(alloc, &s.key_overlay);
            defer alloc.free(keys);
            try out.appendSlice(alloc, ",\"status\":{\"link\":");
            try writeString(alloc, out, link);
            try out.print(alloc, ",\"link_right\":{},\"readonly\":{},\"keys\":", .{
                s.link_overlay.position == .@"bottom-right",
                s.readonlyShown(),
            });
            try writeString(alloc, out, keys);
            try out.print(alloc, ",\"health\":{},\"banner\":", .{s.health_overlay.visible()});
            try writeString(alloc, out, if (s.banner.visible()) s.banner.title() else "");
            try out.append(alloc, '}');
        }
        if (s.core_initialized) {
            const grid = s.core_surface.size.grid();
            const wgl_state = &s.core_surface.renderer.api.wgl_state;
            // Whether text is selected (hasSelection takes the terminal's lock).
            // The OpenGL contexts its renderer made (a new one after a
            // driver reset, roadmap 6.3) and whether its context reports
            // resets (robust).
            try out.print(alloc, ",\"gl_contexts\":{d},\"gl_robust\":{}", .{
                wgl_state.contexts.load(.monotonic),
                wgl_state.robust,
            });
            try out.print(alloc, ",\"core_focused\":{},\"selection\":{},\"frames\":{d},\"probe\":{d},\"frame_ready\":{},\"shade\":{d:.3},\"keys\":{d},\"cols\":{d},\"rows\":{d},\"text\":", .{
                s.core_surface.focused,
                s.core_surface.hasSelection(),
                wgl_state.frames.load(.monotonic),
                wgl_state.probe.load(.monotonic),
                wgl_state.frame_ready.load(.acquire),
                s.shade.alpha(s.shade_dpi, 0),
                s.keys_sent,
                grid.columns,
                grid.rows,
            });
            const text, const pwd, const marks, const cursor = text: {
                s.core_surface.renderer_state.mutex.lockUncancelable(global.io());
                defer s.core_surface.renderer_state.mutex.unlock(global.io());
                const terminal = &s.core_surface.io.terminal;
                const t = try terminal.plainString(alloc);
                errdefer alloc.free(t);
                const p = try alloc.dupe(u8, terminal.getPwd() orelse "");
                errdefer alloc.free(p);
                const cur = terminal.screens.active.cursor;
                break :text .{ t, p, try promptMarks(alloc, terminal), .{
                    cur.x,
                    cur.y,
                    @tagName(cur.semantic_content),
                    terminal.cursorIsAtPrompt(),
                } };
            };
            defer alloc.free(text);
            defer alloc.free(pwd);
            defer alloc.free(marks);
            try writeString(alloc, out, text);
            // The working directory as the shell last reported it (the
            // starting one until then).
            try out.appendSlice(alloc, ",\"pwd\":");
            try writeString(alloc, out, pwd);
            // Each visible row's prompt mark (OSC 133): "p" a prompt's
            // first row, "c" a continuation, "." none.
            try out.appendSlice(alloc, ",\"marks\":");
            try writeString(alloc, out, marks);
            // The cursor (column, row in the active area), its semantic
            // content and whether Ghostty takes it as at a prompt.
            try out.print(alloc, ",\"cursor\":[{d},{d}],\"semantic\":\"{s}\",\"at_prompt\":{}", .{
                cursor[0], cursor[1], cursor[2], cursor[3],
            });
            // Commands the shell reported finished, and the last exit code
            // (-1 for none, or none given).
            try out.print(alloc, ",\"commands\":{d},\"last_exit\":{d}", .{
                s.commands_finished,
                if (s.last_exit) |code| @as(i32, code) else -1,
            });
        }
        try out.append(alloc, '}');
    }
    try out.appendSlice(alloc, "],\"dividers\":[");
    for (layout.splits, 0..) |sp, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.print(alloc, "[{d},{d},{d},{d}]", .{ sp.divider.left, sp.divider.top, sp.divider.right, sp.divider.bottom });
    }
    try out.append(alloc, ']');
}

/// Write each frame the renderers read back (dump wparam 10) as a 32-bit
/// BMP, `frame-<n>.bmp` beside the dump file.
fn saveFrames(app: *App) void {
    const dump_path = app.test_state.path orelse return;
    const sep = std.mem.lastIndexOfScalar(u16, dump_path, '\\') orelse return;
    var n: usize = 0;
    for (app.windows.items) |w| {
        var it = w.panes();
        while (it.next()) |s| : (n += 1) {
            if (!s.core_initialized) continue;
            const state = &s.core_surface.renderer.api.wgl_state;
            if (!state.frame_ready.load(.acquire)) continue;
            var name_buf: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "frame-{d}.bmp", .{n}) catch continue;
            var path: [1024:0]u16 = undefined;
            if (sep + 1 + name.len >= path.len) continue;
            @memcpy(path[0 .. sep + 1], dump_path[0 .. sep + 1]);
            for (name, 0..) |ch, i| path[sep + 1 + i] = ch;
            path[sep + 1 + name.len] = 0;
            writeBmp(&path, state.frame, state.frame_width, state.frame_height);
        }
    }
}

/// Paint each window's chrome, and its active tab's container, into 32-bit
/// bitmaps and write them as `chrome-<n>.bmp` and `tab-<n>.bmp` beside the
/// dump file.
fn saveChrome(app: *App) void {
    for (app.windows.items, 0..) |w, n| {
        var client: c.RECT = .{};
        _ = c.GetClientRect(w.hwnd, &client);
        savePaint(app, "chrome", n, client.right, w.chromeHeight(), w, Window.paintTo);
        if (w.tabs.items.len == 0) continue;
        const tab = w.tabs.items[w.active];
        _ = c.GetClientRect(tab.hwnd, &client);
        savePaint(app, "tab", n, client.right, client.bottom, tab, Tab.paintTo);
    }
}

/// What `paint` draws into a `width` x `height` bitmap, as
/// `<prefix>-<n>.bmp` beside the dump file.
fn savePaint(
    app: *App,
    prefix: []const u8,
    n: usize,
    width: c_int,
    height: c_int,
    target: anytype,
    paint: fn (@TypeOf(target), c.HDC, c.RECT) void,
) void {
    const dump_path = app.test_state.path orelse return;
    const sep = std.mem.lastIndexOfScalar(u16, dump_path, '\\') orelse return;
    if (width <= 0 or height <= 0) return;
    const info: c.BITMAPINFOHEADER = .{ .biWidth = width, .biHeight = -height };
    var bits: ?[*]u8 = null;
    const screen = c.GetDC(null) orelse return;
    defer _ = c.ReleaseDC(null, screen);
    const bmp = c.CreateDIBSection(screen, &info, c.DIB_RGB_COLORS, &bits, null, 0) orelse return;
    defer _ = c.DeleteObject(bmp);
    const mem = c.CreateCompatibleDC(screen) orelse return;
    defer _ = c.DeleteDC(mem);
    const old = c.SelectObject(mem, bmp);
    defer _ = c.SelectObject(mem, old);
    paint(target, mem, .{ .left = 0, .top = 0, .right = width, .bottom = height });
    _ = c.GdiFlush();
    var name_buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s}-{d}.bmp", .{ prefix, n }) catch return;
    var path: [1024:0]u16 = undefined;
    if (sep + 1 + name.len >= path.len) return;
    @memcpy(path[0 .. sep + 1], dump_path[0 .. sep + 1]);
    for (name, 0..) |ch, i| path[sep + 1 + i] = ch;
    path[sep + 1 + name.len] = 0;
    const size: usize = @intCast(width * height * 4);
    writeBmp(&path, (bits orelse return)[0..size], @intCast(width), @intCast(height));
}

/// `pixels` (BGRA rows, top first) as a top-down 32-bit BMP at `path`.
fn writeBmp(path: [*:0]const u16, pixels: []const u8, width: u32, height: u32) void {
    var header: [54]u8 = @splat(0);
    header[0] = 'B';
    header[1] = 'M';
    std.mem.writeInt(u32, header[2..6], @intCast(header.len + pixels.len), .little);
    std.mem.writeInt(u32, header[10..14], header.len, .little);
    std.mem.writeInt(u32, header[14..18], 40, .little);
    std.mem.writeInt(i32, header[18..22], @intCast(width), .little);
    std.mem.writeInt(i32, header[22..26], -@as(i32, @intCast(height)), .little);
    std.mem.writeInt(u16, header[26..28], 1, .little);
    std.mem.writeInt(u16, header[28..30], 32, .little);
    const file = c.CreateFileW(path, c.GENERIC_WRITE, 0, null, c.CREATE_ALWAYS, c.FILE_ATTRIBUTE_NORMAL, null);
    if (file == c.INVALID_HANDLE_VALUE) return;
    defer _ = c.CloseHandle(file);
    var written: c.DWORD = 0;
    _ = c.WriteFile(file, &header, header.len, &written, null);
    _ = c.WriteFile(file, pixels.ptr, @intCast(pixels.len), &written, null);
}

/// Draw a new frame of the pane `s` soon. Nothing may have changed to cause
/// one, so this marks the whole screen dirty (as a modifier change does)
/// and wakes the renderer.
fn redraw(s: *Surface) void {
    const core = &s.core_surface;
    core.renderer_state.mutex.lockUncancelable(global.io());
    core.renderer_state.terminal.flags.dirty.clear = true;
    core.renderer_state.mutex.unlock(global.io());
    core.renderer_thread.wakeup.notify() catch {};
}

/// Spike S1 (roadmap): does a window drawn over a WGL surface stay clean
/// while output floods and the window resizes? One solid magenta overlay
/// per pane, 200 x 40 pixels at 20 from the pane's top-right corner (where
/// a search box goes), kept there as the pane moves and resizes.
const OverlayKind = enum(u8) {
    /// A child of the tab's container above the surface: its sibling.
    sibling = 1,
    /// A child of the surface.
    child = 2,
    /// A layered (WS_EX_LAYERED), fully opaque child of the surface.
    layered_child = 3,
};

const Overlay = struct {
    kind: OverlayKind,
    surface: c.HWND,
    hwnd: c.HWND,
    /// WM_PAINTs handled.
    paints: u32 = 0,
};

const overlay_class = c.L("MurrttyTestOverlay");
const overlay_width = 200;
const overlay_height = 40;
const overlay_margin = 20;

fn setOverlays(app: *App, kind: ?OverlayKind) void {
    const state = &app.test_state;
    for (state.overlays.items) |o| _ = c.DestroyWindow(o.hwnd);
    state.overlays.clearRetainingCapacity();
    const k = kind orelse return;
    if (!state.overlay_class) {
        const wc: c.WNDCLASSEXW = .{
            .lpfnWndProc = &overlayProc,
            .hInstance = app.instance,
            .lpszClassName = overlay_class,
        };
        if (c.RegisterClassExW(&wc) == 0) {
            log.err("overlay class not registered err={d}", .{c.GetLastError()});
            return;
        }
        state.overlay_class = true;
    }
    for (app.windows.items) |w| {
        var it = w.panes();
        while (it.next()) |s| {
            const parent = parent: {
                if (k != .sibling) break :parent s.hwnd;
                break :parent c.GetParent(s.hwnd) orelse continue;
            };
            const hwnd = c.CreateWindowExW(
                if (k == .layered_child) c.WS_EX_LAYERED else 0,
                overlay_class,
                c.L(""),
                c.WS_CHILD | c.WS_VISIBLE | c.WS_CLIPSIBLINGS,
                0,
                0,
                overlay_width,
                overlay_height,
                parent,
                null,
                app.instance,
                null,
            ) orelse {
                log.err("overlay not created kind={t} err={d}", .{ k, c.GetLastError() });
                continue;
            };
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(app)));
            // A layered window shows once its attributes are set.
            if (k == .layered_child) _ = c.SetLayeredWindowAttributes(hwnd, 0, 255, c.LWA_ALPHA);
            const o: Overlay = .{ .kind = k, .surface = s.hwnd, .hwnd = hwnd };
            state.overlays.append(app.core_app.alloc, o) catch {
                _ = c.DestroyWindow(hwnd);
                continue;
            };
            placeOverlay(o);
        }
    }
}

/// Keep the overlays of the pane `surface` at its top-right corner. The
/// surface calls this whenever it moves or resizes.
pub fn paneMoved(app: *App, surface: c.HWND) void {
    if (comptime !enabled) return;
    for (app.test_state.overlays.items) |o| {
        if (o.surface == surface) placeOverlay(o);
    }
}

fn placeOverlay(o: Overlay) void {
    var r: c.RECT = .{};
    _ = c.GetClientRect(o.surface, &r);
    var pt = [1]c.POINT{.{ .x = r.right - overlay_margin - overlay_width, .y = overlay_margin }};
    if (o.kind == .sibling) _ = c.MapWindowPoints(o.surface, c.GetParent(o.surface), &pt, 1);
    // A sibling goes on top (a null insert-after is HWND_TOP); the panes'
    // own moves leave the order alone (SWP_NOZORDER).
    const order: c.UINT = if (o.kind == .sibling) 0 else c.SWP_NOZORDER;
    _ = c.SetWindowPos(o.hwnd, null, pt[0].x, pt[0].y, overlay_width, overlay_height, c.SWP_NOACTIVATE | order);
}

fn overlayProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_ERASEBKGND => return 1,
        c.WM_NCHITTEST => return c.HTTRANSPARENT,
        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = undefined;
            const dc = c.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = c.EndPaint(hwnd, &ps);
            fillClient(hwnd, dc, c.rgb(255, 0, 255));
            const ptr: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA));
            if (ptr != 0) {
                const app: *App = @ptrFromInt(ptr);
                for (app.test_state.overlays.items) |*o| {
                    if (o.hwnd == hwnd) o.paints += 1;
                }
            }
            return 0;
        },
        // What PrintWindow gets when it asks the window to draw itself
        // instead of copying what DWM composed: green, so a capture taken
        // that way shows.
        c.WM_PRINTCLIENT => {
            if (wparam != 0) fillClient(hwnd, @ptrFromInt(wparam), c.rgb(0, 255, 0));
            return 0;
        },
        else => return c.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn fillClient(hwnd: c.HWND, dc: c.HDC, color: c.COLORREF) void {
    var r: c.RECT = .{};
    _ = c.GetClientRect(hwnd, &r);
    const brush = c.CreateSolidBrush(color) orelse return;
    defer _ = c.DeleteObject(brush);
    _ = c.FillRect(dc, &r, brush);
}

/// One character per row of the viewport: its semantic prompt mark.
/// `r`, in the tab row's coordinates, in the window's client area: `top`
/// down, below the header bar.
fn below(r: c.RECT, top: c_int) c.RECT {
    return .{ .left = r.left, .top = r.top + top, .right = r.right, .bottom = r.bottom + top };
}

fn promptMarks(alloc: Allocator, terminal: anytype) ![]u8 {
    var marks: std.ArrayList(u8) = .empty;
    errdefer marks.deinit(alloc);
    var it = terminal.screens.active.pages.rowIterator(.right_down, .{ .viewport = .{} }, null);
    while (it.next()) |pin| {
        try marks.append(alloc, switch (pin.rowAndCell().row.semantic_prompt) {
            .none => '.',
            .prompt => 'p',
            .prompt_continuation => 'c',
        });
    }
    return marks.toOwnedSlice(alloc);
}

/// An overlay's text as UTF-8, or "" while it is hidden.
fn overlayText(alloc: Allocator, o: anytype) ![]u8 {
    if (!o.visible()) return alloc.dupe(u8, "");
    return std.unicode.utf16LeToUtf8Alloc(alloc, o.textUtf16()) catch alloc.dupe(u8, "?");
}

/// A COLORREF (0x00BBGGRR) as 0xRRGGBB.
fn rgbOf(ref: c.COLORREF) i64 {
    return @as(i64, ref & 0xFF) << 16 | @as(i64, (ref >> 8) & 0xFF) << 8 | @as(i64, (ref >> 16) & 0xFF);
}

/// A JSON string literal. Each byte of invalid UTF-8 becomes U+FFFD: the
/// harness's std.json rejects invalid UTF-8, and a terminal title (repeated
/// in the command palette) can hold it.
pub fn writeString(alloc: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(alloc, '"');
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b >= 0x80) {
            const n = std.unicode.utf8ByteSequenceLength(b) catch 0;
            if (n > 0 and i + n <= s.len and std.unicode.utf8ValidateSlice(s[i .. i + n])) {
                try out.appendSlice(alloc, s[i .. i + n]);
                i += n;
            } else {
                try out.appendSlice(alloc, "\u{FFFD}");
                i += 1;
            }
            continue;
        }
        switch (b) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            0...8, 11, 12, 14...0x1f, 0x7f => try out.print(alloc, "\\u{x:0>4}", .{b}),
            else => try out.append(alloc, b),
        }
        i += 1;
    }
    try out.append(alloc, '"');
}
