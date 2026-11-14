"""IFC ingestor via IfcOpenShell.

Parses an IFC model into CIR entities carrying their **native IFC class**
(``IfcWall``, ``IfcDoor``, ``IfcFlowController``, ...). Building elements are grouped by
their containing storey → one CIR :class:`~cir.Sheet` per storey (a plan view). Each
element's insertion point (from its object placement, via the pure-Python placement
util) gives a normalized location; full 2-D geometry projection is left to later phases.
"""

from __future__ import annotations

from collections import defaultdict
from pathlib import Path
from typing import Any

from cir import (
    DrawingSet,
    Entity,
    EntityType,
    Geometry,
    Sheet,
    SourceFile,
    View,
    ViewType,
)

from .base import Ingestor, register
from .normalize import Bounds, Normalizer

# Coarse IFC-class -> CIR entity_type. ifc_class keeps the precise semantics.
_ENTITY_TYPE_PREFIX = {
    "IfcWall": EntityType.WALL,
    "IfcCurtainWall": EntityType.WALL,
    "IfcDoor": EntityType.OPENING,
    "IfcWindow": EntityType.OPENING,
    "IfcSpace": EntityType.ROOM,
    "IfcColumn": EntityType.EQUIPMENT,
    "IfcBeam": EntityType.EQUIPMENT,
    "IfcSlab": EntityType.POLYGON,
    "IfcFlowController": EntityType.EQUIPMENT,
    "IfcFlowTerminal": EntityType.FIXTURE,
    "IfcFlowSegment": EntityType.SEGMENT,
}


def _entity_type_for(ifc_class: str) -> EntityType:
    for prefix, etype in _ENTITY_TYPE_PREFIX.items():
        if ifc_class.startswith(prefix):
            return etype
    return EntityType.OTHER


@register
class IFCIngestor(Ingestor):
    """Ingest an IFC model into the CIR (elements -> entities, storeys -> sheets)."""

    file_types = ("ifc",)

    def ingest(self, path: Path) -> DrawingSet:
        import ifcopenshell
        from ifcopenshell.util import placement as ifc_placement

        model = ifcopenshell.open(str(path))
        elements = list(model.by_type("IfcElement"))

        # Insertion points from object placements (best-effort, no geometry kernel).
        points: dict[int, tuple[float, float]] = {}
        for el in elements:
            pt = self._location(el, ifc_placement)
            if pt is not None:
                points[el.id()] = pt
        bounds = Bounds()
        bounds.update_many(points.values())
        normalizer = Normalizer(bounds, flip_y=True) if bounds.is_valid else None

        # Group elements by containing storey.
        storey_of: dict[int, str] = {}
        for storey in model.by_type("IfcBuildingStorey"):
            name = storey.Name or f"Storey {storey.id()}"
            for rel in storey.ContainsElements or []:
                for el in rel.RelatedElements:
                    storey_of[el.id()] = name
        groups: dict[str, list[Any]] = defaultdict(list)
        for el in elements:
            groups[storey_of.get(el.id(), "Model")].append(el)

        sheets = [self._storey_sheet(name, els, points, normalizer) for name, els in groups.items()]
        project = model.by_type("IfcProject")
        project_name = project[0].Name if project else None
        return DrawingSet(
            name=path.stem,
            project_name=project_name,
            source=SourceFile(
                filename=path.name, file_type="ifc", is_vector=True, ingest_tool="ifcopenshell"
            ),
            sheets=sheets,
            metadata={"ifc_schema": model.schema, "n_elements": len(elements)},
            **self.stamp(),
        )

    @staticmethod
    def _location(element: Any, ifc_placement: Any) -> tuple[float, float] | None:
        if element.ObjectPlacement is None:
            return None
        try:
            matrix = ifc_placement.get_local_placement(element.ObjectPlacement)
            return float(matrix[0][3]), float(matrix[1][3])
        except Exception:  # placement parsing is best-effort
            return None

    def _storey_sheet(
        self,
        name: str,
        elements: list[Any],
        points: dict[int, tuple[float, float]],
        normalizer: Normalizer | None,
    ) -> Sheet:
        entities = [self._entity(el, points, normalizer) for el in elements]
        view = View(name=name, view_type=ViewType.PLAN, entities=entities)
        return Sheet(sheet_number=name, views=[view], attributes={"ifc_storey": name})

    def _entity(
        self,
        element: Any,
        points: dict[int, tuple[float, float]],
        normalizer: Normalizer | None,
    ) -> Entity:
        ifc_class = element.is_a()
        geometry = None
        pt = points.get(element.id())
        if pt is not None and normalizer is not None:
            np = normalizer.point(*pt)
            geometry = Geometry.point(np.x, np.y)
        return Entity(
            entity_type=_entity_type_for(ifc_class),
            label=element.Name or ifc_class,
            ifc_class=ifc_class,
            geometry=geometry,
            confidence=1.0,  # exact parse from the model
            produced_by="ifcopenshell",
            attributes={"global_id": element.GlobalId, "ifc_type": ifc_class},
            **self.stamp(),
        )
