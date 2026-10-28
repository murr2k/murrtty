//! The single instance (roadmap 5.1). The first murrtty of a user, logon
//! session, integrity level and class listens on a named pipe: `murrtty
//! +new-window` and `+new-tab` send their requests there, and a plain launch
//! hands its window to it (gtk-single-instance), as GTK's D-Bus application
//! does. A client that finds no murrtty starts one for its request.
//!
//! Pipe names are machine-wide. The pipe is created with
//! FILE_FLAG_FIRST_PIPE_INSTANCE, a DACL for its user alone and a mandatory
//! label at its integrity level (nothing lower writes to it), and refuses
//! remote clients. A client checks that the process serving the pipe is its
//! own user's, in its session, at no lower integrity level, before sending:
//! another process could otherwise create the name first and receive what
//! murrtty forwards. Clients connect at identification level, so the server
//! can't act as them.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const cli = @import("../../cli.zig");
const configpkg = @import("../../config.zig");
const global = @import("../../global.zig");
const internal_os = @import("../../os/main.zig");

const c = @import("c.zig");
const jump_list = @import("jump_list.zig");

const log = std.log.scoped(.win32_ipc);

/// Set in the environment of a murrtty a client starts for its request: it
/// opens no window of its own and quits if the request never comes
/// (`launch_timeout_ms`). Never passed on to its shells.
pub const launch_env = "MURRTTY_IPC_LAUNCH";

/// How long a murrtty started for a request waits for it. Longer than a
/// client waits for the pipe (`connect_timeout_ms`).
pub const launch_timeout_ms = 15000;

/// How long a client waits for a busy pipe, or for the murrtty it started.
const connect_timeout_ms = 10000;

/// How long either end waits for the other's message.
const io_timeout_ms = 5000;

/// How often a murrtty that found the name taken tries again, so that it
/// takes over when the one holding it quits.
const retry_ms = 3000;

//---------------------------------------------------------------
// Requests

pub const Kind = enum(u8) {
    new_window = 0,
    new_tab = 1,
    toggle_quick_terminal = 2,
    _,
};

/// The server's one-byte answer.
pub const Reply = enum(u8) {
    /// Queued for the UI thread.
    ok = 0,
    /// Not a request.
    malformed = 1,
    /// A request this murrtty doesn't handle (a newer client's).
    unsupported = 2,
    /// It couldn't be queued.
    failed = 3,
    _,
};

pub const Message = struct {
    kind: Kind,
    /// new_tab's: the pane whose window gets the tab, 0 for the focused one.
    surface_id: u64 = 0,
    /// The new pane's overrides as the CLI passes them (`-e`, `--command=`,
    /// `--working-directory=`, `--title=`, `--shell-integration=`), or null
    /// for none. Never empty when not null, as apprt.ipc has it.
    arguments: ?[]const [:0]const u8 = null,
};

/// "MRTY", a version, the kind, whether there are arguments, a zero byte,
/// the surface id (u64) and the argument count (u32); then each argument as
/// its length (u32) and bytes. Integers are little-endian.
const magic = "MRTY";
const version = 1;
const header_len = 20;
pub const max_message = 256 * 1024;
const max_arguments = 4096;

pub fn encode(alloc: Allocator, msg: Message) (Allocator.Error || error{TooLong})![]u8 {
    const args = msg.arguments orelse &.{};
    if (args.len > max_arguments) return error.TooLong;
    var total: usize = header_len;
    for (args) |a| total += 4 + a.len;
    if (total > max_message) return error.TooLong;

    var out: std.ArrayList(u8) = try .initCapacity(alloc, total);
    errdefer out.deinit(alloc);
    out.appendSliceAssumeCapacity(magic);
    out.appendSliceAssumeCapacity(&[_]u8{ version, @intFromEnum(msg.kind), @intFromBool(msg.arguments != null), 0 });
    appendInt(&out, u64, msg.surface_id);
    appendInt(&out, u32, @intCast(args.len));
    for (args) |a| {
        appendInt(&out, u32, @intCast(a.len));
        out.appendSliceAssumeCapacity(a);
    }
    return out.toOwnedSlice(alloc);
}

fn appendInt(out: *std.ArrayList(u8), comptime T: type, v: T) void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, v, .little);
    out.appendSliceAssumeCapacity(&buf);
}

pub const DecodeError = Allocator.Error || error{ Malformed, Unsupported };

/// The request in `bytes`, its arguments allocated in `arena`.
pub fn decode(arena: Allocator, bytes: []const u8) DecodeError!Message {
    if (bytes.len < header_len or !std.mem.eql(u8, bytes[0..4], magic)) return error.Malformed;
    if (bytes[4] != version) return error.Unsupported;
    const kind: Kind = @enumFromInt(bytes[5]);
    switch (kind) {
        .new_window, .new_tab, .toggle_quick_terminal => {},
        _ => return error.Unsupported,
    }
    const has_arguments = switch (bytes[6]) {
        0 => false,
        1 => true,
        else => return error.Malformed,
    };
    if (bytes[7] != 0) return error.Malformed;
    const surface_id = std.mem.readInt(u64, bytes[8..16], .little);
    if (kind != .new_tab and surface_id != 0) return error.Malformed;
    const count = std.mem.readInt(u32, bytes[16..20], .little);
    if (count > max_arguments or has_arguments != (count > 0)) return error.Malformed;

    const args = try arena.alloc([:0]const u8, count);
    var rest = bytes[header_len..];
    for (args) |*a| {
        if (rest.len < 4) return error.Malformed;
        const len = std.mem.readInt(u32, rest[0..4], .little);
        rest = rest[4..];
        if (len > rest.len) return error.Malformed;
        const text = rest[0..len];
        rest = rest[len..];
        // What the config and a command line take: no NUL, and WTF-8, as
        // Windows' command line converts to.
        if (std.mem.indexOfScalar(u8, text, 0) != null or !std.unicode.wtf8ValidateSlice(text)) return error.Malformed;
        a.* = try arena.dupeSentinel(u8, text, 0);
    }
    if (rest.len != 0) return error.Malformed;
    return .{
        .kind = kind,
        .surface_id = surface_id,
        .arguments = if (has_arguments) args else null,
    };
}

/// A request handed to the UI thread, which frees it (`destroy`).
pub const Received = struct {
    arena: std.heap.ArenaAllocator,
    message: Message,

    pub fn destroy(self: *Received, alloc: Allocator) void {
        self.arena.deinit();
        alloc.destroy(self);
    }
};

//---------------------------------------------------------------
// Overrides

