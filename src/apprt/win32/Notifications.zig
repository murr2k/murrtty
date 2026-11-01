//! Desktop notifications (roadmap 5.2, 5.2b): OSC 9 and OSC 777 as
//! Windows' toasts (toast.zig), each its own in the notification center,
//! grouped by pane. GTK's stay until their pane gets the keyboard (3 s, for
//! one sent while it had it), and a click presents the pane; here a pane's
//! toasts go together when it gets the keyboard or closes, one sent while
//! it had the keyboard goes 3 s later, the same text from the same pane
//! replaces its toast, and a click presents the pane. Those left go when
//! murrtty quits.
//!
//! Where Windows has no toasts, balloons of a notification-area icon
//! instead, which Windows also shows as toasts. A balloon carries no id of
//! its own, so the icon stands for the latest notification: it comes with
//! it and goes when that one's pane gets the keyboard or closes, when its
//! 3 s pass, or when it is clicked, which takes the toast out of the
//! notification center too. Without the tray the icon is there only while
//! a notification is; as the tray (roadmap 5.6) it stays, a click on it
//! brings murrtty forward and its menu offers New Window, Config and Quit,
//! and a notification's balloon comes and goes on it.
const Notifications = @This();

const std = @import("std");

const c = @import("c.zig");
const App = @import("App.zig");
const ContextMenu = @import("ContextMenu.zig");
const global = @import("../../global.zig");
const test_hooks = @import("test_hooks.zig");
const text_util = @import("text.zig");
const toast = @import("toast.zig");

const log = std.log.scoped(.win32_notifications);

const class_name = c.L("MurrttyNotify");
/// The icon's messages (NOTIFYICON_VERSION_4: the event in lparam's low
/// word). The GUI tests' hooks send one to click.
pub const WM_ICON = c.WM_APP + 1;
/// A toast was clicked (toast.Target's parameters), posted from Windows'
/// thread.
pub const WM_TOAST = c.WM_APP + 2;
const icon_id = 1;
/// The balloon's 3 s, and the toasts'.
const focused_timer = 1;
const toast_timer = 2;
/// GTK takes back a notification sent to the pane with the keyboard after
/// this.
const focused_timeout_ms = 3000;

app: *App,
/// A hidden top-level window (a message-only one would miss Explorer's
/// TaskbarCreated) that the icon's and toasts' messages go to; null if it
/// couldn't be made, and then nothing is shown.
hwnd: ?c.HWND = null,
small_icon: ?c.HICON = null,
big_icon: ?c.HICON = null,
taskbar_created: c.UINT = 0,
/// Whether the icon is in the notification area.
shown: bool = false,
/// Whether it is the tray, there whether or not a notification is.
tray: bool = false,
/// Whether a balloon notification is pending (the latest stands until it
/// goes).
pending: bool = false,
/// The latest balloon's pane, by core id; null for one of the app's.
surface: ?u64 = null,
/// Inside a call to Explorer, which runs the messages sent meanwhile: a
/// click then waits (`WM_ICON` is posted again).
busy: bool = false,
warned: bool = false,

/// Windows' toasts, made at the first notification (a launch that only
/// hands off to the running murrtty never pays for them).
toasts: ?toast.Toasts = null,
/// Whether making them was tried since they were last let go.
toasts_tried: bool = false,
/// Whether notifications go as toasts: Windows', or, while the GUI tests'
/// hooks record notifications, as if they were. Balloons otherwise.
use_toasts: bool = false,
warned_toast: bool = false,
/// Whether this test murrtty registered its own identity (removed at the
/// end).
test_identity: bool = false,
/// The toasts standing, oldest first.
standing: std.ArrayList(Standing) = .empty,
/// The most kept in `standing`: Windows keeps fewer in its notification
/// center, so older ones are gone there, and a chatty pane in the
/// background can't grow the list.
const max_standing = 32;

