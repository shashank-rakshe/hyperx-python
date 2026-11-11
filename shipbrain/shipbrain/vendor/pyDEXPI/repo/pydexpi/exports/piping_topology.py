"""One row per actual piping connection, without imposing a linear traversal."""

import pandas as pd

from pydexpi.exports.semantic_identity import IdentityContext, semantic_frame
from pydexpi.pydexpi_classes import EngineeringModel, PipingConnection, PipingNetworkSegment


def make_piping_connection_list(model: EngineeringModel) -> pd.DataFrame:
    """Return every connection's ID, segment ID, item/node endpoints and resolution status.

    Parallel connections and cycles are distinct rows. Missing targets stay null;
    references outside the composition tree retain their ID with outside_model status.
    No row is a guessed path, and row order does not imply flow traversal order.
    """
    context = IdentityContext(model)
    owners = {}
    for segment in (obj for obj in context.objects if isinstance(obj, PipingNetworkSegment)):
        for connection in segment.connections:
            if id(connection) in owners and owners[id(connection)] is not segment:
                raise ValueError(f"Ambiguous segment for connection {connection.id!r}")
            owners[id(connection)] = segment
    rows = []
    for connection in (obj for obj in context.objects if isinstance(obj, PipingConnection)):
        row = context.record(connection)
        row["segment_id"] = context.object_id(owners.get(id(connection)))
        for role, attribute in (
            ("source_item", "sourceItem"),
            ("target_item", "targetItem"),
            ("source_node", "sourceNode"),
            ("target_node", "targetNode"),
        ):
            row.update(context.reference(getattr(connection, attribute), role))
        rows.append(row)
    return semantic_frame(
        rows,
        (
            "segment_id",
            "source_item_id",
            "target_item_id",
            "source_node_id",
            "target_node_id",
            "source_item_status",
            "target_item_status",
            "source_node_status",
            "target_node_status",
        ),
    )
