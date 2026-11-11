# SPDX-License-Identifier: Apache-2.0
"""Auditable Welch spectra, spectral moments, and coherence estimates."""

from __future__ import annotations

import contextlib
import csv
import math
import operator
import os
import tempfile
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
import numpy.typing as npt

from cabledyn._optional import pyplot

#: Default relative auto-spectrum floor below which coherence bins are invalid.
DEFAULT_POWER_FLOOR_RATIO = 100.0 * float(np.finfo(float).eps)


def _readonly(values: npt.ArrayLike, *, dtype: npt.DTypeLike = np.float64) -> npt.NDArray[Any]:
    result: npt.NDArray[Any] = np.asarray(values, dtype=dtype).copy()
    result.setflags(write=False)
    return result


def _positive_integer(value: int, name: str, *, minimum: int = 1) -> int:
    try:
        result = operator.index(value)
    except TypeError as exc:
        raise ValueError(f"{name} must be an integer of at least {minimum}") from exc
    if isinstance(value, bool) or result < minimum:
        raise ValueError(f"{name} must be an integer of at least {minimum}")
    return result


def _nonnegative_integer(value: int, name: str) -> int:
    try:
        result = operator.index(value)
    except TypeError as exc:
        raise ValueError(f"{name} must be a non-negative integer") from exc
    if isinstance(value, bool) or result < 0:
        raise ValueError(f"{name} must be a non-negative integer")
    return result


def _sampling(time: npt.NDArray[Any], *, rtol: float, atol: float) -> float:
    if time.ndim != 1 or time.size < 2 or not np.all(np.isfinite(time)):
        raise ValueError("spectral analysis requires at least two finite time samples")
    intervals = np.diff(time)
    if np.any(intervals <= 0.0):
        raise ValueError("spectral analysis requires strictly increasing time")
    dt = float(np.median(intervals))
    if not np.allclose(intervals, dt, rtol=rtol, atol=atol):
        maximum = float(np.max(np.abs(intervals - dt)))
        raise ValueError(
            "spectral analysis requires uniform sampling; "
            f"maximum time-step deviation is {maximum:.6g} s"
        )
    return dt


def _window_name(name: str) -> str:
    """Return the canonical window name (``"hann"`` or ``"boxcar"``) of an alias."""
    if not isinstance(name, str):
        raise ValueError("window must be 'hann' or 'boxcar'")
    normalized = name.lower().replace("-", "_")
    if normalized in {"hann", "hann_periodic"}:
        return "hann"
    if normalized in {"boxcar", "rectangular"}:
        return "boxcar"
    raise ValueError("window must be 'hann' or 'boxcar'")


def _window(name: str, length: int) -> npt.NDArray[Any]:
    if _window_name(name) == "hann":
        # Periodic (DFT-even) Hann, matching the current scipy.signal.welch default.
        return np.hanning(length + 1)[:-1]
    return np.ones(length, dtype=np.float64)


def _squared_unit(unit: str | None) -> str | None:
    """Square an engineering unit without changing compound-unit precedence."""
    if unit is None:
        return None
    normalized = unit.strip()
    if normalized in {"", "-", "1"}:
        return "1"
    if normalized.isalpha():
        return f"{normalized}^2"
    return f"({normalized})^2"


@dataclass(frozen=True)
class _Welch:
    frequency: npt.NDArray[Any]
    auto_x: npt.NDArray[Any]
    auto_y: npt.NDArray[Any] | None
    cross_xy: npt.NDArray[Any] | None
    sample_interval: float
    sample_count: int
    segment_length: int
    overlap_samples: int
    fft_length: int
    segment_count: int
    window: str
    detrend: str


