"""Tests for DiagramView/DiagramScene architecture."""

from __future__ import annotations

import pytest
from PySide6.QtCore import QPoint, QRectF, Qt
from PySide6.QtSvgWidgets import QGraphicsSvgItem
from PySide6.QtWidgets import QGraphicsPathItem, QGraphicsRectItem, QGraphicsSimpleTextItem

pytest.importorskip("PySide6")

from dexpi_studio.core.diagram_manifest import DiagramRenderManifest, DiagramTextLabel
from dexpi_studio.gui.diagram import DiagramScene, DiagramView
from dexpi_studio.gui.diagram.items import EquipmentItem, PipeItem


def _svg(*body: str) -> str:
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="-10 -20 200 150">'
        + "".join(body)
        + "</svg>"
    )


def _manifest(
    *,
    equipment_bounds: dict[str, tuple[float, float, float, float]] | None = None,
    equipment_paths: dict[str, list[list[tuple[float, float]]]] | None = None,
    equipment_colors: dict[str, tuple[int, int, int, int]] | None = None,
    equipment_dash_patterns: dict[str, list[float]] | None = None,
    equipment_stroke_widths: dict[str, float] | None = None,
    piping_paths: dict[str, list[list[tuple[float, float]]]] | None = None,
    pipe_colors: dict[str, tuple[int, int, int, int]] | None = None,
    pipe_dash_patterns: dict[str, list[float]] | None = None,
    pipe_stroke_widths: dict[str, float] | None = None,
    text_labels: list[DiagramTextLabel] | None = None,
) -> DiagramRenderManifest:
    return DiagramRenderManifest(
        equipment_bounds=equipment_bounds or {},
        equipment_paths=equipment_paths or {},
        equipment_colors=equipment_colors or {},
        equipment_dash_patterns=equipment_dash_patterns or {},
        equipment_stroke_widths=equipment_stroke_widths or {},
        piping_paths=piping_paths or {},
        pipe_colors=pipe_colors or {},
        pipe_dash_patterns=pipe_dash_patterns or {},
        pipe_stroke_widths=pipe_stroke_widths or {},
        text_labels=text_labels or [],
    )


def test_imports_and_compatibility_alias() -> None:
    """Diagram module is importable with scene/view types available."""
    assert DiagramView is not None
    assert DiagramScene is not None


def test_load_svg_creates_background_and_object_items(qtbot: object) -> None:
    svg = _svg(
        '<g id="E-1"><rect x="10" y="20" width="30" height="20"/></g>',
        '<g id="P-1"><polyline points="0,10 100,10"/></g>',
    )
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(
        svg,
        equipment_ids={"E-1"},
        piping_segment_ids={"P-1"},
        render_manifest=_manifest(
            equipment_bounds={"E-1": (10.0, 20.0, 30.0, 20.0)},
            piping_paths={"P-1": [[(0.0, 10.0), (100.0, 10.0)]]},
            pipe_colors={"P-1": (128, 128, 0, 210)},
            pipe_stroke_widths={"P-1": 1.35},
        ),
    )

    assert any(isinstance(it, QGraphicsSvgItem) for it in view._scene.items())
    assert view._scene.item_for_object_id("E-1") is not None
    assert view._scene.item_for_object_id("P-1") is not None
    assert isinstance(view._scene.item_for_object_id("E-1"), EquipmentItem)
    # Keep path-derived piping interaction item as first choice where available.
    pipe_item = view._scene.item_for_object_id("P-1")
    assert isinstance(pipe_item, PipeItem)
    # Default (non-selected) pipe stroke should remain visible.
    assert pipe_item.pen().color().alpha() >= 120
    assert not pipe_item.pen().isCosmetic()
    # Keep base pipe color aligned with yellow SVG process lines (not blue).
    c = pipe_item.pen().color()
    assert c.red() > c.blue()
    assert c.green() > c.blue()


def test_pipe_uses_exact_svg_stroke_color(qtbot: object) -> None:
    svg = _svg('<g id="P-C"><polyline points="0,10 100,10" style="stroke:rgb(128,128,0);"/></g>')
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(
        svg,
        piping_segment_ids={"P-C"},
        render_manifest=_manifest(
            piping_paths={"P-C": [[(0.0, 10.0), (100.0, 10.0)]]},
            pipe_colors={"P-C": (128, 128, 0, 255)},
            pipe_stroke_widths={"P-C": 1.35},
        ),
    )

    pipe_item = view._scene.item_for_object_id("P-C")
    assert isinstance(pipe_item, PipeItem)
    c = pipe_item.pen().color()
    assert (c.red(), c.green(), c.blue()) == (128, 128, 0)


