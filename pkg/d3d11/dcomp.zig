//! DirectComposition (dcomp.h): a device, a target on a window and a
//! visual showing a composition swap chain, for per-pixel alpha (murrtty's
//! roadmap 4.1 and 7.8). dcomp.h's C vtables leave out the base slots and
//! its overloads are in MSVC's vtable order only in the non-MSVC branch
//! (the animation overload first), which these indices follow.
const std = @import("std");
const com = @import("com.zig");
const dxgi = @import("dxgi.zig");
const HRESULT = com.HRESULT;
const BOOL = com.BOOL;
const GUID = com.GUID;
const method = com.method;

pub extern "dcomp" fn DCompositionCreateDevice(dxgi_device: ?*dxgi.Device, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT;

/// IDCompositionDevice.
pub const Device = opaque {
    pub const iid = GUID.parse("c37ea93a-e7aa-450d-b16f-9746cb0407f3");

    pub fn create(dxgi_device: *dxgi.Device) ?*Device {
        var out: ?*anyopaque = null;
        if (!com.succeeded(DCompositionCreateDevice(dxgi_device, &iid, &out))) return null;
        return @ptrCast(@alignCast(out));
    }

    pub fn commit(self: *Device) HRESULT {
        return method(self, 3, fn (*Device) callconv(.winapi) HRESULT)(self);
    }

    pub fn createTargetForHwnd(self: *Device, hwnd: *anyopaque, topmost: bool, out: *?*Target) HRESULT {
        return method(self, 6, fn (*Device, *anyopaque, BOOL, *?*Target) callconv(.winapi) HRESULT)(self, hwnd, @intFromBool(topmost), out);
    }

    pub fn createVisual(self: *Device, out: *?*Visual) HRESULT {
        return method(self, 7, fn (*Device, *?*Visual) callconv(.winapi) HRESULT)(self, out);
    }

    /// Whether the device still works (false once the Direct3D device
    /// it was made on is lost).
    pub fn checkDeviceState(self: *Device) bool {
        var valid: BOOL = com.FALSE;
        const hr = method(self, 26, fn (*Device, *BOOL) callconv(.winapi) HRESULT)(self, &valid);
        return com.succeeded(hr) and valid != 0;
    }
};

/// IDCompositionTarget.
pub const Target = opaque {
    pub fn setRoot(self: *Target, visual: ?*Visual) HRESULT {
        return method(self, 3, fn (*Target, ?*Visual) callconv(.winapi) HRESULT)(self, visual);
    }
};

/// IDCompositionVisual.
pub const Visual = opaque {
    pub fn setOffsetX(self: *Visual, x: f32) HRESULT {
        return method(self, 4, fn (*Visual, f32) callconv(.winapi) HRESULT)(self, x);
    }

    pub fn setOffsetY(self: *Visual, y: f32) HRESULT {
        return method(self, 6, fn (*Visual, f32) callconv(.winapi) HRESULT)(self, y);
    }

    pub fn setContent(self: *Visual, content: ?*anyopaque) HRESULT {
        return method(self, 15, fn (*Visual, ?*anyopaque) callconv(.winapi) HRESULT)(self, content);
    }
};
