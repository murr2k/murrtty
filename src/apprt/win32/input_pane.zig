//! The touch keyboard (roadmap 6.5, `show_on_screen_keyboard`): Windows'
//! InputPane for a window, through IInputPaneInterop, as GTK asks its
//! input method for the on-screen keyboard. A WinRT class, so its factory
//! comes from RoGetActivationFactory (the UI thread's OLE apartment does).
const std = @import("std");

const c = @import("c.zig");

const GUID = c.GUID;
const HRESULT = c.HRESULT;
const IID_IInputPaneInterop = GUID.parse("{75cf2c57-9195-4931-8332-f0b409e916af}");
const IID_IInputPane2 = GUID.parse("{8a6b3f26-7090-4793-944c-c3f2cde26276}");
const class_name = std.unicode.utf8ToUtf16LeStringLiteral("Windows.UI.ViewManagement.InputPane");

/// A vtable slot this file doesn't call.
const Unused = *const anyopaque;

const HSTRING = ?*opaque {};
extern "api-ms-win-core-winrt-string-l1-1-0" fn WindowsCreateString([*]const u16, u32, *HSTRING) callconv(.winapi) HRESULT;
extern "api-ms-win-core-winrt-string-l1-1-0" fn WindowsDeleteString(HSTRING) callconv(.winapi) HRESULT;
extern "api-ms-win-core-winrt-l1-1-0" fn RoGetActivationFactory(HSTRING, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT;

const Interop = extern struct {
    vtbl: *const extern struct {
        QueryInterface: Unused,
        AddRef: Unused,
        Release: *const fn (*Interop) callconv(.winapi) u32,
        // IInspectable
        GetIids: Unused,
        GetRuntimeClassName: Unused,
        GetTrustLevel: Unused,
        // IInputPaneInterop
        GetForWindow: *const fn (*Interop, c.HWND, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    },
};

const Pane = extern struct {
    vtbl: *const extern struct {
        QueryInterface: Unused,
        AddRef: Unused,
        Release: *const fn (*Pane) callconv(.winapi) u32,
        // IInspectable
        GetIids: Unused,
        GetRuntimeClassName: Unused,
        GetTrustLevel: Unused,
        // IInputPane2 (WinRT's boolean is a byte)
        TryShow: *const fn (*Pane, *u8) callconv(.winapi) HRESULT,
        TryHide: *const fn (*Pane, *u8) callconv(.winapi) HRESULT,
    },
};

pub const Ask = enum {
    show,
    hide,
    /// Only get the window's pane: the test hooks' stand-in for showing.
    none,
};

pub const Result = struct {
    /// The first failure, or what TryShow or TryHide returned.
    hr: HRESULT,
    /// Windows did it. TryShow declines while the settings say to show
    /// the touch keyboard only without a hardware one, as here.
    done: bool = false,
};

/// Ask Windows to show or hide the touch keyboard for the top-level window
/// `hwnd`.
pub fn request(hwnd: c.HWND, ask: Ask) Result {
    var name: HSTRING = null;
    var hr = WindowsCreateString(class_name, class_name.len, &name);
    if (hr < 0) return .{ .hr = hr };
    defer _ = WindowsDeleteString(name);

    var factory: ?*anyopaque = null;
    hr = RoGetActivationFactory(name, &IID_IInputPaneInterop, &factory);
    if (hr < 0) return .{ .hr = hr };
    const interop: *Interop = @ptrCast(@alignCast(factory.?));
    defer _ = interop.vtbl.Release(interop);

    var out: ?*anyopaque = null;
    hr = interop.vtbl.GetForWindow(interop, hwnd, &IID_IInputPane2, &out);
    if (hr < 0) return .{ .hr = hr };
    const pane: *Pane = @ptrCast(@alignCast(out.?));
    defer _ = pane.vtbl.Release(pane);

    var done: u8 = 0;
    hr = switch (ask) {
        .show => pane.vtbl.TryShow(pane, &done),
        .hide => pane.vtbl.TryHide(pane, &done),
        .none => 0,
    };
    return .{ .hr = hr, .done = hr >= 0 and done != 0 };
}