pub const Standing = struct {
    /// The pane's core id; null for one of murrtty's own.
    surface: ?u64,
    /// The toast's tag in its pane's group: its title and body hashed, so
    /// the same text replaces it.
    tag: [16]u8,
    /// When it goes (GetTickCount64), for one sent to the pane with the
    /// keyboard.
    expires: ?u64,
};

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
    // Toasts, unless the GUI tests ask for balloons, or Windows turns out
    // to have none.
    self.use_toasts = !test_hooks.forcesBalloons(&app.test_state);
}

/// Windows' toasts, made now if they aren't; false if Windows has none
/// (the balloons then). While the GUI tests' hooks record notifications,
/// none are needed.
fn ensureToasts(self: *Notifications) bool {
    if (test_hooks.recordsNotifications(&self.app.test_state)) return true;
    if (self.toasts != null) return true;
    if (self.toasts_tried) return false;
    self.toasts_tried = true;
    const hwnd = self.hwnd orelse return false;
    // A test murrtty (the on-screen scenario's) shows its toasts as an
    // identity of its own, leaving the user's murrtty's registration alone,
    // and removes it as it goes.
    const testing = test_hooks.active();
    const app_id: []const u16 = if (testing) test_app_id else App.app_user_model_id;
    self.toasts = toast.Toasts.init(app_id, hwnd, WM_TOAST) orelse {
        self.use_toasts = false;
        return false;
    };
    if (testing) {
        self.registerIdentity(test_app_id_utf8, "murrtty (GUI test)");
        self.test_identity = true;
    } else self.registerIdentity(App.app_user_model_id_utf8, "murrtty");
    return true;
}

const test_app_id_utf8 = "murrtty.gui-test";
const test_app_id = c.L(test_app_id_utf8);

/// Let Windows' toasts go after a failure (the notification service may
/// have restarted): the next notification makes them again.
fn dropToasts(self: *Notifications) void {
    if (self.toasts) |*t| t.deinit();
    self.toasts = null;
    self.toasts_tried = false;
}

/// `name` and murrtty's icon on `app_id`'s toasts, without which Windows
/// shows none (toast.register): the icon is `murrtty.png` in the
/// resources (share\ghostty).
fn registerIdentity(self: *Notifications, app_id: []const u8, name: []const u8) void {
    const alloc = self.app.core_app.alloc;
    var icon: ?[]u8 = null;
    defer if (icon) |path| alloc.free(path);
    if (global.resourcesDir().app()) |dir| icon: {
        const path = std.fs.path.join(alloc, &.{ dir, "murrtty.png" }) catch break :icon;
        // Backslashes only: the resources' path can hold a '/' (zig-out/share),
        // which files open with but the notification center doesn't, showing
        // no icon.
        std.mem.replaceScalar(u8, path, '/', '\\');
        const wide = text_util.utf16Lossy(alloc, path) catch {
            alloc.free(path);
            break :icon;
        };
        defer alloc.free(wide);
        if (c.GetFileAttributesW(wide) == c.INVALID_FILE_ATTRIBUTES) {
            alloc.free(path);
            break :icon;
        }
        icon = path;
    }
    toast.register(alloc, app_id, name, icon);
}

