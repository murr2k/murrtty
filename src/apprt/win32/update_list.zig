//! The release list murrtty's update checks read (roadmap 7.6), and the
//! arithmetic of when to check: no Windows calls here, so all of it is
//! unit tested.
//!
//! The list is murrtty.org/updates/v1.json, which site/build_worker.py
//! writes from GitHub's releases: every murrtty-vX.Y.Z release, newest
//! first, with its channel (by the version's form: X.Y.Z is stable),
//! preview flag, date, title, page, the newest ones' notes, and each
//! architecture's files. It only says what exists: nothing in it is
//! trusted to say a file is safe (7.6b checks each file's signature).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The list's address. A test build may point it elsewhere (Updates.zig).
pub const default_url = "https://murrtty.org/updates/v1.json";

/// The list's own version: a list murrtty doesn't understand is ignored.
pub const schema = 1;

pub const File = struct {
    name: []const u8 = "",
    url: []const u8 = "",
    size: u64 = 0,
    sha256: ?[]const u8 = null,
};

pub const Files = struct {
    zip: ?File = null,
    setup: ?File = null,
};

pub const Release = struct {
    version: []const u8,
    tag: []const u8 = "",
    channel: []const u8 = "stable",
    preview: bool = false,
    date: []const u8 = "",
    title: []const u8 = "",
    url: []const u8 = "",
    notes: ?[]const u8 = null,
    files: struct {
        x86_64: ?Files = null,
        aarch64: ?Files = null,
    } = .{},
    /// The release's SHA256SUMS.txt and, from 0.6.0 on, its signature
    /// (SHA256SUMS.txt.sig, roadmap 7.6b). This list isn't signed, so a
    /// file is used only if a key murrtty carries signed the sums, its
    /// hash is in them under the name `murrtty-<version>-windows-<this
    /// machine's architecture>` (`.zip` or `-setup.exe`) and that version is
    /// newer than the running one: what the list says of a release is
    /// believed only where the signed sums say it too.
    sums: ?File = null,
    signature: ?File = null,
};

pub const List = struct {
    schema: u32,
    /// The project can make every copy check less often without a
    /// release: no copy checks sooner than this after its last check.
    min_check_hours: ?u32 = null,
    releases: []Release = &.{},
};

/// Read a list (into `arena`); a list of another schema, or one with no
/// release whose version parses, is an error.
pub fn parse(arena: Allocator, text: []const u8) !List {
    const list = try std.json.parseFromSliceLeaky(List, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    if (list.schema != schema) return error.UnknownSchema;
    var kept: std.ArrayList(Release) = .empty;
    for (list.releases) |r| {
        _ = std.SemanticVersion.parse(r.version) catch continue;
        try kept.append(arena, r);
    }
    if (kept.items.len == 0) return error.NoReleases;
    var out = list;
    out.releases = kept.items;
    return out;
}

pub const Channel = enum {
    stable,
    tip,

    /// Whether a release of `channel` (the list's word) is offered on
    /// this one: tip takes the stable releases too.
    pub fn offers(self: Channel, channel: []const u8) bool {
        if (std.mem.eql(u8, channel, "stable")) return true;
        return self == .tip and std.mem.eql(u8, channel, "tip");
    }
};

/// The newest release on `channel` newer than `running`, unless it is the
/// one the user skipped; null when there is none. A newer one than the
/// skipped is offered again.
pub fn newest(list: List, channel: Channel, running: std.SemanticVersion, skipped: ?[]const u8) ?Release {
    var best: ?Release = null;
    var best_v: std.SemanticVersion = running;
    for (list.releases) |r| {
        if (!channel.offers(r.channel)) continue;
        const v = std.SemanticVersion.parse(r.version) catch continue;
        if (v.order(best_v) != .gt) continue;
        best = r;
        best_v = v;
    }
    const b = best orelse return null;
    if (skipped) |s| if (std.mem.eql(u8, s, b.version)) return null;
    return b;
}

/// Whether `version` is newer than `running` (a list entry that doesn't
/// parse is not).
pub fn isNewer(version: []const u8, running: std.SemanticVersion) bool {
    const v = std.SemanticVersion.parse(version) catch return false;
    return v.order(running) == .gt;
}

/// The parts of the list's address WinHTTP takes. Only https, except
/// plain http to the loopback address, which the tests' server uses.
pub const Url = struct {
    secure: bool,
    host: []const u8,
    port: u16,
    path: []const u8,

    pub fn parse(url: []const u8) !Url {
        var rest: []const u8 = undefined;
        var secure = true;
        if (std.mem.startsWith(u8, url, "https://")) {
            rest = url["https://".len..];
        } else if (std.mem.startsWith(u8, url, "http://127.0.0.1:") or std.mem.startsWith(u8, url, "http://127.0.0.1/")) {
            rest = url["http://".len..];
            secure = false;
        } else return error.UnsupportedUrl;
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const authority = rest[0..slash];
        const path = if (slash < rest.len) rest[slash..] else "/";
        if (authority.len == 0) return error.UnsupportedUrl;
        var host = authority;
        var port: u16 = if (secure) 443 else 80;
        if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
            host = authority[0..colon];
            port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return error.UnsupportedUrl;
        }
        if (host.len == 0) return error.UnsupportedUrl;
        return .{ .secure = secure, .host = host, .port = port, .path = path };
    }
};

