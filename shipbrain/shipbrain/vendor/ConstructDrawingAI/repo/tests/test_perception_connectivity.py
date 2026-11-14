"""Model 2 — connectivity: geometry helpers, orientation, the edge model, and the adapter.

The geometry/orientation tests are pure and fast; the model test overfits a tiny separable
set (so it is quick and deterministic-enough); the adapter test uses fakes so no GPU is
needed; the scoreboard test confirms the oracle scores a perfect graph and the real board
stays UNVALIDATED.
"""

from __future__ import annotations

import json

import numpy as np
from PIL import Image

import cir
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
from eval.tasks import CLEAN, RASTER, EvalSample, Slice
from perception.connectivity import (
    EDGE_TYPE_TO_IDX,
    EDGE_TYPES,
    ConnectivityAdapter,
    ConnectivityModel,
    GraphNode,
    _orient,
    candidate_pairs,
    pair_features,
)
from perception.scoreboard import filter_to_graph, run_connectivity_scoreboards

_PROV = {"license_provenance": LicenseProvenance.SYNTHETIC_OWNED, "data_lane": DataLane.COMMERCIAL}


def _nodes() -> list[GraphNode]:
    return [
        GraphNode("Panelboard", 0.10, 0.10, "panel"),
        GraphNode("Duplex Receptacle", 0.50, 0.50, "r0"),
        GraphNode("Duplex Receptacle", 0.60, 0.50, "r1"),
        GraphNode("Single-Pole Switch", 0.20, 0.80, "sw"),
        GraphNode("Recessed Downlight", 0.30, 0.30, "lt"),
    ]


def test_candidate_pairs_are_unordered_and_include_panel() -> None:
    nodes = _nodes()
    pairs = candidate_pairs(nodes, k_neighbors=2)
    assert all(i < j for i, j in pairs)  # unordered, canonical
    assert len(set(pairs)) == len(pairs)  # de-duplicated
    # the panel (index 0) is paired with every other node regardless of distance
    for other in range(1, len(nodes)):
        assert (0, other) in pairs


def test_pair_features_are_orientation_invariant() -> None:
    a, b = _nodes()[1], _nodes()[2]
    assert np.allclose(pair_features(a, b), pair_features(b, a))
    assert pair_features(a, b).shape[0] == 3 + 2 * 10  # FEATURE_DIM


def test_orient_follows_trade_convention() -> None:
    nodes = _nodes()
    # home_run: device -> panel, whichever index order is passed
    assert _orient(0, 1, nodes, "home_run") == (1, 0)
    assert _orient(1, 0, nodes, "home_run") == (1, 0)
    # switch_leg: switch -> the controlled luminaire
    assert _orient(3, 4, nodes, "switch_leg") == (3, 4)
    assert _orient(4, 3, nodes, "switch_leg") == (3, 4)
    # conductor: left-to-right by (x, y)
    assert _orient(2, 1, nodes, "conductor") == (1, 2)  # r0 (x=0.50) before r1 (x=0.60)


def test_model_overfits_a_separable_edge_set() -> None:
    import torch

    torch.manual_seed(0)  # determinism for the tiny overfit
    nodes = _nodes()
    # Hand-label: r0<->panel home_run, r0<->r1 conductor, sw<->lt switch_leg, rest none.
    truth = {
        frozenset(("panel", "r0")): "home_run",
        frozenset(("r0", "r1")): "conductor",
        frozenset(("sw", "lt")): "switch_leg",
    }
    pairs = candidate_pairs(nodes, k_neighbors=4)
    x = np.stack([pair_features(nodes[i], nodes[j]) for i, j in pairs])
    y = np.array(
        [
            EDGE_TYPE_TO_IDX[truth.get(frozenset((nodes[i].entity_id, nodes[j].entity_id)), "none")]
            for i, j in pairs
        ]
    )
    model = ConnectivityModel(hidden=(32, 32), device="cpu")
    model.fit(x, y, epochs=300, lr=0.01, batch_size=64)

    # The trained model recovers the three edges with the correct types + orientation.
    edges = model.predict_edges(nodes, k_neighbors=4, threshold=0.5)
    typed = {(EDGE_TYPES[t], nodes[s].entity_id, nodes[d].entity_id) for (s, d, t, _) in edges}
    assert ("home_run", "r0", "panel") in typed
    assert ("switch_leg", "sw", "lt") in typed
    assert any(et == "conductor" and {a, b} == {"r0", "r1"} for et, a, b in typed)


def test_filter_to_graph_keeps_nodes_and_their_edges() -> None:
    panel = Entity(
        id="p",
        label="Panelboard",
        entity_type=EntityType.EQUIPMENT,
        geometry=Geometry.box(0.05, 0.05, 0.12, 0.12),
        confidence=1.0,
        **_PROV,
    )
    r0 = Entity(
        id="r0",
        label="Duplex Receptacle",
        entity_type=EntityType.SYMBOL,
        geometry=Geometry.box(0.30, 0.48, 0.34, 0.52),
        confidence=1.0,
        **_PROV,
    )
    wall = Entity(
        id="w",
        label="Wall",
        entity_type=EntityType.WALL,
        geometry=Geometry.polygon([(0.1, 0.1), (0.9, 0.1), (0.9, 0.9)]),
        confidence=1.0,
        **_PROV,
    )
    conn = Connection(source_id="r0", target_id="p", connection_type="home_run", confidence=1.0)
    ds = DrawingSet(
        name="t",
        sheets=[
            Sheet(
                sheet_number="E-101",
                discipline=Discipline.ELECTRICAL,
                views=[
                    View(view_type=ViewType.PLAN, entities=[panel, r0, wall], connections=[conn])
                ],
            )
        ],
        **_PROV,
    )
    reduced = filter_to_graph(ds)
    assert sorted(e.label for e in reduced.iter_entities()) == ["Duplex Receptacle", "Panelboard"]
    edges = [c for s in reduced.sheets for v in s.views for c in v.connections]
    assert len(edges) == 1 and edges[0].connection_type == "home_run"


