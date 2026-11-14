"""Which lists carry meaning in their order: the single definition.

A list attribute is **ordered** when reordering it changes what the model says. Two sources say
so, and every consumer -- the diff, its JSON, the Git projection, the canonical JSON behind
``hashing.canonical_json_*`` and data-type equality -- reads them from here:

- **The specification.** DEXPI declares a property ``isOrdered``, and the generated classes carry
  it as ``json_schema_extra["is_ordered"]`` (:func:`is_spec_ordered`). In DEXPI 2.0.1 that is the
  drawing -- ``PolyLine.points``, ``ConnectorLine.innerPoints``, a ``Shape``'s primitives, a type
  group's elements, a ``RepresentationGroup``'s groups (inherited by ``Diagram``: render order is
  list order, and later groups paint over earlier ones) and a
  ``TextTemplate``'s fragments -- plus ``PhysicalQuantityVector.Values`` and, by the declared
  deviation ``COMPONENT-ORDER`` taken from the class's own description,
  ``ListOfMaterialComponents.Component``. A fraction vector is read against that component list
  position by position, so both orders are part of the data.
- **pyDEXPI's own reading** (:data:`ORDERED_BY_CONVENTION`): a ``PipingNetworkSegment``'s items
  and connections, which the specification leaves unordered and the piping toolkit keeps in flow
  order (``piping_toolkit.sort_connected_items_and_connections``).

Every other list is a set in all but name -- the order of a plant model's ``taggedPlantItems`` is
whatever order the file listed them in -- and is compared as a multiset.

The two sources differ in one place: ``id_diff`` always compares a list the specification
orders, and the pyDEXPI-ordered ones only when asked (``track_order=True``); see
``pydexpi.diff.ordering``.

This module imports nothing from pyDEXPI but the generated classes, so the serializers can use it
without importing the diff.
"""

from __future__ import annotations

from functools import cache

from pydexpi.pydexpi_classes.pydexpi_classes import (
    PipingNetworkSegment,
    PyDexpiBaseModel,
    PyDexpiDataTypeBaseModel,
)

__all__ = [
    "ORDERED_BY_CONVENTION",
    "is_convention_ordered",
    "is_ordered",
    "is_spec_ordered",
    "spec_ordered_attributes",
]

#: ``(class, attribute)`` pairs whose order pyDEXPI gives meaning although the specification does
#: not declare them ordered, matched with ``issubclass``. Before the DEXPI 2.0.1 metadata this also
#: named ``Diagram.groups`` and ``RepresentationGroup.groups``; the specification orders both now.
ORDERED_BY_CONVENTION: tuple[tuple[type[PyDexpiBaseModel], str], ...] = (
    (PipingNetworkSegment, "items"),
    (PipingNetworkSegment, "connections"),
)

type _Owner = PyDexpiBaseModel | PyDexpiDataTypeBaseModel | type


def _class_of(owner: _Owner) -> type:
    return owner if isinstance(owner, type) else type(owner)


@cache
def _spec_ordered(cls: type, attribute: str) -> bool:
    fields = getattr(cls, "model_fields", None)
    if not fields or attribute not in fields:
        return False
    extra = fields[attribute].json_schema_extra
    return isinstance(extra, dict) and extra.get("is_ordered") is True


def is_spec_ordered(owner: _Owner, attribute: str) -> bool:
    """Return ``True`` if the specification declares *owner*'s list *attribute* ordered.

    Parameters
    ----------
    owner : PyDexpiBaseModel, PyDexpiDataTypeBaseModel or type
        The object holding the list, or its class.
    attribute : str
        The field name.

    Returns
    -------
    bool
        Whether the generated field carries ``is_ordered``. ``False`` for an unknown field.
    """
    return _spec_ordered(_class_of(owner), attribute)


def is_convention_ordered(owner: _Owner, attribute: str) -> bool:
    """Return ``True`` if pyDEXPI gives *owner*'s list *attribute* an order (a segment's flow order).

    Parameters
    ----------
    owner : PyDexpiBaseModel or type
        The object holding the list, or its class.
    attribute : str
        The field name.

    Returns
    -------
    bool
        Whether the pair matches :data:`ORDERED_BY_CONVENTION`.
    """
    cls = _class_of(owner)
    return any(
        attribute == name and issubclass(cls, holder) for holder, name in ORDERED_BY_CONVENTION
    )


def is_ordered(owner: _Owner, attribute: str) -> bool:
    """Return ``True`` if reordering *owner*'s list *attribute* is a change.

    Parameters
    ----------
    owner : PyDexpiBaseModel, PyDexpiDataTypeBaseModel or type
        The object holding the list, or its class.
    attribute : str
        The field name.

    Returns
    -------
    bool
        Ordered by the specification (:func:`is_spec_ordered`) or by pyDEXPI
        (:func:`is_convention_ordered`).
    """
    return is_spec_ordered(owner, attribute) or is_convention_ordered(owner, attribute)


def spec_ordered_attributes() -> frozenset[tuple[str, str]]:
    """Every ``(class name, attribute)`` the generated classes declare ordered, inherited included.

    Returns
    -------
    frozenset[tuple[str, str]]
        One entry per class and field, for review and tests.
    """
    from pydexpi.pydexpi_classes import pydexpi_classes

    found: set[tuple[str, str]] = set()
    for name, candidate in vars(pydexpi_classes).items():
        if not isinstance(candidate, type) or not issubclass(
            candidate, (PyDexpiBaseModel, PyDexpiDataTypeBaseModel)
        ):
            continue
        for attribute in candidate.model_fields:
            if _spec_ordered(candidate, attribute):
                found.add((name, attribute))
    return frozenset(found)
