# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""A deck of ``EI = 0`` lines in a depth-profile current, stepped in-process.

The current falls from 1.3 m/s at the surface to 0.23 m/s at the seabed. The line takes it at
its own nodes, at the static state and before every step: held at rest the model stays at
rest, and its start is the standalone driver's static state.
"""

from __future__ import annotations

import os
import subprocess
from ctypes import POINTER, byref, c_bool, c_double, c_int
from pathlib import Path

import numpy as np
import pytest

try:
    from cabledyn._lib import _lib
except OSError as exc:
    pytest.skip(f"CableDyn shared library not available: {exc}", allow_module_level=True)

from cabledyn.model import CableDyn

CHANNELS = ["FairTen1", "AnchTen1", "Point1Fx", "Point1Fy", "Point1Fz"]

DECK = """--------------------- CableDyn Input File ------------------------------------
A chain catenary in a depth-profile current
--------------------- LINE TYPES ---------------------------------------
TypeName Diam Mass EA BA EI Cd_n Cd_t Ca_n Ca_t
(-) (m) (kg/m) (N) (N-s) (N-m2) (-) (-) (-) (-)
chain 0.1754 189.03 8.112e8 -0.5 0.0 2.4 1.15 1.0 0.5
--------------------- POINTS -------------------------------------------
ID Type X Y Z
(-) (-) (m) (m) (m)
1 Coupled -2.667 6.615 -9.621
2 Fixed -189.019 -269.414 -137.53
--------------------- LINES --------------------------------------------
ID NodeA NodeB Outputs
(-) (-) (-) (-)
1 1 2 -
--------------------- SECTIONS -----------------------------------------
LineID LineType Length NumSegs
(-) (-) (m) (-)
1 chain 430.23 25
--------------------- OPTIONS ------------------------------------------
137.53 WtrDpth
1.0e5 kBot
profile 0.0 0.5435 1.1875 0.0 -137.53 0.0946 0.2066 0.0 current
0.02 dtM
0.0 TMax
--------------------- OUTPUTS ------------------------------------------
FairTen1
AnchTen1
Point1Fx
Point1Fy
Point1Fz
--------------------- need this line -----------------------------------
"""


@pytest.fixture
def deck(tmp_path: Path) -> Path:
    path = tmp_path / "profile_chain.dat"
    path.write_text(DECK, encoding="utf-8", newline="\n")
    return path


def test_held_line_stays_at_rest(deck: Path) -> None:
    with CableDyn(deck) as model:
        start = model.channels(CHANNELS)
        for _ in range(100):
            model.step_held(0.02)
        end = model.channels(CHANNELS)
    scale = abs(start[0])
    assert np.max(np.abs(end - start)) < 1.0e-6 * scale, (start, end)


def test_a_refused_step_leaves_the_loads(deck: Path) -> None:
    # After the fairlead has moved, the field the next step samples differs from the held one.
    # A step the library refuses (dt <= 0, or a non-finite motion: both bypass the binding's own
    # checks here) commits nothing, so the loads after it are those before it, bit for bit.
    with CableDyn(deck) as model:
        q0, _, _ = model.get_coupled_motion()
        dt, n = 0.02, 20
        for k in range(1, n + 1):
            s = k / n
            shape = s * s * (3.0 - 2.0 * s)  # smooth 2 m surge, at rest at both ends
            rate = 6.0 * s * (1.0 - s) / (n * dt)
            accel = 6.0 * (1.0 - 2.0 * s) / (n * dt) ** 2
            q = q0.copy()
            q[0] += 2.0 * shape
            v = np.zeros_like(q0)
            v[0] = 2.0 * rate
            a = np.zeros_like(q0)
            a[0] = 2.0 * accel
            model.step(dt, q, v, a)
        before = model.calc_output()
        channels = model.channels(CHANNELS)
        nan_q = q.copy()
        nan_q[0] = float("nan")
        for step_dt, motion in ((-1.0, q), (dt, nan_q)):
            qa = np.ascontiguousarray(motion, dtype=np.float64)
            va = np.zeros_like(qa)
            aa = np.zeros_like(qa)
            conv, stall, nit, status = c_bool(), c_bool(), c_int(), c_int()
            _lib.CableDyn_Step(
                model._handle,
                step_dt,
                qa.ctypes.data_as(POINTER(c_double)),
                va.ctypes.data_as(POINTER(c_double)),
                aa.ctypes.data_as(POINTER(c_double)),
                qa.size,
                byref(conv),
                byref(stall),
                byref(nit),
                byref(status),
            )
            assert status.value != 0
            assert np.array_equal(model.calc_output(), before)
            assert np.array_equal(model.channels(CHANNELS), channels)


@pytest.mark.skipif(
    not os.environ.get("CABLEDYN_DRIVER", "").strip(),
    reason="set CABLEDYN_DRIVER to compare with the standalone driver",
)
def test_start_is_the_driver_static_state(deck: Path, tmp_path: Path) -> None:
    root = tmp_path / "profile_chain"
    proc = subprocess.run(
        [os.environ["CABLEDYN_DRIVER"].strip(), str(deck), str(root)],
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr
    rows = Path(str(root) + ".out").read_text(encoding="utf-8").splitlines()
    driver = np.array([float(v) for v in rows[2].split()[1:]])
    with CableDyn(deck) as model:
        start = model.channels(CHANNELS)
    assert np.max(np.abs(start - driver)) < 2.0e-7 * abs(driver[0]), (start, driver)
