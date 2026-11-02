//! murrtty's software OpenGL (roadmap 6.3b): Mesa's llvmpipe, built from
//! source by murr2k/murrtty-mesa and installed in bin\mesa, for a machine
//! whose own OpenGL has no 4.3 (Remote Desktop without the graphics card,
//! a virtual machine without 3D, Windows' basic display adapter, an old
//! driver).
//!
//! A process can't change its opengl32 once loaded (gdi32 routes pixel
//! formats and SwapBuffers to the module of that name), so a murrtty whose
//! first window finds no OpenGL 4.3 starts itself again on Mesa (`relaunch`)
//! and waits until that one has presented a frame, then ends. The new one
//! takes `variable` at start (`take`), so nothing it starts sees it, loads
//! Mesa (wgl.useBundled), watches for its first frame (`tick`) and then
//! says once that it draws in software (`notice`). If Mesa can't draw
//! either, the first murrtty says why its graphics can't (gl_diagnosis),
//! as it would without Mesa; one no longer waiting leaves it to the second
//! (`tellFailed`).
const std = @import("std");
const wgl = @import("opengl").wgl;

const c = @import("c.zig");
const App = @import("App.zig");
const Session = @import("Session.zig");
const Surface = @import("Surface.zig");
const gl_diagnosis = @import("gl_diagnosis.zig");
const test_hooks = @import("test_hooks.zig");

const log = std.log.scoped(.software_gl);
const L = std.unicode.utf8ToUtf16LeStringLiteral;

/// Set for the murrtty started on Mesa, as `<kind> <events> <pid>
/// <skipped>`: why the graphics driver's OpenGL didn't do (a
/// gl_diagnosis.Kind), the name its events start with (`-` for none:
/// `<events>-ready` once it has drawn, `<events>-failed` if Mesa can't,
/// `<events>-gone` once the waiting murrtty no longer waits), the waiting
/// murrtty's process id, and whether that one put the saved session aside
/// (1: its last start crashed restoring it). ASCII.
pub const variable = "MURRTTY_SOFTWARE_GL";

/// How long the first murrtty waits for the second's first frame. Past it,
/// the second is taken to be starting slowly and the first ends anyway.
const wait_ms = 60_000;

/// The wakeup window's timer watching for the first frame (`tick`).
pub const timer_id = 0x56A1;
const watch_ms = 50;

/// What the murrtty started on Mesa was told (`take`).
pub const Started = struct {
    /// Why the graphics driver's OpenGL didn't do, for `notice`.
    kind: gl_diagnosis.Kind = .unknown,
    ready_event: ?c.HANDLE = null,
    failed_event: ?c.HANDLE = null,
    /// Set by the waiting murrtty once it no longer waits.
    gone_event: ?c.HANDLE = null,
    /// The murrtty waiting for this one (SYNCHRONIZE), to tell whether it
    /// still runs.
    parent: ?c.HANDLE = null,
    /// When the watch for the first frame began (GetTickCount64).
    watch_since: u64 = 0,
    /// The waiting murrtty put the session aside (Session.load).
    session_skipped: bool = false,
    /// Mesa is what OpenGL loads. Without it (no bin\mesa) this murrtty
    /// still never starts another.
    bundled: bool = false,
    /// Ready or failed was told.
    told: bool = false,
};

/// Mesa's opengl32.dll in bin\mesa, NUL-terminated: what wgl.useBundled
/// keeps a pointer to.
var path_buf: [4096]u16 = undefined;

/// The full path of Mesa's opengl32.dll beside the executable, if it and
/// its gallium DLL are there. The GUI tests stand in for an install
/// without it (GHOSTTY_WIN32_TEST_NO_MESA).
fn bundledPath() ?[*:0]const u16 {
    if (comptime test_hooks.enabled) if (test_hooks.active() and
        c.GetEnvironmentVariableW(L("GHOSTTY_WIN32_TEST_NO_MESA"), null, 0) != 0) return null;
    const n = c.GetModuleFileNameW(null, &path_buf, path_buf.len);
    if (n == 0 or n >= path_buf.len) return null;
    const dir = (std.mem.lastIndexOfScalar(u16, path_buf[0..n], '\\') orelse return null) + 1;
    for ([_][]const u16{ L("mesa\\libgallium_wgl.dll"), L("mesa\\opengl32.dll") }) |name| {
        if (dir + name.len >= path_buf.len) return null;
        @memcpy(path_buf[dir..][0..name.len], name);
        path_buf[dir + name.len] = 0;
        const attrs = c.GetFileAttributesW(@ptrCast(&path_buf));
        if (attrs == c.INVALID_FILE_ATTRIBUTES or attrs & c.FILE_ATTRIBUTE_DIRECTORY != 0) return null;
    }
    // The last written: opengl32.dll.
    return @ptrCast(&path_buf);
}

