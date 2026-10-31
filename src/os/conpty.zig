//! The pseudo console behind each terminal on Windows (murrtty, roadmap
//! 2.6): Microsoft's ConPTY from conpty.dll beside the executable, which
//! starts OpenConsole.exe beside it as the console host (both from
//! dist/windows/conpty, the build Windows Terminal ships), else Windows'
//! own in kernel32. The bundled one is newer than the one in Windows 10 and
//! older Windows 11: it passes on what it doesn't handle itself (kitty
//! graphics' APC sequences), and measures text by grapheme clusters, as
//! the terminal does. `MURRTTY_CONPTY=system` picks Windows' own.
//!
//! A pseudo console is resized and closed by the implementation that made
//! it, so each pty keeps the `Api` it was created with.

const std = @import("std");
const builtin = @import("builtin");
const windows = @import("windows.zig");

const log = std.log.scoped(.conpty);

pub const Source = enum { bundled, system };

pub const Api = struct {
    source: Source,
    create: *const fn (windows.COORD, windows.HANDLE, windows.HANDLE, windows.DWORD, *windows.HPCON) callconv(.winapi) windows.HRESULT,
    resize: *const fn (windows.HPCON, windows.COORD) callconv(.winapi) windows.HRESULT,
    close: *const fn (windows.HPCON) callconv(.winapi) void,
};

/// The environment variable that picks Windows' own ConPTY when "system".
pub const variable = "MURRTTY_CONPTY";

/// How the bundled ConPTY measures text, as CreatePseudoConsole's flags
/// (conpty.h's PSEUDOCONSOLE_GLYPH_WIDTH_*). Windows' own takes none.
pub const GlyphWidth = enum(windows.DWORD) {
    /// Grapheme clusters, as grapheme-width-method = unicode measures.
    graphemes = 0x08,
    /// wcswidth, as grapheme-width-method = legacy measures.
    wcswidth = 0x10,
};

/// Windows' own ConPTY.
pub const system: Api = .{
    .source = .system,
    .create = windows.exp.kernel32.CreatePseudoConsole,
    .resize = windows.exp.kernel32.ResizePseudoConsole,
    .close = windows.exp.kernel32.ClosePseudoConsole,
};

/// The bundled one, once `resolve` loaded it.
var bundled: Api = undefined;
var chosen: *const Api = &system;
var once: INIT_ONCE = .{};
/// OpenConsole.exe beside conpty.dll, set with `bundled`.
var host_path: [4096]u16 = undefined;
var host_missing_logged = std.atomic.Value(bool).init(false);

/// The ConPTY a new pseudo console uses, decided the first time (any
/// thread). Without OpenConsole.exe beside it, conpty.dll would start
/// System32's conhost.exe with switches an older one doesn't know, and
/// the pane would get no shell; so while that file is gone (moved aside
/// by an install, say), new panes get Windows' own.
pub fn get() *const Api {
    _ = InitOnceExecuteOnce(&once, resolve, null, null);
    if (chosen == &bundled and GetFileAttributesW(@ptrCast(&host_path)) == windows.INVALID_FILE_ATTRIBUTES) {
        if (!host_missing_logged.swap(true, .monotonic)) {
            log.warn("OpenConsole.exe is gone from beside conpty.dll; new panes use Windows' own ConPTY", .{});
        }
        return &system;
    }
    return chosen;
}

/// The flags for creating a pseudo console with `api`.
pub fn flags(api: *const Api, width: GlyphWidth) windows.DWORD {
    return switch (api.source) {
        .bundled => @intFromEnum(width),
        .system => 0,
    };
}

fn resolve(_: *INIT_ONCE, _: ?*anyopaque, _: ?*?*anyopaque) callconv(.winapi) windows.BOOL {
    if (load()) |api| chosen = api;
    log.info("pseudo consoles use the {t} ConPTY", .{chosen.source});
    return windows.TRUE;
}

fn load() ?*const Api {
    if (systemRequested()) return null;
    var buf: [4096]u16 = undefined;
    const path = besideExecutable(&buf, std.unicode.utf8ToUtf16LeStringLiteral("conpty.dll")) orelse return null;
    // None there (a build without it, or an embedding host's folder).
    if (GetFileAttributesW(path) == windows.INVALID_FILE_ATTRIBUTES) return null;
    // Its console host, which `get` checks for again on each new pane.
    const host = besideExecutable(&host_path, std.unicode.utf8ToUtf16LeStringLiteral("OpenConsole.exe")) orelse return null;
    if (GetFileAttributesW(host) == windows.INVALID_FILE_ATTRIBUTES) {
        log.warn("conpty.dll is there but not OpenConsole.exe; using Windows' own ConPTY", .{});
        return null;
    }
    // By full path; what it loads comes from its own folder and System32
    // only, never the current directory or PATH.
    const module = LoadLibraryExW(path, null, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32) orelse {
        log.warn("could not load the bundled conpty.dll err={}", .{GetLastError()});
        return null;
    };
    bundled = .{
        .source = .bundled,
        .create = @ptrCast(GetProcAddress(module, "ConptyCreatePseudoConsole") orelse return missing(module)),
        .resize = @ptrCast(GetProcAddress(module, "ConptyResizePseudoConsole") orelse return missing(module)),
        .close = @ptrCast(GetProcAddress(module, "ConptyClosePseudoConsole") orelse return missing(module)),
    };
    return &bundled;
}

