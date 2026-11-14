# SPDX-License-Identifier: Apache-2.0
"""Host coupling (C ABI 1 minor extension 2): init at host positions, save/restore, layout.

The point-route deck is the foamMooring EsfLOWC box (four slack EI=0 lines), whose
fairleads sit at z = -0.062 m in the deck while the CFD box starts with them at
z = -0.077 m. The aggregate-route deck is an EI=0 chain plus a finite-EI cable.
"""

from __future__ import annotations

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

DATA = Path(__file__).resolve().parents[2] / "tests" / "data"
BOX = DATA / "foam_esflowc_box_points.dat"
MIXED = DATA / "host_coupling_chain_cable.dat"

#: The box fairleads (points 5-8) at the CFD start height, column per point.
BOX_FAIRLEADS = np.array(
    [[-0.1, 0.1, -0.077], [-0.1, -0.1, -0.077], [0.1, 0.1, -0.077], [0.1, -0.1, -0.077]]
).T


def _motion(model: CableDyn, q0: np.ndarray, amp: float, t: float):
    """A smooth surge/heave of the host-driven blocks about q0 at time t."""
    w = 2.0 * np.pi
    q, v, a = q0.copy(), np.zeros_like(q0), np.zeros_like(q0)
    dofs = model.host_dofs().reshape(-1, 3)
    q[dofs[:, 0]] += amp * np.sin(w * t)
    v[dofs[:, 0]] = amp * w * np.cos(w * t)
    a[dofs[:, 0]] = -amp * w * w * np.sin(w * t)
    q[dofs[:, 2]] += 0.5 * amp * (1.0 - np.cos(w * t))
    v[dofs[:, 2]] = 0.5 * amp * w * np.sin(w * t)
    a[dofs[:, 2]] = 0.5 * amp * w * w * np.cos(w * t)
    return q, v, a


def test_abi_minor_reports_the_host_coupling_extension():
    assert _lib.HOST_COUPLING_ABI_MINOR == 2
    assert _lib.abi_minor() == cabledyn.abi_minor() >= _lib.HOST_COUPLING_ABI_MINOR


def test_point_route_layout():
    with CableDyn(BOX) as model:
        layout = model.coupled_layout()
        assert layout == tuple((p, "fixed") for p in (1, 2, 3, 4)) + tuple(
            (p, "coupled") for p in (5, 6, 7, 8)
        )
        assert model.host_dofs().tolist() == list(range(12, 24))


def test_init_deck_at_host_positions_has_no_transient():
    with CableDyn() as model:
        model.init_deck_at(BOX, BOX_FAIRLEADS)
        assert model.n_coupled_dof == 24
        q, v, a = model.get_coupled_motion()
        assert np.array_equal(q[model.host_dofs()], BOX_FAIRLEADS.reshape(-1, order="F"))
        assert not v.any() and not a.any()
        f0 = model.calc_output()
        # line 4's fairlead: the standalone statics of the deck moved to z = -0.077
        np.testing.assert_allclose(f0[21:24], [0.3026, -0.0761, -0.4114], atol=1.0e-4)
        for _ in range(200):
            model.step(1.0e-3, q, v, a)
        assert np.max(np.abs(model.calc_output() - f0)) < 1.0e-9
        assert model.time == pytest.approx(0.2)

    # the same statics from the full coupled vector (the Fixed blocks are not read)
    full = q.copy()
    full[:12] = 1.0e3
    with CableDyn() as other:
        other.init_deck_at(BOX, full)
        assert np.array_equal(other.calc_output(), f0)

    # InitDeck at the deck positions rings when the host holds the fairleads lower
    with CableDyn(BOX) as plain:
        peak = 0.0
        for _ in range(200):
            plain.step(1.0e-3, q, v, a)
            peak = max(peak, float(np.max(np.abs(plain.calc_output() - f0))))
        assert peak > 1.0e-2


def test_point_route_order_follows_the_points_table(tmp_path):
    """Coupled rows listed before the Fixed ones: the blocks follow the POINTS table order."""
    lines = BOX.read_text(encoding="utf-8").splitlines()
    rows = [i for i, ln in enumerate(lines) if ln.split()[:2] in (["1", "Fixed"], ["5", "Coupled"])]
    fixed_at, coupled_at = rows[0], rows[1]
    reordered = (
        lines[:fixed_at]
        + lines[coupled_at : coupled_at + 4]
        + lines[fixed_at : fixed_at + 4]
        + lines[coupled_at + 4 :]
    )
    deck = tmp_path / "box_reordered.dat"
    deck.write_text("\n".join(reordered) + "\n", encoding="utf-8")
    with CableDyn() as model:
        model.init_deck_at(deck, BOX_FAIRLEADS)
        assert model.coupled_layout() == tuple((p, "coupled") for p in (5, 6, 7, 8)) + tuple(
            (p, "fixed") for p in (1, 2, 3, 4)
        )
        assert model.host_dofs().tolist() == list(range(12))
        f = model.calc_output()
        # line 4's fairlead (point 8) is block 3 now
        np.testing.assert_allclose(f[9:12], [0.3026, -0.0761, -0.4114], atol=1.0e-4)


