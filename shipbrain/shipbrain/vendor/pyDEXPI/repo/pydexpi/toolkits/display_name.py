"""Derive human-readable display names for pyDEXPI objects.

Graph exports expose the original DEXPI data attributes, but none of them is a
consistent caption suitable for graph visualisation.  Neo4j Browser, for
example, picks a different property per node -- sometimes a tag, sometimes an
object id, sometimes an unhelpful serialised value.

This module provides :func:`get_display_name`, a *type-aware* resolver that
produces a short, deterministic caption for any ``PyDexpiBaseModel``.  It is
applied once in the shared graph-building layer
(:meth:`pydexpi.loaders.graph_loader.GraphLoader._add_nodes`), so every
exporter -- GraphML, Neo4j CSV, LLM context, the CLI -- receives the same
``displayName`` value.

The resulting format is ``"{Humanised class name} ({identifier})"``::

    Centrifugal Pump (P4711)
    Ball Valve (73KH12)
    Nozzle (N1)
    Piping Network Segment (S1)
    Pipe (Pipe1)
    Direct Piping Connection          # no identifier available

The class name stays in the caption because it is the most reliable piece of
information available: many DEXPI objects carry no tag at all.  The concrete
class also remains available separately as the ``label`` node attribute and as
the Neo4j node label.

Relationship captions
---------------------
:class:`~pydexpi.loaders.graph_loader.GraphAbstractor` collapses a handful of
classes into *relationships* when it builds the process and conceptual graphs.
A collapsed edge inherits the node's attributes, so without further work it
would be captioned with the same class-name caption -- ``Measuring Line
Function (MeasuringLineFunction1)`` where an engineer wants ``Measurement``.

:func:`get_relationship_display_name` supplies the engineer-facing term for
those classes::

    Measurement                 # MeasuringLineFunction
    Signal                      # SignalConveyingFunction
    Actuation                   # OperatedValveReference
    Direct connection           # DirectPipingConnection
    Pipe (47121)                # Pipe, identified by its line number

The wording has to exist as data on the edge because the Neo4j Browser resolves
a caption as a single property name: a stylesheet template mixing literal text
with a placeholder renders as nothing at all.

Extending the mapping
---------------------
For nodes, add an entry to :data:`DISPLAY_NAME_RESOLVERS`.  Entries are matched
with ``isinstance`` in order, so more specific classes must be listed before
their base classes.  For collapsed relationships, add an entry to
:data:`RELATIONSHIP_DISPLAY_NAMES`.

Examples
--------
>>> from pydexpi.pydexpi_classes.plant.piping import BallValve
>>> get_display_name(BallValve(pipingComponentName="73KH12"))
'Ball Valve (73KH12)'
"""

from __future__ import annotations

import re
from collections.abc import Mapping
from functools import lru_cache

from pydexpi.pydexpi_classes.pydexpi_classes import (
    ActuatingElectricalFunction,
    ActuatingElectricalSystem,
    ActuatingFunction,
    ActuatingSystem,
    CustomMaterialComponent,
    InstrumentationActivity,
    InstrumentationLoopFunction,
    InstrumentationSystemActivity,
    MaterialComponent,
    MaterialState,
    MaterialStateType,
    MaterialTemplate,
    MeasuringSystem,
    Nozzle,
    PipeOffPageConnector,
    PipingComponent,
    PipingNetworkSegment,
    PipingNetworkSystem,
    Port,
    ProcessConnection,
    ProcessInstrumentationFunction,
    ProcessSignalGeneratingFunction,
    ProcessStep,
    ProcessStepDetail,
    PureMaterialComponent,
    PyDexpiBaseModel,
    SignalConveyingFunction,
    SignalOffPageConnector,
    TaggedPlantItem,
)
from pydexpi.toolkits.base_model_utils import is_generated_id

__all__ = [
    "CAPTION_FALLBACK_ATTRIBUTES",
    "DISPLAY_NAME_RESOLVERS",
    "GENERIC_TAG_ATTRIBUTES",
    "RELATIONSHIP_DISPLAY_NAMES",
    "combine_name_and_tag",
    "get_display_name",
    "get_relationship_display_name",
    "get_tag",
    "humanize_class_name",
    "referenced_object_name",
]


