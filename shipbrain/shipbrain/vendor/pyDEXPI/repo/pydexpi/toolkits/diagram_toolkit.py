import itertools
import math
from dataclasses import dataclass

from pydexpi.pydexpi_classes import (
    EngineeringModel,
    EquipmentBarLabel,
    GraphicalPrimitive,
    GraphicsGroup,
    NodePosition,
    PipingNode,
    PipingNodePosition,
    PyDexpiBaseModel,
    RepresentationGroup,
    RepresentationTypeGroup,
    ShapeUsage,
)
from pydexpi.pydexpi_classes.core import diagram
from pydexpi.pydexpi_classes.plant import piping
from pydexpi.toolkits.finite_geometry import (
    require_finite,
    require_finite_point,
    require_finite_points,
)
from pydexpi.toolkits.model_toolkit import get_objects_referencing
from pydexpi.toolkits.routing import Axis, polyline_of, snap_axis


def get_object_reference_group(group: RepresentationGroup, obj: PyDexpiBaseModel):
    """Recursively search for the RepresentationGroup that references the target object."""
    if isinstance(group, RepresentationGroup):
        if group.represents == obj:
            return group
        for subgroup in group.groups:
            result = get_object_reference_group(subgroup, obj)
            if result is not None:
                return result
    return None


def get_representation_group_of_object(engineering_model: EngineeringModel, obj: PyDexpiBaseModel):
    """Find the RepresentationGroup that represents the given object in the diagram.

    None when the object is not drawn, which includes every object of a model with no diagram
    at all: 32 of the 36 corpus files have none.
    """
    if engineering_model.diagram is None:
        return None
    for group in engineering_model.diagram.groups:
        target_group = get_object_reference_group(group, obj)
        if target_group is not None:
            return target_group
    return None


def own_symbol_usages(group) -> list[ShapeUsage]:
    """The ``ShapeUsage`` s that are the symbol of the object one group draws: the one reader.

    Those in the ``Static`` type groups directly under `group`, in drawing order. Nothing else
    is the drawn object's own symbol: a nested ``RepresentationGroup`` draws another object (an
    equipment's nozzle, a segment's valve, a step's sub-step), a ``Label`` annotates, and a
    ``Symbol`` -- a ``PipeFlowArrow``, an insulation or slope symbol -- decorates a drawing that
    is drawn by its lines and has no symbol.

    The reader of one group that never raises (:func:`own_symbol_usage`, which
    ``process_drawing.own_usage`` is) and the walk that finds the group holding a given usage
    (:func:`symbol_holder`) both read a group through this function, so they cannot disagree
    about a group that holds two usages or an object that is drawn twice.

    Parameters
    ----------
    group : GraphicsGroup
        A group of the drawing; anything that is not a ``RepresentationGroup`` holds no symbol.

    Returns
    -------
    list[ShapeUsage]
        The usages, empty for a group drawn without a symbol of its own.
    """
    if not isinstance(group, RepresentationGroup):
        return []
    return [
        element
        for subgroup in group.groups
        if isinstance(subgroup, diagram.Static)
        for element in subgroup.elements
        if isinstance(element, ShapeUsage)
    ]


def own_symbol_usage(group) -> ShapeUsage | None:
    """The first of :func:`own_symbol_usages`, or None: the symbol of one group, never raising.

    For a caller that holds one *group* and wants its symbol's rotation, mirroring or position.
    An object drawn twice has a symbol in each drawing; this reads only the group it is given.
    """
    usages = own_symbol_usages(group)
    return usages[0] if usages else None


def symbol_holder(diagram_root, usage) -> RepresentationGroup | None:
    """The ``RepresentationGroup`` whose own symbol `usage` is (:func:`own_symbol_usages`), by
    identity; None when no group under `diagram_root` holds it as its symbol."""

    def walk(group) -> RepresentationGroup | None:
        if any(element is usage for element in own_symbol_usages(group)):
            return group
        for subgroup in getattr(group, "groups", None) or []:
            if isinstance(subgroup, RepresentationGroup):
                found = walk(subgroup)
                if found is not None:
                    return found
        return None

    return walk(diagram_root) if isinstance(diagram_root, RepresentationGroup) else None


def get_shape_usage_in_group(group: GraphicsGroup):
    """Recursively search for the ShapeUsage in the given group."""
    # TODO currently it just returns the first shape usage found
    if isinstance(group, RepresentationTypeGroup):
        for element in group.elements:
            if isinstance(element, ShapeUsage):
                return element
    else:
        for sub_group in group.groups:
            shape_usage = get_shape_usage_in_group(sub_group)
            if shape_usage is not None:
                return shape_usage


def get_graphical_primitive_in_group(group: GraphicsGroup):
    """Recursively search for the ShapeUsage in the given group."""
    # TODO currently it just returns the first graphical primitive found
    if isinstance(group, RepresentationTypeGroup):
        for element in group.elements:
            if isinstance(element, GraphicalPrimitive):
                return element
    else:
        for sub_group in group.groups:
            graphical_primitive = get_graphical_primitive_in_group(sub_group)
            if graphical_primitive is not None:
                return graphical_primitive


