"""L3 takeoff engine — the wedge product. Turns grounded CIR into a quantity takeoff.

Consumes a :class:`cir.DrawingSet` (perception output) and produces a decision-support
artifact, never an oracle: **every line carries a confidence score and evidence links back
to its exact source (sheet + entity id + coordinates), and low-confidence instances are
flagged for human review** (the cross-cutting L3 liability rule, see :mod:`engines`).

v1 counts discrete components by type (EA). Linear/area quantities (conduit/wire length,
wall LF, room SF) need a reliable drawing scale + the connectivity graph and are a follow-on;
connection counts by type are already summarized here as the seed for that. MasterFormat /
UniFormat grouping is L2 grounding's job — this engine keys line items by the CIR label.
"""

from __future__ import annotations

import csv
import io
from collections import defaultdict
from dataclasses import dataclass, field

from cir import DrawingSet, EntityType

#: Entity types excluded from the *component count* — annotation/structure, plus WALL and
#: ROOM which are measured by length/area (see :func:`_linear_area`), not counted as EA.
_NON_COUNTABLE: frozenset[EntityType] = frozenset(
    {
        EntityType.TEXT,
        EntityType.DIMENSION,
        EntityType.LINE,
        EntityType.POLYLINE,
        EntityType.POLYGON,
        EntityType.SEGMENT,
        EntityType.GRAPH_NODE,
        EntityType.TABLE_CELL,
        EntityType.CALLOUT,
        EntityType.TITLE_BLOCK_FIELD,
        EntityType.LEGEND_ENTRY,
        EntityType.OTHER,
        EntityType.WALL,
        EntityType.ROOM,
    }
)
DEFAULT_UNIT = "EA"


@dataclass(frozen=True)
class Evidence:
    """A link from a counted item back to its exact source (the audit trail)."""

    sheet_number: str
    entity_id: str
    confidence: float
    bbox: tuple[float, float, float, float] | None  # normalized (x_min,y_min,x_max,y_max)


@dataclass
class QuantityLine:
    """A linear (conduit/wire/wall) or area (room) quantity. Real units if a drawing scale
    is derivable, else normalized magnitudes flagged with ``scale_known=False``."""

    category: str
    kind: str  # "linear" | "area"
    unit: str  # real unit (e.g. "ft", "ft²") or "norm" / "norm²"
    count: int
    quantity: float
    scale_known: bool


@dataclass
class TakeoffLine:
    """One quantity line: a component type, its count, and its evidence + confidence."""

    discipline: str
    label: str
    unit: str
    count: int
    avg_confidence: float
    needs_review: int  # instances below the review threshold
    masterformat: str | None = None  # from L2 grounding (grounding.ontology), if grounded
    ifc_class: str | None = None
    evidence: list[Evidence] = field(default_factory=list)


