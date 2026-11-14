"""Geometry and SVG parsing helpers for DiagramView/DiagramScene."""

from __future__ import annotations

import math
import re
import xml.etree.ElementTree as ET

from PySide6.QtCore import QPointF
from PySide6.QtGui import QPainterPath, QTransform

_SKIP_CLASSES: frozenset[str] = frozenset(
    {
        "pipeflowarrow",
        "pipeslopesymbol",
        "pipingnetworksegmentlabel",
        "pipingnetworksystemlabel",
        "valvelabel",
        "safetyvalveorfittinglabel",
        "label",
        "equipmentbarlabel",
        "equipmenttagnamelabel",
        "nozzlestandardlabel",
        "processinstrumentationfunctionlabel",
        "failactionlabel",
        "insulationlabel",
        "insulationsymbol",
        "actuating",
        "systemnumberlabel",
    }
)

_STROKE_SCALE = 8.0
_STROKE_WIDTH_ATTR_RE = re.compile(r'stroke-width="([0-9.eE+\-]+)"')
_STROKE_WIDTH_STYLE_RE = re.compile(r"(stroke-width\s*:\s*)([0-9.eE+\-]+)")


def scale_svg_strokes(svg_bytes: bytes) -> bytes:
    """Return SVG bytes with scaled stroke widths for screen visibility."""
    svg_str = svg_bytes.decode("utf-8")

    def _scale_attr(m: re.Match) -> str:  # type: ignore[type-arg]
        return f'stroke-width="{float(m.group(1)) * _STROKE_SCALE}"'

    def _scale_style(m: re.Match) -> str:  # type: ignore[type-arg]
        return f"{m.group(1)}{float(m.group(2)) * _STROKE_SCALE}"

    svg_str = _STROKE_WIDTH_ATTR_RE.sub(_scale_attr, svg_str)
    svg_str = _STROKE_WIDTH_STYLE_RE.sub(_scale_style, svg_str)
    return svg_str.encode("utf-8")


def identity_matrix() -> tuple[float, float, float, float, float, float]:
    return (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)


def matrix_mul(
    m1: tuple[float, float, float, float, float, float],
    m2: tuple[float, float, float, float, float, float],
) -> tuple[float, float, float, float, float, float]:
    """Compose two 2-D affine matrices: result = m1 * m2."""
    a1, b1, c1, d1, e1, f1 = m1
    a2, b2, c2, d2, e2, f2 = m2
    return (
        a1 * a2 + c1 * b2,
        b1 * a2 + d1 * b2,
        a1 * c2 + c1 * d2,
        b1 * c2 + d1 * d2,
        a1 * e2 + c1 * f2 + e1,
        b1 * e2 + d1 * f2 + f1,
    )


def parse_transform_matrix(
    transform_str: str,
) -> tuple[float, float, float, float, float, float]:
    """Parse an SVG transform attribute into a single affine matrix."""
    m = identity_matrix()
    for match in re.finditer(r"(translate|scale|rotate|matrix)\(([^)]+)\)", transform_str):
        func = match.group(1)
        nums = [float(v) for v in re.split(r"[\s,]+", match.group(2).strip()) if v]
        if func == "translate":
            tx = nums[0] if len(nums) > 0 else 0.0
            ty = nums[1] if len(nums) > 1 else 0.0
            t: tuple[float, float, float, float, float, float] = (1.0, 0.0, 0.0, 1.0, tx, ty)
        elif func == "scale":
            sx = nums[0] if len(nums) > 0 else 1.0
            sy = nums[1] if len(nums) > 1 else sx
            t = (sx, 0.0, 0.0, sy, 0.0, 0.0)
        elif func == "rotate":
            angle_rad = math.radians(nums[0]) if nums else 0.0
            cos_a = math.cos(angle_rad)
            sin_a = math.sin(angle_rad)
            if len(nums) == 3:
                cx, cy = nums[1], nums[2]
                t = (
                    cos_a,
                    sin_a,
                    -sin_a,
                    cos_a,
                    cx - cx * cos_a + cy * sin_a,
                    cy - cx * sin_a - cy * cos_a,
                )
            else:
                t = (cos_a, sin_a, -sin_a, cos_a, 0.0, 0.0)
        elif func == "matrix" and len(nums) == 6:
            t = (nums[0], nums[1], nums[2], nums[3], nums[4], nums[5])
        else:
            continue
        m = matrix_mul(m, t)
    return m


def apply_matrix(
    m: tuple[float, float, float, float, float, float], x: float, y: float
) -> tuple[float, float]:
    a, b, c, d, e, f = m
    return a * x + c * y + e, b * x + d * y + f


def polyline_to_path(
    points_str: str,
    matrix: tuple[float, float, float, float, float, float] | None = None,
) -> QPainterPath | None:
    """Parse an SVG points string into world-space QPainterPath."""
    try:
        coords = [float(v) for v in points_str.replace(",", " ").split()]
    except ValueError:
        return None
    if len(coords) < 4:
        return None
    if matrix is None:
        matrix = identity_matrix()
    path = QPainterPath()
    x0, y0 = apply_matrix(matrix, coords[0], coords[1])
    path.moveTo(x0, y0)
    for i in range(2, len(coords) - 1, 2):
        xi, yi = apply_matrix(matrix, coords[i], coords[i + 1])
        path.lineTo(xi, yi)
    return path


