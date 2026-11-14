"""Read a drawing's strokes without following shared catalogue references into the model."""

from pydexpi.pydexpi_classes import (
    Label,
    Pipe,
    RepresentationGroup,
    ShapeUsage,
)


def drawing_elements(group, *, include_labels=False, include_children=False, _root=True):
    """Yield the elements of one drawing, optionally including annotations and child drawings."""
    if isinstance(group, Label) and not include_labels:
        return
    if isinstance(group, RepresentationGroup):
        if not _root and not include_children:
            return
        for child in group.groups:
            yield from drawing_elements(
                child, include_labels=include_labels, include_children=include_children, _root=False
            )
    else:
        yield from getattr(group, "elements", ())


def first_stroke(group, **options):
    """The first actual stroke in a drawing, including a used shape's primitives, or None."""
    for element in drawing_elements(group, **options):
        primitives = element.shape.primitives if isinstance(element, ShapeUsage) else [element]
        for primitive in primitives:
            stroke = getattr(primitive, "stroke", None)
            if stroke is not None:
                return stroke
    return None


def line_stroke(group, **options):
    """The first stroke a drawing's own lines are drawn with, or None.

    Like `first_stroke`, but a `ShapeUsage` is passed over: a symbol drawn on or beside a line
    (an off-page arrow, a tee, a flow arrow) is no part of the line, and its stroke is the
    symbol's, not the line's.
    """
    for element in drawing_elements(group, **options):
        if isinstance(element, ShapeUsage):
            continue
        stroke = getattr(element, "stroke", None)
        if stroke is not None:
            return stroke
    return None


def drawings(model):
    """Each drawn object's first drawing, by identity."""
    from pydexpi.toolkits.model_toolkit import get_all_instances_in_model

    drawings = {}
    for group in get_all_instances_in_model(model.diagram, (RepresentationGroup,)):
        if group.represents is not None:
            drawings.setdefault(id(group.represents), group)
    return drawings


def drawn_pipe_stroke(segment, drawings):
    """The first stroke a segment's pipes are drawn with, else its own group's, or None.

    Lines only (`line_stroke`): a segment's drawing also holds its flow arrows and the symbols
    of its items' drawings are its children, and none of them is drawn like the pipe.
    """
    for connection in segment.connections:
        if isinstance(connection, Pipe) and id(connection) in drawings:
            stroke = line_stroke(drawings[id(connection)])
            if stroke is not None:
                return stroke
    if id(segment) in drawings:
        return line_stroke(drawings[id(segment)])
    return None
