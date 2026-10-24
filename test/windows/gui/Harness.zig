//! Drives a Debug ghostty.exe the way the port's GUI tests always have:
//! by posting messages to its windows, with modifier keys held through a
//! shared keyboard state, and by reading results back from window captures
//! and from the app's state dump (src/apprt/win32/test_hooks.zig).
//!
//! By default Ghostty runs on a separate, hidden desktop so the tests never
//! cover the user's work or take their keystrokes. The clipboard is shared
//! by every desktop in the session, so clipboard scenarios save and restore
//! the user's text.
const Harness = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const w = @import("win.zig");

alloc: Allocator,
/// ghostty.exe, absolute.
exe: [:0]const u16,
/// A per-run folder under %TEMP% for configs and dumps.
temp_dir: []const u8,
/// The hidden desktop, or null to run on the user's desktop.
desktop: ?w.HDESK = null,
desktop_name: ?[:0]u16 = null,
dump_msg: w.UINT,
verbose: bool = false,
/// Each launch's folder, for cleanup.
launched: std.ArrayList([]u8) = .empty,

pub const Error = error{
    TestFailed,
    /// The scenario can't run here; it printed why.
    Skipped,
    Timeout,
    LaunchFailed,
    DumpFailed,
    CaptureFailed,
    ClipboardBusy,
} || Allocator.Error;

pub fn init(alloc: Allocator, exe: []const u8, hidden: bool) !Harness {
    _ = w.SetProcessDPIAware();

    var tmp: [261]u16 = undefined;
    const tlen = w.GetTempPathW(tmp.len, &tmp);
    if (tlen == 0) return error.LaunchFailed;
    const base = try std.unicode.utf16LeToUtf8Alloc(alloc, tmp[0..tlen]);
    defer alloc.free(base);
    // Failed runs keep their folders, and process ids are reused, so the
    // name has the time too: no run starts with an earlier run's files.
    const temp_dir = try std.fmt.allocPrint(alloc, "{s}ghostty-gui-test-{d}-{d}", .{
        base,
        w.GetCurrentProcessId(),
        w.GetTickCount64(),
    });
    try makeDir(alloc, temp_dir);

    var self: Harness = .{
        .alloc = alloc,
        .exe = try std.unicode.utf8ToUtf16LeAllocZ(alloc, exe),
        .temp_dir = temp_dir,
        .dump_msg = w.RegisterWindowMessageW(w.L("GhosttyWin32TestDump")),
    };

    if (hidden) {
        const name = try std.fmt.allocPrint(alloc, "GhosttyGuiTest{d}", .{w.GetCurrentProcessId()});
        defer alloc.free(name);
        const name16 = try std.unicode.utf8ToUtf16LeAllocZ(alloc, name);
        const desk = w.CreateDesktopW(name16, null, null, 0, w.GENERIC_ALL, null) orelse {
            alloc.free(name16);
            std.debug.print("CreateDesktopW failed ({d}); use --visible\n", .{w.GetLastError()});
            return error.LaunchFailed;
        };
        // This thread has no windows yet, so it may move to the desktop:
        // windows can only be enumerated and messaged from the same one.
        if (w.SetThreadDesktop(desk) == 0) {
            std.debug.print("SetThreadDesktop failed ({d}); use --visible\n", .{w.GetLastError()});
            _ = w.CloseDesktop(desk);
            alloc.free(name16);
            return error.LaunchFailed;
        }
        self.desktop = desk;
        self.desktop_name = name16;
    }
    return self;
}

pub fn deinit(self: *Harness) void {
    for (self.launched.items) |d| self.alloc.free(d);
    self.launched.deinit(self.alloc);
    if (self.desktop) |d| _ = w.CloseDesktop(d);
    if (self.desktop_name) |n| self.alloc.free(n);
    self.alloc.free(self.exe);
    self.alloc.free(self.temp_dir);
}

/// Delete the run's folder: each launch's config and dump, then the
/// folders. Called after a fully passing run; a failing run keeps them.
pub fn cleanup(self: *Harness) void {
    for (self.launched.items) |dir| {
        for ([_][]const u8{ "\\dump.json", "\\ghostty.log", "\\ghostty\\config.ghostty" }) |file| removePath(self.alloc, dir, file, .file);
        removePath(self.alloc, dir, "\\ghostty", .dir);
        removePath(self.alloc, dir, "", .dir);
    }
    removePath(self.alloc, self.temp_dir, "", .dir);
}

fn removePath(alloc: Allocator, base: []const u8, rest: []const u8, kind: enum { file, dir }) void {
    const path = std.mem.concat(alloc, u8, &.{ base, rest }) catch return;
    defer alloc.free(path);
    const p = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch return;
    defer alloc.free(p);
    _ = switch (kind) {
        .file => w.DeleteFileW(p),
        .dir => w.RemoveDirectoryW(p),
    };
}

fn makeDir(alloc: Allocator, path: []const u8) !void {
    const p = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(p);
    _ = w.CreateDirectoryW(p, null); // fine if it exists
}

fn writeFile(alloc: Allocator, path: []const u8, data: []const u8) !void {
    const p = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(p);
    const h = w.CreateFileW(p, w.GENERIC_WRITE, 0, null, w.CREATE_ALWAYS, w.FILE_ATTRIBUTE_NORMAL, null);
    if (h == w.INVALID_HANDLE_VALUE) return error.LaunchFailed;
    defer _ = w.CloseHandle(h);
    var written: w.DWORD = 0;
    if (w.WriteFile(h, data.ptr, @intCast(data.len), &written, null) == 0) return error.LaunchFailed;
}

