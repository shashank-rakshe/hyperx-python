"""Model information and summary tools."""

from __future__ import annotations

import json

from pydexpi.mcp_server.session import ModelEntry, SessionState
from pydexpi.toolkits.model_summary import summarize_model


def _register_info_tools(mcp, state: SessionState) -> None:
    """Register model-info tools on *mcp*."""

    @mcp.tool()
    def get_model_summary(model_id: str | None = None) -> str:
        """Return a summary of a loaded DEXPI model.

        Counts cover the whole model, not only its top level:
        ``equipment_count`` (every TaggedPlantItem, column sections included),
        ``instrument_count``, ``piping_system_count``, ``piping_segment_count``,
        ``piping_component_count`` (every PipingComponent, valves and inline
        measuring elements included -- more than ``get_piping_component_list``,
        which leaves valves to their own table), ``process_step_count`` and
        ``process_connection_count`` (a process model's content), the latter
        split by kind into ``stream_count``, ``energy_flow_count`` and
        ``information_flow_count``, ``total_objects`` and ``has_diagram``.
        ``conceptual_model_type`` is ``"PlantModel"`` or ``"ProcessModel"``.
        ``equipment_tags`` and ``instrument_tags`` (loop tags such as
        ``"PICSA-4712.02"``) are present when not empty.

        Parameters
        ----------
        model_id : str, optional
            Target model.  Falls back to the active model if omitted.

        Returns
        -------
        str
            JSON summary or error envelope.
        """
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        entry: ModelEntry = resolved
        result = {"model_id": model_id or state.active_id, **summarize_model(entry.model).to_dict()}
        return json.dumps(result)
