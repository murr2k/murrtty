# murrtty roadmap

murrtty is a native Windows terminal forked from Ghostty: Ghostty's core,
renderer, fonts and configuration with a Win32 runtime, diverging from
upstream where Windows or its own features call for it (see "The fork"
below). This is the plan for it: what is missing, in what order to build it,
how, and how to tell it is done. It began as the plan for a native Windows
port of Ghostty, and was written
from a read of the code at `84e810a3e` (port, in the history before the
2026-10-25 regroup: tag `port/pre-regroup`) on upstream `22f100c63`,
comparing the Win32 runtime (`src/apprt/win32/`) against the core, the GTK
runtime (`src/apprt/gtk/`) and the macOS app (`macos/Sources/`).

The goal is a port that feels like Ghostty, not a terminal that merely runs
Ghostty's core. The first gate is splits: without them the experience is not
Ghostty. After splits come prompt-aware shell integration, then the overlays
and menus users reach for daily (search, command palette, context menu,
scrollbar), then the window chrome.

Effort is for one experienced engineer: **S** under a day, **M** 1 to 3
days, **L** 1 to 2 weeks, **XL** more than 2 weeks. Agent-assisted work
shortens the coding, but not validation on real hardware: physical keyboards
and IMEs, several GPU vendors, Windows 10 and 11.

## Milestones

| Milestone | Contents | Estimate |
|---|---|---|
| **M1: Feels like Ghostty** | All of Phase 0; splits 1.1 to 1.9 (Phase 1); shell integration (Phase 2); and the Phase 3 core UI. The Phase 3 core is 3.0 foundations, context menu, search, command palette, scrollbar, titles, status overlays and toasts, and the bell's `title` indicator. Plus a first pass of keyboard and IME validation (6.2) once splits move focus. | 12 to 14 weeks |
| **M2: Daily-driver parity** | Pane drag and drop (1.10); the rest of Phase 3 (bell audio and border, tab bar, dialogs); all of Phase 4; and Phase 5 items 5.1 to 5.9: IPC, notifications, command-finished notices, taskbar progress, global keybinds, tray, quick terminal, drag and drop, selection clipboard | a further 16 to 20 weeks |
| **M3: Public release** | Phase 7 except 7.8 (upstream merges, full CI, GUI tests in CI, packaging, signing, crash reports, updates, ARM64) and the rest of Phase 6 (DirectWrite fonts, the 6.2 keyboard and IME re-run, OpenGL fallbacks, small fidelity items), in parallel with M2 | 5 to 10 weeks, overlapping M2 |
| **M4: Complete** | Session restore (5.10), undo of closes (5.11), terminal inspector (5.12) | about 4 to 5 weeks |

Not in these estimates: a Direct3D 11 renderer (7.8, XL) and UI Automation
accessibility (6.4, XL). Spikes S1, S2, S3 and
S6 add about a week, before the items they decide. The phase headings below
give each phase's own total; the milestones regroup them by user value.

## Decisions for the owner

These change the work. Each has a recommendation.

1. **How splits are presented.** The plan keeps one child window with its
   own WGL context per terminal and lays panes out as child windows (Phase 1).
   The alternative is one GL presenter per window that composites every
   surface's texture: simpler dividers, dimming and transparency, but an XL
   change to the renderer's threading. *Recommended: child windows.* Splits
   then arrive in about two and a half weeks, and DirectComposition (4.1,
   Phase B) can still give each pane its own visual later.
2. **`Ctrl+Shift+W`.** Upstream's non-macOS defaults bind it to
   `close_surface` and then rebind it to `close_tab` (`Config.zig:6844-6868`),
   so Windows and Linux have no default key that closes one pane. *Recommended:
   keep upstream's behavior and document `keybind = ctrl+shift+w=close_surface`
   for users who want Windows Terminal semantics.* *Decided 2026-10-25 (1.9):
   as recommended; the README documents the keybinding, and the
   `split-commands` scenario closes a pane with it.*
3. **Default shell.** Upstream uses `cmd.exe`. *Recommended: PowerShell 7 when
   installed, else cmd* (2.5). It is what Windows users run, and Phase 2 gives
   it shell integration.
4. **Last window closed.** `quit-after-last-window-closed` defaults to false
   off Linux (`Config.zig:2637`). Honoring that without a tray icon would leave
   an invisible process. *Recommended: keep quitting on the last window until
   the tray (5.6) exists, then honor the option.*
5. **Identifiers.** The AppUserModelID, pipe names, winget package ID and the
   installer's mutex should be fork-specific, not `com.mitchellh.ghostty`, and
   picked before the first release: changing an AppUserModelID later breaks
   pinned taskbar icons. *Decided 2026-10-26: murrtty's own (R3).*
6. **CI on a private repository.** Actions minutes are billed for private
   repos, and Windows runners count double. *Recommended: a single port-owned
   workflow (0.11, later 7.2), started manually or on release tags at first.*
   *Decided 2026-10-24: both kinds of runner.* A self-hosted runner on the
   owner's desktop runs the build, the unit tests and the GUI suite often,
   possibly on every push (its GPU has the OpenGL 4.3 hosted runners lack);
   the owner accepts GitHub's fee for self-hosted runners on private repos.
   The GitHub-hosted job stays manual and occasional (after a rebase, before
   a release) as the clean-machine builder test, so it gets no build cache.
   Planned at the break between Phase 0 and Phase 1. Open points for that
   plan: the runner must run in a signed-in session for the GUI suite
   (a service in session 0 has no interactive desktop), the clipboard
   scenarios briefly take over the clipboard of the session they run in, a
   dedicated low-privilege account, and the runner must never serve a public
   repository.
7. **Upstreaming.** Whether to pursue in-tree support (7.9). It decides how
   carefully history is kept (0.10) and which fixes are written to be
   upstreamable first (Windows `reportPwd`, font style matching). *Decided
   2026-10-26: no.* Ghostty's maintainers said on their Discord that they
   won't add more runtimes to Ghostty and suggested building a Windows
   terminal on libghostty-vt instead. The owner kept the fork, renamed it
   murrtty, and lets it diverge (see "The fork").
8. **Visibility.** The repository is private. winget and the update appcast
   (7.4, 7.6) need publicly downloadable artifacts. *Decide before M3* whether
   the repository goes public then, or releases are hosted elsewhere. Going
   public also makes standard Actions runners free, which changes decision 6.
   *Decided 2026-10-26: public.* murrtty's code goes to a new public
   repository, `murr2k/murrtty`, under the MIT license like Ghostty; the
   private repository stays as a mirror that every push also goes to, so the
   self-hosted GPU runner never serves a public repository (R4).

## The fork

*Decided 2026-10-26.* murrtty is open source, MIT-licensed like Ghostty, and
not affiliated with the Ghostty project.

- **Divergence.** Upstream's design no longer limits murrtty: Windows-native
  behavior and new features may change shared code where that is the right
  place. Shared-code changes stay small and self-contained where it costs
  nothing, because upstream is still merged in (below).
- **Upstream.** Ghostty's `main` is merged into murrtty periodically (per
  upstream release, or when a fix is wanted), replacing the rebases of 0.10:
  a diverging history rebased every time would replay ever more commits.
  `rerere` stays on. Internal names in shared code (`Ghostty*` types, the
  `GHOSTTY_*` variables the shell integration uses, the `ghostty` resource
  folder) stay as they are, so those merges stay cheap.
- **What stays compatible.** The configuration format (and, by default, an
  existing Ghostty configuration, R3), `TERM=xterm-ghostty` and its terminfo
  (programs get the capabilities the shared core implements), the shell
  integration, themes and key bindings.
- **What is murrtty's own.** The executable `murrtty.exe`, window classes,
  `TERM_PROGRAM=murrtty` (so programs' bug reports reach murrtty, not
  Ghostty), the configuration folder `%LOCALAPPDATA%\murrtty`, the
  identifiers of decision 5, and the icon: Ghostty's name and logo belong to
  the Ghostty project and are used only to say what murrtty is based on.
- **Look** (decided by the owner 2026-10-26). By default murrtty looks like
  Ghostty's GTK app as libadwaita draws it on GNOME: its colors (Adwaita's
  light or dark by the terminal background, as `window-theme = auto` does
  there), fonts, spacing, kerning and margins, header bar and menus.
  Windows' own look stays only where GTK has nothing to match: the window's
  minimize and maximize buttons, Snap Layouts, the system menu. Reference:
  the GTK app under WSLg (`run-linux.cmd`), minding that WSL lacks GNOME's
  interface font, so its menus fall back to DejaVu Sans.

Fork items, ahead of the rest of Phase 3:
- **R1, S.** Record the decision (this section, the README). *Done
  2026-10-26.*
- **R2, S.** A trial merge of current upstream `main` on a local branch, to
  measure what each merge costs. *Done 2026-10-26:* upstream `0fe113a35`, 18
  commits past the base `22f100c63` and 21 files (three of them,
  `Screen.zig`, `stream_handler.zig` and `Termio.zig`, also changed by the
  fork), merged without a conflict; unit tests (4,081 passed) and the GUI
  suite passed unchanged, so the merge was kept (`343c485fc`). Pushing it
  needs upstream's objects, which this blobless clone may lack: push from a
  full clone if the push is refused.
- **R3, M.** Rename and brand: the identifiers above, a placeholder icon,
  the builder, harness, CI and README, and a copyright line for murrtty's
  changes beside Ghostty's in `LICENSE`. *Done 2026-10-26.*
  `build_config.murrtty` (true on Windows), `product_name` and `product_id`
  carry the name into shared code: `+version` ("murrtty, based on Ghostty
  ..."), `TERM_PROGRAM` and XTVERSION (`murrtty`), and the configuration
  folder (`file_load.zig`: murrtty's own file, else Ghostty's, which Open
  Configuration then opens; the `config-folder` scenario). The executable
  is `murrtty.exe` with `dist/windows/murrtty.rc`, `.ico` and `.manifest`
  (Ghostty's own `ghostty.*` files are back to upstream's text); window
  classes are `Murrtty*`; dialogs and the title fallback say murrtty; the
  AppUserModelID is `murrtty.murrtty`. The icon is a placeholder ("m" and a
  block cursor, `images/murrtty/make-icon.ps1`). Clink's script accepts
  either `TERM_PROGRAM`; its scenario part still needs the owner's run.
- **R4, S.** Publish `murr2k/murrtty`: an audit for secrets and personal
  data, upstream's workflows kept from running there, the desktop workflow
  limited to the private mirror, and pushes going to both repositories.
  *Prepared 2026-10-26, held by the owner.* The audit found no secrets or
  credential patterns in the fork's commits or messages; what becomes
  visible is the commits' author identity and this roadmap's description of
  the desktop runner. The desktop workflow already runs only in the private
  repository. Steps when the owner says go: create the public repository,
  turn Actions off there before the first push (upstream's workflows would
  run otherwise), push `windows-port` as its `main` and nothing else (never
  `perf-trace`, no tags), then push to both repositories from then on.

### Differences from Ghostty's GTK app

Where murrtty behaves differently from Ghostty's GTK app on purpose, and
why. Not listed: what isn't built yet (the README's status) and internals
that change nothing a user sees. A change that adds, changes or removes a
difference updates this list in the same commit; each entry names the
roadmap item behind it.

*Deliberate:*
- **Default shell** (2.5): PowerShell 7 (`pwsh.exe -NoLogo`) when it is
  installed, else `cmd.exe`; GTK starts the user's login shell.
- **Identity** (R3): murrtty's own configuration folder,
  `%LOCALAPPDATA%\murrtty`, falling back to an existing Ghostty
  configuration; `TERM_PROGRAM=murrtty` and an XTVERSION of `murrtty`
  (`TERM` stays `xterm-ghostty`); `+version` says "murrtty, based on
  Ghostty".
- **Extra split keys** (1.9): `Ctrl+Shift+[` and `]` also go to the previous
  and next split, because Windows holds upstream's `Win+Ctrl+[` and `]`.
- **Numpad navigation keys** (6.2): with NumLock off, a numpad key without
  a binding of its own takes its dedicated key's, so the numpad's
  `Ctrl+Ins` copies and `Shift+Ins` pastes, as in other Windows apps;
  GTK's binds only the dedicated keys.
- **Links** (0.1): untrusted links (OSC 8, unknown kinds) are vetted. Web
  and mail links open; a file opens only if it is inert (code runners are
  blocked, symbolic links are not followed); anything else asks first. GTK
  hands every link to the desktop's opener.
- **Window names** (3.5): a window's name is its caption, so the taskbar
  shows it too; GTK's goes only to the header bar, its window list keeping
  the tab's title. On Windows the caption is the window's title.
- **Renaming a tab by double-clicking it** (3.5): murrtty's own; GTK's tabs
  don't.
- **Closing a background pane** (1.4): the focus stays where it is, as on
  macOS; GTK moves it.
- **`resize_split`** (1.5): each step is clamped, since upstream's resize
  asserts on large deltas; GTK doesn't clamp.
- **Background blur** (4.2): Windows' own: Acrylic, its documented
  backdrop (tinted for the light or dark theme, with its grain), in an
  active window from Windows 11 22H2, and otherwise a plain blur through
  the undocumented accent policy (Windows draws Acrylic solid in an
  inactive window). GTK's blur is the compositor's (KWin's, or
  `ext-background-effect-v1`); both ignore the intensity.
- **No decorations** (4.4): `window-decoration = none` keeps Windows'
  resize borders, its shadow and rounded corners, and a resize band along
  the top (with no tab row above them, it takes the top few pixels of the
  panes, 8 at 100%, from the terminal's clicks); GTK's undecorated window
  loses its resize controls with the title bar
  (`gtk_window_set_decorated`). Toggling decorations keeps the terminal's
  grid, the window growing or shrinking by the header bar where it is,
  where GTK keeps the window's size.
- **Window options** (4.6): `window-position-x`/`-y` (every new window's
  frame there, as macOS), `window-step-resize`, the float binding
  (`toggle_window_float_on_top`) and `reset_window_size` work as on macOS;
  GTK has none of them.
- **Background opacity toggle** (4.1): `toggle_background_opacity` works
  as on macOS: every window turns opaque, or translucent again, and new
  windows follow; with `background-opacity` at 1 it does nothing. GTK
  doesn't implement it.
- **Command palette** (3.3): each "Focus:" row says where its terminal is
  ("Tab 2: C:\src", "Window 2, tab 1: ..."), and typing matches that line
  too; GTK's rows show only the title. Results are ranked (title matches,
  then the line beneath, then letters in order) rather than alphabetical.
- **Palette over the title bar** (3.3, 4.3): with the command palette open,
  the header bar's caption, window buttons and top resize band still work
  (its own buttons stay covered). GTK's dialog dims the whole window; its
  dimming moves and maximizes the window, but its buttons are out of reach.
- **Scrollbar track** (3.4): a click on the track pages, as Windows' scroll
  bars do; GTK's jumps to the spot.
- **Link preview** (3.6): a long URL is cut with an ellipsis; GTK lets it
  run past the pane.
- **Renderer panel** (3.6): while the renderer is unhealthy the pane shows
  macOS's message; GTK shows nothing.