def _welch(
    time: npt.ArrayLike,
    x: npt.ArrayLike,
    *,
    y: npt.ArrayLike | None = None,
    segment_length: int,
    overlap: float,
    fft_length: int | None,
    window: str,
    detrend: str,
    uniform_rtol: float,
    uniform_atol: float,
) -> _Welch:
    time_array = np.asarray(time, dtype=np.float64)
    x_array = np.asarray(x, dtype=np.float64)
    if x_array.shape != time_array.shape or not np.all(np.isfinite(x_array)):
        raise ValueError("channel samples must be finite and match time")
    y_array = None if y is None else np.asarray(y, dtype=np.float64)
    if y_array is not None and (
        y_array.shape != time_array.shape or not np.all(np.isfinite(y_array))
    ):
        raise ValueError("second-channel samples must be finite and match time")
    for name, value in (("uniform_rtol", uniform_rtol), ("uniform_atol", uniform_atol)):
        if isinstance(value, bool) or not math.isfinite(float(value)) or float(value) < 0.0:
            raise ValueError(f"{name} must be finite and non-negative")
    dt = _sampling(time_array, rtol=float(uniform_rtol), atol=float(uniform_atol))
    nperseg = _positive_integer(segment_length, "segment_length", minimum=2)
    if nperseg > time_array.size:
        raise ValueError("segment_length must not exceed the selected sample count")
    if isinstance(overlap, bool) or not math.isfinite(float(overlap)):
        raise ValueError("overlap must be a finite fraction in [0, 1)")
    overlap_fraction = float(overlap)
    if overlap_fraction < 0.0 or overlap_fraction >= 1.0:
        raise ValueError("overlap must be a finite fraction in [0, 1)")
    noverlap = math.floor(overlap_fraction * nperseg)
    step = nperseg - noverlap
    nfft = (
        nperseg
        if fft_length is None
        else _positive_integer(
            fft_length,
            "fft_length",
            minimum=nperseg,
        )
    )
    if not isinstance(detrend, str):
        raise ValueError("detrend must be 'constant' or 'none'")
    detrend_name = detrend.lower()
    if detrend_name not in {"constant", "none"}:
        raise ValueError("detrend must be 'constant' or 'none'")
    weights = _window(window, nperseg)
    window_power = float(np.dot(weights, weights))
    if window_power <= 0.0:
        raise ValueError("window has zero power")
    starts = range(0, time_array.size - nperseg + 1, step)
    pxx = np.zeros(nfft // 2 + 1, dtype=np.float64)
    pyy = np.zeros_like(pxx) if y_array is not None else None
    pxy = np.zeros(pxx.shape, dtype=np.complex128) if y_array is not None else None
    count = 0
    scale = 1.0 / ((1.0 / dt) * window_power)
    one_sided = np.ones(pxx.shape, dtype=np.float64)
    if nfft % 2 == 0:
        one_sided[1:-1] = 2.0
    else:
        one_sided[1:] = 2.0
    for start in starts:
        xs = x_array[start : start + nperseg].copy()
        if detrend_name == "constant":
            xs -= np.mean(xs)
        xf = np.fft.rfft(xs * weights, n=nfft)
        pxx += one_sided * scale * np.abs(xf) ** 2
        if y_array is not None and pyy is not None and pxy is not None:
            ys = y_array[start : start + nperseg].copy()
            if detrend_name == "constant":
                ys -= np.mean(ys)
            yf = np.fft.rfft(ys * weights, n=nfft)
            pyy += one_sided * scale * np.abs(yf) ** 2
            # Pxy convention follows scipy.signal.csd: conjugate(X) * Y.
            pxy += one_sided * scale * np.conjugate(xf) * yf
        count += 1
    pxx /= count
    if pyy is not None and pxy is not None:
        pyy /= count
        pxy /= count
    if (
        not np.all(np.isfinite(pxx))
        or (pyy is not None and not np.all(np.isfinite(pyy)))
        or (pxy is not None and not np.all(np.isfinite(pxy)))
    ):
        raise ValueError("Welch accumulation overflowed; scale the channel values")
    return _Welch(
        frequency=_readonly(np.fft.rfftfreq(nfft, d=dt)),
        auto_x=_readonly(pxx),
        auto_y=None if pyy is None else _readonly(pyy),
        cross_xy=None if pxy is None else _readonly(pxy, dtype=np.complex128),
        sample_interval=dt,
        sample_count=int(time_array.size),
        segment_length=nperseg,
        overlap_samples=noverlap,
        fft_length=nfft,
        segment_count=count,
        window=_window_name(window),
        detrend=detrend_name,
    )


def _atomic_csv(
    target: Path,
    source: Path,
    header: tuple[str, ...],
    rows: Iterable[Iterable[str]],
    *,
    overwrite: bool,
) -> Path:
    target = target.expanduser().resolve()
    if target == source.expanduser().resolve():
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
            writer.writerow(header)
            writer.writerows(rows)
        os.replace(temporary, target)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)
        raise
    return target


