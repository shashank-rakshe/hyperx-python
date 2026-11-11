"""The two-scoreboard discipline: synthetic is a smoke test, real is UNVALIDATED until data.

These tests pin the architectural requirement of Build Playbook 2.1 — a good synthetic
number is never reported as real success, and the real board fills in with no new plumbing
the moment annotated plans arrive.
"""

from __future__ import annotations

import json
import shutil
from pathlib import Path

from cir import (
    Connection,
    DataLane,
    Discipline,
    DrawingSet,
    Entity,
    EntityType,
    Geometry,
    LicenseProvenance,
    Sheet,
    View,
    ViewType,
)
from eval.adapters import PerfectAdapter
from eval.tasks import CLEAN
from perception.scoreboard import (
    build_real_drawing_task,
    filter_to_detection_targets,
    load_real_samples,
    run_detector_scoreboards,
)

_PROV = {"license_provenance": LicenseProvenance.SYNTHETIC_OWNED, "data_lane": DataLane.COMMERCIAL}


def _syn_root(tmp_path: Path, make_electrical_sample, n: int = 3) -> tuple[Path, Path]:
    """N synthetic samples + a split.json marking them all as held-out val."""
    root = tmp_path / "syn"
    names = []
    for i in range(n):
        name = f"sample_{i:05d}"
        names.append(name)
        make_electrical_sample(root / name)
    split = tmp_path / "split.json"
    split.write_text(json.dumps({"val": names, "train": []}))
    return root, split


def test_filter_keeps_only_detectable_symbols_and_drops_edges() -> None:
    duplex = Entity(
        entity_type=EntityType.SYMBOL,
        label="Duplex Receptacle",
        geometry=Geometry.box(0.2, 0.2, 0.24, 0.24),
        confidence=1.0,
        **_PROV,
    )
    panel = Entity(
        entity_type=EntityType.EQUIPMENT,
        label="Panelboard",
        geometry=Geometry.box(0.05, 0.05, 0.12, 0.12),
        confidence=1.0,
        **_PROV,
    )
    wall = Entity(
        entity_type=EntityType.WALL,
        label="Wall",
        geometry=Geometry.polygon([(0.1, 0.1), (0.9, 0.1), (0.9, 0.9)]),
        confidence=1.0,
        **_PROV,
    )
    conn = Connection(source_id=duplex.id, target_id=panel.id, connection_type="home_run")
    ds = DrawingSet(
        name="t",
        sheets=[
            Sheet(
                sheet_number="E-101",
                discipline=Discipline.ELECTRICAL,
                views=[
                    View(
                        view_type=ViewType.PLAN, entities=[duplex, panel, wall], connections=[conn]
                    )
                ],
            )
        ],
        **_PROV,
    )
    reduced = filter_to_detection_targets(ds)
    assert sorted(e.label for e in reduced.iter_entities()) == ["Duplex Receptacle", "Panelboard"]
    # the detection task scores boxes, not edges — connections must not leak in
    assert all(len(v.connections) == 0 for s in reduced.sheets for v in s.views)


def test_synthetic_board_is_framed_and_real_is_unvalidated(
    tmp_path, make_electrical_sample
) -> None:
    root, split = _syn_root(tmp_path, make_electrical_sample, n=3)
    report = run_detector_scoreboards(
        PerfectAdapter(), synthetic_root=root, split_json=split, real_root=None, conditions=(CLEAN,)
    )
    assert report.real_validated is False
    assert "SMOKE TEST" in report.text
    assert "UNVALIDATED" in report.text
    # the oracle scores a perfect detection_map on the synthetic board
    oracle_map = [
        r for r in report.synthetic_records if r.model == "oracle" and r.metric == "detection_map"
    ]
    assert oracle_map and all(abs(r.value - 1.0) < 1e-9 for r in oracle_map)
    # even with no real data, the empty real board still shows the cited SOTA/frontier bars
    assert report.real_records


def test_real_data_dropin_flips_to_validated(tmp_path, make_electrical_sample) -> None:
    root, split = _syn_root(tmp_path, make_electrical_sample, n=3)
    real = tmp_path / "real"
    make_electrical_sample(real / "sample_00000")  # one "real" annotated plan dropped in

    report = run_detector_scoreboards(
        PerfectAdapter(), synthetic_root=root, split_json=split, real_root=real, conditions=(CLEAN,)
    )
    assert report.real_validated is True
    assert "THIS is the comparison" in report.text
    real_map = [
        r for r in report.real_records if r.model == "oracle" and r.metric == "detection_map"
    ]
    assert real_map and all(abs(r.value - 1.0) < 1e-9 for r in real_map)


def test_real_task_is_empty_without_data(tmp_path) -> None:
    assert build_real_drawing_task(None).samples == []
    assert build_real_drawing_task(tmp_path / "does-not-exist").samples == []


def test_real_loader_accepts_flat_cir_png_pairs(tmp_path, make_electrical_sample) -> None:
    built = tmp_path / "_build"
    make_electrical_sample(built)
    # flatten to <stem>.cir + <stem>.png at the real root
    shutil.copy(built / "ground_truth.cir", tmp_path / "plan1.cir")
    shutil.copy(built / "plan.png", tmp_path / "plan1.png")
    shutil.rmtree(built)

    pairs = load_real_samples(tmp_path)
    assert len(pairs) == 1
    image_path, ds = pairs[0]
    assert image_path.name == "plan1.png"
    assert isinstance(ds, DrawingSet)
