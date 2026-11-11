"""L1 — Perception Primitives. **The core bet.**

These are the fine-tuned specialist models that read drawings, expressed against the
CIR. Frontier VLMs are unreliable drawing *perceivers* today (symbol counting collapses;
16-25% MAPE vs. the 1-3% estimators need); this gap is the opportunity, and L1 is where
we invest.

Build Playbook 2.1 (the wedge, electrical) is implemented here:

* **Model 1 — symbol detection** (:mod:`perception.detector`, :mod:`perception.adapter`):
  a YOLOv11 detector over the synthetic engine's device/panel classes
  (:mod:`perception.labels`), trained on the synthetic electrical data
  (:mod:`perception.dataset`), wired into the CIR strictly through the L0->L1 handoff
  contract (``ingest.handoff``). A few-shot legend head (:mod:`perception.fewshot`)
  adapts to a new project's bespoke symbols from a handful of examples.
* **Model 2 — connectivity extraction** (:mod:`perception.connectivity`): the wedge
  differentiator — recovers the electrical graph (home-run -> panel, conductor runs,
  switch legs) into CIR :class:`~cir.Connection` edges.

The most important architectural rule lives in :mod:`perception.scoreboard`: synthetic
and real evaluation are **two separate scoreboards**. A good synthetic number is a
pipeline smoke test, never evidence the model reads real drawings — the real board
reports ``UNVALIDATED`` until real annotated plans exist. Nothing in L1 calls an external
API; these are our own models on our own hardware (``torch``/``ultralytics`` are imported
lazily, only when a model is actually trained or run).

Two model lanes are kept clearly separated (see ``docs/DECISIONS.md``): a research-lane
model (public data, for SOTA/benchmarks) and a commercial-lane model (synthetic +
permissive only, for the shippable product).

See :mod:`perception.base` for the interface every primitive implements.
"""

from __future__ import annotations

from .adapter import DetectorAdapter
from .base import PerceptionModule
from .config import available_profiles, load_config
from .connectivity import (
    ConnectivityAdapter,
    ConnectivityModel,
    ConnectivityTrainResult,
    latest_connectivity_weights,
    train_connectivity,
)
from .dataset import ExportResult, export_from_config, export_yolo_dataset
from .detector import DetectorTrainResult, TrainedDetector, latest_best_weights, train_detector
from .labels import CLASS_NAMES, DETECTOR_CLASSES, NUM_CLASSES, is_detectable
from .scoreboard import (
    DETECTOR_METRICS,
    GRAPH_METRICS,
    ScoreboardReport,
    build_real_drawing_task,
    build_synthetic_validation_task,
    filter_to_detection_targets,
    filter_to_graph,
    load_real_samples,
    run_connectivity_scoreboards,
    run_detector_scoreboards,
)

__all__ = [
    "PerceptionModule",
    # config
    "load_config",
    "available_profiles",
    # labels
    "CLASS_NAMES",
    "NUM_CLASSES",
    "DETECTOR_CLASSES",
    "is_detectable",
    # dataset export
    "export_yolo_dataset",
    "export_from_config",
    "ExportResult",
    # detector (Model 1)
    "TrainedDetector",
    "train_detector",
    "DetectorTrainResult",
    "latest_best_weights",
    "DetectorAdapter",
    # connectivity (Model 2)
    "ConnectivityModel",
    "ConnectivityAdapter",
    "ConnectivityTrainResult",
    "train_connectivity",
    "latest_connectivity_weights",
    # scoreboards
    "run_detector_scoreboards",
    "run_connectivity_scoreboards",
    "ScoreboardReport",
    "build_synthetic_validation_task",
    "build_real_drawing_task",
    "filter_to_detection_targets",
    "filter_to_graph",
    "load_real_samples",
    "DETECTOR_METRICS",
    "GRAPH_METRICS",
]
