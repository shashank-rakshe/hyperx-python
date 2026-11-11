# SPDX-License-Identifier: Apache-2.0
"""Atomic CSV writing shared by the design-check and range-graph results."""

from __future__ import annotations

import contextlib
import csv
import os
import tempfile
from collections.abc import Iterable, Sequence
from pathlib import Path


def number(value: float) -> str:
    """Format a float with full round-trip precision."""
    return f"{float(value):.17g}"


def write_csv(
    path: str | os.PathLike[str],
    header: Sequence[str],
    rows: Iterable[Sequence[object]],
    *,
    overwrite: bool,
) -> Path:
    """Atomically write ``rows`` under ``header``; return the absolute path."""
    target = Path(path).expanduser().resolve()
    if target.exists() and not overwrite:
        raise FileExistsError(f"output already exists: {target}")
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(
        prefix=f".{target.name}.", suffix=".tmp", dir=target.parent, text=True
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
            writer = csv.writer(stream, lineterminator="\n")
            writer.writerow(header)
            writer.writerows(rows)
        os.replace(temporary, target)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)
        raise
    return target
