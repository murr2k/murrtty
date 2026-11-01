//! WinRT toasts (roadmap 5.2b): each desktop notification its own toast in
//! Windows' notification center, under murrtty's AppUserModelID. Toasts
//! are grouped by pane, so a pane taking the keyboard or closing takes back
//! only its own (`removeGroup`), as GTK's go with their pane, and the same
//! text from the same pane replaces its toast (the tag). A click raises
//! Activated, which Windows calls on a thread of its own: the handler reads
//! the pane from the toast's launch argument and posts it to the
//! notifications' window, touching nothing else.
//!
//! An unpackaged murrtty needs no shortcut or package: Windows takes toasts
//! for any AppUserModelID, and `register` gives murrtty's its name and icon
//! under HKCU, as unpackaged apps register. combase's WinRT functions are
//! loaded at run time (Zig's mingw-w64 has no import library for combase
//! on x64 or ARM64); without them, or if Windows refuses the notifier,
//! notifications fall back to balloons (Notifications.zig). The interfaces
//! are laid out from the system's own metadata (System32\WinMetadata: an
//! interface's methods in metadata order follow IInspectable's six slots);
//! the unit test calls every slot used but Show.
const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("c.zig");
const text_util = @import("text.zig");

const log = std.log.scoped(.win32_toast);

const GUID = c.GUID;
const HRESULT = c.HRESULT;
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));

/// A WinRT string; null is the empty one.
const HSTRING = ?*opaque {};

const IID_IUnknown = GUID.parse("{00000000-0000-0000-c000-000000000046}");
const IID_IAgileObject = GUID.parse("{94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90}");
const IID_IToastNotificationManagerStatics = GUID.parse("{50ac103f-d235-4598-bbef-98fe4d1a3ad4}");
const IID_IToastNotificationManagerStatics2 = GUID.parse("{7ab93c52-0e48-4750-ba9d-1a4113981847}");
const IID_IToastNotificationFactory = GUID.parse("{04124b20-82c6-4229-b109-fd9ed4662b53}");
const IID_IToastNotification2 = GUID.parse("{9dfb9fd1-143a-490e-90bf-b9fba7132de7}");
const IID_IToastActivatedEventArgs = GUID.parse("{e3bf92f3-c197-436f-8265-0625824f8dac}");
const IID_IXmlDocument = GUID.parse("{f7f3a506-1e87-42d6-bcfb-b8c809fa5494}");
const IID_IXmlDocumentIO = GUID.parse("{6cd0e74e-ee65-4489-9ebf-ca43e87ba637}");
/// TypedEventHandler<ToastNotification, Object>: Activated's handler.
const IID_ActivatedHandler = GUID.parse("{ab54de2d-97d9-5528-b6ad-105afe156530}");

//---------------------------------------------------------------
// combase

