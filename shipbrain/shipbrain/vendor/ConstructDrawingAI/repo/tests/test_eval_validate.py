"""Tests for the reusable ground-truth validator (``eval.validate``).

These exercise the validator independently of the synthetic engine: a hand-built CIR
document checked against hand-built expectations. The engine's own tests
(``test_synthetic_engine.py``) then rely on this validator being correct.
"""

from __future__ import annotations

from cir import (
    Connection,
    DataLane,
    DrawingSet,
    Entity,
    EntityType,
    Geometry,
    LicenseProvenance,
    Sheet,
    View,
)
from eval.validate import (
    ExpectedPlacement,
    GroundTruthExpectation,
    SheetExpectation,
    validate_ground_truth,
)

_PROV = {"license_provenance": LicenseProvenance.CC0, "data_lane": DataLane.RESEARCH}


def _symbol(eid: str, label: str, cx: float, cy: float) -> Entity:
    return Entity(
        id=eid,
        entity_type=EntityType.SYMBOL,
        label=label,
        geometry=Geometry.box(cx - 0.01, cy - 0.01, cx + 0.01, cy + 0.01),
        confidence=1.0,
        **_PROV,
    )


def _doc_with(entities: list[Entity], connections: list[Connection]) -> DrawingSet:
    view = View(entities=entities, connections=connections)
    sheet = Sheet(sheet_number="E-101", views=[view])
    return DrawingSet(id="d", sheets=[sheet], **_PROV)


def test_exact_match_passes() -> None:
    doc = _doc_with(
        [_symbol("a", "Widget", 0.2, 0.2), _symbol("b", "Widget", 0.4, 0.4)],
        [Connection(source_id="a", target_id="b", connection_type="wire")],
    )
    exp = GroundTruthExpectation(
        sample_id="d",
        sheets=[SheetExpectation("E-101", {"Widget": 2}, {"wire": 1})],
        placements=[
            ExpectedPlacement("E-101", "Widget", 0.2, 0.2),
            ExpectedPlacement("E-101", "Widget", 0.4, 0.4),
        ],
    )
    assert validate_ground_truth(exp, doc).ok


def test_wrong_count_is_caught() -> None:
    doc = _doc_with([_symbol("a", "Widget", 0.2, 0.2)], [])
    exp = GroundTruthExpectation("d", [SheetExpectation("E-101", {"Widget": 2})])
    report = validate_ground_truth(exp, doc)
    assert not report.ok
    assert any(i.code == "entity_count" for i in report.issues)


def test_unexpected_extra_entity_is_caught() -> None:
    # Two entities present, but only one expected -> the total check must fire.
    doc = _doc_with([_symbol("a", "Widget", 0.2, 0.2), _symbol("b", "Gadget", 0.5, 0.5)], [])
    exp = GroundTruthExpectation("d", [SheetExpectation("E-101", {"Widget": 1})])
    report = validate_ground_truth(exp, doc)
    assert not report.ok
    assert any(i.code == "entity_total" for i in report.issues)


def test_wrong_edge_count_is_caught() -> None:
    doc = _doc_with([_symbol("a", "Widget", 0.2, 0.2), _symbol("b", "Widget", 0.4, 0.4)], [])
    exp = GroundTruthExpectation("d", [SheetExpectation("E-101", {"Widget": 2}, {"wire": 1})])
    report = validate_ground_truth(exp, doc)
    assert not report.ok
    assert any(i.code in ("edge_count", "edge_total") for i in report.issues)


def test_misplacement_is_caught() -> None:
    doc = _doc_with([_symbol("a", "Widget", 0.2, 0.2)], [])
    exp = GroundTruthExpectation(
        "d",
        [SheetExpectation("E-101", {"Widget": 1})],
        placements=[ExpectedPlacement("E-101", "Widget", 0.9, 0.9)],
    )
    report = validate_ground_truth(exp, doc)
    assert not report.ok
    assert any(i.code == "placement" for i in report.issues)


def test_missing_sheet_is_caught() -> None:
    doc = _doc_with([_symbol("a", "Widget", 0.2, 0.2)], [])
    exp = GroundTruthExpectation("d", [SheetExpectation("E-999", {"Widget": 1})])
    report = validate_ground_truth(exp, doc)
    assert not report.ok
    assert any(i.code == "missing_sheet" for i in report.issues)