def test_init_deck_at_rejections_keep_the_model():
    with CableDyn(BOX) as model:
        before = model.calc_output()
        with pytest.raises(CableDynError, match="coupled_positions"):
            model.init_deck_at(BOX, BOX_FAIRLEADS[:, :3].reshape(-1, order="F"))
        with pytest.raises(ValueError, match="ambiguous"):
            model.init_deck_at(BOX, BOX_FAIRLEADS[:, :3])
        with pytest.raises(ValueError, match="finite"):
            model.init_deck_at(BOX, np.full(12, np.nan))
        with pytest.raises(ValueError, match="3 \\* n"):
            model.init_deck_at(BOX, np.zeros(13))
        assert np.array_equal(model.calc_output(), before)


@pytest.mark.parametrize(
    ("deck", "q_host", "dt", "amp"),
    [(BOX, BOX_FAIRLEADS, 1.0e-3, 0.005), (MIXED, None, 0.01, 0.2)],
    ids=["point-route", "aggregate-route"],
)
def test_save_restore_is_bit_identical(deck, q_host, dt, amp):
    with CableDyn(deck) as model, CableDyn(deck) as ref:
        if q_host is not None:
            model.init_deck_at(deck, q_host)
            ref.init_deck_at(deck, q_host)
        q0, _, _ = model.get_coupled_motion()
        with pytest.raises(CableDynError, match="no state has been saved"):
            model.restore_state()
        model.save_state()
        for corrector in (1, 2):  # two outer correctors that try other motions
            for s in range(1, 6):
                model.step(dt, *_motion(model, q0, 2.0 * corrector * amp, s * dt))
            model.restore_state()
            assert model.time == 0.0
        for s in range(1, 8):
            motion = _motion(model, q0, amp, s * dt)
            model.step(dt, *motion)
            ref.step(dt, *motion)
            assert np.array_equal(model.calc_output(), ref.calc_output())
            for x, y in zip(model.get_coupled_motion(), ref.get_coupled_motion(), strict=True):
                assert np.array_equal(x, y)
        for line, line_ref in zip(model.lines, ref.lines, strict=True):
            assert np.array_equal(line.node_positions(), line_ref.node_positions())
        assert model.time == pytest.approx(ref.time)
        # a new initialization discards the save
        model.init_deck(deck)
        with pytest.raises(CableDynError, match="no state has been saved"):
            model.restore_state()


def test_a_failed_initialization_keeps_the_save(tmp_path):
    """A failed init_deck/init_deck_at keeps the model and its save; restore still works."""
    dt = 1.0e-3
    with CableDyn() as model, CableDyn() as ref:
        model.init_deck_at(BOX, BOX_FAIRLEADS)
        ref.init_deck_at(BOX, BOX_FAIRLEADS)
        q0, _, _ = model.get_coupled_motion()
        model.save_state()
        model.step(dt, *_motion(model, q0, 0.02, dt))
        with pytest.raises(CableDynError):
            model.init_deck(tmp_path / "missing.dat")
        with pytest.raises(CableDynError, match="coupled_positions"):
            model.init_deck_at(BOX, BOX_FAIRLEADS[:, :2])
        with pytest.raises(ValueError, match="column-per-point"):
            model.init_deck_at(BOX, BOX_FAIRLEADS.T)  # (4, 3): row per point
        model.restore_state()
        assert model.time == 0.0
        for s in range(1, 4):
            motion = _motion(model, q0, 0.005, s * dt)
            model.step(dt, *motion)
            ref.step(dt, *motion)
            assert np.array_equal(model.calc_output(), ref.calc_output())


def test_aggregate_layout_holds_only_the_coupled_points():
    with CableDyn(MIXED) as model:
        assert model.coupled_layout() == ((2, "coupled"), (4, "coupled"))
        assert model.host_dofs().tolist() == list(range(6))


def test_an_uninitialized_handle_has_nothing_to_save():
    with CableDyn() as model:
        with pytest.raises(CableDynError, match="NOT_INITIALIZED"):
            model.save_state()


def test_an_old_library_fails_clearly(monkeypatch):
    monkeypatch.setattr(_lib, "abi_minor", lambda: 1)
    with CableDyn(BOX) as model:
        with pytest.raises(RuntimeError, match="predates the host-coupling calls"):
            model.save_state()
        with pytest.raises(RuntimeError, match="predates the host-coupling calls"):
            model.init_deck_at(BOX, BOX_FAIRLEADS)
