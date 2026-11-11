# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""The notes of an initialisation, read in-process: the ``Note:`` lines of a driver run."""

from __future__ import annotations

import math
import os
import re
import subprocess
from pathlib import Path

import pytest

try:
    from cabledyn import _lib
except OSError as exc:
    pytest.skip(f"CableDyn shared library not available: {exc}", allow_module_level=True)

from cabledyn.errors import CableDynError
from cabledyn.model import CableDyn

ROOT = Path(__file__).resolve().parents[2]
EXAMPLES = ROOT / "examples"
DRIVER = os.environ.get("CABLEDYN_TEST_DRIVER", "").strip() or os.environ.get("CABLEDYN_DRIVER", "")
DRIFT = "on the seabed at the static start with no seabed friction"
CURRENT = "uniform 0.5 0 0 current"
# a Currents 2 table that holds one current over its 1 s
CONSTANT_GRID = (
    "dynamic\n\n\n\n-50.0 0.0\nt ux... uy...\n0.0 0.1 0.1 0.0 0.0\n1.0 0.1 0.1 0.0 0.0\n"
)
_BAR = "-" * 21
_DECK = f"""{_BAR} CableDyn Input File {_BAR}
a grounded chain
{_BAR} LINE TYPES {_BAR}
Name Diam Mass EA BA EI Cdn Cdt Can Cat
chain 0.252 390.0 1.674e9 -1.0 @EI@ 1.37 0.64 1.0 0.0
{_BAR} POINTS {_BAR}
ID Type X Y Z Mass Vol CdA Ca
1 Fixed 400.0 0.0 -50.0 0 0 0 0
2 Coupled 0.0 0.0 0.0 0 0 0 0
{_BAR} LINES {_BAR}
ID NodeA NodeB Outputs
1 2 1 -
{_BAR} SECTIONS {_BAR}
LineID LineType Length NumSegs
1 chain 410.0 41
{_BAR} OPTIONS {_BAR}
9.80665 g
1025.0 rhoW
50.0 WtrDpth
@DTM@ dtM
10.0 TMax
@OPTIONS@
{_BAR} OUTPUTS {_BAR}
FairTen1
@OUTPUTS@
{_BAR} need this line {_BAR}
"""


def _deck(
    tmp_path: Path,
    *options: str,
    ei: float = 0.0,
    dtm: float = 0.02,
    outputs: str = "",
    name: str = "deck.dat",
) -> Path:
    path = tmp_path / name
    text = _DECK.replace("@EI@", str(ei)).replace("@DTM@", str(dtm))
    text = text.replace("@OPTIONS@", "\n".join(options)).replace("@OUTPUTS@", outputs)
    path.write_text(text, encoding="utf-8")
    return path


def _drift(notes: list[str]) -> list[str]:
    return [note for note in notes if DRIFT in note]


@pytest.mark.parametrize("ei", [0.0, 1.0e6], ids=["point", "aggregate"])
def test_the_drift_note_reaches_an_in_process_host(tmp_path, ei):
    with CableDyn(_deck(tmp_path, CURRENT, ei=ei)) as model:
        notes = _drift(model.init_notes)
    assert len(notes) == 1
    assert "line 1 lies" in notes[0] and "Set frictionMu to hold it" in notes[0]
    assert notes[0].endswith(".") and not notes[0].startswith("Note:")


@pytest.mark.parametrize("ei", [0.0, 1.0e6], ids=["point", "aggregate"])
@pytest.mark.parametrize("rows", [(), (CURRENT, "0.5 frictionMu")], ids=["still", "friction"])
def test_no_drift_note_where_it_is_not_true(tmp_path, ei, rows):
    with CableDyn(_deck(tmp_path, *rows, ei=ei)) as model:
        assert _drift(model.init_notes) == []


@pytest.mark.parametrize("ei", [0.0, 1.0e6], ids=["ei0", "finite"])
def test_a_host_field_keeps_the_deck_steady_current(tmp_path, ei):
    with CableDyn() as model:
        model.set_host_fluid(True)
        model.init_deck(_deck(tmp_path, CURRENT, ei=ei))
        assert len(_drift(model.init_notes)) == 1


def test_a_field_applied_after_init_is_not_known(tmp_path):
    with CableDyn() as model:
        model.set_host_fluid(True)
        model.init_deck(_deck(tmp_path))
        assert _drift(model.init_notes) == []


def test_the_notes_of_a_deck_on_both_routes(tmp_path):
    # rhoInf and the node numbering come from the deck; the step from the line
    rows = ("0.99 rhoInf",)
    for ei in (0.0, 1.0e6):
        with CableDyn(_deck(tmp_path, *rows, ei=ei, dtm=0.1, outputs="Ten1N5")) as model:
            notes = "\n".join(model.init_notes)
        assert "rhoInf = 0.990 leaves almost no numerical dissipation" in notes
        assert "line nodes are numbered from 1 = End A" in notes
        assert "LINE 1: dtM = 0.1000 s resolves its axial period" in notes


