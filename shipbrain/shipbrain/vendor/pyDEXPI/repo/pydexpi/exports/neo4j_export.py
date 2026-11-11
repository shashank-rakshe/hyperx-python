"""Neo4j CSV export for pyDEXPI models.

Produces ``nodes.csv`` and ``relationships.csv`` files using the header
convention (``:ID``, ``:LABEL``, ``:START_ID``, ``:END_ID``, ``:TYPE``)
required by the ``neo4j-admin database import`` bulk-loader tool.  The
export reuses the existing
:class:`~pydexpi.loaders.graph_loader.GraphLoaderPipeline` to convert the
pyDEXPI model to a NetworkX graph and then serialises the graph in the
Neo4j CSV header format.

Importing the result
---------------------
These headers follow the convention understood by the ``neo4j-admin
database import`` bulk-loader — plain Cypher ``LOAD CSV`` does **not**
interpret ``:LABEL`` / ``:TYPE`` / ``:ID`` specially on its own. Running
e.g. ``LOAD CSV WITH HEADERS ... CREATE (n) SET n += row`` will leave every
node unlabeled, with its properties keyed under literal strings like
``":LABEL"``. Two ways to load the files correctly:

1. **Bulk import** (fastest; requires an offline/fresh database, no APOC)::

       neo4j-admin database import full <database-name> \\
           --nodes=nodes.csv --relationships=relationships.csv

   (add ``--overwrite-destination`` to replace an existing database; the
   target database must be stopped first). Not available on Neo4j Aura,
   which exposes no server filesystem/CLI access.

2. **Cypher + APOC** (works against a running database, including Aura —
   swap ``file:///...`` below for an HTTPS URL serving the CSV, since Aura
   has no filesystem to read from). Dynamic labels/relationship types need
   APOC, since plain Cypher can't set them from a row value::

       CREATE INDEX dexpi_node_id IF NOT EXISTS
       FOR (n:_DexpiNode) ON (n.nodeId);

       LOAD CSV WITH HEADERS FROM 'file:///nodes.csv' AS row
       WITH row, apoc.map.removeKeys(row, [':ID', ':LABEL']) AS props
       CALL apoc.create.node(
         split(row.`:LABEL`, ';') + ['_DexpiNode'],
         apoc.map.merge(props, {nodeId: row.`:ID`})
       ) YIELD node
       RETURN count(node);

       LOAD CSV WITH HEADERS FROM 'file:///relationships.csv' AS row
       MATCH (start:_DexpiNode {nodeId: row.`:START_ID`})
       MATCH (end:_DexpiNode   {nodeId: row.`:END_ID`})
       CALL apoc.create.relationship(
         start, row.`:TYPE`,
         apoc.map.removeKeys(row, [':START_ID', ':END_ID', ':TYPE']), end
       ) YIELD rel
       RETURN count(rel);

       // optional cleanup once loaded
       MATCH (n:_DexpiNode) REMOVE n:_DexpiNode;
       DROP INDEX dexpi_node_id IF EXISTS;

   ``_DexpiNode`` is a temporary marker label added to every node solely so
   ``nodeId`` can be indexed and matched on — Neo4j indexes are always
   label-scoped, so the index would be unused without it. Drop the label
   and index once the load finishes, or keep them: besides the index, the
   packaged Browser stylesheet styles ``_DexpiNode`` (and ``DexpiNode``) as a
   universal anchor, which keeps captions and colours correct even when the
   DEXPI inheritance labels are curated on import. The
   ``apoc.create.*``/``apoc.map.*`` procedures above are part of APOC Core,
   available on Aura by default (no plugin install needed/possible there).

   ``nodeId`` here is the *namespaced* ``:ID``; the raw DEXPI id travels
   separately as the ``sourceId`` column and is copied through as an ordinary
   property. See the next section for why the two differ.

Loading several abstraction levels — or several models — into one database
--------------------------------------------------------------------------
Node identity is composed as ``[<id_namespace>:]<graph_level>:<sourceId>``::

    :ID          = process:id_abc                  # one model, unique across levels
    :ID          = dexpi-model-123:process:id_abc  # with a caller-supplied namespace
    sourceId     = id_abc                          # the raw DEXPI id
    graph_level  = process                         # on every node and relationship
    id_namespace = dexpi-model-123                 # only present when supplied

**Level namespacing** (always on) supports several abstraction levels of one
model. Without it the levels would collide: the three abstraction builders work
on deep copies of one raw graph, so every object that survives keeps the same
DEXPI id in ``complete``, ``process`` *and* ``conceptual``. Bulk import would
reject the duplicate ids, and the APOC recipe above would match a relationship
endpoint in every loaded level at once — silently wrong topology rather than an
error.

**Model namespacing** (opt-in via ``id_namespace``) additionally supports
several *independent models*. pyDEXPI never generates application-level model
identity — the caller must supply a stable, unique namespace (a DEXPI model id,
a document id, a database key, …) when loading independent models into one
database. ``sourceId`` is only the raw DEXPI identity and is **not** globally
unique: two P&IDs can both contain ``CentrifugalPump1``. Without a namespace
such models collide **by design** — that is documented single-model behaviour,
not a defect.

``:`` is reserved as the composite separator and is rejected in both
``id_namespace`` and DEXPI ids at export time, so the composed ``:ID`` is
guaranteed collision-free rather than merely conventionally so. The composite
never needs to be parsed — the ``sourceId`` / ``graph_level`` /
``id_namespace`` properties carry the parts individually.

Filter a single level with the ``graph_level`` property::

    MATCH (n {graph_level: 'process'}) RETURN n;

Cross levels through ``sourceId``. Within one model export it is the same value
at every level for the same physical object; when a namespace is used, match
**both** properties so objects from other models cannot leak into the join::

    MATCH (c {id_namespace: $modelId, graph_level: 'complete'})
    MATCH (p {id_namespace: $modelId, graph_level: 'process'})
    WHERE c.sourceId = p.sourceId
    RETURN c, p;

The APOC recipe above needs no change for namespaces: it copies every column
except ``:ID``/``:LABEL`` through as an ordinary property, so ``id_namespace``
is retained automatically, and relationship lookup continues to match on the
final composite ``nodeId``.

Relationships have no ``:ID`` in Neo4j. A row whose edge is keyed by a string carries it as
``edgeKey`` (:data:`EDGE_KEY_ATTRIBUTE`): at the ``process_flow`` level the
``ProcessConnection`` id, so parallel streams between one pair of steps stay distinguishable
(that level's ``composition``, ``delegation`` and ``measures`` relationships carry a composed key,
which holds a ``.`` and so is no connection's id in a schema-valid document). At
the P&ID levels the key is whatever the collapse that made the edge keyed it by -- the collapsed
object's id, or at ``conceptual`` the id of the nozzle an edge was stitched through -- so there
it tells parallel rows apart and is not to be joined on (a stitched ``Pipe`` row has its pipe in
``collapsed_node_id``; a stitched ``reference`` row stands for no collapsed object and has only
``stitched_from``). networkx's integer counter, the key of every other edge, identifies
nothing, and is not written.

Two caveats this does **not** solve:

* Model provenance (project, drawing, revision, originating system) is not
  exported by default. It lives in ``graph.graph``, which GraphML and node-link
  JSON carry but Neo4j has no graph object to hold; pass
  ``create_graph_metadata_node=True`` to add one synthetic ``_DexpiGraph`` node
  carrying it.
* ``sourceId`` is stable within one load, not across loads: ``make_id()`` mints
  a fresh UUID per load for objects without an explicit id.

Node captions
-------------
Every node carries a derived ``displayName`` property — a short, human-readable
caption such as ``"Centrifugal Pump (P4711)"`` or ``"Ball Valve (73KH12)"``,
produced by :func:`pydexpi.toolkits.display_name.get_display_name`. Without it,
Neo4j Browser picks a different property per node.

Browser stylesheet
------------------
A ready-made Neo4j Browser graph stylesheet (GRASS) is packaged with pyDEXPI at
``pydexpi/exports/resources/pydexpi-neo4j-browser.grass``. It captions nodes by
``displayName`` and colours them by DEXPI category. It affects visualisation
only and never changes exported data. Read it with :mod:`importlib.resources`::

    from importlib.resources import files

    grass = (
        files("pydexpi.exports.resources")
        .joinpath("pydexpi-neo4j-browser.grass")
        .read_text(encoding="utf-8")
    )

Import it by running ``:style`` in Neo4j Browser and dropping the ``.grass``
file onto the stylesheet area. See ``docs/mkdocs/neo4j_export.md`` for the
import options and the known limitations.

If you write your own rules instead, note that the Browser GRASS parser accepts
**single** quotes only — ``caption: '{displayName}';``. With double quotes the
brace is read as the end of the rule block, so the caption becomes literal text
and the remaining properties in that block are dropped, silently. The parser
also has no comment syntax, and a value must not contain a colon.

API layers
----------
1. ``build_graph(...)`` — graph object (NetworkX ``MultiDiGraph``).
2. ``get_neo4j_records(...)`` — structured in-memory data (lists of dicts).
3. ``export_neo4j_csv_strings(...)`` — serialized in-memory export (CSV text).
4. ``export_neo4j_csv(...)`` — file-writing convenience wrapper.
"""

