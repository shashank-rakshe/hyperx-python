"""Materialize diagram ``Text`` labels from the conceptual attributes they show.

A drawn label is a diagram ``Text`` graphical primitive whose ``text`` is a
*snapshot*, materialized when the model was imported or created.  The link back
to the data it displays is ``Text.template``: a ``TextTemplate`` whose fragments
are ``LiteralText`` (fixed characters) and ``AttributeRepresentation`` (an
explicit, machine-readable "this shows ``object.attributeName``").  This module
reads them:

- :func:`render_text_template` turns a template back into a string from the
  model's *current* state;
- :func:`find_dependent_texts` finds the labels whose template shows a given
  attribute.

This module never mutates the model.

Building templates
------------------
A label whose every ``Text`` is templated renders from the attributes it shows.
:func:`build_text_template` builds such templates and :func:`attribute_fragment` each
attribute fragment, and both refuse a fragment that would render while its value is unset and
stop rendering once it is set. :func:`render_text_template` renders an unset value as ``""``
before it looks at anything else, so such a fragment would not show the problem until the value
exists:

- a fragment names a **data** attribute of the labelled object -- never a
  composition, a reference or the id, whose set value renders ``None``;
- ``Units`` and ``ValueAndUnits`` are allowed only on a field whose every value
  type is a physical quantity, decided on the field's type: units on a string
  render ``None`` once it is set. ``QualifiedValue.value``, typed
  ``float | int | PhysicalQuantity | PhysicalQuantityVector | Undefined``, is refused for the
  same reason.

Separately, so that built templates match imported ones, a fragment
stores the attribute's DEXPI spelling (``TagName``, whatever the caller wrote):
the XML export writes ``attributeName`` verbatim. Rendering matches names
normalised, so the spelling does not change what a label shows.

Formatted fragments
-------------------
DEXPI's ``AttributeRepresentation`` says which attribute a fragment shows and whether
with its units, nothing more. A label also needs a fixed count of decimals and a text
for an unset value ("-", "TBD"), and both must stay in the template, or a re-render
would draw the label unformatted. The generated classes cannot grow a field, so
pyDEXPI keeps the options in ``attributeName`` itself, after the attribute's DEXPI
spelling (:class:`AttributeFormat`, :func:`format_attribute_name`)::

    DesignPressure|decimals=2|empty=n/a

``decimals`` is a count of digits after the decimal point, 0 to :data:`MAX_DECIMALS`;
``empty`` is shown while the attribute is unset or renders blank, with ``%`` and ``|``
(and any character that is not printable) percent-encoded as UTF-8. A plain fragment
carries no ``|`` at all, so every label without options reads as before. This is a
pyDEXPI extension: ``attributeName`` is a plain string in DEXPI XML and JSON, so the
options round-trip through both with no change to a loader or an export, and the
drawn ``Text.text`` is always the formatted rendering, so a viewer that only draws
the text shows the label right. A DEXPI tool that re-renders templates will not
resolve the name; it would leave such a label as drawn. Everything here reads a
fragment's attribute through :func:`split_attribute_name`, which
:func:`resolve_attribute_field` calls too, and a name with an option this module
does not know renders None (unknown), never a guess.
"""

from __future__ import annotations

import re
import types
import typing
from collections.abc import Iterable, Iterator
from dataclasses import dataclass
from enum import Enum
from functools import cache
from urllib.parse import unquote

from pydexpi.pydexpi_classes.core import physicalQuantities
from pydexpi.pydexpi_classes.core.diagram import (
    AttributeRepresentation,
    AttributeRepresentationType,
    LiteralText,
    Text,
    TextTemplate,
    TextTemplateFragment,
)
from pydexpi.pydexpi_classes.pydexpi_classes import (
    ConceptualObject,
    EngineeringModel,
    MultiLanguageString,
    PhysicalQuantity,
    PhysicalQuantityVector,
    PyDexpiBaseModel,
    Undefined,
)
from pydexpi.toolkits.base_model_utils import dexpi_attribute_name
from pydexpi.toolkits.display_name import get_display_name
from pydexpi.toolkits.model_provenance import flatten_multi_language_string
from pydexpi.toolkits.quantity_format import (
    number_with_decimals,
    unit_symbol,
    value_with_symbol,
)

