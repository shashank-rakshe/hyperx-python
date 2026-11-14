#!/usr/bin/env python3
"""Render P&ID pages into an overview plus overlapping tiles for visual reading.

For every page this writes, under <work>/pages/page_NN/:

    page.png           full-resolution render (used by crop.py)
    overview.png       whole sheet, long edge 1568 px
    overview_grid.png  the overview with the tile grid and tile names drawn on
    tiles/rRcC.png     overlapping tiles (default 1400 px, 200 px overlap)
    tiles.json         tile positions in pixels and normalized page coordinates

Vector pages are rendered from their vectors; raster pages at the scan's
native resolution, upscaled (at most 2.5x) and contrast-enhanced. When OCR is
available it detects the page orientation (--rotation overrides it) and
measures the text size, and the resolution is chosen so small text is
comfortably legible in each tile (--long-edge overrides it). Tiles with
almost no ink are marked blank and need not be read.

Usage:
    python render_pages.py work/my-plant [--pages 1-3,5] [--rotation 90]
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from pidkg import ocr  # noqa: E402
from pidkg.pdf import ink_fraction, render_page, tile_grid  # noqa: E402

OVERVIEW_LONG_EDGE = 1568
BLANK_INK = 0.0002  # a lone instrument bubble is ~0.0003 of a tile
PREVIEW_EDGE = 2400
# Render so that small text (25th percentile OCR box) is about this tall in a
# tile. Claude downsamples a 1400 px tile to ~1090 px, leaving ~16 px text.
TARGET_TEXT_BOX = 32
MIN_EDGE, MAX_EDGE = 3000, 8000
DEFAULT_VECTOR_EDGE, DEFAULT_RASTER_EDGE = 5000, 4000


def parse_pages(spec: str | None, n: int, default: list[int] | None = None) -> list[int]:
    """Parse '1-3,5'. With no spec, use `default` (the pages chosen at probe time) or all pages."""
    if not spec:
        return [p for p in default if 1 <= p <= n] if default else list(range(1, n + 1))
    out: list[int] = []
    for part in spec.split(","):
        if "-" in part:
            a, b = part.split("-")
            out.extend(range(int(a), int(b) + 1))
        else:
            out.append(int(part))
    return [p for p in out if 1 <= p <= n]


def _cores(tiles, key_lo, key_hi, total):
    """Split the overlap between neighbouring tiles at its midpoint."""
    spans = sorted({(t["px"][key_lo], t["px"][key_hi]) for t in tiles})
    cores = {}
    for i, (lo, hi) in enumerate(spans):
        c_lo = 0 if i == 0 else (spans[i - 1][1] + lo) / 2
        c_hi = total if i == len(spans) - 1 else (hi + spans[i + 1][0]) / 2
        cores[i + 1] = (c_lo, c_hi)
    return cores


def draw_grid(overview, tiles, scale, width, height):
    """Overlay each tile's core region (overlaps split at the midpoint) and its name."""
    from PIL import ImageDraw, ImageFont

    img = overview.convert("RGB")
    d = ImageDraw.Draw(img)
    try:
        font = ImageFont.truetype("arial.ttf", 22)
    except OSError:
        font = ImageFont.load_default()
    xs = _cores(tiles, 0, 2, width)
    ys = _cores(tiles, 1, 3, height)
    for t in tiles:
        x0, x1 = xs[t["col"]]
        y0, y1 = ys[t["row"]]
        x0, y0, x1, y1 = (round(v * scale) for v in (x0, y0, x1, y1))
        colour = (170, 170, 170) if t.get("blank") else (220, 30, 30)
        d.rectangle([x0, y0, x1, y1], outline=colour, width=1)
        d.text((x0 + 5, y0 + 3), t["name"], fill=colour, font=font)
    return img


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("work", type=Path)
    ap.add_argument("--pages", help="pages to render, e.g. '1-3,5' (default: the pages chosen at probe time)")
    ap.add_argument("--rotation", type=int, choices=(0, 90, 180, 270),
                    help="clockwise rotation for the selected pages (overrides detection)")
    ap.add_argument("--no-auto-rotate", action="store_true", help="skip OCR orientation detection")
    ap.add_argument("--long-edge", type=int,
                    help="render long edge in px (default: chosen from measured text size; "
                         f"{DEFAULT_VECTOR_EDGE} for vector pages without OCR)")
    ap.add_argument("--tile", type=int, default=1400)
    ap.add_argument("--overlap", type=int, default=200)
    args = ap.parse_args()
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)

    from PIL import Image

    manifest_path = args.work / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    pdf = manifest["source_pdf"]
    pages = parse_pages(args.pages, len(manifest["pages"]), manifest.get("selected_pages"))
    can_ocr = ocr.available()
    if not can_ocr and not args.no_auto_rotate and args.rotation is None:
        print(f"note: {ocr.maybe_import_error()}")

    for page_no in pages:
        info = manifest["pages"][page_no - 1]
        cls = info["page_class"]
        if cls == "blank":
            print(f"page {page_no}: blank, skipped")
            continue
        rotation = info.get("rotation")
        text_box = None
        if args.rotation is not None:
            rotation, info["rotation_source"] = args.rotation, "user"
        if can_ocr and (rotation is None and not args.no_auto_rotate or args.long_edge is None):
            preview = render_page(pdf, page_no, cls, 0, vector_long_edge=PREVIEW_EDGE,
                                  raster_long_edge=PREVIEW_EDGE)
            if rotation is None and not args.no_auto_rotate:
                rotation, scores, text_box = ocr.detect_rotation(preview)
                info["rotation_source"], info["rotation_scores"] = "ocr", scores
            else:
                _, _, text_box = ocr.detect_rotation(preview, rotations=(rotation or 0,))
            if text_box:
                # Text box height at the long edge the render will use.
                text_box = text_box / max(preview.size)
        if rotation is None:
            rotation, info["rotation_source"] = 0, "default (unverified)"
        info["rotation"] = rotation

        long_edge = args.long_edge
        if long_edge is None and text_box:
            long_edge = round(TARGET_TEXT_BOX / text_box)
            lo, hi = (MIN_EDGE, MAX_EDGE)
            long_edge = max(lo, min(hi, long_edge))
            info["text_box_fraction"] = round(text_box, 5)
        img = render_page(pdf, page_no, cls, rotation,
                          vector_long_edge=long_edge or DEFAULT_VECTOR_EDGE,
                          raster_long_edge=long_edge or DEFAULT_RASTER_EDGE)
        out = args.work / "pages" / f"page_{page_no:02d}"
        (out / "tiles").mkdir(parents=True, exist_ok=True)
        for old in (out / "tiles").glob("*.png"):
            old.unlink()
        img.save(out / "page.png")

        tiles = tile_grid(img.width, img.height, args.tile, args.overlap)
        for t in tiles:
            crop = img.crop(tuple(t["px"]))
            t["ink"] = round(ink_fraction(crop), 5)
            t["blank"] = t["ink"] < BLANK_INK
            crop.save(out / "tiles" / f"{t['name']}.png")

        scale = OVERVIEW_LONG_EDGE / max(img.size)
        overview = img.resize((round(img.width * scale), round(img.height * scale)), Image.LANCZOS)
        overview.save(out / "overview.png")
        draw_grid(overview, tiles, scale, img.width, img.height).save(out / "overview_grid.png")

        meta = {"page": page_no, "page_class": cls, "rotation": rotation,
                "rotation_source": info.get("rotation_source"), "width": img.width,
                "height": img.height, "tile": args.tile, "overlap": args.overlap, "tiles": tiles}
        (out / "tiles.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")
        info["rendered"] = {"width": img.width, "height": img.height, "tiles": len(tiles),
                            "non_blank_tiles": sum(not t["blank"] for t in tiles)}
        manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
        print(f"page {page_no}: {cls}, rotation {rotation} ({info.get('rotation_source')}), "
              f"{img.width}x{img.height}, {info['rendered']['non_blank_tiles']}/{len(tiles)} "
              f"non-blank tiles -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
