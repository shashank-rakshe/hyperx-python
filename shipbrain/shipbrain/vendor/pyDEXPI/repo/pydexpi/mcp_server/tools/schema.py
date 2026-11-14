"""Schema tools — let clients discover DEXPI class names, attributes, and enum values.

A client that works with DEXPI class names and attribute names has no other way to learn which names
are valid. These tools expose the pyDEXPI class catalog: which classes exist, how they inherit,
which attributes they carry, and which values an enum or a physical-quantity attribute accepts.
"""

from __future__ import annotations

import inspect
import json
import types
import typing
from enum import Enum
from typing import Any, ForwardRef, Literal

from pydexpi.mcp_server.errors import ErrorCode, error_response
from pydexpi.mcp_server.serialization import paginate, pagination_error
from pydexpi.pydexpi_classes import pydexpi_classes
from pydexpi.pydexpi_classes.pydexpi_classes import (
    Port,
    PortDirection,
    PyDexpiBaseModel,
    PyDexpiDataTypeBaseModel,
    Undefined,
)
from pydexpi.pydexpi_classes.unit_resolution import iter_unit_members, qualified_unit_name
from pydexpi.toolkits.base_model_utils import get_dexpi_package_mapping
from pydexpi.toolkits.docstrings import first_sentence
from pydexpi.toolkits.process_toolkit import (
    connection_class_for_port,
    default_role,
    is_abstract_process_class,
    role_names_for,
)
from pydexpi.toolkits.qualified_values import binding_of

#: Enums with more members than this are not inlined into an attribute
#: description; ``describe_dexpi_class`` on the enum lists them.
_MAX_INLINE_ENUM_VALUES = 30

ClassKind = Literal["class", "datatype", "enum"]


def _build_class_catalog() -> dict[str, type]:
    """Map every DEXPI class and enum name to its Python class."""
    catalog: dict[str, type] = {}
    for name in get_dexpi_package_mapping():
        obj = getattr(pydexpi_classes, name, None)
        if not inspect.isclass(obj):
            continue
        if issubclass(obj, Enum) or (
            issubclass(obj, PyDexpiBaseModel | PyDexpiDataTypeBaseModel) and obj is not Undefined
        ):
            catalog[name] = obj
    return dict(sorted(catalog.items()))


CLASS_CATALOG: dict[str, type] = _build_class_catalog()


def _kind(cls: type) -> ClassKind:
    if issubclass(cls, Enum):
        return "enum"
    if issubclass(cls, PyDexpiDataTypeBaseModel):
        return "datatype"
    return "class"


def _own_doc(cls: type) -> str:
    """The class's own docstring, never one inherited from a base class."""
    return inspect.cleandoc(cls.__dict__.get("__doc__") or "")


def _resolve(annotation: Any) -> Any:
    """Resolve a forward reference to a DEXPI class by name."""
    if isinstance(annotation, ForwardRef):
        return getattr(pydexpi_classes, annotation.__forward_arg__, annotation)
    if isinstance(annotation, str):
        return getattr(pydexpi_classes, annotation, annotation)
    return annotation


def _type_info(annotation: Any) -> tuple[list[type | Any], bool]:
    """Flatten an attribute annotation into its member types and a list flag.

    ``None`` and ``Undefined`` are dropped from unions: every optional DEXPI
    attribute carries them, so they say nothing about what to write.
    """
    annotation = _resolve(annotation)
    origin = typing.get_origin(annotation)
    if origin is list:
        (item,) = typing.get_args(annotation) or (Any,)
        members, _ = _type_info(item)
        return members, True
    if origin in (typing.Union, types.UnionType):
        members: list[Any] = []
        is_list = False
        for arg in typing.get_args(annotation):
            arg_members, arg_is_list = _type_info(arg)
            members.extend(arg_members)
            is_list = is_list or arg_is_list
        return members, is_list
    if annotation in (type(None), Undefined):
        return [], False
    return [annotation], False


def _type_name(member: Any) -> str:
    return getattr(member, "__name__", None) or str(member)


