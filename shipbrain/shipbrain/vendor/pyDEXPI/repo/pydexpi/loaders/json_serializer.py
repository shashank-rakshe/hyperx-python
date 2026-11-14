"""Implementation of the tree-reference loading framework for JSON serialization.

Provides `JsonSerializer` as main entry point for JSON serialization and deserialization of pyDEXPI
models."""

from __future__ import annotations

import json
import math
import typing
from datetime import datetime
from enum import StrEnum
from functools import cache
from typing import Any, Literal

import pydexpi.toolkits.base_model_utils as bmt
from pydexpi import pydexpi_classes
from pydexpi.loaders.compat.dexpi_2_0_to_2_0_1 import JSON_VERSION_KEY, upgrade_json_document
from pydexpi.loaders.error_registry import ErrorLevels, ErrorRegistry, SourceLocation
from pydexpi.loaders.source_location import describe_json_value, join_json_pointer
from pydexpi.loaders.tree_ref_base.exporter import SerializerDataFieldType
from pydexpi.loaders.tree_ref_base.loader import DeserializerDataFieldType, UnreadStructure
from pydexpi.loaders.tree_ref_base.utility_base import AbstractTreeReferenceSerializer
from pydexpi.pydexpi_classes import (
    PyDexpiBaseModel,
    PyDexpiDataTypeBaseModel,
)
from pydexpi.pydexpi_classes._spec_info import DEXPI_SPEC_VERSION
from pydexpi.toolkits.base_model_utils import (
    get_data_attributes,
)

#: How JSON may spell a number that is not finite, for `JsonSerializer`'s ``non_finite``.
NonFiniteSpelling = Literal["constants", "strings"]

#: The strings `non_finite_token` writes: what a number that is not finite is in a JSON document.
NON_FINITE_TOKENS = frozenset({"NaN", "Infinity", "-Infinity"})

#: The three blocks of a pyDEXPI JSON object, each a JSON object of attribute names.
_BLOCKS = ("composition", "reference", "data")

#: The two blocks whose values the format types: what one value is -- an object composed, the
#: id of an object referred to -- and how a message names it. An attribute holds one such
#: value, a list of them, or ``null``.
_BLOCK_VALUES: tuple[tuple[str, type, str], ...] = (
    ("composition", dict, "an object"),
    ("reference", str, "the id of an object, a string,"),
)

#: What the ``uri`` of a pyDEXPI JSON object looks like, for a message about one that is not:
#: the namespace every generated class declares, read off one of them.
_CLASS_URI_PATTERN = f"{pydexpi_classes.EngineeringModel.uri.rsplit('/', 1)[0]}/<Class>"


def non_finite_token(value: float) -> str:
    """Return the JSON string that stands for a float that is not finite.

    JSON has no number for a NaN or an infinity. ``"NaN"``, ``"Infinity"`` and ``"-Infinity"``
    are the names JavaScript gives them and the ones pydantic writes with
    ``ser_json_inf_nan="strings"``, and a ``float`` field reads each back as the number, so a
    value written this way is valid JSON and loses nothing.

    Parameters
    ----------
    value : float
        A NaN or an infinity. A finite float has no token; the caller checks first.

    Returns
    -------
    str
        ``"NaN"``, ``"Infinity"`` or ``"-Infinity"``.
    """
    if math.isnan(value):
        return "NaN"
    return "Infinity" if value > 0 else "-Infinity"


def _annotation_members(annotation: Any) -> set[Any]:
    """The types an annotation admits, at any depth of its unions and lists."""
    arguments = typing.get_args(annotation)
    if not arguments:
        return {annotation}
    return set().union(*(_annotation_members(argument) for argument in arguments))


@cache
def number_fields(dexpi_class: type) -> frozenset[str]:
    """The fields of a generated class that hold a float and never a string.

    A number that is not finite is a string in a JSON document (`non_finite_token`), and what
    says that the string is that number is the field it sits in: ``"NaN"`` is a NaN in
    ``PhysicalQuantity.value`` and three letters in ``Tank.tagName``. No generated class has a
    field that takes both, which ``tests/test_loaders/test_value_codec.py`` holds a
    regeneration to; one that did, or an untyped one, is not listed here, and its string is
    left for validation to read.

    Parameters
    ----------
    dexpi_class : type
        A generated class or data type.

    Returns
    -------
    frozenset[str]
        The names of its fields whose annotation admits a ``float``, alone or in a list or a
        union, and admits neither ``str`` nor ``Any``.
    """
    try:
        hints = typing.get_type_hints(dexpi_class)
    except (NameError, TypeError):
        return frozenset()
    found = set()
    for name in getattr(dexpi_class, "model_fields", {}):
        members = _annotation_members(hints.get(name))
        if float in members and str not in members and Any not in members:
            found.add(name)
    return frozenset(found)


