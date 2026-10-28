//! Dropping onto a pane (roadmap 5.8): an OLE drop target on each pane's
//! window. Files (from Explorer) paste as their paths, separated by spaces
//! and quoted for the pane's shell where it would split or expand them:
//! single quotes for PowerShell (and anything else), in which nothing
//! expands, double quotes for cmd; text pastes as it is. Both go through
//! the core's paste, as a paste from the clipboard does (bracketed paste,
//! paste protection). Windows' drag and drop doesn't cross integrity
//! levels: Explorer can't drop onto an elevated murrtty.
const DropTarget = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("c.zig");
const Surface = @import("Surface.zig");

const log = std.log.scoped(.win32_drop);

const GUID = c.GUID;
const IID_IUnknown = GUID.parse("{00000000-0000-0000-c000-000000000046}");
const IID_IDropTarget = GUID.parse("{00000122-0000-0000-c000-000000000046}");

const HRESULT = c.HRESULT;
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
const DROPEFFECT_NONE: c.DWORD = 0;
const DROPEFFECT_COPY: c.DWORD = 1;
const CF_HDROP: u16 = 15;
const DVASPECT_CONTENT: c.DWORD = 1;
const TYMED_HGLOBAL: c.DWORD = 1;

/// IDropTarget: the vtable first, as COM lays an object out.
vtbl: *const VTable = &vtable,
refs: std.atomic.Value(u32) = .init(1),
alloc: Allocator,
/// The pane it drops on; null once the pane revoked it (OLE may hold a
/// reference a little longer).
surface: ?*Surface,
/// What DragEnter found the drag to hold.
kind: Kind = .none,

const Kind = enum { none, files, text };

/// How a pane's shell reads a quoted path.
pub const Shell = enum { cmd, powershell };

comptime {
    // COM finds the vtable at the object's start.
    std.debug.assert(@offsetOf(DropTarget, "vtbl") == 0);
}

const VTable = extern struct {
    QueryInterface: *const fn (*DropTarget, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*DropTarget) callconv(.winapi) u32,
    Release: *const fn (*DropTarget) callconv(.winapi) u32,
    DragEnter: *const fn (*DropTarget, *DataObject, c.DWORD, c.POINTL, *c.DWORD) callconv(.winapi) HRESULT,
    DragOver: *const fn (*DropTarget, c.DWORD, c.POINTL, *c.DWORD) callconv(.winapi) HRESULT,
    DragLeave: *const fn (*DropTarget) callconv(.winapi) HRESULT,
    Drop: *const fn (*DropTarget, *DataObject, c.DWORD, c.POINTL, *c.DWORD) callconv(.winapi) HRESULT,
};

const vtable: VTable = .{
    .QueryInterface = &queryInterface,
    .AddRef = &addRef,
    .Release = &release,
    .DragEnter = &dragEnter,
    .DragOver = &dragOver,
    .DragLeave = &dragLeave,
    .Drop = &drop,
};

/// IDataObject, the slots called here.
pub const DataObject = extern struct {
    vtbl: *const extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*DataObject) callconv(.winapi) u32,
        GetData: *const fn (*DataObject, *const c.FORMATETC, *c.STGMEDIUM) callconv(.winapi) HRESULT,
        GetDataHere: *const anyopaque,
        QueryGetData: *const fn (*DataObject, *const c.FORMATETC) callconv(.winapi) HRESULT,
    },

    pub fn release(self: *DataObject) void {
        _ = self.vtbl.Release(self);
    }

    fn has(self: *DataObject, format: u16) bool {
        const fe = formatOf(format);
        return self.vtbl.QueryGetData(self, &fe) == c.S_OK;
    }
};

fn formatOf(format: u16) c.FORMATETC {
    return .{ .cfFormat = format, .ptd = null, .dwAspect = DVASPECT_CONTENT, .lindex = -1, .tymed = TYMED_HGLOBAL };
}

