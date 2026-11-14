"""Post-load cleanup for isolated PipeTee objects found in PlantEngineer Proteus data."""

from pydexpi.pydexpi_classes import PlantModel
from pydexpi.pydexpi_classes.plant import piping


def get_isolated_pipe_tees(conceptual_model: PlantModel) -> list[piping.PipeTee]:
    """Finds PipeTee objects with no piping attached to them at all.

    A valid PipeTee is a branch point: at least one PipingConnection or an external segment
    boundary (a different segment's sourceItem/targetItem) has to reference it, otherwise no
    flow actually passes through it. PlantEngineer Proteus data can contain PipeTee objects that
    were never wired in this way. These are considered bugs in the source data rather than valid
    degenerate tees, since a tee's entire purpose is to join flows.

    A boundary reference from a tee's own owning segment (segment.sourceItem/targetItem pointing
    at one of its own segment.items) does not count, as that only marks the segment's main
    inlet/outlet and is set even for perfectly ordinary segments.

    Parameters
    ----------
    conceptual_model : PlantModel
        The model to search for isolated tees.

    Returns
    -------
    list[piping.PipeTee]
        The isolated PipeTee objects found, in order of encounter.
    """
    all_tees: list[piping.PipeTee] = []
    referenced_ids: set[int] = set()

    for piping_network_system in conceptual_model.pipingNetworkSystems:
        for segment in piping_network_system.segments:
            all_tees.extend(item for item in segment.items if isinstance(item, piping.PipeTee))
            for connection in segment.connections:
                if connection.sourceItem is not None:
                    referenced_ids.add(id(connection.sourceItem))
                if connection.targetItem is not None:
                    referenced_ids.add(id(connection.targetItem))
            for boundary_item in (segment.sourceItem, segment.targetItem):
                if boundary_item is not None and not any(
                    boundary_item is item for item in segment.items
                ):
                    referenced_ids.add(id(boundary_item))

    return [tee for tee in all_tees if id(tee) not in referenced_ids]


def remove_isolated_pipe_tees(conceptual_model: PlantModel) -> list[piping.PipeTee]:
    """Removes PipeTee objects with no piping attached to them at all, see
    get_isolated_pipe_tees.

    Segments left with no items, no connections, and no source/target item after the removal
    (the common case, a segment that solely contained the isolated tee) are dropped too, as they
    no longer represent anything. A segment's own sourceItem/targetItem pointing at a removed tee
    (the usual convention for a single-item segment, where both equal that one item) is cleared
    before this check, otherwise such a segment would count as non-empty and get stranded.

    Not called automatically by the loader: callers decide whether and when to apply this
    cleanup to a loaded model.

    Parameters
    ----------
    conceptual_model : PlantModel
        The model to remove isolated tees from. Modified in place.

    Returns
    -------
    list[piping.PipeTee]
        The isolated PipeTee objects that were removed.
    """
    isolated_tees = get_isolated_pipe_tees(conceptual_model)
    isolated_ids = {id(tee) for tee in isolated_tees}

    for piping_network_system in conceptual_model.pipingNetworkSystems:
        for segment in piping_network_system.segments:
            segment.items = [item for item in segment.items if id(item) not in isolated_ids]
            if segment.sourceItem is not None and id(segment.sourceItem) in isolated_ids:
                segment.sourceItem = None
            if segment.targetItem is not None and id(segment.targetItem) in isolated_ids:
                segment.targetItem = None
        piping_network_system.segments = [
            segment
            for segment in piping_network_system.segments
            if segment.items
            or segment.connections
            or segment.sourceItem is not None
            or segment.targetItem is not None
        ]

    return isolated_tees
