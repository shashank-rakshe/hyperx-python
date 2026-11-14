"""Generic YOLO-dataset → CIR converter + the verified Roboflow electrical cluster.

Real annotated electrical symbols on real plans are the scarcest, highest-value data we
can get quickly (ADR-0011). The verified Roboflow Universe cluster below (from the
2026-07-02 sourcing pass) provides ~10k mostly-real annotated plan crops. This module:

* :data:`ROBOFLOW_ELECTRICAL` — the *verified* project list (tracked, reproducible), each
  tagged ``role`` = ``train`` or ``eval`` (never-train held-out stock);
* :func:`download_roboflow` — pull them as YOLOv8 exports (needs ``ROBOFLOW_API_KEY``);
* :func:`yolo_dir_to_cir` — convert **any** YOLO dataset (images + ``labels/*.txt`` +
  ``data.yaml``) into CIR :class:`~cir.DrawingSet` docs, one per image, boxes preserved in
  the project's own class vocabulary.

Provenance: these projects display CC BY 4.0, but the license is *uploader self-declared*
on drawings the uploader likely did not own — so everything here is stamped
``CC-BY`` / **research lane** (never commercial-lane training) until provenance diligence.
The real class names are preserved as-is; mapping them onto our detector vocabulary
(:mod:`perception.labels`) is a downstream sim-to-real step, not this converter's job.
"""

from __future__ import annotations

