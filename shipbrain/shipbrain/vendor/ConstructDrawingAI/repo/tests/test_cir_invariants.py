"""Tests for the research/commercial license-lane invariant.

This invariant is the single most important guarantee in the codebase: it must be
*impossible* to construct a commercial-lane record from data that cannot legally
train shippable weights. These tests pin that behavior down.
"""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from cir import (
    DataLane,
    DrawingSet,
    Entity,
    EntityType,
    LicenseLaneError,
    LicenseProvenance,
    Sheet,
    View,
)


def _entity(license_: LicenseProvenance, lane: DataLane) -> Entity:
    return Entity(
        entity_type=EntityType.SYMBOL,
        confidence=0.9,
        license_provenance=license_,
        data_lane=lane,
    )


@pytest.mark.parametrize(
    "license_,expected",
    [
        (LicenseProvenance.CC0, True),
        (LicenseProvenance.PUBLIC_DOMAIN, True),
        (LicenseProvenance.PERMISSIVE, True),
        (LicenseProvenance.SYNTHETIC_OWNED, True),
        (LicenseProvenance.OWNED, True),
        (LicenseProvenance.PROPRIETARY_LICENSED, True),
        (LicenseProvenance.CC_BY, False),  # conservatively gated pending legal sign-off
        (LicenseProvenance.CC_BY_SA, False),
        (LicenseProvenance.CC_BY_ND, False),
        (LicenseProvenance.CC_BY_NC, False),
        (LicenseProvenance.CC_BY_NC_SA, False),
        (LicenseProvenance.RESEARCH_ONLY, False),
        (LicenseProvenance.UNKNOWN, False),
    ],
)
def test_commercial_safe_classification(license_: LicenseProvenance, expected: bool) -> None:
    """The commercial-safe classification matches the documented conservative policy."""
    assert license_.commercial_safe is expected


def test_commercial_entity_with_noncommercial_license_is_rejected() -> None:
    """Constructing a commercial-lane entity from NC data raises at construction time."""
    with pytest.raises(ValidationError):
        _entity(LicenseProvenance.CC_BY_NC, DataLane.COMMERCIAL)


def test_research_entity_with_noncommercial_license_is_fine() -> None:
    """The research lane accepts non-commercial data (papers, benchmarks)."""
    entity = _entity(LicenseProvenance.CC_BY_NC, DataLane.RESEARCH)
    assert entity.data_lane is DataLane.RESEARCH


def test_commercial_entity_with_synthetic_license_is_fine() -> None:
    """Synthetic-owned data is the commercial lane's bread and butter."""
    entity = _entity(LicenseProvenance.SYNTHETIC_OWNED, DataLane.COMMERCIAL)
    assert entity.license_provenance.commercial_safe


def test_flipping_lane_to_commercial_revalidates() -> None:
    """validate_assignment keeps the invariant live when a field is mutated."""
    entity = _entity(LicenseProvenance.CC_BY_NC, DataLane.RESEARCH)
    with pytest.raises(ValidationError):
        entity.data_lane = DataLane.COMMERCIAL


def test_commercial_set_rejects_research_entity() -> None:
    """A COMMERCIAL DrawingSet may not contain a research-lane (NC) entity."""
    research_entity = _entity(LicenseProvenance.CC_BY_NC, DataLane.RESEARCH)
    sheet = Sheet(sheet_number="E-201", views=[View(entities=[research_entity])])
    with pytest.raises(ValidationError):
        DrawingSet(
            license_provenance=LicenseProvenance.SYNTHETIC_OWNED,
            data_lane=DataLane.COMMERCIAL,
            sheets=[sheet],
        )


def test_commercial_example_is_commercial_safe(commercial_set: DrawingSet) -> None:
    """The commercial example passes both the property and the explicit guard."""
    assert commercial_set.is_commercial_safe is True
    commercial_set.assert_commercial_safe()  # must not raise
    assert commercial_set.licenses_present() == {LicenseProvenance.SYNTHETIC_OWNED}


def test_research_example_is_not_commercial_safe(research_set: DrawingSet) -> None:
    """The research example (CC-BY-NC) is correctly flagged as not shippable."""
    assert research_set.is_commercial_safe is False
    assert research_set.licenses_present() == {LicenseProvenance.CC_BY_NC}
    with pytest.raises(LicenseLaneError):
        research_set.assert_commercial_safe()
