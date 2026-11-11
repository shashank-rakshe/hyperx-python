"""Provides an exporter for tree-reference-backed serialization of pyDEXPI models.

Such formats implement the `SerializationElement` interface to provide schema-specific serialization
logic, and can be used with the exporter directly to generate pyDEXPI models."""

from collections.abc import Callable
from datetime import datetime
from enum import Enum
from typing import Any, Literal, Protocol, Self, runtime_checkable

import pydexpi.toolkits.base_model_utils as bmu
from pydexpi.loaders.tree_ref_base.element_utils import call_on_list_or_object_or_none
from pydexpi.pydexpi_classes.pydexpi_classes import (
    PyDexpiBaseModel,
    PyDexpiDataTypeBaseModel,
    Undefined,
)
from pydexpi.toolkits.list_order import is_ordered

type PyDexpiDataFieldType = (
    PyDexpiBaseModel | Undefined | Enum | str | int | float | bool | datetime
)
type SerializerDataFieldType = (
    DataTypeSerializationElement | Enum | str | int | float | bool | datetime
)


@runtime_checkable
class SerializationElement(Protocol):
    """Protocol for format-specific serializer output nodes.

    Implementations receive normalized pyDEXPI data from `TreeReferenceExporter` and translate it
    into a concrete target representation (for example XML/JSON objects).
    """

    def set_id(self, id: str | None) -> None:
        """Set the unique identifier of the element. Can be None if PyDexpiDataTypeBaseModel or Undefined."""
        ...

    def set_dexpi_class(
        self,
        base_class: Literal["PyDexpiBaseModel", "PyDexpiDataTypeBaseModel", "Undefined"],
        class_name: str,
        class_uri: str,
    ) -> None:
        """Set class name/metadata of the element."""
        ...

    def set_comp_attributes(
        self,
        attributes: dict[str, Self | list[Self] | None],
    ) -> None:
        """Set the compositional attributes of the element."""
        ...

    def set_reference_pointers(
        self,
        attributes: dict[str, str | list[str] | None],
    ) -> None:
        """Set the id pointers to reference objects of the element."""
        ...

    def set_data_attributes(
        self,
        attributes: dict[
            str,
            SerializerDataFieldType | list[SerializerDataFieldType] | None,
        ],
    ) -> None:
        """Set data attributes keyed by pyDEXPI field name.

        Nested pyDEXPI data-type objects and `Undefined` are converted to
        `DataTypeSerializationElement` instances, while primitive values are passed through
        unchanged.
        """
        ...

    def export_to_string(self) -> str:
        """Convert the element to a suitable string serialization."""
        ...


@runtime_checkable
class DataTypeSerializationElement(Protocol):
    """Interface for serialization elements that correspond to pyDEXPI data types or undefined.

    Is implemented by default by the main SerializationElement, but can be implemented separately
    if more customization is needed.
    """

    def set_dexpi_class(
        self,
        base_class: Literal["PyDexpiBaseModel", "PyDexpiDataTypeBaseModel", "Undefined"],
        class_name: str,
        class_uri: str,
    ) -> None:
        """Set class name/metadata of the data-type element."""
        ...

    def set_data_attributes(
        self,
        attributes: dict[
            str,
            SerializerDataFieldType | list[SerializerDataFieldType] | None,
        ],
    ) -> None:
        """Set data attributes for a pyDEXPI data-type serialization node."""
        ...


