//! How this copy of murrtty was installed (roadmap 7.6b), which decides how
//! it updates: an installer copy downloads and runs the new installer; a
//! zip copy opens the release's page; Scoop and winget copies are updated
//! by their package manager; an MSIX copy by its package.
//!
//! Decided once, at start, from where murrtty.exe is: the per-user
//! installer records its folder (InstallLocation) under its uninstall key,
//! for the AppId murrtty.iss never changes, and murrtty.exe runs from its
//! `bin`; Scoop's copies live in `<root>\apps\murrtty\`, winget's portable
//! ones in `WinGet\Packages\MurrayKopit.murrtty_<source>\`.

const std = @import("std");
const c = @import("c.zig");
const test_hooks = @import("test_hooks.zig");

const log = std.log.scoped(.win32_updates);

pub const Kind = enum { installer, zip, scoop, winget, package };

/// The per-user installer's uninstall key (murrtty.iss's AppId, which
/// Inno Setup records as `{AppId}_is1`).
const uninstall_key = "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{CF44D64F-C2EA-4A32-A936-08DA32432785}_is1";

/// APPMODEL_ERROR_NO_PACKAGE: not running from an MSIX package.
const APPMODEL_ERROR_NO_PACKAGE = 15700;

/// How this murrtty was installed. GHOSTTY_WIN32_TEST_UPDATES_INSTALL (an
/// installer, zip, scoop, winget or package) stands in under the test hooks.
pub fn detect(alloc: std.mem.Allocator) Kind {
    if (comptime test_hooks.enabled) {
        var wide: [32]u16 = undefined;
        const n = c.GetEnvironmentVariableW(c.L("GHOSTTY_WIN32_TEST_UPDATES_INSTALL"), &wide, wide.len);
        if (n > 0 and n < wide.len) {
            var buf: [32]u8 = undefined;
            for (wide[0..n], buf[0..n]) |unit, *b| b.* = if (unit < 0x80) @intCast(unit) else '?';
            if (std.meta.stringToEnum(Kind, buf[0..n])) |k| return k;
        }
    }
    var len: u32 = 0;
    if (c.GetCurrentPackageFullName(&len, null) != APPMODEL_ERROR_NO_PACKAGE) return .package;

    var exe_w: [32768]u16 = undefined;
    const exe_len = c.GetModuleFileNameW(null, &exe_w, exe_w.len);
    if (exe_len == 0 or exe_len >= exe_w.len) return .zip;
    const exe = std.unicode.wtf16LeToWtf8Alloc(alloc, exe_w[0..exe_len]) catch return .zip;
    defer alloc.free(exe);
    const dir = exe[0 .. std.mem.lastIndexOfScalar(u8, exe, '\\') orelse return .zip];

    const location = installLocation(alloc);
    defer if (location) |l| alloc.free(l);
    const scoop = envVar(alloc, "SCOOP");
    defer if (scoop) |s| alloc.free(s);
    const scoop_global = envVar(alloc, "SCOOP_GLOBAL");
    defer if (scoop_global) |s| alloc.free(s);
    const kind = classify(dir, location, &.{ scoop, scoop_global });
    log.info("installed as {t}", .{kind});
    return kind;
}

/// `exe_dir` (murrtty.exe's folder) classified: under the installer's
/// recorded folder's `bin`, Scoop's apps (`scoop\apps\murrtty`, or the
/// roots SCOOP and SCOOP_GLOBAL name), winget's packages, or else a zip.
/// Names compare without case, either slash, a trailing one ignored.
pub fn classify(exe_dir: []const u8, install_location: ?[]const u8, scoop_roots: []const ?[]const u8) Kind {
    var dir_buf: [4096]u8 = undefined;
    const dir = normalize(&dir_buf, exe_dir) orelse return .zip;
    if (install_location) |loc| {
        var loc_buf: [4096]u8 = undefined;
        if (normalize(&loc_buf, loc)) |l| {
            if (dir.len == l.len + 4 and std.mem.startsWith(u8, dir, l) and std.mem.eql(u8, dir[l.len..], "\\bin")) return .installer;
        }
    }
    if (std.mem.indexOf(u8, dir, "\\scoop\\apps\\murrtty\\") != null) return .scoop;
    for (scoop_roots) |root| if (root) |r| {
        var root_buf: [4096]u8 = undefined;
        const norm = normalize(&root_buf, r) orelse continue;
        if (norm.len == 0) continue;
        var prefix_buf: [4200]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buf, "{s}\\apps\\murrtty\\", .{norm}) catch continue;
        if (std.mem.startsWith(u8, dir, prefix)) return .scoop;
    };
    if (std.mem.indexOf(u8, dir, "\\winget\\packages\\murraykopit.murrtty_") != null) return .winget;
    return .zip;
}

