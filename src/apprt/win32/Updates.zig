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
const ConfigEditor = @import("ConfigEditor.zig");
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
    /// The configuration turns automatic checks on but the user turned them
    /// off on this machine (the notice's Turn Off). The file is left alone:
    /// it may be another computer's too.
    declined: bool = false,
    /// The one-time notice about checks a configuration turns on was shown.
    noticed: bool = false,
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

pub const Note = enum { none, not_found, failed };

/// The header bars' update pill (roadmap 7.6a), macOS Ghostty's: hidden
/// when there is nothing to say.
pub const Pill = enum { hidden, permission, checking, available, not_found, failed };

/// The note's timer, on the wakeup window.
pub const note_timer_id = 0x5D7F;
const note_ms = 5_000;

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
/// What the header bars' pill says after a check the user asked for,
/// until it is dismissed: nothing found (for 5 s, as macOS Ghostty's), or
/// the check failed.
note: Note = .none,
prng: std.Random.DefaultPrng,
/// The state has been read (start): until then the pill says nothing (it
/// would ask for an OK given earlier).
loaded: bool = false,
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
    self.loaded = true;
    self.refresh();
    self.schedule();
    self.notify();
}

/// The config changed: `auto-update` or its channel may have.
pub fn configChanged(self: *Updates) void {
    self.refresh();
    self.schedule();
    self.notify();
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
    self.setNote(.none);
    if (self.job != null) {
        // The check in flight answers this one too (the pill says it
        // checks now).
        self.asked = true;
        self.notify();
        return;
    }
    _ = self.startJob(.manual);
    self.notify();
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
    self.notify();
}

/// The timer: an automatic check, if it is due (another murrtty may have
/// checked meanwhile).
pub fn tick(self: *Updates) void {
    self.stopTimer();
    self.collect();
    // The state file couldn't be read: look again (it may only have been
    // busy, or a newer murrtty's file is gone).
    if (self.state_unreadable and self.job == null) return self.reload();
    if (self.job == null and self.noticeDue()) return self.showNotice();
    if (!self.automaticOn() or self.job != null) return;
    // The state read (another murrtty may have changed it) and the check
    // started under the lock; the window told after it is let go.
    defer self.notify();
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

    // What the check learned, written under the lock; the window, the
    // header bars and the notification after it is let go (their drawing
    // shouldn't hold other murrttys off).
    const tell = locked: {
        const lock = Lock.take(self);
        defer if (lock == .held) lock.held.release();
        // Busy past its retries: what this check learned is still worth
        // writing (a missed lock risks one more check, a missed write a
        // check per tick).
        if (lock == .held) self.loadState();
        self.learn(job, kind, now);
        if (kind == .automatic) self.state.lease_until = 0;
        self.refresh();
        const found_new = self.noteFound(kind == .automatic and !asked);
        self.saveState();
        break :locked found_new;
    };
    // A check the user asked for: the pill says how it went.
    if (kind == .manual or asked) self.setNote(if (self.status == .failed)
        .failed
    else if (self.found == null and (job.outcome == .ok or job.outcome == .not_modified))
        .not_found
    else
        .none);
    // The user asked while an automatic check found the connection
    // metered: theirs runs anyway.
    if (asked and job.outcome == .metered) _ = self.startJob(.manual);
    self.schedule();
    if (tell) self.announce();
    self.notify();
}

/// What a finished check's answer means for the state and the list.
fn learn(self: *Updates, job: *update_fetch.Job, kind: Kind, now: i64) void {
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
}

/// A release found that no notification has told of: recorded as told,
/// and whether to tell of it now (an automatic check's: one the user asked
/// for shows it in the window).
fn noteFound(self: *Updates, automatic: bool) bool {
    const f = self.found orelse return false;
    if (self.state.notified) |n| if (std.mem.eql(u8, n, f.version)) return false;
    self.setString(&self.state.notified, f.version);
    return automatic;
}

/// Tell of the release found, as Update Settings say: a notification, or
/// the Updates window opened without taking the keyboard (a notification
/// while a dialog is open).
fn announce(self: *Updates) void {
    const f = self.found orelse return;
    if (self.state.on_found == .window and self.app.modal_depth == 0) return self.app.openUpdatesQuietly();
    var title_buf: [96]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "murrtty {s} is available", .{f.version}) catch "A murrtty update is available";
    var body_buf: [128]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "You have {d}.{d}.{d}. Click to see what's new.", .{ self.running.major, self.running.minor, self.running.patch }) catch "";
    self.app.notifications.sendUpdate(.found, title, body);
}

/// Whether the configuration's automatic checks wait for the OK on this
/// machine (a file murrtty didn't write: another computer's, or written by
/// hand).
pub fn waiting(self: *const Updates) bool {
    // Without a state that can be kept or read, the OK can't be known.
    if (self.dir == null or self.state_unreadable) return false;
    return self.release_build and self.mode() != .off and !self.state.consent and !self.state.declined;
}

