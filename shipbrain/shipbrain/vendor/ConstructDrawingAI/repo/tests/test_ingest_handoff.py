"""Round-trip test for the L0->L1 tiling handoff contract — no model involved.

Places known synthetic detections at known global (sheet-normalized) coordinates,
tiles the sheet, maps each detection into the tile-local frame of every tile that
contains it, then maps it back through the documented contract and asserts it returns
to the original global coordinates. One detection straddles a tile seam (it lands in
the overlap and is therefore seen by two tiles), exercising the cross-tile NMS dedup
that keeps a single symbol from being counted twice.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from cir import BBox
from ingest.handoff import TileDetection, aggregate
from ingest.tiling import tile_image

FULL_W, FULL_H = 4000, 3000


def _sheet_box(x0: float, y0: float, x1: float, y1: float) -> BBox:
    """A sheet-normalized box from full-raster pixel coordinates."""
    return BBox(x_min=x0 / FULL_W, y_min=y0 / FULL_H, x_max=x1 / FULL_W, y_max=y1 / FULL_H)


def test_handoff_roundtrip_and_cross_tile_dedup(tmp_path: Path) -> None:
    from PIL import Image

    sheet = tmp_path / "E-201.png"
    Image.new("RGB", (FULL_W, FULL_H)).save(sheet)
    tiled = tile_image(sheet, sheet_id="E-201", tile_size=1536, overlap=256)

    # Known global detections (all the same class, "recept"):
    #   D1, D3 sit inside a single tile; D2 straddles the col0/col1 seam (in the overlap)
    #   so it is fully visible in two tiles.
    detections = {
        "D1": _sheet_box(200, 200, 360, 360),
        "D2": _sheet_box(1320, 100, 1480, 260),
        "D3": _sheet_box(3000, 2000, 3160, 2160),
    }

    # Simulate L1: each detection appears (fully) in every tile that contains it.
    tile_dets: list[TileDetection] = []
    appearances: dict[str, int] = {}
    for det_id, global_box in detections.items():
        for tile in tiled.tiles:
            ref = tile.ref
            if not ref.fully_contains(global_box):
                continue
            local = ref.sheet_box_to_tile(global_box)
            assert local.x_min >= -1e-9 and local.x_max <= 1.0 + 1e-9
            assert local.y_min >= -1e-9 and local.y_max <= 1.0 + 1e-9

            # round trip: tile-local -> sheet recovers the ORIGINAL global coordinates
            recovered = ref.tile_box_to_sheet(local)
            assert recovered.x_min == pytest.approx(global_box.x_min, abs=1e-9)
            assert recovered.y_min == pytest.approx(global_box.y_min, abs=1e-9)
            assert recovered.x_max == pytest.approx(global_box.x_max, abs=1e-9)
            assert recovered.y_max == pytest.approx(global_box.y_max, abs=1e-9)

            tile_dets.append(
                TileDetection(tile_id=ref.tile_id, label="recept", bbox=local, score=0.9)
            )
            appearances[det_id] = appearances.get(det_id, 0) + 1

    # D2 straddles the seam -> seen by two tiles; D1 and D3 by exactly one.
    assert appearances == {"D1": 1, "D2": 2, "D3": 1}
    assert len(tile_dets) == 4

    # Compose back to the sheet + dedup across tile seams.
    sheet_dets = aggregate(tile_dets, tiled.refs, iou_threshold=0.5)
    assert len(sheet_dets) == 3  # 4 tile-detections -> 3 unique symbols (no double count)
    assert all(d.label == "recept" for d in sheet_dets)

    # Exactly one survivor was merged from two tiles (the straddling D2).
    merged = [d for d in sheet_dets if len(d.source_tile_ids) == 2]
    assert len(merged) == 1

    # The recovered sheet coordinates match the originals (matched by center).
    recovered_centers = sorted((d.bbox.center.x, d.bbox.center.y) for d in sheet_dets)
    expected_centers = sorted((b.center.x, b.center.y) for b in detections.values())
    for (rx, ry), (ex, ey) in zip(recovered_centers, expected_centers, strict=True):
        assert rx == pytest.approx(ex, abs=1e-9)
        assert ry == pytest.approx(ey, abs=1e-9)


def test_tile_cores_partition_the_sheet(tmp_path: Path) -> None:
    """Tile cores (overlap excluded) tile the sheet, so each point has one owner."""
    from PIL import Image

    sheet = tmp_path / "S-100.png"
    Image.new("RGB", (FULL_W, FULL_H)).save(sheet)
    tiled = tile_image(sheet, sheet_id="S-100", tile_size=1536, overlap=256)

    for x, y in [(0.05, 0.05), (0.5, 0.5), (0.33, 0.02), (0.99, 0.99)]:
        owners = [t for t in tiled.tiles if t.ref.owns(x, y)]
        assert len(owners) == 1, f"point ({x},{y}) owned by {len(owners)} tiles"


def test_pixel_and_normalized_agree(tmp_path: Path) -> None:
    """A tile's pixel region and normalized region describe the same rectangle."""
    from PIL import Image

    sheet = tmp_path / "A-101.png"
    Image.new("RGB", (FULL_W, FULL_H)).save(sheet)
    tiled = tile_image(sheet, sheet_id="A-101", tile_size=1536, overlap=256)

    for tile in tiled.tiles:
        ref = tile.ref
        assert ref.region.x_min == pytest.approx(ref.pixel.x / FULL_W)
        assert ref.region.y_max == pytest.approx(ref.pixel.y_max / FULL_H)
        # tile-local pixel (0,0) maps to the tile's pixel origin on the full sheet
        assert ref.tile_px_to_sheet_px(0, 0) == (ref.pixel.x, ref.pixel.y)
