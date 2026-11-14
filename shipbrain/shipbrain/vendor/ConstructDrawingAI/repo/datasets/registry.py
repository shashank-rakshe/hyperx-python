"""The dataset registry: models + YAML loader.

A :class:`DatasetRecord` reuses :class:`cir.LicensedRecord`, so every entry carries
the two mandatory provenance fields and is bound by the same research/commercial
lane invariant as the CIR — a dataset cannot be tagged ``commercial`` unless its
license is commercial-safe. The registry itself lives in ``registry.yaml``.
"""

from __future__ import annotations

from enum import Enum
from pathlib import Path

import yaml
from pydantic import BaseModel, ConfigDict, Field

from cir import DataLane, LicensedRecord

#: Path to the YAML source-of-truth registry shipped with this package.
DEFAULT_REGISTRY_PATH: Path = Path(__file__).resolve().parent / "registry.yaml"


class Modality(str, Enum):
    """The primary modality of a dataset's contents."""

    VECTOR = "vector"
    RASTER = "raster"
    POINT_CLOUD = "point_cloud"
    MIXED = "mixed"
    SYNTHETIC = "synthetic"
    TEXT = "text"


class DatasetRecord(LicensedRecord):
    """A single registry entry describing a public (or synthetic) dataset.

    Inherits ``license_provenance`` + ``data_lane`` and the lane invariant from
    :class:`cir.LicensedRecord`. ``verified`` records whether the license has been
    confirmed for our intended use — unverified sources stay in the research lane.
    """

    name: str
    source_url: str | None = None
    paper_url: str | None = None
    size: str | None = None
    modality: Modality | None = None
    content_types: list[str] = Field(default_factory=list)
    # Native annotation format, used by the preparer to pick a converter, e.g.
    # "voc-xml", "coco-json", "yolo-txt", "csv-qa", "svg", "ifc", "point-cloud".
    annotation_format: str | None = None
    # Perception/agent tasks the dataset supports: "detection", "segmentation",
    # "panoptic", "vectorization", "graph", "qa", "scan-to-bim", ...
    tasks: list[str] = Field(default_factory=list)
    # Whether a preparer (download + convert-to-CIR) is implemented for this dataset.
    has_preparer: bool = False
    verified: bool = False  # has the license been verified for our intended use?
    notes: str | None = None


class DatasetRegistry(BaseModel):
    """The collection of all known :class:`DatasetRecord` entries."""

    model_config = ConfigDict(extra="forbid")

    datasets: list[DatasetRecord] = Field(default_factory=list)

    @classmethod
    def load(cls, path: str | Path = DEFAULT_REGISTRY_PATH) -> DatasetRegistry:
        """Load and validate the registry from a YAML file."""
        raw = yaml.safe_load(Path(path).read_text(encoding="utf-8")) or {}
        return cls.model_validate(raw)

    def names(self) -> list[str]:
        """All dataset names in registry order."""
        return [record.name for record in self.datasets]

    def get(self, name: str) -> DatasetRecord:
        """Return the record named ``name``, case-insensitively (``KeyError`` if absent)."""
        for record in self.datasets:
            if record.name.lower() == name.lower():
                return record
        raise KeyError(f"No dataset named {name!r} in the registry. Known: {self.names()}.")

    def in_lane(self, lane: DataLane) -> list[DatasetRecord]:
        """All records in a given data lane."""
        return [record for record in self.datasets if record.data_lane is lane]
