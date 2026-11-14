"""Graph tools — expose NetworkX graph statistics and structure."""

from __future__ import annotations

import json
import logging

from pydexpi import get_graph
from pydexpi.loaders.graph_loader import GRAPH_LEVELS
from pydexpi.mcp_server.errors import ErrorCode, error_response
from pydexpi.mcp_server.serialization import paginate, pagination_error
from pydexpi.mcp_server.session import ModelEntry, SessionState

logger = logging.getLogger(__name__)


def _register_graph_tools(mcp, state: SessionState) -> None:
    """Register graph exploration tools on *mcp*."""

    @mcp.tool()
    def get_graph_stats(
        graph_level: str = "complete",
        model_id: str | None = None,
    ) -> str:
        """Return high-level statistics for the DEXPI graph.

        Parameters
        ----------
        graph_level : str
            ``"complete"``, ``"process"``, ``"conceptual"`` (P&ID levels) or
            ``"process_flow"`` (a process model's steps and connections).
        model_id : str, optional
            Target model.  Falls back to the active model if omitted.

        Returns
        -------
        str
            JSON with ``node_count``, ``edge_count``, and
            ``connected_components``.
        """
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        entry: ModelEntry = resolved
        if graph_level not in GRAPH_LEVELS:
            return error_response(
                ErrorCode.INVALID_PARAMETER,
                f"Invalid graph_level '{graph_level}'.",
            )
        try:
            g = get_graph(entry.model, graph_level=graph_level)  # type: ignore[arg-type]
            import networkx as nx

            return json.dumps(
                {
                    "graph_level": graph_level,
                    "node_count": g.number_of_nodes(),
                    "edge_count": g.number_of_edges(),
                    "connected_components": nx.number_weakly_connected_components(g),
                }
            )
        except Exception as exc:
            logger.debug("get_graph_stats failed", exc_info=True)
            return error_response(ErrorCode.INTERNAL_ERROR, "Graph stats failed.", str(exc))

    @mcp.tool()
    def get_graph_nodes(
        graph_level: str = "complete",
        limit: int | None = None,
        offset: int = 0,
        model_id: str | None = None,
    ) -> str:
        """Return a paginated list of graph nodes.

        Parameters
        ----------
        graph_level : str
            ``"complete"``, ``"process"``, ``"conceptual"`` (P&ID levels) or
            ``"process_flow"`` (a process model's steps and connections).
        limit : int, optional
            Maximum number of nodes to return.
        offset : int
            Number of nodes to skip.
        model_id : str, optional
            Target model.  Falls back to the active model if omitted.

        Returns
        -------
        str
            Paginated JSON with node ``id``, ``type`` (the DEXPI class name)
            and ``display_name``. At ``process_flow`` the nodes are the process steps,
            step details, instrumentation activities and instrumentation systems (the
            control loops the activities belong to).
        """
        if (bad_paging := pagination_error(limit=limit, offset=offset)) is not None:
            return bad_paging
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        entry: ModelEntry = resolved
        if graph_level not in GRAPH_LEVELS:
            return error_response(
                ErrorCode.INVALID_PARAMETER,
                f"Invalid graph_level '{graph_level}'.",
            )
        try:
            g = get_graph(entry.model, graph_level=graph_level)  # type: ignore[arg-type]
            items = []
            for node_id, data in g.nodes(data=True):
                items.append(
                    {
                        "id": node_id,
                        "type": data.get("label", ""),
                        "display_name": data.get("displayName", ""),
                    }
                )
            return json.dumps(paginate(items, limit=limit, offset=offset))
        except Exception as exc:
            logger.debug("get_graph_nodes failed", exc_info=True)
            return error_response(ErrorCode.INTERNAL_ERROR, "Graph nodes failed.", str(exc))

    @mcp.tool()
    def get_graph_edges(
        graph_level: str = "complete",
        limit: int | None = None,
        offset: int = 0,
        model_id: str | None = None,
    ) -> str:
        """Return a paginated list of graph edges.

        Parameters
        ----------
        graph_level : str
            ``"complete"``, ``"process"``, ``"conceptual"`` (P&ID levels) or
            ``"process_flow"`` (a process model's steps and connections).
        limit : int, optional
            Maximum number of edges to return.
        offset : int
            Number of edges to skip.
        model_id : str, optional
            Target model.  Falls back to the active model if omitted.

        Returns
        -------
        str
            Paginated JSON with ``source``, ``target``, ``key`` and ``label``. ``key`` tells
            parallel edges apart: at ``process_flow`` it is the connection's id. The other
            edges of that level have a ``label`` and a composed key of their own:
            ``composition`` (``<attribute>.<child id>``, a sub-step or detail under its step,
            or an instrumentation activity under the system that composes it),
            ``delegation`` (``delegation.<delegate port id>``, from the step whose port is
            delegated to the step the delegate is on) and ``measures``
            (``measures.<activity id>.<measured id>``, from a measurement to the step or detail
            it measures, or with ``.source`` / ``.target`` to each end of a measured connection).
        """
        if (bad_paging := pagination_error(limit=limit, offset=offset)) is not None:
            return bad_paging
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        entry: ModelEntry = resolved
        if graph_level not in GRAPH_LEVELS:
            return error_response(
                ErrorCode.INVALID_PARAMETER,
                f"Invalid graph_level '{graph_level}'.",
            )
        try:
            g = get_graph(entry.model, graph_level=graph_level)  # type: ignore[arg-type]
            items = []
            for u, v, key, data in g.edges(keys=True, data=True):
                items.append(
                    {
                        "source": u,
                        "target": v,
                        "key": key,
                        "label": data.get("label", ""),
                    }
                )
            return json.dumps(paginate(items, limit=limit, offset=offset))
        except Exception as exc:
            logger.debug("get_graph_edges failed", exc_info=True)
            return error_response(ErrorCode.INTERNAL_ERROR, "Graph edges failed.", str(exc))
