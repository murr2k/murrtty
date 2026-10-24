# Windows port roadmap

The plan for finishing the native Windows port of Ghostty: what is missing,
in what order to build it, how, and how to tell it is done. It was written
from a read of the code at `84e810a3e` (port) on upstream `22f100c63`,
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
| **M3: Public release** | Phase 7 except 7.8 and 7.9 (upstream-facing upkeep, full CI, GUI tests in CI, packaging, signing, crash reports, updates, ARM64) and the rest of Phase 6 (DirectWrite fonts, the 6.2 keyboard and IME re-run, OpenGL fallbacks, small fidelity items), in parallel with M2 | 5 to 10 weeks, overlapping M2 |
| **M4: Complete** | Session restore (5.10), undo of closes (5.11), terminal inspector (5.12) | about 4 to 5 weeks |

Not in these estimates: a Direct3D 11 renderer (7.8, XL), UI Automation
accessibility (6.4, XL) and upstream review time (7.9). Spikes S1, S2, S3 and
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
   `close_surface` and then rebind it to `close_tab` (`Config.zig:6832-6856`),
   so Windows and Linux have no default key that closes one pane. *Recommended:
   keep upstream's behavior and document `keybind = ctrl+shift+w=close_surface`
   for users who want Windows Terminal semantics.*
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
   pinned taskbar icons.
6. **CI on a private repository.** Actions minutes are billed for private
   repos, and Windows runners count double. *Recommended: a single port-owned
   workflow (0.11, later 7.2), started manually or on release tags at first.*
7. **Upstreaming.** Whether to pursue in-tree support (7.9). It decides how
   carefully history is kept (0.10) and which fixes are written to be
   upstreamable first (Windows `reportPwd`, font style matching).
8. **Visibility.** The repository is private. winget and the update appcast
   (7.4, 7.6) need publicly downloadable artifacts. *Decide before M3* whether
   the repository goes public then, or releases are hosted elsewhere. Going
   public also makes standard Actions runners free, which changes decision 6.

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
- **Ghostty semantics first.** Behavior follows GTK and macOS. Where the two
  differ, or Windows needs something else, the choice is recorded in the port
  README, `.github/README.md` (for example macOS's focus-on-close rule for
  splits).
- **Testable with posted messages.** New UI must be drivable by the GUI
  harness (0.8, run in CI by 7.3) without real input focus, since background
  sessions and CI have none.

## Spikes before committing to a design

| Spike | Question | Decides |
|---|---|---|
| **S1** overlay host, 1 day | Does a child window drawn over a WGL child window stay clean (no flicker, no stale pixels) while output floods and during live resize, on two GPU vendors? | Where text and interactive overlays live (3.0) |
| **S2** transparency, 1 to 2 days, run before 3.0 | Does DWM honor per-pixel alpha from child GL windows when the top level uses `DwmEnableBlurBehindWindow` with an empty region? | Transparency path: cheap (4.1 A) or DirectComposition with `WGL_NV_DX_interop2` (4.1 B, XL). Also whether text overlays (3.0) and the tab strip (3.8, 4.3) can stay GDI, or must become composition visuals, since GDI output does not show on a Phase B window. |
| **S3** ConPTY, 1 day | Does the inbox ConPTY forward OSC 133, OSC 7, OSC 9;9 and DECSCUSR, in order, on Windows 10 22H2 and Windows 11 23H2 to 25H2? | Whether to bundle `conpty.dll` and `OpenConsole.exe` (2.2) |
| **S4** many contexts, part of 1.4 | 16 panes, each flooding output: steady frames, no stale-frame recurrence, linear memory, on two vendors | Whether per-pane contexts scale |
| **S5** reparenting, part of 4.5 | Does a GL child window keep rendering after `SetParent` to another top-level window, on NVIDIA, AMD and Intel? | Tab tear-off design |
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

**0.9 Font style matching, S.** The default `freetype_windows` discovery
checks only family and codepoint (`font/discovery.zig:1157-1165`) and returns
the first file found. Bold Consolas resolves to `consola.ttf`, and italic
Cascadia to the upright face, for anyone who sets `font-family`. Score
candidates on weight, slant (FreeType style flags, OS/2 weight class) and
fixed width, from an index built once. Upstreamable; the DirectWrite backend
stays in 6.1. *Done when:* the log shows the Bold and Italic faces of Consolas
and Cascadia Mono for bold and italic text.

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

**0.11 Minimal CI, M.** One port-owned workflow, started manually: the Windows
build, the Windows unit tests, and the builder under PowerShell 5.1. Before
enabling Actions, disable every upstream workflow: the vouch workflows have no
repository guard and act on every issue. A guard step fails if any other
workflow is active. Phase 7 extends it (7.2).

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

