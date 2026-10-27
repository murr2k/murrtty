# murrtty

<img src="../images/murrtty/icon.png" alt="murrtty icon" width="96" align="right">

**murrtty is a native Windows terminal, forked from
[Ghostty](https://github.com/ghostty-org/ghostty).** It is Ghostty's core
(terminal emulation, fonts, rendering, configuration) with a Win32
application around it, and it diverges from Ghostty where Windows or its own
features call for it.

> Ghostty is created by [Mitchell Hashimoto](https://github.com/mitchellh)
> and the
> [Ghostty contributors](https://github.com/ghostty-org/ghostty/graphs/contributors),
> and most of the code in this repository is theirs. murrtty is not
> affiliated with or endorsed by the Ghostty project. Please report problems
> with murrtty in [this repository's issues](https://github.com/murr2k/murrtty/issues),
> not to Ghostty.

![murrtty running PowerShell on Windows, with two tabs](../images/windows-port/screenshot.png)

## What this is

Upstream Ghostty ships a native macOS app and a GTK app for Linux. On Windows,
upstream builds only `libghostty-vt`, its terminal-emulation library: the full
core did not compile for Windows and there is no application, and Ghostty's
maintainers don't plan to add one. murrtty began as a port that adds the
missing pieces, so that building on Windows
(`zig build -Dtarget=x86_64-windows-gnu`, which `build-windows.cmd` runs)
produces a native `murrtty.exe`:

- **A Win32 application runtime** (`src/apprt/win32/`): windows, tabs,
  keyboard and IME input, mouse, clipboard, DPI scaling and the system theme,
  built directly on the Windows API (mainly `user32`, `gdi32`, `imm32` and
  `dwmapi`).
- **A WGL path in the OpenGL renderer** (`pkg/opengl/wgl.zig`,
  `src/renderer/OpenGL.zig`): each terminal gets an OpenGL 4.3 core context
  on its own window and presents with `SwapBuffers`. Other platforms keep
  their existing EGL and Metal paths.
- **Fixes to Windows-only code in the shared core** that had stopped
  compiling or misbehaved, such as a hang when a terminal closed
  (`src/termio/Exec.zig`).

Everything else (terminal emulation, the parser, fonts and shaping,
configuration, themes) is Ghostty's shared core. murrtty changes it where
Windows needs something else (prompt marks behind ConPTY, the shell's
working directory, shell integration for PowerShell and `cmd`) and where
murrtty names itself: programs see `TERM_PROGRAM=murrtty` and an XTVERSION
of `murrtty`, while `TERM` stays `xterm-ghostty`, so they still get the
capabilities the shared core implements.

murrtty merges upstream Ghostty from time to time instead of rebasing onto
it. It last merged upstream
[`0fe113a35`](https://github.com/ghostty-org/ghostty/commit/0fe113a35)
(October 2026).

## Status

murrtty is early. It has been tested on one machine: Windows 11 Pro
(build 26200), NVIDIA GeForce RTX 2070, at 125% display scaling. Most of the
testing drove the app with key and mouse messages sent to its windows, with
the modifier keys set as held where needed, and checked the results with
window captures, a Debug-build state dump and logs. Those GUI tests are in
`test/windows/gui/` and run with `test\windows\gui\run.cmd`, on a hidden
desktop. murrtty has not yet had much use on a physical keyboard. Every
push runs the unit tests and the GUI tests on a self-hosted runner on the
development machine, in a private mirror of this repository
(`.github/workflows/windows-port-desktop.yml`); the GUI tests need an
OpenGL 4.3 driver, which GitHub's hosted runners lack. A manually started
workflow (`.github/workflows/windows-port.yml`) runs the builder on a clean
hosted Windows runner and then the unit tests.

**Tested and working**

- Shells through ConPTY: PowerShell 7 (the default when installed), Windows
  PowerShell 5.1 and `cmd.exe`, including PSReadLine's colors.
- Shell integration for PowerShell 7, Windows PowerShell 5.1 and `cmd`, on by
  default: murrtty knows where each prompt is (`jump_to_prompt` with
  `Ctrl+Shift+Up`/`Down`; closing at an idle prompt doesn't ask), follows the
  shell's directory (new tabs and splits open there, relative links resolve
  against it), and shows the folder, or PowerShell's running command, as the
  tab title. See `src/shell-integration/README.md`. With
  [Clink](https://chrisant996.github.io/clink/) 1.4.25 or later, cmd also
  reports each command's start and exit status (murrtty doesn't show exit
  statuses yet). Without integration, cmd's directory is still followed by
  reading it from the cmd process.
- Rendering with exact colors, fallback fonts for CJK and symbols, and color
  emoji.
- Typing, Enter, Unicode text entry, mouse selection, copy and paste. On the
  test machine murrtty draws the echo of a key about 1.5 ms after it
  receives the key.
- Ctrl and Alt shortcuts: `Ctrl+C` interrupting a running program,
  `Ctrl+Shift+A`/`C`/`V` to select all, copy and paste, `Ctrl+Insert` to
  copy and `Shift+Insert` to paste (also on the numpad's Ins with NumLock
  off, whose other keys then move as the dedicated ones), `Ctrl+Shift+T`,
  `Ctrl+Shift+W`, `Ctrl+Tab` and `Ctrl+PgUp` for tabs, `Ctrl+Shift+N` for a
  new window, `Alt+F4` to close the window, `Ctrl+Shift+Q` to quit.
- Keys reach console programs whole, as Windows key events, the way
  Windows Terminal sends them (win32-input-mode, which Windows' ConPTY asks
  for): `Shift+Enter` (a new line in PowerShell), `Ctrl+Shift+<letter>`
  and other modified keys arrive with their modifiers. In PowerShell, text
  highlighted with `Shift+arrows` is PowerShell's own selection: copy it
  with `Ctrl+Shift+C` or `Ctrl+C`. (A mouse selection is murrtty's, and
  `Ctrl+Shift+C` copies that.)
- Tabs: a tab strip themed from your terminal colors, new tab (the `+`
  button or a keybinding), switching tabs (clicking or a keybinding), and
  closing a tab (its close button, a middle-click or a keybinding). A
  tab's right-click menu renames it or closes it, the other tabs, or the
  tabs to its right. As in Ghostty's GTK app, the arrow beside `+` splits
  the terminal, and the menu button at the right end opens the main menu
  (copy and paste, windows, tabs, splits, the command palette, the
  configuration, About murrtty, Quit). Tabs that don't fit scroll (the
  chevrons at either end, or the mouse wheel), and the list button beside
  the menu button (or `toggle_tab_overview`) lists the window's tabs with
  a filter box. A tab's tooltip shows its title and working directory.
  These buttons sit in GTK's header bar, which is the window's title bar
  (with the title, and round minimize, maximize and close buttons); the
  tabs get their own row beneath when there are tabs to show.
  `window-decoration = server`, `gtk-titlebar = false` and fullscreen give
  the system's title bar instead, with no header buttons, as GTK has none
  then. `gtk-titlebar-style = tabs` puts the tabs in the title bar instead,
  with the buttons around them, and `gtk-tabs-inverted` puts a tab's close
  button at its start. The title bar casts libadwaita's shade onto the
  terminal (`gtk-toolbar-style` `raised`, or `raised-border` and `flat`).
  The title bar and tabs are in Adwaita Sans, GNOME's interface font
  (bundled, not installed). Menus look like libadwaita's popover menus,
  and the close confirmations, title prompts, clipboard confirmations and
  configuration errors like its alert dialogs. `window-new-tab-position` and
  `window-title-font-family` (the chrome's font) work.
- Splits: `Ctrl+Shift+O` and `Ctrl+Shift+E` split the focused pane right
  and down, a pane closes with its shell (the last one closes the tab), and
  the tab shows the focused pane's title. `Ctrl+Shift+W` closes the whole
  tab, as in upstream's defaults; add `keybind = ctrl+shift+w=close_surface`
  to close just the focused pane, as Windows Terminal does. `goto_split`
  (`Ctrl+Alt+arrows`, and `Ctrl+Shift+[`/`]` for the previous and next
  pane), `toggle_split_zoom` (`Ctrl+Shift+Enter`, with a magnifier on the
  tab), `resize_split` (`Ctrl+Shift+Win+arrows`) and `equalize_splits`
  work, dividers can be dragged with the mouse (Esc cancels a drag, a
  double-click equalizes), unfocused panes are dimmed
  (`unfocused-split-opacity`, `unfocused-split-fill`), and
  `focus-follows-mouse` focuses the pane under the mouse. New panes and
  tabs open in the shell's current directory (see shell integration above).
- Close confirmations. With shell integration, closing a tab, pane or
  window at an idle prompt doesn't ask and a running command does. Without
  it (another shell, or PowerShell started with a command) murrtty can't
  tell an idle prompt from a running program and asks whenever the shell is
  still running. Set `confirm-close-surface = false` to turn this off.
  The dialogs use GTK's wording ("Close Tab?", "Quit murrtty?").
- Clipboard confirmations (`clipboard-read`/`clipboard-write = ask`, and
  paste protection) as in GTK: the whole text in a scrollable box, Deny by
  default, and for OSC 52 "Remember choice for this split". A burst of
  requests is confirmed one dialog at a time.
- The system menu (`Alt+Space`, or the window icon) adds New Window, New
  Tab, Split, Command Palette, Config, About murrtty and Quit.
- Configuration errors: a dialog lists them at startup and after a reload,
  with Open Configuration, Reload and Ignore; reloading (`Ctrl+Shift+,`)
  applies a fixed file.
- Links (`Ctrl`+click a URL or an OSC 8 hyperlink). Web and mail links,
  folders, and files of plain data types (text, source code, images, media,
  PDF) open. Links from terminal output to programs, scripts, shortcuts,
  network paths or a few abused protocols are blocked, with the reason.
  Other files and protocols ask first, naming the program that would open
  them. Relative paths resolve against the shell's directory once murrtty
  knows it (shell integration, or cmd's own), and are blocked otherwise.
  `file://` links that name this computer (as `ls --hyperlink` writes them)
  open like local paths.
- Resizing, the initial size from `window-width`/`window-height`, closing
  windows and tabs cleanly, quitting when the last window closes.
- The resize overlay: a pane shows its grid size ("120 x 34") while it
  resizes (`resize-overlay`, `resize-overlay-position`,
  `resize-overlay-duration`).
- The right-click menu, as in Ghostty's GTK app: Copy, Paste, Clear, Reset
  and Split, Tab, Window and Config submenus, each entry with its key
  binding; entries murrtty can't perform yet are grayed. A right-click
  selects the word under the mouse first; a program using the mouse gets
  the click instead. `right-click-action = copy-or-paste` (copy if there is
  a selection, otherwise paste, as in Windows Terminal) or `paste` replace
  the menu. Menus are dark when Windows apps are.
- Search (`Ctrl+Shift+F`): a box over the pane's top-right corner. Typing
  highlights the matches and counts them ("2/6"); `Enter` or `Ctrl+G` (and
  the up button) goes to the next match up the screen, `Shift+Enter` or
  `Ctrl+Shift+G` (and the down button) back down; `Esc` or the close button
  ends the search. `search_selection` (unbound by default on Windows) opens
  it with the selected text.
- The command palette (`Ctrl+Shift+P`): every command murrtty can perform
  (the `command-palette-entry` list), each with its action and key binding,
  and a "Focus:" entry for each terminal in every window that says where it
  is ("Window 2, tab 1: C:\src"). Typing filters by title, by the line
  beneath it, or by letters in order; `Up`/`Down` choose, `Enter` or a
  click runs, `Esc`, a click outside or `Ctrl+Shift+P` again closes.
- Renaming, as in Ghostty's GTK app: a tab (the context menu's Tab >
  Change Tab Title..., or `prompt_tab_title`; murrtty also renames a tab
  you double-click), a terminal (`prompt_surface_title`) or a window
  (`prompt_window_title`, `set_window_title`). A name stays while programs
  set their titles; a blank one restores theirs. A window's name is its
  caption, so the taskbar shows it too (GTK's header bar shows it, its
  window list the tab's title). `copy_title_to_clipboard` copies the title.
- Ghostty's status overlays: the URL under the mouse (`link-previews`), a
  "Read-only" badge (`toggle_readonly`), the key sequence and key tables in
  progress, a banner when the program ends ("Command Succeeded" or "Command
  Failed", with Close; it stays after a quick failure, see
  `abnormal-command-exit-runtime`, or with `wait-after-command`, and
  otherwise the terminal closes), a panel if the renderer fails, and toasts
  for copying and for reloading the configuration (`app-notifications`).
- The bell's `title` feature: a 🔔 before the tab's title and the caption
  when a terminal rings while it doesn't have the keyboard, until it gets
  the keyboard, a key or a click; and a mark on a background tab until you
  select it.
- An overlay scrollbar, as in Ghostty's GTK app: a thin thumb at the right
  edge shows while you scroll or move the mouse, widens under the mouse,
  drags, and pages with a click on the track; it fades when idle (not when
  Windows is set to always show scroll bars). `scrollbar = never` turns it
  off. Programs on the alternate screen have no scrollback, so no thumb.
- While the search box or the palette has the keyboard, the application
  shortcuts still work, as in Ghostty's GTK app: new tab, window or split,
  close, copy, paste, clear, reset, the palette, and the config's.
- CLI actions such as `murrtty +version` print to the console they were
  started from.
- Transparency: `background-opacity` below 1 lets the desktop show through
  the terminal's background, while the header bar, tabs and dividers stay
  opaque, as in Ghostty's GTK app; `toggle_background_opacity` turns every
  window opaque and back, as on macOS. Tested by reading back what murrtty
  draws, alpha included; what the display shows was checked on NVIDIA
  (spike S2), not yet on AMD or Intel.
- `window-decoration = none`: no title bar, still resizable from every
  edge, with Windows' shadow and rounded corners; and
  `toggle_window_decorations`, per window as in Ghostty's GTK app, which
  keeps the terminal's grid.

**Implemented but not yet tested**

- Background blur (`background-blur`) behind a translucent background:
  Acrylic in the active window on Windows 11 22H2 and later, otherwise a
  plain blur (Windows draws Acrylic solid in inactive windows). The tests
  check that it is applied, not yet how it looks.
- AltGr layouts, dead keys, IME composition (preedit and candidate window
  placement).
- Moving tabs (`Ctrl+Shift+PgUp`/`PgDn`), jumping to a tab (`Alt+1` to `Alt+8`, and `Alt+9` for the last tab), closing
  the other tabs or the tabs to the right (no default keys: bind
  `close_tab:other` or `close_tab:right`).
- Opening the config file (`Ctrl+,`) in the editor registered for it, else
  Notepad. The GUI tests check the request, not the editor appearing.
- Precision touchpad scrolling, mouse pointer shapes and hiding the pointer
  while typing, moving a window between monitors with different DPI.
- Title bar and tab colors (`window-theme`), as in Ghostty's GTK app:
  by default Adwaita's light or dark colors, by the configured background;
  `ghostty` uses `window-titlebar-background`/`-foreground` (or the
  terminal's colors); `system` follows Windows' light or dark setting;
  `light` and `dark` are Adwaita's. An inactive window's title bar dims,
  as libadwaita's does. The system's caption, where it shows, takes the
  same color on Windows 11.
- Fullscreen (`Ctrl+Enter`), maximize, `window-show-tab-bar`, the bell's
  `system` and `attention` features, and paste protection.

**Not implemented yet**

- Terminal inspector, quick terminal, desktop notifications.
- Dragging tabs with the mouse, and moving a tab to a new window. Dragging
  panes to rearrange splits.
- Sending commands to an already running instance (`murrtty +new-window`).

[WINDOWS_ROADMAP.md](../WINDOWS_ROADMAP.md) is the plan for the rest, starting
with the rest of the window chrome (Phase 4: tab dragging next).

**Known issues**

- In a debug build, under bursts of synthetic input combined with the first
  load of a fallback font, the window twice kept showing an older frame until
  it was resized, even though the renderer was presenting new frames. It has
  not been reproduced since, including in release builds.
- Output of CLI actions run from `cmd` or PowerShell appears after the prompt
  returns, because shells don't wait for GUI programs to exit.
- After `cls` or `Clear-Host`, `jump_to_prompt` can stop on blank rows where
  prompts were: ConPTY clears the screen by repainting it, and the rows keep
  their prompt marks.
- In shells whose directory murrtty can't see (PowerShell without its
  integration, WSL, ssh), new tabs open where the first one started, and
  relative links are blocked. Inside cmd, a program that changes its own
  directory (a nested PowerShell, say) still has relative links resolved
  against cmd's.

## Requirements

- Windows 10 version 1809 or newer, or Windows 11, on x64. Windows 11 on ARM64
  should run the x64 build under emulation, but this has not been tested.
  Windows 10 on ARM cannot run x64 programs.
- A GPU driver with OpenGL 4.3 support. Most GPUs from the last decade have
  it; virtual machines and Remote Desktop sessions often don't. Without it
  murrtty shows an error message and exits.

To build you also need an internet connection for the first build. Git is
optional: without it, or in a source tree that isn't a git checkout, the
version reads `<version>-dev+0000000` (pass `-Dversion-string=X.Y.Z` to set
it). Visual Studio and the Windows SDK are **not** needed: the build uses
Zig's bundled MinGW-w64 toolchain.

## Build

```powershell
git clone https://github.com/murr2k/murrtty
cd murrtty
.\build-windows.cmd
```

Clone into a short path, such as `C:\src\murrtty`: some files in the
repository and in the Zig toolchain have long names.

`build-windows.cmd` runs `build-windows.ps1` with the Windows PowerShell 5.1
that ships with Windows, from `cmd`, PowerShell or a double-click. It:

1. Checks that the system is a supported 64-bit Windows.
2. Looks for the Zig version this source tree requires (read from
   `build.zig.zon`, currently 0.17.0) in the `ZIG` environment variable (the
   full path to `zig.exe`, or its folder), a previous download, or `PATH`. If none has it, it downloads Zig from
   [ziglang.org](https://ziglang.org/download/) into `.zig-toolchain\` inside
   the repository and verifies the archive's SHA-256. Nothing is installed
   system-wide and `PATH` is not changed.
3. Runs `zig build` and prints where `murrtty.exe` is.

The first build downloads Ghostty's dependencies (unpacked into `zig-pkg\` in
the repository, about 270 MB; Zig also keeps a per-user cache in
`%LOCALAPPDATA%\zig`) and takes several minutes. The result is
`zig-out\bin\murrtty.exe`. Keep `zig-out\share` next to `bin` if you move it:
it holds the themes and other resources murrtty looks for. To keep a log of
the build, run `.\build-windows.cmd > build.log 2>&1`.

Options:

| Option | Effect |
|---|---|
| `-Optimize Debug` | Debug build (default `ReleaseFast`; also `ReleaseSafe`, `ReleaseSmall`) |
| `-Prefix <dir>` | Install into `<dir>\bin` instead of `zig-out\bin` |
| `-Target <triple>` | Zig target (default `x86_64-windows-gnu`) |
| `-Run` | Start murrtty after a successful build |
| `-SetupOnly` | Install Zig, don't build |
| `-Clean` | Delete `.zig-cache`, and `zig-out` unless `-Prefix` is given, first (`zig-pkg\` and `.zig-toolchain\` are kept) |
| `-Help` | Show the help (also `-?` or `/?`) |

Every other argument is passed to `zig build`: `-D` options (written
`-Dname=value`), steps such as `test`, and flags such as `--summary all`. For
example `.\build-windows.cmd -Dstrip=false` keeps debug information in a
release build. From a PowerShell prompt, quote an argument that contains a
comma or a space (`'-Dname=a,b'`). The exceptions:

- `-h` and `--help` show the builder's help.
- `--verbose` (or `-Verbose`) is forwarded as `zig build --verbose`.
- `-Doptimize=`, `-Dtarget=` and `--prefix` aren't passed through: use
  `-Optimize`, `-Target` and `-Prefix`.
- Other single-dash words must be builder options. PowerShell accepts
  abbreviations of them, such as `-Opt`.
- A bare `--` is rejected. To pass arguments to murrtty, build first and then
  run `zig-out\bin\murrtty.exe` with them.

To build by hand with Zig 0.17.0 already installed:

```powershell
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
```

## Run and configure

Start `zig-out\bin\murrtty.exe`, or build with `-Run`.

- **Configuration** lives in `%LOCALAPPDATA%\murrtty\config.ghostty` (or in
  `%XDG_CONFIG_HOME%\murrtty\` if that variable is set), in Ghostty's format.
  If murrtty has no file of its own but Ghostty's
  `%LOCALAPPDATA%\ghostty\config.ghostty` exists, murrtty reads that one
  instead, and Open Configuration (`Ctrl+,`) opens it; copy it into the
  murrtty folder to give murrtty settings of its own. With neither, murrtty
  creates its file as a commented template on first launch. Everything handled by Ghostty's
  shared core works as documented in the
  [configuration reference](https://ghostty.org/docs/config): fonts, colors,
  themes, keybindings, the shell and so on. Options that the macOS and GTK
  apps implement in their own user interface mostly have no effect here,
  besides the missing features listed above. Among them:
  `window-position-x`/`-y`, `window-save-state`, and the `audio` and
  `border` bell features (`system`, `attention` and
  `title` work). murrtty always opens a window at startup and
  always exits when its last window closes, whatever `initial-window` and
  `quit-after-last-window-closed` say.
- **Shell.** The default is PowerShell 7 (`pwsh.exe -NoLogo`) when it is
  installed, else `cmd.exe` (`%COMSPEC%`); `command` picks another. Shell
  integration is automatic for PowerShell 7, Windows PowerShell and `cmd`
  (`shell-integration = none` turns it off). For PowerShell it applies only
  when the command's arguments are start-up flags such as `-NoLogo` or
  `-NoProfile`, not a command or a script; it loads after your profile. A
  `SHELL` variable (from MSYS2 or Git Bash) is ignored.
- **Starting directory.** Started from a shell or another program, murrtty
  opens in that program's directory; started from the Start menu, a shortcut
  or Explorer, in your home folder. `working-directory` overrides both.
- **Keybindings** are Ghostty's defaults for non-macOS platforms, for example
  `Ctrl+Shift+C`/`Ctrl+Shift+V` to copy and paste, `Ctrl+Shift+T` for a new
  tab, `Ctrl+Shift+W` to close it, and `Ctrl+Tab` or `Ctrl+PgUp`/`Ctrl+PgDn` to
  switch tabs. `murrtty +list-keybinds` prints them all. One addition:
  `Ctrl+Shift+[`/`]` go to the previous and next pane, because Windows can
  hold upstream's `Ctrl+Win+[`/`]` as system hotkeys, which then never reach
  murrtty. Some Intel graphics drivers rotate the screen on
  `Ctrl+Alt+arrows`; if yours does, turn its hotkeys off in Intel Graphics
  Command Center (System, Hotkeys) or bind `goto_split` to other keys.
- **Mouse.** Middle-click doesn't paste by default: the default
  `middle-click-action = primary-paste` uses the selection clipboard of Linux,
  which Windows doesn't have. Set `middle-click-action = clipboard-paste` to
  paste the clipboard instead. For the right button, see `right-click-action`
  above.
- **Logs.** `murrtty.exe` is a GUI program, so it has no console. To see its
  log, start it from a shell with stderr redirected:
  `murrtty.exe 2> murrtty.log`.

## How it works

| Path | What |
|---|---|
| `src/apprt/win32.zig` | The runtime's entry point |
| `src/apprt/win32/App.zig` | Message loop, a message-only window for cross-thread wakeups, action dispatch, close requests |
| `src/apprt/win32/Window.zig` | Top-level window: tabs, size and DPI, fullscreen, close |
| `src/apprt/win32/TabBar.zig` | The tab strip, drawn with GDI using the terminal's colors |
| `src/apprt/win32/Tab.zig` | A tab: its terminal panes as a split tree, in a container window |
| `src/apprt/win32/Surface.zig` | One child window per terminal: keyboard, IME, mouse, clipboard |
| `src/apprt/win32/key.zig` | Scancode and text translation into Ghostty key events |
| `src/apprt/win32/console.zig` | Attaches to the parent console for CLI actions |
| `src/apprt/win32/url.zig` | Decides whether a link from terminal output opens, asks first or is blocked |
| `src/apprt/win32/c.zig` | Hand-written Win32 bindings |
| `pkg/opengl/wgl.zig` | Minimal WGL bindings and context creation |
| `src/renderer/OpenGL.zig`, `src/renderer/opengl/Device.zig` | WGL context per surface and `SwapBuffers` presentation on Windows |
| `build-windows.ps1`, `build-windows.cmd` | The builder |
| `test/windows/gui/`, `src/apprt/win32/test_hooks.zig` | GUI tests, and the Debug-only state dump they read |
| `.github/workflows/windows-port.yml` | CI, started by hand: the builder and the unit tests on a clean hosted Windows runner |
| `.github/workflows/windows-port-desktop.yml` | CI on every push: unit tests and GUI tests on the self-hosted runner |

Ghostty's embedding library (`include/ghostty.h`, the library the macOS app
links) also gains a Windows platform (`GHOSTTY_PLATFORM_WINDOWS`, which takes
an `HWND`), so a native program could host a Ghostty surface. This is
untested, and upstream treats the library's API as internal and unstable.
`zig build -Dtarget=x86_64-windows-gnu -Dapp-runtime=none` builds it as
`zig-out\lib\ghostty-internal.dll`.

A few rules the code depends on:

- Windows and tabs are only closed from the message loop: never inside a
  callback from Ghostty's core, which may still be using them, and never
  while a confirmation dialog is open, since a dialog runs a nested message
  loop. Close requests are queued and run when it is safe.
- Every link Ghostty's core asks to open is accepted, even one that is then
  blocked. Declining one would make the core open it with its generic opener,
  which opens anything.
- Pipe handles on Windows are `HANDLE`s, not C runtime file descriptors: use
  `WriteFile` and `CloseHandle`, not `write()` and `close()`.
- A key-down message only takes the `WM_CHAR` messages queued directly behind
  it, so text is never attached to the wrong key.
- The window's pixel format is sRGB-capable and `GL_FRAMEBUFFER_SRGB` is on
  during the final blit, which keeps colors exact.

The commit messages explain each change in more detail.

## Branches and upstream

`main` is murrtty: upstream Ghostty's history, the commits that brought it to
Windows, and murrtty's own since. Upstream itself is
[ghostty-org/ghostty](https://github.com/ghostty-org/ghostty).

Ghostty's maintainers won't add more runtimes to Ghostty, so murrtty is its
own terminal: a native Windows work-alike of Ghostty that diverges where
Windows or its own features call for it. Upstream is merged in from time to
time rather than rebased onto. The plan is
[WINDOWS_ROADMAP.md](../WINDOWS_ROADMAP.md); "The fork" there says what
stays compatible with Ghostty and what is murrtty's own, and lists where
murrtty behaves differently from Ghostty's GTK app, and why.

## AI assistance

murrtty is developed by the repository owner using Claude Code
(Anthropic's AI coding agent): at the owner's direction, the agent wrote the
code, the commit messages and this README, and ran the testing described
under Status. Ghostty's [AI usage policy](../AI_POLICY.md) governs contributions
to Ghostty itself; murrtty isn't submitted upstream, and any fix offered
to Ghostty on its own would have to meet that policy.

## License

Ghostty is released under the MIT License, and so is murrtty: see
[LICENSE](../LICENSE), copyright Mitchell Hashimoto and the Ghostty
contributors, and Murray Kopit for murrtty's changes.

"Ghostty" and its logo belong to the Ghostty project. The name is used here
only to say what murrtty is based on, and murrtty doesn't use the logo.

Upstream's README is the repository's root [README.md](../README.md), unchanged;
this page is `.github/README.md`, which GitHub shows instead. Its
download, support, contributing and crash-reporting instructions are for
upstream Ghostty and don't apply to murrtty, and the same goes for the other
upstream documents such as [CONTRIBUTING.md](../CONTRIBUTING.md),
[HACKING.md](../HACKING.md) and [AI_POLICY.md](../AI_POLICY.md). Report problems
with murrtty in
[this repository's issues](https://github.com/murr2k/murrtty/issues).
