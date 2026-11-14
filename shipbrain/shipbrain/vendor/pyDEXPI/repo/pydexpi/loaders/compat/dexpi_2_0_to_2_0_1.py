"""Read a DEXPI 2.0 document as DEXPI 2.0.1.

pyDEXPI's classes are DEXPI 2.0.1, and pyDEXPI writes only 2.0.1. It reads 2.0 by converting the
**parsed document** -- the lxml tree of a DEXPI XML document, the decoded dict of a pyDEXPI JSON
one -- before any object is built, the way AGENTS.md prescribes for a vendor dialect: the tree,
never the text, and in the one place every entry point passes through
(``AbstractTreeReferenceSerializer.prepare_document``). Proteus input never comes here: its
parser builds 2.0.1 objects directly.

**Which version a document is.** DEXPI XML declares it in the ``<Import>`` URIs of its root
(``https://data.dexpi.org/models/2.0.0/Core.xml``); pyDEXPI JSON in a root ``"dexpiVersion"``
key, which pyDEXPI writes from 2.0.1 on, so JSON without one is 2.0. A 2.0.1 document is read as
parsed. An XML document that declares no version, or one pyDEXPI does not know, is read by its
content: if it holds a construct only DEXPI 2.0 has, it is converted, with a WARNING saying the
version was inferred; otherwise it reads the same under either version and nothing is reported.

**What is converted**, each step reported to the load's error registry:

- *Renames*, id-preserving, INFO: ``Composition.MoleFractiona`` -> ``MoleFractions``;
  ``Capacity`` -> ``ChargeCapacity`` on the ``StoringEnergy`` family only (``StoringMaterial``
  and ``TransportingEnergy`` keep their ``Capacity``); a nested ``MaterialState.Phase`` ->
  ``Phases``; and the enumeration ``PercentageUnit`` -> ``RatioUnit``, in XML ``DataReference``
  spellings, JSON ``{"__enum__": ...}`` values and qualified ``"PercentageUnit.<L>"`` units.
- *A class key pyDEXPI got wrong* (JSON only), INFO: pyDEXPI's ``Role`` once had a field
  ``uri`` for DEXPI's ``Role.Uri``, which shadowed the class's own URI, so its JSON named no
  class -- ``"uri": null``, or the attribute's value -- and nothing read it back. The roles of a
  ``ConceptualModel`` are ``Role`` s, so such an entry is given its class, and the attribute its
  field name since, ``uri_`` (:data:`SHADOWED_CLASS_KEYS`).
- *Changed kind*: ``MeasuringProcessVariable.MeasuredVariable`` is a ``QualifiedValue``
  composition in 2.0 and an enumeration in 2.0.1, and nothing maps one to the other. Likewise
  ``Port.SubReference``, which pyDEXPI's 2.0 classes composed -- the sub-ports themselves -- and
  its 2.0.1 classes make a reference (a pyDEXPI change, not a DEXPI one). Strict refuses the
  document, naming the object and the value; lenient drops the value, with an ERROR carrying it.
- *Ownership*: DEXPI 2.0 keeps ``Composition`` s and ``MaterialStateType`` s in model-level
  containers and refers to them from ``MaterialStateType.Composition`` and
  ``MaterialState.State`` / ``Phase``; DEXPI 2.0.1 removed the containers and composes them
  there. Owner slots are read in document order:

  ================================================  ===================  ======================
  The 2.0 document                                  strict               lenient
  ================================================  ===================  ======================
  referenced by exactly one owner slot              move, id kept (INFO)  move, id kept (INFO)
  shared: two or more owner slots, or a slot and    refuse, listing      copy (below); WARNING
  an owner that already composes it                 every sharer         per copy, with the ids
  referenced by no owner slot                       refuse               drop; ERROR carrying it
  other references into a shared object             refuse               kept on the original;
                                                                         WARNING
  blocked: a State reference from a state that      refuse               drop the reference;
  already composes one                                                   ERROR
  ================================================  ===================  ======================

  Compositions are placed first, so a state type that is then moved or copied takes its
  composition with it.

  A JSON owner whose ``composition`` block is no JSON object -- a string, a list -- has nowhere
  to place what it claims without that block going: strict refuses the document, lenient drops
  the block, with an ERROR carrying it. Every other part of a document that is not what
  the format expects is left as it is, for the loader to report in a 2.0 and a 2.0.1 document
  alike.

**The copy.** The first owner slot keeps the original. Each other one gets a copy of the whole
owned subtree -- the object and everything composed below it -- in which every object with an id
gets a new one, ``<id>__<owner-id>`` made schema-safe, with a numeric suffix on a clash with any
id in the document or assigned before (``xml_serializer.schema_safe_id``). References inside the
copy to objects inside it follow the copy; references leaving it are kept. The same document
converts to the same ids every time, and to the same ids in XML and in JSON.

**Strict and lenient.** A strict load refuses a document holding anything that cannot be
converted without copying or dropping data -- a shared object, an unclaimed one, a reference into
a shared one, a blocked ``State`` reference, a changed-kind value, a ``composition`` block it
cannot write into. It registers one CRITICAL entry
listing all of it (its exception is a :class:`ConversionRefusedError`) and builds nothing. A
lenient load converts it as above.
"""

from __future__ import annotations

import copy
import json
import re
from collections import Counter
from collections.abc import Callable, Iterator
from dataclasses import dataclass, field
from functools import lru_cache, partial
from typing import Any, Protocol

from lxml import etree

from pydexpi.loaders.error_registry import ErrorLevels, ErrorRegistry, SourceLocation
from pydexpi.loaders.source_location import (
    describe_json_value,
    join_json_pointer,
    source_location_from_xml_element,
)
from pydexpi.loaders.xml_serializer import DexpiXmlDeserializationElement, schema_safe_id
from pydexpi.pydexpi_classes import pydexpi_classes
from pydexpi.toolkits.base_model_utils import dexpi_attribute_name

__all__ = [
    "CHANGED_KINDS",
    "DEXPI_2_0",
    "DEXPI_2_0_1",
    "ENUM_CLASS_RENAMES",
    "JSON_VERSION_KEY",
    "OWNERSHIP_CHANGES",
    "PROPERTY_RENAMES",
    "REMOVED_CONTAINERS",
    "SHADOWED_CLASS_KEYS",
    "ChangedKind",
    "ConversionRefusedError",
    "DocumentVersion",
    "OwnershipChange",
    "PropertyRename",
    "RemovedContainer",
    "ShadowedClassKey",
    "in_family",
    "json_class_name",
    "json_document_version",
    "json_enum_renames",
    "json_objects",
    "json_reading_version",
    "renamed_enum",
    "upgrade_json_document",
    "upgrade_xml_document",
    "xml_document_version",
    "xml_reading_version",
]

#: DEXPI 2.0, as this module names it: an XML ``<Import>`` of ``models/2.0.0`` is 2.0.
DEXPI_2_0 = "2.0"
#: The version this module converts to, and the version of pyDEXPI's classes.
DEXPI_2_0_1 = "2.0.1"
#: The root key of a pyDEXPI JSON document that declares its DEXPI version.
JSON_VERSION_KEY = "dexpiVersion"


# --------------------------------------------------------------------------- What DEXPI 2.0.1
# changed, as data, so that everything migrated from 2.0 is migrated by one definition.
# ---------------------------------------------------------------------------


# Bounded: the class names come from the documents read, which can name anything.
@lru_cache(maxsize=1024)
def in_family(class_name: str | None, family: str) -> bool:
    """Whether *class_name* is the 2.0.1 class *family* or one derived from it."""
    if not class_name:
        return False
    candidate = getattr(pydexpi_classes, class_name, None)
    base = getattr(pydexpi_classes, family)
    return isinstance(candidate, type) and issubclass(candidate, base)


