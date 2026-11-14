"""Implementation of the tree-reference loading framework for DEXPI XML serialization.

Provides `DexpiXmlSerializer` as main entry point for DEXPI XML serialization and deserialization of
pyDEXPI models."""

from __future__ import annotations

import math
import re
from collections.abc import Iterable
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from pathlib import Path
from typing import ForwardRef, Literal, TypeVar, get_origin

from lxml import etree

from pydexpi import pydexpi_classes
from pydexpi.attribution import generator_comment
from pydexpi.loaders.error_registry import ErrorRegistry, SourceLocation
from pydexpi.loaders.source_location import source_location_from_xml_element
from pydexpi.loaders.tree_ref_base.exporter import SerializerDataFieldType
from pydexpi.loaders.tree_ref_base.loader import DeserializerDataFieldType, RepeatedData
from pydexpi.loaders.tree_ref_base.utility_base import AbstractTreeReferenceSerializer
from pydexpi.loaders.xml_parsing import (
    load_xml_schema,
    parse_xml_bytes,
    parse_xml_file,
    parse_xml_string,
)
from pydexpi.pydexpi_classes import PyDexpiBaseModel
from pydexpi.pydexpi_classes._spec_info import MODEL_URIS
from pydexpi.toolkits.base_model_utils import (
    dexpi_attribute_name,
    dexpi_attribute_names,
    get_dexpi_package_mapping,
)

T = TypeVar("T")

#: The C0 control characters that XML 1.0 cannot represent in any form. The gaps in
#: these ranges are TAB, LF and CR -- the only three C0 characters admitted by the
#: ``Char`` production (XML 1.0 5th ed., section 2.2). For the rest there is neither a
#: literal spelling nor a numeric-character-reference spelling: ``&#11;`` is exactly as
#: illegal as a raw ``\x0b``. No escaping scheme can rescue them, so the serializer
#: refuses them rather than writing a document it cannot read back.
#:
#: DEL (U+007F) and the C1 block (U+0080-U+009F) are deliberately absent: XML 1.0
#: permits them and they round-trip unchanged today.
_XML_UNREPRESENTABLE_CHARS = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")


def _xsd_double(value: float) -> str:
    """The text of a ``<Double>``: an ``xsd:double`` literal for *value*.

    Python's ``str`` is one for every finite float, and is what has always been written. It is
    not for the three values that are not finite: ``xsd:double`` spells them ``NaN``, ``INF``
    and ``-INF``, case-sensitively, and a document saying ``nan`` or ``inf`` is rejected by the
    DEXPI XML schema. The loader reads either spelling, ``float`` taking both, so documents
    pyDEXPI wrote before still load.
    """
    if math.isfinite(value):
        return str(value)
    if math.isnan(value):
        return "NaN"
    return "INF" if value > 0 else "-INF"


def _reject_unrepresentable_characters(value: str, location: str) -> None:
    """Raise if *value* holds a character DEXPI XML cannot carry.

    Carriage returns are deliberately not in this set, and the distinction is one of
    kind: a CR has a lossless representation -- ``lxml`` serializes it as the numeric
    character reference ``&#13;`` in both element text and attribute values, which is
    exempt from XML end-of-line normalisation (XML 1.0 5th ed., section 2.11) -- so
    the serializer emits it and the caller never needs to know. The characters caught
    here have none, so the only alternatives are refusing to write them or dropping
    them silently. Writing a file that pyDEXPI cannot read back is the worse outcome, and
    dropping data without saying so is what this whole area of the code got wrong.

    Parameters
    ----------
    value : str
        The string about to be written into the document.
    location : str
        Where the value came from, phrased to slot into the message -- for example
        ``"attribute 'tagName' of object 'pump-1'"``.

    Raises
    ------
    ValueError
        If *value* contains a character matching :data:`_XML_UNREPRESENTABLE_CHARS`.
    """
    match = _XML_UNREPRESENTABLE_CHARS.search(value)
    if match is None:
        return

    # Window the excerpt around the offending character rather than truncating the
    # head of the value: data attributes can be long, and a message that cuts out the
    # very character it is reporting is no help in finding it.
    start = max(match.start() - 20, 0)
    end = min(match.start() + 21, len(value))
    excerpt = f"{'...' if start else ''}{value[start:end]}{'...' if end < len(value) else ''}"
    raise ValueError(
        f"Cannot export to DEXPI XML: {location} contains the control character "
        f"U+{ord(match.group()):04X} at index {match.start()}. XML 1.0 has no "
        f"representation for it -- neither as a literal nor as a numeric character "
        f"reference -- so it cannot be written. Offending value: {excerpt!r}"
    )


def build_generator_comment() -> str:
    """Return the XML comment naming the system that generated the document.

    The comment sits above the root ``Model`` element, where XML allows free-standing
    comments, so it is invisible to every parser and to XSD validation while staying
    readable to a human opening the file.

    Returns
    -------
    str
        A serialized XML comment ending in a newline.
    """
    # A comment may not contain "--" nor end in "-". The text is partly
    # environment-supplied (see pydexpi.attribution), so sanitize rather than trust.
    text = re.sub(r"-{2,}", "-", generator_comment()).rstrip("-").strip()
    return etree.tostring(etree.Comment(f" {text} "), encoding="unicode") + "\n"


