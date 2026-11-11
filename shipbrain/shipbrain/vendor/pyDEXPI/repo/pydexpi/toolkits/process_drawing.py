"""The geometry of a drawn block flow diagram: blocks, the ports on their outline, free lines.

A drawn process model uses DEXPI 2.0.1's ``Process.Diagram.PortNodePosition``, the one drawing
class the Process package adds: a ``NodePosition`` that refers to the ``Port`` it draws. A step is
drawn by a ``RepresentationGroup`` holding its symbol (a ``Static`` with one ``ShapeUsage``), its
label and one ``PortNodePosition`` per port; a connection by a group holding a ``ConnectorLine``
whose ``source`` and ``target`` *are* those node positions. That identity is all the generic
diagram code needs: it reads a ``NodePosition`` of any class, so a block flow diagram is read,
measured and exported by the same code a P&ID is.

What is specific to a block flow diagram, and lives here, is small:

- **which shapes are pyDEXPI's own** (:func:`is_block_shape`, :func:`is_bubble_shape`): a
  rectangle for a step and an ellipse for an instrumentation activity, told by their id or
  their registration number;
- **where a port sits** on a symbol's box (:func:`point_on_side`, :func:`side_of`,
  :func:`fraction_on_side`) and which side a drawn position is on (:func:`port_side`);
- **which object's drawing shows a port** (:func:`drawing_owners`) and where its positions
  are (:func:`port_positions`);
- the **outline** of a drawn symbol, measured from the primitives it holds
  (:func:`outline_distance`);
- the **line of a delegation** (:func:`delegation_ends`, :func:`delegation_lines`): the
  drawing of a delegated port, from its node position to its super port's;
- whether the drawn nesting of the blocks **agrees with the step hierarchy**
  (:func:`containment_problems`).

Nothing here changes a model.
"""

from __future__ import annotations

import math
from collections.abc import Callable, Iterable, Iterator, Mapping
from dataclasses import dataclass
from itertools import pairwise
from typing import Literal

from pydexpi.pydexpi_classes.core import diagram
from pydexpi.pydexpi_classes.pydexpi_classes import (
    EngineeringModel,
    InstrumentationActivity,
    Port,
    PortDirection,
    PortNodePosition,
    ProcessConnection,
    ProcessModel,
    ProcessStep,
    ProcessStepDetail,
)
from pydexpi.toolkits.companions import build_group_index
from pydexpi.toolkits.diagram_toolkit import (
    HIDDEN_SCALE_THRESHOLD,
    Bounds,
    is_annotation_group,
    own_symbol_usage,
    symbol_extent,
)
from pydexpi.toolkits.finite_geometry import (
    NonFiniteGeometryError,
    require_finite,
    require_finite_point,
    require_finite_points,
)
from pydexpi.toolkits.process_hierarchy import StepTree
from pydexpi.toolkits.process_toolkit import iter_process_steps, port_owners, ports_of
from pydexpi.toolkits.routing import POINT_TOLERANCE, Axis, iter_connector_lines

__all__ = [
    "BLOCK_SHAPE_PREFIX",
    "BLOCK_SYMBOL_REGISTRATION",
    "BUBBLE_SHAPE_PREFIX",
    "BUBBLE_SYMBOL_REGISTRATION",
    "CONTAINMENT_TOLERANCE",
    "DEFAULT_ANCHOR_TOLERANCE",
    "SIDE_AXES",
    "ContainmentProblem",
    "DrawingOwner",
    "Side",
    "connection_lines",
    "containment_problems",
    "delegation_ends",
    "delegation_lines",
    "drawing_above",
    "drawing_owner_of",
    "drawing_owners",
    "drawing_step_of",
    "drawing_steps",
    "drawings_below",
    "drawn_ports",
    "first_hit",
    "fraction_on_side",
    "is_block_shape",
    "is_bubble_shape",
    "is_sized_shape",
    "outline_distance",
    "own_usage",
    "point_on_side",
    "port_positions",
    "port_side",
    "side_of",
    "symbol_outlines",
    "usage_outlines",
]

