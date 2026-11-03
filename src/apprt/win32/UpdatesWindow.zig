//! The Updates window (roadmap 7.6a): Directory Opus's News and Updates
//! window and its Updates preferences, in murrtty's look (libadwaita's, as
//! the About dialog and the configuration editor draw it). One per murrtty
//! (App.updates_window), modeless: the terminals stay live while it is open
//! and while it checks (the check runs on update_fetch's thread).
//!
//! Pages: the main one (what murrtty knows, its buttons, what a check sends
//! while checks are off, the release history with unread releases bold), a
//! release's notes, Update Settings, and What a Check Sends. Opening it
//! never connects: only Check Now, Try Again, or automatic checks turned on
//! through the consent dialog do.
//!
//! Its controls are child windows (owner-drawn buttons, an owner-drawn list
//! box for the history, a read-only edit for the notes), so Tab, Enter,
//! Escape (App's loop runs IsDialogMessageW for it), screen readers and the
//! GUI tests work as with any dialog. Owner-drawn menus (ContextMenu.pick,
//! for How Often and When an Update Is Found) need WM_MEASUREITEM,
//! WM_DRAWITEM and WM_MENUCHAR forwarded, which it does.

const UpdatesWindow = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const build_config = @import("../../build_config.zig");
const c = @import("c.zig");
const draw = @import("draw.zig");
const text_util = @import("text.zig");
const App = @import("App.zig");
const AlertDialog = @import("AlertDialog.zig");
const ContextMenu = @import("ContextMenu.zig");
const ConfigEditor = @import("ConfigEditor.zig");
const Updates = @import("Updates.zig");
const update_list = @import("update_list.zig");
const update_fetch = @import("update_fetch.zig");
const test_hooks = @import("test_hooks.zig");

const log = std.log.scoped(.win32_updates_window);

pub const class_name = c.L("MurrttyUpdates");

/// The controls' ids, for the GUI tests.
pub const id_back = 200;
pub const id_primary = 210;
pub const id_secondary = 211;
pub const id_history = 220;
pub const id_settings = 230;
pub const id_read = 231;
pub const id_more = 232;
pub const id_close = 233;
pub const id_notes = 240;
pub const id_page_link = 241;
pub const id_auto = 250;
pub const id_interval = 251;
pub const id_on_found = 252;
pub const id_download = 253;
pub const id_stable = 254;
pub const id_tip = 255;
pub const id_privacy = 256;
pub const id_clear = 257;

pub const Page = enum { main, notes, settings, privacy };

/// What a check sends: the same words in this window, the consent dialog,
/// the README and on murrtty.org (roadmap 7.6).
pub const privacy_lines = [_][]const u8{
    "One request to murrtty.org, with no version, ID or cookie.",
    "Cloudflare, which serves murrtty.org, sees your IP address, as for any website. murrtty.org logs nothing.",
    "Downloads come from GitHub, only when you choose one.",
};

pub const consent_heading = "Check for Updates Automatically?";

/// Unscaled metrics, in DIP: libadwaita's (its preferences rows, cards and
/// buttons, as the configuration editor and About dialog use them). Both
/// sizes are cut to the monitor's work area (a 768-pixel screen at 125%
/// has 566 DIP), and Update Settings' rows tighten to fit the minimum.
const default_width = 560;
const default_height = 700;
const min_width = 460;
const min_height = 560;
const header_height = 46;
const header_button = 34;
const pad = 24;
const gap = 12;
const button_height = 34;
const button_pad_x = 18;
const button_radius = 6;
const row_height = 50;
const row_pad = 12;
const card_radius = 12;
const history_row = 44;
const bottom_height = 58;
const group_gap = 18;
const group_title = 28;
const switch_width = 46;
const switch_height = 26;

const Kind = enum { back, pill, accent, row, list, notes };

/// DRAWITEMSTRUCT's state: the keyboard's cues are hidden (no focus ring
/// until the keyboard is used, as Windows' own buttons).
const ODS_NOFOCUSRECT = c.ODS_NOFOCUSRECT;
const Trailing = enum { none, @"switch", value, check, chevron };

/// What a state button does.
const Action = enum { none, check_now, cancel, skip, download, turn_on };

const Control = struct {
    id: u16,
    /// null: on every page (the back button decides for itself).
    page: ?Page,
    kind: Kind,
    hwnd: ?c.HWND = null,
    rect: c.RECT = .{},
    label: []const u8 = "",
    subtitle: []const u8 = "",
    trailing: Trailing = .none,
    on: bool = false,
    value: []const u8 = "",
    shown: bool = true,
    enabled: bool = true,
};

app: *App,
hwnd: c.HWND,
/// The window has been made: until then a WM_NCDESTROY (a failed creation)
/// leaves freeing it to `create`.
created: bool = false,
page: Page = .main,
dpi: c.UINT = c.USER_DEFAULT_SCREEN_DPI,
dark: bool = false,
pal: draw.DialogPalette,
body_font: ?c.HFONT = null,
bold_font: ?c.HFONT = null,
heading_font: ?c.HFONT = null,
small_font: ?c.HFONT = null,
bg_brush: ?c.HBRUSH = null,
view_brush: ?c.HBRUSH = null,
controls: [18]Control = undefined,
/// The procedures the buttons and the notes had (Button's, Edit's).
button_proc: isize = 0,
edit_proc: isize = 0,
/// The notes' text as last set (hashed): set again only when it changes,
/// so a refresh keeps the reader's place.
notes_hash: u64 = 0,
/// The main page's texts, as the state says.
heading: [160]u8 = undefined,
heading_len: usize = 0,
subtitle: [320]u8 = undefined,
subtitle_len: usize = 0,
primary: Action = .none,
secondary: Action = .none,
/// Painted parts' places, from `layout`.
heading_rect: c.RECT = .{},
subtitle_rect: c.RECT = .{},
card_rect: c.RECT = .{},
history_label_rect: c.RECT = .{},
placeholder_rect: c.RECT = .{},
meta_rect: c.RECT = .{},
settings_cards: [3]c.RECT = @splat(.{}),
settings_titles: [3]c.RECT = @splat(.{}),
privacy_rect: c.RECT = .{},
/// The release whose notes show (owned), and its notes as shown.
notes_version: ?[]u8 = null,
notes_meta: [160]u8 = undefined,
notes_meta_len: usize = 0,
/// The history's versions in its order (owned), and which are bold.
history: std.ArrayList([]u8) = .empty,

pub fn registerClass(instance: c.HINSTANCE) !void {
    const wc: c.WNDCLASSEXW = .{
        .lpfnWndProc = &wndProc,
        .hInstance = instance,
        .hCursor = c.LoadCursorW(null, c.IDC_ARROW),
        .lpszClassName = class_name,
    };
    if (c.RegisterClassExW(&wc) == 0) return error.RegisterClassFailed;
}

/// Open the window, or bring it forward.
pub fn open(app: *App) void {
    if (app.updates_window) |w| return w.present();
    const self = create(app) catch |err| {
        log.warn("updates window not opened err={}", .{err});
        return;
    };
    app.updates_window = self;
}

pub fn present(self: *UpdatesWindow) void {
    if (c.IsIconic(self.hwnd) != 0) _ = c.ShowWindow(self.hwnd, c.SW_RESTORE);
    _ = c.SetForegroundWindow(self.hwnd);
}

/// Close it (murrtty is quitting).
pub fn destroy(self: *UpdatesWindow) void {
    _ = c.DestroyWindow(self.hwnd);
}

fn create(app: *App) !*UpdatesWindow {
    const alloc = app.core_app.alloc;
    const self = try alloc.create(UpdatesWindow);
    var owned = true;
    errdefer if (owned) alloc.destroy(self);
    self.* = .{ .app = app, .hwnd = undefined, .pal = draw.dialogPalette(false) };
    self.initControls();
    _ = c.CreateWindowExW(
        c.WS_EX_CONTROLPARENT,
        class_name,
        c.L("murrtty Updates"),
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
        // WM_NCDESTROY may have run: it left `self` to this errdefer, as
        // `created` was unset.
        return error.CreateWindowFailed;
    };
    owned = false;
    self.created = true;
    _ = c.ShowWindow(self.hwnd, c.SW_SHOWNORMAL);
    return self;
}

fn initControls(self: *UpdatesWindow) void {
    self.controls = .{
        .{ .id = id_back, .page = null, .kind = .back, .label = "Back" },
        .{ .id = id_primary, .page = .main, .kind = .accent, .label = "Check Now" },
        .{ .id = id_secondary, .page = .main, .kind = .pill, .label = "Turn On Automatic Checks..." },
        .{ .id = id_history, .page = .main, .kind = .list, .label = "Release history" },
        .{ .id = id_settings, .page = .main, .kind = .pill, .label = "Update &Settings" },
        .{ .id = id_read, .page = .main, .kind = .pill, .label = "&Read" },
        .{ .id = id_more, .page = .main, .kind = .pill, .label = "&More" },
        .{ .id = id_close, .page = null, .kind = .pill, .label = "&Close" },
        .{ .id = id_notes, .page = .notes, .kind = .notes, .label = "Release notes" },
        .{ .id = id_page_link, .page = .notes, .kind = .pill, .label = "&Open on GitHub" },
        .{ .id = id_auto, .page = .settings, .kind = .row, .label = "Check for updates &automatically", .subtitle = "Saved in your configuration as auto-update", .trailing = .@"switch" },
        .{ .id = id_interval, .page = .settings, .kind = .row, .label = "How &often", .trailing = .value },
        .{ .id = id_on_found, .page = .settings, .kind = .row, .label = "&When an update is found", .trailing = .value },
        .{ .id = id_download, .page = .settings, .kind = .row, .label = "&Download updates automatically", .subtitle = "Downloads and installs come in a later murrtty", .trailing = .@"switch", .enabled = false },
        .{ .id = id_stable, .page = .settings, .kind = .row, .label = "&Stable releases", .trailing = .check },
        .{ .id = id_tip, .page = .settings, .kind = .row, .label = "&Pre-releases", .subtitle = "None are published yet", .trailing = .check },
        .{ .id = id_privacy, .page = .settings, .kind = .row, .label = "What a check s&ends", .trailing = .chevron },
        .{ .id = id_clear, .page = .settings, .kind = .row, .label = "C&lear Cached Update Information", .subtitle = "The release list, and the releases skipped and read" },
    };
}

