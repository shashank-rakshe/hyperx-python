"""Control-loop inference.

Loops are inferred in two steps:

1. **Tag grouping (ISA-5.1).** Instruments and actuated components sharing a
   measured-variable letter and loop number (FT-101, FIC-101, FV-101) form a
   loop ``F-101``. An explicit ``loop`` on an item overrides this.
2. **Signal tracing.** Signal lines refine the groups: a controller's output
   is followed (through relays such as I/P converters) to the final element it
   moves, even when the numbers differ; controller-to-controller signals
   become cascades; and sensors wired into a controller from another loop
   number are added as inputs.
"""

from __future__ import annotations

from collections import defaultdict
from typing import TYPE_CHECKING, Optional

from .models import Node
from .ontology import ACTUATED_COMPONENT_KINDS

if TYPE_CHECKING:  # pragma: no cover
    from .build import GraphBuilder

SENSOR_ROLES = {"transmitter", "element", "switch", "gauge", "indicator", "recorder", "totalizer", "alarm"}
READOUT_ROLES = {"indicator", "recorder", "totalizer", "alarm"}
PANEL_LOCATIONS = {"main_panel", "behind_panel", "dcs", "plc", "scada", "sis", "computer"}


def _member_role(n: Node) -> str:
    """Role within a loop: panel indicators and alarms are read-outs, not sensors."""
    r = _role(n)
    if r in READOUT_ROLES and n.attributes.get("location") in PANEL_LOCATIONS:
        return "readout"
    return r


def loop_variable(key: str) -> Optional[str]:
    """Measured variable named by a loop key such as 'F-101', '660-F-0502' or 'S-1@M702'."""
    from .ontology import ISA_MEASURED, ISA_VARIABLE_MODIFIERS

    core = key.split("@")[0].split("#")[0]
    parts = core.split("-")
    code = parts[-2] if len(parts) >= 2 else ""
    if not code or code[0] not in ISA_MEASURED:
        return None
    var = ISA_MEASURED[code[0]]
    if len(code) > 1 and code[1] in ISA_VARIABLE_MODIFIERS:
        var = f"{ISA_VARIABLE_MODIFIERS[code[1]]} {var}"
    return var


def _role(n: Node) -> str:
    if n.type == "Component":
        if n.kind == "relief_valve" or n.attributes.get("role") == "relief_device":
            return "relief_device"
        return "final_element"
    if n.type == "Equipment":
        return "final_element"
    return n.attributes.get("role", "other")


def _is_final(n: Node) -> bool:
    if n.type == "Component":
        return n.kind in ACTUATED_COMPONENT_KINDS or n.attributes.get("role") == "final_element" \
            or n.attributes.get("actuator") not in (None, "manual", "none", "self")
    if n.type == "Equipment":
        return True  # e.g. a pump motor / VFD driven by a speed controller
    return n.attributes.get("role") == "final_element"


