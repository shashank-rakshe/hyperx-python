# SPDX-License-Identifier: Apache-2.0
"""Host rotations (C ABI 1 minor extension 3): a host that turns its coupled points.

The deck is the straight neutral torsion line of test_coupled_torsion: GJ 5e4 N m^2,
100 m along +x from the Coupled fairlead (0, 0, -50) to a Fixed anchor, both ends
clamped and restrained in torsion, a negligible polar inertia (the quasi-static
torsion). Rolling the fairlead by phi about the line axis twists the line by -phi,
and the line returns the torque GJ phi / L to the host about that axis. With End B on a
second Coupled point (a line between two moving points) the host turns both end frames:
rolling End A by +phi and End B by -phi about the line twists it by -2 phi, and each end
returns its share of the torque to its own block.
"""

from __future__ import annotations

import math
from pathlib import Path

import numpy as np
import pytest

try:
    import cabledyn._lib  # loads the shared library
except (ImportError, OSError) as exc:  # a missing library raises OSError
    pytest.skip(f"CableDyn shared library not available: {exc}", allow_module_level=True)

import cabledyn
from cabledyn import _lib
from cabledyn.errors import CableDynError
from cabledyn.model import CableDyn

GJ = 5.0e4
LENGTH = 100.0
DT = 0.05
BOX = Path(__file__).resolve().parents[2] / "tests" / "data" / "foam_esflowc_box_points.dat"


def _deck(tmp_path: Path, tors: str = "Rigid", end_b: str = "Fixed") -> Path:
    mass = 1025.0 * 0.25 * math.pi * 0.04
    outputs = "Torq1N1\nTorq1N41\nTwist1\n" if tors != "Free" else "FairTen1\n"
    text = (
        "host rotation gate\n--- LINE TYPES ---\n"
        "Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat\n"
        "(-) (m) (kg/m) (N) (-) (Nm2) (N) (Nm2) (kgm) (kgm) (-) (-) (-) (-)\n"
        f"cab 0.2 {mass:.16e} 1.0e7 0.0 1.0e6 1.0e8 5.0e4 1.0 1.0e-9 0.0 0.0 0.0 0.0\n"
        "--- POINTS ---\nID Type X Y Z Mass Vol CdA Ca\n(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)\n"
        f"1 Coupled 0.0 0.0 -50.0 0 0 0 0\n2 {end_b} 100.0 0.0 -50.0 0 0 0 0\n"
        "--- LINES ---\nID NodeA NodeB Outputs\n(-) (-) (-) (-)\n1 1 2 -\n"
        "--- SECTIONS ---\nLineID LineType Length NumSegs\n(-) (-) (m) (-)\n1 cab 100.0 40\n"
        "--- END CONNECTIONS ---\n"
        "LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist\n"
        "(-) (-) (N-m/rad) (-) (-) (-) (N-m/rad) (-) (-) (-) (deg)\n"
        f"1 A Rigid 1 0 0 {tors} 0 0 1 0\n1 B Rigid 1 0 0 {tors} 0 0 1 0\n"
        "--- OPTIONS ---\n9.80665 g\n1025.0 rhoW\n0.05 dtM\n0.0 TMax\n"
        f"--- OUTPUTS ---\n{outputs}--- END ---\n"
    )
    path = tmp_path / f"rotation_{tors.lower()}_{end_b.lower()}.dat"
    path.write_text(text, encoding="utf-8")
    return path


def _roll(phi: float) -> np.ndarray:
    """OpenFAST mesh orientation (global to local) of a roll phi about +x, (1, 3, 3)."""
    c, s = math.cos(phi), math.sin(phi)
    return np.array([[[1.0, 0.0, 0.0], [0.0, c, s], [0.0, -s, c]]])


def test_abi_minor_reports_the_host_rotation_extension():
    assert _lib.HOST_ROTATION_ABI_MINOR == 3
    assert _lib.abi_minor() == cabledyn.abi_minor() >= _lib.HOST_ROTATION_ABI_MINOR


def test_torsion_deck_needs_the_rotating_initialization(tmp_path):
    deck = _deck(tmp_path)
    with CableDyn() as model:
        with pytest.raises(CableDynError, match="CableDyn_InitDeckRotating"):
            model.init_deck(deck)
        model.init_deck_rotating(deck)
        assert model.n_coupled_dof == 3
        assert np.all(np.abs(model.coupled_moments()) <= 1.0e-6)