/// What a request changes about its new pane, read from its arguments as
/// GTK's Overrides reads them. Arguments it can't read are skipped, and
/// others ignored, as there.
pub const Overrides = struct {
    command: ?configpkg.Command = null,
    shell_integration: ?configpkg.Config.ShellIntegration = null,
    working_directory: ?configpkg.WorkingDirectory = null,
    title: ?[:0]const u8 = null,

    pub fn parse(arena: Allocator, arguments: []const [:0]const u8) Allocator.Error!Overrides {
        var result: Overrides = .{};
        var command: std.ArrayList([:0]const u8) = .empty;
        var e_seen = false;
        for (arguments) |arg| {
            if (e_seen) {
                try command.append(arena, arg);
                continue;
            }
            if (std.mem.eql(u8, arg, "-e")) {
                e_seen = true;
                continue;
            }
            if (std.mem.cutPrefix(u8, arg, "--command=")) |v| {
                var cmd: configpkg.Command = undefined;
                cmd.parseCLI(arena, v) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        log.warn("ignoring --command={s} err={}", .{ v, err });
                        continue;
                    },
                };
                result.command = cmd;
                continue;
            }
            if (std.mem.cutPrefix(u8, arg, "--shell-integration=")) |v| {
                var parsed: struct {
                    @"shell-integration": ?configpkg.Config.ShellIntegration = null,
                } = .{};
                cli.args.parseIntoField(
                    @TypeOf(parsed),
                    arena,
                    &parsed,
                    "shell-integration",
                    std.mem.trim(u8, v, &std.ascii.whitespace),
                ) catch |err| {
                    log.warn("ignoring --shell-integration={s} err={}", .{ v, err });
                    continue;
                };
                result.shell_integration = parsed.@"shell-integration";
                continue;
            }
            if (std.mem.cutPrefix(u8, arg, "--working-directory=")) |v| {
                // As the config reads it, then resolved as its finalize does:
                // `home` is the home directory and `inherit` the caller's,
                // which the CLI always passes first (GTK takes both as paths).
                var wd: configpkg.WorkingDirectory = .inherit;
                wd.parseCLI(arena, v) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        log.warn("ignoring --working-directory={s} err={}", .{ v, err });
                        continue;
                    },
                };
                switch (wd) {
                    .inherit => continue,
                    .home => wd = .{ .path = homeDir(arena) orelse continue },
                    .path => try wd.finalize(arena),
                }
                result.working_directory = wd;
                continue;
            }
            if (std.mem.cutPrefix(u8, arg, "--title=")) |v| {
                result.title = try arena.dupeSentinel(u8, std.mem.trim(u8, v, &std.ascii.whitespace), 0);
                continue;
            }
        }
        if (command.items.len > 0) result.command = .{ .direct = command.items };
        return result;
    }

    /// Apply to the config a pane is created with. The command gets shell
    /// integration only for a shell it detects, unless one is given, as
    /// GTK's applyCommandOverrides has it; it also wins over the config's
    /// initial-command, which a murrtty started for the request would run
    /// otherwise. The title is the pane's to take (Surface.title_override).
    pub fn apply(self: *const Overrides, config: *configpkg.Config) Allocator.Error!void {
        const alloc = config.arenaAlloc();
        if (self.command) |value| {
            config.command = try value.clone(alloc);
            config.@"initial-command" = null;
            if (self.shell_integration) |integration| {
                config.@"shell-integration" = integration;
            } else if (config.@"shell-integration" != .none) {
                config.@"shell-integration" = .detect;
            }
        } else if (self.shell_integration) |value| {
            config.@"shell-integration" = value;
        }
        if (self.working_directory) |wd| config.@"working-directory" = try wd.clone(alloc);
    }
};

/// The user's home directory, as the config's finalize finds it.
fn homeDir(arena: Allocator) ?[]const u8 {
    var environ_map = global.environMap() catch return null;
    defer environ_map.deinit();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = (internal_os.home(global.io(), &environ_map, &buf) catch return null) orelse return null;
    return arena.dupe(u8, home) catch null;
}

//---------------------------------------------------------------
// The pipe's name and security

/// The longest SID: 8 bytes and 15 subauthorities.
const max_sid = 68;

const Sid = struct {
    bytes: [max_sid]u8 align(4) = undefined,
    len: usize = 0,

    fn slice(self: *const Sid) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// A process's user, logon session and integrity level.
const Identity = struct {
    user: Sid = .{},
    session: u32 = 0,
    /// The integrity level's RID: 0x2000 medium, 0x3000 high.
    integrity: u32 = 0,

    fn of(process: c.HANDLE, pid: u32) error{TokenQuery}!Identity {
        var token: c.HANDLE = undefined;
        if (c.OpenProcessToken(process, c.TOKEN_QUERY, &token) == 0) return error.TokenQuery;
        defer _ = c.CloseHandle(token);
        var self: Identity = .{};
        try tokenSid(token, c.TokenUser, &self.user);
        var label: Sid = .{};
        try tokenSid(token, c.TokenIntegrityLevel, &label);
        self.integrity = lastSubAuthority(label.slice()) orelse return error.TokenQuery;
        if (c.ProcessIdToSessionId(pid, &self.session) == 0) return error.TokenQuery;
        return self;
    }

    fn current() error{TokenQuery}!Identity {
        return of(c.GetCurrentProcess(), c.GetCurrentProcessId());
    }
};

/// The SID a TOKEN_USER or TOKEN_MANDATORY_LABEL names: both start with a
/// SID_AND_ATTRIBUTES, whose SID points into the same buffer.
fn tokenSid(token: c.HANDLE, class: c_int, out: *Sid) error{TokenQuery}!void {
    var buf: [256]u8 align(@alignOf(usize)) = undefined;
    var len: c.DWORD = 0;
    if (c.GetTokenInformation(token, class, &buf, buf.len, &len) == 0) return error.TokenQuery;
    const sid: [*]const u8 = @as(*const [*]const u8, @ptrCast(&buf)).*;
    const n = sidLength(sid[0..2]);
    if (n > max_sid) return error.TokenQuery;
    @memcpy(out.bytes[0..n], sid[0..n]);
    out.len = n;
}

/// A SID's length from its first two bytes (revision, subauthority count).
fn sidLength(head: *const [2]u8) usize {
    return 8 + 4 * @as(usize, head[1]);
}

fn lastSubAuthority(sid: []const u8) ?u32 {
    if (sid.len < 8) return null;
    const count = sid[1];
    if (count == 0 or sid.len < 8 + 4 * @as(usize, count)) return null;
    const at = 8 + 4 * (@as(usize, count) - 1);
    return std.mem.readInt(u32, sid[at..][0..4], .little);
}

/// A SID as text (S-1-5-21-...), as ConvertSidToStringSidW writes it.
fn formatSid(w: *std.Io.Writer, sid: []const u8) std.Io.Writer.Error!void {
    if (sid.len < 8) return;
    const authority = std.mem.readInt(u48, sid[2..8], .big);
    if (authority < 1 << 32)
        try w.print("S-{d}-{d}", .{ sid[0], authority })
    else
        try w.print("S-{d}-0x{X:0>12}", .{ sid[0], authority });
    const count = @min(sid[1], (sid.len - 8) / 4);
    for (0..count) |i| try w.print("-{d}", .{std.mem.readInt(u32, sid[8 + 4 * i ..][0..4], .little)});
}

/// murrtty's own class, as GTK's application id: Debug builds have their
/// own, so that one can run beside a release.
const default_class = if (builtin.mode == .debug) "murrtty-debug" else "murrtty";

/// The pipe's name: the class (`class`, or murrtty's own), the user's SID,
/// the session and the integrity level.
fn pipeName(buf: []u8, class: ?[]const u8, id: *const Identity) std.Io.Writer.Error![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.writeAll("\\\\.\\pipe\\");
    const prefix = w.end;
    const cls = class orelse default_class;
    // GTK's application ids: letters, digits, '.', '_' and '-'. Anything
    // else, or a long one, goes by its hash.
    const plain = cls.len > 0 and cls.len <= 64 and for (cls) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '_' or ch == '-')) break false;
    } else true;
    if (plain) try w.writeAll(cls) else try w.print("h{x:0>16}", .{std.hash.Wyhash.hash(0, cls)});
    try w.writeByte('.');
    try formatSid(&w, id.user.slice());
    try w.print(".{d}.{x}", .{ id.session, id.integrity });
    // Windows takes 256 characters; only a SID of many subauthorities
    // reaches that.
    if (w.end > 256) {
        const hash = std.hash.Wyhash.hash(0, w.buffered()[prefix..]);
        w.end = prefix;
        try w.print("murrtty.h{x:0>16}", .{hash});
    }
    return w.buffered();
}