fn find(self: *UpdatesWindow, id: u16) ?*Control {
    for (&self.controls) |*ctl| if (ctl.id == id) return ctl;
    return null;
}

fn scale(self: *const UpdatesWindow, v: c_int) c_int {
    return draw.scale(self.dpi, v);
}

fn fromHwnd(hwnd: c.HWND) ?*UpdatesWindow {
    const ptr: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA));
    return if (ptr != 0) @ptrFromInt(ptr) else null;
}

// ---------------------------------------------------------------- the window

fn wndProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_NCCREATE => {
            const cs: *const c.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const self: *UpdatesWindow = @ptrCast(@alignCast(cs.lpCreateParams));
            self.hwnd = hwnd;
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        c.WM_CREATE => {
            const self = fromHwnd(hwnd) orelse return -1;
            self.onCreate() catch return -1;
            return 0;
        },
        c.WM_ERASEBKGND => return 1,
        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = undefined;
            const dc = c.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = c.EndPaint(hwnd, &ps);
            if (fromHwnd(hwnd)) |self| self.paint(dc);
            return 0;
        },
        c.WM_SIZE => {
            if (fromHwnd(hwnd)) |self| {
                self.layout();
                // Centered and right-aligned parts move: all of it again.
                _ = c.RedrawWindow(hwnd, null, null, c.RDW_INVALIDATE | c.RDW_ERASE | c.RDW_ALLCHILDREN);
            }
            return 0;
        },
        c.WM_GETMINMAXINFO => {
            if (fromHwnd(hwnd)) |self| {
                const info: *c.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
                const work = workArea(hwnd);
                info.ptMinTrackSize = .{
                    .x = @min(self.scale(min_width), work.right - work.left),
                    .y = @min(self.scale(min_height), work.bottom - work.top),
                };
            }
            return 0;
        },
        c.WM_DPICHANGED => {
            const self = fromHwnd(hwnd) orelse return 0;
            self.dpi = c.hiword(wparam);
            self.makeFonts();
            const r: *const c.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = c.SetWindowPos(hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
            self.applyFonts();
            self.layout();
            return 0;
        },
        c.WM_MEASUREITEM => {
            if (ContextMenu.measureItem(lparam)) return 1;
            const self = fromHwnd(hwnd) orelse return 0;
            const m: *c.MEASUREITEMSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (m.CtlType == c.ODT_LISTBOX) m.itemHeight = @intCast(self.scale(history_row));
            return 1;
        },
        c.WM_DRAWITEM => {
            if (ContextMenu.drawItem(lparam)) return 1;
            const self = fromHwnd(hwnd) orelse return 0;
            const item: *const c.DRAWITEMSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (item.CtlType == c.ODT_LISTBOX) self.drawHistoryRow(item) else self.drawControl(item);
            return 1;
        },
        c.WM_MENUCHAR => {
            if (ContextMenu.menuChar(wparam, lparam)) |r| return r;
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        c.WM_CTLCOLORSTATIC, c.WM_CTLCOLOREDIT, c.WM_CTLCOLORLISTBOX => {
            const self = fromHwnd(hwnd) orelse return 0;
            const dc: c.HDC = @ptrFromInt(wparam);
            _ = c.SetTextColor(dc, self.pal.text);
            _ = c.SetBkColor(dc, self.pal.view);
            return @bitCast(@intFromPtr(self.view_brush));
        },
        c.WM_COMMAND => {
            const self = fromHwnd(hwnd) orelse return 0;
            self.command(c.loword(wparam), c.hiword(wparam));
            return 0;
        },
        c.WM_SETTINGCHANGE, c.WM_THEMECHANGED => {
            if (fromHwnd(hwnd)) |self| self.themeChanged();
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        c.WM_DESTROY => {
            if (fromHwnd(hwnd)) |self| self.onDestroy();
            return 0;
        },
        c.WM_NCDESTROY => {
            const self = fromHwnd(hwnd) orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
            const app = self.app;
            const created = self.created;
            if (app.updates_window == self) app.updates_window = null;
            if (created) {
                self.free();
                app.updatesWindowClosed();
            }
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

fn onCreate(self: *UpdatesWindow) !void {
    const hwnd = self.hwnd;
    self.dpi = c.GetDpiForWindow(hwnd);
    self.themeColors();
    self.makeFonts();
    // The default size at the window's DPI, on the monitor's work area
    // whole (CW_USEDEFAULT cascades windows down and right).
    var wr: c.RECT = .{};
    _ = c.GetWindowRect(hwnd, &wr);
    const work = workArea(hwnd);
    const ww = @min(self.scale(default_width), work.right - work.left);
    const wh = @min(self.scale(default_height), work.bottom - work.top);
    const x = @max(work.left, @min(wr.left, work.right - ww));
    const y = @max(work.top, @min(wr.top, work.bottom - wh));
    _ = c.SetWindowPos(hwnd, null, x, y, ww, wh, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
    const instance = self.app.instance;
    for (&self.controls) |*ctl| {
        var wide: [96]u16 = undefined;
        const label = text_util.utf16Into(wide[0 .. wide.len - 1], ctl.label);
        wide[label.len] = 0;
        const text: [*:0]const u16 = @ptrCast(&wide);
        ctl.hwnd = switch (ctl.kind) {
            // Its rows keep their titles for screen readers; the item data
            // is the row's index in `history`.
            .list => c.CreateWindowExW(0, c.L("LISTBOX"), text, c.WS_CHILD | c.WS_TABSTOP | c.WS_VSCROLL |
                c.LBS_OWNERDRAWFIXED | c.LBS_HASSTRINGS | c.LBS_NOTIFY | c.LBS_NOINTEGRALHEIGHT, 0, 0, 10, 10, hwnd, @ptrFromInt(ctl.id), instance, null),
            .notes => c.CreateWindowExW(0, c.L("EDIT"), c.L(""), c.WS_CHILD | c.WS_TABSTOP | c.WS_VSCROLL |
                c.ES_MULTILINE | c.ES_READONLY | c.ES_AUTOVSCROLL, 0, 0, 10, 10, hwnd, @ptrFromInt(ctl.id), instance, null),
            else => c.CreateWindowExW(0, c.L("BUTTON"), text, c.WS_CHILD | c.WS_TABSTOP | c.BS_OWNERDRAW, 0, 0, 10, 10, hwnd, @ptrFromInt(ctl.id), instance, null),
        };
        if (ctl.kind == .list) continue;
        if (ctl.hwnd) |h| {
            const prev = c.SetWindowLongPtrW(h, c.GWLP_WNDPROC, @bitCast(@intFromPtr(&childProc)));
            const slot = if (ctl.kind == .notes) &self.edit_proc else &self.button_proc;
            if (slot.* == 0) slot.* = prev;
        }
    }
    self.applyFonts();
    self.themeControls();
    // Keyboard cues (focus rings, access keys) as Windows' setting says,
    // as a dialog starts: hidden until the keyboard is used.
    _ = c.SendMessageW(hwnd, WM_CHANGEUISTATE, UIS_INITIALIZE, 0);
    self.refresh();
    self.showPage(.main);
}

const WM_CHANGEUISTATE = 0x0127;
const UIS_INITIALIZE = 3;

fn onDestroy(self: *UpdatesWindow) void {
    // Each button's and the notes' own procedure back before they go.
    for (self.controls) |ctl| {
        if (ctl.kind == .list) continue;
        const proc = if (ctl.kind == .notes) self.edit_proc else self.button_proc;
        if (proc == 0) continue;
        if (ctl.hwnd) |h| _ = c.SetWindowLongPtrW(h, c.GWLP_WNDPROC, proc);
    }
}

/// The work area of the window's monitor.
fn workArea(hwnd: c.HWND) c.RECT {
    const big: c.RECT = .{ .right = std.math.maxInt(i16), .bottom = std.math.maxInt(i16) };
    const monitor = c.MonitorFromWindow(hwnd, c.MONITOR_DEFAULTTONEAREST) orelse return big;
    var info: c.MONITORINFO = .{};
    if (c.GetMonitorInfoW(monitor, &info) == 0) return big;
    return info.rcWork;
}

fn free(self: *UpdatesWindow) void {
    const alloc = self.app.core_app.alloc;
    for ([_]?c.HFONT{ self.body_font, self.bold_font, self.heading_font, self.small_font }) |f| if (f) |font| {
        _ = c.DeleteObject(font);
    };
    for ([_]?c.HBRUSH{ self.bg_brush, self.view_brush }) |b| if (b) |brush| {
        _ = c.DeleteObject(brush);
    };
    if (self.notes_version) |v| alloc.free(v);
    for (self.history.items) |v| alloc.free(v);
    self.history.deinit(alloc);
    alloc.destroy(self);
}

fn themeColors(self: *UpdatesWindow) void {
    self.dark = self.app.chromeTheme().dark;
    self.pal = draw.dialogPalette(self.dark);
    for ([_]*?c.HBRUSH{ &self.bg_brush, &self.view_brush }) |b| if (b.*) |brush| {
        _ = c.DeleteObject(brush);
        b.* = null;
    };
    self.bg_brush = c.CreateSolidBrush(self.pal.bg);
    self.view_brush = c.CreateSolidBrush(self.pal.view);
    const dark: c.BOOL = if (self.dark) c.TRUE else c.FALSE;
    _ = c.DwmSetWindowAttribute(self.hwnd, c.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, @sizeOf(c.BOOL));
    self.themeControls();
}

/// The list's and the notes' scroll bars in the window's light or dark.
fn themeControls(self: *UpdatesWindow) void {
    const theme: c.LPCWSTR = if (self.dark) c.L("DarkMode_Explorer") else c.L("Explorer");
    for (self.controls) |ctl| if (ctl.kind == .list or ctl.kind == .notes) if (ctl.hwnd) |h| {
        _ = c.SetWindowTheme(h, theme, null);
    };
}

fn themeChanged(self: *UpdatesWindow) void {
    self.themeColors();
    _ = c.RedrawWindow(self.hwnd, null, null, c.RDW_INVALIDATE | c.RDW_ERASE | c.RDW_ALLCHILDREN);
}

fn makeFonts(self: *UpdatesWindow) void {
    for ([_]*?c.HFONT{ &self.body_font, &self.bold_font, &self.heading_font, &self.small_font }) |f| if (f.*) |font| {
        _ = c.DeleteObject(font);
        f.* = null;
    };
    self.body_font = draw.chromeFont(self.dpi, null, false);
    self.bold_font = draw.chromeFont(self.dpi, null, true);
    self.heading_font = draw.chromeFontSized(self.dpi, null, 15, true);
    self.small_font = draw.chromeFontSized(self.dpi, null, 9, false);
}

fn applyFonts(self: *UpdatesWindow) void {
    for (self.controls) |ctl| if (ctl.hwnd) |h| {
        _ = c.SendMessageW(h, c.WM_SETFONT, @intFromPtr(self.body_font), 0);
    };
    if (self.find(id_history)) |ctl| if (ctl.hwnd) |h| {
        _ = c.SendMessageW(h, c.LB_SETITEMHEIGHT, 0, self.scale(history_row));
    };
}

// ---------------------------------------------------------------- what it shows

/// Show what Updates knows now (it calls this on every change).
pub fn refresh(self: *UpdatesWindow) void {
    // A config change may have changed window-theme.
    if (self.app.chromeTheme().dark != self.dark) self.themeColors();
    self.describe();
    self.settingsValues();
    self.fillHistory();
    if (self.page == .notes) self.showNotes();
    _ = self.applyVisibility();
    self.layout();
    _ = c.RedrawWindow(self.hwnd, null, null, c.RDW_INVALIDATE | c.RDW_ERASE | c.RDW_ALLCHILDREN);
}

fn setText(buf: []u8, len: *usize, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(buf, fmt, args) catch buf[0..0];
    len.* = s.len;
}

/// The main page's heading, subtitle and buttons for the state.
fn describe(self: *UpdatesWindow) void {
    const u = &self.app.updates;
    var running_buf: [64]u8 = undefined;
    const running = std.fmt.bufPrint(&running_buf, "{d}.{d}.{d}", .{ u.running.major, u.running.minor, u.running.patch }) catch "";
    var checked_buf: [96]u8 = undefined;
    const checked = checkedText(&checked_buf, u.state.last_check);
    const off = u.mode() == .off;
    // On in the configuration (written by hand, or copied from another
    // computer) but not agreed to here: no automatic check runs yet.
    const waiting = !off and !u.state.consent;
    const off_note: []const u8 = if (off) " Automatic checks are off." else if (waiting) " Automatic checks wait for your OK." else "";
    self.primary = .none;
    self.secondary = .none;
    if (!u.release_build) {
        setText(&self.heading, &self.heading_len, "This is a development build", .{});
        setText(&self.subtitle, &self.subtitle_len, "murrtty {s}. A development build's updates come from building the source, so it never checks.", .{build_config.version_string});
    } else switch (u.status) {
        .checking => {
            setText(&self.heading, &self.heading_len, "Checking for updates...", .{});
            setText(&self.subtitle, &self.subtitle_len, "Asking murrtty.org for its list of releases. Your terminals stay usable meanwhile.", .{});
            self.primary = .cancel;
        },
        .available => {
            const found = u.found.?;
            setText(&self.heading, &self.heading_len, "murrtty {s} is available", .{found.version});
            setText(&self.subtitle, &self.subtitle_len, "You have {s}. {s}.{s}", .{ running, checked, off_note });
            self.primary = .download;
            self.secondary = .skip;
        },
        .up_to_date => {
            setText(&self.heading, &self.heading_len, "murrtty is up to date", .{});
            setText(&self.subtitle, &self.subtitle_len, "You have {s}. {s}.{s}", .{ running, checked, off_note });
            self.primary = .check_now;
            if (off or waiting) self.secondary = .turn_on;
        },
        .failed => {
            var why_buf: [160]u8 = undefined;
            setText(&self.heading, &self.heading_len, "murrtty couldn't get its list of releases", .{});
            setText(&self.subtitle, &self.subtitle_len, "{s}{s}", .{ failureText(&why_buf, u), off_note });
            self.primary = .check_now;
            if (off or waiting) self.secondary = .turn_on;
        },
        .idle => if (off) {
            setText(&self.heading, &self.heading_len, "Update checks are off", .{});
            setText(&self.subtitle, &self.subtitle_len, "You have murrtty {s}. murrtty never connects to the internet on its own.", .{running});
            self.primary = .check_now;
            self.secondary = .turn_on;
        } else if (waiting) {
            setText(&self.heading, &self.heading_len, "Automatic checks wait for your OK", .{});
            setText(&self.subtitle, &self.subtitle_len, "You have murrtty {s}. Your configuration turns them on (auto-update = {t}), but murrtty asks on each computer before it checks on its own.", .{ running, u.mode() });
            self.primary = .check_now;
            self.secondary = .turn_on;
        } else {
            setText(&self.heading, &self.heading_len, "No check yet", .{});
            setText(&self.subtitle, &self.subtitle_len, "You have murrtty {s}. Automatic checks are on: the first comes a few minutes after murrtty starts.", .{running});
            self.primary = .check_now;
        },
    }
    for ([_]struct { u16, Action }{ .{ id_primary, self.primary }, .{ id_secondary, self.secondary } }) |entry| {
        const ctl = self.find(entry[0]).?;
        ctl.shown = entry[1] != .none;
        ctl.kind = if (entry[1] == .check_now or entry[1] == .download) .accent else .pill;
        // Access keys apart from each other's and Close's (C) on the page.
        ctl.label = switch (entry[1]) {
            .none => "",
            .check_now => if (u.status == .failed) "Try &Again" else "Check &Now",
            .cancel => "Ca&ncel",
            .skip => "S&kip This Version",
            .download => "&Download",
            .turn_on => "&Turn On Automatic Checks...",
        };
        self.setLabel(ctl);
    }
    const selected = self.selectedVersion();
    self.find(id_read).?.enabled = selected != null;
    self.find(id_more).?.enabled = selected != null;
}

fn failureText(buf: []u8, u: *const Updates) []const u8 {
    const code = u.last_error;
    return switch (u.last_outcome orelse .failed) {
        .http_error => std.fmt.bufPrint(buf, "murrtty.org answered {d}{s}. murrtty tries again later.", .{ u.last_status, if (u.last_status == 429 or u.last_status == 503) ", asking it to wait" else "" }) catch "",
        else => if (code == update_fetch.ERROR_WINHTTP_NAME_NOT_RESOLVED)
            "The name murrtty.org couldn't be found: no network, or a DNS problem."
        else if (code == update_fetch.ERROR_WINHTTP_CANNOT_CONNECT)
            "murrtty couldn't connect to murrtty.org (a firewall or proxy may block it)."
        else if (code == update_fetch.ERROR_WINHTTP_TIMEOUT)
            "murrtty.org didn't answer in time."
        else if (code == update_fetch.ERROR_WINHTTP_SECURE_FAILURE)
            "The secure connection to murrtty.org failed (its certificate, or a proxy in the way)."
        else if (code == 0)
            "The list murrtty got couldn't be read."
        else
            std.fmt.bufPrint(buf, "Windows reported error {d}.", .{code}) catch "",
    };
}

/// "Checked today at 09:14", "Checked yesterday at 09:14", "Checked on
/// Nov 3 at 09:14", or "Not checked yet".
fn checkedText(buf: []u8, unix: i64) []const u8 {
    if (unix <= 0) return "Not checked yet";
    const when = localTime(unix) orelse return "Checked";
    const today = localTime(Updates.unixNow()) orelse return "Checked";
    const day_s: i64 = 86400;
    const yesterday = localTime(Updates.unixNow() - day_s) orelse today;
    if (when.wYear == today.wYear and when.wMonth == today.wMonth and when.wDay == today.wDay)
        return std.fmt.bufPrint(buf, "Checked today at {d:0>2}:{d:0>2}", .{ when.wHour, when.wMinute }) catch "Checked";
    if (when.wYear == yesterday.wYear and when.wMonth == yesterday.wMonth and when.wDay == yesterday.wDay)
        return std.fmt.bufPrint(buf, "Checked yesterday at {d:0>2}:{d:0>2}", .{ when.wHour, when.wMinute }) catch "Checked";
    return std.fmt.bufPrint(buf, "Checked on {s} {d} at {d:0>2}:{d:0>2}", .{ monthName(when.wMonth), when.wDay, when.wHour, when.wMinute }) catch "Checked";
}

fn localTime(unix: i64) ?c.SYSTEMTIME {
    const ticks: u64 = @intCast(std.math.clamp(unix, 0, Updates.max_unix) * 10_000_000 + 116444736000000000);
    const ft: c.FILETIME = .{ .dwLowDateTime = @truncate(ticks), .dwHighDateTime = @truncate(ticks >> 32) };
    var local: c.FILETIME = undefined;
    if (c.FileTimeToLocalFileTime(&ft, &local) == 0) return null;
    var st: c.SYSTEMTIME = undefined;
    if (c.FileTimeToSystemTime(&local, &st) == 0) return null;
    return st;
}

fn monthName(m: u16) []const u8 {
    const names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    return if (m >= 1 and m <= 12) names[m - 1] else "";
}

/// A list date ("2026-11-20") as "Nov 20, 2026".
fn dateText(buf: []u8, date: []const u8) []const u8 {
    if (date.len < 10) return date;
    const y = date[0..4];
    const m = std.fmt.parseInt(u16, date[5..7], 10) catch return date;
    const d = std.fmt.parseInt(u16, date[8..10], 10) catch return date;
    return std.fmt.bufPrint(buf, "{s} {d}, {s}", .{ monthName(m), d, y }) catch date;
}

fn settingsValues(self: *UpdatesWindow) void {
    const u = &self.app.updates;
    const auto = self.find(id_auto).?;
    // On only when checks run: the configuration's, and the OK here.
    auto.on = u.mode() != .off and u.state.consent;
    auto.subtitle = if (u.mode() != .off and !u.state.consent)
        "On in your configuration: murrtty waits for your OK before checking"
    else
        "Saved in your configuration as auto-update";
    self.find(id_interval).?.value = switch (u.state.interval) {
        .daily => "Daily",
        .weekly => "Weekly",
        .monthly => "Monthly",
    };
    self.find(id_on_found).?.value = switch (u.state.on_found) {
        .notify => "Show a notification",
        .window => "Open this window",
    };
    const ch = u.channel();
    self.find(id_stable).?.on = ch == .stable;
    self.find(id_tip).?.on = ch == .tip;
    for ([_]u16{ id_interval, id_on_found, id_stable, id_tip, id_auto, id_clear }) |id| {
        self.find(id).?.enabled = u.release_build;
    }
    for (self.controls) |ctl| if (ctl.page == .settings) if (ctl.hwnd) |h| {
        _ = c.EnableWindow(h, if (ctl.enabled) c.TRUE else c.FALSE);
        _ = c.InvalidateRect(h, null, c.FALSE);
    };
}

/// The history list from the release list, newest first; the selection
/// and the scroll position kept. The same releases are only redrawn (one
/// read turns plain), so a refresh never moves the list under the reader.
fn fillHistory(self: *UpdatesWindow) void {
    const alloc = self.app.core_app.alloc;
    const list_hwnd = self.find(id_history).?.hwnd orelse return;
    if (self.sameHistory()) {
        _ = c.InvalidateRect(list_hwnd, null, c.FALSE);
        return;
    }
    const keep: ?[]u8 = if (self.selectedVersion()) |v| alloc.dupe(u8, v) catch null else null;
    defer if (keep) |k| alloc.free(k);
    const top = c.SendMessageW(list_hwnd, c.LB_GETTOPINDEX, 0, 0);
    for (self.history.items) |v| alloc.free(v);
    self.history.clearRetainingCapacity();
    _ = c.SendMessageW(list_hwnd, c.LB_RESETCONTENT, 0, 0);
    const list = self.app.updates.list orelse return;
    var select: ?usize = null;
    for (list.releases) |r| {
        if (!self.app.updates.channel().offers(r.channel)) continue;
        const v = alloc.dupe(u8, r.version) catch continue;
        self.history.append(alloc, v) catch {
            alloc.free(v);
            continue;
        };
        // The row's text is for screen readers; the row is drawn from
        // `history` by its index.
        var wide: [256]u16 = undefined;
        const name = text_util.utf16Into(wide[0 .. wide.len - 1], if (r.title.len > 0) r.title else r.version);
        wide[name.len] = 0;
        const row = c.SendMessageW(list_hwnd, c.LB_ADDSTRING, 0, @bitCast(@intFromPtr(&wide)));
        if (row < 0) {
            alloc.free(self.history.pop().?);
            continue;
        }
        _ = c.SendMessageW(list_hwnd, c.LB_SETITEMDATA, @intCast(row), @intCast(self.history.items.len - 1));
        if (keep) |k| if (std.mem.eql(u8, k, r.version)) {
            select = self.history.items.len - 1;
        };
    }
    if (select) |i| _ = c.SendMessageW(list_hwnd, c.LB_SETCURSEL, i, 0);
    if (top > 0) _ = c.SendMessageW(list_hwnd, c.LB_SETTOPINDEX, @intCast(top), 0);
}

/// Whether the history already lists the release list's releases on the
/// channel, in its order.
fn sameHistory(self: *const UpdatesWindow) bool {
    const list = self.app.updates.list orelse return self.history.items.len == 0;
    const ch = self.app.updates.channel();
    var i: usize = 0;
    for (list.releases) |r| {
        if (!ch.offers(r.channel)) continue;
        if (i >= self.history.items.len or !std.mem.eql(u8, self.history.items[i], r.version)) return false;
        i += 1;
    }
    return i == self.history.items.len;
}

fn selectedVersion(self: *UpdatesWindow) ?[]const u8 {
    const list_hwnd = self.find(id_history).?.hwnd orelse return null;
    const sel = c.SendMessageW(list_hwnd, c.LB_GETCURSEL, 0, 0);
    if (sel < 0) return null;
    const i: usize = @intCast(sel);
    return if (i < self.history.items.len) self.history.items[i] else null;
}

fn release(self: *UpdatesWindow, version: []const u8) ?update_list.Release {
    const list = self.app.updates.list orelse return null;
    for (list.releases) |r| if (std.mem.eql(u8, r.version, version)) return r;
    return null;
}

fn setLabel(self: *UpdatesWindow, ctl: *Control) void {
    _ = self;
    const h = ctl.hwnd orelse return;
    var wide: [96]u16 = undefined;
    const label = text_util.utf16Into(wide[0 .. wide.len - 1], ctl.label);
    wide[label.len] = 0;
    _ = c.SetWindowTextW(h, @ptrCast(&wide));
}

// ---------------------------------------------------------------- pages

fn showPage(self: *UpdatesWindow, page: Page) void {
    self.page = page;
    const first = self.applyVisibility();
    self.layout();
    if (first) |f| _ = c.SetFocus(f);
    _ = c.RedrawWindow(self.hwnd, null, null, c.RDW_INVALIDATE | c.RDW_ERASE | c.RDW_ALLCHILDREN);
}

/// Show the page's controls as the state says (a check's answer can bring
/// the history and change the state's buttons); the first shown, for the
/// keyboard.
fn applyVisibility(self: *UpdatesWindow) ?c.HWND {
    var first: ?c.HWND = null;
    for (self.controls) |ctl| {
        const h = ctl.hwnd orelse continue;
        const shown = switch (ctl.id) {
            id_back => self.page != .main,
            id_close => true,
            id_history => self.page == .main and self.app.updates.list != null,
            else => ctl.page == self.page and ctl.shown,
        };
        // The keyboard leaves a control about to hide.
        if (!shown and c.GetFocus() == h) _ = c.SetFocus(self.hwnd);
        _ = c.ShowWindow(h, if (shown) c.SW_SHOWNA else c.SW_HIDE);
        if (shown and first == null and ctl.id != id_back and ctl.id != id_close) first = h;
    }
    return first;
}

/// The selected release's notes, read in the window; marks it read.
fn openNotes(self: *UpdatesWindow) void {
    const version = self.selectedVersion() orelse return;
    const alloc = self.app.core_app.alloc;
    const copy = alloc.dupe(u8, version) catch return;
    if (self.notes_version) |v| alloc.free(v);
    self.notes_version = copy;
    // Opened afresh: from the top.
    self.notes_hash = 0;
    self.app.updates.markRead(copy);
    self.showPage(.notes);
    self.showNotes();
}

fn showNotes(self: *UpdatesWindow) void {
    const alloc = self.app.core_app.alloc;
    const version = self.notes_version orelse return;
    const r = self.release(version) orelse return;
    var date_buf: [32]u8 = undefined;
    setText(&self.notes_meta, &self.notes_meta_len, "Released {s}{s}", .{ dateText(&date_buf, r.date), if (r.preview) " \u{b7} preview" else "" });
    const edit = self.find(id_notes).?.hwnd orelse return;
    const text = notesText(alloc, r.notes orelse "") catch return;
    defer alloc.free(text);
    const shown: []const u8 = if (text.len == 0) "These notes are on the release's page: Open on GitHub." else text;
    // Set again only when they change: setting them scrolls to the top.
    const hash = std.hash.Wyhash.hash(1, shown);
    if (hash != self.notes_hash) {
        const wide = text_util.utf16Lossy(alloc, shown) catch return;
        defer alloc.free(wide);
        _ = c.SetWindowTextW(edit, wide.ptr);
        self.notes_hash = hash;
    }
    self.layout();
    _ = c.InvalidateRect(self.hwnd, null, c.TRUE);
}

/// Release notes' Markdown as plain text for the edit: headings as their
/// own lines, list items with bullets, emphasis and code marks dropped,
/// links as their text with the address after; CRLF line ends.
pub fn notesText(alloc: Allocator, md: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var lines = std.mem.splitScalar(u8, md, '\n');
    var first = true;
    while (lines.next()) |raw| {
        var line = std.mem.trimEnd(u8, raw, "\r");
        if (!first) try out.appendSlice(alloc, "\r\n");
        first = false;
        const trimmed = std.mem.trimStart(u8, line, " ");
        var heading = false;
        if (std.mem.startsWith(u8, trimmed, "#")) {
            line = std.mem.trimStart(u8, std.mem.trimStart(u8, trimmed, "#"), " ");
            heading = true;
        } else if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ")) {
            try out.appendSlice(alloc, line[0 .. line.len - trimmed.len]);
            try out.appendSlice(alloc, "\u{2022} ");
            line = trimmed[2..];
        }
        try inline_text(alloc, &out, line);
        // A heading stands apart: a blank line after it, unless one follows.
        if (heading) if (lines.peek()) |next| {
            if (std.mem.trim(u8, next, " \r").len > 0) try out.appendSlice(alloc, "\r\n");
        };
    }
    return out.toOwnedSlice(alloc);
}

fn inline_text(alloc: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const ch = s[i];
        if (ch == '*' or ch == '`' or ch == '_' and (i + 1 < s.len and s[i + 1] == '_')) {
            i += 1;
            continue;
        }
        if (ch == '[') if (std.mem.indexOfScalarPos(u8, s, i, ']')) |close| {
            if (close + 1 < s.len and s[close + 1] == '(') if (std.mem.indexOfScalarPos(u8, s, close, ')')) |end| {
                try inline_text(alloc, out, s[i + 1 .. close]);
                try out.appendSlice(alloc, " (");
                try out.appendSlice(alloc, s[close + 2 .. end]);
                try out.append(alloc, ')');
                i = end + 1;
                continue;
            };
        };
        try out.append(alloc, ch);
        i += 1;
    }
}

// ---------------------------------------------------------------- actions

fn command(self: *UpdatesWindow, id: u16, code: u16) void {
    switch (id) {
        id_history => switch (code) {
            c.LBN_DBLCLK => self.openNotes(),
            c.LBN_SELCHANGE => {
                const on = self.selectedVersion() != null;
                for ([_]u16{ id_read, id_more }) |b| {
                    self.find(b).?.enabled = on;
                    if (self.find(b).?.hwnd) |h| _ = c.InvalidateRect(h, null, c.FALSE);
                }
            },
            else => {},
        },
        // Escape, as IsDialogMessage sends it: back, else close.
        c.IDCANCEL => if (self.page != .main) self.back() else self.destroy(),
        // Enter, which IsDialogMessage sends as IDOK (no button is the
        // default, and owner-drawn ones aren't push buttons to it).
        c.IDOK => self.enter(),
        else => if (code == c.BN_CLICKED) self.click(id),
    }
}

/// Enter: what the focused control does, as a click on it (a double
/// click in the history).
fn enter(self: *UpdatesWindow) void {
    const focus = c.GetFocus() orelse return;
    const parent = c.GetParent(focus) orelse return;
    if (parent != self.hwnd) return;
    const id = c.GetDlgCtrlID(focus);
    if (id <= 0 or id > std.math.maxInt(u16)) return;
    const control: u16 = @intCast(id);
    switch (control) {
        id_history => self.openNotes(),
        id_notes => {},
        else => self.click(control),
    }
}

fn back(self: *UpdatesWindow) void {
    self.showPage(if (self.page == .privacy) .settings else .main);
}

fn click(self: *UpdatesWindow, id: u16) void {
    const u = &self.app.updates;
    if (self.find(id)) |ctl| if (!ctl.enabled) return;
    switch (id) {
        id_back => self.back(),
        id_close => self.destroy(),
        id_primary => self.act(self.primary),
        id_secondary => self.act(self.secondary),
        id_settings => self.showPage(.settings),
        id_read => self.openNotes(),
        id_more => if (self.selectedVersion()) |v| self.openPage(v),
        id_page_link => if (self.notes_version) |v| self.openPage(v),
        id_auto => if (u.mode() != .off and u.state.consent) self.setConfig("auto-update", "off") else self.turnOn(),
        id_interval => {
            const labels = [_][]const u8{ "Daily", "Weekly", "Monthly" };
            const now = @intFromEnum(u.state.interval);
            var checked = [_]bool{ false, false, false };
            checked[now] = true;
            if (self.pickAt(id, &labels, &checked)) |i| u.setInterval(@enumFromInt(i));
        },
        id_on_found => {
            const labels = [_][]const u8{ "Show a notification", "Open this window" };
            var checked = [_]bool{ u.state.on_found == .notify, u.state.on_found == .window };
            if (self.pickAt(id, &labels, &checked)) |i| u.setOnFound(if (i == 0) .notify else .window);
        },
        id_stable => if (u.channel() != .stable) self.setConfig("auto-update-channel", "stable"),
        id_tip => if (u.channel() != .tip) self.setConfig("auto-update-channel", "tip"),
        id_privacy => self.showPage(.privacy),
        id_clear => u.clearCache(),
        else => {},
    }
}

fn act(self: *UpdatesWindow, action: Action) void {
    const u = &self.app.updates;
    switch (action) {
        .none => {},
        .check_now => u.checkNow(),
        .cancel => u.cancel(),
        .skip => if (u.found) |f| u.skip(f.version),
        // 7.6a: the release's page (7.6b downloads and verifies the file).
        .download => if (u.found) |f| self.openPage(f.version),
        .turn_on => self.turnOn(),
    }
}

/// The release's page on GitHub. The list is not trusted to name what
/// opens: only murrtty's own releases' pages do.
pub const release_pages = "https://github.com/murr2k/murrtty/releases/";

/// Whether `url` is one of murrtty's releases' pages: `release_pages`,
/// `tag/` and a tag of letters, digits, '.', '-' and '_' only. No '/',
/// '\', '%', query or dot segment a browser would resolve to another page
/// of github.com.
pub fn releasePageOk(url: []const u8) bool {
    const prefix = release_pages ++ "tag/";
    if (!std.mem.startsWith(u8, url, prefix)) return false;
    const tag = url[prefix.len..];
    if (tag.len == 0 or tag.len > 128) return false;
    if (std.mem.eql(u8, tag, ".") or std.mem.eql(u8, tag, "..")) return false;
    for (tag) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-' or ch == '_')) return false;
    return true;
}

fn openPage(self: *UpdatesWindow, version: []const u8) void {
    const r = self.release(version) orelse return;
    if (!releasePageOk(r.url)) {
        log.warn("a release page outside murrtty's releases not opened: {s}", .{r.url});
        return;
    }
    const alloc = self.app.core_app.alloc;
    const value = alloc.dupe(u8, r.url) catch return;
    defer alloc.free(value);
    self.app.launch(self.hwnd, .{ .value = value, .item = false });
}

/// A choice menu under a row's value.
fn pickAt(self: *UpdatesWindow, id: u16, labels: []const []const u8, checked: []const bool) ?usize {
    const ctl = self.find(id) orelse return null;
    const h = ctl.hwnd orelse return null;
    var r: c.RECT = .{};
    _ = c.GetWindowRect(h, &r);
    return ContextMenu.pick(self.app, self.hwnd, .{ .x = r.right - self.scale(row_pad + 160), .y = r.bottom }, labels, checked);
}

/// Turning automatic checks on: the consent dialog first, every time.
/// Turn On records the consent (this machine's) and writes auto-update =
/// check to the configuration file murrtty loaded, if it says off.
fn turnOn(self: *UpdatesWindow) void {
    const u = &self.app.updates;
    const alloc = self.app.core_app.alloc;
    const how_often: []const u8 = switch (u.state.interval) {
        .daily => "once a day",
        .weekly => "once a week",
        .monthly => "once a month",
    };
    const body = std.fmt.allocPrint(alloc,
        \\murrtty will ask murrtty.org for its list of releases {s}, and tell you when there is a new one.
        \\
        \\The request carries no version, ID or cookie. Cloudflare, which serves murrtty.org, sees your IP address, as for any website; murrtty.org logs nothing.
        \\
        \\Nothing is downloaded or installed unless you choose it. You can turn this off in Update Settings at any time.
    , .{how_often}) catch return;
    defer alloc.free(body);
    const result = r: {
        var modal = self.app.beginModal(self.hwnd, .{});
        defer modal.end();
        break :r AlertDialog.run(alloc, .{
            .owner = self.hwnd,
            .heading = consent_heading,
            .body = body,
            .responses = &.{
                .{ .id = c.IDCANCEL, .label = "Cancel" },
                .{ .id = c.IDOK, .label = "Turn On", .appearance = .suggested },
            },
            // Enter doesn't agree for you.
            .default = c.IDCANCEL,
            .dark = self.dark,
        });
    };
    const answer = result orelse return;
    if (answer.text) |t| alloc.free(t);
    if (answer.id != c.IDOK) return;
    u.setConsent(true);
    if (u.mode() == .off) self.setConfig("auto-update", "check");
}

/// Write one option to the configuration file murrtty loaded (the
/// configuration editor's in-place edit), then reload.
fn setConfig(self: *UpdatesWindow, name: []const u8, value: []const u8) void {
    // Nothing of the window's is read after a dialog's loop.
    const app = self.app;
    const hwnd = self.hwnd;
    const alloc = app.core_app.alloc;
    ConfigEditor.setOption(app, name, value) catch |err| {
        log.warn("{s} not written err={}", .{ name, err });
        // The editor's own dialog said what it couldn't read.
        if (err == error.Reported) return;
        var modal = app.beginModal(hwnd, .{});
        defer modal.end();
        const msg = std.fmt.allocPrint(alloc, "murrtty couldn't save {s} to your configuration ({t}).", .{ name, err }) catch return;
        defer alloc.free(msg);
        _ = @import("Surface.zig").messageBox(alloc, hwnd, msg, "murrtty Updates", c.MB_OK | c.MB_ICONWARNING);
    };
}

// ---------------------------------------------------------------- layout and painting

fn layout(self: *UpdatesWindow) void {
    var client: c.RECT = .{};
    _ = c.GetClientRect(self.hwnd, &client);
    const w = client.right;
    const h = client.bottom;
    const p = self.scale(pad);
    const g = self.scale(gap);
    const bh = self.scale(button_height);
    const dc = c.GetDC(self.hwnd) orelse return;
    defer _ = c.ReleaseDC(self.hwnd, dc);

    // The header's back button; the bottom bar's buttons.
    const hb = self.scale(header_button);
    const hp = self.scale((header_height - header_button) / 2);
    self.place(id_back, .{ .left = hp, .top = hp, .right = hp + hb, .bottom = hp + hb });
    const bottom_top = h - self.scale(bottom_height) + @divTrunc(self.scale(bottom_height) - bh, 2);
    var right = w - p;
    right = self.placeButton(dc, id_close, right, bottom_top, true);
    if (self.page == .main) {
        right = self.placeButton(dc, id_more, right - g, bottom_top, true);
        _ = self.placeButton(dc, id_read, right - g, bottom_top, true);
        _ = self.placeButton(dc, id_settings, p, bottom_top, false);
    } else if (self.page == .notes) {
        _ = self.placeButton(dc, id_page_link, right - g, bottom_top, true);
    }
    const content_bottom = h - self.scale(bottom_height);

    var y = self.scale(header_height) + self.scale(12);
    switch (self.page) {
        .main => {
            const tw = w - 2 * p;
            const hh = textHeight(dc, self.heading_font, self.heading[0..self.heading_len], tw);
            self.heading_rect = .{ .left = p, .top = y, .right = w - p, .bottom = y + hh };
            y += hh + self.scale(6);
            const sh = textHeight(dc, self.body_font, self.subtitle[0..self.subtitle_len], tw);
            self.subtitle_rect = .{ .left = p, .top = y, .right = w - p, .bottom = y + sh };
            y += sh + self.scale(14);
            var x = p;
            for ([_]u16{ id_primary, id_secondary }) |id| {
                const ctl = self.find(id).?;
                if (!ctl.shown) continue;
                x = self.placeButton(dc, id, x, y, false) + g;
            }
            if (self.find(id_primary).?.shown or self.find(id_secondary).?.shown) y += bh + self.scale(18);
            // What a check sends, while automatic checks don't run (off,
            // or waiting for the OK here).
            if (self.app.updates.mode() == .off or !self.app.updates.state.consent) {
                const lines_h = self.privacyHeight(dc, tw - 2 * self.scale(row_pad), true);
                self.card_rect = .{ .left = p, .top = y, .right = w - p, .bottom = y + lines_h + 2 * self.scale(row_pad) };
                y = self.card_rect.bottom + self.scale(18);
            } else self.card_rect = .{};
            self.history_label_rect = .{ .left = p, .top = y, .right = w - p, .bottom = y + self.scale(group_title) };
            y += self.scale(group_title);
            const list_rect: c.RECT = .{ .left = p, .top = y, .right = w - p, .bottom = @max(y + self.scale(history_row), content_bottom - self.scale(6)) };
            self.place(id_history, list_rect);
            self.placeholder_rect = list_rect;
        },
        .notes => {
            const mh = textHeight(dc, self.body_font, self.notes_meta[0..self.notes_meta_len], w - 2 * p);
            self.meta_rect = .{ .left = p, .top = y, .right = w - p, .bottom = y + mh };
            y += mh + self.scale(12);
            self.card_rect = .{ .left = p, .top = y, .right = w - p, .bottom = @max(y + self.scale(80), content_bottom - self.scale(6)) };
            const rp = self.scale(row_pad);
            self.place(id_notes, .{ .left = self.card_rect.left + rp, .top = self.card_rect.top + rp, .right = self.card_rect.right - self.scale(4), .bottom = self.card_rect.bottom - rp });
        },
        .settings => {
            const groups = [_][]const u16{
                &.{ id_auto, id_interval, id_on_found, id_download },
                &.{ id_stable, id_tip },
                &.{ id_privacy, id_clear },
            };
            const rows = 8;
            // Short of room (the minimum size, or a small screen's work
            // area): tighter titles and gaps, rows down to 36 DIP.
            const room = content_bottom - y;
            const full = 3 * self.scale(group_title) + 2 * self.scale(group_gap) + rows * self.scale(row_height);
            const tight = room < full;
            const title_h = self.scale(if (tight) 24 else group_title);
            const gap_h = self.scale(if (tight) 8 else group_gap);
            const rh = if (tight)
                std.math.clamp(@divTrunc(room - 3 * title_h - 2 * gap_h, rows), self.scale(36), self.scale(row_height))
            else
                self.scale(row_height);
            for (groups, 0..) |ids, gi| {
                self.settings_titles[gi] = .{ .left = p, .top = y, .right = w - p, .bottom = y + title_h };
                y += title_h;
                const top = y;
                for (ids) |id| {
                    self.place(id, .{ .left = p, .top = y, .right = w - p, .bottom = y + rh });
                    y += rh;
                }
                self.settings_cards[gi] = .{ .left = p, .top = top, .right = w - p, .bottom = y };
                y += gap_h;
            }
        },
        .privacy => {
            self.privacy_rect = .{ .left = p, .top = y, .right = w - p, .bottom = content_bottom };
        },
    }
}

fn place(self: *UpdatesWindow, id: u16, r: c.RECT) void {
    const ctl = self.find(id) orelse return;
    ctl.rect = r;
    if (ctl.hwnd) |h| _ = c.SetWindowPos(h, null, r.left, r.top, r.right - r.left, r.bottom - r.top, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
}

/// A button sized to its label, at `x` (its right edge when `from_right`);
/// returns its other edge.
fn placeButton(self: *UpdatesWindow, dc: c.HDC, id: u16, x: c_int, y: c_int, from_right: bool) c_int {
    const ctl = self.find(id) orelse return x;
    var label_buf: [96]u8 = undefined;
    const label = stripAccess(&label_buf, ctl.label);
    const bw = textWidth(dc, self.bold_font, label) + 2 * self.scale(button_pad_x);
    const bh = self.scale(button_height);
    const left = if (from_right) x - bw else x;
    self.place(id, .{ .left = left, .top = y, .right = left + bw, .bottom = y + bh });
    return if (from_right) left else left + bw;
}

fn privacyHeight(self: *UpdatesWindow, dc: c.HDC, w: c_int, heading: bool) c_int {
    var hgt: c_int = if (heading) textHeight(dc, self.bold_font, "What a check sends", w) + self.scale(6) else 0;
    for (privacy_lines) |l| hgt += textHeight(dc, self.body_font, l, w - self.scale(16)) + self.scale(4);
    return hgt;
}

fn paint(self: *UpdatesWindow, dc: c.HDC) void {
    var client: c.RECT = .{};
    _ = c.GetClientRect(self.hwnd, &client);
    draw.fill(dc, client, self.pal.bg);
    _ = c.SetBkMode(dc, c.TRANSPARENT);
    _ = c.SetTextColor(dc, self.pal.text);
    const title: []const u8 = switch (self.page) {
        .main => "Updates",
        .notes => if (self.notes_version) |v| (if (self.release(v)) |r| r.title else v) else "Release",
        .settings => "Update Settings",
        .privacy => "What a Check Sends",
    };
    drawText(dc, self.bold_font, title, .{ .left = 0, .top = 0, .right = client.right, .bottom = self.scale(header_height) }, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX | c.DT_END_ELLIPSIS);
    switch (self.page) {
        .main => {
            drawText(dc, self.heading_font, self.heading[0..self.heading_len], self.heading_rect, c.DT_LEFT | c.DT_WORDBREAK | c.DT_NOPREFIX);
            _ = c.SetTextColor(dc, self.pal.subtitle);
            drawText(dc, self.body_font, self.subtitle[0..self.subtitle_len], self.subtitle_rect, c.DT_LEFT | c.DT_WORDBREAK | c.DT_NOPREFIX);
            _ = c.SetTextColor(dc, self.pal.text);
            if (self.card_rect.bottom > self.card_rect.top) self.paintPrivacy(dc, self.card_rect, true);
            drawText(dc, self.bold_font, "Release history", self.history_label_rect, c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX);
            if (self.app.updates.list == null) {
                draw.roundRect(dc, self.placeholder_rect, self.scale(card_radius), self.pal.card, null, 0);
                _ = c.SetTextColor(dc, self.pal.subtitle);
                const msg: []const u8 = if (self.app.updates.release_build) "Check once to see the releases and their notes." else "A development build lists no releases.";
                drawText(dc, self.body_font, msg, self.placeholder_rect, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX);
            }
        },
        .notes => {
            _ = c.SetTextColor(dc, self.pal.subtitle);
            drawText(dc, self.body_font, self.notes_meta[0..self.notes_meta_len], self.meta_rect, c.DT_LEFT | c.DT_WORDBREAK | c.DT_NOPREFIX);
            draw.roundRect(dc, self.card_rect, self.scale(card_radius), self.pal.view, null, 0);
        },
        .settings => {
            const titles = [_][]const u8{ "Automatic updates", "Release channel", "Privacy" };
            for (titles, 0..) |t, i| {
                _ = c.SetTextColor(dc, self.pal.text);
                drawText(dc, self.bold_font, t, self.settings_titles[i], c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX);
                draw.roundRect(dc, self.settings_cards[i], self.scale(card_radius), self.pal.card, null, 0);
            }
        },
        .privacy => {
            var r = self.privacy_rect;
            const intro = "Update checks are off unless you turn them on. A check you start, or an automatic one, sends:";
            const ih = textHeight(dc, self.body_font, intro, r.right - r.left);
            drawText(dc, self.body_font, intro, r, c.DT_LEFT | c.DT_WORDBREAK | c.DT_NOPREFIX);
            r.top += ih + self.scale(12);
            r.bottom = r.top + self.privacyHeight(dc, r.right - r.left - 2 * self.scale(row_pad), false) + 2 * self.scale(row_pad);
            self.paintPrivacy(dc, r, false);
        },
    }
}

/// What a check sends, in a card: a heading (unless `heading` is false)
/// and the three lines with bullets.
fn paintPrivacy(self: *UpdatesWindow, dc: c.HDC, card: c.RECT, heading: bool) void {
    draw.roundRect(dc, card, self.scale(card_radius), self.pal.card, null, 0);
    const rp = self.scale(row_pad);
    var r: c.RECT = .{ .left = card.left + rp, .top = card.top + rp, .right = card.right - rp, .bottom = card.bottom - rp };
    _ = c.SetTextColor(dc, self.pal.text);
    if (heading) {
        const hh = textHeight(dc, self.bold_font, "What a check sends", r.right - r.left);
        drawText(dc, self.bold_font, "What a check sends", r, c.DT_LEFT | c.DT_NOPREFIX | c.DT_SINGLELINE);
        r.top += hh + self.scale(6);
    }
    for (privacy_lines) |l| {
        const lh = textHeight(dc, self.body_font, l, r.right - r.left - self.scale(16));
        drawText(dc, self.body_font, "\u{2022}", .{ .left = r.left, .top = r.top, .right = r.left + self.scale(16), .bottom = r.top + lh }, c.DT_LEFT | c.DT_NOPREFIX | c.DT_SINGLELINE);
        drawText(dc, self.body_font, l, .{ .left = r.left + self.scale(16), .top = r.top, .right = r.right, .bottom = r.top + lh }, c.DT_LEFT | c.DT_WORDBREAK | c.DT_NOPREFIX);
        r.top += lh + self.scale(4);
    }
}

fn drawControl(self: *UpdatesWindow, item: *const c.DRAWITEMSTRUCT) void {
    const ctl = self.find(@intCast(item.CtlID)) orelse return;
    const dc = item.hDC;
    const r = item.rcItem;
    const pressed = item.itemState & c.ODS_SELECTED != 0;
    const focused = item.itemState & c.ODS_FOCUS != 0 and item.itemState & ODS_NOFOCUSRECT == 0;
    // The window's background behind rounded shapes.
    draw.fill(dc, r, self.pal.bg);
    _ = c.SetBkMode(dc, c.TRANSPARENT);
    var label_buf: [96]u8 = undefined;
    const label = stripAccess(&label_buf, ctl.label);
    switch (ctl.kind) {
        .back => {
            if (pressed) draw.roundRect(dc, r, self.scale(button_radius), self.pal.button_pressed, null, 0);
            chevron(dc, r, true, self.pal.text, self.dpi);
        },
        .pill, .accent => {
            const accent = ctl.kind == .accent;
            const fill = if (accent)
                (if (pressed) self.pal.suggested_pressed else self.pal.suggested)
            else if (pressed) self.pal.button_pressed else self.pal.button;
            draw.roundRect(dc, r, self.scale(button_radius), fill, null, 0);
            _ = c.SetTextColor(dc, if (!ctl.enabled) self.pal.subtitle else if (accent) self.pal.suggested_text else self.pal.text);
            drawText(dc, self.bold_font, label, r, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX);
        },
        .row => {
            // A row draws its part of the card: the card's rounded corners
            // on its first and last rows, a line below all but the last.
            const fill = if (pressed and ctl.enabled) self.pal.button_hover else self.pal.card;
            const where = self.cardPlace(ctl.id);
            const radius = self.scale(card_radius);
            const half = @divTrunc(r.bottom - r.top, 2);
            if (where.first or where.last) {
                draw.roundRect(dc, r, radius, fill, null, 0);
                if (!where.first) draw.fill(dc, .{ .left = r.left, .top = r.top, .right = r.right, .bottom = r.top + half }, fill);
                if (!where.last) draw.fill(dc, .{ .left = r.left, .top = r.top + half, .right = r.right, .bottom = r.bottom }, fill);
            } else draw.fill(dc, r, fill);
            const rp = self.scale(row_pad);
            const trail_w = switch (ctl.trailing) {
                .none => 0,
                .@"switch" => self.scale(switch_width) + rp,
                .value => textWidth(dc, self.body_font, ctl.value) + self.scale(20) + rp,
                .check, .chevron => self.scale(24) + rp,
            };
            var tr: c.RECT = .{ .left = r.left + rp, .top = r.top, .right = r.right - rp - trail_w, .bottom = r.bottom };
            _ = c.SetTextColor(dc, if (ctl.enabled) self.pal.text else self.pal.subtitle);
            if (ctl.subtitle.len > 0) {
                const th = textHeight(dc, self.body_font, label, tr.right - tr.left);
                const sh = textHeight(dc, self.small_font, ctl.subtitle, tr.right - tr.left);
                const top = r.top + @divTrunc(r.bottom - r.top - th - sh, 2);
                drawText(dc, self.body_font, label, .{ .left = tr.left, .top = top, .right = tr.right, .bottom = top + th }, c.DT_LEFT | c.DT_SINGLELINE | c.DT_NOPREFIX | c.DT_END_ELLIPSIS);
                _ = c.SetTextColor(dc, self.pal.subtitle);
                drawText(dc, self.small_font, ctl.subtitle, .{ .left = tr.left, .top = top + th, .right = tr.right, .bottom = top + th + sh }, c.DT_LEFT | c.DT_SINGLELINE | c.DT_NOPREFIX | c.DT_END_ELLIPSIS);
            } else {
                drawText(dc, self.body_font, label, tr, c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX | c.DT_END_ELLIPSIS);
            }
            tr = .{ .left = r.right - rp - trail_w + rp, .top = r.top, .right = r.right - rp, .bottom = r.bottom };
            switch (ctl.trailing) {
                .none => {},
                .@"switch" => {
                    const sw = self.scale(switch_width);
                    const sh = self.scale(switch_height);
                    const sr: c.RECT = .{ .left = r.right - rp - sw, .top = r.top + @divTrunc(r.bottom - r.top - sh, 2), .right = r.right - rp, .bottom = r.top + @divTrunc(r.bottom - r.top - sh, 2) + sh };
                    draw.roundRect(dc, sr, @divTrunc(sh, 2), if (ctl.on and ctl.enabled) self.pal.switch_on else self.pal.switch_off, null, 0);
                    const k = sh - self.scale(6);
                    const kx = if (ctl.on) sr.right - self.scale(3) - k else sr.left + self.scale(3);
                    draw.roundRect(dc, .{ .left = kx, .top = sr.top + self.scale(3), .right = kx + k, .bottom = sr.top + self.scale(3) + k }, @divTrunc(k, 2), self.pal.knob, null, 0);
                },
                .value => {
                    _ = c.SetTextColor(dc, self.pal.subtitle);
                    drawText(dc, self.body_font, ctl.value, .{ .left = tr.left, .top = r.top, .right = r.right - rp - self.scale(20), .bottom = r.bottom }, c.DT_RIGHT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX);
                    draw.triangleDown(dc, r.right - rp - self.scale(8), r.top + @divTrunc(r.bottom - r.top, 2) - self.scale(2), self.scale(4), self.scale(4), self.pal.subtitle);
                },
                .check => if (ctl.on) {
                    _ = c.SetTextColor(dc, self.pal.switch_on);
                    drawText(dc, self.bold_font, "\u{2713}", .{ .left = r.right - rp - self.scale(24), .top = r.top, .right = r.right - rp, .bottom = r.bottom }, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX);
                },
                .chevron => chevron(dc, .{ .left = r.right - rp - self.scale(24), .top = r.top, .right = r.right - rp, .bottom = r.bottom }, false, self.pal.subtitle, self.dpi),
            }
            if (!where.last) draw.line(dc, r.left, r.bottom - 1, r.right, r.bottom - 1, self.pal.bg, 1);
        },
        .list, .notes => {},
    }
    if (focused) draw.roundRect(dc, r, self.scale(button_radius), null, self.pal.focus, self.scale(2));
}

/// Where a settings row sits in its card.
fn cardPlace(self: *const UpdatesWindow, id: u16) struct { first: bool, last: bool } {
    _ = self;
    return .{
        .first = id == id_auto or id == id_stable or id == id_privacy,
        .last = id == id_download or id == id_tip or id == id_clear,
    };
}

/// A release in the history: its title (bold until its notes are read),
/// its date and, for the version running, Installed.
fn drawHistoryRow(self: *UpdatesWindow, item: *const c.DRAWITEMSTRUCT) void {
    const dc = item.hDC;
    const r = item.rcItem;
    const selected = item.itemState & c.ODS_SELECTED != 0;
    draw.fill(dc, r, if (selected) self.pal.button_hover else self.pal.view);
    if (item.itemID == std.math.maxInt(c.UINT)) return;
    const i: usize = item.itemData;
    if (i >= self.history.items.len) return;
    const version = self.history.items[i];
    const rel = self.release(version) orelse return;
    const u = &self.app.updates;
    const unread = !u.isRead(version);
    const installed = std.mem.eql(u8, version, self.runningText());
    _ = c.SetBkMode(dc, c.TRANSPARENT);
    _ = c.SetTextColor(dc, self.pal.text);
    const rp = self.scale(row_pad);
    var date_buf: [32]u8 = undefined;
    const date = dateText(&date_buf, rel.date);
    const date_w = textWidth(dc, self.body_font, date);
    var title_right = r.right - rp - date_w - rp;
    if (installed) {
        const pill_w = textWidth(dc, self.small_font, "Installed") + self.scale(16);
        const pr: c.RECT = .{ .left = title_right - pill_w, .top = r.top + @divTrunc(r.bottom - r.top, 2) - self.scale(10), .right = title_right, .bottom = r.top + @divTrunc(r.bottom - r.top, 2) + self.scale(10) };
        draw.roundRect(dc, pr, self.scale(10), self.pal.button, null, 0);
        drawText(dc, self.small_font, "Installed", pr, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX);
        title_right = pr.left - self.scale(8);
    }
    drawText(dc, if (unread) self.bold_font else self.body_font, if (rel.title.len > 0) rel.title else version, .{ .left = r.left + rp, .top = r.top, .right = title_right, .bottom = r.bottom }, c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX | c.DT_END_ELLIPSIS);
    _ = c.SetTextColor(dc, self.pal.subtitle);
    drawText(dc, self.body_font, date, .{ .left = r.right - rp - date_w, .top = r.top, .right = r.right - rp, .bottom = r.bottom }, c.DT_RIGHT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX);
    draw.line(dc, r.left, r.bottom - 1, r.right, r.bottom - 1, self.pal.bg, 1);
    if (item.itemState & c.ODS_FOCUS != 0 and item.itemState & ODS_NOFOCUSRECT == 0) draw.roundRect(dc, r, self.scale(button_radius), null, self.pal.focus, self.scale(2));
}

var running_text_buf: [64]u8 = undefined;

fn runningText(self: *const UpdatesWindow) []const u8 {
    const v = self.app.updates.running;
    return std.fmt.bufPrint(&running_text_buf, "{d}.{d}.{d}", .{ v.major, v.minor, v.patch }) catch "";
}

fn chevron(dc: c.HDC, r: c.RECT, left: bool, color: c.COLORREF, dpi: c.UINT) void {
    const cx = r.left + @divTrunc(r.right - r.left, 2);
    const cy = r.top + @divTrunc(r.bottom - r.top, 2);
    const s = draw.scale(dpi, 4);
    const w = draw.scale(dpi, 2);
    if (left) {
        draw.line(dc, cx + @divTrunc(s, 2), cy - s, cx - @divTrunc(s, 2), cy, color, w);
        draw.line(dc, cx - @divTrunc(s, 2), cy, cx + @divTrunc(s, 2), cy + s, color, w);
    } else {
        draw.line(dc, cx - @divTrunc(s, 2), cy - s, cx + @divTrunc(s, 2), cy, color, w);
        draw.line(dc, cx + @divTrunc(s, 2), cy, cx - @divTrunc(s, 2), cy + s, color, w);
    }
}

/// A label without its access key's '&'.
fn stripAccess(buf: []u8, label: []const u8) []const u8 {
    var n: usize = 0;
    for (label) |ch| {
        if (ch == '&') continue;
        if (n == buf.len) break;
        buf[n] = ch;
        n += 1;
    }
    return buf[0..n];
}

fn drawText(dc: c.HDC, font: ?c.HFONT, text: []const u8, rect: c.RECT, flags: c.UINT) void {
    if (text.len == 0) return;
    var wide: [1024]u16 = undefined;
    const w = text_util.utf16Into(&wide, text);
    const old = if (font) |f| c.SelectObject(dc, f) else null;
    defer if (old) |o| {
        _ = c.SelectObject(dc, o);
    };
    var r = rect;
    _ = c.DrawTextW(dc, w.ptr, @intCast(w.len), &r, flags);
}

fn textHeight(dc: c.HDC, font: ?c.HFONT, text: []const u8, w: c_int) c_int {
    if (text.len == 0) return 0;
    var wide: [1024]u16 = undefined;
    const s = text_util.utf16Into(&wide, text);
    const old = if (font) |f| c.SelectObject(dc, f) else null;
    defer if (old) |o| {
        _ = c.SelectObject(dc, o);
    };
    var r: c.RECT = .{ .right = w };
    _ = c.DrawTextW(dc, s.ptr, @intCast(s.len), &r, c.DT_CALCRECT | c.DT_WORDBREAK | c.DT_NOPREFIX);
    return r.bottom - r.top;
}

fn textWidth(dc: c.HDC, font: ?c.HFONT, text: []const u8) c_int {
    if (text.len == 0) return 0;
    var wide: [512]u16 = undefined;
    const s = text_util.utf16Into(&wide, text);
    const old = if (font) |f| c.SelectObject(dc, f) else null;
    defer if (old) |o| {
        _ = c.SelectObject(dc, o);
    };
    var r: c.RECT = .{};
    _ = c.DrawTextW(dc, s.ptr, @intCast(s.len), &r, c.DT_CALCRECT | c.DT_SINGLELINE | c.DT_NOPREFIX);
    return r.right - r.left;
}

/// The buttons and the notes keep their own procedures but for these:
/// Backspace or Alt+Left goes back from a subpage (libadwaita's), and the
/// notes leave Tab, Enter and Escape to the window's IsDialogMessage. A
/// multiline edit asks for every key, and then answers Escape with
/// WM_CLOSE and Tab with WM_NEXTDLGCTL, which only a dialog takes: Escape
/// closed the window instead of going back, and Tab stayed in the notes.
/// (Space clicks a focused button by itself; Enter comes as IDOK.)
fn childProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const parent = c.GetParent(hwnd) orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self = fromHwnd(parent) orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const notes = c.GetDlgCtrlID(hwnd) == id_notes;
    const proc = if (notes) self.edit_proc else self.button_proc;
    switch (msg) {
        c.WM_KEYDOWN => if (wparam == c.VK_BACK and self.page != .main) {
            self.back();
            return 0;
        },
        c.WM_SYSKEYDOWN => if (wparam == c.VK_LEFT and self.page != .main) {
            self.back();
            return 0;
        },
        c.WM_GETDLGCODE => if (notes) {
            const code = c.CallWindowProcW(proc, hwnd, msg, wparam, lparam);
            // Arrows and characters stay the notes' (scrolling, copying);
            // no select-all on reaching them by Tab.
            return code & ~@as(c.LRESULT, c.DLGC_WANTALLKEYS | c.DLGC_HASSETSEL);
        },
        else => {},
    }
    return c.CallWindowProcW(proc, hwnd, msg, wparam, lparam);
}

// ---------------------------------------------------------------- the GUI tests

/// The window as WM_PAINT draws it, its controls printed into it, for the
/// GUI tests' pictures (dump wparam 27): captures don't work on their
/// hidden desktop.
pub fn paintTo(self: *UpdatesWindow, dc: c.HDC, _: c.RECT) void {
    self.paint(dc);
    for (self.controls) |ctl| {
        const h = ctl.hwnd orelse continue;
        if (c.IsWindowVisible(h) == 0) continue;
        var r: c.RECT = .{};
        _ = c.GetWindowRect(h, &r);
        var pt = [1]c.POINT{.{ .x = r.left, .y = r.top }};
        _ = c.MapWindowPoints(null, self.hwnd, &pt, 1);
        var old: c.POINT = .{};
        _ = c.SetViewportOrgEx(dc, pt[0].x, pt[0].y, &old);
        _ = c.SendMessageW(h, c.WM_PRINT, @intFromPtr(dc), c.PRF_CLIENT | c.PRF_NONCLIENT | c.PRF_ERASEBKGND);
        _ = c.SetViewportOrgEx(dc, old.x, old.y, null);
    }
}

pub fn clientSize(self: *const UpdatesWindow) c.RECT {
    var r: c.RECT = .{};
    _ = c.GetClientRect(self.hwnd, &r);
    return r;
}

/// The window as the GUI tests read it: the page, the main page's texts,
/// each control (id, label, shown, enabled, on, value), the history
/// (version, bold, installed) and the selection, and the notes shown.
pub fn writeDump(self: *UpdatesWindow, alloc: Allocator, out: *std.ArrayList(u8)) !void {
    try out.print(alloc, "{{\"hwnd\":{d},\"page\":\"{t}\",\"heading\":", .{ @intFromPtr(self.hwnd), self.page });
    try test_hooks.writeString(alloc, out, self.heading[0..self.heading_len]);
    try out.appendSlice(alloc, ",\"subtitle\":");
    try test_hooks.writeString(alloc, out, self.subtitle[0..self.subtitle_len]);
    try out.appendSlice(alloc, ",\"controls\":[");
    for (self.controls, 0..) |ctl, i| {
        if (i > 0) try out.append(alloc, ',');
        var label_buf: [96]u8 = undefined;
        const visible = if (ctl.hwnd) |h| c.IsWindowVisible(h) != 0 else false;
        try out.print(alloc, "{{\"id\":{d},\"label\":", .{ctl.id});
        try test_hooks.writeString(alloc, out, stripAccess(&label_buf, ctl.label));
        try out.print(alloc, ",\"visible\":{},\"enabled\":{},\"on\":{},\"value\":", .{ visible, ctl.enabled, ctl.on });
        try test_hooks.writeString(alloc, out, ctl.value);
        try out.append(alloc, '}');
    }
    try out.appendSlice(alloc, "],\"history\":[");
    for (self.history.items, 0..) |v, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, "{\"version\":");
        try test_hooks.writeString(alloc, out, v);
        try out.print(alloc, ",\"bold\":{},\"installed\":{}}}", .{ !self.app.updates.isRead(v), std.mem.eql(u8, v, self.runningText()) });
    }
    const list_hwnd = self.find(id_history).?.hwnd;
    const sel: isize = if (list_hwnd) |h| c.SendMessageW(h, c.LB_GETCURSEL, 0, 0) else -1;
    try out.print(alloc, "],\"selected\":{d},\"notes_version\":", .{sel});
    if (self.notes_version) |v| try test_hooks.writeString(alloc, out, v) else try out.appendSlice(alloc, "null");
    try out.appendSlice(alloc, ",\"notes\":");
    if (self.find(id_notes).?.hwnd) |h| {
        var wide: [4096]u16 = undefined;
        const n: usize = @intCast(c.GetWindowTextW(h, &wide, wide.len));
        const text = std.unicode.utf16LeToUtf8Alloc(alloc, wide[0..n]) catch "";
        defer if (text.len > 0) alloc.free(text);
        try test_hooks.writeString(alloc, out, text);
    } else try out.appendSlice(alloc, "\"\"");
    try out.append(alloc, '}');
}

test "updates window: release notes as plain text" {
    const a = std.testing.allocator;
    const text = try notesText(a, "## What's new\n\n- **Bold** and `code`\n- A [link](https://x.org)\n");
    defer a.free(text);
    try std.testing.expectEqualStrings("What's new\r\n\r\n\u{2022} Bold and code\r\n\u{2022} A link (https://x.org)\r\n", text);
    const tight = try notesText(a, "# Title\nText");
    defer a.free(tight);
    try std.testing.expectEqualStrings("Title\r\n\r\nText", tight);
}

test "updates window: dates" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Nov 20, 2026", dateText(&buf, "2026-11-20"));
    try std.testing.expectEqualStrings("bad", dateText(&buf, "bad"));
    var label: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Check Now", stripAccess(&label, "Check &Now"));
}

test "updates window: only murrtty's release pages open" {
    try std.testing.expect(releasePageOk("https://github.com/murr2k/murrtty/releases/tag/murrtty-v0.6.0"));
    try std.testing.expect(releasePageOk("https://github.com/murr2k/murrtty/releases/tag/murrtty-v0.7.0-beta.1"));
    for ([_][]const u8{
        "https://github.com/murr2k/murrtty/releases/",
        "https://github.com/murr2k/murrtty/releases/tag/",
        "https://github.com/murr2k/murrtty/releases/tag/..",
        "https://github.com/murr2k/murrtty/releases/tag/../../../x/y",
        "https://github.com/murr2k/murrtty/releases/tag/%2e%2e",
        "https://github.com/murr2k/murrtty/releases/tag/a\\..\\..\\x",
        "https://github.com/murr2k/murrtty/releases/tag/a?b=c",
        "https://github.com/murr2k/murrtty/releases/../../other",
        "https://github.com/murr2k/murrtty/releases/download/x/y.zip",
        "http://github.com/murr2k/murrtty/releases/tag/murrtty-v0.6.0",
        "https://github.com/murr2k/murrtty-evil/releases/tag/x",
    }) |url| try std.testing.expect(!releasePageOk(url));
}
