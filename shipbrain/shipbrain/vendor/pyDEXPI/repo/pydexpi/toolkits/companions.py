"""Objects drawn as one physical assembly but stored in separate groups.

A valve and the ``ControlledActuator`` mounted on it are one thing on the sheet
and two things in the model. The ``ActuatingSystem``'s group sits at the top
level of the diagram; the valve's is three levels down, under its
``PipingNetworkSystem`` and ``PipingNetworkSegment``. Nothing joins them but a
shared position, and a drawing that places one without the other no longer
shows the assembly.

Because the valve is *nested*, every group enclosing it draws it too -- the
segment's group holds the valve's. So the assembly is collected from everything
a group subtree draws, not just from the object addressed; see
:func:`get_companion_groups`.

**Co-location is the invariant**, and it is the model's own claim, not a drafting
habit: in ``data/reference_pid.xml`` the valve and its actuator have *identical*
``ShapeUsage.position`` -- ``(323.5, 98.0)`` for GlobeValve1/ControlledActuator1,
``(160.0, 119.0)`` for GlobeValve2/ControlledActuator2. The actuator appears to
sit on top of the valve purely through shape geometry and rotation. So there is
no relative offset to keep: the two share one point.

The relations are an explicit table rather than "everything that references this
object". That distinction matters: a valve is also referenced by its piping
connections, its segment and its ActuatingFunction, and counting those would
take in half the drawing. Only relations naming a *physical assembly* belong here.

The table is read two ways. Belonging together is **symmetric**: whichever member
is addressed, the whole assembly is returned (:func:`get_companion_objects`).
Existence is **directional**: an actuator mounted on a valve has nowhere to be
once the valve is gone, but a valve exists without its actuator.
:func:`get_dependants` is that second reading -- what cannot exist without the
given objects -- and the valve is never among them for its system.
"""

from collections.abc import Callable
from dataclasses import dataclass
from typing import Protocol

from pydexpi.pydexpi_classes import (
    ActuatingSystem,
    ControlledActuator,
    EngineeringModel,
    OperatedValve,
    Positioner,
    PyDexpiBaseModel,
    RepresentationGroup,
)
from pydexpi.toolkits.diagram_toolkit import get_representation_group_of_object


class CompanionRelation(Protocol):
    """One kind of "these are drawn as a single physical assembly" relation.

    Implementations must be symmetric: given either member they return the
    other, so a caller gets the same assembly whichever half it addresses.
    """

    name: str
    description: str
    #: The kinds of geometric change (move, rotate, mirror, scale) the members
    #: share: for a listed kind the two are one picture. Which ones apply is a
    #: property of the relation; for a kind it leaves out, a companion shares only
    #: its offset from its counterpart (see CompanionGroup).
    #: ActuatingSystemOnValve says why it lists all four.
    carries: frozenset[str]

    def companions(self, model: EngineeringModel, obj: PyDexpiBaseModel) -> list[PyDexpiBaseModel]:
        """The other members of obj's assembly, or [] if obj is not in one."""
        ...

    def dependants(self, model: EngineeringModel, obj: PyDexpiBaseModel) -> list[PyDexpiBaseModel]:
        """Assembly members that cannot exist without obj, or [] if none can.

        Directional, unlike :meth:`companions`: the members whose existence
        depends on ``obj``, never the ones that exist without it.
        """
        ...