import csv
import io
import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

import networkx as nx

from pydexpi.exports.export_identity import namespaced, validate_id_namespace
from pydexpi.loaders.graph_loader import (
    GRAPH_LEVEL_ATTRIBUTE,
    GraphLevelName,
    GraphLoaderPipeline,
)
from pydexpi.pydexpi_classes import EngineeringModel
from pydexpi.toolkits.scalar_coercion import coerce_for_graph

logger = logging.getLogger(__name__)

#: Property name carrying the caller-supplied model namespace on every node and
#: relationship record.  A Neo4j-only concept — unlike ``GRAPH_LEVEL_ATTRIBUTE``
#: it is never stamped onto the NetworkX graph, so it lives here rather than in
#: ``graph_loader``.
ID_NAMESPACE_ATTRIBUTE = "id_namespace"

#: Relationship property carrying the key of the edge a relationship was written from, when that
#: key is a string: at the ``process_flow`` level the ``ProcessConnection`` id, so parallel streams
#: stay distinguishable rows (and ``<attribute>.<child id>``, ``delegation.<port id>`` or
#: ``measures.<activity id>.<measured id>`` on that level's hierarchy, delegation and measures
#: rows; a hierarchy row runs from a step, or from an instrumentation system, to what it
#: composes). At the P&ID levels it is the key the collapse gave the edge: the
#: collapsed object's id at ``process``, and at ``conceptual`` also the id of a *nozzle* the edge
#: was stitched through (13 of the reference P&ID's 37 keyed edges): 12 are ``Pipe`` rows, whose
#: pipe is in ``collapsed_node_id``, and one is a ``reference`` row, which stands for no collapsed
#: object and carries only ``stitched_from``. So it distinguishes rows at every level and names an
#: object only at ``process_flow``. An integer key is networkx's per-pair counter, not an
#: identity, and is left out, so the property is a string wherever it is set. Neo4j relationships
#: have no ``:ID``, so this and the two endpoints identify one.
EDGE_KEY_ATTRIBUTE = "edgeKey"

