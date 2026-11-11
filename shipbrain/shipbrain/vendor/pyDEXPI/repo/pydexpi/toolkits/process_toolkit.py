"""The structure of a DEXPI process model (a block flow diagram), read from the specification.

What the generated classes do not say, and the validation rules and readers of a process
model need, in one place:

- which port class each kind of :class:`ProcessConnection` joins (:data:`PORT_CONNECTIONS`);
- which role names a port of each class should perform (:data:`PORT_ROLE_NAMES`);
- which process classes are abstract (:data:`ABSTRACT_PROCESS_CLASSES`);
- where ports are held (:data:`PORT_OWNER_SLOTS`), with identity-based walks over the owners,
  the ports and the step hierarchy;
- which step holds a step detail, which instrumentation system an activity, and which object
  a value (:func:`step_holding`, :func:`system_holding`, :func:`value_holder`).

Every table is taken from the DEXPI 2.0.1 specification source,
``src/model/Process/Process/Process.py`` at tag ``V2.0.1`` of
https://gitlab.com/dexpi/Specification (commit ``eef0f0c6``), cited by line below. The class
descriptions there are what fix the port of a connection ("a flow of fluid or solid material
between two MaterialPort objects") and the role names ("should have one of the following
Names"); neither reaches the generated classes, whose ``source``/``target`` are typed ``Port``
and whose ``performedRoles`` are any ``Role``.

The idea of one table holding a port class's role names and the connection that joins it, and
of taking the role names from the specification's own text, comes from Sophia Rupprecht's
(@SoRupprecht) DEXPI process tools.

Nothing here edits a model.
"""

from __future__ import annotations

from collections.abc import Iterable, Iterator, Mapping
from types import MappingProxyType

from pydexpi.pydexpi_classes.pydexpi_classes import (
    ElectricalEnergyFlow,
    ElectricalEnergyPort,
    EnergyFlow,
    EnergyPort,
    InformationFlow,
    InformationPort,
    InstrumentationActivity,
    InstrumentationSystemActivity,
    MaterialPort,
    MechanicalEnergyFlow,
    MechanicalEnergyPort,
    Port,
    PortDirection,
    ProcessConnection,
    ProcessModel,
    ProcessStep,
    ProcessStepDetail,
    PyDexpiBaseModel,
    QualifiedValue,
    Role,
    Stream,
    ThermalEnergyFlow,
    ThermalEnergyPort,
)
from pydexpi.toolkits.model_toolkit import get_all_instances_in_model

__all__ = [
    "ABSTRACT_PROCESS_CLASSES",
    "DEFAULT_ROLES",
    "PORT_CONNECTIONS",
    "PORT_OWNER_SLOTS",
    "PORT_ROLE_NAMES",
    "SPECIFICATION_SOURCE",
    "connection_class_for_port",
    "connections_ending_at",
    "default_role",
    "find_role",
    "is_abstract_process_class",
    "iter_process_steps",
    "port_class_for_connection",
    "port_owners",
    "port_slot",
    "ports_of",
    "role_names_for",
    "step_holding",
    "system_holding",
    "value_holder",
]

#: Where the tables below are read from: the specification's Process package at tag V2.0.1.
SPECIFICATION_SOURCE = (
    "https://gitlab.com/dexpi/Specification/-/blob/V2.0.1/src/model/Process/Process/Process.py"
)

#: The port class each connection class joins, most specific first. From the connection classes'
#: descriptions at V2.0.1: ``Stream`` (L4302) "a flow of fluid or solid material between two
#: MaterialPort objects"; ``InformationFlow`` (L1027) "between two instances of InformationPort";
#: ``ElectricalEnergyFlow`` (L925), ``MechanicalEnergyFlow`` (L977) and ``ThermalEnergyFlow``
#: (L1008) between two ports of their own energy form; ``EnergyFlow`` (L900) "between two
#: instances of EnergyPort", for energy of an unspecified form.
PORT_CONNECTIONS: Mapping[type[Port], type[ProcessConnection]] = MappingProxyType(
    {
        MaterialPort: Stream,
        InformationPort: InformationFlow,
        ElectricalEnergyPort: ElectricalEnergyFlow,
        MechanicalEnergyPort: MechanicalEnergyFlow,
        ThermalEnergyPort: ThermalEnergyFlow,
        EnergyPort: EnergyFlow,
    }
)

