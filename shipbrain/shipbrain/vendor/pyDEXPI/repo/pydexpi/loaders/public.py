"""
Public loading API for pyDEXPI models.

This module provides explicit, easy-to-use functions for loading DEXPI models
from XML and JSON formats. It supports filesystem paths, in-memory
text strings, and in-memory bytes without requiring knowledge of internal
serializer classes or temporary files.

The explicit loaders (``load_xml_file``, ``load_json_bytes``, etc.) are the
primary public API.  A generic convenience loader :func:`load_model` is also
provided for callers who prefer a single entry-point with explicit *format*
and *source_type* parameters.

Each call creates a fresh serializer instance so that no mutable state
(e.g. error registries, object registries) leaks between loads.  Advanced
users who need direct serializer control can still instantiate
``DexpiXmlSerializer`` / ``JsonSerializer`` themselves.

XML input is routed by content: DEXPI XML goes to ``DexpiXmlSerializer``, Proteus XML (a
``PlantModel`` root with a ``PlantInformation`` child) to ``ProteusSerializer``, and Proteus XML
whose ``PlantInformation/@OriginatingSystem`` is ``"PlantEngineer"`` to
``PlantEngineerProteusSerializer``, which normalizes that vendor's dialect before parsing.

Graph building is also exposed via :func:`get_graph` and :func:`get_graphs`,
which wrap the internal ``GraphLoader`` / ``GraphAbstractor`` pipeline so that
callers never need to import those classes directly.

Examples
--------
>>> from pydexpi import load_xml_file, load_json_string
>>> model = load_xml_file("data/reference_pid.xml")
>>> model = load_json_string(json_text)

>>> from pydexpi import load_xml_file, get_graph, get_graphs
>>> model = load_xml_file("data/reference_pid.xml")
>>> g = get_graph(model, graph_level="process")
>>> gs = get_graphs(model, embed_shape_usage=True)
"""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Literal

from lxml import etree

if TYPE_CHECKING:
    import networkx as nx

    from pydexpi.loaders.graph_loader import GraphLevelName

from pydexpi.loaders.compat import ConversionRefusedError
from pydexpi.loaders.error_registry import ErrorLevels, ErrorRegistry, ErrorRegistryEntry
from pydexpi.loaders.json_serializer import JsonSerializer
from pydexpi.loaders.plantengineer_proteus_serializer import PlantEngineerProteusSerializer
from pydexpi.loaders.proteus_serializer import ProteusSerializer
from pydexpi.loaders.xml_parsing import parse_xml_bytes, parse_xml_string
from pydexpi.loaders.xml_serializer import DexpiXmlSerializer
from pydexpi.pydexpi_classes import PyDexpiBaseModel
from pydexpi.pydexpi_classes.pydexpi_classes import EngineeringModel

# ---------------------------------------------------------------------------
# Public graph types
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class GraphSet:
    """Container for all three abstraction levels of a DEXPI plant graph.

    Each attribute holds an independent ``nx.MultiDiGraph`` built from the
    same underlying ``EngineeringModel``.  Modifying one graph does not affect
    the others.

    All three carry the same model provenance in ``graph.graph`` but record
    *their own* level as ``graph.graph["graph_level"]`` and as a
    ``"graph_level"`` attribute on every node and edge.

    These are the three P&ID levels. The ``"process_flow"`` level, the view of a
    DEXPI ``ProcessModel``, is not part of the set; build it with
    ``get_graph(model, graph_level="process_flow")``.

    Attributes
    ----------
    complete : nx.MultiDiGraph
        The complete plant graph — all nodes and edges with only top-level
        structural nodes (``PlantModel``, ``ProcessModel``, ``MetaData``)
        removed.
    process : nx.MultiDiGraph
        The process-level abstracted graph — piping nodes collapsed, signals
        and instrumentation abstracted into edges.
    conceptual : nx.MultiDiGraph
        The conceptual-level abstracted graph — further simplified: equipment
        internals and nozzles removed on top of the process-level abstractions.
    """

    complete: nx.MultiDiGraph
    process: nx.MultiDiGraph
    conceptual: nx.MultiDiGraph