const Combase = struct {
    create_string: *const fn (?[*]const u16, u32, *HSTRING) callconv(.winapi) HRESULT,
    delete_string: *const fn (HSTRING) callconv(.winapi) HRESULT,
    raw_buffer: *const fn (HSTRING, ?*u32) callconv(.winapi) ?[*]const u16,
    get_factory: *const fn (HSTRING, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    activate: *const fn (HSTRING, *?*anyopaque) callconv(.winapi) HRESULT,
};

/// Loaded once on the UI thread, before any toast exists, and never
/// unloaded (COM keeps combase loaded anyway); the handler reads it on
/// Windows' thread after that.
var combase: ?Combase = null;

fn loadCombase() ?Combase {
    if (combase) |api| return api;
    const lib = c.LoadLibraryExW(c.L("combase.dll"), null, c.LOAD_LIBRARY_SEARCH_SYSTEM32) orelse return null;
    const api: Combase = .{
        .create_string = @ptrCast(c.GetProcAddress(lib, "WindowsCreateString") orelse return null),
        .delete_string = @ptrCast(c.GetProcAddress(lib, "WindowsDeleteString") orelse return null),
        .raw_buffer = @ptrCast(c.GetProcAddress(lib, "WindowsGetStringRawBuffer") orelse return null),
        .get_factory = @ptrCast(c.GetProcAddress(lib, "RoGetActivationFactory") orelse return null),
        .activate = @ptrCast(c.GetProcAddress(lib, "RoActivateInstance") orelse return null),
    };
    combase = api;
    return api;
}

/// An owned WinRT string.
const Str = struct {
    h: HSTRING = null,

    fn init(api: Combase, s: []const u16) !Str {
        var h: HSTRING = null;
        if (api.create_string(if (s.len > 0) s.ptr else null, @intCast(s.len), &h) < 0) return error.WinRtString;
        return .{ .h = h };
    }

    fn initUtf8(api: Combase, alloc: Allocator, s: []const u8) !Str {
        const w = try text_util.utf16Lossy(alloc, s);
        defer alloc.free(w);
        return init(api, w);
    }

    fn deinit(self: Str, api: Combase) void {
        if (self.h != null) _ = api.delete_string(self.h);
    }
};

/// The text of `h` (valid while `h` is).
fn chars(api: Combase, h: HSTRING) []const u16 {
    var len: u32 = 0;
    const buf = api.raw_buffer(h, &len) orelse return &.{};
    return buf[0..len];
}

//---------------------------------------------------------------
// Interfaces

const Unknown = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
};
/// A vtable slot this file doesn't call.
const Unused = *const anyopaque;
/// IInspectable: IUnknown, then three slots this file doesn't call.
const Inspectable = extern struct {
    unknown: Unknown,
    GetIids: Unused,
    GetRuntimeClassName: Unused,
    GetTrustLevel: Unused,
};

const IInspectable = extern struct {
    vtbl: *const extern struct { base: Inspectable },
};

const IToastNotificationManagerStatics = extern struct {
    vtbl: *const extern struct {
        base: Inspectable,
        CreateToastNotifier: Unused,
        CreateToastNotifierWithId: *const fn (*IToastNotificationManagerStatics, HSTRING, *?*IToastNotifier) callconv(.winapi) HRESULT,
        GetTemplateContent: Unused,
    },
};

const IToastNotificationManagerStatics2 = extern struct {
    vtbl: *const extern struct {
        base: Inspectable,
        get_History: *const fn (*IToastNotificationManagerStatics2, *?*IToastNotificationHistory) callconv(.winapi) HRESULT,
    },
};

const IToastNotificationHistory = extern struct {
    vtbl: *const extern struct {
        base: Inspectable,
        RemoveGroup: Unused,
        RemoveGroupWithId: *const fn (*IToastNotificationHistory, HSTRING, HSTRING) callconv(.winapi) HRESULT,
        RemoveGroupedTagWithId: *const fn (*IToastNotificationHistory, HSTRING, HSTRING, HSTRING) callconv(.winapi) HRESULT,
        RemoveGroupedTag: Unused,
        Remove: Unused,
        Clear: Unused,
        ClearWithId: Unused,
    },
};

const IToastNotificationFactory = extern struct {
    vtbl: *const extern struct {
        base: Inspectable,
        /// The content is an XmlDocument's IXmlDocument.
        CreateToastNotification: *const fn (*IToastNotificationFactory, *anyopaque, *?*IToastNotification) callconv(.winapi) HRESULT,
    },
};

const IToastNotification = extern struct {
    vtbl: *const extern struct {
        base: Inspectable,
        get_Content: Unused,
        put_ExpirationTime: Unused,
        get_ExpirationTime: Unused,
        add_Dismissed: Unused,
        remove_Dismissed: Unused,
        /// An EventRegistrationToken is an i64.
        add_Activated: *const fn (*IToastNotification, *Handler, *i64) callconv(.winapi) HRESULT,
        remove_Activated: Unused,
        add_Failed: Unused,
        remove_Failed: Unused,
    },
};

