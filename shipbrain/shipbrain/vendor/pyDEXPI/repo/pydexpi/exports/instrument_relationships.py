"""Identity-preserving instrumentation relationships from DEXPI binding metadata."""

import pandas as pd

from pydexpi.exports.semantic_identity import IdentityContext, semantic_frame
from pydexpi.pydexpi_classes import (
    ActuatingElectricalFunction,
    ActuatingElectricalSystem,
    ActuatingFunction,
    ActuatingSystem,
    EngineeringModel,
    InstrumentationLoopFunction,
    MeasuringSystem,
    ProcessInstrumentationFunction,
    ProcessSignalGeneratingFunction,
    PyDexpiBaseModel,
    SignalConveyingFunction,
)
from pydexpi.toolkits.base_model_utils import get_composition_attributes, get_reference_attributes
from pydexpi.toolkits.model_toolkit import get_all_instances_in_model

_ROOTS = (
    ProcessInstrumentationFunction,
    InstrumentationLoopFunction,
    ActuatingElectricalFunction,
    ActuatingElectricalSystem,
    ActuatingFunction,
    ActuatingSystem,
    MeasuringSystem,
    ProcessSignalGeneratingFunction,
    SignalConveyingFunction,
)
_ANNOTATIONS = {"persistentIdentifiers", "performedRoles", "referencedNotes"}
_COLUMNS = (
    "relationship_id",
    "role",
    "category",
    "ordinal",
    "source_id",
    "source_status",
    "source_class",
    "target_id",
    "target_status",
    "target_class",
)


def make_instrument_relationship_list(model: EngineeringModel) -> pd.DataFrame:
    """Export property edges and directed signal/measuring flows without tag-based joins.

    Property rows run owner -> value; role is the exact model field, category is
    composition/reference, and ordinal preserves list multiplicity. Flow rows run
    line.source -> line.target with the line's own ID and category=flow. A row's
    id/relationship_id identify its owning DEXPI object, never a synthesized edge ID.
    Empty optional relationships are explicit rows with missing target status.
    """
    context = IdentityContext(model)
    selected = {
        id(child)
        for obj in context.objects
        if isinstance(obj, _ROOTS)
        for child in get_all_instances_in_model(obj)
    }
    rows = []
    for obj in context.objects:
        if id(obj) not in selected:
            continue
        if isinstance(obj, SignalConveyingFunction):
            rows.append(_edge(context, obj, "flow", "flow", None, obj.source, obj.target))
        for category, attributes in (
            ("composition", get_composition_attributes(obj)),
            ("reference", get_reference_attributes(obj)),
        ):
            for role, value in attributes.items():
                if role in _ANNOTATIONS:
                    continue
                if isinstance(value, list):
                    targets = list(enumerate(value)) if value else [(None, None)]
                else:
                    targets = [(None, value)]
                for ordinal, target in targets:
                    rows.append(_edge(context, obj, role, category, ordinal, obj, target))
    df = semantic_frame(rows, _COLUMNS)
    df["ordinal"] = pd.array(df["ordinal"], dtype="Int64")
    return df


def _edge(
    context: IdentityContext,
    owner: PyDexpiBaseModel,
    role: str,
    category: str,
    ordinal: int | None,
    source: PyDexpiBaseModel | None,
    target: PyDexpiBaseModel | None,
) -> dict:
    return {
        **context.record(owner),
        "relationship_id": context.object_id(owner),
        "role": role,
        "category": category,
        "ordinal": ordinal,
        **context.reference(source, "source"),
        **context.reference(target, "target"),
        "source_class": type(source).__name__ if source is not None else None,
        "target_class": type(target).__name__ if target is not None else None,
    }