def get_shape_usage_of_object(engineering_model: EngineeringModel, obj: PyDexpiBaseModel):
    """Find the ShapeUsage that represents the given object in the diagram."""
    target_group = get_representation_group_of_object(engineering_model, obj)
    shape_usage = get_shape_usage_in_group(target_group)
    if shape_usage is not None:
        return shape_usage
    return None


def get_node_position_from_node(group: GraphicsGroup, node: PipingNode) -> NodePosition | None:
    """Recursively search for the NodePosition in the given group that corresponds to the specified PipingNode."""
    if isinstance(group, RepresentationGroup):
        for node_position in group.nodePositions:
            if isinstance(node_position, PipingNodePosition) and node_position.node == node:
                return node_position
        for subgroup in group.groups:
            result = get_node_position_from_node(subgroup, node)
            if result is not None:
                return result
    return None


#: The stroke an imported drawing gives a signal line: red, dashed, 0.2 wide.
SIGNAL_LINE_STROKE = diagram.Stroke(
    color=diagram.Color(r=255, g=0, b=0), dashStyle=diagram.DashStyle.DASH, width=0.2
)


def port_outward_axis(group, node_position: NodePosition) -> Axis | None:
    """The outward axis of a port on a symbol: from the symbol's centre to the port.

    ``group`` is the RepresentationGroup that owns both the symbol and the port. None when the group
    has no symbol, or when the port does not sit on one of the symbol's cardinal axes -- a port with
    no axis of its own. Only for a port whose group owns the symbol: for a port drawn under a bare
    node group the nearest symbol may be tens of units away and the answer 180 degrees wrong, which
    is why ``routing.port_axis`` reads the axis from the line instead once one exists.
    """
    centre = find_reference_point(group)
    if centre is None:
        return None
    return snap_axis(node_position.position.x - centre[0], node_position.position.y - centre[1])


#: The stroke an imported drawing gives a process pipe: black, solid, 0.25 wide.
PIPE_LINE_STROKE = diagram.Stroke(
    color=diagram.Color(r=0, g=0, b=0), dashStyle=diagram.DashStyle.SOLID, width=0.25
)


def groups_enclosing(diagram_root, node_position: NodePosition) -> list[RepresentationGroup] | None:
    """The RepresentationGroups from the top of the diagram down to the one holding ``node_position``.

    Matched by identity, never equality: 20 coordinates in the reference drawing
    are shared between distinct node positions. None when the position is not
    drawn anywhere in ``diagram_root``.
    """
    path: list[RepresentationGroup] = []

    def walk(group) -> bool:
        if not isinstance(group, RepresentationGroup):
            return False
        path.append(group)
        if any(candidate is node_position for candidate in group.nodePositions):
            return True
        if any(walk(subgroup) for subgroup in group.groups):
            return True
        path.pop()
        return False

    if not any(walk(group) for group in getattr(diagram_root, "groups", [])):
        return None
    return path


def port_symbol_group(diagram_root, node_position: NodePosition) -> RepresentationGroup | None:
    """The RepresentationGroup whose symbol a port sits on, for :func:`port_outward_axis`.

    Finds the group holding ``node_position`` (:func:`groups_enclosing`), then
    climbs to the nearest group that draws a symbol directly, as a ``Static``
    child holding a ShapeUsage (:func:`own_symbol_usages`): the owning group itself for an inline component
    or an off-page connector, the equipment's for a nozzle drawn as
    ``RG(equipment) -> RG(nozzle) -> RG(node)``. Only ``Static`` groups count,
    because a ``PipeFlowArrow`` is a ShapeUsage too, and the climb stops at a
    piping segment or system, past which the nearest symbol belongs to
    something else. None when there is no such group: the port is then a free
    end.
    """
    path = groups_enclosing(diagram_root, node_position)
    if path is None:
        return None
    for group in reversed(path):
        if isinstance(group.represents, (piping.PipingNetworkSegment, piping.PipingNetworkSystem)):
            return None
        if own_symbol_usages(group):
            return group
    return None


#: GraphicsGroup subtypes holding annotation rather than symbol geometry. A
#: Label's sheet position is the draftsman's choice -- DEXPI stores it
#: absolutely, with no anchor or offset tying it to the symbol -- so it is not
#: part of the symbol's geometry and is measured apart from it.
#: Border is diagram-level and never nested under an item, but is listed for
#: the same reason.
ANNOTATION_GROUP_TYPES = (diagram.Label, diagram.Border)


def is_annotation_group(graphics_group) -> bool:
    """True if the group carries annotation geometry (a label or a table)."""
    return isinstance(graphics_group, ANNOTATION_GROUP_TYPES)


