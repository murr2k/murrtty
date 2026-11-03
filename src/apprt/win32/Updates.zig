//! Update checks (roadmap 7.6a): when murrtty asks murrtty.org for its
//! release list, what it keeps between runs, and what it found.
//!
//! Off unless `auto-update` is `check` or `download` (unset is off on
//! Windows, unlike macOS Ghostty, which asks) and the user agreed on this
//! machine (`consent`: the consent dialog, or the notice for a config file
//! murrtty didn't write). A check the user starts always runs. Development
//! builds never check: their updates come from building the source.
//!
//! Built for many copies launched often: an automatic check is due once per
//! interval per user, however many murrttys start. The state file (in
//! murrtty's state folder, shared by every murrtty of the user) keeps the
//! next check's time, read and written under a lock file, and a check in
//! flight holds a lease in it; only a murrtty holding the single instance's
//! pipe checks on its own. A check runs at a random point of the interval,
//! never sooner than 2 to 10 minutes after murrtty started, sends the ETag
//! of the list it holds back (so most answers are 304), and backs off after
//! failures, honoring Retry-After and the list's min_check_hours.
//!
//! All the network work is update_fetch's thread: this side runs on the UI
//! thread, touches only small local files, and never waits for the thread.

const Updates = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const build_config = @import("../../build_config.zig");
const configpkg = @import("../../config.zig");
const c = @import("c.zig");
const text_util = @import("text.zig");
const App = @import("App.zig");
const Session = @import("Session.zig");
const test_hooks = @import("test_hooks.zig");
const update_list = @import("update_list.zig");
const update_fetch = @import("update_fetch.zig");

const log = std.log.scoped(.win32_updates);

/// The wakeup window's message when a check is done (posted with nothing:
/// any process on the desktop could post it).
pub const message = c.WM_APP + 5;
/// The wakeup window's timer for the next automatic check.
pub const timer_id = 0x5D7E;

/// SetTimer's longest wait asked for at once: the timer looks again then.
const max_wait_ms: u64 = 6 * 3600 * 1000;
/// Automatic checks failed in a row before giving up for the interval.
const max_failures = 4;
/// How long (seconds) a check in flight holds off another murrtty's.
const lease_s = 120;
/// On a metered connection, an automatic check looks again after this.
const metered_retry_s = 3600;
/// The shortest wait before an automatic check (a reload that turns checks
/// on, say), and the wait when the state file is busy.
const min_wait_ms = 5_000;
/// The state file couldn't be read (it is there): look again after this.
const unreadable_retry_ms = 3600 * 1000;

pub const OnFound = enum { notify, window };

/// What is kept between runs, in `<state folder>\updates.json`.
pub const State = struct {
    interval: update_list.Interval = .daily,
    on_found: OnFound = .notify,
    /// The user agreed to automatic checks on this machine.
    consent: bool = false,
    /// Unix seconds: the last check that got an answer; when the next
    /// automatic one is due (0: now); until when a murrtty's check in
    /// flight holds the others off.
    last_check: i64 = 0,
    next_check: i64 = 0,
    lease_until: i64 = 0,
    /// Automatic checks that failed in a row.
    failures: u32 = 0,
    /// The ETag of the list kept in `updates\list.json`.
    etag: ?[]const u8 = null,
    /// The version the user skipped, and the last a notification announced.
    skipped: ?[]const u8 = null,
    notified: ?[]const u8 = null,
    /// Releases whose notes were read: the window shows the others bold.
    read: []const []const u8 = &.{},
};

pub const Status = enum {
    /// No check this run, and no list kept from an earlier one.
    idle,
    checking,
    up_to_date,
    available,
    failed,
};

pub const Kind = enum { automatic, manual };