class _FakeDetectorAdapter:
    """Returns a fixed DrawingSet of node entities (no detector/torch needed)."""

    name = "fake-detector"

    def predict(self, sample: EvalSample, *, seed: int = 0) -> DrawingSet:
        panel = Entity(
            id="n0",
            label="Panelboard",
            entity_type=EntityType.EQUIPMENT,
            geometry=Geometry.box(0.05, 0.05, 0.12, 0.12),
            confidence=0.9,
            license_provenance=LicenseProvenance.UNKNOWN,
            data_lane=DataLane.RESEARCH,
        )
        recept = Entity(
            id="n1",
            label="Duplex Receptacle",
            entity_type=EntityType.SYMBOL,
            geometry=Geometry.box(0.48, 0.48, 0.52, 0.52),
            confidence=0.9,
            license_provenance=LicenseProvenance.UNKNOWN,
            data_lane=DataLane.RESEARCH,
        )
        view = View(view_type=ViewType.PLAN, entities=[panel, recept])
        sheet = Sheet(sheet_number="E-101", discipline=Discipline.ELECTRICAL, views=[view])
        return DrawingSet(
            name="pred",
            sheets=[sheet],
            license_provenance=LicenseProvenance.UNKNOWN,
            data_lane=DataLane.RESEARCH,
        )


class _FakeConnectivity:
    def predict_edges(self, nodes, *, k_neighbors=8, threshold=0.5):
        # device (index 1) -> panel (index 0)
        return [(1, 0, EDGE_TYPE_TO_IDX["home_run"], 0.88)]


def test_connectivity_adapter_adds_oriented_connection() -> None:
    adapter = ConnectivityAdapter(_FakeDetectorAdapter(), _FakeConnectivity())
    sample = EvalSample(
        id="s",
        ground_truth=DrawingSet(name="gt", **_PROV),
        slice=Slice("mep", RASTER, CLEAN, "t"),
        image_path=None,
    )
    ds = adapter.predict(sample)
    connections = ds.sheets[0].views[0].connections
    assert len(connections) == 1
    edge = connections[0]
    assert edge.connection_type == "home_run"
    assert edge.source_id == "n1" and edge.target_id == "n0"  # device -> panel
    assert edge.confidence == 0.88


def _write_graph_sample(directory) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    panel = Entity(
        id="p",
        label="Panelboard",
        entity_type=EntityType.EQUIPMENT,
        geometry=Geometry.box(0.05, 0.05, 0.12, 0.12),
        confidence=1.0,
        **_PROV,
    )
    r0 = Entity(
        id="r0",
        label="Duplex Receptacle",
        entity_type=EntityType.SYMBOL,
        geometry=Geometry.box(0.30, 0.48, 0.34, 0.52),
        confidence=1.0,
        **_PROV,
    )
    r1 = Entity(
        id="r1",
        label="Duplex Receptacle",
        entity_type=EntityType.SYMBOL,
        geometry=Geometry.box(0.50, 0.48, 0.54, 0.52),
        confidence=1.0,
        **_PROV,
    )
    conns = [
        Connection(source_id="r0", target_id="p", connection_type="home_run", confidence=1.0),
        Connection(source_id="r0", target_id="r1", connection_type="conductor", confidence=1.0),
    ]
    view = View(view_type=ViewType.PLAN, entities=[panel, r0, r1], connections=conns)
    ds = DrawingSet(
        name=directory.name,
        sheets=[Sheet(sheet_number="E-101", discipline=Discipline.ELECTRICAL, views=[view])],
        **_PROV,
    )
    cir.save(ds, str(directory / "ground_truth.cir"))
    Image.new("RGB", (600, 400), "white").save(directory / "plan.png")


def test_connectivity_scoreboard_oracle_and_unvalidated(tmp_path) -> None:
    root = tmp_path / "syn"
    names = []
    for i in range(3):
        name = f"sample_{i:05d}"
        names.append(name)
        _write_graph_sample(root / name)
    split = tmp_path / "split.json"
    split.write_text(json.dumps({"val": names, "train": []}))

    report = run_connectivity_scoreboards(
        PerfectAdapter(), synthetic_root=root, split_json=split, real_root=None, conditions=(CLEAN,)
    )
    assert report.real_validated is False
    assert "UNVALIDATED" in report.text
    # the oracle reproduces the graph exactly -> perfect edge AP (proves filter+metric wiring)
    oracle_edge = [
        r for r in report.synthetic_records if r.model == "oracle" and r.metric == "graph_edge_ap"
    ]
    assert oracle_edge and all(abs(r.value - 1.0) < 1e-9 for r in oracle_edge)
