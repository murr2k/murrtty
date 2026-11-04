//! What a downloaded update must pass before murrtty uses it (roadmap
//! 7.6b): no Windows calls here, so all of it is unit tested.
//!
//! The release list (update_list.zig) isn't signed, so nothing it says is
//! believed on its own. A release's SHA256SUMS.txt must carry a signature
//! one of murrtty's keys made (update_keys.zig); the file murrtty wants must
//! be in it under its exact name, `murrtty-<version>-windows-<arch>-setup.exe`
//! for the version the list named and this build's architecture, so signed
//! sums of another release (an older one, the other architecture's) never
//! pass for this one; and the downloaded file's SHA-256 must be the one the
//! signed sums give. Every address murrtty downloads from must be one of
//! murrtty's own GitHub release downloads.

const std = @import("std");
const builtin = @import("builtin");
const update_keys = @import("update_keys.zig");

/// Why a download was refused (and deleted): the window says it in words.
pub const Refusal = enum {
    /// No key murrtty carries signed its SHA256SUMS.txt.
    bad_signature,
    /// The signed sums don't name this release's installer for this
    /// machine: they may be another release's.
    wrong_release,
    /// The file's SHA-256 isn't the one the signed sums give.
    wrong_hash,
    /// The list named a download outside murrtty's GitHub releases.
    bad_address,
    /// Larger than any murrtty installer, or than any sums or signature.
    too_big,
};

/// The release files' architectures, as their names spell them.
pub const Arch = enum { x86_64, aarch64 };

/// This build's: an x64 murrtty updates with the x64 installer, also where
/// Windows runs it on ARM64.
pub const native_arch: Arch = switch (builtin.cpu.arch) {
    .aarch64 => .aarch64,
    else => .x86_64,
};

/// Size limits: a signature is 64 bytes (more is no signature), the sums a
/// few hundred, an installer tens of megabytes.
pub const signature_len = 64;
pub const max_signature = 1024;
pub const max_sums = 64 * 1024;
pub const max_installer: u64 = 512 * 1024 * 1024;

/// Where murrtty's release downloads are.
pub const release_downloads = "https://github.com/murr2k/murrtty/releases/download/";

/// Whether `version` (from the unsigned list) may name a folder and a file:
/// a semantic version of letters, digits, '.', '-' and '+' only.
pub fn versionOk(version: []const u8) bool {
    if (version.len == 0 or version.len > 64) return false;
    for (version) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-' or ch == '+')) return false;
    _ = std.SemanticVersion.parse(version) catch return false;
    return true;
}

/// The installer's name for `version` on `arch`, into `buf`; null for a
/// version that can't name a file.
pub fn setupName(buf: []u8, version: []const u8, arch: Arch) ?[]const u8 {
    if (!versionOk(version)) return null;
    return std.fmt.bufPrint(buf, "murrtty-{s}-windows-{t}-setup.exe", .{ version, arch }) catch null;
}

/// The SHA-256 the sums give `name`: a line of 64 hex digits, a space, and
/// the name (after a second space or `*`, sha256sum's text and binary
/// forms). Null if no line names it, or two lines give it different hashes.
pub fn hashOf(sums: []const u8, name: []const u8) ?[32]u8 {
    var found: ?[32]u8 = null;
    var lines = std.mem.splitScalar(u8, sums, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len < 66 or line[64] != ' ') continue;
        var rest = line[65..];
        if (rest.len > 0 and (rest[0] == ' ' or rest[0] == '*')) rest = rest[1..];
        if (!std.mem.eql(u8, rest, name)) continue;
        var digest: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&digest, line[0..64]) catch return null;
        if (found) |f| if (!std.mem.eql(u8, &f, &digest)) return null;
        found = digest;
    }
    return found;
}

pub const Checked = union(enum) {
    /// The signed SHA-256 of the file.
    ok: [32]u8,
    refused: Refusal,
};

/// The sums and their signature checked: a key of `keys` signed `sums`, and
/// they name `name`. Its signed SHA-256, or why not.
pub fn checkSums(keys: []const [32]u8, sums: []const u8, signature: []const u8, name: []const u8) Checked {
    if (signature.len != signature_len) return .{ .refused = .bad_signature };
    if (!update_keys.verifyWith(keys, sums, signature)) return .{ .refused = .bad_signature };
    const digest = hashOf(sums, name) orelse return .{ .refused = .wrong_release };
    return .{ .ok = digest };
}

/// Whether murrtty downloads `name` from `url`: `release_downloads`, a tag
/// of letters, digits, '.', '-' and '_', and exactly `name`; no query, no
/// dot segment. `test_origin` (the GUI tests' server, "http://127.0.0.1:<port>")
/// stands in for GitHub with the same path.
pub fn downloadUrlOk(url: []const u8, name: []const u8, test_origin: ?[]const u8) bool {
    const rest = if (std.mem.startsWith(u8, url, release_downloads))
        url[release_downloads.len..]
    else if (test_origin) |origin| local: {
        if (!std.mem.startsWith(u8, origin, "http://127.0.0.1:")) return false;
        if (!std.mem.startsWith(u8, url, origin)) return false;
        const path = url[origin.len..];
        const prefix = "/releases/download/";
        if (!std.mem.startsWith(u8, path, prefix)) return false;
        break :local path[prefix.len..];
    } else return false;
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
    const tag = rest[0..slash];
    if (tag.len == 0 or tag.len > 128) return false;
    if (std.mem.eql(u8, tag, ".") or std.mem.eql(u8, tag, "..")) return false;
    for (tag) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-' or ch == '_')) return false;
    return std.mem.eql(u8, rest[slash + 1 ..], name);
}

