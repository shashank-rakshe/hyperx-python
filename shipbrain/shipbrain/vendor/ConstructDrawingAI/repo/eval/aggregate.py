"""Multi-seed aggregation: mean + std + 95% confidence interval.

Built in from the start (not bolted on): every headline number in the harness is the
aggregate of per-seed scores. For a deterministic adapter the seeds agree and the CI
collapses to zero; for a stochastic one (a frontier model at temperature > 0, or our
seeded weak-baseline simulator) the CI reflects real run-to-run variance. The 95% CI
uses the Student-t critical value for small seed counts.
"""

from __future__ import annotations

import math
import statistics
from collections.abc import Sequence
from dataclasses import dataclass

# Two-sided 95% Student-t critical values by degrees of freedom (n - 1).
_T95: dict[int, float] = {
    1: 12.706,
    2: 4.303,
    3: 3.182,
    4: 2.776,
    5: 2.571,
    6: 2.447,
    7: 2.365,
    8: 2.306,
    9: 2.262,
    10: 2.228,
    11: 2.201,
    12: 2.179,
    13: 2.160,
    14: 2.145,
    15: 2.131,
    16: 2.120,
    17: 2.110,
    18: 2.101,
    19: 2.093,
    20: 2.086,
    21: 2.080,
    22: 2.074,
    23: 2.069,
    24: 2.064,
    25: 2.060,
    26: 2.056,
    27: 2.052,
    28: 2.048,
    29: 2.045,
    30: 2.042,
}


def _t95(df: int) -> float:
    if df <= 0:
        return 0.0
    return _T95.get(df, 1.96)  # normal approximation for df > 30


@dataclass(frozen=True)
class Aggregate:
    """A headline number with its dispersion across seeds."""

    mean: float
    std: float
    ci95: float  # half-width of the 95% confidence interval
    n: int
    values: tuple[float, ...]

    @property
    def low(self) -> float:
        return self.mean - self.ci95

    @property
    def high(self) -> float:
        return self.mean + self.ci95

    def format(self, *, pct: bool = False, places: int = 3) -> str:
        """Render as ``mean +/- ci`` (optionally as a percentage)."""
        scale = 100.0 if pct else 1.0
        suffix = "%" if pct else ""
        return f"{self.mean * scale:.{places}f}{suffix} +/- {self.ci95 * scale:.{places}f}"


def aggregate(values: Sequence[float]) -> Aggregate:
    """Aggregate per-seed values into mean / std / 95% CI."""
    vals = tuple(float(v) for v in values)
    n = len(vals)
    if n == 0:
        return Aggregate(0.0, 0.0, 0.0, 0, ())
    mean = statistics.fmean(vals)
    if n == 1:
        return Aggregate(mean, 0.0, 0.0, 1, vals)
    std = statistics.stdev(vals)
    ci95 = _t95(n - 1) * std / math.sqrt(n)
    return Aggregate(mean, std, ci95, n, vals)
