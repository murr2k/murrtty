# Shell Integration Code

This is the shell-specific shell-integration code that is
used for the shell-integration feature set that Ghostty
supports.

This README is meant as developer documentation and not as
user documentation. For user documentation, see the main
README or [ghostty.org](https://ghostty.org/docs)

## Implementation Details

### Bash

Automatic [Bash](https://www.gnu.org/software/bash/) shell integration works by
starting Bash in POSIX mode and using the `ENV` environment variable to load
our integration script (`bash/ghostty.bash`). This prevents Bash from loading
its normal startup files, which becomes our script's responsibility (along with
disabling POSIX mode).

Bash shell integration can also be sourced manually from `bash/ghostty.bash`.
This also works for older versions of Bash.

```bash
# Ghostty shell integration for Bash. This must be at the top of your bashrc!
if [ -n "${GHOSTTY_RESOURCES_DIR}" ]; then
    builtin source "${GHOSTTY_RESOURCES_DIR}/shell-integration/bash/ghostty.bash"
fi
```

> [!NOTE]
>
> The version of Bash distributed with macOS (`/bin/bash`) does not support
> automatic shell integration. You'll need to manually source the shell
> integration script (as shown above). You can also install a standard
> version of Bash from Homebrew or elsewhere and set it as your shell.

### Elvish

For [Elvish](https://elv.sh), `$GHOSTTY_RESOURCES_DIR/src/shell-integration`
contains an `./elvish/lib/ghostty-integration.elv` file.

Elvish, on startup, searches for paths defined in `XDG_DATA_DIRS`
variable for `./elvish/lib/*.elv` files and imports them. They are thus
made available for use as modules by way of `use <filename>`.

Ghostty launches Elvish, passing the environment with `XDG_DATA_DIRS` prepended
with `$GHOSTTY_RESOURCES_DIR/src/shell-integration`. It contains
`./elvish/lib/ghostty-integration.elv`. The user can then import it
by `use ghostty-integration` every time after shell startup or
autostart integration in `$XDG_CONFIG_HOME/elvish/rc.elv`,
which will run the integration routines.

If you decide to autostart `ghostty-integration` with `rc.elv`, you should
detect whether the terminal is Ghostty or not. To do this, add this to the end
of your `rc.elv` file:

```elvish
if (eq $E:TERM "xterm-ghostty") {
  try { use ghostty-integration } catch { }
}
```

### Fish

For [Fish](https://fishshell.com/), Ghostty prepends to the
`XDG_DATA_DIRS` directory. Fish automatically loads configuration
files in `<XDG_DATA_DIR>/fish/vendor_conf.d/*.fish` on startup,
allowing us to automatically integrate with the shell. For details
on the Fish startup process, see the
[Fish documentation](https://fishshell.com/docs/current/language.html).

### Nushell

For [Nushell](https://www.nushell.sh/), Ghostty prepends to the
`XDG_DATA_DIRS` directory, making the `ghostty` module available through
Nushell's vendor autoload mechanism. Ghostty then automatically imports
the module using the `-e "use ghostty *"` flag when starting Nushell.

Nushell provides many shell features itself, such as `title` and `cursor`,
so our integration focuses on Ghostty-specific features like `sudo`,
`ssh-env`, and `ssh-terminfo`.

The shell integration is automatically enabled when running Nushell in Ghostty,
but you can also load it manually if shell integration is disabled.

Note that Nushell doesn't allow sourcing not _parse-time constants_,
so `GHOSTTY_RESOURCES_DIR` environment variable cannot be used.

Here is an example of `config.nu` with default `GHOSTTY_RESOURCES_DIR` for macOS:

```nushell
source /Applications/Ghostty.app/Contents/Resources/ghostty/shell-integration/nushell/vendor/autoload/ghostty.nu
use ghostty *
```

### PowerShell

On Windows, murrtty (the Windows fork of Ghostty) starts [PowerShell](https://learn.microsoft.com/powershell/)
(`pwsh`, and Windows PowerShell 5.1 as `powershell`) with
`-NoExit -Command` and a command that loads `powershell/ghostty.ps1` after
the profile, so the script wraps whatever prompt the profile set. It reads
the script as text and runs it as a script block rather than running the
`.ps1` file, which Windows PowerShell's default execution policy
(`Restricted`) would refuse. Ghostty does this only when the command's
arguments are start-up flags it knows (such as `-NoLogo`, `-NoProfile` or
`-ExecutionPolicy <policy>`); a command, a script or `-File` runs as given.

The script reports the prompt (OSC 133 P, and I where the input starts),
the start of each command from PSReadLine's `PSConsoleHostReadLine` (OSC
133 C), its exit status (OSC 133 D) and the working directory (OSC 7, empty
in a location that isn't a drive path, such as `HKCU:\`). Through ConPTY
two of the usual marks don't fit. A's fresh-line would move Ghostty's cursor
without ConPTY's, which keeps its own, so every later repaint would land a
row off. And B's input state would carry onto the rows ConPTY repaints with
line feeds, marking output as prompt continuation; I ends at the line's end.
The `cursor`, `title` and `path` features apply; `sudo` and the `ssh-*`
features don't. The script turns strict mode off for its own code, and
loading it again (after a profile reload replaced the prompt) wraps the new
prompt without wrapping anything twice.

To load it manually, at the end of your profile:

```powershell
if ($env:GHOSTTY_RESOURCES_DIR) {
    . "$env:GHOSTTY_RESOURCES_DIR\shell-integration\powershell\ghostty.ps1"
}
```

### cmd

cmd has no start-up script, so on Windows murrtty integrates it through its
environment. It wraps `PROMPT` (cmd's default `$P$G` when unset) to send
OSC 133 D, the folder as the title (OSC 2, the `title` feature), the
working directory (OSC 9;9), then OSC 133 P, your prompt and OSC 133 I. A
`PROMPT` that already sends OSC 133 is left as it is. cmd can't report a
command's start or its exit status: nothing runs before a command, and a
prompt can't show `%ERRORLEVEL%`.

[Clink](https://chrisant996.github.io/clink/) (v1.4.25 or later) fills
those in. murrtty adds `cmd` to `%CLINK_PATH%`, so Clink loads
`cmd/ghostty.lua`, which sends the same codes around whatever prompt Clink
shows, custom prompts included, plus OSC 133 C when a line is accepted and
the exit status with D (with Clink's `cmd.get_errorlevel`, on by default).
Clink puts them around the prompt's last line, so of a prompt over several
lines only the last is marked. Older Clink takes any OSC 133 for a title,
so for it the script only removes the codes from cmd's prompt.
The `cursor` feature doesn't apply to cmd; `path` isn't needed, as murrtty
puts its folder on the `PATH` it gives cmd.

### Zsh

Automatic [Zsh](https://www.zsh.org/) integration works by temporarily setting
`ZDOTDIR` to our `zsh` directory. An existing `ZDOTDIR` environment variable
value will be retained and restored after our shell integration scripts are
run.

However, if `ZDOTDIR` is set in a system-wide file like `/etc/zshenv`, it will
override Ghostty's `ZDOTDIR` value, preventing the shell integration from being
loaded. In this case, the shell integration needs to be loaded manually.

To load the Zsh shell integration manually:

```zsh
if [[ -n $GHOSTTY_RESOURCES_DIR ]]; then
  source "$GHOSTTY_RESOURCES_DIR"/shell-integration/zsh/ghostty-integration
fi
```

Shell integration requires Zsh 5.1+.
