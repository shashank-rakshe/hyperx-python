# SPDX-License-Identifier: Apache-2.0
"""Channel-by-channel comparison of two time histories.

:func:`compare_histories` lines up two :class:`~cabledyn.TimeHistory` tables
(for example a CableDyn run and a MoorDyn or OrcaFlex reference, or two
CableDyn versions) on one time grid and reports error metrics and the change
of the usual engineering statistics for each channel.

Alignment never extrapolates. Both records are restricted to the interval
they share (optionally narrowed by ``start``/``stop``), and the candidate is
linearly interpolated onto the reference samples inside it (or the other way
round with ``grid="candidate"``). When the two time vectors are identical no
interpolation takes place.
"""

from __future__ import annotations

import contextlib
import csv
import math
import os
import tempfile
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
import numpy.typing as npt

from cabledyn.results import TimeHistory, _clean_unit

__all__ = ["ChannelComparison", "HistoryComparison", "compare_histories"]


@dataclass(frozen=True)
class ChannelComparison:
    """Error metrics for one channel pair, ``difference = candidate - reference``.

    ``normalized_rms_difference`` divides the RMS difference by the reference
    standard deviation and ``relative_max_difference`` divides the largest
    absolute difference by the largest absolute reference value; either is
    ``nan`` when its denominator is zero. ``correlation`` is the Pearson
    coefficient, ``nan`` when either signal is constant. The ``*_delta``
    members are candidate minus reference for the statistic named, and
    ``percentile_delta`` uses :attr:`HistoryComparison.percentile`.

    Differences, deltas, and maxima are in the unit of the channel (for
    example N for a tension, m for a position).

    Attributes
    ----------
    channel : str
        Reference channel name.
    candidate_channel : str
        Candidate channel name paired with it.
    unit : str | None
        Channel unit (the reference unit when recorded, otherwise the
        candidate unit), or ``None`` if unknown.
    count : int
        Number of aligned samples compared.
    max_abs_difference : float
        Largest absolute difference.
    mean_difference : float
        Mean difference (bias).
    rms_difference : float
        Root-mean-square difference.
    normalized_rms_difference : float
        RMS difference over the reference standard deviation; dimensionless.
    relative_max_difference : float
        Largest absolute difference over the largest absolute reference value;
        dimensionless.
    correlation : float
        Pearson correlation coefficient, in ``[-1, 1]``.
    reference_maximum : float
        Largest aligned reference value.
    candidate_maximum : float
        Largest aligned candidate value.
    maximum_delta : float
        Change of the maximum.
    minimum_delta : float
        Change of the minimum.
    mean_delta : float
        Change of the mean.
    standard_deviation_delta : float
        Change of the population standard deviation.
    percentile_delta : float
        Change of the :attr:`HistoryComparison.percentile` percentile.
    """

    channel: str
    candidate_channel: str
    unit: str | None
    count: int
    max_abs_difference: float
    mean_difference: float
    rms_difference: float
    normalized_rms_difference: float
    relative_max_difference: float
    correlation: float
    reference_maximum: float
    candidate_maximum: float
    maximum_delta: float
    minimum_delta: float
    mean_delta: float
    standard_deviation_delta: float
    percentile_delta: float


_EXPORT_FIELDS = tuple(ChannelComparison.__dataclass_fields__)


