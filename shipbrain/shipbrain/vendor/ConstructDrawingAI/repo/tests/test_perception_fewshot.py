"""The few-shot legend head: prototypes, nearest-match, rejection, and persistence.

Uses a deterministic stub encoder (mean RGB) so the test is fast, offline, and exact —
the real :func:`perception.fewshot.default_encoder` (a frozen ResNet-18) is exercised
separately at runtime, not in the unit suite.
"""

from __future__ import annotations

import numpy as np
from PIL import Image

from perception.fewshot import LegendAdapter, LegendExemplar


def _mean_rgb(image: Image.Image) -> np.ndarray:
    """A trivial deterministic embedder: the crop's mean RGB (separable for solid glyphs)."""
    return np.asarray(image.convert("RGB"), dtype=np.float64).reshape(-1, 3).mean(axis=0)


def _solid(color: tuple[int, int, int]) -> Image.Image:
    return Image.new("RGB", (16, 16), color)


def test_fits_prototypes_and_classifies_by_nearest() -> None:
    exemplars = [
        LegendExemplar(_solid((220, 20, 20)), "A"),
        LegendExemplar(_solid((200, 10, 30)), "A"),
        LegendExemplar(_solid((20, 200, 20)), "B"),
        LegendExemplar(_solid((10, 220, 40)), "B"),
    ]
    adapter = LegendAdapter(_mean_rgb, min_similarity=0.0).fit(exemplars)
    assert adapter.classes == ["A", "B"]
    label_a, sim_a = adapter.classify(_solid((255, 0, 0)))
    label_b, _ = adapter.classify(_solid((0, 255, 0)))
    assert label_a == "A" and sim_a > 0.9
    assert label_b == "B"


def test_rejects_below_similarity_floor() -> None:
    # A single red prototype; a green query is far in direction (low cosine) -> rejected.
    adapter = LegendAdapter(_mean_rgb, min_similarity=0.9).fit(
        [LegendExemplar(_solid((255, 0, 0)), "red")]
    )
    label, _ = adapter.classify(_solid((0, 255, 0)))
    assert label is None


def test_save_load_round_trip(tmp_path) -> None:
    exemplars = [
        LegendExemplar(_solid((255, 0, 0)), "A"),
        LegendExemplar(_solid((0, 0, 255)), "B"),
    ]
    adapter = LegendAdapter(_mean_rgb, min_similarity=0.1).fit(exemplars)
    path = tmp_path / "legend.npz"
    adapter.save(path)

    reloaded = LegendAdapter.load(path, _mean_rgb)
    assert reloaded.classes == adapter.classes
    assert reloaded.min_similarity == adapter.min_similarity
    assert reloaded.classify(_solid((255, 0, 0)))[0] == "A"
    assert reloaded.classify(_solid((0, 0, 255)))[0] == "B"