const IToastNotification2 = extern struct {
    vtbl: *const extern struct {
        base: Inspectable,
        put_Tag: *const fn (*IToastNotification2, HSTRING) callconv(.winapi) HRESULT,
        get_Tag: *const fn (*IToastNotification2, *HSTRING) callconv(.winapi) HRESULT,
        put_Group: *const fn (*IToastNotification2, HSTRING) callconv(.winapi) HRESULT,
        get_Group: *const fn (*IToastNotification2, *HSTRING) callconv(.winapi) HRESULT,
        /// A WinRT boolean is a byte.
        put_SuppressPopup: *const fn (*IToastNotification2, u8) callconv(.winapi) HRESULT,
        get_SuppressPopup: *const fn (*IToastNotification2, *u8) callconv(.winapi) HRESULT,
    },
};

const IToastNotifier = extern struct {
    vtbl: *const extern struct {
        base: Inspectable,
        Show: *const fn (*IToastNotifier, *IToastNotification) callconv(.winapi) HRESULT,
        Hide: Unused,
        get_Setting: *const fn (*IToastNotifier, *Setting) callconv(.winapi) HRESULT,
        AddToSchedule: Unused,
        RemoveFromSchedule: Unused,
        GetScheduledToastNotifications: Unused,
    },
};

const IToastActivatedEventArgs = extern struct {
    vtbl: *const extern struct {
        base: Inspectable,
        get_Arguments: *const fn (*IToastActivatedEventArgs, *HSTRING) callconv(.winapi) HRESULT,
    },
};

const IXmlDocumentIO = extern struct {
    vtbl: *const extern struct {
        base: Inspectable,
        LoadXml: *const fn (*IXmlDocumentIO, HSTRING) callconv(.winapi) HRESULT,
        LoadXmlWithSettings: Unused,
        SaveToFileAsync: Unused,
    },
};

fn release(obj: anytype) void {
    _ = obj.vtbl.base.unknown.Release(obj);
}

fn query(comptime T: type, obj: anytype, iid: *const GUID) ?*T {
    var out: ?*anyopaque = null;
    if (obj.vtbl.base.unknown.QueryInterface(obj, iid, &out) < 0) return null;
    return @ptrCast(@alignCast(out orelse return null));
}

fn factory(comptime T: type, api: Combase, class: []const u16, iid: *const GUID) !*T {
    const name = try Str.init(api, class);
    defer name.deinit(api);
    var out: ?*anyopaque = null;
    const hr = api.get_factory(name.h, iid, &out);
    if (hr < 0) {
        log.warn("no activation factory for {s} hr=0x{x}", .{ @typeName(T), @as(u32, @bitCast(hr)) });
        return error.WinRtFactory;
    }
    return @ptrCast(@alignCast(out orelse return error.WinRtFactory));
}

/// Whether Windows shows the notifier's toasts (Settings' notifications).
pub const Setting = enum(i32) {
    enabled = 0,
    disabled_for_application = 1,
    disabled_for_user = 2,
    disabled_by_group_policy = 3,
    disabled_by_manifest = 4,
    _,
};

//---------------------------------------------------------------
// Activated

