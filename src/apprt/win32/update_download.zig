//! An update's download (roadmap 7.6b): the release's SHA256SUMS.txt.sig and
//! SHA256SUMS.txt, checked (update_verify.zig) before anything else is
//! fetched, then the installer, resumed where an earlier download stopped,
//! its SHA-256 worked out as it is written and compared with the signed one
//! before it is given its name. All of it on a thread of its own at
//! background priority (its CPU and disk use yield to everything else), as
//! update_fetch's check: the UI never waits for it. The same job, in
//! `verify` mode, checks a kept installer again before it runs (Install
//! Now), reading the kept sums and signature and hashing the installer
//! while holding it, and hands the held file to the UI.
//!
//! The `Job` is shared the same way as a check's: reference counted, its
//! messages posted with no pointer, abandoned to cancel (the thread stops at
//! its next step and frees it) or as murrtty quits (the thread ends with the
//! process; what it wrote is a prefix of the file, which the next download
//! resumes and the final hash checks). Its memory is the page allocator's.
//! A job started after a cancelled one (`after`) waits for that one's thread
//! to end before it touches the folder: a cancelled thread lets go of the
//! file only at its next step, which a slow network can hold back for the
//! time limits' length.
//!
//! Files, in the release's folder (`<state>\updates\download\<version>`):
//! the signature and the sums as downloaded (checked again before the
//! installer runs), `<name>.partial` while downloading (held without write
//! sharing: a second murrtty gets `busy`), and `<name>` once it matches. A
//! refusal deletes all of them, and so does a job `discard`ed (Clear Cached
//! Update Information) as its thread ends.

const std = @import("std");
const builtin = @import("builtin");
const internal_os = @import("../../os/main.zig");
const c = @import("c.zig");
const text_util = @import("text.zig");
const update_list = @import("update_list.zig");
const update_fetch = @import("update_fetch.zig");
const update_verify = @import("update_verify.zig");

const log = std.log.scoped(.win32_updates);
const Sha256 = std.crypto.hash.sha2.Sha256;
const Api = update_fetch.Api;
const HINTERNET = update_fetch.HINTERNET;

/// Time limits, in milliseconds: name lookup, connecting, sending, each
/// wait for data; and the signature's and the sums' whole requests.
const timeout_resolve = 10_000;
const timeout_connect = 10_000;
const timeout_send = 10_000;
const timeout_receive = 60_000;
const small_total_ms = 60_000;
/// Progress is told at most this often.
const progress_ms = 200;
/// Waits of 250 ms for a `.partial` another murrtty holds, before `busy`.
const busy_tries = 20;
const chunk = 64 * 1024;

const WINHTTP_QUERY_CONTENT_LENGTH: u32 = 5;
const WINHTTP_QUERY_CONTENT_RANGE: u32 = 53;
const CANCELLED = update_fetch.ERROR_WINHTTP_OPERATION_CANCELLED;
const TIMEOUT = update_fetch.ERROR_WINHTTP_TIMEOUT;
const ERROR_HANDLE_EOF = 38;

pub const Mode = enum {
    /// Download and check the installer.
    download,
    /// Check the kept installer again (its sums, their signature, its
    /// hash), holding it for the UI to run (`held`).
    verify,
};

pub const Outcome = enum {
    /// The installer is in place under its name and matched its signed
    /// hash (`verify`: and `held` is open on it).
    ready,
    /// A check failed (`refusal`): everything downloaded is deleted.
    refused,
    /// No answer, an HTTP error, an answer that wasn't the file asked for,
    /// a file that couldn't be written: what was downloaded stays, to
    /// resume.
    failed,
    cancelled,
    /// Another murrtty is downloading the same file.
    busy,
    /// `verify`: the kept files aren't there any more.
    gone,
};

/// Where a failed download stopped. `answer`: what came wasn't the file
/// asked for (a proxy's page in a signature's place, say).
pub const Stage = enum { load, open, connect, request, send, receive, read, http, answer, write, incomplete };

pub const Options = struct {
    mode: Mode = .download,
    signature_url: []const u8 = "",
    sums_url: []const u8 = "",
    file_url: []const u8 = "",
    /// The installer's name (update_verify.setupName), which the signed
    /// sums must give.
    name: []const u8,
    /// The release's folder, made by the caller.
    dir: []const u8,
    keys: []const [32]u8,
    /// A cancelled job whose thread may still hold the folder's files: this
    /// one waits for it to end first. The caller may let go of it after
    /// `start` returns.
    after: ?*Job = null,
    hwnd: c.HWND,
    done_msg: c.UINT,
    progress_msg: c.UINT,
};

pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    refs: std.atomic.Value(u32) = .init(2),
    done: std.atomic.Value(bool) = .init(false),
    finished: c.HANDLE,
    /// The window to tell (0 once abandoned).
    hwnd: std.atomic.Value(usize),
    done_msg: c.UINT,
    progress_msg: c.UINT,
    cancelled: std.atomic.Value(bool) = .init(false),
    /// Delete the release's files as the thread ends (Clear Cached Update
    /// Information while it ran).
    discard: std.atomic.Value(bool) = .init(false),

    // What to do, fixed at the start.
    mode: Mode,
    signature_url: []const u8,
    sums_url: []const u8,
    file_url: []const u8,
    name: []const u8,
    keys: []const [32]u8,
    /// The cancelled job's `finished`, duplicated: waited for, then closed.
    wait_for: ?c.HANDLE = null,
    dir_path: [:0]const u16,
    signature_path: [:0]const u16,
    sums_path: [:0]const u16,
    partial_path: [:0]const u16,
    final_path: [:0]const u16,

    /// The installer's bytes so far and in all (0 until known), for the
    /// progress shown; `progress_pending` while a progress message waits
    /// for the UI (one at a time).
    received: std.atomic.Value(u64) = .init(0),
    total: std.atomic.Value(u64) = .init(0),
    progress_pending: std.atomic.Value(bool) = .init(false),
    last_progress_ms: u64 = 0,

    // The results, the thread's until `done`.
    outcome: Outcome = .failed,
    refusal: update_verify.Refusal = .bad_signature,
    stage: Stage = .load,
    error_code: u32 = 0,
    status: u32 = 0,
    /// Where the installer's download picked up (0: from its start).
    resumed_from: u64 = 0,
    /// `verify`: the installer, opened without write or delete sharing, for
    /// the UI to run before closing (`takeHeld`); closed with the job if
    /// nobody took it.
    held: ?c.HANDLE = null,

    /// Start a job on a thread of its own. The caller holds one reference:
    /// `release` (or `abandon`) it.
    pub fn start(opts: Options) !*Job {
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        const job = make(&arena, opts) catch |err| {
            arena.deinit();
            return err;
        };
        job.arena = arena;
        const thread = std.Thread.spawn(internal_os.thread.spawnConfig(), run, .{job}) catch |err| {
            job.closeHandles();
            const dead = job.arena;
            dead.deinit();
            return err;
        };
        thread.detach();
        return job;
    }

    fn make(arena: *std.heap.ArenaAllocator, opts: Options) !*Job {
        const a = arena.allocator();
        const job = try a.create(Job);
        const file = try std.fmt.allocPrint(a, "{s}\\{s}", .{ opts.dir, opts.name });
        job.* = .{
            .arena = undefined,
            .finished = undefined,
            .hwnd = .init(@intFromPtr(opts.hwnd)),
            .done_msg = opts.done_msg,
            .progress_msg = opts.progress_msg,
            .mode = opts.mode,
            .signature_url = try a.dupe(u8, opts.signature_url),
            .sums_url = try a.dupe(u8, opts.sums_url),
            .file_url = try a.dupe(u8, opts.file_url),
            .name = try a.dupe(u8, opts.name),
            .keys = try a.dupe([32]u8, opts.keys),
            .dir_path = try text_util.utf16Lossy(a, opts.dir),
            .signature_path = try text_util.utf16Lossy(a, try std.fmt.allocPrint(a, "{s}\\SHA256SUMS.txt.sig", .{opts.dir})),
            .sums_path = try text_util.utf16Lossy(a, try std.fmt.allocPrint(a, "{s}\\SHA256SUMS.txt", .{opts.dir})),
            .partial_path = try text_util.utf16Lossy(a, try std.fmt.allocPrint(a, "{s}.partial", .{file})),
            .final_path = try text_util.utf16Lossy(a, file),
        };
        job.finished = c.CreateEventW(null, c.TRUE, c.FALSE, null) orelse return error.CreateEvent;
        if (opts.after) |prev| {
            var dup: c.HANDLE = undefined;
            const self_process = c.GetCurrentProcess();
            if (c.DuplicateHandle(self_process, prev.finished, self_process, &dup, 0, c.FALSE, c.DUPLICATE_SAME_ACCESS) != 0) job.wait_for = dup;
        }
        return job;
    }

    fn closeHandles(self: *Job) void {
        _ = c.CloseHandle(self.finished);
        if (self.wait_for) |h| _ = c.CloseHandle(h);
        self.wait_for = null;
        if (self.held) |h| _ = c.CloseHandle(h);
        self.held = null;
    }

    pub fn isDone(self: *const Job) bool {
        return self.done.load(.acquire);
    }

    /// Wait up to `ms` for the thread to be done (the unit tests).
    pub fn wait(self: *Job, ms: u32) bool {
        return c.WaitForSingleObject(self.finished, ms) == c.WAIT_OBJECT_0;
    }

    /// The UI read the progress: the next may be posted.
    pub fn progressSeen(self: *Job) void {
        self.progress_pending.store(false, .release);
    }

    /// `verify`, done and ready: the held installer, the caller's to close.
    pub fn takeHeld(self: *Job) ?c.HANDLE {
        const h = self.held;
        self.held = null;
        return h;
    }

    /// Stop without letting go: the thread stops at its next step and tells
    /// no window; the caller keeps its reference (to start the next job
    /// `after` it, or to `discard` it) and releases it later. What it
    /// downloaded stays, to resume.
    pub fn cancel(self: *Job) void {
        self.hwnd.store(0, .release);
        self.cancelled.store(true, .release);
    }

    /// Cancel and let go.
    pub fn abandon(self: *Job) void {
        self.cancel();
        self.release();
    }

    pub fn release(self: *Job) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        self.closeHandles();
        var arena = self.arena;
        arena.deinit();
    }

    fn isCancelled(self: *const Job) bool {
        return self.cancelled.load(.acquire);
    }

    fn fail(self: *Job, stage: Stage, err: u32) void {
        self.stage = stage;
        self.error_code = err;
        self.outcome = if (self.isCancelled() or err == CANCELLED) .cancelled else .failed;
    }

    fn refuse(self: *Job, why: update_verify.Refusal) void {
        self.refusal = why;
        self.outcome = .refused;
    }

    fn run(self: *Job) void {
        defer self.finish();
        // Its CPU, disk and memory priority below every other thread's.
        _ = c.SetThreadPriority(c.GetCurrentThread(), c.THREAD_MODE_BACKGROUND_BEGIN);
        if (self.wait_for) |h| {
            defer {
                _ = c.CloseHandle(h);
                self.wait_for = null;
            }
            // The cancelled job before this one: until its thread is done
            // with the folder (its time limits bound that).
            while (c.WaitForSingleObject(h, 250) == c.WAIT_TIMEOUT) {
                if (self.isCancelled()) return self.fail(.load, CANCELLED);
            }
        }
        switch (self.mode) {
            .download => {
                const api = Api.load() orelse return self.fail(.load, c.GetLastError());
                const session = api.Open(c.L(update_fetch.user_agent), update_fetch.WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, null, null, 0) orelse
                    return self.fail(.open, c.GetLastError());
                _ = api.SetTimeouts(session, timeout_resolve, timeout_connect, timeout_send, timeout_receive);
                self.download(api, session);
                _ = api.CloseHandle(session);
            },
            .verify => self.verify(),
        }
        // Every handle of the thread's is closed now (a held installer is
        // closed on refusal): a refused or discarded download goes whole.
        if (self.outcome == .refused or self.discard.load(.acquire)) {
            if (self.held) |h| _ = c.CloseHandle(h);
            self.held = null;
            for ([_][:0]const u16{ self.partial_path, self.final_path, self.sums_path, self.signature_path }) |p| _ = c.DeleteFileW(p.ptr);
            if (self.discard.load(.acquire)) _ = c.RemoveDirectoryW(self.dir_path.ptr);
        }
    }

    fn finish(self: *Job) void {
        self.done.store(true, .release);
        const hwnd = self.hwnd.load(.acquire);
        if (hwnd != 0) _ = c.PostMessageW(@ptrFromInt(hwnd), self.done_msg, 0, 0);
        _ = c.SetEvent(self.finished);
        self.release();
    }

    fn download(self: *Job, api: Api, session: HINTERNET) void {
        // The signature and the sums first: nothing larger is fetched for a
        // release whose sums no key of murrtty's signed.
        const signature = self.getSmall(api, session, self.signature_url, update_verify.max_signature) orelse return;
        // Anything but 64 bytes is no signature at all (a proxy's page, a
        // server's error), so it fails rather than refuses: a refusal
        // would delete a good installer kept from before.
        if (signature.len != update_verify.signature_len) return self.fail(.answer, 0);
        const sums = self.getSmall(api, session, self.sums_url, update_verify.max_sums) orelse return;
        const expected = switch (update_verify.checkSums(self.keys, sums, signature, self.name)) {
            .ok => |digest| digest,
            .refused => |why| return self.refuse(why),
        };
        // Kept beside the installer: checked again before it runs.
        if (!writeWhole(self.sums_path, sums)) return self.fail(.write, c.GetLastError());
        if (!writeWhole(self.signature_path, signature)) return self.fail(.write, c.GetLastError());
        // Downloaded and checked earlier (by this murrtty or another).
        switch (self.hashFile(self.final_path)) {
            .digest => |have| {
                if (std.mem.eql(u8, &have, &expected)) {
                    self.outcome = .ready;
                    return;
                }
                _ = c.DeleteFileW(self.final_path.ptr);
            },
            .missing => {},
            .cancelled => return self.fail(.read, CANCELLED),
        }
        // A resumed file that doesn't match may only have had a stale part
        // (an asset uploaded again, a proxy's range): once more from the
        // start before it is refused.
        if (self.fetchFile(api, session, expected, true) == .again) _ = self.fetchFile(api, session, expected, false);
    }

    /// Check the kept installer again: the kept sums and signature, then its
    /// hash, read while it is held (left in `held` when it matches).
    fn verify(self: *Job) void {
        const a = self.arena.allocator();
        const signature = readSmall(a, self.signature_path, update_verify.max_signature) orelse {
            self.outcome = .gone;
            return;
        };
        const sums = readSmall(a, self.sums_path, update_verify.max_sums) orelse {
            self.outcome = .gone;
            return;
        };
        const expected = switch (update_verify.checkSums(self.keys, sums, signature, self.name)) {
            .ok => |digest| digest,
            .refused => |why| return self.refuse(why),
        };
        const held = hashHeld(self.final_path) orelse {
            self.outcome = .gone;
            return;
        };
        if (!std.mem.eql(u8, &held.digest, &expected)) {
            _ = c.CloseHandle(held.held);
            return self.refuse(.wrong_hash);
        }
        self.held = held.held;
        self.outcome = .ready;
    }

    const Request = struct {
        connect: HINTERNET,
        request: HINTERNET,
        status: u32,

        fn close(self: Request, api: Api) void {
            _ = api.CloseHandle(self.request);
            _ = api.CloseHandle(self.connect);
        }
    };

    /// A GET of `url` (from `from` on, if not 0), its answer's head read.
    fn open(self: *Job, api: Api, session: HINTERNET, url_text: []const u8, from: u64) ?Request {
        const a = self.arena.allocator();
        const url = update_list.Url.parse(url_text) catch {
            self.refuse(.bad_address);
            return null;
        };
        const host = text_util.utf16Lossy(a, url.host) catch {
            self.fail(.request, 0);
            return null;
        };
        const path = text_util.utf16Lossy(a, url.path) catch {
            self.fail(.request, 0);
            return null;
        };
        const connect = api.Connect(session, host.ptr, url.port, 0) orelse {
            self.fail(.connect, c.GetLastError());
            return null;
        };
        const request = api.OpenRequest(connect, c.L("GET"), path.ptr, null, null, null, if (url.secure) update_fetch.WINHTTP_FLAG_SECURE else 0) orelse {
            const err = c.GetLastError();
            _ = api.CloseHandle(connect);
            self.fail(.request, err);
            return null;
        };
        var req: Request = .{ .connect = connect, .request = request, .status = 0 };
        const no_cookies: u32 = update_fetch.WINHTTP_DISABLE_COOKIES;
        _ = api.SetOption(request, update_fetch.WINHTTP_OPTION_DISABLE_FEATURE, &no_cookies, @sizeOf(u32));
        if (from > 0) range: {
            const line = std.fmt.allocPrint(a, "Range: bytes={d}-", .{from}) catch break :range;
            const w = text_util.utf16Lossy(a, line) catch break :range;
            _ = api.AddRequestHeaders(request, w.ptr, std.math.maxInt(u32), update_fetch.WINHTTP_ADDREQ_FLAG_ADD);
        }
        const failed: ?struct { Stage, u32 } = if (self.isCancelled())
            .{ .send, CANCELLED }
        else if (api.SendRequest(request, null, 0, null, 0, 0, 0) == 0)
            .{ .send, c.GetLastError() }
        else if (self.isCancelled())
            .{ .receive, CANCELLED }
        else if (api.ReceiveResponse(request, null) == 0)
            .{ .receive, c.GetLastError() }
        else
            null;
        if (failed) |f| {
            req.close(api);
            self.fail(f[0], f[1]);
            return null;
        }
        req.status = update_fetch.queryNumber(api, request, update_fetch.WINHTTP_QUERY_STATUS_CODE) orelse 0;
        return req;
    }

    /// A small file whole (the signature, the sums), at most `max` bytes;
    /// more is no such file (a failure, said as `answer`).
    fn getSmall(self: *Job, api: Api, session: HINTERNET, url: []const u8, max: usize) ?[]const u8 {
        const req = self.open(api, session, url, 0) orelse return null;
        defer req.close(api);
        if (req.status != 200) {
            self.status = req.status;
            self.fail(.http, 0);
            return null;
        }
        const a = self.arena.allocator();
        const started = c.GetTickCount64();
        var body: std.ArrayList(u8) = .empty;
        while (true) {
            if (self.isCancelled()) {
                self.fail(.read, CANCELLED);
                return null;
            }
            if (c.GetTickCount64() -| started > small_total_ms) {
                self.fail(.read, TIMEOUT);
                return null;
            }
            var avail: u32 = 0;
            if (api.QueryDataAvailable(req.request, &avail) == 0) {
                self.fail(.read, c.GetLastError());
                return null;
            }
            if (avail == 0) break;
            if (body.items.len + avail > max) {
                self.fail(.answer, 0);
                return null;
            }
            const dst = body.addManyAsSlice(a, avail) catch {
                self.fail(.read, 0);
                return null;
            };
            var got: u32 = 0;
            if (api.ReadData(req.request, dst.ptr, avail, &got) == 0) {
                self.fail(.read, c.GetLastError());
                return null;
            }
            body.shrinkRetainingCapacity(body.items.len - avail + got);
            if (got == 0) break;
        }
        return body.items;
    }

    const Fetched = enum { done, again };

    /// The installer into `<name>.partial`, from where an earlier download
    /// stopped (`keep`; else from its start), then under its name if its
    /// SHA-256 is `expected`. `again` when a resumed file didn't match.
    fn fetchFile(self: *Job, api: Api, session: HINTERNET, expected: [32]u8, keep: bool) Fetched {
        var tries: u32 = 0;
        const file = while (true) {
            const f = c.CreateFileW(self.partial_path.ptr, c.GENERIC_READ | c.GENERIC_WRITE, c.FILE_SHARE_READ, null, c.OPEN_ALWAYS, c.FILE_ATTRIBUTE_NORMAL, null);
            if (f != c.INVALID_HANDLE_VALUE) break f;
            const err = c.GetLastError();
            if (err != c.ERROR_SHARING_VIOLATION) {
                self.fail(.write, err);
                return .done;
            }
            // Another murrtty's download holds it (this murrtty's own
            // cancelled one was waited for).
            if (self.isCancelled()) {
                self.fail(.write, CANCELLED);
                return .done;
            }
            if (tries >= busy_tries) {
                self.outcome = .busy;
                return .done;
            }
            tries += 1;
            c.Sleep(250);
        };
        var file_open = true;
        defer if (file_open) {
            _ = c.CloseHandle(file);
        };
        var size: i64 = 0;
        _ = c.GetFileSizeEx(file, &size);
        var from: u64 = @intCast(@max(size, 0));
        var hasher = Sha256.init(.{});
        if (!keep or from > update_verify.max_installer) {
            if (!truncate(file)) {
                self.fail(.write, c.GetLastError());
                return .done;
            }
            from = 0;
        } else if (from > 0) {
            // What is there already goes into the hash first.
            if (!self.hashHandle(file, from, &hasher)) return .done;
        }

        var req = self.open(api, session, self.file_url, from) orelse return .done;
        var req_open = true;
        defer if (req_open) req.close(api);
        var total: u64 = 0;
        var restart = false;
        switch (req.status) {
            206 => if (from == 0) {
                self.status = req.status;
                self.fail(.http, 0);
                return .done;
            } else {
                // The range must start where the kept part ends.
                switch (contentRange(self.arena.allocator(), api, req.request)) {
                    .range => |r| if (r.start == from) {
                        total = r.total;
                    } else {
                        restart = true;
                    },
                    .none => restart = true,
                }
            },
            // The whole file came back (a server or proxy ignoring the
            // range): this answer, from its start.
            200 => if (from > 0) {
                if (!truncate(file)) {
                    self.fail(.write, c.GetLastError());
                    return .done;
                }
                from = 0;
                hasher = Sha256.init(.{});
            },
            // The part kept is longer than the file: it isn't this one's.
            416 => restart = true,
            else => {
                self.status = req.status;
                self.fail(.http, 0);
                return .done;
            },
        }
        if (restart) {
            if (req_open) req.close(api);
            req_open = false;
            if (!truncate(file)) {
                self.fail(.write, c.GetLastError());
                return .done;
            }
            from = 0;
            hasher = Sha256.init(.{});
            req = self.open(api, session, self.file_url, 0) orelse return .done;
            req_open = true;
            if (req.status != 200) {
                self.status = req.status;
                self.fail(.http, 0);
                return .done;
            }
        }
        self.resumed_from = from;
        if (c.SetFilePointerEx(file, @intCast(from), null, c.FILE_BEGIN) == 0) {
            self.fail(.write, c.GetLastError());
            return .done;
        }
        const length: ?u64 = if (update_fetch.queryNumber(api, req.request, WINHTTP_QUERY_CONTENT_LENGTH)) |n| n else null;
        if (total == 0) total = if (length) |n| from + n else 0;
        if (total > update_verify.max_installer) {
            self.refuse(.too_big);
            return .done;
        }
        self.total.store(total, .release);
        self.received.store(from, .release);

        const buf = self.arena.allocator().alloc(u8, chunk) catch {
            self.fail(.read, 0);
            return .done;
        };
        var received = from;
        while (true) {
            if (self.isCancelled()) {
                self.fail(.read, CANCELLED);
                return .done;
            }
            var avail: u32 = 0;
            if (api.QueryDataAvailable(req.request, &avail) == 0) {
                self.fail(.read, c.GetLastError());
                return .done;
            }
            if (avail == 0) break;
            var got: u32 = 0;
            if (api.ReadData(req.request, buf.ptr, @min(avail, chunk), &got) == 0) {
                self.fail(.read, c.GetLastError());
                return .done;
            }
            if (got == 0) break;
            if (received + got > update_verify.max_installer) {
                self.refuse(.too_big);
                return .done;
            }
            if (!writeAll(file, buf[0..got])) {
                self.fail(.write, c.GetLastError());
                return .done;
            }
            hasher.update(buf[0..got]);
            received += got;
            self.received.store(received, .release);
            self.tellProgress();
        }
        // Cut short: what came stays, to resume.
        if (total > 0 and received != total) {
            self.fail(.incomplete, 0);
            return .done;
        }
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        _ = c.FlushFileBuffers(file);
        _ = c.CloseHandle(file);
        file_open = false;
        if (!std.mem.eql(u8, &digest, &expected)) {
            if (from > 0) {
                _ = c.DeleteFileW(self.partial_path.ptr);
                return .again;
            }
            self.refuse(.wrong_hash);
            return .done;
        }
        if (c.MoveFileExW(self.partial_path.ptr, self.final_path.ptr, c.MOVEFILE_REPLACE_EXISTING) == 0) {
            self.fail(.write, c.GetLastError());
            return .done;
        }
        self.outcome = .ready;
        return .done;
    }

    /// The first `len` bytes of `file` into `hasher`; false (failed or
    /// cancelled, said in the results) if they couldn't be read.
    fn hashHandle(self: *Job, file: c.HANDLE, len: u64, hasher: *Sha256) bool {
        if (c.SetFilePointerEx(file, 0, null, c.FILE_BEGIN) == 0) {
            self.fail(.write, c.GetLastError());
            return false;
        }
        var buf: [chunk]u8 = undefined;
        var left = len;
        while (left > 0) {
            if (self.isCancelled()) {
                self.fail(.read, CANCELLED);
                return false;
            }
            var n: c.DWORD = 0;
            const want: c.DWORD = @intCast(@min(left, chunk));
            if (c.ReadFile(file, &buf, want, &n, null) == 0) {
                self.fail(.write, c.GetLastError());
                return false;
            }
            if (n == 0) {
                self.fail(.write, ERROR_HANDLE_EOF);
                return false;
            }
            hasher.update(buf[0..n]);
            left -= n;
        }
        return true;
    }

    const Hashed = union(enum) { digest: [32]u8, missing, cancelled };

    /// The SHA-256 of the file at `path` (missing: absent, unreadable or
    /// larger than any installer).
    fn hashFile(self: *Job, path: [:0]const u16) Hashed {
        const file = c.CreateFileW(path.ptr, c.GENERIC_READ, c.FILE_SHARE_READ, null, c.OPEN_EXISTING, c.FILE_ATTRIBUTE_NORMAL, null);
        if (file == c.INVALID_HANDLE_VALUE) return .missing;
        defer _ = c.CloseHandle(file);
        var size: i64 = 0;
        if (c.GetFileSizeEx(file, &size) == 0 or size < 0 or size > update_verify.max_installer) return .missing;
        var hasher = Sha256.init(.{});
        var buf: [chunk]u8 = undefined;
        while (true) {
            if (self.isCancelled()) return .cancelled;
            var n: c.DWORD = 0;
            if (c.ReadFile(file, &buf, chunk, &n, null) == 0) return .missing;
            if (n == 0) break;
            hasher.update(buf[0..n]);
        }
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        return .{ .digest = digest };
    }

    /// Tell the window how far it got: at most every 200 ms, one message
    /// at a time.
    fn tellProgress(self: *Job) void {
        const now = c.GetTickCount64();
        if (now -| self.last_progress_ms < progress_ms) return;
        const hwnd = self.hwnd.load(.acquire);
        if (hwnd == 0) return;
        if (self.progress_pending.swap(true, .acq_rel)) return;
        self.last_progress_ms = now;
        if (c.PostMessageW(@ptrFromInt(hwnd), self.progress_msg, 0, 0) == 0) self.progress_pending.store(false, .release);
    }
};

