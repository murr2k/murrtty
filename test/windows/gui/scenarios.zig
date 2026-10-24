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
    .{ .name = "links", .about = "Ctrl+click links: programs and UNC paths blocked, web opens, other schemes ask", .run = links },
    .{ .name = "links-open", .about = "links really open: a test protocol and file type registered in HKCU", .run = linksOpen },
    .{ .name = "present", .about = "background-opacity doesn't darken the (opaque) window; exact background pixels", .run = present },
    .{ .name = "theme", .about = "window-theme: caption colors, OSC 11 following, and the color scheme reaching terminals", .run = theme },
    .{ .name = "resize", .about = "resizing relays out the terminal, and the edge stays the background color", .run = resize },
    .{ .name = "config-errors", .about = "config errors show a dialog; Open Configuration, fix, Reload; Ctrl+, opens the file", .run = configErrors },
    .{ .name = "launch-context", .about = "from a shell: the shell's directory; from a shortcut: home; a POSIX SHELL is ignored", .run = launchContext },
};

/// Home as the working directory: the harness's launches count as from a
/// shell (see launch-context), which would start each terminal in its long
/// scenario folder, and text typed after that prompt wraps.
const base_config =
    \\command = cmd.exe
    \\window-show-tab-bar = auto
    \\working-directory = home
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
    if (!h.userDesktopShown()) {
        return h.skip("the desktop isn't being drawn (screen saver or lock screen is up)", .{});
    }
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
    var saved = try h.saveClipboard();
    defer saved.restore();

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
    var saved = try h.saveClipboard();
    defer saved.restore();
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

/// Button ids of the link dialogs (src/apprt/win32/App.zig): Open Link or
/// Open File, and Copy Link.
const id_open_link = 100;
const id_copy_link = 101;

/// Clears the screen, then prints one OSC 8 link per line, each labelled
/// LNK-<name>, then a plain-text URL and an end marker. The labels are
/// built at run time so only the output contains them.
const links_command =
    "cls;$e=[char]27;$t=\"$e\\\";" ++
    "function Lnk($u,$n){Write-Host \"$e]8;;$u${t}LNK-$n$e]8;;$t\"};" ++
    "Lnk file:///C:/Windows/System32/calc.exe CALC;" ++
    "Lnk file://attacker.invalid/share/x.txt UNC;" ++
    "Lnk https://example.com/ghostty-gui-test WEB;" ++
    "Lnk ghostty-gui-test:hello APP;" ++
    "Lnk 'ghostty-gui-test:a\"b c' QUOTE;" ++
    "Lnk file:///C:/Windows DIR;" ++
    "Lnk file:///C:/Windows/win.ini INI;" ++
    "Lnk file:///C:/Windows/System32/drivers/etc/hosts HOSTS;" ++
    "Write-Host ('LNK-'+'TXT https://example.org/plain');" ++
    "Write-Host ('LNK-'+'NUL ./nul');" ++
    "Write-Host ('LNK-'+'LONG ./'+('a'*300)+'.txt');" ++
    "Write-Host ('LNK-'+'END')";

/// Ctrl+click the cell `col` of the row that starts with `label`.
fn ctrlClickRow(h: *Harness, g: *Harness.Ghostty, surf: w.HWND, label: []const u8, col: u32) !void {
    var d = try h.dump(g);
    defer d.deinit();
    const t = d.value.windows[0].tabs[d.value.windows[0].active];
    const cell = t.cell orelse return h.fail("no cell size in the dump", .{});
    const pad = t.padding orelse return h.fail("no padding in the dump", .{});
    var row: u32 = 0;
    var lines = std.mem.splitScalar(u8, t.text orelse "", '\n');
    while (lines.next()) |line| : (row += 1) {
        if (std.mem.startsWith(u8, line, label)) break;
    } else return h.fail("no row starts with {s}", .{label});
    const x: c_int = @intCast(pad[0] + col * cell[0] + cell[0] / 2);
    const y: c_int = @intCast(pad[1] + row * cell[1] + cell[1] / 2);
    h.log("ctrl+click {s} at row {d} col {d} ({d},{d})", .{ label, row, col, x, y });
    h.clickMods(surf, x, y, .left, .{ .ctrl = true });
}

