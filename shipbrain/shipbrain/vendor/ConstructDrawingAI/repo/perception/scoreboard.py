"""Two evaluation scoreboards for the wedge models — synthetic vs. real.

This is the most important architectural requirement of Build Playbook 2.1. The first
wedge models are the first whose real success is measured *outside this repo* — on real
electrical drawings — so the harness keeps two scoreboards that must never be conflated:

* **Synthetic-validation scoreboard.** The trained model scored on held-out *synthetic*
  electrical sheets. This is a **pipeline smoke test**: a high number here means the
  training loop, the L0->L1 handoff, and the CIR wiring all work — it is **NOT** evidence
  the model reads real drawings. Every line of output says so.
* **Real-drawing scoreboard.** The slot + loader for evaluation on real annotated plans.
  We do not have real data yet (DELP's full set is gated; sourcing a small real test set
  is a parallel task). The loader and harness wiring exist **now**, so the moment even
  20-50 real annotated electrical plans land they drop in and produce a sim-to-real number
  with zero new plumbing. Until then this board reports, in words,
  *"no real test data — sim-to-real transfer UNVALIDATED"* — it never silently shows only
  synthetic numbers as if they were the real result.

Both boards report against the **published-SOTA** and **published-frontier** reference
rows already in the harness (:func:`eval.fixtures.published_sota` /
:func:`eval.fixtures.published_frontier`) — cited literature numbers, **no live API calls**.
Those references were measured on *real* drawings, so on the synthetic board they are shown
only as out-of-distribution context (explicitly not a fair comparison); the meaningful
comparison to SOTA happens on the real board, once it has data.

The drop-in real-data layout (either form works):

* per-sample dirs:  ``<real_root>/sample_*/`` each with ``ground_truth.cir`` + an image
  (``plan.png`` / ``image.png`` / any ``*.png``); or
* flat pairs:       ``<real_root>/<stem>.cir`` next to ``<real_root>/<stem>.png``.

A converter from VOC/COCO real annotations into ``ground_truth.cir`` is the small bridge
to add when such annotations arrive (the DELP VOC->CIR converter already exists — see
``datasets/preparers/delp.py`` and ``docs/DECISIONS.md`` ADR-0010).
"""

from __future__ import annotations

import json
import logging
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from pathlib import Path

import cir
from cir import DataLane, DrawingSet, LicenseProvenance, Sheet, View, ViewType
from eval.adapters import ModelAdapter, PerfectAdapter
from eval.fixtures import (
    published_frontier,
    published_sota,
    published_sota_synthetic,
    published_synthetic_only,
)
from eval.harness import run_task
from eval.leaderboard import Leaderboard, ResultRecord
from eval.tasks import CLEAN, DEGRADED, RASTER, EvalSample, EvalTask, Slice

from .dataset import plan_sheet
from .labels import is_detectable

logger = logging.getLogger(__name__)

#: Drawing type used for slices, so the cited reference rows (keyed by "mep") line up.
DRAWING_TYPE = "mep"
#: The metrics the symbol detector is scored on (graph metrics belong to Model 2).
DETECTOR_METRICS = ["detection_map", "counting_mape", "counting_exact_match", "panoptic_quality"]
#: The metrics the connectivity model is scored on (nodes + edges).
GRAPH_METRICS = ["graph_node_ap", "graph_edge_ap"]

_CONDITION_IMAGE = {CLEAN: "plan.png", DEGRADED: "plan.deg.png"}


# ---------------------------------------------------------------------------
# Ground-truth reduction: score detection on detection targets only
# ---------------------------------------------------------------------------
def filter_to_detection_targets(ds: DrawingSet) -> DrawingSet:
    """Reduce a full synthetic GT to just the detector's symbols on the plan sheet.

    A synthetic ground-truth :class:`~cir.DrawingSet` also carries walls, room tags,
    dimensions, and (on other sheets) schedule rows — none of which the symbol detector
    predicts. Scoring against the full set would unfairly tank detection mAP / counting
    (those non-target classes would all read as missed). So the detection scoreboard
    compares the prediction against the same class space the detector works in.
    """
    sheet = plan_sheet(ds)
    kept = [
        e.model_copy(deep=True)
        for e in sheet.iter_entities()
        if e.label is not None and is_detectable(e.label) and e.geometry is not None
    ]
    view = View(name="detection-targets", view_type=ViewType.PLAN, entities=kept)
    reduced_sheet = Sheet(
        sheet_number=sheet.sheet_number, discipline=sheet.discipline, views=[view]
    )
    return DrawingSet(
        id=ds.id,
        name=ds.name,
        sheets=[reduced_sheet],
        license_provenance=ds.license_provenance,
        data_lane=ds.data_lane,
    )


