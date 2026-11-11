# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""In-process stepping of a deck in moving water, against the standalone driver.

The driver reads the deck's current and waves and a motion file. The same deck runs here on the
library with the same motion: its current either from the deck, or with every fluid value computed
in this file and handed over node by node (``update_fluid_fields``). Both routes hold the field at
``t + dt`` at the step-start nodes over a step, so they agree to the digits of the driver's output.
"""

from __future__ import annotations

import math
import runpy
import subprocess
from pathlib import Path

import numpy as np
import pytest

try:
    from cabledyn import _lib  # noqa: F401
except OSError as exc:
    pytest.skip(f"CableDyn shared library not available: {exc}", allow_module_level=True)

from cabledyn.driver import CableDynDriver
from cabledyn.errors import CableDynError, DriverNotFoundError
from cabledyn.model import CableDyn

DT, TMAX = 0.02, 6.0
HEIGHT, PERIOD, DEPTH, GRAVITY = 2.0, 8.0, 60.0, 9.80665
SPEED = 0.4
TOP = np.array([0.0, 0.0, -10.0])
SWAY, MOTION_RATE = 0.6, 2.0 * math.pi / 10.0
CHANNELS = ["FairTen1", "AnchTen1"]
TOLERANCE = 1.0e-5

DECK = """--------------------- CableDyn Input File ------------------------------------
A cable between a moving top end and an anchor
--------------------- LINE TYPES ---------------------------------------------
TypeName  Diam   MassDenInAir  EA       BA   EI       Cd_n Cd_t Ca_n Ca_t
(-)       (m)    (kg/m)        (N)      (-)  (N-m2)   (-)  (-)  (-)  (-)
cable     0.16   36.7          4.69e8   -1.0 1.99e4   1.2  0.1  1.0  0.0
--------------------- POINTS ------------------------------------------------
ID  Type     X       Y    Z
(-) (-)      (m)     (m)  (m)
1   Coupled  0.0     0.0  -10.0
2   Fixed    70.0    0.0  -60.0
--------------------- LINES -------------------------------------------------
ID  NodeA  NodeB  Outputs
(-) (-)    (-)    (-)
1   1      2      -
--------------------- SECTIONS ----------------------------------------------
LineID  LineType  Length   NumSegs
(-)     (-)       (m)      (-)
1       cable     100.0    40
{tables}--------------------- OPTIONS -----------------------------------------------
9.80665  g
1025.0   rhoW
60.0     WtrDpth
1.0e5    kBot
1.0e4    cBot
0.02     dtM
6.0      TMax
{options}
--------------------- OUTPUTS -----------------------------------------------
"FairTen1"
"AnchTen1"
--------------------- need this line ----------------------------------------
"""

EI0_DECK = DECK.replace(" 1.99e4 ", " 0 ")

WATERKIN = """MoorDyn v2 water kinematics file
a sheared current
--------------------------- WAVES -------------------------------------
0                    WaveKinMod  - type of wave input
""                   WaveKinFile - file containing wave elevation time series
0.000000E+00  dtWave      - time step to use in setting up wave kinematics grid
0                    WaveDir     - wave heading (deg)
2                                - X wave input type
-10, 110, 2                      - X wave grid point data
2                                - Y wave input type
-10, 10, 2                       - Y wave grid point data
2                                - Z wave input type
-100, 0, 2                       - Z wave grid point data
--------------------------- CURRENT -------------------------------------
1                    CurrentMod  - type of current input
z-depth     x-current      y-current
(m)           (m/s)         (m/s)
0.0    0.5  0.1
-30.0  0.3  0.0
-60.0  0.1  0.0
--------------------- need this line ------------------
"""

# a tapered stiffener at a clamped top end, on a line resting on a seabed with friction
STIFFENER = """--------------------- STIFFENERS --------------------------------------------
LineID  End  Length  RootOD  TipOD  InnerD  E       Density
(-)     (-)  (m)     (m)     (m)    (m)     (Pa)    (kg/m^3)
1       A    4.0     0.45    0.18   0.17    5.0e7   1150
--------------------- END CONNECTIONS ---------------------------------------
LineID  End  Stiffness  EzX     EzY  EzZ
(-)     (-)  (N-m/rad)  (-)     (-)  (-)
1       A    Rigid      0.3     0.0  -0.9539
"""

FRICTION = "0.5 frictionMu\nasLaid staticsFriction\n0 layAzimuth"
CURRENT = f"uniform {SPEED} 0 0 current"
WAVE = f"airy {HEIGHT} {PERIOD} 0 waves"


def _driver() -> CableDynDriver:
    try:
        return CableDynDriver()
    except DriverNotFoundError as exc:
        pytest.skip(f"the standalone driver is not available: {exc}")


def _motion(t: float) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Host motion with zero velocity and acceleration at t = 0."""
    s, c = math.sin(MOTION_RATE * t), math.cos(MOTION_RATE * t)
    q = TOP + np.array([SWAY * s**3, 0.0, 0.0])
    v = np.array([3.0 * SWAY * MOTION_RATE * s * s * c, 0.0, 0.0])
    a = np.array([3.0 * SWAY * MOTION_RATE**2 * (2.0 * s * c * c - s**3), 0.0, 0.0])
    return q, v, a