def _as_written(part: Any) -> str:
    """A part of a decoded document as JSON text, for the entry that reports it.

    What `json.loads` returns is always written back. A dict handed to `dict_to_model` can
    hold anything, and reporting a part must not be what fails the load, so a value JSON has
    no form for is written as its ``repr``.
    """
    return json.dumps(part, ensure_ascii=False, default=repr)


class JsonDeserializationElement:
    """JSON implementation of the DeserializationElement protocol.

    Decoded JSON is untyped, so a document can give anything anywhere: a string where an
    object's ``composition`` block goes, a number in a list of objects, no ``uri``. What the
    loader reads while it builds its element tree -- the id, the class, the compositions and
    the references -- is read without raising over that: no tolerant path is reachable there,
    so raising took the whole document down with an exception the loader does not name. Each
    of those methods reads what is as the format expects and leaves the rest out, and
    `get_unread_structure` and `get_class_problem` name what was left out, for the loader to
    register (`StructureReportingElement`).

    `get_data_attributes` is read later, inside the ``try`` the loader puts around an object's
    data attributes, and still raises for an enumeration pyDEXPI does not have: the loader
    reports that, at the cost of every data attribute of the object.
    """

    def __init__(self, data: dict[str, Any], pointer: str = "") -> None:
        """Initialize a new JsonDeserializationElement with the given data dictionary.

        Parameters
        ----------
        data : dict[str, Any]
            The decoded JSON object this element wraps. Anything else is read as an object
            that holds nothing and names no class, and reported as such.
        pointer : str, optional
            JSON Pointer (RFC 6901) locating this element within the document it came from. The
            empty string denotes the root of the document, by default ""
        """
        self.data = data
        self.pointer = pointer

    def _block(self, name: str) -> dict[str, Any]:
        """One of the object's blocks when it is a JSON object, else an empty one."""
        block = self.data.get(name) if isinstance(self.data, dict) else None
        return block if isinstance(block, dict) else {}

    def _dexpi_type(self) -> type | None:
        """The pyDEXPI class this element's ``uri`` names, or None when it names none."""
        uri = self.data.get("uri") if isinstance(self.data, dict) else None
        if not isinstance(uri, str):
            return None
        try:
            return bmt.get_dexpi_class_from_uri(uri)
        except AttributeError:
            return None

    def get_source_location(self) -> SourceLocation:
        """Return where this element sits in the JSON document it was parsed from.

        Returns
        -------
        SourceLocation
            The DEXPI class name and the JSON Pointer of this element. Line and column are always
            None, since decoding JSON discards the positions of the values it produces.
        """
        # An element that names no class still reports its pointer.
        return SourceLocation(element=self.get_dexpi_class() or None, xpath=self.pointer or "/")

    def get_id(self) -> str | None:
        """Return the unique identifier of the element, as the document gives it.

        An id that is no string is returned as it is: validation refuses the object over it,
        naming it, as it does for any other value its class cannot hold.
        """
        return self.data.get("id") if isinstance(self.data, dict) else None

    def get_dexpi_class(self) -> str:
        """Return the name of the pyDEXPI class this element's URI names.

        Returns
        -------
        str
            The class name, or an empty string when the element names no pyDEXPI class: it has
            no ``uri``, or one that is no pyDEXPI class URI. `get_class_problem` says which.
        """
        dexpi_type = self._dexpi_type()
        return dexpi_type.__name__ if dexpi_type is not None else ""

    def get_class_problem(self) -> str | None:
        """Return why this element names no pyDEXPI class, or None when it names one.

        Phrased to follow the name of the object. ``None`` used to be looked up like a URI and
        matched the first name pyDEXPI exports that declares none, so an object without its
        class was reported as an unknown class ``AreaUnit``.
        """
        if self._dexpi_type() is not None:
            return None
        if not isinstance(self.data, dict):
            return f"it is {describe_json_value(self.data)}, where a JSON object is expected"
        expected = f'the URI of a pyDEXPI class is expected ("{_CLASS_URI_PATTERN}")'
        if "uri" not in self.data:
            return f'it has no "uri", where {expected}'
        uri = self.data["uri"]
        if isinstance(uri, str):
            return (
                f'its "uri" is {json.dumps(uri, ensure_ascii=False)}, which is not the URI of a '
                f'pyDEXPI class ("{_CLASS_URI_PATTERN}")'
            )
        return f'its "uri" is {describe_json_value(uri)}, where {expected}'

    def get_unread_structure(self) -> list[UnreadStructure]:
        """Return the parts of this object that are not what a pyDEXPI JSON object holds there.

        These are the parts the other methods leave out: a ``composition``, ``reference`` or
        ``data`` block that is no JSON object, a composed value that is no object, and a
        reference target that is no string. ``null`` stands for "nothing" in each place and
        is not reported, except inside a list, where every entry is an object or an id.

        Returns
        -------
        list[UnreadStructure]
            One entry per part, in document order, each with the part as the document gives
            it.
        """
        data = self.data
        if not isinstance(data, dict):
            kind = describe_json_value(data)
            return [self._unread(f"is {kind}, where a JSON object is expected", data)]
        unread: list[UnreadStructure] = []
        for name in _BLOCKS:
            block = data.get(name)
            if block is not None and not isinstance(block, dict):
                unread.append(
                    self._unread(
                        f'has a "{name}" block that is {describe_json_value(block)}, where a '
                        f"JSON object is expected",
                        block,
                        name,
                    )
                )
        # This runs for every object of every document, nearly always to find nothing, so
        # the loops below test and move on; a message is only put together for a part found.
        for name, expected_type, expected in _BLOCK_VALUES:
            block = data.get(name)
            if not isinstance(block, dict):
                continue
            for attribute, value in block.items():
                if value is None or isinstance(value, expected_type):
                    continue
                if not isinstance(value, list):
                    unread.append(self._unread_value(name, attribute, None, value, expected))
                    continue
                for index, item in enumerate(value):
                    if not isinstance(item, expected_type):
                        unread.append(self._unread_value(name, attribute, index, item, expected))
        return unread

    def _unread_value(
        self, block: str, attribute: str, index: int | None, value: Any, expected: str
    ) -> UnreadStructure:
        """An `UnreadStructure` for a value of *attribute* in *block* that is not *expected*."""
        which = f'its {block} "{attribute}"'
        tokens: tuple[str | int, ...] = (block, attribute)
        if index is not None:
            which = f"entry {index} of {which}"
            tokens = (*tokens, index)
        return self._unread(
            f"has {describe_json_value(value)} as {which}, where {expected} is expected",
            value,
            *tokens,
        )

    def _unread(self, what: str, part: Any, *tokens: str | int) -> UnreadStructure:
        """An `UnreadStructure` for *part*, found at *tokens* below this element."""
        return UnreadStructure(
            what=what,
            location=SourceLocation(
                element=self.get_dexpi_class() or None,
                xpath=join_json_pointer(self.pointer, *tokens) or "/",
            ),
            content=_as_written(part),
        )

    def get_composition_attributes(
        self,
    ) -> dict[str, JsonDeserializationElement | list[JsonDeserializationElement] | None]:
        """Return all compositional attributes keyed by pyDEXPI field name.

        A composed value that is no JSON object is left out: of a list, the entry; of a single
        value, the attribute. `get_unread_structure` names each.
        """
        comp_attributes: dict[
            str, JsonDeserializationElement | list[JsonDeserializationElement] | None
        ] = {}
        for attr_name, attr_val in self._block("composition").items():
            attr_pointer = join_json_pointer(self.pointer, "composition", attr_name)
            if attr_val is None:
                comp_attributes[attr_name] = None
            elif isinstance(attr_val, list):
                comp_attributes[attr_name] = [
                    JsonDeserializationElement(item, join_json_pointer(attr_pointer, index))
                    for index, item in enumerate(attr_val)
                    if isinstance(item, dict)
                ]
            elif isinstance(attr_val, dict):
                comp_attributes[attr_name] = JsonDeserializationElement(attr_val, attr_pointer)
        return comp_attributes

    def get_reference_attributes(self) -> dict[str, str | list[str] | None]:
        """Return all reference attributes keyed by pyDEXPI field name.

        A target that is no string names no object, and is left out: of a list, the entry; of
        a single reference, the attribute. `get_unread_structure` names each.
        """
        references: dict[str, str | list[str] | None] = {}
        for attr_name, attr_val in self._block("reference").items():
            if attr_val is None or isinstance(attr_val, str):
                references[attr_name] = attr_val
            elif isinstance(attr_val, list):
                references[attr_name] = [target for target in attr_val if isinstance(target, str)]
        return references

    def get_data_attributes(
        self,
    ) -> dict[str, DeserializerDataFieldType | list[DeserializerDataFieldType] | None]:
        """Return all data attributes keyed by pyDEXPI field name.

        A number that is not finite is a string in a JSON document, ``"NaN"``, ``"Infinity"``
        or ``"-Infinity"`` (`non_finite_token`), and is returned as the float it stands for
        when the field it sits in holds numbers (`number_fields`). Validation reads the string
        the same way, so a model is built alike either way; a reader that builds no model --
        ``FormatConverter``, behind ``pydexpi convert --fast`` -- has only what this returns,
        and wrote such a number to DEXPI XML as a ``<String>``.
        """
        data_attributes: dict[
            str, DeserializerDataFieldType | list[DeserializerDataFieldType] | None
        ] = {}
        for attr_name, data_val in self._block("data").items():
            attr_pointer = join_json_pointer(self.pointer, "data", attr_name)
            if data_val is None:
                data_attributes[attr_name] = None
            elif isinstance(data_val, list):
                data_attributes[attr_name] = [
                    self._unpack_data_attribute(
                        item, join_json_pointer(attr_pointer, index), attr_name
                    )
                    for index, item in enumerate(data_val)
                ]
            else:
                data_attributes[attr_name] = self._unpack_data_attribute(
                    data_val, attr_pointer, attr_name
                )
        return data_attributes

    def _unpack_data_attribute(
        self,
        raw_data_attribute: dict | str | int | float | bool | None,
        pointer: str = "",
        attribute_name: str | None = None,
    ) -> DeserializerDataFieldType | None:
        """Decode a data attribute.

        A data attribute is either a nested DeserializationElement, which corresponds to a
        pyDEXPI data type or undefined class, or a primitive DataFieldType. If it is a
        DeserializationElement, return it as a deserialization element. If it is a primitive,
        return as is -- except the token of a number that is not finite in a field
        *attribute_name* that holds numbers, which is returned as that number."""
        if isinstance(raw_data_attribute, dict) and "uri" in raw_data_attribute:
            # This is PyDexpiDataTypeBaseModel or Undefined, return as a deserialization element
            # for compositional pass
            return JsonDeserializationElement(raw_data_attribute, pointer)
        elif isinstance(raw_data_attribute, dict) and "__enum__" in raw_data_attribute:
            # This is an enum, decode it back to the enum value
            enum_class_name = raw_data_attribute["__enum__"]
            enum_value_name = raw_data_attribute["name"]
            # Enum classes are resolved from pydexpi_classes.
            enum_class = getattr(pydexpi_classes, enum_class_name)
            return enum_class[enum_value_name]
        elif (
            isinstance(raw_data_attribute, str)
            and raw_data_attribute in NON_FINITE_TOKENS
            and self._holds_numbers(attribute_name)
        ):
            return float(raw_data_attribute)
        else:
            # This is a primitive DataFieldType, return as is
            return raw_data_attribute

    def _holds_numbers(self, attribute_name: str | None) -> bool:
        """Whether *attribute_name* of this element's class holds a float and never a string."""
        dexpi_type = self._dexpi_type()
        return dexpi_type is not None and attribute_name in number_fields(dexpi_type)

    @classmethod
    def load_from_string(cls, data: str) -> JsonDeserializationElement:
        """Create a deserialization element from a suitable string serialization.

        Raises
        ------
        json.JSONDecodeError
            If the data is not JSON. Like the well-formedness error of an XML document, this is
            raised rather than registered: it is a ``ValueError``, and this runs before a
            loader and its error registry exist. A document that *is* JSON, whatever it holds,
            is read without raising.
        """
        data_dict = json.loads(data)
        return cls(data_dict)

    @classmethod
    def load_from_dict(cls, data_dict: dict[str, Any]) -> JsonDeserializationElement:
        """Create a DeserializationElement directly from a dictionary."""
        return cls(data_dict)


