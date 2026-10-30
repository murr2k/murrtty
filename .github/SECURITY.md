# Security policy

## Reporting a vulnerability

Please report security problems in murrtty privately, through GitHub's
[private vulnerability reporting](https://github.com/murr2k/murrtty/security/advisories/new)
(the repository's Security tab, "Report a vulnerability"), never in a public
Discussion or issue, or by email to security@murrtty.org. Include what you
found, how to reproduce it, the output of `murrtty +version` and your Windows
version. The maintainer answers in the advisory or by email.
[murrtty.org/.well-known/security.txt](https://murrtty.org/.well-known/security.txt)
lists the same contacts.

Reports matter most for the parts of murrtty that decide what runs or opens:

- which links from terminal output it opens, asks about or blocks
  (`src/apprt/win32/url.zig`);
- the single instance's named pipe, through which other processes ask the
  running murrtty for windows and tabs (`src/apprt/win32/ipc.zig`);
- which program a bare command name starts (`src/os/default_shell.zig`);
- the shell integration scripts it loads into PowerShell and cmd
  (`src/shell-integration/`).

## Supported versions

The latest release (0.1.0, a preview) and the latest commit of `main`.

## Ghostty

murrtty is based on [Ghostty](https://github.com/ghostty-org/ghostty) but not
affiliated with it. If a problem lies in code murrtty shares with Ghostty and
also affects Ghostty on macOS or Linux, please report it to the Ghostty
project as well, following its own process.
