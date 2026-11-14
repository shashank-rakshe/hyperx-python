# SPDX-License-Identifier: Apache-2.0
"""Typed object model for building and editing CableDyn decks in Python.

:class:`DeckModel` holds a deck as linked Python objects (line types, rod
types, bodies, rods, points, lines with their sections, the optional
per-line and per-point tables, options, and output channels). Objects refer
to each other by reference, not by id, so renaming a point or a line type
keeps every row that uses it consistent, and removing an object that is still
in use fails unless the removal is asked to cascade.

The model does not parse or validate deck text itself. :meth:`DeckModel.load`
reads through :class:`cabledyn.DeckFile`, and :meth:`DeckModel.to_text`
renders canonical deck text that is validated by :class:`cabledyn.DeckFile`
with the same native rules. Comments, column alignment, and records the
native reader ignores are not kept; use :class:`cabledyn.DeckFile` to edit a
deck while preserving its source text.

The row classes here (``Line``, ``Point``, ``Body``, ``Rod``, ...) describe
deck input. The live solver views of a running model share some of these
names but are different classes, in :mod:`cabledyn.objects` (re-exported by
:mod:`cabledyn.model`); import each family from its own module.
"""

from __future__ import annotations

import contextlib
import copy
import numbers
import operator
import os
import re
from collections.abc import Callable, Iterable, Iterator, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Generic, TypeVar, Union

from cabledyn.deck import _check_free_text
from cabledyn.deck_file import (
    _LINE_OPTION_PATTERN,
    _PINNED_END_CONNECTIONS,
    _RIGID_END_CONNECTIONS,
    _ROD_ATTACHMENT_ALIASES,
    _WAVETRAIN_KEYWORDS,
    DeckFile,
    DeckRecord,
    _body_point_id,
    _copy_companions,
    _end_connection_end,
    _is_csys_token,
    _is_scalar_option_keyword,
    _is_turbine_point_type,
    _native_int,
    _option_key,
    _plan_companion_copies,
    _render,
    _render_quoted_text,
    _rod_end_token,
    _rod_point,
    _split_records,
    _strip_inline_comment,
    _table_float,
    _turbine_id,
)

__all__ = [
    "Attachment",
    "Body",
    "Control",
    "DeckModel",
    "DeckReferenceError",
    "EndConnection",
    "EquivalentBuoyancy",
    "ExternalLoad",
    "Failure",
    "Line",
    "LineType",
    "MoorDynBody",
    "ObjectCollection",
    "Option",
    "OptionSet",
    "OutputList",
    "Point",
    "Rod",
    "RodEnd",
    "RodType",
    "Section",
    "Stiffener",
    "SyropeEA",
    "SyropeIC",
    "Turbine",
]

_END_CONNECTION_KEYWORDS = _PINNED_END_CONNECTIONS | _RIGID_END_CONNECTIONS
# TorsStiffness keywords of the optional END CONNECTIONS torsion columns
_TORSION_KEYWORDS = frozenset({"free", "zero"}) | _RIGID_END_CONNECTIONS

Vec3 = tuple[float, float, float]
"""A three-component vector ``(x, y, z)``."""

_BANNER = "--------------------- CableDyn Input File ------------------------------------"
_FOOTER = "--------------------- need this line -----------------------------------------"
_MOTION_KEYWORDS = ("motionFile", "vesselMotion", "vesselRAO")
_POSITIONAL_KEYS = frozenset({"waves", "current"})
_CHANNEL_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    (
        "line",
        re.compile(
            r"(fairten|anchten|anchfz|anchfh|fairangle|anchangle|fairdecl|anchdecl|fairincl|anchincl"
            r"|fairdefl|anchdefl)"
            r"([0-9]+)()",
            re.IGNORECASE,
        ),
    ),
    ("line", re.compile(r"(tdp)([0-9]+)(s|x|y|z|lay|exc|grd)", re.IGNORECASE)),
    (
        "line",
        re.compile(r"(ten|curvx|curvy|curv|bendmom|stfmom|torq)([0-9]+)(n[0-9]+)", re.IGNORECASE),
    ),
    ("line", re.compile(r"(twist)([0-9]+)(n[0-9]+|)", re.IGNORECASE)),
    ("line", re.compile(r"(l)([0-9]+)(n[0-9]+(?:[pva][xyz]|dec|azi))", re.IGNORECASE)),
    ("point", re.compile(r"(point|con)([0-9]+)(p[xyz])", re.IGNORECASE)),
    ("point", re.compile(r"(point)([0-9]+)(f[xyzh])", re.IGNORECASE)),
    ("body", re.compile(r"(body)([0-9]+)((?:p|r|v|rv|a|ra|f|m)[xyz])", re.IGNORECASE)),
    (
        "rod",
        re.compile(
            r"(rod)([0-9]+)(n[0-9]+p[xyz]|(?:p|v|rv|a|ra|f|m)[xyz]|r[xy]|tena|tenb|sub)",
            re.IGNORECASE,
        ),
    ),
)


class DeckReferenceError(ValueError):
    """An object is used by other deck objects, or belongs to another model.

    Raised by :meth:`DeckModel.remove` when the object is still referenced
    and ``cascade`` is false, and when a row names an object that is not part
    of the model.

    Attributes
    ----------
    referrers : tuple[object, ...]
        The objects (and output channel names) that still use the object.
    """

    def __init__(self, message: str, referrers: Sequence[object] = ()) -> None:
        super().__init__(message)
        self.referrers = tuple(referrers)


# --------------------------------------------------------------------------- objects


@dataclass(frozen=True)
class SyropeEA:
    """Syrope working-curve axial stiffness, the ``SYROPE:<file>|alpha|beta`` EA form.

    Attributes
    ----------
    settings : str
        Syrope settings file, relative to the deck or absolute.
    alpha : float
        Fast-spring stiffness intercept, in N.
    beta : float
        Fast-spring stiffness slope on tension (dimensionless).
    """

    settings: str
    alpha: float
    beta: float


@dataclass(eq=False)
class LineType:
    """One ``LINE TYPES`` row, in CableDyn column order.

    Attributes
    ----------
    name : str
        Unique type name (case-insensitive).
    diam : float
        Hydrodynamic, volume-equivalent diameter, in m.
    mass : float
        Dry mass per unstretched metre, in kg/m.
    ea : float | tuple[float, ...] | SyropeEA
        Axial stiffness in N; ``(Es, Ed)`` or ``(Es, alphaMBL, vbeta)`` for a
        viscoelastic type, or a :class:`SyropeEA`.
    ba : float | tuple[float, ...]
        Axial damping in N s (negative: damping ratio), or ``(Bs, Bd)``.
    ei : float
        Bending stiffness, in N m^2.
    cdn, cdt, can, cat : float
        Normal and tangential drag and added-mass coefficients.
    gas, gj, irt, irn : float | None
        Optional finite-EI columns (shear and torsional stiffness, rotary
        inertias). All four set writes the 14-column row; all ``None`` writes
        the 10-column row. ``gj`` may be ``(GJ, K)``, with ``K`` the
        torque-tension coupling in N m (written ``GJ|K``), or ``(GJ, K, Bt)``,
        with ``Bt`` the torsional damping in N m^2 s, negative for a damping
        ratio (written ``GJ|K|Bt``).
    cl, df, cf : float | None
        Optional cross-flow VIV columns of a type (MoorDyn's lift
        coefficient and the half-range and centre of the synchronisation band
        in non-dimensional frequency). ``cl`` set writes the 13-column row, with
        MoorDyn's ``df = 0.08`` and ``cf = 0.18`` where they are ``None``.
    """

    name: str
    diam: float
    mass: float
    ea: float | tuple[float, ...] | SyropeEA
    ba: float | tuple[float, ...] = 0.0
    ei: float = 0.0
    cdn: float = 0.0
    cdt: float = 0.0
    can: float = 0.0
    cat: float = 0.0
    gas: float | None = None
    gj: float | tuple[float, ...] | None = None
    irt: float | None = None
    irn: float | None = None
    cl: float | None = None
    df: float | None = None
    cf: float | None = None


@dataclass(eq=False)
class RodType:
    """One ``ROD TYPES`` row.

    Attributes
    ----------
    name : str
        Unique type name (case-insensitive).
    diam : float
        Cylinder diameter, in m.
    mass : float
        Dry mass per unit length, in kg/m.
    cd, ca : float
        Transverse drag and added-mass coefficients.
    cd_end, ca_end : float
        End drag and end added-mass coefficients.
    cd_ax, ca_ax : float | None
        Optional axial side drag and added-mass coefficients (both or neither).
    """

    name: str
    diam: float
    mass: float
    cd: float = 0.0
    ca: float = 0.0
    cd_end: float = 0.0
    ca_end: float = 0.0
    cd_ax: float | None = None
    ca_ax: float | None = None


@dataclass(eq=False)
class Body:
    """One CableDyn ``BODIES`` row (15 columns, or 18 with the inertias).

    Attributes
    ----------
    id : int
        Unique body id, at least 1.
    type : str
        ``Point3``, ``Rigid6``, ``Coupled``, or ``Vessel``.
    x, y, z : float
        Reference position, in m.
    roll, pitch, yaw : float
        Reference orientation, in degrees.
    mass : float
        Body mass, in kg.
    volume : float
        Displaced volume, in m^3.
    c33, c44, c55 : float
        Heave (N/m) and roll/pitch (N m/rad) hydrostatic restoring.
    cda : float
        Drag area, in m^2.
    ca : float
        Added-mass coefficient.
    inertia : tuple[float, float, float] | None
        ``(Ixx, Iyy, Izz)`` in kg m^2; required for ``Rigid6``.
    """

    id: int
    type: str
    x: float
    y: float
    z: float
    roll: float = 0.0
    pitch: float = 0.0
    yaw: float = 0.0
    mass: float = 0.0
    volume: float = 0.0
    c33: float = 0.0
    c44: float = 0.0
    c55: float = 0.0
    cda: float = 0.0
    ca: float = 0.0
    inertia: Vec3 | None = None


@dataclass(eq=False)
class MoorDynBody:
    """One 14-column MoorDyn v2 ``BODIES`` row (a Rigid6 body with a centre of gravity).

    Attributes
    ----------
    id : int
        Unique body id, at least 1.
    type : str
        ``Free``, ``Coupled``, or ``Vessel``.
    x, y, z : float
        Reference position, in m.
    roll, pitch, yaw : float
        Reference orientation, in degrees.
    mass : float
        Body mass, in kg.
    cg : float | tuple[float, ...]
        Centre of gravity in the body frame: ``z`` or ``(x, y, z)``, in m.
    inertia : float | tuple[float, ...]
        Inertia about the CG: one value or ``(Ixx, Iyy, Izz)``, in kg m^2.
    volume : float
        Displaced volume, in m^3.
    cda : float | tuple[float, ...]
        Drag area: one value, ``(CdA, CdA_rot)``, or 3 or 6 entries, in m^2.
    ca : float | tuple[float, ...]
        Added-mass coefficient: one value or 3 entries.
    """

    id: int
    type: str
    x: float
    y: float
    z: float
    roll: float = 0.0
    pitch: float = 0.0
    yaw: float = 0.0
    mass: float = 0.0
    cg: float | tuple[float, ...] = 0.0
    inertia: float | tuple[float, ...] = 0.0
    volume: float = 0.0
    cda: float | tuple[float, ...] = 0.0
    ca: float | tuple[float, ...] = 0.0


AnyBody = Union[Body, MoorDynBody]  # noqa: UP007 (a runtime alias must work on Python 3.10)


@dataclass(eq=False)
class Rod:
    """One ``RODS`` row.

    Attributes
    ----------
    id : int
        Unique rod id, at least 1.
    rod_type : RodType
        The rod's type.
    type : str
        Attachment kind: ``Free``, ``Fixed``, ``Pinned``, ``Coupled``,
        ``Vessel`` (or a MoorDyn alias), or ``Body``/``BodyPinned``/``BodyPin``
        together with :attr:`body`.
    end_a, end_b : tuple[float, float, float]
        End A and End B coordinates, in m (body frame for a body rod).
    num_segs : int
        Hydrodynamic segments; ``0`` declares a zero-length rod.
    outputs : str
        ``-`` or ``p``.
    body : Body | MoorDynBody | None
        The body a ``Body``/``BodyPinned`` rod is attached to.
    """

    id: int
    rod_type: RodType
    type: str
    end_a: Vec3
    end_b: Vec3
    num_segs: int
    outputs: str = "-"
    body: AnyBody | None = None

    @property
    def type_token(self) -> str:
        """The attachment as written in the deck, for example ``Body1Pinned``."""
        if self.body is not None and self.type.lower().startswith("body"):
            return f"{self.type[:4]}{self.body.id}{self.type[4:]}"
        return self.type


@dataclass(frozen=True)
class RodEnd:
    """End ``A`` or ``B`` of a rod, used as a line end (``R<N>A``) or a point type.

    Attributes
    ----------
    rod : Rod
        The rod.
    end : str
        ``"A"`` or ``"B"``.
    """

    rod: Rod
    end: str

    @property
    def token(self) -> str:
        """The deck token of this end as a line attachment, for example ``R2A``."""
        return f"R{self.rod.id}{self.end.upper()}"


