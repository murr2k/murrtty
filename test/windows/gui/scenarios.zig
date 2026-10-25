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
    .{ .name = "fonts", .about = "a font-family's bold and italic faces are found (Consolas)", .run = fonts },
    .{ .name = "output-frames", .about = "output that arrives with no key pressed is drawn", .run = outputFrames },
    .{ .name = "background-close", .about = "a tab closing in a background window leaves the active window active", .run = backgroundClose },
    .{ .name = "focus-background-tab", .about = "a tab that never got the focus doesn't stay focused in the core", .run = focusBackgroundTab },
    .{ .name = "splits", .about = "Ctrl+Shift+O/E split panes that tile the tab; closing panes moves focus as designed", .run = splits },
    .{ .name = "split-commands", .about = "goto_split, toggle_split_zoom (hidden panes stop drawing), resize_split, equalize_splits", .run = splitCommands },
    .{ .name = "stress-panes", .about = "16 panes flooding output keep rendering (GHOSTTY_GUI_STRESS=1)", .run = stressPanes },
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

/// With font-family set, bold and italic text use the family's own Bold
/// and Italic faces, not the regular one (roadmap 0.9). Read from
/// Ghostty's log.
fn fonts(h: *Harness) anyerror!void {
    var g = try start(h, "fonts", "font-family = Consolas\n", ">");
    defer g.deinit();
    w.Sleep(1000);
    const path = try std.fmt.allocPrint(h.alloc, "{s}\\ghostty.log", .{g.dir});
    defer h.alloc.free(path);
    const log = h.readFileOrNull(path) orelse return h.fail("no log", .{});
    defer h.alloc.free(log);
    // The grid set logs "font <style>: <full name>" for each style.
    const cases = [_][2][]const u8{
        .{ "font regular:", "Consolas" },
        .{ "font bold:", "Consolas Bold" },
        .{ "font italic:", "Consolas Italic" },
        .{ "font bold_italic:", "Consolas Bold Italic" },
    };
    for (cases) |case| {
        const at = std.mem.indexOf(u8, log, case[0]) orelse return h.fail("no '{s}' line in the log", .{case[0]});
        const rest = log[at + case[0].len ..];
        const line = std.mem.trim(u8, rest[0 .. std.mem.indexOfAny(u8, rest, "\r\n") orelse rest.len], " ");
        try h.expect(std.mem.eql(u8, line, case[1]), "{s} {s} (expected {s})", .{ case[0], line, case[1] });
    }
    try quit(h, &g, try h.surface(&g, try h.mainWindow(&g)));
}

/// Output that arrives with no key pressed must reach the screen: the
/// thread reading the pty wakes the renderer itself. It once held a copy
/// of the renderer's wakeup handle taken before the renderer thread waited
/// on it, which on Windows (libxev's IOCP backend) never fired, so output
/// was drawn only by the next key press or cursor blink, and typed text
/// trailed behind the keys.
fn outputFrames(h: *Harness) anyerror!void {
    // No cursor blink, so nothing but output can draw while we wait.
    var g = try start(h, "output-frames", "cursor-style-blink = false\n", ">");
    defer g.deinit();
    const surf = try h.surface(&g, try h.mainWindow(&g));
    // The marker prints about a second after Enter, with no input between.
    try h.typeText(surf, "ping -n 2 127.0.0.1 >nul & echo late-out");
    h.enter(surf);
    w.Sleep(500);
    const before = try framesPresented(h, &g);
    // Once on the command line, then the output.
    try h.waitText(&g, "late-out", 2, 10000);
    w.Sleep(500);
    const after = try framesPresented(h, &g);
    try h.expect(after > before, "frames after the output: {d}, before: {d}", .{ after, before });
    try quit(h, &g, surf);
}

