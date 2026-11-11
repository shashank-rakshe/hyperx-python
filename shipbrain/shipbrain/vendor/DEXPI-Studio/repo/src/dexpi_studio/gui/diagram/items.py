"""Model-backed QGraphicsItems for DiagramScene interaction."""

from __future__ import annotations

from dataclasses import dataclass

from PySide6.QtCore import QRectF, Qt
from PySide6.QtGui import QBrush, QColor, QPainterPath, QPainterPathStroker, QPen
from PySide6.QtWidgets import (
    QGraphicsEllipseItem,
    QGraphicsPathItem,
    QMenu,
    QStyle,
    QStyleOptionGraphicsItem,
)


class DiagramObjectItem(QGraphicsPathItem):
    """Base item carrying DEXPI model identity for selection/highlighting."""

    def __init__(
        self,
        object_id: str,
        path: QPainterPath,
        object_type: str | None = None,
        parent: QGraphicsPathItem | None = None,
    ) -> None:
        super().__init__(parent)
        self.object_id = object_id
        self.object_type = object_type
        self._highlighted = False
        self._hovered = False
        self.setPath(path)
        self.setZValue(10)
        self.setFlag(self.GraphicsItemFlag.ItemIsSelectable, True)
        self.setAcceptHoverEvents(True)
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setBrush(QBrush(Qt.GlobalColor.transparent))
        self._update_pen()

    def _update_pen(self) -> None:
        if self.isSelected():
            selected = QColor("#2563eb")
            selected.setAlpha(220)
            pen = QPen(selected, 1.6)
        elif self._highlighted:
            pen = QPen(QColor(0, 80, 200, 200), 1.3)
        elif self._hovered:
            # Avoid persistent post-deselect equipment bounding boxes while the
            # cursor remains over the item.
            pen = QPen(Qt.GlobalColor.transparent, 1.0)
        else:
            pen = QPen(QColor(90, 90, 90, 40), 0.8)
        self.setPen(pen)

    def set_highlighted(self, highlighted: bool) -> None:
        self._highlighted = highlighted
        self._update_pen()

    def hoverEnterEvent(self, event: object) -> None:
        self._hovered = True
        self._update_pen()
        super().hoverEnterEvent(event)

    def hoverLeaveEvent(self, event: object) -> None:
        self._hovered = False
        self._update_pen()
        super().hoverLeaveEvent(event)

    def itemChange(self, change: object, value: object) -> object:
        result = super().itemChange(change, value)
        if change == self.GraphicsItemChange.ItemSelectedHasChanged:
            self._update_pen()
        return result

    def mousePressEvent(self, event: object) -> None:
        super().mousePressEvent(event)
        scene = self.scene()
        if scene is not None and hasattr(scene, "notify_object_clicked"):
            scene.notify_object_clicked(self.object_id)

    def paint(self, painter, option, widget=None) -> None:  # type: ignore[override]
        """Paint without Qt's default selected bounding-box decoration."""
        opt = QStyleOptionGraphicsItem(option)
        opt.state &= ~QStyle.StateFlag.State_Selected
        super().paint(painter, opt, widget)

    def contextMenuEvent(self, event: object) -> None:
        menu = QMenu()
        action_highlight = menu.addAction("Highlight")
        action_zoom = menu.addAction("Zoom to")
        action_props = menu.addAction("Show Properties")
        menu.addSeparator()
        action_ask = menu.addAction("Ask ChatP&ID about this")
        screen_pos = event.screenPos()
        global_pos = screen_pos.toPoint() if hasattr(screen_pos, "toPoint") else screen_pos
        chosen = menu.exec(global_pos)
        if chosen is action_highlight:
            scene = self.scene()
            if scene is not None and hasattr(scene, "notify_object_highlight_request"):
                scene.notify_object_highlight_request(self.object_id)
            return
        if chosen is action_zoom:
            scene = self.scene()
            if scene is not None and hasattr(scene, "request_focus"):
                scene.request_focus(self.object_id)
            return
        if chosen is action_props:
            scene = self.scene()
            if scene is not None and hasattr(scene, "notify_object_clicked"):
                scene.notify_object_clicked(self.object_id)
            return
        if chosen is action_ask:
            scene = self.scene()
            if scene is not None and hasattr(scene, "request_assistant"):
                scene.request_assistant(self.object_id)


