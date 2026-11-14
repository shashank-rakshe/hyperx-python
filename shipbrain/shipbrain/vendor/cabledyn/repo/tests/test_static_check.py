#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""TMax = 0 checks the static start of a dynamic deck, and records may outlast TMax.

Gates, on the shipped lazy-wave decks driven by a vesselMotion record and by a motionFile
(both 36 s records at dtM 0.05 s):

* a run to TMax = 1 s on the full record writes the same output, byte for byte, as one on
  the record cut to 1 s: rows after TMax are read and not used;
* a row after TMax that is off the dtM grid is still refused;
* TMax = 0 runs either deck, RangeStart 12 s included, and writes the t = 0 row of the
  1 s run, with the range graph of that row;
* RangeStart after a TMax > 0 is still refused;
* without dtM and TMax the deck stops on its first dynamic input, and the message says to
  give TMax = 0.

and on one deck of each route (EI = 0 and finite-EI lines, the mixed aggregate, the multibody
march, deck current and waves, vesselMotion, vesselRAO and motionFile records, a TURBINES deck on
its per-turbine record):

* TMax = 0 needs no dtM: the deck runs, on records off any step, and writes the output of the
  run with dtM byte for byte;
* a positive TMax without dtM is still refused as a dynamic run.

usage: test_static_check.py --exe <cabledyn> --examples <examples dir> --output <dir>
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

FAILURES: list[str] = []
HINT = "to check a dynamic deck's static start only, give TMax = 0"
# one deck of each route of a static check
ROUTES = ("dynamic_chain_held", "dynamic_chain_current", "dynamic_chain_waves", "lazy_wave_buoyancy_modules",
          "iea15mw_umaine_mixed_cabledyn", "mixed_body_rods_points", "rigid6_buoy", "rod_moored_spar",
          "connect_weighted_point", "lazy_wave_vessel_motion", "lazy_wave_vessel_rao",
          "lozon_gomex80_power_cable_motion")


TURBINES = """--------------------- CableDyn Input File ---------------------
a TURBINES deck on its per-turbine record, at 0.1 s
--------------------- LINE TYPES ---------------------
Name Diam Mass EA BA EI Cdn Cdt Can Cat
chain 0.1 20.0 1.0e9 -1.0 0.0 1.2 0.2 1.0 0.0
--------------------- TURBINES ---------------------
J X0 Y0 Z0 PtfmSurge PtfmSway PtfmHeave PtfmRoll PtfmPitch PtfmYaw
1 300.0 0.0 0 0 0 0 0 0 0
--------------------- POINTS ---------------------
ID Type X Y Z Mass Vol CdA Ca
1 Turbine1 0 0 -10 0 0 0 0
2 Fixed 0.0 0.0 -100.0 0 0 0 0
--------------------- LINES ---------------------
ID NodeA NodeB Outputs
1 1 2 -
--------------------- SECTIONS ---------------------
LineID LineType Length NumSegs
1 chain 380.0 20
--------------------- OPTIONS ---------------------
9.80665 g
1025.0 rhoW
100.0 WtrDpth
0.1 dtM
4.0 TMax
turbine.motion motionFile
--------------------- OUTPUTS ---------------------
AnchTen1
--------------------- need this line ---------------------
"""


def check(ok: bool, message: str) -> None:
    print(("PASS: " if ok else "FAIL: ") + message)
    if not ok:
        FAILURES.append(message)


def set_option(text: str, key: str, value: str | None) -> str:
    """Set the value of OPTION ``key`` (``None`` removes the row)."""
    pattern = re.compile(r"^\s*\S+\s+" + key + r"\b.*$", re.M | re.I)
    assert len(pattern.findall(text)) == 1, key
    return pattern.sub("" if value is None else f"{value}  {key}", text)


def cut_record(src: Path, dst: Path, tmax: float) -> None:
    """Copy a motion record keeping its comments and the rows up to tmax."""
    keep = [line for line in src.read_text().splitlines()
            if line.lstrip().startswith("#") or not line.strip() or float(line.split()[0]) <= tmax + 1e-9]
    dst.write_text("\n".join(keep) + "\n")


def run(exe: str, cwd: Path, name: str, text: str) -> subprocess.CompletedProcess:
    (cwd / f"{name}.dat").write_text(text, encoding="utf-8", newline="\n")
    return subprocess.run([exe, f"{name}.dat", name], cwd=cwd, capture_output=True, text=True,
                          env=dict(os.environ, OMP_NUM_THREADS="1"))


def data_rows(path: Path) -> list[str]:
    lines = path.read_text().splitlines()
    head = next(i for i, line in enumerate(lines) if line.startswith("Time"))
    return [line for line in lines[head + 1:] if line.strip() and not line.lstrip().startswith("(")]