def test_equipment_prefers_manifest_paths_over_large_bounds(qtbot: object) -> None:
    svg = _svg('<g id="E-PATH"><rect x="0" y="0" width="200" height="200"/></g>')
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(
        svg,
        equipment_ids={"E-PATH"},
        render_manifest=_manifest(
            equipment_bounds={"E-PATH": (0.0, 0.0, 200.0, 200.0)},
            equipment_paths={
                "E-PATH": [[(10.0, 10.0), (30.0, 10.0), (30.0, 22.0), (10.0, 22.0), (10.0, 10.0)]]
            },
        ),
    )

    item = view._scene.item_for_object_id("E-PATH")
    assert isinstance(item, EquipmentItem)
    br = item.path().boundingRect()
    assert br.x() == pytest.approx(10.0, abs=0.01)
    assert br.y() == pytest.approx(10.0, abs=0.01)
    assert br.width() == pytest.approx(20.0, abs=0.01)
    assert br.height() == pytest.approx(12.0, abs=0.01)


def test_equipment_uses_manifest_stroke_color_and_width(qtbot: object) -> None:
    svg = _svg('<g id="E-STROKE"><rect x="0" y="0" width="10" height="8"/></g>')
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(
        svg,
        equipment_ids={"E-STROKE"},
        render_manifest=_manifest(
            equipment_bounds={"E-STROKE": (0.0, 0.0, 10.0, 8.0)},
            equipment_colors={"E-STROKE": (220, 40, 60, 255)},
            equipment_stroke_widths={"E-STROKE": 2.75},
        ),
    )

    item = view._scene.item_for_object_id("E-STROKE")
    assert isinstance(item, EquipmentItem)
    c = item.pen().color()
    assert (c.red(), c.green(), c.blue()) == (220, 40, 60)
    assert item.pen().widthF() == pytest.approx(2.75, abs=0.01)


def test_pipe_renders_line_tag_text_item(qtbot: object) -> None:
    svg = _svg(
        '<g id="P-TAG">'
        '<polyline points="0,10 100,10" style="stroke:#008000;"/>'
        '<text x="15" y="12" fill="#111111">MNc 77127 75HB13 50 Q 80</text>'
        "</g>"
    )
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(
        svg,
        piping_segment_ids={"P-TAG"},
        render_manifest=_manifest(
            piping_paths={"P-TAG": [[(0.0, 10.0), (100.0, 10.0)]]},
            text_labels=[
                DiagramTextLabel(
                    text="MNc 77127 75HB13 50 Q 80",
                    x=15.0,
                    y=12.0,
                    color=(17, 17, 17, 255),
                    size=0.6,
                    anchor="start",
                    baseline="alphabetic",
                    rotation_deg=0.0,
                )
            ],
        ),
    )

    items = view._scene.items_for_object_id("__svg_text__")
    tag_items = [
        it
        for it in items
        if isinstance(it, QGraphicsSimpleTextItem)
        and it.text().strip() == "MNc 77127 75HB13 50 Q 80"
    ]
    assert tag_items, "Expected line tag text item to be rendered for piping object"


def test_global_svg_text_is_rendered_even_outside_piping_ids(qtbot: object) -> None:
    svg = _svg(
        '<g id="P-TAG">'
        '<polyline points="0,10 100,10" style="stroke:#008000;"/>'
        "</g>"
        '<g class="label"><text x="40" y="30">GLOBAL LABEL</text></g>'
    )
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(
        svg,
        piping_segment_ids={"P-TAG"},
        render_manifest=_manifest(
            piping_paths={"P-TAG": [[(0.0, 10.0), (100.0, 10.0)]]},
            text_labels=[
                DiagramTextLabel(
                    text="GLOBAL LABEL",
                    x=40.0,
                    y=30.0,
                    color=(20, 20, 20, 220),
                    size=0.6,
                    anchor="start",
                    baseline="alphabetic",
                    rotation_deg=0.0,
                )
            ],
        ),
    )

    global_items = view._scene.items_for_object_id("__svg_text__")
    assert any(
        isinstance(it, QGraphicsSimpleTextItem) and it.text().strip() == "GLOBAL LABEL"
        for it in global_items
    )


