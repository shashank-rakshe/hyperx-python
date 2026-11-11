"""Discovery tools: a segment's pipes, an item's nodes and a line's items, with their ids.

``describe_item`` also describes the objects of a DEXPI process model -- a step and its ports,
a port, a connection, a material state -- through
:mod:`pydexpi.mcp_server.tools.process_discovery`.

An agent working on a model needs the ids of pipes, piping nodes and segments.
``object_summary`` does not carry them, so without these tools an agent has to read
``export_json``.

Occupancy is :func:`pydexpi.toolkits.piping_toolkit.node_holders`'s: a node reported
``free`` is one no connection or segment end names. A line's items come from
:func:`pydexpi.toolkits.piping_toolkit.run_items`, in flow order.
"""

from __future__ import annotations

import json

from pydexpi.mcp_server.errors import ErrorCode, error_response
from pydexpi.mcp_server.extensions import (
    NO_ITEM_FIELDS,
    ItemFields,
    declare_field_passages,
    item_fields_of,
)
from pydexpi.mcp_server.serialization import object_summary
from pydexpi.mcp_server.session import ModelEntry, SessionState
from pydexpi.mcp_server.tools.process_discovery import (
    arrows_by_line,
    describe_process_object,
    line_record,
)
from pydexpi.pydexpi_classes.core.diagram import RepresentationGroup
from pydexpi.pydexpi_classes.plant import instrumentation, piping
from pydexpi.pydexpi_classes.plant.diagram import InstrumentationNodePosition, PipingNodePosition
from pydexpi.query.errors import ObjectNotFoundError
from pydexpi.toolkits import routing
from pydexpi.toolkits.model_toolkit import get_all_instances_in_model
from pydexpi.toolkits.piping_toolkit import (
    DexpiCorruptPipingSegmentException,
    PipingTraversalException,
    node_holders,
    run_items,
)

#: How ``describe_segment`` orders ``pipes``; stated in every response so it is not
#: mistaken for a source-to-target traversal.
PIPE_ORDER = "list order of PipingNetworkSegment.connections"

#: How ``describe_run`` orders ``items``; stated in every response, as PIPE_ORDER is.
RUN_ORDER = "flow order, source to target, through tees along the run"

#: The objects whose drawn signal ports ``describe_item`` lists: the objects a signal port is
#: drawn for.
SIGNAL_PORT_OWNERS = (
    instrumentation.ProcessInstrumentationFunction,
    instrumentation.SensingLocation,
)


def _end(item, node) -> dict:
    return {
        "item": object_summary(item) if item is not None else None,
        "node_id": node.id if node is not None else None,
    }


def _drawn_positions(model) -> dict[int, list[dict]]:
    """``id(node) -> [{position, group_id, represents}]`` for every drawn piping node.

    Every PipingNodePosition is kept together with the group (or diagram) that
    holds it. Nothing is merged or chosen, so a node drawn twice reports two
    positions.
    """
    containers = [model.diagram] if model.diagram is not None else []
    containers += [
        g for g in get_all_instances_in_model(model) if isinstance(g, RepresentationGroup)
    ]
    seen: set[int] = set()
    out: dict[int, list[dict]] = {}
    for group in containers:
        if id(group) in seen:  # the diagram is itself a representation group
            continue
        seen.add(id(group))
        for pos in getattr(group, "nodePositions", None) or []:
            if not isinstance(pos, PipingNodePosition) or pos.node is None:
                continue
            represents = getattr(group, "represents", None)
            out.setdefault(id(pos.node), []).append(
                {
                    "position": [pos.position.x, pos.position.y]
                    if pos.position is not None
                    else None,
                    "node_position_id": pos.id,
                    "group_id": group.id,
                    "represents": getattr(represents, "id", None),
                }
            )
    return out


def _node_record(model, node, drawn: dict[int, list[dict]], owner=None) -> dict:
    holders = node_holders(model, node)
    positions = drawn.get(id(node), [])
    rec = {
        "node_id": node.id,
        "free": not holders,
        "holders": [{"holder": object_summary(h), "attribute": a} for h, a in holders],
        "drawn": bool(positions),
        "positions": positions,
    }
    if owner is not None:
        rec["owner"] = object_summary(owner)
    return rec


