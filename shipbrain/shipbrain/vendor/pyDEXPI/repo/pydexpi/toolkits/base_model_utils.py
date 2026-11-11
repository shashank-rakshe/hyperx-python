"""This module contains utility functions for pydexpi base models. Becasue these
are the common parents to the pydexpi classes, these are basic, overarching
functionalities for all dexpi classes."""

import importlib
import inspect
import pkgutil
import re
from collections.abc import Mapping
from enum import Enum
from functools import cache
from types import MappingProxyType

from pydantic_core import PydanticUndefined

import pydexpi.pydexpi_classes as root
from pydexpi.pydexpi_classes import PyDexpiBaseModel, PyDexpiDataTypeBaseModel, pydexpi_classes
from pydexpi.pydexpi_classes.core import diagram as core_diagram
from pydexpi.pydexpi_classes.plant import diagram as plant_diagram


def get_composition_attributes(dexpi_object: PyDexpiBaseModel) -> dict:
    """
    Retrieve attributes from a DEXPI object with the 'composition' attribute category.

    Parameters
    ----------
    dexpi_object : PyDexpiBaseModel
        An instance of a DEXPI model from which composition attributes are extracted.

    Returns
    -------
    dict
        A dictionary where the keys are field names and the values are the corresponding
        field values with the '"composition"' category."""
    return _get_attributes_with_category(dexpi_object, "composition")


def get_reference_attributes(dexpi_object: PyDexpiBaseModel) -> dict:
    """
    Retrieve attributes from a DEXPI object with the 'reference' attribute category.

    Parameters
    ----------
    dexpi_object : PyDexpiBaseModel
        An instance of a DEXPI model from which reference attributes are extracted.

    Returns
    -------
    dict
        A dictionary where the keys are field names and the values are the corresponding
        field values with the '"reference"' category."""
    return _get_attributes_with_category(dexpi_object, "reference")


def get_data_attributes(dexpi_object: PyDexpiBaseModel) -> dict:
    """
    Retrieve attributes from a DEXPI object with the 'data' attribute category.

    Parameters
    ----------
    dexpi_object : PyDexpiBaseModel
        An instance of a DEXPI model from which data attributes are extracted.

    Returns
    -------
    dict
        A dictionary where the keys are field names and the values are the corresponding
        field values with the '"data"' category."""
    return _get_attributes_with_category(dexpi_object, "data")


def _get_attributes_with_category(
    dexpi_object: PyDexpiBaseModel | PyDexpiDataTypeBaseModel, category: str
) -> dict:
    """
    Retrieve a dictionary of field names and their values from a dexpi_object
    based on the attribute_category annotation in the 'json_schema_extra'.

    This function iterates over the fields of the given dexpi_object,
    checks the 'json_schema_extra' metadata for a key '"attribute_category"',
    and includes the field in the output dictionary if its value matches the
    provided attribute category.

    Parameters
    ----------
    dexpi_object : PyDexpiBaseModel | PyDexpiDataTypeBaseModel
        A pydexpi object from which attributes are extracted.
    category : str
        The value of the '"attribute_category"' to filter the fields by.

    Returns
    -------
    dict
        A dictionary where the keys are field names and the values are the
        corresponding field values from the model, filtered by the given
        annotation.
    """

    attribute_dict = {}
    for fld_name, field in dexpi_object.__class__.model_fields.items():
        if (
            field.json_schema_extra is not None
            and "attribute_category" in field.json_schema_extra
            and field.json_schema_extra["attribute_category"] == category
        ):
            attribute_dict[fld_name] = getattr(dexpi_object, fld_name)
    return attribute_dict


def get_composition_attributes_from_class(
    dexpi_class: type[PyDexpiBaseModel | PyDexpiDataTypeBaseModel],
) -> set[str]:
    """Return names of composition attributes for a DEXPI class.

    Parameters
    ----------
    dexpi_class : type[PyDexpiBaseModel | PyDexpiDataTypeBaseModel]
        The class to inspect.

    Returns
    -------
    set[str]
        Set of field names categorized as composition attributes.
    """
    return _get_attribute_names_with_category_from_class(dexpi_class, "composition")


def get_reference_attributes_from_class(
    dexpi_class: type[PyDexpiBaseModel | PyDexpiDataTypeBaseModel],
) -> set[str]:
    """Return names of reference attributes for a DEXPI class.

    Parameters
    ----------
    dexpi_class : type[PyDexpiBaseModel | PyDexpiDataTypeBaseModel]
        The class to inspect.

    Returns
    -------
    set[str]
        Set of field names categorized as reference attributes.
    """
    return _get_attribute_names_with_category_from_class(dexpi_class, "reference")


