"""Optional OCR (RapidOCR, ONNX runtime; pip-installable, no system binaries).

OCR is used for two things only:

* detecting page orientation, and
* producing *hints*: candidate tags with positions that QA compares against
  Claude's visual extraction to flag possible misses.

It never writes to the graph directly.
"""

from __future__ import annotations

import re
from typing import Optional

from .isa import normalize_tag, parse_isa_tag

_engine = None

EQUIPMENT_LIKE = re.compile(r"^(\d{2,4}-)?[A-Z]{2,4}-\d{2,5}[A-Z]?$")
_LETTERS = re.compile(r"^[A-Z]{1,5}$")
_DIGITS = re.compile(r"^\d{2,5}[A-Z]?$")


def available() -> bool:
    try:
        import rapidocr_onnxruntime  # noqa: F401
        return True
    except ImportError:
        return False


def _get_engine():
    global _engine
    if _engine is None:
        from rapidocr_onnxruntime import RapidOCR

        _engine = RapidOCR()
    return _engine


def ocr_image(img) -> list[dict]:
    """OCR a PIL image. Returns [{'text', 'bbox' (pixels x0,y0,x1,y1), 'conf'}]."""
    import numpy as np

    arr = np.array(img.convert("RGB"))
    result, _ = _get_engine()(arr, use_cls=False)
    out = []
    for box, text, conf in result or []:
        xs = [p[0] for p in box]
        ys = [p[1] for p in box]
        out.append({"text": str(text).strip(), "bbox": [min(xs), min(ys), max(xs), max(ys)],
                    "conf": float(conf)})
    return out


def _upright_boxes(results: list[dict]) -> list[dict]:
    """Confident, horizontal, alphanumeric OCR boxes.

    Only horizontal boxes count: the recognizer silently turns tall crops, so
    sideways text would otherwise read in every orientation.
    """
    keep = []
    for r in results:
        t = re.sub(r"[^A-Za-z0-9]", "", r["text"])
        x0, y0, x1, y1 = r["bbox"]
        if (x1 - x0) > 1.2 * (y1 - y0) and len(t) >= 2 and r["conf"] >= 0.6:
            keep.append(r)
    return keep


def detect_rotation(img, rotations=(0, 90, 180, 270)) -> tuple[int, dict[int, float], Optional[float]]:
    """Find the clockwise rotation that makes the text upright, and measure text size.

    Returns (rotation, score per rotation, 25th-percentile text box height in
    pixels of ``img`` at that rotation, or None if no text was found).
    """
    scores: dict[int, float] = {}
    heights: dict[int, list[float]] = {}
    for rot in rotations:
        # PIL rotates counter-clockwise; negate to match the clockwise convention.
        test = img.rotate(-rot, expand=True) if rot else img
        boxes = _upright_boxes(ocr_image(test))
        scores[rot] = round(sum(r["conf"] * len(re.sub(r"[^A-Za-z0-9]", "", r["text"]))
                                for r in boxes), 1)
        heights[rot] = sorted(r["bbox"][3] - r["bbox"][1] for r in boxes)
    best = max(scores, key=scores.get)
    hs = heights[best]
    p25 = hs[len(hs) // 4] if len(hs) >= 8 else None
    return best, scores, p25


def join_bubbles(runs: list[dict]) -> list[dict]:
    """Join ISA bubble text split over two lines ('FIT' above '0502') into one run.

    ``runs`` use normalized page bboxes. Joined runs are added; originals kept.
    """
    letters = [r for r in runs if _LETTERS.match(r["text"].replace(" ", ""))]
    digits = [r for r in runs if _DIGITS.match(r["text"].replace(" ", ""))]
    joined = []
    for a in letters:
        ax0, ay0, ax1, ay1 = a["bbox"]
        h = ay1 - ay0
        acx = (ax0 + ax1) / 2
        best, best_gap = None, None
        for d in digits:
            dx0, dy0, dx1, dy1 = d["bbox"]
            dcx = (dx0 + dx1) / 2
            gap = dy0 - ay1
            width = max(ax1 - ax0, dx1 - dx0)
            if -0.5 * h <= gap <= 1.5 * h and abs(acx - dcx) <= 0.6 * width:
                if best_gap is None or gap < best_gap:
                    best, best_gap = d, gap
        if best is not None:
            text = f"{a['text'].replace(' ', '')}-{best['text'].replace(' ', '')}"
            bb = [min(ax0, best["bbox"][0]), ay0, max(ax1, best["bbox"][2]), best["bbox"][3]]
            joined.append({"text": text, "bbox": [round(v, 4) for v in bb],
                           "conf": round(min(a.get("conf", 1), best.get("conf", 1)), 3),
                           "joined": True})
    return runs + joined


def tag_candidates(runs: list[dict]) -> list[dict]:
    """Pick tag-like strings from text runs, de-duplicated by normalized tag."""
    seen: dict[str, dict] = {}
    for r in runs:
        tokens = [t for t in re.split(r"[\s,;()]+", r["text"]) if t]
        # Tags are often printed with a space ('FIT 0502'): also try adjacent pairs.
        pairs = [f"{a}-{b}" for a, b in zip(tokens, tokens[1:])
                 if _LETTERS.match(a) and _DIGITS.match(b)]
        for token in tokens + pairs:
            t = normalize_tag(token)
            if not t or len(t) < 4:
                continue
            isa = parse_isa_tag(t)
            eq = bool(EQUIPMENT_LIKE.match(t))
            if not isa and not eq:
                continue
            if t not in seen or r.get("conf", 0) > seen[t]["conf"]:
                seen[t] = {"text": t, "bbox": r["bbox"], "conf": r.get("conf", 1.0),
                           "isa": bool(isa), "equipment_like": eq}
    return sorted(seen.values(), key=lambda c: (c["bbox"][1], c["bbox"][0]))


def dedupe_runs(runs: list[dict], tol: float = 0.004) -> list[dict]:
    """Drop runs seen twice in overlapping tiles (same text, nearly same position)."""
    kept: list[dict] = []
    for r in sorted(runs, key=lambda r: -r.get("conf", 0)):
        cx = (r["bbox"][0] + r["bbox"][2]) / 2
        cy = (r["bbox"][1] + r["bbox"][3]) / 2
        dup = False
        for k in kept:
            if k["text"] != r["text"]:
                continue
            kx = (k["bbox"][0] + k["bbox"][2]) / 2
            ky = (k["bbox"][1] + k["bbox"][3]) / 2
            if abs(kx - cx) < tol and abs(ky - cy) < tol:
                dup = True
                break
        if not dup:
            kept.append(r)
    return kept


def to_norm(bbox_px: list[float], tile_px: list[int], page_w: int, page_h: int,
            tile_scale: float = 1.0) -> list[float]:
    """Convert a bbox in tile pixels to normalized page coordinates."""
    x0, y0, x1, y1 = (v / tile_scale for v in bbox_px)
    return [round((tile_px[0] + x0) / page_w, 4), round((tile_px[1] + y0) / page_h, 4),
            round((tile_px[0] + x1) / page_w, 4), round((tile_px[1] + y1) / page_h, 4)]


def maybe_import_error() -> Optional[str]:
    if available():
        return None
    return ("RapidOCR is not installed; OCR hints and automatic rotation are skipped. "
            "Install with: pip install rapidocr-onnxruntime")
