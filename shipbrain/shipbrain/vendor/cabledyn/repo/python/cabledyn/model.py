# SPDX-License-Identifier: Apache-2.0
"""The CableDyn model class: handle lifecycle + NumPy coupling boundary."""

from __future__ import annotations

import contextlib
import ctypes
import math
import numbers
import os
import threading
from collections.abc import Callable
from ctypes import POINTER, byref, c_bool, c_double, c_int, c_void_p
from pathlib import Path
from types import TracebackType
from typing import Any

import numpy as np
import numpy.typing as npt

from cabledyn import _lib as _lib_module
from cabledyn._lib import _lib
from cabledyn.errors import CableDynError, ConvergenceError
from cabledyn.objects import (
    _POINT_KINDS,
    Body,
    Line,
    Point,
    PointKind,
    Rod,
    build_views,
    eval_channel,
)

__all__ = ["Body", "CableDyn", "CableDynError", "ConvergenceError", "Line", "Point", "Rod"]

FloatArray = npt.NDArray[np.float64]
IntArray = npt.NDArray[np.intc]
ArrayInput = npt.ArrayLike

# The C library retains up to 4096 characters per handle; +1 for the NUL.
_MESSAGE_BUFFER = 4097


def _as_real_array(x: ArrayInput, name: str) -> FloatArray:
    """Return ``x`` as a contiguous ``float64`` array, rejecting non-real input.

    Complex values would otherwise lose their imaginary part silently, and strings
    or objects would be parsed or fail deep inside NumPy.
    """
    src = np.asarray(x)
    if src.dtype.kind == "c":
        raise TypeError(f"{name} must be real-valued; got a complex array")
    if src.dtype.kind not in "biuf":
        raise TypeError(f"{name} must be a real numeric array; got dtype {src.dtype}")
    return np.ascontiguousarray(src, dtype=np.float64)


def _as_real_scalar(value: object, name: str, *, positive: bool) -> float:
    """Return ``value`` as a finite ``float``; ``positive`` also requires ``> 0``."""
    if isinstance(value, (bool, np.bool_)) or not isinstance(value, numbers.Real):
        raise TypeError(f"{name} must be a real number; got {type(value).__name__}")
    result = float(value)
    if not math.isfinite(result):
        raise ValueError(f"{name} must be finite; got {result}")
    if positive and result <= 0.0:
        raise ValueError(f"{name} must be positive; got {result}")
    if not positive and result < 0.0:
        raise ValueError(f"{name} must be non-negative; got {result}")
    return result


def _as_dof_array(x: ArrayInput, n: int, name: str) -> FloatArray:
    """Return ``x`` as a contiguous flat ``float64`` array of ``n`` values.

    Accepts a flat ``(n,)`` array or a column-per-point ``(3, n // 3)`` array.
    """
    arr = _as_real_array(x, name)
    if arr.ndim == 2 and arr.shape[0] == 3:
        arr = np.ascontiguousarray(arr.reshape(-1, order="F"))
    if arr.ndim != 1 or arr.size != n:
        raise ValueError(
            f"{name} must be flat ({n},) or column-per-point (3, {n // 3}); got shape {np.shape(x)}"
        )
    if not np.all(np.isfinite(arr)):
        raise ValueError(f"{name} must be finite (no NaN or Inf)")
    return arr


def _as_field(x: ArrayInput, n: int, name: str) -> FloatArray:
    """Return a per-node vector field as flat ``(3 n,)``; accepts ``(3, n)`` or flat."""
    return _as_dof_array(x, 3 * n, name)


def _as_node_values(x: ArrayInput, n: int, name: str) -> FloatArray:
    """Return one finite value per node as a contiguous ``(n,)`` array."""
    arr = _as_real_array(x, name)
    if arr.ndim != 1 or arr.size != n:
        raise ValueError(f"{name} must have {n} entries")
    if not np.all(np.isfinite(arr)):
        raise ValueError(f"{name} must be finite (no NaN or Inf)")
    return np.ascontiguousarray(arr)


def _dbl_ptr(arr: FloatArray) -> Any:
    return arr.ctypes.data_as(POINTER(c_double))


def _int_ptr(arr: IntArray) -> Any:
    return arr.ctypes.data_as(POINTER(c_int))


def _as_index_array(x: ArrayInput, name: str) -> IntArray:
    """Return ``x`` as a contiguous C ``int`` array, rejecting non-integer input.

    Connectivity, DOF and count arrays stay exact: a float array is not rounded to one.
    """
    src = np.asarray(x)
    if src.size == 0:
        return np.zeros(src.shape, dtype=np.intc)
    if src.dtype.kind not in "iu":
        raise TypeError(f"{name} must be an integer array; got dtype {src.dtype}")
    limits = np.iinfo(np.intc)
    if int(src.min()) < limits.min or int(src.max()) > limits.max:
        raise ValueError(f"{name} holds a value outside the range of a C int")
    return np.ascontiguousarray(src, dtype=np.intc)


def _as_flag(value: object, name: str) -> int:
    """Return a true-or-false argument as the C ``int`` 1 or 0."""
    if not isinstance(value, (bool, np.bool_, numbers.Integral)):
        raise TypeError(f"{name} must be a boolean; got {type(value).__name__}")
    return 1 if value else 0


def _as_spectral_radius(value: object) -> float:
    """Return ``rho_inf``, a finite real number in ``[0, 1]``."""
    result = _as_real_scalar(value, "rho_inf", positive=False)
    if result > 1.0:
        raise ValueError(f"rho_inf must lie in [0, 1]; got {result}")
    return result


def _as_element_array(x: ArrayInput, n_elem: int, name: str) -> FloatArray:
    """Return a per-element array: flat, ``n_elem`` finite values."""
    arr = _as_real_array(x, name)
    if arr.ndim != 1 or arr.size != n_elem:
        raise ValueError(f"{name} must be flat ({n_elem},); got shape {np.shape(x)}")
    if not np.all(np.isfinite(arr)):
        raise ValueError(f"{name} must be finite (no NaN or Inf)")
    return arr


