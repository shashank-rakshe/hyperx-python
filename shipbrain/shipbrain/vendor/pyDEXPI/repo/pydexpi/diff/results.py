"""Result types for semantic diffs.

This module defines the structured result types returned by the diff engine.
Each change is represented as a small, typed object that downstream code
(reports, UI, validation) can consume without parsing free-form strings.

The results are Pydantic models, and a ``DiffResult`` is a versioned, machine-readable artifact::

    payload = diff.model_dump(mode="json")      # plain JSON, safe to send or store
    same = DiffResult.model_validate(payload)   # and back

Attribute values
----------------
In memory, :class:`AttributeChange` holds the *live* values of both models, as it always has: the
objects a reference pointed at, a ``PhysicalQuantity``, an enum member. Serializing it -- in JSON
*or* Python mode -- writes them in the shared wire form of ``pydexpi.loaders.value_codec``:

- a reference, as the target's id. A list of references is written as the sorted list of ids
  -- most reference lists are compared as sets, so their order carries nothing -- unless the
  change says ``ordered``: an ordered list (``ListOfMaterialComponents.component``, whose order a
  fraction vector is read against) keeps its order;
- a composition reorder, as the list of member ids in order;
- anything else through ``value_codec.encode_value``: primitives as themselves, enum members as
  their value, ``datetime`` as ISO 8601, data types as ``{"dexpi_class", "data"}`` envelopes.

A result read back with ``model_validate`` therefore carries wire values, not live objects.
Serializing it again gives the same payload, so ``dump -> validate -> dump`` is stable.

Ordering
--------
Lists are in a documented, deterministic order, not re-sorted: added objects in the depth-first
composition order of the *new* model, removed objects in that of the *old* model, and moved and
modified objects in the order their matches were found (depth-first through the old model's
composition, then the global matching pass). Parents therefore come before their children.
"""

from __future__ import annotations

from collections.abc import Callable, Iterable, Sequence
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_serializer, model_validator

from pydexpi.diff.domains import ChangeDomain, domain_of_class
from pydexpi.loaders.value_codec import JsonValue, encode_value
from pydexpi.pydexpi_classes.pydexpi_classes import PyDexpiBaseModel

__all__ = [
    "DIFF_FORMAT_VERSION",
    "AddedObject",
    "AttributeChange",
    "DiffEntry",
    "DiffResult",
    "Matching",
    "ModifiedObject",
    "MovedObject",
    "RemovedObject",
    "entry_object_ids",
]

#: The version of the serialized ``DiffResult`` format. Bumped on any change a reader must know
#: about; a reader should refuse a version it does not know.
#:
#: - ``"1"``: the first format.
#: - ``"2"``: ``AttributeChange.ordered``, so an ordered reference list is written in order
#:   rather than as sorted ids, and the lists DEXPI declares ordered are compared by position
#:   whether or not the diff tracks order. A format-1 payload still validates, for display, but
#:   it does not say what a format-2 diff of the same models says, so a consumer that acts on
#:   a diff should refuse it and recompute the diff.
DIFF_FORMAT_VERSION: Literal["2"] = "2"

#: The format versions ``DiffResult.model_validate`` reads.
DiffFormatVersion = Literal["1", "2"]

Matching = Literal["id", "tag", "custom"]
"""How objects were matched between the two models: by stable id (``id_equality``), by
engineering tag (``TagEquality``), or by some other strategy. Never the name of a callable, which
would not survive serialization reliably."""


class _ChangeEntry(BaseModel):
    """Fields and behaviour every per-object entry shares."""

    model_config = ConfigDict(frozen=True)

    object_type: str
    """The class name, e.g. ``"Pump"``."""
    tag: str | None = None
    """The engineering tag, as ``display_name.get_tag`` resolves it, or ``None``."""
    domain: ChangeDomain = "conceptual"
    """What the change concerns. The engine classifies by the object's location in the model
    (``pydexpi.diff.domains``); an entry built without one is classified by its class."""

    @model_validator(mode="before")
    @classmethod
    def _default_domain_from_class(cls, data: Any) -> Any:
        """Classify by class when no domain is given, so hand-built entries stay correct."""
        if isinstance(data, dict) and data.get("domain") is None and "object_type" in data:
            return {**data, "domain": domain_of_class(data["object_type"])}
        return data