pub fn deinit(self: *Notifications) void {
    const hwnd = self.hwnd orelse return;
    _ = c.KillTimer(hwnd, focused_timer);
    _ = c.KillTimer(hwnd, toast_timer);
    // Toasts of panes that are gone would present nothing.
    self.withdrawToasts();
    self.standing.deinit(self.app.core_app.alloc);
    self.standing = .empty;
    if (self.toasts) |*t| t.deinit();
    self.toasts = null;
    self.use_toasts = false;
    if (self.test_identity) toast.unregister(self.app.core_app.alloc, test_app_id_utf8);
    self.test_identity = false;
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

/// Keep the icon in the notification area as the tray, or not. Without its
/// window nothing changes, and `tray` stays false.
pub fn setTray(self: *Notifications, on: bool) void {
    if (self.hwnd == null or on == self.tray) return;
    self.tray = on;
    if (on) {
        var data = self.iconOnly();
        // Without a notification area yet (Explorer starting), it comes
        // with TaskbarCreated.
        if (self.place(&data)) {
            self.shown = true;
        } else log.warn("the tray icon could not be added yet err={}", .{c.GetLastError()});
    } else if (!self.pending) self.remove();
}

fn remove(self: *Notifications) void {
    var data = self.iconData();
    _ = self.shell(c.NIM_DELETE, &data);
    self.shown = false;
}

/// Whether a notification stands (a toast, or the balloon's).
pub fn anyPending(self: *const Notifications) bool {
    return self.pending or self.standing.items.len > 0;
}

/// The pane of the latest notification standing (0 for murrtty's own or
/// none), for the tests' dump.
pub fn latestSurface(self: *const Notifications) u64 {
    if (self.standing.items.len > 0) return self.standing.items[self.standing.items.len - 1].surface orelse 0;
    return self.surface orelse 0;
}

/// Show a notification from the pane `surface` (null: the app's own),
/// `focused` if that pane has the keyboard. With no title it is murrtty's,
/// as GTK's is Ghostty's.
pub fn send(self: *Notifications, surface: ?u64, focused: bool, title: []const u8, body: []const u8) void {
    if (self.hwnd == null) return;
    if (self.use_toasts and self.sendToast(surface, focused, title, body)) return;
    self.sendBalloon(surface, focused, title, body);
}

/// As a toast; false if Windows refused it (then a balloon instead).
fn sendToast(self: *Notifications, surface: ?u64, focused: bool, title: []const u8, body: []const u8) bool {
    if (!self.ensureToasts()) return false;
    const alloc = self.app.core_app.alloc;
    const heading: []const u8 = if (title.len > 0) title else "murrtty";
    const tag = tagFor(title, body);
    var group_buf: [32]u8 = undefined;
    const group = groupFor(&group_buf, surface);
    if (self.toasts) |*t| {
        t.show(alloc, .{
            .target = if (surface) |id| .{ .surface = id } else .app,
            .group = group,
            .tag = &tag,
            .title = heading,
            .body = body,
        }) catch |err| {
            if (!self.warned_toast) log.warn("a toast could not be shown, a balloon instead err={}", .{err});
            self.warned_toast = true;
            if (err == error.ToastNotShown) self.dropToasts();
            return false;
        };
    }
    // Showing replaced a toast of the same text from the same pane.
    self.forget(surface, &tag);
    if (self.standing.items.len >= max_standing) _ = self.standing.orderedRemove(0);
    self.standing.append(alloc, .{
        .surface = surface,
        .tag = tag,
        .expires = if (focused) c.GetTickCount64() + focused_timeout_ms else null,
    }) catch {};
    test_hooks.recordNotificationText(&self.app.test_state, alloc, surface, heading, body);
    self.armToastTimer();
    return true;
}

fn sendBalloon(self: *Notifications, surface: ?u64, focused: bool, title: []const u8, body: []const u8) void {
    const hwnd = self.hwnd orelse return;
    var data = self.iconOnly();
    data.uFlags |= c.NIF_INFO;
    // With no body the title says it under murrtty's (a balloon with no
    // text isn't shown).
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
    self.pending = true;
    self.surface = surface;
    test_hooks.recordNotification(&self.app.test_state, self.app.core_app.alloc, surface, shown_title, shown_body);
    _ = c.KillTimer(hwnd, focused_timer);
    if (focused) _ = c.SetTimer(hwnd, focused_timer, focused_timeout_ms, null);
}

/// A pane's toasts' group, or murrtty's own (this process's: another
/// murrtty, of another class, has its own).
fn groupFor(buf: []u8, surface: ?u64) []const u8 {
    if (surface) |id| return std.fmt.bufPrint(buf, "pane-{d}", .{id}) catch unreachable;
    return std.fmt.bufPrint(buf, "app-{d}", .{c.GetCurrentProcessId()}) catch unreachable;
}

fn tagFor(title: []const u8, body: []const u8) [16]u8 {
    var hash: std.hash.Wyhash = .init(0);
    hash.update(title);
    hash.update(&.{0});
    hash.update(body);
    var out: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x:0>16}", .{hash.final()}) catch unreachable;
    return out;
}

