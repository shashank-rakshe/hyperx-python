"""
Dexpi Piping Toolkit
--------------------
This module contains functions and tools for the main piping concepts of a
dexpi model, mainly reading and checking piping network segments.

"""

import logging
from collections.abc import Callable, Iterable
from enum import Enum
from typing import Any, NamedTuple

from pydexpi.pydexpi_classes import EngineeringModel, PlantModel, PyDexpiBaseModel
from pydexpi.pydexpi_classes.plant import piping
from pydexpi.toolkits.model_toolkit import get_objects_referencing

logger = logging.getLogger(__name__)


class DexpiConnectionException(Exception):
    """Exception for dexpi piping, connection-related errors.

    Raised if a connection or reconnection is attempted that is invalid or may cause corrupt
    segments"""


class DexpiCorruptPipingSegmentException(Exception):
    """Exception raised if a segment is encountered that violates piping network segment convention."""


class PipingTraversalException(Exception):
    """Raised if an error occurs during traversal of connected piping components/items/segments."""


class PipingValidityCode(Enum):
    """
    Enumeration of validity codes for piping related objects.

    Attributes
    ----------
    VALID : int = 0
    INTERNAL_VIOLATION : int = 1
        Violation code for an internal violation in a pipingNetworkSegment.
        Examples are unconnected, loose pipes or items, interrupted segments.
    CONNECTION_CONVENTION_VIOLATION : int = 2
        Violation code if the connection convention regarding a
        pipingNetworkSegment and its pipingConnections is violated
    MULTIPLE_NODE_REFERENCE_VIOLATION : int = 3
        Violation of the convention that a node can only be referenced once
    """

    VALID = 0
    INTERNAL_VIOLATION = 1
    CONNECTION_CONVENTION_VIOLATION = 2
    MULTIPLE_NODE_REFERENCE_VIOLATION = 3


class PipingConnectionConvention(Enum):
    """Convention enumeration for creating connections for higher level piping
    tools where explicit assignment of source and target nodes/items becomes
    impractical.

    Attributes
    ----------
    IN_NODE_0_OUT_NODE_1 : int = 0
        Node with index 0 is used as main inlet, node with index one is main
        outlet
    USE_ITEMS : int = 1
        Use direct assignments to items
    """

    IN_NODE_0_OUT_NODE_1 = 0
    USE_ITEMS = 1


def segment_ends_in_connection(the_segment: piping.PipingNetworkSegment, as_source=False) -> bool:
    """Checks if a segment ends in a connection, as opposed to an item.

    Parameters
    ----------
    the_segment : PipingNetworkSegment
        The segment to be evaluated
    as_source : bool, optional
        Whether the segments source should be checked, by default False

    Returns
    -------
    bool
        True if the segment ends in a connection.
    """
    if not the_segment.connections:
        return False
    destination_item = the_segment.sourceItem if as_source else the_segment.targetItem
    return destination_item not in the_segment.items


def segments_are_connected(
    segment_a: piping.PipingNetworkSegment, segment_b: piping.PipingNetworkSegment
) -> bool:
    """Checks if two segments are connected by comparing their source and target items.

    Parameters
    ----------
    segment_a : PipingNetworkSegment
        The first segment to be checked.
    segment_b : PipingNetworkSegment
        The second segment to be checked.

    Returns
    -------
    bool
        True if the segments are connected, False otherwise.

    Raises
    ------
    ValueError
        If the two segments are the same, as they cannot be connected to themselves.
    """
    # Consistency check if the two segments are the same
    if segment_a == segment_b:
        raise ValueError("Segments are the same. Cannot check if they are connected.")
    # Check if any of the source or target items of one segment are present in the items of the other segment
    return (
        segment_a.sourceItem in segment_b.items
        or segment_a.targetItem in segment_b.items
        or segment_b.sourceItem in segment_a.items
        or segment_b.targetItem in segment_a.items
    )


def connect_piping_network_segment(
    piping_segment: piping.PipingNetworkSegment,
    connector_item: piping.PipingSourceItem | piping.PipingTargetItem,
    connector_node_index: int | None = None,
    as_source=False,
    force_reconnect=False,
) -> None:
    """
    Connects a piping network segment by inferring the pipe to reconnect.

    This is based on the assumption that a valid piping network segment has at
    most one unconnected incoming and at most one unconnected outflowing
    connection. Note that a valid piping network segment may end on a segment
    item like a valve, in which case there are no outgoing flow connections
    (same for input). In this case, a ValueError is raised. An Exception is also
    raised if the piping network segment is corrupted (i.e., has more than one
    inflowing or outflowing connection).

    Parameters
    ----------
    piping_segment : PipingNetworkSegment
        Piping segment to be reconnected.
    connector_item : Union[PipingSourceItem, PipingTargetItem]
        The connector object to which the segment will be connected.
        It can be either a PipingNode, PipingSourceItem, or PipingTargetItem.
    connector_node_index: int, optional
        Optionally, the index of the node of connector_item to be connected to,
        by default None
    as_source : bool, optional
        If True, the connection is established as source, else as target.
        Defaults to False.
    force_reconnect : bool, optional
        If False, raises an exception if the piping connection is already
        connected. Defaults to False.

    Returns
    -------
    None
        This function modifies the state of the piping segment and the
        connection but does not return any value.

    Raises
    ------
    DexpiConnectionException
        If the piping connection is already connected, and force_reconnect is
        False.
    ValueError
        If the piping network segment either has no unconnected output
        connection (or input connection if as_source) or has more than one such
        connections, in which case it is corrupted.
    DexpiCorruptPipingSegmentException
        If the segment to be connected is found to be corrupt
    """
    # Find last connection and item. Last item is None if its None alltogether
    # OR if it isnt among the segment items internally
    if piping_segment.connections:
        last_connection = find_final_connection(piping_segment, as_source=as_source)
        last_item = last_connection.sourceItem if as_source else last_connection.targetItem
        last_item = last_item if last_item in piping_segment.items else None

    # Manage case segment has no connection (is empty or consists of one item):
    else:
        last_connection = None
        if not piping_segment.items:
            last_item = None
        elif len(piping_segment.items) == 1:
            last_item = piping_segment.items[0]
        else:
            msg = (
                f"The segment {piping_segment} has multiple items but no "
                f"connections and may be corrupt"
            )
            raise DexpiCorruptPipingSegmentException(msg)

    # Determine if connection references an internal object, in which case a
    # a reconnection would be invalid and cause a corrupt segment
    if last_item is not None:
        msg = (
            f"Piping segment {piping_segment} references internal "
            f"object as {'source' if as_source else 'target'}. Reconnect "
            f"will cause corrupting the segment."
        )
        raise ValueError(msg)

    if connector_node_index is not None:
        connector_node = connector_item.nodes[connector_node_index]
    else:
        connector_node = None

    connect_piping_connection(
        connector_item,
        last_connection,
        piping_segment,
        connector_node,
        as_source,
        force_reconnect,
    )


