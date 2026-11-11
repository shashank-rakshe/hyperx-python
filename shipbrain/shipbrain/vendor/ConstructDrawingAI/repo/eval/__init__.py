"""The matrix evaluation harness — our scientific backbone and SOTA claim.

In drawing understanding, quality lives and dies on per-symbol-family,
per-sheet-type, per-origin regression tracking — so the harness is built **before**
broad model work, and it is a *matrix* harness: every drawing type scored on its
native metrics.

Components:

* :mod:`eval.metrics` — real metric implementations (detection mAP, counting MAPE /
  exact-match, OCR, dimension accuracy, external-wall IoU, Chamfer, loop-closure, PQ,
  graph node/edge AP, QA accuracy, RFI reward). All operate on the CIR.
* :mod:`eval.tasks` — :class:`Slice` (drawing type / origin / condition / dataset),
  :class:`EvalSample`, :class:`EvalTask`.
* :mod:`eval.aggregate` — multi-seed mean / std / 95% CI (built in from the start).
* :mod:`eval.adapters` — the pluggable :class:`ModelAdapter` (oracle, seeded
  weak-baseline, published-numbers).
* :mod:`eval.frontier` — Claude / GPT / Gemini vision adapters with tiling.
  **OPTIONAL / UNUSED.** This project does not call external APIs; the default demo,
  leaderboard, and reported figures use cited literature numbers (see
  :func:`eval.fixtures.published_frontier`), never live calls. Retained for opt-in use.
* :mod:`eval.tiling` — gigapixel tiling + cross-tile NMS (used only by ``eval.frontier``).
* :mod:`eval.leaderboard` — SQLite store + SOTA comparison rendering.
* :mod:`eval.harness` — the runner (adapters × tasks × slices × seeds → results).
* :mod:`eval.tracking` — W&B experiment tracking (lane-aware).

Quick start::

    python -m eval demo        # synthetic gap report + leaderboard
"""

from __future__ import annotations

from .adapters import (
    ModelAdapter,
    PerfectAdapter,
    ReportedNumber,
    ReportedNumbersAdapter,
)
from .aggregate import Aggregate, aggregate
from .harness import run_matrix, run_task
from .leaderboard import Leaderboard, ResultRecord, format_value
from .metrics import HIGHER_IS_BETTER, METRICS, get_metric
from .tasks import EvalSample, EvalTask, Slice
from .tracking import ExperimentTracker
from .validate import (
    ExpectedPlacement,
    GroundTruthExpectation,
    SheetExpectation,
    ValidationIssue,
    ValidationReport,
    validate_ground_truth,
)

__all__ = [
    "METRICS",
    "HIGHER_IS_BETTER",
    "get_metric",
    "Slice",
    "EvalSample",
    "EvalTask",
    "GroundTruthExpectation",
    "SheetExpectation",
    "ExpectedPlacement",
    "ValidationReport",
    "ValidationIssue",
    "validate_ground_truth",
    "aggregate",
    "Aggregate",
    "ModelAdapter",
    "PerfectAdapter",
    "ReportedNumber",
    "ReportedNumbersAdapter",
    "Leaderboard",
    "ResultRecord",
    "format_value",
    "run_task",
    "run_matrix",
    "ExperimentTracker",
]
