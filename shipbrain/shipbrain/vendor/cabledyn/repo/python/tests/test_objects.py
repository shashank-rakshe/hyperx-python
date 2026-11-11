# SPDX-License-Identifier: Apache-2.0
"""In-process object queries: lines, points, bodies, rods and output channels.

The parity gates run each deck through the standalone driver and compare its
written channels, per-line node positions and segment tensions with the
in-process queries at the same time. They need ``CABLEDYN_TEST_DRIVER`` (or
``CABLEDYN_DRIVER``) to name a built driver and are skipped otherwise. The
other gates need only the shared library.
"""

from __future__ import annotations

import math
import os
import re
from pathlib import Path

import numpy as np
import pytest

try:
    import cabledyn._lib  # loads the shared library
except (ImportError, OSError) as exc:  # a missing library raises OSError
    pytest.skip(f"CableDyn shared library not available: {exc}", allow_module_level=True)

import cabledyn
from cabledyn import _lib
from cabledyn import objects as objects_module
from cabledyn.errors import CableDynError
from cabledyn.model import CableDyn

REPO = Path(__file__).resolve().parents[2]
EXAMPLES = REPO / "examples"
_DRIVER = (
    os.environ.get("CABLEDYN_TEST_DRIVER", "").strip()
    or os.environ.get("CABLEDYN_DRIVER", "").strip()
)
needs_driver = pytest.mark.skipif(
    not _DRIVER or not Path(_DRIVER).is_file(),
    reason="set CABLEDYN_TEST_DRIVER to a built native driver to run the parity gates",
)


def _outputs(text: str, channels: list[str]) -> str:
    """Append OUTPUTS channels to a deck's existing OUTPUTS section."""
    block = "".join(f'"{name}"\n' for name in channels)
    marker = re.search(r"^-+\s*need this line.*$", text, flags=re.MULTILINE)
    assert marker is not None
    return text[: marker.start()] + block + text[marker.start() :]


def _held_chain(tmp_path: Path, tmax: float = 1.0) -> Path:
    text = (EXAMPLES / "dynamic_chain_held.dat").read_text(encoding="utf-8")
    text = text.replace("1     2       1       -", "1     2       1       pt")
    text = text.replace("10.0         TMax", f"{tmax}         TMax")
    text = _outputs(
        text,
        [
            "L1N5px",
            "L1N5pz",
            "L1N5vz",
            "L1N5az",
            "Ten1N5",
            "Curv1N5",
            "BendMom1N5",
            "L1N5Dec",
            "L1N5Azi",
            "Point1Fx",
            "Point1Fz",
            "Point2pz",
        ],
    )
    path = tmp_path / "held_chain.dat"
    path.write_text(text, encoding="utf-8")
    return path


def _lazy_wave(tmp_path: Path) -> Path:
    text = (EXAMPLES / "lazy_wave_modes.dat").read_text(encoding="utf-8")
    text = text.replace("1   1      2      -", "1   1      2      pt")
    text = text.replace("10       nModes", "0        nModes")
    text = _outputs(text, ["L1N96px", "L1N96pz", "Ten1N96", "L1N96Dec"])
    path = tmp_path / "lazy_wave.dat"
    path.write_text(text, encoding="utf-8")
    return path


