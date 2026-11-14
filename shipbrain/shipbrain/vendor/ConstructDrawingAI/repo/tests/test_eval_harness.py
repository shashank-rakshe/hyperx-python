"""Tests for the eval adapters, leaderboard, harness, tiling, and frontier parsing."""

from __future__ import annotations

from pathlib import Path

import pytest

from cir import DrawingSet, make_example_drawing_set
from eval.adapters import ModelAdapter, PerfectAdapter
from eval.fixtures import demo_tasks, published_frontier, published_sota
from eval.frontier import ClaudeAdapter, _extract_json
from eval.harness import run_matrix, run_task
from eval.leaderboard import Leaderboard, ResultRecord
from eval.tasks import EvalSample, Slice
from eval.tiling import nms, tile_image


class _DropoutAdapter(ModelAdapter):
    """Test-only stochastic adapter: seed-dependent entity dropout (harder on degraded
    slices), used solely to exercise the multi-seed CI + slicing machinery. It is NOT a
    frontier baseline — the library ships no simulated baseline."""

    is_stochastic = True
    name = "dropout-test"

    def predict(self, sample: EvalSample, *, seed: int = 0) -> DrawingSet:
        import random
        import zlib

        rng = random.Random(seed * 100_003 + zlib.crc32(sample.id.encode()))
        miss = 0.3 + (0.3 if sample.slice.condition == "degraded" else 0.0)
        doc = sample.ground_truth.model_copy(deep=True)
        for sheet in doc.sheets:
            for view in sheet.views:
                kept = [e for e in view.entities if rng.random() >= miss]
                ids = {e.id for e in kept}
                view.entities = kept
                view.connections = [
                    c for c in view.connections if c.source_id in ids and c.target_id in ids
                ]
        return doc


def test_perfect_adapter_scores_perfectly() -> None:
    mep_task = demo_tasks()[0]
    records = run_task(PerfectAdapter(), mep_task, seeds=(0,))
    map_records = [r for r in records if r.metric == "detection_map"]
    assert map_records
    assert all(r.value == 1.0 for r in map_records)


def test_stochastic_test_adapter_is_deterministic_per_seed() -> None:
    sample = demo_tasks()[0].samples[0]
    adapter = _DropoutAdapter()
    assert (
        adapter.predict(sample, seed=1).entity_count()
        == adapter.predict(sample, seed=1).entity_count()
    )


def test_reported_adapter_short_circuits_and_skips_unreported() -> None:
    records = run_task(published_sota(), demo_tasks()[0], seeds=(0, 1, 2))
    metrics = {r.metric for r in records}
    assert "detection_map" in metrics  # reported for mep
    assert "counting_mape" not in metrics  # not reported -> skipped, never predicted
    assert all(r.kind == "reported" and r.n_seeds == 1 for r in records)


def test_multiseed_produces_real_ci() -> None:
    records = run_task(_DropoutAdapter(), demo_tasks()[0], seeds=(0, 1, 2))
    map_records = [r for r in records if r.metric == "detection_map"]
    assert any(r.n_seeds == 3 for r in map_records)
    assert any(r.ci95 > 0.0 for r in map_records)


def test_degraded_slice_is_harder_than_clean() -> None:
    records = run_task(_DropoutAdapter(), demo_tasks()[0], seeds=(0, 1, 2))
    by = {(r.condition): r.value for r in records if r.metric == "detection_map"}
    assert by["clean"] > by["degraded"]


def test_leaderboard_roundtrip_and_render() -> None:
    board = Leaderboard(":memory:")
    board.add(ResultRecord(model="ours", metric="detection_map", value=0.83, drawing_type="mep"))
    found = board.query(metric="detection_map")
    assert len(found) == 1 and found[0].model == "ours"
    table = board.render_table("detection_map", "mep")
    assert "detection_map" in table and "ours" in table
    board.close()


def test_run_matrix_populates_leaderboard() -> None:
    board = Leaderboard(":memory:")
    run_matrix([PerfectAdapter(), published_sota()], demo_tasks(), seeds=(0,), leaderboard=board)
    assert board.metrics()
    report = board.render_report()
    assert "Matrix evaluation leaderboard" in report
    board.close()


