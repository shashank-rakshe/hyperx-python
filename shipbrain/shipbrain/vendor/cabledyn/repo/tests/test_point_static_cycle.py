#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""The static balance of a Connect point does not cycle between trial steps.

A massless Connect point hangs from a fairlead on a 383 m heavy chain (4.0 kN/m submerged)
and is held by two wires to anchors on the seabed, 860 and 915 m away, one wire 50 m slack, the
other lying nearly taut. Its balance (independent check: elastic catenaries with a frictionless
seabed) lies 5.6 m above the seabed at (-46.28, -215.17, -385.52) m, the chain hanging almost
straight. The point solve accepted a step that raised the force residual a hundredfold when the
Newton step from it was half the current one; near the wires' slack/taut kinks the Newton step
then grew again, and the steps cycled with period four (4e4 N -> 6e6 N -> ...) until the solve
failed from every seed. The deck, translated by 0, 0.5, 7 and 50 m and on twice its mesh, must
solve, with the point within 1.5 m (deck mesh: 11 to 27 m elements, the lumped weight of a chain
element 43 kN) and 0.5 m (refined mesh) of that balance.

usage: test_point_static_cycle.py --exe <cabledyn> --output <dir>
"""

from __future__ import annotations

import argparse
import math
import os
import subprocess
import sys
from pathlib import Path

DECK = """--------------------- CableDyn Input File ------------------------------------
Connect point between a near-vertical heavy chain and two wires on the seabed
--------------------- LINE TYPES ---------------------------------------
TypeName Diam Mass EA BA EI Cd_n Cd_t Ca_n Ca_t
(-) (m) (kg/m) (N) (N-s) (N-m2) (-) (-) (-) (-)
c1 0.27415669765336415 461.64250243121677 1981119080.7852216 -0.5 0.0 2.4 1.15 1.0 0.5
c2 0.15735867593791983 123.80876446467634 2228557760.3641744 -0.8 0.0 1.2 0.008 1.0 0.0
--------------------- POINTS -------------------------------------------
ID Type X Y Z
(-) (-) (m) (m) (m)
1 Connect {p1} -243.72632411372282
2 Coupled {p2} -3.636762830393616
3 Fixed {p3} -391.1306916880583
4 Fixed {p4} -391.1306916880583
--------------------- LINES --------------------------------------------
ID NodeA NodeB Outputs
(-) (-) (-) (-)
1 2 1 -
2 1 3 -
3 1 4 -
--------------------- SECTIONS -----------------------------------------
LineID LineType Length NumSegs
(-) (-) (m) (-)
1 c1 383.1443798528323 {n1}
2 c2 911.6709117895668 {n2}
3 c2 915.0868828891583 {n3}
--------------------- OPTIONS ------------------------------------------
391.1306916880583 WtrDpth
68564.77991863908 kBot
0.01 dtM
0.02 TMax
--------------------- OUTPUTS ------------------------------------------
Point1px
Point1py
Point1pz
--------------------- need this line -----------------------------------
"""

XY = [(-15.372812272073247, -9.211690291294737), (-33.33826322302139, -226.49112604239878),
      (824.7662044985119, -134.65675642308003), (-733.8644971516716, 386.4080560971254)]
BALANCE = (-46.28, -215.17, -385.52)


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
    cases = [(dx, 1, 1.5) for dx in (0.0, 0.5, 7.0, 50.0)] + [(0.0, 2, 0.5)]
    for dx, f, tol in cases:
        pts = {"p%d" % (k + 1): "%r %r" % (x + dx, y) for k, (x, y) in enumerate(XY)}
        name = "connect_%g_%d" % (dx, f)
        deck = out / (name + ".dat")
        deck.write_text(DECK.format(n1=35 * f, n2=34 * f, n3=33 * f, **pts), encoding="utf-8", newline="\n")
        root = out / name
        p = subprocess.run([a.exe, str(deck), str(root)], capture_output=True, text=True, env=env, cwd=str(out))
        if p.returncode != 0:
            failures.append("shift %g, mesh x%d: exit %d: %s" % (dx, f, p.returncode, (p.stdout + p.stderr)[-300:]))
            continue
        rows = Path(str(root) + ".out").read_text(encoding="utf-8").splitlines()
        x, y, z = [float(v) for v in rows[2].split()[1:4]]
        d = math.dist((x - dx, y, z), BALANCE)
        if d > tol:
            failures.append("shift %g, mesh x%d: point %.3f m from the balance (limit %.1f m)" % (dx, f, d, tol))
    print("connect point balance: %d runs, %d failures" % (len(cases), len(failures)))
    for m in failures:
        print("FAIL:", m)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