#: Labels whose place on the sheet is the sheet's and not their symbol's: an equipment's entry
#: in the *equipment bar*, the band of data tables along the sheet's edge. DEXPI 2.0.1 declares
#: ``EquipmentBarLabel`` without a description, so this is pyDEXPI's reading of the name and of
#: the specification's reference P&ID, whose five are exactly those tables, 128 to 225 sheet
#: units from the symbols they describe. They fill five cells of a grid, 90 by 26 each and 2
#: and 2.5 apart, and which cell a table has says nothing of where its equipment is drawn: the
#: exchanger at x 140 has the column at x 6 to 96, the pump at x 251 the one at x 98 to 188.
#:
#: So a table's place belongs to the sheet's layout and not to its equipment's symbol.
#:
#: The list is one class long on evidence: no corpus drawing shows where a
#: ``DeviceInformationLabel``, a ``TypicalInformationLabel`` or a ``VendorNameLabel`` is drawn,
#: and a class joins when a drawing shows it placed by the sheet.
#:
#: A ``Border`` is the sheet's frame and no label at all. It is an annotation group, and one
#: nested in another drawing belongs to the sheet like a table.
SHEET_PLACED_LABEL_TYPES = (EquipmentBarLabel, diagram.Border)


def is_sheet_placed_label(graphics_group) -> bool:
    """True if the label is placed by the sheet's layout, not beside what it annotates."""
    return isinstance(graphics_group, SHEET_PLACED_LABEL_TYPES)


def sheet_placed_labels(
    graphics_group,
) -> list[tuple[RepresentationGroup, RepresentationTypeGroup]]:
    """Every label the sheet places under `graphics_group`, with the group that holds it.

    The groups of :data:`SHEET_PLACED_LABEL_TYPES` among :func:`annotations_with_holders`:
    the labels whose place is the sheet's rather than that of the drawing holding them.
    `graphics_group` itself is never one of them.
    """
    return [
        (holder, label)
        for holder, label in annotations_with_holders(graphics_group)
        if is_sheet_placed_label(label)
    ]


def parent_group(diagram_root, group) -> RepresentationGroup | None:
    """The group whose ``groups`` list holds ``group``, by identity, or None.

    Walks ``RepresentationGroup.groups`` from ``diagram_root`` down, the only list that nests
    groups, and stops at the first holder. The root counts: a ``Diagram`` holds the top-level
    groups and the sheet's own labels itself. Identity, never equality: two labels of one class with
    the same text compare equal field by field.

    Parameters
    ----------
    diagram_root : RepresentationGroup or None
        Where to start, normally ``EngineeringModel.diagram``.
    group : GraphicsGroup
        The group to find the holder of, a ``Label`` included.

    Returns
    -------
    RepresentationGroup or None
        The holder, or None when ``group`` is not drawn under ``diagram_root``.
    """

    def walk(node) -> RepresentationGroup | None:
        for child in node.groups:
            if child is group:
                return node
            if isinstance(child, RepresentationGroup):
                found = walk(child)
                if found is not None:
                    return found
        return None

    return walk(diagram_root) if isinstance(diagram_root, RepresentationGroup) else None


def parent_groups(diagram_root) -> dict[int, RepresentationGroup]:
    """Map every group under ``diagram_root``, by ``id()``, to the group whose ``groups`` holds it.

    One walk answering :func:`parent_group` for any number of groups, for a caller that asks
    about several: the same depth-first order, and the first holder wins. The root is a holder
    but is held by nothing, so it is not a key.

    Parameters
    ----------
    diagram_root : RepresentationGroup or None
        Where to start, normally ``EngineeringModel.diagram``.

    Returns
    -------
    dict[int, RepresentationGroup]
        ``id(group)`` to its holder; empty when there is no diagram.
    """
    parents: dict[int, RepresentationGroup] = {}

    def walk(node) -> None:
        for child in node.groups:
            parents.setdefault(id(child), node)
            if isinstance(child, RepresentationGroup):
                walk(child)

    if isinstance(diagram_root, RepresentationGroup):
        walk(diagram_root)
    return parents


def reference_usage(graphics_group) -> ShapeUsage | None:
    """The first ShapeUsage found, depth first: the symbol whose position is the group's
    reference point (:func:`find_reference_point`).

    For a caller that has to name it, for instance when the reference point is not a finite
    point and the caller reports which symbol's position it is.
    """
    if isinstance(graphics_group, diagram.RepresentationTypeGroup):
        for element in graphics_group.elements:
            if isinstance(element, diagram.ShapeUsage):
                return element
    if isinstance(graphics_group, diagram.RepresentationGroup):
        for subgroup in graphics_group.groups:
            result = reference_usage(subgroup)
            if result is not None:
                return result
    return None


def find_reference_point(graphics_group) -> tuple[float, float] | None:
    """Return the position of the first ShapeUsage found: the group's reference point.

    The position as the model holds it, a NaN or an infinity included. A caller that computes
    with it asks :func:`reference_usage` and checks.
    """
    usage = reference_usage(graphics_group)
    return None if usage is None else (usage.position.x, usage.position.y)