def find_final_connection(
    the_segment: piping.PipingNetworkSegment, as_source: bool = False
) -> piping.PipingConnection:
    """Finds the first or last connection object in the_segment. It does so by
    comparing the source and target objects of the segment and the connections.
    Note that in a valid segment, these should be the first or final connection.
    However, this method includes some validity checks, so it is recommended to
    use this instead.

    Parameters
    ----------
    the_segment : pipingNetworkSegment
        The segment whose final connection is to befound.
    as_source : bool, optional
        If the first connection should be found, else last, by default False.

    Returns
    -------
    pipingConnection
        The first or last connection.

    Raises
    ------
    DexpiCorruptPipingSegmentException
        If no connection with the same source and target info as the segment is
        found.
    """
    if not the_segment.connections:
        raise ValueError(f"Segment {the_segment} doesn't have any connections")
    final_connection = None
    # Find the connection with the same source/target info as segment
    for connection in the_segment.connections:
        if as_source:
            if connection.sourceItem is the_segment.sourceItem:
                final_connection = connection
        elif connection.targetItem is the_segment.targetItem:
            final_connection = connection
    # Raise exception if None was found
    if final_connection is None:
        msg = (
            f"Piping segment {the_segment} has no connections with the same "
            f"{'source' if as_source else 'target'} and may be corrupt."
        )
        raise DexpiCorruptPipingSegmentException(msg)

    final_connection_index = the_segment.connections.index(final_connection)
    what_index_should_be = 0 if as_source else len(the_segment.connections) - 1
    if final_connection_index != what_index_should_be:
        msg = (
            f"The final connection found in segment {the_segment} is not in the"
            f"correct position {'0' if as_source else '-1'}."
        )
        raise DexpiCorruptPipingSegmentException(msg)

    return final_connection


def get_unconnected_piping_segments(
    conceptual_model: PlantModel, as_source=False
) -> list[piping.PipingNetworkSegment]:
    """
    Returns a list of unconnected piping segments ending in a connection in the conceptual model.

    Parameters
    ----------
    conceptual_model : ConceptualModel
        The model to be analyzed.
    as_source : bool, optional
        Whether to look for unconnected sources or targets in piping segments.
        Defaults to False.

    Returns
    -------
    list[PipingNetworkSegment]
        The list of identified unconnected segments.
    """
    unconnected_segments = []
    for piping_network_system in conceptual_model.pipingNetworkSystems:
        for piping_network_segment in piping_network_system.segments:
            if as_source:
                if piping_network_segment.sourceItem is None:
                    unconnected_segments.append(piping_network_segment)
            elif piping_network_segment.targetItem is None:
                unconnected_segments.append(piping_network_segment)

    return unconnected_segments


