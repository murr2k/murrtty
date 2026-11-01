//! The terminal's right-click menu (roadmap 3.1), GTK's: Copy, Paste, Notify
//! on Next Command Finish, Clear and Reset, then Split, Tab, Window and
//! Config submenus. Each item shows its key binding, and is grayed when its
//! action can't run here (App.supportsAction) or now (Copy with no
//! selection, Paste with no text on the clipboard). Also the tab strip's
//! right-click menu (roadmap 3.8, trackTab), and the tray icon's (roadmap
//! 5.6, trackTray).
//!
//! They look like libadwaita's popover menus (roadmap 4.3b, measured on
//! GTK's): owner-drawn rows 32 DIP tall in the popover's colors and
//! GNOME's font, the binding at the right in a dimmer color, a rounded
//! highlight under the mouse, thin separators with room around them, and
//! a chevron for a submenu. Windows keeps the menu itself (its frame,
//! placement, keyboard and accessibility), as the strings stay stored in
//! the items. The system menu's items stay Windows' own.
const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("../../input.zig");
const c = @import("c.zig");
const draw = @import("draw.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");

const log = std.log.scoped(.win32_context_menu);

const Action = input.Binding.Action;

const Item = union(enum) {
    action: struct { label: []const u8, action: Action },
    /// Not available yet: always grayed.
    unavailable: []const u8,
    /// The pane's Notify on Next Command Finish (roadmap 5.3), a check
    /// item. GTK's menus leave room for the check before every item of a
    /// menu that has one.
    notify_next: []const u8,
    separator,
    submenu: struct { label: []const u8, items: []const Item },
    /// murrtty's About box, which no core action shows.
    about: []const u8,
    /// The configuration editor (roadmap F1), murrtty's own: no core
    /// action opens it, so a configuration naming one stays Ghostty's.
    config_editor: []const u8,
    /// Fit Window to Screen (roadmap 5.10b), murrtty's own (no core
    /// action): grayed for the quick terminal.
    fit_screen: []const u8,
    /// Close All but This (the owner's ask, 2026-11-01), murrtty's own (no
    /// core action closes the other panes, tabs and windows at once):
    /// grayed when the pane is all there is.
    close_all_but: []const u8,
};

/// What was chosen from a menu.
pub const Choice = union(enum) {
    action: Action,
    about,
    /// Toggle the pane's Notify on Next Command Finish.
    notify_next,
    config_editor,
    fit_screen,
    close_all_but,
};

/// Whom a menu is for: a pane's menus act on their pane, the tray's on the
/// app.
const Ctx = struct {
    app: *App,
    surface: ?*Surface,

    fn of(surface: *Surface) Ctx {
        return .{ .app = surface.app, .surface = surface };
    }
};

fn act(label: []const u8, action: Action) Item {
    return .{ .action = .{ .label = label, .action = action } };
}

/// The Split submenu, in the terminal's menu and the main menu.
const split_submenu = [_]Item{
    act("Change &Title...", .prompt_surface_title),
    act("Split &Up", .{ .new_split = .up }),
    act("Split &Down", .{ .new_split = .down }),
    act("Split &Left", .{ .new_split = .left }),
    act("Split &Right", .{ .new_split = .right }),
    act("&Close Split", .close_surface),
};

/// The Config submenu, likewise.
const config_submenu = [_]Item{
    .{ .config_editor = "Open Configuration &Editor" },
    act("&Open Configuration in OS Editor", .{ .open_config = .os_open }),
    act("Open Configuration in New &Window", .{ .open_config = .new_window }),
    act("&Reload Configuration", .reload_config),
};

/// GTK's menu (*observed* in its app); the `&` marks each item's access key.
const items = [_]Item{
    act("&Copy", .{ .copy_to_clipboard = .mixed }),
    act("&Paste", .paste_from_clipboard),
    .{ .notify_next = "&Notify on Next Command Finish" },
    .separator,
    act("C&lear", .clear_screen),
    act("&Reset", .reset),
    .separator,
    .{ .submenu = .{ .label = "&Split", .items = &split_submenu } },
    .{ .submenu = .{ .label = "&Tab", .items = &.{
        act("Change Tab &Title...", .prompt_tab_title),
        act("&New Tab", .new_tab),
        act("&Close Tab", .{ .close_tab = .this }),
    } } },
    .{ .submenu = .{ .label = "&Window", .items = &.{
        act("Change Window &Title...", .prompt_window_title),
        act("&New Window", .new_window),
        .{ .fit_screen = "&Fit Window to Screen" },
        act("&Close Window", .close_window),
    } } },
    .{ .close_all_but = "Close &All but This" },
    .separator,
    .{ .submenu = .{ .label = "C&onfig", .items = &config_submenu } },
};