_BODY_DECK = """Rigid6 buoy for the object-query gates (still water, no body hydrodynamics)
--- LINE TYPES ---
TypeName Diam MassDenInAir EA BA EI Cd_n Cd_t Ca_n Ca_t
(-) (m) (kg/m) (N) (N-s/-) (N-m^2) (-) (-) (-) (-)
poly 0.12 15.0 5.0e7 -1.0 0.0 1.2 0.2 1.0 0.0
--- BODIES ---
ID Type X Y Z Roll Pitch Yaw Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz
(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm) (Nm) (m2) (-) (kgm2) (kgm2) (kgm2)
1 Rigid6 0.0 0.0 -20.0 0.0 0.0 0.0 2.0e4 40.0 0.0 0.0 0.0 0.0 0.0 3.5e4 3.5e4 3.5e4
--- POINTS ---
ID Type X Y Z Mass Vol CdA Ca
(-) (-) (m) (m) (m) (kg) (m^3) (m^2) (-)
1 Body1 1.5 0.0 -2.0 0 0 0 0
2 Body1 -0.75 1.299 -2.0 0 0 0 0
3 Body1 -0.75 -1.299 -2.0 0 0 0 0
4 Fixed 40.0 0.0 -100.0 0 0 0 0
5 Fixed -20.0 34.641 -100.0 0 0 0 0
6 Fixed -20.0 -34.641 -100.0 0 0 0 0
--- LINES ---
ID NodeA NodeB Outputs
(-) (-) (-) (-)
1 1 4 pt
2 2 5 -
3 3 6 -
--- SECTIONS ---
LineID LineType Length NumSegs
(-) (-) (m) (-)
1 poly 86.85 20
2 poly 86.85 20
3 poly 86.85 20
--- OPTIONS ---
9.80665 g
1025.0 rhoW
100.0 WtrDpth
1.0e5 kBot
1.0e4 cBot
0.01 dtM
0.1 TMax
--- OUTPUTS ---
"FairTen1"
"AnchTen2"
"Body1Px"
"Body1Pz"
"Body1Rx"
"Body1Vz"
"Body1Fz"
"Body1Mx"
"Point1pz"
"Point4Fz"
--- need this line ---
"""

_ROD_DECK = """Free rod for the object-query gates
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
1 rodmat Free 0.0 0.0 -4.0 0.0 0.0 -2.0 2 -
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
0.05 TMax
--- OUTPUTS ---
"Rod1Pz"
"Rod1Rx"
"Rod1N2Pz"
"Rod1TenA"
"Rod1Fz"
--- need this line ---
"""


def _write(tmp_path: Path, name: str, text: str) -> Path:
    path = tmp_path / name
    path.write_text(text, encoding="utf-8")
    return path


def _assert_close(
    actual: np.ndarray, expected: np.ndarray, what: str, *, peak: bool = False
) -> None:
    """The driver writes 8 significant digits (ES15.7); compare at that precision.

    ``peak`` scales by the largest magnitude instead: derived quantities of a stiff
    finite-EI line (curvature, bend moment) amplify the round-off difference between
    the driver's and the embedded static solution.
    """
    top = max(1.0, float(np.max(np.abs(expected))))
    scale = np.full_like(expected, top) if peak else np.maximum(np.abs(expected), 1.0e-6 * top)
    err = np.max(np.abs(actual - expected) / scale)
    assert err < 1.0e-6, f"{what}: max relative difference {err:.3e}"


def _driver_run(deck: Path, tmp_path: Path) -> cabledyn.DriverResult:
    return cabledyn.CableDynDriver(_DRIVER).run(deck, tmp_path / (deck.stem + "_run"))


def _check_row(model: CableDyn, result: cabledyn.DriverResult, time: float) -> None:
    main = result.read_main()
    row = int(np.argmin(np.abs(main.values[:, 0] - time)))
    assert abs(main.values[row, 0] - time) < 1.0e-9
    channels = list(main.channels[1:])
    _assert_close(model.channels(channels), main.values[row, 1:], f"channels at t={time}")
    for line_id in result.line_ids:
        line = model.line(line_id)
        with_p = result.read_line_positions(line_id)
        with_t = result.read_line_tensions(line_id)
        prow = int(np.argmin(np.abs(with_p.values[:, 0] - time)))
        _assert_close(line.node_positions().ravel(), with_p.values[prow, 1:], "node positions")
        trow = int(np.argmin(np.abs(with_t.values[:, 0] - time)))
        # Relative to the line's peak tension: a stiff element's tension amplifies the
        # round-off difference between the driver's and the embedded static solution.
        expected = with_t.values[trow, 1:]
        err = np.max(np.abs(line.segment_tensions() - expected)) / np.max(np.abs(expected))
        assert err < 1.0e-6, f"segment tensions: max difference {err:.3e} of the peak"


# --- parity with the standalone driver's output files -------------------------


@needs_driver
def test_point_route_matches_driver_outputs_at_every_sampled_step(tmp_path):
    deck = _held_chain(tmp_path)
    result = _driver_run(deck, tmp_path)
    with CableDyn(deck) as model:
        _check_row(model, result, 0.0)
        for step in range(20):
            model.step_held(0.05)
            if (step + 1) % 5 == 0:
                _check_row(model, result, model.time)


