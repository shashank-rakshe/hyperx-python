"""Helpers for serialising pyDEXPI objects to compact JSON-safe dicts.

MCP tools must return JSON strings.  Rather than dumping raw Pydantic
models (which are deeply nested and noisy), we define narrow, stable
schemas here.
"""

from __future__ import annotations

from typing import Any

from pydexpi.mcp_server.errors import ErrorCode, error_response
from pydexpi.pydexpi_classes.pydexpi_classes import PyDexpiBaseModel
from pydexpi.toolkits.display_name import get_display_name, get_tag


def object_summary(obj: PyDexpiBaseModel) -> dict[str, Any]:
    """Return a compact dict for a single DEXPI object.

    ``tag`` and ``display_name`` come from :mod:`pydexpi.toolkits.display_name`,
    the single source of truth for both: ``tag`` is omitted when the object
    has none, ``display_name`` is always present.
    """
    summary: dict[str, Any] = {
        "id": obj.id,
        "type": type(obj).__name__,
        "display_name": get_display_name(obj),
    }
    tag = get_tag(obj)
    if tag:
        summary["tag"] = tag
    return summary


class PaginationError(ValueError):
    """Raised when an offset or limit is negative."""


def check_pagination(*, limit: int | None, offset: int = 0) -> None:
    """Raise :class:`PaginationError` for a negative *offset* or *limit*.

    A negative value would be read as Python slice arithmetic -- ``offset=-3``
    returning the *last* three items -- which is never what a client means.
    """
    if offset < 0:
        raise PaginationError(f"offset must be >= 0, got {offset}.")
    if limit is not None and limit < 0:
        raise PaginationError(f"limit must be >= 0, got {limit}.")


def pagination_error(*, limit: int | None, offset: int = 0) -> str | None:
    """Return an ``invalid_parameter`` envelope for bad paging arguments, else ``None``.

    Tools call this before any ``try``: their broad handlers would otherwise
    report a bad argument as an export or internal error.
    """
    try:
        check_pagination(limit=limit, offset=offset)
    except PaginationError as exc:
        return error_response(ErrorCode.INVALID_PARAMETER, str(exc))
    return None


def paginate(items: list, *, limit: int | None = None, offset: int = 0) -> dict[str, Any]:
    """Apply offset/limit pagination and return a result envelope.

    Raises
    ------
    PaginationError
        If *offset* or *limit* is negative.
    """
    check_pagination(limit=limit, offset=offset)
    total = len(items)
    sliced = items[offset:]
    if limit is not None:
        sliced = sliced[:limit]
    return {
        "total": total,
        "offset": offset,
        "limit": limit,
        "count": len(sliced),
        "items": sliced,
    }
