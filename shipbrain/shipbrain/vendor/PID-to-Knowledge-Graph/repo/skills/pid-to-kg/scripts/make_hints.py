#!/usr/bin/env python3
"""Collect deterministic text hints for each rendered page.

Hints are candidate tags with page positions, gathered without the LLM:

* text layer (vector_text, raster_with_text, hybrid pages): exact text and
  positions straight from the PDF;
* OCR (vector_outlined, raster, hybrid pages; needs rapidocr-onnxruntime):
  each non-blank tile is OCR'd and mapped back to page coordinates.

ISA bubbles split over two lines ('FIT' over '0502') are joined. QA compares
these candidates with the extraction to flag tags that may have been missed.
Writes <work>/hints/page_NN.json.

Usage:
    python make_hints.py work/my-plant [--pages 1-3] [--no-ocr]
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from pidkg import ocr  # noqa: E402
from pidkg.pdf import text_runs  # noqa: E402
from render_pages import parse_pages  # noqa: E402

TEXT_LAYER_CLASSES = {"vector_text", "raster_with_text", "hybrid"}
OCR_CLASSES = {"vector_outlined", "raster", "hybrid"}


def tiles_for(bbox: list[float], tiles: list[dict]) -> list[str]:
    cx, cy = (bbox[0] + bbox[2]) / 2, (bbox[1] + bbox[3]) / 2
    return [t["name"] for t in tiles if t["norm"][0] <= cx <= t["norm"][2]
            and t["norm"][1] <= cy <= t["norm"][3]]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("work", type=Path)
    ap.add_argument("--pages")
    ap.add_argument("--no-ocr", action="store_true")
    args = ap.parse_args()
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)

    from PIL import Image

    manifest = json.loads((args.work / "manifest.json").read_text(encoding="utf-8"))
    use_ocr = not args.no_ocr and ocr.available()
    if not args.no_ocr and not use_ocr:
        print(f"note: {ocr.maybe_import_error()}")
    (args.work / "hints").mkdir(exist_ok=True)

    for page_no in parse_pages(args.pages, len(manifest["pages"]), manifest.get("selected_pages")):
        info = manifest["pages"][page_no - 1]
        cls = info["page_class"]
        page_dir = args.work / "pages" / f"page_{page_no:02d}"
        tiles_file = page_dir / "tiles.json"
        if not tiles_file.exists():
            print(f"page {page_no}: not rendered yet (run render_pages.py), skipped")
            continue
        meta = json.loads(tiles_file.read_text(encoding="utf-8"))
        runs: list[dict] = []
        sources: list[str] = []
        if cls in TEXT_LAYER_CLASSES:
            runs += [dict(r, source="text_layer")
                     for r in text_runs(manifest["source_pdf"], page_no, meta["rotation"])]
            sources.append("text_layer")
        if cls in OCR_CLASSES and use_ocr:
            for t in meta["tiles"]:
                if t.get("blank"):
                    continue
                img = Image.open(page_dir / "tiles" / f"{t['name']}.png")
                for r in ocr.ocr_image(img):
                    if r["conf"] < 0.5 or not r["text"]:
                        continue
                    runs.append({"text": r["text"], "conf": round(r["conf"], 3), "source": "ocr",
                                 "bbox": ocr.to_norm(r["bbox"], t["px"], meta["width"], meta["height"])})
            sources.append("ocr")
        runs = ocr.dedupe_runs(runs)
        runs = ocr.join_bubbles(runs)
        cands = ocr.tag_candidates(runs)
        for c in cands:
            c["tiles"] = tiles_for(c["bbox"], meta["tiles"])
        out = {"page": page_no, "source": "+".join(sources) or "none", "page_class": cls,
               "tag_candidates": cands, "runs": runs}
        (args.work / "hints" / f"page_{page_no:02d}.json").write_text(
            json.dumps(out, indent=1), encoding="utf-8")
        print(f"page {page_no}: {len(runs)} text runs, {len(cands)} tag candidates ({out['source']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