@dataclass(frozen=True)
class PropertyRename:
    """A composition property DEXPI 2.0.1 renamed: the same objects, under a new name.

    Attributes
    ----------
    family : str
        The class carrying the property; its subclasses carry it too, and no other class.
    old, new : str
        The pyDEXPI field name in 2.0 and in 2.0.1.
    unique : bool
        Whether no other DEXPI 2.0 class has a property named *old*, so that a name alone
        identifies it -- in a record whose target's class is unknown, for instance.
    """

    family: str
    old: str
    new: str
    unique: bool = False

    def applies_to(self, class_name: str | None) -> bool:
        """Whether an object of *class_name* carries this property."""
        return in_family(class_name, self.family)


#: The lossless, id-preserving renames, by which a document is migrated.
#: ``Capacity`` is renamed on the ``StoringEnergy`` family only.
PROPERTY_RENAMES: tuple[PropertyRename, ...] = (
    PropertyRename("Composition", "moleFractiona", "moleFractions", unique=True),
    PropertyRename("StoringEnergy", "capacity", "chargeCapacity"),
)

#: Enumerations DEXPI 2.0.1 renamed, 2.0 name -> 2.0.1 name. Every 2.0 literal is a literal of the
#: 2.0.1 enumeration, which adds more.
ENUM_CLASS_RENAMES: dict[str, str] = {"PercentageUnit": "RatioUnit"}


@dataclass(frozen=True)
class OwnershipChange:
    """A DEXPI 2.0 reference that DEXPI 2.0.1 made a composition: the owner now holds the object.

    Attributes
    ----------
    owner : str
        The class holding the property.
    old : str
        The 2.0 reference property, as the pyDEXPI field name.
    new : str
        The 2.0.1 composition property.
    owned : str
        The class of the object it holds.
    single : bool
        Whether the 2.0.1 property holds at most one object.
    """

    owner: str
    old: str
    new: str
    owned: str
    single: bool


#: The 2.0 references DEXPI 2.0.1 turned into compositions.
OWNERSHIP_CHANGES: tuple[OwnershipChange, ...] = (
    OwnershipChange("MaterialStateType", "composition", "composition", "Composition", True),
    OwnershipChange("MaterialState", "state", "state", "MaterialStateType", True),
    OwnershipChange("MaterialState", "phase", "phases", "MaterialStateType", False),
)


@dataclass(frozen=True)
class RemovedContainer:
    """A DEXPI 2.0 container DEXPI 2.0.1 removed; its objects now belong to the owners above."""

    owner: str
    prop: str
    owned: str


#: The model-level containers DEXPI 2.0.1 removed.
REMOVED_CONTAINERS: tuple[RemovedContainer, ...] = (
    RemovedContainer("ProcessModel", "compositions", "Composition"),
    RemovedContainer("ProcessModel", "materialStateTypes", "MaterialStateType"),
)


@dataclass(frozen=True)
class ChangedKind:
    """A property that is a composition in DEXPI 2.0 and data in 2.0.1, with no mapping between."""

    family: str
    prop: str
    was: str
    now: str
    #: Who made the change: DEXPI 2.0.1, or pyDEXPI's own classes for it.
    by: str = "DEXPI 2.0.1"


#: The properties whose kind changed between pyDEXPI's DEXPI 2.0 and 2.0.1 classes.
CHANGED_KINDS: tuple[ChangedKind, ...] = (
    ChangedKind(
        "MeasuringProcessVariable",
        "measuredVariable",
        "a QualifiedValue",
        "a MeasuredQuantity enumeration literal",
    ),
    # Not a DEXPI change: pyDEXPI's 2.0 classes composed a port's sub-ports, its 2.0.1 classes
    # refer to them, as DEXPI does. Which step's ports a composed sub-port belongs among is not
    # in the document, so it is not moved there.
    ChangedKind(
        "Port",
        "subReference",
        "composed sub-ports",
        "a reference to ports composed elsewhere",
        by="pyDEXPI's DEXPI 2.0.1 classes",
    ),
)


@dataclass(frozen=True)
class ShadowedClassKey:
    """A class whose JSON class key pyDEXPI's DEXPI 2.0 writer overwrote with a data value.

    A pyDEXPI JSON object names its class under ``"uri"``. DEXPI's ``Role`` has a data attribute
    ``Uri``, which pyDEXPI once generated as a field ``uri``: it shadowed the
    class's own URI, so the writer put the *attribute's* value where the class goes -- ``null``
    for a role without one -- and repeated it under ``data``. pyDEXPI itself could not read such
    a role back. The attribute is the field ``uri_`` since, and the class of the object is known
    from where it sits: the property holds objects of one class.

    Attributes
    ----------
    owner : str
        The class holding the property; its subclasses hold it too.
    prop : str
        The composition property.
    cls : str
        The one class of the objects the property holds.
    old, new : str
        The data field that shadowed the class key, and its field name now.
    """

    owner: str
    prop: str
    cls: str
    old: str
    new: str


#: The classes whose JSON pyDEXPI wrote without their class, by where their objects sit.
SHADOWED_CLASS_KEYS: tuple[ShadowedClassKey, ...] = (
    ShadowedClassKey("ConceptualModel", "roles", "Role", "uri", "uri_"),
)

#: A nested ``MaterialState.Phase`` is the 2.0.1 composition under its 2.0 name: a rename, in a
#: document, while the 2.0 *reference* is an ownership change.
_DOCUMENT_RENAMES: tuple[PropertyRename, ...] = (
    *PROPERTY_RENAMES,
    PropertyRename("MaterialState", "phase", "phases"),
)


def _current_name(class_name: str, prop: str | None) -> str | None:
    """*prop* of a *class_name* under its 2.0.1 name: a nested 2.0 ``phase`` is ``phases``."""
    for rename in _DOCUMENT_RENAMES:
        if prop == rename.old and rename.applies_to(class_name):
            return rename.new
    return prop


def renamed_enum(class_name: str, member: str) -> str | None:
    """The 2.0.1 enumeration a DEXPI 2.0 *class_name* literal *member* belongs to, or None.

    *member* may be the literal (``Percent``) or the member name (``PERCENT``). None when the
    enumeration was not renamed, or when the 2.0.1 one has no such literal -- that value is then
    left as it is, for the loader to report.
    """
    new_name = ENUM_CLASS_RENAMES.get(class_name)
    if new_name is None:
        return None
    new_enum = getattr(pydexpi_classes, new_name)
    return new_name if member.upper() in new_enum.__members__ else None


def _spelled(class_name: str, member: str, new_class: str) -> tuple[str, str]:
    """``(old, new)`` as ``<Enum>.<literal>``, the same whichever format spelled the member."""
    literal = getattr(pydexpi_classes, new_class)[member.upper()].value
    return f"{class_name}.{literal}", f"{new_class}.{literal}"


# ---------------------------------------------------------------------------
# Version
# ---------------------------------------------------------------------------

#: A DEXPI model URI, ``https://data.dexpi.org/models/<version>/...``. Only DEXPI's own host:
#: another vendor's ``<Import>`` may version its own models the same way.
_MODEL_URI_VERSION = re.compile(r"^https?://data\.dexpi\.org/models/(\d+(?:\.\d+)*)/")
_KNOWN_VERSIONS = (DEXPI_2_0, DEXPI_2_0_1)


def _normalise(version: str) -> str:
    """``2.0.0`` is DEXPI 2.0; every other spelling is kept as it is."""
    return DEXPI_2_0 if version in ("2.0", "2.0.0") else version


@dataclass(frozen=True)
class DocumentVersion:
    """The DEXPI version a document declares, as read from it.

    Attributes
    ----------
    declared : str | None
        ``"2.0"`` or ``"2.0.1"``; None when the document declares no version pyDEXPI reads.
    evidence : str
        What the document says, phrased to follow "The document ...".
    unreadable : bool
        True when the document declares something that is not one version pyDEXPI reads: an
        unknown version, or Imports naming different ones.
    """

    declared: str | None
    evidence: str
    unreadable: bool = False


