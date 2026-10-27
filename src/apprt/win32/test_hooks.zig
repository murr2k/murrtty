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
const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");

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
} else struct {};

/// Whether the hooks are on, for code with no App at hand.
var on = false;

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
    return .{
        .msg = c.RegisterWindowMessageW(c.L("GhosttyWin32TestDump")),
        .path = path,
        .record_launches = c.GetEnvironmentVariableW(c.L("GHOSTTY_WIN32_TEST_LAUNCH"), null, 0) == 0,
    };
}

pub fn deinit(state: *State, alloc: Allocator) void {
    if (comptime !enabled) return;
    if (state.path) |p| alloc.free(p);
    state.path = null;
    for (state.launches.items) |l| alloc.free(l);
    state.launches.deinit(alloc);
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
/// - 5: spike S2's transparency (see setTransparent) on (`lparam` 1) or
///   off (0).
/// - 6: every pane's renderer failed (`lparam` 1) or recovered (0), through
///   the core's renderer_health action.
/// - 7: panes ignore WM_MOUSELEAVE (`lparam` 1) or act on it (0).
/// - 8: Windows' "Always show scrollbars" on (`lparam` 1) or off (0).
/// - 10: ask every pane's renderer for the whole frame it presents next
///   (each pane's `frame_ready` reports it read).
/// - 11: write the frames read as `frame-<n>.bmp` beside the dump file, n
///   counting the panes window by window, tab by tab.
/// - 12: paint each window's chrome (header bar and tab row) into a bitmap
///   and write it as `chrome-<n>.bmp` beside the dump file: what WM_PAINT
///   draws, where captures can't see it (the hidden desktop).
/// (9 is the perf-trace branch's.)
pub fn dump(app: *App, wparam: c.WPARAM, lparam: c.LPARAM) c.LRESULT {
    if (comptime !enabled) return 0;
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
    if (wparam == 4) setOverlays(app, std.enums.fromInt(OverlayKind, lparam));
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
    if (wparam == 5) setTransparent(app, lparam != 0);
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
    if (wparam == 12) saveChrome(app);
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
            try out.appendSlice(alloc, "},");
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
    try out.appendSlice(alloc, "]}");
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
        try out.print(alloc, "{{\"hwnd\":{d},\"rect\":[{d},{d},{d},{d}],\"focused\":{},\"visible\":{}", .{
            @intFromPtr(s.hwnd),
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

/// Paint each window's chrome into a 32-bit bitmap and write it as
/// `chrome-<n>.bmp` beside the dump file.
fn saveChrome(app: *App) void {
    const dump_path = app.test_state.path orelse return;
    const sep = std.mem.lastIndexOfScalar(u16, dump_path, '\\') orelse return;
    for (app.windows.items, 0..) |w, n| {
        var client: c.RECT = .{};
        _ = c.GetClientRect(w.hwnd, &client);
        const width = client.right;
        const height = w.chromeHeight();
        if (width <= 0 or height <= 0) continue;
        const info: c.BITMAPINFOHEADER = .{ .biWidth = width, .biHeight = -height };
        var bits: ?[*]u8 = null;
        const screen = c.GetDC(null) orelse continue;
        defer _ = c.ReleaseDC(null, screen);
        const bmp = c.CreateDIBSection(screen, &info, c.DIB_RGB_COLORS, &bits, null, 0) orelse continue;
        defer _ = c.DeleteObject(bmp);
        const mem = c.CreateCompatibleDC(screen) orelse continue;
        defer _ = c.DeleteDC(mem);
        const old = c.SelectObject(mem, bmp);
        defer _ = c.SelectObject(mem, old);
        w.paintChrome(mem);
        _ = c.GdiFlush();
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "chrome-{d}.bmp", .{n}) catch continue;
        var path: [1024:0]u16 = undefined;
        if (sep + 1 + name.len >= path.len) continue;
        @memcpy(path[0 .. sep + 1], dump_path[0 .. sep + 1]);
        for (name, 0..) |ch, i| path[sep + 1 + i] = ch;
        path[sep + 1 + name.len] = 0;
        const size: usize = @intCast(width * height * 4);
        writeBmp(&path, (bits orelse continue)[0..size], @intCast(width), @intCast(height));
    }
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

/// Spike S2 (roadmap): does DWM honor per-pixel alpha from the panes' GL
/// child windows when the top-level window has blur-behind with an empty
/// region (which turns on per-pixel alpha without blurring)? Each pane then
/// presents its frame's own alpha (background-opacity) instead of
/// compositing over the opaque background.
fn setTransparent(app: *App, enable: bool) void {
    for (app.windows.items) |w| {
        const region = if (enable) c.CreateRectRgn(0, 0, -1, -1) else null;
        defer if (region) |r| {
            _ = c.DeleteObject(r);
        };
        const bb: c.DWM_BLURBEHIND = .{
            .dwFlags = c.DWM_BB_ENABLE | @as(c.DWORD, if (enable) c.DWM_BB_BLURREGION else 0),
            .fEnable = @intFromBool(enable),
            .hRgnBlur = region,
        };
        const hr = c.DwmEnableBlurBehindWindow(w.hwnd, &bb);
        if (hr < 0) log.err("DwmEnableBlurBehindWindow failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
        var it = w.panes();
        while (it.next()) |s| {
            if (!s.core_initialized) continue;
            s.core_surface.renderer.api.wgl_state.transparent.store(enable, .monotonic);
            redraw(s);
        }
    }
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
fn writeString(alloc: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
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
