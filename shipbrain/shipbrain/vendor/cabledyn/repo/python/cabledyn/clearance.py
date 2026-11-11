# SPDX-License-Identifier: Apache-2.0
"""Line-to-seabed and line-to-line clearance from node positions.

* :func:`seabed_clearance` -- the vertical clearance of every node above a
  flat seabed or a :class:`Bathymetry` surface ``z_floor(x, y)``, at every
  sample, with the minimum and where and when it occurs. This matches the
  solver's ``Clearance`` range-graph quantity: ``z - z_floor(x, y)``, minus an
  optional contact radius.
* :func:`line_clearance` -- the minimum distance between two lines at every
  sample, measured between their node-to-node polylines (segment to segment,
  not only node to node), with the arc length of the closest point on each
  line.
* :func:`clearance_matrix` -- :func:`line_clearance` for every pair of a set
  of lines.
* :func:`read_bathymetry` -- read the solver's ``x y depth`` bathymetry file.

Positions come from any source accepted by :func:`cabledyn.line_positions`:
a per-line position file, a MoorDyn-F line file, the ``L<L>N<J>p[xyz]``
channels of a main output, a static profile, or an array. Arc lengths are the
deformed chord lengths from End A at the sample. Lines that share an end point
(a common fairlead or anchor) have zero centreline distance there; pass only
the nodes of interest as an array to exclude it.
"""

from __future__ import annotations

import os
import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
import numpy.typing as npt

from cabledyn._csv import number, write_csv
from cabledyn._optional import pyplot
from cabledyn.profiles import (
    ArcProfile,
    Interpolation,
    LinePositions,
    PositionSource,
    _at,
    _file_line_id,
    line_positions,
)
from cabledyn.ranges import RangeGraph

__all__ = [
    "Bathymetry",
    "ClearanceMatrix",
    "LineClearance",
    "SeabedClearance",
    "clearance_matrix",
    "line_clearance",
    "read_bathymetry",
    "seabed_clearance",
    "segment_distance",
]

# Pairwise segment arrays are processed in time chunks of at most this many
# (sample, segment, segment) entries, bounding the temporary memory.
_CHUNK = 250_000
_PLAIN_NUMBER = re.compile(r"[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?")
# Crease rounding of the bathymetry surface, as in the solver (CableDyn_Bathymetry): band
# half-width as a fraction of the smaller grid spacing next to a line, and the smallest
# surface change [m] a crease must make to be rounded.
_CREASE_FRACTION = 0.05
_CREASE_MIN_HEIGHT = 1.0e-6


def _readonly(values: npt.ArrayLike, dtype: Any = np.float64) -> npt.NDArray[Any]:
    result = np.array(values, dtype=dtype, copy=True)
    result.setflags(write=False)
    return result


def _radius(value: float, name: str) -> float:
    radius = float(value)
    if not np.isfinite(radius) or radius < 0.0:
        raise ValueError(f"{name} must be finite and non-negative")
    return radius


