#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""A modal analysis about an unstable static state reports its negative omega^2.

A short finite-EI cable on a coarse mesh (27 elements) is solved in its vertical plane, where
it is unstable out of the plane: its lowest eigenvalue omega^2 is negative. modes.out must
write that mode with a negative frequency and omega and a period of 0, and the run must print
a note naming the line. On a mesh refined 4x the planar state is stable: every frequency is
positive and the note is absent.

usage: test_modal_negative_note.py --exe <cabledyn> --output <dir>
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

DECK = """--------------------- CableDyn Input File ------------------------------------
Finite-EI cable whose planar static state is unstable out of its plane on a coarse mesh
--------------------- LINE TYPES ---------------------------------------
TypeName Diam Mass EA BA EI Cd_n Cd_t Ca_n Ca_t
(-) (m) (kg/m) (N) (N-s) (N-m2) (-) (-) (-) (-)
cab 0.167 45.5 5.72e8 -0.5 9250.0 1.2 0.01 1.0 0.0
--------------------- POINTS -------------------------------------------
ID Type X Y Z
(-) (-) (m) (m) (m)
1 Coupled 0.0 0.0 -0.24
2 Fixed 77.65 0.0 -21.06
--------------------- LINES --------------------------------------------
ID NodeA NodeB Outputs
(-) (-) (-) (-)
1 1 2 -
--------------------- SECTIONS -----------------------------------------
LineID LineType Length NumSegs
(-) (-) (m) (-)
1 cab 90.56 {n}
--------------------- OPTIONS ------------------------------------------
21.06 WtrDpth
1.5e5 kBot
0.01 dtM
0.0 TMax
4 nModes
--------------------- OUTPUTS ------------------------------------------
FairTen1
--------------------- need this line -----------------------------------
"""

NOTE = "of its modes have omega^2 < 0"


def run(exe: str, out: Path, n: int) -> tuple:
    deck = out / ("cable_%d.dat" % n)
    deck.write_text(DECK.format(n=n), encoding="utf-8", newline="\n")
    root = out / ("cable_%d" % n)
    env = dict(os.environ)
    env.setdefault("OPENBLAS_NUM_THREADS", "1")
    p = subprocess.run([exe, str(deck), str(root)], capture_output=True, text=True, env=env, cwd=str(out))
    if p.returncode != 0:
        raise RuntimeError("run with %d elements failed: %s" % (n, (p.stdout + p.stderr)[-400:]))
    rows = []
    for ln in Path(str(root) + ".modes.out").read_text(encoding="utf-8").splitlines():
        if ln.startswith("# Mode shapes"):
            break
        t = ln.split()
        if len(t) == 5 and t[0].isdigit():
            rows.append([float(v) for v in t[2:]])
    return rows, p.stdout + p.stderr


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--output", required=True)
    a = ap.parse_args()
    out = Path(a.output)
    out.mkdir(parents=True, exist_ok=True)
    failures = []
    rows, log = run(a.exe, out, 27)
    neg = [r for r in rows if r[0] < 0.0]
    if not neg:
        failures.append("coarse mesh: no negative frequency (%s)" % rows)
    for f, per, om in neg:
        if per != 0.0 or om >= 0.0:
            failures.append("coarse mesh: negative mode with period %g, omega %g" % (per, om))
    if "line 1: %d %s" % (len(neg), NOTE) not in log:
        failures.append("coarse mesh: the run does not note the %d negative mode(s)" % len(neg))
    rows, log = run(a.exe, out, 108)
    if any(r[0] <= 0.0 for r in rows):
        failures.append("refined mesh: a non-positive frequency (%s)" % rows)
    if NOTE in log:
        failures.append("refined mesh: the run notes a negative mode")
    print("modal negative-mode note: %d failures" % len(failures))
    for f in failures:
        print("FAIL:", f)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
