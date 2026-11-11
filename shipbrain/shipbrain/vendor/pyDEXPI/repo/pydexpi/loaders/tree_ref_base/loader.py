"""Provides a loader for tree-reference-backed deserialization of pyDEXPI models.

Such formats implement the `DeserializationElement` interface to provide schema-specific readout
logic, and can be used with the loader directly to parse pyDEXPI models."""

from __future__ import annotations

import logging
from collections import defaultdict, deque
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from datetime import datetime
from enum import Enum
from functools import cache
from typing import Any, Protocol, Self, cast, runtime_checkable

from pydantic import ValidationError

import pydexpi.toolkits.base_model_utils as bmu
from pydexpi.loaders.error_registry import (
    ErrorLevels,
    ErrorRegistry,
    InternalParserError,
    SourceLocation,
)
from pydexpi.pydexpi_classes import pydexpi_classes
from pydexpi.pydexpi_classes.pydexpi_classes import (
    EngineeringModel,
    Port,
    PyDexpiBaseModel,
    PyDexpiDataTypeBaseModel,
    Undefined,
)

type PyDexpiDataFieldType = (
    PyDexpiBaseModel | Undefined | Enum | str | int | float | bool | datetime
)
type DeserializerDataFieldType = (
    PyDexpiBaseModel
    | Undefined
    | DataTypeDeserializationElement
    | Enum
    | str
    | int
    | float
    | bool
    | datetime
)

logger = logging.getLogger(__name__)


@runtime_checkable
class DeserializationElement(Protocol):
    """Interface that defines format-specific readout logic for the tree reference loader."""

    def get_id(self) -> str | None:
        """Return unique identifier of element. None if PyDexpiDataTypeBaseModel or Undefined."""
        ...

    def get_dexpi_class(self) -> str:
        """Return the name of the corresponding pyDEXPI class for this element.

        A name pyDEXPI has no class for is reported by the loader as unknown. An element that
        names no class at all returns an empty string (see `StructureReportingElement`).
        """
        ...

    def get_composition_attributes(self) -> dict[str, Self | list[Self] | None]:
        """Return all compositional attributes keyed by pyDEXPI field name."""
        ...

    def get_reference_attributes(self) -> dict[str, str | list[str] | None]:
        """Return all reference attributes keyed by pyDEXPI field name."""
        ...

    def get_data_attributes(
        self,
    ) -> dict[str, DeserializerDataFieldType | list[DeserializerDataFieldType] | None]:
        """Return all data attributes keyed by pyDEXPI field name in schema-specific format.

        This can either be another DeserializationElement (either the same (Self) or a different
        one if more customization is needed) (if the data attribute is a PyDexpiDataTypeBaseModel
        type or undefined) or a primitive DataFieldType, depending on the type of the data attribute.
        """
        ...

    @classmethod
    def load_from_string(cls, data: str) -> Self:
        """Create a deserialization element from a suitable string serialization."""
        ...


@runtime_checkable
class BytesLoadableDeserializationElement(Protocol):
    """Interface for deserialization elements that can be built from raw bytes.

    This is an optional capability on top of `DeserializationElement`. Implementing it lets a
    format decode its own input, which matters for formats that declare their encoding in the
    document itself. Elements that do not implement it are handed UTF-8 decoded text instead.
    """

    @classmethod
    def load_from_bytes(cls, data: bytes) -> Self:
        """Create a deserialization element from a suitable byte serialization."""
        ...


@runtime_checkable
class LocatableDeserializationElement(Protocol):
    """Interface for deserialization elements that can locate themselves in their source document.

    This is an optional capability on top of `DeserializationElement`. Implementing it lets errors
    registered against an element point back at the part of the input that caused them. Elements
    that do not implement it load exactly as before, with their errors carrying no location.
    """

    def get_source_location(self) -> SourceLocation:
        """Return the location of this element within its source document."""
        ...


@dataclass(frozen=True)
class RepeatedData:
    """The values of one data attribute that a deserialization element did not read.

    Attributes
    ----------
    location : SourceLocation
        Where the first unread one is.
    object_id : str | None
        The nearest enclosing object with an id: a data type, or an id-less object such as a
        ``QualifiedValue``, has none of its own.
    unread : list[str]
        The serialized text of every unread element, in document order.
    """

    location: SourceLocation
    object_id: str | None
    unread: list[str]


@runtime_checkable
class RepeatedDataReportingElement(Protocol):
    """Interface for deserialization elements that can say which data values they did not read.

    An optional capability, like `LocatableDeserializationElement`. DEXPI XML can give one data
    attribute in several sibling ``<Data>`` elements. For a list field `get_data_attributes` reads
    them all as one list; a single-valued field holds one value, so only the last is read,
    and an element implementing this names the others, so the loader reports them rather than
    discarding them silently. JSON cannot repeat a key, so it has nothing to report.
    """

    def get_repeated_data_attributes(self) -> dict[str, RepeatedData]:
        """Return, per pyDEXPI field name given more than once, what was not read."""
        ...


@dataclass(frozen=True)
class UnreadStructure:
    """A part of a document that is not what its format expects there, and so is not read.

    Attributes
    ----------
    what : str
        What was found and what the format expects, phrased to follow the name of the object
        it belongs to: ``has a "composition" block that is a string, where a JSON object is
        expected``.
    location : SourceLocation
        Where the part is.
    content : str
        The part as the document gives it, serialized in the document's format, so that it
        stays recoverable from the report.
    """

    what: str
    location: SourceLocation
    content: str


@runtime_checkable
class StructureReportingElement(Protocol):
    """Interface for deserialization elements that can say what of their structure they left out.

    An optional capability, like `RepeatedDataReportingElement`. A format whose parsed tree is
    untyped can hold anything where it expects an object, a block of attributes or an id: a
    JSON document may give a string where the ``composition`` block goes, a number in a list of
    objects, an object where a reference names its target, or no class at all. An element is
    read while the loader builds its element tree, before any tolerant path is reachable, so
    it must not raise over that: it reads what is as expected, leaves the rest out, and names
    what it left out here. The loader then registers each part with its content, so nothing is
    dropped silently.

    An element that names no pyDEXPI class answers `DeserializationElement.get_dexpi_class`
    with an empty string, and `get_class_problem` says what stands where the class goes.
    """

    def get_unread_structure(self) -> list[UnreadStructure]:
        """Return the parts of this element that are not what the format expects, in order."""
        ...

    def get_class_problem(self) -> str | None:
        """Return why this element names no pyDEXPI class, or None when it names one.

        Phrased to follow the name of the object: ``its "uri" is null, where ...``.
        """
        ...


@cache
def reports_structure(element_type: type) -> bool:
    """Whether elements of *element_type* are `StructureReportingElement` s.

    Asked once per element type rather than per element: an ``isinstance`` check against a
    runtime-checkable protocol looks every method up statically, and the loader asks for each
    object and each data type value of a document.
    """
    return issubclass(element_type, StructureReportingElement)