@dataclass(frozen=True)
class Bathymetry:
    """A structured seabed: water depth on a rectangular ``x``-``y`` grid.

    The seabed elevation is ``z_floor = -depth``. Between grid points it is
    bilinear in each cell, with the creases of that surface along the interior
    grid lines rounded within a narrow band (the C2 fillet of the solver: a
    crease with slope jump ``J`` is moved by ``J (delta - |u|)^3 / (6 delta^2)`` at
    distance ``|u| < delta`` from its line, ``delta`` five per cent of the smaller
    spacing next to it); outside the grid it takes the value at the nearest grid
    edge, as in the solver.

    Attributes
    ----------
    x : numpy.ndarray
        ``(nx,)`` strictly increasing grid coordinates, in metres, ``nx >= 2``.
    y : numpy.ndarray
        ``(ny,)`` strictly increasing grid coordinates, in metres, ``ny >= 2``.
    depth : numpy.ndarray
        ``(nx, ny)`` positive water depth below still water, in metres.
    source : pathlib.Path | None
        File the grid was read from, if any.

    Raises
    ------
    ValueError
        If an axis has fewer than two points or does not strictly increase,
        ``depth`` does not have shape ``(nx, ny)``, or a value is not finite or
        a depth is not positive.
    """

    x: npt.NDArray[Any]
    y: npt.NDArray[Any]
    depth: npt.NDArray[Any]
    source: Path | None = None

    def __post_init__(self) -> None:
        for name in ("x", "y"):
            axis = _readonly(getattr(self, name))
            if axis.ndim != 1 or axis.size < 2 or not np.all(np.isfinite(axis)):
                raise ValueError(f"{name} must be a finite one-dimensional grid of >= 2 points")
            if np.any(np.diff(axis) <= 0.0):
                raise ValueError(f"{name} must be strictly increasing")
            object.__setattr__(self, name, axis)
        depth = _readonly(self.depth)
        if depth.shape != (self.x.size, self.y.size):
            raise ValueError("depth must have shape (x.size, y.size)")
        if not np.all(np.isfinite(depth)) or np.any(depth <= 0.0):
            raise ValueError("depth must be finite and positive")
        object.__setattr__(self, "depth", depth)
        if self.source is not None:
            object.__setattr__(self, "source", Path(self.source).expanduser().resolve())

    def depth_at(self, x: npt.ArrayLike, y: npt.ArrayLike) -> npt.NDArray[Any]:
        """Return the water depth at points ``(x, y)``, in metres.

        Parameters
        ----------
        x, y : array_like
            Horizontal coordinates in metres; broadcast against each other.

        Returns
        -------
        numpy.ndarray
            Positive depth, with the broadcast shape of ``x`` and ``y``.

        Raises
        ------
        ValueError
            If a coordinate is not finite.
        """
        qx, qy = np.broadcast_arrays(
            np.asarray(x, dtype=np.float64), np.asarray(y, dtype=np.float64)
        )
        if not (np.all(np.isfinite(qx)) and np.all(np.isfinite(qy))):
            raise ValueError("bathymetry query coordinates must be finite")
        ix, tx = _cell(self.x, qx)
        iy, ty = _cell(self.y, qy)
        d = self.depth
        bilinear = (
            (1.0 - tx) * (1.0 - ty) * d[ix, iy]
            + tx * (1.0 - ty) * d[ix + 1, iy]
            + (1.0 - tx) * ty * d[ix, iy + 1]
            + tx * ty * d[ix + 1, iy + 1]
        )
        return np.asarray(bilinear - self._crease_rounding(qx, qy, ix, iy, tx, ty))

    def _crease_rounding(
        self,
        qx: npt.NDArray[Any],
        qy: npt.NDArray[Any],
        ix: npt.NDArray[Any],
        iy: npt.NDArray[Any],
        tx: npt.NDArray[Any],
        ty: npt.NDArray[Any],
    ) -> npt.NDArray[Any]:
        """Rise of the rounded surface over the bilinear one (zero outside the bands).

        ``hx Jx(y) + hy (Jy(x) + hx M)``: ``J`` the slope jumps of the grid rows
        (columns) across the line, interpolated linearly along it, ``M`` the mixed
        second difference at a crossing of two lines, ``h`` the fillet.
        """
        kx, hx = _crease_band(self.x, ix, qx)
        ky, hy = _crease_band(self.y, iy, qy)
        z = -self.depth
        rise = np.zeros(np.shape(qx))
        on_x = kx >= 0
        on_y = ky >= 0
        if not (np.any(on_x) or np.any(on_y)):
            return rise
        kxs = np.clip(kx, 1, self.x.size - 2)
        kys = np.clip(ky, 1, self.y.size - 2)
        dlx = _CREASE_FRACTION * np.minimum(
            self.x[kxs] - self.x[kxs - 1], self.x[kxs + 1] - self.x[kxs]
        )
        dly = _CREASE_FRACTION * np.minimum(
            self.y[kys] - self.y[kys - 1], self.y[kys + 1] - self.y[kys]
        )

        def jump_x(j: npt.NDArray[Any]) -> npt.NDArray[Any]:
            jump = (z[kxs + 1, j] - z[kxs, j]) / (self.x[kxs + 1] - self.x[kxs]) - (
                z[kxs, j] - z[kxs - 1, j]
            ) / (self.x[kxs] - self.x[kxs - 1])
            return np.where(np.abs(jump) * dlx / 6.0 > _CREASE_MIN_HEIGHT, jump, 0.0)

        def jump_y(i: npt.NDArray[Any]) -> npt.NDArray[Any]:
            jump = (z[i, kys + 1] - z[i, kys]) / (self.y[kys + 1] - self.y[kys]) - (
                z[i, kys] - z[i, kys - 1]
            ) / (self.y[kys] - self.y[kys - 1])
            return np.where(np.abs(jump) * dly / 6.0 > _CREASE_MIN_HEIGHT, jump, 0.0)

        jx = (1.0 - ty) * jump_x(iy) + ty * jump_x(iy + 1)
        jy = (1.0 - tx) * jump_y(ix) + tx * jump_y(ix + 1)
        mxy = (jump_x(kys + 1) - jump_x(kys)) / (self.y[kys + 1] - self.y[kys]) - (
            jump_x(kys) - jump_x(kys - 1)
        ) / (self.y[kys] - self.y[kys - 1])
        mxy = np.where(
            on_x & on_y & (np.abs(mxy) * dlx * dly / 36.0 > _CREASE_MIN_HEIGHT), mxy, 0.0
        )
        rise = np.where(on_x, hx * jx, 0.0) + np.where(on_y, hy * (jy + hx * mxy), 0.0)
        return np.asarray(rise)

    def floor(self, x: npt.ArrayLike, y: npt.ArrayLike) -> npt.NDArray[Any]:
        """Return the seabed elevation ``z_floor = -depth`` at points ``(x, y)``.

        Parameters
        ----------
        x, y : array_like
            Horizontal coordinates in metres; broadcast against each other.

        Returns
        -------
        numpy.ndarray
            Seabed elevation in metres (negative below still water).

        Raises
        ------
        ValueError
            If a coordinate is not finite.
        """
        return -self.depth_at(x, y)


def _cell(
    axis: npt.NDArray[Any], query: npt.NDArray[Any]
) -> tuple[npt.NDArray[Any], npt.NDArray[Any]]:
    """Cell index and clamped fraction of each query along one grid axis."""
    index = np.clip(np.searchsorted(axis, query, side="right") - 1, 0, axis.size - 2)
    fraction = (query - axis[index]) / (axis[index + 1] - axis[index])
    return index, np.clip(fraction, 0.0, 1.0)