fn waitNoDialog(h: *Harness, g: *Harness.Ghostty) !void {
    var waited: u32 = 0;
    while (waited <= 5000) : (waited += 100) {
        if (try h.dialogCount(g) == 0) return;
        w.Sleep(100);
    }
    return h.fail("the dialog did not close", .{});
}

/// Wait for `n` recorded launches and check the last one.
fn expectLaunch(h: *Harness, g: *Harness.Ghostty, n: usize, expected: []const u8) !void {
    var waited: u32 = 0;
    while (waited <= 5000) : (waited += 200) {
        var d = try h.dump(g);
        defer d.deinit();
        const l = d.value.launches;
        if (l.len >= n) {
            try h.expect(l.len == n, "{d} launch(es), got {d}", .{ n, l.len });
            try h.expect(std.ascii.eqlIgnoreCase(l[n - 1], expected), "opens '{s}' (got '{s}')", .{ expected, l[n - 1] });
            return;
        }
        w.Sleep(200);
    }
    return h.fail("nothing opened; expected '{s}'", .{expected});
}

fn expectLaunchCount(h: *Harness, g: *Harness.Ghostty, n: usize) !void {
    var d = try h.dump(g);
    defer d.deinit();
    try h.expect(d.value.launches.len == n, "still {d} launch(es) (got {d})", .{ n, d.value.launches.len });
}

fn expectTitle(h: *Harness, dlg: w.HWND, expected: []const u8) !void {
    const t = try h.title(dlg);
    defer h.alloc.free(t);
    try h.expect(std.mem.indexOf(u8, t, expected) != null, "dialog '{s}' (expected '{s}')", .{ t, expected });
}

/// Ctrl+click the row labelled `label`, expect a dialog titled `title`,
/// answer it with `id`, and wait for it to close.
fn clickAndAnswer(h: *Harness, g: *Harness.Ghostty, surf: w.HWND, label: []const u8, title: []const u8, id: c_int) !void {
    try ctrlClickRow(h, g, surf, label, 2);
    const dlg = try h.waitDialog(g, 5000);
    try expectTitle(h, dlg, title);
    h.answer(g, dlg, id);
    try waitNoDialog(h, g);
}

