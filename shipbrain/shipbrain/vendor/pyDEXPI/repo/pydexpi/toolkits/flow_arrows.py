"""Flow arrows: which line an arrow lies on, and which way the flow along it runs.

DEXPI draws the direction of a flow as geometry, not as a property of the line: a
``Core.Diagram.PipeFlowArrow`` type group holding one ``ShapeUsage`` of an arrowhead shape,
placed on the line and turned to the direction the line runs there. The specification's
reference P&ID draws its eight that way, in the drawing of the segment whose flow they show, and
the Tennessee Eastman process export its seventeen, a filled arrowhead 2 to 5 units before each
stream's target. A ``ConnectorLine`` has no marker of its own (``source``, ``target``,
``innerPoints`` and a ``Stroke`` are all it holds), so an arrow drawn any other way would be seen
by pyDEXPI's exports alone.

Nothing in the model ties an arrow to its line. ``ShapeUsage.position`` is a point of its
own, so which line an arrow marks has to be read from the geometry, for a P&ID and
a block flow diagram alike. :func:`bind` reads which line each arrow lies on and where:
which end of the line it is nearer to, how far from that end along the line, whether it is on
the leg that end starts, and at what angle to the leg it lies on -- the angle of the arrow **as
it is drawn** (:func:`facing`), not of its ``rotation`` alone: a mirror flag, or a negative
scale factor, flips the shape in its own frame.

**An arrow shows the flow, not the way its line happens to be drawn**. A line runs
from its ``source`` to its ``target``; the flow it draws runs from the source of its pipe, its
connection or its delegation to the target of that (:func:`flow_along`). The two agree in
every drawing of the corpus that says both -- each of the 26 flow arrows on a P&ID's pipe
points from the pipe's source node to its target node, and no line is drawn against its
flow -- but a model can part them: a pipe whose source and target are swapped keeps its line
as it was drawn. :func:`bind` therefore records which way the flow runs along each arrow's
line.

:func:`arrow_of` finds the arrows an id names. Nothing here changes a model.

An arrow, or a line, that holds a NaN or an infinity is not bound. A document may hold
one (``xsd:double`` admits it), every comparison with a NaN is false, and ``inf % 360`` is a NaN,
so nothing can be read off such an arrow as geometry. :func:`bind` reads neither.
"""

from __future__ import annotations

import math
from collections.abc import Iterator
from dataclasses import dataclass
from itertools import pairwise

from pydexpi.pydexpi_classes.core import diagram
from pydexpi.pydexpi_classes.pydexpi_classes import (
    PipingConnection,
    PipingNodePosition,
    Port,
    PortNodePosition,
    ProcessConnection,
)
from pydexpi.toolkits import routing
from pydexpi.toolkits.diagram_toolkit import usage_extent
from pydexpi.toolkits.process_drawing import delegation_ends

__all__ = [
    "FLOW_ARROW_TOLERANCE",
    "ArrowBinding",
    "arrow_of",
    "bind",
    "facing",
    "finite",
    "flips",
    "flow_along",
    "flow_arrows",
    "foot",
    "footprint",
    "leg_angle",
    "line_legs",
    "line_length",
    "pose_on_line",
    "readable",
]

#: How far from a line an arrow may lie and still be read as lying on it, in sheet units.
#: Measured: the reference P&ID's 8 arrows lie exactly on their pipes and the Tennessee Eastman
#: export's 17 within 0.004 of their streams.
FLOW_ARROW_TOLERANCE = 0.05


def leg_angle(start: tuple[float, float], end: tuple[float, float]) -> float:
    """The direction from `start` to `end` in degrees, as a ``ShapeUsage.rotation`` reads one:
    0 along +x, 90 along +y, which is down the sheet."""
    return math.degrees(math.atan2(end[1] - start[1], end[0] - start[0])) % 360.0


def line_legs(polyline: list[tuple[float, float]]) -> list[tuple[tuple, tuple, float]]:
    """The legs of a polyline that have length, each with its length."""
    return [
        (start, end, length)
        for start, end in pairwise(polyline)
        if (length := math.dist(start, end)) > routing.POINT_TOLERANCE
    ]


def line_length(polyline: list[tuple[float, float]]) -> float:
    """How long a line is, along its drawn route."""
    return sum(length for _start, _end, length in line_legs(polyline))


