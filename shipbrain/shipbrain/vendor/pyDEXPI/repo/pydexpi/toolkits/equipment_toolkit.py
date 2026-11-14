"""Utility functions for DEXPI equipment classes."""

import functools
import inspect
import typing
from dataclasses import dataclass

from pydexpi.pydexpi_classes import Nozzle, ProcessEquipment, PyDexpiBaseModel, TaggedPlantItem
from pydexpi.pydexpi_classes.plant import processEquipment
from pydexpi.toolkits.base_model_utils import (
    get_composition_attributes_from_class,
    get_inheritance_from_dexpi_class,
)


def get_equipment_internal_classes() -> list[type[PyDexpiBaseModel]]:
    """Return all equipment internal component classes.

    Equipment internals are classes that:

    1. Belong to the package Plant.ProcessEquipment
    2. Do NOT inherit from ``TaggedPlantItem``
    3. Exclude ``Nozzle`` explicitly.
    4. Do NOT include superclasses of ``ProcessEquipment``

    The list holds ``ColumnSection`` and ``Vent``, which classes outside it derive from: the
    top-level item ``TaggedColumnSection`` and the piping component ``VentLine``. An
    ``isinstance`` test against the list is True for both. Ask :func:`is_equipment_internal`
    whether an object is an internal.

    Returns
    -------
    list[type[PyDexpiBaseModel]]
        Sorted list of equipment internal component class objects; a new list on every call.
    """
    return list(_equipment_internal_classes())


@functools.cache
def _equipment_internal_classes() -> tuple[type[PyDexpiBaseModel], ...]:
    """:func:`get_equipment_internal_classes`, computed once: the generated classes are fixed."""
    equipment_internals: list[type[PyDexpiBaseModel]] = []

    for _, obj in inspect.getmembers(processEquipment, inspect.isclass):
        obj_inheritance = get_inheritance_from_dexpi_class(obj)
        pe_inheritance = get_inheritance_from_dexpi_class(ProcessEquipment)

        if (
            TaggedPlantItem
            not in obj_inheritance  # Exclude classes that inherit from TaggedPlantItem
            and Nozzle not in obj_inheritance  # Exclude Nozzle explicitly
            and obj not in pe_inheritance  # Exclude classes from ProcessEquipment inheritance tree
        ):
            equipment_internals.append(obj)

    return tuple(sorted(equipment_internals, key=lambda class_type: class_type.__name__))


def is_equipment_internal(obj_or_cls: object) -> bool:
    """Whether an object, or a class, is an equipment internal: a chamber, an impeller, ...

    An instance of exactly one of the classes :func:`get_equipment_internal_classes` lists, by
    membership and not ``issubclass``. That list is every such class of
    ``Plant.ProcessEquipment``, so a subclass outside it comes from elsewhere, and two do, each
    a different thing that a subclass test would take for an internal:

    * ``TaggedColumnSection`` derives from ``ColumnSection`` and from ``TaggedPlantItem``. It is
      a top-level item in ``taggedPlantItems``.
    * ``VentLine`` derives from ``Vent`` and from ``PipingComponent``. It is an item of a
      piping segment.

    Parameters
    ----------
    obj_or_cls : object
        A model object, or a class.

    Returns
    -------
    bool
        True for the 41 internals of the corpus (26 chambers, the column internals arrangements,
        the SubTaggedColumnSections, ...), False for a TaggedColumnSection, a VentLine, a
        nozzle, equipment and anything else.
    """
    cls = obj_or_cls if isinstance(obj_or_cls, type) else type(obj_or_cls)
    return cls in _internal_class_set()


@functools.cache
def _internal_class_set() -> frozenset[type]:
    return frozenset(_equipment_internal_classes())


