"""Model 1 — the electrical symbol detector (YOLOv11 via ultralytics).

Two responsibilities, deliberately separated:

* :func:`train_detector` — export the synthetic data to YOLO format, train a detector
  with **resumable checkpoints** (every ``save_period`` epochs -> survives SLURM
  preemption) and **lane-aware W&B logging**, and return the best-weights path. It runs
  entirely on our own hardware; nothing here calls an external API or SDK.
* :class:`TrainedDetector` — load trained weights and predict on a single **tile**
  image, returning boxes in **tile-local-normalized** coordinates. That is exactly the
  frame the L0->L1 handoff contract (``docs/HANDOFF.md``) says L1 returns per tile, so
  :class:`~perception.adapter.DetectorAdapter` can hand the result straight to
  :func:`ingest.handoff.aggregate` without re-deriving any coordinate mapping.

ultralytics' own per-epoch validation mAP is an internal training-loop signal (computed
on held-out *tiles*). The **reported** synthetic-validation number comes from the eval
harness via the adapter, scored at the *sheet* level — see :mod:`perception.scoreboard`.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import numpy as np

from cir import BBox, DataLane

from .config import resolve
from .dataset import export_from_config
from .labels import INDEX_TO_CLASS

logger = logging.getLogger(__name__)


def _as_numpy(value: Any) -> Any:
    """Normalize an ultralytics box tensor (torch.Tensor or ndarray) to a numpy array."""
    return value.cpu().numpy() if hasattr(value, "cpu") else np.asarray(value)


@dataclass
class TileSymbol:
    """One detected symbol on a tile, in tile-local-normalized coordinates."""

    label: str
    bbox: BBox  # tile-local normalized [0,1] — ready for handoff.TileDetection
    score: float


@dataclass
class DetectorTrainResult:
    """Outcome of a training run: where the weights are + the internal val metrics."""

    weights: Path  # best.pt (the one the adapter loads)
    save_dir: Path  # the ultralytics run directory (weights/, results.csv, ...)
    map50: float = 0.0  # ultralytics tile-level val mAP@0.5 (internal smoke signal)
    map50_95: float = 0.0
    per_class_map50: dict[str, float] = field(default_factory=dict)


def train_detector(cfg: Any, *, export: bool = True) -> DetectorTrainResult:
    """Train the detector for ``cfg`` (a detector config). Returns the best-weights path.

    Args:
        cfg: a detector :class:`~omegaconf.DictConfig` (see ``perception/conf/detector``).
        export: if True, (re)materialize the YOLO dataset from the synthetic source first.
    """
    from ultralytics import YOLO
    from ultralytics import settings as ul_settings

    # We drive W&B ourselves (lane-aware + offline-safe); disable ultralytics' own logger
    # so there is exactly one run per training, tagged with the data lane.
    try:
        ul_settings.update({"wandb": False})
    except Exception:  # pragma: no cover - settings schema varies across versions
        logger.debug("could not toggle ultralytics wandb setting; continuing")

    if export:
        result = export_from_config(cfg)
        logger.info(
            "dataset ready: %d train / %d val tiles", result.n_train_images, result.n_val_images
        )

    dataset_yaml = resolve(cfg.data.export_root) / "dataset.yaml"
    if not dataset_yaml.is_file():
        raise FileNotFoundError(
            f"{dataset_yaml} missing — run with export=True or call perception.dataset first."
        )

    tracker = _start_tracker(cfg)
    model = YOLO(str(cfg.model.arch))
    _attach_wandb_callback(model, tracker)

    train_kwargs = {
        "data": str(dataset_yaml),
        "epochs": int(cfg.train.epochs),
        "imgsz": int(cfg.data.imgsz),
        "batch": cfg.train.batch,  # int, or -1 for ultralytics auto-batch
        "device": cfg.train.device,  # int / "0,1,.." (DDP) / "cpu"
        "workers": int(cfg.train.workers),
        "project": str(resolve(cfg.train.project)),
        "name": str(cfg.train.name),
        "save_period": int(cfg.train.save_period),  # checkpoint cadence -> resumable
        "resume": bool(cfg.train.resume),
        "patience": int(cfg.train.patience),
        "seed": int(cfg.seed),
        "exist_ok": True,
        "plots": False,
        "verbose": True,
    }
    logger.info(
        "training detector: %s",
        {k: train_kwargs[k] for k in ("epochs", "imgsz", "batch", "device", "name")},
    )
    model.train(**train_kwargs)

    assert model.trainer is not None  # populated by .train()
    save_dir = Path(model.trainer.save_dir)
    best = save_dir / "weights" / "best.pt"
    outcome = DetectorTrainResult(weights=best, save_dir=save_dir)
    _capture_val_metrics(model, cfg, outcome)

    tracker.log({"final/map50": outcome.map50, "final/map50_95": outcome.map50_95})
    if best.is_file():
        tracker.log_artifact(best, name=f"detector-{cfg.profile}", artifact_type="model")
    tracker.finish()
    return outcome


def _start_tracker(cfg: Any) -> Any:
    """Begin a lane-aware W&B run for this training (no-ops gracefully if W&B absent)."""
    from omegaconf import OmegaConf

    from eval.tracking import ExperimentTracker

    mode = str(cfg.wandb.mode) if bool(cfg.wandb.enabled) else "disabled"
    os.environ.setdefault("WANDB_MODE", mode)
    tracker = ExperimentTracker(
        str(cfg.wandb.project),
        data_lane=DataLane(str(cfg.data_lane)),
        name=f"detector-{cfg.profile}",
        config=dict(OmegaConf.to_container(cfg, resolve=True)),  # type: ignore[arg-type]
        tags=["detector", str(cfg.profile)],
        mode=mode,
    )
    return tracker.start()


def _attach_wandb_callback(model: Any, tracker: Any) -> None:
    """Log ultralytics' per-epoch metrics through our lane-aware tracker."""

    def _on_fit_epoch_end(trainer: Any) -> None:
        try:
            metrics = {k: float(v) for k, v in (trainer.metrics or {}).items()}
            tracker.log(metrics, step=int(getattr(trainer, "epoch", 0)))
        except Exception:  # pragma: no cover - never let logging kill training
            logger.debug("epoch metric logging hiccup; continuing")

    model.add_callback("on_fit_epoch_end", _on_fit_epoch_end)