@dataclass(frozen=True)
class LoadReport:
    """A loaded model together with the issues its loader recorded.

    Attributes
    ----------
    model : EngineeringModel
        The loaded DEXPI model.
    errors : tuple[ErrorRegistryEntry, ...]
        Every entry the loader's error registry holds after the load, in the order recorded:
        what was dropped, defaulted or could not be resolved. Filter on ``entry.level``.
    """

    model: EngineeringModel
    errors: tuple[ErrorRegistryEntry, ...]


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


#: How many registry entries the error of a failed load quotes before counting the rest.
_MAX_REPORTED_ENTRIES = 3


def _reported(errors: list[ErrorRegistryEntry]) -> str:
    """What a failed load recorded, for its error: the first entries at ERROR or above.

    Returns
    -------
    str
        A sentence quoting up to `_MAX_REPORTED_ENTRIES` messages, in the order recorded, with a
        leading space; or an empty string when nothing was recorded at those levels.
    """
    loud = [
        entry.message
        for entry in errors
        if entry.level in (ErrorLevels.ERROR, ErrorLevels.CRITICAL)
    ]
    if not loud:
        return ""
    quoted = " | ".join(loud[:_MAX_REPORTED_ENTRIES])
    more = len(loud) - _MAX_REPORTED_ENTRIES
    rest = f" | and {more} more." if more > 0 else ""
    # Each message ends its own sentence; one that does not is given its full stop.
    end = "" if rest or quoted.endswith(".") else "."
    return f" The loader reported: {quoted}{rest}{end}"


def _ensure_engineering_model(
    result: PyDexpiBaseModel | None, errors: Iterable[ErrorRegistryEntry] = ()
) -> EngineeringModel:
    """Validate that *result* is an ``EngineeringModel`` and return it.

    The underlying serializers return ``PyDexpiBaseModel``, or ``None`` when
    loading failed critically.  The public API promises ``EngineeringModel``, so
    we perform an explicit runtime check and raise a clear error if the parsed
    object is not the expected root type.

    Parameters
    ----------
    result : PyDexpiBaseModel or None
        The object returned by a serializer's load method.
    errors : Iterable[ErrorRegistryEntry], optional
        What the serializer recorded, so that a refused document raises its own reason.

    Returns
    -------
    EngineeringModel
        The validated model.

    Raises
    ------
    ConversionRefusedError
        If *result* is ``None`` because a strict load refused a DEXPI 2.0 document it cannot
        convert without copying or dropping data. It is a ``ValueError``, and its message lists
        everything refused.
    ValueError
        If *result* is ``None``, i.e. the serializer failed to load the data. The message
        carries what the serializer recorded about it: a document whose root is no object, or
        names no class, is refused this way, and the registry these loaders discard is the
        only other place that says why.
    TypeError
        If *result* is not an ``EngineeringModel`` instance.
    """
    if result is None:
        recorded = list(errors)
        for entry in recorded:
            if isinstance(entry.exception, ConversionRefusedError):
                raise entry.exception
        raise ValueError(
            "Loading failed: the serializer could not build a model from this data."
            f"{_reported(recorded)} Inspect the serializer's error registry (via "
            "DexpiXmlSerializer or JsonSerializer directly) for the underlying cause."
        )
    if not isinstance(result, EngineeringModel):
        raise TypeError(
            f"Expected the parsed data to produce an EngineeringModel, "
            f"got {type(result).__name__}. "
            f"The public convenience loaders only support loading full "
            f"EngineeringModel root objects. Use DexpiXmlSerializer or "
            f"JsonSerializer directly for other element types."
        )
    return result


#: ``PlantInformation/@OriginatingSystem`` value that identifies a PlantEngineer export.
PLANTENGINEER_ORIGINATING_SYSTEM = "PlantEngineer"

#: What :func:`_detect_xml_dialect` can tell apart, and so which serializer reads a document.
XmlDialect = Literal["dexpi", "proteus", "plantengineer"]