fn readFile(alloc: Allocator, path: []const u8) ![]u8 {
    const p = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(p);
    const h = w.CreateFileW(p, w.GENERIC_READ, w.FILE_SHARE_READ, null, w.OPEN_EXISTING, w.FILE_ATTRIBUTE_NORMAL, null);
    if (h == w.INVALID_HANDLE_VALUE) return error.DumpFailed;
    defer _ = w.CloseHandle(h);
    const size = w.GetFileSize(h, null);
    const buf = try alloc.alloc(u8, size);
    errdefer alloc.free(buf);
    var got: w.DWORD = 0;
    if (w.ReadFile(h, buf.ptr, size, &got, null) == 0 or got != size) return error.DumpFailed;
    return buf;
}

pub fn log(self: *const Harness, comptime fmt: []const u8, args: anytype) void {
    if (self.verbose) std.debug.print("    " ++ fmt ++ "\n", args);
}

//---------------------------------------------------------------
// Processes

/// A running Ghostty with its own config.
pub const Ghostty = struct {
    h: *Harness,
    proc: w.HANDLE,
    thread: w.HANDLE,
    pid: w.DWORD,
    dir: []const u8,
    dump_path: []const u8,

    pub fn deinit(self: *Ghostty) void {
        if (self.exitCode() == null) {
            _ = w.TerminateProcess(self.proc, 1);
            _ = w.WaitForSingleObject(self.proc, 5000);
        }
        _ = w.CloseHandle(self.proc);
        _ = w.CloseHandle(self.thread);
        self.h.alloc.free(self.dir);
        self.h.alloc.free(self.dump_path);
    }

    /// The exit code, or null while it runs.
    pub fn exitCode(self: *const Ghostty) ?u32 {
        var code: w.DWORD = 0;
        if (w.GetExitCodeProcess(self.proc, &code) == 0) return null;
        return if (code == w.STILL_ACTIVE) null else code;
    }

    pub fn waitExit(self: *const Ghostty, ms: u32) ?u32 {
        _ = w.WaitForSingleObject(self.proc, ms);
        return self.exitCode();
    }
};

/// Where a launched Ghostty's windows go.
pub const Where = enum {
    /// The harness's desktop: hidden unless --visible.
    default,
    /// The user's desktop, far off-screen, for checks that need captures
    /// (DWM renders off-screen windows but not hidden desktops). Drive it
    /// only from runOnUserDesktop, and end it with deinit (which
    /// terminates it), never through a dialog, which would appear on
    /// screen.
    offscreen,
};

/// Start Ghostty with `config` as its whole configuration. `name` names
/// the scenario's folder. Returns once its first window exists.
pub fn launch(self: *Harness, name: []const u8, config: []const u8) !Ghostty {
    return self.launchWith(name, config, .{});
}

pub fn launchAt(self: *Harness, name: []const u8, config: []const u8, where: Where) !Ghostty {
    return self.launchWith(name, config, .{ .where = where });
}

pub const LaunchOptions = struct {
    where: Where = .default,
    /// Extra environment variables, as name and value.
    env: []const [2][]const u8 = &.{},
};

