//! The command palette (roadmap 3.3), after GTK's: a box at the window's
//! top center with a filter field over the list of commands, the window
//! dimmed behind it. The commands are the `command-palette-entry` items
//! the runtime can perform (App.supportsAction), each row the title with
//! the action beneath ("new_split:right", in a monospace font) and the key
//! binding as keycaps, and a "Focus:" entry per terminal in every window.
//! Those GTK leaves without a line beneath, so terminals of the same title
//! look alike; here it reads where the terminal is and its directory
//! ("Window 2, tab 1: C:\src"). Typing filters them: matches of the title,
//! then of the line beneath (GTK matches both), then titles holding the
//! typed letters in order. Up and Down choose, Enter or a click runs,
//! Escape or a click outside closes. What was chosen runs after the
//! palette has closed, from a posted message, never inside its own window
//! procedures.
//!
//! Its windows (the box and the dimming) are layered children of the
//! window (spike S1), so DWM composes them over the panes. The Window owns
//! it; the windows are created the first time it opens.
const CommandPalette = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("../../input.zig");
const c = @import("c.zig");
const App = @import("App.zig");
const ContextMenu = @import("ContextMenu.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");

const log = std.log.scoped(.win32_palette);

pub const class_name = c.L("MurrttyPalette");
pub const dim_class_name = c.L("MurrttyPaletteDim");

/// Posted to the box: run what was chosen, now that it has closed.
const WM_RUN = c.WM_APP + 10;

/// Metrics in device-independent pixels.
const max_width = 600;
const top_gap = 12;
const field_height = 40;
const row_height = 46;
const max_rows = 10;
const pad = 8;
const radius = 8;
/// The box's and the dimming's opacity, out of 255.
const box_opacity = 250;
const dim_opacity = 90;

const id_edit = 1;
const id_list = 2;

const Entry = struct {
    title: []const u8,
    /// The line beneath: the action, or where a terminal is.
    detail: []const u8,
    /// The key binding, "Ctrl+Shift+T", or empty.
    binding: []const u8,
    action: ?input.Binding.Action,
    /// A terminal to focus (checked to still exist before use).
    jump: ?*Surface,
};

/// What was chosen, kept past closing until WM_RUN runs it.
const Choice = union(enum) {
    action: input.Binding.Action,
    jump: *Surface,
};

window: ?*Window = null,
hwnd: ?c.HWND = null,
dim: ?c.HWND = null,
edit: ?c.HWND = null,
list: ?c.HWND = null,
edit_proc: isize = 0,
list_proc: isize = 0,
/// The pane it opened over: commands run there.
surface: ?*Surface = null,
/// Per opening: the entries (in `arena`) and the filtered order.
arena: ?std.heap.ArenaAllocator = null,
entries: []Entry = &.{},
shown: std.ArrayList(usize) = .empty,
pending: ?Choice = null,
font: ?c.HFONT = null,
/// For the action beneath a command's title.
mono_font: ?c.HFONT = null,
font_dpi: c.UINT = 0,
bg: c.COLORREF = c.rgb(0x2b, 0x2b, 0x2b),
field_bg: c.COLORREF = c.rgb(0x20, 0x20, 0x20),
selected_bg: c.COLORREF = c.rgb(0x3a, 0x3a, 0x3a),
fg: c.COLORREF = c.rgb(0xff, 0xff, 0xff),
dim_fg: c.COLORREF = c.rgb(0xa0, 0xa0, 0xa0),
field_brush: ?c.HBRUSH = null,

pub fn registerClass(instance: c.HINSTANCE) !void {
    for ([_]struct { c.LPCWSTR, c.WNDPROC }{
        .{ class_name, &wndProc },
        .{ dim_class_name, &dimProc },
    }) |cls| {
        const wc: c.WNDCLASSEXW = .{
            .lpfnWndProc = cls[1],
            .hInstance = instance,
            .hCursor = c.LoadCursorW(null, c.IDC_ARROW),
            .lpszClassName = cls[0],
        };
        if (c.RegisterClassExW(&wc) == 0) return error.RegisterClassFailed;
    }
}

