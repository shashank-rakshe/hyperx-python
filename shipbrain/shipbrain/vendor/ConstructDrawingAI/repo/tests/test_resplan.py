"""Tests for the ResPlan → CIR converter (datasets.preparers.resplan_cir). Needs shapely."""

from __future__ import annotations

import pytest

pytest.importorskip("shapely", reason="shapely not installed")

from shapely.geometry import MultiPolygon, Polygon

from engines.takeoff import compute_takeoff
from grounding.ontology import ground_drawing_set


def _plan():
    sq = Polygon([(0, 0), (10, 0), (10, 10), (0, 10)])  # 100 unit² bedroom
    door = Polygon([(2, 0), (3, 0), (3, 1), (2, 1)])
    wall = Polygon([(0, 0), (10, 0), (10, 1), (0, 1)])
    empty = MultiPolygon()
    return {
        "id": 1,
        "net_area": 100.0,
        "area": 120.0,
        "bedroom": MultiPolygon([sq]),
        "bathroom": empty,
        "kitchen": Polygon(),
        "living": Polygon(),
        "balcony": empty,
        "garden": empty,
        "parking": empty,
        "pool": empty,
        "door": MultiPolygon([door]),
        "window": empty,
        "front_door": Polygon(),
        "wall": MultiPolygon([wall]),
    }


def test_plan_to_cir_real_area_and_counts():
    from datasets.preparers.resplan_cir import plan_to_cir

    ds = plan_to_cir(_plan())
    ground_drawing_set(ds)
    t = compute_takeoff(ds)
    # net_area 100 m² calibrates the bedroom (100 unit²) to 100 m²
    bed = next(q for q in t.area if q.category == "Bedroom")
    assert abs(bed.quantity - 100.0) < 1.0 and bed.unit == "m²"
    # door counted as a component + MasterFormat-grounded
    door = next(ln for ln in t.lines if ln.label == "Door")
    assert door.count == 1 and door.masterformat == "08 10 00"
    # wall shows up as linear, not a component
    assert any(q.category == "Wall" for q in t.linear)
