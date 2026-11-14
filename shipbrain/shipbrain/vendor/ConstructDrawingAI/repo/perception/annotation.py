"""Model-assisted annotation pipeline for the REAL test sets (Build Playbook A9).

Turning real plan sheets into the held-out real-drawing scoreboard is a human task, but
the human's time is the scarcest resource — so we bootstrap it: select sheets from the
Missouri index, rasterize them, **pre-label** with the trained detector, and hand a human
a Label Studio project where they only correct. Corrections come back as CIR pairs the
scoreboard loads with zero new plumbing.

Flow (each step a function below; the interactive labeling is the only manual part):

1. :func:`select_sheets` — pick N sheets of a discipline from ``index.json``, spread across
   ≥ ``min_projects`` projects (no single-firm bias).
2. :func:`build_annotation_batch` — rasterize each at ≥300 DPI, pre-label with the detector
   (electrical), and write a Label Studio ``import.json`` (tasks + pre-annotations) plus a
   ``label_config.xml``.
3. *(human)* run Label Studio, import, correct, export.
4. :func:`ingest_label_studio_export` — export JSON → CIR pairs under
   ``datasets/real/<discipline>/`` (``<stem>.cir`` + ``<stem>.png``), which
   :func:`perception.scoreboard.load_real_samples` consumes directly.

Label Studio boxes are in **percent** of the image; CIR geometry is normalized ``[0,1]`` —
the converters here are the one audited place that mapping happens. They are torch-free and
tested; only the batch builder touches the detector (lazily).
"""

from __future__ import annotations

import json
import logging
import shutil
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

from .labels import CLASS_NAMES

logger = logging.getLogger(__name__)

#: Architectural pre-label vocabulary (no arch detector yet; humans label from scratch).
ARCH_LABELS = ["Door", "Window", "Room", "Wall", "Column", "Stair"]
#: Discipline letter -> (CIR Discipline, label vocabulary for the Label Studio config).
_DISCIPLINE = {
    "E": (Discipline.ELECTRICAL, CLASS_NAMES),
    "A": (Discipline.ARCHITECTURAL, ARCH_LABELS),
}
# Real plan sheets are public records with A/E copyright -> research/eval lane.
_PROV: dict[str, Any] = {
    "license_provenance": LicenseProvenance.UNKNOWN,
    "data_lane": DataLane.RESEARCH,
}


def label_config(labels: list[str]) -> str:
    """A Label Studio labeling-config XML: bounding boxes over an image, given classes."""
    tags = "\n".join(f'    <Label value="{name}"/>' for name in labels)
    return (
        '<View>\n  <Image name="image" value="$image"/>\n'
        '  <RectangleLabels name="label" toName="image">\n'
        f"{tags}\n  </RectangleLabels>\n</View>\n"
    )


# ---------------------------------------------------------------------------
# CIR <-> Label Studio (the one audited coordinate mapping: normalized [0,1] <-> percent)
# ---------------------------------------------------------------------------
def cir_to_ls_results(ds: DrawingSet) -> list[dict[str, Any]]:
    """Each boxed entity → a Label Studio ``rectanglelabels`` result (percent coords)."""
    results: list[dict[str, Any]] = []
    for i, entity in enumerate(ds.iter_entities()):
        box = entity.geometry.bounds() if entity.geometry is not None else None
        if box is None or entity.label is None:
            continue
        results.append(
            {
                "id": f"r{i}",
                "type": "rectanglelabels",
                "from_name": "label",
                "to_name": "image",
                "value": {
                    "x": 100.0 * box.x_min,
                    "y": 100.0 * box.y_min,
                    "width": 100.0 * max(0.0, box.width),
                    "height": 100.0 * max(0.0, box.height),
                    "rectanglelabels": [entity.label],
                },
            }
        )
    return results


def ls_results_to_entities(results: list[dict[str, Any]]) -> list[Entity]:
    """Label Studio ``rectanglelabels`` results → CIR entities (percent → normalized)."""
    entities: list[Entity] = []
    for res in results:
        if res.get("type") != "rectanglelabels":
            continue
        v = res["value"]
        labels = v.get("rectanglelabels") or []
        if not labels:
            continue
        x0, y0 = v["x"] / 100.0, v["y"] / 100.0
        x1, y1 = x0 + v["width"] / 100.0, y0 + v["height"] / 100.0
        entities.append(
            Entity(
                entity_type=EntityType.SYMBOL,
                label=labels[0],
                geometry=Geometry.box(x0, y0, x1, y1),
                confidence=1.0,  # a human-verified annotation
                **_PROV,
            )
        )
    return entities


