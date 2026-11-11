"""Material components, templates and states of a DEXPI 2.0.1 process model, and how they pair.

DEXPI 2.0.1 ownership, which everything here follows:

- ``ProcessModel`` owns ``MaterialComponents``, ``ListsOfMaterialComponents``,
  ``MaterialTemplates`` and ``MaterialStates``;
- a ``MaterialState`` owns its ``Phases`` and its ``State`` (``MaterialStateType`` s), and a
  ``MaterialStateType`` its ``Composition``;
- a ``MaterialTemplate`` references its one ``ListOfMaterialComponents`` (1..1, one list per
  template), which references its ``MaterialComponent`` s in order (the ``COMPONENT-ORDER``
  deviation: the specification calls it "an ordered list");
- a ``Stream`` references a template and a state, a ``MaterialPort`` a template.

**The two opposite bounds are read differently, on purpose.** The specification gives both
references an opposite upper bound of 1, each marked ``# TODO check multiplicities``
(Process.py at V2.0.1): ``MaterialTemplate.ListOfComponents`` (L665-671), so a list belongs to
one template, and ``ListOfMaterialComponents.Component`` (L418-424), so a component would belong
to one list. pyDEXPI keeps the first: every template has a list of its own. It does not keep the
second: a component is one chemical of the model, and two templates that both hold water list
the same component -- which is what lets two templates agree at all, since they are compared by
component id. Read literally, the bound would need one water per template, and every pairing
check here would call two such templates different. The corpus cannot settle it (bpmn2dexpi's two
templates share no component), so this is pyDEXPI's reading, not DEXPI's statement.

**Order is data.** The specification's ``Composition`` (Process.py L16-26 at V2.0.1): "The order
of items in the array is determined by the list of chemical components ... in the corresponding
MaterialTemplate". So value ``i`` of a fraction vector belongs to component ``i`` of the template
the vector is read against.

**Pairing.** A state is read against a template through every stream that references the state:
the stream's own ``materialTemplateReference`` and its two end ports', with those of every port
delegating an end port, at any depth: a delegated port takes part in its super port's connection
(:mod:`~pydexpi.toolkits.process_hierarchy`), so it carries the same material. A state may be
shared by several streams, so a length check alone would let one vector be read against two
different
component lists -- ``[A, B]`` and ``[B, A]``, or ``[A, B]`` and ``[A, C]``. Every template paired
with a state must therefore list the same components, by id, in the same order
(:func:`state_component_order`), and a stream must agree with its own ports.
``pydexpi_process_shared_state_component_order`` reports a pairing that breaks this.

**One composition, one length.** Both fraction vectors of a ``Composition`` -- and every value
of either property -- are read against the same list, one value per component, so they hold the
same number of values whatever the list is (:func:`fraction_lengths`). That needs no template:
``pydexpi_composition_fraction_vector_lengths`` reports a composition whose vectors disagree.

**What a state's fractions were written against is not stored.** DEXPI pairs a state with a
template only through a stream, so a state no stream pairs with a template carries fractions in
an order the document records nowhere (:func:`unordered_fractions`). A state no stream pairs yet
and a state whose pairing is gone look alike, so whatever template a later pairing names, the
vectors are read against it with only their lengths checked;
``pydexpi_process_fractions_read_against_template`` reports the state while it is so.
"""

from __future__ import annotations

from collections.abc import Iterator, Mapping, Sequence
from dataclasses import dataclass
from typing import Any

from pydexpi.pydexpi_classes.pydexpi_classes import (
    Composition,
    CustomMaterialComponent,
    ListOfMaterialComponents,
    MaterialComponent,
    MaterialPort,
    MaterialState,
    MaterialStateType,
    MaterialTemplate,
    PhysicalQuantityVector,
    ProcessModel,
    PureMaterialComponent,
    PyDexpiBaseModel,
    QualifiedValue,
    Stream,
)
from pydexpi.toolkits.display_name import referenced_object_name
from pydexpi.toolkits.process_hierarchy import listed_below
from pydexpi.toolkits.qualified_values import FRACTION_PROPERTIES