def _detect_xml_dialect(xml_content: str | bytes) -> XmlDialect:
    """Classify XML content by the serializer that should read it.

    A ``PlantModel`` root with a ``PlantInformation`` child is Proteus; among those, one whose
    ``OriginatingSystem`` attribute is :data:`PLANTENGINEER_ORIGINATING_SYSTEM` is PlantEngineer's
    dialect. Everything else, including XML that does not parse, is treated as DEXPI XML so that
    the DEXPI serializer reports the problem.

    Parameters
    ----------
    xml_content : str or bytes
        XML content to classify.

    Returns
    -------
    {"dexpi", "proteus", "plantengineer"}
        The detected dialect.
    """
    try:
        # Bytes keep the encoding the document declares; a string has already been decoded, so it
        # goes through the parse entry point that overrides the now-stale declaration.
        if isinstance(xml_content, bytes):
            root = parse_xml_bytes(xml_content)
        else:
            root = parse_xml_string(xml_content)
    except etree.XMLSyntaxError:
        # Invalid XML, fall back to standard loader
        return "dexpi"
    if root.tag != "PlantModel":
        return "dexpi"
    plant_information = root.find("PlantInformation")
    if plant_information is None:
        return "dexpi"
    if plant_information.get("OriginatingSystem") == PLANTENGINEER_ORIGINATING_SYSTEM:
        return "plantengineer"
    return "proteus"


def _has_plant_information_tag(xml_content: str | bytes) -> bool:
    """Detect if XML has PlantInformation tag (Proteus format).

    Checks if root element is PlantModel and has PlantInformation child.

    Parameters
    ----------
    xml_content : str or bytes
        XML content to check.

    Returns
    -------
    bool
        True if PlantInformation tag detected.
    """
    return _detect_xml_dialect(xml_content) != "dexpi"


def _load_xml(xml_content: str | bytes, strict: bool) -> EngineeringModel:
    """Load XML text or bytes through the serializer its content calls for."""
    return _load_xml_with_report(xml_content, strict).model


def _load_xml_with_report(xml_content: str | bytes, strict: bool) -> LoadReport:
    """Load XML text or bytes through the serializer its content calls for, keeping its errors.

    Parameters
    ----------
    xml_content : str or bytes
        XML content to load. Bytes are handed on as bytes, so the declared encoding is honoured.
    strict : bool
        Passed to ``DexpiXmlSerializer``; the Proteus serializers have no equivalent.

    Returns
    -------
    LoadReport
        The loaded DEXPI model and its serializer's error registry entries.
    """
    dialect = _detect_xml_dialect(xml_content)
    serializer: ProteusSerializer | DexpiXmlSerializer
    if dialect == "plantengineer":
        serializer = PlantEngineerProteusSerializer()
    elif dialect == "proteus":
        serializer = ProteusSerializer()
    else:
        serializer = DexpiXmlSerializer(strict=strict)

    # ProteusSerializer always returns a model; the tree-reference serializers return None when
    # loading fails critically, which _ensure_engineering_model turns into a ValueError.
    result: EngineeringModel | None
    if isinstance(xml_content, bytes):
        result = serializer.load_from_bytes(xml_content)
    else:
        result = serializer.load_from_string(xml_content)
    # The Proteus serializers hand back their ErrorRegistry, DexpiXmlSerializer a list of entries.
    loading_errors = serializer.get_loading_errors()
    if isinstance(loading_errors, ErrorRegistry):
        loading_errors = loading_errors.get_errors()
    model = _ensure_engineering_model(result, loading_errors)
    return LoadReport(model=model, errors=tuple(loading_errors))


def _load_json_with_report(json_content: str | bytes, strict: bool) -> LoadReport:
    """Load JSON text or bytes with a fresh ``JsonSerializer``, keeping its errors."""
    serializer = JsonSerializer(strict=strict)
    if isinstance(json_content, bytes):
        result = serializer.load_from_bytes(json_content)
    else:
        result = serializer.load_from_string(json_content)
    loading_errors = serializer.get_loading_errors()
    model = _ensure_engineering_model(result, loading_errors)
    return LoadReport(model=model, errors=tuple(loading_errors))


# ---------------------------------------------------------------------------
# XML loaders
# ---------------------------------------------------------------------------