def _validate_welch_metadata(value: Any, *, require_multiple_segments: bool = False) -> None:
    """Normalize and cross-check metadata shared by public spectral results."""
    for name in ("start_time", "end_time", "sample_interval"):
        raw = getattr(value, name)
        number = float(raw)
        if isinstance(raw, bool) or not math.isfinite(number):
            raise ValueError(f"{name} must be finite")
        object.__setattr__(value, name, number)
    if value.sample_interval <= 0.0 or value.end_time <= value.start_time:
        raise ValueError("sample_interval must be positive and end_time must follow start_time")
    sample_count = _positive_integer(value.sample_count, "sample_count", minimum=2)
    segment_length = _positive_integer(value.segment_length, "segment_length", minimum=2)
    overlap_samples = _nonnegative_integer(value.overlap_samples, "overlap_samples")
    fft_length = _positive_integer(value.fft_length, "fft_length", minimum=segment_length)
    segment_count = _positive_integer(value.segment_count, "segment_count")
    if segment_length > sample_count or overlap_samples >= segment_length:
        raise ValueError("Welch segment/overlap metadata is inconsistent")
    expected_segments = 1 + (sample_count - segment_length) // (segment_length - overlap_samples)
    if segment_count != expected_segments:
        raise ValueError("segment_count is inconsistent with sample/segment metadata")
    if require_multiple_segments and segment_count < 2:
        raise ValueError("coherence requires at least two complete Welch segments")
    for name in ("uniform_rtol", "uniform_atol"):
        raw = getattr(value, name)
        tolerance = float(raw)
        if isinstance(raw, bool) or not math.isfinite(tolerance) or tolerance < 0.0:
            raise ValueError(f"{name} must be finite and non-negative")
        object.__setattr__(value, name, tolerance)
    duration = (sample_count - 1) * value.sample_interval
    if not math.isclose(
        value.end_time - value.start_time,
        duration,
        rel_tol=value.uniform_rtol,
        abs_tol=(sample_count - 1) * value.uniform_atol,
    ):
        raise ValueError("start/end times are inconsistent with uniform sampling metadata")
    _window(value.window, segment_length)
    if not isinstance(value.detrend, str) or value.detrend.lower() not in {"constant", "none"}:
        raise ValueError("detrend must be 'constant' or 'none'")
    for name, normalized in (
        ("sample_count", sample_count),
        ("segment_length", segment_length),
        ("overlap_samples", overlap_samples),
        ("fft_length", fft_length),
        ("segment_count", segment_count),
        ("window", value.window.lower()),
        ("detrend", value.detrend.lower()),
    ):
        object.__setattr__(value, name, normalized)


@dataclass(frozen=True)
class SpectralPeak:
    """A bin-centred local maximum; no sub-bin interpolation is implied.

    Attributes
    ----------
    index : int
        Zero-based index of the peak bin in the spectrum arrays.
    frequency : float
        Centre frequency of the peak bin, in Hz.
    density : float
        Power spectral density in the peak bin, in the spectrum's density unit.
    """

    index: int
    frequency: float
    density: float

    def __post_init__(self) -> None:
        try:
            index = operator.index(self.index)
        except TypeError as exc:
            raise ValueError("index must be a non-negative integer") from exc
        if isinstance(self.index, bool) or index < 0:
            raise ValueError("index must be a non-negative integer")
        frequency, density = float(self.frequency), float(self.density)
        if (
            not math.isfinite(frequency)
            or not math.isfinite(density)
            or frequency < 0.0
            or density < 0.0
        ):
            raise ValueError("peak frequency and density must be finite and non-negative")
        object.__setattr__(self, "index", index)
        object.__setattr__(self, "frequency", frequency)
        object.__setattr__(self, "density", density)

    @property
    def period(self) -> float:
        """Bin-centred period in seconds, or infinity for the DC bin."""
        return math.inf if self.frequency == 0.0 else 1.0 / self.frequency