@dataclass(frozen=True)
class InternalSlot:
    """One composition attribute that holds equipment internals, as :func:`internal_slots` reads it.

    Attributes
    ----------
    declared : tuple[type[PyDexpiBaseModel], ...]
        The classes the generated annotation names, such as ``Chamber`` or ``MotorAsComponent``.
    accepts : tuple[type[PyDexpiBaseModel], ...]
        Every equipment internal class the attribute takes: the declared classes and their
        subclasses, ``AlternatingCurrentMotorAsComponent`` for ``motors`` among them.
    is_list : bool
        Whether the attribute is a list (``chambers``) or holds one object (``tubeBundle``).
    """

    declared: tuple[type[PyDexpiBaseModel], ...]
    accepts: tuple[type[PyDexpiBaseModel], ...]
    is_list: bool


def internal_slots(owner_cls: type[PyDexpiBaseModel]) -> dict[str, InternalSlot]:
    """The composition attributes of `owner_cls` that hold equipment internals, in field order.

    Read from the resolved annotations: generated fields carry string forward references such as
    ``'Chamber | None'``, which ``model_fields`` leaves unresolved, so they go through
    ``typing.get_type_hints``. Reference attributes never count -- ``Vessel.columnSections``
    points at TaggedColumnSections, while ``ProcessColumn.columnSections`` composes its
    SubTaggedColumnSections.

    Across the generated classes that is 25 attributes on 105 owner classes, 17 of them lists,
    and each pair of an owner class and an internal class that fit at all fit exactly one
    attribute, so :func:`slot_for` needs no trial assignment.

    Parameters
    ----------
    owner_cls : type[PyDexpiBaseModel]
        A generated class: equipment, or an internal that holds internals itself, such as
        ``SubTaggedColumnSection`` or ``TransmissionSystem``.

    Returns
    -------
    dict[str, InternalSlot]
        Field name to slot; empty for a class that holds no internals. A new dict on every
        call; the reading behind it is done once per class.
    """
    return dict(_internal_slots(owner_cls))


@functools.cache
def _internal_slots(owner_cls: type[PyDexpiBaseModel]) -> dict[str, InternalSlot]:
    """:func:`internal_slots`, computed once per class. Never hand this dict out: it is shared."""
    internals = _equipment_internal_classes()
    composition = get_composition_attributes_from_class(owner_cls)
    hints = typing.get_type_hints(owner_cls)
    slots: dict[str, InternalSlot] = {}
    for name in owner_cls.model_fields:
        if name not in composition:
            continue
        named = tuple(_model_classes(hints[name]))
        accepts = tuple(cls for cls in internals if issubclass(cls, named))
        if accepts:
            declared = tuple(t for t in named if any(issubclass(cls, t) for cls in accepts))
            slots[name] = InternalSlot(declared, accepts, _is_list(hints[name]))
    return slots


def slot_for(owner_cls: type[PyDexpiBaseModel], internal_cls: type[PyDexpiBaseModel]) -> str | None:
    """The composition attribute of `owner_cls` that takes an `internal_cls`, or None.

    A function of the two classes alone: no owner class has two attributes that take the same
    internal class (see :func:`internal_slots`).

    Parameters
    ----------
    owner_cls : type[PyDexpiBaseModel]
        The class of the object the internal would go into.
    internal_cls : type[PyDexpiBaseModel]
        An equipment internal class. ``ColumnSection`` and ``Vent`` fit no attribute of any
        class, and anything that is not an internal fits none either.

    Returns
    -------
    str | None
        The field name, such as ``"chambers"`` or ``"tubeBundle"``.
    """
    return next(
        (name for name, slot in _internal_slots(owner_cls).items() if internal_cls in slot.accepts),
        None,
    )


def _model_classes(annotation: object) -> list[type]:
    """The model classes an annotation names, through ``X | None`` and ``list[X]``."""
    args = typing.get_args(annotation)
    if args:
        return [found for arg in args for found in _model_classes(arg)]
    if isinstance(annotation, type) and issubclass(annotation, PyDexpiBaseModel):
        return [annotation]
    return []


def _is_list(annotation: object) -> bool:
    """Whether an annotation is a list, or a union holding one."""
    if typing.get_origin(annotation) is list:
        return True
    return any(_is_list(arg) for arg in typing.get_args(annotation))