def is_bare_line_drawing(group) -> bool:
    """Whether a drawing is a line with its flow arrows and nothing else.

    True for a ``RepresentationGroup`` that holds no node position and no nested drawing, and
    whose only ``ShapeUsage`` s sit in ``PipeFlowArrow`` groups: the drawing of a process
    connection (a ``Static`` with its line, a ``PipeFlowArrow`` with its arrowhead) and of a
    delegation. Both ends of such a line are node positions *other* drawings hold, so the
    drawing has no reference point of its own: its one symbol is an arrow on the line
    (``toolkits.flow_arrows``), and :func:`find_reference_point`, which takes the first
    ``ShapeUsage`` it meets, would name that arrow.

    False for every drawing of the reference P&ID: the seven whose first ``ShapeUsage`` is a
    flow arrow are segments and piping systems, which hold their pipes as nested drawings.
    """
    if not isinstance(group, RepresentationGroup) or group.nodePositions:
        return False
    arrows = 0
    for subgroup in group.groups:
        if isinstance(subgroup, RepresentationGroup):
            return False
        if is_annotation_group(subgroup):
            continue
        usages = sum(isinstance(element, ShapeUsage) for element in subgroup.elements)
        if usages and not isinstance(subgroup, diagram.PipeFlowArrow):
            return False
        arrows += usages
    return arrows > 0


#: Type groups whose symbols mark a line and are no symbol of an object: a flow arrow. Such
#: a mark belongs to its line, as the line's stroke and the text beside it do.
LINE_MARK_GROUP_TYPES = (diagram.PipeFlowArrow,)


def is_line_mark_group(graphics_group) -> bool:
    """Whether a type group holds marks on a line -- flow arrows -- rather than a symbol."""
    return isinstance(graphics_group, LINE_MARK_GROUP_TYPES)


def annotations_with_holders(
    graphics_group,
) -> list[tuple[RepresentationGroup, RepresentationTypeGroup]]:
    """Every annotation group under `graphics_group`, with the group that holds it.

    The groups of ANNOTATION_GROUP_TYPES, depth first, each beside the RepresentationGroup
    whose ``groups`` it sits in: the drawing it annotates. `graphics_group` itself is never one
    of them, so a label handed in directly yields nothing.
    """
    found: list[tuple[RepresentationGroup, RepresentationTypeGroup]] = []

    def walk(node) -> None:
        if not isinstance(node, diagram.RepresentationGroup):
            return
        for subgroup in node.groups:
            if is_annotation_group(subgroup):
                found.append((node, subgroup))
            else:
                walk(subgroup)

    walk(graphics_group)
    return found


def annotation_centre(annotation) -> tuple[float, float] | None:
    """The centre of the box around an annotation group's own points, or None if it has none.

    The points are what :func:`shape_extent` measures of a shape: the corners of polylines and
    polygons, the boxes of ellipses and the anchors of texts, in the sheet coordinates a label
    is drawn in: one point that stands for where a label is.

    A label that draws no such point but places symbols -- a flag or an arrow drawn as a
    ``ShapeUsage`` and nothing else -- is measured by where its symbols are placed, so it has
    a centre too.

    Raises
    ------
    NonFiniteGeometryError
        If one of those points is not finite: the centre of such points is no point.
    """
    box = annotation_extent(annotation)
    if box is None:
        return None
    return (box.min_x + box.max_x) / 2.0, (box.min_y + box.max_y) / 2.0


def annotation_extent(annotation) -> "Bounds | None":
    """The box around an annotation group's own points, or None if it has none.

    The box :func:`annotation_centre` is the centre of. A text counts by its anchor: the
    model holds no text widths, so a table is measured by its rulings and a label of one
    centred text is a point.

    Raises
    ------
    NonFiniteGeometryError
        If one of those points is not finite: a box of such points is no box.
    """
    elements = annotation.elements or []
    box = _primitive_extent(elements)
    if box is not None:
        return Bounds(*box)
    placed = [
        require_finite_point(element, "position", element.position)
        for element in elements
        if isinstance(element, diagram.ShapeUsage) and element.position is not None
    ]
    if not placed:
        return None
    xs, ys = [x for x, _y in placed], [y for _x, y in placed]
    return Bounds(min(xs), min(ys), max(xs), max(ys))


#: How far from 90 or 270 degrees an angle may lie and still count as that quarter turn: a
#: turn computed in floating point lands within this of the angle it was meant to reach.
ANGLE_TOLERANCE = 1e-9


def is_readable_rotation(rotation: float | None) -> bool:
    """Whether a text at `rotation` reads from the bottom or from the right of the sheet.

    ``Text.rotation`` is clockwise on the Y-down sheet, so a text at 0 degrees reads left to
    right and one at 270 reads upwards, from the right of the sheet. Those are the two a
    drawing is read from, and the only two the reference P&ID uses: 232 of its 245 texts are
    at 0 and the other 13 at 270. So a text reads properly at an angle in [270, 360) or in
    [0, 90): written to the right, or straight up. At 90 it reads downwards, from the left,
    and anywhere between 90 and 270 it is upside down.
    """
    angle = normalized_angle(rotation or 0.0)
    return angle < 90.0 - ANGLE_TOLERANCE or angle >= 270.0 - ANGLE_TOLERANCE


def drawing_extent(graphics_group) -> "Bounds | None":
    """The box of everything a drawing draws apart from its labels, or None if that is nothing.

    Its ports, its symbols (each by its footprint, :func:`usage_extent`, or by where it is
    placed when that cannot be measured), its lines with the ports they end at, and what is
    drawn straight into its type groups, at every depth: the picture the group draws.
    Annotation groups are left out.
    """
    found: Bounds | None = None

    def add(box: "Bounds | None") -> None:
        nonlocal found
        if box is not None:
            found = box if found is None else found.union(box)

    for x, y in drawn_points(graphics_group, footprints=add):
        add(Bounds(x, y, x, y))
    return found