/// At start (App.init), before anything loads OpenGL: whether this murrtty
/// was started on Mesa, clearing `variable` so nothing it starts sees it,
/// and if so, Mesa is what OpenGL loads.
pub fn take() ?Started {
    var buf: [256]u16 = undefined;
    const n = c.GetEnvironmentVariableW(L(variable), &buf, buf.len);
    if (n == 0) return null;
    _ = c.SetEnvironmentVariableW(L(variable), null);
    var started: Started = .{};
    if (bundledPath()) |path| {
        wgl.useBundled(path);
        started.bundled = true;
        log.info("started on murrtty's software OpenGL (Mesa)", .{});
    } else log.warn("{s} is set, but there is no Mesa in bin\\mesa", .{variable});
    if (n >= buf.len) return started;

    // ASCII, as `relaunch` writes it; anything else is no one's message.
    var text_buf: [256]u8 = undefined;
    for (buf[0..n], text_buf[0..n]) |unit, *ch| {
        if (unit < 0x20 or unit > 0x7e) return started;
        ch.* = @intCast(unit);
    }
    var it = std.mem.tokenizeScalar(u8, text_buf[0..n], ' ');
    started.kind = std.meta.stringToEnum(gl_diagnosis.Kind, it.next() orelse "") orelse .unknown;
    const events = it.next() orelse "-";
    const pid = std.fmt.parseInt(c.DWORD, it.next() orelse "", 10) catch 0;
    started.session_skipped = std.mem.eql(u8, it.next() orelse "", "1");
    if (!std.mem.eql(u8, events, "-")) {
        started.ready_event = openEvent(events, "-ready");
        started.failed_event = openEvent(events, "-failed");
        started.gone_event = openEvent(events, "-gone");
    }
    if (pid != 0) started.parent = c.OpenProcess(c.SYNCHRONIZE, c.FALSE, pid);
    return started;
}

fn openEvent(base: []const u8, suffix: []const u8) ?c.HANDLE {
    var name: [128:0]u16 = undefined;
    _ = eventName(&name, base, suffix) orelse return null;
    return c.OpenEventW(c.EVENT_MODIFY_STATE | c.SYNCHRONIZE, c.FALSE, &name);
}

/// `base` and `suffix` as a NUL-terminated UTF-16 name, null if too long.
fn eventName(out: *[128:0]u16, base: []const u8, suffix: []const u8) ?usize {
    if (base.len + suffix.len > out.len) return null;
    var len: usize = 0;
    for ([_][]const u8{ base, suffix }) |part| for (part) |ch| {
        out[len] = ch;
        len += 1;
    };
    out[len] = 0;
    return len;
}

/// After run() has its first window: watch for the first frame.
pub fn startWatch(app: *App) void {
    if (app.software_start) |*s| s.watch_since = c.GetTickCount64();
    _ = c.SetTimer(app.wakeup_hwnd, timer_id, watch_ms, null);
}

