"""Check a value against the binding of the property that holds it: the one shared validator.

DEXPI binds every quantity-carrying property to a value shape and, where it is a quantity, to a
unit enumeration. pyDEXPI-builder records the binding on the generated field:

- a property holding ``QualifiedValue`` s (a composition, ``Composition.massFractions``, every
  process-step parameter) carries ``json_schema_extra["value_types"]`` -- which members of
  ``QualifiedValue.value``'s union it admits: ``PhysicalQuantity``, ``PhysicalQuantityVector``,
  ``float`` or ``int``, each with ``Undefined`` -- and, for a quantity, ``"unit_type"``;
- a data attribute typed ``PhysicalQuantity`` carries ``"unit_type"`` alone: its annotation
  already fixes the shape.

``QualifiedValue.value`` itself is the union of every binding (the ``QV-VALUE-UNION`` deviation),
so pydantic cannot tell a vector where a scalar belongs, or a pressure where a length belongs.
This module can, and everything that checks a value against its property goes through it: the
MANDATORY rule ``pydexpi_qualified_value_binding`` on loaded models, the RECOMMENDED
``pydexpi_composition_fractions``, and :func:`coerce_value`, which builds a value from a plain
input. MCP ``describe_dexpi_class`` lists a property's units from :func:`binding_of` too, so it
offers exactly the units the binding admits. Nothing checks bindings any other way.

**Shape and unit** (:func:`check_value`): the value's kind must be one the binding admits, and a
quantity's unit a member of the bound enumeration or one below it. A unit that is missing or not a
``PhysicalQuantityUnit`` member at all is *not* reported here: that is a different defect, which
pydantic rejects when the value is built, and a lenient load reports. (A rule for it was
drafted as VAL-007 and closed unmerged; if one is added, it and this check must never report
one defect twice.)

**Units are never inferred** (:func:`resolve_unit_for_binding`): a class-qualified spelling
(``"PressureGaugeUnit.Bar"``) is resolved against the whole hierarchy and then checked against the
binding; a bare literal is resolved only when it is unambiguous within the *bound* enumeration.
Within a binding that is no guess: a gauge-bound property cannot hold an absolute pressure, so its
bare ``"Bar"`` can only be ``PressureGaugeUnit.Bar``. (``quantity_units`` deliberately does not
narrow pressures, because there the map is a convenience and never a constraint; here the binding
is the constraint.)

**Fractions** (:func:`check_fractions`), for ``Composition.massFractions`` and ``.moleFractions``
only, whose binding is ``PhysicalQuantityVector[RatioUnit]``: every value is a finite number in
``[0, full scale]``, and they sum to the full scale, both within :data:`FRACTION_SUM_RTOL`. The full
scale is the ``RatioUnit`` literal's (:data:`FRACTION_FULL_SCALE`). Nothing is ever normalised or
relabelled: a vector off by more than the tolerance is reported with its sum, and one that sums to
another literal's full scale -- the Tennessee Eastman export's fractions sum to 1 and are labelled
``Percent`` -- names that literal as a suggestion. That fractions sum to their full scale is
physics, not a DEXPI statement, so it is kept apart from the shape and unit check.
"""

from __future__ import annotations

import math
from collections.abc import Iterator, Mapping
from dataclasses import dataclass
from enum import Enum
from functools import cache
from types import MappingProxyType
from typing import Any, Literal

from pydexpi.pydexpi_classes import pydexpi_classes
from pydexpi.pydexpi_classes.pydexpi_classes import (
    Composition,
    PhysicalQuantity,
    PhysicalQuantityUnit,
    PhysicalQuantityVector,
    PyDexpiBaseModel,
    QualifiedValue,
    RatioUnit,
    Undefined,
)
from pydexpi.pydexpi_classes.unit_resolution import qualified_unit_name, resolve_unit

__all__ = [
    "FRACTION_FULL_SCALE",
    "FRACTION_PROPERTIES",
    "FRACTION_SUM_RTOL",
    "Binding",
    "BindingError",
    "BindingProblem",
    "binding_of",
    "bindings_of_class",
    "check_fractions",
    "check_value",
    "coerce_value",
    "iter_bindings",
    "resolve_unit_for_binding",
    "validate_value",
]

