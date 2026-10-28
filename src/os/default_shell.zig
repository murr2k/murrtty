//! Windows: the shell Ghostty starts when `command` is unset (roadmap 2.5,
//! decision 3), PowerShell 7 when it is installed, else `%COMSPEC%` (cmd);
//! and where a bare command name is found (roadmap 6.6).
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

/// Whether `program` is a bare name: no folder or drive in it.
pub fn isBareName(program: []const u8) bool {
    return std.mem.indexOfAny(u8, program, "\\/:") == null;
}

/// Where Windows' own search would find bare command name `name` (roadmap
/// 6.6), but for what it searches first: the folder murrtty's executable
/// is in (still searched, last, as Exec puts it at the end of the child's
/// PATH) and the current one (a shell's folder, when murrtty was started
/// from one), where a planted program would run instead. The system
/// folder, the Windows folder, then PATH's (`path`) absolute entries: on
/// fixed drives first, as findPwsh, then the others (network shares,
/// removable drives), which can stall or ask for a disk. A name without an
/// extension takes ".exe", as CreateProcess gives it; PATHEXT doesn't
/// apply, as it doesn't there (CreateProcess never runs `tool.cmd` for
/// `tool`, and a batch file as the program gets its arguments through
/// cmd's parsing). The caller owns the result.
pub fn findProgram(alloc: Allocator, name: []const u8, path: ?[]const u8) Allocator.Error!?[]u8 {
    var old_mode: windows.DWORD = 0;
    const mode_set = windows.exp.kernel32.SetThreadErrorMode(
        windows.SEM_FAILCRITICALERRORS | windows.SEM_NOOPENFILEERRORBOX,
        &old_mode,
    ) != windows.FALSE;
    defer if (mode_set) {
        _ = windows.exp.kernel32.SetThreadErrorMode(old_mode, null);
    };

    const has_ext = std.mem.indexOfScalar(u8, name, '.') != null;
    const file = if (has_ext) name else try std.mem.concat(alloc, u8, &.{ name, ".exe" });
    defer if (!has_ext) alloc.free(file);

    var buf: [windows.MAX_PATH]u16 = undefined;
    for ([_]*const fn ([*]u16, windows.UINT) callconv(.winapi) windows.UINT{
        windows.exp.kernel32.GetSystemDirectoryW,
        windows.exp.kernel32.GetSystemWindowsDirectoryW,
    }) |get| {
        const n = get(&buf, buf.len);
        if (n == 0 or n >= buf.len) continue;
        const dir = std.unicode.wtf16LeToWtf8Alloc(alloc, buf[0..n]) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer alloc.free(dir);
        if (try existingFile(alloc, &.{ dir, file })) |found| return found;
    }
    if (path) |p| for ([_]Drives{ .fixed, .other }) |drives| {
        var dirs = std.mem.tokenizeScalar(u8, p, ';');
        while (dirs.next()) |entry| {
            const dir = std.mem.trim(u8, entry, " \"");
            if (try existingFileOn(alloc, &.{ dir, file }, drives)) |found| return found;
        }
    };
    return null;
}

/// This process's PATH, or null. The caller owns the result.
pub fn processPath(alloc: Allocator) Allocator.Error!?[]u8 {
    const name = std.unicode.utf8ToUtf16LeStringLiteral("PATH");
    const len = windows.exp.kernel32.GetEnvironmentVariableW(name, null, 0);
    if (len == 0) return null;
    const buf = try alloc.alloc(u16, len);
    defer alloc.free(buf);
    const n = windows.exp.kernel32.GetEnvironmentVariableW(name, buf.ptr, len);
    if (n == 0 or n >= len) return null;
    return std.unicode.wtf16LeToWtf8Alloc(alloc, buf[0..n]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
}

/// `parts` joined, if they make a path on a fixed drive naming something
/// that isn't a folder (the Store's aliases are reparse points, not files).
fn existingFile(alloc: Allocator, parts: []const []const u8) Allocator.Error!?[]u8 {
    return existingFileOn(alloc, parts, .fixed);
}

/// Which absolute paths existingFileOn takes: a fixed drive's (or a RAM
/// disk's), or the others (another drive type, or a share, `\\server\x`).
const Drives = enum { fixed, other };

fn existingFileOn(alloc: Allocator, parts: []const []const u8, drives: Drives) Allocator.Error!?[]u8 {
    const path = try std.fs.path.join(alloc, parts);
    errdefer alloc.free(path);
    // PATH may write a folder with forward slashes.
    std.mem.replaceScalar(u8, path, '/', '\\');
    const lettered = path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and path[2] == '\\';
    const share = path.len > 2 and path[0] == '\\' and path[1] == '\\' and path[2] != '?' and path[2] != '.';
    const fixed = lettered and fixed: {
        // Answered from the drive letters' table, without touching the drive.
        const root = [_:0]u16{ path[0], ':', '\\' };
        break :fixed switch (windows.exp.kernel32.GetDriveTypeW(&root)) {
            windows.DRIVE_FIXED, windows.DRIVE_RAMDISK => true,
            else => false,
        };
    };
    const take = switch (drives) {
        .fixed => fixed,
        .other => share or (lettered and !fixed),
    };
    if (!take) {
        alloc.free(path);
        return null;
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

test findProgram {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;

    try testing.expect(isBareName("cmd.exe"));
    try testing.expect(isBareName("pwsh"));
    try testing.expect(!isBareName("C:\\Windows\\System32\\cmd.exe"));
    try testing.expect(!isBareName(".\\tool.exe"));
    try testing.expect(!isBareName("bin/tool"));

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "bin");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bin\\tool.exe", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bin\\other.cmd", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bin\\cmd.exe", .data = "" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(root);
    const bin = try std.fs.path.join(alloc, &.{ root, "bin" });
    defer alloc.free(bin);
    const want = try std.fs.path.join(alloc, &.{ bin, "tool.exe" });
    defer alloc.free(want);

    // On PATH (quoted), with ".exe" added, or as named.
    const path = try std.mem.concat(alloc, u8, &.{ "C:\\no-such-dir;\"", bin, "\"" });
    defer alloc.free(path);
    for ([_][]const u8{ "tool", "tool.exe" }) |name| {
        const found = (try findProgram(alloc, name, path)).?;
        defer alloc.free(found);
        try testing.expectEqualStrings(want, found);
    }
    // No PATHEXT: "other" isn't other.cmd; a relative entry (the test
    // runs where it reaches bin) isn't searched; nor is anything without
    // PATH.
    try testing.expect(try findProgram(alloc, "other", path) == null);
    const rel = try std.mem.concat(alloc, u8, &.{ ".zig-cache\\tmp\\", &tmp.sub_path, "\\bin" });
    defer alloc.free(rel);
    try testing.expect(try findProgram(alloc, "tool", rel) == null);
    try testing.expect(try findProgram(alloc, "tool", null) == null);
    // An entry with forward slashes, as some write PATH.
    {
        const fwd = try alloc.dupe(u8, bin);
        defer alloc.free(fwd);
        std.mem.replaceScalar(u8, fwd, '\\', '/');
        const found = (try findProgram(alloc, "tool", fwd)).?;
        defer alloc.free(found);
        try testing.expectEqualStrings(want, found);
    }

    // The system folder comes before PATH: cmd.exe is System32's.
    const cmd = (try findProgram(alloc, "cmd.exe", path)).?;
    defer alloc.free(cmd);
    try testing.expect(!std.mem.startsWith(u8, cmd, bin));
    try testing.expect(std.ascii.endsWithIgnoreCase(cmd, "\\System32\\cmd.exe"));
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