# ------------------------------------------------------------------
# Dataclasses
# ------------------------------------------------------------------


@dataclass
class Neo4jRecords:
    """Combined node and relationship records from a single graph build.

    Record values keep their Python type wherever a Neo4j property can hold it: numbers
    (``int``/``float``) — the ``x``/``y`` coordinates added by ``embed_shape_usage`` and the value
    half of every DEXPI ``PhysicalQuantity``, whose unit travels alongside it in a companion
    ``<attr>_unit`` string property (see ``graph_loader.UNIT_ATTRIBUTE_SUFFIX``) — and
    **booleans**, which are real ``bool`` rather than the strings ``"true"``/``"false"``.
    Everything else is a string.

    Those types survive only on this direct-driver path. The CSV export stringifies every value
    and its headers carry no ``neo4j-admin`` property type, so a bulk import still loads
    quantities — like ``x``/``y`` — as strings, and booleans as lowercase ``true``/``false``.
    """

    nodes: list[dict]
    relationships: list[dict]


@dataclass
class Neo4jCsvExport:
    """In-memory CSV text payloads for Neo4j import."""

    nodes_csv: str
    relationships_csv: str


# ------------------------------------------------------------------
# Public API — file-writing convenience wrapper
# ------------------------------------------------------------------


def export_neo4j_csv(
    model: EngineeringModel,
    output_dir: str | Path,
    *,
    prefix: str = "",
    graph_level: GraphLevelName = "complete",
    embed_shape_usage: bool = False,
    shape_usage_mode: Literal["shapeusage", "position"] = "position",
    id_namespace: str | None = None,
    create_graph_metadata_node: bool = False,
) -> dict[str, Path]:
    """Export a pyDEXPI model to Neo4j-compatible CSV files.

    This is a convenience wrapper around :func:`export_neo4j_csv_strings` that
    writes the serialized CSV text to disk.

    Two files are written:

    * ``<prefix>nodes.csv`` – one row per graph node with ``:ID``, ``:LABEL``,
      ``sourceId``, and all scalar node attributes.
    * ``<prefix>relationships.csv`` – one row per edge with ``:START_ID``,
      ``:END_ID``, ``:TYPE``, and edge attributes.

    ``:ID`` is ``[<id_namespace>:]<graph_level>:<sourceId>`` — namespaced by
    abstraction level so several levels can share one database, and optionally
    by a caller-supplied *id_namespace* so several independent models can too.
    The raw DEXPI id is kept in ``sourceId``.  See the module docstring.

    Parameters
    ----------
    model : EngineeringModel
        The pyDEXPI model to export.
    output_dir : str or Path
        Directory where the CSV files will be written.
    prefix : str, default ``""``
        Optional filename prefix (e.g. ``"plant_"`` → ``plant_nodes.csv``).
    graph_level : {"complete", "process", "conceptual", "process_flow"}, default ``"complete"``
        Level of graph abstraction to export.
    embed_shape_usage : bool, default ``False``
        If ``True``, embed graphical position / shape-usage data as node
        attributes before export.
    shape_usage_mode : {"shapeusage", "position"}, default ``"position"``
        Controls which shape-usage information is embedded when
        *embed_shape_usage* is ``True``.
    id_namespace : str or None, default ``None``
        Caller-owned namespace prefixed to every ``:ID`` and emitted as an
        ``id_namespace`` property, so several independent models can share one
        database.  pyDEXPI never generates this value.  Must not be empty,
        whitespace-padded, or contain ``:``.
    create_graph_metadata_node : bool, default ``False``
        If ``True``, append one synthetic ``_DexpiGraph`` node row carrying the
        model provenance.  See :func:`get_neo4j_records`.

    Returns
    -------
    dict[str, Path]
        Mapping ``{"nodes": <path>, "relationships": <path>}`` of the written
        files.

    Notes
    -----
    Plain Cypher ``LOAD CSV`` does not understand the ``:ID``/``:LABEL``/
    ``:TYPE`` headers on its own — see the module docstring for the two
    correct ways to load these files (``neo4j-admin database import``, or
    ``LOAD CSV`` + APOC).
    """
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    csv_export = export_neo4j_csv_strings(
        model,
        graph_level=graph_level,
        embed_shape_usage=embed_shape_usage,
        shape_usage_mode=shape_usage_mode,
        id_namespace=id_namespace,
        create_graph_metadata_node=create_graph_metadata_node,
    )

    nodes_path = output_dir / f"{prefix}nodes.csv"
    rels_path = output_dir / f"{prefix}relationships.csv"

    nodes_path.write_text(csv_export.nodes_csv, encoding="utf-8")
    rels_path.write_text(csv_export.relationships_csv, encoding="utf-8")

    logger.debug(
        "Wrote Neo4j CSV at level '%s': %s, %s",
        graph_level,
        nodes_path,
        rels_path,
    )

    return {"nodes": nodes_path, "relationships": rels_path}


