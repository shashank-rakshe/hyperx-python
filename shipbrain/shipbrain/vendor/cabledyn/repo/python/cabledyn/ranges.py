# SPDX-License-Identifier: Apache-2.0
"""Along-arc range graphs of tension, curvature, and bend moment.

A range graph (the OrcaFlex term) is the envelope of a quantity along a line:
its minimum, maximum, and mean at each position. :class:`RangeGraph` holds
one, and these functions build it from the kinds of CableDyn result:

* :func:`read_range_graph` and :func:`read_range_graphs` -- from the
  solver-side range file ``<root>.Line<L>.range.out`` (LINES flag ``r``), which
  holds every node of the line over the whole run window;
* :func:`node_range_graph` -- from the node channels of a main output
  (``Ten<L>N<J>``, ``Curv<L>N<J>``, ``BendMom<L>N<J>``) over a time window;
* :func:`static_range_graph` -- from the ``Tension``, ``Curvature``, or
  ``BendMoment`` column of a static profile (``.static.out``), where the
  minimum, maximum, and mean coincide;
* :func:`element_range_graph` -- from the continuous element extrema of a
  cubic-Hermite element table (``.elements.out``).

Node channels are written only for the nodes named in the deck ``OUTPUTS``
section and number deck nodes (1 at End A to 1 + the total ``NumSegs`` of the
line's sections at End B). Their positions along the line come from
``arc_length``: a static profile of the same run (the node's static deformed arc
length; on a line whose mesh the static solve refined, the deck node's row of
the profile, see :meth:`~cabledyn.StaticProfile.deck_node_arc_lengths`), an
explicit mapping from node number to arc length, or nothing, in which case the
graph is plotted against node number.
"""

from __future__ import annotations

import os
import re
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
import numpy.typing as npt

from cabledyn._csv import number, write_csv
from cabledyn._optional import pyplot
from cabledyn.results import OutputTable, StaticProfile, TimeHistory, read_output

__all__ = [
    "RangeGraph",
    "element_range_graph",
    "node_range_graph",
    "read_range_graph",
    "read_range_graphs",
    "static_range_graph",
]

# quantity -> (node-channel prefix, static-profile column, SI unit)
_QUANTITIES: dict[str, tuple[str, str, str]] = {
    "tension": ("Ten", "Tension", "N"),
    "curvature": ("Curv", "Curvature", "1/m"),
    "bend_moment": ("BendMom", "BendMoment", "N-m"),
}
_NODE_QUANTITY = re.compile(r"(Ten|Curv|BendMom)0*([1-9][0-9]{0,8})N0*([1-9][0-9]{0,8})", re.I)
_NODE_POSITION = re.compile(r"L0*([1-9][0-9]{0,8})N0*([1-9][0-9]{0,8})p([xyz])", re.I)

ArcSource = StaticProfile | Mapping[int, float] | None


def _readonly(values: npt.ArrayLike) -> npt.NDArray[Any]:
    result = np.array(values, dtype=np.float64, copy=True)
    result.setflags(write=False)
    return result


def _quantity(quantity: str) -> tuple[str, str, str]:
    if quantity not in _QUANTITIES:
        raise ValueError(f"quantity must be one of {tuple(_QUANTITIES)}")
    return _QUANTITIES[quantity]


def _line_id(line_id: int) -> int:
    if isinstance(line_id, bool) or not isinstance(line_id, (int, np.integer)) or line_id < 1:
        raise ValueError("line_id must be a positive integer")
    return int(line_id)


def node_channels(history: TimeHistory, line_id: int, prefix: str) -> dict[int, str]:
    """Map node number to channel name for one node quantity of one line."""
    wanted = _line_id(line_id)
    found: dict[int, str] = {}
    for channel in history.channels:
        match = _NODE_QUANTITY.fullmatch(channel)
        if match is None or match.group(1).lower() != prefix.lower():
            continue
        if int(match.group(2)) != wanted:
            continue
        node = int(match.group(3))
        if node in found:
            raise ValueError(f"channels {found[node]!r} and {channel!r} name the same node")
        found[node] = channel
    if not found:
        raise KeyError(f"{history.path.name} has no {prefix}{wanted}N<J> channels")
    return dict(sorted(found.items()))


