#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""The initialisation note on grounded lines that a current moves over a seabed without friction.

A dynamic deck with an interior line node in seabed contact at the static start, a current and
no friction prints one note for the run, naming the lines and frictionMu. Gates, on a grounded
chain and on the shipped decks of the other routes:

* the note appears once on an EI = 0 line, a finite-EI line, the mixed aggregate (both lines in
  one note), a line to a Free point, the multibody march (EI = 0 lines and a finite-EI cable) and
  a TURBINES deck on its motionFile record, and names the lines concerned; a route that rejects
  frictionMu says so instead of asking for it;
* no note on a deck with no grounded node (a line clear of the seabed, a taut line that touches
  it at its anchor only), in still water or a zero current, with frictionMu, or on a static run
  (TMax = 0 or no clock): the shipped lazy wave in its current, grounded over 156 nodes, is silent
  at its own TMax = 0 and noted on a short march.

usage: test_seabed_drift_note.py --exe <cabledyn> --examples <examples dir> --output <dir>
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
NOTE = "on the seabed at the static start with no seabed friction"
BAR = "-" * 21
CLOCK = "0.05 dtM\n0.1 TMax\n"
CURRENT = "uniform 0.5 0 0 current\n"
DECK = f"""{BAR} CableDyn Input File {BAR}
seabed drift note
{BAR} LINE TYPES {BAR}
Name Diam Mass EA BA EI Cdn Cdt Can Cat
chain 0.252 390.0 1.674e9 -1.0 0.0 1.37 0.64 1.0 0.0
cable 0.2 60.0 4.0e8 0.0 1.0e4 1.2 0.1 1.0 0.0
{BAR} POINTS {BAR}
ID Type X Y Z Mass Vol CdA Ca
1 Fixed 400.0 0.0 -50.0 0 0 0 0
2 Coupled 0.0 0.0 0.0 0 0 0 0
3 Fixed -400.0 0.0 -50.0 0 0 0 0
{BAR} LINES {BAR}
ID NodeA NodeB Outputs
1 2 1 -
@LINE2@
{BAR} SECTIONS {BAR}
LineID LineType Length NumSegs
1 @TYPE@ @LENGTH@ 41
@SECTION2@
{BAR} OPTIONS {BAR}
9.80665 g
1025.0 rhoW
50.0 WtrDpth
@OPTIONS@
{BAR} OUTPUTS {BAR}
FairTen1
{BAR} need this line {BAR}
"""


TURBINES = f"""{BAR} CableDyn Input File {BAR}
seabed drift note on a TURBINES deck
{BAR} LINE TYPES {BAR}
Name Diam Mass EA BA EI Cdn Cdt Can Cat
chain 0.1 20.0 1.0e9 -1.0 0.0 1.2 0.2 1.0 0.0
{BAR} TURBINES {BAR}
J X0 Y0 Z0 PtfmSurge PtfmSway PtfmHeave PtfmRoll PtfmPitch PtfmYaw
1 300.0 0.0 0 0 0 0 0 0 0
{BAR} POINTS {BAR}
ID Type X Y Z Mass Vol CdA Ca
1 Turbine1 0 0 -10 0 0 0 0
2 Fixed 0.0 0.0 -100.0 0 0 0 0
{BAR} LINES {BAR}
ID NodeA NodeB Outputs
1 1 2 -
{BAR} SECTIONS {BAR}
LineID LineType Length NumSegs
1 chain 380.0 20
{BAR} OPTIONS {BAR}
9.80665 g
1025.0 rhoW
100.0 WtrDpth
@OPTIONS@
turbine.motion motionFile
{BAR} OUTPUTS {BAR}
AnchTen1
{BAR} need this line {BAR}
"""


def check(ok: bool, message: str) -> None:
    print(("PASS: " if ok else "FAIL: ") + message)
    if not ok:
        FAILURES.append(message)


def deck(options: str, line_type: str = "chain", length: str = "410.0", second: bool = False) -> str:
    return (DECK.replace("@OPTIONS@", options).replace("@TYPE@", line_type).replace("@LENGTH@", length)
            .replace("@LINE2@", "2 2 3 -" if second else "")
            .replace("@SECTION2@", "2 cable 420.0 42" if second else ""))


def run(exe: str, work: Path, name: str, text: str) -> str:
    (work / f"{name}.dat").write_text(text, encoding="utf-8", newline="\n")
    done = subprocess.run([exe, f"{name}.dat", name], cwd=work, capture_output=True, text=True,
                          env=dict(os.environ, OMP_NUM_THREADS="1"))
    check(done.returncode == 0, f"{name}: runs (exit {done.returncode})")
    if done.returncode != 0:
        print(done.stderr[-1500:])
    return done.stdout + done.stderr


def noted(exe: str, work: Path, name: str, text: str, names: str, remedy: str = "Set frictionMu to hold") -> None:
    log = run(exe, work, name, text)
    check(log.count(NOTE) == 1, f"{name}: one note for the run ({log.count(NOTE)})")
    line = next((row for row in log.splitlines() if NOTE in row), "")
    check(names in line and remedy in line, f"{name}: names {names} and the remedy: {line.strip()}")


def silent(exe: str, work: Path, name: str, text: str) -> None:
    log = run(exe, work, name, text)
    check(NOTE not in log, f"{name}: no note")


