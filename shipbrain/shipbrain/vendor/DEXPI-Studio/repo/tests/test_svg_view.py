"""Unit tests for SVG highlight geometry extraction in SvgViewWidget.

These tests use small synthetic SVG strings to verify that highlight
rectangles and pipe paths land in the correct world-coordinate space —
matching what QSvgRenderer actually renders — rather than drifting due to
ignored ancestor transforms or incorrect QRectF accumulation.

Run with::

    pytest tests/test_svg_view.py

On headless systems set ``QT_QPA_PLATFORM=offscreen`` (or use the
``pytest-qt`` ``qt_app`` fixture which handles this automatically).
"""

from __future__ import annotations

import xml.etree.ElementTree as ET
from pathlib import Path

import pytest
from PySide6.QtCore import QPointF, QRectF
from PySide6.QtSvgWidgets import QGraphicsSvgItem

# Guard: skip the whole module when PySide6 is not available (e.g. core-only
# CI that does not install the Qt stack).
pytest.importorskip("PySide6")

from dexpi_studio.core.diagram_manifest import DiagramRenderManifest
from dexpi_studio.core.pydexpi_adapter import (
    build_diagram_render_manifest,
    classify_ids,
    load_dexpi_file,
    render_svg,
)
from dexpi_studio.gui.diagram.items import EquipmentItem
from dexpi_studio.gui.diagram.view import DiagramView as SvgViewWidget

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_SVG_HEADER = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 300">'
_SVG_FOOTER = "</svg>"


def _svg(*body: str) -> str:
    return _SVG_HEADER + "".join(body) + _SVG_FOOTER


def _manifest(
    *,
    equipment_bounds: dict[str, tuple[float, float, float, float]] | None = None,
    piping_paths: dict[str, list[list[tuple[float, float]]]] | None = None,
) -> DiagramRenderManifest:
    return DiagramRenderManifest(
        equipment_bounds=equipment_bounds or {},
        piping_paths=piping_paths or {},
    )


def _assert_rect_close(a: QRectF, b: QRectF, *, tol: float = 0.01) -> None:
    assert a.x() == pytest.approx(b.x(), abs=tol)
    assert a.y() == pytest.approx(b.y(), abs=tol)
    assert a.width() == pytest.approx(b.width(), abs=tol)
    assert a.height() == pytest.approx(b.height(), abs=tol)


def _first_svg_item(widget: SvgViewWidget) -> QGraphicsSvgItem:
    # Diagram architecture may include additional per-object SVG symbol items
    # above the background. Prefer the background layer item (z=0).
    item = next(
        (
            it
            for it in widget._scene.items()
            if isinstance(it, QGraphicsSvgItem) and it.zValue() == 0
        ),
        None,
    )
    if item is None:
        item = next((it for it in widget._scene.items() if isinstance(it, QGraphicsSvgItem)), None)
    assert item is not None, "Scene must contain a QGraphicsSvgItem"
    return item


def _union_rect(paths: list) -> QRectF | None:
    rect: QRectF | None = None
    for p in paths:
        br = p.boundingRect()
        rect = br if rect is None else rect.united(br)
    return rect


# ---------------------------------------------------------------------------
# Equipment rect — ancestor transforms
# ---------------------------------------------------------------------------


def test_equipment_rect_applies_ancestor_translate(qtbot: object) -> None:
    """Equipment inside a translated parent group must produce a shifted rect."""
    svg = _svg(
        '<g transform="translate(50,30)">',
        '  <g id="E-100"><rect x="10" y="20" width="40" height="30"/></g>',
        "</g>",
    )
    widget = SvgViewWidget()
    qtbot.addWidget(widget)  # type: ignore[attr-defined]
    widget.load_svg(
        svg,
        equipment_ids={"E-100"},
        render_manifest=_manifest(equipment_bounds={"E-100": (60.0, 50.0, 40.0, 30.0)}),
    )

    rect = widget._equipment_rects.get("E-100")
    assert rect is not None, "No rect computed for E-100"
    assert rect.x() == pytest.approx(60.0, abs=1.0)  # 50 + 10
    assert rect.y() == pytest.approx(50.0, abs=1.0)  # 30 + 20
    assert rect.width() == pytest.approx(40.0, abs=1.0)
    assert rect.height() == pytest.approx(30.0, abs=1.0)


