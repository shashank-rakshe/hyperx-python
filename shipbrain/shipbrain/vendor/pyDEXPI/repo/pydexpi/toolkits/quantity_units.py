"""Which physical quantity units are legal for a given DEXPI attribute.

The map is **derived from the generated classes**, not curated. Since DEXPI 2.0.1,
pyDEXPI-builder records on every quantity-typed data attribute the unit enumeration the
specification binds it to, as ``json_schema_extra["unit_type"]`` -- ``designPressureHead`` is
bound to ``LengthUnit``, ``inclination`` to ``RatioUnit``. :data:`QUANTITY_UNIT_ENUMS` reads
that metadata, so it can no longer drift from the specification. The hand-curated table it
replaced (DEXPI 2.0, when the classes carried no binding) disagreed with the specification on
nine attributes: seven particle sizes it mapped to ``ParticleSizeUnit``, which the
specification binds to ``LengthUnit``, and ``FilterUnit``'s two allowable solids concentrations,
which it mapped to ``MassConcentrationUnit`` and the specification binds to ``RatioUnit``.

Two consumers:

- :func:`legal_units` lists the units of the attribute's widened enumeration. A catalogue that
  tells a client what the *binding* admits must not use it: the widening below offers an
  absolute pressure where the binding admits only a gauge one. MCP ``describe_dexpi_class``
  reads the binding itself (``qualified_values.binding_of``);
- :func:`resolve_unit_for_attribute` narrows a bare unit literal to the attribute's own
  dimension, which is what makes ``{"value": 5, "unit": "Millimetre"}`` unambiguous --
  ``"Millimetre"`` belongs to both ``LengthUnit`` and ``ParticleSizeUnit``, but only one of
  those is a legal thickness.

The map is a convenience, never a constraint: a class-qualified spelling is always resolved
against the full hierarchy, so the map can never reject a unit the model itself permits. One
override of the specification's bindings remains, and it is explicit
(:data:`_UNIT_ENUM_WIDENING`): an attribute bound to ``PressureGaugeUnit`` or
``PressureAbsoluteUnit`` is mapped to their shared parent ``PressureUnit``. The two leaves
share all six literals, so narrowing to the bound leaf would silently turn a bare ``"Bar"``
into the specification's choice of gauge or absolute, where the document may have meant the
other; a bare ``"Bar"`` stays ambiguous and the caller must qualify it, which is the honest
answer. ``legal_units`` therefore still offers both leaves' members.

Only data attributes typed ``PhysicalQuantity`` are in the map. A property bound through a
``QualifiedValue`` (``Composition.moleFractions``, every process-step parameter) is a
composition, carries its binding as ``value_types`` / ``unit_type`` on that composition, and
is not keyed by name here: the same name can be bound to different units on different classes
(``capacity`` is a ``MassUnit`` on ``SupplyingMaterial`` and a ``PowerUnit`` on
``TransportingEnergy``).
"""

import inspect
import re
from typing import Any

from pydantic import BaseModel

from pydexpi.pydexpi_classes import pydexpi_classes
from pydexpi.pydexpi_classes.pydexpi_classes import (
    PhysicalQuantityUnit,
    PressureAbsoluteUnit,
    PressureGaugeUnit,
    PressureUnit,
    PyDexpiBaseModel,
    PyDexpiDataTypeBaseModel,
)
from pydexpi.pydexpi_classes.unit_resolution import iter_unit_members, resolve_unit

__all__ = [
    "QUANTITY_UNIT_ENUMS",
    "legal_units",
    "quantity_attribute_names",
    "resolve_unit_for_attribute",
    "spec_unit_bindings",
    "unit_enum_for_attribute",
]

#: Matches ``PhysicalQuantity`` and ``PhysicalQuantityVector`` but not ``PhysicalQuantityUnit``,
#: whose trailing word character defeats the closing boundary.
_QUANTITY_ANNOTATION = re.compile(r"\bPhysicalQuantity(?:Vector)?\b")