/// GTK's main menu, its header bar's menu button (*observed*): for the
/// active tab's focused pane.
const main_items = [_]Item{
    act("&Copy", .{ .copy_to_clipboard = .mixed }),
    act("&Paste", .paste_from_clipboard),
    .separator,
    act("Change Window &Title...", .prompt_window_title),
    act("New &Window", .new_window),
    act("Close Win&dow", .close_window),
    .separator,
    act("Change Ta&b Title...", .prompt_tab_title),
    act("&New Tab", .new_tab),
    act("Close T&ab", .{ .close_tab = .this }),
    .{ .submenu = .{ .label = "&Split", .items = &split_submenu } },
    .{ .close_all_but = "Close All but T&his" },
    .separator,
    act("C&lear", .clear_screen),
    act("&Reset", .reset),
    .separator,
    act("Command Pal&ette", .toggle_command_palette),
    act("Terminal &Inspector", .{ .inspector = .toggle }),
    .{ .submenu = .{ .label = "C&onfig", .items = &config_submenu } },
    .separator,
    .{ .about = "Abo&ut murrtty" },
    act("&Quit", .quit),
};

/// The menu on the arrow beside "+" (GTK's split button's).
const split_items = [_]Item{
    act("Split &Up", .{ .new_split = .up }),
    act("Split &Down", .{ .new_split = .down }),
    act("Split &Left", .{ .new_split = .left }),
    act("Split &Right", .{ .new_split = .right }),
};

/// The tab strip's menu: the fuller one Windows users expect (decided
/// 2026-10-25), where GTK's offers only Change Tab Title. It acts on the
/// tab clicked, which needn't be the active one.
const tab_items = [_]Item{
    act("Change Tab &Title...", .prompt_tab_title),
    .separator,
    act("&Close Tab", .{ .close_tab = .this }),
    act("Close &Other Tabs", .{ .close_tab = .other }),
    act("Close Tabs to the &Right", .{ .close_tab = .right }),
    .separator,
    act("&Move Tab to New Window", .move_tab_to_new_window),
};

/// murrtty's items in the window's system menu (Alt+Space), after Close:
/// the main menu's reach where the strip isn't (fullscreen, gtk-titlebar =
/// false; roadmap 3.9). Their access keys avoid the system's own in English
/// (system_keys), so Alt+Space then C still closes the window; in other
/// languages SystemMenu.refresh drops any of them Windows' items use.
const system_items = [_]Item{
    act("New &Window", .new_window),
    act("New &Tab", .new_tab),
    .{ .submenu = .{ .label = "Sp&lit", .items = &split_submenu } },
    .{ .fit_screen = "&Fit Window to Screen" },
    .separator,
    act("Command &Palette", .toggle_command_palette),
    act("Terminal &Inspector", .{ .inspector = .toggle }),
    .{ .submenu = .{ .label = "C&onfig", .items = &config_submenu } },
    .separator,
    .{ .about = "Abo&ut murrtty" },
    act("&Quit", .quit),
};

/// The tray icon's menu (roadmap 5.6): what needs no window, and the quick
/// terminal (5.7).
const tray_items = [_]Item{
    act("New &Window", .new_window),
    act("Quick &Terminal", .toggle_quick_terminal),
    .separator,
    .{ .submenu = .{ .label = "C&onfig", .items = &config_submenu } },
    .separator,
    act("&Quit", .quit),
};

/// The access keys of the system menu's own items in English: Restore,
/// Move, Size, Minimize, Maximize, Close.
const system_keys = "rmsnxc";

/// Access keys in use, by lowercase ASCII character.
const Taken = [128]bool;

/// Where the tab a tab menu is for sits in its window's strip.
pub const TabPlace = struct { index: usize, count: usize };

/// The choices of the menu being shown, by item id: index + 1, shifted
/// left by `shift`.
const Built = struct {
    choices: std.ArrayList(Choice) = .empty,
    /// The menu's strings, alive while it shows.
    strings: std.ArrayList([:0]u16) = .empty,
    /// 4 for the system menu: WM_SYSCOMMAND keeps an id's low four bits
    /// for the system's use.
    shift: u4 = 0,
    /// How the owner-drawn items look, by their data (index + 1); none
    /// for the system menu, whose items Windows draws.
    look: ?Look = null,
    draws: std.ArrayList(Draw) = .empty,

    fn nextId(self: *const Built) usize {
        return self.choices.items.len << self.shift;
    }

    fn deinit(self: *Built, alloc: Allocator) void {
        self.choices.deinit(alloc);
        for (self.strings.items) |s| alloc.free(s);
        self.strings.deinit(alloc);
        self.draws.deinit(alloc);
        if (self.look) |l| l.deinit();
    }
};

/// An owner-drawn item.
const Draw = struct {
    menu: c.HMENU,
    /// The label, with its access key's "&", and the binding, if any.
    label: []const u16,
    binding: []const u16,
    kind: enum { item, separator, submenu },
    /// Room before the label for a check (the menu has a check item).
    indent: bool = false,
};

/// The menus' colors, font and size, for the owner window's DPI.
const Look = struct {
    dpi: c.UINT,
    pal: draw.MenuPalette,
    font: ?c.HFONT,
    brush: ?c.HBRUSH,

    fn init(app: *const App, dpi: c.UINT) Look {
        const pal = draw.menuPalette(app.chromeTheme());
        return .{
            .dpi = dpi,
            .pal = pal,
            .font = draw.chromeFont(dpi, null, false),
            .brush = c.CreateSolidBrush(pal.bg),
        };
    }

    fn deinit(self: Look) void {
        if (self.font) |f| _ = c.DeleteObject(f);
        if (self.brush) |b| _ = c.DeleteObject(b);
    }

    fn scale(self: Look, v: c_int) c_int {
        return draw.scale(self.dpi, v);
    }
};