class JsonSerializationElement:
    """JSON implementation of the SerializationElement protocol.

    Attributes
    ----------
    data_dict : dict
        The internal dictionary representation of the element, which will be serialized to JSON.
    indent : int or None
        The number of spaces to use for indentation in the JSON output. If None, the most compact
        representation will be used. Default is 4.
    explicit : bool
        Whether to include empty fields in the output. If False, fields with None or empty list
        values will be omitted from the output. Default is False.
    declare_version : bool
        Whether a document written by `export_to_string` declares the DEXPI version of the
        classes, as a root ``"dexpiVersion"`` key. Default is True.
    non_finite : {"strings", "constants"}
        How a NaN or an infinity is written; see `JsonSerializer`. Default is "strings"."""

    def __init__(
        self,
        indent: int | None = 4,
        explicit: bool = False,
        declare_version: bool = True,
        non_finite: NonFiniteSpelling = "strings",
    ) -> None:
        """Initialize a new JsonSerializationElement with an empty data dictionary."""
        self.data_dict = {}
        self.indent = indent
        self.explicit = explicit
        self.declare_version = declare_version
        self.non_finite = non_finite

    def set_id(self, id: str | None) -> None:
        """Set the unique identifier of the element."""
        if id is not None:
            self.data_dict["id"] = id

    def set_dexpi_class(
        self,
        base_class: Literal["PyDexpiBaseModel", "PyDexpiDataTypeBaseModel", "Undefined"],
        class_name: str,
        class_uri: str,
    ) -> None:
        """Set the class name of the element, encoded in the JSON as a URI."""
        self.data_dict["uri"] = class_uri

    def set_comp_attributes(
        self,
        attributes: dict[
            str,
            JsonSerializationElement | list[JsonSerializationElement] | None,
        ],
    ) -> None:
        """Set compositional attributes of the element in bulk."""
        composition_data: dict[str, Any] = {}
        for attribute_name, attribute_value in attributes.items():
            if attribute_value is None:
                if self.explicit:
                    composition_data[attribute_name] = None
                continue
            elif isinstance(attribute_value, list):
                if len(attribute_value) == 0 and not self.explicit:
                    continue
                composition_data[attribute_name] = [attr.data_dict for attr in attribute_value]
            else:
                composition_data[attribute_name] = attribute_value.data_dict

        if composition_data or self.explicit:
            self.data_dict["composition"] = composition_data
        else:
            self.data_dict.pop("composition", None)

    def set_reference_pointers(
        self,
        attributes: dict[str, str | list[str] | None],
    ) -> None:
        """Set reference-pointer attributes in bulk."""
        reference_dict: dict[str, str | list[str] | None] = {}
        for attr_name, attr_val in attributes.items():
            if attr_val is None:
                if self.explicit:
                    reference_dict[attr_name] = None
            elif isinstance(attr_val, list):
                if len(attr_val) == 0 and not self.explicit:
                    continue
                reference_dict[attr_name] = attr_val
            else:
                reference_dict[attr_name] = attr_val

        if reference_dict or self.explicit:
            self.data_dict["reference"] = reference_dict
        else:
            self.data_dict.pop("reference", None)

    def set_data_attributes(
        self,
        attributes: dict[
            str,
            SerializerDataFieldType | list[SerializerDataFieldType] | None,
        ],
    ) -> None:
        """Set data attributes in bulk."""
        data_dict: dict[str, Any] = {}
        for attribute_name, attribute_value in attributes.items():
            if attribute_value is None:
                if self.explicit:
                    data_dict[attribute_name] = None
            elif isinstance(attribute_value, list):
                if len(attribute_value) == 0 and not self.explicit:
                    continue
                data_dict[attribute_name] = [
                    self.package_data_attribute(attr) for attr in attribute_value
                ]
            else:
                data_dict[attribute_name] = self.package_data_attribute(attribute_value)

        if data_dict or self.explicit:
            self.data_dict["data"] = data_dict
        else:
            self.data_dict.pop("data", None)

    def package_data_attribute(
        self, data_field: SerializerDataFieldType
    ) -> dict | str | int | float | bool | None:
        """Convert data field to JSON-serializable representation.

        Nested JsonSerializationElement objects are converted to dictionaries,
        enums to tagged dictionaries, datetimes to strings, and primitive values
        are passed through unchanged -- except, with ``non_finite="strings"``, a float
        that is not finite, which becomes its `non_finite_token`.
        """

        if isinstance(data_field, JsonSerializationElement):
            return data_field.data_dict
        elif isinstance(data_field, StrEnum):
            return {"__enum__": data_field.__class__.__name__, "name": data_field.name}
        elif (
            self.non_finite == "strings"
            and isinstance(data_field, float)
            and not math.isfinite(data_field)
        ):
            return non_finite_token(data_field)
        elif isinstance(data_field, (str, int, float, bool, type(None))):
            return data_field
        elif isinstance(data_field, datetime):
            return str(data_field)
        else:
            raise TypeError(f"Unsupported data type: {type(data_field)}")

    def export_to_string(self) -> str:
        """Convert the element to a JSON document.

        The document declares the DEXPI version of the classes that wrote it, as the root key
        ``"dexpiVersion"`` (`pydexpi.loaders.compat.dexpi_2_0_to_2_0_1.JSON_VERSION_KEY`), the
        JSON counterpart of a DEXPI XML document's ``<Import>`` URIs; a reader takes a document
        without it for DEXPI 2.0, which is what pyDEXPI wrote before. Only the document carries
        it: `get_dict`, which value records and `hashing.model_digest` read, does not.
        """
        document = (
            {JSON_VERSION_KEY: DEXPI_SPEC_VERSION, **self.data_dict}
            if self.declare_version
            else self.data_dict
        )
        # With "strings", the default, no float that is not finite is left to write, and one
        # that were is refused rather than written as a token no strict parser reads.
        return json.dumps(
            document,
            indent=self.indent,
            ensure_ascii=False,
            allow_nan=self.non_finite == "constants",
        )

    def get_dict(self) -> dict:
        """Return the dictionary representation of the element for JSON serialization."""
        return self.data_dict

    def _pydexpi_datatype_to_dict(self, data_type: PyDexpiDataTypeBaseModel) -> dict:
        """Convert a PyDexpiDataTypeBaseModel to a dictionary for JSON serialization."""
        data_attrs = get_data_attributes(data_type)
        data_dict = {"uri": data_type.uri}
        for attr, attr_val in data_attrs.items():
            data_dict[attr] = self.package_data_attribute(attr_val)

        return data_dict