def load_xml_file(path: str | Path, *, strict: bool = True) -> EngineeringModel:
    """Load a DEXPI model from an XML file on disk.

    Automatically detects Proteus format (PlantInformation tag) and routes
    to ProteusSerializer, or to PlantEngineerProteusSerializer when the
    ``OriginatingSystem`` is ``"PlantEngineer"``. Otherwise uses standard
    DexpiXmlSerializer.

    A fresh serializer is created for each call to avoid shared mutable state.

    Parameters
    ----------
    path : str or Path
        Filesystem path to the XML file.
    strict : bool, optional
        Whether an object omitting an attribute the DEXPI model makes mandatory is discarded.
        Pass ``False`` to load such objects anyway, recording each omission in the serializer's
        error registry, which this function discards: use :func:`load_xml_with_report` to read
        it. DEXPI *process* files commonly need this: real exports routinely omit the mandatory
        ``Identifier``. Default is ``True``.

        **Applies to DEXPI XML only.** Proteus input is read by a Proteus serializer, which has
        no equivalent setting, so *strict* is ignored for a file that routes there. Routing is by
        content, not by this argument -- see above.

    Returns
    -------
    EngineeringModel
        The loaded DEXPI model.

    Raises
    ------
    FileNotFoundError
        If *path* does not exist.
    ValueError
        If the serializer failed to load the data -- including
        :class:`~pydexpi.loaders.compat.ConversionRefusedError`, when a strict load refuses a DEXPI
        2.0 document that 2.0.1 cannot represent without copying or dropping data.
    TypeError
        If the parsed object is not an ``EngineeringModel``.
    """
    path = Path(path)
    if not path.exists():
        raise FileNotFoundError(f"File {path} does not exist.")

    return _load_xml(path.read_bytes(), strict)


def load_xml_string(xml_text: str, *, strict: bool = True) -> EngineeringModel:
    """Load a DEXPI model from an XML string.

    Automatically detects Proteus format (PlantInformation tag) and routes
    to ProteusSerializer, or to PlantEngineerProteusSerializer when the
    ``OriginatingSystem`` is ``"PlantEngineer"``. Otherwise uses standard
    DexpiXmlSerializer.

    A fresh serializer is created for each call.

    Parameters
    ----------
    xml_text : str
        The XML content as a string.
    strict : bool, optional
        Whether an object omitting an attribute the DEXPI model makes mandatory is discarded.
        Pass ``False`` to load such objects anyway, recording each omission in the serializer's
        error registry, which this function discards: use :func:`load_xml_with_report` to read
        it. DEXPI *process* files commonly need this: real exports routinely omit the mandatory
        ``Identifier``. Default is ``True``.

        **Applies to DEXPI XML only.** Proteus input is read by a Proteus serializer, which has
        no equivalent setting, so *strict* is ignored for a file that routes there. Routing is by
        content, not by this argument -- see above.

    Returns
    -------
    EngineeringModel
        The loaded DEXPI model.

    Raises
    ------
    ValueError
        If the serializer failed to load the data -- including
        :class:`~pydexpi.loaders.compat.ConversionRefusedError`, when a strict load refuses a DEXPI
        2.0 document that 2.0.1 cannot represent without copying or dropping data.
    TypeError
        If the parsed object is not an ``EngineeringModel``.
    """
    return _load_xml(xml_text, strict)


def load_xml_bytes(xml_bytes: bytes, *, strict: bool = True) -> EngineeringModel:
    """Load a DEXPI model from XML bytes.

    Automatically detects Proteus format (PlantInformation tag) and routes
    to ProteusSerializer, or to PlantEngineerProteusSerializer when the
    ``OriginatingSystem`` is ``"PlantEngineer"``. Otherwise uses standard
    DexpiXmlSerializer.

    A fresh serializer is created for each call.

    Parameters
    ----------
    xml_bytes : bytes
        The XML content as bytes.
    strict : bool, optional
        Whether an object omitting an attribute the DEXPI model makes mandatory is discarded.
        Pass ``False`` to load such objects anyway, recording each omission in the serializer's
        error registry, which this function discards: use :func:`load_xml_with_report` to read
        it. DEXPI *process* files commonly need this: real exports routinely omit the mandatory
        ``Identifier``. Default is ``True``.

        **Applies to DEXPI XML only.** Proteus input is read by a Proteus serializer, which has
        no equivalent setting, so *strict* is ignored for a file that routes there. Routing is by
        content, not by this argument -- see above.

    Returns
    -------
    EngineeringModel
        The loaded DEXPI model.

    Raises
    ------
    ValueError
        If the serializer failed to load the data -- including
        :class:`~pydexpi.loaders.compat.ConversionRefusedError`, when a strict load refuses a DEXPI
        2.0 document that 2.0.1 cannot represent without copying or dropping data.
    TypeError
        If the parsed object is not an ``EngineeringModel``.
    """
    return _load_xml(xml_bytes, strict)