@dataclass(frozen=True)
class HistoryComparison:
    """Comparison of every selected channel over one aligned time grid.

    Attributes
    ----------
    reference : pathlib.Path
        Source file of the reference history.
    candidate : pathlib.Path
        Source file of the candidate history.
    time : numpy.ndarray
        Read-only ``(n_samples,)`` aligned sample times, in seconds.
    percentile : float
        Percentile, in ``[0, 100]``, used for
        :attr:`ChannelComparison.percentile_delta`.
    channels : tuple[ChannelComparison, ...]
        One comparison per channel pair, in the requested order.
    """

    reference: Path
    candidate: Path
    time: npt.NDArray[Any]
    percentile: float
    channels: tuple[ChannelComparison, ...]

    def __post_init__(self) -> None:
        time = np.array(self.time, dtype=np.float64, copy=True)
        time.setflags(write=False)
        object.__setattr__(self, "time", time)
        object.__setattr__(self, "channels", tuple(self.channels))

    @property
    def start_time(self) -> float:
        """First aligned sample time in seconds."""
        return float(self.time[0])

    @property
    def end_time(self) -> float:
        """Last aligned sample time in seconds."""
        return float(self.time[-1])

    def channel(self, name: str) -> ChannelComparison:
        """Return the comparison of reference channel ``name``.

        Parameters
        ----------
        name : str
            Reference channel name.

        Returns
        -------
        ChannelComparison
            The metrics for that channel.

        Raises
        ------
        KeyError
            If the channel was not compared.
        """
        for item in self.channels:
            if item.channel == name:
                return item
        raise KeyError(
            f"{name!r} was not compared; compared: "
            f"{', '.join(item.channel for item in self.channels)}"
        )

    def worst(
        self,
        count: int = 1,
        *,
        metric: str = "normalized_rms_difference",
    ) -> tuple[ChannelComparison, ...]:
        """Return the ``count`` channels with the largest ``metric`` (``nan`` last).

        Parameters
        ----------
        count : int
            Positive number of channels to return; fewer are returned when
            fewer were compared.
        metric : str
            Name of a numeric :class:`ChannelComparison` field. Channels are
            ranked by its absolute value.

        Returns
        -------
        tuple[ChannelComparison, ...]
            Up to ``count`` comparisons, largest ``abs(metric)`` first.

        Raises
        ------
        ValueError
            If ``metric`` is not a numeric field or ``count`` is not a positive
            integer.
        """
        if metric not in _EXPORT_FIELDS or metric in {
            "channel",
            "candidate_channel",
            "unit",
            "count",
        }:
            raise ValueError(f"{metric!r} is not a numeric comparison metric")
        if isinstance(count, bool) or not isinstance(count, int) or count <= 0:
            raise ValueError("count must be a positive integer")

        def key(item: ChannelComparison) -> tuple[bool, float]:
            value = float(getattr(item, metric))
            return (math.isnan(value), -abs(value) if not math.isnan(value) else 0.0)

        return tuple(sorted(self.channels, key=key)[:count])

    def export(self, path: str | os.PathLike[str], *, overwrite: bool = False) -> Path:
        """Atomically write one CSV row per channel with every metric.

        The header row holds the :class:`ChannelComparison` field names.

        Parameters
        ----------
        path : str | os.PathLike
            Target CSV file. Missing parent directories are created.
        overwrite : bool
            Replace an existing file instead of raising :class:`FileExistsError`.

        Returns
        -------
        pathlib.Path
            Absolute path of the written file.

        Raises
        ------
        FileExistsError
            If ``path`` exists and ``overwrite`` is false.
        ValueError
            If ``path`` is one of the compared result files.
        """
        target = Path(path).expanduser().resolve()
        if target in {self.reference, self.candidate}:
            raise ValueError("export target must not be a compared result file")
        if target.exists() and not overwrite:
            raise FileExistsError(f"output already exists: {target}")
        target.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(
            prefix=f".{target.name}.", suffix=".tmp", dir=target.parent, text=True
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
                writer = csv.writer(stream, lineterminator="\n")
                writer.writerow(_EXPORT_FIELDS)
                for item in self.channels:
                    row: list[str] = []
                    for name in _EXPORT_FIELDS:
                        value = getattr(item, name)
                        if isinstance(value, float):
                            row.append(f"{value:.17g}")
                        else:
                            row.append("" if value is None else str(value))
                    writer.writerow(row)
            os.replace(temporary, target)
        except BaseException:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(temporary)
            raise
        return target


def _ratio(numerator: float, denominator: float) -> float:
    return numerator / denominator if denominator > 0.0 else float("nan")


def _pairs(
    reference: TimeHistory,
    candidate: TimeHistory,
    channels: str | Iterable[str] | Mapping[str, str] | None,
) -> tuple[tuple[str, str], ...]:
    if channels is None:
        pairs = tuple(
            (name, name)
            for name in reference.channels
            if name != reference.time_channel
            and name in candidate.channels
            and name != candidate.time_channel
        )
        if not pairs:
            raise ValueError("the two histories share no channel names; pass a channel mapping")
        return pairs
    if isinstance(channels, str):
        pairs = ((channels, channels),)
    elif isinstance(channels, Mapping):
        pairs = tuple((str(key), str(value)) for key, value in channels.items())
    else:
        pairs = tuple((str(name), str(name)) for name in channels)
    if not pairs:
        raise ValueError("channels must not be empty")
    if len({name for name, _ in pairs}) != len(pairs):
        raise ValueError("reference channels must be unique")
    for name, other in pairs:
        if name == reference.time_channel or other == candidate.time_channel:
            raise ValueError("the time channel cannot be compared")
        reference.column(name)
        candidate.column(other)
    return pairs


def compare_histories(
    reference: TimeHistory,
    candidate: TimeHistory,
    *,
    channels: str | Iterable[str] | Mapping[str, str] | None = None,
    start: float | None = None,
    stop: float | None = None,
    grid: str = "reference",
    percentile: float = 95.0,
    check_units: bool = True,
) -> HistoryComparison:
    """Compare ``candidate`` against ``reference`` channel by channel.

    Parameters
    ----------
    reference : TimeHistory
        Reference record.
    candidate : TimeHistory
        Record compared against it.
    channels : str | collections.abc.Iterable[str] | collections.abc.Mapping[str, str] | None
        ``None`` compares every non-time channel present in both tables under
        the same name. A name or list of names compares those names; a mapping
        ``{reference_name: candidate_name}`` pairs differently named channels
        (for example ``{"FairTen1": "FAIRTEN1"}``).
    start, stop : float | None
        Optional period, in seconds, applied after restricting to the shared
        interval.
    grid : str
        ``"reference"`` (default) interpolates the candidate onto the reference
        samples; ``"candidate"`` does the reverse.
    percentile : float
        Percentile in ``[0, 100]`` reported as ``percentile_delta``.
    check_units : bool
        When both tables record a unit for a pair, a mismatch raises
        ``ValueError`` unless this is false.

    Returns
    -------
    HistoryComparison
        The aligned time grid, in seconds, and one :class:`ChannelComparison`
        per channel pair, with differences in the channel unit.

    Raises
    ------
    TypeError
        If either argument is not a :class:`TimeHistory`.
    KeyError
        If a requested channel is missing from its table.
    ValueError
        If ``grid`` or ``percentile`` is invalid, a limit is not finite, no
        channel can be paired, the time channel is requested, the aligned
        period has fewer than two samples, or the units of a pair differ.
    """
    if not isinstance(reference, TimeHistory) or not isinstance(candidate, TimeHistory):
        raise TypeError("compare_histories requires two TimeHistory tables")
    if grid not in {"reference", "candidate"}:
        raise ValueError("grid must be 'reference' or 'candidate'")
    if isinstance(percentile, bool) or not 0.0 <= float(percentile) <= 100.0:
        raise ValueError("percentile must be in [0, 100]")
    for value, label in ((start, "start"), (stop, "stop")):
        if value is not None and not math.isfinite(float(value)):
            raise ValueError(f"{label} must be finite")
    pairs = _pairs(reference, candidate, channels)
    lower = max(float(reference.time[0]), float(candidate.time[0]))
    upper = min(float(reference.time[-1]), float(candidate.time[-1]))
    if start is not None:
        lower = max(lower, float(start))
    if stop is not None:
        upper = min(upper, float(stop))
    if lower > upper:
        raise ValueError("the histories do not overlap in the requested period")
    base = reference if grid == "reference" else candidate
    mask = (base.time >= lower) & (base.time <= upper)
    time = base.time[mask]
    if time.size < 2:
        raise ValueError("the aligned period needs at least two samples")

    def aligned(table: TimeHistory, channel: str) -> npt.NDArray[Any]:
        if table is base:
            return np.asarray(table.column(channel)[mask], dtype=np.float64)
        if table.time.shape == base.time.shape and np.array_equal(table.time, base.time):
            return np.asarray(table.column(channel)[mask], dtype=np.float64)
        return np.asarray(np.interp(time, table.time, table.column(channel)), dtype=np.float64)

    results: list[ChannelComparison] = []
    for name, other in pairs:
        reference_unit = reference.unit(name)
        candidate_unit = candidate.unit(other)
        if (
            check_units
            and reference_unit is not None
            and candidate_unit is not None
            and _clean_unit(reference_unit).lower() != _clean_unit(candidate_unit).lower()
        ):
            raise ValueError(
                f"unit mismatch for {name!r}: {reference_unit!r} vs {candidate_unit!r}; "
                "pass check_units=False to compare anyway"
            )
        ref = aligned(reference, name)
        cand = aligned(candidate, other)
        difference = cand - ref
        rms = float(np.sqrt(np.mean(difference**2)))
        ref_std, cand_std = float(np.std(ref)), float(np.std(cand))
        correlation = (
            float(np.corrcoef(ref, cand)[0, 1])
            if ref_std > 0.0 and cand_std > 0.0
            else float("nan")
        )
        max_abs = float(np.max(np.abs(difference)))
        results.append(
            ChannelComparison(
                channel=name,
                candidate_channel=other,
                unit=reference_unit if reference_unit is not None else candidate_unit,
                count=int(time.size),
                max_abs_difference=max_abs,
                mean_difference=float(np.mean(difference)),
                rms_difference=rms,
                normalized_rms_difference=_ratio(rms, ref_std),
                relative_max_difference=_ratio(max_abs, float(np.max(np.abs(ref)))),
                correlation=correlation,
                reference_maximum=float(np.max(ref)),
                candidate_maximum=float(np.max(cand)),
                maximum_delta=float(np.max(cand) - np.max(ref)),
                minimum_delta=float(np.min(cand) - np.min(ref)),
                mean_delta=float(np.mean(cand) - np.mean(ref)),
                standard_deviation_delta=cand_std - ref_std,
                percentile_delta=float(
                    np.percentile(cand, percentile) - np.percentile(ref, percentile)
                ),
            )
        )
    return HistoryComparison(
        reference.path, candidate.path, time, float(percentile), tuple(results)
    )