@dataclass(frozen=True)
class PowerSpectrum:
    """One-sided Welch power spectral density for one uniformly sampled channel.

    Usually obtained from :meth:`cabledyn.TimeHistory.spectrum` or
    :func:`cabledyn.power_spectrum`. The density is scaled so that integrating
    it over frequency recovers the mean-square value of the detrended signal.

    Attributes
    ----------
    channel : str
        Name of the analysed channel.
    source : pathlib.Path
        Absolute path of the result file the channel was read from.
    unit : str | None
        Engineering unit of the channel, or ``None`` if unknown.
    start_time : float
        Time of the first analysed sample, in seconds.
    end_time : float
        Time of the last analysed sample, in seconds.
    sample_interval : float
        Uniform sample interval, in seconds.
    sample_count : int
        Number of samples in the analysed record.
    segment_length : int
        Number of samples in each Welch segment.
    overlap_samples : int
        Number of samples shared by consecutive segments.
    fft_length : int
        FFT length; larger than ``segment_length`` when segments are zero-padded.
    segment_count : int
        Number of complete segments averaged.
    window : str
        Segment window, ``"hann"`` or ``"boxcar"``.
    detrend : str
        Per-segment detrending, ``"constant"`` (mean removal) or ``"none"``.
    uniform_rtol : float
        Relative tolerance used to accept the sample times as uniform.
    uniform_atol : float
        Absolute tolerance used to accept the sample times as uniform, in seconds.
    frequency : numpy.ndarray
        Read-only bin frequencies from 0 Hz to the Nyquist frequency, in Hz.
    density : numpy.ndarray
        Read-only one-sided power spectral density in each bin, in
        :attr:`density_unit`.
    """

    channel: str
    source: Path
    unit: str | None
    start_time: float
    end_time: float
    sample_interval: float
    sample_count: int
    segment_length: int
    overlap_samples: int
    fft_length: int
    segment_count: int
    window: str
    detrend: str
    uniform_rtol: float
    uniform_atol: float
    frequency: npt.NDArray[Any]
    density: npt.NDArray[Any]

    def __post_init__(self) -> None:
        if not isinstance(self.channel, str) or not self.channel:
            raise ValueError("channel must be a non-empty string")
        if self.unit is not None and not isinstance(self.unit, str):
            raise ValueError("unit must be a string or None")
        object.__setattr__(self, "source", Path(self.source).expanduser().resolve())
        _validate_welch_metadata(self)
        frequency = _readonly(self.frequency)
        density = _readonly(self.density)
        if frequency.ndim != 1 or frequency.shape != density.shape or frequency.size < 2:
            raise ValueError("frequency and density must be matching one-dimensional arrays")
        if (
            not np.all(np.isfinite(frequency))
            or not np.all(np.isfinite(density))
            or np.any(frequency < 0.0)
            or np.any(np.diff(frequency) <= 0.0)
            or np.any(density < 0.0)
        ):
            raise ValueError("spectrum frequencies/densities must be finite and non-negative")
        object.__setattr__(self, "frequency", frequency)
        object.__setattr__(self, "density", density)
        expected_frequency = np.fft.rfftfreq(self.fft_length, d=self.sample_interval)
        if frequency.shape != expected_frequency.shape or not np.allclose(
            frequency,
            expected_frequency,
            rtol=1.0e-12,
            atol=0.0,
        ):
            raise ValueError("frequency bins are inconsistent with FFT metadata")

    @property
    def density_unit(self) -> str | None:
        """Unit of :attr:`density`, for example ``N^2/Hz``, or ``None`` if unknown."""
        squared = _squared_unit(self.unit)
        return None if squared is None else f"{squared}/Hz"

    @property
    def frequency_resolution(self) -> float:
        """Spacing between adjacent frequency bins, in Hz."""
        return float(self.frequency[1] - self.frequency[0])

    def moment_unit(self, order: float) -> str | None:
        """Return the engineering unit of a spectral moment of ``order``.

        Parameters
        ----------
        order : float
            Finite moment order.

        Returns
        -------
        str | None
            The squared channel unit times ``Hz^order`` (for example
            ``"N^2*Hz^2"``), or ``None`` when the channel unit is unknown.

        Raises
        ------
        ValueError
            If ``order`` is not finite.
        """
        if isinstance(order, bool) or not math.isfinite(float(order)):
            raise ValueError("spectral-moment order must be finite")
        if self.unit is None:
            return None
        squared = _squared_unit(self.unit)
        if float(order) == 0.0:
            return squared
        if squared == "1":
            return f"Hz^{float(order):g}"
        return f"{squared}*Hz^{float(order):g}"

    def moment(
        self,
        order: float,
        *,
        minimum_frequency: float | None = None,
        maximum_frequency: float | None = None,
    ) -> float:
        """Integrate ``f**order * PSD`` over an explicit closed frequency band.

        Parameters
        ----------
        order : float
            Moment order. Over the full band, the zeroth moment estimates the
            variance of the signal (its mean square when ``detrend="none"``).
        minimum_frequency, maximum_frequency : float | None
            Closed band limits in Hz. ``None`` selects the first or last bin.

        Returns
        -------
        float
            The spectral moment, in :meth:`moment_unit` units.

        Raises
        ------
        ValueError
            If the band holds fewer than two bins, the limits are not finite,
            non-negative, and ordered, or a negative order would include 0 Hz.
        """
        if isinstance(order, bool) or not math.isfinite(float(order)):
            raise ValueError("spectral-moment order must be finite")
        lower = self.frequency[0] if minimum_frequency is None else float(minimum_frequency)
        upper = self.frequency[-1] if maximum_frequency is None else float(maximum_frequency)
        if not math.isfinite(lower) or not math.isfinite(upper) or lower < 0.0 or lower > upper:
            raise ValueError("frequency bounds must be finite, non-negative, and ordered")
        mask = (self.frequency >= lower) & (self.frequency <= upper)
        if np.count_nonzero(mask) < 2:
            raise ValueError("spectral-moment band must contain at least two frequency bins")
        f = self.frequency[mask]
        if float(order) < 0.0 and f[0] == 0.0:
            raise ValueError("negative-order moments cannot include the zero-frequency bin")
        integrand = np.power(f, float(order)) * self.density[mask]
        # Welch bins represent density over full bins, including DC and Nyquist.
        # Full-bin rectangle weights preserve discrete mean-square power.
        return float(np.sum(integrand) * self.frequency_resolution)

    def dominant_peaks(
        self,
        count: int = 1,
        *,
        minimum_frequency: float = 0.0,
        maximum_frequency: float | None = None,
        include_dc: bool = False,
    ) -> tuple[SpectralPeak, ...]:
        """Return the strongest local-maxima bins, ordered by decreasing density.

        A flat-topped maximum spanning several equal bins counts as one peak,
        reported at its lowest-frequency bin.

        Parameters
        ----------
        count : int
            Maximum number of peaks to return.
        minimum_frequency, maximum_frequency : float | None
            Closed search band in Hz. ``maximum_frequency=None`` searches up to
            the Nyquist frequency.
        include_dc : bool
            Whether the 0 Hz bin may be reported as a peak.

        Returns
        -------
        tuple[SpectralPeak, ...]
            At most ``count`` peaks; empty if the band has no local maximum.
        """
        wanted = _positive_integer(count, "count")
        lower = float(minimum_frequency)
        upper = self.frequency[-1] if maximum_frequency is None else float(maximum_frequency)
        if not math.isfinite(lower) or not math.isfinite(upper) or lower < 0.0 or lower > upper:
            raise ValueError("frequency bounds must be finite, non-negative, and ordered")
        candidates: list[int] = []
        size = self.density.size
        for index, value in enumerate(self.density):
            if self.frequency[index] < lower or self.frequency[index] > upper:
                continue
            if index == 0 and not include_dc:
                continue
            if value <= 0.0:
                continue
            # A flat-topped maximum spanning several equal bins is one peak,
            # reported at its lowest-frequency bin.
            if index > 0 and value <= self.density[index - 1]:
                continue
            end = index
            while end + 1 < size and self.density[end + 1] == value:
                end += 1
            descends = end + 1 == size or self.density[end + 1] < value
            if descends and (index > 0 or end + 1 < size):
                candidates.append(index)
        candidates.sort(key=lambda index: (-self.density[index], self.frequency[index]))
        return tuple(
            SpectralPeak(index, float(self.frequency[index]), float(self.density[index]))
            for index in candidates[:wanted]
        )

    def export(self, path: str | os.PathLike[str], *, overwrite: bool = False) -> Path:
        """Atomically write the spectrum to a CSV file.

        The file has a ``frequency_[Hz]`` column and a ``PSD`` column whose header
        carries :attr:`density_unit`. Values are written with 17 significant digits.

        Parameters
        ----------
        path : str | os.PathLike
            Target file. Missing parent directories are created.
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
            If ``path`` is the source result file.
        """
        suffix = f"_[{self.density_unit}]" if self.density_unit else ""
        rows = (
            (f"{f:.17g}", f"{p:.17g}") for f, p in zip(self.frequency, self.density, strict=True)
        )
        return _atomic_csv(
            Path(path), self.source, ("frequency_[Hz]", f"PSD{suffix}"), rows, overwrite=overwrite
        )

    def plot(self, *, ax: Any = None, logarithmic: bool = False) -> Any:
        """Plot the density against frequency using optional matplotlib.

        Parameters
        ----------
        ax : matplotlib.axes.Axes | None
            Axes to draw on; a new figure is created when omitted.
        logarithmic : bool
            Use a logarithmic density axis.

        Returns
        -------
        matplotlib.axes.Axes
            The axes drawn on.
        """
        plt = pyplot()
        if ax is None:
            _, ax = plt.subplots()
        plot = ax.semilogy if logarithmic else ax.plot
        plot(self.frequency, self.density)
        ax.set_xlabel("Frequency [Hz]")
        label = "Power spectral density"
        if self.density_unit:
            label += f" [{self.density_unit}]"
        ax.set_ylabel(label)
        ax.grid(True)
        return ax