def _wave_number() -> tuple[float, float]:
    omega = 2.0 * math.pi / PERIOD
    k = omega * omega / GRAVITY
    for _ in range(50):
        th = math.tanh(k * DEPTH)
        k -= (GRAVITY * k * th - omega * omega) / (
            GRAVITY * th + GRAVITY * k * DEPTH / math.cosh(k * DEPTH) ** 2
        )
    return omega, k


OMEGA, WAVE_NUMBER = _wave_number()


def _airy(xyz: np.ndarray, t: float) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """The deck's Airy wave along +x with Wheeler stretching: velocity, acceleration, elevation."""
    theta = WAVE_NUMBER * xyz[0] - OMEGA * t
    eta = 0.5 * HEIGHT * np.cos(theta)
    wet = xyz[2] <= eta
    level = (xyz[2] - eta) * DEPTH / (DEPTH + eta) + DEPTH
    ratio_h = np.cosh(WAVE_NUMBER * level) / math.sinh(WAVE_NUMBER * DEPTH)
    ratio_v = np.sinh(WAVE_NUMBER * level) / math.sinh(WAVE_NUMBER * DEPTH)
    amp = 0.5 * HEIGHT * OMEGA
    velocity = np.zeros_like(xyz)
    acceleration = np.zeros_like(xyz)
    velocity[0] = np.where(wet, amp * ratio_h * np.cos(theta), 0.0)
    velocity[2] = np.where(wet, amp * ratio_v * np.sin(theta), 0.0)
    acceleration[0] = np.where(wet, amp * OMEGA * ratio_h * np.sin(theta), 0.0)
    acceleration[2] = np.where(wet, -amp * OMEGA * ratio_v * np.cos(theta), 0.0)
    return velocity, acceleration, eta


def _deck(folder: Path, name: str, options: str, tables: str = "", template: str = DECK) -> Path:
    path = folder / f"{name}.dat"
    path.write_text(template.format(options=options, tables=tables), encoding="utf-8")
    return path


def _driver_run(folder: Path, options: str, tables: str = "", template: str = DECK) -> np.ndarray:
    """FairTen1 and AnchTen1 of the driver on the deck with the motion as a motionFile."""
    with (folder / "motion.txt").open("w", encoding="ascii") as stream:
        for i in range(round(TMAX / DT) + 1):
            q, v, a = _motion(i * DT)
            row = " ".join(f"{x:.14e}" for x in (*q, *v, *a))
            stream.write(f"{i * DT:.10f} 1 {row}\n")
    deck = _deck(folder, "driver", f"{options}\nmotion.txt motionFile", tables, template)
    subprocess.run(
        [str(_driver().executable), deck.name, "driver"],
        cwd=folder,
        capture_output=True,
        text=True,
        check=True,
    )
    rows = (folder / "driver.out").read_text(encoding="utf-8").splitlines()[2:]
    return np.array([[float(x) for x in row.split()[1:3]] for row in rows])


def _host_field(model: CableDyn, t: float, current: float) -> None:
    xyz = model.fluid_node_positions()
    velocity, acceleration, eta = _airy(xyz, t)
    velocity[0] += current
    model.update_fluid_fields(velocity, acceleration, eta)


def _march(model: CableDyn, current: float | None) -> np.ndarray:
    """The library run: with ``current`` set, the host field of that current and the wave."""
    if current is not None:
        _host_field(model, 0.0, current)
    model.calc_output()
    history = [model.channels(CHANNELS)]
    for i in range(1, round(TMAX / DT) + 1):
        t = i * DT
        if current is not None:
            _host_field(model, t, current)
        model.step(DT, *_motion(t))
        model.calc_output()
        history.append(model.channels(CHANNELS))
    return np.array(history)


def _nrmse(reference: np.ndarray, value: np.ndarray) -> float:
    assert reference.shape == value.shape
    span = np.ptp(reference, axis=0)
    return float(np.max(np.sqrt(np.mean((reference - value) ** 2, axis=0)) / span))


def test_deck_current_is_marched_in_process(tmp_path):
    reference = _driver_run(tmp_path, CURRENT)
    with CableDyn(_deck(tmp_path, "library", CURRENT)) as model:
        history = _march(model, None)
    assert _nrmse(reference, history) < TOLERANCE