/// A path lower-cased (ASCII), with '/' as '\' and no trailing '\'.
fn normalize(buf: []u8, path: []const u8) ?[]const u8 {
    if (path.len > buf.len) return null;
    for (path, buf[0..path.len]) |ch, *o| o.* = if (ch == '/') '\\' else std.ascii.toLower(ch);
    return std.mem.trimEnd(u8, buf[0..path.len], "\\");
}

/// The installer's recorded folder, or null (never installed by it, or
/// uninstalled).
fn installLocation(alloc: std.mem.Allocator) ?[]u8 {
    var wide: [1024]u16 = undefined;
    var size: u32 = @sizeOf(@TypeOf(wide));
    if (c.RegGetValueW(c.HKEY_CURRENT_USER, c.L(uninstall_key), c.L("InstallLocation"), c.RRF_RT_REG_SZ, null, &wide, &size) != 0) return null;
    const units = std.mem.sliceTo(wide[0 .. size / 2], 0);
    if (units.len == 0) return null;
    return std.unicode.wtf16LeToWtf8Alloc(alloc, units) catch null;
}

fn envVar(alloc: std.mem.Allocator, comptime name: []const u8) ?[]u8 {
    var wide: [1024]u16 = undefined;
    const n = c.GetEnvironmentVariableW(c.L(name), &wide, wide.len);
    if (n == 0 or n >= wide.len) return null;
    return std.unicode.wtf16LeToWtf8Alloc(alloc, wide[0..n]) catch null;
}

test "update install: where murrtty.exe is" {
    const testing = std.testing;
    const loc = "C:\\Users\\Ann\\AppData\\Local\\Programs\\murrtty\\";
    try testing.expectEqual(Kind.installer, classify("C:\\Users\\Ann\\AppData\\Local\\Programs\\murrtty\\bin", loc, &.{}));
    // Case and slashes don't matter.
    try testing.expectEqual(Kind.installer, classify("c:/users/ann/appdata/local/programs/MURRTTY/bin/", loc, &.{}));
    // An unpacked zip elsewhere, though the installer was used once.
    try testing.expectEqual(Kind.zip, classify("C:\\Tools\\murrtty\\bin", loc, &.{}));
    try testing.expectEqual(Kind.zip, classify("C:\\Users\\Ann\\AppData\\Local\\Programs\\murrtty\\bin\\x", loc, &.{}));
    try testing.expectEqual(Kind.zip, classify("C:\\Users\\Ann\\AppData\\Local\\Programs\\murrtty-old\\bin", loc, &.{}));
    try testing.expectEqual(Kind.zip, classify("C:\\Tools\\murrtty\\bin", null, &.{}));
    // Scoop: the default root, or the one SCOOP names.
    try testing.expectEqual(Kind.scoop, classify("C:\\Users\\Ann\\scoop\\apps\\murrtty\\current\\bin", null, &.{}));
    try testing.expectEqual(Kind.scoop, classify("D:\\pkgs\\apps\\murrtty\\0.5.0\\bin", null, &.{ "D:\\pkgs", null }));
    try testing.expectEqual(Kind.zip, classify("D:\\pkgs\\apps\\other\\bin", null, &.{"D:\\pkgs"}));
    // winget's portable packages, per user or for the machine.
    try testing.expectEqual(Kind.winget, classify("C:\\Users\\Ann\\AppData\\Local\\Microsoft\\WinGet\\Packages\\MurrayKopit.murrtty_Microsoft.Winget.Source_8wekyb3d8bbwe\\bin", null, &.{}));
    try testing.expectEqual(Kind.winget, classify("C:\\Program Files\\WinGet\\Packages\\MurrayKopit.murrtty_Microsoft.Winget.Source_8wekyb3d8bbwe\\bin", null, &.{}));
}