/// The pipe's security descriptor in SDDL: the user as its owner (an
/// elevated process's objects are otherwise the Administrators'), full
/// access for the user alone, and a mandatory label at the instance's
/// integrity level that keeps lower ones from writing or reading.
fn securityDescriptor(buf: []u8, id: *const Identity) std.Io.Writer.Error![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.writeAll("O:");
    try formatSid(&w, id.user.slice());
    try w.writeAll("D:P(A;;GA;;;");
    try formatSid(&w, id.user.slice());
    try w.print(")S:(ML;;NWNR;;;S-1-16-{d})", .{id.integrity});
    return w.buffered();
}

/// The integrity level an object's SACL labels it with: the RID of its
/// mandatory label ACE's SID, or medium, Windows' default, with none.
fn labelRid(acl: ?[*]const u8) u32 {
    const medium = 0x2000;
    const base = acl orelse return medium;
    // ACL: revision, padding, size (u16), ACE count (u16), padding.
    const size = std.mem.readInt(u16, base[2..4], .little);
    const count = std.mem.readInt(u16, base[4..6], .little);
    const bytes = base[0..size];
    var at: usize = 8;
    for (0..count) |_| {
        if (at + 4 > bytes.len) break;
        // ACE header: type, flags, size (u16).
        const ace_size = std.mem.readInt(u16, bytes[at + 2 ..][0..2], .little);
        if (ace_size < 4 or at + ace_size > bytes.len) break;
        // SYSTEM_MANDATORY_LABEL_ACE: the header, an access mask, a SID.
        if (bytes[at] == 0x11 and ace_size >= 8 + 8) {
            return lastSubAuthority(bytes[at + 8 .. at + ace_size]) orelse medium;
        }
        at += ace_size;
    }
    return medium;
}

/// ASCII as UTF-16.
fn widen(alloc: Allocator, s: []const u8) Allocator.Error![:0]u16 {
    const out = try alloc.allocSentinel(u16, s.len, 0);
    for (s, out) |ch, *o| o.* = ch;
    return out;
}

//---------------------------------------------------------------
// Overlapped I/O

const Io = enum { done, more, stopped, timeout, failed };

/// The end of overlapped I/O on `h` that `ok` (its call's result) began:
/// done, or done with more of the message to read; else cancelled, when
/// `stop` was signaled, `ms` passed or it failed.
fn waitIo(h: c.HANDLE, ov: *c.OVERLAPPED, ok: c.BOOL, ms: c.DWORD, stop: ?c.HANDLE, n: *c.DWORD) Io {
    if (ok == 0) switch (c.GetLastError()) {
        c.ERROR_IO_PENDING => {},
        c.ERROR_MORE_DATA => {
            _ = c.GetOverlappedResult(h, ov, n, c.FALSE);
            return .more;
        },
        else => return .failed,
    };
    // Finished at once or not, the event is set when it ends.
    var handles: [2]c.HANDLE = .{ ov.hEvent.?, undefined };
    var count: c.DWORD = 1;
    if (stop) |s| {
        handles[1] = s;
        count = 2;
    }
    const r = c.WaitForMultipleObjects(count, &handles, c.FALSE, ms);
    if (r != c.WAIT_OBJECT_0) {
        _ = c.CancelIoEx(h, ov);
        // Wait for the cancellation: the OVERLAPPED is in use until then.
        _ = c.GetOverlappedResult(h, ov, n, c.TRUE);
        return if (r == c.WAIT_OBJECT_0 + 1) .stopped else if (r == c.WAIT_TIMEOUT) .timeout else .failed;
    }
    if (c.GetOverlappedResult(h, ov, n, c.FALSE) != 0) return .done;
    return if (c.GetLastError() == c.ERROR_MORE_DATA) .more else .failed;
}

fn writeAll(h: c.HANDLE, ov: *c.OVERLAPPED, bytes: []const u8, stop: ?c.HANDLE) bool {
    _ = c.ResetEvent(ov.hEvent.?);
    var n: c.DWORD = 0;
    const ok = c.WriteFile(h, bytes.ptr, @intCast(bytes.len), null, ov);
    return waitIo(h, ov, ok, io_timeout_ms, stop, &n) == .done and n == bytes.len;
}

/// Read one message, of at most `max_message` bytes.
fn readMessage(alloc: Allocator, h: c.HANDLE, ov: *c.OVERLAPPED, stop: ?c.HANDLE) error{ OutOfMemory, TooLong, Io }![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var chunk: [4096]u8 = undefined;
    while (true) {
        _ = c.ResetEvent(ov.hEvent.?);
        var n: c.DWORD = 0;
        const ok = c.ReadFile(h, &chunk, chunk.len, null, ov);
        const r = waitIo(h, ov, ok, io_timeout_ms, stop, &n);
        if (r != .done and r != .more) return error.Io;
        if (out.items.len + n > max_message) return error.TooLong;
        try out.appendSlice(alloc, chunk[0..n]);
        if (r == .done) return out.toOwnedSlice(alloc);
    }
}

//---------------------------------------------------------------
// The server

