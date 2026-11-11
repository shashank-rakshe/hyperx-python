# SPDX-License-Identifier: Apache-2.0
"""Shared-library discovery and ctypes prototypes for the CableDyn C ABI.

The entry points used by :mod:`cabledyn.model` are declared here with their
exact argument lists from ``src/CableDyn_CAPI.h``. The supported ABI version is
pinned; a library speaking another ABI is rejected at import. Library discovery
is described in :mod:`cabledyn._discovery`.
"""

from __future__ import annotations

import ctypes
import os
import sys
from ctypes import (
    POINTER,
    c_bool,
    c_char_p,
    c_double,
    c_int,
    c_void_p,
)
from pathlib import Path

from cabledyn._discovery import dependency_directories, find_library

#: The CableDyn C ABI version this binding is written against
#: (CD_C_ABI_VERSION in src/CableDyn_CAPI.f90).
SUPPORTED_ABI = 1


# Windows DLL-directory handles must outlive the CDLL load: add_dll_directory
# returns a handle whose garbage collection removes the directory from the
# search path again, which can break resolution of co-located transitive DLLs
# (libgfortran, OpenBLAS) on a later lazy bind. Kept for the process lifetime.
_dll_dir_handles: list[object] = []


def _load() -> tuple[ctypes.CDLL, Path]:
    path = find_library()
    if sys.platform == "win32":
        # The solver DLL depends on toolchain runtimes (libgfortran, OpenBLAS).
        # Python ignores PATH for dependent DLLs, so register their directories.
        for directory in dependency_directories(path):
            _dll_dir_handles.append(os.add_dll_directory(str(directory)))
    return ctypes.CDLL(str(path)), path


_lib, _lib_path = _load()


def library_path() -> str:
    """Absolute path of the loaded CableDyn shared library."""
    return str(_lib_path)


# --- prototypes (one per BIND(C) entry point, argument-exact) ---------------

_lib.CableDyn_GetVersion.argtypes = [POINTER(c_int)] * 4
_lib.CableDyn_GetVersion.restype = None

_lib.CableDyn_GetVersionString.argtypes = [c_char_p, c_int]
_lib.CableDyn_GetVersionString.restype = None

_lib.CableDyn_Create.argtypes = [POINTER(c_void_p), POINTER(c_int)]
_lib.CableDyn_Create.restype = None

_lib.CableDyn_Close.argtypes = [POINTER(c_void_p), POINTER(c_int)]
_lib.CableDyn_Close.restype = None

_lib.CableDyn_InitDeck.argtypes = [c_void_p, c_char_p, c_int, POINTER(c_int)]
_lib.CableDyn_InitDeck.restype = None

_lib.CableDyn_IsInitialized.argtypes = [c_void_p]
_lib.CableDyn_IsInitialized.restype = c_bool

_lib.CableDyn_NCoupledDOF.argtypes = [c_void_p, POINTER(c_int)]
_lib.CableDyn_NCoupledDOF.restype = c_int

_lib.CableDyn_NPoints.argtypes = [c_void_p, POINTER(c_int)]
_lib.CableDyn_NPoints.restype = c_int

_lib.CableDyn_NLines.argtypes = [c_void_p, POINTER(c_int)]
_lib.CableDyn_NLines.restype = c_int

_lib.CableDyn_GetLastError.argtypes = [c_void_p, c_char_p, c_int]
_lib.CableDyn_GetLastError.restype = None

_DBL = POINTER(c_double)
_INT = POINTER(c_int)

_lib.CableDyn_InitLine.argtypes = [
    c_void_p,
    c_int,
    c_int,
    _DBL,
    _DBL,
    _INT,
    _DBL,
    _DBL,
    _DBL,
    _INT,
    c_int,
    c_int,
    c_double,
    _INT,
]
_lib.CableDyn_InitLine.restype = None

_lib.CableDyn_InitLines.argtypes = [
    c_void_p,
    c_int,
    _INT,
    _INT,
    _INT,
    _DBL,
    _DBL,
    _INT,
    _DBL,
    _DBL,
    _DBL,
    _INT,
    _INT,
    c_int,
    c_int,
    c_double,
    _INT,
]
_lib.CableDyn_InitLines.restype = None

_lib.CableDyn_UpdateStates.argtypes = [c_void_p, _DBL, _DBL, _DBL, c_int, POINTER(c_int)]
_lib.CableDyn_UpdateStates.restype = None

