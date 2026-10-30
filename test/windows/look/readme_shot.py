"""Put the README's picture together from the GUI suite's opt-in
readme-screenshot scenario, whose parts are murrtty's own pixels read back on
the hidden desktop (GHOSTTY_GUI_SNAPSHOT = the folder): the chrome (header bar
and tab row) at the top, the active tab's container below it, each visible
pane's frame where the dump places it. Windows 11 then draws the frame's
rounded corners and thin border, which this adds. Needs Pillow.

    python readme_shot.py <folder> <out.png>
"""
import json
import os
import sys

from PIL import Image, ImageDraw

# libadwaita's header bar is 46 px at 96 DPI (HeaderBar.zig).
HEADER_DIP = 46
# Windows 11's window corners and border, at 96 DPI.
RADIUS_DIP = 8
BORDER = (0x48, 0x48, 0x48, 0xFF)


def dim(frame):
    """An unfocused split as the screen shows it: the frame is read back
    before the present pass dims it (unfocused-split-opacity, 0.7 by
    default, over unfocused-split-fill, the background by default), so the
    dimming is drawn here, with the background from the frame's corner."""
    background = frame.getpixel((frame.width - 4, frame.height - 4))
    return Image.blend(frame, Image.new('RGB', frame.size, background), 0.3)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    folder, out = sys.argv[1], sys.argv[2]
    with open(os.path.join(folder, 'readme-dump.json'), encoding='utf-8') as f:
        win = json.load(f)['windows'][0]
    chrome = Image.open(os.path.join(folder, 'readme-chrome.bmp')).convert('RGB')
    tab = Image.open(os.path.join(folder, 'readme-tab.bmp')).convert('RGB')
    picture = Image.new('RGB', (chrome.width, chrome.height + tab.height))
    picture.paste(chrome, (0, 0))
    picture.paste(tab, (0, chrome.height))

    # Each pane's frame by the number the dump gives it (saveFrames counts
    # panes in tree order, the dump lists them left to right), at its place
    # in the tab's container.
    placed = 0
    for t in win['tabs']:
        for p in t.get('panes') or []:
            path = os.path.join(folder, f"readme-frame-{p.get('frame', 0)}.bmp")
            if p.get('visible') and os.path.exists(path):
                frame = Image.open(path).convert('RGB')
                if p.get('dimmed'):
                    frame = dim(frame)
                picture.paste(frame, (p['rect'][0], chrome.height + p['rect'][1]))
                placed += 1
    if placed == 0:
        sys.exit('no pane frame found')

    scale = win['header']['height'] / HEADER_DIP if win['header']['height'] else 1.0
    radius = round(RADIUS_DIP * scale)
    rgba = picture.convert('RGBA')
    mask = Image.new('L', rgba.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, rgba.width - 1, rgba.height - 1), radius, fill=255)
    rgba.putalpha(mask)
    ImageDraw.Draw(rgba).rounded_rectangle(
        (0, 0, rgba.width - 1, rgba.height - 1), radius, outline=BORDER, width=max(1, round(scale)))
    rgba.save(out, optimize=True)
    print(f'{out}: {rgba.width}x{rgba.height}, {placed} pane(s)')


if __name__ == '__main__':
    main()