@dataclass
class DexpiXmlImport:
    """A single DEXPI XML import declaration."""

    prefix: str
    package: str
    source: str


def default_imports() -> list[DexpiXmlImport]:
    """The ``<Import>`` declarations of a DEXPI XML document pyDEXPI writes.

    One per DEXPI model -- Core, Plant, Process -- each pointing at that model's URI in the
    specification the classes were generated from (``pydexpi_classes._spec_info.MODEL_URIS``,
    written by pyDEXPI-builder), so a document declares the DEXPI version of the classes that
    wrote it rather than a hand-kept one.

    Returns
    -------
    list[DexpiXmlImport]
        A fresh list, in model order, each import's prefix and package being the model name.
    """
    return [DexpiXmlImport(model, model, uri) for model, uri in MODEL_URIS.items()]


@dataclass
class DexpiXmlModelMetadata:
    """Metadata for a DEXPI XML model document."""

    name: str = "example"
    uri: str = "http://www.example.org"
    imports: list[DexpiXmlImport] = field(default_factory=default_imports)


def _object_references(element: etree._Element) -> list[etree._Element]:
    """The ``<ObjectReference>`` children of a ``<Components>`` element, in document order."""
    return list(element.iterchildren(tag="ObjectReference"))


class DexpiXmlDeserializationElement:
    """Class representing a deserialization element for the DEXPI XML serializer.

    This class implements the DeserializationElement interface and encapsulates the XML readout
    logic for the `TreeReferenceLoader`.
    """

    def __init__(self, element: etree._Element):
        """Initialize the deserialization element with the given XML element.

        Parameters
        ----------
        element : etree._Element
            The XML element to be deserialized.
        """
        self.element = element

    def get_id(self) -> str | None:
        """Get the unique identifier of the element if available.

        Returns
        -------
        str or None
            The unique identifier of the element, or None if not available.
        """
        return self.element.get("id")

    def get_dexpi_class(self) -> str:
        """Get the DEXPI class name from the XML element.

        Returns
        -------
        str
            The DEXPI class name specified in the XML element.
        """
        if self.element.tag == "Undefined":
            return "Undefined"
        xml_type = self.element.get("type")
        return self._get_class_name_from_name_reference(xml_type)

    def get_composition_attributes(
        self,
    ) -> dict[
        str,
        DexpiXmlDeserializationElement | list[DexpiXmlDeserializationElement] | None,
    ]:
        """Return all composition attributes keyed by pyDEXPI field name.

        A ``<Components>`` element holding only ``<ObjectReference>`` s names objects composed
        elsewhere, so `get_reference_attributes` reads it instead.
        """
        composition_elements = self._extract_attribute_elements("Components")
        composition_attributes = {}
        for attr_name, element in composition_elements.items():
            if _object_references(element) and element.find("Object") is None:
                continue
            is_list_field = self._is_list_field(attr_name)

            if element is None:
                composition_attributes[attr_name] = [] if is_list_field else None
                continue

            # Build wrapped child objects for nested compositional values.
            objects = [DexpiXmlDeserializationElement(child) for child in element.findall("Object")]

            # Dispatch correct return type based on is_list_field
            composition_attributes[attr_name] = self._package_return_type(objects, is_list_field)
        return composition_attributes

    def get_reference_attributes(self) -> dict[str, str | list[str] | None]:
        """Return all reference attributes keyed by pyDEXPI field name.

        Besides ``<References property="X" objects="#a #b"/>``, the DEXPI XML schema lets a
        ``<Components property="X">`` hold ``<ObjectReference object="#a"/>`` children: objects
        named there rather than composed. bpmn2dexpi writes ``Port.SubReference`` that way, 18
        times, and pyDEXPI's classes make that property a reference (the ``PORT-SUBREFERENCE``
        deviation), so such an element is read as references. That holds whatever the field: one
        that is not a reference is then reported by the loader, rather than dropped silently.
        """
        reference_ids: dict[str, list[str]] = {}
        for attr_name, element in self._extract_attribute_elements("References").items():
            reference_ids[attr_name] = self._extract_reference_ids(element.get("objects"))
        for attr_name, element in self._extract_attribute_elements("Components").items():
            for reference in _object_references(element):
                reference_ids.setdefault(attr_name, []).extend(
                    self._extract_reference_ids(reference.get("object"))
                )
        return {
            attr_name: self._package_return_type(ids, self._is_list_field(attr_name))
            for attr_name, ids in reference_ids.items()
        }

    def get_source_location(self) -> SourceLocation:
        """Return where this element sits in the XML document it was parsed from.

        Returns
        -------
        SourceLocation
            The tag, XPath and line number of the element. The XPath is structural and refers to
            the exact document parsed, so it is not stable across edits of that document.
        """
        return source_location_from_xml_element(self.element)

    def get_data_attributes(
        self,
    ) -> dict[
        str,
        DeserializerDataFieldType | list[DeserializerDataFieldType] | None,
    ]:
        """Return all data attributes keyed by pyDEXPI field name in schema-specific format.

        DEXPI XML may give one attribute in several sibling ``<Data>`` elements, one value each:
        bpmn2dexpi writes every ``PhysicalQuantityVector`` value in its own
        ``<Data property="Values">``. For a list field they are read as one list, in document
        order. A single-valued field holds one value, so only its last ``<Data>`` is read,
        and `get_repeated_data_attributes` names the others for the loader to report.
        """
        data_attributes = {}
        for attr_name, elements in self._extract_all_attribute_elements("Data").items():
            is_list_field = self._is_list_field(attr_name)
            read = elements if is_list_field else elements[-1:]

            # Decode data elements
            parsed_elements = [
                self._parse_attribute(data_element)
                for element in read
                for data_element in element.iterchildren(tag=etree.Element)
            ]

            # Dispatch correct return type based on is_list_field
            data_attributes[attr_name] = self._package_return_type(parsed_elements, is_list_field)
        return data_attributes

    @classmethod
    def load_from_string(cls, data: str, top_level: bool = True) -> DexpiXmlDeserializationElement:
        """Create a deserialization element from a suitable string serialization.

        Optionally and by default handles unpacking the top-level XML element from the DEXPI XML
        root that contains default metadata and import declarations.

        Parameters
        ----------
        data : str
            The string serialization to load.
        top_level : bool, optional
            Whether to unpack the top-level XML element from the DEXPI XML root. Default is True.

        Raises
        ------
        etree.XMLSyntaxError
            If the data is not well-formed XML. Unlike the Proteus loader, this is raised rather
            than registered: this runs before a loader and its error registry exist, so there would
            be nowhere for a consumer to read the entry back from.
        """
        return cls._from_root(parse_xml_string(data), top_level)

    @classmethod
    def load_from_bytes(cls, data: bytes, top_level: bool = True) -> DexpiXmlDeserializationElement:
        """Create a deserialization element from a suitable byte serialization.

        Preferred over `load_from_string` wherever the raw bytes are available, as the encoding
        the document declares is then honoured rather than assumed to be UTF-8.

        Parameters
        ----------
        data : bytes
            The byte serialization to load.
        top_level : bool, optional
            Whether to unpack the top-level XML element from the DEXPI XML root. Default is True.

        Raises
        ------
        etree.XMLSyntaxError
            If the data is not well-formed XML. See `load_from_string` for why this is raised
            rather than registered.
        """
        return cls._from_root(parse_xml_bytes(data), top_level)

    @classmethod
    def _from_root(
        cls, xml_root: etree._Element, top_level: bool
    ) -> DexpiXmlDeserializationElement:
        """Wrap a parsed document, optionally unpacking its top-level Object element."""
        if top_level:
            for child in xml_root.iterchildren(tag=etree.Element):
                if child.tag == "Object":
                    # Use first top-level Object as loader root.
                    unpacked_root = child
                    break
            else:
                raise ValueError("No Object element found in XML data")
            xml_root = unpacked_root
        return cls(xml_root)

    def _extract_attribute_elements(self, tag: str) -> dict[str, etree._Element]:
        """Extract attribute elements by DEXPI section tag.

        Parameters
        ----------
        tag : str
            XML section tag (for example `"Components"`, `"References"`, or `"Data"`).

        Returns
        -------
        dict[str, Element]
            Mapping from pyDEXPI field name (camelCase) to raw XML element: the last one, where a
            property is given more than once.
        """
        return {
            name: elements[-1]
            for name, elements in self._extract_all_attribute_elements(tag).items()
        }

    def _extract_all_attribute_elements(self, tag: str) -> dict[str, list[etree._Element]]:
        """Extract every attribute element by DEXPI section tag, in document order.

        Parameters
        ----------
        tag : str
            XML section tag (for example `"Components"`, `"References"`, or `"Data"`).

        Returns
        -------
        dict[str, list[Element]]
            Mapping from pyDEXPI field name (camelCase) to its raw XML elements.
        """
        # A field renamed off its DEXPI name (Role.Uri is the field uri_) is found by the
        # name the class records; everything else by the usual derivation. Never raises: this
        # runs before the ErrorRegistry can take anything (see _is_list_field).
        dexpi_class = getattr(pydexpi_classes, self.get_dexpi_class() or "", None)
        renamed = {dexpi: field for field, dexpi in dexpi_attribute_names(dexpi_class).items()}
        attribute_elements: dict[str, list[etree._Element]] = {}
        for comp in self.element.findall(tag):
            name = comp.get("property")
            if name:
                name = renamed.get(name) or self._pascal_to_camel_case(name)
                attribute_elements.setdefault(name, []).append(comp)
        return attribute_elements

    def get_repeated_data_attributes(self) -> dict[str, RepeatedData]:
        """Return the single-valued data attributes given in more than one ``<Data>``.

        `get_data_attributes` reads all of a list field's elements, but only the last of a
        single-valued field's, so the earlier ones are not read. Keyed by pyDEXPI field name, as
        `get_data_attributes` is.
        """
        unread = {
            name: elements[:-1]
            for name, elements in self._extract_all_attribute_elements("Data").items()
            if len(elements) > 1 and not self._is_list_field(name)
        }
        if not unread:
            return {}
        owner = next(
            (
                str(candidate.get("id"))
                for candidate in (self.element, *self.element.iterancestors("Object"))
                if candidate.tag == "Object" and candidate.get("id") is not None
            ),
            None,
        )
        return {
            name: RepeatedData(
                location=source_location_from_xml_element(elements[0]),
                object_id=owner,
                unread=[
                    str(etree.tostring(e, encoding="unicode", with_tail=False)) for e in elements
                ],
            )
            for name, elements in unread.items()
        }

    def _get_class_name_from_name_reference(self, name_reference: str) -> str:
        """Extract the class name from a DEXPI name reference string.

        Examples
        --------
        - 'http://.../module.ClassName' -> 'ClassName'
        - 'namespace/module.ClassName' -> 'ClassName'
        """
        if not name_reference:
            return ""
        if "/" in name_reference:
            _, path = name_reference.split("/", 1)
        else:
            path = name_reference
        return path.split(".")[-1]

    def _extract_reference_ids(self, objects_value: str) -> list[str]:
        """Extract object ids from a space-separated string of references.

        Examples of `objects_value`:
        - "#id1 #id2 #id3" -> ["id1", "id2", "id3"]
        """

        ids: list[str] = []
        if not objects_value:
            return ids
        for token in objects_value.split():
            if token.startswith("#"):
                ids.append(token[1:])
            else:
                ids.append(token)
        return ids

    def _parse_attribute(
        self, data_element: etree._Element
    ) -> DeserializerDataFieldType | DexpiXmlDeserializationElement:
        """Parse a Data element and return the corresponding Python/DEXPI value.

        The returned value can be a primitive (str, int, float, bool), a datetime, or a
        `DexpiXmlDeserializationElement` instance for aggregated data or data references.
        """

        XSD_BOOLEAN_MAP = {
            "true": True,
            "1": True,
            "false": False,
            "0": False,
        }

        match data_element.tag:
            case "Boolean":
                text = (data_element.text or "").strip().lower()
                if text in XSD_BOOLEAN_MAP:
                    return XSD_BOOLEAN_MAP[text]
                raise ValueError(f"Invalid boolean value: {data_element.text!r}")
            case "DateTime":
                return self._parse_xsd_datetime(data_element.text)
            case "Double":
                return float(data_element.text)
            case "Integer":
                return int(data_element.text)
            case "String":
                if data_element.text is not None:
                    return data_element.text
                else:
                    return ""
            case "DataReference":
                name_reference = data_element.get("data")
                return self._unpack_data_reference(name_reference)
            case "AggregatedDataValue":
                return DexpiXmlDeserializationElement(data_element)

            case "Undefined":
                return DexpiXmlDeserializationElement(data_element)

    def _unpack_data_reference(self, name_reference: str) -> Enum:
        """Resolve a DEXPI XML data reference to an enum value.

        Parameters
        ----------
        name_reference : str
            Reference string from a `DataReference` element.

        Returns
        -------
        Enum
            Resolved enum member.

        Raises
        ------
        ValueError
            If the enum member name is invalid.
        NotImplementedError
            If the reference does not point to an enum type.
        """
        if not name_reference or "/" not in name_reference:
            raise ValueError(f"Invalid data reference: {name_reference!r}")
        _, path = name_reference.split("/", 1)
        parts = path.split(".")

        pydexpi_class: type[PyDexpiBaseModel] | None = (
            getattr(pydexpi_classes, parts[-2], None) if len(parts) >= 2 else None
        )
        if pydexpi_class and issubclass(pydexpi_class, Enum):
            enum_value = parts[-1].upper()
            try:
                return getattr(pydexpi_class, enum_value)
            except AttributeError as exc:
                raise ValueError(f"Invalid enum value: {enum_value}") from exc
        else:
            raise NotImplementedError("Only Enum data references are currently supported")

    def _parse_xsd_datetime(self, value: str) -> datetime:
        """Parse an XSD dateTime string into a Python datetime object."""
        value = value.strip()
        # datetime.fromisoformat does not support "Z" for UTC, so normalize to +00:00.
        if value.endswith("Z"):
            value = value[:-1] + "+00:00"
        return datetime.fromisoformat(value)

    def _pascal_to_camel_case(self, name: str) -> str:
        """Convert a DEXPI attribute name to its pyDEXPI field name.

        Lowercases the first character of every underscore-separated segment, matching how the
        generated classes are named: `ChEBI_Identifier` -> `chEBI_identifier` and
        `IUPAC_Identifier` -> `iUPAC_identifier`. A name with no underscore is a single segment,
        so it is simply lowercased on its first character as before: `Identifier` ->
        `identifier`.
        """
        if not name:
            return name
        return "_".join(
            segment[0].lower() + segment[1:] if segment else segment for segment in name.split("_")
        )

    def _package_return_type(self, value: list[T], is_list_field: bool) -> T | list[T]:
        """Package the return value based on whether the field is a list field or not."""
        if is_list_field:
            return value
        elif len(value) == 1:
            return value[0]
        else:
            raise ValueError(
                f"Expected a single value for non-list field, but got {len(value)} values."
            )

    def _is_list_field(self, field_name: str) -> bool:
        """Check if the specified field in the model class is a list field.

        This is necessary for empty attributes, as this information cannot be inferred otherwise.

        An unknown class or an unknown field is treated as a list. This method runs while the
        loader is still building its element tree, i.e. before `TreeReferenceLoader` gets a chance
        to report the problem through the `ErrorRegistry`, so raising here would abort the whole
        document over a single typo. `True` is the safe default: `_package_return_type` rejects a
        non-list field carrying several values, and the loader discards the unknown field anyway
        after logging it.
        """
        # `getattr` also resolves the enums and other non-model symbols the package exports --
        # `AreaUnit`, `FillStyle` and friends -- and those have no `model_fields`. A document
        # naming one as an Object type would otherwise raise `AttributeError` here, which is
        # exactly the abort this probe exists to avoid: it runs before the ErrorRegistry is
        # reachable. Anything that is not a pydantic model counts as unknown.
        model_cls = getattr(pydexpi_classes, self.get_dexpi_class(), None)
        if not isinstance(model_cls, type) or not hasattr(model_cls, "model_fields"):
            return True
        if field_name not in model_cls.model_fields:
            return True
        field = model_cls.model_fields[field_name]
        annotation = field.annotation

        origin = get_origin(annotation)
        if origin is list:
            return True

        if isinstance(annotation, ForwardRef):
            annotation = annotation.__forward_arg__

        if isinstance(annotation, str):
            cleaned = annotation.replace(" ", "")
            return cleaned.startswith(("list[", "typing.List["))

        return False