/// Read the state again: another murrtty (another class's) may have
/// changed it. Before the Updates window shows it, and on the unreadable
/// state's retry.
pub fn reload(self: *Updates) void {
    if (self.dir == null) return;
    {
        const lock = Lock.take(self);
        if (lock == .busy) return self.schedule();
        defer if (lock == .held) lock.held.release();
        self.loadState();
    }
    self.refresh();
    self.schedule();
    self.notify();
}

/// Whether the configuration turns automatic checks on, and the user
/// turned them off on this machine.
pub fn declinedHere(self: *const Updates) bool {
    if (self.dir == null or self.state_unreadable) return false;
    return self.release_build and self.mode() != .off and !self.state.consent and self.state.declined;
}

pub fn pill(self: *const Updates) Pill {
    if (!self.release_build or !self.loaded) return .hidden;
    if (self.job != null and (self.job_kind == .manual or self.asked)) return .checking;
    if (self.note == .failed) return .failed;
    if (self.found != null) return .available;
    if (self.note == .not_found) return .not_found;
    if (self.waiting()) return .permission;
    return .hidden;
}

/// The pill's text, macOS Ghostty's words ("" while hidden).
pub fn pillText(self: *const Updates, buf: []u8) []const u8 {
    return switch (self.pill()) {
        .hidden => "",
        .permission => "Enable Automatic Updates?",
        .checking => "Checking for Updates\u{2026}",
        .available => std.fmt.bufPrint(buf, "Update Available: {s}", .{self.found.?.version}) catch "Update Available",
        .not_found => "No Updates Available",
        .failed => "Update Check Failed",
    };
}

/// Set the pill's note: nothing found goes by itself after 5 s.
fn setNote(self: *Updates, note: Note) void {
    self.note = note;
    _ = c.KillTimer(self.app.wakeup_hwnd, note_timer_id);
    if (note == .not_found) _ = c.SetTimer(self.app.wakeup_hwnd, note_timer_id, note_ms, null);
}

/// The note dismissed (a click on the pill, the Updates window opened).
pub fn dismissNote(self: *Updates) void {
    if (self.note == .none) return;
    self.setNote(.none);
    self.notify();
}

/// The note's 5 s are up.
pub fn noteTimer(self: *Updates) void {
    _ = c.KillTimer(self.app.wakeup_hwnd, note_timer_id);
    if (self.note == .not_found) self.dismissNote();
}

/// Whether the one-time notice is due here: the configuration turns
/// automatic checks on, nobody agreed on this machine, and no murrtty of
/// this user has shown it. Only the pipe's owner shows it, at the time its
/// first automatic check would come.
fn noticeDue(self: *const Updates) bool {
    return self.owner and self.waiting() and !self.state.noticed and self.app.notifications.hwnd != null;
}

/// The one-time notice (roadmap 7.6a): the configuration turns automatic
/// checks on, but nobody agreed on this machine (a file shared with another
/// computer, say), so the first check waits for it. Shown once, naming the
/// file and line; its buttons answer it (answerNotice), and until then the
/// pill and the Updates window offer the same.
fn showNotice(self: *Updates) void {
    const shown = shown: {
        const lock = Lock.take(self);
        switch (lock) {
            .busy => return self.arm(min_wait_ms + self.prng.random().uintLessThan(u64, 5_000)),
            .failed, .held => {},
        }
        defer if (lock == .held) lock.held.release();
        self.loadState();
        // Another murrtty may have shown it, or the user answered.
        if (!self.noticeDue()) break :shown false;
        self.state.noticed = true;
        self.saveState();
        break :shown true;
    };
    if (shown) {
        const alloc = self.app.core_app.alloc;
        const how_often: []const u8 = switch (self.state.interval) {
            .daily => "once a day",
            .weekly => "once a week",
            .monthly => "once a month",
        };
        var where_buf: [320]u8 = undefined;
        const where: []const u8 = if (ConfigEditor.optionSource(self.app, alloc, "auto-update")) |src| where: {
            defer alloc.free(src.path);
            break :where std.fmt.bufPrint(&where_buf, "{s}, line {d}, sets auto-update = {t}", .{ folderAndName(src.path), src.line, self.mode() }) catch "Your configuration turns them on";
        } else "Your configuration turns them on";
        var body_buf: [640]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "{s}. murrtty asks murrtty.org for its list of releases ({s}, with no version, ID or cookie) only once you agree on this computer.", .{ where, how_often }) catch where;
        self.app.notifications.sendUpdate(.notice, "Check for updates automatically?", body);
    }
    self.schedule();
    self.notify();
}

/// A file's folder and name ("murrtty\config.ghostty"): which program's
/// configuration it is, short enough for a notification.
fn folderAndName(file: []const u8) []const u8 {
    const name = std.mem.lastIndexOfAny(u8, file, "\\/") orelse return file;
    const folder = std.mem.lastIndexOfAny(u8, file[0..name], "\\/") orelse return file;
    return file[folder + 1 ..];
}

