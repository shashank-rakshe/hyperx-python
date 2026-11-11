"""Tree-reference framework primitives for pyDEXPI serializers.

This package provides the reusable protocol and orchestration layers used by
tree-reference serializers:

- `TreeReferenceLoader` performs staged deserialization.
- `TreeReferenceExporter` performs structural serialization.
- `AbstractTreeReferenceSerializer` utility that combines both into the `Serializer` interface.
- `FormatConverter` converts directly between tree-reference formats, bypassing pyDEXPI models.

Typical usage
-------------
Import framework pieces directly from this package:

>>> from pydexpi.loaders.tree_ref_base import AbstractTreeReferenceSerializer
>>> from pydexpi.loaders.tree_ref_base import TreeReferenceLoader
>>> from pydexpi.loaders.tree_ref_base import TreeReferenceExporter

Framework-specific serializers can subclass
`AbstractTreeReferenceSerializer` and provide format-specific element types:

>>> class MySerializer(AbstractTreeReferenceSerializer[MyLoadElement, MySaveElement]):
...     def get_loader_element_type(self) -> type[MyLoadElement]:
...         return MyLoadElement
...     def serializer_element_factory(self) -> MySaveElement:
...         return MySaveElement()

Lower-level access is also available when you need custom orchestration:

>>> loader = TreeReferenceLoader()
>>> exporter = TreeReferenceExporter(False, MySaveElement)
"""

from .exporter import DataTypeSerializationElement, SerializationElement, TreeReferenceExporter
from .format_converter import FormatConverter
from .loader import (
    DataTypeDeserializationElement,
    DeserializationElement,
    TreeReferenceLoader,
)
from .utility_base import AbstractTreeReferenceSerializer

__all__ = [
    "AbstractTreeReferenceSerializer",
    "DataTypeDeserializationElement",
    "DataTypeSerializationElement",
    "DeserializationElement",
    "FormatConverter",
    "SerializationElement",
    "TreeReferenceExporter",
    "TreeReferenceLoader",
]