/// Metrics, in DIP, as GTK's popover menu: rows 32 tall, separators a
/// line with 6 on either side, text 12 in from the row's ends (6 of
/// popover padding and 12 of row padding, less the menu's own margin),
/// 23 more before it in a menu with a check item, the binding 24 clear of
/// the label, a submenu's chevron in the last 16.
const row_height = 32;
const separator_height = 13;
const text_pad = 12;
const check_room = 23;
const binding_gap = 24;
const chevron_room = 16;

/// The menu showing, for its owner window's WM_MEASUREITEM, WM_DRAWITEM
/// and WM_MENUCHAR (one at a time: a menu's loop is modal).
var showing: ?*Built = null;

fn drawOf(data: usize) ?*const Draw {
    const built = showing orelse return null;
    if (data == 0 or data > built.draws.items.len) return null;
    return &built.draws.items[data - 1];
}

/// WM_MEASUREITEM for a menu item: its size. Returns whether it was one
/// of the menu's.
pub fn measureItem(lparam: c.LPARAM) bool {
    const m: *c.MEASUREITEMSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
    if (m.CtlType != c.ODT_MENU) return false;
    const built = showing orelse return false;
    const look = built.look orelse return false;
    const d = drawOf(m.itemData) orelse return false;
    if (d.kind == .separator) {
        m.itemWidth = 0;
        m.itemHeight = @intCast(look.scale(separator_height));
        return true;
    }
    const dc = c.GetDC(null) orelse return false;
    defer _ = c.ReleaseDC(null, dc);
    const old = if (look.font) |f| c.SelectObject(dc, f) else null;
    defer if (old) |o| {
        _ = c.SelectObject(dc, o);
    };
    var width = look.scale(2 * text_pad) + textWidth(dc, d.label, true);
    if (d.indent) width += look.scale(check_room);
    if (d.binding.len > 0) width += look.scale(binding_gap) + textWidth(dc, d.binding, false);
    if (d.kind == .submenu) width += look.scale(chevron_room);
    // Windows adds a check mark's width of its own to every item.
    width -= c.GetSystemMetricsForDpi(c.SM_CXMENUCHECK, look.dpi) - 1;
    m.itemWidth = @intCast(@max(width, look.scale(40)));
    m.itemHeight = @intCast(look.scale(row_height));
    return true;
}

fn textWidth(dc: c.HDC, text: []const u16, prefix: bool) c_int {
    var r: c.RECT = .{};
    const flags: c.UINT = c.DT_SINGLELINE | c.DT_CALCRECT | @as(c.UINT, if (prefix) 0 else c.DT_NOPREFIX);
    _ = c.DrawTextW(dc, text.ptr, @intCast(text.len), &r, flags);
    return r.right - r.left;
}

/// WM_DRAWITEM for a menu item. Returns whether it was one of the menu's.
pub fn drawItem(lparam: c.LPARAM) bool {
    const item: *const c.DRAWITEMSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
    if (item.CtlType != c.ODT_MENU) return false;
    const built = showing orelse return false;
    const look = built.look orelse return false;
    const d = drawOf(item.itemData) orelse return false;
    const dc = item.hDC;
    const r = item.rcItem;
    const pal = look.pal;
    draw.fill(dc, r, pal.bg);
    if (d.kind == .separator) {
        const y = r.top + @divTrunc(r.bottom - r.top, 2);
        draw.fill(dc, .{ .left = r.left + look.scale(3), .top = y, .right = r.right - look.scale(3), .bottom = y + @max(1, look.scale(1)) }, pal.separator);
        return true;
    }
    const grayed = item.itemState & c.ODS_GRAYED != 0;
    // The keyboard stops on grayed items too: a fainter highlight there.
    if (item.itemState & c.ODS_SELECTED != 0) {
        draw.roundRect(dc, r, look.scale(6), if (grayed) pal.hover_disabled else pal.hover, null, 0);
    }
    const old = if (look.font) |f| c.SelectObject(dc, f) else null;
    defer if (old) |o| {
        _ = c.SelectObject(dc, o);
    };
    _ = c.SetBkMode(dc, c.TRANSPARENT);
    var text = r;
    text.left += look.scale(text_pad) + if (d.indent) look.scale(check_room) else 0;
    text.right -= look.scale(text_pad) + if (d.kind == .submenu) look.scale(chevron_room) else 0;
    // Access keys underlined only when the keyboard opened the menu, as
    // Windows shows them; GTK's menus show none.
    const prefix: c.UINT = if (item.itemState & c.ODS_NOACCEL != 0) c.DT_HIDEPREFIX else 0;
    _ = c.SetTextColor(dc, if (grayed) pal.disabled else pal.text);
    _ = c.DrawTextW(dc, d.label.ptr, @intCast(d.label.len), &text, c.DT_SINGLELINE | c.DT_VCENTER | prefix);
    if (d.binding.len > 0) {
        _ = c.SetTextColor(dc, if (grayed) pal.disabled else pal.dim);
        _ = c.DrawTextW(dc, d.binding.ptr, @intCast(d.binding.len), &text, c.DT_SINGLELINE | c.DT_VCENTER | c.DT_RIGHT | c.DT_NOPREFIX);
    }
    // object-select: a check in the room before the label.
    if (item.itemState & c.ODS_CHECKED != 0) {
        const x = r.left + look.scale(text_pad);
        const y = r.top + @divTrunc(r.bottom - r.top, 2);
        const stroke = @max(1, look.scale(2));
        const color = if (grayed) pal.disabled else pal.text;
        draw.line(dc, x + look.scale(2), y, x + look.scale(6), y + look.scale(4), color, stroke);
        draw.line(dc, x + look.scale(6), y + look.scale(4), x + look.scale(14), y - look.scale(4), color, stroke);
    }
    if (d.kind == .submenu) {
        // pan-end: a chevron pointing right, in the last 16 DIP.
        const x = r.right - look.scale(text_pad) - @divTrunc(look.scale(chevron_room), 2);
        const y = r.top + @divTrunc(r.bottom - r.top, 2);
        const arm = look.scale(4);
        const stroke = @max(1, look.scale(2));
        const color = if (grayed) pal.disabled else pal.text;
        draw.line(dc, x - @divTrunc(arm, 2), y - arm, x + @divTrunc(arm, 2), y + 1, color, stroke);
        draw.line(dc, x - @divTrunc(arm, 2), y + arm, x + @divTrunc(arm, 2), y - 1, color, stroke);
        // Windows draws its own arrow after this: keep it off the item.
        _ = c.ExcludeClipRect(dc, r.left, r.top, r.right, r.bottom);
    }
    return true;
}