def _attribute_description(cls: type, name: str) -> dict[str, Any]:
    field = cls.model_fields[name]
    members, is_list = _type_info(field.annotation)
    info: dict[str, Any] = {
        "name": name,
        "type": " | ".join(_type_name(m) for m in members) or "Any",
        "list": is_list,
        "required": field.is_required(),
    }
    if field.description:
        info["description"] = field.description
    enums = [m for m in members if inspect.isclass(m) and issubclass(m, Enum)]
    for enum_class in enums:
        if 0 < len(enum_class) <= _MAX_INLINE_ENUM_VALUES:
            info.setdefault("values", []).extend(member.value for member in enum_class)
        elif len(enum_class) > _MAX_INLINE_ENUM_VALUES:
            # Too long to inline; describe_dexpi_class on the enum lists them.
            info.setdefault("values_from", []).append(enum_class.__name__)
    binding = binding_of(cls, name)
    if binding is not None:
        info.update(_binding_description(binding))
    return info


def _binding_description(binding) -> dict[str, Any]:
    """The binding of a quantity property, as a value is checked against it.

    ``units`` lists the members of the bound unit enumeration and of every enumeration below it
    -- exactly the units ``qualified_values`` accepts for the property, and no other. It used to
    come from ``quantity_units.legal_units``, which widens a pressure bound to one of gauge or
    absolute to both, and so listed a unit the binding does not admit. A property holding
    QualifiedValues also says which kinds of value it admits (``value_types``:
    ``PhysicalQuantity``, ``PhysicalQuantityVector``, ``float``, ``int``, ``Undefined``).
    """
    described: dict[str, Any] = {"binding": binding.describe()}
    if binding.unit_type is not None:
        described["units"] = [
            qualified_unit_name(unit)
            for unit in sorted(
                iter_unit_members(binding.unit_type),
                key=lambda unit: (type(unit).__name__, unit.value),
            )
        ]
    if binding.holds_qualified_values:
        described["value_types"] = list(binding.value_types)
        if binding.category == "composition":
            described["set_with"] = "process.set_values"
    return described


def _describe_model(cls: type) -> dict[str, Any]:
    attributes: dict[str, list[dict[str, Any]]] = {"data": [], "composition": [], "reference": []}
    for name, field in cls.model_fields.items():
        category = (field.json_schema_extra or {}).get("attribute_category")
        if category in attributes:
            attributes[category].append(_attribute_description(cls, name))
    bases = [
        base.__name__
        for base in cls.__mro__[1:]
        if base.__name__ in CLASS_CATALOG and CLASS_CATALOG[base.__name__] is base
    ]
    subclasses = sorted(
        sub.__name__ for sub in cls.__subclasses__() if CLASS_CATALOG.get(sub.__name__) is sub
    )
    described: dict[str, Any] = {
        "base_classes": bases,
        "subclasses": subclasses,
        "attributes": attributes,
        **_abstract(cls),
    }
    if issubclass(cls, Port):
        described.update(_describe_port_class(cls))
    return described


def _abstract(cls: type) -> dict[str, bool]:
    """``{"abstract": True}`` for a process class DEXPI declares abstract, else nothing.

    The generated classes do not mark abstract classes, so only the process ones are known
    (``process_toolkit.ABSTRACT_PROCESS_CLASSES``, from the specification): no object in a
    document is of one, and a listing that offers ``Splitting`` beside ``Mixing`` without a word
    would hide that. The key is absent, never false, for every other class: for a plant class it
    is not known, and an agent must not read "not abstract" into it.
    """
    return {"abstract": True} if is_abstract_process_class(cls) else {}


def _describe_port_class(cls: type[Port]) -> dict[str, Any]:
    """What a port class says of its ports: their roles and their connection class.

    ``role_names`` are the names the specification lists for the class (``process_toolkit``,
    the same table ``pydexpi_process_port_role_names`` checks), None where it lists none;
    ``default_roles`` are the conventional roles of a port facing each way
    (``process_toolkit.default_role``); ``connection_class`` is the connection that
    joins two such ports.
    """
    names = role_names_for(cls)
    connection = connection_class_for_port(cls)
    return {
        "role_names": list(names) if names is not None else None,
        "default_roles": {
            "source": default_role(cls, PortDirection.OUTLET),
            "target": default_role(cls, PortDirection.INLET),
        },
        "connection_class": connection.__name__ if connection is not None else None,
    }


def _describe_enum(cls: type[Enum]) -> dict[str, Any]:
    return {"values": [member.value for member in cls]}


