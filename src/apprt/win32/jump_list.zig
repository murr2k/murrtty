//! The taskbar's Jump List (roadmap 5.1): a New Window task, GTK's desktop
//! file action (`--gtk-single-instance=true`): a window in the running
//! murrtty, or a murrtty if none runs. Windows keeps the list, so the
//! single instance sets it up once it starts listening.
const std = @import("std");

const c = @import("c.zig");

const log = std.log.scoped(.win32_jump_list);

const GUID = c.GUID;
const CLSID_DestinationList = GUID.parse("{77f10cf0-3db5-4966-b520-b7c54fd35ed6}");
const IID_ICustomDestinationList = GUID.parse("{6332debf-87b5-4670-90c0-5e57b408a49e}");
const CLSID_EnumerableObjectCollection = GUID.parse("{2d3468c1-36a7-43b6-ac24-d3f02fd9607a}");
const IID_IObjectCollection = GUID.parse("{5632b1a4-e38a-400a-928a-d4cd63230295}");
const IID_IObjectArray = GUID.parse("{92ca9dcd-5622-4bba-a805-5e9f541bd8c9}");
const CLSID_ShellLink = GUID.parse("{00021401-0000-0000-c000-000000000046}");
const IID_IShellLinkW = GUID.parse("{000214f9-0000-0000-c000-000000000046}");
const IID_IPropertyStore = GUID.parse("{886d8eeb-8cf2-4446-8d02-cdba1dbdcf99}");

const PROPERTYKEY = extern struct { fmtid: GUID, pid: u32 };
/// System.Title, the task's name.
const PKEY_Title: PROPERTYKEY = .{ .fmtid = GUID.parse("{f29f85e0-4ff9-1068-ab91-08002b27b3d9}"), .pid = 2 };

const VT_LPWSTR = 31;
const PROPVARIANT = extern struct {
    vt: u16,
    reserved: [3]u16 = .{ 0, 0, 0 },
    value: extern union { pwszVal: c.LPCWSTR, pad: [2]usize },
};

const HRESULT = c.HRESULT;
const Unknown = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
};
/// A vtable slot this file doesn't call.
const Unused = *const anyopaque;

