//! Keyboard translation from Win32 key messages to Ghostty input.
const std = @import("std");
const input = @import("../../input.zig");
const c = @import("c.zig");

/// The native keycode for a key message: the scancode, with the
/// 0xE000 prefix for extended keys. This matches the "win" column of
/// `input.keycodes`.
pub fn nativeKeycode(vk: c.WPARAM, lparam: c.LPARAM) u32 {
    const flags = c.hiword(lparam);
    var scancode: u32 = flags & 0xFF;

    // Some synthesized and multimedia keys arrive without a scancode.
    if (scancode == 0) scancode = c.MapVirtualKeyW(@intCast(vk & 0xFF), c.MAPVK_VK_TO_VSC_EX);
    if (scancode > 0xFF) return scancode; // MapVirtualKeyW already prefixed it.

    if (flags & c.KF_EXTENDED != 0) scancode |= 0xE000;
    return scancode;
}

/// The physical (W3C) key for a native keycode.
pub fn physicalKey(native: u32) input.Key {
    for (input.keycodes.entries) |entry| {
        if (entry.native == native) return entry.key;
    }
    return .unidentified;
}

fn down(vk: c_int) bool {
    return c.GetKeyState(vk) < 0;
}

fn toggled(vk: c_int) bool {
    return c.GetKeyState(vk) & 1 != 0;
}

/// The current modifier state from the message queue's key state.
pub fn currentMods() input.Mods {
    var mods: input.Mods = .{
        .shift = down(c.VK_SHIFT),
        .ctrl = down(c.VK_CONTROL),
        .alt = down(c.VK_MENU),
        .super = down(c.VK_LWIN) or down(c.VK_RWIN),
        .caps_lock = toggled(c.VK_CAPITAL),
        .num_lock = toggled(c.VK_NUMLOCK),
    };
    if (down(c.VK_RSHIFT) and !down(c.VK_LSHIFT)) mods.sides.shift = .right;
    if (down(c.VK_RCONTROL) and !down(c.VK_LCONTROL)) mods.sides.ctrl = .right;
    if (down(c.VK_RMENU) and !down(c.VK_LMENU)) mods.sides.alt = .right;
    if (down(c.VK_RWIN) and !down(c.VK_LWIN)) mods.sides.super = .right;
    return mods;
}

/// True if Right Alt is down together with Left Ctrl. Windows reports
/// AltGr as this combination, which we treat as a character modifier
/// rather than Ctrl+Alt when it produces text.
pub fn altGrDown() bool {
    return down(c.VK_RMENU) and down(c.VK_LCONTROL);
}

/// Translate a virtual key with a given keyboard state into UTF-16
/// without touching the keyboard's dead key state. Returns the number of
/// code units written, or 0 if the key produces no text (including dead
/// keys).
pub fn toUnicode(vk: c.WPARAM, scancode: u32, state: *const [256]u8, buf: []u16) usize {
    // Flag 0x4: do not change keyboard state (Windows 10 1607+).
    const n = c.ToUnicode(
        @intCast(vk & 0xFF),
        scancode & 0xFF,
        state,
        buf.ptr,
        @intCast(buf.len),
        0x4,
    );
    return if (n > 0) @intCast(n) else 0;
}

/// The codepoint this key produces with no modifiers held, lowercased.
pub fn unshiftedCodepoint(vk: c.WPARAM, scancode: u32) u21 {
    const empty: [256]u8 = @splat(0);
    var buf: [4]u16 = undefined;
    const n = toUnicode(vk, scancode, &empty, &buf);
    if (n == 0) return 0;
    const cp = firstCodepoint(buf[0..n]) orelse return 0;
    if (cp < 0x20 or cp == 0x7F) return 0;
    if (cp < 0x80) return std.ascii.toLower(@intCast(cp));
    return cp;
}

/// The text this key would produce with Ctrl and Alt released (but
/// Shift and the lock keys as they are). Ghostty's encoder applies Ctrl
/// and Alt itself, so like the GTK apprt we report e.g. "c" for Ctrl+C.
pub fn textWithoutCtrlAlt(vk: c.WPARAM, scancode: u32, buf: []u16) usize {
    var state: [256]u8 = undefined;
    if (c.GetKeyboardState(&state) == 0) return 0;
    for ([_]u8{ c.VK_CONTROL, c.VK_LCONTROL, c.VK_RCONTROL, c.VK_MENU, c.VK_LMENU, c.VK_RMENU }) |k| {
        state[k] = 0;
    }
    return toUnicode(vk, scancode, &state, buf);
}

/// The first codepoint of a UTF-16 string, if valid.
pub fn firstCodepoint(utf16: []const u16) ?u21 {
    var it = std.unicode.Utf16LeIterator.init(utf16);
    return (it.nextCodepoint() catch return null);
}

/// True if the UTF-16 text is a single control character, which we
/// don't report as text: the encoder produces control sequences from
/// the key and modifiers.
pub fn isControl(utf16: []const u16) bool {
    return utf16.len == 1 and (utf16[0] < 0x20 or utf16[0] == 0x7F);
}

test "nativeKeycode" {
    const testing = std.testing;
    // 'A': scancode 0x1E, not extended
    try testing.expectEqual(@as(u32, 0x1E), nativeKeycode(0x41, 0x001E0001));
    // Numpad Enter: scancode 0x1C, extended
    try testing.expectEqual(@as(u32, 0xE01C), nativeKeycode(0x0D, 0x011C0001));
}

test "physicalKey" {
    const testing = std.testing;
    try testing.expectEqual(input.Key.key_a, physicalKey(0x1E));
    try testing.expectEqual(input.Key.enter, physicalKey(0x1C));
    try testing.expectEqual(input.Key.numpad_enter, physicalKey(0xE01C));
}