def traverse_items_and_connections(
    all_items: list[piping.PipingNetworkSegmentItem],
    all_connections: list[piping.PipingConnection],
    start_element: piping.PipingNetworkSegmentItem | piping.PipingConnection,
    end_condition: piping.PipingNetworkSegmentItem
    | piping.PipingConnection
    | Callable[[piping.PipingNetworkSegmentItem | piping.PipingConnection], bool],
    reverse=False,
) -> list[piping.PipingNetworkSegmentItem | piping.PipingConnection]:
    """
    Traverses piping items and connections until the end condition is met.

    The traversal is done in a depth-first manner, starting from the specified start element.
    Branching decisions are inferred from the order of the connections in the list of all connections.
    Branches that start with connections that are higher in the list are traversed first.
    The traversal can be done in reverse order by setting the reverse parameter to True.

    Parameters
    ----------
    all_items : list[piping.PipingNetworkSegmentItem]
        List of all items in the piping network segment.
    all_connections : list[piping.PipingConnection]
        List of all connections in the piping network segment.
    start_element : piping.PipingNetworkSegmentItem|piping.PipingConnection
        The element from which to start the traversal.
    end_condition : piping.PipingNetworkSegmentItem|piping.PipingConnection|
                    Callable[[piping.PipingNetworkSegmentItem|piping.PipingConnection], bool]
        The condition that determines when to stop the traversal. This can be a specific element to
        be encountered or a callable function for more complex end conditions.
    reverse : bool, optional
        Whether to traverse in reverse order. Defaults to False.

    Returns
    -------
    list[piping.PipingNetworkSegmentItem|piping.PipingConnection]
        A list of traversed elements.

    Raises
    ------
    PipingTraversalException
        If a circle is encountered or if the traversal cannot continue due to invalid connections.
    """

    # Initialize the traversal
    traversed_elements: list[piping.PipingNetworkSegmentItem | piping.PipingConnection] = [
        start_element
    ]

    # Determine if the start element is a connection or an item
    if isinstance(start_element, piping.PipingNetworkSegmentItem):
        last_was_connection = False
        current_item = start_element
        current_connection = None
    elif isinstance(start_element, piping.PipingConnection):
        last_was_connection = True
        current_item = None
        current_connection = start_element
    else:
        raise TypeError(
            "start_element must be either a PipingNetworkSegmentItem or a PipingConnection"
        )

    # Check if the end condition is a callable function or a specific item/connection.
    # If it's a specific item/connection, create a function to check for equality.
    if isinstance(end_condition, piping.PipingNetworkSegmentItem | piping.PipingConnection):
        end_element = end_condition

        def end_condition_func(
            element: piping.PipingNetworkSegmentItem | piping.PipingConnection,
        ) -> bool:
            return element == end_element

        end_condition = end_condition_func

    if end_condition(start_element):
        return traversed_elements

    # Identity-keyed lookups, built once. `in` against a list of DEXPI objects runs
    # pydantic's inherited deep field comparison against every element (see the Traps
    # section of AGENTS.md), and this function did that on every traversal step, which
    # made it quadratic in the size of the segment.
    all_item_ids = {id(item) for item in all_items}
    traversed_ids = {id(start_element)}

    # Connections indexed by the item they leave from. Keyed on the same attribute the
    # per-step scan used, so the traversal direction is unchanged. A connection whose
    # origin is None was never matched by that scan either, so it is simply not indexed.
    connections_by_origin: dict[int, list[piping.PipingConnection]] = {}
    for connection in all_connections:
        origin = connection.sourceItem if not reverse else connection.targetItem
        if origin is not None:
            connections_by_origin.setdefault(id(origin), []).append(connection)

    # Begin the traversal loop
    while True:
        # Case: Next is an item (if last_was_connection is True)
        if last_was_connection:
            # Get next item
            next_item = (
                current_connection.targetItem if not reverse else current_connection.sourceItem
            )

            # Check if the next item is invalid for further traversal
            if next_item is None:
                msg = f"The connection has no {'source' if reverse else 'target'} item. Cannot traverse further."
                raise PipingTraversalException(msg)
            if id(next_item) not in all_item_ids:
                msg = "The target item is not in the list of all items. Cannot traverse further."
                raise PipingTraversalException(msg)
            if id(next_item) in traversed_ids:
                msg = "Circle encountered: The target item has already been traversed. Cannot traverse further."
                raise PipingTraversalException(msg)

            # Append the next item to the traversed elements
            traversed_elements.append(next_item)
            traversed_ids.add(id(next_item))
            current_item = next_item
            last_was_connection = False

            # Check if the end condition is met. If so, break the loop.
            if end_condition(current_item):
                break

        else:
            # Find all connections originating from the current item. The index
            # preserves the order of all_connections, which is what decides which
            # branch is tried first.
            next_connections = connections_by_origin.get(id(current_item), [])

            # If no connections are found, traversal cannot continue
            if not next_connections:
                msg = "The item has no source connections. Cannot traverse further."
                raise PipingTraversalException(msg)

            # If multiple connections are found, handle branching
            elif len(next_connections) > 1:
                branch_traversal = None
                # A count, not the exceptions themselves: this function is recursive, so
                # retaining a rejected branch's exception would retain its traceback, the
                # frames of the recursive call, and those frames' own locals -- compounding
                # at every level of a deeply branched network. The reason each branch was
                # rejected is logged as it happens; only the count is needed afterwards.
                rejected_branch_count = 0

                # Filter out already traversed items and connections. Hoisted out of
                # the branch loop below: traversed_elements does not change inside it,
                # so both lists were being rebuilt identically for every candidate.
                remaining_items = [item for item in all_items if id(item) not in traversed_ids]
                remaining_connections = [
                    con for con in all_connections if id(con) not in traversed_ids
                ]

                # Attempt to traverse each branch until a valid path is found
                for connection in next_connections:
                    try:
                        # Recursively traverse the branch
                        branch_traversal = traverse_items_and_connections(
                            remaining_items, remaining_connections, connection, end_condition
                        )
                        # Stop if a valid branch is found
                        break

                    except PipingTraversalException as branch_error:
                        # Each rejected branch is the only explanation of why the traversal
                        # as a whole failed, and the exception raised below cannot carry all
                        # of them. Without this, a caller debugging a failed traversal sees
                        # "No valid branch found" and nothing about what was tried.
                        rejected_branch_count += 1
                        logger.debug(
                            "Branch via connection %s rejected: %s",
                            getattr(connection, "id", connection),
                            branch_error,
                        )
                        continue

                # If a valid branch is found, append it to the traversed elements. Otherwise, raise
                # an exception.
                if branch_traversal is not None:
                    return traversed_elements + branch_traversal
                else:
                    msg = (
                        f"No valid branch found. Cannot traverse further. "
                        f"{rejected_branch_count} branch(es) were tried and rejected; "
                        f"enable DEBUG logging on 'pydexpi' for the reason each was rejected."
                    )
                    raise PipingTraversalException(msg)

            # If only one connection is found, continue traversal
            else:
                next_connection = next_connections[0]

                # Check for circular references
                if id(next_connection) in traversed_ids:
                    msg = "Circle encountered: The connection has already been traversed. Cannot traverse further."
                    raise PipingTraversalException(msg)

            # Append the next connection to the traversed elements
            traversed_elements.append(next_connection)
            traversed_ids.add(id(next_connection))
            current_connection = next_connection
            last_was_connection = True

            # Check if the end condition is met. If so, break the loop.
            if end_condition(current_connection):
                break

    # Return the list of traversed elements
    return traversed_elements


