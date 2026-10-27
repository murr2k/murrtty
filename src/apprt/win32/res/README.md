# Win32 runtime resources

Files the Windows runtime embeds in `murrtty.exe`.

## AdwaitaSans-Regular.ttf

GNOME's interface font, which Ghostty's GTK app uses for its header bar,
tabs and menus on GNOME 48 and later ("Adwaita Sans 11"). murrtty draws
its chrome in it by default (roadmap 4.3, the Look rule), registered for
the process only (`AddFontMemResourceEx`), never installed.

- Source: <https://download.gnome.org/sources/adwaita-fonts/51/>,
  `adwaita-fonts-51.0.tar.xz`, file `sans/AdwaitaSans-Regular.ttf`
  (a variable font, Inter's design).
- Tarball SHA-256, as published in `adwaita-fonts-51.0.sha256sum`:
  `fa104ae2c1b96580d322f563ffe8b2dfca5296b0eca4971efd2d8011405123d2`
- This file's SHA-256:
  `8381c33b9a44f066f2b99dba3d416a2342891e28c956a35dfd8d16ee2987e6d4`
- License: SIL Open Font License 1.1, in `OFL-AdwaitaSans.txt` (the
  release's `LICENSE`, unchanged).

To update: take the newest release from the same place, check the tarball
against its `.sha256sum`, replace the font and the license, and update the
hashes and version here.
