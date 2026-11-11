"""L0 — Ingestion & Normalization.

Turns any supported source — vector PDF, scanned/raster PDF, DXF (and DWG via ODA),
IFC, or a raster image — into a CIR :class:`~cir.DrawingSet`. Vector sources yield
exact primitives directly; raster sources are rasterized at >=300 DPI, tiled, and
handed to L1 perception (stub). Per sheet we parse the title block (sheet number,
discipline, scale) and detect cross-reference callouts as CIR sheet-graph edges.
Scale is recovered deterministically (never by an LLM).

Quick start::

    import ingest
    from cir import DataLane, LicenseProvenance

    ds = ingest.ingest(
        "plan.dxf",
        license_provenance=LicenseProvenance.SYNTHETIC_OWNED,
        data_lane=DataLane.COMMERCIAL,
    )

Heavy parsing libraries (ezdxf, pymupdf, ifcopenshell, Pillow) are imported lazily by
the individual ingestors, so ``import ingest`` is cheap and works without them; install
the ``ingest`` optional-dependency group to actually parse files.
"""

from __future__ import annotations

from pathlib import Path

from cir import DataLane, DrawingSet, LicenseProvenance

from .base import Ingestor, ingestor_for, register, supported_file_types
from .dxf import DXFIngestor
from .handoff import (
    PixelRegion,
    SheetDetection,
    TileDetection,
    TileRef,
    aggregate,
    compose_to_sheet,
)
from .ifc import IFCIngestor
from .image import ImageIngestor
from .normalize import Bounds, Normalizer
from .pdf import PDFIngestor
from .scale import parse_scale, resolve_px
from .sheets import find_cross_references, parse_sheet_number, parse_title_block
from .tiling import Tile, TiledSheet, tile_image


def ingest(
    path: str | Path,
    *,
    license_provenance: LicenseProvenance = LicenseProvenance.UNKNOWN,
    data_lane: DataLane = DataLane.RESEARCH,
) -> DrawingSet:
    """Ingest a file into the CIR, dispatching on its extension.

    Args:
        path: The source file ({pdf, dxf, dwg, ifc, png, jpg, ...}).
        license_provenance: Provenance to stamp on every record (default ``UNKNOWN``).
        data_lane: Lane to stamp (default ``research`` — the safe default for files of
            unverified provenance).
    """
    p = Path(path)
    ingestor_cls = ingestor_for(p.suffix)
    ingestor = ingestor_cls(license_provenance=license_provenance, data_lane=data_lane)
    return ingestor.ingest(p)


__all__ = [
    "ingest",
    "Ingestor",
    "ingestor_for",
    "register",
    "supported_file_types",
    "DXFIngestor",
    "PDFIngestor",
    "IFCIngestor",
    "ImageIngestor",
    "Bounds",
    "Normalizer",
    "parse_scale",
    "resolve_px",
    "parse_title_block",
    "parse_sheet_number",
    "find_cross_references",
    "Tile",
    "TiledSheet",
    "tile_image",
    "TileRef",
    "PixelRegion",
    "TileDetection",
    "SheetDetection",
    "compose_to_sheet",
    "aggregate",
]
