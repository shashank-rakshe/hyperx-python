# SPDX-License-Identifier: Apache-2.0
"""Summary tables of channels and lines.

* :func:`channel_summary` -- per-channel statistics with the time of each
  extreme.
* :func:`line_summary` -- per-line extremes: tension (with time and
  location), curvature, and seabed clearance.
* :class:`SummaryTable` -- an ordered collection of such records (or of any
  dataclass records, such as :meth:`cabledyn.StaticProfile.summaries`), with
  conversion to plain dictionaries, a pandas DataFrame, and CSV.

Records are frozen dataclasses of plain Python values, so they serialize
directly. An extreme that the given results cannot provide is ``None``.
"""

from __future__ import annotations

import dataclasses
import os
from collections.abc import Iterable, Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Generic, TypeVar

import numpy as np
import numpy.typing as npt

from cabledyn._csv import number, write_csv
from cabledyn.clearance import Bathymetry, seabed_clearance
from cabledyn.formats import MoorDynLineHistory
from cabledyn.profiles import (
    LineField,
    LocationSource,
    PositionSource,
    _own_locator,
    _place,
    line_field,
    line_positions,
)
from cabledyn.results import (
    LineNodeHistory,
    LineSegmentHistory,
    StaticProfile,
    TimeHistory,
)

__all__ = [
    "ChannelSummary",
    "LineSummary",
    "SummaryTable",
    "channel_summary",
    "line_summary",
]

RecordT = TypeVar("RecordT")


@dataclass(frozen=True)
class SummaryTable(Generic[RecordT]):
    """An ordered table of dataclass records of one type.

    Attributes
    ----------
    records : tuple
        The records, one per row. The columns are the record's fields.

    Raises
    ------
    TypeError
        If a record is not a dataclass instance or the records differ in type.
    """

    records: tuple[RecordT, ...]

    def __post_init__(self) -> None:
        records = tuple(self.records)
        kinds = {type(record) for record in records}
        if len(kinds) > 1:
            raise TypeError("summary records must all have the same type")
        if any(
            not dataclasses.is_dataclass(record) or isinstance(record, type) for record in records
        ):
            raise TypeError("summary records must be dataclass instances")
        object.__setattr__(self, "records", records)

    def __len__(self) -> int:
        return len(self.records)

    def __iter__(self) -> Iterator[RecordT]:
        return iter(self.records)

    def __getitem__(self, index: int) -> RecordT:
        return self.records[index]

    @property
    def columns(self) -> tuple[str, ...]:
        """Field names of the records, in declaration order; empty for no records."""
        if not self.records:
            return ()
        return tuple(field.name for field in dataclasses.fields(self.records[0]))  # type: ignore[arg-type]

    def column(self, name: str) -> tuple[Any, ...]:
        """Return the values of one field, one per record.

        Raises
        ------
        KeyError
            If no record field has that name.
        """
        if name not in self.columns:
            raise KeyError(f"{name!r} is not a column; available: {', '.join(self.columns)}")
        return tuple(getattr(record, name) for record in self.records)

    def to_records(self) -> list[dict[str, Any]]:
        """Return one ``{field: value}`` dictionary per record."""
        return [{name: getattr(record, name) for name in self.columns} for record in self.records]

    def to_dataframe(self) -> Any:
        """Return the table as a pandas DataFrame, one row per record.

        Raises
        ------
        ImportError
            If pandas is not installed.
        """
        try:
            import pandas as pd
        except ImportError as exc:  # pragma: no cover - depends on the optional environment
            raise ImportError(
                "pandas is required for to_dataframe(); install 'cabledyn[dataframe]'"
            ) from exc
        return pd.DataFrame(self.to_records(), columns=list(self.columns))

    def export(self, path: str | os.PathLike[str], *, overwrite: bool = False) -> Path:
        """Atomically write the table as CSV, one row per record.

        Floats are written with full precision, ``None`` as a blank field.

        Parameters
        ----------
        path : str | os.PathLike
            Target CSV file; missing parent directories are created.
        overwrite : bool
            Replace an existing file instead of raising :class:`FileExistsError`.

        Returns
        -------
        pathlib.Path
            Absolute path of the written file.

        Raises
        ------
        ValueError
            If the table has no record.
        """
        if not self.records:
            raise ValueError("an empty summary table has no columns to export")

        def cell(value: Any) -> str:
            if value is None:
                return ""
            if isinstance(value, (float, np.floating)):
                return number(float(value))
            return str(value)

        rows = (tuple(cell(getattr(record, name)) for name in self.columns) for record in self)
        return write_csv(path, self.columns, rows, overwrite=overwrite)


