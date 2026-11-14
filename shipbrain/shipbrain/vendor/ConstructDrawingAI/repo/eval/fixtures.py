"""Synthetic ground-truth eval set + cited SOTA/frontier numbers for the demo.

Provides a small, fully-known eval matrix so the harness can be exercised end-to-end
without external data or APIs: a few MEP/electrical sheets (symbols, connectivity,
dimensions) across clean/degraded slices, architectural sheets with wall polygons, and
an RFI reasoning scenario.

The gap report has three real rows: the **oracle** (our upper bound, *measured* on
this synthetic ground truth), **published-SOTA** (specialist reference), and
**published-frontier** (the gap we are beating). The latter two are
:class:`~eval.adapters.ReportedNumbersAdapter` instances carrying **literature-cited**
values (AECV-Bench, AEC-Bench, FloorplanVLM, SkeySpot, P&ID SOTA) — no simulation, no
random seeds, no API calls.
"""

from __future__ import annotations

from typing import Any

from cir import (
    Connection,
    DataLane,
    DimensionString,
    Discipline,
    DrawingSet,
    Entity,
    EntityType,
    Geometry,
    LicenseProvenance,
    Sheet,
    View,
    ViewType,
)

from .adapters import ReportedNumber, ReportedNumbersAdapter
from .tasks import CLEAN, DEGRADED, RASTER, VECTOR, EvalSample, EvalTask, Slice

_PROV: dict[str, Any] = {
    "license_provenance": LicenseProvenance.SYNTHETIC_OWNED,
    "data_lane": DataLane.COMMERCIAL,
}


def _box(cx: float, cy: float, half: float = 0.018) -> Geometry:
    return Geometry.box(cx - half, cy - half, cx + half, cy + half)


