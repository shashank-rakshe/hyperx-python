# SPDX-License-Identifier: Apache-2.0
"""End-to-end gates against the real native driver on shipped example decks.

Skipped unless ``CABLEDYN_DRIVER`` names a built ``CableDyn_driver``/``cabledyn``
executable. These prove the wrapper, readers, and post-processing against the
files the solver really writes, not synthetic stand-ins.
"""

from __future__ import annotations

import json
import os
import shutil
from pathlib import Path

import numpy as np
import pytest

from cabledyn import (
    CableDynDriver,
    DeckFile,
    DeckFormatError,
    DriverExecutionError,
    StaticProfile,
    compare_histories,
    fft_filter,
    generate_deck_cases,
    line_geometry,
    parameter_grid,
    resample,
    run_study,
)
from cabledyn import cli as run_cli
from cabledyn.post_cli import main as post_main

EXAMPLES = Path(__file__).resolve().parents[2] / "examples"
_DRIVER = os.environ.get("CABLEDYN_DRIVER", "").strip()

pytestmark = pytest.mark.skipif(
    not _DRIVER or not Path(_DRIVER).is_file(),
    reason="set CABLEDYN_DRIVER to a built native driver to run end-to-end gates",
)


@pytest.fixture
def driver() -> CableDynDriver:
    return CableDynDriver(_DRIVER)


def _copy(name: str, directory: Path) -> Path:
    target = directory / name
    shutil.copyfile(EXAMPLES / name, target)
    return target


def test_version_banner_names_the_program(driver):
    assert "CableDyn" in driver.version()


def test_static_catenary_profile_and_node_geometry_agree(driver, tmp_path):
    deck = _copy("chain_catenary_r3_100m.dat", tmp_path)
    result = driver.run(deck, "out/static", timeout=300)
    assert result.static_output is not None
    main = result.read_main()
    assert main.channels[0] == "Time(s)" and "FairTen1" in main.channels
    profile = result.read_static()
    assert isinstance(profile, StaticProfile) and profile.line_ids == (1,)
    summary = profile.summary(1)
    assert summary.maximum_tension is not None and summary.maximum_tension > 0.0
    assert main.column("FairTen1")[0] == pytest.approx(
        profile.line(1).column("Tension")[0], rel=1e-6
    )
    geometry = line_geometry(profile)
    # EI = 0 elements are straight, so the node chord length is the deformed arc
    # length up to the eight significant digits of the written table.
    assert geometry.length == pytest.approx(summary.deformed_length, rel=1e-6)
    # Node-based inclination matches the solver's (sign: rising towards End B).
    solver = profile.line(1).column("Inclination")
    interior = slice(1, -1)
    assert np.allclose(np.abs(geometry.inclination[interior]), np.abs(solver[interior]), atol=1.5)
    touchdown = geometry.touchdown(-100.0, tolerance=0.05)
    assert touchdown is not None and touchdown.grounded_end == "B"
    assert 0.0 < touchdown.suspended_length < geometry.length


def test_dynamic_run_supports_the_full_post_processing_chain(driver, tmp_path):
    deck = _copy("dynamic_chain_waves.dat", tmp_path)
    result = driver.run(deck, "waves", timeout=600)
    history = result.read_main()
    assert history.time[0] == 0.0 and history.time[-1] == pytest.approx(10.0)
    tension = history.statistics("FairTen1")[0]
    assert tension.minimum < tension.mean < tension.maximum
    spectrum = history.spectrum("FairTen1", segment_length=64)
    assert spectrum.dominant_peaks(1)[0].frequency == pytest.approx(1.0 / 8.0, abs=0.2)
    fatigue = history.fatigue("FairTen1", wohler_exponent=3.0, reference_frequency=1.0)
    assert fatigue.damage_equivalent_range > 0.0
    smooth = fft_filter(history, high=0.5, channels="FairTen1")
    assert smooth.values.shape == history.values.shape
    coarse = resample(history, step=0.5)
    comparison = compare_histories(history, coarse, grid="candidate")
    assert comparison.channel("FairTen1").max_abs_difference == pytest.approx(0.0, abs=1e-6)
    # A rerun reproduces the same history bit for bit.
    rerun = driver.run(deck, "waves_rerun", timeout=600).read_main()
    repeat = compare_histories(history, rerun)
    assert all(item.max_abs_difference == 0.0 for item in repeat.channels)


def test_finite_ei_power_cable_writes_the_element_table(driver, tmp_path):
    deck = _copy("lozon_gomex80_power_cable.dat", tmp_path)
    result = driver.run(deck, "cable", timeout=600)
    assert result.elements_output is not None and result.elements_output.is_file()
    profile = result.read_static()
    summary = profile.summaries()[0]
    assert summary.maximum_curvature is not None and summary.minimum_bend_radius is not None
    assert summary.minimum_bend_radius > 0.0


def test_failed_rerun_keeps_the_previous_real_results(driver, tmp_path):
    deck = _copy("chain_catenary_r3_100m.dat", tmp_path)
    driver.run(deck, "keep", timeout=300)
    before = (tmp_path / "keep.out").read_bytes()
    broken = tmp_path / "broken.dat"
    broken.write_text(
        deck.read_text(encoding="utf-8").replace("chainR3", "chainR4", 1), encoding="utf-8"
    )
    with pytest.raises(DriverExecutionError) as caught:
        driver.run(broken, "keep", overwrite=True, timeout=300)
    assert caught.value.returncode == 1
    assert "CableDyn_driver" in caught.value.stderr or "CableDyn" in caught.value.stderr
    assert (tmp_path / "keep.out").read_bytes() == before


