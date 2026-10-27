"""Print a region of a PNG as text: each pixel by how far it is from the
background toward white (0-9), '.' for the background.
ascii.py img.png x y w h"""
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from measure import load

w, h, bpp, rows = load(sys.argv[1])
x0, y0, rw, rh = map(int, sys.argv[2:6])
bg = rows[y0][x0 * bpp: x0 * bpp + 3]
bgl = sum(bg) / 3
print('     ' + ''.join(str((x0 + i) % 10) for i in range(rw)))
for y in range(y0, y0 + rh):
    line = ''
    for x in range(x0, x0 + rw):
        p = rows[y][x * bpp: x * bpp + 3]
        l = sum(p) / 3
        if abs(l - bgl) < 4:
            line += '.'
        else:
            line += str(min(9, max(0, int((l - bgl) / (255 - bgl + 1e-9) * 10))))
    print(f'{y:4d} {line}')