def sort_connected_items_and_connections(
    items: list[piping.PipingNetworkSegmentItem], connections: list[piping.PipingConnection]
) -> tuple[list[piping.PipingNetworkSegmentItem], list[piping.PipingConnection]]:
    """
    Sorts the items and connections of a piping network segment in the order of occurrence.

    Parameters
    ----------
    items : list[piping.PipingNetworkSegmentItem]
        The list of items to be sorted.
    connections : list[piping.PipingConnection]
        The list of connections to be sorted.

    Returns
    -------
    tuple[list[piping.PipingNetworkSegmentItem], list[piping.PipingConnection]]
        A tuple containing the sorted items and connections.

    Raises
    ------
    ValueError
        If the segment is not validly connected, such as having multiple starting points
        or disconnected elements.
    """
    # Identity-keyed lookups, built once. Each of the four searches below tested
    # membership with `in` against a list of DEXPI objects, which runs pydantic's
    # inherited deep field comparison per element (see the Traps section of
    # AGENTS.md); the two item searches additionally rebuilt their comparison list
    # from scratch on every iteration. `None` is absent from all three sets, which
    # matches the old behaviour: a null source or target never compared equal to a
    # real item either.
    item_ids = {id(item) for item in items}
    connection_source_ids = {
        id(connection.sourceItem) for connection in connections if connection.sourceItem is not None
    }
    connection_target_ids = {
        id(connection.targetItem) for connection in connections if connection.targetItem is not None
    }

    # Find the starting element (either an item or a connection)
    start_element = None
    for connection in connections:
        if id(connection.sourceItem) not in item_ids:
            if start_element is None:
                start_element = connection
            else:
                raise ValueError(
                    "Multiple connections found with no source item. Segment is not validly connected."
                )
    if start_element is None:
        for item in items:
            if id(item) not in connection_target_ids:
                if start_element is None:
                    start_element = item
                else:
                    raise ValueError(
                        "Multiple items found that are not referenced by any connection. "
                        "Segment is not validly connected."
                    )

    if start_element is None:
        raise ValueError("No valid starting element found. Segment is not validly connected.")

    # Find end element (either an item or a connection)
    end_element = None
    for connection in connections:
        if id(connection.targetItem) not in item_ids:
            if end_element is None:
                end_element = connection
            else:
                raise ValueError(
                    "Multiple connections found with no target item. Segment is not validly connected."
                )
    if end_element is None:
        for item in items:
            if id(item) not in connection_source_ids:
                if end_element is None:
                    end_element = item
                else:
                    raise ValueError(
                        "Multiple items found that are not referenced as a source by any connection. "
                        "Segment is not validly connected."
                    )

    if end_element is None:
        raise ValueError("No valid ending element found. Segment is not validly connected.")

    # Traverse the segment to determine the order of items and connections
    try:
        traversed_elements = traverse_items_and_connections(
            items, connections, start_element, end_element
        )
    except PipingTraversalException as e:
        raise ValueError(f"Traversal failed: {e}") from e

    # Separate the traversed elements into items and connections
    ordered_items = [
        element
        for element in traversed_elements
        if isinstance(element, piping.PipingNetworkSegmentItem)
    ]
    ordered_connections = [
        element for element in traversed_elements if isinstance(element, piping.PipingConnection)
    ]

    if len(ordered_items) != len(items):
        raise ValueError("Not all items were visited in the segment.")
    if len(ordered_connections) != len(connections):
        raise ValueError("Not all connections were visited in the segment.")

    return ordered_items, ordered_connections


def _flow_links(
    segment: piping.PipingNetworkSegment,
) -> tuple[list, Callable[[Any], list]]:
    """A segment's members, and what each one leads to inside the segment. Read-only.

    The members are its items then its connections, as listed. An item leads to the
    connections of the segment that leave it (``sourceItem``); a connection leads to
    its ``targetItem`` when that is one of the segment's items, and to nothing when
    it ends outside the segment or nowhere. Identity throughout, never equality.
    The one definition :func:`segment_chain` and :func:`segment_ends` share.
    """
    items = list(segment.items)
    connections = list(segment.connections)
    item_ids = {id(item) for item in items}

    def successors(element) -> list:
        if id(element) in item_ids:
            return [c for c in connections if c.sourceItem is element]
        target = element.targetItem
        return [target] if target is not None and id(target) in item_ids else []

    return items + connections, successors


class SegmentEnds(NamedTuple):
    """Where a segment's items and connections start and end; see :func:`segment_ends`."""

    starts: list[piping.PipingNetworkSegmentItem | piping.PipingConnection]
    ends: list[piping.PipingNetworkSegmentItem | piping.PipingConnection]


