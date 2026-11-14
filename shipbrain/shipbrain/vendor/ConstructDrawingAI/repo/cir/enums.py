"""Enumerations and the license policy for the CIR.

The two enums that matter most for the business are :class:`DataLane` and
:class:`LicenseProvenance`. Together with :data:`COMMERCIAL_SAFE_LICENSES` they
encode the *single most important invariant in the codebase*: which data is
allowed to train shippable (commercial) weights.
"""

from __future__ import annotations

from enum import Enum


class DataLane(str, Enum):
    """Which training lane a record belongs to (see ``docs/DECISIONS.md`` #1).

    * ``RESEARCH`` — anything goes: used for papers, benchmarks, and SOTA chasing.
    * ``COMMERCIAL`` — only *commercial-safe* data (permissive / synthetic / owned)
      may enter; this is what may train weights we sell or redistribute.

    The two lanes are kept rigorously separate so we can never accidentally ship
    weights trained on non-commercial (e.g. CC-BY-NC) data.
    """

    RESEARCH = "research"
    COMMERCIAL = "commercial"


class LicenseProvenance(str, Enum):
    """The license of the source a record came from.

    The string values are stable wire identifiers (do not rename casually — they
    are persisted in CIR documents and the dataset registry). Whether each license
    may enter the commercial lane is decided by membership in
    :data:`COMMERCIAL_SAFE_LICENSES`, queryable via :attr:`commercial_safe`.
    """

    # --- commercial-safe (see COMMERCIAL_SAFE_LICENSES) ---
    CC0 = "CC0"
    PUBLIC_DOMAIN = "public-domain"
    PERMISSIVE = "permissive"  # MIT / Apache-2.0 / BSD-style
    SYNTHETIC_OWNED = "synthetic-owned"  # produced by our synthetic engine (the moat)
    OWNED = "owned"  # data we created/own outright
    PROPRIETARY_LICENSED = "proprietary-licensed"  # 3rd-party data licensed FOR commercial use

    # --- research-lane only (NOT commercial-safe by policy) ---
    CC_BY = "CC-BY"  # commercial-OK in theory, but conservatively gated pending legal sign-off
    CC_BY_SA = "CC-BY-SA"  # share-alike copyleft conflicts with proprietary weights
    CC_BY_ND = "CC-BY-ND"  # no-derivatives
    CC_BY_NC = "CC-BY-NC"  # non-commercial
    CC_BY_NC_SA = "CC-BY-NC-SA"
    CC_BY_NC_ND = "CC-BY-NC-ND"
    RESEARCH_ONLY = "research-only"  # released for research use only
    UNKNOWN = "unknown"  # unverified -> fail safe to research lane

    @property
    def commercial_safe(self) -> bool:
        """``True`` iff data under this license may train commercial-lane weights."""
        return self in COMMERCIAL_SAFE_LICENSES


#: The *only* licenses permitted in the commercial lane. This frozenset is the
#: single source of truth for the policy — deliberately conservative: a license is
#: excluded unless it unambiguously permits commercial, proprietary, derivative use.
#:
#: Notably EXCLUDED (research lane only):
#:   * any ``*-NC-*`` (non-commercial) license,
#:   * any ``*-ND`` (no-derivatives) license,
#:   * ``CC-BY-SA`` (share-alike copyleft — endangers proprietary weights),
#:   * ``CC-BY`` (permits commercial use, but gated here pending explicit legal
#:     clearance; re-classify the source as PERMISSIVE/OWNED after sign-off rather
#:     than loosening this set casually),
#:   * ``UNKNOWN`` / unverified (fail safe).
#:
#: To change the policy, edit THIS set (and get legal sign-off) — nothing else.
COMMERCIAL_SAFE_LICENSES: frozenset[LicenseProvenance] = frozenset(
    {
        LicenseProvenance.CC0,
        LicenseProvenance.PUBLIC_DOMAIN,
        LicenseProvenance.PERMISSIVE,
        LicenseProvenance.SYNTHETIC_OWNED,
        LicenseProvenance.OWNED,
        LicenseProvenance.PROPRIETARY_LICENSED,
    }
)


