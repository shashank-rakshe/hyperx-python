"""pyDEXPI MCP Server — main entry point.

Exposes pyDEXPI functionality (loading, querying, exporting DEXPI P&ID
models) via the Model Context Protocol using the official ``mcp`` SDK,
installed with the ``mcp`` extra (``pip install "pydexpi[mcp]"``).

Usage
-----
Run locally via stdio (the default)::

    pydexpi-mcp

Or serve over the network::

    pydexpi-mcp --transport streamable-http --file-root ./models
    pydexpi-mcp --transport sse --host 127.0.0.1 --port 8000

Every client connection has its own session, so clients never see each other's
models. File access follows the transport: over stdio the file tools
reach any path the user can; with ``--file-root`` they are confined to that
directory; over a network transport without ``--file-root`` they are disabled.

A network server keeps each client's models in the session of its connection, so it
serves the session-based (``initialize`` handshake) protocol era only: a request of the
sessionless 2026-07-28 era over HTTP is refused, naming the versions the server serves,
and a client negotiating automatically falls back to them. A Streamable HTTP session
idle for 30 minutes expires, and its models with it.
"""

from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence
from importlib import metadata
from pathlib import Path
from typing import Any, Literal

from pydexpi.mcp_server import SDK_REQUIREMENT

try:
    import anyio
    from mcp.server.context import CallNext, HandlerResult, ServerRequestContext
    from mcp.server.mcpserver import MCPServer
    from mcp.shared.exceptions import MCPError
    from mcp.types import UNSUPPORTED_PROTOCOL_VERSION, UnsupportedProtocolVersionErrorData
    from mcp_types.version import HANDSHAKE_PROTOCOL_VERSIONS
except ImportError as exc:  # pragma: no cover - exercised only without the extra
    try:
        _installed = metadata.version("mcp")
    except metadata.PackageNotFoundError:
        raise ImportError(
            'The pyDEXPI MCP server requires the "mcp" extra: pip install "pydexpi[mcp]"'
        ) from exc
    raise ImportError(
        f"The pyDEXPI MCP server requires {SDK_REQUIREMENT}, but mcp {_installed} is "
        'installed: pip install --upgrade "pydexpi[mcp]"'
    ) from exc

from pydexpi.mcp_server.access import FileAccess
from pydexpi.mcp_server.extensions import McpExtension, arrange_tools, discover_extensions
from pydexpi.mcp_server.resources.model import _register_resources
from pydexpi.mcp_server.session import ConnectionSessions
from pydexpi.mcp_server.tools.discovery import _register_discovery_tools
from pydexpi.mcp_server.tools.export import _register_export_tools
from pydexpi.mcp_server.tools.graph import _register_graph_tools
from pydexpi.mcp_server.tools.info import _register_info_tools
from pydexpi.mcp_server.tools.loading import _register_loading_tools
from pydexpi.mcp_server.tools.query import _register_query_tools
from pydexpi.mcp_server.tools.schema import _register_schema_tools
from pydexpi.mcp_server.tools.toolkit import _register_toolkit_tools

Transport = Literal["stdio", "sse", "streamable-http"]

# ---------------------------------------------------------------------------
# Server factory
# ---------------------------------------------------------------------------


#: At most this many Streamable HTTP sessions at once (the SDK default is 10000). Each holds up
#: to ``session.MAX_MODELS_PER_SESSION`` models, so this bounds what clients can make the server
#: hold.
MAX_SESSIONS = 64

#: How long the SDK keeps an idle Streamable HTTP session -- and so its models -- open, in
#: seconds. This is the SDK's own default, stated here so the documentation can name it.
SESSION_IDLE_TIMEOUT = 30 * 60