#: Relative tolerance on the sum of a fraction vector: ``|sum - full scale| <= rtol * full scale``,
#: and on each value's bounds: ``-rtol * full scale <= value <= (1 + rtol) * full scale``.
#: Explicit and small, because a vector is never normalised -- anything further off is refused.
FRACTION_SUM_RTOL = 1e-6

#: What a fraction vector sums to, per ``RatioUnit`` literal.
FRACTION_FULL_SCALE: Mapping[RatioUnit, float] = MappingProxyType(
    {
        RatioUnit.FRACTION: 1.0,
        RatioUnit.PERCENT: 100.0,
        RatioUnit.PARTSPERTHOUSAND: 1e3,
        RatioUnit.PARTSPERMILLION: 1e6,
        RatioUnit.PARTSPERBILLION: 1e9,
    }
)

#: The properties holding fraction vectors, as ``(class, attribute)``, matched with ``issubclass``.
FRACTION_PROPERTIES: tuple[tuple[type[PyDexpiBaseModel], str], ...] = (
    (Composition, "massFractions"),
    (Composition, "moleFractions"),
)

#: ``value_types`` names, as the generator writes them, and the Python types they admit.
_VALUE_TYPES: Mapping[str, type] = MappingProxyType(
    {
        "PhysicalQuantity": PhysicalQuantity,
        "PhysicalQuantityVector": PhysicalQuantityVector,
        "float": float,
        "int": int,
        "Undefined": Undefined,
    }
)

#: How a value kind is named in a message.
_KIND_NAMES: Mapping[str, str] = MappingProxyType(
    {
        "PhysicalQuantity": "a PhysicalQuantity",
        "PhysicalQuantityVector": "a PhysicalQuantityVector",
        "float": "a Double",
        "int": "an Integer",
        "Undefined": "Undefined",
    }
)


@dataclass(frozen=True)
class Binding:
    """The value shape and unit the specification binds one property to.

    Attributes
    ----------
    owner : type[PyDexpiBaseModel]
        The class declaring the property (a subclass inherits it).
    attribute : str
        The field name.
    category : {"composition", "data", "reference"}
        A composition or reference of ``QualifiedValue`` s, or a data attribute typed
        ``PhysicalQuantity``.
    value_types : tuple[str, ...]
        The ``QualifiedValue.value`` kinds admitted, as the generator names them; empty for a
        data attribute, whose annotation fixes the shape.
    unit_type : type[PhysicalQuantityUnit] or None
        The bound unit enumeration; ``None`` where the binding names none.
    """

    owner: type[PyDexpiBaseModel]
    attribute: str
    category: Literal["composition", "data", "reference"]
    value_types: tuple[str, ...]
    unit_type: type[PhysicalQuantityUnit] | None

    @property
    def holds_qualified_values(self) -> bool:
        """Whether the property holds ``QualifiedValue`` s (else a ``PhysicalQuantity``)."""
        return self.category != "data"

    @property
    def is_fraction(self) -> bool:
        """Whether the property holds fraction vectors (:data:`FRACTION_PROPERTIES`)."""
        return _is_fraction(self.owner, self.attribute)

    def describe(self) -> str:
        """The binding as a reader would state it, e.g. ``PhysicalQuantity[LengthUnit]``."""
        unit = f"[{self.unit_type.__name__}]" if self.unit_type is not None else ""
        if not self.value_types:
            return f"PhysicalQuantity{unit}"
        kinds = [
            f"{kind}{unit}" if kind.startswith("Physical") else kind
            for kind in self.value_types
            if kind != "Undefined"
        ]
        shown = " | ".join(kinds)
        return f"{shown} | Undefined" if "Undefined" in self.value_types else shown


@dataclass(frozen=True)
class BindingProblem:
    """One way a value does not fit its property.

    Attributes
    ----------
    kind : {"shape", "unit", "fraction", "finite"}
        What is wrong: the value's kind, its unit enumeration, (fraction vectors only) its
        values, or (:func:`coerce_value` only) a number that is NaN or infinite.
    message : str
        A sentence saying what was found and what the binding admits.
    """

    kind: Literal["shape", "unit", "fraction", "finite"]
    message: str


