"""Detected pyDEXPI import/export/render/validation capabilities.

This module inspects pyDEXPI at runtime and centralizes available functionality
so the GUI can dynamically enable/disable features based on what pyDEXPI supports.
"""

from __future__ import annotations

import importlib
from dataclasses import dataclass, field


@dataclass(frozen=True)
class ExportCapability:
    """Describes a single export format available from pyDEXPI."""

    name: str
    description: str
    file_extension: str
    callable_path: str


@dataclass
class PyDexpiCapabilities:
    """Detected capabilities of the installed pyDEXPI version."""

    can_load_xml: bool = False
    can_load_json: bool = False
    can_load_proteus: bool = False
    can_render_svg: bool = False
    can_query: bool = False
    can_introspect_model: bool = False
    exports: list[ExportCapability] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)


def _import_draw_diagram() -> type | None:
    """Import ``DrawDiagram`` from pyDEXPI."""
    try:
        module = importlib.import_module("pydexpi.exports.svg_export")
        draw_diagram = getattr(module, "DrawDiagram", None)
        if draw_diagram is not None:
            return draw_diagram
    except ImportError:
        pass

    return None


def detect_capabilities() -> PyDexpiCapabilities:
    """Inspect pyDEXPI and detect available functionality.

    Returns
    -------
    PyDexpiCapabilities
        A summary of what pyDEXPI can do in the current environment.
    """
    caps = PyDexpiCapabilities()

    # Check loading
    try:
        from pydexpi import load_xml_file, load_xml_string  # noqa: F401

        caps.can_load_xml = True
    except ImportError as e:
        caps.errors.append(f"XML loading unavailable: {e}")

    try:
        from pydexpi import load_json_file, load_json_string  # noqa: F401

        caps.can_load_json = True
    except ImportError as e:
        caps.errors.append(f"JSON loading unavailable: {e}")

    try:
        from pydexpi.loaders.proteus_serializer import ProteusSerializer  # noqa: F401

        caps.can_load_proteus = True
    except ImportError as e:
        caps.errors.append(f"ProteusXML loading unavailable: {e}")

    # Check SVG rendering
    draw_diagram_cls = _import_draw_diagram()
    if draw_diagram_cls is not None:
        caps.can_render_svg = True
    else:
        caps.errors.append("SVG rendering unavailable: DrawDiagram class not found")

    # Check query engine
    try:
        from pydexpi.query import QueryEngine  # noqa: F401

        caps.can_query = True
    except ImportError as e:
        caps.errors.append(f"Query engine unavailable: {e}")

    # Check model introspection
    try:
        from pydexpi.toolkits.model_toolkit import get_all_instances_in_model  # noqa: F401

        caps.can_introspect_model = True
    except ImportError as e:
        caps.errors.append(f"Model introspection unavailable: {e}")

    # Detect exports
    caps.exports = _detect_exports()

    return caps


def _detect_exports() -> list[ExportCapability]:
    """Detect available export formats from pyDEXPI."""
    exports: list[ExportCapability] = []

    try:
        from pydexpi.exports import export_graphml  # noqa: F401

        exports.append(
            ExportCapability(
                name="GraphML",
                description="Export DEXPI model as GraphML graph file",
                file_extension=".graphml",
                callable_path="pydexpi.exports.export_graphml",
            )
        )
    except ImportError:
        pass

    try:
        from pydexpi.exports import export_tables  # noqa: F401

        exports.append(
            ExportCapability(
                name="Tables",
                description="Export equipment, line, instrument, piping component and valve tables (Excel, CSV or JSON)",
                file_extension=".xlsx",
                callable_path="pydexpi.exports.export_tables",
            )
        )
    except ImportError:
        pass

    try:
        from pydexpi.exports import export_neo4j_csv  # noqa: F401

        exports.append(
            ExportCapability(
                name="Neo4j CSV",
                description="Export as Neo4j-compatible CSV node/relationship files",
                file_extension="",
                callable_path="pydexpi.exports.export_neo4j_csv",
            )
        )
    except ImportError:
        pass

    try:
        from pydexpi.exports import export_llm_context  # noqa: F401

        exports.append(
            ExportCapability(
                name="LLM Context",
                description="Export compact text representation for LLM consumption",
                file_extension=".txt",
                callable_path="pydexpi.exports.export_llm_context",
            )
        )
    except ImportError:
        pass

    # Image exports via DrawDiagram methods (pyDEXPI API)
    draw_diagram_cls = _import_draw_diagram()
    if draw_diagram_cls is not None:
        module_name = draw_diagram_cls.__module__

        if hasattr(draw_diagram_cls, "save_svg"):
            exports.append(
                ExportCapability(
                    name="Image SVG",
                    description="Export diagram as SVG image",
                    file_extension=".svg",
                    callable_path=f"{module_name}.DrawDiagram.save_svg",
                )
            )
        if hasattr(draw_diagram_cls, "save_png"):
            exports.append(
                ExportCapability(
                    name="Image PNG",
                    description="Export diagram as PNG image",
                    file_extension=".png",
                    callable_path=f"{module_name}.DrawDiagram.save_png",
                )
            )
        if hasattr(draw_diagram_cls, "save_pdf"):
            exports.append(
                ExportCapability(
                    name="Image PDF",
                    description="Export diagram as PDF document",
                    file_extension=".pdf",
                    callable_path=f"{module_name}.DrawDiagram.save_pdf",
                )
            )

    # Backward/alternative compatibility: optional image exports in pydexpi.exports
    try:
        exports_mod = importlib.import_module("pydexpi.exports")
        existing = {e.name for e in exports}
        if hasattr(exports_mod, "export_png") and "Image PNG" not in existing:
            exports.append(
                ExportCapability(
                    name="Image PNG",
                    description="Export diagram as PNG image",
                    file_extension=".png",
                    callable_path="pydexpi.exports.export_png",
                )
            )
        if hasattr(exports_mod, "export_svg") and "Image SVG" not in existing:
            exports.append(
                ExportCapability(
                    name="Image SVG",
                    description="Export diagram as SVG image",
                    file_extension=".svg",
                    callable_path="pydexpi.exports.export_svg",
                )
            )
        if hasattr(exports_mod, "export_pdf") and "Image PDF" not in existing:
            exports.append(
                ExportCapability(
                    name="Image PDF",
                    description="Export diagram as PDF document",
                    file_extension=".pdf",
                    callable_path="pydexpi.exports.export_pdf",
                )
            )
    except ImportError:
        pass

    try:
        from pydexpi.loaders.xml_serializer import DexpiXmlSerializer  # noqa: F401
        from pydexpi.loaders.json_serializer import JsonSerializer  # noqa: F401

        exports.append(
            ExportCapability(
                name="DEXPI 2.0.1 XML",
                description="Export model as DEXPI 2.0.1 XML file",
                file_extension=".xml",
                callable_path="pydexpi.loaders.xml_serializer.DexpiXmlSerializer.save",
            )
        )
        exports.append(
            ExportCapability(
                name="DEXPI 2.0.1 JSON",
                description="Export model as DEXPI 2.0.1 JSON file",
                file_extension=".json",
                callable_path="pydexpi.loaders.json_serializer.JsonSerializer.save",
            )
        )
    except ImportError:
        pass

    try:
        from pydexpi.versioning import model_to_projection  # noqa: F401

        exports.append(
            ExportCapability(
                name="Git projection",
                description="Export stable, reviewable text of the model, for diffs in Git",
                file_extension=".txt",
                callable_path="pydexpi.versioning.model_to_projection",
            )
        )
    except ImportError:
        pass

    return exports
