"""``python -m datasets.prepare`` — download + convert datasets into the CIR.

Each dataset with an implemented preparer is fetched into a DVC-tracked ``raw`` path
and its native annotations are converted into CIR :class:`~cir.DrawingSet` documents
(stamped with the registry's license/lane). Idempotent: re-running skips a download
that is already present and overwrites the deterministic CIR outputs.

Examples::

    python -m datasets.prepare --list           # show all datasets; mark those ready
    python -m datasets.prepare PIDQA             # prepare one dataset
    python -m datasets.prepare --all             # prepare every dataset with a preparer
    python -m datasets.prepare PIDQA --format json --limit 25
"""

from __future__ import annotations

import argparse
from collections.abc import Sequence
from pathlib import Path

from .preparers import get_preparer_class, has_preparer
from .registry import DatasetRecord, DatasetRegistry


def build_parser() -> argparse.ArgumentParser:
    """Build the ``datasets.prepare`` argument parser."""
    parser = argparse.ArgumentParser(
        prog="python -m datasets.prepare",
        description="Download and convert public datasets into the CIR (license-aware).",
    )
    parser.add_argument("dataset", nargs="?", help="Dataset name to prepare (see --list).")
    parser.add_argument("--all", action="store_true", help="Prepare every dataset with a preparer.")
    parser.add_argument("--list", action="store_true", help="List registered datasets and exit.")
    parser.add_argument(
        "--format", choices=["cir", "json"], default="cir", help="CIR output format."
    )
    parser.add_argument("--limit", type=int, default=None, help="Max documents to write.")
    parser.add_argument("--data-root", default="datasets", help="Root for raw/processed data.")
    return parser


def _print_listing(registry: DatasetRegistry) -> None:
    for record in registry.datasets:
        mark = "*" if has_preparer(record.name) else " "
        modality = record.modality.value if record.modality else "-"
        print(
            f"[{mark}] {record.name:22s} lane={record.data_lane.value:10s} "
            f"{record.license_provenance.value:14s} {modality}"
        )
    print("\n[*] = download + convert preparer implemented")


def prepare_one(record: DatasetRecord, *, data_root: str, fmt: str, limit: int | None) -> bool:
    """Prepare a single dataset; return True if a preparer ran, False if skipped."""
    if not has_preparer(record.name):
        print(f"[skip] {record.name}: no preparer implemented yet (registry-only).")
        return False
    preparer = get_preparer_class(record.name)(record, data_root=Path(data_root))
    print(f"[prepare] {record.name}: downloading + converting -> {preparer.cir_dir} ...")
    result = preparer.prepare(fmt=fmt, limit=limit)
    print(
        f"[done] {record.name}: {result.n_drawing_sets} CIR docs, "
        f"{result.n_entities} entities, extra={result.extra}"
    )
    return True


def main(argv: Sequence[str] | None = None) -> int:
    """Entry point for ``python -m datasets.prepare``."""
    parser = build_parser()
    ns = parser.parse_args(argv)
    registry = DatasetRegistry.load()

    if ns.list:
        _print_listing(registry)
        return 0

    if ns.all:
        targets = list(registry.datasets)
    elif ns.dataset:
        targets = [registry.get(ns.dataset)]
    else:
        parser.error("Specify a dataset name, --all, or --list.")  # exits (NoReturn)

    ran = 0
    for record in targets:
        if prepare_one(record, data_root=ns.data_root, fmt=ns.format, limit=ns.limit):
            ran += 1
    print(f"\nPrepared {ran} dataset(s).")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