def walk_group(
    elem: ET.Element,
    parent_matrix: tuple[float, float, float, float, float, float],
    out: list[QPainterPath],
    skip_element_ids: set[str] | None = None,
) -> None:
    """Recursively walk element tree collecting transformed geometry paths."""
    if not isinstance(getattr(elem, "tag", None), str):
        return

    tag = elem.tag.split("}")[-1]
    cls = elem.get("class", "")
    if set(cls.split()) & _SKIP_CLASSES:
        return

    elem_id = elem.get("id", "")
    if skip_element_ids is not None and elem_id and elem_id in skip_element_ids:
        return

    tf_str = elem.get("transform", "")
    if tf_str:
        matrix = matrix_mul(parent_matrix, parse_transform_matrix(tf_str))
    else:
        matrix = parent_matrix

    if tag == "polyline":
        path = polyline_to_path(elem.get("points", ""), matrix)
        if path is not None:
            out.append(path)
        return

    if tag == "line":
        try:
            x1, y1 = apply_matrix(matrix, float(elem.get("x1", "0")), float(elem.get("y1", "0")))
            x2, y2 = apply_matrix(matrix, float(elem.get("x2", "0")), float(elem.get("y2", "0")))
            p = QPainterPath()
            p.moveTo(x1, y1)
            p.lineTo(x2, y2)
            out.append(p)
        except ValueError:
            pass
        return

    if tag in ("ellipse", "circle"):
        try:
            cx = float(elem.get("cx", "0"))
            cy = float(elem.get("cy", "0"))
            if tag == "circle":
                rx = ry = float(elem.get("r", "0"))
            else:
                rx = float(elem.get("rx", elem.get("r", "0")))
                ry = float(elem.get("ry", elem.get("r", "0")))
            if rx > 0 or ry > 0:
                p = QPainterPath()
                p.addEllipse(QPointF(cx, cy), rx, ry)
                a, b, c, d, e, f = matrix
                out.append(QTransform(a, b, c, d, e, f).map(p))
        except ValueError:
            pass
        return

    if tag == "rect":
        try:
            rx_ = float(elem.get("x", "0"))
            ry_ = float(elem.get("y", "0"))
            rw = float(elem.get("width", "0"))
            rh = float(elem.get("height", "0"))
            if rw > 0 or rh > 0:
                corners = [(rx_, ry_), (rx_ + rw, ry_), (rx_ + rw, ry_ + rh), (rx_, ry_ + rh)]
                p = QPainterPath()
                wx0, wy0 = apply_matrix(matrix, corners[0][0], corners[0][1])
                p.moveTo(wx0, wy0)
                for cx_, cy_ in corners[1:]:
                    wx, wy = apply_matrix(matrix, cx_, cy_)
                    p.lineTo(wx, wy)
                p.closeSubpath()
                out.append(p)
        except ValueError:
            pass
        return

    for child in elem:
        walk_group(child, matrix, out, skip_element_ids)


def extract_paths_from_group(
    group: ET.Element,
    init_matrix: tuple[float, float, float, float, float, float] | None = None,
    skip_element_ids: set[str] | None = None,
) -> list[QPainterPath]:
    """Convert polyline/line descendants into world-space QPainterPaths."""
    paths: list[QPainterPath] = []
    walk_group(
        group,
        init_matrix if init_matrix is not None else identity_matrix(),
        paths,
        skip_element_ids,
    )
    return paths


def compute_ancestor_transforms(
    root: ET.Element,
    target_ids: set[str],
) -> dict[str, tuple[float, float, float, float, float, float]]:
    """Return accumulated ancestor transform matrix for each target ID."""
    result: dict[str, tuple[float, float, float, float, float, float]] = {}

    def _walk(
        elem: ET.Element,
        parent_m: tuple[float, float, float, float, float, float],
    ) -> None:
        if not isinstance(getattr(elem, "tag", None), str):
            return
        tf_str = elem.get("transform", "")
        current_m = matrix_mul(parent_m, parse_transform_matrix(tf_str)) if tf_str else parent_m
        eid = elem.get("id", "")
        if eid in target_ids:
            result[eid] = parent_m
        for child in elem:
            _walk(child, current_m)

    _walk(root, identity_matrix())
    return result


# Backward-compatible aliases while migrating modules.
_scale_svg_strokes = scale_svg_strokes
_identity_matrix = identity_matrix
_matrix_mul = matrix_mul
_parse_transform_matrix = parse_transform_matrix
_apply_matrix = apply_matrix
_polyline_to_path = polyline_to_path
_walk_group = walk_group
_extract_paths_from_group = extract_paths_from_group
_compute_ancestor_transforms = compute_ancestor_transforms