# ------------------------------------------------------------------
# Public API — serialized in-memory export (CSV text)
# ------------------------------------------------------------------


def export_neo4j_csv_strings(
    model: EngineeringModel,
    *,
    graph_level: GraphLevelName = "complete",
    embed_shape_usage: bool = False,
    shape_usage_mode: Literal["shapeusage", "position"] = "position",
    id_namespace: str | None = None,
    create_graph_metadata_node: bool = False,
) -> Neo4jCsvExport:
    """Export a pyDEXPI model to Neo4j CSV and return the text in memory.

    This is the primary in-memory serialization entry point for Neo4j CSV.
    The file-writing helper :func:`export_neo4j_csv` delegates to this
    function.

    Parameters
    ----------
    model : EngineeringModel
        The pyDEXPI model to export.
    graph_level : {"complete", "process", "conceptual", "process_flow"}, default ``"complete"``
        Level of graph abstraction to export.
    embed_shape_usage : bool, default ``False``
        Whether to embed graphical position / shape-usage data.
    shape_usage_mode : {"shapeusage", "position"}, default ``"position"``
        Controls which shape-usage information is embedded.
    id_namespace : str or None, default ``None``
        Caller-owned namespace prefixed to every ``:ID`` and emitted as an
        ``id_namespace`` column.  See :func:`get_neo4j_records`.
    create_graph_metadata_node : bool, default ``False``
        If ``True``, append one synthetic ``_DexpiGraph`` node row carrying the
        model provenance.  See :func:`get_neo4j_records`.

    Returns
    -------
    Neo4jCsvExport
        Dataclass with ``nodes_csv`` and ``relationships_csv`` string fields.
    """
    records = get_neo4j_records(
        model,
        graph_level=graph_level,
        embed_shape_usage=embed_shape_usage,
        shape_usage_mode=shape_usage_mode,
        id_namespace=id_namespace,
        create_graph_metadata_node=create_graph_metadata_node,
    )

    # Build fieldnames. The id_namespace column exists only when a namespace was
    # supplied -- an unconditional priority key would emit an all-empty column.
    node_priority = [":ID", ":LABEL", "displayName", GRAPH_LEVEL_ATTRIBUTE, "sourceId"]
    rel_priority = [":START_ID", ":END_ID", ":TYPE", GRAPH_LEVEL_ATTRIBUTE, EDGE_KEY_ATTRIBUTE]
    if id_namespace is not None:
        node_priority.append(ID_NAMESPACE_ATTRIBUTE)
        rel_priority.append(ID_NAMESPACE_ATTRIBUTE)

    node_fieldnames = _build_fieldnames(records.nodes, node_priority)
    nodes_csv = _records_to_csv_string(records.nodes, node_fieldnames)

    rel_fieldnames = _build_fieldnames(records.relationships, rel_priority)
    rels_csv = _records_to_csv_string(records.relationships, rel_fieldnames)

    return Neo4jCsvExport(nodes_csv=nodes_csv, relationships_csv=rels_csv)


