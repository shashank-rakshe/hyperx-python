#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""The static residual-floor note names a residual above the tolerance it says was missed.

A two-section finite-EI line restrained in torsion (pinned in bending at its fairlead, clamped
at its anchor, 9.7 deg of imposed twist) is polished at the tight static tolerance, which does
not converge, and again at the coupled static tolerance 1e-6, whose last Newton step lands at a
relative residual of 6.9e-9, below the tight 1e-8. The run printed "static residual
floor above the dynamic tolerance 1.00E-08; equilibrium accepted at the relative residual
6.91E-09". Every such note must report a residual above its tolerance, and this run none.

usage: test_static_floor_note.py --exe <cabledyn> --output <dir>
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

DECK = """--------------------- CableDyn Input File ------------------------------------
Two-section finite-EI line restrained in torsion
--------------------- LINE TYPES ---------------------------------------
TypeName Diam Mass EA BA EI GAs GJ Irt Irn Cd_n Cd_t Ca_n Ca_t
(-) (m) (kg/m) (N) (N-s) (N-m2) (-) (-) (-) (-)
t1 0.11958934169215762 24.223380558396716 819311396.4530731 -1.0 13696.958265809739 315119767.8665666 \
15490.529253648816 0.021652084830305268 0.043304169660610535 1.2 0.01 1.0 0.0
t2 0.2138970906163321 85.11251138269321 1087874573.7545362 -1.0 2845.9411357014956 418413297.5978985 \
3005.149240256559 0.2433790421053965 0.486758084210793 1.2 0.01 1.0 0.0
--------------------- POINTS -------------------------------------------
ID Type X Y Z
(-) (-) (m) (m) (m)
1 Coupled -22.067725644878863 -43.46036418329759 -11.351640609291547
2 Fixed 155.09096486699008 -43.46036418329759 -231.01460743349267
--------------------- LINES --------------------------------------------
ID NodeA NodeB Outputs
(-) (-) (-) (-)
1 1 2 -
--------------------- SECTIONS -----------------------------------------
LineID LineType Length NumSegs
(-) (-) (m) (-)
1 t1 246.90435544324012 56
1 t2 99.25397277211934 56
--------------------- END CONNECTIONS -------------------------------
LineID End Stiffness EzX EzY EzZ TorsStiffness NxX NxY NxZ Pretwist
(-) (-) (N-m/rad) (-) (-) (-) (N-m/rad) (-) (-) (-) (deg)
1 A Pinned 0.5000000000000001 0.0 -0.8660254037844386 Rigid 0.0 1.0 0.0 0.0
1 B Rigid 1.0 0.0 0.0 Rigid 0.0 1.0 0.0 9.686369916584601
--------------------- OPTIONS ------------------------------------------
0.01 dtM
0.0 TMax
--------------------- OUTPUTS ------------------------------------------
FairTen1
Twist1
--------------------- need this line -----------------------------------
""".replace("\\\n", "")

NOTE = re.compile(r"static residual floor above the dynamic tolerance\s+(\S+); equilibrium accepted at the "
                  r"relative residual\s+(\S+)\.")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--output", required=True)
    a = ap.parse_args()
    out = Path(a.output)
    out.mkdir(parents=True, exist_ok=True)
    deck = out / "twisted.dat"
    deck.write_text(DECK, encoding="utf-8", newline="\n")
    env = dict(os.environ)
    env.setdefault("OPENBLAS_NUM_THREADS", "1")
    p = subprocess.run([a.exe, str(deck), str(out / "twisted")], capture_output=True, text=True, env=env,
                       cwd=str(out))
    log = p.stdout + p.stderr
    failures = []
    if p.returncode != 0:
        failures.append("exit %d: %s" % (p.returncode, log[-400:]))
    for tol, res in NOTE.findall(log):
        if float(res) <= float(tol):
            failures.append("floor note with a residual %s at or below its tolerance %s" % (res, tol))
    print("static floor note: %d failures" % len(failures))
    for f in failures:
        print("FAIL:", f)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
