"""How a nozzle is drawn on a P&ID: a stub from its owner's outline to its node, and a label.

A drawn nozzle in an imported P&ID is ``RG(nozzle) -> RG(node) -> PipingNodePosition``, a
``Static`` holding one ``ShapeUsage`` -- the stub, ``NOZZLE_SHAPE`` on both reference P&IDs --
and a ``NozzleStandardLabel`` showing its ``SubTagName``. The stub's origin sits on the owner's
outline and its far end on the node, and it is turned to face out from the side of the owner the
node lies on: rotation 0 on the right, 90 at the bottom, 180 on the left and 270 at the top, in
the sheet's Y-down coordinates. All 19 nozzles of the reference P&IDs are drawn so.

pyDEXPI chooses no symbols, so a nozzle's stub is described by what the sheet already holds:
the shape, scale and length of a nozzle drawn there (:func:`read_stub`), the owner's own first
and then the sheet's (:func:`stub_templates`). Nothing here changes a model.
"""

from __future__ import annotations

from dataclasses import dataclass

from pydexpi.pydexpi_classes.core import diagram
from pydexpi.pydexpi_classes.plant import processEquipment
from pydexpi.pydexpi_classes.pydexpi_classes import (
    AttributeRepresentation,
    Label,
    NoteTextLabel,
    Text,
    TextAlignment,
)
from pydexpi.toolkits.diagram_toolkit import (
    get_node_position_from_node,
    get_representation_group_of_object,
    normalized_angle,
    own_symbol_usage,
    own_symbol_usages,
    shape_extent,
    symbol_extent,
)
from pydexpi.toolkits.finite_geometry import NonFiniteGeometryError
from pydexpi.toolkits.label_toolkit import bare_attribute_name
from pydexpi.toolkits.model_toolkit import get_all_instances_in_model
from pydexpi.toolkits.process_drawing import SIDE_AXES, Side, port_side

__all__ = [
    "ANGLE_TOLERANCE",
    "SIDE_ROTATIONS",
    "NozzleLabelStyle",
    "NozzleStub",
    "finite",
    "node_point",
    "nozzle_owner",
    "nozzle_side",
    "outline_side",
    "read_stub",
    "stub_length",
    "stub_templates",
]

#: The rotation of a stub facing out of each side of its owner, in the sheet's Y-down
#: coordinates: what the reference P&IDs' 19 nozzles are drawn with.
SIDE_ROTATIONS: dict[Side, float] = {"right": 0.0, "bottom": 90.0, "left": 180.0, "top": 270.0}

#: Below this a stub's turn against the side it faces is no turn: read off a drawing, the angle
#: carries the rounding of the coordinates it was measured from.
ANGLE_TOLERANCE = 1e-6


@dataclass(frozen=True)
class NozzleLabelStyle:
    """How a drawn nozzle's ``SubTagName`` text is drawn, relative to its node.

    Attributes
    ----------
    label_class : type[Label]
        The class of the label group, ``NozzleStandardLabel`` on the reference P&IDs.
    offset : tuple[float, float]
        From the nozzle's node to the text's position, in sheet coordinates.
    font, size, alignment
        The text's, each None when the text holds none that could be drawn again -- a font that
        is not a string, a size that is not a finite number, no alignment, as a lenient load
        (``strict=False``) can leave them: the drawer then uses its own default for that one.
    """

    label_class: type[Label]
    offset: tuple[float, float]
    font: str | None
    size: float | None
    alignment: TextAlignment | None


@dataclass(frozen=True)
class NozzleStub:
    """The stub a drawn nozzle has, read off the sheet by :func:`read_stub`.

    Attributes
    ----------
    nozzle : Nozzle
        The nozzle it was read from.
    shape : Shape
        The shape its ``ShapeUsage`` references.
    scale_x, scale_y : float
        The usage's scale.
    length : float
        From the usage's position, on the owner's outline, to the node.
    side : Side
        The side of its owner it faces out from: the one its node lies beyond the usage on.
    turn : float
        The usage's rotation beyond facing out from `side`, normally 0.
    is_mirrored : bool
        The usage's mirroring.
    label : NozzleLabelStyle or None
        Its ``SubTagName`` text's style, or None when it shows none.
    """

    nozzle: processEquipment.Nozzle
    shape: diagram.Shape
    scale_x: float
    scale_y: float
    length: float
    side: Side
    turn: float
    is_mirrored: bool
    label: NozzleLabelStyle | None


