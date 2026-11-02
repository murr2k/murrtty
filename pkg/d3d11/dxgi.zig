//! DXGI (dxgi.h, dxgi1_2.h, dxgi1_3.h): the factory, adapters, the
//! device's DXGI side and swap chains, as murrtty's Direct3D 11 renderer
//! uses them. Slot indices from mingw-w64's `...Vtbl` structs.
const std = @import("std");
const com = @import("com.zig");
const HRESULT = com.HRESULT;
const BOOL = com.BOOL;
const GUID = com.GUID;
const method = com.method;

pub const Format = enum(u32) {
    unknown = 0x0,
    r32g32b32a32_float = 0x2,
    r32g32_float = 0x10,
    r32g32_uint = 0x11,
    r8g8b8a8_typeless = 0x1b,
    r8g8b8a8_unorm = 0x1c,
    r8g8b8a8_unorm_srgb = 0x1d,
    r8g8b8a8_uint = 0x1e,
    r16g16_uint = 0x24,
    r16g16_sint = 0x26,
    r32_float = 0x29,
    r32_uint = 0x2a,
    r8_unorm = 0x3d,
    r8_uint = 0x3e,
    b8g8r8a8_unorm = 0x57,
    b8g8r8a8_typeless = 0x5a,
    b8g8r8a8_unorm_srgb = 0x5b,
    _,
};

pub const SampleDesc = extern struct {
    Count: u32 = 1,
    Quality: u32 = 0,
};

pub const Scaling = enum(u32) { stretch = 0, none = 1, aspect_ratio_stretch = 2 };
pub const SwapEffect = enum(u32) { discard = 0, sequential = 1, flip_sequential = 3, flip_discard = 4 };
pub const AlphaMode = enum(u32) { unspecified = 0, premultiplied = 1, straight = 2, ignore = 3 };

pub const USAGE_RENDER_TARGET_OUTPUT: u32 = 0x20;
pub const SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT: u32 = 64;

pub const SwapChainDesc1 = extern struct {
    Width: u32,
    Height: u32,
    Format: Format,
    Stereo: BOOL = com.FALSE,
    SampleDesc: SampleDesc = .{},
    BufferUsage: u32 = USAGE_RENDER_TARGET_OUTPUT,
    BufferCount: u32,
    Scaling: Scaling,
    SwapEffect: SwapEffect,
    AlphaMode: AlphaMode,
    Flags: u32 = 0,
};

pub const Luid = extern struct { LowPart: u32, HighPart: i32 };

pub const AdapterDesc1 = extern struct {
    Description: [128]u16,
    VendorId: u32,
    DeviceId: u32,
    SubSysId: u32,
    Revision: u32,
    DedicatedVideoMemory: usize,
    DedicatedSystemMemory: usize,
    SharedSystemMemory: usize,
    AdapterLuid: Luid,
    Flags: u32,
};

/// DXGI_ADAPTER_FLAG_SOFTWARE: WARP, or Microsoft's Basic Render Driver.
pub const ADAPTER_FLAG_SOFTWARE: u32 = 2;

pub const ERROR_DEVICE_REMOVED: HRESULT = @bitCast(@as(u32, 0x887A0005));
pub const ERROR_DEVICE_HUNG: HRESULT = @bitCast(@as(u32, 0x887A0006));
pub const ERROR_DEVICE_RESET: HRESULT = @bitCast(@as(u32, 0x887A0007));
pub const ERROR_DRIVER_INTERNAL_ERROR: HRESULT = @bitCast(@as(u32, 0x887A0020));
pub const ERROR_NOT_FOUND: HRESULT = @bitCast(@as(u32, 0x887A0002));
pub const ERROR_INVALID_CALL: HRESULT = @bitCast(@as(u32, 0x887A0001));
pub const STATUS_OCCLUDED: HRESULT = 0x087A0001;

/// Whether `hr` says the device is gone (DXGI_ERROR_DEVICE_*).
pub fn deviceLost(hr: HRESULT) bool {
    return hr == ERROR_DEVICE_REMOVED or hr == ERROR_DEVICE_HUNG or
        hr == ERROR_DEVICE_RESET or hr == ERROR_DRIVER_INTERNAL_ERROR;
}

