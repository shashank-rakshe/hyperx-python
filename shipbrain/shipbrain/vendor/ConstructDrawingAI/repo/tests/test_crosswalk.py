"""Tests for the DELP→DEVICE_CATALOG label crosswalk (the real-electrical scoring bridge)."""

from __future__ import annotations

import cir
from cir import DataLane, DrawingSet, Entity, Geometry, LicenseProvenance, Sheet, View, ViewType
from perception.crosswalk import DELP_TO_DETECTOR, remap_labels
from perception.labels import LABEL_TO_INDEX
from perception.scoreboard import filter_to_detection_targets


def _delp_ds(labels: list[str]) -> DrawingSet:
    ents = [
        Entity(
            id=f"e{i}",
            label=lab,
            geometry=Geometry.box(0.1, 0.1, 0.2, 0.2),
            license_provenance=LicenseProvenance.UNKNOWN,
            data_lane=DataLane.RESEARCH,
            confidence=1.0,
        )
        for i, lab in enumerate(labels)
    ]
    return DrawingSet(
        name="delp-sample",
        sheets=[
            Sheet(
                sheet_number="1",
                discipline="electrical",
                views=[View(name="plan", view_type=ViewType.PLAN, entities=ents)],
            )
        ],
        license_provenance=LicenseProvenance.UNKNOWN,
        data_lane=DataLane.RESEARCH,
    )


def test_targets_are_all_real_detector_classes():
    # Every crosswalk target must be a class the detector actually predicts.
    assert set(DELP_TO_DETECTOR.values()) <= set(LABEL_TO_INDEX)


def test_remap_translates_and_drops_unmapped():
    ds = _delp_ds(["Double Socket", "Light Switch", "Radiator", "Gas Meter Box"])
    out = remap_labels(ds)
    labels = [e.label for s in out.sheets for v in s.views for e in v.entities]
    # mapped ones translate; unmapped (HVAC/meter) are dropped
    assert labels == ["Duplex Receptacle", "Single-Pole Switch"]


def test_remap_preserves_geometry_and_lane():
    ds = _delp_ds(["Consumer Unit"])
    out = remap_labels(ds)
    ent = next(e for s in out.sheets for v in s.views for e in v.entities)
    assert ent.label == "Panelboard"
    assert ent.geometry is not None and ent.geometry.bounds().x_min == 0.1  # geometry preserved
    assert out.data_lane == DataLane.RESEARCH  # research/eval lane is not laundered away


def test_remapped_gt_survives_the_detection_filter():
    # The reason the crosswalk exists: without it every DELP box is dropped by the
    # detection filter (foreign labels are not detectable); with it, GT is non-empty.
    ds = _delp_ds(["Double Socket", "Low Energy Downlighter", "Radiator"])
    dropped = filter_to_detection_targets(ds)  # no remap -> all foreign -> empty
    assert sum(len(v.entities) for s in dropped.sheets for v in s.views) == 0
    kept = filter_to_detection_targets(remap_labels(ds))  # remap first -> survives
    labels = sorted(e.label for s in kept.sheets for v in s.views for e in v.entities)
    assert labels == ["Duplex Receptacle", "Recessed Downlight"]


def test_remap_roundtrips_through_cir_serialization(tmp_path):
    ds = _delp_ds(["Double Socket", "Light Switch"])
    out = remap_labels(ds)
    path = tmp_path / "remapped.cir"
    cir.save(out, str(path))
    reloaded = cir.load(DrawingSet, str(path))
    labels = sorted(e.label for s in reloaded.sheets for v in s.views for e in v.entities)
    assert labels == ["Duplex Receptacle", "Single-Pole Switch"]
