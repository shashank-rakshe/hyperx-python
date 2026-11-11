#!/usr/bin/env python3
"""Classify every page of a P&ID PDF and start a work directory.

Each page is classified as vector_text, vector_outlined, raster,
raster_with_text, hybrid or blank, which decides how it is rendered and
which hints are available. Writes <work>/manifest.json.

Usage:
    python probe_pdf.py drawings.pdf --work work/my-plant --plant-name "My Plant"
    python probe_pdf.py permit.pdf --work work/my-plant --pages 47-60   # only the P&ID pages
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from pidkg.pdf import probe_pdf  # noqa: E402
from render_pages import parse_pages  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pdf", type=Path)
    ap.add_argument("--work", type=Path, required=True, help="work directory for this plant")
    ap.add_argument("--plant-name", help="human-readable plant name (default: PDF file name)")
    ap.add_argument("--plant-id", help="short id (default: slug of the plant name)")
    ap.add_argument("--pages", help="pages that hold the P&IDs, e.g. '47-60' or '50-51,62-63' "
                                    "(default: all). Later steps use only these pages.")
    args = ap.parse_args()

    if not args.pdf.exists():
        print(f"error: {args.pdf} not found", file=sys.stderr)
        return 2
    name = args.plant_name or args.pdf.stem
    plant_id = args.plant_id or re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    probes = probe_pdf(str(args.pdf))

    args.work.mkdir(parents=True, exist_ok=True)
    manifest_path = args.work / "manifest.json"
    previous = {}
    if manifest_path.exists():
        old = json.loads(manifest_path.read_text(encoding="utf-8"))
        previous = {p["page"]: p for p in old.get("pages", [])}
    pages = []
    for p in probes:
        d = p.to_dict()
        # Keep a rotation that was already confirmed for this page.
        if previous.get(p.page, {}).get("rotation") is not None:
            d["rotation"] = previous[p.page]["rotation"]
            d["rotation_source"] = previous[p.page].get("rotation_source")
        pages.append(d)
    selected = parse_pages(args.pages, len(probes)) if args.pages else None
    if args.pages and not selected:
        print(f"error: --pages {args.pages} selects no page of a {len(probes)}-page PDF", file=sys.stderr)
        return 2
    manifest = {"source_pdf": str(args.pdf.resolve()), "plant_id": plant_id, "plant_name": name,
                "pages": pages}
    if selected:
        manifest["selected_pages"] = selected
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")

    shown = [p for p in probes if not selected or p.page in selected]
    print(f"{args.pdf.name}: {len(probes)} pages -> {manifest_path}")
    if selected:
        print(f"using {len(selected)} selected pages: {args.pages}")
    print(f"{'page':>4}  {'class':<17} {'chars':>6} {'paths':>6} {'img cov':>7}  notes")
    for p in shown:
        print(f"{p.page:>4}  {p.page_class:<17} {p.text_chars:>6} {p.path_objects:>6} "
              f"{p.max_image_coverage:>7.2f}  {'; '.join(p.notes)}")
    classes = sorted({p.page_class for p in probes})
    print("\nRoutes:")
    for c in classes:
        print(f"  {c}: {next(p.route for p in probes if p.page_class == c)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
