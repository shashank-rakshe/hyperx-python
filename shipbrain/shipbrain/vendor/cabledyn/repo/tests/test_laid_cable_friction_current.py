#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Finite-EI laid cable in a current held by seabed friction.

A 230 m cubic-Hermite power cable hangs from a hang-off 14 m below the surface and lies on an
80 m seabed for about half its length to a seabed anchor. The matrix crosses a current of
0.1 to 1.5 m/s (across the laid run, and at 45 degrees and along it for the light cable) with
isotropic seabed friction 0.1 to 1.0 and three anisotropic axial/lateral pairs, for a light
and a heavy cable. Every deck has a static equilibrium (the laid run can bow sideways until
its tension holds what friction cannot), and every deck must:

* converge through the standalone driver (static run, TMax = 0);
* pass an independent global force balance: from the static node positions, the end forces
  (Point<P>F channels), the submerged weight and a Morison drag recomputed on the nodal
  polyline, the seabed must carry a positive normal load N and a horizontal friction
  resultant within the Coulomb capacity max(mu_axial, mu_lateral) N;
* stay at rest when marched in time from the static state (TMax = 2 s): the line-end forces
  of every output row equal the static ones to 1e-5 of the fairlead tension.

The first case (light cable, 0.3 m/s across, mu 0.1) is the minimal reproducer of a static
solve that converged but was rejected as an unstable equilibrium: the stability test took
the symmetric part of a tangent whose friction rows depend on the normal force.

