//! The configuration editor (roadmap F1): murrtty's own, as Ghostty's apps
//! have none. GTK having nothing to match, it is drawn as libadwaita's
//! preferences window (the Look rule): a search field, a page picker and
//! Save over a page of cards (libadwaita's boxed lists), one per group of
//! options, each option a row with its name, its documentation's first
//! sentence (all of it once the row is opened), and the control that edits
//! its value: a switch, a menu of its choices or flags, a field (a color's
//! with its swatch, a path's), or a list's lines.
//!
//! It edits the files the loader reads at start (`edit.defaultFiles`:
//! murrtty's own, else Ghostty's), with the one `open_config` opens as the
//! main file, and the files they include, through an `EditorSession`: a
//! value goes where the loader takes it from, only the
//! lines of the keys changed are rewritten, in Ghostty's own syntax, and a
//! value only murrtty takes is pointed out, so a Ghostty configuration stays
//! one Ghostty reads. Each value is tried as the loader parses it before it
//! is taken. Save writes each changed file whole (a temporary file, then a
//! replace) and reloads, whose errors show in the configuration errors
//! dialog as any reload's do.
//!
//! One editor at a time (App.config_editor); while it is open it keeps
//! murrtty running, and closing it with changes unsaved asks first.
const ConfigEditor = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const configpkg = @import("../../config.zig");
const cli_args = @import("../../cli/args.zig");
const option_list = configpkg.option_list;
const EditorSession = configpkg.EditorSession;
const c = @import("c.zig");
const draw = @import("draw.zig");
const text_util = @import("text.zig");
const App = @import("App.zig");
const AlertDialog = @import("AlertDialog.zig");
const ContextMenu = @import("ContextMenu.zig");

const log = std.log.scoped(.win32_config_editor);

pub const class_name = c.L("MurrttyConfigEditor");
pub const list_class_name = c.L("MurrttyConfigEditorList");

const id_search = 1;
const id_list = 2;
const id_edit = 3;

/// Response ids for the dialogs it asks.
const id_save = 200;
const id_discard = 201;
const id_overwrite = 202;

/// Metrics in device-independent pixels, libadwaita's where it has them:
/// rows 58 tall with a subtitle, cards rounded 12, entries 34 tall rounded
/// 6, a switch 46 by 26, a page at most 680 wide with 24 at its sides.
const default_width = 760;
const default_height = 680;
const min_width = 420;
const min_height = 360;
const bar_height = 58;
const bar_pad = 12;
const field_height = 34;
const field_radius = 6;
const button_pad_x = 16;
const footer_height = 30;
const content_max = 680;
const content_pad = 24;
const group_gap = 24;
const group_title_height = 30;
const card_radius = 12;
const row_height = 58;
const row_pad = 12;
const control_width = 230;
const switch_width = 46;
const switch_height = 26;
const reset_size = 26;
const swatch_size = 18;
const doc_pad = 10;
const list_edit_height = 150;

/// How far one notch of the wheel or an arrow of the scroll bar moves.
const line_step = 40;

/// The longest search, in UTF-16 units.
const max_query = 255;
/// The longest value the field takes, in UTF-16 units (a line the loader
/// reads is at most 4,094 bytes).
const max_value = 4000;

/// libadwaita's preferences colors: the window's background, the cards on
/// it (white in light, 8% white over the window in dark), text, a row's
/// subtitle at 55%, separators at 15%, an entry and a flat button at 10%,
/// the accent (GNOME's blue) for a switch that is on and the suggested
/// button, and the warning and error colors for what the editor points out.
const Pal = struct {
    bg: c.COLORREF,
    card: c.COLORREF,
    text: c.COLORREF,
    subtitle: c.COLORREF,
    separator: c.COLORREF,
    field: c.COLORREF,
    hover: c.COLORREF,
    pressed: c.COLORREF,
    accent: c.COLORREF,
    accent_text: c.COLORREF,
    focus: c.COLORREF,
    switch_off: c.COLORREF,
    knob: c.COLORREF,
    warning: c.COLORREF,
    err: c.COLORREF,

    fn of(dark: bool) Pal {
        const theme = draw.adwaita(dark);
        const white: draw.Color = .{ .r = 0xff, .g = 0xff, .b = 0xff };
        const bg = theme.window;
        const card = if (dark) draw.blend(bg, white, 0.08) else white;
        const fg = theme.fg;
        const accent: draw.Color = .{ .r = 0x35, .g = 0x84, .b = 0xe4 };
        return .{
            .bg = draw.ref(bg),
            .card = draw.ref(card),
            .text = draw.ref(fg),
            .subtitle = draw.ref(draw.blend(card, fg, 0.55)),
            .separator = draw.ref(draw.blend(card, fg, 0.15)),
            .field = draw.ref(draw.blend(card, fg, 0.10)),
            .hover = draw.ref(draw.blend(card, fg, 0.07)),
            .pressed = draw.ref(draw.blend(card, fg, 0.16)),
            .accent = draw.ref(accent),
            .accent_text = draw.ref(white),
            .focus = draw.ref(draw.blend(bg, accent, 0.5)),
            .switch_off = draw.ref(draw.blend(card, fg, 0.15)),
            .knob = draw.ref(white),
            // libadwaita's warning and error foregrounds.
            .warning = draw.ref(if (dark) .{ .r = 0xf8, .g = 0xe4, .b = 0x5c } else .{ .r = 0x9c, .g = 0x6e, .b = 0x03 }),
            .err = draw.ref(if (dark) .{ .r = 0xff, .g = 0x93, .b = 0x8c } else .{ .r = 0xc0, .g = 0x1c, .b = 0x28 }),
        };
    }
};

const Fonts = struct {
    title: ?c.HFONT = null,
    subtitle: ?c.HFONT = null,
    heading: ?c.HFONT = null,
    button: ?c.HFONT = null,

    fn make(dpi: c.UINT) Fonts {
        return .{
            .title = draw.chromeFont(dpi, null, false),
            .subtitle = draw.chromeFontSized(dpi, null, 9, false),
            .heading = draw.chromeFont(dpi, null, true),
            .button = draw.chromeFont(dpi, null, true),
        };
    }

    fn deinit(self: *Fonts) void {
        for ([_]?c.HFONT{ self.title, self.subtitle, self.heading, self.button }) |f| if (f) |font| {
            _ = c.DeleteObject(font);
        };
        self.* = .{};
    }
};

/// A row of the page: a group's title, or an option.
const Item = struct {
    kind: enum { group, option },
    group: option_list.Group,
    /// The option's index in option_list.all.
    option: u16 = 0,
    /// Laid out, in the page's pixels from its top.
    top: c_int = 0,
    height: c_int = 0,
    /// The first and last option of its card.
    first: bool = false,
    last: bool = false,
};

/// What a click lands on.
const Part = enum { row, control, reset };

app: *App,
hwnd: c.HWND,
search: ?c.HWND = null,
search_proc: isize = 0,
list: ?c.HWND = null,
/// The field over a row's value, while one is being typed (a list's lines
/// in a multi-line field).
edit: ?c.HWND = null,
edit_proc: isize = 0,
edit_option: ?u16 = null,
edit_brush: ?c.HBRUSH = null,
session: EditorSession,
/// The opened file, absolute.
path: []u8,
items: std.ArrayList(Item) = .empty,
content_height: c_int = 0,
scroll: c_int = 0,
selected: ?u16 = null,
/// The row whose documentation is shown whole.
expanded: ?u16 = null,
/// The page shown, null for all of them.
group: ?option_list.Group = null,
/// The search, as UTF-8.
query: std.ArrayList(u8) = .empty,
/// Options changed since the editor opened (their names are constants), for
/// what a save says about when they apply.
changed: std.StringHashMapUnmanaged(void) = .empty,
/// The last message: what was saved, or why a value was refused.
status: [512]u8 = undefined,
status_len: usize = 0,
status_error: bool = false,
dpi: c.UINT = c.USER_DEFAULT_SCREEN_DPI,
dark: bool = false,
pal: Pal = Pal.of(false),
fonts: Fonts = .{},
/// The top bar's parts, in the window's client pixels.
search_rect: c.RECT = .{},
group_rect: c.RECT = .{},
save_rect: c.RECT = .{},
pressed: enum { none, group, save } = .none,
/// Its window has been made: until then a WM_NCDESTROY (a failed
/// creation) leaves freeing it to `create`.
created: bool = false,
/// The system menu's loop, a modal scope (as a terminal window's).
menu_modal: ?App.Modal = null,
hover_item: ?usize = null,
hover_part: ?Part = null,
tracking: bool = false,

pub fn registerClass(instance: c.HINSTANCE) !void {
    for ([_]struct { c.LPCWSTR, c.WNDPROC }{
        .{ class_name, &wndProc },
        .{ list_class_name, &listProc },
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

/// Open the editor, or bring it forward if it is open.
pub fn open(app: *App) void {
    if (app.config_editor) |editor| return editor.present();
    const editor = create(app) catch |err| {
        log.warn("config editor not opened err={}", .{err});
        return;
    };
    app.config_editor = editor;
    // Once it is the app's: its dialog runs a loop of its own.
    editor.reportMissing();
}

/// Whether murrtty may quit: changes unsaved ask Save, Discard or Cancel,
/// as closing the editor does.
pub fn allowQuit(self: *ConfigEditor) bool {
    return self.confirmClose();
}

/// Close it without asking (murrtty is quitting).
pub fn destroy(self: *ConfigEditor) void {
    _ = c.DestroyWindow(self.hwnd);
}

pub fn present(self: *ConfigEditor) void {
    if (c.IsIconic(self.hwnd) != 0) _ = c.ShowWindow(self.hwnd, c.SW_RESTORE);
    _ = c.SetForegroundWindow(self.hwnd);
}

fn create(app: *App) !*ConfigEditor {
    const alloc = app.core_app.alloc;
    // The main file: the one open_config opens (made if there is none).
    const open_path = configpkg.edit.openPath(alloc) catch |err| {
        cantOpen(app, "The configuration file", @errorName(err));
        return err;
    };
    defer alloc.free(open_path);
    const path = try alloc.dupe(u8, open_path);
    errdefer alloc.free(path);
    std.mem.replaceScalar(u8, path, '/', '\\');

    // Every file the loader reads at start, in its order, the main one
    // among them.
    const defaults = configpkg.edit.defaultFiles(alloc) catch |err| {
        cantOpen(app, "The configuration file", @errorName(err));
        return err;
    };
    defer configpkg.edit.freeDefaultFiles(alloc, defaults);
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| alloc.free(p);
        paths.deinit(alloc);
    }
    for (defaults) |d| {
        const p = try alloc.dupe(u8, d);
        errdefer alloc.free(p);
        std.mem.replaceScalar(u8, p, '/', '\\');
        try paths.append(alloc, p);
    }
    const listed = for (paths.items) |p| {
        if (std.ascii.eqlIgnoreCase(p, path)) break true;
    } else false;
    if (!listed) try paths.append(alloc, try alloc.dupe(u8, path));

    var texts: std.ArrayList([]u8) = .empty;
    defer {
        for (texts.items) |t| alloc.free(t);
        texts.deinit(alloc);
    }
    var tops: std.ArrayList(EditorSession.Top) = .empty;
    defer tops.deinit(alloc);
    var main: usize = 0;
    for (paths.items) |p| {
        const is_main = std.ascii.eqlIgnoreCase(p, path);
        const text: []u8 = switch (readFile(alloc, p)) {
            .text => |t| t,
            // Gone since it was found: an empty main file, else nothing.
            .not_found => if (is_main) try alloc.dupe(u8, "") else continue,
            // Shown as empty, a save would replace what it holds.
            .failed => |reason| {
                cantOpen(app, p, reason);
                return error.ConfigUnreadable;
            },
        };
        texts.append(alloc, text) catch |err| {
            alloc.free(text);
            return err;
        };
        // A line the loader can't read: the file can't be changed safely.
        var doc = configpkg.EditableFile.parse(alloc, text) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                cantOpen(app, p, "a line in it is longer than murrtty reads, so it can't be changed safely");
                return err;
            },
        };
        doc.deinit();
        if (is_main) main = tops.items.len;
        try tops.append(alloc, .{ .path = p, .text = text });
    }
    var session = try EditorSession.initFiles(alloc, tops.items, main, .{ .ctx = @ptrCast(app), .read = readFileFor });
    errdefer session.deinit();

    const self = try alloc.create(ConfigEditor);
    // Until its window exists; then the window's destroy frees it.
    var owned = true;
    errdefer if (owned) alloc.destroy(self);
    self.* = .{ .app = app, .hwnd = undefined, .session = session, .path = path };

    _ = c.CreateWindowExW(
        0,
        class_name,
        c.L("murrtty Configuration"),
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
        // WM_NCDESTROY may have run: it left `self` to these errdefers,
        // as `created` was unset.
        return error.CreateWindowFailed;
    };
    self.created = true;
    owned = false;
    // Its own copy of the system menu now: asked for later, while it opens,
    // Windows makes a copy other than the one showing (Window.create).
    _ = c.GetSystemMenu(self.hwnd, c.FALSE);
    self.refreshTheme();
    self.rebuild();
    // Its size in DIP at the window's DPI.
    _ = c.SetWindowPos(self.hwnd, null, 0, 0, self.scale(default_width), self.scale(default_height), c.SWP_NOMOVE | c.SWP_NOZORDER | c.SWP_NOACTIVATE);
    _ = c.ShowWindow(self.hwnd, c.SW_SHOWNORMAL);
    _ = c.SetForegroundWindow(self.hwnd);
    if (self.search) |s| _ = c.SetFocus(s);
    self.setStatus(false, "Editing {s}", .{self.path});
    return self;
}

