"""Resolution of DEXPI physical quantity units from their serialized spellings.

``PhysicalQuantity.unit`` is annotated with ``PhysicalQuantityUnit``, which is an *empty*
base ``StrEnum`` -- every member lives on one of its subclasses (``LengthUnit``,
``PressureGaugeUnit``, ...). Pydantic therefore validates the field with a bare
``is_instance_of`` check, and no JSON payload can satisfy it on its own. This module turns
the spellings that DEXPI serializations actually use back into real enum members, so a
validator on ``PyDexpiDataTypeBaseModel`` can accept them.

It deliberately imports nothing from ``pydexpi``: it is called from ``pydexpi_classes.py``
itself, so any such import would be circular. The base enum is passed in as an argument
instead.

Unit *values* are not unique across the subclass enums -- ``"Bar"`` is a member of both
``PressureAbsoluteUnit`` and ``PressureGaugeUnit``, and 14 further literals collide the same
way. A bare literal is therefore resolved only when it is unambiguous; otherwise
:func:`resolve_unit` raises and names the qualified spellings to choose from. Guessing is not
an option, because gauge and absolute pressure are physically different quantities. Callers
that know which attribute is being written can narrow the search with ``scope``; see
``pydexpi.toolkits.quantity_units``.
"""

from collections.abc import Iterator, Mapping
from enum import Enum
from typing import Any

__all__ = [
    "iter_unit_enums",
    "iter_unit_members",
    "qualified_unit_name",
    "resolve_unit",
]


def iter_unit_enums[UnitEnumT: Enum](base: type[UnitEnumT]) -> Iterator[type[UnitEnumT]]:
    """Yield ``base`` and every enum class below it, depth first.

    Parameters
    ----------
    base : type[UnitEnumT]
        Root of the unit enum hierarchy, normally ``PhysicalQuantityUnit`` or one of its
        subclasses when the search is being narrowed.

    Yields
    ------
    type[UnitEnumT]
        ``base`` itself followed by each of its transitive subclasses. Intermediate classes
        such as ``PhysicalQuantityUnit`` and ``PressureUnit`` carry no members of their own
        and simply yield nothing when iterated.
    """
    stack = [base]
    while stack:
        cls = stack.pop()
        yield cls
        stack.extend(cls.__subclasses__())


def iter_unit_members[UnitEnumT: Enum](base: type[UnitEnumT]) -> Iterator[UnitEnumT]:
    """Yield every unit member defined anywhere below ``base``.

    Parameters
    ----------
    base : type[UnitEnumT]
        Root of the unit enum hierarchy to walk.

    Yields
    ------
    UnitEnumT
        Each member of each enum class in the hierarchy. Members are not deduplicated by
        value: colliding literals such as ``PressureAbsoluteUnit.BAR`` and
        ``PressureGaugeUnit.BAR`` are both yielded.
    """
    for cls in iter_unit_enums(base):
        yield from cls


def qualified_unit_name(unit: Enum) -> str:
    """Return the class-qualified spelling of a unit member.

    The result (``"PressureGaugeUnit.Bar"``) is the spelling DEXPI XML already uses in a
    ``DataReference`` element, and is what :func:`resolve_unit` accepts as an unambiguous
    input.

    Parameters
    ----------
    unit : Enum
        A member of one of the generated unit enums.

    Returns
    -------
    str
        ``"<EnumClassName>.<value>"``.
    """
    return f"{type(unit).__name__}.{unit.value}"


