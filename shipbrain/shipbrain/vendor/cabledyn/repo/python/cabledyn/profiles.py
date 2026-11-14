# SPDX-License-Identifier: Apache-2.0
"""Line node positions, per-location result fields, and profiles at one time.

These are the building blocks of linked "results at time t" views: pick a
line and a time, and get any per-node or per-segment variable against arc
length.

* :func:`line_positions` collects the ``(n_samples, n_nodes, 3)`` node
  positions of one line from any result that records them.
* :func:`line_field` collects one per-node or per-segment variable of one line
  as an ``(n_samples, n_locations)`` array.
* :func:`profile_at` and :func:`profiles_at` evaluate fields at one time (the
  nearest sample or linear interpolation between samples) and place them along
  the line: at the node arc lengths for node variables and at the segment
  mid-arc lengths for segment variables.
* :func:`line_range_graph` builds the range graph (minimum, maximum, and mean
  along the line) of any of these variables.

Supported sources are a CableDyn per-line position file
(:class:`~cabledyn.LineNodeHistory`), a per-line tension file
(:class:`~cabledyn.LineSegmentHistory`), the node channels of a main output
(``Ten<L>N<J>``, ``Curv<L>N<J>``, ``BendMom<L>N<J>``, ``L<L>N<J>p[xyz]``,
``v[xyz]``, ``a[xyz]``, ``Dec``, ``Azi``), a MoorDyn-F per-line file
(:class:`~cabledyn.MoorDynLineHistory`), a static profile
(:class:`~cabledyn.StaticProfile`), the static per-line ``Node``/``X(m)``/``Y(m)``/
``Z(m)`` and ``Segment``/``Tension(N)`` tables, and plain arrays. A static
source has no time axis: its fields hold a single sample and ``time`` is
``None``.

Arc length is the deformed arc length from End A: the ``ArcLength`` column of
a static profile, otherwise the cumulative straight node-to-node distance at
the requested time.

The node channels of a main output number deck nodes (1 at End A to 1 + the
total ``NumSegs`` of the line's sections at End B); a static profile and the
per-line files list every node of the line's final mesh. The two differ on a
finite-EI line whose mesh the static solve refined: a static profile then
places main-output node channels at the rows its ``DeckNode`` column names,
and a per-line position file ``<root>.Line<L>.p.out`` (also as the ``source``
of :class:`~cabledyn.LinePositions`) at the nodes its ``# DeckNode`` line names. Plain
position arrays carry no such map: they are taken as numbered by deck node, so
pass the in-process mesh positions of a refined line
(:meth:`cabledyn.objects.Line.values`) together with
:attr:`cabledyn.objects.Line.deck_nodes`, for example as a ``{node: arc}``
mapping.
"""

from __future__ import annotations

import os
import re
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal, TypeAlias

import numpy as np
import numpy.typing as npt

from cabledyn._csv import number, write_csv
from cabledyn._optional import pyplot
from cabledyn.formats import MoorDynLineHistory
from cabledyn.ranges import RangeGraph
from cabledyn.results import (
    LineNodeHistory,
    LineSegmentHistory,
    OutputTable,
    StaticProfile,
    TimeHistory,
    _deck_node_comment,
    read_output,
)

__all__ = [
    "ArcProfile",
    "LineField",
    "LinePositions",
    "available_quantities",
    "line_field",
    "line_positions",
    "line_range_graph",
    "profile_at",
    "profiles_at",
]

Interpolation = Literal["linear", "nearest"]

_MAIN_DEMAND = re.compile(r"(Ten|Curv|BendMom)0*([1-9][0-9]{0,8})N0*([1-9][0-9]{0,8})", re.I)
_MAIN_KINEMATIC = re.compile(
    r"L0*([1-9][0-9]{0,8})N0*([1-9][0-9]{0,8})(p[xyz]|v[xyz]|a[xyz]|Dec|Azi)", re.I
)
_MOORDYN_NODE = re.compile(r"Node(0|[1-9][0-9]{0,8})([pvaUDbV][xyz]|Wz|Kurv)")
_MOORDYN_SEGMENT = re.compile(r"Seg([1-9][0-9]{0,8})(Ten|Dmp|Str|SRt|Lst)")
_LINE_NODE = re.compile(r"Node([1-9][0-9]{0,8})([XYZ])\(([^()]*)\)")
# The line of a per-line result file: <root>.Line<L>.<kind>.out or <root>.MD.Line<N>.out
_FILE_LINE = re.compile(r"\.Line0*([1-9][0-9]{0,8})\.", re.IGNORECASE)


def _file_line_id(path: Path | None) -> int | None:
    """Return the line id a per-line result file name carries, if any."""
    match = None if path is None else _FILE_LINE.search(path.name)
    return None if match is None else int(match.group(1))


# main-output code -> (canonical quantity, default unit)
_MAIN_NAMES: dict[str, tuple[str, str]] = {
    "ten": ("tension", "N"),
    "curv": ("curvature", "1/m"),
    "bendmom": ("bend_moment", "N-m"),
    "px": ("x", "m"),
    "py": ("y", "m"),
    "pz": ("z", "m"),
    "vx": ("vx", "m/s"),
    "vy": ("vy", "m/s"),
    "vz": ("vz", "m/s"),
    "ax": ("ax", "m/s^2"),
    "ay": ("ay", "m/s^2"),
    "az": ("az", "m/s^2"),
    "dec": ("declination", "deg"),
    "azi": ("azimuth", "deg"),
}
# MoorDyn code -> canonical quantity (other codes keep their MoorDyn spelling)
_MOORDYN_NAMES = {
    "px": "x",
    "py": "y",
    "pz": "z",
    "Kurv": "curvature",
    "Ten": "tension",
}


def _readonly(values: npt.ArrayLike, dtype: Any = np.float64) -> npt.NDArray[Any]:
    result = np.array(values, dtype=dtype, copy=True)
    result.setflags(write=False)
    return result


def _key(name: str) -> str:
    """Normalize a quantity name for matching: lower case, no underscores or spaces."""
    return name.lower().replace("_", "").replace(" ", "")


def _snake(name: str) -> str:
    """``BendMoment`` -> ``bend_moment``; ``X`` -> ``x``."""
    return re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "_", name).lower()