@dataclass(frozen=True)
class CoherenceResult:
    """Magnitude-squared Welch coherence with an explicit valid-bin mask.

    Usually obtained from :meth:`cabledyn.TimeHistory.coherence` or
    :func:`cabledyn.magnitude_squared_coherence`. Bins in which either
    auto-spectrum falls below ``power_floor_ratio`` times its maximum carry no
    reliable phase information; they are marked invalid and hold NaN.

    Attributes
    ----------
    channel_x : str
        Name of the first analysed channel.
    channel_y : str
        Name of the second analysed channel.
    source : pathlib.Path
        Absolute path of the result file the channels were read from.
    start_time : float
        Time of the first analysed sample, in seconds.
    end_time : float
        Time of the last analysed sample, in seconds.
    sample_interval : float
        Uniform sample interval, in seconds.
    sample_count : int
        Number of samples in the analysed record.
    segment_length : int
        Number of samples in each Welch segment.
    overlap_samples : int
        Number of samples shared by consecutive segments.
    fft_length : int
        FFT length; larger than ``segment_length`` when segments are zero-padded.
    segment_count : int
        Number of complete segments averaged; at least two.
    window : str
        Segment window, ``"hann"`` or ``"boxcar"``.
    detrend : str
        Per-segment detrending, ``"constant"`` (mean removal) or ``"none"``.
    uniform_rtol : float
        Relative tolerance used to accept the sample times as uniform.
    uniform_atol : float
        Absolute tolerance used to accept the sample times as uniform, in seconds.
    power_floor_ratio : float
        Relative auto-spectrum floor that defines valid bins, in ``[0, 1)``.
    frequency : numpy.ndarray
        Read-only bin frequencies, in Hz.
    coherence : numpy.ndarray
        Read-only magnitude-squared coherence in ``[0, 1]``; NaN in invalid bins.
    valid : numpy.ndarray
        Read-only Boolean mask of the bins whose coherence is defined.
    """

    channel_x: str
    channel_y: str
    source: Path
    start_time: float
    end_time: float
    sample_interval: float
    sample_count: int
    segment_length: int
    overlap_samples: int
    fft_length: int
    segment_count: int
    window: str
    detrend: str
    uniform_rtol: float
    uniform_atol: float
    power_floor_ratio: float
    frequency: npt.NDArray[Any]
    coherence: npt.NDArray[Any]
    valid: npt.NDArray[Any]

    def __post_init__(self) -> None:
        if (
            not isinstance(self.channel_x, str)
            or not self.channel_x
            or not isinstance(self.channel_y, str)
            or not self.channel_y
            or self.channel_x == self.channel_y
        ):
            raise ValueError("coherence channels must be non-empty and distinct")
        object.__setattr__(self, "source", Path(self.source).expanduser().resolve())
        _validate_welch_metadata(self, require_multiple_segments=True)
        ratio = float(self.power_floor_ratio)
        if (
            isinstance(self.power_floor_ratio, bool)
            or not math.isfinite(ratio)
            or not 0.0 <= ratio < 1.0
        ):
            raise ValueError("power_floor_ratio must be finite and in [0, 1)")
        object.__setattr__(self, "power_floor_ratio", ratio)
        frequency = _readonly(self.frequency)
        coherence = _readonly(self.coherence)
        valid_input = np.asarray(self.valid)
        if valid_input.dtype.kind != "b":
            raise ValueError("valid must be a boolean array")
        valid = _readonly(valid_input, dtype=np.bool_)
        if (
            frequency.ndim != 1
            or frequency.shape != coherence.shape
            or frequency.shape != valid.shape
            or frequency.size < 2
        ):
            raise ValueError("frequency, coherence, and valid arrays must match")
        if not np.all(np.isfinite(frequency)) or np.any(np.diff(frequency) <= 0.0):
            raise ValueError("coherence frequencies must be finite and increasing")
        if (
            np.any(~np.isfinite(coherence[valid]))
            or np.any(coherence[valid] < 0.0)
            or np.any(coherence[valid] > 1.0)
        ):
            raise ValueError("valid coherence values must lie in [0, 1]")
        if not np.all(np.isnan(coherence[~valid])):
            raise ValueError("invalid coherence bins must be NaN")
        object.__setattr__(self, "frequency", frequency)
        object.__setattr__(self, "coherence", coherence)
        object.__setattr__(self, "valid", valid)
        expected_frequency = np.fft.rfftfreq(self.fft_length, d=self.sample_interval)
        if frequency.shape != expected_frequency.shape or not np.allclose(
            frequency,
            expected_frequency,
            rtol=1.0e-12,
            atol=0.0,
        ):
            raise ValueError("frequency bins are inconsistent with FFT metadata")

    def export(self, path: str | os.PathLike[str], *, overwrite: bool = False) -> Path:
        """Atomically write the coherence to a CSV file.

        The columns are ``frequency_[Hz]``, ``coherence_[-]`` (empty in invalid
        bins), and ``valid_[-]`` (``1`` or ``0``).

        Parameters
        ----------
        path : str | os.PathLike
            Target file. Missing parent directories are created.
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
            If ``path`` is the source result file.
        """
        rows = (
            (f"{f:.17g}", "" if not ok else f"{c:.17g}", "1" if ok else "0")
            for f, c, ok in zip(self.frequency, self.coherence, self.valid, strict=True)
        )
        return _atomic_csv(
            Path(path),
            self.source,
            ("frequency_[Hz]", "coherence_[-]", "valid_[-]"),
            rows,
            overwrite=overwrite,
        )

    def plot(self, *, ax: Any = None) -> Any:
        """Plot the coherence against frequency; invalid bins appear as gaps.

        Parameters
        ----------
        ax : matplotlib.axes.Axes | None
            Axes to draw on; a new figure is created when omitted.

        Returns
        -------
        matplotlib.axes.Axes
            The axes drawn on.
        """
        plt = pyplot()
        if ax is None:
            _, ax = plt.subplots()
        ax.plot(self.frequency, self.coherence)
        ax.set_xlabel("Frequency [Hz]")
        ax.set_ylabel("Magnitude-squared coherence [-]")
        ax.set_ylim(0.0, 1.0)
        ax.grid(True)
        return ax