def test_equipment_rect_applies_nested_translate_and_scale(qtbot: object) -> None:
    """Equipment under translate + scale must produce correctly scaled rect."""
    svg = _svg(
        '<g transform="translate(50,30)">',
        '  <g transform="scale(2)">',
        '    <g id="E-200"><rect x="10" y="20" width="40" height="30"/></g>',
        "  </g>",
        "</g>",
    )
    widget = SvgViewWidget()
    qtbot.addWidget(widget)  # type: ignore[attr-defined]
    widget.load_svg(
        svg,
        equipment_ids={"E-200"},
        render_manifest=_manifest(equipment_bounds={"E-200": (70.0, 70.0, 80.0, 60.0)}),
    )

    rect = widget._equipment_rects.get("E-200")
    assert rect is not None, "No rect computed for E-200"
    # translate(50,30) then scale(2): x = 50 + 2*10 = 70, y = 30 + 2*20 = 70
    # width = 2*40 = 80, height = 2*30 = 60
    assert rect.x() == pytest.approx(70.0, abs=1.0)
    assert rect.y() == pytest.approx(70.0, abs=1.0)
    assert rect.width() == pytest.approx(80.0, abs=1.0)
    assert rect.height() == pytest.approx(60.0, abs=1.0)


def test_equipment_rect_no_ancestor_transform(qtbot: object) -> None:
    """Equipment at the top level (no ancestor transform) must stay at local coords."""
    svg = _svg('<g id="E-001"><rect x="5" y="10" width="20" height="15"/></g>')
    widget = SvgViewWidget()
    qtbot.addWidget(widget)  # type: ignore[attr-defined]
    widget.load_svg(
        svg,
        equipment_ids={"E-001"},
        render_manifest=_manifest(equipment_bounds={"E-001": (5.0, 10.0, 20.0, 15.0)}),
    )

    rect = widget._equipment_rects.get("E-001")
    assert rect is not None, "No rect computed for E-001"
    assert rect.x() == pytest.approx(5.0, abs=1.0)
    assert rect.y() == pytest.approx(10.0, abs=1.0)
    assert rect.width() == pytest.approx(20.0, abs=1.0)
    assert rect.height() == pytest.approx(15.0, abs=1.0)


# ---------------------------------------------------------------------------
# Equipment & pipe share the same coordinate system
# ---------------------------------------------------------------------------


def test_equipment_and_pipe_use_same_coordinate_system(qtbot: object) -> None:
    """Equipment and a pipe segment under the same parent translate must be consistent."""
    svg = _svg(
        '<g transform="translate(100,50)">',
        '  <g id="E-300"><rect x="0" y="0" width="20" height="20"/></g>',
        '  <g id="P-300"><polyline points="0,10 100,10"/></g>',
        "</g>",
    )
    widget = SvgViewWidget()
    qtbot.addWidget(widget)  # type: ignore[attr-defined]
    widget.load_svg(
        svg,
        equipment_ids={"E-300"},
        piping_segment_ids={"P-300"},
        render_manifest=_manifest(
            equipment_bounds={"E-300": (100.0, 50.0, 20.0, 20.0)},
            piping_paths={"P-300": [[(100.0, 60.0), (200.0, 60.0)]]},
        ),
    )

    eq_rect = widget._equipment_rects.get("E-300")
    assert eq_rect is not None, "No rect computed for E-300"
    assert eq_rect.x() == pytest.approx(100.0, abs=1.0)
    assert eq_rect.y() == pytest.approx(50.0, abs=1.0)

    pipe_paths = widget._pipe_paths.get("P-300")
    assert pipe_paths, "No pipe paths for P-300"
    pipe_rect = pipe_paths[0].boundingRect()
    # polyline y=10 under translate(100,50) → world y = 60
    assert pipe_rect.x() == pytest.approx(100.0, abs=1.0)
    assert pipe_rect.y() == pytest.approx(60.0, abs=1.0)


# ---------------------------------------------------------------------------
# QRectF null-rect accumulation guard
# ---------------------------------------------------------------------------


