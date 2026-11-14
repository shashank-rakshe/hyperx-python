"""Human-readable labels for enum values and attribute names.

:mod:`pydexpi.toolkits.display_name` captions *objects*. This module labels the two other things
a user interface shows next to them: the *value* of an enumerated attribute, and the *name* of an
attribute. Both follow the same rule as object captions, so that one source of wording serves the
graph exports, the table export, search, validation messages and any API built on pyDEXPI:

* :func:`enum_value_label` -- ``FailActionClassification.FailClose`` -> ``"Fail close"``, and a
  unit such as ``TemperatureUnit.DegreeCelsius`` -> ``"°C"``.
* :func:`attribute_label` -- ``"designPressure"`` -> ``"Design pressure"``.

Neither function imports :mod:`pydexpi.exports`, whose ``__init__`` pulls in pandas, openpyxl and
networkx. The dependency points the other way: the table export's
:func:`~pydexpi.exports.table_export.format_string` delegates to :func:`humanize_attribute_name`
here, so there is one implementation of the attribute-name casing.

Units are not labelled here. :func:`enum_value_label` hands them to
:func:`pydexpi.toolkits.quantity_format.unit_symbol`, the single home of the unit-symbol map.

Examples
--------
>>> from pydexpi.pydexpi_classes.core.physicalQuantities import PressureGaugeUnit
>>> from pydexpi.pydexpi_classes.plant.enumerations import FailActionClassification
>>> enum_value_label(FailActionClassification.FAILCLOSE)
'Fail close'
>>> enum_value_label(PressureGaugeUnit.BAR)
'barg'
>>> attribute_label("nominalDiameterRepresentation")
'Nominal diameter representation'
"""

from __future__ import annotations

import re
from enum import Enum
from functools import cache, lru_cache

from pydexpi.pydexpi_classes.pydexpi_classes import (
    MeasuredQuantity,
    NominalDiameterStandardClassification,
    NominalPressureStandardClassification,
    PhysicalQuantityUnit,
)
from pydexpi.toolkits.display_name import humanize_class_name
from pydexpi.toolkits.quantity_format import unit_symbol

__all__ = [
    "ATTRIBUTE_LABEL_OVERRIDES",
    "ENUM_VALUE_LABEL_OVERRIDES",
    "attribute_label",
    "enum_value_label",
    "humanize_attribute_name",
]


#: Curated attribute labels that the generic casing gets wrong or makes needlessly long. Keys are
#: attribute names of the generated classes (a test enforces that each still exists). These apply
#: to :func:`attribute_label` only: the table export's column headers stay the generic
#: :func:`humanize_attribute_name` output, because those headers are also the keys of the
#: translation tables in ``pydexpi.exports.table_locale``.
ATTRIBUTE_LABEL_OVERRIDES: dict[str, str] = {
    "processInstrumentationFunctionCategory": "Measured variable letters",
    "processInstrumentationFunctions": "Function letters",
    "processInstrumentationFunctionNumber": "Loop number",
    "processInstrumentationFunctionModifier": "Modifier letters",
    # The generic casing lowercases every capital, so acronyms fall apart ("Case u i d").
    "caseUID": "Case UID",
    "chEBI_identifier": "ChEBI identifier",
    "iUPAC_identifier": "IUPAC identifier",
    "provenanceURI": "Provenance URI",
    "referenceDataURI": "Reference data URI",
    "sourceURI": "Source URI",
    # Role.Uri: the field carries a trailing underscore so it does not shadow the class's uri
    # ClassVar; the reader sees DEXPI's name.
    "uri_": "URI",
    # Shown next to a valve or other piping component, "Piping" is redundant.
    "pipingComponentName": "Component name",
    "pipingComponentNumber": "Component number",
}