#: The one deliberate override of the specification's unit bindings: a bound unit enum on the
#: left is advertised and narrowed as the enum on the right. Pressures are bound to one leaf
#: each by DEXPI 2.0.1 (``upperLimitDesignPressure`` to ``PressureGaugeUnit``,
#: ``differentialPressure`` to ``PressureAbsoluteUnit``), but both leaves spell all six of their
#: literals identically, so narrowing would make a bare ``"Bar"`` a silent guess. See the module
#: docstring. Widening can only admit more, never reject what the specification binds.
_UNIT_ENUM_WIDENING: dict[type[PhysicalQuantityUnit], type[PhysicalQuantityUnit]] = {
    PressureAbsoluteUnit: PressureUnit,
    PressureGaugeUnit: PressureUnit,
}


def _model_classes() -> list[type[BaseModel]]:
    """Every generated class that declares fields, in module order."""
    return [
        dexpi_class
        for dexpi_class in vars(pydexpi_classes).values()
        if inspect.isclass(dexpi_class)
        and issubclass(dexpi_class, (PyDexpiBaseModel, PyDexpiDataTypeBaseModel))
    ]


def _bound_unit_enum(field: Any) -> type[PhysicalQuantityUnit]:
    """The unit enum the generated binding metadata names for a field.

    An attribute without a ``unit_type`` is unbound: ``QualifiedValue.value`` is the only one,
    because its binding belongs to the property the ``QualifiedValue`` qualifies. It maps to
    the root, which imposes no narrowing -- a bare literal stays as ambiguous as it would be
    without the map.
    """
    extra = field.json_schema_extra if isinstance(field.json_schema_extra, dict) else {}
    unit_type = extra.get("unit_type")
    if unit_type is None:
        return PhysicalQuantityUnit
    unit_enum = getattr(pydexpi_classes, str(unit_type))
    if not (inspect.isclass(unit_enum) and issubclass(unit_enum, PhysicalQuantityUnit)):
        raise TypeError(f"unit_type {unit_type!r} does not name a PhysicalQuantityUnit enum")
    return unit_enum


def spec_unit_bindings() -> dict[str, frozenset[type[PhysicalQuantityUnit]]]:
    """Return the unit enums the specification binds each quantity-typed attribute to.

    This is the generated metadata as it stands, before :data:`_UNIT_ENUM_WIDENING`: what
    DEXPI says, for a reader comparing it with what :data:`QUANTITY_UNIT_ENUMS` advertises.

    Returns
    -------
    dict[str, frozenset[type[PhysicalQuantityUnit]]]
        Attribute name mapped to every unit enum some class binds it to. One per name in the
        generated classes; a test fails if a regeneration binds one name to two.
    """
    bindings: dict[str, set[type[PhysicalQuantityUnit]]] = {}
    for dexpi_class in _model_classes():
        for attribute_name, field in dexpi_class.model_fields.items():
            if _QUANTITY_ANNOTATION.search(str(field.annotation)):
                bindings.setdefault(attribute_name, set()).add(_bound_unit_enum(field))
    return {name: frozenset(enums) for name, enums in sorted(bindings.items())}


def _common_unit_enum(
    unit_enums: frozenset[type[PhysicalQuantityUnit]],
) -> type[PhysicalQuantityUnit]:
    """The narrowest unit enum holding every one of ``unit_enums``' members.

    One name bound to several enums cannot be narrowed to any one of them without rejecting
    the others, so it gets their nearest common ancestor -- the root if they share none.
    """
    widened = {_UNIT_ENUM_WIDENING.get(unit_enum, unit_enum) for unit_enum in unit_enums}
    if len(widened) == 1:
        return next(iter(widened))
    first, *rest = sorted(widened, key=lambda unit_enum: unit_enum.__name__)
    for ancestor in first.__mro__:
        if (
            inspect.isclass(ancestor)
            and issubclass(ancestor, PhysicalQuantityUnit)
            and all(issubclass(other, ancestor) for other in rest)
        ):
            return ancestor
    return PhysicalQuantityUnit