def load_xml_with_report(xml_content: str | bytes, *, strict: bool = True) -> LoadReport:
    """Load a DEXPI model from XML content and return it with the loader's errors.

    The same routing and options as :func:`load_xml_string` / :func:`load_xml_bytes`, but the
    issues the serializer recorded are returned rather than discarded. Use it when a caller has
    to know what a load dropped -- a DEXPI process file loaded with ``strict=True`` can lose most
    of its objects to a missing mandatory ``Identifier``, and the plain loaders report that to
    nobody.

    Parameters
    ----------
    xml_content : str or bytes
        The XML document itself -- never a path. Bytes are handed on as bytes, so the document's
        declared encoding is honoured; read a file with ``Path.read_bytes()``.
    strict : bool, optional
        As for :func:`load_xml_file`. Default is ``True``.

    Returns
    -------
    LoadReport
        The model, and every error registry entry the load recorded.

    Raises
    ------
    ValueError
        If the serializer failed to load the data -- including
        :class:`~pydexpi.loaders.compat.ConversionRefusedError`, when a strict load refuses a DEXPI
        2.0 document that 2.0.1 cannot represent without copying or dropping data.
    TypeError
        If the parsed object is not an ``EngineeringModel``.
    """
    return _load_xml_with_report(xml_content, strict)


# ---------------------------------------------------------------------------
# JSON loaders
# ---------------------------------------------------------------------------


def load_json_file(path: str | Path, *, strict: bool = True) -> EngineeringModel:
    """Load a DEXPI model from a JSON file on disk.

    A fresh ``JsonSerializer`` is created for each call to avoid shared
    mutable state in the decoder's object registry.

    Parameters
    ----------
    path : str or Path
        Filesystem path to the JSON file.
    strict : bool, optional
        Whether an object omitting an attribute the DEXPI model makes mandatory is discarded.
        Pass ``False`` to load such objects anyway, recording each omission in the serializer's
        error registry, which this function discards: use :func:`load_json_with_report` to read
        it. Needed to read back a process model that was itself loaded with ``strict=False``,
        since JSON keeps the omission. Default is ``True``.

    Returns
    -------
    EngineeringModel
        The loaded DEXPI model.

    Raises
    ------
    FileNotFoundError
        If *path* does not exist.
    ValueError
        If the serializer failed to load the data -- including
        :class:`~pydexpi.loaders.compat.ConversionRefusedError`, when a strict load refuses a DEXPI
        2.0 document that 2.0.1 cannot represent without copying or dropping data.
    TypeError
        If the parsed object is not an ``EngineeringModel``.
    """
    path = Path(path)
    if not path.exists():
        raise FileNotFoundError(f"File {path} does not exist.")
    return _load_json_with_report(path.read_text(encoding="utf-8"), strict).model


def load_json_string(json_text: str, *, strict: bool = True) -> EngineeringModel:
    """Load a DEXPI model from a JSON string.

    A fresh ``JsonSerializer`` is created for each call.

    Parameters
    ----------
    json_text : str
        The JSON content as a string.
    strict : bool, optional
        As for :func:`load_json_file`. Default is ``True``.

    Returns
    -------
    EngineeringModel
        The loaded DEXPI model.

    Raises
    ------
    ValueError
        If the serializer failed to load the data -- including
        :class:`~pydexpi.loaders.compat.ConversionRefusedError`, when a strict load refuses a DEXPI
        2.0 document that 2.0.1 cannot represent without copying or dropping data.
    TypeError
        If the parsed object is not an ``EngineeringModel``.
    """
    return _load_json_with_report(json_text, strict).model


