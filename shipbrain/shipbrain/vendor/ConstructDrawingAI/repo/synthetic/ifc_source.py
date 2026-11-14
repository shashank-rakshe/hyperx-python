"""Load a real IFC model into the canonical :class:`~synthetic.model.ElectricalModel`.

The engine's primary v0 source is parametric (:mod:`synthetic.scene`), but the spec's
first-priority architecture is IFC ingestion, and this is it: read the electrical-relevant
entities and their connectivity from an IFC file via IfcOpenShell, and produce the *same*
model type the renderer consumes — so an IFC-sourced sample and a parametric one render and
validate through one identical path.

Reuse: spatial placement is read with IfcOpenShell's placement util and normalized with
``ingest.normalize`` (the same normalizer L0 uses), then mapped into ``layout.PLAN_REGION``
so device coordinates are already CIR-normalized.

**Diversity is bounded by source-IFC diversity.** Open IFC models are overwhelmingly
architectural/structural and rarely carry electrical devices, let alone
``IfcRelConnectsPorts`` / ``IfcDistributionCircuit`` connectivity. So in v0 this path is
implemented and tested but *source-limited*; the connectivity-rich pilot comes from the
parametric scene. Procedurally generating electrically-rich IFC is the documented follow-up
(see ``docs/SYNTHETIC.md``) — explicitly **not** built here.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from ingest.normalize import Bounds, Normalizer

from .layout import PLAN_REGION
from .model import (
    Circuit,
    Device,
    DeviceKind,
    ElectricalModel,
    Panel,
)

# Exact IFC class -> device kind (electrical only). Prefix fallback handles subtypes.
_IFC_DEVICE_KIND: dict[str, DeviceKind] = {
    "IfcOutlet": DeviceKind.DUPLEX_RECEPTACLE,
    "IfcLightFixture": DeviceKind.LIGHT_FIXTURE,
    "IfcSwitchingDevice": DeviceKind.SINGLE_POLE_SWITCH,
    "IfcJunctionBox": DeviceKind.JUNCTION_BOX,
}
# IFC classes treated as the panelboard / distribution board.
_PANEL_CLASSES = {
    "IfcElectricDistributionBoard",
    "IfcElectricDistributionBoardType",
    "IfcDistributionBoard",
}
# Electrical device classes we ingest (panel handled separately).
_DEVICE_CLASSES = tuple(_IFC_DEVICE_KIND)


def device_kind_for_ifc(ifc_class: str) -> DeviceKind | None:
    """Map an IFC class to a v0 device kind, or ``None`` if it is not an electrical device."""
    if ifc_class in _IFC_DEVICE_KIND:
        return _IFC_DEVICE_KIND[ifc_class]
    for prefix, kind in _IFC_DEVICE_KIND.items():
        if ifc_class.startswith(prefix):
            return kind
    return None


def _to_region(nx: float, ny: float) -> tuple[float, float]:
    """Map a normalized [0,1] coordinate into the plan drawing region."""
    rx0, ry0, rx1, ry1 = PLAN_REGION
    return (rx0 + nx * (rx1 - rx0), ry0 + ny * (ry1 - ry0))


def _safe_by_type(ifc: Any, cls: str) -> list:
    """``by_type`` that returns ``[]`` for classes absent from the file's schema.

    Electrical classes like ``IfcOutlet`` exist only in IFC4; querying them on an **IFC2X3**
    file raises. Since open IFC is commonly IFC2X3, guard every class query so the loader
    degrades to an empty result instead of crashing.
    """
    try:
        return list(ifc.by_type(cls))
    except RuntimeError:
        return []


def load_electrical_model(path: str | Path, *, model_id: str | None = None) -> ElectricalModel:
    """Read an IFC file into an :class:`ElectricalModel` (best-effort, source-limited)."""
    import ifcopenshell
    from ifcopenshell.util import placement as ifc_placement

    path = Path(path)
    mid = model_id or f"ifc-{path.stem}"
    ifc = ifcopenshell.open(str(path))

    def location(element: Any) -> tuple[float, float] | None:
        if element.ObjectPlacement is None:
            return None
        try:
            m = ifc_placement.get_local_placement(element.ObjectPlacement)
            return float(m[0][3]), float(m[1][3])
        except Exception:
            return None

    # Collect raw electrical devices + the panel, with source-coordinate positions.
    raw: list[tuple[Any, DeviceKind, tuple[float, float]]] = []
    panel_el: Any | None = None
    panel_pt: tuple[float, float] | None = None
    for cls in _DEVICE_CLASSES:
        for el in _safe_by_type(ifc, cls):
            kind = device_kind_for_ifc(el.is_a())
            pt = location(el)
            if kind is not None and pt is not None:
                raw.append((el, kind, pt))
    for cls in _PANEL_CLASSES:
        for el in _safe_by_type(ifc, cls):
            panel_el = el
            panel_pt = location(el) or panel_pt
            break

    # Normalize all source points into [0,1] then into the plan region.
    bounds = Bounds()
    bounds.update_many([pt for _, _, pt in raw])
    if panel_pt is not None:
        bounds.update(*panel_pt)
    normalizer = Normalizer(bounds, flip_y=True) if bounds.is_valid else None

    def norm(pt: tuple[float, float]) -> tuple[float, float]:
        if normalizer is None:
            return _to_region(0.5, 0.5)
        np_ = normalizer.point(*pt)
        return _to_region(np_.x, np_.y)

    panel = Panel(
        id=f"{mid}-panel",
        name=(panel_el.Name if panel_el is not None and panel_el.Name else "PANEL"),
        x=(norm(panel_pt)[0] if panel_pt else PLAN_REGION[0] + 0.012),
        y=(norm(panel_pt)[1] if panel_pt else (PLAN_REGION[1] + PLAN_REGION[3]) / 2),
    )

    devices: list[Device] = []
    el_to_device: dict[int, str] = {}
    for i, (el, kind, pt) in enumerate(raw):
        x, y = norm(pt)
        did = f"{mid}-d{i}"
        devices.append(Device(id=did, kind=kind, x=x, y=y))
        el_to_device[el.id()] = did

    circuits = _extract_circuits(ifc, mid, devices, el_to_device, panel.id)

    model = ElectricalModel(
        id=mid,
        panel=panel,
        devices=devices,
        circuits=circuits,
        rooms=[],
        walls=[],
        dimensions=[],
        project_name=(ifc.by_type("IfcProject")[0].Name if ifc.by_type("IfcProject") else mid),
        sheet_prefix="E",
    )
    model.assert_consistent()
    return model


def _extract_circuits(
    ifc: Any,
    mid: str,
    devices: list[Device],
    el_to_device: dict[int, str],
    panel_id: str,
) -> list[Circuit]:
    """Build circuits from IfcDistributionCircuit/-System group assignments (best-effort).

    Most open IFC lacks this; when absent we return no circuits rather than inventing
    connectivity the source never stated (honest under-representation beats fabrication).
    """
    by_did = {d.id: d for d in devices}
    circuits: list[Circuit] = []
    number = 1
    group_types = ("IfcDistributionCircuit", "IfcDistributionSystem", "IfcGroup")
    seen_groups: set[int] = set()
    for gtype in group_types:
        try:
            groups = ifc.by_type(gtype)
        except Exception:
            groups = []
        for group in groups:
            if group.id() in seen_groups:
                continue
            seen_groups.add(group.id())
            member_dids: list[str] = []
            for rel in getattr(group, "IsGroupedBy", None) or []:
                for el in rel.RelatedObjects:
                    did = el_to_device.get(el.id())
                    if did is not None:
                        member_dids.append(did)
            if not member_dids:
                continue
            cid = f"{mid}-c{number}"
            for did in member_dids:
                by_did[did].circuit_id = cid
            circuits.append(
                Circuit(
                    id=cid,
                    number=number,
                    panel_id=panel_id,
                    device_ids=member_dids,
                    description=(group.Name or f"Circuit {number}"),
                )
            )
            number += 1
    return circuits
