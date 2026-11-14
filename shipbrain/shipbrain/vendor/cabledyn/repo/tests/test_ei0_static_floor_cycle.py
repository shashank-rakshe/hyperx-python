#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""An EI = 0 static solve whose residual cycles inside its round-off floor is converged.

A suspended three-section line (wire, then two polyester sections, 1151 m, 316 elements) hangs
between a fairlead and an anchor 693 m below it in a 0.67 m/s uniform current. The slack-capable
static stages bring the residual to about 1e-4 N, inside the round-off floor of its nodal forces
(3e-3 N) and above the relative tolerance (2.6e-5 N). Depending on the last digits of the
coordinates the iterates then settle on one value (flat, converged) or alternate between two
(9.49e-5 and 8.77e-5 N), which the flat-stall test never saw: every stage ran out of iterations
and no equilibrium was found. The deck is translated by 32 small offsets, every one of which must
solve and give the same fairlead and anchor tensions to 1e-7.

usage: test_ei0_static_floor_cycle.py --exe <cabledyn> --output <dir>
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

DECK = """--------------------- CableDyn Input File ------------------------------------
Suspended three-section line in a uniform current
--------------------- LINE TYPES ---------------------------------------
TypeName Diam Mass EA BA EI Cd_n Cd_t Ca_n Ca_t
(-) (m) (kg/m) (N) (N-s) (N-m2) (-) (-) (-) (-)
t1 0.16489335960471715 135.94910020865282 2447083803.755751 -1.0 0.0 1.2 0.008 1.0 0.0
t2 0.07370991400051977 7.052224668855406 11019101.045086572 -0.8 0.0 2.0 0.4 1.1 0.15
t3 0.10037023217840212 13.076279295895747 20431686.399837103 -0.8 0.0 2.0 0.4 1.1 0.15
--------------------- POINTS -------------------------------------------
ID Type X Y Z
(-) (-) (m) (m) (m)
1 Coupled {xa!r} {ya!r} -67.45321271085669
2 Fixed {xb!r} {yb!r} -761.0028936967904
--------------------- LINES --------------------------------------------
ID NodeA NodeB Outputs
(-) (-) (-) (-)
1 1 2 -
--------------------- SECTIONS -----------------------------------------
LineID LineType Length NumSegs
(-) (-) (m) (-)
1 t1 296.3708154484327 127
1 t2 120.1220550938935 55
1 t3 734.2263766070876 134
--------------------- OPTIONS ------------------------------------------
uniform -0.6393706682921939 -0.20430951085352095 0.0 current
0.01 dtM
0.0 TMax
--------------------- OUTPUTS ------------------------------------------
FairTen1
AnchTen1
--------------------- need this line -----------------------------------
"""

A = (-239.01858425733275, -260.87547371415656)
B = (-732.1643435012232, -617.3791587315022)
DX = [0.0, 0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0]
DY = [0.0, 0.3, 3.0, 30.0]


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
    for dx in DX:
        for dy in DY:
            name = "shift_%g_%g" % (dx, dy)
            deck = out / (name + ".dat")
            deck.write_text(DECK.format(xa=A[0] + dx, ya=A[1] + dy, xb=B[0] + dx, yb=B[1] + dy), encoding="utf-8",
                            newline="\n")
            root = out / name
            p = subprocess.run([a.exe, str(deck), str(root)], capture_output=True, text=True, env=env,
                               cwd=str(out))
            if p.returncode != 0:
                failures.append("shift (%g, %g): exit %d: %s" % (dx, dy, p.returncode, (p.stdout + p.stderr)[-300:]))
                continue
            rows = Path(str(root) + ".out").read_text(encoding="utf-8").splitlines()
            vals = [float(v) for v in rows[2].split()[1:3]]
            if ref is None:
                ref = vals
            for v, r, ch in zip(vals, ref, ("FairTen1", "AnchTen1")):
                if abs(v - r) > 1.0e-7 * abs(ref[0]):
                    failures.append("shift (%g, %g): %s %.8e differs from %.8e" % (dx, dy, ch, v, r))
    print("translated line in a current: %d runs, %d failures" % (len(DX) * len(DY), len(failures)))
    for f in failures:
        print("FAIL:", f)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
