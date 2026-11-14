"""Raster handling: rasterize at >=300 DPI and hand off to perception (stub).

For flattened/scanned pages there is no vector structure to recover, so L0 rasterizes
at print resolution, tiles the image (:mod:`ingest.tiling`), and hands the tiles to L1
perception. The handoff is a **stub** until the perception models land (Build Playbook
2.x); for now it records that the sheet needs perception and returns nothing.
"""

from __future__ import annotations

import logging
from typing import Any

from .tiling import TiledSheet, tile_image

logger = logging.getLogger(__name__)

#: Default rasterization resolution for scanned pages (print quality).
DEFAULT_DPI = 300


def rasterize_pdf_page(page: Any, *, dpi: int = DEFAULT_DPI) -> Any:
    """Rasterize a PyMuPDF ``page`` to a PIL image at ``dpi``."""
    from PIL import Image

    pixmap = page.get_pixmap(dpi=dpi)
    return Image.frombytes("RGB", (pixmap.width, pixmap.height), pixmap.samples)


def handoff_to_perception(tiled: TiledSheet, *, sheet_id: str, dpi: int | None) -> None:
    """STUB: hand a tiled, rasterized sheet to L1 perception.

    Wired to the real detectors/vectorizer in Build Playbook step 2.x. For now this is
    a no-op that logs the handoff; the ingestor records on the CIR sheet that it is
    raster-origin and awaiting perception.
    """
    logger.info(
        "perception handoff (stub): sheet=%s tiles=%d dpi=%s — no perception model wired yet",
        sheet_id,
        len(tiled.tiles),
        dpi,
    )


def rasterize_and_handoff(image: Any, *, sheet_id: str, dpi: int | None = None) -> TiledSheet:
    """Tile a raster image and hand it to perception; return the tiling for the record."""
    tiled = tile_image(image, sheet_id=sheet_id, dpi=dpi)
    handoff_to_perception(tiled, sheet_id=sheet_id, dpi=dpi)
    return tiled
