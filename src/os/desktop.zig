const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const global = @import("../global.zig");

const c = @import("posix_c");

/// Returns true if the program was launched from a desktop environment.
///
/// On macOS, this returns true if the program was launched from Finder.
///
/// On Linux GTK, this returns true if the program was launched using the
/// desktop file. This also includes when `gtk-launch` is used because I
/// can't find a way to distinguish the two scenarios.
///
/// For other platforms and app runtimes, this returns false.
pub fn launchedFromDesktop() bool {
    return switch (builtin.target.os.tag) {
        // macOS apps launched from finder or `open` always have the init
        // process as their parent.
        .macos => macos: {
            // This special case is so that if we launch the app via the
            // app bundle (i.e. via open) then we still treat it as if it
            // was launched from the desktop.
            if (build_config.artifact == .lib) lib: {
                const env = "GHOSTTY_MAC_LAUNCH_SOURCE";
                const source = global.environ().getPosix(env) orelse break :lib;

                // Source can be "app", "cli", or "zig_run". We assume
                // its the desktop only if its "app". We may want to do
                // "zig_run" but at the moment there's no reason.
                if (std.mem.eql(u8, source, "app")) break :macos true;
            }

            break :macos c.getppid() == 1;
        },

        // On Linux and BSD, GTK sets GIO_LAUNCHED_DESKTOP_FILE and
        // GIO_LAUNCHED_DESKTOP_FILE_PID. We only check the latter to see if
        // we match the PID and assume that if we do, we were launched from
        // the desktop file. Pid comparing catches the scenario where
        // another terminal was launched from a desktop file and then launches
        // Ghostty and Ghostty inherits the env.
        .linux, .freebsd => ul: {
            const gio_pid_str = global.environ().getPosix("GIO_LAUNCHED_DESKTOP_FILE_PID") orelse
                break :ul false;

            const pid = c.getpid();
            const gio_pid = std.fmt.parseInt(
                @TypeOf(pid),
                gio_pid_str,
                10,
            ) catch break :ul false;

            break :ul gio_pid == pid;
        },

        .windows => windows.launchedFromDesktop(),

        // iPhone/iPad is always launched from the "desktop"
        .ios => true,

        else => @compileError("unsupported platform"),
    };
}

/// Windows: launched through a shortcut (the Start menu, a pinned or desktop
/// shortcut) or by Explorer itself (a double-click, the Run dialog).
/// Anything else, a shell above all, counts as the command line.
const windows = struct {
    const DWORD = u32;
    const BOOL = c_int;
    const HANDLE = *anyopaque;

    const STARTF_TITLEISLINKNAME = 0x00000800;
    const TH32CS_SNAPPROCESS = 0x00000002;
    const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));

    const STARTUPINFOW = extern struct {
        cb: DWORD = @sizeOf(STARTUPINFOW),
        lpReserved: ?[*:0]u16 = null,
        lpDesktop: ?[*:0]u16 = null,
        lpTitle: ?[*:0]u16 = null,
        dwX: DWORD = 0,
        dwY: DWORD = 0,
        dwXSize: DWORD = 0,
        dwYSize: DWORD = 0,
        dwXCountChars: DWORD = 0,
        dwYCountChars: DWORD = 0,
        dwFillAttribute: DWORD = 0,
        dwFlags: DWORD = 0,
        wShowWindow: u16 = 0,
        cbReserved2: u16 = 0,
        lpReserved2: ?*u8 = null,
        hStdInput: ?HANDLE = null,
        hStdOutput: ?HANDLE = null,
        hStdError: ?HANDLE = null,
    };

    const PROCESSENTRY32W = extern struct {
        dwSize: DWORD = @sizeOf(PROCESSENTRY32W),
        cntUsage: DWORD = 0,
        th32ProcessID: DWORD = 0,
        th32DefaultHeapID: usize = 0,
        th32ModuleID: DWORD = 0,
        cntThreads: DWORD = 0,
        th32ParentProcessID: DWORD = 0,
        pcPriClassBase: c_long = 0,
        dwFlags: DWORD = 0,
        szExeFile: [260]u16 = @splat(0),
    };

    comptime {
        if (@sizeOf(usize) == 8) {
            std.debug.assert(@sizeOf(STARTUPINFOW) == 104);
            std.debug.assert(@sizeOf(PROCESSENTRY32W) == 568);
        }
    }

    extern "kernel32" fn GetStartupInfoW(*STARTUPINFOW) callconv(.winapi) void;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
    extern "kernel32" fn CreateToolhelp32Snapshot(DWORD, DWORD) callconv(.winapi) HANDLE;
    extern "kernel32" fn Process32FirstW(HANDLE, *PROCESSENTRY32W) callconv(.winapi) BOOL;
    extern "kernel32" fn Process32NextW(HANDLE, *PROCESSENTRY32W) callconv(.winapi) BOOL;
    extern "kernel32" fn CloseHandle(HANDLE) callconv(.winapi) BOOL;

    /// 0 until worked out, then 1 (no) or 2 (yes). The answer can't change,
    /// and config finalization asks on every load.
    var cached: std.atomic.Value(u8) = .init(0);

    fn launchedFromDesktop() bool {
        switch (cached.load(.monotonic)) {
            1 => return false,
            2 => return true,
            else => {},
        }
        const yes = detect();
        cached.store(if (yes) 2 else 1, .monotonic);
        return yes;
    }

    fn detect() bool {
        var si: STARTUPINFOW = .{};
        GetStartupInfoW(&si);
        if (si.dwFlags & STARTF_TITLEISLINKNAME != 0) return true;
        return parentIsExplorer();
    }

    fn parentIsExplorer() bool {
        const snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snap == INVALID_HANDLE_VALUE) return false;
        defer _ = CloseHandle(snap);

        // Find our parent, then its image name. (Its process id may have
        // been reused if it exited, which at worst picks the wrong default
        // directory.)
        const me = GetCurrentProcessId();
        var parent: ?DWORD = null;
        var entry: PROCESSENTRY32W = .{};
        var ok = Process32FirstW(snap, &entry) != 0;
        while (ok) : (ok = Process32NextW(snap, &entry) != 0) {
            if (entry.th32ProcessID == me) {
                parent = entry.th32ParentProcessID;
                break;
            }
        }
        const ppid = parent orelse return false;
        entry = .{};
        ok = Process32FirstW(snap, &entry) != 0;
        while (ok) : (ok = Process32NextW(snap, &entry) != 0) {
            if (entry.th32ProcessID != ppid) continue;
            const name = std.mem.sliceTo(&entry.szExeFile, 0);
            const explorer = std.unicode.utf8ToUtf16LeStringLiteral("explorer.exe");
            if (name.len != explorer.len) return false;
            for (name, explorer) |a, b| {
                const lower = if (a >= 'A' and a <= 'Z') a + 32 else a;
                if (lower != b) return false;
            }
            return true;
        }
        return false;
    }
};

