#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Hydrodynamics of a Syrope polyester line against MoorDyn-C.

A taut 88.5 m polyester line (D 0.203 m, 40 kg/m, 20 segments, Cd 1.2, Ca 1.0) from an anchor at
60 m depth to a fairlead at 20 m depth, 80 m away, with MoorDyn-C's linear working curve
(k1 1.25e8 N) over an OWC table T = 8.5e7 eps + 1.1e9 eps^2 N, alpha 1.53e8 N, beta 23.12,
BA_s|BA_d 5e10|1e5 N s and a SYROPE IC history (Tmax0 1.2 MN). The fairlead sways
2 sin(2 pi t/8) m across the line. MoorDyn-C v2.7.2 (RK2, dtM 5e-4 s; a driver that prescribes
the coupled point) gives a fairlead tension of 1 009 228.1 N at t = 0 and, over 24-40 s, a mean
of 1 029 671.6 N and a range of 44 782.4 N. Gates, CableDyn at dtM 0.01 s:

* the fairlead tension at t = 0 and its mean over 24-40 s within 1e-5 of MoorDyn-C's, and its
  range within 0.2 %;
* the line's drag and added mass act: without them (Cd = Ca = 0) the range grows by more
  than 2 %;
* a cross current deflects the static start (mid-span 0.12 m) and holds the line still;
* VIV (Cl 0.8) in the current lifts the line (LINES Outputs flag V) and moves its tension;
* deck waves move the tension of the line held still.

usage: test_syrope_hydro.py --exe <cabledyn> --output <dir>
"""

from __future__ import annotations

import argparse
import math
import os
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np

MDC_T0, MDC_MEAN, MDC_RANGE = 1009228.1, 1029671.6, 44782.4
FAILURES: list[str] = []


def check(ok: bool, message: str) -> None:
    print(("PASS: " if ok else "FAIL: ") + message)
    if not ok:
        FAILURES.append(message)


def deck(hydro: str = "1.2 1.0 0.0 0.0", flags: str = "-", options: str = "", tmax: float = 40.0,
         motion: bool = True) -> str:
    return f"""--------------------- CableDyn Input File ---