#: What a port is drawn on: a process step, or an instrumentation activity. A port of a
#: ``ProcessStepDetail`` is drawn on its step.
DrawingOwner = ProcessStep | InstrumentationActivity

#: A side of a block's bounding box on the sheet. Y runs down, so ``top`` is the smaller y.
Side = Literal["left", "right", "top", "bottom"]

#: The outward axis of each side, in the sheet's Y-down coordinates.
SIDE_AXES: dict[Side, Axis] = {
    "left": (-1, 0),
    "right": (1, 0),
    "top": (0, -1),
    "bottom": (0, 1),
}

#: Id prefix of pyDEXPI's block shapes; the size follows, so equal blocks share one shape.
BLOCK_SHAPE_PREFIX = "pyDEXPI_ProcessBlock"

#: The ``symbolRegistrationNumber`` of every block shape. It is what still says "block" for a
#: copy of the shape held under another id.
BLOCK_SYMBOL_REGISTRATION = "pyDEXPI process block"

#: Id prefix and ``symbolRegistrationNumber`` of the bubble shapes, the block shapes' twins for
#: an instrumentation activity: an ellipse where a block is a rectangle.
BUBBLE_SHAPE_PREFIX = "pyDEXPI_ProcessBubble"
BUBBLE_SYMBOL_REGISTRATION = "pyDEXPI process bubble"

#: How far a sub-step's block may reach outside its parent's and still count as inside, in
#: sheet units. A drawn coordinate carries what its producer rounded it to, and a block drawn
#: flush with its parent's side is inside it.
CONTAINMENT_TOLERANCE = 1e-3

#: How far a point may lie from a step's outline and still count as on it, in sheet units: the
#: tolerance :func:`port_side` reads a side with. Measured on the Tennessee Eastman export, whose 86
#: line ends lie 0 to 2.55 from the outlines their ports belong to: 78 within 1.0.
DEFAULT_ANCHOR_TOLERANCE = 1.0

#: Segments an ellipse is measured as. The chord error is r (1 - cos(pi / n)), 0.004 % of the
#: radius at 360, far below any tolerance a caller would pass.
_ELLIPSE_SEGMENTS = 360


# ---------------------------------------------------------------------------
# The block shape
# ---------------------------------------------------------------------------


def is_block_shape(shape: diagram.Shape | None) -> bool:
    """Whether `shape` is a pyDEXPI process block shape, or a copy of one.

    By its id, or by its ``symbolRegistrationNumber``: a copy of the shape held under another
    id keeps the registration number, which the id alone would not recognise.
    """
    if shape is None:
        return False
    return (
        str(shape.id).startswith(f"{BLOCK_SHAPE_PREFIX}_")
        or shape.symbolRegistrationNumber == BLOCK_SYMBOL_REGISTRATION
    )


def is_bubble_shape(shape: diagram.Shape | None) -> bool:
    """Whether `shape` is a pyDEXPI process bubble shape, or a copy of one.

    Told as :func:`is_block_shape` tells a block, by its id or its registration number.
    """
    if shape is None:
        return False
    return (
        str(shape.id).startswith(f"{BUBBLE_SHAPE_PREFIX}_")
        or shape.symbolRegistrationNumber == BUBBLE_SYMBOL_REGISTRATION
    )


def is_sized_shape(shape: diagram.Shape | None) -> bool:
    """Whether `shape` is one drawn at its own size, a block or a bubble: its size is in the
    shape, and its usage is drawn at scale 1."""
    return is_block_shape(shape) or is_bubble_shape(shape)


# ---------------------------------------------------------------------------
# Ports on a block's outline
# ---------------------------------------------------------------------------


#: The symbol of one group, never raising: ``diagram_toolkit.own_symbol_usage`` under the name
#: the process drawing code has always used. One reader, in ``diagram_toolkit``, serves every
#: lookup of a group's symbol.
own_usage = own_symbol_usage


def point_on_side(bounds: Bounds, side: Side, fraction: float) -> tuple[float, float]:
    """The point at `fraction` along `side` of `bounds`: from the top down a vertical side, from
    the left along a horizontal one."""
    if side in ("left", "right"):
        y = bounds.min_y + fraction * (bounds.max_y - bounds.min_y)
        return (bounds.min_x if side == "left" else bounds.max_x, y)
    x = bounds.min_x + fraction * (bounds.max_x - bounds.min_x)
    return (x, bounds.min_y if side == "top" else bounds.max_y)


