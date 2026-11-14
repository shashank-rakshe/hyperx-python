"""Query tools — wrap pyDEXPI ``QueryEngine`` with clean MCP interfaces."""

from __future__ import annotations

import json

from pydexpi.mcp_server.errors import ErrorCode, error_response
from pydexpi.mcp_server.serialization import object_summary, paginate, pagination_error
from pydexpi.mcp_server.session import ModelEntry, SessionState
from pydexpi.mcp_server.tools.schema import CLASS_CATALOG
from pydexpi.query.errors import AmbiguousTagError, ObjectNotFoundError, QueryError


def _query_error(exc: QueryError) -> str:
    """Envelope for a failed reference lookup: ambiguity and absence are distinct codes."""
    if isinstance(exc, AmbiguousTagError):
        return error_response(ErrorCode.AMBIGUOUS_TAG, str(exc))
    return error_response(ErrorCode.OBJECT_NOT_FOUND, str(exc))


def _register_query_tools(mcp, state: SessionState) -> None:
    """Register all query tools on *mcp*."""

    @mcp.tool()
    def find_by_tag(tag: str, model_id: str | None = None, type: str | None = None) -> str:
        """Find all objects with the given tag name.

        Parameters
        ----------
        tag : str
            The tag name to search for (e.g. ``"P-101A"``).
        model_id : str, optional
            Target model.  Falls back to the active model if omitted.
        type : str, optional
            Case-sensitive concrete or DEXPI parent class name. For shared instrument numbers,
            use ``ProcessInstrumentationFunction`` or ``InstrumentationLoopFunction``.
            Printed instrument tags (e.g. ``PI-4712.01``) can also be looked up directly.

        Returns
        -------
        str
            JSON array of matching object summaries.
        """
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        entry: ModelEntry = resolved
        matches = entry.query_engine.find_by_tag(tag, type=type)
        return json.dumps([object_summary(obj) for obj in matches])

    @mcp.tool()
    def get_by_tag(tag: str, model_id: str | None = None, type: str | None = None) -> str:
        """Return the unique object with the given tag name.

        Parameters
        ----------
        tag : str
            The tag name to search for.
        model_id : str, optional
            Target model.  Falls back to the active model if omitted.
        type : str, optional
            Case-sensitive concrete or DEXPI parent class name, applied before uniqueness.
            Printed instrument tags (e.g. ``PI-4712.01``) are accepted too. Duplicate tags
            remain ambiguous even after filtering.

        Returns
        -------
        str
            JSON object summary, or an error if not found or ambiguous.
        """
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        entry: ModelEntry = resolved
        try:
            obj = entry.query_engine.get_by_tag(tag, type=type)
        except ObjectNotFoundError:
            type_detail = f" and type '{type}'" if type is not None else ""
            return error_response(
                ErrorCode.OBJECT_NOT_FOUND, f"No object with tag '{tag}'{type_detail}."
            )
        except AmbiguousTagError as exc:
            return error_response(
                ErrorCode.AMBIGUOUS_TAG,
                f"Multiple objects match tag '{tag}'.",
                str(exc),
            )
        return json.dumps(object_summary(obj))

    @mcp.tool()
    def get_by_id(object_id: str, model_id: str | None = None) -> str:
        """Return the object with the given DEXPI ID.

        Parameters
        ----------
        object_id : str
            The ``id`` attribute of the desired object.
        model_id : str, optional
            Target model.  Falls back to the active model if omitted.

        Returns
        -------
        str
            JSON object summary, or an error if not found.
        """
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        entry: ModelEntry = resolved
        try:
            obj = entry.query_engine.get_by_id(object_id)
        except ObjectNotFoundError:
            return error_response(ErrorCode.OBJECT_NOT_FOUND, f"No object with id '{object_id}'.")
        return json.dumps(object_summary(obj))

    @mcp.tool()
    def find_all(
        type: str | None = None,
        has_graphic: bool | None = None,
        limit: int | None = None,
        offset: int = 0,
        model_id: str | None = None,
    ) -> str:
        """Find objects matching the given filters.

        Parameters
        ----------
        type : str, optional
            Filter by DEXPI class name (case-sensitive); instances of its
            subclasses match too, so ``"ProcessEquipment"`` finds every pump,
            vessel and heat exchanger. An unknown name is an ``invalid_parameter`` error;
            ``list_dexpi_classes`` lists the valid ones.
        has_graphic : bool, optional
            If ``True``, only objects with graphical representations.
        limit : int, optional
            Maximum number of results to return.
        offset : int
            Number of results to skip (for pagination).
        model_id : str, optional
            Target model.  Falls back to the active model if omitted.

        Returns
        -------
        str
            Paginated JSON with ``total``, ``offset``, ``limit``, ``count``,
            and ``items`` (list of object summaries).
        """
        if (bad_paging := pagination_error(limit=limit, offset=offset)) is not None:
            return bad_paging
        if type is not None and type not in CLASS_CATALOG:
            return error_response(
                ErrorCode.INVALID_PARAMETER,
                f"Unknown DEXPI class {type!r}.",
                "Call list_dexpi_classes to see the valid class names.",
            )
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        entry: ModelEntry = resolved
        matches = entry.query_engine.find_all(type=type, has_graphic=has_graphic)
        items = [object_summary(obj) for obj in matches]
        return json.dumps(paginate(items, limit=limit, offset=offset))

    @mcp.tool()
    def find_connections(ref: str, model_id: str | None = None) -> str:
        """Find objects directly connected to the referenced object.

        Parameters
        ----------
        ref : str
            Object tag, ID, or name.
        model_id : str, optional
            Target model.  Falls back to the active model if omitted.

        Returns
        -------
        str
            JSON with ``source`` and ``neighbors`` (list of object summaries).
        """
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        entry: ModelEntry = resolved
        try:
            result = entry.query_engine.find_connections(ref)
        except (ObjectNotFoundError, AmbiguousTagError) as exc:
            return _query_error(exc)
        return json.dumps(
            {
                "source": object_summary(result.source),
                "neighbors": [object_summary(n) for n in result.neighbors],
            }
        )

    @mcp.tool()
    def find_paths(
        source: str,
        target: str,
        max_depth: int = 10,
        max_paths: int = 5,
        model_id: str | None = None,
    ) -> str:
        """Find paths between two objects in the DEXPI graph.

        Parameters
        ----------
        source : str
            Source object (tag, ID, or name).
        target : str
            Target object (tag, ID, or name).
        max_depth : int
            Maximum path length (number of edges).
        max_paths : int
            Maximum number of paths to return.
        model_id : str, optional
            Target model.  Falls back to the active model if omitted.

        Returns
        -------
        str
            JSON with ``source``, ``target``, and ``paths``.
        """
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        entry: ModelEntry = resolved
        try:
            result = entry.query_engine.find_paths(
                source, target, max_depth=max_depth, max_paths=max_paths
            )
        except (ObjectNotFoundError, AmbiguousTagError) as exc:
            return _query_error(exc)
        return json.dumps(
            {
                "source": object_summary(result.source),
                "target": object_summary(result.target),
                "paths": [[object_summary(node) for node in path] for path in result.paths],
            }
        )

    @mcp.tool()
    def find_on_sheet(sheet_name: str, model_id: str | None = None) -> str:
        """Find all conceptual objects visible on a diagram sheet.

        Parameters
        ----------
        sheet_name : str
            The diagram / sheet name.
        model_id : str, optional
            Target model.  Falls back to the active model if omitted.

        Returns
        -------
        str
            JSON array of object summaries.
        """
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        entry: ModelEntry = resolved
        matches = entry.query_engine.find_on_sheet(sheet_name)
        return json.dumps([object_summary(obj) for obj in matches])

    @mcp.tool()
    def find_graphics_for(ref: str, model_id: str | None = None) -> str:
        """Find graphical representations for a conceptual object.

        Parameters
        ----------
        ref : str
            Object tag, ID, or name.
        model_id : str, optional
            Target model.  Falls back to the active model if omitted.

        Returns
        -------
        str
            JSON array of graphic group summaries.
        """
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        entry: ModelEntry = resolved
        try:
            groups = entry.query_engine.find_graphics_for(ref)
        except (ObjectNotFoundError, AmbiguousTagError) as exc:
            return _query_error(exc)
        return json.dumps(
            [{"id": getattr(g, "id", None), "type": type(g).__name__} for g in groups]
        )
