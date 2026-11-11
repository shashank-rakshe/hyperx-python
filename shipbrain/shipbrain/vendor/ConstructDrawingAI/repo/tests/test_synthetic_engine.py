"""Tests for the synthetic-data engine — the ground-truth-correctness invariant.

The engine's whole value rests on one promise: the CIR is *exactly* what was drawn. So
these tests place known elements, assert the exact CIR records and graph edges come back,
prove the validator catches corruption (it is not vacuous), and verify degradation cannot
touch the ground truth. They run with no GPU, no network, and no IFC files.
"""

from __future__ import annotations

import random

import pytest

from cir import LicenseProvenance
from eval.metrics import counting_exact_match, graph_edge_ap
from eval.validate import validate_ground_truth
from synthetic.degrade import MAX_LEVEL, degrade
from synthetic.expect import expected_ground_truth
from synthetic.model import (
    CONDUCTOR,
    HOME_RUN,
    SWITCH_LEG,
    Circuit,
    Device,
    DeviceKind,
    ElectricalModel,
    Panel,
    RoomType,
)
from synthetic.provenance import (
    SYNTHETIC_LANE,
    SYNTHETIC_LICENSE,
    SyntheticProvenanceError,
    assert_synthetic_owned,
)
from synthetic.qa import QAExternalEndpointError, local_model_qa, template_qa_pairs
from synthetic.render import render
from synthetic.scene import build_electrical_model
from synthetic.style import sample_style


def _controlled_model(
    n_receptacles: int, m_circuits: int, *, model_id: str = "ctl"
) -> ElectricalModel:
    """A model with *exactly* N duplex receptacles split across M circuits."""
    assert n_receptacles >= m_circuits >= 1
    panel = Panel(id=f"{model_id}-panel", name="LP-1", x=0.06, y=0.45)
    devices: list[Device] = []
    circuits: list[Circuit] = []
    base, extra = divmod(n_receptacles, m_circuits)
    idx = 0
    for c in range(m_circuits):
        size = base + (1 if c < extra else 0)
        cid = f"{model_id}-c{c + 1}"
        dids: list[str] = []
        for _ in range(size):
            dev = Device(
                id=f"{model_id}-d{idx}",
                kind=DeviceKind.DUPLEX_RECEPTACLE,
                x=0.10 + 0.018 * idx,
                y=0.5,
                circuit_id=cid,
            )
            devices.append(dev)
            dids.append(dev.id)
            idx += 1
        circuits.append(
            Circuit(
                id=cid, number=c + 1, panel_id=panel.id, device_ids=dids, description="Receptacles"
            )
        )
    return ElectricalModel(
        id=model_id,
        panel=panel,
        devices=devices,
        circuits=circuits,
        rooms=[],
        walls=[],
        dimensions=[],
    )


def _style():
    return sample_style(0)


# ---------------------------------------------------------------------------
# The headline invariant: "N receptacles on M circuits" -> exactly that.
# ---------------------------------------------------------------------------
def test_asked_n_receptacles_m_circuits_get_exactly_that() -> None:
    model = _controlled_model(n_receptacles=8, m_circuits=3)
    sample = render(model, _style())
    report = validate_ground_truth(expected_ground_truth(model), sample.ground_truth)
    assert report.ok, [f"{i.code}: {i.detail}" for i in report.issues]

    plan = sample.ground_truth.sheets[0].views[0]
    labels = [e.label for e in plan.entities]
    assert labels.count("Duplex Receptacle") == 8  # exactly N
    assert labels.count("Panelboard") == 1
    edge_types = [c.connection_type for c in plan.connections]
    assert edge_types.count(HOME_RUN) == 3  # exactly M home-runs (one per circuit)
    assert edge_types.count(CONDUCTOR) == 8 - 3  # N - M daisy-chain conductors

    # the other two sheets
    sched = sample.ground_truth.sheets[1].views[0]
    assert sum(1 for e in sched.entities if e.label == "Panel Circuit Row") == 3
    sl = sample.ground_truth.sheets[2].views[0]
    assert sum(1 for e in sl.entities if e.label == "Circuit") == 3