/// How often an automatic check runs.
pub const Interval = enum {
    daily,
    weekly,
    monthly,

    pub fn seconds(self: Interval) i64 {
        return switch (self) {
            .daily => 24 * 3600,
            .weekly => 7 * 24 * 3600,
            .monthly => 30 * 24 * 3600,
        };
    }
};

/// A delay after murrtty has finished starting before an automatic check
/// that is due: 2 to 10 minutes, at random, so it never competes with the
/// first commands and launches don't line up.
pub fn startDelayMs(random: std.Random) u32 {
    return random.intRangeAtMost(u32, 2 * 60 * 1000, 10 * 60 * 1000);
}

/// When to check next after a check at `now`: a random point within a
/// tenth of the interval either side of it, so copies spread out; never
/// sooner than the list's minimum.
pub fn nextCheck(now: i64, interval: Interval, min_check_hours: ?u32, random: std.Random) i64 {
    const span = interval.seconds();
    const tenth = @divTrunc(span, 10);
    var next = now + span - tenth + random.intRangeAtMost(i64, 0, 2 * tenth);
    if (min_check_hours) |h| next = @max(next, now + @as(i64, h) * 3600);
    return next;
}

/// After `failures` failed checks in a row: 15 minutes, doubling, but
/// never longer than the interval, with a fifth of jitter; a server's
/// Retry-After, when longer, wins.
pub fn retryAt(now: i64, failures: u32, interval: Interval, retry_after: ?u32, random: std.Random) i64 {
    const base: i64 = 15 * 60;
    const shift: u6 = @intCast(@min(failures -| 1, 20));
    var wait = @min(base << shift, interval.seconds());
    wait += random.intRangeAtMost(i64, 0, @divTrunc(wait, 5));
    if (retry_after) |s| wait = @max(wait, @as(i64, s));
    return now + wait;
}

/// A Retry-After header's seconds (the HTTP-date form is ignored: a
/// server slowing clients down sends seconds).
pub fn parseRetryAfter(value: []const u8) ?u32 {
    const t = std.mem.trim(u8, value, " \t");
    return std.fmt.parseInt(u32, t, 10) catch null;
}