def side_of(bounds: Bounds, point: tuple[float, float], tolerance: float = 1e-6) -> Side | None:
    """The side of `bounds` that `point` lies on, within `tolerance`; None when it lies on none.

    A corner belongs to the vertical side. A point on a side's line but beyond its ends by more
    than the tolerance is on none.
    """
    x, y = point
    within_y = bounds.min_y - tolerance <= y <= bounds.max_y + tolerance
    within_x = bounds.min_x - tolerance <= x <= bounds.max_x + tolerance
    candidates: list[tuple[float, Side]] = []
    if within_y:
        candidates += [(abs(x - bounds.min_x), "left"), (abs(x - bounds.max_x), "right")]
    if within_x:
        candidates += [(abs(y - bounds.min_y), "top"), (abs(y - bounds.max_y), "bottom")]
    near = [(distance, side) for distance, side in candidates if distance <= tolerance]
    if not near:
        return None
    return min(near, key=lambda entry: entry[0])[1]


def fraction_on_side(bounds: Bounds, side: Side, point: tuple[float, float]) -> float:
    """Where along `side` the `point` sits, as :func:`point_on_side` reads a fraction."""
    if side in ("left", "right"):
        length = bounds.max_y - bounds.min_y
        return (point[1] - bounds.min_y) / length if length > 0 else 0.5
    length = bounds.max_x - bounds.min_x
    return (point[0] - bounds.min_x) / length if length > 0 else 0.5


def drawn_ports(owner: DrawingOwner) -> list[Port]:
    """The ports an owner's drawing shows: its own, then, for a step, those of its details, in
    order.

    A ``ProcessStepDetail`` is a facet of its step, never drawn on its own, so a port it holds
    sits on the step's block. An instrumentation activity shows its ``informationPorts``.
    """
    ports = list(ports_of(owner))
    for detail in getattr(owner, "processStepDetails", None) or []:
        ports.extend(ports_of(detail))
    return ports


def drawing_owners(model: EngineeringModel) -> dict[int, DrawingOwner]:
    """The object whose drawing shows each port, by ``id(port)``: one walk for every port.

    A port's own step, the step holding the ``ProcessStepDetail`` that owns it, or the
    ``InstrumentationActivity`` that owns it. The one answer MCP discovery and the readers of a
    drawn block flow diagram find a port by.
    """
    process_model = model.conceptualModel
    details: dict[int, ProcessStep] = {}
    if isinstance(process_model, ProcessModel):
        for step, _parent in iter_process_steps(process_model):
            for detail in step.processStepDetails or []:
                details.setdefault(id(detail), step)
    owners: dict[int, DrawingOwner] = {}
    for port_id, (owner, _slot) in port_owners(model).items():
        if isinstance(owner, (ProcessStep, InstrumentationActivity)):
            owners[port_id] = owner
        elif isinstance(owner, ProcessStepDetail) and id(owner) in details:
            owners[port_id] = details[id(owner)]
    return owners


def drawing_owner_of(model: EngineeringModel, port: Port) -> DrawingOwner | None:
    """The object whose drawing shows `port` (:func:`drawing_owners`), or None.

    For one port; ask :func:`drawing_owners` once for several.
    """
    return drawing_owners(model).get(id(port))


def drawing_steps(model: EngineeringModel) -> dict[int, ProcessStep]:
    """The step whose drawing shows each port, by ``id(port)``: :func:`drawing_owners` without
    the ports an instrumentation activity owns, which are on no step."""
    return {
        port_id: owner
        for port_id, owner in drawing_owners(model).items()
        if isinstance(owner, ProcessStep)
    }


def drawing_step_of(model: EngineeringModel, port: Port) -> ProcessStep | None:
    """The step whose drawing shows `port` (:func:`drawing_steps`), or None.

    For one port; ask :func:`drawing_steps` once for several.
    """
    return drawing_steps(model).get(id(port))