def pose_on_line(
    polyline: list[tuple[float, float]],
    end: routing.Role,
    distance: float,
    lateral: float = 0.0,
    *,
    whole: bool = False,
) -> tuple[tuple[float, float], float] | None:
    """The point `distance` along a line from one of its ends, and the direction the line runs
    there, source to target, in degrees.

    `distance` is measured along the drawn route from `end`, and is held to half the line's
    length, so a point nearer one end is never read as nearer the other. At a corner the
    direction is that of the leg on `end`'s side of it. `lateral` steps the point off the line,
    to the right of the direction it runs (down the sheet for a line running along +x): an
    imported arrow lies a few thousandths beside its line. None for a line without length.

    With `whole` the distance is held to the line's whole length instead, anywhere on the line.
    """
    legs = line_legs(polyline)
    total = sum(length for _start, _end, length in legs)
    if not legs or total <= routing.POINT_TOLERANCE:
        return None
    remaining = min(max(distance, 0.0), total if whole else total / 2.0)
    ordered = legs if end == "source" else [(b, a, length) for a, b, length in reversed(legs)]
    for start, stop, length in ordered:
        if remaining <= length + routing.POINT_TOLERANCE:
            fraction = min(remaining / length, 1.0)
            point = (
                start[0] + fraction * (stop[0] - start[0]),
                start[1] + fraction * (stop[1] - start[1]),
            )
            # The leg as the line runs it: walked backwards from the target, it is reversed.
            angle = leg_angle(start, stop) if end == "source" else leg_angle(stop, start)
            if lateral:
                turn = math.radians(angle)
                point = (
                    point[0] - lateral * math.sin(turn),
                    point[1] + lateral * math.cos(turn),
                )
            return point, angle
        remaining -= length
    return None  # pragma: no cover - the half-length clamp ends in the loop


def _drawn_at(position: object) -> object | None:
    """The conceptual object a line's end draws: a piping node, a process port, or None for a
    free end, an open end and a signal port, which draw none."""
    if isinstance(position, PipingNodePosition):
        return position.node
    if isinstance(position, PortNodePosition):
        return position.port
    return None


def _flow_ends(drawn: object) -> tuple[object | None, object | None] | None:
    """What the flow of the object a line draws leaves and what it arrives at, or None for an
    object whose line shows no flow that can be read off the model."""
    if isinstance(drawn, ProcessConnection):
        return drawn.__dict__.get("source"), drawn.__dict__.get("target")
    if isinstance(drawn, Port):
        # A delegation's line is its super port's connection continued inside the outer block.
        return delegation_ends(drawn)
    if isinstance(drawn, PipingConnection):
        return drawn.__dict__.get("sourceNode"), drawn.__dict__.get("targetNode")
    return None


def flow_along(line: diagram.ConnectorLine, holder: object) -> int:
    """Which way the flow runs along a drawn line: 1 from its ``source`` to its ``target``,
    -1 the other way, 0 when the model does not say.

    `holder` is the drawing that holds the line, and what it represents is what flows: a pipe
    (from its ``sourceNode`` to its ``targetNode``), a process connection (from its source port
    to its target port) or a delegated port (``process_drawing.delegation_ends``). The line's
    two ends are node positions that draw a piping node or a port; where one of them is the
    node or port the flow leaves, or the other the one it arrives at, the line is drawn with
    the flow, and against it the other way round. One end is enough, so a pipe with an open
    end is read by the end it has.

    0 for a line whose drawing represents none of those -- a signal line, a measuring line --
    for a free line, which names no node position, and where the two ends contradict each
    other. An arrow on such a line shows the way the line is drawn.
    """
    ends = _flow_ends(getattr(holder, "represents", None))
    if ends is None:
        return 0
    leaves, arrives = ends
    at_source, at_target = _drawn_at(line.source), _drawn_at(line.target)
    along = (at_source is not None and at_source is leaves) or (
        at_target is not None and at_target is arrives
    )
    against = (at_source is not None and at_source is arrives) or (
        at_target is not None and at_target is leaves
    )
    if along == against:
        return 0
    return 1 if along else -1


def flips(usage: diagram.ShapeUsage) -> tuple[bool, bool]:
    """Whether a usage draws its shape flipped along the shape's own x axis, and whether it
    draws it as a reflection at all.

    A renderer mirrors and scales a shape in the shape's frame, before it turns it
    (``diagram_toolkit.usage_extent``): ``isMirrored`` negates x, and so does a negative
    ``scaleX``, so the two together cancel. A negative ``scaleY`` negates y. The shape is
    drawn as its reflection when an odd number of the three holds.
    """
    along = bool(usage.isMirrored) != ((usage.scaleX or 0.0) < 0.0)
    across = (usage.scaleY or 0.0) < 0.0
    return along, along != across