/// The scheme, host and port of a URL ("http://127.0.0.1:8123"), or null.
pub fn originOf(url: []const u8) ?[]const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    const after = scheme_end + 3;
    const slash = std.mem.indexOfScalarPos(u8, url, after, '/') orelse url.len;
    if (slash == after) return null;
    return url[0..slash];
}

test "update verify: versions and names" {
    const testing = std.testing;
    try testing.expect(versionOk("0.6.0") and versionOk("0.7.0-beta.1") and versionOk("1.0.0+build.5"));
    for ([_][]const u8{ "", "..", "0.6", "0.6.0/../x", "0.6.0\\x", "0.6.0 ", "x" }) |v| try testing.expect(!versionOk(v));
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("murrtty-0.6.0-windows-x86_64-setup.exe", setupName(&buf, "0.6.0", .x86_64).?);
    try testing.expectEqualStrings("murrtty-0.6.0-windows-aarch64-setup.exe", setupName(&buf, "0.6.0", .aarch64).?);
    try testing.expect(setupName(&buf, "../0.6.0", .x86_64) == null);
}

test "update verify: the sums" {
    const testing = std.testing;
    const a: [64]u8 = @splat('a');
    const b: [64]u8 = @splat('b');
    const sums = a ++ "  murrtty-0.6.0-windows-x86_64-setup.exe\r\n" ++
        b ++ " *murrtty-0.6.0-windows-aarch64-setup.exe\n" ++
        "not a line\n";
    var want: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want, &a);
    try testing.expectEqualSlices(u8, &want, &hashOf(sums, "murrtty-0.6.0-windows-x86_64-setup.exe").?);
    try testing.expect(hashOf(sums, "murrtty-0.6.0-windows-aarch64-setup.exe") != null);
    // Exactly the name: not a prefix, not another release's.
    try testing.expect(hashOf(sums, "murrtty-0.6.0-windows-x86_64-setup") == null);
    try testing.expect(hashOf(sums, "murrtty-0.5.0-windows-x86_64-setup.exe") == null);
    // Two lines disagreeing: neither.
    try testing.expect(hashOf(a ++ "  f.exe\n" ++ b ++ "  f.exe\n", "f.exe") == null);
    try testing.expect(hashOf(a ++ "  f.exe\n" ++ a ++ "  f.exe\n", "f.exe") != null);
    // Not hex.
    const g: [64]u8 = @splat('g');
    try testing.expect(hashOf(g ++ "  f.exe\n", "f.exe") == null);
}

test "update verify: signed sums" {
    const testing = std.testing;
    const Ed25519 = std.crypto.sign.Ed25519;
    const kp = try Ed25519.KeyPair.generateDeterministic(@splat(7));
    const other = try Ed25519.KeyPair.generateDeterministic(@splat(9));
    const name = "murrtty-0.6.0-windows-x86_64-setup.exe";
    const hex_c: [64]u8 = @splat('c');
    const hex_d: [64]u8 = @splat('d');
    const sums = hex_c ++ "  " ++ name ++ "\n";
    const sig = (try kp.sign(sums, null)).toBytes();
    const keys = [_][32]u8{kp.public_key.toBytes()};
    try testing.expect(checkSums(&keys, sums, &sig, name) == .ok);
    // Another key's signature, a cut one, changed sums.
    const forged = (try other.sign(sums, null)).toBytes();
    try testing.expectEqual(Checked{ .refused = .bad_signature }, checkSums(&keys, sums, &forged, name));
    try testing.expectEqual(Checked{ .refused = .bad_signature }, checkSums(&keys, sums, sig[0..63], name));
    try testing.expectEqual(Checked{ .refused = .bad_signature }, checkSums(&keys, hex_d ++ "  " ++ name ++ "\n", &sig, name));
    // Signed, but another release's: refused for this one.
    try testing.expectEqual(Checked{ .refused = .wrong_release }, checkSums(&keys, sums, &sig, "murrtty-9.9.9-windows-x86_64-setup.exe"));
    // murrtty's own keys didn't sign the test key's sums.
    try testing.expectEqual(Checked{ .refused = .bad_signature }, checkSums(&update_keys.keys, sums, &sig, name));
}

test "update verify: addresses" {
    const testing = std.testing;
    const name = "murrtty-0.6.0-windows-x86_64-setup.exe";
    try testing.expect(downloadUrlOk(release_downloads ++ "murrtty-v0.6.0/" ++ name, name, null));
    for ([_][]const u8{
        release_downloads ++ "murrtty-v0.6.0/other.exe",
        release_downloads ++ "murrtty-v0.6.0/" ++ name ++ "?x=1",
        release_downloads ++ "../murrtty-v0.6.0/" ++ name,
        release_downloads ++ "a/b/" ++ name,
        release_downloads ++ "/" ++ name,
        "https://github.com/murr2k/murrtty-evil/releases/download/v/" ++ name,
        "http://github.com/murr2k/murrtty/releases/download/murrtty-v0.6.0/" ++ name,
        "https://example.org/" ++ name,
    }) |url| try testing.expect(!downloadUrlOk(url, name, null));
    // The tests' server, only under its origin and GitHub's path.
    const origin = "http://127.0.0.1:8123";
    try testing.expect(downloadUrlOk(origin ++ "/releases/download/murrtty-v0.6.0/" ++ name, name, origin));
    try testing.expect(!downloadUrlOk("http://127.0.0.1:9999/releases/download/t/" ++ name, name, origin));
    try testing.expect(!downloadUrlOk(origin ++ "/elsewhere/t/" ++ name, name, origin));
    try testing.expect(!downloadUrlOk("http://10.0.0.1:8123/releases/download/t/" ++ name, name, "http://10.0.0.1:8123"));
    try testing.expectEqualStrings(origin, originOf(origin ++ "/updates/v1.json").?);
    try testing.expect(originOf("nothing") == null);
}
