"""CIR graph model (ADR-0012): Connection.directed + geometry, and directed-aware edge AP."""

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
    ViewType,
    from_msgpack,
    to_msgpack,
)
from eval.metrics import graph_edge_ap

_PROV = {"license_provenance": LicenseProvenance.UNKNOWN, "data_lane": DataLane.RESEARCH}


def test_connection_new_fields_default_and_roundtrip() -> None:
    edge = Connection(source_id="a", target_id="b")
    assert edge.directed is True and edge.geometry is None  # backward-compatible defaults

    undirected = Connection(
        source_id="a",
        target_id="b",
        connection_type="wire",
        directed=False,
        geometry=Geometry.polyline([(0.1, 0.1), (0.4, 0.4)]),
    )
    view = View(view_type=ViewType.PLAN, connections=[undirected])
    ds = DrawingSet(sheets=[Sheet(sheet_number="P-1", views=[view])], **_PROV)
    restored = from_msgpack(DrawingSet, to_msgpack(ds))
    back = restored.sheets[0].views[0].connections[0]
    assert back.directed is False
    assert back.geometry is not None and len(back.geometry.points) == 2


def _graph(src: str, tgt: str, *, directed: bool) -> DrawingSet:
    a = Entity(
        id="a",
        entity_type=EntityType.SYMBOL,
        label="valve",
        geometry=Geometry.box(0.10, 0.10, 0.20, 0.20),
        confidence=1.0,
        **_PROV,
    )
    b = Entity(
        id="b",
        entity_type=EntityType.SYMBOL,
        label="pump",
        geometry=Geometry.box(0.50, 0.50, 0.60, 0.60),
        confidence=1.0,
        **_PROV,
    )
    conn = Connection(source_id=src, target_id=tgt, directed=directed, confidence=1.0)
    view = View(view_type=ViewType.PLAN, entities=[a, b], connections=[conn])
    return DrawingSet(sheets=[Sheet(sheet_number="P-1", views=[view])], **_PROV)


def test_undirected_edge_matches_either_orientation() -> None:
    gt = _graph("a", "b", directed=False)
    pred_reversed = _graph("b", "a", directed=False)  # opposite orientation
    assert graph_edge_ap([pred_reversed], [gt]) == 1.0


def test_directed_edge_requires_matching_orientation() -> None:
    gt = _graph("a", "b", directed=True)
    assert graph_edge_ap([_graph("a", "b", directed=True)], [gt]) == 1.0  # same orientation
    assert graph_edge_ap([_graph("b", "a", directed=True)], [gt]) == 0.0  # reversed -> miss
