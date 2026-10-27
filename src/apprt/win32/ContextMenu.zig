//! The terminal's right-click menu (roadmap 3.1), GTK's: Copy, Paste, Notify
//! on Next Command Finish, Clear and Reset, then Split, Tab, Window and
//! Config submenus. Each item shows its key binding, and is grayed when its
//! action can't run here (App.supportsAction) or now (Copy with no
//! selection, Paste with no text on the clipboard). Also the tab strip's
//! right-click menu (roadmap 3.8, trackTab).
const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("../../input.zig");
const c = @import("c.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");

const log = std.log.scoped(.win32_context_menu);

const Action = input.Binding.Action;

const Item = union(enum) {
    action: struct { label: []const u8, action: Action },
    /// Not available yet: always grayed.
    unavailable: []const u8,
    separator,
    submenu: struct { label: []const u8, items: []const Item },
    /// murrtty's About box, which no core action shows.
    about: []const u8,
};

/// What was chosen from a menu.
pub const Choice = union(enum) {
    action: Action,
    about,
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

/// The Config submenu, likewise. Opening the editor in a new terminal
/// window is GTK's only, for now.
const config_submenu = [_]Item{
    act("&Open Configuration in OS Editor", .{ .open_config = .os_open }),
    .{ .unavailable = "Open Configuration in New &Window" },
    act("&Reload Configuration", .reload_config),
};

/// GTK's menu (*observed* in its app); the `&` marks each item's access key.
const items = [_]Item{
    act("&Copy", .{ .copy_to_clipboard = .mixed }),
    act("&Paste", .paste_from_clipboard),
    // Roadmap 5.3.
    .{ .unavailable = "&Notify on Next Command Finish" },
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
        act("&Close Window", .close_window),
    } } },
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
    // Roadmap 4.5: moving terminals between windows.
    .{ .unavailable = "&Move Tab to New Window" },
};

/// Where the tab a tab menu is for sits in its window's strip.
pub const TabPlace = struct { index: usize, count: usize };

/// The choices of the menu being shown, by item id (index + 1).
const Built = struct {
    choices: std.ArrayList(Choice) = .empty,
    /// The menu's strings, alive while it shows.
    strings: std.ArrayList([:0]u16) = .empty,

    fn deinit(self: *Built, alloc: Allocator) void {
        self.choices.deinit(alloc);
        for (self.strings.items) |s| alloc.free(s);
        self.strings.deinit(alloc);
    }
};

/// Show the menu at `screen` (screen pixels) over `surface` and return the
/// action chosen, if any. The caller performs it, after the menu is gone.
pub fn track(surface: *Surface, screen: c.POINT) ?Action {
    return actionOf(show(surface, &items, null, surface.hwnd, screen, .left));
}

/// Show the tab strip's menu for the tab at `place`, whose focused pane is
/// `surface`, and return the action chosen for that pane, if any. The
/// window owns the menu: a background tab's pane is hidden.
pub fn trackTab(surface: *Surface, place: TabPlace, screen: c.POINT) ?Action {
    return actionOf(show(surface, &tab_items, place, surface.window.hwnd, screen, .left));
}

/// The menu on the arrow beside "+", its top left at `screen`.
pub fn trackSplit(surface: *Surface, screen: c.POINT) ?Action {
    return actionOf(show(surface, &split_items, null, surface.window.hwnd, screen, .left));
}

/// The main menu, its top right at `screen` (under the button at the
/// strip's right end).
pub fn trackMain(surface: *Surface, screen: c.POINT) ?Choice {
    return show(surface, &main_items, null, surface.window.hwnd, screen, .right);
}

fn actionOf(choice: ?Choice) ?Action {
    return switch (choice orelse return null) {
        .action => |a| a,
        .about => null,
    };
}