def xml_document_version(model_root: etree._Element | None) -> DocumentVersion:
    """The DEXPI version a DEXPI XML document declares in its ``<Import>`` URIs.

    Parameters
    ----------
    model_root : etree._Element | None
        The document's ``Model`` element; None for a fragment parsed without one.

    Returns
    -------
    DocumentVersion
        What the Imports declare.
    """
    if model_root is None:
        return DocumentVersion(None, "is a fragment, without the <Import>s of a <Model>")
    sources = [element.get("source") or "" for element in model_root.iterchildren(tag="Import")]
    versions = sorted(
        {_normalise(match.group(1)) for src in sources if (match := _MODEL_URI_VERSION.search(src))}
    )
    if not versions:
        return DocumentVersion(None, "has no <Import> naming a DEXPI model version")
    if len(versions) > 1:
        return DocumentVersion(
            None, f"has <Import>s naming DEXPI {' and '.join(versions)}", unreadable=True
        )
    version = versions[0]
    if version not in _KNOWN_VERSIONS:
        return DocumentVersion(None, f"has <Import>s naming DEXPI {version}", unreadable=True)
    return DocumentVersion(version, f"has <Import>s naming DEXPI {version}")


def json_document_version(document: dict[str, Any]) -> DocumentVersion:
    """The DEXPI version a pyDEXPI JSON document declares in its root ``"dexpiVersion"``.

    A document without the key is DEXPI 2.0: pyDEXPI wrote JSON without one until its classes
    were 2.0.1.
    """
    if JSON_VERSION_KEY not in document:
        return DocumentVersion(
            DEXPI_2_0, f'has no "{JSON_VERSION_KEY}", so it was written for DEXPI 2.0'
        )
    value = document[JSON_VERSION_KEY]
    version = _normalise(value) if isinstance(value, str) else None
    if version in _KNOWN_VERSIONS:
        return DocumentVersion(version, f'declares "{JSON_VERSION_KEY}": {json.dumps(value)}')
    return DocumentVersion(
        None, f'declares "{JSON_VERSION_KEY}": {json.dumps(value)}', unreadable=True
    )


# ---------------------------------------------------------------------------
# A document, whatever its format
# ---------------------------------------------------------------------------


@dataclass(eq=False)
class _Node:
    """One object of the parsed document: an XML ``Object`` element, or a JSON object dict."""

    raw: Any
    class_name: str
    id: str | None
    parent: _Node | None
    parent_property: str | None
    order: int
    children: list[tuple[str, list[_Node]]] = field(default_factory=list)
    references: list[tuple[str, list[str]]] = field(default_factory=list)

    def child_properties(self) -> set[str]:
        """The composition properties this object has at least one object under."""
        return {name for name, kids in self.children if kids}

    def subtree(self) -> Iterator[_Node]:
        """This object and every object composed below it, in document order."""
        yield self
        for _, kids in self.children:
            for kid in kids:
                yield from kid.subtree()


@dataclass
class _EnumRename:
    """One ``PercentageUnit`` value, and how to make it a ``RatioUnit`` one."""

    object_id: str | None
    location: SourceLocation
    enum_class: str
    old: str
    new: str
    apply: Callable[[], None]


@dataclass
class _ClassKeyRepair:
    """One object pyDEXPI wrote without its class, and how to give it back."""

    node: _Node
    shadowed: ShadowedClassKey
    #: What stands where the class goes, as the document spells it.
    written: str
    #: Whether the attribute's value is under ``data`` too, under its old field name.
    renames: bool
    apply: Callable[[], None]


@dataclass
class _Unwritable:
    """An owner with something that is no block of compositions where its compositions go."""

    owner: _Node
    kind: str
    content: str
    #: What the conversion places in the owner, in the order it does.
    placed: list[_Node] = field(default_factory=list)


class _Format(Protocol):
    """How the conversion reads and changes one format's parsed document."""

    kind: str

    def index(self) -> list[_Node]: ...
    def location(self, node: _Node) -> SourceLocation: ...
    def objects(self, raw: Any) -> list[Any]: ...
    def object_id(self, raw: Any) -> str | None: ...
    def set_object_id(self, raw: Any, new_id: str) -> None: ...
    def rewrite_references(self, raw: Any, mapping: dict[str, str]) -> tuple[int, int]: ...
    def clone(self, raw: Any) -> Any: ...
    def serialize(self, raw: Any) -> str: ...
    def serialize_property(self, node: _Node, prop: str) -> str: ...
    def rename_property(self, node: _Node, old: str, new: str) -> None: ...
    def drop_property(self, node: _Node, prop: str) -> None: ...
    def detach(self, node: _Node) -> None: ...
    def attach(self, owner: _Node, prop: str, raw: Any, single: bool) -> None: ...
    def remove_reference(self, owner: _Node, prop: str, target_id: str) -> None: ...
    def remove_if_empty(self, owner: _Node, prop: str) -> None: ...
    def enum_renames(self) -> list[_EnumRename]: ...
    def class_key_repairs(self, nodes: list[_Node]) -> list[_ClassKeyRepair]: ...
    def unwritable(self, owner: _Node) -> _Unwritable | None: ...
    def drop_unwritable(self, owner: _Node) -> None: ...


def _bare(token: str) -> str:
    """An XML reference token without its ``#``."""
    return token[1:] if token.startswith("#") else token


