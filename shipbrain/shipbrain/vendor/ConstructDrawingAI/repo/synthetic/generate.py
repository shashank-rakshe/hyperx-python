"""The synthetic-data engine CLI and pipeline.

For every sample: build the canonical model (parametric scene, or a real IFC file) →
render pixels + CIR in one auditable pass → **validate the CIR against the model**
(fail-fast: a mismatch is a generator bug, never written) → assert the provenance stamp →
degrade the images (image-only) → write the sample.

Usage::

    python -m synthetic.generate --type electrical --n 1000 --degradation-range 0..3 \
        --out datasets/synthetic/electrical --style-seed 0 --qa-pairs

Each sample directory holds the clean and degraded images per sheet, the canonical CIR
ground truth (``ground_truth.cir``), the source model (``model.json``), the style and
degradation parameters, the connectivity-graph dump (``graph.json``), and the validation
report. Everything is stamped ``synthetic-owned`` / ``commercial`` — the engine cannot emit
anything else (:func:`~synthetic.provenance.assert_synthetic_owned`).
"""

from __future__ import annotations

import argparse
import json
import random
from collections.abc import Sequence
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import cir

from .expect import expected_ground_truth
from .model import ElectricalModel
from .provenance import ENGINE_VERSION, SYNTHETIC_LANE, SYNTHETIC_LICENSE, assert_synthetic_owned
from .qa import template_qa_pairs
from .render import RenderedSample, render
from .style import sample_style

_ELECTRICAL_TYPES = {"electrical", "mep"}


class GeneratorBugError(RuntimeError):
    """Raised when a rendered sample fails ground-truth validation — a bug to fix, not ship."""


@dataclass(frozen=True)
class GenerateConfig:
    """Validated configuration for a synthetic generation run."""

    drawing_type: str
    count: int
    degradation_min: int
    degradation_max: int
    out_dir: str
    seed: int
    style_seed: int
    qa_pairs: bool = False
    validate: bool = True
    write_svg: bool = True
    ifc_path: str | None = None


@dataclass
class SampleSummary:
    """One sample's headline facts, for the run summary."""

    sample_id: str
    n_devices: int
    n_circuits: int
    degradation_level: int
    valid: bool
    issues: list[str] = field(default_factory=list)


@dataclass
class GenerateResult:
    """The outcome of a run — including the all-important validator pass rate."""

    out_dir: str
    config: GenerateConfig
    samples: list[SampleSummary] = field(default_factory=list)

    @property
    def validated_ok(self) -> int:
        return sum(1 for s in self.samples if s.valid)

    @property
    def all_valid(self) -> bool:
        return all(s.valid for s in self.samples)


# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------
def _parse_degradation_range(text: str) -> tuple[int, int]:
    lo_str, _, hi_str = text.partition("..")
    if not hi_str:
        lo_str = hi_str = text
    try:
        lo, hi = int(lo_str), int(hi_str)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(
            f"Invalid --degradation-range {text!r}; expected 'lo..hi', e.g. '0..3'."
        ) from exc
    if lo > hi or lo < 0:
        raise argparse.ArgumentTypeError(
            f"Invalid --degradation-range {text!r}; require 0 <= lo <= hi."
        )
    return lo, hi


def build_parser() -> argparse.ArgumentParser:
    """Build the ``synthetic.generate`` argument parser."""
    parser = argparse.ArgumentParser(
        prog="python -m synthetic.generate",
        description="Render synthetic construction drawings from a model with CIR ground truth.",
    )
    parser.add_argument(
        "--type",
        dest="drawing_type",
        default="electrical",
        choices=["electrical", "mep", "architectural", "structural", "pid"],
        help="Drawing type (v0 is electrical-only; others are a later step).",
    )
    parser.add_argument("--n", dest="count", type=int, default=100, help="Number of samples.")
    parser.add_argument(
        "--degradation-range",
        type=_parse_degradation_range,
        default=(0, 3),
        help="Degradation severity range, e.g. '0..3' (0 = clean).",
    )
    parser.add_argument("--out", dest="out_dir", required=True, help="Output (DVC-tracked) path.")
    parser.add_argument("--seed", type=int, default=0, help="RNG seed (scene + degradation).")
    parser.add_argument(
        "--style-seed",
        dest="style_seed",
        type=int,
        default=None,
        help="Drafting-style seed (defaults to --seed).",
    )
    parser.add_argument(
        "--qa-pairs", dest="qa_pairs", action="store_true", help="Attach grounded QA pairs."
    )
    parser.add_argument(
        "--no-validate",
        dest="no_validate",
        action="store_true",
        help="Skip the ground-truth validator (NOT recommended).",
    )
    parser.add_argument(
        "--no-svg", dest="no_svg", action="store_true", help="Do not also write SVG artifacts."
    )
    parser.add_argument(
        "--ifc",
        dest="ifc_path",
        default=None,
        help="Source from this IFC file instead of the parametric scene.",
    )
    return parser