const ContentRange = union(enum) {
    range: struct { start: u64, total: u64 },
    none,
};

/// A 206's Content-Range ("bytes 100-999/1000"): where it starts and the
/// whole file's size.
fn contentRange(a: std.mem.Allocator, api: Api, request: HINTERNET) ContentRange {
    var buf: [128]u16 = undefined;
    var len: u32 = @sizeOf(@TypeOf(buf));
    if (api.QueryHeaders(request, WINHTTP_QUERY_CONTENT_RANGE, null, &buf, &len, null) == 0) return .none;
    const text = std.unicode.utf16LeToUtf8Alloc(a, buf[0 .. len / 2]) catch return .none;
    return parseContentRange(text);
}

fn parseContentRange(text: []const u8) ContentRange {
    const t = std.mem.trim(u8, text, " \t");
    if (!std.mem.startsWith(u8, t, "bytes ")) return .none;
    const rest = t["bytes ".len..];
    const dash = std.mem.indexOfScalar(u8, rest, '-') orelse return .none;
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return .none;
    if (slash < dash) return .none;
    const start = std.fmt.parseInt(u64, rest[0..dash], 10) catch return .none;
    const total = std.fmt.parseInt(u64, rest[slash + 1 ..], 10) catch return .none;
    return .{ .range = .{ .start = start, .total = total } };
}

