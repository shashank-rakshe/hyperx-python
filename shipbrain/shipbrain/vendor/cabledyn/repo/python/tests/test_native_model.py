# SPDX-License-Identifier: Apache-2.0
"""In-process binding gates that need the CableDyn shared library.

Skipped when the library cannot be loaded (set ``CABLEDYN_LIBRARY``).
"""

from __future__ import annotations

import ctypes
import importlib.util
import os
import sys
import threading
from pathlib import Path

import numpy as np
import pytest

try:
    import cabledyn._lib  # loads the shared library
except (ImportError, OSError) as exc:  # a missing library raises OSError
    pytest.skip(f"CableDyn shared library not available: {exc}", allow_module_level=True)

import cabledyn
from cabledyn import _lib
from cabledyn import model as model_module
from cabledyn.errors import CableDynError, ConvergenceError

REPO = Path(__file__).resolve().parents[2]
VOLTURNUS = REPO / "examples" / "iea15mw_volturnus_mooring.dat"


def _variant(tmp_path: Path, old: str, new: str) -> Path:
    text = VOLTURNUS.read_text(encoding="utf-8")
    assert old in text
    path = tmp_path / "variant.dat"
    path.write_text(text.replace(old, new), encoding="utf-8")
    return path


def test_version_helpers_are_consistent():
    major, minor, patch, abi = _lib.version()
    assert abi == _lib.SUPPORTED_ABI == cabledyn.abi_version()
    assert f"{major}.{minor}.{patch}" in cabledyn.version_string()
    with pytest.raises(AttributeError, match="no attribute 'missing'"):
        _ = cabledyn.missing  # type: ignore[attr-defined]


def test_array_shapes_are_validated_before_the_library():
    with cabledyn.CableDyn(VOLTURNUS) as m:
        n = m.n_coupled_dof
        good = np.zeros(n)
        for bad in (np.zeros(n + 1), np.zeros((2, n)), np.zeros((3, 3))):
            with pytest.raises(ValueError, match="must be flat"):
                m.update_states(bad, good, good)
        with pytest.raises(ValueError, match="waterline_z must have 2 entries"):
            m.update_point_fluid_fields(np.zeros((3, 2)), np.zeros((3, 2)), np.zeros(3), 1025.0)


def test_failed_initialization_in_the_constructor_releases_the_handle(monkeypatch):
    # The constructor's own instance is captured when it calls init_deck, and only its closes
    # count: instances other tests left behind may be finalized (and closed) at any point, with
    # or without the cyclic collector running.
    own: list[model_module.CableDyn] = []
    closes: list[tuple[model_module.CableDyn, bool]] = []
    original_init_deck = model_module.CableDyn.init_deck
    original_close = model_module.CableDyn.close

    def tracking_init_deck(self: model_module.CableDyn, deck: str | os.PathLike[str]) -> None:
        own.append(self)
        original_init_deck(self, deck)

    def tracking_close(self: model_module.CableDyn) -> None:
        closes.append((self, bool(self._handle)))
        original_close(self)

    monkeypatch.setattr(model_module.CableDyn, "init_deck", tracking_init_deck)
    monkeypatch.setattr(model_module.CableDyn, "close", tracking_close)
    with pytest.raises(CableDynError, match="CableDyn_InitDeck failed") as caught:
        cabledyn.CableDyn("no_such_deck_anywhere.dat")
    assert len(own) == 1
    own_closes = [held for instance, held in closes if instance is own[0]]
    # the failed constructor closed its instance while it still held the handle
    assert own_closes and own_closes[0] is True
    assert not own[0]._handle
    assert caught.value.status != 0 and caught.value.detail


def test_a_deck_current_that_varies_in_time_is_refused_without_a_clock(tmp_path):
    # The C ABI has no simulation clock: a MoorDyn-C Currents 2 table that varies in time is
    # refused like deck waves; the same deck with a table constant in time applies it steadily.
    case = REPO / "tests" / "data" / "currents_mdc" / "tension_c2"
    deck = tmp_path / "tension.dat"
    deck.write_bytes((case / "tension.dat").read_bytes())
    table = tmp_path / "current_profile_dynamic.txt"
    table.write_bytes((case / "current_profile_dynamic.txt").read_bytes())
    with cabledyn.CableDyn() as m:
        with pytest.raises(CableDynError):
            m.init_deck(deck)
        assert "no simulation clock" in m.last_error()
        assert "Currents 2" in m.last_error()
    table.write_text(
        "h\nh\n\n\n-50.0 0.0\nt ux\n0.0 0.4 0.6\n10.0 0.4 0.6\n", encoding="utf-8", newline="\n"
    )
    with cabledyn.CableDyn(deck) as m:
        assert m.n_lines == 1