pub const Server = struct {
    alloc: Allocator,
    name: [:0]u16,
    /// The name as text, for the GUI tests' dump.
    name_utf8: []u8,
    /// From ConvertStringSecurityDescriptorToSecurityDescriptorW (LocalFree).
    descriptor: *anyopaque,
    /// The session clients must be in.
    session: u32,
    /// Each request queued wakes this window with `msg` (no pointer: any
    /// process on the desktop can post to it), which `take`s it.
    hwnd: c.HWND,
    msg: c.UINT,
    mutex: std.Io.Mutex = .init,
    queue: std.ArrayList(*Received) = .empty,
    stop_event: c.HANDLE,
    io_event: c.HANDLE,
    thread: std.Thread,
    /// Whether this murrtty holds the name.
    listening: std.atomic.Value(bool) = .init(false),
    /// Requests queued, for the GUI tests.
    received: std.atomic.Value(u32) = .init(0),
    /// The AppUserModelID whose Jump List to set up once it holds the name,
    /// or null to leave it.
    jump_list_app_id: ?c.LPCWSTR,

    /// Listen for `class` (null: murrtty's own) from another thread. The
    /// name is claimed here and now if it is free (`listening`), so that of
    /// two murrttys starting together one holds it and the other can hand
    /// its window over.
    pub fn start(
        alloc: Allocator,
        class: ?[]const u8,
        hwnd: c.HWND,
        msg: c.UINT,
        jump_list_app_id: ?c.LPCWSTR,
    ) !*Server {
        const id = try Identity.current();
        var name_buf: [320]u8 = undefined;
        const name = try pipeName(&name_buf, class, &id);
        var sddl_buf: [256]u8 = undefined;
        const sddl = try widen(alloc, try securityDescriptor(&sddl_buf, &id));
        defer alloc.free(sddl);
        var descriptor: ?*anyopaque = null;
        if (c.ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, c.SDDL_REVISION_1, &descriptor, null) == 0) {
            log.warn("the pipe's security descriptor failed err={}", .{c.GetLastError()});
            return error.SecurityDescriptor;
        }
        errdefer _ = c.LocalFree(descriptor);
        const stop_event = c.CreateEventW(null, c.TRUE, c.FALSE, null) orelse return error.CreateEvent;
        errdefer _ = c.CloseHandle(stop_event);
        const io_event = c.CreateEventW(null, c.TRUE, c.FALSE, null) orelse return error.CreateEvent;
        errdefer _ = c.CloseHandle(io_event);

        const self = try alloc.create(Server);
        errdefer alloc.destroy(self);
        const name16 = try widen(alloc, name);
        errdefer alloc.free(name16);
        const name_utf8 = try alloc.dupe(u8, name);
        errdefer alloc.free(name_utf8);
        self.* = .{
            .alloc = alloc,
            .name = name16,
            .name_utf8 = name_utf8,
            .descriptor = descriptor.?,
            .session = id.session,
            .hwnd = hwnd,
            .msg = msg,
            .stop_event = stop_event,
            .io_event = io_event,
            .thread = undefined,
            .jump_list_app_id = jump_list_app_id,
        };
        const claimed = self.createInstance(true);
        errdefer if (claimed) |h| {
            _ = c.CloseHandle(h);
        };
        if (claimed != null) self.listening.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, run, .{ self, claimed });
        return self;
    }

    /// Stop listening and free the server, with the requests not taken.
    pub fn stop(self: *Server) void {
        _ = c.SetEvent(self.stop_event);
        self.thread.join();
        for (self.queue.items) |r| r.destroy(self.alloc);
        self.queue.deinit(self.alloc);
        _ = c.CloseHandle(self.stop_event);
        _ = c.CloseHandle(self.io_event);
        _ = c.LocalFree(self.descriptor);
        self.alloc.free(self.name);
        self.alloc.free(self.name_utf8);
        self.alloc.destroy(self);
    }

    /// The next request queued, the caller's to free (the UI thread's, on
    /// `msg`), or null.
    pub fn take(self: *Server) ?*Received {
        const io = global.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.queue.items.len == 0) return null;
        return self.queue.orderedRemove(0);
    }

    fn stopped(self: *Server, ms: c.DWORD) bool {
        return c.WaitForSingleObject(self.stop_event, ms) == c.WAIT_OBJECT_0;
    }

    /// The name is this murrtty's now.
    fn holding(self: *Server) void {
        self.listening.store(true, .release);
        log.info("listening as the single instance", .{});
        if (self.jump_list_app_id) |id| _ = jump_list.setUp(id);
        // Once: Windows keeps the list.
        self.jump_list_app_id = null;
    }

    /// An instance of the pipe; the first only if the name is free.
    fn createInstance(self: *Server, first: bool) ?c.HANDLE {
        const sa: c.SECURITY_ATTRIBUTES = .{ .lpSecurityDescriptor = self.descriptor };
        const h = c.CreateNamedPipeW(
            self.name,
            c.PIPE_ACCESS_DUPLEX | c.FILE_FLAG_OVERLAPPED | @as(c.DWORD, if (first) c.FILE_FLAG_FIRST_PIPE_INSTANCE else 0),
            c.PIPE_TYPE_MESSAGE | c.PIPE_READMODE_MESSAGE | c.PIPE_REJECT_REMOTE_CLIENTS,
            c.PIPE_UNLIMITED_INSTANCES,
            4096,
            4096,
            0,
            &sa,
        );
        return if (h == c.INVALID_HANDLE_VALUE) null else h;
    }

    /// `claimed`: the first instance, if start took the name.
    fn run(self: *Server, claimed: ?c.HANDLE) void {
        // One instance always listens: the next is created while one is
        // served, so the name never lapses for another process to take.
        var first = claimed == null;
        var listening: ?c.HANDLE = claimed;
        var warned = false;
        defer if (listening) |h| {
            _ = c.CloseHandle(h);
        };
        if (claimed != null) self.holding();
        // Checked each time round, so that clients one after another can't
        // keep it from stopping.
        while (!self.stopped(0)) {
            if (listening == null) {
                listening = self.createInstance(first);
                if (listening == null) {
                    if (!warned) log.info("the single-instance pipe is taken (err={}), trying again every {d} ms", .{ c.GetLastError(), retry_ms });
                    warned = true;
                    if (self.stopped(retry_ms)) return;
                    continue;
                }
                if (first) {
                    first = false;
                    self.holding();
                }
            }
            const pipe = listening.?;
            var ov: c.OVERLAPPED = .{ .hEvent = self.io_event };
            _ = c.ResetEvent(self.io_event);
            var n: c.DWORD = 0;
            const ok = c.ConnectNamedPipe(pipe, &ov);
            // A client that came between creating and connecting.
            const r: Io = if (ok == 0 and c.GetLastError() == c.ERROR_PIPE_CONNECTED)
                .done
            else
                waitIo(pipe, &ov, ok, c.INFINITE, self.stop_event, &n);
            if (r == .stopped) return;
            listening = self.createInstance(false);
            if (r == .done) self.serve(pipe, &ov);
            _ = c.DisconnectNamedPipe(pipe);
            _ = c.CloseHandle(pipe);
            // Gone with no instance left: the name may be anyone's now.
            if (listening == null) {
                first = true;
                self.listening.store(false, .release);
            }
        }
    }

    fn serve(self: *Server, pipe: c.HANDLE, ov: *c.OVERLAPPED) void {
        // The DACL lets the user's processes in other sessions open it too.
        var session: u32 = 0;
        if (c.GetNamedPipeClientSessionId(pipe, &session) == 0 or session != self.session) {
            log.warn("refused a client from another session", .{});
            return;
        }
        const bytes = readMessage(self.alloc, pipe, ov, self.stop_event) catch |err| {
            if (err == error.TooLong) _ = writeAll(pipe, ov, &.{@intFromEnum(Reply.malformed)}, self.stop_event);
            return;
        };
        defer self.alloc.free(bytes);
        const reply = self.handle(bytes);
        if (!writeAll(pipe, ov, &.{@intFromEnum(reply)}, self.stop_event)) return;
        // Until the client has read the reply and closed its end: closing
        // ours first would discard it.
        _ = c.ResetEvent(ov.hEvent.?);
        var byte: [1]u8 = undefined;
        var n: c.DWORD = 0;
        const ok = c.ReadFile(pipe, &byte, 1, null, ov);
        _ = waitIo(pipe, ov, ok, io_timeout_ms, self.stop_event, &n);
    }

    fn handle(self: *Server, bytes: []const u8) Reply {
        const received = self.alloc.create(Received) catch return .failed;
        received.* = .{ .arena = .init(self.alloc), .message = undefined };
        received.message = decode(received.arena.allocator(), bytes) catch |err| {
            received.destroy(self.alloc);
            log.warn("refused a request err={}", .{err});
            return switch (err) {
                error.Malformed => .malformed,
                error.Unsupported => .unsupported,
                error.OutOfMemory => .failed,
            };
        };
        // The quick terminal comes with roadmap 5.7.
        if (received.message.kind == .toggle_quick_terminal) {
            received.destroy(self.alloc);
            return .unsupported;
        }
        const io = global.io();
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.queue.append(self.alloc, received) catch {
                received.destroy(self.alloc);
                return .failed;
            };
        }
        if (c.PostMessageW(self.hwnd, self.msg, 0, 0) == 0) {
            // Nothing would take it (the window is gone).
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (std.mem.indexOfScalar(*Received, self.queue.items, received)) |i| {
                _ = self.queue.orderedRemove(i);
                received.destroy(self.alloc);
            }
            return .failed;
        }
        _ = self.received.fetchAdd(1, .monotonic);
        return .ok;
    }
};