#: Curated labels for individual enum members whose humanised value reads badly. Keyed by
#: ``(enum class, value)`` rather than by the member, because ``StrEnum`` members of different
#: enums with the same value compare (and hash) equal.
ENUM_VALUE_LABEL_OVERRIDES: dict[tuple[type[Enum], str], str] = {
    (MeasuredQuantity, "AudioVisual"): "Audiovisual",
    (MeasuredQuantity, "WeightMassForce"): "Weight, mass or force",
}

#: Words of enum values that are acronyms or unit spellings, keyed by their lowercase form. The
#: generic sentence casing would otherwise lowercase them ("Din 2448", "Class 1000 kpa").
_ENUM_WORD_SPELLINGS: dict[str, str] = {
    "din": "DIN",
    "dn": "DN",
    "en": "EN",
    "gmp": "GMP",
    "iso": "ISO",
    "kpa": "kPa",
    "nps": "NPS",
    "pn": "PN",
}

#: Enums whose values are standard designations ("Din2448ObjectDn100", "Class150LbsArtefact").
#: Their "Object" / "Artefact" suffixes are modelling vocabulary, not part of the designation,
#: and are dropped: ``"DIN 2448 DN 100"``, ``"Class 150 lbs"``.
_DESIGNATION_ENUMS: frozenset[type[Enum]] = frozenset(
    {NominalDiameterStandardClassification, NominalPressureStandardClassification}
)
_DESIGNATION_FILLER_WORDS: frozenset[str] = frozenset({"object", "artefact"})

#: How the generator spelled characters that are not legal in a Python identifier.
_ENCODED_CHARACTERS: tuple[tuple[str, str], ...] = (("_PER_", "/"), ("_COMMA_", "."))

# A letter followed by a digit is a word boundary in an enum value ("Dn100" -> "Dn 100").
_LETTER_DIGIT_SPLIT = re.compile(r"(?<=[A-Za-z])(?=[0-9])")

# Every capital after the first character starts a new, lowercased word (``format_string``).
_ATTRIBUTE_CAPITAL = re.compile(r"([A-Z])")


@lru_cache(maxsize=1024)
def humanize_attribute_name(name: str) -> str:
    """Sentence-case a camelCase attribute name, without curated overrides.

    This is the casing of the table export's column headers
    (:func:`pydexpi.exports.table_export.format_string` delegates here), and therefore of the keys
    of the translation tables in ``pydexpi.exports.table_locale``. Changing it changes those keys.
    For a label to show a user, prefer :func:`attribute_label`.

    Parameters
    ----------
    name : str
        The attribute name, e.g. ``"pipingComponentName"``.

    Returns
    -------
    str
        The first character capitalised, and every later capital turned into a space and its
        lowercase form: ``"Piping component name"``. An empty name is returned unchanged.

    Examples
    --------
    >>> humanize_attribute_name("designPressure")
    'Design pressure'
    >>> humanize_attribute_name("caseUID")
    'Case u i d'
    """
    if not name:
        return name
    rest = _ATTRIBUTE_CAPITAL.sub(lambda match: " " + match.group(1).lower(), name[1:])
    return name[0].upper() + rest


@lru_cache(maxsize=1024)
def attribute_label(name: str) -> str:
    """Return the human-readable label for a DEXPI attribute name.

    The curated :data:`ATTRIBUTE_LABEL_OVERRIDES` first, then the generic
    :func:`humanize_attribute_name` casing.

    Parameters
    ----------
    name : str
        The attribute name as the generated classes spell it, e.g. ``"designPressure"``.

    Returns
    -------
    str
        The label, e.g. ``"Design pressure"``.

    Examples
    --------
    >>> attribute_label("designPressure")
    'Design pressure'
    >>> attribute_label("pipingComponentName")
    'Component name'
    >>> attribute_label("caseUID")
    'Case UID'
    """
    override = ATTRIBUTE_LABEL_OVERRIDES.get(name)
    if override is not None:
        return override
    return humanize_attribute_name(name)