test "folderAndName" {
    try std.testing.expectEqualStrings("murrtty\\config.ghostty", folderAndName("C:\\Users\\u\\AppData\\Local\\murrtty\\config.ghostty"));
    try std.testing.expectEqualStrings("ghostty/config", folderAndName("/home/u/.config/ghostty/config"));
    try std.testing.expectEqualStrings("config", folderAndName("config"));
}

/// The notice's answer: Keep On agrees on this machine (the configuration
/// already says check), Turn Off turns them off here and leaves the file.
pub fn answerNotice(self: *Updates, keep: bool) void {
    if (keep) return self.setConsent(true);
    self.change({}, struct {
        fn f(u: *Updates, _: void) void {
            u.state.consent = false;
            u.state.declined = true;
            u.state.noticed = true;
        }
    }.f);
}

// ---------------------------------------------------------------- the user's changes

/// A change the user made (the Updates window): the state read under the
/// lock, changed by `f`, written, and shown once the lock is let go.
fn change(self: *Updates, ctx: anytype, comptime f: fn (*Updates, @TypeOf(ctx)) void) void {
    {
        const lock = Lock.take(self);
        defer if (lock == .held) lock.held.release();
        if (lock == .held) self.loadState();
        f(self, ctx);
        // Busy past its retries, the choice is still written: the next
        // read would drop it otherwise.
        self.saveState();
    }
    self.refresh();
    self.schedule();
    self.notify();
}

/// Whether a release's notes count as read: read in the window, or not
/// newer than this murrtty.
pub fn isRead(self: *const Updates, version: []const u8) bool {
    if (!update_list.isNewer(version, self.running)) return true;
    for (self.state.read) |v| if (std.mem.eql(u8, v, version)) return true;
    return false;
}

pub fn markRead(self: *Updates, version: []const u8) void {
    if (self.isRead(version)) return;
    self.change(version, struct {
        fn f(u: *Updates, v: []const u8) void {
            for (u.state.read) |r| if (std.mem.eql(u8, r, v)) return;
            const a = u.state_arena.allocator();
            const read = a.alloc([]const u8, u.state.read.len + 1) catch return;
            @memcpy(read[0..u.state.read.len], u.state.read);
            read[u.state.read.len] = a.dupe(u8, v) catch return;
            u.state.read = read;
        }
    }.f);
}

/// Skip This Version: not offered again, until a newer one comes.
pub fn skip(self: *Updates, version: []const u8) void {
    self.change(version, struct {
        fn f(u: *Updates, v: []const u8) void {
            u.setString(&u.state.skipped, v);
        }
    }.f);
}

/// How often: the next check moves to the new interval from the last.
pub fn setInterval(self: *Updates, interval: update_list.Interval) void {
    self.change(interval, struct {
        fn f(u: *Updates, i: update_list.Interval) void {
            u.state.interval = i;
            if (u.state.last_check > 0) {
                const min_hours = if (u.list) |l| l.min_check_hours else null;
                u.state.next_check = update_list.nextCheck(u.state.last_check, i, min_hours, u.prng.random());
            }
        }
    }.f);
}

pub fn setOnFound(self: *Updates, on_found: OnFound) void {
    self.change(on_found, struct {
        fn f(u: *Updates, o: OnFound) void {
            u.state.on_found = o;
        }
    }.f);
}

/// The consent dialog's answer, kept for this machine.
pub fn setConsent(self: *Updates, consent: bool) void {
    self.change(consent, struct {
        fn f(u: *Updates, on: bool) void {
            u.state.consent = on;
            if (on) u.state.declined = false;
        }
    }.f);
}

/// Clear Cached Update Information: the list kept and its ETag, the
/// releases skipped, read and announced. The settings and consent stay.
pub fn clearCache(self: *Updates) void {
    var arena: std.heap.ArenaAllocator = .init(self.app.core_app.alloc);
    defer arena.deinit();
    if (self.path(arena.allocator(), "updates\\list.json")) |file| Session.deleteFile(arena.allocator(), file);
    self.found = null;
    self.list = null;
    self.list_etag = null;
    self.last_outcome = null;
    self.change({}, struct {
        fn f(u: *Updates, _: void) void {
            u.state.etag = null;
            u.state.skipped = null;
            u.state.notified = null;
            u.state.read = &.{};
        }
    }.f);
}

/// Tell the window (and, from 7.6a's next step, the header bars) what
/// changed.
fn notify(self: *Updates) void {
    self.app.updatesChanged();
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
/// The caller tells the window (`notify`), after any lock it holds.
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
    // The notice comes when the first check would.
    if (!self.automaticOn() and !self.noticeDue()) return;
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
    // A hand-edited file's times stay where the arithmetic on them (an
    // interval added, ticks for Windows' clock) can't overflow.
    for ([_]*i64{ &self.state.last_check, &self.state.next_check, &self.state.lease_until }) |t| {
        t.* = std.math.clamp(t.*, 0, max_unix);
    }
}

/// The last second of 9999, in Unix seconds: the latest time kept.
pub const max_unix: i64 = 253402300799;

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