/// Included files it doesn't edit: one that couldn't be read is said in a
/// dialog (what it sets isn't shown, and a change to it goes elsewhere);
/// one that isn't there, in the status line.
fn reportMissing(self: *ConfigEditor) void {
    for (self.session.missing.items) |m| {
        const reason = m.reason orelse continue;
        const alloc = self.app.core_app.alloc;
        const body = std.fmt.allocPrint(alloc, "{s}, which the configuration includes, can't be read: {s}. What it sets isn't shown here, and a change made here to one of those settings goes to {s}, which it overrides.", .{ m.path, reason, std.fs.path.basename(self.path) }) catch return;
        defer alloc.free(body);
        self.setStatus(true, "Not read: {s} ({s})", .{ m.path, reason });
        var modal = self.app.beginModal(self.hwnd, .{});
        defer modal.end();
        _ = AlertDialog.run(alloc, .{
            .owner = self.hwnd,
            .heading = "Included File Not Read",
            .body = body,
            .responses = &.{.{ .id = c.IDCANCEL, .label = "Close" }},
            .default = c.IDCANCEL,
            .dark = self.dark,
        });
        return;
    }
    if (self.session.missing.items.len > 0) self.setStatus(true, "Not read: {s}", .{self.session.missing.items[0].path});
}

fn scale(self: *const ConfigEditor, v: c_int) c_int {
    return draw.scale(self.dpi, v);
}

fn fromHwnd(hwnd: c.HWND) ?*ConfigEditor {
    const ptr: usize = @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA));
    return if (ptr != 0) @ptrFromInt(ptr) else null;
}

/// A file read: its text, or that it isn't there, or why it couldn't be
/// read (anything but its absence: a file in use, access denied).
const Read = EditorSession.ReadResult;

/// The file at `path` (absolute), through any link.
fn readFile(alloc: Allocator, path: []const u8) Read {
    const wide = text_util.utf16Lossy(alloc, path) catch return .{ .failed = "out of memory" };
    defer alloc.free(wide);
    const handle = c.CreateFileW(wide.ptr, c.GENERIC_READ, c.FILE_SHARE_READ | c.FILE_SHARE_WRITE | c.FILE_SHARE_DELETE, null, c.OPEN_EXISTING, c.FILE_ATTRIBUTE_NORMAL, null);
    if (handle == c.INVALID_HANDLE_VALUE) return switch (c.GetLastError()) {
        c.ERROR_FILE_NOT_FOUND, c.ERROR_PATH_NOT_FOUND => .not_found,
        else => |err| .{ .failed = why(err) },
    };
    defer _ = c.CloseHandle(handle);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        var n: c.DWORD = 0;
        if (c.ReadFile(handle, &buf, buf.len, &n, null) == 0) return .{ .failed = why(c.GetLastError()) };
        if (n == 0) break;
        out.appendSlice(alloc, buf[0..n]) catch return .{ .failed = "out of memory" };
        // A configuration file is small: past this it isn't one.
        if (out.items.len > 16 * 1024 * 1024) return .{ .failed = "it is larger than 16 MB" };
    }
    return .{ .text = out.toOwnedSlice(alloc) catch return .{ .failed = "out of memory" } };
}

fn why(err: c.DWORD) []const u8 {
    return switch (err) {
        c.ERROR_ACCESS_DENIED => "access is denied",
        c.ERROR_SHARING_VIOLATION => "another program is using it",
        else => "Windows couldn't read it",
    };
}

fn readFileFor(_: *anyopaque, alloc: Allocator, path: []const u8) Read {
    return readFile(alloc, path);
}

/// A configuration file the editor can't open: it says so instead of
/// showing defaults a save would write over the file.
fn cantOpen(app: *App, path: []const u8, reason: []const u8) void {
    const alloc = app.core_app.alloc;
    log.warn("config editor not opened path={s} reason={s}", .{ path, reason });
    const body = std.fmt.allocPrint(alloc, "{s} can't be opened for editing: {s}.", .{ path, reason }) catch return;
    defer alloc.free(body);
    var modal = app.beginModal(null, .{});
    defer modal.end();
    _ = AlertDialog.run(alloc, .{
        .owner = null,
        .heading = "Configuration Not Opened",
        .body = body,
        .responses = &.{.{ .id = c.IDCANCEL, .label = "Close" }},
        .default = c.IDCANCEL,
        .dark = app.chromeTheme().dark,
    });
}

/// Write `text` to `path` whole: to a file beside it, then in its place, so
/// a failure leaves the old file as it was. Through a symbolic link, the
/// file it names is written (the link stays); a file with other hard links
/// is written over in place, as replacing it would part it from them (the
/// file beside it is kept if that fails).
fn writeFile(alloc: Allocator, path: []const u8, text: []const u8) !void {
    const logical = try text_util.utf16Lossy(alloc, path);
    defer alloc.free(logical);
    var final: ?[:0]u16 = null;
    defer if (final) |f| alloc.free(f);
    var links: c.DWORD = 1;
    const probe = c.CreateFileW(logical.ptr, c.FILE_READ_ATTRIBUTES, c.FILE_SHARE_READ | c.FILE_SHARE_WRITE | c.FILE_SHARE_DELETE, null, c.OPEN_EXISTING, c.FILE_ATTRIBUTE_NORMAL, null);
    if (probe != c.INVALID_HANDLE_VALUE) {
        defer _ = c.CloseHandle(probe);
        var info: c.BY_HANDLE_FILE_INFORMATION = undefined;
        if (c.GetFileInformationByHandle(probe, &info) != 0) links = info.nNumberOfLinks;
        const buf = try alloc.alloc(u16, 32 * 1024);
        defer alloc.free(buf);
        const n = c.GetFinalPathNameByHandleW(probe, buf.ptr, @intCast(buf.len), 0);
        if (n > 0 and n < buf.len) final = try alloc.dupeSentinel(u16, buf[0..n], 0);
    }
    const dest: [:0]const u16 = final orelse logical;
    const tmp = try std.mem.concatWithSentinel(alloc, u16, &.{ dest, c.L(".murrtty-save") }, 0);
    defer alloc.free(tmp);
    const tmp_z: [*:0]const u16 = tmp.ptr;
    const dest_z: [*:0]const u16 = dest.ptr;

    if (writeWhole(tmp_z, c.CREATE_ALWAYS, text) != .written) {
        _ = c.DeleteFileW(tmp_z);
        return error.WriteFailed;
    }
    if (links > 1) {
        switch (writeWhole(dest_z, c.TRUNCATE_EXISTING, text)) {
            .written => {},
            // Not opened: the file is as it was.
            .not_opened => {
                _ = c.DeleteFileW(tmp_z);
                return error.WriteFailed;
            },
            // Cut short: the whole text stays in the copy beside it.
            .cut_short => return error.CutShort,
        }
        _ = c.DeleteFileW(tmp_z);
        return;
    }
    if (c.MoveFileExW(tmp_z, dest_z, c.MOVEFILE_REPLACE_EXISTING | c.MOVEFILE_WRITE_THROUGH) == 0) {
        _ = c.DeleteFileW(tmp_z);
        return error.ReplaceFailed;
    }
}

/// Write `text` to the file at `path`, opened with `disposition`, and
/// flush it: all of it written, the file not opened (untouched), or cut
/// short once opened.
fn writeWhole(path: [*:0]const u16, disposition: c.DWORD, text: []const u8) enum { written, not_opened, cut_short } {
    const handle = c.CreateFileW(path, c.GENERIC_WRITE, 0, null, disposition, c.FILE_ATTRIBUTE_NORMAL, null);
    if (handle == c.INVALID_HANDLE_VALUE) return .not_opened;
    defer _ = c.CloseHandle(handle);
    var off: usize = 0;
    while (off < text.len) {
        var n: c.DWORD = 0;
        const chunk: c.DWORD = @intCast(@min(text.len - off, 1 << 20));
        if (c.WriteFile(handle, text[off..].ptr, chunk, &n, null) == 0 or n == 0) return .cut_short;
        off += n;
    }
    return if (c.FlushFileBuffers(handle) != 0) .written else .cut_short;
}

fn setStatus(self: *ConfigEditor, is_error: bool, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&self.status, fmt, args) catch self.status[0..];
    self.status_len = text_util.truncate(s, self.status.len).len;
    self.status_error = is_error;
    var r: c.RECT = .{};
    _ = c.GetClientRect(self.hwnd, &r);
    r.top = r.bottom - self.scale(footer_height);
    _ = c.InvalidateRect(self.hwnd, &r, c.FALSE);
}

/// Colors and fonts for the app's chrome theme and the window's DPI.
fn refreshTheme(self: *ConfigEditor) void {
    self.dpi = c.GetDpiForWindow(self.hwnd);
    self.dark = self.app.chromeTheme().dark;
    self.pal = Pal.of(self.dark);
    self.fonts.deinit();
    self.fonts = Fonts.make(self.dpi);
    if (self.edit_brush) |b| _ = c.DeleteObject(b);
    self.edit_brush = c.CreateSolidBrush(self.pal.field);
    const dark: c.BOOL = if (self.dark) c.TRUE else c.FALSE;
    _ = c.DwmSetWindowAttribute(self.hwnd, c.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, @sizeOf(c.BOOL));
    const theme: c.LPCWSTR = if (self.dark) c.L("DarkMode_Explorer") else c.L("Explorer");
    if (self.list) |l| _ = c.SetWindowTheme(l, theme, null);
    for ([_]?c.HWND{ self.search, self.edit }) |h| if (h) |w| {
        _ = c.SendMessageW(w, c.WM_SETFONT, @intFromPtr(self.fonts.title), 1);
        _ = c.SetWindowTheme(w, theme, null);
    };
    self.layoutBar();
    _ = c.InvalidateRect(self.hwnd, null, c.TRUE);
}