class MovedObject(_ChangeEntry):
    """An object that exists in both models but has a changed parent in the composition hierarchy.

    Moving between two attributes of the same parent counts as a move as well; the container
    attributes say which.

    Attributes
    ----------
    object_id_1 : str
        The ``id`` of the object in the first model.
    object_id_2 : str
        The ``id`` of the object in the second model.
    object_type : str
        The class name.
    tag : str | None
        The tag name (from the *new* model) if available.
    old_parent_id : str | None
        The ``id`` of the old parent object, or ``None`` if it had no parent.
    new_parent_id : str | None
        The ``id`` of the new parent object, or ``None`` if it has no parent.
    old_container_attribute : str | None
        The composition attribute of the old parent that held the object.
    new_container_attribute : str | None
        The composition attribute of the new parent that holds the object.
    domain : ChangeDomain
        What the change concerns, classified at the object's *new* location.
    """

    object_id_1: str
    object_id_2: str
    old_parent_id: str | None = None
    new_parent_id: str | None = None
    old_container_attribute: str | None = None
    new_container_attribute: str | None = None


class AddedObject(_ChangeEntry):
    """An object present in the *new* model but absent from the *old* model.

    Attributes
    ----------
    object_id : str
        The ``id`` of the new object (from the second model).
    object_type : str
        The class name (e.g. ``"Pump"``, ``"PipingNetworkSegment"``).
    tag : str | None
        The tag name if the object has one, otherwise ``None``.
    domain : ChangeDomain
        What the change concerns.
    """

    object_id: str


class RemovedObject(_ChangeEntry):
    """An object present in the *old* model but absent from the *new* model.

    Attributes
    ----------
    object_id : str
        The ``id`` of the removed object (from the first model).
    object_type : str
        The class name.
    tag : str | None
        The tag name if the object had one, otherwise ``None``.
    domain : ChangeDomain
        What the change concerns, classified at the object's old location.
    """

    object_id: str


class AttributeChange(BaseModel):
    """A single attribute that differs between the old and new version of an object.

    Attributes
    ----------
    attribute_name : str
        The field name that changed.
    old_value : object
        The value in the old model (may be ``None``). Live in memory; see the module docstring
        for its serialized form.
    new_value : object
        The value in the new model (may be ``None``).
    category : str
        ``"data"`` for a data attribute, ``"reference"`` for a reference attribute, or
        ``"composition"`` for a reordered ordered composition list: always for a list the
        specification orders (z-order included), and for one pyDEXPI orders (a segment's flow
        order) only when the diff tracks order. For a reorder the values are the member ids in order: model-1 ids in the
        old order, model-2 ids in the new one.
    ordered : bool
        Whether the attribute is an ordered list (``pydexpi.diff.ordering``), so that its order
        is part of the change. Its values are then serialized in order; an unordered reference
        list is serialized as sorted ids.
    """

    model_config = ConfigDict(frozen=True)

    attribute_name: str
    old_value: Any = None
    new_value: Any = None
    category: Literal["data", "reference", "composition"] = "data"
    ordered: bool = False

    @field_serializer("old_value", "new_value", when_used="always")
    def _serialize_value(self, value: Any) -> JsonValue:
        """Write a live value in the wire form, and a wire value unchanged."""
        return _wire_value(value, ordered=self.ordered)


def _wire_value(value: Any, *, ordered: bool = False) -> JsonValue:
    """The wire form of one attribute value; idempotent on wire values."""
    if isinstance(value, PyDexpiBaseModel):
        return value.id
    if isinstance(value, Sequence) and not isinstance(value, str):
        items = list(value)
        if items and all(isinstance(item, PyDexpiBaseModel) for item in items):
            ids = [item.id for item in items]
            return ids if ordered else sorted(ids)
    return encode_value(value)


class ModifiedObject(_ChangeEntry):
    """An object that exists in both models but has one or more changed attributes.

    Attributes
    ----------
    object_id_1 : str
        The ``id`` of the object in the first model.
    object_id_2 : str
        The ``id`` of the object in the second model.
    object_type : str
        The class name.
    tag : str | None
        The tag name (from the *new* model) if available.
    changes : list[AttributeChange]
        The list of individual attribute changes.
    domain : ChangeDomain
        What the change concerns, classified at the object's location in the new model.
    """

    object_id_1: str
    object_id_2: str
    changes: list[AttributeChange] = Field(default_factory=list)


