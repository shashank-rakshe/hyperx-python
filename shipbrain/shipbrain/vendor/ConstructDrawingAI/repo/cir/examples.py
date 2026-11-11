"""Factory helpers that build representative CIR documents.

Used by the test-suite (round-trip + invariant tests), the docs, and the backend's
``/cir/example`` endpoint, so there is one canonical, realistic example rather than
many ad-hoc ones. The example is intentionally MEP/electrical flavored — that is
the commercial wedge — and exercises every part of the schema (multiple views,
connectivity edges, dimensions, ontology codes, cross-references, a legend, a
revision, and source-bbox evidence).
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

from .enums import DataLane, Discipline, EntityType, LicenseProvenance, ViewType
from .geometry import BBox, Geometry, SourceBBox
from .schema import (
    Connection,
    CrossReference,
    DimensionString,
    DrawingSet,
    Entity,
    LegendEntry,
    OntologyCodes,
    PageSize,
    Revision,
    Scale,
    Sheet,
    SourceFile,
    TextSpan,
    TitleBlock,
    View,
)


def make_example_drawing_set(
    *,
    data_lane: DataLane = DataLane.RESEARCH,
    license_provenance: LicenseProvenance | None = None,
) -> DrawingSet:
    """Build a representative, fully-populated electrical (MEP) drawing set.

    Args:
        data_lane: Which lane to stamp the set and all its entities with.
        license_provenance: License to stamp; defaults to ``SYNTHETIC_OWNED`` for the
            commercial lane and ``CC_BY_NC`` for the research lane (so the result is
            always a valid document in whichever lane is requested).

    Returns:
        A valid :class:`~cir.schema.DrawingSet` (one sheet, two views, a small
        connectivity graph) that round-trips through every serialization codec.
    """
    if license_provenance is None:
        license_provenance = (
            LicenseProvenance.SYNTHETIC_OWNED
            if data_lane is DataLane.COMMERCIAL
            else LicenseProvenance.CC_BY_NC
        )
    # Typed as Any-valued so the **prov unpack is compatible with every field type
    # (the enums subclass str, which would otherwise narrow the dict to dict[str, str]).
    prov: dict[str, Any] = {"license_provenance": license_provenance, "data_lane": data_lane}

    # --- entities on the power plan -------------------------------------------
    panel = Entity(
        entity_type=EntityType.EQUIPMENT,
        label="Panel 'LP-1'",
        ifc_class="IfcElectricDistributionBoard",
        ontology=OntologyCodes(masterformat="26 24 16", uniformat="D5010", omniclass="23-35 31 00"),
        geometry=Geometry.box(0.08, 0.12, 0.16, 0.22),
        source_bbox=SourceBBox(x_min=160, y_min=240, x_max=320, y_max=440, unit="px", page=0),
        confidence=0.97,
        produced_by="rtdetr-mep",
        model_version="v0.1.0",
        attributes={"voltage": "120/208V", "phases": 3},
        **prov,
    )
    receptacle_a = Entity(
        entity_type=EntityType.SYMBOL,
        label="Duplex Receptacle",
        ifc_class="IfcOutlet",
        ontology=OntologyCodes(masterformat="26 27 26", uniformat="D5020"),
        geometry=Geometry.circle(0.42, 0.36, 0.012),
        source_bbox=SourceBBox(x_min=820, y_min=700, x_max=860, y_max=740, unit="px", page=0),
        text_spans=[TextSpan(text="1", confidence=0.91)],  # circuit number tag
        confidence=0.93,
        produced_by="rtdetr-mep",
        model_version="v0.1.0",
        **prov,
    )
    receptacle_b = Entity(
        entity_type=EntityType.SYMBOL,
        label="Duplex Receptacle",
        ifc_class="IfcOutlet",
        ontology=OntologyCodes(masterformat="26 27 26", uniformat="D5020"),
        geometry=Geometry.circle(0.61, 0.52, 0.012),
        source_bbox=SourceBBox(x_min=1190, y_min=1010, x_max=1230, y_max=1050, unit="px", page=0),
        confidence=0.88,
        produced_by="rtdetr-mep",
        model_version="v0.1.0",
        **prov,
    )
    dimension = Entity(
        entity_type=EntityType.DIMENSION,
        geometry=Geometry.polyline([(0.42, 0.36), (0.61, 0.36)]),
        dimensions=[
            DimensionString(
                raw="12'-6\"",
                value=12.5,
                unit="ft-in",
                value_mm=3810.0,
                confidence=0.90,
            )
        ],
        confidence=0.90,
        produced_by="dimension-parser",
        model_version="v0.1.0",
        **prov,
    )

    power_plan = View(
        name="Lighting & Power Plan",
        view_type=ViewType.PLAN,
        region=BBox(x_min=0.02, y_min=0.05, x_max=0.78, y_max=0.92),
        scale=Scale(
            raw='1/4" = 1\'-0"',
            drawing_unit="in",
            real_world_unit="ft",
            ratio=1.0 / 48.0,
            px_per_real_unit=64.0,
            confidence=0.99,
        ),
        entities=[panel, receptacle_a, receptacle_b, dimension],
        connections=[
            Connection(
                source_id=receptacle_a.id,
                target_id=panel.id,
                connection_type="home_run",
                confidence=0.90,
                attributes={"circuit": "1"},
            ),
            Connection(
                source_id=receptacle_b.id,
                target_id=panel.id,
                connection_type="home_run",
                confidence=0.86,
                attributes={"circuit": "3"},
            ),
        ],
    )

    # --- entities in the panel schedule ---------------------------------------
    schedule_cell = Entity(
        entity_type=EntityType.TABLE_CELL,
        label="Circuit 1 — Receptacles — 20A",
        geometry=Geometry.box(0.82, 0.10, 0.98, 0.13),
        confidence=0.95,
        produced_by="table-extractor",
        model_version="v0.1.0",
        attributes={"circuit": "1", "load": "Receptacles", "breaker": "20A"},
        **prov,
    )
    panel_schedule = View(
        name="Panel 'LP-1' Schedule",
        view_type=ViewType.SCHEDULE,
        region=BBox(x_min=0.80, y_min=0.05, x_max=0.99, y_max=0.60),
        entities=[schedule_cell],
    )

    sheet = Sheet(
        sheet_number="E-201",
        discipline=Discipline.ELECTRICAL,
        title="Lighting & Power Plan — Level 2",
        page_index=0,
        size=PageSize(width=3024.0, height=2160.0, unit="px"),
        scale=power_plan.scale,
        title_block=TitleBlock(
            project_name="Example Office Fit-Out",
            project_number="2026-014",
            sheet_number="E-201",
            sheet_title="Lighting & Power Plan — Level 2",
            discipline=Discipline.ELECTRICAL,
            scale='1/4" = 1\'-0"',
            date="2026-05-30",
            drawn_by="JS",
            checked_by="AK",
            revision="1",
        ),
        views=[power_plan, panel_schedule],
        cross_references=[
            CrossReference(
                callout="3/E-501",
                target_sheet="E-501",
                target_detail="3",
                geometry=Geometry.point(0.55, 0.40),
                source_bbox=SourceBBox(x_min=1080, y_min=770, x_max=1120, y_max=810, page=0),
                confidence=0.92,
            )
        ],
        legend=[
            LegendEntry(
                symbol="R",
                description="Duplex Receptacle, 15A 125V",
                ifc_class="IfcOutlet",
                ontology=OntologyCodes(masterformat="26 27 26"),
            )
        ],
        revisions=[
            Revision(number="1", description="Issued for Construction", date="2026-05-30", by="JS")
        ],
    )

    return DrawingSet(
        name="Example Office Fit-Out — Electrical",
        project_name="Example Office Fit-Out",
        project_number="2026-014",
        source=SourceFile(
            filename="E-201.pdf",
            file_type="pdf",
            is_vector=False,
            page_count=1,
            sha256="0" * 64,  # placeholder content hash
            ingested_at=datetime(2026, 5, 31, 12, 0, 0, tzinfo=UTC),
            ingest_tool="pymupdf",
        ),
        sheets=[sheet],
        metadata={"discipline_focus": "electrical", "note": "synthetic example document"},
        **prov,
    )
