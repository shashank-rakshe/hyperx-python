"""Command bar widget for DEXPI Studio.

A single-row grouped command bar that replaces the old tab-based ribbon.

Sections (left → right):
    File · Tools · Export · View · Panels

Each section shows compact icon-over-label buttons with a subtle group
label underneath, separated by 1 px dividers.
"""

from __future__ import annotations

import math
from collections.abc import Callable
from typing import TYPE_CHECKING

from PySide6.QtCore import QPointF, QRectF, QSize, Qt
from PySide6.QtGui import (
    QBrush,
    QColor,
    QIcon,
    QPainter,
    QPainterPath,
    QPen,
    QPixmap,
)
from PySide6.QtWidgets import (
    QFrame,
    QHBoxLayout,
    QLabel,
    QMenu,
    QSizePolicy,
    QToolButton,
    QVBoxLayout,
    QWidget,
)

if TYPE_CHECKING:
    from dexpi_studio.gui.main_window import MainWindow

# ── Design tokens ─────────────────────────────────────────────────────
_ICON_SZ = 20  # icon pixmap edge length (px)
_BTN_W = 60  # button min-width  (px)
_BTN_H = 54  # button total height (px)  — icon + text

# Ribbon is the primary command surface — bright white bg
_BAR_BG = "#ffffff"
_BAR_BORDER = "#d8dee9"  # bottom border under ribbon
_SEP_COLOR = "#d8dee9"  # vertical group dividers

_ACCENT = "#003499"
_HOVER = "#e8f1ff"
_PRESS = "#dbeafe"
_TEXT = "#1c1c2e"
_MUTED = "#9097aa"  # group caption labels
_ICON_C = "#2a2d3e"

_BTN_QSS = f"""
QToolButton {{
    border: 1px solid transparent;
    border-radius: 8px;
    padding: 5px 8px;
    min-width: {_BTN_W}px;
    font-size: 11px;
    font-family: "Segoe UI", Arial, sans-serif;
    color: {_TEXT};
    background: transparent;
}}
QToolButton:hover {{
    background: {_HOVER};
    border: 1px solid #c7dcff;
    color: {_ACCENT};
}}
QToolButton:pressed {{
    background: {_PRESS};
}}
QToolButton:disabled {{
    color: #b8bcc8;
}}
"""

# ─────────────────────────────────────────────────────────────────────
# Icon factory
# ─────────────────────────────────────────────────────────────────────

DrawFn = Callable[[QPainter, QRectF], None]