app: *App,
/// The state folder, or null where there is none: nothing is kept, and no
/// automatic check runs (it couldn't keep to its interval).
dir: ?[]u8 = null,
/// This murrtty may check on its own: it holds the single instance's pipe.
owner: bool = false,
/// The state as last read or written, in `state_arena`.
state: State = .{},
state_arena: std.heap.ArenaAllocator,
/// The state file was there but couldn't be read (busy, or written by a
/// newer murrtty): nothing writes over it, and no automatic check runs.
state_unreadable: bool = false,
/// The list this murrtty holds, and that list's ETag (not the state
/// file's: another murrtty may have written a newer list since), in
/// `list_arena`.
list: ?update_list.List = null,
list_etag: ?[]const u8 = null,
list_arena: std.heap.ArenaAllocator,
/// The newest release on the channel newer than this murrtty, from `list`
/// (null when there is none, or the user skipped it).
found: ?update_list.Release = null,
status: Status = .idle,
/// The check in flight, what started it, and whether the user asked for
/// one meanwhile (Check Now during an automatic check: the user waits
/// for its answer, the schedule treats it as the automatic one).
job: ?*update_fetch.Job = null,
job_kind: Kind = .automatic,
asked: bool = false,
/// The last check's answer this run, for the window.
last_outcome: ?update_fetch.Outcome = null,
last_error: u32 = 0,
last_status: u32 = 0,
/// When the timer fires (GetTickCount64), null while it doesn't run.
due_ms: ?u64 = null,
/// No automatic check before this (GetTickCount64): start plus its delay.
earliest_ms: u64 = 0,
/// Requests sent this run (the GUI tests count them).
requests: u32 = 0,
prng: std.Random.DefaultPrng,
/// The version this murrtty compares with (a test build may pretend), and
/// whether it checks at all (a release build).
running: std.SemanticVersion,
release_build: bool,

pub fn init(app: *App) Updates {
    const alloc = app.core_app.alloc;
    var ft: c.FILETIME = undefined;
    c.GetSystemTimeAsFileTime(&ft);
    const seed = c.GetTickCount64() *% 0x9E3779B97F4A7C15 ^ c.GetCurrentProcessId() ^
        (@as(u64, ft.dwHighDateTime) << 32 | ft.dwLowDateTime);
    var self: Updates = .{
        .app = app,
        .state_arena = .init(alloc),
        .list_arena = .init(alloc),
        .prng = .init(seed),
        .running = build_config.version,
        .release_build = build_config.release_channel == .stable,
    };
    if (comptime test_hooks.enabled) {
        var buf: [64]u8 = undefined;
        if (testEnv("GHOSTTY_WIN32_TEST_UPDATES_VERSION", &buf)) |v| {
            if (std.SemanticVersion.parse(v)) |parsed| {
                // Only numbers: the buffer goes with this call.
                self.running = .{ .major = parsed.major, .minor = parsed.minor, .patch = parsed.patch };
                self.release_build = true;
            } else |_| {}
        }
    }
    return self;
}

pub fn deinit(self: *Updates) void {
    self.stopTimer();
    // Quitting never waits for the network: the thread ends with the
    // process, or frees the job if it finishes first.
    if (self.job) |job| job.abandon();
    self.job = null;
    const alloc = self.app.core_app.alloc;
    if (self.dir) |d| alloc.free(d);
    self.dir = null;
    self.list = null;
    self.list_etag = null;
    self.found = null;
    self.state = .{};
    self.state_arena.deinit();
    self.list_arena.deinit();
}

/// Once murrtty has started (App.run): the state and the list kept, and
/// the timer for an automatic check that is on.
pub fn start(self: *Updates, owner: bool) void {
    self.owner = owner;
    if (self.release_build) {
        self.dir = Session.stateDir(self.app.core_app.alloc) catch |err| dir: {
            log.warn("no state folder: update checks keep nothing err={}", .{err});
            break :dir null;
        };
    }
    self.earliest_ms = c.GetTickCount64() + self.startDelay();
    self.loadState();
    self.loadList();
    self.refresh();
    self.schedule();
}

/// The config changed: `auto-update` or its channel may have.
pub fn configChanged(self: *Updates) void {
    self.refresh();
    self.schedule();
}

/// `auto-update` as this murrtty reads it: unset is off.
pub fn mode(self: *const Updates) configpkg.Config.AutoUpdate {
    return self.app.config.@"auto-update" orelse .off;
}

/// Whether this murrtty checks on its own.
pub fn automaticOn(self: *const Updates) bool {
    return self.owner and self.release_build and self.dir != null and
        !self.state_unreadable and self.mode() != .off and self.state.consent;
}

pub fn channel(self: *const Updates) update_list.Channel {
    const ch = self.app.config.@"auto-update-channel" orelse build_config.release_channel;
    return switch (ch) {
        .stable => .stable,
        .tip => .tip,
    };
}

