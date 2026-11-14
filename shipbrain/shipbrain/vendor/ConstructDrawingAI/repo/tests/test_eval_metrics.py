"""Tests for the eval metrics and multi-seed aggregation."""

from __future__ import annotations

import pytest

from cir import (
    Connection,
    DataLane,
    DimensionString,
    DrawingSet,
    Entity,
    EntityType,
    Geometry,
    LicenseProvenance,
    Sheet,
    TextSpan,
    View,
)
from eval import metrics
from eval.aggregate import aggregate

PROV = {
    "license_provenance": LicenseProvenance.SYNTHETIC_OWNED,
    "data_lane": DataLane.COMMERCIAL,
}


def _sym(
    eid: str, label: str, cx: float, cy: float, *, conf: float = 1.0, half: float = 0.02
) -> Entity:
    return Entity(
        id=eid,
        entity_type=EntityType.SYMBOL,
        label=label,
        geometry=Geometry.box(cx - half, cy - half, cx + half, cy + half),
        confidence=conf,
        **PROV,
    )


def _ds(entities: list[Entity], connections: list[Connection] | None = None) -> DrawingSet:
    view = View(entities=entities, connections=connections or [])
    return DrawingSet(sheets=[Sheet(sheet_number="X-1", views=[view])], **PROV)


def test_detection_map_perfect() -> None:
    gt = _ds([_sym("a", "R", 0.2, 0.2), _sym("b", "R", 0.5, 0.5)])
    assert metrics.detection_map([gt], [gt]) == 1.0


def test_detection_map_with_miss_is_between() -> None:
    gt = _ds([_sym("a", "R", 0.2, 0.2), _sym("b", "R", 0.5, 0.5)])
    pred = _ds([_sym("a", "R", 0.2, 0.2, conf=0.9)])  # one of two detected
    assert 0.0 < metrics.detection_map([pred], [gt]) < 1.0


def test_counting_mape_and_exact_match() -> None:
    gt = _ds([_sym("a", "R", 0.2, 0.2), _sym("b", "R", 0.5, 0.5), _sym("c", "R", 0.7, 0.7)])
    pred = _ds([_sym("a", "R", 0.2, 0.2)])  # undercounts 3 -> 1
    assert metrics.counting_mape([pred], [gt]) == pytest.approx(100.0 * 2 / 3)
    assert metrics.counting_exact_match([pred], [gt]) == 0.0
    assert metrics.counting_exact_match([gt], [gt]) == 1.0


def test_external_wall_iou_self_is_one() -> None:
    poly = Geometry.polygon([(0.1, 0.1), (0.5, 0.1), (0.5, 0.5), (0.1, 0.5)])
    wall = Entity(
        id="w", entity_type=EntityType.WALL, label="wall", geometry=poly, confidence=1.0, **PROV
    )
    gt = _ds([wall])
    assert metrics.external_wall_iou([gt], [gt]) == pytest.approx(1.0)


def test_chamfer_self_is_zero() -> None:
    line = Entity(
        id="p",
        entity_type=EntityType.POLYLINE,
        label="line",
        geometry=Geometry.polyline([(0.1, 0.1), (0.2, 0.2), (0.3, 0.1)]),
        confidence=1.0,
        **PROV,
    )
    gt = _ds([line])
    assert metrics.chamfer_distance([gt], [gt]) == 0.0


def test_loop_closure_validity() -> None:
    good = Entity(
        id="g",
        entity_type=EntityType.POLYGON,
        label="room",
        geometry=Geometry.polygon([(0.0, 0.0), (0.3, 0.0), (0.3, 0.3)]),
        confidence=1.0,
        **PROV,
    )
    degenerate = Entity(
        id="d",
        entity_type=EntityType.POLYGON,
        label="room",
        geometry=Geometry.polygon([(0.0, 0.0), (0.3, 0.0), (0.6, 0.0)]),  # collinear -> area 0
        confidence=1.0,
        **PROV,
    )
    ds = _ds([good, degenerate])
    assert metrics.loop_closure_validity([ds], [ds]) == 0.5


def test_ocr_and_dimension_self() -> None:
    entity = Entity(
        id="t",
        entity_type=EntityType.TEXT,
        label="label",
        text_spans=[TextSpan(text="Panel A")],
        dimensions=[DimensionString(raw="10ft", value_mm=3048.0)],
        confidence=1.0,
        **PROV,
    )
    gt = _ds([entity])
    assert metrics.ocr_exact_match([gt], [gt]) == 1.0
    assert metrics.dimension_accuracy([gt], [gt]) == 1.0


def test_graph_edge_ap_self() -> None:
    a, b = _sym("a", "R", 0.2, 0.2), _sym("b", "Panel", 0.8, 0.8)
    conn = Connection(source_id="a", target_id="b", confidence=1.0)
    gt = _ds([a, b], [conn])
    assert metrics.graph_edge_ap([gt], [gt]) == 1.0


def test_qa_accuracy() -> None:
    gt = DrawingSet(
        metadata={"qa_pairs": [{"q_id": "1", "answer": "2"}, {"q_id": "2", "answer": "5"}]}, **PROV
    )
    pred = DrawingSet(
        metadata={"qa_pairs": [{"q_id": "1", "answer": "2"}, {"q_id": "2", "answer": "4"}]}, **PROV
    )
    assert metrics.qa_accuracy([pred], [gt]) == 0.5


def test_rfi_reward_rubric() -> None:
    full = DrawingSet(
        metadata={"rfi": {"conflict": "c", "evidence": "e", "cited_clause": "x", "question": "q"}},
        **PROV,
    )
    partial = DrawingSet(metadata={"rfi": {"conflict": "c", "question": "q"}}, **PROV)
    none = DrawingSet(metadata={}, **PROV)
    assert metrics.rfi_reward([full], [full]) == 1.0
    assert metrics.rfi_reward([partial], [partial]) == 0.5
    assert metrics.rfi_reward([none], [none]) == 0.0


def test_metric_registry_directions() -> None:
    assert set(metrics.METRICS) >= {
        "detection_map",
        "counting_mape",
        "external_wall_iou",
        "graph_edge_ap",
    }
    assert metrics.HIGHER_IS_BETTER["counting_mape"] is False
    assert metrics.HIGHER_IS_BETTER["detection_map"] is True


def test_aggregate_multiseed_ci() -> None:
    agg = aggregate([0.8, 0.9, 1.0])
    assert agg.n == 3
    assert agg.mean == pytest.approx(0.9)
    assert agg.ci95 > 0.0


def test_aggregate_single_seed_no_ci() -> None:
    agg = aggregate([0.5])
    assert agg.n == 1
    assert agg.ci95 == 0.0
    assert agg.mean == 0.5