pub fn launchWith(self: *Harness, name: []const u8, config: []const u8, opts: LaunchOptions) !Ghostty {
    const where = opts.where;
    const alloc = self.alloc;
    const dir = try std.fmt.allocPrint(alloc, "{s}\\{s}", .{ self.temp_dir, name });
    errdefer alloc.free(dir);
    try makeDir(alloc, dir);
    try self.launched.append(alloc, try alloc.dupe(u8, dir));
    const cfg_dir = try std.fmt.allocPrint(alloc, "{s}\\ghostty", .{dir});
    defer alloc.free(cfg_dir);
    try makeDir(alloc, cfg_dir);
    const cfg_file = try std.fmt.allocPrint(alloc, "{s}\\config.ghostty", .{cfg_dir});
    defer alloc.free(cfg_file);
    try writeFile(alloc, cfg_file, config);
    const dump_path = try std.fmt.allocPrint(alloc, "{s}\\dump.json", .{dir});
    errdefer alloc.free(dump_path);

    const env = try self.environment(dir, dump_path, opts.env);
    defer alloc.free(env);

    var cmdline: std.ArrayList(u16) = .empty;
    defer cmdline.deinit(alloc);
    try cmdline.append(alloc, '"');
    try cmdline.appendSlice(alloc, self.exe);
    try cmdline.appendSlice(alloc, &.{ '"', 0 });

    var desktop: ?[:0]u16 = null;
    defer if (desktop) |d| alloc.free(d);
    if (where == .default) if (self.desktop_name) |n| {
        desktop = try std.mem.concatWithSentinel(alloc, u16, &.{ std.unicode.utf8ToUtf16LeStringLiteral("WinSta0\\"), n }, 0);
    };
    // Ghostty's log (its stderr) goes to ghostty.log beside the dump. Its
    // shells inherit the handle too (Ghostty starts them inheriting), so
    // the file can be deleted while one is still open.
    const log_path = try std.fmt.allocPrint(alloc, "{s}\\ghostty.log", .{dir});
    defer alloc.free(log_path);
    const log16 = try std.unicode.utf8ToUtf16LeAllocZ(alloc, log_path);
    defer alloc.free(log16);
    var sa: w.SECURITY_ATTRIBUTES = .{ .bInheritHandle = w.TRUE };
    const log_file = w.CreateFileW(log16, w.GENERIC_WRITE, w.FILE_SHARE_READ | w.FILE_SHARE_DELETE, &sa, w.CREATE_ALWAYS, w.FILE_ATTRIBUTE_NORMAL, null);
    defer if (log_file != w.INVALID_HANDLE_VALUE) {
        _ = w.CloseHandle(log_file);
    };
    const logging = log_file != w.INVALID_HANDLE_VALUE;

    var siex: w.STARTUPINFOEXW = .{ .StartupInfo = .{
        .cb = @sizeOf(w.STARTUPINFOEXW),
        .lpDesktop = if (desktop) |d| d.ptr else null,
    } };
    const si = &siex.StartupInfo;
    // Only the log is inherited. Inheriting without a list would hand
    // Ghostty every inheritable handle this process has, including a pipe
    // to whatever reads its output, which would then never see the end of
    // it while an orphaned Ghostty lived.
    var attr_buf: [128]u8 align(@alignOf(usize)) = undefined;
    const inherit = [1]w.HANDLE{log_file};
    if (logging) {
        var size: usize = 0;
        _ = w.InitializeProcThreadAttributeList(null, 1, 0, &size);
        if (size > attr_buf.len or
            w.InitializeProcThreadAttributeList(&attr_buf, 1, 0, &size) == 0) return error.LaunchFailed;
        siex.lpAttributeList = &attr_buf;
        if (w.UpdateProcThreadAttribute(&attr_buf, 0, w.PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &inherit, @sizeOf(@TypeOf(inherit)), null, null) == 0) {
            w.DeleteProcThreadAttributeList(&attr_buf);
            return error.LaunchFailed;
        }
        si.dwFlags |= w.STARTF_USESTDHANDLES;
        si.hStdOutput = log_file;
        si.hStdError = log_file;
    } else {
        si.cb = @sizeOf(w.STARTUPINFOW);
    }
    defer if (logging) w.DeleteProcThreadAttributeList(&attr_buf);
    if (where == .offscreen) {
        // Ghostty creates its first window at CW_USEDEFAULT, which takes
        // this position.
        si.dwFlags |= w.STARTF_USEPOSITION;
        si.dwX = @bitCast(@as(i32, -20000));
        si.dwY = @bitCast(@as(i32, -20000));
    }
    var pi: w.PROCESS_INFORMATION = undefined;
    const dir16 = try std.unicode.utf8ToUtf16LeAllocZ(alloc, dir);
    defer alloc.free(dir16);
    if (w.CreateProcessW(
        self.exe,
        @ptrCast(cmdline.items.ptr),
        null,
        null,
        if (logging) w.TRUE else w.FALSE,
        w.CREATE_UNICODE_ENVIRONMENT | @as(w.DWORD, if (logging) w.EXTENDED_STARTUPINFO_PRESENT else 0),
        env.ptr,
        dir16,
        si,
        &pi,
    ) == 0) {
        std.debug.print("CreateProcessW failed ({d})\n", .{w.GetLastError()});
        return error.LaunchFailed;
    }

    var g: Ghostty = .{
        .h = self,
        .proc = pi.hProcess,
        .thread = pi.hThread,
        .pid = pi.dwProcessId,
        .dir = dir,
        .dump_path = dump_path,
    };
    errdefer g.deinit();
    _ = self.waitFor(&g, 15000, struct {
        fn ready(h: *Harness, gg: *Ghostty) bool {
            const wins = h.windows(gg, "GhosttyWindow") catch return false;
            defer h.alloc.free(wins);
            return wins.len > 0;
        }
    }.ready) catch {
        std.debug.print("no window appeared (exit code {?d})\n", .{g.exitCode()});
        return error.LaunchFailed;
    };
    return g;
}

/// This process's environment with the test's variables replaced.
fn environment(self: *Harness, cfg_home: []const u8, dump_path: []const u8, extra: []const [2][]const u8) ![]u16 {
    const alloc = self.alloc;
    var out: std.ArrayList(u16) = .empty;
    errdefer out.deinit(alloc);
    const block = w.GetEnvironmentStringsW() orelse return error.LaunchFailed;
    defer _ = w.FreeEnvironmentStringsW(block);
    const drop = [_][]const u8{ "XDG_CONFIG_HOME=", "GHOSTTY_WIN32_TEST_DUMP=", "GHOSTTY_WIN32_TEST_LAUNCH=", "NO_COLOR=" };
    var i: usize = 0;
    while (block[i] != 0) {
        const entry = std.mem.sliceTo(block[i..], 0);
        i += entry.len + 1;
        var keep = true;
        for (drop) |d| {
            if (entry.len >= d.len and asciiEqlIgnoreCase16(entry[0..d.len], d)) keep = false;
        }
        if (keep) {
            try out.appendSlice(alloc, entry);
            try out.append(alloc, 0);
        }
    }
    const fixed = [_][2][]const u8{
        .{ "XDG_CONFIG_HOME", cfg_home },
        .{ "GHOSTTY_WIN32_TEST_DUMP", dump_path },
    };
    for ([_][]const [2][]const u8{ &fixed, extra }) |list| for (list) |kv| {
        const s = try std.mem.concat(alloc, u8, &.{ kv[0], "=", kv[1] });
        defer alloc.free(s);
        const s16 = try std.unicode.utf8ToUtf16LeAlloc(alloc, s);
        defer alloc.free(s16);
        try out.appendSlice(alloc, s16);
        try out.append(alloc, 0);
    };
    try out.append(alloc, 0);
    return out.toOwnedSlice(alloc);
}

//---------------------------------------------------------------
// Registry

