"""The composition index of one model: every object by id, where it sits, and in what order.

Read-only, and shared by everything that walks a model by id, the Git projection
(:mod:`pydexpi.versioning.projection`) among them.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass

from pydexpi.pydexpi_classes.pydexpi_classes import PyDexpiBaseModel
from pydexpi.toolkits.base_model_utils import attribute_is_required, get_composition_attributes


@dataclass(frozen=True)
class CompositionLocation:
    """Where an object sits in the composition tree.

    The root of a model has none.

    Attributes
    ----------
    parent_id : str
        The id of the object holding it.
    attribute : str
        The composition attribute of the parent that holds it.
    single_valued : bool
        Whether that attribute holds one object rather than a list.
    required : bool
        Whether that single-valued attribute may not be empty.
    """

    parent_id: str
    attribute: str
    single_valued: bool = False
    required: bool = False


class _ModelIndex:
    """Every object of one model by id, with its location, children and document order."""

    def __init__(self, root: PyDexpiBaseModel) -> None:
        self.root = root
        self.objects: dict[str, PyDexpiBaseModel] = {}
        self.location: dict[str, CompositionLocation] = {}
        self.order: list[str] = []
        self.children: dict[str, list[str]] = defaultdict(list)
        self._seen: dict[int, str] = {}
        self._subtrees: dict[str, frozenset[str]] = {}
        self._visit(root, None)

    def _visit(self, obj: PyDexpiBaseModel, location: CompositionLocation | None) -> None:
        if id(obj) in self._seen:
            raise ValueError(
                f"{type(obj).__name__} {obj.id!r} is composed under two parents; an id-addressed "
                "record cannot say which one it belongs to."
            )
        if obj.id in self.objects:
            raise ValueError(f"Two different objects carry the id {obj.id!r}.")
        self._seen[id(obj)] = obj.id
        self.objects[obj.id] = obj
        if location is not None:
            self.location[obj.id] = location
        self.order.append(obj.id)
        for name, value in get_composition_attributes(obj).items():
            if isinstance(value, list):
                for item in value:
                    self.children[obj.id].append(item.id)
                    self._visit(item, CompositionLocation(obj.id, name))
            elif isinstance(value, PyDexpiBaseModel):
                self.children[obj.id].append(value.id)
                self._visit(
                    value,
                    CompositionLocation(
                        obj.id,
                        name,
                        single_valued=True,
                        required=attribute_is_required(type(obj), name),
                    ),
                )

    def subtree(self, object_id: str) -> frozenset[str]:
        """The ids of an object and all its composition descendants."""
        cached = self._subtrees.get(object_id)
        if cached is None:
            ids = {object_id}
            for child in self.children.get(object_id, ()):
                ids |= self.subtree(child)
            cached = self._subtrees[object_id] = frozenset(ids)
        return cached

    def list_ids(self, holder_id: str, attribute: str) -> list[str]:
        """The ids in one list attribute, in order."""
        return [item.id for item in getattr(self.objects[holder_id], attribute)]

    def slot_id(self, holder_id: str, attribute: str) -> str | None:
        """The id of the object in one single-valued attribute, or ``None``."""
        value = getattr(self.objects[holder_id], attribute)
        return value.id if isinstance(value, PyDexpiBaseModel) else None
