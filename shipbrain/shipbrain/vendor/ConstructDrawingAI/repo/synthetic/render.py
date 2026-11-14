"""The renderer — **the one auditable place** where a model fact becomes a glyph
*and* its CIR ground-truth record, together, in the same loop.

This is the single most safety-critical module in the engine. The governing invariant
is that the ground truth must be *exactly* what was drawn, and the way we guarantee it
is structural: there is no separate "labeling" pass that could drift from the drawing
pass. For each element, the helper that draws the glyph also computes the bounding box
(from the placement math, never from pixels) and emits the matching
:class:`~cir.Entity`/:class:`~cir.Connection`. To change what is drawn you must change
the record in the same place, so they cannot disagree.

One sample renders to three faithful sheets from one :class:`~synthetic.model.ElectricalModel`:

* **plan** (``E-101``) — the device-level drawing: walls, room tags, the panel, every
  device symbol at its location, dimensions, and the connectivity graph (conductor runs
  daisy-chained per circuit + one home-run per circuit to the panel);
* **panel schedule** (``E-601``) — one row per circuit, derived from the circuit data;
* **single-line diagram** (``E-301``) — the panel feeding M circuit nodes.

The emitted :class:`~cir.DrawingSet` is the *clean, canonical* ground truth. Degradation
(:mod:`synthetic.degrade`) acts only on the rendered images and never sees this object.
"""

from __future__ import annotations

from dataclasses import dataclass
from itertools import pairwise

from PIL import Image

from cir import (
    Connection,
    DimensionString,
    Discipline,
    DrawingSet,
    Entity,
    EntityType,
    Geometry,
    OntologyCodes,
    PageSize,
    Sheet,
    SourceFile,
    TextSpan,
    TitleBlock,
    View,
    ViewType,
)

from .canvas import Canvas, gray
from .layout import PLAN_REGION, sheet_number, sheet_title
from .model import (
    CIRCUIT_NODE_LABEL,
    CIRCUIT_ROW_LABEL,
    CONDUCTOR,
    DEVICE_CATALOG,
    DIMENSION_LABEL,
    FEEDER,
    HOME_RUN,
    PANEL_CLASS,
    ROOM_TAG_LABEL,
    SWITCH_LEG,
    WALL_LABEL,
    Circuit,
    Device,
    Dimension,
    ElectricalModel,
    Panel,
)
from .provenance import ENGINE_VERSION, stamp
from .style import StyleParams
from .symbols import draw_symbol

_PRODUCER = "synthetic-engine"


@dataclass
class RenderedSample:
    """The output of rendering one model: clean images (by sheet role) + the CIR."""

    model: ElectricalModel
    ground_truth: DrawingSet
    images: dict[str, Image.Image]  # role ("plan"|"schedule"|"single_line") -> clean image
    svgs: dict[str, str]


def render(model: ElectricalModel, style: StyleParams) -> RenderedSample:
    """Render ``model`` to images + a CIR :class:`~cir.DrawingSet` (clean, canonical)."""
    model.assert_consistent()
    plan_sheet, plan_img, plan_svg = _render_plan(model, style)
    sched_sheet, sched_img, sched_svg = _render_schedule(model, style)
    sl_sheet, sl_img, sl_svg = _render_single_line(model, style)
    ds = DrawingSet(
        id=model.id,
        name=model.project_name,
        project_name=model.project_name,
        source=SourceFile(
            filename=f"{model.id}.synthetic",
            file_type="synthetic",
            is_vector=True,
            ingest_tool="synthetic-engine",
        ),
        sheets=[plan_sheet, sched_sheet, sl_sheet],
        metadata={
            "synthetic": True,
            "engine_version": ENGINE_VERSION,
            "style": style.model_dump(),
        },
        **stamp(),
    )
    return RenderedSample(
        model=model,
        ground_truth=ds,
        images={"plan": plan_img, "schedule": sched_img, "single_line": sl_img},
        svgs={"plan": plan_svg, "schedule": sched_svg, "single_line": sl_svg},
    )


