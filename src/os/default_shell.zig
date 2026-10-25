//! Windows: the shell Ghostty starts when `command` is unset (roadmap 2.5,
//! decision 3). PowerShell 7 when it is installed, else `%COMSPEC%` (cmd).
const std = @import("std");
const Allocator = std.mem.Allocator;
const EnvMap = std.process.Environ.Map;
const windows = @import("windows.zig");

/// The path of PowerShell 7's pwsh.exe, or null if it isn't installed.
/// Looked for on PATH, then as the Microsoft Store's alias, then in the
/// MSI installer's default folder (for an install that left PATH alone).
/// Only paths on fixed drives are searched: a relative PATH entry would
/// search wherever Ghostty was started, a network one (a mapped drive
/// included) could stall startup for tens of seconds, and an empty card
/// reader could raise a "No Disk" box. The installer's App Paths entry
/// isn't used: for a Store install it names the package's own pwsh.exe,
/// which can't be started directly. The caller owns the result.
pub fn findPwsh(alloc: Allocator, env: *const EnvMap) Allocator.Error!?[]u8 {
    var old_mode: windows.DWORD = 0;
    const mode_set = windows.exp.kernel32.SetThreadErrorMode(
        windows.SEM_FAILCRITICALERRORS | windows.SEM_NOOPENFILEERRORBOX,
        &old_mode,
    ) != windows.FALSE;
    defer if (mode_set) {
        _ = windows.exp.kernel32.SetThreadErrorMode(old_mode, null);
    };

    if (env.get("PATH")) |path| {
        var dirs = std.mem.tokenizeScalar(u8, path, ';');
        while (dirs.next()) |entry| {
            const dir = std.mem.trim(u8, entry, " \"");
            if (try existingFile(alloc, &.{ dir, "pwsh.exe" })) |found| return found;
        }
    }
    if (env.get("LOCALAPPDATA")) |local| {
        if (try existingFile(alloc, &.{ local, "Microsoft", "WindowsApps", "pwsh.exe" })) |found| return found;
    }
    if (env.get("ProgramFiles")) |program_files| {
        if (try existingFile(alloc, &.{ program_files, "PowerShell", "7", "pwsh.exe" })) |found| return found;
    }
    return null;
}

/// `parts` joined, if they make a path on a fixed drive naming something
/// that isn't a folder (the Store's aliases are reparse points, not files).
fn existingFile(alloc: Allocator, parts: []const []const u8) Allocator.Error!?[]u8 {
    const path = try std.fs.path.join(alloc, parts);
    errdefer alloc.free(path);
    if (path.len < 3 or !std.ascii.isAlphabetic(path[0]) or path[1] != ':' or path[2] != '\\') {
        alloc.free(path);
        return null;
    }
    // Answered from the drive letters' table, without touching the drive.
    const root = [_:0]u16{ path[0], ':', '\\' };
    switch (windows.exp.kernel32.GetDriveTypeW(&root)) {
        windows.DRIVE_FIXED, windows.DRIVE_RAMDISK => {},
        else => {
            alloc.free(path);
            return null;
        },
    }
    const path_w = std.unicode.wtf8ToWtf16LeAllocZ(alloc, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => {
            alloc.free(path);
            return null;
        },
    };
    defer alloc.free(path_w);
    const attrs = windows.exp.kernel32.GetFileAttributesW(path_w.ptr);
    if (attrs == windows.INVALID_FILE_ATTRIBUTES or attrs & windows.FILE_ATTRIBUTE_DIRECTORY != 0) {
        alloc.free(path);
        return null;
    }
    return path;
}

test findPwsh {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "bin");
    try tmp.dir.createDirPath(testing.io, "apps\\Microsoft\\WindowsApps");
    try tmp.dir.createDirPath(testing.io, "folder\\pwsh.exe");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(root);

    var env = EnvMap.init(alloc);
    defer env.deinit();
    const bin = try std.fs.path.join(alloc, &.{ root, "bin" });
    defer alloc.free(bin);
    const folder = try std.fs.path.join(alloc, &.{ root, "folder" });
    defer alloc.free(folder);

    // Not on PATH (relative entries, though they reach one: from the
    // current directory, where the test runs, and from the drive's root;
    // a missing entry; a folder named pwsh.exe), nor elsewhere.
    try tmp.dir.createDirPath(testing.io, "rel");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "rel\\pwsh.exe", .data = "" });
    const path = try std.mem.concat(alloc, u8, &.{
        ".zig-cache\\tmp\\", &tmp.sub_path, "\\rel;",
        root[2..],           "\\rel;",      "C:\\no-such-dir;",
        folder,              ";\"",         bin,
        "\"",
    });
    defer alloc.free(path);
    try env.put("PATH", path);
    try testing.expect(try findPwsh(alloc, &env) == null);

    // The Store's alias.
    const apps = try std.fs.path.join(alloc, &.{ root, "apps" });
    defer alloc.free(apps);
    try env.put("LOCALAPPDATA", apps);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "apps\\Microsoft\\WindowsApps\\pwsh.exe", .data = "" });
    {
        const found = (try findPwsh(alloc, &env)).?;
        defer alloc.free(found);
        try testing.expect(std.mem.startsWith(u8, found, apps));
    }

    // On PATH (quoted) comes first.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bin\\pwsh.exe", .data = "" });
    {
        const found = (try findPwsh(alloc, &env)).?;
        defer alloc.free(found);
        const want = try std.fs.path.join(alloc, &.{ bin, "pwsh.exe" });
        defer alloc.free(want);
        try testing.expectEqualStrings(want, found);
    }
}
