"""Highlight overlay management for :mod:`dexpi_studio.gui.diagram`.

Keeps all highlight rendering in one place.
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from typing import Protocol

from PySide6.QtCore import Qt
from PySide6.QtGui import QBrush, QColor, QPainterPath, QPen
from PySide6.QtWidgets import QGraphicsPathItem, QGraphicsRectItem, QGraphicsScene


@dataclass(frozen=True)
class HighlightPalette:
    """Visual style for diagram highlight overlays."""

    pipe_color: QColor = field(default_factory=lambda: QColor(30, 120, 255, 120))
    pipe_width_px: int = 3


class HighlightableGraphicsItem(Protocol):
    """Protocol for interactive diagram items that can toggle highlight state."""

    def set_highlighted(self, highlighted: bool) -> None:
        """Update item-level highlighted style."""


class SceneHighlightController:
    """Create/clear scene-level highlight overlays for equipment and piping."""

    def __init__(self, palette: HighlightPalette | None = None) -> None:
        self._palette = palette or HighlightPalette()
        self._equipment_items: list[QGraphicsRectItem] = []
        self._pipe_items: list[QGraphicsPathItem] = []

    @property
    def equipment_items(self) -> list[QGraphicsRectItem]:
        return self._equipment_items

    @property
    def pipe_items(self) -> list[QGraphicsPathItem]:
        return self._pipe_items

    def clear(
        self,
        scene: QGraphicsScene,
        object_items_by_id: Mapping[str, Sequence[HighlightableGraphicsItem | object]],
    ) -> None:
        """Remove all overlay items and reset per-item highlighted state."""
        for item in self._equipment_items:
            scene.removeItem(item)
        for item in self._pipe_items:
            scene.removeItem(item)
        self._equipment_items = []
        self._pipe_items = []

        for items in object_items_by_id.values():
            for item in items:
                set_highlighted = getattr(item, "set_highlighted", None)
                if callable(set_highlighted):
                    set_highlighted(False)

    def apply(
        self,
        scene: QGraphicsScene,
        *,
        object_ids: list[str],
        object_items_by_id: Mapping[str, Sequence[HighlightableGraphicsItem | object]],
        pipe_paths: Mapping[str, Sequence[QPainterPath]],
    ) -> None:
        """Apply highlight styling and overlays for the provided object IDs."""
        self.clear(scene, object_items_by_id)

        for object_id in object_ids:
            for item in object_items_by_id.get(object_id, []):
                set_highlighted = getattr(item, "set_highlighted", None)
                if callable(set_highlighted):
                    set_highlighted(True)

            for path in pipe_paths.get(object_id, []):
                path_item = QGraphicsPathItem(path)
                pen = QPen(self._palette.pipe_color)
                pen.setWidth(self._palette.pipe_width_px)
                pen.setCosmetic(True)
                pen.setCapStyle(Qt.PenCapStyle.RoundCap)
                pen.setJoinStyle(Qt.PenJoinStyle.RoundJoin)
                path_item.setPen(pen)
                path_item.setBrush(QBrush(Qt.GlobalColor.transparent))
                path_item.setZValue(20)
                scene.addItem(path_item)
                self._pipe_items.append(path_item)


# Backward-compatible alias for older imports.
HighlightOverlayManager = SceneHighlightController
