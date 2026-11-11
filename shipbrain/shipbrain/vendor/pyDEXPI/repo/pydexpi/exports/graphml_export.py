"""GraphML export for pyDEXPI models.

Provides functionality to export a pyDEXPI ``EngineeringModel`` to the
GraphML format via NetworkX.  The exported file can be opened in
graph-analysis tools such as Gephi, yEd, and Cytoscape.

API layers
----------
1. ``build_graph(...)`` — graph object (NetworkX ``MultiDiGraph``).
2. ``export_graphml_bytes(...)`` — serialized in-memory export (bytes).
3. ``export_graphml(...)`` — file-writing convenience wrapper.
"""

import logging
from enum import Enum
from io import BytesIO
from pathlib import Path
from typing import Literal

import networkx as nx
from networkx.readwrite.graphml import GraphMLWriter

from pydexpi.exports.export_identity import namespaced, validate_id_namespace
from pydexpi.loaders.graph_loader import GraphLevelName, GraphLoaderPipeline
from pydexpi.pydexpi_classes import EngineeringModel

logger = logging.getLogger(__name__)


#: The exact types ``nx.write_graphml`` accepts as a data value, read from the writer's own
#: dispatch table so the two cannot disagree: ``str``, ``int``, ``float``, ``bool``, and numpy
#: scalars where networkx supports them. Anything else makes the writer refuse the **whole
#: document**, so one stray value costs the entire export.
GRAPHML_SCALARS = tuple(getattr(GraphMLWriter(), "xml_type", (str, int, float, bool)))


class GraphMLAttributeError(TypeError):
    """An attribute value GraphML cannot carry, named precisely.

    Subclasses ``TypeError``, which is what ``nx.write_graphml`` raises, so a caller that
    already catches that keeps working -- it just gets a message that says which attribute on
    which element is at fault instead of only the offending type.
    """


def normalize_graphml_attributes(graph: nx.Graph) -> None:
    """Make every attribute of *graph* one GraphML can carry, or say which one cannot.

    ``nx.write_graphml`` dispatches on the **exact** type, not ``isinstance``, and refuses the
    entire document on the first value it does not recognise -- so this check compares exact
    types too, against the writer's own table, and a ``str`` subclass is refused rather than
    passed through to fail there. A ``StrEnum`` is the trap:
    ``graph_level`` is documented as ``str`` and a ``StrEnum`` member *is* a ``str``, so
    passing one satisfies the contract and every caller reads it back correctly -- and then
    the export dies with ``GraphML does not support type <enum 'GraphLevel'>``.

    So an ``Enum`` is normalised to its value, which is the one conversion that cannot change
    meaning. Everything else GraphML rejects is *raised* rather than coerced: ``str()``-ing a
    ``dict`` or a ``datetime`` would produce a document that exports cleanly and says something
    the model does not. The error names the element and the attribute, because the whole
    document fails on one value and the type alone does not say where to look.

    Values are replaced in place, so the graph passed in is the graph written out.

    Parameters
    ----------
    graph : nx.Graph
        The graph about to be written. Modified in place.

    Raises
    ------
    GraphMLAttributeError
        If an attribute value is neither a GraphML scalar nor an ``Enum`` of one. Absent
        values are part of this: GraphML has no null, so an attribute that does not apply is
        omitted rather than set to ``None``.
    """
    elements = [("graph", None, graph.graph)]
    elements += [("node", node, attributes) for node, attributes in graph.nodes(data=True)]
    elements += [
        ("edge", (source, target), attributes)
        for source, target, attributes in graph.edges(data=True)
    ]

    for location, element_id, attributes in elements:
        for name, value in attributes.items():
            if isinstance(value, Enum):
                # Rebound under its own name: `value` stays what the graph carried, so the
                # error message below reports what the caller actually put there.
                value = attributes[name] = value.value  # noqa: PLW2901
            # `type(value) in`, not `isinstance`: the writer looks the type up in a dict, so a
            # `str` subclass fails there exactly like a `dict` would and has to fail here too.
            if type(value) in GRAPHML_SCALARS:
                continue
            where = f"{location} {element_id!r}" if element_id is not None else location
            raise GraphMLAttributeError(
                f"GraphML cannot carry attribute {name!r} on {where}: "
                f"{type(value).__name__} {value!r}. "
                f"GraphML carries str, int, float and bool exactly -- a subclass of one is "
                f"refused, because the writer dispatches on the exact type -- and an Enum of "
                f"one is normalised to its value; an attribute that does not apply is omitted "
                f"rather than set to None."
            )


def namespace_graphml_ids(
    graph: nx.Graph, graph_level: str, id_namespace: str | None = None
) -> nx.Graph:
    """Return a copy of *graph* whose node ids match the Neo4j ``:ID`` exactly.

    Relabels every node to ``[<id_namespace>:]<graph_level>:<dexpi id>`` and keeps the raw id as a
    ``sourceId`` node attribute, using the *same* composition function the Neo4j exporter calls --
    :func:`pydexpi.exports.export_identity.namespaced` -- so the two cannot drift apart. That is the
    whole point: an object joined across a GraphML file and a Neo4j database has one
    identity, not two.

    A **copy**, deliberately. The namespacing cannot happen in ``graph_loader``, because
    ``namespaced`` rejects a DEXPI id containing ``:`` -- so a graph whose node keys were already
    composite would make every subsequent Neo4j export of the same graph raise.

    Parameters
    ----------
    graph : nx.Graph
        The graph to relabel. Not modified.
    graph_level : str
        The abstraction level, which is part of the composite id.
    id_namespace : str or None, optional
        Caller-owned namespace separating independent models in one database.

    Returns
    -------
    nx.Graph
        A relabelled copy.
    """
    validate_id_namespace(id_namespace)
    mapping = {node: namespaced(str(node), graph_level, id_namespace) for node in graph.nodes}
    relabelled = nx.relabel_nodes(graph, mapping, copy=True)
    for node, raw in zip(mapping.values(), mapping.keys(), strict=True):
        relabelled.nodes[node]["sourceId"] = raw
    return relabelled