def segment_ends(segment: piping.PipingNetworkSegment) -> SegmentEnds:
    """The elements a segment starts and ends at, read from its connections alone. Read-only.

    A *start* is an element nothing inside the segment leads to: one of its items
    that none of its connections enters, or one of its connections whose
    ``sourceItem`` is not an item of the segment (an item outside it, or none). An
    *end* is the converse: an item none of its connections leaves, or a connection
    whose ``targetItem`` is not an item of the segment. These are the starts and
    ends :func:`segment_chain` looks for, but nothing here requires the segment to
    be one linear chain: a segment that branches has several ends, one that joins
    several starts, and a closed loop none. List order is never consulted.

    Parameters
    ----------
    segment : PipingNetworkSegment
        The segment to read.

    Returns
    -------
    SegmentEnds
        ``starts`` and ``ends``, each element once, items before connections and
        otherwise in list order. Both empty for an empty segment.
    """
    members, successors = _flow_links(segment)
    unique = list({id(member): member for member in members}.values())
    led_to = {id(successor) for member in unique for successor in successors(member)}
    return SegmentEnds(
        starts=[member for member in unique if id(member) not in led_to],
        ends=[member for member in unique if not successors(member)],
    )


def segment_chain(
    segment: piping.PipingNetworkSegment,
) -> list[piping.PipingNetworkSegmentItem | piping.PipingConnection]:
    """One segment's items and connections, interleaved in flow order. Read-only.

    The order runs from the segment's source to its target and is derived from
    the connections' ``sourceItem`` / ``targetItem``, never from list order, so
    an imported segment whose lists are shuffled still yields its chain. Every
    ``PipingConnection`` counts (a ``DirectPipingConnection`` as much as a
    ``Pipe``), and both endpoint forms are understood: a segment may start or end
    at one of its own items, or with a connection to an item outside it (or to
    none). The start is the single element nothing inside the segment leads to.

    The segment is left as it is.

    Parameters
    ----------
    segment : PipingNetworkSegment
        The segment to walk.

    Returns
    -------
    list[PipingNetworkSegmentItem | PipingConnection]
        The segment's members in flow order. Empty for an empty segment.

    Raises
    ------
    DexpiCorruptPipingSegmentException
        When the segment is not one linear chain: an element listed twice, an
        item with two outgoing connections, an element with two predecessors,
        a cycle, or elements the walk from the start never reaches. A corrupt
        segment is refused rather than guessed at.
    """
    members, successors = _flow_links(segment)
    if len({id(member) for member in members}) != len(members):
        raise DexpiCorruptPipingSegmentException(
            f"Segment {segment.id!r} lists an item or connection twice."
        )

    led_to: set[int] = set()
    for element in members:
        following = successors(element)
        if len(following) > 1:
            raise DexpiCorruptPipingSegmentException(
                f"Segment {segment.id!r} branches at {element.id!r}; it is not one linear chain."
            )
        for successor in following:
            if id(successor) in led_to:
                raise DexpiCorruptPipingSegmentException(
                    f"Segment {segment.id!r} joins at {successor.id!r}; it is not one linear chain."
                )
            led_to.add(id(successor))
    if not members:
        return []
    starts = [element for element in members if id(element) not in led_to]
    if len(starts) != 1:
        raise DexpiCorruptPipingSegmentException(
            f"Segment {segment.id!r} has {len(starts)} starts; it is not one linear chain."
        )

    chain: list[piping.PipingNetworkSegmentItem | piping.PipingConnection] = []
    seen: set[int] = set()
    element = starts[0]
    while element is not None:
        if id(element) in seen:
            raise DexpiCorruptPipingSegmentException(f"Segment {segment.id!r} contains a cycle.")
        seen.add(id(element))
        chain.append(element)
        following = successors(element)
        element = following[0] if following else None
    if len(chain) != len(members):
        raise DexpiCorruptPipingSegmentException(
            f"Segment {segment.id!r} has elements not connected to its chain."
        )
    return chain