/// Set a string value under HKEY_CURRENT_USER\`path`, creating the key.
/// `value` null sets the key's default value. Keys created here are
/// volatile: if the harness is killed before it deletes them, they are
/// gone at the next sign-in anyway.
pub fn setRegString(self: *Harness, path: []const u8, value: ?[]const u8, data: []const u8) !void {
    const alloc = self.alloc;
    const path16 = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(path16);
    const value16 = if (value) |v| try std.unicode.utf8ToUtf16LeAllocZ(alloc, v) else null;
    defer if (value16) |v| alloc.free(v);
    const data16 = try std.unicode.utf8ToUtf16LeAllocZ(alloc, data);
    defer alloc.free(data16);

    var key_handle: w.HKEY = undefined;
    if (w.RegCreateKeyExW(w.HKEY_CURRENT_USER, path16, 0, null, w.REG_OPTION_VOLATILE, w.KEY_WRITE, null, &key_handle, null) != 0) {
        return self.fail("could not create HKCU\\{s}", .{path});
    }
    defer _ = w.RegCloseKey(key_handle);
    const bytes: w.DWORD = @intCast((data16.len + 1) * 2);
    if (w.RegSetValueExW(key_handle, if (value16) |v| v.ptr else null, 0, w.REG_SZ, @ptrCast(data16.ptr), bytes) != 0) {
        return self.fail("could not set a value in HKCU\\{s}", .{path});
    }
}

/// Delete HKEY_CURRENT_USER\`path` and everything under it.
pub fn deleteRegTree(self: *Harness, path: []const u8) void {
    const path16 = std.unicode.utf8ToUtf16LeAllocZ(self.alloc, path) catch return;
    defer self.alloc.free(path16);
    _ = w.RegDeleteTreeW(w.HKEY_CURRENT_USER, path16);
}

/// Delete the value `value` of HKEY_CURRENT_USER\`path`.
pub fn deleteRegValue(self: *Harness, path: []const u8, value: []const u8) void {
    const path16 = std.unicode.utf8ToUtf16LeAllocZ(self.alloc, path) catch return;
    defer self.alloc.free(path16);
    const value16 = std.unicode.utf8ToUtf16LeAllocZ(self.alloc, value) catch return;
    defer self.alloc.free(value16);
    _ = w.RegDeleteKeyValueW(w.HKEY_CURRENT_USER, path16, value16);
}

/// The path of a helper program built and installed next to the harness.
pub fn helperPath(self: *Harness, comptime name: []const u8) ![]u8 {
    var buf: [1024]u16 = undefined;
    const n = w.GetModuleFileNameW(null, &buf, buf.len);
    if (n == 0 or n >= buf.len) return error.LaunchFailed;
    const exe = try std.unicode.utf16LeToUtf8Alloc(self.alloc, buf[0..n]);
    defer self.alloc.free(exe);
    const dir = exe[0 .. std.mem.lastIndexOfScalar(u8, exe, '\\') orelse return error.LaunchFailed];
    return std.fmt.allocPrint(self.alloc, "{s}\\" ++ name, .{dir});
}

/// The contents of a file, or null if it can't be read.
pub fn readFileOrNull(self: *Harness, path: []const u8) ?[]u8 {
    return readFile(self.alloc, path) catch null;
}

pub fn writeFileAt(self: *Harness, path: []const u8, data: []const u8) !void {
    try writeFile(self.alloc, path, data);
}

pub fn deleteFile(self: *Harness, path: []const u8) void {
    removePath(self.alloc, path, "", .file);
}