/// Links from terminal output go through the runtime's policy (url.zig).
/// The Debug build records what would open instead of opening it, so no
/// browser or Explorer window appears.
fn links(h: *Harness) anyerror!void {
    var saved = try h.saveClipboard();
    defer saved.restore();

    var g = try start(h, "links", "command = powershell.exe -NoLogo -NoProfile\n", "PS ");
    defer g.deinit();
    const surf = try h.surface(&g, try h.mainWindow(&g));
    try h.typeText(surf, links_command);
    h.enter(surf);
    try h.waitText(&g, "LNK-END", 1, 15000);

    // A program is blocked, and Copy Link copies its path. Ghostty writes
    // the clipboard after the dialog closes, so wait for the write before
    // reading.
    try h.setClipboard("");
    const before = h.clipboardSequence();
    try clickAndAnswer(h, &g, surf, "LNK-CALC", "Link Blocked", id_copy_link);
    var waited: u32 = 0;
    while (h.clipboardSequence() == before and waited < 5000) : (waited += 50) w.Sleep(50);
    const copied = (try h.getClipboard()) orelse "";
    defer if (copied.len > 0) h.alloc.free(copied);
    try h.expect(std.ascii.findIgnoreCase(copied, "\\System32\\calc.exe") != null, "Copy Link copied the path (got '{s}')", .{copied});

    // A UNC path is blocked without touching the network.
    try clickAndAnswer(h, &g, surf, "LNK-UNC", "Link Blocked", w.IDOK);

    // https opens without asking.
    try ctrlClickRow(h, &g, surf, "LNK-WEB", 2);
    try expectLaunch(h, &g, 1, "default https://example.com/ghostty-gui-test");
    try h.expect(try h.dialogCount(&g) == 0, "no dialog for https", .{});

    // Another scheme asks: Cancel opens nothing, Open Link opens it.
    try clickAndAnswer(h, &g, surf, "LNK-APP", "Open Link", w.IDCANCEL);
    try expectLaunchCount(h, &g, 1);
    try clickAndAnswer(h, &g, surf, "LNK-APP", "Open Link", id_open_link);
    try expectLaunch(h, &g, 2, "default ghostty-gui-test:hello");

    // A quote and a space reach the handler encoded, so they can't add
    // arguments to its command line.
    try clickAndAnswer(h, &g, surf, "LNK-QUOTE", "Open Link", id_open_link);
    try expectLaunch(h, &g, 3, "default ghostty-gui-test:a%22b%20c");

    // A directory opens with its default verb (the user's file manager).
    try ctrlClickRow(h, &g, surf, "LNK-DIR", 2);
    try expectLaunch(h, &g, 4, "default C:\\Windows");

    // A text file opens without asking; a file of no known type asks.
    try ctrlClickRow(h, &g, surf, "LNK-INI", 2);
    try expectLaunch(h, &g, 5, "default C:\\Windows\\win.ini");
    try clickAndAnswer(h, &g, surf, "LNK-HOSTS", "Open Link", w.IDCANCEL);
    try expectLaunchCount(h, &g, 5);

    // A plain-text URL matched by link-url (an "unknown" link).
    try ctrlClickRow(h, &g, surf, "LNK-TXT", 12);
    try expectLaunch(h, &g, 6, "default https://example.org/plain");

    // Relative paths a file system call would choke on: a device name, and
    // a name longer than NTFS allows (spanning several rows). Both used to
    // crash Debug builds inside the standard library.
    try ctrlClickRow(h, &g, surf, "LNK-NUL", 9);
    var dlg = try h.waitDialog(&g, 5000);
    try expectTitle(h, dlg, "Link Blocked");
    h.answer(&g, dlg, w.IDOK);
    try waitNoDialog(h, &g);
    try ctrlClickRow(h, &g, surf, "LNK-LONG", 12);
    dlg = try h.waitDialog(&g, 5000);
    try expectTitle(h, dlg, "Link Blocked");
    h.answer(&g, dlg, w.IDOK);
    try waitNoDialog(h, &g);
    try expectLaunchCount(h, &g, 6);

    {
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(d.value.modal_depth == 0, "no dialog left open", .{});
    }
    try quit(h, &g, surf);
}

/// Wait until the file at `path` exists and contains `needle` (any case).
fn waitFileText(h: *Harness, path: []const u8, needle: []const u8) !void {
    var waited: u32 = 0;
    while (waited <= 10000) : (waited += 200) {
        if (h.readFileOrNull(path)) |data| {
            defer h.alloc.free(data);
            if (std.ascii.findIgnoreCase(data, needle) != null) return h.expect(true, "{s} was opened", .{needle});
        }
        w.Sleep(200);
    }
    return h.fail("nothing opened {s}", .{needle});
}

/// The registry entries links-open makes, and the ones the shell adds
/// itself once it has used them.
const link_test_keys = [_][]const u8{
    "Software\\Classes\\ghostty-gui-test",
    "Software\\Classes\\.ghosttyguitest",
    "Software\\Classes\\GhosttyGuiTest.File",
    "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FileExts\\.ghosttyguitest",
};
const association_toasts = "Software\\Microsoft\\Windows\\CurrentVersion\\ApplicationAssociationToasts";

fn removeLinkTestRegistry(h: *Harness) void {
    for (link_test_keys) |k| h.deleteRegTree(k);
    h.deleteRegValue(association_toasts, "ghostty-gui-test_ghostty-gui-test");
    h.deleteRegValue(association_toasts, "GhosttyGuiTest.File_.ghosttyguitest");
    w.SHChangeNotify(w.SHCNE_ASSOCCHANGED, 0, null, null);
}

