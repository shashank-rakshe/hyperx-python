#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""A Point3 buoy that starts off balance under bodyIC static is noted with its unbalanced force.

The static solve does not place a Point3 buoy: it starts at its deck position. A 112 t buoy of
259 m^3 on one slack wire leg, 11 m below the surface, starts with about 1.5 MN of net buoyancy
unbalanced. Under the default bodyIC static the run must note it, with the force equal to the
line force on the buoy (Point1F at t = 0) plus its net buoyancy (rhoW Vol - Mass) g to 1e-3, and
with bodyIC deck (an off-balance start on purpose) it must not.

usage: test_point3_balance_note.py --exe <cabledyn> --output <dir>
"""

from __future__ import annotations

import argparse
import math
import os
import re
import subprocess
import sys
from pathlib import Path

DECK = """--------------------- CableDyn Input File ------------------------------------
Point3 buoy on one wire leg, off balance at its deck position
--------------------- LINE TYPES ---------------------------------------
TypeName Diam Mass EA BA EI Cd_n Cd_t Ca_n Ca_t
(-) (m) (kg/m) (N) (N-s) (N-m2) (-) (-) (-) (-)
leg 0.0631 19.93 3.588e8 -0.5 0.0 1.2 0.008 1.0 0.0
--------------------- BODIES -------------------------------------------
ID Type X Y Z Roll Pitch Yaw Mass Vol C33 C44 C55 CdA Ca Ixx Iyy Izz
(-) (-) (m) (m) (m) (deg) (deg) (deg) (kg) (m3) (N/m) (Nm/rad) (Nm/rad) (m2) (-) (kgm2) (kgm2) (kgm2)
1 Point3 27.92 -29.39 -11.07 0.0 0.0 0.0 111760.0 258.6 0.0 0.0 0.0 5.56 0.5 683510.0 683510.0 683510.0
--------------------- POINTS -------------------------------------------
ID Type X Y Z
(-) (-) (m) (m) (m)
1 Body1 0.0 0.0 0.0
2 Fixed 166.94 -51.95 -56.85
--------------------- LINES --------------------------------------------
ID NodeA NodeB Outputs
(-) (-) (-) (-)
1 1 2 -
--------------------- SECTIONS -----------------------------------------
LineID LineType Length NumSegs
(-) (-) (m) (-)
1 leg 178.39 23
--------------------- OPTIONS ------------------------------------------
56.85 WtrDpth
1.8e5 kBot
0.01 dtM
0.02 TMax
{ic} bodyIC
--------------------- OUTPUTS ------------------------------------------
Point1Fx
Point1Fy
Point1Fz
--------------------- need this line -----------------------------------
"""

NOTE = re.compile(r"BODY 1 \(Point3\) starts at its deck position, which the static solve does not change, "
                  r"with an unbalanced force of\s+(\S+) N there")
G, RHO = 9.80665, 1025.0


def run(exe: str, out: Path, ic: str) -> tuple:
    deck = out / ("buoy_%s.dat" % ic)
    deck.write_text(DECK.format(ic=ic), encoding="utf-8", newline="\n")
    root = out / ("buoy_%s" % ic)
    env = dict(os.environ)
    env.setdefault("OPENBLAS_NUM_THREADS", "1")
    p = subprocess.run([exe, str(deck), str(root)], capture_output=True, text=True, env=env, cwd=str(out))
    if p.returncode != 0:
        raise RuntimeError("bodyIC %s run failed: %s" % (ic, (p.stdout + p.stderr)[-400:]))
    rows = Path(str(root) + ".out").read_text(encoding="utf-8").splitlines()
    return [float(v) for v in rows[2].split()[1:4]], p.stdout + p.stderr


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--output", required=True)
    a = ap.parse_args()
    out = Path(a.output)
    out.mkdir(parents=True, exist_ok=True)
    failures = []
    f, log = run(a.exe, out, "static")
    m = NOTE.search(log)
    if not m:
        failures.append("bodyIC static: no note of the unbalanced Point3 buoy")
    else:
        net = (f[0], f[1], f[2] + (RHO * 258.6 - 111760.0) * G)
        expect = math.sqrt(sum(c * c for c in net))
        got = float(m.group(1))
        if abs(got - expect) > 1.0e-3 * expect:
            failures.append("bodyIC static: noted force %.4e N, expected %.4e N" % (got, expect))
    _, log = run(a.exe, out, "deck")
    if NOTE.search(log):
        failures.append("bodyIC deck: the off-balance start is noted")
    print("Point3 balance note: %d failures" % len(failures))
    for x in failures:
        print("FAIL:", x)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
