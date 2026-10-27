//! Desktop notifications (roadmap 5.2): OSC 9 and OSC 777 as balloons of a
//! notification-area icon, which Windows 10 and 11 show as toasts. GTK's
//! stay until their pane gets the keyboard (3 s, for one sent while it had
//! it), and a click presents the pane. A balloon carries no id of its own,
//! so here the icon stands for the latest notification: it comes with it
//! and goes when that one's pane gets the keyboard or closes, when its 3 s
//! pass, or when it is clicked, which takes the toast out of the
//! notification center too. Until the tray (5.6), the icon is there only
//! while a notification is.
const Notifications = @This();

const std = @import("std");

const c = @import("c.zig");
const App = @import("App.zig");
const test_hooks = @import("test_hooks.zig");
const text_util = @import("text.zig");

const log = std.log.scoped(.win32_notifications);

const class_name = c.L("MurrttyNotify");
/// The icon's messages (NOTIFYICON_VERSION_4: the event in lparam's low
/// word). The GUI tests' hooks send one to click.
pub const WM_ICON = c.WM_APP + 1;
const icon_id = 1;
const focused_timer = 1;
/// GTK takes back a notification sent to the pane with the keyboard after
/// this.
const focused_timeout_ms = 3000;

app: *App,
/// A hidden top-level window (a message-only one would miss Explorer's
/// TaskbarCreated) that the icon's messages go to; null if it couldn't be
/// made, and then nothing is shown.
hwnd: ?c.HWND = null,
small_icon: ?c.HICON = null,
big_icon: ?c.HICON = null,
taskbar_created: c.UINT = 0,
/// Whether the icon is in the notification area.
shown: bool = false,
/// The latest notification's pane, by core id; null for one of the app's.
surface: ?u64 = null,
/// Inside a call to Explorer, which runs the messages sent meanwhile: a
/// click then waits (`WM_ICON` is posted again).
busy: bool = false,
warned: bool = false,

pub fn registerClass(instance: c.HINSTANCE) !void {
    const wc: c.WNDCLASSEXW = .{
        .lpfnWndProc = &wndProc,
        .hInstance = instance,
        .lpszClassName = class_name,
    };
    if (c.RegisterClassExW(&wc) == 0) return error.RegisterClassFailed;
}

/// Set up; without its window murrtty runs on and shows no notifications.
pub fn init(self: *Notifications, app: *App) void {
    self.* = .{ .app = app };
    const hwnd = c.CreateWindowExW(0, class_name, c.L("murrtty"), c.WS_POPUP, 0, 0, 0, 0, null, null, app.instance, null) orelse {
        log.warn("no notifications: their window could not be made err={}", .{c.GetLastError()});
        return;
    };
    self.hwnd = hwnd;
    _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.taskbar_created = c.RegisterWindowMessageW(c.L("TaskbarCreated"));
    // Explorer runs below an elevated murrtty, whose windows would refuse
    // its messages.
    for ([_]c.UINT{ self.taskbar_created, WM_ICON }) |msg| {
        if (msg != 0) _ = c.ChangeWindowMessageFilterEx(hwnd, msg, c.MSGFLT_ALLOW, null);
    }
    self.loadIcons();
}

pub fn deinit(self: *Notifications) void {
    const hwnd = self.hwnd orelse return;
    _ = c.KillTimer(hwnd, focused_timer);
    // Whatever murrtty thought: an icon Explorer added without saying so
    // goes too.
    var data = self.iconData();
    _ = self.shell(c.NIM_DELETE, &data);
    self.shown = false;
    _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
    _ = c.DestroyWindow(hwnd);
    self.hwnd = null;
    self.freeIcons();
}

/// The app's icon at the window's DPI, for the notification area and the
/// balloon.
fn loadIcons(self: *Notifications) void {
    const hwnd = self.hwnd orelse return;
    self.freeIcons();
    const dpi = c.GetDpiForWindow(hwnd);
    for ([_]struct { *?c.HICON, c_int, c_int }{
        .{ &self.small_icon, c.SM_CXSMICON, c.SM_CYSMICON },
        .{ &self.big_icon, c.SM_CXICON, c.SM_CYICON },
    }) |entry| {
        const h = c.LoadImageW(self.app.instance, 1, c.IMAGE_ICON, c.GetSystemMetricsForDpi(entry[1], dpi), c.GetSystemMetricsForDpi(entry[2], dpi), 0);
        if (h) |icon| entry[0].* = @ptrCast(icon);
    }
}

fn freeIcons(self: *Notifications) void {
    for ([_]*?c.HICON{ &self.small_icon, &self.big_icon }) |icon| if (icon.*) |h| {
        _ = c.DestroyIcon(h);
        icon.* = null;
    };
}

fn iconData(self: *const Notifications) c.NOTIFYICONDATAW {
    return .{ .hWnd = self.hwnd, .uID = icon_id };
}

/// The icon itself, with no balloon.
fn iconOnly(self: *const Notifications) c.NOTIFYICONDATAW {
    var data = self.iconData();
    data.uFlags = c.NIF_MESSAGE | c.NIF_ICON | c.NIF_TIP | c.NIF_SHOWTIP;
    data.uCallbackMessage = WM_ICON;
    data.hIcon = self.small_icon;
    _ = text_util.utf16Into(&data.szTip, "murrtty");
    return data;
}

/// Shell_NotifyIconW, or as if it worked while the GUI tests' hooks record
/// notifications instead (the hidden desktop has no notification area,
/// and the user's would show them on the owner's screen).
fn shell(self: *Notifications, message: c.DWORD, data: *c.NOTIFYICONDATAW) bool {
    if (test_hooks.recordsNotifications(&self.app.test_state)) return true;
    self.busy = true;
    defer self.busy = false;
    return c.Shell_NotifyIconW(message, data) != 0;
}