//---------------------------------------------------------------
// The client

pub const SendError = error{
    /// Another user's process, or a lower one, serves the pipe.
    Untrusted,
    /// No answer in time.
    Timeout,
    /// The pipe failed.
    Io,
    OutOfMemory,
    TooLong,
};

pub const Sent = union(enum) {
    /// No murrtty holds the name.
    none,
    reply: Reply,
};

/// Send `msg` to the murrtty serving `class` (null: murrtty's own), within
/// `wait_ms` if it isn't there yet (a murrtty just started for it).
fn send(alloc: Allocator, class: ?[]const u8, msg: Message, wait_ms: u32) SendError!Sent {
    const own = Identity.current() catch return error.Io;
    const bytes = try encode(alloc, msg);
    defer alloc.free(bytes);
    const opened = try open(alloc, class, &own, wait_ms) orelse return .none;
    const pipe = opened.pipe;
    defer _ = c.CloseHandle(pipe);
    // So that the window it opens can come forward.
    _ = c.AllowSetForegroundWindow(opened.pid);
    var mode: c.DWORD = c.PIPE_READMODE_MESSAGE;
    if (c.SetNamedPipeHandleState(pipe, &mode, null, null) == 0) return error.Io;

    const event = c.CreateEventW(null, c.TRUE, c.FALSE, null) orelse return error.Io;
    defer _ = c.CloseHandle(event);
    var ov: c.OVERLAPPED = .{ .hEvent = event };
    if (!writeAll(pipe, &ov, bytes, null)) return error.Io;
    const reply = readMessage(alloc, pipe, &ov, null) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooLong, error.Io => error.Io,
    };
    defer alloc.free(reply);
    if (reply.len != 1) return error.Io;
    return .{ .reply = @enumFromInt(reply[0]) };
}

/// Whether a murrtty serves `class`: its pipe opens and passes the same
/// checks as for a request (verifyServer). Nothing is sent; the server
/// drops a client that closes without a request.
pub fn serverRunning(alloc: Allocator, class: ?[]const u8) bool {
    const own = Identity.current() catch return false;
    const opened = (open(alloc, class, &own, 0) catch return false) orelse return false;
    _ = c.CloseHandle(opened.pipe);
    return true;
}

/// Open the pipe of the murrtty serving `class`, within `wait_ms` if it
/// isn't there yet, and check it and its server; null if none holds it.
fn open(alloc: Allocator, class: ?[]const u8, own: *const Identity, wait_ms: u32) SendError!?struct { pipe: c.HANDLE, pid: u32 } {
    var name_buf: [320]u8 = undefined;
    const name = pipeName(&name_buf, class, own) catch return error.Io;
    const name16 = try widen(alloc, name);
    defer alloc.free(name16);

    const deadline = c.GetTickCount64() + connect_timeout_ms;
    const appear_deadline = c.GetTickCount64() + wait_ms;
    const pipe = while (true) {
        const h = c.CreateFileW(
            name16,
            c.GENERIC_READ | c.GENERIC_WRITE,
            0,
            null,
            c.OPEN_EXISTING,
            c.FILE_FLAG_OVERLAPPED | c.SECURITY_SQOS_PRESENT | c.SECURITY_IDENTIFICATION,
            null,
        );
        if (h != c.INVALID_HANDLE_VALUE) break h;
        switch (c.GetLastError()) {
            c.ERROR_FILE_NOT_FOUND => {
                if (c.GetTickCount64() >= appear_deadline) return null;
                c.Sleep(50);
            },
            c.ERROR_PIPE_BUSY => {
                if (c.GetTickCount64() >= deadline) return error.Timeout;
                _ = c.WaitNamedPipeW(name16, 1000);
            },
            else => |err| {
                log.warn("opening the pipe failed err={}", .{err});
                return error.Io;
            },
        }
    };
    errdefer _ = c.CloseHandle(pipe);
    const pid = try verifyServer(pipe, own);
    return .{ .pipe = pipe, .pid = pid };
}

/// The process serving `pipe`, if the pipe is the caller's own: owned by
/// its user and labeled at its integrity level or above (an object can't
/// be made another user's, or labeled above its maker's level), served in
/// its session by a process of its user at no lower level. The process
/// alone could be another's whose id came back to one of the user's.
fn verifyServer(pipe: c.HANDLE, own: *const Identity) error{Untrusted}!u32 {
    var owner: ?*anyopaque = null;
    var sacl: ?*anyopaque = null;
    var descriptor: ?*anyopaque = null;
    if (c.GetSecurityInfo(pipe, c.SE_KERNEL_OBJECT, c.OWNER_SECURITY_INFORMATION | c.LABEL_SECURITY_INFORMATION, &owner, null, null, &sacl, &descriptor) != 0) {
        return error.Untrusted;
    }
    defer _ = c.LocalFree(descriptor);
    const owner_sid: [*]const u8 = @ptrCast(owner orelse return error.Untrusted);
    const owner_len = sidLength(owner_sid[0..2]);
    if (!std.mem.eql(u8, owner_sid[0..owner_len], own.user.slice()) or
        labelRid(@ptrCast(sacl)) < own.integrity) return error.Untrusted;

    var session: u32 = 0;
    if (c.GetNamedPipeServerSessionId(pipe, &session) == 0 or session != own.session) return error.Untrusted;
    var pid: u32 = 0;
    if (c.GetNamedPipeServerProcessId(pipe, &pid) == 0) return error.Untrusted;
    const process = c.OpenProcess(c.PROCESS_QUERY_LIMITED_INFORMATION, c.FALSE, pid) orelse return error.Untrusted;
    defer _ = c.CloseHandle(process);
    const theirs = Identity.of(process, pid) catch return error.Untrusted;
    if (!std.mem.eql(u8, theirs.user.slice(), own.user.slice()) or
        theirs.session != own.session or
        theirs.integrity < own.integrity) return error.Untrusted;
    return pid;
}