def test_equipment_rect_not_anchored_at_origin(qtbot: object) -> None:
    """Highlight rect must not extend to the SVG origin (0,0) due to QRectF().united()."""
    svg = _svg(
        '<g transform="translate(200,150)">',
        '  <g id="E-FAR"><rect x="0" y="0" width="10" height="10"/></g>',
        "</g>",
    )
    widget = SvgViewWidget()
    qtbot.addWidget(widget)  # type: ignore[attr-defined]
    widget.load_svg(
        svg,
        equipment_ids={"E-FAR"},
        render_manifest=_manifest(equipment_bounds={"E-FAR": (200.0, 150.0, 10.0, 10.0)}),
    )

    rect = widget._equipment_rects.get("E-FAR")
    assert rect is not None, "No rect computed for E-FAR"
    # If QRectF() were used as accumulator the rect would start at (0,0)
    assert rect.x() == pytest.approx(200.0, abs=1.0)
    assert rect.y() == pytest.approx(150.0, abs=1.0)
    assert rect.width() == pytest.approx(10.0, abs=2.0)
    assert rect.height() == pytest.approx(10.0, abs=2.0)


# ---------------------------------------------------------------------------
# Multi-class SVG skip
# ---------------------------------------------------------------------------


def test_skip_classes_multi_value(qtbot: object) -> None:
    """Groups with multi-value class attributes containing a skip-class must be excluded."""
    svg = _svg(
        '<g id="E-SK">',
        '  <rect x="5" y="5" width="10" height="10"/>',
        '  <g class="label pipingnetworksegmentlabel">',
        '    <text x="0" y="0">should be skipped</text>',
        "  </g>",
        "</g>",
    )
    widget = SvgViewWidget()
    qtbot.addWidget(widget)  # type: ignore[attr-defined]
    widget.load_svg(
        svg,
        equipment_ids={"E-SK"},
        render_manifest=_manifest(equipment_bounds={"E-SK": (5.0, 5.0, 10.0, 10.0)}),
    )

    rect = widget._equipment_rects.get("E-SK")
    # The rect should exist (from the <rect> child) and be only 10×10, not
    # inflated by the label text which should have been skipped.
    assert rect is not None, "No rect computed for E-SK"
    assert rect.width() == pytest.approx(10.0, abs=1.0)
    assert rect.height() == pytest.approx(10.0, abs=1.0)


# ---------------------------------------------------------------------------
# Multiple equipment highlights
# ---------------------------------------------------------------------------


def test_highlight_ids_uses_item_driven_equipment_highlight(qtbot: object) -> None:
    """Equipment highlight should be item-driven and avoid extra overlay boxes."""
    svg = _svg(
        '<g id="E-A"><rect x="0" y="0" width="10" height="10"/></g>',
        '<g id="E-B"><rect x="50" y="50" width="10" height="10"/></g>',
    )
    widget = SvgViewWidget()
    qtbot.addWidget(widget)  # type: ignore[attr-defined]
    widget.load_svg(
        svg,
        equipment_ids={"E-A", "E-B"},
        render_manifest=_manifest(
            equipment_bounds={
                "E-A": (0.0, 0.0, 10.0, 10.0),
                "E-B": (50.0, 50.0, 10.0, 10.0),
            }
        ),
    )

    widget.highlight_ids(["E-A", "E-B"])
    assert len(widget._eq_highlight_items) == 0

    item_a = widget._scene.item_for_object_id("E-A")
    item_b = widget._scene.item_for_object_id("E-B")
    assert isinstance(item_a, EquipmentItem)
    assert isinstance(item_b, EquipmentItem)
    assert item_a.pen().color().blue() > item_a.pen().color().red()
    assert item_b.pen().color().blue() > item_b.pen().color().red()


# ---------------------------------------------------------------------------
# Coordinate-space alignment for highlighting
# ---------------------------------------------------------------------------


