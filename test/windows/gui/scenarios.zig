//! The scenarios: the README's "Tested and working" list, plus the dialog
//! rules the port depends on. Each starts its own Ghostty with its own
//! config and leaves nothing running.
const std = @import("std");
const w = @import("win.zig");
const Harness = @import("Harness.zig");

pub const Scenario = struct {
    name: []const u8,
    about: []const u8,
    run: *const fn (*Harness) anyerror!void,
};

pub const all = [_]Scenario{
    .{ .name = "launch", .about = "starts, default size, quits with confirmation", .run = launch },
    .{ .name = "pixels", .about = "renders the exact default background (#282c34), captured off-screen", .run = pixels },
    .{ .name = "typing", .about = "typed text reaches the shell; closing the last tab asks", .run = typing },
    .{ .name = "ctrl-c", .about = "Ctrl+C interrupts a running program", .run = ctrlC },
    .{ .name = "tabs", .about = "new, switch, close button, middle-click, tab bar auto-hide", .run = tabs },
    .{ .name = "clipboard", .about = "Ctrl+Shift+V, Shift+Insert, Ctrl+Shift+A/C", .run = clipboard },
    .{ .name = "alt-f4", .about = "Alt+F4 asks, then closes", .run = altF4 },
    .{ .name = "clipboard-queue", .about = "a burst of OSC 52 writes asks one dialog at a time", .run = clipboardQueue },
    .{ .name = "close-all", .about = "close-all asks and disables the other windows meanwhile", .run = closeAll },
    .{ .name = "window-size", .about = "window-width/height give the exact grid", .run = windowSize },
};

const base_config =
    \\command = cmd.exe
    \\window-show-tab-bar = auto
    \\
;

/// Launch with the base config plus `extra`, and wait for cmd's prompt.
fn start(h: *Harness, name: []const u8, extra: []const u8, prompt: []const u8) !Harness.Ghostty {
    const config = try std.mem.concat(h.alloc, u8, &.{ base_config, extra });
    defer h.alloc.free(config);
    var g = try h.launch(name, config);
    errdefer g.deinit();
    try h.waitText(&g, prompt, 1, 20000);
    return g;
}

/// Ctrl+Shift+Q, answer the confirmation with Yes, and expect exit code 0.
fn quit(h: *Harness, g: *Harness.Ghostty, target: w.HWND) !void {
    h.key(target, .{ .ctrl = true, .shift = true }, 'Q');
    const dlg = try h.waitDialog(g, 5000);
    h.answer(g, dlg, w.IDYES);
    const code = g.waitExit(10000);
    try h.expect(code != null and code.? == 0, "exits with code 0 after quit (got {?d})", .{code});
}

fn launch(h: *Harness) anyerror!void {
    var g = try start(h, "launch", "", ">");
    defer g.deinit();
    const win = try h.mainWindow(&g);
    const surf = try h.surface(&g, win);

    {
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(d.value.windows.len == 1, "one window", .{});
        const t = d.value.windows[0].tabs;
        try h.expect(t.len == 1, "one tab", .{});
        try h.expect((t[0].cols orelse 0) > 0 and (t[0].rows orelse 0) > 0, "grid {?d}x{?d}", .{ t[0].cols, t[0].rows });
        try h.expect(!d.value.windows[0].tab_bar.visible, "tab bar hidden with one tab", .{});
    }

    // The default client size is 960x600 DIPs at the window's DPI.
    const dpi = w.GetDpiForWindow(win);
    var r: w.RECT = .{};
    _ = w.GetClientRect(win, &r);
    const ew = (960 * dpi + 95) / 96;
    const eh = (600 * dpi + 95) / 96;
    try h.expect(r.right == ew and r.bottom == eh, "client {d}x{d} at dpi {d}, expected {d}x{d}", .{ r.right, r.bottom, dpi, ew, eh });

    try quit(h, &g, surf);
}

