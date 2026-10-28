//! Drives a Debug murrtty.exe the way the port's GUI tests always have:
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
const dda = @import("dda.zig");

alloc: Allocator,
/// murrtty.exe, absolute.
exe: [:0]const u16,
/// A per-run folder for configs and dumps, under GHOSTTY_GUI_TEST_DIR if
/// set (CI uploads that folder when a run fails), else under %TEMP%.
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
    var tlen = w.GetEnvironmentVariableW(w.L("GHOSTTY_GUI_TEST_DIR"), &tmp, tmp.len - 1);
    if (tlen >= tmp.len - 1) return error.LaunchFailed;
    if (tlen > 0) {
        tmp[tlen] = 0;
        // Made if missing; its parent must exist.
        _ = w.CreateDirectoryW(tmp[0..tlen :0].ptr, null);
        if (tmp[tlen - 1] != '\\') {
            tmp[tlen] = '\\';
            tlen += 1;
        }
    } else {
        tlen = w.GetTempPathW(tmp.len, &tmp);
        if (tlen == 0) return error.LaunchFailed;
    }
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
        for ([_][]const u8{ "\\dump.json", "\\murrtty.log", "\\murrtty\\config.ghostty", "\\ghostty\\config.ghostty" }) |file| removePath(self.alloc, dir, file, .file);
        removePath(self.alloc, dir, "\\murrtty", .dir);
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
    // Shared for writing too: Ghostty may still be writing (its log).
    const h = w.CreateFileW(p, w.GENERIC_READ, w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE, null, w.OPEN_EXISTING, w.FILE_ATTRIBUTE_NORMAL, null);
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
    /// Its first thread, when the harness started it.
    thread: ?w.HANDLE,
    pid: w.DWORD,
    dir: []const u8,
    dump_path: []const u8,

    pub fn deinit(self: *Ghostty) void {
        if (self.exitCode() == null) {
            _ = w.TerminateProcess(self.proc, 1);
            _ = w.WaitForSingleObject(self.proc, 5000);
        }
        _ = w.CloseHandle(self.proc);
        if (self.thread) |t| _ = w.CloseHandle(t);
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
    /// The user's desktop, on screen near its top-left corner, for checks
    /// of what DWM composes there (transparency). It appears on the owner's
    /// screen, so only opt-in scenarios use it; drive and end it as
    /// `.offscreen`.
    onscreen,
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
    /// Start Ghostty as a shortcut (.lnk) at this path would: Windows sets
    /// STARTF_TITLEISLINKNAME with the shortcut as the title.
    shortcut: ?[]const u8 = null,
    /// Write `config` as murrtty's configuration; false leaves it none.
    murrtty_config: bool = true,
    /// Also write this as Ghostty's own configuration, which murrtty reads
    /// when it has none of its own.
    ghostty_config: ?[]const u8 = null,
    /// Wait for murrtty's first window (none comes with initial-window =
    /// false).
    wait_window: bool = true,
};