#: The role names a port of each class "should" perform, from the port classes' descriptions at
#: V2.0.1: ``ElectricalEnergyPort`` L737-751, ``MechanicalEnergyPort`` L757-768,
#: ``ThermalEnergyPort`` L773-784, ``InformationPort`` L788-803, ``MaterialPort`` L807-846.
#: ``EnergyPort`` (L725) lists none: "in practice, this type is abstract". "Should" makes this a
#: recommendation, which ``pydexpi_process_port_role_names`` reports.
PORT_ROLE_NAMES: Mapping[type[Port], tuple[str, ...]] = MappingProxyType(
    {
        ElectricalEnergyPort: ("Instrumentation", "Power", "Utility"),
        MechanicalEnergyPort: ("Input", "Output"),
        ThermalEnergyPort: ("Input", "Output"),
        InformationPort: ("Feedback", "Input", "Output", "Override", "Setpoint"),
        MaterialPort: (
            "Air",
            "BottomProduct",
            "ChemicalFeed",
            "Discharge",
            "Drain",
            "Exhaust",
            "Feed",
            "Fuel",
            "HeavyLiquid",
            "Inlet",
            "LeanSolvent",
            "LightLiquid",
            "Liquid",
            "LiquidInlet",
            "LiquidOutlet",
            "Outlet",
            "Product",
            "Reboil",
            "Reflux",
            "Relief",
            "RichSolvent",
            "Sidedraw",
            "Suction",
            "TopProduct",
            "Vapour",
            "VapourInlet",
            "VapourOutlet",
            "Vent",
            "Waste",
        ),
    }
)

#: The conventional role of a port of each class, as (inlet, outlet). A pyDEXPI convention,
#: each name taken from the class's own list above: an electrical port has no
#: direction-dependent role, so it is ``Power`` either way. ``EnergyPort`` has no list, so it has
#: no conventional role.
DEFAULT_ROLES: Mapping[type[Port], tuple[str, str]] = MappingProxyType(
    {
        MaterialPort: ("Inlet", "Outlet"),
        InformationPort: ("Input", "Output"),
        ElectricalEnergyPort: ("Power", "Power"),
        MechanicalEnergyPort: ("Input", "Output"),
        ThermalEnergyPort: ("Input", "Output"),
    }
)

#: The process classes DEXPI 2.0.1 declares ``ABSTRACT_CLASS``, by name and line:
#: ``InstrumentationActivity`` L128, ``CalculatingProcessVariable`` L158, ``MaterialComponent``
#: L430, ``Port`` L677, ``ProcessConnection`` L863, ``ProcessStep`` L1044, ``Splitting`` L2869,
#: ``SteeringFlow`` L2916, ``StoringMaterial`` L3157, ``StoringEnergy`` L3285 and
#: ``ProcessStepDetail`` L4131. The generated classes do not mark them, so code that needs to
#: know asks here.
ABSTRACT_PROCESS_CLASSES: frozenset[str] = frozenset(
    {
        "CalculatingProcessVariable",
        "InstrumentationActivity",
        "MaterialComponent",
        "Port",
        "ProcessConnection",
        "ProcessStep",
        "ProcessStepDetail",
        "Splitting",
        "SteeringFlow",
        "StoringEnergy",
        "StoringMaterial",
    }
)

#: The three places a port is held, as ``(owner class, composition attribute)``: a step's
#: ``ports``, and since DEXPI 2.0.1 a step detail's ``ports`` and an instrumentation activity's
#: ``informationPorts`` (InformationPorts only).
PORT_OWNER_SLOTS: tuple[tuple[type[PyDexpiBaseModel], str], ...] = (
    (ProcessStep, "ports"),
    (ProcessStepDetail, "ports"),
    (InstrumentationActivity, "informationPorts"),
)


def is_abstract_process_class(cls: type) -> bool:
    """Whether the specification declares *cls* abstract (:data:`ABSTRACT_PROCESS_CLASSES`)."""
    return cls.__name__ in ABSTRACT_PROCESS_CLASSES


def _most_specific[V](table: Mapping[type, V], cls: type) -> V | None:
    """The entry of the first class in *cls*'s MRO that *table* holds, or None."""
    return next((table[base] for base in cls.__mro__ if base in table), None)


def connection_class_for_port(port_class: type[Port]) -> type[ProcessConnection] | None:
    """The connection class that joins ports of *port_class*, or None for an abstract ``Port``."""
    return _most_specific(PORT_CONNECTIONS, port_class)


def port_class_for_connection(
    connection_class: type[ProcessConnection],
) -> type[Port] | None:
    """The port class both ends of a *connection_class* are, or None for ``ProcessConnection``.

    The most specific connection class in its MRO decides: a ``ThermalEnergyFlow`` joins
    ``ThermalEnergyPort`` s, an ``EnergyFlow`` any ``EnergyPort``.
    """
    by_connection = {connection: port for port, connection in PORT_CONNECTIONS.items()}
    return _most_specific(by_connection, connection_class)


def role_names_for(port_class: type[Port]) -> tuple[str, ...] | None:
    """The role names the specification lists for *port_class*, or None where it lists none."""
    return _most_specific(PORT_ROLE_NAMES, port_class)


def default_role(port_class: type[Port], direction: PortDirection) -> str | None:
    """The conventional role of a port of *port_class* facing *direction*, or None."""
    roles = _most_specific(DEFAULT_ROLES, port_class)
    if roles is None:
        return None
    return roles[0] if direction == PortDirection.INLET else roles[1]


