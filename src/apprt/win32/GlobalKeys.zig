//! Global key bindings (roadmap 5.5): `global:` bindings as Windows hot
//! keys (RegisterHotKey), which act whatever program has the keyboard, as
//! GTK binds them through the desktop's global shortcuts portal. A hot key
//! runs its actions as the core runs a global binding: on every terminal
//! (performAllChainedAction). One that can't be had says so, as GTK's
//! "Global keybind unavailable" notification does.
const GlobalKeys = @This();

const std = @import("std");
const input = @import("../../input.zig");

const c = @import("c.zig");
const App = @import("App.zig");
const ContextMenu = @import("ContextMenu.zig");
const test_hooks = @import("test_hooks.zig");

const log = std.log.scoped(.win32_global_keys);

const Trigger = input.Binding.Trigger;

app: *App,
/// Nothing is registered until `start`: a launch that hands its window to
/// the running murrtty (gtk-single-instance) must not take the hot keys
/// from it, and the color scheme's soft reload refreshes before then.
active: bool = false,
/// The hot keys registered, with the keys Windows reports them by.
bound: std.ArrayList(Bound) = .empty,
/// Failures told, so each is told once until the config changes (a layout
/// change tries again quietly).
told: std.ArrayList(Trigger) = .empty,
/// Hot keys pressed while a dialog was open, run when it closes.
pending: std.ArrayList(Trigger) = .empty,
/// Bindings whose keys another murrtty on this desktop holds (a separate
/// instance): tried again every few seconds, so this one takes them when
/// that one quits.
waiting: std.ArrayList(Trigger) = .empty,

/// The wakeup window's timer for `waiting`.
pub const retry_timer = 0x5505;
const retry_ms = 3000;

pub const Bound = struct {
    trigger: Trigger,
    /// MOD_* (no MOD_NOREPEAT) and the virtual key, as WM_HOTKEY's lparam
    /// carries them.
    mods: c.UINT,
    vk: c.UINT,
};

pub fn deinit(self: *GlobalKeys) void {
    const alloc = self.app.core_app.alloc;
    self.active = false;
    self.unregister();
    self.bound.deinit(alloc);
    self.told.deinit(alloc);
    self.pending.deinit(alloc);
    self.waiting.deinit(alloc);
    self.bound = .empty;
    self.told = .empty;
    self.pending = .empty;
    self.waiting = .empty;
}

fn unregister(self: *GlobalKeys) void {
    for (self.bound.items, 1..) |_, id| _ = c.UnregisterHotKey(self.app.wakeup_hwnd, @intCast(id));
    self.bound.clearRetainingCapacity();
    self.waiting.clearRetainingCapacity();
    _ = c.KillTimer(self.app.wakeup_hwnd, retry_timer);
}

/// Register the global bindings: from App.run, once any hand-off is past.
pub fn start(self: *GlobalKeys) void {
    self.active = true;
    self.refresh(.config);
}

/// Register the config's global bindings afresh: after the config changes,
/// and when the keyboard layout does (a character's key may move). A
/// failure is told after a config change, not again after a layout change.
/// With nothing left to show hidden windows (no binding, no tray), they
/// come back.
pub fn refresh(self: *GlobalKeys, why: enum { config, layout }) void {
    if (!self.active) return;
    if (comptime test_hooks.enabled) self.app.test_state.global_refreshes += 1;
    const alloc = self.app.core_app.alloc;
    if (why == .config) self.told.clearRetainingCapacity();
    self.unregister();
    var it = self.app.config.keybind.set.bindings.iterator();
    while (it.next()) |entry| {
        const global = switch (entry.value_ptr.*) {
            .leader => false,
            inline .leaf, .leaf_chained => |leaf| leaf.flags.global,
        };
        if (global) self.register(alloc, entry.key_ptr.*);
    }
    self.syncRetry();
    if (self.app.windows_hidden and !self.app.canShowHidden()) self.app.showWindows();
}

/// Try the bindings another murrtty held again (the retry timer).
pub fn retry(self: *GlobalKeys) void {
    if (!self.active) return;
    const alloc = self.app.core_app.alloc;
    var i: usize = 0;
    while (i < self.waiting.items.len) {
        const trigger = self.waiting.items[i];
        switch (self.tryRegister(alloc, trigger)) {
            .waiting => i += 1,
            .bound => _ = self.waiting.orderedRemove(i),
            .refused => |why| {
                _ = self.waiting.orderedRemove(i);
                self.tellOnce(alloc, trigger, why);
            },
        }
    }
    self.syncRetry();
}