def _raw_line_arrays(
    q0: ArrayInput,
    v0: ArrayInput,
    elem_conn: ArrayInput,
    l0: ArrayInput,
    ea: ArrayInput,
    rho_a: ArrayInput,
    fixed_dofs: ArrayInput,
) -> tuple[FloatArray, FloatArray, IntArray, FloatArray, FloatArray, FloatArray, IntArray]:
    """The arrays of :meth:`CableDyn.init_line` and :meth:`CableDyn.init_lines`, checked for shape.

    Returns them in that order, each flat. The values are the library's to judge.
    """
    q = _host_positions(q0)
    v = _host_positions(v0, "v0")
    if v.size != q.size:
        raise ValueError(f"v0 must hold as many values as q0 ({q.size}); got {v.size}")
    length = _as_real_array(l0, "l0")
    if length.ndim != 1:
        raise ValueError(f"l0 must be flat (n_elem,); got shape {np.shape(l0)}")
    n_elem = int(length.size)
    length = _as_element_array(length, n_elem, "l0")
    stiffness = _as_element_array(ea, n_elem, "ea")
    mass = _as_element_array(rho_a, n_elem, "rho_a")
    conn = _as_index_array(elem_conn, "elem_conn")
    if conn.shape not in {(2 * n_elem,), (n_elem, 2)}:
        raise ValueError(
            f"elem_conn must be flat ({2 * n_elem},) or one row per element ({n_elem}, 2); "
            f"got shape {conn.shape}"
        )
    fixed = _as_index_array(fixed_dofs, "fixed_dofs")
    if fixed.ndim != 1:
        raise ValueError(f"fixed_dofs must be flat; got shape {fixed.shape}")
    return q, v, conn.reshape(-1), length, stiffness, mass, fixed


def _host_positions(q0: ArrayInput, name: str = "q0") -> FloatArray:
    """``q0`` of :meth:`CableDyn.init_deck_at`: flat ``(3 n,)`` or column-per-point ``(3, n)``."""
    q = _as_real_array(q0, name)
    if q.ndim == 2 and q.shape == (3, 3):
        # three points: column-per-point and row-per-point look alike
        raise ValueError(
            f"{name} of shape (3, 3) is ambiguous (column-per-point or row-per-point); "
            "pass it flat, x1 y1 z1 x2 y2 z2 ..."
        )
    if q.ndim == 2 and q.shape[0] == 3:
        q = np.ascontiguousarray(q.reshape(-1, order="F"))
    if q.ndim != 1 or q.size % 3 != 0:
        raise ValueError(
            f"{name} must be flat (3 * n,) or column-per-point (3, n); got shape {np.shape(q0)}"
        )
    if not np.all(np.isfinite(q)):
        raise ValueError(f"{name} must be finite (no NaN or Inf)")
    return q


def _encode_path(deck: str | os.PathLike[str]) -> bytes:
    """Encode a deck path for the Fortran runtime's narrow-character ``OPEN``."""
    text = os.fspath(deck)
    if "\0" in text:
        raise ValueError("deck path must not contain a NUL character")
    if os.name == "nt":
        # gfortran and ifx open files through the active ANSI code page.
        try:
            return text.encode("mbcs", errors="strict")
        except UnicodeEncodeError as exc:
            raise ValueError(
                f"deck path cannot be represented in the active Windows code page: {text!r}; "
                "move the deck to a path using representable characters"
            ) from exc
    return os.fsencode(text)


