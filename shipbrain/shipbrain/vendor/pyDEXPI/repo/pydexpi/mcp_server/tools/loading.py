"""Loading tools — parse and manage DEXPI models in the session."""

from __future__ import annotations

import json
import logging
from collections import Counter
from typing import Any

from pydexpi.exports.graphml_export import export_graphml_bytes
from pydexpi.loaders import JsonSerializer
from pydexpi.loaders.compat import ConversionRefusedError
from pydexpi.loaders.error_registry import ErrorLevels
from pydexpi.loaders.public import load_xml_with_report
from pydexpi.mcp_server.access import FileAccess, FileAccessError
from pydexpi.mcp_server.errors import ErrorCode, error_response
from pydexpi.mcp_server.session import SessionState
from pydexpi.pydexpi_classes import EngineeringModel
from pydexpi.toolkits.model_summary import summarize_model

logger = logging.getLogger(__name__)

#: The largest file ``load_dexpi_xml_file`` reads. Content sent inline is already bounded by the
#: transport's request size limit; a file on disk is not.
MAX_DOCUMENT_BYTES = 64 * 2**20


def _graphml_context(model: EngineeringModel) -> dict:
    """Return the conceptual GraphML flowsheet context for a loaded model.

    On success the result is ``{"graphml_context": <GraphML string>}``.  If the
    export fails, loading still succeeds, but ``graphml_context`` is ``None`` and a
    ``graphml_context_error`` entry explains why, so the agent is not left without
    the P&ID topology silently.
    """
    try:
        graphml = export_graphml_bytes(model, graph_level="conceptual").decode("utf-8")
    except Exception as exc:
        logger.debug("_graphml_context failed", exc_info=True)
        return {
            "graphml_context": None,
            "graphml_context_error": {
                "error_code": str(ErrorCode.EXPORT_ERROR),
                "message": (
                    "The model was loaded, but the conceptual GraphML flowsheet context "
                    "could not be generated. Model queries still work; retry with the "
                    "export_graphml tool or inspect the model with the query tools."
                ),
                "details": f"{type(exc).__name__}: {exc}",
            },
        }
    return {"graphml_context": graphml}


def _loading_issues(errors) -> dict[str, Any]:
    """Summarise a loader's error registry entries for the client.

    ``counts`` has one entry per level that occurred; ``messages`` lists the
    first :data:`_MAX_REPORTED_ISSUES` entries above INFO, most severe level
    first, so a client learns what a load dropped without receiving hundreds
    of lines. An entry that carries the source text of what was dropped -- an
    object reading DEXPI 2.0 as 2.0.1 had no owner for -- keeps it as ``content``.
    """
    counts = Counter(str(entry.level) for entry in errors)
    loud = [entry for entry in errors if entry.level != ErrorLevels.INFO]
    loud.sort(key=lambda entry: _LEVEL_ORDER.index(entry.level))
    return {
        "counts": dict(counts),
        "messages": [
            {"level": str(entry.level), "message": entry.message}
            | ({"content": entry.content} if entry.content is not None else {})
            for entry in loud[:_MAX_REPORTED_ISSUES]
        ],
    }


def _refused(exc: ConversionRefusedError) -> str:
    """The error envelope of a strict load that refused a DEXPI 2.0 document."""
    return error_response(
        ErrorCode.CONVERSION_REFUSED,
        "Strict loading refused this DEXPI 2.0 document: DEXPI 2.0.1 cannot represent all of it "
        "without copying or dropping data. Load it with strict=false to convert it; every copy "
        "and drop is then reported in loading_issues.",
        str(exc),
    )


_MAX_REPORTED_ISSUES = 20
_LEVEL_ORDER = [ErrorLevels.CRITICAL, ErrorLevels.ERROR, ErrorLevels.WARNING, ErrorLevels.INFO]


def _loaded_response(
    state: SessionState,
    model: EngineeringModel,
    label: str,
    errors,
    include_graphml: bool,
) -> str:
    """Register a freshly loaded *model* and return the load tool's JSON response.

    The response is built **before** the model joins the session, so a model
    that cannot be summarised is never left behind as an unusable active model.
    """
    if state.is_full:
        return state.full_error()
    try:
        summary = summarize_model(model).to_dict()
    except Exception as exc:
        logger.debug("summarising a loaded model failed", exc_info=True)
        return error_response(
            ErrorCode.INTERNAL_ERROR, "The model loaded but could not be summarised.", str(exc)
        )
    response: dict[str, Any] = {**summary, "loading_issues": _loading_issues(errors)}
    if include_graphml:
        response.update(_graphml_context(model))
    model_id = state.add_model(model, label=label)
    return json.dumps({"model_id": model_id, **response})