def run_items(
    model: EngineeringModel,
    start: piping.PipingNetworkSegment | piping.PipingNetworkSegmentItem,
    *,
    across_segments: bool = True,
) -> list[piping.PipingNetworkSegmentItem]:
    """The items along a line, in flow order, from `start` to the line's end. Read-only.

    Within a segment the order is :func:`segment_chain`'s: source to target. At
    the segment's end the walk carries on into the segment that starts on the
    **same item and the same node object** the previous one ends on, and only
    that one. That is how DEXPI encodes a run split at an item: at a tee the
    trunk ends on the tee's run outlet and the continuation starts on that same
    node, while a branch leaves from another node of the tee -- so the walk
    follows the run and never the branch. The same holds where a run was split at
    any other item (a valve, a reducer). The continuation may lie in another
    piping network system.

    The walk stops where nothing continues the line: an open end, a nozzle, or an
    item no segment starts from on that node (a branch joining another line ends
    there too). That stop needs an item that can be a branch point. At an item with
    no more than two nodes, a segment leaving from another node continues the line,
    so the walk raises there rather than return part of the line as the whole; an
    item with more nodes is taken as a possible branch point and the walk stops.
    Items outside every segment, such as the nozzles at a line's two
    ends, are not listed. The walk only goes downstream; it never steps back
    upstream of `start`.

    Parameters
    ----------
    model : EngineeringModel
        The model holding the line.
    start : PipingNetworkSegment | PipingNetworkSegmentItem
        Where the walk starts. A segment starts at its first item; an item, which
        must be one of a segment's ``items``, starts at itself and is listed first.
    across_segments : bool, optional
        Carry on into continuation segments, through tees along the run.
        ``False`` stops at the end of the segment the walk starts in. Defaults to
        ``True``.

    Returns
    -------
    list[PipingNetworkSegmentItem]
        The items in flow order, each once. Empty for a segment without items
        that nothing continues.

    Raises
    ------
    TypeError
        If `start` is neither a segment nor a segment item.
    ValueError
        If `start` is not a segment of the model, or not an item of one of its
        segments.
    DexpiCorruptPipingSegmentException
        If a segment on the way is not one linear chain (see :func:`segment_chain`).
    PipingTraversalException
        If the run is ambiguous: two segments start on the node a segment ends on,
        a segment ends at an item without naming the node while segments start
        from that item, a segment starting from that item names no node, or the
        walk comes back to a segment or item it already passed (a cycle). Also
        when segments leave the item a segment ends at, none starts on the node it
        ends on, and the item has no more than two nodes: the line goes on there,
        but the model names two nodes for the junction, so the walk refuses rather
        than return the line cut short.
    """
    if not isinstance(start, piping.PipingNetworkSegment | piping.PipingNetworkSegmentItem):
        raise TypeError(
            "start must be a PipingNetworkSegment or a PipingNetworkSegmentItem, "
            f"not {type(start).__name__}."
        )
    systems = getattr(model.conceptualModel, "pipingNetworkSystems", None) or []
    segments = [segment for system in systems for segment in system.segments]

    if isinstance(start, piping.PipingNetworkSegment):
        if not any(segment is start for segment in segments):
            raise ValueError(f"Segment {start.id!r} is not a segment of the model.")
        segment = start
    else:
        found = next((s for s in segments if any(item is start for item in s.items)), None)
        if found is None:
            raise ValueError(f"Item {start.id!r} is not an item of any segment in the model.")
        segment = found

    items = _items_in_flow_order(segment)
    if not isinstance(start, piping.PipingNetworkSegment):
        items = items[next(i for i, item in enumerate(items) if item is start) :]

    passed_segments = {id(segment)}
    passed_items = {id(item) for item in items}
    while across_segments:
        continuation = _run_continuation(segments, segment)
        if continuation is None:
            break
        segment = continuation
        if id(segment) in passed_segments:
            raise PipingTraversalException(
                f"The run comes back to segment {segment.id!r}; it is a cycle, not a line."
            )
        passed_segments.add(id(segment))
        for item in _items_in_flow_order(segment):
            if id(item) in passed_items:
                raise PipingTraversalException(
                    f"The run comes back to item {item.id!r}; it is a cycle, not a line."
                )
            passed_items.add(id(item))
            items.append(item)
    return items


def _items_in_flow_order(
    segment: piping.PipingNetworkSegment,
) -> list[piping.PipingNetworkSegmentItem]:
    """`segment`'s own items in :func:`segment_chain` order, without its connections."""
    item_ids = {id(item) for item in segment.items}
    return [element for element in segment_chain(segment) if id(element) in item_ids]


def _run_continuation(
    segments: list[piping.PipingNetworkSegment], segment: piping.PipingNetworkSegment
) -> piping.PipingNetworkSegment | None:
    """The segment that continues `segment`'s run, or None at the line's end.

    The continuation starts on the item and the node object `segment` ends on.
    Raises PipingTraversalException when that cannot be decided (see
    :func:`run_items`).
    """
    item, node = segment.targetItem, segment.targetNode
    if item is None:
        return None
    # `segment` itself leaves `item` when it starts and ends on its own single item; it is
    # where the run comes from, not where it goes on.
    leaving = [
        candidate
        for candidate in segments
        if candidate.sourceItem is item and candidate is not segment
    ]
    if not leaving:
        return None
    if node is None:
        raise PipingTraversalException(
            f"Segment {segment.id!r} ends at {item.id!r} without naming the node it ends on, "
            "so its run cannot be told from a branch among "
            f"{[candidate.id for candidate in leaving]}."
        )
    unnamed = [candidate.id for candidate in leaving if candidate.sourceNode is None]
    if unnamed:
        raise PipingTraversalException(
            f"Segments {unnamed} start from {item.id!r} without naming the node they start on, "
            f"so whether one continues segment {segment.id!r} cannot be decided."
        )
    continuing = [candidate for candidate in leaving if candidate.sourceNode is node]
    if len(continuing) > 1:
        raise PipingTraversalException(
            f"Segments {[candidate.id for candidate in continuing]} all start on node "
            f"{node.id!r} of {item.id!r}, where segment {segment.id!r} ends; "
            "the run is ambiguous."
        )
    if not continuing and len(getattr(item, "nodes", None) or []) <= 2:
        # An item with at most two nodes cannot be a branch point, so a segment leaving
        # it from another node continues this line: the model names two nodes for one
        # junction. Stopping here would return the line cut short as if it were whole.
        raise PipingTraversalException(
            f"Segment {segment.id!r} ends on node {node.id!r} of {item.id!r}, but segments "
            f"{[candidate.id for candidate in leaving]} leave {item.id!r} from another node. "
            f"{item.id!r} has no more than two nodes, so it is not a branch point and the line "
            "goes on, but the model names two different nodes for where; the run is refused "
            f"rather than cut short at {item.id!r}."
        )
    return continuing[0] if continuing else None


