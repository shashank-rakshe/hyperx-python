"""What ``describe_item`` reports for an object of a DEXPI process model.

A block flow diagram is steps, ports, connections and materials, none of which has a piping
node. These records answer the questions an agent asks next -- which ports a step has and what
each is connected to, what a stream carries, which streams read a material state and against
which components -- from the toolkits the validation rules read the model with, so a reply and
a rule cannot disagree:

- ports, owners and connection ends: :mod:`pydexpi.toolkits.process_toolkit` (``ports_of``,
  ``port_owners``, ``connections_ending_at``), and from the same module what holds a step
  detail, an instrumentation activity and a measured value (``step_holding``,
  ``system_holding``, ``value_holder``);
- material pairing and component order: :mod:`pydexpi.toolkits.process_materials`
  (``state_component_order``, ``reading_template``, ``stream_template_conflicts``,
  ``streams_referencing``, ``fraction_vectors``) -- the same functions the material rules
  read, so ``component_order`` is the order the rules check vectors against;
- the step hierarchy and port delegation: :mod:`pydexpi.toolkits.process_hierarchy`
  (``StepTree``, ``super_chain``, ``delegates_of``, ``delegation_problems`` -- what
  ``pydexpi_process_port_delegation_consistent`` reports);
- what is drawn: :mod:`pydexpi.toolkits.process_drawing` (``port_positions``,
  ``connection_lines``, ``delegation_lines``, ``port_side``, ``containment_problems``),
  ``toolkits.flow_arrows`` and ``diagram_toolkit.symbol_extent``, so a step's ``containment``
  is what the rule ``pydexpi_process_step_drawn_inside_parent`` reports for it.
"""

from __future__ import annotations

from typing import Any

from pydexpi.mcp_server.extensions import NO_ITEM_FIELDS, ItemFields
from pydexpi.mcp_server.serialization import object_summary
from pydexpi.pydexpi_classes.core.diagram import Label
from pydexpi.pydexpi_classes.pydexpi_classes import (
    InstrumentationActivity,
    InstrumentationSystemActivity,
    MaterialPort,
    MaterialState,
    MeasuringProcessVariable,
    Port,
    ProcessConnection,
    ProcessModel,
    ProcessStep,
    ProcessStepDetail,
    PyDexpiBaseModel,
    Stream,
)
from pydexpi.toolkits import companions, flow_arrows, routing
from pydexpi.toolkits.diagram_toolkit import own_symbol_usage, symbol_extent
from pydexpi.toolkits.finite_geometry import NonFiniteGeometryError
from pydexpi.toolkits.process_drawing import (
    connection_lines,
    containment_problems,
    delegation_lines,
    port_positions,
    port_side,
)
from pydexpi.toolkits.process_hierarchy import (
    DelegationProblem,
    StepTree,
    delegates_of,
    delegation_problems,
    listing_ports,
    model_ports,
    super_chain,
)
from pydexpi.toolkits.process_materials import (
    component_ids,
    fraction_vectors,
    reading_template,
    state_component_order,
    stream_pairings,
    stream_template_conflicts,
    streams_referencing,
)
from pydexpi.toolkits.process_toolkit import (
    connections_ending_at,
    port_owners,
    port_slot,
    ports_of,
    step_holding,
    system_holding,
    value_holder,
)

#: How a step's ``ports`` are listed; stated in every response, as ``describe_segment`` states its
#: pipe order.
PORT_ORDER = "list order of the owner's ports"

#: How many conflict messages a reply lists; the rest are counted (AGENTS.md, *The MCP server*:
#: a reply bounds its lists and counts the rest). A state shared by many streams can pair
#: with many disagreeing templates.
MAX_CONFLICTS = 10


def _summary(obj: PyDexpiBaseModel | None) -> dict[str, Any] | None:
    return object_summary(obj) if obj is not None else None


def _enum_value(value: object) -> object:
    return getattr(value, "value", value)


