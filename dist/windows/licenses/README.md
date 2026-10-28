# License texts for murrtty's release notices

License texts that murrtty's release zip must reproduce
(`THIRD-PARTY-NOTICES.txt`, written by `build-windows.cmd -Package` from
`dist/windows/third-party.json`) but that no dependency package in
`zig-pkg/` carries. Each file is the upstream project's own text, fetched
on 2026-10-28 and kept byte for byte.

| File | For | Source | SHA-256 |
|---|---|---|---|
| `bash-preexec.txt` | `share/ghostty/shell-integration/bash/bash-preexec.sh` (v0.7.0) | https://raw.githubusercontent.com/rcaloras/bash-preexec/master/LICENSE.md | `5ef6b4c99c25dffaee76ecea063cf5df477f0af0fe925e6254229eeebe9a1b42` |
| `chromium.txt` | the DOM key code table in `src/input/keycodes.zig` | https://raw.githubusercontent.com/chromium/chromium/main/LICENSE | `368cca1106be99d39ecd32a38d8305585d802a475effb66380b91ffc9bcf709b` |
| `Apache-2.0.txt` | glad's Khronos registry data, simdutf's Fuchsia-derived code | https://www.apache.org/licenses/LICENSE-2.0.txt | `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` |
| `dear-bindings.txt` | Dear Bindings v0.17 (the generated `dcimgui.cpp`) | https://raw.githubusercontent.com/dearimgui/dear_bindings/v0.17/LICENSE.txt | `b08fd9947ec127fd7785801cac8b1eea2ab4282008cdaae8e50331d870f30d0d` |
| `GPL-3.0.txt` | the Kitty-derived bash and zsh shell integration | https://www.gnu.org/licenses/gpl-3.0.txt | `3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986` |
| `MIT.txt` | the MIT template, for code whose holders are named in the notices (Dear ImGui's ProggyClean font and glcorearb) | https://raw.githubusercontent.com/spdx/license-list-data/main/text/MIT.txt | `b05785f9f18e6716bab63424b11454513b9943a222595b70411009202fc592b5` |
| `iterm2-color-schemes.txt` | `share/ghostty/themes/` | https://raw.githubusercontent.com/mbadolato/iTerm2-Color-Schemes/master/LICENSE | `2373168614b527494dff99eb393024608216db79f687d58bad420f6c1e0ad192` |
| `simdutf-MIT.txt` | simdutf 9.0.0 (`pkg/simdutf/vendor/`) | https://raw.githubusercontent.com/simdutf/simdutf/v9.0.0/LICENSE-MIT | `fc8dbc04e03ad4efc08a647ffe7f995b811a95bc04c0e85a56d5277c6593fa5f` |
| `uucode-Bjoern_Hoehrmann.txt` | uucode's and `src/terminal/UTF8Decoder.zig`'s UTF-8 decoder | https://raw.githubusercontent.com/jacobsandlund/uucode/ea62149739404a73c202b48a33bf6dd2af4bd9b0/licenses/LICENSE_Bjoern_Hoehrmann | `de219cece932aad5a817bf763393d8d149d378a15d2ad5320e3331eac07626dd` |
| `uucode-unicode.txt` | the Unicode data uucode compiles in | https://raw.githubusercontent.com/jacobsandlund/uucode/ea62149739404a73c202b48a33bf6dd2af4bd9b0/licenses/LICENSE_unicode | `1eda5a3b026870c737b22e8bcd4954338612c790db688242e003f41a4fa95175` |
| `x11-rgb.txt` | X11's `rgb.txt` (`src/terminal/res/rgb.txt`) | https://gitlab.freedesktop.org/xorg/app/rgb/-/raw/master/COPYING | `eb3b0a2c9810a0a364cd813377713a223651c17ae8be97c62c2e5d680f71f843` |

When a dependency's version changes, check its license and fetch its text
again if the project changed it.