class _XmlFormat:
    """A DEXPI XML document: ``Object`` elements, ``Components`` / ``References`` children."""

    kind = "XML"

    def __init__(self, top: etree._Element) -> None:
        self.top = top

    @staticmethod
    def _class_name(element: etree._Element) -> str:
        return DexpiXmlDeserializationElement(element).get_dexpi_class()

    def _fields(self, element: etree._Element, tag: str) -> list[tuple[str, etree._Element]]:
        """The *tag* children of *element* in document order, with their pyDEXPI field names.

        Named exactly as the loader names them, so the conversion and the build agree on which
        property an element is.
        """
        named = DexpiXmlDeserializationElement(element)._extract_attribute_elements(tag)
        field_of = {child.get("property"): name for name, child in named.items()}
        return [
            (field_of[child.get("property")], child)
            for child in element.iterchildren(tag=tag)
            if child.get("property") in field_of
        ]

    def index(self) -> list[_Node]:
        nodes: list[_Node] = []

        def visit(element: etree._Element, parent: _Node | None, prop: str | None) -> _Node:
            node = _Node(
                raw=element,
                class_name=self._class_name(element),
                id=element.get("id"),
                parent=parent,
                parent_property=prop,
                order=len(nodes),
            )
            nodes.append(node)
            node.references = [
                (name, [_bare(token) for token in (child.get("objects") or "").split()])
                for name, child in self._fields(element, "References")
            ]
            for name, container in self._fields(element, "Components"):
                kids = [visit(kid, node, name) for kid in container.iterchildren(tag="Object")]
                node.children.append((name, kids))
            return node

        visit(self.top, None, None)
        return nodes

    def location(self, node: _Node) -> SourceLocation:
        return source_location_from_xml_element(node.raw)

    def objects(self, raw: etree._Element) -> list[etree._Element]:
        return list(raw.iter("Object"))

    def object_id(self, raw: etree._Element) -> str | None:
        object_id = raw.get("id")
        return None if object_id is None else str(object_id)

    def set_object_id(self, raw: etree._Element, new_id: str) -> None:
        raw.set("id", new_id)

    def rewrite_references(self, raw: etree._Element, mapping: dict[str, str]) -> tuple[int, int]:
        internal = external = 0
        for reference in raw.iter("References"):
            tokens = []
            for token in (reference.get("objects") or "").split():
                target = _bare(token)
                if target in mapping:
                    tokens.append(f"{token[: len(token) - len(target)]}{mapping[target]}")
                    internal += 1
                else:
                    tokens.append(token)
                    external += 1
            reference.set("objects", " ".join(tokens))
        return internal, external

    def clone(self, raw: etree._Element) -> etree._Element:
        clone = copy.deepcopy(raw)
        clone.tail = None
        return clone

    def serialize(self, raw: etree._Element) -> str:
        return str(etree.tostring(raw, encoding="unicode", with_tail=False))

    def serialize_property(self, node: _Node, prop: str) -> str:
        return "".join(
            self.serialize(child)
            for name, child in self._fields(node.raw, "Components")
            if name == prop
        )

    def _components(self, node: _Node, prop: str) -> list[etree._Element]:
        return [child for name, child in self._fields(node.raw, "Components") if name == prop]

    def rename_property(self, node: _Node, old: str, new: str) -> None:
        dexpi_class = getattr(pydexpi_classes, node.class_name, None)
        existing = self._components(node, new)
        for container in self._components(node, old):
            if existing:
                # Two containers for one property would be read as one: merge them instead.
                for kid in list(container.iterchildren(tag="Object")):
                    existing[-1].append(kid)
                node.raw.remove(container)
            else:
                container.set("property", dexpi_attribute_name(dexpi_class, new))
                existing.append(container)

    def drop_property(self, node: _Node, prop: str) -> None:
        for container in self._components(node, prop):
            node.raw.remove(container)

    def detach(self, node: _Node) -> None:
        parent = node.raw.getparent()
        if parent is not None:
            parent.remove(node.raw)

    def attach(self, owner: _Node, prop: str, raw: etree._Element, single: bool) -> None:
        existing = self._components(owner, prop)
        if existing:
            container = existing[-1]
        else:
            dexpi_class = getattr(pydexpi_classes, owner.class_name, None)
            container = etree.SubElement(
                owner.raw, "Components", property=dexpi_attribute_name(dexpi_class, prop)
            )
        container.append(raw)

    def remove_reference(self, owner: _Node, prop: str, target_id: str) -> None:
        for name, reference in self._fields(owner.raw, "References"):
            if name != prop:
                continue
            tokens = (reference.get("objects") or "").split()
            for position, token in enumerate(tokens):
                if _bare(token) == target_id:
                    del tokens[position]
                    if tokens:
                        reference.set("objects", " ".join(tokens))
                    else:
                        owner.raw.remove(reference)
                    return

    def remove_if_empty(self, owner: _Node, prop: str) -> None:
        for container in self._components(owner, prop):
            if next(container.iterchildren(tag="Object"), None) is None:
                owner.raw.remove(container)

    def enum_renames(self) -> list[_EnumRename]:
        renames = []
        for reference in self.top.iter("DataReference"):
            data = reference.get("data") or ""
            prefix, slash, path = data.partition("/")
            parts = path.split(".")
            if not slash or len(parts) < 2:
                continue
            new_class = renamed_enum(parts[-2], parts[-1])
            if new_class is None:
                continue
            new_data = f"{prefix}/{'.'.join([*parts[:-2], new_class, parts[-1]])}"
            owner = next(reference.iterancestors("Object"), None)
            renames.append(
                _EnumRename(
                    object_id=owner.get("id") if owner is not None else None,
                    location=source_location_from_xml_element(reference),
                    enum_class=parts[-2],
                    old=_spelled(parts[-2], parts[-1], new_class)[0],
                    new=_spelled(parts[-2], parts[-1], new_class)[1],
                    apply=partial(reference.set, "data", new_data),
                )
            )
        return renames

    def class_key_repairs(self, nodes: list[_Node]) -> list[_ClassKeyRepair]:
        # DEXPI XML names a class by its ``type``, which no attribute could shadow.
        return []

    def unwritable(self, owner: _Node) -> _Unwritable | None:
        # An ``Object`` element takes a ``<Components>`` whatever else it holds.
        return None

    def drop_unwritable(self, owner: _Node) -> None:
        return None


def _as_list(value: Any) -> list[Any]:
    if value is None:
        return []
    return list(value) if isinstance(value, list) else [value]


def json_class_name(obj: dict[str, Any]) -> str:
    """The class a pyDEXPI JSON object names: the last segment of its ``uri``."""
    uri = obj.get("uri")
    return uri.rsplit("/", 1)[-1] if isinstance(uri, str) else ""


def json_objects(obj: dict[str, Any]) -> list[dict[str, Any]]:
    """*obj* and every object composed below it in a pyDEXPI JSON value, in document order."""
    found = [obj]
    composition = obj.get("composition")
    if isinstance(composition, dict):
        for value in composition.values():
            for kid in _as_list(value):
                if isinstance(kid, dict):
                    found.extend(json_objects(kid))
    return found