def filter_to_graph(ds: DrawingSet) -> DrawingSet:
    """Reduce a full synthetic GT to the detectable nodes **and** their connectivity edges.

    Like :func:`filter_to_detection_targets`, but keeps the plan view's
    :class:`~cir.Connection` edges among the kept nodes, so ``graph_edge_ap`` is scored on
    the same node space the connectivity model produces. Edges whose endpoints are not
    detectable symbols are dropped.
    """
    sheet = plan_sheet(ds)
    view = sheet.views[0] if sheet.views else None
    kept = [
        e.model_copy(deep=True)
        for e in sheet.iter_entities()
        if e.label is not None and is_detectable(e.label) and e.geometry is not None
    ]
    kept_ids = {e.id for e in kept}
    connections = (
        [
            c.model_copy(deep=True)
            for c in view.connections
            if c.source_id in kept_ids and c.target_id in kept_ids
        ]
        if view is not None
        else []
    )
    reduced_view = View(
        name="graph", view_type=ViewType.PLAN, entities=kept, connections=connections
    )
    reduced_sheet = Sheet(
        sheet_number=sheet.sheet_number, discipline=sheet.discipline, views=[reduced_view]
    )
    return DrawingSet(
        id=ds.id,
        name=ds.name,
        sheets=[reduced_sheet],
        license_provenance=ds.license_provenance,
        data_lane=ds.data_lane,
    )


# ---------------------------------------------------------------------------
# Synthetic-validation scoreboard (the smoke test)
# ---------------------------------------------------------------------------
def _val_sample_dirs(
    synthetic_root: Path, split_json: Path | None, limit: int | None
) -> list[Path]:
    """The held-out synthetic sample dirs (from the export's persisted split.json)."""
    if split_json is not None and split_json.is_file():
        names = json.loads(split_json.read_text())["val"]
        dirs = [synthetic_root / n for n in names]
    else:  # no split persisted (e.g. eval-only) -> fall back to a deterministic slice
        from .dataset import assign_split, discover_samples

        all_dirs = discover_samples(synthetic_root)
        split = assign_split([d.name for d in all_dirs], val_fraction=0.2, seed=0)
        dirs = [d for d in all_dirs if split[d.name] == "val"]
        logger.warning("no split.json at %s; using a default deterministic val split", split_json)
    dirs = [d for d in dirs if (d / "ground_truth.cir").is_file()]
    return dirs[:limit] if limit is not None else dirs


def build_synthetic_validation_task(
    synthetic_root: str | Path,
    *,
    split_json: str | Path | None = None,
    conditions: Sequence[str] = (CLEAN, DEGRADED),
    limit: int | None = None,
    dataset_name: str = "synthetic-electrical",
    metrics: Sequence[str] = tuple(DETECTOR_METRICS),
    gt_filter: Callable[[DrawingSet], DrawingSet] = filter_to_detection_targets,
    task_name: str = "synthetic-validation",
) -> EvalTask:
    """Build the held-out synthetic-electrical task (the smoke-test board).

    ``gt_filter`` reduces each full GT to the relevant target space (detection symbols, or
    nodes+edges for connectivity); ``metrics`` selects what is scored.
    """
    root = Path(synthetic_root)
    split_path = Path(split_json) if split_json is not None else None
    sample_dirs = _val_sample_dirs(root, split_path, limit)
    if not sample_dirs:
        raise FileNotFoundError(
            f"no held-out synthetic samples under {root} (did you export the dataset?)"
        )

    samples: list[EvalSample] = []
    for sample_dir in sample_dirs:
        gt = gt_filter(cir.load(DrawingSet, str(sample_dir / "ground_truth.cir")))
        for condition in conditions:
            image = sample_dir / _CONDITION_IMAGE[condition]
            if not image.is_file():
                continue
            samples.append(
                EvalSample(
                    id=f"{sample_dir.name}-{condition}",
                    ground_truth=gt,
                    slice=Slice(DRAWING_TYPE, RASTER, condition, dataset_name),
                    image_path=image,
                )
            )
    return EvalTask(name=task_name, metrics=list(metrics), samples=samples)