/// The watch: the first frame any pane presents tells the waiting murrtty
/// it can end and shows the notice (with a session put aside, that
/// notice too: one toast); a renderer failing before any frame, or none
/// presented in `wait_ms` while a window shows, is Mesa failing, and this
/// murrtty quits.
pub fn tick(app: *App) void {
    const started = if (app.software_start) |*s| s else {
        _ = c.KillTimer(app.wakeup_hwnd, timer_id);
        return;
    };
    var unhealthy = false;
    for (app.core_app.surfaces.items) |surface| {
        if (!surface.core_initialized) continue;
        if (surface.core_surface.renderer.api.present_state.presented.load(.monotonic) > 0) {
            _ = c.KillTimer(app.wakeup_hwnd, timer_id);
            for (app.windows.items) |w| {
                if (w.quick != null or w.tabs.items.len == 0) continue;
                var skip_buf: [400]u8 = undefined;
                var both_buf: [600]u8 = undefined;
                const text = if (app.session.takeSkipNotice(&skip_buf)) |skip|
                    std.fmt.bufPrint(&both_buf, "{s} {s}", .{ notice(started.kind), skip }) catch skip
                else
                    notice(started.kind);
                w.showToastFor(text, Session.notice_ms);
                break;
            }
            ready(started);
            return;
        }
        if (surface.renderer_unhealthy) unhealthy = true;
    }
    if (!unhealthy and c.GetTickCount64() -| started.watch_since > wait_ms) {
        // Only while a window can be drawn: a minimized start presents
        // nothing until it is restored.
        for (app.windows.items) |w| {
            if (c.IsWindowVisible(w.hwnd) != 0 and c.IsIconic(w.hwnd) == 0) unhealthy = true;
        }
    }
    if (unhealthy) {
        _ = c.KillTimer(app.wakeup_hwnd, timer_id);
        log.err("murrtty's software OpenGL failed before drawing a frame", .{});
        if (!failed(started)) tellFailed(app, started.kind, error.RendererFailed);
        app.quitNow();
    }
}

/// murrtty quits: no watch through its teardown's messages.
pub fn stopWatch(app: *App) void {
    _ = c.KillTimer(app.wakeup_hwnd, timer_id);
}

/// The murrtty started on Mesa has drawn: the one that started it can end.
pub fn ready(started: *Started) void {
    if (started.told) return;
    started.told = true;
    if (started.ready_event) |e| _ = c.SetEvent(e);
    close(started);
}

/// Mesa can't draw: whether the waiting murrtty was told (it then says
/// so); false when none waits any more, and the caller says it. Set
/// before looking for `-gone`, which the waiting one sets before looking
/// for `-failed` a last time: at worst both say it.
pub fn failed(started: *Started) bool {
    if (started.told) return true;
    started.told = true;
    defer close(started);
    const event = started.failed_event orelse return false;
    const parent = started.parent orelse return false;
    if (c.WaitForSingleObject(parent, 0) != c.WAIT_TIMEOUT) return false;
    if (c.SetEvent(event) == 0) return false;
    if (started.gone_event) |gone| if (c.WaitForSingleObject(gone, 0) == c.WAIT_OBJECT_0) return false;
    return true;
}

fn close(started: *Started) void {
    for ([_]*?c.HANDLE{ &started.ready_event, &started.failed_event, &started.gone_event, &started.parent }) |h| {
        if (h.*) |handle| _ = c.CloseHandle(handle);
        h.* = null;
    }
}

/// Mesa failed with no murrtty waiting to say why: say it here.
pub fn tellFailed(app: *App, kind: gl_diagnosis.Kind, err: anyerror) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s}\n\n{s}\n\nmurrtty's software renderer (Mesa, in the mesa folder beside murrtty.exe) couldn't draw either ({t}).\n\nTo see murrtty's log, start it from a shell with: murrtty.exe 2> murrtty.log", .{
        gl_diagnosis.heading,
        reason(kind),
        err,
    }) catch gl_diagnosis.heading;
    _ = Surface.messageBox(app.core_app.alloc, null, msg, "murrtty", c.MB_OK | c.MB_ICONERROR);
}

fn reason(kind: gl_diagnosis.Kind) []const u8 {
    return switch (kind) {
        .remote => "This Remote Desktop session offers no OpenGL 4.3.",
        .basic_adapter => "The graphics card's driver isn't installed.",
        .no_driver => "The graphics driver offers no OpenGL.",
        .old_driver => "The graphics driver's OpenGL is older than 4.3.",
        .library, .unknown => "The graphics driver's OpenGL couldn't be used.",
    };
}

/// The notice the murrtty on Mesa shows in its first window: it draws in
/// software, and why.
pub fn notice(kind: gl_diagnosis.Kind) []const u8 {
    return switch (kind) {
        .remote => "This Remote Desktop session offers no OpenGL 4.3: murrtty draws with its software renderer (Mesa).",
        .basic_adapter => "The graphics card's driver isn't installed: murrtty draws with its software renderer (Mesa).",
        .no_driver => "The graphics driver offers no OpenGL: murrtty draws with its software renderer (Mesa).",
        .old_driver => "The graphics driver's OpenGL is older than 4.3: murrtty draws with its software renderer (Mesa).",
        .library, .unknown => "The graphics driver's OpenGL couldn't be used: murrtty draws with its software renderer (Mesa).",
    };
}