/// IDXGIObject's GetParent (slot 6), shared by every DXGI interface.
fn getParent(obj: anytype, comptime Out: type) ?*Out {
    const T = @typeInfo(@TypeOf(obj)).pointer.child;
    var out: ?*anyopaque = null;
    const hr = method(obj, 6, fn (*T, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT)(obj, &Out.iid, &out);
    if (!com.succeeded(hr)) return null;
    return @ptrCast(@alignCast(out));
}

/// IDXGIDevice: the DXGI side of a Direct3D device.
pub const Device = opaque {
    pub const iid = GUID.parse("54ec77fa-1377-44e6-8c32-88fd5f44c84c");

    pub fn getAdapter(self: *Device) ?*Adapter1 {
        var out: ?*Adapter = null;
        const hr = method(self, 7, fn (*Device, *?*Adapter) callconv(.winapi) HRESULT)(self, &out);
        if (!com.succeeded(hr)) return null;
        const adapter = out orelse return null;
        defer com.release(adapter);
        return com.query(adapter, Adapter1);
    }
};

/// IDXGIAdapter (only as GetAdapter's result).
pub const Adapter = opaque {
    pub const iid = GUID.parse("2411e7e1-12ac-4ccf-bd14-9798e8534dc0");
};

/// IDXGIAdapter1.
pub const Adapter1 = opaque {
    pub const iid = GUID.parse("29038f61-3839-4626-91fd-086879011a05");

    pub fn getParentFactory(self: *Adapter1) ?*Factory2 {
        return getParent(self, Factory2);
    }

    pub fn getDesc1(self: *Adapter1, desc: *AdapterDesc1) HRESULT {
        return method(self, 10, fn (*Adapter1, *AdapterDesc1) callconv(.winapi) HRESULT)(self, desc);
    }
};

/// IDXGIFactory2.
pub const Factory2 = opaque {
    pub const iid = GUID.parse("50c83a1c-e072-4c48-87b0-3630fa36a6d0");

    pub fn enumAdapters1(self: *Factory2, index: u32) ?*Adapter1 {
        var out: ?*Adapter1 = null;
        const hr = method(self, 12, fn (*Factory2, u32, *?*Adapter1) callconv(.winapi) HRESULT)(self, index, &out);
        if (!com.succeeded(hr)) return null;
        return out;
    }

    /// False once adapters were added or removed (a driver update, a
    /// removed card): a lost device's replacement asks a new factory.
    pub fn isCurrent(self: *Factory2) bool {
        return method(self, 13, fn (*Factory2) callconv(.winapi) BOOL)(self) != 0;
    }

    pub fn createSwapChainForHwnd(self: *Factory2, device: *anyopaque, hwnd: *anyopaque, desc: *const SwapChainDesc1, out: *?*SwapChain1) HRESULT {
        return method(self, 15, fn (*Factory2, *anyopaque, *anyopaque, *const SwapChainDesc1, ?*const anyopaque, ?*anyopaque, *?*SwapChain1) callconv(.winapi) HRESULT)(self, device, hwnd, desc, null, null, out);
    }

    pub fn createSwapChainForComposition(self: *Factory2, device: *anyopaque, desc: *const SwapChainDesc1, out: *?*SwapChain1) HRESULT {
        return method(self, 24, fn (*Factory2, *anyopaque, *const SwapChainDesc1, ?*anyopaque, *?*SwapChain1) callconv(.winapi) HRESULT)(self, device, desc, null, out);
    }
};

pub extern "dxgi" fn CreateDXGIFactory2(flags: u32, iid: *const GUID, factory: *?*anyopaque) callconv(.winapi) HRESULT;

/// A new factory (`IsCurrent` stays true until adapters change).
pub fn createFactory() ?*Factory2 {
    var out: ?*anyopaque = null;
    if (!com.succeeded(CreateDXGIFactory2(0, &Factory2.iid, &out))) return null;
    return @ptrCast(@alignCast(out));
}

/// IDXGISwapChain1.
pub const SwapChain1 = opaque {
    pub const iid = GUID.parse("790a45f7-0d42-4876-983a-0a55cfe6f4aa");

    pub fn present(self: *SwapChain1, sync_interval: u32, flags: u32) HRESULT {
        return method(self, 8, fn (*SwapChain1, u32, u32) callconv(.winapi) HRESULT)(self, sync_interval, flags);
    }

    /// Buffer `index` as `Out` (ID3D11Texture2D).
    pub fn getBuffer(self: *SwapChain1, index: u32, comptime Out: type) ?*Out {
        var out: ?*anyopaque = null;
        const hr = method(self, 9, fn (*SwapChain1, u32, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT)(self, index, &Out.iid, &out);
        if (!com.succeeded(hr)) return null;
        return @ptrCast(@alignCast(out));
    }

    pub fn resizeBuffers(self: *SwapChain1, count: u32, width: u32, height: u32, format: Format, flags: u32) HRESULT {
        return method(self, 13, fn (*SwapChain1, u32, u32, u32, Format, u32) callconv(.winapi) HRESULT)(self, count, width, height, format, flags);
    }

    pub fn getDesc1(self: *SwapChain1, desc: *SwapChainDesc1) HRESULT {
        return method(self, 18, fn (*SwapChain1, *SwapChainDesc1) callconv(.winapi) HRESULT)(self, desc);
    }
};

/// IDXGISwapChain2: the frame-latency waitable object.
pub const SwapChain2 = opaque {
    pub const iid = GUID.parse("a8be2ac4-199f-4946-b331-79599fb98de7");

    pub fn setMaximumFrameLatency(self: *SwapChain2, latency: u32) HRESULT {
        return method(self, 31, fn (*SwapChain2, u32) callconv(.winapi) HRESULT)(self, latency);
    }

    /// The handle to wait on before each frame; the caller closes it.
    pub fn getFrameLatencyWaitableObject(self: *SwapChain2) ?*anyopaque {
        return method(self, 33, fn (*SwapChain2) callconv(.winapi) ?*anyopaque)(self);
    }
};

test "layouts" {
    if (@sizeOf(usize) == 8) {
        try std.testing.expectEqual(48, @sizeOf(SwapChainDesc1));
        try std.testing.expectEqual(312, @sizeOf(AdapterDesc1));
        try std.testing.expectEqual(272, @offsetOf(AdapterDesc1, "DedicatedVideoMemory"));
        try std.testing.expectEqual(296, @offsetOf(AdapterDesc1, "AdapterLuid"));
        try std.testing.expectEqual(304, @offsetOf(AdapterDesc1, "Flags"));
        try std.testing.expectEqual(40, @offsetOf(SwapChainDesc1, "AlphaMode"));
    }
}