def _finite_time(time: float) -> float:
    value = float(time)
    if not np.isfinite(value):
        raise ValueError("time must be finite")
    return value


def _validate_time(time: npt.NDArray[Any] | None, samples: int) -> npt.NDArray[Any] | None:
    if time is None:
        if samples != 1:
            raise ValueError("a static result (time None) holds exactly one sample")
        return None
    array = _readonly(time)
    if array.ndim != 1 or array.size != samples or array.size == 0:
        raise ValueError("time must be a non-empty one-dimensional array with one entry per sample")
    if not np.all(np.isfinite(array)) or np.any(np.diff(array) <= 0.0):
        raise ValueError("time must be finite and strictly increasing")
    return array


def _sample_weights(
    time: npt.NDArray[Any], requested: float, interpolation: str
) -> tuple[int, int, float]:
    """Return the two bracketing sample indices and the weight of the second."""
    value = _finite_time(requested)
    if value < time[0] or value > time[-1]:
        raise ValueError(f"time {value:g} is outside [{time[0]:g}, {time[-1]:g}]")
    if time.size == 1:
        return 0, 0, 0.0
    if interpolation == "nearest":
        index = int(np.argmin(np.abs(time - value)))
        return index, index, 0.0
    upper = int(np.clip(np.searchsorted(time, value, side="right"), 1, time.size - 1))
    lower = upper - 1
    weight = (value - time[lower]) / (time[upper] - time[lower])
    return lower, upper, float(weight)


def _window(time: npt.NDArray[Any], start: float | None, stop: float | None) -> npt.NDArray[Any]:
    """Boolean mask of samples in the closed interval ``[start, stop]``."""
    if start is not None:
        start = _finite_time(start)
    if stop is not None:
        stop = _finite_time(stop)
    if start is not None and stop is not None and start > stop:
        raise ValueError("window start must not exceed stop")
    mask = np.ones(time.shape, dtype=bool)
    if start is not None:
        mask &= time >= start
    if stop is not None:
        mask &= time <= stop
    if not np.any(mask):
        raise ValueError("no sample lies in the requested window")
    return mask


@dataclass(frozen=True)
class LinePositions:
    """Node positions of one line over time, in End-A-to-End-B order.

    Attributes
    ----------
    time : numpy.ndarray | None
        ``(n_samples,)`` strictly increasing sample times in seconds, or
        ``None`` for a static configuration (one sample).
    positions : numpy.ndarray
        ``(n_samples, n_nodes, 3)`` node coordinates in metres.
    node_ids : numpy.ndarray
        ``(n_nodes,)`` node numbers as the source names them (one-based for
        CableDyn, ``0`` for End A of a MoorDyn line).
    source : pathlib.Path | None
        Result file the positions were read from, if any.
    line_id : int | None
        Line of a multi-line ``source`` (a static profile) the positions were
        taken from, if any; it selects that line's deck-node map.

    Raises
    ------
    ValueError
        If the arrays are not finite, their shapes disagree, the line has no
        node, or time does not strictly increase.
    """

    time: npt.NDArray[Any] | None
    positions: npt.NDArray[Any]
    node_ids: npt.NDArray[Any]
    source: Path | None = None
    line_id: int | None = None

    def __post_init__(self) -> None:
        positions = _readonly(self.positions)
        if positions.ndim != 3 or positions.shape[2] != 3 or 0 in positions.shape[:2]:
            raise ValueError("positions must be a non-empty (n_samples, n_nodes, 3) array")
        if not np.all(np.isfinite(positions)):
            raise ValueError("positions must be finite")
        object.__setattr__(self, "positions", positions)
        object.__setattr__(self, "time", _validate_time(self.time, positions.shape[0]))
        node_ids = _readonly(self.node_ids, np.int64)
        if node_ids.shape != (positions.shape[1],):
            raise ValueError("node_ids must hold one identifier per node")
        object.__setattr__(self, "node_ids", node_ids)
        if self.source is not None:
            object.__setattr__(self, "source", Path(self.source).expanduser().resolve())

    @property
    def static(self) -> bool:
        """True for a static configuration without a time axis."""
        return self.time is None

    @property
    def sample_count(self) -> int:
        """Number of time samples (1 for a static configuration)."""
        return int(self.positions.shape[0])

    @property
    def node_count(self) -> int:
        """Number of nodes."""
        return int(self.positions.shape[1])

    @property
    def arc_length(self) -> npt.NDArray[Any]:
        """Read-only ``(n_samples, n_nodes)`` cumulative chord length from End A, in m."""
        chords = np.linalg.norm(np.diff(self.positions, axis=1), axis=2)
        zeros = np.zeros((self.sample_count, 1))
        return _readonly(np.concatenate((zeros, np.cumsum(chords, axis=1)), axis=1))

    def at(
        self, time: float | None = None, *, interpolation: Interpolation = "linear"
    ) -> npt.NDArray[Any]:
        """Return the ``(n_nodes, 3)`` node positions at one time.

        Parameters
        ----------
        time : float | None
            Time in seconds; must be ``None`` for a static configuration and
            given otherwise.
        interpolation : {"linear", "nearest"}
            Linear interpolation between the bracketing samples, or the
            nearest sample (the earlier one on a tie).

        Returns
        -------
        numpy.ndarray
            Read-only ``(n_nodes, 3)`` coordinates in metres.

        Raises
        ------
        ValueError
            If ``time`` is missing, not applicable, not finite, or outside the
            record, or ``interpolation`` is unknown.
        """
        return _at(self.time, self.positions, time, interpolation)

    def arc_length_at(
        self, time: float | None = None, *, interpolation: Interpolation = "linear"
    ) -> npt.NDArray[Any]:
        """Return the ``(n_nodes,)`` arc length from End A of the positions at one time.

        The arc length is the cumulative chord length of the node positions
        returned by :meth:`at`, in metres.

        Raises
        ------
        ValueError
            As for :meth:`at`.
        """
        return _readonly(_cumulative_arc(self.at(time, interpolation=interpolation)))

    def period(self, start: float | None = None, stop: float | None = None) -> LinePositions:
        """Return the samples in the closed interval ``[start, stop]``.

        A static configuration is returned unchanged.

        Raises
        ------
        ValueError
            If a limit is not finite, ``start`` exceeds ``stop``, or no sample
            lies in the interval.
        """
        if self.time is None or (start is None and stop is None):
            return self
        mask = _window(self.time, start, stop)
        return LinePositions(
            self.time[mask], self.positions[mask], self.node_ids, self.source, self.line_id
        )


