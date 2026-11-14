"""Frontier-API baseline adapters (Claude / GPT / Gemini vision). **OPTIONAL / UNUSED.**

.. warning::

   This project does **not** call external APIs. Nothing in the default flow — the
   demo, the leaderboard, the test suite's scored runs, or any reported figure —
   imports or instantiates these adapters. The frontier baseline on the leaderboard
   comes from **cited literature numbers** (:func:`eval.fixtures.published_frontier`),
   not live calls. This module is retained only for optional, explicit opt-in use and
   is never on a default code path; importing it requires no API key (keys are checked
   lazily, only if you actually call ``predict``).

If you do opt in: each adapter tiles large pages (:mod:`eval.tiling`), calls its
provider's SDK (lazily imported; the ``frontier`` optional-dependency group), parses
JSON detections, remaps tile-local boxes to the full page, and merges them with
cross-tile NMS. SDK calls are mocked in tests.
"""

from __future__ import annotations

import json
import os
from abc import abstractmethod
from io import BytesIO
from typing import Any

from cir import (
    DataLane,
    DrawingSet,
    Entity,
    EntityType,
    Geometry,
    LicenseProvenance,
    Sheet,
    SourceFile,
    View,
    ViewType,
)

from .adapters import ModelAdapter
from .tasks import EvalSample
from .tiling import nms, tile_box_to_global, tile_image

EXTRACTION_PROMPT = (
    "You are an expert at reading construction drawings. Detect every symbol/device in "
    "this image. Respond with STRICT JSON only, no prose:\n"
    '{"detections": [{"label": "<symbol name>", "bbox": [x0, y0, x1, y1], '
    '"confidence": <0..1>}]}\n'
    "Coordinates are normalized to [0,1] (x right, y down). Be exhaustive; dense "
    "symbols matter."
)


def _png_b64(image: Any) -> str:
    import base64

    buf = BytesIO()
    image.save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode("ascii")


def _extract_json(text: str) -> dict[str, Any]:
    """Pull the first JSON object out of a model response (tolerating code fences)."""
    start, end = text.find("{"), text.rfind("}")
    if start == -1 or end == -1 or end < start:
        return {"detections": []}
    try:
        obj = json.loads(text[start : end + 1])
    except json.JSONDecodeError:
        return {"detections": []}
    return obj if isinstance(obj, dict) else {"detections": []}


class FrontierAdapter(ModelAdapter):
    """Base class for frontier vision adapters (tiling + parse + CIR are shared)."""

    is_stochastic = True
    provider = "frontier"

    def __init__(
        self,
        model: str,
        *,
        api_key_env: str,
        temperature: float = 0.0,
        tile_size: int = 1280,
    ) -> None:
        self.model = model
        self.name = f"{self.provider}:{model}"
        self.api_key_env = api_key_env
        self.temperature = temperature
        self.tile_size = tile_size

    def _require_key(self) -> str:
        key = os.environ.get(self.api_key_env)
        if not key:
            raise RuntimeError(
                f"{self.name}: environment variable {self.api_key_env} is not set. "
                f"Set it to run the frontier baseline."
            )
        return key

    @abstractmethod
    def _call(self, image: Any, prompt: str, *, seed: int) -> str:
        """Provider-specific vision call returning the raw text response."""
        raise NotImplementedError

    def predict(self, sample: EvalSample, *, seed: int = 0) -> DrawingSet:
        if sample.image_path is None:
            raise ValueError(f"{self.name} needs sample.image_path (a drawing image).")
        tiled = tile_image(sample.image_path, tile_size=self.tile_size)
        detections: list[dict[str, Any]] = []
        for tile in tiled.tiles:
            raw = self._call(tile.image, EXTRACTION_PROMPT, seed=seed)
            for det in _extract_json(raw).get("detections", []):
                box = det.get("bbox")
                if not (isinstance(box, list) and len(box) == 4):
                    continue
                detections.append(
                    {
                        "label": str(det.get("label", "symbol")),
                        "bbox": tile_box_to_global(
                            (float(box[0]), float(box[1]), float(box[2]), float(box[3])),
                            tile,
                            tiled.full_width,
                            tiled.full_height,
                        ),
                        "confidence": float(det.get("confidence", 0.5)),
                    }
                )
        return self._to_cir(sample, nms(detections))

    def _to_cir(self, sample: EvalSample, detections: list[dict[str, Any]]) -> DrawingSet:
        entities = [
            Entity(
                id=f"{self.name}-{i}",
                entity_type=EntityType.SYMBOL,
                label=det["label"],
                geometry=Geometry.box(*det["bbox"]),
                confidence=max(0.0, min(1.0, det["confidence"])),
                produced_by=self.name,
                license_provenance=LicenseProvenance.UNKNOWN,
                data_lane=DataLane.RESEARCH,
            )
            for i, det in enumerate(detections)
        ]
        view = View(name="prediction", view_type=ViewType.PLAN, entities=entities)
        sheet = Sheet(sheet_number="P-1", views=[view])
        return DrawingSet(
            name=f"{self.name} prediction for {sample.id}",
            source=SourceFile(
                filename=str(sample.image_path), file_type="image", ingest_tool=self.name
            ),
            sheets=[sheet],
            license_provenance=LicenseProvenance.UNKNOWN,
            data_lane=DataLane.RESEARCH,
        )


class ClaudeAdapter(FrontierAdapter):
    """Anthropic Claude vision adapter."""

    provider = "claude"

    def __init__(self, model: str = "claude-opus-4-8", *, temperature: float = 0.0) -> None:
        super().__init__(model, api_key_env="ANTHROPIC_API_KEY", temperature=temperature)

    def _call(self, image: Any, prompt: str, *, seed: int) -> str:
        import anthropic

        client = anthropic.Anthropic(api_key=self._require_key())
        message = client.messages.create(
            model=self.model,
            max_tokens=4096,
            temperature=self.temperature,
            messages=[
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "image",
                            "source": {
                                "type": "base64",
                                "media_type": "image/png",
                                "data": _png_b64(image),
                            },
                        },
                        {"type": "text", "text": prompt},
                    ],
                }
            ],
        )
        return "".join(block.text for block in message.content if block.type == "text")


class GPTAdapter(FrontierAdapter):
    """OpenAI GPT vision adapter."""

    provider = "gpt"

    def __init__(self, model: str = "gpt-5", *, temperature: float = 0.0) -> None:
        super().__init__(model, api_key_env="OPENAI_API_KEY", temperature=temperature)

    def _call(self, image: Any, prompt: str, *, seed: int) -> str:
        import openai

        client = openai.OpenAI(api_key=self._require_key())
        response = client.chat.completions.create(
            model=self.model,
            temperature=self.temperature,
            messages=[
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": prompt},
                        {
                            "type": "image_url",
                            "image_url": {"url": f"data:image/png;base64,{_png_b64(image)}"},
                        },
                    ],
                }
            ],
        )
        return str(response.choices[0].message.content or "")


class GeminiAdapter(FrontierAdapter):
    """Google Gemini vision adapter."""

    provider = "gemini"

    def __init__(self, model: str = "gemini-3-pro", *, temperature: float = 0.0) -> None:
        super().__init__(model, api_key_env="GOOGLE_API_KEY", temperature=temperature)

    def _call(self, image: Any, prompt: str, *, seed: int) -> str:
        from google import genai

        client = genai.Client(api_key=self._require_key())
        response = client.models.generate_content(model=self.model, contents=[prompt, image])
        return str(response.text or "")
