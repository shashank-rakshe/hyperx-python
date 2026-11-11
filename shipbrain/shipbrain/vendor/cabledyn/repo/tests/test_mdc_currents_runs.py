#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Standalone runs in the MoorDyn-C time-varying and gridded currents (Currents 2 and 5).

The inputs are those of tests/data/currents_mdc (validation/scripts/currents_mdc_reference.py).
Gates, each run through the cabledyn driver with the line node tension channels Ten1N1..Ten1N21:

* against MoorDyn-C v2.7.1 itself (ref_moordyn_c_tension.csv; a 70 m rope across the flow, held
  at both ends, from rest in still water): the still-water tensions within 0.3 % of MoorDyn-C's,
  and the tension change the current makes over 22 s (each code's run minus its own still-water
  run) within 15 % of MoorDyn-C's largest change, for a depth profile that varies in time
  (tension_c2) and for a grid sheared along the line, in depth and in time (tension_c5) (measured:
  0.8 % and 0.9 %; the still-water tensions 0.12 %);
* a second source of the same field, on the EI = 0 and the finite-EI routes: Currents 2 with the
  steady profile at every time equals Currents 1 (c2const, c1), and the Currents 5 grid uniform in
  x and y equals the Currents 2 profile (c5uniform, c2), every channel to the 8 significant digits
  the .out file prints (measured: identical, and one unit of the last digit);
* the static start in a grid sheared along the line and in depth (the tension_c5 grid frozen in
  time) is an equilibrium of the march on the EI = 0, the finite-EI and the point-connected EI = 0
  routes: over the first 2 s the tensions move by less than 1e-4 of the change the current makes
  to the still-water start (a finite-EI static that samples the grid in its translated solve frame
  instead of at the global node positions moves them by 0.8 of it);
* a current that is zero along the straight chord but not where the line sags (offchord: Currents 1
  and 2 on the EI = 0 route, Currents 2 on the finite-EI route) is in the static start: the march
  then moves the tensions by less than 1e-4 of the change the current makes, and the EI = 0 start
  is within 0.5 % of the finite-EI one (an EI = 0 start in still water drifted 192 N in 4 s).

usage: test_mdc_currents_runs.py --exe <cabledyn> --data <tests/data/currents_mdc> --output <dir>
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np

FAILURES: list[str] = []
END_LINE = "------------------------- need this line --------------------------------------"
OUTPUTS = "---------------------- OUTPUTS -----------------------------------------\n" + "\n".join(
    f"Ten1N{j}" for j in range(1, 22)
)


def check(ok: bool, message: str) -> None:
    print(("PASS: " if ok else "FAIL: ") + message)
    if not ok:
        FAILURES.append(message)


def deck_text(path: Path, finite_ei: bool = False, tmax: float | None = None) -> str:
    """The MoorDyn-C deck with the tension channels (and optionally EI > 0, another TMax)."""
    lines = []
    for line in path.read_text().splitlines():
        parts = line.split()
        if line.startswith("------------------------- need this line"):
            lines.append(OUTPUTS)
        if finite_ei and len(parts) == 10 and parts[0] in {"chain", "rope"}:
            parts[5] = "2.0e3"
            line = "      ".join(parts)
        if tmax is not None and len(parts) >= 2 and parts[1] == "TMax":
            line = f"{tmax}          TMax"
        lines.append(line)
    return "\n".join(lines) + "\n"


def run(exe: str, folder: Path, name: str, text: str, tables: list[Path]) -> np.ndarray | None:
    """Run text in folder (with the current tables copied in); the .out rows, time first."""
    folder.mkdir(parents=True, exist_ok=True)
    for table in tables:
        shutil.copy2(table, folder / table.name)
    (folder / f"{name}.dat").write_text(text, encoding="utf-8", newline="\n")
    proc = subprocess.run([exe, f"{name}.dat", name], cwd=folder, capture_output=True, text=True,
                          env=dict(os.environ, OMP_NUM_THREADS="1"))
    check(proc.returncode == 0, f"{folder.name}/{name} runs (exit {proc.returncode})")
    if proc.returncode != 0:
        print(proc.stdout[-2000:], proc.stderr[-2000:])
        return None
    lines = (folder / f"{name}.out").read_text().splitlines()
    head = next(i for i, line in enumerate(lines) if line.split() and line.split()[0].startswith("Time"))
    return np.array([[float(v) for v in line.split()] for line in lines[head + 1:]
                     if line.strip() and not line.lstrip().startswith("(")])


def tables(case: Path) -> list[Path]:
    return sorted(case.glob("current_profile*.txt"))