# Split a CamelCase class name into words.  The two alternatives handle the
# ordinary "aB" boundary and the end of an acronym run ("PIDController" ->
# "PID Controller").
_CAMEL_SPLIT = re.compile(r"(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])")

#: Type-specific identifier attributes, matched with ``isinstance`` in order.
#: More specific classes must precede their base classes -- for example
#: ``ActuatingElectricalSystem`` is a subclass of ``ActuatingSystem``.
#:
#: The last twelve entries are the DEXPI 2.0 *process* classes that declare ``Identifier``; no
#: P&ID class derives from any of them, so they change no plant object's tag. A process identifier
#: is not unique in practice -- a BPMN export numbers its streams and its material states from "1"
#: alike, and the CO2 terminal's ``pXylene`` component carries the identifier ``oXylene`` -- so
#: ``get_by_tag`` raises ``AmbiguousTagError`` on such a tag, which is the honest answer;
#: ``find_by_tag`` returns every match.
#:
#: A material component is the one process class whose ``Identifier`` is optional, and it has
#: other attributes that identify it: the ones that tell two components apart
#: (``process_materials.PURE_IDENTIFYING_ATTRIBUTES`` and
#: ``CUSTOM_IDENTIFYING_ATTRIBUTES``). So a component without an ``Identifier`` is tagged by its
#: IUPAC name, else its ChEBI identifier, or by its project reference: the name a person
#: reads before the number. A component with a ChEBI identifier alone used to be named by its
#: generated id in every message that listed it.
DISPLAY_NAME_RESOLVERS: tuple[tuple[type, tuple[str, ...]], ...] = (
    (Nozzle, ("subTagName",)),
    (PipingNetworkSegment, ("segmentNumber",)),
    (PipingNetworkSystem, ("lineNumber",)),
    (PipingComponent, ("pipingComponentName", "pipingComponentNumber")),
    (PipeOffPageConnector, ("pipeConnectorNumber",)),
    (SignalOffPageConnector, ("signalConnectorNumber",)),
    (InstrumentationLoopFunction, ("instrumentationLoopFunctionNumber",)),
    (ProcessInstrumentationFunction, ("processInstrumentationFunctionNumber",)),
    (ProcessSignalGeneratingFunction, ("processSignalGeneratingFunctionNumber",)),
    (SignalConveyingFunction, ("signalPointNumber",)),
    (MeasuringSystem, ("measuringSystemNumber",)),
    (ActuatingElectricalSystem, ("actuatingElectricalSystemNumber",)),
    (ActuatingSystem, ("actuatingSystemNumber",)),
    (ActuatingElectricalFunction, ("actuatingElectricalFunctionNumber",)),
    (ActuatingFunction, ("actuatingFunctionNumber",)),
    (TaggedPlantItem, ("tagName",)),
    (ProcessStep, ("identifier",)),
    (Port, ("identifier",)),
    (ProcessConnection, ("identifier",)),
    (ProcessStepDetail, ("identifier",)),
    (MaterialTemplate, ("identifier",)),
    (MaterialState, ("identifier",)),
    (MaterialStateType, ("identifier",)),
    (PureMaterialComponent, ("identifier", "iUPAC_identifier", "chEBI_identifier")),
    (CustomMaterialComponent, ("identifier", "projectReference")),
    (MaterialComponent, ("identifier",)),
    (InstrumentationActivity, ("identifier",)),
    (InstrumentationSystemActivity, ("identifier",)),
)

#: Fallback attributes tried for objects with no :data:`DISPLAY_NAME_RESOLVERS`
#: entry, and for registered objects whose type-specific attributes are unset.
#: This covers sub-tagged internals such as ``Chamber``, ``ControlledActuator``
#: and ``OperatedValveReference``.
GENERIC_TAG_ATTRIBUTES: tuple[str, ...] = (
    "tagName",
    "subTagName",
    "pipingComponentName",
    "pipingComponentNumber",
    "segmentNumber",
    "lineNumber",
    "pipeConnectorNumber",
)

#: Attributes that may identify an untagged object in a *caption* but are not tags:
#: ``deviceTypeName`` holds a device type ("Electric", "Spring-diaphragm") that many
#: objects share, and ``label`` is the free-text name a DEXPI 2.0 process object carries
#: beside its ``identifier`` ("Feed pump", often repeated). :func:`get_display_name` tries
#: them after the tag and before the id; :func:`get_tag`, and therefore the query index,
#: never returns them.
CAPTION_FALLBACK_ATTRIBUTES: tuple[str, ...] = ("deviceTypeName", "label")

