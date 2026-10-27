"""Convert an XWD screen dump (Xvfb -fbdir, 24/32 bpp ZPixmap) to PNG,
optionally cropped: xwd2png.py in.xwd out.png [x y w h]."""
import struct, sys, zlib

data = open(sys.argv[1], 'rb').read()
fields = struct.unpack('>25I', data[:100])
(header_size, version, pixmap_format, pixmap_depth, width, height, xoffset,
 byte_order, bitmap_unit, bitmap_bit_order, bitmap_pad, bits_per_pixel,
 bytes_per_line, visual_class, red_mask, green_mask, blue_mask, bits_per_rgb,
 colormap_entries, ncolors, window_width, window_height, window_x, window_y,
 window_bdrwidth) = fields
offset = header_size + ncolors * 12
assert bits_per_pixel == 32, bits_per_pixel
x0, y0, w, h = 0, 0, width, height
if len(sys.argv) >= 7:
    x0, y0, w, h = map(int, sys.argv[3:7])
fmt = '<I' if byte_order == 0 else '>I'

def shift(mask):
    s = 0
    while mask and not (mask >> s) & 1:
        s += 1
    return s

rs, gs, bs = shift(red_mask), shift(green_mask), shift(blue_mask)
rows = []
for y in range(y0, y0 + h):
    row = bytearray([0])
    base = offset + y * bytes_per_line
    for x in range(x0, x0 + w):
        (px,) = struct.unpack(fmt, data[base + 4 * x: base + 4 * x + 4])
        row += bytes(((px & red_mask) >> rs, (px & green_mask) >> gs, (px & blue_mask) >> bs))
    rows.append(bytes(row))

def chunk(tag, body):
    c = struct.pack('>I', len(body)) + tag + body
    return c + struct.pack('>I', zlib.crc32(tag + body) & 0xffffffff)

png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress(b''.join(rows), 9)) + chunk(b'IEND', b'')
open(sys.argv[2], 'wb').write(png)
print(f'{width}x{height} -> {sys.argv[2]} ({w}x{h} at {x0},{y0})')