/// Captures need a composed window, which a hidden desktop doesn't get, so
/// this Ghostty runs on the user's desktop far off-screen, driven from a
/// thread on that desktop, and is terminated rather than closed through a
/// dialog that would appear on screen.
fn pixels(h: *Harness) anyerror!void {
    const Ctx = struct { h: *Harness, err: ?anyerror = null };
    var ctx: Ctx = .{ .h = h };
    h.runOnUserDesktop(&ctx, struct {
        fn run(c: *Ctx) void {
            pixelsOffscreen(c.h) catch |err| {
                c.err = err;
            };
        }
    }.run);
    if (ctx.err) |err| return err;
}

fn pixelsOffscreen(h: *Harness) !void {
    var g = try h.launchAt("pixels", base_config, .offscreen);
    defer g.deinit();
    try h.waitText(&g, ">", 1, 20000);
    const win = try h.mainWindow(&g);
    var r: w.RECT = .{};
    _ = w.GetWindowRect(win, &r);
    try h.expect(r.left < -10000, "the window is off-screen (left {d})", .{r.left});

    // The default theme's background, exactly (the sRGB present invariant).
    const surf = try h.surface(&g, win);
    var img = h.capture(surf) catch return h.fail("capture failed", .{});
    defer img.deinit();
    const px = img.rgb(img.width - 6, img.height - 6);
    try h.expect(px == 0x282c34, "background pixel #{x:0>6}, expected #282c34", .{px});
}

fn typing(h: *Harness) anyerror!void {
    var g = try start(h, "typing", "", ">");
    defer g.deinit();
    const surf = try h.surface(&g, try h.mainWindow(&g));
    try h.typeText(surf, "echo ghostty-gui-test");
    h.enter(surf);
    // The command line and its output.
    try h.waitText(&g, "ghostty-gui-test", 2, 10000);

    // Ctrl+Shift+W closes the tab; the shell is running, so it asks first.
    h.key(surf, .{ .ctrl = true, .shift = true }, 'W');
    const dlg = try h.waitDialog(&g, 5000);
    h.answer(&g, dlg, w.IDNO);
    w.Sleep(500);
    try h.expect(g.exitCode() == null, "No keeps the tab", .{});
    h.key(surf, .{ .ctrl = true, .shift = true }, 'W');
    h.answer(&g, try h.waitDialog(&g, 5000), w.IDYES);
    const code = g.waitExit(10000);
    try h.expect(code != null and code.? == 0, "closing the last tab exits with code 0 (got {?d})", .{code});
}

fn ctrlC(h: *Harness) anyerror!void {
    var g = try start(h, "ctrl-c", "", ">");
    defer g.deinit();
    const surf = try h.surface(&g, try h.mainWindow(&g));
    try h.typeText(surf, "ping -n 60 127.0.0.1");
    h.enter(surf);
    try h.waitText(&g, "Reply from 127.0.0.1", 1, 10000);
    h.key(surf, .{ .ctrl = true }, 'C');
    try h.waitText(&g, "Control-C", 1, 10000);
    try quit(h, &g, surf);
}

fn tabCount(h: *Harness, g: *Harness.Ghostty) !usize {
    var d = try h.dump(g);
    defer d.deinit();
    return d.value.windows[0].tabs.len;
}