/// Empty an open file.
fn truncate(file: c.HANDLE) bool {
    return c.SetFilePointerEx(file, 0, null, c.FILE_BEGIN) != 0 and c.SetEndOfFile(file) != 0;
}

fn writeAll(file: c.HANDLE, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        var n: c.DWORD = 0;
        if (c.WriteFile(file, bytes[off..].ptr, @intCast(bytes.len - off), &n, null) == 0 or n == 0) return false;
        off += n;
    }
    return true;
}

/// A small file written whole, replacing any.
fn writeWhole(path: [:0]const u16, bytes: []const u8) bool {
    const file = c.CreateFileW(path.ptr, c.GENERIC_WRITE, 0, null, c.CREATE_ALWAYS, c.FILE_ATTRIBUTE_NORMAL, null);
    if (file == c.INVALID_HANDLE_VALUE) return false;
    defer _ = c.CloseHandle(file);
    return writeAll(file, bytes) and c.FlushFileBuffers(file) != 0;
}

/// A small file whole, or null (absent, unreadable, more than `max`).
fn readSmall(a: std.mem.Allocator, path: [:0]const u16, max: usize) ?[]u8 {
    const file = c.CreateFileW(path.ptr, c.GENERIC_READ, c.FILE_SHARE_READ, null, c.OPEN_EXISTING, c.FILE_ATTRIBUTE_NORMAL, null);
    if (file == c.INVALID_HANDLE_VALUE) return null;
    defer _ = c.CloseHandle(file);
    const buf = a.alloc(u8, max + 1) catch return null;
    var len: usize = 0;
    while (len < buf.len) {
        var n: c.DWORD = 0;
        if (c.ReadFile(file, buf[len..].ptr, @intCast(buf.len - len), &n, null) == 0) return null;
        if (n == 0) break;
        len += n;
    }
    if (len > max) return null;
    return buf[0..len];
}