def piping_network_segment_validity_check(
    the_segment: piping.PipingNetworkSegment,
) -> tuple[PipingValidityCode, str]:
    """
    Performs a consistency check on the pipingNetworkSegment.

    Returns an appropriate PipingValidityCode Enum type. Internally, this is done by going
    along all items and connections to see if they form a valid chain.

    Parameters
    ----------
    the_segment : pipingNetworkSegment
        The piping network segment to be checked for consistency.

    Returns
    -------
    (PipingValidityCode, str)
        An Enum type indicating the validity status of the piping network
        segment. msg contains the corresponding error message.
    """

    visited_items = []
    visited_connections = []

    # First, go through connections to find the first connection of the segment.
    # This should have the same source spec as the PNS (at least, this is our
    # interpretation of the proteus spec. Adjust in future if otherwise)
    first_connection = None
    first_is_found = False
    for connection in the_segment.connections:
        # Find the first connection in the segment
        if the_segment.sourceItem == connection.sourceItem:
            first_connection = connection
            if not first_is_found:
                first_is_found = True
            else:
                msg = (
                    "At least two pipes in this segment have the same "
                    "piping input as the parent segment, should be one."
                )
                return (PipingValidityCode.INTERNAL_VIOLATION, msg)
    if first_connection is None and the_segment.connections:
        msg = "No piping connection found with the same piping input as the parent segment"
        return (PipingValidityCode.CONNECTION_CONVENTION_VIOLATION, msg)
    current_connection = first_connection
    visited_connections.append(current_connection)
    # Find the first item as source of the first pipe. Is none if the source
    # is outside the segment
    first_item = the_segment.sourceItem if the_segment.sourceItem in the_segment.items else None
    if first_item is not None:
        visited_items.append(first_item)
        current_item = first_item

    # Iterate along the pns one connection and item at a time to find all
    # connected segment members
    while True:
        # Find current connections destination
        current_item = current_connection.targetItem
        # Check if the end of the segment is reached, and finish. The
        # destination could be none, which is a valid case only at the end of
        # the segment
        if current_item is None and the_segment.targetItem is not None:
            msg = f"No destination to pipe {current_connection} referenced "
            return (PipingValidityCode.INTERNAL_VIOLATION, msg)
        if current_item in visited_items:
            msg = f"Item {current_item} referenced as destination twice inone segment"
            return (PipingValidityCode.INTERNAL_VIOLATION, msg)
        if current_item is not None:
            visited_items.append(current_item)
        if the_segment.targetItem == current_item:
            break
        # Otherwise, find the next connection. Return internal violation if none
        # found
        for connection in the_segment.connections:
            connection_found = False
            if connection.sourceItem == current_item:
                current_connection = connection
                visited_connections.append(current_connection)
                connection_found = True
                break
        if not connection_found:
            if len(visited_connections) != len(the_segment.connections):
                msg = (
                    "Piping network segment is interrupted, last connected "
                    "pipe does and not share the same destination as the segment and not all connections are visited"
                )
                return (PipingValidityCode.INTERNAL_VIOLATION, msg)
            else:
                msg = (
                    "Final pipe does not share its destination item with the piping network segment"
                )
                return (PipingValidityCode.CONNECTION_CONVENTION_VIOLATION, msg)

    # Check if there are connections or pipes in the segment that werent
    # visited, in which case it is corrupt
    if len(visited_connections) < len(the_segment.connections):
        msg = "Not all connections in the segment were visited"
        return (PipingValidityCode.INTERNAL_VIOLATION, msg)
    if len(visited_items) < len(the_segment.items):
        msg = "Not all items in the segment were visited"
        return (PipingValidityCode.INTERNAL_VIOLATION, msg)

    # Check if the order of the connections and items is the order of occurrence
    for segment_connection, visited_connection in zip(
        the_segment.connections, visited_connections, strict=False
    ):
        if segment_connection != visited_connection:
            msg = "Segment connections not in right order"
            return (PipingValidityCode.INTERNAL_VIOLATION, msg)
    for segment_item, visited_item in zip(the_segment.items, visited_items, strict=False):
        if segment_item != visited_item:
            msg = "Segment item not in right order"
            return (PipingValidityCode.INTERNAL_VIOLATION, msg)

    # Investigate if all nodes referenced are also part of the respective item
    elements_to_examine = [the_segment]
    elements_to_examine.extend(visited_connections)
    for element in elements_to_examine:
        for item, node, type_str in zip(
            [element.sourceItem, element.targetItem],
            [element.sourceNode, element.targetNode],
            ["source", "target"],
            strict=False,
        ):
            if item is None and node is not None:
                msg = f"{element} has a {type_str} node but no {type_str} item"
                return (PipingValidityCode.INTERNAL_VIOLATION, msg)
            if item is not None and node is not None and node not in item.nodes:
                msg = f"{element} {type_str} node not a member of its {type_str} item"
                return (PipingValidityCode.INTERNAL_VIOLATION, msg)

    # If no violation was encountered above, the segment is valid
    return (PipingValidityCode.VALID, "Segment valid")


def get_segment_from_item(
    conceptual_model: PlantModel, item: piping.PipingNetworkSegmentItem
) -> piping.PipingNetworkSegment:
    """
    Retrieves the piping network segment associated with a given item.

    Parameters
    ----------
    conceptual_model : PlantModel
        The conceptual model containing the piping network systems.
    item : PipingNetworkSegmentItem
        The item for which to retrieve the associated segment.

    Returns
    -------
    PipingNetworkSegment
        The piping network segment associated with the given item.

    Raises
    ------
    ValueError
        If the item is not part of any piping network segment.
    """
    for system in conceptual_model.pipingNetworkSystems:
        for segment in system.segments:
            if item in segment.items:
                return segment
    raise ValueError(f"Item {item} is not part of any piping network segment.")