pub fn launchWith(self: *Harness, name: []const u8, config: []const u8, opts: LaunchOptions) !Ghostty {
    const where = opts.where;
    const alloc = self.alloc;
    const dir = try std.fmt.allocPrint(alloc, "{s}\\{s}", .{ self.temp_dir, name });
    errdefer alloc.free(dir);
    try makeDir(alloc, dir);
    try self.launched.append(alloc, try alloc.dupe(u8, dir));
    // XDG_CONFIG_HOME is the scenario's folder: murrtty's configuration in
    // its murrtty folder, Ghostty's (if any) in its ghostty folder.
    for ([_]struct { []const u8, ?[]const u8 }{
        .{ "murrtty", if (opts.murrtty_config) config else null },
        .{ "ghostty", opts.ghostty_config },
    }) |entry| {
        const text = entry[1] orelse continue;
        const cfg_dir = try std.fmt.allocPrint(alloc, "{s}\\{s}", .{ dir, entry[0] });
        defer alloc.free(cfg_dir);
        try makeDir(alloc, cfg_dir);
        const cfg_file = try std.fmt.allocPrint(alloc, "{s}\\config.ghostty", .{cfg_dir});
        defer alloc.free(cfg_file);
        try writeFile(alloc, cfg_file, text);
    }
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
    // murrtty's log (its stderr) goes to murrtty.log beside the dump. Its
    // shells inherit the handle too (murrtty starts them inheriting), so
    // the file can be deleted while one is still open.
    const log_path = try std.fmt.allocPrint(alloc, "{s}\\murrtty.log", .{dir});
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
    const shortcut16 = if (opts.shortcut) |s| try std.unicode.utf8ToUtf16LeAllocZ(alloc, s) else null;
    defer if (shortcut16) |s| alloc.free(s);
    if (shortcut16) |s| {
        si.dwFlags |= w.STARTF_TITLEISLINKNAME;
        si.lpTitle = s.ptr;
    }
    if (where != .default) {
        // Ghostty creates its first window at CW_USEDEFAULT, which takes
        // this position.
        const at: i32 = if (where == .offscreen) -20000 else 120;
        si.dwFlags |= w.STARTF_USEPOSITION;
        si.dwX = @bitCast(at);
        si.dwY = @bitCast(at);
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
    // Not g.deinit: the errdefers above free `dir` and `dump_path`.
    errdefer {
        if (g.exitCode() == null) {
            _ = w.TerminateProcess(g.proc, 1);
            _ = w.WaitForSingleObject(g.proc, 5000);
        }
        _ = w.CloseHandle(g.proc);
        if (g.thread) |t| _ = w.CloseHandle(t);
    }
    if (!opts.wait_window) return g;
    _ = self.waitFor(&g, 15000, struct {
        fn ready(h: *Harness, gg: *Ghostty) bool {
            const wins = h.windows(gg, "MurrttyWindow") catch return false;
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
        // One the caller sets replaces the inherited one.
        for (extra) |kv| {
            if (entry.len > kv[0].len and entry[kv[0].len] == '=' and asciiEqlIgnoreCase16(entry[0..kv[0].len], kv[0])) keep = false;
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

/// What a CLI action printed, and its exit code.
pub const CliResult = struct {
    alloc: Allocator,
    code: u32,
    /// Its stdout (stderr, the log, goes to murrtty.log in its folder).
    out: []u8,

    pub fn deinit(self: *CliResult) void {
        self.alloc.free(self.out);
    }
};

/// Run murrtty with `args` (a CLI action, such as `+version`) in the run
/// folder `name`, on the hidden desktop, with its stdout on a pipe, as
/// PowerShell captures it, and its stderr (a Debug build's log) in
/// murrtty.log there. Only those two handles are inherited. It gets 30 s
/// to finish.
pub fn runCli(self: *Harness, name: []const u8, args: []const []const u8) !CliResult {
    return self.runCliWith(name, args, &.{});
}

/// runCli with extra environment variables, as name and value.
pub fn runCliWith(self: *Harness, name: []const u8, args: []const []const u8, extra_env: []const [2][]const u8) !CliResult {
    const alloc = self.alloc;
    const dir = try std.fmt.allocPrint(alloc, "{s}\\{s}", .{ self.temp_dir, name });
    defer alloc.free(dir);
    try makeDir(alloc, dir);
    try self.launched.append(alloc, try alloc.dupe(u8, dir));
    const dump_path = try std.fmt.allocPrint(alloc, "{s}\\dump.json", .{dir});
    defer alloc.free(dump_path);
    const env = try self.environment(dir, dump_path, extra_env);
    defer alloc.free(env);

    // Each argument quoted: none the tests pass holds a quote or ends in a
    // backslash.
    var cmdline: std.ArrayList(u16) = .empty;
    defer cmdline.deinit(alloc);
    try cmdline.append(alloc, '"');
    try cmdline.appendSlice(alloc, self.exe);
    try cmdline.append(alloc, '"');
    for (args) |a| {
        const a16 = try std.unicode.utf8ToUtf16LeAlloc(alloc, a);
        defer alloc.free(a16);
        try cmdline.appendSlice(alloc, std.unicode.utf8ToUtf16LeStringLiteral(" \""));
        try cmdline.appendSlice(alloc, a16);
        try cmdline.append(alloc, '"');
    }
    try cmdline.append(alloc, 0);

    var sa: w.SECURITY_ATTRIBUTES = .{ .bInheritHandle = w.TRUE };
    var read_end: w.HANDLE = undefined;
    var write_end: w.HANDLE = undefined;
    if (w.CreatePipe(&read_end, &write_end, &sa, 0) == 0) return error.LaunchFailed;
    defer _ = w.CloseHandle(read_end);
    var write_open = true;
    defer if (write_open) {
        _ = w.CloseHandle(write_end);
    };
    _ = w.SetHandleInformation(read_end, w.HANDLE_FLAG_INHERIT, 0);
    const log_path = try std.fmt.allocPrint(alloc, "{s}\\murrtty.log", .{dir});
    defer alloc.free(log_path);
    const log16 = try std.unicode.utf8ToUtf16LeAllocZ(alloc, log_path);
    defer alloc.free(log16);
    const log_file = w.CreateFileW(log16, w.GENERIC_WRITE, w.FILE_SHARE_READ | w.FILE_SHARE_DELETE, &sa, w.CREATE_ALWAYS, w.FILE_ATTRIBUTE_NORMAL, null);
    if (log_file == w.INVALID_HANDLE_VALUE) return error.LaunchFailed;
    defer _ = w.CloseHandle(log_file);

    var desktop: ?[:0]u16 = null;
    defer if (desktop) |d| alloc.free(d);
    if (self.desktop_name) |n| {
        desktop = try std.mem.concatWithSentinel(alloc, u16, &.{ std.unicode.utf8ToUtf16LeStringLiteral("WinSta0\\"), n }, 0);
    }
    var siex: w.STARTUPINFOEXW = .{ .StartupInfo = .{
        .cb = @sizeOf(w.STARTUPINFOEXW),
        .lpDesktop = if (desktop) |d| d.ptr else null,
        .dwFlags = w.STARTF_USESTDHANDLES,
        .hStdOutput = write_end,
        .hStdError = log_file,
    } };
    var attr_buf: [128]u8 align(@alignOf(usize)) = undefined;
    const inherit = [2]w.HANDLE{ write_end, log_file };
    var size: usize = 0;
    _ = w.InitializeProcThreadAttributeList(null, 1, 0, &size);
    if (size > attr_buf.len or
        w.InitializeProcThreadAttributeList(&attr_buf, 1, 0, &size) == 0) return error.LaunchFailed;
    defer w.DeleteProcThreadAttributeList(&attr_buf);
    if (w.UpdateProcThreadAttribute(&attr_buf, 0, w.PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &inherit, @sizeOf(@TypeOf(inherit)), null, null) == 0) return error.LaunchFailed;
    siex.lpAttributeList = &attr_buf;

    var pi: w.PROCESS_INFORMATION = undefined;
    const dir16 = try std.unicode.utf8ToUtf16LeAllocZ(alloc, dir);
    defer alloc.free(dir16);
    if (w.CreateProcessW(
        self.exe,
        @ptrCast(cmdline.items.ptr),
        null,
        null,
        w.TRUE,
        w.CREATE_UNICODE_ENVIRONMENT | w.EXTENDED_STARTUPINFO_PRESENT,
        env.ptr,
        dir16,
        &siex.StartupInfo,
        &pi,
    ) == 0) {
        std.debug.print("CreateProcessW failed ({d})\n", .{w.GetLastError()});
        return error.LaunchFailed;
    }
    _ = w.CloseHandle(pi.hThread);
    defer _ = w.CloseHandle(pi.hProcess);
    // Ours closed, the pipe breaks once murrtty's end closes.
    _ = w.CloseHandle(write_end);
    write_open = false;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var buf: [4096]u8 = undefined;
    const deadline = w.GetTickCount64() + 30000;
    while (true) {
        var avail: w.DWORD = 0;
        if (w.PeekNamedPipe(read_end, null, 0, null, &avail, null) == 0) break;
        if (avail > 0) {
            var got: w.DWORD = 0;
            if (w.ReadFile(read_end, &buf, @min(avail, buf.len), &got, null) == 0) break;
            try out.appendSlice(alloc, buf[0..got]);
            continue;
        }
        if (w.GetTickCount64() > deadline) {
            _ = w.TerminateProcess(pi.hProcess, 1);
            return self.fail("murrtty {s} didn't finish in 30 s", .{if (args.len > 0) args[0] else ""});
        }
        w.Sleep(20);
    }
    _ = w.WaitForSingleObject(pi.hProcess, 10000);
    var code: w.DWORD = 0;
    if (w.GetExitCodeProcess(pi.hProcess, &code) == 0) return error.LaunchFailed;
    return .{ .alloc = alloc, .code = code, .out = try out.toOwnedSlice(alloc) };
}

const TitleCtx = struct {
    title: []const u16,
    pid: ?w.DWORD = null,
};

fn titleProc(hwnd: w.HWND, lparam: w.LPARAM) callconv(.winapi) w.BOOL {
    const ctx: *TitleCtx = @ptrFromInt(@as(usize, @bitCast(lparam)));
    if (w.IsWindowVisible(hwnd) == 0) return w.TRUE;
    var buf: [256]u16 = undefined;
    const n = w.GetClassNameW(hwnd, &buf, buf.len);
    if (n <= 0 or !std.mem.eql(u16, buf[0..@intCast(n)], std.unicode.utf8ToUtf16LeStringLiteral("MurrttyWindow"))) return w.TRUE;
    const t = w.GetWindowTextW(hwnd, &buf, buf.len);
    if (t <= 0 or std.mem.indexOf(u16, buf[0..@intCast(t)], ctx.title) == null) return w.TRUE;
    var pid: w.DWORD = 0;
    _ = w.GetWindowThreadProcessId(hwnd, &pid);
    ctx.pid = pid;
    return w.FALSE;
}

/// A murrtty the harness didn't start (one a CLI action started for its
/// request), found by its window whose caption holds `title`, with its
/// dump in the run folder `name`, where the CLI's environment pointed it.
/// Waits up to `ms` for the window. deinit ends it.
pub fn adopt(self: *Harness, name: []const u8, caption: []const u8, ms: u32) !Ghostty {
    const alloc = self.alloc;
    const caption16 = try std.unicode.utf8ToUtf16LeAlloc(alloc, caption);
    defer alloc.free(caption16);
    var ctx: TitleCtx = .{ .title = caption16 };
    var waited: u32 = 0;
    while (ctx.pid == null) : (waited += 100) {
        if (waited > ms) return self.fail("no murrtty window titled {s} appeared", .{caption});
        _ = w.EnumWindows(&titleProc, @bitCast(@intFromPtr(&ctx)));
        if (ctx.pid == null) w.Sleep(100);
    }
    const proc = w.OpenProcess(w.PROCESS_TERMINATE | w.SYNCHRONIZE | w.PROCESS_QUERY_LIMITED_INFORMATION, w.FALSE, ctx.pid.?) orelse
        return self.fail("could not open the murrtty titled {s} ({d})", .{ caption, w.GetLastError() });
    errdefer _ = w.CloseHandle(proc);
    const dir = try std.fmt.allocPrint(alloc, "{s}\\{s}", .{ self.temp_dir, name });
    errdefer alloc.free(dir);
    return .{
        .h = self,
        .proc = proc,
        .thread = null,
        .pid = ctx.pid.?,
        .dir = dir,
        .dump_path = try std.fmt.allocPrint(alloc, "{s}\\dump.json", .{dir}),
    };
}

fn strayProc(hwnd: w.HWND, lparam: w.LPARAM) callconv(.winapi) w.BOOL {
    const h: *Harness = @ptrFromInt(@as(usize, @bitCast(lparam)));
    var buf: [1024]u16 = undefined;
    const n = w.GetClassNameW(hwnd, &buf, buf.len);
    if (n <= 0 or !std.mem.eql(u16, buf[0..@intCast(n)], std.unicode.utf8ToUtf16LeStringLiteral("MurrttyWindow"))) return w.TRUE;
    var pid: w.DWORD = 0;
    _ = w.GetWindowThreadProcessId(hwnd, &pid);
    const proc = w.OpenProcess(w.PROCESS_TERMINATE | w.PROCESS_QUERY_LIMITED_INFORMATION, w.FALSE, pid) orelse return w.TRUE;
    defer _ = w.CloseHandle(proc);
    var len: w.DWORD = buf.len;
    if (w.QueryFullProcessImageNameW(proc, 0, &buf, &len) == 0) return w.TRUE;
    if (len != h.exe.len) return w.TRUE;
    for (buf[0..len], h.exe) |a, b| {
        if (a != b and (a > 127 or b > 127 or std.ascii.toLower(@intCast(a)) != std.ascii.toLower(@intCast(b)))) return w.TRUE;
    }
    _ = w.TerminateProcess(proc, 1);
    return w.TRUE;
}

/// End every murrtty of the build under test with a window on the hidden
/// desktop: one a CLI action started that `adopt` couldn't take. Nothing
/// on the user's desktop (with --visible there is no hidden one).
pub fn killStray(self: *Harness) void {
    if (self.desktop_name == null) return;
    _ = w.EnumWindows(&strayProc, @bitCast(@intFromPtr(self)));
}

/// A pipe named `name` that the harness serves, labeled at low integrity:
/// what a sandboxed process of the user's could create first. The caller
/// closes it.
pub fn squatPipe(self: *Harness, name: []const u8) !w.HANDLE {
    const name16 = try std.unicode.utf8ToUtf16LeAllocZ(self.alloc, name);
    defer self.alloc.free(name16);
    var descriptor: ?*anyopaque = null;
    if (w.ConvertStringSecurityDescriptorToSecurityDescriptorW(w.L("D:(A;;GA;;;WD)S:(ML;;NW;;;LW)"), 1, &descriptor, null) == 0) {
        return self.fail("the low label's descriptor failed ({d})", .{w.GetLastError()});
    }
    defer _ = w.LocalFree(descriptor);
    const sa: w.SECURITY_ATTRIBUTES = .{ .lpSecurityDescriptor = descriptor };
    const h = w.CreateNamedPipeW(name16, w.PIPE_ACCESS_DUPLEX, w.PIPE_TYPE_MESSAGE | w.PIPE_READMODE_MESSAGE, 1, 4096, 4096, 0, &sa);
    if (h == w.INVALID_HANDLE_VALUE) return self.fail("could not create the pipe {s} ({d})", .{ name, w.GetLastError() });
    return h;
}

/// Send `bytes` as one message to the pipe `name` and return the one-byte
/// reply, as murrtty's client does (roadmap 5.1), or null if none came.
pub fn pipeRequest(self: *Harness, name: []const u8, bytes: []const u8) !?u8 {
    const name16 = try std.unicode.utf8ToUtf16LeAllocZ(self.alloc, name);
    defer self.alloc.free(name16);
    const h = w.CreateFileW(name16, w.GENERIC_READ | w.GENERIC_WRITE, 0, null, w.OPEN_EXISTING, 0, null);
    if (h == w.INVALID_HANDLE_VALUE) return self.fail("could not open the pipe {s} ({d})", .{ name, w.GetLastError() });
    defer _ = w.CloseHandle(h);
    var mode: w.DWORD = w.PIPE_READMODE_MESSAGE;
    if (w.SetNamedPipeHandleState(h, &mode, null, null) == 0) return self.fail("the pipe's message mode failed ({d})", .{w.GetLastError()});
    var n: w.DWORD = 0;
    if (w.WriteFile(h, bytes.ptr, @intCast(bytes.len), &n, null) == 0) return null;
    var reply: [16]u8 = undefined;
    if (w.ReadFile(h, &reply, reply.len, &n, null) == 0 or n != 1) return null;
    return reply[0];
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

/// Make a folder (fine if it exists); removeDirAt removes it once empty.
pub fn makeDirAt(self: *Harness, path: []const u8) !void {
    try makeDir(self.alloc, path);
}

pub fn removeDirAt(self: *Harness, path: []const u8) void {
    removePath(self.alloc, path, "", .dir);
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
    const wins = try self.windows(g, "MurrttyWindow");
    defer self.alloc.free(wins);
    if (wins.len != 1) return self.fail("expected 1 window, found {d}", .{wins.len});
    return wins[0];
}

/// The visible terminal of `win`.
pub fn surface(self: *Harness, g: *const Ghostty, win: w.HWND) !w.HWND {
    return self.child(g, win, "MurrttySurface") orelse self.fail("no visible surface", .{});
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

/// Whether DWM is driving a display. With the monitor off (or switched to
/// another input) Windows may still report the display as on, but DWM idles
/// at one vblank a second and drops what GL presents, so captures come back
/// blank (white): the tests' windows have nothing drawn.
pub fn displayDriven(self: *const Harness) bool {
    _ = self;
    const first = dwmRefreshes() orelse return false;
    w.Sleep(250);
    const second = dwmRefreshes() orelse return false;
    // About 15 at 60 Hz.
    return second -% first >= 5;
}

/// DWM's vblank count (DWM_TIMING_INFO.cRefresh).
fn dwmRefreshes() ?u64 {
    // DWM_TIMING_INFO is byte-packed: 292 bytes, cRefresh at offset 36.
    var info: [292]u8 align(8) = @splat(0);
    std.mem.writeInt(u32, info[0..4], info.len, .little);
    if (w.DwmGetCompositionTimingInfo(null, &info) < 0) return null;
    return std.mem.readInt(u64, info[36..44], .little);
}

/// Whether captures of the user's desktop work: it is on screen and DWM is
/// drawing it. The scenarios that capture skip themselves otherwise.
pub fn capturesWork(self: *const Harness) ?[]const u8 {
    if (!self.userDesktopShown()) return "the desktop isn't being drawn (screen saver or lock screen is up)";
    // DWM's vblank count also idles (a few a second) on a static screen with
    // the monitor on, so with GHOSTTY_GUI_ONSCREEN (the owner is at the
    // screen) it isn't asked.
    if (w.GetEnvironmentVariableW(w.L("GHOSTTY_GUI_ONSCREEN"), null, 0) != 0) return null;
    if (!self.displayDriven()) return "DWM isn't driving a display (the monitor may be off; set GHOSTTY_GUI_ONSCREEN=1 if you are at the screen), so captures may come back blank";
    return null;
}

/// Put `win` (an `.onscreen` window) in front of the owner's windows and
/// make it the foreground one. Windows lets only a process with foreground
/// rights do that, which a background harness never has here (the
/// foreground lock never times out on this machine), but a thread attached
/// to the foreground window's input may. Returns the window that was in
/// front, for putting back with the same call, and whether `win` is in
/// front now.
pub fn bringToFront(win: w.HWND) struct { previous: ?w.HWND, ok: bool } {
    const previous = w.GetForegroundWindow();
    if (previous != win) {
        const me = w.GetCurrentThreadId();
        const theirs: w.DWORD = if (previous) |p| w.GetWindowThreadProcessId(p, null) else 0;
        const attached = theirs != 0 and theirs != me and w.AttachThreadInput(me, theirs, w.TRUE) != 0;
        defer if (attached) {
            _ = w.AttachThreadInput(me, theirs, w.FALSE);
        };
        _ = w.BringWindowToTop(win);
        _ = w.SetForegroundWindow(win);
    }
    return .{ .previous = previous, .ok = w.GetForegroundWindow() == win };
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

pub const Mods = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    /// NumLock off while the key is handled (numpadKey).
    num_lock_off: bool = false,
};

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
    /// To learn when Ghostty has handled what was posted (see release):
    /// its wakeup window, the dump message and the event it signals. Null
    /// without test hooks, and then a fixed wait has to do.
    wakeup: ?w.HWND = null,
    dump_msg: w.UINT,
    synced: ?w.HANDLE = null,

    fn init(dump_msg: w.UINT, target: w.HWND, mods: Mods) Held {
        var pid: w.DWORD = 0;
        var self: Held = .{
            .me = w.GetCurrentThreadId(),
            .tid = w.GetWindowThreadProcessId(target, &pid),
            .attached = false,
            .saved = undefined,
            .dump_msg = dump_msg,
        };
        if (wakeupWindow(pid)) |wakeup| sync: {
            var name_buf: [64]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "Local\\GhosttyGuiSync-{d}", .{pid}) catch break :sync;
            var name_w: [64:0]u16 = undefined;
            const len = std.unicode.utf8ToUtf16Le(&name_w, name) catch break :sync;
            name_w[len] = 0;
            self.synced = w.CreateEventW(null, w.FALSE, w.FALSE, &name_w) orelse break :sync;
            self.wakeup = wakeup;
        }
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
        if (mods.num_lock_off) state[w.VK_NUMLOCK] &= ~@as(u8, 1);
        _ = w.SetKeyboardState(&state);
        return self;
    }

    fn release(self: *Held) void {
        // Ghostty reads the modifier state when it handles the messages,
        // which can be well after they were posted (a Debug build on a busy
        // machine): ask it to signal once it gets to a message posted after
        // them. Posted messages are handled in order, and the wakeup window
        // is on the same thread as the terminal windows.
        self.wait();
        if (self.synced) |event| _ = w.CloseHandle(event);
        _ = w.SetKeyboardState(&self.saved);
        if (self.attached) _ = w.AttachThreadInput(self.me, self.tid, w.FALSE);
    }

    /// Wait until Ghostty has handled what was posted so far (the event
    /// resets itself, so this can be done more than once).
    fn wait(self: *Held) void {
        const waited = sync: {
            const wakeup = self.wakeup orelse break :sync false;
            const event = self.synced orelse break :sync false;
            if (w.PostMessageW(wakeup, self.dump_msg, 3, 0) == 0) break :sync false;
            break :sync w.WaitForSingleObject(event, 5000) == 0;
        };
        if (!waited) w.Sleep(300);
    }
};

/// Press murrtty's global binding hot key `global` (one of the dump's
/// `globals`), as Windows reports one: WM_HOTKEY to its wakeup window, the
/// modifiers and virtual key in lparam. No real key is sent, which would
/// reach the user's foreground window.
pub fn hotkey(self: *Harness, g: *const Ghostty, global: Dump.Global) !void {
    const hwnd = wakeupWindow(g.pid) orelse return self.fail("no wakeup window", .{});
    _ = w.PostMessageW(hwnd, w.WM_HOTKEY, 1, @intCast(global.mods | (global.vk << 16)));
    self.sync(hwnd);
}

/// Make toggle_visibility take murrtty as in front (`.yes`), as not
/// (`.no`), or ask Windows (`.real`): on the hidden desktop the foreground
/// window is always the user desktop's.
pub fn setInFront(self: *Harness, g: *const Ghostty, state: enum { real, yes, no }) !void {
    var d = try self.dumpWith(g, 16, @intFromEnum(state));
    d.deinit();
}

/// What Explorer sends for murrtty's tray icon (roadmap 5.6), posted to
/// its notification-area window as Explorer does (NOTIFYICON_VERSION_4:
/// the event in lParam's low word, the anchor in wParam): `.select` a
/// click, `.menu` the menu, at (x, y) in screen pixels.
pub fn trayEvent(self: *Harness, g: *const Ghostty, event: enum { select, menu }, x: i16, y: i16) !void {
    const hwnd = notifyWindow(g.pid) orelse return self.fail("no notification-area window", .{});
    const anchor: usize = @as(usize, @as(u16, @bitCast(x))) | (@as(usize, @as(u16, @bitCast(y))) << 16);
    const code: usize = switch (event) {
        .select => w.WM_USER,
        .menu => w.WM_CONTEXTMENU,
    };
    _ = w.PostMessageW(hwnd, w.WM_APP + 1, anchor, @bitCast(code));
    // A click runs before the wakeup window's sync (the same thread); a
    // menu's loop would keep it waiting.
    if (event == .select) if (wakeupWindow(g.pid)) |wake| self.sync(wake);
}

/// Wait until murrtty `g` takes the test hooks' messages (its wakeup
/// window exists), for a launch with no window to wait for.
pub fn waitAnswering(self: *Harness, g: *const Ghostty, ms: u32) !void {
    var waited: u32 = 0;
    while (waited <= ms) : (waited += 100) {
        if (wakeupWindow(g.pid) != null) return;
        if (g.exitCode()) |code| return self.fail("murrtty exited ({d})", .{code});
        w.Sleep(100);
    }
    return self.fail("murrtty never answered", .{});
}

/// The hidden window murrtty `pid`'s notification-area icon reports to.
fn notifyWindow(pid: w.DWORD) ?w.HWND {
    var prev: ?w.HWND = null;
    while (w.FindWindowExW(null, prev, w.L("MurrttyNotify"), null)) |cand| {
        var cand_pid: w.DWORD = 0;
        _ = w.GetWindowThreadProcessId(cand, &cand_pid);
        if (cand_pid == pid) return cand;
        prev = cand;
    }
    return null;
}

/// The message-only wakeup window of the Ghostty process `pid`, which
/// takes the test hooks' messages (Debug builds).
fn wakeupWindow(pid: w.DWORD) ?w.HWND {
    var prev: ?w.HWND = null;
    while (w.FindWindowExW(w.HWND_MESSAGE, prev, w.L("MurrttyWakeup"), null)) |cand| {
        var cand_pid: w.DWORD = 0;
        _ = w.GetWindowThreadProcessId(cand, &cand_pid);
        if (cand_pid == pid) return cand;
        prev = cand;
    }
    return null;
}

/// Wait until Ghostty has handled what was posted to `target` so far: a
/// later key with modifiers held must not be read as held for these.
pub fn sync(self: *Harness, target: w.HWND) void {
    var held: Held = .init(self.dump_msg, target, .{});
    held.release();
}

/// A key press with modifiers held (see Held).
pub fn key(self: *Harness, target: w.HWND, mods: Mods, vk: u8) void {
    // Keys of the navigation block: without the flag their scan codes read
    // as the numeric keypad's (Up as keypad 8).
    const extended = switch (vk) {
        w.VK_PRIOR, w.VK_NEXT, w.VK_INSERT => true,
        0x23...0x28, 0x2E => true, // End, Home, Left, Up, Right, Down, Delete
        else => false,
    };
    self.postKey(target, mods, vk, extended);
}

/// A navigation key from the numeric keypad with NumLock off: Windows
/// sends the navigation key's code (VK_INSERT for 0/Ins) with the keypad's
/// scan code, without the extended flag.
pub fn numpadKey(self: *Harness, target: w.HWND, mods: Mods, vk: u8) void {
    var off = mods;
    off.num_lock_off = true;
    self.postKey(target, off, vk, false);
}

fn postKey(self: *Harness, target: w.HWND, mods: Mods, vk: u8, extended: bool) void {
    var held: Held = .init(self.dump_msg, target, mods);
    defer held.release();

    const sc = w.MapVirtualKeyW(vk, w.MAPVK_VK_TO_VSC);
    var flags: usize = 1 | (@as(usize, sc) << 16);
    if (extended) flags |= 1 << 24;
    if (mods.alt) flags |= 1 << 29;
    const sys = mods.alt and !mods.ctrl;
    _ = w.PostMessageW(target, if (sys) w.WM_SYSKEYDOWN else w.WM_KEYDOWN, vk, @bitCast(flags));
    // As with a keyboard: the key down's WM_CHAR, which Windows posts as
    // Ghostty translates it, comes before the key up (posted together, the
    // key up went first, and the key down was handled without its text).
    held.wait();
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
    var held: ?Held = if (mods.ctrl or mods.shift or mods.alt) .init(self.dump_msg, target, mods) else null;
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

/// A double click at client coordinates of `target` (a window whose class
/// takes double clicks): press, release, then the second press arrives as
/// WM_LBUTTONDBLCLK.
pub fn doubleClick(self: *Harness, target: w.HWND, x: c_int, y: c_int) void {
    _ = self;
    const pos = w.makeLParam(x, y);
    _ = w.PostMessageW(target, w.WM_MOUSEMOVE, 0, pos);
    _ = w.PostMessageW(target, w.WM_LBUTTONDOWN, w.MK_LBUTTON, pos);
    _ = w.PostMessageW(target, w.WM_LBUTTONUP, 0, pos);
    _ = w.PostMessageW(target, w.WM_LBUTTONDBLCLK, w.MK_LBUTTON, pos);
    _ = w.PostMessageW(target, w.WM_LBUTTONUP, 0, pos);
}

/// Move the mouse to client coordinates of `target` (no button down, or
/// the left one held after `press`).
pub fn move(self: *Harness, target: w.HWND, x: c_int, y: c_int, held: bool) void {
    _ = self;
    _ = w.PostMessageW(target, w.WM_MOUSEMOVE, if (held) w.MK_LBUTTON else 0, w.makeLParam(x, y));
}

/// Move the mouse to client coordinates of `target` with modifiers held
/// (Ctrl over a link previews it).
pub fn moveMods(self: *Harness, target: w.HWND, x: c_int, y: c_int, mods: Mods) void {
    var held: Held = .init(self.dump_msg, target, mods);
    defer held.release();
    var mk: w.WPARAM = 0;
    if (mods.ctrl) mk |= w.MK_CONTROL;
    if (mods.shift) mk |= w.MK_SHIFT;
    _ = w.PostMessageW(target, w.WM_MOUSEMOVE, mk, w.makeLParam(x, y));
}

/// Press the left button at client coordinates of `target`, and later let
/// it go with `release`: a drag in between with `move`.
pub fn press(self: *Harness, target: w.HWND, x: c_int, y: c_int) void {
    _ = self;
    const pos = w.makeLParam(x, y);
    _ = w.PostMessageW(target, w.WM_MOUSEMOVE, 0, pos);
    _ = w.PostMessageW(target, w.WM_LBUTTONDOWN, w.MK_LBUTTON, pos);
}

pub fn release(self: *Harness, target: w.HWND, x: c_int, y: c_int) void {
    _ = self;
    _ = w.PostMessageW(target, w.WM_LBUTTONUP, 0, w.makeLParam(x, y));
}

/// Turn the wheel `notches` (positive: away from the user, up) at client
/// coordinates of `target`; the message carries screen coordinates.
pub fn wheel(self: *Harness, target: w.HWND, x: c_int, y: c_int, notches: c_int) void {
    self.wheelDelta(target, x, y, notches * 120);
}

/// A wheel turn of `delta` (120 a notch; touchpads and smooth wheels send
/// less at a time).
pub fn wheelDelta(self: *Harness, target: w.HWND, x: c_int, y: c_int, delta: c_int) void {
    _ = self;
    var pt: w.POINT = .{ .x = x, .y = y };
    _ = w.ClientToScreen(target, &pt);
    const d: u16 = @bitCast(@as(i16, @intCast(delta)));
    _ = w.PostMessageW(target, w.WM_MOUSEWHEEL, @as(w.WPARAM, d) << 16, w.makeLParam(pt.x, pt.y));
}

/// Press the right button at client coordinates of `target`, without the
/// release: a context menu opens on the press and takes the release.
pub fn rightPress(self: *Harness, target: w.HWND, x: c_int, y: c_int) void {
    _ = self;
    const pos = w.makeLParam(x, y);
    _ = w.PostMessageW(target, w.WM_MOUSEMOVE, 0, pos);
    _ = w.PostMessageW(target, w.WM_RBUTTONDOWN, w.MK_RBUTTON, pos);
}

//---------------------------------------------------------------
// Popup menus

/// Wait until the process shows `count` popup menus (#32768: a menu, then
/// a submenu over it) and return the topmost, the last opened.
pub fn waitMenu(self: *Harness, g: *const Ghostty, count: usize, ms: u32) !w.HWND {
    var waited: u32 = 0;
    while (waited <= ms) : (waited += 100) {
        const menus = try self.windows(g, "#32768");
        defer self.alloc.free(menus);
        // EnumWindows lists the topmost first.
        if (menus.len >= count) return menus[0];
        w.Sleep(100);
    }
    return self.fail("{d} popup menu(s) did not appear", .{count});
}

pub fn menuCount(self: *Harness, g: *const Ghostty) !usize {
    const menus = try self.windows(g, "#32768");
    defer self.alloc.free(menus);
    return menus.len;
}

pub const MenuItem = struct {
    /// UTF-8, with the access key's `&` and any `\t` accelerator text.
    text: []u8,
    grayed: bool,
    separator: bool,
    submenu: bool,
    checked: bool = false,
};

/// The items of the popup menu window `menu`. Menus belong to the desktop,
/// so another process can read them. Free with freeMenuItems.
pub fn menuItems(self: *Harness, menu: w.HWND) ![]MenuItem {
    var result: usize = 0;
    if (w.SendMessageTimeoutW(menu, w.MN_GETHMENU, 0, 0, w.SMTO_ABORTIFHUNG, 2000, &result) == 0 or result == 0) {
        return self.fail("could not get the popup menu's items", .{});
    }
    const hmenu: w.HMENU = @ptrFromInt(result);
    const n: usize = @intCast(@max(w.GetMenuItemCount(hmenu), 0));
    const list = try self.alloc.alloc(MenuItem, n);
    for (list, 0..) |*item, i| {
        const pos: w.UINT = @intCast(i);
        const raw = w.GetMenuState(hmenu, pos, w.MF_BYPOSITION);
        // For a submenu the high byte is its item count, not flags.
        const submenu = raw & w.MF_POPUP != 0;
        const state = if (submenu) raw & 0xFF else raw;
        var buf: [256]u16 = undefined;
        const len = w.GetMenuStringW(hmenu, pos, &buf, buf.len, w.MF_BYPOSITION);
        item.* = .{
            .text = try std.unicode.utf16LeToUtf8Alloc(self.alloc, buf[0..@intCast(@max(len, 0))]),
            .grayed = state & (w.MF_GRAYED | w.MF_DISABLED) != 0,
            .separator = state & w.MF_SEPARATOR != 0,
            .submenu = submenu,
            // MF_CHECKED.
            .checked = state & 0x0008 != 0,
        };
    }
    return list;
}

pub fn freeMenuItems(self: *Harness, list: []MenuItem) void {
    for (list) |item| self.alloc.free(item.text);
    self.alloc.free(list);
}

/// Press the access key `letter` in the open popup menu `menu`: it chooses
/// the item, or opens the submenu. Only the key down is posted; the menu's
/// loop translates it into the character it matches.
pub fn menuKey(self: *Harness, menu: w.HWND, letter: u8) void {
    _ = self;
    const vk = std.ascii.toUpper(letter);
    const sc = w.MapVirtualKeyW(vk, w.MAPVK_VK_TO_VSC);
    _ = w.PostMessageW(menu, w.WM_KEYDOWN, vk, @bitCast(@as(usize, 1 | (@as(usize, sc) << 16))));
}

//---------------------------------------------------------------
// State dump

pub const Dump = struct {
    modal_depth: u32,
    /// Context menus shown so far.
    menus_shown: u32 = 0,
    /// The last task dialog's heading and body.
    dialog: struct { heading: []const u8 = "", body: []const u8 = "" } = .{},
    windows: []const Window,
    /// Links that would have opened, as "verb target" (Ghostty records
    /// them instead of opening them while the test hooks are on).
    launches: []const []const u8 = &.{},
    /// Spike S1's overlays (setOverlays).
    overlays: []const Overlay = &.{},
    /// The single instance's pipe (roadmap 5.1).
    ipc: Ipc = .{},
    /// Desktop notifications as they would have shown (roadmap 5.2): the
    /// pane's core id (0 for murrtty's own), the title and body cut to the
    /// balloon's fields; whether the icon for the latest is there, and
    /// whose it is.
    notifications: []const struct { surface: u64, title: []const u8, body: []const u8 } = &.{},
    notify_icon: bool = false,
    /// Whether a notification stands (the icon may stay as the tray).
    notify_pending: bool = false,
    notify_surface: u64 = 0,
    /// The tray (roadmap 5.6); GTK's quit timer ("off", "active",
    /// "expired"); whether a window was ever opened.
    tray: bool = false,
    quit_timer: []const u8 = "",
    requested_window: bool = false,
    /// The global bindings' hot keys (roadmap 5.5); whether
    /// toggle_visibility hid the windows, their ids and the one that was
    /// in front (0 for none); the window last activated; hot keys waiting
    /// for a dialog to close.
    globals: []const Global = &.{},
    windows_hidden: bool = false,
    hidden_windows: []const u64 = &.{},
    hidden_front: u64 = 0,
    last_window: u64 = 0,
    hotkeys_pending: u32 = 0,
    /// Global bindings another murrtty holds, tried again every 3 s;
    /// toggle_visibility's runs; the global bindings' registrations.
    globals_waiting: u32 = 0,
    toggles: u32 = 0,
    global_refreshes: u32 = 0,
    /// The last test drop's effect (dropClipboard; roadmap 5.8): 1 a
    /// copy, 0 refused, -1 none made.
    drop_effect: i32 = -1,
    /// murrtty's selection clipboard (roadmap 5.9).
    selection: []const u8 = "",
    /// A pane's drag (roadmap 1.10): past the drag distance, the pane
    /// dragged, the pane under the pointer and the side ("" for none).
    pane_drag: struct { active: bool = false, dragging: bool = false, source: u64 = 0, target: u64 = 0, dir: []const u8 = "" } = .{},
    /// Undo's history (roadmap 5.11): the entries' names, oldest first, and
    /// how many tabs are parked.
    undo: struct { undo: []const []const u8 = &.{}, redo: []const []const u8 = &.{}, parked: u32 = 0 } = .{},

    /// The quick terminal's state (roadmap 5.7): shown (also while it
    /// slides in), sliding, and the work area and DPI it chose.
    pub const Quick = struct {
        shown: bool = false,
        sliding: bool = false,
        /// Out of the topmost band for another window's dialog.
        lowered: bool = false,
        work: [4]i32 = .{ 0, 0, 0, 0 },
        dpi: u32 = 96,
    };

    pub const Global = struct {
        /// As menus write it.
        trigger: []const u8 = "",
        /// MOD_* and the virtual key, as WM_HOTKEY reports them.
        mods: u32 = 0,
        vk: u32 = 0,
    };

    pub const Ipc = struct {
        /// Its name, "" with no server.
        pipe: []const u8 = "",
        /// Whether this murrtty holds the name.
        listening: bool = false,
        /// Requests it queued.
        received: u32 = 0,
        /// Started by a client for its request.
        launch: bool = false,
    };

    pub const Overlay = struct {
        kind: u8,
        hwnd: u64,
        surface: u64,
        /// WM_PAINTs the overlay handled.
        paints: u32,
    };

    pub const Window = struct {
        id: u64,
        hwnd: u64,
        enabled: bool,
        active: usize,
        client: [2]i32,
        /// The title bar as Ghostty set it: dark or light, and the caption
        /// color (0xRRGGBB) or -1 for the system's.
        chrome: ?struct { dark: bool, caption: i64 } = null,
        /// Whether the desktop shows through the background (roadmap 4.1).
        translucent: bool = false,
        /// window-decoration as the window has it (toggled or the
        /// config's), and whether its frame has no caption (4.3, 4.4).
        decoration: []const u8 = "",
        captionless: bool = false,
        /// Whether Windows last told it it is active (WM_NCACTIVATE).
        active_window: bool = true,
        /// Asked to stay above other windows (float_window), and whether
        /// Windows keeps it there.
        floating: bool = false,
        topmost: bool = false,
        /// Its window rectangle, whether it is shown, whether it is a tool
        /// window (no taskbar button), and the quick terminal's state if
        /// it is the quick terminal (roadmap 5.7).
        rect: [4]i32 = .{ 0, 0, 0, 0 },
        visible: bool = false,
        toolwindow: bool = false,
        quick: ?Quick = null,
        /// Its taskbar button's progress (roadmap 5.4: "none", "normal",
        /// "error", "paused", "indeterminate"), shown once `ready` (the
        /// button exists, never on the hidden desktop).
        taskbar: struct { state: []const u8 = "none", value: u32 = 0, ready: bool = false, hr: i64 = 1 } = .{},
        /// How what shows through is blurred (4.2: "none", "backdrop",
        /// "accent"), and the system backdrop DWM reports (-1 if it can't).
        blur: []const u8 = "none",
        backdrop_type: i64 = -1,
        /// The caption's text, and the user's name for the window ("" for
        /// none).
        caption: []const u8 = "",
        window_name: []const u8 = "",
        /// The toast showing ("" for none).
        toast: []const u8 = "",
        /// The command palette: open, whether it has the keyboard, its
        /// filter field, list and dimming windows, a row's height, the
        /// selected row (-1 for none), the filter's text and the listed
        /// titles, best match first, with the lines beneath them (the
        /// action, or where a terminal is).
        palette: ?struct {
            open: bool,
            focused: bool,
            edit: u64,
            list: u64,
            dim: u64,
            row_height: i32,
            selected: i64,
            text: []const u8,
            items: []const []const u8,
            details: []const []const u8,
        } = null,
        /// The small and big icons' widths at the window's DPI.
        icon_widths: [2]i32 = .{ 0, 0 },
        /// Whether the tab strip has its tooltip.
        has_tooltip: bool = false,
        header: Header = .{},
        tab_bar: TabBar,
        tabs: []const Tab,
    };
    /// GTK's header bar, the title bar with client-side decorations: its
    /// buttons in client coordinates (laid out for the window's width even
    /// while it's hidden).
    pub const Header = struct {
        visible: bool = false,
        /// Its buttons show in the tab row (gtk-titlebar-style = tabs).
        in_row: bool = false,
        height: i32 = 0,
        /// The title's font face.
        font: []const u8 = "",
        new_tab_tooltip: []const u8 = "",
        new_tab: [4]i32 = .{ 0, 0, 0, 0 },
        /// The arrow beside "+" (the split menu).
        new_tab_menu: [4]i32 = .{ 0, 0, 0, 0 },
        list: [4]i32 = .{ 0, 0, 0, 0 },
        menu: [4]i32 = .{ 0, 0, 0, 0 },
        /// The window's buttons.
        minimize: [4]i32 = .{ 0, 0, 0, 0 },
        maximize: [4]i32 = .{ 0, 0, 0, 0 },
        window_close: [4]i32 = .{ 0, 0, 0, 0 },
    };
    /// The tab row, below the header bar; rectangles in client coordinates.
    pub const TabBar = struct {
        visible: bool,
        /// The same as visible (the row shows only with tabs to show).
        tabs_shown: bool = false,
        /// Where the row starts (the header bar's height, or 0).
        top: i32 = 0,
        height: i32,
        /// The row's font face.
        font: []const u8 = "",
        tabs: []const struct { rect: [4]i32, close: [4]i32, tooltip: []const u8 = "" },
        /// Whether tabs overflow; then the chevrons, the span tabs show in
        /// (left, right) and how far they are scrolled.
        overflow: bool = false,
        scroll_left: [4]i32 = .{ 0, 0, 0, 0 },
        scroll_right: [4]i32 = .{ 0, 0, 0, 0 },
        view: [2]i32 = .{ 0, 0 },
        scroll: i32 = 0,
    };
    pub const Tab = struct {
        hwnd: u64,
        visible: bool,
        /// The focused pane's title as its program set it.
        title: []const u8,
        /// What the tab shows, and the user's names for the tab and its
        /// focused pane ("" for none).
        label: []const u8 = "",
        tab_name: []const u8 = "",
        pane_name: []const u8 = "",
        /// The bell: ringing in the focused pane, and the tab's mark for
        /// a bell while it was in the background.
        bell: bool = false,
        attention: bool = false,
        /// What the tab bar last painted: the label with the bell, the mark.
        painted_bell: bool = false,
        painted_attention: bool = false,
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
        /// The color scheme the core surface has: "light" or "dark".
        scheme: ?[]const u8 = null,
        /// Frames the renderer has presented.
        frames: ?u32 = null,
        /// Whether the core surface thinks it has the focus.
        focused: ?bool = null,
        text: ?[]const u8 = null,
        /// The tab's container size, its panes (left to right, top to
        /// bottom, as the splits nest) and its dividers, in the container's
        /// client coordinates.
        area: ?[2]i32 = null,
        panes: ?[]const Pane = null,
        dividers: ?[]const [4]i32 = null,
        /// Whether a pane of the tab is zoomed.
        zoomed: ?bool = null,
        /// The dividers' color as last painted, 0xRRGGBB, or -1 before
        /// any were.
        divider_color: ?i64 = null,
    };

    pub const Pane = struct {
        /// Its drag handle (roadmap 1.10): there (drag-handle), and showing
        /// under the mouse; the side a dragged pane would take ("" none).
        handle: struct { shown: bool = false, hover: bool = false } = .{},
        drop: []const u8 = "",
        /// Dimmed as an unfocused pane of its tab (unfocused-split-*).
        dimmed: bool = false,
        /// Its inspector window (roadmap 5.12), while open: frames drawn and
        /// where ImGui has the mouse; and the core's inspector on.
        inspector: ?struct { hwnd: u64, frames: u32, mouse: [2]f32 } = null,
        inspector_active: bool = false,
        /// Whether it takes drops (roadmap 5.8).
        drop_target: bool = false,
        /// OSC 9;4's progress (roadmap 5.4): its value (-1 while the bar
        /// pulses), error and paused states and the pulsing block's place.
        progress: ?struct { value: i32, err: bool, paused: bool, pulse: f32 } = null,
        hwnd: u64,
        /// The core surface's id (GHOSTTY_SURFACE_ID), 0 before it exists.
        surface_id: u64 = 0,
        rect: [4]i32,
        /// The tab's focused pane.
        focused: bool,
        visible: bool,
        core_focused: ?bool = null,
        /// Whether text is selected.
        selection: ?bool = null,
        frames: ?u32 = null,
        /// As the tab's `probe`, for this pane.
        probe: ?u32 = null,
        /// Whether the frame asked for with `saveFrames` was read.
        frame_ready: bool = false,
        /// The opacity of the top bars' shade over the pane's top row, 0
        /// for none.
        shade: f64 = 0,
        /// Key events the pane passed to the core (presses, repeats and
        /// releases; not text from WM_CHAR alone).
        keys: ?u32 = null,
        cols: ?u32 = null,
        rows: ?u32 = null,
        text: ?[]const u8 = null,
        /// The terminal's working directory: the starting one until the
        /// shell reports one (OSC 7, OSC 9;9).
        pwd: ?[]const u8 = null,
        /// Each visible row's prompt mark (OSC 133): "p" a prompt's first
        /// row, "c" a continuation, "." none.
        marks: ?[]const u8 = null,
        /// The cursor (column, row of the active area), its semantic
        /// content ("prompt", "input", "output") and whether Ghostty takes
        /// it as at a prompt (closing then doesn't ask).
        cursor: ?[2]u32 = null,
        semantic: ?[]const u8 = null,
        at_prompt: ?bool = null,
        /// Commands the shell reported finished (OSC 133;D after 133;C),
        /// and the last exit code (-1 for none).
        commands: u32 = 0,
        last_exit: i32 = -1,
        /// The resize overlay (resize-overlay): shown, and its text.
        resize_overlay: ?struct { visible: bool, text: []const u8 } = null,
        /// The search box: on (start_search to end_search), shown, its
        /// field's window, whether the box has the keyboard, the field's
        /// text and the "n/m" counter.
        search: ?struct {
            active: bool,
            visible: bool,
            edit: u64,
            focused: bool,
            text: []const u8,
            counter: []const u8,
        } = null,
        /// The scrollbar: the core's scrollable area (rows in all, the
        /// viewport's first row and height), shown, widened over the band
        /// at the right edge or pressed, its opacity, and the thumb's
        /// rectangle (left, top, right, bottom) in the pane.
        scrollbar: ?struct {
            total: u64,
            offset: u64,
            len: u64,
            visible: bool,
            hover: bool,
            pressed: bool,
            alpha: f64,
            thumb: [4]i32,
        } = null,
        /// The status overlays: the link preview's text ("" when hidden)
        /// and whether it moved to the right, the read-only badge, the key
        /// state's text, the renderer panel, the banner's title.
        status: ?struct {
            link: []const u8,
            link_right: bool,
            readonly: bool,
            keys: []const u8,
            health: bool,
            banner: []const u8,
        } = null,
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

/// The pixel at (x, y) of pane `i` of the first window's active tab, read
/// back from the next frame it presents (every pane is asked).
pub fn probePane(self: *Harness, g: *const Ghostty, i: usize, x: u32, y: u32) !u32 {
    var d = try self.dumpWith(g, 1, @bitCast(@as(usize, y << 16 | x)));
    d.deinit();
    var waited: u32 = 0;
    while (waited <= 5000) : (waited += 100) {
        var dd = try self.dump(g);
        defer dd.deinit();
        const win = dd.value.windows[0];
        if (win.tabs[win.active].panes) |p| if (i < p.len) if (p[i].probe) |v| {
            if (v & (1 << 24) != 0) return v & 0xFFFFFF;
        };
        w.Sleep(100);
    }
    return self.fail("pane {d} presented no frame after asking for pixel ({d},{d})", .{ i, x, y });
}

/// Have every pane read back the whole frame it presents next and write the
/// visible panes' frames as `frame-<n>.bmp` beside the dump file (n counts
/// the panes window by window, tab by tab, from 0). Ghostty reads them in
/// Debug builds, so this works on the hidden desktop, where captures read
/// white.
pub fn saveFrames(self: *Harness, g: *const Ghostty) !void {
    var d = try self.dumpWith(g, 10, 0);
    d.deinit();
    var waited: u32 = 0;
    while (waited <= 5000) : (waited += 100) {
        var dd = try self.dump(g);
        defer dd.deinit();
        const ready = ready: {
            for (dd.value.windows) |win| for (win.tabs) |t| if (t.panes) |panes| for (panes) |p| {
                if (p.visible and !p.frame_ready) break :ready false;
            };
            break :ready true;
        };
        if (ready) {
            var done = try self.dumpWith(g, 11, 0);
            done.deinit();
            return;
        }
        w.Sleep(100);
    }
    return self.fail("a visible pane presented no frame to read back", .{});
}

/// Have each window paint its chrome (header bar and tab row) into a bitmap
/// and write it as `chrome-<n>.bmp` beside the dump file, and its active
/// tab's container (the dividers) as `tab-<n>.bmp`: what WM_PAINT draws,
/// alpha included, which works on the hidden desktop.
pub fn saveChrome(self: *Harness, g: *const Ghostty) !void {
    var d = try self.dumpWith(g, 12, 0);
    d.deinit();
}

/// A picture Ghostty wrote beside its dump file (`saveFrames`,
/// `saveChrome`): a top-down 32-bit BMP, alpha kept.
pub fn loadPicture(self: *Harness, g: *const Ghostty, name: []const u8) !Image {
    const path = try std.fmt.allocPrint(self.alloc, "{s}\\{s}", .{ std.fs.path.dirname(g.dump_path).?, name });
    defer self.alloc.free(path);
    const bytes = self.readFileOrNull(path) orelse return self.fail("no {s}", .{path});
    defer self.alloc.free(bytes);
    if (bytes.len < 54 or bytes[0] != 'B' or bytes[1] != 'M') return self.fail("{s} is not a BMP", .{name});
    const offset = std.mem.readInt(u32, bytes[10..14], .little);
    const width = std.mem.readInt(i32, bytes[18..22], .little);
    const height = std.mem.readInt(i32, bytes[22..26], .little);
    const bpp = std.mem.readInt(u16, bytes[28..30], .little);
    if (width <= 0 or height >= 0 or bpp != 32) return self.fail("{s} is not a top-down 32-bit BMP", .{name});
    const wd: usize = @intCast(width);
    const ht: usize = @intCast(-height);
    if (bytes.len < offset + wd * ht * 4) return self.fail("{s} is cut short", .{name});
    const pixels = try self.alloc.alloc(u32, wd * ht);
    for (pixels, 0..) |*p, i| p.* = std.mem.readInt(u32, bytes[offset + i * 4 ..][0..4], .little);
    return .{ .alloc = self.alloc, .width = wd, .height = ht, .pixels = pixels };
}

/// Make panes ignore WM_MOUSELEAVE (`pinned`), which Windows sends for a
/// posted move at once on the hidden desktop, or act on it again: to see
/// hover state (a link's preview).
pub fn pinMouse(self: *Harness, g: *const Ghostty, pinned: bool) !void {
    var d = try self.dumpWith(g, 7, @intFromBool(pinned));
    d.deinit();
}

/// Make Ghostty blur with the accent policy, as before Windows 11 22H2,
/// whatever the build (`on`), or as the build says.
pub fn forceAccentBlur(self: *Harness, g: *const Ghostty, on: bool) !void {
    var d = try self.dumpWith(g, 13, @intFromBool(on));
    d.deinit();
}

/// Resize each of Ghostty's windows by its bottom right corner by (`dx`,
/// `dy`) as a drag would (WM_SIZING first, inside Ghostty, as its lParam is
/// a pointer that can't cross processes).
pub fn dragResize(self: *Harness, g: *const Ghostty, dx: i16, dy: i16) !void {
    const lp: u32 = @as(u32, @as(u16, @bitCast(dx))) | @as(u32, @as(u16, @bitCast(dy))) << 16;
    var d = try self.dumpWith(g, 14, @intCast(lp));
    d.deinit();
}

/// Click the latest desktop notification, as a click on its toast does
/// (dump wparam 15). Its pane comes forward from murrtty's message loop,
/// after this returns.
pub fn clickNotification(self: *Harness, g: *const Ghostty) !void {
    var d = try self.dumpWith(g, 15, 0);
    d.deinit();
}

/// Take the latest desktop notification back without presenting its pane,
/// which could take the user's foreground (dump wparam 15, lparam 1).
pub fn withdrawNotification(self: *Harness, g: *const Ghostty) !void {
    var d = try self.dumpWith(g, 15, 1);
    d.deinit();
}

/// Make Ghostty keep Acrylic even while inactive (`on`), where it otherwise
/// takes the accent policy's blur, to see what Windows draws then.
pub fn forceAcrylic(self: *Harness, g: *const Ghostty, on: bool) !void {
    var d = try self.dumpWith(g, 13, if (on) 2 else 0);
    d.deinit();
}

/// Windows' build number.
pub fn windowsBuild() u32 {
    var info: w.OSVERSIONINFOW = .{};
    if (w.RtlGetVersion(&info) != 0) return 0;
    return info.dwBuildNumber;
}

/// Make Ghostty act as if Windows' "Always show scrollbars" changed.
pub fn setScrollbarsAlways(self: *Harness, g: *const Ghostty, always: bool) !void {
    var d = try self.dumpWith(g, 8, @intFromBool(always));
    d.deinit();
}

/// Make every pane act as if its renderer failed (`healthy` false) or
/// recovered.
pub fn setRendererHealth(self: *Harness, g: *const Ghostty, healthy: bool) !void {
    var d = try self.dumpWith(g, 6, @intFromBool(!healthy));
    d.deinit();
}

/// Make Ghostty act as if the system's light/dark setting changed, without
/// changing the user's setting.
pub fn setSystemDark(self: *Harness, g: *const Ghostty, dark: bool) !void {
    var d = try self.dumpWith(g, 2, @intFromBool(dark));
    d.deinit();
}

/// Replace spike S1's overlays: none (`kind` 0), or a magenta window over
/// each pane as a sibling of its surface (1), a child of it (2) or a
/// layered child (3). Returns the dump taken after.
pub fn setOverlays(self: *Harness, g: *const Ghostty, kind: u8) !std.json.Parsed(Dump) {
    return self.dumpWith(g, 4, kind);
}

fn dumpWith(self: *Harness, g: *const Ghostty, wparam: w.WPARAM, lparam: w.LPARAM) !std.json.Parsed(Dump) {
    const target = wakeupWindow(g.pid) orelse return self.fail("no wakeup window (is this a Debug build?)", .{});
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

    /// With the alpha byte as the capture left it.
    pub fn argb(self: *const Image, x: usize, y: usize) u32 {
        return self.pixels[y * self.width + x];
    }

    /// Write it to `path` as a 32-bit BMP, for looking at a failure.
    pub fn save(self: *const Image, path: []const u8) !void {
        const data = std.mem.sliceAsBytes(self.pixels);
        var header: [54]u8 = @splat(0);
        header[0] = 'B';
        header[1] = 'M';
        std.mem.writeInt(u32, header[2..6], @intCast(header.len + data.len), .little);
        std.mem.writeInt(u32, header[10..14], header.len, .little);
        std.mem.writeInt(u32, header[14..18], 40, .little);
        std.mem.writeInt(i32, header[18..22], @intCast(self.width), .little);
        std.mem.writeInt(i32, header[22..26], -@as(i32, @intCast(self.height)), .little);
        std.mem.writeInt(u16, header[26..28], 1, .little);
        std.mem.writeInt(u16, header[28..30], 32, .little);
        const bytes = try std.mem.concat(self.alloc, u8, &.{ &header, data });
        defer self.alloc.free(bytes);
        try writeFile(self.alloc, path, bytes);
    }
};

/// Capture a window through DWM (PrintWindow with PW_RENDERFULLCONTENT),
/// which works even when it is covered or on another desktop.
pub fn capture(self: *Harness, hwnd: w.HWND) !Image {
    var r: w.RECT = .{};
    _ = w.GetWindowRect(hwnd, &r);
    return self.grab(r.right - r.left, r.bottom - r.top, .{ .window = hwnd });
}

/// A window as it paints itself into a bitmap (PrintWindow without DWM,
/// WM_PRINT): a popup menu's owner-drawn items, on the hidden desktop.
pub fn capturePrint(self: *Harness, hwnd: w.HWND) !Image {
    var r: w.RECT = .{};
    _ = w.GetWindowRect(hwnd, &r);
    return self.grab(r.right - r.left, r.bottom - r.top, .{ .print = hwnd });
}

/// A window's client area as it last painted it with GDI, read from its
/// device context: current even where DWM hasn't composed it again (an
/// off-screen window on a still screen), but without what OpenGL drew.
pub fn captureClient(self: *Harness, hwnd: w.HWND) !Image {
    var r: w.RECT = .{};
    _ = w.GetClientRect(hwnd, &r);
    return self.grab(r.right, r.bottom, .{ .client = hwnd });
}

/// What the screen shows in `rect` (screen pixels): windows there as DWM
/// composed them, over whatever is behind them. Only for `.onscreen`.
pub fn captureScreen(self: *Harness, rect: w.RECT) !Image {
    return self.grab(rect.right - rect.left, rect.bottom - rect.top, .{ .screen = .{ .x = rect.left, .y = rect.top } });
}

/// What the display shows in `rect` (screen pixels on the primary
/// monitor), through DXGI desktop duplication (dda.zig). Unlike
/// captureScreen (GDI) it sees what a driver presents outside the window's
/// GDI surface. Only for `.onscreen`.
pub fn captureDisplay(self: *Harness, rect: w.RECT) !Image {
    const width = rect.right - rect.left;
    const height = rect.bottom - rect.top;
    if (width <= 0 or height <= 0) return error.CaptureFailed;
    const pixels = try self.alloc.alloc(u32, @intCast(width * height));
    errdefer self.alloc.free(pixels);
    // Duplication hands over a frame only once DWM presents one, which a
    // still screen never does: a 1 x 1 window just past the area's corner
    // changes color meanwhile.
    var ticker = try Backdrop.create(.{ .left = rect.right, .top = rect.bottom, .right = rect.right + 1, .bottom = rect.bottom + 1 }, 0);
    defer ticker.destroy();
    const Tick = struct {
        ticker: *Backdrop,
        n: u32 = 0,
        fn tick(t: *@This()) void {
            t.n +%= 1;
            _ = t.ticker.fill(if (t.n % 2 == 0) 0x000000 else 0x010101);
        }
    };
    var tick: Tick = .{ .ticker = &ticker };
    dda.capture(rect, pixels, &tick, Tick.tick) catch |err| switch (err) {
        // Nothing to read without a monitor that is on: not the build's
        // fault (2026-10-27: Windows listed the monitor as off line).
        error.NoDisplayFrames => return self.skip("no monitor shows the desktop (DWM presented no frame in 10 s): it is off or on another input", .{}),
        else => return err,
    };
    return .{ .alloc = self.alloc, .width = @intCast(width), .height = @intCast(height), .pixels = pixels };
}

fn grab(self: *Harness, width: c_int, height: c_int, source: union(enum) { window: w.HWND, print: w.HWND, client: w.HWND, screen: w.POINT }) !Image {
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
    const ok = switch (source) {
        .window => |hwnd| w.PrintWindow(hwnd, dc, w.PW_RENDERFULLCONTENT),
        .print => |hwnd| w.PrintWindow(hwnd, dc, 0),
        .client => |hwnd| client: {
            const src = w.GetDC(hwnd) orelse return error.CaptureFailed;
            defer _ = w.ReleaseDC(hwnd, src);
            break :client w.BitBlt(dc, 0, 0, width, height, src, 0, 0, w.SRCCOPY);
        },
        .screen => |at| w.BitBlt(dc, 0, 0, width, height, screen, at.x, at.y, w.SRCCOPY | w.CAPTUREBLT),
    };
    if (ok == 0) return error.CaptureFailed;

    const n: usize = @intCast(width * height);
    const src: [*]const u32 = @ptrCast(@alignCast(bits orelse return error.CaptureFailed));
    const pixels = try self.alloc.alloc(u32, n);
    @memcpy(pixels, src[0..n]);
    return .{ .alloc = self.alloc, .width = @intCast(width), .height = @intCast(height), .pixels = pixels };
}

/// A solid window to put behind an `.onscreen` Ghostty, for transparency
/// checks. It is topmost, never activates, and is a layered window filled
/// once, so it needs no painting. Put it under the Ghostty (SetWindowPos
/// after it): a background harness can't raise the Ghostty over it.
pub const Backdrop = struct {
    hwnd: w.HWND,
    rect: w.RECT,

    /// Cover `rect` (screen pixels) with `rgb` (0xRRGGBB).
    pub fn create(rect: w.RECT, rgb: u32) !Backdrop {
        const width = rect.right - rect.left;
        const height = rect.bottom - rect.top;
        const hwnd = w.CreateWindowExW(
            w.WS_EX_LAYERED | w.WS_EX_TOPMOST | w.WS_EX_TOOLWINDOW | w.WS_EX_NOACTIVATE,
            w.L("STATIC"),
            w.L(""),
            w.WS_POPUP,
            rect.left,
            rect.top,
            width,
            height,
            null,
            null,
            w.GetModuleHandleW(null),
            null,
        ) orelse return error.LaunchFailed;
        var self: Backdrop = .{ .hwnd = hwnd, .rect = rect };
        errdefer self.destroy();
        if (!self.fill(rgb)) return error.LaunchFailed;
        _ = w.ShowWindow(hwnd, w.SW_SHOWNOACTIVATE);
        return self;
    }

    /// Fill it with `rgb`. Returns whether that worked.
    pub fn fill(self: *Backdrop, rgb: u32) bool {
        return self.fillStripes(rgb, rgb, 1);
    }

    /// Fill it with upright stripes `period` pixels wide, `a` then `b`
    /// from the left (for blur checks). Returns whether that worked.
    pub fn fillStripes(self: *Backdrop, a: u32, b: u32, period: u32) bool {
        const rect = self.rect;
        const width = rect.right - rect.left;
        const height = rect.bottom - rect.top;
        const screen = w.GetDC(null) orelse return false;
        defer _ = w.ReleaseDC(null, screen);
        const dc = w.CreateCompatibleDC(screen) orelse return false;
        defer _ = w.DeleteDC(dc);
        var bits: ?*anyopaque = null;
        const bmi: w.BITMAPINFOHEADER = .{ .biWidth = width, .biHeight = -height };
        const bmp = w.CreateDIBSection(dc, &bmi, w.DIB_RGB_COLORS, &bits, null, 0) orelse return false;
        defer _ = w.DeleteObject(bmp);
        const old = w.SelectObject(dc, bmp);
        defer if (old) |o| {
            _ = w.SelectObject(dc, o);
        };
        const px: [*]u32 = @ptrCast(@alignCast(bits orelse return false));
        const wd: usize = @intCast(width);
        for (px[0..@intCast(width * height)], 0..) |*p, i| {
            const stripe = (i % wd) / @max(period, 1);
            p.* = 0xFF000000 | (if (stripe % 2 == 0) a else b);
        }
        const pos: w.POINT = .{ .x = rect.left, .y = rect.top };
        const size: w.SIZE = .{ .cx = width, .cy = height };
        const origin: w.POINT = .{};
        const blend: w.BLENDFUNCTION = .{};
        return w.UpdateLayeredWindow(self.hwnd, screen, &pos, &size, dc, &origin, 0, &blend, w.ULW_ALPHA) != 0;
    }

    pub fn destroy(self: *Backdrop) void {
        _ = w.DestroyWindow(self.hwnd);
    }
};

/// Wait `ms`, handling this thread's window messages (a Backdrop's)
/// meanwhile.
pub fn pump(self: *const Harness, ms: u32) void {
    _ = self;
    var waited: u32 = 0;
    while (waited < ms) : (waited += 10) {
        var msg: w.MSG = undefined;
        while (w.PeekMessageW(&msg, null, 0, 0, w.PM_REMOVE) != 0) _ = w.DispatchMessageW(&msg);
        w.Sleep(10);
    }
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

/// Put `paths` on the clipboard as Explorer's copy does (CF_HDROP: a
/// DROPFILES header, then the paths in UTF-16, double-NUL-terminated).
pub fn setClipboardFiles(self: *Harness, paths: []const []const u8) !void {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(self.alloc);
    // DROPFILES: pFiles (the list's offset), pt, fNC, fWide.
    const header = [_]u32{ 20, 0, 0, 0, 1 };
    try data.appendSlice(self.alloc, std.mem.sliceAsBytes(&header));
    for (paths) |path| {
        const p16 = try std.unicode.utf8ToUtf16LeAllocZ(self.alloc, path);
        defer self.alloc.free(p16);
        try data.appendSlice(self.alloc, std.mem.sliceAsBytes(p16[0 .. p16.len + 1]));
    }
    try data.appendSlice(self.alloc, &.{ 0, 0 });
    try openClipboard();
    defer _ = w.CloseClipboard();
    _ = w.EmptyClipboard();
    setClipboardData(15, data.items);
    excludeFromHistory();
}

/// Empty the clipboard.
pub fn clearClipboard(self: *Harness) !void {
    _ = self;
    try openClipboard();
    defer _ = w.CloseClipboard();
    _ = w.EmptyClipboard();
}

/// Drop what the clipboard holds on the first window's active pane,
/// through its drop target (dump wparam 17); the effect (1 a copy, 0
/// refused, -1 no drop target).
/// Have the first window's active pane export its inspector's Terminal IO
/// events (roadmap 5.12), as the inspector's Export button does: through
/// the core's export_terminal_io action (dump wparam 18).
pub fn exportTerminalIo(self: *Harness, g: *const Ghostty) !void {
    var d = try self.dumpWith(g, 18, 0);
    d.deinit();
}

pub fn dropClipboard(self: *Harness, g: *const Ghostty) !i32 {
    var d = try self.dumpWith(g, 17, 0);
    defer d.deinit();
    return d.value.drop_effect;
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

/// The clipboard held open by another thread (see holdClipboard).
pub const ClipboardHold = struct {
    thread: w.HANDLE,

    /// Wait for the thread to let the clipboard go.
    pub fn wait(self: *ClipboardHold) void {
        _ = w.WaitForSingleObject(self.thread, 10000);
        _ = w.CloseHandle(self.thread);
    }
};

/// Hold the clipboard open for `ms` from another thread, as a clipboard
/// manager or clipboard history does for a moment. Returns once it is
/// held. (Harness.key waits until murrtty has handled a key, so the hold
/// can't be on this thread.)
pub fn holdClipboard(self: *Harness, ms: w.DWORD) !ClipboardHold {
    const Ctx = struct {
        ms: w.DWORD,
        /// 0 starting, 1 held, 2 couldn't open it.
        state: std.atomic.Value(u8) = .init(0),

        fn run(p: ?*anyopaque) callconv(.winapi) w.DWORD {
            const ctx: *@This() = @ptrCast(@alignCast(p.?));
            // The caller's frame may be gone once the state is set.
            const hold = ctx.ms;
            const opened = w.OpenClipboard(null) != 0;
            ctx.state.store(if (opened) 1 else 2, .release);
            if (!opened) return 1;
            w.Sleep(hold);
            _ = w.CloseClipboard();
            return 0;
        }
    };
    var ctx: Ctx = .{ .ms = ms };
    const thread = w.CreateThread(null, 0, Ctx.run, &ctx, 0, null) orelse return self.fail("no thread to hold the clipboard", .{});
    var waited: u32 = 0;
    while (ctx.state.load(.acquire) == 0 and waited < 5000) : (waited += 1) w.Sleep(1);
    if (ctx.state.load(.acquire) != 1) {
        _ = w.WaitForSingleObject(thread, 5000);
        _ = w.CloseHandle(thread);
        return self.fail("couldn't hold the clipboard open", .{});
    }
    return .{ .thread = thread };
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