# ---------------------------------------------------------------------------
# Shared drawing helpers
# ---------------------------------------------------------------------------
def _canvas(style: StyleParams) -> Canvas:
    return Canvas(
        width=style.sheet_w_px,
        height=style.sheet_h_px,
        background=gray(style.paper),
        supersample=style.supersample,
    )


def _centroid(polygon: list[tuple[float, float]]) -> tuple[float, float]:
    xs = [p[0] for p in polygon]
    ys = [p[1] for p in polygon]
    return (sum(xs) / len(xs), sum(ys) / len(ys))


def _fit_size(text: str, max_width: float, base: float) -> float:
    """Shrink a text cap-height so ``text`` approximately fits ``max_width`` (normalized).

    Keeps long project names (incl. arbitrary IFC names) from clipping the title block,
    rather than hard-truncating. Uses a conservative width-per-cap-height estimate for the
    default font and floors at half the base size so it never becomes unreadable.
    """
    estimated = 0.55 * base * max(1, len(text))
    if estimated <= max_width:
        return base
    return max(0.5 * base, base * max_width / estimated)


def _draw_frame(cv: Canvas, style: StyleParams, *, role: str, model: ElectricalModel) -> TitleBlock:
    """Draw the sheet border + title block; return the CIR :class:`TitleBlock`.

    The title block is decoration *and* ground truth (it populates ``Sheet.title_block``),
    but it is not an entity — so it does not enter the per-class counts the validator pins.
    """
    ink = gray(style.ink)
    number = sheet_number(model.sheet_prefix, role)
    title = sheet_title(role)
    # outer border
    cv.rect(0.012, 0.012, 0.988, 0.988, weight=style.heavy_weight, color=ink)
    cv.rect(0.02, 0.02, 0.98, 0.98, weight=style.line_weight, color=ink)
    fs = 0.012 * style.font_scale
    if style.title_block == "right":
        bx0 = 0.755
        cv.rect(bx0, 0.02, 0.98, 0.98, weight=style.line_weight, color=ink)
        tx = (bx0 + 0.98) / 2
        block_w = 0.98 - bx0 - 0.02  # usable width inside the right title block
        cv.text(
            tx, 0.10, model.project_name, size=_fit_size(model.project_name, block_w, fs), color=ink
        )
        cv.text(tx, 0.16, title, size=_fit_size(title, block_w, fs), color=ink)
        cv.text(tx, 0.88, number, size=fs * 1.5, color=ink)
        cv.text(tx, 0.93, "SYNTHETIC - NOT FOR CONSTRUCTION", size=fs * 0.6, color=ink)
    else:  # bottom
        by0 = 0.86
        cv.rect(0.02, by0, 0.98, 0.98, weight=style.line_weight, color=ink)
        label = f"{model.project_name} - {title}"
        cv.text(0.5, by0 + 0.03, label, size=_fit_size(label, 0.94, fs), color=ink)
        cv.text(0.85, by0 + 0.08, number, size=fs * 1.5, color=ink)
        cv.text(0.3, by0 + 0.10, "SYNTHETIC - NOT FOR CONSTRUCTION", size=fs * 0.6, color=ink)
    return TitleBlock(
        project_name=model.project_name,
        sheet_number=number,
        sheet_title=title,
        discipline=Discipline.ELECTRICAL,
    )


def _sheet(
    model: ElectricalModel, role: str, style: StyleParams, tb: TitleBlock, view: View
) -> Sheet:
    return Sheet(
        id=f"{model.id}-{role}",
        sheet_number=sheet_number(model.sheet_prefix, role),
        discipline=Discipline.ELECTRICAL,
        title=sheet_title(role),
        size=PageSize(width=float(style.sheet_w_px), height=float(style.sheet_h_px), unit="px"),
        title_block=tb,
        views=[view],
    )


