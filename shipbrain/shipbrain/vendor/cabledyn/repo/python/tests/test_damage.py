# SPDX-License-Identifier: Apache-2.0
"""Palmgren-Miner damage, stress recovery, damage along the arc, and lifetime weighting."""

from __future__ import annotations

import csv
import math

import numpy as np
import pytest
from _design_data import ARC, TIME, node_channels, write_main, write_static

from cabledyn import (
    ChannelDamage,
    FatigueCurve,
    RainflowCycle,
    SeaStateDamage,
    StudyCaseResult,
    StudyOutputError,
    StudyResult,
    cable_stress,
    channel_damage,
    damage_along_arc,
    dnv_rp_c203_curve,
    lifetime_fatigue,
    miner_damage,
    read_output,
    study_sea_state_damage,
)
from cabledyn.damage import SECONDS_PER_YEAR

CURVE = FatigueCurve("unit", "S-N", 3.0, 12.0)


def _close(value: float):
    """Relative comparison for the tiny damage values."""
    return pytest.approx(value, rel=1.0e-9, abs=0.0)


def _sine_damage(curve: FatigueCurve, amplitude: float) -> float:
    """Damage of the 5-period sine records: 4.5 cycles of 2A plus 1 cycle of A."""
    life = curve.cycles_to_failure([2.0 * amplitude, amplitude])
    return 4.5 / life[0] + 1.0 / life[1]


def test_miner_damage_sums_cycle_fractions():
    cycles = [RainflowCycle(10.0, 0.0, 1.0, 0, 1), RainflowCycle(20.0, 5.0, 0.5, 1, 2)]
    expected = 1.0 / (1.0e12 / 1000.0) + 0.5 / (1.0e12 / 8000.0)
    assert miner_damage(cycles, CURVE) == _close(expected)
    assert miner_damage(cycles, CURVE, scale=2.0) == _close(8.0 * expected)
    assert miner_damage([], CURVE) == 0.0


def test_goodman_correction_is_opt_in_and_tensile_only():
    tensile = [RainflowCycle(10.0, 50.0, 1.0, 0, 1)]
    compressive = [RainflowCycle(10.0, -50.0, 1.0, 0, 1)]
    plain = miner_damage(tensile, CURVE)
    corrected = miner_damage(tensile, CURVE, ultimate_strength=100.0)
    assert corrected == _close(plain * 2.0**3)
    assert miner_damage(compressive, CURVE, ultimate_strength=100.0) == _close(plain)
    with pytest.raises(ValueError, match="Goodman is undefined"):
        miner_damage(tensile, CURVE, ultimate_strength=50.0)
    with pytest.raises(ValueError, match="ultimate_strength"):
        miner_damage(tensile, CURVE, ultimate_strength=-1.0)


@pytest.mark.parametrize(
    ("kwargs", "message"),
    [({"scale": 0.0}, "scale"), ({"scale": True}, "scale")],
)
def test_miner_damage_rejects_bad_settings(kwargs, message):
    with pytest.raises(ValueError, match=message):
        miner_damage([RainflowCycle(1.0, 0.0, 1.0, 0, 1)], CURVE, **kwargs)
    with pytest.raises(ValueError, match="RainflowCycle"):
        miner_damage([1.0], CURVE)  # type: ignore[list-item]


def test_channel_damage_of_a_sine(tmp_path):
    history = read_output(write_main(tmp_path / "run.out"))
    curve = dnv_rp_c203_curve("D", "seawater_cp")
    scale = curve.tension_scale(area=0.01)
    result = channel_damage(history, "FairTen1", curve, scale=scale)
    assert isinstance(result, ChannelDamage)
    assert result.damage == _close(_sine_damage(curve, 1.0e5 * scale))
    assert result.cycle_count == pytest.approx(5.5)
    assert result.duration == pytest.approx(10.0)
    assert not result.goodman
    assert result.damage_rate == pytest.approx(result.damage * SECONDS_PER_YEAR / 10.0)
    assert result.fatigue_life == pytest.approx(1.0 / result.damage_rate)
    windowed = channel_damage(
        history, "FairTen1", curve, scale=scale, start=0.0, stop=5.0, ultimate_strength=500.0
    )
    assert windowed.goodman and windowed.duration == pytest.approx(5.0)
    quiet = channel_damage(history, "ten1n5", curve, scale=scale)
    assert quiet.damage == 0.0 and quiet.fatigue_life == math.inf
    with pytest.raises(ValueError, match="non-time channel"):
        channel_damage(history, "Time(s)", curve)
    with pytest.raises(ValueError, match="two time samples"):
        channel_damage(history, "FairTen1", curve, start=1.0, stop=1.0)