fn syncRetry(self: *GlobalKeys) void {
    if (self.waiting.items.len > 0) {
        _ = c.SetTimer(self.app.wakeup_hwnd, retry_timer, retry_ms, null);
    } else _ = c.KillTimer(self.app.wakeup_hwnd, retry_timer);
}

fn register(self: *GlobalKeys, alloc: std.mem.Allocator, trigger: Trigger) void {
    switch (self.tryRegister(alloc, trigger)) {
        .bound => {},
        .waiting => {
            log.info("global keybind held by another murrtty, trying again", .{});
            self.waiting.append(alloc, trigger) catch {};
        },
        .refused => |why| self.tellOnce(alloc, trigger, why),
    }
}

const Outcome = union(enum) {
    bound,
    /// Another murrtty on this desktop may hold it: not news, and tried
    /// again until that one quits.
    waiting,
    refused: []const u8,
};

fn tryRegister(self: *GlobalKeys, alloc: std.mem.Allocator, trigger: Trigger) Outcome {
    const key = keyOf(trigger) catch |err| return .{ .refused = refusal(err) };
    for (self.bound.items) |b| {
        if (b.mods == key.mods and b.vk == key.vk) return .{ .refused = "Another of murrtty's global bindings uses the same keys." };
    }
    const id: c_int = @intCast(self.bound.items.len + 1);
    if (c.RegisterHotKey(self.app.wakeup_hwnd, id, key.mods | c.MOD_NOREPEAT, key.vk) != 0) {
        self.bound.append(alloc, .{ .trigger = trigger, .mods = key.mods, .vk = key.vk }) catch {
            _ = c.UnregisterHotKey(self.app.wakeup_hwnd, id);
            return .{ .refused = "murrtty ran out of memory." };
        };
        return .bound;
    }
    if (c.GetLastError() != c.ERROR_HOTKEY_ALREADY_REGISTERED) return .{ .refused = "Windows refused it." };
    // Windows doesn't say who holds it.
    if (self.anotherMurrtty()) return .waiting;
    return .{ .refused = "Windows or another program already uses it." };
}

/// Tell a failure, unless told already since the config changed.
fn tellOnce(self: *GlobalKeys, alloc: std.mem.Allocator, trigger: Trigger, why: []const u8) void {
    for (self.told.items) |t| if (std.meta.eql(t, trigger)) return;
    self.told.append(alloc, trigger) catch {};
    self.tell(trigger, why);
}

/// Whether another murrtty runs on this desktop (its wakeup window; windows
/// are found per desktop).
fn anotherMurrtty(self: *const GlobalKeys) bool {
    var prev: ?c.HWND = null;
    while (c.FindWindowExW(c.HWND_MESSAGE, prev, c.L("MurrttyWakeup"), null)) |hwnd| {
        if (hwnd != self.app.wakeup_hwnd) return true;
        prev = hwnd;
    }
    return false;
}

/// GTK's notification for a global binding it couldn't have.
fn tell(self: *GlobalKeys, trigger: Trigger, reason: []const u8) void {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    ContextMenu.writeTrigger(&w, trigger) catch {};
    w.print(": {s}", .{reason}) catch {};
    log.warn("global keybind unavailable: {s}", .{w.buffered()});
    self.app.notifications.send(null, false, "Global keybind unavailable", w.buffered());
}

/// Whether a global binding can show windows toggle_visibility hid: one
/// whose actions include it.
pub fn canShow(self: *const GlobalKeys) bool {
    return self.binds(.toggle_visibility);
}

/// Whether a registered global binding's actions include `tag`.
pub fn binds(self: *const GlobalKeys, tag: std.meta.Tag(input.Binding.Action)) bool {
    for (self.bound.items) |b| {
        const entry = self.app.config.keybind.set.get(b.trigger) orelse continue;
        // A local: a single action's slice points into it.
        const leaf: input.Binding.Set.GenericLeaf = switch (entry.value_ptr.*) {
            .leader => continue,
            inline .leaf, .leaf_chained => |l| l.generic(),
        };
        for (leaf.actionsSlice()) |a| if (a == tag) return true;
    }
    return false;
}