def _device_entity_and_glyph(
    cv: Canvas, model: ElectricalModel, dev: Device, style: StyleParams
) -> Entity:
    """Draw one device's glyph AND build its CIR entity — the atomic auditable unit."""
    spec = DEVICE_CATALOG[dev.kind]
    s = spec.nominal_size * style.symbol_scale
    draw_symbol(
        cv,
        dev.kind,
        dev.x,
        dev.y,
        s,
        variant=style.variant_for(dev.kind),
        weight=style.line_weight,
        color=gray(style.ink),
    )
    return Entity(
        id=dev.id,
        entity_type=spec.entity_type,
        label=spec.label,
        ifc_class=spec.ifc_class,
        geometry=Geometry.box(dev.x - s / 2, dev.y - s / 2, dev.x + s / 2, dev.y + s / 2),
        ontology=OntologyCodes(masterformat=spec.masterformat),
        confidence=1.0,
        produced_by=_PRODUCER,
        model_version=ENGINE_VERSION,
        attributes={"kind": dev.kind.value, "circuit": dev.circuit_id},
        **stamp(),
    )


def _draw_panel(cv: Canvas, panel: Panel, size: float, style: StyleParams) -> Entity:
    """Draw the panelboard glyph AND build its CIR entity."""
    ink = gray(style.ink)
    h = size / 2
    cv.rect(
        panel.x - h, panel.y - h, panel.x + h, panel.y + h, weight=style.heavy_weight, color=ink
    )
    # hatch the panel box so it reads as equipment
    cv.line(panel.x - h, panel.y - h, panel.x + h, panel.y + h, weight=style.line_weight, color=ink)
    cv.text(
        panel.x,
        panel.y + h + 0.018 * style.font_scale,
        panel.name,
        size=0.012 * style.font_scale,
        color=ink,
    )
    return Entity(
        id=panel.id,
        entity_type=PANEL_CLASS.entity_type,
        label=PANEL_CLASS.label,
        ifc_class=PANEL_CLASS.ifc_class,
        geometry=Geometry.box(panel.x - h, panel.y - h, panel.x + h, panel.y + h),
        ontology=OntologyCodes(masterformat=PANEL_CLASS.masterformat),
        text_spans=[TextSpan(text=panel.name, confidence=1.0)],
        confidence=1.0,
        produced_by=_PRODUCER,
        model_version=ENGINE_VERSION,
        attributes={"voltage": panel.voltage, "phases": panel.phases},
        **stamp(),
    )


def _draw_home_run(
    cv: Canvas, sx: float, sy_: float, panel: Panel, circuit: Circuit, style: StyleParams
) -> None:
    """Draw a circuit's home-run line to the panel with its circuit number."""
    ink = gray(style.ink)
    cv.line(sx, sy_, panel.x, panel.y, weight=style.line_weight, color=ink)
    mx, my = (sx + panel.x) / 2, (sy_ + panel.y) / 2
    cv.text(mx, my - 0.012, str(circuit.number), size=0.011 * style.font_scale, color=ink)


def _draw_dimension(cv: Canvas, dim: Dimension, style: StyleParams) -> None:
    ink = gray(style.ink)
    (x0, y0), (x1, y1) = dim.p0, dim.p1
    cv.line(x0, y0, x1, y1, weight=style.line_weight, color=ink)
    t = 0.008
    cv.line(x0, y0 - t, x0, y0 + t, weight=style.line_weight, color=ink)
    cv.line(x1, y1 - t, x1, y1 + t, weight=style.line_weight, color=ink)
    cv.text((x0 + x1) / 2, (y0 + y1) / 2 - 0.013, dim.raw, size=0.011 * style.font_scale, color=ink)


