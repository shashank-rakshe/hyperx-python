"""Detection service for the API: raw drawing image → CIR (L1 behind the product API).

The API accepts a drawing upload and turns it into a CIR :class:`~cir.DrawingSet` the product
engines (grounding/takeoff/Q&A/RFI) consume. The detector is a pluggable protocol so the app is
testable with a stub and production-ready with the trained YOLO weights. Weights are configured
out-of-band via ``CDAI_DETECTOR_WEIGHTS`` (a JSON map ``{discipline: weights_path}``) so no model
is hard-coded; if none is configured the image endpoints report 503 rather than guessing.
"""

from __future__ import annotations

import io
import json
import os
from typing import Protocol

from cir import (
    DataLane,
    Discipline,
    DrawingSet,
    Entity,
    EntityType,
    Geometry,
    LicenseProvenance,
    Sheet,
    View,
    ViewType,
)

_DISCIPLINE = {
    "electrical": Discipline.ELECTRICAL,
    "architectural": Discipline.ARCHITECTURAL,
    "pid": Discipline.PROCESS,
    "process": Discipline.PROCESS,
}


class Detector(Protocol):
    """Turns a drawing image (bytes) into a CIR DrawingSet."""

    def detect(self, image_bytes: bytes, discipline: str, *, conf: float = 0.25) -> DrawingSet: ...


class UltralyticsDetector:
    """Production detector: lazy-loads trained YOLO weights per discipline."""

    def __init__(self, weights: dict[str, str]) -> None:
        self.weights = weights
        self._models: dict[str, object] = {}

    def _model(self, discipline: str) -> object:
        if discipline not in self._models:
            path = self.weights.get(discipline)
            if not path:
                raise KeyError(f"no weights configured for discipline '{discipline}'")
            from ultralytics import YOLO

            self._models[discipline] = YOLO(path)
        return self._models[discipline]

    def detect(self, image_bytes: bytes, discipline: str, *, conf: float = 0.25) -> DrawingSet:
        from PIL import Image

        model = self._model(discipline)
        img = Image.open(io.BytesIO(image_bytes)).convert("RGB")
        result = model(img, conf=conf, verbose=False)[0]  # type: ignore[operator]
        names = result.names
        ents = [
            Entity(
                id=f"d{i}",
                entity_type=EntityType.SYMBOL,
                label=names[int(cls)],
                geometry=Geometry.box(*box),
                license_provenance=LicenseProvenance.UNKNOWN,
                data_lane=DataLane.RESEARCH,
                confidence=float(cf),
            )
            for i, (box, cls, cf) in enumerate(
                zip(
                    result.boxes.xyxyn.tolist(),
                    result.boxes.cls.tolist(),
                    result.boxes.conf.tolist(),
                    strict=True,
                )
            )
        ]
        return DrawingSet(
            name="uploaded-drawing",
            sheets=[
                Sheet(
                    sheet_number="S-1",
                    discipline=_DISCIPLINE.get(discipline, Discipline.OTHER),
                    views=[View(view_type=ViewType.PLAN, entities=ents)],
                )
            ],
            license_provenance=LicenseProvenance.UNKNOWN,
            data_lane=DataLane.RESEARCH,
        )


def get_detector() -> Detector | None:
    """The configured production detector, or None if `CDAI_DETECTOR_WEIGHTS` is unset.

    FastAPI dependency — tests override it via ``app.dependency_overrides[get_detector]``.
    """
    raw = os.environ.get("CDAI_DETECTOR_WEIGHTS")
    if not raw:
        return None
    return UltralyticsDetector(json.loads(raw))