def enum_value_label(member: Enum) -> str:
    """Return the human-readable label for an enum member.

    * A unit (any :class:`~pydexpi.pydexpi_classes.core.physicalQuantities.PhysicalQuantityUnit`)
      is labelled with its symbol, the pressure reference spelled out:
      ``DegreeCelsius`` -> ``"°C"``, ``PressureGaugeUnit.Bar`` -> ``"barg"``. A unit with no
      symbol is labelled like any other member: ``RatioUnit.Fraction`` -> ``"Fraction"``.
    * Any other member is labelled with its value in sentence case: ``"FailClose"`` ->
      ``"Fail close"``. Acronyms keep their spelling (``"Non-GMP relevant function"``), standard
      designations lose their ``Object`` / ``Artefact`` suffix (``"NPS 1 1/2"``, ``"EN 1333 PN
      2.5"``), and a few members have a curated label in :data:`ENUM_VALUE_LABEL_OVERRIDES`.

    Parameters
    ----------
    member : Enum
        The enum member, e.g. ``FailActionClassification.FAILCLOSE``.

    Returns
    -------
    str
        The label.

    Raises
    ------
    TypeError
        If *member* is not an enum member.

    Examples
    --------
    >>> from pydexpi.pydexpi_classes.core.physicalQuantities import TemperatureUnit
    >>> from pydexpi.pydexpi_classes.plant.enumerations import FailActionClassification
    >>> enum_value_label(TemperatureUnit.DEGREECELSIUS)
    '°C'
    >>> enum_value_label(FailActionClassification.FAILCLOSE)
    'Fail close'
    """
    if not isinstance(member, Enum):
        raise TypeError(f"enum_value_label expects an enum member, got {type(member).__name__}")
    # Cached on (class, name) rather than on the member: members of different StrEnums with the
    # same value compare equal, so PressureAbsoluteUnit.BAR would otherwise hit the cached label
    # of PressureGaugeUnit.BAR.
    return _enum_value_label(type(member), member.name)


@cache
def _enum_value_label(enum_class: type[Enum], member_name: str) -> str:
    """Label the member *member_name* of *enum_class*; see :func:`enum_value_label`."""
    member = enum_class[member_name]
    value = member.value
    if isinstance(member, PhysicalQuantityUnit):
        symbol = unit_symbol(member, qualify_pressure_reference=True)
        if symbol:
            return symbol
        # A unit without a symbol (RatioUnit.Fraction, new in DEXPI 2.0.1) renders "" next to a
        # value, which is right there, but a label stands alone and must say something: fall
        # through to the member's name.

    override = ENUM_VALUE_LABEL_OVERRIDES.get((enum_class, str(value)))
    if override is not None:
        return override

    raw = value if isinstance(value, str) else member_name
    return _sentence_case_enum_value(raw, drop_filler=enum_class in _DESIGNATION_ENUMS)


def _sentence_case_enum_value(value: str, *, drop_filler: bool) -> str:
    """Split a generated enum value into words and sentence-case them.

    Parameters
    ----------
    value : str
        The raw enum value, e.g. ``"Nps1_1_PER_2Artefact"``.
    drop_filler : bool
        Whether to drop the ``Object`` / ``Artefact`` modelling words.

    Returns
    -------
    str
        The label, e.g. ``"NPS 1 1/2"``.
    """
    for encoded, character in _ENCODED_CHARACTERS:
        value = value.replace(encoded, character)
    text = _LETTER_DIGIT_SPLIT.sub(" ", humanize_class_name(value)).replace("_", " ")
    words = text.split()
    if drop_filler:
        words = [word for word in words if word.lower() not in _DESIGNATION_FILLER_WORDS]
    if not words:
        return value

    spelled = [_ENUM_WORD_SPELLINGS.get(word.lower(), word.lower()) for word in words]
    if words[0].lower() not in _ENUM_WORD_SPELLINGS:
        spelled[0] = spelled[0][:1].upper() + spelled[0][1:]
    # "NonConfidentialInformation" is one negated adjective, not two words.
    if len(spelled) > 1 and spelled[0] == "Non":
        spelled[:2] = [f"Non-{spelled[1]}"]
    return " ".join(spelled)
