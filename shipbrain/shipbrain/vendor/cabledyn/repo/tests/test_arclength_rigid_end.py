#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""A clamped (Rigid) finite-EI line in a strong current follows its drag path past a limit point.

A 2982 m cable hangs from a fairlead 1300 m above a soft seabed, clamped there (Rigid End A), in
a 1.1 m/s current that carries its grounded run 34 m past the anchor, where it folds back (a
hairpin). The drag load steps stall at a limit point in the drag fraction; the pseudo-arclength
continuation that follows the path around such a point was skipped for a line with a Rigid end,
and the statics failed, while the same line with a rotational spring of 1e9 N m/rad, or pinned,
solved. The Rigid line must solve, with end tensions within 1e-3 of the stiff-spring line's.

usage: test_arclength_rigid_end.py --exe <cabledyn> --output <dir>
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

DECK = """--------------------- CableDyn Input File ------------------------------------
Clamped cable in a strong current, folded back past its anchor
--------------------- LINE TYPES ---------------------------------------
TypeName Diam Mass EA BA EI Cd_n Cd_t Ca_n Ca_t
(-) (m) (kg/m) (N) (N-s) (N-m2) (-) (-) (-) (-)
t1 0.220140427337277 98.69067167615302 1404666756.1903045 -1.0 28098.621431099004 1.2 0.01 1.0 0.0
--------------------- POINTS -------------------------------------------
ID Type X Y Z
(-) (-) (m) (m) (m)
1 Coupled -86.22983517581444 29.680326533513522 -18.41049814550798
2 Fixed 1829.3161686664414 -108.94426352048342 -1300.878186612071
--------------------- LINES --------------------------------------------
ID NodeA NodeB Outputs
(-) (-) (-) (-)
1 1 2 -
--------------------- SECTIONS -----------------------------------------
LineID LineType Length NumSegs
(-) (-) (m) (-)
1 t1 2982.4084481132636 100
--------------------- END CONNECTIONS -------------------------------
LineID End Stiffness EzX EzY EzZ
(-) (-) (N-m/rad) (-) (-) (-)
1 A {k} 0.9264201469208807 0.154631906329435 -0.343270571013623
--------------------- OPTIONS ------------------------------------------
1300.878186612071 WtrDpth
6413.910151738813 kBot
0.02 dtM
0.0 TMax
uniform 1.12 -0.2 0.0 current
--------------------- OUTPUTS ------------------------------------------
FairTen1
AnchTen1
--------------------- need this line -----------------------------------
"""


def run(exe: str, out: Path, k: str) -> list:
    name = "clamped_%s" % k.replace(".", "p")
    deck = out / (name + ".dat")
    deck.write_text(DECK.format(k=k), encoding="utf-8", newline="\n")
    root = out / name
    env = dict(os.environ)
    env.setdefault("OPENBLAS_NUM_THREADS", "1")
    p = subprocess.run([exe, str(deck), str(root)], capture_output=True, text=True, env=env, cwd=str(out))
    if p.returncode != 0:
        raise RuntimeError("End A %s: exit %d: %s" % (k, p.returncode, (p.stdout + p.stderr)[-400:]))
    rows = Path(str(root) + ".out").read_text(encoding="utf-8").splitlines()
    return [float(v) for v in rows[2].split()[1:3]]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--output", required=True)
    a = ap.parse_args()
    out = Path(a.output)
    out.mkdir(parents=True, exist_ok=True)
    failures = []
    try:
        rigid = run(a.exe, out, "Rigid")
        spring = run(a.exe, out, "1.0e9")
        for r, s, ch in zip(rigid, spring, ("FairTen1", "AnchTen1")):
            if abs(r - s) > 1.0e-3 * spring[0]:
                failures.append("%s %.6e (Rigid) against %.6e (1e9 N m/rad spring)" % (ch, r, s))
    except RuntimeError as ex:
        failures.append(str(ex))
    print("clamped cable in a strong current: %d failures" % len(failures))
    for f in failures:
        print("FAIL:", f)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
