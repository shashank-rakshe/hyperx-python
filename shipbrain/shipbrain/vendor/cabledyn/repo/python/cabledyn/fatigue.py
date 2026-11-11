# SPDX-License-Identifier: Apache-2.0
"""Rainflow cycle counting and short-term damage-equivalent ranges."""

from __future__ import annotations

import contextlib
import csv
import math
import operator
import os
import tempfile
from collections import deque
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
import numpy.typing as npt

from cabledyn._optional import pyplot


@dataclass(frozen=True)
class RainflowCycle:
    """One closed cycle or residual half-cycle from a load history.

    Attributes
    ----------
    range : float
        Peak-to-trough range of the cycle (not its amplitude); positive.
    mean : float
        Mean of the two reversal values that bound the cycle.
    count : float
        Cycle weight: ``1.0`` for a closed cycle, ``0.5`` for a residual
        half-cycle.
    start_index : int
        Zero-based index of the first bounding reversal in the analysed samples.
    end_index : int
        Zero-based index of the second bounding reversal; greater than
        ``start_index``.
    start_time : float | None
        Time of ``start_index``, in seconds, when sample times were supplied.
    end_time : float | None
        Time of ``end_index``, in seconds, when sample times were supplied.
    """

    range: float
    mean: float
    count: float
    start_index: int
    end_index: int
    start_time: float | None = None
    end_time: float | None = None

    def __post_init__(self) -> None:
        if any(isinstance(value, bool) for value in (self.range, self.mean, self.count)):
            raise ValueError("rainflow cycle values must be numeric")
        values = tuple(float(value) for value in (self.range, self.mean, self.count))
        if not all(math.isfinite(value) for value in values):
            raise ValueError("rainflow cycle values must be finite")
        cycle_range, mean, count = values
        if cycle_range <= 0.0:
            raise ValueError("rainflow cycle range must be positive")
        if count not in {0.5, 1.0}:
            raise ValueError("rainflow cycle count must be 0.5 or 1.0")
        object.__setattr__(self, "range", cycle_range)
        object.__setattr__(self, "mean", mean)
        object.__setattr__(self, "count", count)
        for name in ("start_index", "end_index"):
            try:
                index = operator.index(getattr(self, name))
            except TypeError as exc:
                raise ValueError(f"{name} must be a non-negative integer") from exc
            if isinstance(getattr(self, name), bool) or index < 0:
                raise ValueError(f"{name} must be a non-negative integer")
            object.__setattr__(self, name, index)
        if self.end_index <= self.start_index:
            raise ValueError("end_index must be greater than start_index")
        if (self.start_time is None) != (self.end_time is None):
            raise ValueError("start_time and end_time must be supplied together")
        if self.start_time is not None and self.end_time is not None:
            start_time, end_time = float(self.start_time), float(self.end_time)
            if not math.isfinite(start_time) or not math.isfinite(end_time):
                raise ValueError("cycle times must be finite")
            if end_time <= start_time:
                raise ValueError("end_time must be greater than start_time")
            object.__setattr__(self, "start_time", start_time)
            object.__setattr__(self, "end_time", end_time)