__all__ = [
    "CUSTOM_IDENTIFYING_ATTRIBUTES",
    "FRACTION_ATTRIBUTES",
    "ONE_LENGTH",
    "PURE_IDENTIFYING_ATTRIBUTES",
    "FractionVector",
    "MaterialComponentConflict",
    "Overrides",
    "Pairing",
    "PairingConflict",
    "component_ids",
    "component_names",
    "describe_component",
    "describe_lengths",
    "find_equivalent",
    "first_difference",
    "fraction_lengths",
    "fraction_vectors",
    "fraction_vectors_of_type",
    "lengths_disagree",
    "pairing_conflicts",
    "pairings_of_state",
    "reading_template",
    "state_component_order",
    "state_holding",
    "state_types_of",
    "stream_material_ports",
    "stream_pairings",
    "stream_template_conflicts",
    "streams_referencing",
    "templates_using",
    "unordered_fractions",
    "vectors_read_against",
]

#: The attributes identifying a pure and a custom component, most specific first: what tells two
#: components of one kind apart.
PURE_IDENTIFYING_ATTRIBUTES = ("chEBI_identifier", "iUPAC_identifier", "identifier")
CUSTOM_IDENTIFYING_ATTRIBUTES = ("projectReference", "identifier")

#: The fraction-vector properties of a Composition, in field order.
FRACTION_ATTRIBUTES: tuple[str, ...] = tuple(name for _owner, name in FRACTION_PROPERTIES)

#: Why the fraction vectors of one composition cannot differ in length, whatever they are read
#: against: the one sentence the rule's message ends with.
ONE_LENGTH = (
    "Every fraction vector of one composition is read against the same list of components, one "
    "value per component, so they all hold the same number of values."
)


class MaterialComponentConflict(ValueError):
    """A component shares an identifying attribute with a held one and differs in another, or
    matches more than one held component."""


def _identifying(component: MaterialComponent) -> tuple[str, ...]:
    if isinstance(component, PureMaterialComponent):
        return PURE_IDENTIFYING_ATTRIBUTES
    if isinstance(component, CustomMaterialComponent):
        return CUSTOM_IDENTIFYING_ATTRIBUTES
    return ("identifier",)


def _set(value: object) -> bool:
    """Whether an identifying value says something: not None, not Undefined, not blank."""
    return isinstance(value, str) and bool(value.strip())


def _shared(first: MaterialComponent, second: MaterialComponent) -> list[str]:
    """The identifying attributes set on both components, when they are of one kind."""
    if type(first) is not type(second):
        return []
    return [
        name
        for name in _identifying(first)
        if _set(getattr(first, name, None)) and _set(getattr(second, name, None))
    ]


def describe_component(component: MaterialComponent) -> str:
    """A component as a message names it: its class and the identifying values it sets."""
    values = ", ".join(
        f"{name}={getattr(component, name)!r}"
        for name in _identifying(component)
        if _set(getattr(component, name, None))
    )
    return f"{type(component).__name__}({values})"


def find_equivalent(
    candidates: Sequence[MaterialComponent], component: MaterialComponent
) -> MaterialComponent | None:
    """The one candidate *component* is the same component as, or None.

    Every candidate is checked, so the outcome does not depend on their order.

    Raises
    ------
    MaterialComponentConflict
        When an equivalent candidate differs from *component* in another identifying attribute
        both set -- the same ChEBI identifier with two IUPAC names names two chemicals, or one
        wrongly -- or when *component* is equivalent to more than one candidate.
    """
    equivalents = [
        candidate
        for candidate in candidates
        if any(
            getattr(candidate, name) == getattr(component, name)
            for name in _shared(candidate, component)
        )
    ]
    for candidate in equivalents:
        differing = [
            name
            for name in _shared(candidate, component)
            if getattr(candidate, name) != getattr(component, name)
        ]
        if differing:
            raise MaterialComponentConflict(
                f"{describe_component(component)} conflicts with "
                f"{describe_component(candidate)}: they share an identifying attribute but "
                f"differ in {', '.join(differing)}. Correct whichever of the two names the wrong "
                "chemical."
            )
    if len(equivalents) > 1:
        raise MaterialComponentConflict(
            f"{describe_component(component)} matches more than one component the model holds: "
            f"{', '.join(describe_component(candidate) for candidate in equivalents)}. Use "
            "identifying attributes that name only one of them."
        )
    return equivalents[0] if equivalents else None