def test_global_svg_text_rotation_is_applied(qtbot: object) -> None:
    svg = _svg(
        '<g id="P-TAG">'
        '<polyline points="0,10 100,10" style="stroke:#008000;"/>'
        "</g>"
        '<text x="60" y="40" transform="rotate(90 60 40)">ROTATED LABEL</text>'
    )
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(
        svg,
        piping_segment_ids={"P-TAG"},
        render_manifest=_manifest(
            piping_paths={"P-TAG": [[(0.0, 10.0), (100.0, 10.0)]]},
            text_labels=[
                DiagramTextLabel(
                    text="ROTATED LABEL",
                    x=60.0,
                    y=40.0,
                    color=(20, 20, 20, 220),
                    size=0.6,
                    anchor="start",
                    baseline="alphabetic",
                    rotation_deg=90.0,
                )
            ],
        ),
    )

    global_items = view._scene.items_for_object_id("__svg_text__")
    rotated_items = [
        it
        for it in global_items
        if isinstance(it, QGraphicsSimpleTextItem) and it.text().strip() == "ROTATED LABEL"
    ]
    assert rotated_items
    assert rotated_items[0].rotation() == pytest.approx(90.0, abs=0.25)


def test_pipe_uses_svg_stroke_dash_pattern_and_color(qtbot: object) -> None:
    svg = _svg(
        '<g id="P-DASH"><polyline points="0,10 100,10" '
        'style="stroke:#ff0066;stroke-dasharray:6,3;"/></g>'
    )
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(
        svg,
        piping_segment_ids={"P-DASH"},
        render_manifest=_manifest(
            piping_paths={"P-DASH": [[(0.0, 10.0), (100.0, 10.0)]]},
            pipe_colors={"P-DASH": (255, 0, 102, 255)},
            pipe_dash_patterns={"P-DASH": [6.0, 3.0]},
            pipe_stroke_widths={"P-DASH": 1.35},
        ),
    )

    pipe_item = view._scene.item_for_object_id("P-DASH")
    assert isinstance(pipe_item, PipeItem)
    pen = pipe_item.pen()

    assert pen.style() == Qt.PenStyle.CustomDashLine
    assert not pen.isCosmetic()
    dash = [float(x) for x in pen.dashPattern()]
    assert len(dash) >= 2
    assert dash[0] * pen.widthF() == pytest.approx(6.0, abs=0.01)
    assert dash[1] * pen.widthF() == pytest.approx(3.0, abs=0.01)

    c = pen.color()
    assert (c.red(), c.green(), c.blue()) == (255, 0, 102)


def test_pipe_uses_inherited_group_dash_pattern(qtbot: object) -> None:
    svg = _svg(
        '<g id="P-DASH-INHERIT" style="stroke-dasharray:5,2;">'
        '<polyline points="0,10 100,10" style="stroke:#00aa88;"/>'
        "</g>"
    )
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(
        svg,
        piping_segment_ids={"P-DASH-INHERIT"},
        render_manifest=_manifest(
            piping_paths={"P-DASH-INHERIT": [[(0.0, 10.0), (100.0, 10.0)]]},
            pipe_dash_patterns={"P-DASH-INHERIT": [5.0, 2.0]},
            pipe_stroke_widths={"P-DASH-INHERIT": 1.35},
        ),
    )

    pipe_item = view._scene.item_for_object_id("P-DASH-INHERIT")
    assert isinstance(pipe_item, PipeItem)
    pen = pipe_item.pen()
    dash = [float(x) for x in pen.dashPattern()]
    assert len(dash) >= 2
    assert dash[0] * pen.widthF() == pytest.approx(5.0, abs=0.01)
    assert dash[1] * pen.widthF() == pytest.approx(2.0, abs=0.01)


