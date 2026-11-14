"""Abstract base class for easy implementation of a tree-reference-backed serializer.

This module defines `AbstractTreeReferenceSerializer`, which composes the `TreeReferenceLoader`
and `TreeReferenceExporter` into a concrete `Serializer` implementation with helper methods for
file, bytes, and stream IO. Subclasses provide format-specific element types and factories by
implementing `get_loader_element_type`, `serializer_element_factory`, and `file_extension`. These
factory methods specify which schema specific element types, i.e. implementations of
`DeserializationElement` and `SerializationElement`, are used for the loader and exporter
respectively.

Tree-reference loading can also be implemented from scratch with loaders and exporters without
this utility wrapper."""

from abc import abstractmethod
from pathlib import Path
from typing import IO, Any

from pydexpi.attribution import stamp_exported_model
from pydexpi.loaders.error_registry import ErrorRegistry, ErrorRegistryEntry
from pydexpi.loaders.serializer import Serializer
from pydexpi.loaders.tree_ref_base.exporter import SerializationElement, TreeReferenceExporter
from pydexpi.loaders.tree_ref_base.loader import (
    BytesLoadableDeserializationElement,
    DeserializationElement,
    TreeReferenceLoader,
)
from pydexpi.pydexpi_classes.pydexpi_classes import EngineeringModel, PyDexpiBaseModel