Syrope polyester line with hydrodynamics
---------------------- LINE TYPES ----------------------------------
LineType Diam MassDenInAir EA BA/-zeta EI Cd Ca CdAx CaAx
(-) (m) (kg/m) (N) (N-s/-) (N-m^2) (-) (-) (-) (-)
poly 0.203 40 SYROPE:syrope.dat|1.53e8|23.12 5.0e10|1.0e5 0.0 {hydro}
---------------------- POINTS --------------------------------------
Node Type X Y Z M V CdA CA
(-) (-) (m) (m) (m) (kg) (m^3) (m^2) (-)
1 Fixed 0 0 -60 0 0 0 0
2 Coupled 80 0 -20 0 0 0 0
---------------------- LINES ---------------------------------------
Line LineType NodeA NodeB UnstrLen NumSegs Outputs
(-) (-) (-) (-) (m) (-) (-)
1 poly 2 1 88.5 20 {flags}
---------------------- SYROPE IC ----------------------------------
Line(s) Tmax0 Tmean0
(-) (N) (N)
1 1.2e6 1.0313e6
---------------------- OPTIONS -----------------------------------
9.80665  g
1025     rhoW
100      WtrDpth
{options}0.01   dtM
{tmax}   TMax
{"motion.txt motionFile" if motion else ""}
---------------------- OUTPUTS -----------------------------------
FairTen1
L1N11PY
END
---------------------- need this line ----------------------------
"""


def run(exe: str, out: Path, name: str, text: str) -> tuple[list[str], np.ndarray] | None:
    (out / f"{name}.dat").write_text(text, encoding="utf-8", newline="\n")
    proc = subprocess.run([exe, f"{name}.dat", name], cwd=out, capture_output=True, text=True,
                          env=dict(os.environ, OMP_NUM_THREADS="1"))
    check(proc.returncode == 0, f"{name}: the run completes (exit {proc.returncode})")
    if proc.returncode != 0:
        print(proc.stdout[-1500:], proc.stderr[-1500:])
        return None
    return table(out / f"{name}.out")


def table(path: Path) -> tuple[list[str], np.ndarray]:
    lines = path.read_text().splitlines()
    head = next(i for i, line in enumerate(lines) if line.startswith("Time"))
    data = np.array([[float(v) for v in line.split()] for line in lines[head + 1:]
                     if line.strip() and not line.lstrip().startswith("(")])
    return lines[head].split("\t"), data


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    out = Path(args.output)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    eps = np.linspace(0.0, 0.06, 31)
    (out / "owc.dat").write_text("Strain Tension\n(-) (N)\n" + "\n".join(
        f"{e:.6e} {8.5e7 * e + 1.1e9 * e * e:.6e}" for e in eps))
    (out / "syrope.dat").write_text("owc.dat  OWC\nLINEAR      WCType\n1.25e8      k1\n0.0         k2\n")
    w = 2.0 * math.pi / 8.0
    (out / "motion.txt").write_text("# time point x y z vx vy vz ax ay az\n" + "\n".join(
        f"{k * 0.01:.6f} 2 80 {2 * math.sin(w * k * 0.01):.12e} -20 0 {2 * w * math.cos(w * k * 0.01):.12e} 0 "
        f"0 {-2 * w * w * math.sin(w * k * 0.01):.12e} 0" for k in range(4001)) + "\n")

    sway = run(args.exe, out, "sway", deck())
    if sway:
        t, ten = sway[1][:, 0], sway[1][:, sway[0].index("FairTen1")]
        win = ten[(t >= 24.0) & (t <= 40.0)]
        t0, mean, span = float(ten[0]), float(win.mean()), float(np.ptp(win))
        check(abs(t0 - MDC_T0) <= 1.0e-5 * MDC_T0, f"fairlead tension at t = 0: {t0:.1f} N, MoorDyn-C {MDC_T0} N")
        check(abs(mean - MDC_MEAN) <= 1.0e-5 * MDC_MEAN,
              f"mean fairlead tension over 24-40 s: {mean:.1f} N, MoorDyn-C {MDC_MEAN} N")
        check(abs(span - MDC_RANGE) <= 2.0e-3 * MDC_RANGE,
              f"fairlead tension range over 24-40 s: {span:.1f} N, MoorDyn-C {MDC_RANGE} N")
        dry = run(args.exe, out, "sway_dry", deck(hydro="0.0 0.0 0.0 0.0"))
        if dry:
            td, tend = dry[1][:, 0], dry[1][:, dry[0].index("FairTen1")]
            dspan = float(np.ptp(tend[(td >= 24.0) & (td <= 40.0)]))
            check(dspan > 1.02 * span, f"without drag and added mass the range grows: {dspan:.1f} N against "
                  f"{span:.1f} N")

    current = "uniform 0.0 1.0 0.0 current\n"
    cur = run(args.exe, out, "current", deck(options=current, tmax=10.0, motion=False))
    if cur:
        y = cur[1][:, cur[0].index("L1N11PY")]
        ten = cur[1][:, cur[0].index("FairTen1")]
        check(y[0] > 0.1 and np.ptp(y) < 1.0e-6 and np.ptp(ten) < 1.0,
              f"a 1 m/s cross current deflects the static start (mid-span {y[0]:.3f} m) and holds it")
    viv = run(args.exe, out, "viv", deck(hydro="1.2 1.0 0.0 0.0 0.8", flags="V", options=current, tmax=20.0,
                                         motion=False))
    if viv:
        ten = viv[1][:, viv[0].index("FairTen1")]
        names, lift = table(out / "viv.Line1.V.out")
        lz = lift[:, names.index("Node11LiftZ(N)")]
        check(lz.std() > 50.0 and ten.std() > 100.0,
              f"VIV in the current: mid-span lift std {lz.std():.1f} N, fairlead tension std {ten.std():.1f} N")
    waves = run(args.exe, out, "waves", deck(options="airy 4.0 8.0 0.0 waves\n", tmax=16.0, motion=False))
    if waves:
        ten = waves[1][:, waves[0].index("FairTen1")]
        check(ten.std() > 10.0, f"deck waves move the tension of the held line (std {ten.std():.1f} N)")
    print(f"{len(FAILURES)} failure(s)")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
