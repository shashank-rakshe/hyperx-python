#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""A rod numbered as a body is not one of the body's points.

A ``Rod<N>A/B`` end point keeps its rod's id in the same field a ``Body<N>`` point keeps its
body's id. The body's attachment points must be its ``Body<N>`` points only, as they are
counted; a rod end point on a rod with the body's number, listed before the body's points, was
taken as the body's first point (and the list overran its allocation).

Gate, on the driver's own output files: a free Rigid6 body on three taut legs with a pinned arm
rod whose tip tether starts from an explicit rod end POINT listed first. The deck with the arm
as ``Rod1`` (the body's number) and the same deck with the arm as ``Rod3`` write identical
outputs, bit for bit (in 1 s the old code turned the arm 172 deg in pitch, the body 1.06 deg in
pitch and 0.14 m in surge, and the leg tension FairTen1 by 3.0 kN).

usage: test_body_rod_numbering.py --exe <cabledyn> --output <dir>
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

DECK = """--------------------- CableDyn Input File ------------------------------------
Rod numbered as the body: a free Rigid6 body, a pinned arm rod, a tether from the arm tip
--------------------- LINE TYPES ---------------------------------------
TypeName   Diam    MassDenInAir   EA          BA/-zeta   EI       Cd_n  Cd_t  Ca_n  Ca_t
(-)        (m)     (kg/m)         (N)         (N-s/-)    (N-m^2)  (-)   (-)   (-)   (-)
nylon      0.124   13.76          2.515288e6  -0.8       0.0      1.6   0.05  1.0   0.0
--------------------- ROD TYPES ----------------------------------------
Name     Diam    Mass     Cd     Ca     CdEnd  CaEnd
(-)      (m)     (kg/m)   (-)    (-)    (-)    (-)
arm      0.5     600.0    1.0    1.0    0.0    0.0
--------------------- BODIES -------------------------------------------
ID  Attachment  X0    Y0    Z0      r0     p0     y0     Mass     CG     I      Volume  CdA    Ca
(-) (-)         (m)   (m)   (m)     (deg)  (deg)  (deg)  (kg)     (m)    (kg-m^2)  (m^3) (m^2)  (-)
1   Free        3.0   0.0   -15.0   0.0    0.0    0.0    1.5e5    0.0    2.0e6  160.0   20|0   0.5
--------------------- RODS ---------------------------------------------
ID   RodType   Attachment    XA    YA    ZA     XB    YB    ZB      NumSegs   Outputs
(-)  (-)       (-)           (m)   (m)   (m)    (m)   (m)   (m)     (-)       (-)
{rod}    arm       Body1Pinned   0.0   0.0   -2.0   0.0   0.0   -12.0   5         -
--------------------- POINTS -------------------------------------------
ID    Type      X          Y          Z          Mass    Vol     CdA    Ca
(-)   (-)       (m)        (m)        (m)        (kg)    (m^3)   (m^2)  (-)
1     Rod{rod}B     0.0        0.0        0.0        0       0       0      0
2     Body1     3.0        0.0        0.0        0       0       0      0
3     Body1     -1.5       2.598076   0.0        0       0       0      0
4     Body1     -1.5       -2.598076  0.0        0       0       0      0
5     Fixed     150.0      0.0        -70.0      0       0       0      0
6     Fixed     -75.0      129.904    -70.0      0       0       0      0
7     Fixed     -75.0      -129.904   -70.0      0       0       0      0
8     Fixed     3.0        0.0        -70.0      0       0       0      0
--------------------- LINES --------------------------------------------
ID    LineType   AttachA   AttachB   UnstrLen   NumSegs   Outputs
(-)   (-)        (-)       (-)       (m)        (-)       (-)
1     nylon      2         5         150.0      40        -
2     nylon      3         6         150.0      40        -
3     nylon      4         7         150.0      40        -
4     nylon      1         8         42.0       12        -
--------------------- OPTIONS ------------------------------------------
9.80665   g
1025.0    rhoW
70.0      WtrDpth
0.005     dtM
1.0       TMax
deck      bodyIC
--------------------- OUTPUTS ------------------------------------------
"Body1Px"
"Body1Pz"
"Body1Ry"
"Rod{rod}Ry"
"Rod{rod}TenB"
"FairTen1"
"FairTen4"
--------------------- need this line -----------------------------------
"""


def run(exe: str, out: Path, rod: int) -> list[str]:
    deck = out / f"rod{rod}.dat"
    deck.write_text(DECK.replace("{rod}", str(rod)), encoding="utf-8", newline="\n")
    root = out / f"rod{rod}"
    p = subprocess.run(
        [exe, str(deck), str(root)], capture_output=True, text=True, check=False
    )
    if p.returncode != 0:
        print(p.stdout[-2000:] + p.stderr[-2000:])
        raise SystemExit(
            f"FAIL: the driver stopped on the Rod{rod} deck (exit {p.returncode})"
        )
    rows = (root.parent / (root.name + ".out")).read_text(encoding="utf-8").splitlines()
    return [r.replace(f"Rod{rod}", "Rod<N>") for r in rows]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)
    same = run(args.exe, out, 1)
    other = run(args.exe, out, 3)
    # the body moves (the deck pose is off its equilibrium), so a misread point shows
    heave = [float(r.split()[2]) for r in same[2:] if r.strip()]
    moved = max(heave) - min(heave)
    diff = sum(1 for a, b in zip(same, other) if a != b) + abs(len(same) - len(other))
    print(
        f"body heave range {moved:.3e} m; rows differing between Rod1 and Rod3: {diff} of {len(same)}"
    )
    failures = []
    if not moved > 1.0e-3:
        failures.append(
            "the body does not move, so the gate does not resolve a misread point"
        )
    if diff != 0:
        failures.append(
            "a rod numbered as the body changes the run (Rod1 and Rod3 decks differ)"
        )
    for f in failures:
        print("FAIL: " + f)
    if not failures:
        print("PASS: a rod numbered as the body is not one of the body's points")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