/// Make `surface`'s window a drop target. Null if Windows refuses (no OLE).
pub fn register(alloc: Allocator, surface: *Surface) ?*DropTarget {
    const self = alloc.create(DropTarget) catch return null;
    self.* = .{ .alloc = alloc, .surface = surface };
    const hr = c.RegisterDragDrop(surface.hwnd, @ptrCast(self));
    if (hr < 0) {
        log.warn("no drag and drop: RegisterDragDrop failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
        alloc.destroy(self);
        return null;
    }
    return self;
}

/// Stop taking drops on `hwnd` and let go of murrtty's reference.
pub fn revoke(self: *DropTarget, hwnd: c.HWND) void {
    _ = c.RevokeDragDrop(hwnd);
    self.surface = null;
    _ = release(self);
}

fn queryInterface(self: *DropTarget, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
    if (std.meta.eql(iid.*, IID_IUnknown) or std.meta.eql(iid.*, IID_IDropTarget)) {
        _ = addRef(self);
        out.* = self;
        return c.S_OK;
    }
    out.* = null;
    return E_NOINTERFACE;
}

fn addRef(self: *DropTarget) callconv(.winapi) u32 {
    return self.refs.fetchAdd(1, .monotonic) + 1;
}

fn release(self: *DropTarget) callconv(.winapi) u32 {
    const left = self.refs.fetchSub(1, .acq_rel) - 1;
    if (left == 0) self.alloc.destroy(self);
    return left;
}

/// The drag holds files or text: a copy, if the source allows one.
fn dragEnter(self: *DropTarget, data: *DataObject, _: c.DWORD, _: c.POINTL, effect: *c.DWORD) callconv(.winapi) HRESULT {
    self.kind = if (self.surface == null) .none else if (data.has(CF_HDROP)) .files else if (data.has(c.CF_UNICODETEXT)) .text else .none;
    effect.* = self.effectFor(effect.*);
    return c.S_OK;
}

fn dragOver(self: *DropTarget, _: c.DWORD, _: c.POINTL, effect: *c.DWORD) callconv(.winapi) HRESULT {
    effect.* = self.effectFor(effect.*);
    return c.S_OK;
}

fn dragLeave(self: *DropTarget) callconv(.winapi) HRESULT {
    self.kind = .none;
    return c.S_OK;
}

fn drop(self: *DropTarget, data: *DataObject, _: c.DWORD, _: c.POINTL, effect: *c.DWORD) callconv(.winapi) HRESULT {
    effect.* = self.effectFor(effect.*);
    const kind = self.kind;
    self.kind = .none;
    if (effect.* == DROPEFFECT_NONE or self.surface == null) return c.S_OK;
    const shell: Shell = if (self.surface.?.shellIsCmd()) .cmd else .powershell;
    const text = textOf(self.alloc, data, kind, shell) catch |err| {
        log.warn("the drop couldn't be read err={}", .{err});
        effect.* = DROPEFFECT_NONE;
        return c.S_OK;
    } orelse {
        effect.* = DROPEFFECT_NONE;
        return c.S_OK;
    };
    defer self.alloc.free(text);
    // After GetData, a call out to the source: its wait can run messages.
    const surface = self.surface orelse return c.S_OK;
    surface.pasteText(text);
    return c.S_OK;
}

/// The GUI tests' drop (test_hooks): DragEnter, then Drop, of `data` with a
/// copy allowed, as a drag and drop would bring it; the effect.
pub fn simulate(self: *DropTarget, data: *DataObject) c.DWORD {
    // Through the vtable, as OLE calls.
    var effect: c.DWORD = DROPEFFECT_COPY;
    _ = self.vtbl.DragEnter(self, data, 0, .{}, &effect);
    if (effect == DROPEFFECT_NONE) return effect;
    effect = DROPEFFECT_COPY;
    _ = self.vtbl.Drop(self, data, 0, .{}, &effect);
    return effect;
}

fn effectFor(self: *const DropTarget, allowed: c.DWORD) c.DWORD {
    if (self.kind == .none or allowed & DROPEFFECT_COPY == 0) return DROPEFFECT_NONE;
    return DROPEFFECT_COPY;
}

/// The text a drop pastes: its files' paths, or its text.
fn textOf(alloc: Allocator, data: *DataObject, kind: Kind, shell: Shell) !?[]u8 {
    const format: u16 = switch (kind) {
        .none => return null,
        .files => CF_HDROP,
        .text => c.CF_UNICODETEXT,
    };
    const fe = formatOf(format);
    var medium: c.STGMEDIUM = .{};
    if (data.vtbl.GetData(data, &fe, &medium) < 0) return null;
    defer c.ReleaseStgMedium(&medium);
    if (medium.tymed != TYMED_HGLOBAL) return null;
    const global = medium.hGlobal orelse return null;
    const p = c.GlobalLock(global) orelse return null;
    defer _ = c.GlobalUnlock(global);
    return switch (kind) {
        .none => null,
        .files => try filesText(alloc, @ptrCast(p), shell),
        .text => text: {
            const units: [*]const u16 = @ptrCast(@alignCast(p));
            const max = c.GlobalSize(global) / 2;
            const len = std.mem.indexOfScalar(u16, units[0..max], 0) orelse max;
            if (len == 0) break :text null;
            break :text try std.unicode.wtf16LeToWtf8Alloc(alloc, units[0..len]);
        },
    };
}

/// A CF_HDROP's paths, quoted as needed and separated by spaces.
fn filesText(alloc: Allocator, hdrop: *anyopaque, shell: Shell) !?[]u8 {
    const count = c.DragQueryFileW(hdrop, 0xFFFFFFFF, null, 0);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var buf: std.ArrayList(u16) = .empty;
    defer buf.deinit(alloc);
    for (0..count) |i| {
        const len = c.DragQueryFileW(hdrop, @intCast(i), null, 0);
        if (len == 0) continue;
        try buf.resize(alloc, len + 1);
        if (c.DragQueryFileW(hdrop, @intCast(i), buf.items.ptr, len + 1) == 0) continue;
        const path = try std.unicode.wtf16LeToWtf8Alloc(alloc, buf.items[0..len]);
        defer alloc.free(path);
        if (out.items.len > 0) try out.append(alloc, ' ');
        try appendPath(alloc, &out, path, shell);
    }
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(alloc);
}

/// `path`, quoted for `shell` where it would split or expand it.
/// PowerShell: in single quotes, where nothing expands, its single quotes
/// (and the typographic ones, U+2018 to U+201B, which PowerShell takes as
/// single quotes too) doubled; any character beyond letters, digits and
/// `\/:._-` quotes. cmd: in double quotes, which a Windows path never
/// holds, for spaces and cmd's metacharacters (`%` still expands there, as
/// cmd has no escape for it inside quotes).
pub fn appendPath(alloc: Allocator, out: *std.ArrayList(u8), path: []const u8, shell: Shell) !void {
    switch (shell) {
        .cmd => {
            const quote = for (path) |ch| {
                if (std.mem.indexOfScalar(u8, " \t&()[]{}^=;!'+,`~$@#", ch) != null) break true;
            } else false;
            if (quote) try out.append(alloc, '"');
            try out.appendSlice(alloc, path);
            if (quote) try out.append(alloc, '"');
        },
        .powershell => {
            const quote = for (path) |ch| {
                if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "\\/:._-", ch) == null) break true;
            } else false;
            if (!quote) return out.appendSlice(alloc, path);
            try out.append(alloc, '\'');
            var i: usize = 0;
            while (i < path.len) {
                // U+2018..U+201B: E2 80 98..9B.
                const typographic = i + 2 < path.len and path[i] == 0xE2 and path[i + 1] == 0x80 and
                    path[i + 2] >= 0x98 and path[i + 2] <= 0x9B;
                const n: usize = if (typographic) 3 else 1;
                const unit = path[i .. i + n];
                try out.appendSlice(alloc, unit);
                if (typographic or path[i] == '\'') try out.appendSlice(alloc, unit);
                i += n;
            }
            try out.append(alloc, '\'');
        },
    }
}