def nearest_drawn_point(graphics_group, x: float, y: float) -> tuple[float, float] | None:
    """The point of a drawing nearest to (x, y), its labels apart; None if it draws nothing.

    A port, the place of a symbol, or the nearest point *on* a line or an outline, which for
    a line's number beside a long straight pipe is the foot of the perpendicular and not a
    far corner. It is what a label of a drawing without a symbol of its own annotates most
    closely.
    """
    best: tuple[float, tuple[float, float]] | None = None

    def offer(px: float, py: float) -> None:
        nonlocal best
        distance = math.hypot(px - x, py - y)
        if best is None or distance < best[0]:
            best = (distance, (px, py))

    def along(points: list[tuple[float, float]]) -> None:
        for (ax, ay), (bx, by) in itertools.pairwise(points):
            dx, dy = bx - ax, by - ay
            length = dx * dx + dy * dy
            t = 0.0 if length == 0.0 else ((x - ax) * dx + (y - ay) * dy) / length
            t = min(1.0, max(0.0, t))
            offer(ax + t * dx, ay + t * dy)

    for px, py in drawn_points(graphics_group, outlines=along):
        offer(px, py)
    return best[1] if best is not None else None


def drawn_points(graphics_group, footprints=None, outlines=None):
    """Yield every point a drawing draws, labels apart: the walk behind :func:`drawing_extent`
    and :func:`nearest_drawn_point`.

    A port, a symbol's place, a line's corners and ends, a polyline's points and an ellipse's
    centre. `footprints` is also handed each symbol's box (or None), and `outlines` each
    line's and polyline's points in order, for the caller that measures more than points.
    A label handed in directly draws nothing that is not label, and yields nothing.
    """
    if is_annotation_group(graphics_group):
        return
    if isinstance(graphics_group, diagram.RepresentationGroup):
        for node_position in graphics_group.nodePositions:
            if node_position.position is not None:
                yield node_position.position.x, node_position.position.y
        for subgroup in graphics_group.groups:
            if not is_annotation_group(subgroup):
                yield from drawn_points(subgroup, footprints, outlines)
        return
    for element in getattr(graphics_group, "elements", None) or []:
        points: list[tuple[float, float]] = []
        if isinstance(element, diagram.ShapeUsage):
            if element.position is not None:
                points.append((element.position.x, element.position.y))
            if footprints is not None:
                footprints(usage_extent(element))
        elif isinstance(element, diagram.ConnectorLine):
            points = polyline_of(element)
        elif isinstance(element, (diagram.PolyLine, diagram.Polygon)):
            points = [(point.x, point.y) for point in element.points or []]
        elif isinstance(element, (diagram.Ellipse, diagram.EllipseArc, diagram.Text)):
            place = element.center if hasattr(element, "center") else element.position
            if place is not None:
                points.append((place.x, place.y))
        if outlines is not None and len(points) > 1:
            outlines(points)
        yield from points


def normalized_angle(angle: float) -> float:
    """`angle` in [0, 360): a tiny negative angle rounds up to 360.0 under %, and -0.0 is 0.0.

    An angle normalised this way never lands on 360.0 or -0.0, which no renderer expects.
    """
    turned = angle % 360.0
    return 0.0 if turned >= 360.0 else turned + 0.0


def ellipse_half_extent(element) -> tuple[float, float]:
    """Half the width and height of the box enclosing a rotated ellipse.

    The whole ellipse, for an ``EllipseArc`` too: :func:`ellipse_arc_extent` is the box of
    what an arc draws, which is what a symbol's footprint is measured by. This is the
    box of the ellipse an arc lies on, which is what turning or scaling it is about.

    Raises
    ------
    NonFiniteGeometryError
        If a semi-axis or the rotation is not finite. ``math.cos`` raised a bare
        ``ValueError`` for an infinite rotation and returned NaN for a NaN one.
    """
    a = require_finite(element, "horizontalSemiAxis", element.horizontalSemiAxis)
    b = require_finite(element, "verticalSemiAxis", element.verticalSemiAxis)
    r = math.radians(require_finite(element, "rotation", element.rotation))
    cos, sin = math.cos(r), math.sin(r)
    return math.hypot(a * cos, b * sin), math.hypot(a * sin, b * cos)


