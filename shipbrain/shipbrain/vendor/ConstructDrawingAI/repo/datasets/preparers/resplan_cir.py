"""ResPlan (MIT, 17k residential floor plans) → CIR.

ResPlan ships shapely vector geometries per plan — rooms (bedroom/bathroom/kitchen/living/…),
openings (door/window/front_door), and walls — plus a real ``net_area`` (m²). We calibrate a
per-plan real scale from ``net_area`` so the CIR carries a physical page size, and the L3 takeoff
then produces **real room areas (m²) and wall lengths (m)** — not just counts. MIT-licensed →
permissive lane. Requires ``shapely`` (imported lazily).
"""

from __future__ import annotations

import logging
import math
import pickle
from pathlib import Path
from typing import Any

from cir import (
    DataLane,
    Discipline,
    DrawingSet,
    Entity,
    EntityType,
    Geometry,
    LicenseProvenance,
    PageSize,
    Scale,
    Sheet,
    View,
    ViewType,
)

logger = logging.getLogger(__name__)

_ROOMS = {
    "bedroom": "Bedroom",
    "bathroom": "Bathroom",
    "kitchen": "Kitchen",
    "living": "Living Room",
    "balcony": "Balcony",
    "garden": "Garden",
    "parking": "Parking",
    "pool": "Pool",
}
_INTERIOR = ("bedroom", "bathroom", "kitchen", "living")  # for net_area scale calibration
_OPENINGS = {"door": "Door", "window": "Window", "front_door": "Front Door"}


def _geoms(v: Any) -> list[Any]:
    if v is None or getattr(v, "is_empty", False):
        return []
    return list(v.geoms) if hasattr(v, "geoms") else [v]


def plan_to_cir(plan: dict[str, Any]) -> DrawingSet | None:
    """Convert one ResPlan plan dict → a CIR DrawingSet with a real-world scale."""
    room_geoms = {k: _geoms(plan.get(k)) for k in _ROOMS}
    opening_geoms = {k: _geoms(plan.get(k)) for k in _OPENINGS}
    wall_geoms = _geoms(plan.get("wall"))

    everything = [g for gs in room_geoms.values() for g in gs] + wall_geoms
    if not everything:
        return None
    xs0 = [g.bounds[0] for g in everything]
    ys0 = [g.bounds[1] for g in everything]
    xs1 = [g.bounds[2] for g in everything]
    ys1 = [g.bounds[3] for g in everything]
    minx, miny, maxx, maxy = min(xs0), min(ys0), max(xs1), max(ys1)
    w = max(maxx - minx, 1e-6)
    h = max(maxy - miny, 1e-6)

    # per-plan scale: interior rooms' shapely area must equal net_area (m²)
    interior_units = sum(g.area for k in _INTERIOR for g in room_geoms[k])
    net_area = float(plan.get("net_area") or plan.get("area") or 0.0)
    m2_per_unit2 = (net_area / interior_units) if interior_units > 0 and net_area > 0 else 0.0
    m_per_unit = math.sqrt(m2_per_unit2) if m2_per_unit2 > 0 else 0.0

    def npoly(poly: Any) -> list[tuple[float, float]]:
        return [((x - minx) / w, (y - miny) / h) for x, y in list(poly.exterior.coords)[:-1]]

    def nbox(poly: Any) -> Geometry:
        b0, b1, b2, b3 = poly.bounds
        return Geometry.box((b0 - minx) / w, (b1 - miny) / h, (b2 - minx) / w, (b3 - miny) / h)

    prov: dict[str, Any] = {
        "license_provenance": LicenseProvenance.PERMISSIVE,
        "data_lane": DataLane.COMMERCIAL,
    }
    ents: list[Entity] = []
    i = 0
    for key, label in _ROOMS.items():
        for g in room_geoms[key]:
            if g.is_empty or len(list(g.exterior.coords)) < 4:
                continue
            ents.append(
                Entity(
                    id=f"r{i}",
                    entity_type=EntityType.ROOM,
                    label=label,
                    geometry=Geometry.polygon(npoly(g)),
                    confidence=1.0,
                    **prov,
                )
            )
            i += 1
    for key, label in _OPENINGS.items():
        for g in opening_geoms[key]:
            if g.is_empty:
                continue
            ents.append(
                Entity(
                    id=f"o{i}",
                    entity_type=EntityType.OPENING,
                    label=label,
                    geometry=nbox(g),
                    confidence=1.0,
                    **prov,
                )
            )
            i += 1
    for g in wall_geoms:
        if g.is_empty:
            continue
        ents.append(
            Entity(
                id=f"w{i}",
                entity_type=EntityType.WALL,
                label="Wall",
                geometry=nbox(g),
                confidence=1.0,
                **prov,
            )
        )
        i += 1

    sheet = Sheet(
        sheet_number="A-101",
        discipline=Discipline.ARCHITECTURAL,
        size=(
            PageSize(width=w * m_per_unit, height=h * m_per_unit, unit="m") if m_per_unit else None
        ),
        scale=Scale(ratio=1.0, real_world_unit="m") if m_per_unit else None,
        views=[View(view_type=ViewType.PLAN, entities=ents)],
    )
    return DrawingSet(name=f"resplan/{plan.get('id')}", sheets=[sheet], **prov)


def convert_resplan(pkl_path: Path, out_dir: Path, *, limit: int | None = None) -> int:
    """Convert ResPlan.pkl → CIR docs in ``out_dir``. Returns the count written."""
    import cir

    with pkl_path.open("rb") as fh:
        plans = pickle.load(fh)
    out_dir.mkdir(parents=True, exist_ok=True)
    n = 0
    for plan in plans[:limit] if limit else plans:
        ds = plan_to_cir(plan)
        if ds is None:
            continue
        cir.save(ds, str(out_dir / f"resplan__{plan.get('id')}.cir"))
        n += 1
    logger.info("converted %d ResPlan plans → %s", n, out_dir)
    return n
