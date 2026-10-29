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
    .{ .name = "drop", .about = "files dropped on a pane paste as their paths, quoted where a shell would split them; text pastes as it is; through the pane's drop target", .run = dropScenario },
    .{ .name = "selection", .about = "murrtty's own selection clipboard: copy-on-select = primary (the default) fills it, not the system clipboard; a middle click and paste_from_selection paste it", .run = selectionScenario },
    .{ .name = "copy-keys", .about = "a word selected by a double click is copied 10 times each by Ctrl+Insert, the numpad's Ctrl+Ins (NumLock off) and Ctrl+Shift+C; the numpad's Left moves, its Shift+Ins pastes", .run = copyKeys },
    .{ .name = "alt-f4", .about = "Alt+F4 asks, then closes", .run = altF4 },
    .{ .name = "bare-command", .about = "a bare command name runs Windows' program, not a same-named one planted where murrtty started", .run = bareCommand },
    .{ .name = "session-end", .about = "Windows ending the session (log-off, shutdown) is answered yes with no dialog, as upstream quits without asking then", .run = sessionEnd },
    .{ .name = "clipboard-queue", .about = "a burst of OSC 52 writes asks one dialog at a time", .run = clipboardQueue },
    .{ .name = "clipboard-dialog", .about = "GTK's clipboard dialog: the whole text in a box, Deny the default, remember for OSC 52; an unsafe paste's warning", .run = clipboardDialog },
    .{ .name = "system-menu", .about = "murrtty's items in the system menu (Alt+Space) after Windows' own: About, New Tab; its Close still asks", .run = systemMenu },
    .{ .name = "close-all", .about = "close-all asks and disables the other windows meanwhile", .run = closeAll },
    .{ .name = "window-size", .about = "window-width/height give the exact grid", .run = windowSize },
    .{ .name = "links", .about = "Ctrl+click links: programs and UNC paths blocked, web opens, other schemes ask", .run = links },
    .{ .name = "links-open", .about = "links really open: a test protocol and file type registered in HKCU", .run = linksOpen },
    .{ .name = "present", .about = "background-opacity doesn't darken an opaque (toggled) window; exact background pixels; translucent, premultiplied", .run = present },
    .{ .name = "theme", .about = "window-theme: caption colors, OSC 11 following, and the color scheme reaching terminals", .run = theme },
    .{ .name = "resize", .about = "resizing relays out the terminal, and the edge stays the background color", .run = resize },
    .{ .name = "resize-overlay", .about = "the grid size shows while a pane resizes: after-first, never, always, position, duration", .run = resizeOverlay },
    .{ .name = "context-menu", .about = "right-click opens GTK's menu with bindings and grayed entries; Copy, Paste, New Tab, Close Tab (which asks)", .run = contextMenu },
    .{ .name = "search", .about = "Ctrl+Shift+F search box: counter, Enter/Shift+Enter and buttons, Escape, reopening, search_selection", .run = search },
    .{ .name = "command-palette", .about = "Ctrl+Shift+P palette: supported commands only, filter, Enter runs New Tab, Focus: jumps (also to another window), row click, Escape and outside click close", .run = commandPalette },
    .{ .name = "header-bar", .about = "GTK's header bar: with one tab the strip shows its buttons (\"+\" opens a tab); fullscreen and gtk-titlebar = false hide it; window-show-tab-bar = never keeps the buttons without tabs; gtk-titlebar-style = tabs puts them in the tab row; gtk-tabs-inverted", .run = headerBar },
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
    .{ .name = "uia", .about = "a screen reader reads a pane through UI Automation's Text pattern: text, caret, words, lines, finding and selecting", .run = uiaScenario },
    .{ .name = "gl-reset", .about = "after a GPU driver reset (faked), the renderer builds itself in a new OpenGL context and draws the same frame", .run = glReset },
    .{ .name = "gl-missing", .about = "without OpenGL 4.3, murrtty says why at start: Remote Desktop, the basic display adapter, no driver, an old one", .run = glMissing },
    .{ .name = "gl-library", .about = "MURRTTY_OPENGL names the opengl32.dll to use; one that can't load is said so", .run = glLibrary },
    .{ .name = "ime-place", .about = "an IME asking where text is (WM_IME_REQUEST) is told the cursor's cell, and follows typing", .run = imePlace },
    .{ .name = "intl-keys", .about = "AltGr and Ctrl+Alt characters, and Alt+Numpad codes, reach a console program as Windows types them", .run = intlKeys },
    .{ .name = "mouse-settings", .about = "Windows' double-click time; a wheel notch scrolls its lines to scroll at a time (a page), which mouse-scroll-multiplier scales; a touchpad's part of a notch its part", .run = mouseSettings },
    .{ .name = "clipboard-html", .about = "a copy puts the text and HTML Format (offsets that find the copy); copy_to_clipboard:html the HTML alone, :plain the text alone", .run = clipboardHtml },
    .{ .name = "on-screen-keyboard", .about = "show_on_screen_keyboard gets Windows' input pane for the window (the hooks stop short of showing it)", .run = onScreenKeyboard },
    .{ .name = "crash-report", .about = "a crash (an access violation) and a Zig panic each leave a crash report naming it and the code, and +crash-report lists them", .run = crashReport },
    .{ .name = "osk-shown", .about = "show_on_screen_keyboard asks Windows to show the touch keyboard for real, then hides it; it may show ON SCREEN (GHOSTTY_GUI_ONSCREEN=1)", .run = oskShown },
    .{ .name = "font-registered", .about = "a font installed for the user from a folder with a non-ASCII name is found and opened", .run = fontRegistered },
    .{ .name = "output-frames", .about = "output that arrives with no key pressed is drawn", .run = outputFrames },
    .{ .name = "background-close", .about = "a tab closing in a background window leaves the active window active", .run = backgroundClose },
    .{ .name = "focus-background-tab", .about = "a tab that never got the focus doesn't stay focused in the core", .run = focusBackgroundTab },
    .{ .name = "splits", .about = "Ctrl+Shift+O/E split panes that tile the tab; closing panes moves focus as designed", .run = splits },
    .{ .name = "split-commands", .about = "goto_split, toggle_split_zoom (hidden panes stop drawing), resize_split, equalize_splits, minimums", .run = splitCommands },
    .{ .name = "split-mouse", .about = "dragging a divider, Esc (none of that keystroke reaches the core), double-click to equalize, the grip band", .run = splitMouse },
    .{ .name = "split-dim", .about = "unfocused panes are dimmed with unfocused-split-fill/-opacity; the dividers follow the focused pane's background, or split-divider-color", .run = splitDim },
    .{ .name = "shade", .about = "the top bars cast libadwaita's shade onto the panes that reach them, none without a bar; gtk-toolbar-style raised-border and flat", .run = shade },
    .{ .name = "translucent", .about = "background-opacity < 1: frames with its alpha (a split's too), the header bar and dividers opaque, toggle_background_opacity in every window and new ones, a reload to 1", .run = translucent },
    .{ .name = "window-options", .about = "window-position-x/-y for each window, toggle_window_float_on_top, reset_window_size, window-step-resize", .run = windowOptions },
    .{ .name = "tab-drag-close", .about = "a tab closing while another is dragged: the drag goes on with the tab pressed", .run = tabDragClose },
    .{ .name = "tab-drag", .about = "tabs reorder live as they are dragged, tear off into a new window, move onto another window's bar (an emptied window closes); move_tab_to_new_window", .run = tabDrag },
    .{ .name = "inspector", .about = "the terminal inspector: Ctrl+Shift+I opens a window for the pane that draws, with the core's inspector on; the mouse reaches it; the toggle, its close and the pane's close end it; its Terminal IO export writes the events", .run = inspectorScenario },
    .{ .name = "undo", .about = "undo and redo of closes (macOS's): a pane back where it was, still running, a tab, closed tabs together, a window where it was; not a pane whose program ended; a parked pane's program ending; expiry; quitting with the last window", .run = undoCloses },
    .{ .name = "pane-drag", .about = "panes move by their drag handle onto a half of another pane, in the tab, into a hovered tab, into another window (an emptied window closes); Escape cancels", .run = paneDrag },
    .{ .name = "decorations", .about = "window-decoration = none: no caption or header, the top band still resizes; toggle_window_decorations per window, the grid unchanged", .run = decorations },
    .{ .name = "blur", .about = "background-blur: Acrylic (DWM's system backdrop) on Windows 11 22H2+, else the accent policy (also forced); none when opaque, off or at opacity 1", .run = blurScenario },
    .{ .name = "split-grip", .about = "the grip band stops 64 px from a divider; a band picks the divider on its own side", .run = splitGrip },
    .{ .name = "split-all", .about = "an all: new_split binding splits every pane of ten tabs at once", .run = splitAll },
    .{ .name = "config-editor", .about = "the configuration editor (murrtty's own): from the terminal's menu and the palette; each option's value and where it comes from; search; a number, a switch and a choice set, a refused value, a value only murrtty takes pointed out, a reset; saving rewrites only the lines changed and reloads; unsaved changes ask; a Ghostty-only configuration edited in place", .run = configEditor },
    .{ .name = "pane-commit", .about = "thread stacks commit as they grow (under 1 MB each on average), not 16 MB each up front; a pane adds under 80 MB of commit charge in all", .run = paneCommit },
    .{ .name = "focus-follows-mouse", .about = "the mouse moving over a pane focuses it; not a pane moving under it, nor in an inactive window", .run = focusFollowsMouse },
    .{ .name = "pwd", .about = "OSC 9;9 and OSC 7 set the working directory; new tabs start there; relative links resolve against it", .run = pwdReports },
    .{ .name = "console-keys", .about = "a console program reads Shift+Left, Ctrl+C, Ctrl+Shift+C and Shift+Enter whole (win32-input-mode)", .run = consoleKeys },
    .{ .name = "pwsh-keys", .about = "win32-input-mode: Shift+arrows highlight PowerShell's text, Ctrl+C and Ctrl+Shift+C copy it, Shift+Enter adds a line", .run = pwshKeys },
    .{ .name = "pwsh-integration", .about = "PowerShell 7 and 5.1: the folder carries to new tabs, idle tabs close without asking, jump_to_prompt", .run = pwshIntegration },
    .{ .name = "cmd-integration", .about = "cmd (and Clink with GHOSTTY_GUI_CLINK): the folder carries to new tabs, idle tabs close without asking", .run = cmdIntegration },
    .{ .name = "cwd-fallback", .about = "without shell integration, cmd's cd still carries to new tabs and relative links", .run = cwdFallback },
    .{ .name = "ipc", .about = "+new-window (title, directory, command) and +new-tab (by surface id) open in the running murrtty over its pipe; what isn't a request is refused", .run = ipcRequests },
    .{ .name = "ipc-launch", .about = "+new-window with no murrtty running starts one for it, which serves the next; one started for a request that never comes quits", .run = ipcLaunch },
    .{ .name = "single-instance", .about = "gtk-single-instance hands a launch's window to the running murrtty; a separate one takes the pipe over when the first quits", .run = singleInstance },
    .{ .name = "open-config-window", .about = "open_config:new_window runs $EDITOR on the config in a new window; without one it opens the file as open_config does", .run = openConfigWindow },
    .{ .name = "global-keys", .about = "global: bindings as hot keys: registered, one runs its binding on WM_HOTKEY (new_window) and waits for a dialog, toggle_visibility hides every window in front and shows them, a binding that can't be had is told once as GTK's notification, a config with none brings hidden windows back", .run = globalKeysScenario },
    .{ .name = "tray", .about = "quit-after-last-window-closed = false: the tray icon stays and murrtty outlives its last window; a click opens a window or shows hidden ones, its menu has New Window, Config and Quit, a notification comes and goes on it; initial-window = false starts in the tray; a delay quits once it passes", .run = trayScenario },
    .{ .name = "quick-terminal", .about = "toggle_quick_terminal: one topmost tool window with no header bar at quick-terminal-position and -size, sliding in and out, hiding only while something can bring it back and showing when its last other window closes; quick-terminal-autohide; +toggle-quick-terminal over the pipe", .run = quickTerminalScenario },
    .{ .name = "progress", .about = "OSC 9;4: GTK's bar over the pane (accent, error tint, pulsing, paused) and the window's taskbar progress, the active tab's; gone after 15 s without a report; progress-style = false", .run = progressScenario },
    .{ .name = "command-finished", .about = "notify-on-command-finish: Command Succeeded and Failed with GTK's text past notify-on-command-finish-after, none for a short one; with never, the menu's Notify on Next Command Finish (checked) notifies once", .run = commandFinishedScenario },
    .{ .name = "notifications", .about = "OSC 9 and OSC 777 notify (titles cut to the balloon's 63 characters); a click presents the pane; the pane getting the keyboard, or 3 s for a focused one, takes it back; desktop-notifications = false", .run = notifications },
    .{ .name = "config-editor-pages", .about = "the configuration editor's pickers: a color's swatch and a file's button (Windows' dialogs stood in for), the font chooser (monospaced families, searched, one chosen) and the theme chooser", .run = configEditorPages },
    .{ .name = "second-launch", .about = "single instance by default: a second plain launch brings the running murrtty's minimized window back and opens nothing (with a dialog open, it raises the dialog); one with -e or --title= opens a new tab in the front window, from the launch's folder; one with a configuration option runs apart; -e reaches a murrtty in the tray", .run = secondLaunch },
    .{ .name = "fit-window", .about = "Fit Window to Screen, from the terminal's Window submenu and the system menu: an oversized window fits its monitor's work area, not maximized; a maximized one and a fullscreen one are restored and fitted", .run = fitWindow },
    .{ .name = "pane-history", .about = "each pane's own command history (PowerShell 5.1): a new pane copies its commands into its own file, one already in the shared history too; restored, Up brings back its own last command; a history no saved pane has goes at start; one of a pane closed for good goes after undo's time", .run = paneHistory },
    .{ .name = "clink-history", .about = "a cmd pane with Clink gets its own Clink history (CLINK_HISTORY_LABEL), and after murrtty quits and restarts, Up in the restored pane brings back its command (GHOSTTY_GUI_CLINK=folder)", .run = clinkHistory },
    .{ .name = "session-save", .about = "the session saved as it changes (session.json): the window, a tab and its pane's directory, a new tab, the tab in front, a split; a move saved as it ends, a divider as it is let go; a drag Esc cancels or murrtty ending mid-drag saves nothing; an unwritable state folder said once", .run = sessionSave },
    .{ .name = "session-restore", .about = "a saved session back at start (a class's own file): windows, names, sizes, tabs, splits' sizes, directories, a gone folder (home, a toast), cmd of its own, a lost oversized window pulled on screen, the quick terminal's tabs when summoned; saved back, kept by quitting; initial-window = false restores on the first window asked for; never; the crash guard", .run = sessionRestore },
    .{ .name = "config-editor-look", .about = "pictures of the configuration editor, dark and light, a row opened, for looking at by eye (GHOSTTY_GUI_SNAPSHOT=folder)", .run = configEditorLook },
    .{ .name = "stress-panes", .about = "16 panes flooding output keep rendering (GHOSTTY_GUI_STRESS=1)", .run = stressPanes },
    .{ .name = "quit-after-reload", .about = "20 launches, each quitting right after two config reloads (the system's light/dark switch), all exit 0: the stopping renderer still releases a font grid swap it hadn't taken (GHOSTTY_GUI_STRESS=1)", .run = quitAfterReload },
    .{ .name = "overlay-host", .about = "spike S1: a layered child window over each pane stays clean while output floods and the window resizes (GHOSTTY_GUI_SPIKE=1)", .run = overlayHost },
    .{ .name = "snapshot", .about = "pictures of the window (one tab, a split) for comparing with GTK's by eye, off-screen (GHOSTTY_GUI_SNAPSHOT=folder)", .run = snapshot },
    .{ .name = "transparency", .about = "background-opacity through DWM blur-behind, header and divider opaque, toggle_background_opacity, over a green backdrop ON SCREEN (GHOSTTY_GUI_ONSCREEN=1)", .run = transparency },
    .{ .name = "blur-display", .about = "background-blur blurs a striped backdrop seen through the background ON SCREEN (GHOSTTY_GUI_ONSCREEN=1)", .run = blurDisplay },
    .{ .name = "taskbar-shown", .about = "OSC 9;4 on a real taskbar button: the button is made (TaskbarButtonCreated) and ITaskbarList3 takes the progress, off-screen on the user's desktop (GHOSTTY_GUI_ONSCREEN=1: a button shows on the taskbar)", .run = taskbarShown },
    .{ .name = "notify-shown", .about = "an OSC 9 notification really shows: Windows takes the icon and its balloon, then it is taken back; a toast appears ON SCREEN (GHOSTTY_GUI_ONSCREEN=1)", .run = notifyShown },
    .{ .name = "tray-shown", .about = "the tray's icon really in the notification area (Shell_NotifyIconW takes it), gone as murrtty quits, off-screen on the user's desktop (GHOSTTY_GUI_ONSCREEN=1: the icon shows for a moment)", .run = trayShown },
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

/// The line `snapshot`'s frame shows, as GTK's reference shows it with
/// `.\gtkref.ps1 -Extra "command = printf '<look_text>\n'; exec sleep 60"`
/// (test/windows/look). Nothing cmd's echo or printf would read as syntax.
const look_text = "The quick brown fox jumps over the lazy dog 0123456789 []{}=+-*/.,;:!?";

/// Opt-in (GHOSTTY_GUI_SNAPSHOT = a folder): pictures for comparing with
/// Ghostty's GTK app (test/windows/look). First the terminal as the
/// renderer drew it, sized as GTK's at 96 DPI and showing `look_text`
/// (frame-tab.bmp), on the hidden desktop; then, where captures work, the
/// whole window: one tab, split right, then a second tab
/// (snapshot-tab.bmp, snapshot-split.bmp, snapshot-tabs.bmp, and
/// chrome-*.bmp), off-screen on the user's desktop, like pixels; no menus,
/// which Windows would pull on screen.
fn snapshot(h: *Harness) anyerror!void {
    var dir_w: [260:0]u16 = undefined;
    const n = w.GetEnvironmentVariableW(w.L("GHOSTTY_GUI_SNAPSHOT"), &dir_w, dir_w.len);
    if (n == 0 or n >= dir_w.len) return h.skip("set GHOSTTY_GUI_SNAPSHOT to a folder to run it", .{});
    var dir_buf: [1024]u8 = undefined;
    const dir_len = std.unicode.utf16LeToUtf8(&dir_buf, dir_w[0..n]) catch return h.fail("bad folder name", .{});
    try snapshotFrame(h, dir_buf[0..dir_len]);
    if (h.capturesWork()) |why| return h.skip("window pictures: {s}", .{why});
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

/// frame-tab.bmp: GTK's default font size (12 points, 16 pixels at 96 DPI)
/// scaled by 96/DPI so the cells come out in GTK's pixels. Padding stays
/// as configured (whole points), so the grid may sit a pixel off GTK's.
fn snapshotFrame(h: *Harness, dir: []const u8) !void {
    const dpi = dpi: {
        var g = try h.launch("snapshot-dpi", base_config);
        defer g.deinit();
        break :dpi w.GetDpiForWindow(try h.mainWindow(&g));
    };
    const config = try std.fmt.allocPrint(h.alloc, base_config ++
        \\command = direct:cmd.exe /c "echo {s}&& pause>nul"
        \\keybind = ctrl+shift+f2=prompt_surface_title
        \\font-size = {d}
        \\window-width = 80
        \\window-height = 24
        \\
    , .{ look_text, 12.0 * 96.0 / @as(f64, @floatFromInt(dpi)) });
    defer h.alloc.free(config);
    var g = try h.launch("snapshot-frame", config);
    defer g.deinit();
    try h.waitText(&g, look_text, 1, 20000);
    w.Sleep(500);
    try h.saveFrames(&g);
    try copyOut(h, &g, "frame-0.bmp", dir, "frame-tab.bmp");
    // The chrome as WM_PAINT draws it, at the window's DPI: the header bar,
    // then with gtk-titlebar-style = tabs the tab row holding its buttons.
    try h.saveChrome(&g);
    try copyOut(h, &g, "chrome-0.bmp", dir, "paint-header.bmp");
    var styled = try h.launch("snapshot-tabs-style", base_config ++ "gtk-titlebar-style = tabs\nwindow-width = 80\n");
    defer styled.deinit();
    try h.waitText(&styled, ">", 1, 20000);
    w.Sleep(500);
    try h.saveChrome(&styled);
    try copyOut(h, &styled, "chrome-0.bmp", dir, "paint-tabs-style.bmp");
    // The menus as they paint themselves: the main menu, then the
    // terminal's.
    const win = try h.mainWindow(&g);
    const at = try stripButton(h, &g, .menu);
    h.press(win, at.x, at.y);
    try saveMenu(h, &g, dir, "paint-main-menu.bmp");
    const surf = try h.surface(&g, win);
    h.rightPress(surf, 200, 150);
    try saveMenu(h, &g, dir, "paint-context-menu.bmp");
    // The alert dialogs: a close confirmation, the title prompt.
    for ([_]struct { u8, []const u8 }{ .{ 'W', "paint-dialog.bmp" }, .{ w.VK_F2, "paint-title-dialog.bmp" } }) |d| {
        h.key(surf, .{ .ctrl = true, .shift = true }, d[0]);
        const dlg = try h.waitDialog(&g, 5000);
        w.Sleep(300);
        var img = h.capturePrint(dlg) catch return h.fail("dialog capture failed", .{});
        defer img.deinit();
        const path = try std.fmt.allocPrint(h.alloc, "{s}\\{s}", .{ dir, d[1] });
        defer h.alloc.free(path);
        try img.save(path);
        h.answer(&g, dlg, w.IDCANCEL);
        try waitNoDialog(h, &g);
    }
    try h.expect(true, "wrote frame-tab.bmp, paint-header.bmp and paint-tabs-style.bmp to {s} at {d} DPI", .{ dir, dpi });
}

/// Wait for a menu, write its picture to `dir` as `name`, and close it.
fn saveMenu(h: *Harness, g: *const Harness.Ghostty, dir: []const u8, name: []const u8) !void {
    const menu = try h.waitMenu(g, 1, 5000);
    w.Sleep(300);
    var img = h.capturePrint(menu) catch return h.fail("menu capture failed", .{});
    defer img.deinit();
    const path = try std.fmt.allocPrint(h.alloc, "{s}\\{s}", .{ dir, name });
    defer h.alloc.free(path);
    try img.save(path);
    _ = w.PostMessageW(menu, w.WM_KEYDOWN, w.VK_ESCAPE, 0);
    w.Sleep(300);
}

/// With GHOSTTY_GUI_SNAPSHOT set, write the dialog's picture there as
/// `name` (as it paints itself; it works on the hidden desktop).
fn snapshotDialog(h: *Harness, dlg: w.HWND, name: []const u8) !void {
    var dir_w: [260:0]u16 = undefined;
    const n = w.GetEnvironmentVariableW(w.L("GHOSTTY_GUI_SNAPSHOT"), &dir_w, dir_w.len);
    if (n == 0 or n >= dir_w.len) return;
    var dir_buf: [1024]u8 = undefined;
    const len = std.unicode.utf16LeToUtf8(&dir_buf, dir_w[0..n]) catch return;
    w.Sleep(300);
    var img = h.capturePrint(dlg) catch return;
    defer img.deinit();
    const path = try std.fmt.allocPrint(h.alloc, "{s}\\{s}", .{ dir_buf[0..len], name });
    defer h.alloc.free(path);
    try img.save(path);
}

/// Copy `name` from beside `g`'s dump file to `dir` as `as`.
fn copyOut(h: *Harness, g: *const Harness.Ghostty, name: []const u8, dir: []const u8, as: []const u8) !void {
    const from = try std.fmt.allocPrint(h.alloc, "{s}\\{s}", .{ std.fs.path.dirname(g.dump_path).?, name });
    defer h.alloc.free(from);
    const to = try std.fmt.allocPrint(h.alloc, "{s}\\{s}", .{ dir, as });
    defer h.alloc.free(to);
    const bytes = h.readFileOrNull(from) orelse return h.fail("no {s}", .{from});
    defer h.alloc.free(bytes);
    try h.writeFileAt(to, bytes);
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
    // libadwaita's alert dialog (roadmap 4.3b): Cancel the default, Close
    // the other response, the window dimmed behind it.
    try h.expect(defaultButton(dlg) == w.IDCANCEL, "Cancel is the default ({d})", .{defaultButton(dlg)});
    {
        const label = try dialogItemText(h, dlg, w.IDYES);
        defer h.alloc.free(label);
        try h.expect(std.mem.eql(u8, label, "Close"), "the other response is Close ('{s}')", .{label});
    }
    const top = childAt(try h.mainWindow(&g), 10, 10);
    try h.expect(top != null and hasClass(top.?, std.unicode.utf8ToUtf16LeStringLiteral("MurrttyPaletteDim")), "the window is dimmed behind it", .{});
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

/// A bare command name (roadmap 6.6) runs the program in Windows' system
/// folders or on PATH, never a same-named one in the folder murrtty started
/// in (a shell's, when started from one), which Windows' own search tries
/// first: with a "cmd.exe" there (a copy of whoami), `command = cmd.exe /d`
/// still starts Windows' cmd. Launched without
/// NoDefaultCurrentDirectoryInExePath (Claude Code's environment sets it,
/// which keeps Windows' search out of the current folder and so would hide
/// the planted one). PowerShell 7 by its bare name, `pwsh`, starts in
/// pwsh-keys and pwsh-integration.
fn bareCommand(h: *Harness) anyerror!void {
    // murrtty starts in its scenario's folder (Harness.launchWith).
    const dir = try std.fmt.allocPrint(h.alloc, "{s}\\bare-command", .{h.temp_dir});
    defer h.alloc.free(dir);
    try h.makeDirAt(dir);
    const planted = try std.fmt.allocPrint(h.alloc, "{s}\\cmd.exe", .{dir});
    defer h.alloc.free(planted);
    const whoami = h.readFileOrNull("C:\\Windows\\System32\\whoami.exe") orelse return h.skip("no whoami.exe to plant", .{});
    defer h.alloc.free(whoami);
    try h.writeFileAt(planted, whoami);
    defer h.deleteFile(planted);

    // With an argument: a lone `cmd.exe` is %COMSPEC%'s full path (Exec).
    {
        var g = try h.launchWith("bare-command", base_config ++ "command = cmd.exe /d\n", .{ .unset = &.{"NoDefaultCurrentDirectoryInExePath"} });
        defer g.deinit();
        try h.waitText(&g, "Microsoft Windows", 1, 20000);
        try h.expect(true, "with a cmd.exe planted where murrtty started, command = cmd.exe starts Windows' cmd (its banner)", .{});
        try quit(h, &g, try h.surface(&g, try h.mainWindow(&g)));
    }

    // A batch file on PATH, a same-named one in the shell's folder
    // (working-directory): it runs as `cmd /c`, which looks its name up
    // again, in that folder first; murrtty hands it the found path.
    const real = try std.fmt.allocPrint(h.alloc, "{s}\\bare-command-batch-real", .{h.temp_dir});
    defer h.alloc.free(real);
    const there = try std.fmt.allocPrint(h.alloc, "{s}\\bare-command-batch-there", .{h.temp_dir});
    defer h.alloc.free(there);
    try h.makeDirAt(real);
    try h.makeDirAt(there);
    const real_cmd = try std.fmt.allocPrint(h.alloc, "{s}\\murrtty-test-tool.cmd", .{real});
    defer h.alloc.free(real_cmd);
    const there_cmd = try std.fmt.allocPrint(h.alloc, "{s}\\murrtty-test-tool.cmd", .{there});
    defer h.alloc.free(there_cmd);
    try h.writeFileAt(real_cmd, "@echo the-real-tool\r\n@cmd /d /k\r\n");
    defer h.deleteFile(real_cmd);
    try h.writeFileAt(there_cmd, "@echo a-planted-tool\r\n@cmd /d /k\r\n");
    defer h.deleteFile(there_cmd);
    const path_var = try std.fmt.allocPrint(h.alloc, "{s};C:\\Windows\\System32;C:\\Windows", .{real});
    defer h.alloc.free(path_var);
    const config = try std.fmt.allocPrint(h.alloc, base_config ++ "command = murrtty-test-tool.cmd\nworking-directory = {s}\n", .{there});
    defer h.alloc.free(config);
    var g = try h.launchWith("bare-command-batch", config, .{
        .env = &.{.{ "PATH", path_var }},
        .unset = &.{"NoDefaultCurrentDirectoryInExePath"},
    });
    defer g.deinit();
    try h.waitText(&g, "the-real-tool", 1, 20000);
    {
        var d = try h.dump(&g);
        defer d.deinit();
        const text = d.value.windows[0].tabs[0].text orelse "";
        try h.expect(std.mem.indexOf(u8, text, "a-planted-tool") == null, "a bare batch name runs the one on PATH, not the shell folder's", .{});
    }
    try quit(h, &g, try h.surface(&g, try h.mainWindow(&g)));
}

/// Windows ending the session (roadmap 5.10's first part, decided): murrtty
/// lets it end without asking, as upstream does at shutdown, restart and
/// log-off (macOS skips its quit confirmation then, GTK holds no logout
/// inhibitor), though a close here would ask (the base config's idle cmd
/// prompt). WM_QUERYENDSESSION is answered yes and no dialog opens.
fn sessionEnd(h: *Harness) anyerror!void {
    var g = try start(h, "session-end", "", ">");
    defer g.deinit();
    const win = try h.mainWindow(&g);
    const surf = try h.surface(&g, win);
    var result: usize = 0;
    const sent = w.SendMessageTimeoutW(win, w.WM_QUERYENDSESSION, 0, w.ENDSESSION_LOGOFF, w.SMTO_ABORTIFHUNG, 5000, &result);
    try h.expect(sent != 0 and result != 0, "WM_QUERYENDSESSION is answered yes (sent {d}, result {d})", .{ sent, result });
    h.sync(surf);
    w.Sleep(300);
    {
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(d.value.modal_depth == 0, "and no dialog asks", .{});
    }
    try quit(h, &g, surf);
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
        try snapshotDialog(h, dlg, "paint-clipboard-dialog.bmp");
        // The switch toggles on a click, and on a double click's second
        // (BN_DOUBLECLICKED), so two quick clicks leave it as it was.
        const clicked: w.WPARAM = 101;
        const double: w.WPARAM = 101 | (5 << 16);
        for ([_]struct { w.WPARAM, usize }{ .{ clicked, 1 }, .{ double, 0 } }) |step| {
            _ = w.PostMessageW(dlg, w.WM_COMMAND, step[0], @bitCast(@intFromPtr(box)));
            w.Sleep(200);
            var state: usize = 9;
            _ = w.SendMessageTimeoutW(box, w.BM_GETCHECK, 0, 0, w.SMTO_ABORTIFHUNG, 2000, &state);
            try h.expect(state == step[1], "the switch reads {d} after a click (expected {d})", .{ state, step[1] });
        }
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

/// The background Ghostty presents with `config` (background-opacity below
/// 1) once toggle_background_opacity has made its window opaque, read from
/// a frame drawn after the toggle (the left padding, clear of the bars'
/// shade).
fn opaquePixel(h: *Harness, name: []const u8, comptime config: []const u8) !u32 {
    var g = try start(h, name, config ++ toggle_opacity, ">");
    defer g.deinit();
    h.key(try h.surface(&g, try h.mainWindow(&g)), .{ .ctrl = true, .shift = true }, w.VK_F3);
    try expectTranslucent(h, &g, &.{false});
    const px = try h.probePane(&g, 0, 1, 40);
    h.log("{s}: #{x:0>6}", .{ name, px });
    return px;
}

/// An opaque window (background-opacity 1, or toggled opaque below it)
/// shows the background color as configured, not darkened toward black
/// (roadmap 0.3); a translucent one presents it premultiplied by the
/// opacity, for DWM to compose over what is behind (4.1).
fn present(h: *Harness) anyerror!void {
    const default = try presentedPixel(h, "present-default", "");
    try h.expect(default == 0x282c34, "default background #{x:0>6}, expected #282c34", .{default});
    const half = try presentedPixel(h, "present-opacity", "background-opacity = 0.5\n");
    try h.expect(nearColor(half, 0x14161a), "translucent at opacity 0.5, #{x:0>6}: #282c34 premultiplied (#14161a)", .{half});
    const half_opaque = try opaquePixel(h, "present-opacity-opaque", "background-opacity = 0.5\n");
    try h.expect(half_opaque == 0x282c34, "opacity 0.5 toggled opaque gives #{x:0>6}, expected #282c34", .{half_opaque});
    const color = try opaquePixel(h, "present-color", "background = #336699\nbackground-opacity = 0.3\n");
    try h.expect(color == 0x336699, "#336699 at opacity 0.3, opaque, gives #{x:0>6}", .{color});
    // Native (non-linear) blending, whose colors used to be encoded twice
    // (#336699 showed as #7caacb). Its sRGB values pass through the sRGB
    // target's 8-bit encoding, which can be off by one.
    const native_opaque = try presentedPixel(h, "present-native-1", "background = #336699\nalpha-blending = native\n");
    try h.expect(nearColor(native_opaque, 0x336699), "native blending gives #{x:0>6}, expected #336699", .{native_opaque});
    const native_part = try opaquePixel(h, "present-native-0.3", "background = #336699\nbackground-opacity = 0.3\nalpha-blending = native\n");
    try h.expect(nearColor(native_part, 0x336699), "native blending at opacity 0.3, opaque, gives #{x:0>6}", .{native_part});
    const native_clear = try presentedPixel(h, "present-native-0.3-translucent", "background = #336699\nbackground-opacity = 0.3\nalpha-blending = native\n");
    try h.expect(nearColor(native_clear, 0x0f1f2e), "and translucent #{x:0>6}: #336699 premultiplied (#0f1f2e)", .{native_clear});

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
    try snapshotDialog(h, dlg, "paint-config-errors.bmp");

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
        try h.expect(std.mem.eql(u8, items[2].text, "&Notify on Next Command Finish") and !items[2].grayed and !items[2].checked, "Notify on Next Command Finish, enabled and unchecked ('{s}')", .{items[2].text});
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
    try h.expect(!p.has("Check for Updates"), "commands this runtime lacks are not", .{});
    try h.expect(p.has("Toggle Inspector"), "Toggle Inspector is, since 5.12", .{});
    try h.expect(p.has("Move Tab to New Window"), "Move Tab to New Window is, since 4.5", .{});
    try h.expect(p.has("Change Tab Title\u{2026}"), "the title prompts are (roadmap 3.5)", .{});
    try h.expect(p.has("Copy Selection as HTML to Clipboard") and p.has("Show On-Screen Keyboard"), "the HTML copy and the touch keyboard are, since 6.5", .{});
    try h.expect(p.has("Paste from Selection"), "Paste from Selection is, since 5.9", .{});

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
    // Over the header bar it leaves the caption and the window's buttons
    // to the window, and covers the bar's own buttons.
    {
        var d = try h.dump(&g);
        defer d.deinit();
        const hb = d.value.windows[0].header;
        var client: w.RECT = .{};
        _ = w.GetClientRect(win, &client);
        const dim = hwndOf(p.dim);
        try h.expect(hitTestAt(dim, win, .{ @divTrunc(client.right, 2), @divTrunc(hb.height, 2) }) == w.HTTRANSPARENT, "over the caption the dimming lets the window have it", .{});
        try h.expect(hitTestAt(dim, win, rectMid(hb.window_close)) == w.HTTRANSPARENT, "and over close", .{});
        try h.expect(hitTestAt(dim, win, rectMid(hb.new_tab)) == w.HTCLIENT, "but over \"+\" it is the dimming's", .{});
    }
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
/// binding, and Move Tab to New Window (roadmap 4.5); Close Others and
/// Move are grayed with one tab, Close to the Right on the last. It acts
/// on the tab clicked, which stays in the background.
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
            .{ .text = "&Move Tab to New Window", .grayed = false },
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
        try h.expect(items.len == 7 and items[3].grayed and items[4].grayed and items[6].grayed and !items[2].grayed, "with one tab, Close Other Tabs, Close Tabs to the Right and Move Tab to New Window are grayed", .{});
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
/// button at the right end opens GTK's main menu for it, whose New Tab and
/// Command Palette work, and whose
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
            try h.expect(std.mem.startsWith(u8, items[16].text, "Terminal &Inspector") and !items[16].grayed, "Terminal Inspector (roadmap 5.12)", .{});
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

        // Never narrower than the bar's buttons side by side (they would
        // overlap, and clicks reach other buttons than those drawn).
        {
            var r: w.RECT = .{};
            _ = w.GetWindowRect(win, &r);
            const flags = w.SWP_NOMOVE | w.SWP_NOZORDER | w.SWP_NOACTIVATE;
            _ = w.SetWindowPos(win, null, 0, 0, 100, r.bottom - r.top, flags);
            var d = try h.dump(&g);
            defer d.deinit();
            const narrow = d.value.windows[0].header;
            try h.expect(narrow.list[0] >= narrow.new_tab_menu[2], "at its narrowest the buttons stay apart (the arrow ends at {d}, the list starts at {d})", .{ narrow.new_tab_menu[2], narrow.list[0] });
            _ = w.SetWindowPos(win, null, 0, 0, r.right - r.left, r.bottom - r.top, flags);
        }

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
    {
        // gtk-titlebar-style = tabs: the tab row is the title bar, with one
        // tab too, holding the header's buttons around its tabs as GTK's.
        var g = try start(h, "header-bar-tabs", "gtk-titlebar-style = tabs\n", ">");
        defer g.deinit();
        const win = try h.mainWindow(&g);
        try waitChrome(h, &g, false, true, "tabs style, one tab: no header bar, the tab row");
        var hb: Harness.Dump.Header = undefined;
        var row_top: i32 = 0;
        var row_height: i32 = 0;
        var tab: [4]i32 = undefined;
        {
            var d = try h.dump(&g);
            defer d.deinit();
            const dw = d.value.windows[0];
            hb = dw.header;
            row_top = dw.tab_bar.top;
            row_height = dw.tab_bar.height;
            tab = dw.tab_bar.tabs[0].rect;
        }
        try h.expect(row_top == 0, "the row at the top (at {d})", .{row_top});
        try h.expect(hb.menu[2] == hb.minimize[0], "the menu button beside minimize, as GTK's ({d}, {d})", .{ hb.menu[2], hb.minimize[0] });
        try h.expect(tab[0] == hb.new_tab_menu[2] and tab[2] == hb.list[0], "the tab between the split arrow and the tab list's button ({d} to {d})", .{ tab[0], tab[2] });
        const mid_y = @divTrunc(row_height, 2);
        try expectNcHit(h, win, rectMid(hb.minimize), w.HTMINBUTTON, "over minimize: the caption's minimize button");
        try expectNcHit(h, win, rectMid(hb.window_close), w.HTCLOSE, "over close: the caption's close");
        try expectNcHit(h, win, rectMid(hb.new_tab), w.HTCLIENT, "over \"+\": the window's own button");
        try expectNcHit(h, win, .{ @divTrunc(tab[0] + tab[2], 2), mid_y }, w.HTCLIENT, "over the tab: the tab's");
        try expectNcHit(h, win, .{ 2, mid_y }, w.HTCAPTION, "beside the split button: the caption");
        const plus = try stripButton(h, &g, .new_tab);
        h.click(win, plus.x, plus.y, .left);
        try waitWindowTabs(h, &g, win, 2);
        try quit(h, &g, try h.surface(&g, win));
    }
    {
        // Without client-side decorations the row keeps its buttons, but
        // not the window's.
        var g = try start(h, "header-bar-tabs-server", "gtk-titlebar-style = tabs\nwindow-decoration = server\n", ">");
        defer g.deinit();
        const win = try h.mainWindow(&g);
        try waitChrome(h, &g, false, true, "tabs style, server decorations: the tab row");
        try expectSystemCaption(h, win, "below the system's caption");
        var d = try h.dump(&g);
        defer d.deinit();
        const hb = d.value.windows[0].header;
        try h.expect(hb.minimize[0] == hb.minimize[2] and hb.window_close[0] == hb.window_close[2], "and no window buttons in it", .{});
        try quit(h, &g, try h.surface(&g, win));
    }
    {
        // gtk-tabs-inverted: a tab's close button at its start.
        var g = try start(h, "tabs-inverted", "window-show-tab-bar = always\ngtk-tabs-inverted = true\n", ">");
        defer g.deinit();
        const win = try h.mainWindow(&g);
        h.key(try h.surface(&g, win), cs, 'T');
        try waitWindowTabs(h, &g, win, 2);
        try waitActivePaneText(h, &g, win, ">");
        var close: [4]i32 = undefined;
        {
            var d = try h.dump(&g);
            defer d.deinit();
            const t = d.value.windows[0].tab_bar.tabs[1];
            close = t.close;
            try h.expect(close[0] - t.rect[0] < @divTrunc(t.rect[2] - t.rect[0], 2), "inverted, the close button is at the tab's start ({d} in a tab from {d})", .{ close[0], t.rect[0] });
        }
        const at = rectMid(close);
        h.click(win, at[0], at[1], .left);
        h.answer(&g, try h.waitDialog(&g, 5000), w.IDYES);
        try waitWindowTabs(h, &g, win, 1);
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
    // Its buttons show in the header bar, or in the tab row
    // (gtk-titlebar-style = tabs).
    if (!bar.visible and !bar.in_row) return h.fail("the header bar isn't showing", .{});
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

    // Enter clicks the button with the keyboard, as in GTK's dialogs: Tab
    // from the field to Cancel, then Enter cancels (Windows would take
    // the default, OK).
    h.key(surf, cs, w.VK_F2);
    dlg = try h.waitDialog(&g, 5000);
    try setDialogText(h, dlg, "nor-this");
    const entry = w.GetDlgItem(dlg, 100) orelse return h.fail("the prompt has no field", .{});
    _ = w.PostMessageW(entry, w.WM_KEYDOWN, w.VK_TAB, 0);
    w.Sleep(300);
    const cancel = w.GetDlgItem(dlg, w.IDCANCEL) orelse return h.fail("the prompt has no Cancel", .{});
    _ = w.PostMessageW(cancel, w.WM_KEYDOWN, w.VK_RETURN, 0);
    try waitNoDialog(h, &g);
    t = try titleState(h, &g);
    try h.expect(std.mem.eql(u8, t.label(), "program-two"), "Enter on Cancel cancels ('{s}')", .{t.label()});

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
    fn scrolledBack(s: ScrollState) bool {
        return s.total > s.len and s.offset + s.len < s.total;
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

/// Whether `hwnd`'s window class is `class`.
fn hasClass(hwnd: w.HWND, class: []const u16) bool {
    var buf: [64]u16 = undefined;
    const n = w.GetClassNameW(hwnd, &buf, buf.len);
    return n > 0 and std.mem.eql(u16, buf[0..@intCast(n)], class);
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

        // The version Explorer shows is +version's (roadmap 6.5).
        const marker = "based on Ghostty ";
        const at = std.mem.indexOf(u8, r.out, marker) orelse return h.fail("+version names no Ghostty version: '{s}'", .{r.out});
        const rest = r.out[at + marker.len ..];
        const printed = std.mem.trim(u8, rest[0 .. std.mem.indexOfAny(u8, rest, "\r\n") orelse rest.len], " ");
        const v = try h.exeVersion();
        defer h.alloc.free(v.text);
        try h.expect(std.mem.eql(u8, v.text, printed), "the version resource's FileVersion is +version's ('{s}', +version '{s}')", .{ v.text, printed });
        const sem = std.SemanticVersion.parse(printed) catch return h.fail("+version's '{s}' isn't a version", .{printed});
        try h.expect(v.numbers[0] == sem.major and v.numbers[1] == sem.minor and v.numbers[2] == sem.patch and v.numbers[3] == 0, "and its file version is {d}.{d}.{d}.{d}", .{ v.numbers[0], v.numbers[1], v.numbers[2], v.numbers[3] });
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

/// Roadmap 6.5: murrtty takes the mouse settings' double-click time, and a
/// wheel notch scrolls their "lines to scroll at a time" (a page for "one
/// screen at a time"), which mouse-scroll-multiplier scales (its default,
/// 3, stands for the setting's lines); a touchpad's part of a notch
/// scrolls its part. The setting is faked (GHOSTTY_WIN32_TEST_WHEEL_LINES)
/// but for the first case, which reads the owner's own.
fn mouseSettings(h: *Harness) anyerror!void {
    var system: w.UINT = 3;
    if (w.SystemParametersInfoW(w.SPI_GETWHEELSCROLLLINES, 0, &system, 0) == 0) system = 3;
    const Case = struct {
        name: []const u8,
        lines: ?[]const u8 = null,
        extra: []const u8 = "",
        /// Rows a notch scrolls; null for a page.
        notch: ?u32,
        /// Rows three thirds of a notch from a touchpad scroll, if checked.
        touchpad: ?u32 = null,
    };
    const cases = [_]Case{
        .{ .name = "mouse-settings", .notch = if (system == w.WHEEL_PAGESCROLL) null else system },
        .{ .name = "mouse-settings-6", .lines = "6", .notch = 6, .touchpad = 6 },
        .{ .name = "mouse-settings-page", .lines = "page", .notch = null },
        .{ .name = "mouse-settings-x1", .lines = "6", .extra = "mouse-scroll-multiplier = discrete:1\n", .notch = 2, .touchpad = 6 },
        // Not multiples of 3: a third of them came back a hair under a row
        // at cell heights of 14, 25, 28 and 31 px, among others (at 125%
        // this size makes 28; the base config's makes 26, which was
        // exact).
        .{ .name = "mouse-settings-1", .lines = "1", .extra = "font-size = 12.5\n", .notch = 1 },
        .{ .name = "mouse-settings-4", .lines = "4", .extra = "font-size = 12.5\n", .notch = 4 },
        // More than a page is a page; none is none.
        .{ .name = "mouse-settings-huge", .lines = "100000", .notch = null },
        .{ .name = "mouse-settings-0", .lines = "0", .notch = 0 },
    };
    // Windows' default double-click time is also murrtty's fallback, 500
    // ms, so the first launch has it 17 ms longer (for the session, not
    // saved; too little to notice), put back once murrtty has read it.
    const click_time = w.GetDoubleClickTime();
    const bump: w.UINT = if (click_time + 17 == 500) 27 else 17;
    var click_moved = w.SetDoubleClickTime(click_time + bump) != 0;
    const moved_at_launch = click_moved;
    defer if (click_moved) {
        _ = w.SetDoubleClickTime(click_time);
    };
    for (cases, 0..) |case, i| {
        const config = try std.mem.concat(h.alloc, u8, &.{ base_config, case.extra });
        defer h.alloc.free(config);
        var g = if (case.lines) |l|
            try h.launchWith(case.name, config, .{ .env = &.{.{ "GHOSTTY_WIN32_TEST_WHEEL_LINES", l }} })
        else
            try h.launch(case.name, config);
        defer g.deinit();
        try h.waitText(&g, ">", 1, 20000);
        const surf = try h.surface(&g, try h.mainWindow(&g));
        if (i == 0) {
            const want = w.GetDoubleClickTime();
            if (click_moved) {
                _ = w.SetDoubleClickTime(click_time);
                click_moved = false;
            }
            var d = try h.dump(&g);
            defer d.deinit();
            try h.expect(d.value.click_interval == want and (want != 500 or !moved_at_launch), "click-repeat-interval is Windows' double-click time ({d} ms; Windows {d})", .{ d.value.click_interval, want });
        }
        if (case.notch == 0 and case.lines == null) {
            h.log("the wheel is set to scroll nothing here; not checked", .{});
            try quit(h, &g, surf);
            continue;
        }
        try h.typeText(surf, "for /L %i in (1,1,200) do @echo row %i");
        h.enter(surf);
        try h.waitText(&g, "row 200", 1, 20000);
        const bottom = try waitScroll(h, &g, ScrollState.atBottom, "to the bottom", 5000);
        var rect: w.RECT = undefined;
        _ = w.GetClientRect(surf, &rect);
        const cx = @divTrunc(rect.right, 2);
        const cy = @divTrunc(rect.bottom, 2);

        h.wheel(surf, cx, cy, 1);
        if (case.notch == 0) {
            h.sync(surf);
            w.Sleep(300);
            const still = try scrollState(h, &g);
            try h.expect(still.offset == bottom.offset, "{s}: a notch scrolls nothing (moved {d})", .{ case.name, rowsUp(bottom, still) });
            try quit(h, &g, surf);
            continue;
        }
        const one = try waitScrolled(h, &g, bottom.offset);
        const want = case.notch orelse bottom.len;
        const moved = rowsUp(bottom, one);
        const cell_h = cell: {
            var d = try h.dump(&g);
            defer d.deinit();
            const cell = d.value.windows[0].tabs[0].cell orelse break :cell 0;
            break :cell cell[1];
        };
        try h.expect(moved == want, "{s}: a notch scrolls {d} rows (moved {d}; cells {d} px high)", .{ case.name, want, moved, cell_h });

        if (case.touchpad) |t| {
            for (0..3) |_| h.wheelDelta(surf, cx, cy, 40);
            const three = try waitScrolled(h, &g, one.offset);
            const touch = rowsUp(one, three);
            try h.expect(touch == t, "{s}: three thirds of a notch from a touchpad scroll {d} rows (moved {d})", .{ case.name, t, touch });
        }
        try quit(h, &g, surf);
    }
}

/// Rows the viewport moved up from `a` to `b`.
fn rowsUp(a: ScrollState, b: ScrollState) i64 {
    return @as(i64, @intCast(a.offset)) - @as(i64, @intCast(b.offset));
}

/// The scrollbar once the viewport has moved from `offset` and settled.
fn waitScrolled(h: *Harness, g: *Harness.Ghostty, offset: u64) !ScrollState {
    var last = try scrollState(h, g);
    var waited: u32 = 0;
    while (last.offset == offset and waited < 5000) : (waited += 50) {
        w.Sleep(50);
        last = try scrollState(h, g);
    }
    w.Sleep(300);
    return try scrollState(h, g);
}

/// Roadmap 6.5: a copy (copy_to_clipboard's default, mixed) puts the text
/// and the HTML on the clipboard, the HTML as Windows' "HTML Format" with
/// offsets that find the document and the copy; copy_to_clipboard:html
/// the HTML alone, :plain the text alone.
fn clipboardHtml(h: *Harness) anyerror!void {
    var saved = try h.saveClipboard();
    defer saved.restore();
    var g = try start(h, "clipboard-html", "keybind = ctrl+shift+f5=copy_to_clipboard:html\nkeybind = ctrl+shift+f6=copy_to_clipboard:plain\n", ">");
    defer g.deinit();
    const surf = try h.surface(&g, try h.mainWindow(&g));
    const word = "html-copy-word";
    try h.typeText(surf, "echo " ++ word);
    h.enter(surf);
    try waitOutputSettled(h, &g, word);
    const at = try cellPoint(h, &g, word);

    const Way = enum { mixed, html, plain };
    for (std.enums.values(Way)) |way| {
        try h.setClipboard("stale");
        // Two clicks, as a real double click reaches a pane.
        h.click(surf, at.x, at.y, .left);
        h.click(surf, at.x, at.y, .left);
        h.sync(surf);
        switch (way) {
            .mixed => h.key(surf, .{ .ctrl = true, .shift = true }, 'C'),
            .html => h.key(surf, .{ .ctrl = true, .shift = true }, w.VK_F5),
            .plain => h.key(surf, .{ .ctrl = true, .shift = true }, w.VK_F6),
        }
        h.sync(surf);
        const text = try h.getClipboard();
        defer if (text) |t| h.alloc.free(t);
        const html = try h.getClipboardFormat(w.L("HTML Format"));
        defer if (html) |x| h.alloc.free(x);
        switch (way) {
            .mixed, .plain => try h.expect(text != null and std.mem.eql(u8, text.?, word), "{s}: the text is the word ('{s}')", .{ @tagName(way), text orelse "(none)" }),
            .html => try h.expect(!h.clipboardHasText(), "html: no text", .{}),
        }
        if (way == .plain) {
            try h.expect(html == null, "plain: no HTML", .{});
            continue;
        }
        const data = html orelse return h.fail("{s}: no HTML Format on the clipboard", .{@tagName(way)});
        try h.expect(std.mem.startsWith(u8, data, "Version:0.9\r\n"), "{s}: the HTML starts with CF_HTML's header", .{@tagName(way)});
        const start_html = cfHtmlField(data, "StartHTML") orelse return h.fail("no StartHTML", .{});
        const end_html = cfHtmlField(data, "EndHTML") orelse return h.fail("no EndHTML", .{});
        const start_fragment = cfHtmlField(data, "StartFragment") orelse return h.fail("no StartFragment", .{});
        const end_fragment = cfHtmlField(data, "EndFragment") orelse return h.fail("no EndFragment", .{});
        const fits = start_html < start_fragment and start_fragment <= end_fragment and end_fragment <= end_html and end_html == data.len;
        try h.expect(fits, "{s}: the offsets lie in order within the data ({d} {d} {d} {d}, {d} bytes)", .{ @tagName(way), start_html, start_fragment, end_fragment, end_html, data.len });
        if (!fits) continue;
        const fragment = data[start_fragment..end_fragment];
        try h.expect(std.mem.startsWith(u8, data[start_html..], "<html>") and std.mem.endsWith(u8, data[0..start_fragment], "<!--StartFragment-->") and std.mem.startsWith(u8, data[end_fragment..], "<!--EndFragment-->"), "{s}: StartHTML finds the document, the fragment's offsets its comments", .{@tagName(way)});
        try h.expect(std.mem.startsWith(u8, fragment, "<") and std.mem.indexOf(u8, fragment, word) != null, "{s}: the fragment is the core's HTML for the word ('{s}')", .{ @tagName(way), fragment });
    }
    try quit(h, &g, surf);
}

/// The value of header field `name` in CF_HTML `data`.
fn cfHtmlField(data: []const u8, name: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, data, "\r\n");
    while (lines.next()) |line| {
        if (line.len > name.len and std.mem.startsWith(u8, line, name) and line[name.len] == ':')
            return std.fmt.parseInt(usize, line[name.len + 1 ..], 10) catch null;
    }
    return null;
}

/// Roadmap 6.5: show_on_screen_keyboard gets Windows' input pane for the
/// pane's window (IInputPaneInterop, then IInputPane2); with the test
/// hooks on it stops short of showing the keyboard (osk-shown shows it).
fn onScreenKeyboard(h: *Harness) anyerror!void {
    var g = try start(h, "on-screen-keyboard", "keybind = ctrl+shift+f7=show_on_screen_keyboard\n", ">");
    defer g.deinit();
    const surf = try h.surface(&g, try h.mainWindow(&g));
    h.key(surf, .{ .ctrl = true, .shift = true }, w.VK_F7);
    h.sync(surf);
    var d = try h.dump(&g);
    defer d.deinit();
    const osk = d.value.osk;
    try h.expect(osk.asks == 1 and osk.hr >= 0, "the binding got the window's input pane (asks {d}, hr 0x{x})", .{ osk.asks, @as(u32, @bitCast(osk.hr)) });
    try quit(h, &g, surf);
}

/// Roadmap 6.5: show_on_screen_keyboard really asks Windows (TryShow),
/// then the hooks hide it (TryHide). Windows may decline to show it (with
/// a keyboard attached, by default); the calls must still succeed.
fn oskShown(h: *Harness) anyerror!void {
    if (w.GetEnvironmentVariableW(w.L("GHOSTTY_GUI_ONSCREEN"), null, 0) == 0) {
        return h.skip("it may show the touch keyboard on the screen; set GHOSTTY_GUI_ONSCREEN=1 to run it", .{});
    }
    const Ctx = struct { h: *Harness, err: ?anyerror = null };
    var ctx: Ctx = .{ .h = h };
    h.runOnUserDesktop(&ctx, struct {
        fn run(cx: *Ctx) void {
            oskShownOffscreen(cx.h) catch |err| {
                cx.err = err;
            };
        }
    }.run);
    if (ctx.err) |err| return err;
}

fn oskShownOffscreen(h: *Harness) !void {
    var g = try h.launchWith("osk-shown", base_config ++ "keybind = ctrl+shift+f7=show_on_screen_keyboard\n", .{
        .where = .offscreen,
        .env = &.{.{ "GHOSTTY_WIN32_TEST_OSK", "1" }},
    });
    defer g.deinit();
    try h.waitText(&g, ">", 1, 20000);
    const surf = try h.surface(&g, try h.mainWindow(&g));
    h.key(surf, .{ .ctrl = true, .shift = true }, w.VK_F7);
    h.sync(surf);
    {
        var d = try h.dump(&g);
        defer d.deinit();
        const osk = d.value.osk;
        try h.expect(osk.asks == 1 and osk.hr >= 0, "TryShow succeeded (hr 0x{x}; Windows showed it: {})", .{ @as(u32, @bitCast(osk.hr)), osk.done });
    }
    try h.hideOnScreenKeyboard(&g);
    var d = try h.dump(&g);
    defer d.deinit();
    const osk = d.value.osk;
    try h.expect(osk.asks == 2 and osk.hr >= 0, "and TryHide (hr 0x{x})", .{@as(u32, @bitCast(osk.hr))});
    // deinit ends it: no dialog on the user's desktop.
}

/// Roadmap 7.5: Sentry's in-process backend on Windows. An access violation
/// on the UI thread and a Zig panic each leave a crash report in murrtty's
/// crash folder (under XDG_STATE_HOME, the scenario's own here, with
/// Sentry's database under XDG_CACHE_HOME), naming what happened and where,
/// and +crash-report lists them. A report Sentry keeps for the next start
/// counts once a murrtty started after it has sent it. The report's frames
/// are addresses; names come from murrtty's PDB (Harness.symbolizeReport),
/// as for a release's symbols zip.
fn crashReport(h: *Harness) anyerror!void {
    const dir = try std.fmt.allocPrint(h.alloc, "{s}\\crash-report", .{h.temp_dir});
    defer h.alloc.free(dir);
    const state = try std.fmt.allocPrint(h.alloc, "{s}\\state", .{dir});
    defer h.alloc.free(state);
    const cache = try std.fmt.allocPrint(h.alloc, "{s}\\cache", .{dir});
    defer h.alloc.free(cache);
    const reports = try std.fmt.allocPrint(h.alloc, "{s}\\murrtty\\crash", .{state});
    defer h.alloc.free(reports);
    const env: []const [2][]const u8 = &.{ .{ "XDG_STATE_HOME", state }, .{ "XDG_CACHE_HOME", cache } };

    const kinds = [_]struct { name: []const u8, next: []const u8, panic: bool, code: u32, says: []const u8 }{
        .{ .name = "crash-report-av", .next = "crash-report-av-next", .panic = false, .code = 0xC0000005, .says = "AccessViolation" },
        .{ .name = "crash-report-panic", .next = "crash-report-panic-next", .panic = true, .code = 3, .says = "murrtty test panic" },
    };
    var before: usize = 0;
    for (kinds) |k| {
        {
            var g = try h.launchWith(k.name, base_config ++ "window-save-state = never\n", .{ .env = env });
            defer g.deinit();
            try h.waitText(&g, ">", 1, 20000);
            // Sentry starts on a thread of its own: wait until it has.
            try waitSentry(h, &g, 10000);
            try h.crash(&g, if (k.panic) .panic else .access_violation);
            const code = g.waitExit(15000) orelse return h.fail("{s}: murrtty didn't end", .{k.name});
            try h.expect(code == k.code, "{s}: murrtty ended with 0x{x} (0x{x} expected)", .{ k.name, code, k.code });
        }
        var found = try findReports(h, reports);
        if (found.count == before) {
            // Kept for the next start: start one, and let it send it.
            var g = try h.launchWith(k.next, base_config ++ "window-save-state = never\n", .{ .env = env });
            defer g.deinit();
            try h.waitText(&g, ">", 1, 20000);
            var waited: u32 = 0;
            while (waited < 10000 and found.count == before) : (waited += 200) {
                w.Sleep(200);
                found = try findReports(h, reports);
            }
            h.log("{s}: the report came with the next start", .{k.name});
        }
        try h.expect(found.count == before + 1, "{s}: one more crash report ({d} now)", .{ k.name, found.count });
        const newest = found.newest orelse return h.fail("{s}: no crash report in {s}", .{ k.name, reports });
        const path = try std.fmt.allocPrint(h.alloc, "{s}\\{s}", .{ reports, std.mem.sliceTo(&newest, 0) });
        defer h.alloc.free(path);
        const text = h.readFileOrNull(path) orelse return h.fail("{s}: couldn't read {s}", .{ k.name, path });
        defer h.alloc.free(text);
        try h.expect(std.mem.indexOf(u8, text, k.says) != null, "{s}: the report says what happened ('{s}')", .{ k.name, k.says });
        var names = try h.symbolizeReport(text);
        defer {
            for (names.items) |n| h.alloc.free(n);
            names.deinit(h.alloc);
        }
        var named = false;
        for (names.items) |n| named = named or std.mem.indexOf(u8, n, "crashForTest") != null;
        try h.expect(named, "{s}: and its stack, read with murrtty's PDB, has the function that crashed (crashForTest; {d} frames in murrtty.exe named, the first '{s}')", .{ k.name, names.items.len, if (names.items.len > 0) names.items[0] else "" });
        before = found.count;
    }

    var r = try h.runCliWith("crash-report", &.{"+crash-report"}, env);
    defer r.deinit();
    const listed = std.mem.count(u8, r.out, ".ghosttycrash");
    try h.expect(r.code == 0 and listed == 2, "+crash-report lists the two reports (exit {d}, {d} listed)", .{ r.code, listed });
}

/// Wait until murrtty's Sentry has started (the dump's sentry_ready).
fn waitSentry(h: *Harness, g: *Harness.Ghostty, ms: u32) !void {
    var waited: u32 = 0;
    while (waited < ms) : (waited += 100) {
        var d = try h.dump(g);
        defer d.deinit();
        if (d.value.sentry_ready) return;
        w.Sleep(100);
    }
    return h.fail("Sentry never started", .{});
}

/// The crash reports (*.ghosttycrash) in `dir`: how many, and the newest's
/// name (UTF-8, NUL-terminated).
fn findReports(h: *Harness, dir: []const u8) !struct { count: usize, newest: ?[512:0]u8 } {
    const pattern = try std.fmt.allocPrint(h.alloc, "{s}\\*.ghosttycrash", .{dir});
    defer h.alloc.free(pattern);
    const p16 = try std.unicode.utf8ToUtf16LeAllocZ(h.alloc, pattern);
    defer h.alloc.free(p16);
    var data: w.WIN32_FIND_DATAW = undefined;
    const find = w.FindFirstFileW(p16, &data);
    if (find == w.INVALID_HANDLE_VALUE) return .{ .count = 0, .newest = null };
    defer _ = w.FindClose(find);
    var count: usize = 0;
    var newest: ?[512:0]u8 = null;
    var newest_time: u64 = 0;
    while (true) {
        count += 1;
        const t = (@as(u64, data.ftLastWriteTime.dwHighDateTime) << 32) | data.ftLastWriteTime.dwLowDateTime;
        if (newest == null or t >= newest_time) {
            var name: [512:0]u8 = @splat(0);
            const units = std.mem.sliceTo(&data.cFileName, 0);
            _ = try std.unicode.utf16LeToUtf8(&name, units);
            newest = name;
            newest_time = t;
        }
        if (w.FindNextFileW(find, &data) == 0) break;
    }
    return .{ .count = count, .newest = newest };
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

/// A font installed for the user from a folder of its own, whose name isn't
/// ASCII, is found and used (roadmap 6.1): DirectWrite lists it from the
/// registry (HKCU's Fonts key, where Windows records a font installed for
/// one user, with its full path), and FreeType opens the path, which needs
/// the process's ANSI code page to be UTF-8 (the manifest's
/// activeCodePage: FreeType opens files with CreateFileA). A font a user
/// installs goes under their %LOCALAPPDATA%, so with a user name like 山田
/// every one failed to open.
fn fontRegistered(h: *Harness) anyerror!void {
    const font = h.readFileOrNull("src\\font\\res\\KawkabMono-Regular.ttf") orelse
        return h.skip("no src\\font\\res\\KawkabMono-Regular.ttf (run from the repository)", .{});
    defer h.alloc.free(font);
    const dir = try std.fmt.allocPrint(h.alloc, "{s}\\\u{30D5}\u{30A9}\u{30F3}\u{30C8} 6.1", .{h.temp_dir});
    defer h.alloc.free(dir);
    try h.makeDirAt(dir);
    defer h.removeDirAt(dir);
    const path = try std.fmt.allocPrint(h.alloc, "{s}\\KawkabMono-Regular.ttf", .{dir});
    defer h.alloc.free(path);
    try h.writeFileAt(path, font);
    defer h.deleteFile(path);

    const key = "Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts";
    const value = "Kawkab Mono Regular (murrtty GUI test)";
    try h.setRegString(key, value, path);
    defer h.deleteRegValue(key, value);

    // DirectWrite may take a moment to list it (its font cache service):
    // a few launches, each checking its first discovery.
    var got: []u8 = &.{};
    defer h.alloc.free(got);
    for (0..3) |attempt| {
        if (attempt > 0) w.Sleep(2000);
        var name_buf: [32]u8 = undefined;
        var g = try start(h, try std.fmt.bufPrint(&name_buf, "font-registered-{d}", .{attempt}), "font-family = Kawkab Mono\n", ">");
        defer g.deinit();
        w.Sleep(1000);
        const log_path = try std.fmt.allocPrint(h.alloc, "{s}\\murrtty.log", .{g.dir});
        defer h.alloc.free(log_path);
        const log = h.readFileOrNull(log_path) orelse return h.fail("no log", .{});
        defer h.alloc.free(log);
        // The grid set logs the face found for a configured family; none
        // if the family wasn't found (or no face of it opened).
        const tag = "font regular:";
        h.alloc.free(got);
        got = if (std.mem.indexOf(u8, log, tag)) |at| line: {
            const rest = log[at + tag.len ..];
            break :line try h.alloc.dupe(u8, std.mem.trim(u8, rest[0 .. std.mem.indexOfAny(u8, rest, "\r\n") orelse rest.len], " "));
        } else try h.alloc.dupe(u8, "none (the family wasn't found)");
        try quit(h, &g, try h.surface(&g, try h.mainWindow(&g)));
        if (std.mem.startsWith(u8, got, "Kawkab Mono")) break;
    }
    try h.expect(std.mem.startsWith(u8, got, "Kawkab Mono"), "font regular: {s} (expected Kawkab Mono, from {s})", .{ got, path });
}

/// A GPU driver reset (roadmap 6.3): a robust context loses itself, and
/// the renderer releases what it made there and builds everything again
/// (shaders, the frames' targets and atlases) in a new context. Faked here
/// (dump wparam 19), since a real reset would reset the owner's GPU for
/// every program: the frame drawn after it must be the frame drawn before.
fn glReset(h: *Harness) anyerror!void {
    try glResetCase(h, "gl-reset", "cursor-style-blink = false\n");
    // With a background image, whose texture went with the lost context
    // and is read from its file again (an 8x8 PNG, all #C81E3C).
    const png = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x08\x00\x00\x00\x08\x08\x06\x00\x00\x00\xc4\x0f\xbe\x8b\x00\x00\x00\x12\x49\x44\x41\x54\x78\xda\x63\x38\x21\x67\xf3\x1f\x1f\x66\x18\x19\x0a\x00\x2d\xc2\x88\x41\xd8\xdb\xb3\x05\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";
    const path = try std.fmt.allocPrint(h.alloc, "{s}\\gl-reset-bg.png", .{h.temp_dir});
    defer h.alloc.free(path);
    try h.writeFileAt(path, png);
    defer h.deleteFile(path);
    const config = try std.fmt.allocPrint(h.alloc, "cursor-style-blink = false\nbackground-image = {s}\nbackground-image-fit = stretch\n", .{path});
    defer h.alloc.free(config);
    try glResetCase(h, "gl-reset-image", config);
}

fn glResetCase(h: *Harness, name: []const u8, extra: []const u8) !void {
    const image = std.mem.indexOf(u8, extra, "background-image") != null;
    var g = try start(h, name, extra, ">");
    defer g.deinit();
    const surf = try h.surface(&g, try h.mainWindow(&g));
    try h.typeText(surf, "echo murrtty-gl-reset");
    try h.waitText(&g, "murrtty-gl-reset", 1, 5000);
    w.Sleep(300);

    const before = blk: {
        var d = try h.dump(&g);
        defer d.deinit();
        const pane = (d.value.windows[0].tabs[0].panes orelse return h.fail("no panes", .{}))[0];
        try h.expect(pane.gl_robust, "{s}: the context reports driver resets (robust)", .{name});
        break :blk .{ pane.gl_contexts, pane.frames orelse 0 };
    };
    try h.saveFrames(&g);
    var first = try h.loadPicture(&g, "frame-0.bmp");
    defer first.deinit();
    // The image draws the background (near its middle, below the text).
    const mid = first.rgb(first.width / 2, first.height * 3 / 4);
    if (image) try h.expect(mid == 0xC81E3C, "{s}: the background image draws (#{x:0>6})", .{ name, mid });

    try h.fakeContextLoss(&g);
    var made = false;
    var frames: u32 = 0;
    for (0..50) |_| {
        var d = try h.dump(&g);
        defer d.deinit();
        const pane = (d.value.windows[0].tabs[0].panes orelse return h.fail("no panes", .{}))[0];
        frames = pane.frames orelse 0;
        if (pane.gl_contexts == before[0] + 1 and frames > before[1]) {
            made = true;
            break;
        }
        w.Sleep(100);
    }
    try h.expect(made, "{s}: a new context was made and drawn with ({d} frames)", .{ name, frames });

    try h.saveFrames(&g);
    var second = try h.loadPicture(&g, "frame-0.bmp");
    defer second.deinit();
    var differ: usize = 0;
    if (first.width == second.width and first.height == second.height) {
        for (first.pixels, second.pixels) |a, b| {
            if (a & 0xFFFFFF != b & 0xFFFFFF) differ += 1;
        }
    } else differ = std.math.maxInt(usize);
    try h.expect(differ == 0, "{s}: the frame after the reset is the frame before it ({d} pixels differ)", .{ name, differ });

    // And it goes on drawing what comes.
    try h.typeText(surf, " again");
    try h.waitText(&g, "murrtty-gl-reset again", 1, 5000);
}

/// Without OpenGL 4.3, murrtty's start says why and what to do (roadmap
/// 6.3), from what Windows says of the session, the display adapter and
/// its OpenGL. The failure is asked for (GHOSTTY_WIN32_TEST_WGL) and the
/// machines it isn't run on stood in for (GHOSTTY_WIN32_TEST_GL_DIAG).
fn glMissing(h: *Harness) anyerror!void {
    const cases = [_]struct { name: []const u8, fail: []const u8, diag: []const u8, body: []const u8 }{
        .{ .name = "gl-missing-remote", .fail = "extensions", .diag = "remote", .body = "This Remote Desktop session's display offers no OpenGL 4.3 (GDI Generic 1.1.0)." },
        .{ .name = "gl-missing-basic", .fail = "extensions", .diag = "basic", .body = "Windows is using its Microsoft Basic Display Adapter" },
        .{ .name = "gl-missing-generic", .fail = "extensions", .diag = "generic", .body = "The graphics driver offers no OpenGL; only Windows' fallback (GDI Generic 1.1.0) is there." },
        .{ .name = "gl-missing-old", .fail = "context", .diag = "old", .body = "The graphics driver offers OpenGL 3.3.0 Example 1.0 (Example GPU), and murrtty needs 4.3." },
        // This machine's own OpenGL is fine: no diagnosis, the error.
        .{ .name = "gl-missing-unknown", .fail = "context", .diag = "", .body = "murrtty couldn't set up OpenGL (ContextCreateFailed)." },
    };
    for (cases) |case| {
        var env: [2][2][]const u8 = .{ .{ "GHOSTTY_WIN32_TEST_WGL", case.fail }, .{ "GHOSTTY_WIN32_TEST_GL_DIAG", case.diag } };
        var g = try h.launchWith(case.name, base_config, .{ .env = if (case.diag.len > 0) &env else env[0..1], .wait_window = false });
        defer g.deinit();
        try h.waitAnswering(&g, 10000);
        const dlg = try h.waitDialog(&g, 10000);
        {
            var d = try h.dump(&g);
            defer d.deinit();
            const dl = d.value.dialog;
            try h.expect(std.mem.eql(u8, dl.heading, "murrtty can't draw: it needs OpenGL 4.3") and std.mem.startsWith(u8, dl.body, case.body), "{s}: the dialog says '{s}' / '{s}'", .{ case.name, dl.heading, dl.body });
        }
        h.answer(&g, dlg, w.IDCLOSE);
        const code = g.waitExit(10000);
        try h.expect(code != null and code.? != 0, "{s}: murrtty then exits with an error (exit {?d})", .{ case.name, code });
    }
}

/// MURRTTY_OPENGL names the opengl32.dll to load by full path, for a
/// software OpenGL (roadmap 6.3): Windows' own named so draws as without
/// it; one that can't load, or a path that isn't a full one, is said so
/// at start.
fn glLibrary(h: *Harness) anyerror!void {
    {
        var g = try h.launchWith("gl-library-system", base_config, .{ .env = &.{.{ "MURRTTY_OPENGL", "C:\\Windows\\System32\\opengl32.dll" }} });
        defer g.deinit();
        try h.waitText(&g, ">", 1, 20000);
        var drew = false;
        for (0..50) |_| {
            var d = try h.dump(&g);
            defer d.deinit();
            const pane = (d.value.windows[0].tabs[0].panes orelse return h.fail("no panes", .{}))[0];
            if ((pane.frames orelse 0) > 0) {
                drew = true;
                break;
            }
            w.Sleep(100);
        }
        try h.expect(drew, "with Windows' opengl32.dll named, murrtty draws", .{});
        try quit(h, &g, try h.surface(&g, try h.mainWindow(&g)));
    }
    const missing = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "gl-library-missing", .value = "C:\\murrtty-no-such-folder\\opengl32.dll" },
        .{ .name = "gl-library-relative", .value = "opengl32.dll" },
        // A DLL that loads, but that gdi32 wouldn't find by opengl32's name.
        .{ .name = "gl-library-name", .value = "C:\\Windows\\System32\\glu32.dll" },
    };
    for (missing) |case| {
        var g = try h.launchWith(case.name, base_config, .{ .env = &.{.{ "MURRTTY_OPENGL", case.value }}, .wait_window = false });
        defer g.deinit();
        try h.waitAnswering(&g, 10000);
        const dlg = try h.waitDialog(&g, 10000);
        {
            var d = try h.dump(&g);
            defer d.deinit();
            const want = try std.fmt.allocPrint(h.alloc, "The OpenGL that MURRTTY_OPENGL names couldn't be loaded: {s}", .{case.value});
            defer h.alloc.free(want);
            try h.expect(std.mem.startsWith(u8, d.value.dialog.body, want), "{s}: the dialog says '{s}'", .{ case.name, d.value.dialog.body });
        }
        h.answer(&g, dlg, w.IDCLOSE);
        const code = g.waitExit(10000);
        try h.expect(code != null and code.? != 0, "{s}: murrtty then exits with an error (exit {?d})", .{ case.name, code });
    }
}

/// UI Automation (roadmap 6.4): a screen reader reads the pane through the
/// Text pattern, from another process on the same desktop
/// (ghostty-gui-uia.exe, as Narrator or NVDA would): its name and control
/// type (Text), the document's and the visible text, the text before the
/// caret (the prompt), lines and words moved through, the caret's line on
/// screen, and text found case-insensitively and selected, which is then
/// the terminal's selection.
fn uiaScenario(h: *Harness) anyerror!void {
    var g = try start(h, "uia", "", ">");
    defer g.deinit();
    const surf = try h.surface(&g, try h.mainWindow(&g));
    try h.typeText(surf, "echo murrtty-uia one two");
    h.enter(surf);
    try h.waitText(&g, "murrtty-uia one two", 2, 5000);
    w.Sleep(300);

    const hwnd_text = try std.fmt.allocPrint(h.alloc, "{d}", .{@intFromPtr(surf)});
    defer h.alloc.free(hwnd_text);
    var r = try h.runHelper("ghostty-gui-uia.exe", "uia-client", &.{ hwnd_text, "name", "doc", "visible", "caret", "line:0", "word:0", "word:1", "rects", "find:ONE TWO", "selection" }, .default);
    defer r.deinit();
    const out = r.out;
    const line = struct {
        fn of(text: []const u8, prefix: []const u8) []const u8 {
            var it = std.mem.splitScalar(u8, text, '\n');
            while (it.next()) |l| if (std.mem.startsWith(u8, l, prefix)) return std.mem.trimEnd(u8, l[prefix.len..], "\r");
            return "";
        }
    }.of;
    try h.expect(std.mem.indexOf(u8, out, "error") == null, "the client's calls all succeed:\n{s}", .{out});
    try h.expect(std.mem.endsWith(u8, line(out, "name: "), "type 50020"), "a Text control ({s})", .{line(out, "name: ")});
    const doc = line(out, "doc: ");
    try h.expect(std.mem.indexOf(u8, doc, "echo murrtty-uia one two\\nmurrtty-uia one two\\n") != null, "the document holds the command and its output ({s})", .{doc});
    try h.expect(std.mem.indexOf(u8, line(out, "visible: "), "murrtty-uia one two") != null, "so does the visible range", .{});
    try h.expect(std.mem.endsWith(u8, line(out, "caret: "), ">"), "the caret stands after the prompt ({s})", .{line(out, "caret: ")});
    try h.expect(std.mem.startsWith(u8, line(out, "line:0: "), "0 Microsoft Windows"), "the first line is cmd's banner ({s})", .{line(out, "line:0: ")});
    try h.expect(std.mem.eql(u8, line(out, "word:0: "), "0 Microsoft "), "the first word, with its space ({s})", .{line(out, "word:0: ")});
    try h.expect(std.mem.eql(u8, line(out, "word:1: "), "1 Windows "), "the next word ({s})", .{line(out, "word:1: ")});
    var rects = std.mem.tokenizeScalar(u8, line(out, "rects: "), ' ');
    const count = std.fmt.parseInt(u32, rects.next() orelse "0", 10) catch 0;
    _ = rects.next();
    _ = rects.next();
    const width = std.fmt.parseInt(i32, rects.next() orelse "0", 10) catch 0;
    const height = std.fmt.parseInt(i32, rects.next() orelse "0", 10) catch 0;
    try h.expect(count == 1 and width > 0 and height > 0, "the caret's line has one rectangle on screen ({s})", .{line(out, "rects: ")});
    try h.expect(std.mem.eql(u8, line(out, "find: "), "one two"), "found case-insensitively ({s})", .{line(out, "find: ")});
    try h.expect(std.mem.eql(u8, line(out, "selection: "), "1 one two"), "and selected ({s})", .{line(out, "selection: ")});
    var d = try h.dump(&g);
    defer d.deinit();
    const pane = (d.value.windows[0].tabs[0].panes orelse return h.fail("no panes", .{}))[0];
    try h.expect(pane.selection orelse false, "the terminal's selection holds it", .{});

    // A client listening as a screen reader does: a typed character
    // changes the text and moves the caret, and a selection made through
    // UI Automation says so. (Typing clears the selection: after it.)
    var events = try h.runHelper("ghostty-gui-uia.exe", "uia-events", &.{ hwnd_text, "events" }, .default);
    defer events.deinit();
    var ev = std.mem.tokenizeScalar(u8, line(events.out, "events: "), ' ');
    var counts: [3]u32 = .{ 0, 0, 0 };
    var k: usize = 0;
    while (ev.next()) |tok| {
        const n = std.fmt.parseInt(u32, tok, 10) catch continue;
        if (k < counts.len) counts[k] = n;
        k += 1;
    }
    try h.expect(counts[0] > 0 and counts[1] > 0 and counts[2] > 0, "a listening client hears the text change, the caret move and a selection ({s})", .{line(events.out, "events: ")});
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

/// Wait until the configuration editor's state passes `ctx.ok`, or fail
/// saying `what` and its status line.
fn waitEditor(h: *Harness, g: *Harness.Ghostty, ctx: anytype, comptime what: []const u8) !void {
    var waited: u32 = 0;
    while (waited <= 5000) : (waited += 100) {
        var d = try h.dump(g);
        defer d.deinit();
        if (d.value.config_editor) |e| if (ctx.ok(e)) return;
        w.Sleep(100);
    }
    var d = try h.dump(g);
    defer d.deinit();
    const status = if (d.value.config_editor) |e| e.status else "(closed)";
    return h.fail("config editor: " ++ what ++ " (status '{s}')", .{status});
}

/// The configuration editor's state now, copied out of the dump: its
/// windows and one row.
const EditorNow = struct { list: w.HWND, search: w.HWND, hwnd: w.HWND, row: ?Harness.Dump.Editor.Row = null };

fn editorNow(h: *Harness, g: *Harness.Ghostty, name: []const u8) !EditorNow {
    var d = try h.dump(g);
    defer d.deinit();
    const e = d.value.config_editor orelse return h.fail("the config editor isn't open", .{});
    return .{ .list = hwndOf(e.list), .search = hwndOf(e.search), .hwnd = hwndOf(e.hwnd), .row = e.find(name) };
}

/// Show only `name`'s rows (Escape empties the search first), then click
/// the control of `name`'s row.
fn editorClick(h: *Harness, g: *Harness.Ghostty, name: []const u8, part: enum { control, reset, picker }) !void {
    const now = try editorNow(h, g, name);
    h.key(now.search, .{}, w.VK_ESCAPE);
    try h.typeText(now.search, name);
    try waitEditor(h, g, struct {
        name: []const u8,
        fn ok(self: @This(), e: Harness.Dump.Editor) bool {
            return std.mem.eql(u8, e.query, self.name) and e.find(self.name) != null;
        }
    }{ .name = name }, "the search shows the row");
    const row = (try editorNow(h, g, name)).row.?;
    const r = switch (part) {
        .control => row.control,
        .reset => row.reset,
        .picker => row.picker orelse return h.fail("{s} has no picker", .{name}),
    };
    // Clear of a value the field takes over.
    w.Sleep(50);
    h.click(now.list, @divTrunc(r[0] + r[2], 2), @divTrunc(r[1] + r[3], 2), .left);
}

fn rowValue(name: []const u8, value: []const u8) struct {
    name: []const u8,
    value: []const u8,
    fn ok(self: @This(), e: Harness.Dump.Editor) bool {
        const r = e.find(self.name) orelse return false;
        return std.mem.eql(u8, r.value, self.value);
    }
} {
    return .{ .name = name, .value = value };
}

/// Roadmap F1: the configuration editor, murrtty's own. It opens from the
/// terminal's menu (Config, Open Configuration Editor) and the command
/// palette, lists every option with its value and whether a file sets it,
/// and searches them. A number is typed, a switch flipped, a choice picked
/// from its menu, a value the loader refuses kept out with its message, a
/// value only murrtty takes pointed out, and a reset takes an option out.
/// Saving rewrites only the lines changed, keeping the rest of the file
/// byte for byte, and reloads (window-theme reaches the window). Closing
/// with changes unsaved asks; a save with none writes nothing. A
/// configuration that is only Ghostty's is edited in place, with no file
/// of murrtty's made.
fn configEditor(h: *Harness) anyerror!void {
    const extra = "# kept as it is\nfont-size = 13\nfont-family = \"\"\nfont-family = Consolas\nshell-integration-features = no-cursor\nwindow-theme = dark\n";
    var g = try start(h, "config-editor", extra, ">");
    defer g.deinit();
    const path = try std.fmt.allocPrint(h.alloc, "{s}\\murrtty\\config.ghostty", .{g.dir});
    defer h.alloc.free(path);
    const original = h.readFileOrNull(path) orelse return h.fail("no configuration file at {s}", .{path});
    defer h.alloc.free(original);
    const win = try h.mainWindow(&g);
    const surf = try h.surface(&g, win);

    // From the terminal's menu: Config, then Open Configuration Editor.
    h.rightPress(surf, 100, 100);
    const menu = try h.waitMenu(&g, 1, 5000);
    h.menuKey(menu, 'o');
    const sub = try h.waitMenu(&g, 2, 5000);
    {
        const items = try h.menuItems(sub);
        defer h.freeMenuItems(items);
        try h.expect(items.len == 4 and std.mem.eql(u8, items[0].text, "Open Configuration &Editor"), "the Config submenu starts with Open Configuration Editor ({d} items)", .{items.len});
    }
    h.menuKey(sub, 'e');
    try waitEditor(h, &g, struct {
        fn ok(_: @This(), e: Harness.Dump.Editor) bool {
            return e.rows.len > 200;
        }
    }{}, "it opens with every option");
    {
        var d = try h.dump(&g);
        defer d.deinit();
        const e = d.value.config_editor.?;
        try h.expect(std.ascii.eqlIgnoreCase(e.path, path), "it edits murrtty's file ({s})", .{e.path});
        try h.expect(!e.dirty, "nothing changed yet", .{});
        const size = e.find("font-size") orelse return h.fail("no font-size row", .{});
        try h.expect(std.mem.eql(u8, size.value, "13") and size.set and size.source == 0, "font-size shows the file's 13 (got '{s}', set {})", .{ size.value, size.set });
        const style = e.find("cursor-style") orelse return h.fail("no cursor-style row", .{});
        try h.expect(!style.set and style.value.len > 0, "cursor-style, unset, shows its default ('{s}')", .{style.value});
    }

    // A list's field opened and taken as it is changes nothing: its reset
    // line (`font-family = ""`, shown as "") stays.
    try editorClick(h, &g, "font-family", .control);
    try waitEditor(h, &g, struct {
        fn ok(_: @This(), e: Harness.Dump.Editor) bool {
            return e.edit != 0 and std.mem.eql(u8, e.editing, "font-family");
        }
    }{}, "the list's field");
    {
        var d = try h.dump(&g);
        defer d.deinit();
        h.key(hwndOf(d.value.config_editor.?.edit), .{ .ctrl = true }, w.VK_RETURN);
    }
    try waitEditor(h, &g, struct {
        fn ok(_: @This(), e: Harness.Dump.Editor) bool {
            return e.edit == 0;
        }
    }{}, "Ctrl+Enter takes it");
    {
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(!d.value.config_editor.?.dirty, "a list taken unchanged, its reset line included, changes nothing", .{});
    }

    // A number, typed and taken; then one the loader refuses.
    try editorClick(h, &g, "font-size", .control);
    try waitEditor(h, &g, struct {
        fn ok(_: @This(), e: Harness.Dump.Editor) bool {
            return e.edit != 0 and std.mem.eql(u8, e.editing, "font-size");
        }
    }{}, "a click on the value puts a field over it");
    var now = try editorNow(h, &g, "font-size");
    {
        var d = try h.dump(&g);
        defer d.deinit();
        const edit_hwnd = hwndOf(d.value.config_editor.?.edit);
        try h.typeText(edit_hwnd, "15");
        h.key(edit_hwnd, .{}, w.VK_RETURN);
    }
    try waitEditor(h, &g, rowValue("font-size", "15"), "Enter takes 15");
    try editorClick(h, &g, "font-size", .control);
    try waitEditor(h, &g, struct {
        fn ok(_: @This(), e: Harness.Dump.Editor) bool {
            return e.edit != 0;
        }
    }{}, "the field again");
    {
        var d = try h.dump(&g);
        defer d.deinit();
        const edit_hwnd = hwndOf(d.value.config_editor.?.edit);
        try h.typeText(edit_hwnd, "big");
        h.key(edit_hwnd, .{}, w.VK_RETURN);
    }
    try waitEditor(h, &g, struct {
        fn ok(_: @This(), e: Harness.Dump.Editor) bool {
            const r = e.find("font-size") orelse return false;
            return e.status_error and std.mem.indexOf(u8, e.status, "font-size") != null and std.mem.eql(u8, r.value, "15");
        }
    }{}, "'big' is refused with the loader's message, 15 kept");

    // A switch, then its reset.
    try editorClick(h, &g, "focus-follows-mouse", .control);
    try waitEditor(h, &g, rowValue("focus-follows-mouse", "true"), "a click on the switch turns it on");
    try editorClick(h, &g, "focus-follows-mouse", .reset);
    try waitEditor(h, &g, struct {
        fn ok(_: @This(), e: Harness.Dump.Editor) bool {
            const r = e.find("focus-follows-mouse") orelse return false;
            return !r.set;
        }
    }{}, "reset takes it out of the file");

    // A choice from its menu.
    try editorClick(h, &g, "window-theme", .control);
    {
        const choices = try h.waitMenu(&g, 1, 5000);
        const items = try h.menuItems(choices);
        defer h.freeMenuItems(items);
        var light: ?usize = null;
        var checked: []const u8 = "";
        for (items, 0..) |it, i| {
            if (std.mem.eql(u8, it.text, "light")) light = i;
            if (it.checked) checked = it.text;
        }
        try h.expect(light != null and std.mem.eql(u8, checked, "dark"), "the menu lists the choices, dark checked (checked '{s}')", .{checked});
        h.menuChoose(choices, light.?);
    }
    try waitEditor(h, &g, rowValue("window-theme", "light"), "light chosen");

    // A value only murrtty takes is pointed out (Ghostty would report it).
    try editorClick(h, &g, "shell-integration", .control);
    {
        const choices = try h.waitMenu(&g, 1, 5000);
        const items = try h.menuItems(choices);
        defer h.freeMenuItems(items);
        const ps = for (items, 0..) |it, i| {
            if (std.mem.eql(u8, it.text, "powershell")) break i;
        } else return h.fail("no powershell in shell-integration's menu", .{});
        h.menuChoose(choices, ps);
    }
    try waitEditor(h, &g, struct {
        fn ok(_: @This(), e: Harness.Dump.Editor) bool {
            const r = e.find("shell-integration") orelse return false;
            return std.mem.startsWith(u8, r.subtitle, "Only murrtty");
        }
    }{}, "shell-integration = powershell is pointed out as murrtty's own");
    // Back to the file's own none (a reset would take the line out, to the
    // default): the line as it was.
    try editorClick(h, &g, "shell-integration", .control);
    {
        const choices = try h.waitMenu(&g, 1, 5000);
        const items = try h.menuItems(choices);
        defer h.freeMenuItems(items);
        const none = for (items, 0..) |it, i| {
            if (std.mem.eql(u8, it.text, "none")) break i;
        } else return h.fail("no none in shell-integration's menu", .{});
        h.menuChoose(choices, none);
    }
    try waitEditor(h, &g, rowValue("shell-integration", "none"), "and none again");

    // A list: its field holds the file's line; a second value goes in
    // beneath it, Ctrl+Enter takes both.
    try editorClick(h, &g, "font-family", .control);
    try waitEditor(h, &g, struct {
        fn ok(_: @This(), e: Harness.Dump.Editor) bool {
            return e.edit != 0 and std.mem.eql(u8, e.editing, "font-family");
        }
    }{}, "a list's field opens");
    {
        var d = try h.dump(&g);
        defer d.deinit();
        const edit_hwnd = hwndOf(d.value.config_editor.?.edit);
        h.key(edit_hwnd, .{ .ctrl = true }, w.VK_END);
        try h.typeText(edit_hwnd, "Cascadia Mono");
        h.key(edit_hwnd, .{ .ctrl = true }, w.VK_RETURN);
    }
    try waitEditor(h, &g, rowValue("font-family", "3 entries"), "Ctrl+Enter takes the lines");

    // Flags: the menu shows what the loader makes of the file's no-cursor
    // (the others at their type's defaults: title on, sudo off), drawn with
    // its labels (owner-drawn: the editor measures its items), and a choice
    // writes only what differs from the defaults.
    try editorClick(h, &g, "shell-integration-features", .control);
    {
        const flags = try h.waitMenu(&g, 1, 5000);
        var r: w.RECT = .{};
        _ = w.GetWindowRect(flags, &r);
        try h.expect(r.right - r.left > 60, "the flags' menu is drawn with its labels ({d} px wide)", .{r.right - r.left});
        const items = try h.menuItems(flags);
        defer h.freeMenuItems(items);
        var cursor: ?bool = null;
        var title: ?bool = null;
        var sudo: ?usize = null;
        var sudo_on = true;
        for (items, 0..) |it, i| {
            if (std.mem.eql(u8, it.text, "cursor")) cursor = it.checked;
            if (std.mem.eql(u8, it.text, "title")) title = it.checked;
            if (std.mem.eql(u8, it.text, "sudo")) {
                sudo = i;
                sudo_on = it.checked;
            }
        }
        try h.expect(cursor == false and title == true and sudo != null and !sudo_on, "no-cursor reads as cursor off, title on, sudo off", .{});
        h.menuChoose(flags, sudo.?);
    }
    try waitEditor(h, &g, rowValue("shell-integration-features", "no-cursor,sudo"), "sudo on writes no-cursor,sudo");
    {
        // The menu opens again for another flag; Escape closes it.
        const again = try h.waitMenu(&g, 1, 5000);
        _ = w.PostMessageW(again, w.WM_KEYDOWN, w.VK_ESCAPE, 1);
        var gone: u32 = 0;
        while (gone <= 3000 and try h.menuCount(&g) > 0) : (gone += 100) w.Sleep(100);
        try h.expect(try h.menuCount(&g) == 0, "Escape closes the flags' menu", .{});
    }

    // Saved: only the changed lines, then the reload reaches the window.
    {
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect((d.value.windows[0].chrome orelse return h.fail("no chrome in the dump", .{})).dark, "the window is dark before the save", .{});
    }
    now = try editorNow(h, &g, "font-size");
    h.key(now.list, .{ .ctrl = true }, 'S');
    try waitEditor(h, &g, struct {
        fn ok(_: @This(), e: Harness.Dump.Editor) bool {
            return !e.dirty and std.mem.startsWith(u8, e.status, "Saved");
        }
    }{}, "Ctrl+S saves");
    const step1 = try std.mem.replaceOwned(u8, h.alloc, original, "font-size = 13\n", "font-size = 15\n");
    defer h.alloc.free(step1);
    const step2 = try std.mem.replaceOwned(u8, h.alloc, step1, "window-theme = dark\n", "window-theme = light\n");
    defer h.alloc.free(step2);
    const step3 = try std.mem.replaceOwned(u8, h.alloc, step2, "font-family = Consolas\n", "font-family = Consolas\nfont-family = Cascadia Mono\n");
    defer h.alloc.free(step3);
    const want = try std.mem.replaceOwned(u8, h.alloc, step3, "shell-integration-features = no-cursor\n", "shell-integration-features = no-cursor,sudo\n");
    defer h.alloc.free(want);
    {
        const saved = h.readFileOrNull(path) orelse return h.fail("the file is gone", .{});
        defer h.alloc.free(saved);
        try h.expect(std.mem.eql(u8, saved, want), "the file changes on its edited lines and gains the list's new one beside the old, the comment, the reset line and the rest as they were", .{});
    }
    var waited: u32 = 0;
    while (waited <= 5000) : (waited += 100) {
        var d = try h.dump(&g);
        defer d.deinit();
        if (!(d.value.windows[0].chrome orelse return h.fail("no chrome in the dump", .{})).dark) break;
        w.Sleep(100);
    }
    {
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(!(d.value.windows[0].chrome orelse return h.fail("no chrome in the dump", .{})).dark, "the reload makes the window light", .{});
    }

    // Unsaved changes ask: Cancel keeps the editor, Discard closes it.
    try editorClick(h, &g, "font-size", .control);
    try waitEditor(h, &g, struct {
        fn ok(_: @This(), e: Harness.Dump.Editor) bool {
            return e.edit != 0;
        }
    }{}, "the field for 16");
    {
        var d = try h.dump(&g);
        defer d.deinit();
        const edit_hwnd = hwndOf(d.value.config_editor.?.edit);
        try h.typeText(edit_hwnd, "16");
        h.key(edit_hwnd, .{}, w.VK_RETURN);
    }
    try waitEditor(h, &g, rowValue("font-size", "16"), "16 taken");
    now = try editorNow(h, &g, "font-size");
    _ = w.PostMessageW(now.hwnd, w.WM_CLOSE, 0, 0);
    var dlg = try h.waitDialog(&g, 5000);
    h.answer(&g, dlg, w.IDCANCEL);
    waited = 0;
    while (waited <= 3000 and try h.dialogCount(&g) > 0) : (waited += 100) w.Sleep(100);
    {
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(d.value.config_editor != null, "Cancel keeps the editor open", .{});
    }
    _ = w.PostMessageW(now.hwnd, w.WM_CLOSE, 0, 0);
    dlg = try h.waitDialog(&g, 5000);
    h.answer(&g, dlg, 201);
    waited = 0;
    while (waited <= 5000) : (waited += 100) {
        var d = try h.dump(&g);
        defer d.deinit();
        if (d.value.config_editor == null) break;
        w.Sleep(100);
    }
    {
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(d.value.config_editor == null, "Discard closes it", .{});
        const saved = h.readFileOrNull(path) orelse return h.fail("the file is gone", .{});
        defer h.alloc.free(saved);
        try h.expect(std.mem.eql(u8, saved, want), "and the file keeps what was saved", .{});
    }

    // From the palette; a save with nothing changed writes nothing.
    h.key(surf, .{ .ctrl = true, .shift = true }, 'P');
    const palette = hwndOf((try waitPalette(h, &g, win, true)).edit);
    try h.typeText(palette, "Configuration Editor");
    const st = try waitPaletteText(h, &g, win, "Configuration Editor");
    try h.expect(std.mem.startsWith(u8, st.titles[0..st.titles_len], "Open Configuration Editor\n"), "the palette lists Open Configuration Editor", .{});
    h.key(palette, .{}, w.VK_RETURN);
    try waitEditor(h, &g, struct {
        fn ok(_: @This(), e: Harness.Dump.Editor) bool {
            return e.rows.len > 200;
        }
    }{}, "the palette opens it");
    now = try editorNow(h, &g, "font-size");

    // One dialog at a time: a terminal's dialog disables the editor until
    // it closes.
    h.key(surf, .{ .ctrl = true, .shift = true }, 'W');
    const close_dlg = try h.waitDialog(&g, 5000);
    try h.expect(w.IsWindowEnabled(now.hwnd) == 0, "a terminal's dialog disables the editor", .{});
    h.answer(&g, close_dlg, w.IDCANCEL);
    waited = 0;
    while (waited <= 3000 and try h.dialogCount(&g) > 0) : (waited += 100) w.Sleep(100);
    try h.expect(w.IsWindowEnabled(now.hwnd) != 0, "and enables it again once it closes", .{});
    h.key(now.list, .{ .ctrl = true }, 'S');
    try waitEditor(h, &g, struct {
        fn ok(_: @This(), e: Harness.Dump.Editor) bool {
            return std.mem.eql(u8, e.status, "No changes to save");
        }
    }{}, "a save with nothing changed says so");
    {
        const saved = h.readFileOrNull(path) orelse return h.fail("the file is gone", .{});
        defer h.alloc.free(saved);
        try h.expect(std.mem.eql(u8, saved, want), "and writes nothing", .{});
    }
    // Unchanged, it closes without asking.
    _ = w.PostMessageW(now.hwnd, w.WM_CLOSE, 0, 0);
    waited = 0;
    while (waited <= 5000) : (waited += 100) {
        var d = try h.dump(&g);
        defer d.deinit();
        if (d.value.config_editor == null) break;
        w.Sleep(100);
    }
    try h.expect(try h.dialogCount(&g) == 0, "an unchanged editor closes without asking", .{});

    // A configuration that is only Ghostty's: edited in place, kept
    // Ghostty's, no file of murrtty's made.
    const ghostty_text = try std.mem.concat(h.alloc, u8, &.{ base_config, "font-size = 12\n" });
    defer h.alloc.free(ghostty_text);
    var g2 = try h.launchWith("config-editor-ghostty", "", .{ .murrtty_config = false, .ghostty_config = ghostty_text });
    defer g2.deinit();
    try h.waitText(&g2, ">", 1, 20000);
    try h.openConfigEditor(&g2);
    try waitEditor(h, &g2, struct {
        fn ok(_: @This(), e: Harness.Dump.Editor) bool {
            return std.mem.endsWith(u8, e.path, "\\ghostty\\config.ghostty");
        }
    }{}, "it opens Ghostty's file when murrtty has none");
    try editorClick(h, &g2, "font-size", .control);
    try waitEditor(h, &g2, struct {
        fn ok(_: @This(), e: Harness.Dump.Editor) bool {
            return e.edit != 0;
        }
    }{}, "the field");
    {
        var d = try h.dump(&g2);
        defer d.deinit();
        const edit_hwnd = hwndOf(d.value.config_editor.?.edit);
        try h.typeText(edit_hwnd, "14");
        h.key(edit_hwnd, .{}, w.VK_RETURN);
    }
    try waitEditor(h, &g2, rowValue("font-size", "14"), "14 taken");
    now = try editorNow(h, &g2, "font-size");
    h.key(now.list, .{ .ctrl = true }, 'S');
    try waitEditor(h, &g2, struct {
        fn ok(_: @This(), e: Harness.Dump.Editor) bool {
            return !e.dirty;
        }
    }{}, "saved");
    const gpath = try std.fmt.allocPrint(h.alloc, "{s}\\ghostty\\config.ghostty", .{g2.dir});
    defer h.alloc.free(gpath);
    const gwant = try std.mem.concat(h.alloc, u8, &.{ base_config, "font-size = 14\n" });
    defer h.alloc.free(gwant);
    {
        const saved = h.readFileOrNull(gpath) orelse return h.fail("Ghostty's file is gone", .{});
        defer h.alloc.free(saved);
        try h.expect(std.mem.eql(u8, saved, gwant), "Ghostty's file changes on its font-size line only", .{});
    }
    const mpath = try std.fmt.allocPrint(h.alloc, "{s}\\murrtty\\config.ghostty", .{g2.dir});
    defer h.alloc.free(mpath);
    if (h.readFileOrNull(mpath)) |m| {
        h.alloc.free(m);
        return h.fail("a file of murrtty's was made", .{});
    }

    // An empty file of murrtty's beside Ghostty's: the loader reads
    // murrtty's alone (it exists), so that is the one the editor opens, as
    // Ctrl+, does, not Ghostty's, which has more in it.
    _ = w.PostMessageW(now.hwnd, w.WM_CLOSE, 0, 0);
    waited = 0;
    while (waited <= 5000) : (waited += 100) {
        var d = try h.dump(&g2);
        defer d.deinit();
        if (d.value.config_editor == null) break;
        w.Sleep(100);
    }
    const mdir = try std.fmt.allocPrint(h.alloc, "{s}\\murrtty", .{g2.dir});
    defer h.alloc.free(mdir);
    try h.makeDirAt(mdir);
    try h.writeFileAt(mpath, "");
    try h.openConfigEditor(&g2);
    try waitEditor(h, &g2, struct {
        fn ok(_: @This(), e: Harness.Dump.Editor) bool {
            return e.rows.len > 200;
        }
    }{}, "it opens again");
    {
        var d = try h.dump(&g2);
        defer d.deinit();
        const e = d.value.config_editor.?;
        try h.expect(std.ascii.eqlIgnoreCase(e.path, mpath), "beside an empty file of murrtty's, it opens that one ({s})", .{e.path});
        try h.expect(e.files.len == 1, "and only that one: Ghostty's isn't read ({d} files)", .{e.files.len});
    }
}

/// Set a chooser's search (Chooser.zig, F1c) and wait for its list to
/// settle; the rows it leaves.
fn chooserSearch(h: *Harness, dlg: w.HWND, text: []const u8) !usize {
    const entry = w.GetDlgItem(dlg, 100) orelse return h.fail("the chooser has no search entry", .{});
    const list = w.GetDlgItem(dlg, 101) orelse return h.fail("the chooser has no list", .{});
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(h.alloc, text);
    defer h.alloc.free(wide);
    var r: usize = 0;
    _ = w.SendMessageTimeoutW(entry, w.WM_SETTEXT, 0, @bitCast(@intFromPtr(wide.ptr)), w.SMTO_ABORTIFHUNG, 2000, &r);
    w.Sleep(150);
    _ = w.SendMessageTimeoutW(list, w.LB_GETCOUNT, 0, 0, w.SMTO_ABORTIFHUNG, 2000, &r);
    return r;
}

fn windowCaption(h: *Harness, hwnd: w.HWND) ![]u8 {
    var buf: [256]u16 = undefined;
    const n: usize = @intCast(@max(w.GetWindowTextW(hwnd, &buf, buf.len), 0));
    return std.unicode.utf16LeToUtf8Alloc(h.alloc, buf[0..n]);
}

/// Press `vk` with `mods` in the new key binding's capture box.
fn captureKeys(h: *Harness, g: *Harness.Ghostty, mods: Harness.Mods, vk: u8) !void {
    const dlg = try h.waitDialog(g, 5000);
    const caption = try windowCaption(h, dlg);
    defer h.alloc.free(caption);
    try h.expect(std.mem.eql(u8, caption, "New Key Binding"), "the capture dialog opens ('{s}')", .{caption});
    const box = w.GetDlgItem(dlg, 103) orelse return h.fail("the capture dialog has no box", .{});
    h.key(box, mods, vk);
}

/// Wait for the dialog whose heading holds `text` (the action chooser
/// naming the keys, the value's prompt), the one before it gone.
fn waitDialogNamed(h: *Harness, g: *Harness.Ghostty, text: []const u8) !w.HWND {
    var waited: u32 = 0;
    while (waited <= 5000) : (waited += 100) {
        const d = try h.dialogs(g);
        defer h.alloc.free(d);
        if (d.len == 1) {
            const caption = try windowCaption(h, d[0]);
            defer h.alloc.free(caption);
            if (std.mem.indexOf(u8, caption, text) != null) return d[0];
        }
        w.Sleep(100);
    }
    return h.fail("no dialog named '{s}' appeared", .{text});
}

/// Wait for a chooser's dialog to close after its answer.
fn chooserGone(h: *Harness, g: *Harness.Ghostty) !void {
    var waited: u32 = 0;
    while (waited <= 3000 and try h.dialogCount(g) > 0) : (waited += 100) w.Sleep(100);
    try h.expect(try h.dialogCount(g) == 0, "the chooser closes", .{});
}

/// Roadmap F1c: the configuration editor's pickers. A color's swatch and a
/// file's button open Windows' own dialogs, stood in for by
/// GHOSTTY_WIN32_TEST_PICK; the font and theme choosers are driven as a
/// user would: a search typed, a row selected, Select.
fn configEditorPages(h: *Harness) anyerror!void {
    const config = try std.mem.concat(h.alloc, u8, &.{ base_config, "font-family = Consolas\n" });
    defer h.alloc.free(config);
    var g = try h.launchWith("config-editor-pages", config, .{ .env = &.{.{ "GHOSTTY_WIN32_TEST_PICK", "#123456" }} });
    defer g.deinit();
    try h.waitText(&g, ">", 1, 20000);
    const path = try std.fmt.allocPrint(h.alloc, "{s}\\murrtty\\config.ghostty", .{g.dir});
    defer h.alloc.free(path);
    try h.openConfigEditor(&g);
    try waitEditor(h, &g, struct {
        fn ok(_: @This(), e: Harness.Dump.Editor) bool {
            return e.rows.len > 200;
        }
    }{}, "it opens");

    // A color's swatch: the color dialog's choice, as #rrggbb.
    try editorClick(h, &g, "background", .picker);
    try waitEditor(h, &g, rowValue("background", "#123456"), "the swatch's dialog sets background");

    // Fonts: only monospaced families, the search narrowing them, the one
    // chosen taking the first family's line.
    try editorClick(h, &g, "font-family", .picker);
    {
        const dlg = try h.waitDialog(&g, 5000);
        const caption = try windowCaption(h, dlg);
        defer h.alloc.free(caption);
        try h.expect(std.mem.eql(u8, caption, "Choose a Font"), "the font chooser opens ('{s}')", .{caption});
        const every = try chooserSearch(h, dlg, "");
        try h.expect(every > 1, "it lists the monospaced fonts ({d})", .{every});
        try snapshotDialog(h, dlg, "paint-font-chooser.bmp");
        try h.expect(try chooserSearch(h, dlg, "Arial") == 0, "and not Arial, which isn't one", .{});
        const found = try chooserSearch(h, dlg, "Cascadia Mono");
        if (found == 0) {
            h.answer(&g, dlg, w.IDCANCEL);
            try chooserGone(h, &g);
            return h.skip("Cascadia Mono isn't installed", .{});
        }
        const list = w.GetDlgItem(dlg, 101).?;
        var r: usize = 0;
        _ = w.SendMessageTimeoutW(list, w.LB_SETCURSEL, 0, 0, w.SMTO_ABORTIFHUNG, 2000, &r);
        h.answer(&g, dlg, w.IDOK);
        try chooserGone(h, &g);
    }

    // Themes: searched by name, with whether they are dark.
    try editorClick(h, &g, "theme", .picker);
    {
        const dlg = try h.waitDialog(&g, 5000);
        const caption = try windowCaption(h, dlg);
        defer h.alloc.free(caption);
        try h.expect(std.mem.eql(u8, caption, "Choose a Theme"), "the theme chooser opens ('{s}')", .{caption});
        try h.expect(try chooserSearch(h, dlg, "") > 100, "it lists the themes murrtty ships", .{});
        try snapshotDialog(h, dlg, "paint-theme-chooser.bmp");
        const dark = try chooserSearch(h, dlg, "Dark");
        try h.expect(dark > 10, "the search matches whether a theme is dark ({d})", .{dark});
        try h.expect(try chooserSearch(h, dlg, "Dracula") > 0, "Dracula is among them", .{});
        h.answer(&g, dlg, w.IDOK);
        try chooserGone(h, &g);
    }
    try waitEditor(h, &g, rowValue("theme", "Dracula"), "Select takes the first row, Dracula");

    // Key bindings: the keys pressed in the capture box, then the action
    // from a chooser whose heading says what they do now.
    try editorClick(h, &g, "keybind", .picker);
    try captureKeys(h, &g, .{ .ctrl = true, .shift = true }, 'T');
    {
        const dlg = try waitDialogNamed(h, &g, "ctrl+shift+t");
        const caption = try windowCaption(h, dlg);
        defer h.alloc.free(caption);
        try h.expect(std.mem.eql(u8, caption, "ctrl+shift+t: now new_tab"), "a bound key says what it does now ('{s}')", .{caption});
        h.answer(&g, dlg, w.IDCANCEL);
        try chooserGone(h, &g);
    }
    // Keys bound by their key, not their character (Windows' defaults bind
    // Alt+1 as alt+digit_1 beside alt+1): the new binding takes that form,
    // which is the one looked up first.
    try editorClick(h, &g, "keybind", .picker);
    try captureKeys(h, &g, .{ .alt = true }, '1');
    {
        const dlg = try waitDialogNamed(h, &g, "alt+digit_1");
        const caption = try windowCaption(h, dlg);
        defer h.alloc.free(caption);
        try h.expect(std.mem.eql(u8, caption, "alt+digit_1: now goto_tab:1"), "Alt+1 is written as its key, as bound ('{s}')", .{caption});
        h.answer(&g, dlg, w.IDCANCEL);
        try chooserGone(h, &g);
    }
    try editorClick(h, &g, "keybind", .picker);
    try captureKeys(h, &g, .{ .ctrl = true, .shift = true }, 'K');
    {
        const dlg = try waitDialogNamed(h, &g, "ctrl+shift+k");
        try h.expect(try chooserSearch(h, dlg, "new_window") > 0, "new_window is among the actions", .{});
        h.answer(&g, dlg, w.IDOK);
        try chooserGone(h, &g);
    }
    // An action that takes a value asks for it.
    try editorClick(h, &g, "keybind", .picker);
    try captureKeys(h, &g, .{ .ctrl = true, .shift = true }, 0x74); // F5
    {
        const dlg = try waitDialogNamed(h, &g, "ctrl+shift+f5");
        try h.expect(try chooserSearch(h, dlg, "goto_tab") > 0, "goto_tab is among the actions", .{});
        h.answer(&g, dlg, w.IDOK);
        const ask = try waitDialogNamed(h, &g, "Value for goto_tab");
        const entry = w.GetDlgItem(ask, 100) orelse return h.fail("the value's prompt has no entry", .{});
        var r: usize = 0;
        _ = w.SendMessageTimeoutW(entry, w.WM_SETTEXT, 0, @bitCast(@intFromPtr(w.L("2"))), w.SMTO_ABORTIFHUNG, 2000, &r);
        h.answer(&g, ask, w.IDOK);
        try chooserGone(h, &g);
    }
    // The same keys again: their line changes, none is added.
    try editorClick(h, &g, "keybind", .picker);
    try captureKeys(h, &g, .{ .ctrl = true, .shift = true }, 'K');
    {
        const dlg = try waitDialogNamed(h, &g, "ctrl+shift+k");
        try h.expect(try chooserSearch(h, dlg, "new_tab") > 0, "new_tab is among the actions", .{});
        h.answer(&g, dlg, w.IDOK);
        try chooserGone(h, &g);
    }

    // Saved: the lines, the font's in place of Consolas.
    const now = try editorNow(h, &g, "theme");
    h.key(now.list, .{ .ctrl = true }, 'S');
    try waitEditor(h, &g, struct {
        fn ok(_: @This(), e: Harness.Dump.Editor) bool {
            return !e.dirty;
        }
    }{}, "saved");
    {
        const saved = h.readFileOrNull(path) orelse return h.fail("the file is gone", .{});
        defer h.alloc.free(saved);
        try h.expect(std.mem.indexOf(u8, saved, "font-family = Cascadia Mono\n") != null and std.mem.indexOf(u8, saved, "Consolas") == null, "the chosen font takes Consolas's line", .{});
        try h.expect(std.mem.indexOf(u8, saved, "background = #123456\n") != null, "background = #123456 is written", .{});
        try h.expect(std.mem.indexOf(u8, saved, "theme = Dracula\n") != null, "theme = Dracula is written", .{});
        try h.expect(std.mem.indexOf(u8, saved, "keybind = ctrl+shift+k=new_tab\n") != null and std.mem.indexOf(u8, saved, "new_window") == null, "ctrl+shift+k's line is new_tab, once", .{});
        try h.expect(std.mem.indexOf(u8, saved, "keybind = ctrl+shift+f5=goto_tab:2\n") != null, "ctrl+shift+f5 = goto_tab:2 is written", .{});
        try h.expect(std.mem.indexOf(u8, saved, "ctrl+shift+t=") == null, "the binding cancelled writes nothing", .{});
    }

    // A file's button: the file dialog's choice.
    const chimes = "C:\\Windows\\Media\\chimes.wav";
    var g2 = try h.launchWith("config-editor-pages-file", base_config, .{ .env = &.{.{ "GHOSTTY_WIN32_TEST_PICK", chimes }} });
    defer g2.deinit();
    try h.waitText(&g2, ">", 1, 20000);
    try h.openConfigEditor(&g2);
    try waitEditor(h, &g2, struct {
        fn ok(_: @This(), e: Harness.Dump.Editor) bool {
            return e.rows.len > 200;
        }
    }{}, "it opens");
    try editorClick(h, &g2, "bell-audio-path", .picker);
    try waitEditor(h, &g2, rowValue("bell-audio-path", chimes), "the file button's dialog sets bell-audio-path");
}

/// Pictures of the configuration editor (roadmap F1), as its WM_PAINT draws
/// it: dark, then light, with a row's documentation opened, copied into
/// GHOSTTY_GUI_SNAPSHOT as `editor-<look>-bar.bmp` and `-list.bmp`.
fn configEditorLook(h: *Harness) anyerror!void {
    var out_buf: [512]u16 = undefined;
    const n = w.GetEnvironmentVariableW(w.L("GHOSTTY_GUI_SNAPSHOT"), &out_buf, out_buf.len);
    if (n == 0 or n >= out_buf.len) return h.skip("set GHOSTTY_GUI_SNAPSHOT to a folder", .{});
    const out_dir = try std.unicode.utf16LeToUtf8Alloc(h.alloc, out_buf[0..n]);
    defer h.alloc.free(out_dir);
    for ([_]struct { []const u8, []const u8 }{
        .{ "dark", "window-theme = dark\nfont-size = 13\nkeybind = ctrl+a=copy_to_clipboard\n" },
        .{ "light", "window-theme = light\nfont-size = 13\n" },
    }) |look| {
        const name = try std.fmt.allocPrint(h.alloc, "config-editor-look-{s}", .{look[0]});
        defer h.alloc.free(name);
        var g = try start(h, name, look[1], ">");
        defer g.deinit();
        try h.openConfigEditor(&g);
        try waitEditor(h, &g, struct {
            fn ok(_: @This(), e: Harness.Dump.Editor) bool {
                return e.rows.len > 200;
            }
        }{}, "it opens");
        // The fonts page's first rows, font-size opened.
        try editorClick(h, &g, "font-size", .control);
        w.Sleep(200);
        const now = try editorNow(h, &g, "font-size");
        h.key(now.search, .{}, w.VK_ESCAPE);
        try h.typeText(now.search, "font");
        w.Sleep(300);
        try h.snapshotConfigEditor(&g);
        for ([_][]const u8{ "bar", "list" }) |part| {
            const src = try std.fmt.allocPrint(h.alloc, "{s}\\editor-{s}-0.bmp", .{ g.dir, part });
            defer h.alloc.free(src);
            const data = h.readFileOrNull(src) orelse return h.fail("no {s}", .{src});
            defer h.alloc.free(data);
            const dst = try std.fmt.allocPrint(h.alloc, "{s}\\editor-{s}-{s}.bmp", .{ out_dir, look[0], part });
            defer h.alloc.free(dst);
            try h.writeFileAt(dst, data);
        }
    }
}

/// Roadmap 0.15: std.Thread on Windows passes its stack size (16 MB) as
/// the stack's commit, so each of a terminal's threads committed 16 MB up
/// front. Spawned through internal_os.thread.spawnConfig they commit their
/// stacks as they grow. Measured over four tabs opened after the first,
/// each with its prompt drawn: the threads' stacks (every thread reserves
/// the exe's 16 MB) and what a pane adds in all. Most of what is left is
/// the GL driver's, one context per pane: on NVIDIA about 8 MB for a bare
/// context and up to 32 MB of command and staging buffers.
fn paneCommit(h: *Harness) anyerror!void {
    var g = try start(h, "pane-commit", "", ">");
    defer g.deinit();
    const win = try h.mainWindow(&g);
    w.Sleep(1000);
    const one = privateBytes(&g);

    const added = 4;
    for (0..added) |i| {
        h.key(try h.surface(&g, win), .{ .ctrl = true, .shift = true }, 'T');
        try waitTabCount(h, &g, 0, i + 2);
        try waitPrompts(h, &g);
    }
    w.Sleep(2000);
    const more = privateBytes(&g);
    try h.expect(one > 0 and more > 0, "the process's commit charge is readable", .{});

    // Each pane has at least its renderer, IO and pty read threads.
    const stacks = threadStacks(&g);
    h.log("{d} thread stacks commit {d} KB, the largest {d} KB", .{
        stacks.count,
        stacks.committed >> 10,
        stacks.largest >> 10,
    });
    try h.expect(stacks.count >= 3 * (added + 1), "the threads' stacks are found (got {d})", .{stacks.count});
    try h.expect(
        stacks.committed < stacks.count * (1 << 20),
        "thread stacks commit under 1 MB each on average (got {d} KB for {d})",
        .{ stacks.committed >> 10, stacks.count },
    );

    const per_pane = (more -| one) / added;
    h.log("commit charge: one pane {d} MB, {d} panes {d} MB, {d} MB a pane", .{
        one >> 20,
        added + 1,
        more >> 20,
        per_pane >> 20,
    });
    try h.expect(per_pane < 80 << 20, "a pane adds under 80 MB of commit charge (got {d} MB)", .{per_pane >> 20});
}

const ThreadStacks = struct { count: usize = 0, committed: usize = 0, largest: usize = 0 };

/// Ghostty's thread stacks, from its address space: every thread reserves
/// the exe's stack reserve (16 MB) as a private allocation of its own,
/// and commits what the stack has used (all of it, before 0.15).
fn threadStacks(g: *Harness.Ghostty) ThreadStacks {
    const reserve = 16 << 20;
    const Allocation = struct { base: usize = 0, reserved: usize = 0, committed: usize = 0, private: bool = false };
    var out: ThreadStacks = .{};
    var current: Allocation = .{};
    var addr: usize = 0;
    while (true) {
        var info: w.MEMORY_BASIC_INFORMATION = .{};
        if (w.VirtualQueryEx(g.proc, addr, &info, @sizeOf(w.MEMORY_BASIC_INFORMATION)) == 0) break;
        if (info.State != w.MEM_FREE) {
            if (info.AllocationBase != current.base) {
                if (current.private and current.reserved == reserve) {
                    out.count += 1;
                    out.committed += current.committed;
                    out.largest = @max(out.largest, current.committed);
                }
                current = .{ .base = info.AllocationBase, .private = info.Type == w.MEM_PRIVATE };
            }
            current.reserved += info.RegionSize;
            if (info.State == w.MEM_COMMIT) current.committed += info.RegionSize;
        }
        addr = info.BaseAddress + info.RegionSize;
    }
    if (current.private and current.reserved == reserve) {
        out.count += 1;
        out.committed += current.committed;
        out.largest = @max(out.largest, current.committed);
    }
    return out;
}

/// Wait until each of the first window's tabs shows cmd's prompt.
fn waitPrompts(h: *Harness, g: *Harness.Ghostty) !void {
    var waited: u32 = 0;
    while (waited <= 20000) : (waited += 200) {
        var d = try h.dump(g);
        defer d.deinit();
        const shown = for (d.value.windows[0].tabs) |t| {
            const text = t.text orelse break false;
            if (std.mem.indexOfScalar(u8, text, '>') == null) break false;
        } else true;
        if (shown) return;
        w.Sleep(200);
    }
    return h.fail("not every tab shows a prompt", .{});
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

/// Roadmap 4.1 on the display (begun as spike S2): at background-opacity
/// 0.5 over a green backdrop, DWM composes the panes' GL output with its
/// alpha (blur-behind with an empty region on the top-level window), while
/// layered children, the header bar and a split's divider stay opaque;
/// toggle_background_opacity switches it off and on. Read back from the
/// screen. Both windows show on the owner's screen for a few seconds,
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
    var g = try h.launchAt("transparency", base_config ++ "background-opacity = 0.5\n" ++ toggle_opacity, .onscreen);
    defer g.deinit();
    try h.waitText(&g, ">", 1, 20000);
    const win = try h.mainWindow(&g);
    const surf = try h.surface(&g, win);
    try expectTranslucent(h, &g, &.{true});
    var wr: w.RECT = .{};
    _ = w.GetWindowRect(win, &wr);
    var backdrop = try Harness.Backdrop.create(wr, backdrop_green);
    defer backdrop.destroy();
    const previous = stage(h, win, backdrop.hwnd);
    defer if (previous) |p| {
        _ = Harness.bringToFront(p);
    };

    // Read from the display (desktop duplication): on screen the GL panes
    // may be presented outside the window's GDI surface, which BitBlt and
    // PrintWindow read. A background pixel near the bottom right, as it
    // opens translucent.
    const client = clientOnScreen(win);
    const bx: usize = @intCast(client.right - client.left - 30);
    const by: usize = @intCast(client.bottom - client.top - 30);
    // The header bar, a quarter of the way along (clear of the title).
    const hx: usize = @intCast(@divTrunc(client.right - client.left, 4));
    printZOrder(win, backdrop.hwnd, wr, client);
    try uncovered(h, win, wr, client, &.{ .{ bx, by }, .{ hx, 4 }, .{ @intCast(@divTrunc(client.right - client.left, 2)), @intCast(@divTrunc(client.bottom - client.top, 2)) } });
    const at_start = try displayPixel(h, &g, client, bx, by, "start.bmp");

    // Opaque, by the toggle.
    h.key(surf, .{ .ctrl = true, .shift = true }, w.VK_F3);
    try expectTranslucent(h, &g, &.{false});
    h.pump(500);
    const opaque_px = try displayPixel(h, &g, client, bx, by, "opaque.bmp");
    const opaque_gdi = try screenPixel(h, client, bx, by);

    // Spike S1's three hosts over the opaque pane: which ones show?
    var hosts: [3]u32 = undefined;
    for (&hosts, 1..) |*px, kind| px.* = try overlayOnDisplay(h, &g, client, @intCast(kind));

    h.key(surf, .{ .ctrl = true, .shift = true }, w.VK_F3);
    try expectTranslucent(h, &g, &.{true});
    h.pump(500);
    const see_through = try displayPixel(h, &g, client, bx, by, "see-through.bmp");
    const see_through_gdi = try screenPixel(h, client, bx, by);
    const layered_over_clear = try overlayOnDisplay(h, &g, client, 3);
    // The header bar, as its paint has it.
    const header_px = try displayPixel(h, &g, client, hx, 4, "header.bmp");
    try h.saveChrome(&g);
    const header_paint = paint: {
        var chrome = try h.loadPicture(&g, "chrome-0.bmp");
        defer chrome.deinit();
        break :paint chrome.rgb(hx, 4);
    };

    // A split's divider, painted with GDI (opaque through the alpha
    // buffer), beside a new pane that starts translucent.
    h.key(surf, .{ .ctrl = true, .shift = true }, 'O');
    try waitPanes(h, &g, 2);
    h.pump(800);
    var divider_color: u32 = 0;
    const divider_px = divider: {
        var d = try h.dump(&g);
        defer d.deinit();
        const t = d.value.windows[0].tabs[0];
        divider_color = @intCast(t.divider_color orelse 0);
        const dv = (t.dividers orelse break :divider @as(u32, 0));
        if (dv.len == 0) break :divider @as(u32, 0);
        const container = w.GetParent(hwndOf(t.panes.?[0].hwnd)) orelse break :divider @as(u32, 0);
        var pt = [1]w.POINT{.{ .x = @divTrunc(dv[0][0] + dv[0][2], 2), .y = @divTrunc(dv[0][1] + dv[0][3], 2) }};
        _ = w.MapWindowPoints(container, null, &pt, 1);
        break :divider try displayPixel(h, &g, client, @intCast(pt[0].x - client.left), @intCast(pt[0].y - client.top), "split.bmp");
    };
    const new_pane = try displayPixel(h, &g, client, bx, by, "split-see-through.bmp");

    h.key(surf, .{ .ctrl = true, .shift = true }, w.VK_F3);
    try expectTranslucent(h, &g, &.{false});
    h.pump(500);
    const opaque_again = try displayPixel(h, &g, client, bx, by, "opaque-again.bmp");

    std.debug.print("\n    display: opaque #{x:0>6}; overlays on it: sibling #{x:0>6}, child #{x:0>6}, layered child #{x:0>6}; " ++
        "see-through #{x:0>6} (#14951a if DWM blends with the alpha, #14161a if it ignores it); layered child on it #{x:0>6}; " ++
        "header #{x:0>6} (painted #{x:0>6}); divider #{x:0>6} (painted #{x:0>6}); new pane #{x:0>6}; opaque again #{x:0>6}\n" ++
        "    GDI's view (BitBlt): opaque #{x:0>6}, see-through #{x:0>6}\n", .{
        opaque_px,  hosts[0],        hosts[1],   hosts[2],      see_through, layered_over_clear,
        header_px,  header_paint,    divider_px, divider_color, new_pane,    opaque_again,
        opaque_gdi, see_through_gdi,
    });
    try h.expect(near(at_start, 0x14951a, 4), "it opens see-through, the backdrop through half (got #{x:0>6})", .{at_start});
    try h.expect(near(opaque_px, 0x282c34, 2), "opaque, the background is #282c34 (got #{x:0>6})", .{opaque_px});
    try h.expect(hosts[2] == overlay_magenta, "a layered child shows over the pane (got #{x:0>6})", .{hosts[2]});
    try h.expect(near(see_through, 0x14951a, 4), "see-through, the backdrop shows through half (got #{x:0>6})", .{see_through});
    try h.expect(layered_over_clear == overlay_magenta, "a layered child stays opaque over it (got #{x:0>6})", .{layered_over_clear});
    try h.expect(near(header_px, header_paint, 2), "the header bar stays opaque (got #{x:0>6}, painted #{x:0>6})", .{ header_px, header_paint });
    try h.expect(near(divider_px, divider_color, 2), "the divider stays opaque (got #{x:0>6}, painted #{x:0>6})", .{ divider_px, divider_color });
    try h.expect(near(new_pane, 0x14951a, 4), "the new pane shows the backdrop through half (got #{x:0>6})", .{new_pane});
    try h.expect(near(opaque_again, 0x282c34, 2), "opaque again (got #{x:0>6})", .{opaque_again});
}

/// background-blur on the display (roadmap 4.2): murrtty at
/// background-opacity 0.5 over upright green and black stripes 12 px wide.
/// Unblurred, the stripes show through the background, its green channel
/// swinging across a row by about half their contrast. Blurred (a reload
/// to background-blur = true), active (Acrylic) and inactive (the accent
/// policy's blur), the swing shrinks to a fraction of that while the
/// backdrop still shows through, and stripes repainted red bring red and
/// take green away. Then, only reported: Acrylic kept while inactive
/// (which Microsoft says turns solid, the reason for the accent there).
/// It shows windows ON SCREEN, so it runs only with
/// GHOSTTY_GUI_ONSCREEN=1.
fn blurDisplay(h: *Harness) anyerror!void {
    if (w.GetEnvironmentVariableW(w.L("GHOSTTY_GUI_ONSCREEN"), null, 0) == 0) {
        return h.skip("it shows windows on the screen; set GHOSTTY_GUI_ONSCREEN=1 to run it", .{});
    }
    if (h.capturesWork()) |why| return h.skip("{s}", .{why});
    const Ctx = struct { h: *Harness, err: ?anyerror = null };
    var ctx: Ctx = .{ .h = h };
    h.runOnUserDesktop(&ctx, struct {
        fn run(cx: *Ctx) void {
            blurOnScreen(cx.h) catch |err| {
                cx.err = err;
            };
        }
    }.run);
    if (ctx.err) |err| return err;
}

fn blurOnScreen(h: *Harness) !void {
    const config = base_config ++ "background-opacity = 0.5\napp-notifications = no-config-reload\n";
    var g = try h.launchAt("blur-display", config, .onscreen);
    defer g.deinit();
    try h.waitText(&g, ">", 1, 20000);
    const win = try h.mainWindow(&g);
    var wr: w.RECT = .{};
    _ = w.GetWindowRect(win, &wr);
    var backdrop = try Harness.Backdrop.create(wr, 0);
    defer backdrop.destroy();
    if (!backdrop.fillStripes(0x00ff00, 0x000000, 12)) return h.fail("the stripes didn't fill", .{});
    const previous = stage(h, win, backdrop.hwnd);
    defer if (previous) |p| {
        _ = Harness.bringToFront(p);
    };
    const client = clientOnScreen(win);
    // A row across the empty middle of the pane.
    const y: usize = @intCast(@divTrunc(client.bottom - client.top, 2));
    try uncovered(h, win, wr, client, &.{ .{ 40, y }, .{ 400, y } });
    const sharp = try greenSwing(h, &g, client, y, "sharp.bmp");
    std.debug.print("\n    unblurred: green {x:0>2}..{x:0>2} (mean {x:0>2})\n", .{ sharp.min, sharp.max, sharp.mean });
    try h.expect(sharp.max - sharp.min > 0x60, "unblurred, the stripes show through (swing {x})", .{sharp.max - sharp.min});

    const cfg_path = try std.fmt.allocPrint(h.alloc, "{s}\\blur-display\\murrtty\\config.ghostty", .{h.temp_dir});
    defer h.alloc.free(cfg_path);
    try h.writeFileAt(cfg_path, config ++ "background-blur = true\n");
    h.key(try h.surface(&g, win), .{ .ctrl = true, .shift = true }, w.VK_OEM_COMMA);
    const active = try waitBlurNot(h, &g, "none");
    try expectBlurred(h, &g, &backdrop, client, y, sharp, active, "active");

    // Inactive: the backdrop takes the foreground, then goes back under.
    _ = Harness.bringToFront(backdrop.hwnd);
    _ = w.SetWindowPos(backdrop.hwnd, win, 0, 0, 0, 0, w.SWP_NOMOVE | w.SWP_NOSIZE | w.SWP_NOACTIVATE);
    const inactive = try waitBlurNot(h, &g, active);
    try expectBlurred(h, &g, &backdrop, client, y, sharp, inactive, "inactive");

    // Acrylic kept while inactive, reported only.
    try h.forceAcrylic(&g, true);
    defer h.forceAcrylic(&g, false) catch {};
    const kept = try waitBlurNot(h, &g, inactive);
    const kept_green, const kept_red = try blurReadings(h, &g, &backdrop, client, y, "acrylic-inactive");
    const verdict = if (follows(kept_green, kept_red)) "it follows the backdrop" else "it doesn't follow the backdrop: solid";
    std.debug.print("    {s} while inactive: green {x:0>2}..{x:0>2} (mean {x:0>2}); red stripes: green mean {x:0>2}, red mean {x:0>2} ({s})\n", .{
        kept, kept_green.min, kept_green.max, kept_green.mean, kept_red[1].mean, kept_red[0].mean, verdict,
    });
}

/// Wait until the first window's blur isn't `old`; return the new one (a
/// static string, as nativeBlur gives).
fn waitBlurNot(h: *Harness, g: *Harness.Ghostty, old: []const u8) ![]const u8 {
    var waited: u32 = 0;
    while (waited <= 3000) : (waited += 100) {
        var d = try h.dump(g);
        defer d.deinit();
        const now = d.value.windows[0].blur;
        if (!std.mem.eql(u8, now, old)) {
            for ([_][]const u8{ "none", "backdrop", "accent" }) |name| if (std.mem.eql(u8, now, name)) return name;
        }
        w.Sleep(100);
    }
    return h.fail("the blur stayed {s}", .{old});
}

/// Green across green stripes, then all three channels across red ones
/// (the stripes are green again after); captures kept as `<name>-*.bmp`.
fn blurReadings(h: *Harness, g: *Harness.Ghostty, backdrop: *Harness.Backdrop, client: w.RECT, y: usize, comptime name: []const u8) !struct { Swing, [3]Swing } {
    h.pump(800);
    const green = try greenSwing(h, g, client, y, name ++ "-green.bmp");
    if (!backdrop.fillStripes(0xff0000, 0x000000, 12)) return h.fail("the stripes didn't fill", .{});
    h.pump(800);
    const red = try rowStats(h, g, client, y, name ++ "-red.bmp");
    if (!backdrop.fillStripes(0x00ff00, 0x000000, 12)) return h.fail("the stripes didn't fill", .{});
    return .{ green, red };
}

/// Whether what shows through followed the stripes turning red: green
/// went away and red came (a solid fallback would do neither).
fn follows(green: Swing, red: [3]Swing) bool {
    return red[1].mean + 0x10 < green.mean and red[0].mean > 0x14 + 0x10;
}

/// The blur `method` (the window `state`, active or not) flattens the
/// stripes yet shows them through, and follows them as they change.
fn expectBlurred(h: *Harness, g: *Harness.Ghostty, backdrop: *Harness.Backdrop, client: w.RECT, y: usize, sharp: Swing, method: []const u8, comptime state: []const u8) !void {
    const green, const red = try blurReadings(h, g, backdrop, client, y, state);
    std.debug.print("    {s} ({s}): green {x:0>2}..{x:0>2} (mean {x:0>2}); red stripes: green mean {x:0>2}, red mean {x:0>2}\n", .{
        state, method, green.min, green.max, green.mean, red[1].mean, red[0].mean,
    });
    try h.expect(!std.mem.eql(u8, method, "none"), state ++ ": blurred ({s})", .{method});
    try h.expect((green.max - green.min) * 3 < sharp.max - sharp.min, state ++ ": the swing shrinks to under a third ({x})", .{green.max - green.min});
    try h.expect(green.mean > 0x1a, state ++ ": the backdrop still shows through (mean green {x}, the background alone #16)", .{green.mean});
    try h.expect(follows(green, red), state ++ ": the blur follows the backdrop (red stripes: green {x} from {x}, red {x})", .{ red[1].mean, green.mean, red[0].mean });
}

const Swing = struct { min: u32, max: u32, mean: u32 };

/// The display's green channel along row `y` of `client`, over a run of
/// stripes from x = 40; the capture is kept as `name`.
fn greenSwing(h: *Harness, g: *Harness.Ghostty, client: w.RECT, y: usize, name: []const u8) !Swing {
    return (try rowStats(h, g, client, y, name))[1];
}

/// The display's red, green and blue channels along row `y` of `client`,
/// over a run of stripes from x = 40; the capture is kept as `name`.
fn rowStats(h: *Harness, g: *Harness.Ghostty, client: w.RECT, y: usize, name: []const u8) ![3]Swing {
    var img = try h.captureDisplay(client);
    defer img.deinit();
    saveImage(h, g, &img, name);
    const end = @min(img.width - 40, 40 + 24 * 12);
    if (y >= img.height or end <= 40) return h.fail("row {d} is outside the capture", .{y});
    var stats: [3]Swing = @splat(.{ .min = 0xff, .max = 0, .mean = 0 });
    var sums: [3]u32 = @splat(0);
    for (40..end) |x| {
        const px = img.rgb(x, y);
        for (&stats, &sums, [_]u5{ 16, 8, 0 }) |*s, *sum, shift| {
            const v = (px >> shift) & 0xff;
            s.min = @min(s.min, v);
            s.max = @max(s.max, v);
            sum.* += v;
        }
    }
    for (&stats, sums) |*s, sum| s.mean = sum / @as(u32, @intCast(end - 40));
    return stats;
}

/// Stage an `.onscreen` murrtty for reading the display: the foreground
/// window, in front of the owner's (Harness.bringToFront), topmost, with
/// the backdrop right under it. Without the first, a background harness
/// left murrtty under the backdrop and the owner's foreground window
/// (2026-10-27: the display read only green). Returns the window that was
/// in front, to put back.
fn stage(h: *Harness, win: w.HWND, backdrop: w.HWND) ?w.HWND {
    const front = Harness.bringToFront(win);
    h.log("murrtty brought to the front: {}", .{front.ok});
    _ = w.SetWindowPos(win, w.HWND_TOPMOST, 0, 0, 0, 0, w.SWP_NOMOVE | w.SWP_NOSIZE | w.SWP_NOACTIVATE);
    _ = w.SetWindowPos(backdrop, win, 0, 0, 0, 0, w.SWP_NOMOVE | w.SWP_NOSIZE | w.SWP_NOACTIVATE);
    h.pump(500);
    return front.previous;
}

/// Skip unless murrtty's `win` is on top at each of `points` (client
/// pixels): another program's window in front, the foreground one say,
/// would be read instead. No capture is needed to tell.
fn uncovered(h: *Harness, win: w.HWND, wr: w.RECT, client: w.RECT, points: []const [2]usize) error{Skipped}!void {
    for (points) |p| {
        const pt: w.POINT = .{ .x = client.left + @as(c_int, @intCast(p[0])), .y = client.top + @as(c_int, @intCast(p[1])) };
        const hit = w.WindowFromPoint(pt) orelse continue;
        const root = w.GetAncestor(hit, w.GA_ROOT) orelse hit;
        if (root == win) continue;
        var class: [128]u16 = undefined;
        const cn: usize = @intCast(@max(w.GetClassNameW(root, &class, class.len), 0));
        return h.skip("a window of class '{f}' covers murrtty at ({d},{d}); move it off ({d},{d})-({d},{d}) and run again", .{
            std.unicode.fmtUtf16Le(class[0..cn]), pt.x, pt.y, wr.left, wr.top, wr.right, wr.bottom,
        });
    }
}

/// Print where `win` is, whether it shows (visible, minimized, cloaked)
/// and which top-level window is hit at its client's middle: it, the
/// backdrop or another.
fn printZOrder(win: w.HWND, backdrop: w.HWND, wr: w.RECT, client: w.RECT) void {
    var cloaked: w.DWORD = 0;
    _ = w.DwmGetWindowAttribute(win, w.DWMWA_CLOAKED, &cloaked, @sizeOf(w.DWORD));
    const mid: w.POINT = .{ .x = @divTrunc(client.left + client.right, 2), .y = @divTrunc(client.top + client.bottom, 2) };
    const hit = w.WindowFromPoint(mid);
    const root = if (hit) |hw| w.GetAncestor(hw, w.GA_ROOT) else null;
    const which = if (root == win) "murrtty" else if (root == backdrop) "the backdrop" else "another window";
    std.debug.print("\n    window ({d},{d})-({d},{d}), client ({d},{d})-({d},{d}), visible {}, iconic {}, cloaked {d}; on top at ({d},{d}): {s}\n", .{
        wr.left,                     wr.top,               wr.right,     wr.bottom,
        client.left,                 client.top,           client.right, client.bottom,
        w.IsWindowVisible(win) != 0, w.IsIconic(win) != 0, cloaked,      mid.x,
        mid.y,                       which,
    });
    // Another window's top level: class, process, text.
    if (root != win) if (root) |hw| {
        var class: [128]u16 = undefined;
        const cn: usize = @intCast(@max(w.GetClassNameW(hw, &class, class.len), 0));
        var text: [128]u16 = undefined;
        const tn: usize = @intCast(@max(w.GetWindowTextW(hw, &text, text.len), 0));
        var pid: w.DWORD = 0;
        _ = w.GetWindowThreadProcessId(hw, &pid);
        var my_pid: w.DWORD = 0;
        _ = w.GetWindowThreadProcessId(win, &my_pid);
        std.debug.print("    hit 0x{x}: class '{f}', text '{f}', pid {d} (murrtty's {d})\n", .{
            @intFromPtr(hw), std.unicode.fmtUtf16Le(class[0..cn]), std.unicode.fmtUtf16Le(text[0..tn]), pid, my_pid,
        });
    };
    const topmost = struct {
        fn f(hw: ?w.HWND) bool {
            return if (hw) |x| w.GetWindowLongPtrW(x, w.GWL_EXSTYLE) & w.WS_EX_TOPMOST != 0 else false;
        }
    }.f;
    const fg = w.GetForegroundWindow();
    std.debug.print("    topmost: murrtty {}, backdrop {}, hit {}; foreground 0x{x} (murrtty {}, hit {})\n", .{
        topmost(win), topmost(backdrop), topmost(root), if (fg) |x| @intFromPtr(x) else 0, fg == win, fg == root,
    });
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
/// dividers are the window's background, as GTK's, unless
/// `split-divider-color` sets them.
fn splitDim(h: *Harness) anyerror!void {
    const dim_config = "unfocused-split-fill = #ff0000\nunfocused-split-opacity = 0.5\n";
    var g = try start(h, "split-dim", dim_config, ">");
    defer g.deinit();
    const win = try h.mainWindow(&g);
    const bg: u32 = 0x282c34;
    try h.expect(try h.probePane(&g, 0, 1, 40) == bg, "one pane: not dimmed", .{});

    h.key(try h.surface(&g, win), .{ .ctrl = true, .shift = true }, 'O');
    try waitPanes(h, &g, 2);
    w.Sleep(1500);
    // The new (right) pane is focused; the left one is dimmed.
    const dim = blendSrgb(0xff0000, bg, 0.5);
    try expectColor(h, try h.probePane(&g, 0, 1, 40), dim, "the unfocused pane is dimmed");
    try expectColor(h, try h.probePane(&g, 1, 1, 40), bg, "the focused pane isn't");

    // Clicking the left pane moves the focus, and the dimming with it.
    const left = try paneHwnd(h, &g, 0);
    h.click(left, 200, 200, .left);
    w.Sleep(800);
    try expectColor(h, try h.probePane(&g, 0, 1, 40), bg, "after a click the left pane isn't dimmed");
    try expectColor(h, try h.probePane(&g, 1, 1, 40), dim, "and the right one is");

    // The dividers are GTK's, the window's background (Adwaita's dark one
    // for the dark default), and stay so when a program changes the
    // terminal's: OSC 11 from cmd's prompt ($E is ESC; ESC \ ends the
    // sequence), as GTK's window theme doesn't follow it either.
    try expectDividerColor(h, &g, 0x222226, "the dividers are the window's background");
    try h.typeText(left, "prompt $E]11;#f0f0f0$E\\$G");
    h.enter(left);
    var light: u32 = 0;
    var waited: u32 = 0;
    while (waited <= 5000 and light != 0xf0f0f0) : (waited += 250) {
        light = try h.probePane(&g, 0, 1, 40);
        if (light != 0xf0f0f0) w.Sleep(250);
    }
    try expectColor(h, light, 0xf0f0f0, "OSC 11 lightens the terminal");
    // The tab repaints on the change (Window.colorsChanged).
    w.Sleep(500);
    try expectDividerColor(h, &g, 0x222226, "and the dividers stay the window's");

    // split-divider-color sets them over that rule: written to the running
    // instance's configuration, then reloaded (Ctrl+Shift+,).
    const cfg_path = try std.fmt.allocPrint(h.alloc, "{s}\\split-dim\\murrtty\\config.ghostty", .{h.temp_dir});
    defer h.alloc.free(cfg_path);
    try h.writeFileAt(cfg_path, base_config ++ dim_config ++ "split-divider-color = #ffffff\n");
    h.key(left, .{ .ctrl = true, .shift = true }, w.VK_OEM_COMMA);
    try expectDividerColor(h, &g, 0xffffff, "split-divider-color sets them, whatever the background");
    try quit(h, &g, left);
}

/// GTK's top bars cast libadwaita's shade onto the content below them
/// (roadmap 4.3), read back from the renderers in the left padding: the
/// top row is the background under the shade's darkest row (#1c1f26 at
/// 96, 120 and 144 DPI, draw.shadeAlpha), and the background returns
/// within 6 px per 96 DPI. Of a split, the panes reaching the bar are
/// shaded and one below another isn't; without a bar (server decorations,
/// one tab) nothing is. gtk-toolbar-style = raised-border draws a line of
/// the darker shade instead, and flat nothing, with the bar in the
/// window's background.
fn shade(h: *Harness) anyerror!void {
    const bg: u32 = 0x282c34;
    const shaded: u32 = 0x1c1f26;
    {
        var g = try start(h, "shade", "", ">");
        defer g.deinit();
        const win = try h.mainWindow(&g);
        try expectColor(h, try h.probePane(&g, 0, 1, 0), shaded, "the top row is under the shade");
        try expectColor(h, try h.probePane(&g, 0, 1, 40), bg, "below its reach, the background");

        // Side by side, then the right pane split down.
        h.key(try h.surface(&g, win), .{ .ctrl = true, .shift = true }, 'O');
        try waitPanes(h, &g, 2);
        h.key(try paneHwnd(h, &g, 1), .{ .ctrl = true, .shift = true }, 'E');
        try waitPanes(h, &g, 3);
        w.Sleep(1500);
        var d = try h.dump(&g);
        defer d.deinit();
        const panes = d.value.windows[0].tabs[0].panes orelse return h.fail("no panes", .{});
        var top: i32 = std.math.maxInt(i32);
        for (panes) |p| top = @min(top, p.rect[1]);
        for (panes, 0..) |p, i| {
            const reaches = p.rect[1] == top;
            try h.expect((p.shade > 0.2) == reaches, "pane {d} {s} the bar: shade {d:.2}", .{ i, if (reaches) "reaching" else "below", p.shade });
            const px = try h.probePane(&g, i, 1, 0);
            try expectColor(h, px, if (reaches) shaded else bg, "its top row");
        }
        try quit(h, &g, try paneHwnd(h, &g, 0));
    }
    {
        var g = try start(h, "shade-none", "window-decoration = server\n", ">");
        defer g.deinit();
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(d.value.windows[0].tabs[0].panes.?[0].shade == 0, "no bar, no shade", .{});
        try expectColor(h, try h.probePane(&g, 0, 1, 0), bg, "the top row is the background");
        // A second tab brings the tab row, whose shade falls on the new tab
        // too (it starts at its final size, so no relayout gives it one).
        const win = try h.mainWindow(&g);
        h.key(try h.surface(&g, win), .{ .ctrl = true, .shift = true }, 'T');
        try waitWindowTabs(h, &g, win, 2);
        try waitActivePaneText(h, &g, win, ">");
        try expectColor(h, try h.probePane(&g, 0, 1, 0), shaded, "the new tab's top row is under the row's shade");
        try quit(h, &g, try h.surface(&g, win));
    }
    {
        var g = try start(h, "shade-border", "gtk-toolbar-style = raised-border\n", ">");
        defer g.deinit();
        try expectColor(h, try h.probePane(&g, 0, 1, 0), 0x040410, "raised-border: the top row is the darker shade's line");
        try expectColor(h, try h.probePane(&g, 0, 1, 4), bg, "and the background below it");
        const chrome = try chromeOf(h, &g);
        try h.expect(chrome.caption == 0x2e2e32, "in the bar's own color (#{x:0>6})", .{@as(u64, @bitCast(chrome.caption))});
        try quit(h, &g, try h.surface(&g, try h.mainWindow(&g)));
    }
    {
        var g = try start(h, "shade-flat", "gtk-toolbar-style = flat\n", ">");
        defer g.deinit();
        try expectColor(h, try h.probePane(&g, 0, 1, 0), bg, "flat: nothing falls on the top row");
        const chrome = try chromeOf(h, &g);
        try h.expect(chrome.caption == 0x222226, "and the bar is the window's background (#{x:0>6})", .{@as(u64, @bitCast(chrome.caption))});
        try quit(h, &g, try h.surface(&g, try h.mainWindow(&g)));
    }
}

const toggle_opacity = "keybind = ctrl+shift+f3=toggle_background_opacity\n";

/// Dragging tabs (roadmap 4.5): along the strip a tab takes the place of
/// each tab it passes, live, before the release; dropped away from the
/// window it moves, panes running, into a new window under the mouse,
/// where its pane takes typing and keeps presenting frames; dropped on
/// another window's bar it moves there, and a window it leaves empty
/// closes. move_tab_to_new_window does the same from a binding, and
/// nothing for a window's only tab. With the tab bar always shown, so a
/// lone tab can be dragged too.
fn tabDrag(h: *Harness) anyerror!void {
    const config = "window-show-tab-bar = always\nkeybind = ctrl+shift+f5=move_tab_to_new_window\n";
    var g = try start(h, "tab-drag", config, ">");
    defer g.deinit();
    const win = try h.mainWindow(&g);
    const surf = try h.surface(&g, win);
    h.key(surf, .{ .ctrl = true, .shift = true }, 'T');
    try waitWindowTabs(h, &g, win, 2);
    h.key(surf, .{ .ctrl = true, .shift = true }, 'T');
    try waitWindowTabs(h, &g, win, 3);
    const o = try tabPanes(h, &g, 0);

    // Along the strip: the first tab over the second, then the third.
    const start0 = try tabMid(h, &g, 0, 0);
    h.press(win, start0[0], start0[1]);
    h.move(win, start0[0] + 12, start0[1], true);
    const over1 = try tabMid(h, &g, 0, 1);
    h.move(win, over1[0] + 4, over1[1], true);
    h.sync(win);
    try expectTabPanes(h, &g, 0, &.{ o.at(1), o.at(0), o.at(2) }, "dragged over the second tab, before the release, it has taken its place");
    const over2 = try tabMid(h, &g, 0, 2);
    h.move(win, over2[0] + 4, over2[1], true);
    h.release(win, over2[0] + 4, over2[1]);
    h.sync(win);
    try expectTabPanes(h, &g, 0, &.{ o.at(1), o.at(2), o.at(0) }, "and over the third, the last place, where it stays");

    // Away from the window: a new window with that tab, under the mouse.
    var client: w.RECT = .{};
    _ = w.GetClientRect(win, &client);
    const last = try tabMid(h, &g, 0, 2);
    h.press(win, last[0], last[1]);
    h.move(win, last[0], last[1] + 12, true);
    h.move(win, last[0], client.bottom + 240, true);
    h.release(win, last[0], client.bottom + 240);
    try waitWindowCount(h, &g, 2);
    try expectTabPanes(h, &g, 0, &.{ o.at(1), o.at(2) }, "dropped below the window, the tab leaves it");
    try expectTabPanes(h, &g, 1, &.{o.at(0)}, "for a new window of its own");
    const torn = hwndOf(o.at(0));
    var drop: w.POINT = .{ .x = last[0], .y = client.bottom + 240 };
    _ = w.ClientToScreen(win, &drop);
    const new_win = try windowOf(h, &g, 1);
    var nr: w.RECT = .{};
    _ = w.GetWindowRect(new_win, &nr);
    // Under the mouse, inside its monitor's work area (where the drop is
    // off it, as below a window near the bottom, inside it all the same).
    var mi: w.MONITORINFO = .{};
    if (w.MonitorFromWindow(new_win, w.MONITOR_DEFAULTTONEAREST)) |m| _ = w.GetMonitorInfoW(m, &mi);
    const work = mi.rcWork;
    const on_work = drop.x >= work.left and drop.x < work.right and drop.y >= work.top and drop.y < work.bottom;
    const under = drop.x >= nr.left and drop.x < nr.right and drop.y >= nr.top and drop.y < nr.bottom;
    const inside = nr.left >= work.left and nr.top >= work.top and nr.right <= work.right and nr.bottom <= work.bottom;
    try h.expect(inside and (under or !on_work), "the new window is under the mouse ({d},{d} in {d},{d}-{d},{d}) within the work area {d},{d}-{d},{d}", .{
        drop.x, drop.y, nr.left, nr.top, nr.right, nr.bottom, work.left, work.top, work.right, work.bottom,
    });
    const container = w.GetParent(torn) orelse return h.fail("the pane has no tab", .{});
    try h.expect(w.GetParent(container) == new_win, "the tab's container, the same window, is the new window's child now", .{});
    // Its pane runs on: it takes typing and presents frames.
    const frames = try paneFrames(h, &g, torn);
    try h.typeText(torn, "echo moved-tab");
    h.enter(torn);
    try h.waitText(&g, "moved-tab", 2, 10000);
    try h.expect(try paneFrames(h, &g, torn) > frames, "the moved pane keeps presenting frames", .{});

    // Onto the new window's bar: the first window's first tab moves there.
    var bar: w.POINT = .{ .x = 200, .y = 8 };
    _ = w.ClientToScreen(new_win, &bar);
    _ = w.ScreenToClient(win, &bar);
    const first = try tabMid(h, &g, 0, 0);
    h.press(win, first[0], first[1]);
    h.move(win, first[0], first[1] + 12, true);
    h.move(win, bar.x, bar.y, true);
    h.release(win, bar.x, bar.y);
    try waitTabCount(h, &g, 1, 2);
    try expectTabPanes(h, &g, 0, &.{o.at(2)}, "dropped on the other window's bar, the tab leaves this one");
    try h.expect(try windowHasPane(h, &g, 1, o.at(1)), "and joins that one", .{});

    // The first window's last tab: dropped there too, it closes the window
    // (gone from Ghostty's list, not just hidden).
    const lone = try tabMid(h, &g, 0, 0);
    h.press(win, lone[0], lone[1]);
    h.move(win, lone[0], lone[1] + 12, true);
    h.move(win, bar.x, bar.y, true);
    h.release(win, bar.x, bar.y);
    try waitWindowGone(h, &g, win);
    try waitTabCount(h, &g, 0, 3);

    // move_tab_to_new_window, then on the new window's only tab, nothing.
    h.key(torn, .{ .ctrl = true, .shift = true }, w.VK_F5);
    try waitWindowCount(h, &g, 2);
    try expectTabPanes(h, &g, 1, &.{o.at(0)}, "move_tab_to_new_window moves the tab to a new window");
    h.key(torn, .{ .ctrl = true, .shift = true }, w.VK_F5);
    h.sync(torn);
    w.Sleep(300);
    const wins = try h.windows(&g, "MurrttyWindow");
    defer h.alloc.free(wins);
    try h.expect(wins.len == 2, "and does nothing for a window's only tab", .{});
    try quit(h, &g, torn);
}

/// The terminal inspector (roadmap 5.12), GTK's: Ctrl+Shift+I opens a
/// window of its own for the pane, which draws, the core's inspector on;
/// the mouse reaches ImGui in it; Ctrl+Shift+I again closes it and turns
/// the core's off, as do its own close and the pane's. Two open close one
/// after the other with their tab (ImGui's GL functions are the process's:
/// neither may break the other's), and one open as murrtty quits. Its
/// Terminal IO export (the core's export_terminal_io) writes the events to
/// the file (GHOSTTY_WIN32_TEST_EXPORT standing in for the save dialog's
/// choice). Nothing leaks.
fn inspectorScenario(h: *Harness) anyerror!void {
    const export_path = try std.fmt.allocPrint(h.alloc, "{s}\\inspector\\terminal-io.txt", .{h.temp_dir});
    defer h.alloc.free(export_path);
    const config = base_config ++ "confirm-close-surface = false\nkeybind = ctrl+shift+f6=close_surface\n";
    var g = try h.launchWith("inspector", config, .{ .env = &.{.{ "GHOSTTY_WIN32_TEST_EXPORT", export_path }} });
    defer g.deinit();
    try h.waitText(&g, ">", 1, 20000);
    const win = try h.mainWindow(&g);
    const a = try h.surface(&g, win);
    const cs: Harness.Mods = .{ .ctrl = true, .shift = true };

    h.key(a, cs, 'I');
    const insp = try waitInspector(h, &g, a, true, "Ctrl+Shift+I opens the pane's inspector, the core's on");
    try waitInspectorFrames(h, &g, a, 3);
    const opened = try h.windows(&g, "MurrttyInspector");
    defer h.alloc.free(opened);
    try h.expect(opened.len == 1, "one inspector window ({d})", .{opened.len});

    // The mouse reaches ImGui (pinned: on the hidden desktop a real
    // WM_MOUSELEAVE follows a posted move).
    try h.pinMouse(&g, true);
    h.move(insp, 120, 80, false);
    try waitInspectorMouse(h, &g, a, .{ 120, 80 });

    // Ctrl+Shift+I again closes it.
    h.key(a, cs, 'I');
    _ = try waitInspector(h, &g, a, false, "Ctrl+Shift+I again closes it, the core's off");
    try waitClassCount(h, &g, "MurrttyInspector", 0, "its window is gone");

    // Its own close.
    h.key(a, cs, 'I');
    const again = try waitInspector(h, &g, a, true, "it opens again");
    _ = w.PostMessageW(again, w.WM_CLOSE, 0, 0);
    _ = try waitInspector(h, &g, a, false, "its window's close ends it");

    // The Terminal IO export.
    try h.exportTerminalIo(&g);
    var waited: u32 = 0;
    while (true) : (waited += 100) {
        if (h.readFileOrNull(export_path)) |text| {
            defer h.alloc.free(text);
            if (std.mem.indexOf(u8, text, "test-export") != null) break;
        }
        if (waited >= 5000) return h.fail("the Terminal IO events weren't written to {s}", .{export_path});
        w.Sleep(100);
    }
    try h.expect(true, "the export writes the Terminal IO events", .{});

    // A pane closing closes its inspector.
    try splitPane(h, &g, 0, 'O');
    const b = try paneHwnd(h, &g, 1);
    h.key(b, cs, 'I');
    _ = try waitInspector(h, &g, b, true, "the new pane's inspector opens");
    h.key(b, cs, w.VK_F6);
    try waitPanes(h, &g, 1);
    try waitClassCount(h, &g, "MurrttyInspector", 0, "and closes with its pane");

    // Two open, both drawn, closed together with their tab.
    h.key(a, cs, 'T');
    try waitWindowTabs(h, &g, win, 2);
    const t1 = try paneHwnd(h, &g, 0);
    try splitPane(h, &g, 0, 'O');
    const t2 = try paneHwnd(h, &g, 1);
    h.key(t1, cs, 'I');
    _ = try waitInspector(h, &g, t1, true, "the tab's first pane's inspector opens");
    h.key(t2, cs, 'I');
    _ = try waitInspector(h, &g, t2, true, "and its second's");
    try waitInspectorFrames(h, &g, t1, 3);
    try waitInspectorFrames(h, &g, t2, 3);
    h.key(t2, cs, 'W');
    try waitWindowTabs(h, &g, win, 1);
    try waitClassCount(h, &g, "MurrttyInspector", 0, "both close with their tab, one after the other");

    // One open as murrtty quits.
    h.key(a, cs, 'I');
    _ = try waitInspector(h, &g, a, true, "an inspector open at the quit");
    try waitInspectorFrames(h, &g, a, 3);
    // Nothing to confirm (confirm-close-surface = false).
    h.key(a, cs, 'Q');
    const code = g.waitExit(10000);
    try h.expect(code != null and code.? == 0, "exits with code 0 after quit (got {?d})", .{code});
    try expectNoLeaks(h, &g, "its inspectors leaked nothing");
}

/// Wait until `pane`'s inspector is open (with the core's on) or closed;
/// returns its window when open.
fn waitInspector(h: *Harness, g: *Harness.Ghostty, pane: w.HWND, open: bool, comptime what: []const u8) !w.HWND {
    var waited: u32 = 0;
    while (true) : (waited += 100) {
        var d = try h.dump(g);
        defer d.deinit();
        const p = findPane(d.value, pane) orelse return h.fail(what ++ ": no such pane", .{});
        if ((p.inspector != null) == open and p.inspector_active == open) {
            try h.expect(true, what, .{});
            return if (p.inspector) |i| hwndOf(i.hwnd) else pane;
        }
        if (waited >= 5000) return h.fail(what ++ ": window {}, core's {}", .{ p.inspector != null, p.inspector_active });
        w.Sleep(100);
    }
}

fn waitInspectorFrames(h: *Harness, g: *Harness.Ghostty, pane: w.HWND, frames: u32) !void {
    var waited: u32 = 0;
    while (true) : (waited += 100) {
        var d = try h.dump(g);
        defer d.deinit();
        const p = findPane(d.value, pane) orelse return h.fail("no such pane", .{});
        const got = if (p.inspector) |i| i.frames else 0;
        if (got >= frames) return h.expect(true, "the inspector draws ({d} frames)", .{got});
        if (waited >= 5000) return h.fail("the inspector drew {d} frames, not {d}", .{ got, frames });
        w.Sleep(100);
    }
}

fn waitInspectorMouse(h: *Harness, g: *Harness.Ghostty, pane: w.HWND, at: [2]f32) !void {
    var waited: u32 = 0;
    while (true) : (waited += 100) {
        var d = try h.dump(g);
        defer d.deinit();
        const p = findPane(d.value, pane) orelse return h.fail("no such pane", .{});
        const got: [2]f32 = if (p.inspector) |i| i.mouse else .{ -1, -1 };
        if (got[0] == at[0] and got[1] == at[1]) return h.expect(true, "the mouse reaches the inspector's ImGui ({d},{d})", .{ got[0], got[1] });
        if (waited >= 3000) return h.fail("ImGui has the mouse at {d},{d}, not {d},{d}", .{ got[0], got[1], at[0], at[1] });
        w.Sleep(100);
    }
}

/// Wait until murrtty has `count` windows of class `class`.
fn waitClassCount(h: *Harness, g: *Harness.Ghostty, comptime class: []const u8, count: usize, comptime what: []const u8) !void {
    var waited: u32 = 0;
    while (true) : (waited += 100) {
        const found = try h.windows(g, class);
        defer h.alloc.free(found);
        if (found.len == count) return h.expect(true, what, .{});
        if (waited >= 5000) return h.fail(what ++ ": {d} windows of {s}", .{ found.len, class });
        w.Sleep(100);
    }
}

const undo_binds = "keybind = ctrl+shift+f11=undo\nkeybind = ctrl+shift+f12=redo\n" ++
    "keybind = ctrl+shift+f6=close_surface\nkeybind = ctrl+shift+f9=close_window\n" ++
    "keybind = ctrl+shift+f8=close_tab:other\nkeybind = ctrl+shift+f7=close_all_windows\n" ++
    "confirm-close-surface = false\n";

/// Undo and redo of closes (roadmap 5.11), macOS's: a closed pane comes
/// back where it was, the same terminal still running, and redo closes it
/// again; a closed tab comes back at its place, and the tabs close_tab:other
/// closed come back together; a closed window comes back where it was.
/// A pane whose program ended closes for good, and a parked pane whose
/// program ends is dropped. Entries go after undo-timeout, with their
/// panes. The last window closing still quits at once, through
/// close_all_windows or the close of its only tab too (each records its
/// closes as one entry, still open as the window goes), leaking nothing.
fn undoCloses(h: *Harness) anyerror!void {
    const undo_key = w.VK_F11;
    const redo_key = w.VK_F12;
    const cs: Harness.Mods = .{ .ctrl = true, .shift = true };
    {
        var g = try start(h, "undo", "undo-timeout = 60s\n" ++ undo_binds, ">");
        defer g.deinit();
        const win = try h.mainWindow(&g);
        const a = try h.surface(&g, win);
        try splitPane(h, &g, 0, 'O');
        const b = try paneHwnd(h, &g, 1);
        try h.typeText(b, "echo undo-marker");
        h.enter(b);
        try h.waitText(&g, "undo-marker", 2, 10000);

        // A pane: closed, back where it was, the same terminal, running.
        h.key(b, cs, w.VK_F6);
        try waitPanes(h, &g, 1);
        try expectUndo(h, &g, &.{"close_terminal"}, &.{}, 1, "the closed pane is kept for undo");
        h.key(a, cs, undo_key);
        try expectPaneOrder(h, &g, &.{ a, b }, false, "undo brings the pane back on the right, the same window");
        try expectUndo(h, &g, &.{}, &.{"close_terminal"}, 0, "and redo can close it again");
        try waitPaneText(h, &g, 1, "undo-marker", 2);
        w.Sleep(200);
        const bs = clientSize(b);
        h.click(b, @divTrunc(bs[0], 2), @divTrunc(bs[1], 2), .left);
        try waitKeyboard(h, win, b, "the pane back takes a click");
        try h.typeText(b, "echo still-running");
        h.enter(b);
        try h.waitText(&g, "still-running", 2, 10000);
        h.key(b, cs, redo_key);
        try waitPanes(h, &g, 1);
        try expectUndo(h, &g, &.{"close_terminal"}, &.{}, 1, "redo closes it again, for undo once more");
        h.key(a, cs, undo_key);
        try expectPaneOrder(h, &g, &.{ a, b }, false, "and undo brings it back again");

        // A tab: back at its place, selected.
        h.key(a, cs, 'T');
        try waitWindowTabs(h, &g, win, 2);
        const c_pane = try paneHwnd(h, &g, 0);
        h.key(c_pane, cs, 'W');
        try waitWindowTabs(h, &g, win, 1);
        try expectUndo(h, &g, &.{"close_tab"}, &.{}, 1, "the closed tab is kept");
        h.key(a, cs, undo_key);
        try waitWindowTabs(h, &g, win, 2);
        try waitActiveTab(h, &g, win, 1);
        try expectTabPanes(h, &g, 0, &.{ @intFromPtr(a), @intFromPtr(c_pane) }, "undo brings the tab back second, its pane the same");

        // close_tab:other: the tabs come back together, in their places.
        h.key(c_pane, cs, 'T');
        try waitWindowTabs(h, &g, win, 3);
        const d_pane = try paneHwnd(h, &g, 0);
        h.key(d_pane, cs, w.VK_F8);
        try waitWindowTabs(h, &g, win, 1);
        try expectUndo(h, &g, &.{"close_tabs"}, &.{}, 2, "one entry for the tabs close_tab:other closed");
        h.key(d_pane, cs, undo_key);
        try waitWindowTabs(h, &g, win, 3);
        try expectTabPanes(h, &g, 0, &.{ @intFromPtr(a), @intFromPtr(c_pane), @intFromPtr(d_pane) }, "undo brings both back in their places");

        // A window: back where it was, its pane the same.
        const second = try sideWindow(h, &g, win, d_pane);
        var before: w.RECT = .{};
        _ = w.GetWindowRect(second.window, &before);
        h.key(second.pane, cs, w.VK_F9);
        try waitWindowCount(h, &g, 1);
        try expectUndo(h, &g, &.{"close_window"}, &.{}, 1, "the closed window's tab is kept");
        h.key(d_pane, cs, undo_key);
        try waitWindowCount(h, &g, 2);
        const back = try windowOf(h, &g, 1);
        try h.expect(hwndOf((try tabPanes(h, &g, 1)).at(0)) == second.pane, "undo brings the window back with its pane", .{});
        var after: w.RECT = .{};
        _ = w.GetWindowRect(back, &after);
        try h.expect(std.meta.eql(before, after), "where it was ({d},{d}-{d},{d}, was {d},{d}-{d},{d})", .{
            after.left, after.top, after.right, after.bottom, before.left, before.top, before.right, before.bottom,
        });

        // Its program ending closes the window for good.
        try h.typeText(second.pane, "exit");
        h.enter(second.pane);
        try waitWindowCount(h, &g, 1);
        try expectUndo(h, &g, &.{}, &.{"close_window"}, 0, "a pane whose program ended isn't kept");

        // A parked pane's program ending drops it.
        try splitPane(h, &g, 0, 'O');
        const e = try paneHwnd(h, &g, 1);
        try h.typeText(e, "ping -n 3 127.0.0.1 > nul & exit");
        h.enter(e);
        h.key(e, cs, w.VK_F6);
        try expectUndo(h, &g, &.{"close_terminal"}, &.{}, 1, "a pane closed while its command runs is kept");
        try expectUndoWithin(h, &g, &.{}, 0, 10000, "and dropped when its program ends");

        // close_all_windows with the last window quits at once, what undo
        // keeps freed.
        try splitPane(h, &g, 0, 'O');
        h.key(try paneHwnd(h, &g, 1), cs, w.VK_F6);
        try expectUndo(h, &g, &.{"close_terminal"}, &.{}, 1, "a pane kept before quitting");
        h.key(a, cs, w.VK_F7);
        const code = g.waitExit(10000);
        try h.expect(code != null and code.? == 0, "close_all_windows quits (exit code {?d})", .{code});
        try expectNoLeaks(h, &g, "and leaks nothing it kept");
    }
    {
        // Entries go after undo-timeout, and their panes with them.
        var g = try start(h, "undo-expiry", "undo-timeout = 1s\n" ++ undo_binds, ">");
        defer g.deinit();
        const win = try h.mainWindow(&g);
        const a = try h.surface(&g, win);
        try splitPane(h, &g, 0, 'O');
        h.key(try paneHwnd(h, &g, 1), cs, w.VK_F6);
        try waitPanes(h, &g, 1);
        try expectUndoWithin(h, &g, &.{}, 0, 5000, "after undo-timeout the close can't be undone, and the pane is freed");
        h.key(a, cs, undo_key);
        h.sync(a);
        w.Sleep(300);
        try h.expect(try paneCount(h, &g) == 1, "undo then brings nothing back", .{});
        // Closing the last window's only tab quits, leaking nothing.
        h.key(a, cs, 'W');
        const code = g.waitExit(10000);
        try h.expect(code != null and code.? == 0, "closing the only tab quits (exit code {?d})", .{code});
        try expectNoLeaks(h, &g, "and leaks nothing it kept");
    }
}

/// After murrtty exited: its Debug allocator reported no leak in its log.
fn expectNoLeaks(h: *Harness, g: *Harness.Ghostty, comptime what: []const u8) !void {
    const path = try std.fmt.allocPrint(h.alloc, "{s}\\murrtty.log", .{g.dir});
    defer h.alloc.free(path);
    const log_text = h.readFileOrNull(path) orelse return h.fail(what ++ ": no log at {s}", .{path});
    defer h.alloc.free(log_text);
    try h.expect(std.mem.indexOf(u8, log_text, "leaked") == null, what, .{});
}

/// Wait until undo's history is `undos` and `redos` (names, oldest first)
/// with `parked` tabs parked.
fn expectUndo(h: *Harness, g: *Harness.Ghostty, undos: []const []const u8, redos: []const []const u8, parked: u32, comptime what: []const u8) !void {
    var waited: u32 = 0;
    while (true) : (waited += 100) {
        var d = try h.dump(g);
        defer d.deinit();
        const u = d.value.undo;
        if (namesEql(u.undo, undos) and namesEql(u.redo, redos) and u.parked == parked) return h.expect(true, what, .{});
        if (waited >= 5000) return h.fail(what ++ ": undo {any}, redo {any}, parked {d}", .{ u.undo, u.redo, u.parked });
        w.Sleep(100);
    }
}

/// Wait up to `ms` until the undo history is `undos` with `parked` parked.
fn expectUndoWithin(h: *Harness, g: *Harness.Ghostty, undos: []const []const u8, parked: u32, ms: u32, comptime what: []const u8) !void {
    var waited: u32 = 0;
    while (true) : (waited += 100) {
        var d = try h.dump(g);
        defer d.deinit();
        const u = d.value.undo;
        if (namesEql(u.undo, undos) and u.parked == parked) return h.expect(true, what, .{});
        if (waited >= ms) return h.fail(what ++ ": undo {any}, parked {d}", .{ u.undo, u.parked });
        w.Sleep(100);
    }
}

fn namesEql(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

/// Dragging panes (roadmap 1.10), GTK's: with drag-handle auto a lone pane
/// has no handle and a split tab's panes do, showing under the mouse.
/// Pressed and dragged onto another pane, the half nearest the pointer is
/// marked (never over the pane itself) and the release moves the pane
/// there, running, the keyboard staying where it was; Escape cancels a
/// drag. Held over
/// another tab of the tab row, that tab comes forward (the pane keeps the
/// mouse) and the pane drops into it. With drag-handle always a lone pane
/// has one, and dragged into another window it leaves its own, which
/// closes.
fn paneDrag(h: *Harness) anyerror!void {
    {
        var g = try start(h, "pane-drag", "", ">");
        defer g.deinit();
        // Posted moves on the hidden desktop are followed by a real
        // WM_MOUSELEAVE, which would hide the handle at once.
        try h.pinMouse(&g, true);
        const win = try h.mainWindow(&g);
        const a = try h.surface(&g, win);
        try waitPaneState(h, &g, a, .{ .shown = false }, "a lone pane has no drag handle (drag-handle auto)");
        try splitPane(h, &g, 0, 'O');
        const b = try paneHwnd(h, &g, 1);
        try waitPaneState(h, &g, a, .{ .shown = true, .hover = false }, "a split tab's panes have one");
        try waitPaneState(h, &g, b, .{ .shown = true }, "each of them");

        // Under the mouse it shows; below it, it hides.
        const as = clientSize(a);
        h.move(a, @divTrunc(as[0], 2), 4, false);
        try waitPaneState(h, &g, a, .{ .hover = true }, "the handle shows under the mouse");
        h.move(a, @divTrunc(as[0], 2), @divTrunc(as[1], 2), false);
        try waitPaneState(h, &g, a, .{ .hover = false }, "and hides when the mouse moves on");

        // Onto the other pane's bottom half: the first pane goes below it.
        h.press(a, @divTrunc(as[0], 2), 4);
        h.move(a, @divTrunc(as[0], 2) + 20, 24, true);
        h.sync(a);
        try expectPaneDrag(h, &g, true, 0, "", "past the drag distance, a drag; over its own pane, nothing marked");
        const bs = clientSize(b);
        const below = mapPoint(b, a, .{ @divTrunc(bs[0], 2), bs[1] - 20 });
        h.move(a, below[0], below[1], true);
        try waitPaneState(h, &g, b, .{ .drop = "down" }, "over the other pane's bottom, its bottom half is marked");
        try expectPaneDrag(h, &g, true, try surfaceIdOf(h, &g, b), "down", "the drag's target");
        h.release(a, below[0], below[1]);
        try waitPaneState(h, &g, b, .{ .drop = "" }, "the mark goes with the release");
        try expectPaneOrder(h, &g, &.{ b, a }, true, "the pane moved below the other");
        try expectPaneDrag(h, &g, false, 0, "", "the drag is over");
        try waitKeyboard(h, win, b, "the keyboard stays with the pane that had it");
        // The moved pane runs on: clicked, it takes typing. Its terminal
        // takes its new size 25 ms after the pane does (termio coalesces
        // resizes), and a click at a column it doesn't have yet trips the
        // core's Debug assertion.
        w.Sleep(200);
        const am = clientSize(a);
        h.click(a, @divTrunc(am[0], 2), @divTrunc(am[1], 2), .left);
        try waitKeyboard(h, win, a, "a click gives the moved pane the keyboard");
        try h.typeText(a, "echo moved-pane");
        h.enter(a);
        try h.waitText(&g, "moved-pane", 2, 10000);

        // Escape cancels: the mark goes, later moves mark nothing, and the
        // release (which the terminal never sees) moves nothing.
        const bs2 = clientSize(b);
        h.press(b, @divTrunc(bs2[0], 2), 4);
        h.move(b, @divTrunc(bs2[0], 2) + 20, 24, true);
        const as2 = clientSize(a);
        const low = mapPoint(a, b, .{ @divTrunc(as2[0], 2), as2[1] - 10 });
        h.move(b, low[0], low[1], true);
        try waitPaneState(h, &g, a, .{ .drop = "down" }, "the top pane dragged over the bottom one marks it");
        const keys = try paneKeys(h, &g, b);
        h.key(b, .{}, w.VK_ESCAPE);
        try waitPaneState(h, &g, a, .{ .drop = "" }, "Escape takes the mark away");
        h.move(b, low[0] + 10, low[1], true);
        h.sync(b);
        try waitPaneState(h, &g, a, .{ .drop = "" }, "and a move after it marks nothing");
        h.release(b, low[0], low[1]);
        h.sync(b);
        try expectPaneDrag(h, &g, false, 0, "", "the release ends the cancelled drag");
        try expectPaneOrder(h, &g, &.{ b, a }, true, "nothing moved");
        try h.expect(try paneKeys(h, &g, b) == keys, "Escape's press and release never reached the terminal", .{});

        // Over another tab: it comes forward, and the pane drops into it.
        h.key(a, .{ .ctrl = true, .shift = true }, 'T');
        try waitWindowTabs(h, &g, win, 2);
        try waitActiveTab(h, &g, win, 1);
        const other = try paneHwnd(h, &g, 0);
        const t0 = try tabMid(h, &g, 0, 0);
        h.press(win, t0[0], t0[1]);
        h.release(win, t0[0], t0[1]);
        try waitActiveTab(h, &g, win, 0);
        try waitPaneState(h, &g, b, .{ .dimmed = true }, "the pane beside the focused one is dimmed");
        const as3 = clientSize(a);
        h.press(a, @divTrunc(as3[0], 2), 4);
        h.move(a, @divTrunc(as3[0], 2) + 20, 24, true);
        const t1 = try tabMid(h, &g, 0, 1);
        const over = mapPoint(win, a, .{ t1[0], t1[1] });
        h.move(a, over[0], over[1], true);
        try waitActiveTab(h, &g, win, 1);
        try expectPaneDrag(h, &g, true, 0, "", "the drag goes on with the tab come forward");
        try h.expect(captureOf(a) == a, "the dragged pane keeps the mouse, its tab behind", .{});
        const os = clientSize(other);
        const right = mapPoint(other, a, .{ os[0] - 20, @divTrunc(os[1], 2) });
        h.move(a, right[0], right[1], true);
        try waitPaneState(h, &g, other, .{ .drop = "right" }, "over the other tab's pane, its right half is marked");
        h.release(a, right[0], right[1]);
        try expectPaneOrder(h, &g, &.{ other, a }, false, "the pane joined the other tab, on the right");
        try expectTabPanes(h, &g, 0, &.{ @intFromPtr(b), @intFromPtr(other) }, "its old tab keeps the pane left behind");
        try waitPaneState(h, &g, b, .{ .dimmed = false }, "left alone, that pane is dimmed no more");
        try waitPaneState(h, &g, a, .{ .dimmed = true }, "the moved pane is, its new tab's focus elsewhere");
        try waitPaneState(h, &g, other, .{ .dimmed = false }, "and that focused pane isn't");
        try waitKeyboard(h, win, other, "the new tab's pane keeps the keyboard");
        try quit(h, &g, a);
    }
    {
        var g = try start(h, "pane-drag-window", "drag-handle = always\n", ">");
        defer g.deinit();
        try h.pinMouse(&g, true);
        const win = try h.mainWindow(&g);
        const a = try h.surface(&g, win);
        try waitPaneState(h, &g, a, .{ .shown = true }, "with drag-handle always, a lone pane has a handle");
        h.key(a, .{ .ctrl = true, .shift = true }, 'N');
        try waitWindowCount(h, &g, 2);
        const win2 = try windowOf(h, &g, 1);
        const moved = hwndOf((try tabPanes(h, &g, 1)).at(0));
        // Side by side, so the first window's pane is under the drop.
        var r1: w.RECT = .{};
        _ = w.GetWindowRect(win, &r1);
        _ = w.SetWindowPos(win2, null, r1.right + 40, r1.top, 0, 0, w.SWP_NOSIZE | w.SWP_NOZORDER | w.SWP_NOACTIVATE);
        h.sync(win2);
        const ms = clientSize(moved);
        h.press(moved, @divTrunc(ms[0], 2), 4);
        h.move(moved, @divTrunc(ms[0], 2) + 20, 24, true);
        const as = clientSize(a);
        const left = mapPoint(a, moved, .{ 20, @divTrunc(as[1], 2) });
        h.move(moved, left[0], left[1], true);
        try waitPaneState(h, &g, a, .{ .drop = "left" }, "over the other window's pane, its left half is marked");
        h.release(moved, left[0], left[1]);
        try waitWindowGone(h, &g, win2);
        try expectPaneOrder(h, &g, &.{ moved, a }, false, "the pane moved into the first window, on the left");
        w.Sleep(200);
        const mm = clientSize(moved);
        h.click(moved, @divTrunc(mm[0], 2), @divTrunc(mm[1], 2), .left);
        try waitKeyboard(h, win, moved, "a click gives the moved pane the keyboard");
        try h.typeText(moved, "echo moved-window");
        h.enter(moved);
        try h.waitText(&g, "moved-window", 2, 10000);
        try quit(h, &g, a);
    }
    {
        // Windows closing mid-drag (1.10's review): the target's leaves the
        // drag over nothing; the source's, here its second tab, ends it.
        // The window frees its tabs one by one, and the drag once looked
        // panes up in the freed ones.
        var g = try start(h, "pane-drag-close", "drag-handle = always\nconfirm-close-surface = false\n", ">");
        defer g.deinit();
        try h.pinMouse(&g, true);
        const win = try h.mainWindow(&g);
        const a = try h.surface(&g, win);
        const target = try sideWindow(h, &g, win, a);
        const as = clientSize(a);
        h.press(a, @divTrunc(as[0], 2), 4);
        h.move(a, @divTrunc(as[0], 2) + 20, 24, true);
        const ts = clientSize(target.pane);
        const over = mapPoint(target.pane, a, .{ 20, @divTrunc(ts[1], 2) });
        h.move(a, over[0], over[1], true);
        try waitPaneState(h, &g, target.pane, .{ .drop = "left" }, "dragged over the other window's pane");
        _ = w.PostMessageW(target.window, w.WM_CLOSE, 0, 0);
        try waitWindowCount(h, &g, 1);
        try expectPaneDrag(h, &g, true, 0, "", "its window closed, the drag goes on over nothing");
        h.release(a, over[0], over[1]);
        try expectPaneDrag(h, &g, false, 0, "", "and the release ends it");

        const source = try sideWindow(h, &g, win, a);
        h.key(source.pane, .{ .ctrl = true, .shift = true }, 'T');
        try waitWindowTabs(h, &g, source.window, 2);
        const second = hwndOf((try tabPanes(h, &g, 1)).at(1));
        const ss = clientSize(second);
        h.press(second, @divTrunc(ss[0], 2), 4);
        h.move(second, @divTrunc(ss[0], 2) + 20, 24, true);
        const onto = mapPoint(a, second, .{ 20, @divTrunc(as[1], 2) });
        h.move(second, onto[0], onto[1], true);
        try waitPaneState(h, &g, a, .{ .drop = "left" }, "the second window's second tab's pane dragged over the first window's");
        _ = w.PostMessageW(source.window, w.WM_CLOSE, 0, 0);
        try waitWindowCount(h, &g, 1);
        try expectPaneDrag(h, &g, false, 0, "", "its window closed, the drag is over");
        try waitPaneState(h, &g, a, .{ .drop = "" }, "and its mark gone");
        h.key(a, .{ .ctrl = true, .shift = true }, 'Q');
        const code = g.waitExit(10000);
        try h.expect(code != null and code.? == 0, "exits with code 0 after quit (got {?d})", .{code});
    }
}

/// A new window (Ctrl+Shift+N from `from`) moved to the right of `win`, so
/// neither covers the other, and its pane.
fn sideWindow(h: *Harness, g: *Harness.Ghostty, win: w.HWND, from: w.HWND) !struct { window: w.HWND, pane: w.HWND } {
    h.key(from, .{ .ctrl = true, .shift = true }, 'N');
    try waitWindowCount(h, g, 2);
    const window = try windowOf(h, g, 1);
    var r: w.RECT = .{};
    _ = w.GetWindowRect(win, &r);
    _ = w.SetWindowPos(window, null, r.right + 40, r.top, 0, 0, w.SWP_NOSIZE | w.SWP_NOZORDER | w.SWP_NOACTIVATE);
    h.sync(window);
    return .{ .window = window, .pane = hwndOf((try tabPanes(h, g, 1)).at(0)) };
}

/// The key events `pane` has passed to its terminal.
fn paneKeys(h: *Harness, g: *Harness.Ghostty, pane: w.HWND) !u32 {
    var d = try h.dump(g);
    defer d.deinit();
    const p = findPane(d.value, pane) orelse return h.fail("no such pane", .{});
    return p.keys orelse 0;
}

const PaneWant = struct { shown: ?bool = null, hover: ?bool = null, drop: ?[]const u8 = null, dimmed: ?bool = null };

fn findPane(d: Harness.Dump, pane: w.HWND) ?Harness.Dump.Pane {
    for (d.windows) |win| for (win.tabs) |t| if (t.panes) |ps| for (ps) |p| {
        if (hwndOf(p.hwnd) == pane) return p;
    };
    return null;
}

/// Wait until `pane`'s drag handle and drop mark are as `want` says.
fn waitPaneState(h: *Harness, g: *Harness.Ghostty, pane: w.HWND, want: PaneWant, comptime what: []const u8) !void {
    var waited: u32 = 0;
    while (true) : (waited += 100) {
        var d = try h.dump(g);
        defer d.deinit();
        const p = findPane(d.value, pane) orelse return h.fail(what ++ ": no such pane", .{});
        const ok = (want.shown == null or want.shown.? == p.handle.shown) and
            (want.hover == null or want.hover.? == p.handle.hover) and
            (want.drop == null or std.mem.eql(u8, want.drop.?, p.drop)) and
            (want.dimmed == null or want.dimmed.? == p.dimmed);
        if (ok) return h.expect(true, what, .{});
        if (waited >= 3000) return h.fail(what ++ ": handle shown {}, hover {}, drop \"{s}\", dimmed {}", .{ p.handle.shown, p.handle.hover, p.drop, p.dimmed });
        w.Sleep(100);
    }
}

/// Wait until a pane's drag is `active` (or not), with `target` (a surface
/// id, 0 for none) and `dir` while it is.
fn expectPaneDrag(h: *Harness, g: *Harness.Ghostty, active: bool, target: u64, dir: []const u8, comptime what: []const u8) !void {
    var waited: u32 = 0;
    while (true) : (waited += 100) {
        var d = try h.dump(g);
        defer d.deinit();
        const pd = d.value.pane_drag;
        const ok = pd.active == active and (!active or (pd.dragging and pd.target == target and std.mem.eql(u8, pd.dir, dir)));
        if (ok) return h.expect(true, what, .{});
        if (waited >= 3000) return h.fail(what ++ ": active {}, dragging {}, target {d}, dir \"{s}\"", .{ pd.active, pd.dragging, pd.target, pd.dir });
        w.Sleep(100);
    }
}

/// Wait until the first window's active tab has the panes `want`, in
/// layout order, side by side (or one above the other when `vertical`).
fn expectPaneOrder(h: *Harness, g: *Harness.Ghostty, want: []const w.HWND, vertical: bool, comptime what: []const u8) !void {
    var waited: u32 = 0;
    while (true) : (waited += 100) {
        var d = try h.dump(g);
        defer d.deinit();
        const dw = d.value.windows[0];
        const ps = dw.tabs[dw.active].panes orelse &.{};
        const same = ps.len == want.len and for (ps, want) |p, v| {
            if (hwndOf(p.hwnd) != v) break false;
        } else true;
        const placed = same and for (ps[1..], ps[0 .. ps.len - 1]) |p, prev| {
            if (if (vertical) p.rect[1] < prev.rect[3] else p.rect[0] < prev.rect[2]) break false;
        } else true;
        if (placed) return h.expect(true, what, .{});
        if (waited >= 3000) {
            var got: [8]u64 = undefined;
            const n = @min(ps.len, got.len);
            for (ps[0..n], 0..) |p, i| got[i] = p.hwnd;
            return h.fail(what ++ ": the tab's panes are {any} (in order: {}), not {any}", .{ got[0..n], same, want });
        }
        w.Sleep(100);
    }
}

fn surfaceIdOf(h: *Harness, g: *Harness.Ghostty, pane: w.HWND) !u64 {
    var d = try h.dump(g);
    defer d.deinit();
    const p = findPane(d.value, pane) orelse return h.fail("no such pane", .{});
    return p.surface_id;
}

fn clientSize(hwnd: w.HWND) [2]i32 {
    var r: w.RECT = .{};
    _ = w.GetClientRect(hwnd, &r);
    return .{ r.right, r.bottom };
}

/// The window holding the mouse in `hwnd`'s thread.
fn captureOf(hwnd: w.HWND) ?w.HWND {
    var info: w.GUITHREADINFO = .{};
    if (w.GetGUIThreadInfo(w.GetWindowThreadProcessId(hwnd, null), &info) == 0) return null;
    return info.hwndCapture;
}

/// Window options macOS has and GTK lacks (roadmap 4.6): window-position-x
/// and -y put each new window's visible frame there; the float binding
/// keeps the window above others and lets it go; reset_window_size brings
/// back the grid the window opened with; window-step-resize leaves a
/// dragged window in whole cells (a step short of a cell keeps the size, a
/// cell and a bit adds one), and without it the window takes any size.
fn windowOptions(h: *Harness) anyerror!void {
    const binds = "keybind = ctrl+shift+f7=toggle_window_float_on_top\nkeybind = ctrl+shift+f8=reset_window_size\nkeybind = ctrl+shift+f9=increase_font_size:2\n";
    {
        // No padding, so whole cells fill the pane exactly.
        const config = "window-position-x = 200\nwindow-position-y = 150\nwindow-step-resize = true\n" ++
            "window-padding-x = 0\nwindow-padding-y = 0\nwindow-width = 90\nwindow-height = 26\n" ++ binds;
        var g = try start(h, "window-options", config, ">");
        defer g.deinit();
        const win = try h.mainWindow(&g);
        const surf = try h.surface(&g, win);
        // What reset_window_size comes back to.
        const opening = try gridOf(h, &g);
        try h.expect(opening[0] == 90 and opening[1] == 26, "it opens at window-width x -height ({d}x{d})", .{ opening[0], opening[1] });
        try expectVisibleAt(h, win, 200, 150, "the window's frame is at window-position-x, -y");
        h.key(surf, .{ .ctrl = true, .shift = true }, 'N');
        try waitWindowCount(h, &g, 2);
        try expectVisibleAt(h, try windowOf(h, &g, 1), 200, 150, "and so is the next window's, as on macOS");

        h.key(surf, .{ .ctrl = true, .shift = true }, w.VK_F7);
        try expectFloating(h, &g, win, true);
        h.key(surf, .{ .ctrl = true, .shift = true }, w.VK_F7);
        try expectFloating(h, &g, win, false);

        // Step resizing, on the first window: a step short of a cell keeps
        // its size, a cell and a bit grows it by a cell.
        const cell = try cellOf(h, &g);
        try h.dragResize(&g, 0, 0);
        const p0 = try paneSize(h, &g, 0);
        try h.expect(@mod(p0[0], cell[0]) == 0 and @mod(p0[1], cell[1]) == 0, "with window-step-resize, a drag leaves whole cells ({d}x{d}, cell {d}x{d})", .{ p0[0], p0[1], cell[0], cell[1] });
        try h.dragResize(&g, @intCast(cell[0] - 1), @intCast(cell[1] - 1));
        const p1 = try paneSize(h, &g, 0);
        try h.expect(p1[0] == p0[0] and p1[1] == p0[1], "a drag short of a cell keeps the size ({d}x{d}, was {d}x{d})", .{ p1[0], p1[1], p0[0], p0[1] });
        try h.dragResize(&g, @intCast(cell[0] + 2), @intCast(cell[1] + 2));
        const p2 = try paneSize(h, &g, 0);
        try h.expect(p2[0] == p0[0] + cell[0] and p2[1] == p0[1] + cell[1], "a cell and a bit adds a cell ({d}x{d}, cell {d}x{d})", .{ p2[0] - p0[0], p2[1] - p0[1], cell[0], cell[1] });

        // reset_window_size: the grid it opened with, also after the font
        // grows (the size is worked out again for it).
        try h.dragResize(&g, 160, 120);
        try h.expect(!std.meta.eql(try gridOf(h, &g), opening), "dragged larger, the grid grows", .{});
        h.key(surf, .{ .ctrl = true, .shift = true }, w.VK_F8);
        try expectGrid(h, &g, opening, "reset_window_size");
        h.key(surf, .{ .ctrl = true, .shift = true }, w.VK_F9);
        h.sync(surf);
        w.Sleep(300);
        try h.expect(!std.meta.eql(try gridOf(h, &g), opening), "a larger font fits fewer cells", .{});
        h.key(surf, .{ .ctrl = true, .shift = true }, w.VK_F8);
        try expectGrid(h, &g, opening, "reset_window_size after the font grew");
        try quit(h, &g, surf);
    }
    {
        var g = try start(h, "window-options-free", "", ">");
        defer g.deinit();
        try h.dragResize(&g, 0, 0);
        const p0 = try paneSize(h, &g, 0);
        try h.dragResize(&g, 3, 2);
        const p1 = try paneSize(h, &g, 0);
        try h.expect(p1[0] == p0[0] + 3 and p1[1] == p0[1] + 2, "without it the window takes the size dragged to (+{d},+{d})", .{ p1[0] - p0[0], p1[1] - p0[1] });
        try quit(h, &g, try h.surface(&g, try h.mainWindow(&g)));
    }
}

/// Expect `win`'s visible frame (DWM's, inside the resize border) at
/// (`x`, `y`).
fn expectVisibleAt(h: *Harness, win: w.HWND, x: i32, y: i32, comptime what: []const u8) !void {
    var r: w.RECT = .{};
    if (w.DwmGetWindowAttribute(win, w.DWMWA_EXTENDED_FRAME_BOUNDS, &r, @sizeOf(w.RECT)) < 0) _ = w.GetWindowRect(win, &r);
    try h.expect(@abs(r.left - x) <= 1 and @abs(r.top - y) <= 1, what ++ " ({d},{d})", .{ r.left, r.top });
}

/// Wait until the first window's floating state is `on`. Windows makes a
/// window topmost only for a process with foreground rights, which murrtty
/// has when its binding is pressed but never on the hidden desktop, so the
/// window style is reported, not checked.
fn expectFloating(h: *Harness, g: *Harness.Ghostty, win: w.HWND, on: bool) !void {
    var waited: u32 = 0;
    while (waited <= 3000) : (waited += 100) {
        var d = try h.dump(g);
        defer d.deinit();
        if (d.value.windows[0].floating == on) {
            const topmost = w.GetWindowLongPtrW(win, w.GWL_EXSTYLE) & w.WS_EX_TOPMOST != 0;
            return h.expect(true, "the float binding turns floating {s} (topmost style here: {})", .{ if (on) "on" else "off", topmost });
        }
        w.Sleep(100);
    }
    return h.fail("floating isn't {}", .{on});
}

/// The first tab's cell size.
fn cellOf(h: *Harness, g: *Harness.Ghostty) ![2]i32 {
    var d = try h.dump(g);
    defer d.deinit();
    const cell = d.value.windows[0].tabs[0].cell orelse return h.fail("no cell size", .{});
    return .{ @intCast(cell[0]), @intCast(cell[1]) };
}

/// Window `wi`'s first pane's size, once its pane has the window's new size.
fn paneSize(h: *Harness, g: *Harness.Ghostty, wi: usize) ![2]i32 {
    var d = try h.dump(g);
    defer d.deinit();
    const r = (d.value.windows[wi].tabs[0].panes orelse return h.fail("no panes", .{}))[0].rect;
    return .{ r[2] - r[0], r[3] - r[1] };
}

/// Wait until window `gone` is no longer among Ghostty's windows.
fn waitWindowGone(h: *Harness, g: *Harness.Ghostty, gone: w.HWND) !void {
    var waited: u32 = 0;
    while (waited <= 5000) : (waited += 100) {
        var d = try h.dump(g);
        defer d.deinit();
        const there = for (d.value.windows) |win| {
            if (hwndOf(win.hwnd) == gone) break true;
        } else false;
        if (!there) return h.expect(true, "a window its last tab leaves closes", .{});
        w.Sleep(100);
    }
    return h.fail("the window its last tab left is still there", .{});
}

/// A tab closing during a drag (roadmap 4.5 review): the drag goes on with
/// the tab pressed, found where it is now, rather than by its old place
/// (which, past the end, crashed the release build). Closes without
/// asking here (confirm-close-surface = false), by a middle click on
/// another tab while the left button is held.
fn tabDragClose(h: *Harness) anyerror!void {
    var g = try start(h, "tab-drag-close", "window-show-tab-bar = always\nconfirm-close-surface = false\n", ">");
    defer g.deinit();
    const win = try h.mainWindow(&g);
    const surf = try h.surface(&g, win);
    h.key(surf, .{ .ctrl = true, .shift = true }, 'T');
    try waitWindowTabs(h, &g, win, 2);
    h.key(surf, .{ .ctrl = true, .shift = true }, 'T');
    try waitWindowTabs(h, &g, win, 3);
    const o = try tabPanes(h, &g, 0);

    // The third tab pressed and moved a little, the first closed under it.
    const third = try tabMid(h, &g, 0, 2);
    h.press(win, third[0], third[1]);
    h.move(win, third[0] - 12, third[1], true);
    const first = try tabMid(h, &g, 0, 0);
    _ = w.PostMessageW(win, w.WM_MBUTTONUP, w.MK_LBUTTON, w.makeLParam(first[0], first[1]));
    try expectTabPanes(h, &g, 0, &.{ o.at(1), o.at(2) }, "a middle click closes a tab while another is dragged");
    // On over the one left before it: the dragged tab takes its place.
    const over = try tabMid(h, &g, 0, 0);
    h.move(win, over[0] - 4, over[1], true);
    h.release(win, over[0] - 4, over[1]);
    h.sync(win);
    try expectTabPanes(h, &g, 0, &.{ o.at(2), o.at(1) }, "the drag goes on with the tab pressed, now second, and moves it first");
    // Nothing to confirm here; the first tab's pane is gone.
    h.key(hwndOf(o.at(2)), .{ .ctrl = true, .shift = true }, 'Q');
    const code = g.waitExit(10000);
    try h.expect(code != null and code.? == 0, "exits with code 0 after quit (got {?d})", .{code});
}

const TabPanes = struct {
    items: [8]u64 = @splat(0),
    len: usize = 0,
    fn at(self: TabPanes, i: usize) u64 {
        return self.items[i];
    }
};

/// Window `wi`'s tabs, as their first panes' window handles.
fn tabPanes(h: *Harness, g: *Harness.Ghostty, wi: usize) !TabPanes {
    var d = try h.dump(g);
    defer d.deinit();
    if (wi >= d.value.windows.len) return h.fail("no window {d}", .{wi});
    var out: TabPanes = .{};
    for (d.value.windows[wi].tabs) |t| {
        if (out.len == out.items.len) break;
        out.items[out.len] = (t.panes orelse return h.fail("a tab without panes", .{}))[0].hwnd;
        out.len += 1;
    }
    return out;
}

/// Wait until window `wi`'s tabs are `want` (first panes, in order).
fn expectTabPanes(h: *Harness, g: *Harness.Ghostty, wi: usize, want: []const u64, comptime what: []const u8) !void {
    var waited: u32 = 0;
    while (waited <= 3000) : (waited += 100) {
        const got = tabPanes(h, g, wi) catch null;
        if (got) |t| if (t.len == want.len and std.mem.eql(u64, t.items[0..t.len], want)) return h.expect(true, what, .{});
        w.Sleep(100);
    }
    const got = try tabPanes(h, g, wi);
    return h.fail(what ++ ": the tabs' panes are {any}, not {any}", .{ got.items[0..got.len], want });
}

/// Wait until window `wi` has `count` tabs.
fn waitTabCount(h: *Harness, g: *Harness.Ghostty, wi: usize, count: usize) !void {
    var waited: u32 = 0;
    while (waited <= 3000) : (waited += 100) {
        const t = tabPanes(h, g, wi) catch null;
        if (t) |v| if (v.len == count) return;
        w.Sleep(100);
    }
    return h.fail("window {d} doesn't have {d} tabs", .{ wi, count });
}

fn windowHasPane(h: *Harness, g: *Harness.Ghostty, wi: usize, pane: u64) !bool {
    const t = try tabPanes(h, g, wi);
    return std.mem.indexOfScalar(u64, t.items[0..t.len], pane) != null;
}

/// The middle of tab `ti` of window `wi`, in its client coordinates.
fn tabMid(h: *Harness, g: *Harness.Ghostty, wi: usize, ti: usize) ![2]i32 {
    var d = try h.dump(g);
    defer d.deinit();
    const strip = d.value.windows[wi].tab_bar.tabs;
    if (ti >= strip.len) return h.fail("no tab {d} in the strip", .{ti});
    return rectMid(strip[ti].rect);
}

fn windowOf(h: *Harness, g: *Harness.Ghostty, wi: usize) !w.HWND {
    var d = try h.dump(g);
    defer d.deinit();
    if (wi >= d.value.windows.len) return h.fail("no window {d}", .{wi});
    return hwndOf(d.value.windows[wi].hwnd);
}

/// The frames pane `pane` has presented.
fn paneFrames(h: *Harness, g: *Harness.Ghostty, pane: w.HWND) !u32 {
    var d = try h.dump(g);
    defer d.deinit();
    for (d.value.windows) |win| for (win.tabs) |t| if (t.panes) |ps| for (ps) |p| {
        if (hwndOf(p.hwnd) == pane) return p.frames orelse 0;
    };
    return h.fail("no such pane", .{});
}
const toggle_decorations = "keybind = ctrl+shift+f4=toggle_window_decorations\n";

/// window-decoration = none (roadmap 4.4): no caption and no header bar,
/// the client reaching the window's top; its top resize band still
/// answers HTTOP, passed on by the pane and its tab, and the rest of the
/// pane stays the pane's. toggle_window_decorations, per window as GTK's:
/// none to auto (the header bar) and back, anything else to none and back,
/// the grid unchanged each time.
fn decorations(h: *Harness) anyerror!void {
    {
        var g = try start(h, "decorations-none", "window-decoration = none\n" ++ toggle_decorations, ">");
        defer g.deinit();
        const win = try h.mainWindow(&g);
        const surf = try h.surface(&g, win);
        try expectDecoration(h, &g, "none", true, false);
        var wr: w.RECT = .{};
        _ = w.GetWindowRect(win, &wr);
        var origin: w.POINT = .{};
        _ = w.ClientToScreen(win, &origin);
        try h.expect(origin.y == wr.top, "the client starts at the window's top ({d}, the window {d})", .{ origin.y, wr.top });
        const tab = w.GetParent(surf) orelse return h.fail("the pane has no tab", .{});
        // At (40, 2) of the window's client, then (40, 60).
        try expectNcHit(h, surf, mapPoint(win, surf, .{ 40, 2 }), w.HTTRANSPARENT, "the pane passes the top band on");
        try expectNcHit(h, tab, mapPoint(win, tab, .{ 40, 2 }), w.HTTRANSPARENT, "and its tab");
        try expectNcHit(h, win, .{ 40, 2 }, w.HTTOP, "where the window resizes from the top");
        try expectNcHit(h, surf, mapPoint(win, surf, .{ 40, 60 }), w.HTCLIENT, "below it the pane is the pane's");
        const grid = try gridOf(h, &g);
        h.key(surf, .{ .ctrl = true, .shift = true }, w.VK_F4);
        try expectDecoration(h, &g, "auto", true, true);
        try expectGrid(h, &g, grid, "toggled to auto");
        h.key(surf, .{ .ctrl = true, .shift = true }, w.VK_F4);
        try expectDecoration(h, &g, "none", true, false);
        try expectGrid(h, &g, grid, "and back to none");

        // A second tab brings the tab row as the top bar: the band is the
        // window's own there, the rest of the row the row's; the palette's
        // dimming leaves the band to the window.
        h.key(surf, .{ .ctrl = true, .shift = true }, 'T');
        try waitWindowTabs(h, &g, win, 2);
        try expectNcHit(h, win, .{ 40, 2 }, w.HTTOP, "with a tab row the window still resizes from its top");
        try expectNcHit(h, win, .{ 40, 20 }, w.HTCLIENT, "below the band the tab row is the row's");
        h.key(try h.surface(&g, win), .{ .ctrl = true, .shift = true }, 'P');
        const p = try waitPalette(h, &g, win, true);
        try h.expect(hitTestAt(hwndOf(p.dim), win, .{ 40, 2 }) == w.HTTRANSPARENT, "the palette's dimming leaves the band to the window", .{});
        h.key(hwndOf(p.edit), .{}, w.VK_ESCAPE);
        _ = try waitPalette(h, &g, win, false);
        try quit(h, &g, surf);
    }
    inline for ([_]struct { []const u8, []const u8, bool, bool }{
        .{ "decorations-auto", "", true, true },
        .{ "decorations-server", "window-decoration = server\n", false, false },
    }) |case| {
        var g = try start(h, case[0], toggle_decorations ++ case[1], ">");
        defer g.deinit();
        const surf = try h.surface(&g, try h.mainWindow(&g));
        const own = if (case[1].len == 0) "auto" else "server";
        try expectDecoration(h, &g, own, case[2], case[3]);
        const grid = try gridOf(h, &g);
        h.key(surf, .{ .ctrl = true, .shift = true }, w.VK_F4);
        try expectDecoration(h, &g, "none", true, false);
        try expectGrid(h, &g, grid, "toggled to none");
        h.key(surf, .{ .ctrl = true, .shift = true }, w.VK_F4);
        try expectDecoration(h, &g, own, case[2], case[3]);
        try expectGrid(h, &g, grid, "and back");
        try quit(h, &g, surf);
    }
}

/// `pt` in `from`'s client coordinates, in `to`'s.
fn mapPoint(from: w.HWND, to: w.HWND, pt: [2]i32) [2]i32 {
    var p = [1]w.POINT{.{ .x = pt[0], .y = pt[1] }};
    _ = w.MapWindowPoints(from, to, &p, 1);
    return .{ p[0].x, p[0].y };
}

/// Wait until the first window's decoration, frame and header bar are as
/// given.
fn expectDecoration(h: *Harness, g: *Harness.Ghostty, decoration: []const u8, captionless: bool, header: bool) !void {
    var waited: u32 = 0;
    while (true) : (waited += 100) {
        var d = try h.dump(g);
        defer d.deinit();
        const win = d.value.windows[0];
        if (std.mem.eql(u8, win.decoration, decoration) and win.captionless == captionless and win.header.visible == header) {
            return h.expect(true, "decoration {s}: captionless {}, header bar {}", .{ decoration, captionless, header });
        }
        if (waited >= 3000) return h.fail("decoration {s}, captionless {}, header bar {}; wanted {s}, {}, {}", .{
            win.decoration, win.captionless, win.header.visible, decoration, captionless, header,
        });
        w.Sleep(100);
    }
}

/// Wait until the first tab's grid is `want` again.
fn expectGrid(h: *Harness, g: *Harness.Ghostty, want: [2]u32, comptime what: []const u8) !void {
    var got: [2]u32 = .{ 0, 0 };
    var waited: u32 = 0;
    while (waited <= 3000) : (waited += 100) {
        got = try gridOf(h, g);
        if (got[0] == want[0] and got[1] == want[1]) return h.expect(true, what ++ ": the grid stays {d}x{d}", .{ want[0], want[1] });
        w.Sleep(100);
    }
    return h.fail(what ++ ": the grid is {d}x{d}, not {d}x{d}", .{ got[0], got[1], want[0], want[1] });
}

/// background-opacity below 1 makes the windows translucent (roadmap 4.1,
/// Phase A). Each pane presents its background at the opacity's alpha,
/// premultiplied as DWM composes it (read back from the renderer); the
/// header bar and a split's divider, which GDI paints, stay opaque, and
/// what the panes don't cover yet takes the background's alpha (read back
/// from their paint, alpha included). A pane split off presents so too
/// (its renderer takes it up as it starts; the unfocused pane's dimming,
/// composed over the background, is off here). toggle_background_opacity
/// makes every window opaque and back, a window opened meanwhile
/// following; a reload to an opacity of 1 makes them opaque, and the
/// toggle then does nothing. What the display shows is the `transparency`
/// scenario's.
fn translucent(h: *Harness) anyerror!void {
    const bg: u32 = 0x282c34;
    // The background at alpha 128, premultiplied.
    const half: u32 = 0x14161a;
    const config = "background-opacity = 0.5\nunfocused-split-opacity = 1\n" ++ toggle_opacity;
    var g = try start(h, "translucent", config, ">");
    defer g.deinit();
    const win = try h.mainWindow(&g);
    const surf = try h.surface(&g, win);
    try expectTranslucent(h, &g, &.{true});
    try expectFrameBackground(h, &g, 0, half, 0x80);

    h.key(surf, .{ .ctrl = true, .shift = true }, 'O');
    try waitPanes(h, &g, 2);
    try expectFrameBackground(h, &g, 1, half, 0x80);
    try h.saveChrome(&g);
    {
        var chrome = try h.loadPicture(&g, "chrome-0.bmp");
        defer chrome.deinit();
        for ([_][2]usize{ .{ 1, 1 }, .{ chrome.width / 2, chrome.height / 2 }, .{ chrome.width - 2, chrome.height - 2 } }) |p| {
            const px = chrome.argb(p[0], p[1]);
            try h.expect(px >> 24 == 0xff, "the header bar is opaque at ({d},{d}) (#{x:0>8})", .{ p[0], p[1], px });
        }
        var tab = try h.loadPicture(&g, "tab-0.bmp");
        defer tab.deinit();
        var d = try h.dump(&g);
        defer d.deinit();
        const t = d.value.windows[0].tabs[0];
        const dv = (t.dividers orelse return h.fail("no divider", .{}))[0];
        const color: u32 = @intCast(t.divider_color orelse return h.fail("no divider color", .{}));
        // Halfway down, clear of the bars' shade at its top.
        const line = tab.argb(@intCast(@divTrunc(dv[0] + dv[2], 2)), @intCast(@divTrunc(dv[1] + dv[3], 2)));
        try h.expect(line >> 24 == 0xff and line & 0xffffff == color, "the divider is opaque #{x:0>6} (#{x:0>8})", .{ color, line });
        const under = tab.argb(10, tab.height - 10);
        try h.expect(under >> 24 == 0x80 and near(under & 0xffffff, half, 1), "what the panes don't cover has the background's alpha (#{x:0>8})", .{under});
    }

    // Opaque, then translucent again; a window opened while opaque follows.
    h.key(surf, .{ .ctrl = true, .shift = true }, w.VK_F3);
    try expectTranslucent(h, &g, &.{false});
    try expectFrameBackground(h, &g, 0, bg, 0xff);
    h.key(surf, .{ .ctrl = true, .shift = true }, 'N');
    try waitWindowCount(h, &g, 2);
    try expectTranslucent(h, &g, &.{ false, false });
    // The new window's pane, after the first window's two.
    try expectFrameBackground(h, &g, 2, bg, 0xff);
    h.key(surf, .{ .ctrl = true, .shift = true }, w.VK_F3);
    try expectTranslucent(h, &g, &.{ true, true });
    try expectFrameBackground(h, &g, 0, half, 0x80);
    try expectFrameBackground(h, &g, 2, half, 0x80);

    // A reload to an opacity of 1; the toggle then does nothing.
    const cfg_path = try std.fmt.allocPrint(h.alloc, "{s}\\translucent\\murrtty\\config.ghostty", .{h.temp_dir});
    defer h.alloc.free(cfg_path);
    try h.writeFileAt(cfg_path, base_config ++ "unfocused-split-opacity = 1\n" ++ toggle_opacity);
    h.key(surf, .{ .ctrl = true, .shift = true }, w.VK_OEM_COMMA);
    try expectTranslucent(h, &g, &.{ false, false });
    h.key(surf, .{ .ctrl = true, .shift = true }, w.VK_F3);
    w.Sleep(300);
    try expectTranslucent(h, &g, &.{ false, false });
    try expectFrameBackground(h, &g, 0, bg, 0xff);
    try quit(h, &g, surf);
}

/// background-blur on a translucent window (roadmap 4.2): Acrylic, DWM's
/// system backdrop, from Windows 11 22H2 (build 22621, DWM reporting it),
/// before it the accent policy's blur (which the test hooks can force
/// here, and then hand back); none while toggled opaque, with
/// background-blur off or at an opacity of 1; a new window takes it up.
/// What it looks like is for the display (`transparency`'s owner).
fn blurScenario(h: *Harness) anyerror!void {
    const build = Harness.windowsBuild();
    h.log("Windows build {d}: active {s}, inactive {s}", .{ build, nativeBlur(build, true), nativeBlur(build, false) });
    const native = "native";
    const config = "background-opacity = 0.5\nbackground-blur = true\n" ++ toggle_opacity;
    var g = try start(h, "blur", config, ">");
    defer g.deinit();
    const win = try h.mainWindow(&g);
    const surf = try h.surface(&g, win);
    try expectBlur(h, &g, &.{native});

    // Windows draws Acrylic solid in an inactive window: there the accent
    // policy's blur, as WM_NCACTIVATE tells the window.
    if (build >= 22621) {
        for ([_]struct { usize, []const u8 }{ .{ 0, "accent" }, .{ 1, "backdrop" } }) |step| {
            var result: usize = 0;
            _ = w.SendMessageTimeoutW(win, w.WM_NCACTIVATE, step[0], 0, w.SMTO_ABORTIFHUNG, 2000, &result);
            try expectBlur(h, &g, &.{step[1]});
        }
    }

    h.key(surf, .{ .ctrl = true, .shift = true }, w.VK_F3);
    try expectBlur(h, &g, &.{"none"});
    h.key(surf, .{ .ctrl = true, .shift = true }, w.VK_F3);
    try expectBlur(h, &g, &.{native});

    // The accent policy's path, then the build's own again.
    try h.forceAccentBlur(&g, true);
    try expectBlur(h, &g, &.{"accent"});
    try h.forceAccentBlur(&g, false);
    try expectBlur(h, &g, &.{native});

    h.key(surf, .{ .ctrl = true, .shift = true }, 'N');
    try waitWindowCount(h, &g, 2);
    try expectBlur(h, &g, &.{ native, native });

    // Reloads: background-blur off, then on at an opacity of 1.
    const cfg_path = try std.fmt.allocPrint(h.alloc, "{s}\\blur\\murrtty\\config.ghostty", .{h.temp_dir});
    defer h.alloc.free(cfg_path);
    try h.writeFileAt(cfg_path, base_config ++ "background-opacity = 0.5\n" ++ toggle_opacity);
    h.key(surf, .{ .ctrl = true, .shift = true }, w.VK_OEM_COMMA);
    try expectBlur(h, &g, &.{ "none", "none" });
    try h.writeFileAt(cfg_path, base_config ++ "background-blur = true\n" ++ toggle_opacity);
    h.key(surf, .{ .ctrl = true, .shift = true }, w.VK_OEM_COMMA);
    // The reload has come once the windows turn opaque.
    try expectTranslucent(h, &g, &.{ false, false });
    try expectBlur(h, &g, &.{ "none", "none" });
    try quit(h, &g, surf);
}

/// The blur a translucent window has on Windows build `build`, active or
/// not (App.blurMethod, Window.syncBlur).
fn nativeBlur(build: u32, active: bool) []const u8 {
    if (build >= 22621) return if (active) "backdrop" else "accent";
    return if (build >= 17763) "accent" else "none";
}

/// Wait until each window's blur is as in `want` ("native": as its build
/// and activity give, nativeBlur); DWM's system backdrop must be Acrylic
/// (3) with "backdrop" and the default (0) otherwise, and DWM must say
/// which from Windows 11 22H2.
fn expectBlur(h: *Harness, g: *Harness.Ghostty, want: []const []const u8) !void {
    const build = Harness.windowsBuild();
    const names = try std.mem.join(h.alloc, ", ", want);
    defer h.alloc.free(names);
    var waited: u32 = 0;
    while (true) : (waited += 100) {
        var d = try h.dump(g);
        defer d.deinit();
        const wins = d.value.windows;
        const same = wins.len == want.len and for (wins, want) |win, wanted| {
            const blur = if (std.mem.eql(u8, wanted, "native")) nativeBlur(build, win.active_window) else wanted;
            if (!std.mem.eql(u8, win.blur, blur)) break false;
            const backdrop: i64 = if (std.mem.eql(u8, blur, "backdrop")) 3 else 0;
            if (build >= 22621 and win.backdrop_type < 0) break false;
            if (win.backdrop_type >= 0 and win.backdrop_type != backdrop) break false;
        } else true;
        if (same) {
            for (wins, 0..) |win, i| h.log("window {d}: {s}, active {}, DWM's backdrop type {d}", .{ i, win.blur, win.active_window, win.backdrop_type });
            return h.expect(true, "the windows' blur is {s}", .{names});
        }
        if (waited >= 3000) {
            for (wins, 0..) |win, i| h.log("window {d}: blur {s}, active {}, backdrop type {d}", .{ i, win.blur, win.active_window, win.backdrop_type });
            return h.fail("the windows' blur isn't {s}", .{names});
        }
        w.Sleep(100);
    }
}

/// Wait until each window's `translucent` reads as in `want`.
fn expectTranslucent(h: *Harness, g: *Harness.Ghostty, want: []const bool) !void {
    var waited: u32 = 0;
    while (true) : (waited += 100) {
        var d = try h.dump(g);
        defer d.deinit();
        const wins = d.value.windows;
        const same = wins.len == want.len and for (wins, want) |win, on| {
            if (win.translucent != on) break false;
        } else true;
        if (same) return h.expect(true, "the windows' translucency is {any}", .{want});
        if (waited >= 3000) return h.fail("the windows' translucency isn't {any}", .{want});
        w.Sleep(100);
    }
}

/// Read pane `pane`'s frames back until its background, low in the middle,
/// is `rgb` at `alpha`.
fn expectFrameBackground(h: *Harness, g: *Harness.Ghostty, pane: usize, rgb: u32, alpha: u32) !void {
    var waited: u32 = 0;
    while (true) : (waited += 250) {
        try h.saveFrames(g);
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "frame-{d}.bmp", .{pane});
        var img = try h.loadPicture(g, name);
        defer img.deinit();
        const px = img.argb(img.width / 2, img.height - 12);
        if (near(px & 0xffffff, rgb, 2) and near(px >> 24, alpha, 1)) {
            return h.expect(true, "pane {d}'s background reads #{x:0>8}", .{ pane, px });
        }
        if (waited >= 2000) return h.fail("pane {d}'s background reads #{x:0>8}, not #{x:0>2}{x:0>6}", .{ pane, px, alpha, rgb });
        w.Sleep(250);
    }
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

/// Keys of layouts other than US (roadmap 6.2), as a console program reads
/// them ([Console]::ReadKey): the character AltGr makes, also for Ctrl+Alt,
/// which Windows' AltGr layouts take as AltGr (German Ctrl+Alt+Q is @,
/// AltGr+E is the euro sign); and a character typed by its code with Alt
/// and the numeric keypad (Alt+0228 is ä), which must arrive alone, not
/// after Alt+digit keys (PowerShell's PSReadLine takes Alt+digits as a
/// repeat count). The layouts' characters come as the WM_CHARs Windows
/// would make (`keyChars`): loading a layout would change the session's.
fn intlKeys(h: *Harness) anyerror!void {
    const dir = try std.fmt.allocPrint(h.alloc, "{s}\\intl-keys", .{h.temp_dir});
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
    var g = try start(h, "intl-keys", config, "keys-ready");
    defer g.deinit();
    const surf = try h.surface(&g, try h.mainWindow(&g));

    // A dead key (´) that doesn't combine with what AltGr+Q makes: Windows
    // sends both characters behind the key, which go as text rather than
    // one Windows key event, through the core's own encoding of AltGr's
    // text (it made "@" a Ctrl+Q). PowerShell reads ´ and then @.
    try h.keyChars(surf, .{ .altgr = true }, 'Q', "\u{B4}@");
    {
        try h.waitText(&g, " 64", 1, 5000);
        var d = try h.dump(&g);
        defer d.deinit();
        const text = d.value.windows[0].tabs[0].text orelse "";
        const at = std.mem.indexOf(u8, text, " 180") orelse return h.fail("a dead key's ´ before AltGr+Q's @ didn't arrive; the program read:\n{s}", .{text});
        const rest = text[at..];
        try h.expect(std.mem.indexOf(u8, rest, " 64") != null and std.mem.indexOf(u8, rest, " 17") == null, "a dead key's ´ and AltGr+Q's @ arrive as both characters, not Ctrl+Q; the program read:\n{s}", .{text});
    }

    const cases = [_]struct { mods: Harness.Mods, vk: u8, chars: []const u8, want: []const u8, what: []const u8 }{
        .{ .mods = .{ .ctrl = true, .alt = true }, .vk = 'Q', .chars = "@", .want = "key Q Alt+Control 64", .what = "German Ctrl+Alt+Q (@)" },
        .{ .mods = .{ .altgr = true }, .vk = 'Q', .chars = "@", .want = "key Q Alt+Control 64", .what = "German AltGr+Q (@)" },
        .{ .mods = .{ .altgr = true }, .vk = 'E', .chars = "\u{20AC}", .want = "key E Alt+Control 8364", .what = "German AltGr+E (the euro sign)" },
        .{ .mods = .{ .ctrl = true, .alt = true }, .vk = 'E', .chars = "\u{20AC}", .want = "key E Alt+Control 8364", .what = "German Ctrl+Alt+E (the euro sign)" },
    };
    for (cases) |k| {
        try h.keyChars(surf, k.mods, k.vk, k.chars);
        h.waitText(&g, k.want, 1, 5000) catch {
            var d = try h.dump(&g);
            defer d.deinit();
            return h.fail("{s} didn't arrive as '{s}'; the program read:\n{s}", .{ k.what, k.want, d.value.windows[0].tabs[0].text orelse "" });
        };
        try h.expect(true, "{s} arrives as '{s}'", .{ k.what, k.want });
    }

    // Alt+0228: ä, and nothing before it but Alt.
    h.altNumpad(surf, "0228");
    h.waitText(&g, " 228", 1, 5000) catch {
        var d = try h.dump(&g);
        defer d.deinit();
        return h.fail("Alt+0228 didn't arrive as ä (228); the program read:\n{s}", .{d.value.windows[0].tabs[0].text orelse ""});
    };
    var d = try h.dump(&g);
    defer d.deinit();
    const text = d.value.windows[0].tabs[0].text orelse "";
    try h.expect(std.mem.indexOf(u8, text, "NumPad") == null, "Alt+0228 arrives as ä alone, its digits not as keys of their own; the program read:\n{s}", .{text});
}

/// Where IMEs place their windows (roadmap 6.2). IMEs built on the Text
/// Services Framework ask (WM_IME_REQUEST, IMR_QUERYCHARPOSITION) where a
/// composition's characters are: the cursor's cell, in screen pixels, a
/// cell high, in the pane as the document; the candidate window goes below
/// the cursor's row (IMR_CANDIDATEWINDOW, CFS_EXCLUDE). Typing moves both
/// along.
fn imePlace(h: *Harness) anyerror!void {
    var g = try start(h, "ime-place", "", ">");
    defer g.deinit();
    const surf = try h.surface(&g, try h.mainWindow(&g));
    for (0..2) |round| {
        if (round == 1) {
            try h.typeText(surf, "abc");
            try h.waitText(&g, ">abc", 1, 5000);
        }
        var d = try h.dump(&g);
        defer d.deinit();
        const tab = d.value.windows[0].tabs[0];
        const pane = (tab.panes orelse return h.fail("no panes in the dump", .{}))[0];
        const ime = pane.ime orelse return h.fail("no ime in the dump", .{});
        const cell = tab.cell orelse return h.fail("no cell size in the dump", .{});
        const pad = tab.padding orelse return h.fail("no padding in the dump", .{});
        const cur = pane.cursor orelse return h.fail("no cursor in the dump", .{});
        const x: i32 = @intCast(cur[0] * cell[0] + pad[0]);
        const y: i32 = @intCast(cur[1] * cell[1] + pad[1]);
        const when = if (round == 0) "at the prompt" else "after typing abc";
        try h.expect(ime.answered, "{s}: IMR_QUERYCHARPOSITION is answered", .{when});
        try h.expect(ime.char[0] - ime.doc[0] == x and ime.char[1] - ime.doc[1] == y and ime.line == cell[1], "{s}: the composition starts at the cursor's cell ({d},{d} in the pane, {d} high; got {d},{d}, {d} high)", .{
            when, x, y, cell[1], ime.char[0] - ime.doc[0], ime.char[1] - ime.doc[1], ime.line,
        });
        try h.expect(ime.doc[2] - ime.doc[0] == pane.rect[2] - pane.rect[0] and ime.doc[3] - ime.doc[1] == pane.rect[3] - pane.rect[1], "{s}: the document is the pane", .{when});
        try h.expect(ime.cand[0] == 0x80 and ime.cand[1] == x and ime.cand[2] == y + @as(i32, @intCast(cell[1])), "{s}: the candidate window goes below the cursor's row, clear of it (style {d} at {d},{d})", .{
            when, ime.cand[0], ime.cand[1], ime.cand[2],
        });
    }

    // A key the IME takes (VK_PROCESSKEY) is a keystroke: scrolled back,
    // the view goes to the bottom, where the composition is drawn.
    h.key(surf, .{}, w.VK_ESCAPE); // cmd clears the line
    try h.typeText(surf, "for /L %i in (1,1,120) do @echo line %i");
    h.enter(surf);
    try h.waitText(&g, "line 120", 1, 10000);
    h.key(surf, .{ .shift = true }, w.VK_PRIOR);
    _ = try waitScroll(h, &g, ScrollState.scrolledBack, "scrolled back by Shift+PgUp", 5000);
    h.postImeKey(surf);
    _ = try waitScroll(h, &g, ScrollState.atBottom, "back at the bottom after a key the IME takes", 5000);
    try h.expect(true, "a key the IME takes scrolls the view to the bottom", .{});
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
    // The shell's next prompt first: a quit just after a command's output,
    // before that prompt is drawn, rightly asks (desktop CI, launch-context,
    // 2026-10-29).
    const active = active: {
        var d = try h.dump(g);
        defer d.deinit();
        break :active d.value.windows[0].active;
    };
    try waitAtPrompt(h, g, active, true);
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

/// What `target` answers to WM_NCHITTEST at `at`, in `win`'s client
/// coordinates.
fn hitTestAt(target: w.HWND, win: w.HWND, at: [2]i32) isize {
    var pt: w.POINT = .{ .x = at[0], .y = at[1] };
    _ = w.ClientToScreen(win, &pt);
    return hitTest(target, pt.x, pt.y);
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

//---------------------------------------------------------------
// The single instance (roadmap 5.1)

/// A class of this harness run's own for `which`: its murrtty is reached by
/// that name, and the owner's murrtty never is.
fn ipcClass(h: *Harness, which: []const u8) ![]u8 {
    return std.fmt.allocPrint(h.alloc, "murrtty-gui-{s}-{d}", .{ which, w.GetCurrentProcessId() });
}

/// Wait until `g` holds its single-instance pipe; its name (caller frees).
fn waitListening(h: *Harness, g: *Harness.Ghostty, ms: u32) ![]u8 {
    var waited: u32 = 0;
    while (waited <= ms) : (waited += 100) {
        var d = try h.dump(g);
        defer d.deinit();
        if (d.value.ipc.listening) return h.alloc.dupe(u8, d.value.ipc.pipe);
        w.Sleep(100);
    }
    return h.fail("murrtty never listened on its pipe", .{});
}

/// Wait until window `wi`'s first tab shows `needle` (any case, across the
/// rows a long line wraps onto).
fn waitWindowText(h: *Harness, g: *Harness.Ghostty, wi: usize, needle: []const u8) !void {
    return waitWindowTabText(h, g, wi, 0, needle);
}

/// waitWindowText for tab `ti` of window `wi`.
fn waitWindowTabText(h: *Harness, g: *Harness.Ghostty, wi: usize, ti: usize, needle: []const u8) !void {
    var waited: u32 = 0;
    while (waited <= 20000) : (waited += 200) {
        var d = try h.dump(g);
        defer d.deinit();
        if (wi < d.value.windows.len and ti < d.value.windows[wi].tabs.len) {
            if (d.value.windows[wi].tabs[ti].text) |text| {
                const joined = try std.mem.replaceOwned(u8, h.alloc, text, "\n", "");
                defer h.alloc.free(joined);
                if (std.ascii.findIgnoreCase(joined, needle) != null) return;
            }
        }
        w.Sleep(200);
    }
    return h.fail("window {d}'s tab {d} never showed '{s}'", .{ wi, ti, needle });
}

/// +new-window and +new-tab reach the running murrtty over its pipe: a
/// window with the title, directory and command given, a tab in the window
/// of the pane its surface id names, the CLI exiting 0 each time. Bytes
/// that aren't a request, and a kind it doesn't know (a newer murrtty's),
/// are refused and open nothing; +toggle-quick-terminal opens the quick
/// terminal (roadmap 5.7).
fn ipcRequests(h: *Harness) anyerror!void {
    const class = try ipcClass(h, "ipc");
    defer h.alloc.free(class);
    const extra = try std.fmt.allocPrint(h.alloc, "class = {s}\n", .{class});
    defer h.alloc.free(extra);
    var g = try start(h, "ipc", extra, ">");
    defer g.deinit();
    const pipe = try waitListening(h, &g, 5000);
    defer h.alloc.free(pipe);
    try h.expect(std.mem.startsWith(u8, pipe, "\\\\.\\pipe\\") and std.mem.indexOf(u8, pipe, class) != null, "the pipe is named for the class ({s})", .{pipe});
    const class_arg = try std.fmt.allocPrint(h.alloc, "--class={s}", .{class});
    defer h.alloc.free(class_arg);

    {
        const wd = try std.fmt.allocPrint(h.alloc, "--working-directory={s}", .{g.dir});
        defer h.alloc.free(wd);
        var r = try h.runCli("ipc-new-window", &.{ "+new-window", class_arg, "--title=IPC window", wd, "-e", "cmd.exe", "/k", "echo", "ipc-ok" });
        defer r.deinit();
        try h.expect(r.code == 0, "+new-window exits 0 (got {d})", .{r.code});
    }
    try waitWindowCount(h, &g, 2);
    try waitWindowText(h, &g, 1, "ipc-ok");
    {
        const prompt = try std.fmt.allocPrint(h.alloc, "{s}>", .{g.dir});
        defer h.alloc.free(prompt);
        try waitWindowText(h, &g, 1, prompt);
        var d = try h.dump(&g);
        defer d.deinit();
        const t = d.value.windows[1].tabs[0];
        try h.expect(std.mem.eql(u8, t.pane_name, "IPC window") and std.mem.eql(u8, t.label, "IPC window"), "the window opened in this murrtty runs the command in the directory given, titled IPC window (name '{s}', label '{s}')", .{ t.pane_name, t.label });
        try h.expect(d.value.windows[0].tabs[0].pane_name.len == 0, "the first window's pane keeps its own title", .{});
    }

    // A tab, by its pane's id, in the window whose pane the core doesn't
    // have focused (that one is where an id ignored would put it), in the
    // home directory.
    var target: usize = 0;
    const id = id: {
        var d = try h.dump(&g);
        defer d.deinit();
        if (d.value.windows[0].tabs[0].focused orelse false) target = 1;
        const t = d.value.windows[target].tabs[0];
        try h.expect(!(t.focused orelse true), "window {d}'s pane isn't the core's focused one", .{target});
        break :id (t.panes orelse return h.fail("no panes", .{}))[0].surface_id;
    };
    try h.expect(id != 0, "the pane has a surface id", .{});
    {
        const id_arg = try std.fmt.allocPrint(h.alloc, "--surface-id={d}", .{id});
        defer h.alloc.free(id_arg);
        var r = try h.runCli("ipc-new-tab", &.{ "+new-tab", class_arg, id_arg, "--title=IPC tab", "--working-directory=home" });
        defer r.deinit();
        try h.expect(r.code == 0, "+new-tab exits 0 (got {d})", .{r.code});
    }
    try waitTabCount(h, &g, target, 2);
    {
        var home_buf: [260]u16 = undefined;
        const n = w.GetEnvironmentVariableW(w.L("USERPROFILE"), &home_buf, home_buf.len);
        const home = try std.unicode.utf16LeToUtf8Alloc(h.alloc, home_buf[0..n]);
        defer h.alloc.free(home);
        const prompt = try std.fmt.allocPrint(h.alloc, "{s}>", .{home});
        defer h.alloc.free(prompt);
        try waitWindowTabText(h, &g, target, 1, prompt);
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(d.value.windows.len == 2 and d.value.windows[1 - target].tabs.len == 1, "the tab went to the window of the pane named only", .{});
        const name = d.value.windows[target].tabs[1].pane_name;
        try h.expect(std.mem.eql(u8, name, "IPC tab"), "the new tab's pane is titled IPC tab and starts at home (got '{s}')", .{name});
        try h.expect(d.value.ipc.received == 2, "two requests received (got {d})", .{d.value.ipc.received});
    }

    // A pipe of another class's name that a lower integrity level made
    // first: the client sends nothing to it.
    {
        const squat_class = try std.fmt.allocPrint(h.alloc, "{s}-squat", .{class});
        defer h.alloc.free(squat_class);
        const prefix = "\\\\.\\pipe\\";
        const squat_name = try std.mem.concat(h.alloc, u8, &.{ prefix, squat_class, pipe[prefix.len + class.len ..] });
        defer h.alloc.free(squat_name);
        const squat = try h.squatPipe(squat_name);
        defer _ = w.CloseHandle(squat);
        const squat_arg = try std.fmt.allocPrint(h.alloc, "--class={s}", .{squat_class});
        defer h.alloc.free(squat_arg);
        var r = try h.runCli("ipc-squat", &.{ "+new-window", squat_arg, "--title=never sent" });
        defer r.deinit();
        try h.expect(r.code == 1, "a pipe labeled below the caller's level is refused: exit 1 (got {d})", .{r.code});
        var avail: w.DWORD = 0;
        if (w.PeekNamedPipe(squat, null, 0, null, &avail, null) == 0) avail = 0;
        try h.expect(avail == 0, "and nothing was written to it ({d} bytes)", .{avail});
    }

    const garbage = try h.pipeRequest(pipe, "this is not a murrtty request");
    try h.expect(garbage != null and garbage.? == 1, "bytes that aren't a request are refused as malformed (reply {?d})", .{garbage});
    // The header of a version 1 request of kind 9, which no murrtty knows.
    const unknown = try h.pipeRequest(pipe, "MRTY\x01\x09\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00");
    try h.expect(unknown != null and unknown.? == 2, "a kind it doesn't know is refused as unsupported (reply {?d})", .{unknown});
    {
        var r = try h.runCli("ipc-quick-terminal", &.{ "+toggle-quick-terminal", class_arg });
        defer r.deinit();
        try h.expect(r.code == 0, "+toggle-quick-terminal exits 0 (got {d})", .{r.code});
    }
    var waited: u32 = 0;
    while (waited < 5000) : (waited += 100) {
        if (try quickState(h, &g) != null) break;
        w.Sleep(100);
    }
    var d = try h.dump(&g);
    defer d.deinit();
    var quick: usize = 0;
    for (d.value.windows) |win| quick += @intFromBool(win.quick != null);
    try h.expect(d.value.ipc.received == 3 and d.value.windows.len == 3 and quick == 1 and d.value.windows[target].tabs.len == 2, "it opens the quick terminal, and nothing else opened", .{});
}

/// With no murrtty serving the class, +new-window starts one for its
/// request, which opens no window of its own, takes the request's and
/// serves the next; the CLI still exits 0 at once (the murrtty it started
/// doesn't hold its output). One started for a request that never comes
/// quits by itself.
fn ipcLaunch(h: *Harness) anyerror!void {
    const class = try ipcClass(h, "ipc-launch");
    defer h.alloc.free(class);
    const class_arg = try std.fmt.allocPrint(h.alloc, "--class={s}", .{class});
    defer h.alloc.free(class_arg);
    {
        var r = try h.runCli("ipc-launch", &.{ "+new-window", class_arg, "--title=Launched for IPC", "-e", "cmd.exe", "/k", "set", "MURRTTY_IPC" });
        defer r.deinit();
        try h.expect(r.code == 0, "+new-window with none running exits 0 (got {d})", .{r.code});
    }
    var g = h.adopt("ipc-launch", "Launched for IPC", 15000) catch |err| {
        h.killStray();
        return err;
    };
    defer g.deinit();
    const pipe = try waitListening(h, &g, 5000);
    defer h.alloc.free(pipe);
    {
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(d.value.ipc.launch and d.value.windows.len == 1, "started for the request, with its window only ({d} windows, launch {})", .{ d.value.windows.len, d.value.ipc.launch });
        try h.expect(std.mem.indexOf(u8, pipe, class) != null, "it serves the class ({s})", .{pipe});
        const name = d.value.windows[0].tabs[0].pane_name;
        try h.expect(std.mem.eql(u8, name, "Launched for IPC"), "with the request's title (got '{s}')", .{name});
    }
    // Its shells don't see the variable it was started with (others of
    // murrtty's, MURRTTY_HISTORY_FILE, are theirs).
    try waitWindowText(h, &g, 0, "Environment variable MURRTTY_IPC not defined");
    {
        var r = try h.runCli("ipc-launch-again", &.{ "+new-window", class_arg });
        defer r.deinit();
        try h.expect(r.code == 0, "the next +new-window exits 0 (got {d})", .{r.code});
    }
    try waitWindowCount(h, &g, 2);

    const idle_class = try std.fmt.allocPrint(h.alloc, "--class={s}-idle", .{class});
    defer h.alloc.free(idle_class);
    const started = w.GetTickCount64();
    var r = try h.runCliWith("ipc-launch-idle", &.{idle_class}, &.{.{ "MURRTTY_IPC_LAUNCH", "1" }});
    defer r.deinit();
    const took = w.GetTickCount64() - started;
    try h.expect(r.code == 0 and took >= 10000, "one started for a request that never comes quits after its wait, code 0 (code {d} after {d} ms)", .{ r.code, took });
}

/// gtk-single-instance: a launch with it on hands its window to the murrtty
/// serving its class and exits 0. One launched from a program (detect: not
/// single) is its own murrtty, without the pipe while the first holds it,
/// and takes it over once the first quits.
fn singleInstance(h: *Harness) anyerror!void {
    const class = try ipcClass(h, "single");
    defer h.alloc.free(class);
    const extra = try std.fmt.allocPrint(h.alloc, "class = {s}\n", .{class});
    defer h.alloc.free(extra);
    var g = try start(h, "single-instance", extra, ">");
    defer g.deinit();
    const pipe = try waitListening(h, &g, 5000);
    defer h.alloc.free(pipe);
    const class_arg = try std.fmt.allocPrint(h.alloc, "--class={s}", .{class});
    defer h.alloc.free(class_arg);
    {
        var r = try h.runCli("single-instance-launch", &.{ class_arg, "--gtk-single-instance=true" });
        defer r.deinit();
        try h.expect(r.code == 0, "a launch with gtk-single-instance hands its window over and exits 0 (got {d})", .{r.code});
    }
    try waitWindowCount(h, &g, 2);

    // detect, no longer the default on Windows (true, roadmap 5.10b).
    const config = try std.mem.concat(h.alloc, u8, &.{ base_config, extra, "gtk-single-instance = detect\n" });
    defer h.alloc.free(config);
    var other = try h.launch("single-instance-other", config);
    defer other.deinit();
    w.Sleep(500);
    {
        var d = try h.dump(&other);
        defer d.deinit();
        try h.expect(!d.value.ipc.listening and std.mem.eql(u8, d.value.ipc.pipe, pipe), "one launched from a program is its own murrtty, without the pipe the first holds", .{});
    }
    try waitWindowCount(h, &g, 2);
    // It tries again every 3 s.
    _ = w.TerminateProcess(g.proc, 1);
    _ = g.waitExit(5000);
    const taken = try waitListening(h, &other, 8000);
    defer h.alloc.free(taken);
    try h.expect(std.mem.eql(u8, taken, pipe), "it serves the class once the first is gone", .{});
}

/// open_config:new_window: a new window running $EDITOR on the config file,
/// titled as GTK's. With neither $VISUAL nor $EDITOR set, the file opens as
/// open_config opens it (recorded while the hooks are on).
fn openConfigWindow(h: *Harness) anyerror!void {
    const config = base_config ++ "keybind = ctrl+shift+y=open_config:new_window\n";
    {
        var g = try h.launchWith("open-config-window", config, .{ .env = &.{ .{ "EDITOR", "cmd.exe /k echo editing" }, .{ "VISUAL", "" } } });
        defer g.deinit();
        try h.waitText(&g, ">", 1, 20000);
        h.key(try h.surface(&g, try h.mainWindow(&g)), .{ .ctrl = true, .shift = true }, 'Y');
        try waitWindowCount(h, &g, 2);
        const path = try std.fmt.allocPrint(h.alloc, "editing {s}\\murrtty\\config.ghostty", .{g.dir});
        defer h.alloc.free(path);
        try waitWindowText(h, &g, 1, path);
        var d = try h.dump(&g);
        defer d.deinit();
        const name = d.value.windows[1].tabs[0].pane_name;
        try h.expect(std.mem.startsWith(u8, name, "Editing configuration file ") and std.mem.endsWith(u8, name, "config.ghostty"), "the editor runs on the file, titled as GTK's (got '{s}')", .{name});
        try h.expect(try launchCount(h, &g, "edit-config ") == 0, "and nothing else opens it", .{});
    }
    {
        var g = try h.launchWith("open-config-window-none", config, .{ .env = &.{ .{ "EDITOR", "" }, .{ "VISUAL", "" } } });
        defer g.deinit();
        try h.waitText(&g, ">", 1, 20000);
        h.key(try h.surface(&g, try h.mainWindow(&g)), .{ .ctrl = true, .shift = true }, 'Y');
        var waited: u32 = 0;
        while (try launchCount(h, &g, "edit-config ") < 1 and waited < 5000) : (waited += 200) w.Sleep(200);
        try h.expect(try launchCount(h, &g, "edit-config ") == 1, "with no editor set, the file opens as open_config opens it", .{});
        const wins = try h.windows(&g, "MurrttyWindow");
        defer h.alloc.free(wins);
        try h.expect(wins.len == 1, "and no window opens ({d})", .{wins.len});
    }
}

//---------------------------------------------------------------
// Desktop notifications (roadmap 5.2)

/// What the dump says of notifications: how many were sent, the latest,
/// and whether its icon is there.
const NotifyState = struct {
    count: usize,
    surface: u64 = 0,
    title: [128]u8 = undefined,
    title_len: usize = 0,
    body: [128]u8 = undefined,
    body_len: usize = 0,
    icon: bool,
    icon_surface: u64,

    fn titleText(self: *const NotifyState) []const u8 {
        return self.title[0..self.title_len];
    }
    fn bodyText(self: *const NotifyState) []const u8 {
        return self.body[0..self.body_len];
    }
};

fn notifyState(h: *Harness, g: *Harness.Ghostty) !NotifyState {
    var d = try h.dump(g);
    defer d.deinit();
    const n = d.value.notifications;
    var s: NotifyState = .{ .count = n.len, .icon = d.value.notify_icon, .icon_surface = d.value.notify_surface };
    if (n.len > 0) {
        const last = n[n.len - 1];
        s.surface = last.surface;
        s.title_len = @min(last.title.len, s.title.len);
        @memcpy(s.title[0..s.title_len], last.title[0..s.title_len]);
        s.body_len = @min(last.body.len, s.body.len);
        @memcpy(s.body[0..s.body_len], last.body[0..s.body_len]);
    }
    return s;
}

/// Wait until `count` notifications have been sent.
fn waitNotifications(h: *Harness, g: *Harness.Ghostty, count: usize) !NotifyState {
    var waited: u32 = 0;
    while (waited <= 15000) : (waited += 200) {
        const s = try notifyState(h, g);
        if (s.count >= count) return s;
        w.Sleep(200);
    }
    return h.fail("no notification {d} came", .{count});
}

/// Wait until the notification's icon has gone, within `ms`.
fn waitIconGone(h: *Harness, g: *Harness.Ghostty, ms: u32, comptime what: []const u8) !void {
    var waited: u32 = 0;
    while (waited <= ms) : (waited += 100) {
        const s = try notifyState(h, g);
        if (!s.icon) return h.expect(true, what, .{});
        w.Sleep(100);
    }
    return h.fail(what ++ ": the notification is still there", .{});
}

/// PowerShell's text that writes `osc` (without its ESC and BEL) after
/// `delay` seconds.
fn oscCommand(h: *Harness, delay: []const u8, osc: []const u8) ![]u8 {
    return std.fmt.allocPrint(h.alloc, "Start-Sleep {s}; [Console]::Write([char]27 + '{s}' + [char]7)", .{ delay, osc });
}

/// OSC 9 and OSC 777 notify, as balloons of a notification-area icon
/// (recorded here: the hidden desktop has none). One from a background
/// pane stays until its pane gets the keyboard or it is clicked, which
/// presents the pane; one from the pane with the keyboard goes after 3 s,
/// as GTK's. Titles are cut to the balloon's 63 characters.
fn notifications(h: *Harness) anyerror!void {
    var g = try h.launchWith("notifications", base_config ++ "command = powershell.exe -NoLogo -NoProfile\n", .{});
    defer g.deinit();
    try h.waitText(&g, "PS ", 1, 20000);
    const win = try h.mainWindow(&g);
    const surf = try h.surface(&g, win);
    const first = first: {
        var d = try h.dump(&g);
        defer d.deinit();
        break :first (d.value.windows[0].tabs[0].panes orelse return h.fail("no panes", .{}))[0].surface_id;
    };

    // From the first tab, sent once a second tab has the keyboard.
    {
        const cmd = try oscCommand(h, "2", "]9;Build done");
        defer h.alloc.free(cmd);
        try h.typeText(surf, cmd);
        h.enter(surf);
    }
    h.key(surf, .{ .ctrl = true, .shift = true }, 'T');
    try waitWindowTabs(h, &g, win, 2);
    var s = try waitNotifications(h, &g, 1);
    try h.expect(s.surface == first and std.mem.eql(u8, s.titleText(), "murrtty") and std.mem.eql(u8, s.bodyText(), "Build done"), "OSC 9 from the background tab notifies as murrtty: '{s}' / '{s}'", .{ s.titleText(), s.bodyText() });
    try h.expect(s.icon and s.icon_surface == first, "its icon stands for it", .{});
    w.Sleep(500);
    try h.expect((try notifyState(h, &g)).icon, "and stays while its pane is in the background", .{});

    // A click takes it back and presents its pane, from the loop.
    try h.clickNotification(&g);
    {
        var active: usize = 1;
        var waited: u32 = 0;
        while (waited <= 3000) : (waited += 100) {
            var d = try h.dump(&g);
            defer d.deinit();
            try h.expect(!d.value.notify_icon, "a click takes the notification back", .{});
            active = d.value.windows[0].active;
            if (active == 0) break;
            w.Sleep(100);
        }
        try h.expect(active == 0, "and brings the first tab forward (tab {d} active)", .{active});
    }

    // OSC 777 from the first tab while the second has the keyboard; the
    // first getting it back takes the notification back.
    const surf0 = try h.surface(&g, win);
    {
        const cmd = try oscCommand(h, "2", "]777;notify;Deploy;All green");
        defer h.alloc.free(cmd);
        try h.typeText(surf0, cmd);
        h.enter(surf0);
    }
    h.key(surf0, .{ .ctrl = true }, 0x09);
    s = try waitNotifications(h, &g, 2);
    try h.expect(s.surface == first and std.mem.eql(u8, s.titleText(), "Deploy") and std.mem.eql(u8, s.bodyText(), "All green"), "OSC 777 notifies with its title: '{s}' / '{s}'", .{ s.titleText(), s.bodyText() });
    try h.expect(s.icon, "its icon is there", .{});
    // Past the 3 s a focused pane's would get: sent unfocused, it stays.
    w.Sleep(3500);
    try h.expect((try notifyState(h, &g)).icon, "it outlasts the 3 s of a focused pane's", .{});
    const surf1 = try h.surface(&g, win);
    h.key(surf1, .{ .ctrl = true }, 0x09);
    try waitIconGone(h, &g, 1500, "the pane getting the keyboard back takes its notification back");

    // From the pane with the keyboard: gone after 3 s. A long title is cut.
    const surf2 = try h.surface(&g, win);
    {
        const long = try std.fmt.allocPrint(h.alloc, "]777;notify;{s};focused", .{"0123456789" ++ "0123456789" ++ "0123456789" ++ "0123456789" ++ "0123456789" ++ "0123456789" ++ "0123456789"});
        defer h.alloc.free(long);
        // After the core's one a second.
        const cmd = try oscCommand(h, "2", long);
        defer h.alloc.free(cmd);
        try h.typeText(surf2, cmd);
        h.enter(surf2);
    }
    s = try waitNotifications(h, &g, 3);
    try h.expect(s.title_len == 63 and std.mem.startsWith(u8, s.titleText(), "0123456789") and std.mem.eql(u8, s.bodyText(), "focused"), "a 70-character title is cut to 63 ({d}: '{s}')", .{ s.title_len, s.titleText() });
    try h.expect(s.icon, "it shows, from the pane with the keyboard too", .{});
    {
        var d = try h.dump(&g);
        defer d.deinit();
        const focused = d.value.windows[0].tabs[0].focused orelse false;
        try h.expect(focused, "the first tab is the core's focused one", .{});
    }
    try waitIconGone(h, &g, 6000, "one sent from the pane with the keyboard goes after 3 s");

    // desktop-notifications = false: nothing.
    var off = try h.launchWith("notifications-off", base_config ++ "command = powershell.exe -NoLogo -NoProfile\ndesktop-notifications = false\n", .{});
    defer off.deinit();
    try h.waitText(&off, "PS ", 1, 20000);
    const off_surf = try h.surface(&off, try h.mainWindow(&off));
    {
        const cmd = try oscCommand(h, "0", "]9;not shown");
        defer h.alloc.free(cmd);
        try h.typeText(off_surf, cmd);
        h.enter(off_surf);
    }
    try h.waitText(&off, "not shown' + [char]7)", 1, 10000);
    w.Sleep(2000);
    const none = try notifyState(h, &off);
    try h.expect(none.count == 0 and !none.icon, "with desktop-notifications = false nothing shows ({d})", .{none.count});
}

/// A notification really shown: Windows takes the icon and its balloon
/// (the icon counts as there only if Shell_NotifyIconW took it), and they
/// are taken back (without presenting the pane, which could take the
/// user's foreground). The window is off-screen on the user's desktop,
/// whose notification area it needs; the toast shows on screen for a
/// moment, so only with GHOSTTY_GUI_ONSCREEN=1.
fn notifyShown(h: *Harness) anyerror!void {
    if (w.GetEnvironmentVariableW(w.L("GHOSTTY_GUI_ONSCREEN"), null, 0) == 0) {
        return h.skip("it shows a toast on the screen; set GHOSTTY_GUI_ONSCREEN=1 to run it", .{});
    }
    const Ctx = struct { h: *Harness, err: ?anyerror = null };
    var ctx: Ctx = .{ .h = h };
    h.runOnUserDesktop(&ctx, struct {
        fn run(cx: *Ctx) void {
            notifyShownOffscreen(cx.h) catch |err| {
                cx.err = err;
            };
        }
    }.run);
    if (ctx.err) |err| return err;
}

fn notifyShownOffscreen(h: *Harness) !void {
    var g = try h.launchWith("notify-shown", base_config ++ "command = powershell.exe -NoLogo -NoProfile\n", .{
        .where = .offscreen,
        .env = &.{.{ "GHOSTTY_WIN32_TEST_NOTIFY", "1" }},
    });
    defer g.deinit();
    try h.waitText(&g, "PS ", 1, 20000);
    const surf = try h.surface(&g, try h.mainWindow(&g));
    const cmd = try oscCommand(h, "0", "]9;murrtty notification test");
    defer h.alloc.free(cmd);
    try h.typeText(surf, cmd);
    h.enter(surf);
    const s = try waitNotifications(h, &g, 1);
    // From the pane with the keyboard it would go after 3 s.
    try h.expect(s.icon, "Windows took the icon and its balloon", .{});
    try h.withdrawNotification(&g);
    try waitIconGone(h, &g, 2000, "and it is taken back");
}

//---------------------------------------------------------------
// The quick terminal (roadmap 5.7)

const QuickState = struct {
    /// Its index in the dump's windows, its HWND.
    index: usize,
    hwnd: w.HWND,
    quick: Harness.Dump.Quick,
    rect: [4]i32,
    visible: bool,
    toolwindow: bool,
    topmost: bool,
    header: bool,
    tabs: usize,
    windows: usize,
    windows_hidden: bool,
};

/// The quick terminal as the dump has it, or null.
fn quickState(h: *Harness, g: *Harness.Ghostty) !?QuickState {
    var d = try h.dump(g);
    defer d.deinit();
    for (d.value.windows, 0..) |win, i| {
        const q = win.quick orelse continue;
        return .{
            .index = i,
            .hwnd = @ptrFromInt(win.hwnd),
            .quick = q,
            .rect = win.rect,
            .visible = win.visible,
            .toolwindow = win.toolwindow,
            .topmost = win.topmost,
            .header = win.header.visible,
            .tabs = win.tabs.len,
            .windows = d.value.windows.len,
            .windows_hidden = d.value.windows_hidden,
        };
    }
    return null;
}

/// Wait until the quick terminal exists and has stopped sliding.
fn waitQuickSettled(h: *Harness, g: *Harness.Ghostty) !QuickState {
    var waited: u32 = 0;
    while (waited <= 5000) : (waited += 50) {
        if (try quickState(h, g)) |q| if (!q.quick.sliding) return q;
        w.Sleep(50);
    }
    return h.fail("the quick terminal never settled", .{});
}

/// The primary monitor's work area and DPI, read here (not from murrtty).
fn primaryScreen() struct { work: [4]i32, dpi: u32 } {
    const mon = w.MonitorFromPoint(.{}, w.MONITOR_DEFAULTTOPRIMARY) orelse return .{ .work = .{ 0, 0, 0, 0 }, .dpi = 96 };
    var mi: w.MONITORINFO = .{};
    _ = w.GetMonitorInfoW(mon, &mi);
    var dpi: u32 = 96;
    if (w.LoadLibraryW(w.L("shcore.dll"))) |lib| {
        defer _ = w.FreeLibrary(lib);
        if (w.GetProcAddress(lib, "GetDpiForMonitor")) |p| {
            const getDpi: *const fn (*anyopaque, c_int, *u32, *u32) callconv(.winapi) c_long = @ptrCast(p);
            var x: u32 = 0;
            var y: u32 = 0;
            if (getDpi(mon, 0, &x, &y) == 0 and x != 0) dpi = x;
        }
    }
    const r = mi.rcWork;
    return .{ .work = .{ r.left, r.top, r.right, r.bottom }, .dpi = dpi };
}

/// Where the quick terminal belongs in `work` at `dpi`: a percentage of the
/// work area's pixels, the default 400 DIP, all of the other side; centered
/// across its side, never past the work area.
fn quickExpected(work: [4]i32, dpi: u32, position: enum { top, right }, primary: ?f32, secondary: ?f32) [4]i32 {
    const ww = work[2] - work[0];
    const wh = work[3] - work[1];
    const pct = struct {
        fn of(v: f32, px: i32) i32 {
            const f: f32 = @floatFromInt(px);
            return @intFromFloat(v / 100.0 * f);
        }
    };
    const dip400: i32 = @intCast(@as(u32, 400) * dpi / 96);
    var pw: i32 = undefined;
    var ph: i32 = undefined;
    switch (position) {
        .top => {
            pw = if (secondary) |s| pct.of(s, ww) else ww;
            ph = if (primary) |p| pct.of(p, wh) else dip400;
        },
        .right => {
            pw = if (primary) |p| pct.of(p, ww) else dip400;
            ph = if (secondary) |s| pct.of(s, wh) else wh;
        },
    }
    pw = @min(pw, ww);
    ph = @min(ph, wh);
    return switch (position) {
        .top => .{ work[0] + @divTrunc(ww - pw, 2), work[1], work[0] + @divTrunc(ww - pw, 2) + pw, work[1] + ph },
        .right => .{ work[2] - pw, work[1] + @divTrunc(wh - ph, 2), work[2], work[1] + @divTrunc(wh - ph, 2) + ph },
    };
}

/// toggle_quick_terminal (roadmap 5.7), as GTK's: one window, a topmost
/// borderless tool window with no header bar, placed by
/// quick-terminal-position and -size in the work area of the monitor
/// quick-terminal-screen names (the primary one), sliding in and out; a
/// dialog of another window opens above it; it hides only while something
/// can bring it back, and comes back when the last other window closes;
/// quick-terminal-autohide hides it when another window takes the
/// keyboard; +toggle-quick-terminal reaches it over the pipe, and can hide
/// what it opened; it leaves what toggle_visibility hid hidden.
fn quickTerminalScenario(h: *Harness) anyerror!void {
    const screen = primaryScreen();
    {
        var g = try start(h, "quick", "keybind = ctrl+shift+f6=toggle_quick_terminal\n" ++
            "keybind = ctrl+shift+f8=close_window\n" ++
            "quick-terminal-animation-duration = 0.8\n", ">");
        defer g.deinit();
        const win = try h.mainWindow(&g);
        const surf = try h.surface(&g, win);
        h.key(surf, .{ .ctrl = true, .shift = true }, 0x75);
        {
            const q = try quickState(h, &g) orelse return h.fail("no quick terminal opened", .{});
            try h.expect(q.quick.shown and q.quick.sliding, "toggle_quick_terminal opens it, sliding in", .{});
        }
        const q = try waitQuickSettled(h, &g);
        try h.expect(std.mem.eql(i32, &q.quick.work, &screen.work) and q.quick.dpi == screen.dpi, "on the primary monitor, at its DPI ({d})", .{q.quick.dpi});
        const want = quickExpected(screen.work, screen.dpi, .top, null, null);
        try h.expect(std.mem.eql(i32, &q.rect, &want), "at the top of the work area, 400 DIP tall, across it ({d},{d},{d},{d}; want {d},{d},{d},{d})", .{ q.rect[0], q.rect[1], q.rect[2], q.rect[3], want[0], want[1], want[2], want[3] });
        try h.expect(q.visible and q.toolwindow and q.topmost and !q.header and q.tabs == 1 and q.windows == 2, "a topmost tool window (no taskbar button), no header bar, one tab", .{});
        const qsurf = try h.surface(&g, q.hwnd);
        try h.waitText(&g, ">", 1, 20000);

        // A dialog of the main window opens above it: it leaves the topmost
        // band until the dialog closes.
        h.key(surf, .{ .ctrl = true, .shift = true }, 0x77);
        const dlg = try h.waitDialog(&g, 5000);
        {
            const s = try quickState(h, &g) orelse return h.fail("the quick terminal went", .{});
            try h.expect(!s.topmost and s.quick.lowered and s.visible, "under another window's dialog it isn't topmost", .{});
        }
        h.answer(&g, dlg, w.IDCANCEL);
        w.Sleep(300);
        {
            // Asked back into the topmost band: Windows grants it only to a
            // process with the foreground, never on the hidden desktop.
            const s = try quickState(h, &g) orelse return h.fail("the quick terminal went", .{});
            try h.expect(!s.quick.lowered, "and goes back above as the dialog closes", .{});
        }

        // From its own pane: it slides out and hides (the main window could
        // bring it back).
        h.key(qsurf, .{ .ctrl = true, .shift = true }, 0x75);
        {
            const hidden = try waitQuickSettled(h, &g);
            try h.expect(!hidden.quick.shown and !hidden.visible and hidden.windows == 2, "toggled from itself, it slides out and hides", .{});
        }
        // Again from the main window: the same window comes back.
        h.key(surf, .{ .ctrl = true, .shift = true }, 0x75);
        {
            const again = try waitQuickSettled(h, &g);
            try h.expect(again.quick.shown and again.visible and again.hwnd == q.hwnd and std.mem.eql(i32, &again.rect, &want), "toggled again, the same window slides back", .{});
        }
        // Hidden, then the main window closes: nothing could bring it back,
        // so it shows.
        h.key(surf, .{ .ctrl = true, .shift = true }, 0x75);
        _ = try waitQuickSettled(h, &g);
        h.key(surf, .{ .ctrl = true, .shift = true }, 0x77);
        h.answer(&g, try h.waitDialog(&g, 5000), w.IDYES);
        var waited: u32 = 0;
        while (waited < 5000) : (waited += 100) {
            if (try quickState(h, &g)) |s| if (s.windows == 1 and s.quick.shown and !s.quick.sliding) break;
            w.Sleep(100);
        }
        {
            const alone = try quickState(h, &g) orelse return h.fail("the quick terminal went", .{});
            try h.expect(alone.windows == 1 and alone.quick.shown and alone.visible, "its last other window closed, the hidden quick terminal shows", .{});
        }
        // Now nothing could bring it back: it won't hide.
        h.key(qsurf, .{ .ctrl = true, .shift = true }, 0x75);
        w.Sleep(1200);
        {
            const kept = try quickState(h, &g) orelse return h.fail("the quick terminal went", .{});
            try h.expect(kept.quick.shown and kept.visible, "with no other way back, it doesn't hide", .{});
        }
    }

    // On the right, 30% by 50%, with no slide; quick-terminal-autohide; the
    // pipe.
    {
        const class = try ipcClass(h, "quick");
        defer h.alloc.free(class);
        const extra = try std.fmt.allocPrint(h.alloc, "class = {s}\n" ++
            "keybind = ctrl+shift+f6=toggle_quick_terminal\nkeybind = ctrl+shift+f8=close_window\n" ++
            "quick-terminal-position = right\nquick-terminal-size = 30%,50%\n" ++
            "quick-terminal-animation-duration = 0\nquick-terminal-autohide = true\n", .{class});
        defer h.alloc.free(extra);
        var g = try start(h, "quick-right", extra, ">");
        defer g.deinit();
        const main = try h.mainWindow(&g);
        h.key(try h.surface(&g, main), .{ .ctrl = true, .shift = true }, 0x75);
        const q = try quickState(h, &g) orelse return h.fail("no quick terminal opened", .{});
        const want = quickExpected(screen.work, screen.dpi, .right, 30, 50);
        try h.expect(!q.quick.sliding and q.visible and std.mem.eql(i32, &q.rect, &want), "with no animation it is there at once, on the right, 30% by 50% ({d},{d},{d},{d}; want {d},{d},{d},{d})", .{ q.rect[0], q.rect[1], q.rect[2], q.rect[3], want[0], want[1], want[2], want[3] });
        // Another window takes the keyboard: it hides.
        var result: usize = 0;
        _ = w.SendMessageTimeoutW(q.hwnd, w.WM_ACTIVATE, w.WA_INACTIVE, 0, w.SMTO_ABORTIFHUNG, 5000, &result);
        {
            const hidden = try quickState(h, &g) orelse return h.fail("the quick terminal went", .{});
            try h.expect(!hidden.quick.shown and !hidden.visible, "quick-terminal-autohide hides it when another window takes the keyboard", .{});
        }
        w.Sleep(600);
        // +toggle-quick-terminal over the pipe shows it again.
        const class_arg = try std.fmt.allocPrint(h.alloc, "--class={s}", .{class});
        defer h.alloc.free(class_arg);
        try quickCli(h, &g, class_arg, true, "+toggle-quick-terminal shows it again");
        // Alone with the quick terminal, the command can still hide it: it
        // brings it back too.
        h.key(try h.surface(&g, main), .{ .ctrl = true, .shift = true }, 0x77);
        h.answer(&g, try h.waitDialog(&g, 5000), w.IDYES);
        var waited: u32 = 0;
        while (waited < 5000) : (waited += 100) {
            if (try quickState(h, &g)) |s| if (s.windows == 1) break;
            w.Sleep(100);
        }
        try quickCli(h, &g, class_arg, false, "alone, +toggle-quick-terminal still hides what it toggled");
        try quickCli(h, &g, class_arg, true, "and shows it again");
    }

    // With the tray, toggle_visibility hides the main window; the quick
    // terminal shows without bringing it back.
    {
        var g = try start(h, "quick-hidden", "quit-after-last-window-closed = false\n" ++
            "keybind = ctrl+shift+f6=toggle_quick_terminal\nkeybind = ctrl+shift+f9=toggle_visibility\n" ++
            "quick-terminal-animation-duration = 0\n", ">");
        defer g.deinit();
        const surf = try h.surface(&g, try h.mainWindow(&g));
        try h.setInFront(&g, .yes);
        h.key(surf, .{ .ctrl = true, .shift = true }, 0x78);
        try waitHidden(h, &g);
        h.key(surf, .{ .ctrl = true, .shift = true }, 0x75);
        const q = try quickState(h, &g) orelse return h.fail("no quick terminal opened", .{});
        try h.expect(q.quick.shown and q.visible and q.windows_hidden and try visibleWindows(h, &g) == 1, "the quick terminal shows, and what toggle_visibility hid stays hidden", .{});
    }
}

/// Run +toggle-quick-terminal for `class_arg` and wait until the quick
/// terminal is `shown` (or not).
fn quickCli(h: *Harness, g: *Harness.Ghostty, class_arg: []const u8, shown: bool, comptime what: []const u8) !void {
    var r = try h.runCli("quick-cli", &.{ "+toggle-quick-terminal", class_arg });
    defer r.deinit();
    var waited: u32 = 0;
    while (waited < 5000) : (waited += 100) {
        if (try quickState(h, g)) |s| if (s.quick.shown == shown and s.visible == shown) break;
        w.Sleep(100);
    }
    const s = try quickState(h, g) orelse return h.fail("the quick terminal went", .{});
    try h.expect(r.code == 0 and s.quick.shown == shown and s.visible == shown, what ++ " (exit code {d})", .{r.code});
}

/// The tray really shown (roadmap 5.6): Windows takes its icon (the dump's
/// `notify_icon` counts it there only if Shell_NotifyIconW took it), and
/// it goes as murrtty quits. Off-screen on the user's desktop, whose
/// notification area it needs; the icon shows for a moment, so only with
/// GHOSTTY_GUI_ONSCREEN=1. It quits without a dialog, which would show on
/// screen.
fn trayShown(h: *Harness) anyerror!void {
    if (w.GetEnvironmentVariableW(w.L("GHOSTTY_GUI_ONSCREEN"), null, 0) == 0) {
        return h.skip("its icon shows in the notification area; set GHOSTTY_GUI_ONSCREEN=1 to run it", .{});
    }
    const Ctx = struct { h: *Harness, err: ?anyerror = null };
    var ctx: Ctx = .{ .h = h };
    h.runOnUserDesktop(&ctx, struct {
        fn run(cx: *Ctx) void {
            trayShownOffscreen(cx.h) catch |err| {
                cx.err = err;
            };
        }
    }.run);
    if (ctx.err) |err| return err;
}

fn trayShownOffscreen(h: *Harness) !void {
    var g = try h.launchWith("tray-shown", base_config ++ "command = powershell.exe -NoLogo -NoProfile\n" ++
        "quit-after-last-window-closed = false\nconfirm-close-surface = false\n", .{
        .where = .offscreen,
        .env = &.{.{ "GHOSTTY_WIN32_TEST_NOTIFY", "1" }},
    });
    defer g.deinit();
    try h.waitText(&g, "PS ", 1, 20000);
    {
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(d.value.tray and d.value.notify_icon, "Windows took the tray's icon", .{});
    }
    // A notification on it, taken back: the icon is deleted (its toast with
    // it) and comes straight back.
    const surf = try h.surface(&g, try h.mainWindow(&g));
    {
        const cmd = try oscCommand(h, "0", "]9;murrtty tray test");
        defer h.alloc.free(cmd);
        try h.typeText(surf, cmd);
        h.enter(surf);
    }
    _ = try waitNotifications(h, &g, 1);
    try h.withdrawNotification(&g);
    {
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(!d.value.notify_pending and d.value.notify_icon and d.value.tray, "a notification taken back leaves the tray's icon there", .{});
    }
    h.key(surf, .{ .ctrl = true, .shift = true }, 'Q');
    const code = g.waitExit(10000);
    try h.expect(code != null and code.? == 0, "and murrtty quits (exit code {?d})", .{code});
}

/// Whether the terminal menu's Notify on Next Command Finish is checked,
/// the menu closed again with Escape.
fn notifyNextChecked(h: *Harness, g: *Harness.Ghostty, surf: w.HWND) !bool {
    h.rightPress(surf, 40, 20);
    const menu = try h.waitMenu(g, 1, 5000);
    const checked = checked: {
        const items = try h.menuItems(menu);
        defer h.freeMenuItems(items);
        if (items.len < 3 or !std.mem.eql(u8, items[2].text, "&Notify on Next Command Finish")) {
            return h.fail("the menu's third item isn't Notify on Next Command Finish", .{});
        }
        break :checked items[2].checked;
    };
    h.menuKey(menu, 0x1B);
    try waitNoMenu(h, g);
    return checked;
}

/// notify-on-command-finish (roadmap 5.3), GTK's: with `always`, a command
/// that took longer than notify-on-command-finish-after notifies "Command
/// Succeeded" or "Command Failed" with its time and code, and a short one
/// doesn't; with `never`, the menu's Notify on Next Command Finish
/// (checked while set) notifies for the next one only.
fn commandFinishedScenario(h: *Harness) anyerror!void {
    const shell = "command = powershell.exe -NoLogo -NoProfile\nshell-integration = detect\n" ++
        "notify-on-command-finish-after = 1s\nnotify-on-command-finish-action = no-bell,notify\n";
    {
        var g = try start(h, "command-finished", shell ++ "notify-on-command-finish = always\n", "PS ");
        defer g.deinit();
        const surf = try h.surface(&g, try h.mainWindow(&g));
        try runForStatus(h, &g, surf, "Start-Sleep 2", 0);
        var s = try waitNotifications(h, &g, 1);
        try h.expect(std.mem.eql(u8, s.titleText(), "Command Succeeded") and std.mem.startsWith(u8, s.bodyText(), "Command took ") and std.mem.endsWith(u8, s.bodyText(), " and exited with code 0."), "a 2 s command notifies as GTK's: '{s}' / '{s}'", .{ s.titleText(), s.bodyText() });
        try runForStatus(h, &g, surf, "echo quick", 0);
        w.Sleep(500);
        try h.expect((try notifyState(h, &g)).count == 1, "one shorter than notify-on-command-finish-after doesn't", .{});
        try runForStatus(h, &g, surf, "Start-Sleep 2; cmd /c exit 3", 3);
        s = try waitNotifications(h, &g, 2);
        try h.expect(std.mem.eql(u8, s.titleText(), "Command Failed") and std.mem.endsWith(u8, s.bodyText(), " and exited with code 3."), "a failing one: '{s}' / '{s}'", .{ s.titleText(), s.bodyText() });
    }
    {
        // notify-on-command-finish = never, the default.
        var g = try start(h, "command-finished-next", shell, "PS ");
        defer g.deinit();
        const surf = try h.surface(&g, try h.mainWindow(&g));
        try runForStatus(h, &g, surf, "Start-Sleep 2", 0);
        w.Sleep(500);
        try h.expect((try notifyState(h, &g)).count == 0, "never: a long command doesn't notify", .{});
        try h.expect(!try notifyNextChecked(h, &g, surf), "Notify on Next Command Finish starts unchecked", .{});
        h.rightPress(surf, 40, 20);
        const menu = try h.waitMenu(&g, 1, 5000);
        h.menuKey(menu, 'n');
        try waitNoMenu(h, &g);
        try h.expect(try notifyNextChecked(h, &g, surf), "choosing it checks it", .{});
        try runForStatus(h, &g, surf, "Start-Sleep 2", 0);
        const s = try waitNotifications(h, &g, 1);
        try h.expect(std.mem.eql(u8, s.titleText(), "Command Succeeded"), "the next command notifies ('{s}')", .{s.titleText()});
        try h.expect(!try notifyNextChecked(h, &g, surf), "and it is unchecked again", .{});
        try runForStatus(h, &g, surf, "Start-Sleep 2", 0);
        w.Sleep(500);
        try h.expect((try notifyState(h, &g)).count == 1, "only the next one", .{});
    }
}

//---------------------------------------------------------------
// Progress (roadmap 5.4)

/// The first window's progress as the dump has it: the active tab's first
/// pane's bar (value -1 while it pulses, -2 for none) and the taskbar
/// button's.
const ProgressState = struct {
    value: i32 = -2,
    err: bool = false,
    paused: bool = false,
    pulse: f32 = 0,
    taskbar: [16]u8 = undefined,
    taskbar_len: usize = 0,
    taskbar_value: u32 = 0,
    width: i32 = 0,

    fn taskbarState(self: *const ProgressState) []const u8 {
        return self.taskbar[0..self.taskbar_len];
    }
};

fn progressState(h: *Harness, g: *Harness.Ghostty) !ProgressState {
    var d = try h.dump(g);
    defer d.deinit();
    const win = d.value.windows[0];
    var s: ProgressState = .{ .taskbar_value = win.taskbar.value };
    s.taskbar_len = @min(win.taskbar.state.len, s.taskbar.len);
    @memcpy(s.taskbar[0..s.taskbar_len], win.taskbar.state[0..s.taskbar_len]);
    const panes = win.tabs[win.active].panes orelse return s;
    if (panes.len == 0) return s;
    s.width = panes[0].rect[2] - panes[0].rect[0];
    if (panes[0].progress) |p| {
        s.value = p.value;
        s.err = p.err;
        s.paused = p.paused;
        s.pulse = p.pulse;
    }
    return s;
}

/// Write OSC 9;4 `params` from PowerShell in `surf` and wait until the bar
/// has `value` (-1 pulsing, -2 none).
fn sendProgress(h: *Harness, g: *Harness.Ghostty, surf: w.HWND, params: []const u8, value: i32) !ProgressState {
    const osc = try std.fmt.allocPrint(h.alloc, "]9;4;{s}", .{params});
    defer h.alloc.free(osc);
    const cmd = try oscCommand(h, "0", osc);
    defer h.alloc.free(cmd);
    try h.typeText(surf, cmd);
    h.enter(surf);
    return waitProgress(h, g, value, params);
}

fn waitProgress(h: *Harness, g: *Harness.Ghostty, value: i32, what: []const u8) !ProgressState {
    var waited: u32 = 0;
    while (waited <= 10000) : (waited += 200) {
        const s = try progressState(h, g);
        if (s.value == value) return s;
        w.Sleep(200);
    }
    return h.fail("OSC 9;4;{s}: the bar never had {d}", .{ what, value });
}

fn bluish(px: u32) bool {
    const r = px >> 16 & 0xFF;
    const b = px & 0xFF;
    return b > 0x90 and b > r + 0x50;
}

fn reddish(px: u32) bool {
    const r = px >> 16 & 0xFF;
    const g = px >> 8 & 0xFF;
    return r > g + 0x30;
}

/// OSC 9;4 (roadmap 5.4), as GTK's bar shows it over the pane: the accent
/// to the value, the error color at half opacity, a pulsing block, paused;
/// the window's taskbar button shows the active tab's (recorded: the
/// hidden desktop has no taskbar). A bar with no report for 15 s goes;
/// progress-style = false shows none.
fn progressScenario(h: *Harness) anyerror!void {
    const ps = base_config ++ "command = powershell.exe -NoLogo -NoProfile\n";
    var g = try h.launchWith("progress", ps, .{});
    defer g.deinit();
    try h.waitText(&g, "PS ", 1, 20000);
    const win = try h.mainWindow(&g);
    const surf = try h.surface(&g, win);

    var s = try sendProgress(h, &g, surf, "1;50", 50);
    try h.expect(!s.err and std.mem.eql(u8, s.taskbarState(), "normal") and s.taskbar_value == 50, "set 50: the bar and the taskbar at 50 ({s} {d})", .{ s.taskbarState(), s.taskbar_value });
    {
        const quarter: u32 = @intCast(@divTrunc(s.width, 4));
        const inside = try h.probePane(&g, 0, quarter, 1);
        const outside = try h.probePane(&g, 0, quarter * 3, 1);
        try h.expect(bluish(inside) and !bluish(outside), "the accent runs to the middle (#{x:0>6} at a quarter, #{x:0>6} at three quarters)", .{ inside, outside });
        const below = try h.probePane(&g, 0, quarter, 12);
        try h.expect(!bluish(below), "3 px tall: no accent below it (#{x:0>6})", .{below});
    }

    // The bar follows the pane's width: halved, a stale bar would cover it.
    {
        const old = s.width;
        try h.dragResize(&g, @intCast(-@divTrunc(old, 2)), 0);
        var waited: u32 = 0;
        while (s.width > old - @divTrunc(old, 4) and waited < 5000) : (waited += 100) {
            w.Sleep(100);
            s = try progressState(h, &g);
        }
        const quarter: u32 = @intCast(@divTrunc(s.width, 4));
        const inside = try h.probePane(&g, 0, quarter, 1);
        const outside = try h.probePane(&g, 0, quarter * 3, 1);
        try h.expect(s.width < old and bluish(inside) and !bluish(outside), "after a resize to {d} px it still runs to the middle (#{x:0>6}, #{x:0>6})", .{ s.width, inside, outside });
    }

    s = try sendProgress(h, &g, surf, "2;80", 80);
    try h.expect(s.err and std.mem.eql(u8, s.taskbarState(), "error") and s.taskbar_value == 80, "error 80: the error color, and on the taskbar ({s} {d})", .{ s.taskbarState(), s.taskbar_value });
    {
        const px = try h.probePane(&g, 0, @intCast(@divTrunc(s.width, 4)), 1);
        try h.expect(reddish(px), "the bar is the error color at half opacity (#{x:0>6})", .{px});
    }
    // A pulse after an error keeps its color, as GTK's `error` class stays;
    // entering the pulse starts the block at the left; the taskbar shows
    // the last report's state.
    s = try sendProgress(h, &g, surf, "3", -1);
    try h.expect(s.err and s.pulse == 0 and std.mem.eql(u8, s.taskbarState(), "indeterminate"), "indeterminate after an error: the error color, the block at the left ({d:.1}), indeterminate on the taskbar ({s})", .{ s.pulse, s.taskbarState() });
    {
        // Still pulsing (-1) when it lands: wait for the block to move.
        _ = try sendProgress(h, &g, surf, "3", -1);
        var waited: u32 = 0;
        while (s.pulse < 0.05 and waited < 10000) : (waited += 200) {
            w.Sleep(200);
            s = try progressState(h, &g);
        }
        try h.expect(s.pulse > 0.05 and s.pulse < 0.15, "the next one moves it a tenth ({d:.2})", .{s.pulse});
    }
    // ConEmu's set with no value is 0; it clears the error.
    s = try sendProgress(h, &g, surf, "1", 0);
    try h.expect(!s.err and std.mem.eql(u8, s.taskbarState(), "normal") and s.taskbar_value == 0, "set with no value: 0, no longer an error ({s} {d})", .{ s.taskbarState(), s.taskbar_value });
    s = try sendProgress(h, &g, surf, "4;30", 30);
    try h.expect(s.paused and std.mem.eql(u8, s.taskbarState(), "paused") and s.taskbar_value == 30, "pause 30 ({s} {d})", .{ s.taskbarState(), s.taskbar_value });
    s = try sendProgress(h, &g, surf, "2;10", 10);
    s = try sendProgress(h, &g, surf, "4;20", 20);
    try h.expect(s.err and std.mem.eql(u8, s.taskbarState(), "paused") and s.taskbar_value == 20, "paused after an error: still red, paused on the taskbar ({s} {d})", .{ s.taskbarState(), s.taskbar_value });
    s = try sendProgress(h, &g, surf, "0", -2);
    try h.expect(std.mem.eql(u8, s.taskbarState(), "none"), "remove: no bar, nothing on the taskbar ({s})", .{s.taskbarState()});
    s = try sendProgress(h, &g, surf, "3", -1);
    try h.expect(s.err, "the error color outlasts the removal, as GTK's class does", .{});
    s = try sendProgress(h, &g, surf, "0", -2);

    // The taskbar shows the active tab's.
    s = try sendProgress(h, &g, surf, "1;40", 40);
    h.key(surf, .{ .ctrl = true, .shift = true }, 'T');
    try waitWindowTabs(h, &g, win, 2);
    s = try waitProgress(h, &g, -2, "1;40 in the other tab");
    try h.expect(std.mem.eql(u8, s.taskbarState(), "none"), "a new tab without progress: nothing on the taskbar ({s})", .{s.taskbarState()});
    const back = try h.surface(&g, win);
    h.key(back, .{ .ctrl = true }, 0x09);
    s = try waitProgress(h, &g, 40, "1;40 back in its tab");
    try h.expect(std.mem.eql(u8, s.taskbarState(), "normal") and s.taskbar_value == 40, "back in its tab: 40 on the taskbar ({s} {d})", .{ s.taskbarState(), s.taskbar_value });

    // No report for 15 s, timed from a fresh one: gone.
    s = try sendProgress(h, &g, try h.surface(&g, win), "1;45", 45);
    const started = w.GetTickCount64();
    while (w.GetTickCount64() - started < 20000) {
        s = try progressState(h, &g);
        if (s.value == -2) break;
        w.Sleep(250);
    }
    const took = w.GetTickCount64() - started;
    try h.expect(s.value == -2 and took >= 13500 and took <= 17500 and std.mem.eql(u8, s.taskbarState(), "none"), "without a report it goes after 15 s (after {d} ms, taskbar {s})", .{ took, s.taskbarState() });

    var off = try h.launchWith("progress-off", ps ++ "progress-style = false\n", .{});
    defer off.deinit();
    try h.waitText(&off, "PS ", 1, 20000);
    const off_surf = try h.surface(&off, try h.mainWindow(&off));
    {
        const cmd = try oscCommand(h, "0", "]9;4;1;50");
        defer h.alloc.free(cmd);
        try h.typeText(off_surf, cmd);
        h.enter(off_surf);
    }
    try h.waitText(&off, "9;4;1;50' + [char]7)", 1, 10000);
    w.Sleep(1000);
    s = try progressState(h, &off);
    try h.expect(s.value == -2 and std.mem.eql(u8, s.taskbarState(), "none"), "progress-style = false: no bar", .{});
}

/// OSC 9;4 on a real taskbar button: off-screen on the user's desktop the
/// window gets one (TaskbarButtonCreated), and ITaskbarList3 takes its
/// progress (S_OK). Its button shows on the taskbar meanwhile, so only with
/// GHOSTTY_GUI_ONSCREEN=1.
fn taskbarShown(h: *Harness) anyerror!void {
    if (w.GetEnvironmentVariableW(w.L("GHOSTTY_GUI_ONSCREEN"), null, 0) == 0) {
        return h.skip("its button shows on the taskbar; set GHOSTTY_GUI_ONSCREEN=1 to run it", .{});
    }
    const Ctx = struct { h: *Harness, err: ?anyerror = null };
    var ctx: Ctx = .{ .h = h };
    h.runOnUserDesktop(&ctx, struct {
        fn run(cx: *Ctx) void {
            taskbarShownOffscreen(cx.h) catch |err| {
                cx.err = err;
            };
        }
    }.run);
    if (ctx.err) |err| return err;
}

fn taskbarShownOffscreen(h: *Harness) !void {
    var g = try h.launchWith("taskbar-shown", base_config ++ "command = powershell.exe -NoLogo -NoProfile\n", .{ .where = .offscreen });
    defer g.deinit();
    try h.waitText(&g, "PS ", 1, 20000);
    const surf = try h.surface(&g, try h.mainWindow(&g));
    for ([_]struct { []const u8, i32, []const u8 }{
        // Each a value of its own, which the wait looks for.
        .{ "1;60", 60, "normal" },
        .{ "2;70", 70, "error" },
        .{ "0", -2, "none" },
    }) |case| {
        _ = try sendProgress(h, &g, surf, case[0], case[1]);
        var d = try h.dump(&g);
        defer d.deinit();
        const t = d.value.windows[0].taskbar;
        try h.expect(t.ready and std.mem.eql(u8, t.state, case[2]) and t.hr == 0, "9;4;{s}: the button shows {s} (ready {}, hr {d})", .{ case[0], case[2], t.ready, t.hr });
    }
}

//---------------------------------------------------------------
// Global key bindings (roadmap 5.5)

/// murrtty's global binding written `trigger` (its mods and virtual key),
/// or null.
fn globalKey(h: *Harness, g: *Harness.Ghostty, trigger: []const u8) !?Harness.Dump.Global {
    var d = try h.dump(g);
    defer d.deinit();
    for (d.value.globals) |k| if (std.mem.eql(u8, k.trigger, trigger)) return .{ .mods = k.mods, .vk = k.vk };
    return null;
}

/// How many notifications murrtty sent end with `suffix`.
fn notifiedEnding(h: *Harness, g: *Harness.Ghostty, suffix: []const u8) !usize {
    var d = try h.dump(g);
    defer d.deinit();
    var n: usize = 0;
    for (d.value.notifications) |note| {
        if (std.mem.eql(u8, note.title, "Global keybind unavailable") and std.mem.endsWith(u8, note.body, suffix)) n += 1;
    }
    return n;
}

fn visibleWindows(h: *Harness, g: *Harness.Ghostty) !usize {
    const wins = try h.windows(g, "MurrttyWindow");
    defer h.alloc.free(wins);
    return wins.len;
}

/// Whether a murrtty other than `pid` runs on this desktop (its wakeup
/// window): one then holding a key would keep murrtty quiet about it.
fn otherMurrtty(pid: w.DWORD) bool {
    var prev: ?w.HWND = null;
    while (w.FindWindowExW(w.HWND_MESSAGE, prev, w.L("MurrttyWakeup"), null)) |hwnd| {
        var owner: w.DWORD = 0;
        _ = w.GetWindowThreadProcessId(hwnd, &owner);
        if (owner != pid) return true;
        prev = hwnd;
    }
    return false;
}

fn waitHidden(h: *Harness, g: *Harness.Ghostty) !void {
    var waited: u32 = 0;
    while (try visibleWindows(h, g) != 0 and waited < 3000) : (waited += 100) w.Sleep(100);
}

/// global: bindings as hot keys (roadmap 5.5): registered, a hot key runs
/// its binding (new_window) and waits for an open dialog, toggle_visibility
/// hides every window while murrtty is in front, shows them again, and
/// otherwise brings murrtty forward; one that can't be had is told once, as
/// GTK's "Global keybind unavailable" notification: another program holds
/// it, a lock modifier, a keypad key Windows can't tell apart, two of
/// murrtty's own on the same keys. A config left with no binding to show
/// hidden windows brings them back. A key another murrtty holds passes to
/// this one when that one quits. Hot keys are posted, never pressed.
fn globalKeysScenario(h: *Harness) anyerror!void {
    const mods = w.MOD_CONTROL | w.MOD_ALT | w.MOD_SHIFT;
    // F12 and F11 must be free for murrtty; the harness holds F10 itself.
    for ([_]c_uint{ 0x7B, 0x7A }) |vk| {
        if (w.RegisterHotKey(null, 0x4D00, mods, vk) == 0) return h.skip("Ctrl+Alt+Shift+F{d} is taken here", .{vk - 0x6F});
        _ = w.UnregisterHotKey(null, 0x4D00);
    }
    // The clash: the character a and the key A's scan code (where this
    // layout types a there), when Ctrl+Alt+Shift+A is free.
    const clash = clash: {
        if (w.MapVirtualKeyW(0x1E, w.MAPVK_VSC_TO_VK) != 'A') break :clash false;
        if (w.RegisterHotKey(null, 0x4D00, mods, 'A') == 0) break :clash false;
        _ = w.UnregisterHotKey(null, 0x4D00);
        break :clash true;
    };
    if (w.RegisterHotKey(null, 0x4D01, mods, 0x79) == 0) return h.skip("Ctrl+Alt+Shift+F10 is taken here", .{});
    defer _ = w.UnregisterHotKey(null, 0x4D01);

    const bindings = "keybind = global:ctrl+alt+shift+f12=new_window\n" ++
        "keybind = global:ctrl+alt+shift+f11=toggle_visibility\n" ++
        "keybind = global:ctrl+alt+shift+f10=new_tab\n" ++
        "keybind = global:ctrl+alt+shift+caps_lock+f9=new_tab\n" ++
        "keybind = global:ctrl+alt+shift+numpad_enter=new_tab\n";
    const letters = "keybind = global:ctrl+alt+shift+a=new_tab\n" ++
        "keybind = global:ctrl+alt+shift+key_a=new_tab\n";
    var g = try start(h, "global-keys", if (clash) bindings ++ letters else bindings, ">");
    defer g.deinit();
    const win = try h.mainWindow(&g);
    const surf = try h.surface(&g, win);
    const new_window = try globalKey(h, &g, "Ctrl+Shift+Alt+F12") orelse return h.fail("Ctrl+Shift+Alt+F12 isn't registered", .{});
    const toggle = try globalKey(h, &g, "Ctrl+Shift+Alt+F11") orelse return h.fail("Ctrl+Shift+Alt+F11 isn't registered", .{});
    try h.expect(new_window.mods == mods and new_window.vk == 0x7B, "registered as Ctrl+Alt+Shift and F12's key (mods {d}, vk {d})", .{ new_window.mods, new_window.vk });
    try h.expect(try globalKey(h, &g, "Ctrl+Shift+Alt+F10") == null, "the held one isn't registered", .{});
    // With another murrtty here (the owner's, under --visible) it could be
    // that one's: then murrtty keeps quiet and tries again.
    const others = otherMurrtty(g.pid);
    if (others) {
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(d.value.globals_waiting == 1 and try notifiedEnding(h, &g, "Ctrl+Shift+Alt+F10: Windows or another program already uses it.") == 0, "with another murrtty here, the held one waits untold", .{});
    } else try h.expect(try notifiedEnding(h, &g, "Ctrl+Shift+Alt+F10: Windows or another program already uses it.") == 1, "the held one is told as GTK's", .{});
    try h.expect(try notifiedEnding(h, &g, ": Caps Lock and Num Lock can't be part of a global binding.") == 1, "a lock modifier is refused and told", .{});
    try h.expect(try notifiedEnding(h, &g, ": Windows can't tell this key from another one.") == 1, "the keypad's Enter is refused and told", .{});
    const told: usize = @as(usize, if (clash) 4 else 3) - @intFromBool(others);
    if (clash) {
        var d = try h.dump(&g);
        defer d.deinit();
        var on_a: usize = 0;
        for (d.value.globals) |k| on_a += @intFromBool(k.vk == 'A');
        try h.expect(on_a == 1, "of a and key_a, one has Ctrl+Alt+Shift+A ({d})", .{on_a});
        try h.expect(try notifiedEnding(h, &g, ": Another of murrtty's global bindings uses the same keys.") == 1, "and the other is told", .{});
    }
    try h.expect((try notifyState(h, &g)).count == told, "each told once ({d})", .{(try notifyState(h, &g)).count});

    // A keyboard layout change registers them again, telling nothing anew.
    const refreshes = refreshes: {
        var d = try h.dump(&g);
        defer d.deinit();
        break :refreshes d.value.global_refreshes;
    };
    _ = w.PostMessageW(win, w.WM_INPUTLANGCHANGE, 0, 0);
    h.sync(win);
    {
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(d.value.global_refreshes == refreshes + 1, "a layout change registers them again ({d} after {d})", .{ d.value.global_refreshes, refreshes });
    }
    try h.expect(try globalKey(h, &g, "Ctrl+Shift+Alt+F12") != null and (try notifyState(h, &g)).count == told, "and keeps them, telling nothing again", .{});

    try h.hotkey(&g, new_window);
    try waitWindowCount(h, &g, 2);
    try h.expect(true, "its hot key runs new_window", .{});

    // In front, toggle_visibility hides both; then shows them.
    try h.setInFront(&g, .yes);
    try h.hotkey(&g, toggle);
    try waitHidden(h, &g);
    {
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(try visibleWindows(h, &g) == 0 and d.value.windows_hidden and d.value.hidden_windows.len == 2 and d.value.windows.len == 2, "in front, toggle_visibility hides both windows", .{});
    }
    try h.hotkey(&g, toggle);
    try waitWindowCount(h, &g, 2);
    {
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(!d.value.windows_hidden and d.value.hidden_windows.len == 0, "and shows them again", .{});
    }
    // Not in front, it brings murrtty forward and hides nothing.
    try h.setInFront(&g, .no);
    try h.hotkey(&g, toggle);
    w.Sleep(300);
    {
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(try visibleWindows(h, &g) == 2 and !d.value.windows_hidden, "not in front, it hides nothing", .{});
    }

    // A hot key while a dialog is open waits for it to close.
    h.key(surf, .{ .ctrl = true, .shift = true }, 'W');
    const dlg = try h.waitDialog(&g, 5000);
    try h.hotkey(&g, new_window);
    {
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(d.value.hotkeys_pending == 1 and d.value.windows.len == 2, "under a dialog the hot key waits ({d} pending, {d} windows)", .{ d.value.hotkeys_pending, d.value.windows.len });
    }
    h.answer(&g, dlg, w.IDCANCEL);
    try waitWindowCount(h, &g, 3);
    try h.expect(true, "and runs once the dialog closes", .{});

    // Hidden, then a config with no global binding: they come back.
    try h.setInFront(&g, .yes);
    try h.hotkey(&g, toggle);
    try waitHidden(h, &g);
    try h.expect(try visibleWindows(h, &g) == 0, "hidden again", .{});
    const cfg_path = try std.fmt.allocPrint(h.alloc, "{s}\\murrtty\\config.ghostty", .{g.dir});
    defer h.alloc.free(cfg_path);
    try h.writeFileAt(cfg_path, base_config);
    h.key(surf, .{ .ctrl = true, .shift = true }, w.VK_OEM_COMMA);
    try waitWindowCount(h, &g, 3);
    {
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(!d.value.windows_hidden and d.value.globals.len == 0, "a config with no global binding brings them back", .{});
    }

    // With no global binding nothing could bring them back: it hides none.
    {
        var plain = try start(h, "global-keys-none", "keybind = ctrl+shift+f9=toggle_visibility\n", ">");
        defer plain.deinit();
        try h.setInFront(&plain, .yes);
        h.key(try h.surface(&plain, try h.mainWindow(&plain)), .{ .ctrl = true, .shift = true }, 0x78);
        w.Sleep(500);
        var d = try h.dump(&plain);
        defer d.deinit();
        try h.expect(d.value.toggles == 1 and try visibleWindows(h, &plain) == 1 and !d.value.windows_hidden, "without a global binding toggle_visibility runs and hides nothing ({d} runs)", .{d.value.toggles});
    }

    // A key another murrtty holds: kept quiet, and taken once it quits.
    const f12 = "keybind = global:ctrl+alt+shift+f12=new_window\n";
    var holder = try start(h, "global-keys-holder", f12, ">");
    defer holder.deinit();
    try h.expect(try globalKey(h, &holder, "Ctrl+Shift+Alt+F12") != null, "one murrtty holds Ctrl+Alt+Shift+F12", .{});
    var second = try start(h, "global-keys-second", f12, ">");
    defer second.deinit();
    {
        var d = try h.dump(&second);
        defer d.deinit();
        try h.expect(d.value.globals.len == 0 and d.value.globals_waiting == 1 and d.value.notifications.len == 0, "a second one waits for it, untold", .{});
    }
    try quit(h, &holder, try h.surface(&holder, try h.mainWindow(&holder)));
    var waited: u32 = 0;
    while (waited < 8000) : (waited += 250) {
        if (try globalKey(h, &second, "Ctrl+Shift+Alt+F12") != null) break;
        w.Sleep(250);
    }
    {
        var d = try h.dump(&second);
        defer d.deinit();
        try h.expect(d.value.globals.len == 1 and d.value.globals_waiting == 0 and d.value.notifications.len == 0, "and takes it once the first quits ({d} ms)", .{waited});
    }
}

//---------------------------------------------------------------
// The tray and background mode (roadmap 5.6)

/// Close the window `win` with the `close_window` binding (Ctrl+Shift+F8
/// in these configs), answering its confirmation, and wait until murrtty
/// has no window left (or has quit with it).
fn closeLastWindow(h: *Harness, g: *Harness.Ghostty, win: w.HWND) !void {
    h.key(try h.surface(g, win), .{ .ctrl = true, .shift = true }, 0x77);
    h.answer(g, try h.waitDialog(g, 5000), w.IDYES);
    // No dump here: murrtty may be quitting with its window, its wakeup
    // window already gone.
    var waited: u32 = 0;
    while (waited < 10000) : (waited += 100) {
        if (g.waitExit(100) != null or try visibleWindows(h, g) == 0) return;
    }
    return h.fail("the window didn't close", .{});
}

/// The dump, once murrtty answers (no window to wait for).
fn waitDump(h: *Harness, g: *Harness.Ghostty) !std.json.Parsed(Harness.Dump) {
    try h.waitAnswering(g, 15000);
    return h.dump(g);
}

/// With quit-after-last-window-closed = false the tray's icon stays and
/// murrtty outlives its last window; a click on the icon opens a window or
/// shows those toggle_visibility hid (no global binding needed then); its
/// menu offers New Window, Config and Quit; a notification's balloon comes
/// and goes on it. initial-window = false starts in the tray. A delay
/// keeps murrtty, trayless, until it passes.
fn trayScenario(h: *Harness) anyerror!void {
    // A dark start: the color scheme's reload reaches the config change
    // before the first window, which must not quit.
    {
        var g = try start(h, "tray-dark", "window-theme = dark\n", ">");
        defer g.deinit();
        try h.expect(g.waitExit(1500) == null, "a dark start doesn't quit", .{});
    }
    {
        var g = try h.launchWith("tray", base_config ++ "command = powershell.exe -NoLogo -NoProfile\n" ++
            "quit-after-last-window-closed = false\n" ++
            "keybind = ctrl+shift+f8=close_window\n" ++
            "keybind = ctrl+shift+f9=toggle_visibility\n", .{});
        defer g.deinit();
        try h.waitText(&g, "PS ", 1, 20000);
        const win = try h.mainWindow(&g);
        {
            var d = try h.dump(&g);
            defer d.deinit();
            try h.expect(d.value.tray and d.value.notify_icon and !d.value.notify_pending, "the tray's icon is there", .{});
        }

        // A notification on it, from the pane with the keyboard: it goes
        // after 3 s, the icon stays.
        {
            const cmd = try oscCommand(h, "0", "]9;tray test");
            defer h.alloc.free(cmd);
            const surf = try h.surface(&g, win);
            try h.typeText(surf, cmd);
            h.enter(surf);
        }
        _ = try waitNotifications(h, &g, 1);
        {
            var d = try h.dump(&g);
            defer d.deinit();
            try h.expect(d.value.notify_pending and d.value.notify_icon, "a notification stands on it", .{});
        }
        var waited: u32 = 0;
        while (waited < 6000) : (waited += 200) {
            var d = try h.dump(&g);
            defer d.deinit();
            if (!d.value.notify_pending) break;
            w.Sleep(200);
        }
        {
            var d = try h.dump(&g);
            defer d.deinit();
            try h.expect(!d.value.notify_pending and d.value.notify_icon and d.value.tray, "and goes, leaving the tray's icon", .{});
        }

        // Hidden without a global binding: the tray shows them again.
        try h.setInFront(&g, .yes);
        h.key(try h.surface(&g, win), .{ .ctrl = true, .shift = true }, 0x78);
        try waitHidden(h, &g);
        try h.expect(try visibleWindows(h, &g) == 0, "with the tray, toggle_visibility hides without a global binding", .{});
        try h.trayEvent(&g, .select, 0, 0);
        try waitWindowCount(h, &g, 1);
        {
            var d = try h.dump(&g);
            defer d.deinit();
            try h.expect(!d.value.windows_hidden, "and a click on the icon shows them", .{});
        }
        try h.setInFront(&g, .real);

        // The last window closed: murrtty stays in the tray.
        try closeLastWindow(h, &g, win);
        try h.expect(g.waitExit(1500) == null, "murrtty outlives its last window", .{});
        {
            var d = try h.dump(&g);
            defer d.deinit();
            try h.expect(d.value.tray and std.mem.eql(u8, d.value.quit_timer, "off"), "in the tray, with no quit timer ({s})", .{d.value.quit_timer});
        }
        // A click opens a window.
        try h.trayEvent(&g, .select, 0, 0);
        try waitWindowCount(h, &g, 1);
        try h.expect(true, "a click on the icon opens a window", .{});

        // Hidden, then its shell exits: nothing stays hidden, and one click
        // opens a window again.
        {
            try h.waitText(&g, "PS ", 1, 20000);
            const surf = try h.surface(&g, try h.mainWindow(&g));
            try h.setInFront(&g, .yes);
            h.key(surf, .{ .ctrl = true, .shift = true }, 0x78);
            try waitHidden(h, &g);
            try h.typeText(surf, "exit");
            h.enter(surf);
            var gone: u32 = 0;
            while (gone < 10000) : (gone += 200) {
                var d = try h.dump(&g);
                defer d.deinit();
                if (d.value.windows.len == 0) break;
                w.Sleep(200);
            }
            {
                var d = try h.dump(&g);
                defer d.deinit();
                try h.expect(d.value.windows.len == 0 and !d.value.windows_hidden and d.value.hidden_windows.len == 0, "a hidden window whose shell exits leaves nothing hidden", .{});
            }
            try h.setInFront(&g, .real);
            try h.trayEvent(&g, .select, 0, 0);
            try waitWindowCount(h, &g, 1);
            try h.expect(true, "and one click opens a window", .{});
        }

        // The menu: New Window, Config, Quit.
        try h.trayEvent(&g, .menu, 200, 200);
        {
            const menu = try h.waitMenu(&g, 1, 5000);
            const items = try h.menuItems(menu);
            defer h.freeMenuItems(items);
            var labels: [8][]const u8 = undefined;
            var n: usize = 0;
            for (items) |it| if (!it.separator and n < labels.len) {
                labels[n] = it.text;
                n += 1;
            };
            const ok = n == 4 and std.mem.startsWith(u8, labels[0], "New &Window") and
                std.mem.startsWith(u8, labels[1], "Quick &Terminal") and
                std.mem.eql(u8, labels[2], "C&onfig") and std.mem.startsWith(u8, labels[3], "&Quit");
            try h.expect(ok and items[3].submenu, "the menu: New Window, Quick Terminal, Config, Quit ({d} items)", .{n});
            h.menuKey(menu, 'w');
        }
        try waitWindowCount(h, &g, 2);
        try h.expect(true, "its New Window opens one", .{});
        try h.trayEvent(&g, .menu, 200, 200);
        h.menuKey(try h.waitMenu(&g, 1, 5000), 'q');
        h.answer(&g, try h.waitDialog(&g, 5000), w.IDYES);
        const code = g.waitExit(10000);
        try h.expect(code != null and code.? == 0, "its Quit quits (exit code {?d})", .{code});
    }

    // initial-window = false: in the tray with no window; a second such
    // launch just ends, as GTK's; a click opens a window, and
    // (quit-after-last-window-closed being true) closing it quits.
    {
        const class = try ipcClass(h, "tray");
        defer h.alloc.free(class);
        const cfg = try std.fmt.allocPrint(h.alloc, "{s}initial-window = false\ngtk-single-instance = true\nclass = {s}\n" ++
            "keybind = ctrl+shift+f8=close_window\n", .{ base_config, class });
        defer h.alloc.free(cfg);
        var g = try h.launchWith("tray-initial", cfg, .{ .wait_window = false });
        defer g.deinit();
        {
            var d = try waitDump(h, &g);
            defer d.deinit();
            try h.expect(d.value.tray and d.value.windows.len == 0 and !d.value.requested_window, "initial-window = false starts in the tray, with no window", .{});
        }
        h.alloc.free(try waitListening(h, &g, 10000));
        try h.expect(g.waitExit(1000) == null, "and stays", .{});
        {
            var second = try h.launchWith("tray-initial-2", cfg, .{ .wait_window = false });
            defer second.deinit();
            const code = second.waitExit(10000);
            try h.expect(code != null and code.? == 0, "a second launch with no initial window ends: one already runs (exit code {?d})", .{code});
        }
        try h.trayEvent(&g, .select, 0, 0);
        try waitWindowCount(h, &g, 1);
        try h.waitText(&g, ">", 1, 20000);
        try closeLastWindow(h, &g, try h.mainWindow(&g));
        const code = g.waitExit(5000);
        try h.expect(code != null and code.? == 0, "its window closed, it quits (exit code {?d})", .{code});
    }

    // A delay: no tray, and murrtty outlives its last window by it.
    {
        var g = try start(h, "tray-delay", "quit-after-last-window-closed-delay = 3s\n" ++
            "keybind = ctrl+shift+f8=close_window\n", ">");
        defer g.deinit();
        try closeLastWindow(h, &g, try h.mainWindow(&g));
        {
            var d = try h.dump(&g);
            defer d.deinit();
            try h.expect(!d.value.tray and std.mem.eql(u8, d.value.quit_timer, "active"), "with a delay the quit timer runs, with no tray ({s})", .{d.value.quit_timer});
        }
        try h.expect(g.waitExit(1000) == null, "murrtty waits for it", .{});
        const code = g.waitExit(10000);
        try h.expect(code != null and code.? == 0, "and quits once it passes (exit code {?d})", .{code});
    }
}

//---------------------------------------------------------------
// Drag and drop onto a terminal (roadmap 5.8)

/// Dropped files paste as their paths, separated by spaces and quoted for
/// the pane's shell where it would split or expand them (double quotes for
/// cmd, single quotes for PowerShell), and dropped text as it is, through
/// the core's paste; a drag with neither is refused. The drop goes through each pane's real drop target (DragEnter,
/// Drop), with OLE's data object for the clipboard standing in for a drag's
/// (the hidden desktop has no mouse to drag with).
fn dropScenario(h: *Harness) anyerror!void {
    var saved = try h.saveClipboard();
    defer saved.restore();
    var g = try start(h, "drop", "", ">");
    defer g.deinit();
    {
        var d = try h.dump(&g);
        defer d.deinit();
        const panes = d.value.windows[0].tabs[0].panes orelse return h.fail("no panes", .{});
        try h.expect(panes[0].drop_target, "the pane is a drop target", .{});
    }

    try h.setClipboardFiles(&.{ "C:\\murrtty-drop\\plain.txt", "C:\\murrtty drop\\with space.txt", "D:\\a&b.log" });
    const files = try h.dropClipboard(&g);
    try h.expect(files == 1, "files drop as a copy (effect {d})", .{files});
    try waitWindowText(h, &g, 0, "C:\\murrtty-drop\\plain.txt \"C:\\murrtty drop\\with space.txt\" \"D:\\a&b.log\"");
    try h.expect(true, "they paste as their paths, quoted where a shell would split them", .{});
    // Clear the prompt's line for the next.
    h.key(try h.surface(&g, try h.mainWindow(&g)), .{}, w.VK_ESCAPE);

    try h.setClipboard("echo murrtty-dropped-text");
    const text = try h.dropClipboard(&g);
    try h.expect(text == 1, "text drops as a copy (effect {d})", .{text});
    try waitWindowText(h, &g, 0, "echo murrtty-dropped-text");
    try h.expect(true, "and pastes as it is", .{});

    try h.clearClipboard();
    const nothing = try h.dropClipboard(&g);
    try h.expect(nothing == 0, "a drag with neither files nor text is refused (effect {d})", .{nothing});

    // PowerShell: single quotes, in which nothing expands, its quotes
    // doubled; a name that would run code stays a name.
    var p = try h.launchWith("drop-pwsh", base_config ++ "command = powershell.exe -NoLogo -NoProfile\n", .{});
    defer p.deinit();
    try h.waitText(&p, "PS ", 1, 20000);
    try h.setClipboardFiles(&.{ "C:\\murrtty-drop\\plain.txt", "D:\\a$(Remove-Item x)'s.txt" });
    const pwsh = try h.dropClipboard(&p);
    try h.expect(pwsh == 1, "files drop on a PowerShell pane (effect {d})", .{pwsh});
    try waitWindowText(h, &p, 0, "C:\\murrtty-drop\\plain.txt 'D:\\a$(Remove-Item x)''s.txt'");
    try h.expect(true, "single-quoted for PowerShell, where nothing expands, its quote doubled", .{});
}

//---------------------------------------------------------------
// The selection clipboard (roadmap 5.9)

/// murrtty's own selection clipboard (Windows has no primary selection):
/// with copy-on-select = primary, the default here as GTK's, a selection
/// (a double-clicked word) goes to it and not the system clipboard; a
/// middle click and paste_from_selection paste it.
fn selectionScenario(h: *Harness) anyerror!void {
    var saved = try h.saveClipboard();
    defer saved.restore();
    try h.setClipboard("murrtty-system-clip");
    var g = try start(h, "selection", "keybind = ctrl+shift+f7=paste_from_selection\n", ">");
    defer g.deinit();
    const surf = try h.surface(&g, try h.mainWindow(&g));
    try h.typeText(surf, "echo murrttyselword");
    h.enter(surf);
    try waitOutputSettled(h, &g, "murrttyselword");

    // The output's word (after cmd's banner), double-clicked: two presses,
    // as a pane's class takes no WM_LBUTTONDBLCLK (the core counts them).
    const at = try cellPoint(h, &g, "murrttyselword");
    h.click(surf, at.x, at.y, .left);
    h.click(surf, at.x, at.y, .left);
    var waited: u32 = 0;
    while (waited < 3000) : (waited += 100) {
        var d = try h.dump(&g);
        defer d.deinit();
        if (d.value.selection.len > 0) break;
        w.Sleep(100);
    }
    {
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(std.mem.eql(u8, d.value.selection, "murrttyselword"), "a double-clicked word goes to the selection clipboard ('{s}')", .{d.value.selection});
    }
    const system = try h.getClipboard();
    defer if (system) |s| h.alloc.free(s);
    try h.expect(system != null and std.mem.eql(u8, system.?, "murrtty-system-clip"), "and not the system clipboard ('{s}')", .{system orelse ""});

    // A middle click pastes it at the prompt; paste_from_selection again.
    h.click(surf, at.x, at.y, .middle);
    try waitWindowText(h, &g, 0, ">murrttyselword");
    try h.expect(true, "a middle click pastes it", .{});
    h.key(surf, .{ .ctrl = true, .shift = true }, 0x76);
    try waitWindowText(h, &g, 0, ">murrttyselwordmurrttyselword");
    try h.expect(true, "and paste_from_selection", .{});
}

// ---------------------------------------------------------------- session restore

/// session.json as murrtty writes it (roadmap 5.10b), as far as read here.
const SavedSession = struct {
    version: u32 = 0,
    front: ?u32 = null,
    windows: []const Win = &.{},

    const Win = struct {
        quick: bool = false,
        name: ?[]const u8 = null,
        left: i32 = 0,
        top: i32 = 0,
        right: i32 = 0,
        bottom: i32 = 0,
        maximized: bool = false,
        fullscreen: bool = false,
        active: u32 = 0,
        tabs: []const Tab = &.{},
    };
    const Tab = struct {
        name: ?[]const u8 = null,
        focused: u32 = 0,
        nodes: []const Node = &.{},
    };
    const Node = struct {
        pane: ?Pane = null,
        split: ?Split = null,
    };
    const Split = struct {
        layout: []const u8 = "horizontal",
        ratio: f32 = 0.5,
        left: u32 = 0,
        right: u32 = 0,
    };
    const Pane = struct {
        id: []const u8 = "",
        directory: ?[]const u8 = null,
        program: ?Program = null,
        name: ?[]const u8 = null,
    };
    const Program = struct {
        direct: ?[]const []const u8 = null,
        shell: ?[]const u8 = null,
    };

    fn tabCount(self: SavedSession) usize {
        return if (self.windows.len > 0) self.windows[0].tabs.len else 0;
    }

    /// The first window's first tab's root split, if it is one.
    fn rootSplit(self: SavedSession) ?Split {
        if (self.windows.len == 0 or self.windows[0].tabs.len == 0) return null;
        const nodes = self.windows[0].tabs[0].nodes;
        return if (nodes.len > 0) nodes[0].split else null;
    }

    fn findPane(self: SavedSession, id: []const u8) ?Pane {
        for (self.windows) |win| for (win.tabs) |tab| for (tab.nodes) |n| {
            if (n.pane) |p| if (std.mem.eql(u8, p.id, id)) return p;
        };
        return null;
    }
};

fn readSession(h: *Harness, path: []const u8) ?std.json.Parsed(SavedSession) {
    const text = h.readFileOrNull(path) orelse return null;
    defer h.alloc.free(text);
    return std.json.parseFromSlice(SavedSession, h.alloc, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
}

/// Read the session file until `ok` holds or `ms` pass; the last read
/// either way (the caller's checks then say what is wrong).
fn waitSession(h: *Harness, path: []const u8, ms: u32, ctx: anytype, comptime ok: fn (@TypeOf(ctx), SavedSession) bool) !std.json.Parsed(SavedSession) {
    var waited: u32 = 0;
    while (true) : (waited += 100) {
        if (readSession(h, path)) |p| {
            if (ok(ctx, p.value) or waited >= ms) return p;
            p.deinit();
        } else if (waited >= ms) return h.fail("no session in {s}", .{path});
        w.Sleep(100);
    }
}

fn userHome(h: *Harness) ![]u8 {
    var buf: [512]u16 = undefined;
    const n = w.GetEnvironmentVariableW(w.L("USERPROFILE"), &buf, buf.len);
    return std.unicode.utf16LeToUtf8Alloc(h.alloc, buf[0..n]);
}

/// The same folder, as Windows compares names (case, a trailing backslash).
fn sameDir(a: ?[]const u8, b: []const u8) bool {
    const x = std.mem.trimEnd(u8, a orelse return false, "\\");
    return std.ascii.eqlIgnoreCase(x, std.mem.trimEnd(u8, b, "\\"));
}

/// Roadmap 5.10b: murrtty saves its session as it changes, to session.json
/// in its state folder (the scenario's own here): at start its window, a
/// tab and its pane's directory; a new tab, the tab in front and a split as
/// they come. A window moved is saved once the move ends (WM_EXITSIZEMOVE),
/// a divider once it is let go; a divider drag Esc cancels saves nothing,
/// nor one murrtty ends in the middle of. A state folder murrtty can't
/// write is said in a dialog, once a run.
fn sessionSave(h: *Harness) anyerror!void {
    const path = try std.fmt.allocPrint(h.alloc, "{s}\\session-save\\state\\murrtty\\session.json", .{h.temp_dir});
    defer h.alloc.free(path);
    const home = try userHome(h);
    defer h.alloc.free(home);
    var before_kill: ?[]u8 = null;
    defer if (before_kill) |b| h.alloc.free(b);
    {
        var g = try start(h, "session-save", "keybind = ctrl+shift+f7=goto_tab:1\n", ">");
        defer g.deinit();
        const win = try h.mainWindow(&g);

        // At start: the window, a tab, a pane in its directory.
        {
            var s = try waitSession(h, path, 5000, @as([]const u8, home), struct {
                fn ok(want: []const u8, v: SavedSession) bool {
                    if (v.tabCount() != 1) return false;
                    const nodes = v.windows[0].tabs[0].nodes;
                    return nodes.len == 1 and nodes[0].pane != null and sameDir(nodes[0].pane.?.directory, want);
                }
            }.ok);
            defer s.deinit();
            try h.expect(s.value.version == 1 and s.value.windows.len == 1 and s.value.tabCount() == 1, "at start the file has the window and its tab (version {d}, {d} windows, {d} tabs)", .{ s.value.version, s.value.windows.len, s.value.tabCount() });
            const nodes = s.value.windows[0].tabs[0].nodes;
            const pane = if (nodes.len == 1) nodes[0].pane else null;
            try h.expect(pane != null and sameDir(pane.?.directory, home) and pane.?.id.len == 16, "and its pane, in its directory ({s}), with an id", .{if (pane) |p| p.directory orelse "none" else "no pane"});
        }

        // A new tab, in front; then the first in front again.
        h.key(try h.surface(&g, win), .{ .ctrl = true, .shift = true }, 'T');
        {
            var s = try waitSession(h, path, 5000, {}, struct {
                fn ok(_: void, v: SavedSession) bool {
                    return v.tabCount() == 2 and v.windows[0].active == 1;
                }
            }.ok);
            defer s.deinit();
            try h.expect(s.value.tabCount() == 2 and s.value.windows[0].active == 1, "a new tab is saved, in front ({d} tabs)", .{s.value.tabCount()});
        }
        try waitWindowTabText(h, &g, 0, 1, ">");
        h.key(try paneHwnd(h, &g, 0), .{ .ctrl = true, .shift = true }, w.VK_F7);
        {
            var s = try waitSession(h, path, 5000, {}, struct {
                fn ok(_: void, v: SavedSession) bool {
                    return v.tabCount() == 2 and v.windows[0].active == 0;
                }
            }.ok);
            defer s.deinit();
            try h.expect(s.value.tabCount() == 2 and s.value.windows[0].active == 0, "and the tab in front as it changes (active {d})", .{if (s.value.windows.len > 0) s.value.windows[0].active else 99});
        }

        // Windows asking to end its session holds the file as it is (the
        // shells end first, and their panes close); called off, saving
        // goes on.
        {
            var result: usize = 0;
            _ = w.SendMessageTimeoutW(win, w.WM_QUERYENDSESSION, 0, w.ENDSESSION_LOGOFF, w.SMTO_ABORTIFHUNG, 5000, &result);
            h.key(try paneHwnd(h, &g, 0), .{ .ctrl = true, .shift = true }, 'T');
            w.Sleep(1500);
            {
                var s = readSession(h, path) orelse return h.fail("no session file", .{});
                defer s.deinit();
                try h.expect(s.value.tabCount() == 2, "while Windows ends its session a new tab isn't saved ({d} tabs)", .{s.value.tabCount()});
            }
            _ = w.SendMessageTimeoutW(win, w.WM_ENDSESSION, 0, w.ENDSESSION_LOGOFF, w.SMTO_ABORTIFHUNG, 5000, &result);
            var s = try waitSession(h, path, 5000, {}, struct {
                fn ok(_: void, v: SavedSession) bool {
                    return v.tabCount() == 3;
                }
            }.ok);
            defer s.deinit();
            try h.expect(s.value.tabCount() == 3, "and once it's called off, it is ({d} tabs)", .{s.value.tabCount()});
            try waitWindowTabText(h, &g, 0, 2, ">");
            h.key(try paneHwnd(h, &g, 0), .{ .ctrl = true, .shift = true }, w.VK_F7);
            try waitPanes(h, &g, 1);
        }

        // A split.
        h.key(try paneHwnd(h, &g, 0), .{ .ctrl = true, .shift = true }, 'O');
        try waitPanes(h, &g, 2);
        {
            var s = try waitSession(h, path, 5000, {}, struct {
                fn ok(_: void, v: SavedSession) bool {
                    return v.rootSplit() != null;
                }
            }.ok);
            defer s.deinit();
            const split = s.value.rootSplit();
            try h.expect(split != null and std.mem.eql(u8, split.?.layout, "horizontal") and @abs(split.?.ratio - 0.5) < 0.01 and s.value.windows[0].tabs[0].nodes.len == 3, "a split is saved: side by side, halves", .{});
            try h.expect(s.value.windows[0].active == 0, "in the first tab", .{});
        }

        // A move is saved as it ends, not while it goes on.
        {
            var s0 = try waitSession(h, path, 0, {}, struct {
                fn ok(_: void, _: SavedSession) bool {
                    return true;
                }
            }.ok);
            defer s0.deinit();
            const left0 = s0.value.windows[0].left;
            const top0 = s0.value.windows[0].top;
            var wr: w.RECT = .{};
            _ = w.GetWindowRect(win, &wr);
            _ = w.SendMessageTimeoutW(win, w.WM_ENTERSIZEMOVE, 0, 0, w.SMTO_ABORTIFHUNG, 2000, null);
            _ = w.SetWindowPos(win, null, wr.left + 40, wr.top + 30, 0, 0, w.SWP_NOSIZE | w.SWP_NOZORDER | w.SWP_NOACTIVATE);
            w.Sleep(1500);
            {
                var s = readSession(h, path) orelse return h.fail("no session file mid-move", .{});
                defer s.deinit();
                try h.expect(s.value.windows[0].left == left0 and s.value.windows[0].top == top0, "mid-move the file keeps the window where it was ({d},{d}; was {d},{d})", .{ s.value.windows[0].left, s.value.windows[0].top, left0, top0 });
            }
            _ = w.SendMessageTimeoutW(win, w.WM_EXITSIZEMOVE, 0, 0, w.SMTO_ABORTIFHUNG, 2000, null);
            const Want = struct { left: i32, top: i32 };
            var s = try waitSession(h, path, 5000, Want{ .left = left0 + 40, .top = top0 + 30 }, struct {
                fn ok(want: Want, v: SavedSession) bool {
                    return v.windows.len == 1 and v.windows[0].left == want.left and v.windows[0].top == want.top;
                }
            }.ok);
            defer s.deinit();
            try h.expect(s.value.windows[0].left == left0 + 40 and s.value.windows[0].top == top0 + 30, "once it ends the move is saved ({d},{d})", .{ s.value.windows[0].left, s.value.windows[0].top });
        }

        // A divider is saved as it is let go.
        const right_pane = try paneHwnd(h, &g, 1);
        const container = w.GetParent(right_pane) orelse return h.fail("pane without a container", .{});
        const y: i32 = 200;
        {
            const x0 = try rootDivider(h, &g);
            postMouse(container, w.WM_LBUTTONDOWN, x0, y);
            postMouse(container, w.WM_MOUSEMOVE, x0 + 60, y);
            postMouse(container, w.WM_MOUSEMOVE, x0 + 120, y);
            w.Sleep(1500);
            const mid = try rootDivider(h, &g);
            {
                var s = readSession(h, path) orelse return h.fail("no session file mid-drag", .{});
                defer s.deinit();
                const split = s.value.rootSplit();
                try h.expect(@abs(mid - (x0 + 120)) <= 1 and split != null and @abs(split.?.ratio - 0.5) < 0.01, "mid-drag the divider moves (to {d}) and the file keeps the halves", .{mid});
            }
            postMouse(container, w.WM_LBUTTONUP, x0 + 120, y);
            var s = try waitSession(h, path, 5000, {}, struct {
                fn ok(_: void, v: SavedSession) bool {
                    const split = v.rootSplit() orelse return false;
                    return split.ratio > 0.55;
                }
            }.ok);
            defer s.deinit();
            const split = s.value.rootSplit();
            try h.expect(split != null and split.?.ratio > 0.55, "let go, the divider is saved (ratio {d:.3})", .{if (split) |sp| sp.ratio else 0});
        }

        // Esc puts a drag back and saves nothing.
        const text0 = h.readFileOrNull(path) orelse return h.fail("no session file", .{});
        defer h.alloc.free(text0);
        const x1 = try rootDivider(h, &g);
        {
            postMouse(container, w.WM_LBUTTONDOWN, x1, y);
            postMouse(container, w.WM_MOUSEMOVE, x1 - 200, y);
            // Longer than the poll, which must not save it either.
            w.Sleep(1500);
            const esc: usize = 1 | (@as(usize, w.MapVirtualKeyW(w.VK_ESCAPE, w.MAPVK_VK_TO_VSC)) << 16);
            _ = w.PostMessageW(right_pane, w.WM_KEYDOWN, w.VK_ESCAPE, @bitCast(esc));
            _ = w.PostMessageW(right_pane, w.WM_KEYUP, w.VK_ESCAPE, @bitCast(esc | (3 << 30)));
            postMouse(container, w.WM_LBUTTONUP, x1 - 200, y);
            w.Sleep(1500);
            const text = h.readFileOrNull(path) orelse return h.fail("no session file", .{});
            defer h.alloc.free(text);
            const back = try rootDivider(h, &g);
            try h.expect(@abs(back - x1) <= 1 and std.mem.eql(u8, text, text0), "a drag Esc puts back saves nothing (divider at {d}, was {d})", .{ back, x1 });
        }

        // murrtty ending mid-drag leaves the file as it was.
        postMouse(container, w.WM_LBUTTONDOWN, x1, y);
        postMouse(container, w.WM_MOUSEMOVE, x1 - 150, y);
        w.Sleep(1500);
        const mid = try rootDivider(h, &g);
        try h.expect(@abs(mid - (x1 - 150)) <= 1, "a last drag is under way (divider at {d})", .{mid});
        before_kill = try h.alloc.dupe(u8, text0);
        _ = w.TerminateProcess(g.proc, 1);
        _ = g.waitExit(5000);
    }
    {
        const text = h.readFileOrNull(path) orelse return h.fail("the session file went with murrtty", .{});
        defer h.alloc.free(text);
        try h.expect(std.mem.eql(u8, text, before_kill.?), "and murrtty ending mid-drag left the file as it was", .{});
    }

    // Quitting writes what changed last: a tab made just before Quit.
    {
        const quit_path = try std.fmt.allocPrint(h.alloc, "{s}\\session-quit\\state\\murrtty\\session.json", .{h.temp_dir});
        defer h.alloc.free(quit_path);
        var g = try start(h, "session-quit", "confirm-close-surface = false\n", ">");
        defer g.deinit();
        var s0 = try waitSession(h, quit_path, 5000, {}, struct {
            fn ok(_: void, v: SavedSession) bool {
                return v.tabCount() == 1;
            }
        }.ok);
        s0.deinit();
        const surf = try h.surface(&g, try h.mainWindow(&g));
        h.key(surf, .{ .ctrl = true, .shift = true }, 'T');
        h.key(surf, .{ .ctrl = true, .shift = true }, 'Q');
        const code = g.waitExit(10000);
        try h.expect(code != null and code.? == 0, "murrtty quits at once (exit {?d})", .{code});
        var s = readSession(h, quit_path) orelse return h.fail("no session after quitting", .{});
        defer s.deinit();
        try h.expect(s.value.tabCount() == 2, "quitting writes the last change (a tab made just before: {d} tabs)", .{s.value.tabCount()});
    }

    // A file where murrtty's state folder would be: said, once.
    {
        const dir = try std.fmt.allocPrint(h.alloc, "{s}\\session-unwritable", .{h.temp_dir});
        defer h.alloc.free(dir);
        const state = try std.fmt.allocPrint(h.alloc, "{s}\\state", .{dir});
        defer h.alloc.free(state);
        const blocker = try std.fmt.allocPrint(h.alloc, "{s}\\murrtty", .{state});
        defer h.alloc.free(blocker);
        try h.makeDirAt(dir);
        try h.makeDirAt(state);
        try h.writeFileAt(blocker, "a file where murrtty's state folder goes\n");
        var g = try h.launchWith("session-unwritable", base_config, .{ .env = &.{.{ "XDG_STATE_HOME", state }} });
        defer g.deinit();
        const dlg = try h.waitDialog(&g, 10000);
        const want = try std.fmt.allocPrint(h.alloc, "murrtty can't save its session to {s}\\session.json: its folder can't be made.", .{blocker});
        defer h.alloc.free(want);
        {
            var d = try h.dump(&g);
            defer d.deinit();
            const dl = d.value.dialog;
            try h.expect(std.mem.eql(u8, dl.heading, "Session Not Saved") and std.mem.startsWith(u8, dl.body, want), "a state folder murrtty can't write is said: '{s}' / '{s}'", .{ dl.heading, dl.body });
        }
        h.answer(&g, dlg, w.IDCANCEL);
        try waitNoDialog(h, &g);
        h.key(try h.surface(&g, try h.mainWindow(&g)), .{ .ctrl = true, .shift = true }, 'T');
        w.Sleep(2500);
        try h.expect(try h.dialogCount(&g) == 0, "and only once a run (a new tab says nothing more)", .{});
    }
}

/// Roadmap 5.10b: a saved session comes back at start, from a file written
/// here (a `class` instance's own, session-<class>.json): two windows, the
/// first with its name, size and tab in front, and a tab of three panes
/// whose splits keep their sizes, with their names and directories, one of
/// them gone (its shell starts in the home folder and a toast says so),
/// and a tab whose program was cmd of its own, which runs it again; the
/// second, saved off every monitor and bigger than any, pulled into a work
/// area; the quick terminal's tabs wait for it to be summoned. What came
/// is saved back, and quitting keeps it. With initial-window = false
/// nothing shows until a window is asked for (+new-window), which brings
/// the saved windows back instead of an empty one; `never` restores
/// nothing and leaves the file alone; a start that crashed while restoring
/// (its marker left) skips the restore once, keeping the session aside and
/// saying so.
fn sessionRestore(h: *Harness) anyerror!void {
    const class = try ipcClass(h, "session");
    defer h.alloc.free(class);
    const dir = try std.fmt.allocPrint(h.alloc, "{s}\\session-restore", .{h.temp_dir});
    defer h.alloc.free(dir);
    const state = try std.fmt.allocPrint(h.alloc, "{s}\\state", .{dir});
    defer h.alloc.free(state);
    const folder = try std.fmt.allocPrint(h.alloc, "{s}\\murrtty", .{state});
    defer h.alloc.free(folder);
    const path = try std.fmt.allocPrint(h.alloc, "{s}\\session-{s}.json", .{ folder, class });
    defer h.alloc.free(path);
    const work = try std.fmt.allocPrint(h.alloc, "{s}\\work", .{dir});
    defer h.alloc.free(work);
    const logs = try std.fmt.allocPrint(h.alloc, "{s}\\logs", .{dir});
    defer h.alloc.free(logs);
    const gone = try std.fmt.allocPrint(h.alloc, "{s}\\gone", .{dir});
    defer h.alloc.free(gone);
    for ([_][]const u8{ dir, state, folder, work, logs }) |p| try h.makeDirAt(p);
    const home = try userHome(h);
    defer h.alloc.free(home);

    const S = SavedSession;
    const main_panes = [_]S.Node{
        .{ .split = .{ .layout = "horizontal", .ratio = 0.3, .left = 1, .right = 2 } },
        .{ .pane = .{ .id = "00000000000000a1", .directory = work } },
        .{ .split = .{ .layout = "vertical", .ratio = 0.7, .left = 3, .right = 4 } },
        .{ .pane = .{ .id = "00000000000000a2", .directory = gone } },
        .{ .pane = .{ .id = "00000000000000a3", .directory = logs, .name = "logs" } },
    };
    const own_cmd = [_]S.Node{.{ .pane = .{ .id = "00000000000000b1", .directory = work, .program = .{ .direct = &.{ "cmd.exe", "/k", "echo", "own-cmd" } } } }};
    const lost_pane = [_]S.Node{.{ .pane = .{ .id = "00000000000000d1", .directory = work } }};
    const quick_a = [_]S.Node{.{ .pane = .{ .id = "00000000000000c1", .directory = work } }};
    const quick_b = [_]S.Node{.{ .pane = .{ .id = "00000000000000c2", .directory = logs, .name = "quick-logs" } }};
    const main_tabs = [_]S.Tab{ .{ .name = "work", .focused = 4, .nodes = &main_panes }, .{ .nodes = &own_cmd } };
    const lost_tabs = [_]S.Tab{.{ .nodes = &lost_pane }};
    const quick_tabs = [_]S.Tab{ .{ .nodes = &quick_a }, .{ .nodes = &quick_b } };
    const windows = [_]S.Win{
        .{ .name = "main", .left = 100, .top = 100, .right = 1060, .bottom = 740, .active = 1, .tabs = &main_tabs },
        // Saved on a monitor that's gone, and bigger than any.
        .{ .left = -50000, .top = -50000, .right = -10000, .bottom = -20000, .tabs = &lost_tabs },
        .{ .quick = true, .active = 1, .tabs = &quick_tabs },
    };
    {
        const text = try std.json.Stringify.valueAlloc(h.alloc, S{ .version = 1, .front = 0, .windows = &windows }, .{ .emit_null_optional_fields = false });
        defer h.alloc.free(text);
        try h.writeFileAt(path, text);
    }

    const config = try std.fmt.allocPrint(h.alloc, "{s}class = {s}\nkeybind = ctrl+shift+f6=toggle_quick_terminal\n", .{ base_config, class });
    defer h.alloc.free(config);
    const env: []const [2][]const u8 = &.{.{ "XDG_STATE_HOME", state }};
    {
        var g = try h.launchWith("session-restore", config, .{ .env = env });
        defer g.deinit();
        try waitWindowCount(h, &g, 2);
        {
            var d = try h.dump(&g);
            defer d.deinit();
            const toast = if (d.value.windows.len > 0) d.value.windows[0].toast else "";
            try h.expect(std.mem.indexOf(u8, toast, "is gone: started in your home folder") != null, "a toast says a folder is gone ('{s}')", .{toast});
        }
        try waitWindowTabText(h, &g, 0, 1, "own-cmd");
        // Each pane's shell reports its directory once it runs.
        var waited: u32 = 0;
        while (waited < 10000) : (waited += 200) {
            var d = try h.dump(&g);
            defer d.deinit();
            const p = d.value.windows[0].tabs[0].panes orelse &.{};
            if (p.len == 3 and sameDir(p[0].pwd, work) and sameDir(p[1].pwd, home) and sameDir(p[2].pwd, logs)) break;
            w.Sleep(200);
        }
        var d = try h.dump(&g);
        defer d.deinit();
        const wins = d.value.windows;
        try h.expect(wins.len == 2, "the two saved windows come back, and no other ({d})", .{wins.len});
        const main = wins[0];
        var mi: w.MONITORINFO = .{};
        if (w.MonitorFromPoint(.{ .x = 110, .y = 110 }, w.MONITOR_DEFAULTTONEAREST)) |m| _ = w.GetMonitorInfoW(m, &mi);
        const want_w = @min(960, mi.rcWork.right - mi.rcWork.left);
        const want_h = @min(640, mi.rcWork.bottom - mi.rcWork.top);
        const size = [2]i32{ main.rect[2] - main.rect[0], main.rect[3] - main.rect[1] };
        try h.expect(std.mem.eql(u8, main.window_name, "main") and size[0] == want_w and size[1] == want_h, "the first, named '{s}', at its size ({d}x{d}, saved {d}x{d})", .{ main.window_name, size[0], size[1], want_w, want_h });
        try h.expect(main.tabs.len == 2 and main.active == 1, "with its two tabs, the second in front ({d} tabs, active {d})", .{ main.tabs.len, main.active });
        const t0 = main.tabs[0];
        const p = t0.panes orelse &.{};
        try h.expect(std.mem.eql(u8, t0.tab_name, "work") and std.mem.eql(u8, t0.pane_name, "logs") and p.len == 3, "the first tab, named '{s}', has its three panes ({d}), the one named '{s}' focused", .{ t0.tab_name, p.len, t0.pane_name });
        if (p.len == 3) {
            const area = t0.area orelse .{ 1, 1 };
            const share = @as(f32, @floatFromInt(p[0].rect[2] - p[0].rect[0])) / @as(f32, @floatFromInt(area[0]));
            try h.expect(share > 0.26 and share < 0.34, "the split keeps its size (the left pane {d:.2} of the width)", .{share});
            const top_h: f32 = @floatFromInt(p[1].rect[3] - p[1].rect[1]);
            const bottom_h: f32 = @floatFromInt(p[2].rect[3] - p[2].rect[1]);
            const top_share = top_h / (top_h + bottom_h);
            try h.expect(p[1].rect[0] == p[2].rect[0] and p[1].rect[1] < p[2].rect[1] and top_share > 0.66 and top_share < 0.74, "and the right side is split top and bottom, keeping its own size (the top {d:.2})", .{top_share});
            try h.expect(sameDir(p[0].pwd, work) and sameDir(p[2].pwd, logs), "each pane's shell in its directory ({s}, {s})", .{ p[0].pwd orelse "", p[2].pwd orelse "" });
            try h.expect(sameDir(p[1].pwd, home), "the gone folder's pane in the home folder ({s})", .{p[1].pwd orelse ""});
        }

        // The window saved on a monitor that's gone, bigger than any.
        if (wins.len == 2) {
            const lost = wins[1];
            const hwnd = hwndOf(lost.hwnd);
            var lmi: w.MONITORINFO = .{};
            if (w.MonitorFromWindow(hwnd, w.MONITOR_DEFAULTTONEAREST)) |m| _ = w.GetMonitorInfoW(m, &lmi);
            const r = lost.rect;
            const work_area = lmi.rcWork;
            try h.expect(r[0] >= work_area.left and r[1] >= work_area.top and r[2] <= work_area.right and r[3] <= work_area.bottom and r[2] > r[0] and w.IsZoomed(hwnd) == 0, "the window saved off-screen and too big comes back inside a work area, not maximized ({d},{d},{d},{d} in {d},{d},{d},{d})", .{ r[0], r[1], r[2], r[3], work_area.left, work_area.top, work_area.right, work_area.bottom });
        }

        // What came is saved back: ids, names, the gone folder's pane in
        // the home folder, the quick terminal's tabs still waiting.
        {
            var s = try waitSession(h, path, 5000, @as([]const u8, home), struct {
                fn ok(want: []const u8, v: SavedSession) bool {
                    const pane = v.findPane("00000000000000a2") orelse return false;
                    return sameDir(pane.directory, want);
                }
            }.ok);
            defer s.deinit();
            const v = s.value;
            try h.expect(v.windows.len == 3 and v.front != null and v.front.? == 0, "saved back: the two windows and the quick terminal's ({d}), the first in front", .{v.windows.len});
            const named = v.findPane("00000000000000a3");
            try h.expect(v.windows.len == 3 and std.mem.eql(u8, v.windows[0].name orelse "", "main") and std.mem.eql(u8, v.windows[0].tabs[0].name orelse "", "work") and named != null and std.mem.eql(u8, named.?.name orelse "", "logs"), "with their names and the panes' ids", .{});
            const own = v.findPane("00000000000000b1");
            const program = if (own) |o| if (o.program) |pr| pr.direct else null else null;
            try h.expect(program != null and program.?.len == 4 and std.mem.eql(u8, program.?[3], "own-cmd"), "the pane running cmd of its own keeps it", .{});
            var quick_tabs_saved: usize = 0;
            for (v.windows) |sw| if (sw.quick) {
                quick_tabs_saved = sw.tabs.len;
            };
            try h.expect(quick_tabs_saved == 2, "the quick terminal's two tabs stay saved while they wait ({d})", .{quick_tabs_saved});
        }

        // The quick terminal comes back with its tabs when summoned.
        h.key(try paneHwnd(h, &g, 0), .{ .ctrl = true, .shift = true }, w.VK_F6);
        var quick_seen = false;
        waited = 0;
        while (waited < 5000 and !quick_seen) : (waited += 100) {
            var dq = try h.dump(&g);
            defer dq.deinit();
            for (dq.value.windows) |dw| if (dw.quick != null and dw.tabs.len == 2) {
                quick_seen = true;
                try h.expect(dw.active == 1 and std.mem.eql(u8, dw.tabs[1].pane_name, "quick-logs"), "the quick terminal comes back with its two tabs, the second in front ('{s}')", .{dw.tabs[1].pane_name});
            };
            if (!quick_seen) w.Sleep(100);
        }
        try h.expect(quick_seen, "summoned, the quick terminal has its saved tabs", .{});

        // Quitting keeps the session.
        try quit(h, &g, try paneHwnd(h, &g, 0));
        var s = readSession(h, path) orelse return h.fail("no session after quitting", .{});
        defer s.deinit();
        try h.expect(s.value.windows.len == 3, "quitting keeps the windows in the file ({d})", .{s.value.windows.len});
    }

    // initial-window = false: nothing until a window is asked for, which
    // brings the session back instead of an empty window.
    {
        const lazy = try std.fmt.allocPrint(h.alloc, "{s}initial-window = false\n", .{config});
        defer h.alloc.free(lazy);
        // A history for a pane that waits to be restored, too long and with
        // a line a cut-short write left: the collector repairs it at start.
        const waiting_file = try std.fmt.allocPrint(h.alloc, "{s}\\history-{s}\\00000000000000a1.txt", .{ folder, class });
        defer h.alloc.free(waiting_file);
        {
            const history_dir = try std.fmt.allocPrint(h.alloc, "{s}\\history-{s}", .{ folder, class });
            defer h.alloc.free(history_dir);
            try h.makeDirAt(history_dir);
            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(h.alloc);
            for (0..1200) |i| {
                if (i == 600) try text.appendSlice(h.alloc, "\x00\x00\x00\n");
                try text.print(h.alloc, "echo {d}\n", .{i});
            }
            try h.writeFileAt(waiting_file, text.items);
        }
        var g = try h.launchWith("session-restore-lazy", lazy, .{ .env = env, .wait_window = false });
        defer g.deinit();
        try h.waitAnswering(&g, 15000);
        h.alloc.free(try waitListening(h, &g, 5000));
        w.Sleep(1000);
        {
            const repaired = h.readFileOrNull(waiting_file) orelse return h.fail("the waiting pane's history went", .{});
            defer h.alloc.free(repaired);
            const lines = std.mem.count(u8, repaired, "\n");
            try h.expect(lines == 1000 and std.mem.indexOfScalar(u8, repaired, 0) == null and std.mem.startsWith(u8, repaired, "echo 200\n"), "a waiting pane's history is cut to its last 1,000 commands and rid of a damaged line ({d} lines)", .{lines});
        }
        {
            const wins = try h.windows(&g, "MurrttyWindow");
            defer h.alloc.free(wins);
            try h.expect(wins.len == 0, "with initial-window = false nothing shows at start ({d} windows)", .{wins.len});
        }
        const class_arg = try std.fmt.allocPrint(h.alloc, "--class={s}", .{class});
        defer h.alloc.free(class_arg);
        var r = try h.runCli("session-new-window", &.{ "+new-window", class_arg });
        defer r.deinit();
        try h.expect(r.code == 0, "+new-window exits 0 (got {d})", .{r.code});
        try waitWindowCount(h, &g, 2);
        w.Sleep(1000);
        const wins = try h.windows(&g, "MurrttyWindow");
        defer h.alloc.free(wins);
        var d = try h.dump(&g);
        defer d.deinit();
        const first = if (d.value.windows.len > 0) d.value.windows[0].window_name else "";
        try h.expect(wins.len == 2 and std.mem.eql(u8, first, "main"), "the first window asked for brings the saved windows back, and no empty one ({d} windows, the first '{s}')", .{ wins.len, first });

        // A second instance (single instance off) neither restores nor
        // saves: the first keeps the session.
        const second_config = try std.fmt.allocPrint(h.alloc, "{s}gtk-single-instance = false\n", .{config});
        defer h.alloc.free(second_config);
        var g2 = try h.launchWith("session-restore-second", second_config, .{ .env = env });
        defer g2.deinit();
        try h.waitText(&g2, ">", 1, 20000);
        w.Sleep(1500);
        const wins2 = try h.windows(&g2, "MurrttyWindow");
        defer h.alloc.free(wins2);
        var s = readSession(h, path) orelse return h.fail("no session file", .{});
        defer s.deinit();
        const name0 = if (s.value.windows.len > 0) s.value.windows[0].name orelse "" else "";
        try h.expect(wins2.len == 1 and s.value.windows.len == 3 and std.mem.eql(u8, name0, "main"), "a second instance opens its own window ({d}) and leaves the session alone ({d} windows saved)", .{ wins2.len, s.value.windows.len });

        // The restore's crash marker goes once murrtty has run a while
        // after it; ending it sooner (as deinit does) would count as a
        // crash at the next start.
        const marker = try std.fmt.allocPrint(h.alloc, "{s}\\session-{s}.restoring", .{ folder, class });
        defer h.alloc.free(marker);
        var marker_waited: u32 = 0;
        while (marker_waited < 10000) : (marker_waited += 200) {
            const left = h.readFileOrNull(marker) orelse break;
            h.alloc.free(left);
            w.Sleep(200);
        }
        try h.expect(marker_waited < 10000, "the restore's crash marker goes a few seconds after it", .{});
    }

    // A start that fails (no OpenGL) leaves the file as it was, and no
    // crash marker behind.
    {
        const before = h.readFileOrNull(path) orelse return h.fail("no session file", .{});
        defer h.alloc.free(before);
        const marker = try std.fmt.allocPrint(h.alloc, "{s}\\session-{s}.restoring", .{ folder, class });
        defer h.alloc.free(marker);
        const gl_env: []const [2][]const u8 = &.{ .{ "XDG_STATE_HOME", state }, .{ "GHOSTTY_WIN32_TEST_WGL", "context" } };
        var g = try h.launchWith("session-restore-gl", config, .{ .env = gl_env, .wait_window = false });
        defer g.deinit();
        try h.waitAnswering(&g, 10000);
        const dlg = try h.waitDialog(&g, 15000);
        w.Sleep(1500);
        {
            const during = h.readFileOrNull(path) orelse return h.fail("the session file is gone", .{});
            defer h.alloc.free(during);
            try h.expect(std.mem.eql(u8, before, during), "while murrtty says it can't draw, the session file is as it was", .{});
        }
        h.answer(&g, dlg, w.IDCLOSE);
        _ = g.waitExit(10000);
        const after = h.readFileOrNull(path) orelse return h.fail("the session file is gone", .{});
        defer h.alloc.free(after);
        const left = h.readFileOrNull(marker);
        defer if (left) |l| h.alloc.free(l);
        try h.expect(std.mem.eql(u8, before, after) and left == null, "and after it ends, with no crash marker left (marker {s})", .{if (left != null) "left" else "gone"});
    }

    // never: nothing restored, the file left as it is.
    {
        const before = h.readFileOrNull(path) orelse return h.fail("no session file", .{});
        defer h.alloc.free(before);
        const never = try std.fmt.allocPrint(h.alloc, "{s}window-save-state = never\n", .{config});
        defer h.alloc.free(never);
        var g = try h.launchWith("session-restore-never", never, .{ .env = env });
        defer g.deinit();
        try h.waitText(&g, ">", 1, 20000);
        w.Sleep(1500);
        const wins = try h.windows(&g, "MurrttyWindow");
        defer h.alloc.free(wins);
        const after = h.readFileOrNull(path) orelse return h.fail("the session file is gone", .{});
        defer h.alloc.free(after);
        try h.expect(wins.len == 1 and std.mem.eql(u8, before, after), "window-save-state = never restores nothing ({d} windows) and leaves the file as it was", .{wins.len});
    }

    // A start that crashed while restoring left its marker: the next skips
    // the restore once, keeps the session aside and says so.
    {
        const marker = try std.fmt.allocPrint(h.alloc, "{s}\\session-{s}.restoring", .{ folder, class });
        defer h.alloc.free(marker);
        const aside = try std.fmt.allocPrint(h.alloc, "{s}\\session-{s}-skipped.json", .{ folder, class });
        defer h.alloc.free(aside);
        const saved = h.readFileOrNull(path) orelse return h.fail("no session file", .{});
        defer h.alloc.free(saved);
        try h.writeFileAt(marker, "");
        var g = try h.launchWith("session-restore-crashed", config, .{ .env = env });
        defer g.deinit();
        try h.waitText(&g, ">", 1, 20000);
        var d = try h.dump(&g);
        defer d.deinit();
        const wins = d.value.windows;
        try h.expect(wins.len == 1, "after a start that crashed restoring, one new window ({d})", .{wins.len});
        const toast = if (wins.len > 0) wins[0].toast else "";
        const aside_name = try std.fmt.allocPrint(h.alloc, "session-{s}-skipped.json", .{class});
        defer h.alloc.free(aside_name);
        var toast_seen = std.mem.indexOf(u8, toast, "wasn't restored") != null;
        // The notice waits for murrtty's first tick with a window.
        var waited: u32 = 0;
        while (!toast_seen and waited < 3000) : (waited += 100) {
            w.Sleep(100);
            var dt = try h.dump(&g);
            defer dt.deinit();
            const t = if (dt.value.windows.len > 0) dt.value.windows[0].toast else "";
            toast_seen = std.mem.indexOf(u8, t, "wasn't restored") != null and std.mem.indexOf(u8, t, aside_name) != null;
        }
        try h.expect(toast_seen, "and a toast says why, naming {s}", .{aside_name});
        const kept = h.readFileOrNull(aside);
        defer if (kept) |k| h.alloc.free(k);
        try h.expect(kept != null and std.mem.eql(u8, kept.?, saved), "the session is kept aside as session-<class>-skipped.json", .{});
        const left = h.readFileOrNull(marker);
        defer if (left) |l| h.alloc.free(l);
        try h.expect(left == null, "and the marker is gone", .{});
    }
}

/// Roadmap 5.10b: single instance by default on Windows. A second plain
/// launch hands over (`present`) and exits 0: the running murrtty's window
/// comes back from minimized and nothing opens. One with a command (`-e`)
/// opens it as a new tab in the front window, in the launch's folder.
fn secondLaunch(h: *Harness) anyerror!void {
    const class = try ipcClass(h, "second");
    defer h.alloc.free(class);
    const extra = try std.fmt.allocPrint(h.alloc, "class = {s}\n", .{class});
    defer h.alloc.free(extra);
    const config = try std.mem.concat(h.alloc, u8, &.{ base_config, extra });
    defer h.alloc.free(config);
    var g = try start(h, "second-launch", extra, ">");
    defer g.deinit();
    h.alloc.free(try waitListening(h, &g, 5000));
    const win = try h.mainWindow(&g);
    _ = w.ShowWindow(win, w.SW_MINIMIZE);
    var waited: u32 = 0;
    while (w.IsIconic(win) == 0 and waited < 3000) : (waited += 100) w.Sleep(100);
    try h.expect(w.IsIconic(win) != 0, "the first murrtty's window is minimized", .{});

    {
        var second = try h.launchWith("second-launch-plain", config, .{ .wait_window = false });
        defer second.deinit();
        const code = second.waitExit(15000);
        try h.expect(code != null and code.? == 0, "a second plain launch hands over and exits 0 (exit {?d})", .{code});
    }
    waited = 0;
    while (w.IsIconic(win) != 0 and waited < 5000) : (waited += 100) w.Sleep(100);
    try h.expect(w.IsIconic(win) == 0, "and the running murrtty's window comes back from minimized", .{});
    w.Sleep(500);
    {
        var d = try h.dump(&g);
        defer d.deinit();
        try h.expect(d.value.windows.len == 1 and d.value.windows[0].tabs.len == 1, "with nothing new opened ({d} windows, {d} tabs)", .{ d.value.windows.len, if (d.value.windows.len > 0) d.value.windows[0].tabs.len else 0 });
    }

    {
        var third = try h.launchWith("second-launch-command", config, .{ .wait_window = false, .args = &.{ "-e", "cmd.exe", "/k", "echo", "second-launch-tab" } });
        defer third.deinit();
        const code = third.waitExit(15000);
        try h.expect(code != null and code.? == 0, "a launch with a command hands over and exits 0 (exit {?d})", .{code});
    }
    try waitWindowTabText(h, &g, 0, 1, "second-launch-tab");
    const folder = try std.fmt.allocPrint(h.alloc, "{s}\\second-launch-command", .{h.temp_dir});
    defer h.alloc.free(folder);
    var d = try h.dump(&g);
    defer d.deinit();
    const win_tabs = if (d.value.windows.len > 0) d.value.windows[0].tabs else &.{};
    const pwd = if (win_tabs.len > 1) if (win_tabs[1].panes) |p| (if (p.len > 0) p[0].pwd else null) else null else null;
    try h.expect(d.value.windows.len == 1 and win_tabs.len == 2 and sameDir(pwd, folder), "it opens as a new tab in the front window ({d} windows, {d} tabs), in the launch's folder ({s})", .{ d.value.windows.len, win_tabs.len, pwd orelse "none" });

    // A pane's option alone: a new tab with it.
    {
        var titled = try h.launchWith("second-launch-title", config, .{ .wait_window = false, .args = &.{"--title=Handed over"} });
        defer titled.deinit();
        const code = titled.waitExit(15000);
        try h.expect(code != null and code.? == 0, "a launch with --title= hands over and exits 0 (exit {?d})", .{code});
    }
    {
        var found = false;
        waited = 0;
        while (!found and waited < 10000) : (waited += 200) {
            var dt = try h.dump(&g);
            defer dt.deinit();
            if (dt.value.windows.len > 0 and dt.value.windows[0].tabs.len == 3) {
                found = std.mem.eql(u8, dt.value.windows[0].tabs[2].pane_name, "Handed over");
            }
            if (!found) w.Sleep(200);
        }
        try h.expect(found, "and opens a tab titled as it asked", .{});
    }

    // A configuration option only a murrtty of its own takes: it runs apart.
    {
        var apart = try h.launchWith("second-launch-separate", config, .{ .args = &.{"--font-size=20"} });
        defer apart.deinit();
        try h.waitText(&apart, ">", 1, 20000);
        var da = try h.dump(&apart);
        defer da.deinit();
        var dg = try h.dump(&g);
        defer dg.deinit();
        try h.expect(apart.exitCode() == null and !da.value.ipc.listening and dg.value.windows.len == 1 and dg.value.windows[0].tabs.len == 3, "a launch with --font-size= runs as a murrtty of its own, the first unchanged", .{});
    }

    // With a dialog open, a second launch raises the dialog: its minimized
    // owner comes back.
    {
        h.key(try paneHwnd(h, &g, 0), .{ .ctrl = true, .shift = true }, 'Q');
        const dlg = try h.waitDialog(&g, 5000);
        _ = w.ShowWindow(win, w.SW_MINIMIZE);
        waited = 0;
        while (w.IsIconic(win) == 0 and waited < 3000) : (waited += 100) w.Sleep(100);
        var again = try h.launchWith("second-launch-dialog", config, .{ .wait_window = false });
        defer again.deinit();
        const code = again.waitExit(15000);
        waited = 0;
        while (w.IsIconic(win) != 0 and waited < 5000) : (waited += 100) w.Sleep(100);
        try h.expect(code != null and code.? == 0 and w.IsIconic(win) == 0, "with a dialog open, a second launch raises it, its window back from minimized (exit {?d})", .{code});
        h.answer(&g, dlg, w.IDCANCEL);
        try waitNoDialog(h, &g);
    }

    // -e reaches a murrtty in the tray (initial-window = false).
    {
        const tray_class = try ipcClass(h, "second-tray");
        defer h.alloc.free(tray_class);
        const tray_config = try std.fmt.allocPrint(h.alloc, "{s}class = {s}\ninitial-window = false\n", .{ base_config, tray_class });
        defer h.alloc.free(tray_config);
        var tray = try h.launchWith("second-launch-tray", tray_config, .{ .wait_window = false });
        defer tray.deinit();
        try h.waitAnswering(&tray, 15000);
        h.alloc.free(try waitListening(h, &tray, 5000));
        var cmd = try h.launchWith("second-launch-tray-command", tray_config, .{ .wait_window = false, .args = &.{ "-e", "cmd.exe", "/k", "echo", "tray-tab" } });
        defer cmd.deinit();
        const code = cmd.waitExit(15000);
        try h.expect(code != null and code.? == 0, "-e to a murrtty in the tray hands over and exits 0 (exit {?d})", .{code});
        try waitWindowCount(h, &tray, 1);
        try waitWindowText(h, &tray, 0, "tray-tab");
    }
}

/// The window fits `work` (its frame on the work area's edges, the
/// window rectangle wider by at most the invisible resize border), not
/// maximized.
fn expectFits(h: *Harness, win: w.HWND, work: w.RECT, comptime how: []const u8) !void {
    var r: w.RECT = .{};
    var ok = false;
    var waited: u32 = 0;
    while (true) : (waited += 100) {
        _ = w.GetWindowRect(win, &r);
        const inside = r.left <= work.left and r.top <= work.top and r.right >= work.right and r.bottom >= work.bottom;
        const close = work.left - r.left <= 16 and work.top - r.top <= 16 and r.right - work.right <= 16 and r.bottom - work.bottom <= 16;
        ok = w.IsZoomed(win) == 0 and inside and close;
        if (ok or waited >= 3000) break;
        w.Sleep(100);
    }
    try h.expect(ok, how ++ ": the window fits the work area, not maximized ({d},{d},{d},{d} for {d},{d},{d},{d}, zoomed {d})", .{ r.left, r.top, r.right, r.bottom, work.left, work.top, work.right, work.bottom, w.IsZoomed(win) });
}

/// Roadmap 5.10b: Fit Window to Screen, murrtty's own (Ghostty has no
/// such action), from the terminal's Window submenu and the system menu:
/// a window bigger than its screen, its corner off it, fits the monitor's
/// work area without being maximized; a maximized one is restored first.
fn fitWindow(h: *Harness) anyerror!void {
    var g = try start(h, "fit-window", "keybind = ctrl+shift+f5=toggle_fullscreen\n", ">");
    defer g.deinit();
    const win = try h.mainWindow(&g);
    const surf = try h.surface(&g, win);
    var mi: w.MONITORINFO = .{};
    const monitor = w.MonitorFromWindow(win, w.MONITOR_DEFAULTTONEAREST) orelse return h.fail("no monitor", .{});
    _ = w.GetMonitorInfoW(monitor, &mi);
    const work = mi.rcWork;
    _ = w.SetWindowPos(win, null, work.left - 300, work.top - 200, work.right - work.left + 800, work.bottom - work.top + 600, w.SWP_NOZORDER | w.SWP_NOACTIVATE);
    w.Sleep(800);

    h.rightPress(surf, 120, 160);
    const menu = try h.waitMenu(&g, 1, 5000);
    h.menuKey(menu, 'w');
    const sub = try h.waitMenu(&g, 2, 5000);
    {
        const items = try h.menuItems(sub);
        defer h.freeMenuItems(items);
        var listed = false;
        for (items) |it| listed = listed or std.mem.indexOf(u8, it.text, "Fit Window to Screen") != null;
        try h.expect(listed, "the Window submenu has Fit Window to Screen", .{});
    }
    h.menuKey(sub, 'f');
    try expectFits(h, win, work, "from the terminal's menu");

    _ = w.ShowWindow(win, w.SW_MAXIMIZE);
    var waited: u32 = 0;
    while (w.IsZoomed(win) == 0 and waited < 3000) : (waited += 100) w.Sleep(100);
    try h.expect(w.IsZoomed(win) != 0, "the window is maximized", .{});
    const sys = try openSystemMenu(h, &g, win);
    h.menuKey(sys, 'f');
    try expectFits(h, win, work, "from the system menu, maximized");

    // Fullscreen (no system menu then): from the terminal's menu.
    h.key(surf, .{ .ctrl = true, .shift = true }, w.VK_F5);
    var r: w.RECT = .{};
    waited = 0;
    while (waited < 3000) : (waited += 100) {
        _ = w.GetWindowRect(win, &r);
        if (r.left == mi.rcMonitor.left and r.top == mi.rcMonitor.top and r.right == mi.rcMonitor.right and r.bottom == mi.rcMonitor.bottom) break;
        w.Sleep(100);
    }
    try h.expect(r.right - r.left == mi.rcMonitor.right - mi.rcMonitor.left, "the window is fullscreen", .{});
    h.rightPress(surf, 120, 160);
    const menu2 = try h.waitMenu(&g, 1, 5000);
    h.menuKey(menu2, 'w');
    const sub2 = try h.waitMenu(&g, 2, 5000);
    h.menuKey(sub2, 'f');
    try expectFits(h, win, work, "from fullscreen");
    try quit(h, &g, surf);
}

/// The id of the first window's first tab's first pane in the saved
/// session, once it is there (caller frees).
fn savedPaneId(h: *Harness, path: []const u8, tab: usize) ![]u8 {
    var waited: u32 = 0;
    while (waited < 10000) : (waited += 200) {
        if (readSession(h, path)) |sv| {
            defer sv.deinit();
            if (sv.value.windows.len > 0 and sv.value.windows[0].tabs.len > tab) {
                for (sv.value.windows[0].tabs[tab].nodes) |n| if (n.pane) |p| if (p.id.len == 16) return h.alloc.dupe(u8, p.id);
            }
        }
        w.Sleep(200);
    }
    return h.fail("no pane in tab {d} of the saved session", .{tab});
}

/// Whether `path` can be read.
fn fileThere(h: *Harness, path: []const u8) bool {
    const text = h.readFileOrNull(path) orelse return false;
    h.alloc.free(text);
    return true;
}

/// Wait until `path` holds `needle` (or, with `gone`, until it is gone).
fn waitFileHas(h: *Harness, path: []const u8, needle: ?[]const u8, ms: u32) bool {
    var waited: u32 = 0;
    while (true) : (waited += 200) {
        const text = h.readFileOrNull(path);
        defer if (text) |t| h.alloc.free(t);
        if (needle) |n| {
            if (text) |t| if (std.mem.indexOf(u8, t, n) != null) return true;
        } else if (text == null) return true;
        if (waited >= ms) return false;
        w.Sleep(200);
    }
}

/// Roadmap 5.10b part C: each pane's own command history, with PowerShell
/// 5.1 and murrtty's integration. A new pane copies each command into its
/// file (MURRTTY_HISTORY_FILE, history-<class>\<pane id>.txt), also one
/// already in PSReadLine's shared history (which its no-duplicates rule
/// keeps out of PSReadLine's own list). That shared file isn't checked:
/// PSReadLine finds it through the shell's folders, not APPDATA, so it is
/// the user's own, which the PowerShell scenarios type into anyway.
/// After a restart its pane comes back with the same id, its file
/// PSReadLine's: Up brings back a line only that file holds, and a new
/// command lands there. At start, a history file no saved pane has goes,
/// with the Clink history of a label murrtty gave out (its marker), not one
/// it didn't; a pane closed for good loses its file and its Clink history
/// once undo's time has passed. Clink's profile is the scenario's own
/// (LOCALAPPDATA).
fn paneHistory(h: *Harness) anyerror!void {
    const class = try ipcClass(h, "history");
    defer h.alloc.free(class);
    const dir = try std.fmt.allocPrint(h.alloc, "{s}\\pane-history", .{h.temp_dir});
    defer h.alloc.free(dir);
    const state = try std.fmt.allocPrint(h.alloc, "{s}\\state", .{dir});
    defer h.alloc.free(state);
    try h.makeDirAt(dir);
    try h.makeDirAt(state);
    const session_path = try std.fmt.allocPrint(h.alloc, "{s}\\murrtty\\session-{s}.json", .{ state, class });
    defer h.alloc.free(session_path);
    const history_dir = try std.fmt.allocPrint(h.alloc, "{s}\\murrtty\\history-{s}", .{ state, class });
    defer h.alloc.free(history_dir);
    const config = try std.fmt.allocPrint(h.alloc, "{s}command = powershell.exe -NoLogo -NoProfile\nshell-integration = detect\nconfirm-close-surface = false\nclass = {s}\n", .{ base_config, class });
    defer h.alloc.free(config);
    const orphan = try std.fmt.allocPrint(h.alloc, "{s}\\ffffffffffffffff.txt", .{history_dir});
    defer h.alloc.free(orphan);
    // Clink's profile, with a marked orphan's history and one murrtty didn't
    // label.
    const local = try std.fmt.allocPrint(h.alloc, "{s}\\local", .{dir});
    defer h.alloc.free(local);
    const clink = try std.fmt.allocPrint(h.alloc, "{s}\\clink", .{local});
    defer h.alloc.free(clink);
    try h.makeDirAt(local);
    try h.makeDirAt(clink);
    const orphan_marker = try std.fmt.allocPrint(h.alloc, "{s}\\eeeeeeeeeeeeeeee.clink", .{history_dir});
    defer h.alloc.free(orphan_marker);
    const orphan_clink = try std.fmt.allocPrint(h.alloc, "{s}\\clink_history-murrttyeeeeeeeeeeeeeeee", .{clink});
    defer h.alloc.free(orphan_clink);
    const foreign_clink = try std.fmt.allocPrint(h.alloc, "{s}\\clink_history-murrttydddddddddddddddd", .{clink});
    defer h.alloc.free(foreign_clink);
    try h.writeFileAt(orphan_clink, "echo stray\n");
    try h.writeFileAt(foreign_clink, "echo not murrtty's\n");
    const env: []const [2][]const u8 = &.{ .{ "XDG_STATE_HOME", state }, .{ "LOCALAPPDATA", local } };

    var pane_file: []u8 = &.{};
    defer h.alloc.free(pane_file);
    {
        var g = try h.launchWith("pane-history", config, .{ .env = env });
        defer g.deinit();
        try h.waitText(&g, "PS ", 1, 30000);
        const surf = try h.surface(&g, try h.mainWindow(&g));
        try h.typeText(surf, "echo murrtty-history-one");
        h.enter(surf);
        try h.waitText(&g, "murrtty-history-one", 2, 15000);
        const id = try savedPaneId(h, session_path, 0);
        defer h.alloc.free(id);
        pane_file = try std.fmt.allocPrint(h.alloc, "{s}\\{s}.txt", .{ history_dir, id });
        try h.expect(waitFileHas(h, pane_file, "echo murrtty-history-one", 10000), "a new pane copies its command into its own history file ({s})", .{pane_file});
        // A history no saved pane has, for the next start to clear, with a
        // Clink marker; and a line only the pane's file holds.
        try h.writeFileAt(orphan, "echo stray\n");
        try h.writeFileAt(orphan_marker, "");
        h.key(surf, .{ .ctrl = true, .shift = true }, 'Q');
        const code = g.waitExit(10000);
        try h.expect(code != null and code.? == 0, "murrtty quits (exit {?d})", .{code});
    }
    try h.expect(fileThere(h, pane_file), "quitting keeps the pane's history", .{});
    {
        const text = h.readFileOrNull(pane_file) orelse return h.fail("no pane history", .{});
        defer h.alloc.free(text);
        const more = try std.mem.concat(h.alloc, u8, &.{ text, "echo murrtty-history-pane-only\n" });
        defer h.alloc.free(more);
        try h.writeFileAt(pane_file, more);
    }

    {
        var g = try h.launchWith("pane-history-restored", config, .{ .env = env });
        defer g.deinit();
        try h.waitText(&g, "PS ", 1, 30000);
        try h.expect(waitFileHas(h, orphan, null, 5000), "at start a history no saved pane has goes", .{});
        try h.expect(!fileThere(h, orphan_marker) and !fileThere(h, orphan_clink), "with Clink's history for the label murrtty gave out", .{});
        try h.expect(fileThere(h, foreign_clink), "and not one it didn't", .{});
        const surf = try h.surface(&g, try h.mainWindow(&g));
        {
            var d = try h.dump(&g);
            defer d.deinit();
            const text = d.value.windows[0].tabs[0].text orelse "";
            try h.expect(std.mem.indexOf(u8, text, "murrtty-history-one") == null, "the restored pane starts with no scrollback", .{});
        }
        // The last line of the pane's file, which nothing else holds.
        h.key(surf, .{}, w.VK_UP);
        try h.waitText(&g, "echo murrtty-history-pane-only", 1, 10000);
        // Clear the line: Escape.
        h.key(surf, .{}, w.VK_ESCAPE);
        // A new command lands in the pane's file (PSReadLine's now).
        try h.typeText(surf, "echo murrtty-history-three");
        h.enter(surf);
        try h.expect(waitFileHas(h, pane_file, "echo murrtty-history-three", 10000), "the restored pane's new command lands in its own file", .{});

        // The garbage collector while murrtty runs (every few minutes; run
        // now through the hook): a history no pane has, a marked label's
        // Clink history and a leftover temporary file go; the live pane's
        // file stays as it is.
        {
            const dangling = try std.fmt.allocPrint(h.alloc, "{s}\\cccccccccccccccc.txt", .{history_dir});
            defer h.alloc.free(dangling);
            const dangling_marker = try std.fmt.allocPrint(h.alloc, "{s}\\cccccccccccccccc.clink", .{history_dir});
            defer h.alloc.free(dangling_marker);
            const dangling_clink = try std.fmt.allocPrint(h.alloc, "{s}\\clink_history-murrttycccccccccccccccc", .{clink});
            defer h.alloc.free(dangling_clink);
            const leftover = try std.fmt.allocPrint(h.alloc, "{s}\\cccccccccccccccc.txt.tmp", .{history_dir});
            defer h.alloc.free(leftover);
            try h.writeFileAt(dangling, "echo dangling\n");
            try h.writeFileAt(dangling_marker, "");
            try h.writeFileAt(dangling_clink, "echo dangling\n");
            try h.writeFileAt(leftover, "echo half\n");
            const before = h.readFileOrNull(pane_file) orelse return h.fail("no pane history", .{});
            defer h.alloc.free(before);
            try h.collectHistoryGarbage(&g);
            try h.expect(!fileThere(h, dangling) and !fileThere(h, dangling_marker) and !fileThere(h, dangling_clink), "the garbage collector removes a history no pane has, with its marked Clink history", .{});
            try h.expect(!fileThere(h, leftover), "and a leftover temporary file", .{});
            const after = h.readFileOrNull(pane_file) orelse return h.fail("the live pane's history went", .{});
            defer h.alloc.free(after);
            try h.expect(std.mem.eql(u8, before, after), "and leaves the live pane's file as it is", .{});
            try h.expect(fileThere(h, foreign_clink), "and a Clink history murrtty didn't label", .{});
        }
        // Clink's history label for the pane (Clink itself isn't run here).
        {
            const id = try savedPaneId(h, session_path, 0);
            defer h.alloc.free(id);
            const label = try std.fmt.allocPrint(h.alloc, "murrtty{s}", .{id});
            defer h.alloc.free(label);
            try h.typeText(surf, "Write-Output \"label=$env:CLINK_HISTORY_LABEL\"");
            h.enter(surf);
            const shown = try std.fmt.allocPrint(h.alloc, "label={s}", .{label});
            defer h.alloc.free(shown);
            try h.waitText(&g, shown, 1, 10000);
        }

        // A tab of its own, closed for good: its history goes once undo's
        // time (5 s) has passed.
        h.key(surf, .{ .ctrl = true, .shift = true }, 'T');
        try waitWindowTabText(h, &g, 0, 1, "PS ");
        const second = try paneHwnd(h, &g, 0);
        try h.typeText(second, "echo murrtty-history-two");
        h.enter(second);
        try waitWindowTabText(h, &g, 0, 1, "murrtty-history-two");
        const id2 = try savedPaneId(h, session_path, 1);
        defer h.alloc.free(id2);
        const second_file = try std.fmt.allocPrint(h.alloc, "{s}\\{s}.txt", .{ history_dir, id2 });
        defer h.alloc.free(second_file);
        try h.expect(waitFileHas(h, second_file, "echo murrtty-history-two", 10000), "the new tab keeps its own history", .{});
        // Its Clink history (as Clink would keep it).
        const second_marker = try std.fmt.allocPrint(h.alloc, "{s}\\{s}.clink", .{ history_dir, id2 });
        defer h.alloc.free(second_marker);
        const second_clink = try std.fmt.allocPrint(h.alloc, "{s}\\clink_history-murrtty{s}", .{ clink, id2 });
        defer h.alloc.free(second_clink);
        try h.expect(fileThere(h, second_marker), "murrtty marks the Clink label it gave the tab", .{});
        try h.writeFileAt(second_clink, "echo murrtty-history-two\n");
        h.key(second, .{ .ctrl = true, .shift = true }, 'W');
        w.Sleep(1500);
        try h.expect(fileThere(h, second_file), "closed, its history stays while undo can bring it back", .{});
        try h.expect(waitFileHas(h, second_file, null, 10000), "and goes once undo's time has passed", .{});
        try h.expect(!fileThere(h, second_clink) and !fileThere(h, second_marker), "with its Clink history", .{});
        try h.expect(fileThere(h, pane_file), "the other pane's stays", .{});
    }
}

/// Roadmap 5.10b part C with Clink (opt-in: GHOSTTY_GUI_CLINK names a folder
/// holding clink_x64.exe, as for cmd-integration; its profile is the
/// scenario's own). A cmd pane with Clink has a Clink history label of its
/// own (murrtty<pane id>); a command run there comes back for Up in the
/// pane murrtty restores after quitting, though murrtty ends cmd without
/// letting Clink save on exit. What Clink's profile holds is logged.
fn clinkHistory(h: *Harness) anyerror!void {
    var buf: [1024]u16 = undefined;
    const n = w.GetEnvironmentVariableW(w.L("GHOSTTY_GUI_CLINK"), &buf, buf.len);
    if (n == 0 or n >= buf.len) return h.skip("set GHOSTTY_GUI_CLINK to a Clink folder to run it", .{});
    const clink_dir = try std.unicode.utf16LeToUtf8Alloc(h.alloc, buf[0..n]);
    defer h.alloc.free(clink_dir);

    const class = try ipcClass(h, "clink-history");
    defer h.alloc.free(class);
    const dir = try std.fmt.allocPrint(h.alloc, "{s}\\clink-history", .{h.temp_dir});
    defer h.alloc.free(dir);
    const state = try std.fmt.allocPrint(h.alloc, "{s}\\state", .{dir});
    defer h.alloc.free(state);
    const profile = try std.fmt.allocPrint(h.alloc, "{s}\\clink-profile", .{dir});
    defer h.alloc.free(profile);
    try h.makeDirAt(dir);
    try h.makeDirAt(state);
    try h.makeDirAt(profile);
    {
        const settings = try std.fmt.allocPrint(h.alloc, "{s}\\clink_settings", .{profile});
        defer h.alloc.free(settings);
        try h.writeFileAt(settings, "clink.autoupdate = off\n");
    }
    const session_path = try std.fmt.allocPrint(h.alloc, "{s}\\murrtty\\session-{s}.json", .{ state, class });
    defer h.alloc.free(session_path);
    var path_buf: [32767]u16 = undefined;
    const path_len = w.GetEnvironmentVariableW(w.L("PATH"), &path_buf, path_buf.len);
    const path = try std.unicode.utf16LeToUtf8Alloc(h.alloc, path_buf[0..@min(path_len, path_buf.len)]);
    defer h.alloc.free(path);
    const clink_path = try std.mem.concat(h.alloc, u8, &.{ clink_dir, ";", path });
    defer h.alloc.free(clink_path);
    const env: []const [2][]const u8 = &.{ .{ "XDG_STATE_HOME", state }, .{ "CLINK_PROFILE", profile }, .{ "PATH", clink_path } };
    const config = try std.fmt.allocPrint(h.alloc, "{s}shell-integration = detect\ncommand = cmd.exe /k clink_x64.exe inject --quiet\nconfirm-close-surface = false\nclass = {s}\n", .{ base_config, class });
    defer h.alloc.free(config);

    var label: []u8 = &.{};
    defer h.alloc.free(label);
    {
        var g = try h.launchWith("clink-history", config, .{ .env = env });
        defer g.deinit();
        try h.waitText(&g, ">", 1, 30000);
        // Clink's prompt filter (murrtty's ghostty.lua) is in by its second
        // prompt; give the injection a moment.
        w.Sleep(1500);
        const surf = try h.surface(&g, try h.mainWindow(&g));
        const id = try savedPaneId(h, session_path, 0);
        defer h.alloc.free(id);
        label = try std.fmt.allocPrint(h.alloc, "murrtty{s}", .{id});
        try h.typeText(surf, "set CLINK_HISTORY_LABEL");
        h.enter(surf);
        const shown = try std.fmt.allocPrint(h.alloc, "CLINK_HISTORY_LABEL={s}", .{label});
        defer h.alloc.free(shown);
        try h.waitText(&g, shown, 1, 10000);
        try h.typeText(surf, "echo clink-history-check");
        h.enter(surf);
        try h.waitText(&g, "clink-history-check", 2, 10000);
        w.Sleep(1000);
        logClinkProfile(h, profile, "before quitting");
        h.key(surf, .{ .ctrl = true, .shift = true }, 'Q');
        const code = g.waitExit(10000);
        try h.expect(code != null and code.? == 0, "murrtty quits (exit {?d})", .{code});
    }
    w.Sleep(1000);
    logClinkProfile(h, profile, "after quitting");
    {
        var g = try h.launchWith("clink-history-restored", config, .{ .env = env });
        defer g.deinit();
        try h.waitText(&g, ">", 1, 30000);
        w.Sleep(2000);
        const surf = try h.surface(&g, try h.mainWindow(&g));
        {
            var d = try h.dump(&g);
            defer d.deinit();
            const text = d.value.windows[0].tabs[0].text orelse "";
            try h.expect(std.mem.indexOf(u8, text, "clink-history-check") == null, "the restored pane starts with no scrollback", .{});
        }
        h.key(surf, .{}, w.VK_UP);
        const back = h.waitText(&g, "echo clink-history-check", 1, 10000);
        logClinkProfile(h, profile, "restored");
        back catch return h.fail("Up in the restored cmd pane doesn't bring back its command (label {s})", .{label});
        h.key(surf, .{}, w.VK_ESCAPE);
    }
}

/// The files in Clink's profile, with their sizes, for the log.
fn logClinkProfile(h: *Harness, profile: []const u8, comptime when: []const u8) void {
    const pattern = std.fmt.allocPrint(h.alloc, "{s}\\*", .{profile}) catch return;
    defer h.alloc.free(pattern);
    const pattern_w = std.unicode.utf8ToUtf16LeAllocZ(h.alloc, pattern) catch return;
    defer h.alloc.free(pattern_w);
    var data: w.WIN32_FIND_DATAW = undefined;
    const find = w.FindFirstFileW(pattern_w.ptr, &data);
    if (find == w.INVALID_HANDLE_VALUE) return;
    defer _ = w.FindClose(find);
    while (true) {
        const name = std.unicode.utf16LeToUtf8Alloc(h.alloc, std.mem.sliceTo(&data.cFileName, 0)) catch break;
        defer h.alloc.free(name);
        if (name[0] != '.') h.log("clink profile " ++ when ++ ": {s} ({d} bytes)", .{ name, data.nFileSizeLow });
        if (w.FindNextFileW(find, &data) == 0) break;
    }
}

/// A quit right after config reloads exits cleanly (desktop CI, 2026-10-29:
/// theme-system's murrtty panicked at exit, App.deinit's font grid
/// assertion). A reload has each pane swap its font grid through the
/// renderer thread's mailbox, which releases the old grid as it takes the
/// swap; a renderer stopping for the quit before it had taken one kept a
/// reference. The stopping renderer now takes what it still holds
/// (drainForExit). Racy by nature, so many launches; opt-in
/// (GHOSTTY_GUI_STRESS=1).
fn quitAfterReload(h: *Harness) anyerror!void {
    if (w.GetEnvironmentVariableW(w.L("GHOSTTY_GUI_STRESS"), null, 0) == 0) {
        return h.skip("set GHOSTTY_GUI_STRESS=1 to run it", .{});
    }
    var failed: usize = 0;
    for (0..20) |i| {
        const name = try std.fmt.allocPrint(h.alloc, "quit-after-reload-{d}", .{i});
        defer h.alloc.free(name);
        var g = try start(h, name, "window-theme = system\nconfirm-close-surface = false\n", ">");
        defer g.deinit();
        const surf = try h.surface(&g, try h.mainWindow(&g));
        try h.setSystemDark(&g, true);
        try h.setSystemDark(&g, false);
        h.key(surf, .{ .ctrl = true, .shift = true }, 'Q');
        const code = g.waitExit(15000);
        if (code == null or code.? != 0) {
            failed += 1;
            h.log("launch {d}: exit {?d}", .{ i, code });
        } else {
            // What the stopping renderer took (configs) is freed once.
            try expectNoLeaks(h, &g, "and leaks nothing");
        }
    }
    try h.expect(failed == 0, "every quit right after reloads exits 0 ({d} of 20 didn't)", .{failed});
}