def node_position_channels(history: TimeHistory, line_id: int) -> dict[int, tuple[str, str, str]]:
    """Map node number to its ``(px, py, pz)`` channel names for one line."""
    wanted = _line_id(line_id)
    axes: dict[int, dict[str, str]] = {}
    for channel in history.channels:
        match = _NODE_POSITION.fullmatch(channel)
        if match is None or int(match.group(1)) != wanted:
            continue
        slot = axes.setdefault(int(match.group(2)), {})
        axis = match.group(3).lower()
        if axis in slot:
            raise ValueError(f"channels {slot[axis]!r} and {channel!r} name the same component")
        slot[axis] = channel
    if not axes:
        raise KeyError(f"{history.path.name} has no L{wanted}N<J>p[xyz] channels")
    incomplete = sorted(node for node, slot in axes.items() if len(slot) != 3)
    if incomplete:
        raise ValueError(f"nodes {incomplete} of line {wanted} lack a px, py, or pz channel")
    return {node: (slot["x"], slot["y"], slot["z"]) for node, slot in sorted(axes.items())}


def node_matrix(history: TimeHistory, channels: Mapping[int, str]) -> npt.NDArray[Any]:
    """Return the ``(n_samples, n_nodes)`` values of node channels."""
    return np.column_stack([history.column(name) for name in channels.values()])


def node_locations(
    line_id: int, node_ids: tuple[int, ...], arc_length: ArcSource
) -> tuple[str, npt.NDArray[Any]]:
    """Return the location kind and the location of each node."""
    if arc_length is None:
        return "Node", np.asarray(node_ids, dtype=np.float64)
    if isinstance(arc_length, StaticProfile):
        # node channels number deck nodes; a refined line's profile locates them (DeckNode)
        lookup = arc_length.deck_node_arc_lengths(line_id)
    elif isinstance(arc_length, Mapping):
        lookup = {int(node): float(arc) for node, arc in arc_length.items()}
    else:
        raise ValueError("arc_length must be a StaticProfile, a node-to-arc mapping, or None")
    missing = [node for node in node_ids if node not in lookup]
    if missing:
        raise KeyError(f"no arc length for nodes {missing} of line {line_id}")
    values = np.asarray([lookup[node] for node in node_ids], dtype=np.float64)
    if not np.all(np.isfinite(values)) or np.any(np.diff(values) < 0.0):
        raise ValueError("node arc lengths must be finite and non-decreasing along the line")
    return "ArcLength", values


