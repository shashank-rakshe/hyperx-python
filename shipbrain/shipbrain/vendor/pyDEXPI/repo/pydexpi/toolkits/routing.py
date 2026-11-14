"""Read-only connector geometry: a line's drawn points and the axis a port is left along.

A ``ConnectorLine`` is drawn from its ``source`` position through its ``innerPoints`` to
its ``target`` position (:func:`polyline_of`). A port's facing direction is **not stored
anywhere in DEXPI** -- ``NodePosition`` carries only a ``Point`` -- so it is read off the
drawn leg (:func:`port_axis`, :func:`snap_axis`).
"""

import math
from typing import Literal

from pydexpi.pydexpi_classes.core import diagram
from pydexpi.toolkits.finite_geometry import require_finite_point, require_finite_points

#: A unit axis: exactly one of (1, 0), (-1, 0), (0, 1), (0, -1).
Axis = tuple[int, int]

#: Role of a connector end. "source" is index 0 of the polyline, "target" is -1.
Role = Literal["source", "target"]

#: Relative tolerance for snapping a leg to an axis. A leg counts as axis-aligned
#: when its minor component is within this fraction of its major one, so float
#: noise (the reference drawing has y = 72.640996091) snaps while a real 30 deg
#: run does not. Deliberately relative: absolute tolerances break under scale.
AXIS_SNAP_TOLERANCE = 1e-3

#: Absolute tolerance for "these two points are the same" and for collinearity.
POINT_TOLERANCE = 1e-6


# --------------------------------------------------------------------------- #
# Pure geometry
# --------------------------------------------------------------------------- #


def snap_axis(dx: float, dy: float, *, eps: float = AXIS_SNAP_TOLERANCE) -> Axis | None:
    """The cardinal axis of (dx, dy), or None if it is degenerate or diagonal.

    Never coerces an arbitrary diagonal to whichever cardinal happens to be
    nearest -- a genuinely diagonal run has no port axis to infer, and saying so
    is the whole point.

    None, too, for a leg that is no finite vector. Every comparison with a
    NaN is false, so the tests below fell through to "along x" for one, and an
    infinite leg along both axes was read as pointing along x.
    """
    if not (math.isfinite(dx) and math.isfinite(dy)):
        return None
    major, minor = (abs(dx), abs(dy)) if abs(dx) >= abs(dy) else (abs(dy), abs(dx))
    if major <= POINT_TOLERANCE:
        return None
    if minor > eps * major:
        return None
    if abs(dx) >= abs(dy):
        return (1, 0) if dx > 0 else (-1, 0)
    return (0, 1) if dy > 0 else (0, -1)


def xy(point) -> tuple[float, float]:
    return (point.x, point.y)


def polyline_of(line: diagram.ConnectorLine) -> list[tuple[float, float]]:
    """The drawn point list: source position, inner points, target position.

    Mirrors what SvgRenderer.convert_connector_line draws. Endpoints are omitted
    when unbound, which the Proteus parser produces before its reference pass.
    """
    points: list[tuple[float, float]] = []
    if line.source is not None and line.source.position is not None:
        points.append(xy(line.source.position))
    points.extend(xy(point) for point in line.innerPoints)
    if line.target is not None and line.target.position is not None:
        points.append(xy(line.target.position))
    return points


def measured_polyline(line: diagram.ConnectorLine) -> list[tuple[float, float]]:
    """:func:`polyline_of` for a caller that measures along the line: every point is finite.

    Which leg a position lies on, how far along the line it is, where an arrowhead goes: all
    are distances to the line's points, and a distance to a NaN is a NaN, which every
    comparison then answers "no" to. So a line holding one is not measured.

    Raises
    ------
    NonFiniteGeometryError
        Naming the port's ``position`` or the line's ``innerPoints[i]``, and the coordinate.
    """
    for end in (line.source, line.target):
        if end is not None and end.position is not None:
            require_finite_point(end, "position", end.position)
    require_finite_points(line, "innerPoints", line.innerPoints)
    return polyline_of(line)


def port_axis(
    polyline: list[tuple[float, float]], role: Role, *, eps: float = AXIS_SNAP_TOLERANCE
) -> Axis | None:
    """Outward axis at one end of a polyline: the direction *leaving* the port.

    ``snap_axis(adjacent - port)``. Note the sign: the outward direction points
    from the port toward its neighbour, away from the symbol. There is
    deliberately **no** symbol-offset fallback -- it is 180 degrees wrong for a
    port whose group owns no symbol (it climbs to a segment's PipeFlowArrow tens
    of units away), and it is unnecessary, since no degenerate first or last leg
    exists in the reference corpus.
    """
    if len(polyline) < 2:
        return None
    if role == "source":
        port, adjacent = polyline[0], polyline[1]
    else:
        port, adjacent = polyline[-1], polyline[-2]
    return snap_axis(adjacent[0] - port[0], adjacent[1] - port[1], eps=eps)


def collapse_polyline(
    points: list[tuple[float, float]], *, eps: float = POINT_TOLERANCE
) -> list[tuple[float, float]]:
    """Drop duplicate points and interior vertices whose two legs are collinear.

    Collinearity is tested by the **cross product alone**, so both a stranded
    elbow (same direction on both sides) and a reversal (opposite directions, a
    doubled-back spur drawn twice) are removed. The first and last points are
    never dropped: they are the shared port positions. Iterates to a fixpoint,
    since one removal can expose another.
    """
    if len(points) < 2:
        return list(points)

    result = list(points)
    changed = True
    while changed:
        changed = False

        deduped = [result[0]]
        for point in result[1:]:
            previous = deduped[-1]
            if abs(point[0] - previous[0]) <= eps and abs(point[1] - previous[1]) <= eps:
                changed = True
                continue
            deduped.append(point)
        result = deduped

        if len(result) < 3:
            break

        kept = [result[0]]
        for index in range(1, len(result) - 1):
            before, here, after = result[index - 1], result[index], result[index + 1]
            first = (here[0] - before[0], here[1] - before[1])
            second = (after[0] - here[0], after[1] - here[1])
            cross = first[0] * second[1] - first[1] * second[0]
            scale = max(1.0, abs(first[0]) + abs(first[1]) + abs(second[0]) + abs(second[1]))
            if abs(cross) <= eps * scale:
                changed = True
                continue
            kept.append(here)
        kept.append(result[-1])
        result = kept

    return result


def iter_connector_lines(diagram_root):
    """Yield (ConnectorLine, owning RepresentationGroup) over a diagram.

    Walks the diagram tree explicitly rather than the model generically:
    ConnectorLine is a GraphicalPrimitive, so a generic instance walk would also
    reach Shape.primitives in the shape catalogue and corrupt symbol geometry.
    """

    def walk(node, holder):
        if isinstance(node, diagram.RepresentationGroup):
            for subgroup in node.groups:
                yield from walk(subgroup, node)
        elif isinstance(node, diagram.RepresentationTypeGroup):
            for element in node.elements:
                if isinstance(element, diagram.ConnectorLine):
                    yield element, holder

    for group in diagram_root.groups:
        yield from walk(group, diagram_root)