# ---------------------------------------------------------------------------
# Selection from the Missouri index
# ---------------------------------------------------------------------------
def select_sheets(
    index: dict[str, Any], *, letter: str, count: int, min_projects: int = 5
) -> list[dict[str, Any]]:
    """Pick ``count`` sheets of discipline ``letter``, round-robin across projects."""
    by_project: dict[str, list[dict[str, Any]]] = {}
    for s in index["sets"]:
        for p in s["pages"]:
            if (p["discipline_letter"] or "")[:1] == letter and p["sheet_no"]:
                by_project.setdefault(s["project"], []).append(
                    {
                        "project": s["project"],
                        "filename": s["filename"],
                        "page": p["page"],
                        "sheet_no": p["sheet_no"],
                    }
                )
    projects = sorted(by_project)
    if len(projects) < min_projects:
        raise ValueError(f"only {len(projects)} projects have '{letter}' sheets (< {min_projects})")
    picked: list[dict[str, Any]] = []
    round_i = 0
    while len(picked) < count and any(round_i < len(by_project[p]) for p in projects):
        for p in projects:
            if round_i < len(by_project[p]):
                picked.append(by_project[p][round_i])
                if len(picked) >= count:
                    break
        round_i += 1
    return picked


# ---------------------------------------------------------------------------
# Batch builder (rasterize + pre-label + Label Studio import)
# ---------------------------------------------------------------------------
def build_annotation_batch(
    index_path: str | Path,
    out_dir: str | Path,
    *,
    letter: str = "E",
    count: int = 40,
    missouri_root: str | Path = "data/real/plansets/missouri",
    detector_adapter: Any = None,
    dpi: int = 300,
    min_projects: int = 5,
) -> dict[str, Any]:
    """Select + rasterize + (electrical) pre-label sheets → a Label Studio import batch."""
    from datasets.realsets import rasterize_sheet
    from eval.tasks import CLEAN, RASTER, EvalSample, Slice

    index = json.loads(Path(index_path).read_text())
    discipline, labels = _DISCIPLINE.get(letter, (Discipline.OTHER, CLASS_NAMES))
    sheets = select_sheets(index, letter=letter, count=count, min_projects=min_projects)

    out = Path(out_dir)
    images_dir = out / "images"
    images_dir.mkdir(parents=True, exist_ok=True)
    tasks: list[dict[str, Any]] = []
    for sheet in sheets:
        stem = f"{sheet['project']}_{sheet['sheet_no']}_p{sheet['page']}".replace("/", "_")
        image_path = images_dir / f"{stem}.png"
        if not image_path.is_file():
            rasterize_sheet(
                Path(missouri_root) / sheet["filename"], sheet["page"], image_path, dpi=dpi
            )
        from PIL import Image

        Image.MAX_IMAGE_PIXELS = None  # trusted plan rasters are legitimately gigapixel
        width, height = Image.open(image_path).size
        predictions: list[dict[str, Any]] = []
        if detector_adapter is not None:
            sample = EvalSample(
                id=stem,
                ground_truth=DrawingSet(name=stem, **_PROV),
                slice=Slice("mep", RASTER, CLEAN, "missouri"),
                image_path=image_path,
            )
            pred = detector_adapter.predict(sample)
            predictions = [
                {
                    "model_version": getattr(detector_adapter, "name", "detector"),
                    "result": cir_to_ls_results(pred),
                }
            ]
        task: dict[str, Any] = {
            "data": {"image": f"images/{stem}.png"},
            "meta": {
                "project": sheet["project"],
                "sheet_no": sheet["sheet_no"],
                "width": width,
                "height": height,
            },
        }
        if predictions and predictions[0]["result"]:
            task["predictions"] = predictions
        tasks.append(task)

    (out / "import.json").write_text(json.dumps(tasks, indent=2), encoding="utf-8")
    (out / "label_config.xml").write_text(label_config(list(labels)), encoding="utf-8")
    logger.info(
        "annotation batch: %d %s-sheets -> %s (%d pre-labeled)",
        len(tasks),
        letter,
        out,
        sum(1 for t in tasks if t.get("predictions")),
    )
    return {"n_sheets": len(tasks), "discipline": discipline.value, "out_dir": str(out)}