def derive_loops(b: "GraphBuilder") -> None:
    nodes = b.nodes
    sig_out: dict[str, list[str]] = defaultdict(list)
    sig_in: dict[str, list[str]] = defaultdict(list)
    sig_purpose: dict[tuple[str, str], str] = {}
    for e in b.edges:
        if e.type == "SIGNAL_TO":
            sig_out[e.source].append(e.target)
            sig_in[e.target].append(e.source)
            sig_purpose[(e.source, e.target)] = e.attributes.get("purpose", "unknown")

    # 1. Group by loop key.
    groups: dict[str, dict[str, str]] = defaultdict(dict)  # loop key -> {node id: role}
    for n in nodes.values():
        key = n.attributes.get("loop_key")
        if key and n.type in ("Instrument", "Component"):
            groups[key][n.id] = _member_role(n)

    # 2. Refine with signals.
    cascades: set[tuple[str, str]] = set()
    loop_of = {nid: key for key, members in groups.items() for nid in members}
    for key, members in list(groups.items()):
        for cid in [m for m, r in members.items() if r == "controller"]:
            for target, via in _trace_outputs(cid, sig_out, nodes):
                tn = nodes[target]
                if tn.type == "Instrument" and tn.attributes.get("role") == "controller":
                    other = loop_of.get(target)
                    if other and other != key:
                        cascades.add((key, other))
                    continue
                if _is_final(tn):
                    members.setdefault(target, "final_element")
                    for r in via:
                        members.setdefault(r, "relay")
                    b._edge(cid, target, "ACTUATES", derived=True,
                            via=[nodes[r].label for r in via] or None)
            for src in sig_in.get(cid, []):
                sn = nodes[src]
                if sn.type == "Instrument" and sn.attributes.get("role") in SENSOR_ROLES:
                    members.setdefault(src, "sensor_input")

        # Sensors or hand switches wired straight to a final element (interlocks,
        # on/off logic in a PLC that is not drawn as a controller).
        for sid in [m for m, r in members.items() if r in ("switch", "hand_switch", "transmitter", "alarm", "other")]:
            for target, via in _trace_outputs(sid, sig_out, nodes):
                if _is_final(nodes[target]) and target not in members:
                    members[target] = "final_element"
                    b._edge(sid, target, "ACTUATES", derived=True,
                            via=[nodes[r].label for r in via] or None)

    # 3. Emit loop nodes for meaningful groups.
    loop_ids: dict[str, str] = {}
    for key, members in sorted(groups.items()):
        roles = set(members.values())
        if len(members) < 2 and "controller" not in roles:
            continue
        lid = f"LOOP:{key}"
        loop_ids[key] = lid
        loop_type = _loop_type(members, nodes, sig_purpose)
        variable = loop_variable(key) or next((nodes[m].attributes.get("variable") for m in members
                                               if nodes[m].attributes.get("variable")), None)
        sheets: list[str] = []
        for m in members:
            for s in nodes[m].sheets:
                if s not in sheets:
                    sheets.append(s)
        sensors = [m for m, r in members.items() if r in SENSOR_ROLES or r == "sensor_input"]
        controllers = [m for m, r in members.items() if r == "controller"]
        finals = [m for m, r in members.items() if r == "final_element"]
        measured_at = _measured_points(sensors, b)
        manipulated_at = _manipulated_points(finals, b)
        node = Node(
            id=lid, type="ControlLoop", label=key, kind=loop_type, sheets=sheets,
            confidence=min(nodes[m].confidence for m in members),
            dexpi_class="InstrumentationLoopFunction",
            attributes={k: v for k, v in dict(
                variable=variable, loop_type=loop_type, sensors=sensors, controllers=controllers,
                final_elements=finals, relays=[m for m, r in members.items() if r == "relay"],
                readouts=[m for m, r in members.items() if r == "readout"],
                measured_at=measured_at, manipulated_at=manipulated_at).items() if v})
        node.attributes["description"] = _describe(node, b)
        b._upsert(node)
        for m, role in members.items():
            b._edge(m, lid, "MEMBER_OF", derived=True, role=role)
        if loop_type == "interlock":
            for s in sensors:
                for f in finals:
                    b._edge(s, f, "TRIPS", derived=True, loop=lid)

    for master, slave in sorted(cascades):
        if master in loop_ids and slave in loop_ids:
            b._edge(loop_ids[master], loop_ids[slave], "CASCADES_TO", derived=True)
            b.nodes[loop_ids[master]].attributes.setdefault("cascade_slaves", []).append(loop_ids[slave])
            b.nodes[loop_ids[slave]].attributes["cascade_master"] = loop_ids[master]
    for lid in loop_ids.values():
        ln = b.nodes[lid]
        if ln.attributes.get("cascade_slaves") or ln.attributes.get("cascade_master"):
            ln.attributes["description"] = _describe(ln, b)

    # 4. QA on loop completeness.
    for key, lid in loop_ids.items():
        ln = b.nodes[lid]
        a = ln.attributes
        if ln.kind == "control":
            if not a.get("final_elements") and not a.get("cascade_slaves"):
                b.issue("warning", "loop_no_final_element",
                        f"control loop {key} has a controller but no final element", node=lid)
            if not a.get("sensors"):
                # Common for speed/position controllers that only take an operator setpoint.
                b.issue("info", "loop_no_sensor",
                        f"control loop {key} has a controller but no sensor", node=lid)
        for c in a.get("controllers", []):
            if not sig_in.get(c) and not sig_out.get(c):
                b.issue("info", "loop_no_signals",
                        f"controller {c} has no signal lines; loop {key} built from tag numbers only",
                        node=c)


def _trace_outputs(start: str, sig_out: dict[str, list[str]], nodes: dict[str, Node],
                   max_depth: int = 4) -> list[tuple[str, list[str]]]:
    """Follow signals from ``start`` through relays; return (endpoint, relays) pairs."""
    results: list[tuple[str, list[str]]] = []
    stack = [(t, []) for t in sig_out.get(start, [])]
    seen = {start}
    while stack:
        nid, via = stack.pop()
        if nid in seen or len(via) > max_depth:
            continue
        seen.add(nid)
        n = nodes[nid]
        if n.type == "Instrument" and n.attributes.get("role") in ("relay", "other") and sig_out.get(nid):
            for t in sig_out[nid]:
                stack.append((t, via + [nid]))
            continue
        results.append((nid, via))
    return results