/// The other link scenario records what would open; this one opens links
/// for real, through ShellExecuteExW, with handlers of its own: a protocol
/// and a file type registered under HKCU for the test's duration. Both run
/// ghostty-gui-record (record.zig), a windowless program that writes what
/// it was given to a marker file, so nothing appears on screen and the
/// argument is never parsed by a shell.
fn linksOpen(h: *Harness) anyerror!void {
    const alloc = h.alloc;
    const recorder = try h.helperPath("ghostty-gui-record.exe");
    defer alloc.free(recorder);
    const protocol_marker = try std.fmt.allocPrint(alloc, "{s}\\protocol-opened.txt", .{h.temp_dir});
    defer alloc.free(protocol_marker);
    const file_marker = try std.fmt.allocPrint(alloc, "{s}\\file-opened.txt", .{h.temp_dir});
    defer alloc.free(file_marker);
    const sample = try std.fmt.allocPrint(alloc, "{s}\\sample.ghosttyguitest", .{h.temp_dir});
    defer alloc.free(sample);

    const files = [_][]const u8{ protocol_marker, file_marker, sample };
    for (files) |f| h.deleteFile(f);
    defer for (files) |f| h.deleteFile(f);
    for (files[0..2]) |f| if (h.readFileOrNull(f)) |data| {
        alloc.free(data);
        return h.fail("a marker from before the test remains: {s}", .{f});
    };
    try h.writeFileAt(sample, "sample\r\n");

    // Before, in case a killed run left entries behind, and after.
    removeLinkTestRegistry(h);
    defer removeLinkTestRegistry(h);
    {
        const cmd = try std.fmt.allocPrint(alloc, "\"{s}\" \"{s}\" \"%1\"", .{ recorder, protocol_marker });
        defer alloc.free(cmd);
        try h.setRegString(link_test_keys[0], null, "URL:Ghostty GUI test");
        try h.setRegString(link_test_keys[0], "URL Protocol", "");
        try h.setRegString(link_test_keys[0] ++ "\\shell\\open\\command", null, cmd);
    }
    {
        const cmd = try std.fmt.allocPrint(alloc, "\"{s}\" \"{s}\" \"%1\"", .{ recorder, file_marker });
        defer alloc.free(cmd);
        try h.setRegString(link_test_keys[1], null, "GhosttyGuiTest.File");
        try h.setRegString(link_test_keys[2] ++ "\\shell\\open\\command", null, cmd);
    }

    var g = try h.launchWith("links-open", base_config ++ "command = powershell.exe -NoLogo -NoProfile\n", .{
        .env = &.{.{ "GHOSTTY_WIN32_TEST_LAUNCH", "1" }},
    });
    defer g.deinit();
    try h.waitText(&g, "PS ", 1, 20000);
    const surf = try h.surface(&g, try h.mainWindow(&g));
    const command = try std.fmt.allocPrint(alloc, "cls;$e=[char]27;$t=\"$e\\\";" ++
        "function Lnk($u,$n){{Write-Host \"$e]8;;$u${{t}}LNK-$n$e]8;;$t\"}};" ++
        "Lnk ghostty-gui-test:hello APP;Lnk '{s}' FILE;Write-Host ('LNK-'+'END')", .{sample});
    defer alloc.free(command);
    try h.typeText(surf, command);
    h.enter(surf);
    try h.waitText(&g, "LNK-END", 1, 15000);

    // The protocol asks first, then opens.
    try clickAndAnswer(h, &g, surf, "LNK-APP", "Open Link", id_open_link);
    try waitFileText(h, protocol_marker, "ghostty-gui-test:hello");

    // A file of a type nothing vouches for asks too, then opens as the
    // item that was checked.
    try clickAndAnswer(h, &g, surf, "LNK-FILE", "Open Link", id_open_link);
    try waitFileText(h, file_marker, "sample.ghosttyguitest");
    {
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(d.value.launches.len == 0, "nothing was only recorded", .{});
    }
    try quit(h, &g, surf);
}

