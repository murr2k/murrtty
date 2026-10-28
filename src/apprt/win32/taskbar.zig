//! The taskbar button's progress (roadmap 5.4): ITaskbarList3, which the
//! app creates once a window's button exists (TaskbarButtonCreated) and
//! every window shares.
const std = @import("std");

const c = @import("c.zig");

const log = std.log.scoped(.win32_taskbar);

/// What a window's taskbar button shows.
pub const Progress = struct {
    state: State = .none,
    /// 0 to 100.
    value: u8 = 0,

    pub const State = enum(u32) {
        none = 0,
        indeterminate = 1,
        normal = 2,
        @"error" = 4,
        paused = 8,
    };
};

const GUID = c.GUID;
const CLSID_TaskbarList = GUID.parse("{56fdf344-fd6d-11d0-958a-006097c9a090}");
const IID_ITaskbarList3 = GUID.parse("{ea1afb91-9e28-4b86-90e9-9e9f8a5eefaf}");

const HRESULT = c.HRESULT;
/// A vtable slot this file doesn't call.
const Unused = *const anyopaque;

pub const List = extern struct {
    vtbl: *const extern struct {
        QueryInterface: Unused,
        AddRef: Unused,
        Release: *const fn (*List) callconv(.winapi) u32,
        // ITaskbarList
        HrInit: *const fn (*List) callconv(.winapi) HRESULT,
        AddTab: Unused,
        DeleteTab: Unused,
        ActivateTab: Unused,
        SetActiveAlt: Unused,
        // ITaskbarList2
        MarkFullscreenWindow: Unused,
        // ITaskbarList3
        SetProgressValue: *const fn (*List, c.HWND, u64, u64) callconv(.winapi) HRESULT,
        SetProgressState: *const fn (*List, c.HWND, u32) callconv(.winapi) HRESULT,
    },

    /// The taskbar's list, or null where there is none (COM, Explorer).
    pub fn create() ?*List {
        var out: ?*anyopaque = null;
        const hr = c.CoCreateInstance(&CLSID_TaskbarList, null, c.CLSCTX_INPROC_SERVER, &IID_ITaskbarList3, &out);
        if (hr < 0) {
            log.warn("no taskbar progress: CoCreateInstance failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return null;
        }
        const self: *List = @ptrCast(@alignCast(out.?));
        if (self.vtbl.HrInit(self) < 0) {
            self.release();
            return null;
        }
        return self;
    }

    pub fn release(self: *List) void {
        _ = self.vtbl.Release(self);
    }

    /// Show `progress` on the button of the window `hwnd`. The result of
    /// setting its state.
    pub fn show(self: *List, hwnd: c.HWND, progress: Progress) HRESULT {
        const hr = self.vtbl.SetProgressState(self, hwnd, @intFromEnum(progress.state));
        switch (progress.state) {
            .none, .indeterminate => {},
            else => _ = self.vtbl.SetProgressValue(self, hwnd, progress.value, 100),
        }
        return hr;
    }
};
