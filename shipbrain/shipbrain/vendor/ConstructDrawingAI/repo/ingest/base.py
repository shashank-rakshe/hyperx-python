"""Interfaces and registry for L0 ingestion.

Every source parser subclasses :class:`Ingestor`, declares the file types it handles,
and is registered via :func:`register`. The top-level :func:`ingest.ingest` dispatcher
looks up the right ingestor by extension. Each ingestor stamps the mandatory
``license_provenance`` / ``data_lane`` onto the CIR it produces; for files of unknown
provenance the safe default is ``UNKNOWN`` / ``research``.

Heavy parsing libraries (ezdxf, pymupdf, ifcopenshell, ...) are imported lazily inside
the ingestors, so ``import ingest`` is cheap and works without them installed.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from pathlib import Path
from typing import Any

from cir import DataLane, DrawingSet, LicenseProvenance


class Ingestor(ABC):
    """Parse one source document into a CIR :class:`~cir.DrawingSet`."""

    #: Lower-case file extensions (no dot) this ingestor handles, e.g. ``("dxf", "dwg")``.
    file_types: tuple[str, ...] = ()

    def __init__(
        self,
        *,
        license_provenance: LicenseProvenance = LicenseProvenance.UNKNOWN,
        data_lane: DataLane = DataLane.RESEARCH,
    ) -> None:
        self.license_provenance = license_provenance
        self.data_lane = data_lane

    @abstractmethod
    def ingest(self, path: Path) -> DrawingSet:
        """Parse ``path`` into a CIR :class:`~cir.DrawingSet`."""
        raise NotImplementedError

    def stamp(self) -> dict[str, Any]:
        """The mandatory provenance kwargs for every CIR record this ingestor emits."""
        return {"license_provenance": self.license_provenance, "data_lane": self.data_lane}


_REGISTRY: dict[str, type[Ingestor]] = {}


def register(cls: type[Ingestor]) -> type[Ingestor]:
    """Class decorator: register ``cls`` for each of its :attr:`Ingestor.file_types`."""
    for file_type in cls.file_types:
        _REGISTRY[file_type.lower()] = cls
    return cls


def ingestor_for(file_type: str) -> type[Ingestor]:
    """Return the ingestor class registered for ``file_type`` (extension, dot optional)."""
    key = file_type.lower().lstrip(".")
    try:
        return _REGISTRY[key]
    except KeyError as exc:
        raise NotImplementedError(
            f"No L0 ingestor for file type {file_type!r}. Supported: {sorted(_REGISTRY)}."
        ) from exc


def supported_file_types() -> list[str]:
    """All registered file extensions."""
    return sorted(_REGISTRY)