@dataclass(frozen=True)
class RainflowHistogram:
    """Weighted rainflow counts grouped by cycle range.

    Attributes
    ----------
    bin_edges : numpy.ndarray
        Read-only, strictly increasing range-bin edges, one more than the bins.
    counts : numpy.ndarray
        Read-only weighted cycle count in each bin (half-cycles count 0.5).
    """

    bin_edges: npt.NDArray[Any]
    counts: npt.NDArray[Any]

    def __post_init__(self) -> None:
        edges = np.asarray(self.bin_edges, dtype=np.float64).copy()
        counts = np.asarray(self.counts, dtype=np.float64).copy()
        if edges.ndim != 1 or edges.size < 2 or not np.all(np.isfinite(edges)):
            raise ValueError("bin_edges must contain at least two finite values")
        if np.any(np.diff(edges) <= 0.0):
            raise ValueError("bin_edges must be strictly increasing")
        if counts.shape != (edges.size - 1,) or not np.all(np.isfinite(counts)):
            raise ValueError("counts must be finite and have one value per bin")
        if np.any(counts < 0.0):
            raise ValueError("histogram counts must be non-negative")
        edges.setflags(write=False)
        counts.setflags(write=False)
        object.__setattr__(self, "bin_edges", edges)
        object.__setattr__(self, "counts", counts)

    @property
    def bin_centers(self) -> npt.NDArray[Any]:
        """Read-only arithmetic centres of the range bins."""
        values: npt.NDArray[Any] = 0.5 * (self.bin_edges[:-1] + self.bin_edges[1:])
        values.setflags(write=False)
        return values

    @property
    def total_cycles(self) -> float:
        """Weighted number of full-cycle equivalents in all bins."""
        return float(np.sum(self.counts))


