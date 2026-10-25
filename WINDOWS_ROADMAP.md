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
   pinned taskbar icons.
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
| **S3** ConPTY, 1 day | Does the inbox ConPTY forward OSC 133, OSC 7, OSC 9;9 and DECSCUSR, in order, on Windows 10 22H2 and Windows 11 23H2 to 25H2? | Whether to bundle `conpty.dll` and `OpenConsole.exe` (2.2). *Run 2026-10-25 on Windows 11 25H2 (build 26200), inbox ConPTY, flags 0 as Ghostty uses:* a child writing text markers with each sequence between them (via cmd `type`, pwsh 7 and Windows PowerShell 5.1) got all of them through: OSC 133 A, B (ST-terminated), C and D;0, OSC 7, OSC 9;9 and DECSCUSR. The OSC 133 marks keep their place in the text; OSC 7, OSC 9;9 and DECSCUSR can arrive ahead of text written before them, which doesn't matter for them. OSC 2 is absorbed and re-sent as OSC 0. Flag 0x8 (passthrough) changed nothing. So no bundling for Windows 11; Windows 10 22H2 and 23H2/24H2 not yet run (the probe needs `STARTF_USESTDHANDLES` with null handles, as `Command.zig` passes, or the child writes to the parent's handles). *Found in 2.2:* ConPTY repaints rows as it renders, line feeds included, and after 133;B (input until 133;C) those line feeds marked output rows as prompt continuation, so `jump_to_prompt` stopped on output. Not reordering: one write arrived in place, and a pause before the prompt changed nothing. The integrations end the prompt with 133;I (input ends with the line) instead. Clearing the screen (`cls`, `Clear-Host`) arrives as a repaint, not an erase, so rows that held a prompt keep their prompt mark. *Found in the mid-phase review:* 133;A's fresh-line moves Ghostty's cursor when it isn't at column 0, which ConPTY never learns of, so its later absolute moves land a row off; the integrations start prompts with 133;P;k=i, which marks the same without moving. |
| **S4** many contexts, part of 1.4 | 16 panes, each flooding output: steady frames, no stale-frame recurrence, linear memory, on two vendors | Whether per-pane contexts scale. *Run 2026-10-24 on NVIDIA (RTX 2070), scenario `stress-panes`:* every pane kept presenting (1,030 to 1,210 frames each in 13 s, Debug build); memory flat while flooding; per added pane 4 threads, 31 MB resident, 90 MB committed, 64 MB of it Zig's thread stacks (0.15). They scale. AMD and Intel not yet run. *Re-run 2026-10-25 at the end of Phase 1 (15 panes dimmed by 1.7's overlay):* the slowest pane presented 994 frames in 13 s; memory per pane unchanged, and 49 MB of growth in 15 s of flooding (scrollback). |
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
folder (the profile goes in the scenario's folder).

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
- *GTK, observed:* modal, dimming the window behind; each row shows the
  title with the action name beneath (`prompt_tab_title`) and the binding as
  keycaps; entries the runtime can't perform are hidden. Its per-terminal
  rows read only "Focus: <title>", so terminals with the same title look
  alike: add the tab and window number.

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
  configuration", both on by default), a bottom-center pill for about 3 s
  with a close button; copying an empty selection shows "Cleared clipboard"
  (*GTK, observed*). Update the option's documentation, which says it
  applies only to GTK.

*Done when:* each appears and hides under the same conditions as on GTK.

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