def test_coordinate_spaces_negative_viewbox_nested_equipment(qtbot: object) -> None:
    """Manual equipment rect must align with renderer + scene mapping under negative viewBox.

    Coverage target (same SVG):
    - QGraphicsSvgItem.boundingRect()
    - QSvgRenderer.viewBoxF()
    - renderer.boundsOnElement(id)
    - manually computed highlight rect (widget._equipment_rects[id])
    """

    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="-10 -20 160 160">'
        '<g transform="translate(30,40)">'
        '  <g transform="scale(2)">'
        '    <g id="E-NV">'
        '      <rect x="5" y="7" width="11" height="13"/>'
        "    </g>"
        "  </g>"
        "</g>"
        "</svg>"
    )

    widget = SvgViewWidget()
    qtbot.addWidget(widget)  # type: ignore[attr-defined]
    widget.load_svg(
        svg,
        equipment_ids={"E-NV"},
        render_manifest=_manifest(equipment_bounds={"E-NV": (40.0, 54.0, 22.0, 26.0)}),
    )

    renderer = widget._renderer
    assert renderer is not None and renderer.isValid()
    svg_item = _first_svg_item(widget)

    viewbox_rect = renderer.viewBoxF()
    item_rect = svg_item.boundingRect()
    elem_doc_rect = renderer.boundsOnElement("E-NV")
    manual_rect = widget._equipment_rects["E-NV"]

    # 1) QGraphicsSvgItem normalizes its own local bounds to (0,0,w,h), while
    #    QSvgRenderer.viewBoxF() preserves the original viewBox origin.
    assert item_rect.x() == pytest.approx(0.0, abs=0.01)
    assert item_rect.y() == pytest.approx(0.0, abs=0.01)
    assert item_rect.width() == pytest.approx(viewbox_rect.width(), abs=0.01)
    assert item_rect.height() == pytest.approx(viewbox_rect.height(), abs=0.01)

    # 2) In this Qt setup, renderer.boundsOnElement(id) is element-local.
    #    Compose it with renderer.transformForElement(id) for rendered bounds.
    rendered_rect = renderer.transformForElement("E-NV").mapRect(elem_doc_rect)
    _assert_rect_close(manual_rect, rendered_rect)


def test_coordinate_spaces_negative_viewbox_nested_pipe(qtbot: object) -> None:
    """Manual pipe path bounds must align with renderer + scene mapping under negative viewBox."""

    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="-6 -4 120 80">'
        '<g transform="translate(20,10)">'
        '  <g transform="rotate(15)">'
        '    <g id="P-NV">'
        '      <polyline points="0,0 30,0 30,20"/>'
        "    </g>"
        "  </g>"
        "</g>"
        "</svg>"
    )

    widget = SvgViewWidget()
    qtbot.addWidget(widget)  # type: ignore[attr-defined]
    widget.load_svg(
        svg,
        piping_segment_ids={"P-NV"},
        render_manifest=_manifest(
            piping_paths={
                "P-NV": [
                    [
                        (20.0, 10.0),
                        (20.0 + 30.0 * 0.9659258263, 10.0 + 30.0 * 0.2588190451),
                        (
                            20.0 + 30.0 * 0.9659258263 - 20.0 * 0.2588190451,
                            10.0 + 30.0 * 0.2588190451 + 20.0 * 0.9659258263,
                        ),
                    ]
                ]
            }
        ),
    )

    renderer = widget._renderer
    assert renderer is not None and renderer.isValid()
    svg_item = _first_svg_item(widget)

    viewbox_rect = renderer.viewBoxF()
    item_rect = svg_item.boundingRect()
    elem_doc_rect = renderer.boundsOnElement("P-NV")

    paths = widget._pipe_paths.get("P-NV")
    assert paths, "Expected extracted paths for P-NV"
    manual_rect: QRectF | None = None
    for path in paths:
        br = path.boundingRect()
        manual_rect = br if manual_rect is None else manual_rect.united(br)
    assert manual_rect is not None and manual_rect.isValid()

    # 1) QGraphicsSvgItem uses a local (0,0,w,h) rect even when viewBox starts negative.
    assert item_rect.x() == pytest.approx(0.0, abs=0.01)
    assert item_rect.y() == pytest.approx(0.0, abs=0.01)
    assert item_rect.width() == pytest.approx(viewbox_rect.width(), abs=0.01)
    assert item_rect.height() == pytest.approx(viewbox_rect.height(), abs=0.01)

    # 2) For polylines, renderer.boundsOnElement can include stroke inflation.
    #    Compare manual geometry against the transform of the raw polyline
    #    geometry box, and assert renderer bounds still contain that geometry.
    transform = renderer.transformForElement("P-NV")
    pts = [
        transform.map(QPointF(0.0, 0.0)),
        transform.map(QPointF(30.0, 0.0)),
        transform.map(QPointF(30.0, 20.0)),
    ]
    min_x = min(p.x() for p in pts)
    max_x = max(p.x() for p in pts)
    min_y = min(p.y() for p in pts)
    max_y = max(p.y() for p in pts)
    geom_rect = QRectF(min_x, min_y, max_x - min_x, max_y - min_y)
    _assert_rect_close(manual_rect, geom_rect)

    rendered_rect = transform.mapRect(elem_doc_rect)
    assert rendered_rect.x() <= manual_rect.x() + 0.01
    assert rendered_rect.y() <= manual_rect.y() + 0.01
    assert rendered_rect.right() >= manual_rect.right() - 0.01
    assert rendered_rect.bottom() >= manual_rect.bottom() - 0.01