def _as_list(value: object) -> list:
    if value is None:
        return []
    return list(value) if isinstance(value, list) else [value]


def _bounded_list(items: list) -> dict[str, Any]:
    """The first :data:`MAX_CONFLICTS` of *items*, their total count, and whether any were left
    out."""
    return {
        "items": items[:MAX_CONFLICTS],
        "count": len(items),
        "truncated": len(items) > MAX_CONFLICTS,
    }


def _bounded(conflicts: list) -> dict[str, Any]:
    """*conflicts*, each described, bounded by :func:`_bounded_list`."""
    return _bounded_list([conflict.describe() for conflict in conflicts])


class _Delegations:
    """The delegation links of one process model, read once per ``describe_item`` call.

    Every field is the toolkit's own answer (:mod:`process_hierarchy`), so a reply cannot say
    something the rule ``pydexpi_process_port_delegation_consistent`` does not.
    """

    def __init__(
        self,
        model: PyDexpiBaseModel,
        process_model: ProcessModel,
        fields: ItemFields = NO_ITEM_FIELDS,
    ) -> None:
        self.model = model
        self.process_model = process_model
        self.fields = fields
        self.tree = StepTree(process_model)
        self.ports = model_ports(process_model)
        self.problems: dict[int, list[DelegationProblem]] = {}
        # Most models delegate nothing: one look at the ports' own references says so, and
        # then no port has a record.
        self.any = any(
            port.__dict__.get("superReference") is not None or port.__dict__.get("subReference")
            for port in self.ports
        )
        if self.any:
            for problem in delegation_problems(process_model, tree=self.tree):
                for port_id in {id(problem.port), id(problem.super_port)}:
                    self.problems.setdefault(port_id, []).append(problem)

    def record(self, port: Port) -> dict[str, Any] | None:
        """A port's part in delegation, or None for a port that is in none, up or down."""
        if not self.any:
            return None
        chain, cyclic = super_chain(port)
        delegates = delegates_of(self.ports, port)
        listed_by = listing_ports(self.ports, port)
        problems = self.problems.get(id(port), [])
        if not (chain or cyclic or delegates or listed_by or problems):
            return None
        delegated = port.__dict__.get("superReference") is not None or bool(listed_by)
        return {
            "chain": _bounded_list([object_summary(above) for above in chain]),
            "cyclic": cyclic,
            "delegates": _bounded_list([object_summary(below) for below in delegates]),
            **self.fields("port_delegation", self.model, self.process_model, port, delegated),
            "problems": _bounded_list([problem.message for problem in problems]),
        }


def _endings(model: PyDexpiBaseModel, ports: list[Port]) -> dict[int, list[tuple[Any, str]]]:
    """``id(port) -> [(connection, end)]`` for *ports*, from one walk of the model, in its order."""
    endings: dict[int, list[tuple[Any, str]]] = {id(port): [] for port in ports}
    for connection in connections_ending_at(model, ports):
        for end in ("source", "target"):
            port = connection.__dict__.get(end)
            if id(port) in endings:
                endings[id(port)].append((connection, end))
    return endings


def _components(process_model: ProcessModel, ids: list[str] | None) -> list[dict] | None:
    """The components *ids* name, in order, each as a summary; an id no component has is kept."""
    if ids is None:
        return None
    by_id = {component.id: component for component in process_model.materialComponents or []}
    return [object_summary(by_id[i]) if i in by_id else {"id": i} for i in ids]


def _measured(measure: Any, *arguments: Any) -> Any:
    """What a measuring function of the toolkits says, or ``None`` where it cannot measure.

    A drawing may hold a NaN or an infinity, and the functions that measure one raise for it
    (``toolkits.finite_geometry``). Discovery only reports, so it answers as for a drawing
    with nothing to measure -- no ``bounds``, no ``side``.
    """
    try:
        return measure(*arguments)
    except NonFiniteGeometryError:
        return None