test "appendPath quotes for the pane's shell" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const cases = [_]struct { Shell, []const u8, []const u8 }{
        .{ .cmd, "C:\\Users\\me\\notes.txt", "C:\\Users\\me\\notes.txt" },
        .{ .cmd, "C:\\Program Files\\app", "\"C:\\Program Files\\app\"" },
        .{ .cmd, "D:\\a&b", "\"D:\\a&b\"" },
        .{ .cmd, "\\\\server\\share\\x(1).log", "\"\\\\server\\share\\x(1).log\"" },
        .{ .powershell, "C:\\Users\\me\\notes.txt", "C:\\Users\\me\\notes.txt" },
        .{ .powershell, "C:\\Program Files\\app", "'C:\\Program Files\\app'" },
        // Nothing expands in single quotes.
        .{ .powershell, "D:\\a$(Remove-Item x).txt", "'D:\\a$(Remove-Item x).txt'" },
        .{ .powershell, "D:\\$HOME`n", "'D:\\$HOME`n'" },
        // Single quotes, typographic ones too, doubled.
        .{ .powershell, "D:\\it's", "'D:\\it''s'" },
        .{ .powershell, "D:\\it\u{2019}s", "'D:\\it\u{2019}\u{2019}s'" },
    };
    for (cases) |case| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try appendPath(alloc, &out, case[1], case[0]);
        try testing.expectEqualStrings(case[2], out.items);
    }
}