def _register_schema_tools(mcp) -> None:
    """Register the DEXPI class-catalog tools on *mcp*."""

    @mcp.tool()
    def list_dexpi_classes(
        base_class: str | None = None,
        package: str | None = None,
        name_contains: str | None = None,
        kind: ClassKind | None = None,
        limit: int = 50,
        offset: int = 0,
    ) -> str:
        """List DEXPI class and enum names, e.g. the valid values of a class parameter.

        Parameters
        ----------
        base_class : str, optional
            Only list this class and its subclasses, e.g. ``TaggedPlantItem``,
            ``PipingComponent``, ``Nozzle`` or ``PlantStructureItem``.
        package : str, optional
            Only list classes in this DEXPI package or below, e.g.
            ``"Plant.Piping"`` or ``"Process"`` (case-insensitive).
        name_contains : str, optional
            Case-insensitive substring filter on the class name.
        kind : {"class", "datatype", "enum"}, optional
            ``"class"`` for model objects, ``"datatype"`` for value types such
            as ``PhysicalQuantity``, ``"enum"`` for enumerations.
        limit : int
            Page size (default 50).
        offset : int
            Number of matches to skip.

        Returns
        -------
        str
            Paginated JSON of ``name``, ``kind``, ``package`` and one-line
            ``summary`` per class, or an error envelope. A process class DEXPI
            declares abstract (``ProcessStep``, ``Splitting``, ``Port``, ...)
            also carries ``"abstract": true``: every object of it in a document
            is of a subclass without the mark. Use ``describe_dexpi_class``
            for a class's attributes.
        """
        if (bad_paging := pagination_error(limit=limit, offset=offset)) is not None:
            return bad_paging
        base = None
        if base_class is not None:
            base = CLASS_CATALOG.get(base_class)
            if base is None:
                return error_response(
                    ErrorCode.INVALID_PARAMETER,
                    f"Unknown DEXPI class {base_class!r}.",
                    "Call list_dexpi_classes with name_contains to search for it.",
                )
        packages = get_dexpi_package_mapping()
        package_prefix = package.lower().rstrip(".") + "." if package else None
        needle = name_contains.lower() if name_contains else None
        items = [
            {
                "name": name,
                "kind": _kind(cls),
                "package": packages[name].rsplit(".", 1)[0],
                "summary": first_sentence(_own_doc(cls)),
                **_abstract(cls),
            }
            for name, cls in CLASS_CATALOG.items()
            if (base is None or issubclass(cls, base))
            and (package_prefix is None or packages[name].lower().startswith(package_prefix))
            and (needle is None or needle in name.lower())
            and (kind is None or _kind(cls) == kind)
        ]
        return json.dumps(paginate(items, limit=limit, offset=offset))

    @mcp.tool()
    def describe_dexpi_class(name: str) -> str:
        """Describe one DEXPI class or enum: documentation, inheritance and attributes.

        Parameters
        ----------
        name : str
            A class or enum name from ``list_dexpi_classes``, e.g.
            ``"CentrifugalPump"`` or ``"NominalPressureStandardClassification"``.

        Returns
        -------
        str
            JSON with ``name``, ``kind``, ``package`` and ``description``. For
            an enum, ``values`` — the strings to write. For a class,
            ``base_classes``, direct ``subclasses`` and ``attributes`` grouped
            as ``data`` (plain values),
            ``composition`` (owned child objects) and ``reference`` (links to
            other objects). Each attribute has ``type``, ``list``,
            ``required`` and, where known, ``description`` and enum ``values``.
            A quantity property also carries its DEXPI ``binding`` and the
            ``units`` it admits -- exactly those the binding admits, each
            spelled class-qualified (``"LengthUnit.Metre"``); one holding
            QualifiedValues (a step's ``temperature``, a stream's ``massFlow``,
            a composition's ``moleFractions``) adds its ``value_types``. A port
            class adds the
            ``role_names`` its ports may perform, the ``default_roles`` of a
            ``source`` and a ``target`` port, and the ``connection_class`` that
            joins two of them. A process class DEXPI declares abstract carries
            ``"abstract": true``; every object of it in a document is of one of
            its ``subclasses``.
        """
        cls = CLASS_CATALOG.get(name)
        if cls is None:
            return error_response(
                ErrorCode.OBJECT_NOT_FOUND,
                f"Unknown DEXPI class {name!r}.",
                "Call list_dexpi_classes with name_contains to search for it.",
            )
        result: dict[str, Any] = {
            "name": name,
            "kind": _kind(cls),
            "package": get_dexpi_package_mapping()[name].rsplit(".", 1)[0],
            "description": _own_doc(cls),
        }
        result.update(_describe_enum(cls) if issubclass(cls, Enum) else _describe_model(cls))
        return json.dumps(result)