/// WM_MENUCHAR: the item of the showing menu `lparam` whose access key
/// was typed, run (or its submenu opened), as Windows does for its own
/// items' access keys. Null when it isn't one of the menu's.
pub fn menuChar(wparam: c.WPARAM, lparam: c.LPARAM) ?c.LRESULT {
    const built = showing orelse return null;
    if (built.look == null) return null;
    const menu: c.HMENU = @ptrFromInt(@as(usize, @bitCast(lparam)));
    // Access keys are ASCII; a letter beyond (Czech š, U+0161) must not
    // match by its low byte ('a').
    const char = c.loword(wparam);
    if (char >= 128) return null;
    const typed = std.ascii.toLower(@intCast(char));
    var pos: usize = 0;
    for (built.draws.items) |d| {
        if (d.menu != menu) continue;
        defer pos += 1;
        if (d.kind == .separator) continue;
        const key = accessKey(u16, d.label) orelse continue;
        if (key == typed) return @intCast((@as(usize, c.MNC_EXECUTE) << 16) | pos);
    }
    return null;
}

/// Show the menu at `screen` (screen pixels) over `surface` and return the
/// action chosen, if any. The caller performs it, after the menu is gone.
pub fn track(surface: *Surface, screen: c.POINT) ?Choice {
    return show(.of(surface), &items, null, surface.hwnd, screen, .left);
}

/// Show the tab strip's menu for the tab at `place`, whose focused pane is
/// `surface`, and return the action chosen for that pane, if any. The
/// window owns the menu: a background tab's pane is hidden.
pub fn trackTab(surface: *Surface, place: TabPlace, screen: c.POINT) ?Action {
    return actionOf(show(.of(surface), &tab_items, place, surface.window.hwnd, screen, .left));
}

/// The menu on the arrow beside "+", its top left at `screen`.
pub fn trackSplit(surface: *Surface, screen: c.POINT) ?Action {
    return actionOf(show(.of(surface), &split_items, null, surface.window.hwnd, screen, .left));
}

/// The main menu, its top right at `screen` (under the button at the
/// strip's right end).
pub fn trackMain(surface: *Surface, screen: c.POINT) ?Choice {
    return show(.of(surface), &main_items, null, surface.window.hwnd, screen, .right);
}

/// The tray icon's menu, owned by its window `owner`, at `screen`; what
/// was chosen, if anything.
pub fn trackTray(app: *App, owner: c.HWND, screen: c.POINT) ?Choice {
    return show(.{ .app = app, .surface = null }, &tray_items, null, owner, screen, .left);
}

fn actionOf(choice: ?Choice) ?Action {
    return switch (choice orelse return null) {
        .action => |a| a,
        .about, .notify_next, .config_editor, .fit_screen, .close_all_but => null,
    };
}