def get_data_attributes_from_class(
    dexpi_class: type[PyDexpiBaseModel | PyDexpiDataTypeBaseModel],
) -> set[str]:
    """Return names of data attributes for a DEXPI class.

    Parameters
    ----------
    dexpi_class : type[PyDexpiBaseModel | PyDexpiDataTypeBaseModel]
        The class to inspect.

    Returns
    -------
    set[str]
        Set of field names categorized as data attributes.
    """
    return _get_attribute_names_with_category_from_class(dexpi_class, "data")


def _get_attribute_names_with_category_from_class(
    dexpi_class: type[PyDexpiBaseModel | PyDexpiDataTypeBaseModel], category: str
) -> set[str]:
    """Return the set of field names on a DEXPI (data type) class for a category.

    Parameters
    ----------
    dexpi_class : type[PyDexpiBaseModel | PyDexpiDataTypeBaseModel]
        The DEXPI model (or data type) class whose fields will be inspected.
    category : str
        Attribute category (e.g. ``"composition"``, ``"reference"``, ``"data"``) to filter by.

    Returns
    -------
    set[str]
        A set containing the names of all fields whose ``json_schema_extra['attribute_category']``
        equals the provided category.
    """
    names: set[str] = set()
    for fld_name, field in dexpi_class.model_fields.items():
        extra = field.json_schema_extra
        if extra and extra.get("attribute_category") == category:
            names.add(fld_name)
    return names


@cache
def dexpi_attribute_names(dexpi_class: type) -> Mapping[str, str]:
    """``{field name: DEXPI attribute name}`` for the fields whose DEXPI name is not derived.

    A field's DEXPI name is normally its own with the first letter raised (``tagName`` is
    ``TagName``). The class generator departs from that only where the derived field name is
    reserved: DEXPI's ``Role.Uri`` would have been a field ``uri``, which removes the ``uri``
    ClassVar every class is resolved by, so it is the field ``uri_``
    (in pyDEXPI-builder). The generator records the DEXPI name in the field's
    ``json_schema_extra["dexpi_name"]``, and this reads it back, so the mapping is generated
    metadata rather than a table kept by hand.

    Parameters
    ----------
    dexpi_class : type
        A generated class. Anything without ``model_fields`` has no renamed fields.

    Returns
    -------
    Mapping[str, str]
        Only the renamed fields; empty for almost every class.
    """
    fields = getattr(dexpi_class, "model_fields", None) or {}
    return MappingProxyType(
        {
            name: extra["dexpi_name"]
            for name, info in fields.items()
            if isinstance(extra := info.json_schema_extra, dict)
            and isinstance(extra.get("dexpi_name"), str)
        }
    )


def dexpi_attribute_name(dexpi_class: type | None, field_name: str) -> str:
    """The DEXPI name a field of `dexpi_class` is written under.

    The name :func:`dexpi_attribute_names` records for a renamed field (``Role.uri_`` is
    ``Uri``), or else the derived one: the first character of every underscore-separated
    segment raised, so ``tagName`` is ``TagName`` and ``chEBI_identifier`` is
    ``ChEBI_Identifier``. The derivation is the exact inverse of the XML loader's
    ``DexpiXmlDeserializationElement._pascal_to_camel_case``.

    The DEXPI XML export writes every attribute under this name, and it is the spelling an
    ``AttributeRepresentation`` fragment of a label should store, so a label made from
    ``"tagName"`` reads ``TagName`` as an imported one does. Nothing else would catch the
    difference: the schema accepts any string there.

    Parameters
    ----------
    dexpi_class : type | None
        The generated class the field belongs to. None, or a class without ``model_fields``,
        has no renamed fields, so the name is derived.
    field_name : str
        The pydantic field name.

    Returns
    -------
    str
        The DEXPI attribute name.
    """
    renamed = dexpi_attribute_names(dexpi_class).get(field_name)
    if renamed is not None:
        return renamed
    return "_".join(
        segment[0].upper() + segment[1:] if segment else segment
        for segment in field_name.split("_")
    )


