"""Geometric primitives for the CIR.

Two coordinate systems coexist, on purpose:

* **Normalized geometry** (:class:`Geometry`, :class:`Point`, :class:`BBox`):
  coordinates as fractions of the *sheet* extent — origin top-left, x→right,
  y→down, nominally in ``[0, 1]``. Resolution-independent, so a detection on a
  300-DPI raster and the same detection on the vector source are directly
  comparable. Values are **not** hard-clamped to ``[0, 1]`` because an entity may
  legitimately extend a hair past a sheet edge.
* **Source coordinates** (:class:`SourceBBox`): the axis-aligned box in the
  *original* file coordinate system — PDF points or raster pixels on a specific
  page — kept so every CIR entity can be traced back to pixel-exact evidence on
  the source document (critical for the human-in-the-loop / liability story).
"""

from __future__ import annotations

from enum import Enum
from typing import Self

from pydantic import BaseModel, ConfigDict, Field


class GeometryType(str, Enum):
    """The shape family a :class:`Geometry` represents."""

    POINT = "point"
    POLYLINE = "polyline"
    POLYGON = "polygon"
    CIRCLE = "circle"
    ARC = "arc"
    BBOX = "bbox"


class _GeoBase(BaseModel):
    """Base for geometry models: forbid unknown fields to catch typos early."""

    model_config = ConfigDict(extra="forbid")


class Point(_GeoBase):
    """A 2-D point in normalized sheet coordinates."""

    x: float
    y: float


class BBox(_GeoBase):
    """An axis-aligned bounding box in normalized sheet coordinates."""

    x_min: float
    y_min: float
    x_max: float
    y_max: float

    @property
    def width(self) -> float:
        """Width (may be negative if min/max are mis-ordered by a caller)."""
        return self.x_max - self.x_min

    @property
    def height(self) -> float:
        """Height (may be negative if min/max are mis-ordered by a caller)."""
        return self.y_max - self.y_min

    @property
    def area(self) -> float:
        """Non-negative area of the box."""
        return max(0.0, self.width) * max(0.0, self.height)

    @property
    def center(self) -> Point:
        """The box center point."""
        return Point(x=(self.x_min + self.x_max) / 2.0, y=(self.y_min + self.y_max) / 2.0)

    def iou(self, other: BBox) -> float:
        """Intersection-over-union with ``other`` (0.0 if they do not overlap).

        Used pervasively by the evaluation harness (detection mAP, PQ).
        """
        ix0 = max(self.x_min, other.x_min)
        iy0 = max(self.y_min, other.y_min)
        ix1 = min(self.x_max, other.x_max)
        iy1 = min(self.y_max, other.y_max)
        inter = max(0.0, ix1 - ix0) * max(0.0, iy1 - iy0)
        union = self.area + other.area - inter
        return inter / union if union > 0.0 else 0.0

    def contains_point(self, point: Point) -> bool:
        """Whether ``point`` lies within (inclusive of) this box."""
        return self.x_min <= point.x <= self.x_max and self.y_min <= point.y <= self.y_max


class Geometry(_GeoBase):
    """A geometric shape in normalized sheet coordinates.

    The meaning of :attr:`points` depends on :attr:`type`:

    * ``POINT``    — exactly 1 point.
    * ``POLYLINE`` — ≥ 2 ordered points (open).
    * ``POLYGON``  — ≥ 3 ordered points (implicitly closed).
    * ``BBOX``     — 2 points: top-left and bottom-right.
    * ``CIRCLE``   — 1 point (center) plus :attr:`radius`.
    * ``ARC``      — 1 point (center) plus :attr:`radius`, :attr:`start_angle`,
      :attr:`end_angle` (degrees).
    """

    type: GeometryType
    points: list[Point] = Field(default_factory=list)
    radius: float | None = None
    start_angle: float | None = None
    end_angle: float | None = None

    def bounds(self) -> BBox | None:
        """Axis-aligned bounds, or ``None`` if there are no points."""
        if not self.points:
            return None
        if self.type in (GeometryType.CIRCLE, GeometryType.ARC) and self.radius is not None:
            c = self.points[0]
            r = abs(self.radius)
            return BBox(x_min=c.x - r, y_min=c.y - r, x_max=c.x + r, y_max=c.y + r)
        xs = [p.x for p in self.points]
        ys = [p.y for p in self.points]
        return BBox(x_min=min(xs), y_min=min(ys), x_max=max(xs), y_max=max(ys))

    # -- ergonomic constructors --------------------------------------------------

    @classmethod
    def point(cls, x: float, y: float) -> Self:
        """A POINT geometry."""
        return cls(type=GeometryType.POINT, points=[Point(x=x, y=y)])

    @classmethod
    def box(cls, x_min: float, y_min: float, x_max: float, y_max: float) -> Self:
        """A BBOX geometry from min/max corners."""
        return cls(
            type=GeometryType.BBOX,
            points=[Point(x=x_min, y=y_min), Point(x=x_max, y=y_max)],
        )

    @classmethod
    def polyline(cls, points: list[tuple[float, float]]) -> Self:
        """An open POLYLINE from ``(x, y)`` tuples."""
        return cls(type=GeometryType.POLYLINE, points=[Point(x=x, y=y) for x, y in points])

    @classmethod
    def polygon(cls, points: list[tuple[float, float]]) -> Self:
        """A closed POLYGON from ``(x, y)`` tuples."""
        return cls(type=GeometryType.POLYGON, points=[Point(x=x, y=y) for x, y in points])

    @classmethod
    def circle(cls, x: float, y: float, radius: float) -> Self:
        """A CIRCLE from a center and radius."""
        return cls(type=GeometryType.CIRCLE, points=[Point(x=x, y=y)], radius=radius)


class SourceBBox(_GeoBase):
    """An axis-aligned bbox in the ORIGINAL source coordinate system.

    Kept alongside normalized :class:`Geometry` so every entity is traceable back
    to exact evidence on the source file (pixel crop / PDF region).
    """

    x_min: float
    y_min: float
    x_max: float
    y_max: float
    unit: str = "px"  # "px" (raster) or "pt" (PDF points)
    page: int | None = None  # 0-based page index in the source file

    @property
    def width(self) -> float:
        """Width in source units."""
        return self.x_max - self.x_min

    @property
    def height(self) -> float:
        """Height in source units."""
        return self.y_max - self.y_min