def swept_arc_box(
    centre_x: float,
    centre_y: float,
    horizontal: float,
    vertical: float,
    rotation: float,
    start: float,
    sweep: float,
) -> tuple[float, float, float, float]:
    """The box of an elliptic arc, ``(min_x, min_y, max_x, max_y)``, from finite numbers.

    The point at parameter ``t`` is the centre plus ``R(rotation) (horizontal cos t,
    vertical sin t)``, as the SVG export places an arc's ends; ``t`` runs from
    ``start`` through ``sweep`` degrees (360 is the whole ellipse). The box is that of the
    two ends and of the parameters inside the sweep where x or y is extreme, which are found
    in the ellipse's own frame and so hold under any rotation: x is extreme where
    ``tan t = -(vertical sin r) / (horizontal cos r)``, y where ``tan t = (vertical cos r) /
    (horizontal sin r)``, each with its opposite ``t + 180``. Exact, not sampled.

    Reads nothing from a model and checks nothing: :func:`ellipse_arc_extent` is the
    measure of an arc a model holds, and the Proteus parser calls this in its own frame.
    """
    turn = math.radians(rotation)
    cos_r, sin_r = math.cos(turn), math.sin(turn)
    extremes = (
        math.degrees(math.atan2(-vertical * sin_r, horizontal * cos_r)),
        math.degrees(math.atan2(vertical * cos_r, horizontal * sin_r)),
    )
    angles = [start, start + sweep]
    angles.extend(
        angle
        for extreme in extremes
        for angle in (extreme, extreme + 180.0)
        if (angle - start) % 360.0 <= sweep
    )
    xs: list[float] = []
    ys: list[float] = []
    for angle in angles:
        t = math.radians(angle)
        x, y = horizontal * math.cos(t), vertical * math.sin(t)
        xs.append(centre_x + x * cos_r - y * sin_r)
        ys.append(centre_y + x * sin_r + y * cos_r)
    return min(xs), min(ys), max(xs), max(ys)


def ellipse_arc_extent(element) -> tuple[float, float, float, float] | None:
    """The box of what an ``EllipseArc`` or an ``Ellipse`` draws, in its own coordinates.

    ``(min_x, min_y, max_x, max_y)``, or None for one without a centre. An arc is measured
    by its sweep (:func:`swept_arc_box`): from ``startAngle`` to ``endAngle`` in the
    positive-angle direction (clockwise on the Y-down sheet, the SVG export's ``sweep=1``),
    angles in the ellipse's own frame, which ``rotation`` turns. An arc whose two angles name
    one direction (``startAngle == endAngle`` modulo 360) is the whole ellipse, as
    ``process_drawing`` traces its outline. An ``Ellipse`` is the whole ellipse, the box of
    :func:`ellipse_half_extent` about its centre.

    An arc used to count its whole ellipse into every extent: Tank1's heads on the
    reference P&ID are arcs of an ellipse 2.1 times as wide as its walls, so the tank's
    footprint was 2.1 times as wide as the tank.

    Raises
    ------
    NonFiniteGeometryError
        If the centre, a semi-axis, the rotation or (for an arc) an angle is not finite:
        the sweep is read from the angles, so a NaN one leaves no box.
    """
    centre = element.center
    if centre is None:
        return None
    centre_x, centre_y = require_finite_point(element, "center", centre)
    if not isinstance(element, diagram.EllipseArc):
        horizontal, vertical = ellipse_half_extent(element)
        return (
            centre_x - horizontal,
            centre_y - vertical,
            centre_x + horizontal,
            centre_y + vertical,
        )
    a = require_finite(element, "horizontalSemiAxis", element.horizontalSemiAxis)
    b = require_finite(element, "verticalSemiAxis", element.verticalSemiAxis)
    rotation = require_finite(element, "rotation", element.rotation)
    start = require_finite(element, "startAngle", element.startAngle)
    end = require_finite(element, "endAngle", element.endAngle)
    sweep = (end - start) % 360.0 or 360.0
    return swept_arc_box(centre_x, centre_y, a, b, rotation, start, sweep)


def shape_extent(shape: diagram.Shape) -> tuple[float, float, float, float] | None:
    """The bounding box of a Shape's own primitives, in shape coordinates.

    ``(min_x, min_y, max_x, max_y)``, or None when the shape carries nothing
    measurable. This is the symbol's *intrinsic* extent -- before a ShapeUsage
    places, rotates, mirrors or scales it -- which is what a scale factor is
    relative to, so no placement transform enters the calculation.

    Only geometry the model actually holds is measured. A Text contributes its
    anchor point and not its rendered width: that needs font metrics pyDEXPI
    does not have, and quietly guessing would make every size derived from it
    wrong. An EllipseArc contributes what it draws, the box of its sweep
    (:func:`ellipse_arc_extent`), not its whole ellipse.

    This is deliberately about a Shape rather than a drawn group: pyDEXPI does
    not choose sizes for symbols it cannot see, and a Shape's primitives
    are exactly the geometry it *can* see.
    """
    return _primitive_extent(shape.primitives or [])


def _primitive_extent(primitives) -> tuple[float, float, float, float] | None:
    """The box of graphical primitives, in the coordinates they are written in.

    What :func:`shape_extent` measures for a Shape, and :func:`symbol_extent`
    for primitives drawn directly into a symbol's own group (as Proteus imports
    do). A connector line is not one of these classes, so it is never measured.

    Raises
    ------
    NonFiniteGeometryError
        For the first point, centre, semi-axis, rotation or arc angle that is not finite.
        ``min`` and ``max`` keep or drop a NaN by its place in the list, so a box over
        one was a box of NaNs or a finite box of the points that came first; neither is an
        extent.
    """
    xs: list[float] = []
    ys: list[float] = []

    def add(x: float, y: float) -> None:
        xs.append(x)
        ys.append(y)

    for primitive in primitives:
        if isinstance(primitive, (diagram.PolyLine, diagram.Polygon)):
            require_finite_points(primitive, "points", primitive.points or [])
            for point in primitive.points or []:
                add(point.x, point.y)
        elif isinstance(primitive, (diagram.Ellipse, diagram.EllipseArc)):
            box = ellipse_arc_extent(primitive)
            if box is None:
                continue
            add(box[0], box[1])
            add(box[2], box[3])
        elif isinstance(primitive, diagram.Text) and primitive.position is not None:
            add(*require_finite_point(primitive, "position", primitive.position))

    if not xs:
        return None
    return min(xs), min(ys), max(xs), max(ys)


