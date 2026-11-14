"""Session state management for the pyDEXPI MCP server.

Holds loaded ``EngineeringModel`` instances and lazily-initialised caches
(``QueryEngine``, graphs).  All model-dependent tools resolve their target
model through :meth:`SessionState.resolve_model`.

Each client connection gets its own :class:`SessionState`:
:class:`ConnectionSessions` is what the tools hold, and it hands every call the
state of the connection making it. Over stdio there is one connection per process,
so one state; over a network transport, one client can never see another's models.
"""

from __future__ import annotations

import uuid
import weakref
from collections.abc import Iterator
from contextlib import contextmanager
from contextvars import ContextVar
from dataclasses import dataclass, field
from typing import Any

from pydexpi.mcp_server.errors import ErrorCode, error_response
from pydexpi.pydexpi_classes import EngineeringModel
from pydexpi.query.engine import QueryEngine

#: The connection the current request arrived on, as :meth:`ConnectionSessions.serving` names it.
#: Sync tools run on a worker thread, which ``anyio.to_thread.run_sync`` hands a copy of the
#: request's context, so the value reaches them too.
_CURRENT_CONNECTION: ContextVar[object | None] = ContextVar("pydexpi_mcp_connection", default=None)

#: How many models one session may hold at once. A reference-size P&ID is a few megabytes in
#: memory; on a network transport every connection gets a session, so this bounds what one
#: client can make the server hold.
MAX_MODELS_PER_SESSION = 32


@dataclass
class ModelEntry:
    """Container for a single loaded model, its lazily-built caches and what extensions keep.

    ``extras`` is where a server extension keeps its own state for the model, under a key of its
    own. The core never reads it; it goes with
    the entry, so unloading a model discards it.
    """

    model: EngineeringModel
    label: str
    _query_engine: QueryEngine | None = field(default=None, repr=False)
    extras: dict[str, Any] = field(default_factory=dict, repr=False)

    @property
    def query_engine(self) -> QueryEngine:
        if self._query_engine is None:
            self._query_engine = QueryEngine(self.model)
        return self._query_engine

    def invalidate_caches(self) -> None:
        if self._query_engine is not None:
            self._query_engine.invalidate()
        self._query_engine = None


class SessionState:
    """The loaded DEXPI models of one client connection, and which one is active."""

    def __init__(self) -> None:
        self._models: dict[str, ModelEntry] = {}
        self._active_id: str | None = None

    # ------------------------------------------------------------------
    # Model lifecycle
    # ------------------------------------------------------------------

    def add_model(self, model: EngineeringModel, label: str = "") -> str:
        """Store a model, make it the active model, and return its generated ID.

        The newest model is the one a client means when it names none: after
        loading a second model, calls without ``model_id`` act on it.
        """
        model_id = f"m-{uuid.uuid4().hex[:8]}"
        self._models[model_id] = ModelEntry(model=model, label=label or model_id)
        self._active_id = model_id
        return model_id

    @property
    def is_full(self) -> bool:
        """Whether the session holds :data:`MAX_MODELS_PER_SESSION` models already."""
        return len(self._models) >= MAX_MODELS_PER_SESSION

    def full_error(self) -> str:
        """The error envelope for loading into a full session."""
        return error_response(
            ErrorCode.SESSION_FULL,
            f"This session already holds {MAX_MODELS_PER_SESSION} models.",
            "Unload one with unload_model or clear_models first.",
        )

    def remove_model(self, model_id: str) -> bool:
        """Remove a model from the session.  Returns ``True`` on success.

        Removing the active model makes the most recently added remaining
        model active, or none if the session is now empty.
        """
        if model_id not in self._models:
            return False
        del self._models[model_id]
        if self._active_id == model_id:
            self._active_id = next(reversed(self._models), None)
        return True

    def clear(self) -> int:
        """Remove all models.  Returns the number removed."""
        count = len(self._models)
        self._models.clear()
        self._active_id = None
        return count

    # ------------------------------------------------------------------
    # Active model
    # ------------------------------------------------------------------

    @property
    def active_id(self) -> str | None:
        return self._active_id

    def set_active(self, model_id: str) -> str | None:
        """Set active model.  Returns an error string or ``None`` on success."""
        if model_id not in self._models:
            return error_response(
                ErrorCode.MODEL_NOT_FOUND,
                f"No model with id '{model_id}'.",
            )
        self._active_id = model_id
        return None

    # ------------------------------------------------------------------
    # Resolution
    # ------------------------------------------------------------------

    def resolve_model(self, model_id: str | None) -> ModelEntry | str:
        """Return the ``ModelEntry`` for *model_id*, falling back to the active model.

        Only ``None`` falls back: an empty string is a model id like any other,
        and names no model.

        Returns the entry on success or a JSON error string on failure.
        """
        target = self._active_id if model_id is None else model_id
        if target is None:
            return error_response(
                ErrorCode.NO_ACTIVE_MODEL,
                "No model is loaded. Use load_dexpi_xml or load_dexpi_json first.",
            )
        entry = self._models.get(target)
        if entry is None:
            return error_response(
                ErrorCode.MODEL_NOT_FOUND,
                f"No model with id '{target}'.",
            )
        return entry

    # ------------------------------------------------------------------
    # Listing
    # ------------------------------------------------------------------

    def list_models(self) -> list[dict]:
        """Return summary dicts for every loaded model."""
        result = []
        for mid, entry in self._models.items():
            result.append(
                {
                    "model_id": mid,
                    "label": entry.label,
                    "is_active": mid == self._active_id,
                }
            )
        return result


class ConnectionSessions:
    """The :class:`SessionState` of the client making each call.

    Tools hold this object and use it exactly like a ``SessionState``: every attribute is looked
    up on the state of the current caller.

    With ``per_connection=False`` -- stdio, and code calling tool functions directly, as tests do
    -- there is one state. A stdio server is started by one client and serves only it, so that is
    exact, whatever protocol era the client speaks.

    With ``per_connection=True`` -- a network transport -- each client connection has its own
    state, keyed weakly by the object :meth:`serving` names for it, so a closed or expired
    connection's models are freed with it. The server tells the sessions which connection a
    request arrived on (``server._RequestMiddleware``); a call outside a request raises, since
    sharing one state between such calls is exactly what per-connection sessions prevent.
    """

    def __init__(self, *, per_connection: bool = False) -> None:
        self._per_connection = per_connection
        self._by_connection: weakref.WeakKeyDictionary[Any, SessionState] = (
            weakref.WeakKeyDictionary()
        )
        self._single = SessionState()

    @property
    def per_connection(self) -> bool:
        """Whether each client connection has a state of its own."""
        return self._per_connection

    @contextmanager
    def serving(self, connection: object) -> Iterator[None]:
        """Attribute the calls made inside the block to *connection*."""
        token = _CURRENT_CONNECTION.set(connection)
        try:
            yield
        finally:
            _CURRENT_CONNECTION.reset(token)

    def current(self) -> SessionState:
        """The state of the client making the current call."""
        if not self._per_connection:
            return self._single
        connection = _CURRENT_CONNECTION.get()
        if connection is None:
            raise RuntimeError("A tool ran outside a client connection on a network server.")
        state = self._by_connection.get(connection)
        if state is None:
            state = self._by_connection[connection] = SessionState()
        return state

    @property
    def connection_count(self) -> int:
        """How many connections currently hold a state."""
        return len(self._by_connection)

    def __getattr__(self, name: str) -> Any:
        return getattr(self.current(), name)
