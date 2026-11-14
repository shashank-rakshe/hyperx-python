"""MCP resources for browsing loaded DEXPI model data."""

from __future__ import annotations

import json
import logging

from pydexpi.exports.dataframe_export import (
    get_equipment_dataframe,
    get_instrument_dataframe,
    get_line_dataframe,
)
from pydexpi.exports.llm_context_export import export_llm_context_strings
from pydexpi.mcp_server.errors import ErrorCode, error_response
from pydexpi.mcp_server.session import SessionState
from pydexpi.toolkits.model_summary import summarize_model

logger = logging.getLogger(__name__)


def _register_resources(mcp, state: SessionState) -> None:
    """Register MCP resource endpoints on *mcp*."""

    @mcp.resource("dexpi://models")
    def list_models() -> str:
        """List all currently loaded DEXPI models."""
        return json.dumps(state.list_models())

    @mcp.resource("dexpi://models/{model_id}/summary")
    def model_summary(model_id: str) -> str:
        """Summary statistics for a specific model."""
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        return json.dumps({"model_id": model_id, **summarize_model(resolved.model).to_dict()})

    @mcp.resource("dexpi://models/{model_id}/equipment")
    def model_equipment(model_id: str) -> str:
        """Equipment list for a specific model."""
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        try:
            df = get_equipment_dataframe(resolved.model)
            return df.to_json(orient="records")
        except Exception as exc:
            logger.debug("model_equipment failed", exc_info=True)
            return error_response(ErrorCode.EXPORT_ERROR, "Equipment list failed.", str(exc))

    @mcp.resource("dexpi://models/{model_id}/lines")
    def model_lines(model_id: str) -> str:
        """Line list for a specific model."""
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        try:
            df = get_line_dataframe(resolved.model)
            return df.to_json(orient="records")
        except Exception as exc:
            logger.debug("model_lines failed", exc_info=True)
            return error_response(ErrorCode.EXPORT_ERROR, "Line list failed.", str(exc))

    @mcp.resource("dexpi://models/{model_id}/instruments")
    def model_instruments(model_id: str) -> str:
        """Instrument list for a specific model."""
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        try:
            df = get_instrument_dataframe(resolved.model)
            return df.to_json(orient="records")
        except Exception as exc:
            logger.debug("model_instruments failed", exc_info=True)
            return error_response(ErrorCode.EXPORT_ERROR, "Instrument list failed.", str(exc))

    @mcp.resource("dexpi://models/{model_id}/llm-context")
    def model_llm_context(model_id: str) -> str:
        """LLM-optimised text description of a model."""
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        try:
            return export_llm_context_strings(
                resolved.model, graph_level="conceptual", mode="graph"
            )
        except Exception as exc:
            logger.debug("model_llm_context failed", exc_info=True)
            return error_response(ErrorCode.EXPORT_ERROR, "LLM context failed.", str(exc))
