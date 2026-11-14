# SPDX-License-Identifier: Apache-2.0
"""Per-object views of an in-process :class:`~cabledyn.CableDyn` model.

A :class:`Line`, :class:`Point`, :class:`Body` or :class:`Rod` is a light handle
on one object of the model's inventory. Its methods read the committed solver
state at the time of the call through the C ABI object queries, which use the
evaluator behind the deck OUTPUTS channels and the per-line ``.p``/``.t`` files:
a value equals what the matching output channel reports at the same step.

Views are cheap to hold and never cache state. A view becomes stale when the
model is re-initialized or closed; using it then raises
:class:`~cabledyn.CableDynError`.

These views describe a running model. The deck rows of the same names in
``cabledyn.builder`` (``Line``, ``Point``, ``Body``, ``Rod``) describe deck
input instead; import each family from its own module.

Every array getter accepts an optional ``out`` array, a writeable C-contiguous
``float64`` array of the documented shape: the library writes into it directly
and it is returned, so a caller polling every step allocates nothing. Without
``out`` a new array is returned; any other ``out`` raises :class:`ValueError`.
"""

from __future__ import annotations

import ctypes
from ctypes import POINTER, byref, c_double, c_int
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any, Literal

import numpy as np
import numpy.typing as npt

from cabledyn.errors import CableDynError

if TYPE_CHECKING:
    from cabledyn.model import CableDyn

__all__ = ["Body", "Line", "LineQuantity", "Point", "PointKind", "Rod"]

FloatArray = npt.NDArray[np.float64]

#: Object kinds of the C ABI (``CD_C_OBJ_*``).
OBJ_LINE, OBJ_POINT, OBJ_BODY, OBJ_ROD = 1, 2, 3, 4

#: Line quantity names and their C ABI codes (``CD_C_LINE_*``) and values per node.
LineQuantity = Literal[
    "position",
    "velocity",
    "acceleration",
    "tension",
    "curvature",
    "bend_moment",
    "declination",
    "azimuth",
    "segment_tension",
    "section_curvature",
]
_LINE_QUANTITIES: dict[str, tuple[int, int]] = {
    "position": (1, 3),
    "velocity": (2, 3),
    "tension": (3, 1),
    "acceleration": (4, 3),
    "curvature": (5, 1),
    "bend_moment": (6, 1),
    "declination": (7, 1),
    "azimuth": (8, 1),
    "segment_tension": (9, 1),
    "section_curvature": (11, 2),
}

#: C ABI code of the deck node of each mesh node (``CD_C_LINE_DECK_NODE``).
_LINE_DECK_NODE = 10

PointKind = Literal["fixed", "coupled", "free", "connect"]
_POINT_KINDS: dict[int, PointKind] = {1: "fixed", 2: "coupled", 3: "free", 4: "connect"}


def _dbl(arr: FloatArray | None) -> Any:
    if arr is None:
        return None
    return arr.ctypes.data_as(POINTER(c_double))


def _buffer(out: FloatArray | None, shape: tuple[int, ...]) -> FloatArray:
    """Return ``out`` when it can be written in place, else a new zero array."""
    if (
        out is not None
        and isinstance(out, np.ndarray)
        and out.dtype == np.float64
        and out.shape == shape
        and out.flags.c_contiguous
        and out.flags.writeable
    ):
        return out
    if out is not None:
        raise ValueError(f"out must be a writeable C-contiguous float64 array of shape {shape}")
    return np.zeros(shape)


@dataclass(frozen=True)
class _ObjectInfo:
    index: int
    id: int
    n_nodes: int
    subtype: int


