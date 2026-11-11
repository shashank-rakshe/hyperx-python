# SPDX-License-Identifier: Apache-2.0
"""Typed CableDyn result tables, engineering summaries, and exports."""

from __future__ import annotations

import contextlib
import csv
import operator
import os
import re
import tempfile
import warnings
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Any

import numpy as np
import numpy.typing as npt

from cabledyn._optional import pyplot
from cabledyn._paths import windows_device_component
from cabledyn.errors import OutputFormatError
from cabledyn.spectra import DEFAULT_POWER_FLOOR_RATIO

if TYPE_CHECKING:
    from cabledyn.fatigue import FatigueResult
    from cabledyn.spectra import CoherenceResult, PowerSpectrum


def _clean_unit(unit: str) -> str:
    unit = unit.strip()
    if len(unit) >= 2 and unit[0] in "([" and unit[-1] in ")]":
        unit = unit[1:-1]
    return unit


def _label(channel: str, unit: str | None) -> str:
    """Return the conventional ``Name_[unit]`` label used by pyDatView."""
    if unit is not None:
        match = re.fullmatch(r"(.+?)\(([^()]*)\)", channel)
        name = match.group(1) if match else channel
        return f"{name}_[{_clean_unit(unit)}]"
    match = re.fullmatch(r"(.+?)\(([^()]*)\)", channel)
    if match:
        return f"{match.group(1)}_[{match.group(2)}]"
    return channel


def _native_channel_unit(channel: str) -> str | None:
    """Infer units for native main-output channels whose names are verbatim.

    Ids may carry leading zeros (``Ten01N01``), as the native channel parser accepts.
    """
    patterns = (
        (r"(?:FairTen|AnchTen|AnchFz|AnchFH)0*[1-9][0-9]*", "N"),
        (r"(?:FairIncl|AnchIncl|FairDecl|AnchDecl|FairAngle|AnchAngle)0*[1-9][0-9]*", "deg"),
        (r"Ten0*[1-9][0-9]*N0*[1-9][0-9]*", "N"),
        (r"Curv0*[1-9][0-9]*N0*[1-9][0-9]*", "1/m"),
        (r"BendMom0*[1-9][0-9]*N0*[1-9][0-9]*", "N-m"),
        (r"Torq0*[1-9][0-9]*N0*[1-9][0-9]*", "N-m"),
        (r"Twist0*[1-9][0-9]*(?:N0*[1-9][0-9]*)?", "deg"),
        (r"L0*[1-9][0-9]*N0*[1-9][0-9]*p[xyz]", "m"),
        (r"L0*[1-9][0-9]*N0*[1-9][0-9]*v[xyz]", "m/s"),
        (r"L0*[1-9][0-9]*N0*[1-9][0-9]*a[xyz]", "m/s^2"),
        (r"L0*[1-9][0-9]*N0*[1-9][0-9]*(?:Dec|Azi)", "deg"),
        (r"(?:Point|Con)0*[1-9][0-9]*p[xyz]", "m"),
    )
    for pattern, unit in patterns:
        if re.fullmatch(pattern, channel, flags=re.IGNORECASE):
            return unit
    return None


@dataclass(frozen=True)
class ChannelStatistics:
    """Population statistics for one time-history channel.

    Attributes
    ----------
    channel : str
        Channel name.
    unit : str | None
        Channel unit, or ``None`` if unknown.
    count : int
        Number of samples summarized.
    minimum : float
        Smallest sample.
    maximum : float
        Largest sample.
    mean : float
        Arithmetic mean.
    standard_deviation : float
        Population standard deviation (divisor ``count``).
    rms : float
        Root-mean-square value.
    """

    channel: str
    unit: str | None
    count: int
    minimum: float
    maximum: float
    mean: float
    standard_deviation: float
    rms: float


@dataclass(frozen=True)
class StaticLineSummary:
    """Engineering summary of one line in a static profile.

    Extrema of columns that the profile does not contain are ``None``.

    Attributes
    ----------
    line_id : int
        Line identifier.
    node_count : int
        Number of profile rows (nodes) for the line.
    deformed_length : float
        Arc length at the last node, in metres.
    minimum_tension : float | None
        Smallest tension, in newtons.
    maximum_tension : float | None
        Largest tension, in newtons.
    maximum_curvature : float | None
        Largest curvature, in 1/m.
    minimum_bend_radius : float | None
        Reciprocal of ``maximum_curvature``, in metres; infinite for a line with
        zero curvature everywhere.
    maximum_bend_moment : float | None
        Largest absolute bending moment, in N-m.
    """

    line_id: int
    node_count: int
    deformed_length: float
    minimum_tension: float | None
    maximum_tension: float | None
    maximum_curvature: float | None
    minimum_bend_radius: float | None
    maximum_bend_moment: float | None


@dataclass(frozen=True)
class SpatialStatistics:
    """Population statistics at every node or segment of a line history.

    Each array holds one value per location, in the order of ``location_ids``.

    Attributes
    ----------
    location_kind : str
        Kind of location, for example ``"Segment"``.
    location_ids : numpy.ndarray
        Read-only, strictly increasing one-based location identifiers.
    quantity : str
        Summarized quantity, for example ``"Tension"``.
    unit : str | None
        Unit of the quantity, or ``None`` if unknown.
    count : int
        Number of time samples summarized.
    minimum : numpy.ndarray
        Smallest value at each location.
    maximum : numpy.ndarray
        Largest value at each location.
    mean : numpy.ndarray
        Arithmetic mean at each location.
    standard_deviation : numpy.ndarray
        Population standard deviation at each location.
    rms : numpy.ndarray
        Root-mean-square value at each location.
    """

    location_kind: str
    location_ids: npt.NDArray[Any]
    quantity: str
    unit: str | None
    count: int
    minimum: npt.NDArray[Any]
    maximum: npt.NDArray[Any]
    mean: npt.NDArray[Any]
    standard_deviation: npt.NDArray[Any]
    rms: npt.NDArray[Any]

    def __post_init__(self) -> None:
        if not self.location_kind or not self.quantity:
            raise ValueError("location_kind and quantity must be non-empty")
        try:
            count = operator.index(self.count)
        except TypeError as exc:
            raise ValueError("count must be a positive integer") from exc
        if isinstance(self.count, bool) or count <= 0:
            raise ValueError("count must be a positive integer")
        object.__setattr__(self, "count", count)
        location_ids = np.asarray(self.location_ids, dtype=np.int64).copy()
        if location_ids.ndim != 1 or location_ids.size == 0:
            raise ValueError("location_ids must be a non-empty one-dimensional array")
        if np.any(location_ids <= 0) or np.any(np.diff(location_ids) <= 0):
            raise ValueError("location_ids must be positive and strictly increasing")
        location_ids.setflags(write=False)
        object.__setattr__(self, "location_ids", location_ids)
        for name in ("minimum", "maximum", "mean", "standard_deviation", "rms"):
            values = np.asarray(getattr(self, name), dtype=np.float64).copy()
            if values.shape != location_ids.shape or not np.all(np.isfinite(values)):
                raise ValueError(f"{name} must be finite and match location_ids")
            values.setflags(write=False)
            object.__setattr__(self, name, values)
        if np.any(self.minimum > self.maximum):
            raise ValueError("minimum must not exceed maximum")
        if np.any(self.standard_deviation < 0.0) or np.any(self.rms < 0.0):
            raise ValueError("standard_deviation and rms must be non-negative")


