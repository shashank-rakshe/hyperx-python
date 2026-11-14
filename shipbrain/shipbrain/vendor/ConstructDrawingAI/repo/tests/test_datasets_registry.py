"""Tests for the dataset registry and the license audit.

These pin down the data contract: every registered dataset carries provenance, the
commercial lane contains only commercial-safe sources, and the audit catches drift.
"""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from cir import DataLane, LicenseProvenance
from datasets import DatasetRecord, DatasetRegistry
from datasets.audit import audit_registry


@pytest.fixture
def registry() -> DatasetRegistry:
    return DatasetRegistry.load()


def test_registry_loads_seed_entries(registry: DatasetRegistry) -> None:
    assert len(registry.datasets) >= 5
    assert "CubiCasa5K" in registry.names()


def test_every_record_carries_provenance(registry: DatasetRegistry) -> None:
    """EVERY dataset record has both mandatory fields (guaranteed by the model)."""
    for record in registry.datasets:
        assert isinstance(record.license_provenance, LicenseProvenance)
        assert record.data_lane in (DataLane.RESEARCH, DataLane.COMMERCIAL)


def test_commercial_lane_is_all_commercial_safe(registry: DatasetRegistry) -> None:
    commercial = registry.in_lane(DataLane.COMMERCIAL)
    assert commercial, "expected at least one commercial-lane dataset in the seed"
    for record in commercial:
        assert record.license_provenance.commercial_safe


def test_audit_passes_on_seed_registry(registry: DatasetRegistry) -> None:
    assert audit_registry(registry) == []


def test_noncommercial_dataset_is_research_lane(registry: DatasetRegistry) -> None:
    cubicasa = registry.get("CubiCasa5K")
    assert cubicasa.license_provenance is LicenseProvenance.CC_BY_NC
    assert cubicasa.data_lane is DataLane.RESEARCH


def test_dataset_record_enforces_lane_invariant() -> None:
    """A dataset record inherits the CIR lane invariant: commercial + NC is rejected."""
    with pytest.raises(ValidationError):
        DatasetRecord(
            name="bogus",
            license_provenance=LicenseProvenance.CC_BY_NC,
            data_lane=DataLane.COMMERCIAL,
        )