fn missing(module: HMODULE) ?*const Api {
    log.warn("the bundled conpty.dll lacks the Conpty* functions", .{});
    _ = FreeLibrary(module);
    return null;
}

/// Whether `MURRTTY_CONPTY` asks for Windows' own ("system", any case).
fn systemRequested() bool {
    var buf: [16]u16 = undefined;
    const n = GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral(variable), &buf, buf.len);
    if (n == 0 or n >= buf.len) return false;
    return eqlIgnoreCase(buf[0..n], "system");
}

fn eqlIgnoreCase(have: []const u16, want: []const u8) bool {
    if (have.len != want.len) return false;
    for (have, want) |a, b| {
        const lower = if (a >= 'A' and a <= 'Z') a + 32 else a;
        if (lower != b) return false;
    }
    return true;
}

/// `name` in the executable's folder, into `buf`; null if the path
/// doesn't fit.
fn besideExecutable(buf: []u16, name: [:0]const u16) ?[*:0]const u16 {
    const n = GetModuleFileNameW(null, buf.ptr, @intCast(buf.len));
    if (n == 0 or n >= buf.len) return null;
    const dir_end = (std.mem.lastIndexOfScalar(u16, buf[0..n], '\\') orelse return null) + 1;
    if (dir_end + name.len + 1 > buf.len) return null;
    @memcpy(buf[dir_end..][0..name.len], name);
    buf[dir_end + name.len] = 0;
    return @ptrCast(buf.ptr);
}

const HMODULE = *opaque {};
const INIT_ONCE = extern struct { ptr: ?*anyopaque = null };
const LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR = 0x00000100;
const LOAD_LIBRARY_SEARCH_SYSTEM32 = 0x00000800;

extern "kernel32" fn InitOnceExecuteOnce(
    once: *INIT_ONCE,
    callback: *const fn (*INIT_ONCE, ?*anyopaque, ?*?*anyopaque) callconv(.winapi) windows.BOOL,
    parameter: ?*anyopaque,
    context: ?*?*anyopaque,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn LoadLibraryExW(name: [*:0]const u16, file: ?*anyopaque, load_flags: u32) callconv(.winapi) ?HMODULE;
extern "kernel32" fn GetProcAddress(module: HMODULE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn FreeLibrary(module: HMODULE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetModuleFileNameW(module: ?HMODULE, buf: [*]u16, size: u32) callconv(.winapi) u32;
extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: ?[*]u16, size: u32) callconv(.winapi) u32;
extern "kernel32" fn GetFileAttributesW(path: [*:0]const u16) callconv(.winapi) u32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

test "eqlIgnoreCase" {
    const testing = std.testing;
    try testing.expect(eqlIgnoreCase(std.unicode.utf8ToUtf16LeStringLiteral("System"), "system"));
    try testing.expect(!eqlIgnoreCase(std.unicode.utf8ToUtf16LeStringLiteral("systems"), "system"));
    try testing.expect(!eqlIgnoreCase(std.unicode.utf8ToUtf16LeStringLiteral("bundled"), "system"));
}

test "besideExecutable" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    var buf: [4096]u16 = undefined;
    const path = besideExecutable(&buf, std.unicode.utf8ToUtf16LeStringLiteral("conpty.dll")).?;
    const s = std.mem.span(path);
    try testing.expect(std.mem.endsWith(u16, s, std.unicode.utf8ToUtf16LeStringLiteral("\\conpty.dll")));
    // Too small a buffer: no path rather than a cut one.
    var small: [8]u16 = undefined;
    try testing.expect(besideExecutable(&small, std.unicode.utf8ToUtf16LeStringLiteral("conpty.dll")) == null);
}

test "flags" {
    const testing = std.testing;
    try testing.expectEqual(@as(windows.DWORD, 0), flags(&system, .graphemes));
    const fake: Api = .{ .source = .bundled, .create = system.create, .resize = system.resize, .close = system.close };
    try testing.expectEqual(@as(windows.DWORD, 0x08), flags(&fake, .graphemes));
    try testing.expectEqual(@as(windows.DWORD, 0x10), flags(&fake, .wcswidth));
}