- **Windows shells** (Phase 2): shell integration for PowerShell (7 and
  5.1) and `cmd` (with Clink); the working directory from OSC 9;9 (Windows
  Terminal's form) as well as OSC 7, and for `cmd` without integration from
  the process itself. GTK's integration covers bash, zsh, fish, elvish and
  nushell.
- **Single instance** (5.1): a named pipe per user, session, integrity
  level and class instead of D-Bus. The first murrtty of a class serves
  `+new-window` and `+new-tab` whatever `gtk-single-instance` says; GTK's
  reach only a single-instance app, which owns its D-Bus name.
  `gtk-single-instance = detect` is on for a launch from the desktop (a
  shortcut or Explorer) without arguments, since Windows' shells and
  terminals don't set `TERM_PROGRAM`; GTK's asks `TERM_PROGRAM` and the
  arguments.
- **Requests** (5.1): `+new-tab` opens in the directory it passes (the
  caller's, unless given) even beside a pane whose directory a new tab
  would inherit; GTK applies the inherited one after the request's, so
  that pane's wins. In `--working-directory=`, `home` is the home
  directory and `inherit` the caller's; GTK takes both as paths. An
  argument murrtty can't read (a bad `--command=`) is skipped, where GTK
  drops all of them (`+new-window`) or opens nothing (`+new-tab`). A
  request's command wins over `initial-command`, and `+new-tab` brings its
  window forward; GTK's does neither.
- **Global keybinds** (5.5): Windows hot keys, which take the combination
  from every other program at once and fail when Windows or another
  program holds it; GTK asks the desktop's global shortcuts portal, which
  may ask the user first or let them pick another combination. A global
  binding with chained actions runs them all, as the core runs one; GTK
  binds only single-action global bindings.
- **Toggle visibility** (5.5): `toggle_visibility` as on macOS: with
  murrtty in front it hides every window, otherwise it brings murrtty
  forward with the windows it hid, as they were; only while a global
  binding can bring them back. GTK doesn't implement it.
- **Taskbar progress** (5.4): OSC 9;4 also shows on the window's taskbar
  button (its active tab's focused pane's), as Windows Terminal shows it;
  GTK has only the bar over the pane.
- **Config in a new window** (5.1): `open_config:new_window` runs `$VISUAL`
  or `$EDITOR` itself, its words split as a command's (quotes group) with
  the file as one argument, where GTK runs it through `/bin/sh -c`; with
  neither set the file opens as `open_config` opens it, where GTK runs vi.

*For now:*
- **Notifications** (5.2): balloons of a notification-area icon, which
  Windows shows as toasts, with the icon in the notification area while
  one is pending (GTK's have none). The icon stands for them all: a click
  presents the latest's pane, and they all go when that pane gets the
  keyboard or closes, or 3 s after the latest if its pane had the
  keyboard; an earlier one's pane taking the keyboard takes nothing back.
  GTK's go each with its own pane, and one the same as a pane's earlier
  one replaces it, where murrtty adds another toast. Titles are cut to 63
  UTF-16 units (an emoji counts two) and bodies to 255, with no ellipsis.
  One with no body shows its title under "murrtty", since Windows shows
  no balloon without text; GTK's shows the title alone. WinRT toasts,
  5.2's second step, are to lift this.
- **Pulsing progress** (5.4): the bar's block moves a step with each
  report; GTK's glides between them.
- **Dragging a tab** (4.5): once out of the strip, nothing follows the
  mouse until the release (libadwaita drags an image of the tab), and
  Escape doesn't cancel the drag.
- **Last window** (decision 4): murrtty always opens a window at start and
  quits with its last window, whatever `initial-window` and
  `quit-after-last-window-closed` say, until the tray (5.6) exists.
- **Toasts** (3.6): the latest replaces the one showing, for 3 seconds;
  GTK queues them, each with a close button.
- **Read-only badge** (3.6): shown at once; GTK fades it in over 500 ms.
- **Palette dimming** (3.3): a click on it closes the palette. GTK's
  palette, a floating libadwaita dialog, stays open; its dimming moves the
  window instead (a window handle). 4.3b takes this with the dialogs.

- **Tab menu** (3.8): a tab's right-click menu has Change Tab Title, Close
  Tab, Close Other Tabs, Close Tabs to the Right and Move Tab to New
  Window (4.5), acting on the tab clicked; GTK's offers only Change Tab
  Title.
- **Tab overview** (3.8): the strip's list button and
  `toggle_tab_overview` open a list of the window's tabs with a filter
  box (the command palette's), not GTK's overview of live thumbnails.
- **Tab overflow** (3.8): tabs that don't fit scroll between chevrons and
  with the wheel; GTK's strip scrolls without chevrons.
- **Chrome font** (4.3): the header bar and tabs are in Adwaita Sans 11,
  GNOME's default interface font, bundled; GTK takes the desktop's
  interface font setting, which on Windows would be Segoe UI.
  `window-title-font-family` names another.
- **Window buttons** (4.3): the header bar always has minimize, maximize
  and close, drawn as libadwaita's round window controls; GTK shows the
  ones its button layout names (GNOME's default: close alone). Its buttons
  take the bar's whole height and close reaches the window's edge, so a
  maximized window's top edge and corner hit them, as Windows' do.
- **No title bar** (4.3): with `gtk-titlebar = false` (or a maximized
  window with `gtk-titlebar-hide-when-maximized`) murrtty shows the
  system's caption; GTK's window then has no title bar at all.
- **Tab tooltips** (3.8): a tab's tooltip shows its title and, beneath,
  its working directory (unless the title shows it); GTK's shows only the
  directory. The strip's buttons have tooltips with their bindings.
- **Close confirmations** (3.9): closing a tab's only pane asks "Close
  Tab?" (GTK: "Close Split?"), and closing several tabs at once asks once,
  "Close Tabs?" (GTK asks for each tab).
- **Clipboard confirmation** (3.9): a write's dialog says the text shown is
  what the program would write (GTK's says the current contents, but shows
  the same text); control characters show as Control Pictures; Escape or
  the close box denies without remembering (GTK's remembers a Deny then).
- **Menus** (4.3b): Windows' popup menus with their items drawn as
  libadwaita's popover menus (its rows, colors, font, separators and
  chevrons): the frame, its rounded corners and shadow are Windows 11's,
  and a submenu opens beside its item as Windows' do (GTK's context menu
  nests its submenus the same way). Access keys stay, underlined when the
  keyboard opens a menu; GTK's menus have none. Bindings read as Windows
  writes them (Ctrl+Shift+T, Ctrl+Ins); GTK writes Shift+Ctrl+T and
  Ctrl+Insert.
- **Dialogs** (4.3b): libadwaita's alert dialogs (the close confirmations,
  the title prompt, the clipboard confirmation, the config errors) are
  Windows dialogs drawn that way: their own window centered over the
  dimmed one (GTK's sit inside the window), with Windows 11's rounded
  frame (libadwaita rounds 18 px); Escape, Enter and Tab behave as in any
  Windows dialog. Text boxes are in Consolas, not GNOME's monospace.
- **Configuration errors** (0.x, 4.3b): the dialog adds Open
  Configuration, which opens the file and leaves the dialog open; GTK's
  offers Ignore and Reload Configuration.
- **System menu** (3.9): Alt+Space's menu adds New Window, New Tab, Split,
  Command Palette, Terminal Inspector, Config, About murrtty and Quit
  after Windows' own items; GTK has no such menu.

*Decided, not built yet:*
- **Config editor** (F1): a GUI for every configuration option; Ghostty is
  configured only by editing its file.

## Rules every item keeps

The port's existing invariants (see the project notes and commit messages)
apply to all new code:

- **Close only from the message loop.** Tabs, panes and windows are freed only
  through `App.request` and `App.runRequests`, never inside a core callback or
  while a modal loop runs. That includes context menus, dialogs and file
  pickers, which run inside a modal scope (`App.beginModal`, then
  `defer modal.end()`; 0.0).
- **One dialog at a time.** `App.confirm` and its successors keep the single
  modal, the disabled sibling windows and `resumeAfterModal`.
- **Exact colors.** The sRGB present invariant holds: the default background
  samples as exactly `#282c34`. Every change to the present path is checked
  with a `PrintWindow` capture.
- **Ghostty semantics first.** Behavior follows GTK and macOS. Where murrtty
  departs from GTK (following macOS, because Windows needs something else,
  or as a feature of its own), the change adds it to "Differences from
  Ghostty's GTK app" above in the same commit, and to the README where
  users would notice.
- **Testable with posted messages.** New UI must be drivable by the GUI
  harness (0.8, run in CI by 7.3) without real input focus, since background
  sessions and CI have none.

## Spikes before committing to a design

| Spike | Question | Decides |
|---|---|---|
| **S1** overlay host, 1 day | Does a child window drawn over a WGL child window stay clean (no flicker, no stale pixels) while output floods and during live resize, on two GPU vendors? | Where text and interactive overlays live (3.0). *Run 2026-10-25 on NVIDIA (RTX 2070, driver 32.0.16.1062), scenario `overlay-host` (opt-in, `GHOSTTY_GUI_SPIKE=1`), six runs:* a solid window over each of two panes, captured through DWM (`PrintWindow`) 200 times per variant while both panes flooded output and the window resized before every third capture. GL honors the clip of a plain child window, whether a sibling of the surface or a child of it: no overlay pixel was ever drawn over. But it leaves a hole where one was: after a move the old place still showed the overlay 33 ms later in some captures (none 200 ms later), after a removal for up to 1 s, and both repainted on every resize (about 600 paints a run). A layered child (`WS_EX_LAYERED` with `SetLayeredWindowAttributes`, which needs the manifest's Windows 10 `supportedOS` entry) is composed by DWM over a surface that GL draws in full: in every run it was never dirty or stale, not even the moment a resize returned, left nothing behind when removed, and painted once. So text and interactive overlays are layered child windows of the surface. AMD and Intel not yet run. |
| **S2** transparency, 1 to 2 days, run before 3.0 | Does DWM honor per-pixel alpha from child GL windows when the top level uses `DwmEnableBlurBehindWindow` with an empty region? | Transparency path: cheap (4.1 A) or DirectComposition with `WGL_NV_DX_interop2` (4.1 B, XL). Also whether text overlays (3.0) and the tab strip (3.8, 4.3) can stay GDI, or must become composition visuals, since GDI output does not show on a Phase B window. *Prepared 2026-10-26, not yet run:* a Debug test hook turns on blur-behind with an empty region and a present mode that writes the frame's alpha as premultiplied sRGB; the opt-in scenario `transparency` (`GHOSTTY_GUI_ONSCREEN=1`; it shows windows on the screen) puts Ghostty at `background-opacity = 0.5` over a green backdrop and reads the display through DXGI desktop duplication (`test/windows/gui/dda.zig`), checking the background blends to `#14951a`, a layered child (S1's host) stays opaque over it, and what a GDI-painted divider shows. It needs a monitor DWM drives: with the monitor off, DWM idles at one vblank a second, duplication gets no frames and GL presents never reach the window (every capture reads white), so the capture scenarios now skip themselves then. *Run 2026-10-26 on NVIDIA (RTX 2070), the owner at the screen:* Phase A works. Opaque, the background read `#282c34`; at 0.5 over the green backdrop, `#14951a`, exactly half (DWM blends with the frame's alpha; ignoring it would read `#14161a`); a layered child (S1's host) stayed opaque over the see-through pane, as did sibling and child windows; GDI's own view (BitBlt) agreed. A GDI-painted divider read `#18ff1f`, its color plus the whole backdrop: GDI writes alpha 0, which DWM takes as fully transparent. So 4.1 takes Phase A, and the tab strip (3.8, 4.3) and dividers stay GDI but paint with alpha 255 (a 32-bit DIB or `BufferedPaintSetAlpha`) while the window is translucent. AMD and Intel not yet run. The scenario's "monitor off" check (DWM's vblank count) also fires on a static screen with the monitor on, where DWM composes only a few times a second, so with `GHOSTTY_GUI_ONSCREEN=1` (the owner at the screen) the capture scenarios skip that check and keep only the screen saver and lock screen one. |
| **S3** ConPTY, 1 day | Does the inbox ConPTY forward OSC 133, OSC 7, OSC 9;9 and DECSCUSR, in order, on Windows 10 22H2 and Windows 11 23H2 to 25H2? | Whether to bundle `conpty.dll` and `OpenConsole.exe` (2.2). *Run 2026-10-25 on Windows 11 25H2 (build 26200), inbox ConPTY, flags 0 as Ghostty uses:* a child writing text markers with each sequence between them (via cmd `type`, pwsh 7 and Windows PowerShell 5.1) got all of them through: OSC 133 A, B (ST-terminated), C and D;0, OSC 7, OSC 9;9 and DECSCUSR. The OSC 133 marks keep their place in the text; OSC 7, OSC 9;9 and DECSCUSR can arrive ahead of text written before them, which doesn't matter for them. OSC 2 is absorbed and re-sent as OSC 0. Flag 0x8 (passthrough) changed nothing. So no bundling for Windows 11; Windows 10 22H2 and 23H2/24H2 not yet run (the probe needs `STARTF_USESTDHANDLES` with null handles, as `Command.zig` passes, or the child writes to the parent's handles). *Found in 2.2:* ConPTY repaints rows as it renders, line feeds included, and after 133;B (input until 133;C) those line feeds marked output rows as prompt continuation, so `jump_to_prompt` stopped on output. Not reordering: one write arrived in place, and a pause before the prompt changed nothing. The integrations end the prompt with 133;I (input ends with the line) instead. Clearing the screen (`cls`, `Clear-Host`) arrives as a repaint, not an erase, so rows that held a prompt keep their prompt mark. *Found in the mid-phase review:* 133;A's fresh-line moves Ghostty's cursor when it isn't at column 0, which ConPTY never learns of, so its later absolute moves land a row off; the integrations start prompts with 133;P;k=i, which marks the same without moving. *Found with Clink (raw pty captures, `GHOSTTY_PTY_LOG`):* ConPTY forwards OSC 133 ahead of text written before it, so a prompt mark arrived before the line feed ahead of the prompt (marking the row above), and during the repaint after a resize, when Clink redraws its prompt, with ConPTY's cursor at the bottom right (marking a blank row that later output scrolled onto). Behind ConPTY a prompt start now marks the row of the next cell written (`Terminal.flags.defer_prompt_mark`, set in `Exec.initTerminal`). |
| **S4** many contexts, part of 1.4 | 16 panes, each flooding output: steady frames, no stale-frame recurrence, linear memory, on two vendors | Whether per-pane contexts scale. *Run 2026-10-24 on NVIDIA (RTX 2070), scenario `stress-panes`:* every pane kept presenting (1,030 to 1,210 frames each in 13 s, Debug build); memory flat while flooding; per added pane 4 threads, 31 MB resident, 90 MB committed, 64 MB of it Zig's thread stacks (0.15). They scale. AMD and Intel not yet run. *Re-run 2026-10-25 at the end of Phase 1 (15 panes dimmed by 1.7's overlay):* the slowest pane presented 994 frames in 13 s; memory per pane unchanged, and 49 MB of growth in 15 s of flooding (scrollback). |
| **S5** reparenting, part of 4.5 | Does a GL child window keep rendering after `SetParent` to another top-level window, on NVIDIA, AMD and Intel? | Tab tear-off design. *Run 2026-10-27 on NVIDIA (RTX 2070), on the hidden desktop (`tab-drag`):* after its tab's container moved to another window the pane kept presenting frames (the renderer's count and read-back) and taking input. What the display shows wasn't checked (no monitor on); AMD and Intel not yet run. |
| **S6** OpenGL elsewhere, 1 day | What does Microsoft's OpenGL compatibility pack expose on Snapdragon X and in VMs: 4.3 core with fragment SSBOs and sRGB framebuffers? | ARM64 (7.7) and software fallback (6.3) |

---

## Phase 0: Safety and quick wins (about 2.5 weeks)

Cheap items that fix wrong behavior today or lay groundwork everything else
uses.

**0.0 Modal and COM foundations, S.** *Done 2026-10-24.* Built first,
because 0.1 and 0.6 need them.
- Generalize `App.confirm` into a modal scope, `App.beginModal` and
  `Modal.end` (modal depth, disabled siblings, held requests), and keep
  `confirm` as a wrapper. Every nested loop uses it: `TrackPopupMenuEx`,
  `TaskDialogIndirect`, dialog templates, file pickers.
- A `TaskDialogIndirect` wrapper with custom buttons and expanded text
  (comctl32 v6 is already in the manifest).
- Call `OleInitialize` once in `App.init`. It initializes COM as STA, and it
  is required for `RegisterDragDrop` (5.8); plain `CoInitializeEx` would make
  that call fail.

*Done when:* the existing close and clipboard confirmations behave as before,
and a close request queued while a TaskDialog is open runs only after it
closes.

**0.1 Untrusted links (security), M.** *Done 2026-10-24.* `open_url` sent
every link kind to `rundll32 url.dll,FileProtocolHandler` (`os/open.zig`),
which runs executables, `.lnk`, `.url`, UNC targets and arbitrary protocol
handlers. Upstream marks OSC 8 and unknown links untrusted and requires the
runtime to vet them (`apprt/action.zig`); macOS does. Add `win32/url.zig`
deciding allow, confirm or deny:
- Reject control, bidi and zero-width characters.
- Allow `http`, `https` and `mailto`.
- For files: deny UNC and device paths, and anything `AssocIsDangerous` or
  `%PATHEXT%` flags; open directories with the `explore` verb.
- Confirm any other scheme with a dialog showing the full target.

Launch with `ShellExecuteExW`, and return true for untrusted kinds even when
denied, so the core never falls back to the unsafe opener. *Done when:* unit
tests cover the decision table, and an OSC 8 link to `calc.exe` is blocked
while an https link opens the browser.

*As built:* links queue as an `App.Request` and are decided from the message
loop, because the core asks with the renderer lock held. Beyond the plan,
much of it from review:
- Files fail closed. Only inert types (text, source code, images, media,
  PDF) open directly. A file is blocked if its extension can run code (our
  list, `%PATHEXT%`, `AssocIsDangerous`) or the program registered for it is
  an interpreter or loader (`py`, `wscript`, `mshta`, `msdt`, ...). Every
  other file asks first, naming the program.
- Paths are canonicalized with `GetFullPathNameW`, then walked one component
  at a time with `FindFirstFileExW`, which gives the long names (an 8.3 name
  can hide an extension) without following any link. A path through a
  symbolic link is blocked, since following one can connect to another
  computer. A junction's target is read and walked in turn (it can pass
  through a symbolic link); volume mount points and cloud files are fine.
  Names Win32 can't spell (a trailing dot or space, reached by an 8.3 alias)
  and names with disguising characters are blocked too.
- Reserved device names, streams and `name.{CLSID}` folders are denied, and
  so is a short list of abused schemes (`ms-msdt`, `search-ms`,
  `ms-officecmd`, `ms-appinstaller`, script and help-file schemes, `shell`).
- URLs are percent-encoded as Chromium does, non-ASCII included, before they
  reach a handler's command line, so a quote or space (or a look-alike an
  ANSI program would "best fit" into one) can't add arguments.
- Files and folders open as the checked shell item (a PIDL) with their
  default verb, so the user's file manager opens folders, and the launch is
  refused if the shell parsed the path into a different item. The root of
  removable or optical media is shown selected instead
  (`SHOpenFolderAndSelectItems`), since its `autorun.inf` can define any verb.
- The block dialog offers Copy Link (the full, escaped target), not a way to
  open the link anyway.

The `links` GUI scenario checks the decisions, with the Debug build recording
launches instead of performing them. `links-open` performs real launches
through a protocol and a file type it registers in HKCU (volatile keys, swept
before and after), handled by a windowless recorder, on the hidden desktop;
https takes the same `ShellExecuteExW` path. Core fix: on Windows,
`resolvePathForOpening` no longer resolves relative text (see 2.1) or touches
the file system. Its std calls panicked Debug builds on a Ctrl+clicked URL,
`./nul` or an over-long name, and a very long path overran a fixed stack
buffer in release builds.

**0.2 Stop swallowing default keys, S.** *Done 2026-10-24, with a caveat.*
The defaults for the inspector
(`Ctrl+Shift+I`), the command palette (`Ctrl+Shift+P`), new split
(`Ctrl+Shift+O`/`E`) and split zoom (`Ctrl+Shift+Enter`) are not
`performable`, so the core consumes them even though the runtime returns false
(`Surface.zig:3178-3196`). Programs never see these keys. Mark them performable
on Windows only until each feature lands, then remove each override. *Done
when:* `Ctrl+Shift+P` reaches a key-echo program.

*As built:* `Config.Keybinds.windows_unimplemented` marks the five bindings
performable on Windows, and a unit test checks them; the log shows the core
now encodes the key after the runtime declines. The done criterion can't be
met yet, though: ConPTY drops the sequences these keys encode to before a
console program sees them (0.12). Remove each override when its feature
lands (Phase 1 splits, 3.3 palette, the inspector).

**0.3 `background-opacity` without darkening, S.** *Done 2026-10-24.* The renderer emits a
premultiplied background, and `presentWgl` blits it onto opaque black, so any
opacity below 1 shows a darker color (`OpenGL.zig:395-409`). Replace the blit
with a present pass: a full-screen triangle that clears to the terminal
background and composites the target with `ONE, ONE_MINUS_SRC_ALPHA`. The
same pass clears resize margins to the background instead of black, and it is
the hook for in-surface overlays (3.0) and transparency (4.1). *Done when:*
with opacity 0.5 the background samples exactly as configured, and the
default stays `#282c34`.

*As built:* the pass computes `frame + background * (1 - frame.a)` in the
frame's color space, with the frame at the window's top-left corner and the
background filling any margin. It also fixed `alpha-blending = native`, whose
colors were sRGB-encoded twice (`#336699` showed as `#7caacb`); native mode
is now within one step per channel, the residue of the sRGB render target's
8-bit encoding (exact would need native mode to render without it). The
`present` GUI scenario checks exact pixels on the hidden desktop, read back
by the Debug renderer under the test hooks: the background at several
opacities, and a prompt cell painted red, which proves the frame itself
reaches the window at its top-left corner, unblended.

**0.4 Window theme and caption colors, S.** *Done 2026-10-24.*
- Implement `window-theme` (auto, system, light, dark, ghostty) and
  `window-titlebar-background`/`-foreground`.
- On Windows 11 set `DWMWA_CAPTION_COLOR`/`TEXT_COLOR`/`BORDER_COLOR`. With
  the default `window-theme = auto`, the caption takes the terminal background
  and follows OSC 11 (from the top-bordering panes once Phase 1 lands), as
  macOS's default transparent titlebar does. Windows 10 gets a light or dark
  caption.
- Handle `color_change` (OSC 10/11) and surface-targeted `config_change` for
  the tab strip.
- Fix a bug found in review: system theme changes never reach
  `Surface.colorSchemeCallback`, so conditional themes and DEC mode 2031 never
  update.
- The scheme reported to the core comes from the system setting or a forced
  light or dark only, never from the computed chrome colors. Otherwise a
  conditional theme can make the soft config reload loop.

*Done when:* every `window-theme` value gives the expected caption under both
system themes, and mode 2031 reports arrive.

*As built:* each surface tracks its current background and foreground
(config, then OSC 10/11, reset by its `config_change`), and the window's
caption, border, caption text and tab strip follow the active tab's. The
`theme` GUI scenario checks every value through the state dump (what Ghostty
asks DWM for), the caption following OSC 11, and a simulated system switch
reaching open terminals' color scheme, which is what queues the mode 2031
report; whether the report then gets through ConPTY to the program isn't
observable from the tests. `auto` takes the terminal colors even when the
theme has light and dark variants (the config docs say `auto` then acts as
`system`); the terminal's colors follow the scheme in that case anyway.

**0.5 Paint hygiene during resize, S.** *Built 2026-10-24; the visual check
is still open.*
- Lay out with `BeginDeferWindowPos`/`DeferWindowPos` and `SWP_NOCOPYBITS`.
- Paint exposed areas in the terminal background.
- Fix the tab strip painting at most 64 titles while hit-testing all of them
  (`Window.zig:470-486`).

*Done when:* a slow-motion capture of a resize shows no black bars or trails.

*As built:* all three, plus 0.3's present pass, which fills the surface's
own margin with the background while its frame catches up. The `resize`
GUI scenario checks that growing and shrinking relays out the grid and
leaves the corner exactly the background color. The slow-motion capture
needs the visible desktop and hasn't been done yet.

**0.6 Config errors dialog, S.** *Done 2026-10-24.* Config diagnostics only reach the log of a
GUI program with no console (`App.zig:86-91`). After startup and each reload,
show a TaskDialog listing them, with Open Configuration, Reload and Ignore.

Also make `open_config` reliable, since Open Configuration and the default
`Ctrl+,` depend on it. It goes through `rundll32` today, which on a clean
machine shows the "How do you want to open this file?" chooser. Use
`ShellExecuteExW` with the `edit` verb, falling back to Notepad.

*Done when:* a misspelled key produces the dialog, fixing it and choosing
Reload applies the change, and `Ctrl+,` opens the file in an editor on a clean
machine.

*As built (2026-10-24):* the dialog shows at startup and after a config
change whose errors differ from those last shown, or after any hard reload,
so a soft reload (a theme switch) doesn't repeat it. Open Configuration
keeps the dialog up (a TaskDialog callback) so the file can be fixed and
then reloaded. `open_config` now runs from the message loop and tries the
`edit` verb, then `open`, then Notepad. The `config-errors` GUI scenario
covers the dialog, Open Configuration, fix and Reload, and `Ctrl+,`, with
the editor launch recorded rather than performed; the clean-machine editor
check is still open.

**0.7 Launch context, S.** *Done 2026-10-24.*
- Explorer and Start menu launches already open in the home directory,
  because `probableCliEnvironment` is hard-coded false on Windows
  (`Config.zig:5349-5354`).
- Started from a shell, Ghostty should inherit that shell's directory. Make
  `probableCliEnvironment` work on Windows, using desktop-launch detection as
  the signal that keeps double-click launches on home. Detection:
  `STARTF_TITLEISLINKNAME`, or an `explorer.exe` parent (`os/desktop.zig:58-59`).
- Skip the `SHELL` environment lookup on Windows, or accept only an existing
  Windows path. MSYS2, Git Bash and Cygwin export a POSIX `SHELL` that would
  otherwise become the command (`Config.zig:4826-4836`), overriding 2.5 too.

*Done when:* `cd C:\src && ghostty` opens in `C:\src`, and a double-click still
opens in `%USERPROFILE%` (regression check).

*As built:* `launchedFromDesktop` on Windows checks the shortcut flag and an
`explorer.exe` parent (Toolhelp; cached, since config finalization asks on
every load), and `SHELL` is skipped on Windows. The `launch-context` GUI
scenario covers a launch from a program (its directory), a shortcut launch
(home; simulated with `STARTF_TITLEISLINKNAME`, which is what a shortcut
sets) and a POSIX `SHELL`. The Explorer-parent path isn't covered: testing
it would mean launching through Explorer on the user's desktop.

