# SPDX-License-Identifier: Apache-2.0
"""Raw-array lines and load Jacobians through the binding, against the C behaviour.

A raw line carries no gravity, seabed or hydrodynamics, so the decks that it must reproduce set
a negligible ``g`` and ``rhoW`` (both must be positive) and no drag or added mass. Skipped when the
library cannot be loaded (set ``CABLEDYN_LIBRARY``).
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

try:
    from cabledyn import model as model_module  # loads the shared library
except (ImportError, OSError) as exc:  # a missing library raises OSError
    pytest.skip(f"CableDyn shared library not available: {exc}", allow_module_level=True)

from cabledyn import CableDyn
from cabledyn.errors import CableDynError

REPO = Path(__file__).resolve().parents[2]
VOLTURNUS = REPO / "examples" / "iea15mw_volturnus_mooring.dat"
BAR = "-" * 21
BAD_INPUT = 3

LENGTH, N_ELEM, EA, MASS, RHO_INF = 100.0, 10, 1.0e7, 50.0, 0.4
SPAN = 100.5
TENSION = EA * (SPAN / LENGTH - 1.0)


def line_deck(
    tmp_path: Path, rows: tuple[str, ...] = ("1 1 2 -",), rho_inf: float = RHO_INF
) -> Path:
    """Taut lines from the Coupled point 1 to the Fixed points 2 and 3, in deck form."""
    sections = "\n".join(f"{row.split()[0]} cab {LENGTH} {N_ELEM}" for row in rows)
    deck = tmp_path / "taut.dat"
    deck.write_text(
        f"""{BAR} CableDyn Input File {BAR}