class CableDyn:
    """One CableDyn solver instance behind the C ABI (context-manager friendly).

    Parameters
    ----------
    deck : str | os.PathLike | None
        A MoorDyn-style sectioned ``.dat`` deck (the deck format in the
        documentation, https://cabledyn.readthedocs.io).
        When given, the static initial condition is solved immediately.
        ``None`` creates an unbound handle for a later :meth:`init_deck`, or for
        :meth:`init_line` or :meth:`init_lines` with lines meshed by the caller.

    The coupled exchange follows the coupling boundary described in the
    documentation (https://cabledyn.readthedocs.io): kinematics in
    (position, velocity, and acceleration at the coupled points, 3 DOFs per
    point, metres and seconds), loads out (the force the lines exert at those
    DOFs, newtons). Arrays may be flat ``(n_dof,)`` with interleaved ``x, y, z``
    values, or column-per-point ``(3, n_points)``; results are always flat.
    A ``(3, 3)`` array is read column-per-point, so pass three points flat when
    in doubt.

    Calls on one instance are serialized by an internal lock. Independent
    instances may be used from different threads.

    The objects of an initialized model are available as :attr:`lines`,
    :attr:`points`, :attr:`bodies` and :attr:`rods` (see
    :mod:`cabledyn.objects`); any output channel can be evaluated with
    :meth:`channel`. Both read the committed state at the time of the call.
    """

    def __init__(self, deck: str | os.PathLike[str] | None = None) -> None:
        self._lock = threading.RLock()
        self._handle = c_void_p()
        self._lib = _lib
        # Bumped by every (re)initialization and by close(): object views compare it
        # to detect a stale handle.
        self._generation = 0
        self._views: tuple[tuple[Line, ...], tuple[Point, ...], tuple[Body, ...], tuple[Rod, ...]]
        self._views = ((), (), (), ())
        self._views_valid = False
        self._time = 0.0
        # the time of the state in the save slot (None: nothing saved since the initialization)
        self._saved_time: float | None = None
        self._deck: Path | None = None
        status = c_int()
        _lib.CableDyn_Create(byref(self._handle), byref(status))
        if status.value != 0:
            raise CableDynError("CableDyn_Create", status.value, "")
        if deck is not None:
            try:
                self.init_deck(deck)
            except BaseException:
                self.close()
                raise

    # -- lifecycle ------------------------------------------------------------

    def close(self) -> None:
        """Release the handle (idempotent)."""
        with self._lock:
            if self._handle:
                status = c_int()
                _lib.CableDyn_Close(byref(self._handle), byref(status))
                self._handle = c_void_p()
            self._generation += 1
            self._views_valid = False

    def __enter__(self) -> CableDyn:
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        self.close()

    def __del__(self) -> None:  # best-effort; close() is the contract
        with contextlib.suppress(Exception):
            self.close()

    def _check(self, call: str, status: int) -> None:
        if status != 0:
            raise CableDynError(call, status, self._last_error())

    def _last_error(self) -> str:
        buf = ctypes.create_string_buffer(_MESSAGE_BUFFER)
        _lib.CableDyn_GetLastError(self._handle, buf, len(buf))
        return buf.value.decode("utf-8", errors="replace").strip()

    def last_error(self) -> str:
        """The library's last diagnostic message for this handle."""
        with self._lock:
            return self._last_error()

    @property
    def init_notes(self) -> list[str]:
        """The notes of the last deck initialisation, successful or not.

        These are the ``Note:`` lines a driver run of the deck prints at its start, without the
        prefix, on the point and aggregate routes alike. They take what is known at
        initialisation: the deck's current, not a field a host applies later. A raw-line
        initialisation has none.
        """
        with self._lock:
            if not _lib_module._has_init_notes:
                # not a C status: the loaded library lacks the entry point
                raise RuntimeError(
                    "the loaded CableDyn library predates CableDyn_GetInitNotes; "
                    "rebuild it from this checkout"
                )
            size = _lib.CableDyn_GetInitNotes(self._handle, None, 0)
            if size <= 0:
                return []
            buf = ctypes.create_string_buffer(size + 1)
            _lib.CableDyn_GetInitNotes(self._handle, buf, len(buf))
            return buf.value.decode("utf-8", errors="replace").splitlines()

    # -- initialization -------------------------------------------------------

    def init_deck(self, deck: str | os.PathLike[str]) -> None:
        """Initialize from a deck file: parse, build, and solve the static IC.

        A failed initialization keeps any previously initialized model.
        """
        _encode_path(deck)  # rejects a NUL before any file-system call
        # the deck path as the rest of the package reads it ('~' expanded)
        resolved = Path(deck).expanduser().resolve()
        path = _encode_path(resolved)
        with self._lock:
            status = c_int()
            _lib.CableDyn_InitDeck(self._handle, path, len(path), byref(status))
            self._check("CableDyn_InitDeck", status.value)
            self._initialized_from(resolved)

    def init_deck_at(self, deck: str | os.PathLike[str], q0: ArrayInput) -> None:
        """Initialize from a deck with the statics solved at the host's coupled positions.

        Every line-bound Coupled/Vessel point starts at its entry of ``q0`` instead
        of its deck coordinates, and the static equilibrium (lines, Free/Connect
        points, bodies, rods) is solved with those points held there, at rest; a
        host whose body starts away from the deck coordinates then starts without
        a transient. ``q0`` is either the full coupled vector of the deck
        (``n_coupled_dof`` values, the layout of :meth:`step`; the Fixed, Free and
        Connect blocks are not read) or the Coupled/Vessel blocks alone, in
        coupled-vector order (the ``MoorDyn_Init`` layout of a deck whose coupled
        objects are points that are all attached to lines: a Coupled point attached
        to no line has no block here), flat or column-per-point ``(3, n)`` with
        ``n != 3`` (a ``(3, 3)`` array is rejected as ambiguous: pass three points
        flat). See :meth:`coupled_layout`. A failed initialization keeps any
        previously initialized model and its saved state.
        """
        _encode_path(deck)  # rejects a NUL before any file-system call
        resolved = Path(deck).expanduser().resolve()
        path = _encode_path(resolved)
        q = _host_positions(q0)
        with self._lock:
            self._require_host_coupling()
            status = c_int()
            _lib.CableDyn_InitDeckAt(
                self._handle, path, len(path), _dbl_ptr(q), int(q.size), byref(status)
            )
            self._check("CableDyn_InitDeckAt", status.value)
            self._initialized_from(resolved)

    def init_deck_rotating(
        self, deck: str | os.PathLike[str], q0: ArrayInput | None = None
    ) -> None:
        """Initialize from a deck for a host that turns the bodies its coupled points are on.

        :meth:`init_deck_at` (or :meth:`init_deck` with ``q0=None``) whose model
        takes each coupled block's rotation from :meth:`update_rotations` and
        passes it with every :meth:`update_states` and :meth:`step`, so a line
        restrained in torsion (``END CONNECTIONS`` ``TorsStiffness``) and a
        ``Rigid`` bending end connection turn with the host at their host-driven
        end; the other initializations refuse a deck with a line restrained in
        torsion. The rotations start at identity (the deck's axes at the static
        start) and rest. :meth:`coupled_moments` returns the moments the lines
        apply to the host.
        """
        _encode_path(deck)  # rejects a NUL before any file-system call
        resolved = Path(deck).expanduser().resolve()
        path = _encode_path(resolved)
        q = np.zeros(0) if q0 is None else _host_positions(q0)
        with self._lock:
            self._require_host_rotation()
            status = c_int()
            _lib.CableDyn_InitDeckRotating(
                self._handle,
                path,
                len(path),
                _dbl_ptr(q) if q.size else None,
                int(q.size),
                byref(status),
            )
            self._check("CableDyn_InitDeckRotating", status.value)
            self._initialized_from(resolved)

    def init_line(
        self,
        q0: ArrayInput,
        v0: ArrayInput,
        elem_conn: ArrayInput,
        l0: ArrayInput,
        ea: ArrayInput,
        rho_a: ArrayInput,
        fixed_dofs: ArrayInput,
        tension_only: bool,
        rho_inf: float,
    ) -> None:
        """Initialize from one line meshed by the caller (``CableDyn_InitLine``).

        The model is structural only: two-node ``EI = 0`` axial elements with a
        consistent mass matrix, without gravity, buoyancy, seabed, hydrodynamics or
        structural damping, and without a static solve: the state starts at ``q0``,
        ``v0`` exactly. ``q0`` and ``v0`` are the node positions [m] and velocities
        [m/s], flat ``(3 * n_nodes,)`` or column-per-point ``(3, n_nodes)`` (a
        ``(3, 3)`` array is rejected as ambiguous). ``elem_conn`` is the **1-based**
        node pair of each element, flat ``(2 * n_elem,)`` or ``(n_elem, 2)``.
        ``l0``, ``ea`` and ``rho_a`` are the unstretched length [m], axial stiffness
        [N] and mass per unit length [kg/m] of each element, ``(n_elem,)``.
        ``fixed_dofs`` lists the **1-based** DOFs the caller prescribes; node ``k``
        owns DOFs ``3k-2, 3k-1, 3k``, and their order is the order of the coupled
        vector. A true ``tension_only`` lets an element go slack instead of carrying
        compression. ``rho_inf`` is the generalised-alpha spectral radius in
        ``[0, 1]``.

        The handle then has no deck and no points: :attr:`deck` is ``None`` and every
        coupled DOF is prescribed by the caller. The views of :attr:`lines` run from
        the last node of ``q0`` to its first, as they run from End A on a deck line,
        whose model holds End B first.

        A wrong shape, a non-finite value or a non-integer index raises
        :class:`ValueError` or :class:`TypeError` before the library is called, and
        changes nothing. The library judges the values and raises
        :class:`CableDynError`. After that error the handle must be initialized
        again, and a saved state is lost, unless it held a model on the coupled
        aggregate (finite-EI lines, bodies or rods), which stays live with its save.
        """
        q, v, conn, length, stiffness, mass, fixed = _raw_line_arrays(
            q0, v0, elem_conn, l0, ea, rho_a, fixed_dofs
        )
        slack = _as_flag(tension_only, "tension_only")
        radius = _as_spectral_radius(rho_inf)
        if q.size < 6 or length.size < 1:
            raise ValueError(
                f"a line needs at least 2 nodes and 1 element; got {q.size // 3} and {length.size}"
            )
        with self._lock:
            status = c_int()
            _lib.CableDyn_InitLine(
                self._handle,
                q.size // 3,
                length.size,
                _dbl_ptr(q),
                _dbl_ptr(v),
                _int_ptr(conn),
                _dbl_ptr(length),
                _dbl_ptr(stiffness),
                _dbl_ptr(mass),
                _int_ptr(fixed) if fixed.size else None,
                fixed.size,
                slack,
                radius,
                byref(status),
            )
            self._finish_raw_init("CableDyn_InitLine", status.value)

    def init_lines(
        self,
        n_nodes: ArrayInput,
        n_elem: ArrayInput,
        n_fixed: ArrayInput,
        q0: ArrayInput,
        v0: ArrayInput,
        elem_conn: ArrayInput,
        l0: ArrayInput,
        ea: ArrayInput,
        rho_a: ArrayInput,
        fixed_dofs: ArrayInput,
        tension_only: bool,
        rho_inf: float,
        coupled_map: ArrayInput | None = None,
    ) -> None:
        """Initialize from several lines meshed by the caller (``CableDyn_InitLines``).

        The lines are those of :meth:`init_line`, in one system. ``n_nodes``,
        ``n_elem`` and ``n_fixed`` hold the counts of each line; every other array is
        the concatenation, in line order, of that line's :meth:`init_line` array.
        ``elem_conn`` and ``fixed_dofs`` stay local to each line: node 1 is the first
        node of that line. ``tension_only`` and ``rho_inf`` apply to every line.

        Without ``coupled_map`` the lines are independent, and the coupled vector is
        their ``fixed_dofs`` in turn. ``coupled_map`` connects lines at shared points:
        every line has exactly six fixed DOFs, and entry ``6 * i + j`` (0-based ``i``,
        ``j``) is the **1-based** system DOF of line ``i``'s ``j``-th fixed DOF. The
        entries use every index from 1 to their maximum, which is the coupled DOF
        count; loads and Jacobian entries of a shared DOF are summed.

        Errors are those of :meth:`init_line`.
        """
        q, v, conn, length, stiffness, mass, fixed = _raw_line_arrays(
            q0, v0, elem_conn, l0, ea, rho_a, fixed_dofs
        )
        slack = _as_flag(tension_only, "tension_only")
        radius = _as_spectral_radius(rho_inf)
        nodes = _as_index_array(n_nodes, "n_nodes")
        elements = _as_index_array(n_elem, "n_elem")
        fixed_counts = _as_index_array(n_fixed, "n_fixed")
        n_lines = nodes.size
        if nodes.ndim != 1 or n_lines < 1:
            raise ValueError(f"n_nodes must be flat with an entry per line; got {nodes.shape}")
        for name, counts in (("n_elem", elements), ("n_fixed", fixed_counts)):
            if counts.shape != nodes.shape:
                raise ValueError(f"{name} must have {n_lines} entries; got shape {counts.shape}")
        if np.any(nodes < 2) or np.any(elements < 1) or np.any(fixed_counts < 0):
            raise ValueError(
                "every line needs at least 2 nodes, 1 element and 0 fixed DOFs; got "
                f"n_nodes {nodes.tolist()}, n_elem {elements.tolist()}, "
                f"n_fixed {fixed_counts.tolist()}"
            )
        totals = (
            ("q0", q.size, 3 * int(nodes.sum(dtype=np.int64))),
            ("l0", length.size, int(elements.sum(dtype=np.int64))),
            ("fixed_dofs", fixed.size, int(fixed_counts.sum(dtype=np.int64))),
        )
        for name, size, expected in totals:
            if size != expected:
                raise ValueError(f"{name} must hold {expected} values in all; got {size}")
        shared = _as_index_array((), "coupled_map")
        if coupled_map is not None:
            shared = _as_index_array(coupled_map, "coupled_map")
        if shared.size:
            if shared.shape != (6 * n_lines,):
                raise ValueError(
                    f"coupled_map must be flat ({6 * n_lines},); got shape {shared.shape}"
                )
            if np.any(fixed_counts != 6):
                raise ValueError("coupled_map needs exactly six fixed DOFs on every line")
        with self._lock:
            status = c_int()
            _lib.CableDyn_InitLines(
                self._handle,
                n_lines,
                _int_ptr(nodes),
                _int_ptr(elements),
                _int_ptr(fixed_counts),
                _dbl_ptr(q),
                _dbl_ptr(v),
                _int_ptr(conn),
                _dbl_ptr(length),
                _dbl_ptr(stiffness),
                _dbl_ptr(mass),
                _int_ptr(fixed) if fixed.size else None,
                _int_ptr(shared) if shared.size else None,
                shared.size,
                slack,
                radius,
                byref(status),
            )
            self._finish_raw_init("CableDyn_InitLines", status.value)

    def _finish_raw_init(self, call: str, status: int) -> None:
        """Book-keeping after InitLine or InitLines (the caller holds the lock).

        A failed call can leave the earlier model live, whose time and views then stand.
        """
        if status != 0:
            message = self._last_error()
            if not _lib.CableDyn_IsInitialized(self._handle):
                self._initialized_from(None)
            raise CableDynError(call, status, message)
        self._initialized_from(None)

    def _initialized_from(self, deck: Path | None) -> None:
        """Book-keeping after a successful initialization (the caller holds the lock)."""
        self._generation += 1
        self._views_valid = False
        self._time = 0.0
        self._saved_time = None
        self._deck = deck

    @staticmethod
    def _require_host_fluid() -> None:
        if _lib_module.abi_minor() < _lib_module.HOST_FLUID_ABI_MINOR:
            # not a C status: the loaded library lacks the entry points
            raise RuntimeError(
                "the loaded CableDyn library predates the host fluid calls "
                "(ABI 1 minor extension 4); rebuild it from this checkout"
            )

    @staticmethod
    def _require_host_rotation() -> None:
        if _lib_module.abi_minor() < _lib_module.HOST_ROTATION_ABI_MINOR:
            # not a C status: the loaded library lacks the entry points
            raise RuntimeError(
                "the loaded CableDyn library predates the host-rotation calls "
                "(ABI 1 minor extension 3); rebuild it from this checkout"
            )

    @staticmethod
    def _require_host_coupling() -> None:
        if _lib_module.abi_minor() < _lib_module.HOST_COUPLING_ABI_MINOR:
            # not a C status: the loaded library lacks the entry points
            raise RuntimeError(
                "the loaded CableDyn library predates the host-coupling calls "
                "(ABI 1 minor extension 2); rebuild it from this checkout"
            )

    @property
    def initialized(self) -> bool:
        """Whether the handle holds an initialized model."""
        with self._lock:
            return bool(_lib.CableDyn_IsInitialized(self._handle))

    # -- structure queries ----------------------------------------------------

    def _query(self, fn: Callable[..., int], call: str) -> int:
        with self._lock:
            status = c_int()
            n = fn(self._handle, byref(status))
            self._check(call, status.value)
            return int(n)

    @property
    def n_coupled_dof(self) -> int:
        """Coupled DOF count (3 per host-driven point)."""
        return self._query(_lib.CableDyn_NCoupledDOF, "CableDyn_NCoupledDOF")

    @property
    def n_points(self) -> int:
        """Stored system point count (the fluid-field column count)."""
        return self._query(_lib.CableDyn_NPoints, "CableDyn_NPoints")

    @property
    def n_lines(self) -> int:
        """Owned line count."""
        return self._query(_lib.CableDyn_NLines, "CableDyn_NLines")

    @property
    def deck(self) -> Path | None:
        """Absolute path of the deck the model was initialized from, if any."""
        with self._lock:
            return self._deck

    @property
    def time(self) -> float:
        """Simulation time [s]: 0 after initialization, advanced by every completed step.

        :meth:`restore_state` sets it back to the time of the saved state.
        """
        with self._lock:
            return self._time

    # -- object queries -------------------------------------------------------

    def _object_views(
        self,
    ) -> tuple[tuple[Line, ...], tuple[Point, ...], tuple[Body, ...], tuple[Rod, ...]]:
        with self._lock:
            if not self._views_valid:
                if _lib_module.abi_minor() < _lib_module.OBJECT_QUERY_ABI_MINOR:
                    # not a C status: the loaded library lacks the entry points
                    raise RuntimeError(
                        "the loaded CableDyn library predates the object queries "
                        "(ABI 1 minor extension 1); rebuild it from this checkout"
                    )
                self._views = build_views(self)
                self._views_valid = True
            return self._views

    @property
    def lines(self) -> tuple[Line, ...]:
        """The model's lines in ascending deck id (see :class:`~cabledyn.objects.Line`)."""
        return self._object_views()[0]

    @property
    def points(self) -> tuple[Point, ...]:
        """The model's points in solver order (see :class:`~cabledyn.objects.Point`)."""
        return self._object_views()[1]

    @property
    def bodies(self) -> tuple[Body, ...]:
        """The model's Rigid6 bodies (see :class:`~cabledyn.objects.Body`)."""
        return self._object_views()[2]

    @property
    def rods(self) -> tuple[Rod, ...]:
        """The model's rods (see :class:`~cabledyn.objects.Rod`)."""
        return self._object_views()[3]

    @staticmethod
    def _by_id(items: tuple[Any, ...], object_id: int, kind: str) -> Any:
        for item in items:
            if item.id == object_id:
                return item
        raise KeyError(f"no {kind} with deck id {object_id}")

    def line(self, line_id: int) -> Line:
        """The line with deck id ``line_id``."""
        result: Line = self._by_id(self.lines, line_id, "line")
        return result

    def point(self, point_id: int) -> Point:
        """The point with deck id ``point_id``."""
        result: Point = self._by_id(self.points, point_id, "point")
        return result

    def body(self, body_id: int) -> Body:
        """The body with deck id ``body_id``."""
        result: Body = self._by_id(self.bodies, body_id, "body")
        return result

    def rod(self, rod_id: int) -> Rod:
        """The rod with deck id ``rod_id``."""
        result: Rod = self._by_id(self.rods, rod_id, "rod")
        return result

    def channel(self, token: str) -> float:
        """Evaluate one output channel at the committed state.

        ``token`` uses the deck OUTPUTS vocabulary (``FairTen1``, ``L2N5px``,
        ``Curv1N3``, ``Point4Fz``, ``Body1Pz``, ``Rod2TenA``, ...) and returns the
        value the standalone driver writes for that channel at the same state. A
        node channel names a deck node, also on a finite-EI line whose mesh the
        static solve refined.
        """
        with self._lock:
            self._object_views()
            return eval_channel(self, token)

    def channels(self, tokens: list[str] | tuple[str, ...]) -> FloatArray:
        """Evaluate several output channels; returns ``(len(tokens),)``."""
        with self._lock:
            return np.array([self.channel(token) for token in tokens], dtype=np.float64)

    def step_held(self, dt: float) -> int:
        """Advance one step with every coupled point held at its current position.

        The coupled kinematics are the current positions with zero velocity and
        acceleration, the standalone driver's treatment of a deck without vessel
        motion. Returns the Newton iteration count, as :meth:`step`.
        """
        with self._lock:
            q, _, _ = self.get_coupled_motion()
            zero = np.zeros_like(q)
            return self.step(dt, q, zero, zero)

    # -- the coupling boundary ------------------------------------------------

    def get_coupled_motion(self) -> tuple[FloatArray, FloatArray, FloatArray]:
        """Current coupled kinematics ``(q, v, a)``, each shaped ``(n_dof,)``."""
        with self._lock:
            n = self.n_coupled_dof
            q = np.zeros(n)
            v = np.zeros(n)
            a = np.zeros(n)
            status = c_int()
            _lib.CableDyn_GetCoupledMotion(
                self._handle, _dbl_ptr(q), _dbl_ptr(v), _dbl_ptr(a), n, byref(status)
            )
            self._check("CableDyn_GetCoupledMotion", status.value)
            return q, v, a

    def update_states(self, q: ArrayInput, v: ArrayInput, a: ArrayInput) -> None:
        """Transfer coupled kinematics without advancing time (direct feedthrough)."""
        with self._lock:
            n = self.n_coupled_dof
            qa = _as_dof_array(q, n, "q")
            va = _as_dof_array(v, n, "v")
            aa = _as_dof_array(a, n, "a")
            status = c_int()
            _lib.CableDyn_UpdateStates(
                self._handle, _dbl_ptr(qa), _dbl_ptr(va), _dbl_ptr(aa), n, byref(status)
            )
            self._check("CableDyn_UpdateStates", status.value)

    def step(self, dt: float, q: ArrayInput, v: ArrayInput, a: ArrayInput) -> int:
        """Advance one implicit step of ``dt`` with the coupled kinematics at t+dt.

        Returns the Newton iteration count. A failed step raises
        :class:`CableDynError` and leaves the state at ``t``. A step that ends
        without meeting the Newton tolerance raises :class:`ConvergenceError`;
        the model has then already advanced to ``t + dt`` with its best iterate.
        ``dt`` must be a finite positive real number (a string, complex, or
        boolean value raises :class:`TypeError`); the library refuses one below
        ``1e-100`` s, as the time integration divides by ``dt**2``.
        """
        step_dt = _as_real_scalar(dt, "dt", positive=True)
        with self._lock:
            n = self.n_coupled_dof
            qa = _as_dof_array(q, n, "q")
            va = _as_dof_array(v, n, "v")
            aa = _as_dof_array(a, n, "a")
            conv = c_bool()
            stall = c_bool()
            nit = c_int()
            status = c_int()
            _lib.CableDyn_Step(
                self._handle,
                step_dt,
                _dbl_ptr(qa),
                _dbl_ptr(va),
                _dbl_ptr(aa),
                n,
                byref(conv),
                byref(stall),
                byref(nit),
                byref(status),
            )
            self._check("CableDyn_Step", status.value)
            self._time += step_dt
            if not conv.value:
                detail = self._last_error() or (
                    f"Newton tolerance not met after {nit.value} iterations"
                    + (" (line search stalled)" if stall.value else "")
                )
                raise ConvergenceError(
                    "CableDyn_Step", detail, n_iter=int(nit.value), stalled=bool(stall.value)
                )
            return int(nit.value)

    def calc_output(self) -> FloatArray:
        """The coupled reaction loads at the current committed state, ``(n_dof,)`` N."""
        with self._lock:
            n = self.n_coupled_dof
            loads = np.zeros(n)
            status = c_int()
            _lib.CableDyn_CalcOutput(self._handle, _dbl_ptr(loads), n, byref(status))
            self._check("CableDyn_CalcOutput", status.value)
            return loads

    def calc_output_derivatives(
        self, q: ArrayInput, v: ArrayInput, a: ArrayInput
    ) -> tuple[FloatArray, FloatArray, FloatArray, FloatArray, FloatArray]:
        """The coupled loads and their analytic Jacobians at an operating point.

        ``q``, ``v`` and ``a`` are the operating point, as in :meth:`update_states`.
        Returns ``(loads, dload_dq, dload_dv, dload_da, added_mass)``: ``loads`` is
        ``(n_dof,)`` [N], and the others are ``(n_dof, n_dof)`` with ``J[i, j]`` the
        derivative of load ``i`` with respect to coupled DOF ``j``, in N/m, N s/m and
        kg; ``added_mass`` is ``-dload_da``.

        Each line's interior DOFs are condensed out at the operating point: interior
        positions and velocities are held, and interior accelerations are eliminated
        through the mass matrix, so ``dload_da`` is
        ``-(M_cc - M_cf inv(M_ff) M_fc)``. The Jacobians are therefore those of
        :meth:`update_states` followed by :meth:`calc_output`, the instantaneous
        response of the end loads to the end motion.

        This call **sets the model state**, as :meth:`update_states` does, also when
        a later stage of it fails; :attr:`time` stays. Call :meth:`update_states` with
        the previous kinematics to return to them. A model on the coupled aggregate
        (finite-EI lines, bodies or rods) has no load derivatives and raises
        :class:`CableDynError`.
        """
        with self._lock:
            n = self.n_coupled_dof
            qa = _as_dof_array(q, n, "q")
            va = _as_dof_array(v, n, "v")
            aa = _as_dof_array(a, n, "a")
            loads = np.zeros(n)
            # The library writes J[i + j*n]: column-major, so J[i, j] reads as it should.
            dload_dq = np.zeros((n, n), order="F")
            dload_dv = np.zeros((n, n), order="F")
            dload_da = np.zeros((n, n), order="F")
            added_mass = np.zeros((n, n), order="F")
            status = c_int()
            # The library's eps_fd argument is unused: the blocks are analytic.
            _lib.CableDyn_CalcOutputDerivatives(
                self._handle,
                _dbl_ptr(qa) if n else None,
                _dbl_ptr(va) if n else None,
                _dbl_ptr(aa) if n else None,
                n,
                0.0,
                _dbl_ptr(loads) if n else None,
                _dbl_ptr(dload_dq) if n else None,
                _dbl_ptr(dload_dv) if n else None,
                _dbl_ptr(dload_da) if n else None,
                _dbl_ptr(added_mass) if n else None,
                byref(status),
            )
            self._check("CableDyn_CalcOutputDerivatives", status.value)
            return loads, dload_dq, dload_dv, dload_da, added_mass

    # -- host coupling: outer correctors and the coupled layout -------------------

    def save_state(self) -> None:
        """Save the whole model and :attr:`time` into the handle's single save slot.

        The slot is a deep copy of the model (every line, point, body and rod
        state with its solver history), replacing any earlier save. A successful
        initialization discards it and a failed one keeps it with the model, so one
        save serves every outer corrector of a host time step (see
        :meth:`restore_state`). Save when a host time step starts after the
        previous one was accepted, and restore on every repeated pass from the
        same start time, whatever its ``dt``.
        """
        with self._lock:
            self._require_host_coupling()
            status = c_int()
            _lib.CableDyn_SaveState(self._handle, byref(status))
            if status.value != 0:
                self._saved_time = None  # a failed save leaves no save in the slot
            self._check("CableDyn_SaveState", status.value)
            self._saved_time = self._time

    def restore_state(self) -> None:
        """Return the model and :attr:`time` to the last :meth:`save_state`.

        The save is kept, so the call can be repeated. A restore followed by a
        step is bit-identical to taking that step from the saved state directly.
        Raises :class:`CableDynError` when nothing was saved since the model was
        initialized.
        """
        with self._lock:
            self._require_host_coupling()
            status = c_int()
            _lib.CableDyn_RestoreState(self._handle, byref(status))
            self._check("CableDyn_RestoreState", status.value)
            if self._saved_time is not None:
                self._time = self._saved_time

    # -- host rotations -------------------------------------------------------

    def update_rotations(self, dcm: ArrayInput, omega: ArrayInput, alpha: ArrayInput) -> None:
        """Set the host's rotation of every coupled block for the next updates and steps.

        ``dcm`` is ``(n_block, 3, 3)``: ``dcm[k]`` is block ``k``'s global-to-body
        direction cosine matrix (its rows are the body axes in global axes, the
        OpenFAST mesh orientation; identity is the body at its static-start
        attitude). ``omega`` and ``alpha`` are ``(n_block, 3)``: the body's
        angular velocity [rad/s] and acceleration [rad/s^2] in global axes. Only a
        finite-EI line's host-driven end uses its block. The rotations are kept
        until the next call and saved with :meth:`save_state`. Requires
        :meth:`init_deck_rotating`; a rejected input (a matrix that is not proper
        orthogonal to 1e-8, a non-finite value) leaves the rotations unchanged.
        """
        with self._lock:
            self._require_host_rotation()
            nb = self.n_coupled_dof // 3
            r = _as_real_array(dcm, "dcm")
            w = _as_real_array(omega, "omega")
            al = _as_real_array(alpha, "alpha")
            if r.shape != (nb, 3, 3):
                raise ValueError(f"dcm must be shaped ({nb}, 3, 3); got {r.shape}")
            for name, x in (("omega", w), ("alpha", al)):
                if x.shape != (nb, 3):
                    raise ValueError(f"{name} must be shaped ({nb}, 3); got {x.shape}")
            r = np.ascontiguousarray(r.reshape(-1))
            w = np.ascontiguousarray(w.reshape(-1))
            al = np.ascontiguousarray(al.reshape(-1))
            status = c_int()
            _lib.CableDyn_UpdateRotations(
                self._handle,
                _dbl_ptr(r) if nb else None,
                _dbl_ptr(w) if nb else None,
                _dbl_ptr(al) if nb else None,
                nb,
                byref(status),
            )
            self._check("CableDyn_UpdateRotations", status.value)

    def coupled_moments(self) -> FloatArray:
        """The moments the lines apply to the host at the coupled points, ``(n_dof,)`` N m.

        Block ``k`` (entries ``3k .. 3k+2``, global axes) is a finite-EI line's
        torsional and bending reaction about the coupled point at its host-driven
        end, at the state :meth:`calc_output` reports; zero for the other blocks
        and for ``EI = 0`` lines.
        """
        with self._lock:
            self._require_host_rotation()
            n = self.n_coupled_dof
            moments = np.zeros(n)
            status = c_int()
            _lib.CableDyn_GetCoupledMoments(
                self._handle, _dbl_ptr(moments) if n else None, n, byref(status)
            )
            self._check("CableDyn_GetCoupledMoments", status.value)
            return moments

    def coupled_layout(self) -> tuple[tuple[int, PointKind], ...]:
        """The owner of each 3-DOF block of the coupled vector, as ``(point_id, kind)``.

        Block ``k`` holds DOFs ``3k .. 3k+2`` of the vectors :meth:`step`,
        :meth:`get_coupled_motion` and :meth:`calc_output` use; ``kind`` is
        ``"fixed"``, ``"coupled"`` (Coupled or Vessel), ``"free"`` or
        ``"connect"``. On a point-system deck every line-bound point has a block,
        in deck POINTS order; on the coupled aggregate (finite-EI lines, bodies or
        rods) only the Coupled points do: those of the ``EI = 0`` lines, then the
        End A of every finite-EI line, then the End B of every finite-EI line
        between two Coupled points (so such a point id appears once per line end).
        The host drives the ``"coupled"`` blocks (:meth:`host_dofs`).
        """
        with self._lock:
            self._require_host_coupling()
            nb = self.n_coupled_dof // 3
            ids = np.zeros(max(nb, 1), dtype=np.intc)
            kinds = np.zeros(max(nb, 1), dtype=np.intc)
            status = c_int()
            _lib.CableDyn_GetCoupledLayout(
                self._handle,
                ids.ctypes.data_as(POINTER(c_int)),
                kinds.ctypes.data_as(POINTER(c_int)),
                nb,
                byref(status),
            )
            self._check("CableDyn_GetCoupledLayout", status.value)
            return tuple((int(ids[k]), _POINT_KINDS.get(int(kinds[k]), "fixed")) for k in range(nb))

    def host_dofs(self) -> npt.NDArray[np.intp]:
        """Indices of the coupled DOFs the host drives (the ``"coupled"`` blocks).

        With ``x`` the ``(3, n)`` host positions of those points in layout order,
        ``q[model.host_dofs()] = x.reshape(-1, order="F")`` fills them in a full
        coupled vector ``q`` taken from :meth:`get_coupled_motion`.
        """
        layout = self.coupled_layout()
        blocks = [k for k, (_, kind) in enumerate(layout) if kind == "coupled"]
        return np.array([3 * k + c for k in blocks for c in range(3)], dtype=np.intp)

    def set_host_fluid(self, enable: bool = True) -> None:
        """Choose, before a deck initialization, whether the host supplies the fluid.

        With ``enable`` the following :meth:`init_deck`, :meth:`init_deck_at` and
        :meth:`init_deck_rotating` take the field of :meth:`update_fluid_fields`:
        deck waves are refused, and a steady deck current sets the static start
        only. The deck needs ``dtM`` and a seabed.
        """
        with self._lock:
            self._require_host_fluid()
            status = c_int()
            _lib.CableDyn_SetHostFluid(self._handle, 1 if enable else 0, byref(status))
            self._check("CableDyn_SetHostFluid", status.value)

    @property
    def n_fluid_nodes(self) -> int:
        """Nodes of the host fluid field; zero without one."""
        with self._lock:
            self._require_host_fluid()
            status = c_int()
            n = _lib.CableDyn_NFluidNodes(self._handle, byref(status))
            self._check("CableDyn_NFluidNodes", status.value)
            return int(n)

    def fluid_node_positions(self) -> FloatArray:
        """Committed fluid node positions ``(3, n_fluid_nodes)``, global axes [m].

        Where the host evaluates the field of the coming step.
        """
        with self._lock:
            n = self.n_fluid_nodes
            xyz = np.zeros(3 * n)
            status = c_int()
            _lib.CableDyn_GetFluidNodePositions(
                self._handle, _dbl_ptr(xyz) if n else None, n, byref(status)
            )
            self._check("CableDyn_GetFluidNodePositions", status.value)
            return xyz.reshape(n, 3).T.copy()

    def update_fluid_fields(
        self,
        fluid_velocity: ArrayInput,
        fluid_acceleration: ArrayInput,
        waterline_z: ArrayInput,
        dynamic_pressure: ArrayInput | None = None,
    ) -> None:
        """Prescribe the ambient fluid at every fluid node, held until the next call.

        ``fluid_velocity`` and ``fluid_acceleration`` are ``(3, n_fluid_nodes)`` in
        global axes, ``waterline_z`` the free-surface elevation ``(n_fluid_nodes,)``,
        ``dynamic_pressure`` the wave pressure ``(n_fluid_nodes,)`` rods use for their
        end caps. Call it once with the field at ``t = 0`` before the first step, then
        before each step from ``t`` to ``t + dt`` with the field at ``t + dt`` at the
        positions of :meth:`fluid_node_positions`. The density is the deck's.
        """
        with self._lock:
            n = self.n_fluid_nodes
            fv = _as_field(fluid_velocity, n, "fluid_velocity")
            fa = _as_field(fluid_acceleration, n, "fluid_acceleration")
            wl = _as_node_values(waterline_z, n, "waterline_z")
            dp = (
                None
                if dynamic_pressure is None
                else _as_node_values(dynamic_pressure, n, "dynamic_pressure")
            )
            status = c_int()
            _lib.CableDyn_UpdateFluidFields(
                self._handle,
                _dbl_ptr(fv) if n else None,
                _dbl_ptr(fa) if n else None,
                _dbl_ptr(wl) if n else None,
                _dbl_ptr(dp) if dp is not None and n else None,
                n,
                byref(status),
            )
            self._check("CableDyn_UpdateFluidFields", status.value)

    def update_point_fluid_fields(
        self,
        fluid_velocity: ArrayInput,
        fluid_acceleration: ArrayInput,
        waterline_z: ArrayInput,
        fluid_density: float,
    ) -> None:
        """Prescribe external per-point fluid kinematics (the CFD-coupling surface).

        ``fluid_velocity`` and ``fluid_acceleration`` are ``(3, n_points)`` or
        flat ``(3 * n_points,)``; ``waterline_z`` is ``(n_points,)``;
        ``fluid_density`` is a finite non-negative real number.
        """
        density = _as_real_scalar(fluid_density, "fluid_density", positive=False)
        with self._lock:
            npt_ = self.n_points
            fv = _as_dof_array(fluid_velocity, 3 * npt_, "fluid_velocity")
            fa = _as_dof_array(fluid_acceleration, 3 * npt_, "fluid_acceleration")
            wl = _as_real_array(waterline_z, "waterline_z")
            if wl.ndim != 1 or wl.size != npt_:
                raise ValueError(f"waterline_z must have {npt_} entries")
            if not np.all(np.isfinite(wl)):
                raise ValueError("waterline_z must be finite (no NaN or Inf)")
            status = c_int()
            _lib.CableDyn_UpdatePointFluidFields(
                self._handle,
                _dbl_ptr(fv),
                _dbl_ptr(fa),
                _dbl_ptr(wl),
                npt_,
                density,
                byref(status),
            )
            self._check("CableDyn_UpdatePointFluidFields", status.value)
