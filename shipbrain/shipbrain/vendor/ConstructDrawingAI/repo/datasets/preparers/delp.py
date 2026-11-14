"""Preparer for DELP / SkeySpot — electrical service-key detection (CC-BY-4.0).

Source: https://github.com/HAIx-Lab/Skeyspot — the SkeySpot toolkit + YOLOv8 weights,
a sample plan, and per-plot detection-summary CSVs. The full annotated DELP dataset
(45 scanned plans, 34 service-key classes, Pascal-VOC/LabelImg boxes) is **gated** —
"available for academic research upon request to the authors."

**Only real ground truth becomes CIR.** This preparer materializes CIR entities
solely from Pascal-VOC (LabelImg) annotations — the actual ground truth. The public
repo's per-plot detection summaries are *model inference*, not ground truth, so they
are **deliberately not converted into the dataset/CIR layer** (see ``docs/DECISIONS.md``,
ADR-0010): a prediction must never be loadable as ground truth by the eval harness or
training. The summaries remain only in the raw layer (``datasets/raw/...``), where
they belong.

Until the licensed VOC set is dropped under ``raw/``, :meth:`convert` yields nothing.
The Pascal-VOC converter below is ready for that moment.
"""

from __future__ import annotations

import xml.etree.ElementTree as ET
from collections.abc import Iterator
from pathlib import Path

from cir import (
    Discipline,
    DrawingSet,
    Entity,
    EntityType,
    Geometry,
    PageSize,
    Sheet,
    SourceBBox,
    SourceFile,
    View,
    ViewType,
)

from .base import DatasetPreparer


class DELPPreparer(DatasetPreparer):
    """Download + convert the DELP/SkeySpot **ground truth** (Pascal-VOC) into CIR."""

    name = "DELP-SkeySpot"
    repo_url = "https://github.com/HAIx-Lab/Skeyspot.git"

    def download(self) -> None:
        self.git_clone(self.repo_url)

    def convert(self) -> Iterator[DrawingSet]:
        # Ground truth only. Pascal-VOC (LabelImg) annotations -> CIR entities.
        # The repo's *_detection_summary.csv files are MODEL INFERENCE and are
        # intentionally NOT converted (they must never be mistaken for ground truth);
        # they stay in the raw layer. Yields nothing until the licensed VOC set lands.
        for xml_path in sorted(self.raw_dir.rglob("*.xml")):
            yield self._from_voc(xml_path)

    # -- Pascal VOC (ground-truth boxes; used once the full dataset is obtained) --
    def _from_voc(self, xml_path: Path) -> DrawingSet:
        root = ET.parse(xml_path).getroot()
        size = root.find("size")
        width = float((size.findtext("width") if size is not None else None) or 0)
        height = float((size.findtext("height") if size is not None else None) or 0)
        stem = xml_path.stem

        entities: list[Entity] = []
        for index, obj in enumerate(root.findall("object")):
            box = obj.find("bndbox")
            if box is None:
                continue
            label = (obj.findtext("name") or "symbol").strip()
            xmin = float(box.findtext("xmin") or 0)
            ymin = float(box.findtext("ymin") or 0)
            xmax = float(box.findtext("xmax") or 0)
            ymax = float(box.findtext("ymax") or 0)
            geometry = None
            if width > 0 and height > 0:
                geometry = Geometry.box(xmin / width, ymin / height, xmax / width, ymax / height)
            entities.append(
                Entity(
                    id=f"delp-{stem}-{index}",
                    entity_type=EntityType.SYMBOL,
                    label=label,
                    geometry=geometry,
                    source_bbox=SourceBBox(
                        x_min=xmin, y_min=ymin, x_max=xmax, y_max=ymax, unit="px", page=0
                    ),
                    confidence=1.0,  # ground-truth annotation
                    produced_by="labelimg",
                    attributes={"dataset": "DELP", "annotation": "voc-ground-truth"},
                    **self.stamp(),
                )
            )
        return self._wrap(stem, entities, width=width, height=height)

    def _wrap(
        self, stem: str, entities: list[Entity], *, width: float, height: float
    ) -> DrawingSet:
        size = PageSize(width=width, height=height, unit="px") if width > 0 and height > 0 else None
        view = View(id=f"delp-{stem}-v0", name=stem, view_type=ViewType.PLAN, entities=entities)
        sheet = Sheet(
            id=f"delp-{stem}-s0",
            sheet_number=stem,
            discipline=Discipline.ELECTRICAL,
            title=f"Electrical Layout Plan {stem}",
            size=size,
            views=[view],
        )
        return DrawingSet(
            id=f"delp-{stem}",
            name=f"DELP {stem}",
            project_name="DELP-SkeySpot",
            source=SourceFile(
                filename=f"{stem}.png",
                file_type="image",
                is_vector=False,
                ingest_tool="datasets.preparers.delp",
            ),
            sheets=[sheet],
            metadata={"dataset": "DELP-SkeySpot", "plot": stem, "annotation": "voc-ground-truth"},
            **self.stamp(),
        )