---

## Phase 1: Splits (about 2.5 weeks, plus 1.10 in M2)

The full design is below; the steps land one at a time. Upstream's generic
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
    background darkened 0.4 on dark themes, 0.08 on light ones.
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
| 1.1 | Focus plumbing: deferred core focus callback; `SetFocus` only in the active window. Fixes focus theft by closing a tab in a background window. | S |
| 1.2 | Tab refactor: `Tab.zig` with a one-leaf tree and a container window; every surface iteration site switches to tabs. No visible change; the full tab test set passes. | M |
| 1.3 | `split_layout.zig` with unit tests: tiling, minimums, zoom, hit-testing, drag ratios, resize deltas, focus after close. | M |
| 1.4 | Basic splits: `new_split`, closing panes through the queue (confirm per pane, last pane closes the tab), divider painting, titles from the focused pane, per-pane `size_limit`, `resize_window` refusals and monitor clamping (the multi-tab, maximized and fullscreen refusals fix a current bug and can land early). Removes 0.2's override for `Ctrl+Shift+O`/`E`. Includes the S4 stress run. | M |
| 1.5 | Navigation and commands: `goto_split`, zoom, equalize, `resize_split`, `split-preserve-zoom`, `present_terminal`. Removes 0.2's override for `Ctrl+Shift+Enter`. | S to M |
| 1.6 | Mouse: divider hover cursors, drag, Esc, double-click equalize, window minimum from the tree. | M |
| 1.7 | Renderer: a rectangle list drawn in 0.3's present pass, written by the UI thread and read by the render thread. The dim overlay is its first user; 3.0's shape overlays reuse it. | M |
| 1.8 | `focus-follows-mouse`, deduplicated on screen position so a relayout under a still cursor does not move focus. | S |
| 1.9 | Defaults and docs: check whether the Windows shell or graphics-driver hotkeys intercept the defaults (`ctrl+super+[`, `super+ctrl+shift+arrows`, and `ctrl+alt+arrows`, which some Intel drivers use for screen rotation) and add fallbacks if so; record decision 2; update the README. | S |
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

**2.3 cmd integration, M.**
- Set `PROMPT` in the child environment to wrap the user's prompt with OSC 133
  A/B/D and OSC 9;9. cmd has no pre-execution hook, so there is no 133 C or
  exit code.
- With Clink present, ship a Lua prompt filter that adds 133 C and the exit
  code.

*Done when:* an idle cmd tab closes without asking, and `cd /d D:\x` carries
over to new tabs.

**2.4 Directory fallback without integration, M.** For shells that send
nothing, read the shell process's current directory from its PEB
(`NtQueryInformationProcess`, `ReadProcessMemory` of
`RTL_USER_PROCESS_PARAMETERS.CurrentDirectory`), used only until the first
OSC 7 or 9;9. It works for cmd's `cd`, not for PowerShell's `Set-Location`.
Also handle the `pwd` action to keep a per-surface copy (tooltips, Open in
File Explorer, session restore). *Done when:* with `shell-integration = none`,
cmd's `cd` carries over.

**2.5 Default shell, S.** When `command` is unset, prefer `pwsh.exe`, found
via `SearchPathW`, App Paths or the Store alias, else `%COMSPEC%` (decision
3). *Done when:* a fresh config opens `pwsh -NoLogo` when PowerShell 7 is
installed.

---

## Phase 3: Core Ghostty UI (about 6 to 7 weeks)

The overlays and menus users meet every day.

**3.0 Foundations, M.** Builds on 0.0 (the modal scope, TaskDialog, OLE) and
waits for spikes S1 and S2.
- **Platform bits.** `SetTimer` helpers, and a `<supportedOS>` block in
  `dist/windows/ghostty.manifest` (needed for layered child windows and
  reliable version checks).
- **Overlay layer**, in two parts:
  - Shapes (borders, progress strip, scrollbar thumb) are rectangles in 1.7's
    present-pass list. They survive transparency and have no airspace
    problems.
  - Text and interactive overlays (labels, the search box) are child windows
    over the surface if spike S1 passes, otherwise owned layered popups that
    track the surface. If S2 forces DirectComposition, they become
    composition visuals instead.
  - Either way they attach to the pane's rectangle, so they work per split.
- **Focus target.** `Surface.focusTarget()` returns an open interactive
  overlay's control, and `Window.focusActive` uses it. Search and the palette
  then keep focus across window activation, which 1.1 otherwise hands back to
  the pane.
- **`App.supportsAction`.** One predicate shared by menus and the palette.
  Entries for actions not implemented yet are grayed in menus and hidden in
  the palette.