def _crease_band(
    axis: npt.NDArray[Any], index: npt.NDArray[Any], query: npt.NDArray[Any]
) -> tuple[npt.NDArray[Any], npt.NDArray[Any]]:
    """Interior grid line whose crease band holds each query (-1: none) and the fillet there.

    The fillet is ``(delta - |u|)^3 / (6 delta^2)``, ``u`` the distance from the line and
    ``delta`` the band half-width; a query outside the grid lies in no band.
    """
    n = axis.size
    inside = (query >= axis[0]) & (query <= axis[-1])
    line = np.full(np.shape(query), -1)
    fillet = np.zeros(np.shape(query))
    for k in (index, index + 1):
        interior = inside & (k >= 1) & (k <= n - 2) & (line < 0)
        ks = np.clip(k, 1, max(n - 2, 1))
        if n < 3:
            continue
        delta = _CREASE_FRACTION * np.minimum(axis[ks] - axis[ks - 1], axis[ks + 1] - axis[ks])
        u = np.abs(query - axis[ks])
        hit = interior & (u < delta)
        line = np.where(hit, k, line)
        fillet = np.where(hit, (delta - u) ** 3 / (6.0 * delta * delta), fillet)
    return line, fillet


def _strip_comment(text: str) -> str:
    """Strip ``#``/``!`` comments and a ``--`` comment that starts a token."""
    cut = len(text)
    for mark in ("#", "!"):
        position = text.find(mark)
        if position >= 0:
            cut = min(cut, position)
    if "---" not in text:
        match = re.search(r"(?:^|\s)--", text)
        if match is not None:
            cut = min(cut, match.end() - 2)
    return text[:cut]


def read_bathymetry(path: str | os.PathLike[str]) -> Bathymetry:
    """Read a structured bathymetry file of ``x y depth`` rows.

    This is the file a deck names with the ``bathymetryFile`` option. Rows may
    be in any order but must form one complete rectangular grid without
    duplicates; blank lines and ``#``, ``!``, or ``--`` comments are ignored.

    Parameters
    ----------
    path : str | os.PathLike
        Bathymetry file.

    Returns
    -------
    Bathymetry
        The grid, with ``x`` and ``y`` sorted.

    Raises
    ------
    FileNotFoundError
        If the file does not exist.
    ValueError
        If a row is not three plain numbers, a depth is not positive, or the
        rows do not form one complete grid.
    """
    source = Path(path).expanduser().resolve()
    rows: list[tuple[float, float, float]] = []
    text = source.read_text(encoding="utf-8-sig")
    for number_, line in enumerate(text.splitlines(), start=1):
        tokens = _strip_comment(line).split()
        if not tokens:
            continue
        if len(tokens) != 3 or not all(_PLAIN_NUMBER.fullmatch(token) for token in tokens):
            raise ValueError(f"{source}:{number_}: rows must be 'x y depth' as plain numbers")
        rows.append((float(tokens[0]), float(tokens[1]), float(tokens[2])))
    if len(rows) < 4:
        raise ValueError(f"{source}: bathymetry file needs at least a 2x2 grid")
    data = np.asarray(rows, dtype=np.float64)
    if not np.all(np.isfinite(data)):
        raise ValueError(f"{source}: bathymetry coordinates and depths must be finite")
    if np.any(data[:, 2] <= 0.0):
        raise ValueError(f"{source}: bathymetry depths must be positive")
    xs, ys = _unique(data[:, 0]), _unique(data[:, 1])
    if data.shape[0] != xs.size * ys.size:
        raise ValueError(f"{source}: bathymetry file must define one complete rectangular grid")
    depth = np.full((xs.size, ys.size), np.nan)
    for x, y, value in data:
        ix, iy = _grid_index(xs, x), _grid_index(ys, y)
        if not np.isnan(depth[ix, iy]):
            raise ValueError(f"{source}: bathymetry file has duplicate x/y entries")
        depth[ix, iy] = value
    return Bathymetry(xs, ys, depth, source)


def _same(a: float, b: float) -> bool:
    """The solver's coordinate equality: within 16 ulp relative to max(1, |a|, |b|)."""
    return bool(abs(a - b) <= 16.0 * np.finfo(np.float64).eps * max(1.0, abs(a), abs(b)))


def _unique(values: npt.NDArray[Any]) -> npt.NDArray[Any]:
    ordered = np.sort(values)
    unique = [float(ordered[0])]
    for value in ordered[1:]:
        if not _same(float(value), unique[-1]):
            unique.append(float(value))
    return np.asarray(unique)


def _grid_index(axis: npt.NDArray[Any], value: float) -> int:
    index = int(np.argmin(np.abs(axis - value)))
    assert _same(float(axis[index]), value)  # every value produced the axis
    return index


