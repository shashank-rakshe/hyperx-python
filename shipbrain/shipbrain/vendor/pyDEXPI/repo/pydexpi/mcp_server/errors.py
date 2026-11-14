"""Structured error model for the pyDEXPI MCP server.

Every tool returns JSON.  When an operation fails, the response contains a
standardised error envelope so that agents can react programmatically.
"""

from __future__ import annotations

import json
from enum import StrEnum


class ErrorCode(StrEnum):
    """Machine-readable error codes returned by MCP tools, including an installed extension's."""

    NO_ACTIVE_MODEL = "no_active_model"
    MODEL_NOT_FOUND = "model_not_found"
    INVALID_XML = "invalid_xml"
    INVALID_JSON = "invalid_json"
    OBJECT_NOT_FOUND = "object_not_found"
    AMBIGUOUS_TAG = "ambiguous_tag"
    FILE_NOT_FOUND = "file_not_found"
    INVALID_PARAMETER = "invalid_parameter"
    ACCESS_DENIED = "access_denied"
    SESSION_FULL = "session_full"
    EXPORT_ERROR = "export_error"
    NOTHING_TO_UNDO = "nothing_to_undo"
    NOTHING_TO_REDO = "nothing_to_redo"
    HISTORY_CONFLICT = "history_conflict"
    CONVERSION_REFUSED = "conversion_refused"
    INTERNAL_ERROR = "internal_error"


def error_response(
    code: ErrorCode, message: str, details: str | None = None, *, reason: dict | None = None
) -> str:
    """Build a JSON error response string.

    Parameters
    ----------
    code : ErrorCode or str
        Machine-readable error code. An installed extension that adds tools may pass a code
        of its own as a plain string.
    message : str
        Human-readable summary.
    details : str, optional
        Additional context (e.g. traceback excerpt).
    reason : dict, optional
        JSON-safe structured data about the refusal, passed through without parsing the
        message.

    Returns
    -------
    str
        JSON-encoded error envelope.
    """
    payload: dict = {"error": True, "error_code": str(code), "message": message}
    if details is not None:
        payload["details"] = details
    if reason is not None:
        payload["reason"] = reason
    return json.dumps(payload)