#: Engineer-facing captions for the classes that ``GraphAbstractor`` collapses
#: into relationships.  Each entry maps a concrete class name to the caption
#: term and the edge attributes searched for an identifier to show in
#: parentheses.  An empty attribute tuple yields the bare term.
#:
#: Keys are matched against the collapsed node's ``label`` first and against its
#: ``labels`` inheritance chain afterwards, so ``MeasuringLineFunction`` resolves
#: to its own entry rather than to that of its base ``SignalConveyingFunction``.
RELATIONSHIP_DISPLAY_NAMES: dict[str, tuple[str, tuple[str, ...]]] = {
    # A pipe is identified by its line number, which reaches the edge because
    # collapsing merged it in from the enclosing PipingNetworkSystem.
    "Pipe": ("Pipe", ("lineNumber",)),
    "DirectPipingConnection": ("Direct connection", ()),
    "MeasuringLineFunction": ("Measurement", ()),
    "SignalConveyingFunction": ("Signal", ()),
    "OperatedValveReference": ("Actuation", ()),
}


@lru_cache(maxsize=1024)
def humanize_class_name(class_name: str) -> str:
    """Split a CamelCase DEXPI class name into space-separated words.

    Cached (bounded): it runs once per object whenever captions are built, over a few hundred
    distinct class names.

    Parameters
    ----------
    class_name : str
        The class name, e.g. ``"CentrifugalPump"``.

    Returns
    -------
    str
        The humanised name, e.g. ``"Centrifugal Pump"``. Acronym runs are kept
        together, so ``"PIDController"`` becomes ``"PID Controller"``.
    """
    return _CAMEL_SPLIT.sub(" ", class_name)


def combine_name_and_tag(name: str | None, tag: str | None) -> str | None:
    """Combine a name and a tag into a single caption.

    Applies the formatting rules for display names: blank and ``None`` values
    are ignored, identical values are not repeated, and parentheses are only
    used when both values are present.

    Parameters
    ----------
    name : str or None
        The leading part of the caption.
    tag : str or None
        The identifier shown in parentheses.

    Returns
    -------
    str or None
        The combined caption, or ``None`` if neither value is usable.

    Examples
    --------
    >>> combine_name_and_tag("Feed Pump", "P-4712")
    'Feed Pump (P-4712)'
    >>> combine_name_and_tag(None, "P-4712")
    'P-4712'
    >>> combine_name_and_tag("Feed Pump", "Feed Pump")
    'Feed Pump'
    >>> combine_name_and_tag("", "   ") is None
    True
    """
    values = [value.strip() for value in (name, tag) if isinstance(value, str) and value.strip()]

    if not values:
        return None

    if len(values) == 1 or values[0] == values[1]:
        return values[0]

    return f"{values[0]} ({values[1]})"


def _clean_string(value: object) -> str | None:
    """Return *value* stripped, or ``None`` if it is not a usable string.

    DEXPI string attributes are typed ``str | Undefined | None``, where
    ``Undefined`` is a sentinel *model instance* rather than a string. Only
    genuine, non-blank strings are accepted.

    Parameters
    ----------
    value : object
        The candidate value.

    Returns
    -------
    str or None
        The stripped string, or ``None``.
    """
    if isinstance(value, str) and value.strip():
        return value.strip()
    return None


def _first_string_attribute(obj: object, attribute_names: tuple[str, ...]) -> str | None:
    """Return the first non-blank string attribute of *obj*, or ``None``.

    Parameters
    ----------
    obj : object
        The object to read attributes from.
    attribute_names : tuple of str
        Attribute names to try, in priority order.

    Returns
    -------
    str or None
        The first usable value, stripped of surrounding whitespace.
    """
    for attribute_name in attribute_names:
        value = _clean_string(getattr(obj, attribute_name, None))
        if value is not None:
            return value
    return None