def _signal_ports(model, owner, fields: ItemFields = NO_ITEM_FIELDS) -> list[dict]:
    """Every signal port drawn directly for this owner, with what extensions add to each."""
    ports = []
    seen = set()
    for group in get_all_instances_in_model(model):
        if not isinstance(group, RepresentationGroup) or group.represents is not owner:
            continue
        for port in group.nodePositions or []:
            if not isinstance(port, InstrumentationNodePosition) or id(port) in seen:
                continue
            seen.add(id(port))
            ports.append(
                {
                    "node_position_id": port.id,
                    "position": [port.position.x, port.position.y]
                    if port.position is not None
                    else None,
                    "group_id": group.id,
                    **fields("signal_port", model, port),
                }
            )
    return ports


def _get(entry: ModelEntry, object_id: str):
    try:
        return entry.query_engine.get_by_id(object_id)
    except ObjectNotFoundError:
        return None


#: The passages of ``describe_item``'s description that document each place of extension fields,
#: as the core gives them: an extension that adds fields there documents them in its own
#: (:func:`pydexpi.mcp_server.extensions.declare_field_passages`).
DESCRIBE_ITEM_PASSAGES = {
    "signal_port": """\
``signal_ports`` lists an instrument or sensing location's drawn ports:
``node_position_id``, ``position`` and ``group_id``. Its
``node_position_id`` is the id that names the port.
""",
    "port_delegation": """\
port (each a port of a step below this one that stands in for
it there, taking part in its connection); and the ``problems``
the delegation rule reports for its
""",
    "instrumentation_activity": """\
the ``system`` holding it,
""",
}