def _at(
    time: npt.NDArray[Any] | None,
    values: npt.NDArray[Any],
    requested: float | None,
    interpolation: str,
) -> npt.NDArray[Any]:
    """Evaluate a ``(n_samples, ...)`` array at one time."""
    if interpolation not in {"linear", "nearest"}:
        raise ValueError("interpolation must be 'linear' or 'nearest'")
    if time is None:
        if requested is not None:
            raise ValueError("time does not apply to a static result")
        return _readonly(values[0])
    if requested is None:
        raise ValueError("a time history needs the time of the profile")
    lower, upper, weight = _sample_weights(time, requested, interpolation)
    return _readonly((1.0 - weight) * values[lower] + weight * values[upper])


@dataclass(frozen=True)
class LineField:
    """One per-node or per-segment variable of one line over time.

    Attributes
    ----------
    quantity : str
        Canonical quantity name, for example ``"tension"`` or ``"z"``.
    unit : str | None
        Unit of the values, or ``None`` if unknown.
    location_kind : str
        ``"Node"`` or ``"Segment"``.
    ids : numpy.ndarray
        ``(n_locations,)`` node or segment numbers as the source names them,
        in End-A-to-End-B order.
    time : numpy.ndarray | None
        ``(n_samples,)`` sample times in seconds, or ``None`` for a static
        result.
    values : numpy.ndarray
        ``(n_samples, n_locations)`` values.
    source : pathlib.Path | None
        Result file the field was read from, if any.
    deck_nodes : bool
        True when :attr:`ids` are deck node numbers, as the node channels of a
        main output name them (1 at End A to 1 + the total ``NumSegs`` of the
        line's sections at End B); false when they number the nodes of the
        source's own mesh, as a static profile and the per-line files do. The
        two differ on a finite-EI line whose mesh the static solve refined.

    Raises
    ------
    ValueError
        If the arrays are not finite or their shapes disagree, the location
        kind is unknown, or time does not strictly increase.
    """

    quantity: str
    unit: str | None
    location_kind: str
    ids: npt.NDArray[Any]
    time: npt.NDArray[Any] | None
    values: npt.NDArray[Any]
    source: Path | None = None
    deck_nodes: bool = False

    def __post_init__(self) -> None:
        if self.location_kind not in {"Node", "Segment"}:
            raise ValueError("location_kind must be 'Node' or 'Segment'")
        values = _readonly(self.values)
        if values.ndim != 2 or 0 in values.shape or not np.all(np.isfinite(values)):
            raise ValueError("values must be a finite, non-empty (n_samples, n_locations) array")
        object.__setattr__(self, "values", values)
        object.__setattr__(self, "time", _validate_time(self.time, values.shape[0]))
        ids = _readonly(self.ids, np.int64)
        if ids.shape != (values.shape[1],):
            raise ValueError("ids must hold one identifier per location")
        object.__setattr__(self, "ids", ids)
        if self.source is not None:
            object.__setattr__(self, "source", Path(self.source).expanduser().resolve())

    @property
    def static(self) -> bool:
        """True for a static result without a time axis."""
        return self.time is None

    def at(
        self, time: float | None = None, *, interpolation: Interpolation = "linear"
    ) -> npt.NDArray[Any]:
        """Return the ``(n_locations,)`` values at one time.

        Parameters
        ----------
        time : float | None
            Time in seconds; must be ``None`` for a static result and given
            otherwise.
        interpolation : {"linear", "nearest"}
            Linear interpolation between the bracketing samples, or the
            nearest sample (the earlier one on a tie).

        Returns
        -------
        numpy.ndarray
            Read-only values, in :attr:`unit`.

        Raises
        ------
        ValueError
            If ``time`` is missing, not applicable, not finite, or outside the
            record, or ``interpolation`` is unknown.
        """
        return _at(self.time, self.values, time, interpolation)

    def period(self, start: float | None = None, stop: float | None = None) -> LineField:
        """Return the samples in the closed interval ``[start, stop]``.

        A static result is returned unchanged.

        Raises
        ------
        ValueError
            If a limit is not finite, ``start`` exceeds ``stop``, or no sample
            lies in the interval.
        """
        if self.time is None or (start is None and stop is None):
            return self
        mask = _window(self.time, start, stop)
        return LineField(
            self.quantity,
            self.unit,
            self.location_kind,
            self.ids,
            self.time[mask],
            self.values[mask],
            self.source,
            self.deck_nodes,
        )


