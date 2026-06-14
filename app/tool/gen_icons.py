"""Generates Shinsoku icon/logo assets from the in-app brand primitives.

The mark is the lightning "bolt" (the same vector used by BoltIcon) on the
volt gradient rounded-square tile (the same tile used by ShinsokuLogo). The
bolt is used instead of the 速 kanji because it is font-independent and stays
crisp at 16px, whereas the kanji needs a CJK font that the app does not bundle.

Outputs (under app/assets/icon and app/assets/logo):
  - shinsoku_1024.png        master mark, transparent background
  - app_icon.ico             multi-size Windows icon (16..256)
  - tray.ico                 small tray icon (16/24/32)
  - tray_32.png / tray_64.png
  - ../logo/shinsoku_mark.png  512px tile for in-app use

Run:  python tool/gen_icons.py
"""

from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw

# ── brand constants (mirror lib/src/theme/colors.dart) ────────────────────────
VIOLET = (0xA2, 0x5C, 0xFF)
PINK = (0xFF, 0x63, 0xB6)
AMBER = (0xFF, 0xCE, 0x4D)
STOPS = [(0.0, VIOLET), (0.46, PINK), (1.0, AMBER)]
GLYPH_DARK = (0x1B, 0x10, 0x20)
ANGLE_DEG = 118.0
CORNER = 0.28          # radius as fraction of tile (matches logo's size*0.28)
BOLT_H = 0.58          # bolt height as fraction of tile
SS = 4                 # supersample factor for mask edges

# bolt path in unit space (from _BoltPainter in lib/src/ui/widgets/bolt_icon.dart)
BOLT = [
    (0.54, 0.00), (0.17, 0.56), (0.43, 0.56), (0.30, 1.00),
    (0.83, 0.38), (0.56, 0.38), (0.68, 0.00),
]

ROOT = Path(__file__).resolve().parent.parent  # app/
ICON_DIR = ROOT / "assets" / "icon"
LOGO_DIR = ROOT / "assets" / "logo"


def _lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def _grad_color(t):
    t = max(0.0, min(1.0, t))
    for i in range(len(STOPS) - 1):
        p0, c0 = STOPS[i]
        p1, c1 = STOPS[i + 1]
        if t <= p1:
            local = 0.0 if p1 == p0 else (t - p0) / (p1 - p0)
            return _lerp(c0, c1, local)
    return STOPS[-1][1]


def gradient(size):
    """118deg linear volt gradient as an (size,size,3) uint8 array."""
    th = np.deg2rad(ANGLE_DEG)
    dx, dy = np.cos(th), np.sin(th)
    xs = (np.arange(size) + 0.5) / size - 0.5
    ys = (np.arange(size) + 0.5) / size - 0.5
    gx, gy = np.meshgrid(xs, ys)
    t = np.clip(0.5 + gx * dx + gy * dy, 0.0, 1.0)
    # build a 256-entry LUT then index — cheap and exact for the 3-stop ramp
    lut = np.array([_grad_color(i / 255.0) for i in range(256)], dtype=np.uint8)
    idx = (t * 255).astype(np.uint8)
    return lut[idx]


def rounded_mask(size, radius_frac):
    big = size * SS
    m = Image.new("L", (big, big), 0)
    d = ImageDraw.Draw(m)
    r = int(radius_frac * big)
    d.rounded_rectangle([0, 0, big - 1, big - 1], radius=r, fill=255)
    return m.resize((size, size), Image.LANCZOS)


def bolt_mask(size):
    big = size * SS
    m = Image.new("L", (big, big), 0)
    d = ImageDraw.Draw(m)
    s = BOLT_H * big
    c = big / 2
    pts = [(c + (u - 0.5) * s, c + (v - 0.5) * s) for (u, v) in BOLT]
    d.polygon(pts, fill=255)
    return m.resize((size, size), Image.LANCZOS)


def render(size):
    """The mark at `size`px: gradient tile + dark bolt, rounded-rect alpha."""
    rgb = gradient(size)
    img = Image.fromarray(rgb, "RGB").convert("RGBA")
    # dark bolt
    bolt = bolt_mask(size)
    dark = Image.new("RGBA", (size, size), GLYPH_DARK + (255,))
    img = Image.composite(dark, img, bolt)
    # rounded-rect alpha
    img.putalpha(rounded_mask(size, CORNER))
    return img


def main():
    ICON_DIR.mkdir(parents=True, exist_ok=True)
    LOGO_DIR.mkdir(parents=True, exist_ok=True)

    master = render(1024)
    master.save(ICON_DIR / "shinsoku_1024.png")
    master.resize((512, 512), Image.LANCZOS).save(LOGO_DIR / "shinsoku_mark.png")

    ico_sizes = [16, 24, 32, 48, 64, 128, 256]
    master.save(ICON_DIR / "app_icon.ico",
                sizes=[(s, s) for s in ico_sizes])

    # tray: small, crisp
    master.resize((32, 32), Image.LANCZOS).save(ICON_DIR / "tray_32.png")
    master.resize((64, 64), Image.LANCZOS).save(ICON_DIR / "tray_64.png")
    master.save(ICON_DIR / "tray.ico", sizes=[(16, 16), (24, 24), (32, 32)])

    print("wrote:")
    for p in sorted(ICON_DIR.glob("*")) + sorted(LOGO_DIR.glob("*")):
        print("  ", p.relative_to(ROOT), p.stat().st_size, "bytes")


if __name__ == "__main__":
    main()