@runtime_checkable
class DataTypeDeserializationElement(Protocol):
    """Interface for deserialization elements that correspond to pyDEXPI data types or undefined.

    Is implemented by default by the main DeserializationElement, but can be implemented separately
    if more customization is needed"""

    def get_dexpi_class(self) -> str:
        """Return the name of the corresponding pyDEXPI class for this element."""
        ...

    def get_data_attributes(
        self,
    ) -> dict[str, DeserializerDataFieldType | list[DeserializerDataFieldType] | None]:
        """Return all data attributes keyed by pyDEXPI field name."""
        ...


def _is_composable_class(candidate: object) -> bool:
    """True unless *candidate* is a symbol the composition helpers cannot read.

    `getattr` over `pydexpi_classes` resolves more than the 495 generated model classes: 93
    enums (`AreaUnit`, `FillStyle`, ...) and a handful of names that leak in from its own
    imports (`ABC`, `datetime`). "Resolved" is therefore not "usable", and an enum carried past
    this point reaches helpers that read `model_fields` and raises `AttributeError` outside any
    tolerant path -- taking the document down instead of reporting one bad type name.

    Enums are rejected by kind rather than by testing for `model_fields`, because the loader is
    also exercised with plain stand-in classes that have no `model_fields` and must keep
    working. The stray imports are not covered by this and remain a narrower open case; `ABC`
    reaching a class lookup is one such shape.
    """
    return isinstance(candidate, type) and not issubclass(candidate, Enum)


