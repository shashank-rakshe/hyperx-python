"""Image ingestor (raster fallback) for scanned/exported sheet images.

A standalone raster image has no vector structure to recover, so L0 tiles it and hands
it to L1 perception (stub). No entities are fabricated; the sheet is recorded as
raster-origin / awaiting perception.
"""

from __future__ import annotations

from pathlib import Path

from cir import DrawingSet, PageSize, Sheet, SourceFile, View, ViewType

from .base import Ingestor, register
from .raster import rasterize_and_handoff


@register
class ImageIngestor(Ingestor):
    """Ingest a raster image into the CIR (raster fallback)."""

    file_types = ("png", "jpg", "jpeg", "tif", "tiff", "bmp")

    def ingest(self, path: Path) -> DrawingSet:
        from PIL import Image

        with Image.open(path) as img:
            width, height = img.size
            tiled = rasterize_and_handoff(img, sheet_id=path.stem, dpi=None)
        sheet = Sheet(
            sheet_number=path.stem,
            page_index=0,
            size=PageSize(width=float(width), height=float(height), unit="px"),
            views=[View(view_type=ViewType.PLAN, entities=[])],
            attributes={"origin": "raster", "needs_perception": True, "n_tiles": len(tiled.tiles)},
        )
        return DrawingSet(
            name=path.stem,
            source=SourceFile(
                filename=path.name, file_type="image", is_vector=False, ingest_tool="pillow"
            ),
            sheets=[sheet],
            **self.stamp(),
        )