@dataclass(frozen=True)
class ChannelSummary:
    """Statistics of one time-history channel with the time of its extremes.

    Attributes
    ----------
    channel : str
        Channel name.
    unit : str | None
        Channel unit, or ``None`` if unknown.
    count : int
        Number of samples.
    minimum, maximum : float
        Extreme values.
    minimum_time, maximum_time : float
        Time of the first occurrence of each extreme, in seconds.
    mean : float
        Arithmetic mean.
    standard_deviation : float
        Population standard deviation.
    rms : float
        Root-mean-square value.
    """

    channel: str
    unit: str | None
    count: int
    minimum: float
    minimum_time: float
    maximum: float
    maximum_time: float
    mean: float
    standard_deviation: float
    rms: float


def channel_summary(
    history: TimeHistory,
    channels: str | Iterable[str] | None = None,
    *,
    start: float | None = None,
    stop: float | None = None,
) -> SummaryTable[ChannelSummary]:
    """Return per-channel statistics with the time of each extreme.

    Parameters
    ----------
    history : TimeHistory
        Any time history.
    channels : str | collections.abc.Iterable[str] | None
        One channel, several, or ``None`` for every channel except time.
    start, stop : float | None
        Optional time window, in seconds.

    Returns
    -------
    SummaryTable[ChannelSummary]
        One record per channel, in the requested order.

    Raises
    ------
    KeyError
        If a channel is not in the history.
    ValueError
        If the window is invalid or empty.
    """
    view = history.period(start, stop) if start is not None or stop is not None else history
    if channels is None:
        selected = tuple(name for name in view.channels if name != view.time_channel)
    elif isinstance(channels, str):
        selected = (channels,)
    else:
        selected = tuple(channels)
    time = view.time
    records = []
    for channel in selected:
        data = view.column(channel)
        low, high = int(np.argmin(data)), int(np.argmax(data))
        records.append(
            ChannelSummary(
                channel=channel,
                unit=view.unit(channel),
                count=int(data.size),
                minimum=float(data[low]),
                minimum_time=float(time[low]),
                maximum=float(data[high]),
                maximum_time=float(time[high]),
                mean=float(np.mean(data)),
                standard_deviation=float(np.std(data)),
                rms=float(np.sqrt(np.mean(data * data))),
            )
        )
    return SummaryTable(tuple(records))


@dataclass(frozen=True)
class LineSummary:
    """Extremes of one line over a run or a static configuration.

    Locations are arc lengths from End A in metres when node positions are
    available (``location_kind`` ``"ArcLength"``), otherwise node or segment
    numbers. Times are ``None`` for a static result. Every field of a
    quantity that was not supplied is ``None``. The time window is that of the
    first quantity summarized (tension, curvature, then clearance).

    Attributes
    ----------
    name : str
        Line name.
    start_time, end_time : float | None
        First and last sample time summarized, in seconds.
    sample_count : int
        Number of samples summarized (1 for a static result).
    maximum_tension, minimum_tension : float | None
        Tension extremes over the line and the run, in newtons.
    maximum_tension_time, minimum_tension_time : float | None
        Times of the tension extremes, in seconds.
    maximum_tension_location, minimum_tension_location : float | None
        Locations of the tension extremes.
    tension_location_kind : str | None
        ``"ArcLength"``, ``"Node"``, or ``"Segment"``.
    maximum_curvature : float | None
        Largest curvature, in 1/m.
    maximum_curvature_time : float | None
        Time of the largest curvature, in seconds.
    maximum_curvature_location : float | None
        Location of the largest curvature.
    curvature_location_kind : str | None
        ``"ArcLength"`` or ``"Node"``.
    minimum_bend_radius : float | None
        Reciprocal of ``maximum_curvature``, in metres (infinite for zero
        curvature).
    minimum_seabed_clearance : float | None
        Smallest node clearance above the seabed, in metres.
    minimum_seabed_clearance_time : float | None
        Time of the smallest clearance, in seconds.
    minimum_seabed_clearance_arc_length : float | None
        Arc length of the smallest clearance at that time, in metres.
    """

    name: str
    start_time: float | None
    end_time: float | None
    sample_count: int
    maximum_tension: float | None = None
    maximum_tension_time: float | None = None
    maximum_tension_location: float | None = None
    minimum_tension: float | None = None
    minimum_tension_time: float | None = None
    minimum_tension_location: float | None = None
    tension_location_kind: str | None = None
    maximum_curvature: float | None = None
    maximum_curvature_time: float | None = None
    maximum_curvature_location: float | None = None
    curvature_location_kind: str | None = None
    minimum_bend_radius: float | None = None
    minimum_seabed_clearance: float | None = None
    minimum_seabed_clearance_time: float | None = None
    minimum_seabed_clearance_arc_length: float | None = None