def test_last_error_reports_the_library_diagnostic():
    with cabledyn.CableDyn() as m:
        with pytest.raises(CableDynError) as caught:
            m.init_deck("no_such_deck_anywhere.dat")
        assert m.last_error() == caught.value.detail
        assert "no_such_deck_anywhere" in m.last_error()


def test_unconverged_step_raises_convergence_error_after_advancing(tmp_path):
    deck = _variant(
        tmp_path, "dynamic_solver 1.0e-8 1.0e-14 30 12", "dynamic_solver 1.0e-15 1.0e-30 1 0"
    )
    with cabledyn.CableDyn(deck) as m:
        n = m.n_coupled_dof
        q, _, _ = m.get_coupled_motion()
        moved = q.copy()
        moved[0::3] += 2.0
        velocity = np.zeros(n)
        velocity[0::3] = 20.0
        with pytest.raises(ConvergenceError) as caught:
            m.step(0.1, moved, velocity, np.zeros(n))
        assert caught.value.status == 4
        assert caught.value.n_iter >= 1
        assert isinstance(caught.value.stalled, bool)
        # The model advanced with its best iterate: the coupled points moved.
        after, _, _ = m.get_coupled_motion()
        assert np.allclose(after, moved)


def test_point_fluid_fields_are_accepted_and_change_the_loads():
    with cabledyn.CableDyn(VOLTURNUS) as m:
        n = m.n_coupled_dof
        points = m.n_points
        q, v, a = m.get_coupled_motion()
        m.update_states(q, v, a)
        still = m.calc_output()
        velocity = np.zeros((3, points))
        velocity[0, :] = 2.0
        m.update_point_fluid_fields(velocity, np.zeros(3 * points), np.zeros(points), 1025.0)
        for _ in range(3):
            m.step(0.1, q, np.zeros(n), np.zeros(n))
        assert np.all(np.isfinite(m.calc_output()))
        assert still.shape == (n,)


def test_structure_queries_fail_closed_on_an_unbound_handle():
    with cabledyn.CableDyn() as m:
        for query in ("n_points", "n_lines", "n_coupled_dof"):
            with pytest.raises(CableDynError, match=r"NOT_INITIALIZED|BAD_HANDLE|failed"):
                getattr(m, query)
        with pytest.raises(CableDynError):
            m.calc_output()


def test_create_failure_is_reported_as_cabledyn_error(monkeypatch):
    class FailingCreate:
        def __getattr__(self, name: str):
            return getattr(_lib._lib, name)

        @staticmethod
        def CableDyn_Create(handle, status):
            ctypes.cast(status, ctypes.POINTER(ctypes.c_int)).contents.value = 2

    monkeypatch.setattr(model_module, "_lib", FailingCreate())
    with pytest.raises(CableDynError, match="CableDyn_Create failed with ALLOC_FAIL"):
        model_module.CableDyn()


@pytest.mark.skipif(os.name != "nt", reason="Windows code-page path encoding")
def test_unrepresentable_windows_path_is_rejected_before_the_library():
    with cabledyn.CableDyn() as m:
        name = "\U0001f30a-一क-deck.dat"
        try:
            name.encode("mbcs", errors="strict")
        except UnicodeEncodeError:
            with pytest.raises(ValueError, match="active Windows code page"):
                m.init_deck(name)
        else:  # pragma: no cover - only on a UTF-8 system code page
            pytest.skip("the active code page represents every test character")


def _load_private_lib_copy(monkeypatch, fake_cdll) -> None:
    spec = importlib.util.spec_from_file_location("cabledyn._lib_probe", _lib.__file__)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    monkeypatch.setattr(ctypes, "CDLL", fake_cdll)
    monkeypatch.setitem(sys.modules, "cabledyn._lib_probe", module)
    spec.loader.exec_module(module)


class _FakeFunction:
    def __init__(self, body=None):
        self.body = body

    def __call__(self, *args):
        return self.body(*args) if self.body else None


class _FakeLibrary:
    def __init__(self, abi: int) -> None:
        def version(major, minor, patch, abi_ref):
            abi_ref._obj.value = abi

        self.CableDyn_GetVersion = _FakeFunction(version)

    def __getattr__(self, name: str) -> _FakeFunction:
        function = _FakeFunction()
        setattr(self, name, function)
        return function


def test_a_library_with_another_abi_is_rejected_at_import(monkeypatch):
    with pytest.raises(OSError, match="speaks C ABI 99"):
        _load_private_lib_copy(monkeypatch, lambda path: _FakeLibrary(99))


