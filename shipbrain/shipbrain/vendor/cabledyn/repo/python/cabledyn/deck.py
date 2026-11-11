# SPDX-License-Identifier: Apache-2.0
"""Programmatic writer for CableDyn's sectioned ``.dat`` decks.

The deck grammar is the documented CableDyn deck format: MoorDyn v2
vocabulary with sectioned line objects (an explicit SECTIONS table).
This writer builds exactly that file from Python values, round-trip-exact
(floats are written with 17 significant digits so a parse of the written deck
reproduces the passed values bit-for-bit). Every generated deck is checked
with :class:`cabledyn.DeckFile` before it is returned or written, so the writer
never produces text the native reader would reject or misread.
"""

from __future__ import annotations

import math
import operator
import os
import sys
from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path

from cabledyn.deck_file import DeckFile, _is_scalar_option_keyword

_POINT_TYPES = {"fixed", "coupled", "vessel", "free", "connect"}
_END_CONNECTION_ENDS = {
    "a": "A",
    "enda": "A",
    "end_a": "A",
    "b": "B",
    "endb": "B",
    "end_b": "B",
}
_PINNED_CONNECTIONS = {"pinned", "free", "zero"}
_RIGID_CONNECTIONS = {"rigid", "infinity", "inf"}
# Characters that change how the native reader splits or truncates a row:
# comment markers anywhere, and list-directed separators in unquoted tokens.
_COMMENT_MARKERS = ("#", "!")
_LIST_SEPARATORS = ("/", ",", ";", "*")


def _num(x: float) -> str:
    return f"{float(x):.17g}"


def _int(value: object, what: str) -> int:
    """Return an integer argument, rejecting Booleans and non-integral numbers."""
    if isinstance(value, bool):
        raise TypeError(f"{what} must be an integer, got {value!r}")
    try:
        return operator.index(value)  # type: ignore[arg-type]
    except TypeError as exc:
        raise TypeError(f"{what} must be an integer, got {value!r}") from exc


def _check_free_text(text: str, what: str) -> str:
    """Return ``text`` stripped, rejecting content the native reader would misparse.

    ``---`` turns any row into a section header, and ``#``/``!`` start a
    comment that silently truncates the rest of the row.
    """
    if not isinstance(text, str):
        raise TypeError(f"{what} must be a string")
    if "\n" in text or "\r" in text:
        raise ValueError(f"{what} must fit on one row")
    if "---" in text:
        raise ValueError(f"{what} must not contain '---' (it would start a deck section)")
    if any(marker in text for marker in _COMMENT_MARKERS):
        raise ValueError(f"{what} must not contain '#' or '!' (they start a native comment)")
    return text.strip()


def _check_token(text: str, what: str) -> str:
    """Return ``text`` if it is one plain native token, else raise ``ValueError``."""
    if not isinstance(text, str):
        raise TypeError(f"{what} must be a string")
    if not text or any(ch.isspace() for ch in text):
        raise ValueError(f"{what} must be a single non-empty token")
    if '"' in text or "'" in text:
        raise ValueError(f"{what} must not contain quotes")
    if any(marker in text for marker in _COMMENT_MARKERS) or text.startswith("--"):
        raise ValueError(f"{what} must not contain comment markers ('#', '!', leading '--')")
    if any(separator in text for separator in _LIST_SEPARATORS):
        raise ValueError(f"{what} must not contain '/', ',', ';', or '*'")
    return text