/// Activated's handler, the one for all of murrtty's toasts. Windows calls
/// it on a thread of its own and may hold it after murrtty stops
/// listening, so it is reference counted and posts only a pane's id.
const Handler = struct {
    /// The vtable first, as COM lays an object out.
    vtbl: *const VTable = &vtable,
    refs: std.atomic.Value(u32) = .init(1),
    /// Where clicks go (an HWND), 0 once murrtty stops listening.
    hwnd: std.atomic.Value(usize),
    msg: c.UINT,

    comptime {
        std.debug.assert(@offsetOf(Handler, "vtbl") == 0);
    }

    const VTable = extern struct {
        QueryInterface: *const fn (*Handler, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Handler) callconv(.winapi) u32,
        Release: *const fn (*Handler) callconv(.winapi) u32,
        Invoke: *const fn (*Handler, ?*anyopaque, ?*IInspectable) callconv(.winapi) HRESULT,
    };

    const vtable: VTable = .{
        .QueryInterface = &queryInterface,
        .AddRef = &addRef,
        .Release = &releaseHandler,
        .Invoke = &invoke,
    };

    fn create(hwnd: c.HWND, msg: c.UINT) !*Handler {
        const self = try std.heap.page_allocator.create(Handler);
        self.* = .{ .hwnd = .init(@intFromPtr(hwnd)), .msg = msg };
        return self;
    }

    /// Agile: Windows may call it from any thread, which it is safe for.
    fn queryInterface(self: *Handler, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        if (std.meta.eql(iid.*, IID_IUnknown) or std.meta.eql(iid.*, IID_IAgileObject) or std.meta.eql(iid.*, IID_ActivatedHandler)) {
            _ = addRef(self);
            out.* = self;
            return c.S_OK;
        }
        out.* = null;
        return E_NOINTERFACE;
    }

    fn addRef(self: *Handler) callconv(.winapi) u32 {
        return self.refs.fetchAdd(1, .monotonic) + 1;
    }

    fn releaseHandler(self: *Handler) callconv(.winapi) u32 {
        const left = self.refs.fetchSub(1, .acq_rel) - 1;
        if (left == 0) std.heap.page_allocator.destroy(self);
        return left;
    }

    fn invoke(self: *Handler, sender: ?*anyopaque, args: ?*IInspectable) callconv(.winapi) HRESULT {
        _ = sender;
        const api = combase orelse return c.S_OK;
        const inspectable = args orelse return c.S_OK;
        const activated = query(IToastActivatedEventArgs, inspectable, &IID_IToastActivatedEventArgs) orelse return c.S_OK;
        defer release(activated);
        var h: HSTRING = null;
        if (activated.vtbl.get_Arguments(activated, &h) < 0) return c.S_OK;
        defer _ = api.delete_string(h);
        const target = parseLaunch(chars(api, h)) orelse return c.S_OK;
        const hwnd = self.hwnd.load(.acquire);
        if (hwnd == 0) return c.S_OK;
        _ = c.PostMessageW(@ptrFromInt(hwnd), self.msg, target.wparam(), target.lparam());
        return c.S_OK;
    }
};

/// Whose toast was clicked, as the launch argument names it and the
/// notifications' window gets it.
pub const Target = union(enum) {
    /// A pane, by core id.
    surface: u64,
    /// murrtty's own.
    app,

    comptime {
        // The id goes in a WPARAM.
        std.debug.assert(@sizeOf(c.WPARAM) == 8);
    }

    pub fn wparam(self: Target) c.WPARAM {
        return switch (self) {
            .surface => |id| @intCast(id),
            .app => 0,
        };
    }

    pub fn lparam(self: Target) c.LPARAM {
        return switch (self) {
            .surface => 1,
            .app => 2,
        };
    }

    /// The target of a click message's parameters, null for anything else.
    pub fn fromMessage(wp: c.WPARAM, lp: c.LPARAM) ?Target {
        return switch (lp) {
            1 => .{ .surface = @intCast(wp) },
            2 => .app,
            else => null,
        };
    }
};

const launch_prefix = "murrtty-pane=";
const launch_app = "murrtty-app";

/// A toast's launch argument for `target` (ASCII).
fn launchFor(buf: []u8, target: Target) []const u8 {
    return switch (target) {
        .surface => |id| std.fmt.bufPrint(buf, launch_prefix ++ "{d}", .{id}) catch unreachable,
        .app => launch_app,
    };
}