class Discipline(str, Enum):
    """Construction drawing discipline (with US National CAD Standard sheet codes).

    ``MECHANICAL``/``ELECTRICAL``/``PLUMBING`` are the commercial wedge (MEP).
    """

    GENERAL = "general"
    SURVEY = "survey"
    GEOTECHNICAL = "geotechnical"
    CIVIL = "civil"
    LANDSCAPE = "landscape"
    STRUCTURAL = "structural"
    ARCHITECTURAL = "architectural"
    INTERIORS = "interiors"
    EQUIPMENT = "equipment"
    FIRE_PROTECTION = "fire_protection"
    PLUMBING = "plumbing"
    PROCESS = "process"
    MECHANICAL = "mechanical"
    ELECTRICAL = "electrical"
    TELECOM = "telecom"
    OTHER = "other"

    @property
    def code(self) -> str:
        """The single-letter NCS Level-1 discipline designator (e.g. ``"E"``)."""
        return _DISCIPLINE_CODES[self]


_DISCIPLINE_CODES: dict[Discipline, str] = {
    Discipline.GENERAL: "G",
    Discipline.SURVEY: "V",
    Discipline.GEOTECHNICAL: "B",
    Discipline.CIVIL: "C",
    Discipline.LANDSCAPE: "L",
    Discipline.STRUCTURAL: "S",
    Discipline.ARCHITECTURAL: "A",
    Discipline.INTERIORS: "I",
    Discipline.EQUIPMENT: "Q",
    Discipline.FIRE_PROTECTION: "F",
    Discipline.PLUMBING: "P",
    Discipline.PROCESS: "D",
    Discipline.MECHANICAL: "M",
    Discipline.ELECTRICAL: "E",
    Discipline.TELECOM: "T",
    Discipline.OTHER: "X",
}


class ViewType(str, Enum):
    """The kind of drawing a :class:`~cir.schema.View` represents."""

    PLAN = "plan"
    ELEVATION = "elevation"
    SECTION = "section"
    DETAIL = "detail"
    SCHEDULE = "schedule"  # tabular: door/window/panel/finish schedule
    LEGEND = "legend"
    DIAGRAM = "diagram"  # single-line / riser / connectivity schematic (MEP, P&ID)
    KEY_PLAN = "key_plan"
    THREE_D = "3d"  # isometric / perspective
    TITLE_SHEET = "title_sheet"
    OTHER = "other"


class EntityType(str, Enum):
    """The CIR's coarse taxonomy of primitive kinds.

    This is intentionally distinct from :attr:`~cir.schema.Entity.ifc_class`:
    ``entity_type`` says *what shape of thing this is in the CIR* (a symbol, a
    polygon, a graph node, a schedule cell), while ``ifc_class`` carries the *domain
    semantics* (``IfcDoor``, ``IfcFlowController``). Keep ``entity_type`` stable and
    small; push richness into ``ifc_class`` + ontology codes.
    """

    SYMBOL = "symbol"  # a detected symbol/glyph (receptacle, valve, door tag, ...)
    TEXT = "text"  # free text / label / annotation
    DIMENSION = "dimension"  # a dimension string + its leader
    LINE = "line"
    POLYLINE = "polyline"
    POLYGON = "polygon"  # closed region (room, zone, hatch area)
    WALL = "wall"
    OPENING = "opening"  # door/window opening in a wall
    ROOM = "room"
    FIXTURE = "fixture"  # plumbing / lighting / etc. fixture
    EQUIPMENT = "equipment"
    SEGMENT = "segment"  # a conduit / pipe / duct run segment
    GRAPH_NODE = "graph_node"  # an explicit connectivity node
    TABLE_CELL = "table_cell"  # a schedule cell
    CALLOUT = "callout"  # a cross-reference callout marker
    TITLE_BLOCK_FIELD = "title_block_field"
    LEGEND_ENTRY = "legend_entry"
    OTHER = "other"