/// The top bar's search field, page button and Save, and the list below.
fn layoutBar(self: *ConfigEditor) void {
    var client: c.RECT = .{};
    _ = c.GetClientRect(self.hwnd, &client);
    const pad = self.scale(bar_pad);
    const fh = self.scale(field_height);
    const top = @divTrunc(self.scale(bar_height) - fh, 2);
    const save_w = self.textWidth(self.fonts.button, "Save") + 2 * self.scale(button_pad_x);
    const group_w = @min(self.scale(200), self.textWidth(self.fonts.button, self.groupLabel()) + 2 * self.scale(button_pad_x) + self.scale(14));
    self.save_rect = .{ .left = client.right - pad - save_w, .top = top, .right = client.right - pad, .bottom = top + fh };
    self.group_rect = .{ .left = self.save_rect.left - pad - group_w, .top = top, .right = self.save_rect.left - pad, .bottom = top + fh };
    self.search_rect = .{ .left = pad, .top = top, .right = @max(pad + self.scale(80), self.group_rect.left - pad), .bottom = top + fh };
    if (self.search) |s| {
        const inset = self.scale(9);
        const line = self.lineHeight(self.fonts.title) + 2;
        const r = self.search_rect;
        _ = c.SetWindowPos(s, null, r.left + inset, r.top + @divTrunc(fh - line, 2), r.right - r.left - 2 * inset, line, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
    }
    if (self.list) |l| {
        const y = self.scale(bar_height);
        const h = @max(0, client.bottom - y - self.scale(footer_height));
        _ = c.SetWindowPos(l, null, 0, y, client.right, h, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
    }
}

fn groupLabel(self: *const ConfigEditor) []const u8 {
    return if (self.group) |g| g.title() else "All Pages";
}

fn textWidth(self: *const ConfigEditor, font: ?c.HFONT, s: []const u8) c_int {
    const dc = c.GetDC(self.hwnd) orelse return 0;
    defer _ = c.ReleaseDC(self.hwnd, dc);
    const old = if (font) |f| c.SelectObject(dc, f) else null;
    defer if (old) |o| {
        _ = c.SelectObject(dc, o);
    };
    var buf: [256]u16 = undefined;
    const w = text_util.utf16Into(&buf, s);
    var r: c.RECT = .{};
    _ = c.DrawTextW(dc, w.ptr, @intCast(w.len), &r, c.DT_SINGLELINE | c.DT_CALCRECT | c.DT_NOPREFIX);
    return r.right - r.left;
}

fn lineHeight(self: *const ConfigEditor, font: ?c.HFONT) c_int {
    const dc = c.GetDC(self.hwnd) orelse return self.scale(16);
    defer _ = c.ReleaseDC(self.hwnd, dc);
    const old = if (font) |f| c.SelectObject(dc, f) else null;
    defer if (old) |o| {
        _ = c.SelectObject(dc, o);
    };
    var r: c.RECT = .{};
    _ = c.DrawTextW(dc, c.L("Ag"), 2, &r, c.DT_SINGLELINE | c.DT_CALCRECT);
    return r.bottom - r.top;
}

/// The page's rows for the search and the page chosen, laid out.
fn rebuild(self: *ConfigEditor) void {
    const alloc = self.app.core_app.alloc;
    self.items.clearRetainingCapacity();
    const groups = @typeInfo(option_list.Group).@"enum".field_names;
    inline for (groups) |gname| {
        const g = @field(option_list.Group, gname);
        if (self.group == null or self.group.? == g) {
            var first = true;
            for (option_list.all, 0..) |*o, i| {
                if (option_list.groupOf(o.name) != g) continue;
                if (!option_list.matches(o, self.query.items)) continue;
                if (first) {
                    self.items.append(alloc, .{ .kind = .group, .group = g }) catch return;
                    first = false;
                }
                self.items.append(alloc, .{ .kind = .option, .group = g, .option = @intCast(i) }) catch return;
            }
        }
    }
    // The first and last of each card.
    for (self.items.items, 0..) |*it, i| {
        if (it.kind != .option) continue;
        it.first = i == 0 or self.items.items[i - 1].kind != .option;
        it.last = i + 1 == self.items.items.len or self.items.items[i + 1].kind != .option;
    }
    if (self.selected) |s| if (self.indexOfOption(s) == null) {
        self.selected = null;
    };
    self.layout();
}

fn indexOfOption(self: *const ConfigEditor, option: u16) ?usize {
    for (self.items.items, 0..) |it, i| if (it.kind == .option and it.option == option) return i;
    return null;
}

/// The page's horizontal extent in the list's pixels.
fn pageX(self: *const ConfigEditor) struct { left: c_int, right: c_int } {
    var r: c.RECT = .{};
    if (self.list) |l| _ = c.GetClientRect(l, &r);
    const pad = self.scale(content_pad);
    const w = @min(self.scale(content_max), @max(self.scale(200), r.right - 2 * pad));
    const left = @max(pad, @divTrunc(r.right - w, 2));
    return .{ .left = left, .right = left + w };
}

/// Each row's place and height, the page's height and the scroll bar.
fn layout(self: *ConfigEditor) void {
    const page = self.pageX();
    var y: c_int = 0;
    for (self.items.items) |*it| {
        switch (it.kind) {
            .group => {
                y += self.scale(group_gap);
                it.top = y;
                it.height = self.scale(group_title_height);
            },
            .option => {
                it.top = y;
                it.height = self.optionHeight(it.option, page.right - page.left);
            },
        }
        y += it.height;
    }
    self.content_height = y + self.scale(group_gap);
    self.syncScroll();
    if (self.list) |l| _ = c.InvalidateRect(l, null, c.FALSE);
    if (self.edit != null) self.placeEdit();
}

/// A row's height: one with its documentation shown, or a list being
/// edited, is taller.
fn optionHeight(self: *const ConfigEditor, option: u16, width: c_int) c_int {
    var h = self.scale(row_height);
    if (self.expanded == option) {
        const o = &option_list.all[option];
        h += self.docHeight(o.doc, width - 2 * self.scale(row_pad)) + self.scale(doc_pad);
        if (o.kind == .list) h += self.scale(list_edit_height) + self.scale(doc_pad);
    }
    return h;
}

fn docHeight(self: *const ConfigEditor, doc: []const u8, width: c_int) c_int {
    const list = self.list orelse return 0;
    const dc = c.GetDC(list) orelse return 0;
    defer _ = c.ReleaseDC(list, dc);
    const old = if (self.fonts.subtitle) |f| c.SelectObject(dc, f) else null;
    defer if (old) |o| {
        _ = c.SelectObject(dc, o);
    };
    const alloc = self.app.core_app.alloc;
    const wide = docText(alloc, doc) catch return 0;
    defer alloc.free(wide);
    var r: c.RECT = .{ .right = width };
    _ = c.DrawTextW(dc, wide.ptr, @intCast(wide.len), &r, c.DT_WORDBREAK | c.DT_NOPREFIX | c.DT_CALCRECT | c.DT_EXPANDTABS);
    return r.bottom - r.top;
}

/// An option's documentation as shown in its opened row: Markdown's
/// backticks dropped, paragraphs kept.
fn docText(alloc: Allocator, doc: []const u8) ![:0]u16 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (doc) |ch| if (ch != '`') try out.append(alloc, ch);
    // DrawText breaks lines at CR LF.
    var crlf: std.ArrayList(u8) = .empty;
    defer crlf.deinit(alloc);
    for (out.items) |ch| {
        if (ch == '\n') try crlf.append(alloc, '\r');
        try crlf.append(alloc, ch);
    }
    return text_util.utf16Lossy(alloc, crlf.items);
}

fn viewHeight(self: *const ConfigEditor) c_int {
    var r: c.RECT = .{};
    if (self.list) |l| _ = c.GetClientRect(l, &r);
    return r.bottom;
}

fn syncScroll(self: *ConfigEditor) void {
    const list = self.list orelse return;
    const view = self.viewHeight();
    self.scroll = std.math.clamp(self.scroll, 0, @max(0, self.content_height - view));
    const info: c.SCROLLINFO = .{
        .fMask = c.SIF_RANGE | c.SIF_PAGE | c.SIF_POS,
        .nMin = 0,
        .nMax = @max(0, self.content_height - 1),
        .nPage = @intCast(@max(0, view)),
        .nPos = self.scroll,
    };
    _ = c.SetScrollInfo(list, c.SB_VERT, &info, c.TRUE);
}

fn scrollTo(self: *ConfigEditor, y: c_int) void {
    const before = self.scroll;
    self.scroll = y;
    self.syncScroll();
    if (self.scroll != before) {
        if (self.list) |l| _ = c.InvalidateRect(l, null, c.FALSE);
        if (self.edit != null) self.placeEdit();
    }
}

/// Scroll so the row of `option` shows.
fn reveal(self: *ConfigEditor, option: u16) void {
    const i = self.indexOfOption(option) orelse return;
    const it = self.items.items[i];
    // A card's first row shows its group's title too.
    const top = if (i > 0 and self.items.items[i - 1].kind == .group) self.items.items[i - 1].top else it.top;
    const view = self.viewHeight();
    if (top < self.scroll) self.scrollTo(top) else if (it.top + it.height > self.scroll + view) self.scrollTo(it.top + it.height - view);
}

/// A row's rectangles, in the list's client pixels: the row, its value's
/// control and its reset button.
const Rects = struct { row: c.RECT, control: c.RECT, reset: c.RECT };

fn rectsOf(self: *const ConfigEditor, it: Item) Rects {
    const page = self.pageX();
    const top = it.top - self.scroll;
    const row: c.RECT = .{ .left = page.left, .top = top, .right = page.right, .bottom = top + it.height };
    const pad = self.scale(row_pad);
    const head_h = self.scale(row_height);
    const rs = self.scale(reset_size);
    const reset: c.RECT = .{
        .left = row.right - pad - rs,
        .top = top + @divTrunc(head_h - rs, 2),
        .right = row.right - pad,
        .bottom = top + @divTrunc(head_h - rs, 2) + rs,
    };
    const cw = @min(self.scale(control_width), @divTrunc((row.right - row.left) * 2, 5));
    const ch = self.scale(field_height);
    const cright = reset.left - self.scale(6);
    var control: c.RECT = .{ .left = cright - cw, .top = top + @divTrunc(head_h - ch, 2), .right = cright, .bottom = top + @divTrunc(head_h - ch, 2) + ch };
    if (option_list.all[it.option].kind == .toggle) {
        const sw = self.scale(switch_width);
        const sh = self.scale(switch_height);
        control = .{ .left = cright - sw, .top = top + @divTrunc(head_h - sh, 2), .right = cright, .bottom = top + @divTrunc(head_h - sh, 2) + sh };
    }
    return .{ .row = row, .control = control, .reset = reset };
}

/// What is at (x, y) in the list's client pixels.
fn hit(self: *const ConfigEditor, x: c_int, y: c_int) ?struct { item: usize, part: Part } {
    for (self.items.items, 0..) |it, i| {
        if (it.kind != .option) continue;
        const r = self.rectsOf(it);
        if (!draw.contains(r.row, x, y)) continue;
        if (self.session.isSet(option_list.all[it.option].name) and draw.contains(r.reset, x, y)) return .{ .item = i, .part = .reset };
        if (draw.contains(r.control, x, y)) return .{ .item = i, .part = .control };
        return .{ .item = i, .part = .row };
    }
    return null;
}

// ---------------------------------------------------------------- values

/// `option`'s value as one line: a list's entries joined, else its value.
/// In `alloc`.
fn valueOf(self: *const ConfigEditor, alloc: Allocator, option: u16) []const u8 {
    const o = &option_list.all[option];
    const vals = self.session.values(alloc, o.name) catch return "";
    if (vals.len == 0) return "";
    return vals[0];
}

/// What the row's control shows.
fn display(self: *const ConfigEditor, alloc: Allocator, option: u16) []const u8 {
    const o = &option_list.all[option];
    if (o.kind == .list) {
        const entries = self.session.listEntries(alloc, o.name) catch return "";
        if (entries.len == 0) {
            const defaults = option_list.values(alloc, &self.session.defaults, o.name) catch return "";
            const n = for (defaults) |d| {
                if (d.len > 0) break defaults.len;
            } else 0;
            return if (n == 0) "None" else std.fmt.allocPrint(alloc, "{d} by default", .{n}) catch "";
        }
        return std.fmt.allocPrint(alloc, "{d} {s}", .{ entries.len, if (entries.len == 1) "entry" else "entries" }) catch "";
    }
    const v = self.valueOf(alloc, option);
    return if (v.len == 0) "None" else v;
}

/// The subtitle: where the value comes from when an included file sets it,
/// a value Ghostty doesn't take, else the documentation's first sentence.
fn subtitle(self: *const ConfigEditor, alloc: Allocator, option: u16, buf: []u8) struct { text: []const u8, color: c.COLORREF } {
    const o = &option_list.all[option];
    if (o.kind != .list) {
        const v = self.valueOf(alloc, option);
        if (self.session.isSet(o.name) and option_list.ghosttyLacks(o.name, v)) {
            return .{ .text = "Only murrtty takes this value: Ghostty reports it as an error", .color = self.pal.warning };
        }
        if (self.session.source(o.name)) |i| if (i != self.session.main) {
            const name = std.fs.path.basename(self.session.files.items[i].path);
            return .{ .text = std.fmt.allocPrint(alloc, "Set in {s}", .{name}) catch "", .color = self.pal.subtitle };
        };
    }
    return .{ .text = option_list.summary(o.doc, buf), .color = self.pal.subtitle };
}

/// Take `value` for single-valued `option`, if the loader would. Returns
/// whether it was taken; the loader's message shows if not.
fn commit(self: *ConfigEditor, option: u16, value: ?[]const u8) bool {
    const alloc = self.app.core_app.alloc;
    const o = &option_list.all[option];
    if (option_list.check(alloc, o.name, value) catch null) |message| {
        defer alloc.free(message);
        self.setStatus(true, "{s}: {s}", .{ o.name, message });
        return false;
    }
    self.session.set(o.name, value) catch |err| {
        self.setStatus(true, "{s}: not changed ({t})", .{ o.name, err });
        return false;
    };
    self.noteChange(o);
    return true;
}

/// Take `entries` for list `option` as the opened file's lines, each tried
/// as the loader would.
fn commitList(self: *ConfigEditor, option: u16, entries: []const ?[]const u8) bool {
    const alloc = self.app.core_app.alloc;
    const o = &option_list.all[option];
    for (entries) |e| {
        if (option_list.check(alloc, o.name, e) catch null) |message| {
            defer alloc.free(message);
            self.setStatus(true, "{s} = {s}: {s}", .{ o.name, e orelse "", message });
            return false;
        }
    }
    self.session.setList(o.name, entries) catch |err| {
        self.setStatus(true, "{s}: not changed ({t})", .{ o.name, err });
        return false;
    };
    self.noteChange(o);
    return true;
}

fn noteChange(self: *ConfigEditor, o: *const option_list.Option) void {
    self.changed.put(self.app.core_app.alloc, o.name, {}) catch {};
    const when: []const u8 = switch (o.reload()) {
        .live => "",
        .new_terminals => " It applies to terminals opened after the save.",
        .restart => " It applies once murrtty starts again.",
    };
    self.setStatus(false, "{s} changed. Save to keep it.{s}", .{ o.name, when });
    self.layout();
    _ = c.InvalidateRect(self.hwnd, &self.save_rect, c.FALSE);
}

fn resetOption(self: *ConfigEditor, option: u16) void {
    const o = &option_list.all[option];
    self.session.reset(o.name) catch |err| {
        self.setStatus(true, "{s}: not reset ({t})", .{ o.name, err });
        return;
    };
    self.noteChange(o);
}

/// Act on a row's control: flip a switch, open a choice's or flags' menu,
/// or put a field over the value.
fn activate(self: *ConfigEditor, item: usize) void {
    const it = self.items.items[item];
    const option = it.option;
    const o = &option_list.all[option];
    self.selected = option;
    switch (o.kind) {
        .toggle => {
            const alloc = self.app.core_app.alloc;
            var arena: std.heap.ArenaAllocator = .init(alloc);
            defer arena.deinit();
            const on = std.mem.eql(u8, self.valueOf(arena.allocator(), option), "true");
            _ = self.commit(option, if (on) "false" else "true");
        },
        .choice => self.pickChoice(item),
        .flags => self.pickFlags(item),
        .list => {
            self.expanded = option;
            self.layout();
            self.reveal(option);
            self.beginEdit(option);
        },
        .number, .text, .color, .path => self.beginEdit(option),
    }
}

fn screenPoint(self: *const ConfigEditor, x: c_int, y: c_int) c.POINT {
    var p: c.POINT = .{ .x = x, .y = y };
    if (self.list) |l| _ = c.ClientToScreen(l, &p);
    return p;
}

fn pickChoice(self: *ConfigEditor, item: usize) void {
    const it = self.items.items[item];
    const o = &option_list.all[it.option];
    const alloc = self.app.core_app.alloc;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const current = self.valueOf(arena.allocator(), it.option);
    const checked = arena.allocator().alloc(bool, o.names.len) catch return;
    for (o.names, checked) |n, *ck| ck.* = std.mem.eql(u8, n, current);
    const r = self.rectsOf(it).control;
    const at = self.screenPoint(r.left, r.bottom);
    const chosen = ContextMenu.pick(self.app, self.hwnd, at, o.names, checked) orelse return;
    _ = self.commit(it.option, o.names[chosen]);
}

/// The flags' menu: a click turns one on or off, and the menu opens again
/// until one is closed without a choice.
fn pickFlags(self: *ConfigEditor, item: usize) void {
    const it = self.items.items[item];
    const o = &option_list.all[it.option];
    const alloc = self.app.core_app.alloc;
    while (true) {
        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();
        const a = arena.allocator();
        const on = a.alloc(bool, o.names.len) catch return;
        flagsOf(self.valueOf(a, it.option), o.names, o.flag_defaults, on);
        const r = self.rectsOf(self.items.items[item]).control;
        const at = self.screenPoint(r.left, r.bottom);
        const chosen = ContextMenu.pick(self.app, self.hwnd, at, o.names, on) orelse return;
        on[chosen] = !on[chosen];
        const value = flagsValue(a, o.names, o.flag_defaults, on) catch return;
        if (!self.commit(it.option, value)) return;
    }
}

/// Which flags `value` turns on, as the loader reads a packed struct's
/// value (`cli_args.parsePackedStruct`): a boolean for all (`true`, `t`, `1`,
/// ...), else names split at commas, each with `no-` to turn it off, the
/// rest as their type has them (`defaults`).
fn flagsOf(value: []const u8, names: []const []const u8, defaults: []const bool, on: []bool) void {
    for (on, 0..) |*v, i| v.* = i < defaults.len and defaults[i];
    if (cli_args.parseBool(value)) |b| return @memset(on, b) else |_| {}
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        const tok = std.mem.trim(u8, raw, cli_args.whitespace);
        const negate = std.mem.startsWith(u8, tok, "no-");
        const name = if (negate) tok[3..] else tok;
        for (names, on) |n, *v| if (std.mem.eql(u8, n, name)) {
            v.* = !negate;
        };
    }
}