class ActuatingSystemOnValve:
    """An ActuatingSystem and the OperatedValve it drives.

    DEXPI records this one-directionally --
    ``ActuatingSystem.operatedValveReference.valve`` points at the valve and the
    valve points back at nothing -- so the valve-to-system direction is a scan
    over ``PlantModel.actuatingSystems``.

    Addressing the ControlledActuator or Positioner yields the enclosing
    ActuatingSystem *and* the valve. The system's group contains the actuator's
    and carries the assembly tag label, so returning only the valve would leave
    out the tag; :func:`maximal_groups` is what keeps the actuator's group from
    being counted twice.
    """

    name = "actuating_system_on_valve"
    description = "An ActuatingSystem and the OperatedValve it operates."

    #: All four kinds: move, rotate, mirror and scale.
    #:
    #: The two share one position, and a mounted device shares its valve's
    #: orientation and size as well as its place: the two are drawn as one
    #: assembly, and a valve twice the size beside an actuator at its drawn size
    #: is no longer one picture.
    #:
    #: The two symbols' authored angles differ, and differ inconsistently -- valve
    #: 270 with actuator 0 in ActuatingSystem1, 270 with 180 in ActuatingSystem2,
    #: 0 with 270 in ActuatingSystem3 -- so one stretch along the sheet's axes lies
    #: along different axes of each symbol: at 90 and 270 degrees a symbol's own
    #: factors are the sheet's swapped.
    carries = frozenset({"move", "rotate", "mirror", "scale"})

    def companions(self, model: EngineeringModel, obj: PyDexpiBaseModel) -> list[PyDexpiBaseModel]:
        systems = getattr(model.conceptualModel, "actuatingSystems", None) or []

        if isinstance(obj, OperatedValve):
            # DEXPI 2.0 allows a valve at most one OperatedValveReference
            # (ActuatingSystem.OperatedValveReference 0..1, opposite
            # OperatedValveReference.Valve 0..1). Collect every match anyway:
            # malformed or imported models can contain several, and stopping at
            # the first would make the result depend on list order.
            return [system for system in systems if self._valve_of(system) is obj]

        if isinstance(obj, ActuatingSystem):
            return self._rest_of_assembly(systems, obj)

        if isinstance(obj, (ControlledActuator, Positioner)):
            for system in systems:
                if system.controlledActuator is obj or system.positioner is obj:
                    # The system, not just the valve: its group encloses this one
                    # and carries the assembly tag label. get_companion_groups
                    # keeps whichever group is outermost, so the actuator is
                    # still counted exactly once.
                    return [system, *self._rest_of_assembly(systems, system)]

        return []

    def dependants(self, model: EngineeringModel, obj: PyDexpiBaseModel) -> list[PyDexpiBaseModel]:
        """The systems mounted on a valve; nothing for any other member.

        The actuator was mounted on that valve and has nowhere to be without it,
        so the system, its actuator, its positioner and its valve reference depend
        on the valve. The other direction is deliberately empty: a valve is a piping
        component in its own right and exists without its actuator.
        """
        if isinstance(obj, OperatedValve):
            systems = getattr(model.conceptualModel, "actuatingSystems", None) or []
            return [system for system in systems if self._valve_of(system) is obj]
        return []

    def _rest_of_assembly(self, systems, system: ActuatingSystem) -> list[PyDexpiBaseModel]:
        """The valve this system drives, plus any other system on that valve.

        Completing the assembly is what makes a non-transitive relation
        symmetric: without it, addressing a valve with two systems returns both,
        but addressing one of those systems returns only the valve. A conforming
        DEXPI 2.0 model has at most one system per valve, so ``other_systems`` is
        empty there; it is defensive tolerance for nonconforming input.
        """
        valve = self._valve_of(system)
        if valve is None:
            return []
        other_systems = [
            other for other in systems if other is not system and self._valve_of(other) is valve
        ]
        return [valve, *other_systems]

    @staticmethod
    def _valve_of(system: ActuatingSystem) -> OperatedValve | None:
        reference = system.operatedValveReference
        return reference.valve if reference is not None else None


#: The relations that count as one physical assembly. Adding a case is an entry
#: here; see the module docstring for what does and does not belong.
COMPANION_RELATIONS: tuple[CompanionRelation, ...] = (ActuatingSystemOnValve(),)


@dataclass(frozen=True)
class CompanionGroup:
    """A group that belongs with another, and how.

    ``carried`` distinguishes the two ways a companion belongs. When the relation
    lists the kind of change in ``carries`` it shares that geometry, about the
    same origin. Otherwise it shares only its **offset** from its counterpart,
    not the shape of its own symbol.

    ``ActuatingSystemOnValve`` lists every kind, so no relation in the table
    shares only an offset today; the distinction is there for one that will.
    """

    group: RepresentationGroup
    relation: str
    #: The assembly member this companion belongs with; the object whose offset
    #: it shares when it is not carried.
    counterpart: PyDexpiBaseModel
    carried: bool


@dataclass(frozen=True)
class Dependant:
    """An object that cannot exist without another, and why."""

    obj: PyDexpiBaseModel
    relation: str
    #: The member this dependant cannot exist without.
    counterpart: PyDexpiBaseModel