/// A menu of `labels` at `screen` (its top left), owned by `owner`: the
/// config editor's choices, flags and pages, as the other menus look. The
/// items `checked` says are checked; the index chosen, if any.
pub fn pick(app: *App, owner: c.HWND, screen: c.POINT, labels: []const []const u8, checked: []const bool) ?usize {
    const alloc = app.core_app.alloc;
    var built: Built = .{ .look = Look.init(app, c.GetDpiForWindow(owner)) };
    defer built.deinit(alloc);
    const menu = c.CreatePopupMenu() orelse return null;
    defer _ = c.DestroyMenu(menu);
    const info: c.MENUINFO = .{ .fMask = c.MIM_BACKGROUND, .hbrBack = built.look.?.brush };
    _ = c.SetMenuInfo(menu, &info);
    const any_checked = for (checked) |ck| {
        if (ck) break true;
    } else false;
    for (labels, 0..) |label, i| {
        // An "&" in a value is itself, not an access key.
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        for (label) |ch| {
            if (ch == '&') w.writeByte('&') catch break;
            w.writeByte(ch) catch break;
        }
        const text = addString(alloc, &built, w.buffered()) catch return null;
        append(alloc, &built, menu, .item, text, i + 1, false, null) catch return null;
        if (i < checked.len and checked[i]) _ = c.CheckMenuItem(menu, @intCast(i + 1), c.MF_BYCOMMAND | c.MF_CHECKED);
    }
    if (any_checked) for (built.draws.items) |*d| {
        d.indent = true;
    };
    showing = &built;
    defer showing = null;
    var modal = app.beginModal(owner, .{ .disable_others = false });
    defer modal.end();
    if (comptime @import("test_hooks.zig").enabled) app.test_state.menus_shown += 1;
    const id = c.TrackPopupMenuEx(menu, c.TPM_RETURNCMD | c.TPM_RIGHTBUTTON | c.TPM_NONOTIFY, screen.x, screen.y, owner, null);
    _ = c.PostMessageW(owner, c.WM_NULL, 0, 0);
    if (id <= 0 or id > labels.len) return null;
    return @intCast(id - 1);
}

fn show(
    ctx: Ctx,
    list: []const Item,
    place: ?TabPlace,
    owner: c.HWND,
    screen: c.POINT,
    edge: enum { left, right },
) ?Choice {
    const app = ctx.app;
    const alloc = app.core_app.alloc;
    // The tray's opens by the taskbar, which may be on a monitor of another
    // DPI than its hidden owner window's.
    const dpi = if (ctx.surface == null) dpiAt(screen, c.GetDpiForWindow(owner)) else c.GetDpiForWindow(owner);
    var built: Built = .{ .look = Look.init(app, dpi) };
    defer built.deinit(alloc);
    const menu = build(ctx, &built, list, place) catch |err| {
        log.warn("context menu not built err={}", .{err});
        return null;
    };
    defer _ = c.DestroyMenu(menu);
    showing = &built;
    defer showing = null;

    // A nested modal loop: close requests wait until it ends. Other
    // windows stay enabled; a click on one just closes the menu.
    var modal = app.beginModal(if (ctx.surface) |s| s.window.hwnd else null, .{ .disable_others = false });
    defer modal.end();
    if (comptime @import("test_hooks.zig").enabled) app.test_state.menus_shown += 1;
    // A notification-area icon's menu closes on a click elsewhere only if
    // its owner has the foreground (which the icon's click granted).
    if (ctx.surface == null) _ = c.SetForegroundWindow(owner);
    const flags: c.UINT = c.TPM_RETURNCMD | c.TPM_RIGHTBUTTON | c.TPM_NONOTIFY |
        @as(c.UINT, if (edge == .right) c.TPM_RIGHTALIGN else 0);
    const id = c.TrackPopupMenuEx(menu, flags, screen.x, screen.y, owner, null);
    // So the menu closes properly the next time (KB135788).
    _ = c.PostMessageW(owner, c.WM_NULL, 0, 0);
    if (id <= 0 or id > built.choices.items.len) return null;
    return built.choices.items[@intCast(id - 1)];
}

/// The DPI of the monitor at `screen`, else `fallback`.
fn dpiAt(screen: c.POINT, fallback: c.UINT) c.UINT {
    const monitor = c.MonitorFromPoint(screen, c.MONITOR_DEFAULTTONEAREST) orelse return fallback;
    return draw.monitorDpi(monitor, fallback);
}

const BuildError = error{ CreateMenuFailed, OutOfMemory, InvalidUtf8 };

fn build(ctx: Ctx, built: *Built, list: []const Item, place: ?TabPlace) BuildError!c.HMENU {
    const menu = c.CreatePopupMenu() orelse return error.CreateMenuFailed;
    errdefer _ = c.DestroyMenu(menu);
    if (built.look) |look| {
        const info: c.MENUINFO = .{ .fMask = c.MIM_BACKGROUND, .hbrBack = look.brush };
        _ = c.SetMenuInfo(menu, &info);
    }
    try fill(ctx, built, menu, list, place, null);
    return menu;
}

