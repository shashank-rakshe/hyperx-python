"""Default `SymbolRegistrationNumber` for PlantEngineer's `ShapeCatalogue` entries.

`symbolRegistrationNumber` is a mandatory field on the DEXPI `Shape` class, but some shapes in
PlantEngineer's `ShapeCatalogue` carry a `SymbolRegistrationNumberAssignmentClass` generic
attribute with no `Value` at all (only `AttributeURI`/`Format`), e.g.::

    <PipeFlowArrow ID="PipeFlowArrowShape-1" ...>
      <GenericAttributes Set="DexpiAttributes" Number="1">
        <GenericAttribute Name="SymbolRegistrationNumberAssignmentClass"
                           AttributeURI="..." Format="string"/>
      </GenericAttributes>

The stock `GenericAttributeParser` skips any attribute with no `Value` (`value is None:
continue`), so the shape ends up with no `symbolRegistrationNumber` at all, which makes the
stock
:class:`~pydexpi.loaders.proteus_serializer.proteus_parser.parser_modules.ShapeParser` fail to
construct it (and every element referencing it, e.g. `ShapeUsage`, cascades from there). Some
shapes omit the generic attribute entirely instead. This is an opinionated,
PlantEngineer-specific accommodation (fall back to an empty string in both cases) rather than a
general proteus-parser bug fix, so it is applied here by rewriting the XML before it reaches the
stock parser, instead of changing `pydexpi.loaders.proteus_serializer`.
"""

from lxml import etree

from pydexpi.loaders.xml_parsing import parse_xml_string

SYMBOL_REGISTRATION_NUMBER_ATTRIBUTE_NAME = "SymbolRegistrationNumberAssignmentClass"
"""The generic attribute `Name` the stock parser maps to `Shape.symbolRegistrationNumber`."""

_GENERIC_ATTRIBUTES_SET = "DexpiAttributes"


def _names_symbol_registration_number(generic_attribute_name: str) -> bool:
    """Check whether a `GenericAttribute` `Name` resolves to the `symbolRegistrationNumber` field.

    Mirrors the name normalization `GenericAttributeParser` applies: strip an `AssignmentClass`
    or `Specialization` suffix, then lowercase the first character.
    """
    name = generic_attribute_name.removesuffix("AssignmentClass").removesuffix("Specialization")
    return bool(name) and name[0].lower() + name[1:] == "symbolRegistrationNumber"


def _find_symbol_registration_number_attribute(shape: etree._Element) -> etree._Element | None:
    """Return the shape's `SymbolRegistrationNumber` `GenericAttribute` element, if any.

    Returned regardless of whether it has a `Value` — the caller distinguishes "missing
    entirely" from "present but valueless".
    """
    for generic_attributes in shape.findall("GenericAttributes"):
        for attribute in generic_attributes.iterchildren(tag=etree.Element):
            name = attribute.get("Name")
            if name is not None and _names_symbol_registration_number(name):
                return attribute
    return None


def ensure_shape_symbol_registration_numbers_in_tree(root: etree._Element) -> None:
    """Default missing/valueless `SymbolRegistrationNumber` generic attributes, in place.

    This is the form the loader uses: it applies the default to an already-parsed tree, so that
    no entry point has to round-trip the document through a string (which would discard the
    encoding declared by the original bytes). `ensure_shape_symbol_registration_numbers` is the
    string-in, string-out wrapper around it.

    After this runs, every direct child of a `ShapeCatalogue` has a
    `SymbolRegistrationNumberAssignmentClass` generic attribute with a `Value`, defaulting to
    `""` where it was missing or valueless. Shapes that already have a value are left untouched.

    Parameters
    ----------
    root : etree._Element
        Root of a parsed Proteus document. Modified in place.
    """
    for shape_catalogue in root.iter("ShapeCatalogue"):
        for shape in shape_catalogue.iterchildren(tag=etree.Element):
            attribute = _find_symbol_registration_number_attribute(shape)
            if attribute is not None:
                if attribute.get("Value") is None:
                    attribute.set("Value", "")
                continue

            generic_attributes = next(
                (
                    attr_set
                    for attr_set in shape.findall("GenericAttributes")
                    if attr_set.get("Set") == _GENERIC_ATTRIBUTES_SET
                ),
                None,
            )
            if generic_attributes is None:
                generic_attributes = etree.SubElement(shape, "GenericAttributes")
                generic_attributes.set("Set", _GENERIC_ATTRIBUTES_SET)
            placeholder = etree.SubElement(generic_attributes, "GenericAttribute")
            placeholder.set("Name", SYMBOL_REGISTRATION_NUMBER_ATTRIBUTE_NAME)
            placeholder.set("Value", "")


def ensure_shape_symbol_registration_numbers(xml_string: str) -> str:
    """Default missing/valueless `SymbolRegistrationNumber` generic attributes on shapes.

    Parses `xml_string`, applies `ensure_shape_symbol_registration_numbers_in_tree`, and
    serializes the result back to a string.

    Parameters
    ----------
    xml_string : str
        Proteus XML content, potentially containing `ShapeCatalogue` shapes with a missing, or
        `Value`-less, `SymbolRegistrationNumberAssignmentClass` generic attribute.

    Returns
    -------
    str
        Proteus XML content where every direct child of a `ShapeCatalogue` has a
        `SymbolRegistrationNumberAssignmentClass` generic attribute with a `Value`, defaulting
        to `""` where it was missing or valueless. Shapes that already have a value are left
        untouched.
    """
    root = parse_xml_string(xml_string)
    ensure_shape_symbol_registration_numbers_in_tree(root)
    return etree.tostring(root, encoding="unicode")