class DexpiXmlSerializationElement:
    """Class representing a serialization element for the DEXPI XML serializer."""

    def __init__(self, metadata: DexpiXmlModelMetadata, indent: int = 2):
        """Initialize a new DEXPI XML serialization element."""
        self.element = etree.Element("Object")
        self.metadata = metadata
        self.indent = indent
        self.class_path = None
        # This object's class, whose renamed fields keep their DEXPI names.
        self.dexpi_class: type | None = None

    def set_id(self, id: str | None) -> None:
        """Set the unique identifier of the element.

        Note that carriage returns are *not* rejected here. An id is written as an XML
        attribute, and ``lxml`` escapes CR in attribute values, so ``id="a\\rb"``
        round-trips unchanged.

        Raises
        ------
        ValueError
            If *id* contains a control character XML 1.0 cannot represent.
        """
        if id is not None:
            _reject_unrepresentable_characters(id, "the object id")
            self.element.set("id", id)

    def set_dexpi_class(
        self,
        base_class: Literal["PyDexpiBaseModel", "PyDexpiDataTypeBaseModel", "Undefined"],
        class_name: str,
        class_uri: str,
    ) -> None:
        """Set XML type metadata and tag based on class metadata."""
        if base_class != "Undefined":
            class_path = self._create_dexpi_xml_type(class_name)
            self.element.set("type", class_path)
        self.dexpi_class = getattr(pydexpi_classes, class_name, None)

        # Assign tag from class category
        if base_class == "Undefined":
            self.element.tag = "Undefined"
        elif base_class == "PyDexpiDataTypeBaseModel":
            self.element.tag = "AggregatedDataValue"
        else:
            self.element.tag = "Object"

    def set_comp_attributes(
        self,
        attributes: dict[
            str,
            DexpiXmlSerializationElement | list[DexpiXmlSerializationElement] | None,
        ],
    ) -> None:
        """Set composition attributes in bulk."""
        for attr_name, value in attributes.items():
            # If there is no value to set, skip creating the xml element altogether
            if value is None or (isinstance(value, list) and len(value) == 0):
                continue

            # Make a new `Components` element for the composition attribute
            components_element = etree.Element("Components")
            components_element.set("property", self._dexpi_attribute_name(attr_name))

            if isinstance(value, list):
                for item in value:
                    components_element.append(item.get_element())
            else:
                components_element.append(value.get_element())
            self.element.append(components_element)

    def set_reference_pointers(
        self,
        attributes: dict[str, str | list[str] | None],
    ) -> None:
        """Set reference-pointer attributes in bulk."""
        for attribute_name, reference_attrs in attributes.items():
            # No need to create a References element if there are no references to set
            if reference_attrs is None or (
                isinstance(reference_attrs, list) and len(reference_attrs) == 0
            ):
                continue

            # Make a new `References` element for the reference attribute
            references_element = etree.Element("References")

            # Populate with reference attributes (object ids). These are ids of *other*
            # objects, which in a whole-model export are each validated by their own
            # set_id -- but a subtree export can reference an object outside the
            # subtree, whose set_id never ran.
            reference_list = (
                reference_attrs if isinstance(reference_attrs, list) else [reference_attrs]
            )
            for reference in reference_list:
                _reject_unrepresentable_characters(
                    reference, f"a reference in attribute {attribute_name!r}"
                )
            references_element.set("objects", " ".join(f"#{ref}" for ref in reference_list))

            # Set property name in pascal case (After objects to preserve alphabetical order)
            references_element.set("property", self._dexpi_attribute_name(attribute_name))

            self.element.append(references_element)

    def set_data_attributes(
        self,
        attributes: dict[
            str,
            DexpiXmlSerializationElement
            | list[DexpiXmlSerializationElement]
            | SerializerDataFieldType
            | list[SerializerDataFieldType]
            | None,
        ],
    ) -> None:
        """Set data attributes in bulk."""
        for attribute_name, attribute_value in attributes.items():
            if attribute_value is None or (
                isinstance(attribute_value, list) and len(attribute_value) == 0
            ):
                continue

            # Make a new `Data` element for the data attribute
            data_element = etree.Element("Data")

            # Populate with data attribute value(s)
            if isinstance(attribute_value, list):
                for value in attribute_value:
                    data_element.append(self._serialize_data_value(value, attribute_name))
            else:
                data_element.append(self._serialize_data_value(attribute_value, attribute_name))

            # Set property name in pascal case (After objects to preserve alphabetical order)
            data_element.set("property", self._dexpi_attribute_name(attribute_name))

            self.element.append(data_element)

    def export_to_string(self, top_level: bool = True) -> str:
        """Get a string representation of the XML element for serialization purposes.

        Optionally and by default wraps the element in a top-level `Model` element with metadata
        and import declarations for DEXPI XML serialization.

        Parameters
        ----------
        top_level : bool, optional
            Whether to wrap the element in a top-level `Model` element with metadata and import
            declarations. Default is True.

        Returns
        -------
        str
            The string representation of the XML element, optionally wrapped in a top-level `Model`
            element with metadata and import declarations."""
        if top_level:
            # Initialize root element. The metadata is supplied by the caller, so it
            # gets the same guard as model data -- a bad character here corrupts the
            # root element of every exported document while the model is blameless,
            # which is the hardest version of this failure to diagnose.
            root_xml = etree.Element("Model")
            _reject_unrepresentable_characters(self.metadata.name, "the model metadata name")
            _reject_unrepresentable_characters(self.metadata.uri, "the model metadata uri")
            root_xml.set("name", self.metadata.name)
            root_xml.set("uri", self.metadata.uri)

            # Add import elements
            for imp in self.metadata.imports:
                # Prefix first, so the source message can safely interpolate it.
                _reject_unrepresentable_characters(imp.prefix, "an import prefix")
                _reject_unrepresentable_characters(
                    imp.source, f"the source of import {imp.prefix!r}"
                )
                import_element = etree.Element(
                    "Import",
                    {"prefix": imp.prefix, "source": imp.source},
                )
                root_xml.append(import_element)

            # Add the serialized model element as a child of the root element
            root_xml.append(self.element)
            _apply_schema_safe_ids(root_xml)
            element_to_write = root_xml
            # The generator comment belongs to the document, not to the element, so a
            # fragment does not get one. It is sanitized by `build_generator_comment`.
            prologue = build_generator_comment()
        else:
            element_to_write = self.element
            prologue = ""

        etree.indent(element_to_write, space=" " * self.indent)
        return prologue + etree.tostring(element_to_write, encoding="unicode")

    def get_element(self) -> etree._Element:
        """Get the underlying XML element.

        Returns
        -------
        etree._Element
            The XML element associated with this serialization element.
        """
        return self.element

    def _dexpi_attribute_name(self, field_name: str) -> str:
        """The DEXPI name a field is written under: the recorded one, or the derived one.

        ``base_model_utils.dexpi_attribute_name`` is the one copy of the rule; a label template
        should store the same name.
        """
        return dexpi_attribute_name(self.dexpi_class, field_name)

    def _describe_data_value(self, attribute_name: str | None) -> str:
        """Return a human-readable locator for a data value, for error messages.

        Nested data types have no id of their own -- a bad ``MultiLanguageString`` leaf
        reports as ``attribute 'value' of a Core/DataTypes.SingleLanguageString value``
        rather than naming the object that owns the description. The owning id is not
        reachable from the nested element, and threading a parent pointer through the
        ``SerializationElement`` protocol to improve one message is not worth the churn.
        """
        attribute = f"attribute {attribute_name!r}" if attribute_name else "a data attribute"
        object_id = self.element.get("id")
        if object_id is not None:
            return f"{attribute} of object {object_id!r}"
        class_path = self.element.get("type")
        if class_path is not None:
            return f"{attribute} of a {class_path} value"
        return attribute

    def _create_dexpi_xml_type(self, class_name: str) -> str:
        """Create a DEXPI XML type name from a class name."""
        class_path = get_dexpi_package_mapping()[class_name]
        for imp in self.metadata.imports:
            if class_path.startswith(imp.package):
                class_path = class_path.replace(imp.package + ".", imp.prefix + "/", 1)
                break
        return class_path

    def _serialize_data_value(
        self,
        value: DexpiXmlSerializationElement | SerializerDataFieldType,
        attribute_name: str | None = None,
    ) -> etree._Element:
        """Serialize a data value to an XML element based on its type.

        Parameters
        ----------
        value : DexpiXmlSerializationElement or SerializerDataFieldType
            The value to serialize.
        attribute_name : str, optional
            The name of the data attribute *value* belongs to, used only to locate the
            offending value in an error message.

        Raises
        ------
        ValueError
            If *value* is a string containing a control character XML 1.0 cannot
            represent. Only strings are checked: the other value types stringify to
            digits and ASCII letters, or to class and enum names taken from generated
            definitions rather than from user data.
        """

        if isinstance(value, bool):
            el = etree.Element("Boolean")
            el.text = "true" if value else "false"
            return el

        if isinstance(value, int):
            el = etree.Element("Integer")
            el.text = str(value)
            return el

        if isinstance(value, float):
            el = etree.Element("Double")
            el.text = _xsd_double(value)
            return el

        if isinstance(value, datetime):
            el = etree.Element("DateTime")
            el.text = value.isoformat()
            return el

        if isinstance(value, Enum):
            el = etree.Element("DataReference")
            enum_path = self._create_dexpi_xml_type(value.__class__.__name__) + "." + value.value
            el.set("data", enum_path)
            return el

        if isinstance(value, str):
            _reject_unrepresentable_characters(value, self._describe_data_value(attribute_name))
            el = etree.Element("String")
            el.text = value
            return el

        if isinstance(value, DexpiXmlSerializationElement):
            return value.get_element()