def _register_discovery_tools(mcp, state: SessionState) -> None:
    """Register the discovery tools on *mcp*."""
    fields = item_fields_of(mcp)
    declare_field_passages(mcp, "describe_item", DESCRIBE_ITEM_PASSAGES)

    @mcp.tool()
    def describe_segment(segment_id: str, model_id: str | None = None) -> str:
        """A piping network segment with its pipes, items and end nodes.

        Returns the segment's own ``source`` / ``target`` (item and node id), its
        ``pipes`` (id, type, source and target item and node id each) and its
        ``items`` with their node ids.

        Each pipe also lists the ``lines`` drawn for it: a ``connector_id``, its
        ``points``, the ``arrow_ids`` of the flow arrows that lie on it and
        ``drawn``: ``with_flow`` when the line runs from the pipe's source node
        to its target node, ``against_flow`` when it runs the other way, or
        ``flow_unknown``. An undrawn pipe has ``lines: []``.

        ``pipes`` are listed in the order of ``PipingNetworkSegment.connections``
        (field ``order``); that is not guaranteed to be source-to-target order.

        Parameters
        ----------
        segment_id : str
            Id of a PipingNetworkSegment.
        model_id : str, optional
            Target model.  Falls back to the active model if omitted.

        Returns
        -------
        str
            JSON with ``segment``, ``source``, ``target``, ``order``, ``pipes`` and ``items``.
        """
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        entry: ModelEntry = resolved
        seg = _get(entry, segment_id)
        if seg is None:
            return error_response(ErrorCode.OBJECT_NOT_FOUND, f"No object with id '{segment_id}'.")
        if not isinstance(seg, piping.PipingNetworkSegment):
            return error_response(
                ErrorCode.INVALID_PARAMETER,
                f"'{segment_id}' is a {type(seg).__name__}, not a PipingNetworkSegment.",
            )
        arrows = arrows_by_line(entry.model)
        drawn = (
            list(routing.iter_connector_lines(entry.model.diagram))
            if getattr(entry.model, "diagram", None) is not None
            else []
        )
        pipes = [
            {
                "pipe_id": c.id,
                "type": type(c).__name__,
                "source": _end(c.sourceItem, c.sourceNode),
                "target": _end(c.targetItem, c.targetNode),
                "lines": [
                    line_record(line, holder, arrows)
                    for line, holder in drawn
                    if holder.represents is c
                ],
            }
            for c in seg.connections or []
        ]
        items = [
            {**object_summary(i), "node_ids": [n.id for n in (getattr(i, "nodes", None) or [])]}
            for i in seg.items or []
        ]
        return json.dumps(
            {
                "segment": object_summary(seg),
                "source": _end(seg.sourceItem, seg.sourceNode),
                "target": _end(seg.targetItem, seg.targetNode),
                "order": PIPE_ORDER,
                "pipes": pipes,
                "items": items,
            }
        )

    @mcp.tool()
    def describe_item(object_id: str, model_id: str | None = None) -> str:
        """An item's piping and signal ports, or a process object's connections and materials.

        For a piping item: ``free`` says whether a node is open for a pipe end:
        a node is taken when a connection or segment names it as ``sourceNode``
        or ``targetNode`` (``holders``). ``positions`` lists every drawn
        PipingNodePosition of the node with the group that holds it; an undrawn
        node has ``drawn: false`` and ``positions: []``. Nozzle nodes of
        equipment are included with their ``owner`` nozzle.

        ``signal_ports`` lists an instrument or sensing location's drawn ports:
        ``node_position_id``, ``position`` and ``group_id``. Its
        ``node_position_id`` is the id that names the port.

        For an object of a process model the reply has a ``kind``:

        - ``port_owner`` (a process step, a step detail, an instrumentation
          activity): its ``ports`` in list order, each with ``identifier``,
          ``direction``, ``roles``, the ``connection`` it is the ``end``
          (``source`` / ``target``) of, its ``connector_reference``, a
          delegated port's ``super_port`` / ``sub_ports``, its
          ``delegation`` (``null`` for a port in none): the ``chain`` of
          super ports above it, nearest first, and whether it is
          ``cyclic``; its ``delegates``, the ports naming it as their super
          port (each a port of a step below this one that stands in for
          it there, taking part in its connection); and the ``problems``
          the delegation rule reports for its
          links; and where it is ``drawn``: its ``positions``, each a
          ``node_position_id``, its ``position``, the ``group_id`` holding it and the
          ``side`` of the block it lies on. A step adds its ``parent_step``
          (``null`` at the top level),
          ``sub_steps`` and ``details``, and its ``drawing``: ``drawn``,
          and when it is, ``group_id``, the ``bounds`` of its symbol
          (``[min_x, min_y, max_x, max_y]``, Y down), ``shape_id``,
          ``rotation`` and ``label_ids``. A step detail adds the ``step``
          holding it. An instrumentation activity adds its ``drawing``,
          the ``system`` holding it,
          and a ``MeasuringProcessVariable`` its ``measurement``: the
          ``process_step``, ``process_step_detail`` and ``connection`` it
          names, and the ``measured_value`` it reads (``value_id``, the
          ``owner`` holding it, and the ``attribute`` and ``index`` it holds
          it at), each ``null`` where unset;
        - ``instrumentation_system``: the ``activities`` it holds, in list
          order;
        - ``port``: the same record for one port, with its ``owner``;
        - ``connection``: its ``source`` and ``target``, each a port and the
          port's owner, and the ``lines`` drawn for it: each a
          ``connector_id``, its ``source_position_id``
          and ``target_position_id`` (``null`` for a free end, a line
          that names no node position), ``bound`` and its
          ``points``; a ``Stream`` adds ``material``: its ``template``, its
          ``state``, the ``component_order`` its fractions are read against
          (without a state, the
          first template of the stream or an end port that lists components),
          ``state_conflicts`` (other streams' templates on the same state that
          disagree with it) and ``template_conflicts`` (its ports' templates);
        - ``material_state``: the ``streams`` that read it, the ``template``
          and ``component_order`` it is read against, any ``conflicts``, and
          its ``fraction_vectors``, each with its ``length`` and whether it
          ``fits`` the component order (``null`` where either is unknown).
          A ``component_order`` of ``null`` beside fraction vectors means no
          stream pairs the state with a template that lists components:
          nothing records which component each value belongs to.

        Every conflict field, and each list of a ``delegation``, holds at
        most 10 entries as ``items``, with the total ``count`` and
        ``truncated``.

        Parameters
        ----------
        object_id : str
            Id of an item that owns piping nodes (piping component, nozzle,
            equipment, off-page connector, ...), or of a process step, step
            detail, instrumentation activity or system, port, connection or
            material state.
        model_id : str, optional
            Target model.  Falls back to the active model if omitted.

        Returns
        -------
        str
            JSON with ``object``, ``nodes`` and ``in_segments`` for a piping
            item; for a process object, JSON with ``kind`` and ``object`` as
            above.
        """
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        entry: ModelEntry = resolved
        obj = _get(entry, object_id)
        if obj is None:
            return error_response(ErrorCode.OBJECT_NOT_FOUND, f"No object with id '{object_id}'.")
        process = describe_process_object(entry.model, obj, fields)
        if process is not None:
            return json.dumps(process)
        own = list(getattr(obj, "nodes", None) or [])
        nozzles = list(getattr(obj, "nozzles", None) or [])
        if not own and not nozzles and not isinstance(obj, SIGNAL_PORT_OWNERS):
            return error_response(
                ErrorCode.INVALID_PARAMETER,
                f"'{object_id}' is a {type(obj).__name__}, which has no piping nodes and is no "
                "process step, step detail, instrumentation activity or system, port, "
                "connection or material state.",
            )
        model = entry.model
        drawn = _drawn_positions(model)
        nodes = [_node_record(model, n, drawn) for n in own]
        for nozzle in nozzles:
            nodes += [_node_record(model, n, drawn, owner=nozzle) for n in nozzle.nodes or []]
        in_segments = [
            s.id
            for s in get_all_instances_in_model(model)
            if isinstance(s, piping.PipingNetworkSegment) and any(i is obj for i in s.items or [])
        ]
        return json.dumps(
            {
                "object": object_summary(obj),
                "nodes": nodes,
                "in_segments": in_segments,
                "signal_ports": _signal_ports(model, obj, fields),
            }
        )

    @mcp.tool()
    def describe_run(
        start_id: str, model_id: str | None = None, across_segments: bool = True
    ) -> str:
        """The items along a line in flow order, through tees along the run, never a branch.

        Starts at a segment's first item, or at an item of a segment, and walks
        downstream: within a segment from source to target, then into the segment
        that starts on the node the previous one ends on. At a tee that is the run
        outlet; a branch leaves from another node and is not followed. Stops at the
        line's end (an open end, a nozzle, an item nothing continues from). Nozzles
        and other items outside every segment are not listed.

        Parameters
        ----------
        start_id : str
            Id of a PipingNetworkSegment, or of an item in one's ``items``.
        model_id : str, optional
            Target model.  Falls back to the active model if omitted.
        across_segments : bool, optional
            False stops at the end of the start segment. Defaults to True.

        Returns
        -------
        str
            JSON with ``start``, ``order`` and ``items``. A run that cannot be
            decided (two segments on one node, a missing node, a cycle, a segment
            leaving a two-node item from another node than the line ends on) is an
            ``invalid_parameter`` error carrying ``run_items``' message, which names
            the segment and item where the walk stopped deciding.
        """
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        entry: ModelEntry = resolved
        start = _get(entry, start_id)
        if start is None:
            return error_response(ErrorCode.OBJECT_NOT_FOUND, f"No object with id '{start_id}'.")
        if not isinstance(start, piping.PipingNetworkSegment | piping.PipingNetworkSegmentItem):
            return error_response(
                ErrorCode.INVALID_PARAMETER,
                f"'{start_id}' is a {type(start).__name__}, not a PipingNetworkSegment or an "
                "item of one.",
            )
        try:
            items = run_items(entry.model, start, across_segments=across_segments)
        except (ValueError, DexpiCorruptPipingSegmentException, PipingTraversalException) as error:
            return error_response(ErrorCode.INVALID_PARAMETER, str(error))
        return json.dumps(
            {
                "start": object_summary(start),
                "order": RUN_ORDER,
                "items": [object_summary(item) for item in items],
            }
        )