/// The pixel Ghostty last presented near its window's bottom-right corner
/// (read back by the renderer in Debug builds, so this works on the hidden
/// desktop, where captures don't).
fn presentedPixel(h: *Harness, name: []const u8, config: []const u8) !u32 {
    var g = try start(h, name, config, ">");
    defer g.deinit();
    var waited: u32 = 0;
    while (waited <= 5000) : (waited += 200) {
        var d = try h.dump(&g);
        defer d.deinit();
        if (d.value.windows[0].tabs[0].pixel) |px| if (px != 0) {
            h.log("{s}: #{x:0>6}", .{ name, px });
            return px;
        };
        w.Sleep(200);
    }
    return h.fail("{s}: no frame was presented", .{name});
}

/// The window is opaque, so background-opacity below 1 must show the
/// background color as configured, not darkened toward black (roadmap 0.3).
fn present(h: *Harness) anyerror!void {
    const default = try presentedPixel(h, "present-default", "");
    try h.expect(default == 0x282c34, "default background #{x:0>6}, expected #282c34", .{default});
    const half = try presentedPixel(h, "present-opacity", "background-opacity = 0.5\n");
    try h.expect(half == 0x282c34, "opacity 0.5 gives #{x:0>6}, expected #282c34", .{half});
    const color = try presentedPixel(h, "present-color", "background = #336699\nbackground-opacity = 0.3\n");
    try h.expect(color == 0x336699, "#336699 at opacity 0.3 gives #{x:0>6}", .{color});
    // Native (non-linear) blending, whose colors used to be encoded twice
    // (#336699 showed as #7caacb). Its sRGB values pass through the sRGB
    // target's 8-bit encoding, which can be off by one.
    const native_opaque = try presentedPixel(h, "present-native-1", "background = #336699\nalpha-blending = native\n");
    try h.expect(nearColor(native_opaque, 0x336699), "native blending gives #{x:0>6}, expected #336699", .{native_opaque});
    const native_part = try presentedPixel(h, "present-native-0.3", "background = #336699\nbackground-opacity = 0.3\nalpha-blending = native\n");
    try h.expect(nearColor(native_part, 0x336699), "native blending at opacity 0.3 gives #{x:0>6}", .{native_part});

    // The frame itself reaches the window, at its top-left corner and not
    // blended into the background: the prompt starts with a cell whose
    // background is explicitly red, and cell backgrounds stay opaque at any
    // background-opacity.
    var g = try start(h, "present-cell", "command = cmd.exe /k prompt $E[48;2;255;0;0m $E[0m$G\nbackground-opacity = 0.5\n", ">");
    defer g.deinit();
    const x, const y = cell: {
        var d = try h.dump(&g);
        defer d.deinit();
        const t = d.value.windows[0].tabs[0];
        const cell = t.cell orelse return h.fail("no cell size in the dump", .{});
        const pad = t.padding orelse return h.fail("no padding in the dump", .{});
        var row: u32 = 0;
        var lines = std.mem.splitScalar(u8, t.text orelse "", '\n');
        while (lines.next()) |line| : (row += 1) {
            if (std.mem.startsWith(u8, line, " >")) break;
        } else return h.fail("no prompt row", .{});
        break :cell .{ pad[0] + cell[0] / 2, pad[1] + row * cell[1] + cell[1] / 2 };
    };
    const red = try h.probe(&g, x, y);
    try h.expect(red == 0xff0000, "the red prompt cell at ({d},{d}) shows #{x:0>6}", .{ x, y, red });
    try quit(h, &g, try h.surface(&g, try h.mainWindow(&g)));
}

