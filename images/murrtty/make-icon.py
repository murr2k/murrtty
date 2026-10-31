"""Make murrtty's icon files from murrtty.svg.

    python make-icon.py [--msix]

Renders murrtty.svg with Microsoft Edge in headless mode (any Windows 10
or 11 has it) at 1024 px, then writes icon.png (256 px, the README's and
murrtty.org's) beside it and dist/windows/murrtty.ico (the executable's,
16 to 256 px), each size downscaled from the 1024 px rendering. With
--msix it writes only the MSIX package's logos into
dist/windows/msix/Assets (at the 200% scale, unqualified: the package has
no resources.pri yet, so Windows scales these). Needs Pillow.

The icon: a lowercase m drawn as a split view, its stems the frame and
the divider, its counters two panes holding a prompt and a block cursor,
in amber phosphor on near-black.
"""
import os
import subprocess
import sys
import tempfile

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SVG = os.path.join(HERE, 'murrtty.svg')
PNG = os.path.join(HERE, 'icon.png')
ICO = os.path.join(ROOT, 'dist', 'windows', 'murrtty.ico')
ICO_SIZES = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]
MSIX_ASSETS = os.path.join(ROOT, 'dist', 'windows', 'msix', 'Assets')
# Each logo the manifest names, at 200%: (width, height); a wide one has
# the square icon centered.
MSIX_LOGOS = {
    'Square44x44Logo.png': (88, 88),
    'Square150x150Logo.png': (300, 300),
    'Wide310x150Logo.png': (620, 300),
    'StoreLogo.png': (100, 100),
}

EDGES = [
    r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
]


def render(svg, png):
    edge = next((e for e in EDGES if os.path.exists(e)), None)
    if edge is None:
        sys.exit('Microsoft Edge not found')
    with tempfile.TemporaryDirectory() as profile:
        subprocess.run([
            edge, '--headless', '--disable-gpu', '--hide-scrollbars',
            '--default-background-color=00000000',
            f'--user-data-dir={profile}', '--window-size=1024,1024',
            f'--screenshot={png}', 'file:///' + svg.replace('\\', '/'),
        ], check=True, capture_output=True, timeout=120)


def main():
    with tempfile.TemporaryDirectory() as tmp:
        big_path = os.path.join(tmp, 'icon-1024.png')
        render(SVG, big_path)
        big = Image.open(big_path).convert('RGBA')
    if big.size != (1024, 1024):
        sys.exit(f'unexpected rendering size {big.size}')
    if '--msix' in sys.argv[1:]:
        os.makedirs(MSIX_ASSETS, exist_ok=True)
        for name, (w, h) in MSIX_LOGOS.items():
            side = min(w, h)
            logo = Image.new('RGBA', (w, h), (0, 0, 0, 0))
            logo.alpha_composite(big.resize((side, side), Image.LANCZOS),
                                 ((w - side) // 2, (h - side) // 2))
            logo.save(os.path.join(MSIX_ASSETS, name), optimize=True)
        print(f'{MSIX_ASSETS}: {", ".join(MSIX_LOGOS)}')
        return
    big.resize((256, 256), Image.LANCZOS).save(PNG, optimize=True)
    frames = [big.resize((s, s), Image.LANCZOS) for s in ICO_SIZES]
    frames[-1].save(ICO, sizes=[(s, s) for s in ICO_SIZES],
                    append_images=frames[:-1])
    print(f'{PNG}\n{ICO} ({", ".join(map(str, ICO_SIZES))})')


if __name__ == '__main__':
    main()