def test_pipe_uses_css_class_dash_pattern(qtbot: object) -> None:
    svg = _svg(
        "<style>.sig{stroke-dasharray:7,3;}</style>",
        '<g id="P-DASH-CSS" class="sig">',
        '<polyline points="0,10 100,10" style="stroke:#3366cc;"/>',
        "</g>",
    )
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(
        svg,
        piping_segment_ids={"P-DASH-CSS"},
        render_manifest=_manifest(
            piping_paths={"P-DASH-CSS": [[(0.0, 10.0), (100.0, 10.0)]]},
            pipe_dash_patterns={"P-DASH-CSS": [7.0, 3.0]},
            pipe_stroke_widths={"P-DASH-CSS": 1.35},
        ),
    )

    pipe_item = view._scene.item_for_object_id("P-DASH-CSS")
    assert isinstance(pipe_item, PipeItem)
    pen = pipe_item.pen()
    dash = [float(x) for x in pen.dashPattern()]
    assert len(dash) >= 2
    assert dash[0] * pen.widthF() == pytest.approx(7.0, abs=0.01)
    assert dash[1] * pen.widthF() == pytest.approx(3.0, abs=0.01)


def test_pipe_uses_css_id_dash_pattern(qtbot: object) -> None:
    svg = _svg(
        "<style>#P-DASH-ID{stroke-dasharray:9,4;}</style>",
        '<g id="P-DASH-ID">',
        '<polyline points="0,10 100,10" style="stroke:#2244aa;"/>',
        "</g>",
    )
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(
        svg,
        piping_segment_ids={"P-DASH-ID"},
        render_manifest=_manifest(
            piping_paths={"P-DASH-ID": [[(0.0, 10.0), (100.0, 10.0)]]},
            pipe_dash_patterns={"P-DASH-ID": [9.0, 4.0]},
            pipe_stroke_widths={"P-DASH-ID": 1.35},
        ),
    )

    pipe_item = view._scene.item_for_object_id("P-DASH-ID")
    assert isinstance(pipe_item, PipeItem)
    pen = pipe_item.pen()
    dash = [float(x) for x in pen.dashPattern()]
    assert len(dash) >= 2
    assert dash[0] * pen.widthF() == pytest.approx(9.0, abs=0.01)
    assert dash[1] * pen.widthF() == pytest.approx(4.0, abs=0.01)


def test_object_mapping_selection_and_highlight(qtbot: object) -> None:
    svg = _svg(
        '<g id="E-1"><rect x="10" y="20" width="30" height="20"/></g>',
        '<g id="P-1"><polyline points="0,10 100,10"/></g>',
    )
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(
        svg,
        equipment_ids={"E-1"},
        piping_segment_ids={"P-1"},
        render_manifest=_manifest(
            equipment_bounds={"E-1": (10.0, 20.0, 30.0, 20.0)},
            piping_paths={"P-1": [[(0.0, 10.0), (100.0, 10.0)]]},
            pipe_stroke_widths={"P-1": 1.35},
        ),
    )

    selected: list[str] = []
    clicked: list[str] = []
    view.object_selected.connect(selected.append)
    view.object_clicked.connect(clicked.append)

    view.select_object("E-1")
    assert selected and selected[-1] == "E-1"

    view.highlight("E-1")
    assert len(view._eq_highlight_items) == 0
    eq_item = view._scene.item_for_object_id("E-1")
    assert isinstance(eq_item, EquipmentItem)
    eq_color = eq_item.pen().color()
    assert eq_color.alpha() > 0
    assert eq_color.blue() > eq_color.red()

    view.highlight("P-1")
    assert len(view._pipe_highlight_items) >= 1


def test_click_overlapping_valve_and_pipe_prefers_valve_selection(qtbot: object) -> None:
    """When valve and pipe overlap, clicking should select the valve symbol."""
    svg = _svg(
        '<g id="VALVE-1"><rect x="45" y="45" width="10" height="10"/></g>',
        '<g id="PIPE-1"><polyline points="0,50 100,50"/></g>',
    )
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(
        svg,
        equipment_ids={"VALVE-1"},
        piping_segment_ids={"PIPE-1"},
        render_manifest=_manifest(
            equipment_bounds={"VALVE-1": (45.0, 45.0, 10.0, 10.0)},
            piping_paths={"PIPE-1": [[(0.0, 50.0), (100.0, 50.0)]]},
            pipe_stroke_widths={"PIPE-1": 1.35},
        ),
    )

    selected: list[str] = []
    view.object_selected.connect(selected.append)

    click_pos = view._view.mapFromScene(50.0, 50.0)
    qtbot.mouseClick(view._view.viewport(), Qt.MouseButton.LeftButton, pos=QPoint(click_pos))

    assert selected
    assert selected[-1] == "VALVE-1"


