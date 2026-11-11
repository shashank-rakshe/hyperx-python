"""Compact Markdown summary of a knowledge graph, written for LLM context windows."""

from __future__ import annotations

from collections import defaultdict
from typing import Optional

from .loops import sensed_points
from .models import KnowledgeGraph
from .store import Graph


def _esc(s: Optional[str]) -> str:
    return (s or "").replace("|", "\\|").replace("\n", " ")


def _flow_order(g: Graph) -> list[str]:
    """Equipment/boundaries in reading order: sources first, then breadth-first along FEEDS."""
    feeds_in: dict[str, int] = defaultdict(int)
    terminals = [n.id for n in g.kg.nodes if n.type in ("Equipment", "Boundary")]
    for e in g.kg.edges:
        if e.type == "FEEDS":
            feeds_in[e.target] += 1
    starts = [t for t in terminals if feeds_in[t] == 0]
    starts.sort(key=lambda t: (g.nodes[t].type != "Boundary", g.nodes[t].sheets[:1], t))
    order: list[str] = []
    seen: set[str] = set()
    for s in starts + terminals:
        if s in seen:
            continue
        queue = [s]
        while queue:
            cur = queue.pop(0)
            if cur in seen:
                continue
            seen.add(cur)
            order.append(cur)
            queue.extend(e.target for e in g.out[cur] if e.type == "FEEDS")
    return order