def test_device_bbox_centers_match_placement_exactly() -> None:
    model = _controlled_model(6, 2)
    sample = render(model, _style())
    by_id = {e.id: e for e in sample.ground_truth.sheets[0].views[0].entities}
    for dev in model.devices:
        center = by_id[dev.id].geometry.bounds().center
        assert center.x == pytest.approx(dev.x, abs=1e-9)
        assert center.y == pytest.approx(dev.y, abs=1e-9)


def test_ground_truth_is_well_formed_for_the_eval_metrics() -> None:
    # A perfect "prediction" (the GT itself) must score perfectly on the metrics that
    # will grade real models — proof the GT is internally consistent and scorable.
    model = _controlled_model(10, 4)
    gt = render(model, _style()).ground_truth
    assert counting_exact_match([gt], [gt]) == 1.0
    assert graph_edge_ap([gt], [gt]) == pytest.approx(1.0, abs=1e-9)


# ---------------------------------------------------------------------------
# The validator is not vacuous: it must catch each corruption.
# ---------------------------------------------------------------------------
def test_validator_catches_dropped_entity() -> None:
    model = _controlled_model(6, 2)
    sample = render(model, _style())
    exp = expected_ground_truth(model)
    bad = sample.ground_truth.model_copy(deep=True)
    bad.sheets[0].views[0].entities.pop()
    assert not validate_ground_truth(exp, bad).ok


def test_validator_catches_mislabeled_entity() -> None:
    model = _controlled_model(6, 2)
    sample = render(model, _style())
    exp = expected_ground_truth(model)
    bad = sample.ground_truth.model_copy(deep=True)
    for e in bad.sheets[0].views[0].entities:
        if e.label == "Duplex Receptacle":
            e.label = "Light Fixture"
            break
    assert not validate_ground_truth(exp, bad).ok


def test_validator_catches_moved_entity() -> None:
    model = _controlled_model(6, 2)
    sample = render(model, _style())
    exp = expected_ground_truth(model)
    bad = sample.ground_truth.model_copy(deep=True)
    moved = next(e for e in bad.sheets[0].views[0].entities if e.label == "Duplex Receptacle")
    moved.geometry.points[0].x += 0.2
    moved.geometry.points[1].x += 0.2
    report = validate_ground_truth(exp, bad)
    assert not report.ok
    assert any(i.code == "placement" for i in report.issues)


def test_validator_catches_dropped_edge() -> None:
    model = _controlled_model(6, 2)
    sample = render(model, _style())
    exp = expected_ground_truth(model)
    bad = sample.ground_truth.model_copy(deep=True)
    bad.sheets[0].views[0].connections.pop()
    assert not validate_ground_truth(exp, bad).ok


# ---------------------------------------------------------------------------
# Degradation may never alter the ground truth, and must not move pixels (v0).
# ---------------------------------------------------------------------------
def test_degradation_leaves_ground_truth_untouched() -> None:
    model = _controlled_model(8, 3)
    sample = render(model, _style())
    gt_before = sample.ground_truth.model_copy(deep=True)
    rng = random.Random(0)
    for img in sample.images.values():
        for level in range(MAX_LEVEL + 1):
            out, params = degrade(img, level, rng)
            assert out.size == img.size  # photometric: boxes stay aligned
            assert params.level == level
            assert not params.geometric
    assert sample.ground_truth == gt_before  # GT object is identical after all degradation


def test_degradation_is_deterministic_and_clean_at_level_zero() -> None:
    model = _controlled_model(5, 2)
    img = render(model, _style()).images["plan"]
    out_a, _ = degrade(img, 2, random.Random(7))
    out_b, _ = degrade(img, 2, random.Random(7))
    assert list(out_a.getdata()) == list(out_b.getdata())  # same seed -> identical
    _clean, params = degrade(img, 0, random.Random(7))
    assert params.level == 0 and not params.ops  # level 0 is the identity


