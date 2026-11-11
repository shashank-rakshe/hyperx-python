"""Export tools — convert DEXPI models to various output formats."""

from __future__ import annotations

import json
import logging
import os
import tempfile
from pathlib import Path
from typing import Literal

from pydexpi.exports.dataframe_export import (
    get_all_tables,
    get_equipment_dataframe,
    get_instrument_dataframe,
    get_line_dataframe,
    get_piping_component_dataframe,
)
from pydexpi.exports.graphml_export import export_graphml_bytes
from pydexpi.exports.llm_context_export import export_llm_context_strings
from pydexpi.exports.neo4j_export import export_neo4j_csv_strings
from pydexpi.exports.svg_export import DrawDiagram
from pydexpi.hashing import canonical_json_equality, model_digest
from pydexpi.loaders import DexpiXmlSerializer, JsonSerializer
from pydexpi.loaders.graph_loader import GRAPH_LEVELS
from pydexpi.mcp_server.access import FileAccess, FileAccessError
from pydexpi.mcp_server.errors import ErrorCode, error_response
from pydexpi.mcp_server.serialization import pagination_error
from pydexpi.mcp_server.session import ModelEntry, SessionState
from pydexpi.toolkits.model_summary import summarize_model

_SAVE_FORMATS_BY_SUFFIX: dict[str, Literal["xml", "json"]] = {".xml": "xml", ".json": "json"}


def _write_atomically(path: Path, data: bytes) -> None:
    """Write *data* to a new file beside *path*, then move it into place.

    Replacing the directory entry, rather than writing into whatever *path* names, means a
    hard link or symlink planted at *path* is replaced, never written through; and a reader never
    sees a half-written document.
    """
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        os.replace(temporary, path)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise


_TRUNCATION_MARKER = "\n... [truncated]"

logger = logging.getLogger(__name__)