def create_server(
    file_access: FileAccess | None = None,
    *,
    per_connection: bool = False,
    extensions: Sequence[McpExtension] | None = None,
) -> tuple[MCPServer, ConnectionSessions]:
    """Build a configured ``MCPServer`` with all tools and resources.

    Parameters
    ----------
    file_access : FileAccess, optional
        What ``load_dexpi_xml_file`` and ``save_model`` may touch. Defaults to **disabled**, so a
        server built here and then run on a network transport cannot be made to read or write
        files; pass :meth:`FileAccess.unrestricted` for a local stdio server, or see
        :func:`file_access_for`.
    per_connection : bool, optional
        Whether every client connection gets a session of its own. Off, the server has a single
        session, which is right for stdio -- one client per process, whatever protocol era it
        speaks -- and for code that calls tool functions directly, as tests do. ``main`` turns
        it on for network transports, where a call outside a client connection raises and a
        sessionless request is refused (see :class:`_RequestMiddleware`).
    extensions : sequence of McpExtension, optional
        What to register after the core's tools (:mod:`pydexpi.mcp_server.extensions`), in
        order. None, the default, registers every installed extension
        (:func:`~pydexpi.mcp_server.extensions.discover_extensions`). An empty sequence builds
        the core server alone.
        Where an extension places its tools among the core's, the list is arranged afterwards
        (:func:`~pydexpi.mcp_server.extensions.arrange_tools`).

    Returns
    -------
    tuple[MCPServer, ConnectionSessions]
        The server, and its sessions: one per client connection, or a single one.
    """
    sessions = ConnectionSessions(per_connection=per_connection)
    mcp = MCPServer(
        "pyDEXPI",
        instructions=(
            "MCP server for DEXPI P&ID / PFD analysis. "
            "Load a DEXPI XML or JSON model, then query, analyse, and "
            "export it using the available tools. For engineering piping inventories, "
            "prefer get_complete_piping_inventory: it includes all valve families and "
            "off-page connectors. Fetch every page when using pagination."
        ),
        version=_pydexpi_version(),
        middleware=[_RequestMiddleware(sessions)],
    )
    file_access = file_access or FileAccess.disabled()

    _register_loading_tools(mcp, sessions, file_access)
    _register_info_tools(mcp, sessions)
    _register_query_tools(mcp, sessions)
    _register_discovery_tools(mcp, sessions)
    _register_export_tools(mcp, sessions, file_access)
    _register_graph_tools(mcp, sessions)
    _register_toolkit_tools(mcp, sessions)
    _register_schema_tools(mcp)
    _register_resources(mcp, sessions)
    for extension in discover_extensions() if extensions is None else extensions:
        extension(mcp, sessions, file_access)
    arrange_tools(mcp)

    return mcp, sessions


def _pydexpi_version() -> str:
    """The installed pyDEXPI version, reported as the server's (the SDK no longer reports its own)."""
    try:
        return metadata.version("pydexpi")
    except metadata.PackageNotFoundError:  # pragma: no cover - an uninstalled source tree
        return ""


def connection_of(ctx: ServerRequestContext[Any, Any]) -> object | None:
    """What identifies the client connection a request arrived on, or None if nothing does.

    The SDK builds a new ``ServerSession`` for every request, so the session identifies nothing
    any more, and the per-connection ``Connection`` behind it has no public accessor in mcp 2.3
    (one is planned): it is read from the session's ``_connection``. What one client stream
    shares is that connection's ``outbound`` channel -- the connection's own in the handshake
    era, and on a 2026-07-28 stream, whose every request gets a ``Connection`` of its own, the
    stream's. A request without such a channel (the 2026-07-28 era over HTTP: one exchange per
    request, no session) belongs to no connection beyond itself, so this returns None.
    """
    connection = getattr(ctx.session, "_connection", None)
    if connection is None:  # pragma: no cover - an SDK change; test_transports pins the path
        raise RuntimeError(
            "This mcp release no longer exposes the connection of a request; "
            f"pyDEXPI's per-connection sessions need {SDK_REQUIREMENT}."
        )
    return connection.outbound if connection.has_standalone_channel else None


#: The requests that run pyDEXPI code against a session's models.
_SERIALIZED_METHODS = frozenset({"tools/call", "resources/read"})


