//! COM basics for the Direct3D 11, DXGI and DirectComposition bindings
//! (murrtty's roadmap 7.8): interfaces are opaque types whose methods call
//! their vtable slot by index. The indices come from mingw-w64's headers
//! (the C `...Vtbl` structs for d3d11.h and dxgi*.h; dcomp.h's non-MSVC
//! C++ branch, the layout MSVC gives overloads). A wrong index calls the
//! wrong method, so each binding's unit test calls every method bound.
const std = @import("std");

pub const HRESULT = i32;
pub const BOOL = i32;
pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;

pub const GUID = extern struct {
    a: u32,
    b: u16,
    c: u16,
    d: [8]u8,

    /// "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx", at compile time.
    pub fn parse(comptime s: []const u8) GUID {
        return comptime blk: {
            if (s.len != 36) @compileError("a GUID is 36 characters");
            var d: [8]u8 = undefined;
            d[0] = std.fmt.parseInt(u8, s[19..21], 16) catch unreachable;
            d[1] = std.fmt.parseInt(u8, s[21..23], 16) catch unreachable;
            for (0..6) |i| d[2 + i] = std.fmt.parseInt(u8, s[24 + 2 * i ..][0..2], 16) catch unreachable;
            break :blk .{
                .a = std.fmt.parseInt(u32, s[0..8], 16) catch unreachable,
                .b = std.fmt.parseInt(u16, s[9..13], 16) catch unreachable,
                .c = std.fmt.parseInt(u16, s[14..18], 16) catch unreachable,
                .d = d,
            };
        };
    }
};

pub const IID_IUnknown = GUID.parse("00000000-0000-0000-c000-000000000046");

pub const E_FAIL: HRESULT = @bitCast(@as(u32, 0x80004005));
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
pub const E_INVALIDARG: HRESULT = @bitCast(@as(u32, 0x80070057));

pub inline fn succeeded(hr: HRESULT) bool {
    return hr >= 0;
}

/// The function in `obj`'s vtable slot `index`, as type `F`.
pub inline fn method(obj: anytype, comptime index: usize, comptime F: type) *const F {
    const vtable: *const *const [index + 1]?*const anyopaque = @ptrCast(@alignCast(obj));
    return @ptrCast(vtable.*[index].?);
}

/// IUnknown's three, for any interface.
pub fn release(obj: anytype) void {
    const T = @typeInfo(@TypeOf(obj)).pointer.child;
    _ = method(obj, 2, fn (*T) callconv(.winapi) u32)(obj);
}

pub fn addRef(obj: anytype) void {
    const T = @typeInfo(@TypeOf(obj)).pointer.child;
    _ = method(obj, 1, fn (*T) callconv(.winapi) u32)(obj);
}

/// QueryInterface for `Out`, whose `iid` names it.
pub fn query(obj: anytype, comptime Out: type) ?*Out {
    const T = @typeInfo(@TypeOf(obj)).pointer.child;
    var out: ?*anyopaque = null;
    const hr = method(obj, 0, fn (*T, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT)(obj, &Out.iid, &out);
    if (!succeeded(hr)) return null;
    return @ptrCast(@alignCast(out));
}

/// An HRESULT as an error, keeping the code for the caller to log.
pub const Failure = struct {
    hr: HRESULT,

    pub fn format(self: Failure, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("0x{x:0>8}", .{@as(u32, @bitCast(self.hr))});
    }
};

pub fn hex(hr: HRESULT) Failure {
    return .{ .hr = hr };
}

test "GUID.parse" {
    const g = GUID.parse("54ec77fa-1377-44e6-8c32-88fd5f44c84c");
    try std.testing.expectEqual(@as(u32, 0x54ec77fa), g.a);
    try std.testing.expectEqual(@as(u16, 0x1377), g.b);
    try std.testing.expectEqual(@as(u16, 0x44e6), g.c);
    try std.testing.expectEqualSlices(u8, &.{ 0x8c, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c }, &g.d);
}
