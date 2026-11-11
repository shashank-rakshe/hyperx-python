# SPDX-License-Identifier: Apache-2.0
"""Touchdown-point time histories on a flat seabed.

:func:`touchdown_history` tracks where a line lifts off a flat seabed at every
output time, from node positions in any of three forms:

* a CableDyn per-line position file (``<root>.Line<L>.p.out``, a
  :class:`~cabledyn.LineNodeHistory`);
* a MoorDyn-F per-line file with node positions (a
  :class:`~cabledyn.MoorDynLineHistory`);
* the ``L<L>N<J>px``/``py``/``pz`` node channels of a main output, for the
  nodes the deck lists (the touchdown is then resolved only to those nodes).

A node is grounded when ``z <= seabed_z + tolerance``, and the grounded run
must start at one end of the line (as for :meth:`cabledyn.LineGeometry.touchdown`).
Between the last grounded node and the next one the touchdown point (TDP) is
placed where the parabola through the last grounded node and the next two
nodes (height against chord arc), its curvature limited so that it rises
monotonically over the element, crosses ``seabed_z + tolerance``; with fewer than
two suspended nodes, or no crossing inside the element, where the chord crosses
that height. The crossing reaches a
node exactly when the node reaches that height, so the TDP moves continuously as
nodes ground and lift off, and the parabola follows a tangential lift-off between
nodes instead of holding the TDP at the last grounded node (the behaviour of the
chord crossing on a stiff seabed). It is the location of the driver's ``TDP<L>``
channels. Arc length is the cumulative deformed chord length from End A through
the available nodes.

The excursion is the horizontal TDP displacement from a reference position,
projected on the horizontal direction from the grounded end to the suspended
end of the reference state: positive towards the suspended end (the hang-off
or fairlead). The reference is a static profile, if given, otherwise the
first time at which the line touches down.
"""

from __future__ import annotations

import math
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
import numpy.typing as npt

from cabledyn._csv import number, write_csv
from cabledyn._optional import pyplot
from cabledyn.formats import MoorDynLineHistory
from cabledyn.ranges import node_position_channels
from cabledyn.results import LineNodeHistory, StaticProfile, TimeHistory

__all__ = ["TouchdownHistory", "touchdown_history"]

_QUANTITIES = {
    "arc_length": ("TDP arc length", "m"),
    "layback": ("Layback", "m"),
    "excursion": ("TDP excursion", "m"),
    "arc_excursion": ("TDP arc-length excursion", "m"),
}


def _readonly(values: npt.ArrayLike) -> npt.NDArray[Any]:
    result = np.array(values, dtype=np.float64, copy=True)
    result.setflags(write=False)
    return result