**3.1 Context menu, M.** The default `right-click-action = context-menu`
only selects a word today, because the runtime ignores the core's consumed
result (`Surface.zig:686-690`). When a right press is not consumed, open
GTK's menu:
- Copy and Paste (grayed when unavailable), Notify on Next Command Finish
  (grayed until 5.3), Clear, Reset.
- Submenus: Split (Split Up, Down, Left, Right, Close Split), Tab, Window,
  Config.

Run it in a modal scope that leaves other windows enabled
(`disable_others = false`) and use dark menus where available. Open it only
from an unconsumed right press, as GTK does. Shift+F10 and the Menu key reach
programs today (the Menu key sends `CSI 29~`), so neither opens the menu;
keyboard access is not scheduled. *Done when:* right-click Copy and Paste
work, and Close Tab chosen from the menu while a dialog is pending frees
nothing early.

**3.2 Search, M.** A search box over the pane's top-right corner: an edit
control, an "n/m" counter and previous, next and close buttons.
- Typing runs the core search with a short debounce. Enter and Shift+Enter
  step; Escape ends the search and returns focus.
- Handle `start_search`, `end_search`, `search_total` and `search_selected`.
  The core's search thread already exists.

*Done when:* `Ctrl+Shift+F` opens and focuses the box, matches highlight with
a counter, and `search_selection` prefills it.

**3.3 Command palette, L.** A popup anchored at the top center of the window:
- A filter box and an owner-drawn list. The entries are
  `command-palette-entry` items, each with its key binding, plus one "focus
  terminal" entry per surface.
- Fuzzy matching, keyboard navigation. Actions run after the palette hides,
  never from inside its window procedure.

Remove 0.2's override for `Ctrl+Shift+P`. *Done when:* the palette filters,
runs actions, and jumps to terminals in other windows.

**3.4 Scrollbar, M.** An overlay scrollbar from the core's `scrollbar` action:
- A thin thumb that widens on hover and fades when idle, drawn through 3.0's
  shape layer so the grid does not shrink.
- Dragging sends `scroll_to_row`; clicking the track pages.
- `scrollbar = never` hides it; `system` follows Windows' "always show
  scrollbars" setting.

*Done when:* the thumb tracks scrollback, dragging scrolls, and alternate-screen
apps show no thumb.

**3.5 Titles, M.** Implement `prompt_title` (surface, tab, window),
`set_tab_title`, `set_window_title` and `copy_title_to_clipboard`.
- Overrides layer over the terminal title: pane, then tab (on `Tab` after
  Phase 1), then window.
- The prompt is a small dialog in a modal scope. Double-clicking a tab
  renames it.

*Done when:* a renamed tab keeps its name while programs set OSC 2 titles, and
clearing the name restores the program's title.

**3.6 Status overlays, M.** Using 3.0:
- the link hover preview (`mouse_over_link`, `link-previews`);
- the resize overlay (`resize-overlay`, default after-first);
- the key sequence and key table indicator;
- the read-only badge;
- the child-exited banner (`show_child_exited`);
- a renderer-unhealthy panel (`renderer_health`);
- in-app toasts (`app-notifications`: "Copied to clipboard" and "Reloaded the
  configuration", both on by default), a bottom-center pill for about 3 s.
  Update the option's documentation, which says it applies only to GTK.

*Done when:* each appears and hides under the same conditions as on GTK.

**3.7 Bell, M.** Implement the `title`, `audio` and `border` bell features
with per-pane ringing state, cleared on focus or input. `title` is in the
default `bell-features`, so its part (S) is in M1; audio and border are M2.
- `title`: a bell glyph on the tab and caption.
- `audio`: Media Foundation playback with `bell-audio-volume`, or `PlaySoundW`
  as a first cut.
- `border`: a border overlay.

*Done when:* a BEL in a background tab marks it until selected, and the audio
file plays at the configured volume.

**3.8 Tab bar, M to L.**
- Right-click menu: Rename, Close, Close Others, Close to the Right, Move to
  New Window.
- Overflow: chevrons, wheel scrolling and a tab list. That list also serves
  `toggle_tab_overview` when `window-show-tab-bar = never`.
- Tooltips with full titles, `window-title-font-family`,
  `window-new-tab-position`, a small icon for high DPI, and the progress and
  read-only indicators (the bell glyph comes from 3.7, the zoom magnifier from
  Phase 1).
- The affordances GTK's header bar shows by default: a menu button at the
  right of the strip opening the main menu (the same items as the system
  menu), a tab-list button, and a dropdown on `+` with Split Right, Down, Left
  and Up once Phase 1 lands.

*Done when:* 40 tabs are all reachable, right-click Close Others works, and
the menu button and `+` dropdown work.

**3.9 Dialog polish, S.**
- Replace `MessageBox` confirmations with TaskDialogs.
- Make the clipboard dialog show the full text in a scrollable monospace box,
  default to Deny, and offer "remember for this terminal" (GTK parity).
- Add Ghostty items and About to the system menu (`Alt+Space`). The system
  menu works even when the tab bar is hidden.
- Add `open_config:new_window` once 5.1's command overrides exist (the basic
  `open_config` fix is in 0.6).