@dataclass(frozen=True)
class ArcProfile:
    """One variable along one line at one time.

    Attributes
    ----------
    quantity : str
        Canonical quantity name.
    unit : str | None
        Unit of :attr:`values`, or ``None`` if unknown.
    location_kind : str
        ``"ArcLength"`` (``location`` in metres from End A), ``"Node"``, or
        ``"Segment"`` (``location`` is the node or segment number).
    location : numpy.ndarray
        ``(n,)`` non-decreasing locations.
    ids : numpy.ndarray
        ``(n,)`` node or segment numbers of the values.
    values : numpy.ndarray
        ``(n,)`` values.
    time : float | None
        Time of the profile in seconds, or ``None`` for a static result.
    source : pathlib.Path | None
        Result file of the values, if any.
    id_kind : str
        ``"Node"`` or ``"Segment"``: what :attr:`ids` number. It must equal
        ``location_kind`` unless that is ``"ArcLength"``.
    """

    quantity: str
    unit: str | None
    location_kind: str
    location: npt.NDArray[Any]
    ids: npt.NDArray[Any]
    values: npt.NDArray[Any]
    time: float | None
    source: Path | None = None
    id_kind: str = "Node"

    def __post_init__(self) -> None:
        if self.location_kind not in {"ArcLength", "Node", "Segment"}:
            raise ValueError("location_kind must be 'ArcLength', 'Node', or 'Segment'")
        if self.id_kind not in {"Node", "Segment"}:
            raise ValueError("id_kind must be 'Node' or 'Segment'")
        if self.location_kind != "ArcLength" and self.id_kind != self.location_kind:
            raise ValueError("id_kind must match a Node or Segment location_kind")
        location = _readonly(self.location)
        values = _readonly(self.values)
        ids = _readonly(self.ids, np.int64)
        if location.ndim != 1 or location.size == 0:
            raise ValueError("location must be a non-empty one-dimensional array")
        if values.shape != location.shape or ids.shape != location.shape:
            raise ValueError("values and ids must match location")
        if not (np.all(np.isfinite(location)) and np.all(np.isfinite(values))):
            raise ValueError("location and values must be finite")
        if np.any(np.diff(location) < 0.0):
            raise ValueError("location must be non-decreasing")
        object.__setattr__(self, "location", location)
        object.__setattr__(self, "values", values)
        object.__setattr__(self, "ids", ids)
        if self.source is not None:
            object.__setattr__(self, "source", Path(self.source).expanduser().resolve())

    @property
    def maximum(self) -> float:
        """Largest value."""
        return float(np.max(self.values))

    @property
    def minimum(self) -> float:
        """Smallest value."""
        return float(np.min(self.values))

    def plot(self, *, ax: Any = None, label: str | None = None) -> Any:
        """Plot the profile against its location.

        Parameters
        ----------
        ax : matplotlib.axes.Axes | None
            Axes to draw on; a new figure is created when omitted.
        label : str | None
            Legend label; defaults to the quantity and time.

        Returns
        -------
        matplotlib.axes.Axes
            The axes drawn on.
        """
        plt = pyplot()
        if ax is None:
            _, ax = plt.subplots()
        when = "static" if self.time is None else f"t = {self.time:g} s"
        ax.plot(self.location, self.values, label=label or f"{self.quantity} ({when})")
        xlabels = {"ArcLength": "Arc length [m]", "Node": "Node [-]", "Segment": "Segment [-]"}
        ax.set_xlabel(xlabels[self.location_kind])
        name = self.quantity.replace("_", " ").capitalize()
        ax.set_ylabel(f"{name} [{self.unit}]" if self.unit else name)
        ax.grid(True)
        ax.legend()
        return ax

    def export(self, path: str | os.PathLike[str], *, overwrite: bool = False) -> Path:
        """Atomically write the profile as a unit-labelled CSV.

        Columns: the location (``ArcLength_[m]``, ``Node_[-]``, or
        ``Segment_[-]``), the node or segment number, and the value.

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
        """
        first = {"ArcLength": "ArcLength_[m]", "Node": "Node_[-]", "Segment": "Segment_[-]"}
        kind = self.id_kind
        value = f"{self.quantity}_[{self.unit}]" if self.unit else self.quantity
        rows = (
            (number(self.location[index]), str(int(self.ids[index])), number(self.values[index]))
            for index in range(self.location.size)
        )
        return write_csv(
            path, (first[self.location_kind], f"{kind}Id", value), rows, overwrite=overwrite
        )


PositionSource: TypeAlias = LinePositions | TimeHistory | OutputTable | npt.ArrayLike
LocationSource: TypeAlias = PositionSource | Mapping[int, float] | None


def _line_id(line_id: int | None) -> int | None:
    if line_id is None:
        return None
    if isinstance(line_id, bool) or not isinstance(line_id, (int, np.integer)) or line_id < 1:
        raise ValueError("line_id must be a positive integer")
    return int(line_id)


def _static_line(profile: StaticProfile, line_id: int | None) -> StaticProfile:
    if line_id is None:
        identifiers = profile.line_ids
        if len(identifiers) != 1:
            raise ValueError(f"the profile holds lines {identifiers}; pass line_id")
        line_id = identifiers[0]
    return profile.line(line_id)


def _no_line_id(line_id: int | None, source: object) -> None:
    if line_id is not None:
        raise ValueError(f"line_id does not apply to a {type(source).__name__}")


def _is_static_node_table(table: OutputTable) -> bool:
    return not isinstance(table, TimeHistory) and {"Node", "X(m)", "Y(m)", "Z(m)"}.issubset(
        table.channels
    )


def _is_static_segment_table(table: OutputTable) -> bool:
    return not isinstance(table, TimeHistory) and {"Segment", "Tension(N)"}.issubset(table.channels)


def _main_channels(history: TimeHistory, line_id: int) -> dict[str, dict[int, str]]:
    """Canonical quantity -> {node: channel} for one line of a main output."""
    found: dict[str, dict[int, str]] = {}
    for channel in history.channels:
        demand = _MAIN_DEMAND.fullmatch(channel)
        kinematic = _MAIN_KINEMATIC.fullmatch(channel)
        if demand is not None:
            line, node, code = int(demand.group(2)), int(demand.group(3)), demand.group(1)
        elif kinematic is not None:
            line, node, code = int(kinematic.group(1)), int(kinematic.group(2)), kinematic.group(3)
        else:
            continue
        if line != line_id:
            continue
        quantity = _MAIN_NAMES[code.lower()][0]
        slot = found.setdefault(quantity, {})
        if node in slot:
            raise ValueError(f"channels {slot[node]!r} and {channel!r} name the same node")
        slot[node] = channel
    return {quantity: dict(sorted(slot.items())) for quantity, slot in found.items()}


def _moordyn_channels(history: MoorDynLineHistory) -> dict[str, tuple[str, dict[int, str]]]:
    """Canonical quantity -> (location kind, {id: channel}) for a MoorDyn line file."""
    found: dict[str, tuple[str, dict[int, str]]] = {}
    for channel in history.channels[1:]:
        node = _MOORDYN_NODE.fullmatch(channel)
        if node is not None:
            kind, identifier, code = "Node", int(node.group(1)), node.group(2)
        else:
            segment = _MOORDYN_SEGMENT.fullmatch(channel)
            assert segment is not None  # every channel is validated by MoorDynLineHistory
            kind, identifier, code = "Segment", int(segment.group(1)), segment.group(2)
        quantity = _MOORDYN_NAMES.get(code, code)
        found.setdefault(quantity, (kind, {}))[1][identifier] = channel
    return {name: (kind, dict(sorted(ids.items()))) for name, (kind, ids) in found.items()}


def _unit(table: OutputTable, channel: str, default: str | None) -> str | None:
    return table.unit(channel) or default