def component_ids(template: MaterialTemplate | None) -> list[str] | None:
    """The ids of *template*'s components, in list order, or None without a template or list."""
    if template is None:
        return None
    components = template.__dict__.get("listOfComponents")
    if components is None:
        return None
    return [component.id for component in components.component or []]


def component_names(template: MaterialTemplate | None) -> list[str] | None:
    """*template*'s components as a message names them, in list order; None as
    :func:`component_ids` is. Ids identify, and decide whether two lists agree; a person reads
    the names."""
    if template is None:
        return None
    components = template.__dict__.get("listOfComponents")
    if components is None:
        return None
    return [referenced_object_name(component) for component in components.component or []]


def first_difference(first: Sequence[str], second: Sequence[str]) -> int | None:
    """The first position at which two id lists differ (the shorter one's length if one is a
    prefix of the other), or None when they are identical."""
    for position, (a, b) in enumerate(zip(first, second, strict=False)):
        if a != b:
            return position
    if len(first) != len(second):
        return min(len(first), len(second))
    return None


@dataclass(frozen=True)
class Pairing:
    """One template a state is read against, and the stream or port that pairs them."""

    template: MaterialTemplate
    via: Stream | MaterialPort


#: References read in place of the model's own: ``(id(holder), attribute) -> value``. A pairing
#: is then read as if those references held those values; the model is not changed.
Overrides = dict[tuple[int, str], object]


def _reference(holder: PyDexpiBaseModel, attribute: str, overrides: Overrides | None) -> Any:
    if overrides is not None and (id(holder), attribute) in overrides:
        return overrides[(id(holder), attribute)]
    return holder.__dict__.get(attribute)


def streams_referencing(
    process_model: ProcessModel, state: MaterialState, overrides: Overrides | None = None
) -> list[Stream]:
    """Every stream of *process_model* whose ``materialStateReference`` is *state*, by identity."""
    return [
        connection
        for connection in process_model.processConnections or []
        if isinstance(connection, Stream)
        and _reference(connection, "materialStateReference", overrides) is state
    ]


def stream_material_ports(stream: Stream) -> list[MaterialPort]:
    """The material ports that carry *stream*'s material: its source, then its target, each
    followed by the ports delegating it, at any depth.

    A delegated port takes part in its super port's connection, so its template is read against
    the same material as the end port's. Delegates are read down ``subReference``
    (:func:`~pydexpi.toolkits.process_hierarchy.listed_below`); one its super port does not list
    is ``pydexpi_process_port_delegation_consistent``'s to report, and is not paired.
    """
    ports: list[MaterialPort] = []
    for end in ("source", "target"):
        port = stream.__dict__.get(end)
        if not isinstance(port, MaterialPort):
            continue
        ports.append(port)
        ports += [below for below in listed_below(port) if isinstance(below, MaterialPort)]
    return ports


def stream_pairings(stream: Stream, overrides: Overrides | None = None) -> list[Pairing]:
    """The templates a stream names itself and through the ports that carry its material
    (:func:`stream_material_ports`: its two ends and their delegates), in that order."""
    found = []
    template = _reference(stream, "materialTemplateReference", overrides)
    if template is not None:
        found.append(Pairing(template, stream))
    for port in stream_material_ports(stream):
        template = _reference(port, "materialTemplateReference", overrides)
        if template is not None:
            found.append(Pairing(template, port))
    return found


def pairings_of_state(
    process_model: ProcessModel, state: MaterialState, overrides: Overrides | None = None
) -> list[Pairing]:
    """Every template *state* is read against: through each stream referencing it, the stream's
    own template and its end ports'. In stream order; a template may appear more than once."""
    return [
        pairing
        for stream in streams_referencing(process_model, state, overrides)
        for pairing in stream_pairings(stream, overrides)
    ]


