#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Modal analysis (OPTION nModes) of a composite line against the two-section string.

A horizontal line 50 m deep, its ends 100 m apart, is built from two EI = 0 sections: 40 m of a
0.2 m line and 60 m of a 0.1 m line, each almost neutrally buoyant (its dry mass 1.00001 times
the displaced water), so the line hangs straight under its tension T (about 20 kN, set by the
stretch). With the normal added mass (Ca_n 1) the transverse mass per length of section i is
M_i = m_i + rhoW A_i, four times as large on the thick section, so the transverse wave travels
at c_i = sqrt(T/M_i) and twice as fast on the thin one. With y = sin(k1 x) on the first section
and sin(k2 (L - x)) on the second (k_i = omega/c_i), continuity of the displacement and of the
slope at the joint gives the natural frequencies as the roots of

    k2 sin(k1 L1) cos(k2 L2) + k1 cos(k1 L1) sin(k2 L2) = 0,

each twice, in the plane of the sag and out of it. The section lengths are the stretched ones
and the masses per stretched metre; T is the static FairTen1 of the run, which must equal
EA_i (l_i/L_i - 1) of each section (the static stretch, within 1e-6).

Gates, on 0.5 m and 0.25 m elements: the 16 lowest modes are the 8 lowest roots in pairs; on the
finer mesh every frequency is within 0.1 % of its root, and halving the element length cuts
the largest error by at least three (the lumped string converges at second order). The same
line as one uniform section (the thick line throughout, a root of k L = n pi) passes the same
gates, so the composite roots are not met by accident.