def load_json_bytes(json_bytes: bytes, *, strict: bool = True) -> EngineeringModel:
    """Load a DEXPI model from JSON bytes.

    A fresh ``JsonSerializer`` is created for each call.

    Parameters
    ----------
    json_bytes : bytes
        The JSON content as bytes.
    strict : bool, optional
        As for :func:`load_json_file`. Default is ``True``.

    Returns
    -------
    EngineeringModel
        The loaded DEXPI model.

    Raises
    ------
    ValueError
        If the serializer failed to load the data -- including
        :class:`~pydexpi.loaders.compat.ConversionRefusedError`, when a strict load refuses a DEXPI
        2.0 document that 2.0.1 cannot represent without copying or dropping data.
    TypeError
        If the parsed object is not an ``EngineeringModel``.
    """
    return _load_json_with_report(json_bytes, strict).model


def load_json_with_report(json_content: str | bytes, *, strict: bool = True) -> LoadReport:
    """Load a DEXPI model from JSON content and return it with the loader's errors.

    The JSON twin of :func:`load_xml_with_report`: the same as :func:`load_json_string` /
    :func:`load_json_bytes`, but the issues the serializer recorded are returned rather than
    discarded.

    Parameters
    ----------
    json_content : str or bytes
        The JSON document itself -- never a path.
    strict : bool, optional
        As for :func:`load_json_file`. Default is ``True``.

    Returns
    -------
    LoadReport
        The model, and every error registry entry the load recorded.

    Raises
    ------
    ValueError
        If the serializer failed to load the data -- including
        :class:`~pydexpi.loaders.compat.ConversionRefusedError`, when a strict load refuses a DEXPI
        2.0 document that 2.0.1 cannot represent without copying or dropping data.
    TypeError
        If the parsed object is not an ``EngineeringModel``.
    """
    return _load_json_with_report(json_content, strict)


# ---------------------------------------------------------------------------
# Convenience facade
# ---------------------------------------------------------------------------


def load_model(
    source: str | bytes | Path,
    *,
    format: Literal["xml", "json"],
    source_type: Literal["file", "string", "bytes"] = "file",
    strict: bool = True,
) -> EngineeringModel:
    """Load a DEXPI model using explicit *format* and *source_type* parameters.

    This is a convenience facade that dispatches to the appropriate explicit
    loader function.  It deliberately does **not** guess whether a ``str`` is
    a file path or raw XML/JSON content -- the caller must specify
    *source_type* explicitly.

    Parameters
    ----------
    source : str, bytes, or Path
        The data source.  Interpretation depends on *source_type*:

        * ``"file"``   -- *source* is a filesystem path (``str`` or ``Path``).
        * ``"string"`` -- *source* is the raw text content (``str``).
        * ``"bytes"``  -- *source* is the raw byte content (``bytes``).
    format : {"xml", "json"}
        The serialization format of the data.
    source_type : {"file", "string", "bytes"}, default ``"file"``
        How *source* should be interpreted.
    strict : bool, default ``True``
        Passed on to the loader: ``False`` keeps objects that omit an attribute the DEXPI model
        makes mandatory. See :func:`load_xml_file` and :func:`load_json_file`.

    Returns
    -------
    EngineeringModel
        The loaded DEXPI model.

    Raises
    ------
    ValueError
        If *format* or *source_type* is not a recognized value.
    TypeError
        If *source* does not match the declared *source_type*, or if the
        parsed object is not an ``EngineeringModel``.

    Examples
    --------
    >>> model = load_model("data/model.xml", format="xml")
    >>> model = load_model(json_text, format="json", source_type="string")
    >>> model = load_model(xml_bytes, format="xml", source_type="bytes")
    """
    # Runtime type check to give a clear error message
    expected_types: dict[str, tuple[type, ...]] = {
        "file": (str, Path),
        "string": (str,),
        "bytes": (bytes,),
    }
    allowed = expected_types.get(source_type)
    if allowed is None:
        raise ValueError(
            f"Unsupported source_type={source_type!r}. Valid values: 'file', 'string', 'bytes'."
        )
    if not isinstance(source, allowed):
        raise TypeError(
            f"source_type={source_type!r} expects source to be "
            f"{' or '.join(t.__name__ for t in allowed)}, got {type(source).__name__}."
        )

    # Explicit if/elif dispatch for strict typing and readability
    if format == "xml":
        if source_type == "file":
            return load_xml_file(source, strict=strict)  # type: ignore[arg-type]
        elif source_type == "string":
            return load_xml_string(source, strict=strict)  # type: ignore[arg-type]
        else:
            return load_xml_bytes(source, strict=strict)  # type: ignore[arg-type]
    elif format == "json":
        if source_type == "file":
            return load_json_file(source, strict=strict)  # type: ignore[arg-type]
        elif source_type == "string":
            return load_json_string(source, strict=strict)  # type: ignore[arg-type]
        else:
            return load_json_bytes(source, strict=strict)  # type: ignore[arg-type]
    else:
        raise ValueError(f"Unsupported format={format!r}. Valid values: 'xml', 'json'.")