def drawing_above(
    step: ProcessStep | None,
    parent_of: Callable[[ProcessStep], ProcessStep | None],
    drawings: Mapping[int, diagram.RepresentationGroup],
) -> diagram.RepresentationGroup | None:
    """The drawing of the nearest drawn step at or above `step`, or None when none is drawn.

    Where the drawing of a step held by `step` belongs: DEXPI's drawing hierarchy follows
    composition, so a sub-step is drawn inside the drawing of the nearest drawn step above it,
    and on the sheet when there is none (the caller's ``or model.diagram``). `parent_of` is the
    step hierarchy to read -- ``StepTree.parent_of`` -- and `drawings` the drawing of each
    drawn object by ``id()`` (``companions.build_group_index``).
    """
    seen: set[int] = set()
    while step is not None and id(step) not in seen:
        group = drawings.get(id(step))
        if group is not None:
            return group
        seen.add(id(step))
        step = parent_of(step)
    return None


def drawings_below(
    step: ProcessStep, drawings: Mapping[int, diagram.RepresentationGroup]
) -> list[tuple[ProcessStep, diagram.RepresentationGroup]]:
    """The nearest drawn steps below `step`, each with its drawing: no drawn step between.

    The drawings that belong directly inside `step`'s own. Below an undrawn sub-step the walk
    goes on; below a drawn one it stops, since what is further down belongs inside that one.
    """
    found: list[tuple[ProcessStep, diagram.RepresentationGroup]] = []
    seen: set[int] = {id(step)}

    def below(parent: ProcessStep) -> None:
        for child in parent.subProcessSteps or []:
            if id(child) in seen:
                continue
            seen.add(id(child))
            drawing = drawings.get(id(child))
            if drawing is None:
                below(child)
            else:
                found.append((child, drawing))

    below(step)
    return found


@dataclass(frozen=True)
class ContainmentProblem:
    """One place where the drawn nesting of two blocks disagrees with the step hierarchy.

    Attributes
    ----------
    step : ProcessStep
        The step whose block is in the wrong place.
    other : ProcessStep
        The step it is measured against.
    kind : {"outside_parent", "inside_unrelated"}
        ``outside_parent``: `other` is the nearest drawn step above `step`, and `step`'s
        block does not lie inside its block. ``inside_unrelated``: `other` is neither above
        nor below `step`, yet `step`'s block lies inside its block, so the sheet shows a
        containment the model does not hold.
    box, other_box : Bounds
        The boxes of the two symbols on the sheet.
    overhang : float
        ``outside_parent``: how far `step`'s block reaches beyond `other`'s, at most, in sheet
        units. 0 for ``inside_unrelated``.
    shift : tuple[float, float] | None
        ``outside_parent``: the smallest offset ``(dx, dy)`` at which `step`'s block would lie
        inside `other`'s, or None when it is larger than that block and no offset would.
    """

    step: ProcessStep
    other: ProcessStep
    kind: Literal["outside_parent", "inside_unrelated"]
    box: Bounds
    other_box: Bounds
    overhang: float = 0.0
    shift: tuple[float, float] | None = None


def _within(inner: Bounds, outer: Bounds, tolerance: float) -> bool:
    return (
        inner.min_x >= outer.min_x - tolerance
        and inner.min_y >= outer.min_y - tolerance
        and inner.max_x <= outer.max_x + tolerance
        and inner.max_y <= outer.max_y + tolerance
    )


def _shift_inside(inner: Bounds, outer: Bounds, tolerance: float) -> tuple[float, float] | None:
    """The smallest offset of `inner` that puts it inside `outer`; None when it does not fit."""
    if (
        inner.max_x - inner.min_x > outer.max_x - outer.min_x + tolerance
        or inner.max_y - inner.min_y > outer.max_y - outer.min_y + tolerance
    ):
        return None

    def along(low: float, high: float, outer_low: float, outer_high: float) -> float:
        if low < outer_low:
            return outer_low - low
        if high > outer_high:
            return outer_high - high
        return 0.0

    return (
        along(inner.min_x, inner.max_x, outer.min_x, outer.max_x),
        along(inner.min_y, inner.max_y, outer.min_y, outer.max_y),
    )