const ICustomDestinationList = extern struct {
    vtbl: *const extern struct {
        unknown: Unknown,
        SetAppID: *const fn (*ICustomDestinationList, c.LPCWSTR) callconv(.winapi) HRESULT,
        BeginList: *const fn (*ICustomDestinationList, *u32, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AppendCategory: Unused,
        AppendKnownCategory: Unused,
        AddUserTasks: *const fn (*ICustomDestinationList, *anyopaque) callconv(.winapi) HRESULT,
        CommitList: *const fn (*ICustomDestinationList) callconv(.winapi) HRESULT,
        GetRemovedDestinations: Unused,
        DeleteList: *const fn (*ICustomDestinationList, ?c.LPCWSTR) callconv(.winapi) HRESULT,
        AbortList: *const fn (*ICustomDestinationList) callconv(.winapi) HRESULT,
    },
};

const IObjectCollection = extern struct {
    vtbl: *const extern struct {
        unknown: Unknown,
        GetCount: Unused,
        GetAt: Unused,
        AddObject: *const fn (*IObjectCollection, *anyopaque) callconv(.winapi) HRESULT,
        AddFromArray: Unused,
        RemoveObjectAt: Unused,
        Clear: Unused,
    },
};

const IShellLinkW = extern struct {
    vtbl: *const extern struct {
        unknown: Unknown,
        GetPath: *const fn (*IShellLinkW, [*]u16, c_int, ?*anyopaque, u32) callconv(.winapi) HRESULT,
        GetIDList: Unused,
        SetIDList: Unused,
        GetDescription: Unused,
        SetDescription: *const fn (*IShellLinkW, c.LPCWSTR) callconv(.winapi) HRESULT,
        GetWorkingDirectory: Unused,
        SetWorkingDirectory: Unused,
        GetArguments: *const fn (*IShellLinkW, [*]u16, c_int) callconv(.winapi) HRESULT,
        SetArguments: *const fn (*IShellLinkW, c.LPCWSTR) callconv(.winapi) HRESULT,
        GetHotkey: Unused,
        SetHotkey: Unused,
        GetShowCmd: Unused,
        SetShowCmd: Unused,
        GetIconLocation: Unused,
        SetIconLocation: *const fn (*IShellLinkW, c.LPCWSTR, c_int) callconv(.winapi) HRESULT,
        SetRelativePath: Unused,
        Resolve: Unused,
        SetPath: *const fn (*IShellLinkW, c.LPCWSTR) callconv(.winapi) HRESULT,
    },
};

const IPropertyStore = extern struct {
    vtbl: *const extern struct {
        unknown: Unknown,
        GetCount: Unused,
        GetAt: Unused,
        GetValue: Unused,
        SetValue: *const fn (*IPropertyStore, *const PROPERTYKEY, *const PROPVARIANT) callconv(.winapi) HRESULT,
        Commit: *const fn (*IPropertyStore) callconv(.winapi) HRESULT,
    },
};

fn release(obj: anytype) void {
    _ = obj.vtbl.unknown.Release(obj);
}

fn create(comptime T: type, clsid: *const GUID, iid: *const GUID) ?*T {
    var out: ?*anyopaque = null;
    const hr = c.CoCreateInstance(clsid, null, c.CLSCTX_INPROC_SERVER, iid, &out);
    if (hr < 0) {
        log.warn("CoCreateInstance for {s} failed hr=0x{x}", .{ @typeName(T), @as(u32, @bitCast(hr)) });
        return null;
    }
    return @ptrCast(@alignCast(out.?));
}

/// The task's arguments, as GTK's desktop action: the window goes to the
/// running murrtty (gtk-single-instance), opened as a desktop launch's.
const arguments = c.L("--gtk-single-instance=true");

/// Make New Window murrtty's only task in the Jump List of `app_id` (the
/// AppUserModelID its windows group under). COM is started for the call.
/// Whether Windows took the list.
pub fn setUp(app_id: c.LPCWSTR) bool {
    const co = c.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED);
    defer if (co >= 0) c.CoUninitialize();

    var exe: [32768]u16 = undefined;
    const len = c.GetModuleFileNameW(null, &exe, exe.len);
    if (len == 0 or len >= exe.len) return false;
    exe[len] = 0;
    const exe_z: [*:0]const u16 = @ptrCast(&exe);

    const list = create(ICustomDestinationList, &CLSID_DestinationList, &IID_ICustomDestinationList) orelse return false;
    defer release(list);
    if (list.vtbl.SetAppID(list, app_id) < 0) return false;
    var slots: u32 = 0;
    var removed: ?*anyopaque = null;
    if (list.vtbl.BeginList(list, &slots, &IID_IObjectArray, &removed) < 0) return false;
    if (removed) |r| release(@as(*IObjectCollection, @ptrCast(@alignCast(r))));
    var committed = false;
    defer if (!committed) {
        _ = list.vtbl.AbortList(list);
    };

    const tasks = create(IObjectCollection, &CLSID_EnumerableObjectCollection, &IID_IObjectCollection) orelse return false;
    defer release(tasks);
    const link = newWindowLink(exe_z) orelse return false;
    defer release(link);
    if (tasks.vtbl.AddObject(tasks, link) < 0) return false;
    // An IObjectCollection is an IObjectArray.
    if (list.vtbl.AddUserTasks(list, tasks) < 0) return false;
    const hr = list.vtbl.CommitList(list);
    committed = hr >= 0;
    if (!committed) log.warn("committing the Jump List failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
    return committed;
}

/// Remove the Jump List of `app_id` (the unit test's).
fn deleteList(app_id: c.LPCWSTR) void {
    const list = create(ICustomDestinationList, &CLSID_DestinationList, &IID_ICustomDestinationList) orelse return;
    defer release(list);
    _ = list.vtbl.DeleteList(list, app_id);
}

fn newWindowLink(exe: c.LPCWSTR) ?*IShellLinkW {
    const link = create(IShellLinkW, &CLSID_ShellLink, &IID_IShellLinkW) orelse return null;
    if (link.vtbl.SetPath(link, exe) < 0 or
        link.vtbl.SetArguments(link, arguments) < 0 or
        link.vtbl.SetIconLocation(link, exe, 0) < 0 or
        link.vtbl.SetDescription(link, c.L("Open a new murrtty window")) < 0)
    {
        release(link);
        return null;
    }
    var store_ptr: ?*anyopaque = null;
    if (link.vtbl.unknown.QueryInterface(link, &IID_IPropertyStore, &store_ptr) < 0) {
        release(link);
        return null;
    }
    const store: *IPropertyStore = @ptrCast(@alignCast(store_ptr.?));
    defer release(store);
    // Copied by the store.
    const title: PROPVARIANT = .{ .vt = VT_LPWSTR, .value = .{ .pwszVal = c.L("New Window") } };
    if (store.vtbl.SetValue(store, &PKEY_Title, &title) < 0 or store.vtbl.Commit(store) < 0) {
        release(link);
        return null;
    }
    return link;
}

test "the New Window task" {
    const testing = std.testing;
    const co = c.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED);
    defer if (co >= 0) c.CoUninitialize();

    // The link holds what was set (the vtables' slots are right).
    var exe: [1024]u16 = undefined;
    const len = c.GetModuleFileNameW(null, &exe, exe.len);
    try testing.expect(len > 0 and len < exe.len);
    exe[len] = 0;
    const link = newWindowLink(@ptrCast(&exe)) orelse return error.TestUnexpectedResult;
    defer release(link);
    var buf: [1024]u16 = undefined;
    try testing.expect(link.vtbl.GetArguments(link, &buf, buf.len) >= 0);
    try testing.expectEqualSlices(u16, arguments, std.mem.sliceTo(&buf, 0));
    // SLGP_RAWPATH.
    try testing.expect(link.vtbl.GetPath(link, &buf, buf.len, null, 0x4) >= 0);
    try testing.expectEqualSlices(u16, exe[0..len], std.mem.sliceTo(&buf, 0));

    // A whole list, under an AppUserModelID of the test's own, then gone.
    // Windows may refuse lists where no shell runs (a service's session).
    const id = c.L("murrtty.unit-test.jump-list");
    if (!setUp(id)) return error.SkipZigTest;
    deleteList(id);
}