pub fn deinit(self: *CommandPalette, alloc: Allocator) void {
    // The windows go with their parent, the window. The controls get their
    // own procedures back, so they still clean up after themselves.
    for ([_]?c.HWND{ self.hwnd, self.dim }) |h| if (h) |w| {
        _ = c.SetWindowLongPtrW(w, c.GWLP_USERDATA, 0);
    };
    if (self.edit) |e| _ = c.SetWindowLongPtrW(e, c.GWLP_WNDPROC, self.edit_proc);
    if (self.list) |l| _ = c.SetWindowLongPtrW(l, c.GWLP_WNDPROC, self.list_proc);
    self.hwnd = null;
    self.dim = null;
    self.edit = null;
    self.list = null;
    self.freeEntries();
    self.shown.deinit(alloc);
    for ([_]?c.HGDIOBJ{ self.font, self.mono_font, self.field_brush }) |obj| if (obj) |o| {
        _ = c.DeleteObject(o);
    };
    self.font = null;
    self.mono_font = null;
    self.field_brush = null;
}

pub fn isOpen(self: *const CommandPalette) bool {
    const h = self.hwnd orelse return false;
    return c.IsWindowVisible(h) != 0;
}

/// While it is open, the window's keyboard goes to its filter field.
pub fn focusTarget(self: *const CommandPalette) ?c.HWND {
    return if (self.isOpen()) self.edit else null;
}

/// toggle_command_palette from `surface`, a pane of `window`.
pub fn toggle(self: *CommandPalette, window: *Window, surface: *Surface) void {
    if (self.isOpen()) return self.close();
    self.open(window, surface) catch |err| log.warn("command palette not opened err={}", .{err});
}

fn open(self: *CommandPalette, window: *Window, surface: *Surface) !void {
    self.window = window;
    self.surface = surface;
    if (self.hwnd == null) try self.create(window);
    self.setColors(surface);
    try self.build(window.app);
    _ = c.SetWindowTextW(self.edit.?, c.L(""));
    try self.refilter();
    _ = c.ShowWindow(self.dim.?, c.SW_SHOWNA);
    _ = c.ShowWindow(self.hwnd.?, c.SW_SHOWNA);
    _ = c.SetFocus(self.edit.?);
}

/// Hide it and give the keyboard back to the pane it opened over.
pub fn close(self: *CommandPalette) void {
    const hwnd = self.hwnd orelse return;
    if (!self.isOpen()) return;
    const had_focus = self.ownsFocus();
    _ = c.ShowWindow(hwnd, c.SW_HIDE);
    if (self.dim) |d| _ = c.ShowWindow(d, c.SW_HIDE);
    self.freeEntries();
    if (had_focus) if (self.surface) |s| if (self.surfaceAlive(s)) {
        _ = c.SetFocus(s.focusTarget());
    };
}

/// Whether the keyboard focus is in the palette.
pub fn ownsFocus(self: *const CommandPalette) bool {
    const f = c.GetFocus() orelse return false;
    return f == self.hwnd or f == self.edit or f == self.list;
}