/// The SHA-256 of the file at `path`, read while `held`: opened without
/// write or delete sharing, so nothing can change it until `held` is
/// closed (the UI runs the installer, then closes it).
fn hashHeld(path: [:0]const u16) ?struct { digest: [32]u8, held: c.HANDLE } {
    const file = c.CreateFileW(path.ptr, c.GENERIC_READ, c.FILE_SHARE_READ, null, c.OPEN_EXISTING, c.FILE_ATTRIBUTE_NORMAL, null);
    if (file == c.INVALID_HANDLE_VALUE) return null;
    var size: i64 = 0;
    if (c.GetFileSizeEx(file, &size) == 0 or size < 0 or size > update_verify.max_installer) {
        _ = c.CloseHandle(file);
        return null;
    }
    var hasher = Sha256.init(.{});
    var buf: [chunk]u8 = undefined;
    while (true) {
        var n: c.DWORD = 0;
        if (c.ReadFile(file, &buf, chunk, &n, null) == 0) {
            _ = c.CloseHandle(file);
            return null;
        }
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return .{ .digest = digest, .held = file };
}

test "update download: Content-Range" {
    const testing = std.testing;
    const r = parseContentRange("bytes 100-999/1000");
    try testing.expect(r == .range and r.range.start == 100 and r.range.total == 1000);
    try testing.expect(parseContentRange("bytes */1000") == .none);
    try testing.expect(parseContentRange("items 1-2/3") == .none);
    try testing.expect(parseContentRange("bytes 5-9/x") == .none);
}

test "update download: a server that refuses fails it, without hanging" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const hwnd = c.CreateWindowExW(0, c.L("STATIC"), c.L(""), 0, 0, 0, 0, 0, c.HWND_MESSAGE, null, null, null) orelse return error.SkipZigTest;
    defer _ = c.DestroyWindow(hwnd);
    var tmp_buf: [512]u16 = undefined;
    const n = c.GetTempPathW(tmp_buf.len, &tmp_buf);
    if (n == 0 or n >= tmp_buf.len) return error.SkipZigTest;
    const tmp = try std.unicode.wtf16LeToWtf8Alloc(std.testing.allocator, tmp_buf[0..n]);
    defer std.testing.allocator.free(tmp);
    const job = try Job.start(.{
        .signature_url = "http://127.0.0.1:9/releases/download/t/SHA256SUMS.txt.sig",
        .sums_url = "http://127.0.0.1:9/releases/download/t/SHA256SUMS.txt",
        .file_url = "http://127.0.0.1:9/releases/download/t/x.exe",
        .name = "x.exe",
        .dir = std.mem.trimEnd(u8, tmp, "\\"),
        .keys = &.{},
        .hwnd = hwnd,
        .done_msg = c.WM_APP + 78,
        .progress_msg = c.WM_APP + 79,
    });
    defer job.release();
    try std.testing.expect(job.wait(20_000));
    try std.testing.expectEqual(Outcome.failed, job.outcome);
    try std.testing.expect(job.error_code != 0);
    // Started after a cancelled job, a job waits for it; cancelled while
    // it waits, it ends at once.
    const first = try Job.start(.{ .file_url = "", .name = "x.exe", .dir = std.mem.trimEnd(u8, tmp, "\\"), .keys = &.{}, .mode = .verify, .hwnd = hwnd, .done_msg = c.WM_APP + 78, .progress_msg = c.WM_APP + 79 });
    first.cancel();
    const second = try Job.start(.{ .name = "x.exe", .dir = std.mem.trimEnd(u8, tmp, "\\"), .keys = &.{}, .mode = .verify, .after = first, .hwnd = hwnd, .done_msg = c.WM_APP + 78, .progress_msg = c.WM_APP + 79 });
    first.release();
    defer second.release();
    try std.testing.expect(second.wait(20_000));
    // Nothing kept in the temp folder under that name: gone.
    try std.testing.expect(second.outcome == .gone or second.outcome == .cancelled);
}