def facing(usage: diagram.ShapeUsage) -> float:
    """The direction on the sheet of the shape's own +x axis as a usage draws it, in degrees.

    ``rotation`` for a usage that is neither mirrored nor scaled by a negative ``scaleX``, the
    opposite direction for one that is either, and ``rotation`` again for one that is both.
    This, not ``rotation``, is the way an arrow points: the ``pyDEXPI_FlowArrowhead`` shape, the
    reference P&ID's chevron and the Tennessee Eastman export's arrowhead all point along
    their shape's +x, and a mirror or a scale by ``-1`` leaves ``rotation`` saying one thing
    and the drawing another.
    """
    along, _reflected = flips(usage)
    return ((usage.rotation or 0.0) + (180.0 if along else 0.0)) % 360.0


def flow_arrows(
    diagram_root: object,
) -> Iterator[tuple[diagram.ShapeUsage, diagram.PipeFlowArrow, diagram.RepresentationGroup]]:
    """Every arrow of a drawing: ``(usage, the PipeFlowArrow group holding it, the drawing
    holding that group)``, in drawing order."""
    if not isinstance(diagram_root, diagram.RepresentationGroup):
        return
    for subgroup in diagram_root.groups:
        if isinstance(subgroup, diagram.PipeFlowArrow):
            for element in subgroup.elements:
                if isinstance(element, diagram.ShapeUsage) and element.position is not None:
                    yield element, subgroup, diagram_root
        elif isinstance(subgroup, diagram.RepresentationGroup):
            yield from flow_arrows(subgroup)


@dataclass(frozen=True)
class ArrowBinding:
    """Where one arrow lies on its line, as :func:`bind` read it.

    Attributes
    ----------
    usage : ShapeUsage
        The arrow.
    line : ConnectorLine
        The line it lies on.
    polyline : tuple[tuple[float, float], ...]
        The line's drawn route when it was read.
    end : {"source", "target"}
        The end of the line the arrow is nearer to, along the line; the target when it is as
        near to both.
    distance : float
        How far from that end it lies, along the line.
    on_end_leg : bool
        It lies on the leg that end starts: the first leg for the source, the last for the
        target. Such an arrow marks what the line ends on; any other marks the run.
    offset : float
        The way the arrow points as drawn (:func:`facing`) less the direction of the leg it
        lies on, in degrees: 0 for an arrow pointing the way the line runs, whatever its
        ``rotation``, its ``isMirrored`` and the sign of its ``scaleX`` are.
    lateral : float
        How far beside the line it lies, to the right of the direction the line runs; 0 on it.
    position, rotation : tuple[float, float], float
        Where the arrow was, and how it was turned, when it was read.
    leg : float
        The direction of the leg it lay on, source to target, in degrees.
    flipped, reflected : bool, bool
        Whether its shape was drawn flipped along its own x axis, and whether as a reflection
        at all (a mirror, or one negative scale factor), when it was read. Either changes the
        way the arrow points without touching its position or its rotation.
    flow : int
        Which way the flow ran along the line when it was read (:func:`flow_along`): 1 from
        the line's source to its target, -1 the other way, 0 when the model does not say.
    """

    usage: diagram.ShapeUsage
    line: diagram.ConnectorLine
    polyline: tuple[tuple[float, float], ...]
    end: routing.Role
    distance: float
    on_end_leg: bool
    offset: float
    lateral: float
    position: tuple[float, float]
    rotation: float
    leg: float
    flipped: bool
    reflected: bool
    flow: int = 0


def foot(
    point: tuple[float, float], start: tuple[float, float], end: tuple[float, float], length: float
) -> tuple[float, float]:
    """How far `point` lies from the leg, and how far along it its nearest point is."""
    ux, uy = (end[0] - start[0]) / length, (end[1] - start[1]) / length
    px, py = point[0] - start[0], point[1] - start[1]
    along = min(max(px * ux + py * uy, 0.0), length)
    nearest = (start[0] + along * ux, start[1] + along * uy)
    return math.dist(point, nearest), along