class DiffResult(BaseModel):
    """Top-level container for the result of comparing two pyDEXPI models.

    Attributes
    ----------
    format_version : str
        The serialized format's version: :data:`DIFF_FORMAT_VERSION` for a diff computed now, or
        ``"1"`` for a stored format-1 payload read back.
    matching : Matching
        How objects were matched between the models. Only an ``"id"`` diff pairs each object with
        the one carrying the same id, which is what acting on the diff needs.
    track_order : bool
        Whether reorders of the composition lists pyDEXPI orders beyond the specification (a
        segment's flow order) were compared. An empty result with ``track_order=False`` does not
        mean a segment's items are in the same order. Lists the specification declares ordered,
        the drawing's z-order among them, are compared either way.
    moved_objects : list[MovedObject]
        Objects that exist in both models but have a changed parent in the composition hierarchy.
    added_objects : list[AddedObject]
        Objects present only in the new model.
    removed_objects : list[RemovedObject]
        Objects present only in the old model.
    modified_objects : list[ModifiedObject]
        Objects present in both models with changed attributes.
    """

    format_version: DiffFormatVersion = DIFF_FORMAT_VERSION
    matching: Matching = "custom"
    track_order: bool = False
    moved_objects: list[MovedObject] = Field(default_factory=list)
    added_objects: list[AddedObject] = Field(default_factory=list)
    removed_objects: list[RemovedObject] = Field(default_factory=list)
    modified_objects: list[ModifiedObject] = Field(default_factory=list)

    # ------------------------------------------------------------------
    # Convenience helpers
    # ------------------------------------------------------------------

    def _entries(self) -> list[_ChangeEntry]:
        """Every per-object entry, in the order of the four lists."""
        return [
            *self.added_objects,
            *self.removed_objects,
            *self.modified_objects,
            *self.moved_objects,
        ]

    @property
    def has_changes(self) -> bool:
        """Return ``True`` if any diff category is non-empty."""
        return bool(
            self.added_objects
            or self.removed_objects
            or self.modified_objects
            or self.moved_objects
        )

    @property
    def has_semantic_changes(self) -> bool:
        """Return ``True`` if any change concerns the engineering content (the conceptual model).

        Document metadata -- the modification date, the exporting tool -- is not engineering
        content, and neither is the drawing.
        """
        return any(entry.domain == "conceptual" for entry in self._entries())

    @property
    def has_graphic_changes(self) -> bool:
        """Return ``True`` if any change concerns drawing/layout data.

        This does not mean the changes are *limited* to graphics: a diff can have both graphic
        and semantic changes. Check ``has_semantic_changes`` for the other half.
        """
        return any(entry.domain == "graphics" for entry in self._entries())

    @property
    def has_metadata_changes(self) -> bool:
        """Return ``True`` if any change concerns document metadata."""
        return any(entry.domain == "metadata" for entry in self._entries())

    # ------------------------------------------------------------------
    # Result filters
    #
    # These narrow an already computed diff; they never re-compare anything. Filtering a whole
    # model diff to a subtree is therefore not the same as comparing the subtree on its own
    # (``PyDexpiDiffEngine.diff_objects``): a move across the boundary stays a move here.
    # ------------------------------------------------------------------

    def filter(self, predicate: Callable[[DiffEntry], bool]) -> DiffResult:
        """Return a diff with only the entries *predicate* accepts, and the same metadata.

        Parameters
        ----------
        predicate : callable
            Called with each ``AddedObject``, ``RemovedObject``, ``ModifiedObject`` and
            ``MovedObject``; the entry is kept when it returns ``True``.

        Returns
        -------
        DiffResult
            A new result. The original is not changed.
        """
        return self.model_copy(
            update={
                "moved_objects": [entry for entry in self.moved_objects if predicate(entry)],
                "added_objects": [entry for entry in self.added_objects if predicate(entry)],
                "removed_objects": [entry for entry in self.removed_objects if predicate(entry)],
                "modified_objects": [entry for entry in self.modified_objects if predicate(entry)],
            }
        )

    def for_objects(self, object_ids: Iterable[str]) -> DiffResult:
        """Return the changes concerning the given objects.

        An entry is kept when its object's id -- in either model -- is one of *object_ids*. To
        keep a whole subtree, pass its ids: ``pydexpi.diff.subtree_ids`` collects them.

        Parameters
        ----------
        object_ids : iterable of str
            The ids of the objects of interest.

        Returns
        -------
        DiffResult
            A new result with the same metadata.
        """
        wanted = set(object_ids)
        return self.filter(lambda entry: not wanted.isdisjoint(entry_object_ids(entry)))

    def in_domains(self, *domains: ChangeDomain) -> DiffResult:
        """Return the changes in the given domains (``"conceptual"``, ``"graphics"``, ...)."""
        wanted = set(domains)
        return self.filter(lambda entry: entry.domain in wanted)

    def semantic_only(self) -> DiffResult:
        """Return only the engineering (conceptual) changes."""
        return self.in_domains("conceptual")

    def graphics_only(self) -> DiffResult:
        """Return only the drawing/layout changes."""
        return self.in_domains("graphics")

    def metadata_only(self) -> DiffResult:
        """Return only the document-metadata changes."""
        return self.in_domains("metadata")


DiffEntry = AddedObject | RemovedObject | ModifiedObject | MovedObject
"""Any one per-object entry of a ``DiffResult``."""


def entry_object_ids(entry: DiffEntry) -> set[str]:
    """The id or ids an entry is about: its object's id in each model it exists in."""
    if isinstance(entry, (AddedObject, RemovedObject)):
        return {entry.object_id}
    return {entry.object_id_1, entry.object_id_2}
