"""Airtight licensing for everything the engine emits.

The synthetic engine is the source of the **commercial** training lane (Decision 1 +
ADR-0009): public/research data cannot train shippable weights, so the commercial lane
is sourced almost entirely from here. That makes the stamping load-bearing — if a single
synthetic record leaked out mis-stamped, it could either poison the commercial lane or
get wrongly excluded from it.

So there is exactly one stamp (:func:`stamp`) and one guard (:func:`assert_synthetic_owned`),
and the pipeline runs the guard on every emitted :class:`~cir.DrawingSet` before it is
written. Output that is not ``synthetic-owned`` / ``commercial`` cannot leave the engine.
"""

from __future__ import annotations

from typing import Any

from cir import DataLane, DrawingSet, LicenseProvenance

#: Every record the engine emits carries this license...
SYNTHETIC_LICENSE: LicenseProvenance = LicenseProvenance.SYNTHETIC_OWNED
#: ...and this lane. Synthetic data is the backbone of the commercial lane.
SYNTHETIC_LANE: DataLane = DataLane.COMMERCIAL
#: Stamped into each emitted document's metadata for audit.
ENGINE_VERSION: str = "0.1.0-electrical"


class SyntheticProvenanceError(RuntimeError):
    """Raised when an emitted record is not stamped synthetic-owned / commercial."""


def stamp() -> dict[str, Any]:
    """The one provenance stamp applied to every synthetic record."""
    return {"license_provenance": SYNTHETIC_LICENSE, "data_lane": SYNTHETIC_LANE}


def assert_synthetic_owned(ds: DrawingSet) -> None:
    """Guarantee ``ds`` and every entity in it are synthetic-owned / commercial.

    The hard gate the generator runs before writing any sample. This is stricter than
    the CIR's own lane invariant (which only requires *commercial-safe*): synthetic
    output must be *exactly* ``synthetic-owned`` / ``commercial``, nothing else.
    """
    offenders: list[str] = []
    if ds.license_provenance is not SYNTHETIC_LICENSE or ds.data_lane is not SYNTHETIC_LANE:
        offenders.append(
            f"DrawingSet {ds.id!r}: license={ds.license_provenance.value!r} "
            f"lane={ds.data_lane.value!r}"
        )
    for entity in ds.iter_entities():
        if (
            entity.license_provenance is not SYNTHETIC_LICENSE
            or entity.data_lane is not SYNTHETIC_LANE
        ):
            offenders.append(
                f"Entity {entity.id!r}: license={entity.license_provenance.value!r} "
                f"lane={entity.data_lane.value!r}"
            )
    if offenders:
        raise SyntheticProvenanceError(
            "synthetic output must be exactly synthetic-owned/commercial; offenders: "
            + "; ".join(offenders[:10])
            + (" ..." if len(offenders) > 10 else "")
        )