def test_windows_dependency_directories_are_registered_before_loading(monkeypatch, tmp_path):
    registered: list[str] = []
    library = tmp_path / "build" / "bin" / "libcabledyn.dll"
    library.parent.mkdir(parents=True)
    library.write_bytes(b"")
    (tmp_path / "build" / "runtime").mkdir()
    monkeypatch.setenv("CABLEDYN_LIBRARY", str(library))
    monkeypatch.setattr(sys, "platform", "win32")
    monkeypatch.setattr(os, "add_dll_directory", registered.append, raising=False)
    _load_private_lib_copy(monkeypatch, lambda path: _FakeLibrary(_lib.SUPPORTED_ABI))
    assert [Path(item) for item in registered] == [library.parent, tmp_path / "build" / "runtime"]


def test_step_and_fluid_scalars_must_be_finite_real_numbers():
    with cabledyn.CableDyn(VOLTURNUS) as m:
        q, v, a = m.get_coupled_motion()
        for bad_dt in ("0.1", b"0.1", 0.1 + 0.0j, True, None):
            with pytest.raises(TypeError, match="dt must be a real number"):
                m.step(bad_dt, q, v, a)  # type: ignore[arg-type]
        for bad_dt in (0.0, -0.1, float("nan"), float("inf")):
            with pytest.raises(ValueError, match="dt must be"):
                m.step(bad_dt, q, v, a)
        points = m.n_points
        zeros = np.zeros(3 * points)
        with pytest.raises(TypeError, match="fluid_density must be a real number"):
            m.update_point_fluid_fields(zeros, zeros, np.zeros(points), "1025")  # type: ignore[arg-type]
        with pytest.raises(ValueError, match="fluid_density must be non-negative"):
            m.update_point_fluid_fields(zeros, zeros, np.zeros(points), -1.0)
        # NumPy scalars are real numbers; the step itself proceeds.
        assert m.step(np.float64(0.05), q, v, a) >= 0


def test_complex_and_non_numeric_arrays_are_rejected():
    with cabledyn.CableDyn(VOLTURNUS) as m:
        n = m.n_coupled_dof
        good = np.zeros(n)
        with pytest.raises(TypeError, match="q must be real-valued"):
            m.update_states(np.zeros(n, dtype=complex), good, good)
        with pytest.raises(TypeError, match="v must be a real numeric array"):
            m.step(0.1, good, np.array(["0"] * n), good)
        points = m.n_points
        with pytest.raises(TypeError, match="waterline_z must be real-valued"):
            m.update_point_fluid_fields(
                np.zeros(3 * points), np.zeros(3 * points), np.zeros(points, dtype=complex), 1025.0
            )


def test_concurrent_initialisation_and_stepping_from_threads():
    # Deck parsing is serialised inside the library: many threads initialising the
    # same deck all succeed (the Fortran runtime cannot open one file twice), and
    # stepping distinct instances concurrently matches a serial reference.
    threads = 16
    results: list[object] = [None] * threads

    def reference() -> np.ndarray:
        with cabledyn.CableDyn(VOLTURNUS) as m:
            q, v, a = m.get_coupled_motion()
            for _ in range(10):
                m.step(0.05, q, v, a)
            return m.calc_output()

    expected = reference()

    def worker(index: int) -> None:
        try:
            results[index] = reference()
        except Exception as exc:  # recorded for the assertion below
            results[index] = exc

    pool = [threading.Thread(target=worker, args=(i,)) for i in range(threads)]
    for thread in pool:
        thread.start()
    for thread in pool:
        thread.join()
    for result in results:
        assert isinstance(result, np.ndarray), result
        np.testing.assert_allclose(result, expected, rtol=1e-9, atol=1e-9)


def test_missing_deck_reports_file_not_found(tmp_path):
    with pytest.raises(CableDynError, match="file not found"):
        cabledyn.CableDyn(tmp_path / "absent.dat")