fn parseLaunch(arg: []const u16) ?Target {
    var buf: [64]u8 = undefined;
    if (arg.len > buf.len) return null;
    for (arg, 0..) |ch, i| {
        if (ch > 0x7F) return null;
        buf[i] = @intCast(ch);
    }
    const s = buf[0..arg.len];
    if (std.mem.eql(u8, s, launch_app)) return .app;
    if (!std.mem.startsWith(u8, s, launch_prefix)) return null;
    return .{ .surface = std.fmt.parseInt(u64, s[launch_prefix.len..], 10) catch return null };
}

//---------------------------------------------------------------
// Toasts

/// What a toast shows and whose it is.
pub const Toast = struct {
    target: Target,
    /// The pane's group and the toast's tag in it (64 characters at most).
    group: []const u8,
    tag: []const u8,
    title: []const u8,
    body: []const u8,
    /// Straight to the notification center, without showing (the unit
    /// test's).
    silent: bool = false,
};

/// Toasts' text is cut to this many bytes (a toast's payload is limited,
/// and shows a few lines).
const max_text = 1024;

pub const Toasts = struct {
    api: Combase,
    app_id: Str,
    notifier: *IToastNotifier,
    history: *IToastNotificationHistory,
    toast_factory: *IToastNotificationFactory,
    handler: *Handler,

    /// Toasts for `app_id`, their clicks posted to `hwnd` as `msg`; null
    /// where Windows has none (then balloons). On the UI thread, in its
    /// COM apartment.
    pub fn init(app_id: []const u16, hwnd: c.HWND, msg: c.UINT) ?Toasts {
        return initInner(app_id, hwnd, msg) catch |err| {
            log.warn("no toasts, balloons instead err={}", .{err});
            return null;
        };
    }

    fn initInner(app_id: []const u16, hwnd: c.HWND, msg: c.UINT) !Toasts {
        const api = loadCombase() orelse return error.NoCombase;
        const id = try Str.init(api, app_id);
        errdefer id.deinit(api);

        const statics = try factory(IToastNotificationManagerStatics, api, c.L("Windows.UI.Notifications.ToastNotificationManager"), &IID_IToastNotificationManagerStatics);
        defer release(statics);
        var notifier_out: ?*IToastNotifier = null;
        if (statics.vtbl.CreateToastNotifierWithId(statics, id.h, &notifier_out) < 0) return error.NoNotifier;
        const notifier = notifier_out orelse return error.NoNotifier;
        errdefer release(notifier);

        const statics2 = query(IToastNotificationManagerStatics2, statics, &IID_IToastNotificationManagerStatics2) orelse return error.NoHistory;
        defer release(statics2);
        var history_out: ?*IToastNotificationHistory = null;
        if (statics2.vtbl.get_History(statics2, &history_out) < 0) return error.NoHistory;
        const history = history_out orelse return error.NoHistory;
        errdefer release(history);

        const toast_factory = try factory(IToastNotificationFactory, api, c.L("Windows.UI.Notifications.ToastNotification"), &IID_IToastNotificationFactory);
        errdefer release(toast_factory);
        const handler = try Handler.create(hwnd, msg);
        return .{
            .api = api,
            .app_id = id,
            .notifier = notifier,
            .history = history,
            .toast_factory = toast_factory,
            .handler = handler,
        };
    }

    /// Stop listening (a click still on its way posts nowhere) and let go.
    /// Toasts already shown stay with Windows.
    pub fn deinit(self: *Toasts) void {
        self.handler.hwnd.store(0, .release);
        _ = Handler.releaseHandler(self.handler);
        release(self.toast_factory);
        release(self.history);
        release(self.notifier);
        self.app_id.deinit(self.api);
    }

    /// Whether Windows shows this app's toasts.
    pub fn setting(self: *const Toasts) Setting {
        var value: Setting = .enabled;
        if (self.notifier.vtbl.get_Setting(self.notifier, &value) < 0) return .enabled;
        return value;
    }

    /// Make the toast for `toast`, its Activated handled; the caller
    /// releases it.
    fn make(self: *Toasts, alloc: Allocator, toast: Toast) !*IToastNotification {
        const xml_text = try xml(alloc, toast);
        defer alloc.free(xml_text);
        const xml_str = try Str.initUtf8(self.api, alloc, xml_text);
        defer xml_str.deinit(self.api);

        var doc_out: ?*anyopaque = null;
        {
            const class = try Str.init(self.api, c.L("Windows.Data.Xml.Dom.XmlDocument"));
            defer class.deinit(self.api);
            if (self.api.activate(class.h, &doc_out) < 0) return error.NoXmlDocument;
        }
        const doc: *IInspectable = @ptrCast(@alignCast(doc_out orelse return error.NoXmlDocument));
        defer release(doc);
        const io = query(IXmlDocumentIO, doc, &IID_IXmlDocumentIO) orelse return error.NoXmlDocument;
        defer release(io);
        if (io.vtbl.LoadXml(io, xml_str.h) < 0) return error.BadToastXml;
        // The factory takes the document as its IXmlDocument.
        const content = query(IInspectable, doc, &IID_IXmlDocument) orelse return error.NoXmlDocument;
        defer release(content);

        var out: ?*IToastNotification = null;
        if (self.toast_factory.vtbl.CreateToastNotification(self.toast_factory, content, &out) < 0) return error.NoToast;
        const notification = out orelse return error.NoToast;
        errdefer release(notification);

        const two = query(IToastNotification2, notification, &IID_IToastNotification2) orelse return error.NoToast;
        defer release(two);
        const group = try Str.initUtf8(self.api, alloc, toast.group);
        defer group.deinit(self.api);
        const tag = try Str.initUtf8(self.api, alloc, toast.tag);
        defer tag.deinit(self.api);
        if (two.vtbl.put_Group(two, group.h) < 0 or two.vtbl.put_Tag(two, tag.h) < 0) return error.NoToast;
        if (toast.silent and two.vtbl.put_SuppressPopup(two, 1) < 0) return error.NoToast;

        // The toast holds the handler; the token isn't needed, since the
        // toast goes with its handler.
        var token: i64 = 0;
        if (notification.vtbl.add_Activated(notification, self.handler, &token) < 0) return error.NoToast;
        return notification;
    }

    /// Show `toast`, replacing one of the same group and tag.
    pub fn show(self: *Toasts, alloc: Allocator, toast: Toast) !void {
        const notification = try self.make(alloc, toast);
        defer release(notification);
        const hr = self.notifier.vtbl.Show(self.notifier, notification);
        if (hr < 0) {
            log.warn("a toast could not be shown hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return error.ToastNotShown;
        }
    }

    /// Take back a group's toasts, from the screen and the notification
    /// center. Whether Windows took the call.
    pub fn removeGroup(self: *Toasts, alloc: Allocator, group: []const u8) bool {
        const g = Str.initUtf8(self.api, alloc, group) catch return false;
        defer g.deinit(self.api);
        return self.history.vtbl.RemoveGroupWithId(self.history, g.h, self.app_id.h) >= 0;
    }

    /// Take back one toast. Whether Windows took the call.
    pub fn remove(self: *Toasts, alloc: Allocator, group: []const u8, tag: []const u8) bool {
        const g = Str.initUtf8(self.api, alloc, group) catch return false;
        defer g.deinit(self.api);
        const t = Str.initUtf8(self.api, alloc, tag) catch return false;
        defer t.deinit(self.api);
        return self.history.vtbl.RemoveGroupedTagWithId(self.history, t.h, g.h, self.app_id.h) >= 0;
    }
};

/// The toast's XML (UTF-8): a title line and a body line, generic.
fn xml(alloc: Allocator, toast: Toast) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var launch_buf: [64]u8 = undefined;
    try out.appendSlice(alloc, "<toast launch=\"");
    try escape(alloc, &out, launchFor(&launch_buf, toast.target));
    try out.appendSlice(alloc, "\"><visual><binding template=\"ToastGeneric\">");
    for ([_][]const u8{ toast.title, toast.body }) |text| {
        if (text.len == 0) continue;
        try out.appendSlice(alloc, "<text>");
        try escape(alloc, &out, text_util.truncate(text, max_text));
        try out.appendSlice(alloc, "</text>");
    }
    try out.appendSlice(alloc, "</binding></visual></toast>");
    return out.toOwnedSlice(alloc);
}