fn tabs(h: *Harness) anyerror!void {
    var g = try start(h, "tabs", "", ">");
    defer g.deinit();
    const win = try h.mainWindow(&g);
    var surf = try h.surface(&g, win);

    h.key(surf, .{ .ctrl = true, .shift = true }, 'T');
    w.Sleep(1500);
    surf = try h.surface(&g, win);
    h.key(surf, .{ .ctrl = true, .shift = true }, 'T');
    w.Sleep(1500);
    {
        var d = try h.dump(&g);
        defer d.deinit();
        const dw = d.value.windows[0];
        try h.expect(dw.tabs.len == 3, "three tabs (got {d})", .{dw.tabs.len});
        try h.expect(dw.active == 2, "the new tab is active (got {d})", .{dw.active});
        try h.expect(dw.tab_bar.visible, "tab bar shown with three tabs", .{});
    }

    surf = try h.surface(&g, win);
    h.key(surf, .{ .ctrl = true }, w.VK_TAB);
    w.Sleep(500);
    {
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(d.value.windows[0].active == 0, "Ctrl+Tab wraps to the first tab (got {d})", .{d.value.windows[0].active});
    }
    surf = try h.surface(&g, win);
    h.key(surf, .{ .ctrl = true }, w.VK_PRIOR);
    w.Sleep(500);
    {
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(d.value.windows[0].active == 2, "Ctrl+PgUp wraps to the last tab (got {d})", .{d.value.windows[0].active});
    }

    // Close the middle tab with its close button: No keeps it, Yes closes.
    const close = close: {
        var d = try h.dump(&g);
        defer d.deinit();
        break :close d.value.windows[0].tab_bar.tabs[1].close;
    };
    const cx = @divTrunc(close[0] + close[2], 2);
    const cy = @divTrunc(close[1] + close[3], 2);
    h.click(win, cx, cy, .left);
    h.answer(&g, try h.waitDialog(&g, 5000), w.IDNO);
    w.Sleep(500);
    try h.expect(try tabCount(h, &g) == 3, "No keeps the tab", .{});
    h.click(win, cx, cy, .left);
    h.answer(&g, try h.waitDialog(&g, 5000), w.IDYES);
    w.Sleep(800);
    try h.expect(try tabCount(h, &g) == 2, "the close button closes the tab", .{});

    // Middle-click the first tab.
    const first = first: {
        var d = try h.dump(&g);
        defer d.deinit();
        break :first d.value.windows[0].tab_bar.tabs[0].rect;
    };
    h.click(win, first[0] + 20, @divTrunc(first[1] + first[3], 2), .middle);
    h.answer(&g, try h.waitDialog(&g, 5000), w.IDYES);
    w.Sleep(800);
    {
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(d.value.windows[0].tabs.len == 1, "middle-click closes the tab", .{});
        try h.expect(!d.value.windows[0].tab_bar.visible, "tab bar hides again with one tab", .{});
    }
    try quit(h, &g, try h.surface(&g, win));
}

fn clipboard(h: *Harness) anyerror!void {
    const saved = h.getClipboard() catch null;
    defer if (saved) |s| {
        h.setClipboard(s) catch {};
        h.alloc.free(s);
    };

    try h.setClipboard("gui-paste-one");
    var g = try start(h, "clipboard", "", ">");
    defer g.deinit();
    const surf = try h.surface(&g, try h.mainWindow(&g));

    h.key(surf, .{ .ctrl = true, .shift = true }, 'V');
    try h.waitText(&g, "gui-paste-one", 1, 5000);

    try h.setClipboard("gui-paste-two");
    h.key(surf, .{ .shift = true }, w.VK_INSERT);
    try h.waitText(&g, "gui-paste-two", 1, 5000);

    try h.setClipboard("");
    h.key(surf, .{ .ctrl = true, .shift = true }, 'A');
    h.key(surf, .{ .ctrl = true, .shift = true }, 'C');
    w.Sleep(500);
    const copied = (try h.getClipboard()) orelse "";
    defer if (copied.len > 0) h.alloc.free(copied);
    try h.expect(std.mem.indexOf(u8, copied, "gui-paste-two") != null, "Ctrl+Shift+A then C copies the screen", .{});

    try quit(h, &g, surf);
}

fn altF4(h: *Harness) anyerror!void {
    var g = try start(h, "alt-f4", "", ">");
    defer g.deinit();
    const surf = try h.surface(&g, try h.mainWindow(&g));
    h.key(surf, .{ .alt = true }, w.VK_F4);
    const dlg = try h.waitDialog(&g, 5000);
    const t = try h.title(dlg);
    defer h.alloc.free(t);
    try h.expect(std.mem.indexOf(u8, t, "Close Window") != null, "Alt+F4 asks to close the window ('{s}')", .{t});
    h.answer(&g, dlg, w.IDYES);
    const code = g.waitExit(10000);
    try h.expect(code != null and code.? == 0, "exits with code 0 (got {?d})", .{code});
}