class BindingError(ValueError):
    """A value does not fit the binding of its property; ``problems`` lists every reason."""

    def __init__(self, problems: list[BindingProblem]) -> None:
        self.problems = problems
        super().__init__(" ".join(problem.message for problem in problems))


def _is_fraction(owner: type, attribute: str) -> bool:
    return any(
        attribute == name and issubclass(owner, holder) for holder, name in FRACTION_PROPERTIES
    )


def _unit_enum(name: object) -> type[PhysicalQuantityUnit] | None:
    if name is None:
        return None
    unit_enum = getattr(pydexpi_classes, str(name), None)
    if not (isinstance(unit_enum, type) and issubclass(unit_enum, PhysicalQuantityUnit)):
        raise TypeError(f"unit_type {name!r} does not name a PhysicalQuantityUnit enumeration")
    return unit_enum


@cache
def _binding(cls: type, attribute: str) -> Binding | None:
    fields = getattr(cls, "model_fields", None)
    if not fields or attribute not in fields:
        return None
    extra = fields[attribute].json_schema_extra
    if not isinstance(extra, dict) or ("value_types" not in extra and "unit_type" not in extra):
        return None
    category = extra.get("attribute_category")
    if category not in ("composition", "data", "reference"):
        return None
    return Binding(
        owner=cls,
        attribute=attribute,
        category=category,
        value_types=tuple(extra.get("value_types", ())),
        unit_type=_unit_enum(extra.get("unit_type")),
    )


def binding_of(owner: PyDexpiBaseModel | type, attribute: str) -> Binding | None:
    """Return the binding of *owner*'s property *attribute*, or ``None`` if it has none.

    Parameters
    ----------
    owner : PyDexpiBaseModel or type
        The object holding the property, or its class.
    attribute : str
        The field name.

    Returns
    -------
    Binding or None
        The binding the generated metadata records.
    """
    return _binding(owner if isinstance(owner, type) else type(owner), attribute)


@cache
def _bound_attributes(cls: type) -> tuple[Binding, ...]:
    return tuple(
        binding
        for attribute in getattr(cls, "model_fields", {})
        if (binding := _binding(cls, attribute)) is not None
    )


def bindings_of_class(cls: type) -> tuple[Binding, ...]:
    """Every bound property of a class, inherited ones included, in field order."""
    return _bound_attributes(cls)


def iter_bindings() -> Iterator[Binding]:
    """Yield the binding of every bound property of every generated class.

    Yields
    ------
    Binding
        One per class and field; an inherited property is yielded for each class declaring it.
    """
    for candidate in vars(pydexpi_classes).values():
        if isinstance(candidate, type) and issubclass(candidate, PyDexpiBaseModel):
            yield from _bound_attributes(candidate)


def _kind(value: object) -> str | None:
    """The ``value_types`` name of a value's kind; ``None`` for anything else."""
    if isinstance(value, bool):
        return None
    for name, python_type in _VALUE_TYPES.items():
        if type(value) is python_type or (
            python_type not in (int, float) and isinstance(value, python_type)
        ):
            return name
    return None


def _describe_value(value: object) -> str:
    kind = _kind(value)
    if kind is not None:
        return _KIND_NAMES[kind]
    return f"a {type(value).__name__}"


def _label(binding: Binding) -> str:
    return f"{binding.owner.__name__}.{binding.attribute}"