**0.8 GUI test harness in the repository, M.** *Done 2026-10-24:
`test\windows\gui\run.cmd` builds a Debug Ghostty and the harness and runs
ten scenarios in about 40 s.* The message-posting harness that tested the
port so far lived in throwaway scripts; it is now a Zig program under
`test/windows/gui/`. Its capabilities:
- Spawn Ghostty with a temporary config.
- Find windows by class.
- Post keys with real modifier state (`AttachThreadInput`, `SetKeyboardState`).
- Capture with `PrintWindow(PW_RENDERFULLCONTENT)`.
- Assert tab counts, titles and pixel regions.
- Read state back through a Debug-only dump of windows, tabs, tab-bar
  geometry, grid sizes and visible text (`src/apprt/win32/test_hooks.zig`),
  requested with a registered window message. Text assertions then do not
  wait for 5.1's pipe.

How it differs from the plan, to keep rebases clean and the owner's screen
free:
- It has its own `build.zig`, so upstream's needs no new step.
- The state dump is switched on by `GHOSTTY_WIN32_TEST_DUMP` in Debug
  builds, not by a new `-D` build option.
- Ghostty runs on a hidden desktop, so test windows never cover the user's
  work or take keystrokes. DWM does not compose hidden desktops, so the
  pixel scenario runs its Ghostty on the user's desktop far off-screen,
  driven from a thread on that desktop, and terminates it rather than
  answering a dialog. The clipboard is shared across desktops, so clipboard
  scenarios save and restore the user's text.

Phase 1 tests depend on it; running it in CI comes later (7.3). *Done when:*
the README's tested list (tabs, close confirmations, clipboard, Ctrl+C) runs
as one command.

**0.9 Font style matching, S.** *Done 2026-10-24.* The default `freetype_windows` discovery
checks only family and codepoint (`font/discovery.zig:1157-1165`) and returns
the first file found. Bold Consolas resolves to `consola.ttf`, and italic
Cascadia to the upright face, for anyone who sets `font-family`. Score
candidates on weight, slant (FreeType style flags, OS/2 weight class) and
fixed width, from an index built once. Upstreamable; the DirectWrite backend
stays in 6.1. *Done when:* the log shows the Bold and Italic faces of Consolas
and Cascadia Mono for bold and italic text.

*As built:* family queries collect every matching face and sort them with a
score modeled on the CoreText backend's (monospace, exact style name,
italic, bold, fuzzy style name, glyph count; bold and italic from
FreeType's style flags, OS/2 and head). Codepoint fallback queries still
stream, since nearly every font matches. Discovered faces now report their
full name ("Consolas Bold") in the log, and name-table strings from the
Unicode platform decode as UTF-16 (the log read "C o n s o l a s"). Unit
tests check all four Consolas files and Cascadia Mono's italic file; the
`fonts` GUI scenario checks the log. Cascadia Mono has no separate bold
file: it is a variable font, so bold uses its upright file. Variable named
instances aren't enumerated as faces yet.

**0.10 Rebase hygiene, S.** *Done 2026-10-24. The regrouped history is the
branch `windows-port-regrouped` (seven area commits, same tree); replacing
`windows-port` with it is the owner's call.*
- Move the port README to `.github/README.md`. GitHub shows it in preference
  to the root file, so the root `README.md` returns to upstream's text and
  stops conflicting on every upstream README edit.
- Regroup history into area commits (build, core fixes, renderer, runtime,
  builder, docs) and enable `rerere`.
- Rebase per upstream tag on a `rebase/<date>` branch, tagging the previous
  tip for rollback. This is an ongoing practice from here on, not a one-off.
  *Superseded 2026-10-26 by the fork decision:* upstream is merged, not
  rebased onto (see "The fork").

**0.11 Minimal CI, M.** *Done 2026-10-24.* One port-owned workflow, started manually: the Windows
build, the Windows unit tests, and the builder under PowerShell 5.1. Before
enabling Actions, disable every upstream workflow: the vouch workflows have no
repository guard and act on every issue. A guard step fails if any other
workflow is active. Phase 7 extends it (7.2).

*As built:* `.github/workflows/windows-port.yml`, started with
`gh workflow run windows-port.yml --ref windows-port` or from the Actions
tab. A guard job, then a `windows-latest` job that runs `build-windows.cmd`
(Windows PowerShell 5.1 on a runner without Zig: download, SHA-256 check,
ReleaseFast build) and the full unit suite, about 4,100 tests, with the Zig
the builder installed. A run from cold takes about 57 minutes (builder 29,
unit tests 27), about 115 billed minutes of the free plan's 2,000 a month
since Windows minutes count double. Three upstream tests failed on Windows and were fixed: one
compared two `@tagName` strings by pointer, two skipped on `AccessDenied`
where Zig 0.17 reports a missing symlink privilege as `PermissionDenied`.
Two of the port's own tests assumed a Windows 11 desktop and failed on the
runner's Windows Server 2025: there `.pyw` is registered without a command
(Python installed without its launcher, so it opens in Notepad) and Cascadia
Mono has no italic file. They now check `.reg`, `.msc` and `.chm`, which
Windows registers to code runners, and the italic match only where an italic
file exists.

Disabling first turned out to be impossible: GitHub registers a workflow
only when one of its own events fires, and only a registered workflow can be
disabled. So Actions was enabled with the policy "GitHub-owned actions only",
which stops every upstream workflow at startup since each uses a third-party
action. The first push registered `test.yml` and `nix.yml` (push-triggered);
their runs ended in `startup_failure` with no jobs and nothing billed, and
both are now disabled. The other 13 register on their own events (an issue,
a tag, a cron) and are disabled as they appear. Their jobs also target
upstream's `namespace-profile-*` runners, which don't exist here. The guard
fails while any registered workflow other than the port's is active and
lists the unregistered ones as notices. Before pushing a rebase, list the
workflows it adds: one that is push-triggered and uses only GitHub-owned
actions on a GitHub-hosted runner would get past the policy.

**0.12 Modified keys through ConPTY (win32-input-mode), M.** *Added
2026-10-24, found during 0.2; not yet scheduled.* ConPTY turns the VT bytes it
receives back into console key events, and it can't represent the sequences
Ghostty sends for many modified keys: `CSI u` (`Ctrl+Shift+<letter>`) and
xterm's `CSI 27;m;k~` (`Shift+Enter`, `Ctrl+Shift+Enter`, modified Escape and
the like). They are dropped, so console programs never see them. Observed
with PowerShell `[Console]::ReadKey`: `Shift+Enter` and `Ctrl+Shift+P` never
arrive; plain keys do. That breaks `Shift+Enter` for a new line in PSReadLine
and in CLIs that use it. ConPTY asks for win32-input-mode at startup (DECSET
9001, logged as unimplemented), the mode Windows Terminal speaks: every key
down and up as `CSI Vk;Sc;Uc;Kd;Cs;Rc _`, which ConPTY replays as the exact
console input record.
- Track mode 9001 in the core's terminal modes.
- When it is set, encode key events (releases too) in that form. The core's
  `KeyEvent` has no virtual-key or scan code, so the runtime has to supply
  them (or the core maps its physical key back); decide which before
  starting.

*Done when:* `Shift+Enter`, `Ctrl+Shift+P` and `Ctrl+Shift+Enter` reach
`[Console]::ReadKey` with their modifiers, and a GUI scenario checks it.

*Done 2026-10-26, brought forward by the owner's report:* PowerShell text
highlighted with Shift+arrows (PSReadLine's own selection, not murrtty's)
couldn't be copied with Ctrl+Shift+C, PSReadLine's Copy. With no selection
of murrtty's the performable copy binding passes the key on, and ConPTY
dropped its `CSI u`. As built, keeping the core's binding and selection
logic and changing only the bytes a key becomes:
- The mode lives in `Terminal.flags.win32_input_mode`, set by a new stream
  action from `CSI ? 9001 h`/`l`, rather than in the mode table, whose
  packed layout is a snapshot format; like `defer_prompt_mark` it describes
  the pty and survives a full reset.
- `KeyEvent.win32` (optional) carries the Windows message: virtual key,
  scan code, the WM_CHAR code unit, dwControlKeyState and the repeat count.
  The Win32 runtime fills it (`key.controlKeyState`), except for dead keys
  and keys that made more than one code unit, which go as text.
