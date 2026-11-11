# SPDX-License-Identifier: Apache-2.0
"""Snapshots: recording, output-file collection, npz archives and animation."""

from __future__ import annotations

import math
import os
import re
from pathlib import Path

import numpy as np
import pytest

from cabledyn.animation import (
    FORMAT,
    Seabed,
    Snapshots,
    WaterSurface,
    animate,
    record,
    seabed_from_deck,
)
from cabledyn.clearance import Bathymetry
from cabledyn.errors import OutputFormatError

REPO = Path(__file__).resolve().parents[2]
EXAMPLES = REPO / "examples"


def _snapshots(**extra: object) -> Snapshots:
    times = np.array([0.0, 0.5, 1.0])
    line = np.zeros((3, 4, 3))
    line[:, :, 0] = np.linspace(0.0, 30.0, 4)
    line[:, :, 2] = -10.0 + np.arange(3)[:, None]
    kwargs: dict[str, object] = {
        "times": times,
        "lines": {2: line},
        "tensions": {2: np.ones((3, 3))},
        "points": {1: np.zeros((3, 3))},
        "bodies": {1: np.zeros((3, 6))},
        "rods": {1: np.zeros((3, 2, 3))},
    }
    kwargs.update(extra)
    return Snapshots(**kwargs)  # type: ignore[arg-type]


def test_snapshots_validate_and_index():
    snaps = _snapshots(seabed=Seabed(depth=20.0), water=WaterSurface(1.0, 5.0, 30.0, 20.0))
    assert snaps.n_frames == 3 and snaps.index_at(0.7) == 1
    frame = snaps.frame(2)
    assert frame["lines"][2][0, 2] == -8.0 and set(frame) >= {"points", "bodies", "rods"}
    lo, hi = snaps.bounds()
    np.testing.assert_array_equal(lo, [0.0, 0.0, -10.0])
    np.testing.assert_array_equal(hi, [30.0, 0.0, 0.0])
    assert not snaps.times.flags.writeable
    with pytest.raises(ValueError, match="strictly increasing"):
        Snapshots(times=np.array([0.0, 0.0]))
    with pytest.raises(ValueError, match="non-empty"):
        Snapshots(times=np.array([]))
    with pytest.raises(ValueError, match="expected 3 samples"):
        _snapshots(points={1: np.zeros((2, 3))})
    with pytest.raises(ValueError, match="no geometry"):
        Snapshots(times=np.zeros(1)).bounds()


def test_npz_round_trip(tmp_path):
    grid = Bathymetry(np.array([0.0, 10.0]), np.array([0.0, 5.0]), np.full((2, 2), 30.0))
    for seabed, water, compress in (
        (Seabed(depth=20.0), WaterSurface(2.0, 8.0, 10.0, None, 9.81, 5.0), True),
        (Seabed(bathymetry=grid), WaterSurface(unmodelled=True), False),
        (None, None, True),
    ):
        snaps = _snapshots(seabed=seabed, water=water)
        path = snaps.save_npz(tmp_path / "sub" / "run", compress=compress)
        assert path.name == "run.npz"
        back = Snapshots.load_npz(path)
        np.testing.assert_array_equal(back.times, snaps.times)
        for group in ("lines", "tensions", "points", "bodies", "rods"):
            for key, value in getattr(snaps, group).items():
                np.testing.assert_array_equal(getattr(back, group)[key], value)
        assert back.water == water
        if seabed is not None and seabed.bathymetry is not None:
            assert back.seabed is not None and back.seabed.bathymetry is not None
            np.testing.assert_array_equal(back.seabed.bathymetry.depth, grid.depth)
        else:
            assert back.seabed == seabed
    np.savez(tmp_path / "other.npz", format=np.array("something-else"))
    with pytest.raises(OutputFormatError):
        Snapshots.load_npz(tmp_path / "other.npz")
    assert FORMAT.startswith("cabledyn-snapshots")