def _positions(model: PyDexpiBaseModel, port: Port) -> list[dict[str, Any]]:
    """Every drawn position of *port*: its ``PortNodePosition`` s, with the drawing holding each.

    ``node_position_id`` is the node position's id, and ``side`` the
    side of its symbol the position lies on (``process_drawing.port_side``: the side of the box
    around the symbol for a block, and for any other shape the side the outline is seen from
    there; ``null`` for one that lies on none, or on a symbol that cannot be measured).
    Nothing is merged or chosen: a port drawn twice reports two positions.
    """
    records = []
    for group, position in port_positions(getattr(model, "diagram", None)).get(id(port), []):
        point = (position.position.x, position.position.y)
        records.append(
            {
                "node_position_id": position.id,
                "position": [point[0], point[1]],
                "group_id": group.id,
                "represents": getattr(group.represents, "id", None),
                "side": _measured(port_side, group, point),
            }
        )
    return records


def _drawing(model: PyDexpiBaseModel, owner: PyDexpiBaseModel) -> dict[str, Any]:
    """How a step or an instrumentation activity is drawn: its group, the box of its symbol,
    its shape and its labels.

    ``bounds`` is ``[min_x, min_y, max_x, max_y]`` on the sheet, Y down, or ``null`` for a
    drawing without a measurable symbol, one holding a number that is not finite included
    (:func:`_measured`); ``label_ids`` are the ids of its labels. An undrawn one reports
    ``drawn: false``.

    A step's ``containment`` lists where its block disagrees with the step hierarchy
    (``process_drawing.containment_problems``, what the rule
    ``pydexpi_process_step_drawn_inside_parent`` reports): ``outside_parent`` with how far it
    reaches outside and the ``shift`` ``[dx, dy]`` that brings it inside (``null`` when it is
    too large to fit), or ``inside_unrelated``; empty for a block that is where it belongs.
    """
    group = companions.build_group_index(model).get(id(owner))  # type: ignore[arg-type]
    if group is None:
        return {"drawn": False}
    bounds = _measured(symbol_extent, group)
    usage = own_symbol_usage(group)
    record: dict[str, Any] = {
        "drawn": True,
        "group_id": group.id,
        "bounds": [bounds.min_x, bounds.min_y, bounds.max_x, bounds.max_y]
        if bounds is not None
        else None,
        "shape_id": getattr(getattr(usage, "shape", None), "id", None),
        "rotation": getattr(usage, "rotation", None),
        "label_ids": [label.id for label in group.groups if isinstance(label, Label)],
    }
    if isinstance(owner, ProcessStep):
        record["containment"] = [
            {
                "kind": problem.kind,
                "step": object_summary(problem.other),
                "overhang": problem.overhang,
                "shift": list(problem.shift) if problem.shift is not None else None,
            }
            for problem in containment_problems(model)  # type: ignore[arg-type]
            if problem.step is owner
        ]
    return record


def _lines(model: PyDexpiBaseModel, connection: ProcessConnection) -> list[dict[str, Any]]:
    """The lines drawn for *connection*: each with its id, its ends and its route.

    ``source_position_id`` / ``target_position_id`` name the node positions the line is bound
    to, ``null`` for a free end; ``bound`` is true when both are set. ``points`` is the whole
    drawn polyline. ``arrow_ids`` are the flow arrows that lie on the line, wherever the
    drawing holds them (``flow_arrows.bind``). ``drawn``
    says which way the line runs with its flow (``flow_arrows.flow_along``): ``with_flow``,
    ``against_flow`` -- an arrow on it points against the line -- or ``flow_unknown``.
    """
    arrows = arrows_by_line(model)
    return [
        line_record(line, holder, arrows)
        for line, holder in connection_lines(getattr(model, "diagram", None))
        if holder.represents is connection
    ]


