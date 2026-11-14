"""The degradation pipeline — a measurement instrument, not random noise.

Legacy-PDF robustness is a differentiator, so degradation is *parameterized and recorded*,
not a vague "add noise" pass: each sample is rendered at a discrete severity **level** and
the exact parameters drawn for that level are written to ``degradation.json``. That is what
lets the eval harness later plot accuracy *as a function of* degradation, precisely, and
attribute a regression to a specific corruption.

The governing safety property is structural: :func:`degrade` takes **only an image**. It
never receives the ground truth, so it *cannot* alter a coordinate — the clean CIR remains
the single source of truth and stays pixel-aligned with the degraded image.

Two families:

* **Photometric** (default, levels 1–3): scan noise, blur, fade/low-contrast, faded/broken
  lines, JPEG artifacts, stains/markings, vignette. None of these move a pixel, so every
  ground-truth box still lands on its symbol in the degraded image — the data is honestly
  labelled as-is.
* **Geometric** (:func:`apply_skew` etc., **off by default**): rotation/skew and paper warp
  *do* move pixels. They are implemented but excluded from the v0 recipe, because using them
  would require reprojecting the boxes through the recorded transform — a deliberate,
  one-flag follow-up (``allow_geometric=True``), not something to enable silently under a
  contract that promises aligned labels.
"""

from __future__ import annotations

import io
import random
from dataclasses import dataclass, field
from typing import Any

import numpy as np
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter

#: Reference severity levels. 0 is clean; 3 is heavy legacy-scan. Higher clamps to 3.
MAX_LEVEL = 3

# Per-level parameter ranges; exact values are drawn within these and recorded.
_LEVEL_RANGES: dict[int, dict[str, tuple[float, float]]] = {
    1: {
        "noise": (3, 8),
        "blur": (0.0, 0.4),
        "jpeg": (80, 92),
        "fade": (0.93, 1.0),
        "dropout": (0.0, 0.02),
        "stains": (0, 1),
    },
    2: {
        "noise": (8, 16),
        "blur": (0.4, 0.9),
        "jpeg": (55, 80),
        "fade": (0.84, 0.94),
        "dropout": (0.02, 0.06),
        "stains": (1, 2),
    },
    3: {
        "noise": (16, 28),
        "blur": (0.8, 1.6),
        "jpeg": (30, 55),
        "fade": (0.70, 0.86),
        "dropout": (0.05, 0.12),
        "stains": (2, 4),
    },
}


@dataclass
class DegradationParams:
    """The exact degradation applied to one image (serialized to ``degradation.json``)."""

    level: int
    np_seed: int
    geometric: bool = False
    ops: dict[str, Any] = field(default_factory=dict)

    def as_dict(self) -> dict[str, Any]:
        return {
            "level": self.level,
            "np_seed": self.np_seed,
            "geometric": self.geometric,
            "ops": self.ops,
        }


def degrade(
    image: Image.Image, level: int, rng: random.Random, *, allow_geometric: bool = False
) -> tuple[Image.Image, DegradationParams]:
    """Return a degraded copy of ``image`` at ``level`` plus the exact params used.

    ``image`` is the *only* input touched — the ground truth is not passed here and cannot
    be changed. Level 0 is the identity (a clean sample), so a 0..3 run still yields clean
    images for the low end of the accuracy-vs-degradation curve.
    """
    level = max(0, min(level, MAX_LEVEL))
    np_seed = int(rng.random() * 2_147_483_647)
    params = DegradationParams(level=level, np_seed=np_seed)
    if level == 0:
        return image.copy(), params

    nprng = np.random.default_rng(np_seed)
    ranges = _LEVEL_RANGES[level]
    img = image.convert("RGB")

    fade = rng.uniform(*ranges["fade"])
    img = ImageEnhance.Contrast(img).enhance(fade)
    img = ImageEnhance.Brightness(img).enhance(1.0 + (1.0 - fade) * 0.5)
    params.ops["fade"] = round(fade, 4)

    dropout = rng.uniform(*ranges["dropout"])
    img = _break_lines(img, dropout, nprng)
    params.ops["line_dropout"] = round(dropout, 4)

    n_stains = rng.randint(int(ranges["stains"][0]), int(ranges["stains"][1]))
    img = _add_stains(img, n_stains, rng)
    params.ops["stains"] = n_stains

    if allow_geometric:
        angle = rng.uniform(-2.0, 2.0) * (level / MAX_LEVEL)
        img = apply_skew(img, angle)
        params.geometric = True
        params.ops["skew_deg"] = round(angle, 4)

    blur = rng.uniform(*ranges["blur"])
    if blur > 0.05:
        img = img.filter(ImageFilter.GaussianBlur(radius=blur))
    params.ops["blur"] = round(blur, 4)

    sigma = rng.uniform(*ranges["noise"])
    img = _add_noise(img, sigma, nprng)
    params.ops["noise_sigma"] = round(sigma, 4)

    quality = int(rng.uniform(*ranges["jpeg"]))
    img = _jpeg(img, quality)
    params.ops["jpeg_quality"] = quality

    return img, params