def test_published_frontier_has_cited_numbers() -> None:
    frontier = published_frontier()
    assert frontier.reported_score("counting_mape", "mep") == 20.5
    citation = frontier.reported_citation("counting_mape", "mep")
    assert citation and "AECV-Bench" in citation
    # a metric it does not carry -> None (so the harness skips it, never predicts)
    assert frontier.reported_score("external_wall_iou", "architectural") is None


def test_default_demo_flow_needs_no_api_key(monkeypatch: pytest.MonkeyPatch) -> None:
    """The full demo runs with NO API keys set, and emits cited + measured rows."""
    for key in ("ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GOOGLE_API_KEY"):
        monkeypatch.delenv(key, raising=False)
    board = Leaderboard(":memory:")
    run_matrix(
        [PerfectAdapter(), published_sota(), published_frontier()],
        demo_tasks(),
        seeds=(0,),
        leaderboard=board,
    )
    report = board.render_report()
    assert "published-frontier" in report
    assert "AECV-Bench" in report  # literature citation present
    assert "measured by us" in report  # measured-vs-cited labeling present
    board.close()


def test_graph_sota_is_corrected_and_slice_keyed() -> None:
    """A8: P&ID connectivity SOTA is the cited real number, keyed real-vs-synthetic."""
    from eval.fixtures import published_sota_synthetic, published_synthetic_only

    real = published_sota()
    assert real.reported_score("graph_edge_ap", "mep") == 0.7546  # Relationformer, real OPEN100
    assert real.reported_score("graph_node_ap", "mep") == 0.8363
    assert "2411.13929" in (real.reported_citation("graph_edge_ap", "mep") or "")
    assert real.reported_score("graph_edge_ap", "mep") != 0.78  # the stale value is gone

    # synthetic in-distribution ceiling and the synthetic-only-on-real bar are separate rows
    assert published_sota_synthetic().reported_score("graph_edge_ap", "mep") == 0.8895
    assert published_synthetic_only().reported_score("graph_edge_ap", "mep") == 0.638


def test_tiling_small_and_large(tmp_path: Path) -> None:
    from PIL import Image

    small = tmp_path / "small.png"
    Image.new("RGB", (100, 80)).save(small)
    assert len(tile_image(small, tile_size=256).tiles) == 1

    large = tmp_path / "large.png"
    Image.new("RGB", (800, 300)).save(large)
    assert len(tile_image(large, tile_size=256, overlap=32).tiles) > 1


def test_nms_dedups_overlapping() -> None:
    dets = [
        {"label": "R", "bbox": (0.0, 0.0, 0.1, 0.1), "confidence": 0.9},
        {"label": "R", "bbox": (0.01, 0.01, 0.11, 0.11), "confidence": 0.5},
    ]
    kept = nms(dets, iou_threshold=0.5)
    assert len(kept) == 1 and kept[0]["confidence"] == 0.9


def test_frontier_extract_json() -> None:
    parsed = _extract_json('prose {"detections": [{"label": "x"}]} trailing')
    assert parsed["detections"][0]["label"] == "x"
    assert _extract_json("no json here") == {"detections": []}


def test_frontier_predict_with_mocked_call(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    from PIL import Image

    image = tmp_path / "drawing.png"
    Image.new("RGB", (300, 200)).save(image)

    adapter = ClaudeAdapter()
    monkeypatch.setattr(
        adapter,
        "_call",
        lambda image, prompt, *, seed: (
            '{"detections": [{"label": "Door", "bbox": [0.1, 0.1, 0.2, 0.2], "confidence": 0.7}]}'
        ),
    )
    sample = EvalSample("s", make_example_drawing_set(), Slice("arch"), image_path=image)
    prediction = adapter.predict(sample, seed=0)
    assert "Door" in [e.label for e in prediction.iter_entities()]


def test_frontier_requires_api_key(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    with pytest.raises(RuntimeError):
        ClaudeAdapter()._require_key()