- With the mode on, `key_encode` writes the event as `CSI Vk;Sc;Uc;Kd;Cs;Rc
  _`, ahead of the Kitty protocol (which ConPTY can't read), releases and
  modifiers included. The core no longer clears the selection, scrolls or
  closes an exited pane on a release, nor closes it on a modifier.
Bindings still come first: `Ctrl+Shift+P` (the palette) and
`Ctrl+Shift+Enter` (split zoom) are murrtty's own by default, so the
scenarios use `Ctrl+Shift+C`, which reaches the program when nothing is
selected. Scenario `console-keys` runs a script printing what
`[Console]::ReadKey` reads (a, Shift+Left, Ctrl+C, Ctrl+Shift+C,
Shift+Enter, all with their modifiers and characters); `pwsh-keys` copies
PSReadLine's highlight with Ctrl+Shift+C and Ctrl+C and adds a line with
Shift+Enter. The harness now posts a key's release only after murrtty has
handled its press, as a keyboard delivers them: posted together, the press
was handled before Windows queued its WM_CHAR.

**0.13 Self-hosted runner on the development desktop, M.** *Planned
2026-10-24 (decision 6), at the break before Phase 1.* A GitHub Actions runner
on the owner's desktop runs a Debug build, the unit tests and the GUI suite on
every push to `windows-port`. The hosted `windows-port.yml` stays as the
manual clean-machine builder test. Facts the design rests on:
- *Cost.* GitHub announced a $0.002/minute charge for self-hosted runners on
  private repositories, then postponed it; as of October 2026 self-hosted
  minutes are free and no new date is set. The owner accepts the charge if
  it comes.
- *The GUI suite needs a signed-in session.* A runner installed as a Windows
  service lives in session 0, where OpenGL falls back to Microsoft's software
  1.1 renderer ("GDI Generic"); Ghostty needs 4.3. So the runner runs in the
  foreground of a signed-in session, started at logon by a scheduled task,
  not as a service.
- *The suite works in a signed-in session today:* that is how it runs from
  development sessions, on hidden desktops. Two things still reach the
  session: the clipboard scenarios save, use and restore its clipboard, and
  `links-open` briefly registers a protocol and file type in its HKCU. The
  `pixels` scenario adds a taskbar button for a moment.
- *Trust.* The runner executes whatever workflow code is pushed. Only the
  owner (and development sessions with the owner's credentials) push, so it
  runs code that would run locally anyway. Third-party actions are blocked by
  the repository policy, the workflow triggers only on pushes to
  `windows-port` (Dependabot pushes `dependabot/*` branches, which carry
  edited workflow files), never on pull requests, and the runner must never
  serve a public repository.

Which account the runner uses is the main decision:
- **A, the owner's account, in the owner's session.** Proven (it is how the
  suite runs now) and simplest. The jobs run with the owner's rights (not
  elevated) and only while the owner is signed in; the clipboard and HKCU
  effects above land in the owner's session. *Recommended to start.*
- **B, a dedicated standard account in a second signed-in session** (fast
  user switching, left signed in). Isolates files, clipboard and HKCU. Open:
  whether the NVIDIA OpenGL driver serves a session that isn't the active
  console one, so it starts with that experiment; and after every reboot
  someone has to sign that account in again.
- **C, both:** build and unit tests on a service runner under a dedicated
  account (always on, isolated), the GUI suite on a runner in a signed-in
  session (label `gui`). Twice the setup.

Steps:
1. *Harness.* A session-wide mutex so two GUI suites never overlap (a CI run
   and a development run would fight over the clipboard and the HKCU
   registrations); a way to skip scenarios (`--skip pixels`, so pushes don't
   flash a taskbar button); a results folder the workflow can upload.
2. *Install.* The runner from `actions/runner` releases, checksum verified,
   in `C:\actions-runner`, registered to this repository with a one-time
   token and the labels `self-hosted, windows, x64, gpu`; a scheduled task
   starts it hidden at logon. Auto-update stays on (GitHub refuses runners
   that fall behind).
3. *Workflow* `windows-port-desktop.yml`: on pushes to `windows-port` (not
   for Markdown-only changes) and by hand; `runs-on: [self-hosted, windows,
   gpu]`; one run at a time, a newer push cancels the older run. Below-normal
   priority so builds yield to the owner's work. The Zig caches live outside
   the checkout, so checkout's clean doesn't wipe them and builds stay
   incremental; the builder's Zig stays installed. Steps: Debug build, unit
   tests, GUI suite without `pixels`; on failure, upload the scenario folders
   and logs (7-day retention: artifact storage on the free plan is 500 MB).
   The hosted workflow's guard learns to allow `windows-port*.yml`.
4. *Upkeep.* Clear the local cache when it passes about 20 GB (it reached 14
   GB in a day of development); note the runner in the project's CLAUDE.md
   with how to stop, start and remove it.

*Done when:* a push to `windows-port` runs the build, unit tests and GUI suite
on the desktop runner and passes; an injected failure in a scenario turns it
red with the scenario's logs attached; and the owner sees nothing on screen
while it runs. Owner decisions besides the account: whether the desktop
stays awake for runs (queued jobs wait up to 24 hours), whether to exclude
the runner's folders from Defender scanning (faster builds, less scanning),
and whether green runs also publish a ReleaseFast `ghostty.exe` (as an
artifact, or installed into the project's `build\`). This also changes 7.3:
the GUI suite runs on this runner, and Mesa llvmpipe on hosted runners
becomes optional.

*Decided 2026-10-24:* account A; green runs on `windows-port` install the
ReleaseFast build into the project's `build\` (skipped while that Ghostty
runs); the runner's folders are excluded from Defender scanning.
*Changed 2026-10-26 (owner's choice):* the install comes after the GUI
suite and before the unit tests, so a build is in `build\` about 9 minutes
after a push instead of 20; the unit tests still decide the run's status.
It no longer waits for a closed murrtty: the running exe is renamed to
`murrtty.prev.exe` (Windows allows that, not overwriting), which is also
the copy to roll back to.

*Done 2026-10-24. As built:* runner 2.338.1 (checksum verified) in
`C:\actions-runner`, registered as `surrey-desktop`, started at logon by the
scheduled task `ghostty-windows actions runner` in a headless console (no
window) at task priority 7, so jobs run below normal. The workflow is
`windows-port-desktop.yml`; the release prefix comes from the runner's
`.env` (`GHOSTTY_INSTALL_PREFIX`), so no machine path is in the repository.
The harness gained `--skip`, the session mutex `Local\GhosttyGuiTest` and
`GHOSTTY_GUI_TEST_DIR`. The first run passed in 25 minutes (unit tests 17,
GUI suite 2.5 with 17 of 17 scenarios, release install 4.3); an injected
`launch` failure turned the next run red ("16 of 17 passed") with every
scenario's config, dump and log in the uploaded artifact, and skipped the
install. Most of the unit-test step is the suite running, not compiling:
the full suite takes about 10 minutes on this machine. Every commit
recompiles the Zig test module anyway, since the version string carries
the commit.

**0.14 Typing latency, S.** *Found and fixed 2026-10-24.* The owner reported
typed text trailing the keys: fine when typing slowly, falling behind and
catching up in bursts when typing fast. A throwaway trace (local branch
`perf-trace`, see the project notes) stamped each stage on the
QueryPerformanceCounter clock: key received, pty write and read, parse,
frame update, draw and present. Two causes:
- *Output never woke the renderer.* Termio kept a copy of the renderer
  thread's `xev.Async` taken before that thread waited on it, and with
  libxev's IOCP backend a copy made then never fires. Frames came only from
  key presses, the cursor blink, resizes and focus, so an echo was drawn
  with the next key, or up to 600 ms later with the blink (one key in the
  owner's trace: parsed 10 ms after its key's frame, drawn 594 ms later).
  Termio now holds a pointer to the thread's handle. The GUI scenario
  `output-frames` checks that output with no key pressed is drawn (frame
  count 4 to 4 without the fix, 9 to 11 with it).
- *`glFinish` after every presented frame.* Upstream finishes so that an
  exported frame is complete before another thread uses it; a frame
  presented with `SwapBuffers` has no other user. It cost about 2 ms of
  each 3.3 ms frame, and one frame stalled 208 ms.

After both, on the owner's desktop: key to drawn echo 1.5 ms on average
(2.7 before), no key over 50 ms (606 ms before; the slower ones wait on
ConPTY's own echo, 10 to 20 ms at times), average frame 1.4 ms (3.3).
Open: the terminal-core unit tests are very slow on Windows (10 to 34 s
each for some `Terminal`, `Screen` and search tests, 10 minutes for the
suite), likely the Debug testing allocator; that is CI time, not app
speed, and is worth a look before 7.2.

**0.15 Thread stack commit, S.** *Found 2026-10-24 in S4; not yet
scheduled.* Every pane (and so every tab) starts four threads: the renderer,
termio's IO thread, the pty reader and one more. Zig 0.17's `std.Thread` on
Windows passes its stack size, 16 MB by default, to `NtCreateThreadEx` as the
stack's commit size rather than a reservation, so each thread commits 16 MB
up front: 64 MB of the 90 MB each pane adds to the commit charge, though only
31 MB of a pane is resident. Many panes or tabs on a machine with a small
page file can hit the commit limit. Pass a smaller `stack_size` for the
per-surface threads on Windows (measure the deepest stacks first: shaping,
parsing, image decoding), or fix the reservation in Zig. *Done when:* a
pane adds under 40 MB of commit.

---

## Phase 1: Splits (about 2.5 weeks, plus 1.10 in M2)

The full design is below; the steps land one at a time. Steps 1.1 to 1.9 are
done (2026-10-25); 1.10 is part of M2. Upstream's generic
split tree (`src/datastruct/split_tree.zig`) already compiles for Windows and
provides every operation (split, remove, equalize, resize, in-place ratio
drag, zoom, wrapped and spatial navigation), so the work is in the Win32
runtime plus the WGL present path (1.7).

### Design

- **A tab becomes a split tree.** New `win32/Tab.zig` owns a
  `SplitTree(Surface)`, the tab's focused pane and a generation counter.
  `Window.surfaces` becomes a list of tabs.
  - `Surface.ref`/`unref` are no-ops, so the tree is only a layout index.
    Panes are freed solely by the close queue, which keeps the "close only
    from the message loop" rule.
  - Real reference counting would free a surface wherever the last tree
    reference dropped, including inside `performAction`.
- **One container window per tab.** A `GhosttyTab` child window parents that
  tab's pane windows, paints the dividers, and owns divider hit-testing and
  drags. Switching tabs is one `ShowWindow`.
- **Pure, tested layout.** `win32/split_layout.zig` maps tree, rectangle and
  DPI to integer pane and divider rectangles that tile the area exactly. It
  honors each pane's core `size_limit` (10x4 cells), with a 1 px floor. It is
  unit-tested on a `SplitTree` of a small test view defined in the module
  (upstream's `TestView` is private), with no windows, and applied with
  `DeferWindowPos`.
- **Dividers.**
  - A 1 DIP line in `split-divider-color`, defaulting to macOS's rule: the
    background darkened 0.4 on dark themes, 0.08 on light ones. (Since 4.3
    step 5, GTK's: the window's background.)
  - The grip band is kept inside the panes' padding. Otherwise it steals
    column-1 clicks, as GTK once did (Ghostty #3020).
  - Drags update `resizeInPlace` live; Esc restores the ratio, and a
    double-click equalizes (macOS parity).
  - The generation counter cancels a drag if a pane closes mid-drag.
- **Focus.**
  - The core focus callback is deferred through a posted message, as GTK does
    with an idle callback. Otherwise `SetFocus` inside `goto_split` re-enters
    the calling pane's key handling.
  - `SetFocus` runs only in the active window, so background windows are never
    activated.
  - Closing the focused pane focuses its previous neighbor, else the next.
    Closing a background pane leaves focus alone (macOS rule; GTK steals focus).
- **Actions.**
  - `new_split`: the pane is created at its final rectangle.
  - `goto_split`: wrapped previous/next and spatial directions. It returns
    false when nothing moves, so the performable key reaches the program.
  - `resize_split`: the amount is scaled by DPI and the delta clamped to
    [-1, 1], because upstream's resize asserts on larger deltas and GTK does
    not clamp. It unzooms, and returns false when nothing changed.
  - `equalize_splits` and `toggle_split_zoom`: zoom hides and occludes the
    other panes and shows a magnifier on the tab.
  - `present_terminal` unzooms.
  - `resize_window` (CSI 8 t) is refused in split or multi-tab windows and
    when maximized or fullscreen, and clamped to the monitor, as on GTK and as
    `vt-window-resize-allowed` documents.
- **Unfocused-pane dimming.** A rectangle in 0.3's present pass, with sRGB
  writes off so it blends like GTK's CSS. Color `unfocused-split-fill`, alpha
  `1 - unfocused-split-opacity`. It keys on the tab's focused pane, passed to
  the render thread as a per-pane flag, so the last focused pane stays bright
  when the window is inactive (macOS rule). The core's own focus state cannot
  do this: it goes false whenever the window is inactive.

### Steps

| Step | Content | Effort |
|---|---|---|
| 1.1 | Focus plumbing: deferred core focus callback; `SetFocus` only in the active window. Fixes focus theft by closing a tab in a background window. *Done 2026-10-24:* surfaces tell the core from a posted `WM_FOCUS_CHANGED` (coalesced, and repeated once the core surface exists); `present_terminal`, activation and the window's own focus still focus unconditionally. The `background-close` scenario failed before (the background window became active) and passes now. | S |
| 1.2 | Tab refactor: `Tab.zig` with a one-leaf tree and a container window; every surface iteration site switches to tabs. No visible change; the full tab test set passes. *Done 2026-10-24:* `Window.tabs`, `Window.panes()` for every pane, `closeSurface` (closes the pane's tab until 1.4) and `removeTab`; the dump still lists each tab as its focused pane. All 19 GUI scenarios pass unchanged. | M |
| 1.3 | `split_layout.zig` with unit tests: tiling, minimums, zoom, hit-testing, drag ratios, resize deltas, focus after close. *Done 2026-10-24:* `Layout(View)` over any split tree whose view has `layoutMin()`; 9 unit tests, including exact tiling at several sizes and divider widths, drags landing within a pixel, and `SplitTree.resize` moving a divider by the requested pixels (its delta is a fraction of the whole tree, not of the split). | M |
| 1.4 | Basic splits: `new_split`, closing panes through the queue (confirm per pane, last pane closes the tab), divider painting, titles from the focused pane, per-pane `size_limit`, `resize_window` refusals and monitor clamping (the multi-tab, maximized and fullscreen refusals fix a current bug and can land early). Removes 0.2's override for `Ctrl+Shift+O`/`E`. Includes the S4 stress run. *Done 2026-10-24:* a new pane is created at the rectangle a trial layout gives it; closing the focused pane focuses the one before it, else after it; a background pane's close leaves the focus alone. The dump lists each tab's panes (layout order, real window rectangles) and dividers; the `splits` scenario checks exact tiling, focus (window, keyboard and core) and both close rules; S4 in `stress-panes`. `resize_window` can't be reached through ConPTY, so its refusals are untested. | M |
| 1.5 | Navigation and commands: `goto_split`, zoom, equalize, `resize_split`, `split-preserve-zoom`, `present_terminal`. Removes 0.2's override for `Ctrl+Shift+Enter`. *Done 2026-10-25:* panes behind a zoom are hidden and occluded but keep their unzoomed size (laying them out empty shrank their terminals to one cell and reflowed their text, which the scenario caught); `resize_split` returns false when no pane moves. The `split-commands` scenario checks wrapping and spatial navigation, that a hidden pane's output still arrives while it draws nothing and keeps its grid, the zoom ending on navigation, resize by the requested points and equalize. | S to M |
| 1.6 | Mouse: divider hover cursors, drag, Esc, double-click equalize, window minimum from the tree. *Done 2026-10-25:* a pane answers `WM_NCHITTEST` with `HTTRANSPARENT` in its margin on a side that borders a divider (the padding before the first cell or what the grid leaves after the last, never a cell), so the container gets the mouse there and on the line; Esc reaches the drag through the focused pane, since a drag never moves the focus; the window's minimum is the largest of its tabs' tree minimums. The `split-mouse` scenario checks a drag landing on the pixel, Esc, double-click and the grip band's hit-testing. | M |
| 1.7 | Renderer: a rectangle list drawn in 0.3's present pass, written by the UI thread and read by the render thread. The dim overlay is its first user; 3.0's shape overlays reuse it. *Done 2026-10-25:* `OpenGL.setOverlay` (up to 16 rectangles, under a mutex) and a solid-color pass after the frame, premultiplied, with sRGB writes off; a pane that changes its dimming forces a frame (as the tests' probe does). `Tab.syncDim` runs whenever the focused pane, the panes, the colors or the config change. The `split-dim` scenario reads back a dimmed pane's background (half red over `#282c34`, within one step) and the focused pane's, before and after a click moves the focus. | M |
| 1.8 | `focus-follows-mouse`, deduplicated on screen position so a relayout under a still cursor does not move focus. *Done 2026-10-25:* a pane's `WM_MOUSEMOVE` maps its own client point to the screen and compares it with the last one seen over any pane (not `GetCursorPos`, so posted test moves count as moves); it focuses the pane only in the active window and with no button held. The `focus-follows-mouse` scenario checks moves focusing each pane, a divider moving the pane under a still cursor (no focus change), and a pane of an inactive window (neither focused nor activated). | S |
| 1.9 | Defaults and docs: check whether the Windows shell or graphics-driver hotkeys intercept the defaults (`ctrl+super+[`, `super+ctrl+shift+arrows`, and `ctrl+alt+arrows`, which some Intel drivers use for screen rotation) and add fallbacks if so; record decision 2; update the README. *Done 2026-10-25:* checked with `RegisterHotKey` on the Windows 11 desktop, which fails for a combination another program holds (Explorer's `Win+E` as the control): `Win+Ctrl+[` and `]` are held (alongside Explorer's `Win+Ctrl` digits, `C`, `D`, `O`, `V`), so Windows gets `Ctrl+Shift+[`/`]` for `goto_split:previous`/`next` (kitty's keys) in addition to upstream's, performable as those are. `Win+Ctrl+Shift+arrows`, `Ctrl+Alt+arrows` and Ghostty's other split keys are free there. Intel's rotation hotkeys could not be checked (no Intel GPU); the README says how to turn them off. A probe only sees hotkeys registered with `RegisterHotKey`, not keyboard hooks, and no real key presses were sent (they would reach the owner's foreground window). | S |
| 1.10 | In M2: drag panes between drop zones and between tabs, with the per-pane handle from `drag-handle` (default `auto`: shown when the tab is split, as on GTK; macOS shows it on hover instead). M1 ships without it. | L |

New-split working-directory inheritance needs 2.1 plus a source of reports:
the 2.2 or 2.3 integration, or the 2.4 fallback. Stock PowerShell and cmd send
none. Until Phase 2 lands, new splits open in the focused pane's starting
directory; the README says so. The core already selects
`split-inherit-working-directory` for split surfaces.

*Done when:*
- `Ctrl+Shift+O`/`E` create panes with the computed rectangles.
- `Ctrl+Alt+arrows` move focus as the unit tests predict.
- Zoom hides the other panes and stops their rendering.
- Divider drags move by the dragged distance, within f16 ratio precision.
- `exit` in a background pane leaves focus where it was.
- Unfocused panes sample at the configured dim color.
- 16 flooding panes render steadily on two GPU vendors.

---

## Phase 2: Shell integration and working directory (about 2.5 weeks)

Without prompt marks, Ghostty cannot tell an idle prompt from a running
program. Every close of an idle PowerShell tab asks for confirmation today.
With splits, closing panes one at a time (a user-bound `close_surface`, or
the Close Split menu item) asks once per pane. Without directory reports, new
tabs and splits open in the wrong directory. This phase pairs with Phase 1.

**2.1 Windows `reportPwd` in the core, S to M.** The core discards OSC 7 and
OSC 9;9 working-directory reports on Windows (`stream_handler.zig:1532-1535`),
so no `*-inherit-working-directory` option works. Accept:
- OSC 7 `file://host/C:/path`: percent-decode, keep the drive letter, use
  backslashes.
- OSC 9;9 raw paths, optionally quoted (Windows Terminal's form).

Check the host case-insensitively against the DNS and NetBIOS computer names;
`os/hostname.zig` `isLocal` compares bytes exactly against `GetComputerNameA`
and needs fixing. Written to be upstreamable. *Done when:* unit tests cover
the path conversion, and a new tab opens where the shell last reported.
*Done 2026-10-25:* `os/cwd_report.zig` turns OSC 7's `/C:/dir` and the raw
(optionally quoted) paths of OSC 9;9 and iTerm2's `CurrentDir` into drive
paths, taking only `X:\...` (no UNC or device paths, nothing a directory name
can't contain), by spelling alone. `isLocal` compares without case against
the NetBIOS, DNS and fully qualified names (`hostname`'s tests weren't in the
test build; they are now). Relative link text resolves against the pwd by
spelling (`resolveWindows`, no file system), and `url.zig` vets the result
and takes this computer's name as a `file://` host. The `pwd` scenario covers
OSC 9;9 from cmd's prompt, OSC 7 with the lower-case name, a new tab starting
there, another computer's report and a UNC path ignored, and a relative link
opening; the dump reports each pane's pwd.

Two link follow-ups from 0.1 depend on this:
- Re-enable relative link text. `resolvePathForOpening` returns null on
  Windows while the pwd is stuck at the starting directory, so Ctrl+click on
  `src/main.zig` is blocked as a relative path. Resolve it against the
  reported pwd without touching the file system, and let `url.zig` vet it.
- Accept the local computer name as a `file://` host in `url.zig`. `ls
  --hyperlink` and ripgrep emit `file://HOSTNAME/...`, which is blocked as
  remote today.

**2.2 PowerShell integration, L.**
- New `src/shell-integration/powershell/ghostty.ps1`, compatible with Windows
  PowerShell 5.1 and pwsh 7:
  - Wrap `prompt` to emit OSC 133 D (exit status), OSC 7, the optional title
    and cursor shape, then 133 A, the user's prompt and 133 B.
  - Wrap `PSConsoleHostReadLine` to emit 133 C after Enter (the technique VS
    Code's integration uses).
- Detection and injection in `termio/shell_integration.zig` and
  `termio/Exec.zig`:
  - Detect `pwsh.exe` and `powershell.exe`, stripping `.exe`. This also fixes
    detection of Git Bash `bash.exe` and `zsh.exe`.
  - Inject with `-NoExit -Command ". '<resources>\...\ghostty.ps1'"` unless
    the arguments already have `-Command`/`-c`, `-File`/`-f`,
    `-EncodedCommand`/`-e`/`-ec` or `-NonInteractive`. Match pwsh's
    case-insensitive prefix abbreviations.
- Spike S3 decides whether to bundle `OpenConsole`.

*Done when:*
- In pwsh 7 and 5.1 an idle tab closes without asking, and asks during
  `Start-Sleep 30`.
- `jump_to_prompt` moves between prompts.
- After `cd C:\Windows`, a new tab opens there.

*Done 2026-10-25:* the script ends the prompt with 133;I, not B (S3's
repaint finding), reports the status as 0, the native exit code when a
program changed it, else 1, and gives the user's prompt the last command's
`$?` and `$LASTEXITCODE`. It sends OSC 7 only for drive paths of the
FileSystem provider. Ghostty loads it with `-NoExit -Command` and a script
block made from the file's text, so the default `Restricted` execution policy
doesn't stop it, and passes the arguments as a list (a Windows command
string splits on spaces, quotes ignored). It injects only when every argument
is a start-up flag it knows, rather than refusing a list of known command
forms, so anything unknown runs as given. `bash.exe` stays undetected: on
PATH it is usually WSL's launcher in System32, where bash's `--posix`
injection would skip the user's bashrc; Git Bash users can source the script
themselves. The `pwsh-integration` scenario runs every *Done when* item in
both PowerShells, plus the title following `cd` and the running command, and
an idle Ctrl+Shift+Q quitting without a dialog. S3 found no reason to bundle
`OpenConsole` on Windows 11.

*Mid-phase review 2026-10-25* (2.1 and 2.2; five reviewers and a skeptic
per finding, 20 of 23 findings confirmed), fixed:
- **Prompt marks:** prompts start with 133;P;k=i, not A. A's fresh-line
  moved Ghostty's cursor without ConPTY's after a prompt written with
  Write-Host (a venv's) or output without a final newline, so later repaints
  landed a row off. The PowerShell prompt mark now goes out before the
  user's prompt runs, so Write-Host text is inside it. cmd and Clink use P
  too.
- **PowerShell script:**
  - runs with strict mode off: the profile's `Set-StrictMode` had aborted
    it silently
  - wraps a prompt or PSReadLine set after it loaded when loaded again
  - reports a repeated native exit code and a failure under another prompt
    wrapper (by `$Error[0]`)
  - caps and guards the title (over 1023 characters it threw, and with
    `$ErrorActionPreference = 'Stop'` lost the command)
  - sends an empty OSC 7 where the location isn't a drive path
  - matches `~` at a path boundary only
  - sets the bar cursor only when its PSReadLine hook can restore it
  - names the host `localhost` when `COMPUTERNAME` isn't a DNS label
- **Host names:** Ghostty also accepts such a name in OSC 7 when it is this
  computer's.
- **Load command:** doubles the typographic single quotes (U+2018 to
  U+201B), which PowerShell also ends strings at.
- **Reported directories:**
  - reject DOS device names, names over 255 UTF-16 units and `.`/`..`; std's
    access panicked in Debug builds on the first two when a new tab inherited
    them
  - a local report that isn't usable makes the pwd unknown rather than
    leaving it stale
  - Exec checks a Windows cwd with `GetFileAttributesW` and drops one at
    MAX_PATH or longer, which CreateProcessW refuses
- **Relative links:** resolve only against a directory a shell reported, not
  the starting one.
- **GUI tests:** they wait on an end marker rather than a fixed sleep, and
  the link check uses a folder that is neither Ghostty's nor the start.

**2.3 cmd integration, M.**
- Set `PROMPT` in the child environment to wrap the user's prompt with OSC 133
  A/B/D and OSC 9;9. cmd has no pre-execution hook, so there is no 133 C or
  exit code.
- With Clink present, ship a Lua prompt filter that adds 133 C and the exit
  code.

*Done when:* an idle cmd tab closes without asking, and `cd /d D:\x` carries
over to new tabs.

*Done 2026-10-25:* `cmd` is detected like PowerShell (any case, with or
without `.exe`), and `PROMPT` becomes `$E]133;D$E\`, the title (`$E]2;$P$E\`,
title feature), `$E]9;9;$P$E\`, `$E]133;P;k=i$E\`, the user's prompt (`$P$G`
when unset) and `$E]133;I$E\`: P and I, not A and B, for S3's reasons, and
because with no 133;C, I lets the line feed after Enter end the input. A `PROMPT` already
sending OSC 133 is kept. `CLINK_PATH` gains `shell-integration\cmd`, whose
`ghostty.lua` (Clink 1.4.25 or later) strips those codes from cmd's prompt
and sends them around Clink's final prompt through a prompt filter's
`surround()`, with the exit status in D (`os.geterrorlevel()`), and 133;C
from `onendedit`. Clink's own integration (`terminal.shell_integration`)
turns on by itself only in terminals it recognizes, so it stays off here; Exec
now drops `WT_SESSION` and `WT_PROFILE_ID`, which Clink and others read as
running in Windows Terminal. The Debug dump counts finished commands and
keeps the last exit code (from `command_finished`), which `pwsh-integration`
now checks (3 from `cmd /c exit 3`, 1 from a failing cmdlet, then 0). The
`cmd-integration` scenario runs the *Done when* items, the title, a running
`ping` asking, and `jump_to_prompt`, with cmd's default prompt and with
`PROMPT=[$P]$G`; its Clink part runs when `GHOSTTY_GUI_CLINK` names a Clink
folder (the profile goes in the scenario's folder). The owner ran it with
Clink 1.9.34 on 2026-10-25: the folder, title, exit statuses and idle close
passed at once. The prompt jumps failed until prompt marks were deferred to
the prompt text's row (S3) and the test profile turned Clink's updater off
(a new profile's first prompt checks GitHub, and once stopped taking
input).

**2.4 Directory fallback without integration, M.** For shells that send
nothing, read the shell process's current directory from its PEB
(`NtQueryInformationProcess`, `ReadProcessMemory` of
`RTL_USER_PROCESS_PARAMETERS.CurrentDirectory`), used only until the first
OSC 7 or 9;9. It works for cmd's `cd`, not for PowerShell's `Set-Location`.
Also handle the `pwd` action to keep a per-surface copy (tooltips, Open in
File Explorer, session restore). *Done when:* with `shell-integration = none`,
cmd's `cd` carries over.

*Done 2026-10-25:* `os/process_cwd.zig` reads `CurrentDirectory.DosPath`
from the process's PEB (`NtQueryInformationProcess`, `NtReadVirtualMemory`),
reading the string's header again after its text in case the shell moved
meanwhile. It skips WOW64 processes, whose directory is in their own PEB,
and takes the result as `cwd_report` takes a report. Exec keeps its own
handle to the shell, duplicated with only the rights that needs and held in
an atomic for the app thread, and only when the shell is cmd. PowerShell's
`Set-Location` and WSL leave their process's directory where they started,
so reading it would name the wrong folder, the very thing the mid-phase
review had relative links stop doing. Until the shell reports, the new
terminal's directory and relative links come from it, and afterwards too
once cmd has moved from where it was at the last report (its reports
stopped, or a program it ran that reported has exited). The `pwd` action
isn't kept per surface: the runtime asks the core's `pwd()` when it needs
it, which includes this fallback, and a copy would miss changes no report
announces. The `cwd-fallback` scenario covers cmd without integration (cd
into a folder with a space, a new tab starting there, a relative link
opening) and Windows PowerShell without it (a new tab starts where the first
did, and a relative link is blocked). Known limit: a program cmd runs that
changes its own directory (a nested PowerShell) still has its relative links
resolved against cmd's.

**2.5 Default shell, S.** When `command` is unset, prefer `pwsh.exe`, found
via `SearchPathW`, App Paths or the Store alias, else `%COMSPEC%` (decision
3). *Done when:* a fresh config opens `pwsh -NoLogo` when PowerShell 7 is
installed.

*Done 2026-10-25:* `os/default_shell.zig` looks for `pwsh.exe` on `PATH`
(fixed drives only, by `GetDriveTypeW`, with the system's error boxes off:
a relative entry would search wherever Ghostty started, a network one, a
mapped drive included, could stall startup, and an empty card reader could
ask for a disk), then the Store's alias in
`%LOCALAPPDATA%\Microsoft\WindowsApps`, then `%ProgramFiles%\PowerShell\7`.
The default command is then `pwsh.exe -NoLogo` as an argument list (the
path may hold spaces), else `%COMSPEC%`. `SearchPathW` wasn't used because it
searches the current directory too. App Paths wasn't used because a Store
install's entry names the package's own `pwsh.exe` under
`Program Files\WindowsApps`, which can't be started directly. The
`launch-context` scenario, which runs with no config, checks a `PS` prompt
without the banner and `$PSVersionTable.PSVersion.Major` of 7.

*End-of-phase review 2026-10-25* (2.3 to 2.5 and the mid-phase fixes; five
reviewers and a skeptic per finding, 22 of 25 findings confirmed), fixed:
- **PowerShell wrappers:**
  - Each load that wraps something is now a generation whose wrappers call
    their own originals, and one called from inside another passes the call
    on. A shared original had made a venv's or conda's chaining prompt, or a
    chaining line-editor wrapper, recurse until the call depth overflowed.
  - The line-editor wrapper calls its original first, so PSReadLine and its
    predictors see the command's own `$?`.
  - The status trusts `$?` when the host called the prompt itself, so a
    handled error is no failure, and tells a native program ran by a new
    `LASTEXITCODE` value, so a repeated code is reported and a stale one
    isn't.
- **Clink script:**
  - It puts `$P` in its prefix, since Clink expands `$` codes there: a
    folder named with a `$` was misreported, and a crafted name could inject
    escape sequences.
  - It needs Clink 1.4.25; older Clink takes any OSC 133 for a title, so for
    it the script only removes the codes.
  - Only a prompt's last line is marked under Clink (documented).
- **Directories:**
  - For cmd, cmd's own directory wins once cmd has moved since the last
    report.
  - Device names are no longer rejected as spellings (Windows 11 allows
    folders named `aux` or `COM0`), since Exec checks the directory.
  - Exec measures the full path as CreateProcessW does (at most MAX_PATH - 2,
    trailing backslash or not).
- **Default shell:** `findPwsh` searches fixed drives only, with error boxes
  off.
- **`direct:` commands:** on Windows they quote arguments with spaces in
  `+show-config` and read quotes back, so the default command round-trips.
- **Tests:**
  - The relative-link checks now fail if the order of reported directory and
    cmd's own changes, or if the cmd-only gate is lost.
  - `cwd-fallback` uses a folder with a space.
  - `launch-context` checks `-NoLogo` without the integration.
  - The Clink run takes its folder through `PATH`.
  - `findPwsh`'s test has relative entries that reach a `pwsh.exe`.

Not changed: the current-directory search that `CreateProcessW` makes for a
command given by bare name (`command = pwsh`, or upstream's old default
`cmd.exe`) could run a planted program from the folder Ghostty started in;
the defaults now name full paths, and a user's bare name keeps Windows'
behavior.

---

## Phase 3: Core Ghostty UI (about 6 to 7 weeks)

The overlays and menus users meet every day. Notes marked *GTK, observed*
come from running upstream's GTK app (`main` of 2026-10-14) under WSL on
2026-10-25 and driving every menu, overlay and dialog.

**3.0 Foundations, M.** Builds on 0.0 (the modal scope, TaskDialog, OLE) and
waits for spikes S1 and S2.
- **Platform bits.** `SetTimer` helpers, and a `<supportedOS>` block in
  `dist/windows/ghostty.manifest` (needed for layered child windows and
  reliable version checks; added with spike S1, now in
  `dist/windows/murrtty.manifest`).
- **Overlay layer**, in two parts:
  - Shapes (borders, progress strip, scrollbar thumb) are rectangles in 1.7's
    present-pass list. They survive transparency and have no airspace
    problems.
  - Text and interactive overlays (labels, the search box) are layered child
    windows of the surface (spike S1): `WS_EX_LAYERED` with
    `SetLayeredWindowAttributes`, so the controls inside paint normally.
    Plain child windows left a ghost where they had been. If S2 forces
    DirectComposition, they become composition visuals instead.
  - Either way they attach to the pane's rectangle, so they work per split.
- **Focus target.** `Surface.focusTarget()` returns an open interactive
  overlay's control, and `Window.focusActive` uses it. Search and the palette
  then keep focus across window activation, which 1.1 otherwise hands back to
  the pane.
- **`App.supportsAction`.** One predicate shared by menus and the palette.
  Entries for actions not implemented yet are grayed in menus and hidden in
  the palette.

*Done 2026-10-26 (with S2 still to run on a live display):*
`win32/Overlay.zig` is the text overlay host, a layered child of the pane
(`MurrttyOverlay`, alpha 235, rounded, GTK's padding and outline, the
terminal's colors), placed at one of `resize-overlay-position`'s spots and
hidden by a `SetTimer` timer. Its first user is the resize overlay, pulled
forward from 3.6 because it exercises the host, the timer and the layout
together: "cols x rows" while a pane resizes, not for a new pane's first
size (the first 250 ms, as GTK; `after-first`), also then with `always`,
never with `never` (scenario `resize-overlay`; the dump reports each
pane's `resize_overlay`). `Surface.focusTarget()` is the pane until 3.2
adds the search box, and `Window.focusActive` uses it. `App.supportsAction`
lists the binding actions whose runtime action isn't implemented yet (all
others the core performs, or the runtime does), from a read of the core's
binding dispatch; app-scoped ones (`open_config`, `quit`) ignore the
runtime's result, surface ones return it.

**3.1 Context menu, M.** The default `right-click-action = context-menu`
only selects a word today, because the runtime ignores the core's consumed
result (`Surface.zig:686-690`). When a right press is not consumed, open
GTK's menu:
- Copy and Paste (grayed when unavailable), Notify on Next Command Finish
  (grayed until 5.3), Clear, Reset.
- Submenus: Split (Change Title… for the pane, then Split Up, Down, Left,
  Right, Close Split), Tab and Window (each Change Title…, New, Close), and
  Config (Open Configuration in OS Editor, Open Configuration in New Window,
  Reload Configuration). Every item shows its binding (*GTK, observed*).

Run it in a modal scope that leaves other windows enabled
(`disable_others = false`) and use dark menus where available. Open it only
from an unconsumed right press, as GTK does. Shift+F10 and the Menu key reach
programs today (the Menu key sends `CSI 29~`), so neither opens the menu;
keyboard access is not scheduled. *Done when:* right-click Copy and Paste
work, and Close Tab chosen from the menu while a dialog is pending frees
nothing early.

*Done 2026-10-26.* `win32/ContextMenu.zig` builds GTK's menu from a table
of binding actions (`TrackPopupMenuEx` with `TPM_RETURNCMD`, in a modal
scope with other windows enabled). Each entry shows its binding Windows
style ("Ctrl+Shift+T", from the core's reverse map, which keeps the binding
added last: Copy shows Ctrl+Ins) and is grayed when `App.supportsAction`
says no, Copy without a selection, Paste without text on the clipboard, or
for the two entries not built yet (Notify on Next Command Finish, Open
Configuration in New Window). The menu opens on an unconsumed right press;
it takes the button's release, so the pane lets go of the mouse and tells
the core the button came up, then performs the chosen action after the
menu's loop (closing actions still queue). Dark menus come from uxtheme's
ordinals 135 and 136 (`App.allowDarkMenus`). The `context-menu` scenario
reads the menu from another process (`MN_GETHMENU`, `GetMenuStringW`),
chooses entries by access key, and checks Copy, Paste, Tab > New Tab and
Close Tab, which asks while the shell runs (No keeps the tab). Not tested:
a program reporting the mouse taking the right press (the core's rule);
ConPTY keeps a console program's DECSET 1000 to itself, so no shell here
can turn reporting on.

**3.2 Search, M.** A search box over the pane's top-right corner: an edit
control, an "n/m" counter and previous, next and close buttons.
- Typing runs the core search with a short debounce. Enter and Shift+Enter
  step; Escape ends the search and returns focus.
- Handle `start_search`, `end_search`, `search_total` and `search_selected`.
  The core's search thread already exists.

*Done when:* `Ctrl+Shift+F` opens and focuses the box, matches highlight with
a counter, and `search_selection` prefills it.

*Done 2026-10-26.* `win32/SearchBox.zig`: a layered child of the pane
(S1's host) at its top-right corner holding a real `EDIT` control (caret,
IME and editing as in any field), GTK's "n/m" counter ("0/0" with no
matches; the core's selected index is 0-based, as GTK reads it) and three
owner-drawn buttons with Segoe MDL2 glyphs, in the terminal's colors. The
field's wrapped window procedure turns Enter, Shift+Enter and Escape into
`navigate_search` and `end_search`; typing runs the core's `search` 150 ms
after it pauses (GTK's search entry delay); opening again searches for what
the field holds. `start_search`, `end_search`, `search_total` and
`search_selected` drive it; while it is open `Surface.focusTarget()` is
the field, so the box keeps the keyboard across window activation, and
closing gives it back to the pane. Scenario `search`; the dump reports
each pane's `search`. Corrected after the mid-phase review: the up button
goes to the next match (the core counts from the newest, so upward, as
GTK's does) and the down button to the previous; Ctrl+G and Ctrl+Shift+G
step as in GTK's search entry; the field gets the keyboard back only if it,
not the terminal, had it last, and taking it makes its pane the focused
one; focus-follows-mouse leaves it alone.

**3.3 Command palette, L.** A popup anchored at the top center of the window:
- A filter box and an owner-drawn list. The entries are
  `command-palette-entry` items, each with its key binding, plus one "focus
  terminal" entry per surface.
- Fuzzy matching, keyboard navigation. Actions run after the palette hides,
  never from inside its window procedure.
- *GTK, observed:* modal, dimming the window behind; each row shows the
  title with the action name beneath (`prompt_tab_title`) and the binding as
  keycaps; entries the runtime can't perform are hidden. Its per-terminal
  rows read only "Focus: <title>", so terminals with the same title look
  alike: add the tab and window number.

Remove 0.2's override for `Ctrl+Shift+P`. *Done when:* the palette filters,
runs actions, and jumps to terminals in other windows.

*Done 2026-10-26.* `win32/CommandPalette.zig`, one per window: a layered
child box (S1's host) at the window's top center, under the tab bar, over a
layered dimming child that covers the client area and closes the palette on
a click. The box holds a real `EDIT` filter over an owner-drawn `LISTBOX`.
Rows are GTK's: the title with the action beneath in monospace
(`new_split:right`) and the binding as keycaps. The entries are the
`command-palette-entry` items `App.supportsAction` allows (71 of the
defaults), copied, sorted as GTK sorts them, and a "Focus:" entry per terminal in
every window. GTK leaves those without a line beneath; here it reads "Tab 2:
C:\src", or "Window 2, tab 1: ..." with several windows (the directory from
`Surface.pwd`, unless the title shows it). Typing ranks title matches, then
matches of the line beneath (GTK's two filters), then titles holding the
typed letters in order. The field's wrapped procedure moves the selection
with Up, Down, Page Up and Page Down, Enter runs and Escape closes; a click
on a row runs it on release (GTK's single-click activation). What was
chosen runs from a posted message after the palette has closed: an action
on the pane it opened over (or the window's active pane, if that one has
closed), a jump through `Window.presentSurface` once the pane is checked to
still exist. While it is open `Window.focusActiveNow` gives it the
keyboard. 0.2's override for `Ctrl+Shift+P` is gone (the inspector's
remains). Scenario `command-palette`, which also jumps from a second window;
the dump reports each window's `palette`. Not done: GTK's description
tooltips (the owner-drawn list has no per-row tooltips yet).

*Mid-phase review, 2026-10-26.* Three independent reviews of 3.0 to 3.3
(Win32 lifetimes and reentrancy, parity with GTK and the core, and the
tests) found, and these were fixed:
- **The palette read freed memory** after any app config change while it
  was open (a reload from another window, Windows switching between light
  and dark): its titles and actions pointed into the config that change
  frees. It now copies each entry; what was chosen is copied again for the
  posted run. The scenario changes the config four times under the open
  palette (with the copy taken out, Ghostty crashed every run).
- GTK's application accelerators work while the search field or the
  palette's filter has the keyboard (`Surface.fieldShortcut`): new tab,
  window and split, close, copy, paste, clear, reset, the config's, and the
  palette's own binding, which now closes it.
- `App.supportsAction` looks at arguments: `copy_to_clipboard:html` (HTML
  only, which the clipboard code can't write), `paste_from_selection` and
  `open_config:new_window` (until 5.1 built it) are hidden and grayed.
- The palette tracks panes by core surface id, not address, and holds a
  chosen command while a dialog is open (`App.resumeAfterModal`); both
  fields' own right-click menus run in a modal scope; only the active
  window takes the keyboard on opening (`all:` actions); the list no
  longer erases white; Ctrl+Backspace deletes a word in both fields; Enter
  with nothing listed closes the palette (GTK's).
- The context menu matches GTK's submenus (no separators; "Change Tab
  Title...", "Open Configuration in OS Editor"), and no longer frees an
  unset string when out of memory.
- Tests: checks that couldn't fail now can (the cross-window jump's tab, a
  click on a row other than the first, Down then Enter, `never` versus
  `after-first`, focus checked as the thread's real focus, posted clicks
  checked against what is under the point); new checks for the highlight
  (pixels), the menu's modal scope, graying with no selection, and the field
  keeping the keyboard across window activation; races fixed (filter text
  waited for, a sync between clicks and a chord); the dump writes invalid
  UTF-8 as U+FFFD instead of failing.

Kept as decided: typing "tab" or "window" also lists every Focus: entry
(their line beneath is matched, so a terminal can be found by where it is
or its directory), and results are ranked rather than GTK's plain
alphabetical order. Still open: the Enter or Escape key-up that closes a
field reaches the pane (a release without a press, seen only by programs
asking for key releases); a clipboard restored by the context-menu
scenario overwrites anything copied meanwhile.

**3.4 Scrollbar, M.** An overlay scrollbar from the core's `scrollbar` action:
- A thin thumb that widens on hover and fades when idle, drawn through 3.0's
  shape layer so the grid does not shrink.
- Dragging sends `scroll_to_row`; clicking the track pages.
- `scrollbar = never` hides it; `system` follows Windows' "always show
  scrollbars" setting.

*Done when:* the thumb tracks scrollback, dragging scrolls, and alternate-screen
apps show no thumb.

*Done 2026-10-26.* `win32/Scrollbar.zig`, one per pane, from the core's
`scrollbar` action (rows in all, the viewport's first row and height):
GTK's overlay indicator, a 3 DIP thumb at the right edge that a scroll (not
new output alone) or any mouse move over the pane shows, 8 DIP with a faint track while the
mouse is over the 14 DIP band at the edge or pressed there, in the
terminal's foreground, fading over 200 ms a second after the last reason to
show. It is drawn in the present pass (`Surface.updateOverlay` composes it
with the split dimming), so the grid keeps its width. The band takes the
mouse from the core (which sees the mouse leave), except while the
terminal drags a selection: a press on the thumb drags it (`scroll_to_row`
for each new row), a press on the track pages. Nothing shows without
scrollback, which covers the alternate screen (Windows 11's ConPTY passes
a program's switch to it through, checked on 25H2; Windows 10's not yet).
The band wins over a divider beside it. `scrollbar = never` turns it off; with Windows'
"Always show scrollbars" (`DynamicScrollbars` 0, read again on any
WM_SETTINGCHANGE) it doesn't fade. Scenario `scrollbar` (the thumb's pixels
from the renderer's read-back, the drag, the page, the fade, a
PowerShell switch to the alternate screen, `never`); the dump reports each
pane's `scrollbar`. Not done: GTK's click-to-warp (a click on the track
pages, as Windows' scroll bars do) and repeating while the track is held.

**3.5 Titles, M.** Implement `prompt_title` (surface, tab, window),
`set_tab_title`, `set_window_title` and `copy_title_to_clipboard`.
- Overrides layer over the terminal title: pane, then tab (on `Tab` after
  Phase 1), then window.
- The prompt is a small dialog in a modal scope. Double-clicking a tab
  renames it.

*Done when:* a renamed tab keeps its name while programs set OSC 2 titles, and
clearing the name restores the program's title.

*Done 2026-10-26.* GTK's layering: a pane shows its name
(`prompt_surface_title`) over its program's title (`Surface.effectiveTitle`),
a tab its name (`prompt_tab_title`, `set_tab_title`) over its focused
pane's, the caption the window's name (`prompt_window_title`,
`set_window_title`) over its active tab's; a blank name goes back to the
one beneath. `win32/TitleDialog.zig` is GTK's prompt as a real dialog from
a template built in memory ("Change Terminal Title", "Change Tab Title" or
"Change Window Title"; "Leave blank to restore the default title."; the
current title, selected; OK and Cancel), so Enter, Escape and Tab work as in
any dialog. It runs from the message loop as an `App.Request`
(`prompt_title`), in a modal scope, never inside the core's key handling.
A double click on a tab renames it, murrtty's own (GTK's tabs don't): the
window class takes double clicks, both presses must hit the same tab, and
on the close and new-tab buttons a double click is two clicks. A window's
name is its caption, which the taskbar also shows; GTK's goes only to the
header bar's title widget, its window list keeping the tab's title. Kept:
on Windows the caption is the window's title.
`copy_title_to_clipboard` copies the pane's effective title; the palette's
Focus: entries and the context menu's Change Title items use these too.
Scenario `titles` (rename, a program's title under a name, blank, Cancel,
the window's name, the pane's name, copying, a double click); the dump
reports the caption, each tab's label and the names.

**3.6 Status overlays, M.** Using 3.0:
- the link hover preview (`mouse_over_link`, `link-previews`);
- the resize overlay (`resize-overlay`, default after-first); *done in 3.0*;
- the key sequence and key table indicator;
- the read-only badge;
- the child-exited banner (`show_child_exited`);
- a renderer-unhealthy panel (`renderer_health`);
- in-app toasts (`app-notifications`: "Copied to clipboard" and "Reloaded the
  configuration", both on by default), a bottom-center pill for about 3 s
  with a close button; copying an empty selection shows "Cleared clipboard"
  (*GTK, observed*). Update the option's documentation, which says it
  applies only to GTK.

*Done when:* each appears and hides under the same conditions as on GTK.

*Done 2026-10-26.* `win32/Overlay.zig` grew into the general text host
(per-use margins, padding, corners and colors, an optional Segoe MDL2
glyph, shows until hidden, a 512-unit buffer cut with an ellipsis at the
parent's width, or wrapped), with these users, each from the core's action:
- **Link preview** (`mouse_over_link`, `link-previews`): the URL at the
  pane's bottom left, square, GTK's padding and outline; at the bottom right
  while the mouse is over that spot; gone on an empty URL. Long URLs are
  cut with an ellipsis (GTK lets them run).
- **Read-only badge** (`readonly`): a lock and "Read-only" at the top right
  in GTK's tan (hsl(25 50% 75%)), outlined, no fill; shown at once (GTK
  crossfades over 500 ms).
- **Key state** (`key_sequence`, `key_table`, `win32/KeyState.zig`): a
  keyboard glyph, the active tables joined by " > ", a "›", then the
  sequence's keys as Windows names them ("Ctrl+Shift+F8"), at the bottom
  center while there is any (GTK's spinner and dragging it to the top are
  not done).
- **Renderer panel** (`renderer_health`): GTK shows nothing; this shows
  macOS's text in the middle of the pane while the renderer is unhealthy.
- **Child-exited banner** (`show_child_exited`, `win32/Banner.zig`): GTK's
  bar across the bottom, "Command Succeeded" on a green wash or "Command
  Failed" on a red one (by exit code), with a real Close button (an
  `App.Request` close). The core asks for it on every exit; returning true
  replaces its text in the terminal. It stays after an abnormal exit
  (non-zero within `abnormal-command-exit-runtime`), whose pane the core
  keeps open, and with `wait-after-command`; otherwise the pane closes at
  once, as on GTK.
- **Toasts** (`app-notifications`): "Copied to clipboard" or "Cleared
  clipboard" for every write to the clipboard without a confirmation (or
  once one is allowed), "Reloaded the configuration" in every window on any
  app config change (the light/dark switch too, as on GTK), none at start;
  a pill at the window's bottom center for 3 seconds, the latest replacing
  the one before (GTK queues them and gives each a close button). The
  option's documentation now names Windows.
Scenario `status-overlays` (each of these; the renderer through a test
hook, as nothing can fail it on demand); the dump reports each pane's
`status` and each window's `toast`. A test hook (dump wparam 7) keeps panes
from acting on WM_MOUSELEAVE, which Windows sends at once for a posted move
on the hidden desktop and would clear hover state before a test sees it.

**3.7 Bell, M.** Implement the `title`, `audio` and `border` bell features
with per-pane ringing state, cleared on focus or input. `title` is in the
default `bell-features`, so its part (S) is in M1; audio and border are M2.
- `title`: a bell glyph on the tab and caption, and an attention marker on
  a background tab (GTK underlines it, *observed*).
- `audio`: Media Foundation playback with `bell-audio-volume`, or `PlaySoundW`
  as a first cut.
- `border`: a border overlay.

*Done when:* a BEL in a background tab marks it until selected, and the audio
file plays at the configured volume.

*3.7a (`title`) done 2026-10-26.* A BEL with `bell-features = title` (the
default) in a pane that doesn't have the keyboard puts "🔔 " before the
tab's title, and the caption, while the pane's bell rings
(`Surface.bell_ringing`), until the pane gets the keyboard, a key or a
press; GTK's order, before the zoom's "🔍 " (`Tab.label`, which the tab
bar and caption show; `Tab.title` stays plain for the rename prompt). A
bell in the pane with the keyboard shows nothing. Any bell in a background
tab also underlines the tab (`Tab.attention`) until it is selected.
Scenario `bell`; the dump reports each tab's `bell` and `attention`, and
what the tab bar last painted (`painted_bell`, `painted_attention`). Audio
and border (the rest of 3.7) are M2.

*End-of-phase review, 2026-10-26.* Three independent reviews of 3.4 to
3.7a and the icon (Win32 lifetimes and reentrancy, parity with GTK and the
core, and the tests) found, and these were fixed:
- **The banner's Close never closed** once the button gave the keyboard
  back while pressed (a fix made in this round, caught by the scenario): a
  button that loses the keyboard mid-press drops the click. The keyboard
  now goes back to the pane when the press is over (a subclass acting
  after the button's own `WM_LBUTTONUP` or capture loss); a press dragged
  off it is checked to take the keyboard, close nothing and give the
  keyboard back (a release with no held move first still clicks, as the
  button stays pushed until a move leaves it).
- GTK parity: no bell for the pane with the keyboard, and a press answers
  one; a background tab's mark on any bell; `resize-overlay-duration = 0`
  hides at once instead of keeping the overlay; the scrollbar wakes on a
  scroll, not on output that only grows the scrollback; the toast stays
  above panes laid out after it; a soft config reload aimed at one pane
  reloads that pane, not the app.
- Win32: the scrollbar's band takes the mouse before a divider beside it;
  a double click renames only if both presses hit the same tab (not one
  moved under the second); `Scrollbar.update` returns early when nothing
  changed (it runs on every scroll message); the overlays and banner of a
  background tab are laid out again by their own visibility
  (`Overlay.shown`, `Banner.shown`) rather than the hidden pane's;
  `Surface.updateOverlay` posts a frame request (`WM_FORCE_FRAME`,
  coalesced) instead of taking the terminal's lock, since it runs from
  `WM_SIZE` and setting changes, which a message sent from another process
  can bring while the core holds that lock (copy-on-select writes the
  clipboard with it held); the rename prompt's text converts lossily, and
  an entered title that can't be converted counts as Cancel; `KeyState`
  frees a key it couldn't append; the dump survives a caption cut inside a
  surrogate pair.
- Tests: the scrollbar's first checks rewritten (hover with the mouse
  pinned, the thumb probed while pressed, the alternate screen probed where
  the thumb was, syncs instead of sleeps, "always" mode); `titles` covers
  `prompt_window_title`, `set_tab_title` layering, the modal scope, Enter
  in the field, and a double click on "+"; `bell` covers the focused pane,
  persistence, keys in another tab and the painted bits; `status-overlays`
  shows read-only held input back with a command typed after it, unpins
  the mouse, and fails on a dump error instead of retrying it;
  `context-menu` guards an empty item list.

Still open: GTK's click-to-warp and track repeat on the scrollbar; GTK's
toast queue and close button; the key state's spinner.

**3.8 Tab bar, M to L.**
- Right-click menu: Rename, Close, Close Others, Close to the Right, Move to
  New Window. *Decided 2026-10-25:* kept, though GTK's offers only Change Tab
  Title (*observed*): Windows users expect the fuller menu, and each item is
  an existing action.
- Overflow: wheel scrolling (with chevrons) and a tab list with a filter box,
  opened from a list button that is always visible. That list also serves
  `toggle_tab_overview`, including with `window-show-tab-bar = never`.
  *Decided 2026-10-25:* a list, not GTK's overview of live thumbnails with a
  search box (*observed*), which would need a snapshot of every pane.
- Tooltips with the title and, once Phase 2 reports it, the working
  directory (*decided 2026-10-25*; GTK's tooltip shows only the directory,
  *observed*). Also `window-title-font-family`, `window-new-tab-position`, a
  small icon for high DPI, and the progress and read-only indicators (the
  bell glyph comes from 3.7, the zoom magnifier from Phase 1).
- The affordances GTK's header bar shows by default: a menu button at the
  right of the strip opening the main menu, the list button, and a dropdown
  on `+` with Split Up, Down, Left and Right. GTK's main menu (*observed*):
  Copy, Paste; Change Window Title…, New Window, Close Window; Change Tab
  Title…, New Tab, Close Tab; Split ▸; Clear, Reset; Command Palette,
  Terminal Inspector, Config ▸; About Ghostty, Quit. The system menu gets the
  same items.

*Done when:* 40 tabs are all reachable, right-click Close Others works, and
the menu button and `+` dropdown work.

*3.8a (the tab menu) done 2026-10-26.* A right press on a tab (GTK opens
menus on the press) shows `ContextMenu.trackTab`'s menu, owned by the
window: Change Tab Title..., Close Tab, Close Other Tabs and Close Tabs to
the Right, each with its binding if it has one, then Move Tab to New
Window, grayed until 4.5 moves terminals between windows. Close Other
Tabs is grayed with one tab, Close Tabs to the Right on the last. The
choice runs as the core's action (`prompt_tab_title`, `close_tab:this`,
`:other`, `:right`) on the clicked tab's focused pane after the menu's
loop, so it confirms and closes as those bindings do, and the clicked tab
stays in the background. Scenario `tab-menu`.

*3.8b (GTK's header bar buttons) done 2026-10-26.* "+" gained an arrow
beside it (GTK's split button) opening Split Up, Down, Left and Right, and
a button with three lines at the strip's right end opens GTK's main menu
(*observed*): Copy, Paste; Change Window Title..., New Window, Close
Window; Change Tab Title..., New Tab, Close Tab, the Split submenu; Clear,
Reset; Command Palette, Terminal Inspector (grayed until 5.12), the Config
submenu; About murrtty (a task dialog with the version, `App.showAbout`),
Quit. Both open on the press under their button and act on the active
tab's focused pane, as the core's actions. Tabs that don't fit run under
the buttons until 3.8c. Scenario `tab-buttons`; the dump reports both
buttons' rectangles. The system menu's items are 3.9's.

*3.8c (overflow and the tab list) done 2026-10-26.* `TabBar.place` lays
the strip out once for everything that draws or hit-tests it: tabs share
the room between 64 and 240 DIP; when they don't fit at 64 they scroll
(`TabBar.scroll`) between a "‹" and a "›", "+" and its arrow move to just
left of the list button, and tabs are painted clipped to their span. A
chevron scrolls a tab per click, the wheel (or a tilt) a tab per notch;
selecting a tab (a click, a key, a new tab) scrolls it into view, and a
resize only clamps the scroll, so scrolling by hand isn't undone. The
list button, always shown left of the main menu's, and
`toggle_tab_overview` (also with `window-show-tab-bar = never`) open the
command palette in a tabs mode: the window's tabs in order as the strip
labels them, "Tab N" and the directory beneath, the active one selected;
the filter matches both lines, and choosing one jumps to its pane. Move
Tab to New Window in the tab menu is now the core's
`move_tab_to_new_window`, grayed until 4.5 implements it. Scenario
`tab-overflow` (twelve tabs in a 50-column window); TabBar's unit tests
bring each of 40 tabs into view and click it. The dump reports the list
button, the chevrons, the span and the scroll.

*3.8d (the strip's details) done 2026-10-26; 3.8 done.*
- **Tooltips:** one tooltip control over the strip (comctl32 v6, a tool
  with its text asked for when it shows, hidden on every change of the
  item under the mouse): a tab's title and, beneath, its directory unless
  the title shows it; "New Tab (Ctrl+Shift+T)", "Tab List", "Split",
  "Menu" and the chevrons' names for the buttons.
- **`window-new-tab-position`:** `end` puts a new tab last instead of after
  the active one.
- **`window-title-font-family`:** the strip's font; the caption's is the
  system's until 4.3 draws the title bar.
- **Icons at the window's DPI:** the small (caption) and big (Alt+Tab)
  icons load from the executable's icon at that DPI's sizes, again on a
  DPI change, rather than the class's 32 px icon scaled.
- **Not done, on purpose:** progress and read-only marks on tabs. GTK marks
  only the bell and the zoom in a tab's label; its progress (OSC 9;4) is a
  bar over the terminal, and read-only a badge (3.6). The progress bar
  goes with 5.4's taskbar progress.
Scenario `tab-details`; the dump reports the strip's font, each tab's and
"+"'s tooltip, the icons' widths and the tooltip's presence.

*3.8e (the header bar with one tab) done 2026-10-26, from the owner's
report that the 3.8 build showed no top bar.* The strip held the header
bar's buttons but hid with one tab (`window-show-tab-bar = auto`), taking
them along; GTK hides only its tab bar then. Now the strip shows whenever
GTK's header bar would (`gtk-titlebar`, not fullscreen, not maximized with
`gtk-titlebar-hide-when-maximized`) or its tab bar would, and lays out
tabs only for the latter: with none, "+" and its arrow sit at the left end
and the list and menu buttons at the right. Fullscreen now hides the strip
with one tab (the field changes before the window moves, so the layouts
see it). Scenario `header-bar`; `launch` expects the 960x600 DIP terminal
below the strip; the dump reports `tabs_shown`, with zero rectangles for
tabs not shown.

*3.8f (GTK's icons) done 2026-10-26, from the owner's screenshot of the
GTK app.* The header's buttons are drawn as GTK's symbolic icons in the
foreground color: tab-new (a rounded square holding a plus), pan-down (a
filled triangle past a thin divider), view-grid for the tab list, and
open-menu; a hovered button gets a rounded highlight. Opt-in scenario
`snapshot` (`GHOSTTY_GUI_SNAPSHOT` = a folder) writes pictures of the whole
window, off-screen, for comparing by eye.

**3.9 Dialog polish, S.**
- Replace `MessageBox` confirmations with TaskDialogs, worded as GTK's
  (*observed*): "Close Tab?" / "All terminal sessions in this tab will be
  terminated." with Cancel and a destructive Close; the rename prompt
  "Change Tab Title" / "Leave blank to restore the default title." with the
  current title selected.
- Make the clipboard dialog show the full text in a scrollable monospace box,
  default to Deny, and offer "remember for this terminal" (GTK parity).
- Add Ghostty items and About to the system menu (`Alt+Space`). The system
  menu works even when the tab bar is hidden.
- Add `open_config:new_window` once 5.1's command overrides exist (the basic
  `open_config` fix is in 0.6).

*3.9 done 2026-10-26; `open_config:new_window` came with 5.1 on
2026-10-27. Phase 3 done.*
- **Close confirmations** (`App.confirmClose`): task dialogs with GTK's
  heading and body for the app ("Quit murrtty?"), a window, a tab, a split,
  plus "Close All Windows?" and "Close Tabs?" (several at once: one question
  where GTK asks per tab), Cancel the default (Escape too) and Close. A lone
  pane's close says "Close Tab?", which is what happens (GTK: "Close
  Split?"). Close has IDYES's id, so tests answer as before; No is Cancel.
- **Clipboard confirmation** (`win32/ClipboardDialog.zig`, a dialog from a
  template like the title prompt): GTK's headings and bodies (a write's
  body says the text shown is what it would write, where GTK's says the
  current contents), the whole text in a read-only Consolas box (up to
  256 KiB; line breaks as CRLF, other control characters as Control
  Pictures, so a NUL can't hide what follows), Allow and Deny (default),
  and for OSC 52 "Remember choice for this split", kept in the core's
  config until a reload. Escape and the close box deny without remembering.
- **System menu** (`ContextMenu.SystemMenu`): after Windows' Close, New
  Window, New Tab, Split, Command Palette, Terminal Inspector, Config, About
  murrtty and Quit, refilled as the menu opens; access keys clear of
  Windows' (R M S N X C), so Alt+Space, C still closes. Ids are multiples of
  16 (WM_SYSCOMMAND keeps the low four bits). The window takes its own copy
  of the menu at creation, or WM_INITMENUPOPUP brings the shared one; the
  menu's loop runs in a modal scope (WM_ENTERMENULOOP).
- The title prompt was already GTK's (3.5).
Scenarios `clipboard-dialog`, `system-menu`; close wording checked in
`typing`, `alt-f4`, `close-all`, `tab-menu`, `split-commands` and every
`quit`, from the dump's `dialog` (the last task dialog's heading and body,
which a DirectUIHWND draws out of reach).

*Phase 3 end-of-phase review (3.8 and 3.9), 2026-10-26:* seven findings,
six fixed. A `window-title-font-family` over 31 characters overran a stack
buffer (`std.unicode.utf8ToUtf16Le` assumes the output fits; now measured
first); text cut by bytes before conversion could split a character and
blank a tooltip, tab title or palette line (now cut between characters);
a tab selected while minimized was scrolled for a strip of no width and
sat outside the view once restored (now revealed at the next layout with
width); sub-notch wheel turns (touchpads) never scrolled the strip (now
accumulated); the system menu's access keys assumed English (Windows'
items' keys are read and murrtty's drop a clashing one); a failed window
creation leaked its icons. The finding that the caption's right-click
menu ran without a modal scope didn't reproduce (`system-menu` checks the
depth there), but the scope now also opens when the system menu itself
does, for ways in that don't announce a menu loop. `tab-overflow` checks
the wheel and the minimized selection, each shown to fail without its fix.

---

## Phase 4: Window chrome and visuals (about 5 to 8 weeks, or 7 to 10 if 4.1 needs Phase B)

*Order:* 4.3 first (the owner, 2026-10-26: GTK's header bar as the title
bar is most of the Look rule), then 4.1, 4.2 and the rest as numbered.

**4.1 True transparency, L, or XL if Phase B is needed.** Spike S2 first.
- **Phase A:** `DwmEnableBlurBehindWindow` with an empty region on the top
  level makes DWM use per-pixel alpha. The present pass clears to transparent
  and copies without blending. GDI writes alpha 0 wherever it paints, so every
  GDI-painted region (tab strip, dividers, exposed margins, overlay windows)
  is drawn into a 32-bit DIB or with `BufferedPaintSetAlpha`, so its alpha is
  255.
- **Phase B, if A fails on a major driver:** a `WS_EX_NOREDIRECTIONBITMAP`
  top level with DirectComposition. Each pane gets a composition swap chain,
  rendered from GL through `WGL_NV_DX_interop2`. The child windows remain for
  input. With no redirection surface, GDI output is not composed: the tab
  strip, caption buttons, dividers and child-window overlays move to
  `IDCompositionSurface` visuals.

Implement `toggle_background_opacity` too. *Done when:* the desktop shows
through the background on NVIDIA, AMD and Intel with opaque text, and drivers
without interop fall back to opaque cleanly.

*Phase A built 2026-10-27:* a window is translucent while
`background-opacity` is below 1 (`App.translucent`, also fullscreen, as
GTK keeps it). `Window.syncTranslucent` turns on blur-behind with an empty
region and switches every pane's present pass to the frame's own alpha
(premultiplied sRGB; beyond the frame during a resize, the background at
its opacity); a new pane's renderer takes it up as it starts, so its first
frame is translucent too. The header bar, tab row and dividers paint
through `draw.AlphaPaint` (uxtheme's buffered paint with
`BufferedPaintSetAlpha`): opaque, as GTK's bars and separators, and what
the panes don't cover yet at the background's opacity, premultiplied.
Overlays are layered children, which S2 showed stay opaque; the
unfocused-split dimming and the bars' shade are present-pass shapes,
blended over the translucent frame as GTK's CSS blends them.
`toggle_background_opacity` follows macOS (every window, new ones too;
nothing at an opacity of 1). A failing `DwmEnableBlurBehindWindow` leaves
the window opaque. The `translucent` scenario reads the frames and paints
back with their alpha on the hidden desktop; `transparency` (on screen)
checks what DWM shows, header and divider included. Its first run
(2026-10-27, the owner at the screen) showed only the green backdrop:
the harness, a background job, set murrtty's topmost style but couldn't
raise it over the backdrop (raising needs foreground rights). It now
lowers the backdrop under murrtty and skips, naming the window, when
another one covers murrtty. Left: a passing on-screen run on NVIDIA,
then AMD and Intel (no such GPU here), and Phase B only if one fails.

**4.2 Blur, M.**
- Windows 11 22H2 (build 22621) and later: Acrylic via
  `DWMWA_SYSTEMBACKDROP_TYPE`.
- Windows 10, and Windows 11 before build 22621: the undocumented
  accent-policy call.
- Off when opaque, fullscreen or forced opaque.

*Built 2026-10-27:* `Window.syncBlur` blurs a translucent window while
`background-blur` is on (any intensity: GTK ignores it too), over 4.1's
blur-behind, the combination Tauri's window-vibrancy uses: Acrylic
(`DWMSBT_TRANSIENTWINDOW`) from build 22621, before it
`SetWindowCompositionAttribute`'s `ACCENT_ENABLE_BLURBEHIND` (resolved at
run time, from build 17763), else none. Off when opaque (an opacity of
1, or toggled); fullscreen keeps it, as GTK does, rather than turning it
off as planned. The `blur` scenario checks the state, DWM's reported
backdrop type and the accent path (forced by a test hook) on the hidden
desktop; `blur-display` (on screen, the owner's) checks that striped
backdrop blurs. Left: that run, and Windows 10 (no machine here).
After the review: Windows draws Acrylic solid in an inactive window, so
an inactive one takes the accent policy's blur (`WM_NCACTIVATE`
switches); that blur lags while dragging or resizing on 22H2, which only
an active window does. `blur-display` repaints its stripes red to check
the blur follows the backdrop rather than a solid fallback.

**4.3 Tabs in the title bar, L.** Windows Terminal-style integrated caption:
- Keep `WS_OVERLAPPEDWINDOW` (snap, animations, rounded corners and shadow
  stay), remove the caption in `WM_NCCALCSIZE`, and draw caption buttons with
  Segoe Fluent or MDL2 glyphs.
- `WM_NCHITTEST`: return `HTMAXBUTTON` so Windows 11 shows Snap Layouts, and
  `HTCAPTION` on empty strip space.
- Mouse input over the caption-button codes then arrives as `WM_NC*`
  messages. Handle `WM_NCMOUSEMOVE`, `WM_NCMOUSELEAVE` and
  `WM_NCLBUTTONDOWN`/`UP` for `HTMINBUTTON`, `HTMAXBUTTON` and `HTCLOSE`
  without `DefWindowProc`, which would paint legacy buttons, and post
  `WM_SYSCOMMAND`.
- Replace `AdjustWindowRectExForDpi` in `setClientSize` and `WM_GETMINMAXINFO`
  with insets that match `WM_NCCALCSIZE`. Otherwise `window-width`/`-height`,
  `initial_size`, CSI 8 t and the minimum size are off by the caption height.
- Handle maximized insets and auto-hide taskbars (done: the frame's inset
  at the top since step 1, auto-hide taskbars after the mid-phase review).

This is `window-decoration = auto/client`; `server` keeps today's layout.
*Done when:* drag, double-click maximize, Snap Layouts, every resize edge and
the system menu all work at 100% to 200%, on Windows 10 and 11.

*The look to match* (the owner's screenshot of the GTK app under WSLg,
2026-10-26): one bar, about 46 px at 100%, is the whole title bar: at the
left the split button (tab-new icon, a thin divider, a down triangle), the
title centered, at the right the tab overview (grid) and main menu
(hamburger) buttons, then the window's buttons (GTK shows only a round
close button; Windows users expect minimize, maximize and close). Tabs, when
shown, go in their own row beneath, as GTK's tab bar. Buttons highlight on
hover with rounded backgrounds; the menu button stays highlighted while its
menu is open. 3.8f already draws GTK's icons on today's strip.

*Design (2026-10-26).* GTK draws its header bar only with client-side
decorations (`window-decoration = auto` or `client`, *checked* in
`gtk/class/window.zig`); with `server` the window manager's title bar and
GTK's tab bar remain. So: CSD (the caption removed, the header bar drawn
as the title bar) when `window-decoration` is `auto` or `client`,
`gtk-titlebar` is on, and the window isn't fullscreen or maximized with
`gtk-titlebar-hide-when-maximized`; otherwise the system caption, as
today, and no header (no header buttons, as GTK's tab bar then has none).
The header holds the split button at the left, the title centered, the
tab list and main menu buttons, then the window's buttons, drawn as
libadwaita's round window controls with minimize and maximize as well as
close (GTK's look for them, as Ubuntu's layout shows them); the tab row
beneath holds only tabs. Steps: (1) the frame and the header's layout,
input and painting in today's colors; (2) the Look's colors and
libadwaita's metrics; (3) the bundled font; (4) the comparison against a
GTK reference capture, and tuning.

*Step 1 done 2026-10-26.* `win32/HeaderBar.zig` lays out, hit-tests and
paints the bar (46 DIP; "+" and its arrow, the bold title centered between
the buttons, the tab list and menu buttons, libadwaita's round minimize,
maximize or restore, and close); `TabBar` is the tab row alone, below it;
`draw.zig` holds the GDI shapes and fonts both use. `WM_NCCALCSIZE` drops
the caption while `Window.csd()` holds (insetting a maximized window by
its frame); `WM_NCHITTEST` answers the caption between the buttons,
`HTMINBUTTON`/`HTMAXBUTTON`/`HTCLOSE` over the window's buttons (Snap
Layouts) and `HTTOP` along the top band; the window's buttons hover,
press and click in `WM_NCMOUSEMOVE`/`WM_NCLBUTTONDOWN`/`UP` (never
DefWindowProc's, which would draw the old buttons), posting
`WM_SYSCOMMAND`. A right-click on the bar's caption opens the system menu
from `WM_CONTEXTMENU` (DefWindowProc shows it only over a caption it
drew), its items enabled for the window's state. `setClientSize` and
`WM_GETMINMAXINFO` take the frame
without the caption (`adjustFrame`). A reload that changes the decorations
recomputes the frame (`SWP_FRAMECHANGED`). Scenario `header-bar` checks
the hit codes, maximize, restore, minimize and close through the bar,
fullscreen, `gtk-titlebar = false`, `window-decoration = server` and
`window-show-tab-bar = never`; the dump reports `header` (its buttons,
title font, visibility) and the tab row's `top`.

*Step 2 done 2026-10-26.* The chrome's colors are GTK's
(`Window.chromeTheme`, `draw.Theme`): `auto` Adwaita's light or dark by the
configured background's luminance (no longer following OSC 11, as GTK's
doesn't), `ghostty` the titlebar options or the terminal's colors with
GTK's backdrop (OKLab lightness × 0.9, `draw.scaleLightness`), `system`
Adwaita's by Windows' setting, `light`/`dark` Adwaita's; values from
libadwaita's stylesheet (header #2e2e32/#ffffff, window #222226/#fafafb,
text white/rgb(0 0 6 / 80%)), mixed as it mixes them (`draw.palette`:
hover 7%, pressed 16%, selected 10%/13%, controls 10/15/30%, separators
15%, the shade under the bar). An inactive window (`WM_NCACTIVATE`) shows
the backdrop with its contents at half opacity. The tab row is libadwaita's
tab bar: 46 DIP in the bar's color, 34 DIP rounded tabs (radius 9) filling
the row under `gtk-wide-tabs` (else up to 240 DIP), the title centered,
the selected tab tinted (none for a lone tab), a round close button on the
selected and hovered tabs, separators between the others. `theme` and
`config-errors` expect Adwaita's colors; the opt-in `snapshot` also saves
`chrome-*.bmp` from the window's device context (`Harness.captureClient`),
current where DWM's captures lag a step behind.

*Step 3 done 2026-10-26.* The chrome's font is GNOME's interface font,
Adwaita Sans 11 (grayscale antialiased, as GTK draws text), from
adwaita-fonts 51.0, checked against its published SHA-256 and embedded in
the executable (`src/apprt/win32/res/`, with its OFL license and a
provenance README); `draw.registerFonts` adds it for the process only
(`AddFontMemResourceEx`, never installed). GDI names a variable font's
instances with their optical size's name, so the family it finds is
"Adwaita Sans Text" (regular and bold; other weights as their own
families). `window-title-font-family` still names another. The dump's
font faces are what GDI chose (`GetTextFace`), so a missing font shows
as its substitute; `launch` expects Adwaita Sans and a unit test
registers it and selects both weights.

*Step 4, begun 2026-10-27: the header bar matched.* `test/windows/look/`
takes a GTK reference picture headless (the snap under Xvfb at 96 DPI,
GNOME's font in an isolated config, the screen from Xvfb's framebuffer
file) and measures it against murrtty's chrome pictures (README there).
Measured on GTK: the bar is 46 px; its buttons sit 6 px from the edges
(libadwaita's 7 px less its -1 px margin); the tab list and menu buttons
touch (a plain box); 6 px from the menu button to minimize, the controls
37 px apart with 24 px circles at 10%; the split arrow 21 px wide past a
1 x 22 px divider at 30%; the icons GTK's 16 px glyphs (tab-new a 2 px
rounded square with an 8 px plus, pan-down 12 x 6, view-grid two 6 px
squares 2 apart, open-menu three 14 x 2 bars, the controls' 8 px glyphs
13 px into the button). `HeaderBar` now lays out and draws exactly that,
glyphs as filled shapes on the 16 px grid; a unit test pins the geometry
to the reference's. The tab row then (step 4b, with
`window-show-tab-bar = always` in the reference): GTK's tab bar under the
header is 40 px (its tab box isn't padded above there; 46 as the top bar),
with no line between it and the header: the shade comes under the lowest
top bar. Its close glyph is window-close's 8 px X, 31 px from the row's
right edge. `TabBar` takes those (`top_bar`), the header draws the shade
only without a tab row, and both draw the X the same way (`draw.cross`).
Then the terminal (step 4c, 2026-10-27): the test hooks read a whole
presented frame back (dump wparams 10 and 11, `Harness.saveFrames`), and
`snapshot` writes one at GTK's 96 DPI pixel size showing the same line as
a reference made with `command = printf ...`. Aligned by their ink, the
two lines differ by at most 9 of 255 (p95 2, 77% of pixels identical,
`textdiff.py`): font, size, hinting, cell width and height and blending
already match, since both use FreeType and `linear-corrected`. Padding
matches at 96 DPI; elsewhere both floor points × DPI / 72 (3 px for 2 pt
at 120 DPI). GTK's shade is libadwaita's raised top bar, `0 1px` and
`0 2px 4px` in the shade color at half its opacity, falling onto the
content (measured: 30, 10, 7, 4 and 2% over the background, then
nothing). murrtty now draws it there too, not as a line inside the bar:
row by row in the present pass over every pane that reaches the bars
(`draw.shadeAlpha`, `Surface.setShade`, after the scrollbar and dimming,
as GTK draws the bar over the content) and over the dividers' tops; the
`shade` scenario checks it. The reference is the snap, which bundles
libadwaita 1.5 (header #303030, window #242424); murrtty keeps the
current stylesheet's colors (step 2), Ghostty's look on a current GNOME,
and the metrics measured on 1.5.

*Step 5 done 2026-10-27:* `gtk-toolbar-style`, measured on GTK's
(`-Extra "gtk-toolbar-style = ..."`): `raised-border` keeps the bar and
draws one 1 px line of the darker shade (the stylesheet's rgb(0 0 12 /
90%) in dark, rgb(0 0 6 / 12%) in light) instead of the shadow; `flat`
casts nothing and shows the window's background (#222226 in dark) as the
bar, except with `window-theme = ghostty`, whose stylesheet colors the
header's window handle anyway (`Theme.shadeFor`, `draw.Shade`). The split
dividers are GTK's too: Ghostty's stylesheet paints the separator in the
window's background (`--window-bg-color`: Adwaita's, or the terminal's
with the `ghostty` theme), so they no longer follow macOS's rule (the
pane's background darkened) nor OSC 11. `shade` and `split-dim` check
them.

*Step 6 done 2026-10-27:* `gtk-titlebar-style = tabs`, Windows
Terminal's tabs in the title bar the GTK way (measured with `gtkref.ps1
-Extra 'gtk-titlebar-style = tabs'`, which now takes several lines): no
header bar; the tab row is the title bar and always shows (unless a
maximized window hides its title bar), 46 DIP like the header, holding the
split button at its start and the tab list's and menu's buttons and the
window's at its end, the menu button against minimize (GTK's end box has no
spacing); the tabs fill the span between the split arrow and the tab list's
button, unpadded. Between the buttons and outside the tabs it is the
caption; a tab is not (GTK's tabs can't drag the window either). Without
client-side decorations the row keeps its buttons, not the window's.
`HeaderBar.tabs_style`/`controls` and `TabBar.inset` carry it;
`Window.chromeHit` and `titleBarHeight` answer for either style. And
`gtk-tabs-inverted`: a tab's close button at its start (`TabBar.inverted`,
9 DIP in, as GTK's). `header-bar` checks the layout, the hit codes, the
row without decorations and an inverted close; unit tests pin both to the
reference's pixels. The test hooks also paint the chrome into a bitmap
(dump wparam 12, `Harness.saveChrome`), which `snapshot` writes as
`paint-*.bmp` from the hidden desktop: the `tabs` row compared with GTK's
picture button for button.

*End-of-4.3 review (2026-10-27, steps 4c to 6), fixed:* a tab whose
opening brings the tab row (window-show-tab-bar = auto without a header
bar) missed the row's shade, being made at its final size before it
counted (`Window.addTab` gives it the shade after; `shade` checks it); the
auto-hide taskbar check looks at the monitor the new client area is on
(`MonitorFromRect`), not the one the window was on (Win+Shift+arrow); the
frame read-back no longer writes over a frame not yet taken; in `tabs`
style the row's buttons and tabs are put together off screen and shown in
one step; the dump says when the header's buttons are in the tab row
(`header.in_row`), which `stripButton` checks.

*4.3b step 1, the menus, done 2026-10-27.* GTK's menus measured with
`gtkref.ps1 -Actions` (xdotool clicks in the Xvfb display): popovers in
the popover color (#36363a in dark, #ffffff in light; the terminal's with
`window-theme = ghostty`), 6 px of padding, rows 32 px with the text 18 px
in (41 in a menu with a check item, as the terminal's Notify on Next
Command Finish), the binding right-aligned at 55%, grayed items at 50%, a
hovered row a rounded 10% highlight, separators 1 px at 15% with 6 px
above and below, a chevron for a submenu; the context menu's submenus
open as nested popovers beside it, as Windows' do. So murrtty keeps
Windows' menus (TrackPopupMenuEx: placement, keyboard, accessibility, the
harness's reading of them) and owner-draws their items that way
(`ContextMenu`: `MFT_OWNERDRAW` with the string still stored, so
GetMenuString and access keys keep working, `WM_MENUCHAR` as well; the
popover color as the menu's background), the system menu's own items left
Windows'. Popup menu frames follow the chrome's light or dark
(`App.syncMenuTheme`, uxtheme's SetPreferredAppMode forced either way),
not Windows' app setting. `snapshot` writes the main and terminal menus as
they paint (`Harness.capturePrint`, WM_PRINT, on the hidden desktop).
Still to see on a real screen: Windows 11's frame around them.

*4.3b step 2a, the alert dialogs, done 2026-10-27.* GTK's (`gtkref.ps1
-Actions 'xdotool key ctrl+shift+w'`) are libadwaita 1.5's, a full-width
row of responses split by lines; the current stylesheet (followed, as
for the colors) has rounded buttons instead: a dialog 372 DIP wide at
most (300 at least) in the dialog color (#36363a in dark, #fafafb in
light), 32 above the heading (15 pt bold), 10 to the body, 24 at the
sides, then a response area padded 24 (12 above) of buttons 44 tall,
rounded 12, 12 apart, sharing the row or stacked when a label doesn't
fit; a plain response 10% of the text, a destructive one in the
destructive color (red_4's OKLab lightness raised to 0.85 in dark,
red_3's lowered to 0.5 in light) over 15% of it, a suggested one white
on the accent; the window behind dimmed with the shade color at twice its
opacity (50% in dark, 14% in light). `AlertDialog` builds that as a
Windows dialog (an in-memory template with an owner-drawn button per
response, so Enter, Escape and the GUI tests' answers work as before),
its frame rounded by DWM, over a layered dimming child of the owner; an
entry (the title prompt's extra child: 34 tall, rounded 6, 10% of the
text, the accent's ring while it has the keyboard) returns its text with
the response. The close confirmations (Cancel, the default, and Close,
destructive) and the title prompt (Cancel, and OK, suggested and the
default) use it; task dialogs and the old template stay as the fallback.
`typing` checks the default, the responses and the dimming; `snapshot`
writes both as they paint.

*Step 2b done 2026-10-27:* the clipboard confirmation and the config
errors, GTK's alert dialogs with an extra child. `AlertDialog` takes a
read-only text box (GTK's 500 DIP wide, which widens the dialog; rounded
10 in the view color, its text 8 in, scroll bars light or dark as the
dialog), a switch row (libadwaita's card, rounded 12, its title and
subtitle at 55%, a switch 46 x 26, the accent when on; the whole row
toggles it, and it answers BM_GETCHECK and BM_SETCHECK as the check box it
replaces did) and responses that run without closing. The clipboard
confirmation: GTK's heading and body, the text in Consolas 11 pt 200 tall,
"Remember choice for this split" with "Reload configuration to show this
prompt again" for OSC 52, Deny (suggested, the default) and Allow
(destructive). The config errors: GTK's heading and body, every error in
a box 100 tall, Ignore (the default), murrtty's Open Configuration
(leaves it open) and Reload Configuration (suggested), stacked as
libadwaita stacks responses that don't fit a row, the first at the
bottom. `clipboard-dialog` and `config-errors` write their dialogs'
pictures with `GHOSTTY_GUI_SNAPSHOT` set. About stays Windows' task dialog
(GTK's is libadwaita's About window, a different thing).

*End-of-4.3b review (2026-10-27), fixed:* Enter took the default
response whatever button had the keyboard (Windows never makes an
owner-drawn button the default): the response buttons now ask for Enter
(WM_GETDLGCODE) and click themselves, as GTK's do, and the switch toggles
on it (`titles` presses Enter on Cancel); responses act on a click only,
not a double click's second (Open Configuration opened the file twice),
while the switch counts both (`clipboard-dialog` clicks it twice); a
dialog whose owner is minimized centers where the owner is when restored
and stays inside its monitor's work area (it opened near -32000);
WM_MENUCHAR ignores letters beyond ASCII (Czech š ran "Close T&ab" by its
low byte); the body is a static control and the switch is named by its
title, for screen readers; a grayed menu item the keyboard stops on gets
a fainter highlight; the remember row measures its text as it draws it;
the `tabs` row paints straight to the window if no bitmap can be made.

*Mid-phase review (2026-10-27, steps 1 to 4b), fixed:* the window's
minimum width now holds the header bar's buttons side by side
(`HeaderBar.minWidth`, 255 DIP; narrower, they overlapped and clicks
reached other buttons than those drawn; `header-bar` checks it); a wider
or maximized window repaints the whole chrome (Windows keeps the old
pixels and asks only for the strip it adds, which would leave the
right-aligned buttons and the title behind; no desktop the tests can use
shows it, so it rests on review); maximized, the client area leaves 2 px
at an edge where an auto-hide taskbar hides (`SHAppBarMessage`), or the
shell takes the window for fullscreen and the taskbar can't slide in, as
Windows Terminal found (its #1438; not tested, it would change the
owner's taskbar); the command palette's dimming leaves the header bar's
caption, window buttons and top resize band to the window
(`Window.isFrameAt`; `command-palette` checks the hit codes); leaving the
tab row for a window button keeps its hover; and the window's handle is
set in WM_NCCREATE, since CreateWindowExW sends WM_SIZE (and the layout
using it) before returning it.

*With the Look rule* (decided 2026-10-26, which made 4.3 Phase 4's first
item): the bar and tab row take libadwaita's colors and metrics (taken from
its stylesheet when built, not from memory): Adwaita light or dark by the
configured background's luminance for `window-theme = auto`, the terminal's
colors for `ghostty`, the system's for `system`; the chrome's font is
GNOME's interface font, bundled (Adwaita Sans, OFL; Cantarell before GNOME
48), unless `window-title-font-family` names one. Then, as **4.3b**, the
menus (main, split, tab, terminal) as libadwaita's popovers and the dialogs
as its alert dialogs, replacing the Win32 menus and task dialogs of 3.1,
3.8 and 3.9. To check the result against GTK's, not by eye alone: a GTK
reference captured headless (the WSL app under `xvfb-run`, at a known DPI
and the same configuration) beside murrtty's own read-back of a frame (a
dump request, since window captures read white while DWM idles), for the
terminal's font, cell spacing and padding as well as the chrome.

**4.4 Decorations, M.** `window-decoration = none` (borderless, resizable,
keeps the shadow) and `toggle_window_decorations` without changing the grid
size. Shares 4.3's non-client code.

*Done 2026-10-27:* `Window.captionless` (the header bar's frame, or
`none`) drops the caption in `WM_NCCALCSIZE`; with `none` no header bar
draws, the tab row (when shown) is the top bar, and the top resize band
stays: over the tab row the window's own hit test answers it, over a pane
the pane and its tab pass it on (`Window.inTopBand`, HTTRANSPARENT).
`toggle_window_decorations` is GTK's: a per-window override
(`decoration_override`), `none` to `auto` and anything else to `none`,
back to the config's on the next toggle; the window then resizes so the
tab area, and so the grid, stays as it was (`resizeTabArea`), unless
maximized or fullscreen. The `decorations` scenario checks the frame,
the hit tests through pane, tab and window, and the grid across toggles
from `none`, `auto` and `server`.

**4.5 Tab drag and tear-off, L.**
- Drag to reorder, with live feedback.
- Drop outside to tear off into a new window, or onto another window's strip
  to move it there.
- `move_tab_to_new_window`.

A tab moves as a whole split tree by reparenting its container (spike S5).
Emptied windows close through the request queue.

*Done 2026-10-27:* a press on a tab arms a drag (`Window.tab_drag`, the
mouse captured); past the system's drag distance the tab takes the place
of each tab it passes along the strip, live. Released more than a row's
height from the strip, it moves onto the title bar or tab row of the
murrtty window under the mouse (at the place its position gives), or,
outside its own window, into a new window of the default size, as GTK's
new window, with its first tab under the mouse inside that monitor's
work area (`tearOff`; nothing for a window's only tab, as GTK's
`move_tab_to_new_window`); dropped on its own terminal, nothing. The
drag keeps the tab pressed, not its place: in review, a tab closed
during a drag (a middle click, a process ending) left a stale index that
panicked in Debug and would have crashed the release build
(`tab-drag-close` checks it).
`moveTabTo` takes the tab out, reparents its container (`adoptTab`: the
panes' window pointers, DPI and translucency follow), and a window it
leaves empty hides and closes through the request queue.
`move_tab_to_new_window` is the same move from a binding, and the tab
menu's item (grayed for a lone tab). Window.create is now `createEmpty`
plus a tab plus `show`. The `tab-drag` scenario drags by posted mouse
messages: the live reorder before the release, a tear-off (the new window
under the mouse, the container its child, the pane typing and presenting
frames), a drop onto another window's bar, the emptied window closing,
and the binding. Not built: an image of the tab following the mouse
while it is out of the strip (libadwaita drags the tab itself), and
Escape cancelling a drag.

**4.6 Window options, S each.**
- `window-position-x`/`-y`, with cascading for later windows.
- `window-step-resize` (`cell_size`, snapping in `WM_SIZING`).
- `float_window` (always on top), `reset_window_size`.
- The missing cursor shapes as `.cur` resources.
- `window-vsync`.

*Built 2026-10-27, as macOS has them (GTK has none):*
`window-position-x`/`-y` put every new window's visible frame (DWM's,
inside the resize border) there, as macOS does rather than cascading
later windows; off every monitor, the window moves into the nearest work
area (`placeAsConfigured`, before the first pane, so it opens at that
monitor's DPI; `move_tab_to_new_window`'s window too).
`float_window` (`toggle_window_float_on_top`) makes the window topmost
and back (`setFloat`, from the window's actual state, which another
program may have changed; Windows may refuse silently, and does on the
hidden desktop). `reset_window_size` restores, if maximized, and sizes
the window to what a new window would get for its focused pane (the
pane's latest `initial_size`, which the core sends again when the font
size changes, as macOS keeps it per terminal; else the default; nothing
when minimized or fullscreen). `window-step-resize` cuts a window being
resized (`WM_SIZING`) so the focused pane's grid fills its tab area in
whole cells, only along the sides dragged (`split_layout.snapToCells`). The `window-options` scenario checks each
(the drag through a test hook that sends `WM_SIZING` inside murrtty).
Not built: `window-vsync`, which murrtty ignores as GTK does (DWM
composes windowed GL without tearing; a swap interval of 1 only adds
latency), and the missing cursor shapes, which need artwork.

---

## Phase 5: Desktop integration (about 10 to 12 weeks)

**5.1 Single instance and IPC, L.** A per-user, per-session named pipe.
- Security: a DACL for the current user only, created with
  `FILE_FLAG_FIRST_PIPE_INSTANCE`. Pipe names are machine-global, so the
  client also verifies the server process's user SID
  (`GetNamedPipeServerProcessId`) before sending; otherwise another local user
  could squat the name and receive forwarded commands.
- The name includes the integrity level, so elevated and non-elevated
  instances stay separate. A client that finds no instance at its level starts
  one.
- `ghostty +new-window`, `+new-tab` and `+toggle-quick-terminal` forward to the
  running instance, with command, directory and title overrides passed
  through `Window.create` into `Surface.init`.
- Requests enter the App request queue, so they wait for dialogs.
- Also: a taskbar Jump List with New Window, and `--class` scoping.

*Done when:* `ghostty +new-window -e pwsh` opens in the running instance and
exits 0.

*Built 2026-10-27 (`win32/ipc.zig`):* the first murrtty of a class
listens on `\\.\pipe\<class>.<user SID>.<session>.<integrity RID>` (the
class is `class`, else `murrtty`, `murrtty-debug` in Debug builds as GTK's
application id). It claims the name as it starts, before any hand-off, so
of two launches together one holds it; a thread of its own then always
keeps one instance listening, so the name never lapses while it runs; one
that finds the name taken tries again every 3 s and takes over when the
holder quits. The pipe has `FILE_FLAG_FIRST_PIPE_INSTANCE`, the user as
its owner, a protected DACL for the user alone, a mandatory label at the
instance's integrity level that keeps lower ones from writing or reading,
and `PIPE_REJECT_REMOTE_CLIENTS`; the server serves only clients in its
session. A client connects at identification level and sends only after
checking the pipe itself (`GetSecurityInfo`: owned by its user, labeled at
its level or above, which no other user or lower process can arrange) and
then its server (`GetNamedPipeServerSessionId`, and the process of
`GetNamedPipeServerProcessId`: its user, in its session, at no lower
level). A request is a small versioned message (kind, surface id, the
CLI's arguments) answered with one byte as soon as it is queued (a locked
queue the UI thread takes from on a wake message that carries nothing,
since any process on the desktop can post one): it enters `App.request`,
so it waits for any dialog, and the CLI exits 0. Its arguments are read
as GTK's `Overrides` reads them (`-e`, `--command=`,
`--working-directory=`, `--title=`, `--shell-integration=`; `home` is
resolved there, and `inherit` keeps the caller's directory, which the CLI
passes first) and reach the first pane `Window.create` or `addTab` makes
through `App.ipc_overrides`, which `Surface.init` takes (with GTK's shell
integration rule for a command; the command also wins over
`initial-command`). `+new-tab` goes to the window of the pane its surface
id names, else the focused one's, else a new window, as GTK, and brings
it forward. `+toggle-quick-terminal` waits for 5.7. With no murrtty
serving the class, the CLI starts one as a desktop launch would (in the
home directory, with the user's own environment from
`CreateEnvironmentBlock`, not the shell's), with `MURRTTY_IPC_LAUNCH` set:
it opens no window of its own, takes the request's, and quits after 15 s
if none comes, or if the request leaves it without a window (it doesn't
pass the variable on). `gtk-single-instance` now works on Windows: with it
on, a launch hands its window to the running murrtty and exits; `detect`
means on for a desktop launch (a shortcut or Explorer) without arguments,
since Windows' shells and terminals don't set `TERM_PROGRAM`. The taskbar's
Jump List gets New Window, GTK's desktop action
(`--gtk-single-instance=true`), from a release build of murrtty's own class
once it listens (`win32/jump_list.zig`). `open_config:new_window` came with
it: the config file in a new window running `$VISUAL` or `$EDITOR`, titled
as GTK's. Scenarios `ipc`, `ipc-launch`, `single-instance` and
`open-config-window` check them, each with a class of its own; while the
test hooks are on, a murrtty's default class is its own
(`murrtty-test-<pid>`), so test instances never reach each other or a
developer's.

**5.2 Desktop notifications, M then L.**
- First `Shell_NotifyIconW` balloons on an app notification-area icon (added
  here, reused by the tray in 5.6). They show as toasts on Windows 10 and 11.
  Titles are cut to 63 characters and bodies to 255, and a click presents the
  pane of the most recent notification (balloons carry no per-notification
  id).
- Later, WinRT toasts with an AppUserModelID, for Action Center history and
  withdrawal on focus.

*Done when:* an OSC 9 or OSC 777 notification appears, and clicking it brings
the pane forward.

*First step built 2026-10-27 (`win32/Notifications.zig`):* the
`desktop_notification` action (the core has checked
`desktop-notifications` and limits the rate) shows a balloon of a
notification-area icon on a hidden top-level window of its own, as a
toast (`NIIF_USER` with the large app icon, `NIIF_RESPECT_QUIET_TIME`). A
notification with no title is murrtty's, as GTK's is Ghostty's. The icon
stands for the latest notification and lives as GTK's notifications do:
it comes with one and goes when that one's pane gets the keyboard or
closes, 3 s after it came if that pane had the keyboard, or when the toast
or the icon is clicked, which presents the pane from the message loop once
no dialog is open (an `App.Request`); a toast that times out stays in the
notification center with the icon. Adding falls back to changing and the
reverse, so murrtty's idea of the icon can't drift from Explorer's for
good; `TaskbarCreated` (Explorer restarting, the taskbar rebuilt) puts a
pending icon back at the current DPI, and murrtty's message filter lets
it and the icon's messages reach an elevated murrtty. A click that comes
during a call to Explorer waits for it to return. The `notifications` scenario
checks it all through the test hooks, which record notifications instead
of showing them (the hidden desktop has no notification area, and the
user's would show them); the opt-in `notify-shown` shows one for real and
checks Windows took it. Not tested: a person's click on a real toast. The
second step, WinRT toasts, is still to come.

**5.3 Command-finished notifications, S.** Port GTK's
`notify-on-command-finish` logic (never, unfocused or always; minimum
duration; bell or notify). Needs 2.2 and 5.2.

*Built 2026-10-27 (`App.commandFinished`), as GTK's:* the core's
`command_finished` (shell integration's OSC 133;D after its 133;C, so
PowerShell's, not cmd's, which sends no C) notifies or rings the bell
(`notify-on-command-finish-action`; the bell as `ring_bell` rings it) for
a command that took longer than `notify-on-command-finish-after`, when
`notify-on-command-finish` is `always`, or `unfocused` and the pane lacks
the keyboard, or the pane's Notify on Next Command Finish is set: the
terminal menu's check item (no longer grayed), which the next command
clears. The notification is "Command Succeeded", "Command Failed" or
"Command Finished" with GTK's "Command took 2s 47ms and exited with code
0.". The Config submenu's Open Configuration in New Window works too
(5.1 built it). The `command-finished` scenario checks it.

**5.4 Taskbar progress, M.** OSC 9;4 drives `ITaskbarList3` (normal, error,
paused, indeterminate) for the window's active tab, plus a thin in-pane bar
through 3.0. A stale report clears after 15 s, and `progress-style = false`
disables it. Use `ITaskbarList3` only after the registered
`TaskbarButtonCreated` message arrives, and re-apply state when it arrives
again after an Explorer restart; an elevated instance must allow the message
with `ChangeWindowMessageFilterEx`.

*Built 2026-10-27 (`Surface.setProgress`, `win32/taskbar.zig`):* GTK's
setProgressReport, as a present-pass bar over the pane: libadwaita's
`osd` bar, 3 px per 96 DPI at the top, in the accent (`#3584e4`) to the
value (a first report with none, an empty bar), or the error color at
half opacity after an error report (GTK's `error` class: only a set
clears it, so it outlasts the bar's removal); with no value a block a
fifth wide, starting at the left, that moves a tenth a report, bouncing,
as GtkProgressBar's pulse. It follows the pane's size, and is drawn under
the dimming and the bars' shade, as GTK's overlays lie. The window's
taskbar button shows its active tab's focused pane's
(`Window.syncProgress`, from `syncTitle`, which every change of tab or
focused pane runs), in the last report's state as Windows Terminal shows
it: normal, error, paused or indeterminate through `ITaskbarList3`, made
when a `TaskbarButtonCreated` arrives (allowed through to an elevated
murrtty; tried again at the next while it can't be made), and shown
again whenever one does. No report for 15 s removes it;
`progress-style = false` shows none. The `progress` scenario checks the
bar's pixels (also after a resize) and what the button would show (the
hidden desktop has no taskbar); the opt-in `taskbar-shown` checks a real
button takes it.

**5.5 Global keybinds, M.** `global:` bindings via `RegisterHotKey`, calling
the core's `performAllChainedAction`. Re-register on config change and
keyboard layout change; report conflicts clearly. Includes `toggle_visibility`
(hide and restore all normal windows), allowed only while a global binding or
the tray (5.6) exists, so the process can never become unreachable.

*Built 2026-10-27 (`win32/GlobalKeys.zig`):* each `global:` binding is a
hot key of the wakeup window (`RegisterHotKey` with `MOD_NOREPEAT`),
registered once any hand-off to a running murrtty is past (a launch that
hands its window over takes none), after a config change and when the
keyboard layout changes (`WM_INPUTLANGCHANGE`). Its key: the keypad's by
their own virtual keys (a scan code gives the navigation key's), other
physical keys by scan code (`MapVirtualKeyW`), letters and digits by their
own virtual keys on every layout, other characters where the layout types
them (`VkKeyScanW`, with the Shift or AltGr it takes). `WM_HOTKEY` is
matched by its modifiers and key, looks the trigger up in the config as it
is then and runs a copy of the actions through the core's
`performAllChainedAction`, as the core runs a global binding; one pressed
while a dialog is open runs when it closes. One that can't be had is told
once per config, as GTK's notification is ("Global keybind unavailable",
"Ctrl+Shift+Alt+F10: Windows or another program already uses it."):
another program holds it, Caps Lock or Num Lock in it, a keypad key
Windows can't tell from another (Enter, the navigation keys), no key types
the character, two of murrtty's own on the same keys. Windows doesn't say
who holds a key, so while another murrtty runs on the desktop (a separate
instance) murrtty keeps quiet and tries again every 3 s: it takes the key
when that one quits, or tells then if something else still has it.
`toggle_visibility` follows macOS (GTK lacks it): with murrtty in front it
hides the windows, recording them and the one in front; otherwise it
brings murrtty forward, showing those windows as they were, all above
other programs with the one that was in front first. Presenting a window
(a notification's click, the pipe's request), opening one, maximizing or
restoring one shows them too, as unhiding does on macOS.
It hides only while a global binding with `toggle_visibility` exists, and
the windows come back when a config change leaves none; menus and the
palette don't offer it. The `global-keys` scenario posts `WM_HOTKEY` with
the dump's modifiers and key (no real key reaches the user's foreground),
holds a combination itself to see the refusal, and fakes murrtty being in
front (dump wparam 16), since on the hidden desktop the foreground window
is always the user desktop's.

**5.6 Tray and background mode, M.** A persistent tray icon (New Window,
Quick Terminal, Configuration, Quit), reusing 5.2's notification-area icon,
that makes `quit-after-last-window-closed`, its delay, and
`initial-window = false` safe to honor (decision 4).

**5.7 Quick terminal, L.** Needs 5.5 and 5.6. A topmost, borderless window
with no taskbar button:
- Placed per `quick-terminal-position`, `-size` and `-screen`.
- Slides in and out with timer-driven moves (never resizes) over
  `quick-terminal-animation-duration`.
- `autohide` on deactivation; tabs allowed.
- Lifecycle: the app stays alive while the quick window exists and a global
  toggle or the tray is registered; `goto_window` skips the quick window.

Toggled by a global key (5.5), the tray (5.6) or IPC (5.1).

**5.8 Drag and drop onto a terminal, S.** Files from Explorer paste as quoted
paths, and text pastes, both through the core's paste path (bracketed paste
applies).

**5.9 Selection clipboard, S.** An in-process selection buffer, so
`copy-on-select`, middle-click paste and `paste_from_selection` work between
Ghostty terminals (Windows has no primary selection).

**5.10 Session end and restore, S then L.**
- `WM_QUERYENDSESSION` with a shutdown block reason when sessions are running.
- Then `window-save-state`: windows, placement, tabs, split trees and
  directories as JSON under `%LOCALAPPDATA%`, with `RegisterApplicationRestart`
  for the `default` policy. State is written on change and on `WM_ENDSESSION`,
  since a crash gives no exit hook; `RegisterApplicationRestart` only
  relaunches the process.
- The owner built session restore on a Linux Ghostty fork of their own
  (noted 2026-10-27). That fork is internal to their employer and can't be
  read or copied: before starting, ask the owner to describe its design
  (what is saved, the state format, the restore policy) and follow it
  where Windows allows.

**5.11 Undo and redo of closes, L.** Keep closed panes, tabs and windows
parked (hidden, process running) until `undo-timeout`. Undo and redo enter
the request queue. This is macOS-only upstream and needs care with the close
invariant.

**5.12 Terminal inspector, L.**
- An inspector window with its own WGL context and the Dear ImGui OpenGL 3
  backend, which is already built for non-Darwin targets.
- `export_terminal_io` through a save dialog.

Remove 0.2's override for `Ctrl+Shift+I`.

---

## Phase 6: Platform quality (parallel, about 2 to 4 weeks, plus 6.4)

**6.1 DirectWrite fonts, L.** After 0.9's style matching: a DirectWrite
discovery backend that keeps FreeType rasterization, with family matching,
registry-installed fonts, and locale-aware fallback via
`IDWriteFontFallback::MapCharacters`. *Done when:* Japanese falls back to a
Japanese UI font on ja-JP, and fonts installed under a registry path are
found.

**6.2 Physical keyboards and IMEs, M.** A first pass is in M1, right after
Phase 1, because non-US users cannot work if `@`, `{` or `[` mistype; a
re-run is in M3. A manual matrix:
- US-International, German, French, Polish and UK layouts.
- Japanese, Chinese and Korean IMEs.
- The emoji panel, voice typing, Alt+Numpad and the on-screen keyboard.

Fix what turns up. One bug is already known: Left Ctrl+Left Alt producing text
is not treated as AltGr, so German `Ctrl+Alt+Q` does not give `@`. Also answer
`WM_IME_REQUEST` (`IMR_QUERYCHARPOSITION`, `IMR_COMPOSITIONWINDOW`) for
TSF-based IMEs; candidate placement through `ImmSetCompositionWindow` already
works. *Done when:* every row types correctly in pwsh
and nvim, and the README entries move to tested.

*Found and fixed 2026-10-26 (owner's report: Ctrl+Insert didn't always
copy):* with NumLock off the numpad's keys typed digits. Windows sends the
navigation key's virtual key (VK_INSERT for 0/Ins) with the keypad's
scancode, and murrtty reported the physical key (`numpad_0`), which the
core encodes as a digit, so Ctrl+Ins there typed `0` and cleared the
selection, and the numpad's arrows typed 8, 2, 4 and 6. It now reports
the keypad's navigation key (`numpad_insert`, `key.remapKeypad`), as GTK
does from the keysym. A numpad navigation key without a binding of its own
also takes its dedicated key's (`Binding.Set.getEvent`, a shared-code
change), so the numpad's Ctrl+Ins copies and Shift+Ins pastes, as in other
Windows apps. Scenario `copy-keys` copies a double-clicked word ten times
each with Ctrl+Insert, the numpad's Ctrl+Ins and Ctrl+Shift+C, moves with
the numpad's Left and pastes with its Shift+Ins.

**6.3 OpenGL fallbacks, M.**
- Diagnose failures: no driver, Remote Desktop, the basic display adapter or an
  old driver. Show a specific TaskDialog.
- Load `opengl32` dynamically so a bundled Mesa llvmpipe can serve as an
  opt-in software renderer.
- Recover from GPU driver resets.

Spike S6 informs the ARM64 story.

**6.4 Accessibility, XL.** A UI Automation text provider (`ITextProvider`,
`ITextRangeProvider`) so Narrator and NVDA can read the terminal, with
selection and text-changed events. Windows Terminal's `UiaTextRange` is the
reference design. Critical for screen-reader users.

**6.5 Small fidelity items, S each.**
- The system double-click time and wheel-scroll lines.
- HTML on the clipboard for `copy_to_clipboard` mixed and html.
- `show_on_screen_keyboard`.
- A `secure_input` badge.
- Version numbers: fill in `FILEVERSION`, `PRODUCTVERSION` and `FileVersion`
  in the existing version resource (`dist/windows/ghostty.rc`).
- `+validate-config` exited 1 and printed nothing for a valid config when
  its output was a pipe (PowerShell capturing it), and likely a console
  (not checked); into a file it exited 0. *Found and fixed 2026-10-26.* It ended its output with
  `stdout_writer.end()`, which also sets the file's length while std's
  writer is still positional, as it is when nothing was written (a valid
  config): that fails for a Windows pipe. Once something is
  written to a pipe the writer turns streaming and skips it, so an invalid
  config already printed its problems and exited 1 correctly. It now only
  flushes (`cli/validate_config.zig`, a shared-code change). Scenario `cli`
  (the harness's `runCli` puts stdout on a pipe) checks `+version` and both
  exit codes; it failed before the fix.

**6.6 Bare command names, S.** `Command.zig` starts the shell with a null
`lpApplicationName`, so for a bare name Windows searches Ghostty's own
folder and the current directory before the system folders and `PATH`.
`command = pwsh` (or upstream's old default, `cmd.exe`) can therefore run a
same-named program planted in the folder Ghostty started in, which, started
from a shell, is that shell's folder. The defaults name full paths since
2.5. Resolve a bare name in `Command.zig` with a `PATH` search that skips
the current directory (honoring `PATHEXT`, fixed drives only as
`default_shell.findPwsh` does) and pass the full path as
`lpApplicationName`; a name with a path separator keeps today's behavior.
*Done when:* a `cmd.exe` planted in the starting folder doesn't run for
`command = cmd.exe`, and `command = pwsh -NoLogo` still starts PowerShell 7.
Small and security-related, so it can land with any phase rather than
waiting for M3.

---

## Phase 7: Release engineering (about 3 to 7 weeks, finished for M3, plus 7.8)

History hygiene and minimal CI moved to Phase 0 (0.10, 0.11), since the fork
takes in upstream many times before M3.

**7.1 Upstream merges, S each.** Merge Ghostty's `main` per upstream
release (see "The fork"): build, unit tests and the GUI suite on a
`merge/<date>` branch before it lands. *Replaced 2026-10-26:* this was a
proposal to upstream an `else => void` default for the GTK-only runtime
switches, which no longer applies.

**7.2 Full CI, M.** Extend 0.11: run on pushes and pull requests (once
decisions 6 and 8 allow the minutes), upload
artifacts, add the GUI suite (7.3), the ARM64 build (7.7) and the release job
(7.4).

**7.3 GUI tests in CI, L.** Run 0.8's harness, with its test-hook state dump,
on a runner. Put a pinned Mesa llvmpipe `opengl32.dll` next to the
`ghostty.exe` under test (or load it through 6.3's dynamic loader), not next to
the harness: the process that loads OpenGL is the one that needs it. *Done
when:* the suite runs in under 5 minutes and fails on an injected
free-inside-callback bug.

**7.4 Packaging and signing, L.**
- A zip of `bin` plus `share` (themes, shell integration, terminfo), LICENSE
  and complete third-party notices (FreeType, HarfBuzz and the rest), with
  symbols in a separate zip.
- winget: a portable zip, with the folder added to PATH.
- A per-user Inno Setup installer: Start menu shortcut with an AppUserModelID,
  "Open Ghostty here", and a `.ghostty` file association.
- Authenticode signing; SmartScreen reputation takes time.

**7.5 Crash reporting, M.** Sentry's in-process (`inproc`) backend on Windows:
- `src/build/SharedDeps.zig` hardcodes the `breakpad` backend, and the vendored
  breakpad build compiles only the Apple and Linux clients. Select `inproc`
  for Windows there.
- `-Dsentry` defaults off outside macOS (`src/build/Config.zig`); default it on
  for Windows release builds.
- `SetThreadStackGuarantee` on Ghostty's threads, so stack overflows are
  still reported.
- Publish PDBs for symbolication. `ghostty +crash-report` lists the local
  reports.

**7.6 Updates, M.** winget is the primary channel. An opt-in check
(`auto-update = check`) reads a static appcast over WinHTTP; downloads are
verified with SHA-256 and Authenticode. The `check_for_updates` action runs the
same check on demand.

**7.7 ARM64, M.** `aarch64-windows-gnu` builds and tests, with the GPU path
decided by S6 and 6.3.

**7.8 Direct3D 11 renderer, XL, future.** A `d3d11` renderer backend with
HLSL ports of the shaders, WARP for GPU-less machines, and native
DirectComposition transparency. It removes the OpenGL 4.3 requirement, which
is expected to be the main cause of start failures (VMs, Remote Desktop,
Windows on ARM).

**7.9 Upstreaming.** *Dropped 2026-10-26 (decision 7):* Ghostty won't take
another runtime. A fix that matters to Ghostty itself can still be offered
upstream on its own, under upstream's `CONTRIBUTING.md` and `AI_POLICY.md`.

---

## Beyond Ghostty: murrtty's own features

Features Ghostty doesn't have, chosen by the owner from Ghostty's wishlist
or as murrtty's own. Each is listed under "Differences from Ghostty's GTK
app" (as decided, not built yet, until it is). None is in a milestone yet.

**F1 Config editor, L to XL.** *Planned 2026-10-26 by the owner.* A
comprehensive GUI for setting configuration options, so users needn't edit
the file by hand. Ghostty has none: its apps open the file in an editor
(`open_config`), and GTK's only config window lists errors. A first sketch:
- **Driven by the shared core's own metadata,** so options added upstream
  appear after a merge without editor work: `Config`'s fields with their
  types and defaults (comptime reflection), each option's documentation
  (the generated `help_strings` module behind `+explain-config`), and value
  formatting (`config/formatter.zig`, behind `+show-config`).
- **Search** across names and documentation; each option's documentation
  beside it; where its value comes from (the file, an included
  `config-file`, or the default); reset to default.
- **Editors by type:** booleans, enums, numbers within their limits, colors
  with a picker, paths with a file dialog; dedicated pages for the hard
  ones: key bindings (capture a chord, show what it replaces or conflicts
  with), themes (`+list-themes`, with a preview and the light/dark pair),
  fonts (`+list-fonts`, styles and features), and the repeatable options
  (`keybind`, `palette`, `font-family`, `command-palette-entry`).
- **Writes the file in place, minimally:** only the lines of changed keys,
  keeping comments, order, repeated keys and includes; it refuses to
  rewrite a file it can't round-trip. It validates with the core's parser
  and shows its diagnostics before saving, then applies with the soft
  reload, marking options that reach only new windows or terminals.
- **Opened from** the context menu's Config submenu, the command palette and
  a key binding.
- **Decisions before starting:** native Win32 controls (no new dependency;
  *recommended*) or WebView2 (quicker to build, a runtime dependency); which
  file it writes while murrtty still uses Ghostty's configuration
  (*recommended:* offer to create murrtty's own file importing Ghostty's
  with `config-file`, leaving Ghostty's untouched); and whether opening it
  is a new core action (a shared-code change) or a Windows-only binding.

*Done when:* every option can be set and reset from the editor, saving
without changes leaves the file byte-identical, and the GUI harness drives
a search, an edit, a key-binding capture and a save.

---

## Appendix A: apprt action coverage

The core can send 70 actions (`src/apprt/action.zig`). At `84e810a3e`
(tag `port/pre-regroup`) the
Win32 runtime handles 26, 8 of them partly, and 44 fall through to the
"unimplemented" branch.

**Handled:**
- quit, new_window, new_tab, close_tab, close_all_windows, close_window
- toggle_maximize, toggle_fullscreen, move_tab, goto_tab, goto_window,
  present_terminal
- size_limit, initial_size, resize_window, render, set_title, mouse_shape,
  mouse_visibility
- renderer_health, open_config, quit_timer, reload_config, config_change,
  ring_bell, open_url

**Partly handled:**

| Action | Gap | Item |
|---|---|---|
| config_change | surface target ignored | 0.4 |
| ring_bell | only `system` and `attention` | 3.7 |
| renderer_health | only logged | 3.6, 6.3 |
| open_config | no editor fallback (0.6), `new_window` variant (3.9) | 0.6, 3.9 |
| quit_timer | ignores `quit-after-last-window-closed` | 5.6 |
| resize_window | not refused when multi-tab, maximized or fullscreen; not clamped | 1.4 |
| mouse_shape | several shapes fall back to the arrow | 4.6 |

**Not handled:**

| Actions | Item |
|---|---|
| new_split, goto_split, resize_split, equalize_splits, toggle_split_zoom | Phase 1 |
| pwd | 2.4 |
| color_change | 0.4 |
| start_search, end_search, search_total, search_selected | 3.2 |
| toggle_command_palette | 3.3 |
| scrollbar | 3.4 |
| prompt_title, set_tab_title, set_window_title, copy_title_to_clipboard | 3.5 |
| mouse_over_link, key_sequence, key_table, readonly, show_child_exited | 3.6 |
| toggle_tab_overview | 3.8 |
| desktop_notification | 5.2 |
| command_finished | 5.3 |
| progress_report | 5.4 |
| toggle_visibility | 5.5 |
| toggle_quick_terminal | 5.7 |
| undo, redo | 5.11 |
| inspector, render_inspector, export_terminal_io | 5.12 |
| selection_changed | 6.4 |
| show_on_screen_keyboard, secure_input | 6.5 |
| check_for_updates | 7.6 |
| show_gtk_inspector | none: GTK-only, keeps returning false |

**Options with no Windows meaning,** to document as no-ops rather than build:
- the `macos-*` options except those folded into items above;
- `linux-cgroup*`, and the `gtk-*` options the Look rule doesn't take
  (4.3 takes `gtk-titlebar`, `gtk-titlebar-hide-when-maximized`,
  `gtk-titlebar-style`, `gtk-wide-tabs`, `gtk-tabs-inverted` and
  `gtk-toolbar-style`, and 5.1 takes `gtk-single-instance`);
- the Wayland quick-terminal layer options;
- `async-backend`, `x11-instance-name`, `window-colorspace`.

**Already working through the core,** with no runtime work needed:
- fonts, colors, themes, palette, cursor options, padding;
- background images and custom shaders;
- clipboard read/write policies and paste protection;
- `copy-on-select = clipboard` and the copy/paste right-click actions;
- mouse reporting, scrollback limits, the `vt-*` options except
  `vt-window-resize-allowed` (see `resize_window` above).