class AbstractTreeReferenceSerializer[
    DeserializationElementType: DeserializationElement[Any],
    SerializationElementType: SerializationElement[Any],
](Serializer):
    """Base serializer for tree-reference-backed formats.

    This class composes `TreeReferenceLoader` and `TreeReferenceExporter` into a concrete
    `Serializer` implementation with helper methods for file, bytes, and stream IO.

    Subclasses provide format-specific element types and factories by
    implementing `get_loader_element_type`, `serializer_element_factory`, and `file_extension`.

    Attributes
    ----------
    loader : TreeReferenceLoader[DeserializationElementType]
        The loader instance used for deserialization.
    serializer : TreeReferenceExporter[SerializationElementType]
        The serializer instance used for serialization.
    """

    def __init__(self, id_canonicalization: bool = False, strict: bool = True) -> None:
        """Initialize the utility parent with the given configuration.

        Parameters
        ----------
        id_canonicalization : bool, optional
            Whether to perform ID canonicalization for reference attributes during serialization.
            If True, list attributes will be sorted by ID. Default is False.
        strict : bool, optional
            Whether an object omitting a mandatory attribute is discarded on load. See
            `TreeReferenceLoader.__init__`. Default is True.
        """
        self.loader: TreeReferenceLoader[DeserializationElementType] = TreeReferenceLoader(strict)
        self.serializer: TreeReferenceExporter[SerializationElementType] = TreeReferenceExporter(
            id_canonicalization, self.serializer_element_factory
        )

    @property
    @abstractmethod
    def file_extension(self) -> str:
        """Return canonical file extension for this serializer, including leading dot."""

    def with_file_extension(self, filename: str) -> str:
        """Return a filename with serializer-specific extension appended if missing.

        Parameters
        ----------
        filename : str
            Input filename that may or may not contain the serializer extension.

        Returns
        -------
        str
            Filename ending with `self.file_extension`.
        """
        extension = self.file_extension
        if not extension.startswith("."):
            raise ValueError("file_extension must start with '.'")
        if filename.lower().endswith(extension.lower()):
            return filename
        return f"{filename}{extension}"

    @abstractmethod
    def get_loader_element_type(self) -> type[DeserializationElementType]:
        """Return the class of deserialization element used for the loader.

        Concrete implementations must provide a class that implements the
        DeserializationElement protocol for their specific format.

        Returns
        -------
        type[DeserializationElementType]
            The class for creating deserialization elements.
        """

    @abstractmethod
    def serializer_element_factory(self) -> SerializationElementType:
        """Create and return a new serialization element.

        Concrete implementations must provide an instance of SerializationElement
        specific to their format.

        Returns
        -------
        SerializationElementType
            A new instance of the serialization element.
        """

    def export_to_string(self, model: PyDexpiBaseModel) -> str:
        """Convert a pyDEXPI model to a string serialization.

        Parameters
        ----------
        model : PyDexpiBaseModel
            The pyDEXPI model to convert.

        Returns
        -------
        str
            The string serialization of the model.

        Notes
        -----
        The model is stamped with the originating system before serialization (see
        :mod:`pydexpi.attribution`). Stamping only fills fields that are unset, and
        it operates on a copy, so *model* itself is never modified. Because
        ``export_to_bytes``, ``export_to_stream`` and ``save`` all funnel through
        here, every DEXPI XML and JSON file pyDEXPI writes carries the stamp.
        """
        element = self.serializer.serialize(stamp_exported_model(model))
        return element.export_to_string()

    def export_to_bytes(self, model: PyDexpiBaseModel) -> bytes:
        """Export a pyDEXPI model to bytes.

        Parameters
        ----------
        model : PyDexpiBaseModel
            The pyDEXPI model to export.

        Returns
        -------
        bytes
            The exported model as bytes.
        """
        string_serialization = self.export_to_string(model)
        return string_serialization.encode("utf-8")

    def export_to_stream(self, model: PyDexpiBaseModel, stream: IO[bytes]) -> None:
        """Export a pyDEXPI model to a byte stream.

        Parameters
        ----------
        model : PyDexpiBaseModel
            The pyDEXPI model to export.
        stream : IO[bytes]
            The byte stream to write the exported model to.
        """
        string_serialization = self.export_to_string(model)
        stream.write(string_serialization.encode("utf-8"))

    def save(self, model: PyDexpiBaseModel, dir_path: str | Path, filename: str) -> None:
        """Save a pyDEXPI model to a file.

        Parameters
        ----------
        model : PyDexpiBaseModel
            The pyDEXPI model to save.
        dir_path : str | Path
            The directory path where the file should be saved.
        filename : str
            The name of the file to save the model to.
        """
        filename = self.with_file_extension(filename)
        string_serialization = self.export_to_string(model)
        full_path = Path(dir_path) / filename
        # newline="" disables newline translation, so the file on disk is exactly the string
        # the serializer produced. The text-mode default rewrites "\n" to os.linesep, which on
        # Windows makes save() disagree with export_to_bytes() for the same model.
        with open(full_path, "w", encoding="utf-8", newline="") as f:
            f.write(string_serialization)

    def prepare_document(
        self, element: DeserializationElementType, error_registry: ErrorRegistry
    ) -> DeserializationElementType | None:
        """Adapt a parsed *document* before its model is built; the default changes nothing.

        Every document entry point -- `load_from_string`, `load_from_bytes`, `load_from_stream`
        and `load` -- passes through here, so a format adapts a document in one place whichever
        way it was read. The DEXPI XML and JSON serializers read a DEXPI 2.0 document as 2.0.1
        here (`pydexpi.loaders.compat.dexpi_2_0_to_2_0_1`). It works on the parsed tree, never on
        text, as AGENTS.md prescribes for a vendor dialect.

        Parameters
        ----------
        element : DeserializationElementType
            The parsed document's root element. It belongs to this load, so it may be changed.
        error_registry : ErrorRegistry
            The registry of the load, where whatever is changed or refused is reported.

        Returns
        -------
        DeserializationElementType | None
            The element to build the model from, or None to refuse the document; the reason is
            then a registry entry.
        """
        return element

    def _load_document(self, element: DeserializationElementType) -> EngineeringModel | None:
        """Build the model of a whole parsed document, through `prepare_document`."""
        return self.loader.load(element, prepare=self.prepare_document)

    def load_from_string(self, data: str) -> EngineeringModel | None:
        """Load a pyDEXPI model from a string serialization.

        Parameters
        ----------
        data : str
            The string serialization to load.

        Returns
        -------
        EngineeringModel | None
            The loaded EngineeringModel object, or `None` if loading fails critically -- or the
            document is refused, e.g. a DEXPI 2.0 document that strict loading cannot convert.
        """
        element = self.get_loader_element_type().load_from_string(data)
        return self._load_document(element)

    def load_from_bytes(self, data: bytes) -> EngineeringModel | None:
        """Load a pyDEXPI model from bytes.

        Parameters
        ----------
        data : bytes
            The bytes to import.

        Returns
        -------
        EngineeringModel | None
            The loaded EngineeringModel object, or `None` if loading fails critically.
        """
        element_type = self.get_loader_element_type()
        if issubclass(element_type, BytesLoadableDeserializationElement):
            # Formats that declare their encoding in the document decode their own bytes.
            return self._load_document(element_type.load_from_bytes(data))
        return self.load_from_string(data.decode("utf-8"))

    def load_from_stream(self, stream: IO[bytes]) -> EngineeringModel | None:
        """Load a pyDEXPI model from a byte stream.

        Parameters
        ----------
        stream : IO[bytes]
            The byte stream to read the data from.

        Returns
        -------
        EngineeringModel | None
            The loaded EngineeringModel object, or `None` if loading fails critically.
        """
        return self.load_from_bytes(stream.read())

    def load(self, dir_path: str | Path, filename: str) -> EngineeringModel | None:
        """Load a pyDEXPI model from a file.

        Parameters
        ----------
        dir_path : str | Path
            The directory path where the file is located.
        filename : str
            The name of the file to load the model from.

        Returns
        -------
        EngineeringModel | None
            The loaded EngineeringModel object, or `None` if loading fails critically.
        """
        filename = self.with_file_extension(filename)
        full_path = Path(dir_path) / filename
        # Read as bytes so that a format declaring its own encoding is decoded by that declaration
        # rather than by an assumption made here. Bytes reading also performs no newline
        # translation, so load() and load_from_bytes(full_path.read_bytes()) hand the parser
        # the same input by construction.
        return self.load_from_bytes(full_path.read_bytes())

    def get_loading_errors(self) -> list[ErrorRegistryEntry]:
        """Get the list of errors that were registered during loading.

        Returns
        -------
        list[ErrorRegistryEntry]
            The list of registered errors.
        """
        return self.loader.error_registry.get_errors()