def _register_loading_tools(mcp, state: SessionState, file_access: FileAccess) -> None:
    """Register all model-loading tools on *mcp*."""

    @mcp.tool()
    def load_dexpi_xml(xml_content: str, strict: bool = True, include_graphml: bool = True) -> str:
        """Load a DEXPI model from an XML string.

        Parameters
        ----------
        xml_content : str
            The full DEXPI or Proteus XML document as a string.
        strict : bool
            If True (default), objects omitting an attribute DEXPI makes
            mandatory are discarded. DEXPI *process* exports routinely omit
            ``Identifier`` and lose most of their content this way; pass
            False to keep them. A DEXPI 2.0 document is read as 2.0.1; one
            that 2.0.1 cannot represent without copying or dropping data is
            refused under True (``conversion_refused``) and converted under
            False. Proteus files ignore this setting.
        include_graphml : bool
            If True (default), the response carries ``graphml_context``, the
            conceptual flowsheet as GraphML (tens of kilobytes for a typical
            P&ID). Pass False to keep the response small; ``export_graphml``
            returns the same on demand.

        Returns
        -------
        str
            JSON with ``model_id``, a model summary and ``loading_issues``
            (counts by level, and the first messages above INFO), plus
            ``graphml_context`` unless disabled; or an error envelope.
        """
        try:
            report = load_xml_with_report(xml_content, strict=strict)
        except ConversionRefusedError as exc:
            return _refused(exc)
        except Exception as exc:
            logger.debug("load_dexpi_xml failed", exc_info=True)
            return error_response(ErrorCode.INVALID_XML, "Failed to parse XML.", str(exc))
        return _loaded_response(state, report.model, "xml-upload", report.errors, include_graphml)

    @mcp.tool()
    def load_dexpi_json(
        json_content: str, strict: bool = True, include_graphml: bool = True
    ) -> str:
        """Load a DEXPI model from a JSON string.

        Parameters
        ----------
        json_content : str
            The full DEXPI JSON document as a string.
        strict : bool
            As for ``load_dexpi_xml``. A process model loaded with
            ``strict=False`` and saved as JSON still omits ``Identifier``, so
            reading it back needs False too.
        include_graphml : bool
            As for ``load_dexpi_xml``.

        Returns
        -------
        str
            JSON with ``model_id``, a model summary and ``loading_issues``,
            plus ``graphml_context`` unless disabled; or an error envelope.
        """
        serializer = JsonSerializer(strict=strict)
        try:
            model = serializer.load_from_string(json_content)
        except Exception as exc:
            logger.debug("load_dexpi_json failed", exc_info=True)
            return error_response(ErrorCode.INVALID_JSON, "Failed to parse JSON.", str(exc))
        if not isinstance(model, EngineeringModel):
            for entry in serializer.get_loading_errors():
                if isinstance(entry.exception, ConversionRefusedError):
                    return _refused(entry.exception)
            if model is None:
                # The loader built nothing: a document that is no JSON object, or whose root
                # names no class. Its registry says which; the client has nothing else.
                issues = _loading_issues(serializer.get_loading_errors())["messages"]
                return error_response(
                    ErrorCode.INVALID_JSON,
                    "The JSON document could not be loaded: its root object could not be built.",
                    "\n".join(f"{issue['level']}: {issue['message']}" for issue in issues) or None,
                )
            return error_response(
                ErrorCode.INVALID_JSON,
                f"Parsed object is {type(model).__name__}, expected EngineeringModel.",
            )
        return _loaded_response(
            state, model, "json-upload", serializer.get_loading_errors(), include_graphml
        )

    @mcp.tool()
    def load_dexpi_xml_file(path: str, strict: bool = True, include_graphml: bool = True) -> str:
        """Load a DEXPI model from an XML file on the server filesystem.

        Parameters
        ----------
        path : str
            Path to the DEXPI or Proteus XML file; ``~`` is expanded. A
            relative path is resolved against the *server process's* working
            directory -- or, when the server was started with a file root,
            against that root, outside which no file can be read.
        strict : bool
            As for ``load_dexpi_xml``.
        include_graphml : bool
            As for ``load_dexpi_xml``.

        Returns
        -------
        str
            JSON with ``model_id``, a model summary and ``loading_issues``,
            plus ``graphml_context`` unless disabled; or an error envelope.
        """
        try:
            p = file_access.resolve(path)
        except FileAccessError as exc:
            return error_response(ErrorCode.ACCESS_DENIED, str(exc))
        if not p.is_file():
            return error_response(ErrorCode.FILE_NOT_FOUND, f"File not found: {path}")
        if p.stat().st_size > MAX_DOCUMENT_BYTES:
            return error_response(
                ErrorCode.INVALID_PARAMETER,
                f"{path} is larger than {MAX_DOCUMENT_BYTES // 2**20} MiB.",
            )
        if state.is_full:
            return state.full_error()
        try:
            report = load_xml_with_report(p.read_bytes(), strict=strict)
        except ConversionRefusedError as exc:
            return _refused(exc)
        except Exception as exc:
            logger.debug("load_dexpi_xml_file failed", exc_info=True)
            return error_response(ErrorCode.INVALID_XML, "Failed to parse XML file.", str(exc))
        return _loaded_response(state, report.model, p.name, report.errors, include_graphml)

    @mcp.tool()
    def list_loaded_models() -> str:
        """List all currently loaded models.

        Returns
        -------
        str
            JSON array of model summaries with ``model_id``, ``label``, and
            ``is_active`` fields.
        """
        return json.dumps(state.list_models())

    @mcp.tool()
    def set_active_model(model_id: str) -> str:
        """Set the active model for subsequent tool calls.

        Parameters
        ----------
        model_id : str
            ID of the model to make active.

        Returns
        -------
        str
            Confirmation JSON or error envelope.
        """
        err = state.set_active(model_id)
        if err is not None:
            return err
        return json.dumps({"active_model_id": model_id})

    @mcp.tool()
    def unload_model(model_id: str) -> str:
        """Remove a model from the session to free memory.

        Parameters
        ----------
        model_id : str
            ID of the model to unload.

        Returns
        -------
        str
            Confirmation JSON or error envelope.
        """
        if state.remove_model(model_id):
            return json.dumps({"unloaded": model_id})
        return error_response(ErrorCode.MODEL_NOT_FOUND, f"No model with id '{model_id}'.")

    @mcp.tool()
    def clear_models() -> str:
        """Remove all loaded models from the session.

        Returns
        -------
        str
            JSON with the number of models removed.
        """
        count = state.clear()
        return json.dumps({"cleared": count})
