#!/usr/bin/env python3
"""Cut a zoomed view of a page region for a closer look.

The bbox is in normalized page coordinates (0..1, origin top-left), the same
system used for tiles and for ``bbox`` in extractions. The crop is upscaled
so its long edge is --size pixels.

Usage:
    python crop.py work/my-plant --page 5 --bbox 0.40 0.20 0.55 0.35
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("work", type=Path)
    ap.add_argument("--page", type=int, required=True)
    ap.add_argument("--bbox", type=float, nargs=4, required=True, metavar=("X0", "Y0", "X1", "Y1"))
    ap.add_argument("--size", type=int, default=1400, help="long edge of the output in px")
    ap.add_argument("--out", type=Path)
    a = ap.parse_args()

    from PIL import Image

    page_dir = a.work / "pages" / f"page_{a.page:02d}"
    src = page_dir / "page.png"
    if not src.exists():
        print(f"error: {src} not found; run render_pages.py first", file=sys.stderr)
        return 2
    img = Image.open(src)
    x0, y0, x1, y1 = a.bbox
    box = (round(min(x0, x1) * img.width), round(min(y0, y1) * img.height),
           round(max(x0, x1) * img.width), round(max(y0, y1) * img.height))
    crop = img.crop(box)
    scale = a.size / max(crop.size)
    crop = crop.resize((max(1, round(crop.width * scale)), max(1, round(crop.height * scale))),
                       Image.LANCZOS)
    out = a.out or page_dir / "crops" / f"crop_{x0:.2f}_{y0:.2f}_{x1:.2f}_{y1:.2f}.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    crop.save(out)
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