def containment_problems(
    model: EngineeringModel, *, tolerance: float = CONTAINMENT_TOLERANCE
) -> list[ContainmentProblem]:
    """Where the drawn nesting of the blocks disagrees with the step hierarchy.

    The drawing hierarchy follows composition -- a sub-step's drawing is held by the drawing of
    the nearest drawn step above it (:func:`drawing_above`) -- but nothing ties the *geometry*
    to it: a block may be drawn at any position, whatever is drawn around it. So the two
    readings of the sheet can part, and this finds where:

    - **outside_parent**: a drawn step's block does not lie inside the block of the nearest
      drawn step above it. Measured on the boxes of the two symbols
      (:func:`~pydexpi.toolkits.diagram_toolkit.symbol_extent`), within `tolerance`.
    - **inside_unrelated**: a drawn step's block lies inside the block of a step that is neither
      above nor below it: the sheet shows it inside a block it does not belong to in the model. Only
      the innermost such block is named, so a block left three levels deep is reported once.

    Read-only, and the one reading the rule ``pydexpi_process_step_drawn_inside_parent`` and
    MCP discovery report. A step drawn without a measurable symbol is neither inside nor
    outside anything and is left out; so is a model without a diagram or a process model. A
    symbol holding a number that is not finite is not measurable either: a rule that
    reports on a document must not fail on what the document may hold, and a block turned by
    an infinite angle used to end ``validate`` with a bare ``ValueError``.

    Returns
    -------
    list[ContainmentProblem]
        In the hierarchy's walk order, a step's ``outside_parent`` before its
        ``inside_unrelated``.
    """
    process_model = model.conceptualModel
    if not isinstance(process_model, ProcessModel) or getattr(model, "diagram", None) is None:
        return []
    drawings = build_group_index(model)
    tree = StepTree(process_model)
    boxes: list[tuple[ProcessStep, Bounds]] = []
    for step, _holder in iter_process_steps(process_model):
        group = drawings.get(id(step))
        try:
            box = symbol_extent(group) if group is not None else None
        except NonFiniteGeometryError:
            box = None
        if box is not None:
            boxes.append((step, box))
    by_step = {id(step): box for step, box in boxes}

    problems: list[ContainmentProblem] = []
    for step, box in boxes:
        above = tree.parent_of(step)
        seen: set[int] = set()
        while above is not None and id(above) not in by_step and id(above) not in seen:
            seen.add(id(above))
            above = tree.parent_of(above)
        if above is not None and id(above) in by_step:
            outer = by_step[id(above)]
            if not _within(box, outer, tolerance):
                overhang = max(
                    outer.min_x - box.min_x,
                    outer.min_y - box.min_y,
                    box.max_x - outer.max_x,
                    box.max_y - outer.max_y,
                )
                problems.append(
                    ContainmentProblem(
                        step,
                        above,
                        "outside_parent",
                        box,
                        outer,
                        overhang=overhang,
                        shift=_shift_inside(box, outer, tolerance),
                    )
                )
        innermost: tuple[float, ProcessStep, Bounds] | None = None
        for other, outer in boxes:
            if other is step or tree.is_below(step, other) or tree.is_below(other, step):
                continue
            if not _within(box, outer, tolerance) or _within(outer, box, tolerance):
                continue  # not inside it, or the two blocks are one box: neither holds the other
            area = (outer.max_x - outer.min_x) * (outer.max_y - outer.min_y)
            if innermost is None or area < innermost[0]:
                innermost = (area, other, outer)
        if innermost is not None:
            problems.append(
                ContainmentProblem(step, innermost[1], "inside_unrelated", box, innermost[2])
            )
    return problems


def delegation_ends(port: Port) -> tuple[Port, Port] | None:
    """The two ports the line of `port`'s delegation runs between, in the direction of the
    flow: ``(source, target)``. None for a port that names no super port.

    A delegated port takes part in its super port's connection (``process_hierarchy``), so the
    line between the two is that connection continued inside the outer block, and it runs the
    way the flow does: into the block for an inlet, from the super port to the delegate, and
    out of it for anything else, from the delegate to the super port.
    """
    super_port = port.__dict__.get("superReference")
    if super_port is None:
        return None
    if port.__dict__.get("nominalDirection") == PortDirection.INLET:
        return super_port, port
    return port, super_port


