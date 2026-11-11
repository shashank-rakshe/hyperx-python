"""Parametric drafting style — diversity is a control, not an accident.

A model trained on one drawing style overfits that style. So drafting style is a set of
seeded parameters — sheet size, line weights, which glyph variant each device uses, font
size, title-block placement, hatching, ink/paper tone — and every sample records the
exact :class:`StyleParams` it was drawn with (written to ``style.json``), so a run is
reproducible and a slice of the data can be conditioned on style later.

The sampler is deterministic in its seed: same ``style_seed`` → same look. That is what
makes ``--style-seed`` meaningful and a 200-sample pilot exactly reproducible.
"""

from __future__ import annotations

import random

from pydantic import BaseModel, ConfigDict, Field

from .model import DeviceKind
from .symbols import n_variants

#: Candidate sheet sizes (name, width_px, height_px), landscape. Kept at moderate
#: resolution: large enough for crisp symbols, small enough to render in bulk. The
#: gigapixel regime is exercised by L0 tiling, not by inflating the source render.
SHEET_SIZES: list[tuple[str, int, int]] = [
    ("ANSI-B", 1500, 1000),
    ("ARCH-C", 1680, 1120),
    ("ANSI-C", 1800, 1280),
    ("ARCH-D", 1980, 1320),
]

TITLE_BLOCK_LAYOUTS = ("right", "bottom")
HATCH_PATTERNS = ("none", "diagonal", "dots")


class StyleParams(BaseModel):
    """The exact drafting style a sample was rendered with (recorded per sample)."""

    model_config = ConfigDict(extra="forbid")

    seed: int
    sheet_size_name: str
    sheet_w_px: int
    sheet_h_px: int
    supersample: int
    line_weight: float  # thin line weight, normalized to sheet width
    heavy_weight: float  # heavy line weight (walls, borders, buses)
    symbol_scale: float  # multiplies each device's nominal glyph size
    font_scale: float  # multiplies base text size
    title_block: str  # "right" | "bottom"
    hatch: str  # "none" | "diagonal" | "dots"
    ink: int  # foreground intensity (0=black)
    paper: int  # background intensity (255=white)
    symbol_variants: dict[str, int] = Field(default_factory=dict)  # DeviceKind.value -> variant idx

    def variant_for(self, kind: DeviceKind) -> int:
        """The glyph-variant index chosen for ``kind`` (0 if unset)."""
        return self.symbol_variants.get(kind.value, 0)


def sample_style(seed: int) -> StyleParams:
    """Deterministically sample a :class:`StyleParams` from ``seed``."""
    rng = random.Random(seed)
    name, w, h = rng.choice(SHEET_SIZES)
    variants = {kind.value: rng.randrange(n_variants(kind)) for kind in DeviceKind}
    return StyleParams(
        seed=seed,
        sheet_size_name=name,
        sheet_w_px=w,
        sheet_h_px=h,
        supersample=2,
        line_weight=rng.uniform(0.0009, 0.0016),
        heavy_weight=rng.uniform(0.0020, 0.0034),
        symbol_scale=rng.uniform(0.9, 1.25),
        font_scale=rng.uniform(0.85, 1.2),
        title_block=rng.choice(TITLE_BLOCK_LAYOUTS),
        hatch=rng.choice(HATCH_PATTERNS),
        ink=rng.randrange(0, 40),
        paper=rng.randrange(244, 256),
        symbol_variants=variants,
    )