def test_waterkin_depth_table_is_marched_in_process(tmp_path):
    (tmp_path / "water.dat").write_text(WATERKIN, encoding="utf-8")
    reference = _driver_run(tmp_path, "water.dat WaterKin")
    still = _driver_run(tmp_path, "")
    with CableDyn(_deck(tmp_path, "library", "water.dat WaterKin")) as model:
        history = _march(model, None)
    assert _nrmse(reference, history) < TOLERANCE
    # the table reaches the static start as well as the march
    assert abs(history[0, 0] - still[0, 0]) > 1.0


def test_deck_current_starts_at_host_positions(tmp_path):
    deck = _deck(tmp_path, "library", CURRENT)
    with CableDyn(deck) as model:
        start = model.calc_output()
    with CableDyn() as model:
        model.init_deck_at(deck, TOP)
        np.testing.assert_allclose(model.calc_output(), start, rtol=1e-12)


def test_host_field_matches_the_driver_in_current_and_waves(tmp_path):
    reference = _driver_run(tmp_path, f"{CURRENT}\n{WAVE}")
    with CableDyn() as model:
        model.set_host_fluid()
        model.init_deck(_deck(tmp_path, "library", CURRENT))
        assert model.n_fluid_nodes == 41
        assert model.fluid_node_positions().shape == (3, 41)
        history = _march(model, SPEED)
    assert _nrmse(reference, history) < TOLERANCE


def test_host_field_takes_a_stiffener_and_as_laid_friction(tmp_path):
    options = f"{CURRENT}\n{FRICTION}"
    reference = _driver_run(tmp_path, f"{options}\n{WAVE}", STIFFENER)
    with CableDyn() as model:
        model.set_host_fluid()
        model.init_deck_rotating(_deck(tmp_path, "library", options, STIFFENER))
        history = _march(model, SPEED)
    assert _nrmse(reference, history) < TOLERANCE


def test_a_host_marches_past_the_deck_tmax(tmp_path):
    deck = _deck(tmp_path, "library", CURRENT)
    deck.write_text(deck.read_text(encoding="utf-8").replace("6.0      TMax", "0.1 TMax"), "utf-8")
    with CableDyn() as model:
        model.set_host_fluid()
        model.init_deck(deck)
        _host_field(model, 0.0, SPEED)
        for i in range(1, 21):
            _host_field(model, i * DT, SPEED)
            model.step(DT, *_motion(i * DT))
        assert np.all(np.isfinite(model.calc_output()))


@pytest.mark.parametrize("policy", ["SEASTATE WaterKin", "water.dat WaterKin"])
def test_host_water_policies_of_a_deck_take_the_host_field(tmp_path, policy):
    text = WATERKIN.replace("0                    WaveKinMod", "2                    WaveKinMod")
    text = text.replace("1                    CurrentMod", "2                    CurrentMod")
    (tmp_path / "water.dat").write_text(text, encoding="utf-8")
    with CableDyn() as model:
        model.set_host_fluid()
        model.init_deck(_deck(tmp_path, "library", policy))
        _host_field(model, 0.0, SPEED)
        _host_field(model, DT, SPEED)
        model.step(DT, *_motion(DT))
        assert np.all(np.isfinite(model.calc_output()))


def test_a_host_field_deck_needs_no_tmax(tmp_path):
    deck = _deck(tmp_path, "library", CURRENT)
    deck.write_text(deck.read_text(encoding="utf-8").replace("6.0      TMax", ""), "utf-8")
    with CableDyn() as model:
        model.set_host_fluid()
        model.init_deck(deck)
        _host_field(model, 0.0, SPEED)
        _host_field(model, DT, SPEED)
        model.step(DT, *_motion(DT))
        assert np.all(np.isfinite(model.calc_output()))


@pytest.mark.parametrize(
    "options, tables",
    [(CURRENT, ""), (CURRENT + "\n" + FRICTION, STIFFENER)],
    ids=["plain", "stiffener-and-as-laid-friction"],
)
def test_save_and_restore_carry_the_held_field(tmp_path, options, tables):
    with CableDyn() as model:
        model.set_host_fluid()
        model.init_deck_rotating(_deck(tmp_path, "library", options, tables))
        _host_field(model, 0.0, SPEED)
        for i in range(1, 6):
            _host_field(model, i * DT, SPEED)
            model.step(DT, *_motion(i * DT))
        _host_field(model, 6 * DT, SPEED)
        model.save_state()
        model.step(DT, *_motion(6 * DT))
        expected = model.calc_output()
        # a different field after the save goes with the restore
        _host_field(model, 7 * DT, 2.0)
        model.restore_state()
        model.step(DT, *_motion(6 * DT))
        np.testing.assert_array_equal(model.calc_output(), expected)