@dataclass(eq=False)
class Turbine:
    """One ``TURBINES`` row of a standalone FAST.Farm deck.

    Attributes
    ----------
    id : int
        Turbine number ``J``, 1 to 10000.
    x, y, z : float
        Farm-global reference position, in m.
    ptfm : tuple[float, ...] | None
        Optional ``(surge, sway, heave, roll, pitch, yaw)`` initial platform
        displacement, in m and degrees.
    """

    id: int
    x: float
    y: float
    z: float
    ptfm: tuple[float, ...] | None = None


@dataclass(eq=False)
class Point:
    """One ``POINTS`` row.

    Attributes
    ----------
    id : int
        Unique point id, at least 1.
    type : str
        ``Fixed``, ``Coupled``, ``Vessel``, ``Free``, ``Connect``, or
        ``Body``/``Rod``/``Turbine``/``T`` together with :attr:`body`,
        :attr:`rod_end`, or :attr:`turbine`.
    x, y, z : float
        Position (or body-frame offset for a body point), in m.
    mass : float
        Point mass, in kg.
    volume : float
        Displaced volume, in m^3.
    cda : float
        Drag area, in m^2.
    ca : float
        Added-mass coefficient.
    body : Body | MoorDynBody | None
        The body of a ``Body<N>`` point.
    rod_end : RodEnd | None
        The rod end of a ``Rod<N>A``/``Rod<N>B`` point.
    turbine : int | None
        The turbine number of a ``Turbine<J>``/``T<J>`` point.
    """

    id: int
    type: str
    x: float
    y: float
    z: float
    mass: float = 0.0
    volume: float = 0.0
    cda: float = 0.0
    ca: float = 0.0
    body: AnyBody | None = None
    rod_end: RodEnd | None = None
    turbine: int | None = None

    @property
    def type_token(self) -> str:
        """The point type as written in the deck, for example ``Body1`` or ``Rod2A``."""
        kind = self.type.lower()
        if kind == "body" and self.body is not None:
            return f"{self.type}{self.body.id}"
        if kind == "rod" and self.rod_end is not None:
            return f"{self.type}{self.rod_end.rod.id}{self.rod_end.end.upper()}"
        if kind in {"turbine", "t"} and self.turbine is not None:
            return f"{self.type}{self.turbine}"
        return self.type


LineEnd = Union[Point, RodEnd]  # noqa: UP007 (a runtime alias must work on Python 3.10)


@dataclass(eq=False)
class Section:
    """One section of a line (a ``SECTIONS`` row).

    Attributes
    ----------
    line_type : LineType
        The section's line type.
    length : float
        Unstretched length, in m.
    num_segs : int
        Number of elements.
    """

    line_type: LineType
    length: float
    num_segs: int


@dataclass(eq=False)
class Line:
    """One ``LINES`` row with its ordered sections (End A to End B).

    Attributes
    ----------
    id : int
        Unique line id, at least 1.
    end_a, end_b : Point | RodEnd
        End A (fairlead side) and End B (anchor side) attachments.
    sections : list[Section]
        Ordered sections from End A.
    outputs : str
        Per-line output flags: ``-`` or a combination of ``p``, ``t``, ``r``.
    stock_row : bool
        Write a single-section line as a stock MoorDyn 7-column row
        (``ID LineType AttachA AttachB UnstrLen NumSegs Outputs``) instead of
        a 4-column row plus one ``SECTIONS`` row.
    """

    id: int
    end_a: LineEnd
    end_b: LineEnd
    sections: list[Section] = field(default_factory=list)
    outputs: str = "-"
    stock_row: bool = False

    @property
    def length(self) -> float:
        """Total unstretched length, the sum of the section lengths, in m."""
        return float(sum(float(section.length) for section in self.sections))

    @property
    def num_segs(self) -> int:
        """Total number of elements over all sections."""
        return sum(int(section.num_segs) for section in self.sections)


@dataclass(eq=False)
class EndConnection:
    """One ``END CONNECTIONS`` row: the bending boundary at a finite-EI line end.

    Attributes
    ----------
    line : Line
        The line.
    end : str
        ``"A"`` or ``"B"``.
    stiffness : float | str
        Rotational stiffness in N m/rad, ``Pinned``, or ``Rigid``.
    direction : tuple[float, float, float]
        Non-zero reference direction (End A to End B convention).
    torsion_stiffness : float | str | None
        Optional torsional restraint: ``Free``, ``Rigid`` or a stiffness in N m/rad; ``None``
        writes the six-column row (no torsion columns).
    normal : tuple[float, float, float] | None
        Zero-twist reference normal in the frame of ``direction`` (with ``torsion_stiffness``).
    pretwist : float | None
        Optional roll of the end frame about ``direction``, in degrees.
    """

    line: Line
    end: str
    stiffness: float | str
    direction: Vec3
    torsion_stiffness: float | str | None = None
    normal: Vec3 | None = None
    pretwist: float | None = None


@dataclass(eq=False)
class EquivalentBuoyancy:
    """One ``EQUIVALENT BUOYANCY`` row: a line type given by its submerged weight.

    Attributes
    ----------
    line_type : LineType
        The line type rewritten by the row.
    diam : float
        Equivalent diameter, in m.
    submerged_weight : float
        Net submerged weight, in N/m (negative for uplift).
    """

    line_type: LineType
    diam: float
    submerged_weight: float


@dataclass(eq=False)
class Attachment:
    """One ``ATTACHMENTS`` row: discrete modules or clumps on a finite-EI line.

    Attributes
    ----------
    line : Line
        The finite-EI line.
    arc_length : float | tuple[float, float, float]
        Arc length from End A in m, or a series ``(first, pitch, last)``.
    mass : float
        Dry mass, in kg.
    volume : float
        Displaced volume, in m^3.
    cda : float
        Normal drag area, in m^2.
    ca : float
        Added-mass coefficient.
    cdax : float | None
        Optional axial drag area, in m^2.
    """

    line: Line
    arc_length: float | tuple[float, float, float]
    mass: float = 0.0
    volume: float = 0.0
    cda: float = 0.0
    ca: float = 0.0
    cdax: float | None = None


@dataclass(eq=False)
class Stiffener:
    """One ``STIFFENERS`` row: a conical segment of a bend stiffener on a finite-EI line.

    The rows of one line end follow each other outward from the stiffener root, each starting
    where the previous one ends; a cylindrical root, a cone and a tip are three rows.

    Attributes
    ----------
    line : Line
        The finite-EI line.
    end : str
        The end the stiffener sleeves, ``A`` or ``B``.
    length : float
        Length of the segment, in m.
    root_od : float
        Outer diameter at the segment's root side, in m.
    tip_od : float
        Outer diameter at the segment's tip side, in m.
    inner_d : float
        Inner diameter, in m.
    modulus : float
        Young's modulus of the stiffener material, in Pa.
    density : float
        Density of the stiffener material, in kg/m^3.
    """

    line: Line
    end: str
    length: float
    root_od: float
    tip_od: float
    inner_d: float
    modulus: float
    density: float


@dataclass(eq=False)
class SyropeIC:
    """One ``SYROPE IC`` row: the prior load history of Syrope lines.

    Attributes
    ----------
    lines : list[Line]
        The lines with a Syrope section (alone or in a composite line).
    tmax0 : float
        Running maximum tension, in N.
    tmean0 : float
        Mean tension, in N.
    """

    lines: list[Line]
    tmax0: float
    tmean0: float


@dataclass(eq=False)
class Failure:
    """One ``FAILURE`` row. Its ``FailID`` is its position in :attr:`DeckModel.failures`.

    Attributes
    ----------
    point : Point
        The point the lines detach from.
    lines : list[Line]
        The lines that detach; each must attach to :attr:`point`.
    fail_time : float
        Trigger time in s; ``0`` disables the time trigger.
    fail_tension : float
        Trigger tension in N; ``0`` disables the tension trigger.
    """

    point: Point
    lines: list[Line]
    fail_time: float = 0.0
    fail_tension: float = 0.0


@dataclass(eq=False)
class Control:
    """One ``CONTROL`` row: lines driven by an OpenFAST cable-control channel.

    Attributes
    ----------
    channel : int
        Positive control channel.
    lines : list[Line]
        The controlled lines.
    """

    channel: int
    lines: list[Line]


@dataclass(eq=False)
class ExternalLoad:
    """One ``EXTERNAL LOADS`` row on a Rigid6 body.

    Attributes
    ----------
    id : int
        Row id; the rows are numbered 1, 2, 3, ... in deck order.
    body : Body | MoorDynBody
        The loaded Rigid6 body.
    csys : str
        ``G`` (global axes) or ``L`` (body axes).
    force : float | tuple[float, ...]
        ``0`` or ``(f1, f2, f3)``, in N.
    blin : float | tuple[float, ...]
        Linear damping, one value or three, in N s/m.
    bquad : float | tuple[float, ...]
        Quadratic damping, one value or three, in N s^2/m^2.
    """

    id: int
    body: AnyBody
    csys: str = "G"
    force: float | tuple[float, ...] = 0.0
    blin: float | tuple[float, ...] = 0.0
    bquad: float | tuple[float, ...] = 0.0


@dataclass(eq=False)
class Option:
    """One ``OPTIONS`` row.

    Attributes
    ----------
    keyword : str
        Option keyword as written (case-insensitive; native aliases allowed).
    values : tuple[str, ...]
        Value tokens: one for a scalar option; several for ``dynamic_solver``
        and the positional ``waves``/``current``/``wavetrain`` forms.
    description : str | None
        Text written after a `` - `` separator.
    """

    keyword: str
    values: tuple[str, ...]
    description: str | None = None

    @property
    def value(self) -> str:
        """The first value token."""
        return self.values[0]


# --------------------------------------------------------------------------- rendering


def _num(value: object, what: str) -> str:
    """Render a number as the shortest token that parses back to the same float."""
    if isinstance(value, bool) or not isinstance(value, numbers.Real):
        raise TypeError(f"{what} must be a number, got {value!r}")
    return repr(float(value))


def _int(value: Any, what: str) -> str:
    if isinstance(value, bool):
        raise TypeError(f"{what} must be an integer, got {value!r}")
    try:
        return str(operator.index(value))
    except TypeError as exc:
        raise TypeError(f"{what} must be an integer, got {value!r}") from exc


def _text(value: object, what: str, *, quote: bool = True) -> str:
    """Render one text token (quoted where the native reader needs it).

    In a text column (``quote``) a name with interior spaces, such as
    ``"my chain"``, is written quoted: the native reader keeps a quoted value
    whole.
    """
    if not isinstance(value, str):
        raise TypeError(f"{what} must be a string, got {value!r}")
    try:
        return _render(value, text=quote)
    except ValueError as exc:
        if quote and " " in value and value == value.strip(" "):
            with contextlib.suppress(ValueError):
                return f'"{_render_quoted_text(value)}"'
        raise ValueError(f"{what}: {exc}") from exc


def _multi(value: object, what: str) -> str:
    """Render a number or a sequence of numbers as a ``a|b|c`` token."""
    if isinstance(value, (tuple, list)):
        if not value:
            raise ValueError(f"{what} must not be empty")
        return "|".join(_num(item, what) for item in value)
    return _num(value, what)


def _vec(value: object, size: int, what: str) -> list[str]:
    if not isinstance(value, (tuple, list)) or len(value) != size:
        raise ValueError(f"{what} must be a sequence of {size} numbers")
    return [_num(item, what) for item in value]


def _end_letter(end: object) -> str:
    if not isinstance(end, str):
        raise TypeError(f"end must be a string, got {end!r}")
    try:
        return _end_connection_end(end).upper()
    except ValueError as exc:
        raise ValueError(f"end must be A or B, got {end!r}") from exc


def _table(header: str, units: str, rows: list[list[str]]) -> list[str]:
    """Return a section's header, units, and aligned data rows."""
    table = [header.split(), units.split(), *rows]
    widths: dict[int, int] = {}
    for row in table:
        for column, token in enumerate(row):
            widths[column] = max(widths.get(column, 0), len(token))
    out: list[str] = []
    for row in table:
        cells = [token.ljust(widths[column]) for column, token in enumerate(row)]
        out.append("  ".join(cells).rstrip())
    return out


# --------------------------------------------------------------------------- parsing


def _f(token: str) -> float:
    return _table_float(token)


def _fmulti(token: str) -> float | tuple[float, ...]:
    parts = token.split("|")
    if len(parts) == 1:
        return _f(parts[0])
    return tuple(_f(part) for part in parts)


def _f3(tokens: Sequence[str]) -> Vec3:
    return (_f(tokens[0]), _f(tokens[1]), _f(tokens[2]))


def _ids(text: str) -> list[int]:
    return [_native_int(value) for value in text.split(",")]


def _key(value: int | str) -> int | str:
    if isinstance(value, bool):
        raise TypeError(f"object keys must be an integer id or a name, got {value!r}")
    if isinstance(value, str):
        return value.lower()
    return operator.index(value)


_T = TypeVar("_T")