class _View:
    """Common base: the owning model, its generation, and the object's inventory entry."""

    _kind = 0
    _prefix = ""

    def __init__(self, model: CableDyn, info: _ObjectInfo, generation: int) -> None:
        self._model = model
        self._info = info
        self._generation = generation

    @property
    def index(self) -> int:
        """0-based position in the model's inventory of this kind."""
        return self._info.index

    @property
    def id(self) -> int:
        """Deck id of the object."""
        return self._info.id

    @property
    def name(self) -> str:
        """Channel-vocabulary name, e.g. ``"Line3"`` or ``"Body1"``."""
        return f"{self._prefix}{self._info.id}"

    def __repr__(self) -> str:
        return f"<{type(self).__name__} {self.name} (index {self.index})>"

    def _handle(self) -> Any:
        model = self._model
        if model._generation != self._generation or not model._handle:
            raise CableDynError(
                f"{type(self).__name__}.{self.name}",
                5,
                "stale object view: the model was re-initialized or closed",
            )
        return model._handle

    def _check(self, call: str, status: int) -> None:
        self._model._check(call, status)


class Line(_View):
    """One line (mooring line or cable) of an in-process model.

    Nodes run from End A (index 0) to End B, the order of the ``.Line<L>.p.out``
    files; segments run in the same order. The arrays hold every node of the
    line's final mesh. The output channels (:meth:`~cabledyn.CableDyn.channel`,
    ``Ten<L>N<J>``, ``L<L>N<J>px``, ...) name deck nodes: on the deck mesh deck
    node ``J`` is array row ``J - 1``; on a finite-EI line whose mesh the static
    solve refined, :attr:`deck_nodes` locates them among the mesh nodes.
    """

    _kind = OBJ_LINE
    _prefix = "Line"

    @property
    def n_nodes(self) -> int:
        """Node count."""
        return self._info.n_nodes

    @property
    def n_segments(self) -> int:
        """Segment (element) count, ``n_nodes - 1``."""
        return self._info.n_nodes - 1

    @property
    def deck_nodes(self) -> npt.NDArray[np.int64]:
        """Deck node of each node of the final mesh ``(n_nodes,)``.

        Entry ``k`` is the deck node ``J`` (the ``<J>`` of the node output
        channels) at array row ``k``, or 0 for a node a mesh refinement added.
        On the deck mesh it is ``1 .. n_nodes``. Rows of the line arrays at deck
        node ``J`` are ``numpy.flatnonzero(line.deck_nodes == J)``.

        Raises
        ------
        CableDynError
            If the library predates this query (``CD_C_LINE_DECK_NODE``).
        """
        buf = _buffer(None, (self.n_nodes,))
        with self._model._lock:
            handle = self._handle()
            status = c_int()
            self._model._lib.CableDyn_GetLineValues(
                handle, self.index, _LINE_DECK_NODE, _dbl(buf), buf.size, byref(status)
            )
            self._check("CableDyn_GetLineValues", status.value)
        return np.rint(buf).astype(np.int64)

    @property
    def finite_ei(self) -> bool:
        """Whether the line carries bending stiffness (the cubic-Hermite element)."""
        return self._info.subtype == 1

    def values(self, quantity: LineQuantity, out: FloatArray | None = None) -> FloatArray:
        """Any line quantity by name.

        Parameters
        ----------
        quantity : str
            One of ``position``, ``velocity``, ``acceleration`` (shape
            ``(n_nodes, 3)``), ``tension``, ``curvature``, ``bend_moment``,
            ``declination``, ``azimuth`` (shape ``(n_nodes,)``) or
            ``segment_tension`` (shape ``(n_segments,)``).
        out : numpy.ndarray, optional
            Destination array of that shape.
        """
        if quantity not in _LINE_QUANTITIES:
            raise ValueError(
                f"unknown line quantity {quantity!r}; expected one of {sorted(_LINE_QUANTITIES)}"
            )
        code, width = _LINE_QUANTITIES[quantity]
        count = self.n_segments if quantity == "segment_tension" else self.n_nodes
        shape = (count, width) if width > 1 else (count,)
        buf = _buffer(out, shape)
        with self._model._lock:
            handle = self._handle()
            status = c_int()
            self._model._lib.CableDyn_GetLineValues(
                handle, self.index, code, _dbl(buf), buf.size, byref(status)
            )
            self._check("CableDyn_GetLineValues", status.value)
        return buf

    def node_positions(self, out: FloatArray | None = None) -> FloatArray:
        """Node positions ``(n_nodes, 3)`` [m] (the ``L<L>N<k>p{x,y,z}`` channels)."""
        return self.values("position", out)

    def node_velocities(self, out: FloatArray | None = None) -> FloatArray:
        """Node velocities ``(n_nodes, 3)`` [m/s]."""
        return self.values("velocity", out)

    def node_accelerations(self, out: FloatArray | None = None) -> FloatArray:
        """Node accelerations ``(n_nodes, 3)`` [m/s^2]."""
        return self.values("acceleration", out)

    def node_tensions(self, out: FloatArray | None = None) -> FloatArray:
        """Effective tension at each node ``(n_nodes,)`` [N] (``Ten<L>N<k>``).

        The end nodes carry the line-end force magnitude (``FairTen``/``AnchTen``),
        interior nodes the length-weighted mean of the two adjacent segments.
        """
        return self.values("tension", out)

    def segment_tensions(self, out: FloatArray | None = None) -> FloatArray:
        """Segment tensions ``(n_segments,)`` [N], as in ``.Line<L>.t.out``."""
        return self.values("segment_tension", out)

    def curvature(self, out: FloatArray | None = None) -> FloatArray:
        """Curvature at each node ``(n_nodes,)`` [1/m] (``Curv<L>N<k>``)."""
        return self.values("curvature", out)

    def section_curvature(self, out: FloatArray | None = None) -> FloatArray:
        """Curvature on the section axes at each node ``(n_nodes, 2)`` [1/m].

        Columns ``CurvX<L>N<k>`` and ``CurvY<L>N<k>``, on a finite-EI line; one evaluation
        for the whole line, so it is much cheaper than a channel per node.
        """
        return self.values("section_curvature", out)

    def bend_moment(self, out: FloatArray | None = None) -> FloatArray:
        """Bend moment magnitude at each node ``(n_nodes,)`` [N-m]; zero when EI = 0."""
        return self.values("bend_moment", out)

    def declination(self, out: FloatArray | None = None) -> FloatArray:
        """Declination at each node ``(n_nodes,)`` [deg] (``L<L>N<k>Dec``)."""
        return self.values("declination", out)

    def azimuth(self, out: FloatArray | None = None) -> FloatArray:
        """Azimuth at each node ``(n_nodes,)`` [deg] (``L<L>N<k>Azi``), in the line's range.

        (-180, 180] on a line whose deck chord heads within 45 deg of +X, otherwise [0, 360).
        """
        return self.values("azimuth", out)

    def arc_length(self) -> FloatArray:
        """Deformed arc length of each node from End A ``(n_nodes,)`` [m]."""
        xyz = self.node_positions()
        seg = np.linalg.norm(np.diff(xyz, axis=0), axis=1)
        return np.concatenate(([0.0], np.cumsum(seg)))

    def fairlead_tension(self) -> float:
        """End A tension [N] (``FairTen<L>``)."""
        return self._model.channel(f"FairTen{self.id}")

    def anchor_tension(self) -> float:
        """End B tension [N] (``AnchTen<L>``)."""
        return self._model.channel(f"AnchTen{self.id}")