/// Append `list`'s items to `menu`, without access keys in `taken`.
fn fill(
    ctx: Ctx,
    built: *Built,
    menu: c.HMENU,
    list: []const Item,
    place: ?TabPlace,
    taken: ?*const Taken,
) BuildError!void {
    const alloc = ctx.app.core_app.alloc;
    const first = built.draws.items.len;
    var toggles = false;
    for (list) |item| switch (item) {
        .separator => try append(alloc, built, menu, .separator, null, 0, false, null),
        .unavailable => |label| {
            var free: [64]u8 = undefined;
            const text = try addString(alloc, built, freeAccessKey(label, taken, &free));
            try append(alloc, built, menu, .item, text, 0, true, null);
        },
        .notify_next => |label| {
            const surface = ctx.surface orelse continue;
            toggles = true;
            var free: [64]u8 = undefined;
            const text = try addString(alloc, built, freeAccessKey(label, taken, &free));
            try built.choices.append(alloc, .notify_next);
            const id = built.nextId();
            try append(alloc, built, menu, .item, text, id, !surface.core_initialized, null);
            if (surface.notify_next_command) _ = c.CheckMenuItem(menu, @intCast(id), c.MF_BYCOMMAND | c.MF_CHECKED);
        },
        .action => |a| {
            var free: [64]u8 = undefined;
            var buf: [96]u8 = undefined;
            const label = labelWithBinding(ctx.app, freeAccessKey(a.label, taken, &free), a.action, &buf);
            const text = try addString(alloc, built, label);
            try built.choices.append(alloc, .{ .action = a.action });
            try append(alloc, built, menu, .item, text, built.nextId(), !enabled(ctx, a.action, place), null);
        },
        .about => |label| {
            var free: [64]u8 = undefined;
            const text = try addString(alloc, built, freeAccessKey(label, taken, &free));
            try built.choices.append(alloc, .about);
            try append(alloc, built, menu, .item, text, built.nextId(), false, null);
        },
        .config_editor => |label| {
            var free: [64]u8 = undefined;
            const text = try addString(alloc, built, freeAccessKey(label, taken, &free));
            try built.choices.append(alloc, .config_editor);
            try append(alloc, built, menu, .item, text, built.nextId(), false, null);
        },
        .fit_screen => |label| {
            var free: [64]u8 = undefined;
            const text = try addString(alloc, built, freeAccessKey(label, taken, &free));
            const quick = if (ctx.surface) |s| s.window.quick != null else true;
            try built.choices.append(alloc, .fit_screen);
            try append(alloc, built, menu, .item, text, built.nextId(), quick, null);
        },
        .close_all_but => |label| {
            var free: [64]u8 = undefined;
            const text = try addString(alloc, built, freeAccessKey(label, taken, &free));
            const alone = if (ctx.surface) |s| s.app.othersOf(s).count == 0 else true;
            try built.choices.append(alloc, .close_all_but);
            try append(alloc, built, menu, .item, text, built.nextId(), alone, null);
        },
        .submenu => |s| {
            // A submenu's access keys are its own.
            const sub = try build(ctx, built, s.items, place);
            errdefer _ = c.DestroyMenu(sub);
            var free: [64]u8 = undefined;
            const text = try addString(alloc, built, freeAccessKey(s.label, taken, &free));
            // The parent menu owns the submenu from here.
            try append(alloc, built, menu, .submenu, text, 0, false, sub);
        },
    };
    // GTK's menu leaves room for the check before all of a menu's items.
    if (toggles) for (built.draws.items[first..]) |*d| {
        if (d.menu == menu) d.indent = true;
    };
}

/// Add an item to `menu`: owner-drawn when the menu has a look (its
/// string stored all the same, for reading back and access keys),
/// Windows' own otherwise (the system menu).
fn append(
    alloc: Allocator,
    built: *Built,
    menu: c.HMENU,
    kind: @FieldType(Draw, "kind"),
    text: ?[:0]const u16,
    id: usize,
    grayed: bool,
    sub: ?c.HMENU,
) BuildError!void {
    if (built.look == null) {
        _ = switch (kind) {
            .separator => c.AppendMenuW(menu, c.MF_SEPARATOR, 0, null),
            .item => c.AppendMenuW(menu, c.MF_STRING | @as(c.UINT, if (grayed) c.MF_GRAYED else 0), id, text.?.ptr),
            .submenu => c.AppendMenuW(menu, c.MF_POPUP, @intFromPtr(sub.?), text.?.ptr),
        };
        return;
    }
    const full = text orelse &[_:0]u16{};
    // The label, then the binding after its tab.
    const tab = std.mem.indexOfScalar(u16, full, '\t');
    try built.draws.append(alloc, .{
        .menu = menu,
        .label = if (tab) |t| full[0..t] else full,
        .binding = if (tab) |t| full[t + 1 ..] else &.{},
        .kind = kind,
    });
    var info: c.MENUITEMINFOW = .{
        .fMask = c.MIIM_FTYPE | c.MIIM_DATA | c.MIIM_ID | c.MIIM_STATE,
        .fType = c.MFT_OWNERDRAW | @as(c.UINT, if (kind == .separator) c.MFT_SEPARATOR else 0),
        .fState = if (grayed) c.MFS_GRAYED else 0,
        .wID = @intCast(id),
        .dwItemData = built.draws.items.len,
    };
    if (text) |t| {
        info.fMask |= c.MIIM_STRING;
        info.dwTypeData = t.ptr;
        info.cch = @intCast(t.len);
    }
    if (sub) |s| {
        info.fMask |= c.MIIM_SUBMENU;
        info.hSubMenu = s;
    }
    _ = c.InsertMenuItemW(menu, std.math.maxInt(c.UINT), c.TRUE, &info);
}