# ---------------------------------------------------------------------------
# Real-drawing scoreboard (the slot + loader; UNVALIDATED until data arrives)
# ---------------------------------------------------------------------------
def _find_image(directory: Path, stem: str | None = None) -> Path | None:
    """Find a sheet image in ``directory`` (prefer plan.png/image.png, else any png/jpg)."""
    if stem is not None:
        for ext in (".png", ".jpg", ".jpeg"):
            candidate = directory / f"{stem}{ext}"
            if candidate.is_file():
                return candidate
        return None
    for preferred in ("plan.png", "image.png", "sheet.png"):
        if (directory / preferred).is_file():
            return directory / preferred
    for ext in ("*.png", "*.jpg", "*.jpeg"):
        hits = sorted(p for p in directory.glob(ext) if not p.name.endswith(".deg.png"))
        if hits:
            return hits[0]
    return None


def load_real_samples(real_root: str | Path) -> list[tuple[Path, DrawingSet]]:
    """Load (image_path, CIR ground truth) pairs from a real-data dir. ``[]`` if none.

    Accepts the per-sample-dir layout (``sample_*/ground_truth.cir`` + an image) and the
    flat layout (``<stem>.cir`` next to ``<stem>.png``). The contract is intentionally the
    same shape the synthetic engine emits, so real data drops in with no new plumbing.
    """
    root = Path(real_root)
    if not root.is_dir():
        return []
    pairs: list[tuple[Path, DrawingSet]] = []

    sample_dirs = [d for d in sorted(root.glob("sample_*")) if (d / "ground_truth.cir").is_file()]
    for sample_dir in sample_dirs:
        image = _find_image(sample_dir)
        if image is not None:
            pairs.append((image, cir.load(DrawingSet, str(sample_dir / "ground_truth.cir"))))

    if not pairs:  # flat layout: pair each *.cir with a same-stem image
        for cir_file in sorted(root.glob("*.cir")):
            image = _find_image(root, stem=cir_file.stem)
            if image is not None:
                pairs.append((image, cir.load(DrawingSet, str(cir_file))))
    return pairs


def build_real_drawing_task(
    real_root: str | Path | None,
    *,
    dataset_name: str = "real-electrical",
    metrics: Sequence[str] = tuple(DETECTOR_METRICS),
    gt_filter: Callable[[DrawingSet], DrawingSet] = filter_to_detection_targets,
    real_gt_transform: Callable[[DrawingSet], DrawingSet] | None = None,
    task_name: str = "real-drawing",
) -> EvalTask:
    """Build the real-drawing task. Empty (no samples) until real data exists.

    ``real_gt_transform`` runs on each loaded GT **before** ``gt_filter`` — the hook that
    maps a foreign taxonomy into our class space (e.g. the DELP→DEVICE_CATALOG crosswalk in
    :mod:`perception.crosswalk`), which the detection filter would otherwise drop wholesale.
    """
    samples: list[EvalSample] = []
    if real_root is not None:
        for image, gt in load_real_samples(real_root):
            if real_gt_transform is not None:
                gt = real_gt_transform(gt)
            samples.append(
                EvalSample(
                    id=image.parent.name + "/" + image.stem,
                    ground_truth=gt_filter(gt),
                    slice=Slice(DRAWING_TYPE, RASTER, CLEAN, dataset_name),
                    image_path=image,
                )
            )
    return EvalTask(name=task_name, metrics=list(metrics), samples=samples)


# ---------------------------------------------------------------------------
# Running both boards + the framed report
# ---------------------------------------------------------------------------
@dataclass
class ScoreboardReport:
    """The rendered two-section report + the raw records + whether real data was scored."""

    text: str
    real_validated: bool
    synthetic_records: list[ResultRecord] = field(default_factory=list)
    real_records: list[ResultRecord] = field(default_factory=list)

    def __str__(self) -> str:
        return self.text


