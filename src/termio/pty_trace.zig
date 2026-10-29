//! Debug builds on Windows: with GHOSTTY_PTY_LOG naming a folder, every
//! byte written to a pseudoconsole and read back from it goes to
//! pty-trace-<pid>.log there, one record a line, timestamped, so what a
//! shell was sent can be lined up with what it printed (lost keystrokes,
//! roadmap task 42). A record: microseconds since the first, '>' for bytes
//! queued to the pty or '<' for bytes from it, the terminal's tag, then the
//! bytes with ESC as \e, CR and LF as \r and \n, other controls and
//! non-ASCII as \xHH; or '=' and the count of bytes a queued write put in
//! the pipe as it completed (the writer's tag), so a write that never
//! completes shows.
const std = @import("std");
const builtin = @import("builtin");
const global = @import("../global.zig");

const enabled = builtin.mode == .debug and builtin.os.tag == .windows;

const HANDLE = *anyopaque;
extern "kernel32" fn QueryPerformanceCounter(*i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(*i64) callconv(.winapi) i32;
extern "kernel32" fn CreateFileW(
    [*:0]const u16,
    u32,
    u32,
    ?*anyopaque,
    u32,
    u32,
    ?HANDLE,
) callconv(.winapi) HANDLE;
extern "kernel32" fn WriteFile(HANDLE, [*]const u8, u32, ?*u32, ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

var state: enum(u8) { unopened, open, off } = .unopened;
var file: ?HANDLE = null;
var start: i64 = 0;
var freq: i64 = 1;
/// A spin lock: records are short, and the reader and writer threads
/// rarely meet.
var busy: std.atomic.Value(bool) = .init(false);

/// Record `bytes` going to (`to_pty`) or coming from terminal `tag`'s
/// pseudoconsole.
pub fn record(tag: usize, to_pty: bool, bytes: []const u8) void {
    if (comptime !enabled) return;
    while (busy.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    defer busy.store(false, .release);
    if (state == .unopened) open();
    const h = file orelse return;
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("{d} {c} {x} ", .{ elapsedUs(), @as(u8, if (to_pty) '>' else '<'), tag }) catch return;
    for (bytes) |b| {
        const ok = switch (b) {
            0x1b => w.writeAll("\\e"),
            '\r' => w.writeAll("\\r"),
            '\n' => w.writeAll("\\n"),
            '\\' => w.writeAll("\\\\"),
            0x20...0x5b, 0x5d...0x7e => w.writeByte(b),
            else => w.print("\\x{x:0>2}", .{b}),
        };
        ok catch break;
    }
    w.writeByte('\n') catch {};
    const out = w.buffered();
    _ = WriteFile(h, out.ptr, @intCast(out.len), null, null);
}

/// Record that a queued write of terminal `tag` completed, `n` bytes in
/// the pipe.
pub fn written(tag: usize, n: usize) void {
    if (comptime !enabled) return;
    while (busy.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    defer busy.store(false, .release);
    if (state == .unopened) open();
    const h = file orelse return;
    var buf: [64]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, "{d} = {x} {d}\n", .{ elapsedUs(), tag, n }) catch return;
    _ = WriteFile(h, out.ptr, @intCast(out.len), null, null);
}

fn elapsedUs() i64 {
    var now: i64 = 0;
    _ = QueryPerformanceCounter(&now);
    return @divTrunc((now - start) * 1_000_000, freq);
}

fn open() void {
    state = .off;
    const alloc = std.heap.page_allocator;
    const dir = global.environ().getAlloc(alloc, "GHOSTTY_PTY_LOG") catch return;
    defer alloc.free(dir);
    const path = std.fmt.allocPrint(alloc, "{s}\\pty-trace-{d}.log", .{ dir, GetCurrentProcessId() }) catch return;
    defer alloc.free(path);
    const path_w = std.unicode.wtf8ToWtf16LeAllocZ(alloc, path) catch return;
    defer alloc.free(path_w);
    const file_append_data = 0x0004;
    const file_share_read = 0x1;
    const create_always = 2;
    const file_attribute_normal = 0x80;
    const h = CreateFileW(path_w.ptr, file_append_data, file_share_read, null, create_always, file_attribute_normal, null);
    if (@intFromPtr(h) == std.math.maxInt(usize)) return;
    _ = QueryPerformanceFrequency(&freq);
    _ = QueryPerformanceCounter(&start);
    file = h;
    state = .open;
}