#: The unit enum whose subtree holds the legal units of each quantity-typed DEXPI attribute,
#: keyed by attribute name: the specification's binding (the generated ``unit_type``), widened
#: by :data:`_UNIT_ENUM_WIDENING`. Every name is bound to one unit enum across all the classes
#: that declare it -- ``insulationThickness`` is a length on all 53 -- so keying by name loses
#: nothing.
QUANTITY_UNIT_ENUMS: dict[str, type[PhysicalQuantityUnit]] = {
    name: _common_unit_enum(unit_enums) for name, unit_enums in spec_unit_bindings().items()
}


def quantity_attribute_names() -> dict[str, frozenset[str]]:
    """Discover every quantity-typed attribute in the generated classes.

    Matching is on the *text* of the field annotation rather than on resolved types, because
    ``QualifiedValue.value`` is still an unevaluated ``ForwardRef`` after class construction
    and would otherwise be missed.

    Returns
    -------
    dict[str, frozenset[str]]
        Attribute name mapped to the names of the DEXPI classes declaring it.
    """
    found: dict[str, set[str]] = {}
    for dexpi_class in _model_classes():
        for attribute_name, field in dexpi_class.model_fields.items():
            if _QUANTITY_ANNOTATION.search(str(field.annotation)):
                found.setdefault(attribute_name, set()).add(dexpi_class.__name__)
    return {name: frozenset(owners) for name, owners in found.items()}


def unit_enum_for_attribute(attribute_name: str) -> type[PhysicalQuantityUnit] | None:
    """Return the unit enum whose subtree holds the legal units of an attribute.

    Parameters
    ----------
    attribute_name : str
        Name of a quantity-typed DEXPI attribute, e.g. ``"designHeatTransferCoefficient"``.

    Returns
    -------
    type[PhysicalQuantityUnit] or None
        The mapped enum, or ``None`` if the attribute is not quantity-typed or is not in
        :data:`QUANTITY_UNIT_ENUMS`.
    """
    return QUANTITY_UNIT_ENUMS.get(attribute_name)


def legal_units(attribute_name: str) -> list[PhysicalQuantityUnit]:
    """Return every unit member an attribute may legally carry.

    Parameters
    ----------
    attribute_name : str
        Name of a quantity-typed DEXPI attribute.

    Returns
    -------
    list[PhysicalQuantityUnit]
        The members of the mapped enum's subtree, ordered by qualified name; empty if the
        attribute is unknown. Values are not unique across the list -- a pressure attribute
        yields ``PressureAbsoluteUnit.BAR`` *and* ``PressureGaugeUnit.BAR`` -- so callers
        that render or round-trip these must key on
        ``unit_resolution.qualified_unit_name``, not on the bare value.
    """
    scope = QUANTITY_UNIT_ENUMS.get(attribute_name)
    if scope is None:
        return []
    return sorted(iter_unit_members(scope), key=lambda unit: (type(unit).__name__, unit.value))


def resolve_unit_for_attribute(attribute_name: str, raw: Any) -> Any:
    """Resolve a serialized unit, using the attribute to disambiguate a bare literal.

    A class-qualified spelling (``"PressureGaugeUnit.Bar"``) or the JSON serializer's
    ``{"__enum__": ..., "name": ...}`` form is always resolved against the whole hierarchy, so
    this can never reject a unit that the model itself accepts. Only a bare literal is
    narrowed to the attribute's dimension.

    Parameters
    ----------
    attribute_name : str
        Name of the attribute being written.
    raw : Any
        The serialized unit, in any spelling ``unit_resolution.resolve_unit`` accepts.

    Returns
    -------
    Any
        The resolved enum member, or ``raw`` unchanged if it is not a spelling that function
        handles.

    Raises
    ------
    ValueError
        If the unit cannot be resolved, or is still ambiguous within the attribute's
        dimension. The message names the attribute and the qualified candidates.
    """
    scope = QUANTITY_UNIT_ENUMS.get(attribute_name)
    narrow = scope is not None and isinstance(raw, str) and "." not in raw
    try:
        return resolve_unit(raw, PhysicalQuantityUnit, scope=scope if narrow else None)
    except ValueError as exc:
        raise ValueError(
            f"Cannot resolve the unit for attribute {attribute_name!r}: {exc}"
        ) from exc