#: The ids the DEXPI XML schema accepts: ``id-pattern`` in ``data/DEXPI_XML_Schema.xsd``,
#: an XML-name-like production with no hyphen.
_SCHEMA_ID = re.compile(r"[A-Za-z_][A-Za-z_0-9]*\Z")


def schema_safe_ids(ids: Iterable[str]) -> dict[str, str]:
    """Map each id onto one the DEXPI XML schema accepts.

    A Proteus file names its objects ``<ClassName>-<n>``, and the parser keeps those ids
    for traceability -- but the schema's ``id-pattern`` is ``[A-Za-z_][A-Za-z_0-9]*``, so
    every exported document from a Proteus-sourced model was invalid. The constraint belongs
    to this serialization format, not to the model, which is why the rewrite happens here and
    the model keeps its own ids.

    An id the schema already accepts is returned unchanged, so documents that were valid are
    written byte for byte as before. Otherwise each illegal character becomes ``_`` --
    ``Tank-1`` becomes ``Tank_1``, which is still recognisably the upstream id -- and an id
    that would not start legally is prefixed ``id_``. Collisions, including with an id that
    was already legal, take a numeric suffix. The result is deterministic: the same document
    always exports the same way.

    Parameters
    ----------
    ids : Iterable[str]
        Every id in the document, in document order.

    Returns
    -------
    dict[str, str]
        Original id -> exported id, for every id given.
    """
    originals = list(dict.fromkeys(ids))
    taken = {original for original in originals if _SCHEMA_ID.match(original)}
    mapping: dict[str, str] = {}
    for original in originals:
        if _SCHEMA_ID.match(original):
            mapping[original] = original
            continue
        mapping[original] = schema_safe_id(original, taken)
    return mapping