def case(exe: str, examples: Path, out: Path, deck_name: str, record: str, keyword: str) -> None:
    work = out / deck_name
    work.mkdir(parents=True)
    text = (examples / f"{deck_name}.dat").read_text(encoding="utf-8")
    src = examples / record
    shutil.copy(src, work / "full.txt")
    cut_record(src, work / "cut.txt", 1.0)
    text = set_option(text, keyword, "full.txt")
    if "RangeStart" not in text:
        text = text.replace(f"full.txt  {keyword}", f"full.txt  {keyword}\n12.0  RangeStart", 1)
    # line 1 writes its range graph (LINES ID NodeA NodeB Outputs)
    text = re.sub(r"^(1\s+1\s+2\s+)\S+$", r"\1r", text, count=1, flags=re.M)

    one = set_option(set_option(text, "TMax", "1.0"), "RangeStart", "0.5")
    p_full = run(exe, work, "full", one)
    p_cut = run(exe, work, "cut", one.replace(f"full.txt  {keyword}", f"cut.txt  {keyword}"))
    ok = p_full.returncode == 0 and p_cut.returncode == 0
    check(ok, f"{deck_name}: TMax = 1 s runs on the 36 s record and on the record cut to 1 s "
          f"(exit {p_full.returncode}, {p_cut.returncode})")
    if not ok:
        print(p_full.stderr[-1500:], p_cut.stderr[-1500:])
        return
    same = (work / "full.out").read_bytes() == (work / "cut.out").read_bytes()
    check(same, f"{deck_name}: the run on the longer record writes the same output byte for byte")

    off = (work / "full.txt").read_text().splitlines()
    last = next(line for line in reversed(off) if line.strip() and not line.startswith("#")).split()
    last[0] = f"{float(last[0]) + 0.025:.3f}"
    (work / "off.txt").write_text("\n".join(off + ["  ".join(last)]) + "\n")
    p_off = run(exe, work, "off", one.replace(f"full.txt  {keyword}", f"off.txt  {keyword}"))
    check(p_off.returncode != 0 and "time is outside the dtM/TMax grid" in p_off.stderr,
          f"{deck_name}: an off-grid row after TMax is refused")

    p_zero = run(exe, work, "zero", set_option(text, "TMax", "0.0"))
    check(p_zero.returncode == 0, f"{deck_name}: TMax = 0 with RangeStart 12 s checks the static start "
          f"(exit {p_zero.returncode})")
    if p_zero.returncode != 0:
        print(p_zero.stderr[-1500:])
        return
    rows = data_rows(work / "zero.out")
    check(len(rows) == 1 and rows[0] == data_rows(work / "full.out")[0],
          f"{deck_name}: TMax = 0 writes the t = 0 row of the 1 s run")
    graph = (work / "zero.Line1.range.out").read_text().splitlines()
    check("1 samples from t =" in graph[0] and any(line[:1].isdigit() for line in graph),
          f"{deck_name}: and the range graph of that row")

    p_late = run(exe, work, "late", set_option(one, "RangeStart", "2.0"))
    check(p_late.returncode != 0 and "RangeStart exceeds TMax" in p_late.stderr,
          f"{deck_name}: RangeStart after a TMax > 0 is still refused")

    p_none = run(exe, work, "none", set_option(set_option(text, "TMax", None), "dtM", None))
    check(p_none.returncode != 0 and HINT in p_none.stderr,
          f"{deck_name}: without dtM and TMax the message says to give TMax = 0")


def no_dtm(exe: str, work: Path, deck_name: str) -> None:
    """The deck at TMax = 0 with and without dtM, and at a positive TMax (past any RangeStart) without dtM."""
    text = (work / f"{deck_name}.dat").read_text(encoding="utf-8")
    zero = set_option(text, "TMax", "0.0")
    p_with = run(exe, work, f"{deck_name}_with", zero)
    p_none = run(exe, work, f"{deck_name}_none", set_option(zero, "dtM", None))
    check(p_with.returncode == 0 and p_none.returncode == 0,
          f"{deck_name}: TMax = 0 runs with and without dtM (exit {p_with.returncode}, {p_none.returncode})")
    if p_none.returncode != 0:
        print(p_none.stderr[-1500:])
        return
    log = p_none.stdout + p_none.stderr
    check("dynamic run" not in log and "dtM =" not in log,
          f"{deck_name}: and says nothing of a dynamic run or a time step")
    same = (work / f"{deck_name}_with.out").read_bytes() == (work / f"{deck_name}_none.out").read_bytes()
    check(same, f"{deck_name}: and writes the same output byte for byte")
    p_late = run(exe, work, f"{deck_name}_late", set_option(set_option(text, "TMax", "1000.0"), "dtM", None))
    check(p_late.returncode == 1 and "dynamic run requires both dtM and TMax" in p_late.stderr,
          f"{deck_name}: a positive TMax without dtM is still refused (exit {p_late.returncode})")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--examples", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    out = Path(args.output)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    examples = Path(args.examples)
    case(args.exe, examples, out, "lazy_wave_vessel_motion", "data/vessel/vessel_surge_heave_pitch_12s_dt005.txt",
         "vesselMotion")
    case(args.exe, examples, out, "lozon_gomex80_power_cable_motion", "data/lozon/gomex80_heave_3m_12s_dt005.txt",
         "motionFile")
    work = out / "no_dtm"
    shutil.copytree(examples, work)
    # the mixed aggregate on a vessel record
    mixed = (work / "iea15mw_umaine_mixed_cabledyn.dat").read_text(encoding="utf-8")
    record = "data/vessel/vessel_surge_heave_pitch_12s_dt005.txt  vesselMotion"
    (work / "mixed_vessel_motion.dat").write_text(
        set_option(mixed, "TMax", f"{record}\n0|0|0  vesselRef\n0.0"), encoding="utf-8", newline="\n")
    # a TURBINES deck: time J x y z q0 q1 q2 q3 and the rates, at rest, every 0.1 s
    rows = [f"{0.1 * k:.1f} 1 300 0 0 1 0 0 0 " + " ".join(["0"] * 12) for k in range(41)]
    (work / "turbine.motion").write_text("\n".join(rows) + "\n", encoding="utf-8", newline="\n")
    (work / "turbines_motion.dat").write_text(TURBINES, encoding="utf-8", newline="\n")
    for deck_name in (*ROUTES, "mixed_vessel_motion", "turbines_motion"):
        no_dtm(args.exe, work, deck_name)
    print(f"{len(FAILURES)} failure(s)")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
