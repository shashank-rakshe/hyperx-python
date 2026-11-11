"""A tiny vector canvas in the normalized sheet frame.

Real construction drawings are vector line-work, so the engine composes drawings as
vector primitives in normalized ``[0, 1]`` sheet coordinates and then (a) rasterizes
to a clean PNG via Pillow with supersampled anti-aliasing, and (b) serializes the same
primitives to SVG. Both outputs come from the *same* op list, so the raster and the
vector artifact agree by construction.

Why Pillow rather than an SVG rasterizer (cairosvg/cairo): no native system-library
dependency, deterministic output, and pixel-exact control — which matters because the
ground-truth bounding boxes are computed from the *placement math*, not read back from
pixels, and we want the pixels to land exactly where the math says.

The canvas deliberately knows nothing about electrical semantics or the CIR; it is a
dumb drawing surface. The mapping from a model fact to a glyph *and* a CIR record lives
in one place — :mod:`synthetic.render`.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from PIL import Image, ImageDraw, ImageFont

# A color is an RGB triple. Grayscale ints are widened via :func:`gray`.
Color = tuple[int, int, int]


def gray(value: int) -> Color:
    """An RGB gray from a 0–255 intensity."""
    v = max(0, min(255, int(value)))
    return (v, v, v)


@dataclass
class _Op:
    """One recorded drawing primitive (normalized coordinates)."""

    kind: str
    args: dict[str, Any]


@dataclass
class Canvas:
    """A normalized-coordinate vector canvas that rasterizes and serializes to SVG.

    Coordinates are fractions of the sheet in ``[0, 1]``; :meth:`to_image` multiplies by
    the pixel size. ``supersample`` draws large and downscales with LANCZOS for clean
    anti-aliased line-work.
    """

    width: int  # output width in pixels
    height: int  # output height in pixels
    background: Color = (255, 255, 255)
    supersample: int = 3
    _ops: list[_Op] = field(default_factory=list)

    # -- primitives (all coordinates normalized [0,1]) ---------------------------
    def line(
        self, x0: float, y0: float, x1: float, y1: float, *, weight: float, color: Color
    ) -> None:
        """A straight stroke from (x0,y0) to (x1,y1); ``weight`` in normalized units."""
        self._ops.append(_Op("line", {"p": (x0, y0, x1, y1), "w": weight, "c": color}))

    def polyline(
        self, pts: list[tuple[float, float]], *, weight: float, color: Color, closed: bool = False
    ) -> None:
        """An open (or closed) sequence of strokes through ``pts``."""
        self._ops.append(
            _Op("polyline", {"pts": list(pts), "w": weight, "c": color, "closed": closed})
        )

    def polygon(
        self,
        pts: list[tuple[float, float]],
        *,
        weight: float,
        color: Color,
        fill: Color | None = None,
    ) -> None:
        """A filled and/or stroked closed polygon."""
        self._ops.append(_Op("polygon", {"pts": list(pts), "w": weight, "c": color, "fill": fill}))

    def circle(
        self,
        cx: float,
        cy: float,
        r: float,
        *,
        weight: float,
        color: Color,
        fill: Color | None = None,
    ) -> None:
        """A circle of normalized radius ``r`` centered at (cx,cy)."""
        self._ops.append(
            _Op("circle", {"c0": (cx, cy), "r": r, "w": weight, "c": color, "fill": fill})
        )

    def rect(
        self,
        x0: float,
        y0: float,
        x1: float,
        y1: float,
        *,
        weight: float,
        color: Color,
        fill: Color | None = None,
    ) -> None:
        """An axis-aligned rectangle."""
        self._ops.append(
            _Op("rect", {"p": (x0, y0, x1, y1), "w": weight, "c": color, "fill": fill})
        )

    def text(
        self,
        x: float,
        y: float,
        s: str,
        *,
        size: float,
        color: Color,
        anchor: str = "mm",
    ) -> None:
        """Draw text ``s`` at (x,y); ``size`` is the cap height in normalized units."""
        self._ops.append(
            _Op("text", {"p": (x, y), "s": s, "size": size, "c": color, "anchor": anchor})
        )

    # -- rasterization -----------------------------------------------------------
    def to_image(self) -> Image.Image:
        """Rasterize to an RGB Pillow image with supersampled anti-aliasing."""
        ss = max(1, self.supersample)
        w, h = self.width * ss, self.height * ss
        img = Image.new("RGB", (w, h), self.background)
        draw = ImageDraw.Draw(img)

        def px(x: float, y: float) -> tuple[float, float]:
            return (x * w, y * h)

        def pw(weight: float) -> int:
            return max(1, round(weight * w))

        for op in self._ops:
            a = op.args
            if op.kind == "line":
                x0, y0, x1, y1 = a["p"]
                draw.line([px(x0, y0), px(x1, y1)], fill=a["c"], width=pw(a["w"]))
            elif op.kind == "polyline":
                pts = [px(x, y) for x, y in a["pts"]]
                if a["closed"] and pts:
                    pts = [*pts, pts[0]]
                if len(pts) >= 2:
                    draw.line(pts, fill=a["c"], width=pw(a["w"]), joint="curve")
            elif op.kind == "polygon":
                pts = [px(x, y) for x, y in a["pts"]]
                if len(pts) >= 3:
                    draw.polygon(pts, outline=a["c"], fill=a["fill"], width=pw(a["w"]))
            elif op.kind == "circle":
                cx, cy = a["c0"]
                r = a["r"]
                box = [px(cx - r, cy - r), px(cx + r, cy + r)]
                draw.ellipse(box, outline=a["c"], fill=a["fill"], width=pw(a["w"]))
            elif op.kind == "rect":
                x0, y0, x1, y1 = a["p"]
                draw.rectangle(
                    [px(x0, y0), px(x1, y1)], outline=a["c"], fill=a["fill"], width=pw(a["w"])
                )
            elif op.kind == "text":
                x, y = a["p"]
                font = _font(round(a["size"] * h))
                draw.text(px(x, y), a["s"], fill=a["c"], font=font, anchor=a["anchor"])

        if ss != 1:
            img = img.resize((self.width, self.height), Image.Resampling.LANCZOS)
        return img

    # -- SVG ---------------------------------------------------------------------
    def to_svg(self) -> str:
        """Serialize the same primitives to an SVG document string."""
        w, h = self.width, self.height
        out: list[str] = [
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" '
            f'viewBox="0 0 {w} {h}">',
            f'<rect width="{w}" height="{h}" fill="{_hex(self.background)}"/>',
        ]

        def sx(x: float) -> float:
            return round(x * w, 2)

        def sy(y: float) -> float:
            return round(y * h, 2)

        def sw(weight: float) -> float:
            return round(max(1.0, weight * w), 2)

        for op in self._ops:
            a = op.args
            if op.kind == "line":
                x0, y0, x1, y1 = a["p"]
                out.append(
                    f'<line x1="{sx(x0)}" y1="{sy(y0)}" x2="{sx(x1)}" y2="{sy(y1)}" '
                    f'stroke="{_hex(a["c"])}" stroke-width="{sw(a["w"])}"/>'
                )
            elif op.kind in ("polyline", "polygon"):
                pts = " ".join(f"{sx(x)},{sy(y)}" for x, y in a["pts"])
                fill = _hex(a["fill"]) if a.get("fill") else "none"
                tag = "polygon" if op.kind == "polygon" or a.get("closed") else "polyline"
                if op.kind == "polyline" and not a.get("closed"):
                    fill = "none"
                out.append(
                    f'<{tag} points="{pts}" fill="{fill}" stroke="{_hex(a["c"])}" '
                    f'stroke-width="{sw(a["w"])}"/>'
                )
            elif op.kind == "circle":
                cx, cy = a["c0"]
                fill = _hex(a["fill"]) if a.get("fill") else "none"
                out.append(
                    f'<circle cx="{sx(cx)}" cy="{sy(cy)}" r="{sx(a["r"])}" fill="{fill}" '
                    f'stroke="{_hex(a["c"])}" stroke-width="{sw(a["w"])}"/>'
                )
            elif op.kind == "rect":
                x0, y0, x1, y1 = a["p"]
                fill = _hex(a["fill"]) if a.get("fill") else "none"
                out.append(
                    f'<rect x="{sx(x0)}" y="{sy(y0)}" width="{sx(x1 - x0)}" height="{sy(y1 - y0)}" '
                    f'fill="{fill}" stroke="{_hex(a["c"])}" stroke-width="{sw(a["w"])}"/>'
                )
            elif op.kind == "text":
                x, y = a["p"]
                ha = {"l": "start", "m": "middle", "r": "end"}.get(a["anchor"][0], "middle")
                out.append(
                    f'<text x="{sx(x)}" y="{sy(y)}" font-size="{sy(a["size"])}" '
                    f'fill="{_hex(a["c"])}" text-anchor="{ha}" '
                    f'dominant-baseline="central">{_xml_escape(a["s"])}</text>'
                )
        out.append("</svg>")
        return "\n".join(out)


def _hex(color: Color) -> str:
    r, g, b = color
    return f"#{r:02x}{g:02x}{b:02x}"


def _xml_escape(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


_FONT_CACHE: dict[int, ImageFont.FreeTypeFont | ImageFont.ImageFont] = {}


def _font(size_px: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    """A scalable default font at ``size_px`` (Pillow ≥10.1 ships a sizeable default)."""
    size_px = max(6, int(size_px))
    if size_px not in _FONT_CACHE:
        try:
            _FONT_CACHE[size_px] = ImageFont.load_default(size=size_px)
        except TypeError:  # very old Pillow: fixed-size bitmap default
            _FONT_CACHE[size_px] = ImageFont.load_default()
    return _FONT_CACHE[size_px]