def schema_safe_id(candidate: str, taken: set[str]) -> str:
    """An id the DEXPI XML schema accepts, derived from *candidate* and not in *taken*.

    The one rule for deriving an id, shared by the export mapping (`schema_safe_ids`) and by the
    DEXPI 2.0 conversion's copies (`pydexpi.loaders.compat`): each illegal character becomes
    ``_``, an id that would not start legally is prefixed ``id_``, and a clash with *taken* takes
    a numeric suffix (``_2``, ``_3``, ...). Deterministic for the same inputs.

    Parameters
    ----------
    candidate : str
        The id wanted.
    taken : set[str]
        The ids that may not be used. The returned id is added to it, so successive calls cannot
        return the same id twice.

    Returns
    -------
    str
        The id.
    """
    safe = re.sub(r"[^A-Za-z_0-9]", "_", candidate)
    if not _SCHEMA_ID.match(safe):
        safe = f"id_{safe}"
    base, suffix = safe, 2
    while safe in taken:
        safe = f"{base}_{suffix}"
        suffix += 1
    taken.add(safe)
    return safe


def _apply_schema_safe_ids(root: etree._Element) -> None:
    """Rewrite every id in the document, and every reference to one, in step.

    References are the ``#id`` tokens of an ``objects`` attribute. A token without ``#`` is a
    name reference, which the schema patterns treat separately and which names no id, so it is
    left alone. Applied to the whole document, where every referenced object is present -- a
    fragment could hold a reference to an id it does not contain, which nothing here could
    rewrite consistently.
    """
    mapping = schema_safe_ids(
        element.get("id") for element in root.iter() if element.get("id") is not None
    )
    if all(original == exported for original, exported in mapping.items()):
        return
    for element in root.iter():
        element_id = element.get("id")
        if element_id is not None and mapping[element_id] != element_id:
            element.set("id", mapping[element_id])
        references = element.get("objects")
        if references is not None:
            element.set(
                "objects",
                " ".join(
                    f"#{mapping.get(token[1:], token[1:])}" if token.startswith("#") else token
                    for token in references.split()
                ),
            )