def test_clicking_empty_canvas_clears_selection(qtbot: object) -> None:
    svg = _svg('<g id="E-1"><rect x="10" y="20" width="30" height="20"/></g>')
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(
        svg,
        equipment_ids={"E-1"},
        render_manifest=_manifest(equipment_bounds={"E-1": (10.0, 20.0, 30.0, 20.0)}),
    )

    view.select_object("E-1")
    assert view._scene.selectedItems()

    empty_view_pos = view._view.mapFromScene(-9.0, -19.0)
    qtbot.mouseClick(view._view.viewport(), Qt.MouseButton.LeftButton, pos=QPoint(empty_view_pos))

    assert not view._scene.selectedItems()


def test_escape_clears_selection(qtbot: object) -> None:
    svg = _svg('<g id="E-1"><rect x="10" y="20" width="30" height="20"/></g>')
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(
        svg,
        equipment_ids={"E-1"},
        render_manifest=_manifest(equipment_bounds={"E-1": (10.0, 20.0, 30.0, 20.0)}),
    )

    view.select_object("E-1")
    assert view._scene.selectedItems()

    cleared: list[bool] = []
    view.empty_space_clicked.connect(lambda: cleared.append(True))

    view._view.viewport().setFocus()
    qtbot.keyClick(view._view.viewport(), Qt.Key.Key_Escape)

    assert not view._scene.selectedItems()
    assert cleared


def test_equipment_coordinates_match_svg_renderer_space(qtbot: object) -> None:
    """Equipment overlay geometry should stay in same document space as renderer output."""
    svg = _svg(
        '<g transform="translate(30,40)"><g id="E-1"><rect x="10" y="20" width="30" height="20"/></g></g>'
    )
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(
        svg,
        equipment_ids={"E-1"},
        render_manifest=_manifest(equipment_bounds={"E-1": (40.0, 60.0, 30.0, 20.0)}),
    )

    renderer = view._renderer
    assert renderer is not None and renderer.isValid()
    manual = view._equipment_rects["E-1"]
    rendered = renderer.transformForElement("E-1").mapRect(renderer.boundsOnElement("E-1"))

    assert manual.x() == pytest.approx(rendered.x(), abs=0.1)
    assert manual.y() == pytest.approx(rendered.y(), abs=0.1)
    assert manual.width() == pytest.approx(rendered.width(), abs=0.1)
    assert manual.height() == pytest.approx(rendered.height(), abs=0.1)


def test_no_duplicate_viewbox_offset(qtbot: object) -> None:
    """SVG background item position should equal viewBox origin exactly once."""
    svg = _svg('<g id="E-1"><rect x="10" y="20" width="30" height="20"/></g>')
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(
        svg,
        equipment_ids={"E-1"},
        render_manifest=_manifest(equipment_bounds={"E-1": (10.0, 20.0, 30.0, 20.0)}),
    )

    renderer = view._renderer
    assert renderer is not None
    vb: QRectF = renderer.viewBoxF()
    svg_item = next(
        it for it in view._scene.items() if isinstance(it, QGraphicsSvgItem) and it.zValue() == 0
    )

    assert svg_item.pos().x() == pytest.approx(vb.x(), abs=0.01)
    assert svg_item.pos().y() == pytest.approx(vb.y(), abs=0.01)


def test_scene_rect_includes_padding_around_viewbox(qtbot: object) -> None:
    """Scene rect should be slightly larger than viewBox to keep edge frame strokes visible."""
    svg = _svg('<g id="E-1"><rect x="10" y="20" width="30" height="20"/></g>')
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(
        svg,
        equipment_ids={"E-1"},
        render_manifest=_manifest(equipment_bounds={"E-1": (10.0, 20.0, 30.0, 20.0)}),
    )

    renderer = view._renderer
    assert renderer is not None
    vb: QRectF = renderer.viewBoxF()
    sr: QRectF = view._scene.sceneRect()

    assert sr.x() < vb.x()
    assert sr.y() < vb.y()
    assert sr.right() > vb.right()
    assert sr.bottom() > vb.bottom()


