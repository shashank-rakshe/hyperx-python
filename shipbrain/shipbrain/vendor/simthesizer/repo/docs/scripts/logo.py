"""Generate the Simthesizer logo files in docs/static/img/.

The mark is an S traced through two fused hexagonal rings, a molecule being
synthesized: the S's bonds are solid, the bonds still forming are dashed. In
the wordmark the mark replaces the S of "Simthesizer", sized to the font's own
S. Text is converted to outlines so the files render without the web font.

Usage (fonts: Bricolage Grotesque variable TTF from google/fonts, OFL):

    uv run --no-project --with fonttools --with uharfbuzz \
        python docs/scripts/logo.py BricolageGrotesque.ttf
"""

import math
import sys
from pathlib import Path

import uharfbuzz as hb
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

OUT = Path(__file__).resolve().parent.parent / "static" / "img"
AXES = {"wght": 800, "opsz": 96, "wdth": 100}
TRACKING = -0.035  # em, matches the site's heading letter-spacing

# Brand colors are the same on any background; only the text follows the theme.
SIGNAL, TRACE = "#2DD4BF", "#FFB224"
TEXT = {"dark": "#E6E8EE", "light": "#1A1D26"}
TILE = "#0B0D12"


def molecule(stretch, r=12.5):
    """Vertices of two fused flat-top hexagons, widened by stretch; the S path and the rest."""
    h = r * math.sin(math.radians(60))
    v = lambda cy, a: (stretch * r * math.cos(math.radians(a)), cy + r * math.sin(math.radians(a)))
    t = {a: v(-h, a) for a in range(0, 360, 60)}
    b = {a: v(h, a) for a in range(0, 360, 60)}
    s = [t[300], t[240], t[180], t[120], t[60], b[0], b[60], b[120]]
    forming = [(t[300], t[0]), (t[0], t[60]), (b[240], b[180]), (b[180], b[120])]
    return s, forming, [t[0], b[180]]


def shorten(p, q, a, b):
    """Segment p-q with a removed at p's end and b at q's end."""
    dx, dy = q[0] - p[0], q[1] - p[1]
    n = math.hypot(dx, dy)
    return (p[0] + dx * a / n, p[1] + dy * a / n), (q[0] - dx * b / n, q[1] - dy * b / n)


STROKE, NODE = 7.6, 3.8
PAD = NODE + STROKE * 0.55 / 2  # ring outer radius: how far ink extends past a vertex


def fit_stretch(aspect, r=12.5):
    """Widening that gives the mark's ink box the given width/height ratio."""
    height = 4 * r * math.sin(math.radians(60)) + 2 * PAD
    return (aspect * height - 2 * PAD) / (2 * r)


def mark_svg(signal, trace, stretch, bond=2.4):
    """The mark in its own coordinates (y down, centered on 0,0), with bounds.

    Segments stop at node rings so ring centers stay transparent and the mark
    works on any background.
    """
    s, forming, free = molecule(stretch)
    stroke, node = STROKE, NODE
    ring = stroke * 0.55
    free_r = node * 0.7
    parts = []
    for p, q in forming:
        a = node if p in s else free_r
        c = node if q in s else free_r
        p2, q2 = shorten(p, q, a, c)
        parts.append(
            f'<line x1="{p2[0]:.2f}" y1="{p2[1]:.2f}" x2="{q2[0]:.2f}" y2="{q2[1]:.2f}" '
            f'stroke="{trace}" stroke-width="{bond}" stroke-linecap="round" '
            f'stroke-dasharray="0.1 2.9" opacity="0.85"/>'
        )
    for p, q in zip(s, s[1:]):
        p2, q2 = shorten(p, q, node, node)
        parts.append(
            f'<line x1="{p2[0]:.2f}" y1="{p2[1]:.2f}" x2="{q2[0]:.2f}" y2="{q2[1]:.2f}" '
            f'stroke="{signal}" stroke-width="{stroke}"/>'
        )
    for x, y in free:
        parts.append(f'<circle cx="{x:.2f}" cy="{y:.2f}" r="{free_r:.2f}" fill="{trace}"/>')
    for x, y in s:
        parts.append(
            f'<circle cx="{x:.2f}" cy="{y:.2f}" r="{node:.2f}" fill="none" '
            f'stroke="{signal}" stroke-width="{ring:.2f}"/>'
        )
    xs = [p[0] for p in s + free]
    ys = [p[1] for p in s + free]
    bounds = (min(xs) - PAD, min(ys) - PAD, max(xs) + PAD, max(ys) + PAD)
    return "\n".join(parts), bounds