# ------------------------------------------------------------------
# Public API — structured in-memory data (records)
# ------------------------------------------------------------------


def get_neo4j_records(
    model: EngineeringModel,
    *,
    graph_level: GraphLevelName = "complete",
    embed_shape_usage: bool = False,
    shape_usage_mode: Literal["shapeusage", "position"] = "position",
    id_namespace: str | None = None,
    create_graph_metadata_node: bool = False,
) -> Neo4jRecords:
    """Return combined Neo4j node and relationship records.

    Builds the graph once and collects both node and relationship records
    in a single pass, avoiding the overhead of rebuilding the graph twice.

    Parameters
    ----------
    model : EngineeringModel
        The pyDEXPI model to export.
    graph_level : {"complete", "process", "conceptual", "process_flow"}, default ``"complete"``
        Level of graph abstraction.
    embed_shape_usage : bool, default ``False``
        If ``True``, embed graphical position / shape-usage data as node
        attributes.  ``"position"`` mode adds ``x``/``y``; ``"shapeusage"``
        mode additionally adds ``rotation``, ``scale_x``, ``scale_y``,
        ``is_mirrored``, ``shape_name`` and ``symbol_registration_number``.
    shape_usage_mode : {"shapeusage", "position"}, default ``"position"``
        Controls which shape-usage information is embedded when
        *embed_shape_usage* is ``True``.
    id_namespace : str or None, default ``None``
        Caller-owned namespace that makes node identity unique across
        *independent models* sharing one database: every ``:ID`` becomes
        ``<id_namespace>:<graph_level>:<sourceId>`` and every record gains an
        ``id_namespace`` property.  pyDEXPI never generates this value — it may
        be a DEXPI model id, a document id, a database key, or any other stable
        external identifier the caller controls.  ``None`` (the default) means
        single-model behaviour: no prefix, no property.
    create_graph_metadata_node : bool, default ``False``
        If ``True``, append one synthetic node row labelled ``_DexpiGraph``
        carrying every entry of the graph's ``graph.graph`` dict — the model
        provenance (project, drawing, revision, originating system) and the
        ``generator`` string — since Neo4j has no graph object to hold it.
        Its ``:ID`` is namespaced like any other row's, so it does not collide
        across levels or models.  Off by default, because the row describes no
        object in the model and would change an existing import's node set.

    Returns
    -------
    Neo4jRecords
        Dataclass with ``nodes`` and ``relationships`` list-of-dict fields.
        Node ``:ID`` values are namespaced with *graph_level* (and
        *id_namespace* when given); the raw DEXPI id is kept in ``sourceId``.

    Raises
    ------
    TypeError
        If *id_namespace* is neither a string nor ``None``.
    ValueError
        If *id_namespace* is empty, whitespace-padded, or contains ``:`` —
        or if a DEXPI id in the model contains ``:`` (reserved as the
        composite-``:ID`` separator) — or if *create_graph_metadata_node* is
        ``True`` and an object in the model already has the id ``_DexpiGraph``.

    Notes
    -----
    *embed_shape_usage* requires a model with a populated ``diagram`` (loaded
    via the Proteus drawing pass); it is a no-op for models without one.
    Coordinates are in the Proteus system (y-up, millimetres) and are kept as
    numbers rather than strings — see :class:`Neo4jRecords`.
    """
    validate_id_namespace(id_namespace)
    graph_loader = GraphLoaderPipeline(
        graph_level=graph_level,
        embed_shape_usage=embed_shape_usage,
        shape_usage_mode=shape_usage_mode,
    )
    graph = graph_loader.dexpi_to_graph(model)
    nodes = _collect_node_records(graph, graph_level, id_namespace)
    if create_graph_metadata_node:
        nodes.append(_graph_metadata_record(graph, graph_level, id_namespace))
    return Neo4jRecords(
        nodes=nodes,
        relationships=_collect_relationship_records(graph, graph_level, id_namespace),
    )


