#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""A heavily damped finite-EI line held at rest stays at rest on every time step.

A taut 400 m wire (EA = 2.19e9 N, 111 elements) is held at both ends and started from its
static equilibrium. The axial damping coefficient BA is swept over 5e7 to 8e8 N s (2 zeta
EA/omega_1 with zeta from about 0.4 to 6 for its first axial mode, the damping that
``mode1 axialDampingRatio`` gives) and dtM over 0.002, 0.005 and 0.01 s. The damping force
takes the strain rate from the Newmark velocity, whose rounding is gamma/(beta dt) times
that of the coordinates, so at these BA and dtM the residual round-off of a step at rest
lies well above the tolerance on the undamped force scale. Every run must complete (exit
code 0) and keep its end tensions at their static values to 1e-6.

usage: test_hermite_damped_rest.py --exe <cabledyn> --output <dir>
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

DECK = """--------------------- CableDyn Input File ------------------------------------
Taut finite-EI line held at rest with a large axial damping coefficient
--------------------- LINE TYPES ---------------------------------------
TypeName Diam Mass EA BA EI Cd_n Cd_t Ca_n Ca_t
(-) (m) (kg/m) (N) (N-s) (N-m2) (-) (-) (-) (-)
wire 0.156 121.7 2.19e9 {ba} 963.0 1.2 0.008 1.0 0.0
--------------------- POINTS -------------------------------------------
ID Type X Y Z
(-) (-) (m) (m) (m)
1 Coupled 82.52 80.42 -8.60
2 Fixed -117.94 395.14 -139.38
--------------------- LINES --------------------------------------------
ID NodeA NodeB Outputs
(-) (-) (-) (-)
1 1 2 -
--------------------- SECTIONS -----------------------------------------
LineID LineType Length NumSegs
(-) (-) (m) (-)
1 wire 400.52 111
--------------------- OPTIONS ------------------------------------------
139.38 WtrDpth
2.9e6 kBot
{dt} dtM
{tmax} TMax
--------------------- OUTPUTS ------------------------------------------
FairTen1
AnchTen1
--------------------- need this line -----------------------------------
"""

BA = ["5.0e7", "7.0e7", "1.0e8", "1.3e8", "1.6e8", "2.0e8", "3.0e8", "4.0e8", "6.0e8", "8.0e8"]
DT = ["0.002", "0.005", "0.01"]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--output", required=True)
    a = ap.parse_args()
    out = Path(a.output)
    out.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env.setdefault("OPENBLAS_NUM_THREADS", "1")
    failures = []
    for ba in BA:
        for dt in DT:
            name = "held_%s_%s" % (ba, dt)
            deck = out / (name + ".dat")
            deck.write_text(DECK.format(ba=ba, dt=dt, tmax=repr(round(40 * float(dt), 6))), encoding="utf-8",
                            newline="\n")
            root = out / name
            p = subprocess.run([a.exe, str(deck), str(root)], capture_output=True, text=True, env=env,
                               cwd=str(out))
            if p.returncode != 0:
                failures.append("BA=%s dtM=%s: exit %d: %s" % (ba, dt, p.returncode, (p.stdout + p.stderr)[-300:]))
                continue
            rows = Path(str(root) + ".out").read_text(encoding="utf-8").splitlines()
            names = rows[1].split()
            vals = [[float(v) for v in r.split()] for r in rows[2:] if r.strip()]
            if len(vals) != 41:
                failures.append("BA=%s dtM=%s: %d output rows, expected 41" % (ba, dt, len(vals)))
                continue
            for ch in ("FairTen1", "AnchTen1"):
                k = names.index(ch)
                t0 = vals[0][k]
                drift = max(abs(v[k] - t0) for v in vals) / abs(t0)
                if drift > 1.0e-6:
                    failures.append("BA=%s dtM=%s: %s drifts by %.3e of its static value" % (ba, dt, ch, drift))
    print("held damped line: %d runs, %d failures" % (len(BA) * len(DT), len(failures)))
    for f in failures:
        print("FAIL:", f)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