def _history_field(
    history: TimeHistory,
    quantity: str,
    kind: str,
    channels: Mapping[int, str],
    default: str | None,
    deck_nodes: bool = False,
) -> LineField:
    names = list(channels.values())
    return LineField(
        quantity=quantity,
        unit=_unit(history, names[0], default),
        location_kind=kind,
        ids=np.asarray(list(channels), dtype=np.int64),
        time=history.time,
        values=np.column_stack([history.column(name) for name in names]),
        source=history.path,
        deck_nodes=deck_nodes,
    )


def _catalog(source: Any, line_id: int | None) -> dict[str, Callable[[], LineField]]:
    """Canonical quantity name -> builder of its field, for one line of ``source``."""
    identifier = _line_id(line_id)
    catalog: dict[str, Callable[[], LineField]] = {}

    def add_positions(positions: Callable[[], LinePositions]) -> None:
        for axis, name in enumerate("xyz"):

            def build(axis: int = axis, name: str = name) -> LineField:
                lines = positions()
                return LineField(
                    name,
                    "m",
                    "Node",
                    lines.node_ids,
                    lines.time,
                    lines.positions[:, :, axis],
                    lines.source,
                )

            catalog[name] = build

    if isinstance(source, LinePositions):
        _no_line_id(identifier, source)
        add_positions(lambda: source)
    elif isinstance(source, StaticProfile):
        line = _static_line(source, identifier)
        for column in line.channels:
            if column in {"LineID", "Node", "ArcLength", "DeckNode"}:
                continue

            def static_build(column: str = column) -> LineField:
                return LineField(
                    _snake(column),
                    line.unit(column),
                    "Node",
                    line.column("Node").astype(np.int64),
                    None,
                    line.column(column)[None, :],
                    line.path,
                )

            catalog[_snake(column)] = static_build
    elif isinstance(source, LineNodeHistory):
        _no_line_id(identifier, source)
        add_positions(lambda: line_positions(source))
    elif isinstance(source, LineSegmentHistory):
        _no_line_id(identifier, source)
        channels = dict(zip(source.segment_ids, source.channels[1:], strict=True))
        catalog["tension"] = lambda: _history_field(source, "tension", "Segment", channels, "N")
    elif isinstance(source, MoorDynLineHistory):
        _no_line_id(identifier, source)
        for name, (kind, ids) in _moordyn_channels(source).items():

            def moordyn_build(name: str = name, kind: str = kind, ids: Any = ids) -> LineField:
                return _history_field(source, name, kind, ids, None)

            catalog[name] = moordyn_build
    elif isinstance(source, TimeHistory):
        if identifier is None:
            raise ValueError("a main output needs line_id to select the node channels")
        for name, channels in _main_channels(source, identifier).items():
            default = next(unit for canonical, unit in _MAIN_NAMES.values() if canonical == name)

            def main_build(
                name: str = name, channels: Any = channels, unit: str = default
            ) -> LineField:
                # main-output node channels number deck nodes
                return _history_field(source, name, "Node", channels, unit, deck_nodes=True)

            catalog[name] = main_build
    elif isinstance(source, OutputTable) and _is_static_node_table(source):
        _no_line_id(identifier, source)
        add_positions(lambda: line_positions(source))
    elif isinstance(source, OutputTable) and _is_static_segment_table(source):
        _no_line_id(identifier, source)
        catalog["tension"] = lambda: LineField(
            "tension",
            _unit(source, "Tension(N)", "N"),
            "Segment",
            source.column("Segment").astype(np.int64),
            None,
            source.column("Tension(N)")[None, :],
            source.path,
        )
    elif isinstance(source, OutputTable):
        raise ValueError(f"{source.path.name} is not a line result table")
    else:
        _no_line_id(identifier, source)
        add_positions(lambda: line_positions(source))
    return catalog


def available_quantities(source: PositionSource, *, line_id: int | None = None) -> tuple[str, ...]:
    """Return the canonical names of the per-line variables a source records.

    Parameters
    ----------
    source : object
        Any source accepted by :func:`line_field`.
    line_id : int | None
        Line to inspect in a main output or a multi-line static profile.

    Returns
    -------
    tuple[str, ...]
        Canonical quantity names, for example ``("x", "y", "z")`` for a
        position file or ``("tension",)`` for a tension file.

    Raises
    ------
    ValueError
        If ``line_id`` is missing or not applicable, or the source is not a
        line result.
    """
    return tuple(_catalog(source, line_id))


def line_field(source: PositionSource, quantity: str, *, line_id: int | None = None) -> LineField:
    """Return one per-node or per-segment variable of one line.

    Parameters
    ----------
    source : object
        A :class:`~cabledyn.LineNodeHistory` (``x``, ``y``, ``z``), a
        :class:`~cabledyn.LineSegmentHistory` (``tension``), a main
        :class:`~cabledyn.TimeHistory` with node channels (``tension``,
        ``curvature``, ``bend_moment``, ``x``, ``y``, ``z``, ``vx`` ...
        ``az``, ``declination``, ``azimuth``), a
        :class:`~cabledyn.MoorDynLineHistory` (``x``, ``y``, ``z``,
        ``tension``, ``curvature``, and the other MoorDyn codes spelled as
        MoorDyn writes them, for example ``vx``, ``ax``, ``Vx`` or ``Dmp``;
        ``vx`` (node velocity) and ``Vx`` (other force) differ only in case,
        so either must be given exactly), a :class:`~cabledyn.StaticProfile`
        (every column other than ``LineID``, ``Node``, and ``ArcLength``, in
        snake case, for example ``bend_moment``), a static per-line node or
        segment table, a :class:`LinePositions`, or a node-position array
        accepted by :func:`line_positions`.
    quantity : str
        Quantity name, matched ignoring case, underscores, and spaces.
    line_id : int | None
        Line to take from a main output (required) or a multi-line static
        profile. Not allowed for per-line sources.

    Returns
    -------
    LineField
        Values of every recorded node or segment over time.

    Raises
    ------
    KeyError
        If the source does not record ``quantity`` for the line.
    ValueError
        If ``line_id`` is missing or not applicable, or the source is not a
        line result.
    """
    catalog = _catalog(source, line_id)
    if quantity in catalog:
        return catalog[quantity]()
    matches = [name for name in catalog if _key(name) == _key(quantity)]
    if len(matches) > 1:
        raise ValueError(f"{quantity!r} is ambiguous between {matches}; use the exact name")
    if not matches:
        raise KeyError(f"no {quantity!r} for this line; available: {', '.join(catalog) or 'none'}")
    return catalog[matches[0]]()


