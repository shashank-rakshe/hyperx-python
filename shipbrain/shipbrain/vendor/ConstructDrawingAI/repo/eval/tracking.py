"""Weights & Biases experiment-tracking integration (stub wrapper).

A thin, dependency-optional wrapper around W&B used by training (``perception``) and
the eval harness. Design goals:

* **Optional.** If ``wandb`` is not installed, the tracker degrades to a no-op that
  prints metrics, so code paths never break in minimal environments.
* **Offline-friendly.** Honors ``WANDB_MODE`` (e.g. ``offline`` on air-gapped compute
  nodes); a login-node ``wandb sync`` step uploads later.
* **Lane-aware.** Every run is tagged with its :class:`cir.DataLane`, so research and
  commercial experiments are never confused in the dashboard — a small but important
  piece of the two-lane discipline.

Example::

    from eval.tracking import ExperimentTracker
    from cir import DataLane

    with ExperimentTracker("wedge-detector", data_lane=DataLane.RESEARCH) as run:
        run.log({"map50": 0.83}, step=100)
        run.log_artifact("models/detector.pt", name="detector", artifact_type="model")

Status: **stub.** Real metric logging is wired in across Build Playbook steps 0.3+.
"""

from __future__ import annotations

import logging
import os
from pathlib import Path
from types import TracebackType
from typing import Any

from cir import DataLane

logger = logging.getLogger(__name__)


def _try_import_wandb() -> Any | None:
    """Return the ``wandb`` module if importable, else ``None``."""
    try:
        import wandb
    except ImportError:
        return None
    return wandb


class ExperimentTracker:
    """A W&B run wrapper that no-ops gracefully when W&B is unavailable."""

    def __init__(
        self,
        project: str,
        *,
        data_lane: DataLane,
        name: str | None = None,
        config: dict[str, Any] | None = None,
        tags: list[str] | None = None,
        entity: str | None = None,
        mode: str | None = None,
    ) -> None:
        """Configure (but do not yet start) a tracked run.

        Args:
            project: W&B project name.
            data_lane: The lane this run belongs to; added as a tag and to config.
            name: Optional run name.
            config: Hyperparameters / run config.
            tags: Extra tags (``data_lane`` is always added).
            entity: W&B entity (team/user).
            mode: W&B mode override ("online" | "offline" | "disabled"); falls back
                to the ``WANDB_MODE`` env var, then "online".
        """
        self.project = project
        self.data_lane = data_lane
        self.name = name
        self.entity = entity
        self.mode = mode or os.environ.get("WANDB_MODE", "online")
        self.config: dict[str, Any] = {**(config or {}), "data_lane": data_lane.value}
        self.tags = [*(tags or []), f"lane:{data_lane.value}"]
        self._wandb = _try_import_wandb()
        self._run: Any | None = None

    def start(self) -> ExperimentTracker:
        """Begin the run (initializes W&B if available)."""
        if self._wandb is None:
            logger.warning("wandb not installed; ExperimentTracker is running in no-op mode.")
            return self
        self._run = self._wandb.init(
            project=self.project,
            name=self.name,
            entity=self.entity,
            config=self.config,
            tags=self.tags,
            mode=self.mode,
        )
        return self

    def log(self, metrics: dict[str, Any], *, step: int | None = None) -> None:
        """Log a dict of metrics, optionally at a given step."""
        if self._run is not None:
            self._run.log(metrics, step=step)
        else:
            logger.info("[no-op tracker] step=%s metrics=%s", step, metrics)

    def log_artifact(self, path: str | Path, *, name: str, artifact_type: str) -> None:
        """Log a file/directory as a W&B artifact (no-op if W&B is unavailable)."""
        if self._wandb is None or self._run is None:
            logger.info("[no-op tracker] artifact %s (%s) at %s", name, artifact_type, path)
            return
        artifact = self._wandb.Artifact(name=name, type=artifact_type)
        artifact.add_file(str(path)) if Path(path).is_file() else artifact.add_dir(str(path))
        self._run.log_artifact(artifact)

    def finish(self) -> None:
        """Finish the run."""
        if self._run is not None:
            self._run.finish()
            self._run = None

    def __enter__(self) -> ExperimentTracker:
        return self.start()

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: TracebackType | None,
    ) -> None:
        self.finish()
