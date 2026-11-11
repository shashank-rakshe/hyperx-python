"""A small curated starter list of open IFC models — and a candid note on its limits.

The IFC ingestion path (:mod:`synthetic.ifc_source`) is only as diverse as the IFC it can
read, and **open IFC is overwhelmingly architectural/structural**: the well-known sample
buildings carry walls, slabs, and spaces, but few electrical devices and almost never the
``IfcRelConnectsPorts`` / ``IfcDistributionCircuit`` connectivity that the MEP/electrical
wedge needs. This list is therefore a seed for the IFC path and an *honesty marker*, not a
sufficient source for the connectivity-rich pilot (which the parametric scene supplies).

The decisive follow-up — flagged here, deliberately **not** built in v0 — is procedurally
generating electrically-rich IFC so the IFC path can scale; see ``docs/SYNTHETIC.md``.

This module holds only *references* (name, URL, license, notes). It never downloads or
vendors data — actual fetching belongs to the dataset registry under its license discipline.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class CuratedIFC:
    """A reference to an open IFC model considered for the synthetic IFC path."""

    name: str
    url: str
    license: str  # as published by the source; verify before any commercial use
    discipline: str
    electrical_rich: bool  # does it actually carry electrical devices + connectivity?
    note: str


#: Open IFC models to seed the IFC path. ``electrical_rich`` is the column that matters —
#: note how few are True, which is exactly why v0 leans on the parametric scene.
CURATED_IFC: list[CuratedIFC] = [
    CuratedIFC(
        name="KIT Duplex Apartment (Common BIM Files)",
        url="https://github.com/buildingSMART/Sample-Test-Files",
        license="open sample (verify terms)",
        discipline="architectural+mep",
        electrical_rich=False,
        note="Classic sample building; some MEP fixtures, sparse/no electrical circuit connectivity.",
    ),
    CuratedIFC(
        name="KIT Office Building (Common BIM Files)",
        url="https://github.com/buildingSMART/Sample-Test-Files",
        license="open sample (verify terms)",
        discipline="architectural+mep",
        electrical_rich=False,
        note="Multi-storey office; lighting/fixtures present in some exports, connectivity rarely encoded.",
    ),
    CuratedIFC(
        name="Schependomlaan",
        url="https://github.com/buildingSMART/Sample-Test-Files",
        license="open research dataset (verify terms)",
        discipline="architectural+structural",
        electrical_rich=False,
        note="Well-used open BIM dataset; primarily arch/struct, not an electrical source.",
    ),
    CuratedIFC(
        name="IfcOpenShell example files",
        url="https://github.com/IfcOpenShell/IfcOpenShell",
        license="LGPL project samples (verify per file)",
        discipline="mixed",
        electrical_rich=False,
        note="Assorted small models for parser testing; useful for IFC-path smoke tests.",
    ),
]


def electrical_rich_sources() -> list[CuratedIFC]:
    """The curated models that actually carry electrical devices + connectivity (today: none)."""
    return [m for m in CURATED_IFC if m.electrical_rich]