/// The value that gives the flags `on`: those that differ from their
/// type's defaults, as a file would name them, or all of them when none
/// does (an empty value isn't one the loader takes).
fn flagsValue(alloc: Allocator, names: []const []const u8, defaults: []const bool, on: []const bool) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(alloc);
    errdefer w.deinit();
    for (0..2) |pass| {
        var any = false;
        for (names, on, 0..) |n, v, i| {
            const d = i < defaults.len and defaults[i];
            if (pass == 0 and v == d) continue;
            if (any) try w.writer.writeByte(',');
            any = true;
            try w.writer.print("{s}{s}", .{ if (v) "" else "no-", n });
        }
        if (any) break;
    }
    return w.toOwnedSlice();
}

// ---------------------------------------------------------------- the field

/// Put a field over `option`'s value (a list's lines in a box under its
/// documentation), holding what the file gives it, else empty with the
/// default as its placeholder.
fn beginEdit(self: *ConfigEditor, option: u16) void {
    self.endEdit(.cancel);
    const list = self.list orelse return;
    const o = &option_list.all[option];
    const multi = o.kind == .list;
    const style: c.DWORD = c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | @as(c.DWORD, if (multi)
        c.ES_MULTILINE | c.ES_AUTOVSCROLL | c.ES_WANTRETURN | c.WS_VSCROLL | c.ES_AUTOHSCROLL
    else
        c.ES_AUTOHSCROLL);
    const edit = c.CreateWindowExW(0, c.L("EDIT"), c.L(""), style, 0, 0, 10, 10, list, @ptrFromInt(id_edit), self.app.instance, null) orelse return;
    self.edit = edit;
    self.edit_option = option;
    _ = c.SendMessageW(edit, c.WM_SETFONT, @intFromPtr(self.fonts.title), 0);
    _ = c.SetWindowTheme(edit, if (self.dark) c.L("DarkMode_Explorer") else c.L("Explorer"), null);
    _ = c.SendMessageW(edit, c.EM_LIMITTEXT, if (multi) 64 * 1024 else max_value, 0);
    self.edit_proc = c.SetWindowLongPtrW(edit, c.GWLP_WNDPROC, @bitCast(@intFromPtr(&editProc)));

    const alloc = self.app.core_app.alloc;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var initial: std.ArrayList(u8) = .empty;
    if (multi) {
        // The opened file's lines; the included files' entries stay as
        // they are.
        const entries = self.session.mainEntries(a, o.name) catch &.{};
        for (entries) |e| {
            initial.appendSlice(a, fieldLine(e)) catch {};
            initial.appendSlice(a, "\r\n") catch {};
        }
    } else if (self.session.isSet(o.name)) {
        initial.appendSlice(a, self.valueOf(a, option)) catch {};
    } else {
        const v = self.valueOf(a, option);
        if (text_util.utf16Lossy(a, v) catch null) |cue| _ = c.SendMessageW(edit, c.EM_SETCUEBANNER, 1, @bitCast(@intFromPtr(cue.ptr)));
    }
    if (text_util.utf16Lossy(a, initial.items) catch null) |w| _ = c.SetWindowTextW(edit, w.ptr);
    _ = c.SendMessageW(edit, c.EM_SETSEL, 0, -1);
    self.placeEdit();
    _ = c.SetFocus(edit);
}

