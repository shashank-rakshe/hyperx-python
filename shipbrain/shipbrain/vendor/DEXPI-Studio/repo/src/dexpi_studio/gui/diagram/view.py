"""DiagramView: canvas wrapper around DiagramScene."""

from __future__ import annotations

from PySide6.QtCore import QEvent, QPoint, QPointF, QRectF, Qt, Signal
from PySide6.QtGui import (
    QCursor,
    QInputDevice,
    QKeyEvent,
    QKeySequence,
    QMouseEvent,
    QNativeGestureEvent,
    QShortcut,
    QWheelEvent,
)
from PySide6.QtWidgets import (
    QGraphicsPathItem,
    QGraphicsRectItem,
    QGraphicsView,
    QHBoxLayout,
    QLabel,
    QPushButton,
    QSizePolicy,
    QVBoxLayout,
    QWidget,
)

from dexpi_studio.core.diagram_manifest import DiagramRenderManifest

from .scene import DiagramScene


class DiagramView(QWidget):
    """Diagram canvas with SVG background + model-backed object layers."""

    object_clicked = Signal(str)
    object_selected = Signal(str)
    empty_space_clicked = Signal()

    # Compatibility signals for existing wiring while migrating call sites.
    element_clicked = Signal(str)
    focus_requested = Signal(str)
    assistant_requested = Signal(str)

    _ZOOM_FACTOR = 1.15
    _MIN_ZOOM = 0.05
    _MAX_ZOOM = 20.0

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._equipment_ids: set[str] = set()
        self._piping_ids: set[str] = set()
        self._pan_active = False
        self._pan_start: QPoint = QPoint()

        self._setup_ui()
        self._setup_shortcuts()
        self._wire_scene_signals()

    @property
    def _renderer(self):
        return self._scene.renderer

    @property
    def _equipment_rects(self) -> dict[str, QRectF]:
        return self._scene._equipment_rects

    @property
    def _pipe_paths(self):
        return self._scene._pipe_paths

    @property
    def _eq_highlight_items(self) -> list[QGraphicsRectItem]:
        return self._scene._equipment_highlight_items

    @property
    def _pipe_highlight_items(self) -> list[QGraphicsPathItem]:
        return self._scene._pipe_highlight_items

    def _setup_ui(self) -> None:
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        self._scene = DiagramScene()
        self._view = QGraphicsView(self._scene)
        self._view.setDragMode(QGraphicsView.DragMode.NoDrag)
        self._view.setTransformationAnchor(QGraphicsView.ViewportAnchor.NoAnchor)
        self._view.setResizeAnchor(QGraphicsView.ViewportAnchor.NoAnchor)
        self._view.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self._view.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self._view.viewport().installEventFilter(self)
        layout.addWidget(self._view)

        self._view_bar = QWidget()
        self._view_bar.setObjectName("diagramViewBar")
        self._view_bar.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        self._view_bar.setFixedHeight(32)

        bar_layout = QHBoxLayout(self._view_bar)
        bar_layout.setContentsMargins(6, 0, 6, 0)
        bar_layout.setSpacing(2)

        def _btn(text: str, tooltip: str) -> QPushButton:
            b = QPushButton(text)
            b.setToolTip(tooltip)
            b.setFixedHeight(24)
            b.setFlat(True)
            b.setCursor(Qt.CursorShape.PointingHandCursor)
            b.setStyleSheet(
                "QPushButton { padding: 0 10px; border-radius: 3px; font-size: 12px; }"
                "QPushButton:hover { background: #DCDCDC; }"
                "QPushButton:pressed { background: #C8C8C8; }"
            )
            return b

        btn_fit = _btn("⊡ Fit", "Fit diagram to window  (Ctrl+0)")
        btn_fit.clicked.connect(self.fit_to_window)
        btn_zoom_out = _btn("−", "Zoom out  (Ctrl+-)")
        btn_zoom_out.setFixedWidth(28)
        btn_zoom_out.clicked.connect(self.zoom_out)
        self._zoom_label = QLabel("100%")
        self._zoom_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._zoom_label.setFixedWidth(48)
        self._zoom_label.setStyleSheet("font-size: 12px; color: #444;")
        self._zoom_label.setToolTip(
            "Touchpad: pinch to zoom, scroll with two fingers to move, double-tap with two "
            "fingers to fit. Ctrl/Cmd + scroll, or a mouse wheel, zooms at the pointer. "
            "Drag to move."
        )
        btn_zoom_in = _btn("+", "Zoom in  (Ctrl++)")
        btn_zoom_in.setFixedWidth(28)
        btn_zoom_in.clicked.connect(self.zoom_in)
        btn_reset = _btn("1:1", "Reset to actual size  (Ctrl+1)")
        btn_reset.clicked.connect(self.reset_zoom)

        bar_layout.addStretch()
        bar_layout.addWidget(btn_fit)
        bar_layout.addSpacing(4)
        bar_layout.addWidget(btn_zoom_out)
        bar_layout.addWidget(self._zoom_label)
        bar_layout.addWidget(btn_zoom_in)
        bar_layout.addSpacing(4)
        bar_layout.addWidget(btn_reset)

        layout.addWidget(self._view_bar)

    def _wire_scene_signals(self) -> None:
        self._scene.object_clicked.connect(self.object_clicked.emit)
        self._scene.object_clicked.connect(self.element_clicked.emit)
        self._scene.object_selected.connect(self.object_selected.emit)
        self._scene.empty_space_clicked.connect(self.empty_space_clicked.emit)
        self._scene.focus_requested.connect(self.focus_requested.emit)
        self._scene.assistant_requested.connect(self.assistant_requested.emit)

    def _setup_shortcuts(self) -> None:
        QShortcut(QKeySequence("Ctrl+0"), self, activated=self.fit_to_window)
        QShortcut(QKeySequence("Ctrl+="), self, activated=self.zoom_in)
        QShortcut(QKeySequence("Ctrl++"), self, activated=self.zoom_in)
        QShortcut(QKeySequence("Ctrl+-"), self, activated=self.zoom_out)
        QShortcut(QKeySequence("Ctrl+1"), self, activated=self.reset_zoom)
        QShortcut(QKeySequence("Esc"), self, activated=self.clear_selection)

    def eventFilter(self, watched: object, event: QEvent) -> bool:
        if watched is self._view.viewport():
            if isinstance(event, QNativeGestureEvent):
                return self._native_gesture(event)
            if isinstance(event, QWheelEvent):
                self._wheel(event)
                return True
            etype = event.type()
            if isinstance(event, QKeyEvent) and etype == QEvent.Type.KeyPress:
                if event.key() == Qt.Key.Key_Escape:
                    self.clear_selection()
                    return True
            if isinstance(event, QMouseEvent):
                if (
                    etype == QEvent.Type.MouseButtonPress
                    and event.button() == Qt.MouseButton.LeftButton
                ):
                    self._pan_active = True
                    self._pan_start = event.globalPosition().toPoint()
                    self._pan_dragged = False
                    self._view.viewport().setCursor(QCursor(Qt.CursorShape.ClosedHandCursor))
                elif etype == QEvent.Type.MouseMove and self._pan_active:
                    pos = event.globalPosition().toPoint()
                    delta = pos - self._pan_start
                    self._pan_start = pos
                    if abs(delta.x()) > 2 or abs(delta.y()) > 2:
                        self._pan_dragged = True
                    self._view.horizontalScrollBar().setValue(
                        self._view.horizontalScrollBar().value() - delta.x()
                    )
                    self._view.verticalScrollBar().setValue(
                        self._view.verticalScrollBar().value() - delta.y()
                    )
                    return True
                elif (
                    etype == QEvent.Type.MouseButtonRelease
                    and event.button() == Qt.MouseButton.LeftButton
                ):
                    self._pan_active = False
                    self._pan_dragged = False
                    self._view.viewport().setCursor(QCursor(Qt.CursorShape.ArrowCursor))
        return super().eventFilter(watched, event)

    def load_svg(
        self,
        svg_content: str,
        equipment_ids: set[str] | None = None,
        piping_segment_ids: set[str] | None = None,
        render_manifest: DiagramRenderManifest | None = None,
    ) -> None:
        """Load SVG and create model-backed object item layer."""
        self._equipment_ids = equipment_ids or set()
        self._piping_ids = piping_segment_ids or set()
        self._scene.set_svg_background(svg_content)
        self._scene.set_render_manifest(render_manifest)
        self._scene.populate_objects(self._equipment_ids, self._piping_ids)
        self.fit_to_window()

    def clear(self) -> None:
        self._equipment_ids = set()
        self._piping_ids = set()
        self._scene.clear_diagram()
        self._update_zoom_label()

    def highlight(self, object_id: str | None) -> None:
        if object_id is None:
            self._scene.clear_highlight()
            return
        self._scene.highlight_object(object_id)

    def highlight_ids(self, object_ids: list[str]) -> None:
        self._scene.highlight_objects(object_ids)
        combined: QRectF | None = None
        for oid in object_ids:
            bounds = self._scene.normalized_object_bounds(oid)
            if bounds is None:
                continue
            combined = bounds if combined is None else combined.united(bounds)
        if combined is not None and (combined.width() > 0 or combined.height() > 0):
            self._view.ensureVisible(combined.adjusted(-10, -10, 10, 10), xmargin=0, ymargin=0)

    def zoom_to(self, object_id: str | None) -> None:
        self.highlight(object_id)
        if object_id is None:
            return
        target_rect = self._scene.normalized_object_bounds(object_id)
        if target_rect is None:
            return
        pad_x = max(target_rect.width() * 1.5, 20.0)
        pad_y = max(target_rect.height() * 1.5, 20.0)
        self._view.fitInView(
            target_rect.adjusted(-pad_x, -pad_y, pad_x, pad_y),
            Qt.AspectRatioMode.KeepAspectRatio,
        )
        self._update_zoom_label()

    def select_object(self, object_id: str) -> None:
        self._scene.select_object(object_id)

    def clear_selection(self) -> None:
        """Clear any selected object in the diagram scene."""
        self._scene.clear_selection()

    def set_full_svg_background_visible(self, visible: bool) -> None:
        """Toggle full SVG background visibility for symbol-layer debugging."""
        self._scene.set_background_visible(visible)

    def set_full_svg_background_opacity(self, opacity: float) -> None:
        """Set full SVG background opacity in range [0.0, 1.0]."""
        self._scene.set_background_opacity(opacity)

    def _current_zoom(self) -> float:
        return self._view.transform().m11()

    def _update_zoom_label(self) -> None:
        self._zoom_label.setText(f"{round(self._current_zoom() * 100)}%")

    def _set_zoom(self, factor: float, anchor: QPointF | None = None) -> None:
        current = self._current_zoom()
        if current == 0:
            return
        rel = factor / current
        if anchor is not None:
            view_anchor = self._view.mapFromScene(anchor)
            self._view.scale(rel, rel)
            new_view_anchor = self._view.mapFromScene(anchor)
            delta = new_view_anchor - view_anchor
            self._view.horizontalScrollBar().setValue(
                self._view.horizontalScrollBar().value() + delta.x()
            )
            self._view.verticalScrollBar().setValue(
                self._view.verticalScrollBar().value() + delta.y()
            )
        else:
            self._view.scale(rel, rel)
        self._update_zoom_label()

    def _zoom_by(self, factor: float, view_pos: QPointF) -> None:
        """Zoom by *factor*, keeping the scene point under *view_pos* in place."""
        if factor <= 0:
            return
        new_zoom = max(self._MIN_ZOOM, min(self._MAX_ZOOM, self._current_zoom() * factor))
        self._set_zoom(new_zoom, self._view.mapToScene(view_pos.toPoint()))

    @staticmethod
    def _from_touchpad(event: QWheelEvent) -> bool:
        """Whether the scroll comes from a touchpad, which scrolls in pixels.

        A mouse wheel turns in notches and reports no pixel delta.
        """
        device = event.device()
        if device is not None and device.type() == QInputDevice.DeviceType.TouchPad:
            return True
        return not event.pixelDelta().isNull()

    def _wheel(self, event: QWheelEvent) -> None:
        """Scroll on a touchpad pans; a mouse wheel, or a scroll with Ctrl/Cmd, zooms.

        The zoom follows how far the wheel or fingers moved, so a touchpad's many small
        events zoom smoothly rather than one fixed step each.
        """
        zoom_keys = Qt.KeyboardModifier.ControlModifier | Qt.KeyboardModifier.MetaModifier
        if self._from_touchpad(event) and not event.modifiers() & zoom_keys:
            delta = event.pixelDelta()
            if delta.isNull():
                delta = event.angleDelta() / 8
            self._view.horizontalScrollBar().setValue(
                self._view.horizontalScrollBar().value() - delta.x()
            )
            self._view.verticalScrollBar().setValue(
                self._view.verticalScrollBar().value() - delta.y()
            )
            return
        angle = event.angleDelta()
        notches = (angle.y() or angle.x()) / 120
        if notches:
            self._zoom_by(self._ZOOM_FACTOR**notches, event.position())

    def _native_gesture(self, event: QNativeGestureEvent) -> bool:
        """Pinch zooms around the fingers; a two-finger double tap fits the drawing."""
        gesture = event.gestureType()
        if gesture == Qt.NativeGestureType.ZoomNativeGesture:
            self._zoom_by(1.0 + event.value(), event.position())
            return True
        if gesture == Qt.NativeGestureType.SmartZoomNativeGesture:
            self.fit_to_window()
            return True
        return False

    def fit_to_window(self) -> None:
        if self._scene.renderer is None or not self._scene.renderer.isValid():
            return
        # Fit to actual scene content so border/title blocks outside the raw
        # SVG viewBox remain visible.
        target = self._scene.sceneRect()
        self._view.fitInView(target, Qt.AspectRatioMode.KeepAspectRatio)
        self._update_zoom_label()

    def zoom_in(self) -> None:
        new_zoom = min(self._current_zoom() * self._ZOOM_FACTOR, self._MAX_ZOOM)
        self._set_zoom(new_zoom)

    def zoom_out(self) -> None:
        new_zoom = max(self._current_zoom() / self._ZOOM_FACTOR, self._MIN_ZOOM)
        self._set_zoom(new_zoom)

    def reset_zoom(self) -> None:
        self._view.resetTransform()
        self._update_zoom_label()