#: ``:LABEL`` of the optional synthetic row carrying model provenance, and its ``sourceId``.
#: Leading underscore so it sorts and reads as pyDEXPI's own, not a DEXPI class.
GRAPH_METADATA_LABEL = "_DexpiGraph"


def _graph_metadata_record(
    graph: nx.MultiDiGraph, graph_level: str, id_namespace: str | None = None
) -> dict:
    """Build the one synthetic node row carrying what ``graph.graph`` knows.

    Neo4j has no graph object, so provenance -- project, drawing, revision, originating system --
    had nowhere to go and was dropped. This puts it on a single node instead of repeating
    ~25 constant fields across every row.

    The row is a node like any other in the columns that matter: it carries ``:ID``, ``sourceId``,
    ``graph_level``, ``id_namespace`` when given, and a ``displayName``, so the "every node row has
    a caption" invariant holds and the level/namespace filters reach it.

    Raises
    ------
    ValueError
        If a real object already uses ``_DexpiGraph`` as its id. DEXPI ids are arbitrary strings,
        so that is possible; emitting two rows with the same ``:ID`` would corrupt the import, and
        overwriting one silently would lose an object.
    """
    if GRAPH_METADATA_LABEL in graph.nodes:
        raise ValueError(
            f"The model contains an object with id {GRAPH_METADATA_LABEL!r}, which is the id this "
            f"export uses for the synthetic provenance node. Rename that object, or export with "
            f"create_graph_metadata_node=False."
        )

    record = {
        ":ID": namespaced(GRAPH_METADATA_LABEL, graph_level, id_namespace),
        ":LABEL": GRAPH_METADATA_LABEL,
        "sourceId": GRAPH_METADATA_LABEL,
        GRAPH_LEVEL_ATTRIBUTE: graph_level,
    }
    if id_namespace is not None:
        record[ID_NAMESPACE_ATTRIBUTE] = id_namespace

    provenance = {
        key: value
        for key, value in graph.graph.items()
        if key not in (GRAPH_LEVEL_ATTRIBUTE, ID_NAMESPACE_ATTRIBUTE)
    }
    # A caption, because `test_every_node_row_has_a_display_name` is an invariant of the export and
    # a row without one is unreadable in the Neo4j browser.
    record["displayName"] = (
        provenance.get("drawingNumber")
        or provenance.get("drawingName")
        or provenance.get("projectName")
        or GRAPH_METADATA_LABEL
    )
    for key, value in provenance.items():
        coerced = _coerce_value(value)
        if coerced is not None:
            record.setdefault(key, coerced)
    return record


