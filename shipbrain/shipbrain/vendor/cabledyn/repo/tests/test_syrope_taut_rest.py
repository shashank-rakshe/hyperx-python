#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""A taut single-section Syrope rope whose tension varies along it starts at rest.

Three deep, inclined polyester ropes (481, 850 and 991 m, 330 to 750 m of water) carry their
weight, so the tension falls by up to 15 % from fairlead to anchor. The static start took one
secant EA from the working curve at the rope's mean strain: the elements away from the mean
started off their curve and their slow strains settled the rope at rest (the fairlead tension
moved by 1.2e-4 to 6.1e-4 in 1 s). Each rope, held at rest for 1 s, must keep its end tensions
at their static values to 1e-6.

usage: test_syrope_taut_rest.py --exe <cabledyn> --output <dir>
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

SETTINGS = """syrope_owc.dat  OWC
EXP             WCType
0.20            k1
1.50            k2
"""

DECK = """--------------------- CableDyn Input File ------------------------------------
Taut polyester rope in deep water, held at rest
--------------------- LINE TYPES ---------------------------------------
TypeName Diam Mass EA BA EI Cd_n Cd_t Ca_n Ca_t
(-) (m) (kg/m) (N) (N-s) (N-m2) (-) (-) (-) (-)
rope 0.1438 26.8406 SYROPE:syrope_settings.dat|{alpha}|{beta} {bas}|{bad} 0.0 1.2 0.2 1.0 0.0
--------------------- POINTS -------------------------------------------
ID Type X Y Z
(-) (-) (m) (m) (m)
1 Coupled {a}
2 Fixed {b}
--------------------- LINES --------------------------------------------
ID NodeA NodeB Outputs
(-) (-) (-) (-)
1 1 2 -
--------------------- SECTIONS -----------------------------------------
LineID LineType Length NumSegs
(-) (-) (m) (-)
1 rope {length} {n}
--------------------- OPTIONS ------------------------------------------
{depth} WtrDpth
{kbot} kBot
0.01 dtM
1.0 TMax
--------------------- OUTPUTS ------------------------------------------
FairTen1
AnchTen1
--------------------- need this line -----------------------------------
"""

ROPES = [
    dict(alpha="1.83494e8", beta="15.9308", bas="2.28256e10", bad="4.81630e5", a="6.0913 -27.1467 -4.6733",
         b="185.5774 -660.5800 -751.7888", length="990.9851", n=20, depth="751.7888", kbot="1.829e5"),
    dict(alpha="1.89709e8", beta="16.1960", bas="1.31046e9", bad="7.86974e5", a="-6.0871 -36.8963 -4.5814",
         b="-360.0368 -124.1505 -328.1981", length="481.3015", n=10, depth="328.1981", kbot="4.494e5"),
    dict(alpha="2.67068e8", beta="15.9927", bas="1.06925e10", bad="2.82844e5", a="14.7149 -33.3903 -4.1781",
         b="-60.8938 -595.2920 -643.3068", length="849.5532", n=13, depth="643.3068", kbot="1.616e5"),
]


# A short vertical rope on a strongly concave curve, T = 1e6 eps^0.4: its secant lies far above
# its tangent, so the per-element tension update overshoots the curve's crossing and reverses
# (it cycled between about 108 and 560 kN and the statics failed); the reversed updates take
# the secant step, and the rope must start at rest in its weight's equilibrium.
CONCAVE = dict(alpha="1.0e8", beta="15.9308", bas="2.28256e10", bad="4.81630e5", a="0.0 0.0 -29.6",
               b="0.0 0.0 -50.0", length="20.0", n=2, depth="50.0", kbot="1.0e5")


def concave_table() -> str:
    rows = ["Strain Tension", "(-) (N)"]
    for k in range(61):
        rows.append("%r %r" % (0.001 * k, 1.0e6 * (0.001 * k) ** 0.4))
    return "\n".join(rows) + "\n"


def owc_table() -> str:
    rows = ["Strain Tension", "(-) (N)"]
    for k in range(30):
        rows.append("%r %r" % (0.00206897 * k, 1.71768e5 * k * (1.0 - 0.012 * k)))
    return "\n".join(rows) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--output", required=True)
    a = ap.parse_args()
    out = Path(a.output)
    out.mkdir(parents=True, exist_ok=True)
    (out / "syrope_settings.dat").write_text(SETTINGS, encoding="utf-8", newline="\n")
    (out / "syrope_owc.dat").write_text(owc_table(), encoding="utf-8", newline="\n")
    (out / "syrope_settings_concave.dat").write_text(SETTINGS.replace("syrope_owc.dat", "syrope_owc_concave.dat"),
                                                     encoding="utf-8", newline="\n")
    (out / "syrope_owc_concave.dat").write_text(concave_table(), encoding="utf-8", newline="\n")
    env = dict(os.environ)
    env.setdefault("OPENBLAS_NUM_THREADS", "1")
    failures = []
    cases = [("rope_%d" % k, DECK.format(**rope)) for k, rope in enumerate(ROPES)]
    cases.append(("rope_concave", DECK.format(**CONCAVE).replace("syrope_settings.dat", "syrope_settings_concave.dat")))
    for name, text in cases:
        deck = out / (name + ".dat")
        deck.write_text(text, encoding="utf-8", newline="\n")
        root = out / name
        p = subprocess.run([a.exe, str(deck), str(root)], capture_output=True, text=True, env=env, cwd=str(out))
        if p.returncode != 0:
            failures.append("%s: exit %d: %s" % (name, p.returncode, (p.stdout + p.stderr)[-300:]))
            continue
        rows = Path(str(root) + ".out").read_text(encoding="utf-8").splitlines()
        vals = [[float(v) for v in r.split()] for r in rows[2:] if r.strip()]
        for j, ch in ((1, "FairTen1"), (2, "AnchTen1")):
            t0 = vals[0][j]
            drift = max(abs(v[j] - t0) for v in vals) / abs(t0)
            if drift > 1.0e-6:
                failures.append("%s: %s drifts by %.3e of its static value" % (name, ch, drift))
    print("taut Syrope ropes at rest: %d ropes, %d failures" % (len(cases), len(failures)))
    for f in failures:
        print("FAIL:", f)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