/// Write a message for the user on stderr (a console, when the CLI has one).
fn complain(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(global.io(), &buf);
    const stderr = &stderr_writer.interface;
    stderr.print("murrtty: " ++ fmt ++ "\n", args) catch {};
    stderr.flush() catch {};
}

/// Send a CLI action's request (App.performIpc), starting a murrtty for it
/// if none serves `class`. Says why on stderr when it fails.
pub fn request(alloc: Allocator, class: ?[]const u8, msg: Message) error{IPCFailed}!void {
    var sent = send(alloc, class, msg, 0) catch |err| return failed(err);
    if (sent == .none) {
        startInstance(alloc, class) catch |err| {
            complain("no murrtty is running, and starting one failed ({t})", .{err});
            return error.IPCFailed;
        };
        sent = send(alloc, class, msg, connect_timeout_ms) catch |err| return failed(err);
    }
    switch (sent) {
        .none => {
            complain("the murrtty started for this request never listened", .{});
            return error.IPCFailed;
        },
        .reply => |r| switch (r) {
            .ok => {},
            .unsupported => {
                complain("the running murrtty doesn't support this request (is it an older version?)", .{});
                return error.IPCFailed;
            },
            else => {
                // A number: a newer murrtty's reply has no name here.
                complain("the running murrtty refused the request (reply {d})", .{@intFromEnum(r)});
                return error.IPCFailed;
            },
        },
    }
}

fn failed(err: SendError) error{IPCFailed} {
    switch (err) {
        error.Untrusted => complain("the single-instance pipe isn't this user's at this integrity level; nothing was sent", .{}),
        error.Timeout => complain("the running murrtty didn't answer", .{}),
        else => complain("sending the request failed ({t})", .{err}),
    }
    return error.IPCFailed;
}

/// gtk-single-instance: ask the murrtty serving `class` for the window this
/// launch would open. Whether it took it.
pub fn handOff(alloc: Allocator, class: ?[]const u8) bool {
    const sent = send(alloc, class, .{ .kind = .new_window }, 0) catch |err| {
        log.warn("handing the window to the running murrtty failed err={}", .{err});
        return false;
    };
    return switch (sent) {
        .none => false,
        .reply => |r| r == .ok,
    };
}

/// Start this murrtty for `class` with no window of its own (launch_env):
/// the request then opens it. It lives on as the single instance, so it
/// starts as a desktop launch would: in the home directory, with the
/// user's own environment rather than this shell's (a virtualenv's PATH,
/// say), as D-Bus activation starts GTK's. Out of the caller's job when the
/// job allows, so a terminal that ends its processes on closing doesn't
/// take it along.
fn startInstance(alloc: Allocator, class: ?[]const u8) !void {
    var exe: [32768]u16 = undefined;
    const len = c.GetModuleFileNameW(null, &exe, exe.len);
    if (len == 0 or len >= exe.len) return error.NoExecutable;
    exe[len] = 0;
    var cmd: std.ArrayList(u16) = .empty;
    defer cmd.deinit(alloc);
    try appendQuoted(alloc, &cmd, exe[0..len]);
    if (class) |cls| {
        const arg = try std.fmt.allocPrint(alloc, "--class={s}", .{cls});
        defer alloc.free(arg);
        const arg16 = try std.unicode.wtf8ToWtf16LeAlloc(alloc, arg);
        defer alloc.free(arg16);
        try cmd.append(alloc, ' ');
        try appendQuoted(alloc, &cmd, arg16);
    }
    try cmd.append(alloc, 0);

    var env: std.ArrayList(u16) = .empty;
    defer env.deinit(alloc);
    var home: std.ArrayList(u16) = .empty;
    defer home.deinit(alloc);
    // The GUI tests point a murrtty's dump and config through the
    // environment, so a Debug build with the hooks on keeps the caller's.
    const tested = builtin.mode == .debug and c.GetEnvironmentVariableW(c.L("GHOSTTY_WIN32_TEST_DUMP"), null, 0) != 0;
    if (!tested) try userEnvironment(alloc, &env, &home);
    var flags: c.DWORD = 0;
    if (env.items.len > 0) {
        flags |= c.CREATE_UNICODE_ENVIRONMENT;
    } else {
        // Inherited: this process exits next.
        _ = c.SetEnvironmentVariableW(c.L(launch_env), c.L("1"));
    }
    defer if (env.items.len == 0) {
        _ = c.SetEnvironmentVariableW(c.L(launch_env), null);
    };
    const env_ptr: ?*anyopaque = if (env.items.len > 0) env.items.ptr else null;
    const cwd: ?c.LPCWSTR = if (home.items.len > 0) @ptrCast(home.items.ptr) else null;

    var si: c.STARTUPINFOW = .{};
    var pi: c.PROCESS_INFORMATION = .{};
    const exe_z: [*:0]const u16 = @ptrCast(&exe);
    const cmd_z: [*:0]u16 = @ptrCast(cmd.items.ptr);
    var ok = c.CreateProcessW(exe_z, cmd_z, null, null, c.FALSE, flags | c.CREATE_BREAKAWAY_FROM_JOB, env_ptr, cwd, &si, &pi);
    if (ok == 0 and c.GetLastError() == c.ERROR_ACCESS_DENIED) {
        ok = c.CreateProcessW(exe_z, cmd_z, null, null, c.FALSE, flags, env_ptr, cwd, &si, &pi);
    }
    if (ok == 0) {
        log.warn("starting murrtty failed err={}", .{c.GetLastError()});
        return error.CreateProcessFailed;
    }
    if (pi.hThread) |h| _ = c.CloseHandle(h);
    if (pi.hProcess) |h| _ = c.CloseHandle(h);
}

/// The user's own environment (CreateEnvironmentBlock, as for a new
/// logon) as a block for CreateProcessW, with launch_env added, into
/// `env`, and its USERPROFILE, NUL-terminated, into `home`. Both stay
/// empty if Windows won't give it.
fn userEnvironment(alloc: Allocator, env: *std.ArrayList(u16), home: *std.ArrayList(u16)) Allocator.Error!void {
    var token: c.HANDLE = undefined;
    if (c.OpenProcessToken(c.GetCurrentProcess(), c.TOKEN_QUERY | c.TOKEN_DUPLICATE | c.TOKEN_IMPERSONATE, &token) == 0) return;
    defer _ = c.CloseHandle(token);
    var block: ?*anyopaque = null;
    if (c.CreateEnvironmentBlock(&block, token, c.FALSE) == 0) return;
    defer _ = c.DestroyEnvironmentBlock(block.?);
    try appendEnvironment(alloc, env, home, @ptrCast(@alignCast(block.?)));
}