def test_rolling_host_gets_the_quasi_static_torque(tmp_path):
    rate = math.radians(60.0)
    with CableDyn() as model:
        model.init_deck_rotating(_deck(tmp_path))
        q, v, a = model.get_coupled_motion()
        for k in range(1, 11):
            phi = rate * DT * k
            model.update_rotations(_roll(phi), [[rate, 0.0, 0.0]], np.zeros((1, 3)))
            model.step(DT, q, v, a)
            m = model.coupled_moments()
            assert m[0] == pytest.approx(-GJ * phi / LENGTH, abs=1.0e-6 * GJ)
            assert abs(m[1]) <= 1.0e-6 * GJ and abs(m[2]) <= 1.0e-6 * GJ
            assert model.channel("Twist1") == pytest.approx(-math.degrees(phi), abs=1.0e-6)


def test_save_restore_carries_the_rotations(tmp_path):
    rate = math.radians(60.0)
    with CableDyn() as model:
        model.init_deck_rotating(_deck(tmp_path))
        q, v, a = model.get_coupled_motion()
        model.update_rotations(_roll(rate * DT), [[rate, 0.0, 0.0]], np.zeros((1, 3)))
        model.save_state()
        model.step(DT, q, v, a)
        first = model.coupled_moments()
        model.update_rotations(_roll(0.5), [[0.0, 0.0, 0.0]], np.zeros((1, 3)))
        model.restore_state()
        model.step(DT, q, v, a)
        assert np.array_equal(model.coupled_moments(), first)


def test_rotation_input_is_checked(tmp_path):
    with CableDyn() as model:
        model.init_deck_rotating(_deck(tmp_path))
        with pytest.raises(ValueError, match="dcm must be shaped"):
            model.update_rotations(np.eye(3), np.zeros((1, 3)), np.zeros((1, 3)))
        with pytest.raises(CableDynError, match="proper orthogonal"):
            model.update_rotations(1.01 * _roll(0.1), np.zeros((1, 3)), np.zeros((1, 3)))
    with CableDyn() as model:
        model.init_deck(_deck(tmp_path, "Free"))
        with pytest.raises(CableDynError, match="CableDyn_InitDeckRotating"):
            model.update_rotations(_roll(0.1), np.zeros((1, 3)), np.zeros((1, 3)))


def test_point_route_takes_rotations_and_returns_no_moment():
    with CableDyn() as model:
        model.init_deck_rotating(BOX)
        nb = model.n_coupled_dof // 3
        dcm = np.repeat(_roll(0.3), nb, axis=0)
        model.update_rotations(dcm, np.zeros((nb, 3)), np.zeros((nb, 3)))
        assert np.array_equal(model.coupled_moments(), np.zeros(3 * nb))


def test_host_turns_both_end_frames_of_a_line_between_two_coupled_points(tmp_path):
    # End B is a second host-driven block: its rotation turns End B's torsion frame
    rate = math.radians(60.0)
    with CableDyn() as model:
        model.init_deck_rotating(_deck(tmp_path, end_b="Coupled"))
        assert model.n_coupled_dof == 6
        q, v, a = model.get_coupled_motion()
        for k in range(1, 11):
            phi = rate * DT * k
            dcm = np.concatenate([_roll(phi), _roll(-phi)])
            model.update_rotations(dcm, [[rate, 0.0, 0.0], [-rate, 0.0, 0.0]], np.zeros((2, 3)))
            model.step(DT, q, v, a)
            m = model.coupled_moments()
            torque = GJ * 2.0 * phi / LENGTH
            assert m[0] == pytest.approx(-torque, abs=1.0e-6 * GJ)
            assert m[3] == pytest.approx(torque, abs=1.0e-6 * GJ)
            assert np.all(np.abs(m[[1, 2, 4, 5]]) <= 1.0e-6 * GJ)
            assert model.channel("Twist1") == pytest.approx(-math.degrees(2.0 * phi), abs=1.0e-6)
        # equal rolls of both ends are a rigid roll of the line: the torque returns to zero
        dcm = np.concatenate([_roll(0.3), _roll(0.3)])
        for _ in range(3):
            model.update_rotations(dcm, np.zeros((2, 3)), np.zeros((2, 3)))
            model.step(DT, q, v, a)
        assert np.all(np.abs(model.coupled_moments()) <= 1.0e-6 * GJ)