/// A check the user asked for (Check Now, `check_for_updates`): it runs
/// whatever `auto-update` says, metered or not. Nothing in a development
/// build, whose window says why.
pub fn checkNow(self: *Updates) void {
    if (!self.release_build) return;
    self.collect();
    if (self.job != null) {
        // The check in flight answers this one too.
        self.asked = true;
        return;
    }
    _ = self.startJob(.manual);
}

/// Cancel the check in flight (the window's Cancel): let go of it at once.
/// A cancelled automatic check counts as this interval's (no retry in a few
/// seconds); a cancelled check the user asked for leaves the schedule.
pub fn cancel(self: *Updates) void {
    const job = self.job orelse return;
    job.abandon();
    self.job = null;
    self.asked = false;
    self.last_outcome = .cancelled;
    self.last_error = 0;
    self.last_status = 0;
    if (self.job_kind == .automatic) {
        const lock = Lock.take(self);
        defer if (lock == .held) lock.held.release();
        if (lock == .held) self.loadState();
        self.state.lease_until = 0;
        self.state.next_check = update_list.nextCheck(unixNow(), self.state.interval, null, self.prng.random());
        if (lock != .busy) self.saveState();
    }
    self.refresh();
    self.schedule();
}

/// The timer: an automatic check, if it is due (another murrtty may have
/// checked meanwhile).
pub fn tick(self: *Updates) void {
    self.stopTimer();
    self.collect();
    if (!self.automaticOn() or self.job != null) return;
    const lock = Lock.take(self);
    switch (lock) {
        // Another murrtty is writing the state this instant.
        .busy => return self.arm(min_wait_ms + self.prng.random().uintLessThan(u64, 5_000)),
        // No lock to be had (an unwritable folder): go on without one.
        .failed, .held => {},
    }
    defer if (lock == .held) lock.held.release();
    self.loadState();
    if (!self.automaticOn()) return self.schedule();
    const now = unixNow();
    const due = @max(self.state.next_check, self.state.lease_until);
    if (due > now) return self.arm(secondsToMs(due - now));
    self.state.lease_until = now + lease_s;
    if (!self.startJob(.automatic)) {
        // As a check that failed (no retry every few seconds).
        self.state.lease_until = 0;
        self.failed(.automatic, now, null);
    }
    self.saveState();
    self.schedule();
}

/// The check's thread is done (`message`).
pub fn finished(self: *Updates) void {
    const job = self.job orelse return;
    // A late message from a job let go of earlier.
    if (!job.isDone()) return;
    self.job = null;
    defer job.release();
    const kind = self.job_kind;
    const asked = self.asked;
    self.asked = false;
    const now = unixNow();
    self.last_outcome = job.outcome;
    self.last_error = job.error_code;
    self.last_status = job.status;
    log.info("update check ({t}): {t} status={} err={} {}ms", .{ kind, job.outcome, job.status, job.error_code, job.elapsed_ms });

    const lock = Lock.take(self);
    defer if (lock == .held) lock.held.release();
    // Busy past its retries: what this check learned is still worth
    // writing (a missed lock risks one more check, a missed write a check
    // per tick).
    if (lock == .held) self.loadState();
    switch (job.outcome) {
        .ok => switch (self.takeList(job.body, job.etag)) {
            // The state's ETag names the list file: none if it wasn't
            // written.
            .kept => {
                self.setString(&self.state.etag, job.etag);
                self.succeeded(now);
            },
            .unsaved => {
                self.setString(&self.state.etag, null);
                self.succeeded(now);
            },
            // A list murrtty can't read is no answer.
            .bad => {
                self.last_outcome = .failed;
                self.failed(kind, now, null);
            },
        },
        .not_modified => if (self.list != null) self.succeeded(now) else {
            // Nothing held to be unchanged: ask for the whole list next.
            self.last_outcome = .failed;
            self.failed(kind, now, null);
        },
        .http_error => self.failed(kind, now, job.retry_after),
        .failed => self.failed(kind, now, null),
        .metered => self.state.next_check = now + metered_retry_s,
        .cancelled => {},
    }
    if (kind == .automatic) self.state.lease_until = 0;
    self.saveState();
    self.refresh();
    // The user asked while an automatic check found the connection
    // metered: theirs runs anyway.
    if (asked and job.outcome == .metered) _ = self.startJob(.manual);
    self.schedule();
}

/// A job whose thread is done but whose message never came (a full message
/// queue): take its results now.
fn collect(self: *Updates) void {
    if (self.job) |job| if (job.isDone()) self.finished();
}