/// WM_HOTKEY: the binding of the hot key with lparam's keys (not its id,
/// which a refresh since may have given another). Inside a dialog's loop
/// it waits for the dialog, as closes and palette commands do, and behind
/// any still waiting.
pub fn hotkey(self: *GlobalKeys, lparam: c.LPARAM) void {
    const bits: usize = @bitCast(lparam);
    const mods: c.UINT = @intCast(bits & 0xFFFF);
    const vk: c.UINT = @intCast((bits >> 16) & 0xFFFF);
    const trigger = for (self.bound.items) |b| {
        if (b.mods == mods and b.vk == vk) break b.trigger;
    } else return;
    if (self.app.modal_depth > 0 or self.pending.items.len > 0) {
        self.pending.append(self.app.core_app.alloc, trigger) catch {};
        if (self.app.modal_depth == 0) self.app.postRunRequests();
        return;
    }
    self.run(trigger);
}

/// Run the hot keys pressed while a dialog was open (App.resumeAfterModal
/// posts for it).
pub fn runPending(self: *GlobalKeys) void {
    while (self.app.modal_depth == 0 and self.pending.items.len > 0) {
        self.run(self.pending.orderedRemove(0));
    }
}

pub fn hasPending(self: *const GlobalKeys) bool {
    return self.pending.items.len > 0;
}

/// Run `trigger`'s binding as the config has it now. The actions are copied
/// first: one of them (reload_config) can free the config they live in.
fn run(self: *GlobalKeys, trigger: Trigger) void {
    const entry = self.app.config.keybind.set.get(trigger) orelse return;
    // A local: a single action's slice points into it.
    const leaf: input.Binding.Set.GenericLeaf = switch (entry.value_ptr.*) {
        .leader => return,
        inline .leaf, .leaf_chained => |l| l.generic(),
    };
    const actions = leaf.actionsSlice();
    var arena: std.heap.ArenaAllocator = .init(self.app.core_app.alloc);
    defer arena.deinit();
    const copy = arena.allocator().alloc(input.Binding.Action, actions.len) catch return;
    for (actions, copy) |a, *out| out.* = a.clone(arena.allocator()) catch return;
    self.app.core_app.performAllChainedAction(self.app, copy);
}

const KeyError = error{ LockModifier, NoKey, SharedKey, CatchAll };

fn refusal(err: KeyError) []const u8 {
    return switch (err) {
        error.LockModifier => "Caps Lock and Num Lock can't be part of a global binding.",
        error.NoKey => "No key on this keyboard layout makes it.",
        error.SharedKey => "Windows can't tell this key from another one.",
        error.CatchAll => "A catch-all binding can't be global.",
    };
}

/// The hot key for a binding's trigger: its modifiers and virtual key.
fn keyOf(trigger: Trigger) KeyError!struct { mods: c.UINT, vk: c.UINT } {
    // The core never matches a trigger with lock modifiers; a hot key
    // would drop them and take the bare key from every program.
    if (!std.meta.eql(trigger.mods, trigger.mods.binding())) return error.LockModifier;
    const key = try virtualKey(trigger.key);
    var mods = modifiers(trigger.mods);
    if (key.shift) mods |= c.MOD_SHIFT;
    if (key.altgr) mods |= c.MOD_CONTROL | c.MOD_ALT;
    return .{ .mods = mods, .vk = key.vk };
}

/// The hot key's modifiers for a binding's.
fn modifiers(mods: input.Mods) c.UINT {
    var out: c.UINT = 0;
    if (mods.shift) out |= c.MOD_SHIFT;
    if (mods.ctrl) out |= c.MOD_CONTROL;
    if (mods.alt) out |= c.MOD_ALT;
    if (mods.super) out |= c.MOD_WIN;
    return out;
}

const VirtualKey = struct {
    vk: c.UINT,
    /// The character takes Shift, or AltGr (Ctrl+Alt), on this layout.
    shift: bool = false,
    altgr: bool = false,
};