/// A tab that closes in a background window must not activate it. Focusing
/// the window's next tab once did: SetFocus activates the window it is
/// called on, pulling the background window in front of the one in use.
fn backgroundClose(h: *Harness) anyerror!void {
    var g = try start(h, "background-close", "", ">");
    defer g.deinit();
    const a = try h.mainWindow(&g);
    h.key(try h.surface(&g, a), .{ .ctrl = true, .shift = true }, 'T');
    try waitWindowTabs(h, &g, a, 2);
    w.Sleep(1500);
    // A second window, which becomes the active one.
    h.key(try h.surface(&g, a), .{ .ctrl = true, .shift = true }, 'N');
    w.Sleep(2500);
    const wins = try h.windows(&g, "GhosttyWindow");
    defer h.alloc.free(wins);
    try h.expect(wins.len == 2, "Ctrl+Shift+N opens a second window (got {d})", .{wins.len});
    const b = if (wins[0] == a) wins[1] else wins[0];
    try h.expect(activeWindow(a) == b, "the new window is active", .{});

    // End the background window's active tab from its shell.
    const tab = try h.surface(&g, a);
    try h.typeText(tab, "exit");
    h.enter(tab);
    try waitWindowTabs(h, &g, a, 1);
    w.Sleep(500);
    const active = activeWindow(a);
    try h.expect(active == b, "the other window stays active (active is {s})", .{
        if (active == a) "the background window" else if (active == null) "none" else "another window",
    });
    try quit(h, &g, try h.surface(&g, b));
}

/// A tab that loses the focus before it ever reaches the core must not keep
/// the core surface's initial "focused" state (its cursor would show as
/// focused, and focus reporting would never tell its program): a chained
/// binding opens a tab and goes back to the first one at once.
fn focusBackgroundTab(h: *Harness) anyerror!void {
    var g = try start(h, "focus-background-tab", "keybind = ctrl+shift+y=new_tab\nkeybind = chain=goto_tab:1\n", ">");
    defer g.deinit();
    const win = try h.mainWindow(&g);
    h.key(try h.surface(&g, win), .{ .ctrl = true, .shift = true }, 'Y');
    try waitWindowTabs(h, &g, win, 2);
    w.Sleep(1500);
    var d = try h.dump(&g);
    defer d.deinit();
    const dw = d.value.windows[0];
    try h.expect(dw.active == 0, "back on the first tab (active is {d})", .{dw.active});
    try h.expect(dw.tabs[0].focused orelse false, "the first tab's terminal is focused", .{});
    try h.expect(!(dw.tabs[1].focused orelse true), "the new tab's terminal is not focused", .{});
    try quit(h, &g, try h.surface(&g, win));
}

