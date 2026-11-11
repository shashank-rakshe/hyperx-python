"""The Canonical Intermediate Representation (CIR) schema.

The CIR is the single data contract every layer of the platform reads and writes
(L0 ingest → L1 perception → L2 grounding → L3 engines → L4 agent). Decoupling
perception from reasoning through one schema is what lets us swap a detector
without touching the agent, score the *structure* instead of screenshots, and keep
all drawing types pointed at a common target.

Hierarchy::

    DrawingSet            # the root document / dataset record
      └── Sheet           # one page; sheet number, discipline, scale, title block,
          │               #   cross-references, legend, revisions
          └── View        # a plan / detail / schedule / single-line diagram
              ├── Entity   # the atom: geometry + IFC class + ontology + text +
              │           #   dimensions + source bbox + CONFIDENCE + provenance
              └── Connection   # connectivity edges among entities (MEP/P&ID graph)

**The mandatory data contract.** Every :class:`Entity` and every dataset-level
record (:class:`DrawingSet`) carries two mandatory fields — ``license_provenance``
and ``data_lane`` — and the research/commercial lane invariant is enforced
structurally (see :class:`LicensedRecord` and :class:`DrawingSet`). This is how we
guarantee we never train shippable weights on incompatible data.
"""

from __future__ import annotations

from collections.abc import Iterator
from datetime import UTC, datetime
from typing import Any, Self
from uuid import uuid4

from pydantic import BaseModel, ConfigDict, Field, model_validator

from .enums import DataLane, Discipline, EntityType, LicenseProvenance, ViewType
from .exceptions import LicenseLaneError
from .geometry import BBox, Geometry, SourceBBox
from .version import SCHEMA_VERSION


def _new_id() -> str:
    """Generate a compact unique identifier for a CIR record."""
    return uuid4().hex


class CIRBase(BaseModel):
    """Base for all CIR models.

    * ``extra="forbid"`` — unknown fields are an error, catching typos and schema
      drift instead of silently dropping data.
    * ``validate_assignment=True`` — mutating a field re-runs validation, so the
      license/lane invariant stays live (e.g. flipping ``data_lane`` to commercial
      on an NC-licensed entity raises immediately).
    """

    model_config = ConfigDict(extra="forbid", validate_assignment=True)


class LicensedRecord(CIRBase):
    """Mixin carrying the two mandatory provenance fields + the lane invariant.

    EVERY entity and EVERY dataset-level record inherits this. The validator is the
    structural enforcement of the research/commercial two-lane discipline
    (``docs/DECISIONS.md`` #1): a record may sit in the COMMERCIAL lane only if its
    license is commercial-safe. That makes "accidentally training on NC data" a
    construction-time :class:`pydantic.ValidationError`, not a code-review hope.
    """

    license_provenance: LicenseProvenance
    data_lane: DataLane

    @model_validator(mode="after")
    def _enforce_lane(self) -> Self:
        if self.data_lane is DataLane.COMMERCIAL and not self.license_provenance.commercial_safe:
            raise ValueError(
                f"data_lane=COMMERCIAL is incompatible with license "
                f"{self.license_provenance.value!r}: only commercial-safe licenses "
                f"(permissive / synthetic / owned) may enter the commercial lane."
            )
        return self


# ---------------------------------------------------------------------------
# Leaf value objects
# ---------------------------------------------------------------------------
class OntologyCodes(CIRBase):
    """Industry ontology codes grounding an entity to standard taxonomies.

    A bounding box is worthless; ``IfcFlowController`` + a MasterFormat code + a
    circuit id is a *product*. These codes are how L2 grounding turns geometry into
    something an estimator or the L4 agent can act on.
    """

    masterformat: str | None = None  # North American spec/estimating, e.g. "26 27 26"
    uniformat: str | None = None  # elemental / assembly (early takeoff), e.g. "D5020"
    omniclass: str | None = None  # master multi-table taxonomy
    uniclass: str | None = None  # UK/EU classification (international expansion)
    extra: dict[str, str] = Field(default_factory=dict)