@needs_driver
def test_finite_ei_line_matches_driver_outputs_at_the_initial_state(tmp_path):
    deck = _lazy_wave(tmp_path)
    result = _driver_run(deck, tmp_path)
    with CableDyn(deck) as model:
        (line,) = model.lines
        assert line.finite_ei
        _check_row(model, result, 0.0)
        # the static profile carries curvature and bend moment for every node
        static = result.read_static()
        profile = np.asarray(static.values)
        cols = list(static.channels)
        curvature = profile[:, cols.index("Curvature")]
        moment = profile[:, cols.index("BendMoment")]
        _assert_close(line.curvature(), curvature, "curvature", peak=True)
        _assert_close(line.bend_moment(), moment, "bend moment", peak=True)


@needs_driver
def test_body_and_rod_decks_match_driver_outputs_at_the_initial_state(tmp_path):
    for name, text in (("body.dat", _BODY_DECK), ("rod.dat", _ROD_DECK)):
        deck = _write(tmp_path, name, text)
        result = _driver_run(deck, tmp_path)
        with CableDyn(deck) as model:
            _check_row(model, result, 0.0)


def _heading_deck(cables: bool) -> tuple[str, dict[int, float]]:
    """Lines on headings on both sides of +x, and the azimuth each must report at End A.

    Line ``2 k`` runs in its vertical plane from its own coupled point to its own anchor. Within
    45 deg of +x the range is (-180, 180], otherwise [0, 360). With ``cables`` every second line
    is finite-EI, which puts the deck on the mixed route.
    """
    headings = [-46.0, -44.0, -30.0, -10.0, -1.0, 1.0, 10.0, 30.0, 44.0, 46.0, 180.0, 270.0]
    points, lines, sections, outputs, expected = [], [], [], [], {}
    for k, heading in enumerate(headings, start=1):
        cable = cables and k % 2 == 0
        reach = 70.0 if cable else 240.0
        cx, sy = math.cos(math.radians(heading)), math.sin(math.radians(heading))
        points.append(f"{2 * k - 1} Coupled {5.0 * cx:.15e} {5.0 * sy:.15e} -10.0")
        points.append(f"{2 * k} Fixed {(5.0 + reach) * cx:.15e} {(5.0 + reach) * sy:.15e} -60.0")
        lines.append(f"{2 * k} {2 * k - 1} {2 * k} -")
        sections.append(f"{2 * k} {'cable 100.0 20' if cable else 'chain 260.0 13'}")
        outputs.append(f"L{2 * k}N1Azi")
        expected[2 * k] = heading if abs(heading) < 45.0 else heading % 360.0
    text = "\n".join(
        [
            "Lines on both sides of +x",
            "--- LINE TYPES ---",
            "Name Diam Mass EA BA EI Cdn Cdt Can Cat",
            "(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)",
            "cable 0.16 36.7 4.69e8 -1.0 1.99e4 1.2 0.1 1.0 0.0",
            "chain 0.10 150.0 8.0e8 -1.0 0.0 1.2 0.4 1.0 0.5",
            "--- POINTS ---",
            "ID Type X Y Z",
            "(-) (-) (m) (m) (m)",
            *points,
            "--- LINES ---",
            "ID NodeA NodeB Outputs",
            "(-) (-) (-) (-)",
            *lines,
            "--- SECTIONS ---",
            "LineID LineType Length NumSegs",
            "(-) (-) (m) (-)",
            *sections,
            "--- OPTIONS ---",
            "9.80665 g",
            "1025.0 rhoW",
            "60.0 WtrDpth",
            "1.0e6 kBot",
            "1.0e5 cBot",
            "0.02 dtM",
            "0.04 TMax",
            "--- OUTPUTS ---",
            *outputs,
            "--- need this line ---",
            "",
        ]
    )
    return text, expected