# ------------------------------------------------------------------
# Internal helpers
# ------------------------------------------------------------------


def _collect_node_records(
    graph: nx.MultiDiGraph, graph_level: str, id_namespace: str | None = None
) -> list[dict]:
    """Collect node records from the graph.

    *graph_level* and *id_namespace* are taken from the caller's explicit,
    already-validated arguments rather than from ``graph.graph`` or the node
    attributes, so neither node identity nor the filter keys depend on whether
    the graph happened to be stamped.
    """
    records: list[dict] = []
    for node_id, attrs in graph.nodes(data=True):
        record: dict = {
            ":ID": namespaced(node_id, graph_level, id_namespace),
            "sourceId": node_id,
            GRAPH_LEVEL_ATTRIBUTE: graph_level,
        }
        if id_namespace is not None:
            record[ID_NAMESPACE_ATTRIBUTE] = id_namespace
        label = attrs.get("label", "")
        labels = attrs.get("labels", "")
        # Neo4j supports multiple labels separated by ";"
        if labels:
            record[":LABEL"] = labels.replace(":", ";")
        elif label:
            record[":LABEL"] = label
        else:
            record[":LABEL"] = ""

        for key, value in attrs.items():
            if key in ("label", "labels", GRAPH_LEVEL_ATTRIBUTE, ID_NAMESPACE_ATTRIBUTE):
                continue
            record[key] = _coerce_value(value)
        records.append(record)
    return records


