# SPDX-License-Identifier: Apache-2.0
"""Resampling and zero-phase filtering of time histories.

Every function returns a new table of the same type as its input (for example
:class:`~cabledyn.TimeHistory` or a per-line history) with the same channels,
units, source path, and title; the input is never modified.

* :func:`resample` linearly interpolates every channel onto a uniform step or
  an explicit set of times inside the recorded interval (never beyond it).
* :func:`moving_average` applies a centred moving mean with an odd number of
  samples. The result drops the half-window at each end, where the mean would
  be incomplete, so every returned sample is a full-window average.
* :func:`fft_filter` applies an ideal (rectangular) zero-phase low-, high-, or
  band-pass filter in the frequency domain.

Filters require uniform sampling (checked against ``uniform_rtol``). Use
:func:`resample` first for a variable-step record.
"""

from __future__ import annotations

import math
import operator
from collections.abc import Iterable
from typing import Any, TypeVar

import numpy as np
import numpy.typing as npt

from cabledyn.results import TimeHistory

__all__ = ["fft_filter", "moving_average", "resample"]

HistoryT = TypeVar("HistoryT", bound=TimeHistory)


def _finite(value: float | None, name: str) -> float | None:
    if value is None:
        return None
    if isinstance(value, bool):
        raise ValueError(f"{name} must be a finite number")
    result = float(value)
    if not math.isfinite(result):
        raise ValueError(f"{name} must be a finite number")
    return result


def _rebuild(history: HistoryT, time: npt.NDArray[Any], values: npt.NDArray[Any]) -> HistoryT:
    index = history.channels.index(history.time_channel)
    table = np.array(values, dtype=np.float64, copy=True)
    table[:, index] = time
    return type(history)(history.path, history.title, history.channels, history.units, table)


def _selected(history: TimeHistory, channels: str | Iterable[str] | None) -> list[int]:
    if channels is None:
        names = [name for name in history.channels if name != history.time_channel]
    elif isinstance(channels, str):
        names = [channels]
    else:
        names = list(channels)
    if not names:
        raise ValueError("at least one channel must be selected")
    if history.time_channel in names:
        raise ValueError("the time channel cannot be filtered")
    for name in names:
        history.column(name)
    return [history.channels.index(name) for name in dict.fromkeys(names)]


def _uniform_step(history: TimeHistory, rtol: float) -> float:
    time = history.time
    if time.size < 2:
        raise ValueError("filtering requires at least two samples")
    intervals = np.diff(time)
    step = float(np.median(intervals))
    if not np.allclose(intervals, step, rtol=rtol, atol=0.0):
        raise ValueError(
            "filtering requires uniform sampling; resample() the record first "
            f"(largest step deviation {float(np.max(np.abs(intervals - step))):.6g} s)"
        )
    return step


def resample(
    history: HistoryT,
    *,
    step: float | None = None,
    times: npt.ArrayLike | None = None,
    start: float | None = None,
    stop: float | None = None,
) -> HistoryT:
    """Linearly interpolate every channel onto new sample times.

    Give exactly one of ``step`` (a uniform grid from ``start``, default the
    first sample, up to and including ``stop``, default the last sample) or
    ``times`` (strictly increasing values inside the recorded interval).

    Parameters
    ----------
    history : TimeHistory
        Record to resample; any :class:`~cabledyn.TimeHistory` subclass.
    step : float | None
        Positive uniform time step, in seconds.
    times : array_like | None
        ``(n_samples,)`` strictly increasing sample times, in seconds, inside
        the recorded interval.
    start, stop : float | None
        Uniform-grid limits, in seconds; allowed only with ``step``.

    Returns
    -------
    TimeHistory
        A new table of the same class as ``history``, with ``values`` of shape
        ``(n_samples, n_channels)`` and every channel in its original unit.

    Raises
    ------
    ValueError
        If not exactly one of ``step`` and ``times`` is given, ``start`` or
        ``stop`` accompanies ``times``, a value is not finite, ``step`` is not
        positive, ``start`` exceeds ``stop``, ``times`` is not strictly
        increasing, or a requested time lies outside the recorded interval.
    """
    if (step is None) == (times is None):
        raise ValueError("pass exactly one of step or times")
    first, last = float(history.time[0]), float(history.time[-1])
    if times is not None:
        if start is not None or stop is not None:
            raise ValueError("start and stop apply only to a uniform step")
        grid = np.asarray(times, dtype=np.float64).copy()
        if grid.ndim != 1 or grid.size == 0 or not np.all(np.isfinite(grid)):
            raise ValueError("times must be a non-empty one-dimensional finite array")
        if grid.size > 1 and np.any(np.diff(grid) <= 0.0):
            raise ValueError("times must be strictly increasing")
    else:
        increment = _finite(step, "step")
        if increment is None or increment <= 0.0:
            raise ValueError("step must be finite and positive")
        lower = first if start is None else _finite(start, "start")
        upper = last if stop is None else _finite(stop, "stop")
        assert lower is not None and upper is not None
        if lower > upper:
            raise ValueError("start must not exceed stop")
        count = math.floor((upper - lower) / increment * (1.0 + 1.0e-12)) + 1
        grid = lower + increment * np.arange(count, dtype=np.float64)
    if grid[0] < first or grid[-1] > last:
        raise ValueError(
            f"resampling times must lie inside the recorded interval [{first:g}, {last:g}]"
        )
    values = np.column_stack(
        [
            np.interp(grid, history.time, history.values[:, index])
            for index in range(len(history.channels))
        ]
    )
    return _rebuild(history, grid, values)