class TextSpan(CIRBase):
    """A run of text recognized on the drawing (OCR or vector text extraction)."""

    text: str
    confidence: float | None = Field(default=None, ge=0.0, le=1.0)
    source_bbox: SourceBBox | None = None
    rotation_deg: float | None = None


class DimensionString(CIRBase):
    """A dimension annotation, both as printed and parsed.

    ``value_mm`` is the canonical comparison value: parsing ``12'-6"`` and ``3810``
    to the same millimeter quantity lets the harness compare dimension accuracy
    regardless of how the source expressed it.
    """

    raw: str  # as printed, e.g. "12'-6\"" or "3810"
    value: float | None = None  # parsed numeric in `unit`
    unit: str | None = None  # "mm", "m", "ft-in", ...
    value_mm: float | None = None  # canonicalized to millimeters
    confidence: float | None = Field(default=None, ge=0.0, le=1.0)
    source_bbox: SourceBBox | None = None


class Scale(CIRBase):
    """Drawing scale, recovered deterministically from title block / scale bar.

    Scale is recovered deterministically — never by an LLM — because downstream
    quantities depend on it and must be reliable. ``px_per_real_unit`` is the
    calibration L1 needs to convert measured pixels into real-world lengths.
    """

    raw: str | None = None  # printed scale, e.g. '1/4" = 1\'-0"' or "1:50"
    drawing_unit: str | None = None  # "in", "mm", "pt", "px"
    real_world_unit: str | None = None  # "ft", "m"
    ratio: float | None = None  # drawing units per real-world unit (1:50 -> 0.02)
    px_per_real_unit: float | None = None  # pixels per ft/m on the raster
    confidence: float | None = Field(default=None, ge=0.0, le=1.0)


class TitleBlock(CIRBase):
    """Parsed title-block fields. ``raw_fields`` keeps anything not modeled."""

    project_name: str | None = None
    project_number: str | None = None
    sheet_number: str | None = None
    sheet_title: str | None = None
    discipline: Discipline | None = None
    scale: str | None = None
    date: str | None = None
    drawn_by: str | None = None
    checked_by: str | None = None
    approved_by: str | None = None
    revision: str | None = None
    raw_fields: dict[str, str] = Field(default_factory=dict)


class Revision(CIRBase):
    """A revision-cloud / revision-table entry on a sheet."""

    number: str | None = None
    description: str | None = None
    date: str | None = None
    by: str | None = None


class LegendEntry(CIRBase):
    """A row in a drawing legend: a symbol glyph and what it means.

    Legends are how a new project's bespoke symbol set is learned few-shot, so they
    are first-class in the CIR.
    """

    symbol: str | None = None  # the legend key text / abbreviation
    description: str | None = None
    ifc_class: str | None = None
    ontology: OntologyCodes = Field(default_factory=OntologyCodes)
    entity_id: str | None = None  # link to a representative Entity, if any
    source_bbox: SourceBBox | None = None


class CrossReference(CIRBase):
    """A callout pointing from one sheet to a target detail/view/sheet.

    e.g. ``"3/E-501"`` → detail 3 on sheet E-501. These are the edges of the
    project *sheet-graph* that L0 extracts and the L4 agent traverses ("resolve
    callout 3/E-501").
    """

    id: str = Field(default_factory=_new_id)
    callout: str | None = None  # raw callout text, e.g. "3/E-501"
    target_sheet: str | None = None  # target sheet number, e.g. "E-501"
    target_detail: str | None = None  # target detail/view id on that sheet
    geometry: Geometry | None = None  # where the callout marker sits (normalized)
    source_bbox: SourceBBox | None = None
    confidence: float | None = Field(default=None, ge=0.0, le=1.0)


