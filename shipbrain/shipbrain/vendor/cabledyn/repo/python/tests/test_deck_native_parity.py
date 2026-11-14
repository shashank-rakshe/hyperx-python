# SPDX-License-Identifier: Apache-2.0
"""Deck-validation rules that mirror the native reader and the standalone driver.

Each test pins one rule of ``src/CableDyn_DeckDriver.f90`` so that
:class:`cabledyn.DeckFile` neither rejects a deck the solver accepts nor
certifies one the solver refuses.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import numpy as np
import pytest

from cabledyn import DeckFile, DeckFormatError, StudyFormatError, generate_deck_cases, run_study
from cabledyn.builder import DeckModel, OptionSet

ROOT = Path(__file__).resolve().parents[2]
EXAMPLES = ROOT / "examples"

_BAR = "-" * 21
# A held chain on a dynamic clock (the static reference plus dtM/TMax).
_HELD = f"""\
{_BAR} CableDyn Input File {_BAR}
in-memory fixture: one grounded chain line on a dynamic clock
{_BAR} LINE TYPES {_BAR}
Name Diam Mass EA BA EI Cdn Cdt Can Cat
chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0
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
0.1 dtM
10.0 TMax
{_BAR} OUTPUTS {_BAR}
FairTen1
{_BAR} need this line {_BAR}
"""
_STATIC = _HELD.replace("0.1 dtM\n10.0 TMax\n", "")
_WAVE_FREQUENCIES = "0 0 0 0\n0.5 0.5 0 0\n0.6 0.3 0.1 0\n"


def _edit(base: str, *edits: tuple[str, str]) -> str:
    text = base
    for old, new in edits:
        assert old in text, old
        text = text.replace(old, new, 1)
    return text


def _options(base: str, *rows: str) -> str:
    return _edit(base, ("50.0 WtrDpth\n", "50.0 WtrDpth\n" + "".join(f"{r}\n" for r in rows)))


def _example(name: str, *edits: tuple[str, str]) -> str:
    return _edit((EXAMPLES / name).read_text(encoding="utf-8"), *edits)


def _section(base: str, heading: str, *rows: str) -> str:
    block = f"{_BAR} {heading} {_BAR}\n" + "".join(f"{row}\n" for row in rows)
    marker = next(line for line in base.splitlines() if "OPTIONS" in line and "---" in line)
    return _edit(base, (marker, block + marker))


def _rejects(text: str, message: str, *, caller_driven: bool = False) -> None:
    with pytest.raises(DeckFormatError, match=message):
        DeckFile.from_text(text, caller_driven=caller_driven)


# --------------------------------------------------------------------------- options


_WATERKIN = (
    "MoorDyn v2 water kinematics file\n(header line 2)\n--- WAVES ---\n"
    '{mode} WaveKinMod\n"eta.txt" WaveKinFile\n0.25 dtWave\n37.0 WaveDir\n'
    "0 X\n0.0\n0 Y\n0.0\n0 Z\n0.0\n--- CURRENT ---\n0 CurrentMod\n0 Z\n0.0\n"
    "--- need this line ---\n"
)
_ETA = "time elevation\n" + "".join(
    f"{0.5 * i:g} {0.4 * (-1.0) ** (i // 4):g}\n" for i in range(41)
)
_RAO = (EXAMPLES / "data" / "vessel" / "sample_rao.txt").read_text(encoding="utf-8")
_ROWS = "0 0 0 0\n0.5 0.5 0 0.3\n0.6 0.3 0.1 2.4\n0.6 0.2 -0.1 -1.0\n"


def _waterkin(mode: str) -> dict[str, str]:
    return {"wk.dat": _WATERKIN.format(mode=mode), "eta.txt": _ETA}


# (rows of the deck, files next to it): every case is judged by DeckFile and by the driver
_WAVE_RECORD_CASES = [
    # a reference point needs component waves
    (("12.5 WaveRefX",), {}),
    (("0 WaveRefY",), {}),
    (("airy 2 8 0 waves", "1 WaveRefX"), {}),
    (("airy 2 8 0 wavetrain", "1 WaveRefY"), {}),
    (("7 WaterKin", "12.5 WaveRefX", "-3 WaveRefY"), {"wave_frequencies.txt": _ROWS}),
    (("7 WaterKin", "1.0e6 WaveRefX"), {"wave_frequencies.txt": _ROWS}),
    (("7 WaterKin", "1.0000001e6 WaveRefX"), {"wave_frequencies.txt": _ROWS}),
    (("7 WaterKin", "-2e6 WaveRefY"), {"wave_frequencies.txt": _ROWS}),
    (("7 WaterKin", "nan WaveRefY"), {"wave_frequencies.txt": _ROWS}),
    (("7 WaterKin", "north WaveRefY"), {"wave_frequencies.txt": _ROWS}),
    (("7 WaterKin", "1e-320 WaveRefX"), {"wave_frequencies.txt": _ROWS}),
    (("7 WaterKin", "2e6 WaveRefX", "1 WaveRefX"), {"wave_frequencies.txt": _ROWS}),
    (("7 WaterKin", "1 WAVEREFX"), {"wave_frequencies.txt": _ROWS}),
    # the WaveKinMod of a WaterKin file decides
    (("wk.dat WaterKin", "12.5 WaveRefX"), _waterkin("1")),
    (("wk.dat WaterKin", "12.5 WaveRefX"), _waterkin("0")),
    (("wk.dat WaterKin", "0 WaveRefY"), _waterkin("0")),
    (("wk.dat WaterKin", "12.5 WaveRefX"), _waterkin("2")),
    (("wk.dat WaterKin", "12.5 WaveRefX"), _waterkin("SEASTATE")),
    (("wk.dat WaterKin", "12.5 WaveRefX"), _waterkin("3")),
    (("wk.dat WaterKin", "12.5 WaveRefX"), _waterkin("one")),
    (("wk.dat WaterKin", "12.5 WaveRefX"), {"wk.dat": "header\nheader\n"}),
    (("wk.dat WaterKin", "12.5 WaveRefX"), {"wk.dat": "header\nheader\nwaves\n"}),
    (("wk.dat WaterKin", "12.5 WaveRefX"), {"wk.dat": "header\nheader\nwaves\n\n"}),
    (("wk.dat WaterKin", "rao.txt vesselRAO"), {**_waterkin("0"), "rao.txt": _RAO}),
    (("wk.dat WaterKin", "rao.txt vesselRAO"), {**_waterkin("1"), "rao.txt": _RAO}),
    # the rows of wave_frequencies.txt
    (("7 WaterKin",), {"wave_frequencies.txt": _ROWS}),
    (("7 WaterKin",), {"wave_frequencies.txt": "0 0 0 1.0\n0.5 0.5 0 0.3\n\n0.6 0.3 0.1 0.3\n"}),
    (("7 WaterKin",), {"wave_frequencies.txt": "0 0 0\n0.5 0.5 0\n0.6 0.3 0.1 -6.2\n"}),
    (("7 WaterKin",), {"wave_frequencies.txt": "0 0 0 0\n0.5 0.5 0 6.3\n"}),
    (("7 WaterKin",), {"wave_frequencies.txt": "0 0 0 -6.3\n0.5 0.5 0 0\n"}),
    (("7 WaterKin",), {"wave_frequencies.txt": "0 0 0 0\n0.5 0.5 0 east\n"}),
    (("7 WaterKin",), {"wave_frequencies.txt": "0 0 0 0\n0.5 0.5 0 nan\n"}),
    (("7 WaterKin",), {"wave_frequencies.txt": "0 0 0 0\n0.5 nan 0 0\n"}),
    (("7 WaterKin",), {"wave_frequencies.txt": "0 0 0 0\n0.5 0.5\n"}),
    (("7 WaterKin",), {"wave_frequencies.txt": "omega Re Im\n0 0 0 0\n0.5 0.5 0 0\n"}),
    (("7 WaterKin",), {"wave_frequencies.txt": "0 0 0 0\n"}),
    (("7 WaterKin",), {"wave_frequencies.txt": "0.1 0 0 0\n0.5 0.5 0 0\n"}),
    (("7 WaterKin",), {"wave_frequencies.txt": "0 0 0 0\n0.5 0.5 0 0\n0 0.5 0 0\n"}),
    (("7 WaterKin",), {"wave_frequencies.txt": "0 0 0 0\n0.5 2000 0 0\n"}),
    (("7 WaterKin",), {"wave_frequencies.txt": "0 0 0 0\n2e4 0.1 0 0\n"}),
    (("7 WaterKin",), {"wave_frequencies.txt": "0 0 -60 0\n0.5 0.5 0 0\n"}),
]


_CURRENT_TABLES = {
    "2": "a\nb\nc\nd\n-40 -10\ne\n0 0.1 0.2\n5 0.2 0.3\n10 0.2 0.3\n",
    "5": "1 1 2 2\n0\n0\n-40 -10\n0 10\n"
    + "".join(f"0 0 {z} {t} 0.1 0 0\n" for z in (-40, -10) for t in (0, 10)),
}
_PROFILE = "z ux uy uz\n-40 0.1 0 0\n-10 0.2 0.1 0\n"
_TABLE = "-40 0.1 0.0\n-10 0.2 0.1\n"


def _kin(wave="0", current="0", table="", dt="0.25", direction="37.0", record='"eta.txt"') -> str:
    return (
        "MoorDyn v2 water kinematics file\n(header line 2)\n--- WAVES ---\n"
        f"{wave} WaveKinMod\n{record} WaveKinFile\n{dt} dtWave\n{direction} WaveDir\n"
        "0 X\n0.0\n0 Y\n0.0\n0 Z\n0.0\n--- CURRENT ---\n"
        f"{current} CurrentMod\nz ux uy\n(m) (m/s) (m/s)\n{table}--- need this line ---\n"
    )


def _hold(point=2, *, tail=(), steps=101, last=None) -> str:
    rows = [f"{0.1 * i:.1f} {point} 0 0 0 0 0 0 0 0 0\n" for i in range(steps)]
    return "".join(rows[:last]) + "".join(tail)


def _vessel(*, form=19, steps=101, tail=()) -> str:
    pose = "0 0 0 0 0 0" if form == 19 else "0 0 0 1 0 0 0"
    rows = [f"{0.1 * i:.1f} {pose} {'0 ' * 12}\n" for i in range(steps)]
    return "".join(rows) + "".join(tail)


def _rao(
    heads=(-180.0, 179.0), period_row="0.5 0 0 0 0 1 0 0 0 0 0 0 0\n100 0 0 0 0 1 0 0 0 0 0 0 0\n"
):
    return "".join(f"HEADING {head}\n{period_row}" for head in heads)


def _sea_bed(depth=50.0, **changes) -> str:
    rows = {(x, y): depth for x in (-1000.0, 1000.0) for y in (-1000.0, 1000.0)}
    rows.update(changes.get("rows", {}))
    return "".join(f"{x} {y} {value}\n" for (x, y), value in rows.items()) + changes.get("tail", "")


_SETTINGS = (EXAMPLES / "data" / "syrope" / "syrope_settings.dat").read_text(encoding="utf-8")
_OWC = (EXAMPLES / "data" / "syrope" / "syrope_owc.dat").read_text(encoding="utf-8")


def _syrope(settings=_SETTINGS, owc=_OWC) -> dict[str, str]:
    return {"data/syrope/syrope_settings.dat": settings, "data/syrope/syrope_owc.dat": owc}


# a deck of objects and no lines: the only route that does not read a motion file
_OBJECTS = """Dry rod pinned to a heavy body
--- ROD TYPES ---
Name Diam Mass Cd Ca CdEnd CaEnd
(-) (m) (kg/m) (-) (-) (-) (-)
pend 0.2 50 0 0 0 0
--- BODIES ---
ID Attachment X0 Y0 Z0 r0 p0 y0 Mass CG* I* Volume CdA* Ca*
(#) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m) (kg-m^2) (m^3) (m^2) (-)
1 Free 5 0 20 0 0 0 5.0e10 0 1.0e13 4.87804882926829E+07 0 0
--- RODS ---
ID RodType Attachment XA YA ZA XB YB ZB NumSegs Outputs
(-) (-) (-) (m) (m) (m) (m) (m) (m) (-) (-)
1 pend Body1Pinned 0 0 0 5.0 0 -8.66025403784439 4 -
--- OPTIONS ---
100 WtrDpth
deck bodyIC
moordyn bodyWetting
0.05 dtM
1.0 TMax
--- OUTPUTS ---
Rod1Px Body1Pz
--- end ---
"""
_FREE = "wave_frequencies.txt"
_ONE_BETA = "0 0 0 0.5\n0.5 0.5 0 0.5\n"
_WK = ("wk.dat WaterKin",)
_C1 = "current_profile.txt"
_C2 = "current_profile_dynamic.txt"
_C5 = "current_profile_4d.txt"
_RAO_ROWS = ("rao.txt vesselRAO", "0|0|0 vesselRef")
# (deck, rows, files): every case is judged by DeckFile and by the driver
_ANCILLARY_CASES = [
    # WaterKin: the rest of the file
    ("held", _WK, {"wk.dat": _kin()}),
    ("held", _WK, {"wk.dat": _kin(dt="-1")}),
    ("held", _WK, {"wk.dat": _kin(dt="x")}),
    ("held", _WK, {"wk.dat": _kin(direction="north")}),
    ("held", _WK, {"wk.dat": 'a\nb\nc\n0\n""\n0\n0\n0\n'}),
    ("held", _WK, {"wk.dat": _kin(current="x")}),
    ("held", _WK, {"wk.dat": _kin(current="3")}),
    ("held", _WK, {"wk.dat": _kin(current="2")}),
    ("held", _WK, {"wk.dat": _kin(wave="1", current="2"), "eta.txt": _ETA}),
    ("held", _WK, {"wk.dat": _kin(wave="1", record='""')}),
    ("held", _WK, {"wk.dat": _kin(wave="1", dt="0"), "eta.txt": _ETA}),
    ("held", ("wk.dat WaterKin", "airy 2 8 0 waves"), {"wk.dat": _kin("1"), "eta.txt": _ETA}),
    # the WaterKin current table, and a current doubled
    ("held", _WK, {"wk.dat": _kin(current="1", table=_TABLE)}),
    ("held", _WK, {"wk.dat": _kin(current="1", table="10 0.2 0.1\n40 0.1 0.0\n")}),
    (
        "held",
        ("wk.dat WaterKin", "uniform 0.1 0 0 current"),
        {"wk.dat": _kin(current="1", table=_TABLE)},
    ),
    ("held", ("wk.dat WaterKin", "uniform 0.1 0 0 current"), {"wk.dat": _kin()}),
    (
        "held",
        ("wk.dat WaterKin", "1 Currents"),
        {"wk.dat": _kin(current="1", table=_TABLE), _C1: _PROFILE},
    ),
    ("held", ("wk.dat WaterKin", "1 Currents"), {"wk.dat": _kin(), _C1: _PROFILE}),
    ("held", _WK, {"wk.dat": _kin(current="1", table="-40 0.1 0\n")}),
    ("held", _WK, {"wk.dat": _kin(current="1", table="-40 0.1 0\n10 0.2 0\n")}),
    ("held", _WK, {"wk.dat": _kin(current="1", table="-40 0.1 0\n-40 0.2 0\n")}),
    ("held", _WK, {"wk.dat": _kin(current="1", table="-40 0.1\n-10 0.2 0\n")}),
    ("held", _WK, {"wk.dat": _kin(current="1", table="-40 2000 0\n-10 0.2 0\n")}),
    # the record of WaveKinMod 1
    ("held", _WK, {"wk.dat": _kin("1"), "eta.txt": "0 0\n1 0\n2 0\n"}),
    ("held", _WK, {"wk.dat": _kin("1"), "eta.txt": "1 0\n2 0\n3 0\n4 0\n"}),
    ("held", _WK, {"wk.dat": _kin("1"), "eta.txt": "0 0\n2 0\n1 0\n3 0\n"}),
    ("held", _WK, {"wk.dat": _kin("1"), "eta.txt": "0 0\n1 0\nend\n2 0\n3 0\n"}),
    ("held", _WK, {"wk.dat": _kin("1"), "eta.txt": "0 0\n1 x\n2 0\n3 0\n"}),
    ("held", _WK, {"wk.dat": _kin("1"), "eta.txt": _ETA.replace(" 0.4\n", " 4000\n")}),
    (
        "held",
        _WK,
        {
            "wk.dat": _kin("1"),
            "eta.txt": _ETA.replace(" 0.4\n", " -70\n").replace(" -0.4\n", " -70\n"),
        },
    ),
    ("held", ("wk.dat WaterKin", "0.1 WvHiCOff"), {"wk.dat": _kin("1"), "eta.txt": _ETA}),
    ("held", ("wk.dat WaterKin", "none WvHiCOff"), {"wk.dat": _kin("1"), "eta.txt": _ETA}),
    # Currents 1, 2 and 5
    ("held", ("1 Currents",), {_C1: _PROFILE}),
    ("held", ("1 Currents",), {_C1: "z ux uy uz\n"}),
    ("held", ("1 Currents",), {_C1: "-10 0 0 0\n-40 0 0 0\n"}),
    ("held", ("1 Currents",), {_C1: "-40 2000 0 0\n-10 0 0 0\n"}),
    ("held", ("1 Currents",), {_C1: "-40 0 0\n-10 0 0 x\n"}),
    ("held", ("1 Currents",), {_C1: "-40 0\n"}),
    ("held", ("2 Currents",), {_C2: _CURRENT_TABLES["2"]}),
    ("held", ("2 Currents",), {_C2: "a\nb\n"}),
    ("held", ("2 Currents",), {_C2: "a\nb\nc\nd\n-40 -10\ne\n0 0.1 0.2\n"}),
    ("held", ("2 Currents",), {_C2: "a\nb\nc\nd\n-10 -40\ne\n0 1 1\n5 1 1\n"}),
    ("held", ("2 Currents",), {_C2: "a\nb\nc\nd\n-40 -10\ne\n0 1 1\n0 1 1\n"}),
    ("held", ("2 Currents",), {_C2: "a\nb\nc\nd\n-40 -10\ne\n0 1\n5 1 1\n"}),
    ("held", ("2 Currents",), {_C2: "a\nb\nc\nd\n-40 -10\ne\n0 x 1\n5 1 1\n"}),
    ("held", ("2 Currents",), {_C2: "a\nb\nc\nd\n-40 -10\ne\n0 2000 1\n5 1 1\n"}),
    ("held", ("5 Currents",), {_C5: _CURRENT_TABLES["5"]}),
    ("held", ("5 Currents",), {_C5: "1 1 x 2\n"}),
    ("held", ("5 Currents",), {_C5: "1 1 2 2\n0\n0\n-40\n0 10\n"}),
    ("held", ("5 Currents",), {_C5: _CURRENT_TABLES["5"] + "0 0 -40 0 0.1 0 0\n"}),
    (
        "held",
        ("5 Currents",),
        {_C5: _CURRENT_TABLES["5"].replace("0 0 -40 0 0.1", "0 0 -41 0 0.1")},
    ),
    ("held", ("5 Currents",), {_C5: _CURRENT_TABLES["5"].replace("0 0 -40 0 0.1 0 0\n", "")}),
    ("held", ("5 Currents",), {_C5: "1 1 1 1\n0\n0\n-40\n0\n0 0 -40 0 0.1 0 0\n"}),
    (
        "held",
        ("5 Currents",),
        {_C5: _CURRENT_TABLES["5"].replace("0 0 -40 0 0.1", "0 0 -40 0 2000")},
    ),
    # motionFile
    ("held", ("m.txt motionFile",), {"m.txt": _hold()}),
    ("held", ("m.txt motionFile",), {"m.txt": _hold(tail=("10.1 2 0 0 0 0 0 0 0 0 0\n",))}),
    ("held", ("m.txt motionFile",), {"m.txt": _hold(last=100)}),
    ("held", ("m.txt motionFile",), {"m.txt": _hold(tail=("0.0 2 0 0 0 0 0 0 0 0 0\n",))}),
    ("held", ("m.txt motionFile",), {"m.txt": _hold(tail=("0.05 2 0 0 0 0 0 0 0 0 0\n",))}),
    ("held", ("m.txt motionFile",), {"m.txt": _hold(tail=("0.0 1 0 0 0 0 0 0 0 0 0\n",))}),
    ("held", ("m.txt motionFile",), {"m.txt": _hold(tail=("0.0 2.5 0 0 0 0 0 0 0 0 0\n",))}),
    ("held", ("m.txt motionFile",), {"m.txt": _hold(tail=("0.0 2 0 0 0\n",))}),
    ("held", ("m.txt motionFile",), {"m.txt": _hold(point=1)}),
    ("held", ("m.txt motionFile",), {"m.txt": "0.0 2 2e6 0 0 0 0 0 0 0 0\n"}),
    ("held", ("m.txt motionFile",), {"m.txt": "0.0 2 0 0 0 2e4 0 0 0 0 0\n"}),
    ("held", ("m.txt motionFile",), {"m.txt": "0.0 2 0 0 0 0 0 0 2e6 0 0\n"}),
    # vesselMotion
    ("held", ("v.txt vesselMotion", "0|0|0 vesselRef"), {"v.txt": _vessel()}),
    ("held", ("v.txt vesselMotion", "0|0|0 vesselRef"), {"v.txt": _vessel(form=20)}),
    ("held", ("v.txt vesselMotion", "0|0|0 vesselRef"), {"v.txt": _vessel(steps=100)}),
    (
        "held",
        ("v.txt vesselMotion", "0|0|0 vesselRef"),
        {"v.txt": _vessel(form=19, tail=("0.0 " + "0 " * 19 + "\n",))},
    ),
    (
        "held",
        ("v.txt vesselMotion", "0|0|0 vesselRef"),
        {"v.txt": _vessel(form=20).replace("0 0 0 1 0 0 0", "0 0 0 2 0 0 0", 1)},
    ),
    ("held", ("v.txt vesselMotion", "0|0|0 vesselRef"), {"v.txt": "0.05 " + "0 " * 18 + "\n"}),
    ("held", ("v.txt vesselMotion", "0|0|0 vesselRef"), {"v.txt": "0.0 2e6 " + "0 " * 17 + "\n"}),
    # vesselRAO, its rows and the headings of the sea
    ("held", ("airy 2 8 30 waves", *_RAO_ROWS), {"rao.txt": _rao()}),
    ("held", ("airy 2 8 30 waves", *_RAO_ROWS), {"rao.txt": _rao(heads=(30.0,))}),
    ("held", ("airy 2 8 30 waves", *_RAO_ROWS), {"rao.txt": _rao(heads=(0.0,))}),
    ("held", ("airy 2 8 30 waves", *_RAO_ROWS), {"rao.txt": _rao(heads=(40.0, 90.0))}),
    ("held", ("airy 2 8 30 waves", *_RAO_ROWS), {"rao.txt": _rao(heads=(0.0, 90.0))}),
    ("held", ("airy 2 8 30 waves", *_RAO_ROWS), {"rao.txt": _rao(heads=(0.0, 360.0))}),
    ("held", ("airy 2 8 30 waves", *_RAO_ROWS), {"rao.txt": "1 0 0 0 0 1 0 0 0 0 0 0 0\n"}),
    ("held", ("airy 2 8 30 waves", *_RAO_ROWS), {"rao.txt": "HEADING 30\n"}),
    ("held", ("airy 2 8 30 waves", *_RAO_ROWS), {"rao.txt": "HEADING 30 40\n"}),
    ("held", ("airy 2 8 30 waves", *_RAO_ROWS), {"rao.txt": "HEADING 30\n1 0 0\n"}),
    ("held", ("airy 2 8 30 waves", *_RAO_ROWS), {"rao.txt": "HEADING 30\n-1 " + "0 " * 12 + "\n"}),
    (
        "held",
        ("airy 2 8 30 waves", *_RAO_ROWS),
        {"rao.txt": "HEADING 30\n1 -1 " + "0 " * 11 + "\n"},
    ),
    (
        "held",
        ("airy 2 8 30 waves", *_RAO_ROWS),
        {"rao.txt": "HEADING 30\n1 " + "0 " * 12 + "\nHEADING 40\n2 " + "0 " * 12 + "\n"},
    ),
    ("held", ("jonswap 2 9 3.3 30 waves", *_RAO_ROWS), {"rao.txt": _rao(heads=(30.0,))}),
    (
        "held",
        ("jonswap 2 9 3.3 30 waves", "4 WaveSpreading", *_RAO_ROWS),
        {"rao.txt": _rao(heads=(30.0,))},
    ),
    (
        "held",
        ("jonswap 2 9 3.3 30 waves", "4 WaveSpreading", *_RAO_ROWS),
        {"rao.txt": _rao(heads=(-60.0, 120.0))},
    ),
    (
        "held",
        ("jonswap 2 9 3.3 30 waves", "4 WaveSpreading", "5 WaveDirections", *_RAO_ROWS),
        {"rao.txt": _rao(heads=(-42.0, 102.0))},
    ),
    # a narrow spreading underflows the outer bins: only the bins with energy need a heading
    (
        "held",
        ("jonswap 2 9 3.3 0 waves", "1000 WaveSpreading", *_RAO_ROWS),
        {"rao.txt": _rao(heads=(-40.0, 40.0))},
    ),
    (
        "held",
        ("jonswap 2 9 3.3 0 waves", "1000 WaveSpreading", *_RAO_ROWS),
        {"rao.txt": _rao(heads=(-20.0, 20.0))},
    ),
    (
        "held",
        ("jonswap 2 9 3.3 0 waves", "838 WaveSpreading", *_RAO_ROWS),
        {"rao.txt": _rao(heads=(-40.0, 40.0))},
    ),
    (
        "held",
        ("jonswap 2 9 3.3 0 waves", "700 WaveSpreading", *_RAO_ROWS),
        {"rao.txt": _rao(heads=(-40.0, 40.0))},
    ),
    (
        "held",
        ("jonswap 2 9 3.3 0 1000 wavetrain", *_RAO_ROWS),
        {"rao.txt": _rao(heads=(-40.0, 40.0))},
    ),
    (
        "held",
        ("jonswap 2 9 3.3 0 1000 wavetrain", "5 WaveDirections", *_RAO_ROWS),
        {"rao.txt": _rao(heads=(-36.0, 36.0))},
    ),
    ("held", ("7 WaterKin", *_RAO_ROWS), {"rao.txt": _rao(), _FREE: _ROWS}),
    ("held", ("7 WaterKin", *_RAO_ROWS), {"rao.txt": _rao(heads=(0.0, 100.0)), _FREE: _ROWS}),
    ("held", ("7 WaterKin", *_RAO_ROWS), {"rao.txt": _rao(heads=(28.0, 29.0)), _FREE: _ONE_BETA}),
    (
        "held",
        ("wk.dat WaterKin", *_RAO_ROWS),
        {"rao.txt": _rao(heads=(37.0,)), "wk.dat": _kin("1"), "eta.txt": _ETA},
    ),
    (
        "held",
        ("wk.dat WaterKin", *_RAO_ROWS),
        {"rao.txt": _rao(heads=(38.0,)), "wk.dat": _kin("1"), "eta.txt": _ETA},
    ),
    # bathymetry
    ("bed", (), {"b.txt": _sea_bed()}),
    ("bed", (), {"b.txt": _sea_bed(depth=49.0)}),
    ("bed", (), {"b.txt": _sea_bed(depth=50.0004)}),
    ("bed", (), {"b.txt": _sea_bed(depth=0.0)}),
    ("bed", (), {"b.txt": "0 0 50\n1 0 50\n"}),
    ("bed", (), {"b.txt": _sea_bed(tail="0 0 50\n")}),
    ("bed", (), {"b.txt": _sea_bed(tail="-1000.0 -1000.0 50\n")}),
    ("bed", (), {"b.txt": _sea_bed(tail="1 2\n")}),
    ("bed", (), {"b.txt": _sea_bed(tail="1 x 3\n")}),
    ("bed", (), {"b.txt": _sea_bed(tail="-1000.0 0.0 50\n1000.0 0.0 50\n")}),
    # a crease at the anchor: the rounded and the tabulated surfaces differ there
    (
        "bed",
        (),
        {
            "b.txt": "".join(
                f"{x} {y} {d}\n"
                for x, d in ((-1000.0, 40.0), (400.0, 50.0), (1000.0, 40.0))
                for y in (-1000.0, 1000.0)
            )
        },
    ),
    # Syrope settings and OWC table
    ("syrope", (), _syrope()),
    ("syrope", (), _syrope(settings=_SETTINGS + "1.0 k1\n")),
    ("syrope", (), _syrope(settings="data/x.dat OWC\n")),
    (
        "syrope",
        (),
        _syrope(
            settings=_SETTINGS.replace("LINEAR", "CUBIC")
            .replace("QUADRATIC", "CUBIC")
            .replace("EXP", "CUBIC")
        ),
    ),
    ("syrope", (), _syrope(owc="strain tension\n0.0 0.0\n")),
    ("syrope", (), _syrope(owc="0.0 0.0\n0.01 x\n")),
    ("syrope", (), _syrope(owc="0.02 1e6\n0.01 2e6\n0.03 3e6\n")),
    ("syrope", (), _syrope(owc="0.0 2e6\n0.01 1e6\n0.03 3e6\n")),
    # the routes of the objects: which of them read a motion file
    ("rigid6_buoy.dat", ("m.txt motionFile",), {"m.txt": "not a motion row\n"}),
    ("rod_moored_spar.dat", ("m.txt motionFile",), {"m.txt": "not a motion row\n"}),
    ("spar_pinned_rods.dat", ("m.txt motionFile",), {"m.txt": "not a motion row\n"}),
    ("mixed_body_rods_points.dat", ("m.txt motionFile",), {"m.txt": "not a motion row\n"}),
    ("objects", ("m.txt motionFile",), {"m.txt": "not a motion row\n"}),
]
# every spelling the reader takes of the options and kinds these rules read
_KEYWORD_SPELLINGS = (
    ("waves", "wave"),
    ("wavetrain", "wave_train"),
    ("WaveSpreading", "wave_spreading"),
    ("WaveDirections", "wave_directions"),
    ("WaveComponents", "wave_components"),
    ("WtrDpth", "water_depth"),
    ("dtM", "dt"),
    ("WaterKin", "WaveKin"),
    ("bathymetryFile", "seafloor_file"),
    ("rampTime", "tramp"),
)
_KIND_VALUES = {
    "airy": ("2 8 30", "2 8 30"),
    "Airy": ("2 8 30", "2 8 30"),
    "jonswap": ("2 9 3.3 30", "2 9 3.3 30 0"),
    "JONSWAP": ("2 9 3.3 30", "2 9 3.3 30 0"),
    "pm": ("2 9 30", "2 9 30 0"),
    "issc": ("2 9 30", "2 9 30 0"),
    "bretschneider": ("2 9 30", "2 9 30 0"),
    "torsethaugen": ("6 12 30", "6 12 30 0"),
    "ochihubble": ("2 8 1 1 12 1 30", "2 8 1 1 12 1 30 0"),
    "ochi-hubble": ("2 8 1 1 12 1 30", "2 8 1 1 12 1 30 0"),
    "ochi_hubble": ("2 8 1 1 12 1 30", "2 8 1 1 12 1 30 0"),
    "Ochi_Hubble": ("2 8 1 1 12 1 30", "2 8 1 1 12 1 30 0"),
}
# every kind and keyword against a one-heading RAO table: at the sea's heading and off it, on
# the dynamic clock and on the static check's
_SPELLED_CASES = [
    (base, (f"{kind} {values[train]} {keyword}", *_RAO_ROWS), {"rao.txt": _rao(heads=(heading,))})
    for kind, values in _KIND_VALUES.items()
    for train, keyword in ((0, "waves"), (0, "wave"), (1, "wavetrain"), (1, "wave_train"))
    for heading in (30.0, 31.0)
    for base in ("held", "held_static")
]
_SPELLED_CASES += [
    # the kinds whose rows spread, and the spellings of the options that spread them
    (base, (f"pm 2 9 30 {keyword}", f"4 {spread}", *_RAO_ROWS), {"rao.txt": _rao(heads=heads)})
    for base in ("held", "held_static")
    for keyword in ("waves", "wave")
    for spread in ("WaveSpreading", "wave_spreading", "WAVESPREADING")
    for heads in ((30.0,), (-180.0, 179.0))
] + [
    (base, (f"ochi_hubble 2 8 1 1 12 1 30 4 {keyword}", *_RAO_ROWS), {"rao.txt": _rao(heads=heads)})
    for base in ("held", "held_static")
    for keyword in ("wavetrain", "wave_train")
    for heads in ((30.0,), (-180.0, 179.0))
]
# a record or a kinematics file on the static check's clock, under each spelling of its selector
_STATIC_CASES = [
    ("held_static", (f"{value} {keyword}", *rows), files)
    for keyword in ("WaterKin", "WaveKin", "WATERKIN")
    for value, rows, files in (
        ("wk.dat", (), {"wk.dat": _kin("1"), "eta.txt": _ETA}),
        ("wk.dat", ("12.5 WaveRefX",), {"wk.dat": _kin("1"), "eta.txt": _ETA}),
        ("wk.dat", ("12.5 WaveRefX",), {"wk.dat": _kin("0"), "eta.txt": _ETA}),
        ("wk.dat", (), {"wk.dat": _kin("1"), "eta.txt": "0 0\n1 0\n"}),
        ("wk.dat", (), {"wk.dat": _kin("1", dt="100"), "eta.txt": _ETA}),
        (
            "wk.dat",
            _RAO_ROWS,
            {"wk.dat": _kin("1"), "eta.txt": _ETA, "rao.txt": _rao(heads=(37.0,))},
        ),
        (
            "wk.dat",
            _RAO_ROWS,
            {"wk.dat": _kin("1"), "eta.txt": _ETA, "rao.txt": _rao(heads=(38.0,))},
        ),
        ("7", (), {_FREE: _ROWS}),
        ("7", ("12.5 WaveRefY",), {_FREE: _ROWS}),
        ("7", (), {_FREE: "0 0 0 0\n0.5 0.5 0 6.3\n"}),
        ("3", ("0.1 dtWave",), {"wave_elevation.txt": _ETA.replace("time elevation\n", "")}),
    )
] + [
    ("held_static", ("m.txt motionFile",), {"m.txt": "0.0 2 0 0 0 0 0 0 0 0 0\n"}),
    (
        "held_static",
        ("m.txt motionFile",),
        {"m.txt": "0.0 2 0 0 0 0 0 0 0 0 0\n0.05 2 0 0 0 0 0 0 0 0 0\n"},
    ),
    ("held_static", ("m.txt motionFile",), {"m.txt": _hold()}),
    ("held_static", ("m.txt motionFile",), {"m.txt": "1.0 2 0 0 0 0 0 0 0 0 0\n"}),
    ("held_static", ("v.txt vesselMotion", "0|0|0 vesselRef"), {"v.txt": _vessel(steps=1)}),
    ("held_static", ("v.txt vesselMotion", "0|0|0 vesselRef"), {"v.txt": _vessel()}),
    ("bed_static", (), {"b.txt": _sea_bed()}),
    ("held", ("airy 2 8 0 waves", "4 WaveSpreading"), {}),
]


def _shipped_decks() -> list[str]:
    decks = [path.name for path in sorted(EXAMPLES.glob("*.dat"))]
    decks.remove("cabledyn_options_reference.dat")
    # the decks of the MoorDyn-C kinematics folders, which read fixed-name files beside them
    folders = sorted(EXAMPLES.glob("moordynC_*/*.dat"))
    return [*decks, *(path.relative_to(EXAMPLES).as_posix() for path in folders)]


def _carries_waves(name: str) -> bool:
    text = (EXAMPLES / name).read_text(encoding="utf-8")
    return re.search(r"(?mi)^(?!none\b|--)\S.*\s(?:waves?|wave_?train)\b", text) is not None or (
        re.search(r"(?mi)^(?!0\s|none\s)\S+\s+(?:WaterKin|WaveKin)\b", text) is not None
    )


# every shipped deck as a static check without dtM; every shipped wave deck under each spelling
_SHIPPED_CASES = [(f"shipped:static:{name}", (), {}) for name in _shipped_decks()] + [
    (f"shipped:{variant}:{name}", (), {})
    for name in _shipped_decks()
    if _carries_waves(name)
    for variant in ("spelled", "upper")
]
_PROFILE_ROW = "profile -30 0.2 0 0 0 0.5 0 0 current"
# (rows, message): the last waves or current row is the one in effect; the native reader
# checks the magnitude bounds on that row alone and the row rules on every row
_OVERRIDDEN_ROW_CASES = [
    (("airy 2000 8 0 waves", "none waves"), None),
    (("airy 2 0.01 0 waves", "airy 2 8 0 waves"), None),
    (("stream 2 2e5 0 waves", "pm 3 10 0 waves"), None),
    (("jonswap 3 10 40 0 waves", "airy 2 8 0 waves"), None),
    (("jonswap 3 10 2000 0 waves", "airy 2 8 0 waves"), None),
    (("jonswap 3 10 2000 0 waves", "stream 2 8 0 waves"), None),
    (("jonswap 3000 10 3.3 0 waves", "none waves"), None),
    (("uniform 2000 0 0 current", "none current"), None),
    (("uniform 2000 0 0 current", _PROFILE_ROW), None),
    (("profile -2e6 0.2 0 0 0 0.5 0 0 current", "uniform 0.1 0 0 current"), None),
    (("profile -30 2000 0 0 0 0.5 0 0 current", _PROFILE_ROW), None),
    (("airy 2 8 0 waves", "airy 2000 8 0 waves"), r"waves need height <= 1e3 m"),
    (("none waves", "jonswap 3 10 40 0 waves"), r"JONSWAP gamma must be in \[1, 32\.6\)"),
    (("airy 2 8 0 waves", "jonswap 3 10 2000 0 waves"), r"JONSWAP gamma must be in \[1, 32\.6\)"),
    ((_PROFILE_ROW, "uniform 2000 0 0 current"), r"at most 1e3 m/s"),
    (("uniform 0.1 0 0 current", "profile -2e6 0.2 0 0 0 0.5 0 0 current"), r"at most 1e6 m"),
    # the row rules hold on an overridden row too
    (("airy 0 8 0 waves", "none waves"), r"positive height/period"),
    (("jonswap 3 10 0.5 0 waves", "airy 2 8 0 waves"), r"JONSWAP gamma >= 1"),
    (("profile -30 0.2 0 0 -30 0.5 0 0 current", "none current"), r"strictly increasing"),
    (("pm 3000 10 0 waves", "none waves"), r"a wave train needs height <= 1e3 m"),
]


_ALL_FILE_CASES = [
    *[("held", rows, files) for rows, files in _WAVE_RECORD_CASES],
    *_ANCILLARY_CASES,
    *_SPELLED_CASES,
    *_STATIC_CASES,
    *_SHIPPED_CASES,
    *[("held", rows, {}) for rows, _ in _OVERRIDDEN_ROW_CASES],
]


def _respell(text: str, old: str, new: str) -> str:
    """``text`` with the first token ``old`` of each row (any case) spelled ``new``."""
    token = re.compile(rf"(?i)(?<!\S){re.escape(old)}(?!\S)")
    return "\n".join(
        line if line.startswith("--") else token.sub(new, line, count=1)
        for line in text.split("\n")
    )


def _static_check(text: str, *, keep_dtm: bool = False) -> str:
    """``text`` as a static check: TMax 0, and without dtM unless it is kept."""
    text = re.sub(r"(?mi)^\s*\S+(\s+TMax\b)", r"0.0\1", text, count=1)
    return text if keep_dtm else re.sub(r"(?mi)^\s*\S+\s+dtM\b.*\n", "", text, count=1)


def _shipped_text(variant: str, name: str) -> str:
    text = (EXAMPLES / name).read_text(encoding="utf-8")
    if variant == "static":
        return _static_check(text)
    text = _static_check(text, keep_dtm=True)
    for old, new in _KEYWORD_SPELLINGS:
        text = _respell(text, old, new if variant == "spelled" else old.upper())
    if variant == "upper":
        for kind in ("airy", "jonswap", "pm", "issc", "torsethaugen", "ochihubble", "stream"):
            text = _respell(text, kind, kind.upper())
    return text


def _deck_text(deck: str, rows: tuple[str, ...]) -> str:
    if deck.startswith("shipped:"):
        return _shipped_text(*deck.split(":")[1:])
    if deck.endswith("_static"):
        return _static_check(_deck_text(deck[: -len("_static")], rows))
    if deck == "bed":
        return _options(_HELD, "b.txt bathymetryFile", *rows).replace("50.0 WtrDpth\n", "")
    if deck == "syrope":
        return (EXAMPLES / "syrope_polyester_mooring.dat").read_text(encoding="utf-8")
    if deck == "objects":
        return _OBJECTS.replace("1.0 TMax\n", "1.0 TMax\n" + "".join(f"{r}\n" for r in rows))
    if deck.endswith(".dat"):
        text = (EXAMPLES / deck).read_text(encoding="utf-8")
        return re.sub(r"(?m)^(\S+\s+TMax\b.*)$", "\\1\n" + "\n".join(rows), text, count=1)
    return _options(_HELD, *rows)


def _stage(folder: Path, rows: tuple[str, ...], files: dict[str, str], deck: str = "held") -> Path:
    folder.mkdir(parents=True, exist_ok=True)
    for name, text in files.items():
        (folder / name).parent.mkdir(parents=True, exist_ok=True)
        (folder / name).write_text(text, encoding="utf-8")
    if deck.startswith("shipped:"):
        source = (EXAMPLES / deck.split(":")[2]).parent
        for item in source.iterdir():
            if item.is_dir():
                shutil.copytree(item, folder / item.name, dirs_exist_ok=True)
            elif item.suffix != ".dat":
                shutil.copy2(item, folder / item.name)
    path = folder / "deck.dat"
    path.write_text(_deck_text(deck, rows), encoding="utf-8")
    return path


def _accepted(deck: Path) -> bool:
    try:
        DeckFile.read(deck)
    except DeckFormatError:
        return False
    return True


@pytest.mark.skipif(
    not os.environ.get("CABLEDYN_DRIVER", "").strip(),
    reason="needs the native driver (CABLEDYN_DRIVER)",
)
@pytest.mark.parametrize(("base", "rows", "files"), _ALL_FILE_CASES)
def test_wave_record_rules_match_the_driver(tmp_path, base, rows, files):
    deck = _stage(tmp_path, rows, files, base)
    run = subprocess.run(
        [os.environ["CABLEDYN_DRIVER"], str(deck), str(tmp_path / "out")],
        capture_output=True,
        text=True,
        errors="replace",
        env={**os.environ, "OMP_NUM_THREADS": "1", "OPENBLAS_NUM_THREADS": "1"},
        check=False,
    )
    assert _accepted(deck) == (run.returncode == 0), run.stdout[-400:] + run.stderr[-400:]


@pytest.mark.parametrize(
    ("rows", "files", "message"),
    [
        (
            ("wk.dat WaterKin", "1 WaveRefX"),
            _waterkin("0"),
            "reference point of an elevation record",
        ),
        (
            ("wk.dat WaterKin", "1 WaveRefX"),
            _waterkin("SEASTATE"),
            "reference point of an elevation",
        ),
        (("wk.dat WaterKin", "1 WaveRefX"), _waterkin("3"), "WaveKinMod supports 0"),
        (("wk.dat WaterKin", "1 WaveRefX"), _waterkin("one"), "must be 0, 1, 2, or SEASTATE"),
        (("wk.dat WaterKin", "1 WaveRefX"), {"wk.dat": "a\nb\n"}, "ended inside its header"),
        (("wk.dat WaterKin", "1 WaveRefX"), {"wk.dat": "a\nb\nc\n"}, "no WaveKinMod line"),
        (("wk.dat WaterKin", "1 WaveRefX"), {"wk.dat": "a\nb\nc\n \n"}, "line has no value"),
        (("7 WaterKin",), {"wave_frequencies.txt": "0 0 0 0\n0.5 0.5 0 6.3\n"}, "within \\+-2 pi"),
        (("7 WaterKin",), {"wave_frequencies.txt": "0 0 0 0\n"}, "at least two"),
        (("7 WaterKin",), {"wave_frequencies.txt": "1 0 0 0\n2 1 0 0\n"}, "at omega = 0"),
        (("7 WaterKin",), {"wave_frequencies.txt": "0 0 0 0\n0 1 0 0\n"}, "must be positive"),
        (("7 WaterKin",), {"wave_frequencies.txt": "0 0 0 0\n0.5 x 0 0\n"}, "plain numbers"),
        (("7 WaterKin",), {"wave_frequencies.txt": "0 0 0 0\n0.5 2000 0 0\n"}, "at most 1e3 m"),
        (("7 WaterKin",), {"wave_frequencies.txt": "0 0 -60 0\n0.5 1 0 0\n"}, "effective depth"),
    ],
)
def test_wave_files_next_to_the_deck_are_read(tmp_path, rows, files, message):
    with pytest.raises(DeckFormatError, match=message):
        DeckFile.read(_stage(tmp_path, rows, files))


@pytest.mark.parametrize("kind", ["ochihubble", "ochi-hubble", "ochi_hubble", "OCHI_HUBBLE"])
def test_every_spelling_of_a_kind_takes_its_heading_from_its_own_column(tmp_path, kind):
    rows = (f"{kind} 2 8 1 1 12 1 30 waves", *_RAO_ROWS)
    DeckFile.read(_stage(tmp_path, rows, {"rao.txt": _rao(heads=(30.0,))}))
    with pytest.raises(DeckFormatError, match="one-heading RAO table"):
        DeckFile.read(_stage(tmp_path, rows, {"rao.txt": _rao(heads=(31.0,))}))


def test_a_static_check_reads_a_record_on_its_own_clock(tmp_path):
    # TMax = 0 without dtM: the record resamples on its dtWave, whatever the nominal step
    files = {"wk.dat": _kin("1"), "eta.txt": _ETA}
    DeckFile.read(_stage(tmp_path, _WK, files, "held_static"))
    with pytest.raises(DeckFormatError, match="four `time elevation` rows"):
        DeckFile.read(_stage(tmp_path, _WK, {"eta.txt": "0 0\n1 0\n"}, "held_static"))


def test_wave_files_that_are_not_there_are_left_to_the_solver(tmp_path):
    # In memory under the nominal path, or on disk ahead of its files: the deck passes here,
    # and the driver, which must open the file, refuses it by name while it is missing.
    for rows in (("wk.dat WaterKin", "1 WaveRefX"), ("7 WaterKin", "1 WaveRefX")):
        DeckFile.from_text(_options(_HELD, *rows))
        DeckFile.from_text(_options(_HELD, *rows), path=tmp_path / "deck.dat")
    # once the file is there the same text is judged by it
    (tmp_path / "wk.dat").write_text(_WATERKIN.format(mode="0"), encoding="utf-8")
    with pytest.raises(DeckFormatError, match="reference point of an elevation record"):
        DeckFile.from_text(
            _options(_HELD, "wk.dat WaterKin", "1 WaveRefX"), path=tmp_path / "deck.dat"
        )


def test_a_waterkin_file_is_found_as_the_native_reader_finds_it(tmp_path):
    # quoted, in a subfolder, and by an absolute path
    (tmp_path / "sub").mkdir()
    (tmp_path / "sub" / "wk.dat").write_text(_WATERKIN.format(mode="0"), encoding="utf-8")
    for value in ('"sub/wk.dat"', "sub/wk.dat", (tmp_path / "sub" / "wk.dat").as_posix()):
        with pytest.raises(DeckFormatError, match="reference point of an elevation record"):
            DeckFile.read(_stage(tmp_path, (f"{value} WaterKin", "1 WaveRefX"), {}))


@pytest.mark.parametrize("value", ["0", "-0.1"])
def test_dtwave_must_be_positive(value):
    _rejects(_options(_HELD, f"{value} dtWave"), "OPTION dtWave must be positive")
    assert DeckFile.from_text(_options(_HELD, "0.25 dtWave")).option("dtWave").values == ("0.25",)


@pytest.mark.parametrize(
    ("rows", "message"),
    [
        (("7 WaterKin",), None),
        (("3 WaveKin", "0.1 dtWave"), None),
        (("1 Currents",), None),
        (("2 Currents",), None),
        (("5 Currents",), None),
        (("airy 2 8 0 waves", "7 WaterKin"), r"both a waves \(or wavetrain\) OPTION and WaveKin 7"),
        (("airy 2 8 0 wavetrain", "3 WaveKin"), "double-counting"),
        (("uniform 0.1 0 0 current", "1 Currents"), "both a current OPTION and Currents 1"),
        (("uniform 0.1 0 0 current", "2 Currents"), "both a current OPTION and Currents 2"),
        (("uniform 0.1 0 0 current", "5 Currents"), "both a current OPTION and Currents 5"),
        (("7 WaterKin", "12.5 WaveRefX", "-3 WaveRefY"), None),
        (("3 WaveKin", "0.1 dtWave", "0 WaveRefY"), None),
        (("wk.dat WaterKin", "12.5 WaveRefX"), None),
        (("12.5 WaveRefX",), "reference point of an elevation record"),
        (("0 WaveRefY",), "reference point of an elevation record"),
        (("airy 2 8 0 waves", "1 WaveRefX"), "reference point of an elevation record"),
        (("airy 2 8 0 wavetrain", "1 WaveRefY"), "reference point of an elevation record"),
        (("7 WaterKin", "2e6 WaveRefX"), "at most 1e6 m"),
        (("7 WaterKin", "nan WaveRefY"), "must be"),
        (("7 WaterKin", "north WaveRefY"), "must be numeric"),
    ],
)
def test_moordyn_c_kinematics_follow_the_native_rules(rows, message):
    text = _options(_HELD, *rows)
    if message is None:
        DeckFile.from_text(text)
    else:
        _rejects(text, message)


def test_moordyn_c_kinematics_need_the_dynamic_sea_setup():
    _rejects(_options(_STATIC, "7 WaterKin"), "WaveKin 7 waves require dtM, TMax and WtrDpth")
    no_depth = _edit(_HELD, ("50.0 WtrDpth\n", "7 WaterKin\n"))
    _rejects(no_depth.replace("-50.0", "-80.0"), "WaveKin 7 waves require dtM, TMax and WtrDpth")
    _rejects(_options(_STATIC, "1 Currents"), "standalone Currents 1 requires dtM and TMax")
    _rejects(_options(_STATIC, "5 Currents"), "standalone Currents 5 requires dtM and TMax")


@pytest.mark.parametrize("row", ["7 WaterKin", "1 Currents", "2 Currents", "5 Currents"])
def test_moordyn_c_kinematics_are_not_certified_for_the_coupled_route(row):
    _rejects(_options(_HELD, row), "not supported on the coupled route", caller_driven=True)


def test_vessel_rao_takes_moordyn_c_component_waves():
    text = _example(
        "lazy_wave_vessel_rao.dat",
        ("jonswap 4.0 10.0 3.3 0.0 waves", "none waves"),
        ("0         WaterKin", "7 WaterKin"),
    )
    assert DeckFile.from_text(text, path=EXAMPLES / "rao.dat").option("WaterKin").values == ("7",)
    without = _example("lazy_wave_vessel_rao.dat", ("jonswap 4.0 10.0 3.3 0.0 waves", "none waves"))
    _rejects(without, "vesselRAO needs deck waves")


@pytest.mark.parametrize(
    "rows",
    [
        ("jonswap 2 8 40 0 waves",),
        ("jonswap 2 8 40 0 waves", "2 WaveSpreading"),
        ("jonswap 2 8 40 0 waves", "300 WaveComponents"),
    ],
)
def test_jonswap_gamma_limit_applies_on_every_path(rows):
    _rejects(_options(_HELD, *rows), r"JONSWAP gamma must be in \[1, 32\.6\)")


@pytest.mark.parametrize(("rows", "message"), _OVERRIDDEN_ROW_CASES)
def test_magnitude_bounds_apply_to_the_waves_and_current_rows_in_effect(rows, message):
    text = _options(_HELD, *rows)
    if message is None:
        DeckFile.from_text(text)
    else:
        _rejects(text, message)


def test_an_edited_waves_row_takes_the_magnitude_bounds():
    deck = DeckFile.from_text(_options(_HELD, "airy 2000 8 0 waves", "airy 2 8 0 waves"))
    with pytest.raises(ValueError, match="waves need height <= 1e3 m"):
        deck.set_option("waves", ("airy", 2000.0, 8.0, 0.0))


def test_spread_jonswap_row_is_validated_as_a_wave_train():
    DeckFile.from_text(_options(_HELD, "jonswap 2 8 3.3 2e6 waves"))
    _rejects(
        _options(_HELD, "jonswap 2 8 3.3 2e6 waves", "2 WaveSpreading"),
        r"\|direction\| <= 1e6",
    )
    DeckFile.from_text(_options(_HELD, "jonswap 2 8 3.3 30 waves", "200 WaveComponents"))


def test_wavetrain_spellings_are_one_option():
    text = _options(_HELD, "airy 2 8 0 wave_train", "airy 1 6 30 wavetrain")
    deck = DeckFile.from_text(text)
    assert deck.option("wave_train").values == ("airy", "1", "6", "30")
    assert deck.option("wavetrain").keyword == "wavetrain"
    options = OptionSet()
    options.add("wave_train", "airy", 2.0, 8.0, 0.0)
    options.add("wavetrain", "airy", 1.0, 6.0, 30.0)
    assert options.remove("wavetrain") == 2


def test_float_edits_use_the_shortest_round_trip_text():
    deck = DeckFile.from_text(_HELD)
    deck.set_option("dtM", 0.1)
    deck.set_option("TMax", 10.0)
    assert "\n0.1 dtM\n10 TMax\n" in deck.text()


# --------------------------------------------------------------------------- seabed, attachments


@pytest.mark.parametrize(
    ("depth", "anchor_z", "accepted"),
    [("200.0", "-200.0015", True), ("200.0", "-200.0021", False), ("1.0", "-1.001", True)],
)
def test_anchor_seabed_tolerance_is_native(depth, anchor_z, accepted):
    text = _edit(
        _HELD, ("50.0 WtrDpth", f"{depth} WtrDpth"), ("400.0 0.0 -50.0", f"400.0 0.0 {anchor_z}")
    )
    if accepted:
        DeckFile.from_text(text)
    else:
        _rejects(text, re.escape(f"z = {float(anchor_z):.10g} m is under"))


@pytest.mark.parametrize(
    ("arc", "accepted"),
    [("5000", False), ("170.215", True), ("70:7:118.12", True), ("100:10:180", False)],
)
def test_attachment_arc_length_lies_on_the_line(arc, accepted):
    text = _example("lazy_wave_buoyancy_modules.dat", ("70.614:5.0:115.614", arc))
    if accepted:
        DeckFile.from_text(text)
    else:
        _rejects(text, "ATTACHMENTS ArcLength lies beyond the end of line 1")


_STIFFENER_ROOT = "1       A    0.4     0.45    0.45   0.17    5.0e7   1150"


@pytest.mark.parametrize(
    ("row", "message"),
    [
        ("1 A 0.4 0.45 0.45 0.17 5.0e7", "STIFFENERS rows must be: LineID End Length"),
        ("x A 0.4 0.45 0.45 0.17 5.0e7 1150", "STIFFENERS LineID must be an integer"),
        ("2 A 0.4 0.45 0.45 0.17 5.0e7 1150", "STIFFENERS row references undefined LINE id 2"),
        ("1 C 0.4 0.45 0.45 0.17 5.0e7 1150", "STIFFENERS End must be A or B"),
        ("1 A 0.4 0.45 0.45 0.17 5.0e7 dense", "must be plain numbers"),
        ("1 A 0.4 0.45 0.45 0.17 2.0e15 1150", "must be finite and at most 1e15"),
        ("1 A 0.0 0.45 0.45 0.17 5.0e7 1150", "Length, RootOD, TipOD and E must be > 0"),
        ("1 A 0.4 0.45 0.45 -0.1 5.0e7 1150", "InnerD and Density must be >= 0"),
        ("1 A 0.4 0.45 0.15 0.17 5.0e7 1150", "InnerD must be smaller than RootOD and TipOD"),
        ("1 A 0.4 1.0e6 0.45 0.17 5.0e7 1150", "RootOD and TipOD must be at most 1e3 m"),
        ("1 A 0.4 0.45 1001.0 0.17 5.0e7 1150", "RootOD and TipOD must be at most 1e3 m"),
        ("1 B 167.0 0.45 0.45 0.17 5.0e7 1150", "are longer than the line"),
    ],
)
def test_stiffener_rows_are_native(row, message):
    _rejects(_example("lazy_wave_bend_stiffener.dat", (_STIFFENER_ROOT, row)), message)


def test_stiffener_needs_a_finite_ei_line():
    text = _section(_HELD, "STIFFENERS", "1 A 1.0 0.5 0.5 0.3 5.0e7 1150")
    _rejects(text, "STIFFENERS name line 1, which is not a finite-EI line")


@pytest.mark.parametrize(
    ("channel", "message"),
    [
        ("StfMom1N3", None),
        ("FairDefl1", None),
        ("AnchDefl1", "needs a Rigid or rotational-spring END CONNECTIONS row at End B of line 1"),
    ],
)
def test_stiffener_and_deflection_channels_are_native(channel, message):
    text = _example("lazy_wave_bend_stiffener.dat", ('"TDP1s"', f'"TDP1s"\n"{channel}"'))
    if message is None:
        DeckFile.from_text(text)
    else:
        _rejects(text, message)


def test_stiffener_moment_needs_a_stiffener():
    text = _example("lazy_wave_vessel_rao.dat", ('"TDP1s"', '"TDP1s"\n"StfMom1N3"'))
    _rejects(text, "line 1 has no STIFFENERS, so no stiffener moment")


def test_stiffener_aliases_and_end_spellings_are_native():
    text = _example(
        "lazy_wave_bend_stiffener.dat",
        ("STIFFENERS ---", "BEND STIFFENERS ---"),
        (_STIFFENER_ROOT, "1 enda 0.4 0.45 0.45 0.17 5.0e7 1150"),
    )
    DeckFile.from_text(text)


# --------------------------------------------------------------------------- output channels


@pytest.mark.parametrize(
    "channel",
    [
        "FairTen01",
        "AnchIncl001",
        "AnchFz01",
        "AnchFH001",
        "TDP01s",
        "TDP01Grd",
        "L01N1px",
        "Ten01N01",
        "Point01px",
        "Con01pz",
    ],
)
def test_line_and_point_channel_ids_may_have_leading_zeros(channel):
    DeckFile.from_text(_edit(_HELD, ("FairTen1\n", f"{channel}\n")))


@pytest.mark.parametrize("channel", ["TDP1q", "Point1pq", "Ten9N0", "AnchFz1z", "TDP1Grd1"])
def test_malformed_line_and_point_channels_fail_closed(channel):
    _rejects(_edit(_HELD, ("FairTen1\n", f"FairTen1\n{channel}\n")), "unsupported OUTPUT")


@pytest.mark.parametrize("channel", ["Ten1N0", "L1N0px", "BendMom1N0"])
def test_node_zero_channels_name_the_numbering(channel):
    _rejects(_edit(_HELD, ("FairTen1\n", f"FairTen1\n{channel}\n")), "node numbers start at 1")


_R6_ROW = (
    "1   Rigid6  0.0  0.0  -20.0  0.0   0.0    0.0   2.0e4   40.0  0.0  0.0  0.0  8.0   0.5  "
    "3.5e4   3.5e4   3.5e4"
)


def _buoy(*edits: tuple[str, str]) -> str:
    return _example("rigid6_buoy.dat", *edits)


@pytest.mark.parametrize("channel", ["Body01Px", "Body1RVx", "Body1RAz", "Body1Rz", "Body1Mz"])
def test_body_channels_follow_the_native_quantities(channel):
    DeckFile.from_text(_buoy(('"FairTen1"', f'"{channel}"')))


@pytest.mark.parametrize("channel", ["Body1RPx", "Body1TenA", "Body1Sub"])
def test_body_channels_outside_the_native_quantities_fail_closed(channel):
    _rejects(_buoy(('"FairTen1"', f'"{channel}"')), "unsupported OUTPUT channel")


def _point3_buoy(*edits: tuple[str, str]) -> str:
    return _buoy(
        (_R6_ROW, "1 Point3 0.0 0.0 -20.0 0.0 0.0 0.0 2.0e4 40.0 0.0 0.0 0.0 8.0 0.5"),
        ("2     Body1     -0.75      1.299      -2.0      0       0       0      0\n", ""),
        ("3     Body1     -0.75      -1.299     -2.0      0       0       0      0\n", ""),
        ("2     2       5       -", "2     1       5       -"),
        ("3     3       6       -", "3     1       6       -"),
        ('"Point2pz"\n', ""),
        ('"Point3pz"\n', ""),
        *edits,
    )


def test_body_channels_report_rigid6_bodies_only():
    DeckFile.from_text(_point3_buoy())
    _rejects(_point3_buoy(('"FairTen1"', '"Body1Px"')), "Body<N> channels report Rigid6 bodies")


def _spar(*edits: tuple[str, str]) -> str:
    return _example("rod_moored_spar.dat", *edits)


_SPAR_ROD = "1    spar      Free   0.0   0.0   -30.0   0.0   0.0   -20.0   1         p"


@pytest.mark.parametrize(
    ("channel", "accepted"),
    [("Rod1N0px", True), ("Rod01N1pz", True), ("Rod1N2px", False), ("Rod1RVx", True)],
)
def test_rod_node_channels_stay_within_numsegs(channel, accepted):
    text = _spar(('"FairTen1"', f'"{channel}"'))
    if accepted:
        DeckFile.from_text(text)
    else:
        _rejects(text, "rod node beyond NumSegs")


def test_rod_channel_quantities_follow_the_native_vocabulary():
    _rejects(_spar(('"FairTen1"', '"Rod1RPx"')), "unsupported OUTPUT channel")


# --------------------------------------------------------------------------- rods


@pytest.mark.parametrize("kind", ["CoupledPinned", "CpldPin", "VesselPinned", "VesPin"])
def test_coupled_pinned_rods_need_a_coupled_host(kind):
    # native finalize_checks: the host moves the pin, so the standalone driver refuses the rod
    # (zero-length ones too) and the coupled route takes it
    pinned = _spar((_SPAR_ROD, _SPAR_ROD.replace("Free", kind)))
    _rejects(pinned, "requires a coupled host")
    zero_length = _spar(
        (_SPAR_ROD, _SPAR_ROD.replace("Free", kind).replace("-20.0   1", "-20.0   0"))
    )
    _rejects(zero_length, "requires a coupled host")
    still = ("uniform 0.5 0.0 0.0  current", "none current")
    DeckFile.from_text(
        _spar((_SPAR_ROD, _SPAR_ROD.replace("Free", kind)), still), caller_driven=True
    )
    # a zero-length one is a Coupled point at End A that its End B point merges into
    DeckFile.from_text(
        _spar(
            (_SPAR_ROD, _SPAR_ROD.replace("Free", kind).replace("-20.0   1", "-20.0   0")),
            still,
            ('"Point2px"\n"Point2pz"', '"Point3px"\n"Point3pz"'),
        ),
        caller_driven=True,
    )


def test_rod_endpoints_have_an_admissible_magnitude():
    text = _spar((_SPAR_ROD, _SPAR_ROD.replace("0.0   0.0   -30.0", "2.0e6   0.0   -30.0")))
    _rejects(text, "ROD endpoint coordinates must be at most 1e6 m")


def test_rod_numsegs_has_no_upper_bound():
    DeckFile.from_text(_spar((_SPAR_ROD, _SPAR_ROD.replace("   1         p", "   2000000   p"))))


def _zero_length(kind: str, rod_type: str = "spar") -> str:
    return _spar(
        (_SPAR_ROD, f"1    {rod_type}  {kind}   0.0   0.0   -30.0   0.0   0.0   -20.0   0   -"),
        ('"Point2px"\n', ""),
        ('"Point2pz"\n', ""),
    )


def test_zero_length_rod_is_a_point_before_the_rod_checks():
    # native collapse_zero_length_rods runs before the rod-type and motion checks
    DeckFile.from_text(_zero_length("Free", rod_type="nope"))
    DeckFile.from_text(_zero_length("Coupled"))


def test_zero_length_rod_merges_its_end_points():
    # the Rod1B POINT row (id 2) becomes the Rod1A connector: its channels no longer exist
    text = _spar((_SPAR_ROD, "1    spar  Free   0.0   0.0   -30.0   0.0   0.0   -20.0   0   -"))
    _rejects(text, "'Point2px' references an unknown point")


def test_both_rod_end_spellings_name_one_point():
    _rejects(
        _spar(("1     1       3       -", "1     R1A     Rod1A   -")),
        "LINE NodeA and NodeB must differ",
    )
    _rejects(
        _spar(("1     1       3       -", "1     R1A     1       -")),
        "LINE NodeA and NodeB must differ",
    )


def test_body_fixed_rod_ends_resolve_to_body_points():
    text = _buoy(
        (
            f"{_BAR} POINTS",
            f"{_BAR} ROD TYPES {_BAR}\nName Diam Mass Cd Ca CdEnd CaEnd\n"
            "spar 1.0 300.0 0.8 1.0 0.0 0.0\n"
            f"{_BAR} RODS {_BAR}\nID RodType Type XA YA ZA XB YB ZB NumSegs Outputs\n"
            "1 spar Body1 0 0 -2 0 0 -8 2 -\n"
            f"{_BAR} POINTS",
        ),
        ("1     1       4       -", "1     R1B     4       -"),
    )
    deck = DeckFile.from_text(text)
    types: dict[str, str] = {}
    keys, merged = deck._resolve_rod_ends(types, set(), {})
    assert keys["rod1b"] == "rod1b" and types["rod1b"] == "body1" and merged == {}


def test_coupled_decks_take_bodies_or_rods_not_both():
    # native CD_Init_Deck_Aggregate (OpenFAST CompMooring = 5, FAST.Farm, the C API): the coupled
    # march advances the bodies or the rods of a deck; a rod fixed to the body counts as a rod
    rods = (
        f"{_BAR} ROD TYPES {_BAR}\nName Diam Mass Cd Ca CdEnd CaEnd\n"
        "spar 1.0 300.0 0.8 1.0 0.0 0.0\n"
        f"{_BAR} RODS {_BAR}\nID RodType Type XA YA ZA XB YB ZB NumSegs Outputs\n"
        "1 spar Body1 0 0 -2 0 0 -8 2 -\n"
    )
    # (in still water: a coupled deck current on a deck with bodies is refused first)
    still = ("uniform 0.6 0.0 0.0  current", "none  current")
    text = _buoy(still, (f"{_BAR} POINTS", rods + f"{_BAR} POINTS"))
    DeckFile.from_text(text)  # the standalone multibody march
    _rejects(text, "a coupled deck with both BODIES and RODS", caller_driven=True)
    DeckFile.from_text(_buoy(still), caller_driven=True)
    # a zero-length rod is a point, not a rod
    zero = rods.replace("0 0 -8 2 -", "0 0 -2 0 -")
    zero_text = _buoy(still, (f"{_BAR} POINTS", zero + f"{_BAR} POINTS"))
    DeckFile.from_text(zero_text, caller_driven=True)


# --------------------------------------------------------------------------- dispatch gates


_FAILURE = ("FAILURE", "ID Point Lines FailTime FailTen", "1 1 1 10.0 0")


def test_failure_needs_the_dynamic_point_system_route():
    DeckFile.from_text(_section(_HELD, *_FAILURE))
    _rejects(_section(_STATIC, *_FAILURE), r"FAILURE requires a dynamic deck \(dtM and TMax\)")
    _rejects(
        _section(_options(_HELD, "0.5 frictionMu"), *_FAILURE),
        "FAILURE deck does not support seabed friction",
    )
    finite = _edit(_HELD, ("1.674e9 -1.0 0.0", "1.674e9 -1.0 1.0e4"))
    _rejects(_section(finite, *_FAILURE), "FAILURE is not supported on finite-EI decks")
    rod_failure = ("FAILURE", "ID Point Lines FailTime FailTen", "1 3 1 10.0 0")
    _rejects(_section(_spar(), *rod_failure), "ROD decks")


def test_failure_on_rigid6_decks_takes_no_other_dynamic_point_or_motion():
    free = _buoy(
        ("4     Fixed     40.0", "7 Connect 20 0 -60 0 0 0 0\n4     Fixed     40.0"),
        ("3     3       6       -", "3     3       6       -\n4 7 4 -"),
        ("3        poly       86.85    20", "3        poly       86.85    20\n4 poly 70 10"),
    )
    failure = ("FAILURE", "ID Point Lines FailTime FailTen", "1 4 1 10.0 0")
    _rejects(_section(free, *failure), "does not support Connect/Free or Point3 body points")
    moving = _buoy(
        (
            "uniform 0.6 0.0 0.0  current",
            "data/vessel/vessel_surge_heave_pitch_12s_dt005.txt vesselMotion\n"
            "uniform 0.6 0.0 0.0  current",
        )
    )
    _rejects(_section(moving, *failure), "FAILURE deck does not support motionFile coupling")


@pytest.mark.parametrize(
    "body",
    [_R6_ROW, "1 Free 0.0 0.0 -20.0 0.0 0.0 0.0 2.0e4 0|0|0 3.5e4 40.0 8.0 0.5"],
)
def test_multibody_decks_take_no_prescribed_motion_in_either_body_spelling(body):
    text = _buoy(
        (_R6_ROW, body),
        (
            "4     Fixed     40.0",
            "7 Connect 20 0 -60 0 0 0 0\n8 Coupled 0 0 0 0 0 0 0\n4     Fixed     40.0",
        ),
        ("3     3       6       -", "3     3       6       -\n4 8 7 -"),
        ("3        poly       86.85    20", "3        poly       86.85    20\n4 poly 70 10"),
        (
            "uniform 0.6 0.0 0.0  current",
            "data/vessel/vessel_surge_heave_pitch_12s_dt005.txt vesselMotion\n"
            "uniform 0.6 0.0 0.0  current",
        ),
    )
    _rejects(text, "a mixed-topology deck .* does not support motionFile coupling")


def test_connect_point_deck_takes_no_prescribed_motion():
    text = _edit(
        _HELD,
        (
            "1 Fixed 400.0 0.0 -50.0 0 0 0 0",
            "1 Fixed 400.0 0.0 -50.0 0 0 0 0\n3 Connect 200 0 -30 0 0 0 0",
        ),
        ("1 2 1 -", "1 2 3 -\n2 3 1 -"),
        ("1 chain 410.0 41", "1 chain 210.0 21\n2 chain 210.0 21"),
        ("10.0 TMax\n", "10.0 TMax\nmotion.txt motionFile\n"),
    )
    _rejects(text, "a Connect/Free dynamic-point deck does not support motionFile coupling")


def _modes(base: str) -> str:
    marker = next(line for line in base.splitlines() if "OPTIONS" in line and "---" in line)
    return _edit(base, (marker + "\n", marker + "\n5 nModes\n"))


def test_modal_analysis_follows_the_native_deck_rules():
    DeckFile.from_text((EXAMPLES / "chain_modes.dat").read_text(encoding="utf-8"))
    DeckFile.from_text((EXAMPLES / "lazy_wave_modes.dat").read_text(encoding="utf-8"))
    _rejects(
        _example("chain_modes.dat", ("100.0        WtrDpth", "seabed.txt bathymetryFile")),
        "nModes supports a flat WtrDpth seabed only",
    )
    _rejects(_modes(_buoy()), "OPTION nModes needs a deck of lines between Fixed and")
    _rejects(_modes(_section(_HELD, *_FAILURE)), "no BODIES, RODS, Connect/Free points or FAILURE")


def test_modal_analysis_holds_a_moving_end_b_of_a_finite_ei_line():
    # the modes hold both line ends: a finite-EI line shared by two turbines is accepted (its
    # moving End B held at its static position, as End A is)
    text = (
        "title\n"
        f"{_BAR} LINE TYPES {_BAR}\n"
        "chain 0.1 20.0 1.0e9 -1.0 1.0e4 1.2 0.2 1.0 0.0\n"
        f"{_BAR} TURBINES {_BAR}\n"
        "1 0 0 0\n2 600 0 0\n"
        f"{_BAR} POINTS {_BAR}\n"
        "1 Turbine1 0 0 -10 0 0 0 0\n2 Turbine2 0 0 -10 0 0 0 0\n3 Fixed 300 0 -100 0 0 0 0\n"
        f"{_BAR} LINES {_BAR}\n"
        "1 1 3 -\n2 1 2 -\n"
        f"{_BAR} SECTIONS {_BAR}\n"
        "1 chain 380 20\n2 chain 620 30\n"
        f"{_BAR} OPTIONS {_BAR}\n"
        "100 WtrDpth\n0.1 dtM\n1.0 TMax\n5 nModes\n"
        f"{_BAR} need this line {_BAR}\n"
    )
    assert DeckFile.from_text(text).option("nModes").values == ("5",)


def test_mixed_aggregate_route_takes_no_modal_analysis():
    # the executable runs a mixed EI=0/finite-EI deck without objects on the aggregate,
    # which writes no modal files
    text = _example("iea15mw_umaine_mixed_cabledyn.dat", ("0.0      TMax", "0.0 TMax\n5 nModes"))
    _rejects(text, "OPTION nModes is not supported for mixed EI=0/finite-EI decks")
    DeckFile.from_text(text, caller_driven=True)
    DeckFile.from_text(text.replace("5 nModes", "0 nModes"))


# --------------------------------------------------------------------------- row syntax


def test_unquoted_ea_text_may_not_mix_quote_characters():
    text = _edit(_HELD, ("1.674e9 -1.0 0.0", "SYROPE:a'b\"c|1|2 1|1 0.0"))
    _rejects(text, "mixes both quote characters")


# --------------------------------------------------------------------------- companion files


def _kinematic_base(folder: Path, *rows: str, files: dict[str, str] | None = None) -> Path:
    folder.mkdir(parents=True, exist_ok=True)
    for name, text in (files or {}).items():
        (folder / name).write_bytes(text.encode())
    path = folder / "base.dat"
    path.write_bytes(_options(_HELD, *rows).encode())
    return path


def test_generated_cases_carry_the_fixed_name_kinematics_files(tmp_path):
    base = _kinematic_base(
        tmp_path / "src",
        "7 WaterKin",
        "1 Currents",
        files={
            "wave_frequencies.txt": _WAVE_FREQUENCIES,
            "current_profile.txt": "-50 0.1 0 0\n0 0.5 0 0\n",
        },
    )
    out = tmp_path / "cases"
    generate_deck_cases(base, out, {"a": {"option.dtM": 0.05}, "b": {"option.WaterKin": 0}})
    assert (out / "wave_frequencies.txt").read_text(encoding="utf-8") == _WAVE_FREQUENCIES
    manifest = json.loads((out / "cases.json").read_text(encoding="utf-8"))
    digest = hashlib.sha256(_WAVE_FREQUENCIES.encode()).hexdigest()
    first, second = manifest["cases"]
    assert first["companion_files"]["wave_frequencies.txt"] == digest
    assert set(first["companion_files"]) == {"wave_frequencies.txt", "current_profile.txt"}
    assert set(second["companion_files"]) == {"current_profile.txt"}
    # run_study refuses a case whose kinematics file changed after generation
    (out / "wave_frequencies.txt").write_text("0 0 0 0\n", encoding="utf-8")
    with pytest.raises(StudyFormatError, match="companion file"):
        run_study(out / "cases.json", executable=tmp_path / "missing.exe")


@pytest.mark.parametrize(
    ("mode", "name"), [("2", "current_profile_dynamic.txt"), ("5", "current_profile_4d.txt")]
)
def test_generated_cases_carry_the_moordyn_c_current_tables(tmp_path, mode, name):
    table = _CURRENT_TABLES[mode]
    base = _kinematic_base(tmp_path / "src", f"{mode} Currents", files={name: table})
    out = tmp_path / "cases"
    generate_deck_cases(base, out, {"a": {"option.dtM": 0.05}})
    assert (out / name).read_text(encoding="utf-8") == table
    manifest = json.loads((out / "cases.json").read_text(encoding="utf-8"))
    assert set(manifest["cases"][0]["companion_files"]) == {name}


def test_study_manifest_companion_entries_are_checked(tmp_path):
    base = _kinematic_base(
        tmp_path / "src", "7 WaterKin", files={"wave_frequencies.txt": _WAVE_FREQUENCIES}
    )
    out = tmp_path / "cases"
    generate_deck_cases(base, out, {"a": {}})
    manifest_path = out / "cases.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    for bad, message in (
        ([], "companion_files must be an object"),
        ({"../evil.txt": "0" * 64}, "unknown companion file"),
    ):
        manifest["cases"][0]["companion_files"] = bad
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        with pytest.raises(StudyFormatError, match=message):
            run_study(manifest_path, executable=tmp_path / "missing.exe")


def test_case_generation_fails_closed_without_the_kinematics_file(tmp_path):
    base = _kinematic_base(tmp_path / "src", "7 WaterKin")
    with pytest.raises(DeckFormatError, match=r"reads wave_frequencies\.txt from its folder"):
        generate_deck_cases(base, tmp_path / "cases", {"a": {}})
    assert not (tmp_path / "cases").exists()


def test_case_generation_keeps_a_different_kinematics_file_without_overwrite(tmp_path):
    base = _kinematic_base(
        tmp_path / "src", "7 WaterKin", files={"wave_frequencies.txt": _WAVE_FREQUENCIES}
    )
    out = tmp_path / "cases"
    out.mkdir()
    (out / "wave_frequencies.txt").write_text("0 0 0 0\n", encoding="utf-8")
    with pytest.raises(FileExistsError, match=r"wave_frequencies\.txt"):
        generate_deck_cases(base, out, {"a": {}})
    generate_deck_cases(base, out, {"a": {}}, overwrite=True)
    assert (out / "wave_frequencies.txt").read_text(encoding="utf-8") == _WAVE_FREQUENCIES


def test_case_generation_in_the_source_folder_copies_nothing(tmp_path):
    base = _kinematic_base(
        tmp_path, "7 WaterKin", files={"wave_frequencies.txt": _WAVE_FREQUENCIES}
    )
    (case,) = generate_deck_cases(base, tmp_path, {"a": {}})
    assert case.deck.parent == tmp_path


def test_invalid_case_creates_no_output_folder(tmp_path):
    base = _kinematic_base(tmp_path / "src")
    with pytest.raises(DeckFormatError):
        generate_deck_cases(base, tmp_path / "cases", {"a": {"option.dtM": -1.0}})
    assert not (tmp_path / "cases").exists()


def test_model_save_copies_the_kinematics_files_when_rebasing(tmp_path):
    base = _kinematic_base(
        tmp_path / "src", "3 WaveKin", files={"wave_elevation.txt": "0 0\n1 0.1\n2 0\n3 -0.1\n"}
    )
    model = DeckModel.load(base)
    saved = model.save(tmp_path / "copy" / "deck.dat")
    assert (saved.parent / "wave_elevation.txt").is_file()
    unmoved = model.save(tmp_path / "plain" / "deck.dat", rebase=False)
    assert not (unmoved.parent / "wave_elevation.txt").exists()


def test_rebased_syrope_path_may_contain_a_space(tmp_path):
    source = tmp_path / "src"
    (source / "my data").mkdir(parents=True)
    text = _example(
        "syrope_polyester_mooring.dat",
        ("SYROPE:data/syrope/syrope_settings.dat", "SYROPE:my data/settings.txt"),
    )
    (source / "deck.dat").write_text(text, encoding="utf-8")
    (case,) = generate_deck_cases(source / "deck.dat", tmp_path / "out", {"a": {}})
    rebased = DeckFile.read(case.deck)
    assert rebased.line_types[0].tokens[3].startswith("SYROPE:../src/my data/settings.txt|")


def test_rebased_option_path_with_a_space_fails_closed(tmp_path):
    source = tmp_path / "my src"
    source.mkdir()
    text = _options(_HELD, "motion.txt motionFile")
    (source / "deck.dat").write_text(text, encoding="utf-8")
    with pytest.raises(DeckFormatError, match="which an OPTIONS value cannot hold"):
        generate_deck_cases(source / "deck.dat", tmp_path / "out", {"a": {}})


# --------------------------------------------------------------------------- DeckModel loading


def test_model_loads_a_quoted_line_type_name_with_a_space():
    text = _edit(
        _HELD, ("chain 0.252", '"my chain" 0.252'), ("1 chain 410.0", '1 "my chain" 410.0')
    )
    model = DeckModel.from_text(text)
    assert model.line_types["my chain"].name == "my chain"
    assert '"my chain"' in model.to_text()


def test_external_loads_take_both_column_orders_and_sequential_ids():
    header = "ID Object Force Blin Bquad CSys"
    rows = ("1 Body1 0 1 1 G", "2 Body1 G 1|0|0 0 0", "3 Body1 0|0|5 2 0 L")
    model = DeckModel.from_text(_section(_buoy(), "EXTERNAL LOADS", header, *rows))
    assert [(load.id, load.csys) for load in model.external_loads] == [
        (1, "G"),
        (2, "G"),
        (3, "L"),
    ]
    assert model.external_loads[2].force == (0.0, 0.0, 5.0)
    DeckFile.from_text(model.to_text())
    for bad, message in (
        (("L1 Body1 G 0 1 1",), "ID numbers must be sequential"),
        (("1 Body1 0 1 1 G", "3 Body1 0 1 1 G"), r"expected 2, found '3'"),
        (("1 Body1 G 0 1 L",), "needs the CSys letter"),
        (("1 Body1 0 1 1 -",), "CSys must be G or L for a body"),
    ):
        _rejects(_section(_buoy(), "EXTERNAL LOADS", header, *bad), message)


def test_named_rejections_of_moordyn_only_rows():
    _rejects(_options(_HELD, "0.5 mu_kT"), "CableDyn reads frictionMu")
    _rejects(_options(_HELD, "1.2 StatDynFricScale"), "has no CableDyn equivalent")
    _rejects(_options(_HELD, "airy 2 8 0 waves regular"), "is a positional")
    _rejects(_options(_HELD, "200 WaveComponents", "600 WaveDirections"), "at most 100000")
    DeckFile.from_text(_options(_HELD, "200 WaveComponents", "500 WaveDirections"))
    _rejects(_edit(_HELD, ("0.252 390.0", "0.252 39+1")), "is not a plain number")
    turbine = _edit(_HELD, ("2 Coupled 0.0", "2 Turbine1 0.0"))
    _rejects(turbine, "Turbine<J> points need a TURBINES section")


def test_model_keeps_keyword_end_connection_stiffness():
    source = _example("lozon_gomex80_power_cable.dat")
    marker = next(line for line in source.splitlines() if "OPTIONS" in line and "---" in line)
    text = _edit(
        source,
        (marker, f"{_BAR} END CONNECTIONS {_BAR}\n1 EndA Inf -0.25 0.0 -0.97\n{marker}"),
    )
    model = DeckModel.from_text(text)
    assert model.end_connections[0].stiffness == "Inf"


def test_model_accepts_numpy_numbers_and_reports_argument_errors():
    model = DeckModel.from_text(_HELD)
    model.points[1].x = np.float32(401.5)
    model.add_line_type("wire", diam=np.float64(0.1), mass=np.int64(20), ea=1.0e9)
    assert "401.5" in model.to_text()
    with pytest.raises(TypeError, match="output channel must be a string"):
        model.outputs.remove(1)  # type: ignore[arg-type]
    with pytest.raises(TypeError, match="pass a point id as an integer"):
        model.add_line(9, "2", 1)
    with pytest.raises(ValueError, match="three numbers"):
        model.add_end_connection(1, "A", "Pinned", (0.0, 1.0))


# --------------------------------------------------------------------------- edge rows


@pytest.mark.parametrize(
    ("kind", "resolved"),
    [
        ("free", "free"),
        ("fixed", "fixed"),
        ("pinned", "fixed"),
        ("vessel", "coupled"),
        ("body3pinned", "body3"),
        ("odd", "odd"),
    ],
)
def test_zero_length_rod_connector_takes_the_rod_attachment(monkeypatch, kind, resolved):
    deck = DeckFile.from_text(_spar())
    monkeypatch.setattr(DeckFile, "_rod_rows_by_id", lambda self: {1: (kind, 0)})
    types = {"1": "rod1a", "2": "rod1b"}
    keys, merged = deck._resolve_rod_ends(types, {"1", "2"}, {})
    assert keys == {"rod1a": "1", "rod1b": "1"} and merged == {"2": "1"}
    assert types["1"] == resolved


def test_rod_ids_must_be_integers():
    _rejects(
        _spar((_SPAR_ROD, _SPAR_ROD.replace("1    spar", "x    spar", 1))),
        "rod id must be an integer",
    )


def test_external_load_on_a_point3_body_is_refused_by_name():
    load = ("EXTERNAL LOADS", "ID Object CSys Force Blin Bquad", "1 Body1 G 0 1 1")
    _rejects(_section(_point3_buoy(), *load), "EXTERNAL LOADS apply to Rigid6 bodies only")


@pytest.mark.parametrize(
    ("path", "message"),
    [
        ("", "must not be empty"),
        ("my data/set #1.txt", "comment/header markers"),
        ("a\tb.txt", "quotes or line breaks"),
    ],
)
def test_quoted_syrope_paths_reject_what_a_quote_cannot_hold(path, message):
    from cabledyn.deck_file import _render_quoted_text

    with pytest.raises(ValueError, match=message):
        _render_quoted_text(path)


# --------------------------------------------------------------------------- aggregate routes

_MIXED = _edit(
    _HELD,
    (
        "chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0\n",
        "chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0\n"
        "cable 0.2 60.0 4.0e8 0.0 1.0e4 1.2 0.1 1.0 0.0\n",
    ),
    (
        "2 Coupled 0.0 0.0 0.0 0 0 0 0",
        "2 Coupled 0.0 0.0 0.0 0 0 0 0\n3 Fixed -400.0 0.0 -50.0 0 0 0 0",
    ),
    ("1 2 1 -", "1 2 1 -\n2 2 3 -"),
    ("1 chain 410.0 41", "1 chain 410.0 41\n2 cable 420.0 42"),
)


def test_standalone_mixed_deck_runs_on_the_aggregate_in_its_current():
    DeckFile.from_text(_MIXED)
    DeckFile.from_text(_edit(_MIXED, ("2 2 3 -", "2 2 3 r")))
    # the aggregate marches the deck current (deck_current) but evaluates no deck waves
    DeckFile.from_text(_options(_MIXED, "uniform 0.5 0 0 current"))
    DeckFile.from_text(_options(_MIXED, "profile -50 0.1 0 0 0 0.5 0.2 0 current"))
    for mode in (1, 2, 5):
        DeckFile.from_text(_options(_MIXED, f"{mode} Currents"))
    _rejects(_options(_MIXED, "airy 2 8 0 waves"), "evaluates no deck waves")
    _rejects(_options(_MIXED, "7 WaveKin"), "WaveKin 7 waves are not supported")
    _rejects(_options(_MIXED, "uniform 0.5 0 0 current", "2 Currents"), "double-counting")
    _rejects(
        _edit(_options(_MIXED, "uniform 0.5 0 0 current"), ("0.1 dtM\n10.0 TMax\n", "")),
        "standalone OPTION current requires dtM and TMax",
    )
    _rejects(_edit(_MIXED, ("2 2 3 -", "2 2 3 pt")), "writes no per-line files")
    # the driver marches the deck's motionFile or vesselMotion; vesselRAO needs deck waves
    DeckFile.from_text(_options(_MIXED, "m.txt motionFile"))
    DeckFile.from_text(_options(_MIXED, "v.txt vesselMotion", "0|0|0 vesselRef"))
    _rejects(_options(_MIXED, "r.txt vesselRAO"), "vesselRAO needs deck waves")
    _rejects(_options(_MIXED, "r.txt vesselRAO", "airy 2 8 0 waves"), "evaluates no deck waves")


def test_coupled_route_takes_no_motion_file_and_needs_a_line():
    _rejects(
        _options(_HELD, "m.txt motionFile"),
        "driven by the host, not a deck motionFile",
        caller_driven=True,
    )
    no_lines = _buoy(
        ("1     1       4       -\n", ""),
        ("2     2       5       -\n", ""),
        ("3     3       6       -\n", ""),
        ("1        poly       86.85    20\n", ""),
        ("2        poly       86.85    20\n", ""),
        ("3        poly       86.85    20\n", ""),
        ('"FairTen1"\n', ""),
        ('"FairTen2"\n', ""),
        ('"FairTen3"\n', ""),
        ('"AnchTen1"\n', ""),
    )
    DeckFile.from_text(no_lines)
    _rejects(no_lines, "needs at least one line", caller_driven=True)


# --------------------------------------------------------------------------- torsion

# A straight finite-EI line clamped at a Coupled and a Fixed point with the optional torsion
# columns of END CONNECTIONS (the pure-torsion deck of test_torsion_deck).
_TORSION = f"""\
{_BAR} CableDyn Input File {_BAR}
in-memory fixture: a straight finite-EI line restrained in torsion at both ends
{_BAR} LINE TYPES {_BAR}
Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat
cab 0.2 32.2 1.0e7 0.0 1.0e6 1.0e8 5.0e4 1.0 1.0 0.0 0.0 0.0 0.0
{_BAR} POINTS {_BAR}
ID Type X Y Z Mass Vol CdA Ca
1 Coupled 0.0 0.0 -50.0 0 0 0 0
2 Fixed 100.0 0.0 -50.0 0 0 0 0
{_BAR} LINES {_BAR}
ID NodeA NodeB Outputs
1 1 2 -
{_BAR} SECTIONS {_BAR}
LineID LineType Length NumSegs
1 cab 100.0 40
{_BAR} END CONNECTIONS {_BAR}
LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist
1 A Rigid 1 0 0 Rigid 0 0 1 0
1 B Rigid 1 0 0 Rigid 0 0 1 720
{_BAR} OPTIONS {_BAR}
9.80665 g
1025.0 rhoW
50.0 WtrDpth
0.1 dtM
0.0 TMax
{_BAR} OUTPUTS {_BAR}
Torq1N1
Twist1N41
Twist1
{_BAR} need this line {_BAR}
"""
_TORSION_ROW_A = "1 A Rigid 1 0 0 Rigid 0 0 1 0\n"


def test_torsion_end_connection_columns_are_accepted():
    deck = DeckFile.from_text(_TORSION)
    assert len(deck.end_connections[0].tokens) == 10 + 1
    # ten columns (no pretwist), keywords and a finite stiffness, mixed with six-column rows
    DeckFile.from_text(_edit(_TORSION, (_TORSION_ROW_A, "1 A Rigid 1 0 0 1.0e5 0 0 1\n")))
    DeckFile.from_text(_edit(_TORSION, (_TORSION_ROW_A, "1 A Rigid 1 0 0 Inf 0 1 1 -45\n")))
    six = _edit(
        _TORSION,
        (_TORSION_ROW_A, "1 A Rigid 1 0 0\n"),
        ("Torq1N1\nTwist1N41\nTwist1\n", "FairTen1\n"),
    )
    DeckFile.from_text(six)


@pytest.mark.parametrize(
    ("row", "message"),
    [
        ("1 A Rigid 1 0 0 Rigid 0 0\n", "or 10 or 11 with the torsion columns"),
        ("1 A Rigid 1 0 0 Rigid 0 0 1 0 0\n", "or 10 or 11 with the torsion columns"),
        ("1 A Rigid 1 0 0 Stiff 0 0 1 0\n", "torsional stiffness must be finite and non-negative"),
        ("1 A Rigid 1 0 0 -1.0 0 0 1 0\n", "torsional stiffness must be finite and non-negative"),
        ("1 A Rigid 1 0 0 Rigid 0 0 0 0\n", r"reference normal \(NxX NxY NxZ\) must be non-zero"),
        ("1 A Rigid 1 0 0 Rigid 2 0 0 0\n", "must not be parallel to the direction Ez"),
        ("1 A Rigid 1 0 0 Rigid 0 x 1 0\n", "reference normal column 9 must be numeric"),
        ("1 A Rigid 1 0 0 Rigid 0 0 1 nan\n", "is not a finite number"),
    ],
)
def test_torsion_end_connection_columns_follow_the_native_rules(row, message):
    _rejects(_edit(_TORSION, (_TORSION_ROW_A, row)), message)


@pytest.mark.parametrize(
    ("row", "message"),
    [
        (
            "1 A Rigid 1 0 0 Stiff 0 0 1 0\n",
            r"line 1 End A: END CONNECTIONS torsional stiffness .*, got 'Stiff'",
        ),
        ("1 A Rigid 1 0 0 -1.0 0 0 1 0\n", r"line 1 End A: .*, got '-1\.0'"),
        ("1 A -5 1 0 0 Rigid 0 0 1 0\n", r"line 1 End A: END CONNECTIONS stiffness .*, got '-5'"),
        (
            "1 A Rigid 0 0 0 Rigid 0 0 1 0\n",
            r"line 1 End A: .*direction must be non-zero, got \(0, 0, 0\)",
        ),
        ("1 A Rigid 1 0 0 Rigid 0 0 0 0\n", r"line 1 End A: .*must be non-zero, got \(0, 0, 0\)"),
        (
            "1 A Rigid 1 0 0 Rigid 2 0 0 0\n",
            r"line 1 End A: .*\(2, 0, 0\) must not be parallel to the direction Ez \(1, 0, 0\)",
        ),
        ("1 C Rigid 1 0 0 Rigid 0 0 1 0\n", r"line 1: END CONNECTIONS End must be A or B, got 'C'"),
        ("1 B Rigid 1 0 0 Rigid 0 0 1 0\n", r"line 1 End B: duplicate END CONNECTIONS row"),
        ("7 A Rigid 1 0 0 Rigid 0 0 1 0\n", r"references an undefined line 7"),
        ("0 A Rigid 1 0 0 Rigid 0 0 1 0\n", r"LineID must be positive, got 0"),
        ("x A Rigid 1 0 0 Rigid 0 0 1 0\n", r"LineID must be an integer, got 'x'"),
    ],
)
def test_end_connection_errors_name_the_line_end_and_value(row, message):
    _rejects(_edit(_TORSION, (_TORSION_ROW_A, row)), message)


_NO_TORSION_OUTPUTS_ONE_END = ("Torq1N1\nTwist1N41\nTwist1\n", "FairTen1\n")


def test_torsion_line_rules_follow_the_native_checks():
    # torsion has no EI/1.3 default: the 10-column LINE TYPES row has no GJ
    no_gj = _edit(
        _TORSION,
        (
            "Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat\n",
            "Name Diam Mass EA BA EI Cdn Cdt Can Cat\n",
        ),
        (
            "cab 0.2 32.2 1.0e7 0.0 1.0e6 1.0e8 5.0e4 1.0 1.0 0.0 0.0 0.0 0.0",
            "cab 0.2 32.2 1.0e7 0.0 1.0e6 0 0 0 0",
        ),
    )
    _rejects(no_gj, "must give an explicit GJ > 0")
    ei0 = _edit(
        _TORSION,
        ("1.0e7 0.0 1.0e6 1.0e8", "1.0e7 0.0 0.0 1.0e8"),
        ("1 A Rigid 1 0 0 Rigid", "1 A Pinned 1 0 0 Rigid"),
        ("1 B Rigid 1 0 0 Rigid", "1 B Pinned 1 0 0 Rigid"),
        ("Torq1N1\nTwist1N41\nTwist1\n", "FairTen1\n"),
    )
    _rejects(ei0, "require a finite-EI line; line 1 has EI = 0")
    # one restrained end, the other free to twist, is solved in torsion with its channels ...
    one_end = _edit(_TORSION, (_TORSION_ROW_A, "1 A Rigid 1 0 0 Free 0 0 1 0\n"))
    DeckFile.from_text(one_end)
    # ... where both-end torsion would be; otherwise it is not, and its channels are refused
    one_end_no_gj = _edit(
        one_end,
        (
            "Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat\n",
            "Name Diam Mass EA BA EI Cdn Cdt Can Cat\n",
        ),
        (
            "cab 0.2 32.2 1.0e7 0.0 1.0e6 1.0e8 5.0e4 1.0 1.0 0.0 0.0 0.0 0.0",
            "cab 0.2 32.2 1.0e7 0.0 1.0e6 0 0 0 0",
        ),
    )
    _rejects(
        one_end_no_gj, "restrained at one end only and its torsion is not solved: its LINE TYPES"
    )
    DeckFile.from_text(_edit(one_end_no_gj, ("Torq1N1\nTwist1N41\nTwist1\n", "FairTen1\n")))
    one_end_dyn = _edit(one_end, ("0.0 TMax\n", "10.0 TMax\n"))
    DeckFile.from_text(one_end_dyn)
    _rejects(
        _options(one_end_dyn, "False alpha_force_blend"),
        "torsion is not solved: torsion in a dynamic run needs the force-blended",
    )
    # the modal analysis, ATTACHMENTS and CONTROL take a line solved at one end, its channels too
    DeckFile.from_text(_options(one_end, "3 nModes"))
    DeckFile.from_text(
        _edit(
            one_end,
            (
                f"{_BAR} OPTIONS {_BAR}",
                f"{_BAR} ATTACHMENTS {_BAR}\nLineID ArcLength Mass Volume CdA Ca\n"
                f"1 50.0 10.0 0.0 0.0 0.0\n{_BAR} OPTIONS {_BAR}",
            ),
        )
    )
    DeckFile.from_text(
        _edit(
            one_end,
            (
                f"{_BAR} OPTIONS {_BAR}",
                f"{_BAR} CONTROL {_BAR}\nChannelID Line(s)\n(-) (-)\n1 1\n{_BAR} OPTIONS {_BAR}",
            ),
        ),
        caller_driven=True,
    )
    # the dynamic run needs the force blend; modal analysis carries the twist
    dynamic = _edit(_TORSION, ("0.0 TMax\n", "10.0 TMax\n"))
    DeckFile.from_text(dynamic)
    _rejects(
        _options(dynamic, "False alpha_force_blend"), "needs the force-blended generalised-alpha"
    )
    DeckFile.from_text(_options(_TORSION, "3 nModes"))
    # the coupled OpenFAST and FAST.Farm routes turn the fairlead frame with the platform and
    # accept torsion, one restrained end included; a coupled run is always dynamic, so it
    # needs the force blend whatever the deck's TMax
    DeckFile.from_text(_TORSION, caller_driven=True)
    DeckFile.from_text(
        _edit(one_end, ("Torq1N1\nTwist1N41\nTwist1\n", "FairTen1\n")), caller_driven=True
    )
    _rejects(
        _options(_TORSION, "False alpha_force_blend"),
        "needs the force-blended generalised-alpha",
        caller_driven=True,
    )
    _rejects(ei0, "require a finite-EI line; line 1 has EI = 0", caller_driven=True)


# The pure-torsion deck dynamic (TMax > 0), for the rules that need a dynamic run.
_TORSION_DYN = _edit(_TORSION, ("0.0 TMax", "1.0 TMax"))
_NO_TORSION_OUTPUTS = ("Torq1N1\nTwist1N41\nTwist1\n", "FairTen1\n")


def _torsion_body(body_row: str) -> str:
    return _edit(
        _TORSION_DYN,
        (
            f"{_BAR} POINTS {_BAR}",
            f"{_BAR} BODIES {_BAR}\n"
            "ID Type X Y Z Roll Pitch Yaw Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz\n"
            f"{body_row}\n{_BAR} POINTS {_BAR}",
        ),
        ("1 Coupled 0.0 0.0 -50.0", "1 Body1 0.0 0.0 0.0"),
    )


def _torsion_two_moving(row_a: str) -> str:
    return _edit(
        _TORSION_DYN,
        ("2 Fixed 100.0 0.0 -50.0 0 0 0 0", "2 Free 100.0 0.0 -50.0 100 0 0 0"),
        (_TORSION_ROW_A, row_a),
        ("1 B Rigid 1 0 0 Rigid", "1 B Pinned 1 0 0 Rigid"),
    )


def _one_end_rod(rod_kind: str) -> str:
    """The pure-torsion line hung from End B of a rod of the given kind along its axis (+x),
    restrained in torsion there only (End B of the line free to twist)."""
    return _edit(
        _TORSION_DYN,
        (
            f"{_BAR} POINTS {_BAR}",
            f"{_BAR} ROD TYPES {_BAR}\nName Diam Mass Cd Ca CdEnd CaEnd\n"
            "spar 1.0 300.0 0.8 1.0 0.0 0.0\n"
            f"{_BAR} RODS {_BAR}\nID RodType Type XA YA ZA XB YB ZB NumSegs Outputs\n"
            f"1 spar {rod_kind} -10 0 -50 0 0 -50 2 -\n{_BAR} POINTS {_BAR}",
        ),
        ("1 1 2 -", "1 R1B 2 -"),
        ("1 Coupled 0.0 0.0 -50.0 0 0 0 0\n", ""),
        ("1 B Rigid 1 0 0 Rigid 0 0 1 720", "1 B Rigid 1 0 0 Free 0 0 1 0"),
    )


def _torsion_between_bodies(body2_row: str, end_b: str = "2 Body2 0.0 0.0 0.0") -> str:
    """The torsional line of _TORSION_DYN between two bodies: End A on body 1, End B on body 2."""
    return _edit(
        _torsion_body(
            "1 Rigid6 0 0 -50 0 0 0 1.0e5 97.56 0 0 0 0 0 1.0e3 1.0e3 1.0e3\n" + body2_row
        ),
        ("2 Fixed 100.0 0.0 -50.0 0 0 0 0", end_b + " 0 0 0 0"),
    )


def test_torsion_between_two_bodies_follows_the_native_checks():
    # a line restrained in torsion between two Rigid6 bodies: both end frames on their bodies
    DeckFile.from_text(
        _torsion_between_bodies("2 Rigid6 100 0 -50 0 0 0 1.0e5 97.56 0 0 0 0 0 1.0e3 1.0e3 1.0e3")
    )
    # End B on a Point3 buoy or a rod end stops by name, as End A does
    _rejects(
        _torsion_between_bodies("2 Point3 100 0 -50 0 0 0 1.0e5 97.56 0 0 0 0 0"),
        "a torsional END CONNECTION on a body needs a Rigid6 body",
    )
    rod_end = _edit(
        _torsion_body("1 Rigid6 0 0 -50 0 0 0 1.0e5 97.56 0 0 0 0 0 1.0e3 1.0e3 1.0e3"),
        (
            f"{_BAR} POINTS {_BAR}",
            f"{_BAR} ROD TYPES {_BAR}\nName Diam Mass Cd Ca CdEnd CaEnd\n"
            "spar 1.0 300.0 0.8 1.0 0.0 0.0\n"
            f"{_BAR} RODS {_BAR}\nID RodType Type XA YA ZA XB YB ZB NumSegs Outputs\n"
            f"1 spar Free 100 0 -50 110 0 -50 2 -\n{_BAR} POINTS {_BAR}",
        ),
        ("2 Fixed 100.0 0.0 -50.0 0 0 0 0", "2 Rod1A 100.0 0.0 -50.0 0 0 0 0"),
    )
    _rejects(rod_end, "a torsional END CONNECTION on a rod end is not supported")


_RIGID6_B = "2 Rigid6 100 0 -50 0 0 0 1.0e5 97.56 0 0 0 0 0 1.0e3 1.0e3 1.0e3"


def test_multibody_cable_ends_follow_the_native_march_checks():
    # End B on a Free/Connect point, a Point3 buoy or a Coupled point stops by name on the march
    for end_b, message in [
        ("2 Free 100.0 0.0 -50.0", "a cable end on a Free/Connect point or a Point3 buoy"),
        ("2 Coupled 100.0 0.0 -50.0", "a Coupled/Vessel End B"),
    ]:
        pinned = _edit(
            _torsion_between_bodies(_RIGID6_B, end_b),
            (_TORSION_ROW_A, "1 A Pinned 1 0 0\n"),
            ("1 B Rigid 1 0 0 Rigid 0 0 1 720", "1 B Pinned 1 0 0"),
            _NO_TORSION_OUTPUTS,
        )
        _rejects(pinned, message)
    _rejects(
        _torsion_between_bodies("2 Point3 100 0 -50 0 0 0 1.0e5 97.56 0 0 0 0 0"),
        "a torsional END CONNECTION on a body needs a Rigid6 body",
    )
    # a connected or torsional end on a body needs the monolithic scheme, at either end: a
    # torsion frame at a bending-pinned End A included
    staggered = ("0.1 dtM\n", "0.1 dtM\nstaggered bodyScheme\n")
    DeckFile.from_text(_torsion_between_bodies(_RIGID6_B))
    _rejects(_edit(_torsion_between_bodies(_RIGID6_B), staggered), "needs bodyScheme monolithic")
    torsion_pinned_a = _edit(
        _torsion_body("1 Rigid6 0 0 -50 0 0 0 1.0e5 97.56 0 0 0 0 0 1.0e3 1.0e3 1.0e3"),
        (_TORSION_ROW_A, "1 A Pinned 1 0 0 Rigid 0 0 1 0\n"),
    )
    DeckFile.from_text(torsion_pinned_a)
    _rejects(_edit(torsion_pinned_a, staggered), "needs bodyScheme monolithic")


def test_torsion_scope_rules_follow_the_native_checks():
    # End A on a Rigid6 body is supported, on a Point3 body or a rod end it stops by name
    DeckFile.from_text(
        _torsion_body("1 Rigid6 0 0 -50 0 0 0 1.0e5 97.56 0 0 0 0 0 1.0e3 1.0e3 1.0e3")
    )
    _rejects(
        _torsion_body("1 Point3 0 0 -50 0 0 0 1.0e5 97.56 0 0 0 0 0"),
        "a torsional END CONNECTION on a body needs a Rigid6 body",
    )
    rod_end = _edit(
        _TORSION_DYN,
        (
            f"{_BAR} POINTS {_BAR}",
            f"{_BAR} ROD TYPES {_BAR}\nName Diam Mass Cd Ca CdEnd CaEnd\n"
            "spar 1.0 300.0 0.8 1.0 0.0 0.0\n"
            f"{_BAR} RODS {_BAR}\nID RodType Type XA YA ZA XB YB ZB NumSegs Outputs\n"
            f"1 spar Fixed 0 0 -50 0 0 -40 2 -\n{_BAR} POINTS {_BAR}",
        ),
        ("1 1 2 -", "1 R1A 2 -"),
        ("1 Coupled 0.0 0.0 -50.0 0 0 0 0\n", ""),
    )
    # a Fixed rod holds the End A torsion frame still; a free or pinned rod has no roll angle,
    # and a Coupled rod carries no finite-EI line on any route
    DeckFile.from_text(rod_end)
    axisymmetric = "is not supported: a free or pinned rod is axisymmetric, with no roll about"
    _rejects(
        _edit(rod_end, ("1 spar Fixed", "1 spar Pinned")),
        rf"line 1: a torsional END CONNECTION on the end of ROD 1 \(pinned\) {axisymmetric}",
    )
    _rejects(
        _edit(rod_end, ("1 spar Fixed", "1 spar Free")),
        rf"on the end of ROD 1 \(free\) {axisymmetric}",
    )
    _rejects(
        _edit(
            rod_end,
            (
                f"{_BAR} ROD TYPES {_BAR}",
                f"{_BAR} BODIES {_BAR}\n"
                "ID Type X Y Z Roll Pitch Yaw Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz\n"
                "1 Rigid6 0 0 -30 0 0 0 1.0e5 97.56 0 0 0 0 0 1.0e3 1.0e3 1.0e3\n"
                f"{_BAR} ROD TYPES {_BAR}",
            ),
            ("1 spar Fixed 0 0 -50 0 0 -40", "1 spar Body1Pin 0 0 -20 0 0 -10"),
        ),
        rf"on the end of ROD 1 \(body1pinned\) {axisymmetric}",
    )
    # written anchor first (MoorDyn's order) the finite-EI line is turned around, onto the Fixed
    # rod as onto a pinned one; a line between two rods ends on a rod end
    anchor_first = _edit(rod_end, ("1 R1A 2 -", "1 2 R1A -"))
    DeckFile.from_text(anchor_first)
    _rejects(
        _edit(anchor_first, ("1 spar Fixed", "1 spar Pinned")),
        rf"on the end of ROD 1 \(pinned\) {axisymmetric}",
    )
    _rejects(
        _edit(
            rod_end,
            (
                "1 spar Fixed 0 0 -50 0 0 -40 2 -\n",
                "1 spar Fixed 0 0 -50 0 0 -40 2 -\n2 spar Fixed 100 0 -50 100 0 -60 2 -\n",
            ),
            ("1 R1A 2 -", "1 R1A R2A -"),
        ),
        # a line between two rods takes its bending connections (a line between two objects);
        # its torsion at the End B rod end stops
        "line 1: a torsional END CONNECTION on a rod end is not supported at End B",
    )
    _rejects(
        _options(_edit(rod_end, ("1 spar Fixed", "1 spar Coupled")), "rod.motion motionFile"),
        "a torsional END CONNECTION on the end of Coupled/Vessel ROD 1 is not supported: no route "
        "of this build carries a finite-EI line on a host-driven rod",
    )
    # restrained at the rod end only (End B free to twist): solved on a Fixed rod, noted on a
    # pinned one, whose twist channels are then refused with the reason
    DeckFile.from_text(_one_end_rod("Fixed"))
    _rejects(
        _one_end_rod("Pinned"),
        "its torsion is not solved: its restrained End A is on the end of a free or pinned rod",
    )
    DeckFile.from_text(_edit(_one_end_rod("Pinned"), _NO_TORSION_OUTPUTS))
    attachments = _edit(
        _TORSION,
        (
            f"{_BAR} OPTIONS {_BAR}",
            f"{_BAR} ATTACHMENTS {_BAR}\nLineID ArcLength Mass Volume CdA Ca\n"
            f"1 50.0 10.0 0.0 0.0 0.0\n{_BAR} OPTIONS {_BAR}",
        ),
    )
    DeckFile.from_text(attachments)  # a torsional line with ATTACHMENTS is accepted
    # restrained at both ends, End B must hold its frame: Fixed, Coupled/Vessel (driven) or a
    # Rigid6 body point (a line between two objects)
    _rejects(
        _torsion_two_moving("1 A Pinned 1 0 0 Rigid 0 0 1 0\n"),
        "torsional END CONNECTIONS need End B on a Fixed, Coupled or Vessel point or a Rigid6 body "
        'point; line 1 ends on a "free" point',
    )
    # one restrained end only, or none, is ignored: the same verdict as the six-column rows (here
    # the multibody march's, which ends no finite-EI cable on a Free point)
    one_end = _edit(_torsion_two_moving("1 A Pinned 1 0 0 Free 0 0 1 0\n"), _NO_TORSION_OUTPUTS)
    six = _edit(
        _torsion_two_moving("1 A Pinned 1 0 0\n"),
        ("1 B Pinned 1 0 0 Rigid 0 0 1 720", "1 B Pinned 1 0 0"),
        _NO_TORSION_OUTPUTS,
    )
    for deck in (six, one_end):
        _rejects(deck, "a cable end on a Free/Connect point or a Point3 buoy")
    both_free = _edit(
        _TORSION,
        (_TORSION_ROW_A, "1 A Rigid 1 0 0 Free 0 0 1 0\n"),
        ("1 B Rigid 1 0 0 Rigid 0 0 1 720", "1 B Rigid 1 0 0 Free 0 0 1 720"),
    )
    _rejects(both_free, "is not torsionally restrained \\(END CONNECTIONS")
    DeckFile.from_text(_edit(both_free, _NO_TORSION_OUTPUTS))


def test_torsion_on_a_standalone_mixed_deck_is_accepted():
    # a mixed EI = 0 + finite-EI deck without bodies runs on the aggregate, whose driver holds the
    # line end frames or turns them with the deck's vesselMotion and rolls them with the
    # motionFile roll column (test_mixed_route_torsion)
    gj_cable = _edit(
        _MIXED,
        (
            "Name Diam Mass EA BA EI Cdn Cdt Can Cat\n",
            "Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat\n",
        ),
        (
            "chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0\n",
            "chain 0.252 390.0 1.674e9 -1.0 0.0 0 0 0 0 1.37 0.64 1.0 0.0\n",
        ),
        (
            "cable 0.2 60.0 4.0e8 0.0 1.0e4 1.2 0.1 1.0 0.0\n",
            "cable 0.2 60.0 4.0e8 0.0 1.0e4 1.0e8 1.0e4 1.0 1.0 1.2 0.1 1.0 0.0\n",
        ),
    )
    DeckFile.from_text(gj_cable)
    for rows in (
        ("2 A Rigid -1 0 0 Rigid 0 0 1 0", "2 B Rigid -1 0 0 Rigid 0 0 1 90"),
        ("2 A Rigid -1 0 0 Rigid 0 0 1 0", "2 B Rigid -1 0 0 Free 0 0 1 0"),
    ):
        text = _section(
            gj_cable,
            "END CONNECTIONS",
            "LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist",
            *rows,
        )
        DeckFile.from_text(text)
        DeckFile.from_text(_edit(text, ("10.0 TMax\n", "0.0 TMax\n")))
        DeckFile.from_text(_options(text, "m.txt motionFile"))
        DeckFile.from_text(_options(text, "v.txt vesselMotion", "0|0|0 vesselRef"))
        # a static run (TMax = 0) marches no step and takes the configuration blend, as native
        # CD_Init_Deck_Aggregate with static_run (test_mixed_route_torsion gate 6)
        DeckFile.from_text(
            _options(_edit(text, ("10.0 TMax\n", "0.0 TMax\n")), "False alpha_force_blend")
        )
        if "Free" not in rows[1]:
            # restrained at both ends, the dynamic run needs the force blend, as on every route
            _rejects(
                _options(text, "False alpha_force_blend"),
                "needs the force-blended generalised-alpha",
            )


@pytest.mark.parametrize(
    ("stiffness", "accepted"),
    [
        ("Inf", True),
        ("Infinity", True),
        ("RIGID", True),
        ('"Rigid"', True),
        ("Zero", True),
        ("-0", True),
        ("2.5d4", True),
        ("+Inf", False),
        ("1e-320", False),
        ("1.0q5", False),
        ("Pinned", False),
    ],
)
def test_torsion_stiffness_keywords_and_numbers_follow_the_native_reader(stiffness, accepted):
    text = _edit(_TORSION, (_TORSION_ROW_A, f"1 A Rigid 1 0 0 {stiffness} 0 1 1 -45\n"))
    if stiffness.lower() in {"zero", "-0"}:
        text = _edit(text, _NO_TORSION_OUTPUTS)
    if accepted:
        DeckFile.from_text(text)
    else:
        _rejects(text, "torsional stiffness must be finite and non-negative, Free, or Rigid")


@pytest.mark.parametrize("stiffness", ["1.0q5", "1e-320", "+Inf", "NaN"])
def test_bending_stiffness_numbers_follow_the_native_reader(stiffness):
    _rejects(
        _edit(_TORSION, (_TORSION_ROW_A, f"1 A {stiffness} 1 0 0 Rigid 0 1 1 -45\n")),
        "END CONNECTIONS stiffness must be finite and non-negative, Pinned, or Rigid",
    )


def test_builders_write_or_refuse_the_torsion_columns():
    from cabledyn.deck import DeckWriter

    # DeckModel writes a 10-column row (no pretwist) that reads back the same
    model = DeckModel.from_text(_edit(_TORSION, (_TORSION_ROW_A, ""), _NO_TORSION_OUTPUTS))
    model.add_end_connection(
        1, "A", "Rigid", (1.0, 0.0, 0.0), torsion_stiffness=2.5e4, normal=(0, 1, 1)
    )
    text = model.to_text()
    row = next(r for r in DeckFile.from_text(text).end_connections if r.tokens[1] == "A")
    assert len(row.tokens) == 10 and float(row.tokens[6]) == 2.5e4
    # DeckFile edits the torsion columns of a row in place, keywords unquoted
    deck = DeckFile.from_text(_TORSION)
    deck.set_end_connection(1, "B", torsstiffness="Infinity", pretwist=90.0)
    row_b = next(r for r in deck.end_connections if r.tokens[1] == "B")
    assert row_b.tokens[6] == "Infinity" and float(row_b.tokens[10]) == 90.0
    # the simple writer has no torsion columns and says so
    with pytest.raises(ValueError, match="no torsion columns"):
        DeckWriter().add_end_connection(1, "A", "Rigid", (1.0, 0.0, 0.0), torsion_stiffness="Rigid")


def test_a_free_torsion_end_takes_any_reference_normal():
    for normal in ("0 0 0", "1 0 0"):
        DeckFile.from_text(
            _edit(
                _TORSION,
                (_TORSION_ROW_A, f"1 A Rigid 1 0 0 Free {normal} 0\n"),
                _NO_TORSION_OUTPUTS,
            )
        )


@pytest.mark.parametrize("pretwist", ["-360001", "1e8", "-1e300"])
def test_static_twist_above_1000_turns_is_refused_by_name(pretwist):
    text = _edit(_TORSION, (_TORSION_ROW_A, f"1 A Rigid 1 0 0 Rigid 0 0 1 {pretwist}\n"))
    with pytest.raises(DeckFormatError, match=r"line 1: the imposed twist .* exceeds 1000 turns"):
        DeckFile.from_text(text)


def test_static_twist_of_1000_turns_is_accepted():
    text = _edit(_TORSION, (_TORSION_ROW_A, "1 A Rigid 1 0 0 Rigid 0 0 1 -359000\n"))
    DeckFile.from_text(text)


_PARITY_DRIVER = (
    os.environ.get("CABLEDYN_TEST_DRIVER", "").strip()
    or os.environ.get("CABLEDYN_DRIVER", "").strip()
)


@pytest.mark.skipif(
    not _PARITY_DRIVER or not Path(_PARITY_DRIVER).is_file(),
    reason="set CABLEDYN_TEST_DRIVER to a built native driver to run the native torsion parity",
)
@pytest.mark.parametrize(
    "row_a",
    [
        "1 A Rigid 1 0 0 Inf 0 1 1 -45",
        "1 A Rigid 1 0 0 Infinity 0 1 1 -45",
        '1 A Rigid 1 0 0 "Rigid" 0 1 1 -45',
        "1 A Rigid 1 0 0 +Inf 0 1 1 -45",
        "1 A Rigid 1 0 0 1e-320 0 1 1 -45",
        "1 A Rigid 1 0 0 1.0q5 0 1 1 -45",
        "1 A 1.0q5 1 0 0 Rigid 0 1 1 -45",
        "1 A Rigid 1 0 0 Rigid 0 0 1",
        "1 A Rigid 1 0 0 Pinned 0 0 1 0",
        "1 A Rigid 1 0 0 Zero 0 0 1 0",
        "1 A Rigid 1 0 0 2.5d4 +0 .5 1 1d2",
        "1 A Rigid 1 0 0 Rigid 0 0 0 0",
        "1 A Rigid 1 0 0 Rigid 1 0 0.0009 0",
        "1 A Rigid 1 0 0 Rigid 1 0 0.0011 0",
        "1 A Rigid 1 0 0 Rigid 0 0 1 nan",
        "1 A Rigid 1 0 0 Rigid 0 0 1 1e400",
        "1 A Rigid 1 0 0 Rigid 0 0 1 -360001",
        "1 A Rigid 1 0 0 Rigid 0 0 1 1e8",
        "1 A Rigid 1 0 0 Free 0 0 0 0",
        "1 A Rigid 1 0 0 Free 1 0 0 -7200",
        "1 A Rigid 1 0 0 Free 0 nan 1 0",
        "1 A Rigid 1 0 0 Free 0 0 1 inf",
    ],
)
def test_torsion_rows_get_the_native_verdict(row_a, tmp_path):
    text = _edit(_TORSION, (_TORSION_ROW_A, f"{row_a}\n"))
    if row_a.split()[6].lower() in {"free", "zero"}:
        # a Free End A: judge the row (its normal and pretwist), not the torsion channels
        text = _edit(text, _NO_TORSION_OUTPUTS)
    try:
        DeckFile.from_text(text)
        python_accepts = True
    except DeckFormatError:
        python_accepts = False
    deck = tmp_path / "torsion.dat"
    deck.write_text(text, encoding="utf-8")
    completed = subprocess.run(
        [_PARITY_DRIVER, str(deck), str(tmp_path / "torsion")],
        capture_output=True,
        text=True,
        cwd=tmp_path,
        timeout=600,
        check=False,
    )
    # exit code 1 is an input refusal; 0 a run and 2 a solve failure after validation
    assert python_accepts == (completed.returncode != 1), completed.stdout + completed.stderr


def _native_exit(text: str, tmp_path: Path) -> int:
    deck = tmp_path / "torsion.dat"
    deck.write_text(text, encoding="utf-8")
    completed = subprocess.run(
        [_PARITY_DRIVER, str(deck), str(tmp_path / "torsion")],
        capture_output=True,
        text=True,
        cwd=tmp_path,
        timeout=600,
        check=False,
    )
    return completed.returncode


@pytest.mark.skipif(
    not _PARITY_DRIVER or not Path(_PARITY_DRIVER).is_file(),
    reason="set CABLEDYN_TEST_DRIVER to a built native driver to run the native torsion parity",
)
@pytest.mark.parametrize(
    "channel",
    [
        "TWIST01",
        "torq01n041",
        "Twist1N41",
        "Twist1N42",
        "Torq1N0",
        "Twist1N0",
        "Torq1",
        "Twist",
        "Twist1N",
        "Torq1N1x",
        "Twist1x",
        "Twist2",
    ],
)
def test_torsion_channels_get_the_native_verdict(channel, tmp_path):
    text = _edit(_TORSION, ("Twist1\n", f"{channel}\n"))
    try:
        DeckFile.from_text(text)
        python_accepts = True
    except DeckFormatError:
        python_accepts = False
    # exit code 1 is an input refusal; 0 a run and 2 a solve failure after validation
    assert python_accepts == (_native_exit(text, tmp_path) != 1)


def _stock_body(body_row: str, row_a: str, row_b: str) -> str:
    """A line written anchor first (NodeA the Fixed anchor, NodeB on body 1), which the reader
    turns around: its deck End B becomes End A."""
    return f"""{_BAR} CableDyn Input File {_BAR}
in-memory fixture: an anchor-first line restrained in torsion at one end
{_BAR} LINE TYPES {_BAR}
Name Diam Mass EA BA EI GAs GJ Irt Irn Cdn Cdt Can Cat
cab 0.2 32.2 1.0e7 0.0 1.0e6 1.0e8 5.0e4 1.0 1.0 0.0 0.0 0.0 0.0
{_BAR} BODIES {_BAR}
ID Type X Y Z Roll Pitch Yaw Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz
{body_row}
{_BAR} POINTS {_BAR}
ID Type X Y Z Mass Vol CdA Ca
1 Body1 0.0 0.0 0.0 0 0 0 0
2 Fixed 100.0 0.0 -50.0 0 0 0 0
{_BAR} LINES {_BAR}
ID NodeA NodeB Outputs
1 2 1 -
{_BAR} SECTIONS {_BAR}
LineID LineType Length NumSegs
1 cab 100.0 40
{_BAR} END CONNECTIONS {_BAR}
LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist
{row_a}
{row_b}
{_BAR} OPTIONS {_BAR}
9.80665 g
1025.0 rhoW
50.0 WtrDpth
0.1 dtM
1.0 TMax
{_BAR} OUTPUTS {_BAR}
FairTen1
Twist1
{_BAR} need this line {_BAR}
"""


# restrained at the deck's End B, the body, which the anchor-first swap makes End A
_STOCK_POINT3_AT_BODY = _stock_body(
    "1 Point3 0 0 -50 0 0 0 1.0e5 97.56 0 0 0 0 0",
    "1 A Rigid -1 0 0 Free 0 0 1 0",
    "1 B Rigid -1 0 0 Rigid 0 0 1 0",
)
_STOCK_RIGID6_AT_BODY = _stock_body(
    "1 Rigid6 0 0 -50 0 0 0 1.0e5 97.56 0 0 0 0 0 1.0e3 1.0e3 1.0e3",
    "1 A Rigid -1 0 0 Free 0 0 1 0",
    "1 B Rigid -1 0 0 Rigid 0 0 1 0",
)


def test_one_end_torsion_follows_the_anchor_first_swap():
    # a Point3 body does not carry torsion: the line restrained there is not solved, and its
    # twist channel is refused; on a Rigid6 body it is solved
    _rejects(_STOCK_POINT3_AT_BODY, "its restrained End A is on a body that is not Rigid6")
    DeckFile.from_text(_STOCK_RIGID6_AT_BODY)


def test_one_end_pretwist_stays_within_1000_turns():
    one_end = _edit(
        _TORSION,
        (_TORSION_ROW_A, "1 A Rigid 1 0 0 Free 0 0 1 0\n"),
        ("1 B Rigid 1 0 0 Rigid 0 0 1 720", "1 B Rigid 1 0 0 Rigid 0 0 1 1e8"),
    )
    _rejects(one_end, "the Pretwist of its restrained End B = 1.00000e\\+08 deg exceeds 1000 turns")
    # the free end's pretwist rolls nothing and is not checked
    DeckFile.from_text(_edit(_TORSION, (_TORSION_ROW_A, "1 A Rigid 1 0 0 Free 0 0 1 1e8\n")))


@pytest.mark.skipif(
    not _PARITY_DRIVER or not Path(_PARITY_DRIVER).is_file(),
    reason="set CABLEDYN_TEST_DRIVER to a built native driver to run the native torsion parity",
)
@pytest.mark.parametrize(
    "text",
    [
        _STOCK_POINT3_AT_BODY,
        _STOCK_RIGID6_AT_BODY,
        _edit(
            _TORSION,
            (_TORSION_ROW_A, "1 A Rigid 1 0 0 Free 0 0 1 0\n"),
            ("1 B Rigid 1 0 0 Rigid 0 0 1 720", "1 B Rigid 1 0 0 Rigid 0 0 1 1e8"),
        ),
        _options(_edit(_TORSION, (_TORSION_ROW_A, "1 A Rigid 1 0 0 Free 0 0 1 0\n")), "3 nModes"),
        _edit(
            _TORSION,
            (_TORSION_ROW_A, "1 A Rigid 1 0 0 Free 0 0 1 0\n"),
            (
                f"{_BAR} OPTIONS {_BAR}",
                f"{_BAR} ATTACHMENTS {_BAR}\nLineID ArcLength Mass Volume CdA Ca\n"
                f"1 50.0 10.0 0.0 0.0 0.0\n{_BAR} OPTIONS {_BAR}",
            ),
        ),
        _one_end_rod("Fixed"),
        _one_end_rod("Pinned"),
    ],
    ids=[
        "stock-point3-body",
        "stock-rigid6-body",
        "one-end-huge-pretwist",
        "one-end-nmodes",
        "one-end-attachments",
        "one-end-fixed-rod",
        "one-end-pinned-rod",
    ],
)
def test_one_end_torsion_gets_the_native_verdict(text, tmp_path):
    try:
        DeckFile.from_text(text)
        python_accepts = True
    except DeckFormatError:
        python_accepts = False
    # exit code 1 is an input refusal; 0 a run and 2 a solve failure after validation
    assert python_accepts == (_native_exit(text, tmp_path) != 1)


@pytest.mark.parametrize(
    ("channel", "message"),
    [
        ("Torq1N42", "node exceeds the line node count"),
        ("Torq1N0", "node numbers start at 1"),
        ("Torq2N1", "bad torsion channel"),
        ("Twist0", "bad torsion channel"),
        ("TwistN1", "bad torsion channel"),
    ],
)
def test_torsion_channels_follow_the_native_rules(channel, message):
    _rejects(_edit(_TORSION, ("Twist1\n", f"Twist1\n{channel}\n")), message)


def test_torsion_channels_are_one_identity_per_quantity():
    _rejects(_edit(_TORSION, ("Twist1\n", "Twist1\nTORQ01N1\n")), "duplicate")
    DeckFile.from_text(_edit(_TORSION, ("Twist1\n", "Twist1\nTwist1N1\nTorq1N41\n")))


def test_model_round_trips_the_torsion_columns():
    model = DeckModel.from_text(_TORSION)
    row_a, row_b = model.end_connections
    assert (row_a.torsion_stiffness, row_a.normal, row_a.pretwist) == (
        "Rigid",
        (0.0, 0.0, 1.0),
        0.0,
    )
    assert row_b.pretwist == 720.0
    text = model.to_text()
    assert "TorsStiffness" in text and "Pretwist" in text
    again = DeckModel.from_text(text)
    assert [(r.torsion_stiffness, r.normal, r.pretwist) for r in again.end_connections] == [
        (r.torsion_stiffness, r.normal, r.pretwist) for r in model.end_connections
    ]
    DeckFile.from_text(text)
    # a six-column row keeps six columns; the builder checks the torsion arguments
    plain = DeckModel.from_text(
        _edit(
            _TORSION,
            (_TORSION_ROW_A, "1 A Rigid 1 0 0\n"),
            ("1 B Rigid 1 0 0 Rigid 0 0 1 720\n", ""),
            ("Torq1N1\nTwist1N41\nTwist1\n", "FairTen1\n"),
        )
    )
    assert "TorsStiffness" not in plain.to_text()
    with pytest.raises(ValueError, match="must be given together"):
        plain.add_end_connection(1, "B", "Rigid", (1.0, 0.0, 0.0), torsion_stiffness="Rigid")
    with pytest.raises(ValueError, match="pretwist needs"):
        plain.add_end_connection(1, "B", "Rigid", (1.0, 0.0, 0.0), pretwist=10.0)
    with pytest.raises(ValueError, match="normal must be three numbers"):
        plain.add_end_connection(
            1, "B", "Rigid", (1.0, 0.0, 0.0), torsion_stiffness=1.0e4, normal=(0.0, 1.0)
        )
    added = plain.add_end_connection(
        1,
        "B",
        "Rigid",
        (1.0, 0.0, 0.0),
        torsion_stiffness=1.0e4,
        normal=(0.0, 0.0, 1.0),
        pretwist=90.0,
    )
    assert added.torsion_stiffness == 1.0e4
    assert "TorsStiffness" in plain.to_text()


# MoorDyn-C current files of the mixed-route parity decks (written beside the deck)
_MIXED_CURRENT_FILES = {
    1: ("current_profile.txt", "steady\nz ux uy uz\n-50.0 0.1 0.05 0.0\n0.0 0.4 0.2 0.0\n"),
    2: (
        "current_profile_dynamic.txt",
        "dynamic\n\n\n\n-50.0 0.0\nt ux... uy...\n0.0 0.1 0.3 0.0 0.1\n1.0 0.2 0.4 0.05 0.15\n",
    ),
    5: (
        "current_profile_4d.txt",
        "2 2 2 2\n-500.0 500.0\n-50.0 50.0\n-60.0 0.0\n0.0 1.0\nx y z t ux uy uz\n"
        + "".join(
            f"{x} {y} {z} {t} {0.1 + 0.1 * t} 0.05 0.0\n"
            for t in (0.0, 1.0)
            for z in (-60.0, 0.0)
            for y in (-50.0, 50.0)
            for x in (-500.0, 500.0)
        ),
    ),
}


@pytest.mark.skipif(
    not _PARITY_DRIVER or not Path(_PARITY_DRIVER).is_file(),
    reason="set CABLEDYN_TEST_DRIVER to a built native driver to run the native mixed-route parity",
)
@pytest.mark.parametrize(
    "rows",
    [
        ("uniform 0.5 0 0 current",),
        ("profile -50 0.1 0 0 0 0.5 0.2 0 current",),
        ("1 Currents",),
        ("2 Currents",),
        ("5 Currents",),
        ("2 Currents", "uniform 0.5 0 0 current"),
        ("3 Currents",),
        ("airy 2 8 0 waves",),
        ("7 WaveKin",),
        ("no dtM", "uniform 0.5 0 0 current"),
    ],
)
def test_mixed_route_currents_get_the_native_verdict(rows, tmp_path):
    # the deck currents of the single-line routes run on the mixed route too; deck waves do not
    text = _edit(_MIXED, ("0.1 dtM\n10.0 TMax\n", "0.1 dtM\n0.2 TMax\n"))
    if rows[0] == "no dtM":
        text = _edit(text, ("0.1 dtM\n0.2 TMax\n", ""))
        rows = rows[1:]
    text = _options(text, *rows)
    for row in rows:
        if row.endswith("Currents") and int(row.split()[0]) in _MIXED_CURRENT_FILES:
            name, content = _MIXED_CURRENT_FILES[int(row.split()[0])]
            (tmp_path / name).write_text(content, encoding="utf-8")
    try:
        DeckFile.from_text(text)
        python_accepts = True
    except DeckFormatError:
        python_accepts = False
    deck = tmp_path / "mixed.dat"
    deck.write_text(text, encoding="utf-8")
    completed = subprocess.run(
        [_PARITY_DRIVER, str(deck), str(tmp_path / "mixed")],
        capture_output=True,
        text=True,
        cwd=tmp_path,
        timeout=600,
        check=False,
    )
    # exit code 1 is an input refusal; 0 a run and 2 a solve failure after validation
    assert python_accepts == (completed.returncode != 1), completed.stdout + completed.stderr
    if python_accepts:
        assert "mixed standalone aggregate" in completed.stdout, completed.stdout


# A static check: TMax = 0 and no dtM.
_CHECK = _edit(_HELD, ("0.1 dtM\n10.0 TMax\n", "0.0 TMax\n"))
_CHECK_MIXED = _edit(_MIXED, ("0.1 dtM\n10.0 TMax\n", "0.0 TMax\n"))
_CHECK_FINITE = _edit(
    _CHECK, ("chain 0.252 390.0 1.674e9 -1.0 0.0 ", "chain 0.252 390.0 1.674e9 -1.0 1.0e6 ")
)


@pytest.mark.parametrize(
    "rows",
    [
        (),
        ("uniform 1 0 0 current",),
        ("airy 2 8 0 waves",),
        ("0.3 frictionMu",),
        ("m.txt motionFile",),
        ("v.txt vesselMotion", "0|0|0 vesselRef"),
    ],
)
def test_static_check_needs_no_dtm(rows):
    DeckFile.from_text(_options(_CHECK, *rows))
    DeckFile.from_text(_options(_CHECK_FINITE, *rows))
    if "airy 2 8 0 waves" not in rows:
        DeckFile.from_text(_options(_CHECK_MIXED, *rows))


def test_static_check_takes_a_negative_zero_tmax_and_no_other():
    DeckFile.from_text(_edit(_CHECK, ("0.0 TMax", "-0.0 TMax")))
    _rejects(_edit(_CHECK, ("0.0 TMax", "1.0e-9 TMax")), "dynamic run requires both dtM and TMax")
    _rejects(_edit(_CHECK, ("0.0 TMax", "10.0 TMax")), "dynamic run requires both dtM and TMax")


def test_static_check_leaves_the_host_clock_rules_alone():
    # a host marches a caller-driven deck: its TMax says nothing about the deck-owned kinematics
    DeckFile.from_text(_CHECK, caller_driven=True)
    _rejects(_options(_CHECK, "airy 2 8 0 waves"), "waves requires dtM", caller_driven=True)
    _rejects(_options(_CHECK, "m.txt motionFile"), "motionFile requires dtM", caller_driven=True)


def test_a_lone_dtm_says_how_to_check_the_static_start():
    _rejects(_edit(_HELD, ("10.0 TMax\n", "")), "requires both dtM and TMax.*give TMax = 0")


@pytest.mark.skipif(
    not _PARITY_DRIVER or not Path(_PARITY_DRIVER).is_file(),
    reason="set CABLEDYN_TEST_DRIVER to a built native driver to run the native clock parity",
)
@pytest.mark.parametrize(
    ("text", "accepted"),
    [
        (_CHECK, True),
        (_options(_CHECK, "uniform 1 0 0 current"), True),
        (_options(_CHECK, "airy 2 8 0 waves"), True),
        (_options(_CHECK, "0.3 frictionMu"), True),
        (_CHECK_FINITE, True),
        (_options(_CHECK_FINITE, "uniform 1 0 0 current"), True),
        (_CHECK_MIXED, True),
        (_options(_CHECK_MIXED, "uniform 0.5 0 0 current"), True),
        (_edit(_CHECK, ("0.0 TMax", "-0.0 TMax")), True),
        (_edit(_CHECK, ("0.0 TMax", "1.0 TMax")), False),
        (_edit(_CHECK_MIXED, ("0.0 TMax", "1.0 TMax")), False),
        (_edit(_HELD, ("10.0 TMax\n", "")), False),
    ],
)
def test_static_check_clock_gets_the_native_verdict(text, accepted, tmp_path):
    try:
        DeckFile.from_text(text)
        python_accepts = True
    except DeckFormatError:
        python_accepts = False
    deck = tmp_path / "check.dat"
    deck.write_text(text, encoding="utf-8")
    completed = subprocess.run(
        [_PARITY_DRIVER, str(deck), str(tmp_path / "check")],
        capture_output=True,
        text=True,
        cwd=tmp_path,
        timeout=600,
        check=False,
    )
    assert python_accepts == accepted
    assert (completed.returncode == 0) == accepted, completed.stdout + completed.stderr


# --------------------------------------------------------------- deck rules of the native routes

_STIFF = "stiff 0.252 390.0 1.674e9 -1.0 1.0e4 1.37 0.64 1.0 0.0\n"
_CHAIN_TYPE = "chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0\n"
# _HELD with a second (finite-EI) line type and its line 1 split between both types
_SPLIT_LINE = _edit(
    _HELD,
    (_CHAIN_TYPE, _CHAIN_TYPE + _STIFF),
    ("1 chain 410.0 41\n", "1 chain 200.0 20\n1 stiff 210.0 21\n"),
)
# ... and a second, EI=0 line beside it (the standalone mixed route)
_SPLIT_LINE_AND_CHAIN = _edit(
    _SPLIT_LINE,
    (
        "2 Coupled 0.0 0.0 0.0 0 0 0 0\n",
        "2 Coupled 0.0 0.0 0.0 0 0 0 0\n3 Fixed -400.0 0.0 -50.0 0 0 0 0\n",
    ),
    ("1 2 1 -\n", "1 2 1 -\n2 2 3 -\n"),
    ("1 stiff 210.0 21\n", "1 stiff 210.0 21\n2 chain 410.0 41\n"),
)
# a finite-EI line on its own
_FINITE = _edit(_HELD, (_CHAIN_TYPE, _CHAIN_TYPE.replace(" 0.0 1.37", " 1.0e4 1.37")))
# a finite-EI line from Coupled point 2 beside an EI=0 line from Coupled point 4 (the mixed route)
_FINITE_AND_CHAIN = _edit(
    _HELD,
    (_CHAIN_TYPE, _CHAIN_TYPE + _STIFF),
    (
        "2 Coupled 0.0 0.0 0.0 0 0 0 0\n",
        "2 Coupled 0.0 0.0 0.0 0 0 0 0\n"
        "3 Fixed -400.0 0.0 -50.0 0 0 0 0\n4 Coupled -10.0 0.0 0.0 0 0 0 0\n",
    ),
    ("1 2 1 -\n", "1 2 1 -\n2 4 3 -\n"),
    ("1 chain 410.0 41\n", "1 stiff 410.0 41\n2 chain 410.0 41\n"),
)
# the submerged Rigid6 buoy of the examples with finite-EI legs (the standalone multibody march)
_BUOY_FINITE_LEGS = _example(
    "rigid6_buoy.dat",
    ("5.0e7      -1.0       0.0 ", "5.0e7      -1.0       1.0e3 "),
    ("60.0                 TMax", "0.04                 TMax"),
)
_BUOY_FORCES = _edit(
    _BUOY_FINITE_LEGS,
    ('"Point1px"\n"Point1pz"\n"Point2pz"\n"Point3pz"\n', '"Point1Fx"\n"Point2Fz"\n'),
)


_NO_SEABED_TDP = _edit(_STATIC, ("50.0 WtrDpth\n", ""), ("FairTen1\n", "FairTen1\nTDP1s\n"))
_FINITE_POINT_POSITIONS = _edit(_FINITE, ("FairTen1\n", "FairTen1\nPoint2px\nPoint1pz\nPoint2Fz\n"))
_MIXED_CABLE_POINT = _edit(_FINITE_AND_CHAIN, ("FairTen1\n", "FairTen1\nPoint2px\n"))
_MIXED_CHAIN_POINT = _edit(_FINITE_AND_CHAIN, ("FairTen1\n", "FairTen1\nPoint4px\nPoint2Fz\n"))
# (name, deck, caller_driven, message): None accepts
_ROUTE_RULE_CASES = [
    # TDP<L> channels need a seabed on the standalone routes (a host gives the depth)
    ("tdp-no-seabed", _NO_SEABED_TDP, False, r"TDP channels of line 1 need a seabed"),
    ("tdp-no-seabed-host", _NO_SEABED_TDP, True, None),
    ("tdp-seabed", _edit(_STATIC, ("FairTen1\n", "FairTen1\nTDP1s\n")), False, None),
    # a finite-EI line needs mass, on every route
    ("finite-mass-0", _edit(_FINITE, (" 390.0 ", " 0 ")), False, r"MassDenInAir must be > 0"),
    ("finite-mass-neg", _edit(_FINITE, (" 390.0 ", " -1 ")), False, r"MassDenInAir must be > 0"),
    (
        "finite-mass-neg-host",
        _edit(_FINITE, (" 390.0 ", " -1 ")),
        True,
        r"MassDenInAir must be > 0",
    ),
    ("finite-mass-small", _edit(_FINITE, (" 390.0 ", " 1e-3 ")), False, None),
    # a line with EI = 0 and finite-EI sections is one finite-EI cable on every route
    ("split-line", _SPLIT_LINE, False, None),
    ("split-line-static", _static_check(_SPLIT_LINE, keep_dtm=True), False, None),
    ("split-line-host", _SPLIT_LINE, True, None),
    ("split-line-mixed-route", _SPLIT_LINE_AND_CHAIN, False, None),
    # Point<P>p channels are read from the EI=0 system: on the aggregate a Coupled point of
    # finite-EI lines alone has no live entry there, and a multibody march with no EI=0 line
    # has no system at all
    ("finite-point-channels", _FINITE_POINT_POSITIONS, False, None),
    (
        "finite-cable-point-host",
        _edit(_FINITE, ("FairTen1\n", "FairTen1\nPoint2px\n")),
        True,
        r"targets a cable-only point",
    ),
    (
        "finite-fixed-point-host",
        _edit(_FINITE, ("FairTen1\n", "FairTen1\nPoint1pz\nPoint2Fz\n")),
        True,
        None,
    ),
    ("mixed-cable-point", _MIXED_CABLE_POINT, False, r"targets a cable-only point"),
    ("mixed-chain-point", _MIXED_CHAIN_POINT, False, None),
    ("buoy-finite-legs-forces", _BUOY_FORCES, False, None),
    (
        "buoy-finite-legs-positions",
        _BUOY_FINITE_LEGS,
        False,
        r"Point channels need an EI=0 mooring system",
    ),
]


@pytest.mark.parametrize(
    ("text", "caller_driven", "message"),
    [pytest.param(*case[1:], id=case[0]) for case in _ROUTE_RULE_CASES],
)
def test_route_rules_of_the_native_reader(text, caller_driven, message):
    if message is None:
        DeckFile.from_text(text, caller_driven=caller_driven)
    else:
        _rejects(text, message, caller_driven=caller_driven)


@pytest.mark.skipif(
    not _PARITY_DRIVER or not Path(_PARITY_DRIVER).is_file(),
    reason="set CABLEDYN_TEST_DRIVER to a built native driver to run the route-rule parity",
)
@pytest.mark.parametrize(
    "text",
    [pytest.param(case[1], id=case[0]) for case in _ROUTE_RULE_CASES if not case[2]],
)
def test_route_rules_match_the_driver(text, tmp_path):
    deck = tmp_path / "rules.dat"
    deck.write_text(text, encoding="utf-8")
    completed = subprocess.run(
        [_PARITY_DRIVER, str(deck), str(tmp_path / "rules")],
        capture_output=True,
        text=True,
        errors="replace",
        cwd=tmp_path,
        timeout=600,
        env={**os.environ, "OMP_NUM_THREADS": "1", "OPENBLAS_NUM_THREADS": "1"},
        check=False,
    )
    assert completed.returncode in (0, 1), completed.stderr[-600:]
    assert _accepted(deck) == (completed.returncode == 0), completed.stderr[-600:]


@pytest.mark.skipif(
    not _PARITY_DRIVER or not Path(_PARITY_DRIVER).is_file(),
    reason="set CABLEDYN_TEST_DRIVER to a built native driver to run the refinement-stop check",
)
def test_a_compression_refinement_leaves_where_it_was_stops_the_refinement(tmp_path):
    # the power cable with its sections given twice: too long to hang clear of the seabed, it is
    # held in axial compression by its bending stiffness, a compression of the equilibrium that
    # no mesh removes; the axial refinement stops once two passes leave it where it was instead
    # of splitting elements to the element budget (6 passes, 32768 elements)
    tail = "1       bare      52.101   256\n"
    text = _example(
        "lozon_gomex80_power_cable.dat",
        (tail, tail + "1       bare      68.114   448\n1       buoy      50.000   320\n" + tail),
    )
    deck = tmp_path / "long.dat"
    deck.write_text(text, encoding="utf-8")
    completed = subprocess.run(
        [_PARITY_DRIVER, str(deck), str(tmp_path / "long")],
        capture_output=True,
        text=True,
        errors="replace",
        cwd=tmp_path,
        timeout=900,
        env={**os.environ, "OMP_NUM_THREADS": "1", "OPENBLAS_NUM_THREADS": "1"},
        check=False,
    )
    assert completed.returncode == 2, completed.stderr[-600:]
    assert "two passes left the compression where it was" in completed.stderr, completed.stderr[
        -900:
    ]
    assert _accepted(deck)


@pytest.mark.parametrize(
    ("od", "accepted"), [("1000.0", True), ("1000.001", False), ("1e6", False)]
)
def test_stiffener_diameter_bound_matches_the_driver(od, accepted, tmp_path):
    # a sleeve as wide as the widest line type (Diam <= 1e3 m) at most
    text = _example(
        "lazy_wave_bend_stiffener.dat",
        (_STIFFENER_ROOT, f"1       A    0.4     {od}    0.45   0.17    5.0e7   1150"),
    )
    if accepted:
        DeckFile.from_text(text)
    else:
        _rejects(text, "RootOD and TipOD must be at most 1e3 m")
    if not _PARITY_DRIVER or not Path(_PARITY_DRIVER).is_file():
        return
    deck = tmp_path / "stiffener.dat"
    deck.write_text(_static_check(text), encoding="utf-8")
    shutil.copytree(EXAMPLES / "data", tmp_path / "data")
    completed = subprocess.run(
        [_PARITY_DRIVER, str(deck), str(tmp_path / "stiffener")],
        capture_output=True,
        text=True,
        errors="replace",
        cwd=tmp_path,
        timeout=600,
        env={**os.environ, "OMP_NUM_THREADS": "1", "OPENBLAS_NUM_THREADS": "1"},
        check=False,
    )
    if accepted:
        assert completed.returncode != 1 or "at most 1e3 m" not in completed.stderr
    else:
        assert completed.returncode == 1, completed.stderr[-600:]
        assert "RootOD and TipOD must be at most 1e3 m" in completed.stderr


# ------------------------------------------------------------------ the smallest time step

# the implicit marches divide by dt^2, which overflows the inertia terms near 1e-155 s
_TINY_STEPS = [
    ("1e-100", True),
    ("1e-60", True),
    ("1e-101", False),
    ("1e-160", False),
    ("1e-300", False),
]


@pytest.mark.parametrize(("dt", "accepted"), _TINY_STEPS)
def test_dtm_has_a_smallest_value(dt, accepted):
    text = _edit(_HELD, ("0.1 dtM\n10.0 TMax\n", f"{dt} dtM\n{2 * float(dt)!r} TMax\n"))
    if accepted:
        DeckFile.from_text(text)
    else:
        _rejects(text, r"dtM must be at least 1e-100 s")
        # every row is checked, also one a later row overrides
        _rejects(
            _edit(_HELD, ("0.1 dtM\n", f"{dt} dtM\n0.1 dtM\n")), r"dtM must be at least 1e-100 s"
        )


@pytest.mark.skipif(
    not _PARITY_DRIVER or not Path(_PARITY_DRIVER).is_file(),
    reason="set CABLEDYN_TEST_DRIVER to a built native driver to run the time-step parity",
)
@pytest.mark.parametrize(("dt", "accepted"), _TINY_STEPS)
@pytest.mark.parametrize("ei", ["0.0", "1.0e4"], ids=["ei0", "finite-ei"])
def test_dtm_bound_matches_the_driver(dt, accepted, ei, tmp_path):
    text = _edit(
        _HELD,
        ("0.1 dtM\n10.0 TMax\n", f"{dt} dtM\n{2 * float(dt)!r} TMax\n"),
        (" -1.0 0.0 1.37", f" -1.0 {ei} 1.37"),
    )
    deck = tmp_path / "step.dat"
    deck.write_text(text, encoding="utf-8")
    completed = subprocess.run(
        [_PARITY_DRIVER, str(deck), str(tmp_path / "step")],
        capture_output=True,
        text=True,
        errors="replace",
        cwd=tmp_path,
        timeout=600,
        env={**os.environ, "OMP_NUM_THREADS": "1", "OPENBLAS_NUM_THREADS": "1"},
        check=False,
    )
    assert completed.returncode == (0 if accepted else 1), completed.stderr[-600:]
    assert _accepted(deck) == accepted
    if not accepted:
        assert "dtM must be at least 1e-100 s" in completed.stderr