def segment_distance(
    p1: npt.ArrayLike, q1: npt.ArrayLike, p2: npt.ArrayLike, q2: npt.ArrayLike
) -> tuple[npt.NDArray[Any], npt.NDArray[Any], npt.NDArray[Any]]:
    """Return the minimum distance between segments ``p1-q1`` and ``p2-q2``.

    The closest points are ``p1 + s (q1 - p1)`` and ``p2 + t (q2 - p2)`` with
    ``0 <= s, t <= 1``. Zero-length segments are points. For parallel
    segments, one of the equally close pairs is returned. The inputs broadcast
    over any leading dimensions.

    Parameters
    ----------
    p1, q1, p2, q2 : array_like
        End points, shape ``(..., 3)``.

    Returns
    -------
    tuple[numpy.ndarray, numpy.ndarray, numpy.ndarray]
        ``(distance, s, t)``, each of the broadcast leading shape.

    Raises
    ------
    ValueError
        If a point does not have three coordinates or is not finite.
    """
    arrays = [np.asarray(value, dtype=np.float64) for value in (p1, q1, p2, q2)]
    if any(array.shape[-1:] != (3,) for array in arrays):
        raise ValueError("segment end points must have three coordinates")
    if not all(np.all(np.isfinite(array)) for array in arrays):
        raise ValueError("segment end points must be finite")
    return _segment_distance(*arrays)


def _segment_distance(
    p1: npt.NDArray[Any], q1: npt.NDArray[Any], p2: npt.NDArray[Any], q2: npt.NDArray[Any]
) -> tuple[npt.NDArray[Any], npt.NDArray[Any], npt.NDArray[Any]]:
    """Closest points of two segments (Ericson, Real-Time Collision Detection, 5.1.9)."""
    d1, d2, r = q1 - p1, q2 - p2, p1 - p2
    a = np.einsum("...i,...i->...", d1, d1)
    e = np.einsum("...i,...i->...", d2, d2)
    b = np.einsum("...i,...i->...", d1, d2)
    c = np.einsum("...i,...i->...", d1, r)
    f = np.einsum("...i,...i->...", d2, r)
    a, b, c, e, f = np.broadcast_arrays(a, b, c, e, f)
    point_a, point_b = a == 0.0, e == 0.0
    with np.errstate(divide="ignore", invalid="ignore"):
        denominator = a * e - b * b
        s = np.where(
            denominator > 1.0e-12 * a * e, np.clip((b * f - c * e) / denominator, 0.0, 1.0), 0.0
        )
        t = (b * s + f) / e
        s = np.where(
            t < 0.0,
            np.clip(-c / a, 0.0, 1.0),
            np.where(t > 1.0, np.clip((b - c) / a, 0.0, 1.0), s),
        )
        t = np.clip(t, 0.0, 1.0)
        # a zero-length first segment: project its point on the second
        s = np.where(point_a, 0.0, s)
        t = np.where(point_a & ~point_b, np.clip(f / e, 0.0, 1.0), t)
        # a zero-length second segment: project its point on the first
        t = np.where(point_b, 0.0, t)
        s = np.where(point_b & ~point_a, np.clip(-c / a, 0.0, 1.0), s)
    gap = (p1 + s[..., None] * d1) - (p2 + t[..., None] * d2)
    return np.sqrt(np.einsum("...i,...i->...", gap, gap)), s, t