def get_dependants(
    model: EngineeringModel,
    objects: list[PyDexpiBaseModel],
    relations: tuple[CompanionRelation, ...] = COMPANION_RELATIONS,
) -> list[Dependant]:
    """Everything that cannot exist without ``objects``.

    The directional reading of the relation table: an ActuatingSystem on a valve
    in ``objects`` is returned, a valve operated by a system in ``objects`` is
    not. One flat pass over the whole batch, each dependant once, and not
    transitive, for the same reason :func:`get_companion_objects` is not.

    Ask it while the objects are in the model with their references set: the
    valve-to-system direction is found through
    ``ActuatingSystem.operatedValveReference.valve``.

    Scans ``PlantModel.actuatingSystems`` only; it never walks the diagram, so
    objects with no valve among them cost one list comprehension.
    """
    found: list[Dependant] = []
    seen: set[int] = {id(obj) for obj in objects}

    for obj in objects:
        for relation in relations:
            for dependant in relation.dependants(model, obj):
                if dependant is None or id(dependant) in seen:
                    continue
                seen.add(id(dependant))
                found.append(Dependant(dependant, relation.name, obj))

    return found


def get_companion_objects(
    model: EngineeringModel,
    obj: PyDexpiBaseModel,
    relations: tuple[CompanionRelation, ...] = COMPANION_RELATIONS,
    transform_kind: str | None = None,
) -> list[tuple[PyDexpiBaseModel, str]]:
    """(companion, relation name) for every object in obj's physical assembly.

    One flat pass, deliberately **not** transitive. Companions of companions
    would cycle (valve -> system -> valve) and would let a growing relation table
    quietly turn the answer for one object into one for the whole drawing.

    ``transform_kind`` filters to relations that list that kind of geometric
    change in ``carries``; ``None`` asks for every relation regardless.
    """
    found: list[tuple[PyDexpiBaseModel, str]] = []
    seen: set[int] = {id(obj)}

    for relation in relations:
        if transform_kind is not None and transform_kind not in relation.carries:
            continue
        for companion in relation.companions(model, obj):
            if companion is None or id(companion) in seen:
                continue
            seen.add(id(companion))
            found.append((companion, relation.name))

    return found


def get_companion_groups(
    model: EngineeringModel,
    obj: PyDexpiBaseModel,
    relations: tuple[CompanionRelation, ...] = COMPANION_RELATIONS,
    transform_kind: str | None = None,
    group_of: Callable[[PyDexpiBaseModel], RepresentationGroup | None] | None = None,
) -> list[CompanionGroup]:
    """Representation groups that belong with obj's own.

    Two rules, each of which a simpler version gets wrong:

    * The assembly is collected from **every object obj's group draws**, not
      only from ``obj``. A valve's group is nested inside its segment's, so the
      segment's group draws the valve -- and its actuator belongs with it too.
    * When two groups in the result nest, the **outermost** is kept. Counting
      both would count the overlap twice; keeping the inner one instead would
      leave out whatever the outer one adds, such as the assembly tag label.

    A companion with no representation group at all is simply absent
    (``OperatedValveReference`` has none), which is not an error.

    ``group_of`` swaps how an object's group is found, never which group. It
    defaults to :func:`get_representation_group_of_object`, a top-down walk that
    is fine for one call and quadratic across a document; a caller answering for
    every object at once passes a lookup built by :func:`build_group_index`.
    """
    if group_of is None:

        def group_of(target: PyDexpiBaseModel) -> RepresentationGroup | None:
            return get_representation_group_of_object(model, target)

    primary = group_of(obj)
    if primary is None:
        return []

    found: list[CompanionGroup] = []
    seen: set[int] = {id(primary)}

    for drawn in represented_objects(primary):
        for companion, relation_name in get_companion_objects(model, drawn, relations):
            group = group_of(companion)
            if group is None or id(group) in seen:
                continue
            seen.add(id(group))
            carried = transform_kind is None or any(
                relation.name == relation_name and transform_kind in relation.carries
                for relation in relations
            )
            found.append(CompanionGroup(group, relation_name, drawn, carried))

    return _maximal(primary, found)


def build_group_index(model: EngineeringModel) -> dict[int, RepresentationGroup]:
    """Map each represented object, by identity, to its representation group.

    One depth-first walk, and **the first group wins** -- the same traversal and
    the same first-match rule :func:`get_representation_group_of_object` uses, so
    the two agree. That matters on Proteus-parsed drawings, where one object can
    be represented by more than one group.

    DEXPI permits multiple RepresentationGroups for one ConceptualObject
    (``RepresentationGroup.Represents`` is 1, its opposite ``*``); first-group-wins
    is the resolution of an object to *its* group used throughout pyDEXPI, rather
    than the only valid representation. Addressing individual representations
    independently would need an API naming a representation or view, not a change
    to this helper in isolation.

    Keyed by ``id()`` rather than by equality: for a real document the two
    coincide, since ids are unique within it, and identity keeps the lookup O(1)
    where the equality-based walk is O(N) per call.
    """
    index: dict[int, RepresentationGroup] = {}
    if model.diagram is None:
        # A conceptual-only model is valid: EngineeringModel.diagram is optional.
        # Nothing is drawn, so nothing is a target.
        return index

    def walk(node) -> None:
        if isinstance(node, RepresentationGroup):
            if node.represents is not None:
                index.setdefault(id(node.represents), node)
            for subgroup in node.groups:
                walk(subgroup)

    for group in model.diagram.groups:
        walk(group)
    return index


