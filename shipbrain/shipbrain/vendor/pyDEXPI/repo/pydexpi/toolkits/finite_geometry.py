"""Geometry that cannot be computed from a number that is not finite.

A DEXPI ``Double`` is an ``xsd:double``, so a drawing a document gives may hold a NaN or an
infinity: in a ``ShapeUsage.rotation``, a coordinate, a semi-axis. pyDEXPI keeps it. What the
geometry code makes of it used to depend on the function and on the number. ``math.cos`` raises
``ValueError`` for an infinity and returns NaN for a NaN; ``round`` raises ``OverflowError`` for
the one and ``ValueError`` for the other; ``min`` and ``max`` keep or drop a NaN by its place in
the list, so a box built from one was sometimes NaN and sometimes a finite box of the points
that happened to come first. A caller could not tell an extent from a guess.

So the functions that *measure* -- the extents of ``diagram_toolkit``, the placed outline of
``process_drawing`` -- raise one exception for such a number, naming the object and the
attribute that holds it: :class:`NonFiniteGeometryError`. A caller can report exactly which
number of the document it could not measure.

A function that *classifies* does **not** raise, and answers "none": a leg that is no finite
vector has no cardinal axis (``routing.snap_axis``), and a flow arrow or a line holding such a
number is on no line (``flow_arrows``).

This module imports nothing from pyDEXPI, so every toolkit can use it.
"""

from __future__ import annotations

import math
from collections.abc import Iterable
from typing import Any

__all__ = [
    "NonFiniteGeometryError",
    "is_finite_point",
    "require_finite",
    "require_finite_point",
    "require_finite_points",
]


class NonFiniteGeometryError(ArithmeticError):
    """Raised when geometry would have to be computed from a NaN or an infinity a model holds.

    An ``ArithmeticError``, and deliberately not a ``ValueError``: a caller that turns a
    toolkit's ``ValueError`` into a message in the toolkit's words would lose what this one
    carries.

    Attributes
    ----------
    obj : object
        The object that holds the number: a ``ShapeUsage``, a ``NodePosition``, a primitive.
    attribute : str
        The attribute, as a path where the number sits inside a value: ``"rotation"``,
        ``"position.x"``, ``"points[2].y"``.
    value : float
        The number.
    """

    def __init__(self, obj: Any, attribute: str, value: float) -> None:
        self.obj = obj
        self.attribute = attribute
        self.value = value
        identifier = getattr(obj, "id", None)
        named = f"{type(obj).__name__} {identifier!r}" if identifier else type(obj).__name__
        super().__init__(
            f"{named}.{attribute} is {value!r}: no geometry can be computed from a number that "
            "is not finite."
        )


def require_finite(obj: Any, attribute: str, value: float | None) -> float:
    """Return *value* (0.0 for None), or raise naming *obj* and *attribute* if it is not finite.

    Parameters
    ----------
    obj : object
        The object the number is read from.
    attribute : str
        The attribute holding it, for the error.
    value : float | None
        The number; an unset attribute reads as 0.0, as the geometry code reads one.

    Raises
    ------
    NonFiniteGeometryError
        If *value* is a NaN or an infinity.
    """
    if value is None:
        return 0.0
    if not math.isfinite(value):
        raise NonFiniteGeometryError(obj, attribute, value)
    return value


def is_finite_point(point: Any) -> bool:
    """Whether a point -- a ``Point``, or an ``(x, y)`` pair -- holds two finite numbers."""
    if isinstance(point, tuple):
        return math.isfinite(point[0]) and math.isfinite(point[1])
    return math.isfinite(point.x) and math.isfinite(point.y)


def require_finite_point(obj: Any, attribute: str, point: Any) -> tuple[float, float]:
    """Return a ``Point`` as ``(x, y)``, or raise naming the coordinate that is not finite.

    Raises
    ------
    NonFiniteGeometryError
        Naming ``<attribute>.x`` or ``<attribute>.y``.
    """
    if not math.isfinite(point.x):
        raise NonFiniteGeometryError(obj, f"{attribute}.x", point.x)
    if not math.isfinite(point.y):
        raise NonFiniteGeometryError(obj, f"{attribute}.y", point.y)
    return point.x, point.y


def require_finite_points(obj: Any, attribute: str, points: Iterable[Any]) -> None:
    """Raise for the first of a list of ``Point`` s that is not finite, naming its position.

    Raises
    ------
    NonFiniteGeometryError
        Naming ``<attribute>[<index>].x`` or ``.y``.
    """
    for index, point in enumerate(points):
        require_finite_point(obj, f"{attribute}[{index}]", point)