/// Whether each channel of two 0xRRGGBB colors differs by at most one.
fn nearColor(a: u32, b: u32) bool {
    for ([_]u5{ 0, 8, 16 }) |shift| {
        const x: i32 = @intCast((a >> shift) & 0xFF);
        const y: i32 = @intCast((b >> shift) & 0xFF);
        if (@abs(x - y) > 1) return false;
    }
    return true;
}

const Chrome = struct { dark: bool, caption: i64 };

fn chromeOf(h: *Harness, g: *Harness.Ghostty) !Chrome {
    var d = try h.dump(g);
    defer d.deinit();
    const c = d.value.windows[0].chrome orelse return h.fail("no chrome in the dump", .{});
    return .{ .dark = c.dark, .caption = c.caption };
}

fn schemeOf(h: *Harness, g: *Harness.Ghostty) ![]const u8 {
    var d = try h.dump(g);
    defer d.deinit();
    const s = d.value.windows[0].tabs[0].scheme orelse return h.fail("no scheme in the dump", .{});
    // Static strings, so they outlive the dump.
    return if (std.mem.eql(u8, s, "dark")) "dark" else if (std.mem.eql(u8, s, "light")) "light" else "?";
}

/// Launch with `extra` and check the title bar.
fn expectChrome(h: *Harness, name: []const u8, extra: []const u8, dark: bool, caption: i64) !void {
    var g = try start(h, name, extra, ">");
    defer g.deinit();
    const got = try chromeOf(h, &g);
    try h.expect(got.dark == dark and got.caption == caption, "{s}: dark {} caption {x}, expected dark {} caption {x}", .{ name, got.dark, got.caption, dark, caption });
}

/// window-theme (roadmap 0.4). The caption colors themselves need Windows
/// 11; the dump reports what Ghostty asked DWM for.
fn theme(h: *Harness) anyerror!void {
    // auto (the default): the terminal's own colors.
    try expectChrome(h, "theme-auto", "", true, 0x282c34);
    try expectChrome(h, "theme-auto-light", "background = #fafafa\nforeground = #202020\n", false, 0xfafafa);
    // Forced light or dark: the system's caption.
    try expectChrome(h, "theme-light", "window-theme = light\n", false, -1);
    try expectChrome(h, "theme-dark", "window-theme = dark\n", true, -1);
    // ghostty: the titlebar colors, else the configured background.
    try expectChrome(h, "theme-ghostty", "window-theme = ghostty\nwindow-titlebar-background = #112233\n", true, 0x112233);

    // auto follows a program changing the background (OSC 11).
    {
        var g = try start(h, "theme-osc11", "command = powershell.exe -NoLogo -NoProfile\n", "PS ");
        defer g.deinit();
        const surf = try h.surface(&g, try h.mainWindow(&g));
        try h.typeText(surf, "Write-Host -NoNewline \"$([char]27)]11;#f0f0f0$([char]7)\"");
        h.enter(surf);
        var waited: u32 = 0;
        var got = try chromeOf(h, &g);
        while (got.caption != 0xf0f0f0 and waited < 5000) : (waited += 200) {
            w.Sleep(200);
            got = try chromeOf(h, &g);
        }
        try h.expect(got.caption == 0xf0f0f0 and !got.dark, "OSC 11 sets the caption (got {x}, dark {})", .{ got.caption, got.dark });
        try quit(h, &g, surf);
    }

    // The system's light/dark setting reaches the terminals that are
    // already open (conditional themes, DEC mode 2031), and the caption
    // under window-theme = system. Simulated: the user's setting is left
    // alone.
    {
        var g = try start(h, "theme-system", "window-theme = system\n", ">");
        defer g.deinit();
        try h.setSystemDark(&g, true);
        try h.expect(std.mem.eql(u8, try schemeOf(h, &g), "dark"), "a system switch to dark reaches the terminal", .{});
        try h.expect((try chromeOf(h, &g)).dark, "and darkens the caption", .{});
        try h.setSystemDark(&g, false);
        try h.expect(std.mem.eql(u8, try schemeOf(h, &g), "light"), "a switch to light reaches it too", .{});
        try h.expect(!(try chromeOf(h, &g)).dark, "and lightens the caption", .{});
        try quit(h, &g, try h.surface(&g, try h.mainWindow(&g)));
    }
    // A forced theme is the scheme whatever the system says.
    {
        var g = try start(h, "theme-forced", "window-theme = dark\n", ">");
        defer g.deinit();
        try h.setSystemDark(&g, false);
        try h.expect(std.mem.eql(u8, try schemeOf(h, &g), "dark"), "window-theme = dark keeps the terminal dark", .{});
        try quit(h, &g, try h.surface(&g, try h.mainWindow(&g)));
    }
}