fn succeeded(self: *Updates, now: i64) void {
    self.state.last_check = now;
    self.state.failures = 0;
    const min_hours = if (self.list) |l| l.min_check_hours else null;
    self.state.next_check = update_list.nextCheck(now, self.state.interval, min_hours, self.prng.random());
}

fn failed(self: *Updates, kind: Kind, now: i64, retry_after: ?u32) void {
    // A check the user started leaves the schedule, except that a server
    // asking for time gets it.
    if (kind == .manual) {
        if (retry_after) |s| self.state.next_check = @max(self.state.next_check, now + s);
        return;
    }
    self.state.failures +|= 1;
    if (self.state.failures >= max_failures) {
        // Given up for this interval.
        self.state.failures = 0;
        self.state.next_check = update_list.nextCheck(now, self.state.interval, null, self.prng.random());
    } else {
        self.state.next_check = update_list.retryAt(now, self.state.failures, self.state.interval, retry_after, self.prng.random());
    }
}

/// What the state and list say now: the release found, the status.
fn refresh(self: *Updates) void {
    self.found = if (self.list) |l| update_list.newest(l, self.channel(), self.running, self.state.skipped) else null;
    self.status = if (self.job != null)
        .checking
    else if (self.last_outcome != null and (self.last_outcome.? == .failed or self.last_outcome.? == .http_error))
        .failed
    else if (self.found != null)
        .available
    else if (self.list != null)
        .up_to_date
    else
        .idle;
}

/// Start a check; false when it couldn't start (said in `last_outcome`).
fn startJob(self: *Updates, kind: Kind) bool {
    var url_buf: [512]u8 = undefined;
    const url = testUrl(&url_buf) orelse update_list.default_url;
    const job = update_fetch.Job.start(.{
        .url = url,
        // The ETag of the list this murrtty holds.
        .etag = if (self.list != null) self.list_etag else null,
        .automatic = kind == .automatic,
        .metered = testMetered(),
        .hwnd = self.app.wakeup_hwnd,
        .msg = message,
    }) catch |err| {
        log.warn("update check couldn't start err={}", .{err});
        self.last_outcome = .failed;
        self.last_error = 0;
        self.last_status = 0;
        self.refresh();
        return false;
    };
    self.job = job;
    self.job_kind = kind;
    self.requests += 1;
    self.refresh();
    return true;
}

/// Arm the timer for the next automatic check: when it is due, never
/// before start plus its delay, never in less than a few seconds.
fn schedule(self: *Updates) void {
    self.stopTimer();
    if (self.job != null) return;
    if (self.state_unreadable and self.owner and self.release_build and self.mode() != .off) {
        // Look at the file again later: it may only have been busy.
        return self.arm(unreadable_retry_ms);
    }
    if (!self.automaticOn()) return;
    const now = unixNow();
    const due = @max(self.state.next_check, self.state.lease_until);
    const wait: u64 = if (due > now) secondsToMs(due - now) else 0;
    const start_wait = self.earliest_ms -| c.GetTickCount64();
    self.arm(@max(wait, start_wait, min_wait_ms));
}

fn secondsToMs(s: i64) u64 {
    // A hand-edited file's far future waits the longest SetTimer wait.
    return @as(u64, @intCast(@min(@max(s, 0), @divTrunc(max_wait_ms, 1000)))) * 1000;
}

fn startDelay(self: *Updates) u64 {
    if (comptime test_hooks.enabled) {
        var buf: [16]u8 = undefined;
        if (testEnv("GHOSTTY_WIN32_TEST_UPDATES_DELAY_MS", &buf)) |v| {
            if (std.fmt.parseInt(u32, v, 10)) |ms| return ms else |_| {}
        }
    }
    return update_list.startDelayMs(self.prng.random());
}

fn arm(self: *Updates, ms: u64) void {
    const wait = @min(ms, max_wait_ms);
    if (c.SetTimer(self.app.wakeup_hwnd, timer_id, @intCast(@max(wait, 1)), null) == 0) return;
    self.due_ms = c.GetTickCount64() + wait;
}

fn stopTimer(self: *Updates) void {
    if (self.due_ms == null) return;
    _ = c.KillTimer(self.app.wakeup_hwnd, timer_id);
    self.due_ms = null;
}

// ---------------------------------------------------------------- files

