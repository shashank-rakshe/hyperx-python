"""Use tree reference loading and saving for direct serialization format conversion.

This utility uses the `SerializationElement` and `DeserializationElement` interfaces to transform
pyDEXPI tree-reference-backed formats without direct parsing to pyDEXPI models.

This can accelerate the conversion and bypasses pyDEXPI validation."""

from collections.abc import Callable
from datetime import datetime
from enum import Enum

from pydexpi.loaders.tree_ref_base.element_utils import call_on_list_or_object_or_none
from pydexpi.loaders.tree_ref_base.exporter import (
    DataTypeSerializationElement,
    SerializationElement,
    SerializerDataFieldType,
)
from pydexpi.loaders.tree_ref_base.loader import (
    DataTypeDeserializationElement,
    DeserializationElement,
    reports_structure,
)
from pydexpi.pydexpi_classes import pydexpi_classes

# Narrower than the alias of the same name in `loader.py`: the converter never sees composed
# `PyDexpiBaseModel`/`Undefined` instances, only deserialization elements and primitives.
type DeserializerDataFieldType = (
    DataTypeDeserializationElement | Enum | str | int | float | bool | datetime
)


class FormatConverter[
    OutputSerializationElement: SerializationElement,
    OutputDataTypeSerializationElement: DataTypeSerializationElement,
]:
    """Convert between tree-reference-backed serialization formats directly.

    This utility uses the `SerializationElement` and `DeserializationElement` interfaces to
    transform pyDEXPI tree-reference-backed formats without direct parsing to pyDEXPI models.

    Attribute order is preserved as found in the source. Unlike `TreeReferenceExporter`, this
    converter has no `id_canonicalization` option and never sorts list-valued attributes, so
    output ordering follows the input rather than a canonical form.

    Since the conversion bypasses pyDEXPI models, it also bypasses pydantic validation and the
    loader's `ErrorRegistry`. A DEXPI class name that is unknown to pyDEXPI raises an
    `AttributeError` and aborts the conversion instead of being logged and skipped. So does a
    source element that left part of its structure out (`StructureReportingElement`): the
    loader would register that part with its content, and here there is no registry to hold
    it, so converting on would drop it without a word. It raises a `ValueError` naming the
    part.

    Attributes
    ----------
    serialization_element_factory : Callable[[], OutputSerializationElement]
        Factory function to create new instances of the target serialization element type.
    dt_serialization_element_factory : Callable[[], OutputDataTypeSerializationElement]
        Factory function to create new instances of the target data type serialization element type.
    """

    def __init__(
        self,
        serialization_element_factory: Callable[[], OutputSerializationElement],
        dt_serialization_element_factory: Callable[[], OutputDataTypeSerializationElement]
        | None = None,
    ) -> None:
        """Initialize the format converter with the given serialization element factories.

        Parameters
        ----------
        serialization_element_factory : Callable[[], OutputSerializationElement]
            Factory function to create new instances of the target serialization element type.
        dt_serialization_element_factory : Callable[[], OutputDataTypeSerializationElement], optional
            Factory function to create new instances of the target data type serialization element type.
            If not provided, the `serialization_element_factory` will be used for data type elements as well.
        """
        self.serialization_element_factory = serialization_element_factory
        self.dt_serialization_element_factory = (
            dt_serialization_element_factory
            if dt_serialization_element_factory is not None
            else serialization_element_factory
        )

    def convert_deser_to_ser(
        self, deser_element: DeserializationElement
    ) -> OutputSerializationElement:
        """Convert a deserialization element to a serialization element.

        The concrete serialization element type produced is determined by the
        `serialization_element_factory` provided during initialization.

        Parameters
        ----------
        deser_element : DeserializationElement
            The deserialization element to convert.

        Returns
        -------
        OutputSerializationElement
            The converted serialization element.
        """
        self._refuse_unread_structure(deser_element)
        new_ser_element = self.serialization_element_factory()

        # Set ID
        new_ser_element.set_id(deser_element.get_id())

        # Set dexpi class
        dexpi_class_name = deser_element.get_dexpi_class()

        base_class, uri = self._base_class_and_uri(dexpi_class_name, deser_element)
        new_ser_element.set_dexpi_class(base_class, dexpi_class_name, uri)

        # Set compositional attributes
        ser_comp_attrs = {}
        deser_comp_attrs = deser_element.get_composition_attributes()
        for attr_name, attr_value in deser_comp_attrs.items():
            ser_comp_attrs[attr_name] = call_on_list_or_object_or_none(
                self.convert_deser_to_ser, attr_value
            )

        new_ser_element.set_comp_attributes(ser_comp_attrs)

        # Set reference attributes (directly, since they are just ID references)
        new_ser_element.set_reference_pointers(dict(deser_element.get_reference_attributes()))

        # Set data attributes
        ser_data_attrs = {}
        deser_data_attrs = deser_element.get_data_attributes()
        for attr_name, attr_value in deser_data_attrs.items():
            ser_data_attrs[attr_name] = call_on_list_or_object_or_none(
                self.dt_deser_element_to_dt_ser_element, attr_value
            )
        new_ser_element.set_data_attributes(ser_data_attrs)

        return new_ser_element

    def dt_deser_element_to_dt_ser_element(
        self, dt_deser_element: DataTypeDeserializationElement | DeserializerDataFieldType
    ) -> OutputDataTypeSerializationElement | SerializerDataFieldType:
        """Convert a data type deserialization element to a data type serialization element.

        The concrete serialization element type produced is determined by the
        `dt_serialization_element_factory` provided during initialization.

        Parameters
        ----------
        dt_deser_element : DataTypeDeserializationElement | DeserializerDataFieldType
            The data type deserialization element to convert.

        Returns
        -------
        OutputDataTypeSerializationElement | SerializerDataFieldType
            The converted data type serialization element.
        """
        if isinstance(dt_deser_element, DataTypeDeserializationElement):
            self._refuse_unread_structure(dt_deser_element)
            new_dt_ser_element = self.dt_serialization_element_factory()

            # Set dexpi class
            dexpi_class_name = dt_deser_element.get_dexpi_class()
            base_class, uri = self._base_class_and_uri(dexpi_class_name, dt_deser_element)
            new_dt_ser_element.set_dexpi_class(base_class, dexpi_class_name, uri)

            # Set data attributes
            ser_data_attrs = {}
            deser_data_attrs = dt_deser_element.get_data_attributes()
            for attr_name, attr_value in deser_data_attrs.items():
                ser_data_attrs[attr_name] = call_on_list_or_object_or_none(
                    self.dt_deser_element_to_dt_ser_element, attr_value
                )
            new_dt_ser_element.set_data_attributes(ser_data_attrs)
            return new_dt_ser_element

        else:
            return dt_deser_element  # For primitive types, return as is

    @staticmethod
    def _refuse_unread_structure(element: object) -> None:
        """Raise for a source element that left part of its structure out.

        Raises
        ------
        ValueError
            Naming the first such part and where it is. The validated route reads the same
            document, builds what it can and registers the part with its content.
        """
        if not reports_structure(type(element)):
            return
        unread = element.get_unread_structure()
        if unread:
            first = unread[0]
            more = f", and {len(unread) - 1} more such part(s)" if len(unread) > 1 else ""
            raise ValueError(
                f"The object at {first.location.xpath} {first.what}{more}. Direct conversion "
                f"builds no model and has no error registry to report it in."
            )

    @staticmethod
    def _base_class_and_uri(class_name: str, element: object = None) -> tuple[str, str]:
        """Transforms a dexpi class name to its base class and URI.

        *element* is the source element the name was read from. One that names no class at
        all, and can say why, has its reason in the error in place of an empty name.
        """
        dexpi_class = getattr(pydexpi_classes, class_name, None) if class_name else None
        if dexpi_class is None:
            problem = element.get_class_problem() if reports_structure(type(element)) else None
            if not class_name and problem:
                raise AttributeError(f"An object names no DEXPI class: {problem}.")
            raise AttributeError(f"Class '{class_name}' not found in pydexpi_classes.")
        uri = dexpi_class.uri
        if issubclass(dexpi_class, pydexpi_classes.Undefined):
            base_class = "Undefined"
        elif issubclass(dexpi_class, pydexpi_classes.PyDexpiDataTypeBaseModel):
            base_class = "PyDexpiDataTypeBaseModel"
        else:
            base_class = "PyDexpiBaseModel"

        return base_class, uri