usage: test_laid_cable_friction_current.py --exe <cabledyn> --output <dir> [--workers N]
"""

from __future__ import annotations

import argparse
import math
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

G, RHO = 9.80665, 1025.0
LENGTH, CDN, CDT = 230.0, 1.2, 0.1
# name: diameter [m], mass [kg/m], EA [N], EI [N m^2]
CABLES = {"light": (0.160, 36.7, 4.69e8, 1.99e4), "heavy": (0.200, 80.0, 8.0e8, 5.0e4)}
CURRENTS = (0.1, 0.3, 0.5, 0.8, 1.2, 1.5)
FRICTION = [(mu, mu) for mu in (0.1, 0.3, 0.6, 1.0)] + [(0.1, 0.5), (0.3, 1.0), (0.6, 0.2)]
REST_TOL = 1.0e-5
CAPACITY_TOL = 0.02


def deck(cable: str, speed: float, heading: float, mu_axial: float, mu_lateral: float, tmax: float) -> str:
    d, m, ea, ei = CABLES[cable]
    ux, uy = speed * math.cos(math.radians(heading)), speed * math.sin(math.radians(heading))
    if mu_axial == mu_lateral:
        friction = "%g frictionMu\n" % mu_lateral
    else:
        friction = "%g frictionMuAxial\n%g frictionMuLateral\n" % (mu_axial, mu_lateral)
    return (
        "--------------------- CableDyn Input File ---------------------------\n"
        f"laid {cable} cable, current {speed} m/s at {heading} deg, friction {mu_axial}/{mu_lateral}\n"
        "--------------------- LINE TYPES ------------------------------------\n"
        "TypeName Diam MassDenInAir EA BA EI Cd_n Cd_t Ca_n Ca_t\n"
        "(-) (m) (kg/m) (N) (-) (N-m2) (-) (-) (-) (-)\n"
        f"cable {d} {m} {ea} 0.0 {ei} {CDN} {CDT} 1.0 0.0\n"
        "--------------------- POINTS ----------------------------------------\n"
        "ID Type X Y Z\n(-) (-) (m) (m) (m)\n"
        "1 Coupled 5.0 0.0 -14.0\n2 Fixed 205.0 0.0 -80.0\n"
        "--------------------- LINES -----------------------------------------\n"
        "ID NodeA NodeB Outputs\n(-) (-) (-) (-)\n1 1 2 -\n"
        "--------------------- SECTIONS --------------------------------------\n"
        "LineID LineType Length NumSegs\n(-) (-) (m) (-)\n"
        f"1 cable {LENGTH} 115\n"
        "--------------------- OPTIONS ---------------------------------------\n"
        "9.80665 g\n1025.0 rhoW\n80.0 WtrDpth\n1.0e5 kBot\n1.0e4 cBot\n0.05 dtM\n"
        f"{tmax} TMax\n{friction}uniform {ux:.9f} {uy:.9f} 0.0 current\n"
        "--------------------- OUTPUTS ---------------------------------------\n"
        '"FairTen1"\n"AnchTen1"\n"Point1Fx"\n"Point1Fy"\n"Point1Fz"\n"Point2Fx"\n"Point2Fy"\n"Point2Fz"\n'
        "--------------------- need this line --------------------------------\n"
    )


def build_cases() -> list:
    cases = [("repro_light_u0.3_mu0.1", "light", 0.3, 90.0, 0.1, 0.1)]
    for cable in CABLES:
        for speed in CURRENTS:
            for mua, mul in FRICTION:
                cases.append(("%s_u%g_h90_a%g_l%g" % (cable, speed, mua, mul), cable, speed, 90.0, mua, mul))
    for heading in (45.0, 0.0):
        for speed in (0.3, 0.8, 1.5):
            for mua, mul in ((0.1, 0.1), (1.0, 1.0), (0.3, 1.0)):
                cases.append(("light_u%g_h%g_a%g_l%g" % (speed, heading, mua, mul), "light", speed, heading,
                              mua, mul))
    return cases


def table(path: Path) -> list:
    rows = path.read_text(encoding="utf-8").splitlines()
    names = rows[1].split()
    return [dict(zip(names, map(float, r.split()))) for r in rows[2:] if r.strip()]


def run_case(exe: str, root: Path, case: tuple) -> dict:
    cid, cable, speed, heading, mua, mul = case
    cdir = root / cid
    cdir.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env.setdefault("OPENBLAS_NUM_THREADS", "1")
    env.setdefault("OMP_NUM_THREADS", "1")
    res = {}
    for tag, tmax in (("static", 0.0), ("rest", 2.0)):
        (cdir / (tag + ".dat")).write_text(deck(cable, speed, heading, mua, mul, tmax), encoding="utf-8",
                                           newline="\n")
        p = subprocess.run([exe, str(cdir / (tag + ".dat")), str(cdir / tag)], cwd=cdir, env=env,
                           capture_output=True, text=True, timeout=600)
        res[tag] = (p.returncode, p.stdout + p.stderr)
    return res


def seabed_load(case: tuple, root: Path) -> tuple:
    """(N, |F_h|): the seabed reaction the static state needs, from an independent balance."""
    cid, cable, speed, heading, _, _ = case
    d, m, _, _ = CABLES[cable]
    w = (m - RHO * math.pi / 4.0 * d * d) * G
    nodes = []
    for ln in (root / cid / "static.static.out").read_text(encoding="utf-8").splitlines()[3:]:
        f = ln.split()
        if len(f) >= 7:
            nodes.append([float(v) for v in f[3:6]])
    row = table(root / cid / "static.out")[0]
    ends = [row["Point1F" + c] + row["Point2F" + c] for c in "xyz"]
    u = [speed * math.cos(math.radians(heading)), speed * math.sin(math.radians(heading)), 0.0]
    load = [0.0, 0.0, -w * LENGTH]
    for a, b in zip(nodes[:-1], nodes[1:]):
        t = [b[k] - a[k] for k in range(3)]
        seg = math.sqrt(sum(x * x for x in t))
        t = [x / seg for x in t]
        ua = sum(u[k] * t[k] for k in range(3))
        un = [u[k] - ua * t[k] for k in range(3)]
        unm = math.sqrt(sum(x * x for x in un))
        for k in range(3):
            load[k] += seg * 0.5 * RHO * d * (CDN * unm * un[k] + math.pi * CDT * abs(ua) * ua * t[k])
    # The line carries -ends (the points' loads reversed), the external load and the seabed.
    seabed = [ends[k] - load[k] for k in range(3)]
    return seabed[2], math.hypot(seabed[0], seabed[1])


def check(case: tuple, res: dict, root: Path) -> list:
    errs = []
    rc, log = res["static"]
    if rc != 0:
        tail = [ln for ln in log.splitlines() if "CableDyn_DeckDriver" in ln]
        return ["static solve failed rc=%s: %s" % (rc, (tail[-1] if tail else log[-300:])[:300])]
    normal, friction = seabed_load(case, root)
    cap = max(case[4], case[5]) * normal
    if not normal > 0.0:
        errs.append("seabed normal load %.4g N is not positive" % normal)
    elif friction > (1.0 + CAPACITY_TOL) * cap + 1.0:
        errs.append("friction resultant %.4g N beyond the Coulomb capacity %.4g N" % (friction, cap))
    rc, log = res["rest"]
    if rc != 0:
        tail = [ln for ln in log.splitlines() if "CableDyn_DeckDriver" in ln]
        errs.append("at-rest march failed rc=%s: %s" % (rc, (tail[-1] if tail else log[-300:])[:300]))
        return errs
    s0 = table(root / case[0] / "static.out")[0]
    scale = max(abs(s0["FairTen1"]), 1.0)
    for k, row in enumerate(table(root / case[0] / "rest.out")):
        drift = max(abs(row[n] - s0[n]) for n in s0 if n != "Time(s)")
        if drift > REST_TOL * scale:
            errs.append("row %d: end forces drift %.3g N from the static state" % (k, drift))
            break
    return errs


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--workers", type=int, default=4)
    a = ap.parse_args()
    root = Path(a.output).resolve()
    root.mkdir(parents=True, exist_ok=True)
    cases = build_cases()
    t0 = time.time()
    with ThreadPoolExecutor(a.workers) as ex:
        results = list(ex.map(lambda c: run_case(a.exe, root, c), cases))
    failures = 0
    for case, res in zip(cases, results):
        errs = check(case, res, root)
        failures += bool(errs)
        print("%-4s %-28s %s" % ("FAIL" if errs else "ok", case[0], "; ".join(errs)))
    print("laid cable friction/current: %d/%d decks as expected in %.1f s" % (len(cases) - failures, len(cases),
                                                                             time.time() - t0))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