_lib.CableDyn_Step.argtypes = [
    c_void_p,
    c_double,
    _DBL,
    _DBL,
    _DBL,
    c_int,
    POINTER(c_bool),
    POINTER(c_bool),
    POINTER(c_int),
    POINTER(c_int),
]
_lib.CableDyn_Step.restype = None

_lib.CableDyn_CalcOutput.argtypes = [c_void_p, _DBL, c_int, POINTER(c_int)]
_lib.CableDyn_CalcOutput.restype = None

_lib.CableDyn_CalcOutputDerivatives.argtypes = [
    c_void_p,
    _DBL,
    _DBL,
    _DBL,
    c_int,
    c_double,
    _DBL,
    _DBL,
    _DBL,
    _DBL,
    _DBL,
    _INT,
]
_lib.CableDyn_CalcOutputDerivatives.restype = None

_lib.CableDyn_GetCoupledMotion.argtypes = [c_void_p, _DBL, _DBL, _DBL, c_int, POINTER(c_int)]
_lib.CableDyn_GetCoupledMotion.restype = None

_lib.CableDyn_UpdatePointFluidFields.argtypes = [
    c_void_p,
    _DBL,
    _DBL,
    _DBL,
    c_int,
    c_double,
    POINTER(c_int),
]
_lib.CableDyn_UpdatePointFluidFields.restype = None


# --- ABI 1, minor extension 1: in-process object queries -------------------
# A library built before the extension lacks these symbols; ``abi_minor()``
# then reports 0 and the object API raises a clear error instead of binding.

#: Minor extension level of ABI 1 this binding uses for the object queries.
OBJECT_QUERY_ABI_MINOR = 1


def _bind_object_queries() -> bool:
    try:
        minor_fn = _lib.CableDyn_GetAbiMinor
    except AttributeError:
        return False
    minor_fn.argtypes = []
    minor_fn.restype = c_int
    _lib.CableDyn_NObjects.argtypes = [c_void_p, c_int, POINTER(c_int)]
    _lib.CableDyn_NObjects.restype = c_int
    _lib.CableDyn_GetObjectInfo.argtypes = [
        c_void_p,
        c_int,
        c_int,
        POINTER(c_int),
        POINTER(c_int),
        POINTER(c_int),
        POINTER(c_int),
    ]
    _lib.CableDyn_GetObjectInfo.restype = None
    _lib.CableDyn_GetLineValues.argtypes = [c_void_p, c_int, c_int, _DBL, c_int, POINTER(c_int)]
    _lib.CableDyn_GetLineValues.restype = None
    _lib.CableDyn_GetPointState.argtypes = [c_void_p, c_int, _DBL, _DBL, _DBL, POINTER(c_int)]
    _lib.CableDyn_GetPointState.restype = None
    _lib.CableDyn_GetBodyState.argtypes = [c_void_p, c_int, _DBL, _DBL, _DBL, _DBL, POINTER(c_int)]
    _lib.CableDyn_GetBodyState.restype = None
    _lib.CableDyn_GetRodState.argtypes = [
        c_void_p,
        c_int,
        _DBL,
        c_int,
        _DBL,
        _DBL,
        _DBL,
        POINTER(c_int),
    ]
    _lib.CableDyn_GetRodState.restype = None
    _lib.CableDyn_EvalChannel.argtypes = [c_void_p, c_char_p, c_int, _DBL, POINTER(c_int)]
    _lib.CableDyn_EvalChannel.restype = None
    return True


_has_object_queries = _bind_object_queries()


# --- ABI 1, minor extension 2: host coupling ---------------------------------
# Initialization at the host's coupled positions, the one-slot state save and
# restore of outer correctors, and the coupled layout query. A library built
# before the extension lacks these symbols and reports ``abi_minor() < 2``.

#: Minor extension level of ABI 1 this binding uses for the host-coupling calls.
HOST_COUPLING_ABI_MINOR = 2


def _bind_host_coupling() -> bool:
    try:
        init_at = _lib.CableDyn_InitDeckAt
    except AttributeError:
        return False
    init_at.argtypes = [c_void_p, c_char_p, c_int, _DBL, c_int, POINTER(c_int)]
    init_at.restype = None
    _lib.CableDyn_SaveState.argtypes = [c_void_p, POINTER(c_int)]
    _lib.CableDyn_SaveState.restype = None
    _lib.CableDyn_RestoreState.argtypes = [c_void_p, POINTER(c_int)]
    _lib.CableDyn_RestoreState.restype = None
    _lib.CableDyn_GetCoupledLayout.argtypes = [
        c_void_p,
        POINTER(c_int),
        POINTER(c_int),
        c_int,
        POINTER(c_int),
    ]
    _lib.CableDyn_GetCoupledLayout.restype = None
    return True