fn create(self: *CommandPalette, window: *Window) !void {
    const instance = c.GetModuleHandleW(null);
    const dim = c.CreateWindowExW(c.WS_EX_LAYERED, dim_class_name, c.L(""), c.WS_CHILD | c.WS_CLIPSIBLINGS, 0, 0, 1, 1, window.hwnd, null, instance, null) orelse return error.CreateWindowFailed;
    errdefer _ = c.DestroyWindow(dim);
    _ = c.SetWindowLongPtrW(dim, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    _ = c.SetLayeredWindowAttributes(dim, 0, dim_opacity, c.LWA_ALPHA);

    const hwnd = c.CreateWindowExW(c.WS_EX_LAYERED, class_name, c.L(""), c.WS_CHILD | c.WS_CLIPSIBLINGS | c.WS_CLIPCHILDREN, 0, 0, 1, 1, window.hwnd, null, instance, null) orelse return error.CreateWindowFailed;
    errdefer _ = c.DestroyWindow(hwnd);
    _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    _ = c.SetLayeredWindowAttributes(hwnd, 0, box_opacity, c.LWA_ALPHA);

    const edit = c.CreateWindowExW(0, c.L("EDIT"), c.L(""), c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.ES_AUTOHSCROLL, 0, 0, 1, 1, hwnd, @ptrFromInt(id_edit), instance, null) orelse return error.CreateWindowFailed;
    const list = c.CreateWindowExW(0, c.L("LISTBOX"), c.L(""), c.WS_CHILD | c.WS_VSCROLL | c.LBS_NOTIFY | c.LBS_OWNERDRAWFIXED | c.LBS_NOINTEGRALHEIGHT, 0, 0, 1, 1, hwnd, @ptrFromInt(id_list), instance, null) orelse return error.CreateWindowFailed;
    for ([_]c.HWND{ edit, list }) |w| {
        _ = c.SetWindowLongPtrW(w, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    }
    self.edit_proc = c.SetWindowLongPtrW(edit, c.GWLP_WNDPROC, @bitCast(@intFromPtr(&editProc)));
    self.list_proc = c.SetWindowLongPtrW(list, c.GWLP_WNDPROC, @bitCast(@intFromPtr(&listProc)));

    self.dim = dim;
    self.hwnd = hwnd;
    self.edit = edit;
    self.list = list;
}

fn setColors(self: *CommandPalette, surface: *Surface) void {
    const bg = surface.colors.bg;
    const fg = surface.colors.fg;
    self.bg = c.rgb(mix(bg.r, fg.r, 0.08), mix(bg.g, fg.g, 0.08), mix(bg.b, fg.b, 0.08));
    self.field_bg = c.rgb(bg.r, bg.g, bg.b);
    self.selected_bg = c.rgb(mix(bg.r, fg.r, 0.2), mix(bg.g, fg.g, 0.2), mix(bg.b, fg.b, 0.2));
    self.fg = c.rgb(fg.r, fg.g, fg.b);
    self.dim_fg = c.rgb(mix(fg.r, bg.r, 0.4), mix(fg.g, bg.g, 0.4), mix(fg.b, bg.b, 0.4));
    if (self.field_brush) |b| _ = c.DeleteObject(b);
    self.field_brush = c.CreateSolidBrush(self.field_bg);
    // A dark scroll bar on a dark background (Explorer's dark theme).
    const luma = @as(u32, bg.r) * 299 + @as(u32, bg.g) * 587 + @as(u32, bg.b) * 114;
    const theme: c.LPCWSTR = if (luma < 128_000) c.L("DarkMode_Explorer") else c.L("Explorer");
    if (self.list) |l| _ = c.SetWindowTheme(l, theme, null);
}

fn mix(a: u8, b: u8, t: f32) u8 {
    const af: f32 = @floatFromInt(a);
    const bf: f32 = @floatFromInt(b);
    return @intFromFloat(@round(af + (bf - af) * t));
}

fn freeEntries(self: *CommandPalette) void {
    if (self.arena) |*a| a.deinit();
    self.arena = null;
    self.entries = &.{};
    self.shown.clearRetainingCapacity();
}

/// The commands and the terminals, sorted by title as GTK sorts them.
fn build(self: *CommandPalette, app: *App) !void {
    self.freeEntries();
    self.arena = .init(app.core_app.alloc);
    const alloc = self.arena.?.allocator();
    var list: std.ArrayList(Entry) = .empty;

    for (app.config.@"command-palette-entry".value.items) |cmd| {
        if (!App.supportsAction(cmd.action)) continue;
        try list.append(alloc, .{
            .title = cmd.title,
            .detail = try std.fmt.allocPrint(alloc, "{f}", .{cmd.action}),
            .binding = binding: {
                const t = app.config.keybind.set.getTrigger(cmd.action) orelse break :binding "";
                var w: std.Io.Writer.Allocating = .init(alloc);
                ContextMenu.writeTrigger(&w.writer, t) catch break :binding "";
                break :binding w.written();
            },
            .action = cmd.action,
            .jump = null,
        });
    }

    // Window by window, tab by tab, so terminals of the same title keep
    // that order.
    const several = app.windows.items.len > 1;
    for (app.windows.items, 1..) |w, wi| for (w.tabs.items, 1..) |tab, ti| {
        var it = tab.panes();
        while (it.next()) |pane| {
            const s = pane.view;
            const title = s.title orelse "murrtty";
            const pwd: []const u8 = if (s.core_initialized) try s.core_surface.pwd(alloc) orelse "" else "";
            var detail: std.Io.Writer.Allocating = .init(alloc);
            if (several) try detail.writer.print("Window {d}, tab {d}", .{ wi, ti }) else try detail.writer.print("Tab {d}", .{ti});
            // The directory, unless the title already shows it (GTK's
            // tooltip).
            if (pwd.len > 0 and std.mem.indexOf(u8, title, pwd) == null) try detail.writer.print(": {s}", .{pwd});
            try list.append(alloc, .{
                .title = try std.fmt.allocPrint(alloc, "Focus: {s}", .{title}),
                .detail = detail.written(),
                .binding = "",
                .action = null,
                .jump = s,
            });
        }
    };

    std.mem.sort(Entry, list.items, {}, lessThan);
    self.entries = list.items;
}

/// By title, ignoring case, with a colon sorting before any letter so
/// "Foo:" comes before "Foo Bar"; the shorter first when one is the
/// other's start (GTK's order). The sort is stable.
fn lessThan(_: void, a: Entry, b: Entry) bool {
    return titleLess(a.title, b.title);
}

fn titleLess(a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        const xl = std.ascii.toLower(if (x == ':') '\t' else x);
        const yl = std.ascii.toLower(if (y == ':') '\t' else y);
        if (xl != yl) return xl < yl;
    }
    return a.len < b.len;
}

/// How well an entry matches the filter, lower first; null hides it.
fn rank(title: []const u8, detail: []const u8, query: []const u8) ?u8 {
    if (query.len == 0) return 0;
    if (std.ascii.findIgnoreCase(title, query) != null) return 0;
    if (std.ascii.findIgnoreCase(detail, query) != null) return 1;
    if (subsequence(title, query)) return 2;
    return null;
}

/// Whether `query`'s letters, spaces aside, all appear in `text` in order.
fn subsequence(text: []const u8, query: []const u8) bool {
    var i: usize = 0;
    for (query) |q| {
        if (q == ' ') continue;
        while (i < text.len and std.ascii.toLower(text[i]) != std.ascii.toLower(q)) i += 1;
        if (i == text.len) return false;
        i += 1;
    }
    return true;
}

/// The filter field's text, as UTF-8 in `buf`, trimmed.
pub fn filterText(self: *const CommandPalette, buf: []u8) []const u8 {
    const edit = self.edit orelse return "";
    var wide: [256]u16 = undefined;
    const n = c.GetWindowTextW(edit, &wide, wide.len);
    const len = std.unicode.utf16LeToUtf8(buf, wide[0..@intCast(@max(n, 0))]) catch 0;
    return std.mem.trim(u8, buf[0..len], " ");
}

/// Filter by the field's text and refill the list, selecting the first.
fn refilter(self: *CommandPalette) !void {
    const list = self.list orelse return;
    const gpa = (self.window orelse return).app.core_app.alloc;
    var buf: [1024]u8 = undefined;
    const query = self.filterText(&buf);

    const Ranked = struct { rank: u8, index: usize };
    var ranked: std.ArrayList(Ranked) = .empty;
    defer ranked.deinit(gpa);
    for (self.entries, 0..) |e, i| {
        if (rank(e.title, e.detail, query)) |r| try ranked.append(gpa, .{ .rank = r, .index = i });
    }
    std.mem.sort(Ranked, ranked.items, {}, struct {
        fn f(_: void, a: Ranked, b: Ranked) bool {
            return if (a.rank != b.rank) a.rank < b.rank else a.index < b.index;
        }
    }.f);
    self.shown.clearRetainingCapacity();
    for (ranked.items) |r| try self.shown.append(gpa, r.index);

    _ = c.SendMessageW(list, c.LB_RESETCONTENT, 0, 0);
    for (0..self.shown.items.len) |i| _ = c.SendMessageW(list, c.LB_ADDSTRING, 0, @intCast(i));
    if (self.shown.items.len > 0) _ = c.SendMessageW(list, c.LB_SETCURSEL, 0, 0);
    self.layout();
}

/// The listed titles, best match first, and the selected row: for the
/// GUI tests' dump.
pub fn shownTitle(self: *const CommandPalette, row: usize) []const u8 {
    return self.entries[self.shown.items[row]].title;
}

pub fn shownDetail(self: *const CommandPalette, row: usize) []const u8 {
    return self.entries[self.shown.items[row]].detail;
}

pub fn shownCount(self: *const CommandPalette) usize {
    return if (self.isOpen()) self.shown.items.len else 0;
}

pub fn selected(self: *const CommandPalette) ?usize {
    const list = self.list orelse return null;
    const sel = c.SendMessageW(list, c.LB_GETCURSEL, 0, 0);
    return if (sel >= 0 and sel < self.shown.items.len) @intCast(sel) else null;
}

/// A row's height in pixels, to click one.
pub fn rowHeight(self: *const CommandPalette) c_int {
    const list = self.list orelse return 0;
    return @intCast(c.SendMessageW(list, c.LB_GETITEMHEIGHT, 0, 0));
}

/// Place the dimming over the window's client area and the box at its
/// top center, under the tab bar. The window calls this when it resizes.
pub fn layout(self: *CommandPalette) void {
    const window = self.window orelse return;
    const hwnd = self.hwnd orelse return;
    const dpi = c.GetDpiForWindow(window.hwnd);
    self.ensureFont(dpi);

    var client: c.RECT = .{};
    _ = c.GetClientRect(window.hwnd, &client);
    // Above the panes, and the box above the dimming.
    if (self.dim) |d| _ = c.SetWindowPos(d, c.HWND_TOP, 0, 0, client.right, client.bottom, c.SWP_NOACTIVATE);
    const rows: c_int = @intCast(@min(self.shown.items.len, max_rows));
    const width = @min(px(max_width, dpi), @max(client.right - px(32, dpi), px(200, dpi)));
    const list_h = rows * px(row_height, dpi);
    const height = px(field_height, dpi) + list_h + (if (rows > 0) px(pad, dpi) else 0);
    const top = (if (window.tabBarVisible()) window.tab_bar.height() else 0) + px(top_gap, dpi);
    _ = c.SetWindowPos(hwnd, c.HWND_TOP, @divTrunc(client.right - width, 2), top, width, height, c.SWP_NOACTIVATE);
    const r = px(radius, dpi) * 2;
    if (c.CreateRoundRectRgn(0, 0, width + 1, height + 1, r, r)) |rgn| {
        if (c.SetWindowRgn(hwnd, rgn, c.TRUE) == 0) _ = c.DeleteObject(rgn);
    }

    const text_h = self.textHeight();
    if (self.edit) |e| {
        _ = c.SetWindowPos(e, null, px(pad + 8, dpi), @divTrunc(px(field_height, dpi) - text_h, 2), width - px(2 * pad + 16, dpi), text_h, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
    }
    if (self.list) |l| {
        _ = c.SendMessageW(l, c.LB_SETITEMHEIGHT, 0, px(row_height, dpi));
        _ = c.SetWindowPos(l, null, px(pad, dpi), px(field_height, dpi), width - px(2 * pad, dpi), list_h, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
        _ = c.ShowWindow(l, if (rows > 0) c.SW_SHOWNA else c.SW_HIDE);
    }
    _ = c.InvalidateRect(hwnd, null, c.TRUE);
}

fn px(v: c_int, dpi: c.UINT) c_int {
    return @intCast(@divTrunc(@as(i64, v) * dpi, c.USER_DEFAULT_SCREEN_DPI));
}

fn ensureFont(self: *CommandPalette, dpi: c.UINT) void {
    if (self.font != null and self.font_dpi == dpi) return;
    for ([_]?c.HFONT{ self.font, self.mono_font }) |f| if (f) |o| {
        _ = c.DeleteObject(o);
    };
    self.font = null;
    self.mono_font = null;
    self.font_dpi = dpi;
    var ncm: c.NONCLIENTMETRICSW = .{};
    if (c.SystemParametersInfoForDpi(c.SPI_GETNONCLIENTMETRICS, @sizeOf(c.NONCLIENTMETRICSW), &ncm, 0, dpi) == 0) return;
    // The action beneath a title: monospace, a little smaller (GTK's
    // "subtitle monospace").
    var mono = ncm.lfMessageFont;
    mono.lfHeight = @divTrunc(mono.lfHeight * 9, 10);
    const face = c.L("Consolas");
    @memset(&mono.lfFaceName, 0);
    @memcpy(mono.lfFaceName[0..face.len], face);
    self.mono_font = c.CreateFontIndirectW(&mono);
    const font = c.CreateFontIndirectW(&ncm.lfMessageFont) orelse return;
    self.font = font;
    for ([_]?c.HWND{ self.edit, self.list }) |h| if (h) |w| {
        _ = c.SendMessageW(w, c.WM_SETFONT, @intFromPtr(font), 1);
    };
}

fn textHeight(self: *const CommandPalette) c_int {
    const hwnd = self.hwnd orelse return 16;
    const dc = c.GetDC(hwnd) orelse return 16;
    defer _ = c.ReleaseDC(hwnd, dc);
    const old = if (self.font) |f| c.SelectObject(dc, f) else null;
    defer if (old) |o| {
        _ = c.SelectObject(dc, o);
    };
    var r: c.RECT = .{};
    const probe = [_]u16{ 'A', 'g' };
    _ = c.DrawTextW(dc, &probe, probe.len, &r, c.DT_CALCRECT | c.DT_SINGLELINE | c.DT_NOPREFIX);
    return @max(r.bottom, 1);
}

/// Move the list's selection by `delta` rows, within the list.
fn move(self: *CommandPalette, delta: isize) void {
    const list = self.list orelse return;
    const count = c.SendMessageW(list, c.LB_GETCOUNT, 0, 0);
    if (count <= 0) return;
    const current = c.SendMessageW(list, c.LB_GETCURSEL, 0, 0);
    const next = std.math.clamp(@max(current, 0) + delta, 0, count - 1);
    _ = c.SendMessageW(list, c.LB_SETCURSEL, @intCast(next), 0);
}

/// Run the selected entry: close, then run it from WM_RUN.
fn choose(self: *CommandPalette) void {
    const row = self.selected() orelse return;
    const entry = self.entries[self.shown.items[row]];
    self.pending = if (entry.jump) |s| .{ .jump = s } else .{ .action = entry.action.? };
    self.close();
    if (self.hwnd) |h| _ = c.PostMessageW(h, WM_RUN, 0, 0);
}

fn run(self: *CommandPalette) void {
    const choice = self.pending orelse return;
    self.pending = null;
    switch (choice) {
        .jump => |s| if (self.surfaceAlive(s)) s.window.presentSurface(s),
        .action => |action| {
            // The pane it opened over, unless that has closed since.
            const opened = if (self.surface) |s| (if (self.surfaceAlive(s)) s else null) else null;
            const target = opened orelse (self.window orelse return).activeSurface() orelse return;
            if (!target.core_initialized) return;
            _ = target.core_surface.performBindingAction(action) catch |err| {
                log.warn("command palette action failed err={}", .{err});
            };
        },
    }
}

/// Whether `s` is still one of the app's panes.
fn surfaceAlive(self: *const CommandPalette, s: *Surface) bool {
    const window = self.window orelse return false;
    for (window.app.windows.items) |w| {
        var it = w.panes();
        while (it.next()) |p| if (p == s) return true;
    }
    return false;
}

fn paint(self: *CommandPalette, hwnd: c.HWND) void {
    var ps: c.PAINTSTRUCT = undefined;
    const hdc = c.BeginPaint(hwnd, &ps) orelse return;
    defer _ = c.EndPaint(hwnd, &ps);
    var rect: c.RECT = .{};
    _ = c.GetClientRect(hwnd, &rect);
    fill(hdc, rect, self.bg);
    const dpi = c.GetDpiForWindow(hwnd);
    fill(hdc, .{
        .left = px(pad, dpi),
        .top = px(pad / 2, dpi),
        .right = rect.right - px(pad, dpi),
        .bottom = px(field_height - pad / 2, dpi),
    }, self.field_bg);
    const r = px(radius, dpi) * 2;
    if (c.CreateRoundRectRgn(0, 0, rect.right, rect.bottom, r, r)) |rgn| {
        defer _ = c.DeleteObject(rgn);
        if (c.CreateSolidBrush(c.rgb(0x55, 0x55, 0x55))) |brush| {
            defer _ = c.DeleteObject(brush);
            _ = c.FrameRgn(hdc, rgn, brush, 1, 1);
        }
    }
}

/// A row: the title, its description beneath, the binding as keycaps.
fn drawItem(self: *CommandPalette, item: *const c.DRAWITEMSTRUCT) void {
    if (item.itemID >= self.shown.items.len) return;
    const e = self.entries[self.shown.items[item.itemID]];
    const dc = item.hDC;
    fill(dc, item.rcItem, if (item.itemState & c.ODS_SELECTED != 0) self.selected_bg else self.bg);
    const old = if (self.font) |f| c.SelectObject(dc, f) else null;
    defer if (old) |o| {
        _ = c.SelectObject(dc, o);
    };
    _ = c.SetBkMode(dc, c.TRANSPARENT);
    const dpi = c.GetDpiForWindow(item.hwndItem);
    const inset = px(10, dpi);
    const half = @divTrunc(item.rcItem.bottom - item.rcItem.top, 2);

    // Keycaps at the right, last key first; the text gets what is left.
    var right = item.rcItem.right - inset;
    var keys: Keys = .init(e.binding);
    var names: [5][]const u8 = undefined;
    var count: usize = 0;
    while (keys.next()) |k| : (count += 1) names[count] = k;
    while (count > 0) {
        count -= 1;
        right = self.keycap(dc, names[count], right, item.rcItem.top + half, dpi) - px(4, dpi);
    }
    const text: c.RECT = .{ .left = item.rcItem.left + inset, .top = item.rcItem.top, .right = right - inset, .bottom = item.rcItem.bottom };
    var upper = text;
    upper.bottom = item.rcItem.top + half + px(1, dpi);
    drawText(dc, e.title, &upper, self.fg, c.DT_BOTTOM);
    // An action in monospace; where a terminal is in the usual font.
    if (e.jump == null) if (self.mono_font) |f| {
        _ = c.SelectObject(dc, f);
    };
    var lower = text;
    lower.top = item.rcItem.top + half + px(1, dpi);
    drawText(dc, e.detail, &lower, self.dim_fg, c.DT_TOP);
}

/// The keys of a binding as writeTrigger spells it ("Ctrl+Shift++"):
/// each modifier, then the key, which may itself be "+".
const Keys = struct {
    rest: []const u8,
    count: usize = 0,

    fn init(binding: []const u8) Keys {
        return .{ .rest = binding };
    }

    fn next(self: *Keys) ?[]const u8 {
        if (self.rest.len == 0 or self.count == 5) return null;
        self.count += 1;
        for ([_][]const u8{ "Ctrl+", "Shift+", "Alt+", "Win+" }) |m| {
            if (self.rest.len > m.len and std.mem.startsWith(u8, self.rest, m)) {
                self.rest = self.rest[m.len..];
                return m[0 .. m.len - 1];
            }
        }
        defer self.rest = "";
        return self.rest;
    }
};

/// A key's name in a small box ending at `right`, centered on `mid`;
/// returns its left edge.
fn keycap(self: *CommandPalette, dc: c.HDC, name: []const u8, right: c_int, mid: c_int, dpi: c.UINT) c_int {
    var wide: [32]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, name[0..@min(name.len, 31)]) catch 0;
    var r: c.RECT = .{};
    _ = c.DrawTextW(dc, &wide, @intCast(n), &r, c.DT_CALCRECT | c.DT_SINGLELINE | c.DT_NOPREFIX);
    const w = r.right + px(12, dpi);
    const h = r.bottom + px(4, dpi);
    var box: c.RECT = .{ .left = right - w, .top = mid - @divTrunc(h, 2), .right = right, .bottom = mid - @divTrunc(h, 2) + h };
    fill(dc, box, self.field_bg);
    _ = c.SetTextColor(dc, self.dim_fg);
    _ = c.DrawTextW(dc, &wide, @intCast(n), &box, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX);
    return right - w;
}

fn drawText(dc: c.HDC, text: []const u8, rect: *c.RECT, color: c.COLORREF, valign: c.UINT) void {
    var wide: [512]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, text[0..@min(text.len, 500)]) catch 0;
    _ = c.SetTextColor(dc, color);
    _ = c.DrawTextW(dc, &wide, @intCast(n), rect, valign | c.DT_SINGLELINE | c.DT_NOPREFIX | c.DT_END_ELLIPSIS);
}

fn fill(hdc: c.HDC, r: c.RECT, color: c.COLORREF) void {
    const brush = c.CreateSolidBrush(color) orelse return;
    defer _ = c.DeleteObject(brush);
    _ = c.FillRect(hdc, &r, brush);
}

fn fromHwnd(hwnd: c.HWND) ?*CommandPalette {
    const ptr: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA));
    return if (ptr != 0) @ptrFromInt(ptr) else null;
}

