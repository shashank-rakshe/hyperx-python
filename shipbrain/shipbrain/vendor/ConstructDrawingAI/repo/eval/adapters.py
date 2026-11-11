"""Pluggable model adapters for the evaluation harness.

Every system on the leaderboard implements :class:`ModelAdapter` so the harness
treats them identically. Two kinds:

* **Measured** adapters predict a CIR :class:`~cir.DrawingSet` per sample, scored by
  the metrics. :class:`PerfectAdapter` (the oracle / upper bound) is the only one in
  the default flow.
* **Reported** adapters return **literature-cited** numbers via
  :class:`ReportedNumbersAdapter` — every value carries its source and the model it
  came from. Both the specialist-SOTA reference and the frontier baseline are built
  this way (see :mod:`eval.fixtures`). No simulation, no random seeds.

This project does **not** call external APIs: there is no simulated frontier baseline
in the library, and nothing in the default flow needs an API key. The optional live
vision adapters live in :mod:`eval.frontier` and are never used by the demo,
leaderboard, or reported figures.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass

from cir import DrawingSet

from .tasks import EvalSample


class ModelAdapter(ABC):
    """A system the harness can score. Subclasses set :attr:`name`."""

    name: str = "adapter"
    #: If True the harness re-runs every seed (real variance); else one run suffices.
    is_stochastic: bool = False
    #: If False, the adapter only reports cited numbers and is never asked to predict.
    can_predict: bool = True

    @abstractmethod
    def predict(self, sample: EvalSample, *, seed: int = 0) -> DrawingSet:
        """Predict a CIR document for ``sample`` (must not read ``sample.ground_truth``)."""
        raise NotImplementedError

    def reported_score(self, metric: str, drawing_type: str) -> float | None:
        """Return a pre-recorded score for (metric, drawing_type), or None to run live."""
        return None

    def reported_citation(self, metric: str, drawing_type: str) -> str | None:
        """Return the citation for a reported (metric, drawing_type), or None."""
        return None


class PerfectAdapter(ModelAdapter):
    """An oracle that returns the ground truth — the metric upper bound."""

    name = "oracle"

    def predict(self, sample: EvalSample, *, seed: int = 0) -> DrawingSet:
        return sample.ground_truth.model_copy(deep=True)


@dataclass(frozen=True)
class ReportedNumber:
    """A literature-cited metric value with its source and the model it came from."""

    value: float
    source: str  # e.g. "AECV-Bench (Jan 2026)"
    model: str  # e.g. "best frontier VLM (GPT-5.x / Gemini 3)"

    def citation(self) -> str:
        """ASCII-safe ``model (source)`` citation string."""
        return f"{self.model} ({self.source})"


class ReportedNumbersAdapter(ModelAdapter):
    """Published, cited metric numbers — used for both the specialist-SOTA reference
    and the frontier baseline. Returns stored literature values; never runs inference.
    """

    can_predict = False

    def __init__(self, name: str, numbers: dict[tuple[str, str], ReportedNumber]) -> None:
        self.name = name
        self._numbers = dict(numbers)

    def predict(self, sample: EvalSample, *, seed: int = 0) -> DrawingSet:
        raise NotImplementedError(
            f"{self.name} reports cited literature numbers; it does not run inference."
        )

    def reported_score(self, metric: str, drawing_type: str) -> float | None:
        entry = self._numbers.get((metric, drawing_type))
        return entry.value if entry is not None else None

    def reported_citation(self, metric: str, drawing_type: str) -> str | None:
        entry = self._numbers.get((metric, drawing_type))
        return entry.citation() if entry is not None else None


_REGISTRY: dict[str, ModelAdapter] = {}


def register(adapter: ModelAdapter) -> ModelAdapter:
    """Register ``adapter`` under its :attr:`~ModelAdapter.name`."""
    _REGISTRY[adapter.name] = adapter
    return adapter


def get_adapter(name: str) -> ModelAdapter:
    """Return the registered adapter named ``name``."""
    try:
        return _REGISTRY[name]
    except KeyError as exc:
        raise KeyError(f"No adapter named {name!r}. Available: {sorted(_REGISTRY)}.") from exc


def available_adapters() -> list[str]:
    """Names of registered adapters."""
    return sorted(_REGISTRY)
