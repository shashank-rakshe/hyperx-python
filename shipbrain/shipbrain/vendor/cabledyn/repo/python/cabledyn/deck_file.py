# SPDX-License-Identifier: Apache-2.0
"""Loss-aware reading, validation, editing, and case generation for decks.

The reader mirrors the native Fortran deck reader: records end at ``\\r\\n``,
``\\n``, or ``\\r``; a leading UTF-8 byte-order mark is not deck text; ``#``,
``!``, and a whitespace-led ``--`` start comments; rows are split on ASCII
whitespace (space, tab, CR, LF, FF, VT), and a NUL or non-ASCII whitespace
character outside a comment is rejected; table rows are read with Fortran
list-directed semantics, so text columns may be quoted while numeric columns
must be plain unquoted Fortran numbers.
"""

from __future__ import annotations

import bisect
import contextlib
import copy
import hashlib
import itertools
import json
import math
import os
import re
import sys
import tempfile
from collections.abc import Callable, Iterable, Iterator, Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path, PureWindowsPath
from types import MappingProxyType
from typing import Any

from cabledyn._paths import windows_device_component
from cabledyn.errors import DeckFormatError

_SECTION_ALIASES = {
    "LINE TYPES": "LINE TYPES",
    "LINETYPES": "LINE TYPES",
    "LINE DICTIONARY": "LINE TYPES",
    "BODIES": "BODIES",
    "BODY": "BODIES",
    "POINTS": "POINTS",
    "CONNECTION PROPERTIES": "POINTS",
    "POINT PROPERTIES": "POINTS",
    "CONNECTS": "POINTS",
    "LINES": "LINES",
    "LINE PROPERTIES": "LINES",
    "SECTIONS": "SECTIONS",
    "OPTIONS": "OPTIONS",
    "SOLVER OPTIONS": "OPTIONS",
    "OUTPUTS": "OUTPUTS",
    "OUTPUT": "OUTPUTS",
    "ROD TYPES": "ROD TYPES",
    "RODTYPES": "ROD TYPES",
    "ROD DICTIONARY": "ROD TYPES",
    "RODS": "RODS",
    "ROD LIST": "RODS",
    "ROD PROPERTIES": "RODS",
    "EQUIVALENT BUOYANCY": "EQUIVALENT BUOYANCY",
    "EQUIVALENT SECTIONS": "EQUIVALENT BUOYANCY",
    "BUOYANCY SECTIONS": "EQUIVALENT BUOYANCY",
    "FAILURE": "FAILURE",
    "FAILURES": "FAILURE",
    "CONTROL": "CONTROL",
    "CONTROLS": "CONTROL",
    "SYROPE IC": "SYROPE IC",
    "END CONNECTIONS": "END CONNECTIONS",
    "END CONNECTION": "END CONNECTIONS",
    "TURBINES": "TURBINES",
    "TURBINE": "TURBINES",
    "EXTERNAL LOADS": "EXTERNAL LOADS",
    "EXTERNAL LOAD": "EXTERNAL LOADS",
    "ATTACHMENTS": "ATTACHMENTS",
    "LINE ATTACHMENTS": "ATTACHMENTS",
    "CLUMPS": "ATTACHMENTS",
    "STIFFENERS": "STIFFENERS",
    "STIFFENER": "STIFFENERS",
    "BEND STIFFENERS": "STIFFENERS",
    "BEND STIFFENER": "STIFFENERS",
}
# Table sections whose rows the native reader takes through a Fortran
# list-directed READ. Their descriptive and units rows are recognized by the
# native rule "the row has no token that reads as a real number".
_LIST_DIRECTED_SECTIONS = frozenset(
    {
        "LINE TYPES",
        "BODIES",
        "ROD TYPES",
        "RODS",
        "POINTS",
        "LINES",
        "SECTIONS",
        "EQUIVALENT BUOYANCY",
        "END CONNECTIONS",
        "TURBINES",
        "EXTERNAL LOADS",
    }
)
# Table sections the native reader splits on whitespace and parses column by
# column (their comma-separated line lists are valid there).
_WHITESPACE_TABLE_SECTIONS = frozenset(
    {"FAILURE", "CONTROL", "SYROPE IC", "ATTACHMENTS", "STIFFENERS"}
)
_TABLE_SECTIONS = _LIST_DIRECTED_SECTIONS | _WHITESPACE_TABLE_SECTIONS
_NATIVE_RECORD_LENGTH = 512
_INT32_MAX = 2**31 - 1
# Largest dtM/TMax step count the native driver indexes (default INTEGER - 1).
_NATIVE_MAX_STEPS = 2**31 - 2
# The native token separators: space, tab, CR, LF, FF, VT (ASCII whitespace).
_WHITESPACE = " \t\r\n\f\v"
# ROD TYPES header names that mark columns 6-7 as the retired CableDyn axial
# coefficients (rejected) or as MoorDyn's end coefficients.
_LEGACY_ROD_AXIAL_NAMES = frozenset(
    {"cdax", "caax", "cd_ax", "ca_ax", "cdt", "cat", "cd_t", "ca_t"}
)
_ROD_END_NAMES = frozenset({"cdend", "caend", "cd_end", "ca_end"})
_TOKEN = re.compile(r"[^ \t\r\n\f\v]+")
_ASCII_UPPER = str.maketrans("abcdefghijklmnopqrstuvwxyz", "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
_UTF8_BOM = "﻿"
# Native numeric_token_shape: [sign] digits [. digits] (or [sign] . digits) with an optional
# exponent e/E/d/D [sign] digits. A list-directed READ would also take "1+2" as 1e2 and
# "10-5" as 1e-4; neither is a number to the native reader.
_FORTRAN_REAL = re.compile(r"([+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+))(?:[EeDd]([+-]?[0-9]+))?")
_NUMBER_CHARACTERS = frozenset("0123456789.+-eEdD")
# A table column is read by a list-directed READ, which also takes a q/Q exponent (a
# token outside the characters above, so list_safe_row leaves it to that READ).
_TABLE_REAL = re.compile(r"([+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+))(?:[EeDdQq]([+-]?[0-9]+))?")
_FORTRAN_SPECIAL_REAL = re.compile(r"[+-]?(?:inf|infinity|nan)", re.IGNORECASE)
_FORTRAN_INTEGER = re.compile(r"[+-]?[0-9]+")
_LIST_REPEAT = re.compile(r"[0-9]+\*")
_LIST_SEPARATORS = frozenset("/,;")
_FIELDS = {
    "line_type": ("name", "diam", "mass", "ea", "ba", "ei", "cdn", "cdt", "can", "cat"),
    "point": ("id", "type", "x", "y", "z", "mass", "vol", "cda", "ca"),
    "line": ("id", "nodea", "nodeb", "outputs"),
    "section": ("lineid", "linetype", "length", "numsegs"),
    "end_connection": (
        "lineid",
        "end",
        "stiffness",
        "ezx",
        "ezy",
        "ezz",
        "torsstiffness",
        "nxx",
        "nxy",
        "nxz",
        "pretwist",
    ),
}
_PATH_OPTIONS = {
    "bathymetryfile",
    "bathymetry_file",
    "seafloorfile",
    "seafloor_file",
    "motionfile",
    "vesselmotion",
    "vesselrao",
    "wavekin",
    "waterkin",
}
_PATH_OPTION_GROUP = {
    "bathymetryfile": "bathymetry",
    "bathymetry_file": "bathymetry",
    "seafloorfile": "bathymetry",
    "seafloor_file": "bathymetry",
    "motionfile": "motion",
    "vesselmotion": "vesselmotion",
    "vesselrao": "vesselrao",
    "wavekin": "waterkin",
    "waterkin": "waterkin",
}
_OPTION_ALIASES = {
    "g": "gravity",
    "gravity": "gravity",
    "rhow": "water_density",
    "wtrdnsty": "water_density",
    "water_density": "water_density",
    "wtrdpth": "water_depth",
    "water_depth": "water_depth",
    "bathymetryfile": "bathymetry",
    "bathymetry_file": "bathymetry",
    "seafloorfile": "bathymetry",
    "seafloor_file": "bathymetry",
    "kbot": "kbot",
    "kb": "kbot",
    "cbot": "cbot",
    "cb": "cbot",
    "dtm": "dtm",
    "dt": "dtm",
    "rhoinf": "rhoinf",
    "rho_inf": "rhoinf",
    "modified_newton": "modified_newton",
    "modifiednewton": "modified_newton",
    "adaptive_mesh": "adaptive_mesh",
    "adaptivemesh": "adaptive_mesh",
    "cable_load_feedback": "cable_load_feedback",
    "cableloadfeedback": "cable_load_feedback",
    "tensile_safety": "tensile_safety",
    "tensilesafety": "tensile_safety",
    "tensile_strain_tolerance": "tensile_strain_tolerance",
    "tensilestraintolerance": "tensile_strain_tolerance",
    "recovery_max_substeps": "recovery_max_substeps",
    "recoverymaxsubsteps": "recovery_max_substeps",
    "axial_quadrature_order": "axial_quadrature_order",
    "axialquadratureorder": "axial_quadrature_order",
    "axial_quadrature": "axial_quadrature_order",
    "bending_quadrature_order": "bending_quadrature_order",
    "bendingquadratureorder": "bending_quadrature_order",
    "bending_quadrature": "bending_quadrature_order",
    "frictionmu": "friction",
    "mu": "friction",
    "frictioncoefficient": "friction",
    "frictionmuaxial": "friction_axial",
    "frictionmu_axial": "friction_axial",
    "mu_axial": "friction_axial",
    "muaxial": "friction_axial",
    "frictionmulateral": "friction_lateral",
    "frictionmu_lateral": "friction_lateral",
    "mu_lateral": "friction_lateral",
    "mulateral": "friction_lateral",
    "frictionmunormal": "friction_lateral",
    "frictionmu_normal": "friction_lateral",
    "wave": "waves",
    "waves": "waves",
    "wavekin": "waterkin",
    "waterkin": "waterkin",
    "ramptime": "ramp_time",
    "ramp_time": "ramp_time",
    "tramp": "ramp_time",
    "maxstrain": "max_strain",
    "max_strain": "max_strain",
    "vivrmswindow": "viv_rms_window",
    "viv_rms_window": "viv_rms_window",
    "vivphaseseed": "viv_phase_seed",
    "viv_phase_seed": "viv_phase_seed",
    "rangestart": "range_start",
    "range_start": "range_start",
    "waveseed": "wave_seed",
    "wave_seed": "wave_seed",
    "wavespreading": "wave_spreading",
    "wave_spreading": "wave_spreading",
    "wavedirections": "wave_directions",
    "wave_directions": "wave_directions",
    "wavecomponents": "wave_components",
    "wave_components": "wave_components",
    "streamorder": "stream_order",
    "stream_order": "stream_order",
    "nmodes": "n_modes",
    "n_modes": "n_modes",
    "modes": "n_modes",
    "alpha_force_blend": "alpha_force_blend",
    "alphaforceblend": "alpha_force_blend",
    "ei0_substeps": "ei0_substeps",
    "ei0substeps": "ei0_substeps",
    "ei0_substep_angle": "ei0_substep_angle",
    "ei0substepangle": "ei0_substep_angle",
    "ei0_substep_max": "ei0_substep_max",
    "ei0substepmax": "ei0_substep_max",
    "cable_statics": "cable_statics",
    "cablestatics": "cable_statics",
    "staticsfriction": "statics_friction",
    "statics_friction": "statics_friction",
    "staticsseabedfrictionpolicy": "statics_friction",
    "seabedfrictionpolicy": "statics_friction",
    "layazimuth": "lay_azimuth",
    "lay_azimuth": "lay_azimuth",
    "aslaidtension": "as_laid_tension",
    "as_laid_tension": "as_laid_tension",
    "outputrecovery": "output_recovery",
    "output_recovery": "output_recovery",
    "axialdampingratio": "axial_damping_ratio",
    "axial_damping_ratio": "axial_damping_ratio",
}
# Per-line static friction rows (native apply_option): ``layAzimuth<ID>`` and ``asLaidTension<ID>``
# with the LINE id appended; the id is a plain decimal suffix, and leading zeros name the same line.
_LINE_OPTION_PATTERN = re.compile(r"(layazimuth|aslaidtension)([0-9]+)\Z")
_LINE_OPTION_FAMILIES = {"layazimuth": "lay_azimuth", "aslaidtension": "as_laid_tension"}
_STATICS_FRICTION_POLICIES = frozenset({"aslaid", "as_laid", "as-laid", "none"})
_SCALAR_OPTION_KEYWORDS = frozenset(_OPTION_ALIASES) | {
    "icmode",
    "bodyic",
    "bodyscheme",
    "bodysubstep",
    "dtwave",
    "wvhicoff",
    "waverefx",
    "waverefy",
    "bodywetting",
    "bodyhydro",
    "rodhydro",
    "tmax",
    "motionfile",
    "vesselmotion",
    "vesselrao",
    "vesselref",
    "current",
    "tscheme",
    "dtic",
    "tmaxic",
    "cdscaleic",
    "threshic",
    "writelog",
    "dtout",
    "currents",
    "inertialf",
    "inertialf_rampt",
}
# Native CD_DECK_NAMELEN: the longest OUTPUTS channel name the reader stores.
_NATIVE_NAME_LENGTH = 64
_STOCK_LINE_FIELDS = ("lineid", "linetype", "nodea", "nodeb", "length", "numsegs", "outputs")
_NATIVE_MAX_SEGMENTS = 1_000_000
# Native admissible magnitudes (CableDyn_DeckDriver section/line-type validation).
_NATIVE_MAX_SECTION_LENGTH = 1.0e6
_NATIVE_MIN_SEGMENT_LENGTH = 1.0e-6
_NATIVE_MAX_EA = 1.0e15
_NATIVE_MAX_ABS_MASS = 1.0e6
_NATIVE_MAX_DIAMETER = 1.0e3
# Native admissible input magnitudes (driver_format.md "Admissible input ranges").
_NATIVE_MAX_COORDINATE = 1.0e6
_NATIVE_MAX_COEFFICIENT = 1.0e15
_NATIVE_MAX_SMALL_COEFFICIENT = 1.0e3
# Relative band around the displaced water mass within which a line type is neutrally buoyant
# (the native NEUTRAL_BUOYANCY_REL_TOL).
_NATIVE_NEUTRAL_BUOYANCY_REL_TOL = 1.0e-6
_NATIVE_MIN_EA = 1.0e-3
_NATIVE_MIN_DIAMETER = 1.0e-6
_NATIVE_MAX_GRAVITY = 1.0e3
_NATIVE_MAX_WATER_DENSITY = 1.0e5
_NATIVE_MAX_FLUID_SPEED = 1.0e3
# native CD_MIN_TIME_STEP: the smallest dtM (the time integration divides by dtM^2)
_NATIVE_MIN_TIME_STEP = 1.0e-100
_NATIVE_MAX_WAVE_HEIGHT = 1.0e3
_NATIVE_WAVE_PERIOD_RANGE = (0.1, 1.0e5)
_DISABLED_MOTION_FILE_VALUES = frozenset({"0", "none"})
# Alternative prescribed-motion sources (native apply_option): only one may be active.
_MOTION_SOURCE_KEYWORDS = ("motionfile", "vesselmotion", "vesselrao")
# Native STATIC_CHECK_HINT: appended to the errors that ask a standalone deck without TMax for
# the march (those naming one of the cues).
_STATIC_CHECK_HINT = "; to check a dynamic deck's static start only, give TMax = 0"
_STATIC_CHECK_CUES = ("dtM and TMax", "requires dtM", "require dtM", "dynamic deck (TMax)")
_END_CONNECTION_ENDS = {
    "a": "a",
    "enda": "a",
    "end_a": "a",
    "b": "b",
    "endb": "b",
    "end_b": "b",
}
_PINNED_END_CONNECTIONS = frozenset({"pinned", "free", "zero"})
# Host-driven (platform-borne) BODIES types, MoorDyn aliases included (native append_body)
_HOST_BODY_TYPES = frozenset({"coupled", "vessel", "cpld", "ves"})
# native apply_option: MoorDyn-F's inertialF other than 1
_INERTIAL_F_MESSAGE = (
    "CableDyn returns the inertia of coupled bodies and rods with their coupled loads, as "
    "MoorDyn-F's inertialF 1; inertialF 0 (MoorDyn-F's default: no inertia) and 2 (the inertia "
    "ramped in) are not supported: use 1 or remove the row"
)
# Bodies pinned to a host node (MoorDyn CoupledPinned/VesselPinned): coupled hosts only
_PINNED_BODY_TYPES = frozenset({"coupledpinned", "cpldpin", "vesselpinned", "vespin"})
_PINNED_BODY_HOST_MESSAGE = (
    "CoupledPinned/VesselPinned BODY requires a coupled host (OpenFAST CompMooring = 5); in a "
    "standalone deck use a Free body, or a Coupled body with a motionFile"
)
_RIGID6_DYNAMIC_MESSAGE = "Rigid6 BODY requires a dynamic deck with dtM and TMax"
_PINNED_BODY_VALUE_MESSAGE = (
    "CoupledPinned/VesselPinned BODY requires Ixx/Iyy/Izz > 0 and non-negative Mass/Vol/CdA/Ca"
)

# MoorDyn RODS attachment aliases (native append_rod)
_ROD_ATTACHMENT_ALIASES = {
    "anchor": "fixed",
    "fix": "fixed",
    "pin": "pinned",
    "point": "free",
    "con": "free",
    "ves": "vessel",
    "cpld": "coupled",
    "cpldpin": "coupledpinned",
    "vesselpinned": "coupledpinned",
    "vespin": "coupledpinned",
}
_RIGID_END_CONNECTIONS = frozenset({"rigid", "infinity", "inf"})
# TorsStiffness keywords of an end free to twist (a numeric 0 is free too)
_FREE_TORSION_KEYWORDS = frozenset({"free", "zero"})
# native CD_HTORS_MAX_TWIST: the largest imposed static twist, 1000 turns
_MAX_STATIC_TWIST_DEG = 360000.0
# Native TORS_NX_PARALLEL_TOL: smallest |Nx x Ez| of unit vectors (about 0.06 degrees off Ez).
_TORSION_NORMAL_PARALLEL_TOL = 1.0e-3
_WATERKIN_FILENAME_LETTERS = frozenset("abcdfghijklmnopqrstuvwxyzABCDFGHIJKLMNOPQRSTUVWXYZ")
# MoorDyn-C kinematics files the native reader opens by fixed name in the deck folder
# (read_moordyn_c_kinematics): WaveKin 3, WaveKin 7 and Currents 1, 2 and 5.
_MOORDYN_C_WAVE_FILES = {3: "wave_elevation.txt", 7: "wave_frequencies.txt"}
_MOORDYN_C_CURRENT_FILES = {
    1: "current_profile.txt",
    2: "current_profile_dynamic.txt",
    5: "current_profile_4d.txt",
}


def _moordyn_c_wave_kin(value: str | None) -> int:
    """Return the MoorDyn-C numeric WaveKin mode (3 or 7) a WaterKin value selects, else 0."""
    if value is None:
        return 0
    value = _strip_quotes(value)
    if value.lower() in {"none", "seastate"} or any(
        character in _WATERKIN_FILENAME_LETTERS for character in value
    ):
        return 0
    mode = round(_native_float(value))  # a validated WaterKin row reads as a finite number
    return mode if mode in _MOORDYN_C_WAVE_FILES else 0


def _moordyn_c_currents(value: str | None) -> int:
    """Return the MoorDyn-C ``Currents`` mode (0, 1, 2 or 5) of a validated row value."""
    if value is None:
        return 0
    mode = round(_native_float(value))
    return mode if mode in _MOORDYN_C_CURRENT_FILES else 0


def _comment_position(text: str) -> int | None:
    """Return where the native ``scan_comment`` rules start a comment, if anywhere."""
    positions = [position for marker in ("#", "!") if (position := text.find(marker)) >= 0]
    if "---" not in text:
        search_from = 0
        while (position := text.find("--", search_from)) >= 0:
            if position == 0 or text[position - 1] in _WHITESPACE:
                positions.append(position)
                break
            search_from = position + 2
    return min(positions) if positions else None


def _strip_inline_comment(text: str) -> str:
    """Return ``text`` without its native inline comment and trailing blanks."""
    position = _comment_position(text)
    return (text if position is None else text[:position]).rstrip(_WHITESPACE)


def _character_error(visible: str) -> str | None:
    """Mirror the native ``record_charset_status`` check of non-comment text.

    A NUL character, or a non-ASCII whitespace character such as a no-break
    space, is not a token separator; the native reader rejects both rather
    than let them hide inside a token.
    """
    if "\x00" in visible:
        return "contains a NUL character outside a comment; save the file as plain text"
    for character in visible:
        if not character.isascii() and character.isspace():
            return (
                f"contains the non-ASCII whitespace character U+{ord(character):04X} outside "
                "a comment; separate values with ASCII spaces or tabs"
            )
    return None


def _ascii_upper(text: str) -> str:
    """Upper-case ASCII letters only, as the native section-name matcher does."""
    return text.translate(_ASCII_UPPER)


def _split_records(text: str) -> tuple[list[str], list[str]]:
    """Split text into records and their terminators exactly like the native reader.

    Only ``\\r\\n``, ``\\n``, and ``\\r`` end a record; other Unicode line
    separators (form feed, U+2028, ...) are ordinary record content.
    """
    lines: list[str] = []
    endings: list[str] = []
    start = 0
    for match in re.finditer(r"\r\n|\n|\r", text):
        lines.append(text[start : match.start()])
        endings.append(match.group())
        start = match.end()
    if start < len(text):
        lines.append(text[start:])
        endings.append("")
    return lines, endings


def _row_tokens(text: str) -> list[str]:
    """Split a native row on the native token separators (ASCII whitespace)."""
    return re.findall(_TOKEN, text)


def _token_spans(text: str) -> list[tuple[int, int]]:
    return [match.span() for match in re.finditer(_TOKEN, text)]


def _quoted_token_spans(text: str) -> list[tuple[int, int]]:
    """Mirror the native ``token_bounds`` tokenizer used for table rows.

    Tokens are separated by ASCII whitespace, except that a token opening with
    a quote runs to the matching close quote (keeping any whitespace inside it)
    and then on to the next separator. An unterminated quote runs to the end
    of the row.
    """
    spans: list[tuple[int, int]] = []
    position, length = 0, len(text)
    while True:
        while position < length and text[position] in _WHITESPACE:
            position += 1
        if position >= length:
            return spans
        start = position
        if text[position] in "\"'":
            close = text.find(text[position], position + 1)
            position = length if close < 0 else close + 1
        while position < length and text[position] not in _WHITESPACE:
            position += 1
        spans.append((start, position))


def _quoted_row_tokens(text: str) -> list[str]:
    """Split a table row into the tokens the native list-directed reader sees."""
    return [text[start:stop] for start, stop in _quoted_token_spans(text)]


def _dequote(raw: str, where: str) -> tuple[str, bool]:
    """Return the list-directed value of one raw token and whether it was quoted."""
    if raw[0] not in "\"'":
        return raw, False
    quote = raw[0]
    if len(raw) < 3 or raw[-1] != quote or quote in raw[1:-1]:
        raise DeckFormatError(
            f"{where}: invalid quoting in token {raw}; a quoted value must be "
            "non-empty text inside one pair of matching quotes"
        )
    return raw[1:-1], True


def _strip_quotes(value: str) -> str:
    """Mirror the native ``strip_quotes`` used for path-valued options."""
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def _has_list_separator(raw: str) -> bool:
    """True when list-directed input would not take an unquoted token whole."""
    return (
        any(character in _LIST_SEPARATORS for character in raw)
        or _LIST_REPEAT.match(raw) is not None
    )


def _render(value: object, *, text: bool = False) -> str:
    """Render one value as a token the native reader takes back unchanged.

    ``text`` marks a list-directed character column: a value that holds a
    list-directed separator (``/``, ``,``, ``;``) or starts with a repeat count
    (``3*``) is quoted there. Values that no native reader can take back as a
    single token raise ``ValueError``.
    """
    if value is None:
        raise ValueError("deck values must not be None")
    if isinstance(value, bool):
        return "True" if value else "False"
    if isinstance(value, float):
        # the shortest text that reads back as the same double (0.1, not
        # 0.10000000000000001); a whole number keeps its integer spelling (510)
        shortest = repr(value)
        return shortest[:-2] if shortest.endswith(".0") else shortest
    if not isinstance(value, (int, str)):
        raise ValueError(
            f"deck values must be a number, Boolean, or string, not {type(value).__name__}"
        )
    rendered = str(value)
    if not rendered:
        raise ValueError("native deck tokens must not be empty")
    if any(character.isspace() for character in rendered):
        raise ValueError(f"native deck tokens cannot contain whitespace: {rendered!r}")
    if '"' in rendered or "'" in rendered:
        raise ValueError(f"native deck tokens cannot contain quotes: {rendered!r}")
    if "#" in rendered or "!" in rendered or rendered.startswith("--") or "---" in rendered:
        raise ValueError(f"native deck tokens cannot contain comment/header markers: {rendered!r}")
    if text and _has_list_separator(rendered):
        rendered = f'"{rendered}"'
    return rendered


def _is_csys_token(token: str) -> bool:
    """An EXTERNAL LOADS CSys entry: G, L, or MoorDyn-F's ``-`` (refused for a body)."""
    return len(token) == 1 and token in "GgLl-"


def _render_quoted_text(value: str) -> str:
    """Check text written inside double quotes, where spaces are allowed.

    The native reader keeps a quoted token whole, spaces included; a quote,
    a comment marker, or a line or tab character cannot be written there.
    """
    if not value:
        raise ValueError("native deck tokens must not be empty")
    if any(character in "\"'\t\r\n\f\v" for character in value):
        raise ValueError(f"a quoted deck value cannot contain quotes or line breaks: {value!r}")
    if _comment_position(value) is not None or "---" in value:
        raise ValueError(f"native deck tokens cannot contain comment/header markers: {value!r}")
    return value


def _reads_as_real(raw: str) -> bool:
    """Mirror the native ``numeric_token_shape``: the token is spelled as one number.

    This is the native header-row test: a row with no such token is a column
    name or units row.
    """
    return (
        _FORTRAN_REAL.fullmatch(raw) is not None or _FORTRAN_SPECIAL_REAL.fullmatch(raw) is not None
    )


def _has_numeric_token(tokens: list[str]) -> bool:
    return any(_reads_as_real(token) for token in tokens)


def _native_float(token: str) -> float:
    """Parse one plain Fortran real token.

    Accepts an optional sign, a mantissa with optional decimal point, and an
    optional exponent written with ``E``/``D``/``Q`` (either case) or as a bare
    signed exponent (``3.0+6``), plus ``Inf``/``Infinity``/``NaN``. Anything
    else, including ``_`` digit separators, raises ``ValueError``.
    """
    value = _fortran_real_value(token)
    if value is None:
        raise ValueError(f"{token!r} is not a Fortran real number")
    if _is_subnormal(value):
        raise ValueError(f"{token!r} is subnormal; write 0 or a normal number")
    return value


def _table_float(token: str) -> float:
    """Parse a number in a table column (list-directed READ: a q/Q exponent is allowed)."""
    match = _TABLE_REAL.fullmatch(token)
    if match is None:
        return _native_float(token)
    mantissa, exponent = match.groups()
    value = float(mantissa if exponent is None else f"{mantissa}e{exponent}")
    if _is_subnormal(value):
        raise ValueError(f"{token!r} is subnormal; write 0 or a normal number")
    return value


def _keyword_column_real(token: str) -> float | None:
    """Mirror the native ``parse_real_token`` on a keyword column (END CONNECTIONS stiffnesses).

    The value of a plain real (``E``/``D`` exponent, no ``Q``; quotes removed as the
    list-directed READ of a character column does), or ``None`` when the token is not a
    number or is NaN, infinite or subnormal.
    """
    value = _fortran_real_value(_strip_quotes(token))
    if value is None or not math.isfinite(value) or _is_subnormal(value):
        return None
    return value


def _fortran_real_value(token: str) -> float | None:
    """Return what a native list-directed ``READ (token, *) real`` gives, or ``None``."""
    match = _FORTRAN_REAL.fullmatch(token)
    if match is not None:
        mantissa, exponent = match.groups()
        return float(mantissa if exponent is None else f"{mantissa}e{exponent}")
    if _FORTRAN_SPECIAL_REAL.fullmatch(token) is not None:
        return float(token)
    return None


def _is_subnormal(value: float) -> bool:
    return math.isfinite(value) and value != 0.0 and abs(value) < sys.float_info.min


def _real_token_defect(token: str) -> str | None:
    """Mirror the native ``real_token_defect``: why a numeric token is inadmissible.

    A token that reads whole as a real number must be finite (not NaN, Inf, or a
    decimal beyond the double range) and not subnormal. Tokens that are not numbers
    at all (names, paths) return ``None``; their own readers judge them.
    """
    token = token.strip(_WHITESPACE)
    if not token or any(character in " \"'/,;*\t" for character in token):
        return None
    value = _fortran_real_value(token)
    if value is None:
        return None
    if not math.isfinite(value):
        return (
            f"value {token!r} is not a finite number (NaN, Inf and magnitudes beyond "
            "1.8e308 are not accepted)"
        )
    if _is_subnormal(value):
        return (
            f"value {token!r} is subnormal (a nonzero magnitude below 2.2e-308); "
            "write 0 or a normal number"
        )
    return None


def _check_section_magnitude(length: float, segments: int, where: str) -> None:
    """Mirror the native section magnitude gate (length and segment length)."""
    if length > _NATIVE_MAX_SECTION_LENGTH or length / segments < _NATIVE_MIN_SEGMENT_LENGTH:
        raise DeckFormatError(
            f"{where}: section Length must be at most 1e6 m with segments of at least 1e-6 m"
        )


def _native_int(token: str) -> int:
    """Parse one Fortran default-INTEGER token (sign and digits, 32-bit range)."""
    if _FORTRAN_INTEGER.fullmatch(token) is None:
        raise ValueError(f"{token!r} is not a Fortran integer")
    value = int(token)
    if not -_INT32_MAX - 1 <= value <= _INT32_MAX:
        raise ValueError(f"{token!r} does not fit a 32-bit Fortran integer")
    return value


def _native_id_suffix(text: str) -> int:
    """Mirror the native ``int_suffix``: all digits, positive, 32-bit; else 0."""
    if not text or not text.isascii() or not text.isdigit():
        return 0
    value = int(text)
    return value if value <= _INT32_MAX else 0


def _native_positive_int(text: str, first: int, last: int) -> int:
    """Mirror the native ``parse_positive_int`` on 1-based inclusive ``text[first:last]``."""
    if first > last or first < 1 or last > len(text):
        return 0
    return _native_id_suffix(text[first - 1 : last])


def _parse_line_node_channel(lowered: str) -> tuple[int, int, int, int]:
    """Mirror the native ``parse_line_node_channel``: (line, node, kind, component)."""
    last = len(lowered)
    if lowered.startswith("twist") and last > 5 and "n" not in lowered[5:]:
        # Twist<L>: the line's total twist (node 1)
        line_id = _native_positive_int(lowered, 6, last)
        return (line_id, 1, 11, 0) if line_id > 0 else (line_id, 0, 0, 0)
    for keyword, code in (
        ("torq", 9),
        ("twist", 10),
        ("ten", 3),
        ("curvx", 13),
        ("curvy", 14),
        ("curv", 5),
        ("bendmom", 6),
        ("stfmom", 12),
    ):
        if lowered.startswith(keyword):
            prefix = len(keyword)
            separator = lowered.find("n", prefix)
            if last <= prefix or separator < 0:
                return 0, 0, 0, 0
            line_id = _native_positive_int(lowered, prefix + 1, separator)
            node_id = _native_positive_int(lowered, separator + 2, last)
            return line_id, node_id, code if line_id > 0 and node_id > 0 else 0, 0
    # Otherwise an ``L<L>N<J>...`` channel (the caller dispatches only ``l``-led names).
    npos = lowered.find("n", 1) + 1  # 1-based index of the first 'n' after the 'l'
    if npos == 0:
        return 0, 0, 0, 0
    if last >= npos + 4 and lowered[last - 3 :] in {"dec", "azi"}:
        line_id = _native_positive_int(lowered, 2, npos - 1)
        node_id = _native_positive_int(lowered, npos + 1, last - 3)
        if line_id <= 0 or node_id <= 0:
            return line_id, node_id, 0, 0
        return line_id, node_id, 7 if lowered.endswith("dec") else 8, 0
    if not (last >= npos + 3 and lowered[last - 2] in "pva"):
        return 0, 0, 0, 0
    line_id = _native_positive_int(lowered, 2, npos - 1)
    node_id = _native_positive_int(lowered, npos + 1, last - 2)
    if line_id <= 0 or node_id <= 0:
        return line_id, node_id, 0, 0
    component = "xyz".find(lowered[-1]) + 1
    kind = {"p": 1, "v": 2, "a": 4}[lowered[last - 2]] if component else 0
    return line_id, node_id, kind, component


def _channel_identity_key(channel: str) -> str:
    """Mirror the native ``channel_identity_key`` used to reject duplicate OUTPUTS.

    Names compare case-insensitively and numeric ids by value; alias spellings
    of one quantity collapse (``Con<P>p?`` = ``Point<P>p?``, ``FairAngle`` =
    ``FairDecl``, ``AnchAngle`` = ``AnchDecl``).
    """
    lowered = channel.lower()
    if lowered.startswith(("fairten", "anchten")):
        line_id = _native_id_suffix(lowered[7:])
        return f"{lowered[:7]}:{line_id}" if line_id > 0 else lowered
    if lowered.startswith(("anchfz", "anchfh")):
        line_id = _native_id_suffix(lowered[6:])
        return f"{lowered[:6]}:{line_id}" if line_id > 0 else lowered
    if lowered.startswith(
        ("fairangle", "anchangle", "fairdecl", "anchdecl", "fairincl", "anchincl")
    ):
        width = 9 if lowered.startswith(("fairangle", "anchangle")) else 8
        line_id = _native_id_suffix(lowered[width:])
        if line_id <= 0:
            return lowered
        if lowered.startswith(("fairincl", "anchincl")):
            return f"{lowered[:8]}:{line_id}"
        return f"{lowered[:4]}decl:{line_id}"
    if lowered.startswith(("fairdefl", "anchdefl")):
        line_id = _native_id_suffix(lowered[8:])
        return f"{lowered[:8]}:{line_id}" if line_id > 0 else lowered
    if lowered.startswith("point") or (
        lowered.startswith("con") and lowered[3:4].isascii() and lowered[3:4].isdigit()
    ):
        start = 5 if lowered.startswith("point") else 3
        separator = lowered.rfind("p")
        point_id = _native_id_suffix(lowered[start:separator]) if separator > start else 0
        component = (
            "xyz".find(lowered[separator + 1]) + 1
            if point_id > 0 and separator + 2 == len(lowered)
            else 0
        )
        return f"point:{point_id}:{component}" if point_id > 0 and component > 0 else lowered
    touchdown = re.fullmatch(r"tdp([0-9]{1,9})(s|x|y|z|lay|exc|grd)", lowered)
    if touchdown is not None and int(touchdown.group(1)) > 0:
        component = ("s", "x", "y", "z", "lay", "exc", "grd").index(touchdown.group(2)) + 1
        return f"tdp:{int(touchdown.group(1))}:{component}"
    if lowered.startswith(("ten", "curv", "bendmom", "stfmom", "l", "torq", "twist")):
        line_id, node_id, kind, component = _parse_line_node_channel(lowered)
        if line_id > 0 and node_id > 0 and kind > 0:
            return f"node:{line_id}:{node_id}:{kind}:{component}"
    return lowered


def _row_key(token: str) -> str:
    """Return a table row's integer id as the validator keys it (``str(int)``)."""
    try:
        return str(_native_int(token))
    except ValueError:
        return token.lower()


def _channel_id(digits: str) -> str:
    """Return a channel's digit-string id by value (native ``int_suffix``; 0 = no id)."""
    return str(_native_id_suffix(digits))


def _end_b_holds_connection(point_type: str) -> bool:
    """Native finalize_checks: an End B that holds a connection or a torsion frame -- a Fixed point,
    or a Coupled/Vessel (Turbine<J>) point that drives it as a second moving end."""
    return point_type in {"fixed", "coupled", "vessel"} or _is_turbine_point_type(point_type)


def _end_b_holds_frame(point_type: str) -> bool:
    """Native end_b_holds_frame: an End B that can hold an END CONNECTION or a torsion frame -- as
    _end_b_holds_connection, or a body point or a rod end (a line between two objects on the
    multibody march, which checks the object)."""
    return (
        _end_b_holds_connection(point_type)
        or point_type.startswith("body")
        or _rod_point(point_type) is not None
    )


def _is_turbine_point_type(point_type: str) -> bool:
    """Mirror the native FAST.Farm ``Turbine<J>``/``T<J>`` vocabulary detection."""
    return point_type.startswith("turbine") or (
        len(point_type) >= 2
        and point_type[0] == "t"
        and point_type[1:].isascii()
        and point_type[1:].isdigit()
    )


def _turbine_id(point_type: str) -> int:
    return _native_id_suffix(point_type[7:] if point_type.startswith("turbine") else point_type[1:])


def _rod_point(point_type: str) -> tuple[int, str] | None:
    """Mirror the native ``parse_rod_point_type`` (``Rod<N>A``/``Rod<N>B``)."""
    match = re.fullmatch(r"rod([0-9]+)([ab])", point_type)
    if match is None:
        return None
    rod_id = _native_id_suffix(match.group(1))
    return (rod_id, match.group(2)) if rod_id >= 1 else None


def _rod_end_token(token: str) -> str | None:
    """Mirror the native ``parse_line_attachment`` rod ends (``R<N>A``, ``Rod<N>B``, ...)."""
    match = re.fullmatch(r"(?:rod|r)([0-9]+)([ab])", token.lower())
    if match is None or _native_id_suffix(match.group(1)) < 1:
        return None
    return f"rod{_native_id_suffix(match.group(1))}{match.group(2)}"


def _body_point_id(point_type: str) -> int:
    return _native_id_suffix(point_type[4:]) if point_type.startswith("body") else 0


def _selector_int(text: object, what: str) -> int:
    """Parse an integer selector argument; bad input is an API ``ValueError``."""
    if isinstance(text, bool):
        raise ValueError(f"{what} must be an integer, got {text!r}")
    if isinstance(text, int):
        return text
    if isinstance(text, str):
        try:
            return _native_int(text.strip())
        except ValueError:
            pass
    raise ValueError(f"{what} must be an integer, got {text!r}")


def _line_option(keyword: str) -> tuple[str, int] | None:
    """Return (family, line id) of a per-line static friction row, else ``None``.

    ``layAzimuth<ID>`` and ``asLaidTension<ID>`` (case-insensitive) set the lay azimuth and the
    as-laid tension of the LINE ``ID`` alone, over the global ``layAzimuth`` / ``asLaidTension``
    row; the family is ``lay_azimuth`` or ``as_laid_tension``.
    """
    match = _LINE_OPTION_PATTERN.match(keyword.lower())
    if match is None:
        return None
    return _LINE_OPTION_FAMILIES[match.group(1)], int(match.group(2))


def _is_scalar_option_keyword(keyword: str) -> bool:
    """Whether ``keyword`` (any case) is a two-token scalar OPTIONS keyword (per-line rows too)."""
    return keyword.lower() in _SCALAR_OPTION_KEYWORDS or _line_option(keyword) is not None


def _option_key(keyword: str) -> str:
    """Return the native identity of an option keyword (aliases collapse to one key)."""
    lowered = keyword.lower()
    if lowered in _WAVETRAIN_KEYWORDS:
        # native CD_Sea_Parse_Train takes both spellings of the one keyword
        return "wavetrain"
    line_option = _line_option(lowered)
    if line_option is not None:
        # layAzimuth7 and layAzimuth07 set the same line natively: the last row wins
        return f"{line_option[0]}:{line_option[1]}"
    return _OPTION_ALIASES.get(lowered, lowered)


def _end_connection_end(token: str) -> str:
    """Return canonical ``a``/``b`` for the native end-name aliases."""
    try:
        return _END_CONNECTION_ENDS[token.lower()]
    except KeyError as exc:
        raise ValueError("END CONNECTIONS End must be A or B") from exc


def _text_columns(section: str, width: int) -> frozenset[int]:
    """Zero-based columns the native list-directed READ takes as character data."""
    if section == "LINE TYPES":
        return frozenset({0, 3, 4})
    if section == "LINES":
        # LineType and Outputs; the attachments are point ids or rod ends, never quoted
        return frozenset({1, 6}) if width == 7 else frozenset({3})
    if section == "RODS":
        return frozenset({1, 2, 10})
    if section == "END CONNECTIONS":
        # End, Stiffness and the optional TorsStiffness keyword
        return frozenset({1, 2, 6}) if width >= 10 else frozenset({1, 2})
    if section in {"POINTS", "SECTIONS", "BODIES"}:
        return frozenset({1})
    if section in {"ROD TYPES", "EQUIVALENT BUOYANCY"}:
        return frozenset({0})
    return frozenset()


# Spectral wave rows (native CD_Sea_Parse_Train): the value count of the single-train
# ``waves`` form; a ``wavetrain`` row adds a trailing spreading exponent except for airy.
_SPECTRUM_VALUES = {
    "pm": 3,
    "issc": 3,
    "bretschneider": 3,
    "piersonmoskowitz": 3,
    "pierson-moskowitz": 3,
    "torsethaugen": 3,
    "ochihubble": 7,
    "ochi-hubble": 7,
    "ochi_hubble": 7,
}
_WAVETRAIN_VALUES = {
    **{mode: count + 1 for mode, count in _SPECTRUM_VALUES.items()},
    "jonswap": 5,
    "airy": 3,
}
_WAVETRAIN_KEYWORDS = frozenset({"wavetrain", "wave_train"})
# First tokens of the positional OPTIONS rows (native apply_option).
_POSITIONAL_ROW_STARTS = frozenset(
    {"airy", "jonswap", "stream", "dean", "uniform", "profile", "dynamic_solver"}
)
# Native JONSWAP gamma bound: the spectrum normalisation 1 - 0.287 ln(gamma) must stay positive.
_JONSWAP_GAMMA_LIMIT = math.exp(1.0 / 0.287)


def _is_positional_option(tokens: list[str]) -> bool:
    """Recognize only the positional forms accepted by ``apply_option``."""
    first = tokens[0].lower()
    last = tokens[-1].lower()
    return (
        (len(tokens) == 2 and first == "none" and last in {"wave", "waves", "current"})
        or (len(tokens) == 5 and first == "uniform" and last == "current")
        or (len(tokens) == 10 and first == "profile" and last == "current")
        or (len(tokens) == 5 and first in {"airy", "stream", "dean"} and last in {"wave", "waves"})
        or (len(tokens) == 6 and first == "jonswap" and last in {"wave", "waves"})
        or (
            last in {"wave", "waves"}
            and first in _SPECTRUM_VALUES
            and len(tokens) == _SPECTRUM_VALUES[first] + 2
        )
        or (
            last in _WAVETRAIN_KEYWORDS
            and first in _WAVETRAIN_VALUES
            and len(tokens) == _WAVETRAIN_VALUES[first] + 2
        )
    )


def _positional_numbers_are_finite(tokens: list[str]) -> bool:
    if len(tokens) == 2:
        return True
    try:
        return all(math.isfinite(_native_float(token)) for token in tokens[1:-1])
    except ValueError:
        return False


def _positional_range_error(tokens: list[str], *, effective: bool = True) -> str | None:
    """Return a native range error for a parsed positional option.

    The native reader checks some rules on every row as it reads it (positive wave
    height and period, distinct profile depths, every spectral and wavetrain row) and
    the magnitude bounds of a regular or JONSWAP ``waves`` row and of a ``current`` row
    only on the row in effect once OPTIONS is read: the last one. ``effective=False``
    returns the per-row rules alone, for a row a later row may override.
    """
    mode = tokens[0].lower()
    if mode == "profile":
        # The native two-point parser accepts either input direction and
        # normalizes it to ascending z.  Its finalizer only rejects coincident
        # (within roundoff) endpoints.
        if abs(_native_float(tokens[5]) - _native_float(tokens[1])) <= 100.0 * math.ulp(1.0):
            return "current profile depths must be strictly increasing"
        values = [_native_float(token) for token in tokens[1:9]]
        if effective and (
            abs(values[0]) > _NATIVE_MAX_COORDINATE
            or abs(values[4]) > _NATIVE_MAX_COORDINATE
            or any(abs(value) > _NATIVE_MAX_FLUID_SPEED for value in values[1:4] + values[5:8])
        ):
            return (
                "current profile depths must be at most 1e6 m and velocities at most 1e3 m/s "
                "in magnitude"
            )
    elif mode == "uniform":
        if effective and any(
            abs(_native_float(token)) > _NATIVE_MAX_FLUID_SPEED for token in tokens[1:4]
        ):
            return "OPTION current velocity components must be at most 1e3 m/s"
    elif (
        mode in {"airy", "jonswap", "stream", "dean"}
        and tokens[-1].lower() not in _WAVETRAIN_KEYWORDS
    ):
        height = _native_float(tokens[1])
        period = _native_float(tokens[2])
        gamma = _native_float(tokens[3]) if mode == "jonswap" else 1.0
        if height <= 0.0 or period <= 0.0 or gamma < 1.0:
            return "waves require positive height/period and JONSWAP gamma >= 1"
        if not effective:
            return None
        low, high = _NATIVE_WAVE_PERIOD_RANGE
        if height > _NATIVE_MAX_WAVE_HEIGHT or not low <= period <= high:
            return "waves need height <= 1e3 m and period in [0.1, 1e5] s"
        # The JONSWAP normalisation 1 - 0.287 ln(gamma) vanishes at gamma = e^(1/0.287)
        # (about 32.6), so every native JONSWAP path (the waves row synthesis and a
        # spread one-train sea alike) rejects a larger gamma.
        if mode == "jonswap" and not gamma < _JONSWAP_GAMMA_LIMIT:
            return "JONSWAP gamma must be in [1, 32.6)"
    elif mode in _WAVETRAIN_VALUES:
        # native CD_Sea_Validate_Train
        values = [_native_float(token) for token in tokens[1:-1]]
        if values[0] <= 0.0 or values[1] <= 0.0:
            return "waves require positive height/period"
        low, high = _NATIVE_WAVE_PERIOD_RANGE
        direction = (
            values[3] if mode == "jonswap" else values[6] if mode.startswith("ochi") else values[2]
        )
        if (
            values[0] > _NATIVE_MAX_WAVE_HEIGHT
            or not low <= values[1] <= high
            or abs(direction) > _NATIVE_MAX_COORDINATE
        ):
            return (
                "a wave train needs height <= 1e3 m, period in [0.1, 1e5] s and |direction| <= 1e6"
            )
        spread = values[-1] if tokens[-1].lower() in _WAVETRAIN_KEYWORDS and mode != "airy" else 0.0
        if not 0.0 <= spread <= 1000.0:
            return "wave spreading exponent must be in [0, 1000]"
        if mode == "jonswap" and not 1.0 <= values[2] < _JONSWAP_GAMMA_LIMIT:
            return "JONSWAP gamma must be in [1, 32.6)"
        if mode.startswith("ochi"):
            hs2, tp2, lam1, lam2 = values[3], values[4], values[2], values[5]
            if hs2 < 0.0 or tp2 <= 0.0 or not (0.0 < lam1 <= 50.0 and 0.0 < lam2 <= 50.0):
                return "Ochi-Hubble needs Hs2 >= 0, Tp2 > 0 and lambda in (0, 50]"
            if hs2 > _NATIVE_MAX_WAVE_HEIGHT or not low <= tp2 <= high:
                return "Ochi-Hubble needs Hs2 <= 1e3 m and Tp2 in [0.1, 1e5] s"
    return None


def _body_outside_admissible_range(
    coordinates: list[float], loads: list[float], added_mass: float
) -> bool:
    """Mirror the native BODY magnitude gate (coordinates and angles, loads, Ca)."""
    return (
        any(abs(value) > _NATIVE_MAX_COORDINATE for value in coordinates)
        or any(abs(value) > _NATIVE_MAX_COEFFICIENT for value in loads)
        or abs(added_mass) > _NATIVE_MAX_SMALL_COEFFICIENT
    )


_BODY_RANGE_MESSAGE = (
    "BODY data outside the admissible range (coordinates and angles <= 1e6, "
    "Mass/Vol/stiffness/CdA/inertia <= 1e15, Ca <= 1e3 in magnitude)"
)


def _raise_option_defect(where: str, tokens: list[str]) -> None:
    """Mirror the native ``apply_option`` number gate.

    Every number on an OPTIONS row must be finite and not subnormal: token 1 of a
    scalar ``value keyword`` row, and every token of a positional
    ``dynamic_solver``/current/waves/wavetrain row. A quoted value is read dequoted.
    """
    last = tokens[-1].lower()
    positional = len(tokens) >= 3 and (
        tokens[0].lower() == "dynamic_solver"
        or last in {"current", "waves", "wave", "wavetrain", "wave_train"}
    )
    for token in tokens if positional else tokens[:1]:
        defect = _real_token_defect(_strip_quotes(token))
        if defect is not None:
            raise DeckFormatError(f"{where}: OPTIONS {defect}")


def _dynamic_solver_values_are_valid(values: list[str] | tuple[str, ...]) -> bool:
    if len(values) not in {4, 5}:
        return False
    try:
        rel_tol = _native_float(values[0])
        abs_tol = _native_float(values[1])
        max_iter = _native_int(values[2])
        backtracks = _native_int(values[3])
        if not (
            math.isfinite(rel_tol)
            and rel_tol > 0.0
            and math.isfinite(abs_tol)
            and abs_tol > 0.0
            and max_iter >= 1
            and backtracks >= 0
        ):
            return False
        if len(values) == 5:
            rho_inf = _native_float(values[4])
            if not math.isfinite(rho_inf) or not 0.0 <= rho_inf <= 1.0:
                return False
    except ValueError:
        return False
    return True


def _scalar_option_value_error(keyword: str, value: str) -> str | None:
    """Return why a two-token scalar row violates ``apply_option`` semantics."""
    raw = keyword.lower()
    key = _option_key(raw).partition(":")[0]  # a per-line row takes its family's rules
    defect = _real_token_defect(value)
    if defect is not None and "subnormal" in defect:
        return defect
    if raw in _PATH_OPTIONS:
        # The native reader dequotes path-valued options (and the WaterKin
        # selector) before interpreting them; every other value is used raw.
        value = _strip_quotes(value)
        if not value:
            return "requires a non-empty path"
    boolean_values = {"true", "t", "yes", "y", "on", "1", "false", "f", "no", "n", "off", "0"}
    if raw == "wvhicoff" and value.lower() == "none":
        # native rule: 'none' keeps every component of an elevation record
        return None
    # native check_option_row_value rule 'positive' (dtWave is the WaveKin 3 resampling step,
    # WvHiCOff the high cut-off frequency of an elevation record)
    positive = key in {"gravity", "water_density", "water_depth", "dtm"} or raw in {
        "dtwave",
        "wvhicoff",
    }
    if positive:
        lower, upper = 0.0, None
    elif key in {"kbot", "cbot"}:
        lower, upper = None, None
    elif key in {
        "tmax",
        "friction",
        "friction_axial",
        "friction_lateral",
        "as_laid_tension",
        "tensile_strain_tolerance",
        "ramp_time",
        "max_strain",
        "range_start",
        "viv_rms_window",
    }:
        if key == "friction" and value.lower() == "none":
            return None
        lower, upper = 0.0, None
    elif key == "rhoinf":
        lower, upper = 0.0, 1.0
    elif raw in {
        "dtic",
        "tmaxic",
        "cdscaleic",
        "threshic",
        "writelog",
        "dtout",
        "inertialf",
        "inertialf_rampt",
    }:
        lower, upper = None, None
    else:
        lower = upper = None

    if key in {
        "gravity",
        "water_density",
        "water_depth",
        "kbot",
        "dtm",
        "cbot",
        "tmax",
        "friction",
        "friction_axial",
        "friction_lateral",
        "lay_azimuth",
        "as_laid_tension",
        "rhoinf",
        "tensile_strain_tolerance",
        "ramp_time",
        "max_strain",
        "range_start",
        "viv_rms_window",
    } or raw in {
        "dtic",
        "tmaxic",
        "cdscaleic",
        "threshic",
        "writelog",
        "dtout",
        "dtwave",
        "wvhicoff",
        "waverefx",
        "waverefy",
        "inertialf",
        "inertialf_rampt",
    }:
        try:
            numeric = _native_float(value)
        except ValueError:
            return "must be numeric"
        if not math.isfinite(numeric):
            return "must be finite"
        if positive and numeric <= 0.0:
            return "must be positive"
        # native check_option_row_value rule 'time step'
        if key == "dtm" and numeric < _NATIVE_MIN_TIME_STEP:
            return "must be at least 1e-100 s: the time integration divides by its square"
        if lower is not None and numeric < lower:
            return f"must be >= {lower:g}"
        if upper is not None and numeric > upper:
            return f"must be <= {upper:g}"
        return None
    if key in {"modified_newton", "adaptive_mesh", "cable_load_feedback", "alpha_force_blend"}:
        return None if value.lower() in boolean_values else "must be a native boolean"
    if key == "tensile_safety":
        allowed = boolean_values | {"warn", "warning", "monitor", "error"}
        return None if value.lower() in allowed else "must be False, warn, or True"
    if key == "recovery_max_substeps":
        try:
            numeric = _native_float(value)
        except ValueError:
            return "must be an integer in [4, 65536]"
        if not math.isfinite(numeric):
            return "must be an integer in [4, 65536]"
        nearest = round(numeric)
        integer_tolerance = 16.0 * math.ulp(1.0) * max(1.0, abs(numeric))
        if abs(numeric - nearest) > integer_tolerance or not 4 <= nearest <= 65536:
            return "must be an integer in [4, 65536]"
        return None
    if key == "wave_spreading":
        try:
            numeric = _native_float(value)
        except ValueError:
            return "must be numeric"
        return (
            None if math.isfinite(numeric) and 0.0 <= numeric <= 1000.0 else "must be in [0, 1000]"
        )
    if key == "stream_order":
        try:
            numeric = _native_float(value)
        except ValueError:
            return "must be 0 (default) or an integer in [2, 60]"
        if not math.isfinite(numeric) or abs(numeric - round(numeric)) > 16.0 * math.ulp(1.0) * max(
            1.0, abs(numeric)
        ):
            return "must be 0 (default) or an integer in [2, 60]"
        return (
            None
            if round(numeric) == 0 or 2 <= round(numeric) <= 60
            else "must be 0 (default) or an integer in [2, 60]"
        )
    if key == "n_modes":
        try:
            numeric = _native_float(value)
        except ValueError:
            return "must be an integer in [0, 1000]"
        tolerance = 16.0 * math.ulp(1.0) * max(1.0, abs(numeric)) if math.isfinite(numeric) else 0.0
        if not math.isfinite(numeric) or abs(numeric - round(numeric)) > tolerance:
            return "must be an integer in [0, 1000]"
        return None if 0 <= round(numeric) <= 1000 else "must be an integer in [0, 1000]"
    if key in {"wave_components", "wave_directions"}:
        lowest = 2 if key == "wave_components" else 1
        try:
            numeric = _native_float(value)
        except ValueError:
            return f"must be an integer in [{lowest}, 100000]"
        if not math.isfinite(numeric):
            return f"must be an integer in [{lowest}, 100000]"
        integer_tolerance = 16.0 * math.ulp(1.0) * max(1.0, abs(numeric))
        if (
            abs(numeric - round(numeric)) > integer_tolerance
            or not lowest <= round(numeric) <= 100000
        ):
            return f"must be an integer in [{lowest}, 100000]"
        return None
    if key == "wave_seed":
        try:
            numeric = _native_float(value)
        except ValueError:
            return "must be an integer in [1, 2147483646]"
        if not (math.isfinite(numeric) and 1.0 <= numeric <= 2147483646.0):
            return "must be an integer in [1, 2147483646]"
        integer_tolerance = 16.0 * math.ulp(1.0) * max(1.0, abs(numeric))
        if abs(numeric - round(numeric)) > integer_tolerance:
            return "must be an integer"
        return None
    if key == "statics_friction":
        # native: the policy is dequoted and compared case-insensitively
        return (
            None
            if _strip_quotes(value).lower() in _STATICS_FRICTION_POLICIES
            else "must be asLaid or none"
        )
    if key == "viv_phase_seed":
        return None if value.lower() in {"spread", "zero"} else "must be spread or zero"
    if key == "cable_statics":
        return (
            None
            if value.lower() in {"continuation", "sequenced"}
            else "must be continuation or sequenced"
        )
    if key == "axial_damping_ratio":
        # native: the value is dequoted and compared case-insensitively
        return (
            None
            if _strip_quotes(value).lower() in {"segment", "mode1"}
            else "must be segment or mode1"
        )
    if key == "output_recovery":
        return (
            None
            if value.lower() in {"equilibrium", "element"}
            else "must be equilibrium or element"
        )
    if key == "ei0_substeps":
        return None if value.lower() in {"auto", "off"} else "must be auto or off"
    if key == "ei0_substep_angle":
        try:
            numeric = _native_float(value)
        except ValueError:
            return "must lie in (0, 90] deg"
        return (
            None if math.isfinite(numeric) and 0.0 < numeric <= 90.0 else "must lie in (0, 90] deg"
        )
    if key == "ei0_substep_max":
        try:
            numeric = _native_float(value)
        except ValueError:
            return "must be an integer in [2, 1024]"
        if not math.isfinite(numeric):
            return "must be an integer in [2, 1024]"
        nearest = round(numeric)
        integer_tolerance = 16.0 * math.ulp(1.0) * max(1.0, abs(numeric))
        if abs(numeric - nearest) > integer_tolerance or not 2 <= nearest <= 1024:
            return "must be an integer in [2, 1024]"
        return None
    if key in {"axial_quadrature_order", "bending_quadrature_order"}:
        try:
            numeric = _native_float(value)
        except ValueError:
            return "must be an integer in [1, 6]"
        if not math.isfinite(numeric):
            return "must be an integer in [1, 6]"
        nearest = round(numeric)
        integer_tolerance = 16.0 * math.ulp(1.0) * max(1.0, abs(numeric))
        if abs(numeric - nearest) > integer_tolerance or not 1 <= nearest <= 6:
            return "must be an integer in [1, 6]"
        return None
    if raw == "icmode":
        return (
            "is not an option: CableDyn always solves the static equilibrium directly; "
            "delete the ICmode row"
        )
    if raw == "bodyic":
        return None if value.lower() in {"static", "deck"} else "must be static or deck"
    if raw == "bodyscheme":
        return (
            None
            if value.lower() in {"monolithic", "staggered"}
            else "must be monolithic or staggered"
        )
    if raw == "bodysubstep":
        return None if value.lower() in {"none", "accuracy"} else "must be none or accuracy"
    if raw == "bodywetting":
        return None if value.lower() in {"sphere", "moordyn"} else "must be sphere or moordyn"
    if raw == "rodhydro":
        return None if value.lower() in {"exact", "moordyn"} else "must be exact or moordyn"
    if raw == "bodyhydro":
        return None if value.lower() in {"morison", "moordyn"} else "must be morison or moordyn"
    if raw in {"current", "wave", "waves"}:
        return None if value.lower() == "none" else "requires a supported positional mode"
    if raw == "vesselref":
        parts = value.split("|")
        if len(parts) != 3:
            return "must be x|y|z (the vessel reference point, m)"
        for part in parts:
            try:
                numeric = _native_float(part)
            except ValueError:
                return "must be x|y|z (the vessel reference point, m)"
            if not math.isfinite(numeric):
                return "must be finite"
        return None
    if raw == "currents":
        try:
            numeric = _native_float(value)
        except ValueError:
            return "must be numeric"
        # native apply_option: 0 none and the MoorDyn-C current files 1, 2 and 5; 3 and 4
        # (MoorDyn-C's node approaches) have no current source in MoorDyn-C v2.7.1
        if not math.isfinite(numeric) or abs(numeric - round(numeric)) > 1.0e-9:
            return "supports only mode 0, 1, 2 or 5"
        if round(numeric) in {3, 4}:
            return f"{round(numeric)} has no current source in MoorDyn-C v2.7.1; use 1, 2 or 5"
        return None if round(numeric) in {0, 1, 2, 5} else "supports only mode 0, 1, 2 or 5"
    if key == "waterkin":
        lowered = value.lower()
        if lowered in {"none", "seastate"} or any(
            character in _WATERKIN_FILENAME_LETTERS for character in value
        ):
            return None
        try:
            numeric = _native_float(value)
        except ValueError:
            return "requires 0/none, SEASTATE, or a filename"
        if (
            math.isfinite(numeric)
            and abs(numeric - round(numeric)) < 1.0e-9
            and round(numeric) in {0, 3, 7}
        ):
            return None
        return "supports only numeric mode 0, 3 or 7"
    # Path-valued options and the ignored stock tScheme selector accept any
    # non-empty native token; tokenization has already enforced that contract.
    return None


# --------------------------------------------------------------------------- ancillary files
# The native readers of the files a deck names, as far as they refuse a deck. Each function
# follows the subroutine it names in src/CableDyn_DeckDriver.f90 (or the module given) and raises
# _AncillaryError with the native message; DeckFile adds the deck's label.

_NATIVE_RECORD_LENGTH = 512  # DECK_RECLEN: the longest non-comment record of next_record
_NATIVE_TABLE_ROW_LENGTH = 65536  # LONG_ROW of read_moordyn_c_kinematics
_NATIVE_EPSILON = sys.float_info.epsilon
_NUMERIC_SHAPE = re.compile(
    r"[+-]?(?:(?i:inf|infinity|nan)|(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eEdD][+-]?[0-9]+)?)"
)
_MAX_GRID_STEPS = float(2**31 - 2)
_MAX_MOTION_SPEED = 1.0e4
_MAX_MOTION_ACCEL = 1.0e6
_MAX_FLUID_SPEED = 1.0e3
_MAX_WAVE_SAMPLES = 1.0e6
_MAX_CURRENT_SAMPLES = 2000000
_SYROPE_CURVE_SAMPLES = 30  # CD_SYROPE_NWC
_SYROPE_SCAN_SAMPLES = 200  # CD_SYROPE_NSCAN
_BATHY_CREASE_FRACTION = 0.05
_BATHY_CREASE_MIN_HEIGHT = 1.0e-6
_SEA_DEFAULT_DIRECTIONS = 9
_SPREADING_QUADRATURE = 128
_STATIC_CHECK_DT = 1.0  # the nominal dtM of a standalone TMax = 0 without one (parse_deck)


class _AncillaryError(ValueError):
    """A refusal of a native ancillary-file reader."""


def _token_real(token: str) -> float | None:
    """Mirror the native ``parse_real_token``: the finite, normal real of a whole token."""
    if _NUMERIC_SHAPE.fullmatch(token) is None:
        return None
    try:
        value = float(re.sub("[dD]", "e", token))
    except ValueError:
        return None
    if not math.isfinite(value) or _is_subnormal(value):
        return None
    return value


def _real_row(tokens: list[str], count: int) -> tuple[int, list[float]]:
    """Mirror the native ``parse_real_row``: status 0, 1 (no number) or 2 (malformed), values."""
    if not tokens or _NUMERIC_SHAPE.fullmatch(tokens[0]) is None:
        return 1, []
    values: list[float] = []
    for token in tokens[:count]:
        value = _token_real(token)
        if value is None:
            return 2, []
        values.append(value)
    return (0, values) if len(values) == count else (2, [])


def _data_rows(records: list[str], what: str) -> Iterator[tuple[int, list[str]]]:
    """Mirror the native ``next_record``: non-blank rows without comments, by file line."""
    for number, raw in enumerate(records, start=1):
        visible = _strip_inline_comment(raw)
        if not visible.strip(_WHITESPACE):
            continue
        defect = _character_error(visible)
        if defect is not None:
            raise _AncillaryError(f"{what} line {number} {defect}")
        if len(visible) > _NATIVE_RECORD_LENGTH:
            raise _AncillaryError(f"{what} line {number} is longer than the record limit")
        yield number, visible.split()


def _increasing(values: Sequence[float]) -> bool:
    return all(later > earlier for earlier, later in itertools.pairwise(values))


def _padded_fft_size(wanted: int) -> int:
    """Mirror ``padded_fft_size``: twice the next 7-smooth half length."""
    half = max((wanted + 1) // 2, 1)
    while True:
        rest = half
        for prime in (2, 3, 5, 7):
            while rest % prime == 0:
                rest //= prime
        if rest == 1:
            return 2 * half
        half += 1


def _check_elevation_record(
    records: list[str], dt_wave: float, window: float, cutoff: float, depth: float | None
) -> None:
    """Mirror ``read_wave_elevation_components`` and the component bounds of validation."""
    import numpy as np

    times: list[float] = []
    heights: list[float] = []
    for raw in records:
        tokens = raw.split()
        if not tokens:
            continue
        status, values = _real_row(tokens, 2)
        if status == 2:
            raise _AncillaryError(f'WaterKin WaveKinFile row "{raw}" is not "time elevation"')
        if status != 0:
            if times:
                raise _AncillaryError("WaterKin WaveKinFile contains a non-data row in its history")
            continue
        times.append(values[0])
        heights.append(values[1])
    if len(times) < 4:
        raise _AncillaryError("WaterKin WaveKinFile needs at least four `time elevation` rows")
    tolerance = 1000.0 * _NATIVE_EPSILON * max(1.0, abs(times[-1]))
    if abs(times[0]) > tolerance:
        raise _AncillaryError("WaterKin WaveKinFile time history must start at t = 0")
    if not _increasing(times):
        raise _AncillaryError("WaterKin WaveKinFile times must be strictly increasing")
    span = window if window > 0.0 else times[-1]
    if not span / dt_wave <= _MAX_WAVE_SAMPLES:
        raise _AncillaryError("WaterKin TMax/dtWave needs more than 1000000 wave samples")
    wanted = math.ceil(span / dt_wave)
    samples = _padded_fft_size(wanted)
    series = np.zeros(samples)
    series[:wanted] = np.interp(np.arange(wanted) * dt_wave, times, heights, right=0.0)
    kept = samples // 2
    if cutoff >= 0.0:
        step = 2.0 * math.pi / (samples * dt_wave)
        kept = min(kept, math.floor(cutoff / step * (1.0 + 1.0e-15)))
    if kept < 1:
        raise _AncillaryError("WvHiCOff keeps no component of the WaterKin WaveKinFile record")
    mean = float(series.sum() / samples)
    amplitudes = np.abs(np.fft.rfft(series - mean))[1 : kept + 1] * (2.0 / samples)
    if samples % 2 == 0 and kept == samples // 2:
        amplitudes[-1] *= 0.5
    top = 2.0 * math.pi * kept / (samples * dt_wave)
    if float(amplitudes.max()) > 1.0e3 or top > 1.0e4:
        raise _AncillaryError(
            "the wave components (WaterKin WaveKinMod 1 or WaveKin 3/7) need amplitudes of at "
            "most 1e3 m and frequencies of at most 1e4 rad/s"
        )
    if depth is not None and depth + mean <= 0.0:
        raise _AncillaryError("WaterKin mean elevation leaves a non-positive effective depth")


def _check_waterkin_current(records: list[str]) -> None:
    """Mirror the CurrentMod 1 table of ``read_waterkin_records`` (records after CurrentMod)."""
    if len(records) < 2:
        raise _AncillaryError("WaterKin file ended inside the current-table header")
    malformed = "malformed WaterKin current row (expected z ux uy as plain numbers)"
    rows: list[list[float]] = []
    start = 2
    for offset in range(4):
        if start + offset >= len(records):
            break
        status, values = _real_row(records[start + offset].split(), 3)
        if status == 2:
            raise _AncillaryError(malformed)
        if status == 0:
            rows.append(values)
            start += offset + 1
            break
    if not rows:
        raise _AncillaryError("could not find the WaterKin current profile table")
    for record in records[start:]:
        status, values = _real_row(record.split(), 3)
        if status == 2:
            raise _AncillaryError(malformed)
        if status != 0:
            break
        rows.append(values)
    if len(rows) < 2:
        raise _AncillaryError("WaterKin CurrentMod 1 needs at least two `z ux uy` depth rows")
    depths = [row[0] for row in rows]
    if any(value > 0.0 for value in depths):
        if not all(value >= 0.0 for value in depths):
            raise _AncillaryError("WaterKin current depth column mixes signs")
        depths = [-value for value in depths]
    if depths[0] > depths[-1]:
        depths.reverse()
    if any(b - a <= 100.0 * _NATIVE_EPSILON for a, b in itertools.pairwise(depths)):
        raise _AncillaryError("WaterKin current depths must be strictly monotonic")
    _check_current_bounds(depths, [value for row in rows for value in row[1:]])


def _check_current_bounds(depths: Sequence[float], velocities: Iterable[float]) -> None:
    if any(abs(value) > _NATIVE_MAX_COORDINATE for value in depths) or any(
        abs(value) > _MAX_FLUID_SPEED for value in velocities
    ):
        raise _AncillaryError(
            "current profile depths must be at most 1e6 m and velocities at most 1e3 m/s in "
            "magnitude"
        )


def _wave_frequency_rows(records: list[str], label: str) -> list[list[float]]:
    """Mirror ``read_table``: rows `omega Re Im beta`, the direction zero when left out."""
    rows: list[list[float]] = []
    for number, record in enumerate(records, start=1):
        tokens = record.split()
        if not tokens:
            continue
        status, values = _real_row(tokens, 4)
        if status != 0:
            status, values = _real_row(tokens, 3)
            values.append(0.0)
        if status != 0:
            raise DeckFormatError(f"{label} line {number}: row is not 3 to 4 plain numbers")
        rows.append(values)
    return rows


def _table_tokens(record: str) -> list[str]:
    """Mirror ``row_tokens``: the tokens up to the first one holding a ``#``."""
    tokens: list[str] = []
    for token in record.split():
        if "#" in token:
            break
        tokens.append(token)
    return tokens


def _table_number(token: str, name: str, number: int) -> float:
    value = _token_real(token)
    if value is None:
        raise _AncillaryError(f'{name} line {number}: value "{token}" is not a plain finite number')
    return value


def _check_current_profile(records: list[str], name: str) -> None:
    """Mirror ``Currents 1``: `z ux uy uz` rows after their header rows."""
    rows: list[list[float]] = []
    for number, raw in enumerate(records, start=1):
        tokens = raw.split()
        if not tokens:
            continue
        status, values = _real_row(tokens, 4)
        if status != 0:
            status, values = _real_row(tokens, 3)
        if status == 1 and not rows:
            continue
        if status != 0:
            raise _AncillaryError(f"{name} line {number}: row is not 3 to 4 plain numbers")
        rows.append(values)
    if not rows:
        raise _AncillaryError(f"Currents 1: {name} has no `z ux uy uz` rows")
    depths = [row[0] for row in rows]
    if not _increasing(depths):
        raise _AncillaryError(f"Currents 1: {name} depths must be strictly increasing")
    if any(b - a <= 100.0 * _NATIVE_EPSILON for a, b in itertools.pairwise(depths)):
        raise _AncillaryError("current profile depths must be strictly increasing")
    _check_current_bounds(depths, [value for row in rows for value in row[1:]])


def _check_current_resample(
    times: list[float], spatial: int, velocities: Any, coordinates: Iterable[float]
) -> None:
    """Mirror ``CD_Current_Grid_Resample`` and the grid bounds; velocities is (nt, points)."""
    import numpy as np

    step = min(b - a for a, b in itertools.pairwise(times))
    if times[-1] < 0.0:
        raise _AncillaryError("current grid: the last time must not be negative")
    if not times[-1] / _MAX_CURRENT_SAMPLES < step:
        raise _AncillaryError(
            "current grid: the last time over the smallest time interval exceeds the sample limit"
        )
    samples = math.floor(times[-1] / step) + 1
    if samples * spatial > _MAX_CURRENT_SAMPLES:
        raise _AncillaryError("current grid: more than 2e6 resampled space-time samples")
    at = np.arange(samples) * step
    upper = np.clip(np.searchsorted(times, at, side="right"), 1, len(times) - 1)
    lower = upper - 1
    knots = np.asarray(times)
    weight = np.clip((at - knots[lower]) / (knots[upper] - knots[lower]), 0.0, 1.0)[:, None]
    resampled = (1.0 - weight) * velocities[lower] + weight * velocities[upper]
    if any(abs(value) > _NATIVE_MAX_COORDINATE for value in coordinates) or (
        float(np.abs(resampled).max()) > _MAX_FLUID_SPEED
    ):
        raise _AncillaryError(
            "current grid coordinates must be at most 1e6 m and velocities at most 1e3 m/s in "
            "magnitude"
        )


def _check_dynamic_current(records: list[str], name: str) -> None:
    """Mirror ``read_dynamic_profile`` (Currents 2)."""
    import numpy as np

    depths: list[float] = []
    times: list[float] = []
    rows: list[list[float]] = []
    for number, raw in enumerate(records, start=1):
        if len(raw) > _NATIVE_TABLE_ROW_LENGTH:
            raise _AncillaryError(f"{name} line {number}: row is too long")
        if number <= 4 or number == 6:
            continue
        tokens = _table_tokens(raw)
        if number == 5:
            if not tokens:
                raise _AncillaryError(f"Currents 2: line 5 of {name} must list the depths")
            for token in tokens:
                depth = float(np.float32(_table_number(token, name, number)))
                if not math.isfinite(depth):
                    raise _AncillaryError(f"{name} depth is not a single-precision number")
                depths.append(depth)
            continue
        if not tokens:
            continue
        count = len(depths)
        if len(tokens) not in (1 + count, 1 + 2 * count, 1 + 3 * count):
            raise _AncillaryError(f"Currents 2: {name} line {number}: wrong number of values")
        values = [_table_number(token, name, number) for token in tokens]
        times.append(values[0])
        rows.append(values[1:] + [0.0] * (3 * count - len(values) + 1))
    if not depths or len(records) < 7:
        raise _AncillaryError(f"Currents 2: {name} needs at least 7 lines")
    if len(times) < 2:
        raise _AncillaryError(f"Currents 2: {name} needs at least two time rows")
    if not _increasing(depths):
        raise _AncillaryError(f"Currents 2: {name} depths must be strictly increasing")
    if not _increasing(times):
        raise _AncillaryError(f"Currents 2: {name} times must be strictly increasing")
    _check_current_resample(times, len(depths), np.asarray(rows), [*depths, 0.0])


def _check_grid_current(records: list[str], name: str) -> None:
    """Mirror ``read_4d_grid`` (Currents 5)."""
    import numpy as np

    sizes: list[int] = []
    axes: list[list[float]] = []
    points: dict[tuple[int, int, int, int], list[float]] = {}
    for number, raw in enumerate(records, start=1):
        if len(raw) > _NATIVE_TABLE_ROW_LENGTH:
            raise _AncillaryError(f"{name} line {number}: row is too long")
        tokens = _table_tokens(raw)
        if number == 1:
            good = len(tokens) == 4 and all(re.fullmatch(r"[+-]?[0-9]+", t) for t in tokens)
            sizes = [int(token) for token in tokens] if good else []
            if not good or any(size < 1 for size in sizes):
                raise _AncillaryError(f"Currents 5: line 1 of {name} must be `nx ny nz nt`")
            if math.prod(sizes) > _MAX_CURRENT_SAMPLES:
                raise _AncillaryError(f"Currents 5: {name} declares more than 2e6 grid points")
        elif number <= 5:
            if len(tokens) != sizes[number - 2]:
                raise _AncillaryError(f"Currents 5: line {number} of {name} has the wrong length")
            axes.append([_table_number(token, name, number) for token in tokens])
        else:
            if not tokens:
                continue
            if number == 6 and _NUMERIC_SHAPE.fullmatch(tokens[0]) is None:
                continue
            if len(tokens) != 7:
                raise _AncillaryError(f"Currents 5: {name} line {number}: a row is 7 numbers")
            row = [_table_number(token, name, number) for token in tokens]
            where: list[int] = []
            for axis, value in zip(axes, row, strict=False):
                if value not in axis:
                    raise _AncillaryError(f"Currents 5: {name} line {number}: off the grid")
                where.append(axis.index(value))
            key = (where[0], where[1], where[2], where[3])
            if key in points:
                raise _AncillaryError(f"Currents 5: {name} line {number}: repeats a grid point")
            points[key] = row[4:]
    if len(axes) < 4:
        raise _AncillaryError(f"Currents 5: {name} needs the grid sizes and coordinates")
    if not all(_increasing(axis) for axis in axes):
        raise _AncillaryError(f"Currents 5: {name} coordinates must be strictly increasing")
    if len(axes[3]) < 2:
        raise _AncillaryError(f"Currents 5: {name} needs at least two times")
    if len(points) < math.prod(sizes):
        raise _AncillaryError(f"Currents 5: {name} has no row for a grid point")
    spatial = math.prod(sizes[:3])
    field = np.zeros((sizes[3], spatial * 3))
    for (ix, iy, iz, it), velocity in points.items():
        column = 3 * ((ix * sizes[1] + iy) * sizes[2] + iz)
        field[it, column : column + 3] = velocity
    _check_current_resample(axes[3], spatial, field, [*axes[0], *axes[1], *axes[2]])


def _motion_time_index(
    time: float, dt: float, n_time: int, tolerance: float, start_row_only: bool
) -> int | None:
    """Mirror ``motion_grid_index``: the 0-based step, -1 past TMax, ``None`` off the grid.

    start_row_only: a static check without dtM, whose grid is the t = 0 row: a later row is not
    used, whatever its time step.
    """
    if start_row_only and time > tolerance:
        return -1
    if not abs(time / dt) < _MAX_GRID_STEPS:
        return None
    step = round(time / dt)
    if step < 0:
        return None
    if step < n_time:
        return step if abs(step * dt - time) <= tolerance else None
    if abs(step * dt - time) <= 100.0 * _NATIVE_EPSILON * max(1.0, abs(time)):
        return -1
    return None


def _check_motion_rows(
    records: list[str],
    dt: float,
    tmax: float,
    eligible: set[int] | None,
    roll_ends: set[int] | None,
    turbines: dict[int, list[int]] | None,
    start_row_only: bool,
) -> None:
    """Mirror ``read_motion_file``.

    eligible: the ids the file must move at every time (``None``: on a route that takes
    other points as well, their rows are only read). roll_ends: with a line solved in torsion,
    the points whose moving end is restrained in torsion. turbines: the point ids of each
    TURBINES row, on a deck that has them.
    """
    n_time = round(tmax / dt) + 1
    tolerance = 100.0 * _NATIVE_EPSILON * max(1.0, tmax)
    what = "motionFile"
    seen: set[tuple[int, int]] = set()
    roll_rows: dict[int, dict[int, float]] = {}
    for number, tokens in _data_rows(records, what):
        where = f"{what} line {number}"
        if turbines is not None:
            status, row = _real_row(tokens, 21)
            if status != 0:
                raise _AncillaryError(f"{where}: TURBINES motion rows must be 21 numbers")
            if (
                any(abs(value) > _NATIVE_MAX_COORDINATE for value in row[2:9])
                or any(abs(value) > _MAX_MOTION_SPEED for value in row[9:15])
                or any(abs(value) > _MAX_MOTION_ACCEL for value in row[15:21])
            ):
                raise _AncillaryError(f"{where}: value outside the admissible range")
            turbine = int(row[1]) if row[1] == int(row[1]) else 0
            if turbine not in turbines:
                raise _AncillaryError(f"{where}: J must be the integer id of a TURBINES row")
            if abs(math.sqrt(sum(value * value for value in row[5:9])) - 1.0) > 1.0e-6:
                raise _AncillaryError(f"{where}: the quaternion must have unit norm (within 1e-6)")
            step = _motion_time_index(row[0], dt, n_time, tolerance, start_row_only)
            if step is None:
                raise _AncillaryError(f"{where}: time is outside the dtM/TMax grid")
            if step == -1:
                continue
            if (-turbine, step) in seen:
                raise _AncillaryError(f"{where}: duplicate row for turbine {turbine}")
            seen.add((-turbine, step))
            seen.update((point, step) for point in turbines[turbine])
            continue
        status, row = _real_row(tokens, 11)
        if status != 0:
            raise _AncillaryError(f"{where}: rows must be: time point_id x y z vx vy vz ax ay az")
        if (
            any(abs(value) > _NATIVE_MAX_COORDINATE for value in row[2:5])
            or any(abs(value) > _MAX_MOTION_SPEED for value in row[5:8])
            or any(abs(value) > _MAX_MOTION_ACCEL for value in row[8:11])
        ):
            raise _AncillaryError(f"{where}: value outside the admissible range")
        point = int(row[1]) if abs(row[1]) <= 2**31 - 1 and row[1] == int(row[1]) else 0
        if point < 1:
            raise _AncillaryError(f"{where}: point_id must be a positive integer")
        step = _motion_time_index(row[0], dt, n_time, tolerance, start_row_only)
        if step is None:
            raise _AncillaryError(f"{where}: time is outside the dtM/TMax grid")
        if eligible is not None and point not in eligible:
            raise _AncillaryError(f"{where}: references point id {point}, which is not eligible")
        if step == -1:
            continue
        if (point, step) in seen:
            raise _AncillaryError(f"{where}: duplicate row for point {point} at this time")
        seen.add((point, step))
        if roll_ends is not None and len(tokens) >= 12 and _NUMERIC_SHAPE.fullmatch(tokens[11]):
            roll = _token_real(tokens[11])
            if roll is None:
                raise _AncillaryError(f"{where}: the roll column must be a finite number")
            roll_rows.setdefault(point, {})[step] = roll
    if eligible is not None and any(
        (point, step) not in seen for point in eligible for step in range(n_time)
    ):
        raise _AncillaryError(
            "motionFile must provide every Coupled/Vessel point at every dtM time"
        )
    if roll_ends is None:
        return
    for point, rolls in roll_rows.items():
        if len(rolls) != n_time:
            raise _AncillaryError(
                f"motionFile: point {point} gives the roll column on some rows only"
            )
        if any(rolls.values()):
            if point not in roll_ends:
                raise _AncillaryError(
                    f"motionFile: point {point} has a non-zero roll column, but no line restrained "
                    "in torsion has its moving end there"
                )
            if rolls[0] != 0.0:
                raise _AncillaryError(
                    f"motionFile: the roll column of point {point} must be 0 at t = 0"
                )


def _check_vessel_rows(records: list[str], dt: float, tmax: float, start_row_only: bool) -> None:
    """Mirror ``read_vessel_record``."""
    n_time = round(tmax / dt) + 1
    tolerance = 100.0 * _NATIVE_EPSILON * max(1.0, tmax)
    what = "vesselMotion file"
    form = 0
    seen: set[int] = set()
    for number, tokens in _data_rows(records, what):
        where = f"{what} line {number}"
        if form == 0 and len(tokens) in (19, 20):
            form = len(tokens)
        status, row = (1, []) if len(tokens) != form else _real_row(tokens, form)
        if status != 0:
            raise _AncillaryError(f"{where}: rows must hold 19 or 20 values, one form for the file")
        if any(abs(value) > _NATIVE_MAX_COORDINATE for value in row[1:]):
            raise _AncillaryError(f"{where}: value outside the admissible range")
        step = _motion_time_index(row[0], dt, n_time, tolerance, start_row_only)
        if step is None:
            raise _AncillaryError(f"{where}: time is outside the dtM/TMax grid")
        if step == -1:
            continue
        if step in seen:
            raise _AncillaryError(f"{where}: duplicate row at this time")
        if form == 20 and abs(math.sqrt(sum(v * v for v in row[4:8])) - 1.0) > 1.0e-6:
            raise _AncillaryError(f"{where}: the quaternion must have unit norm (within 1e-6)")
        seen.add(step)
    if len(seen) < n_time:
        raise _AncillaryError("vesselMotion file must provide one row at every dtM time")


def _check_rao_table(records: list[str], headings_in_use: Iterable[float]) -> None:
    """Mirror ``read_rao_table``, ``CD_Vessel_RAO_Set`` and the heading test of ``_RAO_Eval``."""
    what = "vesselRAO file"
    heads: list[float] = []
    blocks: list[list[float]] = []
    amplitudes: list[float] = []
    for number, tokens in _data_rows(records, what):
        where = f"{what} line {number}"
        if tokens[0].lower() == "heading":
            value = _token_real(tokens[1]) if len(tokens) == 2 else None
            if value is None or len(heads) >= 361:
                raise _AncillaryError(f'{where}: a heading row must be "HEADING <deg>"')
            heads.append(value)
            blocks.append([])
            continue
        status, row = (1, []) if len(tokens) != 13 else _real_row(tokens, 13)
        if status != 0 or not heads or len(blocks[-1]) >= 2000:
            raise _AncillaryError(f'{where}: data rows follow a "HEADING <deg>" row with 13 values')
        blocks[-1].append(row[0])
        amplitudes.extend(row[1::2])
    if not heads:
        raise _AncillaryError('vesselRAO file holds no "HEADING <deg>" block')
    if any(not block for block in blocks):
        raise _AncillaryError("a vesselRAO heading block holds no period rows")
    if any(block != blocks[0] for block in blocks):
        raise _AncillaryError("every vesselRAO heading block must list the same periods")
    periods = sorted(blocks[0])
    heads = sorted(heads)
    if periods[0] <= 0.0:
        raise _AncillaryError("vesselRAO file: RAO periods must be positive")
    if any(value < 0.0 for value in amplitudes):
        raise _AncillaryError("vesselRAO file: RAO amplitudes must be non-negative")
    if not _increasing(periods):
        raise _AncillaryError("vesselRAO file: RAO periods must be strictly ascending")
    if not _increasing(heads):
        raise _AncillaryError("vesselRAO file: RAO headings must be strictly ascending")
    if heads[-1] - heads[0] >= 360.0:
        raise _AncillaryError("vesselRAO file: RAO headings must lie within one 360 deg turn")
    for heading in headings_in_use:
        turned = heads[0] + (heading - heads[0]) % 360.0
        if turned > heads[-1] + 1.0e-9 and abs(turned - 360.0 - heads[0]) <= 1.0e-9:
            turned = heads[0]
        if len(heads) == 1:
            if abs(turned - heads[0]) > 1.0e-9:
                raise _AncillaryError("relative wave heading is not in the one-heading RAO table")
        elif turned > heads[-1] + 1.0e-9:
            raise _AncillaryError("relative wave heading lies outside the RAO table heading range")


def _floor_axis(axis: list[float], q: float) -> tuple[int, float, bool]:
    """Mirror ``locate_axis`` (0-based): the cell, the fraction and whether q is off the grid."""
    if q <= axis[0]:
        return 0, 0.0, q < axis[0]
    if q >= axis[-1]:
        return len(axis) - 2, 1.0, q > axis[-1]
    cell = bisect.bisect_left(axis, q) - 1
    return cell, (q - axis[cell]) / (axis[cell + 1] - axis[cell]), False


def _crease_band(axis: list[float], cell: int, q: float) -> tuple[int, float, float]:
    """Mirror ``crease_band`` (0-based; -1: none)."""
    if cell > 0:
        band = _BATHY_CREASE_FRACTION * min(
            axis[cell] - axis[cell - 1], axis[cell + 1] - axis[cell]
        )
        if q - axis[cell] < band:
            return cell, q - axis[cell], band
    if cell + 2 < len(axis):
        band = _BATHY_CREASE_FRACTION * min(
            axis[cell + 1] - axis[cell], axis[cell + 2] - axis[cell + 1]
        )
        if axis[cell + 1] - q < band:
            return cell + 1, q - axis[cell + 1], band
    return -1, 0.0, 0.0


def _bathymetry_floor(
    xs: list[float], ys: list[float], depth: dict[tuple[int, int], float], x: float, y: float
) -> tuple[float, float]:
    """Mirror ``floor_eval``: the rounded and the bilinear seabed elevation at (x, y)."""
    ix, tx, clamp_x = _floor_axis(xs, x)
    iy, ty, clamp_y = _floor_axis(ys, y)
    grid = (
        -(1.0 - tx) * (1.0 - ty) * depth[ix, iy]
        - tx * (1.0 - ty) * depth[ix + 1, iy]
        - (1.0 - tx) * ty * depth[ix, iy + 1]
        - tx * ty * depth[ix + 1, iy + 1]
    )
    if len(xs) <= 2 and len(ys) <= 2:
        return grid, grid

    def x_jump(k: int, j: int, band: float) -> tuple[float, bool]:
        jump = (depth[k, j] - depth[k + 1, j]) / (xs[k + 1] - xs[k]) - (
            depth[k - 1, j] - depth[k, j]
        ) / (xs[k] - xs[k - 1])
        active = abs(jump) * band / 6.0 > _BATHY_CREASE_MIN_HEIGHT
        return (jump if active else 0.0), active

    def y_jump(i: int, k: int, band: float) -> tuple[float, bool]:
        jump = (depth[i, k] - depth[i, k + 1]) / (ys[k + 1] - ys[k]) - (
            depth[i, k - 1] - depth[i, k]
        ) / (ys[k] - ys[k - 1])
        active = abs(jump) * band / 6.0 > _BATHY_CREASE_MIN_HEIGHT
        return (jump if active else 0.0), active

    kx, u, band_x = (-1, 0.0, 0.0) if clamp_x else _crease_band(xs, ix, x)
    ky, v, band_y = (-1, 0.0, 0.0) if clamp_y else _crease_band(ys, iy, y)
    if kx < 0 and ky < 0:
        return grid, grid
    floor = grid
    hx = 0.0
    if kx >= 0:
        hx = (band_x - abs(u)) ** 3 / (6.0 * band_x * band_x)
        jx0, on0 = x_jump(kx, iy, band_x)
        jx1, on1 = x_jump(kx, iy + 1, band_x)
        if on0 or on1:
            floor += hx * ((1.0 - ty) * jx0 + ty * jx1)
    if ky >= 0:
        hy = (band_y - abs(v)) ** 3 / (6.0 * band_y * band_y)
        jy0, on0 = y_jump(ix, ky, band_y)
        jy1, on1 = y_jump(ix + 1, ky, band_y)
        mixed = 0.0
        on_mixed = False
        if kx >= 0:
            below, _ = x_jump(kx, ky - 1, band_x)
            centre, _ = x_jump(kx, ky, band_x)
            above, _ = x_jump(kx, ky + 1, band_x)
            mixed = (above - centre) / (ys[ky + 1] - ys[ky]) - (centre - below) / (
                ys[ky] - ys[ky - 1]
            )
            on_mixed = abs(mixed) * band_x * band_y / 36.0 > _BATHY_CREASE_MIN_HEIGHT
            if not on_mixed:
                mixed = 0.0
        if on0 or on1 or on_mixed:
            floor += hy * ((1.0 - tx) * jy0 + tx * jy1 + hx * mixed)
    return floor, grid


def _check_bathymetry(
    records: list[str], fixed_points: list[tuple[int, float, float, float]]
) -> None:
    """Mirror ``load_bathymetry_file`` and ``check_fixed_points_on_bathymetry``."""
    what = "bathymetry file"
    rows: list[list[float]] = []
    for number, tokens in _data_rows(records, what):
        if len(tokens) != 3:
            raise _AncillaryError(f'{what} line {number}: rows must be "x y depth"')
        status, row = _real_row(tokens, 3)
        if status != 0:
            raise _AncillaryError(f"{what} line {number}: malformed row")
        rows.append(row)
    if len(rows) < 4:
        raise _AncillaryError("bathymetry file needs at least a 2x2 grid")
    if any(row[2] <= 0.0 for row in rows):
        raise _AncillaryError("bathymetry file depths must be positive")

    def unique(values: list[float]) -> list[float]:
        kept: list[float] = []
        for value in sorted(values):
            if not kept or abs(value - kept[-1]) > 16.0 * _NATIVE_EPSILON * max(
                1.0, abs(value), abs(kept[-1])
            ):
                kept.append(value)
        return kept

    def nearest(axis: list[float], value: float) -> int:
        at = bisect.bisect_left(axis, value)
        return min(
            (i for i in (at - 1, at) if 0 <= i < len(axis)), key=lambda i: abs(axis[i] - value)
        )

    xs = unique([row[0] for row in rows])
    ys = unique([row[1] for row in rows])
    if len(xs) < 2 or len(ys) < 2 or len(rows) != len(xs) * len(ys):
        raise _AncillaryError("bathymetry file must define one complete rectangular grid")
    depth: dict[tuple[int, int], float] = {}
    for x, y, value in rows:
        key = (nearest(xs, x), nearest(ys, y))
        if key in depth:
            raise _AncillaryError("bathymetry file has duplicate x/y entries")
        depth[key] = value
    for point, x, y, z in fixed_points:
        floor, grid = _bathymetry_floor(xs, ys, depth, x, y)
        tolerance = max(1.0e-3, 1.0e-5 * abs(floor)) * (1.0 + 1.0e-9)
        if abs(z - floor) <= tolerance or abs(z - grid) <= tolerance or z > floor:
            continue
        raise _AncillaryError(f"POINT {point} (Fixed) lies below the seabed: z = {z:g}")


def _read_syrope_settings(records: list[str]) -> tuple[str, str, float, float]:
    """Mirror the settings rows of ``read_syrope_settings``: OWC path, WCType, k1, k2."""
    what = "Syrope settings file"
    found: dict[str, str] = {}
    for number, tokens in _data_rows(records, what):
        if len(tokens) < 2:
            continue
        name = tokens[1].lower()
        value = _strip_quotes(tokens[0])
        if name not in {"owc", "wctype", "k1", "k2"}:
            continue
        if name in found:
            raise _AncillaryError(f"{what} line {number}: duplicate Syrope {tokens[1]} row")
        if name == "wctype" and value.lower() not in {"linear", "quadratic", "exp"}:
            raise _AncillaryError(
                f"{what} line {number}: Syrope WCType must be LINEAR, QUADRATIC, or EXP"
            )
        if name in {"k1", "k2"} and _token_real(value) is None:
            raise _AncillaryError(f"{what} line {number}: Syrope {tokens[1]} is not a plain number")
        found[name] = value
    if len(found) < 4:
        raise _AncillaryError("the Syrope settings file needs OWC, WCType, k1, and k2 rows")
    k1 = _token_real(found["k1"])
    k2 = _token_real(found["k2"])
    assert k1 is not None and k2 is not None
    return found["owc"], found["wctype"].lower(), k1, k2


def _read_syrope_table(records: list[str]) -> list[list[float]]:
    """Mirror the OWC table rows of ``read_syrope_settings``."""
    what = "Syrope OWC table"
    rows: list[list[float]] = []
    for number, tokens in _data_rows(records, what):
        if not any(_NUMERIC_SHAPE.fullmatch(token) for token in tokens):
            continue
        status, row = _real_row(tokens, 2)
        if status != 0:
            raise _AncillaryError(f"{what} line {number}: malformed row")
        rows.append(row)
    if len(rows) < 2:
        raise _AncillaryError("the Syrope OWC table needs at least two rows")
    return rows


def _syrope_curve_defect(
    strain: list[float],
    tension: list[float],
    shape: str,
    k1: float,
    k2: float,
    alpha: float,
    beta: float,
    t_max: float,
) -> bool:
    """True when ``CD_Syrope_Working_Curve`` fails at the running maximum ``t_max``."""

    def fast(value: float) -> float:
        return math.log(1.0 + beta / alpha * value) / beta

    if not t_max > 0.0 or t_max < tension[0] or t_max > tension[-1]:
        return True
    at = bisect.bisect_left(tension, t_max)
    if at == 0:
        eps_max = strain[0]
    elif at == len(tension):
        eps_max = strain[-1]
    else:
        eps_max = strain[at - 1] + (strain[at] - strain[at - 1]) * (t_max - tension[at - 1]) / (
            tension[at] - tension[at - 1]
        )
    eps_min = strain[0] + k1 * (eps_max - strain[0])
    if shape == "linear" and k1 >= 1.0:
        eps_min = eps_max - t_max / k1
    if not (eps_min >= 0.0 and eps_max - eps_min > 0.0):
        return True
    previous: tuple[float, float] | None = None
    for index in range(_SYROPE_CURVE_SAMPLES):
        at_strain = eps_min + (eps_max - eps_min) * index / (_SYROPE_CURVE_SAMPLES - 1)
        xi = (at_strain - eps_min) / (eps_max - eps_min)
        if shape == "linear":
            value = t_max * xi
        elif shape == "quadratic":
            value = t_max * xi * (k2 * xi + (1.0 - k2))
        else:
            value = t_max * (1.0 - math.exp(k2 * xi)) / (1.0 - math.exp(k2))
        argument = 1.0 + beta / alpha * value
        if argument <= 0.0:
            return True
        slow = at_strain - fast(value)
        if previous is not None and (value <= previous[0] or slow <= previous[1]):
            return True
        previous = (value, slow)
    return False


def _check_syrope_curve(
    rows: list[list[float]],
    shape: str,
    k1: float,
    k2: float,
    alpha: float,
    beta: float,
) -> None:
    """Mirror ``CD_Syrope_Init`` (the constants BA_s and BA_d are checked with the row)."""
    strain = [row[0] for row in rows]
    tension = [row[1] for row in rows]
    if not (_increasing(strain) and _increasing(tension)):
        raise _AncillaryError("the OWC strain and tension columns must be strictly increasing")
    if shape == "exp" and not k2 > 0.0:
        raise _AncillaryError("the EXP working curve needs a positive shape parameter p2 (k2 > 0)")
    if shape == "linear" and k1 < 0.0:
        raise _AncillaryError("the LINEAR working curve requires k1 >= 0")
    if shape == "quadratic" and (k1 < 0.0 or k1 >= 1.0 or k2 <= 0.0 or k2 > 1.0):
        raise _AncillaryError("the QUADRATIC working curve requires 0 <= k1 < 1 and 0 < k2 <= 1")
    if shape == "exp" and (k1 < 0.0 or k1 >= 1.0 or k2 < 1.0e-6 or k2 > 700.0):
        raise _AncillaryError("the EXP working curve requires 0 <= k1 < 1 and 1e-6 <= k2 <= 700")
    if any(1.0 + beta / alpha * value <= 0.0 for value in tension):
        raise _AncillaryError("the OWC slow-spring static strain is non-finite")
    slow = [
        e - math.log(1.0 + beta / alpha * t) / beta for e, t in zip(strain, tension, strict=True)
    ]
    if not _increasing(slow):
        raise _AncillaryError("the OWC slow-spring static strain must be strictly increasing")
    low = max(tension[0], 0.0)
    high = tension[-1]
    if all(
        _syrope_curve_defect(
            strain,
            tension,
            shape,
            k1,
            k2,
            alpha,
            beta,
            low + (high - low) * k / _SYROPE_SCAN_SAMPLES,
        )
        for k in range(1, _SYROPE_SCAN_SAMPLES + 1)
    ):
        raise _AncillaryError("no running maximum in the OWC table range admits a working curve")


def _train_direction(values: tuple[str, ...]) -> tuple[float, float]:
    """Mirror ``CD_Sea_Parse_Train``: the direction and spreading of a wave row's values."""
    kind = values[0].lower()
    if kind == "airy":
        return _native_float(values[3]), 0.0
    index = 4 if kind == "jonswap" else 7 if kind.startswith("ochi") else 3
    spreading = _native_float(values[index + 1]) if len(values) > index + 1 else 0.0
    return _native_float(values[index]), spreading


def _spreading_weights(spreading: float, bins: int) -> list[float]:
    """Mirror ``CD_Spreading_Weights``: the cos-2s weight of each equal-angle bin."""
    constant = math.exp(math.lgamma(spreading + 1.0) - math.lgamma(spreading + 0.5))
    constant /= math.sqrt(math.pi)
    weights = []
    for j in range(bins):
        start = -0.5 * math.pi + math.pi * j / bins
        step = (-0.5 * math.pi + math.pi * (j + 1) / bins - start) / _SPREADING_QUADRATURE
        weight = 0.0
        for q in range(_SPREADING_QUADRATURE + 1):
            density = constant * max(0.0, math.cos(start + step * q)) ** (2.0 * spreading)
            end = q in (0, _SPREADING_QUADRATURE)
            weight += density * (1.0 if end else 4.0 if q % 2 == 1 else 2.0)
        weights.append(weight * step / 3.0)
    total = sum(weights)
    if total > 0.0:
        weights = [weight / total for weight in weights]
    return [weight if weight >= sys.float_info.min else 0.0 for weight in weights]


def _spread_headings(direction: float, spreading: float, bins: int) -> list[float]:
    """The headings of a train (``CD_Sea_Synthesise``) that carry energy.

    A spread train has one heading per bin centre. A narrow spreading leaves the outer bins with
    no weight, and ``synthesize_vessel_rao`` skips their zero-amplitude components.
    """
    if spreading <= 0.0:
        return [direction]
    return [
        direction - 90.0 + 180.0 * (j + 0.5) / bins
        for j, weight in enumerate(_spreading_weights(spreading, bins))
        if weight > 0.0
    ]


@dataclass(frozen=True)
class DeckRecord:
    """One parsed table row and its zero-based source-line location.

    Returned by the table properties of :class:`cabledyn.DeckFile`, such as
    :attr:`cabledyn.DeckFile.points`.

    Attributes
    ----------
    index : int
        Zero-based line number of the row in the deck text.
    tokens : tuple[str, ...]
        The row's data values in column order, with surrounding quotes removed.
    quoted : tuple[bool, ...]
        Whether each token was quoted in the source.
    """

    index: int
    tokens: tuple[str, ...]
    quoted: tuple[bool, ...] = field(default=(), compare=False)


@dataclass(frozen=True)
class OptionRecord:
    """One option row, including positional and keyword-first native forms.

    Returned by :attr:`cabledyn.DeckFile.options` and
    :meth:`cabledyn.DeckFile.option`.

    Attributes
    ----------
    index : int
        Zero-based line number of the row in the deck text.
    keyword : str
        Option keyword as written in the deck.
    values : tuple[str, ...]
        Interpreted values. Path-valued options are dequoted as the native
        reader does.
    description : str | None
        Text after the first whitespace-delimited ``-``, if any.
    keyword_first : bool
        Whether the row uses the keyword-first form, as ``dynamic_solver`` does.
    trailing : tuple[str, ...]
        Raw commentary tokens that follow a ``value keyword`` pair.
    """

    index: int
    keyword: str
    values: tuple[str, ...]
    description: str | None
    keyword_first: bool = False
    trailing: tuple[str, ...] = ()


@dataclass(frozen=True)
class GeneratedCase:
    """A generated deck plus the working directory required by relative inputs.

    Returned by :func:`cabledyn.generate_deck_cases`.

    Attributes
    ----------
    name : str
        Case name; the deck file is ``<name>.dat``.
    deck : pathlib.Path
        Absolute path of the generated deck.
    working_directory : pathlib.Path
        Directory to run the deck from, so that relative ancillary files resolve.
    changes : collections.abc.Mapping[str, object]
        Read-only mapping of the selectors and values applied to the base deck.
    sha256 : str
        SHA-256 digest of the generated deck file.
    """

    name: str
    deck: Path
    working_directory: Path
    changes: Mapping[str, object]
    sha256: str

    def __post_init__(self) -> None:
        object.__setattr__(self, "deck", Path(self.deck).expanduser().resolve())
        object.__setattr__(
            self, "working_directory", Path(self.working_directory).expanduser().resolve()
        )
        object.__setattr__(self, "changes", MappingProxyType(dict(self.changes)))


def _atomic_write_bytes(target: Path, payload: bytes) -> None:
    """Write ``payload`` to ``target`` through a same-directory temporary file.

    The replacement file receives the default permissions of a newly created
    file (``0o666`` masked by the process umask), not the private mode of the
    temporary file.
    """
    fd, temporary = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(payload)
        umask = os.umask(0)
        os.umask(umask)
        os.chmod(temporary, 0o666 & ~umask)
        os.replace(temporary, target)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)
        raise


class DeckFile:
    """A source-preserving CableDyn deck document.

    Untouched rows, comments, bytes that are not valid UTF-8, recognized native
    optional sections, and ordering are retained byte-for-byte. Unknown dashed
    headings fail closed. An edited row is rendered canonically (single spaces
    between its data tokens) while its leading indentation and everything after
    its last data token (option commentary, description, inline comment) are
    kept verbatim.

    Error contract:

    * ``DeckFormatError`` (a ``ValueError``): the deck text, as read or as it
      would be after an edit, violates the native reader contract. A failed
      edit is rolled back. Messages locate the problem as ``<source>:<line>``;
      after an edit the source is labelled ``edited copy of <path>``.
    * ``KeyError``: a selector or editor names a record, field, or option that
      the deck does not contain (including a column absent from that row).
    * ``ValueError``: a malformed selector or an argument that cannot be
      rendered as one native token (``None``, whitespace, quotes, comment
      markers, containers).
    * ``TypeError``: an argument of the wrong type, such as a non-Boolean
      ``caller_driven``.

    Construct instances with :meth:`read` or :meth:`from_text`.

    Parameters
    ----------
    path : str | os.PathLike
        Deck path; anchors relative ancillary file paths.
    lines : list[str]
        Deck records without their line endings.
    line_endings : list[str]
        The line ending of each record (``""`` for a final unterminated
        record), one per entry of ``lines``.
    caller_driven : bool
        Validate for the OpenFAST coupling instead of the standalone driver
            (see :class:`DeckFile`).
    label : str | None
        Name of the source in error messages; defaults to the resolved path.

    Raises
    ------
    TypeError
        If ``caller_driven`` is not a Boolean.
    ValueError
        If ``lines`` and ``line_endings`` differ in length.
    DeckFormatError
        If the deck violates the native deck contract.

    Attributes
    ----------
    path : pathlib.Path
        Absolute path of the deck. It anchors relative ancillary file paths.
    caller_driven : bool
        Whether the deck is validated for the OpenFAST coupling rather than
        the standalone driver.

    Notes
    -----
    ``caller_driven=False`` certifies a deck for the standalone driver
    ``cabledyn`` (the rules the native reader applies to every standalone
    entry point, together with the driver's own dispatch rules).
    ``caller_driven=True`` certifies it for the OpenFAST and FAST.Farm
    coupling (``CompMooring = 5``, ``MooringMod = 5``), where the host
    supplies the clock, the water depth and the water kinematics and drives
    the Coupled/Vessel points, bodies and rods. On that route a deck ``waves`` or
    ``wavetrain`` row is rejected, and a deck ``current`` row is rejected on a deck with
    finite-EI lines, Rigid6 bodies, rods or ``Turbine<J>`` points. The rest of the current
    rule depends on the host and is checked when OpenFAST initialises the module: the
    current is kept as a steady field when SeaState carries no waves or current and is
    rejected otherwise. The native C API (:class:`cabledyn.CableDyn`) reads decks with the
    standalone rules, so it rejects the ``CoupledPinned``/``VesselPinned`` bodies and rods
    that ``caller_driven=True`` accepts; a FAST.Farm shared mooring, in turn, refuses bodies and
    rods and the ``LINES`` range-graph flag ``r`` when it initialises the module, and the C API
    refuses the flag. ``RangeStart`` is held
    against the host's ``TMax`` when OpenFAST initialises the module, not against a deck
    ``TMax``. A coupled deck carries bodies or rods, not both (a rod fixed to a
    body counts as a rod): ``caller_driven=True`` rejects a deck with both, as the coupled
    route and the C API do, while the standalone driver's multibody march takes them.
    """

    def __init__(
        self,
        path: str | os.PathLike[str],
        lines: list[str],
        line_endings: list[str],
        *,
        caller_driven: bool = False,
        label: str | None = None,
    ) -> None:
        if not isinstance(caller_driven, bool):
            raise TypeError("caller_driven must be a Boolean")
        self.path = Path(path).expanduser().resolve()
        self.caller_driven = caller_driven
        # A leading UTF-8 byte-order mark is not deck text (the native reader drops
        # it too); it is kept aside and restored by text() and write().
        self._bom = bool(lines) and lines[0].startswith(_UTF8_BOM)
        if self._bom:
            lines = [lines[0][len(_UTF8_BOM) :], *lines[1:]]
        self._lines = lines
        self._line_endings = line_endings
        self._defer_validation = False
        self._source_label = label if label is not None else str(self.path)
        self._edited = False
        if len(self._lines) != len(self._line_endings):
            raise ValueError("lines and line endings must have the same length")
        self._sections: dict[str, list[tuple[int, int]]] = {}
        self._scan()
        self.validate()

    @classmethod
    def read(cls, path: str | os.PathLike[str], *, caller_driven: bool = False) -> DeckFile:
        """Read and validate a standalone or caller-driven CableDyn deck.

        Bytes that are not valid UTF-8 (for example a Latin-1 character in a
        comment) are carried through unchanged and written back byte-exactly.

        Parameters
        ----------
        path : str | os.PathLike
            Deck file to read.
        caller_driven : bool
            Validate for the OpenFAST coupling instead of the standalone driver
            (see :class:`DeckFile`).

        Returns
        -------
        DeckFile
            The parsed, validated deck.

        Raises
        ------
        DeckFormatError
            If the file cannot be read, names a reserved Windows device (on
            Windows), or violates the native deck contract.
        """
        if (device := windows_device_component(path)) is not None:
            raise DeckFormatError(
                f"cannot read {os.fspath(path)}: {device!r} is a reserved Windows device "
                "name (CON, PRN, AUX, NUL, COM1-9, LPT1-9), not a deck file"
            )
        source = Path(path).expanduser().resolve()
        try:
            payload = source.read_bytes()
        except OSError as exc:
            raise DeckFormatError(f"cannot read {source}: {exc}") from exc
        lines, endings = _split_records(payload.decode("utf-8", "surrogateescape"))
        return cls(source, lines, endings, caller_driven=caller_driven)

    @classmethod
    def from_text(
        cls,
        text: str,
        *,
        path: str | os.PathLike[str] = "deck.dat",
        caller_driven: bool = False,
        label: str | None = None,
    ) -> DeckFile:
        """Validate deck ``text`` held in memory.

        Parameters
        ----------
        text : str
            Complete deck text.
        path : str | os.PathLike
            Nominal deck path; anchors relative ancillary paths and the default
            write target directory.
        caller_driven : bool
            Validate for the OpenFAST coupling instead of the standalone driver
            (see :class:`DeckFile`).
        label : str | None
            Name of the text in error messages; defaults to
            ``"<in-memory deck>"``.

        Returns
        -------
        DeckFile
            The parsed, validated deck.

        Raises
        ------
        TypeError
            If ``caller_driven`` is not a Boolean.
        DeckFormatError
            If the text violates the native deck contract.
        """
        lines, endings = _split_records(text)
        return cls(
            path,
            lines,
            endings,
            caller_driven=caller_driven,
            label=label if label is not None else "<in-memory deck>",
        )

    def clone(self) -> DeckFile:
        """Return an independent editable copy.

        Returns
        -------
        DeckFile
            A deep copy; edits to it do not affect this deck.
        """
        return copy.deepcopy(self)

    def text(self) -> str:
        """Return the current complete deck text.

        Returns
        -------
        str
            Every record with its original line ending. Source bytes that are
            not valid UTF-8 appear as lone surrogates (``surrogateescape``);
            encode with ``errors="surrogateescape"`` to recover the original
            bytes. A byte-order mark that opened the source opens the text.
        """
        return (_UTF8_BOM if self._bom else "") + "".join(
            line + ending for line, ending in zip(self._lines, self._line_endings, strict=True)
        )

    @property
    def _label(self) -> str:
        return f"edited copy of {self._source_label}" if self._edited else self._source_label

    def _at(self, row: DeckRecord) -> str:
        """Return the ``<source>:<line>`` location of ``row`` for error messages."""
        return f"{self._label}:{row.index + 1}"

    def _scan(self) -> None:
        headings: list[tuple[str | None, int]] = []
        for index, line in enumerate(self._lines):
            encoded = line.encode("utf-8", "surrogateescape")
            if len(encoded) > _NATIVE_RECORD_LENGTH:
                head = encoded[:_NATIVE_RECORD_LENGTH].decode("utf-8", "surrogateescape")
                if encoded[_NATIVE_RECORD_LENGTH:].strip(b" ") and _comment_position(head) is None:
                    raise DeckFormatError(
                        f"{self._label}:{index + 1}: record is longer than "
                        f"{_NATIVE_RECORD_LENGTH} characters (shorten the row or start "
                        "its commentary with a # comment within the limit)"
                    )
            visible = _strip_inline_comment(line)
            if error := _character_error(visible):
                raise DeckFormatError(f"{self._label}:{index + 1}: {error}")
            if "---" not in visible:
                continue
            name = " ".join(_row_tokens(_ascii_upper(visible.replace("-", ""))))
            if not name or name == "END" or "NEED" in name or "INPUT FILE" in name:
                headings.append((None, index))
                continue
            try:
                canonical = _SECTION_ALIASES[name]
            except KeyError as exc:
                raise DeckFormatError(
                    f"{self._label}:{index + 1}: unknown deck section {name!r}"
                ) from exc
            headings.append((canonical, index))
        self._sections.clear()
        for position, (heading, index) in enumerate(headings):
            if heading is None:
                continue
            stop = headings[position + 1][1] if position + 1 < len(headings) else len(self._lines)
            # A repeated header continues the same native section: its rows are
            # appended in file order.
            self._sections.setdefault(heading, []).append((index + 1, stop))

    def _section_indices(self, section: str) -> list[int]:
        return [
            index for start, stop in self._sections.get(section, ()) for index in range(start, stop)
        ]

    def _rows(self, section: str) -> tuple[DeckRecord, ...]:
        rows: list[DeckRecord] = []
        for index in self._section_indices(section):
            visible = _strip_inline_comment(self._lines[index]).strip(_WHITESPACE)
            if not visible:
                continue
            raw = _row_tokens(visible)
            # Native table readers discard every row without a token that reads
            # as a real number (column-name and units rows) before interpreting
            # fields, so descriptive prose is never tokenized as data.
            if section in _TABLE_SECTIONS and not _has_numeric_token(raw):
                continue
            where = f"{self._label}:{index + 1}"
            if section not in _LIST_DIRECTED_SECTIONS:
                rows.append(DeckRecord(index, tuple(raw), (False,) * len(raw)))
                continue
            # List-directed rows are tokenized like the native token_bounds: a
            # quoted value is one token even when it contains whitespace.
            raw = _quoted_row_tokens(visible)
            text_columns = _text_columns(section, len(raw))
            values: list[str] = []
            quoted: list[bool] = []
            for column, token in enumerate(raw):
                # The native reader keeps the LINE TYPES EA column whole as text, so
                # an unquoted SYROPE:<path>|alpha|beta may hold '/' there and may be
                # longer than a name; every other column fits a 64-character buffer.
                verbatim_text = section == "LINE TYPES" and column == 3
                length = len(token) - 2 if token[0] in "\"'" and len(token) >= 2 else len(token)
                if not verbatim_text and length > _NATIVE_NAME_LENGTH:
                    raise DeckFormatError(
                        f"{where}: {section} column {column + 1} value {token[:24]!r}... is "
                        f"longer than {_NATIVE_NAME_LENGTH} characters; shorten the name"
                    )
                value, was_quoted = _dequote(token, where)
                if not was_quoted and verbatim_text and '"' in token and "'" in token:
                    raise DeckFormatError(
                        f"{where}: {section} column {column + 1} value {token!r} mixes both "
                        "quote characters"
                    )
                if not was_quoted and not verbatim_text and _has_list_separator(token):
                    raise DeckFormatError(
                        f"{where}: {section} column {column + 1} value {token!r} contains a "
                        "list-directed separator ('/', ',', ';') or repeat count ('n*'); "
                        "write plain numbers and quote text values that need these characters"
                    )
                if was_quoted and column not in text_columns:
                    raise DeckFormatError(
                        f"{where}: {section} column {column + 1} must be an unquoted number, "
                        f"got {token}"
                    )
                if (
                    not was_quoted
                    and column not in text_columns
                    and not verbatim_text
                    and any(character.isdigit() for character in token)
                    and set(token) <= _NUMBER_CHARACTERS
                    and not _reads_as_real(token)
                ):
                    raise DeckFormatError(
                        f"{where}: {section} column {column + 1} value {token!r} is not a plain "
                        "number (write an exponent with e, as in 1.0e5)"
                    )
                # native list_safe_row: a number column holds a finite, normal value
                if not was_quoted and column not in text_columns:
                    defect = _real_token_defect(token)
                    if defect is not None:
                        raise DeckFormatError(f"{where}: {section} column {column + 1} {defect}")
                values.append(value)
                quoted.append(was_quoted)
            rows.append(DeckRecord(index, tuple(values), tuple(quoted)))
        return tuple(rows)

    def _stock_line_type_columns(self, record: DeckRecord) -> bool:
        """Return the native hydro-column convention in force at ``record``.

        The native reader keeps one convention for the whole parse and updates
        it from every LINE TYPES header row (a row with no numeric token).
        """
        stock_columns = False
        for index in self._section_indices("LINE TYPES"):
            if index >= record.index:
                break
            header = _strip_inline_comment(self._lines[index]).strip(_WHITESPACE).lower()
            if not header or _has_numeric_token(_row_tokens(header)):
                continue
            if "cdax" in header or "caax" in header:
                stock_columns = True
            elif "cdt" in header or "cd_t" in header:
                stock_columns = False
        return stock_columns

    def _check_moordyn_body_row(
        self,
        row: DeckRecord,
        numeric: Callable[[str, DeckRecord, str], float],
        has_motion_file: bool = False,
        has_dtm: bool = True,
    ) -> None:
        """Validate a 14-column MoorDyn BODIES row as the native reader does."""
        attachment = row.tokens[1].lower()
        if attachment not in {"free", *_HOST_BODY_TYPES, *_PINNED_BODY_TYPES}:
            raise DeckFormatError(
                f"{self._at(row)}: BODIES attachment {row.tokens[1]!r} is not supported in the "
                "14-column MoorDyn row (Free, Coupled, Vessel, CoupledPinned or VesselPinned "
                "bodies)"
            )
        host = attachment in _HOST_BODY_TYPES
        pinned = attachment in _PINNED_BODY_TYPES
        if host and not (has_motion_file or self.caller_driven):
            raise DeckFormatError(
                f"{self._at(row)}: Coupled/Vessel BODY requires a motionFile (or a coupled host)"
            )
        for index in (2, 3, 4, 5, 6, 7, 8, 11):
            numeric(row.tokens[index], row, f"BODIES column {index + 1}")
        lists = {}
        for index, name, sizes in (
            (9, "CG", {1, 3}),
            (10, "I", {1, 3}),
            (12, "CdA", {1, 2, 3, 6}),
            (13, "Ca", {1, 3}),
        ):
            parts = row.tokens[index].split("|")
            if len(parts) not in sizes:
                raise DeckFormatError(f"{self._at(row)}: BODIES {name} has {len(parts)} entries")
            lists[name] = [numeric(p, row, f"BODIES {name}") for p in parts]
        cda, ca = lists["CdA"], lists["Ca"]
        translational = cda[:1] if len(cda) == 2 else cda[:3]
        rotational = cda[1:] if len(cda) == 2 else cda[3:]
        if any(v != cda[0] for v in translational) or any(v != 0.0 for v in rotational):
            raise DeckFormatError(
                f"{self._at(row)}: BODIES CdA must be isotropic without rotational drag"
            )
        if any(v != ca[0] for v in ca):
            raise DeckFormatError(f"{self._at(row)}: BODIES Ca must be isotropic")
        mass = numeric(row.tokens[8], row, "BODIES Mass")
        volume = numeric(row.tokens[11], row, "BODIES Volume")
        coordinates = [numeric(row.tokens[index], row, "BODIES") for index in range(2, 8)]
        if _body_outside_admissible_range(
            coordinates + lists["CG"], [mass, volume, cda[0], *lists["I"]], ca[0]
        ):
            raise DeckFormatError(f"{self._at(row)}: {_BODY_RANGE_MESSAGE}")
        if pinned:
            # native finalize_checks: the Rigid6 dynamic-deck rule first, then only a coupled
            # host moves the reference point; the rotation is integrated
            if not (has_dtm or self.caller_driven):
                raise DeckFormatError(f"{self._at(row)}: {_RIGID6_DYNAMIC_MESSAGE}")
            if not self.caller_driven:
                raise DeckFormatError(f"{self._at(row)}: {_PINNED_BODY_HOST_MESSAGE}")
            if min(mass, volume, cda[0], ca[0]) < 0.0 or any(v <= 0.0 for v in lists["I"]):
                raise DeckFormatError(f"{self._at(row)}: {_PINNED_BODY_VALUE_MESSAGE}")
            return
        if host:
            # a platform-borne body may be a massless attachment frame
            if min(mass, volume, cda[0], ca[0], *lists["I"]) < 0.0:
                raise DeckFormatError(
                    f"{self._at(row)}: Coupled/Vessel BODY requires non-negative "
                    "Mass/Ixx/Iyy/Izz/Vol/CdA/Ca"
                )
            return
        if mass <= 0.0 or volume < 0.0 or cda[0] < 0.0 or ca[0] < 0.0:
            raise DeckFormatError(
                f"{self._at(row)}: BODY requires Mass > 0 and non-negative Vol/CdA/Ca"
            )
        if any(v <= 0.0 for v in lists["I"]):
            raise DeckFormatError(f"{self._at(row)}: Rigid6 BODY inertias must be positive")

    def _rod_rows_by_id(self) -> dict[int, tuple[str, int]]:
        """Return each well-formed RODS row's (attachment kind, NumSegs) by rod id.

        A tolerant pre-scan for the rod-end resolution; ``validate`` checks the
        rows themselves.
        """
        rods: dict[int, tuple[str, int]] = {}
        for row in self._rows("RODS"):
            if len(row.tokens) not in {10, 11}:
                continue
            try:
                rod_id, segments = _native_int(row.tokens[0]), _native_int(row.tokens[9])
            except ValueError:
                continue
            kind = _ROD_ATTACHMENT_ALIASES.get(row.tokens[2].lower(), row.tokens[2].lower())
            rods.setdefault(rod_id, (kind, segments))
        return rods

    def _resolve_rod_ends(
        self, point_types: dict[str, str], point_ids: set[str], point_z: dict[str, float]
    ) -> tuple[dict[str, str], dict[str, str]]:
        """Mirror the native rod-end binding.

        Returns the line attachment key of every rod end, and the POINT ids that a
        zero-length rod merges into its connector point (dropped id -> connector id).

        Native ``resolve_rod_end_tokens`` binds an ``R<N>A``/``Rod<N>A`` line end to the
        ``Rod<N>A`` POINT row when one exists (else to an implicit point), and turns the
        end points of a rod fixed to a body (RODS type ``Body<M>``) into ``Body<M>``
        points. Native ``collapse_zero_length_rods`` first merges both ends of a
        zero-length rod (NumSegs 0) into one connector point typed after the rod:
        Free, Fixed (fixed or pinned rod), Coupled (coupled or CoupledPinned rod), or
        ``Body<M>``. ``point_types``,
        ``point_ids`` and ``point_z`` are updated in place.
        """
        merged: dict[str, str] = {}
        rods = self._rod_rows_by_id()
        body_ids: set[int] = set()
        for row in self._rows("BODIES"):
            with contextlib.suppress(ValueError, IndexError):
                body_ids.add(_native_int(row.tokens[0]))
        # rod end -> the POINT row (id) that carries it, in file order
        keys: dict[str, str] = {}
        for row in self.points:
            rod_point = _rod_point(row.tokens[1].lower())
            if rod_point is not None:
                keys.setdefault(f"rod{rod_point[0]}{rod_point[1]}", str(_native_int(row.tokens[0])))
        # implicit points for rod ends named only by LINES rows
        for row in self.lines:
            for token in row.tokens[2:4] if len(row.tokens) == 7 else row.tokens[1:3]:
                rod_end = _rod_end_token(token)
                if rod_end is not None and rod_end not in keys:
                    keys[rod_end] = rod_end
                    point_ids.add(rod_end)
                    point_types[rod_end] = rod_end
                    point_z[rod_end] = 0.0
        for rod_id, (kind, segments) in rods.items():
            ends = [end for end in (f"rod{rod_id}a", f"rod{rod_id}b") if end in keys]
            body = re.fullmatch(r"body([0-9]+)((?:pin|pinned)?)", kind)
            if segments == 0 and ends:
                # both ends become the connector point of the first end present
                connector = keys[ends[0]]
                for end in ends:
                    if keys[end] != connector:
                        merged[keys[end]] = connector
                    keys[end] = connector
                if kind in {"free", "fixed", "coupled"}:
                    resolved = kind
                elif kind == "pinned":
                    resolved = "fixed"
                elif kind in {"vessel", "coupledpinned"}:
                    # a zero-length CoupledPinned rod is a Coupled point on the coupled
                    # route (and refused elsewhere, see the RODS checks)
                    resolved = "coupled"
                elif body is not None:
                    resolved = f"body{_native_id_suffix(body.group(1))}"
                else:
                    resolved = kind
                point_types[connector] = resolved
            elif body is not None and not body.group(2):
                if _native_id_suffix(body.group(1)) in body_ids:
                    for end in ends:
                        point_types[keys[end]] = f"body{_native_id_suffix(body.group(1))}"
        return keys, merged

    def _check_attachments(
        self,
        line_ids: set[str],
        section_types_by_line: dict[str, list[str]],
        line_type_meta: dict[str, tuple[float, float, float, float]],
        line_lengths: dict[str, float],
    ) -> None:
        """Native ``append_line_attachment`` and its finalize checks for ATTACHMENTS rows."""
        for row in self._rows("ATTACHMENTS"):
            where = self._at(row)
            if len(row.tokens) not in {6, 7}:
                raise DeckFormatError(
                    f"{where}: ATTACHMENTS rows must be: LineID ArcLength Mass Volume CdA Ca [CdAx]"
                )
            try:
                line_id = str(_native_int(row.tokens[0]))
            except ValueError as exc:
                raise DeckFormatError(f"{where}: ATTACHMENTS LineID must be an integer") from exc
            if line_id not in line_ids:
                raise DeckFormatError(f"{where}: ATTACHMENTS row references undefined LINE id")
            try:
                values = [_native_float(token) for token in row.tokens[2:]]
            except ValueError as exc:
                raise DeckFormatError(
                    f"{where}: ATTACHMENTS Mass, Volume, CdA, Ca and CdAx must be plain numbers"
                ) from exc
            if not all(math.isfinite(value) and value >= 0.0 for value in values):
                raise DeckFormatError(
                    f"{where}: ATTACHMENTS Mass, Volume, CdA, Ca and CdAx must be finite and >= 0"
                )
            if not any(value > 0.0 for value in (*values[:3], *values[4:])):
                raise DeckFormatError(
                    f"{where}: an ATTACHMENTS row needs a positive Mass, Volume, CdA or CdAx"
                )
            parts = row.tokens[1].split(":")
            try:
                if len(parts) == 1:
                    first = last = _native_float(parts[0])
                    pitch = 1.0
                elif len(parts) == 3:
                    first, pitch, last = (_native_float(part) for part in parts)
                else:
                    raise ValueError(row.tokens[1])
            except ValueError as exc:
                raise DeckFormatError(
                    f"{where}: ATTACHMENTS ArcLength must be a value >= 0 or a series "
                    "first:pitch:last with 0 <= first <= last and pitch > 0"
                ) from exc
            if not (
                all(math.isfinite(value) for value in (first, pitch, last))
                and 0.0 <= first <= last
                and pitch > 0.0
            ):
                raise DeckFormatError(
                    f"{where}: ATTACHMENTS ArcLength must be a value >= 0 or a series "
                    "first:pitch:last with 0 <= first <= last and pitch > 0"
                )
            if (last - first) / pitch > 100000:
                raise DeckFormatError(
                    f"{where}: an ATTACHMENTS series may hold at most 100000 attachments"
                )
            if not any(
                line_type_meta[name][3] > 0.0
                for name in section_types_by_line.get(line_id, [])
                if name in line_type_meta
            ):
                raise DeckFormatError(
                    f"{where}: ATTACHMENTS name a line that is not a finite-EI line; on an "
                    "EI = 0 line use a Point at a line end"
                )
            # native append_line_attachment expands the series; finalize_checks then keeps
            # every arc length on the unstretched line
            steps = (last - first) / pitch
            top = first + int(steps + 1.0e-9 * max(1.0, steps)) * pitch
            if top > line_lengths[line_id] * (1.0 + 1.0e-12) + 1.0e-9:
                raise DeckFormatError(
                    f"{where}: ATTACHMENTS ArcLength lies beyond the end of line {line_id} "
                    f"(unstretched length {line_lengths[line_id]:.10g} m)"
                )

    def _check_stiffeners(
        self,
        line_ids: set[str],
        section_types_by_line: dict[str, list[str]],
        line_type_meta: dict[str, tuple[float, float, float, float]],
        line_lengths: dict[str, float],
    ) -> None:
        """Native ``append_line_stiffener`` and its finalize checks for STIFFENERS rows.

        A row ``LineID End Length RootOD TipOD InnerD E Density`` is one conical segment of the
        bend stiffener sleeving End A or End B; the rows of one line end follow each other
        outward from the root. The stiffeners of both ends together must fit on the line.
        """
        extent: dict[tuple[str, str], float] = {}
        for row in self._rows("STIFFENERS"):
            where = self._at(row)
            if len(row.tokens) != 8:
                raise DeckFormatError(
                    f"{where}: STIFFENERS rows must be: "
                    "LineID End Length RootOD TipOD InnerD E Density"
                )
            try:
                line_id = str(_native_int(row.tokens[0]))
            except ValueError as exc:
                raise DeckFormatError(f"{where}: STIFFENERS LineID must be an integer") from exc
            if line_id not in line_ids:
                raise DeckFormatError(
                    f"{where}: STIFFENERS row references undefined LINE id {line_id}"
                )
            end = {"a": "a", "enda": "a", "b": "b", "endb": "b"}.get(row.tokens[1].lower())
            if end is None:
                raise DeckFormatError(f"{where}: STIFFENERS End must be A or B")
            try:
                length, root_od, tip_od, inner_d, modulus, density = (
                    _native_float(token) for token in row.tokens[2:]
                )
            except ValueError as exc:
                raise DeckFormatError(
                    f"{where}: STIFFENERS Length, RootOD, TipOD, InnerD, E and Density must be "
                    "plain numbers"
                ) from exc
            values = (length, root_od, tip_od, inner_d, modulus, density)
            if not all(
                math.isfinite(value) and value <= _NATIVE_MAX_COEFFICIENT for value in values
            ):
                raise DeckFormatError(
                    f"{where}: STIFFENERS Length, RootOD, TipOD, InnerD, E and Density must be "
                    "finite and at most 1e15"
                )
            if not (length > 0.0 and root_od > 0.0 and tip_od > 0.0 and modulus > 0.0):
                raise DeckFormatError(
                    f"{where}: STIFFENERS Length, RootOD, TipOD and E must be > 0"
                )
            if inner_d < 0.0 or density < 0.0:
                raise DeckFormatError(f"{where}: STIFFENERS InnerD and Density must be >= 0")
            if not inner_d < min(root_od, tip_od):
                raise DeckFormatError(
                    f"{where}: STIFFENERS InnerD must be smaller than RootOD and TipOD"
                )
            # as wide as the widest line type at most (native, LINE TYPES Diam <= 1e3 m)
            if max(root_od, tip_od) > _NATIVE_MAX_DIAMETER:
                raise DeckFormatError(
                    f"{where}: STIFFENERS RootOD and TipOD must be at most 1e3 m, as a line "
                    "type's Diam"
                )
            extent[(line_id, end)] = extent.get((line_id, end), 0.0) + length
        for line_id in sorted({key[0] for key in extent}, key=int):
            if not any(
                line_type_meta[name][3] > 0.0
                for name in section_types_by_line.get(line_id, [])
                if name in line_type_meta
            ):
                raise DeckFormatError(
                    f"{self._label}: STIFFENERS name line {line_id}, which is not a finite-EI "
                    "line: a stiffener adds bending stiffness, which an EI = 0 line does not have"
                )
            total = extent.get((line_id, "a"), 0.0) + extent.get((line_id, "b"), 0.0)
            if total > line_lengths[line_id] * (1.0 + 1.0e-12):
                raise DeckFormatError(
                    f"{self._label}: the STIFFENERS of line {line_id} are longer than the line "
                    "(End A and End B stiffeners together)"
                )

    def _legacy_rod_type_columns(self, record: DeckRecord) -> bool:
        """Return whether ``record`` sits under a legacy CableDyn ROD TYPES header.

        Columns 6-7 are MoorDyn's ``CdEnd CaEnd``. The native reader marks the
        section as legacy when a header row (no numeric token) names an axial
        coefficient in column 6 or 7, and clears it when that column names an end
        coefficient; its data rows are then rejected with a migration message.
        """
        legacy = False
        for index in self._section_indices("ROD TYPES"):
            if index >= record.index:
                break
            tokens = _row_tokens(_strip_inline_comment(self._lines[index]).strip(_WHITESPACE))
            if not tokens or _has_numeric_token(tokens):
                continue
            for name in tokens[5:7]:
                if name.lower() in _LEGACY_ROD_AXIAL_NAMES:
                    legacy = True
                    break
                if name.lower() in _ROD_END_NAMES:
                    legacy = False
                    break
        return legacy

    @property
    def line_types(self) -> tuple[DeckRecord, ...]:
        """Data rows of the ``LINE TYPES`` section, in file order."""
        return self._rows("LINE TYPES")

    @property
    def points(self) -> tuple[DeckRecord, ...]:
        """Data rows of the ``POINTS`` section, in file order."""
        return self._rows("POINTS")

    @property
    def lines(self) -> tuple[DeckRecord, ...]:
        """Data rows of the ``LINES`` section, in file order."""
        return self._rows("LINES")

    @property
    def sections(self) -> tuple[DeckRecord, ...]:
        """Data rows of the ``SECTIONS`` section, in file order."""
        return self._rows("SECTIONS")

    @property
    def end_connections(self) -> tuple[DeckRecord, ...]:
        """Data rows of the ``END CONNECTIONS`` section, in file order."""
        return self._rows("END CONNECTIONS")

    @property
    def outputs(self) -> tuple[str, ...]:
        """Output channel names from the ``OUTPUTS`` section, in file order."""
        result: list[str] = []
        # Native append_channel: each channel is one output column, so a channel
        # requested twice (also through an alias spelling) fails closed.
        seen: dict[str, str] = {}
        for start, stop in self._sections.get("OUTPUTS", ()):
            for index in range(start, stop):
                visible = _strip_inline_comment(self._lines[index]).strip(_WHITESPACE)
                if not visible:
                    continue
                if _quoted_row_tokens(visible)[0].lower() == "end":
                    # A bare END closes the channel list until the next header.
                    break
                # Native append_channel: quotes, commas, and whitespace all separate names.
                for name in re.sub(r"[\"',\t\r\n\f\v]", " ", visible).split(" "):
                    if not name:
                        continue
                    if len(name) > _NATIVE_NAME_LENGTH:
                        raise DeckFormatError(
                            f"{self._label}:{index + 1}: OUTPUTS channel name {name!r} is "
                            f"longer than {_NATIVE_NAME_LENGTH} characters"
                        )
                    key = _channel_identity_key(name)
                    if key in seen:
                        raise DeckFormatError(
                            f"{self._label}:{index + 1}: OUTPUTS channel {name!r} duplicates "
                            f"the earlier channel {seen[key]!r} (each channel may be "
                            "requested once)"
                        )
                    seen[key] = name
                    result.append(name)
        return tuple(result)

    def _option_row(self, index: int) -> OptionRecord | None:
        """Parse one OPTIONS record with the native ``apply_option`` rules."""
        line = _strip_inline_comment(self._lines[index]).strip(_WHITESPACE)
        if not line:
            return None
        where = f"{self._label}:{index + 1}"
        visible, description = line, None
        separator = re.search(r"[ \t\r\n\f\v]-[ \t\r\n\f\v]", line)
        if separator is not None:
            visible = line[: separator.start()]
            description = line[separator.end() :].strip(_WHITESPACE) or None
        tokens = _row_tokens(visible)
        if len(tokens) < 2:
            raise DeckFormatError(f"{where}: malformed OPTIONS row (needs value keyword)")
        if tokens[0].lower() == "dynamic_solver" and len(tokens) in {5, 6}:
            if not _dynamic_solver_values_are_valid(tokens[1:]):
                raise DeckFormatError(
                    f"{where}: dynamic_solver needs positive finite tolerances, "
                    "max_iter >= 1, backtracks >= 0, and optional rhoInf in [0, 1]"
                )
            _raise_option_defect(where, tokens)
            return OptionRecord(index, tokens[0], tuple(tokens[1:]), description, True)
        if _is_positional_option(tokens):
            if not _positional_numbers_are_finite(tokens):
                raise DeckFormatError(
                    f"{where}: positional option values must be finite plain numbers"
                )
            # the magnitude bounds apply to the row in effect only (``_validate``)
            if error := _positional_range_error(tokens, effective=False):
                raise DeckFormatError(f"{where}: {error}")
            _raise_option_defect(where, tokens)
            return OptionRecord(index, tokens[-1], tuple(tokens[:-1]), description)
        if len(tokens) >= 4 and tokens[0].lower() in _POSITIONAL_ROW_STARTS:
            raise DeckFormatError(
                f"{where}: OPTIONS row {tokens[0]!r} ... is a positional "
                "waves/current/dynamic_solver row with the wrong number of values, or with text "
                "after its keyword; write a description after ' - '"
            )
        keyword = tokens[1]
        if keyword.lower() in {"mu_kt", "mu_ka"}:
            raise DeckFormatError(
                f"{where}: OPTION {keyword} is the MoorDyn-F seabed friction coefficient; "
                "CableDyn reads frictionMu (with frictionMuLateral for mu_kT and "
                "frictionMuAxial for mu_kA)"
            )
        if keyword.lower() in {"mc", "cv", "fricdamp", "statdynfricscale"}:
            raise DeckFormatError(
                f"{where}: OPTION {keyword} (MoorDyn static-to-kinetic friction ratio or "
                "friction damping) has no CableDyn equivalent: CableDyn applies one regularised "
                "Coulomb friction set by frictionMu, frictionMuLateral and frictionMuAxial; "
                "remove the row"
            )
        if not _is_scalar_option_keyword(keyword):
            raise DeckFormatError(f"{where}: unknown OPTION keyword {keyword!r}")
        if error := _scalar_option_value_error(keyword, tokens[0]):
            raise DeckFormatError(f"{where}: OPTION {keyword} {error}")
        if keyword.lower() == "inertialf" and _native_float(tokens[0]) != 1.0:
            # native apply_option: CableDyn always returns the coupled objects' inertia
            raise DeckFormatError(f"{where}: OPTION inertialF {tokens[0]}: {_INERTIAL_F_MESSAGE}")
        _raise_option_defect(where, tokens)
        value = _strip_quotes(tokens[0]) if keyword.lower() in _PATH_OPTIONS else tokens[0]
        return OptionRecord(index, keyword, (value,), description, False, tuple(tokens[2:]))

    @property
    def options(self) -> tuple[OptionRecord, ...]:
        """Every row of the ``OPTIONS`` section, in file order.

        A keyword may appear more than once; the last row is the effective one.
        """
        result: list[OptionRecord] = []
        for index in self._section_indices("OPTIONS"):
            record = self._option_row(index)
            if record is not None:
                result.append(record)
        return tuple(result)

    def option(self, keyword: str) -> OptionRecord:
        """Return the effective (last) row for ``keyword`` or any native alias of it.

        Matching is case-insensitive, and native aliases are equivalent: for
        example ``g`` and ``gravity``, or ``dt`` and ``dtM``.

        Parameters
        ----------
        keyword : str
            Option keyword or native alias.

        Returns
        -------
        OptionRecord
            The last row that sets the option. Values are the deck tokens in
            the option's SI unit; path-valued options are dequoted, as the
            native reader does.

        Raises
        ------
        KeyError
            If the deck sets neither the keyword nor any alias of it.
        """
        key = _option_key(keyword)
        matches = [record for record in self.options if _option_key(record.keyword) == key]
        if not matches:
            raise KeyError(f"option {keyword!r} is not in {self._label}")
        return matches[-1]

    def validate(self) -> None:
        """Validate the object graph without pretending to replace native physics checks.

        Checks section structure, row syntax, option values, and cross-references
        between rows. A deck that passes can still be rejected by the solver on
        physical grounds.

        The ancillary files a deck names (WaterKin and its wave record, the
        MoorDyn-C kinematics files, motion and vessel records, the RAO table,
        bathymetry, and the Syrope settings and OWC table) are read from the
        deck's folder, with the rules of their native readers. A file that is
        not there, as for a deck held in memory under its nominal path, is not
        an error at this stage: the deck passes these checks and the solver,
        which must open the file, refuses it by name if it is still missing.

        Raises
        ------
        DeckFormatError
            If the deck violates the native deck contract.
        """
        try:
            self._validate()
        except DeckFormatError as exc:
            if self.caller_driven or not any(cue in str(exc) for cue in _STATIC_CHECK_CUES):
                raise
            # native finalize_and_validate: a standalone deck without TMax that asks for the
            # march is told how to check its static start
            try:
                self.option("TMax")
            except KeyError:
                raise DeckFormatError(f"{exc}{_STATIC_CHECK_HINT}") from None
            raise

    def _validate(self) -> None:
        required = {"LINE TYPES", "POINTS", "LINES"}
        if not self._rows("LINES") and (self._rows("RODS") or self._rows("BODIES")):
            # native finalize_and_validate: a deck whose rows declare bodies or rods and
            # no line needs no line tables (the rule counts rows, not section headers)
            required = set()
        absent = required.difference(self._sections)
        if absent:
            raise DeckFormatError(f"{self._label}: missing {', '.join(sorted(absent))} section(s)")
        # Optional sections still belong to the native syntax contract. Parse them
        # eagerly so ``validate`` cannot report success for errors that would only
        # surface later through a property access.
        options = self.options
        channels = self.outputs
        option_by_key = {_option_key(option.keyword): option for option in options}
        # native finalize_checks: the magnitude bounds of the waves and current rows in
        # effect (the last of each); a row a later row overrides takes its row rules only
        for overridden_kind in ("waves", "current"):
            record = option_by_key.get(overridden_kind)
            if record is None or record.keyword_first:
                continue
            tokens = [*record.values, record.keyword]
            if _is_positional_option(tokens) and (error := _positional_range_error(tokens)):
                raise DeckFormatError(f"{self._label}:{record.index + 1}: {error}")
        has_depth = "water_depth" in option_by_key
        has_bathymetry = "bathymetry" in option_by_key
        if has_depth and has_bathymetry:
            raise DeckFormatError(
                f"{self._label}: OPTIONS WtrDpth and bathymetryFile are mutually exclusive"
            )
        kbot = option_by_key.get("kbot")
        if (
            (has_depth or has_bathymetry)
            and kbot is not None
            and _native_float(kbot.values[0]) <= 0.0
        ):
            raise DeckFormatError(
                f"{self._label}: OPTION kBot must be positive when seabed contact is enabled"
            )
        cbot = option_by_key.get("cbot")
        if (
            (has_depth or has_bathymetry)
            and cbot is not None
            and _native_float(cbot.values[0]) < 0.0
        ):
            raise DeckFormatError(
                f"{self._label}: OPTION cBot must be non-negative when seabed contact is enabled"
            )

        # native finalize_checks: admissible magnitudes of the effective environment
        def effective(key: str, default: float) -> float:
            return _native_float(option_by_key[key].values[0]) if key in option_by_key else default

        if (
            effective("gravity", 9.80665) > _NATIVE_MAX_GRAVITY
            or effective("water_density", 1025.0) > _NATIVE_MAX_WATER_DENSITY
        ):
            raise DeckFormatError(
                f"{self._label}: OPTIONS g must be at most 1e3 m/s^2 and rhoW at most 1e5 kg/m^3"
            )
        if has_depth and effective("water_depth", 0.0) > _NATIVE_MAX_COORDINATE:
            raise DeckFormatError(f"{self._label}: OPTION WtrDpth must be at most 1e6 m")
        if max(abs(effective("kbot", 0.0)), abs(effective("cbot", 0.0))) > _NATIVE_MAX_COEFFICIENT:
            raise DeckFormatError(
                f"{self._label}: OPTIONS kBot and cBot must be at most 1e15 in magnitude"
            )
        has_dtm = "dtm" in option_by_key
        has_tmax = "tmax" in option_by_key
        # native parse_deck: a static check marches no step, so standalone TMax = 0 needs no dtM
        static_check = (
            not self.caller_driven
            and has_tmax
            and not has_dtm
            and _native_float(option_by_key["tmax"].values[0]) == 0.0
        )
        if not self.caller_driven and has_dtm != has_tmax and not static_check:
            raise DeckFormatError(
                f"{self._label}: standalone dynamic run requires both dtM and TMax options"
            )
        if has_dtm and has_tmax:
            dtm = _native_float(option_by_key["dtm"].values[0])
            tmax = _native_float(option_by_key["tmax"].values[0])
            ratio = tmax / dtm
            # Native grid_step_count: the step count must fit the driver's counter
            # (a subnormal dtM makes the ratio overflow to infinity).
            if not math.isfinite(ratio) or ratio > _NATIVE_MAX_STEPS:
                raise DeckFormatError(
                    f"{self._label}: OPTIONS TMax/dtM needs more than {_NATIVE_MAX_STEPS} "
                    "time steps; increase dtM or reduce TMax"
                )
            steps = round(ratio)
            if abs(steps * dtm - tmax) > 100.0 * math.ulp(1.0) * max(1.0, tmax):
                raise DeckFormatError(
                    f"{self._label}: OPTION TMax must be an integer multiple of dtM"
                )
        has_dtm = has_dtm or static_check
        # MoorDyn-C WaveKin 3/7 and Currents 1/2/5 (native read_moordyn_c_kinematics): component
        # waves and a current profile or grid read from fixed-name files in the deck folder.
        # The coupled aggregate takes its water kinematics from the host and rejects both.
        waterkin_row = option_by_key.get("waterkin")
        currents_row = option_by_key.get("currents")
        mdc_wave_kin = _moordyn_c_wave_kin(None if waterkin_row is None else waterkin_row.values[0])
        mdc_currents = _moordyn_c_currents(None if currents_row is None else currents_row.values[0])
        if self.caller_driven and (mdc_wave_kin or mdc_currents):
            raise DeckFormatError(
                f"{self._label}: the MoorDyn-C WaveKin 3/7 and Currents 1/2/5 files are not "
                "supported on the coupled route (coupled runs take water kinematics from the host)"
            )
        # Native apply_option: motionFile, vesselMotion and vesselRAO are alternative
        # sources of one prescribed motion; activating a second one is an error, and a
        # disabling row (0/none) clears only the active source of its own keyword.
        motion_source: str | None = None
        for option in options:
            keyword = option.keyword.lower()
            if keyword not in _MOTION_SOURCE_KEYWORDS:
                continue
            if option.values[0].lower() in _DISABLED_MOTION_FILE_VALUES:
                if motion_source == keyword:
                    motion_source = None
            elif motion_source is not None and motion_source != keyword:
                raise DeckFormatError(
                    f"{self._label}: OPTIONS motionFile, vesselMotion and vesselRAO are "
                    "alternative prescribed-motion sources; give only one"
                )
            else:
                motion_source = keyword
        has_motion_file = motion_source is not None
        if has_motion_file and not has_dtm:
            raise DeckFormatError(f"{self._label}: OPTION motionFile requires dtM")
        if motion_source in {"vesselmotion", "vesselrao"}:
            if self._rows("TURBINES"):
                raise DeckFormatError(
                    f"{self._label}: OPTIONS vesselMotion/vesselRAO do not apply to a TURBINES "
                    "deck; use its per-turbine motionFile records"
                )
            waves_option = option_by_key.get("waves")
            has_deck_waves = waves_option is not None and waves_option.values[0].lower() != "none"
            waterkin_option = option_by_key.get("waterkin")
            waterkin_value = "" if waterkin_option is None else waterkin_option.values[0]
            # A WaterKin file may carry the waves (its WaveKinMod is read at run time).
            has_waterkin_file = waterkin_value.lower() not in {"", "none", "seastate"} and any(
                character in _WATERKIN_FILENAME_LETTERS for character in waterkin_value
            )
            if has_waterkin_file and motion_source == "vesselrao":
                has_waterkin_file = self._waterkin_wave_mode(waterkin_value) in {None, 1}
            has_trains = any(o.keyword.lower() in _WAVETRAIN_KEYWORDS for o in options)
            # WaveKin 3/7 installs linear component waves (native has_wave)
            if motion_source == "vesselrao" and not (
                has_deck_waves or has_trains or has_waterkin_file or mdc_wave_kin
            ):
                raise DeckFormatError(
                    f"{self._label}: OPTION vesselRAO needs deck waves (airy, a spectral sea, wave "
                    "trains, or a WaterKin WaveKinMod 1 file)"
                )
            if (
                motion_source == "vesselrao"
                and has_deck_waves
                and waves_option is not None
                and waves_option.values[0].lower() in {"stream", "dean"}
            ):
                raise DeckFormatError(
                    f"{self._label}: OPTION vesselRAO needs linear deck waves; a nonlinear "
                    "stream-function wave has no linear components to apply RAOs to"
                )
        current = option_by_key.get("current")
        # A caller-driven deck takes its clock from the host, as for frictionMu.
        if (
            current is not None
            and current.values[0].lower() != "none"
            and not self.caller_driven
            and not has_dtm
        ):
            raise DeckFormatError(f"{self._label}: standalone OPTION current requires dtM and TMax")
        waves = option_by_key.get("waves")
        has_waves = waves is not None and waves.values[0].lower() != "none"
        if has_waves and not (has_dtm and has_depth):
            raise DeckFormatError(f"{self._label}: OPTION waves requires dtM and WtrDpth")
        # native resolve_deck_sea
        trains = [o for o in options if o.keyword.lower() in _WAVETRAIN_KEYWORDS]
        spreading = option_by_key.get("wave_spreading")
        spread = spreading is not None and _native_float(spreading.values[0]) > 0.0
        if len(trains) > 16:
            raise DeckFormatError(f"{self._label}: too many wave trains (at most 16)")
        if trains:
            if not (has_dtm and has_depth):
                raise DeckFormatError(f"{self._label}: OPTION wavetrain requires dtM and WtrDpth")
            if has_waves:
                raise DeckFormatError(
                    f"{self._label}: OPTIONS declare both wavetrain rows and a waves row; keep one"
                )
            if spread:
                raise DeckFormatError(
                    f"{self._label}: OPTION WaveSpreading applies to a waves row; "
                    "a wavetrain row carries its own spreading exponent"
                )
        elif spread and not (
            waves is not None
            and has_waves
            and waves.values[0].lower() not in {"airy", "stream", "dean"}
        ):
            raise DeckFormatError(f"{self._label}: OPTION WaveSpreading needs a spectral waves row")
        components_row = option_by_key.get("wave_components")
        components = (
            200 if components_row is None else round(_native_float(components_row.values[0]))
        )
        directions_row = option_by_key.get("wave_directions")
        if (
            directions_row is not None
            and components * round(_native_float(directions_row.values[0])) > 100000
        ):
            raise DeckFormatError(
                f"{self._label}: OPTIONS WaveComponents x WaveDirections must be at most 100000 "
                "wave components"
            )
        # A JONSWAP waves row with WaveSpreading > 0 or a non-default WaveComponents becomes
        # a one-train sea (native resolve_deck_sea, CD_Sea_Validate_Train); the row's gamma
        # bound applies on every path (_positional_range_error).
        if (
            waves is not None
            and has_waves
            and waves.values[0].lower() == "jonswap"
            and (spread or components != 200)
            and abs(_native_float(waves.values[4])) > _NATIVE_MAX_COORDINATE
        ):
            raise DeckFormatError(f"{self._label}: a wave train needs |direction| <= 1e6 deg")
        # native read_moordyn_c_kinematics: WaveKin 3/7 components add to no other deck sea,
        # and Currents 1/2/5 to no other current; each then needs the dynamic sea/current setup.
        if mdc_wave_kin:
            if has_waves or trains:
                raise DeckFormatError(
                    f"{self._label}: the deck declares both a waves (or wavetrain) OPTION and "
                    f"WaveKin {mdc_wave_kin} (double-counting); keep one"
                )
            if not (has_dtm and has_depth):
                raise DeckFormatError(
                    f"{self._label}: WaveKin {mdc_wave_kin} waves require dtM, TMax and WtrDpth"
                )
            if mdc_wave_kin == 7:
                self._check_wave_frequencies(_native_float(option_by_key["water_depth"].values[0]))
        # native validation: WaveRefX and WaveRefY place the phases of component waves alone,
        # which a WaterKin file carries under WaveKinMod 1.
        # The bound applies to the value in force: a later row of an option replaces an earlier one.
        wave_ref_rows = {
            o.keyword.lower(): o for o in options if o.keyword.lower() in {"waverefx", "waverefy"}
        }
        if wave_ref_rows:
            if any(
                abs(_native_float(o.values[0])) > _NATIVE_MAX_COORDINATE
                for o in wave_ref_rows.values()
            ):
                raise DeckFormatError(
                    f"{self._label}: WaveRefX and WaveRefY must be at most 1e6 m in magnitude"
                )
            waterkin_ref = option_by_key.get("waterkin")
            waterkin_text = "" if waterkin_ref is None else waterkin_ref.values[0]
            has_record = bool(mdc_wave_kin) or (
                waterkin_text.lower() not in {"", "none", "seastate"}
                and any(character in _WATERKIN_FILENAME_LETTERS for character in waterkin_text)
                and self._waterkin_wave_mode(waterkin_text) in {None, 1}
            )
            if self.caller_driven or has_waves or trains or not has_record:
                raise DeckFormatError(
                    f"{self._label}: WaveRefX and WaveRefY place the reference point of an "
                    "elevation record or a component file (WaterKin WaveKinMod 1, WaveKin 3 or 7); "
                    "this deck has none"
                )
        if mdc_currents:
            if current is not None and current.values[0].lower() != "none":
                raise DeckFormatError(
                    f"{self._label}: the deck declares both a current OPTION and Currents "
                    f"{mdc_currents} (double-counting); keep one"
                )
            if not has_dtm:
                raise DeckFormatError(
                    f"{self._label}: standalone Currents {mdc_currents} requires dtM and TMax"
                )
        friction = option_by_key.get("friction")
        friction_active = False
        iso = 0.0
        if friction is not None and friction.values[0].lower() != "none":
            iso = _native_float(friction.values[0])
            friction_active = iso > 0.0
        # native resolve_deck_friction: the axial/lateral pair, an omitted one = frictionMu
        axial_row = option_by_key.get("friction_axial")
        lateral_row = option_by_key.get("friction_lateral")
        if axial_row is not None or lateral_row is not None:
            mu_a = _native_float(axial_row.values[0]) if axial_row is not None else iso
            mu_n = _native_float(lateral_row.values[0]) if lateral_row is not None else iso
            if (mu_a > 0.0) != (mu_n > 0.0):
                raise DeckFormatError(
                    f"{self._label}: anisotropic seabed friction needs both the axial and the "
                    "lateral coefficient positive"
                )
            friction_active = mu_n > 0.0
        if friction_active and not (has_depth or has_bathymetry):
            raise DeckFormatError(
                f"{self._label}: OPTION frictionMu requires WtrDpth or bathymetryFile"
            )
        if friction_active and not self.caller_driven and not has_dtm:
            raise DeckFormatError(
                f"{self._label}: standalone OPTION frictionMu requires dtM and TMax"
            )
        allowed_widths = {"LINE TYPES": {10, 11, 13, 14}, "POINTS": {5, 9}, "LINES": {3, 4, 7}}
        # Every row present is checked, also in a line-free deck of bodies and rods: the
        # native reader parses each table row whether or not a line uses it.
        for name in sorted(allowed_widths):
            rows = self._rows(name)
            if name in required and not rows:
                raise DeckFormatError(f"{self._label}: {name} section has no data rows")
            for row in rows:
                if len(row.tokens) not in allowed_widths[name]:
                    widths = ", ".join(str(width) for width in sorted(allowed_widths[name]))
                    raise DeckFormatError(f"{self._at(row)}: {name} row needs {widths} fields")

        def numeric(token: str, row: DeckRecord, field: str) -> float:
            try:
                value = _table_float(token)
            except ValueError as exc:
                raise DeckFormatError(f"{self._at(row)}: {field} must be numeric") from exc
            if not math.isfinite(value):
                raise DeckFormatError(f"{self._at(row)}: {field} must be finite")
            return value

        # name -> (Diam, MassDenInAir, static EA, EI) as written in LINE TYPES
        line_type_scales: dict[str, tuple[float, float]] = {}  # name -> (BA, max Cd/Ca)
        line_type_meta: dict[str, tuple[float, float, float, float]] = {}
        line_type_gj: dict[str, float] = {}  # name -> explicit GJ of a 14-column row, else 0
        viv_type_names: set[str] = set()
        for row in self.line_types:
            for index in (1, 2, *range(5, len(row.tokens))):
                if len(row.tokens) == 14 and index == 7:
                    continue  # the GJ column, GJ, GJ|K or GJ|K|Bt, is read below
                numeric(row.tokens[index], row, f"LINE TYPES column {index + 1}")
            ea_parts = row.tokens[3].split("|")
            ba_parts = row.tokens[4].split("|")
            is_syrope = ea_parts[0].lower().startswith("syrope:")
            if ea_parts[0].lower().startswith("syrope:"):
                if len(ea_parts) != 3 or not ea_parts[0][len("SYROPE:") :]:
                    raise DeckFormatError(
                        f"{self._at(row)}: Syrope EA needs SYROPE:<file>|alpha|beta"
                    )
                if len(ba_parts) != 2:
                    raise DeckFormatError(f"{self._at(row)}: Syrope BA needs BA_s|BA_d")
                syrope_ea = [
                    numeric(part, row, f"Syrope EA part {index}")
                    for index, part in enumerate(ea_parts[1:], start=2)
                ]
                if any(value <= 0.0 for value in syrope_ea):
                    raise DeckFormatError(
                        f"{self._at(row)}: Syrope alpha and beta must be positive"
                    )
                ea_static = syrope_ea[0]
            else:
                if not 1 <= len(ea_parts) <= 3:
                    raise DeckFormatError(f"{self._at(row)}: EA accepts one to three values")
                ea_values = [
                    numeric(part, row, f"EA part {index}")
                    for index, part in enumerate(ea_parts, start=1)
                ]
                ea_static = ea_values[0]
                if len(ea_values) == 2 and ea_values[1] <= ea_values[0]:
                    raise DeckFormatError(f"{self._at(row)}: viscoelastic Ed must exceed Es")
                if len(ea_values) == 3 and any(value <= 0.0 for value in ea_values[1:]):
                    raise DeckFormatError(
                        f"{self._at(row)}: load-dependent alphaMBL/vbeta must be positive"
                    )
            if not 1 <= len(ba_parts) <= min(len(ea_parts), 2):
                raise DeckFormatError(f"{self._at(row)}: BA has too many bar-separated values")
            ba_values = [
                numeric(part, row, f"BA part {index}")
                for index, part in enumerate(ba_parts, start=1)
            ]
            if len(ba_values) == 2 and ba_values[1] < 0.0:
                raise DeckFormatError(f"{self._at(row)}: dynamic damping Bd must be non-negative")
            if ea_parts[0].lower().startswith("syrope:") and (
                any(value < 0.0 for value in ba_values) or sum(ba_values) <= 0.0
            ):
                raise DeckFormatError(
                    f"{self._at(row)}: Syrope BA_s and BA_d must be non-negative "
                    "with a positive sum"
                )
            # Native append_type: drag and added-mass coefficients (columns 7-10, the last
            # four of a 14-column row, in either column order) must be non-negative.
            hydro_start = len(row.tokens) - 4 if len(row.tokens) == 14 else 6
            hydro = [
                numeric(row.tokens[index], row, f"LINE TYPES column {index + 1}")
                for index in range(hydro_start, hydro_start + 4)
            ]
            if any(value < 0.0 for value in hydro):
                raise DeckFormatError(
                    f"{self._at(row)}: LINE TYPES drag and added-mass coefficients "
                    "(Cd_n Cd_t Ca_n Ca_t) must be non-negative"
                )
            ei = numeric(row.tokens[5], row, "EI")
            if len(row.tokens) in (11, 13):
                # Native check_viv_columns: MoorDyn's cross-flow VIV columns Cl [dF cF]
                cl = numeric(row.tokens[10], row, "Cl")
                d_f, c_f = (
                    (numeric(row.tokens[11], row, "dF"), numeric(row.tokens[12], row, "cF"))
                    if len(row.tokens) == 13
                    else (0.08, 0.18)
                )
                if cl < 0.0:
                    raise DeckFormatError(
                        f"{self._at(row)}: LINE TYPES VIV lift coefficient Cl must be "
                        "non-negative (0 = VIV off)"
                    )
                if cl > 0.0 and not (c_f > 0.0 and 0.0 <= d_f < c_f):
                    raise DeckFormatError(
                        f"{self._at(row)}: LINE TYPES VIV synchronisation band needs cF > 0 "
                        "and 0 <= dF < cF"
                    )
                if cl > 0.0:
                    viv_type_names.add(row.tokens[0].lower())
            if ei > 0.0 and (is_syrope or len(ea_parts) > 1):
                model = "Syrope" if is_syrope else "viscoelastic stiffness"
                raise DeckFormatError(f"{self._at(row)}: {model} is not supported with EI > 0")
            gj_value = 0.0
            if len(row.tokens) == 14:
                # the GJ column is GJ, GJ|K or GJ|K|Bt (K the torque-tension coupling, N m;
                # Bt the torsional damping, N m^2 s, negative: -zeta)
                gj_parts = row.tokens[7].split("|")
                if len(gj_parts) > 3:
                    raise DeckFormatError(
                        f'{self._at(row)}: LINE TYPES GJ column "{row.tokens[7]}" takes GJ, GJ|K '
                        "or GJ|K|Bt"
                    )
                gj_value = numeric(gj_parts[0], row, "GJ")
                ktt = numeric(gj_parts[1], row, "GJ|K coupling") if len(gj_parts) >= 2 else 0.0
                btor = numeric(gj_parts[2], row, "GJ|K|Bt damping") if len(gj_parts) == 3 else 0.0
                finite_ei = [
                    numeric(row.tokens[6], row, "LINE TYPES column 7"),
                    gj_value,
                    numeric(row.tokens[8], row, "LINE TYPES column 9"),
                    numeric(row.tokens[9], row, "LINE TYPES column 10"),
                ]
                if any(value != 0.0 for value in finite_ei) and any(
                    value <= 0.0 for value in finite_ei
                ):
                    raise DeckFormatError(
                        f"{self._at(row)}: explicit GAs/GJ/Irt/Irn must all be positive"
                    )
                if ktt != 0.0:
                    name = row.tokens[0]
                    if not ei > 0.0:
                        raise DeckFormatError(
                            f"{self._at(row)}: LINE TYPES {name}: torque-tension coupling (GJ|K) "
                            "needs a finite-EI cable (EI > 0)"
                        )
                    if is_syrope or len(ea_parts) > 1:
                        raise DeckFormatError(
                            f"{self._at(row)}: LINE TYPES {name}: torque-tension coupling (GJ|K) "
                            "needs a linear-elastic EA"
                        )
                    if not (gj_value > 0.0 and ea_static * gj_value > ktt * ktt):
                        raise DeckFormatError(
                            f"{self._at(row)}: LINE TYPES {name}: torque-tension coupling needs "
                            "GJ > 0 and K^2 < EA GJ"
                        )
                if btor != 0.0 and not (ei > 0.0 and gj_value > 0.0 and finite_ei[3] > 0.0):
                    raise DeckFormatError(
                        f"{self._at(row)}: LINE TYPES {row.tokens[0]}: torsional damping (GJ|K|Bt) "
                        "needs a finite-EI cable with GJ > 0 and Irn > 0"
                    )
            line_type_meta[row.tokens[0].lower()] = (
                numeric(row.tokens[1], row, "Diam"),
                numeric(row.tokens[2], row, "Mass"),
                ea_static,
                ei,
            )
            line_type_gj[row.tokens[0].lower()] = gj_value
            # Syrope keeps its BA_s on the working-curve model (native BA slot = 0)
            line_type_scales[row.tokens[0].lower()] = (
                0.0 if is_syrope else ba_values[0],
                max(hydro),
            )

        turbines: set[int] = set()
        for row in self._rows("TURBINES"):
            # native append_turbine: J X0 Y0 Z0 [six PtfmInit displacements]
            if len(row.tokens) not in {4, 10}:
                raise DeckFormatError(f"{self._at(row)}: TURBINES row needs 4 or 10 fields")
            try:
                turbine = _native_int(row.tokens[0])
            except ValueError as exc:
                raise DeckFormatError(f"{self._at(row)}: TURBINES J must be an integer") from exc
            if not 1 <= turbine <= 10000 or turbine in turbines:
                raise DeckFormatError(
                    f"{self._at(row)}: TURBINES J must be unique and between 1 and 10000"
                )
            for index in range(1, len(row.tokens)):
                turbine_value = numeric(row.tokens[index], row, f"TURBINES column {index + 1}")
                if abs(turbine_value) > _NATIVE_MAX_COORDINATE:
                    raise DeckFormatError(
                        f"{self._at(row)}: TURBINES positions and angles must be at most 1e6 "
                        "in magnitude"
                    )
            turbines.add(turbine)
        for row in self.points:
            point_type = row.tokens[1].lower()
            # native append_point: admissible coordinate and load-column magnitudes
            point_values = [numeric(token, row, "POINTS value") for token in row.tokens[2:]]
            loads = point_values[3:] + [0.0] * (4 - len(point_values[3:]))
            if (
                any(abs(coordinate) > _NATIVE_MAX_COORDINATE for coordinate in point_values[:3])
                or max(abs(loads[0]), abs(loads[1]), abs(loads[2])) > _NATIVE_MAX_COEFFICIENT
                or abs(loads[3]) > _NATIVE_MAX_SMALL_COEFFICIENT
            ):
                raise DeckFormatError(
                    f"{self._at(row)}: POINTS row outside the admissible range (|X|, |Y|, |Z| "
                    "<= 1e6 m; |Mass|, |Vol|, |CdA| <= 1e15; |Ca| <= 1e3)"
                )
            if _is_turbine_point_type(point_type):
                if turbines and not self.caller_driven:
                    if _turbine_id(point_type) not in turbines:
                        raise DeckFormatError(
                            f"{self._at(row)}: POINT references a turbine without a TURBINES row"
                        )
                elif not self.caller_driven:
                    raise DeckFormatError(
                        f"{self._at(row)}: POINT type {row.tokens[1]!r}: Turbine<J> points need "
                        "a TURBINES section in the standalone driver (or the CompMooring=5 "
                        "aggregate path"
                    )
                if _turbine_id(point_type) < 1:
                    raise DeckFormatError(
                        f"{self._at(row)}: POINT type {row.tokens[1]!r} must carry "
                        "a positive 32-bit turbine number (Turbine<J>)"
                    )
            elif (
                point_type not in {"fixed", "coupled", "vessel", "connect", "free"}
                and not point_type.startswith("body")
                and _rod_point(point_type) is None
            ):
                raise DeckFormatError(f"{self._at(row)}: unknown POINT type {row.tokens[1]!r}")
            values = [
                numeric(row.tokens[index], row, f"POINTS column {index + 1}")
                for index in range(2, len(row.tokens))
            ]
            loads = values[3:7] if len(values) == 7 else [0.0] * 4
            if point_type in {"fixed", "coupled", "vessel"} or _is_turbine_point_type(point_type):
                if any(value != 0.0 for value in loads):
                    raise DeckFormatError(
                        f"{self._at(row)}: held POINT must not carry Mass/Vol/CdA/Ca"
                    )
            elif point_type in {"connect", "free"} and any(value < 0.0 for value in loads):
                raise DeckFormatError(
                    f"{self._at(row)}: Connect/Free POINT loads must be non-negative"
                )
            elif point_type.startswith(("body", "rod")) and any(value != 0.0 for value in loads):
                raise DeckFormatError(
                    f"{self._at(row)}: Body/Rod POINT must not carry Mass/Vol/CdA/Ca"
                )

        def unique(records: tuple[DeckRecord, ...], label: str, numeric: bool) -> set[str]:
            keys: list[str] = []
            for row in records:
                key = row.tokens[0].lower()
                if numeric:
                    try:
                        value = _native_int(row.tokens[0])
                    except ValueError as exc:
                        raise DeckFormatError(
                            f"{self._at(row)}: {label} id must be an integer"
                        ) from exc
                    if value < 1:
                        raise DeckFormatError(f"{self._at(row)}: {label} id must be positive")
                    key = str(value)
                keys.append(key)
            if len(keys) != len(set(keys)):
                raise DeckFormatError(f"{self._label}: duplicate {label} identifier")
            return set(keys)

        type_names = unique(self.line_types, "line type", False)
        if any(
            len(row.tokens) == 14 and self._stock_line_type_columns(row) for row in self.line_types
        ):
            raise DeckFormatError(
                f"{self._label}: 14-column LINE TYPES rows require CableDyn hydro-column order"
            )
        point_ids = unique(self.points, "point", True)
        point_types = {
            str(_native_int(row.tokens[0])): row.tokens[1].lower() for row in self.points
        }
        point_z = {
            str(_native_int(row.tokens[0])): _native_float(row.tokens[4]) for row in self.points
        }
        rod_end_keys, merged_points = self._resolve_rod_ends(point_types, point_ids, point_z)

        def end_key(token: str) -> str:
            """Canonical line attachment: a point id, or the point a rod end resolves to."""
            rod_end = _rod_end_token(token)
            if rod_end is not None:
                return rod_end_keys.get(rod_end, rod_end)
            point_id = str(_native_int(token))
            return merged_points.get(point_id, point_id)

        if has_depth and not self.caller_driven:
            # Native check_fixed_point_above_seabed. A caller-driven host may override
            # the deck depth, and structured bathymetry is not read here, so both
            # remain native-only checks.
            z_floor = -_native_float(option_by_key["water_depth"].values[0])
            # native CD_Static_Anchor_Seabed_Tolerance: an anchor within max(1 mm,
            # 1e-5 |z_floor|) of the seabed rests on it; a relative round-off margin
            # keeps an anchor written exactly one tolerance off inside
            tolerance = max(1.0e-3, 1.0e-5 * abs(z_floor))
            for row in self.points:
                z = _native_float(row.tokens[4])
                if (
                    row.tokens[1].lower() == "fixed"
                    and z < z_floor
                    and abs(z - z_floor) > tolerance * (1.0 + 1.0e-9)
                ):
                    raise DeckFormatError(
                        f"{self._at(row)}: POINT {_native_int(row.tokens[0])} (Fixed) lies "
                        f"below the seabed: z = {z:.10g} m is under the flat seabed "
                        f"z = -WtrDpth = {z_floor:.10g} m by more than the {tolerance:.2e} m "
                        "seabed tolerance; place the anchor on (or above) the seabed"
                    )
        has_dynamic_points = any(
            point_type in {"connect", "free"} or point_type.startswith(("body", "rod"))
            for point_type in point_types.values()
        )
        line_ids = unique(self.lines, "line", True)
        for option in options:
            line_option = _line_option(option.keyword)
            if line_option is not None and str(line_option[1]) not in line_ids:
                # native: layAzimuth<ID> / asLaidTension<ID> must name a LINE
                raise DeckFormatError(f"{self._label}: OPTION {option.keyword} names no LINE")
        section_lines: set[str] = set()
        section_types_by_line: dict[str, list[str]] = {line_id: [] for line_id in line_ids}
        line_nelems: dict[str, int] = dict.fromkeys(line_ids, 0)
        line_lengths: dict[str, float] = dict.fromkeys(line_ids, 0.0)
        normalized_line_endpoints: dict[str, tuple[str, str]] = {}
        # lines whose stock anchor-first row the native reader turns around (its ends swap)
        swapped_lines: set[str] = set()
        # native finite_ei_by_name (normalize_stock_endpoint_order): the lines whose SECTIONS
        # rows name a line type with EI > 0
        finite_ei_lines: set[str] = set()
        for section in self._rows("SECTIONS"):
            if len(section.tokens) < 2:
                continue
            meta = line_type_meta.get(section.tokens[1].lower())
            if meta is not None and meta[3] > 0.0:
                with contextlib.suppress(ValueError):
                    finite_ei_lines.add(str(_native_int(section.tokens[0])))
        range_lines = 0
        lift_lines = 0  # lines with the VIV lift file (flag V)
        # LINES whose End B is a moving point (row, line id, End B point type), checked below
        moving_b_lines: list[tuple[DeckRecord, str, str]] = []
        series_lines = 0  # lines with per-line time-series files (flags p, t, V)
        for row in self.lines:
            if len(row.tokens) not in {3, 4, 7}:
                raise DeckFormatError(f"{self._at(row)}: LINES row needs 3, 4, or 7 fields")
            output_flags = (
                row.tokens[6]
                if len(row.tokens) == 7
                else (row.tokens[3] if len(row.tokens) == 4 else "-")
            )
            # V (the VIV lift) is case-sensitive, as MoorDyn's v (node velocities) is not written
            if output_flags != "-" and not re.fullmatch(r"[pPtTrRV]+", output_flags):
                raise DeckFormatError(
                    f"{self._at(row)}: LINE Outputs accepts only '-', 'p', 't', 'r', and 'V'"
                )
            if "r" in output_flags.lower():
                range_lines += 1
            if "p" in output_flags.lower() or "t" in output_flags.lower() or "V" in output_flags:
                series_lines += 1
            if "V" in output_flags:
                lift_lines += 1
            if len(row.tokens) == 7:
                line_type = row.tokens[1]
                endpoints: tuple[str, ...] = row.tokens[2:4]
                if line_type.lower() not in type_names:
                    raise DeckFormatError(
                        f"{self._at(row)}: line references missing line type {line_type}"
                    )
                try:
                    length, segments = _native_float(row.tokens[4]), _native_int(row.tokens[5])
                except ValueError as exc:
                    raise DeckFormatError(
                        f"{self._at(row)}: stock line length/NumSegs is invalid"
                    ) from exc
                if (
                    not math.isfinite(length)
                    or length <= 0.0
                    or segments < 1
                    or segments > _NATIVE_MAX_SEGMENTS
                ):
                    raise DeckFormatError(
                        f"{self._at(row)}: stock line length must be positive and "
                        f"NumSegs must be between 1 and {_NATIVE_MAX_SEGMENTS}"
                    )
                _check_section_magnitude(length, segments, self._at(row))
                section_lines.add(str(_native_int(row.tokens[0])))
                section_types_by_line[str(_native_int(row.tokens[0]))].append(line_type.lower())
                line_nelems[str(_native_int(row.tokens[0]))] += segments
                line_lengths[str(_native_int(row.tokens[0]))] += length
            else:
                endpoints = row.tokens[1:3]
            try:
                canonical_endpoints = [end_key(endpoint) for endpoint in endpoints]
            except ValueError as exc:
                raise DeckFormatError(
                    f"{self._at(row)}: each line attachment must be a point id or a rod end"
                ) from exc
            if canonical_endpoints[0] == canonical_endpoints[1]:
                raise DeckFormatError(f"{self._at(row)}: LINE NodeA and NodeB must differ")
            for endpoint in endpoints:
                try:
                    endpoint_id = end_key(endpoint)
                except ValueError as exc:
                    raise DeckFormatError(
                        f"{self._at(row)}: line attachment {endpoint!r} must be a point id"
                    ) from exc
                if endpoint_id not in point_ids:
                    raise DeckFormatError(
                        f"{self._at(row)}: line references missing point {endpoint_id}"
                    )
            node_a, node_b = canonical_endpoints
            type_a, type_b = point_types[node_a], point_types[node_b]
            # Native normalize_stock_endpoint_order: a stock anchor-first line swaps
            # when NodeB is a fairlead (Coupled/Vessel/Body/Turbine), or a Free/Connect
            # point at or above the Fixed NodeA. A Fixed NodeA above a Free/Connect
            # NodeB is an elevated hang-off already in CableDyn (upper-end-first) order.
            # A finite-EI line to a rod end swaps too (it runs only from the rod, End A, to a
            # Fixed End B); an EI = 0 line to a rod end keeps its written order.
            line_key = str(_native_int(row.tokens[0]))
            line_is_finite_ei = line_key in finite_ei_lines or (
                len(row.tokens) == 7
                and line_type_meta.get(row.tokens[1].lower(), (0.0, 0.0, 0.0, 0.0))[3] > 0.0
            )
            upper_b = (
                type_b in {"coupled", "vessel"}
                or type_b.startswith("body")
                or _is_turbine_point_type(type_b)
                or (type_b in {"connect", "free"} and point_z[node_a] <= point_z[node_b])
                or (line_is_finite_ei and _rod_point(type_b) is not None)
            )
            if type_a == "fixed" and upper_b:
                node_a, node_b = node_b, node_a
                type_a, type_b = type_b, type_a
                swapped_lines.add(str(_native_int(row.tokens[0])))
            normalized_line_endpoints[str(_native_int(row.tokens[0]))] = (node_a, node_b)
            if not has_dynamic_points:
                type_a_is_coupled = type_a in {"coupled", "vessel"} or _is_turbine_point_type(
                    type_a
                )
                if not type_a_is_coupled:
                    raise DeckFormatError(
                        f"{self._at(row)}: static LINE End A must be Coupled/Vessel"
                    )
                farm_shared = _is_turbine_point_type(type_a) and _is_turbine_point_type(type_b)
                if type_b != "fixed" and not farm_shared:
                    # native finalize_checks: a finite-EI line may end on two Coupled/Vessel
                    # points (both ends driven); decided once the SECTIONS give its line types
                    moving_b_lines.append((row, str(_native_int(row.tokens[0])), type_b))
                if type_b == "fixed" and point_z[node_a] < point_z[node_b]:
                    raise DeckFormatError(f"{self._at(row)}: fairlead must not be below its anchor")
        for row in self.sections:
            if len(row.tokens) != 4:
                raise DeckFormatError(f"{self._at(row)}: SECTIONS row needs exactly 4 fields")
            line_id_token, line_type = row.tokens[:2]
            try:
                line_id = str(_native_int(line_id_token))
            except ValueError as exc:
                raise DeckFormatError(
                    f"{self._at(row)}: section line id must be an integer"
                ) from exc
            if line_id not in line_ids:
                raise DeckFormatError(f"{self._at(row)}: section references missing line {line_id}")
            if line_type.lower() not in type_names:
                raise DeckFormatError(
                    f"{self._at(row)}: section references missing line type {line_type}"
                )
            try:
                length, segments = _native_float(row.tokens[2]), _native_int(row.tokens[3])
            except ValueError as exc:
                raise DeckFormatError(
                    f"{self._at(row)}: section length/NumSegs is invalid"
                ) from exc
            if (
                not math.isfinite(length)
                or not length > 0.0
                or segments < 1
                or segments > _NATIVE_MAX_SEGMENTS
            ):
                raise DeckFormatError(
                    f"{self._at(row)}: section length must be positive and "
                    f"NumSegs must be between 1 and {_NATIVE_MAX_SEGMENTS}"
                )
            _check_section_magnitude(length, segments, self._at(row))
            section_lines.add(line_id)
            section_types_by_line[line_id].append(line_type.lower())
            line_nelems[line_id] += segments
            line_lengths[line_id] += length
        uncovered = line_ids.difference(section_lines)
        if uncovered:
            raise DeckFormatError(
                f"{self._label}: lines without SECTIONS rows: {', '.join(sorted(uncovered))}"
            )
        for row in self.lines:
            line_id = str(_native_int(row.tokens[0]))
            if len(row.tokens) == 7 and len(section_types_by_line[line_id]) > 1:
                raise DeckFormatError(
                    f"{self._at(row)}: LINE {line_id} is defined by a 7-column LINES row "
                    "(LineType, UnstrLen, NumSegs) and also has SECTIONS rows; describe the "
                    "line either with the 7-column row or with a 3/4-column LINES row plus "
                    "SECTIONS rows"
                )
        used_type_names = {
            line_type
            for section_types in section_types_by_line.values()
            for line_type in section_types
        }
        # Native standalone executable: a deck mixing EI=0 and finite-EI lines between held
        # or moving points (no bodies, rods or Free/Connect points) runs on the coupled
        # aggregate, whose static initialization needs no clock; every other finite-EI
        # deck needs dtM and TMax.
        finite_lines = [
            any(line_type_meta[line_type][3] > 0.0 for line_type in section_types)
            for section_types in section_types_by_line.values()
        ]
        # native finalize_checks: a line between two moving points is a FAST.Farm shared line
        # (accepted above) or a finite-EI line between two Coupled/Vessel points
        for row, line_id, type_b in moving_b_lines:
            finite = any(line_type_meta[name][3] > 0.0 for name in section_types_by_line[line_id])
            if finite and type_b in {"coupled", "vessel"}:
                continue
            if finite:
                raise DeckFormatError(
                    f"{self._at(row)}: static LINE End B of a finite-EI line must be Fixed, "
                    "Coupled or Vessel"
                )
            raise DeckFormatError(f"{self._at(row)}: static LINE End B must be Fixed")
        # native build_one_hermite_cable: the as-laid reference lays a line on the seabed from its
        # anchored end, which a finite-EI line between two moving points does not have
        statics_row = option_by_key.get("statics_friction")
        if (
            statics_row is not None
            and _strip_quotes(statics_row.values[0]).lower() != "none"
            and friction_active
            and (has_depth or has_bathymetry)
        ):
            for line_id, (_, end_b) in normalized_line_endpoints.items():
                end_b_type = point_types.get(end_b, end_b)
                if end_b_type == "fixed" or not _end_b_holds_connection(end_b_type):
                    continue
                if any(line_type_meta[name][3] > 0.0 for name in section_types_by_line[line_id]):
                    raise DeckFormatError(
                        f"{self._label}: OPTION staticsFriction asLaid lays a line on the seabed "
                        f"from its anchored end; finite-EI LINE {line_id} has a moving End B (both "
                        "ends on moving points): use staticsFriction none"
                    )
        # native CD_Deck_Query_dtM has_objects, on the parsed (zero-length rods collapsed) deck
        has_objects = (
            bool(self._rows("BODIES"))
            or any(segments != 0 for _, segments in self._rod_rows_by_id().values())
            or any(point_type in {"free", "connect"} for point_type in point_types.values())
        )
        mixed_route = any(finite_lines) and not all(finite_lines) and not has_objects
        mixed_static = mixed_route and not has_tmax
        finite_line_ids = [
            line_id
            for line_id, section_types in section_types_by_line.items()
            if any(line_type_meta[line_type][3] > 0.0 for line_type in section_types)
        ]
        # Native build_one_hermite_cable, which builds every finite-EI line of the coupled
        # aggregate (OpenFAST, FAST.Farm, the C API and the standalone mixed deck): the cable
        # is driven at End A and either held at a Fixed End B (the anchor) or driven at a
        # Coupled/Vessel End B (its own moving column: a line between two moving points, such
        # as a line shared by two turbines). Any other End B is refused here.
        if self.caller_driven or mixed_route:
            for line_id in finite_line_ids:
                end_b = normalized_line_endpoints[line_id][1]
                end_b_type = point_types.get(end_b, end_b)
                if not _end_b_holds_connection(end_b_type):
                    raise DeckFormatError(
                        f"{self._label}: line {line_id}: finite-EI coupled cable requires End B "
                        "to be a Fixed point or a Coupled/Vessel point (a second driven end); "
                        f'got "{end_b_type}"'
                    )
        for line_type in used_type_names:
            _, _, ea_static, ei = line_type_meta[line_type]
            if ea_static <= 0.0:
                raise DeckFormatError(
                    f"{self._label}: used LINE TYPE {line_type!r} requires EA > 0"
                )
            if ei < 0.0:
                raise DeckFormatError(
                    f"{self._label}: used LINE TYPE {line_type!r} requires EI >= 0"
                )
            if ei > 0.0 and not (has_dtm or self.caller_driven or mixed_static):
                raise DeckFormatError(
                    f"{self._label}: finite-EI sections require dtM and TMax in standalone runs"
                )
        # Native static route: the working-curve (Syrope) model exists only on the
        # dynamic path, so a standalone static deck cannot solve a Syrope line.
        syrope_names = {
            row.tokens[0].lower()
            for row in self.line_types
            if row.tokens[3].split("|", 1)[0].lower().startswith("syrope:")
        }
        if not (has_dtm or self.caller_driven) and used_type_names & syrope_names:
            raise DeckFormatError(
                f"{self._label}: a Syrope line has no static output; provide dtM and TMax "
                "to run the dynamic working-curve path"
            )

        self._check_stiffeners(line_ids, section_types_by_line, line_type_meta, line_lengths)
        self._check_attachments(line_ids, section_types_by_line, line_type_meta, line_lengths)

        assigned_end_connections: set[tuple[str, str]] = set()
        # (line, end) held by a Rigid or rotational-spring row, in native End A/B order
        held_ends: set[tuple[str, str]] = set()
        # line id -> {end: torsionally restrained} from the optional torsion columns, and the
        # pretwists, in native End A/B order (after the anchor-first swap, which reverses Ez and
        # so negates a pretwist)
        torsion_ends: dict[str, dict[str, bool]] = {}
        torsion_pretwist: dict[str, dict[str, float]] = {}
        for row in self.end_connections:
            if len(row.tokens) not in (6, 10, 11):
                raise DeckFormatError(
                    f"{self._at(row)}: END CONNECTIONS row needs 6 columns "
                    "(LineID End Stiffness EzX EzY EzZ), or 10 or 11 with the torsion columns "
                    "(... TorsStiffness NxX NxY NxZ [Pretwist])"
                )
            try:
                line_id = str(_native_int(row.tokens[0]))
            except ValueError as exc:
                raise DeckFormatError(
                    f"{self._at(row)}: END CONNECTIONS LineID must be an integer, "
                    f"got {row.tokens[0]!r}"
                ) from exc
            if _native_int(line_id) < 1:
                raise DeckFormatError(
                    f"{self._at(row)}: END CONNECTIONS LineID must be positive, got {line_id}"
                )
            if line_id not in line_ids:
                raise DeckFormatError(
                    f"{self._at(row)}: END CONNECTIONS references an undefined line {line_id}"
                )
            try:
                end = _end_connection_end(row.tokens[1])
            except ValueError as exc:
                raise DeckFormatError(
                    f"{self._at(row)}: line {line_id}: {exc}, got {row.tokens[1]!r}"
                ) from exc
            # names the line end in every message below
            where = f"{self._at(row)}: line {line_id} End {end.upper()}:"
            key = (line_id, end)
            if key in assigned_end_connections:
                raise DeckFormatError(f"{where} duplicate END CONNECTIONS row for one line end")
            assigned_end_connections.add(key)

            stiffness_token = _strip_quotes(row.tokens[2]).lower()
            if stiffness_token in _PINNED_END_CONNECTIONS:
                non_pinned = False
            elif stiffness_token in _RIGID_END_CONNECTIONS:
                non_pinned = True
            else:
                # native parse_real_token: a plain real (no q exponent), finite, not subnormal
                stiffness = _keyword_column_real(row.tokens[2])
                if stiffness is None or stiffness < 0.0:
                    raise DeckFormatError(
                        f"{where} END CONNECTIONS stiffness must be finite and "
                        f"non-negative, Pinned, or Rigid, got {row.tokens[2]!r}"
                    )
                non_pinned = stiffness > 0.0

            direction = [
                numeric(row.tokens[index], row, f"END CONNECTIONS direction column {index + 1}")
                for index in range(3, 6)
            ]
            norm = math.sqrt(sum(value * value for value in direction))
            if not math.isfinite(norm) or norm <= math.sqrt(sys.float_info.min):
                raise DeckFormatError(
                    f"{where} END CONNECTIONS direction must be non-zero, got "
                    f"({', '.join(row.tokens[3:6])})"
                )
            if len(row.tokens) > 6:
                # native append_end_connection: TorsStiffness NxX NxY NxZ [Pretwist]
                torsion_token = _strip_quotes(row.tokens[6]).lower()
                if torsion_token in _FREE_TORSION_KEYWORDS:
                    restrained = False
                elif torsion_token in _RIGID_END_CONNECTIONS:
                    restrained = True
                else:
                    torsion_k = _keyword_column_real(row.tokens[6])
                    if torsion_k is None or torsion_k < 0.0:
                        raise DeckFormatError(
                            f"{where} END CONNECTIONS torsional stiffness must be finite "
                            f"and non-negative, Free, or Rigid, got {row.tokens[6]!r}"
                        )
                    restrained = torsion_k > 0.0
                normal = [
                    numeric(
                        row.tokens[index],
                        row,
                        f"END CONNECTIONS reference normal column {index + 1}",
                    )
                    for index in range(7, 10)
                ]
                pretwist = 0.0
                if len(row.tokens) == 11:
                    pretwist = numeric(row.tokens[10], row, "END CONNECTIONS pretwist")
                native_end = end
                if line_id in swapped_lines:
                    native_end = {"a": "b", "b": "a"}[end]
                    pretwist = -pretwist
                torsion_pretwist.setdefault(line_id, {})[native_end] = pretwist
                if restrained:
                    # a Free end has no torsion frame: its normal is not checked (native)
                    self._check_torsion_normal(where, row, normal, direction, norm)
                torsion_ends.setdefault(line_id, {})[native_end] = restrained
            if non_pinned:
                swapped = line_id in swapped_lines
                held_ends.add((line_id, {"a": "b", "b": "a"}[end] if swapped else end))
                has_finite_ei = any(
                    line_type_meta[line_type][3] > 0.0
                    for line_type in section_types_by_line[line_id]
                )
                if not has_finite_ei:
                    raise DeckFormatError(f"{where} END CONNECTIONS requires a finite-EI line")
                # native finalize_checks: End B is held at a Fixed point or driven with its
                # own parent at a Coupled/Vessel point (a line between two moving points) or on
                # a body point or a rod end (a line between two objects)
                end_b = normalized_line_endpoints[line_id][1]
                if not _end_b_holds_frame(point_types[end_b]):
                    raise DeckFormatError(
                        f"{where} non-pinned END CONNECTIONS need End B on a Fixed, Coupled or "
                        "Vessel point, a Rigid6 body point or a rod end"
                    )

        # Advanced native sections are preserved, but preservation must not mean
        # silently accepting syntax or references the Fortran parser rejects.
        bodies = self._rows("BODIES")
        for row in bodies:
            if len(row.tokens) == 14:
                self._check_moordyn_body_row(row, numeric, has_motion_file, has_dtm)
                continue
            if len(row.tokens) not in {15, 18}:
                raise DeckFormatError(f"{self._at(row)}: BODIES row needs 14, 15 or 18 fields")
            body_type = row.tokens[1].lower()
            if body_type in _PINNED_BODY_TYPES:
                # native finalize_checks: the host moves the reference point of a CoupledPinned
                # body, so only a coupled host runs it; its rotation is integrated
                values = [
                    numeric(row.tokens[index], row, f"BODIES column {index + 1}")
                    for index in range(2, len(row.tokens))
                ]
                if _body_outside_admissible_range(
                    values[:6], values[6:12] + values[13:], values[12]
                ):
                    raise DeckFormatError(f"{self._at(row)}: {_BODY_RANGE_MESSAGE}")
                if not (has_dtm or self.caller_driven):
                    raise DeckFormatError(f"{self._at(row)}: {_RIGID6_DYNAMIC_MESSAGE}")
                if not self.caller_driven:
                    raise DeckFormatError(f"{self._at(row)}: {_PINNED_BODY_HOST_MESSAGE}")
                inertia = values[13:16] if len(values) >= 16 else [0.0, 0.0, 0.0]
                if min(values[6], values[7], values[11], values[12]) < 0.0 or any(
                    value <= 0.0 for value in inertia
                ):
                    raise DeckFormatError(f"{self._at(row)}: {_PINNED_BODY_VALUE_MESSAGE}")
                continue
            if body_type in _HOST_BODY_TYPES:
                if not (has_motion_file or self.caller_driven):
                    raise DeckFormatError(
                        f"{self._at(row)}: Coupled/Vessel BODY requires a motionFile "
                        "(or a coupled host)"
                    )
                values = [
                    numeric(row.tokens[index], row, f"BODIES column {index + 1}")
                    for index in range(2, len(row.tokens))
                ]
                if _body_outside_admissible_range(
                    values[:6], values[6:12] + values[13:], values[12]
                ):
                    raise DeckFormatError(f"{self._at(row)}: {_BODY_RANGE_MESSAGE}")
                if min(values[6], values[7], values[11], values[12], *values[13:]) < 0.0:
                    raise DeckFormatError(
                        f"{self._at(row)}: Coupled/Vessel BODY requires non-negative "
                        "Mass/Ixx/Iyy/Izz/Vol/CdA/Ca"
                    )
                continue
            if body_type not in {"point3", "rigid6"}:
                raise DeckFormatError(
                    f"{self._at(row)}: BODY type must be Point3, Rigid6, Coupled or Vessel"
                )
            if body_type == "rigid6" and len(row.tokens) != 18:
                raise DeckFormatError(f"{self._at(row)}: Rigid6 BODY requires Ixx, Iyy, and Izz")
            values = [
                numeric(row.tokens[index], row, f"BODIES column {index + 1}")
                for index in range(2, len(row.tokens))
            ]
            if _body_outside_admissible_range(values[:6], values[6:12] + values[13:], values[12]):
                raise DeckFormatError(f"{self._at(row)}: {_BODY_RANGE_MESSAGE}")
            mass, volume, cda, ca = values[6], values[7], values[11], values[12]
            if mass <= 0.0 or volume < 0.0 or cda < 0.0 or ca < 0.0:
                raise DeckFormatError(
                    f"{self._at(row)}: BODY requires Mass > 0 and non-negative Vol/CdA/Ca"
                )
            if body_type == "rigid6" and any(inertia <= 0.0 for inertia in values[13:16]):
                raise DeckFormatError(f"{self._at(row)}: Rigid6 BODY inertias must be positive")
        if bodies and not (has_dtm or self.caller_driven):
            raise DeckFormatError(f"{self._label}: BODIES require dtM and TMax in standalone runs")
        body_ids = unique(bodies, "body", True) if bodies else set()
        body_types = {
            str(_native_int(row.tokens[0])): (
                "rigid6"
                if len(row.tokens) == 14
                or row.tokens[1].lower() in _HOST_BODY_TYPES | _PINNED_BODY_TYPES
                else row.tokens[1].lower()
            )
            for row in bodies
        }
        torsion_lines, torsion_notes = self._check_torsion_lines(
            torsion_ends,
            torsion_pretwist,
            section_types_by_line,
            line_type_meta,
            line_type_gj,
            normalized_line_endpoints,
            point_types,
            body_types,
            option_by_key,
            has_tmax,
        )

        rod_types = self._rows("ROD TYPES")
        for row in rod_types:
            if self._legacy_rod_type_columns(row):
                raise DeckFormatError(
                    f"{self._at(row)}: ROD TYPES header names axial coefficients (CdAx CaAx) in "
                    "columns 6-7, which are MoorDyn's end coefficients CdEnd CaEnd; migrate the "
                    'section to "Name Diam Mass/m Cd Ca CdEnd CaEnd CdAx CaAx"'
                )
            if len(row.tokens) not in {7, 9}:
                raise DeckFormatError(f"{self._at(row)}: ROD TYPES row needs 7 or 9 fields")
            values = [
                numeric(row.tokens[index], row, f"ROD TYPES column {index + 1}")
                for index in range(1, len(row.tokens))
            ]
            if values[0] <= 0.0 or values[1] <= 0.0 or any(value < 0.0 for value in values[2:]):
                raise DeckFormatError(
                    f"{self._at(row)}: ROD TYPE requires Diam/Mass > 0 and non-negative Cd/Ca"
                )
        rod_type_names = unique(rod_types, "rod type", False) if rod_types else set()
        for expected_id, row in enumerate(self._rows("EXTERNAL LOADS"), start=1):
            # native apply_external_load: MoorDyn-F order ID Object Force Blin Bquad CSys, or
            # ID Object CSys Force Blin Bquad; the CSys letter (G, L or -) tells them apart.
            # Several rows on one body add up.
            if len(row.tokens) != 6:
                raise DeckFormatError(
                    f"{self._at(row)}: EXTERNAL LOADS row needs 6 fields: ID Object Force Blin "
                    "Bquad CSys (MoorDyn-F order) or ID Object CSys Force Blin Bquad"
                )
            try:
                row_id = _native_int(row.tokens[0])
            except ValueError:
                row_id = 0
            if row_id != expected_id:
                raise DeckFormatError(
                    f"{self._at(row)}: EXTERNAL LOADS ID numbers must be sequential starting "
                    f"from 1 (expected {expected_id}, found {row.tokens[0]!r})"
                )
            column3, column6 = _is_csys_token(row.tokens[2]), _is_csys_token(row.tokens[5])
            if column3 == column6:
                raise DeckFormatError(
                    f"{self._at(row)}: EXTERNAL LOADS row needs the CSys letter (G or L) in "
                    "column 6 (MoorDyn-F order ID Object Force Blin Bquad CSys) or in column 3 "
                    "(ID Object CSys Force Blin Bquad)"
                )
            csys, first_value = (row.tokens[2], 3) if column3 else (row.tokens[5], 2)
            target = re.fullmatch(r"body([0-9]+)", row.tokens[1].lower())
            target_type = (
                None if target is None else body_types.get(str(_native_id_suffix(target.group(1))))
            )
            if target_type == "point3":
                # Only a Rigid6 body carries the external load and damping in its equations
                # of motion, so a load on a Point3 body is refused rather than dropped.
                raise DeckFormatError(
                    f"{self._at(row)}: EXTERNAL LOADS apply to Rigid6 bodies only; "
                    f"{row.tokens[1]} is a Point3 body"
                )
            if target_type != "rigid6":
                raise DeckFormatError(
                    f"{self._at(row)}: EXTERNAL LOADS object must be a Rigid6 Body<N>"
                )
            for index, name in (
                (first_value, "Force"),
                (first_value + 1, "Blin"),
                (first_value + 2, "Bquad"),
            ):
                parts = row.tokens[index].split("|")
                values = [numeric(part, row, f"EXTERNAL LOADS {name}") for part in parts]
                if len(parts) not in {1, 3}:
                    raise DeckFormatError(
                        f"{self._at(row)}: EXTERNAL LOADS {name} needs one or three values"
                    )
                if name == "Force" and len(parts) == 1 and values[0] != 0.0:
                    raise DeckFormatError(f"{self._at(row)}: EXTERNAL LOADS Force is 0 or f1|f2|f3")
                if name != "Force" and any(value < 0.0 for value in values):
                    raise DeckFormatError(
                        f"{self._at(row)}: EXTERNAL LOADS Blin and Bquad must be non-negative"
                    )
            if csys.lower() not in {"g", "l"}:
                raise DeckFormatError(
                    f"{self._at(row)}: EXTERNAL LOADS CSys must be G or L for a body"
                )

        rods = self._rows("RODS")
        zero_length_rods: set[str] = set()
        rod_segments: dict[str, int] = {}
        for row in rods:
            if len(row.tokens) not in {10, 11}:
                raise DeckFormatError(f"{self._at(row)}: RODS row needs 10 or 11 fields")
            try:
                segments = _native_int(row.tokens[9])
            except ValueError as exc:
                raise DeckFormatError(f"{self._at(row)}: rod NumSegs must be an integer") from exc
            # Native collapse_zero_length_rods turns a zero-length rod (NumSegs 0) into a
            # point before the rod checks, so its rod type and motion source are not used.
            zero_length = segments == 0
            if not zero_length and row.tokens[1].lower() not in rod_type_names:
                raise DeckFormatError(
                    f"{self._at(row)}: rod references missing rod type {row.tokens[1]}"
                )
            rod_kind = _ROD_ATTACHMENT_ALIASES.get(row.tokens[2].lower(), row.tokens[2].lower())
            # native finalize_checks: the host moves the pin of a CoupledPinned rod, so only the
            # coupled route (a caller-driven deck) takes one, zero-length ones included
            if rod_kind == "coupledpinned" and not self.caller_driven:
                raise DeckFormatError(
                    f"{self._at(row)}: CoupledPinned/VesselPinned ROD requires a coupled host "
                    "(OpenFAST CompMooring = 5); in a standalone deck use Pinned, Body<N>Pinned, "
                    "or a Coupled rod with a motionFile"
                )
            # Body<N> (fixed to the body) or Body<N>Pinned / Body<N>Pin (End A pinned to it)
            body_kind = re.fullmatch(r"body([0-9]+)(?:pin|pinned)?", rod_kind)
            if body_kind is not None:
                if body_types.get(str(_native_id_suffix(body_kind.group(1)))) != "rigid6":
                    raise DeckFormatError(
                        f"{self._at(row)}: ROD attachment must name a Rigid6 (Free) BODY"
                    )
            elif rod_kind not in {"free", "fixed", "coupled", "vessel", "pinned", "coupledpinned"}:
                raise DeckFormatError(
                    f"{self._at(row)}: ROD type must be Free, Fixed, Pinned, Coupled, Vessel, "
                    "CoupledPinned, VesselPinned, Body<N>, or Body<N>Pinned"
                )
            if (
                not zero_length
                and rod_kind in {"coupled", "vessel"}
                and not (has_motion_file or self.caller_driven)
            ):
                raise DeckFormatError(
                    f"{self._at(row)}: Coupled/Vessel ROD requires a motionFile (or a coupled host)"
                )
            rod_outputs = row.tokens[10] if len(row.tokens) == 11 else "-"
            if rod_outputs != "-" and not re.fullmatch(r"[pP]+", rod_outputs):
                raise DeckFormatError(f"{self._at(row)}: ROD Outputs accepts only '-' and 'p'")
            rod_ends = [
                numeric(row.tokens[index], row, f"RODS column {index + 1}") for index in range(3, 9)
            ]
            if segments < 0:
                raise DeckFormatError(f"{self._at(row)}: rod NumSegs must be 0 or positive")
            rod_segments[_row_key(row.tokens[0])] = segments
            if zero_length:
                # a zero-length rod (MoorDyn): a point-like connector at End A, End B ignored
                zero_length_rods.add(_row_key(row.tokens[0]))
                continue
            if any(abs(value) > _NATIVE_MAX_COORDINATE for value in rod_ends):
                raise DeckFormatError(
                    f"{self._at(row)}: ROD endpoint coordinates must be at most 1e6 m in magnitude"
                )
            if math.dist(rod_ends[:3], rod_ends[3:]) <= 100.0 * math.ulp(1.0):
                raise DeckFormatError(
                    f"{self._at(row)}: ROD endpoints must define a positive length "
                    "(a zero-length rod is declared with NumSegs 0)"
                )
        # the rods that remain rods natively (zero-length ones become points)
        finite_length_rods = [
            row for row in rods if _row_key(row.tokens[0]) not in zero_length_rods
        ]
        if finite_length_rods and not (has_dtm or self.caller_driven):
            raise DeckFormatError(f"{self._label}: RODS require dtM and TMax in standalone runs")
        if has_dynamic_points and not (has_dtm or self.caller_driven):
            raise DeckFormatError(
                f"{self._label}: dynamic POINT types require dtM and TMax in standalone runs"
            )
        if has_dynamic_points and friction_active:
            raise DeckFormatError(
                f"{self._label}: dynamic POINT types do not support seabed friction"
            )
        has_rigid6 = "rigid6" in body_types.values()
        failures = self._rows("FAILURE")
        # The standalone executable runs a mixed EI=0 + finite-EI deck without bodies,
        # rods or Free/Connect points on the aggregate; every other deck goes through the
        # deck driver, whose dispatch gates follow.
        deck_driver_route = not self.caller_driven and not mixed_route
        if self.caller_driven or mixed_route:
            # native CD_Init_Deck_Aggregate: the host drives the coupled boundary; a standalone
            # mixed deck is driven by the driver, which holds the initialized ends or marches
            # the deck's motionFile/vesselMotion (prescribed_motion; vesselRAO needs deck
            # waves, which the still-water mixed route refuses below)
            if has_motion_file and self.caller_driven:
                raise DeckFormatError(
                    f"{self._label}: the coupled boundary is driven by the host, not a deck "
                    "motionFile; remove the motionFile OPTION"
                )
            if not line_ids:
                raise DeckFormatError(f"{self._label}: the coupled route needs at least one line")
        if self.caller_driven:
            # native CD_Init_Deck_Aggregate: nothing on the coupled route evaluates deck
            # waves (the host SeaState supplies them). A deck current is a steady field on a
            # single-turbine pure EI=0 deck without Rigid6 bodies or rods; the rest of its
            # rule depends on the host (rejected when SeaState carries waves or current).
            if has_waves or trains:
                raise DeckFormatError(
                    f"{self._label}: deck waves are not evaluated on the coupled route (the host "
                    "SeaState supplies wave kinematics); remove the deck waves OPTION"
                )
            has_deck_current = current is not None and current.values[0].lower() != "none"
            has_rods = any(segments != 0 for _, segments in self._rod_rows_by_id().values())
            is_farm = any(_is_turbine_point_type(kind) for kind in point_types.values())
            if has_deck_current and (any(finite_lines) or has_rigid6 or has_rods or is_farm):
                raise DeckFormatError(
                    f"{self._label}: a deck current on the coupled route is kept only on a "
                    "single-turbine pure EI=0 deck without Rigid6 bodies or rods; remove the "
                    "deck current OPTION (the host SeaState supplies the current)"
                )
            # native CD_Init_Deck_Aggregate: the coupled march advances the bodies or the rods
            # of a deck, not both (a rod fixed to a body counts; a zero-length rod is a point)
            if has_rods and body_types:
                raise DeckFormatError(
                    f"{self._label}: a coupled deck with both BODIES and RODS is not "
                    "supported: the coupled march advances the bodies (Rigid6, Point3) or the "
                    "rods of a deck, not both, and a rod fixed to a body counts as a rod; run "
                    "the deck with MoorDyn (CompMooring = 3) or, without CoupledPinned objects, "
                    "with the standalone driver, whose multibody march takes both"
                )
        if mixed_route and not self.caller_driven:
            n_modes_value = option_by_key.get("n_modes")
            if n_modes_value is not None and round(_native_float(n_modes_value.values[0])) != 0:
                raise DeckFormatError(
                    f"{self._label}: OPTION nModes is not supported for mixed EI=0/finite-EI "
                    "decks; remove it or set it to 0"
                )
            # native run_mixed_held_deck: the standalone mixed deck runs on the aggregate, which
            # marches the deck current (a current OPTION or Currents 1/2/5, deck_current) but
            # evaluates no deck waves, and writes the main OUTPUTS only
            if mdc_wave_kin:
                raise DeckFormatError(
                    f"{self._label}: the MoorDyn-C WaveKin {mdc_wave_kin} waves are not supported "
                    "for a standalone mixed EI=0/finite-EI deck (it takes a deck current but no "
                    "deck waves)"
                )
            if has_waves or trains:
                raise DeckFormatError(
                    f"{self._label}: the deck waves OPTION is not supported for a standalone mixed "
                    "EI=0/finite-EI deck: this route takes the deck current but evaluates no deck "
                    "waves"
                )
            if series_lines:
                raise DeckFormatError(
                    f"{self._label}: a mixed EI=0/finite-EI deck writes no per-line files; "
                    "use OUTPUTS channels instead of the LINES Outputs flags p, t and V"
                )

        # Native deck_needs_multibody: a dynamic deck that no single-family march covers
        # runs on the multibody march, which takes no prescribed motion.
        def is_body_kind(kind: str, pinned: bool) -> bool:
            match = re.fullmatch(r"body([0-9]+)((?:pin|pinned)?)", kind)
            return match is not None and bool(match.group(2)) == pinned

        rod_kinds = {
            _row_key(row.tokens[0]): _ROD_ATTACHMENT_ALIASES.get(
                row.tokens[2].lower(), row.tokens[2].lower()
            )
            for row in finite_length_rods
        }
        needs_multibody = any(is_body_kind(kind, True) for kind in rod_kinds.values()) or any(
            kind == "pinned"
            and any(
                (point := _rod_point(point_type)) is not None and str(point[0]) == rod_id
                for point_type in point_types.values()
            )
            for rod_id, kind in rod_kinds.items()
        )
        non_rigid6_points = any(
            point_type in {"connect", "free"}
            or (
                point_type.startswith("body")
                and body_types.get(str(_body_point_id(point_type))) != "rigid6"
            )
            for point_type in point_types.values()
        )
        if not needs_multibody and line_ids:
            if any(finite_lines):
                needs_multibody = bool(bodies or finite_length_rods or has_dynamic_points)
            elif finite_length_rods and not all(
                is_body_kind(kind, False) for kind in rod_kinds.values()
            ):
                needs_multibody = has_rigid6 or any(
                    point_type in {"connect", "free"} or point_type.startswith("body")
                    for point_type in point_types.values()
                )
            elif has_rigid6:
                needs_multibody = non_rigid6_points
        if failures and deck_driver_route:
            # native CD_Run_Deck_Driver: FAILURE runs on the point-system object graph only
            if not has_dtm:
                raise DeckFormatError(
                    f"{self._label}: FAILURE requires a dynamic deck (dtM and TMax)"
                )
            if any(line_type_meta[name][3] > 0.0 for name in used_type_names):
                raise DeckFormatError(f"{self._label}: FAILURE is not supported on finite-EI decks")
            if finite_length_rods:
                raise DeckFormatError(f"{self._label}: FAILURE is not supported on ROD decks")
            if has_rigid6 and non_rigid6_points:
                raise DeckFormatError(
                    f"{self._label}: FAILURE on a Rigid6 BODY deck does not support Connect/Free "
                    "or Point3 body points"
                )
            if has_motion_file:
                raise DeckFormatError(
                    f"{self._label}: a FAILURE deck does not support motionFile coupling"
                )
            if friction_active:
                raise DeckFormatError(
                    f"{self._label}: a FAILURE deck does not support seabed friction"
                )
        if has_motion_file and deck_driver_route and needs_multibody:
            raise DeckFormatError(
                f"{self._label}: a mixed-topology deck (bodies, rods, dynamic points, EI=0 and "
                "finite-EI lines together) does not support motionFile coupling"
            )
        if deck_driver_route and needs_multibody and (has_dtm or has_tmax):
            self._check_multibody_cable_ends(
                finite_line_ids,
                normalized_line_endpoints,
                point_types,
                body_types,
                held_ends,
                {
                    (line_id, end)
                    for line_id in torsion_lines
                    for end in ("a", "b")
                    if torsion_ends.get(line_id, {}).get(end, False)
                },
                option_by_key.get("bodyscheme"),
            )
        # Native standalone dispatch: ROD and Rigid6 decks take prescribed motion; the
        # Connect/Free point-system route does not.
        if (
            has_motion_file
            and deck_driver_route
            and not finite_length_rods
            and not has_rigid6
            and has_dynamic_points
        ):
            raise DeckFormatError(
                f"{self._label}: a Connect/Free dynamic-point deck does not support "
                "motionFile coupling"
            )
        n_modes_row = option_by_key.get("n_modes")
        n_modes = 0 if n_modes_row is None else round(_native_float(n_modes_row.values[0]))
        if n_modes > 0 and deck_driver_route:
            # native check_modal_deck
            if bodies or finite_length_rods or has_dynamic_points or failures or not line_ids:
                raise DeckFormatError(
                    f"{self._label}: OPTION nModes needs a deck of lines between Fixed and "
                    "Coupled/Vessel points (no BODIES, RODS, Connect/Free points or FAILURE)"
                )
            if has_bathymetry:
                raise DeckFormatError(
                    f"{self._label}: OPTION nModes supports a flat WtrDpth seabed only "
                    "(not bathymetryFile)"
                )
            # (native also requires all-finite-EI lines and dtM here; on this route the
            # finite-EI clock rule and the object checks above already enforce both; the modes
            # hold both line ends, a moving End B included)
        rod_ids = unique(rods, "rod", True) if rods else set()

        body_refs: dict[str, int] = dict.fromkeys(body_ids, 0)
        rod_a_refs: dict[str, int] = dict.fromkeys(rod_ids, 0)
        rod_b_refs: dict[str, int] = dict.fromkeys(rod_ids, 0)
        for row in self.points:
            point_type = row.tokens[1].lower()
            if point_type.startswith("body"):
                body_id = str(_body_point_id(point_type))
                if body_id not in body_ids:
                    raise DeckFormatError(
                        f"{self._at(row)}: POINT type references an undefined BODY"
                    )
                body_refs[body_id] += 1
            rod_point = _rod_point(point_type)
            if rod_point is not None:
                rod_id = str(rod_point[0])
                if rod_id not in rod_ids:
                    raise DeckFormatError(
                        f"{self._at(row)}: POINT type references an undefined ROD"
                    )
                refs = rod_a_refs if rod_point[1] == "a" else rod_b_refs
                refs[rod_id] += 1
        for body_id, count in body_refs.items():
            if count and body_types[body_id] == "point3" and count != 1:
                raise DeckFormatError(
                    f"{self._label}: Point3 BODY {body_id} requires exactly one Body<N> POINT"
                )
        for rod_id in rod_ids:
            if rod_a_refs[rod_id] > 1 or rod_b_refs[rod_id] > 1:
                raise DeckFormatError(
                    f"{self._label}: ROD {rod_id} has more than one Rod<N>A or Rod<N>B POINT"
                )

        equivalents = self._rows("EQUIVALENT BUOYANCY")
        equivalent_types: set[str] = set()
        equivalent_sections: dict[str, tuple[float, float]] = {}
        gravity = (
            _native_float(option_by_key["gravity"].values[0])
            if "gravity" in option_by_key
            else 9.80665
        )
        water_density = (
            _native_float(option_by_key["water_density"].values[0])
            if "water_density" in option_by_key
            else 1025.0
        )
        for row in equivalents:
            if len(row.tokens) != 3:
                raise DeckFormatError(f"{self._at(row)}: EQUIVALENT BUOYANCY row needs 3 fields")
            if row.tokens[0].lower() not in type_names:
                raise DeckFormatError(
                    f"{self._at(row)}: equivalent buoyancy references missing "
                    f"line type {row.tokens[0]}"
                )
            line_type = row.tokens[0].lower()
            if line_type in equivalent_types:
                raise DeckFormatError(f"{self._at(row)}: duplicate EQUIVALENT BUOYANCY LineType")
            equivalent_types.add(line_type)
            diameter = numeric(row.tokens[1], row, "equivalent-buoyancy diameter")
            if diameter <= 0.0:
                raise DeckFormatError(
                    f"{self._at(row)}: equivalent-buoyancy diameter must be positive"
                )
            submerged_weight = numeric(
                row.tokens[2],
                row,
                "equivalent-buoyancy submerged weight",
            )
            dry_mass = water_density * (math.pi / 4.0) * diameter**2 + submerged_weight / gravity
            if not math.isfinite(dry_mass) or dry_mass < 0.0:
                raise DeckFormatError(
                    f"{self._at(row)}: equivalent buoyancy would require negative dry mass"
                )
            equivalent_sections[line_type] = (diameter, dry_mass)
        for line_type in sorted(used_type_names):
            diameter, mass, ea_static, ei = line_type_meta[line_type]
            diameter, mass = equivalent_sections.get(line_type, (diameter, mass))
            if (
                ea_static > _NATIVE_MAX_EA
                or abs(mass) > _NATIVE_MAX_ABS_MASS
                or diameter > _NATIVE_MAX_DIAMETER
            ):
                raise DeckFormatError(
                    f"{self._label}: used LINE TYPE {line_type!r} is outside the admissible "
                    "range (EA <= 1e15 N, |mass| <= 1e6 kg/m, Diam <= 1e3 m)"
                )
            if diameter <= 0.0:
                raise DeckFormatError(
                    f"{self._label}: used LINE TYPE {line_type!r} requires Diam > 0"
                )
            # native finalize_checks: a finite-EI line carries its mass in the bending dynamics
            # and its weight in the statics
            if ei > 0.0 and mass <= 0.0:
                raise DeckFormatError(
                    f"{self._label}: used LINE TYPE {line_type!r}: MassDenInAir must be > 0 on a "
                    "finite-EI line"
                )
            damping, coefficient = line_type_scales[line_type]
            if (
                0.0 < ea_static < _NATIVE_MIN_EA
                or diameter < _NATIVE_MIN_DIAMETER
                or ei > _NATIVE_MAX_COEFFICIENT
                or abs(damping) > _NATIVE_MAX_COEFFICIENT
                or coefficient > _NATIVE_MAX_SMALL_COEFFICIENT
            ):
                raise DeckFormatError(
                    f"{self._label}: used LINE TYPE {line_type!r} is outside the admissible "
                    "range (EA >= 1e-3 N, Diam >= 1e-6 m, EI and |BA| <= 1e15, Cd and Ca <= 1e3)"
                )
            # Native net-buoyancy gate: an EI=0 route cannot build a buoyant
            # (lazy-wave) arch, so a used section whose dry mass does not exceed
            # its displaced water mass needs a dynamic finite-EI line type.
            # Within the rejection, an EI=0 type in the neutral band just below the displaced
            # mass is named weightless (the native message).
            displaced_mass = water_density * (math.pi / 4.0) * diameter**2
            if mass <= displaced_mass and (
                ei <= 0.0 or not (has_dtm or self.caller_driven or mixed_static)
            ):
                if ei <= 0.0 and mass > displaced_mass * (1.0 - _NATIVE_NEUTRAL_BUOYANCY_REL_TOL):
                    raise DeckFormatError(
                        f"{self._label}: used LINE TYPE {line_type!r} is neutrally buoyant "
                        "(its dry mass equals the displaced water mass to within a relative "
                        "1e-6), so an EI=0 line of it is weightless and slack: its static "
                        "shape is indeterminate (every slack shape balances). Give the line "
                        "type weight (a larger MassDenInAir), or a finite EI with a tension that "
                        "holds it taut"
                    )
                raise DeckFormatError(
                    f"{self._label}: used LINE TYPE {line_type!r} is net-buoyant (dry mass <= "
                    "displaced water mass): buoyant / lazy-wave sections require a dynamic "
                    "finite-EI deck"
                )

        line_endpoints: dict[str, set[str]] = {}
        line_definition_index: dict[str, int] = {}
        for row in self.lines:
            attachments = row.tokens[2:4] if len(row.tokens) == 7 else row.tokens[1:3]
            line_id = str(_native_int(row.tokens[0]))
            line_endpoints[line_id] = {end_key(value) for value in attachments}
            line_definition_index[line_id] = row.index

        syrope_types = {
            line_type.tokens[0].lower()
            for line_type in self.line_types
            if line_type.tokens[3].split("|", 1)[0].lower().startswith("syrope:")
        }
        assigned_syrope: set[str] = set()
        for row in self._rows("SYROPE IC"):
            if len(row.tokens) < 3:
                raise DeckFormatError(
                    f"{self._at(row)}: SYROPE IC row needs Line(s), Tmax0, Tmean0"
                )
            id_tokens = row.tokens[:-2]
            # Native apply_syrope_ic joins "1,2" or "1, 2" but never "1 2" (line 12).
            if any(
                not previous.endswith(",") and not token.startswith(",")
                for previous, token in itertools.pairwise(id_tokens)
            ):
                raise DeckFormatError(
                    f"{self._at(row)}: SYROPE IC line ids must be separated by commas"
                )
            line_list = "".join(id_tokens)
            if not re.fullmatch(r"[+-]?[0-9]+(?:,[+-]?[0-9]+)*", line_list):
                raise DeckFormatError(f"{self._at(row)}: malformed SYROPE IC line list")
            try:
                ids = [str(_native_int(value)) for value in line_list.split(",")]
            except ValueError as exc:
                raise DeckFormatError(
                    f"{self._at(row)}: SYROPE IC line list must contain integers"
                ) from exc
            if len(ids) != len(set(ids)):
                raise DeckFormatError(f"{self._at(row)}: duplicate SYROPE IC line assignment")
            tmax0 = numeric(row.tokens[-2], row, "SYROPE IC Tmax0")
            tmean0 = numeric(row.tokens[-1], row, "SYROPE IC Tmean0")
            if tmax0 <= 0.0 or tmean0 < 0.0 or tmean0 > tmax0:
                raise DeckFormatError(
                    f"{self._at(row)}: SYROPE IC needs Tmax0 >= Tmean0 >= 0 and Tmax0 > 0"
                )
            if any(value not in line_ids for value in ids):
                raise DeckFormatError(f"{self._at(row)}: SYROPE IC references an undefined line")
            if any(line_definition_index[value] >= row.index for value in ids):
                raise DeckFormatError(
                    f"{self._at(row)}: SYROPE IC must follow its referenced LINE definitions"
                )
            if any(
                not any(t in syrope_types for t in section_types_by_line[value]) for value in ids
            ):
                raise DeckFormatError(
                    f"{self._at(row)}: SYROPE IC can reference only a line with a Syrope section"
                )
            if assigned_syrope.intersection(ids):
                raise DeckFormatError(f"{self._label}: duplicate SYROPE IC line assignment")
            assigned_syrope.update(ids)

        for expected_id, row in enumerate(self._rows("FAILURE"), start=1):
            if len(row.tokens) != 5:
                raise DeckFormatError(f"{self._at(row)}: FAILURE row needs 5 fields")
            try:
                failure_id = _native_int(row.tokens[0])
                point_token = row.tokens[1]
                if point_token[:1].lower() == "r":
                    raise ValueError
                point_id = str(
                    _native_int(point_token[1:] if point_token[:1].lower() == "p" else point_token)
                )
                failure_lines = [str(_native_int(value)) for value in row.tokens[2].split(",")]
            except ValueError as exc:
                raise DeckFormatError(f"{self._at(row)}: malformed FAILURE identifiers") from exc
            fail_time = numeric(row.tokens[3], row, "FAILURE FailTime")
            fail_tension = numeric(row.tokens[4], row, "FAILURE FailTen")
            if failure_id != expected_id or point_id not in point_ids:
                raise DeckFormatError(
                    f"{self._at(row)}: FAILURE IDs must be sequential and reference a point"
                )
            if fail_time <= 0.0 and fail_tension <= 0.0:
                raise DeckFormatError(f"{self._at(row)}: FAILURE needs FailTime > 0 or FailTen > 0")
            if any(
                value not in line_ids or point_id not in line_endpoints[value]
                for value in failure_lines
            ):
                raise DeckFormatError(
                    f"{self._at(row)}: FAILURE line must exist and attach to its point"
                )

        controlled_lines: dict[str, int] = {}
        for row in self._rows("CONTROL"):
            if len(row.tokens) != 2:
                raise DeckFormatError(f"{self._at(row)}: CONTROL row needs 2 fields")
            try:
                control_channel = _native_int(row.tokens[0])
                controlled = [str(_native_int(value)) for value in row.tokens[1].split(",")]
            except ValueError as exc:
                raise DeckFormatError(f"{self._at(row)}: malformed CONTROL identifiers") from exc
            if control_channel < 1 or any(value not in line_ids for value in controlled):
                raise DeckFormatError(
                    f"{self._at(row)}: CONTROL needs a positive channel and known lines"
                )
            for value in controlled:
                if value in controlled_lines and controlled_lines[value] != control_channel:
                    raise DeckFormatError(
                        f"{self._at(row)}: line assigned to multiple CONTROL channels"
                    )
                controlled_lines[value] = control_channel

        # Native finalize_checks: RangeStart opens the window of the LINES flag r graphs.
        range_start = option_by_key.get("range_start")
        if range_start is not None:
            if range_lines == 0:
                raise DeckFormatError(
                    f"{self._label}: OPTION RangeStart needs a line with the LINES Outputs "
                    "flag r (range graph)"
                )
            # a coupled host owns the run time: the native init holds the window against it
            if not self.caller_driven:
                if not has_tmax:
                    raise DeckFormatError(
                        f"{self._label}: OPTION RangeStart needs a dynamic deck (TMax)"
                    )
                tmax_value = _native_float(option_by_key["tmax"].values[0])
                # at TMax = 0 (a dynamic deck's static start) the range graphs hold the t = 0 row
                if _native_float(range_start.values[0]) > tmax_value and tmax_value > 0.0:
                    raise DeckFormatError(
                        f"{self._label}: OPTION RangeStart exceeds TMax: the range window would "
                        "hold no output time"
                    )

        # Native check_channel: ids are digit strings compared by value, so leading zeros
        # are accepted (FairTen01 is FairTen1).
        stiffened_lines = {str(_native_int(row.tokens[0])) for row in self._rows("STIFFENERS")}
        # Point<P>p channels are read from the EI=0 system's point store. The aggregate
        # (a host route, or the standalone mixed deck) has no live entry for a Coupled/Vessel
        # point that only finite-EI lines reach (native validate_aggregate_point_channels);
        # the standalone multibody march has no system without an EI=0 line.
        finite_line_set = set(finite_line_ids)
        cable_points = {
            end
            for line_id, ends in normalized_line_endpoints.items()
            if line_id in finite_line_set
            for end in ends
        }
        chain_points = {
            end
            for line_id, ends in normalized_line_endpoints.items()
            if line_id not in finite_line_set
            for end in ends
        }
        aggregate_points = self.caller_driven or mixed_route
        multibody_without_system = (
            deck_driver_route and needs_multibody and line_ids and all(finite_lines)
        )
        for channel in channels:
            lowered = channel.lower()
            endpoint_channel = re.fullmatch(
                r"(?:fairten|anchten|anchfz|anchfh|fairangle|anchangle|fairdecl|anchdecl"
                r"|fairincl|anchincl)([0-9]+)",
                lowered,
            )
            # Con<P>p{x,y,z} is the native alias of Point<P>p{x,y,z} (MoorDyn v1 spelling).
            position_channel = re.fullmatch(r"(?:point|con)([0-9]+)p([xyz])", lowered)
            # Point<P>F{x,y,z,H}: resultant of the line-end forces on the point.
            point_channel = position_channel or re.fullmatch(r"point([0-9]+)f([xyzh])", lowered)
            # MoorDyn-F body/rod channels (native parse_object_channel, OBJ_QTY)
            body_channel = re.fullmatch(r"body([0-9]+)(?:p|r|v|rv|a|ra|f|m)[xyz]", lowered)
            rod_channel = re.fullmatch(
                r"rod([0-9]+)(?:n([0-9]+)p[xyz]|(?:p|v|rv|a|ra|f|m)[xyz]|r[xy]|tena|tenb|sub)",
                lowered,
            )
            if rod_channel and _channel_id(rod_channel.group(1)) in zero_length_rods:
                raise DeckFormatError(
                    f"{self._label}: OUTPUT {channel!r}: rod "
                    f"{_channel_id(rod_channel.group(1))} has zero length (NumSegs 0) and is "
                    "modelled as a point; report it with Point<P> channels"
                )
            if body_channel:
                body_id = _channel_id(body_channel.group(1))
                if body_id not in body_ids:
                    raise DeckFormatError(
                        f"{self._label}: OUTPUT {channel!r} references an unknown body"
                    )
                if body_types[body_id] != "rigid6":
                    raise DeckFormatError(
                        f"{self._label}: OUTPUT {channel!r}: Body<N> channels report Rigid6 "
                        "bodies; report a Point3 body with its Point<P> channels"
                    )
                continue
            if rod_channel:
                rod_id = _channel_id(rod_channel.group(1))
                if rod_id not in rod_ids:
                    raise DeckFormatError(
                        f"{self._label}: OUTPUT {channel!r} references an unknown rod"
                    )
                if (
                    rod_channel.group(2) is not None
                    and int(rod_channel.group(2)) > (rod_segments[rod_id])
                ):
                    raise DeckFormatError(
                        f"{self._label}: OUTPUT {channel!r}: rod node beyond NumSegs "
                        f"({rod_segments[rod_id]}; node 0 is End A)"
                    )
                continue
            if endpoint_channel:
                if _channel_id(endpoint_channel.group(1)) not in line_ids:
                    raise DeckFormatError(
                        f"{self._label}: OUTPUT {channel!r} references an unknown line"
                    )
                continue
            # FairDefl<L>/AnchDefl<L>: deflection of the end force from a held end's direction
            deflection_channel = re.fullmatch(r"(fair|anch)defl([0-9]+)", lowered)
            if deflection_channel:
                line_id = _channel_id(deflection_channel.group(2))
                if line_id not in line_ids:
                    raise DeckFormatError(
                        f"{self._label}: OUTPUT {channel!r} references an unknown line"
                    )
                end = "a" if deflection_channel.group(1) == "fair" else "b"
                if (line_id, end) not in held_ends:
                    raise DeckFormatError(
                        f"{self._label}: OUTPUT {channel!r}: the deflection angle needs a Rigid or "
                        "rotational-spring END CONNECTIONS row at End "
                        f"{end.upper()} of line {line_id}"
                    )
                continue
            if point_channel:
                # (a POINT row merged into a zero-length rod's connector no longer exists)
                point_id = _channel_id(point_channel.group(1))
                if point_id not in point_ids or point_id in merged_points:
                    raise DeckFormatError(
                        f"{self._label}: OUTPUT {channel!r} references an unknown point"
                    )
                position = position_channel is not None
                if (
                    position
                    and aggregate_points
                    and point_id in cable_points
                    and point_id not in chain_points
                    and point_types.get(point_id) in {"coupled", "vessel"}
                ):
                    raise DeckFormatError(
                        f"{self._label}: aggregate OUTPUT {channel!r} targets a cable-only point; "
                        "use the finite-EI cable line-node position channel instead"
                    )
                if position and multibody_without_system:
                    raise DeckFormatError(
                        f"{self._label}: OUTPUT {channel!r}: Point channels need an EI=0 mooring "
                        "system (a cable-endpoint Point channel is not supported)"
                    )
                continue
            # TDP<L>{s,x,y,z,Lay,Exc,Grd}: the touchdown point of line L (native
            # CD_Parse_TDP_Channel)
            touchdown_channel = re.fullmatch(r"tdp([0-9]{1,9})(?:s|x|y|z|lay|exc|grd)", lowered)
            if touchdown_channel:
                if _channel_id(touchdown_channel.group(1)) not in line_ids:
                    raise DeckFormatError(
                        f"{self._label}: OUTPUT {channel!r} references an unknown line"
                    )
                # native CD_Range_Setup: the touchdown point lies on a seabed, which a standalone
                # deck states itself (a host gives its own water depth)
                if not self.caller_driven and not (has_depth or has_bathymetry):
                    raise DeckFormatError(
                        f"{self._label}: TDP channels of line "
                        f"{_channel_id(touchdown_channel.group(1))} need a seabed (WtrDpth or a "
                        "bathymetry file)"
                    )
                continue
            if lowered.startswith(("torq", "twist")):
                # native: Torq<L>N<J>, Twist<L>N<J> and Twist<L> on a torsional line
                line_number, node_id, kind, _ = _parse_line_node_channel(lowered)
                line_id = str(line_number)
                if (
                    node_id == 0
                    and line_id in line_ids
                    and re.search(r"[0-9]n0(?![0-9])", lowered) is not None
                ):
                    raise DeckFormatError(
                        f"{self._label}: OUTPUT {channel!r}: node numbers start at 1 = End A "
                        "(MoorDyn numbers from N0)"
                    )
                if line_id not in line_ids or kind == 0 or node_id < 1:
                    raise DeckFormatError(
                        f"{self._label}: OUTPUT {channel!r}: bad torsion channel (use "
                        "Torq<L>N<J>, Twist<L>N<J> or Twist<L>, with a known line id)"
                    )
                if node_id > line_nelems[line_id] + 1:
                    raise DeckFormatError(
                        f"{self._label}: OUTPUT {channel!r} node exceeds the line node count"
                    )
                if line_id in torsion_notes:
                    raise DeckFormatError(
                        f"{self._label}: OUTPUT {channel!r}: line {line_id} is torsionally "
                        "restrained at one end only and its torsion is not solved: "
                        f"{torsion_notes[line_id]}"
                    )
                if line_id not in torsion_lines:
                    raise DeckFormatError(
                        f"{self._label}: OUTPUT {channel!r}: line {line_id} is not torsionally "
                        "restrained (END CONNECTIONS TorsStiffness), so it carries no torque"
                    )
                continue
            if lowered.startswith(("ten", "curv", "bendmom", "stfmom", "l")):
                # native parse_line_node_channel: Ten/Curv/BendMom/StfMom<L>N<J>, L<L>N<J>...
                line_number, node_id, kind, _ = _parse_line_node_channel(lowered)
                if (
                    node_id == 0
                    and str(line_number) in line_ids
                    and re.search(r"[0-9]n0(?![0-9])", lowered) is not None
                ):
                    raise DeckFormatError(
                        f"{self._label}: OUTPUT {channel!r}: node numbers start at 1 = End A "
                        "(MoorDyn numbers from N0)"
                    )
                if kind > 0 and node_id >= 1:
                    line_id = str(line_number)
                    if line_id not in line_ids:
                        raise DeckFormatError(
                            f"{self._label}: OUTPUT {channel!r} references an unknown line"
                        )
                    if node_id > line_nelems[line_id] + 1:
                        raise DeckFormatError(
                            f"{self._label}: OUTPUT {channel!r} node exceeds the line node count"
                        )
                    if kind == 12 and line_id not in stiffened_lines:
                        raise DeckFormatError(
                            f"{self._label}: OUTPUT {channel!r}: line {line_id} has no STIFFENERS, "
                            "so no stiffener moment"
                        )
                    if kind in (13, 14) and line_id not in finite_line_ids:
                        raise DeckFormatError(
                            f"{self._label}: OUTPUT {channel!r}: the section curvature components "
                            f"need a finite-EI line (a section frame); line {line_id} has EI = 0 "
                            "(Curv<L>N<J> gives its curvature)"
                        )
                    continue
            raise DeckFormatError(f"{self._label}: unsupported OUTPUT channel {channel!r}")
        try:
            self._check_ancillary_files(
                option_by_key,
                options,
                motion_source,
                mdc_wave_kin,
                mdc_currents,
                has_waves or bool(trains),
                current is not None and current.values[0].lower() != "none",
                (
                    {
                        node
                        for line_id in torsion_lines
                        for node, end in zip(
                            normalized_line_endpoints[line_id], ("a", "b"), strict=True
                        )
                        if torsion_ends.get(line_id, {}).get(end, False)
                        and point_types[node] != "fixed"
                    }
                    if torsion_lines
                    else None
                ),
                bool(finite_length_rods),
                has_rigid6,
                static_check,
            )
        except _AncillaryError as exc:
            raise DeckFormatError(f"{self._label}: {exc}") from None

    def _check_ancillary_files(
        self,
        option_by_key: dict[str, OptionRecord],
        options: tuple[OptionRecord, ...],
        motion_source: str | None,
        mdc_wave_kin: int,
        mdc_currents: int,
        has_sea: bool,
        has_current: bool,
        roll_ends: set[str] | None,
        has_rods: bool,
        has_rigid6: bool,
        static_check: bool,
    ) -> None:
        """Run the native rules of the ancillary files the deck names, those that are there.

        A static check runs on the nominal clock the native parser installs before it validates.
        """

        def number(key: str) -> float | None:
            row = option_by_key.get(key)
            return None if row is None else _native_float(row.values[0])

        dt = _STATIC_CHECK_DT if static_check else number("dtm")
        tmax = number("tmax") or 0.0
        depth = number("water_depth")
        record_dir: float | None = None
        component_headings: list[float] | None = None
        waterkin_row = option_by_key.get("waterkin")
        if waterkin_row is not None and not mdc_wave_kin:
            value = waterkin_row.values[0]
            if value.lower() not in {"", "none", "seastate"} and any(
                character in _WATERKIN_FILENAME_LETTERS for character in value
            ):
                record_dir = self._check_waterkin_file(
                    value, tmax, dt, depth, has_sea, has_current, mdc_currents, option_by_key
                )
        if mdc_wave_kin == 3:
            component_headings = [0.0]
        elif mdc_wave_kin == 7:
            component_headings = self._wave_frequency_headings()
        if mdc_currents:
            name = _MOORDYN_C_CURRENT_FILES[mdc_currents]
            records = self._ancillary_records(name)
            if records is not None:
                check = {
                    1: _check_current_profile,
                    2: _check_dynamic_current,
                    5: _check_grid_current,
                }[mdc_currents]
                check(records, name)
        rows = self._rows("POINTS")
        for key in ("bathymetry",):
            row = option_by_key.get(key)
            if row is None:
                continue
            records = self._ancillary_records(row.values[0])
            if records is not None:
                _check_bathymetry(
                    records,
                    [
                        (
                            _native_int(point.tokens[0]),
                            _native_float(point.tokens[2]),
                            _native_float(point.tokens[3]),
                            _native_float(point.tokens[4]),
                        )
                        for point in rows
                        if point.tokens[1].lower() == "fixed"
                    ],
                )
        self._check_syrope_files()
        if motion_source is None or dt is None or self.caller_driven:
            return
        source = next(o for o in reversed(options) if o.keyword.lower() == motion_source)
        records = self._ancillary_records(source.values[0])
        if records is None:
            return
        if motion_source == "vesselmotion":
            if has_rods or has_rigid6:
                raise _AncillaryError(
                    "vesselMotion/vesselRAO move Coupled/Vessel line points; decks with prescribed "
                    "rods or Rigid6 bodies take motionFile rows"
                )
            _check_vessel_rows(records, dt, tmax, static_check)
        elif motion_source == "vesselrao":
            if has_rods or has_rigid6:
                raise _AncillaryError(
                    "vesselMotion/vesselRAO move Coupled/Vessel line points; decks with prescribed "
                    "rods or Rigid6 bodies take motionFile rows"
                )
            headings = component_headings
            if record_dir is not None:
                headings = [record_dir]
            if headings is None:
                headings = self._sea_headings(option_by_key, options)
            _check_rao_table(records, headings)
        else:
            self._check_motion_file(
                records, dt, tmax, roll_ends, has_rods, has_rigid6, static_check
            )

    def _check_waterkin_file(
        self,
        value: str,
        tmax: float,
        dt: float | None,
        depth: float | None,
        has_sea: bool,
        has_current: bool,
        mdc_currents: int,
        option_by_key: dict[str, OptionRecord],
    ) -> float | None:
        """Mirror ``read_waterkin_records``; returns the WaveDir of a WaveKinMod 1 record."""
        records = self._ancillary_records(value)
        mode = self._waterkin_wave_mode(value)
        if records is None or mode is None:
            return None

        def line(index: int, name: str) -> str:
            if index >= len(records):
                raise _AncillaryError(f"WaterKin file has no {name} line")
            return records[index]

        tokens = line(4, "WaveKinFile").split()
        wave_file = _strip_quotes(tokens[0]) if tokens else ""
        tokens = line(5, "dtWave").split()
        dt_wave = _token_real(tokens[0]) if tokens else None
        if dt_wave is None or dt_wave < 0.0:
            raise _AncillaryError("WaterKin dtWave must be finite and non-negative")
        tokens = line(6, "WaveDir").split()
        wave_dir = _token_real(tokens[0]) if tokens else None
        if wave_dir is None:
            raise _AncillaryError("WaterKin WaveDir must be finite")
        if len(records) < 13:
            raise _AncillaryError("WaterKin file ended inside the waves block")
        if mode == 1:
            if self.caller_driven:
                raise _AncillaryError(
                    "WaterKin WaveKinMod 1 is supported only by the standalone driver; coupled "
                    "aggregate runs must use WaveKinMod 2/SEASTATE through external_fluid"
                )
            if not wave_file:
                raise _AncillaryError("WaterKin WaveKinMod 1 requires WaveKinFile")
            if dt_wave <= 0.0:
                raise _AncillaryError("WaterKin WaveKinMod 1 requires positive dtWave")
            if has_sea:
                raise _AncillaryError(
                    "the deck declares BOTH a waves OPTION and WaterKin WaveKinMod 1 "
                    "(double-counting); keep one"
                )
            if dt is None or depth is None:
                raise _AncillaryError("deck waves require dtM, TMax and WtrDpth")
            history = self._ancillary_records(wave_file)
            if history is None:
                history = self._ancillary_records(
                    str(self._ancillary_path(value).parent / wave_file)
                )
            if history is not None:
                cutoff_row = option_by_key.get("wvhicoff")
                cutoff = math.pi
                if cutoff_row is not None:
                    cutoff = (
                        -1.0
                        if cutoff_row.values[0].lower() == "none"
                        else _native_float(cutoff_row.values[0])
                    )
                _check_elevation_record(history, dt_wave, tmax, cutoff, depth)
        elif mode == 2 and not self.caller_driven:
            raise _AncillaryError(
                "WaterKin WaveKinMod 2/SEASTATE is coupled-only; the standalone driver has no host "
                "SeaState field"
            )
        line(13, "current header")
        tokens = line(14, "CurrentMod").split()
        if not tokens or re.fullmatch(r"[+-]?[0-9]{1,18}", tokens[0]) is None:
            raise _AncillaryError("WaterKin CurrentMod must be an integer (0, 1, or 2)")
        current_mode = int(tokens[0])
        if not 0 <= current_mode <= 2:
            raise _AncillaryError(
                "WaterKin CurrentMod supports 0 (none), 1 (depth profile), or 2 (SeaState hybrid)"
            )
        if current_mode == 2:
            if mode == 1:
                raise _AncillaryError(
                    "WaterKin WaveKinMod 1 plus CurrentMod 2 mixes self-driven waves with a host "
                    "SeaState current, which the nodewise host field cannot separate"
                )
            if not self.caller_driven:
                raise _AncillaryError(
                    "WaterKin WaveKinMod 2/SEASTATE is coupled-only; the standalone driver has no "
                    "host SeaState field"
                )
        if current_mode == 1:
            _check_waterkin_current(records[15:])
            if has_current:
                raise _AncillaryError(
                    "the deck declares BOTH a current OPTION and a WaterKin current "
                    "(double-counting); keep one"
                )
            if mdc_currents:
                raise _AncillaryError(
                    "the deck declares BOTH a current OPTION (or a WaterKin current) and "
                    f"Currents {mdc_currents} (double-counting); keep one"
                )
        return wave_dir if mode == 1 else None

    def _wave_frequency_headings(self) -> list[float] | None:
        """The directions [deg] of the components of ``wave_frequencies.txt``, if it is there."""
        records = self._ancillary_records(_MOORDYN_C_WAVE_FILES[7])
        if records is None:
            return None
        headings = [
            math.degrees(math.atan2(math.sin(beta), math.cos(beta)))
            for omega, real_part, imaginary, beta in _wave_frequency_rows(records, "")
            if omega > 0.0 and math.hypot(real_part, imaginary) > 0.0
        ]
        return headings

    def _sea_headings(
        self, option_by_key: dict[str, OptionRecord], options: tuple[OptionRecord, ...]
    ) -> list[float]:
        """The headings of a deck's own sea, as ``CD_Sea_Synthesise`` lays them out."""
        bins_row = option_by_key.get("wave_directions")
        bins = _SEA_DEFAULT_DIRECTIONS
        if bins_row is not None and round(_native_float(bins_row.values[0])) > 0:
            bins = round(_native_float(bins_row.values[0]))
        spreading_row = option_by_key.get("wave_spreading")
        spreading = 0.0 if spreading_row is None else _native_float(spreading_row.values[0])
        headings: list[float] = []
        waves = option_by_key.get("waves")
        if waves is not None and waves.values[0].lower() != "none":
            direction, _ = _train_direction(waves.values)
            headings.extend(_spread_headings(direction, spreading, bins))
        for option in options:
            if option.keyword.lower() in _WAVETRAIN_KEYWORDS:
                direction, own = _train_direction(option.values)
                headings.extend(_spread_headings(direction, own, bins))
        return headings

    def _check_syrope_files(self) -> None:
        """Mirror ``read_syrope_settings``, and ``CD_Syrope_Init`` for the types lines use."""
        used = {row.tokens[1].lower() for row in self.sections}
        for row in self.line_types:
            parts = row.tokens[3].split("|")
            if not parts[0].lower().startswith("syrope:"):
                continue
            records = self._ancillary_records(parts[0][len("syrope:") :])
            if records is None:
                continue
            owc, shape, k1, k2 = _read_syrope_settings(records)
            settings = self._ancillary_path(parts[0][len("syrope:") :])
            name = _strip_quotes(owc)
            absolute = name.startswith(("/", "\\")) or name[1:2] == ":"
            table = self._ancillary_records(name if absolute else str(settings.parent / name))
            if table is None:
                continue
            rows = _read_syrope_table(table)
            if row.tokens[0].lower() in used:
                _check_syrope_curve(
                    rows, shape, k1, k2, _native_float(parts[1]), _native_float(parts[2])
                )

    def _check_motion_file(
        self,
        records: list[str],
        dt: float,
        tmax: float,
        roll_ends: set[str] | None,
        has_rods: bool,
        has_rigid6: bool,
        start_row_only: bool,
    ) -> None:
        """Mirror ``read_motion_file`` on the route the native dispatch takes.

        Only the routes with lines read the file, and only those of lines alone its roll column.
        """
        if not self.lines and (has_rods or has_rigid6):
            return
        moved = {"coupled", "vessel"}
        ids: dict[int, str] = {
            _native_int(row.tokens[0]): row.tokens[1].lower() for row in self.points
        }
        turbine_rows = self._rows("TURBINES")
        eligible: set[int] | None = {
            point for point, kind in ids.items() if kind in moved or _is_turbine_point_type(kind)
        }
        if has_rods and has_rigid6:
            eligible = None
        elif has_rods:
            assert eligible is not None
            eligible |= {point for point, kind in ids.items() if _rod_point(kind) is not None}
        elif has_rigid6:
            assert eligible is not None
            eligible |= {point for point, kind in ids.items() if kind.startswith("body")}
        if eligible is not None and not eligible:
            raise _AncillaryError("motionFile requires at least one Coupled/Vessel point")
        turbines: dict[int, list[int]] | None = None
        if turbine_rows:
            turbines = {_native_int(row.tokens[0]): [] for row in turbine_rows}
            for point, kind in ids.items():
                if _is_turbine_point_type(kind):
                    turbines.setdefault(_turbine_id(kind), []).append(point)
        _check_motion_rows(
            records,
            dt,
            tmax,
            eligible,
            None
            if roll_ends is None or has_rods or has_rigid6
            else {int(point) for point in roll_ends},
            turbines,
            start_row_only,
        )

    def _ancillary_path(self, value: str) -> Path:
        """Return the file an ancillary value names, as the native ``path_join``."""
        name = _strip_quotes(value)
        absolute = name.startswith(("/", "\\")) or name[1:2] == ":"
        return Path(name) if absolute else self.path.parent / name

    def _ancillary_records(self, value: str) -> list[str] | None:
        """Return the records of the ancillary file ``value`` names, ``None`` if it is not there.

        A relative name is taken from the deck's folder.
        """
        source = self._ancillary_path(value)
        try:
            payload = source.read_bytes()
        except OSError:
            return None
        records, _ = _split_records(payload.decode("utf-8", "surrogateescape"))
        if records and records[0].startswith(_UTF8_BOM):
            records[0] = records[0][len(_UTF8_BOM) :]
        return records

    def _waterkin_wave_mode(self, value: str) -> int | None:
        """Return the ``WaveKinMod`` of WaterKin file ``value``, ``None`` if it is not there.

        Mirrors the head of the native ``read_waterkin_records``: two header lines, a waves
        header, then the WaveKinMod line.
        """
        records = self._ancillary_records(value)
        if records is None:
            return None
        if len(records) < 3:
            raise DeckFormatError(f"{self._label}: WaterKin file ended inside its header")
        if len(records) < 4:
            raise DeckFormatError(f"{self._label}: WaterKin file has no WaveKinMod line")
        tokens = records[3].split()
        if not tokens:
            raise DeckFormatError(f"{self._label}: WaterKin WaveKinMod line has no value")
        if _strip_quotes(tokens[0]).lower() == "seastate":
            return 2
        if re.fullmatch(r"[+-]?[0-9]{1,18}", tokens[0]) is None:
            raise DeckFormatError(
                f"{self._label}: WaterKin WaveKinMod must be 0, 1, 2, or SEASTATE"
            )
        mode = int(tokens[0])
        if not 0 <= mode <= 2:
            raise DeckFormatError(
                f"{self._label}: WaterKin WaveKinMod supports 0 (none), 1 (elevation history), "
                "or 2 (coupled SeaState hybrid)"
            )
        return mode

    def _check_wave_frequencies(self, depth: float) -> None:
        """Check ``wave_frequencies.txt`` in the deck's folder, if it is there.

        Mirrors the ``WaveKin 7`` branch of the native ``read_moordyn_c_kinematics``, the
        component bounds of its validation and the effective depth of the wave precompute.
        A row takes four numbers, or three and a direction of zero.
        """
        records = self._ancillary_records(_MOORDYN_C_WAVE_FILES[7])
        if records is None:
            return
        label = f"{self._label}: WaveKin 7: wave_frequencies.txt"
        rows = _wave_frequency_rows(records, label)
        if len(rows) < 2:
            raise DeckFormatError(f"{label} needs at least two `omega Re Im` rows")
        if rows[0][0] != 0.0:
            raise DeckFormatError(f"{label}: the first row must be at omega = 0")
        for index, (omega, real_part, imaginary, beta) in enumerate(rows):
            if abs(beta) > 2.0 * math.pi:
                raise DeckFormatError(f"{label} directions are radians within +-2 pi")
            if index == 0:
                continue
            if omega <= 0.0:
                raise DeckFormatError(f"{label} frequencies after the first row must be positive")
            if math.hypot(real_part, imaginary) > 1.0e3 or omega > 1.0e4:
                raise DeckFormatError(
                    f"{label} components need amplitudes of at most 1e3 m and frequencies of "
                    "at most 1e4 rad/s"
                )
        if depth + rows[0][2] <= 0.0:
            raise DeckFormatError(f"{label}: the mean level leaves a non-positive effective depth")

    def _check_torsion_normal(
        self,
        where: str,
        row: DeckRecord,
        normal: list[float],
        direction: list[float],
        direction_norm: float,
    ) -> None:
        """Native ``append_end_connection``: a restrained end's normal is non-zero, not along Ez."""
        normal_norm = math.sqrt(sum(value * value for value in normal))
        if not math.isfinite(normal_norm) or normal_norm <= math.sqrt(sys.float_info.min):
            raise DeckFormatError(
                f"{where} END CONNECTIONS torsion reference normal "
                f"(NxX NxY NxZ) must be non-zero, got ({', '.join(row.tokens[7:10])})"
            )
        nx = [value / normal_norm for value in normal]
        ez = [value / direction_norm for value in direction]
        parallel = math.sqrt(
            (nx[1] * ez[2] - nx[2] * ez[1]) ** 2
            + (nx[2] * ez[0] - nx[0] * ez[2]) ** 2
            + (nx[0] * ez[1] - nx[1] * ez[0]) ** 2
        )
        if parallel < _TORSION_NORMAL_PARALLEL_TOL:
            raise DeckFormatError(
                f"{where} END CONNECTIONS torsion reference normal "
                f"(NxX NxY NxZ) ({', '.join(row.tokens[7:10])}) must not be parallel to the "
                f"direction Ez ({', '.join(row.tokens[3:6])})"
            )

    def _check_multibody_cable_ends(
        self,
        finite_line_ids: list[str],
        normalized_line_endpoints: dict[str, tuple[str, str]],
        point_types: dict[str, str],
        body_types: dict[str, str],
        held_ends: set[tuple[str, str]],
        torsion_held: set[tuple[str, str]],
        scheme_row: OptionRecord | None,
    ) -> None:
        """Native write_multibody_dynamic_out: the ends of a finite-EI cable on the multibody march.

        End B may be a Fixed point, a Rigid6 body point or a rod end; a Free/Connect point or a
        Point3 buoy, and a Coupled/Vessel point (no motion drives it there), are refused. A
        connected (Rigid or spring) or torsional end on a body or rod needs bodyScheme
        monolithic; torsion_held lists the (line, end) pairs restrained in torsion of the lines
        solved in torsion (an end free in torsion holds no frame).
        """
        staggered = (
            scheme_row is not None and _strip_quotes(scheme_row.values[0]).lower() == "staggered"
        )
        for line_id in finite_line_ids:
            end_a, end_b = normalized_line_endpoints[line_id]
            type_a = point_types.get(end_a, end_a)
            type_b = point_types.get(end_b, end_b)
            body_b = _body_point_id(type_b)
            if type_b in {"free", "connect"} or (
                body_b > 0 and body_types.get(str(body_b), "rigid6") == "point3"
            ):
                raise DeckFormatError(
                    f"{self._label}: finite-EI LINE {line_id} in a mixed-topology deck: End B is "
                    f"POINT {end_b} ({type_b}); a cable end on a Free/Connect point or a Point3 "
                    "buoy is not supported on the multibody march. End the cable on a Fixed "
                    "point, a Rigid6 body point or a rod end"
                )
            if type_b in {"coupled", "vessel"}:
                raise DeckFormatError(
                    f"{self._label}: finite-EI LINE {line_id}: a Coupled/Vessel End B (POINT "
                    f"{end_b}) would need motionFile coupling to drive it, which a mixed-topology "
                    "deck marched as one multibody system does not support"
                )
            if not staggered:
                continue
            for end, point_type in (("a", type_a), ("b", type_b)):
                if point_type == "fixed":
                    continue
                if (line_id, end) in held_ends or (line_id, end) in torsion_held:
                    raise DeckFormatError(
                        f"{self._label}: finite-EI LINE {line_id}: a clamped or elastic END "
                        "CONNECTION or a torsional one on a body or rod needs bodyScheme "
                        "monolithic (the staggered scheme couples cable ends as point forces)"
                    )

    def _check_torsion_lines(
        self,
        torsion_ends: dict[str, dict[str, bool]],
        torsion_pretwist: dict[str, dict[str, float]],
        section_types_by_line: dict[str, list[str]],
        line_type_meta: dict[str, tuple[float, float, float, float]],
        line_type_gj: dict[str, float],
        normalized_line_endpoints: dict[str, tuple[str, str]],
        point_types: dict[str, str],
        body_types: dict[str, str],
        option_by_key: dict[str, OptionRecord],
        has_tmax: bool,
    ) -> tuple[set[str], dict[str, str]]:
        """Native ``check_torsion_line`` and the driver's torsion scope.

        Returns the lines solved in torsion and, for a line restrained at one end only whose
        torsion is not solved, why (native ``resolve_one_end_torsion``).

        A line with a torsional END CONNECTIONS restraint (TorsStiffness Rigid or a
        stiffness) must be finite-EI. Restrained at both ends, torsion is solved: End B must
        be Fixed, Coupled/Vessel or a Rigid6 body point (not a rod end), every section type
        needs an explicit GJ > 0, End A neither on a rod other than a Fixed one (a free or
        pinned rod has no roll angle, a Coupled/Vessel rod carries no finite-EI line; the ends of
        a rod fixed to a body are body points; a Fixed rod's with a Fixed End B) nor either end
        on a body other than Rigid6. Restrained at one end only (its other end free to twist), it
        is solved in torsion under the same rules and with a force-blended march; otherwise it
        keeps the meaning of the 6-column rows (no error). ATTACHMENTS, CONTROL and the modal
        analysis (nModes, whose modes carry the twist) take a line solved in torsion. A deck with
        torsion runs dynamics only with the force-blended generalised-alpha (a coupled run is
        always dynamic). The coupled OpenFAST and FAST.Farm routes turn the fairlead frame with
        the platform, and the standalone mixed EI = 0 + finite-EI deck without bodies (run on the
        aggregate) holds it or turns it with its vesselMotion and rolls it with the motionFile
        roll column, as the standalone cubic-Hermite route does.
        """
        rod_kinds = self._rod_rows_by_id()
        tmax_row = option_by_key.get("tmax")
        # a coupled run is always dynamic (the host owns TMax)
        dynamic = self.caller_driven or (
            has_tmax and tmax_row is not None and _native_float(tmax_row.values[0]) > 0.0
        )
        blend_row = option_by_key.get("alpha_force_blend")
        force_blend = blend_row is None or blend_row.values[0].lower() in {
            "true",
            "t",
            "yes",
            "y",
            "on",
            "1",
        }
        torsion_lines: set[str] = set()
        torsion_notes: dict[str, str] = {}
        for line_id, ends in torsion_ends.items():
            if not any(ends.values()):
                continue
            if not any(line_type_meta[name][3] > 0.0 for name in section_types_by_line[line_id]):
                raise DeckFormatError(
                    f"{self._label}: torsional END CONNECTIONS (TorsStiffness Rigid or a "
                    f"stiffness) require a finite-EI line; line {line_id} has EI = 0"
                )
            if not (ends.get("a", False) and ends.get("b", False)):
                # one restrained end: solved where the rules hold, noted otherwise
                end_a, end_b = normalized_line_endpoints[line_id]
                note = ""
                if not all(line_type_gj[name] > 0.0 for name in section_types_by_line[line_id]):
                    note = (
                        "its LINE TYPES rows give no GJ (the 14-column row; torsion has no "
                        "EI/1.3 default)"
                    )
                elif point_types[end_b] != "fixed":
                    note = "it has two moving ends (torsion needs a Fixed End B)"
                elif dynamic and not force_blend:
                    note = (
                        "torsion in a dynamic run needs the force-blended generalised-alpha "
                        "(alpha_force_blend True)"
                    )
                elif ends.get("a", False):
                    body_id = _body_point_id(point_types[end_a])
                    rod_end = _rod_point(point_types[end_a])
                    rod_kind = None if rod_end is None else rod_kinds.get(rod_end[0], (None, 0))[0]
                    if rod_end is not None and rod_kind is not None and rod_kind != "fixed":
                        if rod_kind in {"coupled", "vessel"}:
                            note = (
                                "its restrained End A is on a Coupled/Vessel rod end (no route "
                                "carries a finite-EI line on a host-driven rod)"
                            )
                        else:
                            note = (
                                "its restrained End A is on the end of a free or pinned rod "
                                "(axisymmetric, with no roll angle to hold the torque)"
                            )
                    elif body_id > 0 and body_types.get(str(body_id), "rigid6") != "rigid6":
                        note = "its restrained End A is on a body that is not Rigid6"
                if note:
                    torsion_notes[line_id] = note
                    continue
                # native check_torsion_line: the restrained end's pretwist is the imposed twist
                restrained_end = "a" if ends.get("a", False) else "b"
                twist = torsion_pretwist[line_id].get(restrained_end, 0.0)
                if abs(twist) > _MAX_STATIC_TWIST_DEG:
                    raise DeckFormatError(
                        f"{self._label}: line {line_id}: the Pretwist of its restrained End "
                        f"{restrained_end.upper()} = {twist:.5e} deg exceeds 1000 turns "
                        "(360000 deg), the largest twist"
                    )
                torsion_lines.add(line_id)
                continue
            twist = torsion_pretwist[line_id]["b"] - torsion_pretwist[line_id]["a"]
            if abs(twist) > _MAX_STATIC_TWIST_DEG:
                raise DeckFormatError(
                    f"{self._label}: line {line_id}: the imposed twist Pretwist(B) - Pretwist(A) = "
                    f"{twist:.5e} deg exceeds 1000 turns (360000 deg), the largest static twist"
                )
            end_a, end_b = normalized_line_endpoints[line_id]
            # End B is held at a Fixed point or driven with its own frame at a Coupled/Vessel point
            # (a line between two moving points) or on a body point (a line between two objects)
            if not _end_b_holds_frame(point_types[end_b]):
                raise DeckFormatError(
                    f"{self._label}: torsional END CONNECTIONS need End B on a Fixed, Coupled or "
                    f"Vessel point or a Rigid6 body point; line {line_id} ends on a "
                    f'"{point_types[end_b]}" point'
                )
            for name in section_types_by_line[line_id]:
                if not line_type_gj[name] > 0.0:
                    raise DeckFormatError(
                        f"{self._label}: line {line_id} is torsionally restrained at both ends: "
                        f'its LINE TYPES row "{name}" must give an explicit GJ > 0 (the 14-column '
                        "row; torsion has no EI/1.3 default)"
                    )
            if _rod_point(point_types[end_b]) is not None:
                raise DeckFormatError(
                    f"{self._label}: line {line_id}: a torsional END CONNECTION on a rod end is "
                    "not supported at End B: restrain the line at the rod end through its End A "
                    "(a Fixed rod, or a rod fixed to a Rigid6 body, RODS type Body<N>), or end it "
                    "on a Fixed point at a Fixed rod end's position (its force then stays out of "
                    "that rod's Rod<N> loads)"
                )
            rod_end = _rod_point(point_types[end_a])
            rod_kind = None if rod_end is None else rod_kinds.get(rod_end[0], (None, 0))[0]
            if rod_end is not None and rod_kind is not None and rod_kind != "fixed":
                if re.fullmatch(r"body[0-9]+pin", rod_kind):
                    rod_kind += "ned"
                if rod_kind in {"coupled", "vessel"}:
                    raise DeckFormatError(
                        f"{self._label}: line {line_id}: a torsional END CONNECTION on the end of "
                        f"Coupled/Vessel ROD {rod_end[0]} is not supported: no route of this build "
                        "carries a finite-EI line on a host-driven rod"
                    )
                raise DeckFormatError(
                    f"{self._label}: line {line_id}: a torsional END CONNECTION on the end of ROD "
                    f"{rod_end[0]} ({rod_kind}) is not supported: a free or pinned rod is "
                    "axisymmetric, with no roll about its own axis (no load acts about the axis "
                    "and its static solve has no roll angle), so it cannot hold the line's torque; "
                    "restrain End A on a Fixed rod, on a rod fixed to a Rigid6 body (RODS type "
                    "Body<N>), on a Rigid6 body point or on a Fixed point"
                )
            if rod_end is not None and point_types[end_b] != "fixed":
                raise DeckFormatError(
                    f"{self._label}: line {line_id}: a torsional END CONNECTION on a rod end needs "
                    "a Fixed End B (a line restrained in torsion between a rod end and a moving "
                    "object is not supported in this build)"
                )
            # either end on a non-Rigid6 body (End B on a body point: a line between two objects)
            for end_point in (end_a, end_b):
                body_id = _body_point_id(point_types[end_point])
                if body_id > 0 and body_types.get(str(body_id), "rigid6") != "rigid6":
                    raise DeckFormatError(
                        f"{self._label}: line {line_id}: a torsional END CONNECTION on a body "
                        "needs a Rigid6 body"
                    )
            torsion_lines.add(line_id)
        if not torsion_lines:
            return torsion_lines, torsion_notes
        if dynamic and not force_blend:
            raise DeckFormatError(
                f"{self._label}: torsion in a dynamic run needs the force-blended "
                "generalised-alpha (OPTION alpha_force_blend True)"
            )
        return torsion_lines, torsion_notes

    def _line_type_fields(self, record: DeckRecord) -> tuple[str, ...]:
        fields = _FIELDS["line_type"]
        if len(record.tokens) == 14:
            return (*fields[:6], "gas", "gj", "irt", "irn", "cdn", "cdt", "can", "cat")
        # MoorDyn's optional cross-flow VIV columns follow the ten standard ones
        viv = {11: ("cl",), 13: ("cl", "df", "cf")}.get(len(record.tokens), ())
        if self._stock_line_type_columns(record):
            return (*fields[:6], "cd", "ca", "cdax", "caax", *viv)
        return (*fields, *viv)

    def _line_section_records(self, line_id: int) -> list[tuple[DeckRecord, tuple[str, ...], str]]:
        """Return one line's native section sequence in deck (End A to End B) order.

        A stock 7-column LINES row is an implicit section at its own position in
        the file, so it is numbered together with that line's explicit SECTIONS
        rows exactly as the native reader appends them.
        """
        found: list[tuple[DeckRecord, tuple[str, ...], str]] = [
            (row, _FIELDS["section"], "SECTIONS")
            for row in self.sections
            if _native_int(row.tokens[0]) == line_id
        ]
        found.extend(
            (row, _STOCK_LINE_FIELDS, "LINES")
            for row in self.lines
            if len(row.tokens) == 7 and _native_int(row.tokens[0]) == line_id
        )
        found.sort(key=lambda item: item[0].index)
        return found

    def _section_record(
        self, line_id: int, occurrence: int
    ) -> tuple[DeckRecord, tuple[str, ...], str]:
        matches = self._line_section_records(line_id)
        if not 1 <= occurrence <= len(matches):
            raise KeyError(f"line {line_id} section occurrence {occurrence} does not exist")
        return matches[occurrence - 1]

    def _point_record(self, point_id: int) -> DeckRecord:
        record = next((row for row in self.points if _native_int(row.tokens[0]) == point_id), None)
        if record is None:
            raise KeyError(f"point {point_id} does not exist")
        return record

    def _end_connection_record(self, line_id: int, end: str) -> DeckRecord:
        canonical_end = _end_connection_end(end)
        record = next(
            (
                row
                for row in self.end_connections
                if _native_int(row.tokens[0]) == line_id
                and _end_connection_end(row.tokens[1]) == canonical_end
            ),
            None,
        )
        if record is None:
            raise KeyError(f"line {line_id} End {canonical_end.upper()} connection does not exist")
        return record

    def _render_record(
        self,
        record: DeckRecord,
        field_names: tuple[str, ...],
        section: str,
        changes: Mapping[str, object],
    ) -> str:
        """Return ``record``'s source line with the ``changes`` columns re-rendered.

        Untouched columns keep their source token text; the data tokens are
        joined by single spaces, and the leading indentation and everything
        after the last data token (including an inline comment) are kept.
        """
        lookup = {name.lower(): index for index, name in enumerate(field_names)}
        replaced: dict[int, object] = {}
        for field_name, value in changes.items():
            index = lookup.get(field_name.lower())
            if index is None:
                raise KeyError(f"unknown field {field_name!r}; expected {', '.join(field_names)}")
            if index >= len(record.tokens):
                raise KeyError(
                    f"{self._label}:{record.index + 1}: this {section} row has no "
                    f"{field_name} column"
                )
            replaced[index] = value
        line = self._lines[record.index]
        spans = _quoted_token_spans(_strip_inline_comment(line))
        text_columns = _text_columns(section, len(record.tokens))
        tokens: list[str] = []
        for index, (start, stop) in enumerate(spans):
            if index not in replaced:
                tokens.append(line[start:stop])
                continue
            new = replaced[index]
            if (
                section == "LINE TYPES"
                and index == 3
                and isinstance(new, str)
                and new.lower().startswith("syrope:")
            ):
                # The Syrope EA value embeds a settings path; it is always quoted so a
                # list-directed READ takes it whole, and a path may contain spaces.
                value = f'"{_render_quoted_text(new)}"'
            else:
                value = _render(new, text=index in text_columns)
            tokens.append(value)
        return line[: spans[0][0]] + " ".join(tokens) + line[spans[-1][1] :]

    def _replace_record(
        self,
        record: DeckRecord,
        field_names: tuple[str, ...],
        section: str,
        changes: Mapping[str, object],
    ) -> None:
        self._edit_line(record.index, self._render_record(record, field_names, section, changes))

    def _edit_line(self, index: int, replacement: str) -> None:
        original = self._lines[index]
        was_edited = self._edited
        self._lines[index] = replacement
        self._edited = True
        try:
            self._scan()
            if not self._defer_validation:
                self.validate()
        except BaseException:
            self._lines[index] = original
            self._edited = was_edited
            self._scan()
            raise

    def _resolve_selector(
        self, selector: str
    ) -> tuple[DeckRecord, tuple[str, ...], str, str] | str:
        """Resolve a table selector to (record, fields, section, field) or an option keyword."""
        if not isinstance(selector, str):
            raise ValueError(f"deck selectors must be strings, got {selector!r}")
        if selector.lower().startswith("line_type."):
            name, separator, field_name = selector[len("line_type.") :].rpartition(".")
            if not (separator and name and field_name):
                raise ValueError(f"unsupported deck selector {selector!r}")
            record = self._find(self.line_types, name, "line type", casefold=True)
            return record, self._line_type_fields(record), "LINE TYPES", field_name
        parts = selector.split(".")
        kind = parts[0].lower()
        if len(parts) == 2 and kind == "option" and parts[1]:
            return parts[1]
        if len(parts) == 3 and kind == "point" and parts[2]:
            record = self._point_record(_selector_int(parts[1], "point id"))
            return record, _FIELDS["point"], "POINTS", parts[2]
        if len(parts) == 4 and kind == "section" and parts[3]:
            record, fields, section = self._section_record(
                _selector_int(parts[1], "section line id"),
                _selector_int(parts[2], "section occurrence"),
            )
            return record, fields, section, parts[3]
        if len(parts) == 4 and kind == "end_connection" and parts[3]:
            record = self._end_connection_record(
                _selector_int(parts[1], "end-connection line id"),
                parts[2],
            )
            return record, _FIELDS["end_connection"], "END CONNECTIONS", parts[3]
        raise ValueError(f"unsupported deck selector {selector!r}")

    def apply_many(self, changes: Mapping[str, object]) -> None:
        """Apply coordinated selectors transactionally, then validate the final deck.

        Every selector is resolved against the deck as it was before the batch,
        so one selector may rename an id or name that another still addresses.
        Two selectors that address the same field or option (for example
        ``point.2.z`` and ``Point.2.Z``) raise ``ValueError``; on any error the
        deck is left unchanged.

        Parameters
        ----------
        changes : collections.abc.Mapping[str, object]
            ``{selector: value}``; selectors are described in :meth:`apply`.
            Values are in the deck's SI units (m, kg/m, N, s).

        Raises
        ------
        KeyError
            If a selector addresses a record, field, or option the deck lacks.
        ValueError
            If a selector is malformed, two selectors address the same field or
            option, or a value cannot be rendered as one native token.
        DeckFormatError
            If the edited deck violates the native deck contract.
        """
        original = self._lines.copy()
        was_edited = self._edited
        self._defer_validation = True
        try:
            record_batches: dict[
                int, tuple[DeckRecord, tuple[str, ...], str, dict[str, object]]
            ] = {}
            addressed: dict[tuple[int, str], str] = {}
            option_edits: dict[str, tuple[str, object, str]] = {}
            for selector, value in changes.items():
                target = self._resolve_selector(selector)
                if isinstance(target, str):
                    key = _option_key(target)
                    if key in option_edits:
                        raise ValueError(
                            f"selectors {option_edits[key][2]!r} and {selector!r} address "
                            "the same option"
                        )
                    option_edits[key] = (target, value, selector)
                    continue
                record, fields, section, field_name = target
                lookup = {name.lower(): index for index, name in enumerate(fields)}
                column = lookup.get(field_name.lower())
                if column is None:
                    raise KeyError(f"unknown field {field_name!r}; expected {', '.join(fields)}")
                if (record.index, fields[column]) in addressed:
                    raise ValueError(
                        f"selectors {addressed[(record.index, fields[column])]!r} and "
                        f"{selector!r} address the same deck field"
                    )
                addressed[(record.index, fields[column])] = selector
                batch = record_batches.setdefault(record.index, (record, fields, section, {}))
                if batch[1] != fields:
                    raise ValueError("incompatible selectors address the same deck row")
                batch[3][field_name] = value

            for keyword, value, _ in option_edits.values():
                self.set_option(keyword, value)
            for record, fields, section, staged in record_batches.values():
                self._replace_record(record, fields, section, staged)
            self._defer_validation = False
            self._edited = True
            self._scan()
            self.validate()
        except BaseException:
            self._defer_validation = False
            self._lines = original
            self._edited = was_edited
            self._scan()
            raise

    def set_option(self, keyword: str, value: object | tuple[object, ...] | list[object]) -> None:
        """Replace the value(s) of the effective row for ``keyword``.

        Scalar rows take one value; ``dynamic_solver`` and the positional
        ``waves``/``current`` forms take a sequence. The keyword, commentary,
        description, and inline comment of the row are kept. The option must
        already be present in the deck.

        Parameters
        ----------
        keyword : str
            Option keyword or native alias (case-insensitive).
        value : object | tuple[object, ...] | list[object]
            New value, in the option's SI unit, or a sequence of values for a
            multi-value row. Each value must render as one native token.

        Raises
        ------
        KeyError
            If the deck does not set the option.
        ValueError
            If a value cannot be rendered as one native token or the values do
            not fit the row's form.
        DeckFormatError
            If the edited deck violates the native deck contract.
        """
        record = self.option(keyword)
        values = tuple(value) if isinstance(value, (tuple, list)) else (value,)
        rendered = [_render(item) for item in values]
        line = self._lines[record.index]
        spans = _token_spans(_strip_inline_comment(line))
        consumed = len(record.values) + 1
        keyword_token = line[slice(*spans[0 if record.keyword_first else consumed - 1])]
        suffix = line[spans[consumed - 1][1] :]
        if record.keyword_first:
            if record.keyword.lower() == "dynamic_solver" and not _dynamic_solver_values_are_valid(
                rendered
            ):
                raise ValueError(
                    "option dynamic_solver needs positive finite tolerances, max_iter >= 1, "
                    "backtracks >= 0, and optional rhoInf in [0, 1]"
                )
            tokens = [keyword_token, *rendered]
        elif _option_key(record.keyword) in {"waves", "current"} or (
            record.keyword.lower() in _WAVETRAIN_KEYWORDS
        ):
            tokens = [*rendered, keyword_token]
            if not _is_positional_option(tokens) or not _positional_numbers_are_finite(tokens):
                raise ValueError(
                    f"option {keyword} requires a native none/uniform/profile/airy/jonswap form"
                )
            if error := _positional_range_error(tokens):
                raise ValueError(f"option {keyword} {error}")
            if len(tokens) > 2 and record.trailing:
                # Positional rows end at their keyword: keep the old commentary
                # behind a description separator so it is not read as values.
                suffix = " -" + suffix
        else:
            if len(rendered) != 1:
                raise ValueError(f"option {keyword} accepts one value in this editor")
            tokens = [rendered[0], keyword_token]
        self._edit_line(record.index, line[: spans[0][0]] + " ".join(tokens) + suffix)

    def set_point(self, point_id: int, **changes: object) -> None:
        """Edit columns of the POINTS row with ``point_id``.

        Keyword names are column names, case-insensitive: ``id``, ``type``,
        ``x``, ``y``, ``z``, ``mass``, ``vol``, ``cda``, and ``ca``. For
        example, ``deck.set_point(3, z=-150.0)``.

        Parameters
        ----------
        point_id : int
            Point identifier.
        **changes : object
            New column values: positions in m, mass in kg, volume in m^3,
            ``cda`` in m^2, and ``ca`` dimensionless.

        Raises
        ------
        KeyError
            If the point or a column does not exist.
        ValueError
            If a value cannot be rendered as one native token.
        DeckFormatError
            If the edited deck violates the native deck contract.
        """
        record = self._point_record(_selector_int(point_id, "point id"))
        self._replace_record(record, _FIELDS["point"], "POINTS", changes)

    def set_line_type(self, line_type_name: str, **changes: object) -> None:
        """Edit columns of the LINE TYPES row named ``line_type_name`` (case-insensitive).

        Keyword names are column names, case-insensitive: ``name``, ``diam``,
        ``mass``, ``ea``, ``ba``, ``ei``, and the hydrodynamic coefficients in
        the column convention the row uses (``cdn``, ``cdt``, ``can``, ``cat``,
        or ``cd``, ``ca``, ``cdax``, ``caax``).

        Parameters
        ----------
        line_type_name : str
            Line-type name (case-insensitive).
        **changes : object
            New column values: ``diam`` in m, ``mass`` in kg/m, ``ea`` in N
            (or a dynamic-stiffness specification), ``ba`` in N s (negative
            for a damping ratio), ``ei`` in N m^2, and dimensionless
            coefficients.

        Raises
        ------
        KeyError
            If the line type or a column does not exist.
        ValueError
            If a value cannot be rendered as one native token.
        DeckFormatError
            If the edited deck violates the native deck contract.
        """
        record = self._find(self.line_types, line_type_name, "line type", casefold=True)
        self._replace_record(record, self._line_type_fields(record), "LINE TYPES", changes)

    def set_section(self, line_id: int, occurrence: int = 1, **changes: object) -> None:
        """Edit the ``occurrence``-th section (1-based, End A to End B) of a line.

        A stock 7-column LINES row counts as a section at its position in the
        file, as it does natively; editing it accepts the stock column names
        (``linetype``, ``nodea``, ``nodeb``, ``length``, ``numsegs``, ``outputs``).

        Parameters
        ----------
        line_id : int
            Line identifier.
        occurrence : int
            One-based position of the section along the line, from End A.
        **changes : object
            New column values, for example ``length`` in m and ``numsegs``.

        Raises
        ------
        KeyError
            If the section or a column does not exist.
        ValueError
            If a value cannot be rendered as one native token.
        DeckFormatError
            If the edited deck violates the native deck contract.
        """
        record, fields, section = self._section_record(
            _selector_int(line_id, "section line id"),
            _selector_int(occurrence, "section occurrence"),
        )
        self._replace_record(record, fields, section, changes)

    def set_end_connection(self, line_id: int, end: str, **changes: object) -> None:
        """Edit one ``END CONNECTIONS`` row selected by line id and end.

        Keyword names are column names, case-insensitive: ``lineid``, ``end``,
        ``stiffness``, ``ezx``, ``ezy``, ``ezz``, on a row that has the torsion
        columns (10 or 11 values) ``torsstiffness``, ``nxx``, ``nxy`` and ``nxz``, and
        on an 11-value row ``pretwist``. An edit changes existing columns only: it does
        not add the torsion columns or a pretwist to a shorter row (a ``KeyError``);
        :class:`cabledyn.builder.DeckModel` writes rows of any width.

        Parameters
        ----------
        line_id : int
            Line identifier.
        end : str
            ``"A"`` or ``"B"``.
        **changes : object
            New column values: ``stiffness`` in N m/rad (or ``Pinned`` /
            ``Rigid``), dimensionless direction components, ``torsstiffness`` in
            N m/rad (or ``Free`` / ``Rigid``), the reference normal components and
            ``pretwist`` in degrees. Keywords are written unquoted.

        Raises
        ------
        KeyError
            If the row does not exist, or the row has no such column.
        ValueError
            If ``end`` or a value is invalid.
        DeckFormatError
            If the edited deck violates the native deck contract.
        """
        record = self._end_connection_record(_selector_int(line_id, "end-connection line id"), end)
        self._replace_record(record, _FIELDS["end_connection"], "END CONNECTIONS", changes)

    def apply(self, selector: str, value: object) -> None:
        """Apply one selector, validating the edited deck.

        Parameters
        ----------
        selector : str
            ``option.KEY``, ``point.ID.FIELD``, ``line_type.NAME.FIELD``,
            ``section.LINE.OCCURRENCE.FIELD``, or
            ``end_connection.LINE.END.FIELD``.
        value : object
            New value, in the deck's SI units; must render as one native token
            (or a sequence for a multi-value option).

        Raises
        ------
        KeyError
            If the selector addresses a record, field, or option the deck lacks.
        ValueError
            If the selector is malformed or the value cannot be rendered.
        DeckFormatError
            If the edited deck violates the native deck contract.
        """
        self.apply_many({selector: value})

    @staticmethod
    def _find(
        records: tuple[DeckRecord, ...], key: str, label: str, *, casefold: bool = False
    ) -> DeckRecord:
        expected = key.lower() if casefold else key
        matches = [
            row
            for row in records
            if (row.tokens[0].lower() if casefold else row.tokens[0]) == expected
        ]
        if not matches:
            raise KeyError(f"{label} {key!r} does not exist")
        return matches[0]

    def write(self, path: str | os.PathLike[str], *, overwrite: bool = False) -> Path:
        """Validate, then atomically write the deck byte-exactly to ``path``.

        The file receives default permissions for a new file (``0o666`` masked by
        the umask). Missing parent directories are created.

        Parameters
        ----------
        path : str | os.PathLike
            Target file.
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
        ValueError
            If ``path`` names a reserved Windows device (on Windows).
        DeckFormatError
            If the deck violates the native deck contract.
        """
        self.validate()
        if (device := windows_device_component(path)) is not None:
            raise ValueError(
                f"cannot write a deck to {os.fspath(path)}: {device!r} is a reserved Windows "
                "device name (CON, PRN, AUX, NUL, COM1-9, LPT1-9)"
            )
        target = Path(path).expanduser().resolve()
        if target.exists() and not overwrite:
            raise FileExistsError(f"deck already exists: {target}")
        target.parent.mkdir(parents=True, exist_ok=True)
        _atomic_write_bytes(target, self.text().encode("utf-8", "surrogateescape"))
        return target

    def _companion_files(self) -> tuple[str, ...]:
        """Return the fixed-name kinematics files this deck reads from its own folder.

        MoorDyn-C ``WaveKin 3`` reads ``wave_elevation.txt``, ``WaveKin 7`` reads
        ``wave_frequencies.txt``, ``Currents 1`` reads ``current_profile.txt``,
        ``Currents 2`` ``current_profile_dynamic.txt`` and ``Currents 5``
        ``current_profile_4d.txt``; the native reader opens them by name next to the
        deck, so a deck written to another folder needs them copied there.
        """
        effective = {_option_key(record.keyword): record for record in self.options}
        names: list[str] = []
        waterkin = effective.get("waterkin")
        mode = _moordyn_c_wave_kin(None if waterkin is None else waterkin.values[0])
        if mode:
            names.append(_MOORDYN_C_WAVE_FILES[mode])
        currents = effective.get("currents")
        mode = _moordyn_c_currents(None if currents is None else currents.values[0])
        if mode:
            names.append(_MOORDYN_C_CURRENT_FILES[mode])
        return tuple(names)

    def _rebase_relative_inputs(self, target_directory: str | os.PathLike[str]) -> None:
        """Rewrite known relative ancillary references for a relocated deck."""
        destination = Path(target_directory).expanduser().resolve()

        def rebased(value: str) -> str:
            # Deck paths follow the native parser, not shell expansion rules:
            # a leading '~' is an ordinary relative filename component.
            candidate = Path(value)
            if (
                candidate.is_absolute()
                or PureWindowsPath(value).is_absolute()
                or value.startswith(("/", "\\"))
            ):
                return value
            absolute = (self.path.parent / candidate).resolve()
            try:
                return Path(os.path.relpath(absolute, destination)).as_posix()
            except ValueError:
                # Windows cannot express a relative path across drive letters.
                return absolute.as_posix()

        for row in tuple(self.line_types):
            ea = row.tokens[3]
            if not ea.lower().startswith("syrope:"):
                continue
            payload = ea[len("SYROPE:") :]
            path, separator, parameters = payload.partition("|")
            if not path:
                continue
            replacement = f"SYROPE:{rebased(path)}"
            if separator:
                replacement += separator + parameters
            self._replace_record(row, _FIELDS["line_type"], "LINE TYPES", {"ea": replacement})

        effective_path_options: dict[str, OptionRecord] = {}
        for record in self.options:
            keyword = record.keyword.lower()
            if keyword in _PATH_OPTIONS:
                effective_path_options[_PATH_OPTION_GROUP[keyword]] = record
        for record in effective_path_options.values():
            if record.keyword.lower() not in _PATH_OPTIONS or len(record.values) != 1:
                continue
            value = record.values[0]
            path_group = _PATH_OPTION_GROUP[record.keyword.lower()]
            if (
                path_group in {"motion", "vesselmotion", "vesselrao"}
                and value.lower() in _DISABLED_MOTION_FILE_VALUES
            ):
                continue
            is_waterkin = path_group == "waterkin"
            if is_waterkin:
                if value.lower() in {"none", "seastate"}:
                    continue
                try:
                    _native_float(value)
                except ValueError:
                    pass
                else:
                    continue
            new_path = rebased(value)
            if any(character in _WHITESPACE for character in new_path):
                raise DeckFormatError(
                    f"{self._label}: the rebased {record.keyword} path {new_path!r} contains "
                    "a space, which an OPTIONS value cannot hold; move the file or the deck "
                    "so the relative path has no spaces"
                )
            self.set_option(record.keyword, new_path)


def _plan_companion_copies(
    decks: list[DeckFile], destination: Path, *, overwrite: bool
) -> list[tuple[Path, Path]]:
    """Check and return the (source, target) copies of the decks' fixed-name files.

    Every file must exist next to its source deck. A target that already holds
    different bytes is replaced only with ``overwrite``; nothing is copied here.
    """
    plan: dict[Path, Path] = {}
    for deck in decks:
        for name in deck._companion_files():
            source, target = deck.path.parent / name, destination / name
            if not source.is_file():
                raise DeckFormatError(
                    f"{deck._label}: the deck reads {name} from its folder, but {source} does "
                    "not exist"
                )
            if source.resolve() != target.resolve():
                plan[target] = source
    for target, source in plan.items():
        if target.exists() and not overwrite and target.read_bytes() != source.read_bytes():
            raise FileExistsError(f"a different {target.name} already exists: {target}")
    return [(source, target) for target, source in plan.items()]


def _copy_companions(plan: list[tuple[Path, Path]]) -> None:
    for source, target in plan:
        target.parent.mkdir(parents=True, exist_ok=True)
        _atomic_write_bytes(target, source.read_bytes())


def generate_deck_cases(
    base: str | os.PathLike[str],
    output_directory: str | os.PathLike[str],
    cases: Mapping[str, Mapping[str, object]],
    *,
    overwrite: bool = False,
    caller_driven: bool = False,
) -> tuple[GeneratedCase, ...]:
    """Generate validated deck variants and a machine-readable provenance manifest.

    Each case is a copy of ``base`` edited with :meth:`DeckFile.apply_many`
    and written to ``<output_directory>/<name>.dat``. Relative ancillary file
    paths in the deck (motion, bathymetry, WaterKin and Syrope files) are
    rewritten so they still resolve from the new location. The MoorDyn-C
    kinematics files that the solver reads by fixed name from the deck folder
    (``wave_elevation.txt`` for ``WaveKin 3``, ``wave_frequencies.txt`` for
    ``WaveKin 7``, ``current_profile.txt``, ``current_profile_dynamic.txt`` and
    ``current_profile_4d.txt`` for ``Currents 1``, ``2`` and ``5``) are copied into
    ``output_directory``. A ``cases.json`` manifest records the source deck,
    its SHA-256 digest, and every case's changes and digest (with the digests
    of the copied kinematics files it reads); :func:`cabledyn.run_study`
    consumes it. Every case is validated before any file is written.

    Parameters
    ----------
    base : str | os.PathLike
        Source deck.
    output_directory : str | os.PathLike
        Directory for the generated decks and manifest; created if missing.
    cases : collections.abc.Mapping[str, collections.abc.Mapping[str, object]]
        Case name to selector-value mapping, as accepted by
        :meth:`DeckFile.apply_many`. Names start with a letter or digit and
        contain only letters, digits, ``_``, ``.``, and ``-``; they must be
        unique ignoring case.
    overwrite : bool
        Replace existing generated decks and manifest instead of raising
        :class:`FileExistsError`.
    caller_driven : bool
        Validate for the OpenFAST coupling instead of the standalone driver
            (see :class:`DeckFile`).

    Returns
    -------
    tuple[GeneratedCase, ...]
        One entry per case, in the order of ``cases``.

    Raises
    ------
    DeckFormatError
        If the base deck or an edited case violates the native deck contract,
        a rebased OPTIONS path would contain a space, or a fixed-name
        kinematics file the deck reads is missing.
    KeyError
        If a selector addresses a record, field, or option the deck lacks.
    ValueError
        If ``cases`` is empty, a case name is invalid or duplicated, a change
        is not JSON-serializable, or a case would replace the source deck.
    FileExistsError
        If an output exists and ``overwrite`` is false.
    """
    source = DeckFile.read(base, caller_driven=caller_driven)
    if not cases:
        raise ValueError("case mapping must not be empty")
    destination = Path(output_directory).expanduser().resolve()
    manifest_path = destination / "cases.json"
    targets = [destination / f"{name}.dat" for name in cases]

    def replaces_source(target: Path) -> bool:
        if target.resolve() == source.path:
            return True
        # Hard links and case-insensitive file systems can alias the source deck.
        try:
            return target.exists() and os.path.samefile(target, source.path)
        except OSError:
            return False

    if any(replaces_source(target) for target in (manifest_path, *targets)):
        raise ValueError("generated case must not replace the source deck")
    existing = [path for path in [*targets, manifest_path] if path.exists()]
    if existing and not overwrite:
        raise FileExistsError(
            f"case-generation outputs already exist: {', '.join(map(str, existing))}"
        )
    prepared: list[tuple[str, Mapping[str, object], DeckFile, Path, str]] = []
    names: set[str] = set()
    for name, changes in cases.items():
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", name) or name.lower() in names:
            raise ValueError(f"invalid or duplicate case name {name!r}")
        names.add(name.lower())
        deck = source.clone()
        deck.apply_many(changes)
        target = destination / f"{name}.dat"
        deck._rebase_relative_inputs(target.parent)
        digest = hashlib.sha256(deck.text().encode("utf-8", "surrogateescape")).hexdigest()
        prepared.append((name, changes, deck, target, digest))
    # the source deck's fixed-name kinematics files, each copied once into the case folder
    companion_plan = _plan_companion_copies(
        [deck for _, _, deck, _, _ in prepared],
        destination,
        overwrite=overwrite,
    )
    companion_digests = {
        name: hashlib.sha256((source.path.parent / name).read_bytes()).hexdigest()
        for name in {name for _, _, deck, _, _ in prepared for name in deck._companion_files()}
    }
    generated = [
        GeneratedCase(name, target.resolve(), target.parent, dict(changes), digest)
        for name, changes, _, target, digest in prepared
    ]
    manifest = {
        "schema": "cabledyn-deck-cases-v1",
        "source": str(source.path),
        "source_sha256": hashlib.sha256(source.path.read_bytes()).hexdigest(),
        "source_directory": str(source.path.parent),
        "working_directory": str(destination),
        "caller_driven": source.caller_driven,
        "cases": [
            {
                "name": case.name,
                "deck": str(case.deck),
                "sha256": case.sha256,
                "working_directory": str(case.working_directory),
                "changes": dict(case.changes),
                **(
                    {
                        "companion_files": {
                            name: companion_digests[name] for name in deck._companion_files()
                        }
                    }
                    if deck._companion_files()
                    else {}
                ),
            }
            for case, (_, _, deck, _, _) in zip(generated, prepared, strict=True)
        ],
    }
    try:
        manifest_text = json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    except (TypeError, ValueError) as exc:
        raise ValueError(f"case changes are not JSON-serializable: {exc}") from exc
    destination.mkdir(parents=True, exist_ok=True)
    for _, _, deck, target, _ in prepared:
        deck.write(target, overwrite=overwrite)
    _copy_companions(companion_plan)
    _atomic_write_bytes(manifest_path, manifest_text.encode("utf-8"))
    return tuple(generated)