@dataclass(frozen=True)
class OutputTable:
    """A validated CableDyn/OpenFAST-style numeric table.

    Instances are normally created by :func:`cabledyn.read_output`, which
    returns a more specific subclass when the table layout is recognized.

    Attributes
    ----------
    path : pathlib.Path
        Absolute path of the source file.
    title : str
        Free-text lines that precede the column header, joined by newlines.
    channels : tuple[str, ...]
        Column names, in file order.
    units : tuple[str, ...] | None
        Raw units row, one entry per channel, or ``None`` when the file has no
        units row. Use :meth:`unit` for a normalized unit of one channel.
    values : numpy.ndarray
        Read-only ``(n_rows, n_channels)`` array of finite values, each column
        in its channel's unit (SI: N, m, s, deg, and so on).

    Raises
    ------
    ValueError
        If ``values`` is not a finite 2-D array with one column per channel,
        or ``units`` does not match ``channels``.
    """

    path: Path
    title: str
    channels: tuple[str, ...]
    units: tuple[str, ...] | None
    values: npt.NDArray[Any]

    def __post_init__(self) -> None:
        values = np.array(self.values, dtype=np.float64, copy=True)
        if values.ndim != 2 or values.shape[1] != len(self.channels):
            raise ValueError("values must be a 2-D array matching channels")
        if self.units is not None and len(self.units) != len(self.channels):
            raise ValueError("units must match channels")
        if not np.all(np.isfinite(values)):
            raise ValueError("values must be finite")
        values.setflags(write=False)
        object.__setattr__(self, "path", Path(self.path).expanduser().resolve())
        object.__setattr__(self, "channels", tuple(self.channels))
        object.__setattr__(self, "units", tuple(self.units) if self.units is not None else None)
        object.__setattr__(self, "values", values)

    def column(self, channel: str) -> npt.NDArray[Any]:
        """Return a read-only view of one named channel.

        Parameters
        ----------
        channel : str
            Channel name exactly as it appears in :attr:`channels`. When a file
            repeats a channel name, the readers keep every column and rename the
            repeats ``<name>_2``, ``<name>_3``, ...; ``column(name)`` then returns
            the first occurrence.

        Returns
        -------
        numpy.ndarray
            Read-only ``(n_rows,)`` view of the channel, in the channel's unit
            (see :meth:`unit`).

        Raises
        ------
        KeyError
            If the table has no channel of that name.
        """
        try:
            index = self.channels.index(channel)
        except ValueError as exc:
            raise KeyError(
                f"{channel!r} is not in {self.path.name}; available: {', '.join(self.channels)}"
            ) from exc
        return self.values[:, index]

    def unit(self, channel: str) -> str | None:
        """Return a normalized unit string, or ``None`` if none was recorded.

        Surrounding brackets are removed. Without a units row, the unit is taken
        from a ``Name(unit)`` channel name or, for native main-output channels
        such as ``FairTen1``, from the channel's documented unit.

        Parameters
        ----------
        channel : str
            Channel name exactly as it appears in :attr:`channels`.

        Returns
        -------
        str | None
            Unit string such as ``"N"``, ``"m"``, or ``"deg"``, or ``None`` if
            the unit cannot be determined.

        Raises
        ------
        KeyError
            If the table has no channel of that name.
        """
        try:
            index = self.channels.index(channel)
        except ValueError as exc:
            raise KeyError(
                f"{channel!r} is not in {self.path.name}; available: {', '.join(self.channels)}"
            ) from exc
        if self.units is None:
            match = re.fullmatch(r".+?\(([^()]*)\)", channel)
            return match.group(1) if match else _native_channel_unit(channel)
        return _clean_unit(self.units[index])

    def to_dataframe(self, *, units_in_columns: bool = True) -> Any:
        """Return a pandas DataFrame without making pandas a base dependency.

        Parameters
        ----------
        units_in_columns : bool
            Label columns ``Name_[unit]`` when a unit is known; otherwise use
            the bare channel names.

        Returns
        -------
        pandas.DataFrame
            A copy of :attr:`values`, shape ``(n_rows, n_channels)``, with one
            column per channel.

        Raises
        ------
        ImportError
            If pandas is not installed.
        """
        try:
            import pandas as pd
        except ImportError as exc:  # pragma: no cover - depends on optional environment
            raise ImportError(
                "pandas is required for to_dataframe(); install 'cabledyn[dataframe]'"
            ) from exc
        columns = [
            _label(name, self.unit(name)) if units_in_columns else name for name in self.channels
        ]
        return pd.DataFrame(self.values.copy(), columns=columns)

    def export_pydatview(
        self, path: str | os.PathLike[str], *, overwrite: bool = False, delimiter: str | None = None
    ) -> Path:
        """Export a generic table that pyDatView can read reliably.

        Units are embedded in the single header row as ``Name_[unit]``. CSV is
        selected for a ``.csv`` suffix; other suffixes default to tab-separated
        text. The source table is never modified.

        Parameters
        ----------
        path : str | os.PathLike
            Target file. Missing parent directories are created.
        overwrite : bool
            Replace an existing file instead of raising :class:`FileExistsError`.
        delimiter : str | None
            One-character column separator overriding the suffix-based choice.

        Returns
        -------
        pathlib.Path
            Absolute path of the written file.

        Raises
        ------
        FileExistsError
            If ``path`` exists and ``overwrite`` is false.
        ValueError
            If ``path`` is the source file or ``delimiter`` is not one character.
        """
        target = Path(path).expanduser().resolve()
        if target == self.path.expanduser().resolve():
            raise ValueError("export target must not be the source result file")
        if target.exists() and not overwrite:
            raise FileExistsError(f"output already exists: {target}")
        target.parent.mkdir(parents=True, exist_ok=True)
        if delimiter is not None:
            sep = delimiter
        else:
            sep = "," if target.suffix.lower() == ".csv" else "\t"
        if len(sep) != 1:
            raise ValueError("delimiter must be one character")
        labels = [_label(name, self.unit(name)) for name in self.channels]
        fd, temporary = tempfile.mkstemp(
            prefix=f".{target.name}.", suffix=".tmp", dir=target.parent, text=True
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
                writer = csv.writer(stream, delimiter=sep, lineterminator="\n")
                writer.writerow(labels)
                writer.writerows(tuple(f"{value:.17g}" for value in row) for row in self.values)
            os.replace(temporary, target)
        except BaseException:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(temporary)
            raise
        return target


@dataclass(frozen=True)
class TimeHistory(OutputTable):
    """A validated monotonically increasing time-history table.

    A subclass of :class:`cabledyn.OutputTable` with a time column, in
    seconds, whose values strictly increase. :func:`cabledyn.read_output`
    returns it for a main output file. The attributes are those of
    :class:`cabledyn.OutputTable`, with ``values`` of shape
    ``(n_samples, n_channels)``.

    Raises
    ------
    OutputFormatError
        If the time values do not strictly increase.
    """

    def __post_init__(self) -> None:
        super().__post_init__()
        time = self.time
        if time.size > 1 and np.any(np.diff(time) <= 0.0):
            raise OutputFormatError(f"{self.path}: time values are not strictly increasing")

    @property
    def time_channel(self) -> str:
        """Name of the table's time column (``Time`` or ``Time(s)``)."""
        for name in self.channels:
            if name.lower() in {"time", "time(s)"}:
                return name
        raise OutputFormatError(f"{self.path}: time-history table has no time channel")

    @property
    def time(self) -> npt.NDArray[Any]:
        """Read-only sample times in seconds."""
        return self.column(self.time_channel)

    def period(self, start: float | None = None, stop: float | None = None) -> TimeHistory:
        """Return samples in the closed interval ``[start, stop]``.

        Parameters
        ----------
        start, stop : float | None
            Interval limits in seconds. ``None`` leaves that end open.

        Returns
        -------
        TimeHistory
            A new table of the same class holding only the selected rows.

        Raises
        ------
        ValueError
            If a limit is not finite, ``start`` exceeds ``stop``, or no sample
            lies in the interval.
        """
        if start is not None and not np.isfinite(float(start)):
            raise ValueError("period start must be finite")
        if stop is not None and not np.isfinite(float(stop)):
            raise ValueError("period stop must be finite")
        if start is not None and stop is not None and start > stop:
            raise ValueError("period start must not exceed stop")
        mask = np.ones(self.time.shape, dtype=bool)
        if start is not None:
            mask &= self.time >= float(start)
        if stop is not None:
            mask &= self.time <= float(stop)
        if not np.any(mask):
            raise ValueError("requested period contains no samples")
        return type(self)(
            self.path, self.title, self.channels, self.units, self.values[mask].copy()
        )

    def _interpolate(self, channels: tuple[str, ...], time: float) -> npt.NDArray[Any]:
        """Linearly interpolate selected channels at one in-range physical time."""
        requested = float(time)
        if not np.isfinite(requested):
            raise ValueError("sample time must be finite")
        if requested < self.time[0] or requested > self.time[-1]:
            raise ValueError(
                f"sample time {requested:g} is outside [{self.time[0]:g}, {self.time[-1]:g}]"
            )
        indices = [self.channels.index(channel) for channel in channels]
        result = np.asarray(
            [np.interp(requested, self.time, self.values[:, index]) for index in indices],
            dtype=np.float64,
        )
        result.setflags(write=False)
        return result

    def statistics(
        self,
        channels: str | Iterable[str] | None = None,
    ) -> tuple[ChannelStatistics, ...]:
        """Compute population statistics over the represented period.

        Parameters
        ----------
        channels : str | collections.abc.Iterable[str] | None
            One channel name, several names, or ``None`` for every channel
            except time.

        Returns
        -------
        tuple[ChannelStatistics, ...]
            One entry per selected channel, in the requested order, in each
            channel's unit.

        Raises
        ------
        KeyError
            If a requested channel is not in the table.
        """
        if channels is None:
            selected = tuple(name for name in self.channels if name != self.time_channel)
        elif isinstance(channels, str):
            selected = (channels,)
        else:
            selected = tuple(channels)
        result: list[ChannelStatistics] = []
        for channel in selected:
            data = self.column(channel)
            result.append(
                ChannelStatistics(
                    channel=channel,
                    unit=self.unit(channel),
                    count=int(data.size),
                    minimum=float(np.min(data)),
                    maximum=float(np.max(data)),
                    mean=float(np.mean(data)),
                    standard_deviation=float(np.std(data)),
                    rms=float(np.linalg.norm(data) / np.sqrt(data.size)),
                )
            )
        return tuple(result)

    def fatigue(
        self,
        channel: str,
        *,
        wohler_exponent: float,
        reference_cycles: float | None = None,
        reference_frequency: float | None = None,
        start: float | None = None,
        stop: float | None = None,
        bins: int | Iterable[float] | None = None,
    ) -> FatigueResult:
        """Return uncorrected rainflow cycles and a damage-equivalent range.

        Supply exactly one of ``reference_cycles`` or ``reference_frequency``.
        A frequency is converted to cycles using the selected record duration.
        Cycle ranges, rather than amplitudes, are used throughout. No mean-stress
        correction is applied.

        Parameters
        ----------
        channel : str
            Channel to analyse; not the time channel.
        wohler_exponent : float
            Positive S-N curve slope exponent ``m``.
        reference_cycles : float | None
            Number of equivalent constant-range cycles.
        reference_frequency : float | None
            Equivalent-cycle frequency, in Hz; multiplied by the record duration
            to give the reference cycle count.
        start, stop : float | None
            Optional analysis window, in seconds.
        bins : int | collections.abc.Iterable[float] | None
            Optional range histogram: a bin count, or explicit increasing bin
            edges spanning every cycle range. See :func:`cabledyn.cycle_histogram`.

        Returns
        -------
        FatigueResult
            The cycles, the damage-equivalent range, and the analysis settings.

        Raises
        ------
        ValueError
            If the channel is the time channel, fewer than two samples are
            selected, or the fatigue settings are invalid.
        """
        from cabledyn.fatigue import (
            FatigueResult,
            cycle_histogram,
            damage_equivalent_range,
            rainflow_cycles,
        )

        if channel == self.time_channel:
            raise ValueError("fatigue analysis requires a non-time channel")
        if isinstance(wohler_exponent, bool):
            raise ValueError("wohler_exponent must be finite and positive")
        view = self.period(start, stop) if start is not None or stop is not None else self
        if view.time.size < 2:
            raise ValueError("fatigue analysis requires at least two time samples")
        duration = float(view.time[-1] - view.time[0])
        if (reference_cycles is None) == (reference_frequency is None):
            raise ValueError("supply exactly one of reference_cycles or reference_frequency")
        if reference_frequency is not None:
            if isinstance(reference_frequency, bool):
                raise ValueError("reference_frequency must be finite and positive")
            frequency = float(reference_frequency)
            if not np.isfinite(frequency) or frequency <= 0.0:
                raise ValueError("reference_frequency must be finite and positive")
            equivalent_cycles = frequency * duration
        else:
            if isinstance(reference_cycles, bool) or reference_cycles is None:
                raise ValueError("reference_cycles must be finite and positive")
            equivalent_cycles = float(reference_cycles)
            if not np.isfinite(equivalent_cycles) or equivalent_cycles <= 0.0:
                raise ValueError("reference_cycles must be finite and positive")
            frequency = equivalent_cycles / duration
        cycles = rainflow_cycles(view.column(channel), time=view.time)
        histogram = cycle_histogram(cycles, bins) if bins is not None else None
        exponent = float(wohler_exponent)
        equivalent_range = damage_equivalent_range(
            cycles,
            wohler_exponent=exponent,
            reference_cycles=equivalent_cycles,
        )
        return FatigueResult(
            channel=channel,
            source=view.path,
            unit=view.unit(channel),
            sample_count=int(view.time.size),
            start_time=float(view.time[0]),
            end_time=float(view.time[-1]),
            duration=duration,
            wohler_exponent=exponent,
            reference_cycles=equivalent_cycles,
            equivalent_frequency=frequency,
            cycle_count=sum(cycle.count for cycle in cycles),
            damage_equivalent_range=equivalent_range,
            cycles=cycles,
            histogram=histogram,
        )

    def spectrum(
        self,
        channel: str,
        *,
        segment_length: int,
        overlap: float = 0.5,
        fft_length: int | None = None,
        window: str = "hann",
        detrend: str = "constant",
        start: float | None = None,
        stop: float | None = None,
        uniform_rtol: float = 1.0e-6,
        uniform_atol: float = 0.0,
    ) -> PowerSpectrum:
        """Return a one-sided Welch PSD density for a uniformly sampled channel.

        ``segment_length`` is deliberately mandatory. The method never resamples
        data and rejects time-step variation outside the stated tolerances.

        Parameters
        ----------
        channel : str
            Channel to analyse; not the time channel.
        segment_length : int
            Samples per Welch segment; at least 2 and at most the sample count.
        overlap : float
            Fraction of a segment shared with the next, in ``[0, 1)``.
        fft_length : int | None
            FFT length; ``None`` uses ``segment_length``.
        window : str
            ``"hann"`` (periodic Hann) or ``"boxcar"``.
        detrend : str
            ``"constant"`` removes each segment's mean; ``"none"`` keeps it.
        start, stop : float | None
            Optional analysis window, in seconds.
        uniform_rtol, uniform_atol : float
            Relative and absolute (seconds) tolerances for accepting the time
            steps as uniform.

        Returns
        -------
        PowerSpectrum
            The spectrum, in (channel unit)^2/Hz against frequency in Hz, and
            the settings that produced it.

        Raises
        ------
        KeyError
            If the table has no channel of that name.
        ValueError
            If ``channel`` is the time channel, the window is invalid, the
            samples are not uniformly spaced, or a setting is out of range. See
            :func:`cabledyn.power_spectrum`.
        """
        from cabledyn.spectra import power_spectrum

        if channel == self.time_channel:
            raise ValueError("power spectrum requires a non-time channel")
        view = self.period(start, stop) if start is not None or stop is not None else self
        return power_spectrum(
            view.time,
            view.column(channel),
            channel=channel,
            source=view.path,
            unit=view.unit(channel),
            segment_length=segment_length,
            overlap=overlap,
            fft_length=fft_length,
            window=window,
            detrend=detrend,
            uniform_rtol=uniform_rtol,
            uniform_atol=uniform_atol,
        )

    def coherence(
        self,
        channel_x: str,
        channel_y: str,
        *,
        segment_length: int,
        overlap: float = 0.5,
        fft_length: int | None = None,
        window: str = "hann",
        detrend: str = "constant",
        start: float | None = None,
        stop: float | None = None,
        power_floor_ratio: float = DEFAULT_POWER_FLOOR_RATIO,
        uniform_rtol: float = 1.0e-6,
        uniform_atol: float = 0.0,
    ) -> CoherenceResult:
        """Return magnitude-squared Welch coherence with invalid low-power bins masked.

        Parameters
        ----------
        channel_x, channel_y : str
            Two distinct non-time channels.
        segment_length : int
            Samples per Welch segment; at least two complete segments are needed.
        overlap : float
            Fraction of a segment shared with the next, in ``[0, 1)``.
        fft_length : int | None
            FFT length; ``None`` uses ``segment_length``.
        window : str
            ``"hann"`` (periodic Hann) or ``"boxcar"``.
        detrend : str
            ``"constant"`` removes each segment's mean; ``"none"`` keeps it.
        start, stop : float | None
            Optional analysis window, in seconds.
        power_floor_ratio : float
            A bin is valid only where both auto-spectra exceed this fraction of
            their maxima. Must lie in ``[0, 1)``.
        uniform_rtol, uniform_atol : float
            Relative and absolute (seconds) tolerances for accepting the time
            steps as uniform.

        Returns
        -------
        CoherenceResult
            The dimensionless coherence against frequency in Hz, its valid-bin
            mask, and the settings that produced it.

        Raises
        ------
        KeyError
            If the table has no channel of either name.
        ValueError
            If a channel is the time channel, the channels are the same, the
            window is invalid, or a setting is out of range.
        """
        from cabledyn.spectra import magnitude_squared_coherence

        if self.time_channel in {channel_x, channel_y}:
            raise ValueError("coherence requires two non-time channels")
        if channel_x == channel_y:
            raise ValueError("coherence requires two distinct channels")
        view = self.period(start, stop) if start is not None or stop is not None else self
        return magnitude_squared_coherence(
            view.time,
            view.column(channel_x),
            view.column(channel_y),
            channel_x=channel_x,
            channel_y=channel_y,
            source=view.path,
            segment_length=segment_length,
            overlap=overlap,
            fft_length=fft_length,
            window=window,
            detrend=detrend,
            power_floor_ratio=power_floor_ratio,
            uniform_rtol=uniform_rtol,
            uniform_atol=uniform_atol,
        )

    def plot(
        self, *channels: str, start: float | None = None, stop: float | None = None, ax: Any = None
    ) -> Any:
        """Plot one or more channels against time using optional matplotlib.

        Parameters
        ----------
        *channels : str
            Channels to plot; every non-time channel when none are given.
        start, stop : float | None
            Optional time window, in seconds.
        ax : matplotlib.axes.Axes | None
            Axes to draw on; a new figure is created when omitted.

        Returns
        -------
        matplotlib.axes.Axes
            The axes drawn on, with time in seconds on the horizontal axis.

        Raises
        ------
        ImportError
            If matplotlib is not installed.
        KeyError
            If a requested channel is not in the table.
        ValueError
            If the time window is invalid or contains no sample.
        """
        plt = pyplot()
        view = self.period(start, stop) if start is not None or stop is not None else self
        selected = channels or tuple(name for name in self.channels if name != self.time_channel)
        if ax is None:
            _, ax = plt.subplots()
        for channel in selected:
            ax.plot(view.time, view.column(channel), label=channel)
        ax.set_xlabel("Time [s]")
        ax.grid(True)
        if len(selected) > 1:
            ax.legend()
        elif selected:
            unit = self.unit(selected[0])
            ax.set_ylabel(f"{selected[0]} [{unit}]" if unit else selected[0])
        return ax


# Indices are capped at nine digits so int() never meets an unbounded string.
_NODE_CHANNEL = re.compile(r"Node([1-9][0-9]{0,8})([XYZ])\(([^()]*)\)")
_SEGMENT_CHANNEL = re.compile(r"Segment([1-9][0-9]{0,8})Tension\(([^()]*)\)")
_LIFT_CHANNEL = re.compile(r"Node([1-9][0-9]{0,8})Lift([XYZ])\(([^()]*)\)")


@dataclass(frozen=True)
class LineNodeHistory(TimeHistory):
    """Dynamic positions of every node of one line, in End-A-to-End-B order.

    A subclass of :class:`cabledyn.TimeHistory` read from a per-line position
    file. After the time column, the channels are ``Node<i>X(m)``,
    ``Node<i>Y(m)``, and ``Node<i>Z(m)`` for every node ``i``. The attributes
    are those of :class:`cabledyn.OutputTable`, with ``values`` of shape
    ``(n_samples, 1 + 3 * n_nodes)``; positions are in metres.

    The file lists every node of the line's final mesh. On a finite-EI line
    whose mesh the static solve refined, a ``# DeckNode`` comment line names
    the deck node of each (:attr:`deck_nodes`).

    Raises
    ------
    OutputFormatError
        If the node channels are malformed, not contiguous from ``Node1``, or
        not in metres, time does not strictly increase, or a ``# DeckNode``
        line does not number the deck nodes of the file's nodes.
    """

    def __post_init__(self) -> None:
        super().__post_init__()
        parsed = [_NODE_CHANNEL.fullmatch(channel) for channel in self.channels[1:]]
        if not parsed or any(match is None for match in parsed):
            raise OutputFormatError(f"{self.path}: malformed dynamic line-node channels")
        actual = [(int(match.group(1)), match.group(2)) for match in parsed if match is not None]
        node_count = len(actual) // 3
        expected = [(node, axis) for node in range(1, node_count + 1) for axis in "XYZ"]
        if actual != expected:
            raise OutputFormatError(
                f"{self.path}: line-node channels must be contiguous Node1X/Y/Z through "
                f"Node{node_count}X/Y/Z"
            )
        units = {match.group(3) for match in parsed if match is not None}
        if units != {"m"}:
            raise OutputFormatError(f"{self.path}: line-node position channels must use metres")
        deck = self.deck_nodes
        if deck is not None:
            named = deck[deck > 0]
            if (
                deck.size != node_count
                or np.any(deck < 0)
                or deck[0] != 1
                or deck[-1] <= 0
                or not np.array_equal(named, np.arange(1, named.size + 1))
            ):
                raise OutputFormatError(
                    f"{self.path}: the DeckNode line does not number the deck nodes of the "
                    f"{node_count} nodes 1, 2, ... from End A to End B"
                )

    @property
    def deck_nodes(self) -> npt.NDArray[np.int64] | None:
        """Deck node of each node of the file, or ``None`` for the deck mesh.

        ``(n_nodes,)`` deck node numbers (the ``<J>`` of the node channels of
        a main output) from the file's ``# DeckNode`` line, 0 for a node a mesh
        refinement added; ``None`` when the file has no such line (the line was
        not refined, so its nodes are the deck nodes).
        """
        return _deck_node_comment(self.title, self.path)

    @property
    def node_ids(self) -> tuple[int, ...]:
        """One-based node identifiers in public End-A-to-End-B order."""
        return tuple(range(1, (len(self.channels) - 1) // 3 + 1))

    def coordinates(self, time: float) -> npt.NDArray[Any]:
        """Return an interpolated, read-only ``(n_nodes, 3)`` XYZ snapshot.

        Parameters
        ----------
        time : float
            Physical time of the snapshot, in seconds.

        Returns
        -------
        numpy.ndarray
            Read-only ``(n_nodes, 3)`` node positions, in metres, linearly
            interpolated in time, in End-A-to-End-B order.

        Raises
        ------
        ValueError
            If ``time`` is not finite or lies outside the recorded interval.
        """
        values = self._interpolate(self.channels[1:], time).reshape((-1, 3))
        values.setflags(write=False)
        return values

    def arc_length(self, time: float) -> npt.NDArray[Any]:
        """Return cumulative deformed chord length from End A at ``time``.

        Parameters
        ----------
        time : float
            Physical time of the snapshot, in seconds.

        Returns
        -------
        numpy.ndarray
            Read-only ``(n_nodes,)`` cumulative sum of straight node-to-node
            distances, in metres, starting at zero.

        Raises
        ------
        ValueError
            If ``time`` is not finite or lies outside the recorded interval.
        """
        xyz = self.coordinates(time)
        result = np.concatenate(([0.0], np.cumsum(np.linalg.norm(np.diff(xyz, axis=0), axis=1))))
        result.setflags(write=False)
        return result

    def plot_geometry(self, time: float, *, plane: str = "xz", ax: Any = None) -> Any:
        """Plot an interpolated line centreline in ``xy``, ``xz``, ``yz``, or 3-D.

        Parameters
        ----------
        time : float
            Physical time of the snapshot, in seconds.
        plane : str
            ``"xy"``, ``"xz"``, ``"yz"``, or ``"3d"``.
        ax : matplotlib.axes.Axes | None
            Axes to draw on; a new figure is created when omitted. For
            ``"3d"`` it must be a 3-D axes.

        Returns
        -------
        matplotlib.axes.Axes
            The axes drawn on.

        Raises
        ------
        ImportError
            If matplotlib is not installed.
        ValueError
            If ``plane`` is not recognized, or ``time`` is not finite or lies
            outside the recorded interval.
        """
        plt = pyplot()
        plane = plane.lower()
        if plane not in {"xy", "xz", "yz", "3d"}:
            raise ValueError("plane must be 'xy', 'xz', 'yz', or '3d'")
        xyz = self.coordinates(time)
        if ax is None:
            if plane == "3d":
                figure = plt.figure()
                ax = figure.add_subplot(111, projection="3d")
            else:
                _, ax = plt.subplots()
        if plane == "3d":
            ax.plot(xyz[:, 0], xyz[:, 1], xyz[:, 2])
            ax.set_xlabel("X [m]")
            ax.set_ylabel("Y [m]")
            ax.set_zlabel("Z [m]")
        else:
            first, second = ("xyz".index(axis) for axis in plane)
            ax.plot(xyz[:, first], xyz[:, second])
            ax.set_xlabel(f"{plane[0].upper()} [m]")
            ax.set_ylabel(f"{plane[1].upper()} [m]")
            ax.set_aspect("equal", adjustable="datalim")
        ax.set_title(f"t = {float(time):g} s")
        ax.grid(True)
        return ax


@dataclass(frozen=True)
class LineSegmentHistory(TimeHistory):
    """Dynamic effective tension at every segment of one line.

    A subclass of :class:`cabledyn.TimeHistory` read from a per-line tension
    file. After the time column, the channels are ``Segment<i>Tension(N)`` for
    every segment ``i``, numbered from End A. The attributes are those of
    :class:`cabledyn.OutputTable`, with ``values`` of shape
    ``(n_samples, 1 + n_segments)``; tensions are in newtons.

    Raises
    ------
    OutputFormatError
        If the segment channels are malformed, not contiguous from
        ``Segment1``, or not in newtons, or time does not strictly increase.
    """

    def __post_init__(self) -> None:
        super().__post_init__()
        parsed = [_SEGMENT_CHANNEL.fullmatch(channel) for channel in self.channels[1:]]
        if not parsed or any(match is None for match in parsed):
            raise OutputFormatError(f"{self.path}: malformed dynamic line-segment channels")
        identifiers = tuple(int(match.group(1)) for match in parsed if match is not None)
        if identifiers != tuple(range(1, len(identifiers) + 1)):
            raise OutputFormatError(
                f"{self.path}: segment channels must be contiguous Segment1 through "
                f"Segment{len(identifiers)}"
            )
        units = {match.group(2) for match in parsed if match is not None}
        if units != {"N"}:
            raise OutputFormatError(f"{self.path}: segment-tension channels must use newtons")

    @property
    def segment_ids(self) -> tuple[int, ...]:
        """One-based segment identifiers in public End-A-to-End-B order."""
        return tuple(range(1, len(self.channels)))

    def tensions(self, time: float) -> npt.NDArray[Any]:
        """Return linearly interpolated segment tensions at one physical time.

        Parameters
        ----------
        time : float
            Physical time, in seconds.

        Returns
        -------
        numpy.ndarray
            Read-only ``(n_segments,)`` effective tensions, in newtons, in
            End-A-to-End-B order.

        Raises
        ------
        ValueError
            If ``time`` is not finite or lies outside the recorded interval.
        """
        return self._interpolate(self.channels[1:], time)

    def spatial_statistics(
        self, start: float | None = None, stop: float | None = None
    ) -> SpatialStatistics:
        """Return the tension envelope and population statistics at every segment.

        Parameters
        ----------
        start, stop : float | None
            Optional time window, in seconds; ``None`` leaves that end open.

        Returns
        -------
        SpatialStatistics
            Per-segment tension statistics, in newtons, each of shape
            ``(n_segments,)``.

        Raises
        ------
        ValueError
            If a window limit is not finite, ``start`` exceeds ``stop``, or no
            sample lies in the window.
        """
        view = self.period(start, stop) if start is not None or stop is not None else self
        data = view.values[:, 1:]
        unit = self.unit(self.channels[1])
        return SpatialStatistics(
            location_kind="Segment",
            location_ids=np.asarray(self.segment_ids),
            quantity="Tension",
            unit=unit,
            count=data.shape[0],
            minimum=np.min(data, axis=0),
            maximum=np.max(data, axis=0),
            mean=np.mean(data, axis=0),
            standard_deviation=np.std(data, axis=0),
            rms=np.linalg.norm(data, axis=0) / np.sqrt(data.shape[0]),
        )

    def plot_range(self, time: float, *, ax: Any = None) -> Any:
        """Plot the dynamic tension range graph at one interpolated time.

        Parameters
        ----------
        time : float
            Physical time, in seconds.
        ax : matplotlib.axes.Axes | None
            Axes to draw on; a new figure is created when omitted.

        Returns
        -------
        matplotlib.axes.Axes
            The axes drawn on: tension, in newtons, against segment number.

        Raises
        ------
        ImportError
            If matplotlib is not installed.
        ValueError
            If ``time`` is not finite or lies outside the recorded interval.
        """
        plt = pyplot()
        if ax is None:
            _, ax = plt.subplots()
        ax.plot(self.segment_ids, self.tensions(time))
        ax.set_xlabel("Segment [-]")
        unit = self.unit(self.channels[1])
        ax.set_ylabel(f"Tension [{unit}]" if unit else "Tension")
        ax.set_title(f"t = {float(time):g} s")
        ax.grid(True)
        return ax

    def plot_envelope(
        self,
        start: float | None = None,
        stop: float | None = None,
        *,
        ax: Any = None,
    ) -> Any:
        """Plot minimum/maximum and mean segment tension over a physical-time window.

        Parameters
        ----------
        start, stop : float | None
            Optional time window, in seconds; ``None`` leaves that end open.
        ax : matplotlib.axes.Axes | None
            Axes to draw on; a new figure is created when omitted.

        Returns
        -------
        matplotlib.axes.Axes
            The axes drawn on: tension, in newtons, against segment number.

        Raises
        ------
        ImportError
            If matplotlib is not installed.
        ValueError
            If the window is invalid or contains no sample.
        """
        plt = pyplot()
        stats = self.spatial_statistics(start, stop)
        if ax is None:
            _, ax = plt.subplots()
        ax.fill_between(
            stats.location_ids, stats.minimum, stats.maximum, alpha=0.25, label="min-max"
        )
        ax.plot(stats.location_ids, stats.mean, label="mean")
        ax.set_xlabel("Segment [-]")
        ax.set_ylabel(f"Tension [{stats.unit}]" if stats.unit else "Tension")
        ax.grid(True)
        ax.legend()
        return ax


def _check_positive_integers(table: OutputTable, channels: tuple[str, ...]) -> None:
    """Refuse a table whose identifier columns are not positive integers."""
    for channel in channels:
        values = table.column(channel)
        if np.any(values <= 0.0) or np.any(values != np.floor(values)):
            raise OutputFormatError(f"{table.path}: {channel} values must be positive integers")


def _check_contiguous_lines(table: OutputTable) -> None:
    """Refuse a table whose rows of one line are split by rows of another."""
    seen: set[int] = set()
    active: int | None = None
    for value in table.column("LineID"):
        identifier = int(value)
        if identifier != active:
            if identifier in seen:
                raise OutputFormatError(
                    f"{table.path}: LineID {identifier} rows are not contiguous"
                )
            seen.add(identifier)
            active = identifier


@dataclass(frozen=True)
class StaticProfile(OutputTable):
    """One or more CableDyn line profiles indexed by line and arc length.

    A subclass of :class:`cabledyn.OutputTable` read from a static profile
    file. It has at least the ``LineID``, ``Node``, and ``ArcLength`` columns,
    with each line's rows contiguous and ordered from End A. Further columns,
    such as ``X``, ``Y``, ``Z``, ``Tension``, ``Curvature``, and
    ``BendMoment``, are available through :meth:`~cabledyn.OutputTable.column`,
    in SI units: coordinates and arc length in m, tension in N, curvature in
    1/m, and bending moment in N-m. The attributes are those of
    :class:`cabledyn.OutputTable`, with ``values`` of shape
    ``(n_rows, n_channels)``.

    A finite-EI line whose mesh the static solve refined lists every node of
    its final mesh. The file then has a ``DeckNode`` column: the deck node of
    each row (deck nodes run from 1 at End A to 1 + the total ``NumSegs`` of the
    line's sections at End B), or 0 for a node the refinement added. The node
    channels of a main output (``Ten<L>N<J>``, ``L<L>N<J>px``, ...) number deck
    nodes; :meth:`deck_node_arc_lengths` places them.

    Raises
    ------
    OutputFormatError
        If a required column is missing, ``LineID`` or ``Node`` values are not
        positive integers, a line's rows are not contiguous, a line's arc
        length or node order is not increasing, or a ``DeckNode`` column does
        not number the deck nodes of a line in increasing order from 1 at its
        first row to its last row.
    """

    def __post_init__(self) -> None:
        super().__post_init__()
        required = {"LineID", "Node", "ArcLength"}
        missing = required.difference(self.channels)
        if missing:
            raise OutputFormatError(
                f"{self.path}: static profile missing {', '.join(sorted(missing))}"
            )
        _check_positive_integers(self, ("LineID", "Node"))
        _check_contiguous_lines(self)
        for line_id in self.line_ids:
            mask = self.column("LineID") == line_id
            arc = self.column("ArcLength")[mask]
            node = self.column("Node")[mask]
            if np.any(arc < 0.0):
                raise OutputFormatError(f"{self.path}: LineID {line_id} arc length is negative")
            if arc.size > 1 and np.any(np.diff(arc) < -1.0e-12):
                raise OutputFormatError(
                    f"{self.path}: LineID {line_id} arc length is not monotonic"
                )
            if node.size > 1 and np.any(np.diff(node) <= 0.0):
                raise OutputFormatError(
                    f"{self.path}: LineID {line_id} node order is not increasing"
                )
        if "DeckNode" in self.channels:
            deck = self.column("DeckNode")
            if np.any(deck < 0.0) or np.any(deck != np.floor(deck)):
                raise OutputFormatError(
                    f"{self.path}: DeckNode values must be non-negative integers"
                )
            for line_id in self.line_ids:
                numbered = deck[self.column("LineID") == line_id]
                named = numbered[numbered > 0.0]
                if (
                    numbered[0] != 1.0
                    or numbered[-1] <= 0.0
                    or np.any(named != np.arange(1, named.size + 1))
                ):
                    raise OutputFormatError(
                        f"{self.path}: LineID {line_id} DeckNode does not number the deck nodes "
                        "1, 2, ... from End A to End B"
                    )

    @property
    def line_ids(self) -> tuple[int, ...]:
        """Line identifiers in first-appearance order."""
        return tuple(dict.fromkeys(int(value) for value in self.column("LineID")))

    def line(self, line_id: int) -> StaticProfile:
        """Return the rows belonging to one line identifier.

        Parameters
        ----------
        line_id : int
            One-based line identifier, as in the ``LineID`` column.

        Returns
        -------
        StaticProfile
            A new profile holding only that line's rows, ordered from End A.

        Raises
        ------
        KeyError
            If the profile has no rows for ``line_id``.
        """
        mask = self.column("LineID") == int(line_id)
        if not np.any(mask):
            raise KeyError(
                f"LineID {line_id} is not in {self.path.name}; available: {self.line_ids}"
            )
        return StaticProfile(
            self.path, self.title, self.channels, self.units, self.values[mask].copy()
        )

    def deck_node_arc_lengths(self, line_id: int) -> dict[int, float]:
        """Return the static arc length of each deck node of one line.

        The node channels of a main output number deck nodes, from 1 at End A
        to 1 + the total ``NumSegs`` of the line's sections at End B. On a line
        whose mesh the static solve refined, the profile lists every node of the
        final mesh and its ``DeckNode`` column locates the deck nodes among
        them; otherwise the profile nodes are the deck nodes.

        Parameters
        ----------
        line_id : int
            One-based line identifier, as in the ``LineID`` column.

        Returns
        -------
        dict[int, float]
            Deck node number to its deformed arc length from End A, in metres.

        Raises
        ------
        KeyError
            If the profile has no rows for ``line_id``.
        """
        line = self.line(line_id)
        arc = line.column("ArcLength")
        if "DeckNode" not in line.channels:
            nodes = line.column("Node")
            return {int(node): float(value) for node, value in zip(nodes, arc, strict=True)}
        deck = line.column("DeckNode")
        return {
            int(node): float(value) for node, value in zip(deck, arc, strict=True) if node > 0.0
        }

    def summary(self, line_id: int) -> StaticLineSummary:
        """Return core geometry and demand extrema for one line.

        Parameters
        ----------
        line_id : int
            One-based line identifier, as in the ``LineID`` column.

        Returns
        -------
        StaticLineSummary
            Deformed length (m), tension extrema (N), maximum curvature (1/m),
            minimum bend radius (m), and maximum bending moment (N-m).

        Raises
        ------
        KeyError
            If the profile has no rows for ``line_id``.
        """
        line = self.line(line_id)

        def extrema(channel: str, operation: Callable[[npt.NDArray[Any]], Any]) -> float | None:
            return float(operation(line.column(channel))) if channel in line.channels else None

        max_curvature = extrema("Curvature", np.max)
        if max_curvature is None:
            minimum_bend_radius = None
        elif max_curvature > 0.0:
            minimum_bend_radius = 1.0 / max_curvature
        else:
            minimum_bend_radius = float("inf")
        return StaticLineSummary(
            line_id=int(line_id),
            node_count=line.values.shape[0],
            deformed_length=float(line.column("ArcLength")[-1]),
            minimum_tension=extrema("Tension", np.min),
            maximum_tension=extrema("Tension", np.max),
            maximum_curvature=max_curvature,
            minimum_bend_radius=minimum_bend_radius,
            maximum_bend_moment=extrema("BendMoment", lambda x: np.max(np.abs(x))),
        )

    def summaries(self) -> tuple[StaticLineSummary, ...]:
        """Return one engineering summary per line.

        Returns
        -------
        tuple[StaticLineSummary, ...]
            One summary per line, in the order of :attr:`line_ids`.
        """
        return tuple(self.summary(line_id) for line_id in self.line_ids)

    def plot(
        self, channel: str, *, x: str = "ArcLength", line_id: int | None = None, ax: Any = None
    ) -> Any:
        """Plot a range variable against arc length or another profile column.

        Parameters
        ----------
        channel : str
            Profile column plotted on the vertical axis.
        x : str
            Profile column plotted on the horizontal axis.
        line_id : int | None
            Plot one line; every line when omitted.
        ax : matplotlib.axes.Axes | None
            Axes to draw on; a new figure is created when omitted.

        Returns
        -------
        matplotlib.axes.Axes
            The axes drawn on.

        Raises
        ------
        ImportError
            If matplotlib is not installed.
        KeyError
            If a column or ``line_id`` is not in the profile.
        """
        plt = pyplot()
        if ax is None:
            _, ax = plt.subplots()
        selected = (int(line_id),) if line_id is not None else self.line_ids
        for identifier in selected:
            line = self.line(identifier)
            ax.plot(line.column(x), line.column(channel), label=f"Line {identifier}")
        xunit = self.unit(x)
        yunit = self.unit(channel)
        ax.set_xlabel(f"{x} [{xunit}]" if xunit else x)
        ax.set_ylabel(f"{channel} [{yunit}]" if yunit else channel)
        ax.grid(True)
        if len(selected) > 1:
            ax.legend()
        return ax

    def plot_geometry(
        self,
        *,
        plane: str = "xz",
        line_id: int | None = None,
        ax: Any = None,
    ) -> Any:
        """Plot the static centreline in ``xy``, ``xz``, ``yz``, or three dimensions.

        Parameters
        ----------
        plane : str
            ``"xy"``, ``"xz"``, ``"yz"``, or ``"3d"``.
        line_id : int | None
            Plot one line; every line when omitted.
        ax : matplotlib.axes.Axes | None
            Axes to draw on; a new figure is created when omitted. For
            ``"3d"`` it must be a 3-D axes.

        Returns
        -------
        matplotlib.axes.Axes
            The axes drawn on, with coordinates in metres.

        Raises
        ------
        ImportError
            If matplotlib is not installed.
        KeyError
            If the profile lacks the needed ``X``/``Y``/``Z`` columns or
            ``line_id``.
        ValueError
            If ``plane`` is not recognized.
        """
        plt = pyplot()
        plane = plane.lower()
        if plane not in {"xy", "xz", "yz", "3d"}:
            raise ValueError("plane must be 'xy', 'xz', 'yz', or '3d'")
        if ax is None:
            if plane == "3d":
                figure = plt.figure()
                ax = figure.add_subplot(111, projection="3d")
            else:
                _, ax = plt.subplots()
        selected = (int(line_id),) if line_id is not None else self.line_ids
        for identifier in selected:
            line = self.line(identifier)
            if plane == "3d":
                ax.plot(
                    line.column("X"), line.column("Y"), line.column("Z"), label=f"Line {identifier}"
                )
            else:
                first, second = plane.upper()[0], plane.upper()[1]
                ax.plot(line.column(first), line.column(second), label=f"Line {identifier}")
        if plane != "3d":
            first, second = plane.upper()[0], plane.upper()[1]
            ax.set_xlabel(f"{first} [m]")
            ax.set_ylabel(f"{second} [m]")
            ax.set_aspect("equal", adjustable="datalim")
        else:
            ax.set_xlabel("X [m]")
            ax.set_ylabel("Y [m]")
            ax.set_zlabel("Z [m]")
        ax.grid(True)
        if len(selected) > 1:
            ax.legend()
        return ax


@dataclass(frozen=True)
class ModeShapes(OutputTable):
    """The mode-shape table of a ``.modes.out`` file.

    A subclass of :class:`cabledyn.OutputTable` holding one row per line, mode
    and node, with the columns ``LineID``, ``Mode``, ``Node``, ``X``, ``Y``,
    ``Z``, ``dX``, ``dY``, and ``dZ``, and ``dTwist`` in a file that carries
    twist angles. It is read as :attr:`cabledyn.NaturalModes.shapes`.

    ``X``, ``Y``, ``Z`` are the static node positions in m. ``dX``, ``dY``,
    ``dZ`` are the nodal translations of the mode, scaled so that its largest
    nodal displacement is 1. ``dTwist`` is the rotation of the section about
    the line tangent, positive right-handed from End A to End B, on the same
    scale; a torsional mode is scaled to a unit largest ``dTwist`` instead.
    Nodes are numbered from End A. The attributes are those of
    :class:`cabledyn.OutputTable`.

    Raises
    ------
    OutputFormatError
        If a required column is missing, ``LineID``, ``Mode``, or ``Node``
        values are not positive integers, a line's rows are not contiguous,
        they are not the nodes 1, 2, ... of the modes 1, 2, ... in order, or
        the static position of a node differs between modes.
    """

    def __post_init__(self) -> None:
        super().__post_init__()
        required = {"LineID", "Mode", "Node", "X", "Y", "Z", "dX", "dY", "dZ"}
        missing = required.difference(self.channels)
        if missing:
            raise OutputFormatError(
                f"{self.path}: mode-shape table missing {', '.join(sorted(missing))}"
            )
        _check_positive_integers(self, ("LineID", "Mode", "Node"))
        _check_contiguous_lines(self)
        static = np.column_stack([self.column(axis) for axis in ("X", "Y", "Z")])
        for line_id in self.line_ids:
            mask = self.column("LineID") == line_id
            mode = self.column("Mode")[mask]
            node = self.column("Node")[mask]
            n_modes = int(np.count_nonzero(node == 1.0))
            n_nodes = mode.size // n_modes if n_modes else 0
            if not (
                np.array_equal(mode, np.repeat(np.arange(1, n_modes + 1), n_nodes))
                and np.array_equal(node, np.tile(np.arange(1, n_nodes + 1), n_modes))
            ):
                raise OutputFormatError(
                    f"{self.path}: LineID {line_id} rows are not the nodes 1, 2, ... "
                    "of the modes 1, 2, ..."
                )
            positions = static[mask].reshape(n_modes, n_nodes, 3)
            if np.any(positions != positions[0]):
                raise OutputFormatError(
                    f"{self.path}: LineID {line_id} static positions differ between modes"
                )

    @property
    def line_ids(self) -> tuple[int, ...]:
        """Line identifiers in first-appearance order."""
        return tuple(dict.fromkeys(int(value) for value in self.column("LineID")))

    def _line_rows(self, line_id: int) -> npt.NDArray[np.bool_]:
        mask: npt.NDArray[np.bool_] = self.column("LineID") == int(line_id)
        if not np.any(mask):
            raise KeyError(
                f"LineID {line_id} is not in {self.path.name}; available: {self.line_ids}"
            )
        return mask

    def _mode_rows(self, line_id: int, mode: int) -> npt.NDArray[np.bool_]:
        mask: npt.NDArray[np.bool_] = self._line_rows(line_id) & (self.column("Mode") == int(mode))
        if not np.any(mask):
            raise KeyError(f"LineID {line_id} has no mode {mode} in {self.path.name}")
        return mask

    def line(self, line_id: int) -> ModeShapes:
        """Return the rows belonging to one line identifier.

        Parameters
        ----------
        line_id : int
            Line identifier, as in the ``LineID`` column.

        Returns
        -------
        ModeShapes
            A new table holding only that line's rows.

        Raises
        ------
        KeyError
            If the table has no rows for ``line_id``.
        """
        return ModeShapes(
            self.path,
            self.title,
            self.channels,
            self.units,
            self.values[self._line_rows(line_id)].copy(),
        )

    def node_ids(self, line_id: int) -> tuple[int, ...]:
        """Return the node numbers of one line, from End A.

        Parameters
        ----------
        line_id : int
            Line identifier, as in the ``LineID`` column.

        Returns
        -------
        tuple[int, ...]
            Node numbers ``1, 2, ...``.

        Raises
        ------
        KeyError
            If the table has no rows for ``line_id``.
        """
        return tuple(int(value) for value in self.column("Node")[self._mode_rows(line_id, 1)])

    def positions(self, line_id: int) -> npt.NDArray[Any]:
        """Return the static node positions of one line.

        Parameters
        ----------
        line_id : int
            Line identifier, as in the ``LineID`` column.

        Returns
        -------
        numpy.ndarray
            ``(n_nodes, 3)`` array of ``X``, ``Y``, ``Z`` in m, from End A.

        Raises
        ------
        KeyError
            If the table has no rows for ``line_id``.
        """
        rows = self._mode_rows(line_id, 1)
        return np.column_stack([self.column(axis)[rows] for axis in ("X", "Y", "Z")])

    def displacements(self, line_id: int, mode: int) -> npt.NDArray[Any]:
        """Return the nodal translations of one mode.

        Parameters
        ----------
        line_id : int
            Line identifier, as in the ``LineID`` column.
        mode : int
            One-based mode number, as in the ``Mode`` column.

        Returns
        -------
        numpy.ndarray
            ``(n_nodes, 3)`` array of ``dX``, ``dY``, ``dZ``, from End A.

        Raises
        ------
        KeyError
            If the table does not hold that mode of that line.
        """
        rows = self._mode_rows(line_id, mode)
        return np.column_stack([self.column(axis)[rows] for axis in ("dX", "dY", "dZ")])

    def twist(self, line_id: int, mode: int) -> npt.NDArray[Any]:
        """Return the nodal twist of one mode.

        Parameters
        ----------
        line_id : int
            Line identifier, as in the ``LineID`` column.
        mode : int
            One-based mode number, as in the ``Mode`` column.

        Returns
        -------
        numpy.ndarray
            ``(n_nodes,)`` array of ``dTwist``, from End A; zeros in a file
            without twist angles, as on a line without torsion.

        Raises
        ------
        KeyError
            If the table does not hold that mode of that line.
        """
        rows = self._mode_rows(line_id, mode)
        if "dTwist" not in self.channels:
            return np.zeros(int(np.count_nonzero(rows)))
        return self.column("dTwist")[rows].copy()


@dataclass(frozen=True)
class NaturalModes(OutputTable):
    """Natural frequencies and mode shapes of a ``.modes.out`` file.

    A subclass of :class:`cabledyn.OutputTable` whose own table is the frequency
    table, one row per line and mode, with the columns ``LineID``, ``Mode``,
    ``Frequency`` (Hz), ``Period`` (s), and ``Omega`` (rad/s), and
    ``PolarShare`` in a file that carries twist angles. The mode-shape table is
    :attr:`shapes`.

    A negative eigenvalue is recorded with a negative ``Frequency`` and
    ``Omega`` and a ``Period`` of 0. A line without free nodes has no modes and
    no rows, so a file of such lines reads as two empty tables.

    Attributes
    ----------
    shapes : ModeShapes
        The mode-shape table of the same file.

    Raises
    ------
    OutputFormatError
        If a required column is missing, ``LineID`` or ``Mode`` values are not
        positive integers, a line's rows are not contiguous or its modes are
        not numbered 1, 2, ..., only one table carries the twist columns, or
        the two tables do not hold the same modes.
    """

    shapes: ModeShapes

    def __post_init__(self) -> None:
        super().__post_init__()
        missing = {"LineID", "Mode", "Frequency", "Period", "Omega"}.difference(self.channels)
        if missing:
            raise OutputFormatError(
                f"{self.path}: frequency table missing {', '.join(sorted(missing))}"
            )
        _check_positive_integers(self, ("LineID", "Mode"))
        _check_contiguous_lines(self)
        if self.has_twist != ("dTwist" in self.shapes.channels):
            raise OutputFormatError(
                f"{self.path}: PolarShare and dTwist must appear together in the two tables"
            )
        if self.line_ids != self.shapes.line_ids:
            raise OutputFormatError(f"{self.path}: the two tables do not hold the same lines")
        shape_line = self.shapes.column("LineID")
        shape_mode = self.shapes.column("Mode")
        for line_id in self.line_ids:
            mode = self.column("Mode")[self.column("LineID") == line_id]
            if np.any(mode != np.arange(1, mode.size + 1)):
                raise OutputFormatError(
                    f"{self.path}: LineID {line_id} modes are not numbered 1, 2, ..."
                )
            n_shapes = int(shape_mode[shape_line == line_id].max())
            if n_shapes != mode.size:
                raise OutputFormatError(
                    f"{self.path}: LineID {line_id} has {mode.size} frequency rows "
                    f"but {n_shapes} mode shapes"
                )

    @property
    def line_ids(self) -> tuple[int, ...]:
        """Line identifiers in first-appearance order."""
        return tuple(dict.fromkeys(int(value) for value in self.column("LineID")))

    @property
    def has_twist(self) -> bool:
        """Whether the file carries the ``PolarShare`` and ``dTwist`` columns."""
        return "PolarShare" in self.channels

    def _line_column(self, channel: str, line_id: int) -> npt.NDArray[Any]:
        mask = self.column("LineID") == int(line_id)
        if not np.any(mask):
            raise KeyError(
                f"LineID {line_id} is not in {self.path.name}; available: {self.line_ids}"
            )
        values: npt.NDArray[Any] = self.column(channel)[mask].copy()
        return values

    def line(self, line_id: int) -> NaturalModes:
        """Return the frequency and shape rows of one line.

        Parameters
        ----------
        line_id : int
            Line identifier, as in the ``LineID`` column.

        Returns
        -------
        NaturalModes
            New tables holding only that line's rows.

        Raises
        ------
        KeyError
            If the file has no modes for ``line_id``.
        """
        shapes = self.shapes.line(line_id)
        rows = self.values[self.column("LineID") == int(line_id)].copy()
        return NaturalModes(self.path, self.title, self.channels, self.units, rows, shapes)

    def mode_numbers(self, line_id: int) -> tuple[int, ...]:
        """Return the mode numbers of one line, lowest frequency first.

        Parameters
        ----------
        line_id : int
            Line identifier, as in the ``LineID`` column.

        Returns
        -------
        tuple[int, ...]
            Mode numbers ``1, 2, ...``.

        Raises
        ------
        KeyError
            If the file has no modes for ``line_id``.
        """
        return tuple(int(value) for value in self._line_column("Mode", line_id))

    def frequencies(self, line_id: int) -> npt.NDArray[Any]:
        """Return the natural frequencies of one line in Hz, by mode.

        Parameters
        ----------
        line_id : int
            Line identifier, as in the ``LineID`` column.

        Returns
        -------
        numpy.ndarray
            ``(n_modes,)`` array of ``Frequency``.

        Raises
        ------
        KeyError
            If the file has no modes for ``line_id``.
        """
        return self._line_column("Frequency", line_id)

    def periods(self, line_id: int) -> npt.NDArray[Any]:
        """Return the natural periods of one line in s, by mode.

        Parameters
        ----------
        line_id : int
            Line identifier, as in the ``LineID`` column.

        Returns
        -------
        numpy.ndarray
            ``(n_modes,)`` array of ``Period``; 0 for a negative eigenvalue.

        Raises
        ------
        KeyError
            If the file has no modes for ``line_id``.
        """
        return self._line_column("Period", line_id)

    def angular_frequencies(self, line_id: int) -> npt.NDArray[Any]:
        """Return the angular natural frequencies of one line in rad/s, by mode.

        Parameters
        ----------
        line_id : int
            Line identifier, as in the ``LineID`` column.

        Returns
        -------
        numpy.ndarray
            ``(n_modes,)`` array of ``Omega``.

        Raises
        ------
        KeyError
            If the file has no modes for ``line_id``.
        """
        return self._line_column("Omega", line_id)

    def polar_shares(self, line_id: int) -> npt.NDArray[Any]:
        """Return the polar share of the kinetic energy of each mode of one line.

        Parameters
        ----------
        line_id : int
            Line identifier, as in the ``LineID`` column.

        Returns
        -------
        numpy.ndarray
            ``(n_modes,)`` array of ``PolarShare``, 1 for a pure torsional mode;
            zeros in a file without twist angles, as on a line without torsion.

        Raises
        ------
        KeyError
            If the file has no modes for ``line_id``.
        """
        if self.has_twist:
            return self._line_column("PolarShare", line_id)
        return np.zeros_like(self._line_column("Mode", line_id))

    def torsional_modes(self, line_id: int) -> tuple[int, ...]:
        """Return the modes of one line that are mostly torsional.

        Parameters
        ----------
        line_id : int
            Line identifier, as in the ``LineID`` column.

        Returns
        -------
        tuple[int, ...]
            Mode numbers whose ``PolarShare`` is above 0.5, the modes a file
            scales to a unit largest ``dTwist``.

        Raises
        ------
        KeyError
            If the file has no modes for ``line_id``.
        """
        share = self.polar_shares(line_id)
        return tuple(int(mode) for mode in self._line_column("Mode", line_id)[share > 0.5])


_HEADER_FIRST = frozenset({"time", "time(s)", "lineid", "node", "segment"})
_TIME_HEADERS = frozenset({"time", "time(s)"})
# The first columns of the frequency table of a ``.modes.out`` file, and the comment that
# introduces its mode-shape table.
_MODE_FREQUENCY_CHANNELS = ("LineID", "Mode", "Frequency", "Period", "Omega")
_MODE_SHAPE_COMMENT = "# Mode shapes"

# Fortran formatted real output: optional sign, digits with an optional decimal
# point, and an optional exponent. ``ES``/``E`` editing omits the exponent
# letter when a three-digit exponent does not fit (``1.0000000-100``).
_FORTRAN_REAL = re.compile(
    r"(?P<mantissa>[+-]?(?:\d+\.?\d*|\.\d+))(?:[EeDd](?P<exponent>[+-]?\d+)|(?P<bare>[+-]\d+))?",
    re.ASCII,
)


def _parse_float(token: str, path: Path, line_number: int) -> float:
    match = _FORTRAN_REAL.fullmatch(token)
    if match is None:
        if "*" in token:
            raise OutputFormatError(
                f"{path}:{line_number}: overflowed field {token!r} (value exceeds the column width)"
            )
        raise OutputFormatError(f"{path}:{line_number}: nonnumeric value {token!r} in a data row")
    exponent = match.group("exponent") or match.group("bare")
    text = match.group("mantissa") + (f"e{exponent}" if exponent is not None else "")
    value = float(text)
    if not np.isfinite(value):
        raise OutputFormatError(f"{path}:{line_number}: non-finite value {token!r}")
    return value


def _find_header(lines: list[str]) -> int | None:
    """Return the index of the table header row.

    A header starts with a recognized first channel and is followed by a units
    row or a data row with the same number of fields, so a free-text title that
    happens to begin with "Time" is not mistaken for it.
    """
    widths = [len(line.split()) for line in lines]
    candidates = [
        index
        for index, line in enumerate(lines)
        if widths[index] and line.split(maxsplit=1)[0].lower() in _HEADER_FIRST
    ]
    # Width of the next non-blank line after each index, filled in one reverse
    # pass so that many candidate rows cost linear rather than quadratic time.
    following: list[int | None] = [None] * len(lines)
    next_width: int | None = None
    for index in range(len(lines) - 1, -1, -1):
        following[index] = next_width
        if widths[index]:
            next_width = widths[index]
    for index in candidates:
        if following[index] is None or following[index] == widths[index]:
            return index
    return candidates[0] if candidates else None


def _check_not_device(table_path: Path) -> None:
    """Reject a reserved Windows device name, whose read would block on the console."""
    device = windows_device_component(table_path)
    if device is not None:
        raise OutputFormatError(
            f"{table_path}: {device!r} is a reserved Windows device name, not a file"
        )


def _deck_node_comment(title: str, path: Path | None = None) -> npt.NDArray[np.int64] | None:
    """Deck node numbers of a ``# DeckNode`` comment line of a result title, if any."""
    for line in title.splitlines():
        tokens = line.split()
        if len(tokens) >= 2 and tokens[0] == "#" and tokens[1] == "DeckNode":
            try:
                return np.asarray([int(token) for token in tokens[2:]], dtype=np.int64)
            except ValueError as exc:
                raise OutputFormatError(f"{path}: malformed DeckNode line") from exc
    return None


def _read_lines(table_path: Path) -> list[str]:
    """Return the lines of a UTF-8 text output file, failing with OutputFormatError."""
    _check_not_device(table_path)
    try:
        return table_path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as exc:
        raise OutputFormatError(f"cannot read {table_path}: {exc}") from exc


def _unique_channels(channels: tuple[str, ...], source: str) -> tuple[str, ...]:
    """Return ``channels`` with every repeat renamed ``<name>_2``, ``<name>_3``, ...

    OpenFAST OutLists may name a channel twice (the r-test ElastoDyn file lists
    ``TwrBsFzt`` twice), and each copy is a column of the output file. The first
    occurrence keeps its name, so :meth:`OutputTable.column` returns it; the
    k-th occurrence becomes ``<name>_k``, skipping any suffix the file already
    uses. A :class:`UserWarning` names every renamed column.
    """
    if len(set(channels)) == len(channels):
        return channels
    taken = set(channels)
    occurrences: dict[str, int] = {}
    unique: list[str] = []
    renamed: list[str] = []
    for name in channels:
        occurrences[name] = occurrences.get(name, 0) + 1
        if occurrences[name] == 1:
            unique.append(name)
            continue
        suffix = occurrences[name]
        while f"{name}_{suffix}" in taken:
            suffix += 1
        candidate = f"{name}_{suffix}"
        taken.add(candidate)
        unique.append(candidate)
        renamed.append(f"{name} -> {candidate}")
    warnings.warn(
        f"{source}: repeated channel names kept as separate columns ({', '.join(renamed)}); "
        "column(name) returns the first occurrence",
        UserWarning,
        stacklevel=3,
    )
    return tuple(unique)


def _read_units(
    table_path: Path, lines: list[str], cursor: int, channels: tuple[str, ...]
) -> tuple[tuple[str, ...] | None, int]:
    """Return the units row at ``cursor``, if there is one, and the index of the first data row."""
    if cursor < len(lines):
        tokens = tuple(lines[cursor].split())
        if tokens and all(token.startswith("(") and token.endswith(")") for token in tokens):
            if len(tokens) != len(channels):
                raise OutputFormatError(
                    f"{table_path}:{cursor + 1}: expected {len(channels)} units, got {len(tokens)}"
                )
            return tokens, cursor + 1
    return None, cursor


def _read_rows(
    table_path: Path, lines: list[str], start: int, stop: int, channels: tuple[str, ...]
) -> list[list[float]]:
    """Parse the data rows ``lines[start:stop]``, one finite value per channel."""
    rows: list[list[float]] = []
    for i in range(start, stop):
        fields = lines[i].split()
        if not fields:
            continue
        if len(fields) != len(channels):
            raise OutputFormatError(
                f"{table_path}:{i + 1}: expected {len(channels)} fields, got {len(fields)}"
            )
        rows.append([_parse_float(field, table_path, i + 1) for field in fields])
    return rows


def _read_natural_modes(
    table_path: Path,
    lines: list[str],
    header_index: int,
    channels: tuple[str, ...],
    title: str,
) -> NaturalModes:
    """Read the frequency table at ``header_index`` and the mode-shape table after it."""
    units, cursor = _read_units(table_path, lines, header_index + 1, channels)
    comment = next(
        (i for i in range(cursor, len(lines)) if lines[i].startswith(_MODE_SHAPE_COMMENT)),
        None,
    )
    if comment is None or comment + 1 >= len(lines):
        raise OutputFormatError(f"{table_path}: modal output has no mode-shape table")
    rows = _read_rows(table_path, lines, cursor, comment, channels)
    shape_channels = tuple(lines[comment + 1].split())
    if len(shape_channels) != len(set(shape_channels)):
        raise OutputFormatError(f"{table_path}:{comment + 2}: duplicate channel name")
    shape_units, shape_cursor = _read_units(table_path, lines, comment + 2, shape_channels)
    shape_rows = _read_rows(table_path, lines, shape_cursor, len(lines), shape_channels)
    shapes = ModeShapes(
        table_path,
        lines[comment],
        shape_channels,
        shape_units,
        np.asarray(shape_rows, dtype=np.float64).reshape(-1, len(shape_channels)),
    )
    return NaturalModes(
        table_path,
        title,
        channels,
        units,
        np.asarray(rows, dtype=np.float64).reshape(-1, len(channels)),
        shapes,
    )


def read_output(path: str | os.PathLike[str]) -> OutputTable:
    """Read and strictly validate a CableDyn numeric output table.

    Fortran-formatted numbers (including ``D`` exponents) are accepted. Every
    data row must have one finite value per channel. A time history that repeats
    a channel name (as an OpenFAST OutList may) keeps every column: repeats are
    renamed ``<name>_2``, ``<name>_3``, ... with a :class:`UserWarning`. Other
    layouts reject a repeated name.

    Parameters
    ----------
    path : str | os.PathLike
        Output file to read.

    Returns
    -------
    OutputTable
        A :class:`TimeHistory`, :class:`LineNodeHistory`,
        :class:`LineSegmentHistory`, :class:`StaticProfile`, or
        :class:`NaturalModes` when the layout is recognized, otherwise a plain
        :class:`OutputTable`.

    Raises
    ------
    OutputFormatError
        If the file cannot be read, has no recognized header, or holds a
        truncated, overflowed, non-numeric, or non-finite value.
    """
    table_path = Path(path).expanduser().resolve()
    lines = _read_lines(table_path)
    if not lines:
        raise OutputFormatError(f"{table_path}: empty output")

    header_index = _find_header(lines)
    if header_index is None:
        raise OutputFormatError(
            f"{table_path}: no recognized Time(s), LineID, Node, or Segment table header"
        )

    channels = tuple(lines[header_index].split())
    if channels[0].lower() in _TIME_HEADERS:
        # A time history may repeat a channel (an OpenFAST OutList can); keep every column.
        channels = _unique_channels(channels, f"{table_path}:{header_index + 1}")
    elif len(channels) != len(set(channels)):
        raise OutputFormatError(f"{table_path}:{header_index + 1}: duplicate channel name")
    title = "\n".join(line for line in lines[:header_index] if line.strip())
    if channels[: len(_MODE_FREQUENCY_CHANNELS)] == _MODE_FREQUENCY_CHANNELS:
        return _read_natural_modes(table_path, lines, header_index, channels, title)
    units, cursor = _read_units(table_path, lines, header_index + 1, channels)
    rows = _read_rows(table_path, lines, cursor, len(lines), channels)
    if not rows:
        raise OutputFormatError(f"{table_path}: table has no data rows")
    values = np.asarray(rows, dtype=np.float64)
    first = channels[0].lower()
    if first in {"time", "time(s)"}:
        remaining = channels[1:]
        # A VIV lift file (.Line<L>.V.out, Node<i>LiftX/Y/Z in N) is a plain time history.
        lift_like = bool(remaining) and all(_LIFT_CHANNEL.fullmatch(c) for c in remaining)
        node_like = (
            not lift_like
            and remaining
            and (
                any(_NODE_CHANNEL.fullmatch(channel) for channel in remaining)
                or all(channel.startswith("Node") for channel in remaining)
                or re.search(r"\.Line[1-9][0-9]*\.p\.out$", table_path.name) is not None
            )
        )
        segment_like = remaining and (
            any(_SEGMENT_CHANNEL.fullmatch(channel) for channel in remaining)
            or all(channel.startswith("Segment") for channel in remaining)
            or re.search(r"\.Line[1-9][0-9]*\.t\.out$", table_path.name) is not None
        )
        table_type: type[OutputTable]
        if node_like:
            table_type = LineNodeHistory
        elif segment_like:
            table_type = LineSegmentHistory
        else:
            table_type = TimeHistory
    elif {"LineID", "Node", "ArcLength"}.issubset(channels):
        table_type = StaticProfile
    else:
        table_type = OutputTable
    return table_type(table_path, title, channels, units, values)