class _JsonFormat:
    """A pyDEXPI JSON document: object dicts with ``composition`` and ``reference`` dicts."""

    kind = "JSON"

    def __init__(self, document: dict[str, Any]) -> None:
        self.document = document
        self._pointers: dict[int, str] = {}

    def index(self) -> list[_Node]:
        nodes: list[_Node] = []

        def visit(obj: dict[str, Any], parent: _Node | None, prop: str | None, at: str) -> _Node:
            object_id = obj.get("id")
            node = _Node(
                raw=obj,
                class_name=json_class_name(obj),
                id=object_id if isinstance(object_id, str) else None,
                parent=parent,
                parent_property=prop,
                order=len(nodes),
            )
            nodes.append(node)
            self._pointers[id(obj)] = at
            references = obj.get("reference")
            if isinstance(references, dict):
                node.references = [
                    (name, [i for i in _as_list(value) if isinstance(i, str)])
                    for name, value in references.items()
                ]
            composition = obj.get("composition")
            if isinstance(composition, dict):
                for name, value in composition.items():
                    where = join_json_pointer(at, "composition", name)
                    if isinstance(value, list):
                        kids = [
                            visit(kid, node, name, join_json_pointer(where, position))
                            for position, kid in enumerate(value)
                            if isinstance(kid, dict)
                        ]
                    elif isinstance(value, dict):
                        kids = [visit(value, node, name, where)]
                    else:
                        kids = []
                    node.children.append((name, kids))
            return node

        visit(self.document, None, None, "")
        return nodes

    def location(self, node: _Node) -> SourceLocation:
        return SourceLocation(
            element=node.class_name or None, xpath=self._pointers.get(id(node.raw)) or "/"
        )

    def objects(self, raw: dict[str, Any]) -> list[dict[str, Any]]:
        return json_objects(raw)

    def object_id(self, raw: dict[str, Any]) -> str | None:
        object_id = raw.get("id")
        return object_id if isinstance(object_id, str) else None

    def set_object_id(self, raw: dict[str, Any], new_id: str) -> None:
        raw["id"] = new_id

    def rewrite_references(self, raw: dict[str, Any], mapping: dict[str, str]) -> tuple[int, int]:
        internal = external = 0
        for obj in self.objects(raw):
            references = obj.get("reference")
            if not isinstance(references, dict):
                continue
            for name, value in references.items():
                targets = _as_list(value)
                if not targets:
                    continue
                # A target that is no string names no object: kept, for the loader to report.
                named = [target for target in targets if isinstance(target, str)]
                internal += sum(target in mapping for target in named)
                external += sum(target not in mapping for target in named)
                mapped = [
                    mapping.get(target, target) if isinstance(target, str) else target
                    for target in targets
                ]
                references[name] = mapped if isinstance(value, list) else mapped[0]
        return internal, external

    def clone(self, raw: dict[str, Any]) -> dict[str, Any]:
        return copy.deepcopy(raw)

    def serialize(self, raw: Any) -> str:
        return json.dumps(raw, ensure_ascii=False)

    def serialize_property(self, node: _Node, prop: str) -> str:
        return self.serialize(node.raw.get("composition", {}).get(prop))

    def rename_property(self, node: _Node, old: str, new: str) -> None:
        composition = node.raw["composition"]
        if new in composition:
            composition[new] = _as_list(composition[new]) + _as_list(composition.pop(old))
        else:
            node.raw["composition"] = {
                (new if name == old else name): value for name, value in composition.items()
            }

    def drop_property(self, node: _Node, prop: str) -> None:
        composition = node.raw.get("composition")
        if isinstance(composition, dict):
            composition.pop(prop, None)
            if not composition:
                del node.raw["composition"]

    def detach(self, node: _Node) -> None:
        if node.parent is None or node.parent_property is None:
            return
        composition = node.parent.raw.get("composition", {})
        value = composition.get(node.parent_property)
        if isinstance(value, list):
            composition[node.parent_property] = [kid for kid in value if kid is not node.raw]
        elif value is node.raw:
            del composition[node.parent_property]

    def attach(self, owner: _Node, prop: str, raw: dict[str, Any], single: bool) -> None:
        composition = owner.raw.get("composition")
        if not isinstance(composition, dict):
            composition = owner.raw["composition"] = {}
        composition[prop] = raw if single else [*_as_list(composition.get(prop)), raw]

    def remove_reference(self, owner: _Node, prop: str, target_id: str) -> None:
        references = owner.raw.get("reference")
        if not isinstance(references, dict) or prop not in references:
            return
        value = references[prop]
        if isinstance(value, list):
            remaining = list(value)
            if target_id in remaining:
                remaining.remove(target_id)
            if remaining:
                references[prop] = remaining
            else:
                del references[prop]
        elif value == target_id:
            del references[prop]
        if not references:
            del owner.raw["reference"]

    def remove_if_empty(self, owner: _Node, prop: str) -> None:
        composition = owner.raw.get("composition")
        # Only what holds nothing: ``null`` or an empty list. Any other value (0, false, "") is
        # no container, and stays for the loader to report.
        if (
            isinstance(composition, dict)
            and prop in composition
            and (composition[prop] is None or composition[prop] == [])
        ):
            del composition[prop]
            if not composition:
                del owner.raw["composition"]

    def enum_renames(self) -> list[_EnumRename]:
        return json_enum_renames(self.document)

    def class_key_repairs(self, nodes: list[_Node]) -> list[_ClassKeyRepair]:
        """Every object pyDEXPI's 2.0 writer left without its class (`ShadowedClassKey`).

        Such an object is as pyDEXPI wrote it, and nothing else: its class key is the value of
        the shadowed attribute -- ``null`` or absent when the attribute is not under ``data``,
        the same value when it is. An entry that names something else there is not one of
        these, and is left for the loader to report.
        """
        repairs: list[_ClassKeyRepair] = []
        for node in nodes:
            parent = node.parent
            if parent is None:
                continue
            for shadowed in SHADOWED_CLASS_KEYS:
                if node.parent_property != shadowed.prop:
                    continue
                if not in_family(parent.class_name, shadowed.owner):
                    continue
                raw = node.raw
                data = raw.get("data")
                stated = isinstance(data, dict) and shadowed.old in data
                key = raw.get("uri")
                if stated:
                    if key != data[shadowed.old] or shadowed.new in data:
                        continue
                elif key is not None:
                    continue
                repairs.append(
                    _ClassKeyRepair(
                        node,
                        shadowed,
                        json.dumps(key, ensure_ascii=False),
                        stated,
                        partial(self._repair_class_key, raw, shadowed, stated),
                    )
                )
        return repairs

    @staticmethod
    def _repair_class_key(raw: dict[str, Any], shadowed: ShadowedClassKey, stated: bool) -> None:
        raw["uri"] = getattr(pydexpi_classes, shadowed.cls).uri
        if stated:
            raw["data"] = {
                (shadowed.new if name == shadowed.old else name): value
                for name, value in raw["data"].items()
            }

    def unwritable(self, owner: _Node) -> _Unwritable | None:
        """What stands where *owner*'s compositions go, if it is no block to place one in.

        ``null`` and an absent block hold nothing, so `attach` starts a block there.
        """
        block = owner.raw.get("composition")
        if block is None or isinstance(block, dict):
            return None
        return _Unwritable(owner, describe_json_value(block), self.serialize(block))

    def drop_unwritable(self, owner: _Node) -> None:
        del owner.raw["composition"]


_QUALIFIED_UNIT = re.compile(r"(\w+)\.(\w+)")


def json_enum_renames(value: Any, at: str = "", object_id: str | None = None) -> list[_EnumRename]:
    """Every renamed-enumeration value in a pyDEXPI JSON value, and how to rename it in place.

    Covers ``{"__enum__": "PercentageUnit", "name": ...}``, as the JSON serializer writes an
    enumeration, and a qualified ``"unit": "PercentageUnit.<L>"`` spelling.
    """
    renames: list[_EnumRename] = []
    if isinstance(value, dict):
        own_id = value.get("id")
        if isinstance(own_id, str) and isinstance(value.get("uri"), str):
            object_id = own_id
        enum_class, member = value.get("__enum__"), value.get("name")
        if isinstance(enum_class, str) and isinstance(member, str):
            new_class = renamed_enum(enum_class, member)
            # The JSON loader looks an ``__enum__`` up by its exact member name, so only a name it
            # accepts is renamed; another is left as it is, for the loader to report.
            if new_class is not None and member in getattr(pydexpi_classes, new_class).__members__:
                renames.append(
                    _EnumRename(
                        object_id,
                        SourceLocation(element=enum_class, xpath=at or "/"),
                        enum_class,
                        *_spelled(enum_class, member, new_class),
                        partial(value.__setitem__, "__enum__", new_class),
                    )
                )
        unit = value.get("unit")
        if isinstance(unit, str) and (match := _QUALIFIED_UNIT.fullmatch(unit)):
            new_class = renamed_enum(match.group(1), match.group(2))
            if new_class is not None:
                renames.append(
                    _EnumRename(
                        object_id,
                        SourceLocation(element=match.group(1), xpath=join_json_pointer(at, "unit")),
                        match.group(1),
                        *_spelled(match.group(1), match.group(2), new_class),
                        partial(value.__setitem__, "unit", f"{new_class}.{match.group(2)}"),
                    )
                )
        for key, item in value.items():
            renames.extend(json_enum_renames(item, join_json_pointer(at, key), object_id))
    elif isinstance(value, list):
        for position, item in enumerate(value):
            renames.extend(json_enum_renames(item, join_json_pointer(at, position), object_id))
    return renames


# ---------------------------------------------------------------------------
# The conversion
# ---------------------------------------------------------------------------


class ConversionRefusedError(ValueError):
    """A strict load refused a DEXPI 2.0 document it cannot convert without copying or dropping.

    It is the exception of the CRITICAL registry entry that records the refusal; the public
    loaders raise it.

    Attributes
    ----------
    problems : list[str]
        Each offending object or reference, with what lenient loading does with it.
    object_ids : list[str]
        The ids involved, in the order reported.
    """

    def __init__(self, message: str, problems: list[str], object_ids: list[str]) -> None:
        super().__init__(message)
        self.problems = problems
        self.object_ids = object_ids


@dataclass(eq=False)
class _Slot:
    """A 2.0 reference from an owner that DEXPI 2.0.1 makes a composition."""

    owner: _Node
    change: OwnershipChange
    target_id: str


@dataclass(eq=False)
class _Owned:
    """An object that one or more owner slots claim."""

    node: _Node
    pooled: bool
    slots: list[_Slot] = field(default_factory=list)

    @property
    def shared(self) -> bool:
        """Two owners or more: two slots, or a slot and the owner already composing it."""
        return len(self.slots) > 1 or not self.pooled


@dataclass(eq=False)
class _Pass:
    """Everything one removed container's conversion does."""

    container: RemovedContainer
    pool_owners: list[_Node]
    owned: list[_Owned]
    unreferenced: list[_Node]
    blocked: list[tuple[_Slot, _Node]]
    redundant: list[_Slot]


def _describe(node: _Node) -> str:
    name = node.class_name or "object"
    return f"{name} {node.id!r}" if node.id is not None else f"an id-less {name}"


