"""``python -m datasets.audit`` — the license firewall.

Fails loudly (non-zero exit) if any **commercial-lane** record traces to a
non-permissive source. Runs two checks:

* **registry** — every commercial-lane :class:`~datasets.registry.DatasetRecord` must
  be commercial-safe (defense-in-depth; also catches hand-edited YAML).
* **prepared data** — scans every converted CIR document under
  ``<data-root>/processed/*/cir/`` and, for any in the commercial lane, calls
  :meth:`cir.DrawingSet.assert_commercial_safe`.

This is the gate referenced by the data-lane discipline; wire it into CI to block any
merge that would let non-permissive data into the commercial lane.
"""

from __future__ import annotations

import argparse
from collections.abc import Sequence
from pathlib import Path

from cir import DataLane, DrawingSet, LicenseLaneError, load

from .registry import DatasetRegistry

_CIR_SUFFIXES = {".cir", ".json", ".mpk", ".msgpack"}


def audit_registry(registry: DatasetRegistry) -> list[str]:
    """Return registry-level violations (empty == clean)."""
    violations: list[str] = []
    for record in registry.datasets:
        if (
            record.data_lane is DataLane.COMMERCIAL
            and not record.license_provenance.commercial_safe
        ):
            violations.append(
                f"registry: {record.name} is commercial-lane but license "
                f"{record.license_provenance.value!r} is not commercial-safe"
            )
    return violations


def audit_prepared(data_root: Path) -> tuple[list[str], int, int]:
    """Scan prepared CIR docs. Returns (violations, n_scanned, n_commercial)."""
    processed = Path(data_root) / "processed"
    violations: list[str] = []
    n_scanned = n_commercial = 0
    if not processed.exists():
        return violations, 0, 0

    for cir_file in sorted(processed.glob("*/cir/*")):
        if cir_file.suffix.lower() not in _CIR_SUFFIXES:
            continue
        try:
            drawing_set = load(DrawingSet, cir_file)
        except Exception as exc:  # an audit scanner must survive any malformed file
            # A document that fails to validate (e.g. a commercial-lane doc built from
            # non-commercial data) is itself a loud violation.
            violations.append(f"prepared: {cir_file} failed to load as valid CIR ({exc})")
            continue
        n_scanned += 1
        if drawing_set.data_lane is DataLane.COMMERCIAL:
            n_commercial += 1
            try:
                drawing_set.assert_commercial_safe()
            except LicenseLaneError as exc:
                violations.append(f"prepared: {cir_file}: {exc}")
    return violations, n_scanned, n_commercial


def main(argv: Sequence[str] | None = None) -> int:
    """Entry point for ``python -m datasets.audit``."""
    parser = argparse.ArgumentParser(
        prog="python -m datasets.audit",
        description="Fail if any commercial-lane record traces to a non-permissive source.",
    )
    parser.add_argument("--data-root", default="datasets", help="Root holding processed/ CIR.")
    ns = parser.parse_args(argv)

    registry = DatasetRegistry.load()
    registry_violations = audit_registry(registry)
    prepared_violations, n_scanned, n_commercial = audit_prepared(Path(ns.data_root))
    violations = registry_violations + prepared_violations

    n_commercial_registry = len(registry.in_lane(DataLane.COMMERCIAL))
    print(
        f"Registry: {len(registry.datasets)} datasets "
        f"({n_commercial_registry} commercial-lane)."
    )
    print(f"Prepared: scanned {n_scanned} CIR docs ({n_commercial} commercial-lane).")

    if violations:
        print("\nLICENSE AUDIT FAILED:")
        for violation in violations:
            print(f"  - {violation}")
        return 1

    print("\nLicense audit passed: no commercial-lane record traces to a non-permissive source.")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
