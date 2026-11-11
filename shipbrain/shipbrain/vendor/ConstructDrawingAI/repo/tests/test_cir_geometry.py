"""Tests for the CIR geometry helpers (BBox math, Geometry constructors/bounds)."""

from __future__ import annotations

import math

from cir import BBox, Geometry, GeometryType, Point


def test_bbox_dimensions_and_center() -> None:
    box = BBox(x_min=0.0, y_min=0.0, x_max=0.4, y_max=0.2)
    assert math.isclose(box.width, 0.4)
    assert math.isclose(box.height, 0.2)
    assert math.isclose(box.area, 0.08)
    assert box.center == Point(x=0.2, y=0.1)


def test_bbox_iou_identical_is_one() -> None:
    box = BBox(x_min=0.0, y_min=0.0, x_max=1.0, y_max=1.0)
    assert math.isclose(box.iou(box), 1.0)


def test_bbox_iou_disjoint_is_zero() -> None:
    a = BBox(x_min=0.0, y_min=0.0, x_max=0.1, y_max=0.1)
    b = BBox(x_min=0.5, y_min=0.5, x_max=0.6, y_max=0.6)
    assert a.iou(b) == 0.0


def test_bbox_iou_partial_overlap() -> None:
    a = BBox(x_min=0.0, y_min=0.0, x_max=2.0, y_max=2.0)
    b = BBox(x_min=1.0, y_min=1.0, x_max=3.0, y_max=3.0)
    # intersection = 1, union = 4 + 4 - 1 = 7
    assert math.isclose(a.iou(b), 1.0 / 7.0)


def test_bbox_contains_point() -> None:
    box = BBox(x_min=0.0, y_min=0.0, x_max=1.0, y_max=1.0)
    assert box.contains_point(Point(x=0.5, y=0.5))
    assert not box.contains_point(Point(x=1.5, y=0.5))


def test_geometry_box_bounds() -> None:
    geom = Geometry.box(0.1, 0.2, 0.3, 0.5)
    assert geom.type is GeometryType.BBOX
    bounds = geom.bounds()
    assert bounds == BBox(x_min=0.1, y_min=0.2, x_max=0.3, y_max=0.5)


def test_geometry_circle_bounds() -> None:
    geom = Geometry.circle(0.5, 0.5, 0.1)
    bounds = geom.bounds()
    assert bounds is not None
    assert math.isclose(bounds.x_min, 0.4)
    assert math.isclose(bounds.x_max, 0.6)


def test_geometry_polygon_bounds() -> None:
    geom = Geometry.polygon([(0.0, 0.0), (0.5, 0.0), (0.5, 0.5), (0.0, 0.5)])
    assert len(geom.points) == 4
    assert geom.bounds() == BBox(x_min=0.0, y_min=0.0, x_max=0.5, y_max=0.5)


def test_empty_geometry_bounds_is_none() -> None:
    assert Geometry(type=GeometryType.POLYLINE).bounds() is None