@dataclass
class Takeoff:
    """A full quantity takeoff over a drawing set."""

    drawing_set: str
    lines: list[TakeoffLine]
    connections: dict[str, int]  # connection_type -> count (seed for length takeoff)
    by_sheet: dict[str, dict[str, int]]  # sheet_number -> {label: count}
    review_threshold: float
    linear: list[QuantityLine] = field(default_factory=list)  # conduit/wire/wall runs
    area: list[QuantityLine] = field(default_factory=list)  # room areas
    scale_known: bool = False  # was a drawing scale derivable for linear/area?

    @property
    def total_count(self) -> int:
        return sum(line.count for line in self.lines)

    @property
    def total_needs_review(self) -> int:
        return sum(line.needs_review for line in self.lines)

    def to_dict(self) -> dict:
        return {
            "drawing_set": self.drawing_set,
            "total_count": self.total_count,
            "total_needs_review": self.total_needs_review,
            "review_threshold": self.review_threshold,
            "lines": [
                {
                    "discipline": ln.discipline,
                    "item": ln.label,
                    "masterformat": ln.masterformat,
                    "ifc_class": ln.ifc_class,
                    "unit": ln.unit,
                    "qty": ln.count,
                    "avg_confidence": round(ln.avg_confidence, 4),
                    "needs_review": ln.needs_review,
                }
                for ln in self.lines
            ],
            "connections": self.connections,
            "scale_known": self.scale_known,
            "linear": [
                {"category": q.category, "count": q.count, "quantity": q.quantity, "unit": q.unit}
                for q in self.linear
            ],
            "area": [
                {"category": q.category, "count": q.count, "quantity": q.quantity, "unit": q.unit}
                for q in self.area
            ],
        }

    def to_csv(self) -> str:
        buf = io.StringIO()
        w = csv.writer(buf)
        w.writerow(
            [
                "discipline",
                "item",
                "masterformat",
                "ifc_class",
                "qty",
                "unit",
                "avg_confidence",
                "needs_review",
            ]
        )
        for ln in self.lines:
            w.writerow(
                [
                    ln.discipline,
                    ln.label,
                    ln.masterformat or "",
                    ln.ifc_class or "",
                    ln.count,
                    ln.unit,
                    f"{ln.avg_confidence:.4f}",
                    ln.needs_review,
                ]
            )
        return buf.getvalue()

    def to_markdown(self) -> str:
        out = [f"# Quantity takeoff — {self.drawing_set}", ""]
        by_disc: dict[str, list[TakeoffLine]] = defaultdict(list)
        for ln in self.lines:
            by_disc[ln.discipline].append(ln)
        for disc in sorted(by_disc):
            out.append(f"## {disc}")
            out.append("| Item | MasterFormat | Qty | Unit | Avg conf | ⚠ review |")
            out.append("|---|---|---:|:--:|---:|---:|")
            for ln in sorted(by_disc[disc], key=lambda x: (-x.count, x.label)):
                flag = str(ln.needs_review) if ln.needs_review else "—"
                code = ln.masterformat or "—"
                out.append(
                    f"| {ln.label} | {code} | {ln.count} | {ln.unit} "
                    f"| {ln.avg_confidence:.0%} | {flag} |"
                )
            out.append("")
        if self.linear:
            note = "" if self.scale_known else " _(scale unknown — normalized magnitudes)_"
            out.append(f"## Linear — conduit / wire / wall{note}")
            out.append("| Run | Count | Length | Unit |")
            out.append("|---|---:|---:|:--:|")
            for q in self.linear:
                out.append(f"| {q.category} | {q.count} | {q.quantity:g} | {q.unit} |")
            out.append("")
        if self.area:
            note = "" if self.scale_known else " _(scale unknown — normalized²)_"
            out.append(f"## Area — rooms{note}")
            out.append("| Space | Count | Area | Unit |")
            out.append("|---|---:|---:|:--:|")
            for q in self.area:
                out.append(f"| {q.category} | {q.count} | {q.quantity:g} | {q.unit} |")
            out.append("")
        out.append(
            f"**Total: {self.total_count} components** "
            f"({self.total_needs_review} flagged for review at <{self.review_threshold:.0%} conf)"
        )
        return "\n".join(out)


def _scale_factors(ds: DrawingSet) -> tuple[float, float, str] | None:
    """(length_factor, area_factor, unit) converting normalized→real, or None if no scale.

    Uses the first sheet carrying both a physical page size and a scale ratio, and assumes
    that scale applies set-wide (drawing sets usually share a scale). ``ratio`` = real units
    per drawing-sheet unit (e.g. 48 for 1/4"=1'-0"). Normalized coords span [0,1] over the
    page, so real length ≈ norm × (page_width × ratio) and area ≈ norm × (w·h · ratio²).
    """
    for sheet in ds.sheets:
        sz, sc = sheet.size, sheet.scale
        if sz and sc and sc.ratio:
            unit = sc.real_world_unit or sz.unit or "unit"
            return sz.width * sc.ratio, sz.width * sz.height * sc.ratio * sc.ratio, unit
    return None


def _poly_norm_area(geom: object, bnd: object) -> float:
    """Normalized polygon area via the shoelace formula; bbox area if not a polygon.

    A room is rarely a rectangle, so its true (shoelace) area is what a takeoff needs — the
    bounding box would over-count. Falls back to the bbox area when there is no polygon path.
    """
    pts = [(p.x, p.y) for p in getattr(geom, "points", []) or []]
    if len(pts) >= 3:
        a = 0.0
        for i in range(len(pts)):
            x1, y1 = pts[i]
            x2, y2 = pts[(i + 1) % len(pts)]
            a += x1 * y2 - x2 * y1
        return abs(a) / 2
    return float(bnd.area)  # type: ignore[attr-defined]


def _centers(ds: DrawingSet) -> dict[str, tuple[float, float]]:
    """Entity id → normalized center, for connection endpoints."""
    out: dict[str, tuple[float, float]] = {}
    for sheet in ds.sheets:
        for view in sheet.views:
            for e in view.entities:
                if e.geometry is None:
                    continue
                b = e.geometry.bounds()
                if b is not None:
                    out[e.id] = (b.center.x, b.center.y)
    return out