# ---------------------------------------------------------------------------
# Provenance is airtight: synthetic output is always synthetic-owned / commercial.
# ---------------------------------------------------------------------------
def test_every_record_is_synthetic_owned_commercial() -> None:
    sample = render(build_electrical_model(seed=11), sample_style(11))
    ds = sample.ground_truth
    assert ds.license_provenance is SYNTHETIC_LICENSE and ds.data_lane is SYNTHETIC_LANE
    for e in ds.iter_entities():
        assert e.license_provenance is SYNTHETIC_LICENSE and e.data_lane is SYNTHETIC_LANE
    assert_synthetic_owned(ds)  # does not raise
    ds.assert_commercial_safe()  # the CIR's own guard agrees


def test_provenance_guard_rejects_non_synthetic_records() -> None:
    sample = render(_controlled_model(4, 2), _style())
    bad = sample.ground_truth.model_copy(deep=True)
    # PERMISSIVE is commercial-safe (so the CIR allows it) but is NOT synthetic-owned;
    # the engine's stricter guard must still reject it.
    bad.sheets[0].views[0].entities[0].license_provenance = LicenseProvenance.PERMISSIVE
    with pytest.raises(SyntheticProvenanceError):
        assert_synthetic_owned(bad)


# ---------------------------------------------------------------------------
# Scene + style are deterministic; rendered images are real.
# ---------------------------------------------------------------------------
def test_scene_is_deterministic() -> None:
    a = build_electrical_model(seed=5, model_id="x")
    b = build_electrical_model(seed=5, model_id="x")
    assert a.model_dump() == b.model_dump()


def test_rendered_images_are_nonblank_and_sized() -> None:
    style = sample_style(3)
    sample = render(build_electrical_model(seed=3), style)
    for img in sample.images.values():
        assert img.size == (style.sheet_w_px, style.sheet_h_px)
        lo, hi = img.convert("L").getextrema()
        assert lo < hi  # there is ink on the paper


def test_scene_models_validate_across_seeds() -> None:
    for seed in range(24):
        model = build_electrical_model(seed=seed)
        sample = render(model, sample_style(seed))
        report = validate_ground_truth(expected_ground_truth(model), sample.ground_truth)
        assert report.ok, (seed, [i.detail for i in report.issues])


# ---------------------------------------------------------------------------
# Real-world electrical conventions (scene v0.2) — the sim-to-real surface.
# ---------------------------------------------------------------------------
def _room_of(model: ElectricalModel, dev: Device):
    for room in model.rooms:
        xs = [p[0] for p in room.polygon]
        ys = [p[1] for p in room.polygon]
        if min(xs) <= dev.x <= max(xs) and min(ys) <= dev.y <= max(ys):
            return room
    return None


def test_panel_schedule_load_reconciles_against_the_plan() -> None:
    # Each circuit's recorded load must equal the sum of its devices' connected loads,
    # and every circuit must respect the 20 A branch-circuit VA budget.
    for seed in range(20):
        model = build_electrical_model(seed=seed)
        for circuit in model.circuits:
            assert circuit.load_va == model.circuit_load_va(circuit)
            assert circuit.load_va <= 1920


def test_circuits_are_phase_balanced() -> None:
    # A model with several circuits must spread them across phases (round-robin), not
    # dump everything on phase A.
    model = next(
        build_electrical_model(seed=s)
        for s in range(50)
        if len(build_electrical_model(seed=s).circuits) >= 3
    )
    assert len({c.phase for c in model.circuits}) >= 2


def test_gfci_only_in_wet_rooms() -> None:
    # GFCI receptacles are a code requirement in restrooms/break rooms — and should not
    # appear elsewhere. Find a seed that actually has a wet room.
    wet = {RoomType.RESTROOM, RoomType.BREAK_ROOM}
    model = next(
        build_electrical_model(seed=s)
        for s in range(80)
        if any(r.room_type in wet for r in build_electrical_model(seed=s).rooms)
    )
    gfci = [d for d in model.devices if d.kind is DeviceKind.GFCI_RECEPTACLE]
    assert gfci, "a model with a wet room should have GFCI receptacles"
    for d in gfci:
        room = _room_of(model, d)
        assert room is not None and room.room_type in wet


