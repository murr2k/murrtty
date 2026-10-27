# Comparing murrtty's look with Ghostty's GTK app

Roadmap 4.3's Look rule: murrtty looks like Ghostty's GTK app by default.
These tools measure that rather than judging it by eye.

1. **A GTK reference:** `.\gtkref.ps1 -Out ref.png` runs the Ghostty snap
   in the WSL distro under Xvfb at 96 DPI, with an isolated config folder
   that holds GNOME's font (Adwaita Sans 11) and a fixed Ghostty config
   (`-Extra` adds a line), and takes the screen from Xvfb's framebuffer
   file (`gtkref.sh`, `xwd2png.py`). Nothing opens on the screen and the
   distro's own configs stay as they are. Without a window manager GTK
   draws its own frame (5 px) and shows minimize, maximize and close.
2. **murrtty's side:** the GUI suite's opt-in `snapshot` scenario
   (`GHOSTTY_GUI_SNAPSHOT` = a folder, `GHOSTTY_GUI_ONSCREEN=1` on a still
   screen) writes `chrome-*.bmp`, the header bar and tab row as last
   painted, at the window's DPI. The window is inactive there, so its
   chrome shows libadwaita's backdrop colors.
3. **Measure:** `measure.py img.png col=X row=Y` prints the color runs down
   a column or along a row; `ascii.py img.png x y w h` prints a region as
   text (a digit for each pixel's distance toward white), which gives an
   icon's exact shape; `compare.ps1` puts a zoomed region of the reference
   above the same region of murrtty's picture, scaled from its DPI to 96.

The values found this way are written down where they're used (for the
header bar, in `src/apprt/win32/HeaderBar.zig`) and in the roadmap's 4.3
notes.
