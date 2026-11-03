//! The update list's request (roadmap 7.6a): one HTTPS GET through
//! WinHTTP (Windows' proxy settings and certificate store), on a thread of
//! its own, so nothing about the network (proxy detection alone can take
//! seconds) ever runs on the UI thread.
//!
//! A `Job` is shared by the UI thread and its thread, reference counted:
//! the thread writes its results, sets `done`, then posts the window's
//! message with no pointer (as the single instance's pipe thread does) and
//! signals `finished`. The UI never waits for it and never touches its
//! WinHTTP handles: closing a synchronous request's handle from another
//! thread is a race WinHTTP's documentation forbids. To cancel, or as
//! murrtty quits, the UI marks the job cancelled and lets go of it
//! (`abandon`); the thread stops at its next step, or when its time
//! limits end a blocked call, and frees the job as the last to let go (a
//! quit ends it with the process). Its memory comes from the page
//! allocator, not murrtty's, so a job still finishing as murrtty quits is
//! no leak and touches nothing freed.
//!
//! winhttp.dll is loaded from System32 at the first request; a murrtty that
//! never checks never loads it.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const internal_os = @import("../../os/main.zig");
const c = @import("c.zig");
const text_util = @import("text.zig");
const update_list = @import("update_list.zig");

const log = std.log.scoped(.win32_updates);

/// Every request's user agent: the name alone, no version.
pub const user_agent = "murrtty";

/// The largest list taken (today's is a few kilobytes).
pub const max_body = 4 * 1024 * 1024;

/// Time limits, in milliseconds: name lookup, connecting, sending, and
/// each wait for data; and the whole request.
const timeout_resolve = 10_000;
const timeout_connect = 10_000;
const timeout_send = 10_000;
const timeout_receive = 30_000;
const timeout_total_ms = 30_000;

const HINTERNET = *anyopaque;

const WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY: u32 = 4;
const WINHTTP_FLAG_SECURE: u32 = 0x00800000;
const WINHTTP_OPTION_DECOMPRESSION: u32 = 118;
const WINHTTP_DECOMPRESSION_FLAG_ALL: u32 = 3;
const WINHTTP_OPTION_DISABLE_FEATURE: u32 = 63;
const WINHTTP_DISABLE_COOKIES: u32 = 1;
const WINHTTP_QUERY_STATUS_CODE: u32 = 19;
const WINHTTP_QUERY_RETRY_AFTER: u32 = 36;
const WINHTTP_QUERY_ETAG: u32 = 54;
const WINHTTP_QUERY_FLAG_NUMBER: u32 = 0x20000000;
const WINHTTP_ADDREQ_FLAG_ADD: u32 = 0x20000000;

/// WinHTTP's errors a person is told about in words (Updates.zig).
pub const ERROR_WINHTTP_TIMEOUT: u32 = 12002;
pub const ERROR_WINHTTP_NAME_NOT_RESOLVED: u32 = 12007;
pub const ERROR_WINHTTP_OPERATION_CANCELLED: u32 = 12017;
pub const ERROR_WINHTTP_CANNOT_CONNECT: u32 = 12029;
pub const ERROR_WINHTTP_SECURE_FAILURE: u32 = 12175;

// The network's cost (netlistmgr.h), for automatic checks on a metered
// connection.
const CLSID_NetworkListManager = c.GUID.parse("{DCB00C01-570F-4A9B-8D69-199FDBA5723B}");
const IID_INetworkCostManager = c.GUID.parse("{DCB00008-570F-4A9B-8D69-199FDBA5723B}");
const NLM_CONNECTION_COST_FIXED: u32 = 0x2;
const NLM_CONNECTION_COST_VARIABLE: u32 = 0x4;
const NLM_CONNECTION_COST_OVERDATALIMIT: u32 = 0x10000;
const NLM_CONNECTION_COST_ROAMING: u32 = 0x40000;
const CLSCTX_ALL: u32 = 0x17;
const COINIT_MULTITHREADED: u32 = 0x0;