fn samePane(a: ?u64, b: ?u64) bool {
    if (a) |x| return if (b) |y| x == y else false;
    return b == null;
}

/// Forget the standing toast of `surface` with `tag` (Windows replaced it).
fn forget(self: *Notifications, surface: ?u64, tag: *const [16]u8) void {
    var i: usize = 0;
    while (i < self.standing.items.len) {
        const s = self.standing.items[i];
        if (samePane(s.surface, surface) and std.mem.eql(u8, &s.tag, tag)) {
            _ = self.standing.orderedRemove(i);
        } else i += 1;
    }
}

/// Take back the toasts of `surface`'s pane (null: murrtty's own).
fn withdrawPane(self: *Notifications, surface: ?u64) void {
    var found = false;
    var i: usize = 0;
    while (i < self.standing.items.len) {
        if (samePane(self.standing.items[i].surface, surface)) {
            _ = self.standing.orderedRemove(i);
            found = true;
        } else i += 1;
    }
    if (!found) return;
    // Made again if they were let go after a failure, so what stands goes.
    if (self.ensureToasts()) if (self.toasts) |*t| {
        var group_buf: [32]u8 = undefined;
        _ = t.removeGroup(self.app.core_app.alloc, groupFor(&group_buf, surface));
    };
    self.armToastTimer();
}

/// Take back every toast standing.
fn withdrawToasts(self: *Notifications) void {
    while (self.standing.items.len > 0) self.withdrawPane(self.standing.items[0].surface);
}

/// The toast timer for the next of the 3 s to end, or none.
fn armToastTimer(self: *Notifications) void {
    const hwnd = self.hwnd orelse return;
    var next: ?u64 = null;
    for (self.standing.items) |s| if (s.expires) |e| {
        if (next == null or e < next.?) next = e;
    };
    const due = next orelse {
        _ = c.KillTimer(hwnd, toast_timer);
        return;
    };
    const now = c.GetTickCount64();
    const wait: c.UINT = if (due > now) @intCast(@min(due - now, focused_timeout_ms)) else 1;
    _ = c.SetTimer(hwnd, toast_timer, wait, null);
}

/// Take back the toasts whose 3 s have passed.
fn expireToasts(self: *Notifications) void {
    const now = c.GetTickCount64();
    var i: usize = 0;
    while (i < self.standing.items.len) {
        const s = self.standing.items[i];
        const expires = s.expires orelse {
            i += 1;
            continue;
        };
        if (expires > now) {
            i += 1;
            continue;
        }
        _ = self.standing.orderedRemove(i);
        if (self.toasts) |*t| {
            var group_buf: [32]u8 = undefined;
            _ = t.remove(self.app.core_app.alloc, groupFor(&group_buf, s.surface), &s.tag);
        }
    }
    self.armToastTimer();
}

/// Take every notification back: the toasts, and the balloon's icon.
pub fn withdraw(self: *Notifications) void {
    self.withdrawToasts();
    self.withdrawBalloon();
}

/// Take the balloon back: the icon goes, and its toasts with it. The
/// tray's comes straight back: deleting the icon is what takes a toast out
/// of the notification center (an empty balloon only hides one showing).
fn withdrawBalloon(self: *Notifications) void {
    const hwnd = self.hwnd orelse return;
    _ = c.KillTimer(hwnd, focused_timer);
    if (!self.pending) return;
    self.pending = false;
    self.surface = null;
    self.remove();
    if (self.tray) {
        var data = self.iconOnly();
        if (self.place(&data)) self.shown = true;
    }
}

/// The pane `id` got the keyboard, or closes: its notifications go, as
/// GTK's do.
pub fn surfaceDone(self: *Notifications, id: u64) void {
    self.withdrawPane(id);
    if (self.pending and self.surface == id) self.withdrawBalloon();
}

/// The balloon or the icon was clicked: the notification goes, and its pane
/// comes forward from the message loop once no dialog is open (one of the
/// app's own presents nothing, as GTK's).
pub fn clicked(self: *Notifications) void {
    if (!self.pending) return;
    const id = self.surface;
    self.withdrawBalloon();
    if (id) |v| self.app.request(.{ .present_surface = v });
}

