"""Compare the first text line of GTK's reference with murrtty's frame
(needs Pillow): finds each line's ink, aligns the two by it, and prints how
far their pixels differ, then writes the start of both lines and their
difference zoomed 4x (red: GTK's brighter, green: murrtty's).
  textdiff.py gtk.png gx gy frame.bmp mx my out.png
(gx, gy) and (mx, my): a point above and left of the line's first glyph in
each picture (the terminal's top left; under GTK's shade is fine)."""
import sys
from PIL import Image

W, H = 720, 24


def lum(p):
    return (p[0] * 299 + p[1] * 587 + p[2] * 114) // 1000


def ink_box(img, x0, y0, thr=0x70):
    px = img.load()
    pts = [(x, y) for y in range(y0, y0 + H) for x in range(x0, x0 + W) if lum(px[x, y]) > thr]
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return min(xs), min(ys), max(xs) + 1, max(ys) + 1


g = Image.open(sys.argv[1]).convert('RGB')
m = Image.open(sys.argv[4]).convert('RGB')
gb = ink_box(g, int(sys.argv[2]), int(sys.argv[3]))
mb = ink_box(m, int(sys.argv[5]), int(sys.argv[6]))
print('gtk ink', gb, 'murrtty ink', mb)
dx, dy = mb[0] - gb[0], mb[1] - gb[1]
gp, mp = g.load(), m.load()
x0, y0, x1, y1 = gb[0] - 1, gb[1] - 2, gb[2] + 1, gb[3] + 2
diffs = sorted(max(abs(gp[x, y][i] - mp[x + dx, y + dy][i]) for i in range(3))
               for y in range(y0, y1) for x in range(x0, x1))
n = len(diffs)
same = sum(1 for d in diffs if d == 0)
print(f'aligned by ({dx},{dy}): {n} px, identical {100 * same / n:.1f}%, '
      f'median {diffs[n // 2]}, p95 {diffs[int(n * .95)]}, max {diffs[-1]} (of 255)')
z, w, h = 4, 200, y1 - y0
out = Image.new('RGB', (w * z, (h * 3 + 2) * z), (255, 0, 255))
diff = Image.new('RGB', (w, h))
dp = diff.load()
for y in range(h):
    for x in range(w):
        a, b = lum(gp[x0 + x, y0 + y]), lum(mp[x0 + x + dx, y0 + y + dy])
        dp[x, y] = (min(255, max(0, a - b) * 3), min(255, max(0, b - a) * 3), 0)
out.paste(g.crop((x0, y0, x0 + w, y1)).resize((w * z, h * z), Image.NEAREST), (0, 0))
out.paste(m.crop((x0 + dx, y0 + dy, x0 + dx + w, y1 + dy)).resize((w * z, h * z), Image.NEAREST), (0, (h + 1) * z))
out.paste(diff.resize((w * z, h * z), Image.NEAREST), (0, (2 * h + 2) * z))
out.save(sys.argv[7])
print('wrote', sys.argv[7])