@dataclass(frozen=True)
class RangeGraph:
    """Envelope of one quantity along one line.

    Arrays are read-only and hold one value per location, in End-A-to-End-B
    order. ``minimum`` and ``mean`` are ``None`` when the source does not
    define them (an element table records only a peak curvature per element).

    Attributes
    ----------
    line_id : int | None
        Deck line identifier; ``None`` when the source does not identify the
        line (a per-line file whose name has no ``.Line<L>.`` part).
    quantity : str
        ``"tension"``, ``"curvature"``, ``"bend_moment"``, for a range file
        also ``"declination"``, ``"clearance"``, ``"torque"`` and ``"twist"``,
        or, for an element table,
        ``"axial_resultant"``.
    unit : str | None
        Unit of the quantity as the source labels it: ``N``, ``1/m``, ``deg``, ``m``,
        and for a moment or torque ``N.m`` (the units row of a range file) or ``N-m``.
    location_kind : str
        ``"ArcLength"`` (``location`` in metres from End A) or ``"Node"``
        (``location`` is the one-based node number).
    location : numpy.ndarray
        ``(n,)`` non-decreasing locations.
    maximum : numpy.ndarray
        ``(n,)`` largest value at each location.
    minimum : numpy.ndarray | None
        ``(n,)`` smallest value at each location.
    mean : numpy.ndarray | None
        ``(n,)`` time-mean value at each location.
    source : pathlib.Path
        Result file the graph was built from.
    time_window : tuple[float, float] | None
        First and last sample time used, in seconds; ``None`` for a static
        or element source.

    Raises
    ------
    ValueError
        If the arrays do not match, are not finite, the locations decrease, or
        ``minimum`` exceeds ``maximum`` somewhere.
    """

    line_id: int | None
    quantity: str
    unit: str | None
    location_kind: str
    location: npt.NDArray[Any]
    maximum: npt.NDArray[Any]
    minimum: npt.NDArray[Any] | None
    mean: npt.NDArray[Any] | None
    source: Path
    time_window: tuple[float, float] | None = None

    def __post_init__(self) -> None:
        if self.location_kind not in {"ArcLength", "Node"}:
            raise ValueError("location_kind must be 'ArcLength' or 'Node'")
        location = _readonly(self.location)
        if location.ndim != 1 or location.size == 0 or not np.all(np.isfinite(location)):
            raise ValueError("location must be a non-empty finite one-dimensional array")
        if np.any(np.diff(location) < 0.0):
            raise ValueError("location must be non-decreasing")
        object.__setattr__(self, "location", location)
        for name in ("maximum", "minimum", "mean"):
            value = getattr(self, name)
            if value is None:
                if name == "maximum":
                    raise ValueError("maximum is required")
                continue
            array = _readonly(value)
            if array.shape != location.shape or not np.all(np.isfinite(array)):
                raise ValueError(f"{name} must be finite and match location")
            object.__setattr__(self, name, array)
        if self.minimum is not None and np.any(self.minimum > self.maximum):
            raise ValueError("minimum must not exceed maximum")
        object.__setattr__(self, "source", Path(self.source).expanduser().resolve())

    @property
    def peak(self) -> float:
        """Largest value on the line."""
        return float(np.max(self.maximum))

    @property
    def peak_location(self) -> float:
        """Location of :attr:`peak` (the first, if it repeats)."""
        return float(self.location[int(np.argmax(self.maximum))])

    def plot(self, *, ax: Any = None, label: str | None = None) -> Any:
        """Plot the envelope: a min-max band, the mean, and the maximum.

        Parameters
        ----------
        ax : matplotlib.axes.Axes | None
            Axes to draw on; a new figure is created when omitted. Pass the
            axes of an earlier graph to overlay, for example, a static profile
            on a dynamic envelope.
        label : str | None
            Legend prefix; defaults to the quantity.

        Returns
        -------
        matplotlib.axes.Axes
            The axes drawn on.
        """
        plt = pyplot()
        if ax is None:
            _, ax = plt.subplots()
        prefix = label or self.quantity.replace("_", " ")
        if self.minimum is not None:
            ax.fill_between(
                self.location, self.minimum, self.maximum, alpha=0.25, label=f"{prefix} min-max"
            )
        if self.mean is not None:
            ax.plot(self.location, self.mean, label=f"{prefix} mean")
        ax.plot(self.location, self.maximum, label=f"{prefix} max")
        ax.set_xlabel("Arc length [m]" if self.location_kind == "ArcLength" else "Node [-]")
        name = self.quantity.replace("_", " ").capitalize()
        ax.set_ylabel(f"{name} [{self.unit}]" if self.unit else name)
        ax.grid(True)
        ax.legend()
        return ax

    def export(self, path: str | os.PathLike[str], *, overwrite: bool = False) -> Path:
        """Atomically write the graph as a unit-labelled CSV, one row per location.

        Columns: the location (``ArcLength_[m]`` or ``Node_[-]``), then
        ``Minimum``, ``Maximum``, and ``Mean`` in the quantity unit (blank
        where undefined).

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
        FileExistsError
            If ``path`` exists and ``overwrite`` is false.
        """
        suffix = f"_[{self.unit}]" if self.unit else ""
        first = "ArcLength_[m]" if self.location_kind == "ArcLength" else "Node_[-]"
        columns = (self.minimum, self.maximum, self.mean)
        rows = (
            (
                number(self.location[index]),
                *("" if column is None else number(column[index]) for column in columns),
            )
            for index in range(self.location.size)
        )
        return write_csv(
            path,
            (first, f"Minimum{suffix}", f"Maximum{suffix}", f"Mean{suffix}"),
            rows,
            overwrite=overwrite,
        )


def node_range_graph(
    history: TimeHistory,
    line_id: int,
    quantity: str,
    *,
    arc_length: ArcSource = None,
    start: float | None = None,
    stop: float | None = None,
) -> RangeGraph:
    """Return the dynamic range graph of one line from its node channels.

    Parameters
    ----------
    history : TimeHistory
        Main output holding ``Ten<L>N<J>``, ``Curv<L>N<J>``, or
        ``BendMom<L>N<J>`` channels (matched case-insensitively, leading zeros
        allowed).
    line_id : int
        Deck line identifier ``L``.
    quantity : str
        ``"tension"``, ``"curvature"``, or ``"bend_moment"``.
    arc_length : StaticProfile | collections.abc.Mapping[int, float] | None
        Where each node lies along the line: a static profile of the same run,
        a mapping from node number to arc length in metres, or ``None`` to use
        node numbers.
    start, stop : float | None
        Optional time window, in seconds.

    Returns
    -------
    RangeGraph
        Minimum, maximum, and mean at each output node.

    Raises
    ------
    KeyError
        If the line has no channel of that quantity, or ``arc_length`` lacks
        one of its nodes.
    ValueError
        If ``quantity`` or ``line_id`` is invalid, two channels name the same
        node, or the window is invalid.
    """
    prefix, _, default_unit = _quantity(quantity)
    identifier = _line_id(line_id)
    channels = node_channels(history, identifier, prefix)
    view = history.period(start, stop) if start is not None or stop is not None else history
    data = node_matrix(view, channels)
    kind, location = node_locations(identifier, tuple(channels), arc_length)
    unit = view.unit(next(iter(channels.values()))) or default_unit
    return RangeGraph(
        line_id=identifier,
        quantity=quantity,
        unit=unit,
        location_kind=kind,
        location=location,
        maximum=np.max(data, axis=0),
        minimum=np.min(data, axis=0),
        mean=np.mean(data, axis=0),
        source=view.path,
        time_window=(float(view.time[0]), float(view.time[-1])),
    )


