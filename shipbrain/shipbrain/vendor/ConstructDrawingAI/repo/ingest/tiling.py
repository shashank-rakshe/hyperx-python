"""Overlapping sliding-window tiler for gigapixel sheets.

Splits a rasterized sheet into overlapping tiles (default ~1536 px, ~12% overlap) plus
a downsampled global-context view (the AnyRes pattern). Each tile carries an explicit
:class:`~ingest.handoff.TileRef` describing exactly how its coordinates compose back
onto the sheet — the documented L0->L1 contract (see ``docs/HANDOFF.md`` and
:mod:`ingest.handoff`). Pillow is imported lazily.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

from cir import BBox

from .handoff import PixelRegion, TileRef


@dataclass(frozen=True)
class Tile:
    """A tile image paired with its handoff contract metadata."""

    image: Any  # PIL.Image.Image (the crop)
    ref: TileRef


@dataclass(frozen=True)
class TiledSheet:
    """All tiles for a sheet plus a downsampled global-context view."""

    sheet_id: str
    tiles: list[Tile]
    global_view: Any  # PIL.Image.Image
    full_width: int
    full_height: int
    tile_size: int
    overlap: int

    @property
    def refs(self) -> dict[str, TileRef]:
        """Map of tile_id -> TileRef, for composing detections back to the sheet."""
        return {t.ref.tile_id: t.ref for t in self.tiles}


def _as_pil(image: Any) -> Any:
    from PIL import Image

    # Real plan sheets at >=300 DPI are legitimately gigapixel; lift PIL's DOS guard
    # (these are trusted CAD rasters, not adversarial uploads).
    Image.MAX_IMAGE_PIXELS = None
    if isinstance(image, (str, Path)):
        return Image.open(image).convert("RGB")
    if isinstance(image, Image.Image):
        return image.convert("RGB")
    return Image.fromarray(image).convert("RGB")  # numpy array


def _starts(total: int, size: int, step: int) -> list[int]:
    """Tile start offsets covering [0, total], last tile clamped to the edge."""
    if total <= size:
        return [0]
    starts = []
    pos = 0
    while True:
        starts.append(pos)
        if pos + size >= total:
            break
        pos += step
    return starts


def tile_image(
    image: Any,
    *,
    sheet_id: str = "sheet",
    tile_size: int = 1536,
    overlap: int = 192,
    max_global: int = 1024,
    dpi: int | None = None,
) -> TiledSheet:
    """Split ``image`` into overlapping tiles (each with a :class:`TileRef`) + a global view."""
    img = _as_pil(image)
    width, height = img.size
    step = max(1, tile_size - overlap)
    xs = _starts(width, tile_size, step)
    ys = _starts(height, tile_size, step)

    tiles: list[Tile] = []
    for row, y in enumerate(ys):
        for col, x in enumerate(xs):
            x2, y2 = min(x + tile_size, width), min(y + tile_size, height)
            ref = _make_ref(
                sheet_id=sheet_id,
                row=row,
                col=col,
                x=x,
                y=y,
                x2=x2,
                y2=y2,
                first_col=(col == 0),
                last_col=(col == len(xs) - 1),
                first_row=(row == 0),
                last_row=(row == len(ys) - 1),
                full_width=width,
                full_height=height,
                overlap=overlap,
                dpi=dpi,
            )
            tiles.append(Tile(image=img.crop((x, y, x2, y2)), ref=ref))

    global_view = img.copy()
    global_view.thumbnail((max_global, max_global))
    return TiledSheet(sheet_id, tiles, global_view, width, height, tile_size, overlap)


def _make_ref(
    *,
    sheet_id: str,
    row: int,
    col: int,
    x: int,
    y: int,
    x2: int,
    y2: int,
    first_col: bool,
    last_col: bool,
    first_row: bool,
    last_row: bool,
    full_width: int,
    full_height: int,
    overlap: int,
    dpi: int | None,
) -> TileRef:
    half = overlap // 2
    left = 0 if first_col else half
    right = 0 if last_col else half
    top = 0 if first_row else half
    bottom = 0 if last_row else half
    cx0, cx1 = x + left, x2 - right
    cy0, cy1 = y + top, y2 - bottom
    if cx1 <= cx0 or cy1 <= cy0:  # degenerate guard: fall back to the full tile
        cx0, cy0, cx1, cy1 = x, y, x2, y2

    return TileRef(
        tile_id=f"{sheet_id}:r{row}c{col}",
        sheet_id=sheet_id,
        row=row,
        col=col,
        full_width=full_width,
        full_height=full_height,
        pixel=PixelRegion(x=x, y=y, width=x2 - x, height=y2 - y),
        region=BBox(
            x_min=x / full_width,
            y_min=y / full_height,
            x_max=x2 / full_width,
            y_max=y2 / full_height,
        ),
        core=BBox(
            x_min=cx0 / full_width,
            y_min=cy0 / full_height,
            x_max=cx1 / full_width,
            y_max=cy1 / full_height,
        ),
        core_pixel=PixelRegion(x=cx0, y=cy0, width=cx1 - cx0, height=cy1 - cy0),
        overlap_px=overlap,
        dpi=dpi,
    )
