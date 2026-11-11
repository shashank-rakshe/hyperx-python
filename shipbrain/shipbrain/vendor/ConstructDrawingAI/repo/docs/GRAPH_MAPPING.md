# Graph-schema mapping — every graph dataset onto the CIR

How the connectivity ground truth of many datasets — PID2Graph, CGHD, R2V, CubiGraph5K,
Toulouse, SceneCAD — maps onto one CIR target, so a single graph model trains on a unified
representation and the harness scores every source uniformly.

The CIR is a general property graph (`Entity` nodes + typed `Connection` edges, both with
free-form `attributes`) and represents all of them. Two additive, backward-compatible
`Connection` fields (schema **0.2.0**) handle undirectedness and line-level edge geometry;
0.1.0 documents load unchanged.

## The two additions (and why each is first-class, not an attribute)

| Field | Why a real field, not `attributes[...]` |
|---|---|
| `directed: bool = True` | **PID2Graph GraphML is `edgedefault="undirected"`** (verified on disk); CubiGraph room-adjacency and CGHD wires are symmetric too. Our `graph_edge_ap` matched directed `(src,tgt)` tuples — scoring an undirected GT edge `{a,b}` against a prediction would count the "wrong" orientation as a false positive/negative. The metric now branches on this flag, so the score is correct. A silent attribute would not have been read by the metric. |
| `geometry: Geometry \| None = None` | P&ID line detection, wire/conduit/pipe/duct runs, and wall segments have a **drawn path**, and line-level metrics score it. A typed `Geometry` (validated, reused by the harness) beats a raw point list buried in an untyped dict. `None` when the edge is purely topological. |

**Node roles stay a convention, not a field:** a non-symbol graph node is
`entity_type = GRAPH_NODE` with `attributes["node_role"] ∈ {connector, crossing, junction,
port, border}`. `EntityType.GRAPH_NODE` already exists; the role is low-stakes metadata the
metric doesn't branch on, so an attribute is the right weight.

**Undirected storage convention:** store an undirected edge **once**, endpoints sorted by
id (`source_id ≤ target_id`), `directed=False`. (The metric also accepts either order, so
producers that don't sort are still scored correctly.)

## Per-dataset mapping

Grounded in the on-disk data (`data/pid/pid2graph/…`, etc.).

### PID2Graph (P&ID, GraphML) — the reference case
Verified structure: `<graph edgedefault="undirected">`; nodes carry `label` +
`xmin/ymin/xmax/ymax` (pixels); edges carry `edge_label` (e.g. `solid`). Node labels seen:
`connector` (207), `crossing` (93), `valve` (56), `general` (40), `instrumentation` (11),
`background`, `arrow`.

| GraphML | CIR |
|---|---|
| symbol node (`valve`, `instrumentation`, `general`) | `Entity(entity_type=SYMBOL, label=…, geometry=box(xmin..ymax / img_size))` |
| topological node (`connector`, `crossing`) | `Entity(entity_type=GRAPH_NODE, attributes={"node_role": label}, geometry=box)` |
| `background` / `arrow` | skip `background`; `arrow` → `attributes["node_role"]="arrow"` |
| edge `(u,v)` + `edge_label` | `Connection(source_id=u, target_id=v, connection_type=edge_label, directed=False)` |

*Ingestion notes:* boxes are **pixels → normalize by the sheet image size** (pair each
`N.graphml` with its image); keep the `Complete` vs `Patched` and real-`OPEN100` vs
`Synthetic` splits as slices; real-OPEN100 is the sim-to-real reference (SOTA edge mAP 75.5).

### CGHD (hand-drawn circuits: junctions + wire-hops)
Components (Entity SYMBOL) and **junctions** (Entity GRAPH_NODE, `node_role="junction"`);
**wire segments** → `Connection(connection_type="wire", directed=False)`, optional
`geometry` = the wire polyline. A **wire-hop** (one wire crossing another with no contact)
is simply the *absence* of an edge at that crossing — represented by not emitting a
Connection (optionally a GRAPH_NODE `node_role="crossing"` to mark it, as PID2Graph does).
*Note:* the Zenodo zip landed unextracted at `data/electrical/cghd/raw/content` — unzip it first.

### R2V (floor-plan wall junctions)
Wall junctions → `Entity(GRAPH_NODE, node_role="junction", attributes={"junction_kind":"T|L|X"})`;
wall between two junctions → `Connection(connection_type="wall", directed=False, geometry=segment)`.

### CubiGraph5K (room-adjacency 0/1/2)
Rooms → `Entity(entity_type=ROOM, geometry=polygon)`; adjacency →
`Connection(connection_type ∈ {"adjacent","door_connected"}, directed=False)` (the 0/1/2
code becomes the type; 0 = no edge). Undirected by nature.

### Toulouse (road network, canonical-ordered sequences)
Intersections → `Entity(GRAPH_NODE, node_role="junction")`; roads →
`Connection(connection_type="road", directed=False, geometry=polyline)`. The "canonical
node/edge ordering" is a **serialization** choice for seq2seq models, derived at training
time from the CIR graph — not a CIR-representation difference.

### SceneCAD (scene graph)
Objects → `Entity`; relationships → `Connection(connection_type ∈ {"supports","attached"},
directed=True)` (support is oriented).

## Consequence for the metric
`eval.metrics.graph_edge_ap` keys each GT edge by its own `directed` flag and credits a
prediction against whichever orientation the GT declares. All-directed graphs (synthetic
electrical) are scored exactly as before; undirected graphs (PID2Graph et al.) are scored
order-agnostically. This is what makes cross-dataset connectivity numbers comparable.

## Preparers
PID2Graph→CIR and CGHD→CIR preparers use: GRAPH_NODE + `node_role` for topological nodes,
`directed=False` for undirected edges, optional edge `geometry`, pixel→normalized scaling,
and the split-as-slice convention. Tests confirm a hand-checked sample round-trips and edge
counts match the GraphML.
