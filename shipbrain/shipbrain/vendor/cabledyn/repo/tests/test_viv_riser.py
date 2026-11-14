#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Cross-flow VIV of the catenary riser of Thorsen et al., MoorDyn-C's VIV test case.

MoorDyn-C (tests/Mooring/viv/viv.txt): a 23.71 m riser model (D 0.024 m, 0.69 kg/m, EA 6.66e5 N,
EI 10.5 N m^2, 100 segments) from the seabed at 10 m depth to 1 m below the surface, in a uniform
0.2 m/s current in its plane, Cl 0.7 with MoorDyn's band. The cross-flow response, out of the
plane, locks in at the measured 1.04 Hz, so the fairlead tension oscillates at twice that: a
period of 1/(2 x 1.04 Hz) = 0.4808 s. The deck is written anchor first, as MoorDyn's, so it also
exercises the phase seed counted from the deck's End A on a line the reader turns around.

MoorDyn-C v2.7.2 (RK4, dtM 1e-4 s) over 20-40 s: mean fairlead tension 69.93 N, peak-to-peak
3.72 N, period 0.4811 s. Gates on CableDyn at dtM 1e-3 s over the same window:

* mean tension within 0.2 % of MoorDyn-C's;
* tension range (peak to peak) within 10 % of MoorDyn-C's;
* mean period within 1.5 % of the measured target and of MoorDyn-C's (the period converges to
  MoorDyn-C's with dtM: 0.4853, 0.4843, 0.4829 s at 1e-3, 5e-4, 2.5e-4 s).

usage: test_viv_riser.py --exe <cabledyn> --output <dir>
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np

TARGET = 1.0 / (2.0 * 1.04)
MDC_MEAN, MDC_RANGE, MDC_PERIOD = 69.93, 3.72, 0.4811
FAILURES: list[str] = []

DECK = """--------------------- CableDyn Input File ---
Thorsen et al. catenary riser in a uniform 0.2 m/s current (MoorDyn-C tests/Mooring/viv/viv.txt)
--------------------- LINE TYPES ---
LineType Diam MassDenInAir EA cIntDamp EI Cd Ca CdAx CaAx Cl
(-) (m) (kg/m) (N) (Pa-s) (N-m^2) (-) (-) (-) (-) (-)
cable 0.024 0.69 6.66e5 -1 10.5 1.2 2.0 0.08 0.08 0.7
--------------------- POINTS ---
Node Type X Y Z M V CdA Ca
(-) (-) (m) (m) (m) (kg) (m^3) (m2) ()
1 Fixed -21.0425 0 -10 0 0 0 0
2 Coupled 0 0 -1 0 0 0 0
--------------------- LINES ---
Line LineType NodeA NodeB UnstrLen NumSegs Outputs
(-) (-) (-) (-) (m) (-) (-)
1 cable 1 2 23.71 100 -
--------------------- OPTIONS ---
1000.0 rhoW
9.80665 g
10.0 WtrDpth
1.5e5 kBot
1.0e4 cBot
0.5 frictionMu
uniform 0.2 0 0 current
0.001 dtM
40.0 TMax
--------------------- OUTPUTS ---
FairTen1
END
--------------------- need this line ---
"""


def check(ok: bool, message: str) -> None:
    print(("PASS: " if ok else "FAIL: ") + message)
    if not ok:
        FAILURES.append(message)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    out = Path(args.output)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    (out / "riser.dat").write_text(DECK, encoding="utf-8", newline="\n")
    proc = subprocess.run([args.exe, "riser.dat", "riser"], cwd=out, capture_output=True, text=True,
                          env=dict(os.environ, OMP_NUM_THREADS="1"))
    check(proc.returncode == 0, f"the riser run completes (exit {proc.returncode})")
    if proc.returncode != 0:
        print(proc.stdout[-2000:], proc.stderr[-2000:])
        return 1
    lines = (out / "riser.out").read_text().splitlines()
    head = next(i for i, line in enumerate(lines) if line.split() and line.split()[0].startswith("Time"))
    data = np.array([[float(v) for v in line.split()] for line in lines[head + 1:]
                     if line.strip() and not line.lstrip().startswith("(")])
    t, ten = data[:, 0], data[:, lines[head].split().index("FairTen1")]
    w = (t > 20.0) & (t <= 40.0)
    tt, x = t[w], ten[w] - ten[w].mean()
    peaks = [i for i in range(1, len(x) - 1) if x[i] > x[i - 1] and x[i] >= x[i + 1] and x[i] > 0.0]
    period = float(np.mean(np.diff(tt[peaks])))
    mean, span = float(ten[w].mean()), float(np.ptp(ten[w]))
    check(abs(mean - MDC_MEAN) <= 0.002 * MDC_MEAN,
          f"mean fairlead tension {mean:.2f} N, MoorDyn-C {MDC_MEAN} N (within 0.2 %)")
    check(abs(span - MDC_RANGE) <= 0.10 * MDC_RANGE,
          f"tension range {span:.2f} N, MoorDyn-C {MDC_RANGE} N (within 10 %)")
    check(abs(period - TARGET) <= 0.015 * TARGET and abs(period - MDC_PERIOD) <= 0.015 * MDC_PERIOD,
          f"tension period {period:.4f} s: measured 1/(2 x 1.04 Hz) = {TARGET:.4f} s, MoorDyn-C "
          f"{MDC_PERIOD} s (within 1.5 %)")
    print(f"{len(FAILURES)} failure(s)")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