@cache
def get_dexpi_class_from_uri(uri: str) -> type[PyDexpiBaseModel]:
    """
    Retrieve a DEXPI class from its URI.

    Results are cached. The lookup is a linear scan over every DEXPI class, and
    it runs once per deserialized object -- JSON identifies an object's class by
    its URI -- so the scan dominated loading for anything but a small model.
    Failed lookups raise and are not cached, so an unknown URI is re-scanned and
    keeps raising rather than being remembered as a negative result.

    Parameters
    ----------
    uri : str
        The URI of the DEXPI class to retrieve.

    Returns
    -------
    PyDexpiBaseModel
        The DEXPI class corresponding to the given URI.

    Raises
    ------
    AttributeError
        If no DEXPI class declares the given URI. That includes a *uri* that is no string:
        most of what `pydexpi_classes` exports declares no URI at all, and ``None`` used to
        match the first such name, the enumeration ``AreaUnit``.
    TypeError
        If *uri* is not hashable (a list or a dict read from a malformed document): the cache
        refuses it before the lookup runs.
    """
    if isinstance(uri, str):
        for submodule_name in dir(pydexpi_classes):
            submodule = getattr(pydexpi_classes, submodule_name)
            if getattr(submodule, "uri", None) == uri:
                return submodule
    raise AttributeError(f"Class with uri {uri!r} not a DEXPI class.")


def attribute_is_required(dexpi_class: type[PyDexpiBaseModel], attribute_name: str) -> bool:
    """Check if an attribute of a DEXPI class is required.

    This method retrieves the field information for the specified attribute. If there is no
    default factory specified for the field, it is considered required.

    Parameters
    ----------
    dexpi_class : type[PyDexpiBaseModel]
        The DEXPI class to check.
    attribute_name : str
        The name of the attribute to check.

    Returns
    -------
    bool
        True if the attribute is required, False otherwise.
    """
    field_info = dexpi_class.model_fields.get(attribute_name)
    if field_info is None:
        raise AttributeError(
            f"Attribute {attribute_name} not found in class {dexpi_class.__name__}."
        )
    return bool(field_info.default is PydanticUndefined and not field_info.default_factory)


def absent_required_attributes(dexpi_object: PyDexpiBaseModel) -> list[str]:
    """The required attributes of an object that hold no value.

    Validation refuses ``None`` for a required attribute, so an object built or changed through
    validation has none. Two things leave one anyway. A ``strict=False`` load keeps an object
    whose document omits a mandatory attribute, and registers an error for it. And code that
    assigns past validation, as the lenient loader does, can write ``None`` to a required
    attribute without a report. This finds them afterwards, in either case: a document
    written from such an object loses it on a strict load.

    Parameters
    ----------
    dexpi_object : PyDexpiBaseModel
        The object to check. Only its own attributes are checked, not those of its children.

    Returns
    -------
    list[str]
        The names of its required attributes holding ``None``, in field order.
    """
    cls = type(dexpi_object)
    values = dexpi_object.__dict__
    return [
        name
        for name in cls.model_fields
        if values.get(name) is None and attribute_is_required(cls, name)
    ]


def resolve_enum_member(enum_class: type[Enum], value: str | int) -> Enum:
    """Resolve an enum member from a string or integer value.

    This function attempts to convert the provided value to an integer and
    retrieve the corresponding enum member by index. If the conversion fails,
    it treats the value as a string and retrieves the enum member by name.

    Parameters
    ----------
    enum_class : type[Enum]
        The enumeration class to resolve the member from.
    value : str | int
        The value to resolve, either as a string (name) or integer (index).

    Returns
    -------
    Enum
        The resolved enum member.

    Raises
    ------
    IndexError
        If *value* is an integer index outside the range of *enum_class*.
        Negative indices are rejected rather than wrapping around to the end
        of the member list, so that an out-of-range index is always loud.
    ValueError
        If *value* is neither an integer index nor a valid member value.
    """
    try:
        integer_value = int(value)
    except ValueError:
        return enum_class(value)

    enum_members = list(enum_class)
    # Guard the negative case explicitly: list indexing accepts it and counts
    # from the end, so `-1` would silently resolve to the last member. Proteus
    # documents from legacy CAD exporters use `-1` as a conventional "true".
    if integer_value < 0:
        raise IndexError(
            f"Negative enum index {integer_value} is not a valid member index "
            f"for {enum_class.__name__}."
        )
    return enum_members[integer_value]