@dataclass(frozen=True)
class Bounds:
    """An axis-aligned box on the sheet: ``(min_x, min_y)`` to ``(max_x, max_y)``."""

    min_x: float
    min_y: float
    max_x: float
    max_y: float

    def intersects(self, other: "Bounds") -> bool:
        """Whether the two boxes share area. Touching edges do not count."""
        return (
            self.min_x < other.max_x
            and other.min_x < self.max_x
            and self.min_y < other.max_y
            and other.min_y < self.max_y
        )

    def expanded(self, clearance: float) -> "Bounds":
        """The box grown by *clearance* on every side (shrunk if negative)."""
        return Bounds(
            self.min_x - clearance,
            self.min_y - clearance,
            self.max_x + clearance,
            self.max_y + clearance,
        )

    def union(self, other: "Bounds") -> "Bounds":
        """The smallest box holding both."""
        return Bounds(
            min(self.min_x, other.min_x),
            min(self.min_y, other.min_y),
            max(self.max_x, other.max_x),
            max(self.max_y, other.max_y),
        )


#: Both scale factors below this and the SVG, PNG and PDF renderers draw a
#: usage as nothing (a transform that would round to ``scale(0.00,0.00)``).
HIDDEN_SCALE_THRESHOLD = 0.005


def usage_extent(usage: diagram.ShapeUsage) -> Bounds | None:
    """Where a placed symbol sits on the sheet: its shape's extent, transformed.

    The shape's own box (:func:`shape_extent`) has its four corners put through
    the ShapeUsage's placement in the order a renderer applies it, and the
    axis-aligned box of the result is returned: mirror (negate x) and scale,
    then rotate counterclockwise by ``rotation`` degrees in model coordinates, then
    translate to
    ``position``. A rotated box is therefore enclosed rather than traced, which
    is what an overlap check needs.

    None when the shape has nothing measurable, or when both scale factors are
    below :data:`HIDDEN_SCALE_THRESHOLD`: the renderers draw such a usage as
    nothing, so it occupies no area.

    Raises
    ------
    NonFiniteGeometryError
        If a scale factor, the position or the rotation of the usage, or a number of its
        shape's primitives, is not finite: the box of such a symbol is not a box. It
        was a bare ``ValueError`` for an infinite rotation and a box of NaNs for a NaN one.
    """
    own_x = require_finite(usage, "scaleX", usage.scaleX)
    own_y = require_finite(usage, "scaleY", usage.scaleY)
    if abs(own_x) < HIDDEN_SCALE_THRESHOLD and abs(own_y) < HIDDEN_SCALE_THRESHOLD:
        return None  # the renderers draw nothing for it
    local = shape_extent(usage.shape) if usage.shape is not None else None
    if local is None or usage.position is None:
        return None
    min_x, min_y, max_x, max_y = local
    scale_x = own_x * (-1.0 if usage.isMirrored else 1.0)
    scale_y = own_y
    at_x, at_y = require_finite_point(usage, "position", usage.position)
    angle = math.radians(require_finite(usage, "rotation", usage.rotation))
    cos, sin = math.cos(angle), math.sin(angle)
    xs: list[float] = []
    ys: list[float] = []
    for corner_x, corner_y in ((min_x, min_y), (min_x, max_y), (max_x, min_y), (max_x, max_y)):
        x, y = corner_x * scale_x, corner_y * scale_y
        xs.append(at_x + x * cos - y * sin)
        ys.append(at_y + x * sin + y * cos)
    return Bounds(min(xs), min(ys), max(xs), max(ys))


def symbol_extent(group) -> Bounds | None:
    """The footprint of the symbol a representation group draws for its own object.

    The union of :func:`usage_extent` over the ShapeUsages that draw the object
    itself, and of the primitives drawn directly into its own type groups (as
    Proteus imports draw them, already in sheet coordinates), and nothing else: labels and data tables (annotation groups), the
    groups of other objects nested under it (a nozzle, a valve on a line), and
    connector lines are left out. This is the area the symbol occupies, which is
    what placing something clear of it asks about; a label that overlaps a
    neighbour is a different, and usually harmless, matter.

    None when the group draws no measurable symbol of its own.
    """
    found: Bounds | None = None

    def visit(node, top: bool) -> None:
        nonlocal found
        if isinstance(node, diagram.RepresentationTypeGroup):
            if is_annotation_group(node):
                return
            for element in node.elements:
                if isinstance(element, diagram.ShapeUsage):
                    box = usage_extent(element)
                else:
                    # Drawn straight into the group, already in sheet
                    # coordinates: measured as they are, never transformed.
                    local = _primitive_extent([element])
                    box = Bounds(*local) if local is not None else None
                if box is not None:
                    found = box if found is None else found.union(box)
            return
        if isinstance(node, diagram.RepresentationGroup) and not top:
            return  # another object's own drawing
        for subgroup in getattr(node, "groups", None) or []:
            visit(subgroup, top=False)

    visit(group, top=True)
    return found


