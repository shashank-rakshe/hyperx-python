"""Synthetic CIR -> YOLO dataset export for the electrical symbol detector.

Turns the synthetic engine's output (rendered plan sheets + their CIR ground truth)
into a YOLO detection dataset. Two design choices keep training honest and consistent
with inference:

* **Tile the same way inference does.** Each plan sheet is split with
  :func:`ingest.tiling.tile_image` using the *same* ``tile_size``/``overlap`` the
  :class:`~perception.adapter.DetectorAdapter` uses at inference, and boxes are written
  in **tile-local-normalized** coordinates — exactly the frame the L0->L1 handoff
  contract (``docs/HANDOFF.md``) says L1 returns. So the model trains on, and predicts
  in, the same coordinate frame, and symbols appear at the same pixel scale in both.
* **Persist the split.** The exact train/val sample partition is written to
  ``split.json`` so the synthetic-validation **scoreboard** can score the trained model
  on precisely the held-out samples — no train/val leakage, and no second place to keep
  the split in sync.

Only device/panel **symbols** become detection labels (everything routed through
:func:`perception.labels.is_detectable`); walls, room tags, dimensions and schedule rows
are not detection targets. **DELP/SkeySpot is deliberately excluded**: its public release
is count-level only (no bounding boxes), so it cannot supply detection ground truth (see
``docs/DECISIONS.md`` ADR-0010). The synthetic engine is the only boxed electrical source
in v0.
"""

from __future__ import annotations

import hashlib
import json
import logging
import shutil
from dataclasses import dataclass, field
from pathlib import Path

import cir
from cir import BBox, DrawingSet, Sheet, ViewType
from ingest import tile_image

from .labels import CLASS_NAMES, LABEL_TO_INDEX, is_detectable

logger = logging.getLogger(__name__)

#: The rendered plan-sheet image roles the export reads (clean always; degraded optional).
_PLAN_CLEAN = "plan.png"
_PLAN_DEGRADED = "plan.deg.png"


@dataclass
class ExportResult:
    """Summary of one dataset export (what landed, and the exact split used)."""

    dataset_yaml: Path
    export_root: Path
    n_train_images: int = 0
    n_val_images: int = 0
    n_boxes: int = 0
    train_samples: list[str] = field(default_factory=list)
    val_samples: list[str] = field(default_factory=list)
    class_names: list[str] = field(default_factory=lambda: list(CLASS_NAMES))

    @property
    def n_train_samples(self) -> int:
        return len(self.train_samples)

    @property
    def n_val_samples(self) -> int:
        return len(self.val_samples)


def discover_samples(synthetic_root: str | Path) -> list[Path]:
    """Sorted ``sample_*`` dirs under ``synthetic_root`` that have CIR GT + a plan image."""
    root = Path(synthetic_root)
    if not root.is_dir():
        raise FileNotFoundError(
            f"synthetic_root {root} does not exist. Generate the pilot first, e.g.\n"
            f"  python -m synthetic.generate --type electrical --n 200 "
            f"--degradation-range 0..3 --out {root} --style-seed 0"
        )
    samples = [
        d
        for d in sorted(root.glob("sample_*"))
        if (d / "ground_truth.cir").is_file() and (d / _PLAN_CLEAN).is_file()
    ]
    if not samples:
        raise FileNotFoundError(f"no usable samples (ground_truth.cir + plan.png) under {root}")
    return samples


def assign_split(sample_names: list[str], *, val_fraction: float, seed: int) -> dict[str, str]:
    """Deterministically map each sample name to ``"train"`` or ``"val"``.

    Uses a stable hash (not Python's salted ``hash``) so the partition is identical
    across runs and machines — essential for a reproducible held-out scoreboard.
    """
    split: dict[str, str] = {}
    for name in sample_names:
        digest = hashlib.sha1(f"{seed}:{name}".encode()).hexdigest()
        frac = int(digest[:15], 16) / float(0x1000000000000000)  # 60 bits -> [0,1)
        split[name] = "val" if frac < val_fraction else "train"
    return split


def plan_sheet(ds: DrawingSet) -> Sheet:
    """The plan sheet of a synthetic electrical set (the one carrying the device symbols)."""
    for sheet in ds.sheets:
        if any(view.view_type is ViewType.PLAN for view in sheet.views):
            return sheet
    return ds.sheets[0]  # renderer always emits the plan first; defensive fallback


def detection_targets(sheet: Sheet) -> list[tuple[str, BBox]]:
    """(label, sheet-normalized bbox) for every detectable symbol on ``sheet``."""
    out: list[tuple[str, BBox]] = []
    for entity in sheet.iter_entities():
        if entity.label is None or not is_detectable(entity.label) or entity.geometry is None:
            continue
        box = entity.geometry.bounds()
        if box is not None and box.area > 0.0:
            out.append((entity.label, box))
    return out


def _clip01(v: float) -> float:
    return 0.0 if v < 0.0 else 1.0 if v > 1.0 else v