def check_value(
    owner: PyDexpiBaseModel | type,
    attribute: str,
    value: Any,
    *,
    fractions: bool = True,
) -> list[BindingProblem]:
    """Check one value against the binding of the property that holds it.

    Parameters
    ----------
    owner : PyDexpiBaseModel or type
        The object (or class) whose property holds the value.
    attribute : str
        The property. A property without a binding admits anything: nothing is reported.
    value : Any
        For a property of ``QualifiedValue`` s, the ``QualifiedValue`` itself or its ``value``;
        for a data attribute, the ``PhysicalQuantity`` (or ``Undefined`` / ``None``).
    fractions : bool, optional
        Also apply :func:`check_fractions` when the property holds fraction vectors. On by
        default, which is what building a value wants; the MANDATORY rule turns it off.

    Returns
    -------
    list[BindingProblem]
        Every problem found; empty when the value fits. A missing value, and a unit that is
        missing or not a ``PhysicalQuantityUnit`` member, are not reported (see the module
        docstring).
    """
    binding = binding_of(owner, attribute)
    if binding is None:
        return []
    if isinstance(value, QualifiedValue):
        value = value.__dict__.get("value")
    if value is None:
        return []
    problems: list[BindingProblem] = []
    if binding.value_types:
        kind = _kind(value)
        if kind == "int" and "float" in binding.value_types:
            # A whole-number Double: JSON from other tools carries 5.0 as 5, and an int is a
            # lossless Double. The converse -- a float where only an Integer is bound -- is not.
            kind = "float"
        if kind not in binding.value_types:
            admitted = " or ".join(_KIND_NAMES[k] for k in binding.value_types if k in _KIND_NAMES)
            problems.append(
                BindingProblem(
                    "shape",
                    f"{_label(binding)} is bound to {binding.describe()}, so it admits "
                    f"{admitted}; this value is {_describe_value(value)}.",
                )
            )
            return problems
    elif isinstance(value, Undefined):
        return problems
    elif not isinstance(value, PhysicalQuantity):
        problems.append(
            BindingProblem(
                "shape",
                f"{_label(binding)} is bound to {binding.describe()}; this value is "
                f"{_describe_value(value)}.",
            )
        )
        return problems
    if isinstance(value, (PhysicalQuantity, PhysicalQuantityVector)):
        problem = _unit_problem(binding, value.__dict__.get("unit"))
        if problem is not None:
            problems.append(problem)
    if fractions and binding.is_fraction and not problems:
        problems.extend(check_fractions(value, label=_label(binding)))
    return problems


def _unit_problem(binding: Binding, unit: object) -> BindingProblem | None:
    """The problem with *unit* for *binding*, if any.

    A missing unit, or one that is not a ``PhysicalQuantityUnit`` member, is never this check's
    to report: pydantic rejects it when the value is built, and a lenient load reports it.
    """
    if binding.unit_type is None or not isinstance(unit, PhysicalQuantityUnit):
        return None
    if isinstance(unit, binding.unit_type):
        return None
    return BindingProblem(
        "unit",
        f"{_label(binding)} is bound to {binding.unit_type.__name__}; the unit "
        f"{qualified_unit_name(unit)} is a {type(unit).__name__}.",
    )


def check_fractions(value: Any, *, label: str = "The fraction vector") -> list[BindingProblem]:
    """Check a fraction vector: values in ``[0, full scale]`` that sum to the full scale.

    Both within :data:`FRACTION_SUM_RTOL` of the full scale, so a ``-1e-12`` left by a
    subtraction is no more a defect than a sum ``1e-12`` off.

    An entry that is ``Undefined`` (or ``None``) is a component whose fraction is not known --
    DEXPI admits ``Undefined`` in a vector's values -- so it is not a problem in itself. The known
    values must then not exceed the full scale together; only a vector with every value known must
    reach it. A NaN or infinity is never a fraction.

    Parameters
    ----------
    value : Any
        The ``QualifiedValue.value`` of a fraction property. Anything but a
        ``PhysicalQuantityVector`` in a ``RatioUnit`` literal is left alone: :func:`check_value`
        reports a wrong shape or unit.
    label : str, optional
        How the messages name the vector.

    Returns
    -------
    list[BindingProblem]
        One ``"fraction"`` problem per value out of bounds or not finite, and one for a sum off
        its full scale. Nothing is normalised.
    """
    if not isinstance(value, PhysicalQuantityVector):
        return []
    unit = value.__dict__.get("unit")
    if not isinstance(unit, RatioUnit) or unit not in FRACTION_FULL_SCALE:
        return []
    full_scale = FRACTION_FULL_SCALE[unit]
    unit_name = qualified_unit_name(unit)
    problems: list[BindingProblem] = []
    numbers: list[float] = []
    unknown = 0
    for position, item in enumerate(value.__dict__.get("values") or []):
        if item is None or isinstance(item, Undefined):
            unknown += 1
            continue
        if isinstance(item, bool) or not isinstance(item, (int, float)) or not math.isfinite(item):
            problems.append(
                BindingProblem(
                    "fraction", f"{label} value {position} is {item!r}, not a finite number."
                )
            )
            continue
        numbers.append(float(item))
        if not -FRACTION_SUM_RTOL * full_scale <= item <= full_scale * (1 + FRACTION_SUM_RTOL):
            problems.append(
                BindingProblem(
                    "fraction",
                    f"{label} value {position} is {item:g}, outside [0, {full_scale:g}] "
                    f"({unit_name}).",
                )
            )
    if problems:
        return problems
    total = math.fsum(numbers)
    if unknown:
        if total <= full_scale * (1 + FRACTION_SUM_RTOL):
            return problems
        problems.append(
            BindingProblem(
                "fraction",
                f"{label}'s known values sum to {total:.12g}, beyond the full scale "
                f"{full_scale:g} ({unit_name}), with {unknown} more not known.",
            )
        )
        return problems
    if _close(total, full_scale):
        return problems
    message = (
        f"{label} sums to {total:.12g}, not {full_scale:g} ({unit_name}): fractions are never "
        f"normalised, and the tolerance is {FRACTION_SUM_RTOL:g} of the full scale."
    )
    other = next(
        (
            literal
            for literal, scale in FRACTION_FULL_SCALE.items()
            if literal is not unit and _close(total, scale)
        ),
        None,
    )
    if other is not None:
        message += (
            f" It sums to the full scale of {qualified_unit_name(other)}: if that is the unit "
            "the values are in, say so; the unit is not changed for you."
        )
    problems.append(BindingProblem("fraction", message))
    return problems