def test_cable_stress_two_fibres():
    outer, inner = cable_stress([1.0e5, 2.0e5], [0.01, 0.0], area=0.01, modulus=2.0e11, radius=0.05)
    np.testing.assert_allclose(outer, [1.0e7 + 1.0e8, 2.0e7])
    np.testing.assert_allclose(inner, [1.0e7 - 1.0e8, 2.0e7])
    assert not outer.flags.writeable and not inner.flags.writeable
    with pytest.raises(ValueError, match="radius"):
        cable_stress(1.0, 0.0, area=1.0, modulus=1.0, radius=-1.0)
    with pytest.raises(ValueError, match="radius"):
        cable_stress(1.0, 0.0, area=1.0, modulus=1.0, radius=True)  # type: ignore[arg-type]
    with pytest.raises(ValueError, match="modulus"):
        cable_stress(1.0, 0.0, area=1.0, modulus=0.0, radius=1.0)
    with pytest.raises(ValueError, match="finite"):
        cable_stress(math.nan, 0.0, area=1.0, modulus=1.0, radius=1.0)


def test_damage_along_arc_from_tension(tmp_path, plt):
    history = read_output(write_main(tmp_path / "run.out"))
    curve = dnv_rp_c203_curve("D")
    profile = damage_along_arc(history, 1, curve, area=0.01, arc_length=ARC)
    scale = 1.0e-4
    assert profile.node_ids == (1, 3, 5)
    assert profile.location_kind == "ArcLength"
    np.testing.assert_allclose(profile.location, [0.0, 50.0, 100.0])
    assert profile.damage[0] == _close(_sine_damage(curve, 1.0e5 * scale))
    assert profile.damage[1] == _close(_sine_damage(curve, 5.0e4 * scale))
    assert profile.damage[2] == 0.0
    assert profile.critical_node == 1
    assert profile.maximum_damage == _close(profile.damage[0])
    assert profile.plot().get_ylabel() == "Damage [-]"
    _, ax = plt.subplots()
    assert profile.plot(ax=ax) is ax
    by_node = damage_along_arc(history, 1, curve, area=0.01)
    assert by_node.location_kind == "Node"
    tn = FatigueCurve("tn", "T-N", 3.0, 3.0)
    ratio = damage_along_arc(history, 1, tn, breaking_strength=1.0e7)
    assert ratio.damage[0] == _close(_sine_damage(tn, 1.0e5 / 1.0e7))


def test_damage_along_arc_from_recovered_stress(tmp_path):
    history = read_output(write_main(tmp_path / "run.out"))
    curve = dnv_rp_c203_curve("D")
    section = {"area": 0.01, "modulus": 2.0e11, "radius": 0.05}
    profile = damage_along_arc(history, 1, curve, quantity="stress", **section)
    data = node_channels()
    outer, inner = cable_stress(data["Ten1N03"], data["Curv1N3"], **section)
    expected = max(
        channel_damage(_table(tmp_path, outer), "S", curve, scale=1.0e-6).damage,
        channel_damage(_table(tmp_path, inner), "S", curve, scale=1.0e-6).damage,
    )
    assert profile.damage[1] == _close(expected)
    assert profile.quantity == "stress"


def _table(tmp_path, values):
    path = tmp_path / f"s{abs(hash(values.tobytes()))}.out"
    rows = "\n".join(f"{t:.12e} {v:.12e}" for t, v in zip(TIME, values, strict=True))
    path.write_text(f"Time(s) S\n{rows}\n", encoding="ascii")
    return read_output(path)


