//! Hooks for the GUI test harness (test/windows/gui), in Debug builds only.
//!
//! When the environment variable GHOSTTY_WIN32_TEST_DUMP names a file, the
//! wakeup window answers the registered message "GhosttyWin32TestDump" by
//! writing the app's state to that file as JSON: windows, tabs, tab-bar
//! geometry, titles, grid sizes and each terminal's visible text. The
//! harness sends the message with SendMessageTimeout, so the file is
//! complete when the call returns. Release builds compile none of this.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const c = @import("c.zig");
const global = @import("../../global.zig");
const App = @import("App.zig");

const log = std.log.scoped(.win32_test_hooks);

pub const enabled = builtin.mode == .debug;

pub const State = if (enabled) struct {
    /// The registered message, or 0 when the hooks are off.
    msg: c.UINT = 0,
    /// Where to write the dump, as UTF-16 for CreateFileW.
    path: ?[:0]u16 = null,
} else struct {};

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
    return .{
        .msg = c.RegisterWindowMessageW(c.L("GhosttyWin32TestDump")),
        .path = path,
    };
}

pub fn deinit(state: *State, alloc: Allocator) void {
    if (comptime !enabled) return;
    if (state.path) |p| alloc.free(p);
    state.path = null;
}

/// Whether `msg` is the dump request.
pub fn isDump(state: *const State, msg: c.UINT) bool {
    if (comptime !enabled) return false;
    return state.msg != 0 and msg == state.msg;
}

/// Write the app's state to the dump file. Returns 1 on success.
pub fn dump(app: *App) c.LRESULT {
    if (comptime !enabled) return 0;
    const alloc = app.core_app.alloc;
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

        // Tab bar geometry in client coordinates, for clicks.
        const n = w.surfaces.items.len;
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

        for (w.surfaces.items, 0..) |s, si| {
            if (si > 0) try out.append(alloc, ',');
            try out.print(alloc, "{{\"hwnd\":{d},\"visible\":{},\"title\":", .{
                @intFromPtr(s.hwnd),
                c.IsWindowVisible(s.hwnd) != 0,
            });
            try writeString(alloc, out, s.title orelse "");
            if (s.core_initialized) {
                const grid = s.core_surface.size.grid();
                try out.print(alloc, ",\"cols\":{d},\"rows\":{d},\"text\":", .{ grid.columns, grid.rows });
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
        try out.appendSlice(alloc, "]}");
    }
    try out.appendSlice(alloc, "]}");
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