/// `s` as XML text: markup escaped, control characters XML can't hold
/// left out (a line break stays), and U+FFFE and U+FFFF, which XML can't
/// hold either (the document refuses them), replaced with U+FFFD. Bad
/// UTF-8 is left to the UTF-16 conversion, which replaces it.
fn escape(alloc: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        switch (ch) {
            '&' => try out.appendSlice(alloc, "&amp;"),
            '<' => try out.appendSlice(alloc, "&lt;"),
            '>' => try out.appendSlice(alloc, "&gt;"),
            '"' => try out.appendSlice(alloc, "&quot;"),
            '\'' => try out.appendSlice(alloc, "&apos;"),
            '\t', '\n' => try out.append(alloc, ch),
            0...8, 0x0B...0x1F, 0x7F => {},
            0xEF => if (i + 2 < s.len and s[i + 1] == 0xBF and (s[i + 2] == 0xBE or s[i + 2] == 0xBF)) {
                try out.appendSlice(alloc, "\xEF\xBF\xBD");
                i += 2;
            } else try out.append(alloc, ch),
            else => try out.append(alloc, ch),
        }
    }
}

//---------------------------------------------------------------
// Registration

const registry_base = "Software\\Classes\\AppUserModelId\\";

/// Give `app_id` a name and `icon` (a PNG's full path, or none) in the
/// notification center, as unpackaged apps register their AppUserModelID:
/// under HKCU\Software\Classes\AppUserModelId. Windows takes toasts for an
/// AppUserModelID registered nowhere but files them in the notification
/// center without showing them (checked on Windows 11, 2026-11-01), so
/// this is what makes them pop up. Values are written only when they
/// differ, so the key is written once per install.
pub fn register(alloc: Allocator, app_id: []const u8, name: []const u8, icon: ?[]const u8) void {
    const key = std.mem.concat(alloc, u8, &.{ registry_base, app_id }) catch return;
    defer alloc.free(key);
    setValue(alloc, key, "DisplayName", name);
    if (icon) |path| setValue(alloc, key, "IconUri", path);
}