/// The field's place: over the value's box, or under an opened list's
/// documentation.
fn placeEdit(self: *ConfigEditor) void {
    const edit = self.edit orelse return;
    const option = self.edit_option orelse return;
    const i = self.indexOfOption(option) orelse return self.endEdit(.cancel);
    const it = self.items.items[i];
    const r = self.rectsOf(it);
    const o = &option_list.all[option];
    const inset = self.scale(9);
    if (o.kind == .list) {
        const h = self.scale(list_edit_height);
        const bottom = r.row.bottom - self.scale(doc_pad);
        const left = r.row.left + self.scale(row_pad);
        _ = c.SetWindowPos(edit, null, left + inset, bottom - h + inset, r.row.right - self.scale(row_pad) - left - 2 * inset, h - 2 * inset, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
        return;
    }
    const line = self.lineHeight(self.fonts.title) + 2;
    const swatch: c_int = if (o.kind == .color) self.scale(swatch_size) + self.scale(8) else 0;
    const ctl = r.control;
    _ = c.SetWindowPos(edit, null, ctl.left + inset + swatch, ctl.top + @divTrunc(ctl.bottom - ctl.top - line, 2), ctl.right - ctl.left - 2 * inset - swatch, line, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
}

const EndHow = enum { commit, cancel };

/// Take the field's text (`commit`) or not, and remove it.
fn endEdit(self: *ConfigEditor, how: EndHow) void {
    const edit = self.edit orelse return;
    const option = self.edit_option orelse return;
    // Before anything that could move the keyboard and end it again.
    self.edit = null;
    self.edit_option = null;
    // A value refused says why in the status line, and stays as it was.
    if (how == .commit) _ = self.commitField(edit, option);
    _ = c.SetWindowLongPtrW(edit, c.GWLP_WNDPROC, self.edit_proc);
    _ = c.DestroyWindow(edit);
    if (self.list) |l| {
        _ = c.InvalidateRect(l, null, c.FALSE);
        if (c.GetFocus() == null) _ = c.SetFocus(l);
    }
}

/// What the field holds, taken for `option`. Returns whether it was taken.
fn commitField(self: *ConfigEditor, edit: c.HWND, option: u16) bool {
    const alloc = self.app.core_app.alloc;
    const o = &option_list.all[option];
    const len: usize = @intCast(@max(0, c.GetWindowTextLengthW(edit)));
    const wide = alloc.alloc(u16, len + 1) catch return false;
    defer alloc.free(wide);
    const n: usize = @intCast(@max(0, c.GetWindowTextW(edit, wide.ptr, @intCast(wide.len))));
    const text = std.unicode.utf16LeToUtf8Alloc(alloc, wide[0..n]) catch {
        self.setStatus(true, "{s}: the text isn't valid Unicode", .{o.name});
        return false;
    };
    defer alloc.free(text);
    if (o.kind == .list) {
        var entries: std.ArrayList(?[]const u8) = .empty;
        defer entries.deinit(alloc);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const l = std.mem.trimEnd(u8, line, "\r");
            // A blank line is space; `""` is the empty value.
            if (l.len == 0) continue;
            entries.append(alloc, if (std.mem.eql(u8, l, empty_line)) "" else l) catch return false;
        }
        // Unchanged: nothing to write.
        if (self.sameList(o.name, entries.items)) return true;
        return self.commitList(option, entries.items);
    }
    // Unchanged, or emptied while unset: nothing to write.
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    if (self.session.isSet(o.name) and std.mem.eql(u8, text, self.valueOf(arena.allocator(), option))) return true;
    if (!self.session.isSet(o.name) and text.len == 0) return true;
    return self.commit(option, text);
}

/// How a list's field shows the empty value, which resets the list in a
/// file (`font-family = ""`, `keybind =`): blank lines in the field are
/// only space.
const empty_line = "\"\"";

fn fieldLine(value: ?[]const u8) []const u8 {
    const v = value orelse return empty_line;
    return if (v.len == 0) empty_line else v;
}

fn sameList(self: *const ConfigEditor, name: []const u8, entries: []const ?[]const u8) bool {
    const alloc = self.app.core_app.alloc;
    const have = self.session.mainEntries(alloc, name) catch return false;
    defer alloc.free(have);
    if (have.len != entries.len) return false;
    for (have, entries) |h, e| {
        if (!std.mem.eql(u8, h orelse "", e orelse "")) return false;
    }
    return true;
}

/// The field: Enter takes it (Ctrl+Enter in a list's), Escape leaves it
/// unchanged, and leaving it takes it.
fn editProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const list = c.GetParent(hwnd);
    const self = if (list) |l| listOwner(l) else null;
    const s = self orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const proc = s.edit_proc;
    switch (msg) {
        c.WM_GETDLGCODE => return c.CallWindowProcW(proc, hwnd, msg, wparam, lparam) | c.DLGC_WANTALLKEYS,
        c.WM_KEYDOWN => {
            const ctrl = ctrlOnly();
            const multi = s.edit_option != null and option_list.all[s.edit_option.?].kind == .list;
            if (wparam == c.VK_ESCAPE) {
                s.endEdit(.cancel);
                return 0;
            }
            if (wparam == c.VK_RETURN and (!multi or ctrl)) {
                s.endEdit(.commit);
                return 0;
            }
            if (ctrl and wparam == 'S') {
                s.endEdit(.commit);
                s.save();
                return 0;
            }
        },
        c.WM_CHAR => {
            // The Enter and Escape handled above, and Ctrl+S's ^S, beep
            // otherwise.
            const multi = s.edit_option != null and option_list.all[s.edit_option.?].kind == .list;
            if (wparam == 0x1B or wparam == 0x13 or (wparam == '\r' and !multi) or wparam == '\n') return 0;
        },
        c.WM_KILLFOCUS => {
            // Into a menu or a dialog of its own (the refusal shows in the
            // status line): the field stays.
            const r = c.CallWindowProcW(proc, hwnd, msg, wparam, lparam);
            if (s.edit == hwnd) s.endEdit(.commit);
            return r;
        },
        // Its own menu runs a loop of its own: closes and requests wait
        // until it ends (App.beginModal).
        c.WM_CONTEXTMENU => {
            var modal = s.app.beginModal(s.hwnd, .{ .disable_others = false });
            defer modal.end();
            return c.CallWindowProcW(proc, hwnd, msg, wparam, lparam);
        },
        else => {},
    }
    return c.CallWindowProcW(proc, hwnd, msg, wparam, lparam);
}

/// Ctrl held without Alt: Ctrl+Alt is AltGr, which types characters.
fn ctrlOnly() bool {
    return c.GetKeyState(c.VK_CONTROL) < 0 and c.GetKeyState(c.VK_MENU) >= 0;
}

// ---------------------------------------------------------------- saving

/// Write the changed files and reload. A file changed outside the editor
/// since it was read asks before it is overwritten.
fn save(self: *ConfigEditor) void {
    self.endEdit(.commit);
    const alloc = self.app.core_app.alloc;
    if (!self.session.dirty()) {
        self.setStatus(false, "No changes to save", .{});
        return;
    }
    const changed = self.session.changedFiles(alloc) catch |err| {
        self.setStatus(true, "Not saved ({t})", .{err});
        return;
    };
    defer {
        for (changed) |ch| alloc.free(ch.text);
        alloc.free(changed);
    }
    for (changed) |ch| {
        const original = self.session.files.items[ch.index].original;
        const moved = switch (readFile(alloc, ch.path)) {
            .text => |d| moved: {
                defer alloc.free(d);
                break :moved !std.mem.eql(u8, d, original);
            },
            .not_found => original.len > 0,
            .failed => |reason| {
                self.setStatus(true, "Not saved: {s} can't be read ({s})", .{ ch.path, reason });
                return;
            },
        };
        if (moved and !self.askOverwrite(ch.path)) {
            self.setStatus(true, "Not saved: {s} changed outside the editor", .{ch.path});
            return;
        }
    }
    for (changed) |ch| {
        writeFile(alloc, ch.path, ch.text) catch |err| {
            if (err == error.CutShort) {
                self.setStatus(true, "{s} not saved whole: the new text is beside it, in a file ending .murrtty-save", .{ch.path});
            } else {
                self.setStatus(true, "{s} not saved ({t})", .{ ch.path, err });
            }
            return;
        };
        self.session.saved(ch.index, ch.text) catch {};
    }
    // When the changes take effect.
    var later: ?option_list.Reload = null;
    var it = self.changed.keyIterator();
    while (it.next()) |name| {
        const o = option_list.find(name.*) orelse continue;
        const r = o.reload();
        if (r == .restart or (r == .new_terminals and later != .restart)) later = r;
    }
    self.changed.clearRetainingCapacity();
    self.app.reloadConfigFiles();
    const when: []const u8 = if (later) |r| switch (r) {
        .live => "",
        .new_terminals => " Some changes apply to terminals opened from now on.",
        .restart => " Some changes apply once murrtty starts again.",
    } else "";
    self.setStatus(false, "Saved {s}.{s}", .{ self.path, when });
    _ = c.InvalidateRect(self.hwnd, &self.save_rect, c.FALSE);
    if (self.list) |l| _ = c.InvalidateRect(l, null, c.FALSE);
}

fn askOverwrite(self: *ConfigEditor, path: []const u8) bool {
    const alloc = self.app.core_app.alloc;
    const body = std.fmt.allocPrint(alloc, "{s} changed after the editor read it. Saving replaces those changes.", .{path}) catch return false;
    defer alloc.free(body);
    var modal = self.app.beginModal(self.hwnd, .{});
    defer modal.end();
    const result = AlertDialog.run(alloc, .{
        .owner = self.hwnd,
        .heading = "File Changed",
        .body = body,
        .responses = &.{
            .{ .id = c.IDCANCEL, .label = "Cancel" },
            .{ .id = id_overwrite, .label = "Replace", .appearance = .destructive },
        },
        .default = c.IDCANCEL,
        .dark = self.dark,
    }) orelse return false;
    return result.id == id_overwrite;
}

/// Closing with changes unsaved: Save, Discard or Cancel, libadwaita's
/// unsaved-changes dialog. True to close.
fn confirmClose(self: *ConfigEditor) bool {
    self.endEdit(.commit);
    if (!self.session.dirty()) return true;
    const alloc = self.app.core_app.alloc;
    const chosen = chosen: {
        var modal = self.app.beginModal(self.hwnd, .{});
        defer modal.end();
        const result = AlertDialog.run(alloc, .{
            .owner = self.hwnd,
            .heading = "Save Changes?",
            .body = "The configuration has changes that aren't saved.",
            .responses = &.{
                .{ .id = c.IDCANCEL, .label = "Cancel" },
                .{ .id = id_discard, .label = "Discard", .appearance = .destructive },
                .{ .id = id_save, .label = "Save", .appearance = .suggested },
            },
            .default = id_save,
            .dark = self.dark,
        }) orelse return false;
        break :chosen result.id;
    };
    switch (chosen) {
        id_discard => return true,
        id_save => {
            self.save();
            return !self.session.dirty();
        },
        else => return false,
    }
}

// ---------------------------------------------------------------- painting

fn paintBar(self: *ConfigEditor, dc: c.HDC) void {
    var client: c.RECT = .{};
    _ = c.GetClientRect(self.hwnd, &client);
    const pal = self.pal;
    draw.fill(dc, .{ .left = 0, .top = 0, .right = client.right, .bottom = self.scale(bar_height) }, pal.bg);
    const footer: c.RECT = .{ .left = 0, .top = client.bottom - self.scale(footer_height), .right = client.right, .bottom = client.bottom };
    draw.fill(dc, footer, pal.bg);
    _ = c.SetBkMode(dc, c.TRANSPARENT);
    const radius = self.scale(field_radius);

    // The search field's box, ringed while it has the keyboard.
    const focused = self.search != null and c.GetFocus() == self.search;
    if (focused) {
        const ring = @max(1, self.scale(2));
        const r = self.search_rect;
        draw.roundRect(dc, .{ .left = r.left - ring, .top = r.top - ring, .right = r.right + ring, .bottom = r.bottom + ring }, radius + ring, pal.focus, null, 0);
    }
    draw.roundRect(dc, self.search_rect, radius, pal.field, null, 0);

    // The page button: its label and a chevron.
    const old = if (self.fonts.button) |f| c.SelectObject(dc, f) else null;
    defer if (old) |o| {
        _ = c.SelectObject(dc, o);
    };
    draw.roundRect(dc, self.group_rect, radius, if (self.pressed == .group) pal.pressed else pal.field, null, 0);
    var buf: [64]u16 = undefined;
    const label = text_util.utf16Into(&buf, self.groupLabel());
    var lr = self.group_rect;
    lr.left += self.scale(button_pad_x);
    lr.right -= self.scale(button_pad_x) + self.scale(10);
    _ = c.SetTextColor(dc, pal.text);
    _ = c.DrawTextW(dc, label.ptr, @intCast(label.len), &lr, c.DT_SINGLELINE | c.DT_VCENTER | c.DT_NOPREFIX | c.DT_END_ELLIPSIS);
    const cy = @divTrunc(self.group_rect.top + self.group_rect.bottom, 2);
    draw.triangleDown(dc, self.group_rect.right - self.scale(button_pad_x) + self.scale(2), cy, self.scale(4), self.scale(4), pal.text);

    // Save: the suggested button while there are changes.
    const dirty = self.session.dirty();
    draw.roundRect(dc, self.save_rect, radius, if (dirty) pal.accent else pal.field, null, 0);
    _ = c.SetTextColor(dc, if (dirty) pal.accent_text else pal.subtitle);
    var sr = self.save_rect;
    _ = c.DrawTextW(dc, c.L("Save"), 4, &sr, c.DT_SINGLELINE | c.DT_VCENTER | c.DT_CENTER | c.DT_NOPREFIX);

    // The status line.
    const small = if (self.fonts.subtitle) |f| c.SelectObject(dc, f) else null;
    defer if (small) |o| {
        _ = c.SelectObject(dc, o);
    };
    var status_buf: [512]u16 = undefined;
    const status = text_util.utf16Into(&status_buf, self.status[0..self.status_len]);
    var fr = footer;
    fr.left += self.scale(bar_pad);
    fr.right -= self.scale(bar_pad);
    _ = c.SetTextColor(dc, if (self.status_error) pal.err else pal.subtitle);
    _ = c.DrawTextW(dc, status.ptr, @intCast(status.len), &fr, c.DT_SINGLELINE | c.DT_VCENTER | c.DT_NOPREFIX | c.DT_END_ELLIPSIS);
}