/// Splitting and closing panes: Ctrl+Shift+O puts a new pane right of the
/// focused one, Ctrl+Shift+E below it; the panes and dividers tile the tab
/// exactly; the new pane takes the focus (the window's and the core's);
/// `exit` in a background pane leaves the focus alone, and in the focused
/// pane hands it to the pane before it.
fn splits(h: *Harness) anyerror!void {
    var g = try start(h, "splits", "", ">");
    defer g.deinit();
    const win = try h.mainWindow(&g);
    const first = try h.surface(&g, win);

    // Side by side.
    h.key(first, .{ .ctrl = true, .shift = true }, 'O');
    try waitPanes(h, &g, 2);
    w.Sleep(1500);
    {
        var d = try h.dump(&g);
        defer d.deinit();
        const t = d.value.windows[0].tabs[0];
        const p = t.panes.?;
        const area = t.area.?;
        try expectTiling(h, t);
        try h.expect(p[0].rect[2] < p[1].rect[0], "the new pane is right of the first", .{});
        const w0 = p[0].rect[2] - p[0].rect[0];
        const w1 = p[1].rect[2] - p[1].rect[0];
        try h.expect(@abs(w0 - w1) <= 1, "halves of the width: {d} and {d}", .{ w0, w1 });
        try h.expect(p[0].rect[3] - p[0].rect[1] == area[1], "full height", .{});
        try h.expect(p[1].focused and !p[0].focused, "the new pane is the tab's focused pane", .{});
        try h.expect(p[1].core_focused orelse false, "the new pane's core is focused", .{});
        try h.expect(!(p[0].core_focused orelse true), "the first pane's core is not", .{});
        try h.expect(keyboardFocus(win) == hwndOf(p[1].hwnd), "the new pane has the keyboard focus", .{});
    }

    // Typed text reaches the focused pane only.
    const second = try paneHwnd(h, &g, 1);
    try h.typeText(second, "echo pane-two-out");
    h.enter(second);
    try waitPaneText(h, &g, 1, "pane-two-out", 2);
    {
        var d = try h.dump(&g);
        defer d.deinit();
        const p = d.value.windows[0].tabs[0].panes.?;
        try h.expect(std.mem.indexOf(u8, p[0].text orelse "", "pane-two-out") == null, "the first pane didn't get it", .{});
    }

    // Below the second: tree order is first, second, third.
    h.key(second, .{ .ctrl = true, .shift = true }, 'E');
    try waitPanes(h, &g, 3);
    w.Sleep(1500);
    {
        var d = try h.dump(&g);
        defer d.deinit();
        const t = d.value.windows[0].tabs[0];
        const p = t.panes.?;
        try expectTiling(h, t);
        try h.expect(p[1].rect[0] == p[2].rect[0] and p[1].rect[2] == p[2].rect[2], "the third pane is under the second", .{});
        try h.expect(p[1].rect[3] < p[2].rect[1], "stacked", .{});
        try h.expect(p[2].focused, "the third pane is focused", .{});
    }
    const third = try paneHwnd(h, &g, 2);

    // `exit` in the first (background) pane: the focus stays on the third.
    const first_pane = try paneHwnd(h, &g, 0);
    try h.typeText(first_pane, "exit");
    h.enter(first_pane);
    try waitPanes(h, &g, 2);
    w.Sleep(800);
    {
        var d = try h.dump(&g);
        defer d.deinit();
        const t = d.value.windows[0].tabs[0];
        const p = t.panes.?;
        try expectTiling(h, t);
        try h.expect(hwndOf(p[1].hwnd) == third and p[1].focused, "the third pane keeps the tab's focus", .{});
        try h.expect(keyboardFocus(win) == third, "and the keyboard focus", .{});
    }

    // `exit` in the focused third pane: the focus goes to the one before it.
    try h.typeText(third, "exit");
    h.enter(third);
    try waitPanes(h, &g, 1);
    w.Sleep(800);
    {
        var d = try h.dump(&g);
        defer d.deinit();
        const t = d.value.windows[0].tabs[0];
        const p = t.panes.?;
        try h.expect(hwndOf(p[0].hwnd) == second and p[0].focused, "the second pane is focused", .{});
        try h.expect(keyboardFocus(win) == second, "and has the keyboard focus", .{});
        try h.expect(p[0].rect[0] == 0 and p[0].rect[2] == t.area.?[0], "and fills the tab", .{});
        try h.expect(t.dividers.?.len == 0, "no dividers", .{});
    }
    try quit(h, &g, second);
}