def _linear_area(
    ds: DrawingSet, scale: tuple[float, float, str] | None
) -> tuple[list[QuantityLine], list[QuantityLine]]:
    import math

    lf = scale[0] if scale else 1.0
    af = scale[1] if scale else 1.0
    known = scale is not None
    lu = scale[2] if scale else "norm"
    au = f"{scale[2]}²" if scale else "norm²"

    centers = _centers(ds)
    run_len: dict[str, float] = defaultdict(float)
    run_n: dict[str, int] = defaultdict(int)
    wall_len = 0.0
    wall_n = 0
    room_area: dict[str, float] = defaultdict(float)
    room_n: dict[str, int] = defaultdict(int)

    for sheet in ds.sheets:
        for view in sheet.views:
            for c in view.connections:
                a, b = centers.get(c.source_id), centers.get(c.target_id)
                if a is None or b is None:
                    continue
                t = c.connection_type or "unspecified"
                run_len[t] += math.hypot(b[0] - a[0], b[1] - a[1]) * lf
                run_n[t] += 1
            for e in view.entities:
                if e.geometry is None or e.label is None:
                    continue
                bnd = e.geometry.bounds()
                if bnd is None:
                    continue
                if e.entity_type == EntityType.WALL:
                    wall_len += max(bnd.width, bnd.height) * lf
                    wall_n += 1
                elif e.entity_type == EntityType.ROOM:
                    room_area[e.label] += _poly_norm_area(e.geometry, bnd) * af
                    room_n[e.label] += 1

    linear = [
        QuantityLine(t, "linear", lu, run_n[t], round(run_len[t], 2), known)
        for t in sorted(run_len)
    ]
    if wall_n:
        linear.append(QuantityLine("Wall", "linear", lu, wall_n, round(wall_len, 2), known))
    area = [
        QuantityLine(lab, "area", au, room_n[lab], round(room_area[lab], 2), known)
        for lab in sorted(room_area)
    ]
    return linear, area


def compute_takeoff(
    ds: DrawingSet, *, min_confidence: float = 0.0, review_threshold: float = 0.5
) -> Takeoff:
    """Aggregate the countable components of ``ds`` into a :class:`Takeoff`.

    ``min_confidence`` drops instances below it entirely (noise floor); instances kept but
    below ``review_threshold`` are counted **and** flagged in ``needs_review``.
    """
    groups: dict[tuple[str, str], list[Evidence]] = defaultdict(list)
    codes: dict[tuple[str, str], tuple[str | None, str | None]] = {}
    by_sheet: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    connections: dict[str, int] = defaultdict(int)

    for sheet in ds.sheets:
        disc = sheet.discipline.value if sheet.discipline else "unknown"
        for view in sheet.views:
            for e in view.entities:
                if e.entity_type in _NON_COUNTABLE or e.label is None:
                    continue
                if e.confidence < min_confidence:
                    continue
                bounds = e.geometry.bounds() if e.geometry else None
                bbox = (
                    (bounds.x_min, bounds.y_min, bounds.x_max, bounds.y_max)
                    if bounds is not None
                    else None
                )
                key = (disc, e.label)
                groups[key].append(Evidence(sheet.sheet_number, e.id, e.confidence, bbox))
                if key not in codes and (e.ontology.masterformat or e.ifc_class):
                    codes[key] = (e.ontology.masterformat, e.ifc_class)
                by_sheet[sheet.sheet_number][e.label] += 1
            for c in view.connections:
                connections[c.connection_type or "unspecified"] += 1

    lines: list[TakeoffLine] = []
    for (disc, label), evs in groups.items():
        confs = [ev.confidence for ev in evs]
        mf, ifc = codes.get((disc, label), (None, None))
        lines.append(
            TakeoffLine(
                discipline=disc,
                label=label,
                unit=DEFAULT_UNIT,
                count=len(evs),
                avg_confidence=sum(confs) / len(confs),
                needs_review=sum(1 for c in confs if c < review_threshold),
                masterformat=mf,
                ifc_class=ifc,
                evidence=evs,
            )
        )
    lines.sort(key=lambda ln: (ln.discipline, -ln.count, ln.label))
    scale = _scale_factors(ds)
    linear, area = _linear_area(ds, scale)
    return Takeoff(
        drawing_set=ds.name or "(unnamed drawing set)",
        lines=lines,
        connections=dict(connections),
        by_sheet={s: dict(d) for s, d in by_sheet.items()},
        review_threshold=review_threshold,
        linear=linear,
        area=area,
        scale_known=scale is not None,
    )


def main(argv: list[str] | None = None) -> int:  # pragma: no cover - thin CLI
    import argparse

    import cir

    p = argparse.ArgumentParser(prog="python -m engines.takeoff", description=__doc__)
    p.add_argument("--cir", required=True, help="path to a CIR DrawingSet (.cir)")
    p.add_argument("--min-confidence", type=float, default=0.0)
    p.add_argument("--review-threshold", type=float, default=0.5)
    p.add_argument("--format", choices=["md", "csv", "json"], default="md")
    ns = p.parse_args(argv)
    ds = cir.load(DrawingSet, ns.cir)
    t = compute_takeoff(ds, min_confidence=ns.min_confidence, review_threshold=ns.review_threshold)
    if ns.format == "md":
        print(t.to_markdown())
    elif ns.format == "csv":
        print(t.to_csv())
    else:
        import json

        print(json.dumps(t.to_dict(), indent=2))
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
