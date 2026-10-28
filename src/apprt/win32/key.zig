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

/// A keypad key that moves rather than types. With NumLock off (or Shift
/// reversing it) Windows sends the navigation key's virtual key, VK_INSERT
/// for 0/Ins, with the keypad's scancode: report the keypad's navigation
/// key (numpad_insert), as GTK does from the keysym (KP_Insert). The
/// physical numpad_0 would type a digit.
pub fn remapKeypad(physical: input.Key, vk: c.WPARAM) input.Key {
    if (!physical.keypad()) return physical;
    return switch (vk) {
        c.VK_INSERT => .numpad_insert,
        c.VK_DELETE => .numpad_delete,
        c.VK_HOME => .numpad_home,
        c.VK_END => .numpad_end,
        c.VK_PRIOR => .numpad_page_up,
        c.VK_NEXT => .numpad_page_down,
        c.VK_UP => .numpad_up,
        c.VK_DOWN => .numpad_down,
        c.VK_LEFT => .numpad_left,
        c.VK_RIGHT => .numpad_right,
        c.VK_CLEAR => .numpad_begin,
        else => physical,
    };
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

/// The console's dwControlKeyState for a key message (`flags` is its
/// lparam's high word): Ctrl and Alt by side, Shift, the lock keys, and
/// ENHANCED_KEY for an extended key. A Ctrl or Alt down on neither side
/// (injected input) counts as the left one.
pub fn controlKeyState(flags: u16) u32 {
    var state: u32 = 0;
    const right_alt = down(c.VK_RMENU);
    const right_ctrl = down(c.VK_RCONTROL);
    if (right_alt) state |= 0x0001; // RIGHT_ALT_PRESSED
    if (down(c.VK_LMENU) or (down(c.VK_MENU) and !right_alt)) state |= 0x0002; // LEFT_ALT_PRESSED
    if (right_ctrl) state |= 0x0004; // RIGHT_CTRL_PRESSED
    if (down(c.VK_LCONTROL) or (down(c.VK_CONTROL) and !right_ctrl)) state |= 0x0008; // LEFT_CTRL_PRESSED
    if (down(c.VK_SHIFT)) state |= 0x0010; // SHIFT_PRESSED
    if (toggled(c.VK_NUMLOCK)) state |= 0x0020; // NUMLOCK_ON
    if (toggled(c.VK_SCROLL)) state |= 0x0040; // SCROLLLOCK_ON
    if (toggled(c.VK_CAPITAL)) state |= 0x0080; // CAPSLOCK_ON
    if (flags & c.KF_EXTENDED != 0) state |= 0x0100; // ENHANCED_KEY
    return state;
}

/// Whether a key's text `text` (its WM_CHARs) is AltGr's: Ctrl and Alt
/// held, on either side, and a character made. Windows reports AltGr as
/// Left Ctrl + Right Alt, and its AltGr layouts give AltGr's characters for
/// Ctrl+Alt too (German Ctrl+Alt+Q is @, as AltGr+Q), which other Windows
/// programs type either way. A layout without AltGr makes no text for
/// Ctrl+Alt, so those keys stay Ctrl+Alt+key.
pub fn altGrText(mods: input.Mods, text: []const u16) bool {
    return mods.ctrl and mods.alt and text.len > 0 and !isControl(text);
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

test "altGrText" {
    const testing = std.testing;
    const at = [_]u16{'@'};
    const ctrl_q = [_]u16{0x11};
    // German Ctrl+Alt+Q (either side) and AltGr+Q type @.
    try testing.expect(altGrText(.{ .ctrl = true, .alt = true }, &at));
    try testing.expect(altGrText(.{ .ctrl = true, .alt = true, .sides = .{ .alt = .right } }, &at));
    // No text (a US layout's Ctrl+Alt+Q), a control character, or Ctrl or
    // Alt alone: not AltGr.
    try testing.expect(!altGrText(.{ .ctrl = true, .alt = true }, &.{}));
    try testing.expect(!altGrText(.{ .ctrl = true, .alt = true }, &ctrl_q));
    try testing.expect(!altGrText(.{ .ctrl = true }, &at));
    try testing.expect(!altGrText(.{ .alt = true }, &at));
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

test "remapKeypad" {
    const testing = std.testing;
    // The numpad's 0/Ins with NumLock off: VK_INSERT, scancode 0x52.
    try testing.expectEqual(input.Key.numpad_insert, remapKeypad(physicalKey(0x52), c.VK_INSERT));
    try testing.expectEqual(input.Key.numpad_up, remapKeypad(physicalKey(0x48), c.VK_UP));
    try testing.expectEqual(input.Key.numpad_delete, remapKeypad(physicalKey(0x53), c.VK_DELETE));
    try testing.expectEqual(input.Key.numpad_begin, remapKeypad(physicalKey(0x4C), c.VK_CLEAR));
    // NumLock on: the digit stays.
    try testing.expectEqual(input.Key.numpad_0, remapKeypad(physicalKey(0x52), 0x60));
    // The dedicated Insert key and the numpad's Enter aren't touched.
    try testing.expectEqual(input.Key.insert, remapKeypad(physicalKey(0xE052), c.VK_INSERT));
    try testing.expectEqual(input.Key.numpad_enter, remapKeypad(physicalKey(0xE01C), 0x0D));
}