def power_spectrum(
    time: npt.ArrayLike,
    values: npt.ArrayLike,
    *,
    channel: str,
    source: Path,
    unit: str | None,
    segment_length: int,
    overlap: float = 0.5,
    fft_length: int | None = None,
    window: str = "hann",
    detrend: str = "constant",
    uniform_rtol: float = 1.0e-6,
    uniform_atol: float = 0.0,
) -> PowerSpectrum:
    """Calculate an explicitly configured one-sided Welch PSD density.

    The record is split into segments of ``segment_length`` samples, each is
    detrended, windowed, and transformed, and the periodograms are averaged.
    Incomplete trailing samples are not used. The data are never resampled.

    Parameters
    ----------
    time : array_like
        Strictly increasing, uniformly spaced sample times, in seconds.
    values : array_like
        Finite channel samples, one per time.
    channel : str
        Channel name recorded in the result.
    source : pathlib.Path
        Result file the samples came from, recorded in the result.
    unit : str | None
        Channel unit, or ``None`` if unknown.
    segment_length : int
        Samples per Welch segment; at least 2 and at most the sample count.
    overlap : float
        Fraction of a segment shared with the next, in ``[0, 1)``.
    fft_length : int | None
        FFT length; ``None`` uses ``segment_length``. A longer length zero-pads
        each segment.
    window : str
        ``"hann"`` (periodic Hann) or ``"boxcar"``.
    detrend : str
        ``"constant"`` removes each segment's mean; ``"none"`` keeps it.
    uniform_rtol, uniform_atol : float
        Relative and absolute tolerances for accepting the time steps as uniform.

    Returns
    -------
    PowerSpectrum
        The spectrum and the settings that produced it.

    Raises
    ------
    ValueError
        If the samples are not finite, uniformly sampled, and strictly increasing
        in time, or a setting is out of range.
    """
    result = _welch(
        time,
        values,
        segment_length=segment_length,
        overlap=overlap,
        fft_length=fft_length,
        window=window,
        detrend=detrend,
        uniform_rtol=uniform_rtol,
        uniform_atol=uniform_atol,
    )
    time_array = np.asarray(time, dtype=np.float64)
    return PowerSpectrum(
        channel=channel,
        source=source,
        unit=unit,
        start_time=float(time_array[0]),
        end_time=float(time_array[-1]),
        sample_interval=result.sample_interval,
        sample_count=result.sample_count,
        segment_length=result.segment_length,
        overlap_samples=result.overlap_samples,
        fft_length=result.fft_length,
        segment_count=result.segment_count,
        window=result.window,
        detrend=result.detrend,
        uniform_rtol=float(uniform_rtol),
        uniform_atol=float(uniform_atol),
        frequency=result.frequency,
        density=result.auto_x,
    )