def static_range_graph(profile: StaticProfile, line_id: int, quantity: str) -> RangeGraph:
    """Return the static range graph of one line from a static profile.

    The minimum, maximum, and mean are the static value itself.

    Parameters
    ----------
    profile : StaticProfile
        A ``.static.out`` table.
    line_id : int
        Deck line identifier.
    quantity : str
        ``"tension"``, ``"curvature"``, or ``"bend_moment"``.

    Returns
    -------
    RangeGraph
        The static value against arc length.

    Raises
    ------
    KeyError
        If the line or the column is not in the profile.
    ValueError
        If ``quantity`` or ``line_id`` is invalid.
    """
    _, column, default_unit = _quantity(quantity)
    line = profile.line(_line_id(line_id))
    values = line.column(column)
    return RangeGraph(
        line_id=int(line_id),
        quantity=quantity,
        unit=line.unit(column) or default_unit,
        location_kind="ArcLength",
        location=line.column("ArcLength"),
        maximum=values,
        minimum=values,
        mean=values,
        source=line.path,
    )


# range-file quantity -> (column prefix, SI unit)
_RANGE_FILE_QUANTITIES: dict[str, tuple[str, str]] = {
    "tension": ("Tension", "N"),
    "curvature": ("Curvature", "1/m"),
    "bend_moment": ("BendMoment", "N-m"),
    "declination": ("Declination", "deg"),
    "clearance": ("Clearance", "m"),
    "torque": ("Torque", "N-m"),
    "twist": ("Twist", "deg"),
}
_RANGE_TITLE = re.compile(
    r"CableDyn range graph \(line ([1-9][0-9]*); ([1-9][0-9]*) samples from t =\s*(\S+) s to "
    r"t =\s*(\S+) s;"
)


def _range_file(
    source: str | os.PathLike[str] | OutputTable,
) -> tuple[OutputTable, int, tuple[float, float]]:
    table = source if isinstance(source, OutputTable) else read_output(source)
    match = _RANGE_TITLE.search(table.title)
    if match is None or table.channels[:2] != ("Node", "ArcLength"):
        raise ValueError(
            f"{table.path.name} is not a CableDyn range file (<root>.Line<L>.range.out)"
        )
    window = (float(match.group(3).replace("D", "E")), float(match.group(4).replace("D", "E")))
    return table, int(match.group(1)), window


def read_range_graphs(source: str | os.PathLike[str] | OutputTable) -> dict[str, RangeGraph]:
    """Return every range graph of a solver-side range file.

    ``<root>.Line<L>.range.out`` is written by the driver for a line with the
    LINES ``Outputs`` flag ``r``: the minimum, maximum, and mean over the
    output times of the range window of the node tension, curvature, bend
    moment, and declination, the seabed clearance when the deck has a
    seabed, and the torque and twist from End A when the line is solved in
    torsion (restrained at both ends, or at one end with the other free), at
    every node against its arc length.

    Parameters
    ----------
    source : str | os.PathLike | OutputTable
        The range file, or the table :func:`cabledyn.read_output` read from it.

    Returns
    -------
    dict[str, RangeGraph]
        ``"tension"``, ``"curvature"``, ``"bend_moment"``, ``"declination"``,
        with a seabed ``"clearance"``, and with torsion ``"torque"`` and
        ``"twist"``.

    Raises
    ------
    OutputFormatError
        If the file is not a valid output table.
    ValueError
        If the table is not a range file.
    """
    table, line_id, window = _range_file(source)
    location = table.column("ArcLength")
    graphs: dict[str, RangeGraph] = {}
    for quantity, (prefix, default_unit) in _RANGE_FILE_QUANTITIES.items():
        if f"{prefix}Max" not in table.channels:
            continue
        graphs[quantity] = RangeGraph(
            line_id=line_id,
            quantity=quantity,
            unit=table.unit(f"{prefix}Max") or default_unit,
            location_kind="ArcLength",
            location=location,
            maximum=table.column(f"{prefix}Max"),
            minimum=table.column(f"{prefix}Min"),
            mean=table.column(f"{prefix}Mean"),
            source=table.path,
            time_window=window,
        )
    return graphs