def set_row(text: str, key: str, value: str | None) -> str:
    """Set OPTION ``key`` of a shipped deck; a key it lacks goes first in OPTIONS."""
    pattern = re.compile(r"^(?![ \t]*--)[ \t]*\S+(?:[ \t]+\S+)*?[ \t]+" + key + r"\b.*$", re.M)
    if pattern.search(text):
        return pattern.sub("" if value is None else value, text, count=1)
    head = re.search(r"^-+ *OPTIONS.*\n", text, re.M)
    return text[:head.end()] + (value or "") + "\n" + text[head.end():]


def shipped(work: Path, name: str, *rows: tuple[str, str | None]) -> str:
    text = (work / f"{name}.dat").read_text(encoding="utf-8")
    text = set_row(set_row(text, "dtM", "0.005 dtM"), "TMax", "0.01 TMax")
    for key, value in rows:
        text = set_row(text, key, value)
    assert len(re.findall(r"^(?![ \t]*--).*\bTMax\b", text, re.M)) == 1, name
    return text


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--examples", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    exe = args.exe
    out = Path(args.output)
    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(args.examples, out)

    # the note, on each route
    noted(exe, out, "ei0", deck(CLOCK + CURRENT), "line 1 lies")
    noted(exe, out, "finite", deck(CLOCK + CURRENT, "cable", "420.0"), "line 1 lies")
    noted(exe, out, "mixed", deck(CLOCK + CURRENT, second=True), "lines 1, 2 lie")
    noted(exe, out, "profile", deck(CLOCK + "profile -50 0.5 0 0 0 0.5 0 0 current\n"), "line 1 lies")
    current = ("current", "uniform 0.5 0 0 current")
    refused = "Seabed friction (frictionMu), which would hold it, is not supported on this deck"
    clump = shipped(out, "clump_weight_free_point", current).replace("chain      250.0", "chain      300.0")
    noted(exe, out, "free_point", clump, "line 1 lies", refused)
    noted(exe, out, "multibody_ei0", shipped(out, "spar_pinned_rods", current), "lines 1, 2, 3 lie")
    noted(exe, out, "multibody_finite", shipped(out, "buoy_clamped_cable", current), "line 4 lies")
    noted(exe, out, "multibody_points", shipped(out, "mixed_body_rods_points", current), "line 8 lies", refused)

    # a TURBINES deck on its per-turbine record: time J x y z q0 q1 q2 q3 and the rates, at rest
    rows = [f"{0.05 * k:.2f} 1 300 0 0 1 0 0 0 " + " ".join(["0"] * 12) for k in range(5)]
    (out / "turbine.motion").write_text("\n".join(rows) + "\n", encoding="utf-8", newline="\n")
    noted(exe, out, "turbines", TURBINES.replace("@OPTIONS@", CLOCK + CURRENT), "line 1 lies")
    silent(exe, out, "turbines_still", TURBINES.replace("@OPTIONS@", CLOCK))
    silent(exe, out, "turbines_friction", TURBINES.replace("@OPTIONS@", CLOCK + CURRENT + "0.5 frictionMu\n"))
    silent(exe, out, "turbines_static", TURBINES.replace("@OPTIONS@", "0.05 dtM\n0.0 TMax\n" + CURRENT))

    # no grounded node, on the EI = 0 and finite-EI routes
    clear = deck(CLOCK + CURRENT, length="404.0").replace("1 Fixed 400.0 0.0 -50.0", "1 Fixed 400.0 0.0 -30.0")
    silent(exe, out, "clear_ei0", clear)
    silent(exe, out, "clear_finite", clear.replace("1 chain 404.0", "1 cable 404.0"))
    silent(exe, out, "anchor_only_ei0", deck(CLOCK + CURRENT, length="400.0"))
    silent(exe, out, "anchor_only_finite", deck(CLOCK + CURRENT, "cable", "400.0"))

    # still water, a zero current and friction, on the single-line routes and the mixed aggregate
    routes = (("ei0", {}), ("finite", {"line_type": "cable", "length": "420.0"}), ("mixed", {"second": True}))
    for tag, kwargs in routes:
        silent(exe, out, f"still_{tag}", deck(CLOCK, **kwargs))
        silent(exe, out, f"zero_{tag}", deck(CLOCK + "uniform 0 0 0 current\n", **kwargs))
        silent(exe, out, f"friction_{tag}", deck(CLOCK + CURRENT + "0.5 frictionMu\n", **kwargs))
        # a static run marches no step
        silent(exe, out, f"static_{tag}", deck("0.05 dtM\n0.0 TMax\n" + CURRENT, **kwargs))
    silent(exe, out, "static_no_clock", deck(""))
    lazy_wave = (out / "lazy_wave_buoyancy_smeared.dat").read_text(encoding="utf-8")
    silent(exe, out, "lazy_wave_static", lazy_wave)
    noted(exe, out, "lazy_wave_march", set_row(lazy_wave, "TMax", "0.05 TMax"), "line 1 lies")
    silent(exe, out, "static_free_point", set_row(clump, "TMax", "0.0 TMax"))
    for name in ("spar_pinned_rods", "buoy_clamped_cable"):
        silent(exe, out, f"static_{name}", shipped(out, name, current, ("TMax", "0.0 TMax")))
        silent(exe, out, f"friction_{name}", shipped(out, name, current, ("frictionMu", "0.5 frictionMu")))
    print(f"{len(FAILURES)} failure(s)")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