class ElementBuilder[DeserializationElementType: DeserializationElement[Any]]:
    """Builder for constructing pyDEXPI objects from deserialization elements.

    Each builder is responsible for composing a single pyDEXPI object from its corresponding
    deserialization element. The builder retrieves the necessary information from the element and its
    child builders to compose the corresponding pyDEXPI object. It also handles error logging for
    missing or invalid attributes, and adds the composed object to the registry.

    To ensure that required references are available in the registry, the builder should only
    be composed after all its child builders have been composed to avoid RunTimeErrors.

    Attributes
    ----------
    _element : DeserializationElementType
        The deserialization element containing the data for this builder to compose.
    _object_registry : dict[str, PyDexpiBaseModel | PyDexpiDataTypeBaseModel]
        The registry for looking up references to other objects during composition (context pattern).
    _error_registry : ErrorRegistry
        The registry for logging errors during composition (context pattern).
    _parsed_object : PyDexpiBaseModel | PyDexpiDataTypeBaseModel | None
        The composed pyDEXPI object after composition, or None if it has not been composed yet.
    _is_composed : bool
        Flag indicating whether the builder has been composed or not.

    Further attributes are unpacked from the element and cached during initialization for efficient
    and consistent access during composition.
    """

    def __init__(
        self,
        element: DeserializationElementType,
        object_registry: dict[str, PyDexpiBaseModel | PyDexpiDataTypeBaseModel],
        error_registry: ErrorRegistry,
        strict: bool = True,
    ) -> None:
        """Initialize the builder with the deserialization element and registries.

        Parameters
        ----------
        _element : DeserializationElementType
            The deserialization element containing the data for this builder to compose.
        _object_registry : dict[str, PyDexpiBaseModel | PyDexpiDataTypeBaseModel]
            The registry for looking up references to other objects during composition
            (context pattern).
        _error_registry : ErrorRegistry
            The registry for logging errors during composition (context pattern).
        strict : bool, optional
            Whether an object missing a mandatory attribute is discarded. When False such an
            object is built with the attribute absent and the omission is recorded as an error.
            See `TreeReferenceLoader.__init__`. Default is True.
        """

        self._parsed_object = None
        self._is_composed = False
        self._strict = strict

        # Required reference fields whose targets did not yet exist when this builder was
        # composed, because `_extract_composition_chain` had to break a reference cycle to get
        # here. They are resolved in the reference pass instead. See `establish_references`.
        self._deferred_required_refs: set[str] = set()

        self._object_registry = object_registry
        self._error_registry = error_registry

        self._element = element

        # Unpack and cache element readouts for efficient and consistent access.
        self._element_id = self._element.get_id()
        self._source_location = (
            self._element.get_source_location()
            if isinstance(self._element, LocatableDeserializationElement)
            else SourceLocation()
        )
        self._dexpi_type = self._get_dexpi_type()
        self._report_unread_structure(self._element, f"Object {self._element_id}")
        self._compositional_child_builders = self._make_child_builders(element)
        self._reference_attributes = self._element.get_reference_attributes()

    def get_child_builders(self) -> list[ElementBuilder[Any]]:
        """Return the child builders for the compositional attributes."""
        return_list = []
        for builder in self._compositional_child_builders.values():
            if builder is None:
                continue
            elif isinstance(builder, list):
                return_list.extend(builder)
            else:
                return_list.append(builder)
        return return_list

    def get_required_reference_attributes(self) -> dict[str, str | list[str] | None]:
        """Return the required reference attributes for the element."""
        if self._dexpi_type is None:
            return {}
        model_ref_fields = bmu.get_reference_attributes_from_class(self._dexpi_type)
        required_ref_fields = [
            fld for fld in model_ref_fields if bmu.attribute_is_required(self._dexpi_type, fld)
        ]

        return {
            field: attr_ref
            for field, attr_ref in self._reference_attributes.items()
            if field in required_ref_fields
        }

    def get_element_id(self) -> str | None:
        """Return the element ID if present, otherwise None."""
        return self._element_id

    def compose(self) -> None:
        """Compose the element into a pyDEXPI object and add it to the registry.

        This method retrieves the necessary information from the element and its child builders to
        compose the corresponding pyDEXPI object. It also handles error logging for missing or
        invalid attributes, and adds the composed object to the registry."""

        if self._dexpi_type is None:
            msg = (
                f"Cannot compose object for element {self._element_id} due to unknown DEXPI class."
                f"{self._lost_with(self.get_child_builders(), ' ')}"
            )
            self._register_error(message=msg, level="error")
            self._is_composed = True
            return

        class_type = self._dexpi_type

        # Seed kwargs with id if present. Data/reference/composition values are added below.
        kwargs = {"id": self._element_id} if self._element_id is not None else {}

        # Retrieve compositional attributes with helper method
        try:
            kwargs.update(self._get_composition_attributes())
        except InternalParserError:
            raise
        except Exception as e:
            # Broad exception handler: a malformed child element can raise arbitrary runtime
            # errors while building the kwargs for this object. Record the issue and continue
            # composing so the rest of the document is still processed.
            logger.debug(
                "Error retrieving compositional attributes for object %s",
                self._element_id,
                exc_info=True,
            )
            msg = f"Error retrieving compositional attributes for object {self._element_id}: {e}"
            self._register_error(message=msg, level="error", exception=e)

        # Retrieve data attributes with helper method
        try:
            kwargs.update(self._get_data_attributes(self._element, self._dexpi_type))
        except InternalParserError:
            raise
        except Exception as e:
            # Broad exception handler: data attributes are schema-specific and may raise arbitrary
            # runtime errors when malformed. Record the issue and continue.
            logger.debug(
                "Error retrieving data attributes for object %s", self._element_id, exc_info=True
            )
            msg = f"Error retrieving data attributes for object {self._element_id}: {e}"
            self._register_error(message=msg, level="error", exception=e)

        try:
            kwargs.update(self._get_required_reference_attributes())
        except InternalParserError:
            raise
        except Exception as e:
            # Broad exception handler: reference resolution can fail in many ways for broken
            # documents. Record the issue and continue.
            logger.debug(
                "Error retrieving required reference attributes for object %s",
                self._element_id,
                exc_info=True,
            )
            msg = (
                f"Error retrieving required reference attributes for object {self._element_id}: {e}"
            )
            self._register_error(message=msg, level="error", exception=e)

        # Instantiate the object and add to registry.
        # `class_type` comes from a runtime lookup and is not guaranteed to be a Pydantic
        # model, so a plain ValueError from __init__ or a custom validator is as much a
        # malformed-document symptom as a ValidationError. AttributeError is deliberately
        # not caught: it points at an implementation bug rather than at bad input, and
        # should stay visible instead of becoming a registry entry.
        # ValidationError subclasses ValueError and is named only to document the common
        # case; the tuple would behave identically without it.
        try:
            the_object = class_type(**kwargs)
        except (ValidationError, TypeError, ValueError) as e:
            absent_attributes = self._missing_attributes_only(e)
            if absent_attributes is not None:
                # A reference cycle was broken to reach this builder, so the kwargs are knowingly
                # incomplete and nothing else is wrong. Build the object without validation so its
                # cycle partner can resolve against it; `establish_references` then assigns the
                # deferred references, and `validate_assignment` on `PyDexpiBaseModel` validates
                # them at that point.
                logger.debug(
                    "Deferring required references %s of object %s past a reference cycle",
                    sorted(self._deferred_required_refs),
                    self._element_id,
                )
                # Seed the deferred fields so the attributes exist even if the reference pass
                # cannot fill them (a dangling target). Reading `stream.target` then yields None
                # and a registered error, rather than raising AttributeError.
                the_object = self._construct_present_values(class_type, kwargs, absent_attributes)
                waived = absent_attributes - self._deferred_required_refs
                if "connectorReference" in waived and self._super_port_id() is not None:
                    # Derived after the reference pass, and reported there.
                    waived.discard("connectorReference")
                if waived:
                    msg = (
                        f"Object {self._element_id} of type {class_type.__name__} omits the "
                        f"mandatory attribute(s) {', '.join(sorted(waived))}. Loaded without "
                        f"them because the loader is not strict."
                    )
                    self._register_error(message=msg, level="error")
            else:
                the_object = self._compose_without_unusable_values(class_type, kwargs, e)
                if the_object is None:
                    logger.debug("Error instantiating object %s", self._element_id, exc_info=True)
                    lost = self._lost_with(self.get_child_builders(), "\n")
                    msg = f"Error instantiating object {self._element_id}: {e}{lost}"
                    self._register_error(message=msg, level="error", exception=e)
                    self._is_composed = True
                    return

        # Add to registry. Only applies to PyDexpiBaseModel objects, as PyDexpiDataTypeBaseModel and
        # Undefined objects do not have an id.
        if hasattr(the_object, "id") and the_object.id is not None:
            self._object_registry[the_object.id] = the_object
            self._element_id = the_object.id

        self._parsed_object = the_object
        self._is_composed = True

    @staticmethod
    def _construct_present_values(class_type, values, absent):
        """Waive only absent fields, retaining normal validation/coercion of present ones.

        Construction already reported only missing values. Assignment runs the same field
        validators on the provisional object, preserving live composition/reference identities.
        """
        result = class_type.model_construct(**{**dict.fromkeys(absent), **values})
        for name, value in values.items():
            setattr(result, name, value)
        return result

    # A malformed document can nest failures, so retries are bounded rather than open-ended.
    _MAX_VALUE_DROP_PASSES = 8

    def _compose_without_unusable_values(
        self,
        class_type: type[PyDexpiBaseModel],
        kwargs: dict[str, object],
        error: Exception,
    ) -> PyDexpiBaseModel | None:
        """Rebuild `class_type` with the values the model cannot represent removed.

        Only runs when the loader is not strict. One unusable value otherwise costs the whole
        object, which is a poor trade for a document that is right about everything else: a
        `Description` serialised as a plain string instead of a `MultiLanguageString` discards the
        component it describes, and a `QualifiedValue` whose value the model has no type for
        (a `PhysicalQuantityVector`) is discarded with its qualifiers and provenance.

        Removal is as narrow as the error allows. A failure reported at `("ports", 3, ...)` drops
        item 3 and keeps the rest of the list, so a parent survives with its remaining children
        rather than losing all of them to one bad entry.

        Returns the rebuilt object, or None to leave the caller's original error standing - which
        is what happens under strict, when nothing identifiable is at fault, or when dropping
        values does not make the object valid.
        """
        if self._strict:
            return None

        working = dict(kwargs)
        dropped: set[str] = set()
        # The values taken out, to name the built objects among them.
        removed: list[object] = []

        for _ in range(self._MAX_VALUE_DROP_PASSES):
            unusable = self._unusable_value_locations(error)
            if not unusable:
                return None

            # Classify every blamed location before touching `working`, then apply one
            # removal per field. Doing it per location would renumber the list between
            # removals: dropping index 1 shifts index 3 down to 2, so a later removal of 3
            # would take a *valid* sibling and leave the offending entry in place. `unusable`
            # is a set, so the order that happened in was not even deterministic.
            scalar_fields: set[str] = set()
            list_indices: dict[str, set[int]] = {}
            for field, index in unusable:
                if index is None or not isinstance(working.get(field), list):
                    scalar_fields.add(field)
                else:
                    list_indices.setdefault(field, set()).add(index)

            for field in scalar_fields:
                value = working.pop(field, None)
                removed.extend(value if isinstance(value, list) else [value])
                dropped.add(field)
            for field, indices in list_indices.items():
                values = cast(list[object], working[field])
                removed.extend(values[position] for position in indices if position < len(values))
                working[field] = [
                    value for position, value in enumerate(values) if position not in indices
                ]
                dropped.add(field)

            try:
                rebuilt = class_type(**working)
            except (ValidationError, TypeError, ValueError) as retry_error:
                # Removing a mandatory attribute makes it absent, which the leniency contract
                # already covers; anything else means another pass, or giving up.
                absent = self._missing_attributes_only(retry_error)
                if absent is not None:
                    rebuilt = self._construct_present_values(class_type, working, absent)
                else:
                    error = retry_error
                    continue

            msg = (
                f"Object {self._element_id} of type {class_type.__name__} carries "
                f"value(s) for {', '.join(sorted(dropped))} that the DEXPI model cannot "
                f"represent. Loaded without them because the loader is not strict."
                f"{self._lost_with(self._builders_of(removed), ' ')}"
            )
            self._register_error(message=msg, level="error", exception=error)
            return rebuilt

        return None

    def _builders_of(self, values: Iterable[object]) -> list[ElementBuilder[Any]]:
        """The child builders whose built object is one of *values*, in document order.

        A value `_compose_without_unusable_values` removes from a composition is an object a
        child builder built, and leaves the model with everything composed under it. Matching is
        by identity: model objects compare by value. A removed data value has no builder.
        """
        removed = {id(value) for value in values if value is not None}
        return [
            builder
            for builder in self.get_child_builders()
            if builder._parsed_object is not None and id(builder._parsed_object) in removed
        ]

    @staticmethod
    def _unusable_value_locations(error: Exception) -> set[tuple[str, int | None]]:
        """Locate the values a `ValidationError` blames, as (field, list index or None) pairs.

        `missing` entries are excluded: an absent attribute is not an unusable value, and
        `_missing_attributes_only` is what decides those.
        """
        if not isinstance(error, ValidationError):
            return set()

        locations: set[tuple[str, int | None]] = set()
        for details in error.errors():
            location = details.get("loc")
            if details.get("type") == "missing" or not location:
                continue
            field = location[0]
            if not isinstance(field, str):
                continue
            index = location[1] if len(location) > 1 and isinstance(location[1], int) else None
            locations.add((field, index))
        return locations

    def _missing_attributes_only(self, error: Exception) -> set[str] | None:
        """Return the absent mandatory attributes if `error` reports nothing else, else None.

        Two situations produce an object that is complete apart from absent attributes, and both
        are recoverable by building it without validation:

        - A reference cycle was broken to compose this builder early, so its required references
          are absent *on purpose* and get filled in by the reference pass. Always waived.
        - The document omits an attribute the DEXPI model makes mandatory. Waived only when the
          loader is not strict; see `TreeReferenceLoader.__init__`.

        Every other validation failure returns None, so this predicate alone never waives a bad
        value; `_compose_without_unusable_values` is what decides those, and only when the loader
        is not strict. Scoping this one to absences is what keeps the outcome independent of
        where the cycle happened to be cut.

        Only a *top-level* absence qualifies, which is why `loc` must name exactly one field.
        Pydantic reports a required field missing from somewhere nested as a longer path such as
        `("ports", 0, "identifier")`, and the caller resolves a waived name by setting that whole
        attribute to None - so reading `loc[0]` alone would answer a missing grandchild by
        discarding the entire `ports` list.
        """
        if not isinstance(error, ValidationError):
            return None
        missing: set[str] = set()
        for details in error.errors():
            location = details.get("loc")
            if details.get("type") != "missing" or not location or len(location) != 1:
                return None
            field = location[0]
            if not isinstance(field, str):
                return None
            if field not in self._deferred_required_refs and self._strict:
                return None
            missing.add(field)
        return missing or None

    # How many of the objects an entry loses with its own it names before counting the rest.
    _MAX_NAMED_LOST = 10

    @staticmethod
    def _lost_with(builders: Iterable[ElementBuilder[Any]], separator: str) -> str:
        """A sentence naming the built objects under *builders*, which no parent will hold.

        An object that is not built -- its class is unknown, it fails validation -- or a field
        its class does not have takes everything composed under it along: those objects were
        built, stay in the object registry, and nothing owns them. The entry that reports the
        cause therefore names them -- the first `_MAX_NAMED_LOST` by id, the rest by count -- so
        the loss shows below its root, and in full while it is that small.
        A strict load of bpmn2dexpi refuses each ``MaterialStateType`` over its ``Description``,
        and the ``Composition`` the DEXPI 2.0 conversion had just moved into it left with it,
        named by no entry.

        An object below that was not built itself is not walked into: its own entry names what
        it took along. Objects the document gives an id are named, up to `_MAX_NAMED_LOST`; the
        others are counted by class.

        Returns
        -------
        str
            *separator* and the sentence, or an empty string when nothing built is lost.
        """
        named: list[str] = []
        unnamed: dict[str, int] = defaultdict(int)
        pending = deque(builders)
        while pending:
            builder = pending.popleft()
            lost = builder._parsed_object
            if lost is None:
                continue
            document_id = builder._element.get_id()
            if document_id is None:
                unnamed[type(lost).__name__] += 1
            else:
                named.append(f"{type(lost).__name__} {document_id!r}")
            pending.extend(builder.get_child_builders())
        total = len(named) + sum(unnamed.values())
        if not total:
            return ""
        parts = named[: ElementBuilder._MAX_NAMED_LOST]
        if len(named) > len(parts):
            parts.append(f"{len(named) - len(parts)} more with an id")
        if unnamed:
            counts = ", ".join(f"{count} {name}" for name, count in sorted(unnamed.items()))
            parts.append(f"{counts} without an id")
        return (
            f"{separator}Not loaded with it: the {total} object(s) composed under it -- "
            f"{'; '.join(parts)}."
        )

    def establish_references(self):
        """Establish the parsed object's references after all objects have been composed.

        Determines the reference fields of the parsed object and looks up the corresponding
        references in the registry. This covers every non-required reference, plus any *required*
        reference listed in `_deferred_required_refs` - those were left unresolved because
        `_extract_composition_chain` had to break a reference cycle to compose this builder, and
        their targets only exist now. Required references that resolved during composition are
        skipped, since re-assigning them would be redundant work."""

        if not self._is_composed:
            raise InternalParserError(
                "Cannot establish references before object has been composed."
            )

        if self._parsed_object is None:
            msg = "Parsed object in reference pass is None, cannot establish references."
            self._register_error(message=msg, level="warning")
            return

        # Identify the pyDEXPI class
        class_type = type(self._parsed_object)

        # Retrieve non-required reference attributes
        ref_fields = bmu.get_reference_attributes_from_class(class_type)

        non_req_ref_flds = [
            fld for fld in ref_fields if not bmu.attribute_is_required(class_type, fld)
        ]

        for field, attr_ref in self._reference_attributes.items():
            # Log warnings for unrecognized reference fields.
            if field not in ref_fields:
                msg = (
                    f"Field '{field}' is not a valid reference attribute for "
                    f"class {class_type.__name__} and will be ignored."
                )
                self._register_error(message=msg, level="warning")

            # Non-required references are always established here. Required ones were resolved
            # during composition, except those deferred past a broken reference cycle, whose
            # targets only exist now.
            if field not in non_req_ref_flds and field not in self._deferred_required_refs:
                continue
            if attr_ref is not None:
                if isinstance(attr_ref, list):
                    resolved_refs = []
                    for ref in attr_ref:
                        if ref not in self._object_registry:
                            msg = (
                                f"Reference '{ref}' for attribute '{field}' not found in "
                                f"registry during reference pass."
                            )
                            self._register_error(message=msg, level="error")
                        else:
                            resolved_refs.append(self._object_registry[ref])
                    self._assign_reference(field, resolved_refs)
                elif attr_ref not in self._object_registry:
                    msg = (
                        f"Reference '{attr_ref}' for attribute '{field}' not found in "
                        f"registry during reference pass."
                    )
                    self._register_error(message=msg, level="error")
                else:
                    self._assign_reference(field, self._object_registry[attr_ref])

    def _assign_reference(self, field: str, value: object) -> None:
        """Assign a resolved reference, registering an ERROR if the attribute refuses it.

        The assignment is validated, and a document can give a reference in a shape its
        attribute does not take: a list of ids where it names one object, one id where it lists
        several, the id of an object of another class. That is bad input for one attribute, so
        it is reported and the attribute left as it was; raised from here, in the reference
        pass, it took the whole document down after every object had been built.
        """
        try:
            setattr(self._parsed_object, field, value)
        except (ValidationError, TypeError, ValueError) as e:
            logger.debug(
                "Error assigning reference %s of object %s", field, self._element_id, exc_info=True
            )
            given = f"{len(value)} object(s) as a list" if isinstance(value, list) else "one object"
            msg = (
                f"Reference attribute '{field}' of object {self._element_id} cannot hold what "
                f"the document gives it, {given}: {e}"
            )
            self._register_error(message=msg, level="error", exception=e)

    def derive_absent_references(self, derived: set[int]) -> None:
        """Give a delegated port that omits its connection the connection of its super port.

        A port with a ``SuperReference`` delegates to that port: it is its super port's
        stand-in on the inside of a sub-step, takes part in the same connection, and is never
        that connection's source or target. DEXPI makes ``ConnectorReference`` mandatory, but
        says nothing about a delegate's, and real files leave it out -- every one of the CO2
        terminal's delegated ports does. The connection is nonetheless determined: it is the
        super port's, found up the chain of super ports. So a lenient load assigns it, with one
        WARNING per port naming the connection and where it came from; a strict load does not
        derive it, and reports the omission as an error (`_get_required_reference_attributes`).

        Runs after the reference pass, once every ``SuperReference`` is resolved. A port none of
        whose super ports has a connection keeps none, and the omission is an ERROR as for any
        other port.

        Which port is a delegate missing its connection is read off the element and the object,
        not off how the object was built: a port the loader had to rebuild without an unusable
        value (`_compose_without_unusable_values`) is derived and reported like any other.

        Parameters
        ----------
        derived : set[int]
            The ``id()`` of every port derived so far, shared across the pass and extended here.
            The chain is climbed past them to the port whose connection the document states, so
            the result and its message do not depend on the order the ports are visited in.
        """
        port = self._parsed_object
        if (
            not isinstance(port, Port)
            or self._super_port_id() is None
            or self._reference_attributes.get("connectorReference")
            or port.__dict__.get("connectorReference") is not None
        ):
            return
        chain: list[Port] = []
        current = port.__dict__.get("superReference")
        connection = None
        while isinstance(current, Port) and not any(seen is current for seen in chain):
            chain.append(current)
            connection = current.__dict__.get("connectorReference")
            if connection is not None and id(current) not in derived:
                break
            connection = None
            current = current.__dict__.get("superReference")
        path = " -> ".join(repr(super_port.id) for super_port in chain) or "none resolved"
        if connection is None:
            msg = (
                f"Port {self._element_id} omits the mandatory attribute connectorReference, and "
                f"none of its super ports ({path}) has a connection to take. Loaded without it "
                "because the loader is not strict."
            )
            self._register_error(message=msg, level="error")
            return
        port.connectorReference = connection
        derived.add(id(port))
        msg = (
            f"Port {self._element_id} omits the mandatory attribute connectorReference. It "
            f"delegates to super port {path}, so it takes that port's connection "
            f"{connection.id!r}: a delegated port takes part in its super port's connection. "
            "Derived because the loader is not strict."
        )
        self._register_error(message=msg, level="warning")

    def _super_port_id(self) -> str | None:
        """The ``SuperReference`` this element names, if it builds a ``Port``."""
        if not (isinstance(self._dexpi_type, type) and issubclass(self._dexpi_type, Port)):
            return None
        super_port = self._reference_attributes.get("superReference")
        return super_port if isinstance(super_port, str) and super_port else None

    def get_parsed_object(self) -> PyDexpiBaseModel | PyDexpiDataTypeBaseModel | None:
        """Return the parsed object if it has already been composed, otherwise None."""
        if not self._is_composed:
            raise InternalParserError("Cannot get parsed object before it has been composed.")
        return self._parsed_object

    def _make_child_builders(
        self, element: DeserializationElementType
    ) -> dict[str, ElementBuilder[Any] | list[ElementBuilder[Any]]]:
        """Create child builders for the compositional attributes of the element."""
        child_builders = {}
        composition_attributes = element.get_composition_attributes()
        for field, attr_value in composition_attributes.items():
            if attr_value is None:
                child_builders[field] = None
            elif isinstance(attr_value, list):
                child_builders[field] = [
                    ElementBuilder(item, self._object_registry, self._error_registry, self._strict)
                    for item in attr_value
                ]
            else:
                child_builders[field] = ElementBuilder(
                    attr_value, self._object_registry, self._error_registry, self._strict
                )
        return child_builders

    def _get_dexpi_type(self) -> type[PyDexpiBaseModel] | None:
        class_name = self._element.get_dexpi_class()
        class_type = getattr(pydexpi_classes, class_name, None) if class_name else None

        # `getattr` also resolves the enums and other non-model symbols the package exports, so
        # "resolved" is not the same as "is a DEXPI object class". Treating `AreaUnit` as one
        # sends it on to helpers that read `model_fields` and raises `AttributeError` outside
        # any tolerant path -- taking the document down instead of reporting one bad type name.
        if not _is_composable_class(class_type):
            if class_name:
                msg = (
                    f"Unknown DEXPI class: {class_name}. Object {self._element_id} cannot be "
                    f"instantiated."
                )
            else:
                # The element names no class at all, which is not the same as naming one that
                # pyDEXPI does not have: say what stands where the class goes.
                msg = (
                    f"Object {self._element_id} names no DEXPI class"
                    f"{self._class_problem(self._element)}. It cannot be instantiated."
                )
            self._register_error(message=msg, level="error")
            return None
        return class_type

    @staticmethod
    def _class_problem(element: object) -> str:
        """``: <why>`` for an element that says why it names no class, else an empty string."""
        problem = element.get_class_problem() if reports_structure(type(element)) else None
        return f": {problem}" if problem else ""

    def _report_unread_structure(self, element: object, subject: str) -> None:
        """Register an ERROR for each part of *element* that it left out.

        A `StructureReportingElement` leaves out what is not what its format expects -- a
        ``composition`` block that is no mapping, an entry of a list of objects that is no
        object, a reference target that is no id -- instead of raising while the element tree
        is built. Each such part is reported here with its content, so the object is built
        from the rest and nothing is dropped silently.

        Parameters
        ----------
        element : object
            The element read; one that reports no structure is skipped.
        subject : str
            What the element is, to begin the message with: ``Object Tank1``.
        """
        if not reports_structure(type(element)):
            return
        for unread in element.get_unread_structure():
            self._error_registry.register_error(
                message=(
                    f"{subject} {unread.what}. It is not read; what the document gives there "
                    f"is this entry's content."
                ),
                level="error",
                object_id=self._entry_object_id,
                element=unread.location.element,
                xpath=unread.location.xpath,
                line=unread.location.line,
                column=unread.location.column,
                content=unread.content,
            )

    def _get_composition_attributes(self) -> dict[str, object]:
        """Helper method to retrieve compositional attributes for the element.

        Retrieves the compositional attributes from the references to the child builders and
        returns them in a dictionary keyed by the pyDEXPI field names, ready to be used as
        kwargs for the model constructor.

        Returns
        -------
        dict[str, object]
            A dictionary of compositional attribute names and their corresponding values.
        """

        # Collect composition kwargs and return once all fields are processed.
        comp_attr_args = {}

        # Retrieve the compositional fields
        compositional_fields = bmu.get_composition_attributes_from_class(self._dexpi_type)

        # Loop over fields and populate the kwargs.
        for field, field_builder in self._compositional_child_builders.items():
            if field not in compositional_fields:
                if field_builder is None:
                    under = []
                else:
                    under = field_builder if isinstance(field_builder, list) else [field_builder]
                msg = (
                    f"Field '{field}' is not a valid compositional attribute for class "
                    f"{self._dexpi_type.__name__} and will be ignored."
                    f"{self._lost_with(under, ' ')}"
                )
                self._register_error(message=msg, level="warning")
                continue

            if field_builder is None:
                comp_attr_args[field] = None
            elif isinstance(field_builder, list):
                comp_attr_args[field] = []
                for child_builder in field_builder:
                    parsed_obj = child_builder.get_parsed_object()
                    if parsed_obj is not None:
                        comp_attr_args[field].append(parsed_obj)
            else:
                comp_attr_args[field] = field_builder.get_parsed_object()
        return comp_attr_args

    def _get_data_attributes(
        self, element: DataTypeDeserializationElement, class_type: type[PyDexpiBaseModel]
    ) -> dict[str, PyDexpiDataFieldType | list[PyDexpiDataFieldType] | None]:
        """Retrieve and decode data attributes for a given element.

        Parameters
        ----------
        element : DataTypeDeserializationElement
            Source element containing schema-specific data attributes.
        class_type : type[PyDexpiBaseModel]
            pyDEXPI model class used for field validation.

        Returns
        -------
        dict[str, PyDexpiDataFieldType | list[PyDexpiDataFieldType] | None]
            Decoded data attributes ready for model construction.
        """
        data_attr_args = {}
        data_fields = bmu.get_data_attributes_from_class(class_type)
        data_attributes = element.get_data_attributes()
        if isinstance(element, RepeatedDataReportingElement):
            self._report_repeated_data(element, class_type, data_fields)

        for field, raw_data_attribute in data_attributes.items():
            if field not in data_fields:
                msg = (
                    f"Field '{field}' is not a valid data attribute for class "
                    f"{class_type.__name__} and will be ignored."
                )
                self._register_error(message=msg, level="warning")
                continue

            # Decode data attribute from schema-specific format to pyDEXPI DataFieldType
            if raw_data_attribute is None:
                data_attr_args[field] = None
            elif isinstance(raw_data_attribute, list):
                data_attr_args[field] = []
                for item in raw_data_attribute:
                    parsed_obj = self._unpack_data_attribute(item)
                    if parsed_obj is not None:
                        data_attr_args[field].append(parsed_obj)
            else:
                data_attr_args[field] = self._unpack_data_attribute(raw_data_attribute)
        return data_attr_args

    def _report_repeated_data(
        self,
        element: RepeatedDataReportingElement,
        class_type: type[PyDexpiBaseModel],
        data_fields: Iterable[str],
    ) -> None:
        """Register an ERROR for each valid single-valued data attribute given more than once.

        A list field's repeated ``<Data>`` elements are read as one list -- a
        ``PhysicalQuantityVector`` written as one ``<Data property="Values">`` per value loads
        with all of them -- so only a single-valued field reaches here: one value is read,
        the last, and the others are lost. The entry names the field and how many were not read,
        and carries their text, so nothing is dropped silently. An invalid field is already
        reported as such, so it is skipped here.
        """
        valid = set(data_fields)
        for field, repeated in element.get_repeated_data_attributes().items():
            if field not in valid:
                continue
            unread = len(repeated.unread)
            owner = repeated.object_id
            msg = (
                f"The {class_type.__name__} data attribute '{field}'"
                f"{f' in object {owner!r}' if owner is not None else ''} is given in "
                f"{unread + 1} <Data> elements, and only the last is read: the other {unread} "
                f"value(s) are not loaded. They are this entry's content."
            )
            self._error_registry.register_error(
                message=msg,
                level="error",
                object_id=owner,
                element=repeated.location.element,
                xpath=repeated.location.xpath,
                line=repeated.location.line,
                column=repeated.location.column,
                content="\n".join(repeated.unread),
            )

    def _unpack_data_attribute(
        self, raw_data_attribute: DeserializerDataFieldType
    ) -> PyDexpiDataFieldType | None:
        """Decode a data attribute.

        A data attribute is either a nested DeserializationElement, which corresponds to a
        pyDEXPI data type or undefined class, or a primitive DataFieldType. If it is a
        DeserializationElement, recursively decode it into a pyDEXPI object. Primitive
        values are returned unchanged.

        Parameters
        ----------
        raw_data_attribute : DeserializerDataFieldType
            Raw data-attribute value from the deserialization element.

        Returns
        -------
        PyDexpiDataFieldType | None
            Decoded pyDEXPI data-field value.
        """

        if isinstance(raw_data_attribute, DataTypeDeserializationElement):
            # Retrieve the corresponding pyDEXPI class from the element
            class_name = raw_data_attribute.get_dexpi_class()
            class_type = getattr(pydexpi_classes, class_name, None) if class_name else None
            self._report_unread_structure(
                raw_data_attribute,
                f"A {class_name or 'data type'} value of object {self._element_id}",
            )

            if not _is_composable_class(class_type):
                # Mirrors `_get_dexpi_type`: an unknown class is bad input, not a bug. Report it
                # and drop the value rather than handing it to the field-map helpers below --
                # which includes a name that resolves to something that is not a data type, such
                # as one of the exported enums.
                if class_name:
                    msg = (
                        f"Unknown DEXPI data type: {class_name}. Data attribute of object "
                        f"{self._element_id} cannot be instantiated."
                    )
                else:
                    msg = (
                        f"A data attribute of object {self._element_id} names no DEXPI data "
                        f"type{self._class_problem(raw_data_attribute)}. It cannot be "
                        f"instantiated."
                    )
                self._register_error(message=msg, level="error")
                return None

            # Get data attributes and (recursively) unpack them
            data_attr_args = self._get_data_attributes(raw_data_attribute, class_type)
            # Same reasoning as the instantiation site in `compose`: a plain ValueError is a
            # malformed-input symptom, an AttributeError is not and stays uncaught.
            try:
                the_object = class_type(**data_attr_args)
            except (ValidationError, TypeError, ValueError) as e:
                logger.debug(
                    "Error instantiating data attribute of type %s", class_name, exc_info=True
                )
                msg = f"Error instantiating data attribute of type {class_name}: {e}"
                self._register_error(message=msg, level="error", exception=e)
                the_object = None
            return the_object

        else:
            return raw_data_attribute

    def _get_required_reference_attributes(self) -> dict[str, object]:
        """Retrieve required reference attributes for a given element and class type.

        For each required field, retrieve the reference(s) from the element. Then, lookup the
        referenced objects in the registry. If found, resolve reference. If not found, then it
        has not been composed yet => raise IncompletePassError.

        Returns
        -------
        dict[str, object]
            A dictionary of required reference attribute names and their corresponding values.
        """
        ref_attr_args = {}
        ref_fields = bmu.get_reference_attributes_from_class(self._dexpi_type)

        required_ref_fields = [
            fld for fld in ref_fields if bmu.attribute_is_required(self._dexpi_type, fld)
        ]
        for field in required_ref_fields:
            attr_ref = self._reference_attributes.get(field)
            if attr_ref is None:
                super_port = self._super_port_id() if field == "connectorReference" else None
                if super_port is not None and not self._strict:
                    # A lenient load gives a delegated port its super port's connection, and
                    # reports that instead (`derive_absent_references`).
                    continue
                # The document does not carry the attribute at all; no later pass can supply it.
                msg = (
                    f"Missing required reference attribute '{field}' for element with ID "
                    f"'{self._element.get_id()}'."
                )
                if super_port is not None:
                    msg += (
                        f" It is a delegated port (SuperReference {super_port!r}), and takes part "
                        "in its super port's connection: a lenient load gives it that one, a "
                        "strict load does not derive it."
                    )
                self._register_error(message=msg, level="error")
            elif isinstance(attr_ref, list):
                resolved = [
                    self._object_registry[ref] for ref in attr_ref if ref in self._object_registry
                ]
                if len(resolved) == len(attr_ref):
                    ref_attr_args[field] = resolved
                else:
                    # A target is still missing because a reference cycle was broken to compose
                    # this builder early. Defer to the reference pass, which reports the ones
                    # that are genuinely dangling.
                    self._deferred_required_refs.add(field)
            elif attr_ref in self._object_registry:
                ref_attr_args[field] = self._object_registry[attr_ref]
            else:
                self._deferred_required_refs.add(field)

        return ref_attr_args

    @property
    def _entry_object_id(self) -> str | None:
        """The element's id for a registry entry: the id when it is one, else None.

        An untyped format can give anything where the id goes -- a number, a list. Such an id
        still reaches validation, which refuses it by name, and the messages, which quote it;
        an entry's ``object_id`` is a string or nothing, for the code that reads it.
        """
        return self._element_id if isinstance(self._element_id, str) else None

    def report_nothing_loaded(self) -> None:
        """Register the CRITICAL entry of a load whose root object could not be built.

        Nothing is returned then, and the entries so far are ERRORs about one object each: a
        caller looking for what "prevents loading the model entirely" would find none at that
        level. The entry points at the root and leaves the reason to those ERRORs.
        """
        self._register_error(
            message=(
                f"Nothing was loaded: the root object {self._element_id} could not be built. "
                f"The ERROR entries of this load say why."
            ),
            level=ErrorLevels.CRITICAL,
        )

    def _register_error(
        self, message: str, level: str = "error", exception: Exception | None = None
    ) -> None:
        """Helper method to register an error with the error registry with prefilled id.

        Also prefills the source location of the element, so that the error points back at the part
        of the input document that caused it. The location fields stay None for formats that cannot
        report one.
        """
        self._error_registry.register_error(
            message=message,
            level=level,
            object_id=self._entry_object_id,
            exception=exception,
            element=self._source_location.element,
            xpath=self._source_location.xpath,
            line=self._source_location.line,
            column=self._source_location.column,
        )