class ObjectCollection(Generic[_T]):
    """A live, read-only view of one kind of model object, looked up by id or name.

    Iteration yields the objects in deck order. ``collection[key]`` returns
    the object with that integer id (points, lines, bodies, rods, turbines)
    or case-insensitive name (line and rod types). Add, rename, and remove
    objects through :class:`DeckModel`.
    """

    def __init__(self, items: list[_T], key: Callable[[_T], int | str], label: str) -> None:
        self._items = items
        self._keyfn = key
        self._label = label

    def __iter__(self) -> Iterator[_T]:
        return iter(tuple(self._items))

    def __len__(self) -> int:
        return len(self._items)

    def __contains__(self, item: object) -> bool:
        if isinstance(item, (int, str)) and not isinstance(item, bool):
            return self.get(item) is not None
        return any(existing is item for existing in self._items)

    def __getitem__(self, key: int | str) -> _T:
        found = self.get(key)
        if found is None:
            raise KeyError(f"{self._label} {key!r} does not exist")
        return found

    def get(self, key: int | str) -> _T | None:
        """Return the object with ``key``, or ``None``.

        Parameters
        ----------
        key : int | str
            Integer id, or case-insensitive name.

        Returns
        -------
        object | None
            The first matching object in deck order.
        """
        wanted = _key(key)
        for item in self._items:
            stored = self._keyfn(item)
            if isinstance(stored, str):
                stored = stored.lower()
            if not isinstance(stored, bool) and stored == wanted:
                return item
        return None

    def keys(self) -> list[int | str]:
        """Return the ids or names in deck order."""
        return [self._keyfn(item) for item in self._items]

    def next_id(self) -> int:
        """Return one more than the largest integer id (1 for an empty collection)."""
        ids = [key for key in self.keys() if isinstance(key, int)]
        return max(ids, default=0) + 1

    def __repr__(self) -> str:
        return f"<{self._label} collection: {self.keys()!r}>"


class OptionSet:
    """The ``OPTIONS`` rows of a model, in deck order.

    A keyword may appear more than once (the last row wins natively, and
    ``wavetrain`` rows add up). Lookups match native aliases
    case-insensitively, so ``dt`` finds a ``dtM`` row.
    """

    def __init__(self) -> None:
        self._rows: list[Option] = []

    def __iter__(self) -> Iterator[Option]:
        return iter(tuple(self._rows))

    def __len__(self) -> int:
        return len(self._rows)

    def __contains__(self, keyword: object) -> bool:
        return isinstance(keyword, str) and self.get(keyword) is not None

    def __repr__(self) -> str:
        return f"<OPTIONS: {[row.keyword for row in self._rows]!r}>"

    @staticmethod
    def _identity(keyword: str) -> str:
        return _option_key(keyword)

    def get(self, keyword: str) -> Option | None:
        """Return the effective (last) row for ``keyword`` or an alias, or ``None``.

        Parameters
        ----------
        keyword : str
            Option keyword or native alias (case-insensitive).

        Returns
        -------
        Option | None
            The effective row.
        """
        key = self._identity(keyword)
        matches = [row for row in self._rows if self._identity(row.keyword) == key]
        return matches[-1] if matches else None

    def value(self, keyword: str, default: str | None = None) -> str | None:
        """Return the first value token of the effective row, or ``default``.

        Parameters
        ----------
        keyword : str
            Option keyword or native alias.
        default : str | None
            Returned when the option is not set.

        Returns
        -------
        str | None
            The value token as written, for example ``"0.05"`` or ``"True"``.
        """
        row = self.get(keyword)
        return default if row is None else row.value

    @staticmethod
    def _make(keyword: str, values: tuple[object, ...], description: str | None) -> Option:
        if not isinstance(keyword, str):
            raise TypeError(f"option keyword must be a string, got {keyword!r}")
        lowered = keyword.lower()
        multi = (
            lowered == "dynamic_solver"
            or lowered in _WAVETRAIN_KEYWORDS
            or _option_key(lowered) in _POSITIONAL_KEYS
        )
        if not _is_scalar_option_keyword(lowered) and not multi:
            raise ValueError(f"unknown option keyword {keyword!r}")
        if not values:
            raise ValueError(f"option {keyword} needs a value")
        if not multi and len(values) != 1:
            raise ValueError(f"option {keyword} takes one value")
        tokens: list[str] = []
        for value in values:
            if isinstance(value, bool):
                token = "True" if value else "False"
            elif isinstance(value, (tuple, list)):
                token = _multi(value, f"option {keyword}")
            elif isinstance(value, float):
                token = repr(value)
            elif isinstance(value, (int, str)):
                token = str(value)
            else:
                raise TypeError(f"option {keyword} values must be numbers, Booleans, or strings")
            try:
                tokens.append(_render(token))
            except ValueError as exc:
                raise ValueError(f"option {keyword}: {exc}") from exc
        clean = None
        if description is not None:
            clean = _check_free_text(description, "option description") or None
        return Option(keyword, tuple(tokens), clean)

    def set(self, keyword: str, *values: object, description: str | None = None) -> Option:
        """Set an option, replacing every row of the keyword and its aliases.

        The new row takes the place of the first replaced row, or is appended.
        Scalar options take one value; ``dynamic_solver`` takes its four or
        five values, and ``waves``/``current``/``wavetrain`` their positional
        values (for example ``set("waves", "airy", 2.0, 8.0, 0.0)``).

        Parameters
        ----------
        keyword : str
            Option keyword or native alias.
        *values : object
            Values in the option's SI unit: numbers, Booleans (written
            ``True``/``False``), strings, or a number sequence written as
            ``a|b|c`` (for example ``vesselRef``).
        description : str | None
            Optional one-row note written after `` - ``.

        Returns
        -------
        Option
            The new row.

        Raises
        ------
        TypeError
            If a keyword or value has the wrong type.
        ValueError
            If the keyword is unknown, the value count does not fit a scalar
            option, or a value is not one native token.
        """
        row = self._make(keyword, values, description)
        key = self._identity(keyword)
        positions = [i for i, old in enumerate(self._rows) if self._identity(old.keyword) == key]
        if positions:
            self._rows[positions[0]] = row
            for index in reversed(positions[1:]):
                del self._rows[index]
        else:
            self._rows.append(row)
        return row

    def add(self, keyword: str, *values: object, description: str | None = None) -> Option:
        """Append a row without replacing earlier rows (for example a ``wavetrain``).

        Parameters
        ----------
        keyword : str
            Option keyword or native alias.
        *values : object
            Values, as for :meth:`set`.
        description : str | None
            Optional one-row note.

        Returns
        -------
        Option
            The new row.
        """
        row = self._make(keyword, values, description)
        self._rows.append(row)
        return row

    def remove(self, keyword: str) -> int:
        """Remove every row of ``keyword`` and its aliases.

        Parameters
        ----------
        keyword : str
            Option keyword or native alias.

        Returns
        -------
        int
            The number of rows removed.
        """
        key = self._identity(keyword)
        before = len(self._rows)
        self._rows[:] = [row for row in self._rows if self._identity(row.keyword) != key]
        return before - len(self._rows)

    def clear(self) -> None:
        """Remove every option row."""
        self._rows.clear()


class OutputList:
    """The ``OUTPUTS`` channel names of a model, in order."""

    def __init__(self) -> None:
        self._names: list[str] = []

    def __iter__(self) -> Iterator[str]:
        return iter(tuple(self._names))

    def __len__(self) -> int:
        return len(self._names)

    def __getitem__(self, index: int) -> str:
        return self._names[index]

    def __contains__(self, channel: object) -> bool:
        return isinstance(channel, str) and channel.lower() in {n.lower() for n in self._names}

    def __repr__(self) -> str:
        return f"<OUTPUTS: {self._names!r}>"

    def add(self, *channels: str) -> None:
        """Append output channels, for example ``add("FairTen1", "AnchTen1")``.

        Parameters
        ----------
        *channels : str
            Native channel names. Unknown channels and ids are reported by
            :meth:`DeckModel.validate`.

        Raises
        ------
        TypeError
            If a channel is not a string.
        ValueError
            If a channel is not one plain token or is already listed
            (case-insensitive).
        """
        for channel in channels:
            token = _text(channel, "output channel", quote=False)
            if "," in token:
                raise ValueError(f"output channel {channel!r} must not contain ','")
            if token in self:
                raise ValueError(f"output channel {channel!r} is already listed")
            self._names.append(token)

    def remove(self, channel: str) -> None:
        """Remove one channel (case-insensitive).

        Parameters
        ----------
        channel : str
            Channel name.

        Raises
        ------
        TypeError
            If ``channel`` is not a string.
        KeyError
            If the channel is not listed.
        """
        if not isinstance(channel, str):
            raise TypeError(f"output channel must be a string, got {channel!r}")
        for index, name in enumerate(self._names):
            if name.lower() == channel.lower():
                del self._names[index]
                return
        raise KeyError(f"output channel {channel!r} is not listed")

    def clear(self) -> None:
        """Remove every channel."""
        self._names.clear()

    def _replace(self, index: int, name: str) -> None:
        self._names[index] = name


def _channel_reference(channel: str) -> tuple[str, int, re.Match[str]] | None:
    """Return the object kind and id an output channel names, if any."""
    for kind, pattern in _CHANNEL_PATTERNS:
        match = pattern.fullmatch(channel)
        if match is not None:
            return kind, int(match.group(2)), match
    return None


def _object_kind(obj: object) -> str | None:
    if isinstance(obj, Line):
        return "line"
    if isinstance(obj, Point):
        return "point"
    if isinstance(obj, (Body, MoorDynBody)):
        return "body"
    if isinstance(obj, Rod):
        return "rod"
    return None


# --------------------------------------------------------------------------- the model


