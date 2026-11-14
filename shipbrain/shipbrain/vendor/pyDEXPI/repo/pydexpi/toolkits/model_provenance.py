"""Extract model provenance for graph-level properties.

Graph exports drop the DEXPI ``MetaData`` object: every abstraction level calls
``remove_nodes_by_label([..., "MetaData"])``, and the graph walk starts at
``EngineeringModel.conceptualModel``, so ``exportDateTime`` and the
``originatingSystem*`` attributes never enter the graph at all.  Which project,
drawing and revision a graph came from is therefore unrecoverable from the
nodes alone.

This module provides :func:`get_model_provenance`, which lifts a curated subset
of that information into a flat dict of GraphML-safe scalars.  It is applied
once in the shared graph-building layer
(:meth:`pydexpi.loaders.graph_loader.GraphLoader.parse_dexpi_to_graph`), which
writes the result into ``graph.graph`` -- the NetworkX graph-attribute dict --
so every consumer that understands graph-level data receives the same values::

    >>> g = get_graph(model, graph_level="process")
    >>> g.graph["projectName"]
    'a project'

``nx.write_graphml`` serialises these as ``<data>`` children of the ``<graph>``
element and ``nx.node_link_data`` puts them under a ``"graph"`` key.  Neo4j has
no graph object and therefore drops them.

GraphML-safe values
-------------------
``nx.write_graphml`` accepts only ``str``, ``int``, ``float`` and ``bool`` as
data values; it raises ``TypeError`` on ``None``, ``dict``, ``list`` **and**
``datetime``.  Absent values are therefore *omitted* rather than emitted as
empty strings, which also keeps the graph header short.

Extending the field lists
-------------------------
Add the DEXPI attribute name to :data:`METADATA_FIELDS` or
:data:`PLANT_METADATA_FIELDS`.  Unknown names are ignored, so listing a
``PlantMetaData``-only field is safe even when the model carries a plain
``MetaData``.
"""

from pydexpi.pydexpi_classes.pydexpi_classes import (
    EngineeringModel,
)

# `flatten_multi_language_string` is imported for re-export: `table_export` and `label_toolkit`
# import it from here, and the implementation moved to `scalar_coercion` so it can share the value
# rules it recurses through. It stays in `__all__` below, so those import paths keep
# working and the move is invisible to callers.
from pydexpi.toolkits.scalar_coercion import (
    coerce_for_graph,
    flatten_multi_language_string,
)

__all__ = [
    "ENGINEERING_MODEL_FIELDS",
    "GENERATOR_KEY",
    "METADATA_FIELDS",
    "PLANT_METADATA_FIELDS",
    "flatten_multi_language_string",
    "get_model_provenance",
]

ProvenanceValue = str | int | float | bool

#: Key under which the exporting software identifies itself in ``graph.graph`` and
#: in the table-export metadata block.  It is deliberately *not* filled by
#: :func:`get_model_provenance`, which reports facts about the model: the generator
#: describes the file being written, and answers a different question from
#: ``originatingSystemName`` (what authored the P&ID).  Exporting a vendor drawing
#: yields ``generator="pyDEXPI ..."`` beside ``originatingSystemName="P&ID Toolbox"``.
#: Defined here so the writers share one spelling; see :mod:`pydexpi.attribution`.
GENERATOR_KEY = "generator"

#: Source-system provenance, read from the ``EngineeringModel`` root.  The graph
#: walk starts one level below this, so these never reach the graph as nodes.
ENGINEERING_MODEL_FIELDS: tuple[str, ...] = (
    "exportDateTime",
    "originatingSystemName",
    "originatingSystemVendorName",
    "originatingSystemVersion",
)

#: Curated subset of ``MetaData``.  Deliberately not all of its attributes: the
#: goal is to identify and filter a drawing, not to mirror its title block.
#: Omitted on purpose -- ``checkerName``, ``designerName``, ``drafterName``,
#: ``archiveNumber``, ``sheetFormat``, ``replacedDrawing``,
#: ``projectRangeNumber``, ``approvalDescription`` -- title-block detail that
#: would be repeated on every graph in a shared database without helping to
#: identify it.
METADATA_FIELDS: tuple[str, ...] = (
    "projectName",
    "projectNumber",
    "subProjectName",
    "subProjectNumber",
    "drawingName",
    "drawingNumber",
    "drawingSubTitle",
    "sheetNumber",
    "totalNumberOfSheets",
    "revisionNumber",
    "fileName",
    "locationName",
    "unitName",
    "unitIdentificationCode",
    "processCellName",
    "processCellIdentificationCode",
    "blockName",
    "blockNumber",
    "creatorName",
    "approverName",
    "responsibleDepartmentName",
    "confidentiality",
    "creationDateRepresentation",
    "lastModificationDateRepresentation",
    "approvalDateRepresentation",
)

#: ISA-95 plant hierarchy, present only on ``PlantMetaData`` (a ``MetaData``
#: subclass).  These are the natural filter keys when several plants share one
#: database.
PLANT_METADATA_FIELDS: tuple[str, ...] = (
    "enterpriseName",
    "siteName",
    "siteIdentificationCode",
    "processPlantName",
    "processPlantIdentificationCode",
    "plantAreaName",
    "plantSectionName",
)


def get_model_provenance(
    model: EngineeringModel,
    *,
    include_plant_hierarchy: bool = True,
    preferred_language: str = "en",
) -> dict[str, ProvenanceValue]:
    """Return a flat dict of GraphML-safe provenance scalars for *model*.

    Parameters
    ----------
    model : EngineeringModel
        The DEXPI model to describe.
    include_plant_hierarchy : bool, default ``True``
        Whether to include the ISA-95 fields in :data:`PLANT_METADATA_FIELDS`.
        They exist only on ``PlantMetaData``; on a plain ``MetaData`` they are
        silently skipped either way.
    preferred_language : str, default ``"en"``
        Language picked out of ``MultiLanguageString`` attributes, falling back
        to English and then to the first non-empty entry.

    Returns
    -------
    dict[str, str | int | float | bool]
        Keys are DEXPI attribute names verbatim.  Keys whose value is ``None``,
        the ``Undefined`` sentinel, or an empty string are omitted entirely, so
        the result is safe to pass straight to ``nx.write_graphml``.  Returns
        an empty dict when the model carries no provenance at all.

    Examples
    --------
    >>> from pydexpi import load_xml_file
    >>> provenance = get_model_provenance(load_xml_file("data/reference_pid.xml"))
    >>> provenance["projectName"]
    'a project'
    >>> provenance["totalNumberOfSheets"]
    4
    """
    provenance: dict[str, ProvenanceValue] = {}
    _collect(model, ENGINEERING_MODEL_FIELDS, provenance, preferred_language)

    metadata = getattr(getattr(model, "conceptualModel", None), "metaData", None)
    if metadata is None:
        return provenance

    fields = METADATA_FIELDS
    if include_plant_hierarchy:
        fields += PLANT_METADATA_FIELDS
    _collect(metadata, fields, provenance, preferred_language)
    return provenance


def _collect(obj: object, field_names: tuple[str, ...], out: dict, preferred_language: str) -> None:
    """Coerce each named attribute of *obj* into *out*, skipping absent ones."""
    for name in field_names:
        coerced = coerce_for_graph(getattr(obj, name, None), preferred_language)
        if coerced is not None:
            out[name] = coerced