def parse_args(argv: Sequence[str] | None = None) -> GenerateConfig:
    """Parse ``argv`` into a validated :class:`GenerateConfig`."""
    ns = build_parser().parse_args(argv)
    lo, hi = ns.degradation_range
    return GenerateConfig(
        drawing_type=ns.drawing_type,
        count=ns.count,
        degradation_min=lo,
        degradation_max=hi,
        out_dir=ns.out_dir,
        seed=ns.seed,
        style_seed=ns.seed if ns.style_seed is None else ns.style_seed,
        qa_pairs=ns.qa_pairs,
        validate=not ns.no_validate,
        write_svg=not ns.no_svg,
        ifc_path=ns.ifc_path,
    )


# ---------------------------------------------------------------------------
# Pipeline
# ---------------------------------------------------------------------------
def _build_model(config: GenerateConfig, index: int) -> ElectricalModel:
    """Build sample ``index``'s canonical model (parametric scene or IFC)."""
    model_id = f"syn-elec-{config.seed:06d}-{index:05d}"
    if config.ifc_path:
        from .ifc_source import load_electrical_model

        return load_electrical_model(config.ifc_path, model_id=model_id)
    from .scene import build_electrical_model

    return build_electrical_model(seed=config.seed + index, model_id=model_id)


def plan_graph(ground_truth: cir.DrawingSet) -> dict[str, Any]:
    """Extract the plan view's connectivity graph as a readable dict (for eyeballing)."""
    plan = ground_truth.sheets[0].views[0]
    nodes = []
    for e in plan.entities:
        box = e.geometry.bounds() if e.geometry is not None else None
        center = box.center if box is not None else None
        if e.entity_type.value in ("symbol", "equipment"):
            nodes.append(
                {
                    "id": e.id,
                    "label": e.label,
                    "ifc_class": e.ifc_class,
                    "center": [round(center.x, 4), round(center.y, 4)] if center else None,
                    "circuit": e.attributes.get("circuit"),
                }
            )
    edges = [
        {
            "type": c.connection_type,
            "source": c.source_id,
            "target": c.target_id,
            "circuit": c.attributes.get("circuit"),
        }
        for c in plan.connections
    ]
    return {"sheet": ground_truth.sheets[0].sheet_number, "nodes": nodes, "edges": edges}


def _write_sample(
    sdir: Path,
    config: GenerateConfig,
    sample: RenderedSample,
    degraded: dict[str, Any],
    report_ok: bool,
    report_issues: list[str],
) -> None:
    sdir.mkdir(parents=True, exist_ok=True)
    for role, img in sample.images.items():
        img.save(sdir / f"{role}.png")
        degraded[role]["image"].save(sdir / f"{role}.deg.png")
    if config.write_svg:
        for role, svg in sample.svgs.items():
            (sdir / f"{role}.svg").write_text(svg, encoding="utf-8")
    cir.save(sample.ground_truth, str(sdir / "ground_truth.cir"))
    (sdir / "model.json").write_text(sample.model.model_dump_json(indent=2), encoding="utf-8")
    (sdir / "style.json").write_text(
        json.dumps(sample.ground_truth.metadata["style"], indent=2), encoding="utf-8"
    )
    (sdir / "degradation.json").write_text(
        json.dumps({role: d["params"] for role, d in degraded.items()}, indent=2), encoding="utf-8"
    )
    (sdir / "graph.json").write_text(
        json.dumps(plan_graph(sample.ground_truth), indent=2), encoding="utf-8"
    )
    (sdir / "validation.json").write_text(
        json.dumps({"ok": report_ok, "issues": report_issues}, indent=2), encoding="utf-8"
    )