---

## Phase 4: Window chrome and visuals (about 5 to 8 weeks, or 7 to 10 if 4.1 needs Phase B)

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

**4.2 Blur, M.**
- Windows 11 22H2 (build 22621) and later: Acrylic via
  `DWMWA_SYSTEMBACKDROP_TYPE`.
- Windows 10, and Windows 11 before build 22621: the undocumented
  accent-policy call.
- Off when opaque, fullscreen or forced opaque.

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
- Handle maximized insets and auto-hide taskbars.

This is `window-decoration = auto/client`; `server` keeps today's layout.
*Done when:* drag, double-click maximize, Snap Layouts, every resize edge and
the system menu all work at 100% to 200%, on Windows 10 and 11.

**4.4 Decorations, M.** `window-decoration = none` (borderless, resizable,
keeps the shadow) and `toggle_window_decorations` without changing the grid
size. Shares 4.3's non-client code.

**4.5 Tab drag and tear-off, L.**
- Drag to reorder, with live feedback.
- Drop outside to tear off into a new window, or onto another window's strip
  to move it there.
- `move_tab_to_new_window`.

A tab moves as a whole split tree by reparenting its container (spike S5).
Emptied windows close through the request queue.

**4.6 Window options, S each.**
- `window-position-x`/`-y`, with cascading for later windows.
- `window-step-resize` (`cell_size`, snapping in `WM_SIZING`).
- `float_window` (always on top), `reset_window_size`.
- The missing cursor shapes as `.cur` resources.
- `window-vsync`.

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

**5.3 Command-finished notifications, S.** Port GTK's
`notify-on-command-finish` logic (never, unfocused or always; minimum
duration; bell or notify). Needs 2.2 and 5.2.

**5.4 Taskbar progress, M.** OSC 9;4 drives `ITaskbarList3` (normal, error,
paused, indeterminate) for the window's active tab, plus a thin in-pane bar
through 3.0. A stale report clears after 15 s, and `progress-style = false`
disables it. Use `ITaskbarList3` only after the registered
`TaskbarButtonCreated` message arrives, and re-apply state when it arrives
again after an Explorer restart; an elevated instance must allow the message
with `ChangeWindowMessageFilterEx`.

**5.5 Global keybinds, M.** `global:` bindings via `RegisterHotKey`, calling
the core's `performAllChainedAction`. Re-register on config change and
keyboard layout change; report conflicts clearly. Includes `toggle_visibility`
(hide and restore all normal windows), allowed only while a global binding or
the tray (5.6) exists, so the process can never become unreachable.

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

---

## Phase 7: Release engineering (about 3 to 7 weeks, finished for M3, plus 7.8)

Rebase hygiene and minimal CI moved to Phase 0 (0.10, 0.11), since the fork
rebases many times before M3.

**7.1 Upstream-facing upkeep, S.** Propose upstream an `else => void` default
for the GTK-only runtime switches, so a new runtime needs no core edits.

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

**7.9 Upstreaming.** Per upstream's `CONTRIBUTING.md` and `AI_POLICY.md`:
1. A vouch request, then a discussion in the owner's own words.
2. Small, independently useful PRs first: the Exec pipe-handle fix, Windows
   `reportPwd`, font style matching, build enablers.
3. Full libghostty on Windows.
4. The runtime only after parity, with an owner for Windows issues.

Every PR discloses the AI assistance, and its human author can explain every
line.

---

## Appendix A: apprt action coverage

The core can send 70 actions (`src/apprt/action.zig`). At `84e810a3e` the
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
| toggle_background_opacity | 4.1 |
| toggle_window_decorations | 4.4 |
| move_tab_to_new_window | 4.5 |
| cell_size, reset_window_size, float_window | 4.6 |
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
- `linux-cgroup*`, and all `gtk-*` options (their Windows analogs, such as
  `gtk-single-instance` and `gtk-titlebar-style`, are folded into 5.1 and 4.3);
- the Wayland quick-terminal layer options;
- `async-backend`, `x11-instance-name`, `window-colorspace`.

**Already working through the core,** with no runtime work needed:
- fonts, colors, themes, palette, cursor options, padding;
- background images and custom shaders;
- clipboard read/write policies and paste protection;
- `copy-on-select = clipboard` and the copy/paste right-click actions;
- mouse reporting, scrollback limits, the `vt-*` options except
  `vt-window-resize-allowed` (see `resize_window` above).
