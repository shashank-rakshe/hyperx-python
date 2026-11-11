"""Stand-alone re-validation of a generated run — the independent "prove it" pass.

The generator already validates each sample inline (fail-fast). This runs the *same*
reusable validator again over what was written to disk, re-deriving the expectation from
the persisted ``model.json`` and checking it against the persisted ``ground_truth.cir``.
Re-deriving from disk makes it a genuinely independent check: it also catches a
serialization or save/load bug, not just an in-memory one.

Usage::

    python -m synthetic.validate datasets/synthetic/electrical_pilot
"""

from __future__ import annotations

import json
import sys
from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path

import cir
from eval.validate import validate_ground_truth

from .expect import expected_ground_truth
from .model import ElectricalModel


@dataclass
class RunValidation:
    """Aggregate validator result over a generated run."""

    out_dir: str
    total: int = 0
    ok: int = 0
    failures: list[tuple[str, list[str]]] = field(default_factory=list)  # (sample_dir, issues)

    @property
    def all_valid(self) -> bool:
        return self.total > 0 and self.ok == self.total


def validate_run(out_dir: str | Path) -> RunValidation:
    """Re-validate every sample directory under ``out_dir`` from its persisted files."""
    out = Path(out_dir)
    result = RunValidation(out_dir=str(out))
    for sdir in sorted(p for p in out.glob("sample_*") if p.is_dir()):
        model_path = sdir / "model.json"
        cir_path = sdir / "ground_truth.cir"
        if not model_path.exists() or not cir_path.exists():
            continue
        result.total += 1
        model = ElectricalModel.model_validate_json(model_path.read_text(encoding="utf-8"))
        ground_truth = cir.load(cir.DrawingSet, str(cir_path))
        report = validate_ground_truth(expected_ground_truth(model), ground_truth)
        if report.ok:
            result.ok += 1
        else:
            result.failures.append(
                (sdir.name, [f"{x.code}@{x.sheet}: {x.detail}" for x in report.issues])
            )
    return result


def main(argv: Sequence[str] | None = None) -> int:
    """Entry point for ``python -m synthetic.validate <out_dir>``."""
    args = list(sys.argv[1:] if argv is None else argv)
    if not args:
        print("usage: python -m synthetic.validate <out_dir>", file=sys.stderr)
        return 2
    result = validate_run(args[0])
    print(
        f"Re-validated {result.total} sample(s) from {result.out_dir}: "
        f"{result.ok}/{result.total} exact "
        f"({'PASS' if result.all_valid else 'FAIL'})"
    )
    for name, issues in result.failures[:10]:
        print(f"  FAIL {name}: {issues[:4]}")
    if result.failures:
        # also dump a machine-readable summary
        (Path(result.out_dir) / "revalidation.json").write_text(
            json.dumps(
                {"ok": result.ok, "total": result.total, "failures": dict(result.failures)},
                indent=2,
            ),
            encoding="utf-8",
        )
    return 0 if result.all_valid else 1


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