import logging
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import cir
from cir import (
    DataLane,
    Discipline,
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

logger = logging.getLogger(__name__)

_IMAGE_EXTS = (".jpg", ".jpeg", ".png", ".bmp")


@dataclass(frozen=True)
class RoboflowProject:
    """One verified Roboflow Universe project. ``role`` gates train-vs-eval use."""

    workspace: str
    project: str
    preferred_version: int | None  # try this first; else discover 1..8
    n_images: int
    n_classes: int
    role: str  # "train" (may train) | "eval" (never-train held-out stock)
    note: str = ""

    @property
    def slug(self) -> str:
        return f"roboflow__{self.project}"


#: Verified real-plan electrical projects (2026-07-02 sourcing). Self-declared CC BY.
ROBOFLOW_ELECTRICAL: list[RoboflowProject] = [
    # DELP/SkeySpot — the canonical REAL electrical-layout benchmark (IIT Gandhinagar,
    # arXiv 2508.10449), on Roboflow at iitgn-motpy/delp. 45 real UK plans, 2,450 boxes,
    # 34 service-key classes. HELD-OUT eval → this is the real-drawing scoreboard for
    # electrical (never train on it). Was previously request-only; now directly pullable.
    RoboflowProject(
        "iitgn-motpy",
        "delp",
        1,
        45,
        34,
        "eval",
        "DELP/SkeySpot real UK electrical layout plans — THE real benchmark",
    ),
    RoboflowProject(
        "icat",
        "blueprint-symbol-detection-cg16j-h53fr",
        None,
        2962,
        25,
        "train",
        "real residential lighting/electrical plans",
    ),
    RoboflowProject(
        "tradeplane",
        "lsb-receptacle-znhco",
        2,
        853,
        12,
        "train",
        "real CAD plan crops; 12 receptacle classes",
    ),
    RoboflowProject(
        "doxle-fmcyk", "electrical-plan-zirbr", None, 586, 6, "train", "real AU builder sheets"
    ),
    RoboflowProject(
        "bpai2", "detect_bp_fixture-ncp3d", 7, 5932, 19, "train", "mixed real/synthetic fixtures"
    ),
    RoboflowProject(
        "workspace-terhb",
        "electrical-plan",
        None,
        810,
        2,
        "train",
        "real; instance-seg (duplex/quad) -> boxes",
    ),
    RoboflowProject(
        "tradeplane",
        "mep_blueprints_objects-alfmj",
        None,
        32,
        93,
        "eval",
        "93-class MEP taxonomy reference; held-out eval stock",
    ),
]


# ---------------------------------------------------------------------------
# Download (Roboflow SDK)
# ---------------------------------------------------------------------------
def download_roboflow(
    projects: list[RoboflowProject],
    *,
    root: Path,
    api_key: str,
    fmt: str = "yolov8",
) -> dict[str, str]:
    """Download each project's YOLO export into ``root/electrical/<slug>/raw/`` (resumable)."""
    from roboflow import Roboflow

    rf = Roboflow(api_key=api_key)
    outcomes: dict[str, str] = {}
    for p in projects:
        dest = root / "electrical" / p.slug / "raw"
        if dest.exists() and any(dest.rglob("data.yaml")):
            outcomes[p.slug] = "skip"
            continue
        dest.mkdir(parents=True, exist_ok=True)
        proj = rf.workspace(p.workspace).project(p.project)
        candidates = (
            [p.preferred_version, *range(1, 9)] if p.preferred_version else list(range(1, 9))
        )
        last: Exception | None = None
        for v in dict.fromkeys(x for x in candidates if x):  # dedup, keep order
            try:
                # overwrite=True: with a pre-existing (even empty) location the SDK
                # reports success without actually writing any files.
                proj.version(v).download(fmt, location=str(dest), overwrite=True)
                outcomes[p.slug] = f"ok(v{v})"
                break
            except Exception as exc:
                last = exc
        else:
            outcomes[p.slug] = f"fail: {last}"
            logger.warning("roboflow download failed: %s (%s)", p.slug, last)
        logger.info("roboflow %s -> %s", p.slug, outcomes[p.slug])
    return outcomes


# ---------------------------------------------------------------------------
# YOLO dir -> CIR
# ---------------------------------------------------------------------------
def _read_names(data_yaml: Path) -> dict[int, str]:
    """Read the class-index → name map from a YOLO ``data.yaml`` (list or dict form)."""
    import yaml

    names = yaml.safe_load(data_yaml.read_text()).get("names", [])
    if isinstance(names, dict):
        return {int(k): str(v) for k, v in names.items()}
    return {i: str(n) for i, n in enumerate(names)}


def _label_path(image: Path) -> Path:
    """The YOLO label .txt for an image (``.../images/x.jpg`` → ``.../labels/x.txt``)."""
    return image.parent.parent / "labels" / (image.stem + ".txt")


def _boxes_to_entities(
    label_file: Path, names: dict[int, str], prov: dict[str, Any]
) -> list[Entity]:
    entities: list[Entity] = []
    if not label_file.is_file():
        return entities
    for line in label_file.read_text().splitlines():
        parts = line.split()
        if len(parts) < 5:
            continue
        cls, cx, cy, w, h = int(float(parts[0])), *(float(v) for v in parts[1:5])
        x0, y0, x1, y1 = cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2
        entities.append(
            Entity(
                entity_type=EntityType.SYMBOL,
                label=names.get(cls, str(cls)),
                geometry=Geometry.box(max(0.0, x0), max(0.0, y0), min(1.0, x1), min(1.0, y1)),
                confidence=1.0,  # ground-truth annotation
                **prov,
            )
        )
    return entities


def yolo_dir_to_cir(
    dataset_dir: Path,
    *,
    slug: str,
    out_dir: Path,
    license_provenance: LicenseProvenance = LicenseProvenance.CC_BY,
    data_lane: DataLane = DataLane.RESEARCH,
    copy_images: bool = False,
) -> int:
    """Convert a YOLO dataset (all train/valid/test splits) → one CIR doc per image.

    ``copy_images=True`` also copies each image next to its ``.cir`` (same stem) — the flat
    (image + CIR) layout the real-drawing scoreboard loader consumes, used for held-out eval
    sets like DELP so they drop straight into the real board.
    """
    data_yaml = next(dataset_dir.rglob("data.yaml"), None)
    if data_yaml is None:
        raise FileNotFoundError(f"no data.yaml under {dataset_dir}")
    names = _read_names(data_yaml)
    prov: dict[str, Any] = {"license_provenance": license_provenance, "data_lane": data_lane}
    out_dir.mkdir(parents=True, exist_ok=True)
    images = [
        p
        for p in data_yaml.parent.rglob("*")
        if p.suffix.lower() in _IMAGE_EXTS and p.parent.name == "images"
    ]
    n = 0
    for image in sorted(images):
        entities = _boxes_to_entities(_label_path(image), names, prov)
        ds = DrawingSet(
            name=f"{slug}/{image.stem}",
            source=SourceFile(filename=image.name, file_type="image", ingest_tool="roboflow-yolo"),
            sheets=[
                Sheet(
                    sheet_number=image.stem[:32] or "S-1",
                    discipline=Discipline.ELECTRICAL,
                    views=[View(view_type=ViewType.PLAN, entities=entities)],
                )
            ],
            metadata={"slug": slug, "src_image": str(image), "split": image.parent.parent.name},
            **prov,
        )
        cir.save(ds, str(out_dir / f"{slug}__{image.stem}.cir"))
        if copy_images:
            shutil.copy(image, out_dir / f"{slug}__{image.stem}{image.suffix}")
        n += 1
    logger.info("converted %s: %d images -> CIR (%d classes)", slug, n, len(names))
    return n