def instance(path):
    font = TTFont(path)
    instantiateVariableFont(font, AXES, inplace=True)
    return font


def shape(path, text):
    blob = hb.Blob.from_file_path(path)
    font = hb.Font(hb.Face(blob))
    font.set_variations(AXES)
    buf = hb.Buffer()
    buf.add_str(text)
    buf.guess_segment_properties()
    hb.shape(font, buf, {"kern": True, "liga": False})
    return buf.glyph_infos, buf.glyph_positions


def s_box(font):
    """Ink bounds of the font's S, which the mark replaces."""
    glyphs = font.getGlyphSet()
    pen = BoundsPen(glyphs)
    glyphs[font.getBestCmap()[ord("S")]].draw(pen)
    return pen.bounds


def wordmark(path, font, theme, stretch):
    text_fill = TEXT[theme]
    upem = font["head"].unitsPerEm
    glyphs = font.getGlyphSet()
    order = font.getGlyphOrder()
    infos, positions = shape(path, "Simthesizer")
    track = TRACKING * upem

    # The mark takes the S's ink box: same height, baseline, and width.
    sx0, sy0, sx1, sy1 = s_box(font)
    body, (mx0, my0, mx1, my1) = mark_svg(SIGNAL, TRACE, stretch)
    k = (sy1 - sy0) / (my1 - my0)
    ox = sx0 - mx0 * k
    # Mark coordinates are y down; font coordinates are y up, flipped below.
    oy = sy1 + my0 * k

    paths = []
    x = positions[0].x_advance + track
    for info, pos in zip(infos[1:], positions[1:]):
        pen = SVGPathPen(glyphs)
        glyphs[order[info.codepoint]].draw(TransformPen(pen, (1, 0, 0, 1, x + pos.x_offset, pos.y_offset)))
        paths.append(pen.getCommands())
        x += pos.x_advance + track
    width = x - track

    top = max(sy1, font["OS/2"].sCapHeight) + upem * 0.04
    bottom = min(sy0, 0) - upem * 0.04
    left = min(sx0, 0)
    vb = f"{left:.0f} {-top:.0f} {width - left:.0f} {top - bottom:.0f}"
    return "\n".join(
        [
            f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}" role="img" aria-label="Simthesizer">',
            f'<g transform="translate({ox:.2f} {-oy:.2f}) scale({k:.4f})">',
            body,
            "</g>",
            f'<path transform="scale(1 -1)" fill="{text_fill}" d="{" ".join(paths)}"/>',
            "</svg>",
            "",
        ]
    )


def tile(stretch):
    """The mark alone on the app tile: favicon and social avatar."""
    body, (x0, y0, x1, y1) = mark_svg(SIGNAL, TRACE, stretch)
    k = 44 / (y1 - y0)
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    return "\n".join(
        [
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" role="img" aria-label="Simthesizer">',
            f'<rect width="64" height="64" rx="15" fill="{TILE}"/>',
            f'<g transform="translate(32 32) scale({k:.4f}) translate({-cx:.2f} {-cy:.2f})">',
            body,
            "</g>",
            "</svg>",
            "",
        ]
    )


def main():
    path = sys.argv[1]
    font = instance(path)
    x0, y0, x1, y1 = s_box(font)
    stretch = fit_stretch((x1 - x0) / (y1 - y0))
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "logo.svg").write_text(tile(stretch))
    for theme in TEXT:
        (OUT / f"wordmark-{theme}.svg").write_text(wordmark(path, font, theme, stretch))
    print(f"wrote logo.svg and wordmark-{{{','.join(TEXT)}}}.svg to {OUT}")


if __name__ == "__main__":
    main()