def _loop_type(members: dict[str, str], nodes: dict[str, Node],
               sig_purpose: dict[tuple[str, str], str]) -> str:
    roles = set(members.values())
    if any(p == "trip" for (a, _), p in sig_purpose.items() if a in members):
        return "interlock"
    if "controller" in roles:
        return "control"
    variables = {nodes[m].attributes.get("variable") for m in members}
    if "final_element" in roles:
        if "hand" in variables or "hand_switch" in roles:
            return "manual"
        process_switch = any(r in ("switch", "alarm") and nodes[m].attributes.get("variable") not in
                             ("event/state", "unclassified", "position", "hand")
                             for m, r in members.items())
        if process_switch:
            return "interlock"
        if roles & {"transmitter", "element", "sensor_input"}:
            # Sensor and final element share a loop but no controller is drawn:
            # the control function lives in a PLC/DCS not shown on the sheet.
            return "control"
        return "on_off"
    return "monitoring"


def sensed_points(nid: str, nodes: dict[str, Node], edges: list) -> list[str]:
    """Where an instrument senses the process, as human-readable labels."""
    if nodes[nid].attributes.get("inline"):
        return [point_label(nid, nodes, edges)]
    return [point_label(e.target, nodes, edges) for e in edges
            if e.type == "MEASURES" and e.source == nid]


def _measured_points(sensors: list[str], b: "GraphBuilder") -> list[str]:
    out: list[str] = []
    for s in sensors:
        for lbl in sensed_points(s, b.nodes, b.edges):
            if lbl not in out:
                out.append(lbl)
    return out


def _manipulated_points(finals: list[str], b: "GraphBuilder") -> list[str]:
    out: list[str] = []
    for f in finals:
        n = b.nodes[f]
        if n.type == "Equipment":
            continue
        lines = {b.nodes[e.source].attributes.get("line_number") for e in b.edges
                 if e.type == "FLOWS_TO" and e.target == f and b.nodes[e.source].type == "PipeSegment"}
        lines.discard(None)
        if lines:
            out.append(f"{n.label} on {', '.join(sorted(lines))}")
    return out


def point_label(nid: str, nodes: dict[str, Node], edges: list) -> str:
    """Human-readable process location.

    An item gives its label; a pipe segment or an in-line instrument gives
    ``line (nearest upstream item -> nearest downstream item)``.
    """
    n = nodes[nid]
    inline = n.type == "Instrument" and n.attributes.get("inline")
    if n.type != "PipeSegment" and not inline:
        return n.label
    up = _nearest(nid, nodes, edges, upstream=True)
    down = _nearest(nid, nodes, edges, upstream=False)
    line = n.attributes.get("line_number")
    if not line:
        line = next((nodes[e.source].attributes.get("line_number") for e in edges
                     if e.type == "FLOWS_TO" and e.target == nid
                     and nodes[e.source].type == "PipeSegment"), None)
    where = f"{line or 'line'} ({up or '?'} -> {down or '?'})"
    return f"in-line on {where}" if inline else where


def _nearest(start: str, nodes: dict[str, Node], edges: list, upstream: bool,
             limit: int = 50) -> Optional[str]:
    """Nearest equipment/component/boundary label upstream or downstream of a segment."""
    adj: dict[str, list[str]] = defaultdict(list)
    for e in edges:
        if e.type == "FLOWS_TO":
            if upstream:
                adj[e.target].append(e.source)
            else:
                adj[e.source].append(e.target)
    frontier, seen = [start], {start}
    for _ in range(limit):
        nxt = []
        for nid in frontier:
            for other in adj[nid]:
                if other in seen:
                    continue
                seen.add(other)
                if nodes[other].type in ("Equipment", "Boundary", "Component", "Instrument",
                                         "OffPageConnector"):
                    return nodes[other].label
                nxt.append(other)
        if not nxt:
            return None
        frontier = nxt
    return None


def _describe(loop: Node, b: "GraphBuilder") -> str:
    a = loop.attributes
    lbl = lambda ids: ", ".join(b.nodes[i].label for i in ids)  # noqa: E731
    var = a.get("variable") or "process"
    parts = [f"{loop.kind.replace('_', ' ').capitalize()} loop {loop.label} ({var})."]
    if a.get("sensors"):
        where = f" ({'; '.join(a['measured_at'])})" if a.get("measured_at") else ""
        parts.append(f"Sensed by {lbl(a['sensors'])}{where}.")
    if a.get("controllers"):
        locs = {b.nodes[c].attributes.get('location', 'unknown') for c in a["controllers"]}
        parts.append(f"Controlled by {lbl(a['controllers'])} ({', '.join(sorted(locs))}).")
    if a.get("final_elements"):
        placed = {m.split(" on ")[0]: m for m in a.get("manipulated_at", [])}
        acts = [placed.get(b.nodes[f].label, b.nodes[f].label) for f in a["final_elements"]]
        parts.append(f"Acts on {'; '.join(acts)}.")
    if a.get("cascade_slaves"):
        parts.append(f"Cascade master: sets the setpoint of {lbl(a['cascade_slaves'])}.")
    if a.get("cascade_master"):
        parts.append(f"Cascade slave of {b.nodes[a['cascade_master']].label}.")
    return " ".join(parts)