def test_border_group_is_rendered_as_frame_overlay(qtbot: object) -> None:
    """SVG border group should be visible through explicit frame overlay paths."""
    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="-5 -5 120 80">'
        '<g class="border">'
        '<polyline points="1,74 114,74 114,1 1,1 1,74" fill="none" stroke="black" stroke-width="0.2"/>'
        "</g>"
        '<g id="E-1"><rect x="20" y="20" width="20" height="12"/></g>'
        "</svg>"
    )
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(
        svg,
        equipment_ids={"E-1"},
        render_manifest=_manifest(equipment_bounds={"E-1": (20.0, 20.0, 20.0, 12.0)}),
    )

    frame_items = [
        it
        for it in view._scene.items()
        if isinstance(it, QGraphicsPathItem) and it.zValue() == pytest.approx(1.0, abs=0.01)
    ]
    assert frame_items, "Expected explicit border frame overlay path items"


def test_background_visibility_and_opacity_controls(qtbot: object) -> None:
    svg = _svg('<g id="E-1"><rect x="10" y="20" width="30" height="20"/></g>')
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(
        svg,
        equipment_ids={"E-1"},
        render_manifest=_manifest(equipment_bounds={"E-1": (10.0, 20.0, 30.0, 20.0)}),
    )

    assert view._scene.svg_item is not None
    view.set_full_svg_background_visible(False)
    assert view._scene.svg_item is not None and not view._scene.svg_item.isVisible()

    view.set_full_svg_background_visible(True)
    view.set_full_svg_background_opacity(0.4)
    assert view._scene.svg_item is not None
    assert view._scene.svg_item.opacity() == pytest.approx(0.4, abs=0.001)


def test_sheet_background_is_explicit_white_page(qtbot: object) -> None:
    svg = _svg('<g id="E-1"><rect x="10" y="20" width="30" height="20"/></g>')
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(
        svg,
        equipment_ids={"E-1"},
        render_manifest=_manifest(equipment_bounds={"E-1": (10.0, 20.0, 30.0, 20.0)}),
    )

    renderer = view._renderer
    assert renderer is not None
    vb = renderer.viewBoxF()

    sheet_items = [
        it
        for it in view._scene.items()
        if isinstance(it, QGraphicsRectItem) and it.zValue() == pytest.approx(-1.0, abs=0.01)
    ]
    assert sheet_items, "Expected explicit white sheet background behind SVG"

    sheet = sheet_items[0]
    assert sheet.brush().color().name().lower() == "#ffffff"
    rect = sheet.rect()
    assert rect.x() == pytest.approx(vb.x(), abs=0.01)
    assert rect.y() == pytest.approx(vb.y(), abs=0.01)
    assert rect.width() == pytest.approx(vb.width(), abs=0.01)
    assert rect.height() == pytest.approx(vb.height(), abs=0.01)


def test_transformed_equipment_bounds_from_manifest(qtbot: object) -> None:
    """Nested transforms are respected when provided by the manifest."""
    svg = _svg(
        '<g transform="translate(30,40)">',
        '  <g transform="scale(2)">',
        '    <g id="E-TX"><rect x="10" y="20" width="30" height="20"/></g>',
        "  </g>",
        "</g>",
    )
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(
        svg,
        equipment_ids={"E-TX"},
        render_manifest=_manifest(equipment_bounds={"E-TX": (50.0, 80.0, 60.0, 40.0)}),
    )

    item = view._scene.item_for_object_id("E-TX")
    assert isinstance(item, EquipmentItem)

    renderer = view._renderer
    assert renderer is not None and renderer.isValid()
    expected = renderer.transformForElement("E-TX").mapRect(renderer.boundsOnElement("E-TX"))
    actual = view._scene.object_bounds("E-TX")
    assert actual is not None and actual.isValid()

    assert actual.x() == pytest.approx(expected.x(), abs=0.2)
    assert actual.y() == pytest.approx(expected.y(), abs=0.2)
    assert actual.width() == pytest.approx(expected.width(), abs=0.2)
    assert actual.height() == pytest.approx(expected.height(), abs=0.2)


def test_renderer_bounds_supplement_equipment_without_manifest_bounds(qtbot: object) -> None:
    """Equipment IDs missing manifest bounds should still render via renderer element bounds."""
    svg = _svg(
        '<g id="V-1" class="representation-group">',
        '  <polyline points="10,10 14,14 10,18 6,14 10,10"/>',
        "</g>",
    )
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(svg, equipment_ids={"V-1"}, render_manifest=_manifest())

    item = view._scene.item_for_object_id("V-1")
    assert isinstance(item, EquipmentItem)


