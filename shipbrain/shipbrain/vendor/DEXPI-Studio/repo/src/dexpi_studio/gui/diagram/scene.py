"""DiagramScene with layered SVG background, object items, and highlights."""

from __future__ import annotations

import logging

from PySide6 import QtWidgets
from PySide6.QtCore import QRectF, QSignalBlocker, Qt, Signal
from PySide6.QtGui import QBrush, QColor, QPainterPath, QPen, QTransform
from PySide6.QtSvgWidgets import QGraphicsSvgItem
from PySide6.QtWidgets import QGraphicsPathItem

from dexpi_studio.core.diagram_manifest import DiagramRenderManifest

from .geometry import extract_paths_from_group, identity_matrix, walk_group
from .highlighting import SceneHighlightController
from .items import EquipmentItem, PipeItem
from .svg_background import SvgBackgroundData, build_svg_background
from .svg_text_layer import create_text_item

_log = logging.getLogger(__name__)


class DiagramScene(QtWidgets.QGraphicsScene):
    """Graphics scene managing background, object items, and highlight overlays."""

    _VIEWBOX_PADDING_X = 3.0
    _VIEWBOX_PADDING_TOP = 9.0
    _VIEWBOX_PADDING_BOTTOM = 3.0
    _FALLBACK_SKIP_RATIO = 0.9

    object_clicked = Signal(str)
    object_selected = Signal(str)
    empty_space_clicked = Signal()
    focus_requested = Signal(str)
    assistant_requested = Signal(str)

    def __init__(self) -> None:
        super().__init__()
        self._background: SvgBackgroundData | None = None
        self._sheet_item: QtWidgets.QGraphicsRectItem | None = None
        self._background_visible = True
        self._background_opacity = 1.0
        self._frame_items: list[QGraphicsPathItem] = []

        self._object_items_by_id: dict[str, list[QtWidgets.QGraphicsItem]] = {}
        self._equipment_rects: dict[str, QRectF] = {}
        self._equipment_paths: dict[str, list[QPainterPath]] = {}
        self._equipment_colors: dict[str, QColor] = {}
        self._equipment_dash_patterns: dict[str, list[float]] = {}
        self._equipment_stroke_widths: dict[str, float] = {}
        self._pipe_paths: dict[str, list[QPainterPath]] = {}
        self._pipe_colors: dict[str, QColor] = {}
        self._pipe_dash_patterns: dict[str, list[float]] = {}
        self._pipe_stroke_widths: dict[str, float] = {}
        self._highlighted_object_ids: list[str] = []

        self._highlight_controller = SceneHighlightController()
        self._render_manifest: DiagramRenderManifest | None = None
        self.selectionChanged.connect(self._on_selection_changed)

    @property
    def renderer(self):
        return self._background.renderer if self._background is not None else None

    @property
    def svg_item(self) -> QGraphicsSvgItem | None:
        return self._background.svg_item if self._background is not None else None

    @property
    def _equipment_highlight_items(self):
        """Compatibility accessor for tests and view internals."""
        return self._highlight_controller.equipment_items

    @property
    def _pipe_highlight_items(self):
        """Compatibility accessor for tests and view internals."""
        return self._highlight_controller.pipe_items

    def set_svg_background(self, svg_content: str) -> None:
        """Set/replace diagram SVG background layer."""
        self.clear_diagram()
        self._background = build_svg_background(svg_content)
        self._render_sheet_background(self._background.renderer.viewBoxF())
        self._background.svg_item.setVisible(self._background_visible)
        self._background.svg_item.setOpacity(self._background_opacity)
        self.addItem(self._background.svg_item)
        self._render_frame_overlay()
        self._render_label_overlay()
        self._update_scene_rect()

    def _update_scene_rect(self) -> None:
        """Set scene rect to cover all currently rendered diagram content."""
        if self._background is None:
            return

        vb = self._background.renderer.viewBoxF()
        content_rect = self.itemsBoundingRect()

        if vb.isValid() and vb.width() > 0 and vb.height() > 0:
            base_rect = vb
        else:
            base_rect = content_rect

        if content_rect.isValid() and content_rect.width() > 0 and content_rect.height() > 0:
            base_rect = base_rect.united(content_rect)

        self.setSceneRect(
            base_rect.adjusted(
                -self._VIEWBOX_PADDING_X,
                -self._VIEWBOX_PADDING_TOP,
                self._VIEWBOX_PADDING_X,
                self._VIEWBOX_PADDING_BOTTOM,
            )
        )

    def _render_sheet_background(self, view_box: QRectF) -> None:
        """Render a dedicated white page behind the SVG drawing."""
        if self._sheet_item is not None:
            self.removeItem(self._sheet_item)
            self._sheet_item = None

        sheet = QtWidgets.QGraphicsRectItem(view_box)
        sheet.setPen(QPen(Qt.PenStyle.NoPen))
        sheet.setBrush(QBrush(QColor("#ffffff")))
        sheet.setZValue(-1)
        sheet.setAcceptedMouseButtons(Qt.MouseButton.NoButton)
        self.addItem(sheet)
        self._sheet_item = sheet

    def _render_label_overlay(self) -> None:
        """Render SVG label-group (title block) polylines as a crisp cosmetic overlay."""
        if self._background is None or self._background.svg_root is None:
            return

        label_group = next(
            (
                elem
                for elem in self._background.svg_root.iter()
                if elem.tag.split("}")[-1] == "g" and elem.get("class") == "label"
            ),
            None,
        )
        if label_group is None:
            return

        paths: list[QPainterPath] = []
        for child in label_group:
            walk_group(child, identity_matrix(), paths)

        for path in paths:
            item = QGraphicsPathItem(path)
            pen = QPen(QColor(0, 0, 0, 230), 1.2)
            pen.setCosmetic(True)
            item.setPen(pen)
            item.setBrush(QBrush(Qt.GlobalColor.transparent))
            item.setZValue(1)
            self.addItem(item)
            self._frame_items.append(item)

    def _render_frame_overlay(self) -> None:
        """Render SVG border/frame polylines as a dedicated visible overlay layer."""
        if self._background is None or self._background.svg_root is None:
            return

        for item in self._frame_items:
            self.removeItem(item)
        self._frame_items = []

        border_group = next(
            (
                elem
                for elem in self._background.svg_root.iter()
                if elem.tag.split("}")[-1] == "g" and elem.get("class") == "border"
            ),
            None,
        )
        if border_group is None:
            return

        border_paths = extract_paths_from_group(border_group)
        for path in border_paths:
            item = QGraphicsPathItem(path)
            pen = QPen(QColor(0, 0, 0, 230), 1.2)
            pen.setCosmetic(True)
            item.setPen(pen)
            item.setBrush(QBrush(Qt.GlobalColor.transparent))
            item.setZValue(1)
            self.addItem(item)
            self._frame_items.append(item)

    def set_background_visible(self, visible: bool) -> None:
        """Enable/disable full SVG background layer."""
        self._background_visible = visible
        if self._background is not None:
            self._background.svg_item.setVisible(visible)

    def set_background_opacity(self, opacity: float) -> None:
        """Set full SVG background opacity (0.0 to 1.0)."""
        clamped = max(0.0, min(1.0, opacity))
        self._background_opacity = clamped
        if self._background is not None:
            self._background.svg_item.setOpacity(clamped)

    def clear_diagram(self) -> None:
        """Clear all scene content including background and object layers."""
        self._background = None
        self._sheet_item = None
        self._frame_items.clear()
        self._object_items_by_id.clear()
        self._equipment_rects.clear()
        self._equipment_paths.clear()
        self._equipment_colors.clear()
        self._equipment_dash_patterns.clear()
        self._equipment_stroke_widths.clear()
        self._pipe_paths.clear()
        self._pipe_colors.clear()
        self._pipe_dash_patterns.clear()
        self._pipe_stroke_widths.clear()
        self._highlighted_object_ids.clear()
        self._render_manifest = None
        self._highlight_controller.clear(self, self._object_items_by_id)
        self.clear()

    def set_render_manifest(self, render_manifest: DiagramRenderManifest | None) -> None:
        """Set model-first render metadata used to build interactive overlays."""
        self._render_manifest = render_manifest

    def add_object_item(self, object_id: str, item: QtWidgets.QGraphicsItem) -> None:
        """Register and add a model-backed object item to the interaction layer."""
        if object_id == "__svg_text__":
            item.setZValue(11)
        elif isinstance(item, PipeItem):
            # Keep piping slightly below equipment so small symbols (e.g. valves)
            # are still directly clickable where they overlap a line.
            item.setZValue(9)
        else:
            item.setZValue(10)
        self.addItem(item)
        self._object_items_by_id.setdefault(object_id, []).append(item)

    def clear_object_items(self) -> None:
        """Remove all model-backed object interaction items."""
        for items in self._object_items_by_id.values():
            for item in items:
                self.removeItem(item)
        self._object_items_by_id.clear()

    def request_assistant(self, object_id: str) -> None:
        """Emit a request to open Assistant for a specific object."""
        self.assistant_requested.emit(object_id)

    def item_for_object_id(self, object_id: str) -> QtWidgets.QGraphicsItem | None:
        """Return first mapped graphics item for object ID, if any."""
        items = self._object_items_by_id.get(object_id)
        return items[0] if items else None

    def items_for_object_id(self, object_id: str) -> list[QtWidgets.QGraphicsItem]:
        """Return all mapped graphics items for object ID."""
        return list(self._object_items_by_id.get(object_id, []))

    def populate_objects(self, equipment_ids: set[str], piping_ids: set[str]) -> None:
        """Populate interaction items from manifest-backed equipment and piping IDs."""
        if (
            self._background is None
            or not self._background.renderer.isValid()
            or self._render_manifest is None
        ):
            return

        self.clear_object_items()
        self.clear_highlight()

        self._equipment_rects = {
            oid: QRectF(float(x), float(y), float(w), float(h))
            for oid, (x, y, w, h) in self._render_manifest.equipment_bounds.items()
        }
        self._equipment_paths = {}
        for oid, polyline_list in self._render_manifest.equipment_paths.items():
            paths: list[QPainterPath] = []
            for polyline in polyline_list:
                if len(polyline) < 2:
                    continue
                path = QPainterPath()
                x0, y0 = polyline[0]
                path.moveTo(float(x0), float(y0))
                for x, y in polyline[1:]:
                    path.lineTo(float(x), float(y))
                paths.append(path)
            if paths:
                self._equipment_paths[oid] = paths

        self._equipment_colors = {
            oid: QColor(int(r), int(g), int(b), int(a))
            for oid, (r, g, b, a) in self._render_manifest.equipment_colors.items()
        }
        self._equipment_dash_patterns = {
            oid: [float(v) for v in pattern]
            for oid, pattern in self._render_manifest.equipment_dash_patterns.items()
        }
        self._equipment_stroke_widths = {
            oid: float(width)
            for oid, width in self._render_manifest.equipment_stroke_widths.items()
        }

        self._pipe_paths = {}
        for oid, polyline_list in self._render_manifest.piping_paths.items():
            paths: list[QPainterPath] = []
            for polyline in polyline_list:
                if len(polyline) < 2:
                    continue
                path = QPainterPath()
                x0, y0 = polyline[0]
                path.moveTo(float(x0), float(y0))
                for x, y in polyline[1:]:
                    path.lineTo(float(x), float(y))
                paths.append(path)
            if paths:
                self._pipe_paths[oid] = paths

        self._pipe_colors = {
            oid: QColor(int(r), int(g), int(b), int(a))
            for oid, (r, g, b, a) in self._render_manifest.pipe_colors.items()
        }
        self._pipe_dash_patterns = {
            oid: [float(v) for v in pattern]
            for oid, pattern in self._render_manifest.pipe_dash_patterns.items()
        }
        self._pipe_stroke_widths = {
            oid: float(width) for oid, width in self._render_manifest.pipe_stroke_widths.items()
        }

        # Keep equipment presence complete for IDs that exist in rendered SVG
        # but were not covered by manifest primitive ownership.
        renderer = self.renderer
        if renderer is not None and renderer.isValid():
            view_box = renderer.viewBoxF()
            for object_id in equipment_ids:
                if object_id in self._equipment_rects:
                    continue
                local = renderer.boundsOnElement(object_id)
                if not local.isValid() or (local.width() <= 0 and local.height() <= 0):
                    continue
                mapped = renderer.transformForElement(object_id).mapRect(local)

                # Guard against container/group IDs whose renderer bounds span
                # (almost) the full diagram. Adding those as interactive items
                # causes accidental full-canvas selection and blocks smaller
                # symbols like valves below.
                if self._is_near_full_viewbox_fallback(mapped, view_box):
                    ratio_w = mapped.width() / view_box.width()
                    ratio_h = mapped.height() / view_box.height()
                    _log.debug(
                        f"Skipping fallback equipment hit area for '{object_id}' because "
                        f"it spans most of the diagram "
                        f"(w_ratio={ratio_w:.3f}, h_ratio={ratio_h:.3f}, "
                        f"threshold={self._FALLBACK_SKIP_RATIO:.2f})."
                    )
                    continue

                self._equipment_rects[object_id] = mapped

        for object_id in equipment_ids:
            equipment_paths = self._equipment_paths.get(object_id)
            if equipment_paths:
                combined = QPainterPath()
                for path in equipment_paths:
                    combined.addPath(path)
                self.add_object_item(
                    object_id,
                    EquipmentItem(
                        object_id=object_id,
                        path=combined,
                        base_color=self._equipment_colors.get(object_id),
                        base_dash_pattern=self._equipment_dash_patterns.get(object_id),
                        base_stroke_width=self._equipment_stroke_widths.get(object_id),
                    ),
                )
                continue

            rect = self._equipment_rects.get(object_id)
            if rect is not None:
                self.add_object_item(
                    object_id,
                    EquipmentItem(
                        object_id=object_id,
                        rect=rect,
                        base_color=self._equipment_colors.get(object_id),
                        base_dash_pattern=self._equipment_dash_patterns.get(object_id),
                        base_stroke_width=self._equipment_stroke_widths.get(object_id),
                    ),
                )

        for object_id in piping_ids:
            for path in self._pipe_paths.get(object_id, []):
                self.add_object_item(
                    object_id,
                    PipeItem(
                        object_id=object_id,
                        path=path,
                        base_color=self._pipe_colors.get(object_id),
                        base_dash_pattern=self._pipe_dash_patterns.get(object_id),
                        base_stroke_width=self._pipe_stroke_widths.get(object_id),
                    ),
                )

        self._render_svg_text_layer()

    def _is_near_full_viewbox_fallback(self, mapped: QRectF, view_box: QRectF) -> bool:
        return (
            view_box.isValid()
            and view_box.width() > 0
            and view_box.height() > 0
            and mapped.width() >= (self._FALLBACK_SKIP_RATIO * view_box.width())
            and mapped.height() >= (self._FALLBACK_SKIP_RATIO * view_box.height())
        )

    def _render_svg_text_layer(self) -> None:
        if self._render_manifest is None:
            return

        for label in self._render_manifest.text_labels:
            color = QColor(*label.color)
            self.add_object_item(
                "__svg_text__",
                create_text_item(
                    (
                        label.text,
                        float(label.x),
                        float(label.y),
                        color,
                        float(label.size),
                        label.anchor,
                        label.baseline,
                        float(label.rotation_deg),
                    )
                ),
            )

    def notify_object_clicked(self, object_id: str) -> None:
        """Called by DiagramObjectItems when clicked."""
        self.select_object(object_id)
        self.object_clicked.emit(object_id)

    def notify_object_highlight_request(self, object_id: str) -> None:
        """Handle context-menu highlight request from object items."""
        self.highlight_object(object_id)

    def request_focus(self, object_id: str) -> None:
        """Called by DiagramObjectItems context menu for focus/zoom action."""
        self.focus_requested.emit(object_id)

    def select_object(self, object_id: str) -> None:
        """Select mapped graphics item(s) for a model object ID."""
        blocker = QSignalBlocker(self)
        self.clearSelection()
        items = self._object_items_by_id.get(object_id, [])
        if not items:
            return
        for item in items:
            item.setSelected(True)
        del blocker
        self.object_selected.emit(object_id)

    def clear_selection(self) -> None:
        """Clear scene selection state."""
        self.clearSelection()

    def clear_highlight(self) -> None:
        """Clear all highlight overlays and per-item highlighted state."""
        self._highlighted_object_ids = []
        self._highlight_controller.clear(self, self._object_items_by_id)

    def highlight_object(self, object_id: str) -> None:
        """Highlight one object by ID."""
        self.highlight_objects([object_id])

    def highlight_objects(self, object_ids: list[str]) -> None:
        """Highlight multiple object IDs."""
        normalized: list[str] = []
        seen: set[str] = set()
        for object_id in object_ids:
            if object_id in seen:
                continue
            seen.add(object_id)
            normalized.append(object_id)

        if normalized == self._highlighted_object_ids:
            return

        self._highlighted_object_ids = normalized
        self._highlight_controller.apply(
            self,
            object_ids=normalized,
            object_items_by_id=self._object_items_by_id,
            pipe_paths=self._pipe_paths,
        )

    def object_bounds(self, object_id: str) -> QRectF | None:
        """Return aggregate bounds for object ID in diagram coordinate space."""
        items = self._object_items_by_id.get(object_id, [])
        combined: QRectF | None = None
        for item in items:
            if isinstance(item, EquipmentItem):
                br = item.path().boundingRect()
            else:
                br = item.sceneBoundingRect()
            if br.width() <= 0 and br.height() <= 0:
                continue
            combined = br if combined is None else combined.united(br)
        if combined is not None and (combined.width() > 0 or combined.height() > 0):
            return combined

        if object_id in self._equipment_rects:
            return self._equipment_rects[object_id]

        if object_id in self._pipe_paths:
            for path in self._pipe_paths[object_id]:
                br = path.boundingRect()
                combined = br if combined is None else combined.united(br)
            return combined

        return None

    def normalized_object_bounds(self, object_id: str, *, min_extent: float = 2.0) -> QRectF | None:
        """Return object bounds with a minimum width/height for view navigation."""
        rect = self.object_bounds(object_id)
        if rect is None:
            return None

        width = rect.width()
        height = rect.height()
        if width <= 0 and height <= 0:
            return None

        half = max(min_extent, 0.001) * 0.5
        x = rect.x()
        y = rect.y()

        if width <= 0:
            x = rect.x() - half
            width = half * 2.0
        if height <= 0:
            y = rect.y() - half
            height = half * 2.0

        return QRectF(x, y, width, height)

    def mousePressEvent(self, event: QtWidgets.QGraphicsSceneMouseEvent) -> None:
        """Emit empty-space clicks for selection-model synchronization."""
        had_selected = any(hasattr(item, "object_id") for item in self.selectedItems())
        clicked_item = self.itemAt(event.scenePos(), QTransform())
        super().mousePressEvent(event)
        if not hasattr(clicked_item, "object_id"):
            self.clear_selection()
            if not had_selected:
                self.empty_space_clicked.emit()

    def _on_selection_changed(self) -> None:
        selected = [item for item in self.selectedItems() if hasattr(item, "object_id")]
        if not selected:
            self.empty_space_clicked.emit()
            return
        object_id = getattr(selected[0], "object_id", None)
        if isinstance(object_id, str):
            self.object_selected.emit(object_id)
