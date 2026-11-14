"""Canonical Intermediate Representation (CIR) — the substrate of the platform.

The CIR is the one schema every layer reads and writes:

    L0 ingest → L1 perception → L2 grounding → L3 engines → L4 agent
                          ╲          │          ╱
                           ╲         │         ╱
                            ▼        ▼        ▼
                     ── Canonical Intermediate Representation ──
              DrawingSet → Sheet → View → Entity (+ Connection edges)

Two design commitments make the CIR load-bearing:

1. **Structured, ontology-grounded output, not pixels.** Every recognized element is
   an :class:`Entity` with normalized geometry, an IFC class, ontology codes, a
   confidence score, and traceable source evidence.
2. **License provenance is mandatory and enforced.** Every entity and dataset record
   carries ``license_provenance`` + ``data_lane``; the research/commercial lane
   invariant is checked at construction time (see :class:`LicensedRecord`).

Quick start::

    import cir

    ds = cir.make_example_drawing_set(data_lane=cir.DataLane.RESEARCH)
    blob = cir.to_msgpack(ds)               # compact binary
    same = cir.from_msgpack(cir.DrawingSet, blob)
    assert same == ds

    ds.assert_commercial_safe()             # raises LicenseLaneError if it can't ship
"""

from __future__ import annotations

from .enums import (
    COMMERCIAL_SAFE_LICENSES,
    DataLane,
    Discipline,
    EntityType,
    LicenseProvenance,
    ViewType,
)
from .examples import make_example_drawing_set
from .exceptions import (
    CIRError,
    LicenseLaneError,
    SchemaVersionError,
    SerializationError,
)
from .geometry import BBox, Geometry, GeometryType, Point, SourceBBox
from .schema import (
    CIRBase,
    Connection,
    CrossReference,
    DimensionString,
    DrawingSet,
    Entity,
    LegendEntry,
    LicensedRecord,
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
from .serialization import (
    BINARY_SUFFIXES,
    from_dict,
    from_gzip_json,
    from_json,
    from_msgpack,
    load,
    save,
    to_dict,
    to_gzip_json,
    to_json,
    to_msgpack,
)
from .version import (
    SCHEMA_VERSION,
    SCHEMA_VERSION_INFO,
    check_compatible,
    is_compatible,
)

__all__ = [
    # version
    "SCHEMA_VERSION",
    "SCHEMA_VERSION_INFO",
    "is_compatible",
    "check_compatible",
    # exceptions
    "CIRError",
    "SchemaVersionError",
    "LicenseLaneError",
    "SerializationError",
    # enums + license policy
    "DataLane",
    "LicenseProvenance",
    "COMMERCIAL_SAFE_LICENSES",
    "Discipline",
    "ViewType",
    "EntityType",
    # geometry
    "GeometryType",
    "Point",
    "BBox",
    "Geometry",
    "SourceBBox",
    # schema
    "CIRBase",
    "LicensedRecord",
    "OntologyCodes",
    "TextSpan",
    "DimensionString",
    "Scale",
    "TitleBlock",
    "Revision",
    "LegendEntry",
    "CrossReference",
    "Connection",
    "SourceFile",
    "PageSize",
    "Entity",
    "View",
    "Sheet",
    "DrawingSet",
    # serialization
    "to_dict",
    "from_dict",
    "to_json",
    "from_json",
    "to_msgpack",
    "from_msgpack",
    "to_gzip_json",
    "from_gzip_json",
    "save",
    "load",
    "BINARY_SUFFIXES",
    # examples
    "make_example_drawing_set",
]
