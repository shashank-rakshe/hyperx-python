"""One summary of what a model holds, for every front end that prints one.

`pydexpi info` and the MCP server's `get_model_summary` used to count separately and disagree: one
walked the whole model, the other read a `PlantModel`'s top-level lists -- and so found nothing in
a `ProcessModel` -- and each assembled tags its own way. :func:`summarize_model` is the one
definition both use.

Counts are by **type, over the whole composition tree**, so nesting does not hide an object: an
item owned by a sub-assembly counts like a top-level one. "Equipment" is every
``TaggedPlantItem``, which includes separately tagged column sections; "piping components" are
every ``PipingComponent``, valves and inline measuring elements included. A process model's
flows are counted once in all (``process_connection_count``, every ``ProcessConnection``) and
once per kind (``stream_count``, ``energy_flow_count``, ``information_flow_count``), so a flow
that is not a ``Stream`` is not missing from the summary. Equipment tags come from
:func:`~pydexpi.toolkits.display_name.get_tag`; an instrumentation function's tag is its loop tag,
letters included (``"PICSA-4712.02"``), from
:func:`~pydexpi.toolkits.display_name.instrument_tag`.
"""

from collections.abc import Callable, Iterable
from dataclasses import dataclass
from typing import Any

from pydexpi.pydexpi_classes.pydexpi_classes import (
    EnergyFlow,
    EngineeringModel,
    InformationFlow,
    PipingComponent,
    PipingNetworkSegment,
    PipingNetworkSystem,
    ProcessConnection,
    ProcessInstrumentationFunction,
    ProcessStep,
    PyDexpiBaseModel,
    Stream,
    TaggedPlantItem,
)
from pydexpi.toolkits.display_name import get_display_name, get_tag, instrument_tag
from pydexpi.toolkits.model_toolkit import get_all_instances_in_model


@dataclass(frozen=True)
class SummaryEntry:
    """One listed object: id, DEXPI class name, tag (``None`` when it has none) and caption."""

    id: str
    type: str
    tag: str | None
    display_name: str


@dataclass(frozen=True)
class ModelSummary:
    """What a model holds, counted by kind.

    Attributes
    ----------
    conceptual_model_type : str or None
        ``"PlantModel"``, ``"ProcessModel"``, or ``None`` for a model without a conceptual model.
    equipment : tuple[SummaryEntry, ...]
        Every ``TaggedPlantItem``, tagged by ``get_tag``.
    instruments : tuple[SummaryEntry, ...]
        Every ``ProcessInstrumentationFunction``, tagged by ``instrument_tag``.
    piping_system_count, piping_segment_count, piping_component_count : int
        ``PipingNetworkSystem``, ``PipingNetworkSegment`` and ``PipingComponent`` instances.
    process_step_count : int
        ``ProcessStep`` instances, the content of a process model.
    process_connection_count : int
        Every ``ProcessConnection``: streams, energy flows and information flows together.
    stream_count, energy_flow_count, information_flow_count : int
        ``Stream``, ``EnergyFlow`` (thermal, mechanical and electrical included) and
        ``InformationFlow`` instances: the connections by kind.
    has_diagram : bool
        Whether the model carries a diagram.
    total_objects : int
        Every object in the composition tree, graphics included.
    """

    conceptual_model_type: str | None
    equipment: tuple[SummaryEntry, ...]
    instruments: tuple[SummaryEntry, ...]
    piping_system_count: int
    piping_segment_count: int
    piping_component_count: int
    process_step_count: int
    process_connection_count: int
    stream_count: int
    energy_flow_count: int
    information_flow_count: int
    has_diagram: bool
    total_objects: int

    @property
    def equipment_tags(self) -> list[str]:
        """The equipment's tags, in model order, skipping untagged items."""
        return [entry.tag for entry in self.equipment if entry.tag]

    @property
    def instrument_tags(self) -> list[str]:
        """The instrumentation functions' tags, in model order, skipping untagged ones."""
        return [entry.tag for entry in self.instruments if entry.tag]

    def to_dict(self) -> dict[str, Any]:
        """A flat, JSON-ready dict: counts, plus the tag lists when they are not empty."""
        result: dict[str, Any] = {
            "conceptual_model_type": self.conceptual_model_type,
            "equipment_count": len(self.equipment),
            "instrument_count": len(self.instruments),
            "piping_system_count": self.piping_system_count,
            "piping_segment_count": self.piping_segment_count,
            "piping_component_count": self.piping_component_count,
            "process_step_count": self.process_step_count,
            "process_connection_count": self.process_connection_count,
            "stream_count": self.stream_count,
            "energy_flow_count": self.energy_flow_count,
            "information_flow_count": self.information_flow_count,
            "has_diagram": self.has_diagram,
            "total_objects": self.total_objects,
        }
        if self.equipment_tags:
            result["equipment_tags"] = self.equipment_tags
        if self.instrument_tags:
            result["instrument_tags"] = self.instrument_tags
        return result


def summarize_model(model: EngineeringModel) -> ModelSummary:
    """Summarise *model*: counts by kind over the whole composition tree, and tags.

    Walks the model once.

    Parameters
    ----------
    model : EngineeringModel
        A plant or process model.

    Returns
    -------
    ModelSummary
    """
    instances = get_all_instances_in_model(model)
    conceptual = model.conceptualModel
    return ModelSummary(
        conceptual_model_type=type(conceptual).__name__ if conceptual is not None else None,
        equipment=_entries(
            (obj for obj in instances if isinstance(obj, TaggedPlantItem)), tag_of=get_tag
        ),
        instruments=_entries(
            (obj for obj in instances if isinstance(obj, ProcessInstrumentationFunction)),
            tag_of=instrument_tag,
        ),
        piping_system_count=_count(instances, PipingNetworkSystem),
        piping_segment_count=_count(instances, PipingNetworkSegment),
        piping_component_count=_count(instances, PipingComponent),
        process_step_count=_count(instances, ProcessStep),
        process_connection_count=_count(instances, ProcessConnection),
        stream_count=_count(instances, Stream),
        energy_flow_count=_count(instances, EnergyFlow),
        information_flow_count=_count(instances, InformationFlow),
        has_diagram=model.diagram is not None,
        total_objects=len(instances),
    )


def _entries(
    objects: Iterable[PyDexpiBaseModel], tag_of: Callable[[Any], str | None]
) -> tuple[SummaryEntry, ...]:
    return tuple(
        SummaryEntry(
            id=obj.id,
            type=type(obj).__name__,
            tag=tag_of(obj),
            display_name=get_display_name(obj),
        )
        for obj in objects
    )


def _count(instances: list[PyDexpiBaseModel], cls: type) -> int:
    return sum(isinstance(obj, cls) for obj in instances)
