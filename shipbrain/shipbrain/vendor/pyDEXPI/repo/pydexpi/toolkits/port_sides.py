"""The side of its own symbol a drawn port lies on.

DEXPI stores no direction for a port: a ``NodePosition`` is a point. A port's outward axis can
be read off the line drawn to it (``routing.port_axis``), which is right for every line a
draughtsman drew and wrong as soon as a line reaches its port along the edge of the symbol the
port is on: the "outward" axis is then the edge's. A block flow diagram's arrowhead, turned
with its line's last leg, then points along the block's side.

A port that lies on a side of the box around **its own symbol** has an outward axis that needs
no line to read it from: the normal of that side. Measured on every drawn file of the corpus,
it is the axis of the drawn leg wherever both can be read: at all 49 such line ends of each of
the two reference P&IDs, at 39, 8 and 2 of the Proteus training cases ``C01V04``, ``C02V03``
and ``C03V04``, and at 28 ends of the anchored Tennessee Eastman export, with none against.
The one file in which they differ shows which to believe: the vendor export
``pump_example_v2.xml`` starts seven of its pipes with a leg under a thousandth of a unit long
that reads as "down" beside a flange facing right.

:class:`PortSides` is that reader, built once for a drawing, and the one answer everything
that asks shares. It asks ``process_drawing.port_side`` for the side, so a port has one side
whoever asks. Nothing here changes a model.
"""

from __future__ import annotations

from typing import Any

from pydexpi.pydexpi_classes.core import diagram
from pydexpi.pydexpi_classes.plant import piping
from pydexpi.pydexpi_classes.pydexpi_classes import Port
from pydexpi.toolkits import routing
from pydexpi.toolkits.diagram_toolkit import Bounds, own_symbol_usages, symbol_extent
from pydexpi.toolkits.finite_geometry import NonFiniteGeometryError
from pydexpi.toolkits.process_drawing import SIDE_AXES, Side, port_side

__all__ = ["PortSides", "reached_from_within", "sides_at"]


def sides_at(bounds: Bounds, point: tuple[float, float], tolerance: float) -> list[Side]:
    """Every side of `bounds` that `point` lies on, within `tolerance`.

    One for a port in the run of a side, two for one at a corner, and two opposite ones for a
    symbol drawn as a single line, whose box has no width: a flange in the Proteus training
    case ``C03V04``. None for a point inside the box or off it.
    """
    x, y = point
    within_x = bounds.min_x - tolerance <= x <= bounds.max_x + tolerance
    within_y = bounds.min_y - tolerance <= y <= bounds.max_y + tolerance
    found: list[Side] = []
    if within_y and abs(x - bounds.min_x) <= tolerance:
        found.append("left")
    if within_y and abs(x - bounds.max_x) <= tolerance:
        found.append("right")
    if within_x and abs(y - bounds.min_y) <= tolerance:
        found.append("top")
    if within_x and abs(y - bounds.max_y) <= tolerance:
        found.append("bottom")
    return found


def reached_from_within(node_position: object, holder: object) -> bool:
    """Whether the line `holder` holds reaches `node_position` from inside the port's symbol.

    True for one end of one kind of line: the line of a delegation, at its super port. Its
    holder is the drawing of the delegated port (``process_drawing.delegation_lines``: a
    group that represents a ``Port``), and the end is the node position that shows the port
    this one delegates. The other end is the delegate's own port, which the line leaves
    outwards like any other.
    """
    delegate = getattr(holder, "represents", None)
    if not isinstance(delegate, Port):
        return False
    shown = getattr(node_position, "port", None)
    return shown is not None and shown is delegate.__dict__.get("superReference")