__all__ = [
    "FORMAT_SEPARATOR",
    "MAX_DECIMALS",
    "AttributeFormat",
    "FragmentSpec",
    "LineSpec",
    "attribute_fragment",
    "bare_attribute_name",
    "build_text_template",
    "find_dependent_texts",
    "format_attribute_name",
    "iter_texts",
    "lines_are_blank",
    "render_text_template",
    "resolve_attribute_field",
    "split_attribute_name",
]

#: Separates the options of a formatted fragment from its attribute name, and each option from
#: the next (see "Formatted fragments" in the module docstring). No DEXPI name contains it.
FORMAT_SEPARATOR = "|"

#: The most digits after the decimal point a fragment may fix.
MAX_DECIMALS = 10

_DECIMALS_OPTION = "decimals"
_EMPTY_OPTION = "empty"

#: Representation types that ask for the unit rather than (only) the value.
_UNIT_TYPES = (
    AttributeRepresentationType.UNITS,
    AttributeRepresentationType.VALUEANDUNITS,
)


@dataclass(frozen=True)
class AttributeFormat:
    """How an attribute fragment formats its value, beyond what DEXPI's representation types say.

    Attributes
    ----------
    decimals : int | None
        Digits after the decimal point for a number, a physical quantity's value and each value
        of a vector, rounded half away from zero
        (:func:`~pydexpi.toolkits.quantity_format.number_with_decimals`). None shows the number
        as stored. Any other value is shown as it would be without it.
    empty_text : str | None
        Shown in place of the attribute while it is unset or renders blank. None, or ``""``,
        shows nothing.
    """

    decimals: int | None = None
    empty_text: str | None = None


def format_attribute_name(attribute_name: str, attribute_format: AttributeFormat) -> str:
    """The ``attributeName`` a fragment stores for `attribute_name` shown with `attribute_format`.

    Parameters
    ----------
    attribute_name : str
        The attribute's name, normally its DEXPI spelling; it must not contain
        :data:`FORMAT_SEPARATOR`.
    attribute_format : AttributeFormat
        The options. Without any, `attribute_name` is returned as it is.

    Returns
    -------
    str
        ``"<name>|decimals=<n>|empty=<text>"``, each option only when set.

    Raises
    ------
    ValueError
        If `attribute_name` contains the separator, or `decimals` is not an int from 0 to
        :data:`MAX_DECIMALS`.
    """
    if FORMAT_SEPARATOR in attribute_name:
        raise ValueError(
            f"An attribute name cannot contain {FORMAT_SEPARATOR!r}: {attribute_name!r}."
        )
    parts = [attribute_name]
    decimals = attribute_format.decimals
    if decimals is not None:
        if isinstance(decimals, bool) or not isinstance(decimals, int):
            raise ValueError(f"decimals must be a whole number, not {decimals!r}.")
        if not 0 <= decimals <= MAX_DECIMALS:
            raise ValueError(f"decimals must be from 0 to {MAX_DECIMALS}, not {decimals}.")
        parts.append(f"{_DECIMALS_OPTION}={decimals}")
    if attribute_format.empty_text:
        parts.append(f"{_EMPTY_OPTION}={_escape_option(attribute_format.empty_text)}")
    return FORMAT_SEPARATOR.join(parts)


def split_attribute_name(attribute_name: str) -> tuple[str, AttributeFormat] | None:
    """Read a fragment's ``attributeName`` as the attribute and its options.

    The inverse of :func:`format_attribute_name`. A name without :data:`FORMAT_SEPARATOR`, any
    imported one, is the attribute with no options.

    Parameters
    ----------
    attribute_name : str
        ``AttributeRepresentation.attributeName`` as stored.

    Returns
    -------
    tuple[str, AttributeFormat] | None
        The attribute's name and its options, or None if the options cannot be read: an
        option this module does not know, one given twice, one without ``=``, or a
        ``decimals`` that is not a count from 0 to :data:`MAX_DECIMALS`. None is never guessed
        past: such a fragment renders None, and a re-render leaves its label alone.
    """
    if not isinstance(attribute_name, str):
        return None
    if FORMAT_SEPARATOR not in attribute_name:
        return attribute_name, AttributeFormat()
    name, *options = attribute_name.split(FORMAT_SEPARATOR)
    values: dict[str, str] = {}
    for option in options:
        key, equals, value = option.partition("=")
        if not equals or key not in (_DECIMALS_OPTION, _EMPTY_OPTION) or key in values:
            return None
        values[key] = value
    decimals: int | None = None
    if _DECIMALS_OPTION in values:
        raw = values[_DECIMALS_OPTION]
        if not (raw.isascii() and raw.isdigit()) or int(raw) > MAX_DECIMALS:
            return None
        decimals = int(raw)
    empty_text = unquote(values[_EMPTY_OPTION]) if _EMPTY_OPTION in values else None
    return name, AttributeFormat(decimals=decimals, empty_text=empty_text or None)


