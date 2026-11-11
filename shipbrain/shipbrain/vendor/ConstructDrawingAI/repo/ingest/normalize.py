"""Coordinate normalization to the CIR's normalized sheet frame.

CAD (DXF) and IFC use a Y-up coordinate system with arbitrary extents; PDFs use a
Y-down page frame in points. Both are mapped into the CIR convention — origin
top-left, x→right, y→down, fractions of the sheet extent — by a :class:`Normalizer`
built from the source bounds. Normalization is per-axis (``x/width``, ``y/height``),
matching the CIR's "fractions of the sheet extent" definition; the true source extents
are recorded in the document metadata so exact coordinates can be recovered.
"""

from __future__ import annotations

import math
from collections.abc import Iterable
from dataclasses import dataclass

from cir import BBox, Point


@dataclass
class Bounds:
    """An accumulating axis-aligned bounding box in source coordinates."""

    x_min: float = math.inf
    y_min: float = math.inf
    x_max: float = -math.inf
    y_max: float = -math.inf

    def update(self, x: float, y: float) -> None:
        self.x_min = min(self.x_min, x)
        self.y_min = min(self.y_min, y)
        self.x_max = max(self.x_max, x)
        self.y_max = max(self.y_max, y)

    def update_many(self, points: Iterable[tuple[float, float]]) -> None:
        for x, y in points:
            self.update(x, y)

    @property
    def width(self) -> float:
        return self.x_max - self.x_min

    @property
    def height(self) -> float:
        return self.y_max - self.y_min

    @property
    def is_valid(self) -> bool:
        return (
            self.x_max >= self.x_min
            and self.y_max >= self.y_min
            and (self.width > 0 or self.height > 0)
        )

    def as_dict(self) -> dict[str, float]:
        return {"x_min": self.x_min, "y_min": self.y_min, "x_max": self.x_max, "y_max": self.y_max}


class Normalizer:
    """Maps source coordinates into normalized [0, 1] sheet coordinates."""

    def __init__(self, bounds: Bounds, *, flip_y: bool) -> None:
        self.bounds = bounds
        self.flip_y = flip_y
        # Guard degenerate extents so we never divide by zero.
        self._w = bounds.width if bounds.width > 1e-9 else 1.0
        self._h = bounds.height if bounds.height > 1e-9 else 1.0

    def point(self, x: float, y: float) -> Point:
        nx = (x - self.bounds.x_min) / self._w
        ny = (self.bounds.y_max - y) / self._h if self.flip_y else (y - self.bounds.y_min) / self._h
        return Point(x=nx, y=ny)

    def points(self, coords: Iterable[tuple[float, float]]) -> list[Point]:
        return [self.point(x, y) for x, y in coords]

    def bbox(self, x0: float, y0: float, x1: float, y1: float) -> BBox:
        p0 = self.point(x0, y0)
        p1 = self.point(x1, y1)
        return BBox(
            x_min=min(p0.x, p1.x),
            y_min=min(p0.y, p1.y),
            x_max=max(p0.x, p1.x),
            y_max=max(p0.y, p1.y),
        )
