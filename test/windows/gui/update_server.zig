//! A release list server for the update check scenarios (roadmap 7.6a):
//! HTTP/1.1 on 127.0.0.1 at a port Windows picks, on a thread of its own,
//! so no test reaches murrtty.org. It serves a made-up list with an ETag
//! (a 304 when murrtty sends that ETag back), a 503 with Retry-After, or
//! nothing at all (a connection held open: murrtty must not hang), and
//! records every request's head, so a scenario can check exactly what a
//! check sends. For downloads (7.6b) it serves release files at GitHub's
//! paths (`/releases/download/<tag>/<name>`): ranges as 206, slowly if
//! asked (to watch progress and cancel), or stopping part way with the
//! connection held (murrtty quitting mid-download).

const std = @import("std");

const SOCKET = usize;
const INVALID_SOCKET: SOCKET = std.math.maxInt(usize);
const AF_INET = 2;
const SOCK_STREAM = 1;
const IPPROTO_TCP = 6;
const SOL_SOCKET = 0xffff;
const SO_RCVTIMEO = 0x1006;
const SD_BOTH = 2;

const SockaddrIn = extern struct {
    family: u16 = AF_INET,
    port: u16 = 0,
    addr: u32 = 0,
    zero: [8]u8 = @splat(0),
};

extern "ws2_32" fn WSAStartup(u16, *[512]u8) callconv(.winapi) i32;
extern "ws2_32" fn socket(i32, i32, i32) callconv(.winapi) SOCKET;
extern "ws2_32" fn bind(SOCKET, *const SockaddrIn, i32) callconv(.winapi) i32;
extern "ws2_32" fn listen(SOCKET, i32) callconv(.winapi) i32;
extern "ws2_32" fn accept(SOCKET, ?*SockaddrIn, ?*i32) callconv(.winapi) SOCKET;
extern "ws2_32" fn recv(SOCKET, [*]u8, i32, i32) callconv(.winapi) i32;
extern "ws2_32" fn send(SOCKET, [*]const u8, i32, i32) callconv(.winapi) i32;
extern "ws2_32" fn shutdown(SOCKET, i32) callconv(.winapi) i32;
extern "ws2_32" fn closesocket(SOCKET) callconv(.winapi) i32;
extern "ws2_32" fn getsockname(SOCKET, *SockaddrIn, *i32) callconv(.winapi) i32;
extern "ws2_32" fn setsockopt(SOCKET, i32, i32, [*]const u8, i32) callconv(.winapi) i32;

const SRWLOCK = extern struct { ptr: ?*anyopaque = null };
extern "kernel32" fn AcquireSRWLockExclusive(*SRWLOCK) callconv(.winapi) void;
extern "kernel32" fn ReleaseSRWLockExclusive(*SRWLOCK) callconv(.winapi) void;
extern "kernel32" fn Sleep(u32) callconv(.winapi) void;

pub const Mode = enum {
    /// 200 with the list, or 304 when its ETag comes back.
    list,
    /// 503 with Retry-After.
    unavailable,
    /// Accept, read the request, never answer.
    hang,
};

/// A release list: 0.6.0 (stable) and 0.7.0-beta.1 (tip) newer than the
/// 0.5.0 the scenarios' murrtty pretends to be, and 0.5.0 itself.
pub const sample_list =
    \\{"schema":1,"releases":[
    \\{"version":"0.7.0-beta.1","tag":"murrtty-v0.7.0-beta.1","channel":"tip","preview":true,"date":"2026-12-01","title":"murrtty 0.7.0 beta 1","url":"https://github.com/murr2k/murrtty/releases/tag/murrtty-v0.7.0-beta.1","notes":"A test release.","files":{}},
    \\{"version":"0.6.0","tag":"murrtty-v0.6.0","channel":"stable","preview":true,"date":"2026-11-20","title":"murrtty 0.6.0","url":"https://github.com/murr2k/murrtty/releases/tag/murrtty-v0.6.0","notes":"### What's new\n\n- A test release.","files":{}},
    \\{"version":"0.5.0","tag":"murrtty-v0.5.0","channel":"stable","preview":true,"date":"2026-11-06","title":"murrtty 0.5.0","url":"https://github.com/murr2k/murrtty/releases/tag/murrtty-v0.5.0","notes":"","files":{}}]}
