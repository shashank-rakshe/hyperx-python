"""DuckDB storage and graph traversal.

The DuckDB file is a query layer over ``graph.json``: two tables (``nodes``,
``edges``), convenience views, and table macros for flow traversal, e.g.::

    SELECT * FROM downstream('660-TK-001');
    SELECT * FROM upstream('FV-0502');
    SELECT * FROM instruments WHERE variable = 'flow';
"""

from __future__ import annotations

import json
from collections import defaultdict, deque
from pathlib import Path
from typing import Any, Optional

from .models import KnowledgeGraph

SCHEMA_SQL = """
CREATE TABLE plant (
    id VARCHAR PRIMARY KEY, name VARCHAR, source_file VARCHAR,
    generated_at VARCHAR, generator VARCHAR, schema_version VARCHAR, stats JSON
);
CREATE TABLE nodes (
    id VARCHAR PRIMARY KEY, type VARCHAR NOT NULL, label VARCHAR, tag VARCHAR,
    kind VARCHAR, name VARCHAR, status VARCHAR, dexpi_class VARCHAR,
    sheets VARCHAR[], confidence DOUBLE, attributes JSON, provenance JSON
);
CREATE TABLE edges (
    id VARCHAR PRIMARY KEY, source VARCHAR NOT NULL, target VARCHAR NOT NULL,
    type VARCHAR NOT NULL, confidence DOUBLE, derived BOOLEAN, sheet VARCHAR,
    attributes JSON
);
CREATE TABLE issues (
    severity VARCHAR, code VARCHAR, message VARCHAR, node VARCHAR, sheet VARCHAR, page INTEGER
);
"""

FLOW_VIEW_SQL = """
CREATE VIEW flow_edges AS
SELECT source, target, sheet, attributes FROM edges
WHERE type = 'FLOWS_TO' {pfd_filter};
"""

VIEWS_SQL = """
CREATE VIEW equipment AS
SELECT id, tag, kind, name, status, sheets, confidence FROM nodes WHERE type = 'Equipment';

CREATE VIEW equipment_flow AS
SELECT e.source AS from_id, s.label AS from_label, e.target AS to_id, t.label AS to_label,
       e.attributes->>'via_lines' AS via_lines, e.attributes->>'via_items' AS via_items
FROM edges e JOIN nodes s ON s.id = e.source JOIN nodes t ON t.id = e.target
WHERE e.type = 'FEEDS' {feeds_filter};

CREATE VIEW instruments AS
SELECT n.id, n.tag, n.attributes->>'variable' AS variable, n.attributes->>'role' AS role,
       n.attributes->>'location' AS location, n.name,
       m.target AS measures_id, mt.label AS measures_label, mt.type AS measures_type,
       l.target AS loop_id, n.sheets, n.confidence
FROM nodes n
LEFT JOIN edges m ON m.source = n.id AND m.type = 'MEASURES'
LEFT JOIN nodes mt ON mt.id = m.target
LEFT JOIN edges l ON l.source = n.id AND l.type = 'MEMBER_OF'
WHERE n.type = 'Instrument';

CREATE VIEW loops AS
SELECT id, label AS loop, kind AS loop_type, attributes->>'variable' AS variable,
       attributes->'sensors' AS sensors, attributes->'controllers' AS controllers,
       attributes->'final_elements' AS final_elements,
       attributes->>'description' AS description, sheets
FROM nodes WHERE type = 'ControlLoop';

CREATE VIEW signals AS
SELECT e.source, e.target, e.attributes->>'signal_type' AS signal_type,
       e.attributes->>'purpose' AS purpose, e.sheet
FROM edges e WHERE e.type = 'SIGNAL_TO';

CREATE MACRO downstream(start_id) AS TABLE
WITH RECURSIVE walk(id) AS (
    SELECT target FROM flow_edges WHERE source = start_id
    UNION
    SELECT e.target FROM flow_edges e JOIN walk w ON e.source = w.id
)
SELECT n.id, n.type, n.label, n.kind, n.name FROM walk JOIN nodes n ON n.id = walk.id;

CREATE MACRO upstream(start_id) AS TABLE
WITH RECURSIVE walk(id) AS (
    SELECT source FROM flow_edges WHERE target = start_id
    UNION
    SELECT e.source FROM flow_edges e JOIN walk w ON e.target = w.id
)
SELECT n.id, n.type, n.label, n.kind, n.name FROM walk JOIN nodes n ON n.id = walk.id;
"""