def test_renderer_fallback_skips_near_full_viewbox_container_bounds(qtbot: object) -> None:
    """Container-like IDs with scene-sized bounds should not become selectable overlays."""
    svg = (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">'
        '<g id="AF-WIDE"><rect x="0" y="0" width="100" height="100" fill="none"/></g>'
        '<g id="VALVE-1"><rect x="45" y="45" width="10" height="10" fill="none"/></g>'
        "</svg>"
    )
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(
        svg,
        equipment_ids={"AF-WIDE", "VALVE-1"},
        render_manifest=_manifest(equipment_bounds={"VALVE-1": (45.0, 45.0, 10.0, 10.0)}),
    )

    # Full-canvas container should be ignored; concrete valve symbol remains selectable.
    assert view._scene.item_for_object_id("AF-WIDE") is None
    assert isinstance(view._scene.item_for_object_id("VALVE-1"), EquipmentItem)


def test_equipment_hover_outline_is_not_selection_blue(qtbot: object) -> None:
    """Hovered-but-unselected equipment should not look selected."""
    svg = _svg('<rect id="E-HOVER" x="15" y="25" width="40" height="18"/>')
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(
        svg,
        equipment_ids={"E-HOVER"},
        render_manifest=_manifest(equipment_bounds={"E-HOVER": (15.0, 25.0, 40.0, 18.0)}),
    )

    item = view._scene.item_for_object_id("E-HOVER")
    assert isinstance(item, EquipmentItem)

    item.setSelected(False)
    item.set_highlighted(False)
    item._hovered = True
    item._update_pen()

    c = item.pen().color()
    assert c.isValid()
    assert c.alpha() == 0


def test_path_based_equipment_hover_stays_visible(qtbot: object) -> None:
    """Path-based equipment (like valve symbols) should remain visible on hover."""
    svg = _svg('<g id="VALVE-HOVER"><path d="M 10 10 L 14 14 L 10 18 L 6 14 Z"/></g>')
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(
        svg,
        equipment_ids={"VALVE-HOVER"},
        render_manifest=_manifest(
            equipment_paths={
                "VALVE-HOVER": [
                    [(10.0, 10.0), (14.0, 14.0), (10.0, 18.0), (6.0, 14.0), (10.0, 10.0)]
                ]
            },
            equipment_colors={"VALVE-HOVER": (40, 40, 40, 255)},
            equipment_stroke_widths={"VALVE-HOVER": 1.0},
        ),
    )

    item = view._scene.item_for_object_id("VALVE-HOVER")
    assert isinstance(item, EquipmentItem)

    item.setSelected(False)
    item.set_highlighted(False)
    item._hovered = True
    item._update_pen()

    c = item.pen().color()
    assert c.isValid()
    assert c.alpha() > 0


def test_manifest_leaf_shape_equipment_renders_item(qtbot: object) -> None:
    """Leaf-shape IDs render through equipment bounds from manifest."""
    svg = _svg(
        '<rect id="E-RECT-TX" x="10" y="20" width="20" height="12"/>',
    )
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(
        svg,
        equipment_ids={"E-RECT-TX"},
        render_manifest=_manifest(equipment_bounds={"E-RECT-TX": (10.0, 20.0, 20.0, 12.0)}),
    )

    item = view._scene.item_for_object_id("E-RECT-TX")
    assert isinstance(item, EquipmentItem)

    actual = view._scene.object_bounds("E-RECT-TX")
    assert actual is not None and actual.isValid()


def test_manifest_only_skips_piping_without_paths(qtbot: object) -> None:
    """Piping IDs without manifest paths should not create interaction items."""
    svg = _svg(
        '<g id="P-NOPATH">',
        '  <path d="M 10 12 L 75 12"/>',
        "</g>",
    )
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(svg, piping_segment_ids={"P-NOPATH"}, render_manifest=_manifest())

    item = view._scene.item_for_object_id("P-NOPATH")
    assert item is None


def test_normalized_object_bounds_expand_line_like_geometry(qtbot: object) -> None:
    """Line-like bounds should be expanded to non-zero area for navigation."""
    svg = _svg(
        '<g id="P-LINE">',
        '  <path d="M 10 12 L 75 12"/>',
        "</g>",
    )
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(
        svg,
        piping_segment_ids={"P-LINE"},
        render_manifest=_manifest(piping_paths={"P-LINE": [[(10.0, 12.0), (75.0, 12.0)]]}),
    )

    raw = view._scene.object_bounds("P-LINE")
    assert raw is not None
    assert raw.height() > 0.0

    normalized = view._scene.normalized_object_bounds("P-LINE", min_extent=4.0)
    assert normalized is not None
    assert normalized.width() > 0
    assert normalized.height() >= 4.0