;

pub const Server = struct {
    alloc: std.mem.Allocator,
    sock: SOCKET,
    port: u16,
    thread: std.Thread,
    stopping: std.atomic.Value(bool) = .init(false),
    /// Requests read, and how many got a 304.
    requests: std.atomic.Value(u32) = .init(0),
    not_modified: std.atomic.Value(u32) = .init(0),

    lock: SRWLOCK = .{},
    mode: Mode = .list,
    body: []const u8 = sample_list,
    etag: []const u8 = "\"test-list-1\"",
    retry_after: u32 = 7200,
    /// The last request's head (request line and headers).
    last: [4096]u8 = undefined,
    last_len: usize = 0,
    /// Connections held open by `hang` (and a file's `hold_after`), closed
    /// at `stop`.
    held: [16]SOCKET = @splat(INVALID_SOCKET),
    /// Release files by path, the requests each got, and the last file
    /// request's Range header ("" for none).
    files: [8]File = undefined,
    files_len: usize = 0,
    file_hits: [8]std.atomic.Value(u32) = @splat(.init(0)),
    last_range: [64]u8 = undefined,
    last_range_len: usize = 0,
    /// A file's bytes per 50 ms (0: all at once), and where it stops with
    /// the connection held (null: never).
    throttle: usize = 0,
    hold_after: ?usize = null,

    pub const File = struct { path: []const u8, body: []const u8 };

    pub fn start(alloc: std.mem.Allocator) !*Server {
        var wsa: [512]u8 align(8) = undefined;
        if (WSAStartup(0x0202, &wsa) != 0) return error.Winsock;
        const sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (sock == INVALID_SOCKET) return error.Winsock;
        errdefer _ = closesocket(sock);
        // 127.0.0.1, port 0: Windows picks one.
        var addr: SockaddrIn = .{ .addr = std.mem.nativeToBig(u32, 0x7F000001) };
        if (bind(sock, &addr, @sizeOf(SockaddrIn)) != 0) return error.Winsock;
        if (listen(sock, 16) != 0) return error.Winsock;
        var len: i32 = @sizeOf(SockaddrIn);
        if (getsockname(sock, &addr, &len) != 0) return error.Winsock;
        const self = try alloc.create(Server);
        errdefer alloc.destroy(self);
        self.* = .{ .alloc = alloc, .sock = sock, .port = std.mem.bigToNative(u16, addr.port), .thread = undefined };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Stop listening (closing the socket ends the blocked accept), close
    /// what `hang` held, and free the server.
    pub fn stop(self: *Server) void {
        self.stopping.store(true, .release);
        _ = closesocket(self.sock);
        self.thread.join();
        for (&self.held) |*s| if (s.* != INVALID_SOCKET) {
            _ = closesocket(s.*);
            s.* = INVALID_SOCKET;
        };
        self.alloc.destroy(self);
    }

    /// The list's address, for GHOSTTY_WIN32_TEST_UPDATES_URL.
    pub fn url(self: *const Server, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}/updates/v1.json", .{self.port}) catch unreachable;
    }

    pub fn setMode(self: *Server, mode: Mode) void {
        AcquireSRWLockExclusive(&self.lock);
        defer ReleaseSRWLockExclusive(&self.lock);
        self.mode = mode;
    }

    pub fn setList(self: *Server, body: []const u8, etag: []const u8) void {
        AcquireSRWLockExclusive(&self.lock);
        defer ReleaseSRWLockExclusive(&self.lock);
        self.body = body;
        self.etag = etag;
    }

    /// Serve `body` at `path` (the caller keeps both alive), replacing a
    /// file at the same path.
    pub fn setFile(self: *Server, path: []const u8, body: []const u8) void {
        AcquireSRWLockExclusive(&self.lock);
        defer ReleaseSRWLockExclusive(&self.lock);
        for (self.files[0..self.files_len]) |*f| if (std.mem.eql(u8, f.path, path)) {
            f.body = body;
            return;
        };
        if (self.files_len == self.files.len) return;
        self.files[self.files_len] = .{ .path = path, .body = body };
        self.files_len += 1;
    }

    /// How files are sent: `throttle` bytes per 50 ms (0: at once), and
    /// held open after `hold_after` bytes (null: never).
    pub fn setPace(self: *Server, throttle: usize, hold_after: ?usize) void {
        AcquireSRWLockExclusive(&self.lock);
        defer ReleaseSRWLockExclusive(&self.lock);
        self.throttle = throttle;
        self.hold_after = hold_after;
    }

    /// Requests the file at `path` got.
    pub fn hits(self: *Server, path: []const u8) u32 {
        AcquireSRWLockExclusive(&self.lock);
        defer ReleaseSRWLockExclusive(&self.lock);
        for (self.files[0..self.files_len], 0..) |f, i| if (std.mem.eql(u8, f.path, path)) return self.file_hits[i].load(.acquire);
        return 0;
    }

    /// The last file request's Range header, copied into `buf`.
    pub fn lastRange(self: *Server, buf: []u8) []const u8 {
        AcquireSRWLockExclusive(&self.lock);
        defer ReleaseSRWLockExclusive(&self.lock);
        const n = @min(buf.len, self.last_range_len);
        @memcpy(buf[0..n], self.last_range[0..n]);
        return buf[0..n];
    }

    /// The last request's head, copied into `buf`.
    pub fn lastRequest(self: *Server, buf: []u8) []const u8 {
        AcquireSRWLockExclusive(&self.lock);
        defer ReleaseSRWLockExclusive(&self.lock);
        const n = @min(buf.len, self.last_len);
        @memcpy(buf[0..n], self.last[0..n]);
        return buf[0..n];
    }

    fn run(self: *Server) void {
        while (!self.stopping.load(.acquire)) {
            const client = accept(self.sock, null, null);
            if (client == INVALID_SOCKET) {
                if (self.stopping.load(.acquire)) return;
                continue;
            }
            self.serve(client);
        }
    }

    fn serve(self: *Server, client: SOCKET) void {
        // A request that never ends doesn't hold the server.
        const timeout_ms: u32 = 5000;
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, std.mem.asBytes(&timeout_ms), @sizeOf(u32));
        var buf: [4096]u8 = undefined;
        var got: usize = 0;
        while (got < buf.len) {
            const n = recv(client, buf[got..].ptr, @intCast(buf.len - got), 0);
            if (n <= 0) break;
            got += @intCast(n);
            if (std.mem.indexOf(u8, buf[0..got], "\r\n\r\n") != null) break;
        }
        const head_end = if (std.mem.indexOf(u8, buf[0..got], "\r\n\r\n")) |i| i else got;
        const head = buf[0..head_end];

        // A release file?
        if (self.serveFile(client, head)) return;

        AcquireSRWLockExclusive(&self.lock);
        @memcpy(self.last[0..head.len], head);
        self.last_len = head.len;
        const mode = self.mode;
        const body = self.body;
        const etag = self.etag;
        const retry_after = self.retry_after;
        if (mode == .hang) {
            for (&self.held) |*s| if (s.* == INVALID_SOCKET) {
                s.* = client;
                break;
            };
        }
        ReleaseSRWLockExclusive(&self.lock);
        _ = self.requests.fetchAdd(1, .acq_rel);
        if (mode == .hang) return;

        var out: [256]u8 = undefined;
        switch (mode) {
            .list => if (header(head, "if-none-match")) |sent| if (std.mem.eql(u8, sent, etag)) {
                _ = self.not_modified.fetchAdd(1, .acq_rel);
                const msg = std.fmt.bufPrint(&out, "HTTP/1.1 304 Not Modified\r\nETag: {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{etag}) catch unreachable;
                sendAll(client, msg);
                return finish(client);
            },
            .unavailable => {
                const msg = std.fmt.bufPrint(&out, "HTTP/1.1 503 Service Unavailable\r\nRetry-After: {d}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{retry_after}) catch unreachable;
                sendAll(client, msg);
                return finish(client);
            },
            .hang => unreachable,
        }
        const msg = std.fmt.bufPrint(&out, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nETag: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ etag, body.len }) catch unreachable;
        sendAll(client, msg);
        sendAll(client, body);
        finish(client);
    }

    /// Serve a release file if `head` asks for one: whole (200) or from a
    /// range's start (206; 416 past its end), at the pace set. False when
    /// the path is no file's.
    fn serveFile(self: *Server, client: SOCKET, head: []const u8) bool {
        const line_end = std.mem.indexOf(u8, head, "\r\n") orelse head.len;
        var parts = std.mem.tokenizeScalar(u8, head[0..line_end], ' ');
        _ = parts.next();
        const path = parts.next() orelse return false;
        AcquireSRWLockExclusive(&self.lock);
        var body: ?[]const u8 = null;
        for (self.files[0..self.files_len], 0..) |f, i| if (std.mem.eql(u8, f.path, path)) {
            body = f.body;
            _ = self.file_hits[i].fetchAdd(1, .acq_rel);
        };
        if (body == null) {
            ReleaseSRWLockExclusive(&self.lock);
            return false;
        }
        @memcpy(self.last[0..head.len], head);
        self.last_len = head.len;
        const range = header(head, "range") orelse "";
        const n = @min(range.len, self.last_range.len);
        @memcpy(self.last_range[0..n], range[0..n]);
        self.last_range_len = n;
        const throttle = self.throttle;
        const hold_after = self.hold_after;
        ReleaseSRWLockExclusive(&self.lock);
        _ = self.requests.fetchAdd(1, .acq_rel);

        const data = body.?;
        var from: usize = 0;
        if (std.mem.startsWith(u8, range, "bytes=") and std.mem.endsWith(u8, range, "-")) {
            from = std.fmt.parseInt(usize, range["bytes=".len .. range.len - 1], 10) catch 0;
        }
        var out: [256]u8 = undefined;
        if (from >= data.len and from > 0) {
            const msg = std.fmt.bufPrint(&out, "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{d}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{data.len}) catch unreachable;
            sendAll(client, msg);
            finish(client);
            return true;
        }
        const msg = if (from > 0)
            std.fmt.bufPrint(&out, "HTTP/1.1 206 Partial Content\r\nContent-Type: application/octet-stream\r\nContent-Range: bytes {d}-{d}/{d}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ from, data.len - 1, data.len, data.len - from }) catch unreachable
        else
            std.fmt.bufPrint(&out, "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{data.len}) catch unreachable;
        sendAll(client, msg);
        var off = from;
        var sent: usize = 0;
        while (off < data.len) {
            if (self.stopping.load(.acquire)) break;
            if (hold_after) |limit| if (sent >= limit) {
                // Part way: held open, as a connection gone quiet.
                AcquireSRWLockExclusive(&self.lock);
                defer ReleaseSRWLockExclusive(&self.lock);
                for (&self.held) |*s| if (s.* == INVALID_SOCKET) {
                    s.* = client;
                    return true;
                };
                break;
            };
            var piece = if (throttle > 0) @min(throttle, data.len - off) else data.len - off;
            if (hold_after) |limit| piece = @min(piece, limit - sent);
            if (!sendSome(client, data[off .. off + piece])) break;
            off += piece;
            sent += piece;
            if (throttle > 0) Sleep(50);
        }
        finish(client);
        return true;
    }

    fn finish(client: SOCKET) void {
        _ = shutdown(client, SD_BOTH);
        _ = closesocket(client);
    }

    fn sendAll(client: SOCKET, data: []const u8) void {
        _ = sendSome(client, data);
    }

    /// All of `data`; false once the other end is gone.
    fn sendSome(client: SOCKET, data: []const u8) bool {
        var off: usize = 0;
        while (off < data.len) {
            const n = send(client, data[off..].ptr, @intCast(@min(data.len - off, 1 << 20)), 0);
            if (n <= 0) return false;
            off += @intCast(n);
        }
        return true;
    }
};

/// A header's value in a request's head (name in lower case), or null.
pub fn header(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}
