# SPDX-License-Identifier: Apache-2.0
"""S-N and T-N curves and their cited built-in constants."""

from __future__ import annotations

import math

import numpy as np
import pytest

from cabledyn import (
    FatigueCurve,
    api_rp_2sk_curve,
    chain_nominal_area,
    dnv_os_e301_curve,
    dnv_rp_c203_curve,
)
from cabledyn import curves as curves_module

# DNV-RP-C203 Table 2-1 fatigue limits at 1e7 cycles (MPa), as tabulated.
FATIGUE_LIMITS = {
    "B1": 106.97,
    "B2": 93.59,
    "C": 73.10,
    "C1": 65.50,
    "C2": 58.48,
    "D": 52.63,
    "E": 46.78,
    "F": 41.52,
    "F1": 36.84,
    "F3": 32.75,
    "G": 29.24,
    "W1": 26.32,
    "W2": 23.39,
    "W3": 21.05,
}


@pytest.mark.parametrize("name", sorted(FATIGUE_LIMITS))
def test_dnv_rp_c203_air_curves_meet_at_the_tabulated_fatigue_limit(name):
    curve = dnv_rp_c203_curve(name)
    assert curve.bilinear and curve.m2 == 5.0
    assert curve.transition_cycles == pytest.approx(1.0e7, rel=5.0e-3)
    assert curve.transition_range == pytest.approx(FATIGUE_LIMITS[name], rel=2.0e-3)
    assert curve.unit == "MPa" and "Table 2-1" in curve.source


@pytest.mark.parametrize("name", sorted(FATIGUE_LIMITS))
def test_dnv_rp_c203_seawater_curves_change_slope_at_one_million_cycles(name):
    curve = dnv_rp_c203_curve(name, "seawater_cp")
    assert curve.transition_cycles == pytest.approx(1.0e6, rel=5.0e-3)
    # The high-cycle segment is the same as in air.
    assert curve.log_a2 == dnv_rp_c203_curve(name).log_a2
    assert "Table 2-2" in curve.source


@pytest.mark.parametrize("name", [key for key in FATIGUE_LIMITS if key not in {"B1", "B2"}])
def test_dnv_rp_c203_free_corrosion_is_one_third_of_the_air_life(name):
    curve = dnv_rp_c203_curve(name.lower(), "free_corrosion")
    air = dnv_rp_c203_curve(name)
    assert not curve.bilinear and curve.m1 == 3.0
    assert curve.log_a1 == pytest.approx(air.log_a1 - math.log10(3.0), abs=1.5e-3)
    assert curve.transition_range is None and curve.transition_cycles is None


def test_bilinear_curve_uses_the_segment_of_each_range():
    curve = dnv_rp_c203_curve("D")
    life = curve.cycles_to_failure([100.0, 30.0, 0.0])
    assert life[0] == pytest.approx(10.0 ** (12.164 - 3.0 * 2.0))
    assert life[1] == pytest.approx(10.0 ** (15.606 - 5.0 * math.log10(30.0)))
    assert life[2] == math.inf
    assert not life.flags.writeable
    with pytest.raises(ValueError, match="non-negative"):
        curve.cycles_to_failure([-1.0])
    with pytest.raises(ValueError, match="non-negative"):
        curve.cycles_to_failure([math.nan])


def test_endurance_limit_removes_small_ranges():
    curve = FatigueCurve("user", "S-N", 3.0, 12.0, endurance_limit=10.0)
    life = curve.cycles_to_failure(np.array([[5.0, 10.0, 20.0]]))
    assert life.shape == (1, 3)
    assert life[0, 0] == life[0, 1] == math.inf
    assert life[0, 2] == pytest.approx(1.0e12 / 8000.0)


def test_thickness_factor():
    curve = dnv_rp_c203_curve("D")
    assert curve.reference_thickness == 25.0 and curve.thickness_exponent == 0.2
    assert curve.thickness_factor(50.0) == pytest.approx(2.0**0.2)
    assert curve.thickness_factor(10.0) == 1.0
    assert dnv_rp_c203_curve("B1").thickness_factor(80.0) == 1.0
    with pytest.raises(ValueError, match="thickness"):
        curve.thickness_factor(0.0)


def test_tension_scale_by_curve_kind():
    sn = dnv_os_e301_curve("studless_chain")
    tn = api_rp_2sk_curve("studless_chain")
    assert sn.tension_scale(area=0.01) == pytest.approx(1.0e-4)
    assert tn.tension_scale(breaking_strength=2.0e7) == pytest.approx(5.0e-8)
    with pytest.raises(ValueError, match="S-N curve needs area"):
        sn.tension_scale(breaking_strength=1.0)
    with pytest.raises(ValueError, match="S-N curve needs area"):
        sn.tension_scale()
    with pytest.raises(ValueError, match="T-N curve needs breaking_strength"):
        tn.tension_scale(area=1.0)
    with pytest.raises(ValueError, match="area must be finite"):
        sn.tension_scale(area=-1.0)