def bare_attribute_name(attribute_name: str) -> str:
    """The attribute a fragment's ``attributeName`` names, without its options.

    For messages and listings. A name whose options cannot be read is returned as it is.
    """
    split = split_attribute_name(attribute_name)
    return split[0] if split is not None else attribute_name


def _escape_option(text: str) -> str:
    """Percent-encode, as UTF-8, what an option value cannot hold: ``%``, ``|``, non-printables."""
    return "".join(
        "".join(f"%{byte:02X}" for byte in char.encode("utf-8"))
        if char in "%" + FORMAT_SEPARATOR or not char.isprintable()
        else char
        for char in text
    )


def iter_texts(group) -> Iterator[Text]:
    """Yield every ``Text`` primitive in a graphics-group tree, depth first.

    Parameters
    ----------
    group : GraphicsGroup | GraphicalElement | None
        Any node of the diagram tree, typically ``model.diagram``. None yields
        nothing, so callers need not guard a model without a diagram.

    Yields
    ------
    Text
        Each ``Text`` primitive found below (and including) ``group``.
    """
    if group is None:
        return
    if isinstance(group, Text):
        yield group
    for subgroup in getattr(group, "groups", ()) or ():
        yield from iter_texts(subgroup)
    for element in getattr(group, "elements", ()) or ():
        yield from iter_texts(element)


def resolve_attribute_field(obj: PyDexpiBaseModel, attribute_name: str) -> str | None:
    """Map a DEXPI attribute name onto the pydantic field that holds it.

    ``AttributeRepresentation.attributeName`` carries the DEXPI spelling, which
    is the PascalCase of the XML schema and occasionally parenthesized
    (``"NominalCapacity(Volume)"``), while the generated classes use camelCase
    (``nominalCapacityVolume``).  Matching is therefore done on a normalized
    form: lowercased, with everything that is not a letter or digit removed.

    A formatted fragment's options (:func:`split_attribute_name`) are no part of
    the attribute: ``"DesignPressure|decimals=2"`` resolves as ``"DesignPressure"``.

    Parameters
    ----------
    obj : PyDexpiBaseModel
        The object the attribute is read from.
    attribute_name : str
        The attribute name as written in the template fragment.

    Returns
    -------
    str | None
        The field name to pass to ``getattr``, or None if ``obj`` has no such
        field, or the name carries options that cannot be read.
    """
    split = split_attribute_name(attribute_name)
    if split is None:
        return None
    attribute_name = split[0]
    fields = type(obj).model_fields
    if attribute_name in fields:
        return attribute_name
    normalized = _normalize_attribute_name(attribute_name)
    for field_name in fields:
        if _normalize_attribute_name(field_name) == normalized:
            return field_name
    return None


def render_text_template(template: TextTemplate | None) -> str | None:
    """Materialize a ``TextTemplate`` into a display string.

    Parameters
    ----------
    template : TextTemplate | None
        The template to render.

    Returns
    -------
    str | None
        The rendered label, or None if the template is absent, empty, or
        contains a fragment that cannot be rendered (an unknown fragment
        subclass, an attribute fragment holding no object, an attribute the
        referenced object does not have, or a value of a type with no defined
        rendering).  None means "unknown", never
        "empty" -- an empty string is a legitimate rendering of an unset
        attribute, and the two must not be confused.
    """
    if template is None or not template.fragments:
        return None
    parts: list[str] = []
    for fragment in template.fragments:
        rendered = _render_fragment(fragment)
        if rendered is None:
            return None
        parts.append(rendered)
    return "".join(parts)


def find_dependent_texts(
    model: EngineeringModel, obj: PyDexpiBaseModel, attribute_names: Iterable[str]
) -> list[Text]:
    """Find the diagram labels whose template displays one of ``attribute_names``.

    Parameters
    ----------
    model : EngineeringModel
        The model whose diagram is searched.
    obj : PyDexpiBaseModel
        The conceptual object whose attributes changed.
    attribute_names : Iterable[str]
        Field names on ``obj``, in the generated classes' camelCase spelling.

    Returns
    -------
    list[Text]
        Every ``Text`` whose ``template`` contains an ``AttributeRepresentation``
        pointing at ``obj`` and at one of the named attributes. Identity of the
        referenced object is compared by ``is``, not by equality: two distinct
        items with equal field values must not share labels.
    """
    wanted = {_normalize_attribute_name(name) for name in attribute_names}
    return [
        text
        for text in iter_texts(model.diagram)
        if _template_references(text.template, obj, wanted)
    ]