taut lines without weight
{BAR} LINE TYPES {BAR}
Name Diam Mass EA BA EI Cdn Cdt Can Cat
cab 0.1 {MASS} {EA} 0.0 0.0 0.0 0.0 0.0 0.0
{BAR} POINTS {BAR}
ID Type X Y Z
1 Coupled 0.0 0.0 -10.0
2 Fixed {SPAN} 0.0 -10.0
3 Fixed 0.0 {SPAN} -10.0
{BAR} LINES {BAR}
ID NodeA NodeB Outputs
{chr(10).join(rows)}
{BAR} SECTIONS {BAR}
LineID LineType Length NumSegs
{sections}
{BAR} OPTIONS {BAR}
1.0e-9 g
1.0e-9 rhoW
500.0 WtrDpth
{rho_inf} rhoInf
{BAR} OUTPUTS {BAR}
FairTen1
{BAR} need this line {BAR}
""",
        encoding="utf-8",
    )
    return deck


def straight(end: tuple[float, float, float], n_elem: int = N_ELEM) -> np.ndarray:
    """Flat node positions of a straight line from (0, 0, -10) to ``end``."""
    start = np.array([0.0, 0.0, -10.0])
    weights = np.linspace(0.0, 1.0, n_elem + 1)[:, None]
    return (start + weights * (np.array(end) - start)).reshape(-1)


def chain_conn(n_elem: int = N_ELEM) -> np.ndarray:
    """The 1-based node pairs of a chain of elements, one row per element."""
    first = np.arange(1, n_elem + 1)
    return np.column_stack([first, first + 1])


def end_dofs(n_elem: int = N_ELEM) -> list[int]:
    """The 1-based DOFs of the two end nodes."""
    last = 3 * n_elem
    return [1, 2, 3, last + 1, last + 2, last + 3]


def element_values(value: float, n_elem: int = N_ELEM) -> np.ndarray:
    return np.full(n_elem, value)


def init_taut(
    model: CableDyn,
    end: tuple[float, float, float] = (SPAN, 0.0, -10.0),
    *,
    tension_only: bool = True,
    fixed: list[int] | None = None,
    rho_inf: float = RHO_INF,
) -> np.ndarray:
    q0 = straight(end)
    model.init_line(
        q0,
        np.zeros_like(q0),
        chain_conn(),
        element_values(LENGTH / N_ELEM),
        element_values(EA),
        element_values(MASS),
        end_dofs() if fixed is None else fixed,
        tension_only,
        rho_inf,
    )
    return q0


def fairlead_motion(q: np.ndarray, time: float) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """A smooth motion of the first coupled block away from ``q``, in x and in y."""
    omega = 2.0 * np.pi / 2.0
    position, velocity, acceleration = q.copy(), np.zeros_like(q), np.zeros_like(q)
    for axis, amplitude in ((0, 0.2), (1, 0.5)):
        position[axis] += amplitude * (1.0 - np.cos(omega * time))
        velocity[axis] = amplitude * omega * np.sin(omega * time)
        acceleration[axis] = amplitude * omega**2 * np.cos(omega * time)
    return position, velocity, acceleration


@pytest.mark.parametrize("rho_inf", [0.0, 0.4, 0.8])
def test_a_raw_line_matches_the_same_line_from_a_deck(tmp_path, rho_inf):
    with CableDyn(line_deck(tmp_path, rho_inf=rho_inf)) as deck, CableDyn() as raw:
        init_taut(raw, rho_inf=rho_inf)
        assert raw.initialized and raw.n_coupled_dof == 6 and raw.n_lines == 1
        assert raw.deck is None and raw.n_points == 0

        q_deck, _, _ = deck.get_coupled_motion()
        q_raw, v_raw, a_raw = raw.get_coupled_motion()
        assert q_raw == pytest.approx(q_deck, abs=1e-9)
        assert not np.any(v_raw) and not np.any(a_raw)
        assert raw.calc_output() == pytest.approx(deck.calc_output(), abs=1e-4)
        assert raw.calc_output()[0] == pytest.approx(TENSION, rel=1e-12)

        dt = 0.01
        for step in range(1, 201):
            motion = fairlead_motion(q_raw, step * dt)
            deck.step(dt, *motion)
            raw.step(dt, *motion)
        loads = deck.calc_output()
        assert np.max(np.abs(loads - TENSION * np.array([1, 0, 0, -1, 0, 0]))) > 100.0
        assert raw.calc_output() == pytest.approx(loads, rel=1e-8, abs=1e-3)
        # The views run from the last node of the arrays, the End A of a deck model's arrays.
        assert raw.lines[0].node_positions()[::-1] == pytest.approx(
            deck.lines[0].node_positions(), abs=1e-8
        )
        assert raw.time == pytest.approx(deck.time)


def shared_arrays() -> dict[str, np.ndarray]:
    """Two lines of the shared-point system, as ``init_lines`` takes them."""
    q0 = np.concatenate([straight((SPAN, 0.0, -10.0)), straight((0.0, SPAN, -10.0))])
    fixed = end_dofs() + end_dofs()
    return {
        "n_nodes": np.array([N_ELEM + 1] * 2),
        "n_elem": np.array([N_ELEM] * 2),
        "n_fixed": np.array([6, 6]),
        "q0": q0,
        "v0": np.zeros_like(q0),
        "elem_conn": np.concatenate([chain_conn(), chain_conn()]),
        "l0": element_values(LENGTH / N_ELEM, 2 * N_ELEM),
        "ea": element_values(EA, 2 * N_ELEM),
        "rho_a": element_values(MASS, 2 * N_ELEM),
        "fixed_dofs": np.array(fixed),
    }


def test_shared_points_of_raw_lines_match_a_deck(tmp_path):
    deck_file = line_deck(tmp_path, ("1 1 2 -", "2 1 3 -"))
    with CableDyn(deck_file) as deck, CableDyn() as raw:
        raw.init_lines(
            **shared_arrays(),
            tension_only=True,
            rho_inf=RHO_INF,
            coupled_map=[1, 2, 3, 4, 5, 6, 1, 2, 3, 7, 8, 9],
        )
        assert raw.n_lines == 2 and raw.n_coupled_dof == 9 == deck.n_coupled_dof
        q, _, _ = raw.get_coupled_motion()
        assert q == pytest.approx(deck.get_coupled_motion()[0], abs=1e-9)
        # The shared point takes the pull of both lines.
        loads = raw.calc_output()
        assert loads[:3] == pytest.approx([TENSION, TENSION, 0.0], rel=1e-12)
        assert loads == pytest.approx(deck.calc_output(), abs=1e-4)
        dt = 0.01
        for step in range(1, 101):
            motion = fairlead_motion(q, step * dt)
            deck.step(dt, *motion)
            raw.step(dt, *motion)
        assert raw.calc_output() == pytest.approx(deck.calc_output(), rel=1e-8, abs=1e-3)


def test_independent_raw_lines_equal_separate_handles():
    arrays = shared_arrays()
    with CableDyn() as both, CableDyn() as first, CableDyn() as second:
        both.init_lines(**arrays, tension_only=True, rho_inf=RHO_INF)
        init_taut(first)
        init_taut(second, (0.0, SPAN, -10.0))
        assert both.n_lines == 2 and both.n_coupled_dof == 12
        q, v, a = both.get_coupled_motion()
        assert q[:6] == pytest.approx(first.get_coupled_motion()[0])
        assert q[6:] == pytest.approx(second.get_coupled_motion()[0])
        moved = q.copy()
        moved[1] += 0.3
        both.step(0.01, moved, v, a)
        first.step(0.01, moved[:6], v[:6], a[:6])
        second.step(0.01, moved[6:], v[6:], a[6:])
        expected = np.concatenate([first.calc_output(), second.calc_output()])
        assert both.calc_output() == pytest.approx(expected, rel=1e-13)


def central_difference(model, q, v, a, block: int, column: int, step: float) -> np.ndarray:
    """d(calc_output)/d(the coupled DOF ``column`` of q, v or a), held as update_states holds it."""
    columns = []
    for sign in (1.0, -1.0):
        state = [q.copy(), v.copy(), a.copy()]
        state[block][column] += sign * step
        model.update_states(*state)
        columns.append(model.calc_output())
    return (columns[0] - columns[1]) / (2.0 * step)


def check_jacobians(model, q, v, a, steps: tuple[float, float, float]) -> list[np.ndarray]:
    loads, dq, dv, da, added = model.calc_output_derivatives(q, v, a)
    n = model.n_coupled_dof
    assert loads.shape == (n,)
    for block in (dq, dv, da, added):
        assert block.shape == (n, n)
    assert added == pytest.approx(-da, abs=0.0)
    model.update_states(q, v, a)
    assert loads == pytest.approx(model.calc_output(), rel=1e-12)
    for index, (jacobian, step) in enumerate(zip((dq, dv, da), steps, strict=True)):
        scale = max(float(np.max(np.abs(jacobian))), 1.0)
        for column in range(n):
            numeric = central_difference(model, q, v, a, index, column, step)
            assert np.max(np.abs(jacobian[:, column] - numeric)) < 2e-6 * scale, (index, column)
    return [dq, dv, da]


@pytest.mark.parametrize(
    ("end", "tension_only"),
    [
        ((SPAN, 0.0, -10.0), True),  # taut along x
        ((70.0, 60.0, 40.0), True),  # sloped, past its length
        ((70.0, 60.0, 30.0), False),  # sloped, nearly at its length
        ((60.0, 50.0, 10.0), False),  # in compression
    ],
)
def test_the_jacobians_of_a_raw_line_match_finite_differences(end, tension_only):
    with CableDyn() as model:
        # The fixed DOFs out of order, the line moving and accelerating.
        init_taut(model, end, tension_only=tension_only, fixed=[33, 1, 2, 31, 3, 32])
        q, _, _ = model.get_coupled_motion()
        rng = np.random.default_rng(7)
        v = rng.uniform(-0.5, 0.5, 6)
        a = rng.uniform(-0.5, 0.5, 6)
        dq, dv, da = check_jacobians(
            model, q + rng.uniform(-0.05, 0.05, 6), v, a, (1e-5, 1e-3, 1e-3)
        )
        assert np.any(dq)
        assert not np.any(dv)  # a raw line has no damping
        # The condensed mass is positive definite.
        assert np.linalg.eigvalsh(-0.5 * (da + da.T)).min() > 0.0


def test_the_jacobians_of_a_shared_point_sum_its_lines():
    with CableDyn() as model:
        model.init_lines(
            **shared_arrays(),
            tension_only=True,
            rho_inf=RHO_INF,
            coupled_map=[1, 2, 3, 4, 5, 6, 1, 2, 3, 7, 8, 9],
        )
        q, _, _ = model.get_coupled_motion()
        rng = np.random.default_rng(3)
        v = rng.uniform(-0.5, 0.5, 9)
        a = rng.uniform(-0.5, 0.5, 9)
        dq, _, da = check_jacobians(model, q, v, a, (1e-5, 1e-3, 1e-3))
        # The far ends of the two lines do not act on each other.
        assert not np.any(dq[3:6, 6:9]) and not np.any(da[3:6, 6:9])
        with CableDyn() as first, CableDyn() as second:
            init_taut(first)
            init_taut(second, (0.0, SPAN, -10.0))
            one = first.calc_output_derivatives(q[:6], v[:6], a[:6])[1]
            two = second.calc_output_derivatives(
                q[[0, 1, 2, 6, 7, 8]], v[[0, 1, 2, 6, 7, 8]], a[[0, 1, 2, 6, 7, 8]]
            )[1]
        assert dq[:3, :3] == pytest.approx(one[:3, :3] + two[:3, :3], rel=1e-12)


def test_the_jacobians_are_read_column_major(monkeypatch):
    """J[i + j*n] of the library is J[i, j] here. The stiffness blocks are nearly symmetric, so
    finite differences could not tell a transposed block; a stand-in writes the flat index."""

    def write_blocks(_handle, _q, _v, _a, n, _eps, loads, *rest):
        *blocks, status = rest
        for number, block in enumerate(blocks, start=1):
            for j in range(n):
                for i in range(n):
                    block[i + j * n] = 1000.0 * number + 10.0 * i + j
        loads[0] = 7.0
        status._obj.value = 0

    with CableDyn() as model:
        init_taut(model)
        q, v, a = model.get_coupled_motion()
        monkeypatch.setattr(model_module._lib, "CableDyn_CalcOutputDerivatives", write_blocks)
        loads, *blocks = model.calc_output_derivatives(q, v, a)
        assert loads[0] == 7.0
        for number, block in enumerate(blocks, start=1):
            assert block[1, 4] == 1000.0 * number + 14.0
            assert block[4, 1] == 1000.0 * number + 41.0


def test_the_jacobians_of_a_deck_with_hydrodynamics_match_finite_differences():
    with CableDyn(VOLTURNUS) as model:
        q, v, a = model.get_coupled_motion()
        rng = np.random.default_rng(11)
        _, dv, da = check_jacobians(
            model,
            q + rng.uniform(-0.02, 0.02, q.size),
            v + rng.uniform(0.2, 0.6, q.size),
            a + rng.uniform(-0.2, 0.2, q.size),
            (1e-5, 1e-5, 1e-3),
        )
        assert np.any(dv) and np.any(da)


def test_calc_output_derivatives_sets_the_state_and_keeps_the_time():
    with CableDyn() as model:
        init_taut(model)
        q, v, a = model.get_coupled_motion()
        model.step(0.01, q, v, a)
        moved = q.copy()
        moved[1] += 0.1
        velocity = np.full(6, 0.2)
        acceleration = np.full(6, -0.1)
        model.calc_output_derivatives(moved, velocity, acceleration)
        assert model.time == pytest.approx(0.01)
        q_now, v_now, a_now = model.get_coupled_motion()
        assert q_now == pytest.approx(moved) and v_now == pytest.approx(velocity)
        assert a_now == pytest.approx(acceleration)


def test_the_jacobians_are_refused_on_the_coupled_aggregate(tmp_path):
    deck = aggregate_deck(tmp_path)
    with CableDyn(deck) as model:
        q, v, a = model.get_coupled_motion()
        with pytest.raises(CableDynError, match="no load derivatives"):
            model.calc_output_derivatives(q, v, a)


def aggregate_deck(tmp_path: Path) -> Path:
    """A finite-EI line, which runs on the coupled aggregate."""
    text = line_deck(tmp_path).read_text(encoding="utf-8")
    finite = text.replace(
        f"Name Diam Mass EA BA EI Cdn Cdt Can Cat\ncab 0.1 {MASS} {EA} 0.0 0.0 0.0 0.0 0.0 0.0",
        "Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat\n"
        f"cab 0.1 {MASS} {EA} 0.0 100.0 1.0e8 80.0 1.0 0.04 0.0 0.0 0.0 0.0",
    ).replace("1.0e-9 g\n1.0e-9 rhoW", "9.8 g\n1025.0 rhoW\n0.01 dtM\n1.0 TMax")
    deck = tmp_path / "finite.dat"
    deck.write_text(finite, encoding="utf-8")
    return deck


def test_flat_and_column_per_point_positions_build_the_same_line():
    q0 = straight((SPAN, 0.0, -10.0))
    with CableDyn() as flat, CableDyn() as columns:
        init_taut(flat)
        columns.init_line(
            q0.reshape(-1, 3).T,
            np.zeros((3, N_ELEM + 1)),
            chain_conn().reshape(-1),
            element_values(LENGTH / N_ELEM),
            element_values(EA),
            element_values(MASS),
            end_dofs(),
            True,
            RHO_INF,
        )
        assert columns.calc_output() == pytest.approx(flat.calc_output(), abs=0.0)


def test_a_line_without_prescribed_dofs_has_an_empty_coupled_vector():
    q0 = straight((SPAN, 0.0, -10.0))
    with CableDyn() as model:
        model.init_line(
            q0,
            np.zeros_like(q0),
            chain_conn(),
            element_values(LENGTH / N_ELEM),
            element_values(EA),
            element_values(MASS),
            [],
            True,
            RHO_INF,
        )
        assert model.n_coupled_dof == 0 and model.calc_output().shape == (0,)
        loads, dq, dv, da, added = model.calc_output_derivatives([], [], [])
        assert loads.shape == (0,)
        assert dq.shape == dv.shape == da.shape == added.shape == (0, 0)


def test_tension_only_lets_a_line_go_slack():
    span = (LENGTH * 0.9, 0.0, -10.0)
    with CableDyn() as slack, CableDyn() as linear:
        init_taut(slack, span, tension_only=True)
        init_taut(linear, span, tension_only=False)
        assert not np.any(slack.calc_output())
        assert linear.calc_output()[0] == pytest.approx(-0.1 * EA, rel=1e-12)


def raw_arguments() -> dict:
    q0 = straight((SPAN, 0.0, -10.0))
    return {
        "q0": q0,
        "v0": np.zeros_like(q0),
        "elem_conn": chain_conn(),
        "l0": element_values(LENGTH / N_ELEM),
        "ea": element_values(EA),
        "rho_a": element_values(MASS),
        "fixed_dofs": end_dofs(),
        "tension_only": True,
        "rho_inf": RHO_INF,
    }


@pytest.mark.parametrize(
    ("name", "value", "error", "match"),
    [
        ("q0", np.zeros(32), ValueError, "q0 must be flat"),
        ("q0", np.zeros((3, 3)), ValueError, "ambiguous"),
        ("q0", np.full(33, np.nan), ValueError, "q0 must be finite"),
        ("q0", np.zeros(33, dtype=complex), TypeError, "real-valued"),
        ("v0", np.zeros(30), ValueError, "v0 must hold as many"),
        ("v0", np.full(33, np.inf), ValueError, "v0 must be finite"),
        ("elem_conn", np.ones((N_ELEM, 3), dtype=int), ValueError, "elem_conn must be"),
        ("elem_conn", np.ones((N_ELEM, 2)), TypeError, "elem_conn must be an integer"),
        ("elem_conn", np.full((N_ELEM, 2), 2**33), ValueError, "range of a C int"),
        ("l0", np.ones((N_ELEM, 1)), ValueError, "l0 must be flat"),
        ("l0", np.zeros(0), ValueError, "ea must be flat"),
        ("l0", np.full(N_ELEM, np.nan), ValueError, "l0 must be finite"),
        ("ea", np.ones(N_ELEM + 1), ValueError, "ea must be flat"),
        ("ea", np.full(N_ELEM, np.inf), ValueError, "ea must be finite"),
        ("rho_a", np.ones(N_ELEM - 1), ValueError, "rho_a must be flat"),
        ("rho_a", np.full(N_ELEM, np.nan), ValueError, "rho_a must be finite"),
        ("fixed_dofs", np.ones((2, 3), dtype=int), ValueError, "fixed_dofs must be flat"),
        ("fixed_dofs", [1.0, 2.0], TypeError, "fixed_dofs must be an integer"),
        ("tension_only", "yes", TypeError, "tension_only must be a boolean"),
        ("rho_inf", float("nan"), ValueError, "rho_inf must be finite"),
        ("rho_inf", -0.1, ValueError, "rho_inf must be non-negative"),
        ("rho_inf", 1.5, ValueError, r"rho_inf must lie in \[0, 1\]"),
        ("rho_inf", "0.4", TypeError, "rho_inf must be a real number"),
    ],
)
def test_a_bad_array_is_refused_before_the_library(name, value, error, match):
    with CableDyn(VOLTURNUS) as model:
        n_lines = model.n_lines
        arguments = raw_arguments()
        arguments[name] = value
        with pytest.raises(error, match=match):
            model.init_line(**arguments)
        assert model.deck == VOLTURNUS.resolve() and model.n_lines == n_lines


def test_a_line_needs_two_nodes_and_an_element():
    arguments = raw_arguments()
    with CableDyn() as model:
        short = {**arguments, "q0": np.zeros(3), "v0": np.zeros(3)}
        with pytest.raises(ValueError, match="at least 2 nodes"):
            model.init_line(**short)
        empty = {**arguments, "elem_conn": [], "l0": [], "ea": [], "rho_a": []}
        with pytest.raises(ValueError, match="at least 2 nodes and 1 element"):
            model.init_line(**empty)


@pytest.mark.parametrize(
    ("name", "value", "match"),
    [
        ("elem_conn", chain_conn() - 1, "elem_conn|connectivity|node"),
        ("fixed_dofs", [0, 1, 2], "fixed"),
        ("fixed_dofs", [1, 1, 2], "fixed|duplicate"),
        ("fixed_dofs", [34], "fixed"),
        ("l0", -element_values(1.0), "l0|length|positive"),
        ("ea", 0.0 * element_values(1.0), "ea|EA|positive"),
        ("rho_a", -element_values(1.0), "rho_a|mass|positive"),
    ],
)
def test_a_bad_value_is_the_library_s_to_refuse(name, value, match):
    arguments = raw_arguments()
    arguments[name] = value
    with CableDyn() as model:
        with pytest.raises(CableDynError, match=match) as raised:
            model.init_line(**arguments)
        assert raised.value.status == BAD_INPUT
        assert not model.initialized


@pytest.mark.parametrize(
    ("change", "error", "match"),
    [
        ({"n_nodes": [11]}, ValueError, "n_elem must have 1 entries"),
        ({"n_nodes": []}, ValueError, "n_nodes must be flat"),
        ({"n_nodes": [11, 1]}, ValueError, "at least 2 nodes"),
        ({"n_elem": [10, 0]}, ValueError, "at least 2 nodes"),
        ({"n_fixed": [6, -6]}, ValueError, "at least 2 nodes"),
        ({"n_nodes": [11, 10]}, ValueError, "q0 must hold 63"),
        ({"n_elem": [10, 9]}, ValueError, "l0 must hold 19"),
        ({"n_fixed": [6, 5]}, ValueError, "fixed_dofs must hold 11"),
        ({"n_nodes": [11.0, 11.0]}, TypeError, "n_nodes must be an integer"),
        ({"coupled_map": [1, 2, 3]}, ValueError, r"coupled_map must be flat \(12,\)"),
        ({"coupled_map": [1.0] * 12}, TypeError, "coupled_map must be an integer"),
    ],
)
def test_a_bad_count_is_refused_before_the_library(change, error, match):
    arguments = shared_arrays()
    arguments.update(change)
    with CableDyn() as model, pytest.raises(error, match=match):
        model.init_lines(**arguments, tension_only=True, rho_inf=RHO_INF)


def test_a_coupled_map_needs_six_fixed_dofs_on_every_line():
    arguments = shared_arrays()
    arguments["n_fixed"] = np.array([3, 3])
    arguments["fixed_dofs"] = np.array([1, 2, 3, 1, 2, 3])
    with CableDyn() as model, pytest.raises(ValueError, match="six fixed DOFs"):
        model.init_lines(
            **arguments, tension_only=True, rho_inf=RHO_INF, coupled_map=list(range(1, 13))
        )


def test_a_coupled_map_with_a_gap_is_the_library_s_to_refuse():
    with CableDyn() as model:
        with pytest.raises(CableDynError) as raised:
            model.init_lines(
                **shared_arrays(),
                tension_only=True,
                rho_inf=RHO_INF,
                coupled_map=[1, 2, 3, 4, 5, 6, 1, 2, 3, 8, 9, 10],
            )
        assert raised.value.status == BAD_INPUT
        assert not model.initialized


def test_a_raw_line_replaces_a_deck_model_and_its_book_keeping(tmp_path):
    with CableDyn(line_deck(tmp_path)) as model:
        q, v, a = model.get_coupled_motion()
        model.step(0.01, q, v, a)
        model.save_state()
        old_line = model.lines[0]
        init_taut(model)
        assert model.deck is None and model.time == 0.0
        with pytest.raises(CableDynError):
            model.restore_state()  # the library drops the save
        with pytest.raises(RuntimeError):
            old_line.node_positions()
        assert model.lines[0].n_nodes == N_ELEM + 1


def test_a_failed_raw_line_keeps_a_live_aggregate_with_its_save(tmp_path):
    deck = aggregate_deck(tmp_path)
    with CableDyn(deck) as model:
        q, v, a = model.get_coupled_motion()
        model.step(0.01, q, v, a)
        model.save_state()
        view = model.lines[0]
        arguments = raw_arguments()
        arguments["l0"] = -element_values(1.0)
        with pytest.raises(CableDynError):
            model.init_line(**arguments)
        assert model.initialized and model.deck == deck.resolve()
        assert model.time == pytest.approx(0.01)
        assert view.n_nodes > 0
        model.step(0.01, q, v, a)
        model.restore_state()
        assert model.time == pytest.approx(0.01)


def test_a_failed_raw_line_loses_the_save_of_a_point_model(tmp_path):
    with CableDyn(line_deck(tmp_path)) as model:
        model.save_state()
        arguments = raw_arguments()
        arguments["ea"] = -element_values(1.0)
        with pytest.raises(CableDynError):
            model.init_line(**arguments)
        with pytest.raises(CableDynError):
            model.restore_state()