/// Remove `app_id`'s registration (the GUI tests' own identity).
pub fn unregister(alloc: Allocator, app_id: []const u8) void {
    const key = std.mem.concat(alloc, u8, &.{ registry_base, app_id }) catch return;
    defer alloc.free(key);
    const key_w = text_util.utf16Lossy(alloc, key) catch return;
    defer alloc.free(key_w);
    _ = c.RegDeleteTreeW(c.HKEY_CURRENT_USER, key_w);
}

fn setValue(alloc: Allocator, key: []const u8, name: []const u8, value: []const u8) void {
    const key_w = text_util.utf16Lossy(alloc, key) catch return;
    defer alloc.free(key_w);
    const name_w = text_util.utf16Lossy(alloc, name) catch return;
    defer alloc.free(name_w);
    const value_w = text_util.utf16Lossy(alloc, value) catch return;
    defer alloc.free(value_w);

    var current: [1024]u16 = undefined;
    var size: c.DWORD = @sizeOf(@TypeOf(current));
    if (c.RegGetValueW(c.HKEY_CURRENT_USER, key_w, name_w, c.RRF_RT_REG_SZ, null, &current, &size) == 0) {
        const len = size / 2;
        if (len > 0 and std.mem.eql(u16, current[0 .. len - 1], value_w)) return;
    }
    const bytes: c.DWORD = @intCast((value_w.len + 1) * 2);
    const rc = c.RegSetKeyValueW(c.HKEY_CURRENT_USER, key_w, name_w, c.REG_SZ, value_w.ptr, bytes);
    if (rc != 0) log.warn("the AppUserModelID's {s} could not be written err={}", .{ name, rc });
}

