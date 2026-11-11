"""Relational nozzle inventory, independent of equipment display labels."""

import pandas as pd

from pydexpi.exports.semantic_identity import IdentityContext, semantic_frame
from pydexpi.exports.table_export import get_attribute_value
from pydexpi.pydexpi_classes import (
    EngineeringModel,
    Nozzle,
    PipingConnection,
    PipingNetworkSegment,
    PyDexpiBaseModel,
    TaggedPlantItem,
)
from pydexpi.toolkits.base_model_utils import get_composition_attributes


def make_nozzle_list(model: EngineeringModel) -> pd.DataFrame:
    """One row per nozzle with its direct owner and nearest tagged equipment ancestor.

    Node and connection ID arrays retain model IDs, including null IDs. Disconnected
    nozzles have empty connection arrays. Shared composition ownership is refused
    explicitly because a single parent column would be ambiguous.
    """
    context = IdentityContext(model)
    parents = {}
    for obj in context.objects:
        for value in get_composition_attributes(obj).values():
            children = value if isinstance(value, list) else [value]
            for child in children:
                if not isinstance(child, PyDexpiBaseModel):
                    continue
                previous = parents.get(id(child))
                if previous is not None and previous is not obj:
                    raise ValueError(f"Ambiguous composition owner for {child.id!r}")
                parents[id(child)] = obj

    rows = []
    holders = [
        obj for obj in context.objects if isinstance(obj, (PipingConnection, PipingNetworkSegment))
    ]
    for nozzle in (obj for obj in context.objects if isinstance(obj, Nozzle)):
        parent = parents.get(id(nozzle))
        equipment = parent
        visited = {id(nozzle)}
        while equipment is not None and not isinstance(equipment, TaggedPlantItem):
            if id(equipment) in visited:
                raise ValueError(f"Composition cycle above nozzle {nozzle.id!r}")
            visited.add(id(equipment))
            equipment = parents.get(id(equipment))
        node_keys = {id(node) for node in nozzle.nodes}
        attached = [
            holder
            for holder in holders
            if any(getattr(holder, name, None) is nozzle for name in ("sourceItem", "targetItem"))
            or any(
                id(getattr(holder, name, None)) in node_keys
                for name in ("sourceNode", "targetNode")
            )
        ]
        rows.append(
            {
                **context.record(nozzle),
                "sub_tag_name": get_attribute_value(nozzle.subTagName),
                "parent_id": context.object_id(parent),
                "parent_equipment_id": context.object_id(equipment),
                "node_ids": [context.object_id(node) for node in nozzle.nodes],
                "connection_ids": [
                    context.object_id(obj) for obj in attached if isinstance(obj, PipingConnection)
                ],
                "segment_ids": [
                    context.object_id(obj)
                    for obj in attached
                    if isinstance(obj, PipingNetworkSegment)
                ],
            }
        )
    return semantic_frame(
        rows,
        (
            "sub_tag_name",
            "parent_id",
            "parent_equipment_id",
            "node_ids",
            "connection_ids",
            "segment_ids",
        ),
    )
