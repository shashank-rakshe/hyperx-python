"""PDF inspection and rendering (pypdfium2: Apache-2.0/BSD, no system dependencies)."""

from __future__ import annotations

import math
from dataclasses import asdict, dataclass, field
from typing import Optional

import pypdfium2 as pdfium
import pypdfium2.raw as pdfium_c

# Page classes and how each is extracted.
ROUTES = {
    "vector_text": "Vector drawing with a text layer: render from vectors, take exact text and "
                   "positions from the text layer as hints, then read visually.",
    "vector_outlined": "Vector drawing whose text was converted to outlines (no text layer): "
                       "render from vectors at high resolution, OCR the render for hints, then "
                       "read visually.",
    "raster": "Scanned image: render at the scan's native resolution, upscale and enhance "
              "contrast, OCR for hints, then read visually.",
    "raster_with_text": "Scanned image with an OCR text layer: as raster, and use the existing "
                        "text layer as (untrusted) hints.",
    "hybrid": "Mix of vector content and large images: render from vectors at high "
              "resolution and use both text layer and OCR hints.",
    "blank": "No meaningful content.",
}

MIN_TEXT_CHARS = 50
MIN_VECTOR_PATHS = 200
BIG_IMAGE_COVERAGE = 0.5


@dataclass
class PageProbe:
    page: int
    width_pt: float
    height_pt: float
    pdf_rotation: int
    text_chars: int
    path_objects: int
    text_objects: int
    image_objects: int
    max_image_coverage: float
    image_px: Optional[list[int]]
    effective_image_dpi: Optional[float]
    page_class: str
    route: str = ""
    rotation: Optional[int] = None
    notes: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return asdict(self)


def probe_pdf(path: str) -> list[PageProbe]:
    pdf = pdfium.PdfDocument(path)
    try:
        return [probe_page(pdf, i) for i in range(len(pdf))]
    finally:
        pdf.close()


def probe_page(pdf: "pdfium.PdfDocument", index: int) -> PageProbe:
    page = pdf[index]
    w, h = page.get_size()
    area = max(w * h, 1.0)
    tp = page.get_textpage()
    text = tp.get_text_range() or ""
    chars = sum(1 for ch in text if not ch.isspace())
    counts = {pdfium_c.FPDF_PAGEOBJ_PATH: 0, pdfium_c.FPDF_PAGEOBJ_TEXT: 0, pdfium_c.FPDF_PAGEOBJ_IMAGE: 0}
    best_cov, best_px, best_dpi = 0.0, None, None
    for obj in page.get_objects(max_depth=8):
        if obj.type in counts:
            counts[obj.type] += 1
        if obj.type == pdfium_c.FPDF_PAGEOBJ_IMAGE:
            l, b, r, t = obj.get_bounds()
            cov = max(0.0, (r - l) * (t - b)) / area
            if cov > best_cov:
                best_cov = cov
                try:
                    px = list(obj.get_px_size())
                    best_px = px
                    best_dpi = round(72.0 * max(px) / max(r - l, t - b, 1e-6), 1)
                except Exception:  # pragma: no cover - exotic image types
                    best_px, best_dpi = None, None
    paths = counts[pdfium_c.FPDF_PAGEOBJ_PATH]
    has_text = chars >= MIN_TEXT_CHARS
    has_vec = paths >= MIN_VECTOR_PATHS
    big_img = best_cov >= BIG_IMAGE_COVERAGE
    if big_img and not has_vec:
        cls = "raster_with_text" if has_text else "raster"
    elif big_img and has_vec:
        cls = "hybrid"
    elif has_text:
        cls = "vector_text"
    elif has_vec:
        cls = "vector_outlined"
    elif paths or counts[pdfium_c.FPDF_PAGEOBJ_IMAGE]:
        cls = "vector_outlined" if paths else "raster"
    else:
        cls = "blank"
    probe = PageProbe(
        page=index + 1, width_pt=round(w, 1), height_pt=round(h, 1),
        pdf_rotation=page.get_rotation(), text_chars=chars, path_objects=paths,
        text_objects=counts[pdfium_c.FPDF_PAGEOBJ_TEXT],
        image_objects=counts[pdfium_c.FPDF_PAGEOBJ_IMAGE],
        max_image_coverage=round(best_cov, 3), image_px=best_px, effective_image_dpi=best_dpi,
        page_class=cls, route=ROUTES[cls])
    if cls.startswith("raster") and best_dpi and best_dpi < 200:
        probe.notes.append(f"low scan resolution (~{best_dpi:.0f} dpi): small text may be "
                           "illegible; record unreadable items in 'unreadable'")
    if max(w, h) < 1000:
        probe.notes.append("page is smaller than a typical drawing sheet; the drawing was "
                           "probably reduced, so render at high resolution")
    return probe


