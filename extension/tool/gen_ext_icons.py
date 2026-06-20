"""Generates the extension's PNG icons (16/32/48/128) from the same brand mark
the app uses. Reuses app/tool/gen_icons.py's renderer so the bolt/gradient stay
identical.

Run:  python tool/gen_ext_icons.py   (from the extension/ directory)
"""

import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent  # extension/
APP_TOOL = ROOT.parent / "app" / "tool"
sys.path.insert(0, str(APP_TOOL))

import gen_icons  # noqa: E402  (provides render(size))

OUT = ROOT / "shared" / "icons"
SIZES = (16, 32, 48, 128)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    master = gen_icons.render(128)
    for s in SIZES:
        master.resize((s, s), Image.LANCZOS).save(OUT / f"icon-{s}.png")
    print("wrote extension icons:")
    for s in SIZES:
        print("  ", (OUT / f"icon-{s}.png").relative_to(ROOT))


if __name__ == "__main__":
    main()