#: How ``drawn`` names which way a line runs with its flow.
_DRAWN = {1: "with_flow", -1: "against_flow", 0: "flow_unknown"}


def arrows_by_line(model: PyDexpiBaseModel) -> dict[int, list[str]]:
    """The ids of the flow arrows that lie on each line of the drawing, by ``id(line)``.

    Read by ``flow_arrows.bind``: an arrow belongs to the line it lies on, whichever drawing
    holds its group. The
    Tennessee Eastman export holds all seventeen of its arrows on the sheet.
    """
    found: dict[int, list[str]] = {}
    for binding in flow_arrows.bind(getattr(model, "diagram", None)):
        found.setdefault(id(binding.line), []).append(binding.usage.id)
    return found


def line_record(line: Any, holder: Any, arrows: dict[int, list[str]]) -> dict[str, Any]:
    """One drawn line as discovery reports it, for a process connection and a pipe alike."""
    return {
        "connector_id": line.id,
        "group_id": holder.id,
        "source_position_id": getattr(line.source, "id", None),
        "target_position_id": getattr(line.target, "id", None),
        "bound": line.source is not None and line.target is not None,
        "points": [[x, y] for x, y in routing.polyline_of(line)],
        "arrow_ids": arrows.get(id(line), []),
        "drawn": _DRAWN[flow_arrows.flow_along(line, holder)],
    }


def _delegation_lines(model: PyDexpiBaseModel, port: Port) -> list[dict[str, Any]]:
    """The lines drawn for *port*'s delegation: the drawing of the delegated port, from its
    node position to its super port's. Empty for a delegation that is not drawn."""
    arrows = arrows_by_line(model)
    return [
        line_record(line, holder, arrows)
        for line, holder in delegation_lines(getattr(model, "diagram", None))
        if holder.represents is port
    ]


def _port_record(
    model: PyDexpiBaseModel,
    port: Port,
    ending: list[tuple[Any, str]],
    delegations: _Delegations,
) -> dict[str, Any]:
    """A port: its direction and roles, the connection it is an end of, its delegation, and
    where it is drawn.

    ``connection`` is the connection whose ``source`` or ``target`` is this port, and ``end``
    says which (``connections_ending_at``). A delegated port
    takes part in its ``super_port``'s connection without being an end of it, so it has none;
    ``connector_reference`` is what the port itself names, which
    ``pydexpi_process_connection_ports_agree`` holds to the connection's ends.

    ``super_port`` and ``sub_ports`` are the port's own two references. ``delegation`` is null
    for a port in no delegation, and otherwise what follows from the links: the ``chain`` of
    super ports above it, nearest first (``cyclic`` when it loops), its ``delegates`` -- the
    ports naming it as their super port -- and the ``problems`` the delegation rule reports for
    its links.

    ``positions`` are its node positions on the sheet (:func:`_positions`), and ``drawn``
    whether it has any. ``delegation_lines`` are the lines drawn for its delegation, for a
    port that names a super port: empty while it is not drawn.
    """
    connection, end = ending[0] if ending else (None, None)
    connector = port.__dict__.get("connectorReference")
    positions = _positions(model, port)
    record: dict[str, Any] = {
        "port": object_summary(port),
        "identifier": port.identifier,
        "direction": _enum_value(port.nominalDirection),
        "roles": [role.name for role in port.performedRoles or []],
        "connection": _summary(connection),
        "end": end,
        "connector_reference": connector.id if connector is not None else None,
        "super_port": _summary(port.__dict__.get("superReference")),
        "sub_ports": [object_summary(p) for p in _as_list(port.__dict__.get("subReference"))],
        "delegation": delegations.record(port),
        "drawn": bool(positions),
        "positions": positions,
    }
    if port.__dict__.get("superReference") is not None:
        record["delegation_lines"] = _delegation_lines(model, port)
    if len(ending) > 1:
        # A malformed model: more than one connection ends here. Name them all.
        record["connections"] = [object_summary(c) for c, _end in ending]
    if isinstance(port, MaterialPort):
        record["material_template"] = _summary(port.__dict__.get("materialTemplateReference"))
    return record