@cache
def get_dexpi_package_mapping() -> Mapping[str, str]:
    """Get a mapping of DEXPI class names to their full DEXPI package paths.

    The mapping is derived by importing every module under
    ``pydexpi.pydexpi_classes`` and recording, for each class it exposes, the
    dotted package path that DEXPI XML uses to name its type::

        "Boiling"       -> "Process.Process.Boiling"
        "AgitatorRotor" -> "Plant.ProcessEquipment.AgitatorRotor"

    The walk is expensive and its result cannot change within a process --
    pyDEXPI's classes are statically declared, nothing is reloaded and no class
    is created at runtime -- so the mapping is built on first use and cached.
    It was previously rebuilt on every call, once per serialized object, which
    made DEXPI XML export of the reference P&ID take ~4.0 s instead of ~0.08 s.

    Because every caller now shares one object, the returned mapping is
    read-only; take a ``dict(...)`` copy to modify one. Mutating it used to be
    a silent no-op, since the next call rebuilt it from scratch.
    ``get_dexpi_package_mapping.cache_clear()`` forces a rebuild, which is only
    needed by a test that has patched the ``pydexpi.pydexpi_classes`` namespace.

    Returns
    -------
    Mapping[str, str]
        Read-only mapping from class name to its dotted DEXPI package path.
    """
    mapping = {}

    for modinfo in pkgutil.walk_packages(root.__path__, root.__name__ + "."):
        module = importlib.import_module(modinfo.name)

        if modinfo.name.endswith("pydexpi_classes"):
            continue

        # Get all classes defined in the module
        classes = [name for name, obj in vars(module).items() if inspect.isclass(obj)]

        parts = modinfo.name.split(".")[
            2:
        ]  # Skip the first two segments (root package and pydexpi_classes)
        parts = [part[0].upper() + part[1:] for part in parts]
        for class_name in classes:
            mapping[class_name] = ".".join([*parts, class_name])

    return MappingProxyType(mapping)


def get_inheritance_from_dexpi_class(source: type[PyDexpiBaseModel]) -> list[type]:
    """Get inheritance chain from a PyDexpiBaseModel class.

    This method extracts the inheritance hierarchy from a PyDexpiBaseModel class,
    returning the class types in the inheritance chain.

    Parameters
    ----------
    source : type[PyDexpiBaseModel]
        A PyDexpiBaseModel class (not an instance)

    Returns
    -------
    list[type]
        List of class types in the inheritance chain, excluding base classes
        like PyDexpiBaseModel, ABC, and BaseModel

    """
    class_hierarchy = []

    def _gather_base_classes(cls):
        """Recursively gather base classes until reaching pydexpi base models"""
        if cls.__name__ in (
            "PyDexpiBaseModel",
            "PyDexpiDataTypeBaseModel",
            "PyDexpiSingletonBaseModel",
        ):
            return
        if cls not in class_hierarchy:
            class_hierarchy.append(cls)
        for base in cls.__bases__:
            _gather_base_classes(base)

    _gather_base_classes(source)
    return class_hierarchy


def type_from_name(class_name: str) -> type[PyDexpiBaseModel] | type[PyDexpiDataTypeBaseModel]:
    """Retrieve a pydexpi type from  a class name.

    Parameters
    ----------
    class_name : str
        The name of the class to retrieve

    Returns
    -------
    type[PyDexpiBaseModel] | type[PyDexpiDataTypeBaseModel]
        Handle to the pyDEXPI class with name class_name.
    """
    return getattr(pydexpi_classes, class_name)


def is_graphics_type(pydexpi_class: str | type[PyDexpiBaseModel]) -> bool:
    """Checks if a pydexpi class is a graphics/diagram-related type.

    Parameters
    ----------
    pydexpi_class : str | type[PyDexpiBaseModel]
        The name or class handle of the PyDexpiClass to examine.

    Returns
    -------
    bool
        True if the class is a graphics/diagram related type, False if it is conceptual.
    """
    if not isinstance(pydexpi_class, str):
        pydexpi_class = pydexpi_class.__name__

    return hasattr(core_diagram, pydexpi_class) or hasattr(plant_diagram, pydexpi_class)


#: The shape of the ids ``pydexpi_classes.make_id`` mints for objects that were given none.
_GENERATED_ID = re.compile(r"id_[0-9a-f]{32}")


def is_generated_id(value: object) -> bool:
    """Return ``True`` if *value* has the shape of an id minted by ``make_id``.

    A generated id says nothing about *where* the object came from, only that no id was supplied
    when it was built. What that means for stability depends on the caller: an object loaded from
    a file without an id gets a fresh one on every load, while an object created in code
    keeps the id it was minted with once the model is saved as JSON. This function answers
    the shape question only; deciding whether to trust such an id is the caller's call.

    Parameters
    ----------
    value : object
        The value to examine, normally an object's ``id``.

    Returns
    -------
    bool
        ``True`` for strings of the form ``id_<32 lowercase hex digits>``.
    """
    return isinstance(value, str) and _GENERATED_ID.fullmatch(value) is not None