@dataclass(frozen=True)
class SeabedClearance:
    """Vertical clearance of every node of one line above the seabed.

    Attributes
    ----------
    time : numpy.ndarray | None
        ``(n_samples,)`` sample times in seconds, or ``None`` for a static
        configuration.
    node_ids : numpy.ndarray
        ``(n_nodes,)`` node numbers as the source names them.
    arc_length : numpy.ndarray
        ``(n_samples, n_nodes)`` deformed arc length from End A, in metres.
    clearance : numpy.ndarray
        ``(n_samples, n_nodes)`` clearance ``z - z_floor(x, y) - radius``, in
        metres; negative where the node is below the seabed surface.
    radius : float
        Radius subtracted from the centreline clearance, in metres.
    source : pathlib.Path | None
        Result file of the positions, if any.
    line_id : int | None
        Deck line identifier, when known (from ``line_id`` or the name of a
        per-line result file).
    """

    time: npt.NDArray[Any] | None
    node_ids: npt.NDArray[Any]
    arc_length: npt.NDArray[Any]
    clearance: npt.NDArray[Any]
    radius: float = 0.0
    source: Path | None = None
    line_id: int | None = None

    def __post_init__(self) -> None:
        clearance = _readonly(self.clearance)
        if clearance.ndim != 2 or 0 in clearance.shape or not np.all(np.isfinite(clearance)):
            raise ValueError("clearance must be a finite, non-empty (n_samples, n_nodes) array")
        arc = _readonly(self.arc_length)
        if arc.shape != clearance.shape or not np.all(np.isfinite(arc)):
            raise ValueError("arc_length must be finite and match clearance")
        node_ids = _readonly(self.node_ids, np.int64)
        if node_ids.shape != (clearance.shape[1],):
            raise ValueError("node_ids must hold one identifier per node")
        if self.time is not None:
            time = _readonly(self.time)
            if time.shape != (clearance.shape[0],):
                raise ValueError("time must hold one entry per sample")
            object.__setattr__(self, "time", time)
        elif clearance.shape[0] != 1:
            raise ValueError("a static clearance holds exactly one sample")
        object.__setattr__(self, "clearance", clearance)
        object.__setattr__(self, "arc_length", arc)
        object.__setattr__(self, "node_ids", node_ids)
        object.__setattr__(self, "radius", _radius(self.radius, "radius"))
        if self.source is not None:
            object.__setattr__(self, "source", Path(self.source).expanduser().resolve())

    @property
    def minimum(self) -> float:
        """Smallest clearance of any node at any sample, in metres."""
        return float(np.min(self.clearance))

    @property
    def minimum_index(self) -> tuple[int, int]:
        """``(sample, node)`` array indices of :attr:`minimum` (the first, if repeated)."""
        sample, node = np.unravel_index(int(np.argmin(self.clearance)), self.clearance.shape)
        return int(sample), int(node)

    @property
    def minimum_time(self) -> float | None:
        """Time of :attr:`minimum` in seconds, or ``None`` when static."""
        return None if self.time is None else float(self.time[self.minimum_index[0]])

    @property
    def minimum_node(self) -> int:
        """Node number of :attr:`minimum`."""
        return int(self.node_ids[self.minimum_index[1]])

    @property
    def minimum_arc_length(self) -> float:
        """Arc length from End A of :attr:`minimum`, in metres, at its time."""
        return float(self.arc_length[self.minimum_index])

    @property
    def node_minimum(self) -> npt.NDArray[Any]:
        """``(n_nodes,)`` smallest clearance of each node over time."""
        return _readonly(np.min(self.clearance, axis=0))

    @property
    def sample_minimum(self) -> npt.NDArray[Any]:
        """``(n_samples,)`` smallest clearance along the line at each sample."""
        return _readonly(np.min(self.clearance, axis=1))

    @property
    def location(self) -> npt.NDArray[Any]:
        """``(n_nodes,)`` time-mean arc length of each node, in metres."""
        return _readonly(np.mean(self.arc_length, axis=0))

    def profile(
        self, time: float | None = None, *, interpolation: Interpolation = "linear"
    ) -> ArcProfile:
        """Return the clearance along the line at one time.

        Parameters
        ----------
        time : float | None
            Time in seconds; ``None`` for a static configuration and required
            otherwise.
        interpolation : {"linear", "nearest"}
            Linear interpolation between the bracketing samples, or the
            nearest sample.

        Returns
        -------
        ArcProfile
            Quantity ``"seabed_clearance"`` in metres against arc length.

        Raises
        ------
        ValueError
            If ``time`` is missing, not applicable, or outside the record.
        """
        values = _at(self.time, self.clearance, time, interpolation)
        arc = _at(self.time, self.arc_length, time, interpolation)
        return ArcProfile(
            quantity="seabed_clearance",
            unit="m",
            location_kind="ArcLength",
            location=arc,
            ids=self.node_ids,
            values=values,
            time=None if time is None else float(time),
            source=self.source,
        )

    def range_graph(self, line_id: int | None = None) -> RangeGraph:
        """Return the clearance envelope along the line as a range graph.

        Each node is placed at its time-mean arc length (:attr:`location`).

        Parameters
        ----------
        line_id : int | None
            Line identifier recorded in the graph; by default
            :attr:`line_id` (``None`` when unknown).

        Returns
        -------
        RangeGraph
            Quantity ``"clearance"`` in metres, with the minimum, maximum, and
            mean clearance of each node.

        Raises
        ------
        ValueError
            If the positions did not come from a result file.
        """
        if self.source is None:
            raise ValueError("a range graph needs the source result file")
        window = None if self.time is None else (float(self.time[0]), float(self.time[-1]))
        order = np.argsort(self.location, kind="stable")
        return RangeGraph(
            line_id=self.line_id if line_id is None else line_id,
            quantity="clearance",
            unit="m",
            location_kind="ArcLength",
            location=self.location[order],
            maximum=np.max(self.clearance, axis=0)[order],
            minimum=self.node_minimum[order],
            mean=np.mean(self.clearance, axis=0)[order],
            source=self.source,
            time_window=window,
        )

    def plot(self, *, ax: Any = None) -> Any:
        """Plot the minimum clearance along the line against time.

        A static clearance is plotted against arc length instead.

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
        if self.time is None:
            ax.plot(self.arc_length[0], self.clearance[0])
            ax.set_xlabel("Arc length [m]")
        else:
            ax.plot(self.time, self.sample_minimum)
            ax.set_xlabel("Time [s]")
        ax.set_ylabel("Seabed clearance [m]")
        ax.grid(True)
        return ax


def seabed_clearance(
    source: PositionSource,
    seabed: float | Bathymetry,
    *,
    line_id: int | None = None,
    radius: float = 0.0,
    start: float | None = None,
    stop: float | None = None,
) -> SeabedClearance:
    """Return the vertical clearance of every node of one line above the seabed.

    Parameters
    ----------
    source : object
        Node positions: any source accepted by :func:`cabledyn.line_positions`.
    seabed : float | Bathymetry
        The seabed elevation ``z`` of a flat seabed (``-WtrDpth``), in metres,
        or a :class:`Bathymetry` surface.
    line_id : int | None
        Line to take from a main output or a multi-line static profile.
    radius : float
        Radius subtracted from the centreline clearance, for example the
        outer contact radius, in metres.
    start, stop : float | None
        Optional time window, in seconds.

    Returns
    -------
    SeabedClearance
        Clearance of every node at every sample.

    Raises
    ------
    KeyError
        If the source records no node positions for the line.
    ValueError
        If the seabed or radius is not finite, ``line_id`` is missing or not
        applicable, or the window is invalid.
    """
    positions = line_positions(source, line_id=line_id).period(start, stop)
    xyz = positions.positions
    if isinstance(seabed, Bathymetry):
        floor = seabed.floor(xyz[:, :, 0], xyz[:, :, 1])
    else:
        level = float(seabed)
        if not np.isfinite(level):
            raise ValueError("seabed elevation must be finite")
        floor = np.full(xyz.shape[:2], level)
    return SeabedClearance(
        time=positions.time,
        node_ids=positions.node_ids,
        arc_length=positions.arc_length,
        clearance=xyz[:, :, 2] - floor - _radius(radius, "radius"),
        radius=radius,
        source=positions.source,
        line_id=line_id if line_id is not None else _file_line_id(positions.source),
    )


@dataclass(frozen=True)
class LineClearance:
    """Minimum distance between two lines at every sample.

    Lines are the polylines through their nodes; the distance is the smallest
    segment-to-segment distance. ``a`` and ``b`` are the first and second
    line passed to :func:`line_clearance`.

    Attributes
    ----------
    time : numpy.ndarray | None
        ``(n_samples,)`` sample times in seconds, or ``None`` when both lines
        are static.
    distance : numpy.ndarray
        ``(n_samples,)`` minimum centreline distance, in metres.
    arc_length_a, arc_length_b : numpy.ndarray
        ``(n_samples,)`` deformed arc length from End A of the closest point on
        each line, in metres.
    segment_a, segment_b : numpy.ndarray
        ``(n_samples,)`` one-based index, from End A, of the segment holding
        the closest point on each line.
    point_a, point_b : numpy.ndarray
        ``(n_samples, 3)`` closest points, in metres.
    radius_a, radius_b : float
        Radii subtracted from the centreline distance, in metres.
    """

    time: npt.NDArray[Any] | None
    distance: npt.NDArray[Any]
    arc_length_a: npt.NDArray[Any]
    arc_length_b: npt.NDArray[Any]
    segment_a: npt.NDArray[Any]
    segment_b: npt.NDArray[Any]
    point_a: npt.NDArray[Any]
    point_b: npt.NDArray[Any]
    radius_a: float = 0.0
    radius_b: float = 0.0

    def __post_init__(self) -> None:
        distance = _readonly(self.distance)
        if distance.ndim != 1 or distance.size == 0 or not np.all(np.isfinite(distance)):
            raise ValueError("distance must be a finite, non-empty one-dimensional array")
        object.__setattr__(self, "distance", distance)
        shapes = {
            "arc_length_a": (distance.shape, np.float64),
            "arc_length_b": (distance.shape, np.float64),
            "segment_a": (distance.shape, np.int64),
            "segment_b": (distance.shape, np.int64),
            "point_a": ((distance.size, 3), np.float64),
            "point_b": ((distance.size, 3), np.float64),
        }
        for name, (shape, dtype) in shapes.items():
            array = _readonly(getattr(self, name), dtype)
            if array.shape != shape:
                raise ValueError(f"{name} must match distance")
            object.__setattr__(self, name, array)
        if self.time is not None:
            time = _readonly(self.time)
            if time.shape != distance.shape:
                raise ValueError("time must hold one entry per sample")
            object.__setattr__(self, "time", time)
        elif distance.size != 1:
            raise ValueError("a static clearance holds exactly one sample")
        object.__setattr__(self, "radius_a", _radius(self.radius_a, "radius_a"))
        object.__setattr__(self, "radius_b", _radius(self.radius_b, "radius_b"))

    @property
    def clearance(self) -> npt.NDArray[Any]:
        """``(n_samples,)`` surface clearance: distance minus both radii, in metres."""
        return _readonly(self.distance - self.radius_a - self.radius_b)

    @property
    def minimum(self) -> float:
        """Smallest :attr:`clearance` over all samples, in metres."""
        return float(np.min(self.clearance))

    @property
    def minimum_index(self) -> int:
        """Sample index of :attr:`minimum` (the first, if repeated)."""
        return int(np.argmin(self.distance))

    @property
    def minimum_time(self) -> float | None:
        """Time of :attr:`minimum` in seconds, or ``None`` when static."""
        return None if self.time is None else float(self.time[self.minimum_index])

    @property
    def minimum_arc_length_a(self) -> float:
        """Arc length on line ``a`` of the closest point at :attr:`minimum_time`."""
        return float(self.arc_length_a[self.minimum_index])

    @property
    def minimum_arc_length_b(self) -> float:
        """Arc length on line ``b`` of the closest point at :attr:`minimum_time`."""
        return float(self.arc_length_b[self.minimum_index])

    def plot(self, *, ax: Any = None, label: str | None = None) -> Any:
        """Plot the clearance against time.

        Parameters
        ----------
        ax : matplotlib.axes.Axes | None
            Axes to draw on; a new figure is created when omitted.
        label : str | None
            Legend label.

        Returns
        -------
        matplotlib.axes.Axes
            The axes drawn on.

        Raises
        ------
        ValueError
            If both lines are static.
        """
        if self.time is None:
            raise ValueError("a static clearance has no time history to plot")
        plt = pyplot()
        if ax is None:
            _, ax = plt.subplots()
        ax.plot(self.time, self.clearance, label=label)
        ax.set_xlabel("Time [s]")
        ax.set_ylabel("Line clearance [m]")
        ax.grid(True)
        if label is not None:
            ax.legend()
        return ax

    def export(self, path: str | os.PathLike[str], *, overwrite: bool = False) -> Path:
        """Atomically write one row per sample as a unit-labelled CSV.

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
        header = (
            "Time_[s]",
            "Distance_[m]",
            "Clearance_[m]",
            "ArcLengthA_[m]",
            "ArcLengthB_[m]",
            "SegmentA_[-]",
            "SegmentB_[-]",
        )
        clearance = self.clearance
        rows = (
            (
                "" if self.time is None else number(self.time[index]),
                number(self.distance[index]),
                number(clearance[index]),
                number(self.arc_length_a[index]),
                number(self.arc_length_b[index]),
                str(int(self.segment_a[index])),
                str(int(self.segment_b[index])),
            )
            for index in range(self.distance.size)
        )
        return write_csv(path, header, rows, overwrite=overwrite)