def _measurement(model: PyDexpiBaseModel, activity: MeasuringProcessVariable) -> dict[str, Any]:
    """What a measuring activity says it measures: its four references.

    ``process_step``, ``process_step_detail`` and ``connection`` are where the measurement is
    taken, each null where unset. ``measured_value`` is the ``QualifiedValue`` it reads, null
    where unset: its ``value_id``, the ``owner`` that holds it and the ``attribute`` and
    ``index`` it holds it at (``process_toolkit.value_holder``), which are what
    ``measured_attribute`` and ``measured_index`` name when the owner is the one object the
    activity names.
    """
    value = activity.__dict__.get("measuredVariableReference")
    measured: dict[str, Any] | None = None
    if value is not None:
        held = value_holder(model, value)
        owner, attribute = held if held is not None else (None, None)
        values = getattr(owner, attribute, None) if attribute is not None else None
        measured = {
            "value_id": value.id,
            "owner": _summary(owner),
            "attribute": attribute,
            "index": next((i for i, item in enumerate(values) if item is value), None)
            if isinstance(values, list)
            else None,
        }
    return {
        "process_step": _summary(activity.__dict__.get("processStepReference")),
        "process_step_detail": _summary(activity.__dict__.get("processStepDetailReference")),
        "connection": _summary(activity.__dict__.get("connectionReference")),
        "measured_value": measured,
    }


def _owner_record(
    model: PyDexpiBaseModel,
    process_model: ProcessModel,
    owner: PyDexpiBaseModel,
    delegations: _Delegations,
) -> dict[str, Any]:
    """A step, a step detail or an instrumentation activity: its ports, then, for a step, the
    step it is inside (``parent_step``, null at the top level), its sub-steps and details.

    A step detail adds the ``step`` that holds it. An instrumentation activity adds the
    ``system`` that holds it, and whatever an installed extension adds there. A
    ``MeasuringProcessVariable`` adds its ``measurement`` (:func:`_measurement`).
    """
    ports = ports_of(owner)
    endings = _endings(model, ports)
    record: dict[str, Any] = {
        "kind": "port_owner",
        "object": object_summary(owner),
        "port_order": PORT_ORDER,
        "ports": [_port_record(model, port, endings[id(port)], delegations) for port in ports],
    }
    if isinstance(owner, ProcessStep):
        record["parent_step"] = _summary(delegations.tree.parent_of(owner))
        record["sub_steps"] = [object_summary(s) for s in owner.subProcessSteps or []]
        record["details"] = [object_summary(d) for d in owner.processStepDetails or []]
    if isinstance(owner, ProcessStepDetail):
        record["step"] = _summary(step_holding(process_model, owner))
    if isinstance(owner, InstrumentationActivity):
        system = system_holding(process_model, owner)
        record["system"] = _summary(system)
        record.update(delegations.fields("instrumentation_activity", process_model, owner, system))
        if isinstance(owner, MeasuringProcessVariable):
            record["measurement"] = _measurement(model, owner)
    if isinstance(owner, (ProcessStep, InstrumentationActivity)):
        record["drawing"] = _drawing(model, owner)
    return record


def _system_record(system: InstrumentationSystemActivity) -> dict[str, Any]:
    """An instrumentation system: the activities it holds, in list order.

    DEXPI requires a system to hold at least one.
    """
    return {
        "kind": "instrumentation_system",
        "object": object_summary(system),
        "activities": [object_summary(a) for a in system.instrumentationActivities or []],
    }


def _connection_end(owners: dict, port: Port | None) -> dict[str, Any]:
    owner = owners.get(id(port)) if port is not None else None
    return {"port": _summary(port), "owner": _summary(owner[0]) if owner else None}