/// Roadmap S4: sixteen panes, each with its own GL context and render
/// thread, all flooding output, keep presenting frames, and memory grows
/// with their scrollback rather than without bound. Long and heavy, so it
/// runs only with GHOSTTY_GUI_STRESS=1, and it prints what it measured. In
/// a Debug build every frame also reads back a pixel for the tests, so the
/// frame counts say whether all panes keep up, not how fast a release
/// build is.
fn stressPanes(h: *Harness) anyerror!void {
    if (w.GetEnvironmentVariableW(w.L("GHOSTTY_GUI_STRESS"), null, 0) == 0) {
        return h.skip("set GHOSTTY_GUI_STRESS=1 to run it", .{});
    }
    var g = try start(h, "stress-panes", "window-width = 160\nwindow-height = 48\n", ">");
    defer g.deinit();
    w.Sleep(1000);
    const mem_one = privateBytes(&g);
    const ws_one = workingSet(&g);

    // Four columns, then each pane halved twice: a 4 x 4 grid. Panes are
    // split from the last one back, so earlier indices stay put.
    try splitPane(h, &g, 0, 'O');
    try splitPane(h, &g, 0, 'O');
    try splitPane(h, &g, 2, 'O');
    for (0..2) |_| {
        var i = try paneCount(h, &g);
        while (i > 0) {
            i -= 1;
            try splitPane(h, &g, i, 'E');
        }
    }
    const count = try paneCount(h, &g);
    try h.expect(count == 16, "sixteen panes (got {d})", .{count});
    w.Sleep(3000);
    const mem_sixteen = privateBytes(&g);
    const ws_sixteen = workingSet(&g);
    std.debug.print("\n    private memory: one pane {d} MB, sixteen idle panes {d} MB ({d} MB a pane)", .{
        mem_one >> 20,
        mem_sixteen >> 20,
        ((mem_sixteen -| mem_one) / 15) >> 20,
    });
    std.debug.print("\n    working set: one pane {d} MB, sixteen idle panes {d} MB ({d} MB a pane)", .{
        ws_one >> 20,
        ws_sixteen >> 20,
        ((ws_sixteen -| ws_one) / 15) >> 20,
    });

    var panes: [16]w.HWND = undefined;
    for (&panes, 0..) |*p, i| p.* = try paneHwnd(h, &g, i);
    for (panes) |p| {
        try h.typeText(p, "for /l %i in (1,1,200000) do @echo flood-line-%i");
        h.enter(p);
    }

    // Once a second: frames per pane and private memory.
    var first: [16]u32 = undefined;
    var last: [16]u32 = undefined;
    var mem_first: usize = 0;
    var mem_last: usize = 0;
    const seconds = 15;
    for (0..seconds) |s| {
        w.Sleep(1000);
        var d = try h.dump(&g);
        defer d.deinit();
        const p = d.value.windows[0].tabs[0].panes.?;
        var mem: w.PROCESS_MEMORY_COUNTERS = .{};
        _ = w.K32GetProcessMemoryInfo(g.proc, &mem, @sizeOf(w.PROCESS_MEMORY_COUNTERS));
        var min_frames: u32 = std.math.maxInt(u32);
        for (p, 0..) |pane, i| {
            last[i] = pane.frames orelse 0;
            if (s == 1) first[i] = last[i];
            min_frames = @min(min_frames, last[i]);
        }
        if (s == 1) mem_first = mem.PagefileUsage;
        mem_last = mem.PagefileUsage;
        std.debug.print("\n    t={d:>2}s  private {d:>5} MB  fewest frames in a pane {d}", .{ s + 1, mem.PagefileUsage >> 20, min_frames });
    }
    std.debug.print("\n", .{});

    // Every pane kept presenting while all of them flooded.
    for (first, last, 0..) |a, b, i| {
        try h.expect(b - a >= 10, "pane {d} presented {d} frames in {d} s", .{ i, b - a, seconds - 2 });
    }
    try h.expect(g.exitCode() == null, "still running", .{});
    h.log("private memory {d} MB after a second of flooding, {d} MB at the end", .{ mem_first >> 20, mem_last >> 20 });
    // Sixteen 10 MB scrollbacks and their renderers: generous, but bounded.
    try h.expect(mem_last < 2048 << 20, "private memory under 2 GB (got {d} MB)", .{mem_last >> 20});
}

/// Ghostty's private committed memory, in bytes.
fn privateBytes(g: *Harness.Ghostty) usize {
    var mem: w.PROCESS_MEMORY_COUNTERS = .{};
    if (w.K32GetProcessMemoryInfo(g.proc, &mem, @sizeOf(w.PROCESS_MEMORY_COUNTERS)) == 0) return 0;
    return mem.PagefileUsage;
}

/// Ghostty's working set (resident memory), in bytes.
fn workingSet(g: *Harness.Ghostty) usize {
    var mem: w.PROCESS_MEMORY_COUNTERS = .{};
    if (w.K32GetProcessMemoryInfo(g.proc, &mem, @sizeOf(w.PROCESS_MEMORY_COUNTERS)) == 0) return 0;
    return mem.WorkingSetSize;
}

