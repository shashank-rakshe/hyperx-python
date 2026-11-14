"""Tests for L2 grounding (grounding.ontology)."""

from __future__ import annotations

from cir import (
    DataLane,
    DrawingSet,
    Entity,
    EntityType,
    Geometry,
    LicenseProvenance,
    Sheet,
    View,
    ViewType,
)
from engines.takeoff import compute_takeoff
from grounding.ontology import ground_drawing_set, lookup


def _ds(labels):
    ents = [
        Entity(
            id=f"e{i}",
            entity_type=EntityType.SYMBOL,
            label=lab,
            geometry=Geometry.box(0.1, 0.1, 0.2, 0.2),
            license_provenance=LicenseProvenance.SYNTHETIC_OWNED,
            data_lane=DataLane.COMMERCIAL,
            confidence=1.0,
        )
        for i, lab in enumerate(labels)
    ]
    return DrawingSet(
        name="x",
        sheets=[
            Sheet(
                sheet_number="E-1",
                discipline="electrical",
                views=[View(view_type=ViewType.PLAN, entities=ents)],
            )
        ],
        license_provenance=LicenseProvenance.SYNTHETIC_OWNED,
        data_lane=DataLane.COMMERCIAL,
    )


def test_lookup_known_and_unknown():
    assert lookup("Panelboard").masterformat == "26 24 16"
    assert lookup("double_door").ifc == "IfcDoor"
    assert lookup("valve").ifc == "IfcValve"
    assert lookup("PANELBOARD").ifc == "IfcElectricDistributionBoard"  # case-insensitive
    assert lookup("nonsense") is None
    assert lookup(None) is None


def test_ground_fills_codes_and_counts():
    ds, grounded, total = ground_drawing_set(_ds(["Panelboard", "Light Fixture", "nonsense-thing"]))
    assert (grounded, total) == (2, 3)
    ents = {e.label: e for s in ds.sheets for v in s.views for e in v.entities}
    assert ents["Panelboard"].ifc_class == "IfcElectricDistributionBoard"
    assert ents["Panelboard"].ontology.masterformat == "26 24 16"
    assert ents["Light Fixture"].ontology.uniformat == "D5020"
    assert ents["nonsense-thing"].ifc_class is None  # unknown left ungrounded


def test_takeoff_surfaces_codes_after_grounding():
    ds, _, _ = ground_drawing_set(_ds(["Duplex Receptacle", "Duplex Receptacle"]))
    t = compute_takeoff(ds)
    line = t.lines[0]
    assert line.masterformat == "26 27 26" and line.ifc_class == "IfcOutlet"
    assert "26 27 26" in t.to_markdown()