class DeckModel:
    """An editable, typed object model of a CableDyn deck.

    Create one with :meth:`new`, :meth:`load`, :meth:`from_text`, or
    :meth:`from_deck_file`. Objects are plain dataclasses whose fields may be
    edited in place; rows refer to other objects by reference, so renaming an
    object never breaks the rows that use it. Structural edits go through the
    ``add_*``, :meth:`rename`, and :meth:`remove` methods, which keep the
    references consistent. :meth:`validate`, :meth:`to_text`, and
    :meth:`save` check the complete deck with :class:`cabledyn.DeckFile`.

    Parameters
    ----------
    title : str
        Free-text title written below the deck banner.
    path : str | os.PathLike
        Nominal deck path; relative ancillary paths (motion, bathymetry,
        WaterKin, Syrope files) resolve against its folder.
    caller_driven : bool
        Validate for the OpenFAST coupling (``CompMooring = 5``) instead of
        the standalone driver; see :class:`cabledyn.DeckFile`. The native C
        API reads decks with the standalone rules.

    Attributes
    ----------
    title : str
        Deck title.
    path : pathlib.Path
        Absolute nominal deck path.
    caller_driven : bool
        Validation route.
    options : OptionSet
        The ``OPTIONS`` rows.
    outputs : OutputList
        The ``OUTPUTS`` channels.

    Examples
    --------
    >>> model = DeckModel.new(title="single chain")
    >>> chain = model.add_line_type("chain", diam=0.252, mass=390.0, ea=1.674e9,
    ...                             ba=-1.0, cdn=1.37, cdt=0.64, can=1.0)
    >>> fairlead = model.add_point(1, "Coupled", 0.0, 0.0, -14.0)
    >>> anchor = model.add_point(2, "Fixed", 400.0, 0.0, -50.0)
    >>> line = model.add_line(1, fairlead, anchor, chain, length=410.0, num_segs=41)
    >>> _ = model.options.set("WtrDpth", 50.0, description="Water depth (m)")
    >>> model.outputs.add("FairTen1")
    >>> model.save("chain.dat")  # doctest: +SKIP
    """

    def __init__(
        self,
        *,
        title: str = "CableDyn deck",
        path: str | os.PathLike[str] = "deck.dat",
        caller_driven: bool = False,
    ) -> None:
        if not isinstance(caller_driven, bool):
            raise TypeError("caller_driven must be a Boolean")
        self.title = title
        self.path = Path(path).expanduser().resolve()
        self.caller_driven = caller_driven
        self._line_types: list[LineType] = []
        self._rod_types: list[RodType] = []
        self._bodies: list[AnyBody] = []
        self._rods: list[Rod] = []
        self._turbines: list[Turbine] = []
        self._points: list[Point] = []
        self._lines: list[Line] = []
        self._end_connections: list[EndConnection] = []
        self._equivalent_buoyancy: list[EquivalentBuoyancy] = []
        self._attachments: list[Attachment] = []
        self._stiffeners: list[Stiffener] = []
        self._syrope_ic: list[SyropeIC] = []
        self._failures: list[Failure] = []
        self._controls: list[Control] = []
        self._external_loads: list[ExternalLoad] = []
        self.options = OptionSet()
        self.outputs = OutputList()

    # ------------------------------------------------------------------ construction

    @classmethod
    def new(
        cls,
        *,
        title: str = "CableDyn deck",
        path: str | os.PathLike[str] = "deck.dat",
        caller_driven: bool = False,
    ) -> DeckModel:
        """Return an empty model.

        Parameters
        ----------
        title : str
            Deck title.
        path : str | os.PathLike
            Nominal deck path that anchors relative ancillary paths.
        caller_driven : bool
            Validate for the OpenFAST coupling instead of the standalone driver.

        Returns
        -------
        DeckModel
            A model with no objects.
        """
        return cls(title=title, path=path, caller_driven=caller_driven)

    @classmethod
    def load(cls, path: str | os.PathLike[str], *, caller_driven: bool = False) -> DeckModel:
        """Read and validate a deck file into a model.

        Parameters
        ----------
        path : str | os.PathLike
            Deck file.
        caller_driven : bool
            Validate for the OpenFAST coupling instead of the standalone driver.

        Returns
        -------
        DeckModel
            The model of the deck.

        Raises
        ------
        DeckFormatError
            If the file cannot be read or violates the native deck contract.
        """
        return cls.from_deck_file(DeckFile.read(path, caller_driven=caller_driven))

    @classmethod
    def from_text(
        cls,
        text: str,
        *,
        path: str | os.PathLike[str] = "deck.dat",
        caller_driven: bool = False,
    ) -> DeckModel:
        """Validate deck text and return its model.

        Parameters
        ----------
        text : str
            Complete deck text.
        path : str | os.PathLike
            Nominal deck path that anchors relative ancillary paths.
        caller_driven : bool
            Validate for the OpenFAST coupling instead of the standalone driver.

        Returns
        -------
        DeckModel
            The model of the deck.

        Raises
        ------
        DeckFormatError
            If the text violates the native deck contract.
        """
        return cls.from_deck_file(DeckFile.from_text(text, path=path, caller_driven=caller_driven))

    @classmethod
    def from_deck_file(cls, deck: DeckFile) -> DeckModel:
        """Build a model from a validated :class:`cabledyn.DeckFile`.

        Parameters
        ----------
        deck : DeckFile
            A parsed deck; its path and validation route carry over.

        Returns
        -------
        DeckModel
            The model of the deck.
        """
        model = cls(title=_deck_title(deck), path=deck.path, caller_driven=deck.caller_driven)
        _Loader(model, deck).load()
        return model

    def copy(self) -> DeckModel:
        """Return an independent deep copy with its own objects.

        Returns
        -------
        DeckModel
            The copy.
        """
        return copy.deepcopy(self)

    # ------------------------------------------------------------------ collections

    @property
    def line_types(self) -> ObjectCollection[LineType]:
        """``LINE TYPES`` rows, looked up by case-insensitive name."""
        return ObjectCollection(self._line_types, lambda item: item.name, "line type")

    @property
    def rod_types(self) -> ObjectCollection[RodType]:
        """``ROD TYPES`` rows, looked up by case-insensitive name."""
        return ObjectCollection(self._rod_types, lambda item: item.name, "rod type")

    @property
    def bodies(self) -> ObjectCollection[AnyBody]:
        """``BODIES`` rows (:class:`Body` or :class:`MoorDynBody`), looked up by id."""
        return ObjectCollection(self._bodies, lambda item: item.id, "body")

    @property
    def rods(self) -> ObjectCollection[Rod]:
        """``RODS`` rows, looked up by id."""
        return ObjectCollection(self._rods, lambda item: item.id, "rod")

    @property
    def turbines(self) -> ObjectCollection[Turbine]:
        """``TURBINES`` rows, looked up by turbine number."""
        return ObjectCollection(self._turbines, lambda item: item.id, "turbine")

    @property
    def points(self) -> ObjectCollection[Point]:
        """``POINTS`` rows, looked up by id."""
        return ObjectCollection(self._points, lambda item: item.id, "point")

    @property
    def lines(self) -> ObjectCollection[Line]:
        """``LINES`` rows with their sections, looked up by id."""
        return ObjectCollection(self._lines, lambda item: item.id, "line")

    @property
    def end_connections(self) -> tuple[EndConnection, ...]:
        """``END CONNECTIONS`` rows."""
        return tuple(self._end_connections)

    @property
    def equivalent_buoyancy(self) -> tuple[EquivalentBuoyancy, ...]:
        """``EQUIVALENT BUOYANCY`` rows."""
        return tuple(self._equivalent_buoyancy)

    @property
    def attachments(self) -> tuple[Attachment, ...]:
        """``ATTACHMENTS`` rows."""
        return tuple(self._attachments)

    @property
    def stiffeners(self) -> tuple[Stiffener, ...]:
        """``STIFFENERS`` rows."""
        return tuple(self._stiffeners)

    @property
    def syrope_ic(self) -> tuple[SyropeIC, ...]:
        """``SYROPE IC`` rows."""
        return tuple(self._syrope_ic)

    @property
    def failures(self) -> tuple[Failure, ...]:
        """``FAILURE`` rows; row *i* (from 1) is ``FailID`` *i*."""
        return tuple(self._failures)

    @property
    def controls(self) -> tuple[Control, ...]:
        """``CONTROL`` rows."""
        return tuple(self._controls)

    @property
    def external_loads(self) -> tuple[ExternalLoad, ...]:
        """``EXTERNAL LOADS`` rows."""
        return tuple(self._external_loads)

    # ------------------------------------------------------------------ resolution

    def _member(self, obj: object, items: Sequence[object], label: str) -> None:
        if not any(item is obj for item in items):
            raise DeckReferenceError(f"{label} {obj!r} is not part of this model")

    def _line_type(self, ref: LineType | str) -> LineType:
        if isinstance(ref, LineType):
            self._member(ref, self._line_types, "line type")
            return ref
        return self.line_types[ref]

    def _rod_type(self, ref: RodType | str) -> RodType:
        if isinstance(ref, RodType):
            self._member(ref, self._rod_types, "rod type")
            return ref
        return self.rod_types[ref]

    def _body(self, ref: AnyBody | int) -> AnyBody:
        if isinstance(ref, (Body, MoorDynBody)):
            self._member(ref, self._bodies, "body")
            return ref
        return self.bodies[ref]

    def _point(self, ref: Point | int) -> Point:
        if isinstance(ref, Point):
            self._member(ref, self._points, "point")
            return ref
        return self.points[ref]

    def _line(self, ref: Line | int) -> Line:
        if isinstance(ref, Line):
            self._member(ref, self._lines, "line")
            return ref
        return self.lines[ref]

    def _lines_of(self, refs: Line | int | Iterable[Line | int]) -> list[Line]:
        if isinstance(refs, (Line, int)):
            refs = [refs]
        lines = [self._line(ref) for ref in refs]
        if not lines:
            raise ValueError("at least one line is required")
        return lines

    def rod_end(self, rod: Rod | int, end: str) -> RodEnd:
        """Return end ``A`` or ``B`` of a rod, to use as a line end or point type.

        Parameters
        ----------
        rod : Rod | int
            The rod or its id.
        end : str
            ``"A"`` or ``"B"``.

        Returns
        -------
        RodEnd
            The rod end.
        """
        if isinstance(rod, Rod):
            self._member(rod, self._rods, "rod")
        else:
            rod = self.rods[rod]
        return RodEnd(rod, _end_letter(end))

    def _line_end(self, ref: Point | RodEnd | int | str) -> LineEnd:
        if isinstance(ref, RodEnd):
            self._member(ref.rod, self._rods, "rod")
            return ref
        if isinstance(ref, str):
            canonical = _rod_end_token(ref)
            if canonical is None:
                if ref.strip().isdigit():
                    raise TypeError(
                        f"line end {ref!r} is a string; pass a point id as an integer "
                        f"({int(ref)}) or a rod end as R<N>A/R<N>B"
                    )
                raise ValueError(f"line end {ref!r} is not a point id or a rod end R<N>A/R<N>B")
            return self.rod_end(int(canonical[3:-1]), canonical[-1])
        return self._point(ref)

    def _typed_reference(
        self,
        kind: str,
        body: AnyBody | int | None,
        rod_end: RodEnd | None,
        turbine: int | None,
    ) -> tuple[str, AnyBody | None, RodEnd | None, int | None]:
        """Split a point type such as ``Body2`` into its kind and referenced object."""
        lowered = kind.lower()
        rod_point = _rod_point(lowered)
        if rod_point is not None:
            rod_end = self.rod_end(rod_point[0], rod_point[1])
            return kind[:3], None, rod_end, None
        if lowered.startswith("body") and lowered != "body":
            return kind[:4], self.bodies[_body_point_id(lowered)], None, None
        if _is_turbine_point_type(lowered) and lowered not in {"turbine", "t"}:
            prefix = kind[:7] if lowered.startswith("turbine") else kind[:1]
            return prefix, None, None, _turbine_id(lowered)
        resolved_body = None if body is None else self._body(body)
        if rod_end is not None:
            self._member(rod_end.rod, self._rods, "rod")
        return kind, resolved_body, rod_end, turbine

    # ------------------------------------------------------------------ adding objects

    def _check_new_key(self, collection: ObjectCollection[_T], key: int | str) -> None:
        numeric = collection._label not in {"line type", "rod type"}
        if isinstance(key, bool) or not isinstance(key, int if numeric else str):
            kind = "an integer id" if numeric else "a name"
            raise TypeError(f"{collection._label} key must be {kind}, got {key!r}")
        if key in collection:
            raise ValueError(f"{collection._label} {key!r} already exists")

    def add_line_type(
        self,
        name: str,
        *,
        diam: float,
        mass: float,
        ea: float | tuple[float, ...] | SyropeEA,
        ba: float | tuple[float, ...] = 0.0,
        ei: float = 0.0,
        cdn: float = 0.0,
        cdt: float = 0.0,
        can: float = 0.0,
        cat: float = 0.0,
        gas: float | None = None,
        gj: float | tuple[float, ...] | None = None,
        irt: float | None = None,
        irn: float | None = None,
        cl: float | None = None,
        df: float | None = None,
        cf: float | None = None,
    ) -> LineType:
        """Add a ``LINE TYPES`` row; see :class:`LineType` for the fields.

        Returns
        -------
        LineType
            The new line type.

        Raises
        ------
        ValueError
            If a line type of that name (case-insensitive) exists.
        """
        _text(name, "line-type name")
        self._check_new_key(self.line_types, name)
        item = LineType(
            name, diam, mass, ea, ba, ei, cdn, cdt, can, cat, gas, gj, irt, irn, cl, df, cf
        )
        self._line_types.append(item)
        return item

    def add_rod_type(
        self,
        name: str,
        *,
        diam: float,
        mass: float,
        cd: float = 0.0,
        ca: float = 0.0,
        cd_end: float = 0.0,
        ca_end: float = 0.0,
        cd_ax: float | None = None,
        ca_ax: float | None = None,
    ) -> RodType:
        """Add a ``ROD TYPES`` row; see :class:`RodType` for the fields.

        Returns
        -------
        RodType
            The new rod type.

        Raises
        ------
        ValueError
            If a rod type of that name (case-insensitive) exists.
        """
        _text(name, "rod-type name")
        self._check_new_key(self.rod_types, name)
        item = RodType(name, diam, mass, cd, ca, cd_end, ca_end, cd_ax, ca_ax)
        self._rod_types.append(item)
        return item

    def add_body(
        self,
        body_id: int,
        type: str,
        x: float,
        y: float,
        z: float,
        *,
        roll: float = 0.0,
        pitch: float = 0.0,
        yaw: float = 0.0,
        mass: float = 0.0,
        volume: float = 0.0,
        c33: float = 0.0,
        c44: float = 0.0,
        c55: float = 0.0,
        cda: float = 0.0,
        ca: float = 0.0,
        inertia: Vec3 | None = None,
    ) -> Body:
        """Add a CableDyn ``BODIES`` row; see :class:`Body` for the fields.

        Returns
        -------
        Body
            The new body.

        Raises
        ------
        ValueError
            If a body with ``body_id`` exists.
        """
        self._check_new_key(self.bodies, body_id)
        item = Body(
            body_id, type, x, y, z, roll, pitch, yaw, mass, volume, c33, c44, c55, cda, ca, inertia
        )
        self._bodies.append(item)
        return item

    def add_moordyn_body(
        self,
        body_id: int,
        type: str,
        x: float,
        y: float,
        z: float,
        *,
        roll: float = 0.0,
        pitch: float = 0.0,
        yaw: float = 0.0,
        mass: float = 0.0,
        cg: float | tuple[float, ...] = 0.0,
        inertia: float | tuple[float, ...] = 0.0,
        volume: float = 0.0,
        cda: float | tuple[float, ...] = 0.0,
        ca: float | tuple[float, ...] = 0.0,
    ) -> MoorDynBody:
        """Add a 14-column MoorDyn ``BODIES`` row; see :class:`MoorDynBody`.

        Returns
        -------
        MoorDynBody
            The new body.

        Raises
        ------
        ValueError
            If a body with ``body_id`` exists.
        """
        self._check_new_key(self.bodies, body_id)
        item = MoorDynBody(
            body_id, type, x, y, z, roll, pitch, yaw, mass, cg, inertia, volume, cda, ca
        )
        self._bodies.append(item)
        return item

    def add_rod(
        self,
        rod_id: int,
        rod_type: RodType | str,
        type: str,
        end_a: Vec3,
        end_b: Vec3,
        num_segs: int,
        *,
        outputs: str = "-",
        body: AnyBody | int | None = None,
    ) -> Rod:
        """Add a ``RODS`` row; see :class:`Rod` for the fields.

        ``type`` may name a body directly (``"Body1"``, ``"Body1Pinned"``) or
        be ``"Body"``/``"BodyPinned"`` together with ``body``.

        Returns
        -------
        Rod
            The new rod.

        Raises
        ------
        KeyError
            If the rod type or body does not exist.
        ValueError
            If a rod with ``rod_id`` exists.
        """
        self._check_new_key(self.rods, rod_id)
        resolved_type = self._rod_type(rod_type)
        _text(type, "rod type")
        kind = _ROD_ATTACHMENT_ALIASES.get(type.lower(), type.lower())
        match = re.fullmatch(r"body([0-9]+)((?:pin|pinned)?)", kind)
        resolved_body = None if body is None else self._body(body)
        if match is not None:
            resolved_body = self.bodies[int(match.group(1))]
            type = type[:4] + type[4 + len(match.group(1)) :]
        item = Rod(rod_id, resolved_type, type, end_a, end_b, num_segs, outputs, resolved_body)
        self._rods.append(item)
        return item

    def add_turbine(
        self, turbine_id: int, x: float, y: float, z: float, *, ptfm: Sequence[float] | None = None
    ) -> Turbine:
        """Add a ``TURBINES`` row; see :class:`Turbine` for the fields.

        Returns
        -------
        Turbine
            The new turbine.

        Raises
        ------
        ValueError
            If the turbine number exists.
        """
        self._check_new_key(self.turbines, turbine_id)
        item = Turbine(turbine_id, x, y, z, None if ptfm is None else tuple(ptfm))
        self._turbines.append(item)
        return item

    def add_point(
        self,
        point_id: int,
        type: str,
        x: float,
        y: float,
        z: float,
        *,
        mass: float = 0.0,
        volume: float = 0.0,
        cda: float = 0.0,
        ca: float = 0.0,
        body: AnyBody | int | None = None,
        rod_end: RodEnd | None = None,
        turbine: int | None = None,
    ) -> Point:
        """Add a ``POINTS`` row; see :class:`Point` for the fields.

        ``type`` may name the referenced object directly (``"Body1"``,
        ``"Rod2A"``, ``"Turbine3"``) or be ``"Body"``/``"Rod"``/``"Turbine"``
        together with ``body``, ``rod_end``, or ``turbine``.

        Returns
        -------
        Point
            The new point.

        Raises
        ------
        KeyError
            If a named body or rod does not exist.
        ValueError
            If a point with ``point_id`` exists.
        """
        self._check_new_key(self.points, point_id)
        _text(type, "point type")
        kind, resolved_body, resolved_rod_end, resolved_turbine = self._typed_reference(
            type, body, rod_end, turbine
        )
        item = Point(
            point_id,
            kind,
            x,
            y,
            z,
            mass,
            volume,
            cda,
            ca,
            resolved_body,
            resolved_rod_end,
            resolved_turbine,
        )
        self._points.append(item)
        return item

    def add_line(
        self,
        line_id: int,
        end_a: Point | RodEnd | int | str,
        end_b: Point | RodEnd | int | str,
        line_type: LineType | str | None = None,
        *,
        length: float | None = None,
        num_segs: int | None = None,
        outputs: str = "-",
        stock_row: bool = False,
    ) -> Line:
        """Add a ``LINES`` row, optionally with its first section.

        Parameters
        ----------
        line_id : int
            Unique line id.
        end_a, end_b : Point | RodEnd | int | str
            End A (fairlead side) and End B (anchor side): a point, a point
            id, a :class:`RodEnd`, or a rod-end token such as ``"R1A"``.
        line_type : LineType | str | None
            Line type of a first section; give ``length`` and ``num_segs`` too.
        length : float | None
            First-section unstretched length, in m.
        num_segs : int | None
            First-section element count.
        outputs : str
            Per-line output flags (``-``, or ``p``/``t``/``r`` combined).
        stock_row : bool
            Write a single-section line as a stock MoorDyn 7-column row.

        Returns
        -------
        Line
            The new line.

        Raises
        ------
        KeyError
            If an end or the line type does not exist.
        ValueError
            If a line with ``line_id`` exists, or only part of the first
            section is given.
        """
        self._check_new_key(self.lines, line_id)
        item = Line(line_id, self._line_end(end_a), self._line_end(end_b), [], outputs, stock_row)
        given = (line_type is not None, length is not None, num_segs is not None)
        if any(given) and not all(given):
            raise ValueError("give line_type, length, and num_segs together for a first section")
        if line_type is not None and length is not None and num_segs is not None:
            item.sections.append(Section(self._line_type(line_type), length, num_segs))
        self._lines.append(item)
        return item

    def add_section(
        self,
        line: Line | int,
        line_type: LineType | str,
        length: float,
        num_segs: int,
        *,
        index: int | None = None,
    ) -> Section:
        """Add a section to a line.

        Parameters
        ----------
        line : Line | int
            The line or its id.
        line_type : LineType | str
            The section's line type or its name.
        length : float
            Unstretched length, in m.
        num_segs : int
            Element count.
        index : int | None
            Position in the line's section list (End A first); appended at
            End B when ``None``.

        Returns
        -------
        Section
            The new section.
        """
        target = self._line(line)
        item = Section(self._line_type(line_type), length, num_segs)
        if index is None:
            target.sections.append(item)
        else:
            target.sections.insert(index, item)
        return item

    def add_end_connection(
        self,
        line: Line | int,
        end: str,
        stiffness: float | str,
        direction: Sequence[float],
        *,
        torsion_stiffness: float | str | None = None,
        normal: Sequence[float] | None = None,
        pretwist: float | None = None,
    ) -> EndConnection:
        """Add an ``END CONNECTIONS`` row; see :class:`EndConnection`.

        Returns
        -------
        EndConnection
            The new row.

        Raises
        ------
        ValueError
            If ``end`` is not A or B, that line end already has a row,
            ``direction`` or ``normal`` does not hold three values, or the
            torsion columns are incomplete (``torsion_stiffness`` and ``normal``
            go together; ``pretwist`` needs them).
        """
        target = self._line(line)
        letter = _end_letter(end)
        if any(row.line is target and row.end == letter for row in self._end_connections):
            raise ValueError(f"line {target.id} End {letter} already has an end connection")
        if len(direction) != 3:
            raise ValueError(f"end-connection direction must be three numbers, got {direction!r}")
        if (torsion_stiffness is None) != (normal is None):
            raise ValueError("end-connection torsion_stiffness and normal must be given together")
        if pretwist is not None and torsion_stiffness is None:
            raise ValueError("end-connection pretwist needs torsion_stiffness and normal")
        torsion_normal: Vec3 | None = None
        if normal is not None:
            if len(normal) != 3:
                raise ValueError(f"end-connection normal must be three numbers, got {normal!r}")
            nx, ny, nz = normal
            torsion_normal = (nx, ny, nz)
        x, y, z = direction
        item = EndConnection(
            target,
            letter,
            stiffness,
            (x, y, z),
            torsion_stiffness=torsion_stiffness,
            normal=torsion_normal,
            pretwist=pretwist,
        )
        self._end_connections.append(item)
        return item

    def add_equivalent_buoyancy(
        self, line_type: LineType | str, diam: float, submerged_weight: float
    ) -> EquivalentBuoyancy:
        """Add an ``EQUIVALENT BUOYANCY`` row; see :class:`EquivalentBuoyancy`.

        Returns
        -------
        EquivalentBuoyancy
            The new row.
        """
        item = EquivalentBuoyancy(self._line_type(line_type), diam, submerged_weight)
        self._equivalent_buoyancy.append(item)
        return item

    def add_attachment(
        self,
        line: Line | int,
        arc_length: float | tuple[float, float, float],
        *,
        mass: float = 0.0,
        volume: float = 0.0,
        cda: float = 0.0,
        ca: float = 0.0,
        cdax: float | None = None,
    ) -> Attachment:
        """Add an ``ATTACHMENTS`` row; see :class:`Attachment`.

        Returns
        -------
        Attachment
            The new row.
        """
        item = Attachment(self._line(line), arc_length, mass, volume, cda, ca, cdax)
        self._attachments.append(item)
        return item

    def add_stiffener(
        self,
        line: Line | int,
        end: str,
        length: float,
        root_od: float,
        tip_od: float,
        inner_d: float,
        modulus: float,
        density: float,
    ) -> Stiffener:
        """Add a ``STIFFENERS`` row (one conical segment); see :class:`Stiffener`.

        Returns
        -------
        Stiffener
            The new row.
        """
        item = Stiffener(self._line(line), end, length, root_od, tip_od, inner_d, modulus, density)
        self._stiffeners.append(item)
        return item

    def add_syrope_ic(
        self, lines: Line | int | Iterable[Line | int], tmax0: float, tmean0: float
    ) -> SyropeIC:
        """Add a ``SYROPE IC`` row; see :class:`SyropeIC`.

        Returns
        -------
        SyropeIC
            The new row.
        """
        item = SyropeIC(self._lines_of(lines), tmax0, tmean0)
        self._syrope_ic.append(item)
        return item

    def add_failure(
        self,
        point: Point | int,
        lines: Line | int | Iterable[Line | int],
        *,
        fail_time: float = 0.0,
        fail_tension: float = 0.0,
    ) -> Failure:
        """Add a ``FAILURE`` row; its ``FailID`` is its position in :attr:`failures`.

        Returns
        -------
        Failure
            The new row.
        """
        item = Failure(self._point(point), self._lines_of(lines), fail_time, fail_tension)
        self._failures.append(item)
        return item

    def add_control(self, channel: int, lines: Line | int | Iterable[Line | int]) -> Control:
        """Add a ``CONTROL`` row; see :class:`Control`.

        Returns
        -------
        Control
            The new row.
        """
        item = Control(channel, self._lines_of(lines))
        self._controls.append(item)
        return item

    def add_external_load(
        self,
        load_id: int,
        body: AnyBody | int,
        *,
        csys: str = "G",
        force: float | tuple[float, ...] = 0.0,
        blin: float | tuple[float, ...] = 0.0,
        bquad: float | tuple[float, ...] = 0.0,
    ) -> ExternalLoad:
        """Add an ``EXTERNAL LOADS`` row; see :class:`ExternalLoad`.

        Returns
        -------
        ExternalLoad
            The new row.
        """
        item = ExternalLoad(load_id, self._body(body), csys, force, blin, bquad)
        self._external_loads.append(item)
        return item

    # ------------------------------------------------------------------ prescribed motion

    def _set_motion(
        self, keyword: str, path: str | os.PathLike[str], reference: Sequence[float] | None
    ) -> None:
        for other in _MOTION_KEYWORDS:
            if other != keyword:
                self.options.remove(other)
        self.options.set(keyword, os.fspath(path))
        if reference is not None:
            self.options.set("vesselRef", tuple(reference))

    def set_motion_file(self, path: str | os.PathLike[str]) -> None:
        """Prescribe point, rod-end, and body motion from a ``motionFile`` time series.

        Removes any ``vesselMotion``/``vesselRAO`` row (the three are
        alternatives).

        Parameters
        ----------
        path : str | os.PathLike
            Motion file, relative to the deck folder or absolute.
        """
        self._set_motion("motionFile", path, None)

    def set_vessel_motion(
        self, path: str | os.PathLike[str], *, reference: Sequence[float] | None = None
    ) -> None:
        """Move every ``Coupled``/``Vessel`` point rigidly with a 6-DOF vessel record.

        Removes any ``motionFile``/``vesselRAO`` row.

        Parameters
        ----------
        path : str | os.PathLike
            ``vesselMotion`` record file.
        reference : Sequence[float] | None
            Vessel reference point ``(x, y, z)`` in m (``vesselRef``); left
            unchanged when ``None``.
        """
        self._set_motion("vesselMotion", path, reference)

    def set_vessel_rao(
        self, path: str | os.PathLike[str], *, reference: Sequence[float] | None = None
    ) -> None:
        """Move the vessel as the RAO response to the deck waves.

        Removes any ``motionFile``/``vesselMotion`` row. The deck needs linear
        waves (a ``waves`` row, ``wavetrain`` rows, or a WaterKin file).

        Parameters
        ----------
        path : str | os.PathLike
            ``vesselRAO`` table file.
        reference : Sequence[float] | None
            Vessel reference point ``(x, y, z)`` in m (``vesselRef``, the RAO
            origin); left unchanged when ``None``.
        """
        self._set_motion("vesselRAO", path, reference)

    def clear_motion(self) -> None:
        """Remove every prescribed-motion row (``motionFile``, ``vesselMotion``,
        ``vesselRAO``, and ``vesselRef``)."""
        for keyword in (*_MOTION_KEYWORDS, "vesselRef"):
            self.options.remove(keyword)

    # ------------------------------------------------------------------ references

    def _registry(self, obj: object) -> list[Any] | None:
        registries: tuple[tuple[type | tuple[type, ...], list[Any]], ...] = (
            (LineType, self._line_types),
            (RodType, self._rod_types),
            ((Body, MoorDynBody), self._bodies),
            (Rod, self._rods),
            (Turbine, self._turbines),
            (Point, self._points),
            (Line, self._lines),
            (EndConnection, self._end_connections),
            (EquivalentBuoyancy, self._equivalent_buoyancy),
            (Attachment, self._attachments),
            (Stiffener, self._stiffeners),
            (SyropeIC, self._syrope_ic),
            (Failure, self._failures),
            (Control, self._controls),
            (ExternalLoad, self._external_loads),
        )
        for kinds, items in registries:
            if isinstance(obj, kinds):
                return items
        return None

    def _is_member(self, obj: object) -> bool:
        if isinstance(obj, str):
            return obj in self.outputs
        if isinstance(obj, Section):
            return self._section_owner(obj) is not None
        items = self._registry(obj)
        return items is not None and any(item is obj for item in items)

    def _line_options(self, line_id: int) -> list[Option]:
        """The ``layAzimuth<L>``/``asLaidTension<L>`` rows that name LINE ``line_id``."""
        rows: list[Option] = []
        for row in self.options:
            match = _LINE_OPTION_PATTERN.match(row.keyword.lower())
            if match is not None and int(match.group(2)) == line_id:
                rows.append(row)
        return rows

    def _section_owner(self, section: Section) -> Line | None:
        for line in self._lines:
            if any(item is section for item in line.sections):
                return line
        return None

    def references(self, obj: object) -> tuple[object, ...]:
        """Return the rows and output channels that use ``obj``.

        Parameters
        ----------
        obj : object
            A model object.

        Returns
        -------
        tuple[object, ...]
            Referring objects (lines, sections, points, rows, the per-line
            ``layAzimuth<L>``/``asLaidTension<L>`` options of a line, ...) and
            output channel names, in deck order.

        Raises
        ------
        DeckReferenceError
            If ``obj`` is not part of this model.
        """
        if not self._is_member(obj):
            raise DeckReferenceError(f"{obj!r} is not part of this model")
        found: list[object] = []
        if isinstance(obj, LineType):
            for line in self._lines:
                found.extend(s for s in line.sections if s.line_type is obj)
            found.extend(row for row in self._equivalent_buoyancy if row.line_type is obj)
        elif isinstance(obj, RodType):
            found.extend(rod for rod in self._rods if rod.rod_type is obj)
        elif isinstance(obj, (Body, MoorDynBody)):
            found.extend(point for point in self._points if point.body is obj)
            found.extend(rod for rod in self._rods if rod.body is obj)
            found.extend(row for row in self._external_loads if row.body is obj)
        elif isinstance(obj, Rod):
            found.extend(p for p in self._points if p.rod_end is not None and p.rod_end.rod is obj)
            found.extend(
                line
                for line in self._lines
                if any(
                    isinstance(end, RodEnd) and end.rod is obj for end in (line.end_a, line.end_b)
                )
            )
        elif isinstance(obj, Turbine):
            found.extend(point for point in self._points if point.turbine == obj.id)
        elif isinstance(obj, Point):
            found.extend(line for line in self._lines if obj in (line.end_a, line.end_b))
            found.extend(row for row in self._failures if row.point is obj)
        elif isinstance(obj, Line):
            found.extend(row for row in self._end_connections if row.line is obj)
            found.extend(row for row in self._attachments if row.line is obj)
            found.extend(row for row in self._stiffeners if row.line is obj)
            for rows in (self._syrope_ic, self._failures, self._controls):
                found.extend(row for row in rows if any(line is obj for line in row.lines))
            found.extend(self._line_options(obj.id))
        kind = _object_kind(obj)
        if kind is not None:
            object_id = getattr(obj, "id")  # noqa: B009 (every referenced kind has an id)
            for channel in self.outputs:
                reference = _channel_reference(channel)
                if reference is not None and reference[:2] == (kind, object_id):
                    found.append(channel)
        return tuple(found)

    def remove(self, obj: object, *, cascade: bool = False) -> None:
        """Remove an object from the model.

        Parameters
        ----------
        obj : object
            A model object: a type, body, rod, turbine, point, line, section,
            row, or an output channel name.
        cascade : bool
            Also remove what uses ``obj``: lines on a removed point, the rows
            of a removed line (a line is dropped from multi-line rows, and a
            row left without lines is removed), the per-line options and output
            channels that name it, and so on recursively. A line left without
            sections by a removed line type is removed too.

        Raises
        ------
        DeckReferenceError
            If ``obj`` is not part of this model, or is still referenced and
            ``cascade`` is false. The error lists the referrers.
        """
        referrers = self.references(obj)
        if referrers and not cascade:
            names = ", ".join(_describe(ref) for ref in referrers)
            raise DeckReferenceError(
                f"{_describe(obj)} is still used by {names}; remove those first or pass "
                "cascade=True",
                referrers,
            )
        for ref in referrers:
            if isinstance(ref, Option):
                self.options._rows[:] = [row for row in self.options._rows if row is not ref]
                continue
            if not self._is_member(ref):
                continue
            if isinstance(ref, (SyropeIC, Failure, Control)) and isinstance(obj, Line):
                ref.lines[:] = [line for line in ref.lines if line is not obj]
                if ref.lines:
                    continue
            if isinstance(ref, Section):
                owner = self._section_owner(ref)
                assert owner is not None
                owner.sections[:] = [s for s in owner.sections if s is not ref]
                if not owner.sections:
                    self.remove(owner, cascade=True)
                continue
            self.remove(ref, cascade=True)
        self._unregister(obj)

    def _unregister(self, obj: object) -> None:
        if isinstance(obj, str):
            self.outputs.remove(obj)
            return
        if isinstance(obj, Section):
            owner = self._section_owner(obj)
            assert owner is not None
            owner.sections[:] = [s for s in owner.sections if s is not obj]
            return
        items = self._registry(obj)
        assert items is not None
        items[:] = [item for item in items if item is not obj]

    def rename(
        self, obj: LineType | RodType | AnyBody | Rod | Turbine | Point | Line, new: int | str
    ) -> None:
        """Give an object a new id (or name, for line and rod types).

        Rows that use the object follow it automatically; output channels that
        name the object by id (``FairTen<L>``, ``Point<P>pz``, ``Body<N>Px``,
        ``Rod<N>Pz``, ...) and the per-line options of a line
        (``layAzimuth<L>``, ``asLaidTension<L>``) are rewritten.

        Parameters
        ----------
        obj : LineType | RodType | Body | MoorDynBody | Rod | Turbine | Point | Line
            The object.
        new : int | str
            The new id, or the new name of a line or rod type.

        Raises
        ------
        DeckReferenceError
            If ``obj`` is not part of this model.
        ValueError
            If another object of the same kind already has ``new``.
        TypeError
            If ``new`` has the wrong type for the object.
        """
        if not self._is_member(obj):
            raise DeckReferenceError(f"{obj!r} is not part of this model")
        if isinstance(obj, (LineType, RodType)):
            if not isinstance(new, str):
                raise TypeError(f"a type name must be a string, got {new!r}")
            _text(new, "type name")
            collection: ObjectCollection[object] = (
                self.line_types if isinstance(obj, LineType) else self.rod_types  # type: ignore[assignment]
            )
            other = collection.get(new)
            if other is not None and other is not obj:
                raise ValueError(f"{collection._label} {new!r} already exists")
            obj.name = new
            return
        if isinstance(new, bool) or not isinstance(new, int):
            raise TypeError(f"an id must be an integer, got {new!r}")
        kind = _object_kind(obj)
        registry = self._registry(obj)
        assert registry is not None
        if any(item is not obj and getattr(item, "id") == new for item in registry):  # noqa: B009
            raise ValueError(f"id {new} is already used by another {type(obj).__name__}")
        old = obj.id
        line_options = self._line_options(old) if isinstance(obj, Line) else []
        if isinstance(obj, Turbine):
            for point in self._points:
                if point.turbine == old:
                    point.turbine = new
        obj.id = new
        for row in line_options:
            match = _LINE_OPTION_PATTERN.match(row.keyword.lower())
            assert match is not None
            row.keyword = f"{row.keyword[: len(match.group(1))]}{new}"
        if kind is None:
            return
        for index, channel in enumerate(self.outputs):
            reference = _channel_reference(channel)
            if reference is not None and reference[:2] == (kind, old):
                match = reference[2]
                self.outputs._replace(index, f"{match.group(1)}{new}{match.group(3)}")

    # ------------------------------------------------------------------ rendering

    def _check_references(self) -> None:
        """Check that every row refers to objects of this model."""
        for line in self._lines:
            for end in (line.end_a, line.end_b):
                if isinstance(end, RodEnd):
                    self._member(end.rod, self._rods, "rod")
                elif isinstance(end, Point):
                    self._member(end, self._points, "point")
                else:
                    raise TypeError(f"line {line.id} end must be a Point or RodEnd, got {end!r}")
            for section in line.sections:
                self._member(section.line_type, self._line_types, "line type")
        for rod in self._rods:
            self._member(rod.rod_type, self._rod_types, "rod type")
            if rod.body is not None:
                self._member(rod.body, self._bodies, "body")
        for point in self._points:
            if point.body is not None:
                self._member(point.body, self._bodies, "body")
            if point.rod_end is not None:
                self._member(point.rod_end.rod, self._rods, "rod")
        owners: list[EndConnection | Attachment | Stiffener] = [
            *self._end_connections,
            *self._attachments,
            *self._stiffeners,
        ]
        for owned in owners:
            self._member(owned.line, self._lines, "line")
        for eq in self._equivalent_buoyancy:
            self._member(eq.line_type, self._line_types, "line type")
        multis: list[SyropeIC | Failure | Control] = [
            *self._syrope_ic,
            *self._failures,
            *self._controls,
        ]
        for multi in multis:
            for line in multi.lines:
                self._member(line, self._lines, "line")
        for failure in self._failures:
            self._member(failure.point, self._points, "point")
        for load in self._external_loads:
            self._member(load.body, self._bodies, "body")

    def to_text(self, *, validate: bool = True) -> str:
        """Render the model as canonical deck text.

        Parameters
        ----------
        validate : bool
            Check the text with :class:`cabledyn.DeckFile` before returning it.

        Returns
        -------
        str
            Newline-terminated deck text.

        Raises
        ------
        DeckReferenceError
            If a row refers to an object outside this model.
        TypeError
            If a field has the wrong type.
        ValueError
            If a field cannot be written as a native token.
        DeckFormatError
            If ``validate`` is true and the deck violates the native contract.
        """
        self._check_references()
        out = [_BANNER, _check_free_text(self.title, "title") or "CableDyn deck"]
        _emit(out, "LINE TYPES", *self._line_type_table())
        _emit(out, "BODIES", *self._body_table())
        _emit(out, "ROD TYPES", *self._rod_type_table())
        _emit(out, "RODS", *self._rod_table())
        _emit(out, "TURBINES", *self._turbine_table())
        _emit(out, "POINTS", *self._point_table())
        _emit(out, "LINES", *self._line_table())
        _emit(out, "SYROPE IC", *self._syrope_table())
        _emit(out, "SECTIONS", *self._section_table())
        _emit(out, "END CONNECTIONS", *self._end_connection_table())
        _emit(out, "EQUIVALENT BUOYANCY", *self._equivalent_table())
        _emit(out, "ATTACHMENTS", *self._attachment_table())
        _emit(out, "STIFFENERS", *self._stiffener_table())
        _emit(out, "FAILURE", *self._failure_table())
        _emit(out, "CONTROL", *self._control_table())
        _emit(out, "EXTERNAL LOADS", *self._external_load_table())
        if len(self.options):
            out.append(_heading("OPTIONS"))
            out.extend(_option_row(row) for row in self.options)
        if len(self.outputs):
            out.append(_heading("OUTPUTS"))
            out.extend(f'"{name}"' for name in self.outputs)
        out.append(_FOOTER)
        text = "\n".join(out) + "\n"
        if validate:
            self._validate_text(text)
        return text

    def _validate_text(self, text: str) -> DeckFile:
        return DeckFile.from_text(
            text, path=self.path, caller_driven=self.caller_driven, label="<DeckModel deck>"
        )

    def to_deck_file(self) -> DeckFile:
        """Return the model as a validated :class:`cabledyn.DeckFile`.

        Returns
        -------
        DeckFile
            The parsed deck, anchored at :attr:`path` and on the model's
            validation route.

        Raises
        ------
        DeckFormatError
            If the deck violates the native contract.
        """
        return self._validate_text(self.to_text(validate=False))

    def validate(self) -> None:
        """Validate the model with the native deck rules of :class:`cabledyn.DeckFile`.

        Raises
        ------
        DeckReferenceError
            If a row refers to an object outside this model.
        DeckFormatError
            If the deck violates the native contract. Line numbers in the
            message refer to :meth:`to_text` output.
        """
        self.to_deck_file()

    def save(
        self,
        path: str | os.PathLike[str],
        *,
        overwrite: bool = False,
        rebase: bool = True,
    ) -> Path:
        """Validate the model and write it as a deck file.

        The model itself is unchanged: its :attr:`path` and the relative
        ancillary paths in it stay anchored at the original folder.

        Parameters
        ----------
        path : str | os.PathLike
            Target file; missing parent folders are created.
        overwrite : bool
            Replace an existing file instead of raising ``FileExistsError``.
        rebase : bool
            Rewrite relative ancillary paths (motion, bathymetry, WaterKin,
            Syrope files) so they still resolve from the target folder, and
            copy the MoorDyn-C kinematics files the solver reads by fixed name
            from the deck folder (``wave_elevation.txt`` for ``WaveKin 3``,
            ``wave_frequencies.txt`` for ``WaveKin 7``, ``current_profile.txt``,
            ``current_profile_dynamic.txt`` and ``current_profile_4d.txt`` for
            ``Currents 1``, ``2`` and ``5``) into it.

        Returns
        -------
        pathlib.Path
            Absolute path of the written deck.

        Raises
        ------
        FileExistsError
            If ``path`` exists and ``overwrite`` is false, or a different
            kinematics file of the same name is already in the target folder.
        DeckFormatError
            If the deck violates the native contract, a rebased OPTIONS path
            would contain a space, or a fixed-name kinematics file the deck
            reads is missing from :attr:`path`'s folder.
        """
        deck = self.to_deck_file()
        target = Path(path).expanduser().resolve()
        companions: list[tuple[Path, Path]] = []
        if rebase and target.parent != self.path.parent:
            deck._rebase_relative_inputs(target.parent)
            companions = _plan_companion_copies([deck], target.parent, overwrite=overwrite)
        written = deck.write(target, overwrite=overwrite)
        _copy_companions(companions)
        return written

    # ------------------------------------------------------------------ tables

    def _line_type_table(self) -> tuple[str, str, list[list[str]]]:
        rows: list[list[str]] = []
        wide = viv = False
        for item in self._line_types:
            what = f"line type {item.name!r}"
            row = [_text(item.name, what), _num(item.diam, what), _num(item.mass, what)]
            if isinstance(item.ea, SyropeEA):
                ea = f"SYROPE:{item.ea.settings}|{_num(item.ea.alpha, what)}"
                ea = f"{ea}|{_num(item.ea.beta, what)}"
                row.append(f'"{_render(ea)}"')
            else:
                row.append(_multi(item.ea, what))
            row += [_multi(item.ba, what), _num(item.ei, what)]
            extra = (item.gas, item.gj, item.irt, item.irn)
            if all(value is not None for value in extra):
                wide = True
                if isinstance(item.gj, tuple) and len(item.gj) not in (2, 3):
                    raise ValueError(f"{what}: gj is GJ, (GJ, K) or (GJ, K, Bt)")
                row += [
                    _multi(value, what) if index == 1 else _num(value, what)
                    for index, value in enumerate(extra)
                ]
            elif any(value is not None for value in extra):
                raise ValueError(f"{what}: give all of gas, gj, irt, irn or none")
            row += [_num(v, what) for v in (item.cdn, item.cdt, item.can, item.cat)]
            if item.cl is not None:
                if all(value is not None for value in extra):
                    # a LINE TYPES row has 10, 11, 13 or 14 columns: no VIV on the wide row
                    raise ValueError(f"{what}: cl, df and cf do not combine with gas, gj, irt, irn")
                viv = True
                df = 0.08 if item.df is None else item.df
                cf = 0.18 if item.cf is None else item.cf
                row += [_num(v, what) for v in (item.cl, df, cf)]
            elif item.df is not None or item.cf is not None:
                raise ValueError(f"{what}: df and cf need the VIV lift coefficient cl")
            rows.append(row)
        if wide:
            header = "Name Diam Mass EA BA EI GAs GJ Irt Irn Cd_n Cd_t Ca_n Ca_t"
            units = "(-) (m) (kg/m) (N) (N-s) (N-m^2) (N) (N-m^2) (kg-m) (kg-m) (-) (-) (-) (-)"
        elif viv:
            header = "Name Diam Mass EA BA EI Cd_n Cd_t Ca_n Ca_t Cl dF cF"
            units = "(-) (m) (kg/m) (N) (N-s) (N-m^2) (-) (-) (-) (-) (-) (-) (-)"
        else:
            header = "Name Diam Mass EA BA EI Cd_n Cd_t Ca_n Ca_t"
            units = "(-) (m) (kg/m) (N) (N-s) (N-m^2) (-) (-) (-) (-)"
        return header, units, rows

    def _body_table(self) -> tuple[str, str, list[list[str]]]:
        rows: list[list[str]] = []
        for body in self._bodies:
            what = f"body {body.id}"
            row = [_int(body.id, what), _text(body.type, what)]
            pose = (body.x, body.y, body.z, body.roll, body.pitch, body.yaw)
            row += [_num(value, what) for value in pose]
            if isinstance(body, MoorDynBody):
                row += [
                    _num(body.mass, what),
                    _multi(body.cg, what),
                    _multi(body.inertia, what),
                    _num(body.volume, what),
                    _multi(body.cda, what),
                    _multi(body.ca, what),
                ]
            else:
                values = (body.mass, body.volume, body.c33, body.c44, body.c55, body.cda, body.ca)
                row += [_num(value, what) for value in values]
                if body.inertia is not None:
                    row += _vec(body.inertia, 3, f"{what} inertia")
            rows.append(row)
        if any(isinstance(body, Body) for body in self._bodies):
            header = "ID Type X Y Z Roll Pitch Yaw Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz"
            units = (
                "(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m^3) (N/m) (N-m/rad) (N-m/rad) "
                "(m^2) (-) (kg-m^2) (kg-m^2) (kg-m^2)"
            )
        else:
            header = "ID Attachment X0 Y0 Z0 r0 p0 y0 Mass CG I Volume CdA Ca"
            units = "(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m) (kg-m^2) (m^3) (m^2) (-)"
        return header, units, rows

    def _rod_type_table(self) -> tuple[str, str, list[list[str]]]:
        rows: list[list[str]] = []
        for item in self._rod_types:
            what = f"rod type {item.name!r}"
            values = (item.diam, item.mass, item.cd, item.ca, item.cd_end, item.ca_end)
            row = [_text(item.name, what), *(_num(value, what) for value in values)]
            if (item.cd_ax is None) != (item.ca_ax is None):
                raise ValueError(f"{what}: give both cd_ax and ca_ax or neither")
            if item.cd_ax is not None and item.ca_ax is not None:
                row += [_num(item.cd_ax, what), _num(item.ca_ax, what)]
            rows.append(row)
        header = "Name Diam Mass Cd Ca CdEnd CaEnd CdAx CaAx"
        return header, "(-) (m) (kg/m) (-) (-) (-) (-) (-) (-)", rows

    def _rod_table(self) -> tuple[str, str, list[list[str]]]:
        rows: list[list[str]] = []
        for rod in self._rods:
            what = f"rod {rod.id}"
            if rod.type.lower().startswith("body") and rod.body is None:
                raise ValueError(f"{what}: a Body rod needs its body")
            if rod.body is not None and not rod.type.lower().startswith("body"):
                raise ValueError(f"{what}: only a Body/BodyPinned rod has a body")
            row = [
                _int(rod.id, what),
                _text(rod.rod_type.name, what),
                _text(rod.type_token, what),
                *_vec(rod.end_a, 3, f"{what} End A"),
                *_vec(rod.end_b, 3, f"{what} End B"),
                _int(rod.num_segs, what),
                _text(rod.outputs, what),
            ]
            rows.append(row)
        header = "ID RodType Attachment Xa Ya Za Xb Yb Zb NumSegs Outputs"
        return header, "(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)", rows

    def _turbine_table(self) -> tuple[str, str, list[list[str]]]:
        rows: list[list[str]] = []
        for turbine in self._turbines:
            what = f"turbine {turbine.id}"
            row = [_int(turbine.id, what), *_vec((turbine.x, turbine.y, turbine.z), 3, what)]
            if turbine.ptfm is not None:
                row += _vec(turbine.ptfm, 6, f"{what} ptfm")
            rows.append(row)
        header = "J X0 Y0 Z0 PtfmSurge PtfmSway PtfmHeave PtfmRoll PtfmPitch PtfmYaw"
        return header, "(-) (m) (m) (m) (m) (m) (m) (deg) (deg) (deg)", rows

    def _point_table(self) -> tuple[str, str, list[list[str]]]:
        rows: list[list[str]] = []
        for point in self._points:
            what = f"point {point.id}"
            kind = point.type.lower()
            linked = {
                "body": point.body is not None,
                "rod": point.rod_end is not None,
                "turbine": point.turbine is not None,
            }
            expected = {"body": "body", "rod": "rod", "turbine": "turbine", "t": "turbine"}
            for name, present in linked.items():
                if present != (expected.get(kind) == name):
                    raise ValueError(
                        f"{what}: type {point.type!r} does not match its body, rod_end, "
                        "and turbine fields"
                    )
            values = (point.x, point.y, point.z, point.mass, point.volume, point.cda, point.ca)
            row = [_int(point.id, what), _text(point.type_token, what)]
            rows.append(row + [_num(value, what) for value in values])
        header = "ID Type X Y Z Mass Vol CdA Ca"
        return header, "(-) (-) (m) (m) (m) (kg) (m^3) (m^2) (-)", rows

    def _is_stock(self, line: Line) -> bool:
        return line.stock_row and len(line.sections) == 1

    def _line_table(self) -> tuple[str, str, list[list[str]]]:
        rows: list[list[str]] = []
        for line in self._lines:
            what = f"line {line.id}"
            ends = [_end_token(line.end_a), _end_token(line.end_b)]
            if self._is_stock(line):
                section = line.sections[0]
                rows.append(
                    [
                        _int(line.id, what),
                        _text(section.line_type.name, what),
                        *ends,
                        _num(section.length, what),
                        _int(section.num_segs, what),
                        _text(line.outputs, what),
                    ]
                )
            else:
                rows.append([_int(line.id, what), *ends, _text(line.outputs, what)])
        if self._lines and all(len(row) == 7 for row in rows):
            header = "ID LineType AttachA AttachB UnstrLen NumSegs Outputs"
            return header, "(-) (-) (-) (-) (m) (-) (-)", rows
        return "ID NodeA NodeB Outputs", "(-) (-) (-) (-)", rows

    def _section_table(self) -> tuple[str, str, list[list[str]]]:
        rows: list[list[str]] = []
        for line in self._lines:
            if self._is_stock(line):
                continue
            what = f"line {line.id} section"
            for section in line.sections:
                rows.append(
                    [
                        _int(line.id, what),
                        _text(section.line_type.name, what),
                        _num(section.length, what),
                        _int(section.num_segs, what),
                    ]
                )
        return "LineID LineType Length NumSegs", "(-) (-) (m) (-)", rows

    def _end_connection_table(self) -> tuple[str, str, list[list[str]]]:
        rows: list[list[str]] = []
        for row in self._end_connections:
            what = f"line {row.line.id} end connection"
            stiffness = (
                _text(row.stiffness, what)
                if isinstance(row.stiffness, str)
                else _num(row.stiffness, what)
            )
            direction = _vec(row.direction, 3, f"{what} direction")
            cells = [_int(row.line.id, what), _end_letter(row.end), stiffness, *direction]
            if row.torsion_stiffness is not None:
                cells.append(
                    _text(row.torsion_stiffness, what)
                    if isinstance(row.torsion_stiffness, str)
                    else _num(row.torsion_stiffness, what)
                )
                cells.extend(_vec(row.normal, 3, f"{what} normal"))
                if row.pretwist is not None:
                    cells.append(_num(row.pretwist, f"{what} pretwist"))
            rows.append(cells)
        if any(row.torsion_stiffness is not None for row in self._end_connections):
            header = "LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist"
            units = "(-) (-) (N-m/rad) (-) (-) (-) (N-m/rad) (-) (-) (-) (deg)"
            return header, units, rows
        header = "LineID End Stiffness EzX EzY EzZ"
        return header, "(-) (-) (N-m/rad) (-) (-) (-)", rows

    def _equivalent_table(self) -> tuple[str, str, list[list[str]]]:
        rows = [
            [
                _text(row.line_type.name, "equivalent buoyancy"),
                _num(row.diam, "equivalent buoyancy"),
                _num(row.submerged_weight, "equivalent buoyancy"),
            ]
            for row in self._equivalent_buoyancy
        ]
        return "LineType Diam SubmergedWeightNpm", "(-) (m) (N/m)", rows

    def _attachment_table(self) -> tuple[str, str, list[list[str]]]:
        rows: list[list[str]] = []
        for row in self._attachments:
            what = f"line {row.line.id} attachment"
            if isinstance(row.arc_length, (tuple, list)):
                arc = ":".join(_vec(row.arc_length, 3, f"{what} arc-length series"))
            else:
                arc = _num(row.arc_length, what)
            values = (row.mass, row.volume, row.cda, row.ca)
            cells = [_int(row.line.id, what), arc, *(_num(value, what) for value in values)]
            if row.cdax is not None:
                cells.append(_num(row.cdax, what))
            rows.append(cells)
        header = "LineID ArcLength Mass Volume CdA Ca CdAx"
        return header, "(-) (m) (kg) (m^3) (m^2) (-) (m^2)", rows

    def _stiffener_table(self) -> tuple[str, str, list[list[str]]]:
        rows: list[list[str]] = []
        for row in self._stiffeners:
            what = f"line {row.line.id} stiffener"
            values = (row.length, row.root_od, row.tip_od, row.inner_d, row.modulus, row.density)
            cells = [_int(row.line.id, what), _end_letter(row.end)]
            rows.append([*cells, *(_num(value, what) for value in values)])
        header = "LineID End Length RootOD TipOD InnerD E Density"
        return header, "(-) (-) (m) (m) (m) (m) (Pa) (kg/m^3)", rows

    def _syrope_table(self) -> tuple[str, str, list[list[str]]]:
        rows = [
            [_line_list(row.lines), _num(row.tmax0, "SYROPE IC"), _num(row.tmean0, "SYROPE IC")]
            for row in self._syrope_ic
        ]
        return "Line(s) Tmax0 Tmean0", "(-) (N) (N)", rows

    def _failure_table(self) -> tuple[str, str, list[list[str]]]:
        rows = [
            [
                str(number),
                f"P{_int(row.point.id, 'failure point')}",
                _line_list(row.lines),
                _num(row.fail_time, "FAILURE"),
                _num(row.fail_tension, "FAILURE"),
            ]
            for number, row in enumerate(self._failures, start=1)
        ]
        return "FailID Point Line(s) FailTime FailTen", "(-) (-) (-) (s) (N)", rows

    def _control_table(self) -> tuple[str, str, list[list[str]]]:
        rows = [
            [_int(row.channel, "CONTROL channel"), _line_list(row.lines)] for row in self._controls
        ]
        return "ChannelID Line(s)", "(-) (-)", rows

    def _external_load_table(self) -> tuple[str, str, list[list[str]]]:
        rows: list[list[str]] = []
        for row in self._external_loads:
            what = f"external load {row.id}"
            rows.append(
                [
                    _int(row.id, what),
                    f"Body{_int(row.body.id, what)}",
                    _text(row.csys, what, quote=False),
                    _multi(row.force, what),
                    _multi(row.blin, what),
                    _multi(row.bquad, what),
                ]
            )
        header = "ID Object CSys Force Blin Bquad"
        return header, "(-) (-) (-) (N) (N-s/m) (N-s^2/m^2)", rows

    def __repr__(self) -> str:
        counts = (
            f"{len(self._line_types)} line types, {len(self._points)} points, "
            f"{len(self._lines)} lines, {len(self._bodies)} bodies, {len(self._rods)} rods"
        )
        return f"<DeckModel {self.title!r}: {counts}>"