class Point(_View):
    """One point (fixed, coupled, free or connect) of an in-process model."""

    _kind = OBJ_POINT
    _prefix = "Point"

    @property
    def kind(self) -> PointKind:
        """``"fixed"``, ``"coupled"``, ``"free"`` or ``"connect"``."""
        return _POINT_KINDS.get(self._info.subtype, "fixed")

    def _state(self, which: int, out: FloatArray | None) -> FloatArray:
        buf = _buffer(out, (3,))
        ptrs: list[Any] = [None, None, None]
        ptrs[which] = _dbl(buf)
        with self._model._lock:
            handle = self._handle()
            status = c_int()
            self._model._lib.CableDyn_GetPointState(
                handle, self.index, ptrs[0], ptrs[1], ptrs[2], byref(status)
            )
            self._check("CableDyn_GetPointState", status.value)
        return buf

    def position(self, out: FloatArray | None = None) -> FloatArray:
        """Position ``(3,)`` [m] (``Point<P>p{x,y,z}``)."""
        return self._state(0, out)

    def velocity(self, out: FloatArray | None = None) -> FloatArray:
        """Velocity ``(3,)`` [m/s]."""
        return self._state(1, out)

    def force(self, out: FloatArray | None = None) -> FloatArray:
        """Resultant force of the attached lines on the point ``(3,)`` [N] (``Point<P>F``)."""
        return self._state(2, out)