usage: test_composite_string_modes.py --exe <cabledyn> --output <dir>
"""

from __future__ import annotations

import argparse
import math
import subprocess
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))
from cabledyn import read_output  # noqa: E402

FAILURES: list[str] = []
RHO = 1025.0
SPAN = 100.0
STRETCH = 1.6e-3  # total static stretch of the line (m)
N_ROOTS = 8

DECK = """--------------------- CableDyn Input File ------------------------------------
composite string modes
--------------------- LINE TYPES ---------------------------------------
TypeName   Diam    MassDenInAir   EA        BA/-zeta   EI       Cd_n  Cd_t  Ca_n  Ca_t
(-)        (m)     (kg/m)         (N)       (N-s/-)    (N-m^2)  (-)   (-)   (-)   (-)
{types}
--------------------- POINTS -------------------------------------------
ID    Type      X        Y      Z         Mass    Vol     CdA    Ca
(-)   (-)       (m)      (m)    (m)       (kg)    (m^3)   (m^2)  (-)
1     Coupled   0.0      0.0    -50.0     0       0       0      0
2     Fixed     100.0    0.0    -50.0     0       0       0      0
--------------------- LINES --------------------------------------------
ID    NodeA   NodeB   Outputs
(-)   (-)     (-)     (-)
1     1       2       -
--------------------- SECTIONS -----------------------------------------
LineID   LineType   Length   NumSegs
(-)      (-)        (m)      (-)
{sections}
--------------------- OPTIONS ------------------------------------------
9.80665  g
1025.0   rhoW
200.0    WtrDpth
{modes}  nModes
--------------------- OUTPUTS ------------------------------------------
"FairTen1"
--------------------- need this line -----------------------------------
"""


def check(ok: bool, message: str) -> None:
    print(("PASS: " if ok else "FAIL: ") + message)
    if not ok:
        FAILURES.append(message)


class Section:
    def __init__(self, name: str, diameter: float, ea: float, length: float) -> None:
        self.name = name
        self.area = 0.25 * math.pi * diameter**2
        self.diameter = diameter
        self.mass = 1.00001 * RHO * self.area  # dry mass per unstretched metre
        self.ea = ea
        self.length = length  # stretched length at the static tension (m)


def unstretched(sections: list[Section]) -> list[float]:
    """Unstretched lengths whose stretch under one tension T totals STRETCH."""
    compliance = sum(s.length / s.ea for s in sections)
    tension = STRETCH / compliance
    return [s.length / (1.0 + tension / s.ea) for s in sections]


def run(exe: Path, folder: Path, sections: list[Section], h: float) -> tuple[float, np.ndarray]:
    """Static tension and natural frequencies (Hz) of the line on elements of length ~h."""
    folder.mkdir(parents=True, exist_ok=True)
    types = "\n".join(
        f"{s.name:10s} {s.diameter:.4f}  {s.mass:.6f}  {s.ea:.4e}  0.0  0.0  1.2  0.0  1.0  0.0"
        for s in sections
    )
    rows = "\n".join(
        f"1        {s.name:10s} {length:.9f}  {round(s.length / h)}"
        for s, length in zip(sections, unstretched(sections))
    )
    deck = folder / "deck.dat"
    deck.write_text(
        DECK.format(types=types, sections=rows, modes=2 * N_ROOTS), encoding="ascii", newline="\n"
    )
    result = subprocess.run(
        [str(exe), deck.name, str(folder / "run")],
        cwd=folder,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        check(False, f"{folder.name}: driver exit {result.returncode}\n{result.stderr[-2000:]}")
        return math.nan, np.array([])
    tension = float(read_output(folder / "run.out").column("FairTen1")[0])
    freqs = []
    for line in (folder / "run.modes.out").read_text().splitlines():
        parts = line.split()
        if line.startswith("#") or parts[:1] in (["LineID"], ["(-)"]):
            if line.startswith("# Mode shapes"):
                break
            continue
        if len(parts) == 5:
            freqs.append(float(parts[2]))
    return tension, np.array(freqs)


def bisect(function, low: float, high: float) -> float:
    """The root of function between low and high, where it changes sign, to round-off."""
    f_low = function(low)
    for _ in range(200):
        middle = 0.5 * (low + high)
        f_middle = function(middle)
        if f_middle == 0.0 or high - low <= 1.0e-15 * high:
            return middle
        if (f_middle < 0.0) == (f_low < 0.0):
            low, f_low = middle, f_middle
        else:
            high = middle
    return 0.5 * (low + high)


def roots(sections: list[Section], tension: float) -> np.ndarray:
    """The N_ROOTS lowest roots (Hz) of the fixed-fixed string of the stretched sections."""
    lengths = [s.length for s in sections]
    speeds = []
    for s, l0 in zip(sections, unstretched(sections)):
        added = RHO * s.area  # Ca_n = 1, per unstretched metre as the dry mass
        speeds.append(math.sqrt(tension / ((s.mass + added) * l0 / s.length)))

    def residual(omega: float) -> float:
        if len(sections) == 1:
            return math.sin(omega / speeds[0] * lengths[0])
        k1, k2 = omega / speeds[0], omega / speeds[1]
        l1, l2 = lengths
        return k2 * math.sin(k1 * l1) * math.cos(k2 * l2) + k1 * math.cos(k1 * l1) * math.sin(
            k2 * l2
        )

    grid = np.linspace(1.0e-3, 2.0 * math.pi * 2.0, 20001)
    values = [residual(w) for w in grid]
    found = [
        bisect(residual, grid[i], grid[i + 1])
        for i in range(len(grid) - 1)
        if values[i] * values[i + 1] < 0.0
    ]
    return np.array(found[:N_ROOTS]) / (2.0 * math.pi)


def gate(label: str, exe: Path, out: Path, sections: list[Section]) -> None:
    errors = []
    for h in (0.5, 0.25):
        tension, freqs = run(exe, out / f"{label}_{h:g}", sections, h)
        if freqs.size == 0:
            return
        for s, l0 in zip(sections, unstretched(sections)):
            expected = s.ea * (s.length / l0 - 1.0)
            check(
                abs(tension / expected - 1.0) < 1.0e-6,
                f"{label}, h {h:g} m: static tension {tension:.6g} N is EA (l/L - 1) of "
                f"{s.name} ({expected:.6g} N)",
            )
        exact = roots(sections, tension)
        check(
            freqs.size == 2 * N_ROOTS,
            f"{label}, h {h:g} m: {freqs.size} modes written",
        )
        paired = np.repeat(exact, 2)
        error = np.abs(freqs[: paired.size] / paired - 1.0)
        errors.append(float(error.max()))
        print(
            f"  {label}, h {h:g} m: roots {np.round(exact, 5)} Hz, largest error {error.max():.3e}"
        )
    check(errors[1] < 1.0e-3, f"{label}: on 0.25 m elements within 0.1 % ({errors[1]:.3e})")
    check(
        errors[0] > 3.0 * errors[1],
        f"{label}: halving the elements cuts the error at least threefold "
        f"({errors[0]:.3e} -> {errors[1]:.3e})",
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    exe = args.exe.resolve()
    out = args.output.resolve()
    gate(
        "composite",
        exe,
        out,
        [Section("thick", 0.2, 2.0e9, 40.0), Section("thin", 0.1, 1.0e9, 60.0)],
    )
    gate("uniform", exe, out, [Section("thick", 0.2, 2.0e9, SPAN)])
    if FAILURES:
        print(f"\n{len(FAILURES)} check(s) failed")
        return 1
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
