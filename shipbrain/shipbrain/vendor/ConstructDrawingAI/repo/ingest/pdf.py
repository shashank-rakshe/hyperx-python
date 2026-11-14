"""PDF ingestor (vector-first, raster fallback) via PyMuPDF.

Each page becomes a CIR :class:`~cir.Sheet`. A page is classified vector or raster:

* **Vector** (has selectable text and/or vector drawings): extract text words and
  drawn paths directly with exact geometry.
* **Raster** (a flattened/scanned page — essentially one image, no text/vectors):
  rasterize at >=300 DPI, tile, and hand off to L1 perception (stub). No entities are
  fabricated; the sheet is marked raster-origin / awaiting perception.

Per sheet we also parse the title block (sheet number, discipline, scale) and detect
cross-reference callouts as CIR sheet-graph edges.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from cir import (
    DrawingSet,
    Entity,
    EntityType,
    Geometry,
    GeometryType,
    PageSize,
    Sheet,
    SourceBBox,
    SourceFile,
    TextSpan,
    View,
    ViewType,
)

from .base import Ingestor, register
from .normalize import Bounds, Normalizer
from .raster import DEFAULT_DPI, rasterize_and_handoff, rasterize_pdf_page
from .sheets import (
    discipline_for_letter,
    find_cross_references,
    parse_sheet_number,
    parse_title_block,
)


@register
class PDFIngestor(Ingestor):
    """Ingest a (possibly multi-page) PDF into the CIR."""

    file_types = ("pdf",)

    def ingest(self, path: Path) -> DrawingSet:
        import fitz  # PyMuPDF

        doc = fitz.open(str(path))
        sheets: list[Sheet] = []
        any_vector = False
        for index, page in enumerate(doc):
            sheet, is_vector = self._page_to_sheet(page, index)
            any_vector = any_vector or is_vector
            sheets.append(sheet)
        page_count = len(doc)
        doc.close()
        return DrawingSet(
            name=path.stem,
            source=SourceFile(
                filename=path.name,
                file_type="pdf",
                is_vector=any_vector,
                page_count=page_count,
                ingest_tool="pymupdf",
            ),
            sheets=sheets,
            **self.stamp(),
        )

    def _page_to_sheet(self, page: Any, index: int) -> tuple[Sheet, bool]:
        text = page.get_text("text")
        title_block, scale = parse_title_block(text)
        cross_refs = find_cross_references(text)
        parsed_number = parse_sheet_number(text)
        # Only infer discipline from a real parsed number, never from the P-N fallback.
        discipline = discipline_for_letter(parsed_number[0]) if parsed_number else None
        sheet_number = parsed_number or f"P-{index + 1}"

        width, height = float(page.rect.width), float(page.rect.height)
        normalizer = Normalizer(Bounds(0.0, 0.0, width, height), flip_y=False)
        is_vector = self._is_vector(page, text)

        if is_vector:
            entities = self._vector_entities(page, normalizer, index)
            attributes: dict[str, Any] = {"origin": "vector", "n_entities": len(entities)}
        else:
            tiled = rasterize_and_handoff(
                rasterize_pdf_page(page, dpi=DEFAULT_DPI), sheet_id=sheet_number, dpi=DEFAULT_DPI
            )
            entities = []
            attributes = {
                "origin": "raster",
                "dpi": DEFAULT_DPI,
                "needs_perception": True,
                "n_tiles": len(tiled.tiles),
            }

        view = View(name=sheet_number, view_type=ViewType.PLAN, scale=scale, entities=entities)
        sheet = Sheet(
            sheet_number=sheet_number,
            discipline=discipline,
            page_index=index,
            size=PageSize(width=width, height=height, unit="pt"),
            scale=scale,
            title_block=title_block,
            views=[view],
            cross_references=cross_refs,
            attributes=attributes,
        )
        return sheet, is_vector

    @staticmethod
    def _is_vector(page: Any, text: str) -> bool:
        if len(text.strip()) >= 16 or len(page.get_drawings()) >= 3:
            return True
        # No text and no vectors: if it is essentially a full-page image, it's raster.
        return not page.get_images(full=True)

    def _vector_entities(self, page: Any, normalizer: Normalizer, page_index: int) -> list[Entity]:
        entities: list[Entity] = []

        # Text words.
        for word in page.get_text("words"):
            x0, y0, x1, y1, text = word[0], word[1], word[2], word[3], word[4]
            if not str(text).strip():
                continue
            nb = normalizer.bbox(x0, y0, x1, y1)
            entities.append(
                Entity(
                    entity_type=EntityType.TEXT,
                    label=str(text),
                    geometry=Geometry.box(nb.x_min, nb.y_min, nb.x_max, nb.y_max),
                    text_spans=[TextSpan(text=str(text))],
                    source_bbox=SourceBBox(
                        x_min=x0, y_min=y0, x_max=x1, y_max=y1, unit="pt", page=page_index
                    ),
                    confidence=1.0,
                    produced_by="pymupdf",
                    **self.stamp(),
                )
            )

        # Vector drawings (one entity per drawn path).
        for path in page.get_drawings():
            pts = _path_points(path)
            if len(pts) < 2:
                continue
            filled = path.get("fill") is not None
            geom_type = GeometryType.POLYGON if filled else GeometryType.POLYLINE
            entities.append(
                Entity(
                    entity_type=EntityType.POLYGON if filled else EntityType.POLYLINE,
                    geometry=Geometry(type=geom_type, points=normalizer.points(pts)),
                    source_bbox=_source_bbox(pts, page_index),
                    confidence=1.0,
                    produced_by="pymupdf",
                    attributes={"origin": "vector"},
                    **self.stamp(),
                )
            )
        return entities


def _path_points(path: dict[str, Any]) -> list[tuple[float, float]]:
    pts: list[tuple[float, float]] = []
    for item in path.get("items", []):
        op = item[0]
        if op == "l":  # line: p1, p2
            pts.append((item[1].x, item[1].y))
            pts.append((item[2].x, item[2].y))
        elif op == "c":  # bezier: p1..p4 (keep endpoints)
            pts.append((item[1].x, item[1].y))
            pts.append((item[4].x, item[4].y))
        elif op == "re":  # rectangle
            r = item[1]
            pts.extend([(r.x0, r.y0), (r.x1, r.y0), (r.x1, r.y1), (r.x0, r.y1)])
        elif op == "qu":  # quad
            q = item[1]
            pts.extend([(q.ul.x, q.ul.y), (q.ur.x, q.ur.y), (q.lr.x, q.lr.y), (q.ll.x, q.ll.y)])
    # drop consecutive duplicates
    deduped: list[tuple[float, float]] = []
    for p in pts:
        if not deduped or deduped[-1] != p:
            deduped.append(p)
    return deduped


def _source_bbox(pts: list[tuple[float, float]], page_index: int) -> SourceBBox:
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return SourceBBox(
        x_min=min(xs), y_min=min(ys), x_max=max(xs), y_max=max(ys), unit="pt", page=page_index
    )
