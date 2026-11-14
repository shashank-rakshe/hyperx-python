#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""An EI = 0 line above the still-water level on a deck without a seabed carries its dry weight.

Without ``WtrDpth`` or a bathymetry an ``EI = 0`` line was modelled fully submerged (submerged
weight, drag and added mass up to an end above the surface, with a warning), while the same line
on a deck with a seabed, and a finite-EI line with or without one, took its dry weight above the
surface: a 50 m chain hung 10 m above the surface was 13 % light.

Gates, on the driver's own output (``Point<P>Fz``, ``Point<P>pz``):

1. a chain wholly above the surface, no seabed: its end forces sum to its weight in air (to
   1e-6), at the start and after 2 s;
2. a chain that sags through the surface: the deck without a seabed and the same deck with a
   seabed far below give the same end forces (to 1e-9), at the start and after 2 s;
3. a 50 t ``Connect`` clump hung by two chains from points 15 m above the surface, no seabed: it
   starts where the deck with a seabed far below starts it (to 1e-9 m) and holds that position
   over 2 s (to 1e-6 m), the static start being the march's equilibrium;
4. no "modelled fully submerged" warning.

usage: test_no_seabed_surface.py --exe <cabledyn> --output <dir>
"""

from __future__ import annotations

import argparse
import math
import subprocess
import sys
from pathlib import Path

G = 9.80665
RHO = 1025.0
DIAM = 0.2791
MASS = 480.93

HEAD = """--------------------- CableDyn Input File ------------------------------------
{title}
--------------------- LINE TYPES ---------------------------------------
TypeName   Diam     MassDenInAir   EA         BA/-zeta   EI       Cd_n  Cd_t  Ca_n  Ca_t
(-)        (m)      (kg/m)         (N)        (N-s/-)    (N-m^2)  (-)   (-)   (-)   (-)
chain      0.2791   480.93         2.058e9    -1.0       0.0      1.37  0.64  1.0   0.0
--------------------- POINTS -------------------------------------------
ID    Type      X        Y      Z         Mass    Vol     CdA    Ca
(-)   (-)       (m)      (m)    (m)       (kg)    (m^3)   (m^2)  (-)
{points}
--------------------- LINES --------------------------------------------
ID    NodeA   NodeB   Outputs
(-)   (-)     (-)     (-)
{lines}
--------------------- SECTIONS -----------------------------------------
LineID   LineType   Length   NumSegs
(-)      (-)        (m)      (-)
{sections}
--------------------- OPTIONS ------------------------------------------
9.80665      g
1025.0       rhoW
{seabed}0.01         dtM
2.0          TMax
--------------------- OUTPUTS ------------------------------------------
{outputs}
--------------------- need this line -----------------------------------
"""


def deck(title: str, points: str, lines: str, sections: str, outputs: list[str], seabed: bool) -> str:
    return HEAD.format(
        title=title,
        points=points,
        lines=lines,
        sections=sections,
        seabed="300.0        WtrDpth\n" if seabed else "",
        outputs="\n".join(f'"{c}"' for c in outputs),
    )


def run(exe: str, out: Path, name: str, text: str) -> tuple[dict[str, list[float]], str]:
    path = out / f"{name}.dat"
    path.write_text(text, encoding="utf-8", newline="\n")
    root = out / name
    p = subprocess.run([exe, str(path), str(root)], capture_output=True, text=True, check=False)
    log = p.stdout + p.stderr
    if p.returncode != 0:
        raise RuntimeError(f"{name}: exit {p.returncode}: {log[-600:]}")
    rows = []
    header: list[str] = []
    for line in Path(f"{root}.out").read_text(encoding="utf-8").splitlines():
        fields = line.split()
        if not fields:
            continue
        if fields[0].startswith("Time"):
            header = fields
            continue
        try:
            rows.append([float(v) for v in fields])
        except ValueError:
            continue
    cols = {h: [r[i] for r in rows] for i, h in enumerate(header)}
    return cols, log


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)
    failures = []
    logs = []

    two_points = "1     Coupled   0.0      0.0    10.0      0       0       0      0\n" \
                 "2     Fixed     40.0     0.0    10.0      0       0       0      0"
    one_line = "1     1       2       -"

    # 1. wholly above the surface: the end forces carry the weight in air
    cols, log = run(args.exe, out, "above", deck(
        "EI = 0 chain wholly above the still-water level, no seabed", two_points, one_line,
        "1        chain      42.0     20", ["Point1Fz", "Point2Fz"], seabed=False))
    logs.append(log)
    dry = 42.0 * MASS * G
    for k in (0, -1):
        total = -(cols["Point1Fz"][k] + cols["Point2Fz"][k])
        rel = abs(total - dry) / dry
        print(f"gate 1: t = {cols['Time(s)'][k]:.2f} s: end forces {total:.3f} N, weight in air {dry:.3f} N, "
              f"relative {rel:.2e}")
        if rel > 1.0e-6:
            failures.append(f"gate 1: the end forces {total} N are not the weight in air {dry} N")

    # 2. through the surface: no seabed and a seabed far below agree
    res = {}
    for sb in (False, True):
        cols, log = run(args.exe, out, f"pierce_{'seabed' if sb else 'none'}", deck(
            "EI = 0 chain sagging through the still-water level", two_points, one_line,
            "1        chain      50.0     20", ["Point1Fz", "Point2Fz"], seabed=sb))
        logs.append(log)
        res[sb] = cols
    wet = 50.0 * (MASS - RHO * math.pi / 4.0 * DIAM**2) * G
    for k in (0, -1):
        a = res[False]["Point1Fz"][k] + res[False]["Point2Fz"][k]
        b = res[True]["Point1Fz"][k] + res[True]["Point2Fz"][k]
        rel = abs(a - b) / abs(b)
        print(f"gate 2: t = {res[True]['Time(s)'][k]:.2f} s: no seabed {-a:.3f} N, seabed {-b:.3f} N "
              f"(weight in water {wet:.0f} N), relative {rel:.2e}")
        if rel > 1.0e-9:
            failures.append(f"gate 2: no seabed {-a} N against seabed {-b} N")

    # 3. a Connect clump hung above the surface
    clump = "1     Fixed    -25.0     0.0    15.0      0       0       0      0\n" \
            "2     Connect   0.0      0.0    5.0       50000.0 2.0     0      0\n" \
            "3     Fixed     25.0     0.0    15.0      0       0       0      0"
    two_lines = "1     1       2       -\n2     3       2       -"
    two_secs = "1        chain      30.0     15\n2        chain      30.0     15"
    res = {}
    for sb in (False, True):
        cols, log = run(args.exe, out, f"clump_{'seabed' if sb else 'none'}", deck(
            "50 t Connect clump hung by two chains above the still-water level", clump, two_lines, two_secs,
            ["Point2pz"], seabed=sb))
        logs.append(log)
        res[sb] = cols["Point2pz"]
    d0 = abs(res[False][0] - res[True][0])
    drift = max(abs(z - res[False][0]) for z in res[False])
    print(f"gate 3: clump start z {res[False][0]:.9f} m (seabed deck {res[True][0]:.9f} m, {d0:.1e} m apart), "
          f"largest move over 2 s {drift:.1e} m")
    if d0 > 1.0e-9:
        failures.append(f"gate 3: the clump starts {d0} m from the seabed deck's start")
    if drift > 1.0e-6:
        failures.append(f"gate 3: the clump moves {drift} m from its static start")

    # 4. the warning of the old model
    if any("modelled fully submerged" in log for log in logs):
        failures.append("gate 4: a 'modelled fully submerged' warning is printed")

    for f in failures:
        print("FAIL: " + f)
    if not failures:
        print("PASS: an EI = 0 line above the surface carries its dry weight without a seabed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