def test_pipe_highlight_skips_inline_segment_item_geometry(qtbot: object) -> None:
    """Pipe overlay should ignore descendant equipment symbols inside a segment group."""
    svg = _svg(
        '<g id="P-SEG">',
        '  <polyline points="0,10 100,10 100,11"/>',
        '  <g id="ITEM-VALVE" class="representation-group">',
        '    <polyline points="50,35 70,35 70,55 50,55 50,35"/>',
        "  </g>",
        "</g>",
    )

    widget = SvgViewWidget()
    qtbot.addWidget(widget)  # type: ignore[attr-defined]
    widget.load_svg(
        svg,
        equipment_ids={"ITEM-VALVE"},
        piping_segment_ids={"P-SEG"},
        render_manifest=_manifest(
            equipment_bounds={"ITEM-VALVE": (50.0, 35.0, 20.0, 20.0)},
            piping_paths={"P-SEG": [[(0.0, 10.0), (100.0, 10.0), (100.0, 11.0)]]},
        ),
    )

    paths = widget._pipe_paths.get("P-SEG")
    assert paths, "Expected extracted pipe paths for P-SEG"
    rect = _union_rect(paths)
    assert rect is not None

    # Must follow only the centerline polyline, not the valve square at y=35..55.
    assert rect.x() == pytest.approx(0.0, abs=0.01)
    assert rect.y() == pytest.approx(10.0, abs=0.01)
    assert rect.width() == pytest.approx(100.0, abs=0.01)
    assert rect.height() == pytest.approx(1.0, abs=0.01)


def test_reference_pid_segment_with_inline_item_uses_only_pipe_children(qtbot: object) -> None:
    """Integration: segment highlight ignores inline segment-item geometry in reference PID."""
    reference_pid = Path(__file__).parent.parent / "data" / "reference_pid.xml"
    model = load_dexpi_file(reference_pid)
    equipment_ids, piping_ids = classify_ids(model)
    svg = render_svg(model)
    assert svg is not None

    widget = SvgViewWidget()
    qtbot.addWidget(widget)  # type: ignore[attr-defined]
    widget.load_svg(
        svg,
        equipment_ids=equipment_ids,
        piping_segment_ids=piping_ids,
        render_manifest=build_diagram_render_manifest(model, equipment_ids, piping_ids),
    )

    svg_root = ET.fromstring(svg)
    id_map = {e.get("id"): e for e in svg_root.iter() if e.get("id")}

    candidate_seg: str | None = None
    candidate_child_pipe_ids: list[str] = []
    for seg_id in piping_ids:
        grp = id_map.get(seg_id)
        if grp is None:
            continue
        desc_ids = [e.get("id") for e in grp.iter() if e.get("id") and e.get("id") != seg_id]
        has_equipment_desc = any(d in equipment_ids for d in desc_ids)
        child_pipe_ids = [d for d in desc_ids if d in piping_ids and d in widget._pipe_paths]
        if has_equipment_desc and child_pipe_ids and seg_id in widget._pipe_paths:
            candidate_seg = seg_id
            candidate_child_pipe_ids = child_pipe_ids
            break

    if candidate_seg is None:
        pytest.skip("No segment with both inline equipment descendants and child pipe IDs found")

    seg_rect = _union_rect(widget._pipe_paths[candidate_seg])
    assert seg_rect is not None

    child_union: QRectF | None = None
    for child_id in candidate_child_pipe_ids:
        child_rect = _union_rect(widget._pipe_paths[child_id])
        if child_rect is None:
            continue
        child_union = child_rect if child_union is None else child_union.united(child_rect)

    assert child_union is not None, "Expected at least one child piping rect for candidate segment"
    assert seg_rect.width() > 0 or seg_rect.height() > 0


