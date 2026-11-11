#!/usr/bin/env python3
"""Query a P&ID knowledge graph (for people, and as a tool for LLM agents).

Usage:
    python kg_query.py KG stats
    python kg_query.py KG describe 660-TK-004
    python kg_query.py KG upstream FV-0502 [--equipment] [--depth 3]
    python kg_query.py KG downstream 660-TK-001 [--equipment]
    python kg_query.py KG path 660-TK-001 660-TK-004
    python kg_query.py KG loops [--type control]
    python kg_query.py KG loop F-0502
    python kg_query.py KG instruments [--on 660-PP-011] [--variable flow]
    python kg_query.py KG sql "SELECT * FROM equipment_flow"

KG is a kg/ directory, graph.json or graph.duckdb. Add --json for machine-readable output.
Item references accept ids, tags or labels; tags are matched loosely (FIT0502 = FIT-0502).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from pidkg.loops import point_label, sensed_points  # noqa: E402
from pidkg.store import Graph  # noqa: E402

TERMINAL = ("Equipment", "Boundary")


def _resolve_paths(kg: Path) -> tuple[Path, Path]:
    if kg.is_dir():
        return kg / "graph.json", kg / "graph.duckdb"
    if kg.suffix == ".duckdb":
        return kg.with_name("graph.json"), kg
    return kg, kg.with_name("graph.duckdb")


def _node_brief(g: Graph, nid: str) -> dict:
    n = g.nodes[nid]
    d = {"id": n.id, "type": n.type, "label": n.label}
    if n.kind:
        d["kind"] = n.kind
    if n.name:
        d["name"] = n.name
    return d


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("kg", type=Path)
    ap.add_argument("command", choices=["stats", "describe", "upstream", "downstream", "path",
                                        "loops", "loop", "instruments", "sql"])
    ap.add_argument("args", nargs="*")
    ap.add_argument("--equipment", action="store_true", help="only equipment and boundaries")
    ap.add_argument("--depth", type=int)
    ap.add_argument("--type", help="loop type filter")
    ap.add_argument("--on", help="instruments measuring this item (or anything on it)")
    ap.add_argument("--variable", help="instrument variable filter, e.g. flow")
    ap.add_argument("--include-pfd", action="store_true",
                    help="also traverse PFD-sheet flow when the plant has P&IDs (default: P&ID detail only)")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")

    json_path, db_path = _resolve_paths(a.kg)

    if a.command == "sql":
        import duckdb

        con = duckdb.connect(str(db_path), read_only=True)
        rel = con.sql(" ".join(a.args))
        if a.json:
            cols = rel.columns
            print(json.dumps([dict(zip(cols, r)) for r in rel.fetchall()], indent=1, default=str))
        else:
            rel.show(max_width=200, max_rows=200)
        return 0

    g = Graph.load(json_path, include_pfd=a.include_pfd)

    def need(n: int) -> list[str]:
        if len(a.args) < n:
            ap.error(f"'{a.command}' needs {n} item reference(s)")
        ids = []
        for ref in a.args[:n]:
            nid = g.find(ref)
            if nid is None:
                print(f"error: '{ref}' not found in the graph", file=sys.stderr)
                sys.exit(2)
            ids.append(nid)
        return ids

    result: object
    if a.command == "stats":
        result = {"plant": g.kg.plant.model_dump(), **g.kg.stats}
    elif a.command == "describe":
        (nid,) = need(1)
        n = g.nodes[nid]
        result = {**n.model_dump(exclude_none=True, exclude={"provenance"}),
                  "relations": g.neighbors(nid)}
        if n.type == "PipeSegment":
            result["location"] = point_label(nid, g.nodes, g.kg.edges)
    elif a.command in ("upstream", "downstream"):
        (nid,) = need(1)
        hits = g.walk(nid, "down" if a.command == "downstream" else "up", max_depth=a.depth)
        rows = [dict(_node_brief(g, h), hops=d) for h, d in hits
                if not a.equipment or g.nodes[h].type in TERMINAL]
        result = {"from": _node_brief(g, nid), "direction": a.command, "items": rows}
    elif a.command == "path":
        x, y = need(2)
        p = g.path(x, y) or g.path(y, x)
        result = {"path": [_node_brief(g, i) for i in p]} if p else {"path": None,
                  "note": "no directed flow path between these items"}
    elif a.command == "loops":
        loops = [n for n in g.kg.nodes if n.type == "ControlLoop" and (not a.type or n.kind == a.type)]
        result = [{"id": n.id, "loop": n.label, "type": n.kind,
                   "description": n.attributes.get("description")} for n in loops]
    elif a.command == "loop":
        ref = a.args[0] if a.args else ap.error("'loop' needs a loop id")
        nid = g.find(ref) or g.find(f"LOOP:{ref}")
        if nid is None or g.nodes[nid].type != "ControlLoop":
            # Accept a member tag, e.g. 'loop FIC-0502'.
            member = g.find(ref)
            nid = next((e.target for e in g.out.get(member, []) if e.type == "MEMBER_OF"), None) \
                if member else None
        if nid is None:
            print(f"error: loop '{ref}' not found", file=sys.stderr)
            return 2
        n = g.nodes[nid]
        members = [dict(_node_brief(g, e.source), role=e.attributes.get("role"))
                   for e in g.inn[nid] if e.type == "MEMBER_OF"]
        result = {**n.model_dump(exclude_none=True, exclude={"provenance"}), "members": members}
    else:  # instruments
        target_ids: set[str] | None = None
        if a.on:
            t = g.find(a.on)
            if t is None:
                print(f"error: '{a.on}' not found", file=sys.stderr)
                return 2
            # The item plus its own piping: everything reachable up- and downstream
            # before the next piece of equipment.
            target_ids = {t} | _local_piping(g, t)
        rows = []
        for n in g.kg.nodes:
            if n.type != "Instrument":
                continue
            if a.variable and a.variable.lower() not in (n.attributes.get("variable") or "").lower():
                continue
            meas = {e.target for e in g.out[n.id] if e.type == "MEASURES"}
            if target_ids is not None and not ((meas | {n.id}) & target_ids):
                continue
            rows.append({"tag": n.label, "variable": n.attributes.get("variable"),
                         "role": n.attributes.get("role"), "location": n.attributes.get("location"),
                         "measures": sensed_points(n.id, g.nodes, g.kg.edges),
                         "loop": [g.nodes[e.target].label for e in g.out[n.id] if e.type == "MEMBER_OF"]})
        result = rows

    if a.json:
        print(json.dumps(result, indent=1, default=str))
    else:
        _print_text(result)
    return 0


def _local_piping(g: Graph, start: str, limit: int = 8) -> set[str]:
    """Segments and fittings within ``limit`` hops of an item, stopping at equipment."""
    found: set[str] = set()
    for direction in ("down", "up"):
        frontier = [start]
        while frontier and len(found) < 500:
            nxt = []
            for cur in frontier:
                edges = g.out[cur] if direction == "down" else g.inn[cur]
                for e in edges:
                    if e.type != "FLOWS_TO":
                        continue
                    other = e.target if direction == "down" else e.source
                    if other in found or other == start or g.nodes[other].type in TERMINAL:
                        continue
                    found.add(other)
                    nxt.append(other)
            frontier = nxt
            limit -= 1
            if limit <= 0:
                break
    return found


def _print_text(obj, indent: int = 0) -> None:
    pad = "  " * indent
    if isinstance(obj, list):
        if not obj:
            print(pad + "(none)")
        for item in obj:
            if isinstance(item, dict):
                print(pad + "- " + ", ".join(f"{k}: {_fmt(v)}" for k, v in item.items()))
            else:
                print(pad + f"- {item}")
    elif isinstance(obj, dict):
        for k, v in obj.items():
            if isinstance(v, (dict, list)) and v and any(isinstance(x, (dict, list)) for x in
                                                        (v.values() if isinstance(v, dict) else v)):
                print(f"{pad}{k}:")
                _print_text(v, indent + 1)
            else:
                print(f"{pad}{k}: {_fmt(v)}")
    else:
        print(pad + str(obj))


def _fmt(v) -> str:
    if isinstance(v, list):
        return "[" + ", ".join(_fmt(x) for x in v) + "]"
    if isinstance(v, dict):
        return "{" + ", ".join(f"{k}: {_fmt(x)}" for k, x in v.items()) + "}"
    return str(v)


if __name__ == "__main__":
    sys.exit(main())
