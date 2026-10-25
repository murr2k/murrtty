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
const global = @import("../../global.zig");
const App = @import("App.zig");
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
pub fn dump(app: *App, wparam: c.WPARAM, lparam: c.LPARAM) c.LRESULT {
    if (comptime !enabled) return 0;
    const alloc = app.core_app.alloc;
    if (wparam == 2) app.setSystemDark(lparam != 0);
    if (wparam == 1) {
        const point: u32 = @truncate(@as(usize, @bitCast(lparam)));
        for (app.windows.items) |w| {
            var it = w.panes();
            while (it.next()) |s| {
                if (!s.core_initialized) continue;
                const core = &s.core_surface;
                const state = &core.renderer.api.wgl_state;
                state.probe.store(0, .monotonic);
                state.probe_point.store(point, .monotonic);
                // Nothing may have changed to cause a frame, so mark the
                // whole screen dirty (as a modifier change does) and wake
                // the renderer.
                core.renderer_state.mutex.lockUncancelable(global.io());
                core.renderer_state.terminal.flags.dirty.clear = true;
                core.renderer_state.mutex.unlock(global.io());
                core.renderer_thread.wakeup.notify() catch {};
            }
        }
    }
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
    try out.print(alloc, "{{\"modal_depth\":{d},\"windows\":[", .{app.modal_depth});
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

        // Tab bar geometry in client coordinates, for clicks.
        const n = w.tabs.items.len;
        try out.print(alloc, "\"tab_bar\":{{\"visible\":{},\"height\":{d},\"tabs\":[", .{
            w.tabBarVisible(),
            w.tab_bar.height(),
        });
        for (0..n) |i| {
            if (i > 0) try out.append(alloc, ',');
            const r = w.tab_bar.tabRect(i, n, client.right);
            const x = w.tab_bar.closeRect(r);
            try out.print(alloc, "{{\"rect\":[{d},{d},{d},{d}],\"close\":[{d},{d},{d},{d}]}}", .{
                r.left, r.top, r.right, r.bottom, x.left, x.top, x.right, x.bottom,
            });
        }
        const nt = w.tab_bar.newTabRect(n, client.right);
        try out.print(alloc, "],\"new_tab\":[{d},{d},{d},{d}]}},\"tabs\":[", .{
            nt.left, nt.top, nt.right, nt.bottom,
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
        if (s.core_initialized) {
            const grid = s.core_surface.size.grid();
            const wgl_state = &s.core_surface.renderer.api.wgl_state;
            try out.print(alloc, ",\"core_focused\":{},\"frames\":{d},\"probe\":{d},\"cols\":{d},\"rows\":{d},\"text\":", .{
                s.core_surface.focused,
                wgl_state.frames.load(.monotonic),
                wgl_state.probe.load(.monotonic),
                grid.columns,
                grid.rows,
            });
            const text = text: {
                s.core_surface.renderer_state.mutex.lockUncancelable(global.io());
                defer s.core_surface.renderer_state.mutex.unlock(global.io());
                break :text try s.core_surface.io.terminal.plainString(alloc);
            };
            defer alloc.free(text);
            try writeString(alloc, out, text);
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

/// A COLORREF (0x00BBGGRR) as 0xRRGGBB.
fn rgbOf(ref: c.COLORREF) i64 {
    return @as(i64, ref & 0xFF) << 16 | @as(i64, (ref >> 8) & 0xFF) << 8 | @as(i64, (ref >> 16) & 0xFF);
}

/// A JSON string literal. Invalid UTF-8 passes through unchanged; the
/// harness decodes leniently.
fn writeString(alloc: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |b| switch (b) {
        '"' => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\r' => try out.appendSlice(alloc, "\\r"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        0...8, 11, 12, 14...0x1f, 0x7f => try out.print(alloc, "\\u{x:0>4}", .{b}),
        else => try out.append(alloc, b),
    };
    try out.append(alloc, '"');
}
