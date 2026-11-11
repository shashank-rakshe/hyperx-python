"""Versioning for the Canonical Intermediate Representation (CIR) schema.

The CIR is the substrate every layer (L0 ingest → L4 agent) reads and writes, so
its schema is explicitly, semantically versioned. The compatibility contract is:

    A document is *readable* by this library iff it shares the same MAJOR version.

* MAJOR bump  -> breaking change (fields removed/retyped); old readers must refuse.
* MINOR bump  -> additive, backward-compatible change (new optional fields).
* PATCH bump  -> clarifications/fixes with no wire impact.

:data:`SCHEMA_VERSION` is stamped onto every :class:`~cir.schema.DrawingSet` and is
checked on deserialization (see :mod:`cir.serialization`).
"""

from __future__ import annotations

from .exceptions import SchemaVersionError

#: The schema version this library produces and can read (semantic versioning).
#: 0.2.0 (2026-07-03): additive — Connection.directed + Connection.geometry, to carry
#: every graph convention uniformly (see docs/GRAPH_MAPPING.md, ADR-0012). Backward-
#: compatible: 0.1.0 documents load unchanged (new fields take their defaults).
SCHEMA_VERSION: str = "0.2.0"


def parse_version(version: str) -> tuple[int, int, int]:
    """Parse a ``"MAJOR.MINOR.PATCH"`` string into an integer triple.

    Raises:
        SchemaVersionError: if ``version`` is not three dot-separated integers.
    """
    parts = version.split(".")
    if len(parts) != 3:
        raise SchemaVersionError(
            f"Malformed schema version {version!r}: expected 'MAJOR.MINOR.PATCH'."
        )
    try:
        major, minor, patch = (int(p) for p in parts)
    except ValueError as exc:
        raise SchemaVersionError(
            f"Malformed schema version {version!r}: components must be integers."
        ) from exc
    return major, minor, patch


#: Parsed form of :data:`SCHEMA_VERSION`.
SCHEMA_VERSION_INFO: tuple[int, int, int] = parse_version(SCHEMA_VERSION)


def is_compatible(version: str) -> bool:
    """Return ``True`` if a document at ``version`` can be read by this library."""
    return parse_version(version)[0] == SCHEMA_VERSION_INFO[0]


def check_compatible(version: str) -> None:
    """Raise :class:`SchemaVersionError` if ``version`` is not readable here."""
    if not is_compatible(version):
        raise SchemaVersionError(
            f"CIR document schema version {version!r} is incompatible with this "
            f"library's schema version {SCHEMA_VERSION!r} (major versions differ)."
        )