fn gridOf(h: *Harness, g: *Harness.Ghostty) ![2]u32 {
    var d = try h.dump(g);
    defer d.deinit();
    const t = d.value.windows[0].tabs[0];
    return .{ t.cols orelse 0, t.rows orelse 0 };
}

/// Growing and shrinking the window resizes the terminal (laid out with
/// DeferWindowPos, roadmap 0.5), and its bottom-right corner shows the
/// background color each time, not black.
fn resize(h: *Harness) anyerror!void {
    var g = try start(h, "resize", "", ">");
    defer g.deinit();
    const win = try h.mainWindow(&g);
    const before = try gridOf(h, &g);
    var r: w.RECT = .{};
    _ = w.GetWindowRect(win, &r);
    for ([_]c_int{ 240, -160 }) |delta| {
        const width = r.right - r.left + delta;
        const height = r.bottom - r.top + @divTrunc(delta, 2);
        _ = w.SetWindowPos(win, null, 0, 0, width, height, w.SWP_NOMOVE | w.SWP_NOZORDER | w.SWP_NOACTIVATE);
        var waited: u32 = 0;
        var grid = try gridOf(h, &g);
        while (grid[0] == before[0] and waited < 5000) : (waited += 200) {
            w.Sleep(200);
            grid = try gridOf(h, &g);
        }
        try h.expect(if (delta > 0) grid[0] > before[0] else grid[0] < before[0], "a {d}px change resizes the grid ({d}x{d} to {d}x{d})", .{ delta, before[0], before[1], grid[0], grid[1] });
        w.Sleep(500);
        var d = try h.dump(&g);
        defer d.deinit();
        const px = d.value.windows[0].tabs[0].pixel orelse 0;
        try h.expect(px == 0x282c34, "the corner is the background after resizing (#{x:0>6})", .{px});
    }
    try quit(h, &g, try h.surface(&g, win));
}

/// Button ids of the config errors dialog (src/apprt/win32/App.zig).
const id_open_config = 110;
const id_reload_config = 111;

fn launchCount(h: *Harness, g: *Harness.Ghostty, prefix: []const u8) !usize {
    var d = try h.dump(g);
    defer d.deinit();
    var n: usize = 0;
    for (d.value.launches) |l| {
        if (std.mem.startsWith(u8, l, prefix)) n += 1;
    }
    return n;
}