# ---------------------------------------------------------------------------
# Ingest a Label Studio export back into CIR real-board pairs
# ---------------------------------------------------------------------------
def ingest_label_studio_export(
    export_path: str | Path,
    out_dir: str | Path,
    *,
    images_dir: str | Path,
    discipline: Discipline = Discipline.ELECTRICAL,
) -> int:
    """Label Studio export JSON → CIR pairs (``<stem>.cir`` + ``<stem>.png``) for the real board."""
    export = json.loads(Path(export_path).read_text())
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    n = 0
    for task in export:
        image_ref = (task.get("data") or {}).get("image", "")
        stem = Path(image_ref).stem
        annotations = task.get("annotations") or []
        results = annotations[0].get("result", []) if annotations else []
        entities = ls_results_to_entities(results)
        ds = DrawingSet(
            name=stem,
            source=SourceFile(
                filename=f"{stem}.png", file_type="image", ingest_tool="label-studio"
            ),
            sheets=[
                Sheet(
                    sheet_number=stem[:32] or "S-1",
                    discipline=discipline,
                    views=[View(view_type=ViewType.PLAN, entities=entities)],
                )
            ],
            metadata={"annotated": True, "source_batch": str(export_path)},
            **_PROV,
        )
        cir.save(ds, str(out / f"{stem}.cir"))
        src_img = Path(images_dir) / f"{stem}.png"
        if src_img.is_file():
            shutil.copy(src_img, out / f"{stem}.png")
        n += 1
    logger.info("ingested %d annotated sheets -> %s", n, out)
    return n


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main(argv: list[str] | None = None) -> int:  # pragma: no cover - thin CLI
    import argparse

    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    parser = argparse.ArgumentParser(prog="python -m perception.annotation")
    sub = parser.add_subparsers(dest="cmd", required=True)

    b = sub.add_parser("build", help="Select + rasterize + pre-label a Label Studio batch.")
    b.add_argument("--letter", default="E")
    b.add_argument("--count", type=int, default=40)
    b.add_argument("--index", default="data/real/plansets/missouri/index.json")
    b.add_argument("--missouri-root", default="data/real/plansets/missouri")
    b.add_argument("--out", default=None, help="default: datasets/real/_annotation/<discipline>")
    b.add_argument("--profile", default="local_debug")
    b.add_argument("--dpi", type=int, default=300)
    b.add_argument("--no-prelabel", action="store_true")
    b.add_argument(
        "--prelabel-conf",
        type=float,
        default=None,
        help="detector confidence for pre-labels (raise to curb over-firing, e.g. 0.5).",
    )

    ig = sub.add_parser("ingest", help="Label Studio export JSON -> CIR real-board pairs.")
    ig.add_argument("--export", required=True)
    ig.add_argument("--images", required=True)
    ig.add_argument("--out", required=True)
    ig.add_argument("--discipline", default="electrical")

    ns = parser.parse_args(argv)
    if ns.cmd == "build":
        out = (
            ns.out
            or f"datasets/real/_annotation/{_DISCIPLINE.get(ns.letter, (Discipline.OTHER,))[0].value}"
        )
        detector = None
        if ns.letter == "E" and not ns.no_prelabel:
            from .adapter import DetectorAdapter
            from .config import load_config

            cfg = load_config("detector", ns.profile)
            if ns.prelabel_conf is not None:
                cfg.infer.conf = ns.prelabel_conf  # curb the sim-to-real over-firing (see A10)
            try:
                detector = DetectorAdapter.from_config(cfg)
            except FileNotFoundError:
                logger.warning("no trained detector weights; building batch without pre-labels")
        result = build_annotation_batch(
            ns.index,
            out,
            letter=ns.letter,
            count=ns.count,
            missouri_root=ns.missouri_root,
            detector_adapter=detector,
            dpi=ns.dpi,
        )
        print("built:", result)
    elif ns.cmd == "ingest":
        n = ingest_label_studio_export(
            ns.export, ns.out, images_dir=ns.images, discipline=Discipline(ns.discipline)
        )
        print(f"ingested {n} sheets -> {ns.out}")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