def write_summary(kg: KnowledgeGraph) -> str:
    g = Graph(kg)
    nodes = g.nodes
    sheets = [n for n in kg.nodes if n.type == "Sheet"]
    sheets.sort(key=lambda n: n.attributes.get("page", 0))
    st = kg.stats
    out: list[str] = []
    w = out.append

    w(f"# {kg.plant.name}: process knowledge graph summary")
    w("")
    w(f"Built from `{kg.plant.source_file or 'P&IDs'}` ({len(sheets)} sheets) by {kg.generator} "
      f"on {kg.generated_at[:10]}. The graph has {st.get('nodes', 0)} nodes and "
      f"{st.get('edges', 0)} edges; this summary covers equipment-level flow, instruments and "
      "control loops. Query `graph.duckdb` or `graph.json` for pipe-segment and valve detail.")
    w("")
    nbt = st.get("nodes_by_type", {})
    w("| Equipment | Instruments | Valves & fittings | Pipe segments | Control loops | Off-page links |")
    w("|---|---|---|---|---|---|")
    w(f"| {nbt.get('Equipment', 0)} | {nbt.get('Instrument', 0)} | {nbt.get('Component', 0)} | "
      f"{nbt.get('PipeSegment', 0)} | {nbt.get('ControlLoop', 0)} | {nbt.get('OffPageConnector', 0)} |")
    w("")

    w("## Sheets")
    w("")
    w("| Page | Drawing | Title | Type |")
    w("|---|---|---|---|")
    for s in sheets:
        a = s.attributes
        w(f"| {a.get('page', '')} | {_esc(a.get('drawing_number'))} | {_esc(a.get('title'))} | "
          f"{a.get('drawing_type', '')} |")
    w("")

    w("## Process flow (equipment to equipment)")
    w("")
    w("Each line reads *upstream → downstream*, with the pipe lines and in-line items between them. "
      "Pipes, valves and instruments are collapsed; use `kg_query.py path` for the full route.")
    w("")
    drains: dict[str, set[str]] = defaultdict(set)
    for nid in _flow_order(g):
        feeds = [e for e in g.out[nid] if e.type == "FEEDS"]
        for e in [e for e in feeds if _is_drain(nodes[e.target])]:
            drains[nodes[e.target].label].add(nodes[nid].label)
        feeds = [e for e in feeds if not _is_drain(nodes[e.target])]
        if not feeds:
            continue
        n = nodes[nid]
        head = f"**{n.label}**" + (f" ({_esc(n.name)})" if n.name and n.name != n.label else "")
        for e in feeds:
            t = nodes[e.target]
            via = []
            if e.attributes.get("via_lines"):
                via.append("lines " + ", ".join(e.attributes["via_lines"]))
            if e.attributes.get("via_items"):
                via.append("through " + ", ".join(e.attributes["via_items"]))
            if e.attributes.get("off_page"):
                via.append("crosses sheets")
            tname = f" ({_esc(t.name)})" if t.name and t.name != t.label else ""
            w(f"- {head} → **{t.label}**{tname}" + (f": {'; '.join(via)}" if via else ""))
    if drains:
        w("")
        w("Drains, vents and overflows (not process flow):")
        for d, srcs in sorted(drains.items()):
            w(f"- {d} ← {', '.join(sorted(srcs))}")
    w("")

    w("## Equipment")
    w("")
    w("| Tag | Kind | Description | Fed by | Feeds | Status | Sheets |")
    w("|---|---|---|---|---|---|---|")
    for n in sorted((n for n in kg.nodes if n.type == "Equipment"), key=lambda n: n.label):
        ups = sorted({nodes[e.source].label for e in g.inn[n.id] if e.type == "FEEDS"})
        downs = sorted({nodes[e.target].label for e in g.out[n.id] if e.type == "FEEDS"})
        w(f"| {n.label} | {n.kind or ''} | {_esc(n.name)} | {', '.join(ups)} | {', '.join(downs)} | "
          f"{n.status or ''} | {', '.join(_sheet_labels(n.sheets, nodes))} |")
    w("")

    w("## Instruments")
    w("")
    w("Location is where the instrument senses the process. Pipe locations read "
      "`line (upstream item -> downstream item)`.")
    w("")
    w("| Tag | Variable | Function | Mounted | Senses | Loop |")
    w("|---|---|---|---|---|---|")
    for n in sorted((n for n in kg.nodes if n.type == "Instrument"), key=lambda n: n.label):
        a = n.attributes
        senses = sensed_points(n.id, nodes, kg.edges)
        loops = [nodes[e.target].label for e in g.out[n.id] if e.type == "MEMBER_OF"]
        w(f"| {n.label} | {a.get('variable', '')} | {a.get('role', '')} | {a.get('location', '')} | "
          f"{_esc('; '.join(senses))} | {', '.join(loops)} |")
    w("")

    loops = [n for n in kg.nodes if n.type == "ControlLoop"]
    w("## Control loops")
    w("")
    if not loops:
        w("No control loops were identified.")
    else:
        w("| Loop | Type | Sensor(s) | Controller(s) | Final element(s) | Description |")
        w("|---|---|---|---|---|---|")
        lab = lambda ids: ", ".join(nodes[i].label for i in ids if i in nodes)  # noqa: E731
        for n in sorted(loops, key=lambda n: n.label):
            a = n.attributes
            w(f"| {n.label} | {n.kind} | {lab(a.get('sensors', []))} | {lab(a.get('controllers', []))} | "
              f"{lab(a.get('final_elements', []))} | {_esc(a.get('description'))} |")
    w("")

    opcs = [n for n in kg.nodes if n.type == "OffPageConnector"]
    if opcs:
        w("## Off-page connections")
        w("")
        w("| Sheet | Connector | Direction | Other drawing | Linked to |")
        w("|---|---|---|---|---|")
        for n in sorted(opcs, key=lambda n: n.id):
            a = n.attributes
            link = a.get("linked_to") or a.get("linked_from") or a.get("linked_item") or "unmatched"
            if link in nodes:
                link = f"{nodes[link].label} ({', '.join(_sheet_labels(nodes[link].sheets, nodes))})"
            w(f"| {', '.join(_sheet_labels(n.sheets, nodes))} | {_esc(n.label)} | {a.get('direction', '')} | "
              f"{_esc(a.get('other_drawing'))} | {_esc(link)} |")
        w("")

    sev = st.get("issues_by_severity", {})
    w("## Data quality")
    w("")
    w(f"{sev.get('error', 0)} errors, {sev.get('warning', 0)} warnings and {sev.get('info', 0)} "
      "informational items; see `qa_report.md`. Every node carries `confidence` and the sheet "
      "region it was read from (`provenance`). This graph was machine-extracted from drawings "
      "and must be verified by a qualified engineer before use in design, operations or safety work.")
    return "\n".join(out) + "\n"


_DRAIN_WORDS = ("DRAIN", "VENT", "OVERFLOW", "SUMP")


def _is_drain(n) -> bool:
    return n.type == "Boundary" and any(w in (n.label or "").upper() for w in _DRAIN_WORDS[:3])


def _sheet_labels(sheet_ids: list[str], nodes) -> list[str]:
    return [nodes[s].label if s in nodes else s for s in sheet_ids]