@dataclass(frozen=True)
class FragmentSpec:
    """One fragment of a label line: a literal, or a data attribute of the labelled object.

    Exactly one of `text` and `attribute` is set; :func:`build_text_template` refuses
    anything else.

    Attributes
    ----------
    text : str | None
        Characters shown as they are, such as the ``" "`` between two attributes.
    attribute : str | None
        A data attribute of the labelled object, in its DEXPI spelling (``"TagName"``) or
        its field name (``"tagName"``).
    type : AttributeRepresentationType
        How an attribute is shown; ``Value`` for a literal.
    decimals : int | None
        Digits after the decimal point for an attribute's number (:class:`AttributeFormat`);
        None for a literal.
    empty_text : str | None
        What an attribute shows while unset or blank (:class:`AttributeFormat`); None for a
        literal.
    """

    text: str | None = None
    attribute: str | None = None
    type: AttributeRepresentationType = AttributeRepresentationType.VALUE
    decimals: int | None = None
    empty_text: str | None = None


@dataclass(frozen=True)
class LineSpec:
    """One line of a label, which becomes one ``Text``.

    Attributes
    ----------
    fragments : tuple[FragmentSpec, ...]
        What the line shows, in order.
    offset : tuple[float, float]
        Where the line sits relative to the label's position, in sheet units, Y-down.
    """

    fragments: tuple[FragmentSpec, ...]
    offset: tuple[float, float] = (0.0, 0.0)


def lines_are_blank(obj: PyDexpiBaseModel, lines: Iterable[LineSpec]) -> bool:
    """Whether every one of `lines` would be blank for `obj` as it is now.

    A line that cannot be built at all (an attribute the object lacks) or that cannot be shown
    as text counts as blank here; it is refused where the label is built.
    """
    for line in lines:
        try:
            text = render_text_template(build_text_template(obj, line.fragments))
        except ValueError:
            continue
        if text is not None and text.strip():
            return False
    return True


def attribute_fragment(
    obj: ConceptualObject,
    attribute_name: str,
    representation_type: AttributeRepresentationType = AttributeRepresentationType.VALUE,
    *,
    decimals: int | None = None,
    empty_text: str | None = None,
) -> AttributeRepresentation:
    """A template fragment showing one data attribute of `obj`, checked to render once set.

    See the module docstring for the two rules this enforces and why.

    Parameters
    ----------
    obj : ConceptualObject
        The object whose attribute the fragment shows.
    attribute_name : str
        The attribute, in its DEXPI spelling or as a field name; resolved as
        :func:`resolve_attribute_field` resolves a template's.
    representation_type : AttributeRepresentationType
        ``Value``, or ``Units`` / ``ValueAndUnits`` for a physical quantity.
    decimals : int | None
        Digits after the decimal point, 0 to :data:`MAX_DECIMALS`, for a field that can hold a
        number; see :class:`AttributeFormat`.
    empty_text : str | None
        What the fragment shows while the attribute is unset or blank.

    Returns
    -------
    AttributeRepresentation
        A fragment on `obj`, whose ``attributeName`` is the attribute's DEXPI spelling
        (:func:`~pydexpi.toolkits.base_model_utils.dexpi_attribute_name`), whatever the
        caller wrote, followed by the options when there are any
        (:func:`format_attribute_name`).

    Raises
    ------
    ValueError
        If `obj` has no such attribute, if it is not a data attribute (a composition, a
        reference, or the id), if units are asked of a field that can hold something
        other than a physical quantity, if `attribute_name` carries options of its own, or
        if `decimals` is out of range, is given with ``Units`` or for a field that never holds
        a number. The message names `obj` by its display name.
    """
    cls = type(obj)
    if FORMAT_SEPARATOR in attribute_name:
        raise ValueError(
            f"{attribute_name!r} is not an attribute name; give the decimals and the text for "
            "an empty value as options of the fragment."
        )
    field_name = resolve_attribute_field(obj, attribute_name)
    if field_name is None:
        raise ValueError(f"{get_display_name(obj)} has no attribute {attribute_name!r} to show.")
    extra = cls.model_fields[field_name].json_schema_extra
    category = extra.get("attribute_category") if isinstance(extra, dict) else None
    if category != "data":
        kind = f"a {category} attribute" if isinstance(category, str) else "not a data attribute"
        raise ValueError(
            f"{attribute_name!r} of {get_display_name(obj)} is {kind}; a label shows data "
            "attributes only."
        )
    if representation_type in _UNIT_TYPES and not _holds_quantities_only(cls, field_name):
        raise ValueError(
            f"{attribute_name!r} of {get_display_name(obj)} can hold a value that is not a "
            "physical quantity, so it has no units to show; show it as "
            f"{AttributeRepresentationType.VALUE.value}."
        )
    if decimals is not None:
        if representation_type == AttributeRepresentationType.UNITS:
            raise ValueError(
                f"{attribute_name!r} of {get_display_name(obj)} is shown as its units, which "
                "have no decimals."
            )
        if not _can_hold_numbers(cls, field_name):
            raise ValueError(
                f"{attribute_name!r} of {get_display_name(obj)} never holds a number, so it "
                "has no decimals to fix."
            )
    return AttributeRepresentation(
        object=obj,
        attributeName=format_attribute_name(
            dexpi_attribute_name(cls, field_name),
            AttributeFormat(decimals=decimals, empty_text=empty_text),
        ),
        type=representation_type,
    )


