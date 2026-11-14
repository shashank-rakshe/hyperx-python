"""LLM context export for pyDEXPI models.

Converts the existing GraphML export into a compact XML-like text
representation suitable for injection into Large Language Model prompts.
The export reuses :func:`~pydexpi.exports.graphml_export.export_graphml_bytes`
so that no additional graph traversal is needed.

Two serialization modes are available:

* ``"graph"`` — includes nodes and edges with their data attributes
  (excluding noisy/internal keys).
* ``"topology"`` — includes only node id, node label, edge source,
  edge target, and edge label; at the ``process_flow`` level also the edge's
  ``id``, the id of the connection it is, so that two streams between one pair
  of steps are two lines and not one line twice. A hierarchy, delegation or
  measures edge of that level has a composed id (``delegation.<port id>``).

API layers
----------
1. ``build_graph(...)`` — graph object (NetworkX ``MultiDiGraph``).
2. ``export_graphml_bytes(...)`` — serialized GraphML (bytes).
3. ``export_llm_context_strings(...)`` — compact LLM-ready text (str).
4. ``export_llm_context(...)`` — file-writing convenience wrapper.
"""

import re
from pathlib import Path
from typing import Literal

from pydexpi.exports.graphml_export import export_graphml_bytes
from pydexpi.loaders.graph_loader import PROCESS_FLOW_LEVEL, GraphLevelName
from pydexpi.pydexpi_classes import EngineeringModel

# ------------------------------------------------------------------
# Default skip keys
# ------------------------------------------------------------------

DEFAULT_LLM_SKIP_KEYS: frozenset[str] = frozenset(
    {
        "local_semantic",
        "global_semantic",
        "local_semantic_embedding",
        "global_semantic_embedding",
        "collapsed_from",
        "collapsed_node_id",
        "stitched_from",
        "labels",
        "id",
        "graph_level",
        "x",
        "y",
    }
)
"""Keys excluded from the LLM context output by default.

These are either internal graph-processing artefacts or positional
data that adds noise without semantic value for an LLM.

Note that a DEXPI ``PhysicalQuantity`` reaches the output as two adjacent
elements rather than one -- the numeric value under the attribute's own name and
the unit under ``<attr>_unit`` (see ``graph_loader.UNIT_ATTRIBUTE_SUFFIX``).
Document order is preserved, so the two always appear together. They are
deliberately not re-joined here: this module is a passthrough over the GraphML
text, and re-formatting quantities would add yet another place in the codebase
that knows how to render one.
"""

# ------------------------------------------------------------------
# Public API — file-writing convenience wrapper
# ------------------------------------------------------------------


def export_llm_context(
    model: EngineeringModel,
    path: str | Path,
    *,
    graph_level: GraphLevelName = "complete",
    mode: Literal["graph", "topology"] = "graph",
    skip_keys: frozenset[str] | None = None,
) -> None:
    """Export a pyDEXPI model to a compact LLM context file.

    This is a convenience wrapper around :func:`export_llm_context_strings`
    that writes the result to *path*.

    Parameters
    ----------
    model : EngineeringModel
        The pyDEXPI model to export.
    path : str or Path
        Destination file path.
    graph_level : {"complete", "process", "conceptual", "process_flow"}, default ``"complete"``
        Level of graph abstraction to export.
    mode : {"graph", "topology"}, default ``"graph"``
        Serialization mode (see module docstring).
    skip_keys : frozenset[str] or None, default ``None``
        Attribute keys to exclude.  ``None`` uses
        :data:`DEFAULT_LLM_SKIP_KEYS`.
    """
    text = export_llm_context_strings(
        model,
        graph_level=graph_level,
        mode=mode,
        skip_keys=skip_keys,
    )
    Path(path).write_text(text, encoding="utf-8")


# ------------------------------------------------------------------
# Public API — serialized in-memory export (text)
# ------------------------------------------------------------------


def export_llm_context_strings(
    model: EngineeringModel,
    *,
    graph_level: GraphLevelName = "complete",
    mode: Literal["graph", "topology"] = "graph",
    skip_keys: frozenset[str] | None = None,
) -> str:
    """Export a pyDEXPI model to a compact LLM-ready text string.

    This is the primary in-memory entry point.  It obtains the GraphML
    bytes via :func:`~pydexpi.exports.graphml_export.export_graphml_bytes`
    and converts them to a compact XML-like text representation.

    Parameters
    ----------
    model : EngineeringModel
        The pyDEXPI model to export.
    graph_level : {"complete", "process", "conceptual", "process_flow"}, default ``"complete"``
        Level of graph abstraction to export.
    mode : {"graph", "topology"}, default ``"graph"``
        Serialization mode:

        * ``"graph"`` — nodes and edges with data attributes (minus
          *skip_keys*).
        * ``"topology"`` — only node id/label and edge
          source/target/label, and at ``process_flow`` the edge's ``id``
          (its connection's id).
    skip_keys : frozenset[str] or None, default ``None``
        Attribute keys to exclude from data output.  ``None`` uses
        :data:`DEFAULT_LLM_SKIP_KEYS`.

    Returns
    -------
    str
        The compact text representation.
    """
    graphml_bytes = export_graphml_bytes(model, graph_level=graph_level)
    graphml_str = graphml_bytes.decode("utf-8")
    resolved = _resolve_graphml_keys(graphml_str)
    return _graphml_to_llm_context(
        resolved,
        mode=mode,
        skip_keys=skip_keys if skip_keys is not None else DEFAULT_LLM_SKIP_KEYS,
        edge_ids=graph_level == PROCESS_FLOW_LEVEL,
    )


# ------------------------------------------------------------------
# Internal helpers
# ------------------------------------------------------------------