class TreeReferenceLoader[DeserializationElementType: DeserializationElement[Any]]:
    """Decoder for tree-reference loading strategy for pyDEXPI graph-like serialization formats.

    Constructs pyDEXPI objects from a tree-like traversal of the input data, where child elements
    and dependencies are composed before their parents. After the initial composition pass, a
    second reference pass establishes non-required references.

    Attributes
    ----------
    object_registry : dict[str, PyDexpiBaseModel | PyDexpiDataTypeBaseModel]
        A registry mapping element IDs to their corresponding instantiated pyDEXPI objects. Used to
        resolve references.
    element_registry : dict[str, DeserializationElementType]
        A registry mapping element IDs to their corresponding DeserializationElements. Used for
        reference pass to keep track and map elements without an intrinsic id, but for which an
        id is assigned during parsing.
    error_registry : ErrorRegistry
        A registry for collecting and managing errors during loading.
    """

    def __init__(self, strict: bool = True) -> None:
        """Initialize the decoder with empty registries.

        Parameters
        ----------
        strict : bool, optional
            How to treat an object that omits an attribute the DEXPI model makes mandatory. When
            True (the default) the object is discarded and the failure recorded, so a loaded model
            always satisfies its own schema. When False the object is built with the attribute
            absent and the omission is recorded as an error instead.

            Leniency exists because real DEXPI process files need it: both reference process models
            in `data/dexpi_process_examples/`, written by independent vendors, omit the mandatory
            `Identifier` on 78 % and 92 % of the objects whose class requires it, and rejecting
            those, with their descendants, builds 146 objects from the CO2 terminal where a lenient
            load builds 959. Only *missing* attributes are waived; every other validation failure
            is still fatal to the object under either setting.

            The serializers' `prepare_document` follows the same setting when it reads a DEXPI 2.0
            document as 2.0.1: strict refuses one that 2.0.1 cannot represent without copying or
            dropping data, lenient converts it and reports each copy and drop.
        """

        self.strict = strict
        self.element_registry: dict[str, DeserializationElementType] = {}
        self.object_registry: dict[str, PyDexpiBaseModel | PyDexpiDataTypeBaseModel] = {}
        self.error_registry = ErrorRegistry()

    def reset(self) -> None:
        """Reset the decoder's state for a new parsing session."""
        self.element_registry: dict[str, DeserializationElementType] = {}
        self.object_registry = {}
        self.error_registry = ErrorRegistry()

    def load(
        self,
        data: DeserializationElementType,
        prepare: Callable[
            [DeserializationElementType, ErrorRegistry], DeserializationElementType | None
        ]
        | None = None,
    ) -> EngineeringModel | None:
        """Load data into an EngineeringModel object.

        Parameters
        ----------
        data : DeserializationElementType
            The root element containing the data to be loaded.
        prepare : Callable, optional
            Adapts the parsed document before any object is built, reporting what it does to the
            error registry it is given: this load's own, so its entries are kept with the rest.
            It returns the element to build from, or None to refuse the document, in which case
            nothing is built and this returns None. The serializers use it to read a DEXPI 2.0
            document as 2.0.1 (`pydexpi.loaders.compat`). By default the document is built as
            parsed.

        Returns
        -------
        EngineeringModel | None
            The loaded EngineeringModel object, or None if loading failed critically: *prepare*
            refused the document, or the root object could not be built. Either way the error
            registry then holds a CRITICAL entry, the refusal's own or one registered here
            last, which leaves the reason to the ERROR entries before it.
        """
        # Reset state for new load
        self.reset()

        if prepare is not None:
            prepared = prepare(data, self.error_registry)
            if prepared is None:
                return None
            data = prepared

        # Make top level builder
        root_builder = ElementBuilder(data, self.object_registry, self.error_registry, self.strict)

        # Recursively collect child builders, keeping track of the dependency structure
        builders_w_dependencies = {}
        self._unpack_child_builders(root_builder, builders_w_dependencies)

        # Further populate the dependencies with required reference attributes
        self._extend_dependencies_with_required_refs(builders_w_dependencies)

        # Extract chain of compositions from dependencies, where builders with no dependencies
        # are composed first, then their parents, and so on. Ensures that when a builder is
        # composed, all of its required references have already been composed and are available in
        # the registry.
        composition_chain = self._extract_composition_chain(builders_w_dependencies)

        # Compose builders along the composition chain
        for builder in composition_chain:
            builder.compose()

        # After all builders are composed, establish non-required references in separate pass
        for builder in composition_chain:
            builder.establish_references()

        # What a lenient load derives from references, once they all resolve: a delegated
        # port's connection. A strict load never derives anything.
        if not self.strict:
            derived_ports: set[int] = set()
            for builder in composition_chain:
                builder.derive_absent_references(derived_ports)

        # Return the parsed root object
        root_object = root_builder.get_parsed_object()
        if root_object is None:
            root_builder.report_nothing_loaded()

        return root_object

    def _unpack_child_builders(
        self,
        element_builder: ElementBuilder[Any],
        collected_builders: dict[ElementBuilder, list[ElementBuilder]],
    ) -> dict[str, PyDexpiBaseModel | list[PyDexpiBaseModel] | None]:
        """Helper method to unpack child builders.

        Recursively unpacks child builders from the higher level builder and collects them in a
        the keys of a dictionary. The dictionary values keep track of all builders that depend on
        a given builder. This allows to identify quickly which builders can be composed first.

        Parameters
        ----------
        element_builder : ElementBuilder
            The builder whose child builders are being unpacked.
        collected_builders : dict[ElementBuilder, list[ElementBuilder]]
            A dictionary mapping builders to the list of builders that depend on them. This is
        """
        if element_builder in collected_builders:
            msg = (
                f"Builder for element with ID {element_builder.get_element_id()} unexpectedly "
                f"shared across multiple parents."
            )
            raise InternalParserError(msg)

        child_builders = element_builder.get_child_builders()
        collected_builders[element_builder] = child_builders
        for child_builder in child_builders:
            collected_builders = self._unpack_child_builders(child_builder, collected_builders)

        return collected_builders

    def _extend_dependencies_with_required_refs(
        self, collected_builders: dict[ElementBuilder, list[ElementBuilder]]
    ) -> None:
        """Helper method to populate the dependencies with required reference attributes."""
        # Only an id that is one: an untyped format can give a list or an object where the id
        # goes, which is no dictionary key. Validation refuses such an object by name later.
        builder_id_map = {
            element_id: builder
            for builder in collected_builders
            if isinstance(element_id := builder.get_element_id(), str)
        }
        for builder, dependencies in collected_builders.items():
            required_refs = builder.get_required_reference_attributes()
            for ref_attr in required_refs.values():
                for ref in ref_attr if isinstance(ref_attr, list) else [ref_attr]:
                    if isinstance(ref, str) and ref in builder_id_map:
                        dependencies.append(builder_id_map[ref])

    def _extract_composition_chain(
        self, collected_builders: dict[ElementBuilder, list[ElementBuilder]]
    ) -> list[ElementBuilder]:
        """Order builders so that each is composed after the builders it depends on.

        Two kinds of dependency are mixed into `collected_builders`, and they must not be treated
        alike:

        - *Compositional* dependencies (parent to child) come from `_unpack_child_builders`. They
          form a tree, so they can never cycle, and they are honoured unconditionally: a parent is
          never composed before its children.
        - *Required-reference* dependencies come from `_extend_dependencies_with_required_refs`.
          These can and routinely do cycle. Every DEXPI process model contains one, because
          `Stream.source` / `Stream.target` and `Port.connectorReference` are required references
          to each other.

        When only reference dependencies are left unsatisfied, one is broken: the builder is
        composed anyway and its unresolved required references are deferred to the reference pass
        (`establish_references`), which fills them in once their targets exist.

        Every builder in `collected_builders` is returned exactly once.
        """
        # Split the merged dependency lists back into their two kinds. Sets also collapse the
        # duplicates that arise when several required references point at the same builder.
        hard_dependencies: dict[ElementBuilder[Any], set[ElementBuilder[Any]]] = {}
        soft_dependencies: dict[ElementBuilder[Any], set[ElementBuilder[Any]]] = {}
        for builder, dependencies in collected_builders.items():
            children = set(builder.get_child_builders())
            hard_dependencies[builder] = children
            soft_dependencies[builder] = {dep for dep in dependencies if dep not in children}

        # Reverse the edges so composing a builder can decrement its dependents' counters.
        hard_dependents: dict[ElementBuilder[Any], list[ElementBuilder[Any]]] = defaultdict(list)
        soft_dependents: dict[ElementBuilder[Any], list[ElementBuilder[Any]]] = defaultdict(list)
        for builder in collected_builders:
            for dependency in hard_dependencies[builder]:
                hard_dependents[dependency].append(builder)
            for dependency in soft_dependencies[builder]:
                soft_dependents[dependency].append(builder)

        open_hard = {builder: len(deps) for builder, deps in hard_dependencies.items()}
        open_soft = {builder: len(deps) for builder, deps in soft_dependencies.items()}

        # `ready` holds builders with nothing outstanding; `blocked` holds those whose children
        # are composed but which still wait on a required reference. Only `blocked` may be cut.
        # `blocked` is a dict used as an ordered set: `min` returns the first of several equal
        # candidates, so insertion order keeps the choice of cut point deterministic. A plain set
        # would make the loaded model depend on hash ordering between runs.
        ready: deque[ElementBuilder[Any]] = deque()
        blocked: dict[ElementBuilder[Any], None] = {}
        for builder in collected_builders:
            if open_hard[builder]:
                continue
            if open_soft[builder]:
                blocked[builder] = None
            else:
                ready.append(builder)

        composition_chain: list[ElementBuilder[Any]] = []
        composed: set[ElementBuilder[Any]] = set()

        while len(composition_chain) < len(collected_builders):
            if ready:
                builder = ready.popleft()
            elif blocked:
                # Break the cycle at the builder waiting on the fewest references.
                builder = min(blocked, key=lambda candidate: open_soft[candidate])
                del blocked[builder]
                msg = (
                    f"Cyclic dependency detected involving object "
                    f"{builder.get_element_id()}. Its unresolved required references are "
                    f"deferred to the reference pass."
                )
                self.error_registry.register_error(
                    msg, level="warning", object_id=builder.get_element_id()
                )
            else:
                # Unreachable for well-formed input: compositional dependencies form a tree, so
                # something is always unblocked. Emit the remainder rather than spin forever.
                remaining = [b for b in collected_builders if b not in composed]
                msg = (
                    f"Could not order {len(remaining)} builders; composing them in "
                    f"arbitrary order. This indicates a malformed composition tree."
                )
                self.error_registry.register_error(msg, level="error", object_id=None)
                composition_chain.extend(remaining)
                break

            composed.add(builder)
            composition_chain.append(builder)

            for dependent in hard_dependents[builder]:
                open_hard[dependent] -= 1
                if open_hard[dependent] == 0:
                    if open_soft[dependent]:
                        blocked[dependent] = None
                    else:
                        ready.append(dependent)
            for dependent in soft_dependents[builder]:
                open_soft[dependent] -= 1
                # Only promote builders still sitting in `blocked`; one already taken by the
                # cycle-breaking branch above must not be queued a second time.
                if open_soft[dependent] == 0 and dependent in blocked:
                    del blocked[dependent]
                    ready.append(dependent)

        return composition_chain
