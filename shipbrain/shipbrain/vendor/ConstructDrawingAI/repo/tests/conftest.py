"""Shared pytest fixtures for the CIR tests."""

from __future__ import annotations

import pytest

from cir import DataLane, DrawingSet, make_example_drawing_set


@pytest.fixture
def research_set() -> DrawingSet:
    """A fully-populated example drawing set in the research lane (CC-BY-NC)."""
    return make_example_drawing_set(data_lane=DataLane.RESEARCH)


@pytest.fixture
def commercial_set() -> DrawingSet:
    """A fully-populated example drawing set in the commercial lane (synthetic-owned)."""
    return make_example_drawing_set(data_lane=DataLane.COMMERCIAL)


@pytest.fixture
def make_electrical_sample():
    """Factory: write a minimal synthetic electrical sample (CIR + plan PNG) to a dir.

    Mirrors the synthetic engine's on-disk shape (``ground_truth.cir`` + ``plan.png`` +
    ``plan.deg.png``) so the perception tests are independent of the (git-ignored,
    regenerated) pilot. Includes a non-detectable wall so target-filtering can be tested.
    """
    from pathlib import Path

    from PIL import Image

    import cir as _cir
    from cir import (
        DataLane,
        Discipline,
        DrawingSet,
        Entity,
        EntityType,
        Geometry,
        LicenseProvenance,
        Sheet,
        View,
        ViewType,
    )

    prov = {
        "license_provenance": LicenseProvenance.SYNTHETIC_OWNED,
        "data_lane": DataLane.COMMERCIAL,
    }

    def _build(
        sample_dir: Path | str,
        *,
        n_duplex: int = 3,
        panel: bool = True,
        wall: bool = True,
        img_size: tuple[int, int] = (900, 600),
        degraded: bool = True,
    ) -> DrawingSet:
        directory = Path(sample_dir)
        directory.mkdir(parents=True, exist_ok=True)
        entities = []
        for i in range(n_duplex):
            cx, cy = 0.15 + 0.12 * i, 0.5
            entities.append(
                Entity(
                    entity_type=EntityType.SYMBOL,
                    label="Duplex Receptacle",
                    ifc_class="IfcOutlet",
                    geometry=Geometry.box(cx - 0.02, cy - 0.02, cx + 0.02, cy + 0.02),
                    confidence=1.0,
                    **prov,
                )
            )
        if panel:
            entities.append(
                Entity(
                    entity_type=EntityType.EQUIPMENT,
                    label="Panelboard",
                    ifc_class="IfcElectricDistributionBoard",
                    geometry=Geometry.box(0.04, 0.04, 0.12, 0.12),
                    confidence=1.0,
                    **prov,
                )
            )
        if wall:
            entities.append(
                Entity(
                    entity_type=EntityType.WALL,
                    label="Wall",
                    geometry=Geometry.polygon([(0.1, 0.1), (0.9, 0.1), (0.9, 0.9), (0.1, 0.9)]),
                    confidence=1.0,
                    **prov,
                )
            )
        ds = DrawingSet(
            name=directory.name,
            sheets=[
                Sheet(
                    sheet_number="E-101",
                    discipline=Discipline.ELECTRICAL,
                    views=[View(view_type=ViewType.PLAN, entities=entities)],
                )
            ],
            **prov,
        )
        _cir.save(ds, str(directory / "ground_truth.cir"))
        Image.new("RGB", img_size, "white").save(directory / "plan.png")
        if degraded:
            Image.new("RGB", img_size, "white").save(directory / "plan.deg.png")
        return ds

    return _build