# Pre-compiled patterns
_KEY_DEF_RE = re.compile(r'<key\s+id="([^"]+)"[^>]*attr\.name="([^"]+)"[^>]*/>')
_DATA_KEY_RE = re.compile(r'(<data\s+key=")([^"]+)(")')
_NODE_RE = re.compile(r'<node\s+id="([^"]+)"[^>]*>(.*?)</node>', re.DOTALL)
_EDGE_RE = re.compile(r"<edge\s([^>]*?)(?:/>|>(.*?)</edge>)", re.DOTALL)
_DATA_RE = re.compile(r'<data key="([^"]+)">(.*?)</data>', re.DOTALL)


def _resolve_graphml_keys(content: str) -> str:
    """Replace internal GraphML key IDs with human-readable attribute names.

    NetworkX's ``write_graphml`` assigns opaque IDs (``d0``, ``d1``, ...)
    to ``<key>`` definitions.  This helper builds a mapping from those IDs
    to the corresponding ``attr.name`` values and rewrites every
    ``<data key="...">`` reference in the document.

    Parameters
    ----------
    content : str
        Raw GraphML text.

    Returns
    -------
    str
        GraphML text with human-readable key names.
    """
    key_map: dict[str, str] = {}
    for m in _KEY_DEF_RE.finditer(content):
        key_map[m.group(1)] = m.group(2)

    if not key_map:
        return content

    def _replace_key(m: re.Match) -> str:
        return m.group(1) + key_map.get(m.group(2), m.group(2)) + m.group(3)

    return _DATA_KEY_RE.sub(_replace_key, content)


def _graphml_to_llm_context(
    content: str,
    *,
    mode: Literal["graph", "topology"],
    skip_keys: frozenset[str],
    edge_ids: bool = False,
) -> str:
    """Convert GraphML text to a compact LLM-friendly representation.

    Parameters
    ----------
    content : str
        GraphML text, with its ``<key>`` ids already resolved to attribute names by
        :func:`_resolve_graphml_keys`.
    mode : {"graph", "topology"}
        Serialization mode.
    skip_keys : frozenset[str]
        Attribute keys to exclude.
    edge_ids : bool, default ``False``
        In topology mode, also write each edge's GraphML ``id`` -- its key in the graph.
        Topology mode drops every data attribute, so without it parallel edges of one label
        are identical lines. On for ``process_flow``, where the key is the connection's id
        (and a hierarchy edge's ``<attribute>.<child id>``, from a step or from an
        instrumentation system to what it composes, a delegation edge's
        ``delegation.<delegate port id>``, a measures edge's ``measures.<activity id>.<measured
        id>``, which for a measured connection names it and its end); off at the P&ID levels, whose
        keys are artefacts of the collapse -- at ``conceptual`` a pipe may be keyed by the
        nozzle it was stitched through -- and would read as the name of the wrong object.
        Graph mode needs none: it keeps ``connectionId``.

    Returns
    -------
    str
        Compact XML-like text.
    """

    def _graph_node(node_id: str, node_body: str) -> str:
        data_items = [
            f'  <data key="{key}">{value.strip()}</data>'
            for key, value in _DATA_RE.findall(node_body)
            if key not in skip_keys
        ]
        if data_items:
            return f'<node id="{node_id}">\n' + "\n".join(data_items) + "\n</node>"
        return f'<node id="{node_id}"/>'

    def _graph_edge(edge_attrs: str, edge_body: str) -> str | None:
        source = re.search(r'source="([^"]+)"', edge_attrs)
        target = re.search(r'target="([^"]+)"', edge_attrs)
        if not (source and target):
            return None
        data_items = [
            f'  <data key="{key}">{value.strip()}</data>'
            for key, value in _DATA_RE.findall(edge_body)
            if key not in skip_keys
        ]
        if data_items:
            return (
                f'<edge source="{source.group(1)}" target="{target.group(1)}">\n'
                + "\n".join(data_items)
                + "\n</edge>"
            )
        return f'<edge source="{source.group(1)}" target="{target.group(1)}"/>'

    def _topology_node(node_id: str, node_body: str) -> str | None:
        label_match = re.search(r'<data key="label">([^<]+)</data>', node_body)
        if not label_match:
            return None
        return f'<node id="{node_id}" label="{label_match.group(1).strip()}"/>'

    def _topology_edge(edge_attrs: str, edge_body: str) -> str | None:
        source = re.search(r'source="([^"]+)"', edge_attrs)
        target = re.search(r'target="([^"]+)"', edge_attrs)
        label = re.search(r'\blabel="([^"]+)"', edge_attrs) or re.search(
            r'<data key="label">([^<]+)</data>', edge_body
        )
        if not (source and target and label):
            return None
        edge_id = re.search(r'\bid="([^"]+)"', edge_attrs) if edge_ids else None
        return (
            f'<edge source="{source.group(1)}" target="{target.group(1)}"'
            f' label="{label.group(1).strip()}"'
            + (f' id="{edge_id.group(1)}"' if edge_id else "")
            + "/>"
        )

    if mode == "topology":
        node_lines = [
            result
            for m in _NODE_RE.finditer(content)
            if (result := _topology_node(m.group(1), m.group(2))) is not None
        ]
        edge_lines = [
            result
            for m in _EDGE_RE.finditer(content)
            if (result := _topology_edge(m.group(1), m.group(2) or "")) is not None
        ]
    else:
        node_lines = [_graph_node(m.group(1), m.group(2)) for m in _NODE_RE.finditer(content)]
        edge_lines = [
            result
            for m in _EDGE_RE.finditer(content)
            if (result := _graph_edge(m.group(1), m.group(2) or "")) is not None
        ]

    parts = node_lines + edge_lines
    return "\n".join(parts) + "\n" if parts else ""
