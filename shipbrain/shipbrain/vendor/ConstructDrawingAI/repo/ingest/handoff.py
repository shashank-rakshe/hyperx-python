"""The L0 -> L1 tiling handoff contract.

This is the seam where L1 perception results get stitched back onto the global sheet.
A stitching error here becomes a *counting* error — the core metric of the MEP wedge —
so the contract is an explicit, validated schema rather than an ad-hoc dict.

Coordinate systems (all documented on :class:`TileRef`):

* **Full-raster pixels** — integer pixels of the rasterized sheet (``full_width`` x
  ``full_height``). A tile is a 1:1 crop, so tile-local pixels map to sheet pixels by a
  pure offset (``pixel.x``, ``pixel.y``); there is no per-tile resampling.
* **Sheet-normalized [0,1]** — the CIR convention: ``sheet_norm = pixel / full_size``.
* **Tile-local-normalized [0,1]** — coordinates within a single tile, which is what L1
  returns per tile. The affine map back to the sheet is
  ``sheet_norm = region.min + tile_norm * region.size`` (see :meth:`TileRef.tile_box_to_sheet`).

What L1 receives per tile: a tile image + its :class:`TileRef`. What L1 must return:
:class:`TileDetection` objects in **tile-local-normalized** coordinates referencing the
``tile_id``. :func:`aggregate` composes them back to sheet-normalized
:class:`SheetDetection` objects and de-duplicates across tile seams with NMS.
"""

from __future__ import annotations

from pydantic import BaseModel, ConfigDict, Field

from cir import BBox, Point

# Tolerance treated as "fully inside" when assigning a detection to a tile.
_EPS = 1e-6


class PixelRegion(BaseModel):
    """An axis-aligned rectangle in full-raster pixel coordinates (offset + size)."""

    model_config = ConfigDict(extra="forbid")

    x: int  # left offset in the full raster
    y: int  # top offset in the full raster
    width: int
    height: int

    @property
    def x_max(self) -> int:
        return self.x + self.width

    @property
    def y_max(self) -> int:
        return self.y + self.height


class TileRef(BaseModel):
    """The handoff metadata for one tile — the documented L0->L1 contract.

    Records the tile's placement in **both** pixel and normalized-sheet coordinates,
    its scale factor, its overlap, a stable id, and a back-reference to its sheet.
    """

    model_config = ConfigDict(extra="forbid")

    tile_id: str  # stable, deterministic by position: f"{sheet_id}:r{row}c{col}"
    sheet_id: str  # back-reference to the CIR Sheet this tile belongs to
    row: int
    col: int
    full_width: int  # rasterized sheet size, pixels
    full_height: int
    pixel: PixelRegion  # this tile in full-raster pixels (origin offset + size)
    region: BBox  # this tile in normalized [0,1] sheet coordinates
    core: BBox  # interior excluding overlap margins (unambiguous dedup ownership), norm
    core_pixel: PixelRegion  # the same core, in pixels
    overlap_px: int  # configured overlap margin between neighboring tiles
    dpi: int | None = None  # rasterization DPI (for px<->real via the sheet scale)

    # -- scale factor: tile-local-normalized [0,1] -> sheet-normalized extent --
    @property
    def scale_x(self) -> float:
        return self.region.width

    @property
    def scale_y(self) -> float:
        return self.region.height

    # -- coordinate composition (the contract) -----------------------------------
    def tile_norm_to_sheet(self, u: float, v: float) -> Point:
        """Tile-local-normalized (u, v) -> sheet-normalized point."""
        return Point(
            x=self.region.x_min + u * self.region.width,
            y=self.region.y_min + v * self.region.height,
        )

    def sheet_to_tile_norm(self, x: float, y: float) -> Point:
        """Sheet-normalized (x, y) -> tile-local-normalized point."""
        return Point(
            x=(x - self.region.x_min) / self.region.width,
            y=(y - self.region.y_min) / self.region.height,
        )

    def tile_box_to_sheet(self, box: BBox) -> BBox:
        """Tile-local-normalized box -> sheet-normalized box."""
        lo = self.tile_norm_to_sheet(box.x_min, box.y_min)
        hi = self.tile_norm_to_sheet(box.x_max, box.y_max)
        return BBox(x_min=lo.x, y_min=lo.y, x_max=hi.x, y_max=hi.y)

    def sheet_box_to_tile(self, box: BBox) -> BBox:
        """Sheet-normalized box -> tile-local-normalized box."""
        lo = self.sheet_to_tile_norm(box.x_min, box.y_min)
        hi = self.sheet_to_tile_norm(box.x_max, box.y_max)
        return BBox(x_min=lo.x, y_min=lo.y, x_max=hi.x, y_max=hi.y)

    def tile_px_to_sheet_px(self, px: float, py: float) -> tuple[float, float]:
        """Tile-local pixel -> full-raster pixel (a pure offset; 1:1 crop)."""
        return (self.pixel.x + px, self.pixel.y + py)

    def fully_contains(self, sheet_box: BBox) -> bool:
        """Whether a sheet-normalized box lies entirely within this tile's region."""
        return (
            sheet_box.x_min >= self.region.x_min - _EPS
            and sheet_box.y_min >= self.region.y_min - _EPS
            and sheet_box.x_max <= self.region.x_max + _EPS
            and sheet_box.y_max <= self.region.y_max + _EPS
        )

    def owns(self, x: float, y: float) -> bool:
        """Whether a sheet-normalized point falls in this tile's (non-overlap) core.

        The cores of all tiles partition the sheet, so a detection's center lands in
        exactly one tile's core — an alternative to NMS for unambiguous dedup.
        """
        return self.core.contains_point(Point(x=x, y=y))