def get_move_companions(model: EngineeringModel) -> dict[str, list[str]]:
    """target id -> ids of the groups that keep their place relative to that target.

    The whole-document answer to "what belongs with this object on the sheet",
    for a client that shows it. It is deliberately a loop
    over :func:`get_companion_groups` rather than a second implementation: a
    client-side scan of ``operatedValveReference`` would miss that a segment's
    group draws the valve inside it and so belongs with that valve's actuator,
    and that addressing a ControlledActuator resolves to the whole ActuatingSystem.

    Only targets with at least one companion appear. Keys and values are the same
    object ids the group lookup resolves. It reads the relations for a
    translation, which every relation lists, so the offset-only distinction a
    relation may draw for another kind makes no difference here.

    The object-to-group lookup is indexed once. Calling get_companion_groups per
    object with its default lookup is quadratic -- 97% of the time goes to the
    top-down group walk -- and takes about a second at 1,500 represented objects.
    """
    index = build_group_index(model)

    def group_of(target: PyDexpiBaseModel) -> RepresentationGroup | None:
        return index.get(id(target))

    result: dict[str, list[str]] = {}
    seen: set[int] = set()

    for group in index.values():
        target = group.represents
        if id(target) in seen:
            continue
        seen.add(id(target))

        ids: list[str] = []
        for entry in get_companion_groups(model, target, transform_kind="move", group_of=group_of):
            companion_id = entry.group.represents.id
            if companion_id not in ids:
                ids.append(companion_id)
        if ids:
            result[target.id] = ids

    return result


def represented_objects(group: RepresentationGroup) -> list[PyDexpiBaseModel]:
    """Every conceptual object a group subtree draws, outermost first."""
    objects: list[PyDexpiBaseModel] = []

    def walk(node) -> None:
        if isinstance(node, RepresentationGroup):
            if node.represents is not None:
                objects.append(node.represents)
            for subgroup in node.groups:
                walk(subgroup)

    walk(group)
    return objects


def maximal_groups(groups: list[RepresentationGroup]) -> list[RepresentationGroup]:
    """Drop every group contained in another, keeping the outermost.

    The set that draws everything once. Counting both a group and one nested
    inside it would count the overlap twice, so when the assembly pulls in a
    group that encloses the addressed one, the addressed one drops out and is
    drawn inside it.
    """
    kept: list[RepresentationGroup] = []
    for group in groups:
        if any(other is not group and _contains(other, group) for other in groups):
            continue
        if any(other is group for other in kept):
            continue
        kept.append(group)
    return kept


def _maximal(primary: RepresentationGroup, found: list[CompanionGroup]) -> list[CompanionGroup]:
    """Drop companions that nest with the primary or with another companion.

    Keeping the outermost is what lets a nested member -- a ControlledActuator,
    whose group is inside its ActuatingSystem group -- resolve to the whole
    assembly without being counted twice.
    """
    kept: list[CompanionGroup] = []
    for entry in found:
        if _contains(entry.group, primary):
            # The companion encloses the target: it is the one to keep, and the
            # target is drawn inside it. Only when it shares the kind of change
            # asked about -- a group that contains the target and shares only its
            # offset would count the target twice.
            if entry.carried:
                kept.append(entry)
            continue
        if groups_overlap(primary, entry.group):
            continue
        if any(
            _contains(other.group, entry.group) for other in found if other.group is not entry.group
        ):
            continue
        kept.append(entry)
    return kept


def groups_overlap(first: RepresentationGroup, second: RepresentationGroup) -> bool:
    """True if either group contains the other, or they are the same group."""
    return first is second or _contains(first, second) or _contains(second, first)


def _contains(outer, inner) -> bool:
    if outer is inner:
        return True
    if isinstance(outer, RepresentationGroup):
        return any(_contains(subgroup, inner) for subgroup in outer.groups)
    return False