def _aligned(
    a: LinePositions, b: LinePositions
) -> tuple[npt.NDArray[Any] | None, npt.NDArray[Any], npt.NDArray[Any]]:
    """Common sample times and the two position arrays on them."""
    if a.time is None and b.time is None:
        return None, a.positions, b.positions
    if a.time is None:
        assert b.time is not None
        return (
            b.time,
            np.broadcast_to(a.positions, (b.sample_count, *a.positions.shape[1:])),
            b.positions,
        )
    if b.time is None:
        return (
            a.time,
            a.positions,
            np.broadcast_to(b.positions, (a.sample_count, *b.positions.shape[1:])),
        )
    scale = max(1.0, float(np.max(np.abs(a.time))))
    if a.time.shape != b.time.shape or not np.allclose(a.time, b.time, rtol=0.0, atol=1e-9 * scale):
        raise ValueError(
            "the two lines must share their sample times; resample one onto the other first"
        )
    return a.time, a.positions, b.positions


def _segments(positions: npt.NDArray[Any]) -> tuple[npt.NDArray[Any], npt.NDArray[Any]]:
    """Segment start and end points; a single node is one zero-length segment."""
    if positions.shape[1] == 1:
        return positions, positions
    return positions[:, :-1], positions[:, 1:]


def _chords(positions: npt.NDArray[Any]) -> tuple[npt.NDArray[Any], npt.NDArray[Any]]:
    """Segment lengths and the arc length at each segment start."""
    start, end = _segments(positions)
    chords = np.linalg.norm(end - start, axis=2)
    before = np.concatenate(
        (np.zeros((positions.shape[0], 1)), np.cumsum(chords, axis=1)[:, :-1]), axis=1
    )
    return chords, before