/// Press Ctrl+Shift+`key` on pane `i` and wait for the new pane.
fn splitPane(h: *Harness, g: *Harness.Ghostty, i: usize, key: u8) !void {
    const before = try paneCount(h, g);
    h.key(try paneHwnd(h, g, i), .{ .ctrl = true, .shift = true }, key);
    try waitPanes(h, g, before + 1);
}

fn paneCount(h: *Harness, g: *Harness.Ghostty) !usize {
    var d = try h.dump(g);
    defer d.deinit();
    const dw = d.value.windows[0];
    return if (dw.tabs[dw.active].panes) |p| p.len else 0;
}

/// goto_split (wrapping previous/next and a direction), toggle_split_zoom
/// (the zoomed pane fills the tab, the others are hidden and stop drawing
/// while their output still arrives), moving to another pane ending the
/// zoom, resize_split and equalize_splits.
fn splitCommands(h: *Harness) anyerror!void {
    const cs: Harness.Mods = .{ .ctrl = true, .shift = true };
    const f1 = 0x70;
    const f2 = 0x71;
    const f3 = 0x72;
    const f4 = 0x73;
    const f5 = 0x74;
    var g = try start(h, "split-commands",
        \\keybind = ctrl+shift+f1=goto_split:previous
        \\keybind = ctrl+shift+f2=goto_split:next
        \\keybind = ctrl+shift+f3=goto_split:left
        \\keybind = ctrl+shift+f4=equalize_splits
        \\keybind = ctrl+shift+f5=resize_split:right,100
        \\
    , ">");
    defer g.deinit();
    const win = try h.mainWindow(&g);

    // A | (B / C), with C focused.
    h.key(try h.surface(&g, win), cs, 'O');
    try waitPanes(h, &g, 2);
    w.Sleep(800);
    h.key(try paneHwnd(h, &g, 1), cs, 'E');
    try waitPanes(h, &g, 3);
    w.Sleep(1500);
    const a = try paneHwnd(h, &g, 0);
    const b = try paneHwnd(h, &g, 1);
    const cc = try paneHwnd(h, &g, 2);
    try expectFocus(h, &g, win, cc, "C after the splits");

    // Previous and next, wrapping.
    h.key(cc, cs, f1);
    try expectFocus(h, &g, win, b, "previous from C: B");
    h.key(b, cs, f2);
    try expectFocus(h, &g, win, cc, "next from B: C");
    h.key(cc, cs, f2);
    try expectFocus(h, &g, win, a, "next from C wraps to A");
    // A direction: from C, left is A.
    h.key(a, cs, f2);
    h.key(b, cs, f2);
    try expectFocus(h, &g, win, cc, "back to C");
    h.key(cc, cs, f3);
    try expectFocus(h, &g, win, a, "left from C: A");

    // B gets output once a second; then A is zoomed.
    try h.typeText(b, "ping -n 30 127.0.0.1");
    h.enter(b);
    try waitPaneText(h, &g, 1, "Reply from", 1);
    var grid_b: [2]u32 = undefined;
    {
        var d = try h.dump(&g);
        defer d.deinit();
        const p = d.value.windows[0].tabs[0].panes.?;
        grid_b = .{ p[1].cols orelse 0, p[1].rows orelse 0 };
    }
    h.key(a, cs, w.VK_RETURN);
    w.Sleep(800);
    var frames_hidden: u32 = 0;
    var replies: usize = 0;
    {
        var d = try h.dump(&g);
        defer d.deinit();
        const t = d.value.windows[0].tabs[0];
        const p = t.panes.?;
        try h.expect(t.zoomed orelse false, "the tab is zoomed", .{});
        try h.expect(p[0].visible and !p[1].visible and !p[2].visible, "only A is shown", .{});
        try h.expect(p[0].rect[0] == 0 and p[0].rect[2] == t.area.?[0] and p[0].rect[3] == t.area.?[1], "A fills the tab", .{});
        // A hidden pane keeps its size: shrinking it would reflow its text.
        try h.expect((p[1].cols orelse 0) == grid_b[0] and (p[1].rows orelse 0) == grid_b[1], "hidden B keeps its {d}x{d} grid (has {?d}x{?d})", .{ grid_b[0], grid_b[1], p[1].cols, p[1].rows });
        frames_hidden = p[1].frames orelse 0;
        replies = std.mem.count(u8, p[1].text orelse "", "Reply from");
    }
    w.Sleep(3000);
    {
        var d = try h.dump(&g);
        defer d.deinit();
        const p = d.value.windows[0].tabs[0].panes.?;
        const more = std.mem.count(u8, p[1].text orelse "", "Reply from");
        try h.expect(more > replies, "B's output still arrives ({d} replies, then {d})", .{ replies, more });
        try h.expect((p[1].frames orelse 0) == frames_hidden, "but B draws nothing while hidden ({d} frames, then {d})", .{ frames_hidden, p[1].frames orelse 0 });
    }
    h.key(a, cs, w.VK_RETURN);
    w.Sleep(800);
    {
        var d = try h.dump(&g);
        defer d.deinit();
        const t = d.value.windows[0].tabs[0];
        const p = t.panes.?;
        try h.expect(!(t.zoomed orelse true), "unzoomed", .{});
        try h.expect(p[0].visible and p[1].visible and p[2].visible, "all panes shown", .{});
        try expectTiling(h, t);
    }

    // Moving to another pane ends a zoom (split-preserve-zoom is off).
    h.key(a, cs, w.VK_RETURN);
    w.Sleep(500);
    h.key(a, cs, f2);
    try expectFocus(h, &g, win, b, "next from the zoomed A: B");
    {
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(!(d.value.windows[0].tabs[0].zoomed orelse true), "and the zoom ended", .{});
    }

    // Resize from A: the divider moves right by 100 points; equalize
    // brings it back to the middle.
    h.key(b, cs, f3);
    try expectFocus(h, &g, win, a, "left from B: A");
    const before = try rootDivider(h, &g);
    h.key(a, cs, f5);
    w.Sleep(800);
    const after = try rootDivider(h, &g);
    const dpi = w.GetDpiForWindow(win);
    const want: i32 = @intCast((100 * dpi + 48) / 96);
    try h.expect(@abs(after - before - want) <= 2, "resize moved the divider {d} px (expected {d})", .{ after - before, want });
    h.key(a, cs, f4);
    w.Sleep(800);
    try h.expect(@abs((try rootDivider(h, &g)) - before) <= 1, "equalize put it back in the middle", .{});
    try quit(h, &g, a);
}