class Body(_View):
    """One Rigid6 body of an in-process model.

    Angles are the x-y'-z'' Euler angles of the deck convention in degrees, and
    angular rates are in deg/s (deg/s^2), as in the ``Body<N>`` output channels.
    """

    _kind = OBJ_BODY
    _prefix = "Body"

    def _state(self, which: int, out: FloatArray | None) -> FloatArray:
        buf = _buffer(out, (6,))
        ptrs: list[Any] = [None, None, None, None]
        ptrs[which] = _dbl(buf)
        with self._model._lock:
            handle = self._handle()
            status = c_int()
            self._model._lib.CableDyn_GetBodyState(
                handle, self.index, ptrs[0], ptrs[1], ptrs[2], ptrs[3], byref(status)
            )
            self._check("CableDyn_GetBodyState", status.value)
        return buf

    def pose(self, out: FloatArray | None = None) -> FloatArray:
        """``[x, y, z, rx, ry, rz]`` of the reference point [m, deg]."""
        return self._state(0, out)

    def velocity(self, out: FloatArray | None = None) -> FloatArray:
        """``[vx, vy, vz, wx, wy, wz]`` [m/s, deg/s]."""
        return self._state(1, out)

    def acceleration(self, out: FloatArray | None = None) -> FloatArray:
        """``[ax, ay, az, alpha_x, alpha_y, alpha_z]`` [m/s^2, deg/s^2]."""
        return self._state(2, out)

    def wrench(self, out: FloatArray | None = None) -> FloatArray:
        """Net external load ``[Fx, Fy, Fz, Mx, My, Mz]`` about the reference point [N, N-m]."""
        return self._state(3, out)

    def rotation_matrix(self) -> FloatArray:
        """Body-to-global rotation matrix ``(3, 3)`` from the x-y'-z'' pose angles."""
        rx, ry, rz = np.radians(self.pose()[3:])
        cx, sx, cy, sy, cz, sz = (
            np.cos(rx),
            np.sin(rx),
            np.cos(ry),
            np.sin(ry),
            np.cos(rz),
            np.sin(rz),
        )
        r_x = np.array([[1.0, 0.0, 0.0], [0.0, cx, -sx], [0.0, sx, cx]])
        r_y = np.array([[cy, 0.0, sy], [0.0, 1.0, 0.0], [-sy, 0.0, cy]])
        r_z = np.array([[cz, -sz, 0.0], [sz, cz, 0.0], [0.0, 0.0, 1.0]])
        result: FloatArray = r_x @ r_y @ r_z
        return result