def _first_string_value(
    attributes: Mapping[str, object], attribute_names: tuple[str, ...]
) -> str | None:
    """Return the first non-blank string entry of *attributes*, or ``None``.

    The mapping counterpart of :func:`_first_string_attribute`, used for graph
    attribute dictionaries rather than model objects.

    Parameters
    ----------
    attributes : Mapping
        The attribute dictionary to read from.
    attribute_names : tuple of str
        Keys to try, in priority order.

    Returns
    -------
    str or None
        The first usable value, stripped of surrounding whitespace.
    """
    for attribute_name in attribute_names:
        value = _clean_string(attributes.get(attribute_name))
        if value is not None:
            return value
    return None


def instrument_tag(function: ProcessInstrumentationFunction) -> str | None:
    """The loop tag of an instrumentation function as a P&ID prints it: ``"PICSA-4712.02"``.

    That is the category letter and the further function letters, a hyphen, and the number.
    :func:`get_tag` resolves an instrumentation function by its number alone
    (``"4712.02"``), which is what the diff matches on and the query index keeps as its canonical
    key. Queries also accept this printed tag as an additional key. This is the tag a
    person reads, and the one to show in a list, where the number alone repeats -- a ``PI`` and a
    ``PT`` of one loop share it.

    Missing parts are left out rather than raising: no letters gives the number, no number gives
    the letters, neither gives ``None``.

    Examples
    --------
    >>> from pydexpi.pydexpi_classes.plant.instrumentation import ProcessInstrumentationFunction
    >>> instrument_tag(ProcessInstrumentationFunction(
    ...     processInstrumentationFunctionCategory="P",
    ...     processInstrumentationFunctions="ICSA",
    ...     processInstrumentationFunctionNumber="4712.02",
    ... ))
    'PICSA-4712.02'
    """
    letters = "".join(
        part
        for part in (
            _clean_string(getattr(function, "processInstrumentationFunctionCategory", None)),
            _clean_string(getattr(function, "processInstrumentationFunctions", None)),
        )
        if part
    )
    number = _clean_string(getattr(function, "processInstrumentationFunctionNumber", None))
    if letters and number:
        return f"{letters}-{number}"
    return letters or number


def get_tag(obj: PyDexpiBaseModel) -> str | None:
    """Return the engineering tag of *obj*, or ``None`` if it carries none.

    This is the tag part of :func:`get_display_name` without its last resort: the object id is
    never returned. Use it wherever a tag is wanted *as a tag* -- a label in a diff, a search
    field -- rather than as a caption, so that an untagged object reads as untagged instead of
    as its id.

    Resolution order:

    1. The type-specific attributes registered in :data:`DISPLAY_NAME_RESOLVERS`.
    2. The generic sweep over :data:`GENERIC_TAG_ATTRIBUTES`.

    Only non-blank strings count; ``Undefined`` and blank values are skipped.

    Parameters
    ----------
    obj : PyDexpiBaseModel
        The object to read the tag of.

    Returns
    -------
    str or None
        The tag, stripped of surrounding whitespace, or ``None``.

    Examples
    --------
    >>> from pydexpi.pydexpi_classes.plant.piping import PipingNode
    >>> from pydexpi.pydexpi_classes.plant.processEquipment import Tank
    >>> get_tag(Tank(tagName="T4750"))
    'T4750'
    >>> get_tag(PipingNode(id="PipingNode-1")) is None
    True
    """
    for dexpi_class, attribute_names in DISPLAY_NAME_RESOLVERS:
        if isinstance(obj, dexpi_class):
            identifier = _first_string_attribute(obj, attribute_names)
            if identifier is not None:
                return identifier
            # Registered but unset -- fall through to the generic sweep.
            break

    return _first_string_attribute(obj, GENERIC_TAG_ATTRIBUTES)


def _resolve_identifier(obj: PyDexpiBaseModel) -> str | None:
    """Resolve the identifier part of the display name for *obj*.

    Resolution order:

    1. The tag, as resolved by :func:`get_tag`.
    2. The :data:`CAPTION_FALLBACK_ATTRIBUTES` (a device type, or a process object's free-text
       label), which are not tags.
    3. The object ``id``, unless it was auto-generated by ``make_id``.

    Parameters
    ----------
    obj : PyDexpiBaseModel
        The object to resolve.

    Returns
    -------
    str or None
        The identifier, or ``None`` when no meaningful one exists.
    """
    identifier = get_tag(obj) or _first_string_attribute(obj, CAPTION_FALLBACK_ATTRIBUTES)
    if identifier is not None:
        return identifier

    object_id = getattr(obj, "id", None)
    if isinstance(object_id, str) and object_id.strip() and not is_generated_id(object_id):
        return object_id.strip()

    return None