def port_slot(owner: PyDexpiBaseModel) -> str | None:
    """The attribute *owner* holds its ports in (:data:`PORT_OWNER_SLOTS`), or None."""
    return next((slot for cls, slot in PORT_OWNER_SLOTS if isinstance(owner, cls)), None)


def ports_of(owner: PyDexpiBaseModel) -> list[Port]:
    """The ports *owner* holds, in order; empty for an object that holds none."""
    slot = port_slot(owner)
    return list(getattr(owner, slot, None) or []) if slot is not None else []


def port_owners(model: PyDexpiBaseModel) -> dict[int, tuple[PyDexpiBaseModel, str]]:
    """Every port in *model*, by identity, mapped to ``(owner, slot)``: one walk for all.

    Keyed by ``id(port)`` so that two ports with equal fields, or a stray copy under a known
    id, are never confused (AGENTS.md, the ``in`` trap).
    """
    owners: dict[int, tuple[PyDexpiBaseModel, str]] = {}
    for owner in get_all_instances_in_model(model):
        slot = port_slot(owner)
        if slot is None:
            continue
        for port in getattr(owner, slot, None) or []:
            owners.setdefault(id(port), (owner, slot))
    return owners


def connections_ending_at(
    model: PyDexpiBaseModel, ports: Iterable[Port]
) -> list[ProcessConnection]:
    """Every connection in *model* whose ``source`` or ``target`` is one of *ports*, by identity."""
    wanted = {id(port) for port in ports}
    return [
        connection
        for connection in get_all_instances_in_model(model)
        if isinstance(connection, ProcessConnection)
        and (
            id(connection.__dict__.get("source")) in wanted
            or id(connection.__dict__.get("target")) in wanted
        )
    ]


def iter_process_steps(process_model: ProcessModel) -> Iterator[tuple[ProcessStep, object]]:
    """Every step of *process_model*, depth first, with the object holding it.

    The holder is the ``ProcessModel`` for a top-level step and the parent step for one in
    ``subProcessSteps``. Cycle-safe: a step reached a second time, which only a malformed model
    composes, is not descended into again (an idea from @SoRupprecht's hierarchy walk).
    """
    seen: set[int] = set()
    pending: list[tuple[ProcessStep, object]] = [
        (step, process_model) for step in reversed(process_model.processSteps or [])
    ]
    while pending:
        step, holder = pending.pop()
        if id(step) in seen:
            continue
        seen.add(id(step))
        yield step, holder
        pending.extend((child, step) for child in reversed(step.subProcessSteps or []))


def step_holding(process_model: ProcessModel, detail: ProcessStepDetail) -> ProcessStep | None:
    """The step whose ``processStepDetails`` holds *detail*, by identity, or None.

    A ``ProcessStepDetail`` is composed by one step and by nothing else (DEXPI 2.0.1,
    ``ProcessStep.ProcessStepDetails``, Process.py L1117-1120 at ``V2.0.1``).
    """
    for step, _holder in iter_process_steps(process_model):
        if any(held is detail for held in step.processStepDetails or []):
            return step
    return None


def system_holding(
    process_model: ProcessModel, activity: InstrumentationActivity
) -> InstrumentationSystemActivity | None:
    """The system whose ``instrumentationActivities`` holds *activity*, by identity, or None.

    An ``InstrumentationActivity`` is composed by an ``InstrumentationSystemActivity`` and by
    nothing else (``InstrumentationSystemActivity.InstrumentationActivities``, Process.py
    L399-402 at ``V2.0.1``), and the model composes the systems.
    """
    for system in process_model.instrumentationSystemActivities or []:
        if any(held is activity for held in system.instrumentationActivities or []):
            return system
    return None


def value_holder(
    model: PyDexpiBaseModel, value: QualifiedValue
) -> tuple[PyDexpiBaseModel, str] | None:
    """The object of *model* that composes *value*, and the property it holds it in, or None.

    By identity, over one walk: what a ``MeasuringProcessVariable.measuredVariableReference``
    names is a value some step, detail, connection or state type holds -- its ``temperature``,
    its ``pressure`` -- and a ``QualifiedValue`` does not say which.
    """
    for holder in get_all_instances_in_model(model):
        for name, field in type(holder).model_fields.items():
            extra = field.json_schema_extra
            if not isinstance(extra, dict) or extra.get("attribute_category") != "composition":
                continue
            held = holder.__dict__.get(name)
            if held is value or (isinstance(held, list) and any(item is value for item in held)):
                return holder, name
    return None


def find_role(process_model: ProcessModel, name: str) -> Role | None:
    """The first ``Role`` named *name* that *process_model* owns, or None."""
    return next((role for role in process_model.roles or [] if role.name == name), None)
