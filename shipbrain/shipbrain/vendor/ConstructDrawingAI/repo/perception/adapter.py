"""DetectorAdapter — wire Model 1 into the CIR via the L0->L1 handoff contract.

This is the seam between L1 perception and the rest of the platform. A
:class:`~eval.adapters.ModelAdapter` so the evaluation harness scores the detector
exactly like any other system, it does the one thing L1 must do and nothing more:

1. **tile** the sheet image with :func:`ingest.tiling.tile_image` (the L0 tiler);
2. ask the detector for per-tile detections in **tile-local-normalized** coordinates;
3. hand those to :func:`ingest.handoff.aggregate`, which composes them back to
   sheet-normalized coordinates and de-duplicates across tile seams.

Crucially, **the coordinate mapping is not re-implemented here** — composition lives in
exactly one audited place (``ingest.handoff``, pinned by ``tests/test_ingest_handoff.py``),
because a stitching error becomes a counting error and counting is the headline metric of
the MEP wedge. This adapter just produces ``TileDetection`` objects and calls the contract.

The emitted :class:`~cir.DrawingSet` carries, per entity: the recovered class label (the
same string the synthetic GT uses), the IFC class + MasterFormat code (grounding-ready),
the detector confidence, a ``source_bbox`` in sheet pixels (the evidence link for the
human-in-the-loop / liability story, ADR-0008), and ``produced_by``/``model_version`` for
the audit trail. Predictions are stamped ``research`` / ``unknown`` — a derived inference
output has no source license (mirrors :mod:`eval.frontier`); the two-lane discipline
governs *training data*, not predictions.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from cir import (
    DataLane,
    Discipline,
    DrawingSet,
    Entity,
    EntityType,
    Geometry,
    LicenseProvenance,
    OntologyCodes,
    Sheet,
    SourceBBox,
    SourceFile,
    View,
    ViewType,
)
from eval.adapters import ModelAdapter
from eval.tasks import EvalSample
from ingest import TileDetection, aggregate, tile_image

from .detector import TrainedDetector
from .labels import BY_LABEL


class DetectorAdapter(ModelAdapter):
    """Run the trained detector over a sheet image and emit a CIR :class:`~cir.DrawingSet`."""

    is_stochastic = False  # inference is deterministic at a fixed confidence threshold

    def __init__(
        self,
        detector: TrainedDetector,
        *,
        tile_size: int = 1536,
        overlap: int = 192,
        aggregate_iou: float = 0.5,
        name: str = "cdai-detector",
        model_version: str = "0.1.0",
        data_lane: DataLane = DataLane.RESEARCH,
        license_provenance: LicenseProvenance = LicenseProvenance.UNKNOWN,
    ) -> None:
        self.detector = detector
        self.tile_size = tile_size
        self.overlap = overlap
        self.aggregate_iou = aggregate_iou
        self.name = name
        self.model_version = model_version
        self.data_lane = data_lane
        self.license_provenance = license_provenance

    def predict(self, sample: EvalSample, *, seed: int = 0) -> DrawingSet:
        if sample.image_path is None:
            raise ValueError(
                f"{self.name} needs sample.image_path (the sheet image) to detect symbols."
            )
        tiled = tile_image(
            sample.image_path,
            sheet_id=sample.id,
            tile_size=self.tile_size,
            overlap=self.overlap,
        )

        tile_detections: list[TileDetection] = []
        for tile in tiled.tiles:
            for symbol in self.detector.predict_tile(tile.image):
                tile_detections.append(
                    TileDetection(
                        tile_id=tile.ref.tile_id,
                        label=symbol.label,
                        bbox=symbol.bbox,  # tile-local-normalized — the contract's frame
                        score=symbol.score,
                    )
                )

        # The one audited place coordinates compose back + dedup across seams.
        sheet_detections = aggregate(tile_detections, tiled.refs, iou_threshold=self.aggregate_iou)

        entities = [
            self._to_entity(det, index, tiled.full_width, tiled.full_height)
            for index, det in enumerate(sheet_detections)
        ]
        view = View(name="prediction", view_type=ViewType.PLAN, entities=entities)
        sheet = Sheet(sheet_number="E-101", discipline=Discipline.ELECTRICAL, views=[view])
        return DrawingSet(
            name=f"{self.name} prediction for {sample.id}",
            source=SourceFile(
                filename=str(sample.image_path), file_type="image", ingest_tool=self.name
            ),
            sheets=[sheet],
            license_provenance=self.license_provenance,
            data_lane=self.data_lane,
        )

    def _to_entity(self, det: Any, index: int, full_w: int, full_h: int) -> Entity:
        """Turn one sheet-normalized :class:`~ingest.handoff.SheetDetection` into an Entity."""
        box = det.bbox
        cls = BY_LABEL.get(det.label)
        ontology = OntologyCodes(masterformat=cls.masterformat) if cls else OntologyCodes()
        return Entity(
            id=f"{self.name}-{index}",
            entity_type=cls.entity_type if cls else EntityType.OTHER,
            label=det.label,
            geometry=Geometry.box(box.x_min, box.y_min, box.x_max, box.y_max),
            ifc_class=cls.ifc_class if cls else None,
            ontology=ontology,
            # Pixel-exact evidence on the source sheet (the human-in-the-loop link).
            source_bbox=SourceBBox(
                x_min=box.x_min * full_w,
                y_min=box.y_min * full_h,
                x_max=box.x_max * full_w,
                y_max=box.y_max * full_h,
                unit="px",
            ),
            confidence=max(0.0, min(1.0, det.score)),
            produced_by=self.name,
            model_version=self.model_version,
            attributes={"source_tile_ids": list(det.source_tile_ids)},
            license_provenance=self.license_provenance,
            data_lane=self.data_lane,
        )

    @classmethod
    def from_config(cls, cfg: Any, *, weights: str | Path | None = None) -> DetectorAdapter:
        """Build an adapter from a detector config (uses the ``infer`` block + weights)."""
        from .detector import latest_best_weights

        weights_path = (
            Path(weights)
            if weights is not None
            else latest_best_weights(cfg.train.project, cfg.train.name)
        )
        detector = TrainedDetector(
            weights_path,
            conf=float(cfg.infer.conf),
            iou=float(cfg.infer.iou),
            imgsz=int(cfg.data.imgsz),
        )
        return cls(
            detector,
            tile_size=int(cfg.infer.tile_size),
            overlap=int(cfg.infer.overlap),
            aggregate_iou=float(cfg.infer.aggregate_iou),
            name=f"cdai-detector-{cfg.profile}",
            model_version=f"detector-{cfg.profile}",
            data_lane=DataLane(str(cfg.data_lane)),
        )