fn show(
    surface: *Surface,
    list: []const Item,
    place: ?TabPlace,
    owner: c.HWND,
    screen: c.POINT,
    edge: enum { left, right },
) ?Choice {
    const app = surface.app;
    const alloc = app.core_app.alloc;
    var built: Built = .{};
    defer built.deinit(alloc);
    const menu = build(surface, &built, list, place) catch |err| {
        log.warn("context menu not built err={}", .{err});
        return null;
    };
    defer _ = c.DestroyMenu(menu);

    // A nested modal loop: close requests wait until it ends. Other
    // windows stay enabled; a click on one just closes the menu.
    var modal = app.beginModal(surface.window.hwnd, .{ .disable_others = false });
    defer modal.end();
    if (comptime @import("test_hooks.zig").enabled) app.test_state.menus_shown += 1;
    const flags: c.UINT = c.TPM_RETURNCMD | c.TPM_RIGHTBUTTON | c.TPM_NONOTIFY |
        @as(c.UINT, if (edge == .right) c.TPM_RIGHTALIGN else 0);
    const id = c.TrackPopupMenuEx(menu, flags, screen.x, screen.y, owner, null);
    // So the menu closes properly the next time (KB135788).
    _ = c.PostMessageW(owner, c.WM_NULL, 0, 0);
    if (id <= 0 or id > built.choices.items.len) return null;
    return built.choices.items[@intCast(id - 1)];
}

const BuildError = error{ CreateMenuFailed, OutOfMemory, InvalidUtf8 };

fn build(surface: *Surface, built: *Built, list: []const Item, place: ?TabPlace) BuildError!c.HMENU {
    const alloc = surface.app.core_app.alloc;
    const menu = c.CreatePopupMenu() orelse return error.CreateMenuFailed;
    errdefer _ = c.DestroyMenu(menu);
    for (list) |item| switch (item) {
        .separator => _ = c.AppendMenuW(menu, c.MF_SEPARATOR, 0, null),
        .unavailable => |label| {
            const text = try addString(alloc, built, label);
            _ = c.AppendMenuW(menu, c.MF_STRING | c.MF_GRAYED, 0, text.ptr);
        },
        .action => |a| {
            var buf: [96]u8 = undefined;
            const label = labelWithBinding(surface.app, a.label, a.action, &buf);
            const text = try addString(alloc, built, label);
            try built.choices.append(alloc, .{ .action = a.action });
            const flags: c.UINT = if (enabled(surface, a.action, place)) c.MF_STRING else c.MF_STRING | c.MF_GRAYED;
            _ = c.AppendMenuW(menu, flags, built.choices.items.len, text.ptr);
        },
        .about => |label| {
            const text = try addString(alloc, built, label);
            try built.choices.append(alloc, .about);
            _ = c.AppendMenuW(menu, c.MF_STRING, built.choices.items.len, text.ptr);
        },
        .submenu => |s| {
            const sub = try build(surface, built, s.items, place);
            errdefer _ = c.DestroyMenu(sub);
            const text = try addString(alloc, built, s.label);
            // The parent menu owns the submenu from here.
            _ = c.AppendMenuW(menu, c.MF_POPUP, @intFromPtr(sub), text.ptr);
        },
    };
    return menu;
}

/// A UTF-16 copy of `s` that lives as long as the menu (Built.strings).
fn addString(alloc: Allocator, built: *Built, s: []const u8) BuildError![:0]u16 {
    const text = try std.unicode.utf8ToUtf16LeAllocZ(alloc, s);
    errdefer alloc.free(text);
    try built.strings.append(alloc, text);
    return text;
}

fn enabled(surface: *Surface, action: Action, place: ?TabPlace) bool {
    if (!App.supportsAction(action)) return false;
    return switch (action) {
        .copy_to_clipboard => surface.core_initialized and surface.core_surface.hasSelection(),
        .paste_from_clipboard => c.IsClipboardFormatAvailable(c.CF_UNICODETEXT) != 0,
        // In the tab menu, only when there are tabs to close.
        .close_tab => |mode| if (place) |p| switch (mode) {
            .this => true,
            .other => p.count > 1,
            .right => p.index + 1 < p.count,
        } else true,
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