const INetworkCostManager = extern struct {
    vtbl: *const extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const fn (*INetworkCostManager) callconv(.winapi) u32,
        Release: *const fn (*INetworkCostManager) callconv(.winapi) u32,
        GetCost: *const fn (*INetworkCostManager, *u32, ?*const anyopaque) callconv(.winapi) c.HRESULT,
        GetDataPlanStatus: *const anyopaque,
        SetDestinationAddresses: *const anyopaque,
    },
};

/// The functions taken from System32's winhttp.dll.
const Api = struct {
    Open: *const fn (?c.LPCWSTR, u32, ?c.LPCWSTR, ?c.LPCWSTR, u32) callconv(.winapi) ?HINTERNET,
    Connect: *const fn (HINTERNET, c.LPCWSTR, u16, u32) callconv(.winapi) ?HINTERNET,
    OpenRequest: *const fn (HINTERNET, ?c.LPCWSTR, c.LPCWSTR, ?c.LPCWSTR, ?c.LPCWSTR, ?*const ?c.LPCWSTR, u32) callconv(.winapi) ?HINTERNET,
    AddRequestHeaders: *const fn (HINTERNET, c.LPCWSTR, u32, u32) callconv(.winapi) c.BOOL,
    SetOption: *const fn (?HINTERNET, u32, ?*const anyopaque, u32) callconv(.winapi) c.BOOL,
    SetTimeouts: *const fn (HINTERNET, c_int, c_int, c_int, c_int) callconv(.winapi) c.BOOL,
    SendRequest: *const fn (HINTERNET, ?c.LPCWSTR, u32, ?*anyopaque, u32, u32, usize) callconv(.winapi) c.BOOL,
    ReceiveResponse: *const fn (HINTERNET, ?*anyopaque) callconv(.winapi) c.BOOL,
    QueryHeaders: *const fn (HINTERNET, u32, ?c.LPCWSTR, ?*anyopaque, *u32, ?*u32) callconv(.winapi) c.BOOL,
    QueryDataAvailable: *const fn (HINTERNET, *u32) callconv(.winapi) c.BOOL,
    ReadData: *const fn (HINTERNET, [*]u8, u32, *u32) callconv(.winapi) c.BOOL,
    CloseHandle: *const fn (HINTERNET) callconv(.winapi) c.BOOL,

    fn load() ?Api {
        const dll = c.LoadLibraryExW(c.L("winhttp.dll"), null, c.LOAD_LIBRARY_SEARCH_SYSTEM32) orelse return null;
        var api: Api = undefined;
        inline for (@typeInfo(Api).@"struct".field_names) |name| {
            // @alignCast too: GetProcAddress's pointer is byte-aligned, a
            // function's isn't on ARM64.
            @field(api, name) = @ptrCast(@alignCast(c.GetProcAddress(dll, "WinHttp" ++ name) orelse return null));
        }
        return api;
    }
};

pub const Outcome = enum {
    /// 200, with the list in `body`.
    ok,
    /// 304: the list is the one whose ETag was sent.
    not_modified,
    /// Another status (`status`), with the server's Retry-After if any.
    http_error,
    /// No answer: `stage` and `error_code` say where and why.
    failed,
    /// An automatic check on a metered connection: nothing was sent.
    metered,
    /// Cancelled before an answer.
    cancelled,
};

/// Where a request that got no answer stopped.
pub const Stage = enum { load, open, connect, request, send, receive, read, too_big, timeout };

pub const Options = struct {
    url: []const u8,
    /// The cached list's ETag, sent back as If-None-Match.
    etag: ?[]const u8 = null,
    /// An automatic check: it waits on a metered connection.
    automatic: bool,
    /// Stands in for the connection's cost (the GUI tests' variable).
    metered: ?bool = null,
    /// Where `msg` is posted when the job is done.
    hwnd: c.HWND,
    msg: c.UINT,
};

pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    refs: std.atomic.Value(u32) = .init(2),
    /// Set once the thread's results below are written.
    done: std.atomic.Value(bool) = .init(false),
    /// Signalled when the thread lets go of WinHTTP (manual reset).
    finished: c.HANDLE,
    /// The window to tell (0 once abandoned).
    hwnd: std.atomic.Value(usize),
    msg: c.UINT,

    // What to ask, fixed at the start.
    secure: bool,
    host: [:0]const u16,
    port: u16,
    path: [:0]const u16,
    if_none_match: ?[:0]const u16,
    automatic: bool,
    metered_override: ?bool,
    started_ms: u64,

    /// The UI let go of the job: its answer goes unused.
    cancelled: std.atomic.Value(bool) = .init(false),

    // The results, the thread's until `done`.
    outcome: Outcome = .failed,
    stage: Stage = .load,
    error_code: u32 = 0,
    status: u32 = 0,
    body: []const u8 = "",
    etag: ?[]const u8 = null,
    retry_after: ?u32 = null,
    elapsed_ms: u64 = 0,

    /// Start a request on a thread of its own. The caller holds one
    /// reference: `release` (or `abandon`) it.
    pub fn start(opts: Options) !*Job {
        const url = try update_list.Url.parse(opts.url);
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        const job = make(&arena, opts, url) catch |err| {
            arena.deinit();
            return err;
        };
        // The job lives in its arena, whose state moves in with it: from
        // here on only `job.arena` allocates.
        job.arena = arena;
        const thread = std.Thread.spawn(internal_os.thread.spawnConfig(), run, .{job}) catch |err| {
            _ = c.CloseHandle(job.finished);
            const dead = job.arena;
            dead.deinit();
            return err;
        };
        thread.detach();
        return job;
    }

    fn make(arena: *std.heap.ArenaAllocator, opts: Options, url: update_list.Url) !*Job {
        const a = arena.allocator();
        const job = try a.create(Job);
        job.* = .{
            .arena = undefined,
            .finished = undefined,
            .hwnd = .init(@intFromPtr(opts.hwnd)),
            .msg = opts.msg,
            .secure = url.secure,
            .host = try text_util.utf16Lossy(a, url.host),
            .port = url.port,
            .path = try text_util.utf16Lossy(a, url.path),
            .if_none_match = if (opts.etag) |e| header: {
                // A value that could end the header line is no ETag.
                if (e.len == 0 or std.mem.indexOfAny(u8, e, "\r\n") != null) break :header null;
                const line = try std.fmt.allocPrint(a, "If-None-Match: {s}", .{e});
                break :header try text_util.utf16Lossy(a, line);
            } else null,
            .automatic = opts.automatic,
            .metered_override = opts.metered,
            .started_ms = c.GetTickCount64(),
        };
        job.finished = c.CreateEventW(null, c.TRUE, c.FALSE, null) orelse return error.CreateEvent;
        return job;
    }

    /// The UI's results: valid once `done` is true.
    pub fn isDone(self: *const Job) bool {
        return self.done.load(.acquire);
    }

    /// Wait up to `ms` for the thread to be done (the unit tests).
    pub fn wait(self: *Job, ms: u32) bool {
        return c.WaitForSingleObject(self.finished, ms) == c.WAIT_OBJECT_0;
    }

    /// Let go of the job without waiting: the thread stops at its next step
    /// (or when a blocked call's time limit ends it), tells no window, and
    /// frees the job.
    pub fn abandon(self: *Job) void {
        self.hwnd.store(0, .release);
        self.cancelled.store(true, .release);
        self.release();
    }

    pub fn release(self: *Job) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        _ = c.CloseHandle(self.finished);
        var arena = self.arena;
        arena.deinit();
    }

    fn fail(self: *Job, stage: Stage, err: u32) void {
        self.stage = stage;
        self.error_code = err;
        const cancelled = self.cancelled.load(.acquire) or err == ERROR_WINHTTP_OPERATION_CANCELLED;
        self.outcome = if (cancelled) .cancelled else .failed;
    }

    fn timedOut(self: *const Job) bool {
        return c.GetTickCount64() -| self.started_ms > timeout_total_ms;
    }

    fn isCancelled(self: *const Job) bool {
        return self.cancelled.load(.acquire);
    }

    /// The request, on the job's own thread.
    fn run(self: *Job) void {
        defer self.finish();
        if (self.automatic) {
            const metered = self.metered_override orelse isMetered();
            if (metered) {
                self.outcome = .metered;
                return;
            }
        }
        const api = Api.load() orelse return self.fail(.load, c.GetLastError());
        self.fetch(api);
    }

    fn finish(self: *Job) void {
        self.elapsed_ms = c.GetTickCount64() -| self.started_ms;
        self.done.store(true, .release);
        const hwnd = self.hwnd.load(.acquire);
        if (hwnd != 0) _ = c.PostMessageW(@ptrFromInt(hwnd), self.msg, 0, 0);
        _ = c.SetEvent(self.finished);
        self.release();
    }

    fn fetch(self: *Job, api: Api) void {
        const session = api.Open(c.L(user_agent), WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, null, null, 0) orelse
            return self.fail(.open, c.GetLastError());
        defer _ = api.CloseHandle(session);
        _ = api.SetTimeouts(session, timeout_resolve, timeout_connect, timeout_send, timeout_receive);
        const decompress: u32 = WINHTTP_DECOMPRESSION_FLAG_ALL;
        _ = api.SetOption(session, WINHTTP_OPTION_DECOMPRESSION, &decompress, @sizeOf(u32));
        const connect = api.Connect(session, self.host.ptr, self.port, 0) orelse
            return self.fail(.connect, c.GetLastError());
        defer _ = api.CloseHandle(connect);
        const request = api.OpenRequest(connect, c.L("GET"), self.path.ptr, null, null, null, if (self.secure) WINHTTP_FLAG_SECURE else 0) orelse
            return self.fail(.request, c.GetLastError());
        defer _ = api.CloseHandle(request);
        const no_cookies: u32 = WINHTTP_DISABLE_COOKIES;
        _ = api.SetOption(request, WINHTTP_OPTION_DISABLE_FEATURE, &no_cookies, @sizeOf(u32));
        if (self.if_none_match) |h| _ = api.AddRequestHeaders(request, h.ptr, std.math.maxInt(u32), WINHTTP_ADDREQ_FLAG_ADD);

        if (self.isCancelled()) return self.fail(.send, ERROR_WINHTTP_OPERATION_CANCELLED);
        if (api.SendRequest(request, null, 0, null, 0, 0, 0) == 0) return self.fail(.send, c.GetLastError());
        if (self.isCancelled()) return self.fail(.receive, ERROR_WINHTTP_OPERATION_CANCELLED);
        if (api.ReceiveResponse(request, null) == 0) return self.fail(.receive, c.GetLastError());
        if (self.isCancelled()) return self.fail(.receive, ERROR_WINHTTP_OPERATION_CANCELLED);

        self.status = queryNumber(api, request, WINHTTP_QUERY_STATUS_CODE) orelse 0;
        self.etag = self.queryText(api, request, WINHTTP_QUERY_ETAG);
        switch (self.status) {
            304 => {
                self.outcome = .not_modified;
                return;
            },
            200 => {},
            else => {
                if (self.queryText(api, request, WINHTTP_QUERY_RETRY_AFTER)) |v| self.retry_after = update_list.parseRetryAfter(v);
                self.outcome = .http_error;
                return;
            },
        }

        const a = self.arena.allocator();
        var body: std.ArrayList(u8) = .empty;
        while (true) {
            if (self.isCancelled()) return self.fail(.read, ERROR_WINHTTP_OPERATION_CANCELLED);
            if (self.timedOut()) return self.fail(.timeout, ERROR_WINHTTP_TIMEOUT);
            var avail: u32 = 0;
            if (api.QueryDataAvailable(request, &avail) == 0) return self.fail(.read, c.GetLastError());
            if (avail == 0) break;
            if (body.items.len + avail > max_body) return self.fail(.too_big, 0);
            const dst = body.addManyAsSlice(a, avail) catch return self.fail(.read, 0);
            var got: u32 = 0;
            if (api.ReadData(request, dst.ptr, avail, &got) == 0) return self.fail(.read, c.GetLastError());
            body.shrinkRetainingCapacity(body.items.len - avail + got);
            if (got == 0) break;
        }
        self.body = body.items;
        self.outcome = .ok;
    }

    fn queryText(self: *Job, api: Api, request: HINTERNET, level: u32) ?[]const u8 {
        var buf: [256]u16 = undefined;
        var len: u32 = @sizeOf(@TypeOf(buf));
        if (api.QueryHeaders(request, level, null, &buf, &len, null) == 0) return null;
        const units = buf[0 .. len / 2];
        return std.unicode.utf16LeToUtf8Alloc(self.arena.allocator(), units) catch null;
    }
};