def test_damage_along_arc_errors(tmp_path):
    history = read_output(write_main(tmp_path / "run.out"))
    curve = dnv_rp_c203_curve("D")
    tn = FatigueCurve("tn", "T-N", 3.0, 3.0)
    with pytest.raises(ValueError, match="S-N curve"):
        damage_along_arc(history, 1, tn, quantity="stress", area=1.0, modulus=1.0, radius=1.0)
    with pytest.raises(ValueError, match="area, modulus, and radius"):
        damage_along_arc(history, 1, curve, quantity="stress", area=1.0)
    with pytest.raises(ValueError, match="quantity must be"):
        damage_along_arc(history, 1, curve, quantity="strain", area=1.0)
    with pytest.raises(KeyError, match="Ten7N"):
        damage_along_arc(history, 7, curve, area=1.0)
    columns = node_channels()
    del columns["Curv1N5"]
    sparse = read_output(write_main(tmp_path / "sparse.out", columns))
    with pytest.raises(ValueError, match="same nodes"):
        damage_along_arc(sparse, 1, curve, quantity="stress", area=1.0, modulus=1.0, radius=1.0)


def test_lifetime_fatigue_weights_sea_states(tmp_path):
    first = SeaStateDamage("hs2", 0.6, 3600.0, [1.0e-6, 2.0e-6])
    second = SeaStateDamage("hs4", 0.3, 1800.0, np.array([4.0e-6, 0.0]))
    hours = SECONDS_PER_YEAR / 3600.0
    result = lifetime_fatigue([first, second], design_life=25.0, design_factor=3.0)
    annual = 3.0 * np.array([0.6 * 1.0e-6 * hours + 0.3 * 8.0e-6 * hours, 0.6 * 2.0e-6 * hours])
    np.testing.assert_allclose(result.annual_damage, annual)
    np.testing.assert_allclose(result.lifetime_damage, 25.0 * annual)
    np.testing.assert_allclose(result.fatigue_life, 1.0 / annual)
    assert result.total_probability == pytest.approx(0.9)
    assert result.critical_index == int(np.argmax(annual))
    assert result.maximum_lifetime_damage == pytest.approx(25.0 * annual.max())
    assert result.minimum_fatigue_life == pytest.approx(1.0 / annual.max())
    assert result.passed == (25.0 * annual.max() <= 1.0)
    contributions = result.contributions()
    np.testing.assert_allclose(contributions["hs4"], 3.0 * second.annual_damage)
    target = result.export(tmp_path / "out" / "lifetime.csv")
    rows = list(csv.reader(target.open(encoding="utf-8")))
    assert rows[0][0] == "SeaState" and len(rows) == 5
    with pytest.raises(FileExistsError):
        result.export(target)
    zero = lifetime_fatigue([SeaStateDamage("calm", 1.0, 10.0, 0.0)], design_life=1.0)
    assert zero.fatigue_life[0] == math.inf and zero.passed


@pytest.mark.parametrize(
    ("states", "kwargs", "message"),
    [
        ([], {}, "non-empty"),
        ([SeaStateDamage("a", 0.5, 1.0, 0.0)] * 2, {}, "unique"),
        (
            [SeaStateDamage("a", 0.5, 1.0, 0.0), SeaStateDamage("b", 0.4, 1.0, [0.0, 0.0])],
            {},
            "same shape",
        ),
        (
            [SeaStateDamage("a", 0.6, 1.0, 0.0), SeaStateDamage("b", 0.6, 1.0, 0.0)],
            {},
            "more than one",
        ),
        ([SeaStateDamage("a", 0.5, 1.0, 0.0)], {"design_life": 0.0}, "design_life"),
        ([SeaStateDamage("a", 0.5, 1.0, 0.0)], {"design_factor": -1.0}, "design_factor"),
    ],
)
def test_lifetime_fatigue_errors(states, kwargs, message):
    settings = {"design_life": 20.0, **kwargs}
    with pytest.raises(ValueError, match=message):
        lifetime_fatigue(states, **settings)