@dataclass(frozen=True)
class PairingConflict:
    """Two templates read against one material, listing different components or orders."""

    first: Pairing
    second: Pairing
    position: int
    """The first position at which their component ids differ."""

    def describe(self) -> str:
        """Both templates, what pairs each, and the component each lists at the first differing
        position -- by name, since a message is the only pointer to an object it refers to."""
        first_names = component_names(self.first.template) or []
        second_names = component_names(self.second.template) or []

        def at(names: list[str]) -> str:
            return names[self.position] if self.position < len(names) else "nothing"

        return (
            f"{referenced_object_name(self.first.template)} (through "
            f"{referenced_object_name(self.first.via)}) lists {at(first_names)} at position "
            f"{self.position} of {len(first_names)} components, and "
            f"{referenced_object_name(self.second.template)} (through "
            f"{referenced_object_name(self.second.via)}) lists {at(second_names)} there, of "
            f"{len(second_names)}"
        )


def _determinate(pairings: Sequence[Pairing]) -> list[Pairing]:
    """The pairings whose template has its list of components.

    A template without one -- a lenient load keeps a template whose required ``ListOfComponents``
    did not resolve, as in the CO2 terminal export -- says nothing about length or order, so it
    is left out rather than read as listing no components.
    """
    return [pairing for pairing in pairings if component_ids(pairing.template) is not None]


def pairing_conflicts(pairings: Sequence[Pairing]) -> list[PairingConflict]:
    """Each pairing whose template's ordered component ids differ from the first pairing's.

    Templates are compared by their ordered component ids, so two distinct templates listing the
    same components in the same order agree. A template without its list is left out
    (:func:`_determinate`).
    """
    known = _determinate(pairings)
    if not known:
        return []
    first = known[0]
    reference = component_ids(first.template) or []
    conflicts = []
    for other in known[1:]:
        position = first_difference(reference, component_ids(other.template) or [])
        if position is not None:
            conflicts.append(PairingConflict(first, other, position))
    return conflicts


def state_component_order(
    process_model: ProcessModel, state: MaterialState, overrides: Overrides | None = None
) -> tuple[list[str] | None, list[PairingConflict]]:
    """The one ordered component-id list *state* is read against, and any disagreement.

    Returns ``(ids, conflicts)``: ``ids`` is ``None`` when no template with a list of components
    is paired with the state, so no length or order is determinable; ``conflicts`` lists every
    pairing that disagrees with the first.
    """
    known = _determinate(pairings_of_state(process_model, state, overrides))
    if not known:
        return None, []
    return component_ids(known[0].template), pairing_conflicts(known)


def reading_template(
    process_model: ProcessModel, state: MaterialState, overrides: Overrides | None = None
) -> MaterialTemplate | None:
    """The template whose list :func:`state_component_order` reads *state* against, or None."""
    known = _determinate(pairings_of_state(process_model, state, overrides))
    return known[0].template if known else None


def stream_template_conflicts(
    stream: Stream, overrides: Overrides | None = None
) -> list[PairingConflict]:
    """Where a stream's own template and its end ports' templates disagree."""
    return pairing_conflicts(stream_pairings(stream, overrides))


@dataclass(frozen=True)
class FractionVector:
    """One fraction vector of a state, with what holds it."""

    state_type: MaterialStateType
    composition: Composition
    attribute: str
    qualified_value: QualifiedValue

    @property
    def length(self) -> int | None:
        """The vector's length, or None when the value is not a vector (``Undefined``)."""
        value = self.qualified_value.__dict__.get("value")
        if not isinstance(value, PhysicalQuantityVector):
            return None
        return len(value.values or [])

    def describe(self) -> str:
        """Where the vector is, as a message names it."""
        return (
            f"{self.attribute} {referenced_object_name(self.qualified_value)} of "
            f"{referenced_object_name(self.state_type)}"
        )


def state_types_of(state: MaterialState) -> list[MaterialStateType]:
    """A state's phase types, then its state type."""
    types = list(state.phases or [])
    if state.state is not None:
        types.append(state.state)
    return types