def render_page(pdf_path: str, page_no: int, page_class: str, rotation: int = 0,
                vector_long_edge: int = 5000, raster_long_edge: int = 4000,
                max_upscale: float = 2.5):
    """Render a page to a PIL image following the route for its class."""
    from PIL import Image, ImageOps

    pdf = pdfium.PdfDocument(pdf_path)
    try:
        page = pdf[page_no - 1]
        w, h = page.get_size()
        if page_class.startswith("raster"):
            probe = probe_page(pdf, page_no - 1)
            native = (probe.effective_image_dpi or 200) / 72.0
            img = page.render(scale=native, rotation=rotation, grayscale=True).to_pil()
            long_edge = max(img.size)
            factor = min(max_upscale, max(1.0, raster_long_edge / long_edge))
            if factor > 1.0:
                img = img.resize((round(img.width * factor), round(img.height * factor)),
                                 Image.LANCZOS)
            img = ImageOps.autocontrast(img.convert("L"), cutoff=0.5)
            return img
        scale = vector_long_edge / max(w, h)
        return page.render(scale=scale, rotation=rotation).to_pil().convert("RGB")
    finally:
        pdf.close()


def tile_grid(width: int, height: int, tile: int = 1400, overlap: int = 200) -> list[dict]:
    """Evenly spaced overlapping tiles covering the image."""
    def spans(total: int) -> list[tuple[int, int]]:
        if total <= tile:
            return [(0, total)]
        n = math.ceil((total - overlap) / (tile - overlap))
        step = (total - tile) / (n - 1)
        return [(round(i * step), round(i * step) + tile) for i in range(n)]

    tiles = []
    for r, (y0, y1) in enumerate(spans(height), 1):
        for c, (x0, x1) in enumerate(spans(width), 1):
            tiles.append({"name": f"r{r}c{c}", "row": r, "col": c, "px": [x0, y0, x1, y1],
                          "norm": [round(x0 / width, 4), round(y0 / height, 4),
                                   round(x1 / width, 4), round(y1 / height, 4)]})
    return tiles


def ink_fraction(img, threshold: int = 200) -> float:
    """Fraction of pixels darker than ``threshold``, ignoring frame lines.

    Rows and columns that are dark across most of the tile (the drawing
    border, title-block rules) are not content, so they are excluded; a tile
    holding only a border line then counts as blank.
    """
    g = img.convert("L")
    try:
        import numpy as np
    except ImportError:  # pragma: no cover - numpy ships with the OCR extra
        hist = g.histogram()
        return sum(hist[:threshold]) / max(1, g.width * g.height)
    dark = np.asarray(g) < threshold
    rows = dark.mean(axis=1) > 0.6
    cols = dark.mean(axis=0) > 0.6
    dark[rows, :] = False
    dark[:, cols] = False
    return float(dark.mean())


def rotate_norm_bbox(b: list[float], rotation: int) -> list[float]:
    """Map a normalized bbox on the unrotated page onto the page rotated clockwise."""
    x0, y0, x1, y1 = b
    pts = [(x0, y0), (x1, y1)]
    if rotation == 90:
        pts = [(1 - y, x) for x, y in pts]
    elif rotation == 180:
        pts = [(1 - x, 1 - y) for x, y in pts]
    elif rotation == 270:
        pts = [(y, 1 - x) for x, y in pts]
    (a, b2), (c, d) = pts
    return [round(min(a, c), 4), round(min(b2, d), 4), round(max(a, c), 4), round(max(b2, d), 4)]


def text_runs(pdf_path: str, page_no: int, rotation: int = 0) -> list[dict]:
    """Text-layer runs with normalized bboxes on the (rotated) page."""
    pdf = pdfium.PdfDocument(pdf_path)
    try:
        page = pdf[page_no - 1]
        w, h = page.get_size()
        tp = page.get_textpage()
        runs = []
        for i in range(tp.count_rects()):
            l, b, r, t = tp.get_rect(i)
            txt = (tp.get_text_bounded(l, b, r, t) or "").strip()
            if not txt:
                continue
            norm = [l / w, 1 - t / h, r / w, 1 - b / h]
            runs.append({"text": txt, "bbox": rotate_norm_bbox(norm, rotation), "conf": 1.0})
        return runs
    finally:
        pdf.close()