@dataclass(frozen=True)
class TouchdownHistory:
    """Touchdown point of one line at every output time.

    Arrays are read-only with one row per sample. At samples where the line
    does not touch down at ``grounded_end`` (fully suspended, or lying on
    the seabed entirely) ``touching`` is false and the values are ``nan``.

    Attributes
    ----------
    time : numpy.ndarray
        ``(n,)`` sample times, in seconds.
    touching : numpy.ndarray
        ``(n,)`` boolean: whether a touchdown point exists.
    arc_length : numpy.ndarray
        ``(n,)`` TDP arc length from End A, in metres.
    coordinates : numpy.ndarray
        ``(n, 3)`` TDP global X, Y, Z, in metres.
    layback : numpy.ndarray
        ``(n,)`` horizontal distance from the TDP to the suspended end, in
        metres.
    excursion : numpy.ndarray
        ``(n,)`` signed horizontal TDP displacement from the reference, in
        metres, positive towards the suspended end.
    arc_excursion : numpy.ndarray
        ``(n,)`` TDP arc length minus the reference arc length, in metres.
    grounded_end : str
        ``"A"`` or ``"B"``.
    seabed_z : float
        Seabed level, in metres.
    tolerance : float
        Grounding tolerance, in metres.
    reference_arc_length : float
        Reference TDP arc length, in metres.
    source : pathlib.Path
        Result file.
    """

    time: npt.NDArray[Any]
    touching: npt.NDArray[Any]
    arc_length: npt.NDArray[Any]
    coordinates: npt.NDArray[Any]
    layback: npt.NDArray[Any]
    excursion: npt.NDArray[Any]
    arc_excursion: npt.NDArray[Any]
    grounded_end: str
    seabed_z: float
    tolerance: float
    reference_arc_length: float
    source: Path

    def __post_init__(self) -> None:
        for name in (
            "time",
            "arc_length",
            "coordinates",
            "layback",
            "excursion",
            "arc_excursion",
        ):
            object.__setattr__(self, name, _readonly(getattr(self, name)))
        touching = np.array(self.touching, dtype=bool, copy=True)
        touching.setflags(write=False)
        object.__setattr__(self, "touching", touching)

    def statistics(self, quantity: str) -> tuple[float, float, float]:
        """Return the minimum, maximum, and mean of a quantity over touching samples.

        Parameters
        ----------
        quantity : str
            ``"arc_length"``, ``"layback"``, ``"excursion"``, or
            ``"arc_excursion"``.

        Returns
        -------
        tuple[float, float, float]
            Minimum, maximum, and mean, in metres.

        Raises
        ------
        ValueError
            If ``quantity`` is unknown or the line never touches down.
        """
        if quantity not in _QUANTITIES:
            raise ValueError(f"quantity must be one of {tuple(_QUANTITIES)}")
        values = getattr(self, quantity)[self.touching]
        if values.size == 0:
            raise ValueError("the line never touches down in this record")
        return float(np.min(values)), float(np.max(values)), float(np.mean(values))

    def plot(self, quantity: str = "arc_length", *, ax: Any = None) -> Any:
        """Plot a touchdown quantity against time.

        Parameters
        ----------
        quantity : str
            ``"arc_length"``, ``"layback"``, ``"excursion"``, or
            ``"arc_excursion"``.
        ax : matplotlib.axes.Axes | None
            Axes to draw on; a new figure is created when omitted.

        Returns
        -------
        matplotlib.axes.Axes
            The axes drawn on.

        Raises
        ------
        ValueError
            If ``quantity`` is unknown.
        """
        if quantity not in _QUANTITIES:
            raise ValueError(f"quantity must be one of {tuple(_QUANTITIES)}")
        plt = pyplot()
        if ax is None:
            _, ax = plt.subplots()
        label, unit = _QUANTITIES[quantity]
        ax.plot(self.time, getattr(self, quantity))
        ax.set_xlabel("Time [s]")
        ax.set_ylabel(f"{label} [{unit}]")
        ax.grid(True)
        return ax

    def export(self, path: str | os.PathLike[str], *, overwrite: bool = False) -> Path:
        """Atomically write the history as a unit-labelled CSV, one row per sample.

        Samples without a touchdown point have empty fields.

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

        def row(index: int) -> tuple[str, ...]:
            if not self.touching[index]:
                return (number(self.time[index]), *([""] * 7))
            values = (
                self.arc_length[index],
                *self.coordinates[index],
                self.layback[index],
                self.excursion[index],
                self.arc_excursion[index],
            )
            return (number(self.time[index]), *(number(value) for value in values))

        return write_csv(
            path,
            (
                "Time_[s]",
                "ArcLength_[m]",
                "X_[m]",
                "Y_[m]",
                "Z_[m]",
                "Layback_[m]",
                "Excursion_[m]",
                "ArcExcursion_[m]",
            ),
            (row(index) for index in range(self.time.size)),
            overwrite=overwrite,
        )


def _positions(
    source: TimeHistory, line_id: int | None
) -> tuple[npt.NDArray[Any], npt.NDArray[Any]]:
    """Return sample times and ``(n_samples, n_nodes, 3)`` node positions."""
    if isinstance(source, (LineNodeHistory, MoorDynLineHistory)):
        if line_id is not None:
            raise ValueError("line_id does not apply to a per-line history")
        if isinstance(source, MoorDynLineHistory):
            names = [
                f"Node{node}{axis}"
                for node in range(source.node_count)
                for axis in ("px", "py", "pz")
            ]
            if any(name not in source.channels for name in names):
                raise KeyError(f"{source.path.name} has no node position channels")
        else:
            names = list(source.channels[1:])
        data = np.column_stack([source.column(name) for name in names])
        return source.time, data.reshape((source.time.size, -1, 3))
    if line_id is None:
        raise ValueError("a main output needs line_id to select the L<L>N<J>p channels")
    channels = node_position_channels(source, line_id)
    data = np.stack(
        [np.column_stack([source.column(name) for name in names]) for names in channels.values()],
        axis=1,
    )
    return source.time, data


def _profile_positions(profile: StaticProfile, line_id: int | None) -> npt.NDArray[Any]:
    identifiers = profile.line_ids
    if line_id is None:
        if len(identifiers) != 1:
            raise ValueError(f"the reference profile holds lines {identifiers}; pass line_id")
        line_id = identifiers[0]
    line = profile.line(line_id)
    return np.column_stack([line.column(axis) for axis in ("X", "Y", "Z")])[None, :, :]


def _locate(
    xyz: npt.NDArray[Any], level: float, end: str
) -> tuple[npt.NDArray[Any], npt.NDArray[Any], npt.NDArray[Any], npt.NDArray[Any]]:
    """Return touching mask, TDP arc, TDP coordinates, and suspended-end xy per sample."""
    if end == "B":
        xyz = xyz[:, ::-1, :]
    chords = np.linalg.norm(np.diff(xyz, axis=1), axis=2)
    arc = np.concatenate((np.zeros((xyz.shape[0], 1)), np.cumsum(chords, axis=1)), axis=1)
    grounded = xyz[:, :, 2] <= level
    touching = grounded[:, 0] & ~np.all(grounded, axis=1)
    lifted = np.argmin(grounded, axis=1)
    last = np.clip(lifted - 1, 0, None)
    rows = np.arange(xyz.shape[0])
    low, high = xyz[rows, last], xyz[rows, np.minimum(last + 1, xyz.shape[1] - 1)]
    rise = high[:, 2] - low[:, 2]
    with np.errstate(divide="ignore", invalid="ignore"):
        fraction = np.clip(np.where(rise > 0.0, (level - low[:, 2]) / rise, 0.0), 0.0, 1.0)
    n = xyz.shape[1]
    quadratic = touching & (last + 2 < n)
    for row in np.nonzero(quadratic)[0]:
        fraction[row] = _quadratic_fraction(xyz[row], int(last[row]), level, fraction[row])
    point = low + fraction[:, None] * (high - low)
    point[touching, 2] = level
    tdp_arc = arc[rows, last] + fraction * chords[rows, np.minimum(last, chords.shape[1] - 1)]
    if end == "B":
        tdp_arc = arc[:, -1] - tdp_arc
    return touching, tdp_arc, point, xyz[:, -1, :2]


def _quadratic_fraction(xyz: npt.NDArray[Any], last: int, level: float, linear: float) -> float:
    """Crossing of ``level`` by the quadratic height through the last grounded node and the
    first two suspended nodes, as a fraction of the first chord (the linear fraction when the
    quadratic has no crossing in the element). The curvature is limited to ``|qa| <= d1/l1``
    so that the height rises monotonically over the element and the crossing is unique: an
    unlimited parabola can dip below ``level`` when the line rises sharply beyond the element,
    and its crossing then jumps by almost an element as the next node grounds. The monotone
    crossing reaches a node exactly when the node reaches ``level``, from either side."""
    g0, g1, g2 = (xyz[last + k, 2] - level for k in range(3))
    l1 = float(np.linalg.norm(xyz[last + 1] - xyz[last]))
    l2 = float(np.linalg.norm(xyz[last + 2] - xyz[last + 1]))
    if not (l1 > 0.0 and l2 > 0.0):
        return linear
    d1 = (g1 - g0) / l1
    qa = ((g2 - g1) / l2 - d1) / (l1 + l2)
    if d1 > 0.0:  # monotone over the element: q'(0) >= 0 and q'(l1) >= 0
        qa = min(max(qa, -d1 / l1), d1 / l1)
    qb = d1 - qa * l1
    if abs(qa) * l1 <= 1e-12 * max(abs(qb), np.finfo(float).tiny):
        return float(np.clip(-g0 / qb / l1, 0.0, 1.0)) if qb != 0.0 else linear
    disc = qb * qb - 4.0 * qa * g0
    if disc < 0.0:
        return linear
    x1 = (-qb - math.sqrt(disc)) / (2.0 * qa) if qb >= 0.0 else (-qb + math.sqrt(disc)) / (2.0 * qa)
    x2 = g0 / (qa * x1) if x1 != 0.0 else 0.0
    inside = [x for x in (x1, x2) if -1e-9 * l1 <= x <= l1 * (1.0 + 1e-9)]
    return float(np.clip(max(inside) / l1, 0.0, 1.0)) if inside else linear


def touchdown_history(
    source: TimeHistory,
    *,
    seabed_z: float,
    tolerance: float = 0.01,
    grounded_end: str | None = None,
    line_id: int | None = None,
    reference: StaticProfile | None = None,
    start: float | None = None,
    stop: float | None = None,
) -> TouchdownHistory:
    """Return the touchdown point of one line at every output time.

    Parameters
    ----------
    source : LineNodeHistory | MoorDynLineHistory | TimeHistory
        Node positions: a per-line position file, or a main output with
        ``L<L>N<J>px``/``py``/``pz`` channels (then ``line_id`` is required).
    seabed_z : float
        Global Z of the flat seabed, in metres.
    tolerance : float
        Non-negative height above the seabed within which a node counts as
        grounded, in metres.
    grounded_end : str | None
        ``"A"`` or ``"B"``. By default the end grounded at the first sample;
        required when both or neither end is grounded then.
    line_id : int | None
        Deck line identifier, for a main output (and to select the line of a
        multi-line ``reference`` profile).
    reference : StaticProfile | None
        Static profile that fixes the reference TDP for the excursions;
        by default the first touching sample.
    start, stop : float | None
        Optional time window, in seconds.

    Returns
    -------
    TouchdownHistory
        TDP arc length, coordinates, layback, and excursions against time.

    Raises
    ------
    KeyError
        If the source lacks node positions.
    ValueError
        If a setting is invalid, fewer than two nodes are available,
        consecutive nodes coincide, the grounded end cannot be chosen, the
        line never touches down, or the reference has no touchdown point.
    """
    seabed = float(seabed_z)
    margin = float(tolerance)
    if not math.isfinite(seabed) or not math.isfinite(margin) or margin < 0.0:
        raise ValueError("seabed_z must be finite and tolerance finite and non-negative")
    view = source.period(start, stop) if start is not None or stop is not None else source
    time, xyz = _positions(view, line_id)
    if xyz.shape[1] < 2:
        raise ValueError("a touchdown history needs at least two nodes")
    if np.any(np.linalg.norm(np.diff(xyz, axis=1), axis=2) <= 0.0):
        raise ValueError("consecutive line nodes must not coincide")
    level = seabed + margin
    if grounded_end is None:
        first = xyz[0, :, 2] <= level
        if first[0] == first[-1]:
            raise ValueError("cannot infer the grounded end at the first sample; pass grounded_end")
        end = "A" if first[0] else "B"
    else:
        end = str(grounded_end).upper()
        if end not in {"A", "B"}:
            raise ValueError("grounded_end must be 'A' or 'B'")
    touching, arc, point, suspended = _locate(xyz, level, end)
    if not np.any(touching):
        raise ValueError("the line never touches down at the selected end in this record")
    if reference is not None:
        ref_touch, ref_arc, ref_point, ref_suspended = _locate(
            _profile_positions(reference, line_id), level, end
        )
        if not ref_touch[0]:
            raise ValueError("the reference profile has no touchdown point at the selected end")
        base_arc, base_xy, base_suspended = ref_arc[0], ref_point[0, :2], ref_suspended[0]
    else:
        index = int(np.argmax(touching))
        base_arc, base_xy, base_suspended = arc[index], point[index, :2], suspended[index]
    direction = base_suspended - base_xy
    span = float(np.linalg.norm(direction))
    if span <= 0.0:
        raise ValueError("the reference TDP lies below the suspended end; excursion is undefined")
    direction = direction / span
    nan = np.where(touching, 1.0, np.nan)
    return TouchdownHistory(
        time=time,
        touching=touching,
        arc_length=arc * nan,
        coordinates=point * nan[:, None],
        layback=np.linalg.norm(suspended - point[:, :2], axis=1) * nan,
        excursion=((point[:, :2] - base_xy) @ direction) * nan,
        arc_excursion=(arc - base_arc) * nan,
        grounded_end=end,
        seabed_z=seabed,
        tolerance=margin,
        reference_arc_length=float(base_arc),
        source=view.path,
    )