def against_moordyn_c(exe: str, data: Path, out: Path) -> None:
    """Node tensions of the tension cases against MoorDyn-C's."""
    series = {}
    for case in ("tension_c0", "tension_c2", "tension_c5"):
        src = data / case
        cd = run(exe, out / case, "tension", deck_text(src / "tension.dat"), tables(src))
        if cd is None:
            return
        mdc = np.loadtxt(src / "ref_moordyn_c_tension.csv", delimiter=",", skiprows=1)
        # CableDyn's rows every dtM at MoorDyn-C's output times; CableDyn node J (from End A) is
        # MoorDyn-C node J - 1
        rows = np.searchsorted(cd[:, 0], mdc[:, 0] - 1.0e-9)
        check(bool(np.all(np.abs(cd[rows, 0] - mdc[:, 0]) < 1.0e-6)), f"{case}: the output times correspond")
        series[case] = (cd[rows, 1:22], mdc[:, 1:22])
    # interior nodes 2-20, where both codes report the mean of the two adjacent segment tensions
    # (at an end MoorDyn-C reports the end segment's, CableDyn the line-end force)
    cd0, mdc0 = series["tension_c0"]
    still = np.abs(cd0[:, 1:20] - mdc0[:, 1:20]).max() / np.abs(mdc0[:, 1:20]).max()
    check(still <= 3.0e-3, f"still water: node tensions within {still:.2e} of MoorDyn-C's (0.3 %)")
    for case in ("tension_c2", "tension_c5"):
        cd, mdc = series[case]
        d_cd, d_mdc = cd - cd0, mdc - mdc0
        scale = np.abs(d_mdc[:, 1:20]).max()
        err = np.abs(d_cd[:, 1:20] - d_mdc[:, 1:20]).max()
        rms = np.sqrt(np.mean((d_cd[:, 1:20] - d_mdc[:, 1:20]) ** 2))
        check(err <= 0.03 * scale,
              f"{case}: the tension change of the current, MoorDyn-C's largest {scale:.0f} N, matches to "
              f"{err:.1f} N ({err / scale:.1%}, rms {rms / scale:.1%}) at nodes 2-20 over 22 s (3 %)")


def same_field(exe: str, data: Path, out: Path) -> None:
    """Two sources of the same current give the same run, on both routes."""
    for case, other, label in (("c2const", "c1", "Currents 2 (a constant table) vs Currents 1"),
                               ("c5uniform", "c2", "Currents 5 (uniform in x and y) vs Currents 2")):
        for finite in (False, True):
            route = "finite-EI" if finite else "EI = 0"
            a = run(exe, out / f"{case}_{int(finite)}", "run",
                    deck_text(data / case / "currents.dat", finite, tmax=8.0), tables(data / case))
            b = run(exe, out / f"{other}_{int(finite)}", "run",
                    deck_text(data / other / "currents.dat", finite, tmax=8.0), tables(data / other))
            if a is None or b is None:
                continue
            # the runs agree to the 8 significant digits the .out file prints (the fields differ
            # by round-off, which the Newton iterations of the march may carry to the last digit)
            ok = a.shape == b.shape
            if ok:
                unit = 10.0 ** (np.floor(np.log10(np.maximum(np.abs(b[:, 1:]), 1.0e-300))) - 7.0)
                digits = np.abs(a[:, 1:] - b[:, 1:]) / unit
                ok = bool(np.all(digits <= 1.01))
                print(f"   {label}, {route}: largest difference {np.abs(a - b).max():.1e} N, "
                      f"{digits.max():.2f} units of the last printed digit")
            check(ok, f"{label}, {route}: every channel the same to the last printed digit")


def static_start(exe: str, data: Path, out: Path) -> None:
    """The static start in a sheared grid, frozen in time, is an equilibrium of the march."""
    src = (data / "tension_c5" / "current_profile_4d.txt").read_text().splitlines()
    head, rows = src[:6], src[6:]
    dims = head[0].split()
    frozen = [" ".join(dims[:3] + ["2"])] + head[1:4] + ["0.0 100.0"] + [head[5]]
    t_keep = "15.0"
    for t_new in ("0.0", "100.0"):
        for row in rows:
            parts = row.split()
            if parts[3] == t_keep:
                parts[3] = t_new
                frozen.append(" ".join(parts))
    for kind in ("EI = 0", "finite-EI", "EI = 0 with a free point"):
        tag = kind.replace(" ", "_").replace("=", "")
        folder = out / f"static_{tag}"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "current_profile_4d.txt").write_text("\n".join(frozen) + "\n", encoding="utf-8", newline="\n")
        if kind == "EI = 0 with a free point":
            text_cur = two_line_deck(5)
            text_still = two_line_deck(0)
        else:
            finite = kind == "finite-EI"
            text_cur = deck_text(data / "tension_c5" / "tension.dat", finite, tmax=2.0)
            text_still = deck_text(data / "tension_c0" / "tension.dat", finite, tmax=2.0)
        cur = run(exe, folder, "run", text_cur, [])
        still = run(exe, out / f"still_{tag}", "run", text_still, [])
        if cur is None or still is None:
            continue
        step = np.abs(cur[0, 1:] - still[0, 1:]).max()
        drift = np.abs(cur[:, 1:] - cur[0, 1:]).max()
        check(step > 0.05 * np.abs(still[0, 1:]).max() and drift <= 1.0e-4 * step,
              f"{kind}: the static start in the sheared grid moves the tensions by {step:.0f} N from still "
              f"water; the march then moves them by {drift:.2e} N ({drift / step:.1e}, 1e-4) over 2 s")