def _yolo_lines_for_tile(
    targets: list[tuple[str, BBox]], ref: object, *, min_box_area: float
) -> list[str]:
    """YOLO label lines (``cls cx cy w h``, tile-local-normalized) for one tile.

    A target belongs to a tile when its **center** falls in the tile's region (so a
    symbol in the overlap band is owned by both neighbours and the model sees it whole
    in at least one). The box is mapped to tile-local coords and clipped to the tile.
    """
    lines: list[str] = []
    for label, box in targets:
        center = box.center
        if not ref.region.contains_point(center):  # type: ignore[attr-defined]
            continue
        tbox = ref.sheet_box_to_tile(box)  # type: ignore[attr-defined]
        x0, y0 = _clip01(tbox.x_min), _clip01(tbox.y_min)
        x1, y1 = _clip01(tbox.x_max), _clip01(tbox.y_max)
        w, h = x1 - x0, y1 - y0
        if w <= 0.0 or h <= 0.0 or (w * h) < min_box_area:
            continue
        cx, cy = x0 + w / 2.0, y0 + h / 2.0
        lines.append(f"{LABEL_TO_INDEX[label]} {cx:.6f} {cy:.6f} {w:.6f} {h:.6f}")
    return lines


def export_yolo_dataset(
    *,
    synthetic_root: str | Path,
    export_root: str | Path,
    val_fraction: float = 0.2,
    limit_samples: int | None = None,
    tile_size: int = 1536,
    overlap: int = 192,
    include_degraded: bool = False,
    min_box_area: float = 1e-6,
    seed: int = 0,
) -> ExportResult:
    """Export synthetic plan sheets to a tiled YOLO dataset; return what was written.

    Writes the ultralytics layout (``images/{train,val}`` + ``labels/{train,val}`` +
    ``dataset.yaml``) and ``split.json`` (the exact sample partition for the scoreboard).
    Tiles with no symbols are kept as background negatives (empty label files).
    """
    export = Path(export_root)
    samples = discover_samples(synthetic_root)
    if limit_samples is not None:
        samples = samples[:limit_samples]
    split = assign_split([s.name for s in samples], val_fraction=val_fraction, seed=seed)

    # Clean slate: stale tiles from a previous split would silently corrupt train/val.
    for sub in ("images/train", "images/val", "labels/train", "labels/val"):
        target = export / sub
        if target.exists():
            shutil.rmtree(target)
        target.mkdir(parents=True, exist_ok=True)

    result = ExportResult(dataset_yaml=export / "dataset.yaml", export_root=export)
    for sample_dir in samples:
        fold = split[sample_dir.name]
        ds = cir.load(DrawingSet, str(sample_dir / "ground_truth.cir"))
        targets = detection_targets(plan_sheet(ds))

        variants = [(_PLAN_CLEAN, "clean")]
        if include_degraded and (sample_dir / _PLAN_DEGRADED).is_file():
            variants.append((_PLAN_DEGRADED, "deg"))

        for filename, tag in variants:
            tiled = tile_image(
                sample_dir / filename,
                sheet_id=sample_dir.name,
                tile_size=tile_size,
                overlap=overlap,
            )
            for tile in tiled.tiles:
                ref = tile.ref
                stem = f"{sample_dir.name}_{tag}_r{ref.row}c{ref.col}"
                lines = _yolo_lines_for_tile(targets, ref, min_box_area=min_box_area)
                tile.image.save(export / f"images/{fold}/{stem}.png")
                (export / f"labels/{fold}/{stem}.txt").write_text(
                    "\n".join(lines) + ("\n" if lines else ""), encoding="utf-8"
                )
                result.n_boxes += len(lines)
                if fold == "train":
                    result.n_train_images += 1
                else:
                    result.n_val_images += 1

        (result.train_samples if fold == "train" else result.val_samples).append(sample_dir.name)

    _write_dataset_yaml(export)
    (export / "split.json").write_text(
        json.dumps(
            {
                "synthetic_root": str(Path(synthetic_root)),
                "seed": seed,
                "val_fraction": val_fraction,
                "include_degraded": include_degraded,
                "tile_size": tile_size,
                "overlap": overlap,
                "train": sorted(result.train_samples),
                "val": sorted(result.val_samples),
            },
            indent=2,
        ),
        encoding="utf-8",
    )
    logger.info(
        "exported YOLO dataset: %d train / %d val images, %d boxes, %d/%d samples -> %s",
        result.n_train_images,
        result.n_val_images,
        result.n_boxes,
        result.n_train_samples,
        result.n_val_samples,
        export,
    )
    return result


def _write_dataset_yaml(export: Path) -> None:
    """Write the ultralytics ``dataset.yaml`` (absolute ``path`` so it resolves anywhere)."""
    names_block = "\n".join(f"  {i}: {name}" for i, name in enumerate(CLASS_NAMES))
    export.mkdir(parents=True, exist_ok=True)
    (export / "dataset.yaml").write_text(
        "# Auto-generated by perception.dataset.export_yolo_dataset — do not edit by hand.\n"
        f"path: {export.resolve()}\n"
        "train: images/train\n"
        "val: images/val\n"
        f"nc: {len(CLASS_NAMES)}\n"
        "names:\n"
        f"{names_block}\n",
        encoding="utf-8",
    )


def export_from_config(cfg: object) -> ExportResult:
    """Export driven by a detector config's ``data`` block (see ``perception/conf``)."""
    from .config import resolve

    data = cfg.data  # type: ignore[attr-defined]
    return export_yolo_dataset(
        synthetic_root=resolve(data.synthetic_root),
        export_root=resolve(data.export_root),
        val_fraction=float(data.val_fraction),
        limit_samples=(None if data.limit_samples is None else int(data.limit_samples)),
        tile_size=int(data.tile_size),
        overlap=int(data.overlap),
        include_degraded=bool(data.include_degraded),
        min_box_area=float(data.min_box_area),
        seed=int(cfg.seed),  # type: ignore[attr-defined]
    )
