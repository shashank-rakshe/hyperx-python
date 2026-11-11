"""One way to turn a DEXPI attribute value into something a graph backend accepts.

Before this module the conversion existed four times and no two agreed:

=========================  =======================  ==========================  =============
input                      ``graph_loader``         ``neo4j_export``            provenance
=========================  =======================  ==========================  =============
``None``                   omitted                  ``""``                      omitted
``bool``                   ``bool``                 ``"true"`` / ``"false"``    ``bool``
non-``str`` ``Enum``       ``.value``               ``"Class.MEMBER"``          ``.value``
``dict`` / ``list``        ``json.dumps``           Python ``repr``             ``str()``
``datetime``               **passed through**       ``"1990-10-03 00:00:00"``   ISO 8601
``MultiLanguageString``    JSON blob                --                          flat text
=========================  =======================  ==========================  =============

The divergence was reachable on real models. A boolean attribute was a real ``bool`` on a GraphML
node and the *string* ``"true"`` in Neo4j, so ``WHERE n.flag = true`` failed there.
``equipmentDescription`` reached a node as a JSON blob while ``drawingSubTitle`` -- the same
``MultiLanguageString`` type -- reached ``graph.graph`` as readable text. And a ``datetime`` data
attribute was passed through untouched, for ``graphml_export.normalize_graphml_attributes`` to
refuse, killing the whole export.

``normalize_graphml_attributes`` is **not** a fifth implementation and is deliberately left alone:
it is the *validation* boundary that refuses what GraphML cannot carry, which is a different job
from deciding what a value should become. With this module in place nothing upstream hands it a
``datetime`` any more.
"""

import json
from datetime import date, datetime
from enum import Enum

from pydexpi.pydexpi_classes.pydexpi_classes import (
    MultiLanguageString,
    PyDexpiDataTypeBaseModel,
    Undefined,
)

#: What a graph backend can hold. ``None`` is not one of them: it means *omit this key*, because
#: GraphML has no null and Neo4j has no reason to store one.
GraphValue = str | int | float | bool


def coerce_for_graph(value: object, preferred_language: str = "en") -> GraphValue | None:
    """Return *value* as something a graph backend accepts, or ``None`` to omit it.

    The branch order is load-bearing:

    - ``Undefined`` before the data-type case, because it *is* one and means "not known";
    - ``Enum`` before ``str``, because ``ConfidentialityClassification`` is a ``StrEnum`` and
      would otherwise be stored as its member repr;
    - ``bool`` before the numeric case, because ``bool`` subclasses ``int``.

    ``PhysicalQuantity`` is not special-cased here. The graph loader splits a quantity into a
    numeric ``foo`` and a ``foo_unit`` *before* reaching this function -- see
    ``graph_loader._quantity_attributes`` -- because a single scalar cannot carry both and a range
    query needs the number. A quantity that does arrive here is serialised as JSON rather than
    silently flattened to a lossy string.

    **Structured values are dumped with ``default=coerce_for_graph``, not
    ``model_dump(mode="json")``.** The obvious choice is the wrong one: ``mode="json"`` renders
    ``PhysicalQuantity.unit`` as ``"PressureGaugeUnit.Bar"`` instead of ``"Bar"``, because ``unit``
    is annotated with the *memberless* ``PhysicalQuantityUnit`` base (a known quirk),
    so pydantic cannot match the member and falls back. Recursing through this function
    instead gives ``"Bar"``, ISO-formats nested dates, and unwraps nested enums -- so a nested
    value follows exactly the same rules as a top-level one, which is the point of having one
    table.

    Parameters
    ----------
    value : object
        The attribute value to convert.
    preferred_language : str, default ``"en"``
        Language to prefer when flattening a ``MultiLanguageString``.

    Returns
    -------
    str or int or float or bool or None
        The value a backend should store, or ``None`` when the attribute carries nothing and the
        key should be left out entirely.
    """
    if value is None or isinstance(value, Undefined):
        return None
    if isinstance(value, MultiLanguageString):
        return flatten_multi_language_string(value, preferred_language)
    if isinstance(value, Enum):
        return coerce_for_graph(value.value, preferred_language)
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value
    if isinstance(value, (datetime, date)):
        return value.isoformat()
    if isinstance(value, str):
        return value.strip() or None
    if isinstance(value, PyDexpiDataTypeBaseModel):
        return json.dumps(value.model_dump(), default=coerce_for_graph)
    if isinstance(value, (set, frozenset)):
        # JSON has no set, so `json.dumps` would hand it straight back to `default=` -- which is
        # this function -- and recurse until the stack runs out. Converted here instead, and
        # sorted by repr so the same model always exports the same string.
        return json.dumps(sorted(value, key=repr), default=coerce_for_graph)
    if isinstance(value, (dict, list, tuple)):
        return json.dumps(value, default=coerce_for_graph)
    return str(value) or None


def flatten_multi_language_string(
    value: MultiLanguageString, preferred_language: str = "en"
) -> str | None:
    """Pick one string out of a ``MultiLanguageString``.

    The single flattening implementation, shared by the provenance extractor, the table export,
    label rendering and graph node attributes -- do not add a parallel one. ``model_provenance``
    re-exports it, so the import path its callers already use keeps working.

    Mutually recursive with :func:`coerce_for_graph`, which is what strips and rejects the
    individual entries.

    Parameters
    ----------
    value : MultiLanguageString
        The multi-language value to flatten.
    preferred_language : str, default ``"en"``
        BCP-47 primary language subtag to prefer. A region-tagged entry matches its primary
        subtag (``"en-US"`` satisfies ``"en"``).

    Returns
    -------
    str or None
        The preferred-language string, falling back to English and then to the first non-empty
        entry; ``None`` when every entry is empty.
    """
    strings = value.singleLanguageStrings or []

    def matching(language: str) -> list:
        prefix = language.lower()
        return [
            s
            for s in strings
            if isinstance(entry_language := getattr(s, "language", None), str)
            and (
                entry_language.lower() == prefix or entry_language.lower().startswith(prefix + "-")
            )
        ]

    candidate_lists = [matching(preferred_language)]
    if preferred_language.lower() != "en":
        candidate_lists.append(matching("en"))
    candidate_lists.append(strings)
    for candidates in candidate_lists:
        for single in candidates:
            text = coerce_for_graph(single.value, preferred_language)
            if text is not None:
                return str(text)
    return None
