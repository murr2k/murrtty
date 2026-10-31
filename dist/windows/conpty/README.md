# Microsoft's ConPTY, vendored

The pseudo console murrtty's terminals run in (roadmap 2.6). The build
installs this folder's `conpty.dll` and `OpenConsole.exe` for the target
architecture beside `murrtty.exe` (`src/build/GhosttyExe.zig`), and the pty
loads `conpty.dll` from there by full path (`src/os/conpty.zig`); without it,
or with `MURRTTY_CONPTY=system`, murrtty uses Windows' own ConPTY.
`conpty.dll` starts the `OpenConsole.exe` beside it as each terminal's
console host.

The files are Microsoft's, unmodified and signed by Microsoft Corporation,
from the NuGet package
[Microsoft.Windows.Console.ConPTY 1.25.260930003](https://www.nuget.org/packages/Microsoft.Windows.Console.ConPTY/1.25.260930003)
(`runtimes/win-<arch>/native/conpty.dll` and
`build/native/runtimes/<arch>/OpenConsole.exe`), the build Windows Terminal
1.25.2733.0 ships. The package is MIT licensed and says it works on Windows
10 1809 (build 17763) and later; its license texts are in `../licenses/`.

| File | SHA-256 |
|---|---|
| `x64/conpty.dll` | `feeef341d891643c62d30b6b07800bc70f0bc148f44cb8c3bee84aa557ae805a` |
| `x64/OpenConsole.exe` | `3d66b23d0a71bb8eed2b77edc8b9df9bf54ce6c8fb74c863a30e760997f80586` |
| `arm64/conpty.dll` | `151a02355227710c20c9f8f1eaf68ac4668aa09cdc921adc7ec661804d8eb1bf` |
| `arm64/OpenConsole.exe` | `4313825a3ba634d113cc6ed3bc8ce735e3c19d360cecd985794787479469f91f` |

The package itself (`microsoft.windows.console.conpty.1.25.260930003.nupkg`)
had SHA-256 `02b07b349af66d801159bdf9e440d4a1ce78bb951f37fc8609731665afdae7ee`.

To move to another version, run `python update.py <version>` here: it
fetches the package from NuGet, checks its id, version and license, copies
the four files and checks their signatures, and prints their hashes. Then
update the table above, `filePins` and the ConPTY component's version in
`../third-party.json`, and the license texts in `../licenses/` from the
matching Windows Terminal tag; run the GUI suite, since murrtty's
integrations work around how ConPTY forwards sequences (roadmap 2.2, S3).
