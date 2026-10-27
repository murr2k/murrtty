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
    .{ .name = "copy-keys", .about = "a word selected by a double click is copied 10 times each by Ctrl+Insert, the numpad's Ctrl+Ins (NumLock off) and Ctrl+Shift+C; the numpad's Left moves, its Shift+Ins pastes", .run = copyKeys },
    .{ .name = "alt-f4", .about = "Alt+F4 asks, then closes", .run = altF4 },
    .{ .name = "clipboard-queue", .about = "a burst of OSC 52 writes asks one dialog at a time", .run = clipboardQueue },
    .{ .name = "clipboard-dialog", .about = "GTK's clipboard dialog: the whole text in a box, Deny the default, remember for OSC 52; an unsafe paste's warning", .run = clipboardDialog },
    .{ .name = "system-menu", .about = "murrtty's items in the system menu (Alt+Space) after Windows' own: About, New Tab; its Close still asks", .run = systemMenu },
    .{ .name = "close-all", .about = "close-all asks and disables the other windows meanwhile", .run = closeAll },
    .{ .name = "window-size", .about = "window-width/height give the exact grid", .run = windowSize },
    .{ .name = "links", .about = "Ctrl+click links: programs and UNC paths blocked, web opens, other schemes ask", .run = links },
    .{ .name = "links-open", .about = "links really open: a test protocol and file type registered in HKCU", .run = linksOpen },
    .{ .name = "present", .about = "background-opacity doesn't darken the (opaque) window; exact background pixels", .run = present },
    .{ .name = "theme", .about = "window-theme: caption colors, OSC 11 following, and the color scheme reaching terminals", .run = theme },
    .{ .name = "resize", .about = "resizing relays out the terminal, and the edge stays the background color", .run = resize },
    .{ .name = "resize-overlay", .about = "the grid size shows while a pane resizes: after-first, never, always, position, duration", .run = resizeOverlay },
    .{ .name = "context-menu", .about = "right-click opens GTK's menu with bindings and grayed entries; Copy, Paste, New Tab, Close Tab (which asks)", .run = contextMenu },
    .{ .name = "search", .about = "Ctrl+Shift+F search box: counter, Enter/Shift+Enter and buttons, Escape, reopening, search_selection", .run = search },
    .{ .name = "command-palette", .about = "Ctrl+Shift+P palette: supported commands only, filter, Enter runs New Tab, Focus: jumps (also to another window), row click, Escape and outside click close", .run = commandPalette },
    .{ .name = "header-bar", .about = "GTK's header bar: with one tab the strip shows its buttons (\"+\" opens a tab); fullscreen and gtk-titlebar = false hide it; window-show-tab-bar = never keeps the buttons without tabs", .run = headerBar },
    .{ .name = "tab-details", .about = "the strip's font (window-title-font-family), icons at the DPI, tooltips (title and directory, a button's binding), window-new-tab-position = end", .run = tabDetails },
    .{ .name = "tab-overflow", .about = "twelve tabs in a narrow window scroll between chevrons and with the wheel; the list button and toggle_tab_overview list them", .run = tabOverflow },
    .{ .name = "tab-buttons", .about = "the arrow beside + opens the split menu; the menu button opens GTK's main menu (New Tab, Command Palette, About murrtty)", .run = tabButtons },
    .{ .name = "tab-menu", .about = "a tab's right-click menu: Change Tab Title, Close Tab, Close Other Tabs, Close Tabs to the Right, on the tab clicked; graying", .run = tabMenu },
    .{ .name = "bell", .about = "bell-features title: a bell before the tab's title and caption until input; a background tab's mark until selected", .run = bell },
    .{ .name = "status-overlays", .about = "link preview, read-only badge, key sequence and table, renderer panel, toasts (copy, reload), child-exited banner (Close, any key)", .run = statusOverlays },
    .{ .name = "titles", .about = "rename prompts (tab, terminal) over program titles, blank restores, Cancel, set_window_title, copy_title_to_clipboard, double-click a tab", .run = titles },
    .{ .name = "scrollbar", .about = "overlay scrollbar: none without scrollback, shows on a move, widens pressed, drag to the top, track click pages, fades, none on the alternate screen, scrollbar = never", .run = scrollbar },
    .{ .name = "config-errors", .about = "config errors show a dialog; Open Configuration, fix, Reload; Ctrl+, opens the file", .run = configErrors },
    .{ .name = "config-folder", .about = "murrtty's own config wins, Ghostty's is read when it has none, Ctrl+, opens the file in effect; TERM_PROGRAM is murrtty", .run = configFolder },
    .{ .name = "launch-context", .about = "from a shell: the shell's directory; from a shortcut: home; a POSIX SHELL is ignored", .run = launchContext },
    .{ .name = "cli", .about = "CLI actions with output on a pipe: +version; +validate-config exits 0 for a valid file, 1 naming the problem for an invalid one", .run = cli },
    .{ .name = "fonts", .about = "a font-family's bold and italic faces are found (Consolas)", .run = fonts },
    .{ .name = "output-frames", .about = "output that arrives with no key pressed is drawn", .run = outputFrames },
    .{ .name = "background-close", .about = "a tab closing in a background window leaves the active window active", .run = backgroundClose },
    .{ .name = "focus-background-tab", .about = "a tab that never got the focus doesn't stay focused in the core", .run = focusBackgroundTab },
    .{ .name = "splits", .about = "Ctrl+Shift+O/E split panes that tile the tab; closing panes moves focus as designed", .run = splits },
    .{ .name = "split-commands", .about = "goto_split, toggle_split_zoom (hidden panes stop drawing), resize_split, equalize_splits, minimums", .run = splitCommands },
    .{ .name = "split-mouse", .about = "dragging a divider, Esc (none of that keystroke reaches the core), double-click to equalize, the grip band", .run = splitMouse },
    .{ .name = "split-dim", .about = "unfocused panes are dimmed with unfocused-split-fill/-opacity; the dividers follow the focused pane's background, or split-divider-color", .run = splitDim },
    .{ .name = "split-grip", .about = "the grip band stops 64 px from a divider; a band picks the divider on its own side", .run = splitGrip },
    .{ .name = "split-all", .about = "an all: new_split binding splits every pane of ten tabs at once", .run = splitAll },
    .{ .name = "focus-follows-mouse", .about = "the mouse moving over a pane focuses it; not a pane moving under it, nor in an inactive window", .run = focusFollowsMouse },
    .{ .name = "pwd", .about = "OSC 9;9 and OSC 7 set the working directory; new tabs start there; relative links resolve against it", .run = pwdReports },
    .{ .name = "console-keys", .about = "a console program reads Shift+Left, Ctrl+C, Ctrl+Shift+C and Shift+Enter whole (win32-input-mode)", .run = consoleKeys },
    .{ .name = "pwsh-keys", .about = "win32-input-mode: Shift+arrows highlight PowerShell's text, Ctrl+C and Ctrl+Shift+C copy it, Shift+Enter adds a line", .run = pwshKeys },
    .{ .name = "pwsh-integration", .about = "PowerShell 7 and 5.1: the folder carries to new tabs, idle tabs close without asking, jump_to_prompt", .run = pwshIntegration },
    .{ .name = "cmd-integration", .about = "cmd (and Clink with GHOSTTY_GUI_CLINK): the folder carries to new tabs, idle tabs close without asking", .run = cmdIntegration },
    .{ .name = "cwd-fallback", .about = "without shell integration, cmd's cd still carries to new tabs and relative links", .run = cwdFallback },
    .{ .name = "stress-panes", .about = "16 panes flooding output keep rendering (GHOSTTY_GUI_STRESS=1)", .run = stressPanes },
    .{ .name = "overlay-host", .about = "spike S1: a layered child window over each pane stays clean while output floods and the window resizes (GHOSTTY_GUI_SPIKE=1)", .run = overlayHost },
    .{ .name = "snapshot", .about = "pictures of the window (one tab, a split) for comparing with GTK's by eye, off-screen (GHOSTTY_GUI_SNAPSHOT=folder)", .run = snapshot },
    .{ .name = "transparency", .about = "spike S2: background-opacity through DWM blur-behind, over a green backdrop ON SCREEN (GHOSTTY_GUI_ONSCREEN=1)", .run = transparency },
};

/// Home as the working directory: the harness's launches count as from a
/// shell (see launch-context), which would start each terminal in its long
/// scenario folder, and text typed after that prompt wraps. No shell
/// integration (the scenarios for it turn it on), so closing at an idle
/// prompt still asks, as most scenarios expect.
const base_config =
    \\command = cmd.exe
    \\window-show-tab-bar = auto
    \\working-directory = home
    \\shell-integration = none
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
    try expectDialogText(h, g, "Quit murrtty?", "All terminal sessions will be terminated.");
    h.answer(g, dlg, w.IDYES);
    const code = g.waitExit(10000);
    try h.expect(code != null and code.? == 0, "exits with code 0 after quit (got {?d})", .{code});
}

fn launch(h: *Harness) anyerror!void {
    var g = try start(h, "launch", "", ">");
    defer g.deinit();
    const win = try h.mainWindow(&g);
    const surf = try h.surface(&g, win);

    var bar: i32 = 0;
    {
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(d.value.windows.len == 1, "one window", .{});
        const t = d.value.windows[0].tabs;
        try h.expect(t.len == 1, "one tab", .{});
        try h.expect((t[0].cols orelse 0) > 0 and (t[0].rows orelse 0) > 0, "grid {?d}x{?d}", .{ t[0].cols, t[0].rows });
        const dw = d.value.windows[0];
        try h.expect(dw.header.visible and !dw.tab_bar.visible, "one tab: the header bar, no tab row", .{});
        try h.expect(
            std.mem.eql(u8, dw.header.font, "Adwaita Sans Text") and std.mem.eql(u8, dw.tab_bar.font, "Adwaita Sans Text"),
            "the chrome is in GNOME's font, the bundled Adwaita Sans ('{s}', '{s}')",
            .{ dw.header.font, dw.tab_bar.font },
        );
        bar = dw.header.height;
    }

    // The default terminal area is 960x600 DIPs at the window's DPI, below
    // the header bar.
    const dpi = w.GetDpiForWindow(win);
    var r: w.RECT = .{};
    _ = w.GetClientRect(win, &r);
    const ew = (960 * dpi + 95) / 96;
    const eh = (600 * dpi + 95) / 96 + @as(u32, @intCast(bar));
    try h.expect(r.right == ew and r.bottom == eh, "client {d}x{d} at dpi {d}, expected {d}x{d}", .{ r.right, r.bottom, dpi, ew, eh });

    try quit(h, &g, surf);
}

/// Captures need a composed window, which a hidden desktop doesn't get, so
/// this Ghostty runs on the user's desktop far off-screen, driven from a
/// thread on that desktop, and is terminated rather than closed through a
/// dialog that would appear on screen.
fn pixels(h: *Harness) anyerror!void {
    if (h.capturesWork()) |why| return h.skip("{s}", .{why});
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

/// Opt-in (GHOSTTY_GUI_SNAPSHOT = a folder): pictures of the whole window,
/// for comparing with Ghostty's GTK app by eye: one tab, split right, then
/// a second tab (snapshot-tab.bmp, snapshot-split.bmp, snapshot-tabs.bmp).
/// Off-screen on the user's
/// desktop, like pixels; no menus, which Windows would pull on screen.
fn snapshot(h: *Harness) anyerror!void {
    var dir_w: [260:0]u16 = undefined;
    const n = w.GetEnvironmentVariableW(w.L("GHOSTTY_GUI_SNAPSHOT"), &dir_w, dir_w.len);
    if (n == 0 or n >= dir_w.len) return h.skip("set GHOSTTY_GUI_SNAPSHOT to a folder to run it", .{});
    if (h.capturesWork()) |why| return h.skip("{s}", .{why});
    var dir_buf: [1024]u8 = undefined;
    const dir_len = std.unicode.utf16LeToUtf8(&dir_buf, dir_w[0..n]) catch return h.fail("bad folder name", .{});
    const Ctx = struct { h: *Harness, dir: []const u8, err: ?anyerror = null };
    var ctx: Ctx = .{ .h = h, .dir = dir_buf[0..dir_len] };
    h.runOnUserDesktop(&ctx, struct {
        fn run(c: *Ctx) void {
            snapshotOffscreen(c.h, c.dir) catch |err| {
                c.err = err;
            };
        }
    }.run);
    if (ctx.err) |err| return err;
}

fn snapshotOffscreen(h: *Harness, dir: []const u8) !void {
    var g = try h.launchAt("snapshot", base_config, .offscreen);
    defer g.deinit();
    try h.waitText(&g, ">", 1, 20000);
    const win = try h.mainWindow(&g);
    for ([_][]const u8{ "snapshot-tab.bmp", "snapshot-split.bmp", "snapshot-tabs.bmp" }, 0..) |name, i| {
        if (i == 1) {
            h.key(try h.surface(&g, win), .{ .ctrl = true, .shift = true }, 'O');
            try waitPanes(h, &g, 2);
            try waitActivePaneText(h, &g, win, ">");
        }
        if (i == 2) {
            h.key(try h.surface(&g, win), .{ .ctrl = true, .shift = true }, 'T');
            try waitWindowTabs(h, &g, win, 2);
            try waitActivePaneText(h, &g, win, ">");
        }
        h.sync(win);
        w.Sleep(800);
        var img = h.capture(win) catch return h.fail("capture failed", .{});
        defer img.deinit();
        const path = try std.fmt.allocPrint(h.alloc, "{s}\\{s}", .{ dir, name });
        defer h.alloc.free(path);
        try img.save(path);
        try h.expect(true, "wrote {s} ({d}x{d})", .{ path, img.width, img.height });
        // The chrome as last painted, current even where DWM lags.
        var chrome = h.captureClient(win) catch return h.fail("client capture failed", .{});
        defer chrome.deinit();
        const chrome_path = try std.fmt.allocPrint(h.alloc, "{s}\\chrome-{s}", .{ dir, name });
        defer h.alloc.free(chrome_path);
        try chrome.save(chrome_path);
    }
}

fn typing(h: *Harness) anyerror!void {
    var g = try start(h, "typing", "", ">");
    defer g.deinit();
    const surf = try h.surface(&g, try h.mainWindow(&g));
    try h.typeText(surf, "echo ghostty-gui-test");
    h.enter(surf);
    // The command line and its output.
    try h.waitText(&g, "ghostty-gui-test", 2, 10000);

    // Ctrl+Shift+W closes the tab; the shell is running, so it asks first,
    // in GTK's words.
    h.key(surf, .{ .ctrl = true, .shift = true }, 'W');
    const dlg = try h.waitDialog(&g, 5000);
    try expectDialogText(h, &g, "Close Tab?", "All terminal sessions in this tab will be terminated.");
    h.answer(&g, dlg, w.IDCANCEL);
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
        try h.expect(dw.tab_bar.visible and dw.tab_bar.top == dw.header.height, "the tab row shows three tabs, below the header bar", .{});
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
    h.answer(&g, try h.waitDialog(&g, 5000), w.IDCANCEL);
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
        const dw = d.value.windows[0];
        try h.expect(dw.header.visible and !dw.tab_bar.visible, "with one tab again, the tab row goes", .{});
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

    // A paste while another program has the clipboard open for a moment
    // (clipboard history, a manager) waits for it rather than being lost.
    try h.setClipboard("gui-paste-held");
    var hold = try h.holdClipboard(50);
    h.key(surf, .{ .shift = true }, w.VK_INSERT);
    hold.wait();
    try h.waitText(&g, "gui-paste-held", 1, 5000);
    try h.expect(true, "a paste waits out a clipboard held open for 50 ms", .{});

    try h.setClipboard("");
    h.key(surf, .{ .ctrl = true, .shift = true }, 'A');
    h.key(surf, .{ .ctrl = true, .shift = true }, 'C');
    w.Sleep(500);
    const copied = (try h.getClipboard()) orelse "";
    defer if (copied.len > 0) h.alloc.free(copied);
    try h.expect(std.mem.indexOf(u8, copied, "gui-paste-two") != null, "Ctrl+Shift+A then C copies the screen", .{});

    try quit(h, &g, surf);
}

/// The copy keys users expect, each copying a double-clicked word ten
/// times: Ctrl+Insert on the dedicated key and on the numpad's 0/Ins with
/// NumLock off (Windows treats both as Insert), and Ctrl+Shift+C. With
/// NumLock off the numpad's other keys move, as GTK has them, and its
/// Shift+Ins pastes.
fn copyKeys(h: *Harness) anyerror!void {
    var saved = try h.saveClipboard();
    defer saved.restore();
    var g = try start(h, "copy-keys", "", ">");
    defer g.deinit();
    const surf = try h.surface(&g, try h.mainWindow(&g));

    const Way = enum { ctrl_insert, numpad_ctrl_ins, ctrl_shift_c };
    var failed: [3]u32 = @splat(0);
    var round: u32 = 0;
    while (round < 10) : (round += 1) {
        for (std.enums.values(Way)) |way| {
            var buf: [48]u8 = undefined;
            const word = try std.fmt.bufPrint(&buf, "copy-{s}-{d}", .{ @tagName(way), round });
            try h.typeText(surf, "echo ");
            try h.typeText(surf, word);
            h.enter(surf);
            try waitOutputSettled(h, &g, word);
            const at = try cellPoint(h, &g, word);
            try h.setClipboard("stale");
            // Two clicks, as a real double click reaches a pane (its class
            // takes no double clicks; the core counts the clicks).
            h.click(surf, at.x, at.y, .left);
            h.click(surf, at.x, at.y, .left);
            h.sync(surf);
            {
                var d = try h.dump(&g);
                defer d.deinit();
                const panes = d.value.windows[0].tabs[0].panes orelse return h.fail("no panes", .{});
                if (panes[0].selection != true) return h.fail("{s}: the double click selected nothing", .{word});
            }
            switch (way) {
                .ctrl_insert => h.key(surf, .{ .ctrl = true }, w.VK_INSERT),
                .numpad_ctrl_ins => h.numpadKey(surf, .{ .ctrl = true }, w.VK_INSERT),
                .ctrl_shift_c => h.key(surf, .{ .ctrl = true, .shift = true }, 'C'),
            }
            const got = (try h.getClipboard()) orelse "";
            defer if (got.len > 0) h.alloc.free(got);
            if (!std.mem.eql(u8, got, word)) {
                failed[@intFromEnum(way)] += 1;
                h.log("{s}: the clipboard holds '{s}', not '{s}'", .{ @tagName(way), got, word });
            }
        }
    }
    try h.expect(failed[0] == 0, "Ctrl+Insert copied the word 10 of 10 times (missed {d})", .{failed[0]});
    try h.expect(failed[1] == 0, "the numpad's Ctrl+Ins (NumLock off) copied it 10 of 10 times (missed {d})", .{failed[1]});
    try h.expect(failed[2] == 0, "Ctrl+Shift+C copied it 10 of 10 times (missed {d})", .{failed[2]});

    // With NumLock off the numpad's keys move rather than type digits (Left
    // typed 4): Left twice, then X, inside a typed word.
    try h.typeText(surf, "echo abc");
    h.numpadKey(surf, .{}, w.VK_LEFT);
    h.numpadKey(surf, .{}, w.VK_LEFT);
    try h.typeText(surf, "X");
    h.enter(surf);
    try h.waitText(&g, "aXbc", 2, 10000);
    try h.expect(true, "the numpad's Left (NumLock off) moves the cursor", .{});
    // And its Shift+Ins pastes.
    try h.setClipboard("numpad-paste");
    h.numpadKey(surf, .{ .shift = true }, w.VK_INSERT);
    try h.waitText(&g, "numpad-paste", 1, 5000);
    try h.expect(true, "the numpad's Shift+Ins (NumLock off) pastes", .{});
    try quit(h, &g, surf);
}

/// Wait until `word` is a whole line of the first tab with cmd's prompt
/// after it: once the prompt is out nothing scrolls, so a click computed
/// from the text lands on the word.
fn waitOutputSettled(h: *Harness, g: *Harness.Ghostty, word: []const u8) !void {
    var buf: [64]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "\n{s}\n", .{word});
    var waited: u32 = 0;
    while (waited <= 10000) : (waited += 100) {
        var d = try h.dump(g);
        defer d.deinit();
        const text = d.value.windows[0].tabs[0].text orelse "";
        if (std.mem.indexOf(u8, text, line) != null and
            std.mem.endsWith(u8, std.mem.trimEnd(u8, text, " \n"), ">")) return;
        w.Sleep(100);
    }
    return h.fail("'{s}' and the prompt after it never showed", .{word});
}