class DexpiXmlSerializer(
    AbstractTreeReferenceSerializer[DexpiXmlDeserializationElement, DexpiXmlSerializationElement]
):
    """Serializer for the DEXPI XML tree-reference format.

    Carriage returns in string data attributes are written as ``&#13;`` and survive
    the round trip unchanged. The remaining C0 control characters -- everything below
    ``U+0020`` except tab, line feed and carriage return -- have no representation in
    XML 1.0, as a literal or as a character reference, so export raises ``ValueError``
    naming the attribute and the offending code point rather than writing a file that
    cannot be read back. ``JsonSerializer`` has no such restriction.
    """

    def __init__(
        self,
        id_canonicalization: bool = False,
        export_metadata: DexpiXmlModelMetadata | None = None,
        indent: int = 2,
        strict: bool = True,
    ) -> None:
        """Initialize a new XML serializer.

        Parameters
        ----------
        id_canonicalization : bool, optional
            Whether to perform ID canonicalization for reference attributes during serialization.
            If True, list attributes will be sorted by ID. Default is False.
        export_metadata : DexpiXmlModelMetadata | None, optional
            Metadata for the DEXPI XML model document. If not provided, default metadata
            with Core, Plant, and Process imports will be used.
        indent : int, optional
            Number of spaces to use for indentation in the output XML. Default is 2.
        strict : bool, optional
            Whether an object omitting a mandatory DEXPI attribute is discarded on load. Pass
            False to load such objects anyway, recording each omission as an error - needed for
            real process files, which routinely omit the mandatory `Identifier`. See
            `TreeReferenceLoader.__init__`. Default is True.
        """
        super().__init__(id_canonicalization=id_canonicalization, strict=strict)
        self.metadata = export_metadata or DexpiXmlModelMetadata()
        self.indent = indent

    @property
    def file_extension(self) -> str:
        """Return file extension for XML serialization."""
        return ".xml"

    def get_loader_element_type(self) -> type[DexpiXmlDeserializationElement]:
        """Return DexpiXmlDeserializationElement as deserialization element used by this loader."""
        return DexpiXmlDeserializationElement

    def prepare_document(
        self, element: DexpiXmlDeserializationElement, error_registry: ErrorRegistry
    ) -> DexpiXmlDeserializationElement | None:
        """Read a DEXPI 2.0 document as DEXPI 2.0.1, on its parsed tree, before it is built.

        The version is the one the document's ``<Import>`` URIs declare; see
        `pydexpi.loaders.compat.dexpi_2_0_to_2_0_1` for what is converted and how each step is
        reported. A 2.0.1 document is built as parsed.

        Returns
        -------
        DexpiXmlDeserializationElement | None
            *element*, converted in place; or None when the loader is strict and the document
            holds something 2.0.1 cannot represent without copying or dropping it.
        """
        # Imported here: the conversion module reads XML through this module's element type, so
        # importing it at the top would be circular.
        from pydexpi.loaders.compat.dexpi_2_0_to_2_0_1 import upgrade_xml_document

        converted = upgrade_xml_document(
            element.element, strict=self.loader.strict, registry=error_registry
        )
        return element if converted else None

    def serializer_element_factory(self) -> DexpiXmlSerializationElement:
        """Instantiate a new DexpiXmlSerializationElement with metadata for serialization."""
        return DexpiXmlSerializationElement(metadata=self.metadata, indent=self.indent)

    @classmethod
    def validate_xml_schema(cls, xml_path: Path, xsd_path: Path) -> None:
        """Validate the XML file against the DEXPI XML Schema.

        Parameters
        ----------
        xml_path : Path
            Path to the XML file to validate.
        xsd_path : Path
            Path to the XSD file to validate against.

        Raises
        ------
        etree.DocumentInvalid
            If the XML file does not conform to the DEXPI XML Schema.
        """
        # The document being validated is untrusted input and gets the hardened parser; the schema
        # is content shipped with pyDEXPI and is read by the loader that its internal DTD needs.
        schema = load_xml_schema(xsd_path)
        schema.assertValid(parse_xml_file(xml_path))
