"""Few-shot legend adaptation — add a new project's bespoke symbols from a few examples.

Every project's drawing set ships a **legend**: a small table mapping each glyph to what
it means. Legends differ between offices and trades, so a detector trained on one symbol
vocabulary must adapt to a new project's glyphs without a full retrain. This module is
that adaptation head.

The mechanism is a **prototypical-network** classifier (the standard few-shot approach):

1. Embed each legend exemplar crop with a frozen image encoder.
2. Average the embeddings per class and L2-normalize -> one **prototype** per class.
3. Classify a query crop by cosine similarity to the nearest prototype; reject below a
   similarity floor (so out-of-legend clutter is not force-labelled).

A handful of exemplars per class is enough because the encoder is frozen and only the
(cheap, non-parametric) prototypes are "learned" — no gradient steps, no GPU job. The
head composes with Model 1 two ways: **re-label** the detector's boxes into a new
project's vocabulary, or **discover** instances of a legend symbol the base detector was
never trained on.

The encoder is injectable (any ``crop -> vector`` callable), so this is testable offline
with a deterministic stub; :func:`default_encoder` provides a frozen ResNet-18 embedder
for real use. Nothing here calls an external API — the encoder runs locally.
"""

from __future__ import annotations

import logging
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np

from cir import BBox

logger = logging.getLogger(__name__)

#: A frozen embedder: a PIL image crop -> a 1-D feature vector.
Embedder = Callable[[Any], np.ndarray]


@dataclass(frozen=True)
class LegendExemplar:
    """One labelled legend crop (a glyph image + the class name it denotes)."""

    image: Any  # PIL.Image.Image
    label: str


def _l2(vector: np.ndarray) -> np.ndarray:
    norm = float(np.linalg.norm(vector))
    return vector / norm if norm > 0.0 else vector


class LegendAdapter:
    """A prototype classifier fitted to a project's legend; re-labels/finds its symbols."""

    def __init__(self, embed: Embedder, *, min_similarity: float = 0.55) -> None:
        self.embed = embed
        self.min_similarity = min_similarity
        self.prototypes: dict[str, np.ndarray] = {}

    # -- fit ---------------------------------------------------------------------
    def fit(self, exemplars: Sequence[LegendExemplar]) -> LegendAdapter:
        """Build one L2-normalized prototype per class from the legend exemplars."""
        sums: dict[str, np.ndarray] = {}
        counts: dict[str, int] = {}
        for ex in exemplars:
            vec = _l2(np.asarray(self.embed(ex.image), dtype=np.float64))
            sums[ex.label] = sums.get(ex.label, np.zeros_like(vec)) + vec
            counts[ex.label] = counts.get(ex.label, 0) + 1
        if not sums:
            raise ValueError("LegendAdapter.fit needs at least one exemplar")
        self.prototypes = {label: _l2(total / counts[label]) for label, total in sums.items()}
        logger.info(
            "fitted legend with %d class(es) from %d exemplars: %s",
            len(self.prototypes),
            len(exemplars),
            sorted(counts),
        )
        return self

    @property
    def classes(self) -> list[str]:
        return sorted(self.prototypes)

    # -- classify ----------------------------------------------------------------
    def classify(self, crop: Any) -> tuple[str | None, float]:
        """Nearest-prototype class for one crop, or ``(None, sim)`` if below the floor."""
        if not self.prototypes:
            raise RuntimeError("LegendAdapter is not fitted; call fit() first")
        query = _l2(np.asarray(self.embed(crop), dtype=np.float64))
        best_label, best_sim = None, -1.0
        for label, proto in self.prototypes.items():
            sim = float(np.dot(query, proto))
            if sim > best_sim:
                best_label, best_sim = label, sim
        if best_sim < self.min_similarity:
            return None, best_sim
        return best_label, best_sim

    def relabel(self, image: Any, boxes: Sequence[BBox]) -> list[tuple[str | None, float]]:
        """Classify each sheet-normalized box's crop against the legend prototypes."""
        width, height = image.size
        out: list[tuple[str | None, float]] = []
        for box in boxes:
            crop = image.crop(
                (
                    int(box.x_min * width),
                    int(box.y_min * height),
                    round(box.x_max * width),
                    round(box.y_max * height),
                )
            )
            out.append(self.classify(crop))
        return out

    # -- persistence -------------------------------------------------------------
    def save(self, path: str | Path) -> None:
        """Persist the prototypes (the only fitted state) to a ``.npz`` file."""
        labels = self.classes
        matrix = (
            np.stack([self.prototypes[label] for label in labels]) if labels else np.empty((0,))
        )
        np.savez(
            Path(path),
            labels=np.array(labels, dtype=object),
            prototypes=matrix,
            min_similarity=self.min_similarity,
        )

    @classmethod
    def load(cls, path: str | Path, embed: Embedder) -> LegendAdapter:
        """Load prototypes saved by :meth:`save` (re-supply the same kind of encoder)."""
        data = np.load(Path(path), allow_pickle=True)
        adapter = cls(embed, min_similarity=float(data["min_similarity"]))
        labels = list(data["labels"])
        adapter.prototypes = {label: data["prototypes"][i] for i, label in enumerate(labels)}
        return adapter


def default_encoder(*, device: str | None = None, image_size: int = 64) -> Embedder:
    """A frozen ResNet-18 (ImageNet) embedder: PIL crop -> 512-d feature vector.

    Loaded lazily so importing this module costs nothing. Weights are a one-time local
    download (like the YOLO init); no inference-time network calls. Pass your own encoder
    to :class:`LegendAdapter` to avoid the download or to reuse Model 1's backbone.
    """
    import torch
    from torchvision import transforms
    from torchvision.models import ResNet18_Weights, resnet18

    dev = device or ("cuda" if torch.cuda.is_available() else "cpu")
    backbone = resnet18(weights=ResNet18_Weights.IMAGENET1K_V1)
    backbone.fc = torch.nn.Identity()  # 512-d penultimate features
    backbone.eval().to(dev)
    transform = transforms.Compose(
        [
            transforms.Resize((image_size, image_size)),
            transforms.ToTensor(),
            transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]),
        ]
    )

    @torch.no_grad()
    def embed(crop: Any) -> np.ndarray:
        tensor = transform(crop.convert("RGB")).unsqueeze(0).to(dev)
        return np.asarray(backbone(tensor).squeeze(0).cpu().numpy())

    return embed


def crop_for_box(image: Any, box: BBox) -> Any:
    """Crop the sheet-normalized ``box`` out of a PIL ``image`` (a legend-exemplar helper)."""
    width, height = image.size
    return image.crop(
        (
            int(box.x_min * width),
            int(box.y_min * height),
            round(box.x_max * width),
            round(box.y_max * height),
        )
    )