_SYNTHETIC_BANNER = """\
================================================================================
SYNTHETIC-VALIDATION SCOREBOARD  —  PIPELINE SMOKE TEST (NOT real-drawing accuracy)
================================================================================
A number here means the training loop + L0->L1 handoff + CIR wiring work on
held-out SYNTHETIC data. It is NOT evidence the model reads real drawings.
The published-SOTA / published-frontier rows below were measured on REAL drawings
and are therefore NOT directly comparable to our synthetic row — they are shown for
context only. The meaningful comparison to SOTA is the REAL-DRAWING scoreboard.
"""

_REAL_BANNER_UNVALIDATED = """\
================================================================================
REAL-DRAWING SCOREBOARD  —  SIM-TO-REAL  (the number that actually matters)
================================================================================
no real test data — sim-to-real transfer UNVALIDATED.
We do not yet have real annotated electrical plans (DELP's full set is gated; a small
real test set is a parallel sourcing task). The loader + harness slot are wired: drop
20-50 annotated plans into the real-data dir and this board fills in with zero new
plumbing. The published-SOTA / published-frontier bars below are what a real number
must clear before any 'beats SOTA' claim is made.
"""

_REAL_BANNER_VALIDATED = """\
================================================================================
REAL-DRAWING SCOREBOARD  —  SIM-TO-REAL  (the number that actually matters)
================================================================================
Measured on REAL annotated electrical plans. THIS is the comparison to published SOTA.
"""


def _board_models(adapter: ModelAdapter, references: Sequence[ModelAdapter]) -> list[ModelAdapter]:
    """Our model + the oracle upper bound + the cited references (no duplicate oracle)."""
    models: list[ModelAdapter] = [adapter]
    if not isinstance(adapter, PerfectAdapter):
        models.append(PerfectAdapter())  # upper bound: a perfect prediction scores 1.0
    models.extend(references)
    return models


def _placeholder_real_task(metrics: Sequence[str]) -> EvalTask:
    """A one-sample task so the cited SOTA/frontier bars render on the empty real board.

    A reported-numbers adapter emits a row per (metric, slice); with zero real samples
    there are no slices and nothing renders. This hosts the bars on a single placeholder
    sample whose dummy ground truth is never read (reported adapters short-circuit).
    """
    dummy = DrawingSet(
        name="real-data-pending",
        license_provenance=LicenseProvenance.UNKNOWN,
        data_lane=DataLane.RESEARCH,
    )
    sample = EvalSample(
        id="real-data-pending",
        ground_truth=dummy,
        slice=Slice(DRAWING_TYPE, RASTER, CLEAN, "real-electrical (none yet)"),
    )
    return EvalTask(name="real-bars", metrics=list(metrics), samples=[sample])