fn path(self: *const Updates, a: Allocator, comptime name: []const u8) ?[]u8 {
    const dir = self.dir orelse return null;
    return std.fmt.allocPrint(a, "{s}\\" ++ name, .{dir}) catch null;
}

/// Read the state file into `state`: defaults when there is none. One that
/// is there but can't be read (busy, or a newer murrtty's that this one
/// can't parse) leaves defaults in memory and `state_unreadable` set, so
/// nothing writes over it.
fn loadState(self: *Updates) void {
    _ = self.state_arena.reset(.free_all);
    self.state = .{};
    self.state_unreadable = false;
    const a = self.state_arena.allocator();
    const file = self.path(a, "updates.json") orelse return;
    const text = Session.readFile(a, file) orelse {
        if (exists(a, file)) {
            log.warn("updates.json can't be read: left as it is", .{});
            self.state_unreadable = true;
        }
        return;
    };
    self.state = std.json.parseFromSliceLeaky(State, a, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        log.warn("updates.json unreadable, left as it is err={}", .{err});
        self.state = .{};
        self.state_unreadable = true;
        return;
    };
}

fn saveState(self: *Updates) void {
    if (self.state_unreadable) return;
    var arena: std.heap.ArenaAllocator = .init(self.app.core_app.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = self.dir orelse return;
    Session.makeDirs(a, dir) catch {};
    const file = self.path(a, "updates.json") orelse return;
    const text = std.json.Stringify.valueAlloc(a, self.state, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }) catch return;
    Session.writeFile(a, file, text) catch |err| log.warn("updates.json not written err={}", .{err});
}

fn exists(a: Allocator, file: []const u8) bool {
    const w = text_util.utf16Lossy(a, file) catch return false;
    return c.GetFileAttributesW(w.ptr) != c.INVALID_FILE_ATTRIBUTES;
}

/// The list kept from an earlier check (`updates\list.json`), with the
/// ETag the state file gives it (both are written together).
fn loadList(self: *Updates) void {
    var arena: std.heap.ArenaAllocator = .init(self.app.core_app.alloc);
    defer arena.deinit();
    const file = self.path(arena.allocator(), "updates\\list.json") orelse return;
    const text = Session.readFile(arena.allocator(), file) orelse return;
    _ = self.parseList(text, self.state.etag);
}