/// The list of desktop environments that we detect. New Linux desktop
/// environments should only be added to this list if there's a specific reason
/// to differentiate between `gnome` and `other`.
pub const DesktopEnvironment = enum {
    gnome,
    macos,
    other,
    windows,
};

/// Detect what desktop environment we are running under. This is mainly used
/// on Linux and BSD to enable or disable certain features but there may be more uses in
/// the future.
pub fn desktopEnvironment(environ_map: *const std.process.Environ.Map) DesktopEnvironment {
    return switch (comptime builtin.target.os.tag) {
        .macos => .macos,
        .windows => .windows,
        .linux, .freebsd => de: {
            if (@inComptime()) @compileError("Checking for the desktop environment on Linux/BSD must be done at runtime.");

            // Use $XDG_SESSION_DESKTOP to determine what DE we are using on Linux
            // https://www.freedesktop.org/software/systemd/man/latest/pam_systemd.html#desktop=
            if (environ_map.get("XDG_SESSION_DESKTOP")) |sd| {
                if (std.ascii.eqlIgnoreCase("gnome", sd)) break :de .gnome;
                if (std.ascii.eqlIgnoreCase("gnome-xorg", sd)) break :de .gnome;
            }

            // If $XDG_SESSION_DESKTOP is not set, or doesn't match any known
            // DE, check $XDG_CURRENT_DESKTOP. $XDG_CURRENT_DESKTOP is a
            // colon-separated list of up to three desktop names, although we
            // only look at the first.
            // https://specifications.freedesktop.org/desktop-entry-spec/latest/recognized-keys.html
            if (environ_map.get("XDG_CURRENT_DESKTOP")) |cd| {
                var cd_it = std.mem.splitScalar(u8, cd, ':');
                const cd_first = cd_it.first();
                if (std.ascii.eqlIgnoreCase(cd_first, "gnome")) break :de .gnome;
            }

            break :de .other;
        },
        else => .other,
    };
}

test "desktop environment" {
    const testing = std.testing;

    // Always run these tests with a blank evironment map so that we don't get any
    // failures from values in the "real" evironment leaking in.
    switch (builtin.target.os.tag) {
        inline .macos, .windows => |tag| {
            var environ_map: std.process.Environ.Map = .init(testing.allocator);
            defer environ_map.deinit();
            try testing.expectEqual(@tagName(tag), @tagName(desktopEnvironment(&environ_map)));
        },
        .linux, .freebsd => {
            {
                var environ_map: std.process.Environ.Map = .init(testing.allocator);
                defer environ_map.deinit();
                try environ_map.put("XDG_SESSION_DESKTOP", "gnome");
                try testing.expectEqual(.gnome, desktopEnvironment(&environ_map));
            }

            {
                var environ_map: std.process.Environ.Map = .init(testing.allocator);
                defer environ_map.deinit();
                try environ_map.put("XDG_SESSION_DESKTOP", "gnome-xorg");
                try testing.expectEqual(.gnome, desktopEnvironment(&environ_map));
            }

            {
                var environ_map: std.process.Environ.Map = .init(testing.allocator);
                defer environ_map.deinit();
                try environ_map.put("XDG_SESSION_DESKTOP", "foobar");
                try testing.expectEqual(.other, desktopEnvironment(&environ_map));
            }

            {
                var environ_map: std.process.Environ.Map = .init(testing.allocator);
                defer environ_map.deinit();
                try environ_map.put("XDG_CURRENT_DESKTOP", "GNOME");
                try testing.expectEqual(.gnome, desktopEnvironment(&environ_map));
            }

            {
                var environ_map: std.process.Environ.Map = .init(testing.allocator);
                defer environ_map.deinit();
                try environ_map.put("XDG_CURRENT_DESKTOP", "FOOBAR");
                try testing.expectEqual(.other, desktopEnvironment(&environ_map));
            }

            {
                var environ_map: std.process.Environ.Map = .init(testing.allocator);
                defer environ_map.deinit();
                try testing.expectEqual(.other, desktopEnvironment(&environ_map));
            }
        },
        else => try testing.expectEqual(.other, DesktopEnvironment()),
    }
}