class EquipmentItem(DiagramObjectItem):
    """Equipment item represented by a model-backed bounding rectangle."""

    def __init__(
        self,
        object_id: str,
        rect: QRectF | None = None,
        object_type: str | None = None,
        path: QPainterPath | None = None,
        base_color: QColor | None = None,
        base_dash_pattern: list[float] | None = None,
        base_stroke_width: float | None = None,
    ) -> None:
        self._base_color = QColor(base_color) if base_color is not None else QColor(90, 90, 90, 120)
        self._base_dash_pattern = (
            [float(x) for x in base_dash_pattern if float(x) > 0.0] if base_dash_pattern else None
        )
        self._base_stroke_width = float(base_stroke_width) if base_stroke_width is not None else 1.0
        if self._base_stroke_width <= 0:
            self._base_stroke_width = 1.0
        self._uses_rect_proxy = path is None
        if path is None:
            if rect is None:
                raise ValueError("EquipmentItem requires either rect or path")
            path = QPainterPath()
            path.addRect(rect)
        super().__init__(object_id=object_id, path=path, object_type=object_type)

    def _update_pen(self) -> None:
        base_w = self._base_stroke_width
        if self.isSelected():
            selected = QColor("#2563eb")
            selected.setAlpha(220)
            pen = QPen(selected, max(base_w * 1.5, 1.1))
        elif self._highlighted:
            pen = QPen(QColor(0, 80, 200, 200), max(base_w * 1.3, 1.0))
        elif self._hovered:
            if self._uses_rect_proxy:
                # Keep proxy rectangles visually silent on hover.
                pen = QPen(Qt.GlobalColor.transparent, base_w)
            else:
                # Keep real symbol geometry (e.g. valves) visible and slightly emphasized.
                hover = QColor(self._base_color)
                hover = hover.lighter(115)
                hover.setAlpha(max(hover.alpha(), 180))
                pen = QPen(hover, max(base_w * 1.15, 0.9))
        else:
            pen = QPen(QColor(self._base_color), base_w)

        if self._base_dash_pattern:
            width = max(pen.widthF(), 1e-6)
            dash_units = [max(float(v) / width, 0.1) for v in self._base_dash_pattern]
            pen.setDashPattern(dash_units)
            pen.setCapStyle(Qt.PenCapStyle.FlatCap)

        pen.setCosmetic(False)
        self.setPen(pen)


class PipeItem(DiagramObjectItem):
    """Pipe item represented by model-backed polyline/path geometry."""

    def __init__(
        self,
        object_id: str,
        path: QPainterPath,
        object_type: str | None = None,
        base_color: QColor | None = None,
        base_dash_pattern: list[float] | None = None,
        base_stroke_width: float | None = None,
    ) -> None:
        self._base_color = (
            QColor(base_color) if base_color is not None else QColor(128, 128, 0, 210)
        )
        self._base_dash_pattern = (
            [float(x) for x in base_dash_pattern if float(x) > 0.0] if base_dash_pattern else None
        )
        self._base_stroke_width = (
            float(base_stroke_width) if base_stroke_width is not None else 1.35
        )
        if self._base_stroke_width <= 0:
            self._base_stroke_width = 1.35
        super().__init__(object_id=object_id, path=path, object_type=object_type)

    def _update_pen(self) -> None:
        """Keep non-selected pipes visibly rendered using SVG-derived base color."""
        base_w = self._base_stroke_width
        if self.isSelected():
            selected = QColor("#2563eb")
            selected.setAlpha(230)
            pen = QPen(selected, max(base_w * 1.8, 1.2))
        elif self._highlighted:
            pen = QPen(QColor(0, 80, 200, 220), max(base_w * 1.6, 1.0))
        elif self._hovered:
            hover = QColor(self._base_color)
            hover = hover.lighter(115)
            hover.setAlpha(max(hover.alpha(), 180))
            pen = QPen(hover, max(base_w * 1.3, 0.8))
        else:
            default = QColor(self._base_color)
            # Keep default overlay subtle so SVG line labels/tags remain readable.
            default.setAlpha(max(default.alpha(), 120))
            pen = QPen(default, base_w)
        if self._base_dash_pattern:
            # Qt interprets dash-pattern numbers in *pen-width units*.
            # SVG dash arrays are absolute lengths in user units, so normalize
            # by current width to preserve SVG appearance across zoom levels.
            width = max(pen.widthF(), 1e-6)
            dash_units = [max(float(v) / width, 0.1) for v in self._base_dash_pattern]
            pen.setDashPattern(dash_units)
            pen.setCapStyle(Qt.PenCapStyle.FlatCap)
            pen.setCosmetic(False)
        else:
            # Preserve source stroke widths for solid process/signal lines too,
            # preventing thick overlays that diverge from the SVG appearance.
            pen.setCosmetic(False)
        self.setPen(pen)

    def shape(self) -> QPainterPath:
        stroker = QPainterPathStroker()
        stroker.setWidth(6.0)
        return stroker.createStroke(self.path())


@dataclass
class IssueMarkerItem(QGraphicsEllipseItem):
    """Placeholder for future validation issue overlays (not yet active)."""

    object_id: str

    def __init__(self, object_id: str, rect: QRectF) -> None:
        super().__init__(rect)
        self.object_id = object_id
        self.setZValue(30)
        self.setBrush(QBrush(QColor(200, 40, 40, 180)))
        self.setPen(QPen(Qt.GlobalColor.transparent))