fn queryNumber(api: Api, request: HINTERNET, level: u32) ?u32 {
    var n: u32 = 0;
    var len: u32 = @sizeOf(u32);
    if (api.QueryHeaders(request, level | WINHTTP_QUERY_FLAG_NUMBER, null, &n, &len, null) == 0) return null;
    return n;
}

/// Whether Windows says the connection is metered (a data plan, roaming,
/// over its limit, or the user's "metered connection" switch): automatic
/// checks wait for another. Unknown counts as not.
fn isMetered() bool {
    const hr = c.CoInitializeEx(null, COINIT_MULTITHREADED);
    defer if (hr >= 0) c.CoUninitialize();
    var obj: ?*anyopaque = null;
    if (c.CoCreateInstance(&CLSID_NetworkListManager, null, CLSCTX_ALL, &IID_INetworkCostManager, &obj) < 0) return false;
    const mgr: *INetworkCostManager = @ptrCast(@alignCast(obj orelse return false));
    defer _ = mgr.vtbl.Release(mgr);
    var cost: u32 = 0;
    if (mgr.vtbl.GetCost(mgr, &cost, null) < 0) return false;
    return cost & (NLM_CONNECTION_COST_FIXED | NLM_CONNECTION_COST_VARIABLE |
        NLM_CONNECTION_COST_OVERDATALIMIT | NLM_CONNECTION_COST_ROAMING) != 0;
}

