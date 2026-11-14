"""Derive the ground-truth expectation straight from the canonical model.

This is the *independent* half of the correctness proof. The renderer
(:mod:`synthetic.render`) builds the CIR by drawing and emitting in one pass; this
module builds what the CIR *should* contain by plainly counting the model's own lists —
a different, much simpler computation. The validator (:func:`eval.validate_ground_truth`)
then checks the two agree. If a future change makes the renderer drop, duplicate, or
mis-class something, the counts here won't move with it, and the validator fails loudly.

It only shares the *label vocabulary* with the renderer (via :data:`DEVICE_CATALOG` and
the ``*_LABEL`` constants in :mod:`synthetic.model`) and the *sheet identity* (via
:mod:`synthetic.layout`) — never the emission logic.
"""

from __future__ import annotations

from collections import Counter

from eval.validate import ExpectedPlacement, GroundTruthExpectation, SheetExpectation

from .layout import sheet_number
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
    ElectricalModel,
)


def expected_ground_truth(model: ElectricalModel) -> GroundTruthExpectation:
    """The exact CIR contents ``model`` must render to, per sheet (no tolerance)."""
    prefix = model.sheet_prefix
    plan_no = sheet_number(prefix, "plan")
    sched_no = sheet_number(prefix, "schedule")
    sl_no = sheet_number(prefix, "single_line")
    m = len(model.circuits)

    # --- plan sheet: devices + panel + walls + room tags + dimensions ---
    plan_counts: Counter[str] = Counter()
    for kind, n in model.device_count_by_kind().items():
        plan_counts[DEVICE_CATALOG[kind].label] += n
    plan_counts[PANEL_CLASS.label] += 1
    if model.walls:
        plan_counts[WALL_LABEL] += len(model.walls)
    if model.rooms:
        plan_counts[ROOM_TAG_LABEL] += len(model.rooms)
    if model.dimensions:
        plan_counts[DIMENSION_LABEL] += len(model.dimensions)

    conductor = sum(max(0, len(c.device_ids) - 1) for c in model.circuits)
    home_run = sum(1 for c in model.circuits if c.device_ids)
    switch_leg = sum(len(d.controls) for d in model.devices)
    plan_edges: dict[str, int] = {}
    if conductor:
        plan_edges[CONDUCTOR] = conductor
    if home_run:
        plan_edges[HOME_RUN] = home_run
    if switch_leg:
        plan_edges[SWITCH_LEG] = switch_leg

    placements = [
        ExpectedPlacement(plan_no, DEVICE_CATALOG[d.kind].label, d.x, d.y) for d in model.devices
    ]
    placements.append(ExpectedPlacement(plan_no, PANEL_CLASS.label, model.panel.x, model.panel.y))

    # --- panel-schedule sheet: one row per circuit ---
    sched_counts = {CIRCUIT_ROW_LABEL: m} if m else {}

    # --- single-line sheet: the panel feeding M circuit nodes ---
    sl_counts = {PANEL_CLASS.label: 1}
    if m:
        sl_counts[CIRCUIT_NODE_LABEL] = m
    sl_edges = {FEEDER: m} if m else {}

    return GroundTruthExpectation(
        sample_id=model.id,
        sheets=[
            SheetExpectation(plan_no, dict(plan_counts), plan_edges),
            SheetExpectation(sched_no, sched_counts, {}),
            SheetExpectation(sl_no, sl_counts, sl_edges),
        ],
        placements=placements,
    )
