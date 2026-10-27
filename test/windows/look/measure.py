"""Measure a chrome picture (PNG, 8-bit RGB, no interlace): color runs
down a column and along a row. measure.py img.png col=X row=Y [...]"""
import struct, sys, zlib

def load(path):
    data = open(path, 'rb').read()
    pos = 8
    idat = b''
    while pos < len(data):
        n, tag = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if tag == b'IHDR':
            w, h, depth, ctype = struct.unpack('>IIBB', body[:10])
        elif tag == b'IDAT':
            idat += body
        pos += 12 + n
    raw = zlib.decompress(idat)
    bpp = 3 if ctype == 2 else 4
    stride = w * bpp
    rows, prev = [], bytearray(stride)
    i = 0
    for _ in range(h):
        f = raw[i]; i += 1
        line = bytearray(raw[i:i + stride]); i += stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(bytes(line)); prev = line
    return w, h, bpp, rows

def px(rows, bpp, x, y):
    r = rows[y]
    return '#%02x%02x%02x' % (r[x * bpp], r[x * bpp + 1], r[x * bpp + 2])

if __name__ == "__main__":
    w, h, bpp, rows = load(sys.argv[1])
    for arg in sys.argv[2:]:
        kind, v = arg.split('=')
        v = int(v)
        runs, last, start = [], None, 0
        n = h if kind == 'col' else w
        for i in range(n):
            color = px(rows, bpp, v, i) if kind == 'col' else px(rows, bpp, i, v)
            if color != last:
                if last is not None:
                    runs.append((start, i - 1, last))
                last, start = color, i
        runs.append((start, n - 1, last))
        print(f'{kind} {v}:', ' '.join(f'{a}-{b}:{c}' for a, b, c in runs if b - a >= 0)[:3000])