def _close(total: float, full_scale: float) -> bool:
    return abs(total - full_scale) <= FRACTION_SUM_RTOL * full_scale


def validate_value(
    owner: PyDexpiBaseModel | type, attribute: str, value: Any, *, fractions: bool = True
) -> None:
    """Raise :class:`BindingError` if :func:`check_value` finds anything.

    Parameters
    ----------
    owner : PyDexpiBaseModel or type
        The object (or class) whose property holds the value.
    attribute : str
        The property.
    value : Any
        As for :func:`check_value`.
    fractions : bool, optional
        As for :func:`check_value`.

    Raises
    ------
    BindingError
        Listing every problem.
    """
    problems = check_value(owner, attribute, value, fractions=fractions)
    if problems:
        raise BindingError(problems)


def resolve_unit_for_binding(
    owner: PyDexpiBaseModel | type, attribute: str, raw: Any
) -> PhysicalQuantityUnit:
    """Resolve a serialized unit for a bound property, never inferring one.

    A class-qualified spelling (``"PressureGaugeUnit.Bar"``, ``{"__enum__": ..., "name": ...}``)
    or a member is resolved against the whole hierarchy; a bare literal (``"Bar"``) only within
    the bound enumeration, and only if it is unambiguous there. The result must belong to the
    bound enumeration.

    Parameters
    ----------
    owner : PyDexpiBaseModel or type
        The object (or class) whose property is written.
    attribute : str
        The property.
    raw : Any
        The unit, in any spelling ``unit_resolution.resolve_unit`` accepts.

    Returns
    -------
    PhysicalQuantityUnit
        The member.

    Raises
    ------
    BindingError
        If the unit cannot be resolved, is ambiguous within the binding, or is not a member of
        the bound enumeration.
    """
    binding = binding_of(owner, attribute)
    scope = binding.unit_type if binding is not None else None
    bare = isinstance(raw, str) and "." not in raw
    name = _label(binding) if binding is not None else attribute
    try:
        unit = resolve_unit(raw, PhysicalQuantityUnit, scope=scope if bare else None)
    except ValueError as error:
        unresolved = BindingProblem("unit", f"Cannot resolve the unit for {name}: {error}")
        raise BindingError([unresolved]) from error
    if not isinstance(unit, PhysicalQuantityUnit):
        raise BindingError([BindingProblem("unit", f"{raw!r} is not a unit, for {name}.")])
    problem = _unit_problem(binding, unit) if binding is not None else None
    if problem is not None:
        raise BindingError([problem])
    return unit