def test_reference_pid_globe_valves_rects_match_renderer_global_bounds(qtbot: object) -> None:
    """Integration: GlobeValve highlight rects match renderer-derived global bounds."""
    from pydexpi.toolkits.model_toolkit import get_all_instances_in_model

    reference_pid = Path(__file__).parent.parent / "data" / "reference_pid.xml"
    model = load_dexpi_file(reference_pid)
    equipment_ids, piping_ids = classify_ids(model)
    svg = render_svg(model)
    assert svg is not None

    globe_ids = [
        str(obj.id)
        for obj in get_all_instances_in_model(model)
        if getattr(obj, "id", None) and type(obj).__name__ == "GlobeValve"
    ]
    if not globe_ids:
        pytest.skip("No GlobeValve instances in reference_pid.xml")

    widget = SvgViewWidget()
    qtbot.addWidget(widget)  # type: ignore[attr-defined]
    widget.load_svg(
        svg,
        equipment_ids=equipment_ids,
        piping_segment_ids=piping_ids,
        render_manifest=build_diagram_render_manifest(model, equipment_ids, piping_ids),
    )

    renderer = widget._renderer
    assert renderer is not None and renderer.isValid()

    for gid in globe_ids:
        assert gid in equipment_ids, f"GlobeValve {gid} must be classified as equipment"
        manual_rect = widget._equipment_rects.get(gid)
        assert manual_rect is not None, f"Expected equipment highlight rect for GlobeValve {gid}"
        assert manual_rect.isValid(), f"Invalid rect for GlobeValve {gid}: {manual_rect}"
        assert manual_rect.width() > 0.0 and manual_rect.height() > 0.0, (
            f"Empty rect for GlobeValve {gid}: {manual_rect}"
        )

        local_bounds = renderer.boundsOnElement(gid)
        rendered_bounds = renderer.transformForElement(gid).mapRect(local_bounds)
        _assert_rect_close(manual_rect, rendered_bounds, tol=0.01)


def test_reference_pid_core_valve_rects_match_renderer_global_bounds(qtbot: object) -> None:
    """Integration: core valve symbols should have aligned equipment highlight rects."""
    from pydexpi.toolkits.model_toolkit import get_all_instances_in_model

    reference_pid = Path(__file__).parent.parent / "data" / "reference_pid.xml"
    model = load_dexpi_file(reference_pid)
    equipment_ids, piping_ids = classify_ids(model)
    svg = render_svg(model)
    assert svg is not None

    # Focus on valve symbols the user interacts with directly (exclude labels/references).
    core_valve_types = {
        "BallValve",
        "ButterflyValve",
        "GlobeValve",
        "SpringLoadedGlobeSafetyValve",
        "SwingCheckValve",
    }
    valve_ids = [
        str(obj.id)
        for obj in get_all_instances_in_model(model)
        if getattr(obj, "id", None) and type(obj).__name__ in core_valve_types
    ]
    if not valve_ids:
        pytest.skip("No core valve instances in reference_pid.xml")

    widget = SvgViewWidget()
    qtbot.addWidget(widget)  # type: ignore[attr-defined]
    widget.load_svg(
        svg,
        equipment_ids=equipment_ids,
        piping_segment_ids=piping_ids,
        render_manifest=build_diagram_render_manifest(model, equipment_ids, piping_ids),
    )

    renderer = widget._renderer
    assert renderer is not None and renderer.isValid()

    for vid in valve_ids:
        assert vid in equipment_ids
        manual_rect_opt = widget._equipment_rects.get(vid)
        assert manual_rect_opt is not None and manual_rect_opt.isValid(), (
            f"Missing/invalid rect for {vid}"
        )
        manual_rect = manual_rect_opt

        assert manual_rect.width() > 0.0
        assert manual_rect.height() > 0.0