def test_water_surface_and_seabed():
    still = WaterSurface()
    assert still.still and still.wavenumber == 0.0
    assert np.all(still.elevation(3.0, [0.0, 1.0], 0.0) == 0.0)
    deep = WaterSurface(2.0, 10.0)
    assert deep.wavenumber == pytest.approx((2 * math.pi / 10.0) ** 2 / 9.80665)
    finite = WaterSurface(2.0, 10.0, 90.0, 20.0)
    k = finite.wavenumber
    assert 9.80665 * k * math.tanh(20.0 * k) == pytest.approx((2 * math.pi / 10.0) ** 2)
    # direction 90 deg: the wave travels along +y
    assert finite.elevation(0.0, 0.0, 0.0) == pytest.approx(1.0)
    assert finite.elevation(0.0, 0.0, math.pi / k) == pytest.approx(-1.0)
    ramped = WaterSurface(2.0, 10.0, ramp_time=10.0)
    assert ramped.elevation(0.0, 0.0, 0.0) == 0.0
    assert ramped.elevation(5.0, 0.0, 0.0) == pytest.approx(0.5 * math.cos(-math.pi))
    assert ramped.elevation(20.0, 0.0, 0.0) == pytest.approx(1.0)
    with pytest.raises(ValueError):
        Seabed()
    with pytest.raises(ValueError):
        Seabed(depth=-1.0)
    flat = Seabed(depth=50.0)
    gx, _gy, gz = flat.grid((0.0, 10.0), (0.0, 5.0), 3)
    assert gx.shape == (3, 3) and np.all(gz == -50.0)
    grid = Seabed(
        bathymetry=Bathymetry(
            np.array([0.0, 10.0]), np.array([0.0, 1.0]), np.array([[10.0, 10.0], [20.0, 20.0]])
        )
    )
    assert grid.elevation(5.0, 0.5) == pytest.approx(-15.0)


def test_deck_environment():
    airy = WaterSurface.from_deck(EXAMPLES / "airy_wave_shallow_chain.dat")
    assert (airy.height, airy.period, airy.ramp_time) == (8.0, 10.0, 10.0)
    assert not airy.still and airy.depth is not None
    irregular = WaterSurface.from_deck(EXAMPLES / "chain_torsethaugen_spread.dat")
    assert irregular.unmodelled and irregular.still
    calm = WaterSurface.from_deck(EXAMPLES / "dynamic_chain_held.dat")
    assert calm.still and not calm.unmodelled and calm.depth == 50.0
    seabed = seabed_from_deck(EXAMPLES / "dynamic_chain_held.dat")
    assert seabed == Seabed(depth=50.0)


def test_bathymetry_deck_seabed(tmp_path):
    grid = tmp_path / "bathy.txt"
    grid.write_text("0 0 50\n0 100 50\n500 0 60\n500 100 60\n", encoding="utf-8")
    text = (EXAMPLES / "dynamic_chain_held.dat").read_text(encoding="utf-8")
    text = text.replace("50.0         WtrDpth", "bathy.txt    bathymetryFile")
    deck = tmp_path / "deck.dat"
    deck.write_text(text, encoding="utf-8")
    seabed = seabed_from_deck(deck)
    assert seabed is not None and seabed.bathymetry is not None
    assert seabed.elevation(250.0, 50.0) == pytest.approx(-55.0)


def _write_run(root: Path, *, static: bool = False) -> None:
    """Driver-format files for two lines, a rod, a point and a body."""
    if static:
        (root.parent / f"{root.name}.Line1.p.out").write_text(
            "# CableDyn static line node positions; public node order EndA -> EndB\n"
            "Node\tX(m)\tY(m)\tZ(m)\n1\t0.0\t0.0\t-5.0\n2\t10.0\t0.0\t-20.0\n",
            encoding="utf-8",
        )
        return
    (root.parent / f"{root.name}.Line1.p.out").write_text(
        "Time(s)\tNode1X(m)\tNode1Y(m)\tNode1Z(m)\tNode2X(m)\tNode2Y(m)\tNode2Z(m)\n"
        "0.0\t0.0\t0.0\t-5.0\t10.0\t0.0\t-20.0\n"
        "1.0\t1.0\t0.0\t-5.0\t10.0\t0.0\t-20.0\n",
        encoding="utf-8",
    )
    (root.parent / f"{root.name}.Line1.t.out").write_text(
        "Time(s)\tSegment1Tension(N)\n0.0\t100.0\n1.0\t110.0\n", encoding="utf-8"
    )
    (root.parent / f"{root.name}.Rod3.p.out").write_text(
        "# rod\nTime(s)\tEndAX(m)\tEndAY(m)\tEndAZ(m)\tEndBX(m)\tEndBY(m)\tEndBZ(m)\n"
        "0.0\t0\t0\t-4\t0\t0\t-2\n0.5\t0\t0\t-4\t0\t0\t-2\n1.0\t0\t0\t-3\t0\t0\t-1\n",
        encoding="utf-8",
    )
    (root.parent / f"{root.name}.out").write_text(
        "Time(s)\tPoint4px\tPoint4py\tPoint4pz\tBody1Px\tBody1Py\tBody1Pz\tBody1Rz\n"
        "0.0\t1\t2\t3\t0\t0\t-10\t0\n0.5\t1\t2\t4\t0\t0\t-10\t5\n1.0\t1\t2\t5\t0\t0\t-10\t10\n",
        encoding="utf-8",
    )