def get_display_name(obj: PyDexpiBaseModel) -> str:
    """Return a human-readable caption for a pyDEXPI object.

    The caption is ``"{Humanised class name} ({identifier})"``, where the
    identifier is resolved from type-specific attributes. Objects without any
    usable identifier are captioned with the humanised class name alone. The
    result is deterministic and never empty.

    Parameters
    ----------
    obj : PyDexpiBaseModel
        The object to name.

    Returns
    -------
    str
        The display name, e.g. ``"Centrifugal Pump (P4711)"``.

    Examples
    --------
    >>> from pydexpi.pydexpi_classes.plant.processEquipment import Tank
    >>> get_display_name(Tank(tagName="T4750"))
    'Tank (T4750)'
    """
    class_name = humanize_class_name(type(obj).__name__)
    return combine_name_and_tag(class_name, _resolve_identifier(obj)) or class_name


def referenced_object_name(obj: PyDexpiBaseModel | None) -> str:
    """Name an object that a message mentions but ``affected_component_ids`` does not list.

    The display name, as for the affected objects. For an untagged object whose caption does not
    already show its id (the id was minted by ``make_id``), the id is appended: the message is
    then the only place a reader, or an agent fixing the model, can learn *which* node or item is
    meant. Ids are deliberately not added to ``affected_component_ids`` instead, because that
    list identifies the issue.

    Validation messages and other messages that name objects use it, which is why it lives here
    rather than in the validation package.

    Parameters
    ----------
    obj : PyDexpiBaseModel or None
        The referenced object, or ``None`` for an unset reference.

    Returns
    -------
    str
        E.g. ``"Globe Valve (66KL21)"``, ``"Piping Node (PipingNode51)"``,
        ``"Piping Node id_3f2a..."``, or ``"none"``.
    """
    if obj is None:
        return "none"
    name = get_display_name(obj)
    object_id = getattr(obj, "id", None)
    if get_tag(obj) is None and isinstance(object_id, str) and object_id not in name:
        return f"{name} {object_id}"
    return name


def get_relationship_display_name(
    label: str,
    attributes: Mapping[str, object] | None = None,
    inheritance: str = "",
) -> str | None:
    """Return the caption for a relationship formed by collapsing *label*.

    Collapsed relationships are captioned with a concise engineer-facing term
    from :data:`RELATIONSHIP_DISPLAY_NAMES` instead of the class-name caption a
    node would receive. Classes that are not registered there return ``None``,
    which leaves the caption inherited from the collapsed node untouched.

    Parameters
    ----------
    label : str
        The concrete class name of the collapsed node.
    attributes : Mapping, optional
        The attributes of the relationship being built. Searched for the
        identifier shown in parentheses, which may originate from a node that
        was merged into the collapsed one earlier -- a pipe's ``lineNumber``
        comes from its ``PipingNetworkSystem``.
    inheritance : str, default=""
        The collapsed node's colon-separated ``labels`` chain, used so that a
        subclass of a registered class still resolves.

    Returns
    -------
    str or None
        The caption, or ``None`` if *label* denotes no registered relationship.

    Examples
    --------
    >>> get_relationship_display_name("MeasuringLineFunction")
    'Measurement'
    >>> get_relationship_display_name("Pipe", {"lineNumber": "47121"})
    'Pipe (47121)'
    >>> get_relationship_display_name("Pipe")
    'Pipe'
    >>> get_relationship_display_name("BallValve") is None
    True
    """
    entry = RELATIONSHIP_DISPLAY_NAMES.get(label)
    if entry is None:
        for base_name in inheritance.split(":"):
            entry = RELATIONSHIP_DISPLAY_NAMES.get(base_name)
            if entry is not None:
                break
    if entry is None:
        return None

    term, attribute_names = entry
    identifier = None
    if attribute_names and attributes:
        identifier = _first_string_value(attributes, attribute_names)

    return combine_name_and_tag(term, identifier) or term