def magnitude_squared_coherence(
    time: npt.ArrayLike,
    x: npt.ArrayLike,
    y: npt.ArrayLike,
    *,
    channel_x: str,
    channel_y: str,
    source: Path,
    segment_length: int,
    overlap: float = 0.5,
    fft_length: int | None = None,
    window: str = "hann",
    detrend: str = "constant",
    power_floor_ratio: float = DEFAULT_POWER_FLOOR_RATIO,
    uniform_rtol: float = 1.0e-6,
    uniform_atol: float = 0.0,
) -> CoherenceResult:
    """Calculate Welch magnitude-squared coherence without asserting zero-power bins.

    Uses the same segmenting and windowing as :func:`power_spectrum`. At least
    two complete segments are required, because a single segment always gives
    a coherence of one.

    Parameters
    ----------
    time : array_like
        Strictly increasing, uniformly spaced sample times, in seconds.
    x, y : array_like
        Finite samples of the two channels, one per time.
    channel_x, channel_y : str
        Distinct channel names recorded in the result.
    source : pathlib.Path
        Result file the samples came from, recorded in the result.
    segment_length : int
        Samples per Welch segment.
    overlap : float
        Fraction of a segment shared with the next, in ``[0, 1)``.
    fft_length : int | None
        FFT length; ``None`` uses ``segment_length``.
    window : str
        ``"hann"`` (periodic Hann) or ``"boxcar"``.
    detrend : str
        ``"constant"`` removes each segment's mean; ``"none"`` keeps it.
    power_floor_ratio : float
        A bin is valid only where both auto-spectra exceed this fraction of their
        maxima. Must lie in ``[0, 1)``.
    uniform_rtol, uniform_atol : float
        Relative and absolute tolerances for accepting the time steps as uniform.

    Returns
    -------
    CoherenceResult
        The coherence, its valid-bin mask, and the settings that produced it.

    Raises
    ------
    ValueError
        If the samples are not uniformly sampled, fewer than two segments fit, or
        a setting is out of range.
    """
    if (
        isinstance(power_floor_ratio, bool)
        or not math.isfinite(float(power_floor_ratio))
        or not 0.0 <= float(power_floor_ratio) < 1.0
    ):
        raise ValueError("power_floor_ratio must be finite and in [0, 1)")
    result = _welch(
        time,
        x,
        y=y,
        segment_length=segment_length,
        overlap=overlap,
        fft_length=fft_length,
        window=window,
        detrend=detrend,
        uniform_rtol=uniform_rtol,
        uniform_atol=uniform_atol,
    )
    if result.segment_count < 2:
        raise ValueError("coherence requires at least two complete Welch segments")
    assert result.auto_y is not None and result.cross_xy is not None
    floor_x = float(power_floor_ratio) * float(np.max(result.auto_x))
    floor_y = float(power_floor_ratio) * float(np.max(result.auto_y))
    valid = (result.auto_x > floor_x) & (result.auto_y > floor_y)
    coherence = np.full(result.frequency.shape, np.nan, dtype=np.float64)
    # Divide before squaring to avoid overflow/underflow in Pxx*Pyy.
    normalized_cross = (
        np.abs(result.cross_xy[valid])
        / np.sqrt(result.auto_x[valid])
        / np.sqrt(result.auto_y[valid])
    )
    coherence[valid] = np.clip(normalized_cross**2, 0.0, 1.0)
    time_array = np.asarray(time, dtype=np.float64)
    return CoherenceResult(
        channel_x=channel_x,
        channel_y=channel_y,
        source=source,
        start_time=float(time_array[0]),
        end_time=float(time_array[-1]),
        sample_interval=result.sample_interval,
        sample_count=result.sample_count,
        segment_length=result.segment_length,
        overlap_samples=result.overlap_samples,
        fft_length=result.fft_length,
        segment_count=result.segment_count,
        window=result.window,
        detrend=result.detrend,
        uniform_rtol=float(uniform_rtol),
        uniform_atol=float(uniform_atol),
        power_floor_ratio=float(power_floor_ratio),
        frequency=result.frequency,
        coherence=coherence,
        valid=valid,
    )