/// Take a list's text: parsed, held with its ETag, written to the cache
/// (`unsaved` when it couldn't be).
fn takeList(self: *Updates, text: []const u8, etag: ?[]const u8) enum { kept, unsaved, bad } {
    if (!self.parseList(text, etag)) return .bad;
    var arena: std.heap.ArenaAllocator = .init(self.app.core_app.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = self.path(a, "updates") orelse return .unsaved;
    Session.makeDirs(a, dir) catch {};
    const file = self.path(a, "updates\\list.json") orelse return .unsaved;
    Session.writeFile(a, file, text) catch |err| {
        log.warn("the release list not kept err={}", .{err});
        return .unsaved;
    };
    return .kept;
}

fn parseList(self: *Updates, text: []const u8, etag: ?[]const u8) bool {
    var arena: std.heap.ArenaAllocator = .init(self.app.core_app.alloc);
    const a = arena.allocator();
    const list = update_list.parse(a, text) catch |err| {
        log.warn("the release list unreadable err={}", .{err});
        arena.deinit();
        return false;
    };
    const tag = if (etag) |e| a.dupe(u8, e) catch null else null;
    // `found` points into the list it replaces.
    self.found = null;
    self.list_arena.deinit();
    self.list_arena = arena;
    self.list = list;
    self.list_etag = tag;
    return true;
}

fn setString(self: *Updates, field: *?[]const u8, value: ?[]const u8) void {
    field.* = if (value) |v| self.state_arena.allocator().dupe(u8, v) catch null else null;
}

/// The state file's lock: `updates.lock` held open with no sharing while
/// the state is read and written, so two murrttys (another session's, or
/// one with a `class` of its own) never both see a check as due. `busy`
/// when another murrtty holds it (a few milliseconds), `failed` when it
/// can't be had at all (an unwritable folder).
const Lock = union(enum) {
    held: Held,
    busy,
    failed,

    const Held = struct {
        handle: c.HANDLE,

        fn release(self: Held) void {
            _ = c.CloseHandle(self.handle);
        }
    };

    fn take(updates: *Updates) Lock {
        var arena: std.heap.ArenaAllocator = .init(updates.app.core_app.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        const dir = updates.dir orelse return .failed;
        Session.makeDirs(a, dir) catch {};
        const file = updates.path(a, "updates.lock") orelse return .failed;
        const w = text_util.utf16Lossy(a, file) catch return .failed;
        for (0..4) |i| {
            const h = c.CreateFileW(w.ptr, c.GENERIC_READ | c.GENERIC_WRITE, 0, null, c.OPEN_ALWAYS, c.FILE_ATTRIBUTE_NORMAL, null);
            if (h != c.INVALID_HANDLE_VALUE) return .{ .held = .{ .handle = h } };
            if (c.GetLastError() != c.ERROR_SHARING_VIOLATION) return .failed;
            if (i < 3) c.Sleep(1);
        }
        return .busy;
    }
};

/// Now, in Unix seconds.
pub fn unixNow() i64 {
    var ft: c.FILETIME = undefined;
    c.GetSystemTimeAsFileTime(&ft);
    const ticks = @as(i64, ft.dwHighDateTime) << 32 | ft.dwLowDateTime;
    return @divTrunc(ticks - 116444736000000000, 10_000_000);
}

// ---------------------------------------------------------------- tests' stand-ins

/// A test variable's value (ASCII), with the test hooks only.
fn testEnv(comptime name: []const u8, buf: []u8) ?[]const u8 {
    if (comptime !test_hooks.enabled) return null;
    var wide: [512]u16 = undefined;
    const n = c.GetEnvironmentVariableW(c.L(name), &wide, wide.len);
    if (n == 0 or n >= wide.len or n > buf.len) return null;
    for (wide[0..n], buf[0..n]) |unit, *b| b.* = if (unit < 0x80) @intCast(unit) else '?';
    return buf[0..n];
}

/// GHOSTTY_WIN32_TEST_UPDATES_URL: the GUI tests' server on 127.0.0.1.
fn testUrl(buf: []u8) ?[]const u8 {
    return testEnv("GHOSTTY_WIN32_TEST_UPDATES_URL", buf);
}

/// Under the test hooks the connection's cost is the tests' to say
/// (GHOSTTY_WIN32_TEST_UPDATES_METERED=1), so a runner's network can't
/// change a result.
fn testMetered() ?bool {
    if (comptime !test_hooks.enabled) return null;
    var buf: [4]u8 = undefined;
    const v = testEnv("GHOSTTY_WIN32_TEST_UPDATES_METERED", &buf) orelse return false;
    return std.mem.eql(u8, v, "1");
}

test "updates: unix time" {
    const now = unixNow();
    // After this file was written, before 2100.
    try std.testing.expect(now > 1_793_000_000 and now < 4_102_444_800);
}

test "updates: a far future waits the longest timer wait" {
    try std.testing.expectEqual(@as(u64, 0), secondsToMs(-5));
    try std.testing.expectEqual(@as(u64, 7000), secondsToMs(7));
    try std.testing.expectEqual(max_wait_ms, secondsToMs(std.math.maxInt(i64)));
}

test "updates: the state's file round trips" {
    const a = std.testing.allocator;
    const state: State = .{ .interval = .weekly, .consent = true, .next_check = 5, .etag = "\"abc\"", .read = &.{ "0.4.0", "0.5.0" } };
    const text = try std.json.Stringify.valueAlloc(a, state, .{ .emit_null_optional_fields = false });
    defer a.free(text);
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const back = try std.json.parseFromSliceLeaky(State, arena.allocator(), text, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(update_list.Interval.weekly, back.interval);
    try std.testing.expect(back.consent);
    try std.testing.expectEqualStrings("\"abc\"", back.etag.?);
    try std.testing.expectEqual(@as(usize, 2), back.read.len);
    // An older or newer murrtty's file still loads.
    const odd = try std.json.parseFromSliceLeaky(State, arena.allocator(), "{\"interval\":\"daily\",\"later\":[1]}", .{ .ignore_unknown_fields = true });
    try std.testing.expect(!odd.consent);
    // A value this murrtty doesn't know is an error: the file is left alone.
    try std.testing.expectError(error.InvalidEnumTag, std.json.parseFromSliceLeaky(State, arena.allocator(), "{\"interval\":\"hourly\"}", .{ .ignore_unknown_fields = true }));
}