def _side_of_axis(dx: float, dy: float) -> Side:
    """The side whose outward axis is nearest (dx, dy); a tie is a left or right side."""
    if abs(dx) >= abs(dy):
        return "right" if dx >= 0 else "left"
    return "bottom" if dy > 0 else "top"


def _node_position(group, nozzle) -> diagram.NodePosition | None:
    """The drawn position of the nozzle's first node, nested or flat, or None."""
    nodes = getattr(nozzle, "nodes", None) or []
    if not nodes:
        return None
    return get_node_position_from_node(group, nodes[0])


def _label_style(group, nozzle, node: diagram.Point) -> NozzleLabelStyle | None:
    """The style of the text in `group`'s labels that shows `nozzle`'s ``SubTagName``."""
    for label in group.groups:
        if not isinstance(label, Label) or isinstance(label, NoteTextLabel):
            continue
        for text in label.elements:
            if not isinstance(text, Text) or text.template is None or text.position is None:
                continue
            shows = any(
                isinstance(fragment, AttributeRepresentation)
                and fragment.object is nozzle
                and bare_attribute_name(fragment.attributeName or "") == "SubTagName"
                for fragment in text.template.fragments
            )
            if not shows:
                continue
            offset = (text.position.x - node.x, text.position.y - node.y)
            if not all(finite(value) for value in offset):
                # A label placed by a number that is not finite places no other.
                return None
            # Each of the text's own fields is copied only when it could be drawn again: a
            # lenient load keeps a Text without a font or with a size that is no number.
            font = getattr(text, "font", None)
            size = getattr(text, "size", None)
            alignment = getattr(text, "alignment", None)
            return NozzleLabelStyle(
                label_class=type(label),
                offset=offset,
                font=font if isinstance(font, str) and font else None,
                size=size if finite(size) and size > 0 else None,
                alignment=alignment if isinstance(alignment, TextAlignment) else None,
            )
    return None


def read_stub(model, nozzle) -> NozzleStub | None:
    """The stub `nozzle` is drawn with, or None for a nozzle drawn without exactly one.

    The nozzle's drawing must hold one symbol of its own (``own_symbol_usages``). The side it
    faces is read from where its node is drawn against the usage's position, so it holds for a
    nozzle on any owner, whatever the owner's symbol; for a nozzle whose node is not drawn (the
    reference P&IDs' manhole, ``Nozzle19``) from the usage's rotation, with the shape's own
    length, and its label is then measured from where that length ends.

    Parameters
    ----------
    model : EngineeringModel
        The model the nozzle is drawn in.
    nozzle : Nozzle
        A nozzle of `model`.

    Returns
    -------
    NozzleStub or None
        The stub, or None when the nozzle is not drawn, is drawn bare or by several symbols,
        or holds a number that is not finite.
    """
    group = get_representation_group_of_object(model, nozzle)
    if group is None:
        return None
    usages = own_symbol_usages(group)
    if len(usages) != 1:
        return None
    usage = usages[0]
    origin = usage.position
    if origin is None or not all(
        finite(value) for value in (origin.x, origin.y, usage.rotation, usage.scaleX, usage.scaleY)
    ):
        return None
    position = _node_position(group, nozzle)
    node = position.position if position is not None else None
    if node is not None and not (finite(node.x) and finite(node.y)):
        return None
    dx, dy = (node.x - origin.x, node.y - origin.y) if node is not None else (0.0, 0.0)
    length = (dx * dx + dy * dy) ** 0.5
    if length > 0:
        side = _side_of_axis(dx, dy)
    else:
        # A node drawn on the usage, or not drawn at all -- the reference P&IDs' manhole: the
        # stub faces the way its rotation turns it, and reaches its shape's own length.
        axis_x, axis_y = _rotation_axis(usage.rotation)
        if usage.isMirrored:
            axis_x, axis_y = -axis_x, -axis_y
        side = _side_of_axis(axis_x, axis_y)
    if node is None:
        length = stub_length(usage.shape, abs(usage.scaleX))
        axis_x, axis_y = SIDE_AXES[side]
        node = diagram.Point(x=origin.x + axis_x * length, y=origin.y + axis_y * length)
    turn = normalized_angle(usage.rotation - SIDE_ROTATIONS[side])
    if turn < ANGLE_TOLERANCE or 360.0 - turn < ANGLE_TOLERANCE:
        turn = 0.0
    return NozzleStub(
        nozzle=nozzle,
        shape=usage.shape,
        scale_x=usage.scaleX,
        scale_y=usage.scaleY,
        length=length,
        side=side,
        turn=turn,
        is_mirrored=bool(usage.isMirrored),
        label=_label_style(group, nozzle, node),
    )


