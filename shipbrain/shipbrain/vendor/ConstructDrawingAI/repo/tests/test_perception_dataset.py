"""The synthetic->YOLO export writes correct, correctly-placed labels.

A label-geometry bug here silently teaches the detector the wrong thing, so these tests
pin: (1) the right entities become targets (symbols yes, walls no); (2) a YOLO box maps
back through the audited handoff math to the original CIR box; (3) every target is
captured by at least one tile when the sheet is tiled; (4) the ultralytics layout +
persisted split are well-formed and leak-free.
"""

from __future__ import annotations

from cir import BBox
from ingest import tile_image
from perception.dataset import (
    _yolo_lines_for_tile,
    detection_targets,
    export_yolo_dataset,
    plan_sheet,
)
from perception.labels import CLASS_NAMES


def _parse(line: str) -> tuple[int, BBox]:
    cls, cx, cy, w, h = line.split()
    cx, cy, w, h = (float(v) for v in (cx, cy, w, h))
    return int(cls), BBox(x_min=cx - w / 2, y_min=cy - h / 2, x_max=cx + w / 2, y_max=cy + h / 2)


def test_only_symbols_are_detection_targets(make_electrical_sample, tmp_path) -> None:
    ds = make_electrical_sample(tmp_path / "sample_00000", n_duplex=3, panel=True, wall=True)
    targets = detection_targets(plan_sheet(ds))
    labels = sorted(label for label, _ in targets)
    assert labels == ["Duplex Receptacle", "Duplex Receptacle", "Duplex Receptacle", "Panelboard"]
    assert "Wall" not in labels  # the wall polygon is structure, never a detection label


def test_yolo_box_maps_back_to_the_cir_box(make_electrical_sample, tmp_path) -> None:
    sd = tmp_path / "sample_00000"
    ds = make_electrical_sample(sd, n_duplex=3, panel=True, wall=True)
    targets = detection_targets(plan_sheet(ds))

    # Single tile covering the whole sheet: tile-local coords == sheet coords.
    tiled = tile_image(sd / "plan.png", sheet_id="s", tile_size=4096, overlap=0)
    assert len(tiled.tiles) == 1
    ref = tiled.tiles[0].ref
    lines = _yolo_lines_for_tile(targets, ref, min_box_area=1e-9)
    assert len(lines) == len(targets)  # one label per target, nothing dropped or added

    recovered = []
    for line in lines:
        cls, tile_box = _parse(line)
        recovered.append((CLASS_NAMES[cls], ref.tile_box_to_sheet(tile_box)))
    for label, box in targets:
        assert any(
            name == label
            and abs(sheet_box.center.x - box.center.x) < 1e-6
            and abs(sheet_box.center.y - box.center.y) < 1e-6
            for name, sheet_box in recovered
        ), f"target {label} not recovered from its YOLO label"


def test_every_target_is_captured_when_tiled(make_electrical_sample, tmp_path) -> None:
    sd = tmp_path / "sample_00000"
    ds = make_electrical_sample(sd, n_duplex=4, panel=True, img_size=(900, 600))
    targets = detection_targets(plan_sheet(ds))

    tiled = tile_image(sd / "plan.png", sheet_id="s", tile_size=256, overlap=64)
    assert len(tiled.tiles) > 1  # genuinely multi-tile

    seen: list[tuple[str, float, float]] = []
    for tile in tiled.tiles:
        for line in _yolo_lines_for_tile(targets, tile.ref, min_box_area=1e-9):
            cls, tile_box = _parse(line)
            sheet_box = tile.ref.tile_box_to_sheet(tile_box)
            seen.append((CLASS_NAMES[cls], sheet_box.center.x, sheet_box.center.y))

    for label, box in targets:
        assert any(
            name == label and abs(sx - box.center.x) < 1e-3 and abs(sy - box.center.y) < 1e-3
            for name, sx, sy in seen
        ), f"target {label} fell through the tiling"


def test_export_layout_is_wellformed_and_split_is_leakfree(
    make_electrical_sample, tmp_path
) -> None:
    root = tmp_path / "syn"
    names = {f"sample_{i:05d}" for i in range(6)}
    for name in names:
        make_electrical_sample(root / name)

    export_root = tmp_path / "yolo"
    result = export_yolo_dataset(
        synthetic_root=root, export_root=export_root, val_fraction=0.5, tile_size=4096, seed=0
    )

    assert (export_root / "dataset.yaml").is_file()
    assert (export_root / "split.json").is_file()
    yaml_text = (export_root / "dataset.yaml").read_text()
    assert "Duplex Receptacle" in yaml_text and "Panelboard" in yaml_text

    # one tile per sheet here, so #images == #samples per fold
    assert len(list((export_root / "images/train").glob("*.png"))) == result.n_train_images
    assert len(list((export_root / "labels/train").glob("*.txt"))) == result.n_train_images
    # the split partitions the samples with no leakage
    assert set(result.train_samples).isdisjoint(result.val_samples)
    assert set(result.train_samples) | set(result.val_samples) == names