@pytest.mark.parametrize("ei", [0.0, 1.0e6], ids=["point", "aggregate"])
def test_the_axial_damping_note_reaches_an_in_process_host(tmp_path, ei):
    # BA = -1 is a damping ratio per segment: the note gives the first-mode ratio of the mesh
    with CableDyn(_deck(tmp_path, ei=ei)) as model:
        notes = [note for note in model.init_notes if "damping ratio per segment" in note]
    assert len(notes) == 1
    match = re.search(r"at ([0-9.]+) % of critical on its ([0-9]+) elements", notes[0])
    assert match is not None, notes[0]
    # zeta pi/(2N) on the uniform chain, N its final mesh
    expected = 100.0 * math.pi / (2 * int(match.group(2)))
    assert float(match.group(1)) == pytest.approx(expected, rel=1e-3)
    with CableDyn(_deck(tmp_path, "mode1 axialDampingRatio", ei=ei, name="mode1.dat")) as model:
        assert not [note for note in model.init_notes if "damping ratio per segment" in note]


def test_a_note_of_the_parse_is_kept_once(tmp_path):
    # the deck is read twice, to find its route and to build it
    (tmp_path / "current_profile_dynamic.txt").write_text(CONSTANT_GRID, encoding="utf-8")
    with CableDyn(_deck(tmp_path, "2 Currents")) as model:
        notes = model.init_notes
    assert len([note for note in notes if "TMax outlasts the last sample" in note]) == 1
    assert len(notes) == len(set(notes))


def _free_point_deck(tmp_path: Path, friction: str = "none") -> Path:
    # the shipped clump weight in a current, on a chain long enough for a run on the seabed
    text = (EXAMPLES / "clump_weight_free_point.dat").read_text(encoding="utf-8")
    for old, new in (
        ("chain      250.0", "chain      300.0"),
        ("none      current", CURRENT),
        ("none      frictionMu", f"{friction} frictionMu"),
    ):
        assert old in text, old
        text = text.replace(old, new)
    path = tmp_path / "free_point.dat"
    path.write_text(text, encoding="utf-8")
    return path


@pytest.mark.parametrize("host_fluid", [False, True], ids=["point", "aggregate"])
def test_a_route_without_friction_says_so(tmp_path, host_fluid):
    with CableDyn() as model:
        model.set_host_fluid(host_fluid)
        model.init_deck(_free_point_deck(tmp_path))
        notes = _drift(model.init_notes)
        assert len(notes) == 1
        assert "line 1 lies" in notes[0]
        assert "Seabed friction (frictionMu), which would hold it, is not supported" in notes[0]
        with pytest.raises(CableDynError, match="seabed friction is not supported"):
            model.init_deck(_free_point_deck(tmp_path, "0.5"))


def test_a_failed_initialisation_keeps_its_notes_and_the_model(tmp_path):
    with CableDyn(_deck(tmp_path, CURRENT)) as model:
        assert _drift(model.init_notes)
        n_lines = model.n_lines
        (tmp_path / "current_profile_dynamic.txt").write_text(CONSTANT_GRID, encoding="utf-8")
        bad = _deck(tmp_path, "2 Currents", "r.txt vesselRAO", name="bad.dat")
        with pytest.raises(CableDynError):
            model.init_deck(bad)
        assert _drift(model.init_notes) == []
        assert model.n_lines == n_lines


def test_a_new_initialisation_replaces_the_notes(tmp_path):
    with CableDyn(_deck(tmp_path, CURRENT)) as model:
        assert _drift(model.init_notes)
        model.init_deck(_deck(tmp_path, name="still.dat"))
        assert _drift(model.init_notes) == []


def test_a_new_handle_has_no_notes():
    with CableDyn() as model:
        assert model.init_notes == []


@pytest.mark.skipif(
    not DRIVER or not Path(DRIVER).is_file(),
    reason="set CABLEDYN_TEST_DRIVER to a built native driver to compare the notes of a run",
)
@pytest.mark.parametrize(
    ("deck", "host_fluid"),
    [
        ("dynamic_chain_current", False),
        ("dynamic_chain_held", False),
        ("connect_weighted_point", False),
        ("lazy_wave_buoyancy_smeared", False),
        ("clump_weight_free_point", False),
        ("rod_moored_spar", True),
    ],
)
def test_the_notes_match_those_of_a_driver_run(tmp_path, deck, host_fluid):
    text = (EXAMPLES / f"{deck}.dat").read_text(encoding="utf-8")
    text = re.sub(r"^[ \t]*\S+[ \t]+TMax\b.*$", "0.1  TMax", text, count=1, flags=re.M)
    text = re.sub(r"^[ \t]*\S+[ \t]+dtM\b.*$", "0.05  dtM", text, count=1, flags=re.M)
    path = tmp_path / f"{deck}.dat"
    path.write_text(text, encoding="utf-8")
    run = subprocess.run(
        [DRIVER, path.name, deck],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        timeout=600,
        check=False,
    )
    assert run.returncode == 0, run.stdout + run.stderr
    # stderr holds the initialisation report; stdout the start of the run, then the march
    start = run.stdout.split("Dynamic simulation:")[0]
    printed = {m.group(1).strip() for m in re.finditer(r"Note: (.*)", run.stderr + "\n" + start)}
    with CableDyn() as model:
        model.set_host_fluid(host_fluid)
        model.init_deck(path)
        notes = set(model.init_notes)
    assert printed <= notes, printed - notes


def test_a_library_without_the_notes_call_still_loads(monkeypatch):
    # a library of ABI minor 4 can predate the entry point: only init_notes may refuse
    monkeypatch.setattr(_lib, "_has_init_notes", False)
    with CableDyn() as model, pytest.raises(RuntimeError, match="CableDyn_GetInitNotes"):
        _ = model.init_notes