/// A config error shows a dialog at startup (the log of a GUI program goes
/// nowhere); Open Configuration opens the file and leaves the dialog up;
/// fixing the file and choosing Reload applies it; Ctrl+, opens the file
/// too (roadmap 0.6). Opening is recorded by the Debug build, not done.
fn configErrors(h: *Harness) anyerror!void {
    var g = try start(h, "config-errors", "fontt-size = 12\n", ">");
    defer g.deinit();
    var dlg = try h.waitDialog(&g, 5000);
    try expectTitle(h, dlg, "Configuration Errors");

    h.answer(&g, dlg, id_open_config);
    w.Sleep(1000);
    try h.expect(try h.dialogCount(&g) == 1, "Open Configuration leaves the dialog open", .{});
    try h.expect(try launchCount(h, &g, "edit-config ") == 1, "and opens the config file", .{});

    // Fix the file (the misspelled key goes; a visible setting comes) and
    // reload from the dialog.
    const path = try std.fmt.allocPrint(h.alloc, "{s}\\ghostty\\config.ghostty", .{g.dir});
    defer h.alloc.free(path);
    try h.writeFileAt(path, base_config ++ "window-theme = light\n");
    dlg = try h.waitDialog(&g, 1000);
    h.answer(&g, dlg, id_reload_config);
    try waitNoDialog(h, &g);
    w.Sleep(1500);
    try h.expect(try h.dialogCount(&g) == 0, "a config without errors shows no dialog", .{});
    const chrome = try chromeOf(h, &g);
    try h.expect(!chrome.dark and chrome.caption == -1, "Reload applied the fixed config (window-theme = light)", .{});

    // Ctrl+, opens the config file.
    const surf = try h.surface(&g, try h.mainWindow(&g));
    h.key(surf, .{ .ctrl = true }, w.VK_OEM_COMMA);
    var waited: u32 = 0;
    while (try launchCount(h, &g, "edit-config ") < 2 and waited < 5000) : (waited += 200) w.Sleep(200);
    try h.expect(try launchCount(h, &g, "edit-config ") == 2, "Ctrl+, opens the config file", .{});
    try quit(h, &g, surf);
}

/// The visible text of the first tab, once `needle` is in it.
fn textWith(h: *Harness, g: *Harness.Ghostty, needle: []const u8) ![]u8 {
    try h.waitText(g, needle, 1, 20000);
    var d = try h.dump(g);
    defer d.deinit();
    return h.alloc.dupe(u8, d.value.windows[0].tabs[0].text orelse "");
}

/// Where Ghostty starts depends on how it was launched (roadmap 0.7): a
/// shell (anything but the desktop) passes its directory on, a shortcut or
/// Explorer starts it in the home directory, and a POSIX SHELL (MSYS2, Git
/// Bash) is not taken as the command.
fn launchContext(h: *Harness) anyerror!void {
    // The harness starts Ghostty in the scenario's folder, as a shell would.
    {
        var g = try h.launchWith("launch-context", "", .{});
        defer g.deinit();
        const text = try textWith(h, &g, ">");
        defer h.alloc.free(text);
        try h.expect(std.ascii.findIgnoreCase(text, g.dir) != null, "started from a program, it opens in that program's directory", .{});
        try quit(h, &g, try h.surface(&g, try h.mainWindow(&g)));
    }
    // As a shortcut launch: the home directory.
    {
        var home_buf: [260]u16 = undefined;
        const n = w.GetEnvironmentVariableW(w.L("USERPROFILE"), &home_buf, home_buf.len);
        const home = try std.unicode.utf16LeToUtf8Alloc(h.alloc, home_buf[0..n]);
        defer h.alloc.free(home);
        const prompt = try std.fmt.allocPrint(h.alloc, "{s}>", .{home});
        defer h.alloc.free(prompt);
        var g = try h.launchWith("launch-context-shortcut", "", .{ .shortcut = "C:\\ProgramData\\Microsoft\\Windows\\Start Menu\\Programs\\Ghostty.lnk" });
        defer g.deinit();
        const text = try textWith(h, &g, ">");
        defer h.alloc.free(text);
        try h.expect(std.ascii.findIgnoreCase(text, prompt) != null, "started from a shortcut, it opens in {s}", .{home});
        try quit(h, &g, try h.surface(&g, try h.mainWindow(&g)));
    }
    // SHELL from Git Bash is ignored: cmd starts.
    {
        var g = try h.launchWith("launch-context-shell", "", .{ .env = &.{.{ "SHELL", "/usr/bin/bash" }} });
        defer g.deinit();
        const text = try textWith(h, &g, ">");
        defer h.alloc.free(text);
        try h.expect(std.ascii.findIgnoreCase(text, "Microsoft Windows") != null, "SHELL=/usr/bin/bash still starts cmd", .{});
        try quit(h, &g, try h.surface(&g, try h.mainWindow(&g)));
    }
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