# ---------------------------------------------------------------------------
# Sheet renderers (each draws + emits; the auditable mapping lives here)
# ---------------------------------------------------------------------------
def _render_plan(model: ElectricalModel, style: StyleParams) -> tuple[Sheet, Image.Image, str]:
    cv = _canvas(style)
    ink = gray(style.ink)
    tb = _draw_frame(cv, style, role="plan", model=model)
    entities: list[Entity] = []
    connections: list[Connection] = []

    for wall in model.walls:
        cv.polygon(wall.polygon, weight=style.heavy_weight, color=ink)
        entities.append(
            Entity(
                id=wall.id,
                entity_type=EntityType.WALL,
                label=WALL_LABEL,
                geometry=Geometry.polygon(wall.polygon),
                confidence=1.0,
                produced_by=_PRODUCER,
                model_version=ENGINE_VERSION,
                **stamp(),
            )
        )

    for room in model.rooms:
        cx, _cy = _centroid(room.polygon)
        ty = min(p[1] for p in room.polygon) + 0.02  # near the top edge, clear of devices
        cv.text(cx, ty, room.name, size=0.013 * style.font_scale, color=ink)
        entities.append(
            Entity(
                id=room.id,
                entity_type=EntityType.TEXT,
                label=ROOM_TAG_LABEL,
                geometry=Geometry.point(cx, ty),
                text_spans=[TextSpan(text=room.name, confidence=1.0)],
                confidence=1.0,
                produced_by=_PRODUCER,
                model_version=ENGINE_VERSION,
                **stamp(),
            )
        )

    entities.append(
        _draw_panel(cv, model.panel, PANEL_CLASS.nominal_size * style.symbol_scale, style)
    )

    for dev in model.devices:
        entities.append(_device_entity_and_glyph(cv, model, dev, style))

    for circuit in model.circuits:
        devs = model.devices_on(circuit)
        for a, b in pairwise(devs):
            cv.line(a.x, a.y, b.x, b.y, weight=style.line_weight, color=ink)
            connections.append(
                Connection(
                    source_id=a.id,
                    target_id=b.id,
                    connection_type=CONDUCTOR,
                    confidence=1.0,
                    attributes={"circuit": circuit.number},
                )
            )
        if devs:
            last = devs[-1]
            _draw_home_run(cv, last.x, last.y, model.panel, circuit, style)
            connections.append(
                Connection(
                    source_id=last.id,
                    target_id=model.panel.id,
                    connection_type=HOME_RUN,
                    confidence=1.0,
                    attributes={"circuit": circuit.number},
                )
            )

    # switch legs: control wiring from a switch to the luminaire(s) it controls
    for dev in model.devices:
        for controlled in dev.controls:
            target = model.device(controlled)
            cv.line(dev.x, dev.y, target.x, target.y, weight=style.line_weight, color=ink)
            connections.append(
                Connection(
                    source_id=dev.id,
                    target_id=target.id,
                    connection_type=SWITCH_LEG,
                    confidence=1.0,
                )
            )

    for dim in model.dimensions:
        _draw_dimension(cv, dim, style)
        entities.append(
            Entity(
                id=dim.id,
                entity_type=EntityType.DIMENSION,
                label=DIMENSION_LABEL,
                geometry=Geometry.polyline([dim.p0, dim.p1]),
                dimensions=[
                    DimensionString(
                        raw=dim.raw,
                        value_mm=dim.value_mm,
                        unit="ft-in" if "'" in dim.raw else "mm",
                    )
                ],
                confidence=1.0,
                produced_by=_PRODUCER,
                model_version=ENGINE_VERSION,
                **stamp(),
            )
        )

    view = View(
        id=f"{model.id}-plan-v",
        name=sheet_title("plan"),
        view_type=ViewType.PLAN,
        entities=entities,
        connections=connections,
    )
    sheet = _sheet(model, "plan", style, tb, view)
    return sheet, cv.to_image(), cv.to_svg()