def _describe_slot(slot: _Slot) -> str:
    return f"{_describe(slot.owner)}.{slot.change.old}"


class _Conversion:
    """Plans the conversion of one parsed document, then applies or refuses it."""

    def __init__(self, fmt: _Format, *, strict: bool, registry: ErrorRegistry) -> None:
        self.fmt = fmt
        self.strict = strict
        self.registry = registry
        self.nodes = fmt.index()
        self.taken = {node.id for node in self.nodes if node.id is not None}
        self.by_id: dict[str, list[_Node]] = {}
        for node in self.nodes:
            if node.id is not None:
                self.by_id.setdefault(node.id, []).append(node)
        self._locations: dict[int, SourceLocation] = {}
        self.renames: list[tuple[_Node, PropertyRename]] = []
        self.enum_renames: list[_EnumRename] = []
        self.measured: list[tuple[_Node, ChangedKind]] = []
        self.passes: list[_Pass] = []
        self.externals: dict[int, list[tuple[_Node, str, str]]] = {}
        self.class_keys: list[_ClassKeyRepair] = []
        self.unwritable: list[_Unwritable] = []

    # -- planning ------------------------------------------------------------------------------

    def plan(self) -> bool:
        """Work out everything the conversion does, changing nothing. True if anything."""
        # First, so that every step below knows such an object by its class.
        self.class_keys = self.fmt.class_key_repairs(self.nodes)
        for repair in self.class_keys:
            repair.node.class_name = repair.shadowed.cls
        for node in self.nodes:
            present = node.child_properties()
            self.renames.extend(
                (node, rename)
                for rename in _DOCUMENT_RENAMES
                if rename.old in present and rename.applies_to(node.class_name)
            )
            self.measured.extend(
                (node, kind)
                for kind in CHANGED_KINDS
                if kind.prop in present and in_family(node.class_name, kind.family)
            )
        self.enum_renames = self.fmt.enum_renames()

        slots = self._slots()
        self.passes = [self._plan_pass(container, slots) for container in REMOVED_CONTAINERS]
        self._plan_externals(slots)
        self._plan_unwritable()

        # Locate everything that will be reported while the document is still as parsed.
        for node, _ in (*self.renames, *self.measured):
            self._where(node)
        for repair in self.class_keys:
            self._where(repair.node)
        for unwritable in self.unwritable:
            self._where(unwritable.owner)
        for conversion_pass in self.passes:
            for owned in conversion_pass.owned:
                self._where(owned.node)
            for node in conversion_pass.unreferenced:
                self._where(node)
            for slot, _ in conversion_pass.blocked:
                self._where(slot.owner)
            for slot in conversion_pass.redundant:
                self._where(slot.owner)
        for references in self.externals.values():
            for referrer, _, _ in references:
                self._where(referrer)

        return bool(
            self.renames
            or self.enum_renames
            or self.measured
            or self.class_keys
            or any(
                p.pool_owners or p.owned or p.unreferenced or p.blocked or p.redundant
                for p in self.passes
            )
        )

    def _where(self, node: _Node) -> SourceLocation:
        key = id(node)
        if key not in self._locations:
            self._locations[key] = self.fmt.location(node)
        return self._locations[key]

    def _slots(self) -> list[_Slot]:
        """Every 2.0 reference an ownership change applies to, in document order."""
        slots: list[_Slot] = []
        for node in self.nodes:
            for prop, targets in node.references:
                for change in OWNERSHIP_CHANGES:
                    if prop == change.old and in_family(node.class_name, change.owner):
                        slots.extend(_Slot(node, change, target) for target in targets)
        return slots

    def _plan_pass(self, container: RemovedContainer, slots: list[_Slot]) -> _Pass:
        pool_owners = []
        pool: list[_Node] = []
        for node in self.nodes:
            if not in_family(node.class_name, container.owner):
                continue
            for prop, kids in node.children:
                if prop == container.prop:
                    pool_owners.append(node)
                    pool.extend(kids)
        pooled = {id(node) for node in pool}

        owned: dict[int, _Owned] = {}
        blocked: list[tuple[_Slot, _Node]] = []
        redundant: list[_Slot] = []
        occupied = {
            (id(node), change.new)
            for node in self.nodes
            for change in OWNERSHIP_CHANGES
            if change.single and change.new in node.child_properties()
        }
        for slot in slots:
            if slot.change.owned != container.owned:
                continue
            candidates = [
                node
                for node in self.by_id.get(slot.target_id, [])
                if in_family(node.class_name, slot.change.owned)
            ]
            in_pool = [node for node in candidates if id(node) in pooled]
            target = in_pool[0] if in_pool else candidates[0] if candidates else None
            if target is None:
                # A dangling reference: left for the loader to report.
                continue
            if (
                target.parent is slot.owner
                and _current_name(slot.owner.class_name, target.parent_property) == slot.change.new
            ):
                redundant.append(slot)
                continue
            key = (id(slot.owner), slot.change.new)
            if slot.change.single and key in occupied:
                blocked.append((slot, target))
                continue
            if slot.change.single:
                occupied.add(key)
            entry = owned.setdefault(id(target), _Owned(target, pooled=id(target) in pooled))
            entry.slots.append(slot)
        unreferenced = [node for node in pool if id(node) not in owned]
        return _Pass(container, pool_owners, list(owned.values()), unreferenced, blocked, redundant)

    def _plan_unwritable(self) -> None:
        """The owners the passes place something in that have no block to place it in."""
        found: dict[int, _Unwritable] = {}
        for conversion_pass in self.passes:
            for owned in conversion_pass.owned:
                for slot in owned.slots:
                    key = id(slot.owner)
                    if key not in found:
                        unwritable = self.fmt.unwritable(slot.owner)
                        if unwritable is None:
                            continue
                        found[key] = unwritable
                    found[key].placed.append(owned.node)
        self.unwritable = list(found.values())

    def _members(self, node: _Node, conversion_pass: _Pass) -> list[_Node]:
        """What *node*'s subtree holds once the passes before this one are applied."""
        members = list(node.subtree())
        index = self.passes.index(conversion_pass)
        for earlier in self.passes[:index]:
            for placed in earlier.owned:
                first = placed.slots[0].owner if placed.pooled else placed.node.parent
                if any(first is member for member in members):
                    members.extend(placed.node.subtree())
        return members

    def _plan_externals(self, slots: list[_Slot]) -> None:
        """References into a shared object, or into one that is dropped, from outside it."""
        converted = {(id(slot.owner), slot.change.old, slot.target_id) for slot in slots}
        into: dict[str, list[tuple[_Node, str]]] = {}
        for node in self.nodes:
            for prop, targets in node.references:
                for target in targets:
                    if (id(node), prop, target) not in converted:
                        into.setdefault(target, []).append((node, prop))
        for conversion_pass in self.passes:
            subjects = [
                owned.node for owned in conversion_pass.owned if owned.shared
            ] + conversion_pass.unreferenced
            for subject in subjects:
                members = self._members(subject, conversion_pass)
                inside = {id(member) for member in members}
                found = [
                    (referrer, prop, member.id)
                    for member in members
                    if member.id is not None
                    for referrer, prop in into.get(member.id, [])
                    if id(referrer) not in inside
                ]
                if found:
                    self.externals[id(subject)] = found

    # -- reporting -------------------------------------------------------------------------------

    def markers(self) -> str:
        """The DEXPI 2.0 constructs found, for the inferred-version WARNING."""
        found: Counter[str] = Counter()
        for repair in self.class_keys:
            found[f"{repair.shadowed.cls} without its class"] += 1
        for _, rename in self.renames:
            found[f"{rename.family}.{rename.old}"] += 1
        for enum_rename in self.enum_renames:
            found[enum_rename.enum_class] += 1
        for conversion_pass in self.passes:
            container = conversion_pass.container
            if conversion_pass.pool_owners:
                found[f"model-level {container.owner}.{container.prop}"] += 1
            for owned in conversion_pass.owned:
                for slot in owned.slots:
                    found[f"{slot.change.owner}.{slot.change.old} as a reference"] += 1
        for _, kind in self.measured:
            found[f"{kind.family}.{kind.prop} as {kind.was}"] += 1
        return ", ".join(f"{name} ({count})" for name, count in found.items())

    def _report(
        self,
        level: ErrorLevels,
        message: str,
        node: _Node | None = None,
        *,
        object_id: str | None = None,
        location: SourceLocation | None = None,
        content: str | None = None,
        exception: Exception | None = None,
    ) -> None:
        where = location or (self._where(node) if node is not None else SourceLocation())
        self.registry.register_error(
            message=message,
            level=level,
            object_id=object_id if object_id is not None else (node.id if node else None),
            exception=exception,
            element=where.element,
            xpath=where.xpath,
            line=where.line,
            column=where.column,
            content=content,
        )

    def problems(self) -> tuple[list[str], list[str]]:
        """What strict loading refuses, and the ids involved."""
        problems: list[str] = []
        ids: list[str] = []
        for conversion_pass in self.passes:
            container = conversion_pass.container
            for owned in conversion_pass.owned:
                if not owned.shared:
                    continue
                sharers = [_describe_slot(slot) for slot in owned.slots]
                if not owned.pooled and owned.node.parent is not None:
                    sharers.insert(
                        0, f"{_describe(owned.node.parent)}.{owned.node.parent_property}"
                    )
                problems.append(
                    f"{_describe(owned.node)} is shared by {', '.join(sharers)}, and DEXPI 2.0.1 "
                    f"composes a {container.owned} in exactly one of them; lenient loading keeps "
                    f"it with the first and copies it, with new ids, for each other"
                )
                ids.append(owned.node.id or "")
                ids.extend(slot.owner.id or "" for slot in owned.slots)
                for referrer, prop, target in self.externals.get(id(owned.node), []):
                    problems.append(
                        f"{_describe(referrer)}.{prop} refers to {target!r} in the shared "
                        f"{_describe(owned.node)}; lenient loading keeps it on the original"
                    )
                    ids.append(referrer.id or "")
            for node in conversion_pass.unreferenced:
                problems.append(
                    f"{_describe(node)} in the model-level {container.prop} is claimed by no "
                    f"owner, and DEXPI 2.0.1 composes a {container.owned} only in one; lenient "
                    f"loading drops it, recording its content"
                )
                ids.append(node.id or "")
            for slot, claimed in conversion_pass.blocked:
                problems.append(
                    f"{_describe_slot(slot)} refers to {_describe(claimed)}, but "
                    f"{_describe(slot.owner)} already composes a {slot.change.new}; lenient "
                    f"loading drops the reference"
                )
                ids.append(slot.owner.id or "")
        for unwritable in self.unwritable:
            placed = ", ".join(_describe(node) for node in unwritable.placed)
            problems.append(
                f"{_describe(unwritable.owner)} has {unwritable.kind} where its compositions go, "
                f"not a block to compose {placed} in, as DEXPI 2.0.1 does; lenient loading "
                f"drops what stands there, recording it: {unwritable.content}"
            )
            ids.append(unwritable.owner.id or "")
        for node, kind in self.measured:
            value = self.fmt.serialize_property(node, kind.prop)
            problems.append(
                f"{_describe(node)}.{kind.prop} holds {kind.was}, which {kind.by} replaced by "
                f"{kind.now} with no mapping between them; lenient loading drops the value, "
                f"recording it: {value}"
            )
            ids.append(node.id or "")
        return problems, [i for i in ids if i]

    # -- applying --------------------------------------------------------------------------------

    def apply(self) -> bool:
        """Convert the document in place, or refuse it. False when refused."""
        problems, ids = self.problems()
        if self.strict and problems:
            listed = "".join(f"\n- {problem}." for problem in problems)
            message = (
                f"Not loaded: this DEXPI 2.0 {self.fmt.kind} document holds {len(problems)} "
                f"thing(s) DEXPI 2.0.1 cannot represent without copying or dropping data, which "
                f"strict loading refuses:{listed}\nLoad it with strict=False (--lenient on the "
                f"command line) to convert it as said; every copy and drop is then recorded in "
                f"the error registry."
            )
            self._report(
                ErrorLevels.CRITICAL,
                message,
                location=SourceLocation(),
                exception=ConversionRefusedError(message, problems, ids),
            )
            return False

        for repair in self.class_keys:
            repair.apply()
            shadowed = repair.shadowed
            shadowed_class = getattr(pydexpi_classes, shadowed.cls)
            renamed = (
                f" The attribute, written as {shadowed.old!r} under its data too, is read as "
                f"{shadowed.new!r}, its field name since."
                if repair.renames
                else ""
            )
            self._report(
                ErrorLevels.INFO,
                f"{_describe(repair.node)}: read as a {shadowed.cls}, which every object of a "
                f"{shadowed.owner}'s {shadowed.prop!r} is. Its JSON names no class: older "
                f"pyDEXPI wrote the value of the {shadowed.cls}'s DEXPI attribute "
                f"{dexpi_attribute_name(shadowed_class, shadowed.new)} where the class goes, here "
                f"{repair.written}.{renamed}",
                repair.node,
            )
        for unwritable in self.unwritable:
            self.fmt.drop_unwritable(unwritable.owner)
            placed = ", ".join(_describe(node) for node in unwritable.placed)
            self._report(
                ErrorLevels.ERROR,
                f"{_describe(unwritable.owner)}: dropped what stands where its compositions "
                f"go, {unwritable.kind} and no block to compose {placed} in, as DEXPI 2.0.1 "
                f"does. What stood there is this entry's content.",
                unwritable.owner,
                content=unwritable.content,
            )
        for node, rename in self.renames:
            self.fmt.rename_property(node, rename.old, rename.new)
            self._report(
                ErrorLevels.INFO,
                f"{_describe(node)}: DEXPI 2.0 property {rename.old!r} read as {rename.new!r}, "
                f"its DEXPI 2.0.1 name.",
                node,
            )
        for enum_rename in self.enum_renames:
            enum_rename.apply()
            self._report(
                ErrorLevels.INFO,
                f"DEXPI 2.0 value {enum_rename.old!r} read as {enum_rename.new!r}: DEXPI 2.0.1 "
                f"renamed {enum_rename.enum_class} to "
                f"{ENUM_CLASS_RENAMES[enum_rename.enum_class]}.",
                object_id=enum_rename.object_id,
                location=enum_rename.location,
            )
        for conversion_pass in self.passes:
            self._apply_pass(conversion_pass)
        for node, kind in self.measured:
            # Recorded as dropped: renames applied, so it reads as DEXPI 2.0.1 would hold it.
            value = self.fmt.serialize_property(node, kind.prop)
            self.fmt.drop_property(node, kind.prop)
            self._report(
                ErrorLevels.ERROR,
                f"{_describe(node)}: dropped its DEXPI 2.0 {kind.prop!r}, {kind.was}, because "
                f"{kind.by} replaced it by {kind.now} with no mapping between them. The value "
                f"is this entry's content.",
                node,
                content=value,
            )
        for conversion_pass in self.passes:
            for owner in conversion_pass.pool_owners:
                self.fmt.remove_if_empty(owner, conversion_pass.container.prop)
        return True

    def _apply_pass(self, conversion_pass: _Pass) -> None:
        container = conversion_pass.container
        for slot in conversion_pass.redundant:
            self.fmt.remove_reference(slot.owner, slot.change.old, slot.target_id)
            self._report(
                ErrorLevels.INFO,
                f"{_describe_slot(slot)}: dropped the DEXPI 2.0 reference to {slot.target_id!r}, "
                f"which {_describe(slot.owner)} already composes.",
                slot.owner,
            )
        for slot, claimed in conversion_pass.blocked:
            self.fmt.remove_reference(slot.owner, slot.change.old, slot.target_id)
            self._report(
                ErrorLevels.ERROR,
                f"{_describe_slot(slot)}: dropped the DEXPI 2.0 reference to {_describe(claimed)}: "
                f"DEXPI 2.0.1 composes at most one {slot.change.new}, and "
                f"{_describe(slot.owner)} already has one.",
                slot.owner,
            )
        for owned in conversion_pass.owned:
            copies = owned.slots
            if owned.pooled:
                first, copies = owned.slots[0], owned.slots[1:]
                self.fmt.detach(owned.node)
                self.fmt.attach(first.owner, first.change.new, owned.node.raw, first.change.single)
                self.fmt.remove_reference(first.owner, first.change.old, first.target_id)
                owned.node.parent, owned.node.parent_property = first.owner, first.change.new
                self._report(
                    ErrorLevels.INFO,
                    f"{_describe(owned.node)}: moved from the model-level {container.prop}, "
                    f"which DEXPI 2.0.1 removed, into {_describe_slot(first)}, a reference in "
                    f"DEXPI 2.0 and a composition ({first.change.new!r}) in 2.0.1. Its id is kept.",
                    owned.node,
                )
            for slot in copies:
                self._copy(owned, slot)
            keeper = _describe(owned.node.parent) if owned.node.parent is not None else "its owner"
            for referrer, prop, target in self.externals.get(id(owned.node), []):
                self._report(
                    ErrorLevels.WARNING,
                    f"{_describe(referrer)}.{prop} refers to {target!r} in "
                    f"{_describe(owned.node)}, which is shared and so copied for its other "
                    f"owners; it keeps referring to the original, composed by {keeper}.",
                    referrer,
                )
        for node in conversion_pass.unreferenced:
            # Recorded as dropped: renames applied, and with whatever an earlier pass placed in it
            # -- a state type no state claims takes the composition it claimed along.
            content = self.fmt.serialize(node.raw)
            self.fmt.detach(node)
            dangling = self.externals.get(id(node), [])
            also = (
                " It is also referred to by "
                + ", ".join(f"{_describe(referrer)}.{prop}" for referrer, prop, _ in dangling)
                + ", which no longer resolve."
                if dangling
                else ""
            )
            self._report(
                ErrorLevels.ERROR,
                f"{_describe(node)}: dropped from the model-level {container.prop}, which DEXPI "
                f"2.0.1 removed. No owner claims it, and 2.0.1 composes a {container.owned} only "
                f"in one, so it has nowhere to go.{also} Its content is this entry's content.",
                node,
                content=content,
            )

    def _copy(self, owned: _Owned, slot: _Slot) -> None:
        """Copy *owned*'s whole subtree, with new ids, into the owner slot *slot*."""
        owner_key = slot.owner.id if slot.owner.id is not None else slot.owner.class_name
        originals = self.fmt.objects(owned.node.raw)
        new_ids: list[str | None] = []
        mapping: dict[str, str] = {}
        for original in originals:
            original_id = self.fmt.object_id(original)
            if original_id is None:
                new_ids.append(None)
                continue
            new_id = schema_safe_id(f"{original_id}__{owner_key}", self.taken)
            new_ids.append(new_id)
            mapping.setdefault(original_id, new_id)
        clone = self.fmt.clone(owned.node.raw)
        for copied, copied_id in zip(self.fmt.objects(clone), new_ids, strict=True):
            if copied_id is not None:
                self.fmt.set_object_id(copied, copied_id)
        internal, external = self.fmt.rewrite_references(clone, mapping)
        self.fmt.attach(slot.owner, slot.change.new, clone, slot.change.single)
        self.fmt.remove_reference(slot.owner, slot.change.old, slot.target_id)
        keeper = owned.slots[0] if owned.pooled else None
        kept_by = (
            _describe_slot(keeper)
            if keeper is not None
            else f"{_describe(owned.node.parent)}.{owned.node.parent_property}"
            if owned.node.parent is not None
            else "its first owner"
        )
        pairs = ", ".join(
            f"{self.fmt.object_id(original)} -> {new_id}"
            for original, new_id in zip(originals, new_ids, strict=True)
            if new_id is not None
        )
        self._report(
            ErrorLevels.WARNING,
            f"{_describe(owned.node)} is shared, and DEXPI 2.0.1 composes it in one owner: "
            f"{kept_by} keeps it, and {_describe_slot(slot)} gets a copy of it and everything it "
            f"composes, with new ids: {pairs or 'none, as nothing in it has one'}. "
            f"{internal} reference(s) inside the copy now point at the copies; {external} "
            f"leaving it are unchanged.",
            owned.node,
            object_id=mapping.get(owned.node.id or "") or owned.node.id,
        )