def read_range_graph(source: str | os.PathLike[str] | OutputTable, quantity: str) -> RangeGraph:
    """Return one range graph of a solver-side range file.

    Parameters
    ----------
    source : str | os.PathLike | OutputTable
        The range file ``<root>.Line<L>.range.out``, or its table.
    quantity : str
        ``"tension"``, ``"curvature"``, ``"bend_moment"``, ``"declination"``,
        ``"clearance"``, ``"torque"`` or ``"twist"``.

    Returns
    -------
    RangeGraph
        Minimum, maximum, and mean at every node against the arc length
        from End A at the start of the run, with the range window as
        ``time_window``.

    Raises
    ------
    KeyError
        If the file has no such quantity (clearance needs a seabed, torque and
        twist a line with torsion).
    ValueError
        If ``quantity`` is unknown or the table is not a range file.
    """
    if quantity not in _RANGE_FILE_QUANTITIES:
        raise ValueError(f"quantity must be one of {tuple(_RANGE_FILE_QUANTITIES)}")
    graphs = read_range_graphs(source)
    if quantity not in graphs:
        raise KeyError(f"the range file has no {quantity} columns")
    return graphs[quantity]


_ELEMENT_COLUMNS = (
    "LineID",
    "Element",
    "ReferenceArcStart",
    "ReferenceArcEnd",
    "PeakReferenceArc",
    "PeakCurvature",
    "BendMomentAtPeak",
    "MinimumAxialResultant",
    "MaximumAxialResultant",
)


def element_range_graph(table: OutputTable, line_id: int, quantity: str) -> RangeGraph:
    """Return a range graph of one line from a cubic-Hermite element table.

    Locations are unstretched (reference) arc lengths from End A.
    ``"curvature"`` and ``"bend_moment"`` give each element's peak at the
    arc where it occurs (``PeakReferenceArc``), with no minimum or mean.
    ``"axial_resultant"`` gives the minimum and maximum axial force resultant
    of each element, placed at the element's mid-arc.

    Parameters
    ----------
    table : OutputTable
        A ``.elements.out`` table read with :func:`cabledyn.read_output`.
    line_id : int
        Deck line identifier.
    quantity : str
        ``"curvature"``, ``"bend_moment"``, or ``"axial_resultant"``.

    Returns
    -------
    RangeGraph
        The element envelope against reference arc length.

    Raises
    ------
    KeyError
        If the line is not in the table.
    ValueError
        If the table lacks an element-table column, or ``quantity`` or
        ``line_id`` is invalid.
    """
    missing = [name for name in _ELEMENT_COLUMNS if name not in table.channels]
    if missing:
        raise ValueError(f"{table.path.name} is not an element table; missing {missing}")
    identifier = _line_id(line_id)
    mask = table.column("LineID") == identifier
    if not np.any(mask):
        raise KeyError(f"LineID {identifier} is not in {table.path.name}")
    order = np.argsort(table.column("Element")[mask], kind="stable")

    def column(name: str) -> npt.NDArray[Any]:
        values: npt.NDArray[Any] = table.column(name)[mask][order]
        return values

    if quantity in {"curvature", "bend_moment"}:
        name = "PeakCurvature" if quantity == "curvature" else "BendMomentAtPeak"
        location = column("PeakReferenceArc")
        values = column(name)
        sort = np.argsort(location, kind="stable")
        return RangeGraph(
            line_id=identifier,
            quantity=quantity,
            unit=table.unit(name) or _QUANTITIES[quantity][2],
            location_kind="ArcLength",
            location=location[sort],
            maximum=values[sort],
            minimum=None,
            mean=None,
            source=table.path,
        )
    if quantity != "axial_resultant":
        raise ValueError("quantity must be 'curvature', 'bend_moment', or 'axial_resultant'")
    middle = 0.5 * (column("ReferenceArcStart") + column("ReferenceArcEnd"))
    return RangeGraph(
        line_id=identifier,
        quantity=quantity,
        unit=table.unit("MaximumAxialResultant") or "N",
        location_kind="ArcLength",
        location=middle,
        maximum=column("MaximumAxialResultant"),
        minimum=column("MinimumAxialResultant"),
        mean=None,
        source=table.path,
    )
