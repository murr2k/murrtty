# License texts for murrtty's release notices

License texts that murrtty's release zip must reproduce
(`THIRD-PARTY-NOTICES.txt`, written by `build-windows.cmd -Package` from
`dist/windows/third-party.json`) but that no dependency package in
`zig-pkg/` carries. Each file is the upstream project's own text, fetched
on 2026-10-28 (Microsoft's and those for Mesa on 2026-10-31) and kept byte
for byte.

| File | For | Source | SHA-256 |
|---|---|---|---|
| `bash-preexec.txt` | `share/ghostty/shell-integration/bash/bash-preexec.sh` (v0.7.0) | https://raw.githubusercontent.com/rcaloras/bash-preexec/master/LICENSE.md | `5ef6b4c99c25dffaee76ecea063cf5df477f0af0fe925e6254229eeebe9a1b42` |
| `chromium.txt` | the DOM key code table in `src/input/keycodes.zig` | https://raw.githubusercontent.com/chromium/chromium/main/LICENSE | `368cca1106be99d39ecd32a38d8305585d802a475effb66380b91ffc9bcf709b` |
| `Apache-2.0.txt` | glad's Khronos registry data, simdutf's Fuchsia-derived code, Mesa's files under Apache-2.0 | https://www.apache.org/licenses/LICENSE-2.0.txt | `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` |
| `dear-bindings.txt` | Dear Bindings v0.17 (the generated `dcimgui.cpp`) | https://raw.githubusercontent.com/dearimgui/dear_bindings/v0.17/LICENSE.txt | `b08fd9947ec127fd7785801cac8b1eea2ab4282008cdaae8e50331d870f30d0d` |
| `GPL-3.0.txt` | the Kitty-derived bash and zsh shell integration | https://www.gnu.org/licenses/gpl-3.0.txt | `3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986` |
| `MIT.txt` | the MIT template, for code whose holders are named in the notices (Dear ImGui's ProggyClean font and glcorearb) | https://raw.githubusercontent.com/spdx/license-list-data/main/text/MIT.txt | `b05785f9f18e6716bab63424b11454513b9943a222595b70411009202fc592b5` |
| `microsoft-terminal.txt` | Microsoft's ConPTY (`bin\conpty.dll`, `bin\OpenConsole.exe`, from `dist/windows/conpty/`), whose package carries no license file | https://raw.githubusercontent.com/microsoft/terminal/v1.25.2733.0/LICENSE | `5d177f23ecfeb0ea8e050b6a5a16355e1ae9a0b286436ca8f83ed08b3795be6b` |
| `microsoft-terminal-NOTICE.md` | the same, the third-party code Windows Terminal's builds include | https://raw.githubusercontent.com/microsoft/terminal/v1.25.2733.0/NOTICE.md | `e7fbaadee6ab20c28b87730a510ee5f5815d8fb4bd88d1d54d282dc2a74c0726` |
| `mesa-license.rst` | Mesa 26.2.6's llvmpipe (`bin\mesa\`, from murr2k/murrtty-mesa's release zips, which carry the same files): its license overview | `docs/license.rst` in https://archive.mesa3d.org/mesa-26.2.6.tar.xz (SHA-256 `b9436b3e1a8be76fbd4823dc884f90596ab7c6ac5e1867a305e66ffccfb31a92`) | `0d1a0472ecc81830e75c20d59b0ea02841e3db21255e0ebad97ab682c54d6615` |
| `mesa-MIT.txt` | the same: the license of most of Mesa | `licenses/MIT` in the same archive | `323c587d0ccf10e376f8bf9a7f31fb4ca6078105194b42e0b1e0ee2bc9bde71f` |
| `mesa-BSL-1.0.txt` | the same: Mesa's files under the Boost license | `licenses/BSL-1.0` in the same archive | `9b9fea7520a816107fcac2598b7c0155222f16bc430e989706b22f4367f1df7d` |
| `llvm.txt` | LLVM 23.1.4, linked into Mesa's `libgallium_wgl.dll` | https://raw.githubusercontent.com/llvm/llvm-project/llvmorg-23.1.4/llvm/LICENSE.TXT | `8d85c1057d742e597985c7d4e6320b015a9139385cff4cbae06ffc0ebe89afee` |
| `iterm2-color-schemes.txt` | `share/ghostty/themes/` | https://raw.githubusercontent.com/mbadolato/iTerm2-Color-Schemes/master/LICENSE | `2373168614b527494dff99eb393024608216db79f687d58bad420f6c1e0ad192` |
| `simdutf-MIT.txt` | simdutf 9.0.0 (`pkg/simdutf/vendor/`) | https://raw.githubusercontent.com/simdutf/simdutf/v9.0.0/LICENSE-MIT | `fc8dbc04e03ad4efc08a647ffe7f995b811a95bc04c0e85a56d5277c6593fa5f` |
| `uucode-Bjoern_Hoehrmann.txt` | uucode's and `src/terminal/UTF8Decoder.zig`'s UTF-8 decoder | https://raw.githubusercontent.com/jacobsandlund/uucode/ea62149739404a73c202b48a33bf6dd2af4bd9b0/licenses/LICENSE_Bjoern_Hoehrmann | `de219cece932aad5a817bf763393d8d149d378a15d2ad5320e3331eac07626dd` |
| `uucode-unicode.txt` | the Unicode data uucode compiles in | https://raw.githubusercontent.com/jacobsandlund/uucode/ea62149739404a73c202b48a33bf6dd2af4bd9b0/licenses/LICENSE_unicode | `1eda5a3b026870c737b22e8bcd4954338612c790db688242e003f41a4fa95175` |
| `x11-rgb.txt` | X11's `rgb.txt` (`src/terminal/res/rgb.txt`) | https://gitlab.freedesktop.org/xorg/app/rgb/-/raw/master/COPYING | `eb3b0a2c9810a0a364cd813377713a223651c17ae8be97c62c2e5d680f71f843` |

When a dependency's version changes, check its license and fetch its text
again if the project changed it.