def build_text_template(obj: ConceptualObject, fragments: Iterable[FragmentSpec]) -> TextTemplate:
    """The template for one label line on `obj`: a ``LiteralText`` or checked attribute each.

    Parameters
    ----------
    obj : ConceptualObject
        The labelled object; every attribute fragment names one of its data attributes.
    fragments : Iterable[FragmentSpec]
        The line's fragments, in order.

    Returns
    -------
    TextTemplate
        The template. It is not rendered here: the caller decides what an unset attribute
        or an unrenderable value means for it.

    Raises
    ------
    ValueError
        If there are no fragments, if one is neither or both of a literal and an attribute,
        if a literal asks for units, decimals or a text for an empty value, or for any reason
        :func:`attribute_fragment` gives.
    """
    built: list[TextTemplateFragment] = []
    for spec in fragments:
        if (spec.text is None) == (spec.attribute is None):
            raise ValueError(
                "A label fragment is either literal text or an attribute, exactly one of the two."
            )
        if spec.text is not None:
            if spec.type != AttributeRepresentationType.VALUE:
                raise ValueError(f"The literal {spec.text!r} has no units to show.")
            if spec.decimals is not None or spec.empty_text is not None:
                raise ValueError(
                    f"The literal {spec.text!r} is shown as written; decimals and a text for an "
                    "empty value belong to an attribute."
                )
            built.append(LiteralText(text=spec.text))
        else:
            assert spec.attribute is not None  # narrowed by the exclusive check above
            built.append(
                attribute_fragment(
                    obj,
                    spec.attribute,
                    spec.type,
                    decimals=spec.decimals,
                    empty_text=spec.empty_text,
                )
            )
    if not built:
        raise ValueError("A label line needs at least one fragment.")
    return TextTemplate(fragments=built)


@cache
def _type_hints(cls: type) -> dict[str, typing.Any]:
    """The resolved annotations of a generated class.

    ``model_fields`` keeps some as unresolved strings -- ``QualifiedValue.value`` is a
    ``ForwardRef('float | int | PhysicalQuantity | PhysicalQuantityVector | Undefined')`` -- so
    the field's own annotation cannot be read for its value types.
    """
    return typing.get_type_hints(cls)


def _union_members(annotation: object) -> list[object]:
    """The members of a union annotation, nested unions flattened; anything else alone."""
    if typing.get_origin(annotation) in (typing.Union, types.UnionType):
        return [member for arg in typing.get_args(annotation) for member in _union_members(arg)]
    return [annotation]


def _holds_quantities_only(cls: type, field_name: str) -> bool:
    """True if every value `field_name` of `cls` admits, besides unset, is a physical quantity."""
    values = [
        member
        for member in _union_members(_type_hints(cls)[field_name])
        if member is not type(None) and member is not Undefined
    ]
    return bool(values) and all(
        isinstance(member, type) and issubclass(member, (PhysicalQuantity, PhysicalQuantityVector))
        for member in values
    )


def _can_hold_numbers(cls: type, field_name: str) -> bool:
    """True if `field_name` of `cls` admits a number or a physical quantity among its values."""
    return any(
        isinstance(member, type)
        and member is not bool
        and issubclass(member, (int, float, PhysicalQuantity, PhysicalQuantityVector))
        for member in _union_members(_type_hints(cls)[field_name])
    )