def _make_icon(draw_fn: DrawFn, sz: int = _ICON_SZ) -> QIcon:
    """Render *draw_fn* onto a transparent QPixmap and wrap in QIcon."""
    pix = QPixmap(sz, sz)
    pix.fill(Qt.GlobalColor.transparent)
    p = QPainter(pix)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    margin = max(1, sz // 10)
    draw_fn(p, QRectF(margin, margin, sz - 2 * margin, sz - 2 * margin))
    p.end()
    return QIcon(pix)


def _pen(color: str = _ICON_C, w: float = 1.7) -> QPen:
    pen = QPen(QColor(color))
    pen.setWidthF(w)
    pen.setCapStyle(Qt.PenCapStyle.RoundCap)
    pen.setJoinStyle(Qt.PenJoinStyle.RoundJoin)
    return pen


# ── Individual icon draw functions ────────────────────────────────────


def _draw_open(p: QPainter, r: QRectF) -> None:
    """Folder with an upward arrow."""
    p.setPen(_pen())
    tab_h = r.height() * 0.26
    body_y = r.top() + tab_h * 0.7
    body = QRectF(r.left(), body_y, r.width(), r.height() - tab_h * 0.7)
    p.drawRoundedRect(body, 1.5, 1.5)
    tab = QRectF(r.left(), r.top(), r.width() * 0.44, tab_h + 2)
    p.drawRoundedRect(tab, 1.5, 1.5)
    # upload arrow inside body
    cx = body.center().x()
    cy = body.center().y() + 1
    aw = r.width() * 0.18
    ah = body.height() * 0.34
    p.drawLine(QPointF(cx, cy + ah), QPointF(cx, cy - ah))
    p.drawLine(QPointF(cx - aw, cy - ah + aw * 0.85), QPointF(cx, cy - ah))
    p.drawLine(QPointF(cx + aw, cy - ah + aw * 0.85), QPointF(cx, cy - ah))


def _draw_close(p: QPainter, r: QRectF) -> None:
    """X mark."""
    p.setPen(_pen(w=2.0))
    m = r.width() * 0.12
    p.drawLine(QPointF(r.left() + m, r.top() + m), QPointF(r.right() - m, r.bottom() - m))
    p.drawLine(QPointF(r.right() - m, r.top() + m), QPointF(r.left() + m, r.bottom() - m))


def _draw_reload(p: QPainter, r: QRectF) -> None:
    """Circular reload arrow."""
    p.setPen(_pen(w=1.8))
    arc_r = QRectF(
        r.left() + r.width() * 0.13,
        r.top() + r.height() * 0.13,
        r.width() * 0.74,
        r.height() * 0.74,
    )
    p.drawArc(arc_r, 35 * 16, 300 * 16)
    angle_rad = math.radians(35)
    cx_a = arc_r.center().x()
    cy_a = arc_r.center().y()
    rx = arc_r.width() / 2
    ry = arc_r.height() / 2
    tip = QPointF(cx_a + rx * math.cos(angle_rad), cy_a - ry * math.sin(angle_rad))
    sz = r.width() * 0.18
    p.drawLine(tip, QPointF(tip.x() + sz, tip.y() - sz * 0.15))
    p.drawLine(tip, QPointF(tip.x() - sz * 0.2, tip.y() - sz * 0.95))


def _draw_validate(p: QPainter, r: QRectF) -> None:
    """Bold checkmark."""
    p.setPen(_pen(w=2.3))
    p.drawLine(
        QPointF(r.left() + r.width() * 0.08, r.top() + r.height() * 0.54),
        QPointF(r.left() + r.width() * 0.41, r.bottom() - r.height() * 0.10),
    )
    p.drawLine(
        QPointF(r.left() + r.width() * 0.41, r.bottom() - r.height() * 0.10),
        QPointF(r.right() - r.width() * 0.05, r.top() + r.height() * 0.12),
    )


def _draw_diff(p: QPainter, r: QRectF) -> None:
    """Two overlapping document outlines with a delta symbol."""
    p.setPen(_pen(w=1.3))
    # back document (offset slightly right/down)
    off = r.width() * 0.12
    fold = r.width() * 0.24
    br = QRectF(r.left() + off, r.top() + off, r.width() - off, r.height() - off)
    back = QPainterPath()
    back.moveTo(br.left(), br.top())
    back.lineTo(br.right() - fold, br.top())
    back.lineTo(br.right(), br.top() + fold)
    back.lineTo(br.right(), br.bottom())
    back.lineTo(br.left(), br.bottom())
    back.closeSubpath()
    p.drawPath(back)
    # front document (offset left/up)
    fr = QRectF(r.left(), r.top(), r.width() - off, r.height() - off)
    front = QPainterPath()
    front.moveTo(fr.left(), fr.top())
    front.lineTo(fr.right() - fold, fr.top())
    front.lineTo(fr.right(), fr.top() + fold)
    front.lineTo(fr.right(), fr.bottom())
    front.lineTo(fr.left(), fr.bottom())
    front.closeSubpath()
    p.drawPath(front)
    # delta (Δ) in centre of front doc
    p.setPen(_pen(w=1.1))
    cx = fr.center().x() - off * 0.3
    cy = fr.center().y() - off * 0.3
    dw = fr.width() * 0.28
    dh = fr.height() * 0.30
    p.drawLine(QPointF(cx, cy - dh), QPointF(cx - dw, cy + dh))
    p.drawLine(QPointF(cx, cy - dh), QPointF(cx + dw, cy + dh))
    p.drawLine(QPointF(cx - dw, cy + dh), QPointF(cx + dw, cy + dh))


def _draw_export(p: QPainter, r: QRectF) -> None:
    """Box with arrow pointing up-right (export)."""
    p.setPen(_pen())
    box_top = r.top() + r.height() * 0.42
    box = QRectF(r.left(), box_top, r.width(), r.bottom() - box_top)
    p.drawRect(box)
    cx = r.center().x()
    tip_y = r.top() + r.height() * 0.04
    base_y = box_top
    aw = r.width() * 0.20
    p.drawLine(QPointF(cx, base_y + 1), QPointF(cx, tip_y))
    p.drawLine(QPointF(cx - aw, tip_y + aw * 0.95), QPointF(cx, tip_y))
    p.drawLine(QPointF(cx + aw, tip_y + aw * 0.95), QPointF(cx, tip_y))


def _draw_image_export(p: QPainter, r: QRectF) -> None:
    """Image export icon: picture frame + outward arrow."""
    p.setPen(_pen())
    frame = QRectF(r.left(), r.top() + r.height() * 0.18, r.width(), r.height() * 0.72)
    p.drawRoundedRect(frame, 1.5, 1.5)
    # mountain line
    p.drawLine(
        QPointF(frame.left() + frame.width() * 0.10, frame.bottom() - frame.height() * 0.20),
        QPointF(frame.left() + frame.width() * 0.40, frame.bottom() - frame.height() * 0.45),
    )
    p.drawLine(
        QPointF(frame.left() + frame.width() * 0.40, frame.bottom() - frame.height() * 0.45),
        QPointF(frame.left() + frame.width() * 0.66, frame.bottom() - frame.height() * 0.22),
    )
    # sun dot
    p.setBrush(QBrush(QColor(_ICON_C)))
    p.setPen(Qt.PenStyle.NoPen)
    p.drawEllipse(
        QPointF(frame.left() + frame.width() * 0.78, frame.top() + frame.height() * 0.26),
        frame.width() * 0.06,
        frame.width() * 0.06,
    )
    p.setPen(_pen())
    # export arrow at top-right
    tip = QPointF(r.right() - r.width() * 0.04, r.top() + r.height() * 0.06)
    tail = QPointF(r.right() - r.width() * 0.34, r.top() + r.height() * 0.36)
    p.drawLine(tail, tip)
    p.drawLine(QPointF(tip.x() - r.width() * 0.18, tip.y()), tip)
    p.drawLine(QPointF(tip.x(), tip.y() + r.height() * 0.18), tip)


def _draw_graph_export(p: QPainter, r: QRectF) -> None:
    """Network/graph icon with connected nodes."""
    p.setPen(_pen())

    n1 = QPointF(r.left() + r.width() * 0.20, r.top() + r.height() * 0.28)
    n2 = QPointF(r.left() + r.width() * 0.52, r.top() + r.height() * 0.20)
    n3 = QPointF(r.right() - r.width() * 0.18, r.top() + r.height() * 0.42)
    n4 = QPointF(r.left() + r.width() * 0.34, r.bottom() - r.height() * 0.20)
    n5 = QPointF(r.right() - r.width() * 0.24, r.bottom() - r.height() * 0.16)

    for a, b in [(n1, n2), (n2, n3), (n1, n4), (n2, n4), (n3, n5), (n4, n5)]:
        p.drawLine(a, b)

    p.setBrush(QBrush(QColor(_ICON_C)))
    p.setPen(Qt.PenStyle.NoPen)
    radius = max(1.8, r.width() * 0.055)
    for n in (n1, n2, n3, n4, n5):
        p.drawEllipse(n, radius, radius)


def _draw_fit(p: QPainter, r: QRectF) -> None:
    """Four inward-pointing corner arrows."""
    p.setPen(_pen())
    arm = r.width() * 0.30
    gap = r.width() * 0.14
    corners = [
        (r.left(), r.top(), +1, +1),
        (r.right(), r.top(), -1, +1),
        (r.left(), r.bottom(), +1, -1),
        (r.right(), r.bottom(), -1, -1),
    ]
    for ox, oy, dx, dy in corners:
        p.drawLine(QPointF(ox, oy), QPointF(ox + dx * arm, oy))
        p.drawLine(QPointF(ox, oy), QPointF(ox, oy + dy * arm))
    # centre crosshair (tiny)
    cx, cy = r.center().x(), r.center().y()
    p.drawLine(QPointF(cx - gap, cy), QPointF(cx + gap, cy))
    p.drawLine(QPointF(cx, cy - gap), QPointF(cx, cy + gap))


def _draw_zoom_in(p: QPainter, r: QRectF) -> None:
    """Magnifier + plus."""
    p.setPen(_pen())
    lens_r = QRectF(r.left(), r.top(), r.width() * 0.70, r.height() * 0.70)
    p.drawEllipse(lens_r)
    hx = lens_r.right() - lens_r.width() * 0.14
    hy = lens_r.bottom() - lens_r.height() * 0.14
    p.drawLine(QPointF(hx, hy), QPointF(r.right(), r.bottom()))
    cx, cy = lens_r.center().x(), lens_r.center().y()
    s = lens_r.width() * 0.22
    p.drawLine(QPointF(cx - s, cy), QPointF(cx + s, cy))
    p.drawLine(QPointF(cx, cy - s), QPointF(cx, cy + s))


def _draw_zoom_out(p: QPainter, r: QRectF) -> None:
    """Magnifier + minus."""
    p.setPen(_pen())
    lens_r = QRectF(r.left(), r.top(), r.width() * 0.70, r.height() * 0.70)
    p.drawEllipse(lens_r)
    hx = lens_r.right() - lens_r.width() * 0.14
    hy = lens_r.bottom() - lens_r.height() * 0.14
    p.drawLine(QPointF(hx, hy), QPointF(r.right(), r.bottom()))
    cx, cy = lens_r.center().x(), lens_r.center().y()
    s = lens_r.width() * 0.22
    p.drawLine(QPointF(cx - s, cy), QPointF(cx + s, cy))


def _draw_reset_zoom(p: QPainter, r: QRectF) -> None:
    """Circular refresh arrow."""
    p.setPen(_pen(w=1.8))
    arc_r = QRectF(
        r.left() + r.width() * 0.10,
        r.top() + r.height() * 0.10,
        r.width() * 0.78,
        r.height() * 0.78,
    )
    p.drawArc(arc_r, 40 * 16, 290 * 16)
    # arrowhead at end of arc (angle=40° in Qt convention = standard 40°)
    angle_rad = math.radians(40)
    cx_a = arc_r.center().x()
    cy_a = arc_r.center().y()
    rx = arc_r.width() / 2
    ry = arc_r.height() / 2
    tip = QPointF(cx_a + rx * math.cos(angle_rad), cy_a - ry * math.sin(angle_rad))
    sz = r.width() * 0.20
    p.drawLine(tip, QPointF(tip.x() + sz, tip.y() - sz * 0.3))
    p.drawLine(tip, QPointF(tip.x() - sz * 0.25, tip.y() - sz))


def _draw_tree(p: QPainter, r: QRectF) -> None:
    """Hierarchy / tree branching icon."""
    p.setPen(_pen(w=1.5))
    nr = r.width() * 0.14  # node radius
    root = QPointF(r.center().x(), r.top() + nr)
    c_l = QPointF(r.left() + nr, r.bottom() - nr)
    c_r = QPointF(r.right() - nr, r.bottom() - nr)
    mid_y = r.top() + r.height() * 0.52
    p.drawLine(root, QPointF(root.x(), mid_y))
    p.drawLine(QPointF(c_l.x(), mid_y), QPointF(c_r.x(), mid_y))
    p.drawLine(QPointF(c_l.x(), mid_y), QPointF(c_l.x(), c_l.y() - nr))
    p.drawLine(QPointF(c_r.x(), mid_y), QPointF(c_r.x(), c_r.y() - nr))
    for pt in [root, c_l, c_r]:
        p.drawEllipse(pt, nr, nr)


def _draw_properties(p: QPainter, r: QRectF) -> None:
    """Three horizontal lines (list / properties)."""
    p.setPen(_pen(w=1.9))
    for frac in [0.25, 0.52, 0.78]:
        y = r.top() + r.height() * frac
        p.drawLine(QPointF(r.left(), y), QPointF(r.right(), y))


def _draw_messages(p: QPainter, r: QRectF) -> None:
    """Chat-bubble / messages icon."""
    p.setPen(_pen(w=1.5))
    bubble = QRectF(r.left(), r.top(), r.width(), r.height() * 0.76)
    p.drawRoundedRect(bubble, 3, 3)
    tx = r.left() + r.width() * 0.22
    p.drawLine(QPointF(tx, bubble.bottom()), QPointF(tx - r.width() * 0.14, r.bottom()))
    p.drawLine(QPointF(tx, bubble.bottom()), QPointF(tx + r.width() * 0.10, bubble.bottom()))


def _draw_background_toggle(p: QPainter, r: QRectF) -> None:
    """Layered rectangles indicating background visibility control."""
    p.setPen(_pen(w=1.5))
    back = QRectF(
        r.left() + r.width() * 0.10,
        r.top() + r.height() * 0.20,
        r.width() * 0.72,
        r.height() * 0.58,
    )
    front = QRectF(
        r.left() + r.width() * 0.24,
        r.top() + r.height() * 0.34,
        r.width() * 0.66,
        r.height() * 0.58,
    )
    p.drawRoundedRect(back, 1.5, 1.5)
    p.drawRoundedRect(front, 1.5, 1.5)
    p.drawLine(
        QPointF(front.left() + front.width() * 0.14, front.top() + front.height() * 0.50),
        QPointF(front.right() - front.width() * 0.14, front.top() + front.height() * 0.50),
    )


def _draw_about(p: QPainter, r: QRectF) -> None:
    """Circle with 'i'."""
    p.setPen(_pen(w=1.5))
    p.drawEllipse(r)
    cx, cy = r.center().x(), r.center().y()
    dot_r = r.width() * 0.09
    p.setBrush(QBrush(QColor(_ICON_C)))
    p.setPen(Qt.PenStyle.NoPen)
    p.drawEllipse(QPointF(cx, cy - r.height() * 0.20), dot_r, dot_r)
    p.setPen(_pen(w=1.6))
    p.drawLine(QPointF(cx, cy - r.height() * 0.05), QPointF(cx, cy + r.height() * 0.28))


def _draw_settings(p: QPainter, r: QRectF) -> None:
    """Simple gear/settings icon."""
    p.setPen(_pen(w=1.5))
    c = r.center()
    outer = min(r.width(), r.height()) * 0.42
    inner = outer * 0.42

    for i in range(8):
        a = math.radians(i * 45)
        x1 = c.x() + math.cos(a) * (outer * 0.72)
        y1 = c.y() + math.sin(a) * (outer * 0.72)
        x2 = c.x() + math.cos(a) * outer
        y2 = c.y() + math.sin(a) * outer
        p.drawLine(QPointF(x1, y1), QPointF(x2, y2))

    p.drawEllipse(c, outer * 0.66, outer * 0.66)
    p.drawEllipse(c, inner, inner)


def _draw_file_format(p: QPainter, r: QRectF) -> None:
    """Generic document with folded corner."""
    p.setPen(_pen(w=1.5))
    fold = r.width() * 0.28
    path = QPainterPath()
    path.moveTo(r.left(), r.top())
    path.lineTo(r.right() - fold, r.top())
    path.lineTo(r.right(), r.top() + fold)
    path.lineTo(r.right(), r.bottom())
    path.lineTo(r.left(), r.bottom())
    path.closeSubpath()
    p.drawPath(path)
    p.drawLine(QPointF(r.right() - fold, r.top()), QPointF(r.right() - fold, r.top() + fold))
    p.drawLine(QPointF(r.right() - fold, r.top() + fold), QPointF(r.right(), r.top() + fold))
    p.setPen(_pen(w=1.2))
    for frac in [0.55, 0.70, 0.83]:
        y = r.top() + r.height() * frac
        p.drawLine(
            QPointF(r.left() + r.width() * 0.18, y), QPointF(r.right() - r.width() * 0.18, y)
        )


def _draw_dexpi_export(p: QPainter, r: QRectF) -> None:
    """Document with folded corner and a downward export arrow."""
    p.setPen(_pen(w=1.5))
    fold = r.width() * 0.28
    doc_bottom = r.bottom() - r.height() * 0.26
    path = QPainterPath()
    path.moveTo(r.left(), r.top())
    path.lineTo(r.right() - fold, r.top())
    path.lineTo(r.right(), r.top() + fold)
    path.lineTo(r.right(), doc_bottom)
    path.lineTo(r.left(), doc_bottom)
    path.closeSubpath()
    p.drawPath(path)
    p.drawLine(QPointF(r.right() - fold, r.top()), QPointF(r.right() - fold, r.top() + fold))
    p.drawLine(QPointF(r.right() - fold, r.top() + fold), QPointF(r.right(), r.top() + fold))
    # downward arrow below document
    cx = r.center().x()
    arr_top = doc_bottom + r.height() * 0.04
    arr_bot = r.bottom() - r.height() * 0.02
    aw = r.width() * 0.18
    p.setPen(_pen(w=1.5))
    p.drawLine(QPointF(cx, arr_top), QPointF(cx, arr_bot))
    p.drawLine(QPointF(cx - aw, arr_bot - aw * 0.9), QPointF(cx, arr_bot))
    p.drawLine(QPointF(cx + aw, arr_bot - aw * 0.9), QPointF(cx, arr_bot))


# ─────────────────────────────────────────────────────────────────────
# Command button
# ─────────────────────────────────────────────────────────────────────


class _CmdButton(QToolButton):
    """A compact icon-over-label toolbar button."""

    def __init__(
        self,
        label: str,
        draw_fn: DrawFn,
        tooltip: str = "",
        callback: Callable | None = None,
        menu_items: list[tuple[str, Callable[[], None], str | None]] | None = None,
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(parent)
        self.setText(label)
        self.setToolTip(tooltip or label)
        self.setIcon(_make_icon(draw_fn))
        self.setIconSize(QSize(_ICON_SZ, _ICON_SZ))
        self.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonTextUnderIcon)
        self.setSizePolicy(QSizePolicy.Policy.Fixed, QSizePolicy.Policy.Fixed)
        self.setStyleSheet(_BTN_QSS)
        if callback is not None:
            self.clicked.connect(callback)
        if menu_items:
            menu = QMenu(self)
            for text, cb, tip in menu_items:
                action = menu.addAction(text)
                if tip:
                    action.setToolTip(tip)
                    action.setStatusTip(tip)
                action.triggered.connect(cb)
            self.setMenu(menu)
            self.setPopupMode(QToolButton.ToolButtonPopupMode.MenuButtonPopup)


# ─────────────────────────────────────────────────────────────────────
# Group widget
# ─────────────────────────────────────────────────────────────────────


class _Group(QWidget):
    """A labelled cluster of _CmdButtons with a muted caption below."""

    def __init__(self, title: str, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(4, 4, 4, 0)
        layout.setSpacing(0)

        self._btn_row = QHBoxLayout()
        self._btn_row.setSpacing(1)
        self._btn_row.setAlignment(Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter)
        layout.addLayout(self._btn_row)

        lbl = QLabel(title.upper())
        lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
        lbl.setStyleSheet(
            f"color: {_MUTED}; font-size: 9px; font-weight: 600; letter-spacing: 0.8px;"
            f" padding: 3px 0 4px 0; font-family: 'Segoe UI', Arial, sans-serif;"
            f" border-top: 1px solid {_SEP_COLOR}; margin-top: 3px;"
        )
        layout.addWidget(lbl)

    def add(self, btn: _CmdButton) -> _CmdButton:
        self._btn_row.addWidget(btn)
        return btn


# ─────────────────────────────────────────────────────────────────────
# Vertical group separator
# ─────────────────────────────────────────────────────────────────────


def _vsep(parent: QWidget | None = None) -> QFrame:
    sep = QFrame(parent)
    sep.setFrameShape(QFrame.Shape.VLine)
    sep.setFrameShadow(QFrame.Shadow.Plain)
    sep.setSizePolicy(QSizePolicy.Policy.Fixed, QSizePolicy.Policy.Expanding)
    sep.setFixedWidth(1)
    sep.setStyleSheet(f"background: {_SEP_COLOR}; margin: 6px 6px;")
    return sep


# ─────────────────────────────────────────────────────────────────────
# Public widget
# ─────────────────────────────────────────────────────────────────────


class RibbonWidget(QWidget):
    """Single-row command bar with grouped actions.

    Parameters
    ----------
    window : MainWindow
        The main application window whose action slots are wired up here.
    """

    def __init__(self, window: MainWindow, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._window = window
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        self.setStyleSheet(
            f"RibbonWidget {{ background: {_BAR_BG};"
            f" border-top: 1px solid {_SEP_COLOR};"
            f" border-bottom: 2px solid {_BAR_BORDER}; }}"
        )

        root = QHBoxLayout(self)
        root.setContentsMargins(8, 0, 8, 0)
        root.setSpacing(0)

        self._build_groups(root)
        root.addStretch()

    # ------------------------------------------------------------------
    # Build helpers
    # ------------------------------------------------------------------

    def _build_groups(self, layout: QHBoxLayout) -> None:
        w = self._window

        def _open_svg_panel_from_ribbon() -> None:
            w.open_external_svg_panel()

        # ── File ──────────────────────────────────────────────────────
        file_grp = _Group("File")
        open_menu: list[tuple[str, Callable[[], None], str | None]] = [
            ("DEXPI 2.0 (.xml / .json)", w.open_file, "Open a DEXPI 2.0.1 XML or JSON file"),
            (
                "ProteusXML (DEXPI 1.3, beta)",
                w.open_proteus_file,
                "Open a ProteusXML file and map it to DEXPI 2.0",
            ),
        ]
        file_grp.add(
            _CmdButton(
                "Open",
                _draw_open,
                "Open DEXPI File  (Ctrl+O)",
                w.open_file,
                menu_items=open_menu,
            )
        )
        file_grp.add(_CmdButton("Reload", _draw_reload, "Reload current file  (F5)", w.reload_file))
        file_grp.add(_CmdButton("Close", _draw_close, "Close current file  (Ctrl+W)", w.close_file))
        layout.addWidget(file_grp)
        layout.addWidget(_vsep())

        # ── Tools ─────────────────────────────────────────────────────
        tools_grp = _Group("Tools")
        tools_grp.add(
            _CmdButton(
                "Summary",
                _draw_properties,
                "Counts and tags of the model, as pydexpi info prints them",
                w.show_summary,
            )
        )
        tools_grp.add(
            _CmdButton("Validate", _draw_validate, "Validate / Check  (Ctrl+Shift+V)", w.validate)
        )
        tools_grp.add(
            _CmdButton("Diff", _draw_diff, "Compare against another DEXPI file", w.diff_file)
        )
        layout.addWidget(tools_grp)
        layout.addWidget(_vsep())

        # ── Export ────────────────────────────────────────────────────
        export_grp = _Group("Export")
        export_grp.add(
            _CmdButton("Export…", _draw_export, "Open export dialog  (Ctrl+E)", w.export_file)
        )

        caps_exports = list(w._capabilities.exports)  # type: ignore[attr-defined]
        image_exports = [
            exp
            for exp in caps_exports
            if exp.file_extension.lower() in {".png", ".svg", ".pdf"}
            or exp.name in {"Image PNG", "Image SVG", "Image PDF"}
        ]
        graph_exports = [
            exp
            for exp in caps_exports
            if exp.name in {"GraphML", "Neo4j CSV", "LLM Context"}
            or "graphml" in exp.callable_path.lower()
            or "neo4j" in exp.callable_path.lower()
        ]
        dexpi_exports = [
            e for e in caps_exports if e.name in {"DEXPI 2.0.1 XML", "DEXPI 2.0.1 JSON"}
        ]
        remaining_exports = [
            exp
            for exp in caps_exports
            if exp not in image_exports and exp not in graph_exports and exp not in dexpi_exports
        ]

        if image_exports:

            def _make_img_cb(name: str) -> Callable[[], None]:
                def _cb() -> None:
                    w.export_format(name)

                return _cb

            menu_items: list[tuple[str, Callable[[], None], str | None]] = []
            for exp in image_exports:
                menu_items.append((exp.name, _make_img_cb(exp.name), exp.description))

            export_grp.add(
                _CmdButton(
                    "Image",
                    _draw_image_export,
                    "Export image (PNG/SVG/PDF)",
                    callback=_make_img_cb(image_exports[0].name),
                    menu_items=menu_items,
                )
            )

        if graph_exports:

            def _make_graph_cb(name: str) -> Callable[[], None]:
                def _cb() -> None:
                    w.export_format(name)

                return _cb

            graph_menu_items: list[tuple[str, Callable[[], None], str | None]] = []
            for exp in graph_exports:
                graph_menu_items.append((exp.name, _make_graph_cb(exp.name), exp.description))

            export_grp.add(
                _CmdButton(
                    "Graph",
                    _draw_graph_export,
                    "Export the model graph (GraphML, Neo4j CSV or LLM context)",
                    callback=_make_graph_cb(graph_exports[0].name),
                    menu_items=graph_menu_items,
                )
            )

        if dexpi_exports:

            def _make_dexpi_cb(name: str) -> Callable[[], None]:
                def _cb() -> None:
                    w.export_format(name)

                return _cb

            dexpi_menu: list[tuple[str, Callable[[], None], str | None]] = [
                (exp.name, _make_dexpi_cb(exp.name), exp.description) for exp in dexpi_exports
            ]
            export_grp.add(
                _CmdButton(
                    "DEXPI 2.0",
                    _draw_dexpi_export,
                    "Export model as DEXPI 2.0 (XML or JSON)",
                    callback=_make_dexpi_cb(dexpi_exports[0].name),
                    menu_items=dexpi_menu,
                )
            )

        # Keep dedicated buttons for remaining non-image/non-graph exports. A name too long
        # for a ribbon button gets a short label; the tooltip says what it exports.
        short_labels = {"Git projection": "Projection"}
        for exp in remaining_exports:

            def _make_cb(name: str) -> Callable:
                def _cb() -> None:
                    w.export_format(name)

                return _cb

            export_grp.add(
                _CmdButton(
                    short_labels.get(exp.name, exp.name),
                    _draw_file_format,
                    exp.description,
                    _make_cb(exp.name),
                )
            )
        layout.addWidget(export_grp)
        layout.addWidget(_vsep())

        # ── View / Zoom ───────────────────────────────────────────────
        zoom_grp = _Group("Zoom")
        zoom_grp.add(
            _CmdButton("Fit", _draw_fit, "Fit diagram to window  (Ctrl+0)", w.fit_to_window)
        )
        zoom_grp.add(_CmdButton("In", _draw_zoom_in, "Zoom in  (Ctrl++)", w.zoom_in))
        zoom_grp.add(_CmdButton("Out", _draw_zoom_out, "Zoom out  (Ctrl+-)", w.zoom_out))
        zoom_grp.add(_CmdButton("Reset", _draw_reset_zoom, "Reset zoom  (Ctrl+1)", w.reset_zoom))
        layout.addWidget(zoom_grp)
        layout.addWidget(_vsep())

        # ── Panels ────────────────────────────────────────────────────
        panels_grp = _Group("Panels")
        panels_grp.add(_CmdButton("Tree", _draw_tree, "Toggle Model Tree", w.toggle_model_tree))
        panels_grp.add(
            _CmdButton("Properties", _draw_properties, "Toggle Properties", w.toggle_properties)
        )
        panels_grp.add(
            _CmdButton(
                "ChatP&ID",
                _draw_messages,
                "Open ChatP&ID",
                w.show_assistant_panel,
            )
        )
        panels_grp.add(_CmdButton("Issues", _draw_validate, "Toggle Issues", w.toggle_issues))
        panels_grp.add(_CmdButton("Logs", _draw_messages, "Toggle Logs", w.toggle_messages))
        panels_grp.add(
            _CmdButton(
                "SVG Panel",
                _draw_background_toggle,
                "Open rendered SVG in a detached window",
                _open_svg_panel_from_ribbon,
            )
        )
        layout.addWidget(panels_grp)
        layout.addWidget(_vsep())

        # ── Help ──────────────────────────────────────────────────────
        help_grp = _Group("Help")
        help_grp.add(
            _CmdButton(
                "Settings",
                _draw_settings,
                "ChatP&ID Settings",
                w.show_assistant_settings,
            )
        )
        help_grp.add(_CmdButton("About", _draw_about, "About DEXPI Studio", w.show_about))
        layout.addWidget(help_grp)
