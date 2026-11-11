#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Static equilibrium of a finite-EI line longer than its span with little or no net weight.

Such a line cannot hang as a catenary: it bows under the axial compression its bending stiffness
carries (the Euler elastica). Gates, each on the driver's own output files, for a 120 m line
pinned at both ends 113 m apart on a chord inclined 45 deg:

* weightless: the line solves, the run notes that nothing chooses the plane or side of the bow,
  the bow lies in the vertical plane of the chord on its lower side, and its end thrust and
  mid-span bow are those of the inextensible pinned-pinned elastica (P = 4 K(m)^2 EI/L^2 and
  delta = sqrt(m) L/K(m), with chord/L = 2 E(m)/K(m) - 1); so too with both ends Fixed (legal in
  a deck with a dynamic point: a weighted Connect point on two chains, well clear of the line);
* light: with a net weight of +1e-3 N/m (heavy) or -1e-3 N/m (buoyant) the line solves with no
  such note and bows down or up, its end forces within its whole weight of the elastica's thrust;
* dynamics: a march from the weightless equilibrium stays at rest.

usage: test_light_slack_statics.py --exe <cabledyn> --output <dir>
"""

from __future__ import annotations

import argparse
import math
import subprocess
import sys
from pathlib import Path

import numpy as np
from scipy.optimize import brentq
from scipy.special import ellipe, ellipk

G, RHO = 9.80665, 1025.0
DIAM, EA, EI, LENGTH, NSEG = 0.2, 1.0e8, 1.0e4, 120.0, 120
END_A = np.array([0.0, 0.0, -20.0])
END_B = np.array([80.0, 0.0, -100.0])
FAILURES: list[str] = []


def check(ok: bool, message: str) -> None:
    print(("PASS: " if ok else "FAIL: ") + message)
    if not ok:
        FAILURES.append(message)


def elastica() -> tuple[float, float]:
    """End thrust [N] and mid-span bow [m] of the inextensible pinned-pinned elastica."""
    ratio = np.linalg.norm(END_B - END_A) / LENGTH
    m = brentq(lambda m: 2.0 * ellipe(m) / ellipk(m) - 1.0 - ratio, 1.0e-12, 0.99)
    k = ellipk(m)
    return 4.0 * k * k * EI / LENGTH ** 2, math.sqrt(m) * LENGTH / k


def write_deck(path: Path, weight: float, tmax: float = 0.0, end_a: str = "Coupled") -> None:
    """The line with a net weight [N/m] (0: neutrally buoyant to the 7 digits written)."""
    mass = RHO * math.pi * DIAM ** 2 / 4.0 + weight / G
    crowfoot = end_a == "Fixed"
    if crowfoot:
        tmax = max(tmax, 0.05)
    outputs = ["FairTen1", "AnchTen1"]
    if tmax > 0.0:
        outputs += ["L1N61PX", "L1N61PY", "L1N61PZ"]
    path.write_text("\n".join([
        "--------------------- CableDyn Input File ---",
        "light slack finite-EI line",
        "--------------------- LINE TYPES ---",
        "TypeName Diam MassDenInAir EA BA EI Cd_n Cd_t Ca_n Ca_t",
        "(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)",
        f"light {DIAM} {mass:.7f} {EA:.6g} -1 {EI:.6g} 1.2 0.1 1 0",
        *(["chain 0.2 250.0 1.0e9 -1 0.0 1.2 0.6 1 0"] if crowfoot else []),
        "--------------------- POINTS ---",
        "ID Type X Y Z Mass Vol CdA Ca",
        "(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)",
        "1 {} {:g} {:g} {:g} 0 0 0 0".format(end_a, *END_A),
        "2 Fixed {:g} {:g} {:g} 0 0 0 0".format(*END_B),
        *(["3 Fixed -100 300 -20 0 0 0 0", "4 Connect 0 300 -80 5000 0 0 0",
           "5 Fixed 100 300 -20 0 0 0 0"] if crowfoot else []),
        "--------------------- LINES ---",
        "ID NodeA NodeB Outputs",
        "(-) (-) (-) (-)",
        "1 1 2 -",
        *(["2 3 4 -", "3 5 4 -"] if crowfoot else []),
        "--------------------- SECTIONS ---",
        "LineID LineType Length NumSegs",
        "(-) (-) (m) (-)",
        f"1 light {LENGTH:g} {NSEG}",
        *(["2 chain 120 20", "3 chain 120 20"] if crowfoot else []),
        "--------------------- OPTIONS ---",
        "9.80665 g",
        "1025.0 rhoW",
        "200.0 WtrDpth",
        "100000.0 kBot",
        "1.0e4 cBot",
        "0.05 dtM",
        f"{tmax:g} TMax",
        "--------------------- OUTPUTS ---",
        *[f'"{c}"' for c in outputs],
        "--------------------- need this line ---",
        "",
    ]))


def run(exe: str, workdir: Path, name: str, weight: float, tmax: float = 0.0, end_a: str = "Coupled"):
    deck = workdir / f"{name}.dat"
    write_deck(deck, weight, tmax, end_a)
    proc = subprocess.run([exe, deck.name, name], cwd=workdir, capture_output=True, text=True, timeout=600)
    return proc.returncode, proc.stdout + proc.stderr


def static_profile(path: Path) -> np.ndarray:
    """Rows of the static profile: node, x, y, z, tension."""
    rows = [line.split() for line in path.read_text().splitlines()[3:] if line.strip()]
    return np.array([[float(r[1]), float(r[3]), float(r[4]), float(r[5]), float(r[6])] for r in rows])


def time_series(path: Path) -> tuple[list[str], np.ndarray]:
    """Channel names and rows of a driver .out file."""
    lines = path.read_text().splitlines()
    head = next(i for i, line in enumerate(lines) if line.split() and line.split()[0].startswith("Time"))
    data = np.array([[float(v) for v in line.split()] for line in lines[head + 1:]
                     if line.strip() and not line.lstrip().startswith("(")])
    return lines[head].split(), data


def bow(mid: np.ndarray) -> np.ndarray:
    """Offset of the mid-span node from the chord."""
    d = (END_B - END_A) / np.linalg.norm(END_B - END_A)
    mid = mid - END_A
    return mid - np.dot(mid, d) * d


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    work = Path(args.output)
    work.mkdir(parents=True, exist_ok=True)
    thrust, delta = elastica()
    print(f"elastica: thrust {thrust:.5f} N, mid-span bow {delta:.5f} m")

    for name, end_a in (("weightless", "Coupled"), ("weightless_fixed", "Fixed")):
        rc, log = run(args.exe, work, name, 0.0, end_a=end_a)
        check(rc == 0, f"{name} line (End A {end_a}) solves (rc {rc})")
        if rc != 0:
            print(log)
            continue
        check("is weightless and longer than its span" in log and "bowed downward" in log,
              f"{name}: the run notes the weightless bow and the side it was solved on")
        if end_a == "Coupled":
            prof = static_profile(work / f"{name}.static.out")
            in_plane = np.all(prof[:, 2] == 0.0)
            mid, ends = prof[len(prof) // 2, 1:4], (prof[0, 4], prof[-1, 4])
        else:
            # the multibody route writes no static profile: its first output row is the equilibrium
            names, data = time_series(work / f"{name}.out")
            mid = data[0, [names.index("L1N61PX"), names.index("L1N61PY"), names.index("L1N61PZ")]]
            in_plane = mid[1] == 0.0
            ends = (data[0, names.index("FairTen1")], data[0, names.index("AnchTen1")])
        b = bow(mid)
        check(in_plane, f"{name}: the bow lies in the vertical plane of the chord")
        check(b[2] < 0.0, f"{name}: the weightless line bows downward")
        check(abs(ends[0] - thrust) < 1.0e-3 * thrust and abs(ends[1] - thrust) < 1.0e-3 * thrust,
              f"{name}: end thrust {ends[0]:.5f} / {ends[1]:.5f} N = elastica {thrust:.5f} N")
        check(abs(np.linalg.norm(b) - delta) < 1.0e-3 * delta,
              f"{name}: mid-span bow {np.linalg.norm(b):.5f} m = elastica {delta:.5f} m")

    for name, weight, down in (("light_heavy", 1.0e-3, True), ("light_buoyant", -1.0e-3, False)):
        rc, log = run(args.exe, work, name, weight)
        check(rc == 0, f"{name} line ({weight:+g} N/m) solves (rc {rc})")
        if rc != 0:
            continue
        check("is weightless" not in log, f"{name}: no weightless note")
        prof = static_profile(work / f"{name}.static.out")
        b = bow(prof[len(prof) // 2, 1:4])
        check((b[2] < 0.0) == down, f"{name} line bows {'down' if down else 'up'}ward")
        # the end forces differ from the weightless thrust by at most the line's whole weight
        check(max(abs(prof[0, 4] - thrust), abs(prof[-1, 4] - thrust)) <= abs(weight) * LENGTH,
              f"{name}: end forces {prof[0, 4]:.4f} / {prof[-1, 4]:.4f} N within the line's weight "
              f"{abs(weight) * LENGTH:.3f} N of the elastica's thrust")

    rc, log = run(args.exe, work, "weightless_march", 0.0, tmax=2.0)
    check(rc == 0, f"march from the weightless equilibrium runs (rc {rc})")
    if rc == 0:
        names, data = time_series(work / "weightless_march.out")
        mid = data[:, [names.index("L1N61PX"), names.index("L1N61PY"), names.index("L1N61PZ")]]
        drift = np.max(np.linalg.norm(mid - mid[0], axis=1))
        ten = data[:, names.index("FairTen1")]
        check(drift < 1.0e-6, f"the bow stays at rest (mid-span drift {drift:.2e} m)")
        check(np.max(np.abs(ten - thrust)) < 1.0e-3 * thrust, "the end thrust stays at the elastica's")

    if FAILURES:
        print(f"FAIL: {len(FAILURES)} check(s) failed")
        return 1
    print("PASS: light slack finite-EI statics")
    return 0


if __name__ == "__main__":
    sys.exit(main())
