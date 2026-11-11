# SPDX-License-Identifier: Apache-2.0
"""Line geometry derived from node coordinates.

:func:`line_geometry` takes the node coordinates of one line, from a static
profile, from a dynamic per-line position history at one time, from a MoorDyn
line file, or from an ``(n, 3)`` array, in End-A-to-End-B order, and returns a
:class:`LineGeometry` with chord arc length, inclination, and a discrete
curvature estimate. :meth:`LineGeometry.touchdown` locates the touchdown
point on a flat seabed.

These are geometric post-processing estimates from the output nodes only. The
solver's own ``Curvature``, ``Tension``, and angle channels, where written,
are the authoritative values: the discrete curvature here is the curvature of
the circle through three consecutive nodes and depends on the output
discretization.
"""

from __future__ import annotations

import contextlib
import csv
import math
import os
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
import numpy.typing as npt

from cabledyn.formats import MoorDynLineHistory
from cabledyn.results import LineNodeHistory, StaticProfile

__all__ = ["LineGeometry", "Touchdown", "line_geometry"]


def _readonly(values: npt.ArrayLike) -> npt.NDArray[Any]:
    result = np.array(values, dtype=np.float64, copy=True)
    result.setflags(write=False)
    return result


@dataclass(frozen=True)
class Touchdown:
    """Touchdown point of a line on a flat seabed.

    The estimate resolves the touchdown to one output segment.

    Attributes
    ----------
    node : int
        Zero-based index of the last grounded node before the line lifts off,
        counted in End-A-to-End-B order.
    arc_length : float
        Chord arc length from End A to the touchdown node, in metres.
    coordinates : numpy.ndarray
        Read-only ``(3,)`` global X, Y, Z of the touchdown node, in metres.
    grounded_end : str
        ``"A"`` or ``"B"``: the end whose run lies on the seabed.
    grounded_length : float
        Chord length from the grounded end to the touchdown node, in metres.
    suspended_length : float
        Chord length from the touchdown node to the suspended end, in metres.
    layback : float
        Horizontal distance from the touchdown node to the suspended end, in
        metres.
    """

    node: int
    arc_length: float
    coordinates: npt.NDArray[Any]
    grounded_end: str
    grounded_length: float
    suspended_length: float
    layback: float

    def __post_init__(self) -> None:
        object.__setattr__(self, "coordinates", _readonly(self.coordinates))