class PortSides:
    """Which symbol each drawn port of a drawing is on, and the outward axis that gives it.

    Built by one walk of the drawing. A port's symbol is that of the nearest drawing at or
    above the one holding its node position that draws a symbol of its own
    (``diagram_toolkit.own_symbol_usages``, so a flow arrow is none): the drawing itself for a
    block or an inline component drawn flat, the nozzle's for an imported
    ``RG(nozzle) -> RG(node)``. The climb stops at a piping segment or system, past which the
    nearest symbol is another object's -- what ``diagram_toolkit.port_symbol_group`` finds,
    for every port at once.
    """

    def __init__(self, diagram_root: object) -> None:
        self._symbol_group: dict[int, diagram.RepresentationGroup] = {}
        self._boxes: dict[int, Bounds | None] = {}

        def walk(group: object, nearest: diagram.RepresentationGroup | None) -> None:
            if not isinstance(group, diagram.RepresentationGroup):
                return
            if isinstance(
                getattr(group, "represents", None),
                (piping.PipingNetworkSegment, piping.PipingNetworkSystem),
            ):
                nearest = None
            elif own_symbol_usages(group):
                nearest = group
            if nearest is not None:
                for position in group.nodePositions:
                    self._symbol_group[id(position)] = nearest
            for subgroup in group.groups:
                walk(subgroup, nearest)

        for group in getattr(diagram_root, "groups", None) or []:
            walk(group, None)

    def symbol_group(self, node_position: object) -> diagram.RepresentationGroup | None:
        """The drawing whose symbol `node_position` is a port of, or None: a port of no
        symbol is a free end, an open end, a junction of lines."""
        return self._symbol_group.get(id(node_position))

    def axis(
        self,
        node_position: object,
        drawn: routing.Axis | None = None,
        holder: object = None,
    ) -> routing.Axis | None:
        """The axis a line leaves a port along: the normal of the side of its own symbol the
        port lies on, and `drawn`, the axis read off its line, where it lies on none.

        The normal is the outward one for every line outside the symbol, which is every line
        but one: the line of a delegation runs **inside** the block whose port it ends at,
        from that super port to the port of a step drawn within.
        It reaches the super port from within, so there its axis is the inward normal of the
        same side. `holder` is the group holding the line the axis is asked for; given the
        drawing of a delegated port, the end at that port's super port is read so
        (:func:`reached_from_within`). Without it every axis is the outward one, which is
        the port's side and what a line outside the symbol needs.

        The side is one of the box around the symbol when the port lies on exactly one, to
        within a thousandth of the box's size (``routing.AXIS_SNAP_TOLERANCE``: relative, as a
        drawing in metres has symbols a hundredth across). A port on the outline of a symbol
        that is no rectangle, inside its box, has the side it is seen from
        (``process_drawing.port_side``). A port at a corner of the box, or on a box without
        width, lies on two sides at once and none of them says more than its line does, so
        `drawn` stands; so it does for a port inside the symbol and for one on no symbol.

        And so it does for a port of a symbol that cannot be measured, because the symbol
        holds a number that is not finite. This classifies, and never raises: a symbol
        turned by a NaN has no box and so no sides. A caller that needs the box measures it
        itself, and is told.
        """
        group = self.symbol_group(node_position)
        position = getattr(node_position, "position", None)
        if group is None or position is None:
            return drawn
        try:
            return self._side_axis(group, node_position, position, drawn, holder)
        except NonFiniteGeometryError:
            self._boxes[id(group)] = None
            return drawn

    def _side_axis(
        self,
        group: diagram.RepresentationGroup,
        node_position: object,
        position: Any,
        drawn: routing.Axis | None,
        holder: object,
    ) -> routing.Axis | None:
        """:meth:`axis` for a port on a symbol; raises for a symbol that cannot be measured."""
        if id(group) not in self._boxes:
            self._boxes[id(group)] = symbol_extent(group)
        box = self._boxes[id(group)]
        if box is None:
            return drawn
        point = (position.x, position.y)
        tolerance = max(
            routing.POINT_TOLERANCE,
            routing.AXIS_SNAP_TOLERANCE * max(box.max_x - box.min_x, box.max_y - box.min_y),
        )
        on = sides_at(box, point, tolerance)
        if len(on) == 1:
            side: Side | None = on[0]
        elif on:
            return drawn
        else:
            side = port_side(group, point, tolerance=tolerance)
        if side is None:
            return drawn
        outward = SIDE_AXES[side]
        if reached_from_within(node_position, holder):
            return (-outward[0], -outward[1])
        return outward