@pytest.mark.parametrize(
    ("component", "a_d", "m", "kind"),
    [
        ("studlink_chain", 1.2e11, 3.0, "S-N"),
        ("studless_chain", 6.0e10, 3.0, "S-N"),
        ("stranded_rope", 3.4e14, 4.0, "S-N"),
        ("spiral_strand_rope", 1.7e17, 4.8, "S-N"),
        ("polyester_rope", 0.259, 13.46, "T-N"),
    ],
)
def test_dnv_os_e301_curves(component, a_d, m, kind):
    curve = dnv_os_e301_curve(component)
    assert curve.kind == kind and curve.m1 == m
    assert curve.cycles_to_failure([1.0])[0] == pytest.approx(a_d)
    assert "E301" in curve.source


@pytest.mark.parametrize(
    ("component", "k"),
    [("studlink_chain", 1000.0), ("studless_chain", 316.0), ("connecting_link", 178.0)],
)
def test_api_rp_2sk_chain_curves(component, k):
    curve = api_rp_2sk_curve(component)
    assert curve.kind == "T-N" and curve.m1 == 3.36
    assert curve.cycles_to_failure([1.0])[0] == pytest.approx(k)
    assert "API RP 2SK" in curve.source


def test_api_rp_2sk_rope_curves_depend_on_the_mean_load():
    rope = api_rp_2sk_curve("stranded_rope", mean_load_ratio=0.2)
    spiral = api_rp_2sk_curve("spiral_strand_rope", mean_load_ratio=0.0)
    assert rope.m1 == 4.09 and rope.log_a1 == pytest.approx(3.20 - 2.79 * 0.2)
    assert spiral.m1 == 5.05 and spiral.log_a1 == pytest.approx(3.25)
    assert "Lm = 0.2" in rope.name
    with pytest.raises(ValueError, match="needs mean_load_ratio"):
        api_rp_2sk_curve("stranded_rope")
    with pytest.raises(ValueError, match=r"\[0, 1\)"):
        api_rp_2sk_curve("stranded_rope", mean_load_ratio=1.0)
    with pytest.raises(ValueError, match="must be finite"):
        api_rp_2sk_curve("stranded_rope", mean_load_ratio=math.nan)
    with pytest.raises(ValueError, match="omit mean_load_ratio"):
        api_rp_2sk_curve("studless_chain", mean_load_ratio=0.1)


@pytest.mark.parametrize(
    ("call", "message"),
    [
        (lambda: dnv_rp_c203_curve("Z"), "unknown DNV-RP-C203 curve"),
        (lambda: dnv_rp_c203_curve("D", "fresh"), "environment must be"),
        (lambda: dnv_os_e301_curve("nylon"), "unknown DNV-OS-E301 component"),
        (lambda: api_rp_2sk_curve("nylon"), "unknown API RP 2SK component"),
        (lambda: chain_nominal_area(0.0), "diameter"),
    ],
)
def test_builtin_curve_errors(call, message):
    with pytest.raises(ValueError, match=message):
        call()


def test_chain_nominal_area_is_two_legs():
    assert chain_nominal_area(0.1) == pytest.approx(2.0 * math.pi * 0.01 / 4.0)


@pytest.mark.parametrize(
    ("kwargs", "message"),
    [
        ({"name": ""}, "name must be"),
        ({"kind": "E-N"}, "kind must be"),
        ({"m1": 0.0}, "m1 must be"),
        ({"m1": True}, "m1 must be"),
        ({"log_a1": math.inf}, "log_a1 must be finite"),
        ({"log_a1": False}, "log_a1 must be finite"),
        ({"m2": 5.0}, "given together"),
        ({"m2": 2.0, "log_a2": 10.0}, "must exceed m1"),
        ({"thickness_exponent": -0.1}, "non-negative"),
        ({"thickness_exponent": 0.2}, "needs a reference_thickness"),
        ({"reference_thickness": 0.0}, "reference_thickness"),
        ({"endurance_limit": -1.0}, "endurance_limit"),
    ],
)
def test_curve_validation(kwargs, message):
    fields = {"name": "c", "kind": "S-N", "m1": 3.0, "log_a1": 12.0}
    fields.update(kwargs)
    with pytest.raises(ValueError, match=message):
        FatigueCurve(**fields)


def test_every_builtin_table_is_complete():
    assert set(curves_module._C203_AIR) == set(curves_module._C203_SEAWATER_CP)
    assert set(curves_module._C203_AIR) == set(curves_module._C203_FREE_CORROSION)


def test_every_dnv_mooring_curve_names_its_edition():
    for component in (
        "studlink_chain",
        "studless_chain",
        "stranded_rope",
        "spiral_strand_rope",
        "polyester_rope",
    ):
        assert "July 2018" in dnv_os_e301_curve(component).source