/// A toast was clicked: its pane's notifications go, and the pane comes
/// forward, as a balloon's.
fn activated(self: *Notifications, target: toast.Target) void {
    switch (target) {
        .surface => |id| {
            self.withdrawPane(id);
            self.app.request(.{ .present_surface = id });
        },
        .app => self.withdrawPane(null),
    }
}

/// For the GUI tests: click the latest notification as Windows would, a
/// toast through the message its click posts.
pub fn clickLatest(self: *Notifications) void {
    const hwnd = self.hwnd orelse return;
    if (self.standing.items.len > 0) {
        const latest = self.standing.items[self.standing.items.len - 1];
        const target: toast.Target = if (latest.surface) |id| .{ .surface = id } else .app;
        _ = c.PostMessageW(hwnd, WM_TOAST, target.wparam(), target.lparam());
        return;
    }
    _ = c.SendMessageW(hwnd, WM_ICON, 0, c.NIN_BALLOONUSERCLICK);
}

fn wndProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *Notifications = @ptrFromInt(@as(usize, @bitCast(ptr)));
    switch (msg) {
        WM_ICON => {
            const event: c.UINT = @intCast(@as(usize, @bitCast(lparam)) & 0xFFFF);
            switch (event) {
                c.NIN_BALLOONUSERCLICK, c.NIN_SELECT, c.NIN_KEYSELECT, c.WM_CONTEXTMENU => if (self.busy) {
                    _ = c.PostMessageW(hwnd, msg, wparam, lparam);
                    return 0;
                },
                else => return 0,
            }
            switch (event) {
                // A toast that times out stays in the notification center,
                // and the icon with it.
                c.NIN_BALLOONUSERCLICK => self.clicked(),
                // The icon itself: the tray's brings murrtty forward, a
                // notification's stands for it.
                c.NIN_SELECT, c.NIN_KEYSELECT => if (self.tray) self.app.trayActivate() else self.clicked(),
                // Its anchor in wparam (NOTIFYICON_VERSION_4).
                c.WM_CONTEXTMENU => if (self.tray) self.app.trayMenu(hwnd, .{ .x = c.xParam(@bitCast(wparam)), .y = c.yParam(@bitCast(wparam)) }),
                else => {},
            }
            return 0;
        },
        // Posted by toast.zig's handler, or another process: it only
        // names a pane, which then comes forward.
        WM_TOAST => {
            if (self.use_toasts) if (toast.Target.fromMessage(wparam, lparam)) |target| self.activated(target);
            return 0;
        },
        // The tray's menu is owner-drawn (ContextMenu).
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
        c.WM_TIMER => {
            switch (wparam) {
                focused_timer => self.withdrawBalloon(),
                toast_timer => self.expireToasts(),
                else => {},
            }
            return 0;
        },
        else => {
            // Explorer started, restarted or rebuilt the taskbar: the icon
            // at its DPI again, for the tray or a pending notification (its
            // toast is gone).
            if (msg == self.taskbar_created and self.taskbar_created != 0) {
                self.loadIcons();
                if (self.shown or self.tray) {
                    var data = self.iconOnly();
                    self.shown = false;
                    if (self.place(&data)) {
                        self.shown = true;
                    } else {
                        self.pending = false;
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

test "toast groups and tags" {
    const testing = std.testing;
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("pane-18446744073709551615", groupFor(&buf, 18446744073709551615));
    try testing.expect(std.mem.startsWith(u8, groupFor(&buf, null), "app-"));
    // The same text, the same tag; another, another.
    try testing.expectEqualSlices(u8, &tagFor("t", "b"), &tagFor("t", "b"));
    try testing.expect(!std.mem.eql(u8, &tagFor("t", "b"), &tagFor("tb", "")));
    try testing.expect(samePane(null, null) and samePane(3, 3) and !samePane(3, null) and !samePane(null, 3));
}