/// Wait until `pane` is the tab's focused pane and has the keyboard focus.
fn expectFocus(h: *Harness, g: *Harness.Ghostty, win: w.HWND, pane: w.HWND, comptime what: []const u8) !void {
    var waited: u32 = 0;
    while (waited <= 3000) : (waited += 100) {
        var d = try h.dump(g);
        defer d.deinit();
        const dw = d.value.windows[0];
        for (dw.tabs[dw.active].panes.?) |p| {
            if (p.focused and hwndOf(p.hwnd) == pane and keyboardFocus(win) == pane) {
                return h.expect(true, what, .{});
            }
        }
        w.Sleep(100);
    }
    return h.fail(what ++ " (focus didn't get there)", .{});
}

/// The left edge of the divider that spans the tab's full height.
fn rootDivider(h: *Harness, g: *Harness.Ghostty) !i32 {
    var d = try h.dump(g);
    defer d.deinit();
    const t = d.value.windows[0].tabs[0];
    for (t.dividers.?) |dv| if (dv[1] == 0 and dv[3] == t.area.?[1]) return dv[0];
    return h.fail("no full-height divider", .{});
}

/// The panes and dividers of tab `t` cover its area exactly, without
/// overlapping.
fn expectTiling(h: *Harness, t: Harness.Dump.Tab) !void {
    const area = t.area.?;
    var rects: [32][4]i32 = undefined;
    var n: usize = 0;
    for (t.panes.?) |p| {
        rects[n] = p.rect;
        n += 1;
    }
    for (t.dividers.?) |d| {
        rects[n] = d;
        n += 1;
    }
    var total: i64 = 0;
    for (rects[0..n], 0..) |a, i| {
        try h.expect(a[0] >= 0 and a[1] >= 0 and a[2] <= area[0] and a[3] <= area[1], "inside the tab: {any}", .{a});
        total += @as(i64, a[2] - a[0]) * (a[3] - a[1]);
        for (rects[i + 1 .. n]) |b| {
            const overlap = a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3];
            try h.expect(!overlap, "{any} and {any} don't overlap", .{ a, b });
        }
    }
    try h.expect(total == @as(i64, area[0]) * area[1], "panes and dividers cover the tab exactly ({d} of {d} pixels)", .{ total, @as(i64, area[0]) * area[1] });
}

