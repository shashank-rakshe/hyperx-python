#!/usr/bin/env python3
"""Export a knowledge graph to GraphML or a Neo4j import bundle.

    python export.py work/my-plant/kg graphml          # -> graph.graphml (yEd, Gephi, NetworkX)
    python export.py work/my-plant/kg neo4j            # -> neo4j/nodes.csv, edges.csv, import.cypher

Node types become Neo4j labels and edge types become relationship types.
Nested attributes are flattened to scalar properties where possible and kept
whole as a JSON string in ``attributes_json``.
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from pidkg.store import Graph  # noqa: E402


def _scalar(v):
    if v is None or isinstance(v, (str, int, float, bool)):
        return v
    return json.dumps(v)


def _node_props(n) -> dict:
    props = {"id": n.id, "type": n.type, "label": n.label, "tag": n.tag, "kind": n.kind,
             "name": n.name, "status": n.status, "dexpi_class": n.dexpi_class,
             "sheets": ";".join(n.sheets), "confidence": n.confidence,
             "attributes_json": json.dumps(n.attributes)}
    for k, v in n.attributes.items():
        props.setdefault(f"a_{k}", _scalar(v))
    return {k: v for k, v in props.items() if v is not None}


def export_graphml(g: Graph, path: Path) -> None:
    import networkx as nx

    G = nx.MultiDiGraph(plant=g.kg.plant.name)
    for n in g.kg.nodes:
        G.add_node(n.id, **_node_props(n))
    for e in g.kg.edges:
        attrs = {"type": e.type, "confidence": e.confidence, "derived": e.derived,
                 "attributes_json": json.dumps(e.attributes)}
        if e.sheet:
            attrs["sheet"] = e.sheet
        G.add_edge(e.source, e.target, key=e.id, **attrs)
    nx.write_graphml(G, path)


def export_neo4j(g: Graph, out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    keys = ["id", "type", "label", "tag", "kind", "name", "status", "dexpi_class", "sheets",
            "confidence", "attributes_json"]
    with open(out / "nodes.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=keys, extrasaction="ignore")
        w.writeheader()
        for n in g.kg.nodes:
            w.writerow(_node_props(n))
    with open(out / "edges.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["id", "source", "target", "type", "confidence", "derived", "sheet", "attributes_json"])
        for e in g.kg.edges:
            w.writerow([e.id, e.source, e.target, e.type, e.confidence, e.derived, e.sheet or "",
                        json.dumps(e.attributes)])
    node_types = sorted({n.type for n in g.kg.nodes})
    edge_types = sorted({e.type for e in g.kg.edges})
    plant = g.kg.plant.id
    lines = [
        f"// Neo4j import for plant '{g.kg.plant.name}'. Copy nodes.csv and edges.csv into the",
        "// Neo4j import directory, then run this script (e.g. with cypher-shell).",
        "CREATE CONSTRAINT pid_node_id IF NOT EXISTS FOR (n:PidNode) REQUIRE (n.plant, n.id) IS UNIQUE;",
        "",
        "LOAD CSV WITH HEADERS FROM 'file:///nodes.csv' AS row",
        f"MERGE (n:PidNode {{plant: '{plant}', id: row.id}})",
        "SET n += row, n.confidence = toFloat(row.confidence);",
        "",
    ]
    for t in node_types:
        lines.append(f"MATCH (n:PidNode {{plant: '{plant}', type: '{t}'}}) SET n:{t};")
    lines.append("")
    for t in edge_types:
        lines += [
            "LOAD CSV WITH HEADERS FROM 'file:///edges.csv' AS row",
            f"WITH row WHERE row.type = '{t}'",
            f"MATCH (a:PidNode {{plant: '{plant}', id: row.source}}), (b:PidNode {{plant: '{plant}', id: row.target}})",
            f"MERGE (a)-[r:{t} {{id: row.id}}]->(b)",
            "SET r.confidence = toFloat(row.confidence), r.derived = row.derived = 'True',",
            "    r.sheet = row.sheet, r.attributes_json = row.attributes_json;",
            "",
        ]
    (out / "import.cypher").write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("kg", type=Path, help="kg/ directory or graph.json")
    ap.add_argument("format", choices=["graphml", "neo4j"])
    a = ap.parse_args()
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    json_path = a.kg / "graph.json" if a.kg.is_dir() else a.kg
    g = Graph.load(json_path)
    if a.format == "graphml":
        target = json_path.with_name("graph.graphml")
        export_graphml(g, target)
    else:
        target = json_path.with_name("neo4j")
        export_neo4j(g, target)
    print(f"wrote {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