/// murrtty's items in a window's system menu, refilled each time it opens
/// so bindings and grayed items are current.
pub const SystemMenu = struct {
    /// How many items Windows put in the menu, recorded before murrtty's.
    base: ?c_int = null,
    /// What murrtty's items run, by WM_SYSCOMMAND id (index + 1) << 4.
    choices: std.ArrayList(Choice) = .empty,

    pub fn deinit(self: *SystemMenu, alloc: Allocator) void {
        self.choices.deinit(alloc);
    }

    /// Put murrtty's items, for `surface`, after Windows' in `menu`.
    pub fn refresh(self: *SystemMenu, surface: *Surface, menu: c.HMENU) void {
        const alloc = surface.app.core_app.alloc;
        const base = self.base orelse base: {
            const n = c.GetMenuItemCount(menu);
            if (n < 0) return;
            self.base = n;
            break :base n;
        };
        // DeleteMenu destroys a submenu with its item.
        while (c.GetMenuItemCount(menu) > base) {
            if (c.DeleteMenu(menu, @intCast(base), c.MF_BYPOSITION) == 0) break;
        }
        // Windows' items' access keys, in the system's language.
        var taken: Taken = @splat(false);
        for (0..@intCast(base)) |i| {
            var text: [128]u16 = undefined;
            const n = c.GetMenuStringW(menu, @intCast(i), &text, text.len, c.MF_BYPOSITION);
            if (n <= 0) continue;
            if (accessKey(u16, text[0..@intCast(n)])) |k| taken[k] = true;
        }
        var built: Built = .{ .shift = 4 };
        defer built.deinit(alloc);
        _ = c.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
        fill(.of(surface), &built, menu, &system_items, null, &taken) catch |err| {
            log.warn("system menu items not added err={}", .{err});
        };
        // Built.deinit frees the old list.
        std.mem.swap(std.ArrayList(Choice), &self.choices, &built.choices);
    }

    /// What WM_SYSCOMMAND's `wparam` asks for, if it is one of murrtty's.
    pub fn choice(self: *const SystemMenu, wparam: c.WPARAM) ?Choice {
        const id = wparam & 0xFFF0;
        // The system's own commands (SC_*) start at 0xF000.
        if (id == 0 or id >= 0xF000) return null;
        const i = (id >> 4) - 1;
        return if (i < self.choices.items.len) self.choices.items[i] else null;
    }
};

/// Where `label`'s access key's `&` is ("&&" is a literal ampersand).
fn accessKeyIndex(comptime T: type, label: []const T) ?usize {
    var i: usize = 0;
    while (i + 1 < label.len) : (i += 1) {
        if (label[i] != '&') continue;
        if (label[i + 1] == '&') {
            i += 1;
            continue;
        }
        return i;
    }
    return null;
}

/// `label`'s access key, lowercased, if it is ASCII (murrtty's all are).
fn accessKey(comptime T: type, label: []const T) ?u7 {
    const i = accessKeyIndex(T, label) orelse return null;
    const k = label[i + 1];
    if (k >= 128) return null;
    return @intCast(std.ascii.toLower(@intCast(k)));
}

/// `label` without its access key's `&` (in `buf`) if `taken` has that key:
/// two items with one access key would only move the highlight between
/// them, so Windows' keep theirs.
fn freeAccessKey(label: []const u8, taken: ?*const Taken, buf: []u8) []const u8 {
    const t = taken orelse return label;
    const k = accessKey(u8, label) orelse return label;
    if (!t[k] or label.len - 1 > buf.len) return label;
    const i = accessKeyIndex(u8, label).?;
    @memcpy(buf[0..i], label[0..i]);
    @memcpy(buf[i .. label.len - 1], label[i + 1 ..]);
    return buf[0 .. label.len - 1];
}

/// A UTF-16 copy of `s` that lives as long as the menu (Built.strings).
fn addString(alloc: Allocator, built: *Built, s: []const u8) BuildError![:0]u16 {
    const text = try std.unicode.utf8ToUtf16LeAllocZ(alloc, s);
    errdefer alloc.free(text);
    try built.strings.append(alloc, text);
    return text;
}

fn enabled(ctx: Ctx, action: Action, place: ?TabPlace) bool {
    if (!App.supportsAction(action)) return false;
    return switch (action) {
        .copy_to_clipboard => if (ctx.surface) |surface| surface.core_initialized and surface.core_surface.hasSelection() else false,
        .paste_from_clipboard => c.IsClipboardFormatAvailable(c.CF_UNICODETEXT) != 0,
        // In the tab menu, only when there are tabs to close.
        .close_tab => |mode| if (place) |p| switch (mode) {
            .this => true,
            .other => p.count > 1,
            .right => p.index + 1 < p.count,
        } else true,
        // As GTK's, nothing for a window's only tab.
        .move_tab_to_new_window => if (place) |p| p.count > 1 else true,
        else => true,
    };
}

/// `label`, then a tab and the action's key binding, if it has one
/// ("&Copy\tCtrl+Shift+C"): menus right-align what follows the tab.
fn labelWithBinding(app: *App, label: []const u8, action: Action, buf: []u8) []const u8 {
    const trigger = app.config.keybind.set.getTrigger(action) orelse return label;
    var w: std.Io.Writer = .fixed(buf);
    w.print("{s}\t", .{label}) catch return label;
    writeTrigger(&w, trigger) catch return label;
    return w.buffered();
}