@needs_driver
@pytest.mark.parametrize("cables", [False, True], ids=["ei0", "mixed"])
def test_azimuth_range_is_the_same_on_every_route(tmp_path, cables):
    text, expected = _heading_deck(cables)
    deck = _write(tmp_path, "headings.dat", text)
    result = _driver_run(deck, tmp_path)
    main = result.read_main()
    # a run without dtM and TMax stops at the static solution, which an EI = 0 deck writes out
    static_text = text.replace("0.02 dtM\n", "").replace("0.04 TMax\n", "")
    static_deck = _write(tmp_path, "headings_static.dat", static_text)
    static = _driver_run(static_deck, tmp_path).read_static()
    with CableDyn(deck) as model:
        for line_id, azimuth in expected.items():
            token = f"L{line_id}N1Azi"
            driver = float(main.values[0, list(main.channels).index(token)])
            assert driver == pytest.approx(azimuth, abs=1.0e-5), f"driver {token}"
            assert model.channel(token) == pytest.approx(azimuth, abs=1.0e-6), f"library {token}"
            line = model.line(line_id)
            np.testing.assert_allclose(line.azimuth(), azimuth, rtol=0.0, atol=1.0e-6)
            profile = static.line(line_id).column("Azimuth")
            np.testing.assert_allclose(profile, azimuth, rtol=0.0, atol=1.0e-5)


@needs_driver
def test_azimuth_range_of_a_line_on_a_body(tmp_path):
    text = _BODY_DECK.replace("4 Fixed 40.0 0.0 -100.0", "4 Fixed 40.0 -10.0 -100.0")
    text = text.replace('"FairTen1"\n', '"FairTen1"\n"L1N1Azi"\n')
    deck = _write(tmp_path, "body_heading.dat", text)
    main = _driver_run(deck, tmp_path).read_main()
    driver = float(main.values[0, list(main.channels).index("L1N1Azi")])
    with CableDyn(deck) as model:
        assert model.channel("L1N1Azi") == pytest.approx(driver, abs=1.0e-5)
    assert -45.0 < driver < 0.0


# --- library-only gates --------------------------------------------------------


def test_views_equal_the_channel_evaluator_bit_for_bit(tmp_path):
    deck = _held_chain(tmp_path)
    with CableDyn(deck) as model:
        model.step_held(0.05)
        (line,) = model.lines
        assert (line.index, line.id, line.name, line.n_nodes, line.n_segments) == (
            0,
            1,
            "Line1",
            42,
            41,
        )
        assert not line.finite_ei
        pos = line.node_positions()
        vel = line.node_velocities()
        acc = line.node_accelerations()
        for k in (1, 7, 42):
            for c, axis in enumerate("xyz"):
                assert pos[k - 1, c] == model.channel(f"L1N{k}p{axis}")
                assert vel[k - 1, c] == model.channel(f"L1N{k}v{axis}")
                assert acc[k - 1, c] == model.channel(f"L1N{k}a{axis}")
            assert line.node_tensions()[k - 1] == model.channel(f"Ten1N{k}")
            assert line.curvature()[k - 1] == model.channel(f"Curv1N{k}")
            assert line.declination()[k - 1] == model.channel(f"L1N{k}Dec")
            assert line.azimuth()[k - 1] == model.channel(f"L1N{k}Azi")
        assert np.all(line.bend_moment() == 0.0)
        assert line.fairlead_tension() == model.channel("FairTen1") == line.node_tensions()[0]
        assert line.anchor_tension() == model.channel("AnchTen1") == line.node_tensions()[-1]
        seg = line.segment_tensions()
        assert seg.shape == (41,) and np.all(seg > 0.0)
        arc = line.arc_length()
        assert arc[0] == 0.0 and arc[-1] == pytest.approx(410.0, rel=1.0e-2)

        fixed, coupled = model.points
        assert (fixed.id, fixed.kind, coupled.id, coupled.kind) == (1, "fixed", 2, "coupled")
        np.testing.assert_array_equal(fixed.position(), [400.0, 0.0, -50.0])
        np.testing.assert_array_equal(coupled.position(), pos[0])
        np.testing.assert_array_equal(fixed.position(), pos[-1])
        np.testing.assert_array_equal(coupled.velocity(), [0.0, 0.0, 0.0])
        force = fixed.force()
        assert force[0] == model.channel("Point1Fx")
        assert np.linalg.norm(force) == pytest.approx(line.anchor_tension(), rel=1.0e-12)
        # the anchor holds one line: AnchFz/AnchFH are components of the same end force
        assert model.channel("AnchFz1") == model.channel("Point1Fz") == force[2]
        assert model.channel("AnchFH1") == model.channel("Point1FH")
        assert model.channel("AnchFH1") == pytest.approx(np.hypot(force[0], force[1]), rel=1.0e-14)
        # a grounded anchor carries part of its end node's weight: a small downward force
        assert -0.05 * line.anchor_tension() < model.channel("AnchFz1") < 0.0
        assert model.bodies == () and model.rods == ()


