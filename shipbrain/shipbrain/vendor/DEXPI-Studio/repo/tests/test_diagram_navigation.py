"""Tests for zooming and moving the diagram with a touchpad and a mouse wheel."""

from __future__ import annotations

import pytest
from PySide6.QtCore import QCoreApplication, QPoint, QPointF, Qt
from PySide6.QtGui import QInputDevice, QNativeGestureEvent, QPointingDevice, QWheelEvent

from dexpi_studio.core.diagram_manifest import DiagramRenderManifest
from dexpi_studio.gui.diagram import DiagramView

_SVG = (
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 2000 1500">'
    '<rect x="0" y="0" width="2000" height="1500" fill="none" stroke="black"/></svg>'
)

_TOUCHPAD = QPointingDevice(
    "test touchpad",
    1001,
    QInputDevice.DeviceType.TouchPad,
    QPointingDevice.PointerType.Finger,
    QInputDevice.Capability.Position,
    5,
    0,
)


@pytest.fixture
def view(qtbot):
    view = DiagramView()
    qtbot.addWidget(view)
    view.resize(800, 600)
    view.show()
    view.load_svg(
        _SVG,
        equipment_ids=set(),
        piping_segment_ids=set(),
        render_manifest=DiagramRenderManifest(
            equipment_bounds={},
            equipment_paths={},
            equipment_colors={},
            equipment_dash_patterns={},
            equipment_stroke_widths={},
            piping_paths={},
            pipe_colors={},
            pipe_dash_patterns={},
            pipe_stroke_widths={},
            text_labels=[],
        ),
    )
    view.reset_zoom()
    return view


def _wheel(view, *, pixel=None, angle=None, modifiers=Qt.KeyboardModifier.NoModifier):
    pixel = pixel or QPoint()
    angle = angle or QPoint()
    viewport = view._view.viewport()
    centre = QPointF(viewport.width() / 2, viewport.height() / 2)
    device = _TOUCHPAD if not pixel.isNull() else QPointingDevice.primaryPointingDevice()
    event = QWheelEvent(
        centre,
        viewport.mapToGlobal(centre),
        pixel,
        angle,
        Qt.MouseButton.NoButton,
        modifiers,
        Qt.ScrollPhase.ScrollUpdate,
        False,
        Qt.MouseEventSource.MouseEventNotSynthesized,
        device,
    )
    QCoreApplication.sendEvent(viewport, event)


def _gesture(view, gesture, value=0.0):
    viewport = view._view.viewport()
    centre = QPointF(viewport.width() / 2, viewport.height() / 2)
    event = QNativeGestureEvent(
        gesture, _TOUCHPAD, 2, centre, centre, viewport.mapToGlobal(centre), value, QPointF(), 0
    )
    QCoreApplication.sendEvent(viewport, event)


def _scroll(view):
    return view._view.horizontalScrollBar().value(), view._view.verticalScrollBar().value()


def test_two_finger_scroll_moves_the_drawing_and_does_not_zoom(view):
    before = _scroll(view)

    _wheel(view, pixel=QPoint(-30, -40), angle=QPoint(-90, -120))

    assert view._current_zoom() == pytest.approx(1.0)
    assert _scroll(view) == (before[0] + 30, before[1] + 40)


def test_ctrl_or_cmd_with_two_fingers_zooms(view):
    _wheel(
        view,
        pixel=QPoint(0, 10),
        angle=QPoint(0, 30),
        modifiers=Qt.KeyboardModifier.ControlModifier,
    )

    assert view._current_zoom() == pytest.approx(DiagramView._ZOOM_FACTOR**0.25)


def test_a_mouse_wheel_notch_zooms_one_step(view):
    _wheel(view, angle=QPoint(0, 120))
    assert view._current_zoom() == pytest.approx(DiagramView._ZOOM_FACTOR)

    _wheel(view, angle=QPoint(0, -240))
    assert view._current_zoom() == pytest.approx(1 / DiagramView._ZOOM_FACTOR)


def test_pinch_zooms_by_the_gesture(view):
    _gesture(view, Qt.NativeGestureType.ZoomNativeGesture, 0.5)
    assert view._current_zoom() == pytest.approx(1.5)

    _gesture(view, Qt.NativeGestureType.ZoomNativeGesture, -0.5)
    assert view._current_zoom() == pytest.approx(0.75)


def test_pinch_stops_at_the_zoom_limits(view):
    for _ in range(40):
        _gesture(view, Qt.NativeGestureType.ZoomNativeGesture, 1.0)

    assert view._current_zoom() == pytest.approx(DiagramView._MAX_ZOOM)


def test_two_finger_double_tap_fits_the_drawing(view):
    _gesture(view, Qt.NativeGestureType.ZoomNativeGesture, 2.0)

    _gesture(view, Qt.NativeGestureType.SmartZoomNativeGesture)

    assert view._current_zoom() < 1.0, "a 2000 x 1500 drawing fits an 800 x 600 view below 100%"