def resolve_unit[UnitEnumT: Enum](
    raw: Any,
    base: type[UnitEnumT],
    *,
    scope: type[UnitEnumT] | None = None,
) -> Any:
    """Resolve a serialized unit into a real member of a ``base`` subclass.

    Accepts every spelling a DEXPI serialization produces:

    - an actual enum member, returned unchanged;
    - ``{"__enum__": "PressureGaugeUnit", "name": "BAR"}``, as written by
      ``pydexpi.loaders.json_serializer``;
    - ``"PressureGaugeUnit.Bar"`` or ``"PressureGaugeUnit.BAR"``, the class-qualified form --
      the ``.Bar`` variant is what DEXPI XML ``DataReference`` elements carry;
    - a bare literal such as ``"Millimetre"``, resolved when it is unique within ``scope``.

    Anything else is returned unchanged so that pydantic reports its own, more detailed error
    for it.

    Parameters
    ----------
    raw : Any
        The value to resolve.
    base : type[UnitEnumT]
        Root of the unit enum hierarchy, normally ``PhysicalQuantityUnit``.
    scope : type[UnitEnumT] or None, optional
        Restrict the search to this subclass of ``base`` and its descendants. Used to
        disambiguate a bare literal when the caller knows which attribute is being written --
        ``"Millimetre"`` is ambiguous across the whole hierarchy but unique within
        ``LengthUnit``. Defaults to ``base``.

    Returns
    -------
    Any
        The resolved enum member, or ``raw`` unchanged if it is not a spelling this function
        handles.

    Raises
    ------
    ValueError
        If a string or mapping spelling names an unknown enum class, an unknown member, or an
        ambiguous bare literal. The ambiguity message lists every qualified candidate.
    """
    if isinstance(raw, base):
        return raw

    search_root = scope if scope is not None else base

    if isinstance(raw, Mapping):
        if "__enum__" not in raw or "name" not in raw:
            return raw
        return _member_of_named_enum(str(raw["__enum__"]), str(raw["name"]), search_root)

    if isinstance(raw, str):
        if "." in raw:
            enum_name, member = raw.split(".", 1)
            return _member_of_named_enum(enum_name, member, search_root)
        return _member_by_value(raw, search_root)

    return raw


def _member_of_named_enum[UnitEnumT: Enum](
    enum_name: str, member: str, search_root: type[UnitEnumT]
) -> UnitEnumT:
    """Look a member up by its enum class name plus its member name or value.

    Parameters
    ----------
    enum_name : str
        Name of the unit enum class, e.g. ``"PressureGaugeUnit"``.
    member : str
        Either the member name (``"BAR"``) or the member value (``"Bar"``). Both are accepted
        because the JSON serializer writes the former and DEXPI XML the latter.
    search_root : type[UnitEnumT]
        Root of the hierarchy to search.

    Returns
    -------
    UnitEnumT
        The resolved member.

    Raises
    ------
    ValueError
        If no enum class of that name exists below ``search_root``, or it has no such member.
    """
    for cls in iter_unit_enums(search_root):
        if cls.__name__ != enum_name:
            continue
        try:
            return cls[member]
        except KeyError:
            pass
        try:
            return cls(member)
        except ValueError:
            raise ValueError(
                f"{enum_name!r} has no unit {member!r}. Available: "
                f"{', '.join(sorted(known.value for known in cls))}."
            ) from None
    raise ValueError(
        f"Unknown physical quantity unit enum {enum_name!r} below {search_root.__name__!r}."
    )


def _member_by_value[UnitEnumT: Enum](value: str, search_root: type[UnitEnumT]) -> UnitEnumT:
    """Resolve a bare unit literal, requiring it to be unique within ``search_root``.

    Parameters
    ----------
    value : str
        A unit value such as ``"Millimetre"``.
    search_root : type[UnitEnumT]
        Root of the hierarchy to search.

    Returns
    -------
    UnitEnumT
        The single matching member.

    Raises
    ------
    ValueError
        If nothing matches, or if more than one enum class defines the literal. The latter
        message lists the qualified spellings to disambiguate with.
    """
    matches = [member for member in iter_unit_members(search_root) if member.value == value]
    if not matches:
        raise ValueError(
            f"Unknown physical quantity unit {value!r} below {search_root.__name__!r}."
        )
    if len(matches) > 1:
        qualified = ", ".join(sorted(qualified_unit_name(member) for member in matches))
        raise ValueError(
            f"Ambiguous physical quantity unit {value!r}; it is defined by more than one unit "
            f"enum. Qualify it as one of: {qualified}."
        )
    return matches[0]
