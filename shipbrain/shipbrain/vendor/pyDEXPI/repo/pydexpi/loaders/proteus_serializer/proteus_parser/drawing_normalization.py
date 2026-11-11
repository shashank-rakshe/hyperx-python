"""Normalization of Proteus drawing coordinates into pyDEXPI's canonical Y-down space.

Proteus/XMpLant files use a mathematical drawing coordinate system: origin at the
bottom-left of the sheet with Y increasing upward. pyDEXPI's canonical diagram space is
Y-down (like SVG, and like the DEXPI-native XML/JSON fixtures), so after parsing, every
drawing coordinate is flipped in place:

- Absolute (sheet-space) coordinates map through ``y -> (minY + maxY) - y`` using the
  drawing extents, keeping coordinates within the sheet frame.
- Shape-catalogue geometry is local to the shape origin and maps through ``y -> -y``.
- Ellipse-arc angles map through ``start', end' = -end, -start`` (mod 360): the flip
  reverses arc orientation, and the renderer draws from start to end in the
  positive-angle (clockwise on screen) direction.
- Rotations are untouched: the position parser already stores angles negated relative to
  the model's counter-clockwise convention (``(360 - atan2(...)) % 360``), which is
  exactly the Y-down-compatible convention.
"""

from __future__ import annotations

from pydexpi.pydexpi_classes.core import diagram as core_diagram
from pydexpi.pydexpi_classes.pydexpi_classes import EngineeringModel


def normalize_drawing_orientation(model: EngineeringModel) -> None:
    """Flip a freshly parsed Proteus model's drawing coordinates to Y-down, in place.

    Parameters
    ----------
    model : EngineeringModel
        The model produced by the Proteus parser. Its diagram and shape catalogues are
        mutated in place; models without graphical content are left untouched.
    """
    # getattr with defaults keeps this boundary utility working when the loader is
    # driven with test doubles that stub EngineeringModel without its data fields.
    diagram = getattr(model, "diagram", None)
    catalogues = getattr(model, "shapeCatalogues", None) or []
    if diagram is None and not catalogues:
        return

    # Sheet-frame flip constant: y -> offset - y maps [minY, maxY] onto itself. Without
    # extents, fall back to pure negation (the geometry is still oriented correctly; the
    # coordinates just end up negative).
    if diagram is not None and diagram.minY is not None and diagram.maxY is not None:
        offset = diagram.minY + diagram.maxY
    else:
        offset = 0.0

    seen: set[int] = set()

    for catalogue in catalogues:
        for shape in catalogue.shapes or []:
            _flip_shape_local(shape, seen)

    if diagram is not None:
        _flip_group(diagram, offset, seen)


def _flip_point(point: core_diagram.Point | None, offset: float, seen: set[int]) -> None:
    """Flip one point's y coordinate, at most once."""
    if point is None or id(point) in seen:
        return
    seen.add(id(point))
    point.y = offset - point.y


def _flip_node_position(
    node_position: core_diagram.NodePosition | None, offset: float, seen: set[int]
) -> None:
    if node_position is None or id(node_position) in seen:
        return
    seen.add(id(node_position))
    _flip_point(node_position.position, offset, seen)


def _flip_shape_local(shape: core_diagram.Shape | None, seen: set[int]) -> None:
    """Flip a catalogue shape's local geometry about its own origin."""
    if shape is None or id(shape) in seen:
        return
    seen.add(id(shape))
    for primitive in shape.primitives or []:
        _flip_primitive(primitive, 0.0, seen)


def _flip_primitive(primitive, offset: float, seen: set[int]) -> None:
    """Flip one graphical primitive in place, dispatching on its type."""
    if primitive is None or id(primitive) in seen:
        return
    seen.add(id(primitive))

    if isinstance(primitive, (core_diagram.PolyLine, core_diagram.Polygon)):
        for point in primitive.points or []:
            _flip_point(point, offset, seen)
    elif isinstance(primitive, core_diagram.EllipseArc):
        _flip_point(primitive.center, offset, seen)
        start, end = primitive.startAngle, primitive.endAngle
        primitive.startAngle = -end % 360.0
        primitive.endAngle = -start % 360.0
    elif isinstance(primitive, core_diagram.Ellipse):
        _flip_point(primitive.center, offset, seen)
    elif isinstance(primitive, core_diagram.Text):
        _flip_point(primitive.position, offset, seen)
    elif isinstance(primitive, core_diagram.ConnectorLine):
        _flip_node_position(primitive.source, offset, seen)
        _flip_node_position(primitive.target, offset, seen)
        for point in primitive.innerPoints or []:
            _flip_point(point, offset, seen)
    elif isinstance(primitive, core_diagram.ShapeUsage):
        _flip_point(primitive.position, offset, seen)
        # The referenced shape is local geometry; usually already flipped via the
        # catalogue walk, and the seen-set keeps this from flipping it twice.
        _flip_shape_local(primitive.shape, seen)


def _flip_group(group, offset: float, seen: set[int]) -> None:
    """Recursively flip a representation group tree in place."""
    if group is None or id(group) in seen:
        return
    seen.add(id(group))

    for node_position in getattr(group, "nodePositions", None) or []:
        _flip_node_position(node_position, offset, seen)
    for element in getattr(group, "elements", None) or []:
        _flip_primitive(element, offset, seen)
    for subgroup in getattr(group, "groups", None) or []:
        _flip_group(subgroup, offset, seen)
