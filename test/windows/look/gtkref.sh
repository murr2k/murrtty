#!/bin/sh
# A reference picture of Ghostty's GTK app, headless (roadmap 4.3 step 4):
# the snap under Xvfb at 96 DPI, in an isolated config and data folder
# (GNOME's font, Adwaita Sans 11, and a fixed Ghostty config), the screen
# taken from Xvfb's framebuffer file. Nothing in the user's own config
# changes and no window opens on their screen.
#   gtkref.sh <font.ttf> <out.xwd> [file of extra ghostty config lines]
#             [file of commands, xdotool's, run in the display before the
#             picture: to open a menu]
set -e
font="$1"
out="$2"
extra="$3"
actions="$4"
base=/tmp/murrtty-gtkref
rm -rf "$base"
mkdir -p "$base/config/gtk-4.0" "$base/config/ghostty" "$base/data/fonts" "$base/fb"
cp "$font" "$base/data/fonts/"
printf '[Settings]\ngtk-font-name=Adwaita Sans 11\n' > "$base/config/gtk-4.0/settings.ini"
printf 'window-width = 80\nwindow-height = 24\n' > "$base/config/ghostty/config.ghostty"
if [ -n "$extra" ]; then cat "$extra" >> "$base/config/ghostty/config.ghostty"; fi
: > "$base/actions.sh"
if [ -n "$actions" ]; then cp "$actions" "$base/actions.sh"; fi
cat > "$base/run.sh" <<EOF
#!/bin/sh
export XDG_CONFIG_HOME=$base/config XDG_DATA_HOME=$base/data
export GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1 XDG_DATA_DIRS=/usr/local/share:/usr/share
/snap/bin/ghostty > $base/ghostty.log 2>&1 &
pid=\$!
sleep 8
. $base/actions.sh
sleep 2
cp $base/fb/Xvfb_screen0 $base/screen.xwd
kill \$pid 2>/dev/null || true
EOF
chmod +x "$base/run.sh"
unset DISPLAY WAYLAND_DISPLAY
xvfb-run -a -s "-screen 0 1280x800x24 -dpi 96 -fbdir $base/fb" "$base/run.sh"
cp "$base/screen.xwd" "$out"
echo "wrote $out"