def delegation_lines(
    diagram_root: diagram.RepresentationGroup | None,
) -> list[tuple[diagram.ConnectorLine, diagram.RepresentationGroup]]:
    """Every ``ConnectorLine`` drawn for a delegated port, with the group that holds it.

    The drawing of a delegation is the drawing of its delegate: a ``RepresentationGroup`` that
    represents the ``Port``, nested in its step's drawing, holding the line from the
    delegate's node position to its super port's. Nothing else
    draws a port as a group, so a line held by one is a delegation's.
    """
    if diagram_root is None:
        return []
    return [
        (line, holder)
        for line, holder in iter_connector_lines(diagram_root)
        if isinstance(getattr(holder, "represents", None), Port)
    ]


def _representation_groups(root: object) -> Iterator[diagram.RepresentationGroup]:
    for subgroup in getattr(root, "groups", None) or []:
        if isinstance(subgroup, diagram.RepresentationGroup):
            yield subgroup
            yield from _representation_groups(subgroup)


def port_positions(
    diagram_root: diagram.RepresentationGroup | None,
) -> dict[int, list[tuple[diagram.RepresentationGroup, PortNodePosition]]]:
    """Every drawn position of every port, by ``id(port)``: ``(holding group, position)``.

    In drawing order. DEXPI allows a port several positions, so each port maps to a list. A
    position naming no port is left out.
    """
    found: dict[int, list[tuple[diagram.RepresentationGroup, PortNodePosition]]] = {}
    if diagram_root is None:
        return found
    for group in [diagram_root, *_representation_groups(diagram_root)]:
        for position in getattr(group, "nodePositions", None) or []:
            if isinstance(position, PortNodePosition) and position.port is not None:
                found.setdefault(id(position.port), []).append((group, position))
    return found


def connection_lines(
    diagram_root: diagram.RepresentationGroup | None,
) -> list[tuple[diagram.ConnectorLine, diagram.RepresentationGroup]]:
    """Every ``ConnectorLine`` drawn for a process connection, with the group that holds it."""
    if diagram_root is None:
        return []
    return [
        (line, holder)
        for line, holder in iter_connector_lines(diagram_root)
        if isinstance(getattr(holder, "represents", None), ProcessConnection)
    ]


# ---------------------------------------------------------------------------
# The outline of a drawn symbol
# ---------------------------------------------------------------------------


def _segment_distance(
    point: tuple[float, float], start: tuple[float, float], end: tuple[float, float]
) -> float:
    dx, dy = end[0] - start[0], end[1] - start[1]
    length = dx * dx + dy * dy
    if length <= 0.0:
        return math.dist(point, start)
    along = ((point[0] - start[0]) * dx + (point[1] - start[1]) * dy) / length
    along = min(max(along, 0.0), 1.0)
    return math.dist(point, (start[0] + along * dx, start[1] + along * dy))


def _primitive_polyline(primitive: object) -> list[tuple[float, float]] | None:
    """A primitive as the points of its outline, in the coordinates it is written in.

    A ``Polygon`` closes on its first point; an ellipse is its :data:`_ELLIPSE_SEGMENTS` chords,
    an arc those between its angles. A ``Text`` has no outline, and neither has anything else.

    Raises
    ------
    NonFiniteGeometryError
        For a point, a centre, a semi-axis or an angle that is not finite: an outline
        through such a number is none, and every distance to it is a NaN.
    """
    if isinstance(primitive, (diagram.PolyLine, diagram.Polygon)):
        require_finite_points(primitive, "points", primitive.points or [])
        points = [(point.x, point.y) for point in primitive.points or []]
        if isinstance(primitive, diagram.Polygon) and points:
            points.append(points[0])
        return points or None
    if isinstance(primitive, (diagram.Ellipse, diagram.EllipseArc)):
        centre = primitive.center
        if centre is None:
            return None
        centre_x, centre_y = require_finite_point(primitive, "center", centre)
        a = require_finite(primitive, "horizontalSemiAxis", primitive.horizontalSemiAxis)
        b = require_finite(primitive, "verticalSemiAxis", primitive.verticalSemiAxis)
        turn = math.radians(require_finite(primitive, "rotation", primitive.rotation))
        start, sweep = 0.0, 2.0 * math.pi
        if isinstance(primitive, diagram.EllipseArc):
            start_angle = require_finite(primitive, "startAngle", primitive.startAngle)
            end_angle = require_finite(primitive, "endAngle", primitive.endAngle)
            start = math.radians(start_angle)
            sweep = math.radians(end_angle - start_angle)
            sweep = sweep % (2.0 * math.pi) or 2.0 * math.pi
        points = []
        for index in range(_ELLIPSE_SEGMENTS + 1):
            t = start + sweep * index / _ELLIPSE_SEGMENTS
            x, y = a * math.cos(t), b * math.sin(t)
            points.append(
                (
                    centre_x + x * math.cos(turn) - y * math.sin(turn),
                    centre_y + x * math.sin(turn) + y * math.cos(turn),
                )
            )
        return points
    return None