def bind(diagram_root: object) -> list[ArrowBinding]:
    """Read which line every flow arrow of a drawing lies on, and where on it.

    An arrow belongs to the lines of the drawing that holds its group, at any depth: the
    reference P&ID keeps an arrow in its segment's drawing and the pipe it lies on in a drawing
    nested there, and the Tennessee Eastman export keeps all of its arrows on the sheet. It is bound
    to the nearest of those lines within :data:`FLOW_ARROW_TOLERANCE`; an arrow that lies on none --
    drawn beside its line -- is not bound. Neither is an arrow whose position, rotation or scale is
    not finite, and no arrow is bound to a line whose route holds such a number: nothing can be read
    off either.

    Read-only, and cheap where it matters: a drawing without a ``PipeFlowArrow`` costs one walk
    of its groups.
    """
    bindings: list[ArrowBinding] = []
    lines_of: dict[int, list[tuple[diagram.ConnectorLine, list, object]]] = {}
    for usage, _group, holder in flow_arrows(diagram_root):
        if not readable(usage):
            continue
        candidates = lines_of.get(id(holder))
        if candidates is None:
            candidates = lines_of[id(holder)] = [
                (line, polyline, line_holder)
                for line, line_holder in routing.iter_connector_lines(holder)
                if finite(polyline := routing.polyline_of(line))
            ]
        point = (usage.position.x, usage.position.y)
        best: tuple[float, diagram.ConnectorLine, list, float, object] | None = None
        for line, polyline, line_holder in candidates:
            walked = 0.0
            for start, stop, length in line_legs(polyline):
                gap, along = foot(point, start, stop, length)
                if gap <= FLOW_ARROW_TOLERANCE and (best is None or gap < best[0]):
                    best = (gap, line, polyline, walked + along, line_holder)
                walked += length
        if best is None:
            continue
        _gap, line, polyline, from_source, line_holder = best
        total = sum(length for _start, _end, length in line_legs(polyline))
        nearer_source = from_source < total - from_source - routing.POINT_TOLERANCE
        end: routing.Role = "source" if nearer_source else "target"
        distance = from_source if nearer_source else total - from_source
        # Measured against the pose :func:`pose_on_line` gives for this end and distance: at a
        # corner the arrow lies on two legs, and its angle is read against the one it names.
        pose = pose_on_line(polyline, end, distance)
        if pose is None:  # pragma: no cover - a leg with length was found above
            continue
        (on_x, on_y), angle = pose
        turn = math.radians(angle)
        beside = (point[1] - on_y) * math.cos(turn) - (point[0] - on_x) * math.sin(turn)
        legs = line_legs(polyline)
        end_leg = legs[0][2] if nearer_source else legs[-1][2]
        flipped, reflected = flips(usage)
        bindings.append(
            ArrowBinding(
                usage=usage,
                line=line,
                polyline=tuple(polyline),
                end=end,
                distance=distance,
                on_end_leg=distance <= end_leg + routing.POINT_TOLERANCE,
                offset=(facing(usage) - angle) % 360.0,
                lateral=beside if abs(beside) > routing.POINT_TOLERANCE else 0.0,
                position=point,
                rotation=usage.rotation or 0.0,
                leg=angle,
                flipped=flipped,
                reflected=reflected,
                flow=flow_along(line, line_holder),
            )
        )
    return bindings


def readable(usage: diagram.ShapeUsage) -> bool:
    """Whether an arrow's own numbers are all finite: its position, rotation and scales."""
    return all(
        math.isfinite(value)
        for value in (
            usage.position.x,
            usage.position.y,
            usage.rotation or 0.0,
            usage.scaleX or 0.0,
            usage.scaleY or 0.0,
        )
    )


def finite(polyline: list[tuple[float, float]]) -> bool:
    """Whether every point of a line's route is a finite point."""
    return all(math.isfinite(value) for point in polyline for value in point)


def footprint(usage: diagram.ShapeUsage) -> tuple[float, float] | None:
    """How far an arrow's shape reaches behind and ahead of its position, along the way it
    points (:func:`facing`): ``(behind, ahead)``, in sheet units. None for a usage that draws
    nothing to measure.

    Measured on the box around the shape as it is drawn (``diagram_toolkit.usage_extent``),
    which is the shape itself for an arrow along a sheet axis and a little more for one
    turned off it. The ``pyDEXPI_FlowArrowhead`` shape has its tip at its position, so it reaches
    its whole length behind and nothing ahead, and so does the reference P&ID's chevron
    (1.75 and 0). The Tennessee Eastman export's arrowhead is drawn about its position: 2.63
    each way.
    """
    box = usage_extent(usage)
    if box is None or usage.position is None:
        return None
    turn = math.radians(facing(usage))
    along = [
        (x - usage.position.x) * math.cos(turn) + (y - usage.position.y) * math.sin(turn)
        for x in (box.min_x, box.max_x)
        for y in (box.min_y, box.max_y)
    ]
    return max(0.0, -min(along)), max(0.0, *along)


def arrow_of(
    diagram_root: object, identifier: str
) -> list[tuple[diagram.ShapeUsage, diagram.PipeFlowArrow, diagram.RepresentationGroup]]:
    """The flow arrows an id names: ``(usage, the PipeFlowArrow group holding it, the drawing
    holding that group)`` for the usage with that id, or for every usage of the
    ``PipeFlowArrow`` group with that id. Empty when the id names neither.

    An arrow is drawing with two ids, the group's and its usage's; a client that selects one
    on the sheet has either.
    """
    return [
        entry for entry in flow_arrows(diagram_root) if identifier in (entry[0].id, entry[1].id)
    ]