fn wndProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const self = fromHwnd(hwnd) orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    switch (msg) {
        c.WM_ERASEBKGND => return 1,
        c.WM_PAINT => {
            self.paint(hwnd);
            return 0;
        },
        c.WM_COMMAND => {
            if (c.loword(wparam) == id_edit and c.hiword(wparam) == c.EN_CHANGE) {
                self.refilter() catch |err| log.warn("command palette filter failed err={}", .{err});
            }
            return 0;
        },
        c.WM_CTLCOLOREDIT => {
            const dc: c.HDC = @ptrFromInt(wparam);
            _ = c.SetTextColor(dc, self.fg);
            _ = c.SetBkColor(dc, self.field_bg);
            if (self.field_brush) |b| return @bitCast(@intFromPtr(b));
        },
        c.WM_DRAWITEM => {
            const item: *const c.DRAWITEMSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            self.drawItem(item);
            return 1;
        },
        WM_RUN => {
            self.run();
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// The dimming: a click on it closes the palette, as a click outside a
/// popup does.
fn dimProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_ERASEBKGND => return 1,
        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = undefined;
            if (c.BeginPaint(hwnd, &ps)) |dc| {
                fill(dc, ps.rcPaint, c.rgb(0, 0, 0));
                _ = c.EndPaint(hwnd, &ps);
            }
            return 0;
        },
        c.WM_LBUTTONDOWN, c.WM_RBUTTONDOWN, c.WM_MBUTTONDOWN => {
            if (fromHwnd(hwnd)) |self| self.close();
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// The filter field's keys: Up, Down, Page Up and Page Down move the
/// selection, Enter runs it, Escape closes.
fn editProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const self = fromHwnd(hwnd) orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    switch (msg) {
        c.WM_KEYDOWN => switch (wparam) {
            c.VK_UP, c.VK_DOWN, c.VK_PRIOR, c.VK_NEXT => {
                self.move(switch (wparam) {
                    c.VK_UP => -1,
                    c.VK_DOWN => 1,
                    c.VK_PRIOR => -max_rows,
                    else => max_rows,
                });
                return 0;
            },
            c.VK_RETURN => {
                self.choose();
                return 0;
            },
            c.VK_ESCAPE => {
                self.close();
                return 0;
            },
            else => {},
        },
        // Their characters would only beep.
        c.WM_CHAR => if (wparam == '\r' or wparam == 0x1b) return 0,
        // The keyboard moving elsewhere in the window (not to another
        // window or app) closes it, as a click outside it does.
        c.WM_KILLFOCUS => if (@as(?c.HWND, @ptrFromInt(wparam))) |to| {
            if (self.window) |w| if (to != self.list and to != self.hwnd and
                (to == w.hwnd or c.IsChild(w.hwnd, to) != 0))
            {
                const result = c.CallWindowProcW(self.edit_proc, hwnd, msg, wparam, lparam);
                self.close();
                return result;
            };
        },
        else => {},
    }
    return c.CallWindowProcW(self.edit_proc, hwnd, msg, wparam, lparam);
}

/// The list runs the row a click lets go on (GTK's single-click
/// activation), after the list itself has let go of the mouse.
fn listProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const self = fromHwnd(hwnd) orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const result = c.CallWindowProcW(self.list_proc, hwnd, msg, wparam, lparam);
    switch (msg) {
        c.WM_LBUTTONUP => {
            var client: c.RECT = .{};
            _ = c.GetClientRect(hwnd, &client);
            const x = c.xParam(lparam);
            const y = c.yParam(lparam);
            if (x >= 0 and y >= 0 and x < client.right and y < client.bottom) self.choose();
        },
        // The keyboard stays in the field.
        c.WM_LBUTTONDOWN => if (self.edit) |e| {
            _ = c.SetFocus(e);
        },
        else => {},
    }
    return result;
}