fn clipboardQueue(h: *Harness) anyerror!void {
    const saved = h.getClipboard() catch null;
    defer if (saved) |s| {
        h.setClipboard(s) catch {};
        h.alloc.free(s);
    };
    try h.setClipboard("before");

    var g = try start(h, "clipboard-queue",
        \\command = powershell.exe -NoLogo -NoProfile
        \\clipboard-write = ask
        \\
    , "PS ");
    defer g.deinit();
    const surf = try h.surface(&g, try h.mainWindow(&g));
    // Two OSC 52 writes ("one", then "two") in one burst.
    try h.typeText(surf, "Write-Host -NoNewline \"$([char]27)]52;c;b25l$([char]7)$([char]27)]52;c;dHdv$([char]7)\"");
    h.enter(surf);

    const first = try h.waitDialog(&g, 10000);
    try h.expect(try h.dialogCount(&g) == 1, "one dialog at a time", .{});
    h.answer(&g, first, w.IDYES);
    w.Sleep(800);
    const second = try h.waitDialog(&g, 5000);
    try h.expect(second != first, "the second request asks after the first is answered", .{});
    const after_first = (try h.getClipboard()) orelse "";
    defer if (after_first.len > 0) h.alloc.free(after_first);
    try h.expect(std.mem.eql(u8, after_first, "one"), "Yes wrote 'one' (got '{s}')", .{after_first});
    h.answer(&g, second, w.IDNO);
    w.Sleep(800);
    try h.expect(try h.dialogCount(&g) == 0, "no dialogs left", .{});
    const final = (try h.getClipboard()) orelse "";
    defer if (final.len > 0) h.alloc.free(final);
    try h.expect(std.mem.eql(u8, final, "one"), "No left the clipboard alone (got '{s}')", .{final});

    try quit(h, &g, surf);
}

fn closeAll(h: *Harness) anyerror!void {
    var g = try start(h, "close-all", "keybind = ctrl+shift+k=close_all_windows\n", ">");
    defer g.deinit();
    const first = try h.mainWindow(&g);
    const surf = try h.surface(&g, first);
    h.key(surf, .{ .ctrl = true, .shift = true }, 'N');
    w.Sleep(2500);
    const wins = try h.windows(&g, "GhosttyWindow");
    defer h.alloc.free(wins);
    try h.expect(wins.len == 2, "Ctrl+Shift+N opens a second window (got {d})", .{wins.len});

    h.key(try h.surface(&g, first), .{ .ctrl = true, .shift = true }, 'K');
    const dlg = try h.waitDialog(&g, 5000);
    for (wins) |win| try h.expect(w.IsWindowEnabled(win) == 0, "every window is disabled while the dialog is open", .{});
    h.answer(&g, dlg, w.IDNO);
    w.Sleep(800);
    for (wins) |win| try h.expect(w.IsWindowEnabled(win) != 0, "No re-enables every window", .{});
    const still = try h.windows(&g, "GhosttyWindow");
    defer h.alloc.free(still);
    try h.expect(still.len == 2, "No keeps both windows", .{});

    h.key(try h.surface(&g, first), .{ .ctrl = true, .shift = true }, 'K');
    h.answer(&g, try h.waitDialog(&g, 5000), w.IDYES);
    const code = g.waitExit(10000);
    try h.expect(code != null and code.? == 0, "Yes closes everything, exit code 0 (got {?d})", .{code});
}

fn windowSize(h: *Harness) anyerror!void {
    var g = try start(h, "window-size", "window-width = 86\nwindow-height = 22\n", ">");
    defer g.deinit();
    var d = try h.dump(&g);
    defer d.deinit();
    const t = d.value.windows[0].tabs[0];
    try h.expect(t.cols == 86 and t.rows == 22, "grid {?d}x{?d}, expected 86x22", .{ t.cols, t.rows });
    try quit(h, &g, try h.surface(&g, try h.mainWindow(&g)));
}