def _collect_relationship_records(
    graph: nx.MultiDiGraph, graph_level: str, id_namespace: str | None = None
) -> list[dict]:
    """Collect relationship records from the graph.

    Both endpoints are namespaced the same way as :func:`_collect_node_records`,
    or no relationship would resolve to a node.  ``graph_level`` and
    ``id_namespace`` likewise come from the arguments, not from the edge
    attributes.

    An edge's string key travels as the :data:`EDGE_KEY_ATTRIBUTE` property. Without it two
    parallel edges -- two streams between one pair of process steps, keyed by their connection ids
    at the ``process_flow`` level -- were rows that differed in nothing that said which was which.
    An integer key is networkx's counter and is not written: it would make the property a number
    on some rows and a string on others.
    """
    records: list[dict] = []
    for u, v, edge_key, attrs in graph.edges(keys=True, data=True):
        record: dict = {
            ":START_ID": namespaced(u, graph_level, id_namespace),
            ":END_ID": namespaced(v, graph_level, id_namespace),
            ":TYPE": attrs.get("label", "RELATED_TO"),
            GRAPH_LEVEL_ATTRIBUTE: graph_level,
        }
        if isinstance(edge_key, str):
            record[EDGE_KEY_ATTRIBUTE] = edge_key
        if id_namespace is not None:
            record[ID_NAMESPACE_ATTRIBUTE] = id_namespace
        for key, value in attrs.items():
            if key in ("label", GRAPH_LEVEL_ATTRIBUTE, ID_NAMESPACE_ATTRIBUTE, EDGE_KEY_ATTRIBUTE):
                continue
            record[key] = _coerce_value(value)
        records.append(record)
    return records


def _coerce_value(value: object) -> str | int | float | bool:
    """Convert a graph attribute to a Neo4j property value.

    Delegates to :func:`pydexpi.toolkits.scalar_coercion.coerce_for_graph`, the one decision
    table shared with the graph loader and the provenance extractor. Numbers keep their
    Python type, so a consumer writing directly to Neo4j gets numeric properties usable in
    range, ordering and spatial queries -- and **booleans now keep theirs too**, so
    ``WHERE n.flag = true`` matches. Before, this path stringified them to ``"true"`` while
    the same attribute stayed a real ``bool`` on a GraphML node.

    ``None`` is returned for an attribute that carries nothing. Callers omit the key rather than
    writing an empty string: the graph attributes reaching here never contain ``None`` in
    practice, because the loader already omits what ``coerce_for_graph`` rejects.
    """
    return coerce_for_graph(value)


def _csv_value(value: object) -> str:
    """Render a record value as CSV text.

    A separate step from :func:`_coerce_value` on purpose. ``neo4j-admin import`` reads the CSV
    as text and the headers carry no property types, so everything is stringified here --
    booleans as lowercase ``true``/``false``, which is what Cypher and the CSV importer accept.
    Keeping this at the CSV boundary is what lets the record path hand back real ``bool`` and
    numeric values without changing what a bulk import loads.
    """
    if value is None:
        return ""
    if isinstance(value, bool):
        return str(value).lower()
    return str(value)


def _build_fieldnames(records: list[dict], priority_keys: list[str]) -> list[str]:
    """Collect all field names across records, keeping *priority_keys* first."""
    all_keys: dict[str, None] = {}
    for rec in records:
        for key in rec:
            all_keys[key] = None
    fieldnames = list(priority_keys)
    fieldnames.extend(k for k in all_keys if k not in priority_keys)
    return fieldnames


def _records_to_csv_string(records: list[dict], fieldnames: list[str]) -> str:
    """Serialise a list of record dicts to a CSV string.

    Parameters
    ----------
    records : list[dict]
        Row data — each dict is one CSV row.
    fieldnames : list[str]
        Ordered column headers.

    Returns
    -------
    str
        The complete CSV text (header + data rows).  Returns an empty
        string when *records* is empty.

    Notes
    -----
    Record values may be numbers (see :class:`Neo4jRecords`); they are
    stringified here via :func:`_csv_value` so the CSV stays plain text.
    """
    if not records:
        return ""

    buf = io.StringIO()
    writer = csv.DictWriter(buf, fieldnames=fieldnames, extrasaction="ignore", lineterminator="\n")
    writer.writeheader()
    for rec in records:
        writer.writerow({key: _csv_value(value) for key, value in rec.items()})
    return buf.getvalue()