def write_duckdb(kg: KnowledgeGraph, path: Path) -> None:
    import duckdb

    path = Path(path)
    if path.exists():
        path.unlink()
    con = duckdb.connect(str(path))
    try:
        con.execute(SCHEMA_SQL)
        con.execute("INSERT INTO plant VALUES (?, ?, ?, ?, ?, ?, ?)",
                    [kg.plant.id, kg.plant.name, kg.plant.source_file, kg.generated_at,
                     kg.generator, kg.schema_version, json.dumps(kg.stats)])
        con.executemany(
            "INSERT INTO nodes VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [[n.id, n.type, n.label, n.tag, n.kind, n.name, n.status, n.dexpi_class, n.sheets,
              n.confidence, json.dumps(n.attributes),
              json.dumps([p.model_dump(exclude_none=True) for p in n.provenance])]
             for n in kg.nodes])
        con.executemany(
            "INSERT INTO edges VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            [[e.id, e.source, e.target, e.type, e.confidence, e.derived, e.sheet,
              json.dumps(e.attributes)] for e in kg.edges])
        if kg.issues:
            con.executemany(
                "INSERT INTO issues VALUES (?, ?, ?, ?, ?, ?)",
                [[i.get("severity"), i.get("code"), i.get("message"), i.get("node"),
                  i.get("sheet"), i.get("page")] for i in kg.issues])
        pfd_filter = ("AND coalesce(attributes->>'drawing_type', '') <> 'pfd'"
                      if has_pid_sheets(kg) else "")
        con.execute(FLOW_VIEW_SQL.format(pfd_filter=pfd_filter))
        con.execute(VIEWS_SQL.replace("{feeds_filter}", "AND coalesce(e.attributes->>'view', '') <> 'pfd'"
                                      if pfd_filter else ""))
    finally:
        con.close()


def has_pid_sheets(kg: KnowledgeGraph) -> bool:
    sheets = [n for n in kg.nodes if n.type == "Sheet"]
    return any(n.attributes.get("drawing_type", "pid") != "pfd" for n in sheets) and         any(n.attributes.get("drawing_type") == "pfd" for n in sheets)


class Graph:
    """In-memory view of a knowledge graph for traversal queries."""

    def __init__(self, kg: KnowledgeGraph, include_pfd: bool = False):
        """``include_pfd``: when a plant has P&IDs, PFD-sheet flow is skipped in
        traversals by default because the P&IDs show the same flow in detail."""
        self.kg = kg
        self.nodes = {n.id: n for n in kg.nodes}
        self.out: dict[str, list] = defaultdict(list)
        self.inn: dict[str, list] = defaultdict(list)
        skip_pfd = not include_pfd and has_pid_sheets(kg)
        for e in kg.edges:
            if skip_pfd and e.attributes.get("drawing_type") == "pfd":
                continue
            if skip_pfd and e.type == "FEEDS" and e.attributes.get("view") == "pfd":
                continue
            self.out[e.source].append(e)
            self.inn[e.target].append(e)
        self._by_tag = {}
        for n in kg.nodes:
            for key in {n.id, n.tag, n.label}:
                if key:
                    self._by_tag.setdefault(key.upper(), n.id)

    @classmethod
    def load(cls, path: Path, include_pfd: bool = False) -> "Graph":
        path = Path(path)
        if path.suffix == ".duckdb":
            path = path.with_name("graph.json")
        return cls(KnowledgeGraph.model_validate_json(path.read_text(encoding="utf-8")), include_pfd)

    def find(self, ref: str) -> Optional[str]:
        from .isa import normalize_tag

        if ref in self.nodes:
            return ref
        for key in (ref.upper(), normalize_tag(ref)):
            if key and key in self._by_tag:
                return self._by_tag[key]
        # Untagged items: a unique local id ('P12.OXIDANT_TOTE') or a unique name.
        r = ref.upper()
        hits = [n.id for n in self.kg.nodes if n.id.upper().endswith("." + r)]
        if len(hits) != 1:
            hits = [n.id for n in self.kg.nodes if n.name and n.name.upper() == r]
        return hits[0] if len(hits) == 1 else None

    def walk(self, start: str, direction: str = "down", edge_types=("FLOWS_TO",),
             max_depth: Optional[int] = None) -> list[tuple[str, int]]:
        """Breadth-first traversal returning (node id, hops) in visiting order."""
        adj = self.out if direction == "down" else self.inn
        seen = {start: 0}
        order: list[tuple[str, int]] = []
        q = deque([start])
        while q:
            cur = q.popleft()
            d = seen[cur]
            if max_depth is not None and d >= max_depth:
                continue
            for e in adj[cur]:
                if e.type not in edge_types:
                    continue
                nxt = e.target if direction == "down" else e.source
                if nxt not in seen:
                    seen[nxt] = d + 1
                    order.append((nxt, d + 1))
                    q.append(nxt)
        return order

    def path(self, a: str, b: str, edge_types=("FLOWS_TO",)) -> Optional[list[str]]:
        prev: dict[str, Optional[str]] = {a: None}
        q = deque([a])
        while q:
            cur = q.popleft()
            if cur == b:
                out = []
                while cur is not None:
                    out.append(cur)
                    cur = prev[cur]
                return out[::-1]
            for e in self.out[cur]:
                if e.type in edge_types and e.target not in prev:
                    prev[e.target] = cur
                    q.append(e.target)
        return None

    def neighbors(self, nid: str) -> dict[str, list[dict[str, Any]]]:
        rel: dict[str, list[dict[str, Any]]] = defaultdict(list)
        for e in self.out[nid]:
            rel[f"{e.type} ->"].append({"id": e.target, "label": self.nodes[e.target].label,
                                        **({"attributes": e.attributes} if e.attributes else {})})
        for e in self.inn[nid]:
            rel[f"<- {e.type}"].append({"id": e.source, "label": self.nodes[e.source].label,
                                        **({"attributes": e.attributes} if e.attributes else {})})
        return dict(rel)
