"""Toolkit tools — equipment, line, instrument, and piping component lists."""

from __future__ import annotations

import json
import logging

from pydexpi.exports.dataframe_export import (
    get_equipment_dataframe,
    get_instrument_dataframe,
    get_instrument_relationship_dataframe,
    get_line_dataframe,
    get_nozzle_dataframe,
    get_piping_component_dataframe,
    get_piping_connection_dataframe,
)
from pydexpi.mcp_server.errors import ErrorCode, error_response
from pydexpi.mcp_server.serialization import paginate, pagination_error
from pydexpi.mcp_server.session import ModelEntry, SessionState

logger = logging.getLogger(__name__)


def _register_toolkit_tools(mcp, state: SessionState) -> None:
    """Register toolkit convenience tools on *mcp*."""

    @mcp.tool()
    def get_equipment_list(
        limit: int | None = None,
        offset: int = 0,
        model_id: str | None = None,
    ) -> str:
        """Return the equipment list as paginated JSON records.

        Parameters
        ----------
        limit : int, optional
            Maximum number of rows.
        offset : int
            Rows to skip.
        model_id : str, optional
            Target model.  Falls back to the active model if omitted.

        Returns
        -------
        str
            Paginated JSON with equipment records.
        """
        if (bad_paging := pagination_error(limit=limit, offset=offset)) is not None:
            return bad_paging
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        entry: ModelEntry = resolved
        try:
            df = get_equipment_dataframe(entry.model)
            records = json.loads(df.to_json(orient="records"))
            return json.dumps(paginate(records, limit=limit, offset=offset))
        except Exception as exc:
            logger.debug("get_equipment_list failed", exc_info=True)
            return error_response(ErrorCode.EXPORT_ERROR, "Equipment list failed.", str(exc))

    @mcp.tool()
    def get_line_list(
        limit: int | None = None,
        offset: int = 0,
        model_id: str | None = None,
    ) -> str:
        """Return one row per piping segment with boundary item/node and system IDs.

        Endpoint *_status fields distinguish missing, detached and invalid IDs.
        A segment row is not a globally ordered line or path.

        Parameters
        ----------
        limit : int, optional
            Maximum number of rows.
        offset : int
            Rows to skip.
        model_id : str, optional
            Target model.  Falls back to the active model if omitted.

        Returns
        -------
        str
            Paginated JSON with line records.
        """
        if (bad_paging := pagination_error(limit=limit, offset=offset)) is not None:
            return bad_paging
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        entry: ModelEntry = resolved
        try:
            df = get_line_dataframe(entry.model)
            records = json.loads(df.to_json(orient="records"))
            return json.dumps(paginate(records, limit=limit, offset=offset))
        except Exception as exc:
            logger.debug("get_line_list failed", exc_info=True)
            return error_response(ErrorCode.EXPORT_ERROR, "Line list failed.", str(exc))

    @mcp.tool()
    def get_instrument_list(
        limit: int | None = None,
        offset: int = 0,
        model_id: str | None = None,
    ) -> str:
        """Return the instrument list as paginated JSON records.

        Parameters
        ----------
        limit : int, optional
            Maximum number of rows.
        offset : int
            Rows to skip.
        model_id : str, optional
            Target model.  Falls back to the active model if omitted.

        Returns
        -------
        str
            Paginated JSON with instrument records.
        """
        if (bad_paging := pagination_error(limit=limit, offset=offset)) is not None:
            return bad_paging
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        entry: ModelEntry = resolved
        try:
            df = get_instrument_dataframe(entry.model)
            records = json.loads(df.to_json(orient="records"))
            return json.dumps(paginate(records, limit=limit, offset=offset))
        except Exception as exc:
            logger.debug("get_instrument_list failed", exc_info=True)
            return error_response(ErrorCode.EXPORT_ERROR, "Instrument list failed.", str(exc))

    @mcp.tool()
    def get_piping_component_list(
        limit: int | None = None,
        offset: int = 0,
        model_id: str | None = None,
        include_valves: bool = False,
        include_connectors: bool = False,
    ) -> str:
        """Return the piping component list as paginated JSON records.

        For engineering inventory and safety analysis, prefer
        get_complete_piping_inventory, which always includes valves and connectors.

        Parameters
        ----------
        limit : int, optional
            Maximum number of rows.
        offset : int
            Rows to skip.
        model_id : str, optional
            Target model.  Falls back to the active model if omitted.

        include_valves : bool
            Include every valve family; False preserves the dedicated valve-table default.
        include_connectors : bool
            Include off-page connectors. Both flags True give the complete inventory;
            valves only matches summary piping_component_count (connectors are extra).

        Returns
        -------
        str
            Paginated JSON with piping component records.
        """
        if (bad_paging := pagination_error(limit=limit, offset=offset)) is not None:
            return bad_paging
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        entry: ModelEntry = resolved
        try:
            df = get_piping_component_dataframe(
                entry.model, include_valves=include_valves, include_connectors=include_connectors
            )
            records = json.loads(df.to_json(orient="records"))
            return json.dumps(paginate(records, limit=limit, offset=offset))
        except Exception as exc:
            logger.debug("get_piping_component_list failed", exc_info=True)
            return error_response(ErrorCode.EXPORT_ERROR, "Piping component list failed.", str(exc))

    @mcp.tool()
    def get_complete_piping_inventory(
        limit: int | None = None,
        offset: int = 0,
        model_id: str | None = None,
    ) -> str:
        """Return all piping components, valves and off-page connectors with object IDs.

        Prefer this tool for engineering inventory and safety analysis. Includes
        operated, check and safety valves, plus inline measuring elements, without
        requiring inclusion flags. Completeness refers to objects in the loaded
        model, not proof that the source document or plant is complete.
        Pipes and equipment nozzles use get_piping_connection_list and get_nozzle_list.
        total counts all inventory rows before pagination; fetch every page for analysis.

        Parameters
        ----------
        limit : int, optional
            Maximum number of rows; omitted returns all rows.
        offset : int
            Rows to skip.
        model_id : str, optional
            Target model. Falls back to the active model if omitted.

        Returns
        -------
        str
            Paginated JSON with identity-preserving inventory records.
        """
        return get_piping_component_list(
            limit=limit,
            offset=offset,
            model_id=model_id,
            include_valves=True,
            include_connectors=True,
        )

    @mcp.tool()
    def get_nozzle_list(
        limit: int | None = None,
        offset: int = 0,
        model_id: str | None = None,
    ) -> str:
        """Return nozzle IDs, parent equipment IDs, and node/connection/segment ID arrays.

        Disconnected nozzles have empty arrays. Join parent_equipment_id to the
        equipment table id. Subtags are display values, never relationship keys.
        limit/offset paginate rows; model_id defaults to the active model.
        """
        if (bad_paging := pagination_error(limit=limit, offset=offset)) is not None:
            return bad_paging
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        try:
            records = json.loads(get_nozzle_dataframe(resolved.model).to_json(orient="records"))
            return json.dumps(paginate(records, limit=limit, offset=offset))
        except Exception as exc:
            logger.debug("get_nozzle_list failed", exc_info=True)
            return error_response(ErrorCode.EXPORT_ERROR, "Nozzle list failed.", str(exc))

    @mcp.tool()
    def get_piping_connection_list(
        limit: int | None = None,
        offset: int = 0,
        model_id: str | None = None,
    ) -> str:
        """Return actual piping edges with ID, segment ID, item/node endpoints and status.

        Parallel edges remain distinct. Missing endpoints are null; outside_model
        diagnoses references to objects not in the composition tree. Source/target
        follow DEXPI connection flow. Use find_paths with explicit endpoints or
        describe_run for traversal; table row order is not a universal line sequence.
        limit/offset paginate rows; model_id defaults to the active model.
        """
        if (bad_paging := pagination_error(limit=limit, offset=offset)) is not None:
            return bad_paging
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        try:
            records = json.loads(
                get_piping_connection_dataframe(resolved.model).to_json(orient="records")
            )
            return json.dumps(paginate(records, limit=limit, offset=offset))
        except Exception as exc:
            logger.debug("get_piping_connection_list failed", exc_info=True)
            return error_response(
                ErrorCode.EXPORT_ERROR, "Piping connection list failed.", str(exc)
            )

    @mcp.tool()
    def get_instrument_relationship_list(
        limit: int | None = None,
        offset: int = 0,
        model_id: str | None = None,
    ) -> str:
        """Return identity-preserving instrumentation, sensing, actuation and signal edges.

        Property edges run owner to value with exact role/category/ordinal. Flow
        edges run source to target with the signal/measuring line relationship_id.
        Parallel lines remain distinct. Missing targets are null with missing status;
        outside_model diagnoses detached targets. No identity comes from a number.
        limit/offset paginate rows; model_id defaults to the active model.
        """
        if (bad_paging := pagination_error(limit=limit, offset=offset)) is not None:
            return bad_paging
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        try:
            records = json.loads(
                get_instrument_relationship_dataframe(resolved.model).to_json(orient="records")
            )
            return json.dumps(paginate(records, limit=limit, offset=offset))
        except Exception as exc:
            logger.debug("get_instrument_relationship_list failed", exc_info=True)
            return error_response(
                ErrorCode.EXPORT_ERROR, "Instrument relationship list failed.", str(exc)
            )