def moving_average(
    history: HistoryT,
    window: int,
    *,
    channels: str | Iterable[str] | None = None,
    uniform_rtol: float = 1.0e-6,
) -> HistoryT:
    """Return the centred moving mean over ``window`` samples (an odd integer >= 1).

    Unselected channels are kept at the retained sample times unchanged. The
    first and last ``window // 2`` samples are dropped.

    Parameters
    ----------
    history : TimeHistory
        Uniformly sampled record; any :class:`~cabledyn.TimeHistory` subclass.
    window : int
        Odd, positive number of samples averaged, at most the sample count.
    channels : str | collections.abc.Iterable[str] | None
        Channels to smooth; every non-time channel when ``None``.
    uniform_rtol : float
        Relative tolerance for accepting the time steps as uniform.

    Returns
    -------
    TimeHistory
        A new table of the same class as ``history`` with
        ``n_samples - 2 * (window // 2)`` rows; units are unchanged.

    Raises
    ------
    KeyError
        If a selected channel is not in the table.
    ValueError
        If ``window`` is not an odd positive integer or exceeds the record, no
        channel or the time channel is selected, or the sampling is not
        uniform.
    """
    try:
        width = operator.index(window)
    except TypeError as exc:
        raise ValueError("window must be an odd positive integer") from exc
    if isinstance(window, bool) or width < 1 or width % 2 == 0:
        raise ValueError("window must be an odd positive integer")
    selected = _selected(history, channels)
    _uniform_step(history, uniform_rtol)
    if width > history.time.size:
        raise ValueError("window is longer than the record")
    half = width // 2
    kept = slice(half, history.time.size - half)
    values = history.values[kept].copy()
    kernel = np.full(width, 1.0 / width)
    for index in selected:
        values[:, index] = np.convolve(history.values[:, index], kernel, mode="valid")
    return _rebuild(history, history.time[kept], values)


def fft_filter(
    history: HistoryT,
    *,
    low: float | None = None,
    high: float | None = None,
    channels: str | Iterable[str] | None = None,
    detrend: str = "linear",
    uniform_rtol: float = 1.0e-6,
) -> HistoryT:
    """Keep only the frequency band ``low <= f <= high`` (Hz) with a zero-phase FFT filter.

    Give ``high`` alone for a low-pass, ``low`` alone for a high-pass, or both
    for a band-pass filter.

    The FFT treats the record as periodic, so a record whose ends do not
    match rings near its ends. With ``detrend="linear"`` (default) the
    least-squares straight line is subtracted before the transform, which
    removes the largest end mismatch of a drifting record, and restored
    afterwards only for a low-pass filter, whose band includes zero
    frequency. ``detrend="none"`` filters the record as it is, which is exact
    for a record holding a whole number of periods of every component. The
    filter is ideal, not tapered: judge results away from the record ends
    and sharp transients.

    Parameters
    ----------
    history : TimeHistory
        Uniformly sampled record; any :class:`~cabledyn.TimeHistory` subclass.
    low : float | None
        Positive lower pass-band edge, in Hz; ``None`` for a low-pass filter.
    high : float | None
        Positive upper pass-band edge, in Hz; ``None`` for a high-pass filter.
        A low-pass edge must lie below the Nyquist frequency.
    channels : str | collections.abc.Iterable[str] | None
        Channels to filter; every non-time channel when ``None``. Other
        channels are returned unchanged.
    detrend : str
        ``"linear"`` or ``"none"``, as described above.
    uniform_rtol : float
        Relative tolerance for accepting the time steps as uniform.

    Returns
    -------
    TimeHistory
        A new table of the same class and shape as ``history``, with the same
        sample times and units.

    Raises
    ------
    KeyError
        If a selected channel is not in the table.
    ValueError
        If neither edge is given, an edge is not finite and positive,
        ``low >= high``, ``detrend`` is unknown, no channel or the time channel
        is selected, the sampling is not uniform, a low-pass edge reaches the
        Nyquist frequency, or the pass band holds no frequency bin.
    """
    lower = _finite(low, "low")
    upper = _finite(high, "high")
    if lower is None and upper is None:
        raise ValueError("give low, high, or both")
    if (lower is not None and lower <= 0.0) or (upper is not None and upper <= 0.0):
        raise ValueError("filter frequencies must be positive")
    if lower is not None and upper is not None and lower >= upper:
        raise ValueError("low must be below high")
    if detrend not in {"linear", "none"}:
        raise ValueError("detrend must be 'linear' or 'none'")
    selected = _selected(history, channels)
    step = _uniform_step(history, uniform_rtol)
    count = history.time.size
    frequency = np.fft.rfftfreq(count, d=step)
    if upper is not None and upper >= frequency[-1] and lower is None:
        raise ValueError(f"high must be below the Nyquist frequency {frequency[-1]:g} Hz")
    keep = np.ones(frequency.shape, dtype=bool)
    if lower is not None:
        keep &= frequency >= lower
    if upper is not None:
        keep &= frequency <= upper
    if not np.any(keep):
        raise ValueError("the pass band contains no frequency bins of this record")
    design = np.column_stack((np.ones(count), history.time - history.time[0]))
    values = history.values.copy()
    for index in selected:
        signal = history.values[:, index]
        if detrend == "linear":
            coefficients, *_ = np.linalg.lstsq(design, signal, rcond=None)
            trend = design @ coefficients
        else:
            trend = np.zeros(count)
        spectrum = np.fft.rfft(signal - trend)
        filtered = np.fft.irfft(np.where(keep, spectrum, 0.0), n=count)
        values[:, index] = filtered + trend if lower is None else filtered
    return _rebuild(history, history.time.copy(), values)