@dataclass(frozen=True)
class LineGeometry:
    """Node-based geometry of one line in End-A-to-End-B order.

    Arrays are read-only and have one row per node.

    Attributes
    ----------
    coordinates : numpy.ndarray
        ``(n, 3)`` global X, Y, Z, in metres.
    arc_length : numpy.ndarray
        ``(n,)`` cumulative chord length from End A, in metres.
    inclination : numpy.ndarray
        ``(n,)`` angle of the local tangent above the horizontal plane, in
        degrees (positive when the line rises towards End B), from central
        differences at interior nodes and one-sided differences at the ends.
    curvature : numpy.ndarray
        ``(n,)`` inverse radius of the circle through each interior node and
        its two neighbours, in 1/m; ``nan`` at the two end nodes.
    """

    coordinates: npt.NDArray[Any]
    arc_length: npt.NDArray[Any]
    inclination: npt.NDArray[Any]
    curvature: npt.NDArray[Any]

    def __post_init__(self) -> None:
        for name in ("coordinates", "arc_length", "inclination", "curvature"):
            object.__setattr__(self, name, _readonly(getattr(self, name)))

    @property
    def length(self) -> float:
        """Total chord length in metres."""
        return float(self.arc_length[-1])

    @property
    def horizontal_span(self) -> float:
        """Horizontal distance between End A and End B in metres."""
        return float(np.linalg.norm(self.coordinates[-1, :2] - self.coordinates[0, :2]))

    @property
    def vertical_span(self) -> float:
        """Height of End B above End A in metres."""
        return float(self.coordinates[-1, 2] - self.coordinates[0, 2])

    @property
    def minimum_bend_radius(self) -> float:
        """Smallest discrete bend radius in metres (``inf`` for a straight line)."""
        largest = float(np.nanmax(self.curvature)) if self.curvature.size > 2 else 0.0
        return 1.0 / largest if largest > 0.0 else float("inf")

    def touchdown(
        self, seabed_z: float, *, tolerance: float = 0.01, grounded_end: str | None = None
    ) -> Touchdown | None:
        """Locate where the line lifts off a flat seabed at ``z = seabed_z``.

        A node is grounded when ``z <= seabed_z + tolerance``. The grounded
        run must start at one end of the line. ``grounded_end`` (``"A"`` or
        ``"B"``) chooses the end when both are grounded; by default exactly
        one end must be grounded.

        Parameters
        ----------
        seabed_z : float
            Global Z of the flat seabed, in metres.
        tolerance : float
            Non-negative height above the seabed, in metres, within which a
            node counts as grounded.
        grounded_end : str | None
            ``"A"`` or ``"B"``; required only when both ends are grounded.

        Returns
        -------
        Touchdown | None
            The touchdown point, or ``None`` when the line does not touch the
            seabed at the selected end or lies on it entirely.

        Raises
        ------
        ValueError
            If ``seabed_z`` or ``tolerance`` is invalid, ``grounded_end`` is
            not ``"A"`` or ``"B"``, or both ends are grounded and
            ``grounded_end`` is omitted.
        """
        seabed = float(seabed_z)
        margin = float(tolerance)
        if not math.isfinite(seabed) or not math.isfinite(margin) or margin < 0.0:
            raise ValueError("seabed_z must be finite and tolerance finite and non-negative")
        grounded = self.coordinates[:, 2] <= seabed + margin
        if grounded_end is None:
            if grounded[0] and grounded[-1] and not np.all(grounded):
                raise ValueError("both ends are grounded; pass grounded_end='A' or 'B'")
            end = "A" if grounded[0] else "B"
        else:
            end = grounded_end.upper()
            if end not in {"A", "B"}:
                raise ValueError("grounded_end must be 'A' or 'B'")
        if np.all(grounded) or not (grounded[0] if end == "A" else grounded[-1]):
            return None
        if end == "A":
            node = int(np.argmin(grounded)) - 1
            free_end = self.coordinates[-1]
            grounded_length = float(self.arc_length[node])
        else:
            node = grounded.size - int(np.argmin(grounded[::-1]))
            free_end = self.coordinates[0]
            grounded_length = float(self.arc_length[-1] - self.arc_length[node])
        point = self.coordinates[node]
        return Touchdown(
            node=node,
            arc_length=float(self.arc_length[node]),
            coordinates=point,
            grounded_end=end,
            grounded_length=grounded_length,
            suspended_length=self.length - grounded_length,
            layback=float(np.linalg.norm(free_end[:2] - point[:2])),
        )

    def export(self, path: str | os.PathLike[str], *, overwrite: bool = False) -> Path:
        """Atomically write a unit-labelled CSV with one row per node.

        The columns are ``Node_[-]`` (one-based), ``ArcLength_[m]``,
        ``X_[m]``, ``Y_[m]``, ``Z_[m]``, ``Inclination_[deg]``, and
        ``Curvature_[1/m]``.

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
        """
        target = Path(path).expanduser().resolve()
        if target.exists() and not overwrite:
            raise FileExistsError(f"output already exists: {target}")
        target.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(
            prefix=f".{target.name}.", suffix=".tmp", dir=target.parent, text=True
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
                writer = csv.writer(stream, lineterminator="\n")
                writer.writerow(
                    (
                        "Node_[-]",
                        "ArcLength_[m]",
                        "X_[m]",
                        "Y_[m]",
                        "Z_[m]",
                        "Inclination_[deg]",
                        "Curvature_[1/m]",
                    )
                )
                for index in range(self.arc_length.size):
                    x, y, z = self.coordinates[index]
                    writer.writerow(
                        (
                            str(index + 1),
                            *(
                                f"{value:.17g}"
                                for value in (
                                    self.arc_length[index],
                                    x,
                                    y,
                                    z,
                                    self.inclination[index],
                                    self.curvature[index],
                                )
                            ),
                        )
                    )
            os.replace(temporary, target)
        except BaseException:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(temporary)
            raise
        return target


def _coordinates(
    source: StaticProfile | LineNodeHistory | MoorDynLineHistory | npt.ArrayLike,
    line_id: int | None,
    time: float | None,
) -> npt.NDArray[Any]:
    if isinstance(source, StaticProfile):
        if time is not None:
            raise ValueError("time does not apply to a static profile")
        identifiers = source.line_ids
        if line_id is None:
            if len(identifiers) != 1:
                raise ValueError(f"the profile holds lines {identifiers}; pass line_id")
            line_id = identifiers[0]
        line = source.line(line_id)
        return np.column_stack([line.column(axis) for axis in ("X", "Y", "Z")])
    if isinstance(source, (LineNodeHistory, MoorDynLineHistory)):
        if line_id is not None:
            raise ValueError("line_id does not apply to a per-line history")
        if time is None:
            raise ValueError("a line history needs the snapshot time")
        if isinstance(source, MoorDynLineHistory):
            return np.asarray(source.positions(time))
        return np.asarray(source.coordinates(time))
    if line_id is not None or time is not None:
        raise ValueError("line_id and time apply only to result tables")
    return np.asarray(source, dtype=np.float64)


def line_geometry(
    source: StaticProfile | LineNodeHistory | MoorDynLineHistory | npt.ArrayLike,
    *,
    line_id: int | None = None,
    time: float | None = None,
) -> LineGeometry:
    """Return the node-based geometry of one line.

    Parameters
    ----------
    source : StaticProfile | LineNodeHistory | MoorDynLineHistory | array_like
        A static profile with ``X``, ``Y``, and ``Z`` columns, a dynamic
        per-line position history (CableDyn or MoorDyn), or an ``(n, 3)``
        array of node coordinates in metres with ``n >= 2``, in
        End-A-to-End-B order.
    line_id : int | None
        Line to take from a static profile; required when the profile holds
        several lines. Not allowed for other sources.
    time : float | None
        Snapshot time, in seconds, for a line history (linearly
        interpolated). Required for a line history; not allowed otherwise.

    Returns
    -------
    LineGeometry
        Coordinates and arc length in metres, inclination in degrees, and
        curvature in 1/m, one row per node.

    Raises
    ------
    KeyError
        If ``line_id`` or a coordinate column is missing from the profile, or
        the history lacks node positions.
    ValueError
        If ``line_id`` or ``time`` is missing or not applicable, ``time`` is
        outside the record, the coordinates are not a finite ``(n, 3)`` array
        with ``n >= 2``, or consecutive nodes coincide.
    """
    xyz = np.array(_coordinates(source, line_id, time), dtype=np.float64, copy=True)
    if xyz.ndim != 2 or xyz.shape[1] != 3 or xyz.shape[0] < 2 or not np.all(np.isfinite(xyz)):
        raise ValueError("line coordinates must be a finite (n, 3) array with n >= 2")
    chords = np.linalg.norm(np.diff(xyz, axis=0), axis=1)
    if np.any(chords <= 0.0):
        raise ValueError("consecutive line nodes must not coincide")
    arc = np.concatenate(([0.0], np.cumsum(chords)))
    tangent = np.gradient(xyz, arc, axis=0, edge_order=1)
    horizontal = np.linalg.norm(tangent[:, :2], axis=1)
    inclination = np.degrees(np.arctan2(tangent[:, 2], horizontal))
    curvature = np.full(xyz.shape[0], np.nan)
    if xyz.shape[0] >= 3:
        first, second = xyz[1:-1] - xyz[:-2], xyz[2:] - xyz[1:-1]
        third = xyz[2:] - xyz[:-2]
        area2 = np.linalg.norm(np.cross(first, second), axis=1)
        denominator = (
            np.linalg.norm(first, axis=1)
            * np.linalg.norm(second, axis=1)
            * np.linalg.norm(third, axis=1)
        )
        curvature[1:-1] = 2.0 * area2 / denominator
    return LineGeometry(xyz, arc, inclination, curvature)