def _render_schedule(model: ElectricalModel, style: StyleParams) -> tuple[Sheet, Image.Image, str]:
    cv = _canvas(style)
    ink = gray(style.ink)
    tb = _draw_frame(cv, style, role="schedule", model=model)
    entities: list[Entity] = []

    x0, y0, x1, _y1 = PLAN_REGION
    table_right = x1
    fs = 0.011 * style.font_scale
    cv.text(
        (x0 + x1) / 2,
        y0,
        f"PANEL {model.panel.name} - {model.panel.voltage}",
        size=fs * 1.3,
        color=ink,
    )

    circuits = sorted(model.circuits, key=lambda c: c.number)
    header_y = y0 + 0.05
    row_h = min(0.034, (0.78 - header_y) / max(1, len(circuits) + 2))
    col_ckt = x0 + 0.008
    col_ph = x0 + 0.045
    col_desc = x0 + 0.085
    col_load = table_right - 0.205
    col_bkr = table_right - 0.105
    col_p = table_right - 0.03
    columns = (
        ("CKT", col_ckt),
        ("PH", col_ph),
        ("DESCRIPTION", col_desc),
        ("LOAD (VA)", col_load),
        ("BKR", col_bkr),
        ("P", col_p),
    )
    for label, cx in columns:
        cv.text(cx, header_y, label, size=fs, color=ink, anchor="lm")
    cv.line(
        x0,
        header_y + row_h / 2,
        table_right,
        header_y + row_h / 2,
        weight=style.line_weight,
        color=ink,
    )

    total_va = 0
    for i, circuit in enumerate(circuits):
        ry = header_y + row_h * (i + 1)
        load = model.circuit_load_va(circuit)  # reconciles against the devices on the plan
        total_va += load
        cv.rect(
            x0, ry - row_h / 2, table_right, ry + row_h / 2, weight=style.line_weight, color=ink
        )
        cv.text(col_ckt, ry, str(circuit.number), size=fs, color=ink, anchor="lm")
        cv.text(col_ph, ry, circuit.phase, size=fs, color=ink, anchor="lm")
        cv.text(col_desc, ry, circuit.description[:30], size=fs, color=ink, anchor="lm")
        cv.text(col_load, ry, str(load), size=fs, color=ink, anchor="lm")
        cv.text(col_bkr, ry, f"{circuit.breaker_amps}A", size=fs, color=ink, anchor="lm")
        cv.text(col_p, ry, str(circuit.poles), size=fs, color=ink, anchor="lm")
        entities.append(
            Entity(
                id=f"{circuit.id}-row",
                entity_type=EntityType.TABLE_CELL,
                label=CIRCUIT_ROW_LABEL,
                geometry=Geometry.box(x0, ry - row_h / 2, table_right, ry + row_h / 2),
                text_spans=[
                    TextSpan(text=str(circuit.number), confidence=1.0),
                    TextSpan(text=circuit.phase, confidence=1.0),
                    TextSpan(text=circuit.description, confidence=1.0),
                    TextSpan(text=f"{load} VA", confidence=1.0),
                    TextSpan(text=f"{circuit.breaker_amps}A", confidence=1.0),
                ],
                confidence=1.0,
                produced_by=_PRODUCER,
                model_version=ENGINE_VERSION,
                attributes={
                    "circuit_number": circuit.number,
                    "phase": circuit.phase,
                    "load_va": load,
                },
                **stamp(),
            )
        )

    # total connected load — reconciles the schedule against the plan (decoration, not an entity)
    total_y = header_y + row_h * (len(circuits) + 1)
    cv.text(col_desc, total_y, "TOTAL CONNECTED LOAD", size=fs, color=ink, anchor="lm")
    cv.text(col_load, total_y, f"{total_va} VA", size=fs, color=ink, anchor="lm")

    view = View(
        id=f"{model.id}-schedule-v",
        name=sheet_title("schedule"),
        view_type=ViewType.SCHEDULE,
        entities=entities,
    )
    sheet = _sheet(model, "schedule", style, tb, view)
    return sheet, cv.to_image(), cv.to_svg()