def finite(value) -> bool:
    """Whether `value` is a number and finite: ``inf - inf`` and ``nan - nan`` are NaN."""
    return isinstance(value, int | float) and value - value == 0


def _rotation_axis(rotation: float) -> tuple[float, float]:
    """The axis of the nearest quarter turn to `rotation`."""
    quarter = round(normalized_angle(rotation) / 90.0) % 4
    return ((1, 0), (0, 1), (-1, 0), (0, -1))[quarter]


def stub_templates(model, owner=None) -> list[NozzleStub]:
    """The stubs of every drawn nozzle on the sheet: `owner`'s first, then the sheet's.

    In the order of ``owner.nozzles``, then in the order the model holds the other nozzles.
    Nozzles drawn bare or by several symbols are left out.
    """
    first = list(getattr(owner, "nozzles", None) or []) if owner is not None else []
    seen = {id(nozzle) for nozzle in first}
    others = [
        nozzle
        for nozzle in get_all_instances_in_model(model, processEquipment.Nozzle)
        if id(nozzle) not in seen
    ]
    stubs = (read_stub(model, nozzle) for nozzle in [*first, *others])
    return [stub for stub in stubs if stub is not None]


def nozzle_side(owner_group, point: tuple[float, float]) -> Side:
    """The side of its owner's symbol a nozzle's node at `point` faces out from.

    The side ``process_drawing.port_side`` reads for a point on the outline, so a nozzle has the
    side its port is read to have. For a point off the outline, the side of the owner's box it is
    nearest to, measured from the box's centre against the box's half sizes: a node drawn a stub's
    length out from a wall is beyond that wall. An owner with no measurable symbol -- drawn with
    the empty placeholder used when no symbol resolves -- has the side
    the point lies towards from the owner's reference point, its symbol's position.

    Parameters
    ----------
    owner_group : RepresentationGroup
        The owner's drawing.
    point : tuple[float, float]
        The node's position.

    Returns
    -------
    Side
        ``"right"`` for a point at the owner's own reference point, where no side is nearer.
    """
    try:
        box = symbol_extent(owner_group)
    except NonFiniteGeometryError:
        box = None
    x, y = point
    if box is not None and box.max_x > box.min_x and box.max_y > box.min_y:
        side = outline_side(owner_group, point)
        if side is not None:
            return side
        half_x, half_y = (box.max_x - box.min_x) / 2, (box.max_y - box.min_y) / 2
        centre_x, centre_y = box.min_x + half_x, box.min_y + half_y
        return _side_of_axis((x - centre_x) / half_x, (y - centre_y) / half_y)
    usage = own_symbol_usage(owner_group)
    reference = getattr(usage, "position", None)
    if reference is None:
        return "right"
    return _side_of_axis(x - reference.x, y - reference.y)


def outline_side(owner_group, point: tuple[float, float]) -> Side | None:
    """The side of its owner's outline `point` lies on, or None for a point off the outline.

    ``process_drawing.port_side``, for an owner whose symbol has a box with an area; None for an
    owner without one -- the empty placeholder -- or one holding a number that is not finite.
    A node on the outline is where its stub starts, not where it ends: a stub drawn from there
    puts the node at its far end.
    """
    try:
        box = symbol_extent(owner_group)
        if box is None or not (box.max_x > box.min_x and box.max_y > box.min_y):
            return None
        return port_side(owner_group, point)
    except NonFiniteGeometryError:
        return None


def stub_length(shape: diagram.Shape, scale_x: float) -> float:
    """How far a stub drawn with `shape` reaches along its own x axis: from its origin, on the
    owner's outline, to its far edge, where the node is. 0 for a shape with nothing measurable,
    or one drawn entirely behind its origin."""
    try:
        extent = shape_extent(shape)
    except NonFiniteGeometryError:
        return 0.0
    if extent is None:
        return 0.0
    return max(extent[2], 0.0) * scale_x


def nozzle_owner(model, nozzle):
    """The one equipment whose ``nozzles`` hold `nozzle`, by identity, or None."""
    owners = [
        owner
        for owner in get_all_instances_in_model(model, processEquipment.NozzleOwner)
        if any(held is nozzle for held in getattr(owner, "nozzles", None) or [])
    ]
    return owners[0] if len(owners) == 1 else None


def node_point(model, nozzle) -> tuple[float, float] | None:
    """Where `nozzle`'s first node is drawn, or None."""
    group = get_representation_group_of_object(model, nozzle)
    if group is None:
        return None
    position = _node_position(group, nozzle)
    if position is None or position.position is None:
        return None
    return (position.position.x, position.position.y)
