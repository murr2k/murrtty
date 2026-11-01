//! Windows' folder dialog (roadmap F1e, the config editor's
//! working-directory picker): IFileOpenDialog with FOS_PICKFOLDERS, the
//! Explorer-style dialog the file dialog (GetOpenFileNameW, which has no
//! folder mode) matches. Hand-written vtables laid out to the slots used:
//! a wrong slot crashes, so the unit test calls each of them but Show.
//! COM is initialized on the UI thread (OleInitialize, for drops).
const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig");
const text_util = @import("text.zig");

const GUID = c.GUID;
const HRESULT = c.HRESULT;
const CLSID_FileOpenDialog = GUID.parse("{dc1c5a9c-e88a-4dde-a5a1-60f82a20aef7}");
const IID_IFileOpenDialog = GUID.parse("{d57c7288-d4ad-4768-be02-9d969532d960}");
const IID_IShellItem = GUID.parse("{43826d1e-e718-42ee-bc55-a1e261c37bfe}");

const FOS_PICKFOLDERS: u32 = 0x20;
const FOS_FORCEFILESYSTEM: u32 = 0x40;
const FOS_PATHMUSTEXIST: u32 = 0x800;
const SIGDN_FILESYSPATH: u32 = 0x80058000;

const Unknown = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
};
/// A vtable slot this file doesn't call.
const Unused = *const anyopaque;

const IShellItem = extern struct {
    vtbl: *const extern struct {
        unknown: Unknown,
        BindToHandler: Unused,
        GetParent: Unused,
        GetDisplayName: *const fn (*IShellItem, u32, *?[*:0]u16) callconv(.winapi) HRESULT,
        GetAttributes: Unused,
        Compare: Unused,
    },

    fn release(self: *IShellItem) void {
        _ = self.vtbl.unknown.Release(self);
    }

    /// Its path, or null (not a file system item). The caller owns it.
    fn path(self: *IShellItem, alloc: Allocator) ?[]u8 {
        var name: ?[*:0]u16 = null;
        if (self.vtbl.GetDisplayName(self, SIGDN_FILESYSPATH, &name) < 0) return null;
        const n = name orelse return null;
        defer c.CoTaskMemFree(n);
        return std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.sliceTo(n, 0)) catch null;
    }
};

/// IFileOpenDialog: IModalWindow's Show, then IFileDialog's methods, to
/// the last one used.
const IFileOpenDialog = extern struct {
    vtbl: *const extern struct {
        unknown: Unknown,
        Show: *const fn (*IFileOpenDialog, ?c.HWND) callconv(.winapi) HRESULT,
        SetFileTypes: Unused,
        SetFileTypeIndex: Unused,
        GetFileTypeIndex: Unused,
        Advise: Unused,
        Unadvise: Unused,
        SetOptions: *const fn (*IFileOpenDialog, u32) callconv(.winapi) HRESULT,
        GetOptions: *const fn (*IFileOpenDialog, *u32) callconv(.winapi) HRESULT,
        SetDefaultFolder: Unused,
        SetFolder: *const fn (*IFileOpenDialog, *IShellItem) callconv(.winapi) HRESULT,
        GetFolder: *const fn (*IFileOpenDialog, *?*IShellItem) callconv(.winapi) HRESULT,
        GetCurrentSelection: Unused,
        SetFileName: Unused,
        GetFileName: Unused,
        SetTitle: *const fn (*IFileOpenDialog, c.LPCWSTR) callconv(.winapi) HRESULT,
        SetOkButtonLabel: Unused,
        SetFileNameLabel: Unused,
        GetResult: *const fn (*IFileOpenDialog, *?*IShellItem) callconv(.winapi) HRESULT,
    },

    fn create() ?*IFileOpenDialog {
        var out: ?*anyopaque = null;
        if (c.CoCreateInstance(&CLSID_FileOpenDialog, null, c.CLSCTX_INPROC_SERVER, &IID_IFileOpenDialog, &out) < 0) return null;
        return @ptrCast(@alignCast(out orelse return null));
    }

    fn release(self: *IFileOpenDialog) void {
        _ = self.vtbl.unknown.Release(self);
    }

    /// Choose folders, of the file system, that exist.
    fn pickFolders(self: *IFileOpenDialog) void {
        var opts: u32 = 0;
        _ = self.vtbl.GetOptions(self, &opts);
        _ = self.vtbl.SetOptions(self, opts | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST);
    }

    /// Open in `dir`, if it is a folder.
    fn startIn(self: *IFileOpenDialog, alloc: Allocator, dir: []const u8) void {
        const wide = text_util.utf16Lossy(alloc, dir) catch return;
        defer alloc.free(wide);
        var item: ?*anyopaque = null;
        if (c.SHCreateItemFromParsingName(wide.ptr, null, &IID_IShellItem, &item) < 0) return;
        const it: *IShellItem = @ptrCast(@alignCast(item orelse return));
        defer it.release();
        _ = self.vtbl.SetFolder(self, it);
    }
};

/// The folder the user chooses, the dialog opening in `start` when it is
/// one; null if none is chosen or the dialog can't open. The caller owns
/// the result. Run it in a modal scope (App.beginModal): it runs a loop of
/// its own.
pub fn pickFolder(alloc: Allocator, owner: ?c.HWND, title: [:0]const u16, start: ?[]const u8) ?[]u8 {
    const dialog = IFileOpenDialog.create() orelse return null;
    defer dialog.release();
    dialog.pickFolders();
    _ = dialog.vtbl.SetTitle(dialog, title.ptr);
    if (start) |s| if (s.len > 0) dialog.startIn(alloc, s);
    // S_OK, or HRESULT_FROM_WIN32(ERROR_CANCELLED) when closed unchosen.
    if (dialog.vtbl.Show(dialog, owner) != 0) return null;
    var item: ?*IShellItem = null;
    if (dialog.vtbl.GetResult(dialog, &item) < 0) return null;
    const it = item orelse return null;
    defer it.release();
    return it.path(alloc);
}

test "file_dialog: every slot used but Show" {
    const alloc = std.testing.allocator;
    const init = c.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED);
    defer if (init >= 0) c.CoUninitialize();
    const dialog = IFileOpenDialog.create() orelse return error.SkipZigTest;
    defer dialog.release();

    dialog.pickFolders();
    var opts: u32 = 0;
    try std.testing.expect(dialog.vtbl.GetOptions(dialog, &opts) >= 0);
    try std.testing.expect(opts & FOS_PICKFOLDERS != 0);
    try std.testing.expect(dialog.vtbl.SetTitle(dialog, c.L("Choose a Folder").ptr) >= 0);

    // The folder it opens in comes back as it was set.
    var buf: [261]u16 = undefined;
    const n = c.GetSystemDirectoryW(&buf, buf.len);
    if (n == 0 or n >= buf.len) return error.SkipZigTest;
    const system = try std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..n]);
    defer alloc.free(system);
    dialog.startIn(alloc, system);
    var folder: ?*IShellItem = null;
    try std.testing.expect(dialog.vtbl.GetFolder(dialog, &folder) >= 0);
    const f = folder orelse return error.TestUnexpectedResult;
    defer f.release();
    const got = f.path(alloc) orelse return error.TestUnexpectedResult;
    defer alloc.free(got);
    try std.testing.expect(std.ascii.eqlIgnoreCase(got, system));

    // Nothing chosen before it was shown.
    var result: ?*IShellItem = null;
    try std.testing.expect(dialog.vtbl.GetResult(dialog, &result) < 0);
    if (result) |r| r.release();
}