fn paintList(self: *ConfigEditor, dc: c.HDC, client: c.RECT) void {
    const alloc = self.app.core_app.alloc;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const pal = self.pal;
    draw.fill(dc, client, pal.bg);
    _ = c.SetBkMode(dc, c.TRANSPARENT);
    if (self.items.items.len == 0) {
        const old = if (self.fonts.title) |f| c.SelectObject(dc, f) else null;
        defer if (old) |o| {
            _ = c.SelectObject(dc, o);
        };
        _ = c.SetTextColor(dc, pal.subtitle);
        var r = client;
        r.top += self.scale(48);
        _ = c.DrawTextW(dc, c.L("No options match"), 16, &r, c.DT_SINGLELINE | c.DT_CENTER | c.DT_NOPREFIX);
        return;
    }
    const page = self.pageX();
    const view_top = self.scroll;
    const view_bottom = self.scroll + client.bottom;

    // The cards first, under their rows.
    var i: usize = 0;
    while (i < self.items.items.len) : (i += 1) {
        const it = self.items.items[i];
        if (it.kind != .option or !it.first) continue;
        var j = i;
        while (!self.items.items[j].last) j += 1;
        const last = self.items.items[j];
        if (last.top + last.height < view_top or it.top > view_bottom) continue;
        draw.roundRect(dc, .{ .left = page.left, .top = it.top - self.scroll, .right = page.right, .bottom = last.top + last.height - self.scroll }, self.scale(card_radius), pal.card, null, 0);
    }

    for (self.items.items, 0..) |it, idx| {
        if (it.top + it.height < view_top or it.top > view_bottom) continue;
        switch (it.kind) {
            .group => {
                const old = if (self.fonts.heading) |f| c.SelectObject(dc, f) else null;
                defer if (old) |o| {
                    _ = c.SelectObject(dc, o);
                };
                var buf: [64]u16 = undefined;
                const t = text_util.utf16Into(&buf, it.group.title());
                var r: c.RECT = .{ .left = page.left + self.scale(2), .top = it.top - self.scroll, .right = page.right, .bottom = it.top - self.scroll + it.height - self.scale(6) };
                _ = c.SetTextColor(dc, pal.text);
                _ = c.DrawTextW(dc, t.ptr, @intCast(t.len), &r, c.DT_SINGLELINE | c.DT_BOTTOM | c.DT_NOPREFIX);
            },
            .option => self.paintRow(dc, a, it, idx),
        }
    }
}

fn paintRow(self: *ConfigEditor, dc: c.HDC, a: Allocator, it: Item, idx: usize) void {
    const pal = self.pal;
    const o = &option_list.all[it.option];
    const r = self.rectsOf(it);
    const pad = self.scale(row_pad);
    const head_h = self.scale(row_height);
    const radius = self.scale(card_radius);
    const selected = self.selected == it.option;

    // The row under the mouse or the keyboard, inside its card's corners.
    if (selected or (self.hover_item == idx and self.hover_part == .row)) {
        var hr = r.row;
        hr.bottom = hr.top + head_h;
        const inset: c_int = 0;
        draw.roundRect(dc, .{ .left = hr.left + inset, .top = hr.top, .right = hr.right - inset, .bottom = hr.bottom }, if (it.first or it.last) radius else 0, if (selected) pal.pressed else pal.hover, null, 0);
        if (!it.first) draw.fill(dc, .{ .left = hr.left, .top = hr.top, .right = hr.right, .bottom = hr.top + radius }, if (selected) pal.pressed else pal.hover);
        if (!it.last or self.expanded == it.option) draw.fill(dc, .{ .left = hr.left, .top = hr.bottom - radius, .right = hr.right, .bottom = hr.bottom }, if (selected) pal.pressed else pal.hover);
    }
    if (!it.first) draw.fill(dc, .{ .left = r.row.left, .top = r.row.top, .right = r.row.right, .bottom = r.row.top + @max(1, self.scale(1)) }, pal.separator);

    // Title and subtitle, clear of the control.
    const text_right = r.control.left - self.scale(12);
    {
        const old = if (self.fonts.title) |f| c.SelectObject(dc, f) else null;
        defer if (old) |ob| {
            _ = c.SelectObject(dc, ob);
        };
        var buf: [96]u16 = undefined;
        const t = text_util.utf16Into(&buf, o.name);
        var tr: c.RECT = .{ .left = r.row.left + pad, .top = r.row.top + self.scale(9), .right = text_right, .bottom = r.row.top + head_h };
        _ = c.SetTextColor(dc, pal.text);
        _ = c.DrawTextW(dc, t.ptr, @intCast(t.len), &tr, c.DT_SINGLELINE | c.DT_NOPREFIX | c.DT_END_ELLIPSIS);
    }
    {
        const old = if (self.fonts.subtitle) |f| c.SelectObject(dc, f) else null;
        defer if (old) |ob| {
            _ = c.SelectObject(dc, ob);
        };
        var sbuf: [200]u8 = undefined;
        const sub = self.subtitle(a, it.option, &sbuf);
        const w = text_util.utf16Lossy(a, sub.text) catch return;
        var sr: c.RECT = .{ .left = r.row.left + pad, .top = r.row.top + self.scale(31), .right = text_right, .bottom = r.row.top + head_h };
        _ = c.SetTextColor(dc, sub.color);
        _ = c.DrawTextW(dc, w.ptr, @intCast(w.len), &sr, c.DT_SINGLELINE | c.DT_NOPREFIX | c.DT_END_ELLIPSIS);

        // The whole documentation, opened.
        if (self.expanded == it.option) {
            const doc = docText(a, o.doc) catch return;
            var dr: c.RECT = .{ .left = r.row.left + pad, .top = r.row.top + head_h, .right = r.row.right - pad, .bottom = r.row.bottom };
            _ = c.SetTextColor(dc, pal.subtitle);
            _ = c.DrawTextW(dc, doc.ptr, @intCast(doc.len), &dr, c.DT_WORDBREAK | c.DT_NOPREFIX | c.DT_EXPANDTABS);
            if (o.kind == .list) {
                const h = self.scale(list_edit_height);
                const bottom = r.row.bottom - self.scale(doc_pad);
                draw.roundRect(dc, .{ .left = r.row.left + pad, .top = bottom - h, .right = r.row.right - pad, .bottom = bottom }, self.scale(field_radius), pal.field, null, 0);
            }
        }
    }

    self.paintControl(dc, a, it, idx, r);

    // Reset: a flat round button with a cross, for an option a file sets.
    if (self.session.isSet(o.name)) {
        const hovered = self.hover_item == idx and self.hover_part == .reset;
        if (hovered) draw.roundRect(dc, r.reset, @divTrunc(r.reset.right - r.reset.left, 2), pal.hover, null, 0);
        const k = self.scale(8);
        const cx = @divTrunc(r.reset.left + r.reset.right, 2);
        const cy = @divTrunc(r.reset.top + r.reset.bottom, 2);
        draw.cross(dc, .{ .left = cx - @divTrunc(k, 2), .top = cy - @divTrunc(k, 2), .right = cx + @divTrunc(k, 2), .bottom = cy + @divTrunc(k, 2) }, self.dpi, pal.subtitle);
    }
}

fn paintControl(self: *ConfigEditor, dc: c.HDC, a: Allocator, it: Item, idx: usize, r: Rects) void {
    const pal = self.pal;
    const o = &option_list.all[it.option];
    const ctl = r.control;
    const set = self.session.isSet(o.name);
    const hovered = self.hover_item == idx and self.hover_part == .control;
    switch (o.kind) {
        .toggle => {
            const on = std.mem.eql(u8, self.valueOf(a, it.option), "true");
            const sh = ctl.bottom - ctl.top;
            draw.roundRect(dc, ctl, @divTrunc(sh, 2), if (on) pal.accent else pal.switch_off, null, 0);
            const inset = self.scale(3);
            const knob = sh - 2 * inset;
            const kx = if (on) ctl.right - inset - knob else ctl.left + inset;
            draw.roundRect(dc, .{ .left = kx, .top = ctl.top + inset, .right = kx + knob, .bottom = ctl.top + inset + knob }, @divTrunc(knob, 2), pal.knob, null, 0);
            return;
        },
        else => {},
    }
    // The editing field draws its own text over the box.
    draw.roundRect(dc, ctl, self.scale(field_radius), if (hovered) pal.pressed else pal.field, null, 0);
    if (self.edit_option == it.option and o.kind != .list) return;
    const old = if (self.fonts.title) |f| c.SelectObject(dc, f) else null;
    defer if (old) |ob| {
        _ = c.SelectObject(dc, ob);
    };
    var tr = ctl;
    tr.left += self.scale(9);
    tr.right -= self.scale(9);
    if (o.kind == .color) {
        const v = self.valueOf(a, it.option);
        if (configpkg.Config.Color.parseCLI(v) catch null) |color| {
            const s = self.scale(swatch_size);
            const top = ctl.top + @divTrunc(ctl.bottom - ctl.top - s, 2);
            draw.roundRect(dc, .{ .left = tr.left, .top = top, .right = tr.left + s, .bottom = top + s }, self.scale(4), draw.ref(color), pal.separator, 1);
        }
        tr.left += self.scale(swatch_size) + self.scale(8);
    }
    const chevron = o.kind == .choice or o.kind == .flags or o.kind == .list;
    if (chevron) tr.right -= self.scale(12);
    const shown = self.display(a, it.option);
    const w = text_util.utf16Lossy(a, shown) catch return;
    _ = c.SetTextColor(dc, if (set) pal.text else pal.subtitle);
    _ = c.DrawTextW(dc, w.ptr, @intCast(w.len), &tr, c.DT_SINGLELINE | c.DT_VCENTER | c.DT_NOPREFIX | c.DT_END_ELLIPSIS);
    if (chevron) {
        const cy = @divTrunc(ctl.top + ctl.bottom, 2);
        draw.triangleDown(dc, ctl.right - self.scale(12), cy, self.scale(4), self.scale(4), pal.text);
    }
}

// ---------------------------------------------------------------- input

fn moveSelection(self: *ConfigEditor, delta: i32) void {
    var options: std.ArrayList(u16) = .empty;
    defer options.deinit(self.app.core_app.alloc);
    for (self.items.items) |it| if (it.kind == .option) options.append(self.app.core_app.alloc, it.option) catch return;
    if (options.items.len == 0) return;
    var cur: i64 = -1;
    if (self.selected) |s| for (options.items, 0..) |o, i| {
        if (o == s) cur = @intCast(i);
    };
    const next: usize = @intCast(std.math.clamp(cur + delta, 0, @as(i64, @intCast(options.items.len - 1))));
    self.selected = options.items[next];
    self.reveal(self.selected.?);
    if (self.list) |l| _ = c.InvalidateRect(l, null, c.FALSE);
}

fn toggleExpanded(self: *ConfigEditor, option: u16) void {
    self.endEdit(.commit);
    self.expanded = if (self.expanded == option) null else option;
    self.layout();
    self.reveal(option);
}