def line_positions(
    source: PositionSource,
    *,
    line_id: int | None = None,
    time: npt.ArrayLike | None = None,
) -> LinePositions:
    """Return the node positions of one line over time.

    Parameters
    ----------
    source : LinePositions | TimeHistory | OutputTable | array_like
        A :class:`LinePositions` (returned unchanged), a
        :class:`~cabledyn.LineNodeHistory`, a
        :class:`~cabledyn.MoorDynLineHistory` with node positions, a main
        output with ``L<L>N<J>p[xyz]`` channels (only the listed nodes), a
        :class:`~cabledyn.StaticProfile` with ``X``, ``Y``, and ``Z``
        columns, a static per-line ``Node``/``X(m)``/``Y(m)``/``Z(m)`` table,
        or an array: ``(n_nodes, 3)`` for a static configuration or
        ``(n_samples, n_nodes, 3)`` for a history, in metres. For a main
        output, arc lengths follow the chords between the listed nodes only.
    line_id : int | None
        Line to take from a main output (required) or a multi-line static
        profile. Not allowed for per-line sources.
    time : array_like | None
        ``(n_samples,)`` sample times, in seconds, for a 3-D array (required
        there); not allowed for other sources.

    Returns
    -------
    LinePositions
        Positions in End-A-to-End-B order. Array nodes are numbered from 1.

    Raises
    ------
    KeyError
        If the source records no node positions for the line.
    ValueError
        If ``line_id`` or ``time`` is missing or not applicable, or the array
        shape is wrong.
    """
    identifier = _line_id(line_id)
    if time is not None and (isinstance(source, (LinePositions, OutputTable))):
        raise ValueError("time applies only to a position array")
    if isinstance(source, LinePositions):
        _no_line_id(identifier, source)
        return source
    if isinstance(source, StaticProfile):
        line = _static_line(source, identifier)
        xyz = np.column_stack([line.column(axis) for axis in "XYZ"])
        return LinePositions(
            None, xyz[None], line.column("Node").astype(np.int64), line.path, line.line_ids[0]
        )
    data: npt.NDArray[Any]
    if isinstance(source, LineNodeHistory):
        _no_line_id(identifier, source)
        data = source.values[:, 1:].reshape((source.time.size, -1, 3))
        return LinePositions(source.time, data, np.asarray(source.node_ids), source.path)
    if isinstance(source, MoorDynLineHistory):
        _no_line_id(identifier, source)
        names = [
            f"Node{node}{axis}" for node in range(source.node_count) for axis in ("px", "py", "pz")
        ]
        if any(name not in source.channels for name in names):
            raise KeyError(f"{source.path.name} has no node position channels")
        data = np.column_stack([source.column(name) for name in names])
        return LinePositions(
            source.time,
            data.reshape((source.time.size, -1, 3)),
            np.arange(source.node_count),
            source.path,
        )
    if isinstance(source, TimeHistory):
        if identifier is None:
            raise ValueError("a main output needs line_id to select the L<L>N<J>p channels")
        channels = _main_channels(source, identifier)
        axes = [channels.get(axis, {}) for axis in "xyz"]
        if not any(axes):
            raise KeyError(f"{source.path.name} has no L{identifier}N<J>p[xyz] channels")
        if not (axes[0].keys() == axes[1].keys() == axes[2].keys()):
            raise ValueError(f"line {identifier} nodes lack a px, py, or pz channel")
        nodes = list(axes[0])
        data = np.stack(
            [np.column_stack([source.column(axis[node]) for axis in axes]) for node in nodes],
            axis=1,
        )
        return LinePositions(source.time, data, np.asarray(nodes), source.path)
    if isinstance(source, OutputTable):
        if not _is_static_node_table(source):
            raise KeyError(f"{source.path.name} records no line node positions")
        _no_line_id(identifier, source)
        xyz = np.column_stack([source.column(f"{axis}(m)") for axis in "XYZ"])
        return LinePositions(None, xyz[None], source.column("Node").astype(np.int64), source.path)
    _no_line_id(identifier, source)
    array = np.asarray(source, dtype=np.float64)
    if array.ndim == 2:
        if time is not None:
            raise ValueError("time applies only to a (n_samples, n_nodes, 3) array")
        array = array[None]
        stamps: npt.NDArray[Any] | None = None
    elif array.ndim == 3:
        if time is None:
            raise ValueError("a (n_samples, n_nodes, 3) array needs the sample times")
        stamps = np.asarray(time, dtype=np.float64)
    else:
        raise ValueError("positions must be a (n_nodes, 3) or (n_samples, n_nodes, 3) array")
    return LinePositions(stamps, array, np.arange(1, array.shape[1] + 1))


def _node_arc(
    locate: LocationSource,
    time: float | None,
    interpolation: Interpolation,
    line_id: int | None,
    deck_nodes: bool = False,
) -> tuple[npt.NDArray[Any], npt.NDArray[Any]]:
    """Return node ids and their arc lengths from End A at ``time``.

    ``deck_nodes`` asks for deck node numbers (main-output node channels): a
    static profile then gives the rows its ``DeckNode`` column names on a line
    whose mesh the static solve refined.
    """
    if isinstance(locate, StaticProfile):
        line = _static_line(locate, line_id)
        if deck_nodes:
            lookup = line.deck_node_arc_lengths(line.line_ids[0])
            ids = np.asarray(sorted(lookup), dtype=np.int64)
            return ids, np.asarray([lookup[int(node)] for node in ids], dtype=np.float64)
        return line.column("Node").astype(np.int64), np.asarray(line.column("ArcLength"))
    if isinstance(locate, Mapping):
        ids = np.asarray(sorted(int(node) for node in locate), dtype=np.int64)
        arc = np.asarray([float(locate[int(node)]) for node in ids], dtype=np.float64)
        return ids, arc
    positions = line_positions(
        locate,  # type: ignore[arg-type]
        line_id=line_id if isinstance(locate, TimeHistory) and not _per_line(locate) else None,
    )
    xyz = positions.at(None if positions.static else time, interpolation=interpolation)
    if deck_nodes:
        return _deck_node_positions(locate, positions.node_ids, _cumulative_arc(xyz))
    return positions.node_ids, _cumulative_arc(xyz)