def test_switches_drive_switch_legs_not_power_circuits() -> None:
    # Switches are control devices: not on a power circuit, but wired to a luminaire via
    # a switch_leg edge — and the rendered edges match the model exactly.
    model = build_electrical_model(seed=7)
    switches = [
        d
        for d in model.devices
        if d.kind in (DeviceKind.SINGLE_POLE_SWITCH, DeviceKind.THREE_WAY_SWITCH)
    ]
    assert switches
    for sw in switches:
        assert sw.circuit_id is None  # control device, not on a power circuit
    sample = render(model, sample_style(7))
    plan = sample.ground_truth.sheets[0].views[0]
    drawn = sum(1 for c in plan.connections if c.connection_type == SWITCH_LEG)
    assert drawn == sum(len(d.controls) for d in model.devices)
    # and it still validates exactly (switch legs are accounted for in the expectation)
    assert validate_ground_truth(expected_ground_truth(model), sample.ground_truth).ok


# ---------------------------------------------------------------------------
# QA pairs are grounded; the local-model hook refuses external endpoints.
# ---------------------------------------------------------------------------
def test_template_qa_pairs_are_grounded_in_ground_truth() -> None:
    model = _controlled_model(8, 3)
    pairs = {p["q_id"]: p["answer"] for p in template_qa_pairs(model)}
    assert pairs[f"{model.id}-q-circuits"] == "3"
    assert pairs[f"{model.id}-q-receptacles"] == "8"
    assert pairs[f"{model.id}-q-homerun"] == "LP-1"


def test_qa_local_hook_refuses_external_endpoint() -> None:
    model = _controlled_model(4, 2)
    with pytest.raises(QAExternalEndpointError):
        local_model_qa(model, endpoint="https://api.openai.com/v1/chat/completions")


# ---------------------------------------------------------------------------
# IFC path: pure helpers are testable without IfcOpenShell installed.
# ---------------------------------------------------------------------------
def test_ifc_class_to_device_kind_mapping() -> None:
    from synthetic.ifc_source import _to_region, device_kind_for_ifc
    from synthetic.layout import PLAN_REGION

    assert device_kind_for_ifc("IfcOutlet") is DeviceKind.DUPLEX_RECEPTACLE
    assert device_kind_for_ifc("IfcLightFixture") is DeviceKind.LIGHT_FIXTURE
    assert device_kind_for_ifc("IfcOutletType") is DeviceKind.DUPLEX_RECEPTACLE  # prefix fallback
    assert device_kind_for_ifc("IfcWall") is None
    x, y = _to_region(0.5, 0.5)
    assert PLAN_REGION[0] <= x <= PLAN_REGION[2]
    assert PLAN_REGION[1] <= y <= PLAN_REGION[3]


def test_generate_pipeline_writes_and_revalidates(tmp_path) -> None:
    from synthetic.generate import GenerateConfig, generate
    from synthetic.validate import validate_run

    out = tmp_path / "pilot"
    cfg = GenerateConfig(
        drawing_type="electrical",
        count=3,
        degradation_min=0,
        degradation_max=3,
        out_dir=str(out),
        seed=0,
        style_seed=0,
        qa_pairs=True,
        write_svg=False,
    )
    result = generate(cfg)
    assert result.all_valid and len(result.samples) == 3
    s0 = out / "sample_00000"
    for f in ("plan.png", "plan.deg.png", "ground_truth.cir", "model.json", "graph.json"):
        assert (s0 / f).exists()
    assert (out / "manifest.json").exists()
    # independent re-validation from disk (re-derives expectation from model.json)
    assert validate_run(out).all_valid


def test_non_electrical_type_is_rejected_in_v0() -> None:
    from synthetic.generate import GenerateConfig, generate

    cfg = GenerateConfig("architectural", 1, 0, 0, out_dir="unused", seed=0, style_seed=0)
    with pytest.raises(NotImplementedError):
        generate(cfg)