/// `block`'s variables, without any launch_env, then launch_env=1, into
/// `env` (its own block); its USERPROFILE into `home`.
fn appendEnvironment(alloc: Allocator, env: *std.ArrayList(u16), home: *std.ArrayList(u16), block: [*:0]const u16) Allocator.Error!void {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    var rest = block;
    while (rest[0] != 0) {
        const entry = std.mem.sliceTo(rest, 0);
        rest += entry.len + 1;
        if (startsWithIgnoreCase(entry, L(launch_env ++ "="))) continue;
        try env.appendSlice(alloc, entry);
        try env.append(alloc, 0);
        const profile = L("USERPROFILE=");
        if (startsWithIgnoreCase(entry, profile) and entry.len > profile.len) {
            home.clearRetainingCapacity();
            try home.appendSlice(alloc, entry[profile.len..]);
            try home.append(alloc, 0);
        }
    }
    try env.appendSlice(alloc, L(launch_env ++ "=1"));
    try env.appendSlice(alloc, &.{ 0, 0 });
}

fn startsWithIgnoreCase(s: []const u16, prefix: []const u16) bool {
    if (s.len < prefix.len) return false;
    for (s[0..prefix.len], prefix) |a, b| {
        if (a > 127 or std.ascii.toLower(@intCast(a)) != std.ascii.toLower(@intCast(b))) return false;
    }
    return true;
}

/// Append `arg` to a command line, quoted as the C runtime splits one.
fn appendQuoted(alloc: Allocator, out: *std.ArrayList(u16), arg: []const u16) Allocator.Error!void {
    const needs = arg.len == 0 or for (arg) |ch| {
        if (ch == ' ' or ch == '\t' or ch == '"') break true;
    } else false;
    if (!needs) return out.appendSlice(alloc, arg);
    try out.append(alloc, '"');
    var backslashes: usize = 0;
    for (arg) |ch| {
        if (ch == '\\') {
            backslashes += 1;
            continue;
        }
        if (ch == '"') {
            try out.appendNTimes(alloc, '\\', backslashes * 2 + 1);
        } else {
            try out.appendNTimes(alloc, '\\', backslashes);
        }
        try out.append(alloc, ch);
        backslashes = 0;
    }
    try out.appendNTimes(alloc, '\\', backslashes * 2);
    try out.append(alloc, '"');
}

//---------------------------------------------------------------
// Tests

test "encode and decode round trip" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const args = [_][:0]const u8{ "--working-directory=C:\\Users\\me", "-e", "pwsh", "-NoLogo" };
    const bytes = try encode(testing.allocator, .{ .kind = .new_tab, .surface_id = 0x1234, .arguments = &args });
    defer testing.allocator.free(bytes);
    const msg = try decode(arena.allocator(), bytes);
    try testing.expectEqual(Kind.new_tab, msg.kind);
    try testing.expectEqual(@as(u64, 0x1234), msg.surface_id);
    try testing.expectEqual(args.len, msg.arguments.?.len);
    for (args, msg.arguments.?) |want, got| try testing.expectEqualStrings(want, got);

    // No arguments stays null.
    const none = try encode(testing.allocator, .{ .kind = .new_window });
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(?[]const [:0]const u8, null), (try decode(arena.allocator(), none)).arguments);
}

test "decode refuses what isn't a request" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = [_][:0]const u8{"-e"};
    const good = try encode(testing.allocator, .{ .kind = .new_window, .arguments = &args });
    defer testing.allocator.free(good);

    try testing.expectError(error.Malformed, decode(a, ""));
    try testing.expectError(error.Malformed, decode(a, "garbage that is long enough"));
    // Truncated, or with bytes after the last argument.
    try testing.expectError(error.Malformed, decode(a, good[0 .. good.len - 1]));
    const longer = try std.mem.concat(testing.allocator, u8, &.{ good, "x" });
    defer testing.allocator.free(longer);
    try testing.expectError(error.Malformed, decode(a, longer));

    var bad = try testing.allocator.dupe(u8, good);
    defer testing.allocator.free(bad);
    // Another version, or a kind it doesn't know.
    bad[4] = 2;
    try testing.expectError(error.Unsupported, decode(a, bad));
    bad[4] = version;
    bad[5] = 9;
    try testing.expectError(error.Unsupported, decode(a, bad));
    bad[5] = good[5];
    // Arguments said present but none, and absent but some.
    bad[6] = 0;
    try testing.expectError(error.Malformed, decode(a, bad));
    bad[6] = 1;
    // A surface id on a new window.
    bad[8] = 1;
    try testing.expectError(error.Malformed, decode(a, bad));
    bad[8] = 0;
    // A NUL in an argument.
    bad[bad.len - 1] = 0;
    try testing.expectError(error.Malformed, decode(a, bad));
    // An argument length past the end.
    bad[bad.len - 1] = 'e';
    bad[header_len] = 200;
    try testing.expectError(error.Malformed, decode(a, bad));
}

test "encode refuses too much" {
    const testing = std.testing;
    const big = try testing.allocator.allocSentinel(u8, max_message, 0);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    const args = [_][:0]const u8{big};
    try testing.expectError(error.TooLong, encode(testing.allocator, .{ .kind = .new_window, .arguments = &args }));
}

test "Overrides.parse reads GTK's arguments" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = [_][:0]const u8{
        "--working-directory=C:\\caller",
        "--title= Build ",
        "--shell-integration=none",
        "--unknown=1",
        // The caller's directory, which the CLI passes first, stays.
        "--working-directory=inherit",
        "-e",
        "pwsh",
        "--title=not mine",
    };
    const o = try Overrides.parse(a, &args);
    try testing.expectEqualStrings("C:\\caller", o.working_directory.?.path);
    try testing.expectEqualStrings("Build", o.title.?);
    try testing.expectEqual(configpkg.Config.ShellIntegration.none, o.shell_integration.?);
    // Everything after -e is the command, as it is.
    try testing.expectEqual(@as(usize, 2), o.command.?.direct.len);
    try testing.expectEqualStrings("pwsh", o.command.?.direct[0]);
    try testing.expectEqualStrings("--title=not mine", o.command.?.direct[1]);

    // A path, and an argument it can't read, skipped.
    const more = [_][:0]const u8{ "--working-directory=C:\\work", "--shell-integration=nonsense", "--command=cmd /k" };
    const p = try Overrides.parse(a, &more);
    try testing.expectEqualStrings("C:\\work", p.working_directory.?.path);
    try testing.expectEqual(@as(?configpkg.Config.ShellIntegration, null), p.shell_integration);
    try testing.expectEqualStrings("cmd /k", p.command.?.shell);

    // `home` is resolved as the config's finalize resolves it: a pane given
    // `.home` itself would start in murrtty's own directory.
    const home = [_][:0]const u8{"--working-directory=home"};
    const q = try Overrides.parse(a, &home);
    if (homeDir(a)) |want| {
        try testing.expectEqualStrings(want, q.working_directory.?.path);
    } else try testing.expect(q.working_directory == null);
}