def _placed(usage: diagram.ShapeUsage, point: tuple[float, float]) -> tuple[float, float]:
    """A point of a usage's shape on the sheet: mirrored and scaled, turned, then moved, in the
    order :func:`~pydexpi.toolkits.diagram_toolkit.usage_extent` and every renderer apply."""
    x = point[0] * (usage.scaleX or 0.0) * (-1.0 if usage.isMirrored else 1.0)
    y = point[1] * (usage.scaleY or 0.0)
    angle = math.radians(usage.rotation or 0.0)
    return (
        usage.position.x + x * math.cos(angle) - y * math.sin(angle),
        usage.position.y + x * math.sin(angle) + y * math.cos(angle),
    )


def usage_outlines(usage: diagram.ShapeUsage) -> Iterator[list[tuple[float, float]]]:
    """The outlines of one placed symbol, each as sheet points: its shape's primitives as
    :func:`_primitive_polyline` reads them, mirrored, scaled, turned and moved as the usage
    draws them. Nothing for a usage without a shape or a position, or one drawn at a scale the
    renderers draw nothing for.

    Raises
    ------
    NonFiniteGeometryError
        If a scale factor, the position or the rotation of the usage, or a number of its
        shape's primitives, is not finite, as
        :func:`~pydexpi.toolkits.diagram_toolkit.usage_extent` does for the box of the same
        symbol. ``math.cos`` raised a bare ``ValueError`` here for an infinite rotation.
    """
    if usage.shape is None or usage.position is None:
        return
    own_x = require_finite(usage, "scaleX", usage.scaleX)
    own_y = require_finite(usage, "scaleY", usage.scaleY)
    if abs(own_x) < HIDDEN_SCALE_THRESHOLD and abs(own_y) < HIDDEN_SCALE_THRESHOLD:
        return  # the renderers draw nothing for it
    require_finite_point(usage, "position", usage.position)
    require_finite(usage, "rotation", usage.rotation)
    for primitive in usage.shape.primitives or []:
        points = _primitive_polyline(primitive)
        if points:
            yield [_placed(usage, point) for point in points]


def symbol_outlines(group: object) -> Iterator[list[tuple[float, float]]]:
    """The outlines of the symbol `group` draws for its own object, each as sheet points.

    What :func:`~pydexpi.toolkits.diagram_toolkit.symbol_extent` measures the box of: the
    primitives of the shapes its own type groups use, placed, and the primitives drawn straight
    into them. Labels, the drawings of other objects nested under it and connector lines are
    not the symbol.
    """
    for subgroup in getattr(group, "groups", None) or []:
        if not isinstance(subgroup, diagram.RepresentationTypeGroup):
            continue
        if is_annotation_group(subgroup):
            continue
        for element in subgroup.elements:
            if isinstance(element, diagram.ShapeUsage):
                yield from usage_outlines(element)
            elif not isinstance(element, diagram.ConnectorLine):
                points = _primitive_polyline(element)
                if points:
                    yield points


#: How close to parallel a ray and an outline's edge are taken to be the same line, and how far
#: behind its start a ray still meets an edge: coordinates carry a rotation's rounding.
_RAY_EPSILON = 1e-9