def test_a_step_needs_a_host_field(tmp_path):
    with CableDyn() as model:
        model.set_host_fluid()
        model.init_deck(_deck(tmp_path, "library", ""))
        q, v, a = _motion(DT)
        with pytest.raises(CableDynError, match="before the first step"):
            model.step(DT, q, v, a)
        model.save_state()
        _host_field(model, 0.0, 0.0)
        model.restore_state()
        with pytest.raises(CableDynError, match="before the first step"):
            model.step(DT, q, v, a)


def test_host_field_calls_need_the_switch(tmp_path):
    with CableDyn(_deck(tmp_path, "library", "")) as model:
        assert model.n_fluid_nodes == 0
        with pytest.raises(CableDynError, match="takes no host fluid field"):
            model.fluid_node_positions()
        with pytest.raises(CableDynError, match="takes no host fluid field"):
            model.update_fluid_fields(np.zeros((3, 0)), np.zeros((3, 0)), np.zeros(0))


def test_host_field_inputs_are_checked(tmp_path):
    with CableDyn() as model:
        model.set_host_fluid()
        model.init_deck(_deck(tmp_path, "library", ""))
        n = model.n_fluid_nodes
        with pytest.raises(ValueError, match="fluid_velocity"):
            model.update_fluid_fields(np.zeros((3, n - 1)), np.zeros((3, n)), np.zeros(n))
        with pytest.raises(ValueError, match="waterline_z"):
            model.update_fluid_fields(np.zeros((3, n)), np.zeros((3, n)), np.zeros(n - 1))
        bad = np.zeros(n)
        bad[0] = math.nan
        with pytest.raises(ValueError, match="finite"):
            model.update_fluid_fields(np.zeros((3, n)), np.zeros((3, n)), bad)


def test_deck_waves_are_refused_with_a_host_field(tmp_path):
    with CableDyn() as model:
        model.set_host_fluid()
        with pytest.raises(CableDynError, match="remove the deck waves"):
            model.init_deck(_deck(tmp_path, "library", WAVE))


def test_ei0_lines_of_a_host_field_need_a_seabed(tmp_path):
    deck = _deck(tmp_path, "library", "", template=EI0_DECK)
    text = deck.read_text(encoding="utf-8").replace("60.0     WtrDpth\n", "")
    deck.write_text(text, encoding="utf-8")
    with CableDyn() as model:
        model.set_host_fluid()
        with pytest.raises(CableDynError, match="seabed"):
            model.init_deck(deck)


def test_ei0_line_takes_the_host_field(tmp_path):
    reference = _driver_run(tmp_path, f"{CURRENT}\n{WAVE}", template=EI0_DECK)
    with CableDyn() as model:
        model.set_host_fluid()
        model.init_deck(_deck(tmp_path, "library", CURRENT, template=EI0_DECK))
        history = _march(model, SPEED)
    print("EI0 NRMSE", _nrmse(reference, history))
    assert _nrmse(reference, history) < TOLERANCE


def test_the_switch_can_be_turned_off(tmp_path):
    deck = _deck(tmp_path, "library", CURRENT)
    with CableDyn() as model:
        model.set_host_fluid()
        model.set_host_fluid(False)
        model.init_deck(deck)
        assert model.n_fluid_nodes == 0


def test_the_stepping_example_runs():
    example = (
        Path(__file__).resolve().parents[2] / "examples" / "python" / "step_in_moving_water.py"
    )
    tensions = runpy.run_path(str(example))["main"](duration=2.0)
    assert len(tensions) == 40
    assert all(math.isfinite(value) and value > 0.0 for value in tensions)


def test_section_curvature_of_a_line_matches_its_channels(tmp_path):
    deck = _deck(tmp_path, "library", "", STIFFENER)
    with CableDyn() as model:
        model.init_deck_rotating(deck)
        model.calc_output()
        line = model.lines[0]
        values = line.section_curvature()
        assert values.shape == (line.n_nodes, 2)
        tokens = [f"Curv{axis}1N{j}" for j in range(1, line.n_nodes + 1) for axis in "XY"]
        expected = model.channels(tokens).reshape(-1, 2)
        np.testing.assert_array_equal(values, expected)
        assert np.abs(values).max() > 0.0
        np.testing.assert_allclose(np.hypot(*values.T), line.curvature(), rtol=1e-9, atol=1e-12)


def test_section_curvature_needs_a_finite_ei_line(tmp_path):
    with CableDyn(_deck(tmp_path, "library", "", template=EI0_DECK)) as model:
        with pytest.raises(CableDynError, match="finite-EI"):
            model.lines[0].section_curvature()