class _RequestMiddleware:
    """Run tool calls one at a time, and attribute each request to its client connection.

    **One at a time.** The SDK runs a synchronous tool on a worker thread, so calls arriving
    together -- an agent's parallel tool calls -- would use one model on several threads at
    once. pyDEXPI's models and caches are not thread-safe, so tool calls and resource
    reads are serialised server-wide, as the 1.x SDK's single event loop did.

    **Per connection.** On a server with per-connection sessions every request is attributed to
    the connection it arrived on (:func:`connection_of`). A request that belongs to no
    connection -- the 2026-07-28 era over HTTP -- is refused with -32022, naming the
    handshake-era versions as the supported ones: a client in ``mode="auto"`` falls back to the
    ``initialize`` handshake, which opens a session, and a client pinned to 2026-07-28 is told
    why it cannot connect. Notifications pass: they reach no tool.
    """

    def __init__(self, sessions: ConnectionSessions) -> None:
        self.sessions = sessions
        self._lock = anyio.Lock()

    async def __call__(
        self, ctx: ServerRequestContext[Any, Any], call_next: CallNext
    ) -> HandlerResult:
        if not self.sessions.per_connection:
            return await self._serialized(ctx, call_next)
        connection = connection_of(ctx)
        if connection is None and ctx.request_id is not None:
            requested = ctx.session.protocol_version
            raise MCPError(
                code=UNSUPPORTED_PROTOCOL_VERSION,
                message=(
                    "This pyDEXPI server keeps each client's models in its session, which the "
                    f"{requested} protocol does not have; connect with the initialize handshake."
                ),
                data=UnsupportedProtocolVersionErrorData(
                    supported=list(HANDSHAKE_PROTOCOL_VERSIONS), requested=requested
                ).model_dump(mode="json"),
            )
        with self.sessions.serving(connection):
            return await self._serialized(ctx, call_next)

    async def _serialized(
        self, ctx: ServerRequestContext[Any, Any], call_next: CallNext
    ) -> HandlerResult:
        if ctx.method not in _SERIALIZED_METHODS:
            return await call_next(ctx)
        async with self._lock:
            return await call_next(ctx)


def file_access_for(transport: Transport, file_root: str | Path | None) -> FileAccess:
    """The file-access policy for a transport.

    A file root always confines the file tools. Without one, stdio -- where the client is the
    local user -- is unrestricted, and a network transport -- where the client is whoever can
    reach the port -- has no file access.
    """
    if file_root is not None:
        return FileAccess.sandboxed(file_root)
    if transport == "stdio":
        return FileAccess.unrestricted()
    return FileAccess.disabled()


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------


def main(argv: Sequence[str] | None = None) -> None:
    """CLI entry point for the pyDEXPI MCP server."""
    parser = argparse.ArgumentParser(description="pyDEXPI MCP Server")
    parser.add_argument(
        "--transport",
        choices=["stdio", "sse", "streamable-http"],
        default="stdio",
        help=(
            "MCP transport (default: stdio). Over a network transport each client has its own "
            "session, which holds its models only while the session lasts: a streamable-http "
            f"session idle for {SESSION_IDLE_TIMEOUT // 60} minutes expires, and at most "
            f"{MAX_SESSIONS} are open at once."
        ),
    )
    parser.add_argument(
        "--host",
        default="127.0.0.1",
        help="Address a network transport listens on (default: 127.0.0.1).",
    )
    parser.add_argument(
        "--port", type=int, default=8000, help="Port of a network transport (default: 8000)."
    )
    parser.add_argument(
        "--file-root",
        metavar="DIR",
        help=(
            "Confine load_dexpi_xml_file and save_model to this directory. Without it, file "
            "access is unrestricted over stdio and disabled over a network transport."
        ),
    )
    args = parser.parse_args(argv)
    try:
        file_access = file_access_for(args.transport, args.file_root)
    except NotADirectoryError as exc:
        parser.error(str(exc))

    server, _ = create_server(file_access, per_connection=args.transport != "stdio")
    if args.transport == "stdio":
        # stdout carries the protocol, so nothing is announced.
        server.run(transport="stdio")
        return
    # A network server can announce itself. Passing a loopback host to run() is what enables
    # the SDK's DNS-rebinding protection.
    print(
        f"pyDEXPI MCP server: {args.transport} on {args.host}:{args.port}, "
        f"{file_access.describe()}.",
        file=sys.stderr,
    )
    if args.transport == "sse":
        server.run(transport="sse", host=args.host, port=args.port)
    else:
        server.run(
            transport="streamable-http",
            host=args.host,
            port=args.port,
            max_sessions=MAX_SESSIONS,
            session_idle_timeout=SESSION_IDLE_TIMEOUT,
        )


if __name__ == "__main__":
    main()