fn asciiEqlIgnoreCase16(a: []const u16, b: []const u8) bool {
    for (a, b) |x, y| {
        if (x > 127 or std.ascii.toLower(@intCast(x)) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// Poll `cond` every 100 ms until it holds or `ms` pass.
pub fn waitFor(self: *Harness, g: *Ghostty, ms: u32, cond: fn (*Harness, *Ghostty) bool) Error!void {
    var waited: u32 = 0;
    while (waited <= ms) : (waited += 100) {
        if (cond(self, g)) return;
        w.Sleep(100);
    }
    return error.Timeout;
}

//---------------------------------------------------------------
// Windows

const FindCtx = struct {
    alloc: Allocator,
    pid: w.DWORD,
    class: []const u16,
    list: *std.ArrayList(w.HWND),
    failed: bool = false,
};

fn findProc(hwnd: w.HWND, lparam: w.LPARAM) callconv(.winapi) w.BOOL {
    const ctx: *FindCtx = @ptrFromInt(@as(usize, @bitCast(lparam)));
    var pid: w.DWORD = 0;
    _ = w.GetWindowThreadProcessId(hwnd, &pid);
    if (pid != ctx.pid or w.IsWindowVisible(hwnd) == 0) return w.TRUE;
    var buf: [64]u16 = undefined;
    const n = w.GetClassNameW(hwnd, &buf, buf.len);
    if (n > 0 and std.mem.eql(u16, buf[0..@intCast(n)], ctx.class)) {
        ctx.list.append(ctx.alloc, hwnd) catch {
            ctx.failed = true;
            return w.FALSE;
        };
    }
    return w.TRUE;
}

/// Visible top-level windows of class `class` (caller frees).
pub fn windows(self: *Harness, g: *const Ghostty, comptime class: []const u8) ![]w.HWND {
    var list: std.ArrayList(w.HWND) = .empty;
    errdefer list.deinit(self.alloc);
    var ctx: FindCtx = .{
        .alloc = self.alloc,
        .pid = g.pid,
        .class = std.unicode.utf8ToUtf16LeStringLiteral(class),
        .list = &list,
    };
    _ = w.EnumWindows(&findProc, @bitCast(@intFromPtr(&ctx)));
    if (ctx.failed) return error.OutOfMemory;
    return list.toOwnedSlice(self.alloc);
}

/// The visible child of `parent` with class `class`, if any.
pub fn child(self: *Harness, g: *const Ghostty, parent: w.HWND, comptime class: []const u8) ?w.HWND {
    var list: std.ArrayList(w.HWND) = .empty;
    defer list.deinit(self.alloc);
    var ctx: FindCtx = .{
        .alloc = self.alloc,
        .pid = g.pid,
        .class = std.unicode.utf8ToUtf16LeStringLiteral(class),
        .list = &list,
    };
    _ = w.EnumChildWindows(parent, &findProc, @bitCast(@intFromPtr(&ctx)));
    return if (list.items.len > 0) list.items[0] else null;
}

/// The single main window; fails if there is not exactly one.
pub fn mainWindow(self: *Harness, g: *const Ghostty) !w.HWND {
    const wins = try self.windows(g, "GhosttyWindow");
    defer self.alloc.free(wins);
    if (wins.len != 1) return self.fail("expected 1 window, found {d}", .{wins.len});
    return wins[0];
}

/// The visible terminal of `win`.
pub fn surface(self: *Harness, g: *const Ghostty, win: w.HWND) !w.HWND {
    return self.child(g, win, "GhosttySurface") orelse self.fail("no visible surface", .{});
}

pub fn title(self: *Harness, hwnd: w.HWND) ![]u8 {
    var buf: [256]u16 = undefined;
    const n = w.GetWindowTextW(hwnd, &buf, buf.len);
    return std.unicode.utf16LeToUtf8Alloc(self.alloc, buf[0..@intCast(@max(n, 0))]);
}

pub fn fail(self: *const Harness, comptime fmt: []const u8, args: anytype) error{TestFailed} {
    _ = self;
    std.debug.print("    FAIL: " ++ fmt ++ "\n", args);
    return error.TestFailed;
}

pub fn expect(self: *const Harness, ok: bool, comptime fmt: []const u8, args: anytype) error{TestFailed}!void {
    if (!ok) return self.fail(fmt, args);
    self.log("ok: " ++ fmt, args);
}

pub fn skip(self: *const Harness, comptime fmt: []const u8, args: anytype) error{Skipped} {
    _ = self;
    std.debug.print("    SKIP: " ++ fmt ++ "\n", args);
    return error.Skipped;
}

/// Whether the user's desktop is the one on screen, and so drawn by DWM.
/// It isn't while a screen saver or the lock screen is up (each has a
/// desktop of its own), and captures of its windows then come back blank.
pub fn userDesktopShown(self: *const Harness) bool {
    _ = self;
    const desk = w.OpenInputDesktop(0, w.FALSE, w.DESKTOP_READOBJECTS) orelse return false;
    defer _ = w.CloseDesktop(desk);
    var name: [64]u16 = undefined;
    var needed: w.DWORD = 0;
    if (w.GetUserObjectInformationW(desk, w.UOI_NAME, &name, @sizeOf(@TypeOf(name)), &needed) == 0) return false;
    return std.mem.eql(u16, std.mem.sliceTo(&name, 0), std.unicode.utf8ToUtf16LeStringLiteral("Default"));
}

/// Run `func(ctx)` on a new thread, which starts on the user's desktop
/// (only the harness's main thread moved to the hidden one), and wait for
/// it. Windows are enumerated and messaged per desktop, so an `.offscreen`
/// Ghostty is driven from here.
pub fn runOnUserDesktop(self: *Harness, ctx: anytype, comptime func: fn (@TypeOf(ctx)) void) void {
    _ = self;
    const Thunk = struct {
        fn start(p: ?*anyopaque) callconv(.winapi) w.DWORD {
            func(@ptrCast(@alignCast(p.?)));
            return 0;
        }
    };
    const t = w.CreateThread(null, 0, &Thunk.start, @ptrCast(ctx), 0, null) orelse {
        std.debug.print("CreateThread failed ({d})\n", .{w.GetLastError()});
        return;
    };
    _ = w.WaitForSingleObject(t, w.INFINITE);
    _ = w.CloseHandle(t);
}

//---------------------------------------------------------------
// Dialogs

/// Visible dialogs (#32770: MessageBox and TaskDialog) of the process.
pub fn dialogs(self: *Harness, g: *const Ghostty) ![]w.HWND {
    return self.windows(g, "#32770");
}

/// Wait for exactly one dialog and return it.
pub fn waitDialog(self: *Harness, g: *Ghostty, ms: u32) !w.HWND {
    var waited: u32 = 0;
    while (waited <= ms) : (waited += 100) {
        const d = try self.dialogs(g);
        defer self.alloc.free(d);
        if (d.len == 1) return d[0];
        if (d.len > 1) return self.fail("expected one dialog, found {d}", .{d.len});
        w.Sleep(100);
    }
    return self.fail("no dialog appeared", .{});
}

pub fn dialogCount(self: *Harness, g: *const Ghostty) !usize {
    const d = try self.dialogs(g);
    defer self.alloc.free(d);
    return d.len;
}

/// Answer a dialog with button `id` (IDYES, IDNO, or a task dialog's
/// custom id). Task dialogs host a DirectUIHWND and take TDM_CLICK_BUTTON;
/// message boxes take WM_COMMAND.
pub fn answer(self: *Harness, g: *const Ghostty, dlg: w.HWND, id: c_int) void {
    const id_w: w.WPARAM = @intCast(id);
    if (self.child(g, dlg, "DirectUIHWND") != null) {
        _ = w.PostMessageW(dlg, w.TDM_CLICK_BUTTON, id_w, 0);
    } else {
        _ = w.PostMessageW(dlg, w.WM_COMMAND, id_w, 0);
    }
}

//---------------------------------------------------------------
// Input

pub const Mods = struct { ctrl: bool = false, shift: bool = false, alt: bool = false };

/// Type text as WM_CHAR messages (UTF-16 units).
pub fn typeText(self: *Harness, target: w.HWND, text: []const u8) !void {
    const t16 = try std.unicode.utf8ToUtf16LeAlloc(self.alloc, text);
    defer self.alloc.free(t16);
    for (t16) |u| _ = w.PostMessageW(target, w.WM_CHAR, u, 1);
}

/// Modifier keys held for messages posted to a window: this thread
/// attaches to the window's input queue and sets the shared key state, so
/// GetKeyState in Ghostty sees the modifiers as they would be with a real
/// keyboard.
const Held = struct {
    me: w.DWORD,
    tid: w.DWORD,
    attached: bool,
    saved: [256]u8,

    fn init(target: w.HWND, mods: Mods) Held {
        var self: Held = .{
            .me = w.GetCurrentThreadId(),
            .tid = w.GetWindowThreadProcessId(target, null),
            .attached = false,
            .saved = undefined,
        };
        self.attached = w.AttachThreadInput(self.me, self.tid, w.TRUE) != 0;
        _ = w.GetKeyboardState(&self.saved);
        var state = self.saved;
        if (mods.ctrl) {
            state[w.VK_CONTROL] = 0x80;
            state[w.VK_LCONTROL] = 0x80;
        }
        if (mods.shift) {
            state[w.VK_SHIFT] = 0x80;
            state[w.VK_LSHIFT] = 0x80;
        }
        if (mods.alt) {
            state[w.VK_MENU] = 0x80;
            state[w.VK_LMENU] = 0x80;
        }
        _ = w.SetKeyboardState(&state);
        return self;
    }

    fn release(self: *Held) void {
        // Ghostty reads the modifier state when it handles the messages.
        w.Sleep(300);
        _ = w.SetKeyboardState(&self.saved);
        if (self.attached) _ = w.AttachThreadInput(self.me, self.tid, w.FALSE);
    }
};

/// A key press with modifiers held (see Held).
pub fn key(self: *Harness, target: w.HWND, mods: Mods, vk: u8) void {
    _ = self;
    var held: Held = .init(target, mods);
    defer held.release();

    const sc = w.MapVirtualKeyW(vk, w.MAPVK_VK_TO_VSC);
    const extended = switch (vk) {
        w.VK_PRIOR, w.VK_NEXT, w.VK_INSERT => true,
        else => false,
    };
    var flags: usize = 1 | (@as(usize, sc) << 16);
    if (extended) flags |= 1 << 24;
    if (mods.alt) flags |= 1 << 29;
    const sys = mods.alt and !mods.ctrl;
    _ = w.PostMessageW(target, if (sys) w.WM_SYSKEYDOWN else w.WM_KEYDOWN, vk, @bitCast(flags));
    _ = w.PostMessageW(target, if (sys) w.WM_SYSKEYUP else w.WM_KEYUP, vk, @bitCast(flags | 0xC0000000));
}

pub fn enter(self: *Harness, target: w.HWND) void {
    self.key(target, .{}, w.VK_RETURN);
}

pub const Button = enum { left, middle };

/// Click at client coordinates of `target`.
pub fn click(self: *Harness, target: w.HWND, x: c_int, y: c_int, button: Button) void {
    self.clickMods(target, x, y, button, .{});
}

/// Click with modifiers held from before the pointer moves there until
/// after the button is released (see Held).
pub fn clickMods(self: *Harness, target: w.HWND, x: c_int, y: c_int, button: Button, mods: Mods) void {
    _ = self;
    var held: ?Held = if (mods.ctrl or mods.shift or mods.alt) .init(target, mods) else null;
    defer if (held) |*h| h.release();

    var mk: w.WPARAM = 0;
    if (mods.ctrl) mk |= w.MK_CONTROL;
    if (mods.shift) mk |= w.MK_SHIFT;
    const pos = w.makeLParam(x, y);
    _ = w.PostMessageW(target, w.WM_MOUSEMOVE, mk, pos);
    switch (button) {
        .left => {
            _ = w.PostMessageW(target, w.WM_LBUTTONDOWN, mk | w.MK_LBUTTON, pos);
            _ = w.PostMessageW(target, w.WM_LBUTTONUP, mk, pos);
        },
        .middle => {
            _ = w.PostMessageW(target, w.WM_MBUTTONDOWN, mk | w.MK_MBUTTON, pos);
            _ = w.PostMessageW(target, w.WM_MBUTTONUP, mk, pos);
        },
    }
}

//---------------------------------------------------------------
// State dump

pub const Dump = struct {
    modal_depth: u32,
    windows: []const Window,
    /// Links that would have opened, as "verb target" (Ghostty records
    /// them instead of opening them while the test hooks are on).
    launches: []const []const u8 = &.{},

    pub const Window = struct {
        id: u64,
        hwnd: u64,
        enabled: bool,
        active: usize,
        client: [2]i32,
        tab_bar: TabBar,
        tabs: []const Tab,
    };
    pub const TabBar = struct {
        visible: bool,
        height: i32,
        tabs: []const struct { rect: [4]i32, close: [4]i32 },
        new_tab: [4]i32,
    };
    pub const Tab = struct {
        hwnd: u64,
        visible: bool,
        title: []const u8,
        cols: ?u32 = null,
        rows: ?u32 = null,
        /// Cell size and padding in pixels.
        cell: ?[2]u32 = null,
        padding: ?[2]u32 = null,
        /// The last presented frame's pixel near the window's
        /// bottom-right corner, 0xRRGGBB.
        pixel: ?u32 = null,
        /// The pixel asked for with `probe`, 0xRRGGBB with bit 24 set
        /// once a frame has been read; 0 until then.
        probe: ?u32 = null,
        text: ?[]const u8 = null,
    };
};

/// Ask Ghostty for its state. Needs a Debug build.
pub fn dump(self: *Harness, g: *const Ghostty) !std.json.Parsed(Dump) {
    return self.dumpWith(g, 0, 0);
}

/// The color of the pixel at client (`x`, `y`) of the active tab, as the
/// renderer next presents it. Ghostty reads it back in Debug builds, so
/// this works on the hidden desktop, where captures don't.
pub fn probe(self: *Harness, g: *const Ghostty, x: u32, y: u32) !u32 {
    var d = try self.dumpWith(g, 1, @bitCast(@as(usize, y << 16 | x)));
    d.deinit();
    var waited: u32 = 0;
    while (waited <= 5000) : (waited += 100) {
        var dd = try self.dump(g);
        defer dd.deinit();
        const win = dd.value.windows[0];
        if (win.tabs[win.active].probe) |v| if (v & (1 << 24) != 0) return v & 0xFFFFFF;
        w.Sleep(100);
    }
    return self.fail("no frame was presented after asking for pixel ({d},{d})", .{ x, y });
}

fn dumpWith(self: *Harness, g: *const Ghostty, wparam: w.WPARAM, lparam: w.LPARAM) !std.json.Parsed(Dump) {
    var hwnd: ?w.HWND = null;
    var prev: ?w.HWND = null;
    while (w.FindWindowExW(w.HWND_MESSAGE, prev, w.L("GhosttyWakeup"), null)) |cand| {
        var pid: w.DWORD = 0;
        _ = w.GetWindowThreadProcessId(cand, &pid);
        if (pid == g.pid) {
            hwnd = cand;
            break;
        }
        prev = cand;
    }
    const target = hwnd orelse return self.fail("no wakeup window (is this a Debug build?)", .{});
    var result: usize = 0;
    if (w.SendMessageTimeoutW(target, self.dump_msg, wparam, lparam, w.SMTO_ABORTIFHUNG, 5000, &result) == 0 or result != 1) {
        return self.fail("state dump failed (Debug build with test hooks needed)", .{});
    }
    const bytes = try readFile(self.alloc, g.dump_path);
    defer self.alloc.free(bytes);
    return std.json.parseFromSlice(Dump, self.alloc, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return self.fail("unreadable state dump", .{});
}

/// Wait until some tab's visible text contains `needle` at least `count`
/// times.
pub fn waitText(self: *Harness, g: *const Ghostty, needle: []const u8, count: usize, ms: u32) !void {
    var waited: u32 = 0;
    while (waited <= ms) : (waited += 200) {
        var d = try self.dump(g);
        defer d.deinit();
        for (d.value.windows) |win| for (win.tabs) |t| {
            if (t.text) |text| if (std.mem.count(u8, text, needle) >= count) return;
        };
        w.Sleep(200);
    }
    return self.fail("text '{s}' did not appear {d} time(s)", .{ needle, count });
}

//---------------------------------------------------------------
// Captures

pub const Image = struct {
    alloc: Allocator,
    width: usize,
    height: usize,
    /// 0x00RRGGBB, top-down.
    pixels: []u32,

    pub fn deinit(self: *Image) void {
        self.alloc.free(self.pixels);
    }

    pub fn rgb(self: *const Image, x: usize, y: usize) u32 {
        return self.pixels[y * self.width + x] & 0xFFFFFF;
    }
};

/// Capture a window through DWM (PrintWindow with PW_RENDERFULLCONTENT),
/// which works even when it is covered or on another desktop.
pub fn capture(self: *Harness, hwnd: w.HWND) !Image {
    var r: w.RECT = .{};
    _ = w.GetWindowRect(hwnd, &r);
    const width = r.right - r.left;
    const height = r.bottom - r.top;
    if (width <= 0 or height <= 0) return error.CaptureFailed;

    const screen = w.GetDC(null) orelse return error.CaptureFailed;
    defer _ = w.ReleaseDC(null, screen);
    const dc = w.CreateCompatibleDC(screen) orelse return error.CaptureFailed;
    defer _ = w.DeleteDC(dc);
    var bits: ?*anyopaque = null;
    const bmi: w.BITMAPINFOHEADER = .{ .biWidth = width, .biHeight = -height };
    const bmp = w.CreateDIBSection(dc, &bmi, w.DIB_RGB_COLORS, &bits, null, 0) orelse return error.CaptureFailed;
    defer _ = w.DeleteObject(bmp);
    const old = w.SelectObject(dc, bmp);
    defer if (old) |o| {
        _ = w.SelectObject(dc, o);
    };
    if (w.PrintWindow(hwnd, dc, w.PW_RENDERFULLCONTENT) == 0) return error.CaptureFailed;

    const n: usize = @intCast(width * height);
    const src: [*]const u32 = @ptrCast(@alignCast(bits orelse return error.CaptureFailed));
    const pixels = try self.alloc.alloc(u32, n);
    @memcpy(pixels, src[0..n]);
    return .{ .alloc = self.alloc, .width = @intCast(width), .height = @intCast(height), .pixels = pixels };
}

//---------------------------------------------------------------
// Clipboard

pub fn getClipboard(self: *Harness) !?[]u8 {
    try openClipboard();
    defer _ = w.CloseClipboard();
    const h = w.GetClipboardData(w.CF_UNICODETEXT) orelse return null;
    const p = w.GlobalLock(h) orelse return null;
    defer _ = w.GlobalUnlock(h);
    const s: [*:0]const u16 = @ptrCast(@alignCast(p));
    return try std.unicode.utf16LeToUtf8Alloc(self.alloc, std.mem.span(s));
}

pub fn setClipboard(self: *Harness, text: []const u8) !void {
    const t16 = try std.unicode.utf8ToUtf16LeAllocZ(self.alloc, text);
    defer self.alloc.free(t16);
    try openClipboard();
    defer _ = w.CloseClipboard();
    _ = w.EmptyClipboard();
    setClipboardData(w.CF_UNICODETEXT, std.mem.sliceAsBytes(t16[0 .. t16.len + 1]));
    excludeFromHistory();
}

/// A copy of `data` on the open clipboard as `format`.
fn setClipboardData(format: w.UINT, data: []const u8) void {
    const h = w.GlobalAlloc(w.GMEM_MOVEABLE, @max(data.len, 1)) orelse return;
    const p: [*]u8 = @ptrCast(w.GlobalLock(h) orelse {
        _ = w.GlobalFree(h);
        return;
    });
    @memcpy(p[0..data.len], data);
    _ = w.GlobalUnlock(h);
    // On success the system owns the memory.
    if (w.SetClipboardData(format, h) == null) _ = w.GlobalFree(h);
}

/// Keep what the harness puts on the open clipboard out of clipboard
/// history (Win+V) and cloud clipboard.
fn excludeFromHistory() void {
    const format = w.RegisterClipboardFormatW(w.L("ExcludeClipboardContentFromMonitorProcessing"));
    if (format != 0) setClipboardData(format, &.{0});
}

/// The clipboard's change counter, which reading doesn't need the
/// clipboard open for (so it can't get in the way of a write).
pub fn clipboardSequence(self: *Harness) w.DWORD {
    _ = self;
    return w.GetClipboardSequenceNumber();
}

/// The user's clipboard, to put back after a scenario that changes it: the
/// clipboard belongs to the window station, so the hidden desktop shares
/// it. Only formats that are cheap to read and mean the same as plain bytes
/// are kept: text, rich text, HTML, PNG and file lists. Reading a format
/// makes the program that copied it render it (Office renders a selection
/// as a picture or a whole document), so nothing else is read; formats
/// outside the list are dropped, and if one of them holds content the list
/// can't stand in for (a picture, embedded Office data), the scenario is
/// skipped rather than lose it.
pub const ClipboardSnapshot = struct {
    alloc: Allocator,
    formats: std.ArrayList(Format) = .empty,

    const Format = struct { id: w.UINT, data: []u8 };

    pub fn restore(self: *ClipboardSnapshot) void {
        defer self.deinit();
        openClipboard() catch {
            std.debug.print("    could not restore the clipboard (busy)\n", .{});
            return;
        };
        defer _ = w.CloseClipboard();
        _ = w.EmptyClipboard();
        for (self.formats.items) |f| setClipboardData(f.id, f.data);
        excludeFromHistory();
    }

    fn deinit(self: *ClipboardSnapshot) void {
        for (self.formats.items) |f| self.alloc.free(f.data);
        self.formats.deinit(self.alloc);
    }
};

/// Save the clipboard (see ClipboardSnapshot). Returns error.Skipped,
/// having said why, if it holds content that couldn't be put back.
pub fn saveClipboard(self: *Harness) !ClipboardSnapshot {
    var snap: ClipboardSnapshot = .{ .alloc = self.alloc };
    errdefer snap.deinit();
    try openClipboard();
    defer _ = w.CloseClipboard();

    // Listing the formats renders nothing; only kept ones are read.
    var keep: std.ArrayList(w.UINT) = .empty;
    defer keep.deinit(self.alloc);
    var format: w.UINT = 0;
    while (true) {
        format = w.EnumClipboardFormats(format);
        if (format == 0) break;
        switch (clipboardFormatKind(format)) {
            .keep => try keep.append(self.alloc, format),
            .drop => {},
            .lose => return self.skip("the clipboard holds a picture or embedded data the tests can't put back; clear it to run this", .{}),
        }
    }
    for (keep.items) |f| {
        const h = w.GetClipboardData(f) orelse continue;
        const size = w.GlobalSize(h);
        if (size == 0) continue;
        const p: [*]const u8 = @ptrCast(w.GlobalLock(h) orelse continue);
        defer _ = w.GlobalUnlock(h);
        const data = try self.alloc.dupe(u8, p[0..size]);
        errdefer self.alloc.free(data);
        try snap.formats.append(self.alloc, .{ .id = f, .data = data });
    }
    return snap;
}

fn clipboardFormatKind(format: w.UINT) enum { keep, drop, lose } {
    return switch (format) {
        13, 15, 16 => .keep, // CF_UNICODETEXT, CF_HDROP, CF_LOCALE
        // Pictures (bitmap, metafile, palette, DIB, DIBV5), owner-display
        // and private formats.
        2, 3, 8, 9, 14, 17, 0x80...0x8E, 0x200...0x3FF => .lose,
        0xC000...0xFFFF => registered: {
            var buf: [128]u16 = undefined;
            const n = w.GetClipboardFormatNameW(format, &buf, buf.len);
            if (n <= 0) break :registered .drop;
            const name = buf[0..@intCast(n)];
            for (kept_formats) |k| if (eqlAscii16(name, k)) break :registered .keep;
            for (lost_formats) |k| if (eqlAscii16(name, k)) break :registered .lose;
            break :registered .drop;
        },
        // CF_TEXT, CF_OEMTEXT and the like, which Windows makes from
        // CF_UNICODETEXT again.
        else => .drop,
    };
}

const kept_formats = [_][]const u8{
    "HTML Format", "Rich Text Format",   "PNG",                  "FileNameW",
    "FileName",    "Shell IDList Array", "Preferred DropEffect", "ExcludeClipboardContentFromMonitorProcessing",
};

/// Embedded documents, Office's own formats and the like.
const lost_formats = [_][]const u8{
    "Embed Source",      "Embedded Object", "Link Source",     "Link Source Descriptor",
    "Object Descriptor", "Native",          "OwnerLink",       "ObjectLink",
    "Biff8",             "Biff12",          "XML Spreadsheet", "Art::GVML ClipFormat",
};

fn eqlAscii16(a: []const u16, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

fn openClipboard() !void {
    var tries: usize = 0;
    while (tries < 20) : (tries += 1) {
        if (w.OpenClipboard(null) != 0) return;
        w.Sleep(50);
    }
    return error.ClipboardBusy;
}