def test_from_files_collects_every_object(tmp_path):
    root = tmp_path / "run"
    _write_run(root)
    snaps = Snapshots.from_files(root, deck=EXAMPLES / "dynamic_chain_held.dat")
    np.testing.assert_array_equal(snaps.times, [0.0, 1.0])
    assert snaps.lines[1].shape == (2, 2, 3) and snaps.lines[1][1, 0, 0] == 1.0
    np.testing.assert_array_equal(snaps.tensions[1][:, 0], [100.0, 110.0])
    # the rod and main-output series are interpolated onto the line sample times
    np.testing.assert_array_equal(snaps.rods[3][:, 0, 2], [-4.0, -3.0])
    np.testing.assert_array_equal(snaps.points[4], [[1, 2, 3], [1, 2, 5]])
    np.testing.assert_array_equal(snaps.bodies[1][:, 5], [0.0, 10.0])
    assert snaps.bodies[1][0, 3] == 0.0  # absent Rx channel reads zero
    assert snaps.seabed == Seabed(depth=50.0) and snaps.water is not None

    main_only = tmp_path / "main"
    (tmp_path / "main.out").write_text("Time(s)\tFairTen1\n0.0\t1.0\n1.0\t2.0\n", encoding="utf-8")
    snaps = Snapshots.from_files(main_only)
    assert snaps.n_frames == 2 and not snaps.lines and snaps.seabed is None

    static = tmp_path / "static"
    _write_run(static, static=True)
    snaps = Snapshots.from_files(static)
    assert snaps.n_frames == 1 and snaps.lines[1][0, 1, 2] == -20.0

    with pytest.raises(FileNotFoundError):
        Snapshots.from_files(tmp_path / "missing")


def test_from_static_profile(tmp_path):
    path = tmp_path / "run.static.out"
    path.write_text(
        "CableDyn static\nLineID\tNode\tArcLength\tX\tY\tZ\tTension\n"
        "(-)\t(-)\t(m)\t(m)\t(m)\t(m)\t(N)\n"
        "1\t1\t0.0\t0.0\t0.0\t-5.0\t10.0\n1\t2\t5.0\t3.0\t0.0\t-9.0\t9.0\n"
        "2\t1\t0.0\t0.0\t1.0\t-5.0\t10.0\n2\t2\t5.0\t0.0\t4.0\t-9.0\t9.0\n",
        encoding="utf-8",
    )
    snaps = Snapshots.from_static(path, deck=EXAMPLES / "dynamic_chain_held.dat")
    assert sorted(snaps.lines) == [1, 2] and snaps.lines[2][0, 1, 1] == 4.0
    assert snaps.seabed == Seabed(depth=50.0)
    main = tmp_path / "main.out"
    main.write_text("Time(s)\tFairTen1\n0.0\t1.0\n", encoding="utf-8")
    with pytest.raises(OutputFormatError):
        Snapshots.from_static(main)


@pytest.mark.filterwarnings("ignore:Animation was deleted")
def test_animate_draws_every_frame(tmp_path):
    matplotlib = pytest.importorskip("matplotlib")
    matplotlib.use("Agg")
    snaps = _snapshots(seabed=Seabed(depth=20.0), water=WaterSurface(1.0, 5.0, 0.0, 20.0))
    anim = animate(snaps, stride=2, grid=4)
    anim._draw_was_started = True  # drawn frame by frame below, never saved
    for index in (0, 2):
        artists = anim._func(index)
        assert artists[0].get_data_3d()[2][0] == pytest.approx(-10.0 + index)
    calm = _snapshots(points={}, bodies={}, water=WaterSurface())
    import matplotlib.pyplot as plt

    fig = plt.figure()
    ax = fig.add_subplot(projection="3d")
    anim = animate(calm, ax=ax, seabed=False)
    anim._draw_was_started = True
    anim._func(1)
    with pytest.raises(ValueError):
        animate(calm, stride=0)
    plt.close("all")


# --- recording an in-process model --------------------------------------------


def _model_or_skip():
    try:
        import cabledyn._lib  # noqa: F401  (loads the shared library)
    except (ImportError, OSError) as exc:  # a missing library raises OSError
        pytest.skip(f"CableDyn shared library not available: {exc}")
    from cabledyn.model import CableDyn

    return CableDyn