def current_below_the_chord(exe: str, data: Path, out: Path) -> None:
    """The static start in a current that is zero along the straight chord but not where the line
    sags (offchord: 0.8 m/s below z = -32 m, the ends at z = -20 m) carries the current: the march
    then holds the start, and the EI = 0 start agrees with the finite-EI one."""
    src = data / "offchord"
    tables = [src / "current_profile.txt", src / "current_profile_dynamic.txt"]
    runs = {}
    for name, finite in (("c1", False), ("c2", False), ("c2", True)):
        tag = f"{name}_{'fei' if finite else 'ei0'}"
        text = deck_text(src / f"{name}.dat", finite)
        runs[tag] = run(exe, out / f"offchord_{tag}", "run", text, tables)
    still = run(exe, out / "offchord_still", "run", deck_text(data / "tension_c0" / "tension.dat", tmax=4.0), [])
    if still is None or any(r is None for r in runs.values()):
        return
    for tag, r in runs.items():
        step = np.abs(r[0, 1:] - still[0, 1:]).max()
        drift = np.abs(r[:, 1:] - r[0, 1:]).max()
        check(step > 0.05 * np.abs(still[0, 1:]).max() and drift <= 1.0e-4 * step,
              f"current below the chord, {tag}: the static start carries it ({step:.0f} N from still water); "
              f"the march then moves the tensions by {drift:.2e} N over 4 s (1e-4 of that)")
    ei0, fei = runs["c2_ei0"][0, 1:], runs["c2_fei"][0, 1:]
    gap = np.abs(ei0 - fei).max() / np.abs(fei).max()
    check(gap <= 5.0e-3 and np.array_equal(runs["c1_ei0"][0, 1:], ei0),
          f"current below the chord: the EI = 0 start within {gap:.1e} of the finite-EI one (0.5 %), and "
          "Currents 1 and 2 give the same start")


def two_line_deck(currents: int) -> str:
    """The tension rope as two EI = 0 lines meeting at a free point (the point-connected route)."""
    return f"""--------------------- MoorDyn Input File ------------------------------------
two lines meeting at a free point (Currents {currents})
----------------------- LINE TYPES ------------------------------------------
TypeName   Diam    Mass/m     EA         BA/-zeta    EI         Cd     Ca     CdAx    CaAx
(name)     (m)     (kg/m)     (N)        (N-s/-)     (N-m^2)    (-)    (-)    (-)     (-)
rope       0.3     80.0       1.0e7      -1.0        0          1.2    1.0    0.2     0.0
---------------------- POINT PROPERTIES --------------------------------
ID    Type      X       Y       Z       Mass   Volume  CdA    Ca
(#)   (-)       (m)     (m)     (m)     (kg)   (m^3)   (m^2)  (-)
1     Fixed     0.0     -30.0   -20.0   0      0       0      0
2     Free      4.0     0.0     -32.0   200    0.05    0.5    1.0
3     Vessel    0.0     30.0    -20.0   0      0       0      0
---------------------- LINES ----------------------------------------
ID   LineType   AttachA  AttachB  UnstrLen  NumSegs  LineOutputs
(#)   (name)     (#)      (#)       (m)       (-)     (-)
1     rope       2        1         35.0      10      -
2     rope       3        2         35.0      10      -
---------------------- OPTIONS -----------------------------------------
0.002         dtM
2.0           TMax
1025.0        WtrDnsty
50            WtrDpth
0             WaveKin
{currents}             Currents
{OUTPUTS.split(chr(10))[0]}
""" + "\n".join(f"Ten{line}N{j}" for line in (1, 2) for j in range(1, 12)) + f"\n{END_LINE}\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--exe", required=True)
    parser.add_argument("--data", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    data, out = Path(args.data), Path(args.output)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    against_moordyn_c(args.exe, data, out)
    same_field(args.exe, data, out)
    static_start(args.exe, data, out)
    current_below_the_chord(args.exe, data, out)
    print(f"{len(FAILURES)} failure(s)")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