class TreeReferenceExporter[SerializationElementType: SerializationElement[Any]]:
    """Implements tree-reference writing strategy for pyDEXPI graph-like serialization formats.

    Parses information from pyDEXPI objects and informs the SerializationElement with the parsed
    information. The format-specific writing logic is delegated to the SerializationElement
    interface.

    Attributes
    ----------
    id_canonicalization : bool
        Whether to write a canonical form, independent of the order of the lists whose order
        carries nothing. If True, every *unordered* list is sorted -- objects and references by
        id, data values by a deterministic key of their own -- and every ordered list
        (``pydexpi.toolkits.list_order``: the ones the specification declares ordered, such as a
        vector's values or a template's component list, and a segment's flow order) is written in
        its order. ``hashing.canonical_json_*`` rely on this.
    dt_element_factory : Callable[[], SerializationElementType]
        A factory function that creates new instances of the serialization element,
        determining the format-specific writing logic for the exporter."""

    def __init__(
        self,
        id_canonicalization: bool,
        serialization_element_factory: Callable[[], SerializationElementType],
        dt_element_factory: Callable[[], DataTypeSerializationElement] | None = None,
    ) -> None:
        """Initialize the exporter with the given configuration.

        Parameters
        ----------
        id_canonicalization : bool
            Whether to write the canonical form: unordered lists sorted, ordered lists kept in
            order (see the class docstring).
        serialization_element_factory : Callable[[], SerializationElementType]
            A factory function that creates new instances of the serialization element,
            determining the format-specific writing logic for the exporter.
        dt_element_factory : Callable[[], DataTypeSerializationElement] | None, optional
            A factory function that creates new instances of the data type serialization element,
            defaults to the serialization_element_factory if not provided.
        """
        self.id_canonicalization = id_canonicalization
        self.serialization_element_factory = serialization_element_factory
        self.dt_serialization_element_factory = (
            dt_element_factory if dt_element_factory is not None else serialization_element_factory
        )

    def serialize(
        self, obj: PyDexpiBaseModel | PyDexpiDataTypeBaseModel
    ) -> SerializationElementType:
        """Serialize a pyDEXPI object into a SerializationElement.

        Retrieves information from the pyDEXPI object and packages it into a new
        SerializationElement, which is returned.

        Parameters
        ----------
        obj : PyDexpiBaseModel | PyDexpiDataTypeBaseModel
            The pyDEXPI object to serialize.

        Returns
        -------
        SerializationElementType
            The serialized representation of the object.
        """

        # Construct a new SerializationElement and inform about id and uri.
        element = self.serialization_element_factory()
        element.set_id(getattr(obj, "id", None))
        base_class = self._get_base_class(obj)
        class_name = obj.__class__.__name__
        class_uri = getattr(obj, "uri", "")
        element.set_dexpi_class(base_class, class_name, class_uri)

        # Get all attributes of the element by type
        raw_comp_attributes = bmu.get_composition_attributes(obj)
        raw_reference_attributes = bmu.get_reference_attributes(obj)
        raw_data_attributes = bmu.get_data_attributes(obj)

        # Package composition attributes. This is done recursively with dexpi_element_to_dict
        # to ensure that nested elements are also converted to dictionaries.
        comp_attributes: dict[
            str,
            SerializationElementType | list[SerializationElementType] | None,
        ] = {}
        for attr, attr_val in raw_comp_attributes.items():
            sort = self._sorts(obj, attr)
            comp_attributes[attr] = call_on_list_or_object_or_none(
                self.serialize,
                attr_val,
                sort_list=sort,
                sorting_key=self._get_id if sort else None,
            )

        element.set_comp_attributes(comp_attributes)

        # Package reference attributes. For reference attributes, we only store the IDs.
        reference_attributes: dict[str, str | list[str] | None] = {}
        for attr, attr_val in raw_reference_attributes.items():
            sort = self._sorts(obj, attr)
            reference_attributes[attr] = call_on_list_or_object_or_none(
                self._get_id,
                attr_val,
                sort_list=sort,
                sorting_key=self._get_id if sort else None,
            )

        element.set_reference_pointers(reference_attributes)

        # Package data attributes with package_data_attribute.
        data_attributes: dict[
            str,
            SerializerDataFieldType | list[SerializerDataFieldType] | None,
        ] = {}
        for attr, attr_val in raw_data_attributes.items():
            data_attributes[attr] = call_on_list_or_object_or_none(
                self._serialize_data_attribute,
                attr_val,
                sort_list=self._sorts(obj, attr),
                sorting_key=_canonical_sort_key,
            )

        element.set_data_attributes(data_attributes)

        return element

    def _sorts(self, owner: object, attribute: str) -> bool:
        """Whether *owner*'s list *attribute* is sorted: canonicalizing, and its order is free."""
        return self.id_canonicalization and not is_ordered(owner, attribute)

    def _serialize_data_attribute(
        self, data_field: PyDexpiDataFieldType
    ) -> SerializerDataFieldType:
        """Serialize one data-field value.

        Parameters
        ----------
        data_field : PyDexpiDataFieldType
            A raw data-attribute value from a pyDEXPI object.

        Returns
        -------
        SerializerDataFieldType
            Serialized representation of `data_field`. Primitive values are
            returned unchanged. pyDEXPI data-type values are recursively
            converted into serialization elements.
        """
        if isinstance(data_field, (PyDexpiDataTypeBaseModel, Undefined)):
            data_element = self.dt_serialization_element_factory()
            base_class = self._get_base_class(data_field)
            class_name = data_field.__class__.__name__
            class_uri = getattr(data_field, "uri", "")
            data_element.set_dexpi_class(base_class, class_name, class_uri)

            raw_data_attributes = bmu.get_data_attributes(data_field)

            data_attributes: dict[
                str,
                SerializerDataFieldType | list[SerializerDataFieldType] | None,
            ] = {}
            for attr, attr_val in raw_data_attributes.items():
                data_attributes[attr] = call_on_list_or_object_or_none(
                    self._serialize_data_attribute,
                    attr_val,
                    sort_list=self._sorts(data_field, attr),
                    sorting_key=_canonical_sort_key,
                )

            data_element.set_data_attributes(data_attributes)
            return data_element
        else:
            return data_field

    @staticmethod
    def _get_base_class(
        obj: PyDexpiBaseModel | PyDexpiDataTypeBaseModel | Undefined,
    ) -> Literal["PyDexpiBaseModel", "PyDexpiDataTypeBaseModel", "Undefined"]:
        """Get serialization base-class category for a pyDEXPI object.

        Parameters
        ----------
        obj : PyDexpiBaseModel | PyDexpiDataTypeBaseModel | Undefined
            Source object that is being serialized.

        Returns
        -------
        Literal["PyDexpiBaseModel", "PyDexpiDataTypeBaseModel", "Undefined"]
            Base-class category used by serialization elements.
        """
        if isinstance(obj, Undefined):
            return "Undefined"
        elif isinstance(obj, PyDexpiDataTypeBaseModel):
            return "PyDexpiDataTypeBaseModel"
        else:
            return "PyDexpiBaseModel"

    @staticmethod
    def _get_id(element: PyDexpiBaseModel) -> str:
        """Helper method to get the ID of an element."""
        return element.id


def _canonical_sort_key(element: Any) -> str:
    """A deterministic sort key for one element of an unordered data list.

    Built from the element's class and ``repr``, which for the values a data list holds --
    strings, numbers, ``None``, enum members and data types such as a ``SingleLanguageString`` --
    depends on the value alone. It replaces ``str(hash(element))``, which ordered floats by
    their hash rather than their value and data types by a hash salted per process.

    Parameters
    ----------
    element : Any
        Value to derive a string key from.

    Returns
    -------
    str
        `element.id` when present, otherwise the class name and the ``repr``.
    """
    element_id = getattr(element, "id", None)
    if isinstance(element_id, str):
        return element_id
    return f"{type(element).__name__}:{element!r}"