def test_record_matches_the_model_and_round_trips(tmp_path):
    model_cls = _model_or_skip()
    with model_cls(EXAMPLES / "dynamic_chain_held.dat") as model:
        q0, _, _ = model.get_coupled_motion()

        def surge(t: float):
            q = q0.copy()
            q[3] += 2.0 * math.sin(2 * math.pi * t / 10.0)  # point 2 (the fairlead) x
            v = np.zeros_like(q)
            v[3] = 2.0 * (2 * math.pi / 10.0) * math.cos(2 * math.pi * t / 10.0)
            a = np.zeros_like(q)
            a[3] = -2.0 * (2 * math.pi / 10.0) ** 2 * math.sin(2 * math.pi * t / 10.0)
            return q, v, a

        snaps = record(model, 0.05, 20, every=5, motion=surge)
        assert snaps.n_frames == 5
        np.testing.assert_allclose(snaps.times, [0.0, 0.25, 0.5, 0.75, 1.0])
        np.testing.assert_array_equal(snaps.lines[1][-1], model.line(1).node_positions())
        np.testing.assert_array_equal(snaps.tensions[1][-1], model.line(1).segment_tensions())
        np.testing.assert_array_equal(snaps.points[2][-1], model.point(2).position())
        assert snaps.points[2][-1][0] == pytest.approx(2.0 * math.sin(2 * math.pi * 0.1))
        assert snaps.seabed == Seabed(depth=50.0)
        back = Snapshots.load_npz(snaps.save_npz(tmp_path / "rec.npz"))
        np.testing.assert_array_equal(back.lines[1], snaps.lines[1])
        held = record(model, 0.05, 2, tensions=False)
        assert held.n_frames == 3 and not held.tensions
        with pytest.raises(ValueError):
            record(model, 0.05, 2, every=0)
        with pytest.raises(ValueError):
            record(model, 0.05, -1)


def test_recorder_contract(tmp_path):
    model_cls = _model_or_skip()
    from cabledyn.animation import Recorder

    with model_cls(EXAMPLES / "dynamic_chain_held.dat") as model:
        recorder = Recorder(model)
        with pytest.raises(ValueError, match="no samples"):
            recorder.snapshots()
        recorder.sample()
        with pytest.raises(ValueError, match="does not advance"):
            recorder.sample()
        assert len(recorder) == 1


_DRIVER = (
    os.environ.get("CABLEDYN_TEST_DRIVER", "").strip()
    or os.environ.get("CABLEDYN_DRIVER", "").strip()
)


@pytest.mark.skipif(
    not _DRIVER or not Path(_DRIVER).is_file(),
    reason="set CABLEDYN_TEST_DRIVER to a built native driver to run the parity gate",
)
def test_driver_files_and_in_process_recording_agree(tmp_path):
    model_cls = _model_or_skip()
    import cabledyn

    text = (EXAMPLES / "dynamic_chain_held.dat").read_text(encoding="utf-8")
    text = text.replace("1     2       1       -", "1     2       1       pt")
    text = text.replace("10.0         TMax", "0.5         TMax")
    text = text.replace('"AnchIncl1"\n', '"AnchIncl1"\n"Point2px"\n"Point2py"\n"Point2pz"\n')
    deck = tmp_path / "held.dat"
    deck.write_text(text, encoding="utf-8")
    cabledyn.CableDynDriver(_DRIVER).run(deck, tmp_path / "held")
    files = Snapshots.from_files(tmp_path / "held", deck=deck)
    with model_cls(deck) as model:
        live = record(model, 0.05, 10, every=1)
    np.testing.assert_allclose(files.times, live.times, atol=1e-9)
    np.testing.assert_allclose(files.lines[1], live.lines[1], rtol=1e-7, atol=1e-5)
    np.testing.assert_allclose(files.tensions[1], live.tensions[1], rtol=1e-6)
    np.testing.assert_allclose(files.points[2], live.points[2], atol=1e-6)


def _sea_deck(tmp_path: Path, row: str) -> Path:
    text = (EXAMPLES / "dynamic_chain_held.dat").read_text(encoding="utf-8")
    # drop the still-water waves and WaterKin rows, then add the row under test
    text = re.sub(r"^none +waves .*\n", "", text, flags=re.MULTILINE)
    text = re.sub(r"^0 +WaterKin .*\n", "", text, flags=re.MULTILINE)
    text = text.replace("10.0         TMax", f"10.0         TMax\n{row}")
    deck = tmp_path / "sea.dat"
    deck.write_text(text, encoding="utf-8")
    return deck


@pytest.mark.parametrize("row", ["airy 2 8 0 wavetrain", "7 WaterKin", "kin.txt WaterKin"])
def test_decks_with_seas_the_surface_cannot_draw_are_flagged(tmp_path, row):
    surface = WaterSurface.from_deck(_sea_deck(tmp_path, row))
    assert surface.unmodelled and surface.still


@pytest.mark.parametrize("row", ["0 WaterKin", "none WaterKin", "0.1 dtWave"])
def test_still_water_deck_is_not_flagged(tmp_path, row):
    assert not WaterSurface.from_deck(_sea_deck(tmp_path, row)).unmodelled