class Connection(CIRBase):
    """An edge in a connectivity graph — the general property-graph edge of the CIR.

    Nodes are :class:`Entity` objects referenced by id (symbols, or topological nodes with
    ``entity_type=GRAPH_NODE`` and ``attributes["node_role"]`` ∈ {connector, crossing,
    junction, port, border}). Connectivity is the core of the MEP/electrical wedge
    (``home_run`` → panel, P&ID component → component) and the harness scores these as graph
    node/edge AP.

    One schema serves every graph convention we ingest (electrical circuits, P&ID lines,
    room adjacency, wall/road junction graphs — see ``docs/GRAPH_MAPPING.md``):

    * :attr:`directed` — ``True`` (default) for oriented edges (home-run device→panel,
      conductor left→right); ``False`` for symmetric edges (room adjacency, undirected
      P&ID/circuit connectivity, walls). The edge metric honors this, so an undirected
      ground-truth edge is never mis-scored against a directed prediction (or vice versa).
    * :attr:`geometry` — the optional drawn path of the edge (a pipe/wire/duct/wall
      polyline) for line-level tasks; ``None`` when the edge is purely topological.
    """

    id: str = Field(default_factory=_new_id)
    source_id: str  # Entity.id of the edge's tail (or one endpoint, if undirected)
    target_id: str  # Entity.id of the edge's head (or the other endpoint)
    connection_type: str | None = None  # "home_run", "conductor", "pipe", "adjacent", ...
    directed: bool = True  # False = symmetric edge (adjacency, undirected connectivity)
    geometry: Geometry | None = None  # optional drawn edge path (pipe/wire/wall polyline)
    confidence: float | None = Field(default=None, ge=0.0, le=1.0)
    attributes: dict[str, Any] = Field(default_factory=dict)


class SourceFile(CIRBase):
    """Provenance of the original document a :class:`DrawingSet` was parsed from."""

    filename: str | None = None
    file_type: str | None = None  # "pdf" | "dwg" | "dxf" | "ifc" | "image"
    is_vector: bool | None = None  # vector-native vs flattened/scanned raster
    page_count: int | None = None
    sha256: str | None = None  # content hash, for reproducibility
    ingested_at: datetime | None = None
    ingest_tool: str | None = None  # e.g. "ezdxf", "pymupdf", "ifcopenshell"


class PageSize(CIRBase):
    """Physical/pixel extent of a sheet, in the source unit."""

    width: float
    height: float
    unit: str = "pt"  # "pt" (PDF) or "px" (raster)


# ---------------------------------------------------------------------------
# Core hierarchy: Entity -> View -> Sheet -> DrawingSet
# ---------------------------------------------------------------------------
class Entity(LicensedRecord):
    """A single recognized element on a drawing — the atom of the CIR.

    Carries normalized :attr:`geometry`, its :attr:`ifc_class` + :attr:`ontology`
    codes (L2 grounding), any :attr:`text_spans`/:attr:`dimensions`, a traceable
    :attr:`source_bbox`, a required :attr:`confidence` score, an audit trail of
    which model produced it, and — mandatorily — its license provenance and data
    lane (from :class:`LicensedRecord`).
    """

    id: str = Field(default_factory=_new_id)
    entity_type: EntityType = EntityType.OTHER
    label: str | None = None  # predicted / human label, e.g. "duplex receptacle"
    geometry: Geometry | None = None
    ifc_class: str | None = None  # e.g. "IfcDoor", "IfcFlowController"
    ontology: OntologyCodes = Field(default_factory=OntologyCodes)
    text_spans: list[TextSpan] = Field(default_factory=list)
    dimensions: list[DimensionString] = Field(default_factory=list)
    source_bbox: SourceBBox | None = None
    confidence: float = Field(ge=0.0, le=1.0)  # REQUIRED: every entity is scored
    produced_by: str | None = None  # model/tool id that emitted this entity
    model_version: str | None = None  # version of that model (audit trail)
    attributes: dict[str, Any] = Field(default_factory=dict)


class View(CIRBase):
    """A discrete drawing on a sheet — a plan, detail, schedule, single-line
    diagram, etc. Holds the entities recognized within it and, for schematic views,
    the connectivity graph among them."""

    id: str = Field(default_factory=_new_id)
    name: str | None = None
    view_type: ViewType = ViewType.OTHER
    region: BBox | None = None  # where on the sheet this view sits (normalized)
    scale: Scale | None = None
    entities: list[Entity] = Field(default_factory=list)
    connections: list[Connection] = Field(default_factory=list)
    attributes: dict[str, Any] = Field(default_factory=dict)

    def iter_entities(self) -> Iterator[Entity]:
        """Iterate the entities in this view."""
        yield from self.entities