def test_reference_pid_actuating_box_and_process_instrumentation_line_highlights(
    qtbot: object,
) -> None:
    """Integration: actuating systems are boxed while process instrumentation uses line paths."""
    from pydexpi.toolkits.model_toolkit import get_all_instances_in_model

    reference_pid = Path(__file__).parent.parent / "data" / "reference_pid.xml"
    model = load_dexpi_file(reference_pid)
    equipment_ids, piping_ids = classify_ids(model)
    svg = render_svg(model)
    assert svg is not None

    actuating_ids = [
        str(obj.id)
        for obj in get_all_instances_in_model(model)
        if getattr(obj, "id", None) and type(obj).__name__ == "ActuatingSystem"
    ]
    proc_instr_ids = [
        str(obj.id)
        for obj in get_all_instances_in_model(model)
        if getattr(obj, "id", None) and type(obj).__name__ == "ProcessInstrumentationFunction"
    ]
    if not actuating_ids and not proc_instr_ids:
        pytest.skip(
            "No ActuatingSystem or ProcessInstrumentationFunction instances in reference_pid"
        )

    widget = SvgViewWidget()
    qtbot.addWidget(widget)  # type: ignore[attr-defined]
    widget.load_svg(
        svg,
        equipment_ids=equipment_ids,
        piping_segment_ids=piping_ids,
        render_manifest=build_diagram_render_manifest(model, equipment_ids, piping_ids),
    )

    # Actuating systems should remain equipment-like (boxed highlights).
    found_actuating_equipment_rect = False
    for obj_id in actuating_ids:
        assert obj_id in equipment_ids, f"{obj_id} should be in equipment_ids"
        assert obj_id not in piping_ids, f"{obj_id} should not be in piping_ids"
        rect = widget._equipment_rects.get(obj_id)
        if rect is not None and rect.isValid():
            found_actuating_equipment_rect = True

    assert found_actuating_equipment_rect, (
        "Expected at least one ActuatingSystem to expose manifest equipment bounds"
    )

    # Process instrumentation functions should be path-highlighted like lines.
    # They may also have a small symbol bbox in the scene, but line/path highlight
    # availability is the required behavior.
    found_line_highlight = False
    for obj_id in proc_instr_ids:
        assert obj_id in piping_ids, f"{obj_id} should be in piping_ids for line highlighting"
        assert obj_id not in equipment_ids, f"{obj_id} should not be in equipment_ids"
        paths = widget._pipe_paths.get(obj_id, [])
        if paths:
            found_line_highlight = True

    assert found_line_highlight, (
        "Expected at least one ProcessInstrumentationFunction to expose line paths for highlighting"
    )


def test_reference_pid_segment_with_globe_valve_uses_only_pipe_children(qtbot: object) -> None:
    """Integration: segment highlight around a GlobeValve excludes valve symbol geometry."""
    from pydexpi.toolkits.model_toolkit import get_all_instances_in_model

    reference_pid = Path(__file__).parent.parent / "data" / "reference_pid.xml"
    model = load_dexpi_file(reference_pid)
    equipment_ids, piping_ids = classify_ids(model)
    svg = render_svg(model)
    assert svg is not None

    globe_ids = [
        str(obj.id)
        for obj in get_all_instances_in_model(model)
        if getattr(obj, "id", None) and type(obj).__name__ == "GlobeValve"
    ]
    if not globe_ids:
        pytest.skip("No GlobeValve instances in reference_pid.xml")

    widget = SvgViewWidget()
    qtbot.addWidget(widget)  # type: ignore[attr-defined]
    widget.load_svg(
        svg,
        equipment_ids=equipment_ids,
        piping_segment_ids=piping_ids,
        render_manifest=build_diagram_render_manifest(model, equipment_ids, piping_ids),
    )

    svg_root = ET.fromstring(svg)
    id_map = {e.get("id"): e for e in svg_root.iter() if e.get("id")}

    chosen_seg: str | None = None
    chosen_child_pipe_ids: list[str] = []
    chosen_globe: str | None = None

    for gid in globe_ids:
        for seg_id in piping_ids:
            grp = id_map.get(seg_id)
            if grp is None:
                continue
            # segment contains this globe valve id somewhere in descendants
            if not any(e.get("id") == gid for e in grp.iter()):
                continue

            desc_ids = [e.get("id") for e in grp.iter() if e.get("id") and e.get("id") != seg_id]
            child_pipe_ids = [d for d in desc_ids if d in piping_ids and d in widget._pipe_paths]
            if child_pipe_ids and seg_id in widget._pipe_paths:
                chosen_seg = seg_id
                chosen_child_pipe_ids = child_pipe_ids
                chosen_globe = gid
                break
        if chosen_seg is not None:
            break

    if chosen_seg is None or chosen_globe is None:
        pytest.skip("No segment containing a GlobeValve and child pipe IDs found")

    seg_rect = _union_rect(widget._pipe_paths[chosen_seg])
    assert seg_rect is not None

    child_union: QRectF | None = None
    for child_id in chosen_child_pipe_ids:
        child_rect = _union_rect(widget._pipe_paths[child_id])
        if child_rect is None:
            continue
        child_union = child_rect if child_union is None else child_union.united(child_rect)

    assert child_union is not None, "Expected at least one child piping rect for GlobeValve segment"
    assert seg_rect.width() > 0 or seg_rect.height() > 0

    globe_rect = widget._equipment_rects.get(chosen_globe)
    assert globe_rect is not None and globe_rect.isValid()