pub const Outcome = enum {
    /// No Mesa, or this murrtty already runs on it or on MURRTTY_OPENGL's.
    unavailable,
    /// The murrtty started on Mesa has drawn (or ended well, having handed
    /// its window to a murrtty already running): this one ends.
    took_over,
    /// Mesa couldn't draw either (it said so, crashed or panicked): this
    /// one says why, and that Mesa couldn't help.
    failed,
    /// murrtty couldn't be started again: this one says why its graphics
    /// can't draw, as without Mesa.
    not_started,
    /// The murrtty started on Mesa failed otherwise and said so itself
    /// (run() returned an error after its own message: exit 1): this one
    /// ends with an error, saying nothing more.
    ended,
};

/// The first window found no OpenGL 4.3 (`err`): start murrtty again on
/// Mesa, as this one was started, and wait until it has drawn. Before it
/// starts, this one lets go of what a murrtty holds once (the single
/// instance's pipe went already, App.run): the global hot keys, the tray
/// icon and the session (whose crash marker a failed restore left).
pub fn relaunch(app: *App, err: anyerror) Outcome {
    if (app.software_start != null or wgl.libraryOverridden()) return .unavailable;
    if (wgl.loadedSource()) |source| if (source != .system) return .unavailable;
    if (bundledPath() == null) return .unavailable;

    const kind = gl_diagnosis.diagnose(err);
    log.warn("no OpenGL 4.3 ({t}, {t}): starting murrtty again on its software OpenGL", .{ kind, err });

    const skipped = app.session.skipped;
    app.global_keys.deinit();
    app.notifications.deinit();
    app.session.freeze();

    var exe: [32768]u16 = undefined;
    const exe_len = c.GetModuleFileNameW(null, &exe, exe.len);
    if (exe_len == 0 or exe_len >= exe.len) return .not_started;
    exe[exe_len] = 0;
    // CreateProcessW may write to the command line it is given.
    const given = std.mem.span(c.GetCommandLineW());
    const alloc = app.core_app.alloc;
    const cmd = alloc.dupeSentinel(u16, given, 0) catch return .not_started;
    defer alloc.free(cmd);

    // The events the other sets, named for this process and the moment;
    // if one is there already (made by someone else), none is waited for.
    var base_buf: [64]u8 = undefined;
    const base = std.fmt.bufPrint(&base_buf, "Local\\murrtty-software-gl-{d}-{d}", .{ c.GetCurrentProcessId(), c.GetTickCount64() }) catch return .not_started;
    var events: [3]?c.HANDLE = .{ null, null, null };
    for ([_][]const u8{ "-ready", "-failed", "-gone" }, &events) |suffix, *e| e.* = createEvent(base, suffix);
    // All three or none.
    if (events[0] == null or events[1] == null or events[2] == null) for (&events) |*e| {
        if (e.*) |h| _ = c.CloseHandle(h);
        e.* = null;
    };
    const ready_event = events[0];
    const failed_event = events[1];
    const gone_event = events[2];
    defer for (events) |h| {
        if (h) |e| _ = c.CloseHandle(e);
    };

    var value_buf: [160]u8 = undefined;
    const value = std.fmt.bufPrint(&value_buf, "{t} {s} {d} {d}", .{
        kind,
        if (ready_event != null) base else "-",
        c.GetCurrentProcessId(),
        @intFromBool(skipped),
    }) catch return .not_started;
    var value16: [160:0]u16 = undefined;
    for (value, 0..) |ch, i| value16[i] = ch;
    value16[value.len] = 0;
    // Inherited: the other gets this process's environment.
    _ = c.SetEnvironmentVariableW(L(variable), &value16);
    defer _ = c.SetEnvironmentVariableW(L(variable), null);

    // As this one was started: its window's place and show state, a
    // shortcut's title, the desktop. Its log (redirected stderr) goes on
    // in the same file, its other handles stay this one's.
    var siex: c.STARTUPINFOEXW = .{};
    const si = &siex.StartupInfo;
    c.GetStartupInfoW(si);
    si.cb = @sizeOf(c.STARTUPINFOEXW);
    si.lpReserved = null;
    si.cbReserved2 = 0;
    si.lpReserved2 = null;
    // Not the AppUserModelID this process set (App.init): it shows in the
    // startup info as the title, flagged as the ID and as shell32's own
    // allocation. Passed on, the other's shell32 frees that title, which
    // there lies in the process parameters, as it sets its own ID: heap
    // corruption (0xc0000374), caught or not depending on where the string
    // falls, which the install path's length decides. The other sets the
    // same ID itself.
    if (si.dwFlags & (c.STARTF_TITLEISAPPID | c.STARTF_TITLE_ALLOCATED) != 0) {
        si.dwFlags &= ~@as(c.DWORD, c.STARTF_TITLEISAPPID | c.STARTF_TITLE_ALLOCATED);
        si.lpTitle = null;
    }
    var std_handles: [3]c.HANDLE = undefined;
    var inherit: usize = 0;
    defer for (std_handles[0..inherit]) |h| {
        _ = c.CloseHandle(h);
    };
    // The hot key's and the monitor's flags use the handles' fields.
    if (si.dwFlags & (c.STARTF_USEHOTKEY | c.STARTF_USEMONITOR) == 0) {
        si.dwFlags &= ~@as(c.DWORD, c.STARTF_USESTDHANDLES);
        si.hStdInput = null;
        si.hStdOutput = null;
        si.hStdError = null;
        const fields = [_]*?c.HANDLE{ &si.hStdInput, &si.hStdOutput, &si.hStdError };
        for ([_]c.DWORD{ c.STD_INPUT_HANDLE, c.STD_OUTPUT_HANDLE, c.STD_ERROR_HANDLE }, fields) |which, field| {
            const h = c.GetStdHandle(which) orelse continue;
            if (h == c.INVALID_HANDLE_VALUE) continue;
            var dup: c.HANDLE = undefined;
            if (c.DuplicateHandle(c.GetCurrentProcess(), h, c.GetCurrentProcess(), &dup, 0, c.TRUE, c.DUPLICATE_SAME_ACCESS) == 0) continue;
            std_handles[inherit] = dup;
            inherit += 1;
            field.* = dup;
        }
        if (inherit > 0) si.dwFlags |= c.STARTF_USESTDHANDLES;
    }
    var attr_buf: [128]u8 align(@alignOf(usize)) = undefined;
    var attrs = false;
    if (inherit > 0) {
        var size: usize = 0;
        _ = c.InitializeProcThreadAttributeList(null, 1, 0, &size);
        if (size <= attr_buf.len and c.InitializeProcThreadAttributeList(&attr_buf, 1, 0, &size) != 0) {
            if (c.UpdateProcThreadAttribute(&attr_buf, 0, c.PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &std_handles, inherit * @sizeOf(c.HANDLE), null, null) != 0) {
                siex.lpAttributeList = &attr_buf;
                attrs = true;
            } else c.DeleteProcThreadAttributeList(&attr_buf);
        }
        // Without the list, inheriting would pass every inheritable handle.
        if (!attrs) {
            si.dwFlags &= ~@as(c.DWORD, c.STARTF_USESTDHANDLES);
            si.hStdInput = null;
            si.hStdOutput = null;
            si.hStdError = null;
        }
    }
    defer if (attrs) c.DeleteProcThreadAttributeList(&attr_buf);

    var pi: c.PROCESS_INFORMATION = .{};
    const flags: c.DWORD = c.CREATE_SUSPENDED | @as(c.DWORD, if (attrs) c.EXTENDED_STARTUPINFO_PRESENT else 0);
    if (c.CreateProcessW(@ptrCast(&exe), cmd.ptr, null, null, if (attrs) c.TRUE else c.FALSE, flags, null, null, si, &pi) == 0) {
        log.err("starting murrtty again failed err={}", .{c.GetLastError()});
        return .not_started;
    }
    const proc = pi.hProcess.?;
    defer _ = c.CloseHandle(proc);
    // Its window comes to the front as this one's would have.
    _ = c.AllowSetForegroundWindow(pi.dwProcessId);
    _ = c.ResumeThread(pi.hThread.?);
    _ = c.CloseHandle(pi.hThread.?);

    const outcome = waitFor(proc, ready_event, failed_event);
    // No longer waiting: the other says a failure itself from now on. One
    // set just before this is still seen (it sets, then looks for this).
    if (gone_event) |gone| {
        _ = c.SetEvent(gone);
        if (outcome == .took_over) if (failed_event) |f| if (c.WaitForSingleObject(f, 0) == c.WAIT_OBJECT_0) return .failed;
    }
    return outcome;
}