def line_clearance(
    a: PositionSource,
    b: PositionSource,
    *,
    line_id_a: int | None = None,
    line_id_b: int | None = None,
    radius_a: float = 0.0,
    radius_b: float = 0.0,
    start: float | None = None,
    stop: float | None = None,
) -> LineClearance:
    """Return the minimum distance between two lines at every sample.

    Parameters
    ----------
    a, b : object
        Node positions of each line: any source accepted by
        :func:`cabledyn.line_positions`. A static line is compared with every
        sample of the other; two histories must share their sample times.
    line_id_a, line_id_b : int | None
        Line to take from a main output or a multi-line static profile.
    radius_a, radius_b : float
        Radii subtracted from the centreline distance, in metres.
    start, stop : float | None
        Optional time window, in seconds.

    Returns
    -------
    LineClearance
        Distance, closest points, and their arc lengths at every sample.

    Raises
    ------
    KeyError
        If a source records no node positions.
    ValueError
        If the sample times differ, a radius is negative, ``line_id`` is
        missing or not applicable, or the window is invalid.
    """
    first = line_positions(a, line_id=line_id_a).period(start, stop)
    second = line_positions(b, line_id=line_id_b).period(start, stop)
    time, pa, pb = _aligned(first, second)
    start_a, end_a = _segments(pa)
    start_b, end_b = _segments(pb)
    chords_a, before_a = _chords(pa)
    chords_b, before_b = _chords(pb)
    samples, count_a, count_b = pa.shape[0], start_a.shape[1], start_b.shape[1]
    distance = np.empty(samples)
    seg_a = np.empty(samples, dtype=np.int64)
    seg_b = np.empty(samples, dtype=np.int64)
    frac_a = np.empty(samples)
    frac_b = np.empty(samples)
    chunk = max(1, _CHUNK // (count_a * count_b))
    for low in range(0, samples, chunk):
        high = min(samples, low + chunk)
        d, s, t = _segment_distance(
            start_a[low:high, :, None, :],
            end_a[low:high, :, None, :],
            start_b[low:high, None, :, :],
            end_b[low:high, None, :, :],
        )
        flat = np.argmin(d.reshape((high - low, -1)), axis=1)
        ia, ib = np.divmod(flat, count_b)
        rows = np.arange(high - low)
        distance[low:high] = d[rows, ia, ib]
        seg_a[low:high], seg_b[low:high] = ia, ib
        frac_a[low:high], frac_b[low:high] = s[rows, ia, ib], t[rows, ia, ib]
    rows = np.arange(samples)
    point_a = start_a[rows, seg_a] + frac_a[:, None] * (end_a[rows, seg_a] - start_a[rows, seg_a])
    point_b = start_b[rows, seg_b] + frac_b[:, None] * (end_b[rows, seg_b] - start_b[rows, seg_b])
    return LineClearance(
        time=time,
        distance=distance,
        arc_length_a=before_a[rows, seg_a] + frac_a * chords_a[rows, seg_a],
        arc_length_b=before_b[rows, seg_b] + frac_b * chords_b[rows, seg_b],
        segment_a=seg_a + 1,
        segment_b=seg_b + 1,
        point_a=point_a,
        point_b=point_b,
        radius_a=radius_a,
        radius_b=radius_b,
    )


@dataclass(frozen=True)
class ClearanceMatrix:
    """Minimum clearance between every pair of a set of lines.

    Attributes
    ----------
    names : tuple[str, ...]
        Line names, in input order.
    minimum : numpy.ndarray
        ``(n, n)`` symmetric matrix of the smallest clearance of each pair
        over all samples, in metres; ``nan`` on the diagonal.
    pairs : collections.abc.Mapping[tuple[str, str], LineClearance]
        Clearance history of each pair ``(names[i], names[j])`` with ``i < j``.
    """

    names: tuple[str, ...]
    minimum: npt.NDArray[Any]
    pairs: Mapping[tuple[str, str], LineClearance]

    def __post_init__(self) -> None:
        names = tuple(self.names)
        if len(names) < 2 or len(set(names)) != len(names):
            raise ValueError("a clearance matrix needs at least two distinct line names")
        minimum = _readonly(self.minimum)
        if minimum.shape != (len(names), len(names)):
            raise ValueError("minimum must be a square matrix matching names")
        object.__setattr__(self, "names", names)
        object.__setattr__(self, "minimum", minimum)
        object.__setattr__(self, "pairs", dict(self.pairs))

    def pair(self, first: str, second: str) -> LineClearance:
        """Return the clearance history of two named lines.

        The result's ``a`` is the line listed first in :attr:`names`.

        Raises
        ------
        KeyError
            If a name is unknown or the two names are equal.
        """
        if (first, second) in self.pairs:
            return self.pairs[(first, second)]
        if (second, first) in self.pairs:
            return self.pairs[(second, first)]
        raise KeyError(f"no line pair ({first!r}, {second!r}); lines: {', '.join(self.names)}")

    @property
    def governing(self) -> tuple[str, str, LineClearance]:
        """The pair with the smallest clearance, as ``(name_a, name_b, clearance)``."""
        (first, second), history = min(self.pairs.items(), key=lambda item: item[1].minimum)
        return first, second, history

    def export(self, path: str | os.PathLike[str], *, overwrite: bool = False) -> Path:
        """Atomically write the minimum-clearance matrix as CSV, in metres.

        The first column and the header hold the line names; the diagonal is
        blank.

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
        rows = (
            (
                name,
                *("" if i == j else number(self.minimum[i, j]) for j in range(len(self.names))),
            )
            for i, name in enumerate(self.names)
        )
        return write_csv(path, ("Line", *self.names), rows, overwrite=overwrite)


def clearance_matrix(
    lines: Mapping[str, PositionSource] | Sequence[PositionSource],
    *,
    radius: float | Mapping[str, float] = 0.0,
    start: float | None = None,
    stop: float | None = None,
) -> ClearanceMatrix:
    """Return the minimum clearance between every pair of lines.

    Parameters
    ----------
    lines : collections.abc.Mapping[str, object] | collections.abc.Sequence[object]
        Node positions of each line, keyed by name, or a sequence named
        ``"1"``, ``"2"``, ... in order. Each is a per-line source accepted by
        :func:`cabledyn.line_positions` without ``line_id`` (build a
        :class:`cabledyn.LinePositions` first for a main output).
    radius : float | collections.abc.Mapping[str, float]
        One radius for every line, or a radius per name (missing names use
        zero), in metres.
    start, stop : float | None
        Optional time window, in seconds.

    Returns
    -------
    ClearanceMatrix
        Pairwise minimum clearance and the history of every pair.

    Raises
    ------
    ValueError
        If fewer than two lines are given, or a pair cannot be compared (see
        :func:`line_clearance`).
    """
    named: dict[str, PositionSource]
    if isinstance(lines, Mapping):
        named = {str(name): value for name, value in lines.items()}
    else:
        named = {str(index): value for index, value in enumerate(lines, start=1)}
    names = tuple(named)
    if len(names) < 2:
        raise ValueError("a clearance matrix needs at least two lines")
    radii = {
        name: float(radius.get(name, 0.0)) if isinstance(radius, Mapping) else float(radius)
        for name in names
    }
    positions = {name: line_positions(value) for name, value in named.items()}
    minimum = np.full((len(names), len(names)), np.nan)
    pairs: dict[tuple[str, str], LineClearance] = {}
    for i, first in enumerate(names):
        for j in range(i + 1, len(names)):
            second = names[j]
            history = line_clearance(
                positions[first],
                positions[second],
                radius_a=radii[first],
                radius_b=radii[second],
                start=start,
                stop=stop,
            )
            pairs[(first, second)] = history
            minimum[i, j] = minimum[j, i] = history.minimum
    return ClearanceMatrix(names, minimum, pairs)
