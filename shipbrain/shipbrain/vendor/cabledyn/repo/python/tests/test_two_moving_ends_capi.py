# SPDX-License-Identifier: Apache-2.0
"""A finite-EI line between two Coupled points driven through the C API host recipe.

The deck is a 100 m suspended power cable between Coupled points 1 (0, 0, -20) and 2
(80, 0, -20), no seabed, no drag. CableDyn_GetCoupledLayout names one block per line end
(End A, then End B after the fairleads of every finite-EI line); the host drives both
blocks, steps and reads the loads (CalcOutput) and moments (GetCoupledMoments):

* held at rest, the two end loads carry the line's submerged weight w L between them and,
  the hang being symmetric, mirror each other (Fx_A = -Fx_B, Fz_A = Fz_B = -w L / 2);
* the End A load equals that of the same line built with a Fixed End B (the established
  fairlead route), to the solver tolerance;
* moving the End B block alone (a slow surge away from End A) moves node 1 to the host's
  position and changes both end loads: End B's block is driven, not held.
"""

from __future__ import annotations

import math
from pathlib import Path

import numpy as np
import pytest

try:
    import cabledyn._lib  # noqa: F401  (loads the shared library)
except (ImportError, OSError) as exc:  # a missing library raises OSError
    pytest.skip(f"CableDyn shared library not available: {exc}", allow_module_level=True)

from cabledyn.model import CableDyn

DT = 0.05
MASS = 60.0
DIAM = 0.20
LENGTH = 100.0
W_SUB = (MASS - 1025.0 * math.pi * DIAM**2 / 4.0) * 9.80665


def _deck(tmp_path: Path, end_b: str) -> Path:
    text = (
        "two moving ends host recipe\n--- LINE TYPES ---\n"
        "Name Diam Mass EA BA EI Cdn Cdt Can Cat\n(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)\n"
        f"pcable {DIAM} {MASS} 8.0e8 0.0 2.0e4 0.0 0.0 1.0 0.0\n"
        "--- POINTS ---\nID Type X Y Z Mass Vol CdA Ca\n(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)\n"
        f"1 Coupled 0.0 0.0 -20.0 0 0 0 0\n2 {end_b} 80.0 0.0 -20.0 0 0 0 0\n"
        "--- LINES ---\nID NodeA NodeB Outputs\n(-) (-) (-) (-)\n1 1 2 -\n"
        "--- SECTIONS ---\nLineID LineType Length NumSegs\n(-) (-) (m) (-)\n1 pcable 100.0 40\n"
        "--- OPTIONS ---\n9.80665 g\n1025.0 rhoW\n0.05 dtM\n0.0 TMax\n"
        "--- OUTPUTS ---\nFairTen1\n--- END ---\n"
    )
    path = tmp_path / f"two_end_{end_b.lower()}.dat"
    path.write_text(text, encoding="utf-8")
    return path


def test_layout_names_both_ends_and_the_host_drives_them(tmp_path):
    with CableDyn() as model:
        model.init_deck(_deck(tmp_path, "Coupled"))
        assert model.coupled_layout() == ((1, "coupled"), (2, "coupled"))
        assert list(model.host_dofs()) == [0, 1, 2, 3, 4, 5]
        q, v, a = model.get_coupled_motion()
        assert np.allclose(q.reshape(2, 3), [[0.0, 0.0, -20.0], [80.0, 0.0, -20.0]])
        # held at rest: the two ends carry the weight and mirror each other
        for _ in range(5):
            model.step(DT, q, v, a)
        f = model.calc_output().reshape(2, 3)
        print(f"held: End A {f[0]}, End B {f[1]} N; w L / 2 = {W_SUB * LENGTH / 2:.6e} N")
        assert f[0, 2] == pytest.approx(-W_SUB * LENGTH / 2.0, rel=1.0e-6)
        assert f[1, 2] == pytest.approx(f[0, 2], rel=1.0e-8)
        assert f[1, 0] == pytest.approx(-f[0, 0], rel=1.0e-8)
        assert np.all(np.abs(model.coupled_moments()) <= 1.0e-6)
        # End A equals the same line with a Fixed End B (the established route) at End A
        with CableDyn() as fixed:
            fixed.init_deck(_deck(tmp_path, "Fixed"))
            assert fixed.coupled_layout() == ((1, "coupled"),)
            qf, vf, af = fixed.get_coupled_motion()
            for _ in range(5):
                fixed.step(DT, qf, vf, af)
            ff = fixed.calc_output()
        print(f"End A load, two moving ends {f[0]}, Fixed End B {ff} N")
        assert np.allclose(f[0], ff, rtol=0.0, atol=1.0e-6 * np.linalg.norm(ff))


def test_the_end_b_block_is_driven(tmp_path):
    with CableDyn() as model:
        model.init_deck(_deck(tmp_path, "Coupled"))
        q, v, a = model.get_coupled_motion()
        model.step(DT, q, v, a)
        f0 = model.calc_output().copy()
        n_move = 40
        for k in range(1, n_move + 1):
            qk = q.copy()
            qk[3] += 2.0 * 0.5 * (1.0 - math.cos(math.pi * k / n_move))
            vk = np.zeros(6)
            vk[3] = math.pi / (n_move * DT) * math.sin(math.pi * k / n_move)
            ak = np.zeros(6)
            ak[3] = (math.pi / (n_move * DT)) ** 2 * math.cos(math.pi * k / n_move)
            model.step(DT, qk, vk, ak)
        q1, _, _ = model.get_coupled_motion()
        assert np.array_equal(q1, qk)
        assert q1[3] == pytest.approx(82.0)
        f1 = model.calc_output()
        print(f"End B surged 2 m: end loads {f0} -> {f1} N")
        assert np.max(np.abs(f1 - f0)) > 0.01 * np.max(np.abs(f0))
