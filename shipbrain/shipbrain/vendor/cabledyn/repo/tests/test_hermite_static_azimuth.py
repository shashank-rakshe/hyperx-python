#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""The finite-EI statics of a line do not depend on its azimuth.

A 3.8 km suspended three-section lazy wave on 540 elements, clamped (Rigid) at its fairlead
along a direction 11 deg out of the vertical plane of its chord, is turned about the vertical
axis. Its first continuation stage fails on the coarse mesh at the clamp and the statics restart
at full stiffness from the catenary seed, an energy descent whose length scatters with the last
digits of the input (1171 to 1661 iterations over 28 azimuths). It was cut at 1600, so the
statics failed at 328.29 and 329 deg and solved elsewhere; it now runs while its residual keeps
falling. Every azimuth (seven across 328 to 329.5 deg and four elsewhere) must solve, with the
same fairlead and anchor tensions to 1e-6.

usage: test_hermite_static_azimuth.py --exe <cabledyn> --output <dir>
"""

from __future__ import annotations

import argparse
import math
import os
import subprocess
import sys
from pathlib import Path

DECK = """--------------------- CableDyn Input File ------------------------------------
Suspended lazy wave clamped at its fairlead out of its chord plane, turned about the vertical
--------------------- LINE TYPES ---------------------------------------
TypeName Diam Mass EA BA EI Cd_n Cd_t Ca_n Ca_t
(-) (m) (kg/m) (N) (N-s) (N-m2) (-) (-) (-) (-)
t1 0.13901651567091225 25.009060114295032 644913120.4893594 -1.0 203482.2288474299 1.2 0.01 1.0 0.0
t2 0.6428183465278386 200.38465492542826 1054908164.887091 -0.8 38575.24712022166 1.2 0.01 1.0 0.0
t3 0.07107464816032726 25.258028055571554 454644505.00028795 -1.0 2138.24079651583 1.2 0.008 1.0 0.0
--------------------- POINTS -------------------------------------------
ID Type X Y Z
(-) (-) (m) (m) (m)
1 Coupled {xa!r} {ya!r} -63.39980772163334
2 Fixed {xb!r} {yb!r} -754.4713708188342
--------------------- LINES --------------------------------------------
ID NodeA NodeB Outputs
(-) (-) (-) (-)
1 1 2 -
--------------------- SECTIONS -----------------------------------------
LineID LineType Length NumSegs
(-) (-) (m) (-)
1 t1 1351.43480777781 200
1 t2 792.1830512136142 140
1 t3 1678.538077522514 200
--------------------- END CONNECTIONS -------------------------------
LineID End Stiffness EzX EzY EzZ
(-) (-) (N-m/rad) (-) (-) (-)
1 A Rigid {ex!r} {ey!r} -0.4254613873973588
--------------------- OPTIONS ------------------------------------------
0.01 dtM
0.0 TMax
--------------------- OUTPUTS ------------------------------------------
FairTen1
AnchTen1
--------------------- need this line -----------------------------------
"""

A = (14.254910394242287, 60.0359685337248)
B = (-2330.8134158224498, 2012.8230287080746)
EZ = (-0.5700516816811296, 0.702868186821989)
ANGLES = [0.0, 90.0, 200.0, 328.0, 328.29064504314925, 328.5, 328.75, 329.0, 329.25, 329.5, 330.0]


def turn(p, th):
    c, s = math.cos(math.radians(th)), math.sin(math.radians(th))
    return c * p[0] - s * p[1], s * p[0] + c * p[1]


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
    ref = None
    for th in ANGLES:
        (xa, ya), (xb, yb), (ex, ey) = turn(A, th), turn(B, th), turn(EZ, th)
        name = "azimuth_%g" % th
        deck = out / (name + ".dat")
        deck.write_text(
            DECK.format(xa=xa, ya=ya, xb=xb, yb=yb, ex=ex, ey=ey), encoding="utf-8", newline="\n"
        )
        root = out / name
        p = subprocess.run(
            [a.exe, str(deck), str(root)], capture_output=True, text=True, env=env, cwd=str(out)
        )
        if p.returncode != 0:
            failures.append(
                "%g deg: exit %d: %s" % (th, p.returncode, (p.stdout + p.stderr)[-300:])
            )
            continue
        rows = Path(str(root) + ".out").read_text(encoding="utf-8").splitlines()
        vals = [float(v) for v in rows[2].split()[1:3]]
        if ref is None:
            ref = vals
        for v, r, ch in zip(vals, ref, ("FairTen1", "AnchTen1")):
            if abs(v - r) > 1.0e-6 * abs(r):
                failures.append("%g deg: %s %.8e differs from %.8e" % (th, ch, v, r))
    print(
        "lazy wave turned about the vertical: %d azimuths, %d failures"
        % (len(ANGLES), len(failures))
    )
    for f in failures:
        print("FAIL:", f)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
