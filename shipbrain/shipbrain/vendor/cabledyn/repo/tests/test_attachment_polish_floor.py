#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""The discrete attachment polish accepts a residual floor as the line's own static solve does.

A 920 m suspended finite-EI cable is clamped at its anchor along -x, so that it arrives in a
tight bend (the deck mesh is refined about fivefold there), and carries one clump weight. The
warm-started solves of the attachment polish stall on a residual floor at a few times the tight
static tolerance (the smeared equilibrium of some of these lines is itself accepted at its
floor), and the polish failed. The clump mass (400 and 1600 kg) and its arc position (450 and
760 m) are swept. Every run must reach the discrete equilibrium without a fallback note, and its
end forces must balance the line's submerged weight and the clump's weight to 1e-5 of the
fairlead tension.

usage: test_attachment_polish_floor.py --exe <cabledyn> --output <dir>
"""

from __future__ import annotations

import argparse
import math
import os
import subprocess
import sys
from pathlib import Path

DECK = """--------------------- CableDyn Input File ------------------------------------
Suspended finite-EI cable clamped at its anchor in a tight bend, with one clump weight
--------------------- LINE TYPES ---------------------------------------
TypeName Diam Mass EA BA EI Cd_n Cd_t Ca_n Ca_t
(-) (m) (kg/m) (N) (N-s) (N-m2) (-) (-) (-) (-)
cab 0.26 91.0 9.3e8 0.0 2.5e4 1.2 0.01 1.0 0.0
--------------------- POINTS -------------------------------------------
ID Type X Y Z
(-) (-) (m) (m) (m)
1 Coupled 0.0 0.0 -10.0
2 Fixed 915.0 0.0 -171.0
--------------------- LINES --------------------------------------------
ID NodeA NodeB Outputs
(-) (-) (-) (-)
1 1 2 -
--------------------- SECTIONS -----------------------------------------
LineID LineType Length NumSegs
(-) (-) (m) (-)
1 cab 920.0 127
--------------------- END CONNECTIONS -------------------------------
LineID End Stiffness EzX EzY EzZ
(-) (-) (N-m/rad) (-) (-) (-)
1 B Rigid -1.0 0.0 0.0
--------------------- ATTACHMENTS ----------------------------------
LineID ArcLength Mass Volume CdA Ca CdAx
(-) (m) (kg) (m^3) (m^2) (-) (m^2)
1 {arc} {mass} 0.0 0.44 1.0 0.25
--------------------- OPTIONS ------------------------------------------
0.01 dtM
0.0 TMax
--------------------- OUTPUTS ------------------------------------------
FairTen1
Point1Fx
Point1Fy
Point1Fz
Point2Fx
Point2Fy
Point2Fz
--------------------- need this line -----------------------------------
"""

G, RHO = 9.80665, 1025.0
W_LINE = (91.0 - RHO * math.pi * 0.26**2 / 4.0) * G * 920.0
MASS = ["400.0", "1600.0"]
ARC = ["450.0", "760.0"]


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
    for mass in MASS:
        for arc in ARC:
            name = "clump_%s_%s" % (mass, arc)
            deck = out / (name + ".dat")
            deck.write_text(DECK.format(mass=mass, arc=arc), encoding="utf-8", newline="\n")
            root = out / name
            p = subprocess.run([a.exe, str(deck), str(root)], capture_output=True, text=True, env=env,
                               cwd=str(out))
            log = p.stdout + p.stderr
            if p.returncode != 0:
                failures.append("mass %s arc %s: exit %d: %s" % (mass, arc, p.returncode, log[-400:]))
                continue
            if "after a failed Newton solve" in log:
                failures.append("mass %s arc %s: the polish fell back after a failed Newton solve" % (mass, arc))
            rows = Path(str(root) + ".out").read_text(encoding="utf-8").splitlines()
            names = rows[1].split()
            vals = [float(v) for v in rows[2].split()]
            f = {n: vals[names.index(n)] for n in names[1:]}
            sx = f["Point1Fx"] + f["Point2Fx"]
            sy = f["Point1Fy"] + f["Point2Fy"]
            sz = f["Point1Fz"] + f["Point2Fz"] + W_LINE + float(mass) * G
            err = math.sqrt(sx * sx + sy * sy + sz * sz) / f["FairTen1"]
            if err > 1.0e-5:
                failures.append("mass %s arc %s: end forces miss the weight by %.3e of the fairlead tension"
                                % (mass, arc, err))
    print("clamped cable with a clump: %d runs, %d failures" % (len(MASS) * len(ARC), len(failures)))
    for f in failures:
        print("FAIL:", f)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