def _deck_node_positions(
    locate: LocationSource, node_ids: npt.NDArray[Any], arc: npt.NDArray[Any]
) -> tuple[npt.NDArray[Any], npt.NDArray[Any]]:
    """Deck node ids and arc lengths of the nodes of a position source.

    A per-line file ``<root>.Line<L>.p.out`` and a static profile list every
    node of the line's final mesh. On a line whose mesh the static solve
    refined, the file's ``# DeckNode`` line (or the ``DeckNode`` column of the
    static profile ``<root>.static.out`` beside it) names the deck nodes among
    them; without either the file's nodes are the deck nodes. Position arrays
    carry no such map and are taken as numbered by deck node.
    """
    mesh_node = _deck_node_rows(locate)
    if mesh_node is None:
        return node_ids, arc
    position = dict(zip(node_ids.tolist(), arc.tolist(), strict=True))
    deck = [j for j in sorted(mesh_node) if mesh_node[j] in position]
    return (
        np.asarray(deck, dtype=np.int64),
        np.asarray([position[mesh_node[j]] for j in deck], dtype=np.float64),
    )


def _deck_node_rows(locate: LocationSource) -> dict[int, int] | None:
    """Deck node -> node id of a position source's file; ``None`` when they coincide."""
    path: Path | None
    deck: npt.NDArray[Any] | None = None
    if isinstance(locate, LineNodeHistory):
        path, deck = locate.path, locate.deck_nodes
    elif isinstance(locate, OutputTable) and _is_static_node_table(locate):
        path, deck = locate.path, _deck_node_comment(locate.title, locate.path)
    elif isinstance(locate, LinePositions) and locate.source is not None:
        path = locate.source
        if path.name.lower().endswith(".static.out"):
            return _static_profile_rows(path, locate.line_id)
        if path.is_file():
            deck = _deck_node_comment(_comment_head(path), path)
    else:
        return None
    if deck is not None:
        return {int(j): k + 1 for k, j in enumerate(deck.tolist()) if j > 0}
    match = _FILE_LINE.search(path.name)
    if match is None:
        return None
    static = path.with_name(path.name[: match.start()] + ".static.out")
    if not static.is_file():
        return None
    return _static_profile_rows(static, int(match.group(1)))


def _static_profile_rows(path: Path, line_id: int | None) -> dict[int, int] | None:
    """Deck node -> ``Node`` of one line of a static profile with a ``DeckNode`` column."""
    profile = read_output(path)
    if not isinstance(profile, StaticProfile) or "DeckNode" not in profile.channels:
        return None
    if line_id is None:
        if len(profile.line_ids) != 1:
            raise ValueError(
                f"{path.name} lists several lines with a refined mesh; place deck-node "
                "channels with the StaticProfile itself"
            )
        line_id = profile.line_ids[0]
    if line_id not in profile.line_ids:
        return None
    rows = profile.line(line_id)
    return {
        int(deck): int(node)
        for deck, node in zip(rows.column("DeckNode"), rows.column("Node"), strict=True)
        if deck > 0.0
    }


def _comment_head(path: Path) -> str:
    """The leading ``#`` comment lines of a result file."""
    lines: list[str] = []
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            if not line.startswith("#"):
                break
            lines.append(line.rstrip("\n"))
    return "\n".join(lines)


def _cumulative_arc(xyz: npt.NDArray[Any]) -> npt.NDArray[Any]:
    """Cumulative chord length from the first of ``(n_nodes, 3)`` points."""
    return np.concatenate(([0.0], np.cumsum(np.linalg.norm(np.diff(xyz, axis=0), axis=1))))


def _per_line(history: TimeHistory) -> bool:
    return isinstance(history, (LineNodeHistory, LineSegmentHistory, MoorDynLineHistory))


def _own_locator(source: Any) -> LocationSource:
    """The arc-length source a result carries itself, if any."""
    if isinstance(source, (LinePositions, StaticProfile, LineNodeHistory)):
        return source
    if isinstance(source, MoorDynLineHistory):
        return source if "Node0px" in source.channels else None
    if isinstance(source, OutputTable) and _is_static_node_table(source):
        return source
    if isinstance(source, (OutputTable, Mapping)):
        return None
    array: LocationSource = source  # a position array
    return array


def _place(
    field: LineField,
    locate: LocationSource,
    time: float | None,
    interpolation: Interpolation,
    line_id: int | None,
) -> tuple[str, npt.NDArray[Any]]:
    """Return the location kind and location of each field value."""
    if locate is None:
        return field.location_kind, field.ids.astype(np.float64)
    node_ids, arc = _node_arc(locate, time, interpolation, line_id, field.deck_nodes)
    return "ArcLength", _assign(field, isinstance(locate, Mapping), node_ids, arc)


def _assign(
    field: LineField, mapping: bool, node_ids: npt.NDArray[Any], arc: npt.NDArray[Any]
) -> npt.NDArray[Any]:
    """Arc length of each field value from the arc length of the line nodes."""
    if field.location_kind == "Node":
        lookup = dict(zip(node_ids.tolist(), arc.tolist(), strict=True))
        missing = [int(node) for node in field.ids if int(node) not in lookup]
        if missing:
            raise KeyError(f"no arc length for nodes {missing}")
        return np.asarray([lookup[int(node)] for node in field.ids])
    if mapping:
        raise ValueError("a node-to-arc mapping cannot place segment values; pass node positions")
    if arc.size != field.ids.size + 1:
        raise ValueError(
            f"{field.ids.size} segments need {field.ids.size + 1} nodes to be placed; "
            f"the positions hold {arc.size}"
        )
    return np.asarray(0.5 * (arc[:-1] + arc[1:]))