class Rod(_View):
    """One rigid rod of an in-process model. Node 0 is End A, the last node End B."""

    _kind = OBJ_ROD
    _prefix = "Rod"

    @property
    def n_nodes(self) -> int:
        """Node count, ``NumSegs + 1``."""
        return self._info.n_nodes

    @property
    def n_segments(self) -> int:
        """Segment count (the deck NumSegs)."""
        return self._info.n_nodes - 1

    def _state(self, which: int, out: FloatArray | None) -> FloatArray:
        shape = (self.n_nodes, 3) if which == 0 else (6,)
        buf = _buffer(out, shape)
        ptrs: list[Any] = [None, None, None, None]
        ptrs[which] = _dbl(buf)
        with self._model._lock:
            handle = self._handle()
            status = c_int()
            self._model._lib.CableDyn_GetRodState(
                handle,
                self.index,
                ptrs[0],
                self.n_nodes,
                ptrs[1],
                ptrs[2],
                ptrs[3],
                byref(status),
            )
            self._check("CableDyn_GetRodState", status.value)
        return buf

    def node_positions(self, out: FloatArray | None = None) -> FloatArray:
        """Node positions ``(n_nodes, 3)`` [m] (``Rod<N>N<k>P{x,y,z}``)."""
        return self._state(0, out)

    def end_a(self) -> FloatArray:
        """End A position ``(3,)`` [m]."""
        result: FloatArray = self.node_positions()[0].copy()
        return result

    def end_b(self) -> FloatArray:
        """End B position ``(3,)`` [m]."""
        result: FloatArray = self.node_positions()[-1].copy()
        return result

    def axis(self) -> FloatArray:
        """Unit vector from End A to End B ``(3,)``."""
        nodes = self.node_positions()
        vec = nodes[-1] - nodes[0]
        norm = float(np.linalg.norm(vec))
        if norm == 0.0:
            raise ValueError(f"Rod {self.name} has zero length and so no axis")
        result: FloatArray = vec / norm
        return result

    def pose(self, out: FloatArray | None = None) -> FloatArray:
        """``[x, y, z, rx, ry, 0]``: End A [m] and the axis roll and pitch from vertical [deg]."""
        return self._state(1, out)

    def velocity(self, out: FloatArray | None = None) -> FloatArray:
        """End A ``[vx, vy, vz, wx, wy, wz]`` [m/s, deg/s]."""
        return self._state(2, out)

    def wrench(self, out: FloatArray | None = None) -> FloatArray:
        """Net load ``[Fx, Fy, Fz, Mx, My, Mz]`` about End A [N, N-m]."""
        return self._state(3, out)


def _object_info(model: CableDyn, kind: int, index: int) -> _ObjectInfo:
    oid, nn, sub, status = c_int(), c_int(), c_int(), c_int()
    model._lib.CableDyn_GetObjectInfo(
        model._handle, kind, index, byref(oid), byref(nn), byref(sub), byref(status)
    )
    model._check("CableDyn_GetObjectInfo", status.value)
    return _ObjectInfo(index=index, id=oid.value, n_nodes=nn.value, subtype=sub.value)


def build_views(
    model: CableDyn,
) -> tuple[tuple[Line, ...], tuple[Point, ...], tuple[Body, ...], tuple[Rod, ...]]:
    """Enumerate the model's objects (the caller holds the model lock)."""
    lib = model._lib
    generation = model._generation
    result: list[list[Any]] = []
    for kind, cls in ((OBJ_LINE, Line), (OBJ_POINT, Point), (OBJ_BODY, Body), (OBJ_ROD, Rod)):
        status = c_int()
        count = int(lib.CableDyn_NObjects(model._handle, kind, byref(status)))
        model._check("CableDyn_NObjects", status.value)
        result.append([cls(model, _object_info(model, kind, i), generation) for i in range(count)])
    return tuple(result[0]), tuple(result[1]), tuple(result[2]), tuple(result[3])


def eval_channel(model: CableDyn, token: str) -> float:
    """Evaluate one OUTPUTS token (the caller holds the model lock)."""
    if not isinstance(token, str):
        raise TypeError(f"channel token must be a string; got {type(token).__name__}")
    if "\0" in token:
        # the library ends a token at its first NUL, so "FairTen1\0x" would read as FairTen1
        raise ValueError(f"channel token must not contain a NUL character; got {token!r}")
    try:
        raw = token.strip().encode("ascii")
    except UnicodeEncodeError:
        raw = b""
    if not raw or len(raw) > 64:
        raise ValueError(f"channel token must be 1..64 ASCII characters; got {token!r}")
    value = c_double()
    status = c_int()
    model._lib.CableDyn_EvalChannel(
        model._handle, ctypes.c_char_p(raw), len(raw), byref(value), byref(status)
    )
    model._check("CableDyn_EvalChannel", status.value)
    return float(value.value)
