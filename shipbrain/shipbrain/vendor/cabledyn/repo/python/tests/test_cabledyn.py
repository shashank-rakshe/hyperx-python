# File: python/tests/test_cabledyn.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Gate for the cabledyn Python package: the ctypes layer over the C ABI.

Runs against the built shared library (CABLEDYN_LIBRARY or the repo build tree)
and the committed IEA-15MW VolturnUS-S mooring example. The physics assertions
pin the Python path to the SAME numbers the Fortran L2 gate certifies, so a
binding-layer defect (wrong prototype, transposed array, dropped DOF) shows up
as a physics mismatch, not just a crash.
"""

from __future__ import annotations

import os
from pathlib import Path

import numpy as np
import pytest

cabledyn = pytest.importorskip("cabledyn")
try:
    import cabledyn._lib  # loads the shared library
except (ImportError, OSError) as exc:  # a missing library raises OSError
    pytest.skip(f"CableDyn shared library not available: {exc}", allow_module_level=True)

REPO = Path(__file__).resolve().parent.parent.parent
VOLTURNUS_DECK = REPO / "examples" / "iea15mw_volturnus_mooring.dat"

# The l2_volturnus_mooring gate's certified static fairlead tension band (N): the
# all-chain catenary solves to ~2.44 MN at each of the three fairleads (1.28% vs
# OrcaFlex). The Python path must land in the same physical band.
FAIRLEAD_TENSION_LO = 1.0e6
FAIRLEAD_TENSION_HI = 5.0e6


def test_version_and_abi():
    *_, abi = cabledyn._lib.version()
    assert abi == cabledyn._lib.SUPPORTED_ABI
    assert "CableDyn" in cabledyn.version_string()
    assert Path(cabledyn.library_path()).is_file()


def test_create_close_idempotent():
    m = cabledyn.CableDyn()
    assert not m.initialized
    m.close()
    m.close()  # idempotent


def test_uninitialized_queries_fail_closed():
    with cabledyn.CableDyn() as m:
        with pytest.raises(cabledyn.CableDynError):
            _ = m.n_coupled_dof


def test_missing_deck_fails_closed():
    with cabledyn.CableDyn() as m:
        with pytest.raises(cabledyn.CableDynError):
            m.init_deck("no_such_deck_anywhere.dat")
        assert not m.initialized


@pytest.mark.skipif(not VOLTURNUS_DECK.is_file(), reason="repo example deck not present")
def test_volturnus_static_and_dynamics():
    with cabledyn.CableDyn(VOLTURNUS_DECK) as m:
        assert m.initialized
        # the committed example is ONE line of the symmetric three-line spread:
        # a Coupled fairlead (z = -14 m) and a Fixed anchor (z = -200 m). The
        # coupled boundary spans EVERY host-held point (the host prescribes the
        # anchor too; it simply never moves) -- 2 points x 3 DOFs.
        assert m.n_lines == 1
        assert m.n_points == 2
        n = m.n_coupled_dof
        assert n == 6

        q, v, a = m.get_coupled_motion()
        assert q.shape == (n,)
        assert np.all(np.isfinite(q))
        z = q.reshape(3, -1, order="F")[2, :]
        fair = np.isclose(z, -14.0, atol=1e-6)
        anch = np.isclose(z, -200.0, atol=1e-6)
        assert fair.sum() == 1 and anch.sum() == 1

        # static loads: physical fairlead pull, dominated by the catenary weight --
        # the l2_volturnus_mooring gate certifies ~2.44 MN at this fairlead
        m.update_states(q, v, a)
        loads = m.calc_output()
        per_pt = loads.reshape(3, -1, order="F")
        fair_mag = float(np.linalg.norm(per_pt[:, fair]))
        assert FAIRLEAD_TENSION_LO < fair_mag < FAIRLEAD_TENSION_HI
        # the fairlead is pulled DOWN by the hanging chain
        assert float(per_pt[2, fair][0]) < 0.0
        assert np.all(np.isfinite(per_pt[:, anch]))

        # dynamics: a held platform is a fixed point -- 20 implicit steps at the
        # production dt change nothing (the static IC is the dynamic equilibrium)
        q0 = q.copy()
        for _ in range(20):
            nit = m.step(0.1, q0, np.zeros(n), np.zeros(n))
            assert nit >= 0
        q1, _, _ = m.get_coupled_motion()
        assert np.allclose(q1, q0, atol=1e-9)
        loads_after = m.calc_output()
        assert np.allclose(loads_after, loads, rtol=1e-6, atol=1.0)

        # a prescribed heave changes the loads (the coupling is live)
        qh = q0.copy()
        qh[2::3] += 0.5
        vh = np.zeros(n)
        vh[2::3] = 0.5 / 0.1
        m.step(0.1, qh, vh, np.zeros(n))
        loads_heave = m.calc_output()
        assert not np.allclose(loads_heave, loads, rtol=1e-4)


@pytest.mark.skipif(not VOLTURNUS_DECK.is_file(), reason="repo example deck not present")
def test_column_shaped_arrays_accepted():
    with cabledyn.CableDyn(VOLTURNUS_DECK) as m:
        n = m.n_coupled_dof
        q, v, a = m.get_coupled_motion()
        cols = q.reshape(3, -1, order="F")
        m.update_states(cols, v.reshape(3, -1, order="F"), a.reshape(3, -1, order="F"))
        loads = m.calc_output()
        assert loads.shape == (n,)


def test_deck_writer_roundtrip(tmp_path):
    deck = cabledyn.DeckWriter(title="single grounded chain, writer round-trip")
    deck.add_line_type(
        "main", diam=0.333, mass=685.0, ea=3.27e9, ba=-1.0, cdn=2.0, cdt=0.4, can=0.82, cat=0.27
    )
    deck.add_point(1, "Vessel", -58.0, 0.0, -14.0)
    deck.add_point(2, "Fixed", -837.6, 0.0, -200.0)
    deck.add_line(1, node_a=1, node_b=2)
    deck.add_section(line_id=1, line_type="main", length=850.0, num_segs=20)
    deck.set_option("9.80665", "g", "Gravitational acceleration (m/s^2)")
    deck.set_option("1025.0", "rhoW")
    deck.set_option("200.0", "WtrDpth")
    deck.set_option(False, "adaptive_mesh", "Enable adaptive mesh refinement {True, False}")
    deck.add_output("FairTen1")
    path = deck.write(tmp_path / "writer_chain.dat")

    text = path.read_text(encoding="ascii")
    assert text.startswith("--------------------- CableDyn Input File ")
    assert "9.80665 g - Gravitational acceleration (m/s^2)" in text
    assert "False adaptive_mesh - Enable adaptive mesh refinement {True, False}" in text
    assert '\n"FairTen1"\n' in text

    with cabledyn.CableDyn(path) as m:
        assert m.initialized
        assert m.n_lines == 1
        assert m.n_coupled_dof == 6  # both boundary points (fairlead + anchor) x 3
        m.update_states(*m.get_coupled_motion())
        loads = m.calc_output()
        assert np.isfinite(loads).all()
        assert np.linalg.norm(loads) > 1.0e4  # a heavy grounded chain pulls hard


def test_deck_writer_validation():
    deck = cabledyn.DeckWriter()
    with pytest.raises(ValueError):
        deck.add_point(1, "NotAType", 0, 0, 0)
    with pytest.raises(ValueError):
        deck.add_section(line_id=1, line_type="main", length=10.0, num_segs=0)
    with pytest.raises(ValueError):
        deck.set_option("1.0", "not a keyword")
    with pytest.raises(ValueError):
        deck.set_option("1.0", "g", "first row\nsecond row")
    with pytest.raises(ValueError):
        deck.add_output("FairTen1 Point2pz")
    with pytest.raises(ValueError):
        deck.text()  # empty deck


def test_deck_path_with_nul_is_rejected_before_the_library():
    with cabledyn.CableDyn() as m:
        with pytest.raises(ValueError, match="NUL"):
            m.init_deck(str(VOLTURNUS_DECK) + "\0ignored.dat")
        assert not m.initialized


@pytest.mark.skipif(not VOLTURNUS_DECK.is_file(), reason="repo example deck not present")
def test_non_ascii_deck_directory_is_opened(tmp_path):
    names = ("케이블", "câble", "кабель")
    if os.name == "nt":
        # The Fortran runtime opens files through the active ANSI code page.
        names = tuple(name for name in names if _encodable(str(tmp_path / name), "mbcs"))
    if not names:
        pytest.skip("no non-ASCII test name is representable in the active code page")
    folder = tmp_path / names[0]
    folder.mkdir()
    deck = folder / VOLTURNUS_DECK.name
    deck.write_bytes(VOLTURNUS_DECK.read_bytes())
    with cabledyn.CableDyn(deck) as m:
        assert m.initialized


def _encodable(text: str, encoding: str) -> bool:
    try:
        text.encode(encoding)
    except UnicodeEncodeError:
        return False
    return True


@pytest.mark.skipif(not VOLTURNUS_DECK.is_file(), reason="repo example deck not present")
def test_failed_reinitialization_keeps_the_previous_model():
    with cabledyn.CableDyn(VOLTURNUS_DECK) as m:
        before = m.n_coupled_dof
        with pytest.raises(cabledyn.CableDynError):
            m.init_deck("no_such_deck_anywhere.dat")
        assert m.initialized
        assert m.n_coupled_dof == before


def test_error_types_import_without_loading_the_library():
    from cabledyn.errors import CableDynError, ConvergenceError

    assert issubclass(ConvergenceError, CableDynError)
    error = ConvergenceError("CableDyn_Step", "tolerance not met", n_iter=40, stalled=True)
    assert error.status == 4 and error.n_iter == 40 and error.stalled


@pytest.mark.parametrize("dt", [1e-101, 1e-160, 1e-300, 5e-324])
def test_a_step_below_the_smallest_time_step_is_named(dt):
    # the implicit march divides by dt^2: below 1e-100 s the step is refused by name, not left
    # to overflow inside the line solve
    with cabledyn.CableDyn(VOLTURNUS_DECK) as m:
        q, v, a = m.get_coupled_motion()
        before = m.calc_output()
        with pytest.raises(
            cabledyn.CableDynError, match=r"below the smallest time step, 1e-100 s"
        ) as err:
            m.step(dt, q, v, a)
        assert "BAD_INPUT" in str(err.value)
        assert np.array_equal(m.calc_output(), before)
        m.step(1e-100, q, v, a)  # the bound itself steps
        assert np.all(np.isfinite(m.calc_output()))
    with cabledyn.CableDyn() as m:
        m.init_line(
            [0, 0, 0, 1, 0, 0, 2, 0, 0],
            np.zeros(9),
            [1, 2, 2, 3],
            [1.0, 1.0],
            [1e6, 1e6],
            [1.0, 1.0],
            [1, 2, 3, 7, 8, 9],
            False,
            0.5,
        )
        with pytest.raises(cabledyn.CableDynError, match=r"below the smallest time step, 1e-100 s"):
            m.step(dt, [0, 0, 0, 2, 0, 0], np.zeros(6), np.zeros(6))