test "update list: parse, newest on a channel, skipped" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\{"schema":1,"min_check_hours":48,"releases":[
        \\ {"version":"0.7.0-beta.1","channel":"tip","date":"2026-12-01","title":"murrtty 0.7.0 beta 1"},
        \\ {"version":"0.6.0","channel":"stable","date":"2026-11-20","title":"murrtty 0.6.0","notes":"### What's new","files":{"x86_64":{"zip":{"name":"z","url":"u","size":3,"sha256":"ab"}}},"sums":{"name":"SHA256SUMS.txt","url":"s","size":714},"signature":{"name":"SHA256SUMS.txt.sig","url":"g","size":64},"extra":1},
        \\ {"version":"not a version"},
        \\ {"version":"0.5.0","channel":"stable","date":"2026-11-06"}]}
    ;
    const list = try parse(a, text);
    try testing.expectEqual(@as(usize, 3), list.releases.len);
    try testing.expectEqual(@as(?u32, 48), list.min_check_hours);
    try testing.expectEqual(@as(u64, 3), list.releases[1].files.x86_64.?.zip.?.size);
    try testing.expectEqual(@as(u64, 64), list.releases[1].signature.?.size);
    try testing.expectEqualStrings("s", list.releases[1].sums.?.url);
    // A list from before signatures has neither.
    try testing.expect(list.releases[2].signature == null and list.releases[2].sums == null);
    const running = try std.SemanticVersion.parse("0.5.0");
    try testing.expectEqualStrings("0.6.0", newest(list, .stable, running, null).?.version);
    try testing.expectEqualStrings("0.7.0-beta.1", newest(list, .tip, running, null).?.version);
    try testing.expect(newest(list, .stable, running, "0.6.0") == null);
    try testing.expect(newest(list, .stable, try std.SemanticVersion.parse("0.6.0"), null) == null);
    try testing.expect(isNewer("0.6.0", running) and !isNewer("0.5.0", running) and !isNewer("x", running));
    try testing.expectError(error.UnknownSchema, parse(a, "{\"schema\":2,\"releases\":[]}"));
    try testing.expectError(error.NoReleases, parse(a, "{\"schema\":1,\"releases\":[{\"version\":\"x\"}]}"));
}

test "update list: the address" {
    const testing = std.testing;
    const u = try Url.parse("https://murrtty.org/updates/v1.json");
    try testing.expect(u.secure and u.port == 443);
    try testing.expectEqualStrings("murrtty.org", u.host);
    try testing.expectEqualStrings("/updates/v1.json", u.path);
    const t = try Url.parse("http://127.0.0.1:8123/list.json");
    try testing.expect(!t.secure and t.port == 8123);
    try testing.expectEqualStrings("127.0.0.1", t.host);
    try testing.expectError(error.UnsupportedUrl, Url.parse("http://murrtty.org/x"));
    try testing.expectError(error.UnsupportedUrl, Url.parse("ftp://x/y"));
    try testing.expectEqualStrings("/", (try Url.parse("https://murrtty.org")).path);
}

test "update list: when to check" {
    const testing = std.testing;
    var prng = std.Random.DefaultPrng.init(42);
    const r = prng.random();
    for (0..200) |_| {
        const d = startDelayMs(r);
        try testing.expect(d >= 120_000 and d <= 600_000);
        const n = nextCheck(1000, .daily, null, r);
        try testing.expect(n >= 1000 + 86400 - 8640 and n <= 1000 + 86400 + 8640);
        try testing.expect(nextCheck(0, .daily, 72, r) >= 72 * 3600);
        const first = retryAt(0, 1, .daily, null, r);
        try testing.expect(first >= 900 and first <= 1080);
        // Never longer than the interval (plus its jitter) however many
        // failures, unless the server asks for longer.
        try testing.expect(retryAt(0, 30, .daily, null, r) <= 86400 + 86400 / 5);
        try testing.expect(retryAt(0, 1, .daily, 7200, r) >= 7200);
    }
    try testing.expectEqual(@as(?u32, 120), parseRetryAfter(" 120"));
    try testing.expect(parseRetryAfter("Wed, 21 Oct 2026 07:28:00 GMT") == null);
}
