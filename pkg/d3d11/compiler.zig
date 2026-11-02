//! HLSL to DXBC with System32's d3dcompiler_47.dll (in Windows since 8.1),
//! loaded by full path the first time it is needed: it isn't a KnownDLL,
//! so importing it would search the executable's folder first, and only
//! custom shaders, the inspector and the build's shader tool need it.
const std = @import("std");
const com = @import("com.zig");
const HRESULT = com.HRESULT;
const method = com.method;

/// ID3DBlob (ID3D10Blob).
pub const Blob = opaque {
    pub fn bytes(self: *Blob) []const u8 {
        const ptr = method(self, 3, fn (*Blob) callconv(.winapi) ?[*]const u8)(self);
        const len = method(self, 4, fn (*Blob) callconv(.winapi) usize)(self);
        return if (ptr) |p| p[0..len] else &.{};
    }
};

const D3DCompileFn = fn (
    src: [*]const u8,
    src_len: usize,
    name: ?[*:0]const u8,
    defines: ?*const anyopaque,
    include: ?*anyopaque,
    entry: [*:0]const u8,
    target: [*:0]const u8,
    flags1: u32,
    flags2: u32,
    code: *?*Blob,
    errors: ?*?*Blob,
) callconv(.winapi) HRESULT;

pub const OPTIMIZATION_LEVEL3: u32 = 1 << 15;
pub const ENABLE_STRICTNESS: u32 = 1 << 11;
pub const WARNINGS_ARE_ERRORS: u32 = 1 << 18;

extern "kernel32" fn GetSystemDirectoryW(buf: [*]u16, len: u32) callconv(.winapi) u32;
extern "kernel32" fn LoadLibraryExW(name: [*:0]const u16, file: ?*anyopaque, flags: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
const LOAD_LIBRARY_SEARCH_SYSTEM32: u32 = 0x800;
const LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR: u32 = 0x100;

var loaded: std.atomic.Value(?*const D3DCompileFn) = .init(null);

/// D3DCompile from System32's d3dcompiler_47.dll, loaded once. Two
/// threads racing here both load it and store the same function: no lock.
pub fn compileFn() ?*const D3DCompileFn {
    if (loaded.load(.acquire)) |f| return f;
    var buf: [300]u16 = undefined;
    const n = GetSystemDirectoryW(&buf, buf.len);
    const name = std.unicode.utf8ToUtf16LeStringLiteral("\\d3dcompiler_47.dll");
    if (n == 0 or n + name.len + 1 > buf.len) return null;
    @memcpy(buf[n..][0..name.len], name);
    buf[n + name.len] = 0;
    const module = LoadLibraryExW(@ptrCast(&buf), null, LOAD_LIBRARY_SEARCH_SYSTEM32 | LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR) orelse return null;
    const proc = GetProcAddress(module, "D3DCompile") orelse return null;
    const f: *const D3DCompileFn = @ptrCast(@alignCast(proc));
    loaded.store(f, .release);
    return f;
}

pub const Compiled = struct {
    code: *Blob,

    pub fn bytes(self: Compiled) []const u8 {
        return self.code.bytes();
    }

    pub fn deinit(self: Compiled) void {
        com.release(self.code);
    }
};

/// Compile `source` (HLSL) at `entry` for `target` ("vs_5_0", "ps_5_0").
/// On failure the compiler's messages, if any, are logged through `log`.
pub fn compile(source: []const u8, name: [:0]const u8, entry: [:0]const u8, target: [:0]const u8, flags: u32, messages: ?*std.ArrayList(u8), alloc: std.mem.Allocator) !Compiled {
    const f = compileFn() orelse return error.NoCompiler;
    var code: ?*Blob = null;
    var errors: ?*Blob = null;
    const hr = f(source.ptr, source.len, name.ptr, null, null, entry.ptr, target.ptr, flags, 0, &code, &errors);
    defer if (errors) |e| com.release(e);
    if (errors) |e| if (messages) |m| try m.appendSlice(alloc, e.bytes());
    if (!com.succeeded(hr)) {
        if (code) |c| com.release(c);
        return error.CompileFailed;
    }
    return .{ .code = code orelse return error.CompileFailed };
}

test "compile a pixel shader" {
    const alloc = std.testing.allocator;
    var messages: std.ArrayList(u8) = .empty;
    defer messages.deinit(alloc);
    const c = try compile("float4 main() : SV_Target { return float4(1, 0, 0, 1); }", "test", "main", "ps_5_0", OPTIMIZATION_LEVEL3, &messages, alloc);
    defer c.deinit();
    // DXBC starts with its magic.
    try std.testing.expectEqualSlices(u8, "DXBC", c.bytes()[0..4]);
    try std.testing.expectError(error.CompileFailed, compile("float4 main() : SV_Target { return nope; }", "bad", "main", "ps_5_0", 0, &messages, alloc));
    try std.testing.expect(std.mem.indexOf(u8, messages.items, "nope") != null);
}