fn altF4(h: *Harness) anyerror!void {
    var g = try start(h, "alt-f4", "", ">");
    defer g.deinit();
    const surf = try h.surface(&g, try h.mainWindow(&g));
    h.key(surf, .{ .alt = true }, w.VK_F4);
    const dlg = try h.waitDialog(&g, 5000);
    try expectDialogText(h, &g, "Close Window?", "All terminal sessions in this window will be terminated.");
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

/// The clipboard confirmation (roadmap 3.9), GTK's: an OSC 52 write shows
/// its whole text in the box (the line break kept, ESC as U+241B), Deny is
/// the default, and remembering an Allow lets the next write through
/// unasked; an unsafe paste gets GTK's warning, with nothing to remember,
/// and Deny pastes nothing.
fn clipboardDialog(h: *Harness) anyerror!void {
    var saved = try h.saveClipboard();
    defer saved.restore();
    try h.setClipboard("before");
    {
        var g = try start(h, "clipboard-dialog",
            \\command = powershell.exe -NoLogo -NoProfile
            \\clipboard-write = ask
            \\
        , "PS ");
        defer g.deinit();
        const surf = try h.surface(&g, try h.mainWindow(&g));
        // "first line\nsecond\x1bline"
        try h.typeText(surf, "Write-Host -NoNewline \"$([char]27)]52;c;Zmlyc3QgbGluZQpzZWNvbmQbbGluZQ==$([char]7)\"");
        h.enter(surf);
        const dlg = try h.waitDialog(&g, 10000);
        try expectTitle(h, dlg, "Authorize Clipboard Access");
        const text = try dialogItemText(h, dlg, 100);
        defer h.alloc.free(text);
        try h.expect(std.mem.eql(u8, text, "first line\r\nsecond\u{241B}line"), "the box shows the whole text, the line break kept, ESC as a picture ('{s}')", .{text});
        try h.expect(defaultButton(dlg) == w.IDNO, "Deny is the default (got {d})", .{defaultButton(dlg)});
        const box = w.GetDlgItem(dlg, 101) orelse return h.fail("no remember box for an OSC 52 write", .{});
        var r: usize = 0;
        _ = w.SendMessageTimeoutW(box, w.BM_SETCHECK, 1, 0, w.SMTO_ABORTIFHUNG, 2000, &r);
        h.answer(&g, dlg, w.IDYES);
        try waitNoDialog(h, &g);
        try waitClipboardHas(h, "second");
        try h.expect(true, "Allow wrote the text", .{});

        // "again": remembered, so no dialog.
        try h.typeText(surf, "Write-Host -NoNewline \"$([char]27)]52;c;YWdhaW4=$([char]7)\"");
        h.enter(surf);
        try waitClipboardHas(h, "again");
        try h.expect(try h.dialogCount(&g) == 0, "remembered: the next write asks nothing", .{});
        try quit(h, &g, surf);
    }
    {
        try h.setClipboard("echo one\r\necho two");
        var g = try start(h, "clipboard-dialog-paste", "", ">");
        defer g.deinit();
        const surf = try h.surface(&g, try h.mainWindow(&g));
        h.key(surf, .{ .ctrl = true, .shift = true }, 'V');
        const dlg = try h.waitDialog(&g, 5000);
        try expectTitle(h, dlg, "Warning: Potentially Unsafe Paste");
        try h.expect(w.GetDlgItem(dlg, 101) == null, "nothing to remember for a paste", .{});
        const text = try dialogItemText(h, dlg, 100);
        defer h.alloc.free(text);
        try h.expect(std.mem.eql(u8, text, "echo one\r\necho two"), "the box shows both lines ('{s}')", .{text});
        h.answer(&g, dlg, w.IDNO);
        try waitNoDialog(h, &g);
        w.Sleep(500);
        {
            var d = try h.dump(&g);
            defer d.deinit();
            const screen = d.value.windows[0].tabs[0].text orelse "";
            try h.expect(std.mem.indexOf(u8, screen, "echo one") == null, "Deny pasted nothing", .{});
        }
        try quit(h, &g, surf);
    }
}

/// The text of dialog item `id`, another process's control (WM_GETTEXT).
fn dialogItemText(h: *Harness, dlg: w.HWND, id: c_int) ![]u8 {
    const item = w.GetDlgItem(dlg, id) orelse return h.fail("the dialog has no item {d}", .{id});
    var buf: [4096]u16 = undefined;
    var n: usize = 0;
    _ = w.SendMessageTimeoutW(item, w.WM_GETTEXT, buf.len, @bitCast(@intFromPtr(&buf)), w.SMTO_ABORTIFHUNG, 2000, &n);
    return std.unicode.utf16LeToUtf8Alloc(h.alloc, buf[0..n]);
}

/// The dialog's default button's id (DM_GETDEFID).
fn defaultButton(dlg: w.HWND) usize {
    var r: usize = 0;
    _ = w.SendMessageTimeoutW(dlg, w.DM_GETDEFID, 0, 0, w.SMTO_ABORTIFHUNG, 2000, &r);
    return r & 0xFFFF;
}

/// Wait until the clipboard's text holds `needle`.
fn waitClipboardHas(h: *Harness, needle: []const u8) !void {
    var waited: u32 = 0;
    while (waited <= 5000) : (waited += 250) {
        w.Sleep(250);
        const got = (try h.getClipboard()) orelse "";
        defer if (got.len > 0) h.alloc.free(got);
        if (std.mem.indexOf(u8, got, needle) != null) return;
    }
    return h.fail("the clipboard never held '{s}'", .{needle});
}

/// The system menu (roadmap 3.9): murrtty's items after Windows' own, with
/// access keys clear of them; About and New Tab from it, and its Close (C)
/// still closing the window, asked first.
fn systemMenu(h: *Harness) anyerror!void {
    var g = try start(h, "system-menu", "", ">");
    defer g.deinit();
    const win = try h.mainWindow(&g);
    var menu = try openSystemMenu(h, &g, win);
    {
        const items = try h.menuItems(menu);
        defer h.freeMenuItems(items);
        var close: ?usize = null;
        var new_window: ?usize = null;
        var about = false;
        var quit_item = false;
        for (items, 0..) |item, i| {
            if (std.mem.startsWith(u8, item.text, "&Close")) close = i;
            if (std.mem.startsWith(u8, item.text, "New &Window")) new_window = i;
            if (std.mem.eql(u8, item.text, "Abo&ut murrtty")) about = true;
            if (std.mem.startsWith(u8, item.text, "&Quit")) quit_item = true;
        }
        try h.expect(close != null and new_window != null and close.? < new_window.?, "murrtty's items follow Windows' Close", .{});
        try h.expect(about and quit_item, "with About murrtty and Quit", .{});
    }
    try expectModalDepth(h, &g, 1, "closes wait while the system menu is open");
    h.menuKey(menu, 'u');
    const about = try h.waitDialog(&g, 5000);
    try expectTitle(h, about, "About murrtty");
    h.answer(&g, about, w.IDOK);
    try waitNoDialog(h, &g);

    menu = try openSystemMenu(h, &g, win);
    h.menuKey(menu, 't');
    try waitWindowTabs(h, &g, win, 2);
    try h.expect(true, "its New Tab opens a tab", .{});

    // A right-click on the caption (the header bar between its buttons):
    // DefWindowProc shows the menu, with murrtty's items and closes held
    // all the same.
    var at: w.POINT = .{ .x = 0, .y = 0 };
    {
        var d = try h.dump(&g);
        defer d.deinit();
        const header = d.value.windows[0].header;
        var client: w.RECT = .{};
        _ = w.GetClientRect(win, &client);
        at = .{ .x = @divTrunc(client.right, 2), .y = @divTrunc(header.height, 2) };
    }
    try expectNcHit(h, win, .{ at.x, at.y }, w.HTCAPTION, "the header bar's middle is the caption");
    _ = w.ClientToScreen(win, &at);
    _ = w.PostMessageW(win, w.WM_CONTEXTMENU, @intFromPtr(win), w.makeLParam(at.x, at.y));
    menu = try h.waitMenu(&g, 1, 5000);
    try expectModalDepth(h, &g, 1, "closes wait while the caption's menu is open");
    h.menuKey(menu, 't');
    try waitWindowTabs(h, &g, win, 3);
    try expectModalDepth(h, &g, 0, "and the scope ends with it; its New Tab opens a tab");

    menu = try openSystemMenu(h, &g, win);
    h.menuKey(menu, 'c');
    const close = try h.waitDialog(&g, 5000);
    try expectDialogText(h, &g, "Close Window?", "All terminal sessions in this window will be terminated.");
    h.answer(&g, close, w.IDCANCEL);
    try waitNoDialog(h, &g);
    try quit(h, &g, try h.surface(&g, win));
}

/// Wait until the dump's modal depth is `depth`.
fn expectModalDepth(h: *Harness, g: *Harness.Ghostty, depth: u32, what: []const u8) !void {
    var waited: u32 = 0;
    var last: u32 = 0;
    while (waited <= 3000) : (waited += 100) {
        var d = try h.dump(g);
        defer d.deinit();
        last = d.value.modal_depth;
        if (last == depth) return h.expect(true, "{s}", .{what});
        w.Sleep(100);
    }
    return h.fail("{s}: modal depth {d}, expected {d}", .{ what, last, depth });
}

/// Open the window's system menu as Alt+Space does.
fn openSystemMenu(h: *Harness, g: *Harness.Ghostty, win: w.HWND) !w.HWND {
    _ = w.PostMessageW(win, w.WM_SYSCOMMAND, w.SC_KEYMENU, ' ');
    return h.waitMenu(g, 1, 5000);
}

fn closeAll(h: *Harness) anyerror!void {
    var g = try start(h, "close-all", "keybind = ctrl+shift+k=close_all_windows\n", ">");
    defer g.deinit();
    const first = try h.mainWindow(&g);
    const surf = try h.surface(&g, first);
    h.key(surf, .{ .ctrl = true, .shift = true }, 'N');
    w.Sleep(2500);
    const wins = try h.windows(&g, "MurrttyWindow");
    defer h.alloc.free(wins);
    try h.expect(wins.len == 2, "Ctrl+Shift+N opens a second window (got {d})", .{wins.len});

    h.key(try h.surface(&g, first), .{ .ctrl = true, .shift = true }, 'K');
    const dlg = try h.waitDialog(&g, 5000);
    try expectDialogText(h, &g, "Close All Windows?", "All terminal sessions will be terminated.");
    for (wins) |win| try h.expect(w.IsWindowEnabled(win) == 0, "every window is disabled while the dialog is open", .{});
    h.answer(&g, dlg, w.IDCANCEL);
    w.Sleep(800);
    for (wins) |win| try h.expect(w.IsWindowEnabled(win) != 0, "No re-enables every window", .{});
    const still = try h.windows(&g, "MurrttyWindow");
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

/// The dialog showing is a task dialog with `heading` and `body` (its text,
/// drawn by a DirectUIHWND, comes from the dump).
fn expectDialogText(h: *Harness, g: *Harness.Ghostty, heading: []const u8, body: []const u8) !void {
    var d = try h.dump(g);
    defer d.deinit();
    const dl = d.value.dialog;
    try h.expect(
        std.mem.eql(u8, dl.heading, heading) and std.mem.eql(u8, dl.body, body),
        "the dialog says '{s}' / '{s}'",
        .{ dl.heading, dl.body },
    );
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

/// window-theme (roadmap 0.4, 4.3): the chrome's colors as GTK's, the
/// header bar's background reported as the caption's (what DWM is also
/// asked for; caption colors need Windows 11).
fn theme(h: *Harness) anyerror!void {
    // auto (the default): Adwaita's, dark or light by the background.
    try expectChrome(h, "theme-auto", "", true, 0x2e2e32);
    try expectChrome(h, "theme-auto-light", "background = #fafafa\nforeground = #202020\n", false, 0xffffff);
    // Forced light or dark: Adwaita's.
    try expectChrome(h, "theme-light", "window-theme = light\n", false, 0xffffff);
    try expectChrome(h, "theme-dark", "window-theme = dark\n", true, 0x2e2e32);
    // ghostty: the titlebar colors, else the configured background.
    try expectChrome(h, "theme-ghostty", "window-theme = ghostty\nwindow-titlebar-background = #112233\n", true, 0x112233);

    // A program changing the background (OSC 11) leaves the chrome alone:
    // GTK's follows the configuration.
    {
        var g = try start(h, "theme-osc11", "command = powershell.exe -NoLogo -NoProfile\n", "PS ");
        defer g.deinit();
        const surf = try h.surface(&g, try h.mainWindow(&g));
        try h.typeText(surf, "Write-Host -NoNewline \"$([char]27)]11;#f0f0f0$([char]7)\"");
        h.enter(surf);
        w.Sleep(1500);
        const got = try chromeOf(h, &g);
        try h.expect(got.caption == 0x2e2e32 and got.dark, "OSC 11 leaves the chrome Adwaita's dark (got {x}, dark {})", .{ got.caption, got.dark });
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
    const path = try std.fmt.allocPrint(h.alloc, "{s}\\murrtty\\config.ghostty", .{g.dir});
    defer h.alloc.free(path);
    try h.writeFileAt(path, base_config ++ "window-theme = light\n");
    dlg = try h.waitDialog(&g, 1000);
    h.answer(&g, dlg, id_reload_config);
    try waitNoDialog(h, &g);
    w.Sleep(1500);
    try h.expect(try h.dialogCount(&g) == 0, "a config without errors shows no dialog", .{});
    const chrome = try chromeOf(h, &g);
    try h.expect(!chrome.dark and chrome.caption == 0xffffff, "Reload applied the fixed config (window-theme = light)", .{});

    // Ctrl+, opens the config file.
    const surf = try h.surface(&g, try h.mainWindow(&g));
    h.key(surf, .{ .ctrl = true }, w.VK_OEM_COMMA);
    var waited: u32 = 0;
    while (try launchCount(h, &g, "edit-config ") < 2 and waited < 5000) : (waited += 200) w.Sleep(200);
    try h.expect(try launchCount(h, &g, "edit-config ") == 2, "Ctrl+, opens the config file", .{});
    try quit(h, &g, surf);
}

/// murrtty's configuration folder (XDG_CONFIG_HOME\murrtty here, normally
/// %LOCALAPPDATA%\murrtty): its own file wins, Ghostty's is read when it has
/// none, and Ctrl+, opens the file in effect. Programs in it see
/// TERM_PROGRAM=murrtty.
fn configFolder(h: *Harness) anyerror!void {
    const own = base_config ++ "title = from-murrtty\n";
    const ghosttys = base_config ++ "title = from-ghostty\n";
    const cases = [_]struct { name: []const u8, murrtty: bool, ghostty: bool, title: []const u8, folder: []const u8 }{
        .{ .name = "config-folder-own", .murrtty = true, .ghostty = false, .title = "from-murrtty", .folder = "murrtty" },
        .{ .name = "config-folder-ghostty", .murrtty = false, .ghostty = true, .title = "from-ghostty", .folder = "ghostty" },
        .{ .name = "config-folder-both", .murrtty = true, .ghostty = true, .title = "from-murrtty", .folder = "murrtty" },
    };
    for (cases) |case| {
        var g = try h.launchWith(case.name, own, .{
            .murrtty_config = case.murrtty,
            .ghostty_config = if (case.ghostty) ghosttys else null,
        });
        defer g.deinit();
        try h.waitText(&g, ">", 1, 20000);
        try waitTabTitle(h, &g, 0, case.title);

        const surf = try h.surface(&g, try h.mainWindow(&g));
        h.key(surf, .{ .ctrl = true }, w.VK_OEM_COMMA);
        const want = try std.fmt.allocPrint(h.alloc, "edit-config {s}\\{s}\\config.ghostty", .{ g.dir, case.folder });
        defer h.alloc.free(want);
        var opened = false;
        var waited: u32 = 0;
        while (!opened and waited <= 5000) : (waited += 200) {
            var d = try h.dump(&g);
            defer d.deinit();
            for (d.value.launches) |l| {
                if (pathEql(l, want)) opened = true;
            }
            if (!opened) w.Sleep(200);
        }
        try h.expect(opened, "{s}: Ctrl+, opens the {s} folder's file", .{ case.name, case.folder });
        try quit(h, &g, surf);
    }

    var g = try start(h, "config-folder-env", "", ">");
    defer g.deinit();
    const surf = try h.surface(&g, try h.mainWindow(&g));
    try h.typeText(surf, "echo program=%TERM_PROGRAM%");
    h.enter(surf);
    try h.waitText(&g, "program=murrtty", 1, 10000);
    try quit(h, &g, surf);
}

/// The context menu (roadmap 3.1): a right press the core leaves alone
/// (right-click-action = context-menu) selects the word and opens GTK's
/// menu, with key bindings, and grayed entries for what can't run; its
/// Copy, Paste, New Tab and Close Tab work, and Close Tab still asks.
fn contextMenu(h: *Harness) anyerror!void {
    var saved = try h.saveClipboard();
    defer saved.restore();
    var g = try start(h, "context-menu", "", ">");
    defer g.deinit();
    const win = try h.mainWindow(&g);
    const surf = try h.surface(&g, win);
    try h.typeText(surf, "echo hello-menu");
    h.enter(surf);
    try h.waitText(&g, "hello-menu", 2, 10000);
    try h.setClipboard("from-the-clipboard");

    // On the output's word: the core selects it, and the menu opens.
    const at = try cellPoint(h, &g, "hello-menu");
    h.rightPress(surf, at.x, at.y);
    var menu = try h.waitMenu(&g, 1, 5000);
    {
        // The menu's loop runs in a modal scope, so close requests wait;
        // other windows stay enabled. (The dump is answered from that loop.)
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(d.value.modal_depth == 1 and d.value.windows[0].enabled, "the menu runs in a modal scope (depth {d})", .{d.value.modal_depth});
    }
    {
        const items = try h.menuItems(menu);
        defer h.freeMenuItems(items);
        try h.expect(items.len == 12, "twelve entries (got {d})", .{items.len});
        // Copy is bound to Ctrl+Shift+C and Ctrl+Insert; the core's reverse
        // map keeps the binding added last, as GTK's menu shows too.
        try h.expect(std.mem.startsWith(u8, items[0].text, "&Copy\tCtrl+") and !items[0].grayed, "Copy, with its binding, enabled over a selection ('{s}')", .{items[0].text});
        try h.expect(std.mem.startsWith(u8, items[1].text, "&Paste\t") and !items[1].grayed, "Paste, enabled with text on the clipboard ('{s}')", .{items[1].text});
        try h.expect(items[2].grayed, "Notify on Next Command Finish is grayed", .{});
        try h.expect(items[3].separator and items[6].separator and items[10].separator, "separators where GTK has them", .{});
        try h.expect(items[7].submenu and items[8].submenu and items[9].submenu and items[11].submenu, "Split, Tab, Window and Config submenus", .{});
    }
    h.menuKey(menu, 'c');
    try waitNoMenu(h, &g);
    try waitClipboard(h, "hello-menu");

    h.rightPress(surf, at.x, at.y);
    menu = try h.waitMenu(&g, 1, 5000);
    h.menuKey(menu, 'p');
    try waitNoMenu(h, &g);
    try h.waitText(&g, "hello-menu", 3, 5000);
    try h.expect(true, "Paste typed the clipboard at the prompt", .{});

    // Tab > New Tab; Change Tab Title is there too (roadmap 3.5).
    h.rightPress(surf, at.x, at.y);
    menu = try h.waitMenu(&g, 1, 5000);
    h.menuKey(menu, 't');
    var sub = try h.waitMenu(&g, 2, 5000);
    {
        const items = try h.menuItems(sub);
        defer h.freeMenuItems(items);
        // (Never index an empty list: a panic skips the clipboard's restore.)
        if (items.len != 3) return h.fail("the Tab submenu has {d} items, not 3", .{items.len});
        try h.expect(!items[0].grayed and std.mem.startsWith(u8, items[0].text, "Change Tab &Title..."), "Tab: Change Tab Title, enabled ('{s}')", .{items[0].text});
        try h.expect(std.mem.eql(u8, items[1].text, "&New Tab\tCtrl+Shift+T") and !items[1].grayed, "New Tab with its binding ('{s}')", .{items[1].text});
    }
    h.menuKey(sub, 'n');
    try waitNoMenu(h, &g);
    try waitWindowTabs(h, &g, win, 2);

    // Close Tab from the new tab's menu: its shell runs, so it asks first.
    const second = try h.surface(&g, win);
    try waitActivePaneText(h, &g, win, ">");
    for ([_]c_int{ w.IDCANCEL, w.IDYES }) |answer| {
        h.rightPress(second, 40, 20);
        menu = try h.waitMenu(&g, 1, 5000);
        h.menuKey(menu, 't');
        sub = try h.waitMenu(&g, 2, 5000);
        h.menuKey(sub, 'c');
        const dlg = try h.waitDialog(&g, 5000);
        h.answer(&g, dlg, answer);
        try waitNoDialog(h, &g);
        try waitWindowTabs(h, &g, win, if (answer == w.IDCANCEL) 2 else 1);
    }
    // A program reporting the mouse takes the right button (the core says
    // so, and no menu opens), but no shell here can turn reporting on:
    // ConPTY keeps a console program's DECSET 1000 to itself.
    const last = try h.surface(&g, win);

    // With nothing selected (a click on a blank cell clears the selection,
    // and a right press there selects no word), Copy is grayed.
    {
        var d = try h.dump(&g);
        defer d.deinit();
        const client = d.value.windows[0].client;
        const x = @divTrunc(client[0], 2);
        const y = client[1] - 20;
        h.click(last, x, y, .left);
        w.Sleep(200);
        h.rightPress(last, x, y);
    }
    menu = try h.waitMenu(&g, 1, 5000);
    {
        const items = try h.menuItems(menu);
        defer h.freeMenuItems(items);
        try h.expect(items[0].grayed, "Copy is grayed with nothing selected", .{});
    }
    h.menuKey(menu, 0x1b);
    try waitNoMenu(h, &g);
    {
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(d.value.menus_shown == 6, "six menus shown in all (got {d})", .{d.value.menus_shown});
    }
    try quit(h, &g, last);
}

/// Wait until window `win`'s active tab's first pane shows `needle`.
fn waitActivePaneText(h: *Harness, g: *Harness.Ghostty, win: w.HWND, needle: []const u8) !void {
    var waited: u32 = 0;
    while (waited <= 10000) : (waited += 100) {
        var d = try h.dump(g);
        defer d.deinit();
        for (d.value.windows) |dw| {
            if (dw.hwnd != @intFromPtr(win)) continue;
            const panes = dw.tabs[dw.active].panes orelse continue;
            const text = panes[0].text orelse continue;
            if (std.mem.indexOf(u8, text, needle) != null) return;
        }
        w.Sleep(100);
    }
    return h.fail("the active pane never showed '{s}'", .{needle});
}

/// Search (roadmap 3.2): Ctrl+Shift+F opens the box over the pane and
/// focuses its field; typing searches (the core highlights, the box counts
/// "n/m"); Enter and Shift+Enter, and the buttons, step through matches;
/// Escape closes it and gives the keyboard back; opening again searches
/// for what the field holds; search_selection fills it with the selection.
fn search(h: *Harness) anyerror!void {
    var g = try start(h, "search", "keybind = ctrl+shift+g=search_selection\n", ">");
    defer g.deinit();
    const win = try h.mainWindow(&g);
    const surf = try h.surface(&g, win);
    const line = "apple banana apple cherry apple";
    try h.typeText(surf, "echo " ++ line);
    h.enter(surf);
    try h.waitText(&g, "cherry apple", 2, 10000);
    // A background pixel of the output's first "apple" and of "cherry".
    const apple = try cellTop(h, &g, line, 1);
    const cherry = try cellTop(h, &g, line, 21);
    const plain = try h.probe(&g, apple.x, apple.y);

    h.key(surf, .{ .ctrl = true, .shift = true }, 'F');
    var box = try waitSearch(h, &g, true);
    const edit = hwndOf(box.edit);
    try h.expect(keyboardFocus(win) == edit, "Ctrl+Shift+F shows the box with the keyboard in its field", .{});

    // Six matches: three in the command line, three in its output. They
    // highlight; the rest doesn't.
    try h.typeText(edit, "apple");
    box = try waitCounter(h, &g, "/6");
    const hit = try h.probe(&g, apple.x, apple.y);
    const miss = try h.probe(&g, cherry.x, cherry.y);
    try h.expect(hit != plain and miss == plain, "matches highlight (#{x:0>6} on #{x:0>6}, other text #{x:0>6})", .{ hit, plain, miss });
    h.key(edit, .{}, w.VK_RETURN);
    box = try waitCounter(h, &g, "1/6");
    h.key(edit, .{}, w.VK_RETURN);
    box = try waitCounter(h, &g, "2/6");
    h.key(edit, .{ .shift = true }, w.VK_RETURN);
    box = try waitCounter(h, &g, "1/6");
    // GTK's buttons: up goes to the next match (upward, as the core counts
    // from the newest), down to the previous, wrapping.
    const box_hwnd = w.GetParent(edit) orelse return h.fail("the field has no box", .{});
    const up = w.GetDlgItem(box_hwnd, 2) orelse return h.fail("no up button", .{});
    const down = w.GetDlgItem(box_hwnd, 3) orelse return h.fail("no down button", .{});
    _ = w.PostMessageW(up, w.BM_CLICK, 0, 0);
    box = try waitCounter(h, &g, "2/6");
    _ = w.PostMessageW(down, w.BM_CLICK, 0, 0);
    box = try waitCounter(h, &g, "1/6");
    _ = w.PostMessageW(down, w.BM_CLICK, 0, 0);
    box = try waitCounter(h, &g, "6/6");
    // GTK's search entry keys too. Ctrl+Shift+G is bound to
    // search_selection here, which is no application shortcut, so the
    // field keeps it.
    h.key(edit, .{ .ctrl = true }, 'G');
    box = try waitCounter(h, &g, "1/6");
    h.key(edit, .{ .ctrl = true, .shift = true }, 'G');
    box = try waitCounter(h, &g, "6/6");

    h.key(edit, .{}, w.VK_ESCAPE);
    box = try waitSearch(h, &g, false);
    try h.expect(!box.visible, "Escape closes the box", .{});
    try h.expect(keyboardFocus(win) == surf, "and the pane has the keyboard again", .{});

    h.key(surf, .{ .ctrl = true, .shift = true }, 'F');
    box = try waitSearch(h, &g, true);
    try h.expect(std.mem.eql(u8, box.textSlice(), "apple"), "opening again keeps the field ('{s}')", .{box.textSlice()});
    box = try waitCounter(h, &g, "/6");

    // An application shortcut works from the field (GTK's accelerators):
    // Ctrl+Shift+N opens a window. Closing that one gives the keyboard back
    // to the field, which had it (roadmap 3.0's focus target).
    h.key(edit, .{ .ctrl = true, .shift = true }, 'N');
    const other = try waitOtherWindow(h, &g, win);
    h.key(try h.surface(&g, other), .{ .alt = true }, w.VK_F4);
    h.answer(&g, try h.waitDialog(&g, 5000), w.IDYES);
    try waitWindowCount(h, &g, 1);
    try waitKeyboard(h, win, edit, "the field has the keyboard again once its window is active");
    h.key(edit, .{}, w.VK_ESCAPE);
    _ = try waitSearch(h, &g, false);

    // Double-click "banana" to select it, then search_selection.
    const at = try cellPoint(h, &g, line);
    const banana_x = at.x + @as(c_int, @intCast((try paneCell(h, &g))[0])) * 6;
    h.click(surf, banana_x, at.y, .left);
    h.click(surf, banana_x, at.y, .left);
    // Before Ctrl+Shift+G holds its modifiers, or the clicks read them.
    h.sync(surf);
    h.key(surf, .{ .ctrl = true, .shift = true }, 'G');
    box = try waitSearch(h, &g, true);
    try h.expect(std.mem.eql(u8, box.textSlice(), "banana"), "search_selection fills the field ('{s}')", .{box.textSlice()});
    box = try waitCounter(h, &g, "/2");
    h.key(hwndOf(box.edit), .{}, w.VK_ESCAPE);
    _ = try waitSearch(h, &g, false);
    try quit(h, &g, surf);
}

const SearchState = struct {
    active: bool = false,
    visible: bool = false,
    focused: bool = false,
    edit: u64 = 0,
    text: [128]u8 = undefined,
    text_len: usize = 0,
    counter: [32]u8 = undefined,
    counter_len: usize = 0,

    fn textSlice(self: *const SearchState) []const u8 {
        return self.text[0..self.text_len];
    }
    fn counterSlice(self: *const SearchState) []const u8 {
        return self.counter[0..self.counter_len];
    }
};

/// The first pane's search box, from a fresh dump.
fn searchState(h: *Harness, g: *Harness.Ghostty) !SearchState {
    var d = try h.dump(g);
    defer d.deinit();
    const dw = d.value.windows[0];
    const panes = dw.tabs[dw.active].panes orelse return h.fail("no panes in the dump", .{});
    const s = panes[0].search orelse return h.fail("no search in the dump", .{});
    var r: SearchState = .{ .active = s.active, .visible = s.visible, .focused = s.focused, .edit = s.edit };
    r.text_len = @min(s.text.len, r.text.len);
    @memcpy(r.text[0..r.text_len], s.text[0..r.text_len]);
    r.counter_len = @min(s.counter.len, r.counter.len);
    @memcpy(r.counter[0..r.counter_len], s.counter[0..r.counter_len]);
    return r;
}

fn waitSearch(h: *Harness, g: *Harness.Ghostty, active: bool) !SearchState {
    var waited: u32 = 0;
    while (waited <= 5000) : (waited += 100) {
        const s = try searchState(h, g);
        if (s.active == active and s.visible == active) return s;
        w.Sleep(100);
    }
    return h.fail("the search box didn't {s}", .{if (active) "open" else "close"});
}

/// Wait until the counter ends with `suffix` ("1/6", or "/6" for any).
fn waitCounter(h: *Harness, g: *Harness.Ghostty, suffix: []const u8) !SearchState {
    var last: SearchState = .{};
    var waited: u32 = 0;
    while (waited <= 5000) : (waited += 100) {
        last = try searchState(h, g);
        if (std.mem.endsWith(u8, last.counterSlice(), suffix) and
            (suffix[0] == '/' or std.mem.eql(u8, last.counterSlice(), suffix)))
        {
            try h.expect(true, "the counter reads {s}", .{last.counterSlice()});
            return last;
        }
        w.Sleep(100);
    }
    return h.fail("the counter reads '{s}', not '{s}'", .{ last.counterSlice(), suffix });
}

/// The command palette (roadmap 3.3): Ctrl+Shift+P opens it over the
/// window with the keyboard in its filter, listing the commands this
/// runtime performs (each with its action beneath) and a "Focus:" entry
/// per terminal (with where it is); typing filters; Enter runs the
/// selected command once it has closed, also one Down moved to; a click
/// runs the row it lands on; a jump entry brings its terminal's tab
/// forward, also from another window; Escape, a click on the dimmed
/// window, and its own binding in the filter close it and give the
/// keyboard back.
fn commandPalette(h: *Harness) anyerror!void {
    var g = try start(h, "command-palette", "", ">");
    defer g.deinit();
    const win = try h.mainWindow(&g);
    const surf = try h.surface(&g, win);

    // A config change first: the config loaded at start holds the default
    // entries' titles as constants, a changed one copies of them (freed with
    // it). Windows switching between light and dark reloads the config, and
    // one of the two is a change.
    try h.setSystemDark(&g, true);
    try h.setSystemDark(&g, false);

    h.key(surf, .{ .ctrl = true, .shift = true }, 'P');
    var p = try waitPalette(h, &g, win, true);
    try h.expect(keyboardFocus(win) == hwndOf(p.edit), "Ctrl+Shift+P opens it with the keyboard in its filter", .{});
    try h.expect(p.count > 20, "it lists the commands ({d})", .{p.count});
    try h.expect(p.has("New Tab"), "New Tab is there", .{});
    try h.expect(p.hasPrefix("Focus: "), "and a jump to the terminal", .{});
    try h.expect(!p.has("Toggle Inspector") and !p.has("Move Tab to New Window"), "commands this runtime lacks are not", .{});
    try h.expect(p.has("Change Tab Title\u{2026}"), "the title prompts are (roadmap 3.5)", .{});
    try h.expect(!p.has("Copy Selection as HTML to Clipboard") and !p.has("Paste from Selection"), "nor ones whose argument it can't honor", .{});

    // The app's config changes while it is open, again and again (the app
    // is light after the two above, so each switch is a change), each time
    // freeing the one before. The palette keeps its own copy of every entry.
    // Reading the freed config's would read memory Debug builds overwrite or
    // unmap, unless a new copy of the config happens to land there, so each
    // change is another chance to catch it: the dump reads every title.
    for ([_]bool{ true, false, true, false }) |dark| {
        try h.setSystemDark(&g, dark);
        const after = try paletteState(h, &g, win);
        if (after.count != p.count or !after.has("New Tab")) {
            return h.fail("after the config changed it lists {d} rows, first '{s}'", .{ after.count, after.first() });
        }
    }
    try h.expect(true, "it lists the same entries while the config changes under it", .{});
    try h.typeText(hwndOf(p.edit), "new tab");
    p = try waitPaletteFirst(h, &g, win, "new tab", "New Tab");
    try h.expect(std.mem.eql(u8, p.firstDetail(), "new_tab"), "with its action beneath ('{s}')", .{p.firstDetail()});
    h.key(hwndOf(p.edit), .{}, w.VK_RETURN);
    _ = try waitPalette(h, &g, win, false);
    try waitWindowTabs(h, &g, win, 2);
    w.Sleep(500);
    const second = try h.surface(&g, win);
    try h.expect(keyboardFocus(win) == second, "Enter runs New Tab, and its pane has the keyboard", .{});

    // The first tab's terminal sorts first among the jumps: its title, or
    // the same title and the earlier tab.
    h.key(second, .{ .ctrl = true, .shift = true }, 'P');
    p = try waitPalette(h, &g, win, true);
    try h.typeText(hwndOf(p.edit), "focus:");
    p = try waitPaletteFirst(h, &g, win, "focus:", "Focus: ");
    try h.expect(std.mem.startsWith(u8, p.firstDetail(), "Tab 1"), "a jump says where its terminal is ('{s}')", .{p.firstDetail()});
    h.key(hwndOf(p.edit), .{}, w.VK_RETURN);
    _ = try waitPalette(h, &g, win, false);
    try waitActiveTab(h, &g, win, 0);
    try h.expect(keyboardFocus(win) == surf, "a jump entry brings its tab forward with the keyboard in its pane", .{});

    h.key(surf, .{ .ctrl = true, .shift = true }, 'P');
    p = try waitPalette(h, &g, win, true);
    h.key(hwndOf(p.edit), .{}, w.VK_ESCAPE);
    _ = try waitPalette(h, &g, win, false);
    try h.expect(keyboardFocus(win) == surf, "Escape closes it and gives the keyboard back", .{});

    h.key(surf, .{ .ctrl = true, .shift = true }, 'P');
    p = try waitPalette(h, &g, win, true);
    try h.expect(childAt(win, 10, 10) == hwndOf(p.dim), "the dimming covers the window, above the panes", .{});
    _ = w.PostMessageW(hwndOf(p.dim), w.WM_LBUTTONDOWN, w.MK_LBUTTON, 10 << 16 | 10);
    _ = try waitPalette(h, &g, win, false);
    try h.expect(keyboardFocus(win) == surf, "a click outside it closes it too", .{});

    // Its own binding works in the filter (an application shortcut).
    h.key(surf, .{ .ctrl = true, .shift = true }, 'P');
    p = try waitPalette(h, &g, win, true);
    h.key(hwndOf(p.edit), .{ .ctrl = true, .shift = true }, 'P');
    _ = try waitPalette(h, &g, win, false);
    try h.expect(keyboardFocus(win) == surf, "Ctrl+Shift+P in the filter closes it", .{});

    // Down moves to another row; Enter runs that one.
    h.key(surf, .{ .ctrl = true, .shift = true }, 'P');
    p = try waitPalette(h, &g, win, true);
    try h.typeText(hwndOf(p.edit), "tab");
    p = try waitPaletteText(h, &g, win, "tab");
    const row = p.index("New Tab") orelse return h.fail("no New Tab row for 'tab'", .{});
    try h.expect(row > 0 and row < 10, "New Tab is row {d}, not the first, and in view", .{row});
    for (0..row) |_| h.key(hwndOf(p.edit), .{}, w.VK_DOWN);
    p = try waitPaletteSelected(h, &g, win, row);
    h.key(hwndOf(p.edit), .{}, w.VK_RETURN);
    _ = try waitPalette(h, &g, win, false);
    try waitWindowTabs(h, &g, win, 3);
    try h.expect(true, "Down moves to it, and Enter runs it", .{});
    w.Sleep(500);

    // A click runs the row it lands on, not the selected one.
    h.key(try h.surface(&g, win), .{ .ctrl = true, .shift = true }, 'P');
    p = try waitPalette(h, &g, win, true);
    try h.typeText(hwndOf(p.edit), "tab");
    p = try waitPaletteText(h, &g, win, "tab");
    const click_row = p.index("New Tab") orelse return h.fail("no New Tab row for 'tab'", .{});
    try h.expect(p.selected == 0 and click_row > 0, "row 0 is selected, New Tab is row {d}", .{click_row});
    const list = hwndOf(p.list);
    const y: c_int = @intCast(@as(i32, @intCast(click_row)) * p.row_height + @divTrunc(p.row_height, 2));
    {
        // What a real click there reaches: the box above the dimming, and
        // the list in it.
        const box = w.GetParent(list) orelse return h.fail("the list has no box", .{});
        var pt = [2]w.POINT{ .{ .x = 20, .y = y }, .{ .x = 20, .y = y } };
        _ = w.MapWindowPoints(list, win, pt[0..1], 1);
        _ = w.MapWindowPoints(list, box, pt[1..2], 1);
        try h.expect(childAt(win, pt[0].x, pt[0].y) == box and childAt(box, pt[1].x, pt[1].y) == list, "a click there reaches the list", .{});
    }
    const at: isize = @as(isize, y) << 16 | 20;
    _ = w.PostMessageW(list, w.WM_LBUTTONDOWN, w.MK_LBUTTON, at);
    _ = w.PostMessageW(list, w.WM_LBUTTONUP, 0, at);
    _ = try waitPalette(h, &g, win, false);
    try waitWindowTabs(h, &g, win, 4);
    try h.expect(true, "a click on row {d} runs it", .{click_row});
    w.Sleep(500);

    // From a second window, a jump to the first window's tab holding the
    // second terminal, which isn't its active tab: found by where it is,
    // it brings that window forward on that tab, keyboard in that pane.
    const where = try tabOfPane(h, &g, win, second);
    try h.expect(where.tab != where.active, "the target is tab {d}; tab {d} is active", .{ where.tab + 1, where.active + 1 });
    h.key(try h.surface(&g, win), .{ .ctrl = true, .shift = true }, 'N');
    const other = try waitOtherWindow(h, &g, win);
    w.Sleep(500);
    h.key(try h.surface(&g, other), .{ .ctrl = true, .shift = true }, 'P');
    p = try waitPalette(h, &g, other, true);
    var filter_buf: [32]u8 = undefined;
    const filter = try std.fmt.bufPrint(&filter_buf, "window 1, tab {d}", .{where.tab + 1});
    try h.typeText(hwndOf(p.edit), filter);
    p = try waitPaletteFirst(h, &g, other, filter, "Focus: ");
    var expect_buf: [32]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expect_buf, "Window 1, tab {d}", .{where.tab + 1});
    try h.expect(std.mem.startsWith(u8, p.firstDetail(), expected), "the filter matches where a terminal is ('{s}')", .{p.firstDetail()});
    h.key(hwndOf(p.edit), .{}, w.VK_RETURN);
    _ = try waitPalette(h, &g, other, false);
    try waitActiveTab(h, &g, win, where.tab);
    try waitKeyboard(h, win, second, "the jump puts the keyboard in that pane");
    try h.expect(activeWindow(win) == win, "and brings its window forward", .{});
    try quit(h, &g, second);
}

/// The bell (roadmap 3.7a, GTK's): a BEL in the pane that has the keyboard
/// shows nothing; while the keyboard is elsewhere (the pane's search
/// field), a bell before its tab's title and the caption stays until the
/// pane has it again; in a background tab the bell also marks the tab,
/// painted on the tab bar, through keys in another tab, until the tab is
/// selected, which (giving its pane the keyboard) answers it too.
fn bell(h: *Harness) anyerror!void {
    var g = try start(h, "bell", "bell-features = title,no-attention,no-system\n", ">");
    defer g.deinit();
    const win = try h.mainWindow(&g);
    const first = try h.surface(&g, win);
    const cs: Harness.Mods = .{ .ctrl = true, .shift = true };

    // The pane with the keyboard: nothing.
    try h.typeText(first, "powershell -NoProfile -Command \"[Console]::Write([char]7)\" & echo rang-here");
    h.enter(first);
    try h.waitText(&g, "rang-here", 2, 15000);
    // The bell reaches the app thread through the core's mailbox, which can
    // trail the text.
    h.sync(first);
    w.Sleep(300);
    var t = try tabState(h, &g, 0);
    try h.expect(!t.bell and !std.mem.startsWith(u8, t.caption(), "\u{1F514}"), "a bell in the pane with the keyboard shows nothing", .{});

    // The keyboard in the search field when it rings: the bell stays.
    try h.typeText(first, "powershell -NoProfile -Command \"Start-Sleep 3; [Console]::Write([char]7)\"");
    h.enter(first);
    h.key(first, cs, 'F');
    t = try waitTabStateFor(h, &g, 0, TabState.ringing, "the bell", 15000);
    try h.expect(std.mem.startsWith(u8, t.label(), "\u{1F514} ") and std.mem.startsWith(u8, t.caption(), "\u{1F514} "), "a bell before the tab's title and the caption ('{s}')", .{t.caption()});
    h.sync(first);
    w.Sleep(1000);
    t = try tabState(h, &g, 0);
    // One tab, so no tab bar (`auto`): the caption shows it.
    try h.expect(t.bell and std.mem.startsWith(u8, t.caption(), "\u{1F514} "), "it stays until answered", .{});
    {
        var d = try h.dump(&g);
        defer d.deinit();
        const panes = d.value.windows[0].tabs[0].panes orelse return h.fail("no panes", .{});
        const s = panes[0].search orelse return h.fail("no search box", .{});
        h.key(hwndOf(s.edit), .{}, w.VK_ESCAPE);
    }
    t = try waitTabState(h, &g, 0, TabState.quiet, "the bell answered");
    try h.expect(!std.mem.startsWith(u8, t.caption(), "\u{1F514}"), "the pane getting the keyboard back answers it", .{});

    // In a background tab: a bell a little later, from the first tab.
    try h.typeText(first, "powershell -NoProfile -Command \"Start-Sleep 3; [Console]::Write([char]7)\"");
    h.enter(first);
    h.key(first, cs, 'T');
    try waitWindowTabs(h, &g, win, 2);
    t = try waitTabStateFor(h, &g, 0, TabState.marked, "the background tab's mark", 15000);
    try h.expect(std.mem.startsWith(u8, t.label(), "\u{1F514} "), "a background tab's bell marks it ('{s}')", .{t.label()});
    // Keys in the other tab leave it.
    const second = try h.surface(&g, win);
    h.key(second, .{}, w.VK_SPACE);
    h.sync(second);
    w.Sleep(500);
    t = try tabState(h, &g, 0);
    try h.expect(t.attention and t.bell and t.painted_attention and t.painted_bell, "it stays through keys in another tab, painted on the tab bar", .{});
    {
        var d = try h.dump(&g);
        defer d.deinit();
        const dw = d.value.windows[0];
        try h.expect(dw.active == 1 and !std.mem.startsWith(u8, dw.caption, "\u{1F514}"), "the caption (the active tab's) has no bell", .{});
        const r = dw.tab_bar.tabs[0].rect;
        h.click(win, @divTrunc(r[0] + r[2], 2), @divTrunc(r[1] + r[3], 2), .left);
    }
    t = try waitTabState(h, &g, 0, TabState.seen, "the tab seen");
    try h.expect(true, "selecting it clears the mark and answers the bell", .{});
    try quit(h, &g, first);
}

/// The tab strip's right-click menu (roadmap 3.8): Change Tab Title, Close
/// Tab, Close Other Tabs and Close Tabs to the Right, each with its
/// binding, and Move Tab to New Window grayed (roadmap 4.5); Close Others
/// is grayed with one tab, Close to the Right on the last. It acts on the
/// tab clicked, which stays in the background.
fn tabMenu(h: *Harness) anyerror!void {
    var g = try start(h, "tab-menu", "window-show-tab-bar = always\nkeybind = ctrl+shift+f6=close_tab:other\n", ">");
    defer g.deinit();
    const win = try h.mainWindow(&g);
    const cs: Harness.Mods = .{ .ctrl = true, .shift = true };
    h.key(try h.surface(&g, win), cs, 'T');
    try waitWindowTabs(h, &g, win, 2);
    h.key(try h.surface(&g, win), cs, 'T');
    try waitWindowTabs(h, &g, win, 3);

    // On tab 0 while tab 2 is active.
    var at = try tabCenter(h, &g, 0);
    h.rightPress(win, at.x, at.y);
    var menu = try h.waitMenu(&g, 1, 5000);
    {
        const items = try h.menuItems(menu);
        defer h.freeMenuItems(items);
        const want = [_]struct { text: []const u8, grayed: bool }{
            .{ .text = "Change Tab &Title...", .grayed = false },
            .{ .text = "", .grayed = false },
            .{ .text = "&Close Tab\tCtrl+Shift+W", .grayed = false },
            .{ .text = "Close &Other Tabs\tCtrl+Shift+F6", .grayed = false },
            .{ .text = "Close Tabs to the &Right", .grayed = false },
            .{ .text = "", .grayed = false },
            .{ .text = "&Move Tab to New Window", .grayed = true },
        };
        try h.expect(items.len == want.len, "seven entries (got {d})", .{items.len});
        for (items, want) |got, exp| {
            if (exp.text.len == 0) {
                try h.expect(got.separator, "a separator where expected", .{});
                continue;
            }
            try h.expect(std.mem.eql(u8, got.text, exp.text) and got.grayed == exp.grayed, "'{s}' ({s})", .{ got.text, if (got.grayed) "grayed" else "enabled" });
        }
    }
    // Close Tabs to the Right of tab 0: the two after it (they ask, as an
    // idle prompt does without shell integration).
    h.menuKey(menu, 'r');
    var dlg = try h.waitDialog(&g, 5000);
    try expectDialogText(h, &g, "Close Tabs?", "All terminal sessions in these tabs will be terminated.");
    h.answer(&g, dlg, w.IDYES);
    try waitWindowTabs(h, &g, win, 1);
    try h.expect(true, "Close Tabs to the Right closes the tabs after the one clicked", .{});

    // With one tab, nothing else to close.
    at = try tabCenter(h, &g, 0);
    h.rightPress(win, at.x, at.y);
    menu = try h.waitMenu(&g, 1, 5000);
    {
        const items = try h.menuItems(menu);
        defer h.freeMenuItems(items);
        try h.expect(items.len == 7 and items[3].grayed and items[4].grayed and !items[2].grayed, "with one tab, Close Other Tabs and Close Tabs to the Right are grayed", .{});
    }
    _ = w.PostMessageW(menu, w.WM_KEYDOWN, w.VK_ESCAPE, 1);
    try waitNoMenu(h, &g);

    // Renaming a background tab: it stays in the background.
    h.key(try h.surface(&g, win), cs, 'T');
    try waitWindowTabs(h, &g, win, 2);
    at = try tabCenter(h, &g, 0);
    h.rightPress(win, at.x, at.y);
    menu = try h.waitMenu(&g, 1, 5000);
    h.menuKey(menu, 't');
    dlg = try h.waitDialog(&g, 5000);
    try setDialogText(h, dlg, "renamed-bg");
    const field = w.GetDlgItem(dlg, 100) orelse return h.fail("the prompt has no field", .{});
    h.key(field, .{}, w.VK_RETURN);
    try waitNoDialog(h, &g);
    {
        var d = try h.dump(&g);
        defer d.deinit();
        const dw = d.value.windows[0];
        try h.expect(std.mem.eql(u8, dw.tabs[0].tab_name, "renamed-bg") and dw.active == 1, "Change Tab Title names the tab clicked ('{s}'), which stays in the background", .{dw.tabs[0].tab_name});
    }

    // Close Other Tabs from the background tab: it is the one left.
    at = try tabCenter(h, &g, 0);
    h.rightPress(win, at.x, at.y);
    menu = try h.waitMenu(&g, 1, 5000);
    h.menuKey(menu, 'o');
    dlg = try h.waitDialog(&g, 5000);
    h.answer(&g, dlg, w.IDYES);
    try waitWindowTabs(h, &g, win, 1);
    {
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(std.mem.eql(u8, d.value.windows[0].tabs[0].tab_name, "renamed-bg"), "Close Other Tabs keeps the tab clicked", .{});
    }
    try quit(h, &g, try h.surface(&g, win));
}

/// The strip's buttons (roadmap 3.8, GTK's header bar): the arrow beside
/// "+" opens Split Up, Down, Left and Right for the active pane; the
/// button at the right end opens GTK's main menu for it (Terminal
/// Inspector grayed), whose New Tab and Command Palette work, and whose
/// About murrtty shows the About box.
fn tabButtons(h: *Harness) anyerror!void {
    var g = try start(h, "tab-buttons", "window-show-tab-bar = always\n", ">");
    defer g.deinit();
    const win = try h.mainWindow(&g);

    // The split menu: the press opens it (the menu takes the release).
    var at = try stripButton(h, &g, .new_tab_menu);
    h.press(win, at.x, at.y);
    var menu = try h.waitMenu(&g, 1, 5000);
    {
        const items = try h.menuItems(menu);
        defer h.freeMenuItems(items);
        const want = [_][]const u8{ "Split &Up", "Split &Down", "Split &Left", "Split &Right" };
        try h.expect(items.len == want.len, "the split menu has four entries (got {d})", .{items.len});
        for (items, want) |got, exp| try h.expect(std.mem.startsWith(u8, got.text, exp) and !got.grayed, "'{s}'", .{got.text});
    }
    h.menuKey(menu, 'r');
    try waitPanes(h, &g, 2);
    try h.expect(true, "Split Right from it splits the active pane", .{});

    // The main menu.
    at = try stripButton(h, &g, .menu);
    h.press(win, at.x, at.y);
    menu = try h.waitMenu(&g, 1, 5000);
    {
        const items = try h.menuItems(menu);
        defer h.freeMenuItems(items);
        try h.expect(items.len == 21, "GTK's main menu: 21 entries with separators (got {d})", .{items.len});
        if (items.len == 21) {
            try h.expect(std.mem.startsWith(u8, items[0].text, "&Copy") and std.mem.startsWith(u8, items[8].text, "&New Tab"), "Copy first, New Tab with the tab's items", .{});
            try h.expect(items[10].submenu and std.mem.eql(u8, items[10].text, "&Split"), "a Split submenu", .{});
            try h.expect(std.mem.startsWith(u8, items[16].text, "Terminal &Inspector") and items[16].grayed, "Terminal Inspector, grayed (roadmap 5.12)", .{});
            try h.expect(std.mem.eql(u8, items[19].text, "Abo&ut murrtty") and std.mem.startsWith(u8, items[20].text, "&Quit"), "About murrtty, then Quit", .{});
        }
    }
    h.menuKey(menu, 'n');
    try waitWindowTabs(h, &g, win, 2);
    try h.expect(true, "its New Tab opens a tab", .{});

    at = try stripButton(h, &g, .menu);
    h.press(win, at.x, at.y);
    menu = try h.waitMenu(&g, 1, 5000);
    h.menuKey(menu, 'u');
    const dlg = try h.waitDialog(&g, 5000);
    {
        const t = try h.title(dlg);
        defer h.alloc.free(t);
        try h.expect(std.mem.eql(u8, t, "About murrtty"), "About murrtty shows the About box ('{s}')", .{t});
    }
    h.answer(&g, dlg, w.IDOK);
    try waitNoDialog(h, &g);

    at = try stripButton(h, &g, .menu);
    h.press(win, at.x, at.y);
    menu = try h.waitMenu(&g, 1, 5000);
    h.menuKey(menu, 'e');
    {
        var waited: u32 = 0;
        const open = while (waited <= 5000) : (waited += 100) {
            var d = try h.dump(&g);
            defer d.deinit();
            if (d.value.windows[0].palette) |p| if (p.open) break true;
            w.Sleep(100);
        } else false;
        try h.expect(open, "its Command Palette opens the palette", .{});
    }
    try quit(h, &g, try h.surface(&g, win));
}

/// Many tabs (roadmap 3.8): in a narrow window twelve don't fit, so they
/// scroll between chevrons; a new tab shows; the chevrons reach the first
/// tab, the wheel the last; the list button lists them all, in order, the
/// active one selected, and filtering by a tab's line picks it. With no
/// strip, toggle_tab_overview opens the same list.
fn tabOverflow(h: *Harness) anyerror!void {
    const cs: Harness.Mods = .{ .ctrl = true, .shift = true };
    {
        // window-width counts only with window-height.
        var g = try start(h, "tab-overflow", "window-width = 50\nwindow-height = 20\nwindow-show-tab-bar = always\nkeybind = ctrl+shift+f9=goto_tab:6\n", ">");
        defer g.deinit();
        const win = try h.mainWindow(&g);
        var count: usize = 1;
        while (count < 12) : (count += 1) {
            h.key(try h.surface(&g, win), cs, 'T');
            try waitWindowTabs(h, &g, win, count + 1);
        }
        {
            var d = try h.dump(&g);
            defer d.deinit();
            const dw = d.value.windows[0];
            const bar = dw.tab_bar;
            try h.expect(bar.overflow, "twelve tabs overflow the narrow strip", .{});
            const r = bar.tabs[dw.active].rect;
            try h.expect(dw.active == 11 and r[0] >= bar.view[0] and r[2] <= bar.view[1], "the newest tab, active, is in view", .{});
        }

        // The left chevron, until the first tab shows; then click it.
        var clicks: usize = 0;
        while (clicks < 20) : (clicks += 1) {
            var d = try h.dump(&g);
            defer d.deinit();
            const bar = d.value.windows[0].tab_bar;
            if (bar.scroll == 0) break;
            const r = bar.scroll_left;
            h.click(win, @divTrunc(r[0] + r[2], 2), @divTrunc(r[1] + r[3], 2), .left);
            h.sync(win);
        }
        {
            var d = try h.dump(&g);
            defer d.deinit();
            const bar = d.value.windows[0].tab_bar;
            const r = bar.tabs[0].rect;
            try h.expect(bar.scroll == 0 and r[0] >= bar.view[0], "the left chevron scrolls back to the first tab ({d} clicks)", .{clicks});
            h.click(win, @divTrunc(r[0] + r[2], 2) - 8, @divTrunc(r[1] + r[3], 2), .left);
        }
        try waitActiveTab(h, &g, win, 0);
        try h.expect(true, "and the first tab can be clicked", .{});

        // The wheel (towards the user) to the end: the last tab shows.
        {
            var d = try h.dump(&g);
            defer d.deinit();
            const bar = d.value.windows[0].tab_bar;
            const mid = @divTrunc(bar.view[0] + bar.view[1], 2);
            h.wheel(win, mid, bar.top + @divTrunc(bar.height, 2), -20);
        }
        h.sync(win);
        {
            var d = try h.dump(&g);
            defer d.deinit();
            const bar = d.value.windows[0].tab_bar;
            const r = bar.tabs[11].rect;
            try h.expect(r[2] <= bar.view[1] and r[0] >= bar.view[0], "the wheel scrolls to the last tab (scroll {d})", .{bar.scroll});
        }

        // A touchpad's smaller steps add up: three thirds of a notch back
        // scroll one tab.
        var before: i32 = 0;
        var tab_w: i32 = 0;
        {
            var d = try h.dump(&g);
            defer d.deinit();
            const bar = d.value.windows[0].tab_bar;
            before = bar.scroll;
            tab_w = bar.tabs[0].rect[2] - bar.tabs[0].rect[0];
            const mid = @divTrunc(bar.view[0] + bar.view[1], 2);
            for (0..3) |_| h.wheelDelta(win, mid, bar.top + @divTrunc(bar.height, 2), 40);
        }
        h.sync(win);
        {
            var d = try h.dump(&g);
            defer d.deinit();
            const scroll = d.value.windows[0].tab_bar.scroll;
            try h.expect(before - scroll == tab_w, "three thirds of a notch scroll one tab (scroll {d} -> {d}, a tab {d})", .{ before, scroll, tab_w });
        }

        // The tab list.
        const at = try stripButton(h, &g, .list);
        h.press(win, at.x, at.y);
        const palette = hwndOf((try waitPalette(h, &g, win, true)).edit);
        {
            var d = try h.dump(&g);
            defer d.deinit();
            const p = d.value.windows[0].palette orelse return h.fail("no palette in the dump", .{});
            const tabs_dump = d.value.windows[0].tabs;
            var same = p.items.len == 12;
            if (same) for (p.items, tabs_dump) |item, t| {
                same = same and std.mem.eql(u8, item, t.label);
            };
            try h.expect(same, "the list button lists the twelve tabs in order (got {d})", .{p.items.len});
            try h.expect(p.selected == 0 and std.mem.startsWith(u8, p.details[0], "Tab 1"), "the active tab selected, 'Tab N' beneath", .{});
        }
        try h.typeText(palette, "Tab 3");
        _ = try waitPaletteText(h, &g, win, "Tab 3");
        h.key(palette, .{}, w.VK_RETURN);
        try waitActiveTab(h, &g, win, 2);
        try h.expect(true, "filtering by 'Tab 3' and Enter selects the third tab", .{});

        // A middle tab selected while minimized (the strip has no width
        // then) is in view once the window is restored; the last would be
        // anyway, the scroll clamped to its end. The pane, found first: a
        // minimized window's panes don't count as visible.
        const pane = try h.surface(&g, win);
        _ = w.ShowWindow(win, w.SW_MINIMIZE);
        {
            var waited: u32 = 0;
            while (w.IsIconic(win) == 0 and waited < 3000) : (waited += 100) w.Sleep(100);
        }
        h.key(pane, cs, w.VK_F9);
        try waitActiveTab(h, &g, win, 5);
        _ = w.ShowWindow(win, w.SW_RESTORE);
        {
            var waited: u32 = 0;
            while (w.IsIconic(win) != 0 and waited < 3000) : (waited += 100) w.Sleep(100);
        }
        h.sync(win);
        {
            var d = try h.dump(&g);
            defer d.deinit();
            const bar = d.value.windows[0].tab_bar;
            const r = bar.tabs[5].rect;
            try h.expect(r[0] >= bar.view[0] and r[2] <= bar.view[1], "a tab selected while minimized shows once restored (scroll {d})", .{bar.scroll});
        }
        try quit(h, &g, try h.surface(&g, win));
    }
    {
        // No strip: toggle_tab_overview.
        var g = try start(h, "tab-overview", "window-show-tab-bar = never\nkeybind = ctrl+shift+f5=toggle_tab_overview\n", ">");
        defer g.deinit();
        const win = try h.mainWindow(&g);
        h.key(try h.surface(&g, win), cs, 'T');
        try waitWindowTabs(h, &g, win, 2);
        h.key(try h.surface(&g, win), cs, w.VK_F5);
        const palette = hwndOf((try waitPalette(h, &g, win, true)).edit);
        h.key(palette, .{}, w.VK_UP);
        h.key(palette, .{}, w.VK_RETURN);
        try waitActiveTab(h, &g, win, 0);
        try h.expect(true, "with no strip, toggle_tab_overview lists the tabs and Up, Enter picks the first", .{});
        try quit(h, &g, try h.surface(&g, win));
    }
}

/// GTK's header bar as the title bar (roadmap 4.3; 3.8e before it): with
/// client-side decorations the header bar replaces the caption, shows with
/// one tab (the tab row hidden), and is the caption between its buttons,
/// the window's buttons answering as the caption's (maximize, restore,
/// minimize, close asking first); "+" opens a tab and the row shows.
/// Fullscreen, gtk-titlebar = false and window-decoration = server bring
/// back the system's caption without a header; window-show-tab-bar = never
/// keeps the header without the row.
fn headerBar(h: *Harness) anyerror!void {
    const cs: Harness.Mods = .{ .ctrl = true, .shift = true };
    {
        var g = try start(h, "header-bar", "keybind = ctrl+shift+f8=toggle_fullscreen\n", ">");
        defer g.deinit();
        const win = try h.mainWindow(&g);
        try waitChrome(h, &g, true, false, "one tab: the header bar, no tab row");

        // What Windows hears over the header bar.
        var hb: Harness.Dump.Header = undefined;
        var width: i32 = 0;
        {
            var d = try h.dump(&g);
            defer d.deinit();
            hb = d.value.windows[0].header;
            var client: w.RECT = .{};
            _ = w.GetClientRect(win, &client);
            width = client.right;
        }
        try h.expect(hb.new_tab[0] > 0 and hb.new_tab[0] < 40, "\"+\" at the bar's left end (x {d})", .{hb.new_tab[0]});
        try expectNcHit(h, win, rectMid(hb.minimize), w.HTMINBUTTON, "over minimize: the caption's minimize button");
        try expectNcHit(h, win, rectMid(hb.maximize), w.HTMAXBUTTON, "over maximize: the caption's (Snap Layouts)");
        try expectNcHit(h, win, rectMid(hb.window_close), w.HTCLOSE, "over close: the caption's close");
        try expectNcHit(h, win, rectMid(hb.new_tab), w.HTCLIENT, "over \"+\": the window's own button");
        try expectNcHit(h, win, .{ @divTrunc(width, 2), @divTrunc(hb.height, 2) }, w.HTCAPTION, "between the buttons: the caption");
        try expectNcHit(h, win, .{ @divTrunc(width, 2), 1 }, w.HTTOP, "the top edge resizes");

        // The window's buttons.
        ncClick(win, w.HTMAXBUTTON);
        try waitWindowState(win, .maximized, h, "maximize maximizes");
        ncClick(win, w.HTMAXBUTTON);
        try waitWindowState(win, .normal, h, "and again restores");
        ncClick(win, w.HTMINBUTTON);
        try waitWindowState(win, .minimized, h, "minimize minimizes");
        _ = w.ShowWindow(win, w.SW_RESTORE);
        try waitWindowState(win, .normal, h, "restored");

        const plus = try stripButton(h, &g, .new_tab);
        h.key(try h.surface(&g, win), cs, w.VK_F8);
        try waitChrome(h, &g, false, false, "fullscreen with one tab: no header, no row");
        h.key(try h.surface(&g, win), cs, w.VK_F8);
        try waitChrome(h, &g, true, false, "out of fullscreen: the header bar again");
        h.click(win, plus.x, plus.y, .left);
        try waitWindowTabs(h, &g, win, 2);
        try waitChrome(h, &g, true, true, "\"+\" opened a second tab, and the row shows both");

        ncClick(win, w.HTCLOSE);
        const dlg = try h.waitDialog(&g, 5000);
        try expectDialogText(h, &g, "Close Window?", "All terminal sessions in this window will be terminated.");
        h.answer(&g, dlg, w.IDCANCEL);
        try waitNoDialog(h, &g);
        try quit(h, &g, try h.surface(&g, win));
    }
    {
        var g = try start(h, "header-bar-off", "gtk-titlebar = false\n", ">");
        defer g.deinit();
        const win = try h.mainWindow(&g);
        try waitChrome(h, &g, false, false, "gtk-titlebar = false, one tab: no header, no row");
        try expectSystemCaption(h, win, "with the system's caption");
        h.key(try h.surface(&g, win), cs, 'T');
        try waitWindowTabs(h, &g, win, 2);
        try waitChrome(h, &g, false, true, "and with two tabs, the row alone");
        try quit(h, &g, try h.surface(&g, win));
    }
    {
        var g = try start(h, "header-bar-server", "window-decoration = server\n", ">");
        defer g.deinit();
        const win = try h.mainWindow(&g);
        try waitChrome(h, &g, false, false, "window-decoration = server: no header bar");
        try expectSystemCaption(h, win, "the system's caption instead");
        try quit(h, &g, try h.surface(&g, win));
    }
    {
        var g = try start(h, "header-bar-never", "window-show-tab-bar = never\n", ">");
        defer g.deinit();
        const win = try h.mainWindow(&g);
        h.key(try h.surface(&g, win), cs, 'T');
        try waitWindowTabs(h, &g, win, 2);
        try waitChrome(h, &g, true, false, "window-show-tab-bar = never, two tabs: the header bar, no row");
        try quit(h, &g, try h.surface(&g, win));
    }
}

/// Wait until the first window shows the header bar or not, and the tab
/// row or not.
fn waitChrome(h: *Harness, g: *Harness.Ghostty, header: bool, row: bool, what: []const u8) !void {
    var waited: u32 = 0;
    var last: [2]bool = .{ false, false };
    while (waited <= 5000) : (waited += 100) {
        var d = try h.dump(g);
        defer d.deinit();
        const dw = d.value.windows[0];
        last = .{ dw.header.visible, dw.tab_bar.visible };
        if (last[0] == header and last[1] == row) return h.expect(true, "{s}", .{what});
        w.Sleep(100);
    }
    return h.fail("{s}: the header bar shows {}, the tab row {}", .{ what, last[0], last[1] });
}

fn rectMid(r: [4]i32) [2]i32 {
    return .{ @divTrunc(r[0] + r[2], 2), @divTrunc(r[1] + r[3], 2) };
}

/// What WM_NCHITTEST answers at client point `at`.
fn ncHit(win: w.HWND, at: [2]i32) isize {
    var pt: w.POINT = .{ .x = at[0], .y = at[1] };
    _ = w.ClientToScreen(win, &pt);
    var result: usize = 0;
    _ = w.SendMessageTimeoutW(win, w.WM_NCHITTEST, 0, w.makeLParam(pt.x, pt.y), w.SMTO_ABORTIFHUNG, 2000, &result);
    return @bitCast(result);
}

fn expectNcHit(h: *Harness, win: w.HWND, at: [2]i32, want: isize, what: []const u8) !void {
    const got = ncHit(win, at);
    try h.expect(got == want, "{s} (hit {d} at {d},{d}; expected {d})", .{ what, got, at[0], at[1], want });
}

/// A click on the caption's button `code`, as Windows posts it.
fn ncClick(win: w.HWND, code: c_int) void {
    var r: w.RECT = .{};
    _ = w.GetWindowRect(win, &r);
    const pos = w.makeLParam(r.left + 10, r.top + 10);
    _ = w.PostMessageW(win, w.WM_NCLBUTTONDOWN, @intCast(code), pos);
    _ = w.PostMessageW(win, w.WM_NCLBUTTONUP, @intCast(code), pos);
}

fn waitWindowState(win: w.HWND, want: enum { normal, maximized, minimized }, h: *Harness, what: []const u8) !void {
    var waited: u32 = 0;
    while (waited <= 5000) : (waited += 100) {
        const now: @TypeOf(want) = if (w.IsIconic(win) != 0) .minimized else if (w.IsZoomed(win) != 0) .maximized else .normal;
        if (now == want) return h.expect(true, "{s}", .{what});
        w.Sleep(100);
    }
    return h.fail("{s}: the window never was {t}", .{ what, want });
}

/// The window has the system's caption: its client area starts well below
/// its top.
fn expectSystemCaption(h: *Harness, win: w.HWND, what: []const u8) !void {
    var r: w.RECT = .{};
    _ = w.GetWindowRect(win, &r);
    var origin: w.POINT = .{ .x = 0, .y = 0 };
    _ = w.ClientToScreen(win, &origin);
    try h.expect(origin.y - r.top > 20, "{s} (client area {d} px below the window's top)", .{ what, origin.y - r.top });
}

/// The strip's details (roadmap 3.8): window-title-font-family sets its
/// font; the window's icons are loaded at its DPI; a tab's tooltip shows
/// its title and, beneath, its directory (GTK's shows only the
/// directory), a button's its name and binding; window-new-tab-position =
/// end puts a new tab last.
fn tabDetails(h: *Harness) anyerror!void {
    // Shell integration reports the directory the tooltip shows.
    var g = try start(h, "tab-details",
        \\window-show-tab-bar = always
        \\window-title-font-family = Consolas
        \\window-new-tab-position = end
        \\shell-integration = detect
        \\keybind = ctrl+shift+f8=set_tab_title:named
        \\
    , ">");
    defer g.deinit();
    const win = try h.mainWindow(&g);
    const cs: Harness.Mods = .{ .ctrl = true, .shift = true };
    {
        var d = try h.dump(&g);
        defer d.deinit();
        const dw = d.value.windows[0];
        try h.expect(std.mem.eql(u8, dw.tab_bar.font, "Consolas"), "window-title-font-family sets the strip's font ('{s}')", .{dw.tab_bar.font});
        const dpi = w.GetDpiForWindow(win);
        const small = w.GetSystemMetricsForDpi(w.SM_CXSMICON, dpi);
        const big = w.GetSystemMetricsForDpi(w.SM_CXICON, dpi);
        try h.expect(dw.icon_widths[0] == small and dw.icon_widths[1] == big, "the icons are loaded at the window's DPI ({d} and {d} px at {d} dpi; got {d} and {d})", .{ small, big, dpi, dw.icon_widths[0], dw.icon_widths[1] });
        try h.expect(dw.has_tooltip, "the strip has a tooltip", .{});
        try h.expect(std.mem.eql(u8, dw.header.new_tab_tooltip, "New Tab (Ctrl+Shift+T)"), "'+' says what it does and its binding ('{s}')", .{dw.header.new_tab_tooltip});
    }

    // A tab's tooltip: its title, then its directory, unless the title
    // shows it (cmd's integration makes the directory the title).
    const first = try h.surface(&g, win);
    try h.typeText(first, "cd /d C:\\Windows");
    h.enter(first);
    try waitPwd(h, &g, 0, "C:\\Windows");
    try waitTabTitle(h, &g, 0, "C:\\Windows");
    {
        var d = try h.dump(&g);
        defer d.deinit();
        const tip = d.value.windows[0].tab_bar.tabs[0].tooltip;
        try h.expect(std.mem.eql(u8, tip, "C:\\Windows"), "with the directory as its title, a tab's tooltip is the title alone ('{s}')", .{tip});
    }
    h.key(first, cs, w.VK_F8);
    {
        var waited: u32 = 0;
        var tip_buf: [256]u8 = undefined;
        var tip_len: usize = 0;
        while (waited <= 5000) : (waited += 100) {
            var d = try h.dump(&g);
            defer d.deinit();
            const tip = d.value.windows[0].tab_bar.tabs[0].tooltip;
            tip_len = copyInto(&tip_buf, tip);
            if (std.mem.eql(u8, tip, "named\nC:\\Windows")) break;
            w.Sleep(100);
        }
        try h.expect(std.mem.eql(u8, tip_buf[0..tip_len], "named\nC:\\Windows"), "a named tab's tooltip: the name, then the directory ('{s}')", .{tip_buf[0..tip_len]});
    }

    // window-new-tab-position = end: from the first of three tabs, the new
    // one goes last.
    h.key(first, cs, 'T');
    try waitWindowTabs(h, &g, win, 2);
    h.key(try h.surface(&g, win), cs, 'T');
    try waitWindowTabs(h, &g, win, 3);
    const at = try tabCenter(h, &g, 0);
    h.click(win, at.x - 8, at.y, .left);
    try waitActiveTab(h, &g, win, 0);
    h.key(try h.surface(&g, win), cs, 'T');
    try waitWindowTabs(h, &g, win, 4);
    try waitActiveTab(h, &g, win, 3);
    try h.expect(true, "window-new-tab-position = end puts the new tab last", .{});
    // Every prompt idle, so quitting doesn't ask.
    for (0..4) |i| try waitAtPrompt(h, &g, i, true);
    try quitIdle(h, &g, try h.surface(&g, win));
}

/// The middle of one of the header bar's buttons, in the window's client
/// area.
fn stripButton(h: *Harness, g: *Harness.Ghostty, which: enum { new_tab, new_tab_menu, menu, list, minimize, maximize, window_close }) !struct { x: c_int, y: c_int } {
    var d = try h.dump(g);
    defer d.deinit();
    const bar = d.value.windows[0].header;
    if (!bar.visible) return h.fail("the header bar isn't showing", .{});
    const r = switch (which) {
        .new_tab => bar.new_tab,
        .new_tab_menu => bar.new_tab_menu,
        .menu => bar.menu,
        .list => bar.list,
        .minimize => bar.minimize,
        .maximize => bar.maximize,
        .window_close => bar.window_close,
    };
    if (r[2] <= r[0]) return h.fail("the header bar reports no such button", .{});
    return .{ .x = @divTrunc(r[0] + r[2], 2), .y = @divTrunc(r[1] + r[3], 2) };
}

/// The middle of tab `i` of the first window's strip, in its client area.
fn tabCenter(h: *Harness, g: *Harness.Ghostty, i: usize) !struct { x: c_int, y: c_int } {
    var d = try h.dump(g);
    defer d.deinit();
    const strip = d.value.windows[0].tab_bar.tabs;
    if (i >= strip.len) return h.fail("no tab {d} in the strip", .{i});
    const r = strip[i].rect;
    return .{ .x = @divTrunc(r[0] + r[2], 2), .y = @divTrunc(r[1] + r[3], 2) };
}

/// A tab's label, the bell's state, and the window's caption (copies).
const TabState = struct {
    label_buf: [256]u8 = undefined,
    label_len: usize = 0,
    caption_buf: [256]u8 = undefined,
    caption_len: usize = 0,
    bell: bool = false,
    attention: bool = false,
    painted_bell: bool = false,
    painted_attention: bool = false,

    fn label(s: *const TabState) []const u8 {
        return s.label_buf[0..s.label_len];
    }
    fn caption(s: *const TabState) []const u8 {
        return s.caption_buf[0..s.caption_len];
    }
    fn ringing(s: *const TabState) bool {
        return s.bell;
    }
    fn quiet(s: *const TabState) bool {
        return !s.bell;
    }
    fn marked(s: *const TabState) bool {
        return s.attention and s.bell;
    }
    fn seen(s: *const TabState) bool {
        return !s.attention and !s.bell;
    }
};

fn tabState(h: *Harness, g: *Harness.Ghostty, index: usize) !TabState {
    var d = try h.dump(g);
    defer d.deinit();
    const dw = d.value.windows[0];
    if (index >= dw.tabs.len) return .{};
    const tab = dw.tabs[index];
    var r: TabState = .{
        .bell = tab.bell,
        .attention = tab.attention,
        .painted_bell = tab.painted_bell,
        .painted_attention = tab.painted_attention,
    };
    r.label_len = copyInto(&r.label_buf, tab.label);
    r.caption_len = copyInto(&r.caption_buf, dw.caption);
    return r;
}

fn waitTabState(h: *Harness, g: *Harness.Ghostty, index: usize, cond: fn (*const TabState) bool, comptime what: []const u8) !TabState {
    return waitTabStateFor(h, g, index, cond, what, 10000);
}

fn waitTabStateFor(h: *Harness, g: *Harness.Ghostty, index: usize, cond: fn (*const TabState) bool, comptime what: []const u8, ms: u32) !TabState {
    var last: TabState = .{};
    var waited: u32 = 0;
    while (waited <= ms) : (waited += 100) {
        last = try tabState(h, g, index);
        if (cond(&last)) return last;
        w.Sleep(100);
    }
    return h.fail("never " ++ what ++ " (tab {d} '{s}', bell {}, mark {}, caption '{s}')", .{ index, last.label(), last.bell, last.attention, last.caption() });
}

/// The status overlays (roadmap 3.6, GTK's): a URL under the mouse with
/// Ctrl held shows at the bottom left, and goes with Ctrl; the read-only
/// badge shows while toggle_readonly holds input back; the key state shows
/// a pending sequence's keys and an active key table; the renderer panel
/// shows while the renderer is unhealthy; toasts follow a copy and a
/// config reload (none at start); a pane whose program fails keeps a
/// "Command Failed" banner whose Close closes it, and with
/// wait-after-command a "Command Succeeded" one that any key closes.
fn statusOverlays(h: *Harness) anyerror!void {
    var saved = try h.saveClipboard();
    defer saved.restore();
    const cs: Harness.Mods = .{ .ctrl = true, .shift = true };
    {
        var g = try start(h, "status-overlays",
            \\keybind = ctrl+shift+f7=toggle_readonly
            \\keybind = ctrl+shift+f8>x=scroll_to_bottom
            \\keybind = ctrl+shift+f9=activate_key_table:mytable
            \\keybind = mytable/escape=deactivate_key_table
            \\
        , ">");
        defer g.deinit();
        const win = try h.mainWindow(&g);
        const surf = try h.surface(&g, win);
        var st = try statusState(h, &g);
        try h.expect(st.toast().len == 0 and st.link().len == 0 and !st.readonly and !st.health and st.banner().len == 0, "nothing shows at start (no toast)", .{});

        // A link: Ctrl held over it previews it.
        const url = "https://example.com/murrtty-preview";
        try h.typeText(surf, "echo " ++ url);
        h.enter(surf);
        try h.waitText(&g, url, 2, 10000);
        const at = try cellPoint(h, &g, url);
        try h.pinMouse(&g, true);
        h.moveMods(surf, at.x, at.y, .{ .ctrl = true });
        st = try waitStatus(h, &g, url, StatusState.linkIs, "the link's preview");
        try h.expect(!st.link_right, "the URL under the mouse with Ctrl shows at the bottom left", .{});
        h.move(surf, at.x + 3, at.y, false);
        st = try waitStatus(h, &g, "", StatusState.linkIs, "no preview without Ctrl");
        try h.expect(true, "without Ctrl it goes", .{});
        try h.pinMouse(&g, false);

        // Read-only: the badge, and typing reaches nothing (shown by a
        // command typed after it ends, which would carry anything held).
        h.key(surf, cs, w.VK_F7);
        st = try waitStatus(h, &g, "", StatusState.isReadonly, "the read-only badge");
        try h.typeText(surf, "echo held-back");
        h.key(surf, cs, w.VK_F7);
        st = try waitStatus(h, &g, "", StatusState.notReadonly, "no read-only badge");
        try h.typeText(surf, "echo after-ro");
        h.enter(surf);
        try h.waitText(&g, "after-ro", 2, 10000);
        {
            var d = try h.dump(&g);
            defer d.deinit();
            const text = d.value.windows[0].tabs[0].text orelse "";
            try h.expect(std.mem.indexOf(u8, text, "held-back") == null, "read-only shows its badge, holds input back, and the badge goes when it ends", .{});
        }

        // The key state: a sequence's leader, then a key table.
        h.key(surf, cs, w.VK_F8);
        st = try waitStatus(h, &g, "Ctrl+Shift+F8", StatusState.keysAre, "the pending key");
        h.key(surf, .{}, 'X');
        st = try waitStatus(h, &g, "", StatusState.keysAre, "the sequence done");
        try h.expect(true, "a pending sequence shows its keys until it ends", .{});
        h.key(surf, cs, w.VK_F9);
        st = try waitStatus(h, &g, "mytable", StatusState.keysAre, "the key table");
        h.key(surf, .{}, w.VK_ESCAPE);
        st = try waitStatus(h, &g, "", StatusState.keysAre, "the table gone");
        try h.expect(true, "an active key table shows until it is deactivated", .{});

        // The renderer panel.
        try h.setRendererHealth(&g, false);
        st = try waitStatus(h, &g, "", StatusState.isUnhealthy, "the renderer panel");
        try h.setRendererHealth(&g, true);
        st = try waitStatus(h, &g, "", StatusState.isHealthy, "no renderer panel");
        try h.expect(true, "the renderer panel shows while it is unhealthy", .{});

        // Toasts: a copy, then a reload of the config.
        h.click(surf, at.x, at.y, .left);
        h.click(surf, at.x, at.y, .left);
        h.sync(surf);
        h.key(surf, cs, 'C');
        st = try waitStatus(h, &g, "Copied to clipboard", StatusState.toastIs, "the copy's toast");
        h.key(surf, cs, w.VK_OEM_COMMA);
        st = try waitStatus(h, &g, "Reloaded the configuration", StatusState.toastIs, "the reload's toast");
        st = try waitStatusFor(h, &g, "", StatusState.toastIs, "the toast gone", 6000);
        try h.expect(true, "toasts for a copy and a reload, gone after a few seconds", .{});
        try quit(h, &g, surf);
    }
    {
        // A program that fails at once: the banner, and Close.
        var g = try h.launch("status-banner-failed", base_config ++
            \\command = cmd.exe /c exit 3
            \\abnormal-command-exit-runtime = 60000
            \\
        );
        defer g.deinit();
        _ = try waitStatusFor(h, &g, "Command Failed", StatusState.bannerIs, "the failed banner", 15000);
        const win = try h.mainWindow(&g);
        const surf = try h.surface(&g, win);
        const banner = h.child(&g, surf, "MurrttyBanner") orelse return h.fail("no banner window", .{});
        const close = h.child(&g, banner, "Button") orelse return h.fail("no Close button", .{});
        try h.expect(true, "a failed program leaves 'Command Failed' with Close", .{});
        _ = w.PostMessageW(close, w.BM_CLICK, 0, 0);
        const code = g.waitExit(10000);
        try h.expect(code != null and code.? == 0, "Close closes it (exit {?d})", .{code});
    }
    {
        // With wait-after-command, a finished program's banner; any key.
        var g = try h.launch("status-banner-done", base_config ++
            \\command = cmd.exe /c exit 0
            \\wait-after-command = true
            \\
        );
        defer g.deinit();
        _ = try waitStatusFor(h, &g, "Command Succeeded", StatusState.bannerIs, "the succeeded banner", 15000);
        const surf = try h.surface(&g, try h.mainWindow(&g));
        try h.expect(true, "with wait-after-command, 'Command Succeeded'", .{});
        // A press on Close dragged off and let go: nothing closes, and the
        // keyboard, which the press took, is the pane's again. (The button
        // stays pushed until a held move leaves it, as a real drag does.)
        const banner = h.child(&g, surf, "MurrttyBanner") orelse return h.fail("no banner window", .{});
        const close = h.child(&g, banner, "Button") orelse return h.fail("no Close button", .{});
        h.press(close, 5, 5);
        h.sync(surf);
        try h.expect(keyboardFocus(surf) == close, "a press on Close takes the keyboard", .{});
        h.move(close, -40, -40, true);
        h.release(close, -40, -40);
        h.sync(surf);
        try h.expect(g.waitExit(300) == null, "dragged off and let go, it closes nothing", .{});
        try h.expect(keyboardFocus(surf) == surf, "and the keyboard is the pane's again", .{});
        h.key(surf, .{}, 'A');
        const code = g.waitExit(10000);
        try h.expect(code != null and code.? == 0, "and a key closes it (exit {?d})", .{code});
    }
}

/// The first window's active pane's status overlays and the window's
/// toast (copies, with lengths: the dump they come from is freed).
const StatusState = struct {
    link_buf: [256]u8 = undefined,
    link_len: usize = 0,
    link_right: bool = false,
    readonly: bool = false,
    keys_buf: [128]u8 = undefined,
    keys_len: usize = 0,
    health: bool = false,
    banner_buf: [64]u8 = undefined,
    banner_len: usize = 0,
    toast_buf: [64]u8 = undefined,
    toast_len: usize = 0,

    fn link(s: *const StatusState) []const u8 {
        return s.link_buf[0..s.link_len];
    }
    fn keys(s: *const StatusState) []const u8 {
        return s.keys_buf[0..s.keys_len];
    }
    fn banner(s: *const StatusState) []const u8 {
        return s.banner_buf[0..s.banner_len];
    }
    fn toast(s: *const StatusState) []const u8 {
        return s.toast_buf[0..s.toast_len];
    }

    fn linkIs(s: *const StatusState, want: []const u8) bool {
        return std.mem.eql(u8, s.link(), want);
    }
    fn keysAre(s: *const StatusState, want: []const u8) bool {
        return std.mem.eql(u8, s.keys(), want);
    }
    fn bannerIs(s: *const StatusState, want: []const u8) bool {
        return std.mem.eql(u8, s.banner(), want);
    }
    fn toastIs(s: *const StatusState, want: []const u8) bool {
        return std.mem.eql(u8, s.toast(), want);
    }
    fn isReadonly(s: *const StatusState, _: []const u8) bool {
        return s.readonly;
    }
    fn notReadonly(s: *const StatusState, _: []const u8) bool {
        return !s.readonly;
    }
    fn isUnhealthy(s: *const StatusState, _: []const u8) bool {
        return s.health;
    }
    fn isHealthy(s: *const StatusState, _: []const u8) bool {
        return !s.health;
    }
};

fn statusState(h: *Harness, g: *Harness.Ghostty) !StatusState {
    var d = try h.dump(g);
    defer d.deinit();
    if (d.value.windows.len == 0) return .{};
    const dw = d.value.windows[0];
    var r: StatusState = .{};
    r.toast_len = copyInto(&r.toast_buf, dw.toast);
    const panes = dw.tabs[dw.active].panes orelse return r;
    const s = panes[0].status orelse return r;
    r.link_len = copyInto(&r.link_buf, s.link);
    r.link_right = s.link_right;
    r.readonly = s.readonly;
    r.keys_len = copyInto(&r.keys_buf, s.keys);
    r.health = s.health;
    r.banner_len = copyInto(&r.banner_buf, s.banner);
    return r;
}

fn waitStatus(h: *Harness, g: *Harness.Ghostty, want: []const u8, cond: fn (*const StatusState, []const u8) bool, comptime what: []const u8) !StatusState {
    return waitStatusFor(h, g, want, cond, what, 5000);
}

fn waitStatusFor(h: *Harness, g: *Harness.Ghostty, want: []const u8, cond: fn (*const StatusState, []const u8) bool, comptime what: []const u8, ms: u32) !StatusState {
    var last: StatusState = .{};
    var waited: u32 = 0;
    while (waited <= ms) : (waited += 100) {
        last = try statusState(h, g);
        if (cond(&last, want)) return last;
        w.Sleep(100);
    }
    return h.fail("never " ++ what ++ " (link '{s}', keys '{s}', readonly {}, health {}, banner '{s}', toast '{s}')", .{ last.link(), last.keys(), last.readonly, last.health, last.banner(), last.toast() });
}

/// Titles (roadmap 3.5, GTK's): a program's title shows on the tab and the
/// caption; the tab's rename prompt ("Change Tab Title", the current title
/// selected) overrides it and keeps it while the program sets new titles;
/// a blank name restores the program's; Cancel changes nothing;
/// set_window_title overrides the caption only; prompt_surface_title names
/// the pane; copy_title_to_clipboard copies what shows; a double click on
/// a tab opens its prompt.
fn titles(h: *Harness) anyerror!void {
    var saved = try h.saveClipboard();
    defer saved.restore();
    var g = try start(h, "titles",
        \\keybind = ctrl+shift+f2=prompt_tab_title
        \\keybind = ctrl+shift+f3=set_window_title:win-title
        \\keybind = ctrl+shift+f4=set_window_title:
        \\keybind = ctrl+shift+f5=prompt_surface_title
        \\keybind = ctrl+shift+f6=copy_title_to_clipboard
        \\keybind = ctrl+shift+f7=prompt_window_title
        \\keybind = ctrl+shift+f8=set_tab_title:tab-name
        \\keybind = ctrl+shift+f9=set_tab_title:
        \\
    , ">");
    defer g.deinit();
    const win = try h.mainWindow(&g);
    const surf = try h.surface(&g, win);
    const cs: Harness.Mods = .{ .ctrl = true, .shift = true };

    try h.typeText(surf, "title program-one");
    h.enter(surf);
    _ = try waitTitles(h, &g, "program-one", "program-one");

    // Rename the tab: the prompt runs in a modal scope (closes wait), and
    // Enter in its field is OK (the dialog's own handling).
    h.key(surf, cs, w.VK_F2);
    var dlg = try h.waitDialog(&g, 5000);
    try expectTitleDialog(h, dlg, "Change Tab Title", "program-one");
    {
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(d.value.modal_depth == 1, "the prompt runs in a modal scope", .{});
    }
    try setDialogText(h, dlg, "renamed");
    const field = w.GetDlgItem(dlg, 100) orelse return h.fail("the prompt has no field", .{});
    h.key(field, .{}, w.VK_RETURN);
    try waitNoDialog(h, &g);
    _ = try waitTitles(h, &g, "renamed", "renamed");

    // The program's next title doesn't replace the name.
    try h.typeText(surf, "title program-two");
    h.enter(surf);
    var t = try waitProgramTitle(h, &g, "program-two");
    try h.expect(std.mem.eql(u8, t.label(), "renamed") and std.mem.eql(u8, t.caption(), "renamed"), "the tab keeps its name while the program sets titles ('{s}')", .{t.label()});

    // A blank name restores the program's.
    h.key(surf, cs, w.VK_F2);
    dlg = try h.waitDialog(&g, 5000);
    try expectTitleDialog(h, dlg, "Change Tab Title", "renamed");
    try setDialogText(h, dlg, "");
    h.answer(&g, dlg, w.IDOK);
    try waitNoDialog(h, &g);
    _ = try waitTitles(h, &g, "program-two", "program-two");

    // Cancel changes nothing.
    h.key(surf, cs, w.VK_F2);
    dlg = try h.waitDialog(&g, 5000);
    try setDialogText(h, dlg, "not-this");
    h.answer(&g, dlg, w.IDCANCEL);
    try waitNoDialog(h, &g);
    t = try titleState(h, &g);
    try h.expect(std.mem.eql(u8, t.label(), "program-two"), "Cancel keeps the title ('{s}')", .{t.label()});

    // The window's name: the caption only; empty clears it.
    h.key(surf, cs, w.VK_F3);
    _ = try waitTitles(h, &g, "program-two", "win-title");
    h.key(surf, cs, w.VK_F4);
    _ = try waitTitles(h, &g, "program-two", "program-two");

    // The pane's name, through its prompt.
    h.key(surf, cs, w.VK_F5);
    dlg = try h.waitDialog(&g, 5000);
    try expectTitleDialog(h, dlg, "Change Terminal Title", "program-two");
    try setDialogText(h, dlg, "pane-name");
    h.answer(&g, dlg, w.IDOK);
    try waitNoDialog(h, &g);
    _ = try waitTitles(h, &g, "pane-name", "pane-name");

    // Copying the title copies what shows.
    h.key(surf, cs, w.VK_F6);
    try waitClipboard(h, "pane-name");

    // A tab's name over the pane's (set_tab_title); empty clears it.
    h.key(surf, cs, w.VK_F8);
    _ = try waitTitles(h, &g, "tab-name", "tab-name");
    h.key(surf, cs, w.VK_F9);
    _ = try waitTitles(h, &g, "pane-name", "pane-name");

    // The window's prompt: the caption only.
    h.key(surf, cs, w.VK_F7);
    dlg = try h.waitDialog(&g, 5000);
    try expectTitleDialog(h, dlg, "Change Window Title", "pane-name");
    try setDialogText(h, dlg, "win-name");
    h.answer(&g, dlg, w.IDOK);
    try waitNoDialog(h, &g);
    _ = try waitTitles(h, &g, "pane-name", "win-name");

    // A double click on a tab opens its prompt (two tabs show the bar);
    // the window class takes double clicks, which real ones need.
    try h.expect(w.GetClassLongPtrW(win, w.GCL_STYLE) & w.CS_DBLCLKS != 0, "the window takes double clicks", .{});
    h.key(surf, cs, 'T');
    try waitWindowTabs(h, &g, win, 2);
    w.Sleep(500);
    {
        var d = try h.dump(&g);
        defer d.deinit();
        const r = d.value.windows[0].tab_bar.tabs[0].rect;
        h.doubleClick(win, @divTrunc(r[0] + r[2], 2), @divTrunc(r[1] + r[3], 2));
    }
    dlg = try h.waitDialog(&g, 5000);
    try expectTitleDialog(h, dlg, "Change Tab Title", "pane-name");
    h.answer(&g, dlg, w.IDCANCEL);
    try waitNoDialog(h, &g);

    // A double click on "+" is two clicks that add tabs, never a rename
    // (its first press moves the tabs under the second).
    {
        var d = try h.dump(&g);
        defer d.deinit();
        const r = d.value.windows[0].header.new_tab;
        h.doubleClick(win, @divTrunc(r[0] + r[2], 2), @divTrunc(r[1] + r[3], 2));
    }
    try waitWindowTabsAtLeast(h, &g, win, 3);
    h.sync(win);
    w.Sleep(300);
    try h.expect(try h.dialogCount(&g) == 0, "a double click on \"+\" adds a tab and renames nothing", .{});
    try quit(h, &g, try h.surface(&g, win));
}

/// The active tab's focused pane's program title, the tab's label and the
/// caption (copies: the dump they come from is freed).
const TitleState = struct {
    program_buf: [128]u8 = undefined,
    program_len: usize = 0,
    label_buf: [128]u8 = undefined,
    label_len: usize = 0,
    caption_buf: [128]u8 = undefined,
    caption_len: usize = 0,

    fn program(self: *const TitleState) []const u8 {
        return self.program_buf[0..self.program_len];
    }
    fn label(self: *const TitleState) []const u8 {
        return self.label_buf[0..self.label_len];
    }
    fn caption(self: *const TitleState) []const u8 {
        return self.caption_buf[0..self.caption_len];
    }
};

fn titleState(h: *Harness, g: *Harness.Ghostty) !TitleState {
    var d = try h.dump(g);
    defer d.deinit();
    const dw = d.value.windows[0];
    const tab = dw.tabs[dw.active];
    var r: TitleState = .{};
    r.program_len = copyInto(&r.program_buf, tab.title);
    r.label_len = copyInto(&r.label_buf, tab.label);
    r.caption_len = copyInto(&r.caption_buf, dw.caption);
    return r;
}

fn copyInto(buf: []u8, s: []const u8) usize {
    const n = @min(buf.len, s.len);
    @memcpy(buf[0..n], s[0..n]);
    return n;
}

/// Wait until the active tab shows `label` and the caption reads `caption`.
fn waitTitles(h: *Harness, g: *Harness.Ghostty, label: []const u8, caption: []const u8) !TitleState {
    var last: TitleState = .{};
    var waited: u32 = 0;
    while (waited <= 10000) : (waited += 100) {
        last = try titleState(h, g);
        if (std.mem.eql(u8, last.label(), label) and std.mem.eql(u8, last.caption(), caption)) {
            try h.expect(true, "the tab shows '{s}', the caption '{s}'", .{ label, caption });
            return last;
        }
        w.Sleep(100);
    }
    return h.fail("the tab shows '{s}' and the caption '{s}', not '{s}' and '{s}'", .{ last.label(), last.caption(), label, caption });
}

/// Wait until the active tab's program has set `title`.
fn waitProgramTitle(h: *Harness, g: *Harness.Ghostty, title: []const u8) !TitleState {
    var last: TitleState = .{};
    var waited: u32 = 0;
    while (waited <= 10000) : (waited += 100) {
        last = try titleState(h, g);
        if (std.mem.eql(u8, last.program(), title)) return last;
        w.Sleep(100);
    }
    return h.fail("the program's title is '{s}', not '{s}'", .{ last.program(), title });
}

/// The title prompt's caption, and its field holding `initial`, selected.
fn expectTitleDialog(h: *Harness, dlg: w.HWND, caption: []const u8, initial: []const u8) !void {
    const t = try h.title(dlg);
    defer h.alloc.free(t);
    const edit = w.GetDlgItem(dlg, 100) orelse return h.fail("the prompt has no field", .{});
    var buf: [256]u16 = undefined;
    var n: usize = 0;
    _ = w.SendMessageTimeoutW(edit, w.WM_GETTEXT, buf.len, @bitCast(@intFromPtr(&buf)), w.SMTO_ABORTIFHUNG, 2000, &n);
    var text_buf: [512]u8 = undefined;
    const len = std.unicode.utf16LeToUtf8(&text_buf, buf[0..n]) catch 0;
    var sel: usize = 0;
    _ = w.SendMessageTimeoutW(edit, w.EM_GETSEL, 0, 0, w.SMTO_ABORTIFHUNG, 2000, &sel);
    const selected = (sel & 0xFFFF) == 0 and (sel >> 16) == n;
    try h.expect(
        std.mem.eql(u8, t, caption) and std.mem.eql(u8, text_buf[0..len], initial) and selected,
        "the prompt reads '{s}', with '{s}' selected",
        .{ t, text_buf[0..len] },
    );
}

fn setDialogText(h: *Harness, dlg: w.HWND, text: []const u8) !void {
    const edit = w.GetDlgItem(dlg, 100) orelse return h.fail("the prompt has no field", .{});
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(h.alloc, text);
    defer h.alloc.free(wide);
    var result: usize = 0;
    _ = w.SendMessageTimeoutW(edit, w.WM_SETTEXT, 0, @bitCast(@intFromPtr(wide.ptr)), w.SMTO_ABORTIFHUNG, 2000, &result);
}

/// The scrollbar (roadmap 3.4, GTK's overlay scrollbar): nothing without
/// scrollback; with it, a mouse move shows a thin thumb at the bottom of
/// the track; pressed in the band at the right edge it widens, and dragged
/// to the top it scrolls to the first row; a click on the track below the
/// thumb pages down; idle, it fades; a program on the alternate screen
/// has no scrollback, so no thumb. `scrollbar = never` shows nothing.
fn scrollbar(h: *Harness) anyerror!void {
    {
        var g = try start(h, "scrollbar", "", ">");
        defer g.deinit();
        const win = try h.mainWindow(&g);
        const surf = try h.surface(&g, win);
        var sb = try scrollState(h, &g);
        try h.expect(sb.len > 0 and sb.total == sb.len and !sb.visible, "no scrollback, no scrollbar ({d} of {d} rows)", .{ sb.len, sb.total });
        const cols = try paneCols(h, &g);

        try h.typeText(surf, "for /l %i in (1,1,150) do @echo line-%i");
        h.enter(surf);
        try h.waitText(&g, "line-150", 1, 15000);
        sb = try waitScroll(h, &g, ScrollState.atBottom, "scrollback, viewed at the bottom", 5000);
        // The output scrolled it into view: let it fade first.
        sb = try waitScroll(h, &g, ScrollState.hidden, "faded after the output", 5000);

        // A move over the terminal shows it: thin, its thumb at the bottom,
        // over the grid (which keeps its width).
        var rect: w.RECT = .{};
        _ = w.GetClientRect(surf, &rect);
        const mid_x = @divTrunc(rect.right, 2);
        const mid_y = @divTrunc(rect.bottom, 2);
        h.move(surf, mid_x, mid_y, false);
        sb = try waitScroll(h, &g, ScrollState.shown, "shown after a move", 5000);
        const thin = sb.thumb[2] - sb.thumb[0];
        try h.expect(sb.thumb[3] >= rect.bottom - 10 and sb.thumb[2] >= rect.right - 10, "a move shows a thin thumb ({d} px) at the bottom right", .{thin});
        try h.expect(try paneCols(h, &g) == cols, "the grid keeps its {d} columns", .{cols});

        // Over the band at the right edge it widens (the mouse kept over
        // the pane: on the hidden desktop it would "leave" at once).
        const x = rect.right - 5;
        try h.pinMouse(&g, true);
        h.move(surf, x, mid_y, false);
        sb = try waitScroll(h, &g, ScrollState.isHovered, "widened over the edge", 5000);
        try h.expect(sb.thumb[2] - sb.thumb[0] > thin, "over the edge it widens ({d} px)", .{sb.thumb[2] - sb.thumb[0]});
        h.move(surf, mid_x, mid_y, false);
        try h.pinMouse(&g, false);

        // Pressed on the thumb (kept shown while pressed): drawn over the
        // frame, it differs from beside it (the renderer's read-back); then
        // dragged to the top, the viewport shows the first row and the
        // thumb the top of the track.
        const grab_y = @divTrunc(sb.thumb[1] + sb.thumb[3], 2);
        h.press(surf, x, grab_y);
        sb = try waitScroll(h, &g, ScrollState.isPressed, "pressed", 5000);
        try h.expect(sb.thumb[2] - sb.thumb[0] > thin, "pressed, the thumb is wide ({d} px)", .{sb.thumb[2] - sb.thumb[0]});
        const thumb_rect = sb.thumb;
        {
            const cy: u32 = @intCast(@divTrunc(sb.thumb[1] + sb.thumb[3], 2));
            const on = try h.probe(&g, @intCast(@divTrunc(sb.thumb[0] + sb.thumb[2], 2)), cy);
            const beside = try h.probe(&g, @intCast(sb.thumb[0] - 6), cy);
            try h.expect(on != beside, "the thumb is drawn (#{x:0>6} beside #{x:0>6})", .{ on, beside });
        }
        h.move(surf, x, @divTrunc(grab_y, 2), true);
        h.move(surf, x, 0, true);
        h.release(surf, x, 0);
        sb = try waitScroll(h, &g, ScrollState.atTop, "scrolled to the top", 5000);
        try h.expect(!sb.pressed and sb.thumb[1] < 12, "dragging the thumb to the top scrolls to the first row (thumb at {d})", .{sb.thumb[1]});

        // A click on the track below the thumb pages down.
        h.click(surf, x, rect.bottom - 10, .left);
        sb = try waitScroll(h, &g, ScrollState.onePageDown, "one page down", 5000);
        try h.expect(true, "a click below the thumb pages down ({d} rows)", .{sb.len});

        // Left alone, it fades.
        h.move(surf, mid_x, mid_y, false);
        sb = try waitScroll(h, &g, ScrollState.hidden, "faded", 5000);
        try h.expect(true, "it fades when idle", .{});

        // With Windows set to always show scroll bars, it stays.
        try h.setScrollbarsAlways(&g, true);
        h.move(surf, mid_x, mid_y, false);
        sb = try waitScroll(h, &g, ScrollState.shown, "shown, always", 5000);
        w.Sleep(2500);
        sb = try scrollState(h, &g);
        try h.expect(sb.visible, "with \"always show scrollbars\" it doesn't fade", .{});
        try h.setScrollbarsAlways(&g, false);
        sb = try waitScroll(h, &g, ScrollState.hidden, "faded again", 5000);

        // A program on the alternate screen: no scrollback there, and
        // nothing drawn where the thumb was.
        try h.typeText(surf, "powershell -NoProfile -Command \"[Console]::Write([char]27+'[?1049h'); Start-Sleep 5; [Console]::Write([char]27+'[?1049l')\"");
        h.enter(surf);
        sb = try waitScroll(h, &g, ScrollState.nothingToScroll, "nothing to scroll on the alternate screen", 10000);
        h.move(surf, mid_x, mid_y, false);
        h.sync(surf);
        sb = try scrollState(h, &g);
        {
            const cy: u32 = @intCast(@divTrunc(thumb_rect[1] + thumb_rect[3], 2));
            const on = try h.probe(&g, @intCast(@divTrunc(thumb_rect[0] + thumb_rect[2], 2)), cy);
            const beside = try h.probe(&g, @intCast(thumb_rect[0] - 6), cy);
            try h.expect(!sb.visible and on == beside, "the alternate screen shows no thumb (#{x:0>6}, beside #{x:0>6})", .{ on, beside });
        }
        sb = try waitScroll(h, &g, ScrollState.scrollable, "scrollback again after it", 15000);
        try quit(h, &g, surf);
    }
    {
        var g = try start(h, "scrollbar-never", "scrollbar = never\n", ">");
        defer g.deinit();
        const surf = try h.surface(&g, try h.mainWindow(&g));
        try h.typeText(surf, "for /l %i in (1,1,150) do @echo line-%i");
        h.enter(surf);
        try h.waitText(&g, "line-150", 1, 15000);
        _ = try waitScroll(h, &g, ScrollState.scrollable, "scrollback", 5000);
        var rect: w.RECT = .{};
        _ = w.GetClientRect(surf, &rect);
        h.move(surf, rect.right - 5, @divTrunc(rect.bottom, 2), false);
        h.sync(surf);
        const sb = try scrollState(h, &g);
        try h.expect(!sb.visible, "scrollbar = never shows nothing", .{});
        try quit(h, &g, surf);
    }
}

const ScrollState = struct {
    total: u64 = 0,
    offset: u64 = 0,
    len: u64 = 0,
    visible: bool = false,
    hover: bool = false,
    pressed: bool = false,
    thumb: [4]i32 = .{ 0, 0, 0, 0 },

    fn scrollable(s: ScrollState) bool {
        return s.total > s.len;
    }
    fn nothingToScroll(s: ScrollState) bool {
        return s.total <= s.len;
    }
    fn atBottom(s: ScrollState) bool {
        return s.total > s.len and s.offset + s.len == s.total;
    }
    fn atTop(s: ScrollState) bool {
        return s.total > s.len and s.offset == 0 and !s.pressed;
    }
    fn onePageDown(s: ScrollState) bool {
        return s.offset == s.len;
    }
    fn shown(s: ScrollState) bool {
        return s.visible;
    }
    fn hidden(s: ScrollState) bool {
        return !s.visible;
    }
    fn isPressed(s: ScrollState) bool {
        return s.pressed;
    }
    fn isHovered(s: ScrollState) bool {
        return s.hover and s.visible;
    }
};

/// The first window's active tab's columns.
fn paneCols(h: *Harness, g: *Harness.Ghostty) !u32 {
    var d = try h.dump(g);
    defer d.deinit();
    const dw = d.value.windows[0];
    return dw.tabs[dw.active].cols orelse h.fail("no columns in the dump", .{});
}

/// The first window's active pane's scrollbar, from a fresh dump.
fn scrollState(h: *Harness, g: *Harness.Ghostty) !ScrollState {
    var d = try h.dump(g);
    defer d.deinit();
    const dw = d.value.windows[0];
    const panes = dw.tabs[dw.active].panes orelse return h.fail("no panes in the dump", .{});
    const s = panes[0].scrollbar orelse return h.fail("no scrollbar in the dump", .{});
    return .{
        .total = s.total,
        .offset = s.offset,
        .len = s.len,
        .visible = s.visible,
        .hover = s.hover,
        .pressed = s.pressed,
        .thumb = s.thumb,
    };
}

fn waitScroll(h: *Harness, g: *Harness.Ghostty, cond: fn (ScrollState) bool, comptime what: []const u8, ms: u32) !ScrollState {
    var last: ScrollState = .{};
    var waited: u32 = 0;
    while (waited <= ms) : (waited += 100) {
        last = try scrollState(h, g);
        if (cond(last)) return last;
        w.Sleep(100);
    }
    return h.fail("the scrollbar never got " ++ what ++ " (rows {d}+{d} of {d}, shown {}, pressed {})", .{ last.offset, last.len, last.total, last.visible, last.pressed });
}

/// Which tab of window `win` holds the pane `pane`, and which is active.
fn tabOfPane(h: *Harness, g: *Harness.Ghostty, win: w.HWND, pane: w.HWND) !struct { tab: usize, active: usize } {
    var d = try h.dump(g);
    defer d.deinit();
    for (d.value.windows) |dw| {
        if (dw.hwnd != @intFromPtr(win)) continue;
        for (dw.tabs, 0..) |t, i| {
            const panes = t.panes orelse continue;
            for (panes) |p| if (p.hwnd == @intFromPtr(pane)) return .{ .tab = i, .active = dw.active };
        }
    }
    return h.fail("no tab holds the pane", .{});
}

const PaletteState = struct {
    open: bool = false,
    focused: bool = false,
    edit: u64 = 0,
    list: u64 = 0,
    dim: u64 = 0,
    row_height: i32 = 0,
    count: usize = 0,
    /// The selected row, or -1.
    selected: i64 = -1,
    /// The filter's text.
    text: [256]u8 = undefined,
    text_len: usize = 0,
    /// The listed titles, each followed by a line feed.
    titles: [8192]u8 = undefined,
    titles_len: usize = 0,
    /// The line beneath the first row's title.
    detail: [256]u8 = undefined,
    detail_len: usize = 0,

    fn firstDetail(self: *const PaletteState) []const u8 {
        return self.detail[0..self.detail_len];
    }

    fn filter(self: *const PaletteState) []const u8 {
        return self.text[0..self.text_len];
    }

    /// The row titled `title`.
    fn index(self: *const PaletteState, title: []const u8) ?usize {
        var it = std.mem.splitScalar(u8, self.titles[0..self.titles_len], '\n');
        var i: usize = 0;
        while (it.next()) |t| : (i += 1) if (std.mem.eql(u8, t, title)) return i;
        return null;
    }

    fn has(self: *const PaletteState, title: []const u8) bool {
        var it = std.mem.splitScalar(u8, self.titles[0..self.titles_len], '\n');
        while (it.next()) |t| if (std.mem.eql(u8, t, title)) return true;
        return false;
    }
    fn hasPrefix(self: *const PaletteState, prefix: []const u8) bool {
        var it = std.mem.splitScalar(u8, self.titles[0..self.titles_len], '\n');
        while (it.next()) |t| if (std.mem.startsWith(u8, t, prefix)) return true;
        return false;
    }
    fn first(self: *const PaletteState) []const u8 {
        const listed = self.titles[0..self.titles_len];
        return listed[0 .. std.mem.indexOfScalar(u8, listed, '\n') orelse listed.len];
    }
};

/// Window `win`'s command palette, from a fresh dump.
fn paletteState(h: *Harness, g: *Harness.Ghostty, win: w.HWND) !PaletteState {
    var d = try h.dump(g);
    defer d.deinit();
    const dw = for (d.value.windows) |dw| {
        if (dw.hwnd == @intFromPtr(win)) break dw;
    } else return h.fail("the window isn't in the dump", .{});
    const p = dw.palette orelse return h.fail("no palette in the dump", .{});
    var r: PaletteState = .{
        .open = p.open,
        .focused = p.focused,
        .edit = p.edit,
        .list = p.list,
        .dim = p.dim,
        .row_height = p.row_height,
        .count = p.items.len,
        .selected = p.selected,
    };
    r.text_len = @min(p.text.len, r.text.len);
    @memcpy(r.text[0..r.text_len], p.text[0..r.text_len]);
    for (p.items) |t| {
        if (r.titles_len + t.len + 1 > r.titles.len) break;
        @memcpy(r.titles[r.titles_len..][0..t.len], t);
        r.titles[r.titles_len + t.len] = '\n';
        r.titles_len += t.len + 1;
    }
    if (p.details.len > 0) {
        r.detail_len = @min(p.details[0].len, r.detail.len);
        @memcpy(r.detail[0..r.detail_len], p.details[0][0..r.detail_len]);
    }
    return r;
}

fn waitPalette(h: *Harness, g: *Harness.Ghostty, win: w.HWND, open: bool) !PaletteState {
    var waited: u32 = 0;
    while (waited <= 5000) : (waited += 100) {
        const p = try paletteState(h, g, win);
        if (p.open == open) return p;
        w.Sleep(100);
    }
    return h.fail("the command palette didn't {s}", .{if (open) "open" else "close"});
}

/// Wait until the palette's filter reads `typed` (all of it typed: the
/// dump can come between the characters) and its first row starts with
/// `prefix`.
fn waitPaletteFirst(h: *Harness, g: *Harness.Ghostty, win: w.HWND, typed: []const u8, prefix: []const u8) !PaletteState {
    const last = try waitPaletteText(h, g, win, typed);
    if (!std.mem.startsWith(u8, last.first(), prefix)) {
        return h.fail("for '{s}' the first row is '{s}', not '{s}...'", .{ typed, last.first(), prefix });
    }
    try h.expect(true, "'{s}' puts '{s}' first", .{ typed, last.first() });
    return last;
}

/// Wait until the open palette's filter reads `typed`.
fn waitPaletteText(h: *Harness, g: *Harness.Ghostty, win: w.HWND, typed: []const u8) !PaletteState {
    var last: PaletteState = .{};
    var waited: u32 = 0;
    while (waited <= 5000) : (waited += 100) {
        last = try paletteState(h, g, win);
        if (last.open and std.mem.eql(u8, last.filter(), typed)) return last;
        w.Sleep(100);
    }
    return h.fail("the palette's filter reads '{s}', not '{s}'", .{ last.filter(), typed });
}

/// Wait until the palette's selected row is `row`.
fn waitPaletteSelected(h: *Harness, g: *Harness.Ghostty, win: w.HWND, row: usize) !PaletteState {
    var last: PaletteState = .{};
    var waited: u32 = 0;
    while (waited <= 5000) : (waited += 100) {
        last = try paletteState(h, g, win);
        if (last.selected == row) return last;
        w.Sleep(100);
    }
    return h.fail("row {d} is selected, not {d}", .{ last.selected, row });
}

/// Wait until window `win`'s tab `index` is the active one.
fn waitActiveTab(h: *Harness, g: *Harness.Ghostty, win: w.HWND, index: usize) !void {
    var active: usize = 0;
    var waited: u32 = 0;
    while (waited <= 5000) : (waited += 100) {
        var d = try h.dump(g);
        defer d.deinit();
        for (d.value.windows) |dw| if (dw.hwnd == @intFromPtr(win)) {
            active = dw.active;
        };
        if (active == index) return;
        w.Sleep(100);
    }
    return h.fail("tab {d} is active, not {d}", .{ active, index });
}

/// The first tab's cell size in pixels.
fn paneCell(h: *Harness, g: *Harness.Ghostty) ![2]u32 {
    var d = try h.dump(g);
    defer d.deinit();
    return d.value.windows[0].tabs[0].cell orelse h.fail("no cell size in the dump", .{});
}

/// A pixel near the top of cell `col` of the first tab's row reading
/// `line`: the cell's background, above any glyph.
fn cellTop(h: *Harness, g: *Harness.Ghostty, line: []const u8, col: u32) !struct { x: u32, y: u32 } {
    var d = try h.dump(g);
    defer d.deinit();
    const t = d.value.windows[0].tabs[0];
    const text = t.text orelse return h.fail("no text in the dump", .{});
    const cell = t.cell orelse return h.fail("no cell size in the dump", .{});
    const pad = t.padding orelse return h.fail("no padding in the dump", .{});
    var rows = std.mem.splitScalar(u8, text, '\n');
    var row: u32 = 0;
    while (rows.next()) |r| : (row += 1) {
        if (std.mem.eql(u8, std.mem.trimEnd(u8, r, " "), line)) return .{
            .x = pad[0] + col * cell[0] + cell[0] / 2,
            .y = pad[1] + row * cell[1] + 1,
        };
    }
    return h.fail("no row reads '{s}'", .{line});
}

/// Wait for a second murrtty window besides `win`; returns it.
fn waitOtherWindow(h: *Harness, g: *Harness.Ghostty, win: w.HWND) !w.HWND {
    var waited: u32 = 0;
    while (waited <= 10000) : (waited += 100) {
        const wins = try h.windows(g, "MurrttyWindow");
        defer h.alloc.free(wins);
        if (wins.len == 2) {
            const other = if (wins[0] == win) wins[1] else wins[0];
            // Its pane, before keys go to it.
            if (h.child(g, other, "MurrttySurface") != null) return other;
        }
        w.Sleep(100);
    }
    return h.fail("no second window opened", .{});
}

fn waitWindowCount(h: *Harness, g: *Harness.Ghostty, count: usize) !void {
    var waited: u32 = 0;
    var last: usize = 0;
    while (waited <= 10000) : (waited += 100) {
        const wins = try h.windows(g, "MurrttyWindow");
        defer h.alloc.free(wins);
        last = wins.len;
        if (last == count) return;
        w.Sleep(100);
    }
    return h.fail("{d} windows, not {d}", .{ last, count });
}

/// Wait until `target` has the keyboard in `win`'s thread.
fn waitKeyboard(h: *Harness, win: w.HWND, target: w.HWND, comptime what: []const u8) !void {
    var waited: u32 = 0;
    while (waited <= 5000) : (waited += 100) {
        if (keyboardFocus(win) == target) return h.expect(true, what, .{});
        w.Sleep(100);
    }
    return h.fail("not so: " ++ what, .{});
}

/// The direct child of `parent` under its client point (`x`, `y`): what a
/// real click there would reach first.
fn childAt(parent: w.HWND, x: c_int, y: c_int) ?w.HWND {
    return w.ChildWindowFromPointEx(parent, .{ .x = x, .y = y }, w.CWP_SKIPINVISIBLE);
}

fn waitNoMenu(h: *Harness, g: *Harness.Ghostty) !void {
    var waited: u32 = 0;
    while (waited <= 5000) : (waited += 100) {
        if (try h.menuCount(g) == 0) return;
        w.Sleep(100);
    }
    return h.fail("the popup menu stayed open", .{});
}

fn waitClipboard(h: *Harness, want: []const u8) !void {
    var waited: u32 = 0;
    while (waited <= 5000) : (waited += 100) {
        if (try h.getClipboard()) |text| {
            defer h.alloc.free(text);
            if (std.mem.eql(u8, text, want)) return h.expect(true, "the clipboard holds '{s}'", .{want});
        }
        w.Sleep(100);
    }
    return h.fail("the clipboard never held '{s}'", .{want});
}

/// Client coordinates over the third cell of the first tab's row that
/// reads exactly `line`.
fn cellPoint(h: *Harness, g: *Harness.Ghostty, line: []const u8) !struct { x: c_int, y: c_int } {
    var d = try h.dump(g);
    defer d.deinit();
    const t = d.value.windows[0].tabs[0];
    const text = t.text orelse return h.fail("no text in the dump", .{});
    const cell = t.cell orelse return h.fail("no cell size in the dump", .{});
    const pad = t.padding orelse return h.fail("no padding in the dump", .{});
    var rows = std.mem.splitScalar(u8, text, '\n');
    var row: u32 = 0;
    while (rows.next()) |r| : (row += 1) {
        if (std.mem.eql(u8, std.mem.trimEnd(u8, r, " "), line)) return .{
            .x = @intCast(pad[0] + cell[0] * 2 + cell[0] / 2),
            .y = @intCast(pad[1] + row * cell[1] + cell[1] / 2),
        };
    }
    return h.fail("no row reads '{s}'", .{line});
}

/// The resize overlay (roadmap 3.0, GTK's): the grid size over a pane while
/// it resizes, not for a new pane's first size (after-first), gone after
/// resize-overlay-duration; never with `never`; with `always` also on a new
/// pane, at resize-overlay-position.
fn resizeOverlay(h: *Harness) anyerror!void {
    {
        var g = try start(h, "resize-overlay", "resize-overlay-duration = 1500ms\n", ">");
        defer g.deinit();
        const win = try h.mainWindow(&g);
        var pane = try paneOverlay(h, &g, 0);
        try h.expect(!pane.visible, "a new pane shows no resize overlay (after-first)", .{});
        // Past a new pane's first moments (250 ms), whose resizes still
        // count as its first size: cmd's prompt comes sooner.
        w.Sleep(500);

        var wr: w.RECT = .{};
        _ = w.GetWindowRect(win, &wr);
        _ = w.SetWindowPos(win, null, 0, 0, wr.right - wr.left + 120, wr.bottom - wr.top + 80, w.SWP_NOMOVE | w.SWP_NOZORDER | w.SWP_NOACTIVATE);
        w.Sleep(200);
        pane = try paneOverlay(h, &g, 0);
        var want_buf: [32]u8 = undefined;
        var want = try std.fmt.bufPrint(&want_buf, "{d} x {d}", .{ pane.cols, pane.rows });
        try h.expect(pane.visible, "resizing the window shows the overlay", .{});
        try h.expect(std.mem.eql(u8, pane.text(), want), "it shows the grid, {s} (got '{s}')", .{ want, pane.text() });
        w.Sleep(2000);
        pane = try paneOverlay(h, &g, 0);
        try h.expect(!pane.visible, "and is gone after resize-overlay-duration", .{});

        // A split shrinks the first pane (it shows its new grid); the new
        // pane's first size shows nothing. The split is done when the core's
        // binding returns, so no wait beyond the panes appearing.
        h.key(try h.surface(&g, win), .{ .ctrl = true, .shift = true }, 'O');
        try waitPanes(h, &g, 2);
        pane = try paneOverlay(h, &g, 0);
        want = try std.fmt.bufPrint(&want_buf, "{d} x {d}", .{ pane.cols, pane.rows });
        try h.expect(pane.visible and std.mem.eql(u8, pane.text(), want), "the split pane shows its new grid {s} (got '{s}', shown {})", .{ want, pane.text(), pane.visible });
        const new_pane = try paneOverlay(h, &g, 1);
        try h.expect(!new_pane.visible, "the new pane shows none", .{});
        try quit(h, &g, try h.surface(&g, win));
    }
    {
        var g = try start(h, "resize-overlay-never", "resize-overlay = never\n", ">");
        defer g.deinit();
        const win = try h.mainWindow(&g);
        // Past the first moments, as above, where after-first shows nothing
        // either: only `never` keeps a later resize from showing it.
        w.Sleep(500);
        var wr: w.RECT = .{};
        _ = w.GetWindowRect(win, &wr);
        _ = w.SetWindowPos(win, null, 0, 0, wr.right - wr.left + 120, wr.bottom - wr.top + 80, w.SWP_NOMOVE | w.SWP_NOZORDER | w.SWP_NOACTIVATE);
        w.Sleep(300);
        const pane = try paneOverlay(h, &g, 0);
        try h.expect(!pane.visible, "resize-overlay = never shows nothing", .{});
        try quit(h, &g, try h.surface(&g, win));
    }
    {
        var g = try start(h, "resize-overlay-always", "resize-overlay = always\nresize-overlay-position = top-left\nresize-overlay-duration = 30s\n", ">");
        defer g.deinit();
        const win = try h.mainWindow(&g);
        const pane = try paneOverlay(h, &g, 0);
        try h.expect(pane.visible, "resize-overlay = always shows on a new pane", .{});
        const surf = try h.surface(&g, win);
        const overlay = h.child(&g, surf, "MurrttyOverlay") orelse return h.fail("no overlay window", .{});
        var sr: w.RECT = .{};
        var orect: w.RECT = .{};
        _ = w.GetWindowRect(surf, &sr);
        _ = w.GetWindowRect(overlay, &orect);
        const dx = orect.left - sr.left;
        const dy = orect.top - sr.top;
        try h.expect(dx > 0 and dx < 40 and dy > 0 and dy < 40, "top-left: at ({d},{d}) in the pane", .{ dx, dy });
        try quit(h, &g, surf);
    }
}

const PaneOverlay = struct {
    visible: bool,
    cols: u32,
    rows: u32,
    buf: [32]u8 = undefined,
    len: usize = 0,

    fn text(self: *const PaneOverlay) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Pane `i`'s resize overlay and grid, from a fresh dump.
fn paneOverlay(h: *Harness, g: *Harness.Ghostty, i: usize) !PaneOverlay {
    var d = try h.dump(g);
    defer d.deinit();
    const dw = d.value.windows[0];
    const panes = dw.tabs[dw.active].panes orelse return h.fail("no panes in the dump", .{});
    if (i >= panes.len) return h.fail("no pane {d}", .{i});
    const p = panes[i];
    const o = p.resize_overlay orelse return h.fail("no resize_overlay in the dump", .{});
    var result: PaneOverlay = .{ .visible = o.visible, .cols = p.cols orelse 0, .rows = p.rows orelse 0 };
    result.len = @min(o.text.len, result.buf.len);
    @memcpy(result.buf[0..result.len], o.text[0..result.len]);
    return result;
}

/// Whether two Windows paths are the same text, ignoring case and taking
/// `/` and `\` as one (the core joins its config subfolder with `/`).
fn pathEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const xs = if (x == '/') '\\' else std.ascii.toLower(x);
        const ys = if (y == '/') '\\' else std.ascii.toLower(y);
        if (xs != ys) return false;
    }
    return true;
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
/// Bash) is not taken as the command. With no config, the shell is
/// PowerShell 7 (roadmap 2.5; the GUI tests need it installed).
fn launchContext(h: *Harness) anyerror!void {
    // PowerShell starts with its shell integration, so quitting at its
    // idle prompt doesn't ask.

    // The harness starts Ghostty in the scenario's folder, as a shell would.
    {
        var g = try h.launchWith("launch-context", "", .{});
        defer g.deinit();
        const text = try textWith(h, &g, ">");
        defer h.alloc.free(text);
        try h.expect(std.ascii.findIgnoreCase(text, g.dir) != null, "started from a program, it opens in that program's directory", .{});
        try h.expect(std.mem.indexOf(u8, text, "PS ") != null and std.mem.indexOf(u8, text, "PowerShell 7.") == null, "no config starts PowerShell, with no banner (-NoLogo)", .{});
        const surf = try h.surface(&g, try h.mainWindow(&g));
        try h.typeText(surf, "'major=' + $PSVersionTable.PSVersion.Major");
        h.enter(surf);
        try waitTabLine(h, &g, 0, "major=7");
        try quitIdle(h, &g, surf);
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
        try quitIdle(h, &g, try h.surface(&g, try h.mainWindow(&g)));
    }
    // The default command itself has -NoLogo (with the integration off, so
    // the arguments are Ghostty's default as they are).
    {
        var g = try h.launchWith("launch-context-nologo", "shell-integration = none\n", .{});
        defer g.deinit();
        const text = try textWith(h, &g, ">");
        defer h.alloc.free(text);
        try h.expect(std.mem.indexOf(u8, text, "PS ") != null and std.mem.indexOf(u8, text, "PowerShell 7.") == null, "the default command starts PowerShell with -NoLogo", .{});
        try quit(h, &g, try h.surface(&g, try h.mainWindow(&g)));
    }
    // SHELL from Git Bash is ignored: the default shell starts.
    {
        var g = try h.launchWith("launch-context-shell", "", .{ .env = &.{.{ "SHELL", "/usr/bin/bash" }} });
        defer g.deinit();
        const text = try textWith(h, &g, ">");
        defer h.alloc.free(text);
        try h.expect(std.mem.indexOf(u8, text, "PS ") != null, "SHELL=/usr/bin/bash still starts PowerShell", .{});
        try quitIdle(h, &g, try h.surface(&g, try h.mainWindow(&g)));
    }
}

/// CLI actions with their output on a pipe, as PowerShell captures it:
/// +version names murrtty; +validate-config exits 0 and says nothing for a
/// valid file (it exited 1: with nothing written, its writer then tried to
/// set the pipe's length), and 1 naming the problem for an invalid one.
fn cli(h: *Harness) anyerror!void {
    const dir = try std.fmt.allocPrint(h.alloc, "{s}\\cli", .{h.temp_dir});
    defer h.alloc.free(dir);
    try h.makeDirAt(dir);
    const valid = try std.fmt.allocPrint(h.alloc, "{s}\\valid.ghostty", .{dir});
    defer h.alloc.free(valid);
    try h.writeFileAt(valid, "split-divider-color = #ffffff\n");
    const invalid = try std.fmt.allocPrint(h.alloc, "{s}\\invalid.ghostty", .{dir});
    defer h.alloc.free(invalid);
    try h.writeFileAt(invalid, "no-such-option = 1\n");

    {
        var r = try h.runCli("cli", &.{"+version"});
        defer r.deinit();
        try h.expect(r.code == 0 and std.mem.indexOf(u8, r.out, "murrtty") != null, "+version exits 0 and names murrtty (exit {d})", .{r.code});
    }
    {
        const arg = try std.fmt.allocPrint(h.alloc, "--config-file={s}", .{valid});
        defer h.alloc.free(arg);
        var r = try h.runCli("cli", &.{ "+validate-config", arg });
        defer r.deinit();
        try h.expect(r.code == 0 and std.mem.trim(u8, r.out, " \r\n").len == 0, "+validate-config: a valid file exits 0, saying nothing (exit {d}, '{s}')", .{ r.code, r.out });
    }
    {
        const arg = try std.fmt.allocPrint(h.alloc, "--config-file={s}", .{invalid});
        defer h.alloc.free(arg);
        var r = try h.runCli("cli", &.{ "+validate-config", arg });
        defer r.deinit();
        try h.expect(r.code == 1 and std.mem.indexOf(u8, r.out, "no-such-option") != null, "+validate-config: an invalid file exits 1, naming the problem (exit {d}, '{s}')", .{ r.code, std.mem.trim(u8, r.out, " \r\n") });
    }
}

/// With font-family set, bold and italic text use the family's own Bold
/// and Italic faces, not the regular one (roadmap 0.9). Read from
/// Ghostty's log.
fn fonts(h: *Harness) anyerror!void {
    var g = try start(h, "fonts", "font-family = Consolas\n", ">");
    defer g.deinit();
    w.Sleep(1000);
    const path = try std.fmt.allocPrint(h.alloc, "{s}\\murrtty.log", .{g.dir});
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
    const wins = try h.windows(&g, "MurrttyWindow");
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

/// Spike S1 (roadmap 3.0): can text and interactive overlays be child
/// windows over a WGL surface? A magenta window over each of two panes, as
/// a sibling of the surface, a child of it and a layered child, captured
/// through DWM while the panes flood output and the window resizes. Like
/// pixels, it runs on the user's desktop far off-screen. Only the layered
/// child is required to pass (the roadmap's S1 row has why); run it on
/// each GPU vendor.
fn overlayHost(h: *Harness) anyerror!void {
    if (w.GetEnvironmentVariableW(w.L("GHOSTTY_GUI_SPIKE"), null, 0) == 0) {
        return h.skip("set GHOSTTY_GUI_SPIKE=1 to run it", .{});
    }
    if (h.capturesWork()) |why| return h.skip("{s}", .{why});
    const Ctx = struct { h: *Harness, err: ?anyerror = null };
    var ctx: Ctx = .{ .h = h };
    h.runOnUserDesktop(&ctx, struct {
        fn run(cx: *Ctx) void {
            overlayHostOffscreen(cx.h) catch |err| {
                cx.err = err;
            };
        }
    }.run);
    if (ctx.err) |err| return err;
}

const overlay_magenta = 0xFF00FF;
/// What an overlay draws for WM_PRINTCLIENT: a capture showing it didn't
/// come from what DWM composed.
const overlay_green = 0x00FF00;

const OverlayStats = struct {
    /// Captures, and those not taken the moment a resize returned (when
    /// Ghostty may not have painted yet).
    captures: u32 = 0,
    steady: u32 = 0,
    /// Steady captures with an overlay pixel that isn't magenta, and the
    /// most such pixels in one.
    dirty: u32 = 0,
    dirty_most: usize = 0,
    /// Steady captures with magenta outside the overlays.
    stale: u32 = 0,
    /// Steady captures dirty or stale whose overlays still were 200 ms on.
    lasting: u32 = 0,
    /// The same two, for captures taken as a resize returned.
    dirty_at_resize: u32 = 0,
    stale_at_resize: u32 = 0,
    /// Captures drawn by WM_PRINTCLIENT instead of DWM.
    printed: u32 = 0,
    /// Steady captures whose terminal pixels differ from the capture
    /// before.
    changed: u32 = 0,
    last_sum: u64 = 0,
};

fn overlayHostOffscreen(h: *Harness) !void {
    var g = try h.launchAt("overlay-host", base_config, .offscreen);
    defer g.deinit();
    try h.waitText(&g, ">", 1, 20000);
    const win = try h.mainWindow(&g);
    h.key(try h.surface(&g, win), .{ .ctrl = true, .shift = true }, 'O');
    try waitPanes(h, &g, 2);
    try waitPaneText(h, &g, 1, ">", 1);
    var panes: [2]w.HWND = undefined;
    for (&panes, 0..) |*p, i| p.* = try paneHwnd(h, &g, i);
    var wr: w.RECT = .{};
    _ = w.GetWindowRect(win, &wr);
    const width = wr.right - wr.left;
    const height = wr.bottom - wr.top;

    const names = [_][]const u8{ "sibling", "child", "layered child" };
    var failed = false;
    for (names, 1..) |name, k| {
        const kind: u8 = @intCast(k);
        var overlays: [2]w.HWND = undefined;
        {
            var d = try h.setOverlays(&g, kind);
            defer d.deinit();
            if (d.value.overlays.len != overlays.len) {
                std.debug.print("\n    {s}: {d} overlays created, expected {d}", .{ name, d.value.overlays.len, overlays.len });
                failed = true;
                continue;
            }
            for (&overlays, d.value.overlays) |*o, v| o.* = hwndOf(v.hwnd);
        }
        w.Sleep(300);
        var idle: OverlayStats = .{};
        _ = try overlayCapture(h, win, &overlays, &idle, false);

        // Flood both panes, and resize the window before every third
        // capture.
        for (panes) |p| {
            try h.typeText(p, "for /l %i in (1,1,1000000) do @echo %i the quick brown fox jumps over the lazy dog");
            h.enter(p);
        }
        w.Sleep(500);
        var flood: OverlayStats = .{};
        for (0..150) |i| {
            if (i % 3 == 0) {
                const dw: i32 = @as(i32, @intCast(i % 7)) * 40 - 120;
                const dh: i32 = @as(i32, @intCast(i % 5)) * 30 - 60;
                _ = w.SetWindowPos(win, null, 0, 0, width + dw, height + dh, w.SWP_NOMOVE | w.SWP_NOZORDER | w.SWP_NOACTIVATE);
                _ = try overlayCapture(h, win, &overlays, &flood, true);
                // Two frames on, when DWM would have shown it.
                w.Sleep(33);
            } else {
                w.Sleep(@intCast(i % 4 * 10));
            }
            if (try overlayCapture(h, win, &overlays, &flood, false)) {
                // Whether it lasts.
                var later: OverlayStats = .{};
                w.Sleep(200);
                if (try overlayCapture(h, win, &overlays, &later, false)) flood.lasting += 1;
            }
        }
        const paints = paints: {
            var d = try h.dump(&g);
            defer d.deinit();
            var n: u32 = 0;
            for (d.value.overlays) |o| n += o.paints;
            break :paints n;
        };

        // Removed while flooding, then while idle: nothing of them stays.
        const left_flooding = try overlayRemoved(h, &g, win, kind);
        for (panes) |p| h.key(p, .{ .ctrl = true }, 'C');
        w.Sleep(1000);
        _ = w.SetWindowPos(win, null, 0, 0, width, height, w.SWP_NOMOVE | w.SWP_NOZORDER | w.SWP_NOACTIVATE);
        w.Sleep(300);
        const left_idle = try overlayRemoved(h, &g, win, kind);

        std.debug.print("\n    {s}: idle {d} dirty px; flooding, of {d} captures {d} dirty (most {d} px) and {d} stale, " ++
            "{d} of them still 200 ms on; as a resize returned, of {d} {d} dirty and {d} stale; " ++
            "{d} printed; terminal changed in {d}; {d} paints; removed: {d} px left flooding, {d} idle", .{
            name,
            idle.dirty_most,
            flood.steady,
            flood.dirty,
            flood.dirty_most,
            flood.stale,
            flood.lasting,
            flood.captures - flood.steady,
            flood.dirty_at_resize,
            flood.stale_at_resize,
            flood.printed,
            flood.changed,
            paints,
            left_flooding,
            left_idle,
        });
        // The layered child is the host 3.0 builds on, and must stay clean
        // throughout. The others are reported for comparison: on NVIDIA
        // they leave a ghost where they were for up to 200 ms.
        const clean = idle.dirty == 0 and flood.dirty == 0 and flood.stale == 0 and
            flood.dirty_at_resize == 0 and flood.stale_at_resize == 0 and
            left_flooding == 0 and left_idle == 0;
        // Captures must come from DWM, with the terminal drawing.
        const measured = flood.printed == 0 and flood.changed * 2 > flood.steady;
        if (!measured or (kind == 3 and !clean)) failed = true;
    }
    std.debug.print("\n", .{});
    try h.expect(!failed, "the layered child stayed clean and left nothing behind; every capture came from DWM", .{});
}

/// Capture the window and check the overlays in it. Returns whether an
/// overlay was dirty or stale.
fn overlayCapture(h: *Harness, win: w.HWND, overlays: []const w.HWND, stats: *OverlayStats, at_resize: bool) !bool {
    var img = h.capture(win) catch return h.fail("capture failed", .{});
    defer img.deinit();
    var wr: w.RECT = .{};
    _ = w.GetWindowRect(win, &wr);
    var rects: [4]w.RECT = undefined;
    for (overlays, 0..) |o, i| {
        var r: w.RECT = .{};
        _ = w.GetWindowRect(o, &r);
        rects[i] = .{ .left = r.left - wr.left, .top = r.top - wr.top, .right = r.right - wr.left, .bottom = r.bottom - wr.top };
    }
    var dirty: usize = 0;
    var stale: usize = 0;
    var printed = false;
    var sum: u64 = 0;
    for (0..img.height) |y| for (0..img.width) |x| {
        const px = img.rgb(x, y);
        const xi: i32 = @intCast(x);
        const yi: i32 = @intCast(y);
        const inside = for (rects[0..overlays.len]) |r| {
            if (xi >= r.left and xi < r.right and yi >= r.top and yi < r.bottom) break true;
        } else false;
        if (inside) {
            if (px != overlay_magenta) dirty += 1;
            if (px == overlay_green) printed = true;
        } else {
            if (px == overlay_magenta) stale += 1;
            sum = sum *% 31 +% px;
        }
    };
    stats.captures += 1;
    if (printed) stats.printed += 1;
    if (at_resize) {
        if (dirty > 0) stats.dirty_at_resize += 1;
        if (stale > 0) stats.stale_at_resize += 1;
    } else {
        stats.steady += 1;
        if (dirty > 0) stats.dirty += 1;
        stats.dirty_most = @max(stats.dirty_most, dirty);
        if (stale > 0) stats.stale += 1;
        if (sum != stats.last_sum) stats.changed += 1;
    }
    stats.last_sum = sum;
    return dirty > 0 or stale > 0;
}

/// Put fresh overlays of `kind` up, remove them, and return how many
/// magenta pixels the window still shows 200 ms later.
fn overlayRemoved(h: *Harness, g: *Harness.Ghostty, win: w.HWND, kind: u8) !usize {
    (try h.setOverlays(g, kind)).deinit();
    w.Sleep(300);
    (try h.setOverlays(g, 0)).deinit();
    w.Sleep(200);
    var img = h.capture(win) catch return h.fail("capture failed", .{});
    defer img.deinit();
    var n: usize = 0;
    for (img.pixels) |px| {
        if (px & 0xFFFFFF == overlay_magenta) n += 1;
    }
    return n;
}

/// Spike S2 (roadmap 4.1): with blur-behind (an empty region) on the
/// top-level window, does DWM compose the panes' GL output with its alpha?
/// Ghostty at background-opacity 0.5 over a green backdrop, read back from
/// the screen. Both windows show on the owner's screen for a few seconds,
/// above everything else, so it runs only when asked.
fn transparency(h: *Harness) anyerror!void {
    if (w.GetEnvironmentVariableW(w.L("GHOSTTY_GUI_ONSCREEN"), null, 0) == 0) {
        return h.skip("it shows windows on the screen; set GHOSTTY_GUI_ONSCREEN=1 to run it", .{});
    }
    if (h.capturesWork()) |why| return h.skip("{s}", .{why});
    const Ctx = struct { h: *Harness, err: ?anyerror = null };
    var ctx: Ctx = .{ .h = h };
    h.runOnUserDesktop(&ctx, struct {
        fn run(cx: *Ctx) void {
            transparencyOnScreen(cx.h) catch |err| {
                cx.err = err;
            };
        }
    }.run);
    if (ctx.err) |err| return err;
}

const backdrop_green = 0x00FF00;

fn transparencyOnScreen(h: *Harness) !void {
    var g = try h.launchAt("transparency", base_config ++ "background-opacity = 0.5\n", .onscreen);
    defer g.deinit();
    try h.waitText(&g, ">", 1, 20000);
    const win = try h.mainWindow(&g);
    var wr: w.RECT = .{};
    _ = w.GetWindowRect(win, &wr);
    var backdrop = try Harness.Backdrop.create(wr, backdrop_green);
    defer backdrop.destroy();
    _ = w.SetWindowPos(win, w.HWND_TOPMOST, 0, 0, 0, 0, w.SWP_NOMOVE | w.SWP_NOSIZE | w.SWP_NOACTIVATE);
    h.pump(500);

    // Read from the display (desktop duplication): on screen the GL panes
    // may be presented outside the window's GDI surface, which BitBlt and
    // PrintWindow read. A background pixel near the bottom right.
    const client = clientOnScreen(win);
    const bx: usize = @intCast(client.right - client.left - 30);
    const by: usize = @intCast(client.bottom - client.top - 30);
    const opaque_px = try displayPixel(h, &g, client, bx, by, "opaque.bmp");
    const opaque_gdi = try screenPixel(h, client, bx, by);

    // Spike S1's three hosts over the opaque pane: which ones show?
    var hosts: [3]u32 = undefined;
    for (&hosts, 1..) |*px, kind| px.* = try overlayOnDisplay(h, &g, client, @intCast(kind));

    try h.setTransparent(&g, true);
    h.pump(500);
    const see_through = try displayPixel(h, &g, client, bx, by, "see-through.bmp");
    const see_through_gdi = try screenPixel(h, client, bx, by);
    const layered_over_clear = try overlayOnDisplay(h, &g, client, 3);

    // A split's divider is painted with GDI, which leaves alpha 0. The new
    // pane starts opaque until it is switched too.
    h.key(try h.surface(&g, win), .{ .ctrl = true, .shift = true }, 'O');
    try waitPanes(h, &g, 2);
    try h.setTransparent(&g, true);
    h.pump(800);
    const divider_px = divider: {
        var d = try h.dump(&g);
        defer d.deinit();
        const t = d.value.windows[0].tabs[0];
        const dv = (t.dividers orelse break :divider @as(u32, 0));
        if (dv.len == 0) break :divider @as(u32, 0);
        const container = w.GetParent(hwndOf(t.panes.?[0].hwnd)) orelse break :divider @as(u32, 0);
        var pt = [1]w.POINT{.{ .x = @divTrunc(dv[0][0] + dv[0][2], 2), .y = @divTrunc(dv[0][1] + dv[0][3], 2) }};
        _ = w.MapWindowPoints(container, null, &pt, 1);
        break :divider try displayPixel(h, &g, client, @intCast(pt[0].x - client.left), @intCast(pt[0].y - client.top), "split.bmp");
    };

    try h.setTransparent(&g, false);
    h.pump(500);
    const opaque_again = try displayPixel(h, &g, client, bx, by, "opaque-again.bmp");

    std.debug.print("\n    display: opaque #{x:0>6}; overlays on it: sibling #{x:0>6}, child #{x:0>6}, layered child #{x:0>6}; " ++
        "see-through #{x:0>6} (#14951a if DWM blends with the alpha, #14161a if it ignores it); layered child on it #{x:0>6}; " ++
        "GDI divider #{x:0>6}; opaque again #{x:0>6}\n    GDI's view (BitBlt): opaque #{x:0>6}, see-through #{x:0>6}\n", .{
        opaque_px,  hosts[0],     hosts[1],   hosts[2],        see_through, layered_over_clear,
        divider_px, opaque_again, opaque_gdi, see_through_gdi,
    });
    try h.expect(near(opaque_px, 0x282c34, 2), "opaque, the background is #282c34 (got #{x:0>6})", .{opaque_px});
    try h.expect(hosts[2] == overlay_magenta, "a layered child shows over the pane (got #{x:0>6})", .{hosts[2]});
    try h.expect(near(see_through, 0x14951a, 4), "see-through, the backdrop shows through half (got #{x:0>6})", .{see_through});
    try h.expect(layered_over_clear == overlay_magenta, "a layered child stays opaque over it (got #{x:0>6})", .{layered_over_clear});
    try h.expect(near(opaque_again, 0x282c34, 2), "opaque again (got #{x:0>6})", .{opaque_again});
}

/// The display's pixel at (`x`, `y`) of `area`; the capture is kept as
/// `name` in the scenario's folder.
fn displayPixel(h: *Harness, g: *Harness.Ghostty, area: w.RECT, x: usize, y: usize, name: []const u8) !u32 {
    var img = try h.captureDisplay(area);
    defer img.deinit();
    saveImage(h, g, &img, name);
    if (x >= img.width or y >= img.height) return h.fail("({d},{d}) is outside the capture", .{ x, y });
    return img.rgb(x, y);
}

/// Put spike S1's overlays of `kind` up and return the display's pixel at
/// the middle of the first; then take them down.
fn overlayOnDisplay(h: *Harness, g: *Harness.Ghostty, client: w.RECT, kind: u8) !u32 {
    defer if (h.setOverlays(g, 0)) |d| {
        var dd = d;
        dd.deinit();
    } else |_| {};
    var d = try h.setOverlays(g, kind);
    defer d.deinit();
    if (d.value.overlays.len == 0) return 0;
    h.pump(300);
    var r: w.RECT = .{};
    _ = w.GetWindowRect(hwndOf(d.value.overlays[0].hwnd), &r);
    var name_buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "overlay-{d}.bmp", .{kind}) catch "overlay.bmp";
    return displayPixel(h, g, client, @intCast(@divTrunc(r.left + r.right, 2) - client.left), @intCast(@divTrunc(r.top + r.bottom, 2) - client.top), name);
}

fn saveImage(h: *Harness, g: *Harness.Ghostty, img: *const Harness.Image, name: []const u8) void {
    const path = std.fmt.allocPrint(h.alloc, "{s}\\{s}", .{ g.dir, name }) catch return;
    defer h.alloc.free(path);
    img.save(path) catch {};
}

/// The client area of `hwnd` in screen pixels.
fn clientOnScreen(hwnd: w.HWND) w.RECT {
    var r: w.RECT = .{};
    _ = w.GetClientRect(hwnd, &r);
    var pts = [2]w.POINT{ .{ .x = r.left, .y = r.top }, .{ .x = r.right, .y = r.bottom } };
    _ = w.MapWindowPoints(hwnd, null, &pts, 2);
    return .{ .left = pts[0].x, .top = pts[0].y, .right = pts[1].x, .bottom = pts[1].y };
}

/// The screen's pixel at (`x`, `y`) of `area`, 0xRRGGBB.
fn screenPixel(h: *Harness, area: w.RECT, x: usize, y: usize) !u32 {
    var img = h.captureScreen(area) catch return h.fail("screen capture failed", .{});
    defer img.deinit();
    if (x >= img.width or y >= img.height) return h.fail("({d},{d}) is outside the capture", .{ x, y });
    return img.rgb(x, y);
}

/// Whether each channel of two 0xRRGGBB colors is within `tolerance`.
fn near(a: u32, b: u32, tolerance: u32) bool {
    var shift: u5 = 0;
    while (shift <= 16) : (shift += 8) {
        const x: i32 = @intCast((a >> shift) & 0xFF);
        const y: i32 = @intCast((b >> shift) & 0xFF);
        if (@abs(x - y) > tolerance) return false;
    }
    return true;
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

/// goto_split (wrapping previous/next, also on Windows's Ctrl+Shift+[ and ],
/// and a direction), toggle_split_zoom
/// (the zoomed pane fills the tab, the others are hidden and stop drawing
/// while their output still arrives), moving to another pane ending the
/// zoom, resize_split (stepping from where the divider is drawn) and
/// equalize_splits; a pane's minimum following its font; a zoom ending
/// when its pane is the last.
fn splitCommands(h: *Harness) anyerror!void {
    const cs: Harness.Mods = .{ .ctrl = true, .shift = true };
    const f1 = 0x70;
    const f2 = 0x71;
    const f3 = 0x72;
    const f4 = 0x73;
    const f5 = 0x74;
    const f6 = 0x75;
    const f7 = 0x76;
    const f8 = 0x77;
    var g = try start(h, "split-commands",
        \\keybind = ctrl+shift+f1=goto_split:previous
        \\keybind = ctrl+shift+f2=goto_split:next
        \\keybind = ctrl+shift+f3=goto_split:left
        \\keybind = ctrl+shift+f4=equalize_splits
        \\keybind = ctrl+shift+f5=resize_split:right,100
        \\keybind = ctrl+shift+f6=resize_split:left,4000
        \\keybind = ctrl+shift+f7=resize_split:right,20
        \\keybind = ctrl+shift+f8=increase_font_size:4
        \\keybind = ctrl+shift+w=close_surface
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
    // Windows's own defaults for next and previous: Ctrl+Shift+] and [.
    h.key(a, cs, 0xDD);
    try expectFocus(h, &g, win, b, "Ctrl+Shift+] (next) from A: B");
    h.key(b, cs, 0xDB);
    try expectFocus(h, &g, win, a, "Ctrl+Shift+[ (previous) from B: A");

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
    try expectZoomTitle(h, win, true);
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
    try expectZoomTitle(h, win, false);

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

    // A big step left takes the ratio to 0, well past where A's minimum
    // holds the divider; a small step right still moves it, from there.
    h.key(a, cs, f6);
    w.Sleep(800);
    try expectMinimumWidth(h, &g, 0, "a big step left leaves A its minimum");
    const held = try rootDivider(h, &g);
    h.key(a, cs, f7);
    w.Sleep(800);
    const step: i32 = @intCast((20 * dpi + 48) / 96);
    const stepped = try rootDivider(h, &g);
    try h.expect(@abs(stepped - held - step) <= 2, "a step right from the minimum moved the divider {d} px (expected {d})", .{ stepped - held, step });

    // A's minimum follows its font: larger cells widen it.
    h.key(a, cs, f6);
    h.key(a, cs, f8);
    h.key(a, cs, f8);
    w.Sleep(1000);
    try expectMinimumWidth(h, &g, 0, "at a larger font, A keeps its minimum");

    // A zoom on a pane that becomes the tab's last ends with the split.
    // B goes with the README's keybinding for closing one pane, which asks
    // first (its shell is running).
    h.key(a, cs, w.VK_RETURN);
    w.Sleep(500);
    try h.typeText(cc, "exit");
    h.enter(cc);
    try waitPanes(h, &g, 2);
    h.key(b, cs, 'W');
    const split_dlg = try h.waitDialog(&g, 5000);
    try expectDialogText(h, &g, "Close Split?", "The currently running process in this split will be terminated.");
    h.answer(&g, split_dlg, w.IDYES);
    try waitPanes(h, &g, 1);
    w.Sleep(300);
    {
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(!(d.value.windows[0].tabs[0].zoomed orelse true), "the zoom ended with the last split", .{});
    }
    try quit(h, &g, a);
}

/// The window title starts with the zoom magnifier, or doesn't.
fn expectZoomTitle(h: *Harness, win: w.HWND, zoomed: bool) !void {
    const t = try h.title(win);
    defer h.alloc.free(t);
    const marked = std.mem.startsWith(u8, t, "\u{1F50D} ");
    try h.expect(marked == zoomed, "the window title {s} the magnifier ({s})", .{ if (zoomed) "has" else "lacks", t });
}

/// Pane `i` is at least the core's minimum, 10 columns, at its font.
fn expectMinimumWidth(h: *Harness, g: *Harness.Ghostty, i: usize, comptime what: []const u8) !void {
    var d = try h.dump(g);
    defer d.deinit();
    const p = d.value.windows[0].tabs[0].panes.?;
    const cols = p[i].cols orelse 0;
    try h.expect(cols >= 10, what ++ " (10 columns, has {d})", .{cols});
}

/// Divider mouse handling, with mouse messages posted to the tab's
/// container as Windows routes them there: a drag moves the divider by the
/// distance dragged, Esc puts it back, a double-click equalizes; and a
/// pane's padding next to a divider is transparent to hit-testing (so the
/// container gets the mouse there) but not in the middle or on the outer
/// edge.
fn splitMouse(h: *Harness) anyerror!void {
    var g = try start(h, "split-mouse", "", ">");
    defer g.deinit();
    const win = try h.mainWindow(&g);
    h.key(try h.surface(&g, win), .{ .ctrl = true, .shift = true }, 'O');
    try waitPanes(h, &g, 2);
    w.Sleep(1500);
    const left_pane = try paneHwnd(h, &g, 0);
    const right_pane = try paneHwnd(h, &g, 1);
    const container = w.GetParent(left_pane) orelse return h.fail("pane without a container", .{});
    const start_x = try rootDivider(h, &g);
    const y: i32 = 200;

    // Drag 120 px right.
    postMouse(container, w.WM_LBUTTONDOWN, start_x, y);
    postMouse(container, w.WM_MOUSEMOVE, start_x + 60, y);
    postMouse(container, w.WM_MOUSEMOVE, start_x + 120, y);
    postMouse(container, w.WM_LBUTTONUP, start_x + 120, y);
    w.Sleep(600);
    const dragged = try rootDivider(h, &g);
    try h.expect(@abs(dragged - (start_x + 120)) <= 1, "the drag moved the divider to {d} (expected {d})", .{ dragged, start_x + 120 });

    // Esc during a drag puts it back, and none of that keystroke reaches
    // the core, neither its auto-repeat nor its release: the pane's count of
    // key events stays put (a release encodes nothing at cmd's prompt), and
    // what is typed there stays (an Esc would clear it).
    try h.typeText(right_pane, "abc");
    try waitPaneText(h, &g, 1, ">abc", 1);
    const keys_before = blk: {
        var d = try h.dump(&g);
        defer d.deinit();
        break :blk d.value.windows[0].tabs[0].panes.?[1].keys orelse return h.fail("no key count in the dump", .{});
    };
    postMouse(container, w.WM_LBUTTONDOWN, dragged, y);
    postMouse(container, w.WM_MOUSEMOVE, dragged - 200, y);
    w.Sleep(300);
    const mid_drag = try rootDivider(h, &g);
    try h.expect(@abs(mid_drag - (dragged - 200)) <= 1, "mid-drag the divider follows the mouse ({d})", .{mid_drag});
    const esc: usize = 1 | (@as(usize, w.MapVirtualKeyW(w.VK_ESCAPE, w.MAPVK_VK_TO_VSC)) << 16);
    _ = w.PostMessageW(right_pane, w.WM_KEYDOWN, w.VK_ESCAPE, @bitCast(esc));
    _ = w.PostMessageW(right_pane, w.WM_KEYDOWN, w.VK_ESCAPE, @bitCast(esc | (1 << 30)));
    _ = w.PostMessageW(right_pane, w.WM_KEYUP, w.VK_ESCAPE, @bitCast(esc | (3 << 30)));
    postMouse(container, w.WM_LBUTTONUP, dragged - 200, y);
    w.Sleep(600);
    const after_esc = try rootDivider(h, &g);
    try h.expect(@abs(after_esc - dragged) <= 1, "Esc put it back at {d} (is {d})", .{ dragged, after_esc });
    {
        var d = try h.dump(&g);
        defer d.deinit();
        const p = d.value.windows[0].tabs[0].panes.?;
        try h.expect(std.mem.indexOf(u8, p[1].text orelse "", ">abc") != null, "the typed text is still at the prompt", .{});
        const keys = p[1].keys orelse 0;
        try h.expect(keys == keys_before, "no key event of that Esc reached the core ({d} before, {d} after)", .{ keys_before, keys });
    }

    // A double-click equalizes.
    postMouse(container, w.WM_LBUTTONDBLCLK, after_esc, y);
    w.Sleep(600);
    const equalized = try rootDivider(h, &g);
    try h.expect(@abs(equalized - start_x) <= 1, "a double-click equalized it to {d} (is {d})", .{ start_x, equalized });

    // Hit-testing on the left pane: its right padding borders the divider.
    var r: w.RECT = .{};
    _ = w.GetWindowRect(left_pane, &r);
    const mid_y = @divTrunc(r.top + r.bottom, 2);
    try h.expect(hitTest(left_pane, r.right - 1, mid_y) == w.HTTRANSPARENT, "the padding next to the divider is the grip band", .{});
    try h.expect(hitTest(left_pane, @divTrunc(r.left + r.right, 2), mid_y) == w.HTCLIENT, "the middle of the pane is the pane's", .{});
    try h.expect(hitTest(left_pane, r.left, mid_y) == w.HTCLIENT, "the window's outer edge is the pane's", .{});
    try quit(h, &g, right_pane);
}

/// Unfocused panes of a split tab are dimmed: a translucent
/// unfocused-split-fill over them at 1 - unfocused-split-opacity, blended
/// in sRGB. Read back from the renderers in a padding pixel (the
/// background): half red over #282c34 in the dimmed pane, the background
/// alone in the focused one; moving the focus moves the dimming. The
/// dividers follow the background unless `split-divider-color` sets them.
fn splitDim(h: *Harness) anyerror!void {
    const dim_config = "unfocused-split-fill = #ff0000\nunfocused-split-opacity = 0.5\n";
    var g = try start(h, "split-dim", dim_config, ">");
    defer g.deinit();
    const win = try h.mainWindow(&g);
    const bg: u32 = 0x282c34;
    try h.expect(try h.probePane(&g, 0, 1, 1) == bg, "one pane: not dimmed", .{});

    h.key(try h.surface(&g, win), .{ .ctrl = true, .shift = true }, 'O');
    try waitPanes(h, &g, 2);
    w.Sleep(1500);
    // The new (right) pane is focused; the left one is dimmed.
    const dim = blendSrgb(0xff0000, bg, 0.5);
    try expectColor(h, try h.probePane(&g, 0, 1, 1), dim, "the unfocused pane is dimmed");
    try expectColor(h, try h.probePane(&g, 1, 1, 1), bg, "the focused pane isn't");

    // Clicking the left pane moves the focus, and the dimming with it.
    const left = try paneHwnd(h, &g, 0);
    h.click(left, 200, 200, .left);
    w.Sleep(800);
    try expectColor(h, try h.probePane(&g, 0, 1, 1), bg, "after a click the left pane isn't dimmed");
    try expectColor(h, try h.probePane(&g, 1, 1, 1), dim, "and the right one is");

    // The dividers are the focused pane's background darkened (60% of a
    // dark one, 92% of a light one), and repaint when a program changes
    // it: OSC 11 from cmd's prompt ($E is ESC; ESC \ ends the sequence).
    try expectDividerColor(h, &g, 0x181a1f, "the dividers darken the dark background");
    try h.typeText(left, "prompt $E]11;#f0f0f0$E\\$G");
    h.enter(left);
    try expectDividerColor(h, &g, 0xdcdcdc, "after OSC 11 they follow the light one");

    // split-divider-color sets them over that rule: written to the running
    // instance's configuration, then reloaded (Ctrl+Shift+,).
    const cfg_path = try std.fmt.allocPrint(h.alloc, "{s}\\split-dim\\murrtty\\config.ghostty", .{h.temp_dir});
    defer h.alloc.free(cfg_path);
    try h.writeFileAt(cfg_path, base_config ++ dim_config ++ "split-divider-color = #ffffff\n");
    h.key(left, .{ .ctrl = true, .shift = true }, w.VK_OEM_COMMA);
    try expectDividerColor(h, &g, 0xffffff, "split-divider-color sets them, whatever the background");
    try quit(h, &g, left);
}

/// Wait until the first tab's dividers were last painted `want`.
fn expectDividerColor(h: *Harness, g: *Harness.Ghostty, want: i64, comptime what: []const u8) !void {
    var got: i64 = -1;
    var waited: u32 = 0;
    while (waited <= 3000) : (waited += 100) {
        var d = try h.dump(g);
        defer d.deinit();
        got = d.value.windows[0].tabs[0].divider_color orelse -1;
        if (got == want) return h.expect(true, what, .{});
        w.Sleep(100);
    }
    // -1 (never painted) shows as #ffffffff.
    return h.fail(what ++ ": #{x:0>6} (expected #{x:0>6})", .{
        @as(u32, @truncate(@as(u64, @bitCast(got)))),
        @as(u32, @intCast(want)),
    });
}

/// The grip band (a pane's margin next to a divider, where the mouse goes
/// to the tab's container) reaches at most 64 px from the divider, so the
/// rest of a wide padding stays the pane's; and a point in a band picks
/// the divider on that band's side, even beside a nearer one. (A / B) | C,
/// with a horizontal padding wider than the reach and no vertical padding.
fn splitGrip(h: *Harness) anyerror!void {
    const cs: Harness.Mods = .{ .ctrl = true, .shift = true };
    var g = try start(h, "split-grip", "window-padding-x = 60\nwindow-padding-y = 0\n", ">");
    defer g.deinit();
    const win = try h.mainWindow(&g);
    h.key(try h.surface(&g, win), cs, 'O');
    try waitPanes(h, &g, 2);
    w.Sleep(800);
    h.key(try paneHwnd(h, &g, 0), cs, 'E');
    try waitPanes(h, &g, 3);
    w.Sleep(1500);
    const a = try paneHwnd(h, &g, 0);
    const container = w.GetParent(a) orelse return h.fail("pane without a container", .{});

    var r: w.RECT = .{};
    _ = w.GetWindowRect(a, &r);
    const mid_x = @divTrunc(r.left + r.right, 2);
    const mid_y = @divTrunc(r.top + r.bottom, 2);
    try h.expect(hitTest(a, r.right - 64, mid_y) == w.HTTRANSPARENT, "64 px from the divider is the grip band", .{});
    try h.expect(hitTest(a, r.right - 65, mid_y) == w.HTCLIENT, "65 px from it, still padding, is the pane's", .{});

    // A's bottom band is what its grid leaves over. Beside A's last text
    // row, 60 px from the side-by-side divider, a point is in A's right
    // band only, and nearer the stacked divider.
    var bottom_band: i32 = 0;
    while (bottom_band < 64 and hitTest(a, mid_x, r.bottom - 1 - bottom_band) != w.HTCLIENT) bottom_band += 1;
    try h.expect(bottom_band + 1 < 60, "setup: A's bottom band ({d} px) is narrower than its right one", .{bottom_band});
    try h.expect(hitTest(a, r.right - 60, r.bottom - 1 - bottom_band) == w.HTTRANSPARENT, "the point is in A's right band", .{});

    // A drag from it moves the side-by-side divider, not the stacked one.
    const root_x = try rootDivider(h, &g);
    const stacked_y, const px, const py = blk: {
        var d = try h.dump(&g);
        defer d.deinit();
        const t = d.value.windows[0].tabs[0];
        const p = t.panes.?;
        break :blk .{ try leftStackedDivider(h, t), p[0].rect[2] - 60, p[0].rect[3] - 1 - bottom_band };
    };
    postMouse(container, w.WM_LBUTTONDOWN, px, py);
    postMouse(container, w.WM_MOUSEMOVE, px + 30, py + 30);
    postMouse(container, w.WM_LBUTTONUP, px + 30, py + 30);
    w.Sleep(600);
    const root_after = try rootDivider(h, &g);
    try h.expect(@abs(root_after - (root_x + 30)) <= 1, "the side-by-side divider moved to {d} (expected {d})", .{ root_after, root_x + 30 });
    {
        var d = try h.dump(&g);
        defer d.deinit();
        const stacked_after = try leftStackedDivider(h, d.value.windows[0].tabs[0]);
        try h.expect(stacked_after == stacked_y, "the stacked divider stayed at {d} (is {d})", .{ stacked_y, stacked_after });
    }
    try quit(h, &g, a);
}

/// focus-follows-mouse: moving the mouse over a pane focuses it. A pane
/// moving under a still cursor (a divider moving) gets WM_MOUSEMOVE at the
/// same screen position, which doesn't take the focus, also when the mouse
/// was last seen by the tab's container (resting on the divider); nor does
/// moving over a pane of a window that isn't active.
fn focusFollowsMouse(h: *Harness) anyerror!void {
    const cs: Harness.Mods = .{ .ctrl = true, .shift = true };
    const f3 = 0x72;
    const f5 = 0x74;
    const f6 = 0x75;
    var g = try start(h, "focus-follows-mouse",
        \\focus-follows-mouse = true
        \\keybind = ctrl+shift+f3=goto_split:left
        \\keybind = ctrl+shift+f5=resize_split:right,40
        \\keybind = ctrl+shift+f6=resize_split:left,40
        \\
    , ">");
    defer g.deinit();
    const win = try h.mainWindow(&g);
    h.key(try h.surface(&g, win), cs, 'O');
    try waitPanes(h, &g, 2);
    w.Sleep(1000);
    const left = try paneHwnd(h, &g, 0);
    const right = try paneHwnd(h, &g, 1);
    try expectFocus(h, &g, win, right, "the new pane has the focus");

    postMove(left, 100, 100);
    try expectFocus(h, &g, win, left, "the mouse over the left pane focuses it");
    postMove(right, 50, 100);
    try expectFocus(h, &g, win, right, "and over the right one, that one");

    // The focus goes left by key; the divider then moves right under the
    // still cursor, and the right pane hears of the mouse at its new
    // client position, the same place on screen.
    h.key(right, cs, f3);
    try expectFocus(h, &g, win, left, "goto_split:left focuses the left pane");
    const before = try rootDivider(h, &g);
    h.key(left, cs, f5);
    w.Sleep(800);
    const shift = (try rootDivider(h, &g)) - before;
    try h.expect(shift > 0, "the divider moved right ({d} px)", .{shift});
    postMove(right, 50 - shift, 100);
    w.Sleep(600);
    try h.expect(keyboardFocus(win) == left, "a pane moving under a still cursor doesn't take the focus", .{});
    postMove(right, 60 - shift, 100);
    try expectFocus(h, &g, win, right, "the mouse moving again does");

    // The same with the mouse resting on the divider, where the tab's
    // container gets it and no pane does: the divider moves left, and the
    // right pane, now under the mouse, hears of it at the same screen point.
    h.key(right, cs, f3);
    try expectFocus(h, &g, win, left, "goto_split:left again");
    const container = w.GetParent(left) orelse return h.fail("pane without a container", .{});
    const at = try rootDivider(h, &g);
    postMove(container, at, 100);
    w.Sleep(300);
    h.key(left, cs, f6);
    w.Sleep(800);
    const right_left = blk: {
        var d = try h.dump(&g);
        defer d.deinit();
        break :blk d.value.windows[0].tabs[0].panes.?[1].rect[0];
    };
    try h.expect(right_left <= at, "the divider moved left, under the mouse ({d} to {d})", .{ at, right_left });
    postMove(right, at - right_left, 100);
    w.Sleep(600);
    try h.expect(keyboardFocus(win) == left, "a pane moving under a mouse resting on the divider doesn't take the focus", .{});

    // A second window is the active one: the mouse over the first's panes
    // leaves the focus, and the activation, alone.
    h.key(right, cs, 'N');
    w.Sleep(2500);
    const wins = try h.windows(&g, "MurrttyWindow");
    defer h.alloc.free(wins);
    try h.expect(wins.len == 2, "Ctrl+Shift+N opens a second window (got {d})", .{wins.len});
    const other = if (wins[0] == win) wins[1] else wins[0];
    try h.expect(activeWindow(win) == other, "the new window is active", .{});
    postMove(left, 150, 150);
    w.Sleep(600);
    try h.expect(activeWindow(win) == other, "the mouse over an inactive window's pane doesn't activate it", .{});
    try h.expect(keyboardFocus(win) != left, "nor focus that pane", .{});
    try quit(h, &g, try h.surface(&g, other));
}

/// Working-directory reports (roadmap 2.1). cmd's prompt reports its folder
/// with OSC 9;9 ($P); PowerShell sends OSC 7 naming this computer in lower
/// case (the DNS name's usual spelling, unlike the NetBIOS name). The pwd
/// follows them and a new tab starts there; a report from another computer
/// is ignored, and a local one that isn't a drive path (a UNC share) makes
/// the pwd unknown. Relative link text resolves against the reported pwd,
/// not Ghostty's own directory (cwd-fallback covers a shell that doesn't
/// report).
fn pwdReports(h: *Harness) anyerror!void {
    const cs: Harness.Mods = .{ .ctrl = true, .shift = true };
    var g = try start(h, "pwd", "", ">");
    defer g.deinit();
    const win = try h.mainWindow(&g);
    const first = try h.surface(&g, win);

    const report_prompt = "prompt $E]9;9;\"$P\"$E\\$P$G";
    try h.typeText(first, report_prompt);
    h.enter(first);
    try h.typeText(first, "cd /d C:\\Windows");
    h.enter(first);
    try waitPwd(h, &g, 0, "C:\\Windows");

    // A new tab starts where the shell last reported.
    h.key(first, cs, 'T');
    try waitWindowTabs(h, &g, win, 2);
    try waitTabText(h, &g, 1, "C:\\Windows>");
    try waitPwd(h, &g, 1, "C:\\Windows");
    const second = try h.surface(&g, win);

    // OSC 7 from PowerShell, naming this computer in lower case.
    try h.typeText(second, "powershell -NoProfile -Command \"[Console]::Write([char]27+']7;file://'+$env:COMPUTERNAME.ToLower()+'/C:/Windows/System32'+[char]7)\" & echo osc-sent-1");
    h.enter(second);
    try waitTabText(h, &g, 1, "\nosc-sent-1");
    try waitPwd(h, &g, 1, "C:\\Windows\\System32");

    // Another computer's OSC 7 changes nothing.
    try h.typeText(second, "powershell -NoProfile -Command \"[Console]::Write([char]27+']7;file://elsewhere.invalid/C:/Temp'+[char]7)\" & echo osc-sent-2");
    h.enter(second);
    try waitTabText(h, &g, 1, "\nosc-sent-2");
    w.Sleep(300);
    try waitPwd(h, &g, 1, "C:\\Windows\\System32");

    // A UNC path in OSC 9;9: the shell is somewhere unknown.
    try h.typeText(second, "powershell -NoProfile -Command \"[Console]::Write([char]27+']9;9;\\\\server\\share'+[char]7)\" & echo osc-sent-3");
    h.enter(second);
    try waitTabText(h, &g, 1, "\nosc-sent-3");
    try waitPwd(h, &g, 1, "");

    // Relative link text resolves against the reported pwd: a text file in
    // a folder that is neither Ghostty's directory nor the tab's starting
    // one opens (recorded by the test hooks, not opened). A decoy of the
    // same name in Ghostty's directory catches resolving against that.
    const rel = try std.fmt.allocPrint(h.alloc, "{s}\\rel", .{g.dir});
    defer h.alloc.free(rel);
    try h.makeDirAt(rel);
    defer h.removeDirAt(rel);
    const notes = try std.fmt.allocPrint(h.alloc, "{s}\\notes.txt", .{rel});
    defer h.alloc.free(notes);
    try h.writeFileAt(notes, "notes\n");
    defer h.deleteFile(notes);
    const decoy = try std.fmt.allocPrint(h.alloc, "{s}\\notes.txt", .{g.dir});
    defer h.alloc.free(decoy);
    try h.writeFileAt(decoy, "decoy\n");
    defer h.deleteFile(decoy);
    try h.typeText(second, report_prompt);
    h.enter(second);
    // The tab's cmd stays in Ghostty's directory (where the decoy is) while
    // a nested cmd, reporting with the same prompt, moves to rel: the report
    // wins over the outer cmd's own directory.
    const cd_outer = try std.fmt.allocPrint(h.alloc, "cd /d {s}", .{g.dir});
    defer h.alloc.free(cd_outer);
    try h.typeText(second, cd_outer);
    h.enter(second);
    try waitPwd(h, &g, 1, g.dir);
    try h.typeText(second, "cmd /d");
    h.enter(second);
    const cd = try std.fmt.allocPrint(h.alloc, "cd /d {s}", .{rel});
    defer h.alloc.free(cd);
    try h.typeText(second, cd);
    h.enter(second);
    try waitPwd(h, &g, 1, rel);
    try h.typeText(second, "cls & echo ./notes.txt");
    h.enter(second);
    try waitTabLine(h, &g, 1, "./notes.txt");
    try ctrlClickRow(h, &g, second, "./notes.txt", 3);
    const want = try std.fmt.allocPrint(h.alloc, "default {s}", .{notes});
    defer h.alloc.free(want);
    try expectLaunch(h, &g, 1, want);
    try quit(h, &g, second);
}

/// PowerShell integration (roadmap 2.2), for PowerShell 7 and Windows
/// PowerShell 5.1.
/// What a console program reads for each key ([Console]::ReadKey through
/// ConPTY): keys VT input can't carry arrive whole as Windows key events
/// (win32-input-mode, roadmap 0.12). The program prints what it reads.
fn consoleKeys(h: *Harness) anyerror!void {
    const dir = try std.fmt.allocPrint(h.alloc, "{s}\\console-keys", .{h.temp_dir});
    defer h.alloc.free(dir);
    try h.makeDirAt(dir);
    const script = try std.fmt.allocPrint(h.alloc, "{s}\\keys.ps1", .{dir});
    defer h.alloc.free(script);
    try h.writeFileAt(script,
        \\[Console]::TreatControlCAsInput = $true
        \\Write-Host 'keys-ready'
        \\while ($true) {
        \\  $k = [Console]::ReadKey($true)
        \\  Write-Host ('key {0} {1} {2}' -f $k.Key, ($k.Modifiers -replace ', ', '+'), [int]$k.KeyChar)
        \\}
        \\
    );
    const config = try std.fmt.allocPrint(h.alloc, "command = pwsh -NoLogo -NoProfile -File {s}\n", .{script});
    defer h.alloc.free(config);
    var g = try start(h, "console-keys", config, "keys-ready");
    defer g.deinit();
    const surf = try h.surface(&g, try h.mainWindow(&g));

    const cases = [_]struct { mods: Harness.Mods, vk: u8, want: []const u8, what: []const u8 }{
        .{ .mods = .{}, .vk = 'A', .want = "key A None 97", .what = "a" },
        .{ .mods = .{ .shift = true }, .vk = w.VK_LEFT, .want = "key LeftArrow Shift 0", .what = "Shift+Left" },
        .{ .mods = .{ .ctrl = true }, .vk = 'C', .want = "key C Control 3", .what = "Ctrl+C" },
        .{ .mods = .{ .ctrl = true, .shift = true }, .vk = 'C', .want = "key C Shift+Control 3", .what = "Ctrl+Shift+C" },
        .{ .mods = .{ .shift = true }, .vk = w.VK_RETURN, .want = "key Enter Shift 13", .what = "Shift+Enter" },
    };
    for (cases) |k| {
        h.key(surf, k.mods, k.vk);
        h.waitText(&g, k.want, 1, 5000) catch {
            var d = try h.dump(&g);
            defer d.deinit();
            const text = d.value.windows[0].tabs[0].text orelse "";
            return h.fail("{s} didn't arrive as '{s}'; the program read:\n{s}", .{ k.what, k.want, text });
        };
        try h.expect(true, "{s} arrives as '{s}'", .{ k.what, k.want });
    }
}

/// PowerShell's own keys, which reach it through ConPTY only as Windows
/// key events (win32-input-mode, roadmap 0.12). Shift+arrows highlight
/// text in its command line (PSReadLine), which isn't murrtty's selection,
/// and PSReadLine copies it with Ctrl+Shift+C (Copy) or Ctrl+C
/// (CopyOrCancelLine): with no selection of murrtty's, Ctrl+Shift+C must
/// reach PowerShell, as in Windows Terminal. Shift+Enter adds a line.
fn pwshKeys(h: *Harness) anyerror!void {
    var saved = try h.saveClipboard();
    defer saved.restore();
    var g = try start(h, "pwsh-keys", "command = pwsh -NoLogo -NoProfile\n", "PS ");
    defer g.deinit();
    const surf = try h.surface(&g, try h.mainWindow(&g));

    // Each copy key gets a fresh line with its own word highlighted (Copy
    // ends the highlight; CopyOrCancelLine without one cancels the line).
    const keys = [_]struct { mods: Harness.Mods, word: []const u8, what: []const u8 }{
        .{ .mods = .{ .ctrl = true, .shift = true }, .word = "word1", .what = "Ctrl+Shift+C (PSReadLine's Copy)" },
        .{ .mods = .{ .ctrl = true }, .word = "word2", .what = "Ctrl+C (PSReadLine's CopyOrCancelLine)" },
    };
    var copied: [keys.len]bool = @splat(false);
    for (keys, 0..) |k, n| {
        h.key(surf, .{}, w.VK_ESCAPE);
        try h.typeText(surf, "Write-Output hello ");
        try h.typeText(surf, k.word);
        try h.waitText(&g, k.word, 1, 10000);
        var i: usize = 0;
        while (i < k.word.len) : (i += 1) h.key(surf, .{ .shift = true }, w.VK_LEFT);
        h.sync(surf);
        if (n == 0) {
            var d = try h.dump(&g);
            defer d.deinit();
            const panes = d.value.windows[0].tabs[0].panes orelse return h.fail("no panes", .{});
            try h.expect(panes[0].selection != true, "Shift+Left highlights PowerShell's text, not murrtty's selection", .{});
        }
        try h.setClipboard("stale");
        h.key(surf, k.mods, 'C');
        // PowerShell writes the clipboard from its own process, the first
        // time slowly; polled gently, so it isn't kept out by our reads.
        var waited: u32 = 0;
        while (waited < 10000) : (waited += 250) {
            w.Sleep(250);
            const got = (try h.getClipboard()) orelse "";
            defer if (got.len > 0) h.alloc.free(got);
            if (std.mem.eql(u8, got, k.word)) {
                copied[n] = true;
                break;
            }
        }
        h.log("{s}: {s}", .{ k.what, if (copied[n]) "copied the highlighted word" else "copied nothing" });
    }
    try h.expect(copied[1], "Ctrl+C copies PowerShell's highlighted text", .{});
    try h.expect(copied[0], "Ctrl+Shift+C copies PowerShell's highlighted text", .{});

    // Shift+Enter adds a line (PSReadLine's AddLine): two commands, one
    // run, two lines of output. Escape clears what was typed (RevertLine).
    h.key(surf, .{}, w.VK_ESCAPE);
    try h.typeText(surf, "Write-Output first-line");
    h.key(surf, .{ .shift = true }, w.VK_RETURN);
    try h.typeText(surf, "Write-Output second-line");
    h.enter(surf);
    try waitTabLine(h, &g, 0, "first-line");
    try waitTabLine(h, &g, 0, "second-line");
    try h.expect(true, "Shift+Enter adds a line to the command", .{});
    try quit(h, &g, surf);
}

fn pwshIntegration(h: *Harness) anyerror!void {
    try powershellIntegration(h, "pwsh-integration-7", "pwsh -NoLogo");
    try powershellIntegration(h, "pwsh-integration-5", "powershell -NoLogo");
}

/// With Ghostty's script loaded: a cd reports the folder (pwd and title)
/// and a new tab starts there; an idle tab closes without asking while one
/// running a command asks, its title the command; jump_to_prompt moves the
/// view to earlier prompts.
fn powershellIntegration(h: *Harness, name: []const u8, command: []const u8) !void {
    const cs: Harness.Mods = .{ .ctrl = true, .shift = true };
    const extra = try std.fmt.allocPrint(h.alloc, "command = {s}\nshell-integration = detect\n", .{command});
    defer h.alloc.free(extra);
    var g = try start(h, name, extra, "PS ");
    defer g.deinit();
    const win = try h.mainWindow(&g);
    const first = try h.surface(&g, win);

    try h.typeText(first, "cd C:\\Windows");
    h.enter(first);
    try waitPwd(h, &g, 0, "C:\\Windows");
    try waitTabTitle(h, &g, 0, "C:\\Windows");

    // Exit statuses: a program's code (twice: the same code again still
    // counts), a failing cmdlet's 1, then success.
    try runForStatus(h, &g, first, "cmd /c exit 3", 3);
    try runForStatus(h, &g, first, "cmd /c exit 3", 3);
    try runForStatus(h, &g, first, "Get-Item C:\\no-such-file", 1);
    try runForStatus(h, &g, first, "$null", 0);

    // A new tab starts there, and closes at its idle prompt without asking.
    h.key(first, cs, 'T');
    try waitWindowTabs(h, &g, win, 2);
    try waitTabText(h, &g, 1, "PS C:\\Windows>");
    const second = try h.surface(&g, win);
    h.key(second, cs, 'W');
    try waitWindowTabs(h, &g, win, 1);
    w.Sleep(500);
    try h.expect(try h.dialogCount(&g) == 0, "an idle prompt closes without asking", .{});

    // A running command asks; its title is the command.
    try h.typeText(first, "Start-Sleep 30");
    h.enter(first);
    try waitTabTitle(h, &g, 0, "Start-Sleep 30");
    h.key(first, cs, 'W');
    const dlg = try h.waitDialog(&g, 5000);
    h.answer(&g, dlg, w.IDCANCEL);
    try waitNoDialog(h, &g);
    try waitWindowTabs(h, &g, win, 1);
    h.key(first, .{ .ctrl = true }, 'C');
    try waitTabTitle(h, &g, 0, "C:\\Windows");

    // Two commands each printing more than a screen; jump_to_prompt
    // (Ctrl+Shift+Up) brings each one's prompt to the top of the view.
    try h.typeText(first, "'mark-a'; 1..45");
    h.enter(first);
    try h.typeText(first, "'mark-b'; 1..45; 'end-b'");
    h.enter(first);
    try waitTabLine(h, &g, 0, "end-b");
    h.key(first, cs, w.VK_UP);
    try waitTopLine(h, &g, 0, "PS ", "'mark-b'");
    h.key(first, cs, w.VK_UP);
    try waitTopLine(h, &g, 0, "PS ", "'mark-a'");

    // A location that isn't a drive path makes the pwd unknown.
    try h.typeText(first, "cd HKCU:\\");
    h.enter(first);
    try waitPwd(h, &g, 0, "");
    try h.typeText(first, "cd C:\\Windows");
    h.enter(first);
    try waitPwd(h, &g, 0, "C:\\Windows");

    // A venv's prompt (it writes with Write-Host and chains to the prompt it
    // replaced, Ghostty's), then the script loaded again under strict mode:
    // it wraps the new prompt without recursing, the prompt stays on one
    // row, nothing adds errors, and reports go on. Then a line editor
    // wrapper that chains to Ghostty's, which the next prompt wraps again.
    try h.typeText(first, "Set-StrictMode -Version Latest; Copy-Item function:prompt function:global:_OLD_VIRTUAL_PROMPT; " ++
        "function global:prompt { Write-Host -NoNewline '(venv) '; _OLD_VIRTUAL_PROMPT }; " ++
        ". ([scriptblock]::Create([IO.File]::ReadAllText(\"$env:GHOSTTY_RESOURCES_DIR\\shell-integration\\powershell\\ghostty.ps1\"))); $Error.Clear()");
    h.enter(first);
    try waitTabText(h, &g, 0, "(venv) PS C:\\Windows>");
    try h.typeText(first, "$global:prev = $function:PSConsoleHostReadLine; function global:PSConsoleHostReadLine { & $global:prev }");
    h.enter(first);
    try h.typeText(first, "cd C:\\Windows\\System32");
    h.enter(first);
    try waitPwd(h, &g, 0, "C:\\Windows\\System32");
    try runForStatus(h, &g, first, "cmd /c exit 4", 4);
    try runForStatus(h, &g, first, "Get-Item C:\\no-such-file", 1);
    try h.typeText(first, "$Error.Clear(); $null = 1");
    h.enter(first);
    try h.typeText(first, "'errors=' + $Error.Count");
    h.enter(first);
    try waitTabLine(h, &g, 0, "errors=0");

    // At an idle prompt, quitting doesn't ask.
    try quitIdle(h, &g, first);
}

/// cmd integration (roadmap 2.3): through PROMPT with cmd's default prompt
/// and with a user's own, then through Clink when GHOSTTY_GUI_CLINK names a
/// folder holding clink_x64.exe (its profile goes in the scenario's folder,
/// never the user's).
fn cmdIntegration(h: *Harness) anyerror!void {
    try cmdIntegrationRun(h, "cmd-integration", .plain);
    try cmdIntegrationRun(h, "cmd-integration-prompt", .user_prompt);

    var buf: [1024]u16 = undefined;
    const n = w.GetEnvironmentVariableW(w.L("GHOSTTY_GUI_CLINK"), &buf, buf.len);
    if (n == 0 or n >= buf.len) {
        h.log("Clink part skipped: set GHOSTTY_GUI_CLINK to a Clink folder to run it", .{});
        return;
    }
    try cmdIntegrationRun(h, "cmd-integration-clink", .{ .clink = try std.unicode.utf16LeToUtf8Alloc(h.alloc, buf[0..n]) });
}

const CmdRun = union(enum) {
    plain,
    /// PROMPT=[$P]$G in Ghostty's environment.
    user_prompt,
    /// Clink injected from this folder.
    clink: []const u8,
};

/// With Ghostty's PROMPT (and Clink's script): cd /d reports the folder
/// (pwd and title) and a new tab starts there; an idle tab closes without
/// asking while one running a command asks; jump_to_prompt moves the view
/// to earlier prompts. With Clink, finished commands carry their status.
fn cmdIntegrationRun(h: *Harness, name: []const u8, run: CmdRun) !void {
    defer if (run == .clink) h.alloc.free(run.clink);
    const cs: Harness.Mods = .{ .ctrl = true, .shift = true };
    // Clink's folder goes on PATH rather than in the command, which the
    // config splits on spaces (C:\Program Files (x86)\clink).
    const extra = switch (run) {
        .plain, .user_prompt => "shell-integration = detect\n",
        .clink => "shell-integration = detect\ncommand = cmd.exe /k clink_x64.exe inject --quiet\n",
    };
    const config = try std.mem.concat(h.alloc, u8, &.{ base_config, extra });
    defer h.alloc.free(config);
    // In the launch's folder, never the user's (Clink's files there keep
    // the run folder from being removed). Its settings turn the updater
    // off: a new profile's first prompt otherwise checks GitHub, and once
    // stopped taking input until the test gave up.
    const profile = try std.fmt.allocPrint(h.alloc, "{s}\\{s}\\clink-profile", .{ h.temp_dir, name });
    defer h.alloc.free(profile);
    if (run == .clink) {
        const launch_dir = try std.fmt.allocPrint(h.alloc, "{s}\\{s}", .{ h.temp_dir, name });
        defer h.alloc.free(launch_dir);
        try h.makeDirAt(launch_dir);
        try h.makeDirAt(profile);
        const settings = try std.fmt.allocPrint(h.alloc, "{s}\\clink_settings", .{profile});
        defer h.alloc.free(settings);
        try h.writeFileAt(settings, "clink.autoupdate = off\n");
    }
    var path_buf: [32767]u16 = undefined;
    const path_len = w.GetEnvironmentVariableW(w.L("PATH"), &path_buf, path_buf.len);
    const path = try std.unicode.utf16LeToUtf8Alloc(h.alloc, path_buf[0..@min(path_len, path_buf.len)]);
    defer h.alloc.free(path);
    const clink_path = try std.mem.concat(h.alloc, u8, &.{ if (run == .clink) run.clink else "", ";", path });
    defer h.alloc.free(clink_path);
    const env: []const [2][]const u8 = switch (run) {
        .plain => &.{},
        .user_prompt => &.{.{ "PROMPT", "[$P]$G" }},
        .clink => &.{ .{ "CLINK_PROFILE", profile }, .{ "PATH", clink_path } },
    };
    const home_prompt = if (run == .user_prompt) "]>" else ">";
    var g = try h.launchWith(name, config, .{ .env = env });
    defer g.deinit();
    try h.waitText(&g, home_prompt, 1, 20000);
    const win = try h.mainWindow(&g);
    const first = try h.surface(&g, win);
    const prompt = if (run == .user_prompt) "[C:\\Windows]>" else "C:\\Windows>";

    try h.typeText(first, "cd /d C:\\Windows");
    h.enter(first);
    try waitPwd(h, &g, 0, "C:\\Windows");
    try waitTabTitle(h, &g, 0, "C:\\Windows");

    if (run == .clink) {
        try runForStatus(h, &g, first, "cmd /c exit 3", 3);
        try runForStatus(h, &g, first, "cmd /c exit 0", 0);
    }

    // A new tab starts there, and closes at its idle prompt without asking.
    h.key(first, cs, 'T');
    try waitWindowTabs(h, &g, win, 2);
    try waitTabText(h, &g, 1, prompt);
    // The prompt's text can show before the core's idle-prompt verdict,
    // which decides whether the close asks.
    try waitAtPrompt(h, &g, 1, true);
    const second = try h.surface(&g, win);
    h.key(second, cs, 'W');
    try waitWindowTabs(h, &g, win, 1);
    w.Sleep(500);
    try h.expect(try h.dialogCount(&g) == 0, "an idle prompt closes without asking", .{});

    // A running command asks.
    try h.typeText(first, "ping -n 30 127.0.0.1 >nul");
    h.enter(first);
    try waitAtPrompt(h, &g, 0, false);
    h.key(first, cs, 'W');
    const dlg = try h.waitDialog(&g, 5000);
    h.answer(&g, dlg, w.IDCANCEL);
    try waitNoDialog(h, &g);
    try waitWindowTabs(h, &g, win, 1);
    h.key(first, .{ .ctrl = true }, 'C');
    try waitAtPrompt(h, &g, 0, true);

    // Two commands each printing more than a screen; jump_to_prompt
    // (Ctrl+Shift+Up) brings each one's prompt to the top of the view.
    try h.typeText(first, "echo mark-a& for /l %i in (1,1,45) do @echo %i");
    h.enter(first);
    try h.typeText(first, "echo mark-b& (for /l %i in (1,1,45) do @echo %i)& echo end-b");
    h.enter(first);
    try waitTabLine(h, &g, 0, "end-b");
    h.key(first, cs, w.VK_UP);
    try waitTopLine(h, &g, 0, prompt, "mark-b");
    h.key(first, cs, w.VK_UP);
    try waitTopLine(h, &g, 0, prompt, "mark-a");
    try quitIdle(h, &g, first);
}

/// Without shell integration (roadmap 2.4): cmd reports nothing, but its cd
/// changes its process's directory, which Ghostty reads, so a new tab starts
/// there and relative links resolve against it. PowerShell's Set-Location
/// leaves its process's directory alone, so for it neither happens (a new
/// tab starts where the first did, and a relative link is blocked rather
/// than resolved against the wrong folder).
fn cwdFallback(h: *Harness) anyerror!void {
    const cs: Harness.Mods = .{ .ctrl = true, .shift = true };
    const dir = try std.fmt.allocPrint(h.alloc, "{s}\\cwd fallback dir", .{h.temp_dir});
    defer h.alloc.free(dir);
    try h.makeDirAt(dir);
    defer h.removeDirAt(dir);
    const notes = try std.fmt.allocPrint(h.alloc, "{s}\\notes.txt", .{dir});
    defer h.alloc.free(notes);
    try h.writeFileAt(notes, "notes\n");
    defer h.deleteFile(notes);
    // Where the PowerShell half starts, with a decoy that a link resolved
    // against that starting directory would open.
    const start_dir = try std.fmt.allocPrint(h.alloc, "{s}\\cwd-fallback-start", .{h.temp_dir});
    defer h.alloc.free(start_dir);
    try h.makeDirAt(start_dir);
    defer h.removeDirAt(start_dir);
    const decoy = try std.fmt.allocPrint(h.alloc, "{s}\\notes.txt", .{start_dir});
    defer h.alloc.free(decoy);
    try h.writeFileAt(decoy, "decoy\n");
    defer h.deleteFile(decoy);

    {
        var g = try start(h, "cwd-fallback", "", ">");
        defer g.deinit();
        const win = try h.mainWindow(&g);
        const first = try h.surface(&g, win);
        const prompt = try std.fmt.allocPrint(h.alloc, "{s}>", .{dir});
        defer h.alloc.free(prompt);
        const cd = try std.fmt.allocPrint(h.alloc, "cd /d \"{s}\"", .{dir});
        defer h.alloc.free(cd);
        try h.typeText(first, cd);
        h.enter(first);
        try waitTabText(h, &g, 0, prompt);

        // A relative link resolves against it, in the tab that started
        // elsewhere (recorded by the test hooks).
        try h.typeText(first, "cls & echo ./notes.txt");
        h.enter(first);
        try waitTabLine(h, &g, 0, "./notes.txt");
        try ctrlClickRow(h, &g, first, "./notes.txt", 3);
        const want = try std.fmt.allocPrint(h.alloc, "default {s}", .{notes});
        defer h.alloc.free(want);
        try expectLaunch(h, &g, 1, want);

        // A new tab starts there.
        h.key(first, cs, 'T');
        try waitWindowTabs(h, &g, win, 2);
        try waitTabText(h, &g, 1, prompt);
        try quit(h, &g, try h.surface(&g, win));
    }
    {
        const extra = try std.fmt.allocPrint(h.alloc, "command = powershell -NoLogo -NoProfile\nworking-directory = {s}\n", .{start_dir});
        defer h.alloc.free(extra);
        var g = try start(h, "cwd-fallback-pwsh", extra, "PS ");
        defer g.deinit();
        const win = try h.mainWindow(&g);
        const first = try h.surface(&g, win);
        const cd = try std.fmt.allocPrint(h.alloc, "Set-Location '{s}'", .{dir});
        defer h.alloc.free(cd);
        try h.typeText(first, cd);
        h.enter(first);
        const prompt = try std.fmt.allocPrint(h.alloc, "PS {s}>", .{dir});
        defer h.alloc.free(prompt);
        try waitTabText(h, &g, 0, prompt);

        // A new tab starts where the first did, not there.
        h.key(first, cs, 'T');
        try waitWindowTabs(h, &g, win, 2);
        try waitTabText(h, &g, 1, "PS ");
        try h.expect(!try tabShows(h, &g, 1, prompt), "PowerShell's Set-Location doesn't carry over without its integration", .{});
        const second = try h.surface(&g, win);

        // A relative link is blocked, not resolved against the wrong folder.
        try h.typeText(second, cd);
        h.enter(second);
        try waitTabText(h, &g, 1, prompt);
        try h.typeText(second, "Clear-Host; './notes.txt'");
        h.enter(second);
        try waitTabLine(h, &g, 1, "./notes.txt");
        try ctrlClickRow(h, &g, second, "./notes.txt", 3);
        const dlg = try h.waitDialog(&g, 5000);
        try expectTitle(h, dlg, "Link Blocked");
        h.answer(&g, dlg, w.IDOK);
        try waitNoDialog(h, &g);
        try expectLaunchCount(h, &g, 0);
        try quit(h, &g, second);
    }
}

/// Whether the first window's tab `tab` shows `needle` now.
fn tabShows(h: *Harness, g: *Harness.Ghostty, tab: usize, needle: []const u8) !bool {
    var d = try h.dump(g);
    defer d.deinit();
    const win_tabs = d.value.windows[0].tabs;
    if (tab >= win_tabs.len) return false;
    const text = win_tabs[tab].text orelse return false;
    return std.mem.indexOf(u8, text, needle) != null;
}

/// Run `command` at the first tab's prompt and wait for the shell to report
/// it finished with exit status `want`.
fn runForStatus(h: *Harness, g: *Harness.Ghostty, target: w.HWND, command: []const u8, want: i32) !void {
    const before = before: {
        var d = try h.dump(g);
        defer d.deinit();
        const p = d.value.windows[0].tabs[0].panes orelse break :before 0;
        break :before if (p.len > 0) p[0].commands else 0;
    };
    try h.typeText(target, command);
    h.enter(target);
    // Generous: the command starts a process, and on a loaded machine (a
    // build running beside a Debug Ghostty) that has taken over 10 s.
    var last: i32 = -1;
    var waited: u32 = 0;
    while (waited <= 30000) : (waited += 200) {
        var d = try h.dump(g);
        defer d.deinit();
        if (d.value.windows[0].tabs[0].panes) |p| if (p.len > 0 and p[0].commands > before) {
            last = p[0].last_exit;
            if (last == want) return h.expect(true, "{s} finished with status {d}", .{ command, want });
        };
        w.Sleep(200);
    }
    return h.fail("{s} didn't finish with status {d} (last {d})", .{ command, want, last });
}

/// Wait until the first window's tab `tab` is (or isn't) at a prompt, as
/// close confirmation sees it.
fn waitAtPrompt(h: *Harness, g: *Harness.Ghostty, tab: usize, want: bool) !void {
    var waited: u32 = 0;
    while (waited <= 10000) : (waited += 200) {
        var d = try h.dump(g);
        defer d.deinit();
        const win_tabs = d.value.windows[0].tabs;
        if (tab < win_tabs.len) if (win_tabs[tab].panes) |p| if (p.len > 0) if (p[0].at_prompt) |at| {
            if (at == want) return h.expect(true, "tab {d} {s} at a prompt", .{ tab, if (want) "is" else "isn't" });
        };
        w.Sleep(200);
    }
    return h.fail("tab {d} {s} at a prompt", .{ tab, if (want) "isn't" else "is still" });
}

/// Ctrl+Shift+Q at an idle prompt: Ghostty exits with code 0 and no dialog.
fn quitIdle(h: *Harness, g: *Harness.Ghostty, target: w.HWND) !void {
    h.key(target, .{ .ctrl = true, .shift = true }, 'Q');
    const code = g.waitExit(10000);
    try h.expect(code != null and code.? == 0, "an idle prompt quits without asking, code 0 (got {?d})", .{code});
}

/// Wait until the first window's tab `tab` has the title `want`.
fn waitTabTitle(h: *Harness, g: *Harness.Ghostty, tab: usize, want: []const u8) !void {
    var waited: u32 = 0;
    while (waited <= 10000) : (waited += 200) {
        var d = try h.dump(g);
        defer d.deinit();
        const win_tabs = d.value.windows[0].tabs;
        if (tab < win_tabs.len and std.ascii.eqlIgnoreCase(win_tabs[tab].title, want)) {
            return h.expect(true, "tab {d}'s title is {s}", .{ tab, want });
        }
        w.Sleep(200);
    }
    return h.fail("tab {d}'s title isn't {s}", .{ tab, want });
}

/// Wait until the top row of the first window's tab `tab` is a prompt
/// (starting with `prompt`) holding `needle`.
fn waitTopLine(h: *Harness, g: *Harness.Ghostty, tab: usize, prompt: []const u8, needle: []const u8) !void {
    var top_buf: [256]u8 = undefined;
    var top: []const u8 = "";
    var waited: u32 = 0;
    while (waited <= 5000) : (waited += 200) {
        var d = try h.dump(g);
        defer d.deinit();
        const win_tabs = d.value.windows[0].tabs;
        if (tab < win_tabs.len) if (win_tabs[tab].text) |text| {
            const line = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
            if (std.mem.startsWith(u8, line, prompt) and std.mem.indexOf(u8, line, needle) != null) {
                return h.expect(true, "the view starts at the prompt of {s}", .{needle});
            }
            const n = @min(line.len, top_buf.len);
            @memcpy(top_buf[0..n], line[0..n]);
            top = top_buf[0..n];
        };
        w.Sleep(200);
    }
    return h.fail("the view's top row is '{s}', not the prompt of {s}", .{ top, needle });
}

/// Wait until the first window's tab `tab` reports `want` as its pwd.
fn waitPwd(h: *Harness, g: *Harness.Ghostty, tab: usize, want: []const u8) !void {
    var last_buf: [512]u8 = undefined;
    var last: []const u8 = "(none)";
    var waited: u32 = 0;
    while (waited <= 10000) : (waited += 200) {
        var d = try h.dump(g);
        defer d.deinit();
        const win_tabs = d.value.windows[0].tabs;
        if (tab < win_tabs.len) if (win_tabs[tab].panes) |p| if (p.len > 0) if (p[0].pwd) |pwd| {
            if (std.ascii.eqlIgnoreCase(pwd, want)) return h.expect(true, "tab {d}'s pwd is {s}", .{ tab, want });
            const n = @min(pwd.len, last_buf.len);
            @memcpy(last_buf[0..n], pwd[0..n]);
            last = last_buf[0..n];
        };
        w.Sleep(200);
    }
    return h.fail("tab {d}'s pwd is {s}, expected {s}", .{ tab, last, want });
}

/// Wait until the first window's tab `tab` shows `needle`.
fn waitTabText(h: *Harness, g: *Harness.Ghostty, tab: usize, needle: []const u8) !void {
    var waited: u32 = 0;
    while (waited <= 15000) : (waited += 200) {
        var d = try h.dump(g);
        defer d.deinit();
        const win_tabs = d.value.windows[0].tabs;
        if (tab < win_tabs.len) if (win_tabs[tab].text) |text| {
            if (std.mem.indexOf(u8, text, needle) != null) return;
        };
        w.Sleep(200);
    }
    return h.fail("tab {d} doesn't show '{s}'", .{ tab, needle });
}

/// Wait until a row of the first window's tab `tab` starts with `prefix`.
fn waitTabLine(h: *Harness, g: *Harness.Ghostty, tab: usize, prefix: []const u8) !void {
    var waited: u32 = 0;
    while (waited <= 15000) : (waited += 200) {
        var d = try h.dump(g);
        defer d.deinit();
        const win_tabs = d.value.windows[0].tabs;
        if (tab < win_tabs.len) if (win_tabs[tab].text) |text| {
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line| if (std.mem.startsWith(u8, line, prefix)) return;
        };
        w.Sleep(200);
    }
    return h.fail("no row of tab {d} starts with '{s}'", .{ tab, prefix });
}

/// A mouse move with no button held, at client (x, y) of `target`.
fn postMove(target: w.HWND, x: i32, y: i32) void {
    _ = w.PostMessageW(target, w.WM_MOUSEMOVE, 0, w.makeLParam(x, y));
}

/// The top of the stacked divider in the left part of tab `t`.
fn leftStackedDivider(h: *Harness, t: Harness.Dump.Tab) !i32 {
    for (t.dividers.?) |dv| if (dv[0] == 0 and dv[3] - dv[1] < t.area.?[1]) return dv[1];
    return h.fail("no stacked divider on the left", .{});
}

/// An `all:` binding performs new_split on every surface inside the core's
/// loop over its surface list, which each new pane joins; ten terminals
/// fill the list's first allocation, so splitting inside that loop would
/// move the list from under it. Every tab gets its second pane.
fn splitAll(h: *Harness) anyerror!void {
    const f9 = 0x78;
    var g = try start(h, "split-all", "keybind = all:ctrl+shift+f9=new_split:right\n", ">");
    defer g.deinit();
    const win = try h.mainWindow(&g);
    for (2..11) |n| {
        h.key(try h.surface(&g, win), .{ .ctrl = true, .shift = true }, 'T');
        try waitWindowTabs(h, &g, win, n);
    }
    h.key(try h.surface(&g, win), .{ .ctrl = true, .shift = true }, f9);
    var split: usize = 0;
    var waited: u32 = 0;
    while (waited <= 20000) : (waited += 250) {
        if (g.exitCode()) |code| return h.fail("Ghostty exited with code {d}", .{code});
        var d = try h.dump(&g);
        defer d.deinit();
        split = 0;
        for (d.value.windows[0].tabs) |t| {
            if (t.panes) |p| split += @intFromBool(p.len == 2);
        }
        if (split == 10) break;
        w.Sleep(250);
    }
    try h.expect(split == 10, "every tab was split ({d} of 10)", .{split});
    try quit(h, &g, try h.surface(&g, win));
}

/// `fg` at `alpha` over `bg`, per channel in the stored (sRGB) values.
fn blendSrgb(fg: u32, bg: u32, alpha: f32) u32 {
    var out: u32 = 0;
    inline for (.{ 16, 8, 0 }) |shift| {
        const f: f32 = @floatFromInt((fg >> shift) & 0xFF);
        const b: f32 = @floatFromInt((bg >> shift) & 0xFF);
        out |= @as(u32, @intFromFloat(@round(f * alpha + b * (1 - alpha)))) << shift;
    }
    return out;
}

fn expectColor(h: *Harness, got: u32, want: u32, comptime what: []const u8) !void {
    var close = true;
    inline for (.{ 16, 8, 0 }) |shift| {
        const a: i32 = @intCast((got >> shift) & 0xFF);
        const b: i32 = @intCast((want >> shift) & 0xFF);
        if (@abs(a - b) > 2) close = false;
    }
    try h.expect(close, what ++ ": #{x:0>6} (expected #{x:0>6})", .{ got, want });
}

fn postMouse(target: w.HWND, msg: w.UINT, x: i32, y: i32) void {
    const lp: usize = (@as(usize, @as(u16, @bitCast(@as(i16, @intCast(y))))) << 16) | @as(u16, @bitCast(@as(i16, @intCast(x))));
    _ = w.PostMessageW(target, msg, if (msg == w.WM_LBUTTONUP) 0 else w.MK_LBUTTON, @bitCast(lp));
}

/// WM_NCHITTEST at screen point (x, y).
fn hitTest(target: w.HWND, x: i32, y: i32) isize {
    const lp: usize = (@as(usize, @as(u16, @bitCast(@as(i16, @intCast(y))))) << 16) | @as(u16, @bitCast(@as(i16, @intCast(x))));
    var result: usize = 0;
    _ = w.SendMessageTimeoutW(target, w.WM_NCHITTEST, 0, @bitCast(lp), w.SMTO_ABORTIFHUNG, 2000, &result);
    return @bitCast(result);
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

/// Wait until window `win` has at least `count` tabs.
fn waitWindowTabsAtLeast(h: *Harness, g: *Harness.Ghostty, win: w.HWND, count: usize) !void {
    var waited: u32 = 0;
    var last: usize = 0;
    while (waited <= 10000) : (waited += 200) {
        var d = try h.dump(g);
        defer d.deinit();
        for (d.value.windows) |dw| {
            if (dw.hwnd != @intFromPtr(win)) continue;
            last = dw.tabs.len;
            if (last >= count) return;
        }
        w.Sleep(200);
    }
    return h.fail("window has {d} tab(s), expected at least {d}", .{ last, count });
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

    // Larger than the screen: clamped to the monitor's work area, and kept
    // inside it wherever Windows first put the window.
    var big = try start(h, "window-size-big", "window-width = 500\nwindow-height = 200\n", ">");
    defer big.deinit();
    const win = try h.mainWindow(&big);
    var r: w.RECT = .{};
    _ = w.GetWindowRect(win, &r);
    var mi: w.MONITORINFO = .{};
    const monitor = w.MonitorFromWindow(win, w.MONITOR_DEFAULTTONEAREST) orelse return h.fail("no monitor", .{});
    _ = w.GetMonitorInfoW(monitor, &mi);
    const work = mi.rcWork;
    try h.expect(
        r.left >= work.left and r.top >= work.top and r.right <= work.right and r.bottom <= work.bottom,
        "the window ({d},{d})-({d},{d}) is inside the work area ({d},{d})-({d},{d})",
        .{ r.left, r.top, r.right, r.bottom, work.left, work.top, work.right, work.bottom },
    );
    try quit(h, &big, try h.surface(&big, win));
}