/// A key binding as Windows menus show one: "Ctrl+Shift+T".
pub fn writeTrigger(w: *std.Io.Writer, trigger: input.Binding.Trigger) !void {
    if (trigger.mods.ctrl) try w.writeAll("Ctrl+");
    if (trigger.mods.shift) try w.writeAll("Shift+");
    if (trigger.mods.alt) try w.writeAll("Alt+");
    if (trigger.mods.super) try w.writeAll("Win+");
    switch (trigger.key) {
        .physical => |k| try writeKey(w, k),
        .unicode => |cp| {
            const upper: u21 = if (cp < 128) std.ascii.toUpper(@intCast(cp)) else cp;
            try w.print("{u}", .{upper});
        },
        .catch_all => try w.writeAll("Any Key"),
    }
}

fn writeKey(w: *std.Io.Writer, k: input.Key) !void {
    const name = @tagName(k);
    if (std.mem.startsWith(u8, name, "key_") and name.len == 5) {
        return w.writeByte(std.ascii.toUpper(name[4]));
    }
    if (std.mem.startsWith(u8, name, "digit_")) return w.writeAll(name["digit_".len..]);
    if (name.len >= 2 and name[0] == 'f' and std.ascii.isDigit(name[1])) {
        return w.print("F{s}", .{name[1..]});
    }
    const text: []const u8 = switch (k) {
        .backquote => "`",
        .backslash => "\\",
        .bracket_left => "[",
        .bracket_right => "]",
        .comma => ",",
        .equal => "=",
        .minus => "-",
        .period => ".",
        .quote => "'",
        .semicolon => ";",
        .slash => "/",
        .backspace => "Backspace",
        .enter => "Enter",
        .space => "Space",
        .tab => "Tab",
        .escape => "Esc",
        .delete => "Del",
        .insert => "Ins",
        .home => "Home",
        .end => "End",
        .page_up => "PgUp",
        .page_down => "PgDn",
        .arrow_up => "Up",
        .arrow_down => "Down",
        .arrow_left => "Left",
        .arrow_right => "Right",
        .numpad_add => "Num +",
        .numpad_subtract => "Num -",
        .numpad_multiply => "Num *",
        .numpad_divide => "Num /",
        .numpad_enter => "Num Enter",
        else => name,
    };
    try w.writeAll(text);
}

test "writeTrigger: Windows menu style" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    const cases = [_]struct { input.Binding.Trigger, []const u8 }{
        .{ .{ .key = .{ .physical = .key_c }, .mods = .{ .ctrl = true, .shift = true } }, "Ctrl+Shift+C" },
        .{ .{ .key = .{ .physical = .comma }, .mods = .{ .ctrl = true } }, "Ctrl+," },
        .{ .{ .key = .{ .physical = .page_up }, .mods = .{ .ctrl = true, .shift = true } }, "Ctrl+Shift+PgUp" },
        .{ .{ .key = .{ .physical = .digit_1 }, .mods = .{ .alt = true } }, "Alt+1" },
        .{ .{ .key = .{ .physical = .f4 }, .mods = .{ .alt = true } }, "Alt+F4" },
        .{ .{ .key = .{ .unicode = 'q' }, .mods = .{ .super = true } }, "Win+Q" },
    };
    for (cases) |case| {
        var w: std.Io.Writer = .fixed(&buf);
        try writeTrigger(&w, case[0]);
        try testing.expectEqualStrings(case[1], w.buffered());
    }
}

test "system menu items: access keys of their own, clear of the system's" {
    var taken: Taken = @splat(false);
    for (system_keys) |k| taken[k] = true;
    for (system_items) |item| {
        const label = switch (item) {
            .action => |a| a.label,
            .submenu => |s| s.label,
            .about, .unavailable, .notify_next, .config_editor, .fit_screen, .close_all_but => |l| l,
            .separator => continue,
        };
        const k = accessKey(u8, label) orelse return error.NoAccessKey;
        try std.testing.expect(!taken[k]);
        taken[k] = true;
    }
}

test "system menu items: a key Windows' items use in another language goes" {
    const testing = std.testing;
    // French: &Restaurer, &Déplacer, &Taille, Réd&uire, Agrand&ir, &Fermer.
    var taken: Taken = @splat(false);
    for ([_][]const u16{
        std.unicode.utf8ToUtf16LeStringLiteral("&Restaurer"),
        std.unicode.utf8ToUtf16LeStringLiteral("&Déplacer"),
        std.unicode.utf8ToUtf16LeStringLiteral("&Taille"),
        std.unicode.utf8ToUtf16LeStringLiteral("Réd&uire"),
        std.unicode.utf8ToUtf16LeStringLiteral("Agrand&ir"),
        std.unicode.utf8ToUtf16LeStringLiteral("&Fermer\tAlt+F4"),
    }) |text| taken[accessKey(u16, text).?] = true;
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("New Tab", freeAccessKey("New &Tab", &taken, &buf));
    try testing.expectEqualStrings("About murrtty", freeAccessKey("Abo&ut murrtty", &taken, &buf));
    try testing.expectEqualStrings("New &Window", freeAccessKey("New &Window", &taken, &buf));
    try testing.expectEqualStrings("Fish && &Chips", freeAccessKey("Fish && &Chips", &taken, &buf));
    try testing.expectEqual(@as(?u7, 'c'), accessKey(u8, "Fish && &Chips"));
}