def _render_single_line(
    model: ElectricalModel, style: StyleParams
) -> tuple[Sheet, Image.Image, str]:
    cv = _canvas(style)
    ink = gray(style.ink)
    tb = _draw_frame(cv, style, role="single_line", model=model)
    entities: list[Entity] = []
    connections: list[Connection] = []

    x0, y0, _x1, y1 = PLAN_REGION
    bus_x = x0 + 0.08
    bus_y0, bus_y1 = y0 + 0.10, y1 - 0.06
    cv.line(bus_x, bus_y0, bus_x, bus_y1, weight=style.heavy_weight, color=ink)

    panel_node_id = f"{model.panel.id}-sl"
    ph = 0.02
    cv.rect(
        bus_x - ph, bus_y0 - 0.06, bus_x + ph, bus_y0 - 0.02, weight=style.heavy_weight, color=ink
    )
    cv.text(bus_x, bus_y0 - 0.08, model.panel.name, size=0.013 * style.font_scale, color=ink)
    entities.append(
        Entity(
            id=panel_node_id,
            entity_type=EntityType.EQUIPMENT,
            label=PANEL_CLASS.label,
            ifc_class=PANEL_CLASS.ifc_class,
            geometry=Geometry.box(bus_x - ph, bus_y0 - 0.06, bus_x + ph, bus_y0 - 0.02),
            ontology=OntologyCodes(masterformat=PANEL_CLASS.masterformat),
            text_spans=[TextSpan(text=model.panel.name, confidence=1.0)],
            confidence=1.0,
            produced_by=_PRODUCER,
            model_version=ENGINE_VERSION,
            **stamp(),
        )
    )

    circuits = sorted(model.circuits, key=lambda c: c.number)
    node_x = bus_x + 0.16
    fs = 0.011 * style.font_scale
    for i, circuit in enumerate(circuits):
        cy = bus_y0 + (i + 0.5) * (bus_y1 - bus_y0) / max(1, len(circuits))
        cv.line(bus_x, cy, node_x - 0.02, cy, weight=style.line_weight, color=ink)
        cv.circle(bus_x, cy, 0.006, weight=style.line_weight, color=ink, fill=ink)  # breaker tap
        cv.rect(
            node_x - 0.02,
            cy - 0.013,
            node_x + 0.30,
            cy + 0.013,
            weight=style.line_weight,
            color=ink,
        )
        cv.text(
            node_x - 0.005,
            cy,
            f"CKT {circuit.number}: {circuit.description[:28]}",
            size=fs,
            color=ink,
            anchor="lm",
        )
        node_id = f"{circuit.id}-sl"
        entities.append(
            Entity(
                id=node_id,
                entity_type=EntityType.GRAPH_NODE,
                label=CIRCUIT_NODE_LABEL,
                geometry=Geometry.box(node_x - 0.02, cy - 0.013, node_x + 0.30, cy + 0.013),
                text_spans=[TextSpan(text=f"CKT {circuit.number}", confidence=1.0)],
                confidence=1.0,
                produced_by=_PRODUCER,
                model_version=ENGINE_VERSION,
                attributes={"circuit_number": circuit.number},
                **stamp(),
            )
        )
        connections.append(
            Connection(
                source_id=panel_node_id,
                target_id=node_id,
                connection_type=FEEDER,
                confidence=1.0,
                attributes={"circuit": circuit.number},
            )
        )

    view = View(
        id=f"{model.id}-single_line-v",
        name=sheet_title("single_line"),
        view_type=ViewType.DIAGRAM,
        entities=entities,
        connections=connections,
    )
    sheet = _sheet(model, "single_line", style, tb, view)
    return sheet, cv.to_image(), cv.to_svg()