# ---------------------------------------------------------------------------
# Graph building — public convenience API
# ---------------------------------------------------------------------------


def _build_raw_graph(
    model: EngineeringModel,
    embed_shape_usage: bool,
    shape_usage_mode: Literal["shapeusage", "position"],
) -> nx.MultiDiGraph:
    """Build a raw plant graph from *model*, optionally embedding shape usage.

    Creates a fresh :class:`~pydexpi.loaders.graph_loader.GraphLoader` for
    each call so that no mutable state leaks between invocations.

    Parameters
    ----------
    model : EngineeringModel
        The DEXPI model to convert.
    embed_shape_usage : bool
        Whether to embed graphical shape-usage attributes into each node.
    shape_usage_mode : {"shapeusage", "position"}
        Controls how much shape information is embedded when
        *embed_shape_usage* is ``True``.

    Returns
    -------
    nx.MultiDiGraph
        The raw (un-abstracted) plant graph.
    """
    # Import here to avoid a circular import at module load time; graph_loader
    # imports from pydexpi_classes which in turn does not import public.
    from pydexpi.loaders.graph_loader import GraphLoader

    loader = GraphLoader()
    loader.dexpi_to_graph(model)
    if embed_shape_usage:
        loader.embed_shape_usage(shape_usage_mode=shape_usage_mode)
    return loader.graph