test "update fetch: winhttp's functions and the network's cost load" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.expect(Api.load() != null);
    // Whatever the answer, asking works (unit tests run on any network).
    _ = isMetered();
}

test "update fetch: a request to a closed port fails, without hanging" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // A message-only window to post to.
    const hwnd = c.CreateWindowExW(0, c.L("STATIC"), c.L(""), 0, 0, 0, 0, 0, c.HWND_MESSAGE, null, null, null) orelse return error.SkipZigTest;
    defer _ = c.DestroyWindow(hwnd);
    // Port 9 (discard) on the loopback address: refused at once.
    const job = try Job.start(.{ .url = "http://127.0.0.1:9/updates/v1.json", .automatic = false, .hwnd = hwnd, .msg = c.WM_APP + 77 });
    defer job.release();
    try std.testing.expect(job.wait(20_000));
    try std.testing.expect(job.isDone());
    try std.testing.expectEqual(Outcome.failed, job.outcome);
    try std.testing.expect(job.error_code != 0);
}

test "update fetch: cancelling ends the job" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const hwnd = c.CreateWindowExW(0, c.L("STATIC"), c.L(""), 0, 0, 0, 0, 0, c.HWND_MESSAGE, null, null, null) orelse return error.SkipZigTest;
    defer _ = c.DestroyWindow(hwnd);
    const job = try Job.start(.{ .url = "http://127.0.0.1:9/x", .automatic = false, .hwnd = hwnd, .msg = c.WM_APP + 77 });
    // As abandon marks it, while keeping this test's reference to look.
    job.cancelled.store(true, .release);
    try std.testing.expect(job.wait(20_000));
    try std.testing.expect(job.outcome == .cancelled or job.outcome == .failed);
    job.release();
    // Abandoned: the thread frees it, telling no window.
    const gone = try Job.start(.{ .url = "http://127.0.0.1:9/x", .automatic = false, .hwnd = hwnd, .msg = c.WM_APP + 77 });
    gone.abandon();
    // An automatic check on a metered connection sends nothing.
    const metered = try Job.start(.{ .url = "http://127.0.0.1:9/x", .automatic = true, .metered = true, .hwnd = hwnd, .msg = c.WM_APP + 77 });
    defer metered.release();
    try std.testing.expect(metered.wait(5_000));
    try std.testing.expectEqual(Outcome.metered, metered.outcome);
}