def _needs_line_id(source: Any, line_id: int | None) -> int | None:
    """Pass ``line_id`` only to sources that select a line with it."""
    if isinstance(source, StaticProfile):
        return line_id
    per_line = (LineNodeHistory, LineSegmentHistory, MoorDynLineHistory)
    if isinstance(source, TimeHistory) and not isinstance(source, per_line):
        return line_id
    return None


def _extreme(
    field: LineField, locate: LocationSource, line_id: int | None, largest: bool
) -> tuple[float, float | None, float, str]:
    """Value, time, location, and location kind of one field extreme."""
    values = field.values
    flat = int(np.argmax(values) if largest else np.argmin(values))
    sample, index = np.unravel_index(flat, values.shape)
    when = None if field.time is None else float(field.time[sample])
    kind, location = _place(field, locate, when, "linear", line_id)
    return float(values[sample, index]), when, float(location[index]), kind


def line_summary(
    name: str,
    *,
    positions: PositionSource | None = None,
    tensions: PositionSource | None = None,
    curvature: PositionSource | None = None,
    seabed: float | Bathymetry | None = None,
    line_id: int | None = None,
    radius: float = 0.0,
    start: float | None = None,
    stop: float | None = None,
) -> LineSummary:
    """Return the tension, curvature, and seabed-clearance extremes of one line.

    Parameters
    ----------
    name : str
        Line name recorded in the summary.
    positions : object | None
        Node positions (any source accepted by :func:`cabledyn.line_positions`),
        used to place extremes along the line and for the seabed clearance.
    tensions : object | None
        A source of the ``tension`` quantity (see :func:`cabledyn.line_field`):
        a per-line tension file, a main output with ``Ten<L>N<J>`` channels, a
        MoorDyn-F line file, or a static profile.
    curvature : object | None
        A source of the ``curvature`` quantity: a main output with
        ``Curv<L>N<J>`` channels, a MoorDyn-F line file with ``Kurv``, or a
        static profile.
    seabed : float | Bathymetry | None
        Seabed for the clearance (see :func:`cabledyn.seabed_clearance`);
        needs ``positions``.
    line_id : int | None
        Line to take from a main output or a multi-line static profile; used
        only for those sources.
    radius : float
        Radius subtracted from the seabed clearance, in metres.
    start, stop : float | None
        Optional time window, in seconds.

    Returns
    -------
    LineSummary
        The extremes of the supplied quantities.

    Raises
    ------
    KeyError
        If a source does not record its quantity for the line.
    ValueError
        If nothing is supplied, ``seabed`` is given without ``positions``, or
        a window, ``line_id``, or placement is invalid.
    """
    if positions is None and tensions is None and curvature is None:
        raise ValueError("line_summary needs positions, tensions, or curvature")
    if seabed is not None and positions is None:
        raise ValueError("a seabed clearance needs the node positions")
    windows: list[tuple[float | None, float | None, int]] = []
    fields: dict[str, Any] = {}

    def locator(source: Any) -> LocationSource:
        return positions if positions is not None else _own_locator(source)

    for quantity, source in (("tension", tensions), ("curvature", curvature)):
        if source is None:
            continue
        field = line_field(source, quantity, line_id=_needs_line_id(source, line_id))
        field = field.period(start, stop)
        windows.append(_span(field.time))
        high = _extreme(field, locator(source), line_id, True)
        fields[f"maximum_{quantity}"] = high[0]
        fields[f"maximum_{quantity}_time"] = high[1]
        fields[f"maximum_{quantity}_location"] = high[2]
        fields[f"{quantity}_location_kind"] = high[3]
        if quantity == "tension":
            low = _extreme(field, locator(source), line_id, False)
            fields.update(
                minimum_tension=low[0], minimum_tension_time=low[1], minimum_tension_location=low[2]
            )
        else:
            fields["minimum_bend_radius"] = 1.0 / high[0] if high[0] > 0.0 else float("inf")
    if seabed is not None:
        assert positions is not None
        clearance = seabed_clearance(
            positions,
            seabed,
            line_id=_needs_line_id(positions, line_id),
            radius=radius,
            start=start,
            stop=stop,
        )
        windows.append(_span(clearance.time))
        fields.update(
            minimum_seabed_clearance=clearance.minimum,
            minimum_seabed_clearance_time=clearance.minimum_time,
            minimum_seabed_clearance_arc_length=clearance.minimum_arc_length,
        )
    if not windows:
        assert positions is not None
        windows.append(
            _span(
                line_positions(positions, line_id=_needs_line_id(positions, line_id))
                .period(start, stop)
                .time
            )
        )
    first, last, count = windows[0]
    return LineSummary(name=name, start_time=first, end_time=last, sample_count=count, **fields)


def _span(time: npt.NDArray[Any] | None) -> tuple[float | None, float | None, int]:
    if time is None:
        return None, None, 1
    return float(time[0]), float(time[-1]), int(time.size)
