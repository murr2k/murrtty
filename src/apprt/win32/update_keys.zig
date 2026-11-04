//! The update-signing public keys (roadmap 7.6b): a download is used only
//! if one of them signed its release's SHA256SUMS.txt.
//!
//! The release job signs SHA256SUMS.txt with `murrtty-update`'s private
//! half, the `release` environment's UPDATE_SIGNING_KEY secret, which only
//! murrtty-v* tags reach: a plain Ed25519 signature (RFC 8032), as
//! `openssl pkeyutl -sign -rawin` makes it, published beside it as
//! SHA256SUMS.txt.sig (64 bytes). `murrtty-update-spare`'s private half is
//! kept offline by the owner, to replace the first if it is lost or leaks:
//! copies carrying both keys still take a release signed by the spare.
//!
//! The keys are the PEM files beside this one (the release job checks each
//! signature against the same file before uploading it), read here at
//! compile time.

const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;

pub const keys = [_][32]u8{
    fromPem(@embedFile("update_keys/murrtty-update.pub")),
    fromPem(@embedFile("update_keys/murrtty-update-spare.pub")),
};

/// Whether one of murrtty's keys signed `message` (a release's
/// SHA256SUMS.txt, as downloaded) with `signature` (its SHA256SUMS.txt.sig).
pub fn verify(message: []const u8, signature: []const u8) bool {
    return verifyWith(&keys, message, signature);
}

/// `verify` with other keys (the GUI tests' own, under the test hooks).
pub fn verifyWith(public_keys: []const [32]u8, message: []const u8, signature: []const u8) bool {
    if (signature.len != Ed25519.Signature.encoded_length) return false;
    const sig = Ed25519.Signature.fromBytes(signature[0..Ed25519.Signature.encoded_length].*);
    for (public_keys) |k| {
        const pk = Ed25519.PublicKey.fromBytes(k) catch continue;
        sig.verify(message, pk) catch continue;
        return true;
    }
    return false;
}

/// An Ed25519 public key's 32 bytes from its PEM (SubjectPublicKeyInfo),
/// as `openssl pkey -pubout` writes it.
fn fromPem(comptime pem: []const u8) [32]u8 {
    comptime {
        @setEvalBranchQuota(20_000);
        const begin = "-----BEGIN PUBLIC KEY-----";
        const end = "-----END PUBLIC KEY-----";
        const b = std.mem.indexOf(u8, pem, begin) orelse @compileError("not a public key PEM");
        const e = std.mem.indexOf(u8, pem, end) orelse @compileError("not a public key PEM");
        const body = std.mem.trim(u8, pem[b + begin.len .. e], " \t\r\n");
        const dec = std.base64.standard.Decoder;
        const size = dec.calcSizeForSlice(body) catch @compileError("the PEM's base64 is bad");
        if (size != 44) @compileError("not an Ed25519 public key (wrong length)");
        var der: [44]u8 = undefined;
        dec.decode(&der, body) catch @compileError("the PEM's base64 is bad");
        // SEQUENCE { SEQUENCE { OID 1.3.101.112 (Ed25519) }, BIT STRING (32 bytes) }
        const prefix = [_]u8{ 0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00 };
        if (!std.mem.eql(u8, der[0..prefix.len], &prefix)) @compileError("not an Ed25519 public key");
        return der[prefix.len..].*;
    }
}

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

test "update keys: the PEM files read as the owner's two keys" {
    const testing = std.testing;
    try testing.expectEqualSlices(u8, &hex("c3597a3f54ef9a19bf6cbd4fe097dee27f9cd8ecb34b7ae417cf62bf94f7ea77"), &keys[0]);
    try testing.expectEqualSlices(u8, &hex("a1034f2429f43e344c208abb97e3b4a06da9b16a66bd45712eb806b6b9310e6a"), &keys[1]);
}

test "update keys: OpenSSL's signatures verify" {
    // Made by a throwaway key with OpenSSL 3.5.5 (genpkey -algorithm
    // ed25519; pkeyutl -sign -rawin), as the release job signs.
    const testing = std.testing;
    const pk = hex("b64c6baeda67a2d8ddc092868fa43a4d748b54c4424d3fca9dadabebbf49fbf9");
    const message = "0123abcd  murrtty-0.6.0-windows-x86_64.zip\n";
    const sig = hex("4460cb088d4cbee225415736468ba82debe1d6aeac336b84b83d30a1f329b5e30b640b0a363603f787909b767a5cab3b9e70a906eda0f2d6f7cbb922934b8509");
    try testing.expect(verifyWith(&.{pk}, message, &sig));
    // Any other key in the list may be the one: the spare's place.
    try testing.expect(verifyWith(&.{ keys[0], pk }, message, &sig));
    // A changed byte, a cut signature, another key: refused.
    try testing.expect(!verifyWith(&.{pk}, "0123abce  murrtty-0.6.0-windows-x86_64.zip\n", &sig));
    try testing.expect(!verifyWith(&.{pk}, message, sig[0..63]));
    var bad = sig;
    bad[10] ^= 1;
    try testing.expect(!verifyWith(&.{pk}, message, &bad));
    try testing.expect(!verify(message, &sig));
}