def node_holders(
    model: EngineeringModel,
    node: piping.PipingNode,
    *,
    excluding: Iterable[tuple[PyDexpiBaseModel, str]] = (),
) -> list[tuple[PyDexpiBaseModel, str]]:
    """Every connection or segment end that names `node`, as ``(holder, attribute)`` pairs.

    This is the one answer to "is this port taken": the MCP discovery tools report a
    node as free exactly when it returns nothing. A node is one physical
    port, so a pipe attaches to it at most once; a segment's own end counts too,
    as a run ending on the port has it.

    Only ``sourceNode``/``targetNode`` references count -- a node's own drawing
    refers to it as well.

    Parameters
    ----------
    model : EngineeringModel
        The model to search.
    node : PipingNode
        The node to check.
    excluding : Iterable[tuple[PyDexpiBaseModel, str]]
        ``(holder, attribute)`` pairs to leave out, compared by identity, so a
        holder can ask whether any *other* end names the node.

    Returns
    -------
    list[tuple[PyDexpiBaseModel, str]]
        The holders, in model traversal order. Empty when the node is free.
    """
    excluded = list(excluding)
    return [
        (holder, attribute)
        for holder, attribute in get_objects_referencing(model, [node])
        if attribute in ("sourceNode", "targetNode")
        and not any(holder is kept and attribute == name for kept, name in excluded)
    ]


def connect_piping_connection(
    connector_item: piping.PipingSourceItem | piping.PipingTargetItem,
    piping_connection: piping.PipingConnection | None = None,
    piping_segment: piping.PipingNetworkSegment | None = None,
    connector_node: piping.PipingNode | None = None,
    as_source: bool = False,
    force_reconnect: bool = False,
) -> None:
    """
    Connects the pipe to the target connector object.

    If the connector object is a PipingNode, the connection is implemented via
    node connection. Otherwise, a connection via Source or TargetItem is
    attempted. Raises an error if the piping connection is already connected
    unless `force_reconnect` is True.

    Parameters
    ----------
    connector_item : Union[PipingSourceItem, PipingTargetItem]
        The item to which the pipe will be connected.
    piping_connection : PipingConnection, optional
        The piping connection to be reconnected. If not passed, then
        reconnection only performed on the segment
    piping_segment : PipingNetworkSegment, optional
        Applies the reconnection to the piping segment too if passed along.
    connector_node: PipingNode, optional
        Optionally, the node of connector_item to be connected to. Must be a
        member of connector_item
    as_source : bool, optional
        If True, the connection is established as source, else as target.
        Defaults to False.
    force_reconnect : bool, optional
        If False, raises an exception if the piping connection is already
        connected. Defaults to False.

    Returns
    -------
    None
        This function modifies the state of the piping connection but does
        not return any value.

    Raises
    ------
    ConnectionException
        If the piping connection is already connected, and `force_reconnect`
        is False.
    ValueError
        If the piping_connection and piping_segment are found to be faulty or
        do not fit together, or if the optional connector_node is not associated to the connector_item
    """
    if connector_item is None and connector_node is not None:
        msg = "Cannot have a node without an item for connections."
        raise ValueError(msg)
    if connector_node is not None and connector_node not in connector_item.nodes:
        msg = f"Piping node {connector_node} not associated to item {connector_item}"
        raise ValueError(msg)

    def raise_exception_if_connection_conflict(connection_object, as_source) -> None:
        """Raise a DexpiConnectionException if the object is already connected"""
        if as_source and (
            connection_object.sourceNode is not None or connection_object.sourceItem is not None
        ):
            raise DexpiConnectionException(
                f"{type(connection_object)} object: {connection_object} already has a source."
            )
        elif not as_source and (
            connection_object.targetNode is not None or connection_object.targetItem is not None
        ):
            raise DexpiConnectionException(
                f"{type(connection_object)} object: {connection_object} already has a target."
            )

    def reconnect_connection_object(conntection_object, item, node, as_source) -> None:
        """Set the source/target connector to the item and node specified"""
        if as_source:
            conntection_object.sourceNode = None
            conntection_object.sourceItem = None
            conntection_object.sourceItem = item
            if connector_node is not None:
                conntection_object.sourceNode = node

        else:
            conntection_object.targetNode = None
            conntection_object.targetItem = None
            conntection_object.targetItem = item
            if connector_node is not None:
                conntection_object.targetNode = node

    if piping_segment is not None and piping_connection is not None:
        final_segment_connection = find_final_connection(piping_segment, as_source=as_source)
        if final_segment_connection != piping_connection:
            msg = f"{piping_connection} is not the final connection of {piping_segment}"
            raise ValueError(msg)

    # check if connection already exists.
    if not force_reconnect:
        if piping_connection is not None:
            raise_exception_if_connection_conflict(piping_connection, as_source)
        if piping_segment is not None:
            raise_exception_if_connection_conflict(piping_segment, as_source)

    # Perform reconnection
    if piping_connection is not None:
        reconnect_connection_object(piping_connection, connector_item, connector_node, as_source)
    if piping_segment is not None:
        reconnect_connection_object(piping_segment, connector_item, connector_node, as_source)