def make_mep_sheet(idx: int, *, n_receptacles: int) -> DrawingSet:
    """A synthetic electrical power plan: a panel, receptacles (home-run to panel),
    switches, and a dimension."""
    panel = Entity(
        id=f"mep{idx}-panel",
        entity_type=EntityType.EQUIPMENT,
        label="Panelboard",
        geometry=_box(0.1, 0.1, 0.04),
        confidence=1.0,
        **_PROV,
    )
    entities = [panel]
    connections = []
    for i in range(n_receptacles):
        cx, cy = 0.2 + 0.07 * (i % 8), 0.3 + 0.09 * (i // 8)
        recept = Entity(
            id=f"mep{idx}-r{i}",
            entity_type=EntityType.SYMBOL,
            label="Duplex Receptacle",
            geometry=_box(cx, cy),
            confidence=1.0,
            **_PROV,
        )
        entities.append(recept)
        connections.append(
            Connection(
                source_id=recept.id, target_id=panel.id, connection_type="home_run", confidence=1.0
            )
        )
    for i in range(2):
        entities.append(
            Entity(
                id=f"mep{idx}-sw{i}",
                entity_type=EntityType.SYMBOL,
                label="Light Switch",
                geometry=_box(0.15 + 0.06 * i, 0.85),
                confidence=1.0,
                **_PROV,
            )
        )
    entities.append(
        Entity(
            id=f"mep{idx}-dim",
            entity_type=EntityType.DIMENSION,
            geometry=Geometry.polyline([(0.2, 0.93), (0.5, 0.93)]),
            dimensions=[DimensionString(raw="10'-0\"", value=10.0, unit="ft-in", value_mm=3048.0)],
            confidence=1.0,
            **_PROV,
        )
    )
    view = View(
        id=f"mep{idx}-v",
        name="Power Plan",
        view_type=ViewType.PLAN,
        entities=entities,
        connections=connections,
    )
    sheet = Sheet(
        id=f"mep{idx}-s",
        sheet_number=f"E-{100 + idx}",
        discipline=Discipline.ELECTRICAL,
        views=[view],
    )
    return DrawingSet(id=f"mep{idx}", name=f"MEP sheet {idx}", sheets=[sheet], **_PROV)


def make_arch_sheet(idx: int) -> DrawingSet:
    """A synthetic floor plan: two room/wall polygons and a few doors."""
    entities = [
        Entity(
            id=f"arch{idx}-w0",
            entity_type=EntityType.WALL,
            label="wall",
            geometry=Geometry.polygon([(0.1, 0.1), (0.5, 0.1), (0.5, 0.5), (0.1, 0.5)]),
            confidence=1.0,
            **_PROV,
        ),
        Entity(
            id=f"arch{idx}-w1",
            entity_type=EntityType.WALL,
            label="wall",
            geometry=Geometry.polygon([(0.5, 0.1), (0.9, 0.1), (0.9, 0.5), (0.5, 0.5)]),
            confidence=1.0,
            **_PROV,
        ),
    ]
    for i in range(3):
        entities.append(
            Entity(
                id=f"arch{idx}-d{i}",
                entity_type=EntityType.SYMBOL,
                label="Door",
                geometry=_box(0.2 + 0.2 * i, 0.5),
                confidence=1.0,
                **_PROV,
            )
        )
    view = View(id=f"arch{idx}-v", view_type=ViewType.PLAN, entities=entities)
    sheet = Sheet(
        id=f"arch{idx}-s",
        sheet_number=f"A-{100 + idx}",
        discipline=Discipline.ARCHITECTURAL,
        views=[view],
    )
    return DrawingSet(id=f"arch{idx}", name=f"Arch sheet {idx}", sheets=[sheet], **_PROV)


def make_reasoning_sheet(idx: int) -> DrawingSet:
    """A reasoning scenario: a drafted RFI (conflict + evidence + cited clause +
    question) stored in metadata, for the AEC-Bench-style reward."""
    return DrawingSet(
        id=f"rfi{idx}",
        name=f"RFI scenario {idx}",
        metadata={
            "rfi": {
                "conflict": "Panel 'LP-1' schedule lists 14 circuits; plan shows 12 home-runs.",
                "evidence": "crop:E-201@panel",
                "cited_clause": "NEC 408.4(A)",
                "question": "Please confirm the intended circuit count for panel LP-1.",
            }
        },
        **_PROV,
    )


def demo_tasks() -> list[EvalTask]:
    """The demo eval matrix: MEP perception + reasoning, and architectural structural."""
    mep_samples: list[EvalSample] = []
    for i, n in enumerate((12, 20, 8)):
        gt = make_mep_sheet(i, n_receptacles=n)
        mep_samples.append(
            EvalSample(f"mep-clean-{i}", gt, Slice("mep", RASTER, CLEAN, "synthetic"))
        )
        mep_samples.append(
            EvalSample(f"mep-degraded-{i}", gt, Slice("mep", RASTER, DEGRADED, "synthetic"))
        )
    mep_task = EvalTask(
        name="mep-perception",
        metrics=[
            "detection_map",
            "counting_mape",
            "counting_exact_match",
            "panoptic_quality",
            "graph_edge_ap",
        ],
        samples=mep_samples,
    )

    arch_samples = [
        EvalSample(
            f"arch-clean-{i}",
            make_arch_sheet(i),
            Slice("architectural", VECTOR, CLEAN, "synthetic"),
        )
        for i in range(3)
    ]
    arch_task = EvalTask(
        name="arch-structural",
        metrics=["external_wall_iou", "loop_closure_validity", "detection_map"],
        samples=arch_samples,
    )

    reasoning_samples = [
        EvalSample(f"rfi-{i}", make_reasoning_sheet(i), Slice("mep", RASTER, CLEAN, "synthetic"))
        for i in range(2)
    ]
    reasoning_task = EvalTask(
        name="mep-reasoning", metrics=["rfi_reward"], samples=reasoning_samples
    )
    return [mep_task, arch_task, reasoning_task]


def published_sota() -> ReportedNumbersAdapter:
    """Published specialist-SOTA measured on **real drawings** — the real board's bar to beat.

    Every value here is a real-drawing result, so it is the meaningful comparison for the
    real-drawing scoreboard (ADR-0011). The synthetic in-distribution ceiling and the
    synthetic-only-training bar are separate (:func:`published_sota_synthetic`,
    :func:`published_synthetic_only`), routed to the appropriate board by the scoreboard so
    a synthetic number is never compared against a real one.
    """
    return ReportedNumbersAdapter(
        "published-SOTA (real)",
        {
            ("detection_map", "mep"): ReportedNumber(
                0.825, "SkeySpot, arXiv 2508.10449 (real UK electrical)", "YOLOv8 specialist"
            ),
            ("graph_node_ap", "mep"): ReportedNumber(
                0.8363, "PID2Graph real OPEN100, arXiv 2411.13929", "Relationformer"
            ),
            ("graph_edge_ap", "mep"): ReportedNumber(
                0.7546, "PID2Graph real OPEN100, arXiv 2411.13929", "Relationformer"
            ),
            ("panoptic_quality", "mep"): ReportedNumber(
                0.889, "FloorPlanCAD (CADSpotting)", "panoptic-spotting specialist"
            ),
            ("panoptic_quality", "architectural"): ReportedNumber(
                0.862, "FloorPlanCAD, arXiv 2503.22346 (> SymPointV2 83.2)", "DPSS"
            ),
            ("external_wall_iou", "architectural"): ReportedNumber(
                0.9252, "FloorplanVLM, arXiv 2602.06507", "Qwen2.5-VL SFT+GRPO"
            ),
        },
    )


def published_sota_synthetic() -> ReportedNumbersAdapter:
    """Published SOTA measured on **synthetic** data — the in-distribution ceiling shown on
    the synthetic (smoke-test) board. Explicitly NOT a real-drawing claim (ADR-0011)."""
    return ReportedNumbersAdapter(
        "published-SOTA (synthetic)",
        {
            ("graph_edge_ap", "mep"): ReportedNumber(
                0.8895, "PID2Graph synthetic, arXiv 2411.13929", "Relationformer (in-distribution)"
            ),
        },
    )


def published_synthetic_only() -> ReportedNumbersAdapter:
    """Best **synthetic-only-trained** result on REAL data — the commercial-lane bar.

    SynthPID trains with zero real data and tests on real OPEN100 — exactly our
    commercial-lane story (synthetic engine → real deployment, ADR-0009). So on the real
    board it is the bar our synthetic-trained model must beat to justify the moat.
    """
    return ReportedNumbersAdapter(
        "SynthPID (synthetic-only -> real)",
        {
            ("graph_edge_ap", "mep"): ReportedNumber(
                0.638, "real OPEN100, no real training, arXiv 2604.16513", "SynthPID"
            ),
        },
    )


def published_frontier() -> ReportedNumbersAdapter:
    """Published **frontier-model** numbers (cited) — the gap we are beating.

    These are literature values from the public benchmarks (no API calls, no
    simulation): AECV-Bench (Jan 2026) for symbol counting and per-class door/window
    detection, and AEC-Bench (Mar 2026) for agentic reasoning rewards.
    """
    return ReportedNumbersAdapter(
        "published-frontier",
        {
            ("counting_exact_match", "mep"): ReportedNumber(
                0.51, "AECV-Bench, arXiv 2601.04819", "best frontier VLM (Gemini 3 / GPT-5.x)"
            ),
            ("counting_exact_match", "architectural"): ReportedNumber(
                0.51, "AECV-Bench, arXiv 2601.04819", "best frontier VLM (Gemini 3 / GPT-5.x)"
            ),
            ("counting_mape", "mep"): ReportedNumber(
                20.5, "AECV-Bench, arXiv 2601.04819 (range 16-25%)", "best frontier VLM"
            ),
            ("counting_mape", "architectural"): ReportedNumber(
                20.5, "AECV-Bench, arXiv 2601.04819 (range 16-25%)", "best frontier VLM"
            ),
            ("detection_map", "architectural"): ReportedNumber(
                0.24,
                "AECV-Bench, arXiv 2601.04819 (doors/windows per-class 0.09-0.39)",
                "frontier VLMs (all)",
            ),
            ("rfi_reward", "mep"): ReportedNumber(
                0.88,
                "AEC-Bench, arXiv 2603.29199 (agentic; submittal review 23.1%)",
                "frontier + tools",
            ),
        },
    )
