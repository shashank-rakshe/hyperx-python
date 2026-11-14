"""Tiling for gigapixel drawings before sending them to a vision model.

**OPTIONAL / UNUSED in the default flow** — this is used only by the opt-in live
vision adapters in :mod:`eval.frontier`. The default demo/leaderboard never call it.

Drawings routinely exceed 4000x3000 px; a naive send compresses them to ~1k px and
destroys the dense symbols that matter. :func:`tile_image` splits a page into
overlapping tiles plus a downsampled global-context view (the AnyRes pattern), and
:func:`nms` merges per-tile detections back into one full-page set with cross-tile
non-maximum suppression. Pillow is imported lazily so the module imports without it.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

from cir import BBox

NormBox = tuple[float, float, float, float]  # (x0, y0, x1, y1) normalized


@dataclass(frozen=True)
class Tile:
    """A crop of the page plus its pixel offset/size in the original image."""

    image: Any  # PIL.Image.Image
    x: int
    y: int
    width: int
    height: int


@dataclass(frozen=True)
class TiledImage:
    """The full set of tiles + a downsampled global-context view."""

    tiles: list[Tile]
    global_view: Any  # PIL.Image.Image
    full_width: int
    full_height: int


def tile_image(
    path: str | Path,
    *,
    tile_size: int = 1280,
    overlap: int = 128,
    max_global: int = 1024,
) -> TiledImage:
    """Split the image at ``path`` into overlapping tiles + a global-context view."""
    from PIL import Image

    img = Image.open(path).convert("RGB")
    width, height = img.size
    tiles: list[Tile] = []
    if width <= tile_size and height <= tile_size:
        tiles.append(Tile(img, 0, 0, width, height))
    else:
        step = max(1, tile_size - overlap)
        for y in range(0, height, step):
            for x in range(0, width, step):
                x2, y2 = min(x + tile_size, width), min(y + tile_size, height)
                tiles.append(Tile(img.crop((x, y, x2, y2)), x, y, x2 - x, y2 - y))
    global_view = img.copy()
    global_view.thumbnail((max_global, max_global))
    return TiledImage(tiles, global_view, width, height)


def tile_box_to_global(box: NormBox, tile: Tile, full_width: int, full_height: int) -> NormBox:
    """Remap a box normalized within ``tile`` to coordinates normalized on the full page."""
    x0 = (tile.x + box[0] * tile.width) / full_width
    y0 = (tile.y + box[1] * tile.height) / full_height
    x1 = (tile.x + box[2] * tile.width) / full_width
    y1 = (tile.y + box[3] * tile.height) / full_height
    return (x0, y0, x1, y1)


def nms(detections: list[dict[str, Any]], *, iou_threshold: float = 0.5) -> list[dict[str, Any]]:
    """Per-label non-maximum suppression over detections with normalized boxes.

    Each detection is a dict ``{"label", "bbox": NormBox, "confidence"}``. Used to
    merge overlapping detections across tile boundaries.
    """
    kept: list[dict[str, Any]] = []
    for label in {d["label"] for d in detections}:
        group = sorted(
            (d for d in detections if d["label"] == label),
            key=lambda d: d["confidence"],
            reverse=True,
        )
        kept_boxes: list[BBox] = []
        for det in group:
            box = BBox(
                x_min=det["bbox"][0],
                y_min=det["bbox"][1],
                x_max=det["bbox"][2],
                y_max=det["bbox"][3],
            )
            if all(box.iou(k) < iou_threshold for k in kept_boxes):
                kept.append(det)
                kept_boxes.append(box)
    return kept