_has_host_coupling = _bind_host_coupling()


# --- ABI 1, minor extension 3: host rotations --------------------------------
# Initialization for a host that turns its coupled points, their rotations, and
# the coupled moments. A library built before the extension lacks these symbols
# and reports ``abi_minor() < 3``.

#: Minor extension level of ABI 1 this binding uses for the host-rotation calls.
HOST_ROTATION_ABI_MINOR = 3


def _bind_host_rotation() -> bool:
    try:
        init_rot = _lib.CableDyn_InitDeckRotating
    except AttributeError:
        return False
    init_rot.argtypes = [c_void_p, c_char_p, c_int, _DBL, c_int, POINTER(c_int)]
    init_rot.restype = None
    _lib.CableDyn_UpdateRotations.argtypes = [c_void_p, _DBL, _DBL, _DBL, c_int, POINTER(c_int)]
    _lib.CableDyn_UpdateRotations.restype = None
    _lib.CableDyn_GetCoupledMoments.argtypes = [c_void_p, _DBL, c_int, POINTER(c_int)]
    _lib.CableDyn_GetCoupledMoments.restype = None
    return True


_has_host_rotation = _bind_host_rotation()

# Host fluid field (ABI minor 4). A library built before the extension lacks these
# symbols and reports ``abi_minor() < 4``.

#: Minor extension level of ABI 1 this binding uses for the host fluid field
#: (the newest extension the binding knows).
HOST_FLUID_ABI_MINOR = 4


def _bind_host_fluid() -> bool:
    try:
        set_fluid = _lib.CableDyn_SetHostFluid
    except AttributeError:
        return False
    set_fluid.argtypes = [c_void_p, c_int, POINTER(c_int)]
    set_fluid.restype = None
    _lib.CableDyn_NFluidNodes.argtypes = [c_void_p, POINTER(c_int)]
    _lib.CableDyn_NFluidNodes.restype = c_int
    _lib.CableDyn_GetFluidNodePositions.argtypes = [c_void_p, _DBL, c_int, POINTER(c_int)]
    _lib.CableDyn_GetFluidNodePositions.restype = None
    _lib.CableDyn_UpdateFluidFields.argtypes = [
        c_void_p,
        _DBL,
        _DBL,
        _DBL,
        _DBL,
        c_int,
        POINTER(c_int),
    ]
    _lib.CableDyn_UpdateFluidFields.restype = None
    return True


_has_host_fluid = _bind_host_fluid()


def _bind_init_notes() -> bool:
    # Bound on its own: a library of ABI minor 4 may predate this entry point, and nothing but
    # ``CableDyn.init_notes`` needs it.
    try:
        get_notes = _lib.CableDyn_GetInitNotes
    except AttributeError:
        return False
    get_notes.argtypes = [c_void_p, c_char_p, c_int]
    get_notes.restype = c_int
    return True


_has_init_notes = _bind_init_notes()


def abi_minor() -> int:
    """The loaded library's ABI 1 extension level (0 before the object queries)."""
    if not _has_object_queries:
        return 0
    return int(_lib.CableDyn_GetAbiMinor())


def version() -> tuple[int, int, int, int]:
    """(major, minor, patch, abi_version) of the loaded library."""
    major = c_int()
    minor = c_int()
    patch = c_int()
    abi = c_int()
    _lib.CableDyn_GetVersion(
        ctypes.byref(major), ctypes.byref(minor), ctypes.byref(patch), ctypes.byref(abi)
    )
    return major.value, minor.value, patch.value, abi.value


def abi_version() -> int:
    """The loaded library's C ABI version."""
    return version()[3]


def version_string() -> str:
    """The loaded library's human-readable version string."""
    buf = ctypes.create_string_buffer(128)
    _lib.CableDyn_GetVersionString(buf, len(buf))
    return buf.value.decode("ascii", errors="replace")


_loaded_abi = abi_version()
if _loaded_abi != SUPPORTED_ABI:
    raise OSError(
        f"cabledyn: the loaded library at {_lib_path} speaks C ABI "
        f"{_loaded_abi}, but this binding supports ABI {SUPPORTED_ABI}. "
        "Rebuild the library and the package from the same CableDyn checkout."
    )