def _describe(obj: object) -> str:
    if isinstance(obj, str):
        return f"output channel {obj!r}"
    if isinstance(obj, Option):
        return f"OPTION {obj.keyword}"
    name = getattr(obj, "name", None)
    if isinstance(name, str):
        return f"{type(obj).__name__} {name!r}"
    object_id = getattr(obj, "id", None)
    if isinstance(object_id, int):
        return f"{type(obj).__name__} {object_id}"
    return type(obj).__name__


def _heading(name: str) -> str:
    return f"--------------------- {name} ".ljust(len(_BANNER), "-")


def _emit(out: list[str], name: str, header: str, units: str, rows: list[list[str]]) -> None:
    if rows:
        out.append(_heading(name))
        out.extend(_table(header, units, rows))


def _end_token(end: LineEnd) -> str:
    if isinstance(end, RodEnd):
        return end.token
    return _int(end.id, "line end point id")


def _line_list(lines: Sequence[Line]) -> str:
    if not lines:
        raise ValueError("a row needs at least one line")
    return ",".join(_int(line.id, "line id") for line in lines)


def _option_row(row: Option) -> str:
    values = [_render(value) for value in row.values]
    keyword = _text(row.keyword, "option keyword", quote=False)
    if row.keyword.lower() == "dynamic_solver":
        text = " ".join([keyword, *values])
    else:
        text = " ".join([*values, keyword])
    if row.description:
        text += f" - {_check_free_text(row.description, 'option description')}"
    return text