/// The virtual key a binding's key is on. The keypad's keys by their own
/// codes (a scan code gives the navigation key's with NumLock off, which
/// the dedicated keys share); a letter or digit by its own code on every
/// layout, as Windows' accelerators; another character where the current
/// layout types it.
fn virtualKey(key: Trigger.Key) KeyError!VirtualKey {
    switch (key) {
        .physical => |k| {
            const fixed: ?c.UINT = switch (k) {
                .numpad_0, .numpad_1, .numpad_2, .numpad_3, .numpad_4, .numpad_5, .numpad_6, .numpad_7, .numpad_8, .numpad_9 => 0x60 + @as(c.UINT, @intCast(@intFromEnum(k) - @intFromEnum(input.Key.numpad_0))),
                .numpad_multiply => 0x6A,
                .numpad_add => 0x6B,
                .numpad_separator => 0x6C,
                .numpad_subtract => 0x6D,
                .numpad_decimal => 0x6E,
                .numpad_divide => 0x6F,
                .pause => 0x13,
                .num_lock => 0x90,
                // Their codes are the main block's or the dedicated keys'.
                .numpad_enter, .numpad_up, .numpad_down, .numpad_left, .numpad_right, .numpad_home, .numpad_end, .numpad_page_up, .numpad_page_down, .numpad_insert, .numpad_delete, .numpad_begin => return error.SharedKey,
                else => null,
            };
            if (fixed) |vk| return .{ .vk = vk };
            for (input.keycodes.entries) |entry| {
                if (entry.key != k or entry.native == 0) continue;
                const vk = c.MapVirtualKeyW(entry.native, c.MAPVK_VSC_TO_VK_EX);
                return if (vk == 0) error.NoKey else .{ .vk = vk };
            }
            return error.NoKey;
        },
        .unicode => |cp| {
            if (cp < 128) {
                const ch: u8 = @intCast(cp);
                if (std.ascii.isAlphabetic(ch)) return .{ .vk = std.ascii.toUpper(ch) };
                if (std.ascii.isDigit(ch)) return .{ .vk = ch };
            }
            if (cp > 0xFFFF) return error.NoKey;
            const scan = c.VkKeyScanW(@intCast(cp));
            if (scan == -1) return error.NoKey;
            const bits: u16 = @bitCast(scan);
            const state = bits >> 8;
            return .{
                .vk = bits & 0xFF,
                .shift = state & 1 != 0,
                .altgr = state & 6 == 6,
            };
        },
        .catch_all => return error.CatchAll,
    }
}

test "modifiers" {
    const testing = std.testing;
    try testing.expectEqual(@as(c.UINT, c.MOD_CONTROL | c.MOD_ALT | c.MOD_SHIFT), modifiers(.{ .ctrl = true, .alt = true, .shift = true }));
    try testing.expectEqual(@as(c.UINT, c.MOD_WIN), modifiers(.{ .super = true }));
}

test "virtualKey" {
    const testing = std.testing;
    // Layout-free keys by their scan codes; the keypad by its own codes.
    try testing.expectEqual(@as(c.UINT, 0x7B), (try virtualKey(.{ .physical = .f12 })).vk);
    try testing.expectEqual(@as(c.UINT, 0x20), (try virtualKey(.{ .physical = .space })).vk);
    try testing.expectEqual(@as(c.UINT, 0x60), (try virtualKey(.{ .physical = .numpad_0 })).vk);
    try testing.expectEqual(@as(c.UINT, 0x67), (try virtualKey(.{ .physical = .numpad_7 })).vk);
    try testing.expectEqual(@as(c.UINT, 0x6E), (try virtualKey(.{ .physical = .numpad_decimal })).vk);
    try testing.expectError(error.SharedKey, virtualKey(.{ .physical = .numpad_enter }));
    // Letters and digits by their own codes on every layout.
    try testing.expectEqual(@as(c.UINT, 'A'), (try virtualKey(.{ .unicode = 'a' })).vk);
    try testing.expectEqual(@as(c.UINT, '1'), (try virtualKey(.{ .unicode = '1' })).vk);
    try testing.expectError(error.CatchAll, virtualKey(.catch_all));
}

test "keyOf refuses lock modifiers" {
    try std.testing.expectError(error.LockModifier, keyOf(.{ .key = .{ .unicode = 'a' }, .mods = .{ .caps_lock = true } }));
    const k = try keyOf(.{ .key = .{ .physical = .f12 }, .mods = .{ .ctrl = true, .alt = true } });
    try std.testing.expectEqual(@as(c.UINT, c.MOD_CONTROL | c.MOD_ALT), k.mods);
}