def test_out_buffers_are_filled_in_place_and_validated(tmp_path):
    deck = _held_chain(tmp_path)
    with CableDyn(deck) as model:
        line = model.line(1)
        buf = np.empty((42, 3))
        assert line.node_positions(out=buf) is buf
        np.testing.assert_array_equal(buf, line.node_positions())
        seg = np.empty(41)
        assert line.segment_tensions(out=seg) is seg
        p3 = np.empty(3)
        assert model.point(1).force(out=p3) is p3
        with pytest.raises(ValueError, match="shape"):
            line.node_positions(out=np.empty((3, 42)))
        with pytest.raises(ValueError, match="C-contiguous"):
            line.node_positions(out=np.empty((42, 6))[:, ::2])
        with pytest.raises(ValueError, match="unknown line quantity"):
            line.values("strain")  # type: ignore[arg-type]


def test_finite_ei_views_report_bending(tmp_path):
    deck = _lazy_wave(tmp_path)
    with CableDyn(deck) as model:
        (line,) = model.lines
        # 256 deck segments, refined by the tensile-safety pass
        assert line.finite_ei and line.n_nodes >= 257
        curv = line.curvature()
        moment = line.bend_moment()
        assert curv.max() > 0.01
        # EI is uniform (1.99e4 N.m^2) along this cable; the moment is EI kappa over the stretch
        stretch = 1.0 + (line.values("tension") + 1.99e4 * curv**2) / 4.69e8
        np.testing.assert_allclose(moment * stretch, 1.99e4 * curv, rtol=1.0e-6, atol=1.0e-9)
        assert line.bend_moment()[95] == model.channel("BendMom1N96")
        np.testing.assert_allclose(line.node_positions()[0], [5.0, 0.0, -14.0], atol=1e-9)
        np.testing.assert_allclose(line.node_positions()[-1], [125.0, 0.0, -80.0], atol=1e-9)
        model.step_held(0.05)
        assert model.time == pytest.approx(0.05)
        assert np.all(np.isfinite(line.segment_tensions()))


def test_body_views(tmp_path):
    deck = _write(tmp_path, "body.dat", _BODY_DECK)
    with CableDyn(deck) as model:
        (body,) = model.bodies
        assert (body.id, body.name) == (1, "Body1")
        pose = body.pose()
        assert pose[2] == model.channel("Body1Pz")
        assert pose[3] == model.channel("Body1Rx")
        wrench = body.wrench()
        assert wrench[2] == model.channel("Body1Fz")
        assert wrench[3] == model.channel("Body1Mx")
        assert body.velocity()[2] == model.channel("Body1Vz")
        assert body.acceleration().shape == (6,)
        rot = body.rotation_matrix()
        np.testing.assert_allclose(rot @ rot.T, np.eye(3), atol=1e-12)
        assert len(model.lines) == 3 and len(model.points) >= 6
        assert model.body(1) is body
        model.step_held(0.01)
        assert np.all(np.isfinite(body.pose()))


def test_rod_views(tmp_path):
    deck = _write(tmp_path, "rod.dat", _ROD_DECK)
    with CableDyn(deck) as model:
        (rod,) = model.rods
        assert (rod.id, rod.n_nodes, rod.n_segments) == (1, 3, 2)
        nodes = rod.node_positions()
        np.testing.assert_array_equal(rod.end_a(), nodes[0])
        np.testing.assert_array_equal(rod.end_b(), nodes[-1])
        assert nodes[2, 2] == model.channel("Rod1N2Pz")
        assert rod.pose()[2] == model.channel("Rod1Pz")
        assert rod.pose()[5] == 0.0
        assert rod.wrench()[2] == model.channel("Rod1Fz")
        assert rod.velocity().shape == (6,)
        assert np.linalg.norm(rod.axis()) == pytest.approx(1.0)
        assert model.rod(1) is rod
        with pytest.raises(KeyError):
            model.rod(7)


