"""Eval tasks, samples, and the slicing dimensions.

A :class:`Slice` is the conditioning under which a number is reported — drawing type,
vector-vs-raster origin, clean-vs-degraded, and dataset. Every :class:`EvalSample`
carries one, so the harness can report **sliced** results (never silently averaging
across incomparable conditions). An :class:`EvalTask` bundles samples with the list
of metrics to compute over them.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

from cir import DrawingSet

VECTOR = "vector"
RASTER = "raster"
CLEAN = "clean"
DEGRADED = "degraded"


@dataclass(frozen=True)
class Slice:
    """The conditioning dimensions every result is sliced by."""

    drawing_type: str = "unknown"  # mep, architectural, pid, structural, ...
    origin: str = "unknown"  # vector | raster
    condition: str = "clean"  # clean | degraded
    dataset: str = "unknown"

    def key(self) -> str:
        return f"{self.drawing_type}/{self.origin}/{self.condition}/{self.dataset}"

    def as_dict(self) -> dict[str, str]:
        return {
            "drawing_type": self.drawing_type,
            "origin": self.origin,
            "condition": self.condition,
            "dataset": self.dataset,
        }


@dataclass
class EvalSample:
    """One scored item: ground-truth CIR + its slice (+ an image for vision models)."""

    id: str
    ground_truth: DrawingSet
    slice: Slice
    image_path: Path | None = None


@dataclass
class EvalTask:
    """A named set of samples plus the metrics to compute over them."""

    name: str
    metrics: list[str]
    samples: list[EvalSample] = field(default_factory=list)

    def slices(self) -> dict[Slice, list[EvalSample]]:
        """Group the samples by their slice."""
        grouped: dict[Slice, list[EvalSample]] = defaultdict(list)
        for sample in self.samples:
            grouped[sample.slice].append(sample)
        return dict(grouped)