def _upgrade(
    fmt: _Format, version: DocumentVersion, *, strict: bool, registry: ErrorRegistry
) -> bool:
    if version.unreadable:
        registry.register_error(
            f"The document {version.evidence}, which is not one DEXPI version pyDEXPI reads; it "
            f"is read as DEXPI {DEXPI_2_0_1}, or as {DEXPI_2_0} if it holds a construct only "
            f"DEXPI 2.0 has.",
            level=ErrorLevels.WARNING,
        )
    if version.declared == DEXPI_2_0_1:
        return True
    conversion = _Conversion(fmt, strict=strict, registry=registry)
    if not conversion.plan():
        return True
    if version.declared is None:
        registry.register_error(
            f"The document {version.evidence}. It is read as DEXPI {DEXPI_2_0} and converted to "
            f"{DEXPI_2_0_1}, as inferred from what it holds: {conversion.markers()}.",
            level=ErrorLevels.WARNING,
        )
    return conversion.apply()


def upgrade_xml_document(top: etree._Element, *, strict: bool, registry: ErrorRegistry) -> bool:
    """Convert a parsed DEXPI XML document to DEXPI 2.0.1 in place, if it is DEXPI 2.0.

    Parameters
    ----------
    top : etree._Element
        The document's top-level ``Object``; its parent, the ``Model``, holds the ``<Import>``s.
    strict : bool
        Whether to refuse a document that cannot be converted without copying or dropping data.
    registry : ErrorRegistry
        Where every conversion step, or the refusal, is reported.

    Returns
    -------
    bool
        True when the document can be built: converted, or nothing to convert. False when it is
        refused; the CRITICAL registry entry says why.
    """
    return _upgrade(
        _XmlFormat(top), xml_document_version(top.getparent()), strict=strict, registry=registry
    )