def test_channel_errors_and_stale_views(tmp_path):
    deck = _held_chain(tmp_path)
    model = CableDyn(deck)
    for bad in (
        "",
        "x" * 65,
        "L1N99px",
        "Line1",
        "FairTen9",
        "AnchFz9",
        "AnchFz1x",
        "L1N5q",
        "Body1Pz",
        "TDP1s",
        "TDP1Grd",
    ):
        with pytest.raises((CableDynError, ValueError)):
            model.channel(bad)
    with pytest.raises(TypeError):
        model.channel(3)  # type: ignore[arg-type]
    with pytest.raises(KeyError):
        model.line(5)
    line = model.lines[0]
    model.init_deck(deck)
    assert model.time == 0.0
    with pytest.raises(CableDynError, match="stale"):
        line.node_positions()
    fresh = model.lines[0]
    assert fresh is not line and fresh.n_nodes == 42
    model.close()
    with pytest.raises(CableDynError, match="stale"):
        fresh.node_tensions()
    assert "Line1" in repr(fresh)


def test_unbound_handle_and_raw_lines(monkeypatch, tmp_path):
    with CableDyn() as model:
        with pytest.raises(CableDynError, match="NOT_INITIALIZED"):
            model.lines  # noqa: B018
    # an old library without the object queries fails with a clear message
    monkeypatch.setattr(_lib, "abi_minor", lambda: 0)
    with CableDyn(_held_chain(tmp_path)) as model:
        with pytest.raises(RuntimeError, match="predates the object queries"):
            model.points  # noqa: B018


def test_abi_minor_is_reported():
    assert _lib.OBJECT_QUERY_ABI_MINOR == 1
    assert _lib.abi_minor() == cabledyn.abi_minor() == _lib.HOST_FLUID_ABI_MINOR == 4
    assert objects_module.OBJ_ROD == 4


def test_finite_ei_deck_needs_the_coupling_step(tmp_path):
    text = (EXAMPLES / "lazy_wave_modes.dat").read_text(encoding="utf-8")
    text = text.replace("10       nModes", "0        nModes")
    kept = [row for row in text.splitlines() if " dtM " not in row and " TMax " not in row]
    deck = _write(tmp_path, "no_dtm.dat", "\n".join(kept) + "\n")
    with pytest.raises(CableDynError, match="finite-EI lines, BODIES or RODS needs dtM"):
        CableDyn(deck)


def test_channel_tokens_must_be_ascii(tmp_path):
    with CableDyn(_held_chain(tmp_path)) as model:
        with pytest.raises(ValueError, match=r"1..64 ASCII characters"):
            model.channel("FairTen\u00b91")


@pytest.mark.parametrize("token", ["FairTen1\x00", "FairTen1\x00x", "\x00FairTen1"])
def test_channel_tokens_must_not_hold_a_nul(tmp_path, token):
    # the library reads a token up to its first NUL: "FairTen1\0x" would read as FairTen1
    with CableDyn(_held_chain(tmp_path)) as model:
        with pytest.raises(ValueError, match="NUL"):
            model.channel(token)
        with pytest.raises(ValueError, match="NUL"):
            model.channels(["FairTen1", token])


def test_zero_length_rod_axis_is_a_value_error(tmp_path, monkeypatch):
    deck = _write(tmp_path, "rod.dat", _ROD_DECK)
    with CableDyn(deck) as model:
        (rod,) = model.rods
        monkeypatch.setattr(type(rod), "node_positions", lambda self, out=None: np.zeros((3, 3)))
        with pytest.raises(ValueError, match="zero length"):
            rod.axis()