test "labelRid reads a SACL's mandatory label" {
    const testing = std.testing;
    try testing.expectEqual(@as(u32, 0x2000), labelRid(null));
    // An ACL with an audit ACE (type 2) and then a label ACE (0x11) for
    // S-1-16-4096 (low), mask NW.
    const acl = [_]u8{ 2, 0, 40, 0, 2, 0, 0, 0 } ++ // the header: 40 bytes, 2 ACEs
        [_]u8{ 2, 0, 12, 0, 0, 0, 0, 0, 0, 0, 0, 0 } ++ // the audit ACE
        [_]u8{ 0x11, 0, 20, 0, 1, 0, 0, 0 } ++ // the label ACE's header and mask
        [_]u8{ 1, 1, 0, 0, 0, 0, 0, 16, 0, 0x10, 0, 0 }; // S-1-16-4096
    try testing.expectEqual(@as(u32, 0x1000), labelRid(&acl));
    // No label ACE: Windows' default, medium.
    var none = acl;
    none[20] = 2;
    try testing.expectEqual(@as(u32, 0x2000), labelRid(&none));
}

test "appendEnvironment adds the launch variable and finds the profile" {
    const testing = std.testing;
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    var env: std.ArrayList(u16) = .empty;
    defer env.deinit(testing.allocator);
    var home: std.ArrayList(u16) = .empty;
    defer home.deinit(testing.allocator);
    const block = L("A=1\x00murrtty_ipc_launch=0\x00UserProfile=C:\\Users\\x\x00");
    try appendEnvironment(testing.allocator, &env, &home, block);
    try testing.expectEqualSlices(u16, L("A=1\x00UserProfile=C:\\Users\\x\x00" ++ launch_env ++ "=1\x00\x00"), env.items);
    try testing.expectEqualSlices(u16, L("C:\\Users\\x\x00"), home.items);
}

test "Overrides.apply follows GTK's shell integration rule" {
    const testing = std.testing;
    var config = try configpkg.Config.default(testing.allocator);
    defer config.deinit();

    config.@"shell-integration" = .nushell;
    try (Overrides{ .command = .{ .shell = "vim" } }).apply(&config);
    try testing.expectEqual(.detect, config.@"shell-integration");

    config.@"shell-integration" = .none;
    try (Overrides{ .command = .{ .shell = "vim" } }).apply(&config);
    try testing.expectEqual(.none, config.@"shell-integration");

    try (Overrides{ .command = .{ .shell = "nu" }, .shell_integration = .nushell }).apply(&config);
    try testing.expectEqual(.nushell, config.@"shell-integration");

    config.@"shell-integration" = .nushell;
    try (Overrides{}).apply(&config);
    try testing.expectEqual(.nushell, config.@"shell-integration");

    try (Overrides{ .shell_integration = .none }).apply(&config);
    try testing.expectEqual(.none, config.@"shell-integration");

    // The command wins over initial-command; the directory is set.
    config.@"initial-command" = .{ .shell = "htop" };
    try (Overrides{ .command = .{ .shell = "vim" }, .working_directory = .{ .path = "C:\\x" } }).apply(&config);
    try testing.expectEqual(@as(?configpkg.Command, null), config.@"initial-command");
    try testing.expectEqualStrings("vim", config.command.?.shell);
    try testing.expectEqualStrings("C:\\x", config.@"working-directory".?.path);
}

test "formatSid writes SIDs as Windows does" {
    const testing = std.testing;
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // BUILTIN\Administrators.
    try formatSid(&w, &.{ 1, 2, 0, 0, 0, 0, 0, 5, 32, 0, 0, 0, 0x20, 2, 0, 0 });
    try testing.expectEqualStrings("S-1-5-32-544", w.buffered());
    w = .fixed(&buf);
    // Medium integrity.
    try formatSid(&w, &.{ 1, 1, 0, 0, 0, 0, 0, 16, 0, 0x20, 0, 0 });
    try testing.expectEqualStrings("S-1-16-8192", w.buffered());
    try testing.expectEqual(@as(?u32, 0x2000), lastSubAuthority(&.{ 1, 1, 0, 0, 0, 0, 0, 16, 0, 0x20, 0, 0 }));
}

test "pipeName and securityDescriptor" {
    const testing = std.testing;
    var id: Identity = .{ .session = 1, .integrity = 0x2000 };
    const sid = [_]u8{ 1, 2, 0, 0, 0, 0, 0, 5, 32, 0, 0, 0, 0x20, 2, 0, 0 };
    @memcpy(id.user.bytes[0..sid.len], &sid);
    id.user.len = sid.len;

    var buf: [320]u8 = undefined;
    try testing.expectEqualStrings("\\\\.\\pipe\\com.example.term.S-1-5-32-544.1.2000", try pipeName(&buf, "com.example.term", &id));
    try testing.expectEqualStrings("\\\\.\\pipe\\" ++ default_class ++ ".S-1-5-32-544.1.2000", try pipeName(&buf, null, &id));
    // A class with other characters goes by its hash, so it can't reach
    // outside the pipe namespace.
    const odd = try pipeName(&buf, "..\\other pipe", &id);
    try testing.expect(std.mem.startsWith(u8, odd, "\\\\.\\pipe\\h"));
    try testing.expect(std.mem.indexOfScalar(u8, odd["\\\\.\\pipe\\".len..], '\\') == null);

    try testing.expectEqualStrings("O:S-1-5-32-544D:P(A;;GA;;;S-1-5-32-544)S:(ML;;NWNR;;;S-1-16-8192)", try securityDescriptor(&buf, &id));
}

test "appendQuoted quotes as the C runtime splits" {
    const testing = std.testing;
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    const cases = [_]struct { []const u16, []const u16 }{
        .{ L("plain"), L("plain") },
        .{ L(""), L("\"\"") },
        .{ L("C:\\Program Files\\murrtty.exe"), L("\"C:\\Program Files\\murrtty.exe\"") },
        .{ L("a \"b\""), L("\"a \\\"b\\\"\"") },
        .{ L("dir with space\\"), L("\"dir with space\\\\\"") },
        .{ L("x\\\\\" y"), L("\"x\\\\\\\\\\\" y\"") },
    };
    for (cases) |case| {
        var out: std.ArrayList(u16) = .empty;
        defer out.deinit(testing.allocator);
        try appendQuoted(testing.allocator, &out, case[0]);
        try testing.expectEqualSlices(u16, case[1], out.items);
    }
}

test "the current process's identity" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const id = try Identity.current();
    try testing.expect(id.user.len >= 12);
    try testing.expect(id.integrity >= 0x1000);
}