def coerce_value(owner: PyDexpiBaseModel | type, attribute: str, raw: Any) -> Any:
    """Build the value a bound property holds from a plain input, and check it.

    For callers whose input is JSON. Accepted inputs, per binding kind:

    - ``PhysicalQuantity``: ``{"value": <number>, "unit": <unit>}``;
    - ``PhysicalQuantityVector``: ``{"values": [<number>, ...], "unit": <unit>}``;
    - ``float``: a number (an ``int`` becomes a ``float``, which is lossless);
    - ``int``: an integer (a ``float`` only if it is integral);
    - ``Undefined``: ``None`` or ``{"undefined": true}``, where the binding admits it;
    - a value of the right type, unchanged.

    The unit is resolved with :func:`resolve_unit_for_binding`. The result is checked with
    :func:`check_value`, fraction checks included, and must hold finite numbers only: a NaN or
    an infinity is refused: a value built from input is never one.

    Parameters
    ----------
    owner : PyDexpiBaseModel or type
        The object (or class) whose property is written.
    attribute : str
        The property; it must have a binding.
    raw : Any
        The input.

    Returns
    -------
    Any
        The value, ready for ``QualifiedValue(value=...)`` or the data attribute.

    Raises
    ------
    BindingError
        If the input does not fit the binding, listing every reason, or holds a NaN or an
        infinity.
    """
    binding = binding_of(owner, attribute)
    if binding is None:
        raise BindingError(
            [BindingProblem("shape", f"{attribute!r} of {_owner_name(owner)} has no binding.")]
        )
    kinds = binding.value_types or ("PhysicalQuantity",)
    value = _coerce(binding, kinds, raw)
    validate_value(binding.owner, attribute, value)
    not_finite = _not_finite(binding, value)
    if not_finite is not None:
        raise BindingError([not_finite])
    return value


def _not_finite(binding: Binding, value: Any) -> BindingProblem | None:
    """The problem with a NaN or an infinity in *value*, if it holds one.

    A NaN or an infinity is no quantity, and a value built from input is never one.
    :func:`coerce_value` is where an input becomes a value, so it holds the built value
    to that: a number spelled as a string, ``{"value": "NaN", ...}``, is a number only once
    the quantity is built. :func:`check_value` does not refuse one: a loaded document may hold
    one (XML's ``xs:double`` admits ``NaN`` and ``INF``), and that is no
    binding defect for the MANDATORY rule to report. A fraction vector's values are checked
    before this, by :func:`check_fractions`.
    """
    if isinstance(value, PhysicalQuantity):
        numbers = [value.__dict__.get("value")]
    elif isinstance(value, PhysicalQuantityVector):
        numbers = list(value.__dict__.get("values") or [])
    else:
        numbers = [value]
    for number in numbers:
        if isinstance(number, float) and not math.isfinite(number):
            return BindingProblem(
                "finite",
                f"{_label(binding)} takes a finite number; {number!r} is not one. Leave a "
                "value that is not known unset.",
            )
    return None


def _owner_name(owner: PyDexpiBaseModel | type) -> str:
    return (owner if isinstance(owner, type) else type(owner)).__name__


def _coerce(binding: Binding, kinds: tuple[str, ...], raw: Any) -> Any:
    if _kind(raw) in kinds:
        return raw
    if raw is None or (isinstance(raw, Mapping) and raw.get("undefined") is True):
        if "Undefined" in kinds:
            return Undefined()
    elif isinstance(raw, Mapping) and "unit" in raw:
        unit = resolve_unit_for_binding(binding.owner, binding.attribute, raw["unit"])
        if "values" in raw and "PhysicalQuantityVector" in kinds:
            return PhysicalQuantityVector(values=list(raw["values"]), unit=unit)
        if "value" in raw and "PhysicalQuantity" in kinds:
            return PhysicalQuantity(value=raw["value"], unit=unit)
    elif isinstance(raw, (int, float)) and not isinstance(raw, bool):
        if "float" in kinds:
            return float(raw)
        if "int" in kinds and float(raw).is_integer():
            return int(raw)
    raise BindingError(
        [
            BindingProblem(
                "shape",
                f"{_label(binding)} is bound to {binding.describe()}; {_shown(raw)} is not "
                "one of its kinds.",
            )
        ]
    )


def _shown(raw: Any) -> str:
    if isinstance(raw, Enum):
        return qualified_unit_name(raw) if isinstance(raw, PhysicalQuantityUnit) else str(raw)
    text = repr(raw)
    return text if len(text) <= 80 else text[:77] + "..."