def test_c_api_takes_bodies_or_rods_not_both(tmp_path):
    # the C API runs a deck with bodies or rods on the coupled aggregate, which marches one of the
    # two families: a rod fixed to the buoy is refused by name, saying where such a deck runs
    bar = "-" * 21
    base = (EXAMPLES / "rigid6_buoy.dat").read_text(encoding="utf-8")
    # still water and a fluid-inert buoy (the aggregate refuses CdA/Ca without a host field)
    base = base.replace("uniform 0.6 0.0 0.0  current", "none  current", 1)
    base = base.replace("0.0  0.0  0.0  8.0   0.5  3.5e4", "0.0  0.0  0.0  0.0   0.0  3.5e4", 1)
    marker = f"{bar} POINTS"
    rods = (
        f"{bar} ROD TYPES {bar}\nName Diam Mass Cd Ca CdEnd CaEnd\n"
        "spar 1.0 300.0 0.8 1.0 0.0 0.0\n"
        f"{bar} RODS {bar}\nID RodType Type XA YA ZA XB YB ZB NumSegs Outputs\n"
        "1 spar Body1 0 0 -2 0 0 -8 2 -\n"
    )
    assert base.count(marker) == 1
    deck = tmp_path / "buoy_rod.dat"
    deck.write_text(base.replace(marker, rods + marker), encoding="utf-8")
    with CableDyn() as model, pytest.raises(CableDynError) as err:
        model.init_deck(deck)
    message = str(err.value)
    assert "a coupled deck with both BODIES and RODS is not supported" in message
    assert "CompMooring = 3" in message and "standalone driver" in message
    still = tmp_path / "buoy.dat"
    still.write_text(base, encoding="utf-8")
    with CableDyn() as model:
        model.init_deck(still)


_SPLIT_LINE_DECK = """Split line: an EI = 0 chain section and a finite-EI section of one line
--- LINE TYPES ---
Name Diam Mass EA BA EI Cdn Cdt Can Cat
chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0
stiff 0.252 390.0 1.674e9 -1.0 1.0e4 1.37 0.64 1.0 0.0
--- POINTS ---
ID Type X Y Z Mass Vol CdA Ca
1 Fixed 400.0 0.0 -50.0 0 0 0 0
2 Coupled 0.0 0.0 0.0 0 0 0 0
--- LINES ---
ID NodeA NodeB Outputs
1 2 1 -
--- SECTIONS ---
LineID LineType Length NumSegs
{sections}--- OPTIONS ---
9.80665 g
1025.0 rhoW
50.0 WtrDpth
0.1 dtM
1.0 TMax
{motion}--- OUTPUTS ---
FairTen1
AnchTen1
L1N10px
L1N10pz
Ten1N30
L1N35pz
Curv1N35
--- need this line ---
"""


def _surge(t: float) -> tuple[float, float, float]:
    """A smooth 0.5 m surge of the fairlead from rest over the first second."""
    s = min(max(t, 0.0), 1.0)
    return (
        0.5 * (10 * s**3 - 15 * s**4 + 6 * s**5),
        0.5 * (30 * s**2 - 60 * s**3 + 30 * s**4),
        0.5 * (60 * s - 180 * s**2 + 120 * s**3),
    )


@needs_driver
@pytest.mark.parametrize(
    "sections",
    ["1 chain 200.0 20\n1 stiff 210.0 21\n", "1 stiff 210.0 21\n1 chain 200.0 20\n"],
    ids=["chain-at-fairlead", "chain-at-anchor"],
)
def test_split_line_runs_standalone_as_on_the_c_api(tmp_path, sections):
    # a line of EI = 0 and finite-EI sections is one finite-EI cable on every route
    times = [round(0.1 * k, 10) for k in range(11)]
    (tmp_path / "m.txt").write_text(
        "".join(
            f"{t:.10g} 2 {_surge(t)[0]!r} 0 0 {_surge(t)[1]!r} 0 0 {_surge(t)[2]!r} 0 0\n"
            for t in times
        ),
        encoding="utf-8",
    )
    deck = _write(
        tmp_path,
        "split.dat",
        _SPLIT_LINE_DECK.format(sections=sections, motion="m.txt motionFile\n"),
    )
    result = _driver_run(deck, tmp_path)
    main = result.read_main()
    channels = list(main.channels[1:])
    host = _write(tmp_path, "split_host.dat", _SPLIT_LINE_DECK.format(sections=sections, motion=""))
    with CableDyn(host) as model:
        (line,) = model.lines
        assert line.finite_ei
        q0, _, _ = model.get_coupled_motion()
        for k, t in enumerate(times):
            if k:
                x, v, a = _surge(t)
                model.step(
                    0.1,
                    q0 + np.array([x, 0.0, 0.0]),
                    np.array([v, 0.0, 0.0]),
                    np.array([a, 0.0, 0.0]),
                )
            row = int(np.argmin(np.abs(main.values[:, 0] - t)))
            assert abs(main.values[row, 0] - t) < 1.0e-9
            _assert_close(model.channels(channels), main.values[row, 1:], f"channels at t={t}")