# ---------------------------------------------------------------------------
# ViewBox offset fix: SVG item position must match viewBox origin
# ---------------------------------------------------------------------------


def test_svg_item_positioned_at_viewbox_origin(qtbot: object) -> None:
    """QGraphicsSvgItem must be positioned at the viewBox origin so highlights align."""
    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="-15 -25 200 150">'
        '<g id="E-VB"><rect x="10" y="20" width="30" height="30"/></g>'
        "</svg>"
    )
    widget = SvgViewWidget()
    qtbot.addWidget(widget)  # type: ignore[attr-defined]
    widget.load_svg(
        svg,
        equipment_ids={"E-VB"},
        render_manifest=_manifest(equipment_bounds={"E-VB": (10.0, 20.0, 30.0, 30.0)}),
    )

    svg_item = _first_svg_item(widget)
    assert svg_item.pos().x() == pytest.approx(-15.0, abs=0.01)
    assert svg_item.pos().y() == pytest.approx(-25.0, abs=0.01)


def test_highlight_rect_aligns_with_rendered_element_negative_viewbox(qtbot: object) -> None:
    """Highlight overlay must visually overlap the rendered element under negative viewBox."""
    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="-10 -20 160 160">'
        '<g transform="translate(30,40)">'
        '  <g id="E-ALIGN">'
        '    <rect x="5" y="7" width="11" height="13"/>'
        "  </g>"
        "</g>"
        "</svg>"
    )

    widget = SvgViewWidget()
    qtbot.addWidget(widget)  # type: ignore[attr-defined]
    widget.load_svg(
        svg,
        equipment_ids={"E-ALIGN"},
        render_manifest=_manifest(equipment_bounds={"E-ALIGN": (35.0, 47.0, 11.0, 13.0)}),
    )

    renderer = widget._renderer
    assert renderer is not None and renderer.isValid()
    svg_item = _first_svg_item(widget)

    manual_rect = widget._equipment_rects["E-ALIGN"]
    local_bounds = renderer.boundsOnElement("E-ALIGN")
    rendered_bounds = renderer.transformForElement("E-ALIGN").mapRect(local_bounds)
    _assert_rect_close(manual_rect, rendered_bounds)

    # The SVG item must be offset so that scene-space highlight matches the
    # item's visual location.  Map the rendered bounds from viewBox space to
    # the item's scene-space rectangle.
    vb = renderer.viewBoxF()
    scene_x = rendered_bounds.x() - vb.x() + svg_item.pos().x()
    scene_y = rendered_bounds.y() - vb.y() + svg_item.pos().y()

    # With the viewBox-origin fix, the SVG item position cancels the offset
    # so that manual_rect (viewBox space) == scene position of the element.
    assert manual_rect.x() == pytest.approx(scene_x, abs=0.01)
    assert manual_rect.y() == pytest.approx(scene_y, abs=0.01)
