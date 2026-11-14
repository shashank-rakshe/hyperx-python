"""Tests for the generic YOLO→CIR converter (datasets.preparers.yolo_generic)."""

from __future__ import annotations

import cir
from cir import DrawingSet
from datasets.preparers.yolo_generic import yolo_dir_to_cir


def _make_yolo(root) -> None:
    from PIL import Image

    (root / "train" / "images").mkdir(parents=True)
    (root / "train" / "labels").mkdir(parents=True)
    (root / "data.yaml").write_text("names:\n  0: duplex\n  1: switch\n")
    Image.new("RGB", (100, 100), "white").save(root / "train" / "images" / "s1.png")
    (root / "train" / "labels" / "s1.txt").write_text("0 0.5 0.5 0.2 0.1\n1 0.25 0.75 0.1 0.1\n")


def test_yolo_dir_to_cir_converts_boxes(tmp_path) -> None:
    src = tmp_path / "ds"
    _make_yolo(src)
    out = tmp_path / "cir"
    n = yolo_dir_to_cir(src, slug="proj", out_dir=out)
    assert n == 1
    cirs = list(out.glob("*.cir"))
    assert len(cirs) == 1
    ds = cir.load(DrawingSet, str(cirs[0]))
    assert sorted(e.label for e in ds.iter_entities()) == ["duplex", "switch"]
    duplex = next(e for e in ds.iter_entities() if e.label == "duplex")
    box = duplex.geometry.bounds()
    assert abs(box.center.x - 0.5) < 1e-6 and abs(box.center.y - 0.5) < 1e-6
    assert ds.data_lane.value == "research"  # self-declared CC-BY -> research lane


def test_yolo_dir_to_cir_copies_images_for_eval_pairs(tmp_path) -> None:
    src = tmp_path / "ds"
    _make_yolo(src)
    out = tmp_path / "real"
    yolo_dir_to_cir(src, slug="proj", out_dir=out, copy_images=True)
    # flat (image + CIR) pair the real-drawing scoreboard loader consumes
    assert (out / "proj__s1.png").exists()
    assert (out / "proj__s1.cir").exists()