fn chooseGroup(self: *ConfigEditor) void {
    const groups = @typeInfo(option_list.Group).@"enum".field_names;
    var labels: [groups.len + 1][]const u8 = undefined;
    var checked: [groups.len + 1]bool = undefined;
    labels[0] = "All Pages";
    checked[0] = self.group == null;
    inline for (groups, 1..) |gname, i| {
        const g = @field(option_list.Group, gname);
        labels[i] = g.title();
        checked[i] = self.group == g;
    }
    var at: c.POINT = .{ .x = self.group_rect.left, .y = self.group_rect.bottom };
    _ = c.ClientToScreen(self.hwnd, &at);
    const chosen = ContextMenu.pick(self.app, self.hwnd, at, &labels, &checked) orelse return;
    // What is typed, taken before its row may leave the page.
    self.endEdit(.commit);
    self.group = if (chosen == 0) null else @enumFromInt(chosen - 1);
    self.scroll = 0;
    self.layoutBar();
    self.rebuild();
    _ = c.InvalidateRect(self.hwnd, null, c.FALSE);
}

fn onSearchChanged(self: *ConfigEditor) void {
    const search = self.search orelse return;
    var buf: [max_query + 1]u16 = undefined;
    const n: usize = @intCast(@max(0, c.GetWindowTextW(search, &buf, buf.len)));
    const alloc = self.app.core_app.alloc;
    const text = std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..n]) catch return;
    defer alloc.free(text);
    self.query.clearRetainingCapacity();
    self.query.appendSlice(alloc, text) catch return;
    self.endEdit(.commit);
    self.scroll = 0;
    self.rebuild();
}

/// Keys every part of the window takes: Ctrl+S saves, Ctrl+F searches,
/// Escape closes an opened row. Returns whether the key was taken.
fn commonKey(self: *ConfigEditor, key: c.WPARAM) bool {
    if (!ctrlOnly()) return false;
    switch (key) {
        'S' => {
            self.save();
            return true;
        },
        'F' => {
            if (self.search) |s| {
                _ = c.SetFocus(s);
                _ = c.SendMessageW(s, c.EM_SETSEL, 0, -1);
            }
            return true;
        },
        else => return false,
    }
}

fn listKey(self: *ConfigEditor, key: c.WPARAM) bool {
    if (self.commonKey(key)) return true;
    switch (key) {
        c.VK_UP => self.moveSelection(-1),
        c.VK_DOWN => self.moveSelection(1),
        c.VK_PRIOR => self.moveSelection(-8),
        c.VK_NEXT => self.moveSelection(8),
        c.VK_HOME => self.moveSelection(-1_000_000),
        c.VK_END => self.moveSelection(1_000_000),
        c.VK_RETURN, c.VK_SPACE => {
            const s = self.selected orelse return true;
            const i = self.indexOfOption(s) orelse return true;
            self.activate(i);
        },
        c.VK_DELETE => {
            const s = self.selected orelse return true;
            if (self.session.isSet(option_list.all[s].name)) self.resetOption(s);
        },
        // F1: the selected option's documentation, whole.
        0x70 => if (self.selected) |s| self.toggleExpanded(s),
        c.VK_ESCAPE => if (self.expanded) |e| self.toggleExpanded(e),
        else => return false,
    }
    return true;
}

fn listOwner(list: c.HWND) ?*ConfigEditor {
    const main = c.GetParent(list) orelse return null;
    return fromHwnd(main);
}

fn listProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const self = listOwner(hwnd) orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    switch (msg) {
        c.WM_ERASEBKGND => return 1,
        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = undefined;
            const dc = c.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = c.EndPaint(hwnd, &ps);
            var client: c.RECT = .{};
            _ = c.GetClientRect(hwnd, &client);
            // Drawn off screen, then copied: no flicker while scrolling.
            const mem = c.CreateCompatibleDC(dc) orelse return 0;
            defer _ = c.DeleteDC(mem);
            const bmp = c.CreateCompatibleBitmap(dc, @max(1, client.right), @max(1, client.bottom)) orelse return 0;
            defer _ = c.DeleteObject(bmp);
            const old = c.SelectObject(mem, bmp);
            defer _ = c.SelectObject(mem, old);
            self.paintList(mem, client);
            _ = c.BitBlt(dc, 0, 0, client.right, client.bottom, mem, 0, 0, c.SRCCOPY);
            return 0;
        },
        c.WM_SIZE => {
            self.layout();
            return 0;
        },
        c.WM_VSCROLL => {
            var info: c.SCROLLINFO = .{ .fMask = c.SIF_ALL };
            _ = c.GetScrollInfo(hwnd, c.SB_VERT, &info);
            const view = self.viewHeight();
            const step = self.scale(line_step);
            const y: c_int = switch (c.loword(wparam)) {
                c.SB_LINEUP => self.scroll - step,
                c.SB_LINEDOWN => self.scroll + step,
                c.SB_PAGEUP => self.scroll - view,
                c.SB_PAGEDOWN => self.scroll + view,
                c.SB_THUMBTRACK => info.nTrackPos,
                c.SB_TOP => 0,
                c.SB_BOTTOM => self.content_height,
                else => self.scroll,
            };
            self.scrollTo(y);
            return 0;
        },
        c.WM_MOUSEWHEEL => {
            const delta: i16 = @bitCast(c.hiword(wparam));
            self.scrollTo(self.scroll - @divTrunc(@as(c_int, delta) * self.scale(line_step) * 3, 120));
            return 0;
        },
        c.WM_LBUTTONDOWN => {
            _ = c.SetFocus(hwnd);
            const x = c.xParam(lparam);
            const y = c.yParam(lparam);
            const h = self.hit(x, y) orelse return 0;
            const option = self.items.items[h.item].option;
            switch (h.part) {
                .reset => self.resetOption(option),
                .control => self.activate(h.item),
                .row => {
                    self.selected = option;
                    self.toggleExpanded(option);
                },
            }
            _ = c.InvalidateRect(hwnd, null, c.FALSE);
            return 0;
        },
        c.WM_MOUSEMOVE => {
            if (!self.tracking) {
                var tme: c.TRACKMOUSEEVENT = .{ .dwFlags = c.TME_LEAVE, .hwndTrack = hwnd };
                _ = c.TrackMouseEvent(&tme);
                self.tracking = true;
            }
            const h = self.hit(c.xParam(lparam), c.yParam(lparam));
            const item: ?usize = if (h) |v| v.item else null;
            const part: ?Part = if (h) |v| v.part else null;
            if (item != self.hover_item or part != self.hover_part) {
                self.hover_item = item;
                self.hover_part = part;
                _ = c.InvalidateRect(hwnd, null, c.FALSE);
            }
            return 0;
        },
        c.WM_MOUSELEAVE => {
            self.tracking = false;
            if (self.hover_item != null) {
                self.hover_item = null;
                self.hover_part = null;
                _ = c.InvalidateRect(hwnd, null, c.FALSE);
            }
            return 0;
        },
        c.WM_SETCURSOR => if (c.loword(lparam) == c.HTCLIENT) {
            const cursor = if (self.hover_part != null and self.hover_part.? != .row) c.IDC_HAND else c.IDC_ARROW;
            _ = c.SetCursor(c.LoadCursorW(null, cursor));
            return 1;
        },
        c.WM_GETDLGCODE => return c.DLGC_WANTALLKEYS,
        c.WM_KEYDOWN => if (self.listKey(wparam)) return 0,
        c.WM_SETFOCUS, c.WM_KILLFOCUS => {
            _ = c.InvalidateRect(hwnd, null, c.FALSE);
            return 0;
        },
        c.WM_CTLCOLOREDIT => {
            const dc: c.HDC = @ptrFromInt(wparam);
            _ = c.SetTextColor(dc, self.pal.text);
            _ = c.SetBkColor(dc, self.pal.field);
            return @bitCast(@intFromPtr(self.edit_brush));
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// The search field: Down or Enter moves to the list, Escape empties it,
/// and the window's own keys.
fn searchProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const main = c.GetParent(hwnd);
    const self = if (main) |m| fromHwnd(m) else null;
    const s = self orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    switch (msg) {
        c.WM_KEYDOWN => {
            if (s.commonKey(wparam)) return 0;
            switch (wparam) {
                c.VK_DOWN, c.VK_RETURN => {
                    if (s.selected == null) s.moveSelection(1);
                    if (s.list) |l| _ = c.SetFocus(l);
                    return 0;
                },
                c.VK_ESCAPE => {
                    _ = c.SetWindowTextW(hwnd, c.L(""));
                    return 0;
                },
                else => {},
            }
        },
        // Enter, Escape and Ctrl's keys, handled above, would beep.
        c.WM_CHAR => if (wparam == '\r' or wparam == 0x1B or wparam == 0x13 or wparam == 0x06) return 0,
        c.WM_CONTEXTMENU => {
            var modal = s.app.beginModal(s.hwnd, .{ .disable_others = false });
            defer modal.end();
            return c.CallWindowProcW(s.search_proc, hwnd, msg, wparam, lparam);
        },
        c.WM_SETFOCUS, c.WM_KILLFOCUS => {
            const r = c.CallWindowProcW(s.search_proc, hwnd, msg, wparam, lparam);
            var ring = s.search_rect;
            const k = s.scale(3);
            ring = .{ .left = ring.left - k, .top = ring.top - k, .right = ring.right + k, .bottom = ring.bottom + k };
            if (main) |m| _ = c.InvalidateRect(m, &ring, c.FALSE);
            return r;
        },
        else => {},
    }
    return c.CallWindowProcW(s.search_proc, hwnd, msg, wparam, lparam);
}