def generate(config: GenerateConfig) -> GenerateResult:
    """Run the engine for ``config`` and return the result (with validator pass rate)."""
    if config.drawing_type not in _ELECTRICAL_TYPES:
        raise NotImplementedError(
            f"v0 is electrical-only; --type {config.drawing_type!r} is a later breadth step."
        )
    from .degrade import degrade  # local import keeps numpy/PIL optional at import time

    out = Path(config.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    result = GenerateResult(out_dir=str(out), config=config)

    for i in range(config.count):
        model = _build_model(config, i)
        style = sample_style(config.style_seed + i)
        sample = render(model, style)

        report_ok, report_issues = True, []
        if config.validate:
            report = expected_ground_truth(model)
            validation = _validate(report, sample.ground_truth)
            report_ok = validation.ok
            report_issues = [f"{x.code}@{x.sheet}: {x.detail}" for x in validation.issues]
            if not report_ok:
                raise GeneratorBugError(
                    f"sample {model.id!r} failed ground-truth validation — fix the generator, "
                    f"do not ship. Issues: {report_issues[:6]}"
                )

        assert_synthetic_owned(sample.ground_truth)

        if config.qa_pairs:
            md = dict(sample.ground_truth.metadata)
            md["qa_pairs"] = template_qa_pairs(model)
            sample.ground_truth.metadata = md
            assert_synthetic_owned(sample.ground_truth)

        deg_rng = random.Random((config.seed + i) ^ 0x9E3779B9)
        level = deg_rng.randint(config.degradation_min, config.degradation_max)
        degraded: dict[str, Any] = {}
        for role, img in sample.images.items():
            dimg, dparams = degrade(img, level, deg_rng)
            degraded[role] = {"image": dimg, "params": dparams.as_dict()}

        _write_sample(out / f"sample_{i:05d}", config, sample, degraded, report_ok, report_issues)
        result.samples.append(
            SampleSummary(
                sample_id=model.id,
                n_devices=len(model.devices),
                n_circuits=len(model.circuits),
                degradation_level=level,
                valid=report_ok,
                issues=report_issues,
            )
        )

    _write_manifest(out, result)
    return result


def _validate(expectation: Any, ground_truth: cir.DrawingSet) -> Any:
    from eval.validate import validate_ground_truth

    return validate_ground_truth(expectation, ground_truth)


def _write_manifest(out: Path, result: GenerateResult) -> None:
    manifest = {
        "engine_version": ENGINE_VERSION,
        "created_at": datetime.now(UTC).isoformat(),
        "license_provenance": SYNTHETIC_LICENSE.value,
        "data_lane": SYNTHETIC_LANE.value,
        "config": {
            "drawing_type": result.config.drawing_type,
            "count": result.config.count,
            "degradation_range": [result.config.degradation_min, result.config.degradation_max],
            "seed": result.config.seed,
            "style_seed": result.config.style_seed,
            "qa_pairs": result.config.qa_pairs,
            "ifc_path": result.config.ifc_path,
        },
        "validated_ok": result.validated_ok,
        "n_samples": len(result.samples),
        "samples": [
            {
                "id": s.sample_id,
                "n_devices": s.n_devices,
                "n_circuits": s.n_circuits,
                "degradation_level": s.degradation_level,
                "valid": s.valid,
            }
            for s in result.samples
        ],
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")


def main(argv: Sequence[str] | None = None) -> int:
    """Entry point for ``python -m synthetic.generate``."""
    config = parse_args(argv)
    result = generate(config)
    ok, n = result.validated_ok, len(result.samples)
    devs = [s.n_devices for s in result.samples]
    circs = [s.n_circuits for s in result.samples]
    print(
        f"Generated {n} {config.drawing_type} sample(s) -> {result.out_dir}\n"
        f"  validator: {ok}/{n} exact ({'PASS' if result.all_valid else 'FAIL — generator bug'})\n"
        f"  devices/sample: min={min(devs) if devs else 0} max={max(devs) if devs else 0}; "
        f"circuits/sample: min={min(circs) if circs else 0} max={max(circs) if circs else 0}\n"
        f"  every record stamped license={SYNTHETIC_LICENSE.value!r} lane={SYNTHETIC_LANE.value!r}"
    )
    return 0 if result.all_valid else 1


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