def fraction_vectors_of_type(state_type: MaterialStateType) -> Iterator[FractionVector]:
    """The fraction vectors one state type's composition holds."""
    composition = state_type.composition
    if composition is None:
        return
    for attribute in FRACTION_ATTRIBUTES:
        for qualified_value in composition.__dict__.get(attribute) or []:
            yield FractionVector(state_type, composition, attribute, qualified_value)


def fraction_vectors(state: MaterialState) -> list[FractionVector]:
    """Every fraction vector a state holds, phases first."""
    return [
        vector
        for state_type in state_types_of(state)
        for vector in fraction_vectors_of_type(state_type)
    ]


def fraction_lengths(
    composition: Composition | None = None,
    *,
    values: Mapping[str, Sequence[QualifiedValue]] | None = None,
) -> list[tuple[str, int, int]]:
    """``(property, position, number of values)`` of every fraction vector, in field order.

    Read off *composition*, with *values* -- a fraction property mapped to its QualifiedValues
    -- in place of what the composition holds for that property, to ask about values the
    composition does not hold. A value that is no vector
    (``Undefined``) has no length and is left out.
    """
    found: list[tuple[str, int, int]] = []
    for attribute in FRACTION_ATTRIBUTES:
        if values is not None and attribute in values:
            held: Sequence[QualifiedValue] = values[attribute]
        elif composition is not None:
            held = composition.__dict__.get(attribute) or []
        else:
            held = []
        for position, qualified_value in enumerate(held):
            value = qualified_value.__dict__.get("value")
            if isinstance(value, PhysicalQuantityVector):
                found.append((attribute, position, len(value.values or [])))
    return found


def lengths_disagree(lengths: Sequence[tuple[str, int, int]]) -> bool:
    """Whether the vectors :func:`fraction_lengths` found hold different numbers of values.

    The fraction vectors of one composition are all read against one list of components, one
    value per component, so two of different lengths cannot both be right, whatever the list.
    """
    return len({count for _attribute, _position, count in lengths}) > 1


def describe_lengths(lengths: Sequence[tuple[str, int, int]]) -> str:
    """``massFractions[0] has 2 values and moleFractions[0] has 3 values``: each vector by the
    property and position that hold it. Empty for no vector."""
    parts = [
        f"{attribute}[{position}] has {count} value{'' if count == 1 else 's'}"
        for attribute, position, count in lengths
    ]
    return " and ".join([", ".join(parts[:-1]), parts[-1]] if len(parts) > 1 else parts)


def unordered_fractions(process_model: ProcessModel, state: MaterialState) -> list[FractionVector]:
    """The fraction vectors of *state* that no list of components orders: every vector it
    holds, when no template with a list is paired with it; none otherwise.

    The template a state is read against is the only record of which component each value
    belongs to (:func:`state_component_order`). A state no stream references, one whose streams
    and their ports name no template, and one whose templates lack their list all have none.
    """
    ids, _conflicts = state_component_order(process_model, state)
    if ids is not None:
        return []
    return [vector for vector in fraction_vectors(state) if vector.length is not None]


def state_holding(process_model: ProcessModel, obj: object) -> MaterialState | None:
    """The state that composes *obj* -- a state type or a composition -- by identity, or None."""
    for state in process_model.materialStates or []:
        for state_type in state_types_of(state):
            if state_type is obj or state_type.composition is obj:
                return state
    return None


def templates_using(
    process_model: ProcessModel, component_list: ListOfMaterialComponents
) -> list[MaterialTemplate]:
    """The templates whose ``listOfComponents`` is *component_list*, by identity."""
    return [
        template
        for template in process_model.materialTemplates or []
        if template.__dict__.get("listOfComponents") is component_list
    ]


def vectors_read_against(
    process_model: ProcessModel, templates: Sequence[MaterialTemplate]
) -> list[FractionVector]:
    """Every fraction vector of every state paired with one of *templates*, each once."""
    wanted = {id(template) for template in templates}
    found: list[FractionVector] = []
    seen: set[int] = set()
    for state in process_model.materialStates or []:
        if id(state) in seen:
            continue
        pairings = pairings_of_state(process_model, state)
        if any(id(pairing.template) in wanted for pairing in pairings):
            seen.add(id(state))
            found.extend(fraction_vectors(state))
    return found