def test_zoom_to_line_like_object_uses_normalized_bounds(qtbot: object) -> None:
    """Zoom-to should work for line-like objects by using normalized bounds."""
    svg = _svg(
        '<g id="P-ZOOM">',
        '  <path d="M 10 12 L 75 12"/>',
        "</g>",
    )
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(
        svg,
        piping_segment_ids={"P-ZOOM"},
        render_manifest=_manifest(piping_paths={"P-ZOOM": [[(10.0, 12.0), (75.0, 12.0)]]}),
    )

    view.reset_zoom()
    before = view._view.transform().m11()
    view.zoom_to("P-ZOOM")
    after = view._view.transform().m11()

    assert after != pytest.approx(before, abs=1e-6)


def test_highlight_for_line_like_object_uses_pipe_overlay(qtbot: object) -> None:
    """Line-like piping highlights should use path overlays in one central layer."""
    svg = _svg(
        '<g id="P-HL">',
        '  <path d="M 10 12 L 75 12"/>',
        "</g>",
    )
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(
        svg,
        piping_segment_ids={"P-HL"},
        render_manifest=_manifest(piping_paths={"P-HL": [[(10.0, 12.0), (75.0, 12.0)]]}),
    )

    view.highlight("P-HL")
    assert len(view._pipe_highlight_items) >= 1
    assert len(view._eq_highlight_items) == 0


def test_highlight_source_parity_scene_notify_vs_view_api(qtbot: object) -> None:
    """Scene notify and view API should produce equivalent highlight state."""
    svg = _svg(
        '<g id="E-1"><rect x="10" y="20" width="30" height="20"/></g>',
        '<g id="P-1"><polyline points="0,10 100,10"/></g>',
    )
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(
        svg,
        equipment_ids={"E-1"},
        piping_segment_ids={"P-1"},
        render_manifest=_manifest(
            equipment_bounds={"E-1": (10.0, 20.0, 30.0, 20.0)},
            piping_paths={"P-1": [[(0.0, 10.0), (100.0, 10.0)]]},
            pipe_stroke_widths={"P-1": 1.35},
        ),
    )

    view.highlight("P-1")
    overlays_via_view = len(view._pipe_highlight_items)
    assert overlays_via_view >= 1

    view.highlight(None)
    assert len(view._pipe_highlight_items) == 0

    view._scene.notify_object_highlight_request("P-1")
    overlays_via_notify = len(view._pipe_highlight_items)
    assert overlays_via_notify == overlays_via_view


def test_clear_and_rehighlight_is_deterministic(qtbot: object) -> None:
    """Repeated clear/re-highlight cycles should produce stable overlay geometry."""
    svg = _svg(
        '<g id="P-1"><polyline points="0,10 100,10"/></g>',
    )
    view = DiagramView()
    qtbot.addWidget(view)  # type: ignore[attr-defined]
    view.load_svg(
        svg,
        piping_segment_ids={"P-1"},
        render_manifest=_manifest(
            piping_paths={"P-1": [[(0.0, 10.0), (100.0, 10.0)]]},
            pipe_stroke_widths={"P-1": 1.35},
        ),
    )

    view.highlight("P-1")
    first_rects = [
        item.path().boundingRect()
        for item in view._pipe_highlight_items
        if isinstance(item, QGraphicsPathItem)
    ]
    assert first_rects

    view.highlight(None)
    assert len(view._pipe_highlight_items) == 0

    view.highlight("P-1")
    second_rects = [
        item.path().boundingRect()
        for item in view._pipe_highlight_items
        if isinstance(item, QGraphicsPathItem)
    ]
    assert len(second_rects) == len(first_rects)
    for first, second in zip(first_rects, second_rects):
        assert first.x() == pytest.approx(second.x(), abs=0.01)
        assert first.y() == pytest.approx(second.y(), abs=0.01)
        assert first.width() == pytest.approx(second.width(), abs=0.01)
        assert first.height() == pytest.approx(second.height(), abs=0.01)