@dataclass(frozen=True)
class FatigueResult:
    """Uncorrected short-term rainflow/DEL result for one channel.

    Returned by :meth:`cabledyn.TimeHistory.fatigue`. The damage-equivalent
    range (DEL) is the constant range that, applied ``reference_cycles`` times,
    gives the same Palmgren-Miner damage as the counted cycles for an S-N curve
    of slope ``wohler_exponent``. No mean-stress correction is applied.

    Attributes
    ----------
    channel : str
        Name of the analysed channel.
    source : pathlib.Path
        Absolute path of the result file the channel was read from.
    unit : str | None
        Channel unit, or ``None`` if unknown; ranges share this unit.
    sample_count : int
        Number of samples analysed.
    start_time : float
        Time of the first analysed sample, in seconds.
    end_time : float
        Time of the last analysed sample, in seconds.
    duration : float
        ``end_time - start_time``, in seconds.
    wohler_exponent : float
        S-N curve slope exponent ``m``.
    reference_cycles : float
        Number of equivalent constant-range cycles.
    equivalent_frequency : float
        ``reference_cycles / duration``, in Hz.
    cycle_count : float
        Sum of the cycle weights.
    damage_equivalent_range : float
        The damage-equivalent range, in the channel unit.
    cycles : tuple[RainflowCycle, ...]
        Every counted cycle and half-cycle, in extraction order.
    histogram : RainflowHistogram | None
        Range histogram, present when bins were requested.
    """

    channel: str
    source: Path
    unit: str | None
    sample_count: int
    start_time: float
    end_time: float
    duration: float
    wohler_exponent: float
    reference_cycles: float
    equivalent_frequency: float
    cycle_count: float
    damage_equivalent_range: float
    cycles: tuple[RainflowCycle, ...]
    histogram: RainflowHistogram | None = None

    def __post_init__(self) -> None:
        if not isinstance(self.channel, str) or not self.channel:
            raise ValueError("channel must be a non-empty string")
        if self.unit is not None and not isinstance(self.unit, str):
            raise ValueError("unit must be a string or None")
        object.__setattr__(self, "source", Path(self.source).expanduser().resolve())
        try:
            sample_count = operator.index(self.sample_count)
        except TypeError as exc:
            raise ValueError("sample_count must be an integer of at least two") from exc
        if isinstance(self.sample_count, bool) or sample_count < 2:
            raise ValueError("sample_count must be an integer of at least two")
        object.__setattr__(self, "sample_count", sample_count)
        if any(
            isinstance(getattr(self, name), bool)
            for name in (
                "start_time",
                "end_time",
                "duration",
                "wohler_exponent",
                "reference_cycles",
                "equivalent_frequency",
                "cycle_count",
                "damage_equivalent_range",
            )
        ):
            raise ValueError("fatigue scalar values must be numeric")
        for name in (
            "start_time",
            "end_time",
            "duration",
            "wohler_exponent",
            "reference_cycles",
            "equivalent_frequency",
            "cycle_count",
            "damage_equivalent_range",
        ):
            value = float(getattr(self, name))
            if not math.isfinite(value):
                raise ValueError(f"{name} must be finite")
            object.__setattr__(self, name, value)
        if self.duration <= 0.0 or self.wohler_exponent <= 0.0:
            raise ValueError("duration and wohler_exponent must be positive")
        if self.end_time <= self.start_time or not math.isclose(
            self.end_time - self.start_time,
            self.duration,
            rel_tol=1.0e-12,
            abs_tol=1.0e-12,
        ):
            raise ValueError("start_time/end_time must define the reported duration")
        if self.reference_cycles <= 0.0 or self.equivalent_frequency <= 0.0:
            raise ValueError("reference_cycles and equivalent_frequency must be positive")
        if self.cycle_count < 0.0 or self.damage_equivalent_range < 0.0:
            raise ValueError("cycle_count and damage_equivalent_range must be non-negative")
        cycles = tuple(self.cycles)
        if not all(isinstance(cycle, RainflowCycle) for cycle in cycles):
            raise ValueError("cycles must contain RainflowCycle values")
        if cycles and any(
            (cycle.start_time is None) != (cycles[0].start_time is None) for cycle in cycles
        ):
            raise ValueError("cycles must use one consistent time-coordinate convention")
        if not math.isclose(
            sum(cycle.count for cycle in cycles), self.cycle_count, rel_tol=1.0e-12, abs_tol=1.0e-12
        ):
            raise ValueError("cycle_count must equal the sum of rainflow cycle weights")
        object.__setattr__(self, "cycles", cycles)
        if self.histogram is not None:
            if not isinstance(self.histogram, RainflowHistogram):
                raise ValueError("histogram must be a RainflowHistogram or None")
            if not math.isclose(
                self.histogram.total_cycles, self.cycle_count, rel_tol=1.0e-12, abs_tol=1.0e-12
            ):
                raise ValueError("histogram must contain every counted cycle")

    def plot_histogram(self, *, ax: Any = None) -> Any:
        """Plot weighted cycle counts against cycle range.

        Parameters
        ----------
        ax : matplotlib.axes.Axes | None
            Axes to draw on; a new figure is created when omitted.

        Returns
        -------
        matplotlib.axes.Axes
            The axes drawn on.

        Raises
        ------
        ValueError
            If the result has no histogram.
        """
        if self.histogram is None:
            raise ValueError("this fatigue result has no histogram; pass bins to fatigue()")
        plt = pyplot()
        if ax is None:
            _, ax = plt.subplots()
        widths = np.diff(self.histogram.bin_edges)
        ax.bar(self.histogram.bin_edges[:-1], self.histogram.counts, width=widths, align="edge")
        label = "Cycle range"
        if self.unit:
            label += f" [{self.unit}]"
        ax.set_xlabel(label)
        ax.set_ylabel("Cycle count [-]")
        ax.grid(True, axis="y")
        return ax

    def export_histogram(self, path: str | os.PathLike[str], *, overwrite: bool = False) -> Path:
        """Atomically export range-bin bounds, centres, and weighted counts.

        Writes a CSV file with one row per bin, with bounds and centres in the
        channel unit. Missing parent directories are created.

        Parameters
        ----------
        path : str | os.PathLike
            Target CSV file.
        overwrite : bool
            Replace an existing file instead of raising :class:`FileExistsError`.

        Returns
        -------
        pathlib.Path
            Absolute path of the written file.

        Raises
        ------
        ValueError
            If the result has no histogram or ``path`` is the source file.
        FileExistsError
            If ``path`` exists and ``overwrite`` is false.
        """
        if self.histogram is None:
            raise ValueError("this fatigue result has no histogram; pass bins to fatigue()")
        target = Path(path).expanduser().resolve()
        if target == self.source:
            raise ValueError("export target must not be the source result file")
        if target.exists() and not overwrite:
            raise FileExistsError(f"output already exists: {target}")
        target.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(
            prefix=f".{target.name}.",
            suffix=".tmp",
            dir=target.parent,
            text=True,
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
                writer = csv.writer(stream, lineterminator="\n")
                suffix = f"_[{self.unit}]" if self.unit else ""
                writer.writerow(
                    (
                        f"range_lower{suffix}",
                        f"range_upper{suffix}",
                        f"range_center{suffix}",
                        "count_[-]",
                    )
                )
                for lower, upper, center, count in zip(
                    self.histogram.bin_edges[:-1],
                    self.histogram.bin_edges[1:],
                    self.histogram.bin_centers,
                    self.histogram.counts,
                    strict=True,
                ):
                    writer.writerow(
                        f"{float(value):.17g}" for value in (lower, upper, center, count)
                    )
            os.replace(temporary, target)
        except BaseException:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(temporary)
            raise
        return target

    def export_cycles(self, path: str | os.PathLike[str], *, overwrite: bool = False) -> Path:
        """Atomically export every exact rainflow cycle used by the DEL.

        Writes a CSV file with one row per cycle: its weight, range, mean, and
        bounding sample indices, plus bounding times in seconds when they are
        known. Ranges and means are in the channel unit. Missing parent
        directories are created.

        Parameters
        ----------
        path : str | os.PathLike
            Target CSV file.
        overwrite : bool
            Replace an existing file instead of raising :class:`FileExistsError`.

        Returns
        -------
        pathlib.Path
            Absolute path of the written file.

        Raises
        ------
        ValueError
            If ``path`` is the source file.
        FileExistsError
            If ``path`` exists and ``overwrite`` is false.
        """
        target = Path(path).expanduser().resolve()
        if target == self.source:
            raise ValueError("export target must not be the source result file")
        if target.exists() and not overwrite:
            raise FileExistsError(f"output already exists: {target}")
        target.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(
            prefix=f".{target.name}.",
            suffix=".tmp",
            dir=target.parent,
            text=True,
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
                writer = csv.writer(stream, lineterminator="\n")
                suffix = f"_[{self.unit}]" if self.unit else ""
                timed = bool(self.cycles) and self.cycles[0].start_time is not None
                header = [
                    "count_[-]",
                    f"range{suffix}",
                    f"mean{suffix}",
                    "start_index_[-]",
                    "end_index_[-]",
                ]
                if timed:
                    header.extend(("start_time_[s]", "end_time_[s]"))
                writer.writerow(header)
                for cycle in self.cycles:
                    row: list[object] = [
                        f"{cycle.count:.17g}",
                        f"{cycle.range:.17g}",
                        f"{cycle.mean:.17g}",
                        cycle.start_index,
                        cycle.end_index,
                    ]
                    if timed:
                        row.extend((f"{cycle.start_time:.17g}", f"{cycle.end_time:.17g}"))
                    writer.writerow(row)
            os.replace(temporary, target)
        except BaseException:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(temporary)
            raise
        return target


def _reversals(series: npt.NDArray[Any]) -> tuple[tuple[int, float], ...]:
    """Return endpoint-inclusive reversals, retaining the last plateau point."""
    unique: list[tuple[int, float]] = [(0, float(series[0]))]
    for index in range(1, series.size):
        value = float(series[index])
        if value == unique[-1][1]:
            if len(unique) > 1:
                unique[-1] = (index, value)
        else:
            unique.append((index, value))
    if len(unique) < 2:
        return ()
    result = [unique[0]]
    for before, current, after in zip(unique, unique[1:], unique[2:], strict=False):
        if (current[1] - before[1]) * (after[1] - current[1]) < 0.0:
            result.append(current)
    result.append(unique[-1])
    return tuple(result)


def _cycle(first: tuple[int, float], second: tuple[int, float], count: float) -> RainflowCycle:
    return RainflowCycle(
        range=abs(second[1] - first[1]),
        mean=0.5 * (first[1] + second[1]),
        count=count,
        start_index=first[0],
        end_index=second[0],
    )


def rainflow_cycles(
    values: Iterable[float] | npt.NDArray[Any],
    *,
    time: Iterable[float] | npt.NDArray[Any] | None = None,
) -> tuple[RainflowCycle, ...]:
    """Count Downing--Socie/ASTM-style cycles in a finite scalar history.

    Complete closed cycles have weight 1.0. Unclosed residual cycles have
    weight 0.5, following the wind-energy convention used by NREL MLife.

    Parameters
    ----------
    values : collections.abc.Iterable[float] | numpy.ndarray
        Non-empty, finite, one-dimensional load history.
    time : collections.abc.Iterable[float] | numpy.ndarray | None
        Optional strictly increasing sample times, in seconds, one per value.
        When given, each cycle also records its bounding times.

    Returns
    -------
    tuple[RainflowCycle, ...]
        The counted cycles; empty for a constant history.

    Raises
    ------
    ValueError
        If the history or the times are empty, not finite, or mismatched, or
        the times do not strictly increase.
    """
    try:
        source = values if isinstance(values, np.ndarray) else tuple(values)
        series = np.asarray(source, dtype=np.float64)
    except (TypeError, ValueError) as exc:
        raise ValueError(
            "rainflow input must be a non-empty one-dimensional numeric sequence"
        ) from exc
    if series.ndim != 1 or series.size == 0:
        raise ValueError("rainflow input must be a non-empty one-dimensional sequence")
    if not np.all(np.isfinite(series)):
        raise ValueError("rainflow input values must be finite")
    coordinates = None
    if time is not None:
        try:
            source_time = time if isinstance(time, np.ndarray) else tuple(time)
            coordinates = np.asarray(source_time, dtype=np.float64)
        except (TypeError, ValueError) as exc:
            raise ValueError("rainflow time must be a finite one-dimensional sequence") from exc
        if coordinates.shape != series.shape or not np.all(np.isfinite(coordinates)):
            raise ValueError("rainflow time must be finite and match the input values")
        if np.any(np.diff(coordinates) <= 0.0):
            raise ValueError("rainflow time must be strictly increasing")
    points = deque(_reversals(series))
    if len(points) < 2:
        return ()
    stack: deque[tuple[int, float]] = deque()
    result: list[RainflowCycle] = []
    while points:
        stack.append(points.popleft())
        while len(stack) >= 3:
            older_range = abs(stack[-2][1] - stack[-3][1])
            newer_range = abs(stack[-1][1] - stack[-2][1])
            if newer_range < older_range:
                break
            if len(stack) == 3:
                result.append(_cycle(stack[0], stack[1], 0.5))
                stack.popleft()
            else:
                result.append(_cycle(stack[-3], stack[-2], 1.0))
                newest = stack.pop()
                stack.pop()
                stack.pop()
                stack.append(newest)
    while len(stack) > 1:
        first = stack.popleft()
        result.append(_cycle(first, stack[0], 0.5))
    cycles = tuple(result)
    if coordinates is None:
        return cycles
    return tuple(
        RainflowCycle(
            cycle.range,
            cycle.mean,
            cycle.count,
            cycle.start_index,
            cycle.end_index,
            float(coordinates[cycle.start_index]),
            float(coordinates[cycle.end_index]),
        )
        for cycle in cycles
    )


def cycle_histogram(
    cycles: Iterable[RainflowCycle],
    bins: int | Iterable[float],
) -> RainflowHistogram:
    """Group weighted cycle counts by range without altering DEL calculations.

    Parameters
    ----------
    cycles : collections.abc.Iterable[RainflowCycle]
        Cycles to group, typically from :func:`rainflow_cycles`.
    bins : int | collections.abc.Iterable[float]
        A number of equal-width bins from zero to the largest range, or
        explicit strictly increasing edges that span every cycle range.

    Returns
    -------
    RainflowHistogram
        The weighted counts per bin.

    Raises
    ------
    ValueError
        If ``bins`` is invalid, the edges do not span every range, or a bin
        count is requested for an empty cycle set.
    """
    selected = tuple(cycles)
    if not all(isinstance(cycle, RainflowCycle) for cycle in selected):
        raise ValueError("cycles must contain RainflowCycle values")
    if isinstance(bins, bool):
        raise ValueError("bins must be a positive integer or finite edge sequence")
    count: int | None
    try:
        count = operator.index(bins)  # type: ignore[arg-type]
    except TypeError:
        count = None
    edges: npt.NDArray[Any]
    if count is None:
        try:
            edges = np.asarray(tuple(bins), dtype=np.float64)  # type: ignore[arg-type]
        except (TypeError, ValueError) as exc:
            raise ValueError("bins must be a positive integer or finite edge sequence") from exc
        if edges.ndim != 1 or edges.size < 2 or not np.all(np.isfinite(edges)):
            raise ValueError("histogram edges must contain at least two finite values")
        if np.any(np.diff(edges) <= 0.0):
            raise ValueError("histogram edges must be strictly increasing")
        if selected and (
            edges[0] > min(cycle.range for cycle in selected)
            or edges[-1] < max(cycle.range for cycle in selected)
        ):
            raise ValueError("histogram edges must span every cycle range")
    else:
        if count <= 0:
            raise ValueError("bins must be a positive integer")
        if not selected:
            raise ValueError("cannot infer histogram limits from an empty cycle set")
        maximum = max(cycle.range for cycle in selected)
        edges = np.linspace(0.0, maximum, count + 1)
    if not selected:
        return RainflowHistogram(edges, np.zeros(edges.size - 1))
    ranges = np.asarray([cycle.range for cycle in selected], dtype=np.float64)
    weights = np.asarray([cycle.count for cycle in selected], dtype=np.float64)
    counts, edges = np.histogram(ranges, bins=edges, weights=weights)
    return RainflowHistogram(edges, counts)


def damage_equivalent_range(
    cycles: Iterable[RainflowCycle], *, wohler_exponent: float, reference_cycles: float
) -> float:
    """Return the uncorrected DEL range for an explicit reference cycle count.

    The damage-equivalent range is
    ``(sum(n_i * S_i**m) / reference_cycles) ** (1 / m)`` over cycle weights
    ``n_i`` and ranges ``S_i``, with ``m`` the Wohler exponent.

    Parameters
    ----------
    cycles : collections.abc.Iterable[RainflowCycle]
        Cycles to combine, typically from :func:`rainflow_cycles`.
    wohler_exponent : float
        Positive S-N curve slope exponent ``m``.
    reference_cycles : float
        Positive number of equivalent constant-range cycles.

    Returns
    -------
    float
        The damage-equivalent range; ``0.0`` for an empty cycle set.

    Raises
    ------
    ValueError
        If the exponent or the reference cycle count is not finite and positive.
    """
    if isinstance(wohler_exponent, bool) or isinstance(reference_cycles, bool):
        raise ValueError("wohler_exponent and reference_cycles must be numeric")
    exponent = float(wohler_exponent)
    reference = float(reference_cycles)
    if not math.isfinite(exponent) or exponent <= 0.0:
        raise ValueError("wohler_exponent must be finite and positive")
    if not math.isfinite(reference) or reference <= 0.0:
        raise ValueError("reference_cycles must be finite and positive")
    selected = tuple(cycles)
    if not selected:
        return 0.0
    if not all(isinstance(cycle, RainflowCycle) for cycle in selected):
        raise ValueError("cycles must contain RainflowCycle values")
    maximum = max(cycle.range for cycle in selected)
    normalized = math.fsum(cycle.count * (cycle.range / maximum) ** exponent for cycle in selected)
    return float(maximum * (normalized / reference) ** (1.0 / exponent))