fn wndProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_NCCREATE => {
            const cs: *const c.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const self: *ConfigEditor = @ptrCast(@alignCast(cs.lpCreateParams.?));
            self.hwnd = hwnd;
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        else => {},
    }
    const self = fromHwnd(hwnd) orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    switch (msg) {
        c.WM_CREATE => {
            const instance = self.app.instance;
            const search = c.CreateWindowExW(0, c.L("EDIT"), c.L(""), c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.ES_AUTOHSCROLL, 0, 0, 10, 10, hwnd, @ptrFromInt(id_search), instance, null);
            if (search) |s| {
                self.search = s;
                _ = c.SendMessageW(s, c.EM_LIMITTEXT, max_query, 0);
                _ = c.SendMessageW(s, c.EM_SETCUEBANNER, 1, @bitCast(@intFromPtr(c.L("Search options").ptr)));
                self.search_proc = c.SetWindowLongPtrW(s, c.GWLP_WNDPROC, @bitCast(@intFromPtr(&searchProc)));
            }
            self.list = c.CreateWindowExW(0, list_class_name, c.L("Options"), c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.WS_VSCROLL, 0, 0, 10, 10, hwnd, @ptrFromInt(id_list), instance, null);
            return 0;
        },
        c.WM_ERASEBKGND => return 1,
        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = undefined;
            const dc = c.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = c.EndPaint(hwnd, &ps);
            self.paintBar(dc);
            return 0;
        },
        c.WM_SIZE => {
            self.layoutBar();
            _ = c.InvalidateRect(hwnd, null, c.FALSE);
            return 0;
        },
        c.WM_GETMINMAXINFO => {
            const info: *c.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
            info.ptMinTrackSize = .{ .x = self.scale(min_width), .y = self.scale(min_height) };
            return 0;
        },
        c.WM_DPICHANGED => {
            const r: *const c.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = c.SetWindowPos(hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
            self.refreshTheme();
            self.layout();
            return 0;
        },
        c.WM_SETTINGCHANGE => {
            self.refreshTheme();
            self.layout();
        },
        c.WM_CTLCOLOREDIT => {
            const dc: c.HDC = @ptrFromInt(wparam);
            _ = c.SetTextColor(dc, self.pal.text);
            _ = c.SetBkColor(dc, self.pal.field);
            return @bitCast(@intFromPtr(self.edit_brush));
        },
        c.WM_COMMAND => {
            if (c.loword(wparam) == id_search and c.hiword(wparam) == c.EN_CHANGE) self.onSearchChanged();
            return 0;
        },
        c.WM_LBUTTONDOWN => {
            const x = c.xParam(lparam);
            const y = c.yParam(lparam);
            if (draw.contains(self.save_rect, x, y)) {
                self.save();
            } else if (draw.contains(self.group_rect, x, y)) {
                self.pressed = .group;
                _ = c.InvalidateRect(hwnd, &self.group_rect, c.FALSE);
                self.chooseGroup();
                self.pressed = .none;
                _ = c.InvalidateRect(hwnd, &self.group_rect, c.FALSE);
            } else if (draw.contains(self.search_rect, x, y)) {
                if (self.search) |s| _ = c.SetFocus(s);
            }
            return 0;
        },
        c.WM_KEYDOWN => if (self.commonKey(wparam)) return 0,
        // The choice, flags and page menus, owner-drawn (ContextMenu.pick).
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
        // A click while a terminal window's dialog has it disabled: the
        // dialog comes forward (Window does the same).
        c.WM_SETCURSOR => {
            if (c.loword(lparam) == c.HTERROR) switch (c.hiword(lparam)) {
                c.WM_LBUTTONDOWN, c.WM_RBUTTONDOWN, c.WM_MBUTTONDOWN, c.WM_XBUTTONDOWN => self.app.raiseModal(),
                else => {},
            };
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        // The system menu's loop in a modal scope, as a terminal window's:
        // opened on WM_ENTERMENULOOP (wparam FALSE; the editor's own menus
        // have theirs) or as the system menu opens, ended with the loop.
        c.WM_INITMENUPOPUP => {
            if (c.hiword(lparam) != 0) if (c.GetSystemMenu(hwnd, c.FALSE)) |sys| if (sys == @as(c.HMENU, @ptrFromInt(wparam))) self.beginMenuModal();
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
        c.WM_DESTROY => {
            self.endMenuModal();
            return 0;
        },
        c.WM_ACTIVATE => {
            // The keyboard back where it was.
            if (c.loword(wparam) != c.WA_INACTIVE) {
                if (self.edit) |e| {
                    _ = c.SetFocus(e);
                } else if (self.list) |l| {
                    if (self.selected != null) _ = c.SetFocus(l) else if (self.search) |s| _ = c.SetFocus(s);
                }
            }
            return 0;
        },
        c.WM_CLOSE => {
            if (self.app.modal_depth > 0) return 0;
            if (self.confirmClose()) _ = c.DestroyWindow(hwnd);
            return 0;
        },
        c.WM_NCDESTROY => {
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
            if (self.created) self.free();
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

fn beginMenuModal(self: *ConfigEditor) void {
    if (self.menu_modal == null) self.menu_modal = self.app.beginModal(self.hwnd, .{ .disable_others = false });
}

fn endMenuModal(self: *ConfigEditor) void {
    if (self.menu_modal) |*m| m.end();
    self.menu_modal = null;
}

fn free(self: *ConfigEditor) void {
    const app = self.app;
    const alloc = app.core_app.alloc;
    if (self.search) |s| _ = c.SetWindowLongPtrW(s, c.GWLP_WNDPROC, self.search_proc);
    self.fonts.deinit();
    if (self.edit_brush) |b| _ = c.DeleteObject(b);
    self.session.deinit();
    alloc.free(self.path);
    self.items.deinit(alloc);
    self.query.deinit(alloc);
    self.changed.deinit(alloc);
    if (app.config_editor == self) app.config_editor = null;
    alloc.destroy(self);
    app.configEditorClosed();
}

/// The top bar and status line as WM_PAINT draws them, into `dc` (the GUI
/// tests' pictures, test_hooks).
pub fn paintBarTo(self: *ConfigEditor, dc: c.HDC, _: c.RECT) void {
    self.paintBar(dc);
}

/// The page as the list's WM_PAINT draws it, into `dc` over `rect`.
pub fn paintListTo(self: *ConfigEditor, dc: c.HDC, rect: c.RECT) void {
    self.paintList(dc, rect);
}

/// The list's client size, for the pictures.
pub fn listSize(self: *const ConfigEditor) c.RECT {
    var r: c.RECT = .{};
    if (self.list) |l| _ = c.GetClientRect(l, &r);
    return r;
}

/// The GUI tests' view of it (test_hooks): its windows, the file, what the
/// page shows and each row's value and places (in the list's client
/// pixels), the selection, and the status line.
pub fn writeDump(self: *const ConfigEditor, alloc: Allocator, out: *std.ArrayList(u8)) !void {
    const writeString = @import("test_hooks.zig").writeString;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    try out.print(alloc, "{{\"hwnd\":{d},\"search\":{d},\"list\":{d},\"edit\":{d},\"dirty\":{},\"scroll\":{d},\"content_height\":{d},\"path\":", .{
        @intFromPtr(self.hwnd),
        if (self.search) |s| @intFromPtr(s) else 0,
        if (self.list) |l| @intFromPtr(l) else 0,
        if (self.edit) |e| @intFromPtr(e) else 0,
        self.session.dirty(),
        self.scroll,
        self.content_height,
    });
    try writeString(alloc, out, self.path);
    try out.appendSlice(alloc, ",\"query\":");
    try writeString(alloc, out, self.query.items);
    try out.appendSlice(alloc, ",\"group\":");
    try writeString(alloc, out, if (self.group) |g| g.title() else "");
    try out.appendSlice(alloc, ",\"selected\":");
    try writeString(alloc, out, if (self.selected) |s| option_list.all[s].name else "");
    try out.appendSlice(alloc, ",\"expanded\":");
    try writeString(alloc, out, if (self.expanded) |e| option_list.all[e].name else "");
    try out.appendSlice(alloc, ",\"editing\":");
    try writeString(alloc, out, if (self.edit_option) |e| option_list.all[e].name else "");
    try out.print(alloc, ",\"status_error\":{},\"status\":", .{self.status_error});
    try writeString(alloc, out, self.status[0..self.status_len]);
    try out.appendSlice(alloc, ",\"files\":[");
    for (self.session.files.items, 0..) |f, i| {
        if (i > 0) try out.append(alloc, ',');
        try writeString(alloc, out, f.path);
    }
    try out.appendSlice(alloc, "],\"rows\":[");
    var first = true;
    for (self.items.items) |it| {
        if (it.kind != .option) continue;
        if (!first) try out.append(alloc, ',');
        first = false;
        const o = &option_list.all[it.option];
        const r = self.rectsOf(it);
        try out.appendSlice(alloc, "{\"name\":");
        try writeString(alloc, out, o.name);
        try out.appendSlice(alloc, ",\"group\":");
        try writeString(alloc, out, it.group.title());
        try out.appendSlice(alloc, ",\"value\":");
        try writeString(alloc, out, self.display(a, it.option));
        var sub_buf: [200]u8 = undefined;
        try out.appendSlice(alloc, ",\"subtitle\":");
        try writeString(alloc, out, self.subtitle(a, it.option, &sub_buf).text);
        const source: i64 = if (self.session.source(o.name)) |s| @intCast(s) else -1;
        try out.print(alloc, ",\"kind\":\"{t}\",\"set\":{},\"source\":{d},\"row\":[{d},{d},{d},{d}],\"control\":[{d},{d},{d},{d}],\"reset\":[{d},{d},{d},{d}]}}", .{
            o.kind,
            self.session.isSet(o.name),
            source,
            r.row.left,
            r.row.top,
            r.row.right,
            r.row.bottom,
            r.control.left,
            r.control.top,
            r.control.right,
            r.control.bottom,
            r.reset.left,
            r.reset.top,
            r.reset.right,
            r.reset.bottom,
        });
    }
    try out.appendSlice(alloc, "]}");
}

test "flagsOf: as the loader reads a packed struct's value" {
    const names: []const []const u8 = &.{ "cursor", "sudo", "title" };
    const defaults: []const bool = &.{ true, false, true };
    var on: [3]bool = undefined;
    flagsOf("cursor,no-sudo,title", names, defaults, &on);
    try std.testing.expectEqualSlices(bool, &.{ true, false, true }, &on);
    flagsOf("true", names, defaults, &on);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true }, &on);
    flagsOf("0", names, defaults, &on);
    try std.testing.expectEqualSlices(bool, &.{ false, false, false }, &on);
    // What the value doesn't name keeps its type's default.
    flagsOf("no-cursor", names, defaults, &on);
    try std.testing.expectEqualSlices(bool, &.{ false, false, true }, &on);
    flagsOf(" sudo , no-title", names, defaults, &on);
    try std.testing.expectEqualSlices(bool, &.{ true, true, false }, &on);

    // Written back: only what differs, all of them when nothing does.
    const a = std.testing.allocator;
    const v1 = try flagsValue(a, names, defaults, &.{ false, true, true });
    defer a.free(v1);
    try std.testing.expectEqualStrings("no-cursor,sudo", v1);
    const v2 = try flagsValue(a, names, defaults, defaults);
    defer a.free(v2);
    try std.testing.expectEqualStrings("cursor,no-sudo,title", v2);
}

test "writeFile: through links, the file they name is written and they stay" {
    const alloc = std.testing.allocator;
    var tmp_buf: [261]u16 = undefined;
    const tn = c.GetTempPathW(tmp_buf.len, &tmp_buf);
    if (tn == 0 or tn >= tmp_buf.len) return error.SkipZigTest;
    const tmp_dir = try std.unicode.utf16LeToUtf8Alloc(alloc, tmp_buf[0..tn]);
    defer alloc.free(tmp_dir);
    const dir = try std.fmt.allocPrint(alloc, "{s}murrtty-editor-test-{d}", .{ tmp_dir, c.GetCurrentProcessId() });
    defer alloc.free(dir);
    const dir_w = try text_util.utf16Lossy(alloc, dir);
    defer alloc.free(dir_w);
    _ = c.CreateDirectoryW(dir_w.ptr, null);
    defer _ = c.RemoveDirectoryW(dir_w.ptr);

    var names: [4][]u8 = undefined;
    var wide: [4][:0]u16 = undefined;
    for ([_][]const u8{ "target", "hard", "soft", "named" }, 0..) |name, i| {
        names[i] = try std.fmt.allocPrint(alloc, "{s}\\{s}", .{ dir, name });
        wide[i] = try text_util.utf16Lossy(alloc, names[i]);
    }
    defer for (names, wide) |n, w| {
        _ = c.DeleteFileW(w.ptr);
        alloc.free(n);
        alloc.free(w);
    };
    const target, const hard, const soft, const named = names;

    const expectText = struct {
        fn f(path: []const u8, want: []const u8) !void {
            switch (readFile(std.testing.allocator, path)) {
                .text => |t| {
                    defer std.testing.allocator.free(t);
                    try std.testing.expectEqualStrings(want, t);
                },
                else => return error.TestUnexpectedResult,
            }
        }
    }.f;

    // A new file, then one replaced.
    try writeFile(alloc, target, "one\n");
    try expectText(target, "one\n");

    // A hard link: written in place, so both names keep the one file.
    if (c.CreateHardLinkW(wide[1].ptr, wide[0].ptr, null) != 0) {
        try writeFile(alloc, hard, "two\n");
        try expectText(target, "two\n");
        try writeFile(alloc, target, "three\n");
        try expectText(hard, "three\n");
        const leftover = try std.fmt.allocPrint(alloc, "{s}.murrtty-save", .{target});
        defer alloc.free(leftover);
        const leftover_w = try text_util.utf16Lossy(alloc, leftover);
        defer alloc.free(leftover_w);
        try std.testing.expectEqual(@as(c.DWORD, 0xFFFFFFFF), c.GetFileAttributesW(leftover_w.ptr));
    }

    // A symbolic link (Windows allows one with Developer Mode or the right
    // to make them) to a file of one link: the file it names is replaced,
    // and it stays a link.
    try writeFile(alloc, named, "four\n");
    if (c.CreateSymbolicLinkW(wide[2].ptr, wide[3].ptr, c.SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE) != 0) {
        try writeFile(alloc, soft, "five\n");
        try std.testing.expect(c.GetFileAttributesW(wide[2].ptr) & c.FILE_ATTRIBUTE_REPARSE_POINT != 0);
        try expectText(named, "five\n");
        try expectText(soft, "five\n");
    }
}
