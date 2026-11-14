"""The electrical symbol glyph library.

Every device kind has **several valid glyph variants**, because real drawing sets do
not agree on a single symbol — legends differ by office, era, and standard. Training on
one fixed glyph would overfit; the style sampler (:mod:`synthetic.style`) picks a
variant per kind per sample so the model sees the spread.

Contract that keeps ground truth exact: each glyph draws *entirely within* the square
cell ``[cx − s/2, cx + s/2] × [cy − s/2, cy + s/2]``. The renderer therefore knows the
symbol's bounding box from the placement alone — ``(cx, cy, s)`` — and never has to
read it back from pixels. Glyphs are schematic, not artwork; fidelity of the *box and
class* is what matters, not draughtsman-perfect symbology.
"""

from __future__ import annotations

import math
from collections.abc import Callable

from .canvas import Canvas, Color
from .model import DeviceKind

# (canvas, center_x, center_y, cell_size, line_weight, ink_color) -> None
GlyphFn = Callable[[Canvas, float, float, float, float, Color], None]


def _circle(
    cv: Canvas, cx: float, cy: float, r: float, w: float, c: Color, fill: Color | None = None
) -> None:
    cv.circle(cx, cy, r, weight=w, color=c, fill=fill)


# --- receptacles ------------------------------------------------------------------
def _duplex_a(cv: Canvas, cx: float, cy: float, s: float, w: float, c: Color) -> None:
    r = 0.42 * s
    _circle(cv, cx, cy, r, w, c)
    cv.line(cx, cy - r, cx, cy + r, weight=w, color=c)  # vertical bar (two devices)
    cv.line(cx - 0.18 * s, cy, cx - 0.04 * s, cy, weight=w, color=c)
    cv.line(cx + 0.04 * s, cy, cx + 0.18 * s, cy, weight=w, color=c)


def _duplex_b(cv: Canvas, cx: float, cy: float, s: float, w: float, c: Color) -> None:
    r = 0.42 * s
    _circle(cv, cx, cy, r, w, c)
    cv.line(cx - r, cy, cx + r, cy, weight=w, color=c)  # horizontal diameter
    cv.line(cx, cy - 0.18 * s, cx, cy - 0.04 * s, weight=w, color=c)


def _quad_a(cv: Canvas, cx: float, cy: float, s: float, w: float, c: Color) -> None:
    r = 0.30 * s
    _circle(cv, cx - 0.18 * s, cy, r, w, c)
    _circle(cv, cx + 0.18 * s, cy, r, w, c)
    cv.line(cx - 0.18 * s, cy, cx + 0.18 * s, cy, weight=w, color=c)


def _gfci_a(cv: Canvas, cx: float, cy: float, s: float, w: float, c: Color) -> None:
    _duplex_a(cv, cx, cy - 0.08 * s, 0.8 * s, w, c)
    cv.text(cx, cy + 0.34 * s, "GFI", size=0.22 * s, color=c)


# --- luminaires -------------------------------------------------------------------
def _light_x(cv: Canvas, cx: float, cy: float, s: float, w: float, c: Color) -> None:
    r = 0.42 * s
    _circle(cv, cx, cy, r, w, c)
    d = r * math.cos(math.pi / 4)
    cv.line(cx - d, cy - d, cx + d, cy + d, weight=w, color=c)
    cv.line(cx - d, cy + d, cx + d, cy - d, weight=w, color=c)


def _light_spokes(cv: Canvas, cx: float, cy: float, s: float, w: float, c: Color) -> None:
    r = 0.42 * s
    _circle(cv, cx, cy, r, w, c)
    cv.line(cx - r, cy, cx + r, cy, weight=w, color=c)
    cv.line(cx, cy - r, cx, cy + r, weight=w, color=c)


def _downlight(cv: Canvas, cx: float, cy: float, s: float, w: float, c: Color) -> None:
    _circle(cv, cx, cy, 0.42 * s, w, c)
    _circle(cv, cx, cy, 0.16 * s, w, c, fill=c)


def _wall_light(cv: Canvas, cx: float, cy: float, s: float, w: float, c: Color) -> None:
    r = 0.36 * s
    _circle(cv, cx, cy, r, w, c)
    cv.line(cx - r, cy + r, cx + r, cy + r, weight=w, color=c)  # the wall it mounts on
    cv.line(cx, cy, cx, cy + r, weight=w, color=c)


# --- switches ---------------------------------------------------------------------
def _switch_s(cv: Canvas, cx: float, cy: float, s: float, w: float, c: Color) -> None:
    cv.text(cx, cy, "S", size=0.6 * s, color=c)


def _switch_toggle(cv: Canvas, cx: float, cy: float, s: float, w: float, c: Color) -> None:
    cv.line(cx - 0.35 * s, cy + 0.25 * s, cx + 0.1 * s, cy - 0.3 * s, weight=w, color=c)
    cv.circle(cx - 0.35 * s, cy + 0.25 * s, 0.06 * s, weight=w, color=c, fill=c)


def _switch_3way(cv: Canvas, cx: float, cy: float, s: float, w: float, c: Color) -> None:
    cv.text(cx - 0.08 * s, cy, "S", size=0.6 * s, color=c)
    cv.text(cx + 0.25 * s, cy + 0.12 * s, "3", size=0.32 * s, color=c)


# --- junction box -----------------------------------------------------------------
def _jbox_filled(cv: Canvas, cx: float, cy: float, s: float, w: float, c: Color) -> None:
    h = 0.32 * s
    cv.rect(cx - h, cy - h, cx + h, cy + h, weight=w, color=c, fill=c)


def _jbox_j(cv: Canvas, cx: float, cy: float, s: float, w: float, c: Color) -> None:
    h = 0.36 * s
    cv.rect(cx - h, cy - h, cx + h, cy + h, weight=w, color=c)
    cv.text(cx, cy, "J", size=0.4 * s, color=c)


#: The variants available per device kind. The style sampler chooses an index.
GLYPHS: dict[DeviceKind, list[GlyphFn]] = {
    DeviceKind.DUPLEX_RECEPTACLE: [_duplex_a, _duplex_b],
    DeviceKind.QUAD_RECEPTACLE: [_quad_a],
    DeviceKind.GFCI_RECEPTACLE: [_gfci_a],
    DeviceKind.LIGHT_FIXTURE: [_light_x, _light_spokes],
    DeviceKind.RECESSED_DOWNLIGHT: [_downlight],
    DeviceKind.WALL_LIGHT: [_wall_light],
    DeviceKind.SINGLE_POLE_SWITCH: [_switch_s, _switch_toggle],
    DeviceKind.THREE_WAY_SWITCH: [_switch_3way],
    DeviceKind.JUNCTION_BOX: [_jbox_filled, _jbox_j],
}


def n_variants(kind: DeviceKind) -> int:
    """How many glyph variants exist for ``kind`` (always ≥ 1)."""
    return len(GLYPHS[kind])


def draw_symbol(
    cv: Canvas,
    kind: DeviceKind,
    cx: float,
    cy: float,
    s: float,
    *,
    variant: int,
    weight: float,
    color: Color,
) -> None:
    """Draw ``kind``'s glyph (variant ``variant``) centered at (cx,cy) in cell side ``s``.

    The drawn ink stays within the ``s``-sided cell centered at (cx,cy); that cell is
    the symbol's ground-truth bounding box (computed by the renderer, not measured here).
    """
    variants = GLYPHS[kind]
    variants[variant % len(variants)](cv, cx, cy, s, weight, color)