fn hwndOf(v: u64) w.HWND {
    return @ptrFromInt(v);
}

/// Pane `i` of the first window's active tab.
fn paneHwnd(h: *Harness, g: *Harness.Ghostty, i: usize) !w.HWND {
    var d = try h.dump(g);
    defer d.deinit();
    const dw = d.value.windows[0];
    const p = dw.tabs[dw.active].panes orelse return h.fail("no panes in the dump", .{});
    if (i >= p.len) return h.fail("no pane {d}", .{i});
    return hwndOf(p[i].hwnd);
}

/// Wait until the first window's active tab has `count` panes.
fn waitPanes(h: *Harness, g: *Harness.Ghostty, count: usize) !void {
    var waited: u32 = 0;
    var last: usize = 0;
    while (waited <= 10000) : (waited += 200) {
        var d = try h.dump(g);
        defer d.deinit();
        const dw = d.value.windows[0];
        last = if (dw.tabs[dw.active].panes) |p| p.len else 0;
        if (last == count) return;
        w.Sleep(200);
    }
    return h.fail("the tab has {d} pane(s), expected {d}", .{ last, count });
}

/// Wait until pane `i`'s text contains `needle` at least `count` times.
fn waitPaneText(h: *Harness, g: *Harness.Ghostty, i: usize, needle: []const u8, count: usize) !void {
    var waited: u32 = 0;
    while (waited <= 10000) : (waited += 200) {
        var d = try h.dump(g);
        defer d.deinit();
        const dw = d.value.windows[0];
        if (dw.tabs[dw.active].panes) |p| if (i < p.len) {
            if (std.mem.count(u8, p[i].text orelse "", needle) >= count) return;
        };
        w.Sleep(200);
    }
    return h.fail("pane {d} doesn't show '{s}' {d} time(s)", .{ i, needle, count });
}

/// The keyboard focus of the thread that owns `hwnd`.
fn keyboardFocus(hwnd: w.HWND) ?w.HWND {
    var info: w.GUITHREADINFO = .{};
    if (w.GetGUIThreadInfo(w.GetWindowThreadProcessId(hwnd, null), &info) == 0) return null;
    return info.hwndFocus;
}

/// The active window of the thread that owns `hwnd`.
fn activeWindow(hwnd: w.HWND) ?w.HWND {
    var info: w.GUITHREADINFO = .{};
    if (w.GetGUIThreadInfo(w.GetWindowThreadProcessId(hwnd, null), &info) == 0) return null;
    return info.hwndActive;
}

/// Wait until window `win` has `count` tabs.
fn waitWindowTabs(h: *Harness, g: *Harness.Ghostty, win: w.HWND, count: usize) !void {
    var waited: u32 = 0;
    var last: usize = 0;
    while (waited <= 10000) : (waited += 200) {
        var d = try h.dump(g);
        defer d.deinit();
        for (d.value.windows) |dw| {
            if (dw.hwnd != @intFromPtr(win)) continue;
            last = dw.tabs.len;
            if (last == count) return;
        }
        w.Sleep(200);
    }
    return h.fail("window has {d} tab(s), expected {d}", .{ last, count });
}

fn framesPresented(h: *Harness, g: *Harness.Ghostty) !u32 {
    var d = try h.dump(g);
    defer d.deinit();
    return d.value.windows[0].tabs[0].frames orelse h.fail("no frame count in the dump", .{});
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
