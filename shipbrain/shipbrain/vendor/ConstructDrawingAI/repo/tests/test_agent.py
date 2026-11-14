"""Tests for L4 Q&A (agent.qa) + RFI drafting (agent.rfi)."""

from __future__ import annotations

from agent.qa import answer
from agent.rfi import generate_rfis
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
    ViewType,
)


def _e(label, conf, eid, etype=EntityType.SYMBOL):
    return Entity(
        id=eid,
        entity_type=etype,
        label=label,
        geometry=Geometry.box(0.1, 0.1, 0.2, 0.2),
        license_provenance=LicenseProvenance.SYNTHETIC_OWNED,
        data_lane=DataLane.COMMERCIAL,
        confidence=conf,
    )


def _ds():
    e_sheet = Sheet(
        sheet_number="E-101",
        discipline="electrical",
        views=[
            View(
                view_type=ViewType.PLAN,
                entities=[
                    _e("Duplex Receptacle", 0.9, "r1"),
                    _e("Duplex Receptacle", 0.3, "r2"),  # low-confidence
                    _e("Light Fixture", 0.9, "l1"),
                    _e("Panelboard", 0.95, "panel"),  # no connections -> discrepancy
                ],
                connections=[
                    Connection(
                        source_id="r1", target_id="l1", connection_type="conductor", confidence=0.8
                    )
                ],
            )
        ],
    )
    a_sheet = Sheet(
        sheet_number="A-101",
        discipline="architectural",
        views=[View(view_type=ViewType.PLAN, entities=[_e("door", 0.9, "d1")])],
    )
    return DrawingSet(
        name="proj",
        sheets=[e_sheet, a_sheet],
        license_provenance=LicenseProvenance.SYNTHETIC_OWNED,
        data_lane=DataLane.COMMERCIAL,
    )


def test_qa_count_substring_and_plural():
    a = answer(_ds(), "how many receptacles?")
    assert a.value == 2 and len(a.evidence) == 2


def test_qa_count_scoped_to_sheet():
    ds = _ds()
    assert answer(ds, "how many doors on A-101").value == 1
    assert answer(ds, "how many receptacles on A-101").value == 0


def test_qa_disciplines_and_sheets():
    ds = _ds()
    assert answer(ds, "what disciplines are in this set").value == ["architectural", "electrical"]
    assert answer(ds, "how many sheets").value == 2


def test_qa_list_panels():
    a = answer(_ds(), "list the panels")
    assert a.value == [("Panelboard", 1)]


def test_qa_unresolved_is_graceful():
    a = answer(_ds(), "what is the meaning of life")
    assert a.value is None and "counts" in a.text


def test_rfi_low_confidence_and_panel_discrepancy():
    rfis = generate_rfis(_ds())
    sev = {r.severity for r in rfis}
    assert "review" in sev and "discrepancy" in sev
    review = next(r for r in rfis if r.severity == "review")
    assert "Duplex Receptacle" in review.subject and "r2" in review.evidence
    disc = next(r for r in rfis if r.severity == "discrepancy")
    assert disc.evidence == ["panel"] and disc.discipline == "electrical"


def test_rfi_none_when_clean():
    clean = DrawingSet(
        name="clean",
        sheets=[
            Sheet(
                sheet_number="E-1",
                discipline="electrical",
                views=[View(view_type=ViewType.PLAN, entities=[_e("Light Fixture", 0.99, "x")])],
            )
        ],
        license_provenance=LicenseProvenance.SYNTHETIC_OWNED,
        data_lane=DataLane.COMMERCIAL,
    )
    assert generate_rfis(clean) == []