/// A new event named `base` + `suffix`; null if one was there already.
fn createEvent(base: []const u8, suffix: []const u8) ?c.HANDLE {
    var name: [128:0]u16 = undefined;
    _ = eventName(&name, base, suffix) orelse return null;
    const event = c.CreateEventW(null, c.TRUE, c.FALSE, &name) orelse return null;
    if (c.GetLastError() == c.ERROR_ALREADY_EXISTS) {
        _ = c.CloseHandle(event);
        return null;
    }
    return event;
}

/// Wait for the murrtty on Mesa: its events or its end, with this thread's
/// messages handled meanwhile (OLE's window, a broadcast).
fn waitFor(proc: c.HANDLE, ready_event: ?c.HANDLE, failed_event: ?c.HANDLE) Outcome {
    // The events first: of several signaled together the wait reports the
    // first, and a frame drawn counts even if its murrtty ended since.
    var handles: [3]c.HANDLE = undefined;
    var count: c.DWORD = 0;
    if (ready_event) |e| {
        handles[count] = e;
        count += 1;
    }
    if (failed_event) |e| {
        handles[count] = e;
        count += 1;
    }
    const proc_index = count;
    handles[count] = proc;
    count += 1;
    const until = c.GetTickCount64() + wait_ms;
    while (true) {
        const now = c.GetTickCount64();
        if (now >= until) {
            log.warn("murrtty on its software OpenGL hasn't drawn yet; leaving it to start", .{});
            return .took_over;
        }
        const r = c.MsgWaitForMultipleObjects(count, &handles, c.FALSE, @intCast(until - now), c.QS_ALLINPUT);
        if (ready_event != null and r == c.WAIT_OBJECT_0) {
            log.info("murrtty on its software OpenGL has drawn", .{});
            return .took_over;
        }
        if (failed_event != null and r == c.WAIT_OBJECT_0 + 1) {
            log.err("murrtty's software OpenGL couldn't draw either", .{});
            return .failed;
        }
        if (r == c.WAIT_OBJECT_0 + proc_index) {
            var code: c.DWORD = 0;
            _ = c.GetExitCodeProcess(proc, &code);
            if (code == 0) {
                log.info("murrtty on its software OpenGL ended well (exit 0)", .{});
                return .took_over;
            }
            // 1: run() returned an error after its own message. Anything
            // else, a crash's NTSTATUS (0xC0000374, heap corruption) or a
            // panic's 3, ended it before it could say anything.
            if (code == 1) {
                log.err("murrtty on its software OpenGL ended (exit 1)", .{});
                return .ended;
            }
            log.err("murrtty on its software OpenGL died (exit 0x{x})", .{code});
            return .failed;
        }
        if (r == c.WAIT_OBJECT_0 + count) {
            var msg: c.MSG = undefined;
            while (c.PeekMessageW(&msg, null, 0, 0, c.PM_REMOVE) != 0) {
                // Quitting comes after: this murrtty ends anyway.
                if (msg.message == c.WM_QUIT) continue;
                _ = c.TranslateMessage(&msg);
                _ = c.DispatchMessageW(&msg);
            }
            continue;
        }
        if (r == c.WAIT_TIMEOUT) continue;
        log.err("waiting for murrtty on its software OpenGL failed err={}", .{c.GetLastError()});
        return .took_over;
    }
}

test "eventName" {
    var out: [128:0]u16 = undefined;
    const n = eventName(&out, "Local\\murrtty-software-gl-1-2", "-ready").?;
    try std.testing.expectEqualSlices(u16, L("Local\\murrtty-software-gl-1-2-ready"), out[0..n]);
    try std.testing.expectEqual(@as(u16, 0), out[n]);
    const long: [100]u8 = @splat('a');
    const tail: [40]u8 = @splat('b');
    try std.testing.expect(eventName(&out, &long, &tail) == null);
}
