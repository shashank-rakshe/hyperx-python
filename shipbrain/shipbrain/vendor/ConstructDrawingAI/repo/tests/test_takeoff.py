"""Tests for the L3 takeoff engine (engines.takeoff)."""

from __future__ import annotations

import json

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
from engines.takeoff import compute_takeoff


def _entity(label, conf, etype=EntityType.SYMBOL, eid="e"):
    return Entity(
        id=eid,
        entity_type=etype,
        label=label,
        geometry=Geometry.box(0.1, 0.1, 0.2, 0.2),
        license_provenance=LicenseProvenance.SYNTHETIC_OWNED,
        data_lane=DataLane.COMMERCIAL,
        confidence=conf,
    )


def _ds(entities, connections=None, discipline="electrical"):
    view = View(view_type=ViewType.PLAN, entities=entities, connections=connections or [])
    return DrawingSet(
        name="demo",
        sheets=[Sheet(sheet_number="E-101", discipline=discipline, views=[view])],
        license_provenance=LicenseProvenance.SYNTHETIC_OWNED,
        data_lane=DataLane.COMMERCIAL,
    )


def test_counts_group_by_label():
    ds = _ds(
        [_entity("Duplex Receptacle", 0.9, eid=f"r{i}") for i in range(3)]
        + [_entity("Panelboard", 0.95, eid="p0")]
    )
    t = compute_takeoff(ds)
    counts = {ln.label: ln.count for ln in t.lines}
    assert counts == {"Duplex Receptacle": 3, "Panelboard": 1}
    assert t.total_count == 4
    assert all(ln.discipline == "electrical" for ln in t.lines)


def test_low_confidence_flagged_and_min_confidence_drops():
    ds = _ds(
        [
            _entity("Light Fixture", 0.9, eid="a"),
            _entity("Light Fixture", 0.3, eid="b"),  # kept but flagged for review
            _entity("Light Fixture", 0.05, eid="c"),  # dropped by min_confidence
        ]
    )
    t = compute_takeoff(ds, min_confidence=0.1, review_threshold=0.5)
    line = next(ln for ln in t.lines if ln.label == "Light Fixture")
    assert line.count == 2  # the 0.05 instance dropped
    assert line.needs_review == 1  # the 0.3 instance flagged
    assert t.total_needs_review == 1


def test_non_countable_excluded():
    ds = _ds(
        [
            _entity("Duplex Receptacle", 0.9, eid="s"),
            _entity("A-1", 0.9, etype=EntityType.TEXT, eid="t"),
            _entity("junction", 0.9, etype=EntityType.GRAPH_NODE, eid="g"),
        ]
    )
    t = compute_takeoff(ds)
    assert [ln.label for ln in t.lines] == ["Duplex Receptacle"]


def test_connections_summarized():
    ents = [_entity("Duplex Receptacle", 0.9, eid="a"), _entity("Panelboard", 0.9, eid="b")]
    conns = [Connection(source_id="a", target_id="b", connection_type="home_run", confidence=0.8)]
    t = compute_takeoff(_ds(ents, conns))
    assert t.connections == {"home_run": 1}


def test_evidence_links_back_to_source():
    t = compute_takeoff(_ds([_entity("Panelboard", 0.9, eid="p0")]))
    ev = t.lines[0].evidence[0]
    assert ev.sheet_number == "E-101" and ev.entity_id == "p0"
    assert ev.bbox is not None and abs(ev.bbox[0] - 0.1) < 1e-9


def test_exports_render():
    t = compute_takeoff(_ds([_entity("Duplex Receptacle", 0.9, eid="a")]))
    md = t.to_markdown()
    assert "Quantity takeoff" in md and "Duplex Receptacle" in md and "Total: 1" in md
    assert "discipline,item,masterformat" in t.to_csv()
    d = json.loads(json.dumps(t.to_dict()))
    assert d["total_count"] == 1 and d["lines"][0]["item"] == "Duplex Receptacle"


def _sym(label, eid, box):
    return Entity(
        id=eid,
        entity_type=EntityType.SYMBOL,
        label=label,
        geometry=Geometry.box(*box),
        license_provenance=LicenseProvenance.SYNTHETIC_OWNED,
        data_lane=DataLane.COMMERCIAL,
        confidence=1.0,
    )


def test_linear_from_connections_normalized_without_scale():
    import math

    a = _sym("Panelboard", "a", (0.0, 0.0, 0.1, 0.1))  # center (0.05, 0.05)
    b = _sym("Duplex Receptacle", "b", (0.4, 0.05, 0.5, 0.15))  # center (0.45, 0.10)
    conn = Connection(source_id="a", target_id="b", connection_type="home_run", confidence=0.9)
    t = compute_takeoff(_ds([a, b], [conn]))
    assert t.scale_known is False
    run = next(q for q in t.linear if q.category == "home_run")
    assert run.count == 1 and run.unit == "norm"
    assert abs(run.quantity - round(math.hypot(0.4, 0.05), 2)) < 0.02


def test_scale_converts_length_and_area_to_real_units():
    from cir import PageSize, Scale

    room = Entity(
        id="rm",
        entity_type=EntityType.ROOM,
        label="Bedroom",
        geometry=Geometry.box(0.0, 0.0, 0.5, 0.5),  # normalized area 0.25
        license_provenance=LicenseProvenance.SYNTHETIC_OWNED,
        data_lane=DataLane.COMMERCIAL,
        confidence=1.0,
    )
    sheet = Sheet(
        sheet_number="A-1",
        discipline="architectural",
        size=PageSize(width=100.0, height=100.0, unit="ft"),
        scale=Scale(ratio=1.0, real_world_unit="ft"),
        views=[View(view_type=ViewType.PLAN, entities=[room])],
    )
    ds = DrawingSet(
        name="scaled",
        sheets=[sheet],
        license_provenance=LicenseProvenance.SYNTHETIC_OWNED,
        data_lane=DataLane.COMMERCIAL,
    )
    t = compute_takeoff(ds)
    assert t.scale_known is True
    ar = next(q for q in t.area if q.category == "Bedroom")
    assert ar.unit == "ft²" and abs(ar.quantity - 2500.0) < 1.0  # 0.25 * 100 * 100


def test_room_area_uses_polygon_shoelace_not_bbox():
    from cir import PageSize, Scale

    # A triangle: normalized area 0.5, but its bbox area is 1.0 — the takeoff must use the polygon.
    tri = Entity(
        id="rm",
        entity_type=EntityType.ROOM,
        label="Bedroom",
        geometry=Geometry.polygon([(0.0, 0.0), (1.0, 0.0), (0.0, 1.0)]),
        license_provenance=LicenseProvenance.SYNTHETIC_OWNED,
        data_lane=DataLane.COMMERCIAL,
        confidence=1.0,
    )
    sheet = Sheet(
        sheet_number="A-1",
        discipline="architectural",
        size=PageSize(width=10.0, height=10.0, unit="m"),
        scale=Scale(ratio=1.0, real_world_unit="m"),
        views=[View(view_type=ViewType.PLAN, entities=[tri])],
    )
    ds = DrawingSet(
        name="t",
        sheets=[sheet],
        license_provenance=LicenseProvenance.SYNTHETIC_OWNED,
        data_lane=DataLane.COMMERCIAL,
    )
    t = compute_takeoff(ds)
    ar = next(q for q in t.area if q.category == "Bedroom")
    assert abs(ar.quantity - 50.0) < 0.5  # 0.5 (triangle) * 100, not 100 (bbox)
    assert all(ln.label != "Bedroom" for ln in t.lines)  # ROOM excluded from component count