def _capture_val_metrics(model: Any, cfg: Any, outcome: DetectorTrainResult) -> None:
    """Read ultralytics' final tile-level val metrics into ``outcome`` (best-effort)."""
    try:
        metrics = model.val(
            data=str(resolve(cfg.data.export_root) / "dataset.yaml"),
            imgsz=int(cfg.data.imgsz),
            device=cfg.train.device,
            verbose=False,
            plots=False,
        )
        outcome.map50 = float(metrics.box.map50)
        outcome.map50_95 = float(metrics.box.map)
        names = getattr(metrics, "names", {}) or {}
        ap50 = getattr(metrics.box, "ap50", None)  # per-class AP@0.5 (numpy array)
        class_index = getattr(metrics.box, "ap_class_index", None)  # class id per ap50 row
        if ap50 is not None and class_index is not None:
            for idx, ap in zip(list(class_index), list(ap50), strict=False):
                outcome.per_class_map50[str(names.get(int(idx), int(idx)))] = float(ap)
    except Exception as exc:  # pragma: no cover - metric extraction is non-fatal
        logger.warning("could not capture ultralytics val metrics: %s", exc)


class TrainedDetector:
    """A loaded detector that predicts on one tile image at a time.

    Returns boxes in **tile-local-normalized** coordinates (the L0->L1 contract frame),
    so the adapter can compose them back to the sheet via :func:`ingest.handoff.aggregate`.
    """

    def __init__(
        self,
        weights: str | Path,
        *,
        conf: float = 0.25,
        iou: float = 0.5,
        imgsz: int = 1536,
        device: int | str | None = None,
    ) -> None:
        from ultralytics import YOLO

        self.weights = Path(weights)
        if not self.weights.is_file():
            raise FileNotFoundError(f"detector weights not found: {self.weights}")
        self.model = YOLO(str(self.weights))
        self.conf = conf
        self.iou = iou
        self.imgsz = imgsz
        self.device = device

    def predict_tile(self, image: Any) -> list[TileSymbol]:
        """Detect symbols on one tile (a PIL image); boxes are tile-local-normalized."""
        width, height = image.size
        result = self.model.predict(
            image,
            conf=self.conf,
            iou=self.iou,
            imgsz=self.imgsz,
            device=self.device,
            verbose=False,
        )[0]
        boxes = result.boxes
        if boxes is None:
            return []
        # Read vectorially (ultralytics Boxes exposes parallel tensors) — faster than
        # per-box iteration and avoids the stub's non-iterable Boxes type.
        xyxy = _as_numpy(boxes.xyxy)  # (N, 4), tile pixels
        classes = _as_numpy(boxes.cls)  # (N,)
        scores = _as_numpy(boxes.conf)  # (N,)
        symbols: list[TileSymbol] = []
        for i in range(len(xyxy)):
            x1, y1, x2, y2 = (float(v) for v in xyxy[i])
            cls = int(classes[i])
            detector_class = INDEX_TO_CLASS.get(cls)
            label = detector_class.label if detector_class is not None else str(cls)
            symbols.append(
                TileSymbol(
                    label=label,
                    bbox=BBox(
                        x_min=x1 / width,
                        y_min=y1 / height,
                        x_max=x2 / width,
                        y_max=y2 / height,
                    ),
                    score=float(scores[i]),
                )
            )
        return symbols


def latest_best_weights(project: str | Path, name: str) -> Path:
    """The ``best.pt`` for run ``name`` under ``project`` (raises if absent)."""
    best = resolve(str(project)) / name / "weights" / "best.pt"
    if not best.is_file():
        raise FileNotFoundError(f"no trained weights at {best} — train the detector first.")
    return best