# ---------------------------------------------------------------------------
# Photometric ops (size- and position-preserving — boxes stay aligned)
# ---------------------------------------------------------------------------
def _add_noise(img: Image.Image, sigma: float, nprng: np.random.Generator) -> Image.Image:
    arr = np.asarray(img, dtype=np.float32)
    arr += nprng.normal(0.0, sigma, arr.shape)
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB")


def _break_lines(img: Image.Image, dropout: float, nprng: np.random.Generator) -> Image.Image:
    """Fade/break dark line-work: randomly lift a fraction of ink pixels toward paper."""
    if dropout <= 0:
        return img
    arr = np.asarray(img, dtype=np.float32)
    luma = arr.mean(axis=2)
    ink = luma < 128
    drop = ink & (nprng.random(luma.shape) < dropout)
    arr[drop] = np.minimum(255.0, arr[drop] + 150.0)
    return Image.fromarray(arr.astype(np.uint8), "RGB")


def _add_stains(img: Image.Image, n: int, rng: random.Random) -> Image.Image:
    """Overlay translucent stains and the occasional marker stroke."""
    if n <= 0:
        return img
    w, h = img.size
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    for _ in range(n):
        cx, cy = rng.uniform(0, w), rng.uniform(0, h)
        rx, ry = rng.uniform(0.02, 0.10) * w, rng.uniform(0.02, 0.10) * h
        tone = rng.choice([(120, 90, 50), (90, 80, 70), (60, 80, 110)])
        alpha = rng.randint(20, 55)
        draw.ellipse([cx - rx, cy - ry, cx + rx, cy + ry], fill=(*tone, alpha))
    if rng.random() < 0.4:  # a redline / highlighter stroke
        x0, y0 = rng.uniform(0, w), rng.uniform(0, h)
        x1, y1 = x0 + rng.uniform(-0.2, 0.2) * w, y0 + rng.uniform(-0.1, 0.1) * h
        color = rng.choice([(200, 30, 30, 90), (40, 90, 200, 80)])
        draw.line([x0, y0, x1, y1], fill=color, width=max(2, int(0.004 * w)))
    return Image.alpha_composite(img.convert("RGBA"), overlay).convert("RGB")


def _jpeg(img: Image.Image, quality: int) -> Image.Image:
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=int(quality))
    buf.seek(0)
    return Image.open(buf).convert("RGB")


# ---------------------------------------------------------------------------
# Geometric ops (move pixels — OFF by default; would require reprojecting boxes)
# ---------------------------------------------------------------------------
def apply_skew(img: Image.Image, angle_deg: float) -> Image.Image:
    """Rotate (skew) the image about its center, filling with paper white.

    Off by default: rotation moves symbols in pixel space, so using it requires
    reprojecting the ground-truth boxes through ``angle_deg`` (a recorded, deferred step).
    """
    return img.rotate(
        angle_deg, resample=Image.Resampling.BICUBIC, fillcolor=(255, 255, 255), expand=False
    )
