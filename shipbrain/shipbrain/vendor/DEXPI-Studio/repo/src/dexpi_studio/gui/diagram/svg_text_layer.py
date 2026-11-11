"""Text-layer helpers for rendering SVG labels in the diagram scene."""

from __future__ import annotations

import math

from PySide6.QtCore import Qt
from PySide6.QtGui import QBrush, QFont, QPen
from PySide6.QtWidgets import QGraphicsSimpleTextItem

SvgTextLabel = tuple[str, float, float, object, float, str, str, float]


def create_text_item(label: SvgTextLabel) -> QGraphicsSimpleTextItem:
    """Create a configured text graphics item from extracted SVG label data."""
    text, tx, ty, color, size, anchor, baseline, rotation_deg = label
    label_item = QGraphicsSimpleTextItem(text)
    font = QFont()
    base_px = 100
    font.setPixelSize(base_px)
    label_item.setFont(font)
    label_item.setBrush(QBrush(color))
    label_item.setPen(QPen(Qt.GlobalColor.transparent))
    target_size = max(float(size), 0.01)
    scale = target_size / float(base_px)

    br = label_item.boundingRect()
    anchor_value = (anchor or "start").strip().lower()
    if anchor_value in {"middle", "center"}:
        anchor_shift = -(br.x() + (br.width() * 0.5))
    elif anchor_value in {"end", "right"}:
        anchor_shift = -(br.x() + br.width())
    else:
        anchor_shift = 0.0

    baseline_value = (baseline or "alphabetic").strip().lower()
    if baseline_value in {"middle", "central"}:
        baseline_shift = -(br.y() + (br.height() * 0.5))
    elif baseline_value in {"hanging", "text-before-edge", "before-edge", "top"}:
        baseline_shift = -br.y()
    elif baseline_value in {
        "text-after-edge",
        "after-edge",
        "ideographic",
        "bottom",
    }:
        baseline_shift = -(br.y() + br.height())
    else:
        baseline_shift = 0.0

    label_item.setScale(scale)
    rad = math.radians(rotation_deg)
    sx = anchor_shift * scale
    sy = baseline_shift * scale
    dx = (sx * math.cos(rad)) - (sy * math.sin(rad))
    dy = (sx * math.sin(rad)) + (sy * math.cos(rad))
    label_item.setPos(tx + dx, ty + dy)
    label_item.setRotation(rotation_deg)
    label_item.setAcceptedMouseButtons(Qt.MouseButton.NoButton)
    label_item.setAcceptHoverEvents(False)
    label_item.setZValue(12)
    return label_item