# One registrar defines every export tool as a closure, and ruff counts each nested statement
# against it. Splitting it into per-format registrars is a follow-up.
def _register_export_tools(  # noqa: C901, PLR0915
    mcp, state: SessionState, file_access: FileAccess
) -> None:
    """Register all export tools on *mcp*."""

    # ------------------------------------------------------------------
    # SVG
    # ------------------------------------------------------------------

    @mcp.tool()
    def export_svg(pretty: bool = True, model_id: str | None = None) -> str:
        """Export the DEXPI diagram as an SVG string.

        Requires the model to contain diagram (graphical) data.

        Parameters
        ----------
        pretty : bool
            If ``True``, apply thinner lines and scale to A3.
        model_id : str, optional
            Target model.  Falls back to the active model if omitted.

        Returns
        -------
        str
            The SVG document as a string, or an error envelope.
        """
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        entry: ModelEntry = resolved
        diagram = entry.model.diagram
        if diagram is None:
            return error_response(
                ErrorCode.EXPORT_ERROR, "Model has no diagram data for SVG export."
            )
        try:
            drawer = DrawDiagram(diagram, pretty=pretty)
            return drawer.draw_svg()
        except Exception as exc:
            logger.debug("export_svg failed", exc_info=True)
            return error_response(ErrorCode.EXPORT_ERROR, "SVG export failed.", str(exc))

    # ------------------------------------------------------------------
    # GraphML
    # ------------------------------------------------------------------

    @mcp.tool()
    def export_graphml(
        graph_level: str = "complete",
        embed_shape_usage: bool = False,
        model_id: str | None = None,
    ) -> str:
        """Export the model as GraphML (XML string).

        Parameters
        ----------
        graph_level : str
            ``"complete"``, ``"process"``, ``"conceptual"`` (P&ID levels) or
            ``"process_flow"`` (a process model's steps and connections).
        embed_shape_usage : bool
            Whether to embed graphical position data.
        model_id : str, optional
            Target model.  Falls back to the active model if omitted.

        Returns
        -------
        str
            The GraphML document as a UTF-8 string, or an error envelope.
        """
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        entry: ModelEntry = resolved
        if graph_level not in GRAPH_LEVELS:
            return error_response(
                ErrorCode.INVALID_PARAMETER,
                f"Invalid graph_level '{graph_level}'. "
                f"Must be one of {', '.join(map(repr, GRAPH_LEVELS))}.",
            )
        try:
            data = export_graphml_bytes(
                entry.model,
                graph_level=graph_level,  # type: ignore[arg-type]
                embed_shape_usage=embed_shape_usage,
            )
            return data.decode("utf-8")
        except Exception as exc:
            logger.debug("export_graphml failed", exc_info=True)
            return error_response(ErrorCode.EXPORT_ERROR, "GraphML export failed.", str(exc))

    # ------------------------------------------------------------------
    # LLM context
    # ------------------------------------------------------------------

    @mcp.tool()
    def export_llm_context(
        graph_level: str = "complete",
        mode: str = "graph",
        model_id: str | None = None,
    ) -> str:
        """Export a compact LLM-ready text representation of the model.

        This is a key tool for building chat contexts around P&ID data.

        Parameters
        ----------
        graph_level : str
            ``"complete"``, ``"process"``, ``"conceptual"`` (P&ID levels) or
            ``"process_flow"`` (a process model's steps and connections).
        mode : str
            ``"graph"`` (nodes + edges with data) or ``"topology"`` (id/label only).
        model_id : str, optional
            Target model.  Falls back to the active model if omitted.

        Returns
        -------
        str
            Compact text representation suitable for LLM prompts.
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
        if mode not in ("graph", "topology"):
            return error_response(
                ErrorCode.INVALID_PARAMETER,
                f"Invalid mode '{mode}'. Must be 'graph' or 'topology'.",
            )
        try:
            return export_llm_context_strings(
                entry.model,
                graph_level=graph_level,  # type: ignore[arg-type]
                mode=mode,  # type: ignore[arg-type]
            )
        except Exception as exc:
            logger.debug("export_llm_context failed", exc_info=True)
            return error_response(ErrorCode.EXPORT_ERROR, "LLM context export failed.", str(exc))

    @mcp.tool()
    def build_chat_context(
        context_mode: str = "overview",
        max_chars: int | None = None,
        model_id: str | None = None,
    ) -> str:
        """Build a structured context block for chat agents.

        This is the primary tool for preparing model data for LLM reasoning.
        It combines model metadata, equipment, lines, instruments, and
        connectivity into a single, deterministic, compact text.

        Parameters
        ----------
        context_mode : str
            One of:

            - ``"overview"`` — short summary for general chat.
            - ``"detailed"`` — full plant/item/connectivity context.
            - ``"equipment_focus"`` — equipment-centric detail.
            - ``"connectivity_focus"`` — "what connects to what" detail.
        max_chars : int, optional
            Truncate the output to at most this many characters, ending in a
            truncation marker. Must be at least the marker's length (16).
        model_id : str, optional
            Target model.  Falls back to the active model if omitted.

        Returns
        -------
        str
            Structured text context or error envelope.
        """
        if max_chars is not None and max_chars < len(_TRUNCATION_MARKER):
            return error_response(
                ErrorCode.INVALID_PARAMETER,
                f"max_chars must be at least {len(_TRUNCATION_MARKER)}, got {max_chars}.",
            )
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        entry: ModelEntry = resolved

        valid_modes = ("overview", "detailed", "equipment_focus", "connectivity_focus")
        if context_mode not in valid_modes:
            return error_response(
                ErrorCode.INVALID_PARAMETER,
                f"Invalid context_mode '{context_mode}'. Must be one of {valid_modes}.",
            )

        try:
            sections: list[str] = []

            # --- Header ---
            summary = summarize_model(entry.model).to_dict()
            sections.append("# DEXPI Model Context")
            sections.append(f"Equipment: {summary['equipment_count']}")
            sections.append(f"Piping segments: {summary['piping_segment_count']}")
            sections.append(f"Instruments: {summary['instrument_count']}")
            sections.append(f"Piping components: {summary['piping_component_count']}")
            if summary["process_step_count"] or summary["process_connection_count"]:
                sections.append(f"Process steps: {summary['process_step_count']}")
                sections.append(
                    f"Process connections: {summary['process_connection_count']} "
                    f"({summary['stream_count']} streams, "
                    f"{summary['energy_flow_count']} energy flows, "
                    f"{summary['information_flow_count']} information flows)"
                )
            sections.append(f"Total objects: {summary['total_objects']}")
            sections.append(f"Has diagram: {summary['has_diagram']}")
            sections.append("")

            # --- Equipment ---
            if context_mode in ("overview", "detailed", "equipment_focus"):
                try:
                    eq_df = get_equipment_dataframe(entry.model)
                    if not eq_df.empty:
                        sections.append("## Equipment")
                        if context_mode == "overview":
                            sections.append(eq_df.to_string(max_rows=20, max_cols=5))
                        else:
                            sections.append(eq_df.to_string())
                        sections.append("")
                except Exception:
                    logger.debug("build_chat_context: skipped equipment section", exc_info=True)

            # --- Lines ---
            if context_mode in ("overview", "detailed", "connectivity_focus"):
                try:
                    line_df = get_line_dataframe(entry.model)
                    if not line_df.empty:
                        sections.append("## Piping Lines")
                        if context_mode == "overview":
                            sections.append(line_df.to_string(max_rows=20, max_cols=5))
                        else:
                            sections.append(line_df.to_string())
                        sections.append("")
                except Exception:
                    logger.debug("build_chat_context: skipped lines section", exc_info=True)

            # --- Instruments ---
            if context_mode in ("overview", "detailed", "equipment_focus"):
                try:
                    instr_df = get_instrument_dataframe(entry.model)
                    if not instr_df.empty:
                        sections.append("## Instruments")
                        if context_mode == "overview":
                            sections.append(instr_df.to_string(max_rows=20, max_cols=5))
                        else:
                            sections.append(instr_df.to_string())
                        sections.append("")
                except Exception:
                    logger.debug("build_chat_context: skipped instruments section", exc_info=True)

            # --- Connectivity (topology) ---
            if context_mode in ("detailed", "connectivity_focus"):
                try:
                    topo = export_llm_context_strings(
                        entry.model,
                        graph_level="conceptual",
                        mode="topology",
                    )
                    sections.append("## Connectivity (conceptual topology)")
                    sections.append(topo)
                    sections.append("")
                except Exception:
                    logger.debug("build_chat_context: skipped connectivity section", exc_info=True)

            text = "\n".join(sections)
        except Exception as exc:
            logger.debug("build_chat_context failed", exc_info=True)
            return error_response(ErrorCode.EXPORT_ERROR, "build_chat_context failed.", str(exc))

        if max_chars is not None and len(text) > max_chars:
            text = text[: max_chars - len(_TRUNCATION_MARKER)] + _TRUNCATION_MARKER
        return text

    # ------------------------------------------------------------------
    # Tables (JSON)
    # ------------------------------------------------------------------

    @mcp.tool()
    def export_tables(
        list_type: str = "all",
        limit: int | None = None,
        model_id: str | None = None,
    ) -> str:
        """Export equipment, line, instrument, or piping component tables as JSON.

        Parameters
        ----------
        list_type : str
            ``"all"``, ``"equipment"``, ``"line"``, ``"instrument"``, or
            ``"piping_component"``.
        limit : int, optional
            Maximum number of rows per table.
        model_id : str, optional
            Target model.  Falls back to the active model if omitted.

        Returns
        -------
        str
            JSON object keyed by table name.
        """
        if (bad_paging := pagination_error(limit=limit)) is not None:
            return bad_paging
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        entry: ModelEntry = resolved
        valid = ("all", "equipment", "line", "instrument", "piping_component")
        if list_type not in valid:
            return error_response(
                ErrorCode.INVALID_PARAMETER,
                f"Invalid list_type '{list_type}'. Must be one of {valid}.",
            )
        try:
            if list_type == "all":
                tables = get_all_tables(entry.model)
            elif list_type == "equipment":
                tables = {"equipment": get_equipment_dataframe(entry.model)}
            elif list_type == "line":
                tables = {"line": get_line_dataframe(entry.model)}
            elif list_type == "instrument":
                tables = {"instrument": get_instrument_dataframe(entry.model)}
            else:
                tables = {"piping_component": get_piping_component_dataframe(entry.model)}

            result = {}
            for name, df in tables.items():
                rows = df.head(limit) if limit is not None else df
                result[name] = json.loads(rows.to_json(orient="records"))
            return json.dumps(result)
        except Exception as exc:
            logger.debug("export_tables failed", exc_info=True)
            return error_response(ErrorCode.EXPORT_ERROR, "Table export failed.", str(exc))

    # ------------------------------------------------------------------
    # Neo4j CSV
    # ------------------------------------------------------------------

    @mcp.tool()
    def export_neo4j_csv(
        graph_level: str = "complete",
        model_id: str | None = None,
    ) -> str:
        """Export the model as Neo4j-compatible CSV strings.

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
            JSON with ``nodes_csv`` and ``relationships_csv`` keys.
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
            result = export_neo4j_csv_strings(
                entry.model,
                graph_level=graph_level,  # type: ignore[arg-type]
            )
            return json.dumps(
                {
                    "nodes_csv": result.nodes_csv,
                    "relationships_csv": result.relationships_csv,
                }
            )
        except Exception as exc:
            logger.debug("export_neo4j_csv failed", exc_info=True)
            return error_response(ErrorCode.EXPORT_ERROR, "Neo4j export failed.", str(exc))

    # ------------------------------------------------------------------
    # XML / JSON round-trip
    # ------------------------------------------------------------------

    @mcp.tool()
    def export_xml(model_id: str | None = None) -> str:
        """Export the model back to DEXPI XML.

        Parameters
        ----------
        model_id : str, optional
            Target model.  Falls back to the active model if omitted.

        Returns
        -------
        str
            The DEXPI XML document.
        """
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        entry: ModelEntry = resolved
        try:
            serializer = DexpiXmlSerializer()
            data = serializer.export_to_bytes(entry.model)
            return data.decode("utf-8") if isinstance(data, bytes) else str(data)
        except Exception as exc:
            logger.debug("export_xml failed", exc_info=True)
            return error_response(ErrorCode.EXPORT_ERROR, "XML export failed.", str(exc))

    @mcp.tool()
    def export_json(model_id: str | None = None) -> str:
        """Export the model as DEXPI JSON.

        Parameters
        ----------
        model_id : str, optional
            Target model.  Falls back to the active model if omitted.

        Returns
        -------
        str
            The DEXPI JSON document.
        """
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        entry: ModelEntry = resolved
        try:
            serializer = JsonSerializer()
            data = serializer.export_to_bytes(entry.model)
            return data.decode("utf-8") if isinstance(data, bytes) else str(data)
        except Exception as exc:
            logger.debug("export_json failed", exc_info=True)
            return error_response(ErrorCode.EXPORT_ERROR, "JSON export failed.", str(exc))

    @mcp.tool()
    def save_model(
        path: str,
        file_format: Literal["xml", "json"] | None = None,
        overwrite: bool = False,
        model_id: str | None = None,
    ) -> str:
        """Save the model to a file on the server filesystem.

        Parameters
        ----------
        path : str
            Path of the file to write; ``~`` is expanded. A relative path is
            resolved against the *server process's* working directory -- or,
            when the server was started with a file root, against that root,
            outside which nothing can be written. Its parent directory must
            exist.
        file_format : {"xml", "json"}, optional
            Output format. Inferred from the file extension (``.xml`` or
            ``.json``) if omitted.
        overwrite : bool
            If False (default), refuse to replace an existing file.
        model_id : str, optional
            Target model.  Falls back to the active model if omitted.

        Returns
        -------
        str
            JSON with the absolute ``path``, ``format`` and ``bytes`` written,
            or an error envelope.
        """
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        entry: ModelEntry = resolved
        try:
            p = file_access.resolve(path)
        except FileAccessError as exc:
            return error_response(ErrorCode.ACCESS_DENIED, str(exc))
        if file_format is None:
            file_format = _SAVE_FORMATS_BY_SUFFIX.get(p.suffix.lower())
            if file_format is None:
                return error_response(
                    ErrorCode.INVALID_PARAMETER,
                    f"Cannot infer format from extension {p.suffix!r}.",
                    "Use a .xml or .json extension, or pass file_format.",
                )
        if not p.parent.is_dir():
            return error_response(
                ErrorCode.FILE_NOT_FOUND, f"Directory not found: {file_access.display(p.parent)}"
            )
        if p.is_dir():
            return error_response(ErrorCode.INVALID_PARAMETER, f"Path is a directory: {path}")
        if p.exists() and not overwrite:
            return error_response(
                ErrorCode.INVALID_PARAMETER,
                f"File already exists: {path}",
                "Pass overwrite=True to replace it.",
            )
        serializer = DexpiXmlSerializer() if file_format == "xml" else JsonSerializer()
        try:
            data = serializer.export_to_bytes(entry.model)
        # A tool returns an error envelope rather than raising, so any serializer failure reaches
        # the client as data instead of as a protocol error (BLE001).
        except Exception as exc:  # noqa: BLE001
            return error_response(
                ErrorCode.EXPORT_ERROR, f"{file_format.upper()} export failed.", str(exc)
            )
        if isinstance(data, str):
            data = data.encode("utf-8")
        try:
            _write_atomically(p, data)
        except OSError as exc:
            return error_response(ErrorCode.EXPORT_ERROR, f"Failed to write {path}.", str(exc))
        return json.dumps(
            {"path": file_access.display(p), "format": file_format, "bytes": len(data)}
        )

    # ------------------------------------------------------------------
    # Hashing / comparison
    # ------------------------------------------------------------------

    @mcp.tool()
    def hash_model(model_id: str | None = None) -> str:
        """Return a digest of the model's exact serialized state.

        Two models have the same digest exactly when they serialize to the
        same document, ids and list order included. The digest is stable
        across processes, so it can be stored and compared later, e.g. to
        detect whether a model changed since it was last seen.

        It is **not** a semantic comparison: loading the same DEXPI XML file
        twice gives different digests, because objects the file leaves
        without an id get a fresh one on every load.

        Parameters
        ----------
        model_id : str, optional
            Target model.  Falls back to the active model if omitted.

        Returns
        -------
        str
            JSON with ``hash`` (a hex digest) key.
        """
        resolved = state.resolve_model(model_id)
        if isinstance(resolved, str):
            return resolved
        entry: ModelEntry = resolved
        try:
            h = model_digest(entry.model)
            return json.dumps({"hash": h})
        except Exception as exc:
            logger.debug("hash_model failed", exc_info=True)
            return error_response(ErrorCode.INTERNAL_ERROR, "Hashing failed.", str(exc))

    @mcp.tool()
    def compare_models(model_id_a: str, model_id_b: str) -> str:
        """Compare two loaded models, ignoring the order of unordered lists.

        Models are equal when they hold the same objects with the same ids
        and values. A list whose order carries meaning -- a vector's values, a
        template's component list, the drawing's z-order and geometry, a
        segment's flow order -- is compared in order, as the exit status of
        ``pydexpi diff --exit-code`` compares it; the order of any other list
        is not a difference. Ids matter: two loads of one DEXPI XML file are **not**
        equal, because objects the file leaves without an id get a fresh one
        on every load. Use it to check whether a model still matches one it
        was copied, saved or exported from in this session.

        Parameters
        ----------
        model_id_a : str
            First model ID.
        model_id_b : str
            Second model ID.

        Returns
        -------
        str
            JSON with ``equal`` (bool) key.
        """
        resolved_a = state.resolve_model(model_id_a)
        if isinstance(resolved_a, str):
            return resolved_a
        resolved_b = state.resolve_model(model_id_b)
        if isinstance(resolved_b, str):
            return resolved_b
        try:
            eq = canonical_json_equality(resolved_a.model, resolved_b.model)
            return json.dumps({"equal": eq})
        except Exception as exc:
            logger.debug("compare_models failed", exc_info=True)
            return error_response(ErrorCode.INTERNAL_ERROR, "Comparison failed.", str(exc))
