"""Tests for pyDEXPI capability detection."""

import pydexpi.exports as exports_mod

from dexpi_studio.core.capabilities import (
    ExportCapability,
    PyDexpiCapabilities,
    detect_capabilities,
)


def test_detect_capabilities_returns_dataclass():
    """detect_capabilities returns a PyDexpiCapabilities instance."""
    caps = detect_capabilities()
    assert isinstance(caps, PyDexpiCapabilities)


def test_xml_loading_detected():
    """pyDEXPI XML loading should be detected."""
    caps = detect_capabilities()
    assert caps.can_load_xml is True


def test_json_loading_detected():
    """pyDEXPI JSON loading should be detected."""
    caps = detect_capabilities()
    assert caps.can_load_json is True


def test_svg_rendering_detected():
    """pyDEXPI SVG rendering should be detected."""
    caps = detect_capabilities()
    assert caps.can_render_svg is True


def test_query_engine_detected():
    """pyDEXPI query engine should be detected."""
    caps = detect_capabilities()
    assert caps.can_query is True


def test_model_introspection_detected():
    """pyDEXPI model introspection should be detected."""
    caps = detect_capabilities()
    assert caps.can_introspect_model is True


def test_exports_detected():
    """At least some export capabilities should be detected."""
    caps = detect_capabilities()
    assert len(caps.exports) > 0
    for export in caps.exports:
        assert isinstance(export, ExportCapability)
        assert export.name
        assert export.callable_path


def test_graphml_export_available():
    """GraphML export should be available."""
    caps = detect_capabilities()
    names = [e.name for e in caps.exports]
    assert "GraphML" in names


def test_tables_export_available():
    """The tables export should be available."""
    caps = detect_capabilities()
    names = [e.name for e in caps.exports]
    assert "Tables" in names


def test_image_svg_export_available_via_drawdiagram():
    """Image SVG export should be detected when DrawDiagram.save_svg exists."""
    caps = detect_capabilities()
    names = {e.name for e in caps.exports}
    assert "Image SVG" in names


def test_optional_image_exports_detected_when_available(monkeypatch):
    """Image exports are detected when optional pyDEXPI callables exist."""

    def _noop(*_args, **_kwargs):  # type: ignore[no-untyped-def]
        return None

    monkeypatch.setattr(exports_mod, "export_png", _noop, raising=False)
    monkeypatch.setattr(exports_mod, "export_svg", _noop, raising=False)
    monkeypatch.setattr(exports_mod, "export_pdf", _noop, raising=False)

    caps = detect_capabilities()
    names = {e.name for e in caps.exports}
    assert "Image PNG" in names
    assert "Image SVG" in names
    assert "Image PDF" in names


def test_drawdiagram_image_exports_detected_with_module_paths(monkeypatch):
    """Image exports include PNG/PDF and a DrawDiagram callable path when methods exist."""
    import dexpi_studio.core.capabilities as cap_mod

    class _FakeDrawDiagram:
        __module__ = "pydexpi.exports.svg_export"

        def save_svg(self): ...

        def save_png(self): ...

        def save_pdf(self): ...

    monkeypatch.setattr(cap_mod, "_import_draw_diagram", lambda: _FakeDrawDiagram)

    caps = detect_capabilities()
    by_name = {e.name: e for e in caps.exports}

    assert "Image PNG" in by_name
    assert "Image PDF" in by_name
    assert by_name["Image PNG"].callable_path.endswith("DrawDiagram.save_png")
    assert by_name["Image PDF"].callable_path.endswith("DrawDiagram.save_pdf")