def first_hit(
    outlines: Iterable[list[tuple[float, float]]],
    origin: tuple[float, float],
    direction: tuple[float, float],
) -> float | None:
    """How far along the ray from `origin` in `direction`, a unit vector, the first point of
    any of `outlines` lies; None when the ray meets none of them."""
    best: float | None = None
    for points in outlines:
        for start, end in pairwise(points):
            ex, ey = end[0] - start[0], end[1] - start[1]
            ox, oy = start[0] - origin[0], start[1] - origin[1]
            cross = direction[0] * ey - direction[1] * ex
            scale = math.hypot(ex, ey)
            if scale <= 0.0:
                continue
            if abs(cross) <= _RAY_EPSILON * scale:
                # Parallel. On the ray's own line the edge is met where it begins.
                if abs(ox * direction[1] - oy * direction[0]) > _RAY_EPSILON * max(1.0, scale):
                    continue
                first = ox * direction[0] + oy * direction[1]
                last = first + ex * direction[0] + ey * direction[1]
                near, far = min(first, last), max(first, last)
                if far < -_RAY_EPSILON:
                    continue
                along = max(near, 0.0)
            else:
                along = (ox * ey - oy * ex) / cross
                across = (ox * direction[1] - oy * direction[0]) / cross
                if along < -_RAY_EPSILON or not -_RAY_EPSILON <= across <= 1.0 + _RAY_EPSILON:
                    continue
                along = max(along, 0.0)
            if best is None or along < best:
                best = along
    return best


def port_side(
    group: object, point: tuple[float, float], *, tolerance: float = DEFAULT_ANCHOR_TOLERANCE
) -> Side | None:
    """The side of its symbol a drawn port lies on, within `tolerance`; None for one on none.

    The side of the symbol's box the point is on (:func:`side_of`), which is every port of a
    block. A port of another shape sits on the outline, inside the box: its side is the one it is *seen from* -- the side whose
    inward normal through the point meets the outline first there -- and the nearest of them
    when it is seen from two, a vertical side before a horizontal one. That is the side a line
    leaves the port through, and the side MCP discovery reports.
    """
    bounds = symbol_extent(group)
    if bounds is None:
        return None
    side = side_of(bounds, point, tolerance=tolerance)
    if side is not None:
        return side
    outlines = list(symbol_outlines(group))
    best: tuple[float, Side] | None = None
    for candidate in ("left", "right", "top", "bottom"):
        if candidate in ("left", "right"):
            if not bounds.min_y - tolerance <= point[1] <= bounds.max_y + tolerance:
                continue
            start = (bounds.min_x if candidate == "left" else bounds.max_x, point[1])
        else:
            if not bounds.min_x - tolerance <= point[0] <= bounds.max_x + tolerance:
                continue
            start = (point[0], bounds.min_y if candidate == "top" else bounds.max_y)
        axis = SIDE_AXES[candidate]
        inward = (-float(axis[0]), -float(axis[1]))
        # Signed, so a point outside the box, behind the ray's start, is seen from nowhere.
        depth = (point[0] - start[0]) * inward[0] + (point[1] - start[1]) * inward[1]
        hit = first_hit(outlines, start, inward)
        if hit is None or abs(hit - depth) > tolerance:
            continue
        if best is None or depth < best[0] - POINT_TOLERANCE:
            best = (depth, candidate)
    return best[1] if best is not None else None


def outline_distance(group: object, point: tuple[float, float]) -> float | None:
    """How far `point` lies from the outline of the symbol `group` draws, in sheet units.

    The distance to the nearest line, polygon edge or ellipse the symbol is made of, wherever
    the point is: on the outline it is 0, and inside a block as far as the nearest edge. None
    when the group draws no symbol with an outline to measure -- nothing, a placeholder, or
    text alone.
    """
    best: float | None = None
    for points in symbol_outlines(group):
        if len(points) == 1:
            distance = math.dist(point, points[0])
            best = distance if best is None else min(best, distance)
            continue
        for start, end in pairwise(points):
            distance = _segment_distance(point, start, end)
            best = distance if best is None else min(best, distance)
    return best