def _connection_record(
    model: PyDexpiBaseModel, process_model: ProcessModel, connection: ProcessConnection
) -> dict[str, Any]:
    """A connection's two ends with their owners; for a stream, the material it carries.

    A stream's ``component_order`` is its state's (:func:`state_component_order`, over every
    stream sharing the state), with ``state_conflicts`` naming the pairings that disagree with
    it; without a state it is the first template, the stream's own or an end port's, that lists
    its components. ``template_conflicts`` compares the stream's template with its ports'.
    """
    owners = port_owners(model)
    record: dict[str, Any] = {
        "kind": "connection",
        "object": object_summary(connection),
        "source": _connection_end(owners, connection.__dict__.get("source")),
        "target": _connection_end(owners, connection.__dict__.get("target")),
        "lines": _lines(model, connection),
    }
    record["drawn"] = bool(record["lines"])
    if isinstance(connection, Stream):
        state = connection.__dict__.get("materialStateReference")
        state_conflicts: list = []
        if state is not None:
            ids, state_conflicts = state_component_order(process_model, state)
        else:
            ids = next(
                (
                    known
                    for pairing in stream_pairings(connection)
                    if (known := component_ids(pairing.template)) is not None
                ),
                None,
            )
        record["material"] = {
            "template": _summary(connection.__dict__.get("materialTemplateReference")),
            "state": _summary(state),
            "component_order": _components(process_model, ids),
            "state_conflicts": _bounded(state_conflicts),
            "template_conflicts": _bounded(stream_template_conflicts(connection)),
        }
    return record


def _state_record(process_model: ProcessModel, state: MaterialState) -> dict[str, Any]:
    """A material state: the streams that read it, the component order and its vectors."""
    ids, conflicts = state_component_order(process_model, state)
    vectors = [
        {
            "state_type": object_summary(vector.state_type),
            "attribute": vector.attribute,
            "value_id": vector.qualified_value.id,
            "length": vector.length,
            "fits": None if ids is None or vector.length is None else vector.length == len(ids),
        }
        for vector in fraction_vectors(state)
    ]
    return {
        "kind": "material_state",
        "object": object_summary(state),
        "streams": [object_summary(s) for s in streams_referencing(process_model, state)],
        "template": _summary(reading_template(process_model, state)),
        "component_order": _components(process_model, ids),
        "conflicts": _bounded(conflicts),
        "fraction_vectors": vectors,
    }


def describe_process_object(
    model: PyDexpiBaseModel, obj: PyDexpiBaseModel, fields: ItemFields = NO_ITEM_FIELDS
) -> dict | None:
    """The ``describe_item`` record of *obj* in a process model, or None for any other object.

    A step, a step detail or an instrumentation activity (anything that holds ports), a port, a
    connection, an instrumentation system and a material state each get a record whose
    ``kind`` says which. A port's record is its owner's, with ``port`` naming the one asked
    about. *fields* are what the server's extensions add (:mod:`pydexpi.mcp_server.extensions`).
    """
    process_model = getattr(model, "conceptualModel", None)
    if not isinstance(process_model, ProcessModel):
        return None
    if port_slot(obj) is not None:
        return _owner_record(model, process_model, obj, _Delegations(model, process_model, fields))
    if isinstance(obj, InstrumentationSystemActivity):
        return _system_record(obj)
    if isinstance(obj, Port):
        owner = port_owners(model).get(id(obj))
        delegations = _Delegations(model, process_model, fields)
        return {
            "kind": "port",
            "object": object_summary(obj),
            "owner": _summary(owner[0]) if owner else None,
            **_port_record(model, obj, _endings(model, [obj])[id(obj)], delegations),
        }
    if isinstance(obj, ProcessConnection):
        return _connection_record(model, process_model, obj)
    if isinstance(obj, MaterialState):
        return _state_record(process_model, obj)
    return None