@pytest.mark.parametrize(
    ("kwargs", "message"),
    [
        ({"name": ""}, "name"),
        ({"probability": 1.5}, r"\(0, 1\]"),
        ({"probability": 0.0}, "probability"),
        ({"duration": -1.0}, "duration"),
        ({"damage": [[1.0]]}, "one-dimensional"),
        ({"damage": []}, "one-dimensional"),
        ({"damage": [math.nan]}, "one-dimensional"),
        ({"damage": [-1.0]}, "non-negative"),
    ],
)
def test_sea_state_validation(kwargs, message):
    fields = {"name": "a", "probability": 0.5, "duration": 10.0, "damage": 1.0}
    fields.update(kwargs)
    with pytest.raises(ValueError, match=message):
        SeaStateDamage(**fields)


def _case(tmp_path, name, main, status="completed"):
    return StudyCaseResult(
        name=name,
        status=status,
        deck=tmp_path / f"{name}.dat",
        deck_sha256="0" * 64,
        output_root=tmp_path / name,
        elapsed_seconds=1.0,
        returncode=0 if status == "completed" else 2,
        main_output=main,
        static_output=None,
        stdout_log=tmp_path / f"{name}.stdout.log",
        stderr_log=tmp_path / f"{name}.stderr.log",
        error=None,
    )


def _study(tmp_path, cases):
    return StudyResult(
        case_manifest=tmp_path / "cases.json",
        study_manifest=tmp_path / "study.json",
        summary_csv=tmp_path / "summary.csv",
        executable=tmp_path / "driver",
        executable_sha256="0" * 64,
        solver_version="test",
        started_at="2026-01-01T00:00:00Z",
        finished_at="2026-01-01T00:00:01Z",
        cases=tuple(cases),
    )


def test_study_sea_state_damage_to_lifetime(tmp_path):
    calm = {"FairTen1": np.full(TIME.shape, 1.0e6), "Ten1N1": np.full(TIME.shape, 1.0e6)}
    study = _study(
        tmp_path,
        [
            _case(tmp_path, "ss1", write_main(tmp_path / "ss1.out")),
            _case(tmp_path, "ss2", write_main(tmp_path / "ss2.out", calm)),
            _case(tmp_path, "failed", None, status="failed"),
        ],
    )
    curve = dnv_rp_c203_curve("D", "seawater_cp")
    scale = curve.tension_scale(area=0.01)
    states = study_sea_state_damage(
        study,
        {"ss1": 0.7, "ss2": 0.3},
        lambda history: channel_damage(history, "FairTen1", curve, scale=scale),
        start=2.0,
    )
    assert [state.name for state in states] == ["ss1", "ss2"]
    assert states[0].duration == pytest.approx(8.0)
    assert states[1].damage[0] == 0.0
    profiles = study_sea_state_damage(
        study,
        {"ss1": 0.7},
        lambda history: damage_along_arc(history, 1, curve, area=0.01),
    )
    assert profiles[0].damage.shape == (3,)
    plain = study_sea_state_damage(study, {"ss1": 1.0}, lambda history: 1.0e-3, stop=5.0)
    assert plain[0].duration == pytest.approx(5.0)
    result = lifetime_fatigue(states, design_life=25.0)
    assert result.annual_damage[0] == _close(0.7 * states[0].damage[0] * SECONDS_PER_YEAR / 8.0)
    with pytest.raises(StudyOutputError, match="did not complete"):
        study_sea_state_damage(study, {"failed": 1.0}, lambda history: 0.0)
    with pytest.raises(KeyError, match="not in the study"):
        study_sea_state_damage(study, {"ss9": 1.0}, lambda history: 0.0)
    with pytest.raises(ValueError, match="at least one case"):
        study_sea_state_damage(study, {}, lambda history: 0.0)


def test_study_sea_state_damage_needs_a_time_history(tmp_path):
    static = write_static(tmp_path / "run.static.out")
    study = _study(tmp_path, [_case(tmp_path, "s", static)])
    with pytest.raises(StudyOutputError, match="not a time history"):
        study_sea_state_damage(study, {"s": 1.0}, lambda history: 0.0)
