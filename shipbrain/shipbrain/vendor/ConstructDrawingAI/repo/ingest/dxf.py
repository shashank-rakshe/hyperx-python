"""DXF / DWG ingestor (vector-first) via ezdxf.

Extracts primitives directly from CAD model space with exact geometry and layer info —
lines, polylines (open/closed), arcs, circles, text, and block inserts. Arcs and
circles are sampled into points so they survive per-axis normalization. The true model
extents + units are recorded on the document so exact coordinates are recoverable.

DWG is the proprietary binary format ezdxf cannot read directly; if a ``.dwg`` is given
we try the ODA File Converter via ezdxf's ``odafc`` add-on and raise a clear error if
it is unavailable (convert to DXF, or install the ODA File Converter).
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from cir import (
    DrawingSet,
    Entity,
    EntityType,
    Geometry,
    GeometryType,
    Sheet,
    SourceBBox,
    SourceFile,
    TextSpan,
    View,
    ViewType,
)

from .base import Ingestor, register
from .normalize import Bounds, Normalizer


@dataclass
class _Raw:
    entity_type: EntityType
    geom_type: GeometryType
    points: list[tuple[float, float]]
    layer: str
    label: str | None = None
    text: str | None = None
    attributes: dict[str, Any] = field(default_factory=dict)


def _arc_points(
    cx: float, cy: float, r: float, a0: float, a1: float, n: int = 24
) -> list[tuple[float, float]]:
    start, end = math.radians(a0), math.radians(a1)
    if end <= start:
        end += 2 * math.pi
    return [
        (
            cx + r * math.cos(start + (end - start) * i / (n - 1)),
            cy + r * math.sin(start + (end - start) * i / (n - 1)),
        )
        for i in range(n)
    ]


def _circle_points(cx: float, cy: float, r: float, n: int = 32) -> list[tuple[float, float]]:
    return [
        (cx + r * math.cos(2 * math.pi * i / n), cy + r * math.sin(2 * math.pi * i / n))
        for i in range(n)
    ]


@register
class DXFIngestor(Ingestor):
    """Ingest a DXF (or DWG via ODA) drawing into the CIR."""

    file_types = ("dxf", "dwg")

    def ingest(self, path: Path) -> DrawingSet:
        doc = self._read(path)
        msp = doc.modelspace()
        raws = list(self._collect(msp))

        bounds = Bounds()
        for raw in raws:
            bounds.update_many(raw.points)
        if not bounds.is_valid:
            bounds = Bounds(0.0, 0.0, 1.0, 1.0)
        normalizer = Normalizer(bounds, flip_y=True)  # CAD is Y-up

        entities = [self._to_entity(raw, normalizer) for raw in raws]
        units = getattr(doc, "units", None)
        view = View(name="model", view_type=ViewType.PLAN, entities=entities)
        sheet = Sheet(
            sheet_number=path.stem,
            views=[view],
            attributes={"origin": "vector", "source_format": "dxf"},
        )
        return DrawingSet(
            name=path.stem,
            source=SourceFile(
                filename=path.name, file_type="dxf", is_vector=True, ingest_tool="ezdxf"
            ),
            sheets=[sheet],
            metadata={"model_extents": bounds.as_dict(), "dxf_units": units},
            **self.stamp(),
        )

    def _read(self, path: Path) -> Any:
        import ezdxf

        if path.suffix.lower() == ".dwg":
            try:
                from ezdxf.addons import odafc

                return odafc.readfile(str(path))  # type: ignore[attr-defined]
            except Exception as exc:  # surface a clear, actionable message
                raise NotImplementedError(
                    "Reading DWG requires the ODA File Converter (ezdxf 'odafc' add-on). "
                    "Convert the file to DXF, or install the ODA File Converter."
                ) from exc
        return ezdxf.readfile(str(path))

    def _collect(self, msp: Any) -> list[_Raw]:
        raws: list[_Raw] = []
        for e in msp:
            kind = e.dxftype()
            layer = str(getattr(e.dxf, "layer", "0"))
            if kind == "LINE":
                raws.append(
                    _Raw(
                        EntityType.LINE,
                        GeometryType.POLYLINE,
                        [(e.dxf.start.x, e.dxf.start.y), (e.dxf.end.x, e.dxf.end.y)],
                        layer,
                    )
                )
            elif kind == "LWPOLYLINE":
                pts = [(p[0], p[1]) for p in e.get_points("xy")]
                closed = bool(e.closed)
                raws.append(
                    _Raw(
                        EntityType.POLYGON if closed else EntityType.POLYLINE,
                        GeometryType.POLYGON if closed else GeometryType.POLYLINE,
                        pts,
                        layer,
                    )
                )
            elif kind == "POLYLINE":
                pts = [(v.dxf.location.x, v.dxf.location.y) for v in e.vertices]
                if pts:
                    closed = bool(getattr(e, "is_closed", False))
                    raws.append(
                        _Raw(
                            EntityType.POLYGON if closed else EntityType.POLYLINE,
                            GeometryType.POLYGON if closed else GeometryType.POLYLINE,
                            pts,
                            layer,
                        )
                    )
            elif kind == "ARC":
                pts = _arc_points(
                    e.dxf.center.x, e.dxf.center.y, e.dxf.radius, e.dxf.start_angle, e.dxf.end_angle
                )
                raws.append(
                    _Raw(
                        EntityType.LINE,
                        GeometryType.POLYLINE,
                        pts,
                        layer,
                        attributes={"shape": "arc"},
                    )
                )
            elif kind == "CIRCLE":
                pts = _circle_points(e.dxf.center.x, e.dxf.center.y, e.dxf.radius)
                raws.append(
                    _Raw(
                        EntityType.SYMBOL,
                        GeometryType.POLYGON,
                        pts,
                        layer,
                        attributes={"shape": "circle"},
                    )
                )
            elif kind in ("TEXT", "MTEXT"):
                text = e.plain_text() if hasattr(e, "plain_text") else str(e.dxf.text)
                ins = e.dxf.insert
                raws.append(
                    _Raw(EntityType.TEXT, GeometryType.POINT, [(ins.x, ins.y)], layer, text=text)
                )
            elif kind == "INSERT":
                ins = e.dxf.insert
                raws.append(
                    _Raw(
                        EntityType.SYMBOL,
                        GeometryType.POINT,
                        [(ins.x, ins.y)],
                        layer,
                        label=str(e.dxf.name),
                        attributes={"block": str(e.dxf.name)},
                    )
                )
        return raws

    def _to_entity(self, raw: _Raw, normalizer: Normalizer) -> Entity:
        xs = [p[0] for p in raw.points]
        ys = [p[1] for p in raw.points]
        source_bbox = SourceBBox(
            x_min=min(xs), y_min=min(ys), x_max=max(xs), y_max=max(ys), unit="model"
        )
        attributes = {"layer": raw.layer, **raw.attributes}
        return Entity(
            entity_type=raw.entity_type,
            label=raw.label,
            geometry=Geometry(type=raw.geom_type, points=normalizer.points(raw.points)),
            source_bbox=source_bbox,
            text_spans=[TextSpan(text=raw.text)] if raw.text else [],
            confidence=1.0,  # exact vector extraction
            produced_by="ezdxf",
            attributes=attributes,
            **self.stamp(),
        )