def _normalize_attribute_name(name: str) -> str:
    """Reduce an attribute name to letters and digits, lowercased."""
    return re.sub(r"[^0-9a-z]", "", name.lower())


def _template_references(
    template: TextTemplate | None, obj: PyDexpiBaseModel, wanted: set[str]
) -> bool:
    """True if ``template`` has an AttributeRepresentation for obj + a wanted name."""
    if template is None:
        return False
    return any(
        isinstance(fragment, AttributeRepresentation)
        and fragment.object is obj
        and _normalize_attribute_name(bare_attribute_name(fragment.attributeName)) in wanted
        for fragment in template.fragments
    )


def _render_fragment(fragment) -> str | None:
    """Render one template fragment, or None if it cannot be rendered."""
    if isinstance(fragment, LiteralText):
        return fragment.text if isinstance(fragment.text, str) else None
    if isinstance(fragment, AttributeRepresentation):
        return _render_attribute_representation(fragment)
    # Bare TextTemplateFragment (what the Proteus parser emits) or any fragment
    # subclass added later: it carries no renderable content, and guessing would
    # silently drop characters from the label.
    return None


def _render_attribute_representation(fragment: AttributeRepresentation) -> str | None:
    """Render an AttributeRepresentation from the referenced object's current state.

    A fragment that holds no object renders None: the XML loader leaves ``object`` None,
    with an ERROR in its registry, when the document's reference does not resolve, and
    there is nothing to read the attribute from.

    A formatted fragment (:class:`AttributeFormat`) fixes the decimals of what it renders, and
    renders its empty text in place of a blank rendering; one whose options cannot be read
    renders None.
    """
    obj = fragment.object
    if not isinstance(obj, PyDexpiBaseModel):
        return None
    split = split_attribute_name(fragment.attributeName)
    if split is None:
        return None
    name, attribute_format = split
    field_name = resolve_attribute_field(obj, name)
    if field_name is None:
        return None
    rendered = _render_value(
        getattr(obj, field_name), fragment.type, decimals=attribute_format.decimals
    )
    if rendered is not None and not rendered.strip() and attribute_format.empty_text:
        return attribute_format.empty_text
    return rendered


def _render_value(
    value, representation_type: AttributeRepresentationType, *, decimals: int | None = None
) -> str | None:
    """Render a DEXPI attribute value for the requested representation type.

    `decimals` fixes the digits after the decimal point of a number; it leaves any other value
    as it is.
    """
    if value is None or isinstance(value, Undefined):
        return ""
    if _is_physical_quantity(value):
        return _render_physical_quantity(value, representation_type, decimals=decimals)
    if representation_type in _UNIT_TYPES:
        # A non-quantity attribute has no unit to show. Refuse rather than
        # render the value alone, which would drop whatever the authoring tool
        # put there.
        return None
    if isinstance(value, MultiLanguageString):
        return flatten_multi_language_string(value) or ""
    if isinstance(value, Enum):
        return str(value.value)
    if isinstance(value, bool):
        return str(value)
    if isinstance(value, (int, float)):
        return number_with_decimals(value, decimals)
    if isinstance(value, str):
        return value
    return None


def _is_physical_quantity(value) -> bool:
    """True for the generated PhysicalQuantity / PhysicalQuantityVector types."""
    return hasattr(value, "unit") and hasattr(physicalQuantities, type(value).__name__)


def _render_physical_quantity(
    value, representation_type: AttributeRepresentationType, *, decimals: int | None = None
) -> str | None:
    """Render a physical quantity as value, unit, or both.

    ``qualify_pressure_reference`` is on because P&ID labels spell the pressure
    reference out -- the DEXPI reference drawing writes "60 barg", not "60 bar".
    """
    symbol = unit_symbol(value.unit, qualify_pressure_reference=True)
    if representation_type == AttributeRepresentationType.UNITS:
        return symbol
    # PhysicalQuantityVector carries a list of values instead of a single one.
    if hasattr(value, "values"):
        numbers = [
            _render_value(item, AttributeRepresentationType.VALUE, decimals=decimals)
            for item in value.values
        ]
        if any(number is None for number in numbers):
            return None
        rendered_value = " ".join(numbers)
    else:
        rendered_value = number_with_decimals(value.value, decimals)
    if representation_type == AttributeRepresentationType.VALUEANDUNITS:
        return value_with_symbol(rendered_value, symbol)
    return rendered_value