def static_extent(group) -> Bounds | None:
    """The footprint of what a group's own ``Static`` type groups draw, lines apart; None when
    they draw nothing measurable.

    Narrower than :func:`symbol_extent`, which also measures the ``Symbol`` type groups: a
    flow arrow, an insulation or a slope symbol decorates a drawing that is drawn by its
    lines and has no symbol of its own. This is the question "does this group place a symbol
    on the sheet", which a process connection's drawing -- a ``Static`` holding its line and
    a ``PipeFlowArrow`` holding its arrowhead -- answers with no, and an equipment's, a
    block's or an imported symbol's loose primitives with yes.

    A walk over ``Static`` groups of its own, beside :func:`own_symbol_usages`, on purpose:
    that one returns the usages, and this one also measures what is drawn straight into the
    group, which no usage holds.
    """
    found: Bounds | None = None
    for subgroup in getattr(group, "groups", None) or []:
        if not isinstance(subgroup, diagram.Static):
            continue
        for element in subgroup.elements:
            if isinstance(element, diagram.ShapeUsage):
                box = usage_extent(element)
            else:
                local = _primitive_extent([element])
                box = Bounds(*local) if local is not None else None
            if box is not None:
                found = box if found is None else found.union(box)
    return found


def object_extent(engineering_model: EngineeringModel, obj: PyDexpiBaseModel) -> Bounds | None:
    """The footprint of *obj*'s symbol on the sheet (:func:`symbol_extent`).

    None when the model has no diagram, the object is not drawn, or it is drawn
    without a measurable symbol. For many objects use :func:`object_extents`,
    which walks the diagram once.
    """
    group = get_representation_group_of_object(engineering_model, obj)
    return symbol_extent(group) if group is not None else None


def object_extents(engineering_model: EngineeringModel, objects=None) -> dict[str, Bounds]:
    """The footprint of every drawn object's symbol, by object id, in one walk.

    :func:`object_extent` finds an object's group by walking the diagram from
    the top, so calling it per object is quadratic on a large drawing. This
    indexes every representation group by the id of the object it represents
    once, then measures each. *objects* limits the answer to those objects;
    an object not drawn, or drawn without a measurable symbol, is left out.
    """
    if engineering_model.diagram is None:
        return {}
    wanted = None if objects is None else {obj.id for obj in objects}
    groups: dict[str, diagram.RepresentationGroup] = {}

    def index(node) -> None:
        if isinstance(node, diagram.RepresentationGroup):
            represented = getattr(node.represents, "id", None)
            if represented is not None and (wanted is None or represented in wanted):
                groups.setdefault(represented, node)
        for subgroup in getattr(node, "groups", None) or []:
            index(subgroup)

    for group in engineering_model.diagram.groups:
        index(group)
    extents: dict[str, Bounds] = {}
    for object_id, group in groups.items():
        box = symbol_extent(group)
        if box is not None:
            extents[object_id] = box
    return extents


def remove_unused_shapes(model) -> list[str]:
    """Remove every shape nothing in the model references, and any catalogue left empty.

    A cleanup to run on a document before handing it to someone else, typically
    on export. Shapes accumulate in `shapeCatalogues` without anything drawing
    them: an element is gone and its symbol stays, a library shape is superseded
    by a newer copy.
    None of that is wrong -- a catalogue may legitimately hold shapes nothing
    uses -- but an exported document is smaller and easier to read without them.

    **Mutates the model in place**, so run it on the copy being exported rather
    than on a stored document: removing a shape is not recorded anywhere.

    "Used" means referenced from anywhere in the model through a reference
    attribute, which is how a `ShapeUsage` holds its shape; being listed in a
    catalogue is composition, not use. A catalogue left with no shapes is
    removed too, since it carries nothing an importer could act on.

    Parameters
    ----------
    model : EngineeringModel
        The model to clean, in place.

    Returns
    -------
    list[str]
        The ids of the removed shapes, in catalogue order.
    """
    shapes = [shape for catalogue in model.shapeCatalogues for shape in catalogue.shapes]
    shape_ids = {id(shape) for shape in shapes}
    used: set[int] = set()
    # One traversal for all shapes, and none when there are no shapes to find;
    # empty catalogues are still swept below. A reference attribute holds one
    # object or a list of them, so both forms are read.
    for holder, attribute in get_objects_referencing(model, shapes) if shapes else []:
        value = getattr(holder, attribute, None)
        held = value if isinstance(value, list) else [value]
        used.update(id(item) for item in held if id(item) in shape_ids)

    removed: list[str] = []
    for catalogue in model.shapeCatalogues:
        kept = []
        for shape in catalogue.shapes:
            if id(shape) in used:
                kept.append(shape)
            else:
                removed.append(shape.id)
        catalogue.shapes = kept
    model.shapeCatalogues = [catalogue for catalogue in model.shapeCatalogues if catalogue.shapes]
    return removed