def get_graph(
    model: EngineeringModel,
    *,
    graph_level: GraphLevelName = "complete",
    embed_shape_usage: bool = False,
    shape_usage_mode: Literal["shapeusage", "position"] = "position",
    stamp_graph_level: bool = True,
) -> nx.MultiDiGraph:
    """Build a single abstracted graph from a DEXPI model.

    This is the primary public entry-point for graph construction.  It wraps
    the internal :class:`~pydexpi.loaders.graph_loader.GraphLoader` and
    :class:`~pydexpi.loaders.graph_loader.GraphAbstractor` pipeline so that
    callers never need to import those classes directly.

    A fresh loader is created for every call — no mutable state is shared
    between invocations.

    Parameters
    ----------
    model : EngineeringModel
        The DEXPI model to convert.  Load one with e.g. :func:`load_xml_file`.
    graph_level : {"complete", "process", "conceptual", "process_flow"}, default ``"complete"``
        The level of abstraction to apply:

        * ``"complete"``   — All nodes and edges; only top-level structural
          nodes (``PlantModel``, ``ProcessModel``, ``MetaData``) are removed.
        * ``"process"``    — Piping nodes collapsed; instrumentation signals
          abstracted to edges.
        * ``"conceptual"`` — Further simplified: equipment internals and
          nozzles also removed on top of the process-level abstractions.
        * ``"process_flow"`` — For a DEXPI ``ProcessModel``: one node per process
          step, step detail, instrumentation activity and instrumentation
          system (the control loop that composes activities), one edge per
          ``ProcessConnection`` keyed by its id, so parallel streams stay
          distinct, and one ``delegation`` edge per delegated port and
          ``measures`` edges from a measurement to what it measures. Empty for
          a ``PlantModel``. See
          :func:`~pydexpi.loaders.graph_loader.build_process_flow_graph`.

        The first three abstract a P&ID; ``"process"`` is the P&ID's process
        level, not a ``ProcessModel`` view.
    embed_shape_usage : bool, default ``False``
        When ``True``, graphical shape-usage information (position, rotation,
        scale, etc.) is embedded as node attributes before abstraction.
    shape_usage_mode : {"shapeusage", "position"}, default ``"position"``
        Controls how much shape information is embedded when
        *embed_shape_usage* is ``True``:

        * ``"position"``   — Only ``x`` and ``y`` coordinates.
        * ``"shapeusage"`` — Full shape information (position, rotation,
          scale, mirror flag, shape name, registration number).
    stamp_graph_level : bool, default ``True``
        When ``True``, *graph_level* is recorded as a ``"graph_level"``
        attribute on the graph itself and on every node and every edge, so
        that several levels can be told apart once exported.

    Returns
    -------
    nx.MultiDiGraph
        The abstracted plant graph.  ``graph.graph`` carries the model
        provenance (project, drawing, revision, originating system) and, unless
        *stamp_graph_level* is ``False``, the abstraction level.

    Raises
    ------
    ValueError
        If *graph_level* is not one of ``"complete"``, ``"process"``,
        ``"conceptual"`` or ``"process_flow"``.

    Examples
    --------
    >>> from pydexpi import load_xml_file, get_graph
    >>> model = load_xml_file("data/reference_pid.xml")
    >>> g = get_graph(model)
    >>> g_process = get_graph(model, graph_level="process")
    >>> g_pos = get_graph(model, embed_shape_usage=True)
    >>> g_process.graph["graph_level"]
    'process'
    >>> g_process.graph["projectName"]
    'a project'
    """
    from pydexpi.loaders.graph_loader import build_level

    raw = _build_raw_graph(model, embed_shape_usage, shape_usage_mode)
    return build_level(raw, graph_level, stamp=stamp_graph_level)


def get_graphs(
    model: EngineeringModel,
    *,
    embed_shape_usage: bool = False,
    shape_usage_mode: Literal["shapeusage", "position"] = "position",
    stamp_graph_level: bool = True,
) -> GraphSet:
    """Build all three abstraction levels of a DEXPI plant graph at once.

    The raw graph is built and (optionally) enriched with shape-usage data
    **once** and then used as input to all three abstraction builders, each of
    which operates on an independent deep copy.  This is more efficient than
    calling :func:`get_graph` three times.

    Parameters
    ----------
    model : EngineeringModel
        The DEXPI model to convert.  Load one with e.g. :func:`load_xml_file`.
    embed_shape_usage : bool, default ``False``
        When ``True``, graphical shape-usage information is embedded as node
        attributes before any abstraction is applied.
    shape_usage_mode : {"shapeusage", "position"}, default ``"position"``
        Controls how much shape information is embedded when
        *embed_shape_usage* is ``True``.  See :func:`get_graph` for details.
    stamp_graph_level : bool, default ``True``
        When ``True``, each of the three graphs records *its own* level as a
        ``"graph_level"`` attribute on the graph and on every node and edge.

    Returns
    -------
    GraphSet
        A dataclass with ``complete``, ``process``, and ``conceptual``
        attributes, each holding an independent ``nx.MultiDiGraph``.  The three
        share the same provenance in ``graph.graph`` but carry different
        ``"graph_level"`` values.

    Examples
    --------
    >>> from pydexpi import load_xml_file, get_graphs
    >>> model = load_xml_file("data/reference_pid.xml")
    >>> gs = get_graphs(model)
    >>> gs.complete.number_of_nodes()
    >>> gs.process.number_of_edges()
    >>> gs.conceptual.graph["graph_level"]
    'conceptual'
    """
    from pydexpi.loaders.graph_loader import build_level

    raw = _build_raw_graph(model, embed_shape_usage, shape_usage_mode)
    return GraphSet(
        complete=build_level(raw, "complete", stamp=stamp_graph_level),
        process=build_level(raw, "process", stamp=stamp_graph_level),
        conceptual=build_level(raw, "conceptual", stamp=stamp_graph_level),
    )