def _run_boards(
    adapter: ModelAdapter,
    *,
    metrics: Sequence[str],
    gt_filter: Callable[[DrawingSet], DrawingSet],
    kind: str,
    synthetic_root: str | Path,
    split_json: str | Path | None,
    real_root: str | Path | None,
    real_gt_transform: Callable[[DrawingSet], DrawingSet] | None,
    seeds: Sequence[int],
    conditions: Sequence[str],
    limit: int | None,
    db_path: str | Path,
) -> ScoreboardReport:
    """The shared two-board engine for the detector and the connectivity model."""
    # Reference rows are slice-routed so a real number is never shown as one bar with a
    # synthetic one (ADR-0011/0012): the REAL board carries real-drawing SOTA + frontier +
    # the synthetic-only-on-real bar (the commercial-lane target); the SYNTHETIC board
    # carries only the in-distribution synthetic ceiling.
    real_refs = [published_sota(), published_frontier(), published_synthetic_only()]
    synth_refs = [published_sota_synthetic()]

    # --- synthetic board: our model + oracle upper bound + synthetic ceiling ------
    synthetic_task = build_synthetic_validation_task(
        synthetic_root,
        split_json=split_json,
        conditions=conditions,
        limit=limit,
        metrics=metrics,
        gt_filter=gt_filter,
        task_name=f"{kind}-synthetic-validation",
    )
    syn_board = Leaderboard(":memory:")
    syn_records: list[ResultRecord] = []
    for model in _board_models(adapter, synth_refs):
        syn_records.extend(run_task(model, synthetic_task, seeds=seeds, leaderboard=syn_board))

    # --- real board: our model if data exists, else just the bars -----------------
    real_task = build_real_drawing_task(
        real_root,
        metrics=metrics,
        gt_filter=gt_filter,
        real_gt_transform=real_gt_transform,
        task_name=f"{kind}-real-drawing",
    )
    real_validated = len(real_task.samples) > 0
    real_board = Leaderboard(":memory:")
    real_records: list[ResultRecord] = []
    if real_validated:
        for model in _board_models(adapter, real_refs):
            real_records.extend(run_task(model, real_task, seeds=seeds, leaderboard=real_board))
    else:
        # No real data yet: still show the SOTA/frontier bars the real number must clear.
        # Reported adapters need at least one slice to attach to, so host them on a single
        # placeholder sample (its dummy GT is never read by a reported-numbers adapter).
        bars_task = _placeholder_real_task(metrics)
        for adapter_ref in real_refs:
            real_records.extend(
                run_task(adapter_ref, bars_task, seeds=seeds, leaderboard=real_board)
            )

    # --- optional persistence (accumulating SQLite leaderboard) -------------------
    if str(db_path) != ":memory:":
        store = Leaderboard(db_path)
        store.add_many(syn_records)
        store.add_many(real_records)
        store.close()

    # --- render -------------------------------------------------------------------
    n_syn = len({s.id for s in synthetic_task.samples})
    parts = [
        _SYNTHETIC_BANNER,
        f"({kind}; held-out synthetic samples: {n_syn}; conditions: {', '.join(conditions)}; "
        f"model: {adapter.name})",
        "",
        syn_board.render_report(),
        "",
        _REAL_BANNER_VALIDATED if real_validated else _REAL_BANNER_UNVALIDATED,
        "",
        real_board.render_report() if real_records else "(no reference rows configured)",
    ]
    syn_board.close()
    real_board.close()
    return ScoreboardReport(
        text="\n".join(parts),
        real_validated=real_validated,
        synthetic_records=syn_records,
        real_records=real_records,
    )


def run_detector_scoreboards(
    adapter: ModelAdapter,
    *,
    synthetic_root: str | Path,
    split_json: str | Path | None = None,
    real_root: str | Path | None = None,
    real_gt_transform: Callable[[DrawingSet], DrawingSet] | None = None,
    seeds: Sequence[int] = (0,),
    conditions: Sequence[str] = (CLEAN, DEGRADED),
    limit: int | None = None,
    db_path: str | Path = ":memory:",
) -> ScoreboardReport:
    """Score the symbol detector (Model 1) on both boards — detection metrics."""
    return _run_boards(
        adapter,
        metrics=DETECTOR_METRICS,
        gt_filter=filter_to_detection_targets,
        kind="detection",
        synthetic_root=synthetic_root,
        split_json=split_json,
        real_root=real_root,
        real_gt_transform=real_gt_transform,
        seeds=seeds,
        conditions=conditions,
        limit=limit,
        db_path=db_path,
    )


def run_connectivity_scoreboards(
    adapter: ModelAdapter,
    *,
    synthetic_root: str | Path,
    split_json: str | Path | None = None,
    real_root: str | Path | None = None,
    seeds: Sequence[int] = (0,),
    conditions: Sequence[str] = (CLEAN, DEGRADED),
    limit: int | None = None,
    db_path: str | Path = ":memory:",
) -> ScoreboardReport:
    """Score the connectivity model (Model 2) on both boards — graph node/edge AP."""
    return _run_boards(
        adapter,
        metrics=GRAPH_METRICS,
        gt_filter=filter_to_graph,
        kind="connectivity",
        synthetic_root=synthetic_root,
        split_json=split_json,
        real_root=real_root,
        real_gt_transform=None,
        seeds=seeds,
        conditions=conditions,
        limit=limit,
        db_path=db_path,
    )