//---------------------------------------------------------------
// Tests

test "launch arguments" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    const pane = launchFor(&buf, .{ .surface = 18446744073709551615 });
    var wide: [64]u16 = undefined;
    for (pane, 0..) |ch, i| wide[i] = ch;
    try testing.expectEqual(Target{ .surface = 18446744073709551615 }, parseLaunch(wide[0..pane.len]).?);
    for (launch_app, 0..) |ch, i| wide[i] = ch;
    try testing.expectEqual(Target.app, parseLaunch(wide[0..launch_app.len]).?);
    for ("murrtty-pane=x1", 0..) |ch, i| wide[i] = ch;
    try testing.expect(parseLaunch(wide[0..15]) == null);
    try testing.expectEqual(Target{ .surface = 7 }, Target.fromMessage((Target{ .surface = 7 }).wparam(), (Target{ .surface = 7 }).lparam()).?);
    try testing.expect(Target.fromMessage(1, 0) == null);
}

test "toast XML escapes its text" {
    const testing = std.testing;
    const out = try xml(testing.allocator, .{
        .target = .app,
        .group = "g",
        .tag = "t",
        .title = "a<b & \"c\"",
        .body = "x\x1b[0m\ny\xEF\xBF\xBF\xEF\xBF\xBE\xEF\xBF",
    });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "<toast launch=\"murrtty-app\"><visual><binding template=\"ToastGeneric\">" ++
            "<text>a&lt;b &amp; &quot;c&quot;</text><text>x[0m\ny\xEF\xBF\xBD\xEF\xBF\xBD\xEF\xBF</text></binding></visual></toast>",
        out,
    );
}

test "the toast interfaces' slots" {
    // Every slot used but Show (it would put a toast in the notification
    // center), under an AppUserModelID of the test's own.
    const testing = std.testing;
    const co = c.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED);
    defer if (co >= 0) c.CoUninitialize();

    // No click comes: the window is never posted to.
    const hwnd: c.HWND = @ptrFromInt(0x10);
    var toasts = Toasts.init(c.L("murrtty.unit-test.toast"), hwnd, c.WM_APP) orelse return error.SkipZigTest;
    defer toasts.deinit();
    _ = toasts.setting();

    const notification = try toasts.make(testing.allocator, .{
        .target = .{ .surface = 42 },
        .group = "group-1",
        .tag = "tag-1",
        .title = "title",
        .body = "body",
        .silent = true,
    });
    defer release(notification);
    const two = query(IToastNotification2, notification, &IID_IToastNotification2) orelse return error.TestUnexpectedResult;
    defer release(two);
    var h: HSTRING = null;
    try testing.expect(two.vtbl.get_Group(two, &h) >= 0);
    try testing.expect(std.mem.eql(u16, chars(toasts.api, h), c.L("group-1")));
    _ = toasts.api.delete_string(h);
    try testing.expect(two.vtbl.get_Tag(two, &h) >= 0);
    try testing.expect(std.mem.eql(u16, chars(toasts.api, h), c.L("tag-1")));
    _ = toasts.api.delete_string(h);
    var silent: u8 = 0;
    try testing.expect(two.vtbl.get_SuppressPopup(two, &silent) >= 0);
    try testing.expectEqual(@as(u8, 1), silent);

    // Nothing is in the test's history; Windows takes the removals all the
    // same (each slot's arguments as it expects them).
    try testing.expect(toasts.remove(testing.allocator, "group-1", "tag-1"));
    try testing.expect(toasts.removeGroup(testing.allocator, "group-1"));
}