/// Put the icon (with `data`'s balloon) in the notification area, whatever
/// Explorer has: one it lost (it restarted, a message filter kept its
/// TaskbarCreated away) is added again, and one it added though the call
/// said it failed (Explorer was slow) is changed.
fn place(self: *Notifications, data: *c.NOTIFYICONDATAW) bool {
    if (self.shown and self.shell(c.NIM_MODIFY, data)) return true;
    if (self.shell(c.NIM_ADD, data)) {
        var version = self.iconData();
        version.uVersion = c.NOTIFYICON_VERSION_4;
        _ = self.shell(c.NIM_SETVERSION, &version);
        return true;
    }
    return !self.shown and self.shell(c.NIM_MODIFY, data);
}

/// Show a notification from the pane `surface` (null: the app's own),
/// `focused` if that pane has the keyboard. With no title it is murrtty's,
/// as GTK's is Ghostty's; with no body the title says it under murrtty's
/// (a balloon with no text isn't shown).
pub fn send(self: *Notifications, surface: ?u64, focused: bool, title: []const u8, body: []const u8) void {
    const hwnd = self.hwnd orelse return;
    var data = self.iconOnly();
    data.uFlags |= c.NIF_INFO;
    var heading: []const u8 = if (title.len > 0) title else "murrtty";
    var text: []const u8 = body;
    if (body.len == 0) {
        heading = "murrtty";
        text = if (title.len > 0) title else " ";
    }
    // Windows' fields hold 63 and 255 UTF-16 units.
    const shown_title = text_util.utf16Into(&data.szInfoTitle, heading);
    const shown_body = text_util.utf16Into(&data.szInfo, text);
    data.dwInfoFlags = c.NIIF_USER | c.NIIF_LARGE_ICON | c.NIIF_RESPECT_QUIET_TIME;
    data.hBalloonIcon = self.big_icon;

    if (!self.place(&data)) {
        // No notification area (no Explorer, another desktop).
        if (!self.warned) log.warn("a notification could not be shown err={}", .{c.GetLastError()});
        self.warned = true;
        return;
    }
    self.shown = true;
    self.surface = surface;
    test_hooks.recordNotification(&self.app.test_state, self.app.core_app.alloc, surface, shown_title, shown_body);
    _ = c.KillTimer(hwnd, focused_timer);
    if (focused) _ = c.SetTimer(hwnd, focused_timer, focused_timeout_ms, null);
}

/// Take the notification back: the icon goes, and its toasts with it.
pub fn withdraw(self: *Notifications) void {
    const hwnd = self.hwnd orelse return;
    _ = c.KillTimer(hwnd, focused_timer);
    if (!self.shown) return;
    self.shown = false;
    self.surface = null;
    var data = self.iconData();
    _ = self.shell(c.NIM_DELETE, &data);
}

/// The pane `id` got the keyboard, or closes: its notification goes, as
/// GTK's do.
pub fn surfaceDone(self: *Notifications, id: u64) void {
    if (self.shown and self.surface == id) self.withdraw();
}

/// The toast or the icon was clicked: the notification goes, and its pane
/// comes forward from the message loop once no dialog is open (one of the
/// app's own presents nothing, as GTK's).
pub fn clicked(self: *Notifications) void {
    if (!self.shown) return;
    const id = self.surface;
    self.withdraw();
    if (id) |v| self.app.request(.{ .present_surface = v });
}

fn wndProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *Notifications = @ptrFromInt(@as(usize, @bitCast(ptr)));
    switch (msg) {
        WM_ICON => {
            const event: c.UINT = @intCast(@as(usize, @bitCast(lparam)) & 0xFFFF);
            switch (event) {
                // A toast that times out stays in the notification center,
                // and the icon with it.
                c.NIN_BALLOONUSERCLICK, c.NIN_SELECT, c.NIN_KEYSELECT => {
                    if (self.busy) {
                        _ = c.PostMessageW(hwnd, msg, wparam, lparam);
                    } else self.clicked();
                },
                else => {},
            }
            return 0;
        },
        c.WM_TIMER => {
            if (wparam == focused_timer) self.withdraw();
            return 0;
        },
        else => {
            // Explorer restarted, or rebuilt the taskbar: the icon at its
            // DPI again, if a notification is pending (its toast is gone).
            if (msg == self.taskbar_created and self.taskbar_created != 0) {
                self.loadIcons();
                if (self.shown) {
                    var data = self.iconOnly();
                    if (!self.shell(c.NIM_ADD, &data) and !self.shell(c.NIM_MODIFY, &data)) {
                        self.shown = false;
                        self.surface = null;
                    }
                }
                return 0;
            }
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
    }
}

test "NOTIFYICONDATAW is laid out as Windows' (x64)" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    const testing = std.testing;
    const T = c.NOTIFYICONDATAW;
    try testing.expectEqual(@as(usize, 976), @sizeOf(T));
    try testing.expectEqual(@as(usize, 32), @offsetOf(T, "hIcon"));
    try testing.expectEqual(@as(usize, 304), @offsetOf(T, "szInfo"));
    try testing.expectEqual(@as(usize, 816), @offsetOf(T, "uVersion"));
    try testing.expectEqual(@as(usize, 820), @offsetOf(T, "szInfoTitle"));
    try testing.expectEqual(@as(usize, 948), @offsetOf(T, "dwInfoFlags"));
    try testing.expectEqual(@as(usize, 952), @offsetOf(T, "guidItem"));
    try testing.expectEqual(@as(usize, 968), @offsetOf(T, "hBalloonIcon"));
}