test "palette order: case-insensitive, colon first, prefix first" {
    const testing = std.testing;
    try testing.expect(titleLess("Close Tab", "copy to clipboard"));
    try testing.expect(titleLess("Focus: a", "Focus Bar"));
    try testing.expect(titleLess("New", "New Tab"));
    try testing.expect(!titleLess("New Tab", "new tab"));
    try testing.expect(!titleLess("new tab", "New Tab"));
}

test "palette filter: title, then the line beneath, then letters in order" {
    const testing = std.testing;
    try testing.expectEqual(@as(?u8, 0), rank("New Tab", "new_tab", ""));
    try testing.expectEqual(@as(?u8, 0), rank("New Tab", "new_tab", "new t"));
    try testing.expectEqual(@as(?u8, 1), rank("New Tab", "new_tab", "new_t"));
    try testing.expectEqual(@as(?u8, 1), rank("Focus: cmd.exe", "Tab 2: C:\\src", "src"));
    try testing.expectEqual(@as(?u8, 2), rank("Toggle Fullscreen", "toggle_fullscreen", "tgl full"));
    try testing.expectEqual(@as(?u8, null), rank("New Tab", "new_tab", "split"));
}

test "palette keycaps" {
    const testing = std.testing;
    var buf: [5][]const u8 = undefined;
    var n: usize = 0;
    var keys: Keys = .init("Ctrl+Shift++");
    while (keys.next()) |k| : (n += 1) buf[n] = k;
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("Ctrl", buf[0]);
    try testing.expectEqualStrings("Shift", buf[1]);
    try testing.expectEqualStrings("+", buf[2]);

    n = 0;
    keys = .init("Alt+Num +");
    while (keys.next()) |k| : (n += 1) buf[n] = k;
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("Num +", buf[1]);
}