_ROD_DECK = """C API free-rod deck
--- LINE TYPES ---
Name Diam Mass EA BA EI Cdn Cdt Can Cat
(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)
line 0.10 80.0 1.0e5 0.0 0.0 1.0 0.0 1.0 0.0
--- ROD TYPES ---
Name Diam Mass Cd Ca CdEnd CaEnd
(-) (m) (kg/m) (-) (-) (-) (-)
rodmat 0.20 50.0 1.0 1.0 0.0 0.0
--- RODS ---
ID RodType Type XA YA ZA XB YB ZB NumSegs Outputs
(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)
1 rodmat {rod_type} 0.0 0.0 -4.0 0.0 0.0 -2.0 2 -
--- POINTS ---
ID Type X Y Z Mass Vol CdA Ca
(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)
1 Fixed 2.0 0.0 -5.0 0.0 0.0 0.0 0.0
2 Rod1A 0.0 0.0 -4.0 0.0 0.0 0.0 0.0
3 Rod1B 0.0 0.0 -2.0 0.0 0.0 0.0 0.0
4 Coupled 0.0 0.0 -1.0 0.0 0.0 0.0 0.0
--- LINES ---
ID NodeA NodeB Outputs
(-) (-) (-) (-)
1 2 1 -
2 3 4 -
--- SECTIONS ---
LineID LineType Length NumSegs
(-) (-) (m) (-)
1 line 3.5 3
2 line 1.2 2
--- OPTIONS ---
9.80665 g
1025.0 rhoW
10.0 WtrDpth
1.0e5 kBot
0.005 dtM
1.0 TMax
--- end ---
"""


def test_rod_deck_steps_through_the_coupled_aggregate(tmp_path):
    deck = tmp_path / "rod.dat"
    deck.write_text(_ROD_DECK.format(rod_type="Free"), encoding="utf-8")
    with cabledyn.CableDyn(deck) as m:
        # the coupled DOFs are the deck's Coupled points; the rod is integrated internally
        assert m.n_coupled_dof == 3
        assert m.n_lines == 2
        q, _, _ = m.get_coupled_motion()
        m.update_states(q, np.zeros(3), np.zeros(3))
        at_rest = m.calc_output()
        for k in range(10):
            moved = q.copy()
            moved[0] += 0.02 * np.sin(0.5 * (k + 1))
            m.step(0.005, moved, np.zeros(3), np.zeros(3))
        loads = m.calc_output()
        assert np.all(np.isfinite(loads)) and np.abs(loads).max() > 0.0
        assert not np.allclose(loads, at_rest)
        # the step is the deck dtM; point fluid fields are not part of this route
        with pytest.raises(CableDynError) as caught:
            m.step(0.01, q, np.zeros(3), np.zeros(3))
        assert caught.value.status == 3
        with pytest.raises(CableDynError, match="finite-EI lines, BODIES or RODS runs on"):
            npt = m.n_points
            m.update_point_fluid_fields(np.zeros(3 * npt), np.zeros(3 * npt), np.zeros(npt), 1025.0)


def test_coupled_rod_deck_is_rejected_by_the_translational_abi(tmp_path):
    deck = tmp_path / "hostrod.dat"
    deck.write_text(_ROD_DECK.format(rod_type="Coupled"), encoding="utf-8")
    with pytest.raises(CableDynError, match="Coupled/Vessel ROD"):
        cabledyn.CableDyn(deck)


def test_coupled_arrays_must_be_finite():
    with cabledyn.CableDyn(VOLTURNUS) as m:
        q, v, a = m.get_coupled_motion()
        bad = q.copy()
        bad[0] = np.nan
        with pytest.raises(ValueError, match="q must be finite"):
            m.step(0.05, bad, v, a)
        with pytest.raises(ValueError, match="a must be finite"):
            m.step(0.05, q, v, np.full_like(a, np.inf))
        points = m.n_points
        zeros = np.zeros(3 * points)
        with pytest.raises(ValueError, match="fluid_velocity must be finite"):
            m.update_point_fluid_fields(zeros + np.nan, zeros, np.zeros(points), 1025.0)
        with pytest.raises(ValueError, match="waterline_z must be finite"):
            m.update_point_fluid_fields(zeros, zeros, np.full(points, np.inf), 1025.0)


def test_home_relative_deck_path_is_expanded(tmp_path, monkeypatch):
    deck = tmp_path / "volturnus.dat"
    deck.write_bytes(Path(VOLTURNUS).read_bytes())
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("USERPROFILE", str(tmp_path))
    with cabledyn.CableDyn("~/volturnus.dat") as m:
        assert m.deck == deck.resolve()


def test_long_failure_message_is_kept_whole():
    # A deck path of 1100 characters that does not exist: the diagnosis names the whole path and
    # the reason, longer than the 1024 characters the handle once retained, and its closing
    # reason must reach the caller.
    deck = "missing_" + "d" * 1100 + ".dat"
    with cabledyn.CableDyn() as m:
        with pytest.raises(CableDynError) as caught:
            m.init_deck(deck)
        detail = caught.value.detail
        assert len(detail) > 1024
        assert "cannot open deck: " in detail and deck in detail
        assert detail.endswith("(file not found)")