class TileDetection(BaseModel):
    """What L1 returns per tile: a detection in **tile-local-normalized** coordinates."""

    model_config = ConfigDict(extra="forbid")

    tile_id: str
    label: str
    bbox: BBox  # tile-local normalized [0,1]
    score: float = Field(default=1.0, ge=0.0, le=1.0)


class SheetDetection(BaseModel):
    """A detection composed back onto the sheet, in sheet-normalized coordinates."""

    model_config = ConfigDict(extra="forbid")

    label: str
    bbox: BBox  # sheet-normalized [0,1]
    score: float = Field(default=1.0, ge=0.0, le=1.0)
    source_tile_ids: list[str] = Field(default_factory=list)


def compose_to_sheet(detection: TileDetection, ref: TileRef) -> SheetDetection:
    """Map one tile-local detection back onto the sheet via its :class:`TileRef`."""
    return SheetDetection(
        label=detection.label,
        bbox=ref.tile_box_to_sheet(detection.bbox),
        score=detection.score,
        source_tile_ids=[detection.tile_id],
    )


def aggregate(
    detections: list[TileDetection],
    refs: dict[str, TileRef],
    *,
    iou_threshold: float = 0.5,
) -> list[SheetDetection]:
    """Compose tile-local detections back to the sheet and dedup across tile seams.

    Per label, sheet-space detections that overlap above ``iou_threshold`` are merged
    (highest score wins; merged tile ids are recorded). This is what turns a symbol
    seen in two overlapping tiles into a single counted detection.
    """
    composed = [compose_to_sheet(d, refs[d.tile_id]) for d in detections]
    kept: list[SheetDetection] = []
    for label in {d.label for d in composed}:
        group = sorted(
            (d for d in composed if d.label == label), key=lambda d: d.score, reverse=True
        )
        label_kept: list[SheetDetection] = []
        for det in group:
            duplicate = next((k for k in label_kept if k.bbox.iou(det.bbox) >= iou_threshold), None)
            if duplicate is None:
                label_kept.append(det)
            else:
                for tid in det.source_tile_ids:
                    if tid not in duplicate.source_tile_ids:
                        duplicate.source_tile_ids.append(tid)
        kept.extend(label_kept)
    return kept