@dataclass
class DeckWriter:
    """Accumulates line types, points, lines, sections, and options; writes a deck.

    Free text (``title`` and option descriptions) must not contain ``---``,
    ``#``, or ``!``; names must be single plain tokens. :meth:`text` and
    :meth:`write` validate the complete deck with :class:`cabledyn.DeckFile`
    and raise :class:`cabledyn.DeckFormatError` when it breaks the native
    contract. Numbers are written in a round-trip-exact form, so reading the
    deck back reproduces the passed values exactly.

    Parameters
    ----------
    title : str
        Title line written below the deck's first heading.

    Example
    -------
    >>> deck = DeckWriter(title="three-line chain mooring")
    >>> deck.add_line_type("main", diam=0.333, mass=685.0, ea=3.27e9,
    ...                    ba=-1.0, ei=0.0, cdn=2.0, cdt=0.4, can=0.82, cat=0.27)
    >>> deck.add_point(1, "Vessel", -58.0, 0.0, -14.0)
    >>> deck.add_point(2, "Fixed", -837.6, 0.0, -200.0)
    >>> deck.add_line(1, node_a=1, node_b=2)
    >>> deck.add_section(line_id=1, line_type="main", length=850.0, num_segs=20)
    >>> deck.set_option(9.80665, "g", "Gravitational acceleration (m/s^2)")
    >>> deck.add_output("FairTen1")
    >>> deck.write("mooring.dat")   # doctest: +SKIP
    """

    title: str = "cabledyn deck"
    _types: list[str] = field(default_factory=list)
    _points: list[str] = field(default_factory=list)
    _lines: list[str] = field(default_factory=list)
    _sections: list[str] = field(default_factory=list)
    _end_connections: list[str] = field(default_factory=list)
    _end_connection_keys: set[tuple[int, str]] = field(default_factory=set)
    _options: list[str] = field(default_factory=list)
    _outputs: list[str] = field(default_factory=list)

    def add_line_type(
        self,
        name: str,
        *,
        diam: float,
        mass: float,
        ea: float,
        ba: float = 0.0,
        ei: float = 0.0,
        cdn: float = 0.0,
        cdt: float = 0.0,
        can: float = 0.0,
        cat: float = 0.0,
    ) -> None:
        """One LINE TYPES row (MoorDyn vocabulary: Diam Mass EA BA EI Cdn Cdt Can Cat).

        Parameters
        ----------
        name : str
            Line-type name referenced by :meth:`add_section`.
        diam : float
            Hydrodynamic (volume-equivalent) diameter, in m.
        mass : float
            Mass per unit length, in kg/m.
        ea : float
            Axial stiffness, in N.
        ba : float
            Axial damping, in N s; a negative value is a damping ratio.
        ei : float
            Bending stiffness, in N m^2; zero for a cable without bending stiffness.
        cdn, cdt : float
            Normal and tangential drag coefficients.
        can, cat : float
            Normal and tangential added-mass coefficients.

        Raises
        ------
        TypeError
            If ``name`` is not a string.
        ValueError
            If ``name`` is not a single plain token.
        """
        _check_token(name, "line-type name")
        vals = " ".join(_num(v) for v in (diam, mass, ea, ba, ei, cdn, cdt, can, cat))
        self._types.append(f"{name} {vals}")

    def add_point(self, point_id: int, ptype: str, x: float, y: float, z: float) -> None:
        """One POINTS row. ``ptype`` is Fixed / Coupled / Vessel / Free / Connect.

        Parameters
        ----------
        point_id : int
            Point identifier referenced by :meth:`add_line`.
        ptype : str
            ``"Fixed"``, ``"Coupled"``, ``"Vessel"``, ``"Free"``, or
            ``"Connect"`` (case-insensitive; written as given).
        x, y, z : float
            Point position in the global frame, in metres (``z`` positive up).

        Raises
        ------
        TypeError
            If ``point_id`` is not an integer.
        ValueError
            If ``ptype`` is not a recognized point type.
        """
        if not isinstance(ptype, str) or ptype.lower() not in _POINT_TYPES:
            raise ValueError(
                f"unknown point type {ptype!r}; expected one of {sorted(_POINT_TYPES)}"
            )
        point = _int(point_id, "point_id")
        self._points.append(f"{point} {ptype} {_num(x)} {_num(y)} {_num(z)}")

    def add_line(self, line_id: int, *, node_a: int, node_b: int, outputs: str = "-") -> None:
        """One LINES row: End A (fairlead-side) and End B (anchor-side) point ids.

        Parameters
        ----------
        line_id : int
            Line identifier referenced by :meth:`add_section`.
        node_a : int
            Point identifier of End A (fairlead side).
        node_b : int
            Point identifier of End B (anchor side).
        outputs : str
            Per-line output-file flags: ``-`` for none, ``p`` for node
            positions, ``t`` for segment tensions, ``r`` for the range graph
            (for example ``pt``).

        Raises
        ------
        TypeError
            If ``outputs`` is not a string, or an id is not an integer.
        ValueError
            If ``outputs`` is not a single plain token.
        """
        _check_token(outputs, "line outputs flag")
        ids = [_int(value, name) for value, name in ((line_id, "line_id"), (node_a, "node_a"))]
        ids.append(_int(node_b, "node_b"))
        self._lines.append(f"{ids[0]} {ids[1]} {ids[2]} {outputs}")

    def add_section(self, *, line_id: int, line_type: str, length: float, num_segs: int) -> None:
        """One SECTIONS row (sections compose a line from End A to End B).

        Sections of one line are joined from End A to End B in the order they are
        added.

        Parameters
        ----------
        line_id : int
            Identifier of the line the section belongs to.
        line_type : str
            Line-type name defined with :meth:`add_line_type`.
        length : float
            Unstretched section length, in metres.
        num_segs : int
            Number of segments, at least 1.

        Raises
        ------
        TypeError
            If ``line_type`` is not a string, or ``line_id`` or ``num_segs`` is
            not an integer.
        ValueError
            If ``line_type`` is not a single plain token or ``num_segs`` is less
            than 1.
        """
        _check_token(line_type, "section line type")
        line = _int(line_id, "line_id")
        segments = _int(num_segs, "num_segs")
        if segments < 1:
            raise ValueError("num_segs must be >= 1")
        self._sections.append(f"{line} {line_type} {_num(length)} {segments}")

    def add_end_connection(
        self,
        line_id: int,
        end: str,
        stiffness: float | str,
        direction: Sequence[float],
        *,
        torsion_stiffness: float | str | None = None,
        normal: Sequence[float] | None = None,
        pretwist: float | None = None,
    ) -> None:
        """Add a finite-EI line-end bending connection.

        This writer has no torsion columns (``TorsStiffness NxX NxY NxZ Pretwist``) and
        no ``GJ`` column, so a torsion argument is refused; build a deck with torsion with
        ``cabledyn.builder.DeckModel.add_end_connection``.

        Parameters
        ----------
        line_id : int
            Positive line identifier.
        end : str
            ``"A"`` or ``"B"`` (also ``"EndA"``, ``"end_a"``, and so on;
            case-insensitive).
        stiffness : float | str
            Finite, non-negative rotational stiffness in N m/rad, ``"Pinned"``
            (also ``"Free"``/``"Zero"``), or ``"Rigid"`` (also
            ``"Infinity"``/``"Inf"``).
        direction : tuple[float, float, float] | list[float]
            Three finite components of the non-zero end direction in the global
            frame, following CableDyn's End-A-to-End-B convention; normalized
            before writing.
        torsion_stiffness, normal, pretwist : None
            Not supported by this writer; any other value raises ``ValueError``.

        Raises
        ------
        TypeError
            If ``line_id`` is not an integer.
        ValueError
            If ``line_id`` is not positive, ``end`` is not A or B, that end
            already has a connection, ``stiffness`` is invalid,
            ``direction`` is not three finite components with a non-zero norm,
            or a torsion argument is given.
        """
        if torsion_stiffness is not None or normal is not None or pretwist is not None:
            raise ValueError(
                "the simple deck writer has no torsion columns or GJ; build a deck with torsion "
                "with cabledyn.builder.DeckModel (add_end_connection(..., torsion_stiffness=..., "
                "normal=..., pretwist=...))"
            )
        key_id = _int(line_id, "line_id")
        if key_id < 1:
            raise ValueError("line_id must be positive")
        try:
            canonical_end = _END_CONNECTION_ENDS[str(end).lower()]
        except KeyError as exc:
            raise ValueError("end must be A or B") from exc
        key = (key_id, canonical_end)
        if key in self._end_connection_keys:
            raise ValueError(f"line {key_id} End {canonical_end} already has a connection")

        if isinstance(stiffness, bool):
            raise ValueError("stiffness must be non-negative, Pinned, or Rigid")
        stiffness_token: str
        if isinstance(stiffness, str) and stiffness.lower() in _PINNED_CONNECTIONS:
            stiffness_token = "Pinned"
        elif isinstance(stiffness, str) and stiffness.lower() in _RIGID_CONNECTIONS:
            stiffness_token = "Rigid"
        else:
            try:
                stiffness_value = float(stiffness)
            except (TypeError, ValueError) as exc:
                raise ValueError("stiffness must be non-negative, Pinned, or Rigid") from exc
            if not math.isfinite(stiffness_value) or stiffness_value < 0.0:
                raise ValueError("stiffness must be finite and non-negative")
            stiffness_token = _num(stiffness_value)

        if isinstance(direction, (str, bytes)):
            raise ValueError("direction must contain exactly three numeric components")
        try:
            components = tuple(float(value) for value in direction)
        except (TypeError, ValueError) as exc:
            raise ValueError("direction must contain exactly three numeric components") from exc
        if len(components) != 3:
            raise ValueError("direction must contain exactly three numeric components")
        if not all(math.isfinite(value) for value in components):
            raise ValueError("direction components must be finite")
        norm = math.sqrt(sum(value * value for value in components))
        if not math.isfinite(norm) or norm <= math.sqrt(sys.float_info.min):
            raise ValueError("direction must be non-zero")
        normalized = " ".join(_num(value / norm) for value in components)
        self._end_connections.append(f"{key_id} {canonical_end} {stiffness_token} {normalized}")
        self._end_connection_keys.add(key)

    def set_option(
        self, value: str | float | bool, keyword: str, description: str | None = None
    ) -> None:
        """Add one OPTIONS row, written in the native column order ``value keyword``.

        Checking the keyword means a call with the value and keyword swapped
        raises instead of writing a wrong row.

        Parameters
        ----------
        value : str | float | bool
            Option value in the option's SI unit (for example seconds for
            ``dtM``, metres for ``WtrDpth``). Strings are written verbatim and
            must be one plain token, numbers with ``str`` (shortest exact
            form), and Booleans as ``True``/``False``.
        keyword : str
            Native scalar option keyword (case-insensitive, for example
            ``dtM``, ``TMax``, ``WtrDpth``).
        description : str | None
            Optional one-row note on the option's meaning, units, and choices,
            written after a whitespace-delimited ``-`` separator. It must not
            contain ``---``, ``#``, or ``!``.

        Raises
        ------
        TypeError
            If ``keyword`` is not a string, or ``value`` is not a string,
            number, or Boolean.
        ValueError
            If ``keyword`` is unknown, a string ``value`` is not a plain token,
            or ``description`` holds forbidden text.
        """
        if not isinstance(keyword, str):
            raise TypeError(
                f"option keyword must be a string, got {type(keyword).__name__}; "
                "the argument order is set_option(value, keyword, description)"
            )
        if not _is_scalar_option_keyword(keyword):
            raise ValueError(
                f"unknown option keyword {keyword!r}; the argument order is "
                "set_option(value, keyword, description)"
            )
        if isinstance(value, bool):
            rendered = "True" if value else "False"
        elif isinstance(value, (int, float)):
            rendered = str(value)
        elif isinstance(value, str):
            rendered = _check_token(value, f"option {keyword} value")
        else:
            raise TypeError(f"option {keyword} value must be a string, number, or Boolean")
        row = f"{rendered} {keyword}"
        if description is not None:
            clean_description = _check_free_text(description, "option description")
            if clean_description:
                row += f" - {clean_description}"
        self._options.append(row)

    def add_output(self, channel: str) -> None:
        """Add one output channel; it is rendered as a quoted row in ``OUTPUTS``.

        Parameters
        ----------
        channel : str
            Native output channel name, for example ``"FairTen1"``.

        Raises
        ------
        TypeError
            If ``channel`` is not a string.
        ValueError
            If ``channel`` is not a single plain token.
        """
        _check_token(channel, "output channel")
        self._outputs.append(channel)

    def text(self, *, caller_driven: bool = False) -> str:
        """Return the complete deck text after validating it with :class:`DeckFile`.

        Parameters
        ----------
        caller_driven : bool
            Validate for the OpenFAST coupling (see :class:`DeckFile`) instead of the
            standalone driver.

        Returns
        -------
        str
            The deck text, newline-terminated.

        Raises
        ------
        ValueError
            If the deck lacks a line type, point, line, or section, or the title
            holds forbidden text.
        DeckFormatError
            If the deck breaks the native contract.
        """
        if not self._types or not self._points or not self._lines or not self._sections:
            raise ValueError("a deck needs at least one LINE TYPE, POINT, LINE, and SECTION")
        out: list[str] = [
            "--------------------- CableDyn Input File ------------------------------------",
            _check_free_text(self.title, "title"),
        ]
        out.append("--- LINE TYPES ---")
        out.append("Name Diam Mass EA BA EI Cdn Cdt Can Cat")
        out.append("(-) (m) (kg/m) (N) (N-s) (N-m^2) (-) (-) (-) (-)")
        out.extend(self._types)
        out.append("--- POINTS ---")
        out.append("ID Type X Y Z")
        out.append("(-) (-) (m) (m) (m)")
        out.extend(self._points)
        out.append("--- LINES ---")
        out.append("ID NodeA NodeB Outputs")
        out.append("(-) (-) (-) (-)")
        out.extend(self._lines)
        out.append("--- SECTIONS ---")
        out.append("LineID LineType Length NumSegs")
        out.append("(-) (-) (m) (-)")
        out.extend(self._sections)
        if self._end_connections:
            out.append("--- END CONNECTIONS ---")
            out.append("LineID End Stiffness EzX EzY EzZ")
            out.append("(-) (-) (N-m/rad) (-) (-) (-)")
            out.extend(self._end_connections)
        if self._options:
            out.append("--- OPTIONS ---")
            out.extend(self._options)
        if self._outputs:
            out.append("--- OUTPUTS ---")
            out.extend(f'"{channel}"' for channel in self._outputs)
        out.append("--- need this line ---")
        text = "\n".join(out) + "\n"
        DeckFile.from_text(text, caller_driven=caller_driven, label="<DeckWriter deck>")
        return text

    def write(self, path: str | os.PathLike[str], *, caller_driven: bool = False) -> Path:
        """Validate the deck, write it to ``path``, and return the path.

        An existing file is replaced.

        Parameters
        ----------
        path : str | os.PathLike
            Target file, written as ASCII with LF line endings.
        caller_driven : bool
            Validate for the OpenFAST coupling; see :meth:`text`.

        Returns
        -------
        pathlib.Path
            ``path`` as given, not resolved.

        Raises
        ------
        ValueError
            If the deck is incomplete or holds forbidden text.
        DeckFormatError
            If the deck breaks the native contract.
        """
        p = Path(path)
        p.write_text(self.text(caller_driven=caller_driven), encoding="ascii", newline="\n")
        return p