def _deck_title(deck: DeckFile) -> str:
    """Return the free-text title after the ``Input File`` banner, if any."""
    records, _ = _split_records(deck.text())
    banner_seen = False
    for record in records:
        visible = _strip_inline_comment(record).strip()
        if "---" in visible:
            if banner_seen or "INPUT FILE" not in visible.upper():
                break
            banner_seen = True
            continue
        if banner_seen and visible:
            return visible
    return "CableDyn deck"


class _Loader:
    """Fill a model from the rows of a validated :class:`DeckFile`."""

    def __init__(self, model: DeckModel, deck: DeckFile) -> None:
        self.model = model
        self.deck = deck

    def rows(self, section: str) -> tuple[DeckRecord, ...]:
        return self.deck._rows(section)

    def load(self) -> None:
        model = self.model
        for row in self.deck.line_types:
            self.line_type(row)
        for row in self.rows("ROD TYPES"):
            t = row.tokens
            ax = (_f(t[7]), _f(t[8])) if len(t) == 9 else (None, None)
            model.add_rod_type(
                t[0],
                diam=_f(t[1]),
                mass=_f(t[2]),
                cd=_f(t[3]),
                ca=_f(t[4]),
                cd_end=_f(t[5]),
                ca_end=_f(t[6]),
                cd_ax=ax[0],
                ca_ax=ax[1],
            )
        for row in self.rows("BODIES"):
            self.body(row)
        for row in self.rows("RODS"):
            t = row.tokens
            model.add_rod(
                _native_int(t[0]),
                t[1],
                t[2],
                _f3(t[3:6]),
                _f3(t[6:9]),
                _native_int(t[9]),
                outputs=t[10] if len(t) == 11 else "-",
            )
        for row in self.rows("TURBINES"):
            t = row.tokens
            ptfm = [_f(token) for token in t[4:]] if len(t) == 10 else None
            model.add_turbine(_native_int(t[0]), _f(t[1]), _f(t[2]), _f(t[3]), ptfm=ptfm)
        for row in self.deck.points:
            t = row.tokens
            loads = [_f(token) for token in t[5:9]] if len(t) == 9 else [0.0] * 4
            model.add_point(
                _native_int(t[0]),
                t[1],
                _f(t[2]),
                _f(t[3]),
                _f(t[4]),
                mass=loads[0],
                volume=loads[1],
                cda=loads[2],
                ca=loads[3],
            )
        self.lines()
        for row in self.deck.end_connections:
            t = row.tokens
            # Pinned/Free/Zero and Rigid/Infinity/Inf are keywords, not numbers
            stiffness: float | str = t[2] if t[2].lower() in _END_CONNECTION_KEYWORDS else _f(t[2])
            if len(t) >= 10:
                torsion: float | str = t[6] if t[6].lower() in _TORSION_KEYWORDS else _f(t[6])
                model.add_end_connection(
                    _native_int(t[0]),
                    t[1],
                    stiffness,
                    _f3(t[3:6]),
                    torsion_stiffness=torsion,
                    normal=_f3(t[7:10]),
                    pretwist=_f(t[10]) if len(t) == 11 else None,
                )
            else:
                model.add_end_connection(_native_int(t[0]), t[1], stiffness, _f3(t[3:6]))
        for row in self.rows("EQUIVALENT BUOYANCY"):
            t = row.tokens
            model.add_equivalent_buoyancy(t[0], _f(t[1]), _f(t[2]))
        for row in self.rows("STIFFENERS"):
            t = row.tokens
            model.add_stiffener(_native_int(t[0]), t[1][-1], *(_f(token) for token in t[2:8]))
        for row in self.rows("ATTACHMENTS"):
            t = row.tokens
            arc: float | tuple[float, float, float]
            parts = t[1].split(":")
            arc = _f3(parts) if len(parts) == 3 else _f(parts[0])
            model.add_attachment(
                _native_int(t[0]),
                arc,
                mass=_f(t[2]),
                volume=_f(t[3]),
                cda=_f(t[4]),
                ca=_f(t[5]),
                cdax=_f(t[6]) if len(t) == 7 else None,
            )
        for row in self.rows("SYROPE IC"):
            t = row.tokens
            model.add_syrope_ic(_ids("".join(t[:-2])), _f(t[-2]), _f(t[-1]))
        for row in self.rows("FAILURE"):
            t = row.tokens
            point = t[1][1:] if t[1][:1].lower() == "p" else t[1]
            model.add_failure(
                _native_int(point), _ids(t[2]), fail_time=_f(t[3]), fail_tension=_f(t[4])
            )
        for row in self.rows("CONTROL"):
            model.add_control(_native_int(row.tokens[0]), _ids(row.tokens[1]))
        for row in self.rows("EXTERNAL LOADS"):
            t = row.tokens
            # CableDyn order ID Object CSys Force Blin Bquad, or MoorDyn-F order
            # ID Object Force Blin Bquad CSys (written back in CableDyn order)
            csys, values = (t[2], t[3:6]) if _is_csys_token(t[2]) else (t[5], t[2:5])
            model.add_external_load(
                _native_int(t[0]),
                _body_point_id(t[1].lower()),
                csys=csys,
                force=_fmulti(values[0]),
                blin=_fmulti(values[1]),
                bquad=_fmulti(values[2]),
            )
        for record in self.deck.options:
            description = " ".join(filter(None, (" ".join(record.trailing), record.description)))
            model.options._rows.append(
                Option(record.keyword, tuple(record.values), description or None)
            )
        model.outputs._names.extend(self.deck.outputs)

    def line_type(self, row: DeckRecord) -> None:
        names = self.deck._line_type_fields(row)
        values = dict(zip(names, row.tokens, strict=False))
        if "cd" in values:
            # stock MoorDyn order: Cd Ca CdAx CaAx
            values.update(cdn=values["cd"], can=values["ca"], cdt=values["cdax"])
            values["cat"] = values["caax"]
        ea_token = values["ea"]
        ea: float | tuple[float, ...] | SyropeEA
        if ea_token.lower().startswith("syrope:"):
            settings, alpha, beta = ea_token[len("SYROPE:") :].split("|")
            ea = SyropeEA(settings, _f(alpha), _f(beta))
        else:
            ea = _fmulti(ea_token)
        wide = "gas" in values
        self.model.add_line_type(
            values["name"],
            diam=_f(values["diam"]),
            mass=_f(values["mass"]),
            ea=ea,
            ba=_fmulti(values["ba"]),
            ei=_f(values["ei"]),
            cdn=_f(values["cdn"]),
            cdt=_f(values["cdt"]),
            can=_f(values["can"]),
            cat=_f(values["cat"]),
            gas=_f(values["gas"]) if wide else None,
            gj=_fmulti(values["gj"]) if wide else None,
            irt=_f(values["irt"]) if wide else None,
            irn=_f(values["irn"]) if wide else None,
            cl=_f(values["cl"]) if "cl" in values else None,
            df=_f(values["df"]) if "df" in values else None,
            cf=_f(values["cf"]) if "cf" in values else None,
        )

    def body(self, row: DeckRecord) -> None:
        t = row.tokens
        pose = [_f(token) for token in t[2:8]]
        common = {"roll": pose[3], "pitch": pose[4], "yaw": pose[5]}
        if len(t) == 14:
            self.model.add_moordyn_body(
                _native_int(t[0]),
                t[1],
                pose[0],
                pose[1],
                pose[2],
                mass=_f(t[8]),
                cg=_fmulti(t[9]),
                inertia=_fmulti(t[10]),
                volume=_f(t[11]),
                cda=_fmulti(t[12]),
                ca=_fmulti(t[13]),
                **common,
            )
            return
        values = [_f(token) for token in t[8:]]
        self.model.add_body(
            _native_int(t[0]),
            t[1],
            pose[0],
            pose[1],
            pose[2],
            mass=values[0],
            volume=values[1],
            c33=values[2],
            c44=values[3],
            c55=values[4],
            cda=values[5],
            ca=values[6],
            inertia=(values[7], values[8], values[9]) if len(values) == 10 else None,
            **common,
        )

    def lines(self) -> None:
        model = self.model
        stock: dict[int, DeckRecord] = {}
        for row in self.deck.lines:
            t = row.tokens
            line_id = _native_int(t[0])
            if len(t) == 7:
                stock[line_id] = row
                model.add_line(line_id, _end(t[2]), _end(t[3]), outputs=t[6], stock_row=True)
            else:
                outputs = t[3] if len(t) == 4 else "-"
                model.add_line(line_id, _end(t[1]), _end(t[2]), outputs=outputs)
        explicit = [(row.index, row) for row in self.deck.sections]
        ordered = sorted([*explicit, *((row.index, row) for row in stock.values())])
        for _, row in ordered:
            t = row.tokens
            if len(t) == 7:
                model.add_section(_native_int(t[0]), t[1], _f(t[4]), _native_int(t[5]))
            else:
                model.add_section(_native_int(t[0]), t[1], _f(t[2]), _native_int(t[3]))


def _end(token: str) -> int | str:
    """A LINES attachment token: a point id, or a rod-end token kept as text."""
    return token if _rod_end_token(token) is not None else _native_int(token)
