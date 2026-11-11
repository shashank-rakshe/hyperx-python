"""SVG background management for DiagramScene."""

from __future__ import annotations

import xml.etree.ElementTree as ET
from dataclasses import dataclass

from PySide6.QtCore import QByteArray
from PySide6.QtSvg import QSvgRenderer
from PySide6.QtSvgWidgets import QGraphicsSvgItem

from .geometry import scale_svg_strokes


@dataclass
class SvgBackgroundData:
    """Container for parsed/renderable SVG background state."""

    svg_bytes: bytes
    renderer: QSvgRenderer
    svg_item: QGraphicsSvgItem
    svg_root: ET.Element | None
    id_to_elem: dict[str, ET.Element]


def build_svg_background(svg_content: str) -> SvgBackgroundData:
    """Build background renderer/item and parsed SVG tree from raw content."""
    raw_bytes = svg_content.encode("utf-8")
    svg_bytes = scale_svg_strokes(raw_bytes)
    renderer = QSvgRenderer(QByteArray(svg_bytes))
    svg_item = QGraphicsSvgItem()
    svg_item.setSharedRenderer(renderer)

    # Coordinate convention:
    # - Scene coordinates are SVG document/viewBox coordinates.
    # - Place SVG item at viewBox origin so overlays/items can use raw
    #   document-space coordinates directly with no extra offset correction.
    vb = renderer.viewBoxF()
    svg_item.setPos(vb.x(), vb.y())
    svg_item.setZValue(0)

    try:
        svg_root = ET.fromstring(svg_bytes.decode("utf-8"))
    except ET.ParseError:
        svg_root = None

    id_to_elem: dict[str, ET.Element] = {}
    if svg_root is not None:
        for elem in svg_root.iter():
            elem_id = elem.get("id")
            if elem_id:
                id_to_elem[elem_id] = elem

    return SvgBackgroundData(
        svg_bytes=svg_bytes,
        renderer=renderer,
        svg_item=svg_item,
        svg_root=svg_root,
        id_to_elem=id_to_elem,
    )