def export_graphml(
    model: EngineeringModel,
    path: str | Path,
    *,
    graph_level: GraphLevelName = "complete",
    embed_shape_usage: bool = False,
    shape_usage_mode: Literal["shapeusage", "position"] = "position",
    namespace_ids: bool = False,
    id_namespace: str | None = None,
) -> None:
    """Export a pyDEXPI model to a GraphML file.

    This is a convenience wrapper around :func:`export_graphml_bytes` that
    writes the serialized bytes to *path*.

    Parameters
    ----------
    model : EngineeringModel
        The pyDEXPI model to export.
    path : str or Path
        Destination file path.  A ``.graphml`` extension is added if missing.
    graph_level : {"complete", "process", "conceptual", "process_flow"}, default ``"complete"``
        Level of graph abstraction to export:

        * ``"complete"`` – all nodes except structural metadata.
        * ``"process"`` – plant topology including nozzles and equipment internals.
        * ``"conceptual"`` – plant topology excluding nozzles and equipment internals.
        * ``"process_flow"`` – a ``ProcessModel``'s steps as nodes and its connections as
          edges, each written with its connection id as the GraphML edge ``id``; port
          delegations and what a measurement measures are edges labelled ``delegation`` and
          ``measures``. Step details, instrumentation activities and the instrumentation
          systems that compose them are nodes too.
    embed_shape_usage : bool, default ``False``
        If ``True``, embed graphical position / shape-usage data as node
        attributes before export.
    shape_usage_mode : {"shapeusage", "position"}, default ``"position"``
        Controls which shape-usage information is embedded when
        *embed_shape_usage* is ``True``.
    namespace_ids : bool, default ``False``
        Write node ids as ``[<id_namespace>:]<graph_level>:<dexpi id>``, matching the Neo4j
        export's ``:ID`` exactly, and add the raw id as a ``sourceId`` node attribute. Off by
        default because it changes every id in the document, and existing consumers read the
        bare one.
    id_namespace : str or None, optional
        Caller-owned namespace separating independent models in one database. Requires
        *namespace_ids*; passing it alone raises ``ValueError`` rather than writing bare ids and
        dropping the namespace silently. ``:`` is reserved as the separator and rejected here.
    """
    path = Path(path)
    if path.suffix != ".graphml":
        path = path.with_suffix(".graphml")

    data = export_graphml_bytes(
        model,
        graph_level=graph_level,
        embed_shape_usage=embed_shape_usage,
        shape_usage_mode=shape_usage_mode,
        namespace_ids=namespace_ids,
        id_namespace=id_namespace,
    )
    path.write_bytes(data)
    logger.debug("Wrote %d bytes of GraphML at level '%s' to %s", len(data), graph_level, path)


def export_graphml_bytes(
    model: EngineeringModel,
    *,
    graph_level: GraphLevelName = "complete",
    embed_shape_usage: bool = False,
    shape_usage_mode: Literal["shapeusage", "position"] = "position",
    namespace_ids: bool = False,
    id_namespace: str | None = None,
) -> bytes:
    """Export a pyDEXPI model to GraphML and return the result as bytes.

    This is the primary in-memory serialization entry point for GraphML.
    The file-writing helper :func:`export_graphml` delegates to this function.

    Parameters
    ----------
    model : EngineeringModel
        The pyDEXPI model to export.
    graph_level : {"complete", "process", "conceptual", "process_flow"}, default ``"complete"``
        Level of graph abstraction (see :func:`export_graphml`).
    embed_shape_usage : bool, default ``False``
        Whether to embed graphical position / shape-usage data.
    shape_usage_mode : {"shapeusage", "position"}, default ``"position"``
        Controls which shape-usage information is embedded.
    namespace_ids : bool, default ``False``
        Write node ids as ``[<id_namespace>:]<graph_level>:<dexpi id>``, matching the Neo4j
        export's ``:ID`` exactly, and add the raw id as a ``sourceId`` node attribute. Off by
        default because it changes every id in the document, and existing consumers read the
        bare one.
    id_namespace : str or None, optional
        Caller-owned namespace separating independent models in one database. Requires
        *namespace_ids*; passing it alone raises ``ValueError`` rather than writing bare ids and
        dropping the namespace silently. ``:`` is reserved as the separator and rejected here.

    Returns
    -------
    bytes
        The GraphML document encoded as UTF-8 bytes.
    """
    graph_loader = GraphLoaderPipeline(
        graph_level=graph_level,
        embed_shape_usage=embed_shape_usage,
        shape_usage_mode=shape_usage_mode,
    )
    graph = graph_loader.dexpi_to_graph(model)
    if id_namespace is not None and not namespace_ids:
        raise ValueError(
            "id_namespace was given but namespace_ids is False, so the ids would be written "
            "bare and the namespace silently dropped. Pass namespace_ids=True to use it."
        )
    if namespace_ids:
        graph = namespace_graphml_ids(graph, graph_level, id_namespace)
    normalize_graphml_attributes(graph)
    buf = BytesIO()
    nx.write_graphml(graph, buf)
    return buf.getvalue()