def test_cabledyn_run_cli_with_the_real_driver(tmp_path, capsys):
    deck = _copy("wd0050_chain.dat", tmp_path)
    assert run_cli.main([str(deck), "cli_run", "--executable", _DRIVER, "--timeout", "300"]) == 0
    main_output = Path(capsys.readouterr().out.strip())
    assert main_output == tmp_path / "cli_run.out"
    assert post_main(["summary", str(main_output)]) == 0
    assert "FairTen1" in capsys.readouterr().out


def test_generated_study_runs_on_the_real_driver(tmp_path):
    deck = _copy("chain_catenary_r3_100m.dat", tmp_path)
    cases = parameter_grid({"option.kBot": [1.0e5, 3.0e5]}, prefix="kbot")
    generate_deck_cases(deck, tmp_path / "cases", cases)
    result = run_study(
        tmp_path / "cases" / "cases.json",
        executable=_DRIVER,
        jobs=2,
        channels=["FairTen1"],
        timeout=300,
    )
    assert result.passed
    record = json.loads(result.study_manifest.read_text(encoding="utf-8"))
    assert [case["name"] for case in record["cases"]] == ["kbot000", "kbot001"]
    assert "CableDyn" in record["solver_version"]


# Deck variants on which the Python validator and the native reader must agree.
_PARITY = [
    ("ea-1e300", "chain_catenary_r3_100m.dat", "1.607e9    -1.0", "1e300    -1.0", False),
    ("mass-2e6", "chain_catenary_r3_100m.dat", "0.2466   373.5", "0.2466   2.0e6", False),
    ("diam-1001", "chain_catenary_r3_100m.dat", "0.2466   373.5", "1001.0   373.5", False),
    (
        "length-1e300",
        "chain_catenary_r3_100m.dat",
        "chainR3    550.0    55",
        "chainR3    1e300    55",
        False,
    ),
    (
        "length-1e-300",
        "chain_catenary_r3_100m.dat",
        "chainR3    550.0    55",
        "chainR3    1e-300   55",
        False,
    ),
    (
        "syrope-unquoted",
        "syrope_polyester_mooring.dat",
        '"SYROPE:data/syrope/syrope_settings.dat|1.53e8|23.12"',
        "SYROPE:data/syrope/syrope_settings.dat|1.53e8|23.12",
        True,
    ),
    ("ba-separator", "chain_catenary_r3_100m.dat", "1.607e9    -1.0", "1.607e9    1,5", False),
    ("quoted-name-space", "chain_catenary_r3_100m.dat", "chainR3", '"chain R3"', True),
    ("outputs-comma", "chain_catenary_r3_100m.dat", '"FairTen1"', "FairTen1,Point1px", True),
    ("outputs-long", "chain_catenary_r3_100m.dat", '"FairTen1"', "FairTen1" + "x" * 60, False),
    ("con-alias", "chain_catenary_r3_100m.dat", '"FairTen1"', "Con2pz", True),
    ("name-65", "chain_catenary_r3_100m.dat", "chainR3", "c" * 65, False),
    (
        "stock-plus-sections",
        "chain_catenary_r3_100m.dat",
        "1     2       1       -",
        "1 chainR3 2 1 275.0 25 -",
        False,
    ),
    (
        "outputs-duplicate-alias",
        "chain_catenary_r3_100m.dat",
        '"FairTen1"',
        '"FairTen1" FairDecl1 FairAngle1',
        False,
    ),
    (
        "outputs-duplicate-padded",
        "chain_catenary_r3_100m.dat",
        '"FairTen1"',
        '"FairTen1" L1N3px l01n03PX',
        False,
    ),
    (
        "outputs-duplicate-con",
        "chain_catenary_r3_100m.dat",
        '"FairTen1"',
        '"FairTen1" Con2pz Point2pz',
        False,
    ),
    (
        "outputs-duplicate-case",
        "chain_catenary_r3_100m.dat",
        '"FairTen1"',
        '"FairTen1", fairten01',
        False,
    ),
    (
        "outputs-distinct",
        "chain_catenary_r3_100m.dat",
        '"FairTen1"',
        '"FairTen1" FairDecl1 Point2pz Point2px Ten1N3 Curv1N3 L1N3Dec',
        True,
    ),
    (
        "anchor-below-seabed",
        "chain_catenary_r3_100m.dat",
        "100.0        WtrDpth",
        "99.9         WtrDpth",
        False,
    ),
    (
        "anchor-on-seabed-roundoff",
        "chain_catenary_r3_100m.dat",
        "-100.0    0 ",
        "-100.00005 0 ",
        True,
    ),
    (
        "no-water-depth",
        "chain_catenary_r3_100m.dat",
        "100.0        WtrDpth   - Water depth (m) "
        "[default: absent standalone; host-owned OpenFAST]\n",
        "",
        True,
    ),
]


@pytest.mark.parametrize(
    ("label", "example", "old", "new", "accepted"), _PARITY, ids=[item[0] for item in _PARITY]
)
def test_deck_validator_agrees_with_the_native_reader(
    driver, tmp_path, label, example, old, new, accepted
):
    if example.startswith("syrope"):
        shutil.copytree(EXAMPLES / "data" / "syrope", tmp_path / "data" / "syrope")
    text = (EXAMPLES / example).read_text(encoding="utf-8")
    assert old in text
    deck = tmp_path / f"{label}.dat"
    deck.write_text(text.replace(old, new), encoding="utf-8")
    try:
        DeckFile.read(deck)
        python_accepts = True
    except DeckFormatError:
        python_accepts = False
    try:
        driver.run(deck, label, timeout=300)
        native_accepts = True
    except DriverExecutionError as exc:
        assert exc.returncode == 1, exc.stderr  # a deck error, not a solve failure
        native_accepts = False
    assert python_accepts == native_accepts == accepted