class Sheet(CIRBase):
    """One sheet (page) of a drawing set.

    Carries the sheet number, discipline, scale, title-block fields,
    cross-references (callout → target), legend, and revisions.
    """

    id: str = Field(default_factory=_new_id)
    sheet_number: str  # REQUIRED: sheets are keyed by their number, e.g. "E-201"
    discipline: Discipline | None = None
    title: str | None = None
    page_index: int | None = None  # 0-based index in the source file
    size: PageSize | None = None
    scale: Scale | None = None
    title_block: TitleBlock | None = None
    views: list[View] = Field(default_factory=list)
    cross_references: list[CrossReference] = Field(default_factory=list)
    legend: list[LegendEntry] = Field(default_factory=list)
    revisions: list[Revision] = Field(default_factory=list)
    attributes: dict[str, Any] = Field(default_factory=dict)

    def iter_entities(self) -> Iterator[Entity]:
        """Iterate every entity across every view on this sheet."""
        for view in self.views:
            yield from view.entities


class DrawingSet(LicensedRecord):
    """The root CIR document: a parsed drawing *set* (a project deliverable).

    Also the dataset-level record, hence it carries the mandatory
    ``license_provenance`` + ``data_lane``. A COMMERCIAL drawing set may contain
    only commercial-lane, commercial-safe entities — enforced by
    :meth:`_enforce_commercial_set`.
    """

    schema_version: str = Field(default=SCHEMA_VERSION)
    id: str = Field(default_factory=_new_id)
    name: str | None = None
    project_name: str | None = None
    project_number: str | None = None
    source: SourceFile | None = None
    sheets: list[Sheet] = Field(default_factory=list)
    created_at: datetime = Field(default_factory=lambda: datetime.now(UTC))
    metadata: dict[str, Any] = Field(default_factory=dict)

    # -- traversal helpers -------------------------------------------------------
    def iter_entities(self) -> Iterator[Entity]:
        """Iterate every entity across every sheet and view in the set."""
        for sheet in self.sheets:
            for view in sheet.views:
                yield from view.entities

    def entity_count(self) -> int:
        """Total number of entities in the set."""
        return sum(1 for _ in self.iter_entities())

    # -- license / lane helpers (used by datasets.audit and CI guards) -----------
    def licenses_present(self) -> set[LicenseProvenance]:
        """The set of distinct licenses present (the set's own + every entity's)."""
        licenses = {self.license_provenance}
        licenses.update(entity.license_provenance for entity in self.iter_entities())
        return licenses

    @property
    def is_commercial_safe(self) -> bool:
        """``True`` iff every record here could legally ship in the commercial lane."""
        return self.license_provenance.commercial_safe and all(
            entity.license_provenance.commercial_safe for entity in self.iter_entities()
        )

    def assert_commercial_safe(self) -> None:
        """Raise :class:`LicenseLaneError` if anything here is not commercial-safe.

        The explicit, typed guard for pipelines, the dataset ``audit`` command, and
        CI — distinct from the construction-time pydantic validation.
        """
        offenders = sorted(
            {
                entity.license_provenance.value
                for entity in self.iter_entities()
                if not entity.license_provenance.commercial_safe
            }
        )
        if not self.license_provenance.commercial_safe:
            offenders.append(self.license_provenance.value)
        if offenders:
            raise LicenseLaneError(
                f"DrawingSet {self.id!r} is not commercial-safe; it contains "
                f"non-commercial license(s): {sorted(set(offenders))}."
            )

    @model_validator(mode="after")
    def _enforce_commercial_set(self) -> Self:
        """A commercial drawing set may hold only commercial-lane, safe entities."""
        if self.data_lane is DataLane.COMMERCIAL:
            for entity in self.iter_entities():
                if (
                    entity.data_lane is not DataLane.COMMERCIAL
                    or not entity.license_provenance.commercial_safe
                ):
                    raise ValueError(
                        f"COMMERCIAL DrawingSet {self.id!r} contains a non-commercial "
                        f"entity {entity.id!r} (lane={entity.data_lane.value}, "
                        f"license={entity.license_provenance.value}). The commercial "
                        f"lane must contain only commercial-safe data."
                    )
        return self
