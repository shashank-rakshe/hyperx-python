# File: validation/scripts/l2_2_orcaflex_summary.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Reduce the L2-2 OrcaFlex fairlead-tension series to the summary values the gate checks.

The L2-2 dynamic chain gate (tests/test_l2_2_dynamic_parity.f90) compares CableDyn with the
OrcaFlex quasi-static-chain results that MoorDyn-C ships in its test suite
(``tests/Mooring/QuasiStatic/WD{0050,0200,0600}_Chain_ZZP1_{A1,A2}.txt``, BSD-3-Clause,
checked against MoorDyn-C v2.7.1). Each file holds 201 rows at t = 0, 0.1, ..., 20 s
(two periods of the 10 s ZZP1 heave); column 4 is the fairlead tension in kN.

CableDyn keeps only the summary of each series: mean, standard deviation, maximum and
minimum over the 201 samples, and the first three harmonics of the 0.1 Hz drive
(amplitude and phase, ``a_k cos(2 pi k t / 10 + phase_k)``, from the 200 samples of the two
whole periods). Mean plus the three harmonics reproduce each series to 1.5-7.4 % of its
peak-to-peak variation.

Usage:
  python validation/scripts/l2_2_orcaflex_summary.py <MoorDyn>/tests/Mooring/QuasiStatic
Writes tests/data/l2_2_dynamic_refs/orcaflex_summary.txt.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "tests" / "data" / "l2_2_dynamic_refs" / "orcaflex_summary.txt"
CELLS = [f"WD{d}_{a}" for d in ("0050", "0200", "0600") for a in ("A1", "A2")]
PERIOD, DT, NROW = 10.0, 0.1, 201

HEADER = """\
! File: tests/data/l2_2_dynamic_refs/orcaflex_summary.txt
! SPDX-License-Identifier: Apache-2.0
! L2-2 OrcaFlex fairlead-tension summary values (kN) for tests/test_l2_2_dynamic_parity.f90.
! Source: the OrcaFlex quasi-static-chain reference series distributed with MoorDyn-C
! (tests/Mooring/QuasiStatic/WD*_Chain_ZZP1_A*.txt, BSD-3-Clause; identical in v2.7.1),
! 201 samples at t = 0:0.1:20 s under the prescribed heave z = A sin(2 pi t / 10).
! Reduced by validation/scripts/l2_2_orcaflex_summary.py: mean, std (population), max and
! min over the 201 samples; harmonic k of the 0.1 Hz drive as a_k cos(2 pi k t / 10 + ph_k)
! from the 200 samples of the two whole periods (ph_k in degrees).
! cell       mean      std       max       min       a1        ph1       a2        ph2       a3        ph3
"""


def summarise(path: Path) -> list[float]:
    data = np.loadtxt(path, comments=("!", "#"))
    t, fair = data[:, 0], data[:, 3]
    if len(t) != NROW or np.max(np.abs(t - DT * np.arange(NROW))) > 1e-6:
        raise ValueError(f"{path}: expected {NROW} rows on the 0:{DT}:20 s grid")
    whole = fair[:-1] - np.mean(fair[:-1])
    row = [float(np.mean(fair)), float(np.std(fair)), float(np.max(fair)), float(np.min(fair))]
    for k in (1, 2, 3):
        z = 2.0 / len(whole) * np.sum(whole * np.exp(-2j * np.pi * k * t[:-1] / PERIOD))
        row += [float(abs(z)), float(np.degrees(np.angle(z)))]
    return row


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print(__doc__)
        return 2
    src = Path(argv[0])
    lines = [HEADER.rstrip("\n")]
    for cell in CELLS:
        depth, amp = cell.split("_")
        row = summarise(src / f"{depth}_Chain_ZZP1_{amp}.txt")
        lines.append(f"{cell:<10}" + "".join(f"{v:10.3f}" for v in row))
    OUT.write_text("\n".join(lines) + "\n", newline="\n")
    print(f"wrote {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
