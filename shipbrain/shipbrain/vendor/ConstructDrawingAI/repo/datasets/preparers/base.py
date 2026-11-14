"""Base class + shared utilities for dataset preparers.

A :class:`DatasetPreparer` turns one registered dataset into CIR documents in two
idempotent steps:

1. :meth:`download` — fetch the raw data into the DVC-tracked ``raw`` path
   (``<data_root>/raw/<slug>/``); skip if already present.
2. :meth:`convert` — yield :class:`cir.DrawingSet` documents from the dataset's
   native annotations, each stamped with the registry's license/lane provenance.

:meth:`prepare` runs both, writes the CIR docs to ``<data_root>/processed/<slug>/cir/``
and a ``manifest.json`` summary, and returns a :class:`PrepareResult`.

The raw/processed paths are git-ignored and meant to be version-controlled with DVC
(``dvc add <data_root>/raw/<slug>``).
"""

from __future__ import annotations

import json
import subprocess
from abc import ABC, abstractmethod
from collections.abc import Iterator
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from cir import DrawingSet
from cir import save as save_cir
from datasets.registry import DatasetRecord

#: Default root for raw downloads and processed CIR (git-ignored; DVC-tracked).
DEFAULT_DATA_ROOT = Path("datasets")

_FORMAT_SUFFIX = {"cir": ".cir", "json": ".json"}


@dataclass
class PrepareResult:
    """Summary of a single dataset preparation run."""

    name: str
    raw_dir: Path
    cir_dir: Path
    n_drawing_sets: int
    n_entities: int
    extra: dict[str, int] = field(default_factory=dict)


class DatasetPreparer(ABC):
    """Download + convert one dataset into CIR. Subclasses set :attr:`name`."""

    #: Must equal the dataset's name in the registry.
    name: str = ""

    def __init__(self, record: DatasetRecord, *, data_root: Path | str = DEFAULT_DATA_ROOT) -> None:
        self.record = record
        self.data_root = Path(data_root)

    # -- paths -------------------------------------------------------------------
    @property
    def slug(self) -> str:
        """Filesystem-friendly id derived from the dataset name."""
        return self.name.lower()

    @property
    def raw_dir(self) -> Path:
        """Where raw data is downloaded (DVC-tracked)."""
        return self.data_root / "raw" / self.slug

    @property
    def processed_dir(self) -> Path:
        """Where processed outputs (CIR + manifest) live."""
        return self.data_root / "processed" / self.slug

    @property
    def cir_dir(self) -> Path:
        """Where converted CIR documents are written."""
        return self.processed_dir / "cir"

    def is_downloaded(self) -> bool:
        """Whether raw data is already present (makes :meth:`download` idempotent)."""
        return self.raw_dir.exists() and any(self.raw_dir.iterdir())

    # -- to implement ------------------------------------------------------------
    @abstractmethod
    def download(self) -> None:
        """Idempotently fetch raw data into :attr:`raw_dir`."""
        raise NotImplementedError

    @abstractmethod
    def convert(self) -> Iterator[DrawingSet]:
        """Yield CIR documents from the dataset's native annotations."""
        raise NotImplementedError

    # -- orchestration -----------------------------------------------------------
    def prepare(self, *, fmt: str = "cir", limit: int | None = None) -> PrepareResult:
        """Download, convert, write CIR + a manifest, and return a summary."""
        if fmt not in _FORMAT_SUFFIX:
            raise ValueError(f"Unknown format {fmt!r}; choose from {sorted(_FORMAT_SUFFIX)}.")
        self.download()
        self.cir_dir.mkdir(parents=True, exist_ok=True)
        # Clear stale outputs so a re-run never leaves orphaned CIR documents (e.g.
        # records dropped by a policy change must not linger in the dataset layer).
        for stale in self.cir_dir.iterdir():
            if stale.is_file():
                stale.unlink()
        suffix = _FORMAT_SUFFIX[fmt]

        n_ds = n_ent = n_qa = 0
        files: list[str] = []
        for i, drawing_set in enumerate(self.convert()):
            if limit is not None and i >= limit:
                break
            out = self.cir_dir / f"{drawing_set.id}{suffix}"
            save_cir(drawing_set, out)
            files.append(out.name)
            n_ds += 1
            n_ent += drawing_set.entity_count()
            qa = drawing_set.metadata.get("qa_pairs")
            if isinstance(qa, list):
                n_qa += len(qa)

        result = PrepareResult(
            name=self.name,
            raw_dir=self.raw_dir,
            cir_dir=self.cir_dir,
            n_drawing_sets=n_ds,
            n_entities=n_ent,
            extra={"qa_pairs": n_qa},
        )
        self._write_manifest(result, fmt=fmt, files=files)
        return result

    def _write_manifest(self, result: PrepareResult, *, fmt: str, files: list[str]) -> None:
        manifest = {
            "name": self.name,
            "slug": self.slug,
            "source_url": self.record.source_url,
            "license_provenance": self.record.license_provenance.value,
            "data_lane": self.record.data_lane.value,
            "annotation_format": self.record.annotation_format,
            "cir_format": fmt,
            "n_drawing_sets": result.n_drawing_sets,
            "n_entities": result.n_entities,
            "extra": result.extra,
            "files": files,
        }
        self.processed_dir.mkdir(parents=True, exist_ok=True)
        (self.processed_dir / "manifest.json").write_text(
            json.dumps(manifest, indent=2), encoding="utf-8"
        )

    # -- helpers -----------------------------------------------------------------
    def git_clone(self, url: str) -> None:
        """Idempotently shallow-clone ``url`` into :attr:`raw_dir`."""
        if self.is_downloaded():
            return
        self.raw_dir.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["git", "clone", "--depth", "1", url, str(self.raw_dir)],
            check=True,
            capture_output=True,
            text=True,
        )

    def stamp(self) -> dict[str, Any]:
        """Mandatory provenance kwargs for every CIR record from this dataset."""
        return {
            "license_provenance": self.record.license_provenance,
            "data_lane": self.record.data_lane,
        }