def upgrade_json_document(
    document: dict[str, Any], *, strict: bool, registry: ErrorRegistry
) -> bool:
    """Convert a decoded pyDEXPI JSON document to DEXPI 2.0.1 in place, if it is DEXPI 2.0.

    As :func:`upgrade_xml_document`, for the root object of a JSON document.
    """
    return _upgrade(
        _JsonFormat(document), json_document_version(document), strict=strict, registry=registry
    )


def _reading_version(fmt: _Format, version: DocumentVersion) -> DocumentVersion:
    if version.declared is not None:
        return version
    conversion = _Conversion(fmt, strict=True, registry=ErrorRegistry())
    if conversion.plan():
        return DocumentVersion(
            DEXPI_2_0, f"{version.evidence}, and holds {conversion.markers()}", version.unreadable
        )
    return DocumentVersion(
        DEXPI_2_0_1,
        f"{version.evidence}, and holds nothing only DEXPI 2.0 has",
        version.unreadable,
    )


def xml_reading_version(top: etree._Element) -> DocumentVersion:
    """The version a DEXPI XML document is read as: the declared one, else the inferred one.

    Changes nothing; for a caller that has to know before loading, such as ``convert --fast``,
    which rewrites a document without converting it.
    """
    return _reading_version(_XmlFormat(top), xml_document_version(top.getparent()))


def json_reading_version(document: dict[str, Any]) -> DocumentVersion:
    """As :func:`xml_reading_version`, for a decoded pyDEXPI JSON document."""
    return _reading_version(_JsonFormat(document), json_document_version(document))