class JsonSerializer(
    AbstractTreeReferenceSerializer[JsonDeserializationElement, JsonSerializationElement]
):
    """
    JSON implementation of the AbstractTreeReferenceSerializer for DEXPI models.

    This class provides JSON-specific implementations of the loader and serializer
    element factories, enabling serialization and deserialization of DEXPI models
    to/from JSON format.
    """

    def __init__(
        self,
        id_canonicalization: bool = False,
        indent: int | None = 4,
        explicit: bool = False,
        strict: bool = True,
        declare_version: bool = True,
        non_finite: NonFiniteSpelling = "strings",
    ) -> None:
        """Initialize a new JSON serializer.

        Parameters
        ----------
        id_canonicalization : bool, optional
            Whether to perform ID canonicalization for reference attributes during serialization.
            If True, list attributes will be sorted by ID. Default is False.
        indent : int, optional
            The number of spaces to use for indentation in the JSON output. Default is 4.
        explicit : bool, optional
            Whether to include null values in the JSON output. Default is False.
        strict : bool, optional
            Whether an object omitting a mandatory DEXPI attribute is discarded on load. Pass
            False to load such objects anyway, recording each omission as an error -- as for
            `DexpiXmlSerializer`. A process model loaded leniently and saved as JSON still omits
            the attribute, so reading it back needs False too. Default is True.
        declare_version : bool, optional
            Whether the documents written declare the DEXPI version, ``"dexpiVersion": "2.0.1"``.
            Only `pydexpi.hashing` turns it off, so that no hash depends on it. Default is True.
        non_finite : {"strings", "constants"}, optional
            How a NaN or an infinity the model holds is written. ``xsd:double``
            admits both, so a DEXPI document may hold one, and JSON has no number for either.
            "strings", the default, writes the JSON strings ``"NaN"`` / ``"Infinity"`` /
            ``"-Infinity"`` (`non_finite_token`), so everything this serializer writes is JSON a
            strict parser reads; diff values (`pydexpi.loaders.value_codec`) are
            spelled the same way. "constants" writes Python's bare ``NaN`` / ``Infinity`` /
            ``-Infinity``, which is what pyDEXPI wrote before and no JSON: a strict parser
            refuses the whole document. Either spelling is read back as the same number, by
            any `JsonSerializer`, because the field it is read into is a number: no generated
            class has a field that takes both a string and a float. `pydexpi.hashing` keeps
            its own serializers on "constants", so no digest depends on this default.

        Raises
        ------
        ValueError
            If `non_finite` is neither "constants" nor "strings".
        """
        if non_finite not in ("constants", "strings"):
            raise ValueError(f'non_finite must be "constants" or "strings", got {non_finite!r}.')
        super().__init__(id_canonicalization=id_canonicalization, strict=strict)
        self.indent = indent
        self.explicit = explicit
        self.declare_version = declare_version
        self.non_finite: NonFiniteSpelling = non_finite

    @property
    def file_extension(self) -> str:
        """Return file extension for JSON serialization."""
        return ".json"

    def get_loader_element_type(self) -> type[JsonDeserializationElement]:
        """Return the type of deserialization element used by this serializer.

        Returns
        -------
        type[JsonDeserializationElement]
            The JsonDeserializationElement class for creating deserialization elements.
        """
        return JsonDeserializationElement

    def prepare_document(
        self, element: JsonDeserializationElement, error_registry: ErrorRegistry
    ) -> JsonDeserializationElement | None:
        """Read a DEXPI 2.0 document as DEXPI 2.0.1, on its decoded dict, before it is built.

        The version is the root ``"dexpiVersion"``; a document without one is DEXPI 2.0, as is
        everything pyDEXPI wrote before it declared one. See
        `pydexpi.loaders.compat.dexpi_2_0_to_2_0_1`. `dict_to_model`, which reads a subtree
        rather than a document, is never converted.

        A document that is no JSON object -- a list, a string, ``null`` -- is refused here: it
        holds no object to build, so the load registers one CRITICAL entry carrying it and
        returns None, where it used to raise an ``AttributeError``.

        Returns
        -------
        JsonDeserializationElement | None
            *element*, converted in place; or None when the document is no JSON object, or
            when the loader is strict and the document holds something 2.0.1 cannot represent
            without copying or dropping it.
        """
        if not isinstance(element.data, dict):
            error_registry.register_error(
                f"Not loaded: the JSON document is {describe_json_value(element.data)}, where a "
                f'pyDEXPI JSON document is one JSON object: {{"uri": "{_CLASS_URI_PATTERN}", '
                f'"id": ..., "composition": {{...}}, "reference": {{...}}, "data": {{...}}}}. '
                f"What it holds is this entry's content.",
                level=ErrorLevels.CRITICAL,
                xpath="/",
                content=_as_written(element.data),
            )
            return None
        converted = upgrade_json_document(
            element.data, strict=self.loader.strict, registry=error_registry
        )
        return element if converted else None

    def serializer_element_factory(self) -> JsonSerializationElement:
        """Create and return a new JSON serialization element.

        Returns
        -------
        JsonSerializationElement
            A new instance of JsonSerializationElement.
        """
        return JsonSerializationElement(
            indent=self.indent,
            explicit=self.explicit,
            declare_version=self.declare_version,
            non_finite=self.non_finite,
        )

    def model_to_dict(self, model: PyDexpiBaseModel | PyDexpiDataTypeBaseModel) -> dict:
        """Convert a DEXPI model to a dictionary for JSON serialization.

        Accepts any pyDEXPI object, not only a whole model: a subtree, or a data
        type such as Point or PhysicalQuantity, which has a ``uri`` and ``data``
        but no ``id``. Single values are recorded this way (`pydexpi.loaders.value_codec`).

        Parameters
        ----------
        model : PyDexpiBaseModel | PyDexpiDataTypeBaseModel
            The pyDEXPI object to convert.

        Returns
        -------
        dict
            A dictionary representation of the model suitable for JSON serialization.
        """
        element = self.serializer.serialize(model)
        return element.get_dict()

    def dict_to_model(self, data_dict: dict[str, Any]) -> PyDexpiBaseModel | None:
        """Convert a dictionary representation of a DEXPI model back to a PyDexpiBaseModel instance.

        Parameters
        ----------
        data_dict : dict
            The dictionary representation of the DEXPI model, typically obtained from JSON
            deserialization.

        Returns
        -------
        PyDexpiBaseModel | None
            The reconstructed model, or `None` when critical loading errors prevent model
            construction.
        """
        element = self.get_loader_element_type().load_from_dict(data_dict)
        return self.loader.load(element)