def _mean_node_arc(
    locate: LocationSource,
    line_id: int | None,
    start: float | None,
    stop: float | None,
    deck_nodes: bool = False,
) -> tuple[npt.NDArray[Any], npt.NDArray[Any]]:
    """Node ids and their arc length, time-averaged over a window for a history."""
    if isinstance(locate, (StaticProfile, Mapping)):
        return _node_arc(locate, None, "linear", line_id, deck_nodes)
    positions = line_positions(
        locate,  # type: ignore[arg-type]
        line_id=line_id if isinstance(locate, TimeHistory) and not _per_line(locate) else None,
    ).period(start, stop)
    if deck_nodes:
        return _deck_node_positions(
            locate, positions.node_ids, np.mean(positions.arc_length, axis=0)
        )
    return positions.node_ids, np.mean(positions.arc_length, axis=0)


def line_range_graph(
    source: PositionSource,
    quantity: str,
    *,
    line_id: int | None = None,
    positions: LocationSource = None,
    start: float | None = None,
    stop: float | None = None,
) -> RangeGraph:
    """Return the range graph of any per-node or per-segment variable of one line.

    This extends :func:`cabledyn.node_range_graph` to every source accepted by
    :func:`line_field`, for example the effective tension of every segment
    from a per-line tension file.

    Parameters
    ----------
    source : object
        Any source accepted by :func:`line_field`, with a result file.
    quantity : str
        Quantity name; see :func:`available_quantities`.
    line_id : int | None
        Line to take from a main output or a multi-line static profile.
    positions : object | None
        Where the values lie along the line when ``source`` does not record
        node positions itself (see :func:`profiles_at`). A position history
        places each node at its arc length averaged over the window. Without
        positions, node values are placed by node number.
    start, stop : float | None
        Optional time window, in seconds.

    Returns
    -------
    RangeGraph
        Minimum, maximum, and mean at each node or segment, against arc length
        (or node number). For a per-line source the graph's ``line_id`` is
        read from the file name (``<root>.Line<L>.t.out``,
        ``<root>.MD.Line<N>.out``), and is ``None`` when the name has none.

    Raises
    ------
    KeyError
        If the quantity is not recorded or ``positions`` lacks a node.
    ValueError
        If ``line_id`` is missing or not applicable, the window is invalid,
        the source has no result file, or segment values have no positions to
        place them.
    """
    field = line_field(source, quantity, line_id=line_id).period(start, stop)
    if field.source is None:
        raise ValueError("a range graph needs a source read from a result file")
    locate = positions if positions is not None else _own_locator(source)
    if locate is None:
        if field.location_kind == "Segment":
            raise ValueError("a segment range graph needs node positions to place the segments")
        kind, location = "Node", field.ids.astype(np.float64)
    else:
        node_ids, arc = _mean_node_arc(locate, line_id, start, stop, field.deck_nodes)
        kind, location = "ArcLength", _assign(field, isinstance(locate, Mapping), node_ids, arc)
    order = np.argsort(location, kind="stable")
    values = field.values[:, order]
    window = None if field.time is None else (float(field.time[0]), float(field.time[-1]))
    return RangeGraph(
        line_id=line_id if line_id is not None else _file_line_id(field.source),
        quantity=field.quantity,
        unit=field.unit,
        location_kind=kind,
        location=location[order],
        maximum=np.max(values, axis=0),
        minimum=np.min(values, axis=0),
        mean=np.mean(values, axis=0),
        source=field.source,
        time_window=window,
    )


def profiles_at(
    source: PositionSource,
    quantities: Iterable[str],
    time: float | None = None,
    *,
    line_id: int | None = None,
    interpolation: Interpolation = "linear",
    positions: LocationSource = None,
) -> dict[str, ArcProfile]:
    """Return several variables of one line along its arc length at one time.

    Parameters
    ----------
    source : object
        Any source accepted by :func:`line_field`.
    quantities : collections.abc.Iterable[str]
        Quantity names; see :func:`available_quantities`.
    time : float | None
        Time in seconds; ``None`` for a static source and required otherwise.
    line_id : int | None
        Line to take from a main output or a multi-line static profile.
    interpolation : {"linear", "nearest"}
        Linear interpolation between the bracketing samples, or the nearest
        sample (the earlier one on a tie).
    positions : object | None
        Where the values lie along the line when ``source`` does not record
        node positions itself: a position source accepted by
        :func:`line_positions` (evaluated at the same time), a
        :class:`~cabledyn.StaticProfile` (its ``ArcLength`` column), or a
        mapping from node number to arc length in metres. Segment values are
        placed at the mid-arc of their end nodes, which needs the positions of
        every node. Without positions, values are placed by node or segment
        number.

    Returns
    -------
    dict[str, ArcProfile]
        One profile per requested name, keyed by the name as given.

    Raises
    ------
    KeyError
        If a quantity is not recorded or ``positions`` lacks a node.
    ValueError
        If ``time`` or ``line_id`` is missing or not applicable, ``time`` is
        outside the record, or segment values cannot be placed.
    """
    locate = positions if positions is not None else _own_locator(source)
    result: dict[str, ArcProfile] = {}
    for quantity in quantities:
        field = line_field(source, quantity, line_id=line_id)
        values = field.at(time, interpolation=interpolation)
        kind, location = _place(field, locate, time, interpolation, line_id)
        order = np.argsort(location, kind="stable")
        when = None if time is None or field.static else _finite_time(time)
        result[quantity] = ArcProfile(
            quantity=field.quantity,
            unit=field.unit,
            location_kind=kind,
            location=location[order],
            ids=field.ids[order],
            values=values[order],
            time=when,
            source=field.source,
            id_kind=field.location_kind,
        )
    return result


def profile_at(
    source: PositionSource,
    quantity: str,
    time: float | None = None,
    *,
    line_id: int | None = None,
    interpolation: Interpolation = "linear",
    positions: LocationSource = None,
) -> ArcProfile:
    """Return one variable of one line along its arc length at one time.

    The parameters are those of :func:`profiles_at` with a single quantity.

    Returns
    -------
    ArcProfile
        The values against arc length (or node or segment number).

    Raises
    ------
    KeyError
        If the quantity is not recorded or ``positions`` lacks a node.
    ValueError
        If ``time`` or ``line_id`` is missing or not applicable, ``time`` is
        outside the record, or segment values cannot be placed.
    """
    return profiles_at(
        source,
        (quantity,),
        time,
        line_id=line_id,
        interpolation=interpolation,
        positions=positions,
    )[quantity]
