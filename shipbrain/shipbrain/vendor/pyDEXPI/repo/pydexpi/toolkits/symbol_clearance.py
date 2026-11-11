"""Read-only segment clearance against the geometry an object's symbol draws."""

import math
from itertools import pairwise

from pydexpi.pydexpi_classes.core import diagram
from pydexpi.toolkits.diagram_toolkit import is_annotation_group

Point = tuple[float, float]
_EPS = 1e-7


def segment_clears_symbol(
    group, start: Point, end: Point, *, start_tolerance: float = 0.01
) -> bool | None:
    """Whether a segment leaves a symbol without crossing or following its outline.

    Contact within ``start_tolerance`` drawing units of ``start`` is allowed
    for rounded port coordinates; following an edge or entering a closed
    body is not. Shape usages are checked in their own frame after undoing
    placement, rotation, scale and mirroring. Own type groups are included;
    annotations and nested objects are excluded. Text is not an outline.

    ``None`` means there is no measurable geometry, or a primitive/transform
    cannot be checked. Ellipse arcs conservatively occupy their full ellipse:
    a gap is not treated as a way through the symbol.

    ``None``, too, for a segment between two finite points so far apart that the square of
    its length is no finite number: every test below is made of such products. It
    used to end in ``OverflowError``, out of a ``** 2``.
    """
    if (
        not all(math.isfinite(v) for v in (*start, *end, start_tolerance))
        or start_tolerance < 0
        or math.dist(start, end) <= max(_EPS, start_tolerance)
        or not math.isfinite(math.dist(start, end) * math.dist(start, end))
    ):
        return None
    contact = max(_EPS, start_tolerance / math.dist(start, end))
    found = False
    unknown = False

    def check(primitive, a, b):
        nonlocal found, unknown
        clear = _primitive_clear(primitive, a, b, contact)
        if clear is None:
            unknown |= not isinstance(primitive, diagram.Text)
        else:
            found = True
        return clear is not False

    def visit(node):
        nonlocal unknown
        for element in getattr(node, "elements", None) or []:
            if isinstance(element, diagram.ShapeUsage):
                a, b = _local(element, start), _local(element, end)
                if a is None or b is None or element.shape is None:
                    unknown = True
                    continue
                if not all(check(p, a, b) for p in element.shape.primitives or []):
                    return False
            elif not check(element, start, end):
                return False
        for child in getattr(node, "groups", None) or []:
            if (
                isinstance(child, diagram.RepresentationTypeGroup)
                and not is_annotation_group(child)
                and not visit(child)
            ):
                return False
        return True

    if group is None:
        return None
    if not visit(group):
        return False
    return True if found and not unknown else None


def _local(usage, point: Point) -> Point | None:
    if usage.position is None:
        return None
    if not all(
        math.isfinite(v)
        for v in (
            usage.scaleX or 0,
            usage.scaleY or 0,
            usage.position.x,
            usage.position.y,
            usage.rotation or 0,
        )
    ):
        return None
    sx = (usage.scaleX or 0) * (-1 if usage.isMirrored else 1)
    sy = usage.scaleY or 0
    if abs(sx) <= _EPS or abs(sy) <= _EPS:
        return None
    angle = math.radians(-(usage.rotation or 0))
    x, y = point[0] - usage.position.x, point[1] - usage.position.y
    c, s = math.cos(angle), math.sin(angle)
    return (x * c - y * s) / sx, (x * s + y * c) / sy


def _cross(a: Point, b: Point) -> float:
    return a[0] * b[1] - a[1] * b[0]


def _minus(a: Point, b: Point) -> Point:
    return a[0] - b[0], a[1] - b[1]


def _edge_clear(a: Point, b: Point, p: Point, q: Point, contact: float) -> bool:
    d, e, offset = _minus(b, a), _minus(q, p), _minus(p, a)
    denominator = _cross(d, e)
    if abs(denominator) <= _EPS:
        if abs(_cross(offset, d)) > _EPS:
            return True
        # Products, not powers: ``x ** 2`` raises OverflowError where ``x * x`` is an
        # infinity.
        length2 = d[0] * d[0] + d[1] * d[1]
        ts = [sum(x * y for x, y in zip(_minus(v, a), d, strict=True)) / length2 for v in (p, q)]
        return min(max(ts), 1) <= max(min(ts), _EPS)
    t, u = _cross(offset, e) / denominator, _cross(offset, d) / denominator
    return not (contact < t <= 1 + _EPS and -_EPS <= u <= 1 + _EPS)


def _inside(point: Point, vertices: list[Point]) -> bool:
    x, y = point
    inside = False
    for (px, py), (qx, qy) in pairwise(vertices):
        if (py > y) != (qy > y) and x < (qx - px) * (y - py) / (qy - py) + px:
            inside = not inside
    return inside


def _primitive_clear(primitive, start: Point, end: Point, contact: float) -> bool | None:
    if not all(math.isfinite(v) for v in (*start, *end)):
        return None
    if isinstance(primitive, (diagram.PolyLine, diagram.Polygon)):
        points = [(p.x, p.y) for p in primitive.points or []]
        if len(points) < 2 or not all(math.isfinite(v) for p in points for v in p):
            return None
        if isinstance(primitive, diagram.Polygon) and points[0] != points[-1]:
            points.append(points[0])
        if not all(_edge_clear(start, end, a, b, contact) for a, b in pairwise(points)):
            return False
        # Inspect just after the allowed initial contact, as well as the end.
        near = tuple(a + (b - a) * contact for a, b in zip(start, end, strict=True))
        return not (points[0] == points[-1] and (_inside(near, points) or _inside(end, points)))
    if isinstance(primitive, (diagram.Ellipse, diagram.EllipseArc)):
        rx, ry = primitive.horizontalSemiAxis, primitive.verticalSemiAxis
        if (
            primitive.center is None
            or not rx
            or not ry
            or rx <= 0
            or ry <= 0
            or not all(
                math.isfinite(v)
                for v in (rx, ry, primitive.center.x, primitive.center.y, primitive.rotation or 0)
            )
        ):
            return None
        angle = math.radians(-(primitive.rotation or 0))
        c, s = math.cos(angle), math.sin(angle)

        def local(point):
            x, y = point[0] - primitive.center.x, point[1] - primitive.center.y
            return (x * c - y * s) / rx, (x * s + y * c) / ry

        a, b = local(start), local(end)
        dx, dy = _minus(b, a)
        aa, bb, cc = dx * dx + dy * dy, 2 * (a[0] * dx + a[1] * dy), a[0] * a[0] + a[1] * a[1] - 1
        if aa <= 0 or not all(math.isfinite(v) for v in (aa, bb, cc)):
            return None
        near_x, near_y = a[0] + dx * contact, a[1] + dy * contact
        near_q = near_x * near_x + near_y * near_y - 1
        if (cc < -_EPS and near_q < -_EPS) or (cc <= _EPS and bb <= _EPS):
            return False
        discriminant = bb * bb - 4 * aa * cc
        if discriminant < -_EPS:
            return True
        root = math.sqrt(max(0, discriminant))
        return not any(
            contact < t <= 1 + _EPS for t in ((-bb - root) / (2 * aa), (-bb + root) / (2 * aa))
        )
    return None
