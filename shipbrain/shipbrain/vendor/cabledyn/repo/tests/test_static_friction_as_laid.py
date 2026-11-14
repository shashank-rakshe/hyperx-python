#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Static seabed friction toward the as-laid position (OPTIONS staticsFriction asLaid, set in
every deck below; the default is none).

A grounded run on a seabed sloping down toward its anchor, with friction mu = 1 well above the
slope, must hold in statics where it was laid; with the default frictionless statics (none) the
run slides down the slope and folds back past its anchor (EI = 0), or is rejected as too long
for its span (finite EI). Every deck runs through the standalone
driver:

* ``slope_ei0`` (EI = 0 chain, 5 degree slope, 700 m line over a 450 m span): converges with
  the grounded run on its side of the anchor, and an independent nodal force balance (element
  tensions, lumped weight, seabed normal along the local normal) leaves at every grounded node
  a horizontal friction force within mu N, mobilised against the slope; its twin with
  ``none staticsFriction`` still folds past the anchor (the frictionless static of before);
* ``slope_ei0_rest``: the same deck marched for 2 s from the static state stays at rest (every
  output row reproduces the static end forces to 1e-5 of the fairlead tension): the friction
  anchors of the march continue the static springs, with no jump at t = 0;
* ``slope_fei`` (finite-EI cable on a 10 degree slope, too long for its span) converges, and
  marched for 1 s stays at rest likewise;
* ``flat_*`` (a grounded chain on a flat seabed): laid at the tension its run carries
  (``asLaidTension``), the friction is not mobilised and the end tensions equal the
  frictionless ones (FairTen to 1e-4, AnchTen to 0.5 %, see the check); laid slack (the
  default), friction holds the run back and the anchor tension falls by at most mu w times the
  grounded length;
* ``fei_flat_*`` (finite-EI cable on a flat seabed, laid slack): a lay azimuth across the vertical
  plane of the chord (45 degrees) is solved in 3D from the start, so the state is consistent
  (friction within mu N, a march from it stays at rest), while 180 degrees keeps the planar solve
  and flips the reference (the anchor tension falls below the default one);
* ``fei_cross`` (a cable on a cross slope, EI = 0 and finite EI): the lateral anchor force stays
  below the one a reference without the sink offset of the laid nodes would give, and
  the finite-EI line, solved in 3D because the seabed slopes across its chord, stays at rest when
  marched;
* ``att_cross`` (a finite-EI line with discrete buoyancy modules on a cross slope): the reference
  sinks each node under its discrete load, so the module nodes rest on the laid path (no lateral
  kink, as in the smeared twin) and a march from the static state stays at rest;
* ``shallow_cross`` (a 0.5 m finite-EI cable on a seabed 0.1 m deep, sloping across it): the
  reference sinks each node under the load the solver applies there, the dry part of the section
  that pierces the surface included, so the run rests on its laid path and a march from the
  static state stays at rest;
* ``buoyant_shallow`` (a net-buoyant 0.5 m cable on a flat seabed 0.01 m deep, kBot = 1000): the
  reference's dry load, whose full Newton step cycles between a wholly dry and a wholly wet node,
  converges with halved steps, and a march from the static state stays at rest;
* ``pl_*``: per-line rows win over the global ones (``layAzimuth<ID>`` over ``layAzimuth``,
  ``asLaidTension<ID>`` over ``asLaidTension``, in either order), and a row for line 2 leaves
  line 1 alone; ``aniso_*``: the axial coefficient rules the friction along a laid run;
  ``multi``: a three-section line of different weights keeps every grounded node within mu N;
* ``refined`` (a finite-EI line of two sections laid at a tension on a seabed curved along it and
  sloping across it, on a deck mesh the adaptive refinement takes 16x finer): the reference is laid
  on the refined mesh, so the run rests where its twin declared on that mesh does (positions to
  1e-6 m, end forces) and a march from it stays at rest;
* input checks: ``layAzimuth<ID>`` of a line that does not exist (also one too large for an
  integer), an unknown suffix and an unknown policy are rejected, and the ``<ID>`` rows take
  effect; a finite-EI line shared between two turbines (both ends moving: no anchored end to lay
  the line from) rejects asLaid by name and runs with none.

usage: test_static_friction_as_laid.py --exe <cabledyn> --output <dir>
"""

from __future__ import annotations

import argparse
import math
import os
import subprocess
import sys
from pathlib import Path

G, RHO = 9.80665, 1025.0
CHAIN = (0.216, 286.56, 1.22976e9)  # diameter [m], mass [kg/m], EA [N]
REST_TOL = 1.0e-5
FAILURES: list[str] = []


def check(cond: bool, msg: str) -> None:
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        FAILURES.append(msg)


def slope_grid(path: Path, depth0: float, slope_deg: float) -> None:
    """A seabed z = -(depth0 + tan(slope) x): planar in x, falling toward +x."""
    t = math.tan(math.radians(slope_deg))
    rows = []
    for x in range(-300, 1000, 100):
        for y in (-300.0, 300.0):
            rows.append("%.1f %.1f %.12g" % (x, y, depth0 + t * x))
    path.write_text("\n".join(rows) + "\n", encoding="utf-8", newline="\n")


def deck(title: str, ei: float, length: float, nseg: int, fair: tuple, anch: tuple, seabed: str,
         extra: str = "", tmax: float = 0.0, mu: float = 1.0, types: str | None = None,
         sections: str | None = None, attachments: str | None = None) -> str:
    d, m, ea = CHAIN
    if types is None:
        types = f"chain {d} {m} {ea} -1 {ei} 1.37 0.64 1 0\n"
    if sections is None:
        sections = f"1 chain {length} {nseg}\n"
    if attachments is not None:
        sections += ("--------------------- ATTACHMENTS ---\n"
                     "LineID ArcLength Mass Volume CdA Ca CdAx\n(-) (m) (kg) (m^3) (m^2) (-) (m^2)\n"
                     f"{attachments}")
    return (
        "--------------------- CableDyn Input File ---\n"
        f"{title}\n"
        "--------------------- LINE TYPES ---\n"
        "TypeName Diam MassDenInAir EA BA EI Cd_n Cd_t Ca_n Ca_t\n"
        "(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)\n"
        f"{types}"
        "--------------------- POINTS ---\n"
        "ID Type X Y Z Mass Vol CdA Ca\n(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)\n"
        f"1 Coupled {fair[0]} {fair[1]} {fair[2]} 0 0 0 0\n"
        f"2 Fixed {anch[0]} {anch[1]} {anch[2]} 0 0 0 0\n"
        "--------------------- LINES ---\n"
        "ID NodeA NodeB Outputs\n(-) (-) (-) (-)\n1 1 2 pt\n"
        "--------------------- SECTIONS ---\n"
        "LineID LineType Length NumSegs\n(-) (-) (m) (-)\n"
        f"{sections}"
        "--------------------- OPTIONS ---\n"
        f"{G} g\n{RHO} rhoW\n{seabed}\n100000.0 kBot\n1.0e4 cBot\n0.05 dtM\n{tmax} TMax\n"
        f"{mu} frictionMu\nasLaid staticsFriction\n{extra}"
        "--------------------- OUTPUTS ---\n"
        '"FairTen1"\n"AnchTen1"\n"Point1Fx"\n"Point1Fy"\n"Point1Fz"\n"Point2Fx"\n"Point2Fy"\n"Point2Fz"\n'
        "--------------------- need this line ---\n"
    )


def run(exe: str, cdir: Path, name: str, text: str) -> tuple:
    cdir.mkdir(parents=True, exist_ok=True)
    (cdir / (name + ".dat")).write_text(text, encoding="utf-8", newline="\n")
    env = dict(os.environ)
    env.setdefault("OPENBLAS_NUM_THREADS", "1")
    env.setdefault("OMP_NUM_THREADS", "1")
    p = subprocess.run([exe, name + ".dat", name], cwd=cdir, env=env, capture_output=True, text=True,
                       timeout=600)
    return p.returncode, p.stdout + p.stderr


def table(path: Path) -> list:
    rows = [r for r in path.read_text(encoding="utf-8").splitlines() if r.strip() and not r.startswith("#")]
    names = rows[0].split()
    return [dict(zip(names, map(float, r.split()))) for r in rows[1:]]


def first_row(path: Path) -> list:
    rows = [r for r in path.read_text(encoding="utf-8").splitlines() if r.strip() and not r.startswith("#")]
    return [float(v) for v in rows[1].split()[1:]]


def grounded_balance(cdir: Path, name: str, length: float, nseg: int, mu: float, depth0: float,
                     slope_deg: float, band: float | None = None, end_trim: int = 0) -> tuple:
    """Largest friction utilisation |f|/(mu N) over grounded nodes and the total friction.

    band: only the nodes whose three neighbours on either side lie within band [m] of the
    seabed are taken (a finite-EI cable bends at its touchdown, which the tension-only balance
    does not carry), and not the last end_trim nodes before the anchor."""
    d, m, _ = CHAIN
    w = (m - RHO * math.pi / 4.0 * d * d) * G
    l0 = length / nseg
    p = first_row(cdir / (name + ".Line1.p.out"))
    pos = [p[3 * i:3 * i + 3] for i in range(len(p) // 3)]
    ten = first_row(cdir / (name + ".Line1.t.out"))
    gx = -math.tan(math.radians(slope_deg))
    nrm = [-gx / math.hypot(1.0, gx), 0.0, 1.0 / math.hypot(1.0, gx)]
    worst, total = 0.0, 0.0
    for i in range(1, len(pos) - 1):
        f = [0.0, 0.0, -w * l0]
        for e, j in ((i - 1, i - 1), (i, i + 1)):
            u = [pos[j][k] - pos[i][k] for k in range(3)]
            n = math.sqrt(sum(x * x for x in u))
            for k in range(3):
                f[k] += ten[e] * u[k] / n
        zf = -(depth0 + math.tan(math.radians(slope_deg)) * pos[i][0])
        normal = -f[2] / nrm[2]
        if pos[i][2] > zf + 0.5 or not normal > 1.0e-6 * w * l0:
            continue
        if i >= len(pos) - 1 - end_trim:
            continue
        if band is not None and not all(
                abs(pos[j][2] + depth0 + math.tan(math.radians(slope_deg)) * pos[j][0]) < band
                for j in range(max(i - 3, 0), min(i + 4, len(pos)))):
            continue
        fr = math.hypot(f[0] + normal * nrm[0], f[1])
        total += fr
        worst = max(worst, fr / (mu * normal))
    past = max(p_[0] for p_ in pos) - pos[-1][0]  # beyond the anchor (+x) along the span
    return worst, total, past


def at_rest(cdir: Path, static_name: str, rest_name: str) -> float:
    s0 = table(cdir / (static_name + ".out"))[0]
    scale = max(abs(s0["FairTen1"]), 1.0)
    drift = 0.0
    for row in table(cdir / (rest_name + ".out")):
        drift = max(drift, max(abs(row[n] - s0[n]) for n in s0 if n != "Time(s)"))
    return drift / scale


def deck_two(title: str, extra: str = "", mu: float = 0.5) -> str:
    """Two identical EI = 0 chains on a flat seabed, 1000 m apart (lines 1 and 2)."""
    d, m, ea = CHAIN
    return (
        "--------------------- CableDyn Input File ---\n"
        f"{title}\n"
        "--------------------- LINE TYPES ---\n"
        "TypeName Diam MassDenInAir EA BA EI Cd_n Cd_t Ca_n Ca_t\n"
        "(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)\n"
        f"chain {d} {m} {ea} -1 0 1.37 0.64 1 0\n"
        "--------------------- POINTS ---\n"
        "ID Type X Y Z Mass Vol CdA Ca\n(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)\n"
        "1 Coupled -58 0 -14 0 0 0 0\n2 Fixed -837.6 0 -200 0 0 0 0\n"
        "3 Coupled -58 1000 -14 0 0 0 0\n4 Fixed -837.6 1000 -200 0 0 0 0\n"
        "--------------------- LINES ---\n"
        "ID NodeA NodeB Outputs\n(-) (-) (-) (-)\n1 1 2 pt\n2 3 4 pt\n"
        "--------------------- SECTIONS ---\n"
        "LineID LineType Length NumSegs\n(-) (-) (m) (-)\n1 chain 850 85\n2 chain 850 85\n"
        "--------------------- OPTIONS ---\n"
        f"{G} g\n{RHO} rhoW\n200.0 WtrDpth\n100000.0 kBot\n1.0e4 cBot\n0.05 dtM\n0 TMax\n"
        f"{mu} frictionMu\nasLaid staticsFriction\n{extra}"
        "--------------------- OUTPUTS ---\n"
        '"FairTen1"\n"AnchTen1"\n"FairTen2"\n"AnchTen2"\n'
        "--------------------- need this line ---\n"
    )


def same(a: dict, b: dict, keys: tuple, tol: float = 1.0e-9) -> bool:
    """Whether the channels ``keys`` of two output rows agree to the relative tolerance tol."""
    return all(abs(a[k] - b[k]) <= tol * max(abs(a[k]), 1.0) for k in keys)


def chain_weight() -> float:
    """Submerged weight per length [N/m] of the test chain."""
    d, m, _ = CHAIN
    return (m - RHO * math.pi / 4.0 * d * d) * G


def plateau_utilisation(cdir: Path, name: str, mu: float, zfloor: float, kbot: float, sections: tuple,
                        trim: int = 2) -> tuple:
    """Largest |f|/(mu N) over the nodes resting on a flat seabed, from the nodal balance.

    The horizontal force that tensions and weight leave at a grounded node is what friction
    carries (EI = 0, or a straight run of a finite-EI cable). The nodes are the ones at the
    penetration depth of the penalty seabed, less ``trim`` at each end of the run (the bending
    of a finite-EI cable acts at the touchdown and at the anchor). ``sections``: (diameter,
    submerged weight per length, element length, number of elements) from End A. Returns
    (utilisation, number of nodes, largest |y| of the line, the utilisation and the number of
    nodes of each section, a node counted with the section of its End A element).
    """
    p = first_row(cdir / (name + ".Line1.p.out"))
    pos = [p[3 * i:3 * i + 3] for i in range(len(p) // 3)]
    ten = first_row(cdir / (name + ".Line1.t.out"))
    elem = []  # per element: diameter, weight per length, length
    owner = []  # per element: its section
    for k, (dia, wt, l0, ne) in enumerate(sections):
        elem += [(dia, wt, l0)] * ne
        owner += [k] * ne
    grounded = []
    for i in range(1, len(pos) - 1):
        # a node is grounded when it sits below the floor by (nearly) the penetration of the
        # lighter of its two elements
        pen = min(elem[i - 1][1] / (kbot * elem[i - 1][0]), elem[i][1] / (kbot * elem[i][0]))
        if pos[i][2] < zfloor - 0.95 * pen:
            grounded.append(i)
    grounded = grounded[trim:len(grounded) - trim]
    worst = 0.0
    by_section = [[0.0, 0] for _ in sections]
    for i in grounded:
        f = [0.0, 0.0, -0.5 * (elem[i - 1][1] * elem[i - 1][2] + elem[i][1] * elem[i][2])]
        for e, j in ((i - 1, i - 1), (i, i + 1)):
            u = [pos[j][k] - pos[i][k] for k in range(3)]
            n = math.sqrt(sum(x * x for x in u))
            for k in range(3):
                f[k] += ten[e] * u[k] / n
        util = math.hypot(f[0], f[1]) / (mu * -f[2])
        worst = max(worst, util)
        by_section[owner[i - 1]][0] = max(by_section[owner[i - 1]][0], util)
        by_section[owner[i - 1]][1] += 1
    return worst, len(grounded), max(abs(q[1]) for q in pos), by_section


def cross_grid(path: Path, depth0: float, slope_deg: float) -> None:
    """A seabed z = -(depth0 + tan(slope) y): planar in y, falling toward +y (across the line)."""
    t = math.tan(math.radians(slope_deg))
    rows = []
    for x in range(-300, 1000, 100):
        for y in (-300.0, 300.0):
            rows.append("%.1f %.1f %.12g" % (x, y, depth0 + t * y))
    path.write_text("\n".join(rows) + "\n", encoding="utf-8", newline="\n")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--output", required=True)
    a = ap.parse_args()
    root = Path(a.output).resolve()
    root.mkdir(parents=True, exist_ok=True)
    d, m, ea = CHAIN
    w = (m - RHO * math.pi / 4.0 * d * d) * G

    # --- EI = 0 run on a 5 degree slope (the R3 reproducer) ---
    cdir = root / "slope_ei0"
    cdir.mkdir(parents=True, exist_ok=True)
    depth0, slope = 260.6301014133342, 5.0
    slope_grid(cdir / "bathy.txt", depth0, slope)
    sb = "bathy.txt bathymetryFile"
    base = dict(ei=0.0, length=700.0, nseg=70, fair=(0, 0, -10), anch=(450, 0, -300), seabed=sb)
    rc, log = run(a.exe, cdir, "laid", deck("slope_ei0", **base))
    check(rc == 0, "slope_ei0 converges (rc %d)" % rc)
    if rc == 0:
        worst, total, past = grounded_balance(cdir, "laid", 700.0, 70, 1.0, depth0, slope)
        check(past < 0.5, "slope_ei0: the grounded run stays on its side of the anchor (%.3f m past it)" % past)
        check(worst <= 1.0 + 1.0e-3, "slope_ei0: friction within mu N at every grounded node (max %.4f)" % worst)
        check(worst > 0.5 * math.tan(math.radians(slope)),
              "slope_ei0: friction holds the slope load (max utilisation %.4f)" % worst)
    rc, log = run(a.exe, cdir, "none", deck("slope_ei0 none", **base, extra="none staticsFriction\n"))
    check(rc == 0, "slope_ei0 with staticsFriction none converges (rc %d)" % rc)
    if rc == 0:
        _, total, past = grounded_balance(cdir, "none", 700.0, 70, 1.0, depth0, slope)
        check(past > 10.0, "slope_ei0 frictionless static still folds past the anchor (%.2f m)" % past)
    rc, log = run(a.exe, cdir, "rest", deck("slope_ei0 rest", **base, tmax=2.0))
    check(rc == 0, "slope_ei0 at-rest march runs (rc %d)" % rc)
    if rc == 0:
        drift = at_rest(cdir, "laid", "rest")
        check(drift <= REST_TOL, "slope_ei0 stays at rest from the static state (drift %.2e of FairTen)" % drift)

    # --- finite-EI cable on a 10 degree slope, too long for its span ---
    cdir = root / "slope_fei"
    cdir.mkdir(parents=True, exist_ok=True)
    depth0, slope = 220.65285868119076, 10.0
    slope_grid(cdir / "bathy.txt", depth0, slope)
    fei = dict(ei=1.0e4, length=650.0, nseg=140, fair=(0, 0, -10), anch=(450, 0, -300), seabed=sb)
    rc, log = run(a.exe, cdir, "laid", deck("slope_fei", **fei))
    check(rc == 0, "slope_fei converges (rc %d)%s" % (rc, "" if rc == 0 else ": " + log.strip()[-300:]))
    if rc == 0:
        # the straight grounded run (away from the touchdown and the anchor, where the cable
        # bends) carries its slope load by friction: mobilised well above zero, within mu N
        worst, total, past = grounded_balance(cdir, "laid", 650.0, 140, 1.0, depth0, slope, band=0.35,
                                             end_trim=10)
        check(worst <= 1.0 + 1.0e-2, "slope_fei: friction within mu N along the straight run (max %.4f)" % worst)
        check(worst > 0.5 * math.tan(math.radians(slope)),
              "slope_fei: friction holds the slope load (max utilisation %.4f, tan(slope) %.4f)"
              % (worst, math.tan(math.radians(slope))))
        rc, log = run(a.exe, cdir, "rest", deck("slope_fei rest", **fei, tmax=1.0))
        check(rc == 0, "slope_fei at-rest march runs (rc %d)" % rc)
        if rc == 0:
            drift = at_rest(cdir, "laid", "rest")
            check(drift <= REST_TOL, "slope_fei stays at rest from the static state (drift %.2e)" % drift)

    # --- flat seabed: friction not mobilised when laid at the run's tension ---
    cdir = root / "flat"
    h_run = None  # the horizontal tension of the frictionless grounded run
    flat = dict(ei=0.0, length=850.0, nseg=85, fair=(-58, 0, -14), anch=(-837.6, 0, -200),
                seabed="200.0 WtrDpth", mu=0.5)
    rc0, _ = run(a.exe, cdir, "none", deck("flat none", **flat, extra="none staticsFriction\n"))
    check(rc0 == 0, "flat frictionless static converges")
    if rc0 == 0:
        r0 = table(cdir / "none.out")[0]
        h = abs(r0["Point2Fx"])  # the grounded run carries the anchor's horizontal tension
        h_run = h
        rc, _ = run(a.exe, cdir, "taut", deck("flat taut", **flat, extra="%.9g asLaidTension\n" % h))
        check(rc == 0, "flat laid at the run tension converges")
        if rc == 0:
            r1 = table(cdir / "taut.out")[0]
            # FairTen to 1e-4. AnchTen to 0.5 %: the anchor rests on the seabed surface and the
            # laid run one static penetration below it, so the run is drawn a fraction of a
            # millimetre toward the anchor and its friction springs add a small tension there
            # (the anchor-level effect Orcina's "OrcaFlex Friction Effects" note describes).
            for k, tol in (("FairTen1", 1.0e-4), ("AnchTen1", 5.0e-3)):
                rel = abs(r1[k] - r0[k]) / r0[k]
                check(rel < tol, "flat laid at the run tension: %s equals the frictionless %.6g N (rel %.1e)"
                      % (k, r0[k], rel))
        rc, _ = run(a.exe, cdir, "slack", deck("flat slack", **flat))
        check(rc == 0, "flat laid slack converges")
        if rc == 0:
            r2 = table(cdir / "slack.out")[0]
            drop = r0["AnchTen1"] - r2["AnchTen1"]
            check(0.0 < drop <= 0.5 * w * 850.0,
                  "flat laid slack: friction lowers AnchTen by %.4g N (within mu w L)" % drop)

    # --- finite-EI cable on a flat seabed, laid slack: lay azimuth across the chord ---
    # A lay azimuth off the vertical plane of the chord puts the reference (and its friction)
    # out of that plane, so the static solve is 3D from the start: the state is then an
    # equilibrium of the line (friction within mu N, a march from it stays at rest). At 180
    # degrees the reference lies in the plane, on the far side of the anchor: the planar solve
    # holds, and the friction saturates along the whole run, below the default's anchor tension.
    cdir = root / "fei_flat"
    kbot = 1.0e5
    fl = dict(ei=1.0e4, length=400.0, nseg=80, fair=(300, 0, -10), anch=(0, 0, -200),
              seabed="200.0 WtrDpth", mu=0.5)
    fsec = ((d, w, 400.0 / 80, 80),)
    fres = {}
    for tag, extra in (("def", ""), ("az45", "45.0 layAzimuth\n"), ("az180", "180.0 layAzimuth\n")):
        rc, log = run(a.exe, cdir, tag, deck("fei flat " + tag, **fl, extra=extra))
        check(rc == 0, "fei_flat %s converges (rc %d)%s" % (tag, rc, "" if rc == 0 else ": " + log.strip()[-300:]))
        if rc != 0:
            continue
        fres[tag] = table(cdir / (tag + ".out"))[0]
        util, ngr, maxy, _ = plateau_utilisation(cdir, tag, 0.5, -200.0, kbot, fsec)
        check(ngr > 10 and 0.1 < util <= 1.05,
              "fei_flat %s: friction within mu N over %d grounded nodes (max %.4f)" % (tag, ngr, util))
        if tag == "az45":
            check(maxy > 1.0, "fei_flat az45: the line leaves the chord plane (max |y| %.3f m)" % maxy)
        else:
            check(maxy < 1.0e-6, "fei_flat %s: the line stays in the chord plane (max |y| %.1e m)" % (tag, maxy))
        rc, _ = run(a.exe, cdir, tag + "_rest", deck("fei flat rest " + tag, **fl, extra=extra, tmax=1.0))
        check(rc == 0, "fei_flat %s at-rest march runs (rc %d)" % (tag, rc))
        if rc == 0:
            drift = at_rest(cdir, tag, tag + "_rest")
            check(drift <= REST_TOL, "fei_flat %s stays at rest from the static state (drift %.2e)" % (tag, drift))
    if "def" in fres and "az180" in fres:
        check(fres["az180"]["AnchTen1"] < 0.8 * fres["def"]["AnchTen1"],
              "fei_flat: the 180 degree reference flips (AnchTen %.4g below the default %.4g N)"
              % (fres["az180"]["AnchTen1"], fres["def"]["AnchTen1"]))

    # --- finite-EI cable on a cross slope, default lay azimuth ---
    # The nodes laid at rest sink into the penalty seabed along its normal, across the slope too;
    # the friction reference keeps that offset. A reference without it would leave the run shifted
    # down the slope by the sink, about w tan(slope)/(kBot d) = 1 cm, which the anchor would carry
    # as a lateral force of AnchTen times that shift over an element (about +0.4 kN, down the slope).
    # With it the lateral anchor force stays below that: up the slope for the EI = 0 line, whose end
    # force follows the chord of its first element, and in the plane of the floor for the finite-EI
    # one, whose end force follows the cable's end tangent less the part pressing into the floor and
    # the along-floor part of its end node's weight, which the friction holds.
    # The seabed slope across the chord
    # pushes the run out of its vertical plane against its friction, so the finite-EI line is solved
    # in 3D and a march from its static state stays at rest.
    cdir = root / "fei_cross"
    cdir.mkdir(parents=True, exist_ok=True)
    cross_grid(cdir / "bathy.txt", 200.0, 5.0)
    fy = {}
    for tag, ei in (("ei0", 0.0), ("fei", 1.0e4)):
        cd = dict(ei=ei, length=400.0, nseg=80, fair=(300, 0, -10), anch=(0, 0, -200), seabed=sb)
        rc, log = run(a.exe, cdir, tag, deck("fei cross " + tag, **cd))
        check(rc == 0, "fei_cross %s converges (rc %d)%s" % (tag, rc, "" if rc == 0 else ": " + log.strip()[-300:]))
        if rc == 0:
            r0 = table(cdir / (tag + ".out"))[0]
            # the anchor force of a run shifted down the slope by its sink
            ref = r0["AnchTen1"] * w / (1.0e5 * d) * math.tan(math.radians(5.0)) / 5.0
            fy[tag] = r0["Point2Fy"]
            if tag == "ei0":
                check(-0.5 * ref < fy[tag] < 0.0,
                      "fei_cross ei0: lateral anchor force %.4g N up the slope, within half the %.4g N of a "
                      "reference without the sink" % (fy[tag], ref))
            else:
                # A finite-EI end resting on the floor leaves the part of its end force pressing into
                # the floor to it, here the pull of the run sunk into the penalty seabed along the
                # slope's normal (about AnchTen delta / l0, whose lateral part the EI = 0 line keeps),
                # and the friction holds its end node's weight across the slope: what is left is the
                # run's pull in the plane of the floor, below the reference.
                check(abs(fy[tag]) < ref,
                      "fei_cross fei: lateral anchor force %.4g N in the plane of the floor, below the %.4g N of a "
                      "reference without the sink" % (fy[tag], ref))
        if rc == 0 and tag == "fei":
            rc, _ = run(a.exe, cdir, "fei_rest", deck("fei cross rest", **cd, tmax=1.0))
            check(rc == 0, "fei_cross fei at-rest march runs (rc %d)" % rc)
            if rc == 0:
                drift = at_rest(cdir, "fei", "fei_rest")
                check(drift <= REST_TOL, "fei_cross fei stays at rest from the static state (drift %.2e)" % drift)

    # --- finite-EI line with discrete buoyancy modules on a cross slope ---
    # Three modules (net buoyancy 8.09 kN, two thirds of a node's weight) on the grounded run of a
    # soft rope (EA 2e7 N: its laid slack run beyond the touchdown is held by friction at a small
    # tension, so it rests as laid). The static solve smears each module over its node's two
    # elements, then polishes to the discrete loads; the friction reference sinks every node under
    # those discrete loads, so a module node rests on the laid path as its neighbours do. A
    # reference built from the smeared weights would deflect each module node across the slope by
    # about half its net weight times tan(slope) over the nodal seabed stiffness (3.3 mm) and hold
    # that with a spurious friction force (the seabed stiffness times that kink). Checked: the
    # lateral kink of the line at the module nodes stays within a tenth of that and no larger than
    # in its smeared twin (each module spread over its node's two elements as a section), and a
    # march from the static state stays at rest.
    cdir = root / "att_cross"
    cdir.mkdir(parents=True, exist_ok=True)
    cross_grid(cdir / "bathy.txt", 200.0, 5.0)
    ea_soft, l_att, n_att, mods = 2.0e7, 600.0, 120, (450.0, 500.0, 550.0)
    m_mod, v_mod = 200.0, 1.0
    d_m = 0.5 * (m_mod - RHO * v_mod) / 5.0  # smeared mass per length over each of the two elements
    soft = f"chain {d} {m} {ea_soft} -1 1.0e4 1.37 0.64 1 0\n"
    ac = dict(ei=1.0e4, length=l_att, nseg=n_att, fair=(500, 0, -10), anch=(0, 0, -200), seabed=sb)
    att_rows = "".join("1 %.1f %.1f %.1f 0.0 0.0 0.0\n" % (s, m_mod, v_mod) for s in mods)
    secs, s0 = "", 0.0
    for s in mods:
        secs += "1 chain %.1f %d\n1 mod %.1f 2\n" % (s - 5.0 - s0, round((s - 5.0 - s0) / 5.0), 10.0)
        s0 = s + 5.0
    secs += "1 chain %.1f %d\n" % (l_att - s0, round((l_att - s0) / 5.0))
    twin_types = soft + f"mod {d} {m + d_m} {ea_soft} -1 1.0e4 1.37 0.64 1 0\n"
    ys = {}
    for tag, kw in (("discrete", dict(types=soft, attachments=att_rows)),
                    ("smeared", dict(types=twin_types, sections=secs))):
        rc, log = run(a.exe, cdir, tag, deck("att cross " + tag, **ac, **kw))
        check(rc == 0, "att_cross %s converges (rc %d)%s" % (tag, rc, "" if rc == 0 else ": " + log.strip()[-300:]))
        if rc != 0:
            continue
        p = first_row(cdir / (tag + ".Line1.p.out"))
        ys[tag] = [p[3 * i + 1] for i in range(len(p) // 3)]
        if tag == "discrete":
            rc, _ = run(a.exe, cdir, tag + "_rest", deck("att cross rest", **ac, **kw, tmax=1.0))
            check(rc == 0, "att_cross at-rest march runs (rc %d)" % rc)
            if rc == 0:
                drift = at_rest(cdir, tag, tag + "_rest")
                check(drift <= REST_TOL, "att_cross stays at rest from the static state (drift %.2e)" % drift)
    if len(ys) == 2:
        spurious = 0.5 * abs(m_mod - RHO * v_mod) * G * math.tan(math.radians(5.0)) / (1.0e5 * d * 5.0)

        def kink(y: list) -> float:
            """Largest lateral offset of a module node from the chord of its two neighbours [m]."""
            return max(abs(y[k] - 0.5 * (y[k - 1] + y[k + 1])) for k in (round(s / 5.0) for s in mods))

        kd, ks = kink(ys["discrete"]), kink(ys["smeared"])
        check(kd < 0.1 * spurious,
              "att_cross: no lateral kink at the module nodes (%.2e m, the smeared reference's %.2e m)" % (kd, spurious))
        check(kd <= ks,
              "att_cross: the module nodes rest on the laid path as closely as in the smeared twin (%.2e <= %.2e m)"
              % (kd, ks))

    # --- finite-EI cable laid on a shelf shallower than its radius, sloping across it ---
    # A light 0.5 m cable rests on a seabed 0.1 m deep (5 degrees across the line): its section
    # pierces the surface, and the static solve and the dynamics give back the buoyancy of the dry
    # part, about 2.3 times its submerged weight. The friction reference sinks every node under
    # that same normal load (the dry part at the node's sunk height), so the laid run rests on its
    # laid path, y = 0. A reference sunk under the submerged weight alone would hold the run down
    # the slope by the difference of the two sinks times tan(slope), about 0.8 mm, with a spurious
    # friction force. Checked: the run's nodes stay within a tenth of that of the laid path
    # (about 4e-6 m), and a march from the static state stays at rest.
    cdir = root / "shallow_cross"
    cdir.mkdir(parents=True, exist_ok=True)
    rows = []
    for x in range(-300, 1000, 100):
        for y in (-1.0, 1.0):
            rows.append("%.1f %.1f %.12g" % (x, y, 0.1 + math.tan(math.radians(5.0)) * y))
    (cdir / "bathy.txt").write_text("\n".join(rows) + "\n", encoding="utf-8", newline="\n")
    d_s, m_s = 0.5, 220.0
    w_s = (m_s - RHO * math.pi / 4.0 * d_s * d_s) * G
    sc = dict(ei=1.0e4, length=100.0, nseg=50, fair=(100.0, 0.0, -0.095), anch=(0.0, 0.0, -0.1), seabed=sb,
              types=f"chain {d_s} {m_s} 1.0e8 -1 1.0e4 1.2 0.008 1 0\n")
    rc, log = run(a.exe, cdir, "shallow", deck("shallow cross", **sc))
    check(rc == 0, "shallow_cross converges (rc %d)%s" % (rc, "" if rc == 0 else ": " + log.strip()[-300:]))
    if rc == 0:
        p = first_row(cdir / "shallow.Line1.p.out")
        # the run away from its two held ends, which rest at their deck positions above the
        # sunk run and bend it within a few elements of them
        y_run = [p[3 * i + 1] for i in range(5, len(p) // 3 - 5)]
        # the sink of a node under its submerged weight and under its load with the dry part
        kn_l = 1.0e5 * d_s
        dry_load = w_s
        for _ in range(100):
            u = max(-1.0, min(1.0, (-0.1 - dry_load / kn_l) / (0.5 * d_s)))
            phi = 1.0 - (math.acos(u) - u * math.sqrt(1.0 - u * u)) / math.pi
            dry_load = w_s + phi * RHO * G * math.pi / 4.0 * d_s * d_s
        spurious = (dry_load - w_s) / kn_l * math.tan(math.radians(5.0))
        dev = max(abs(y) for y in y_run)
        check(dev < 0.1 * spurious,
              "shallow_cross: the run rests on its laid path (%.2e m off it, a reference without the dry part "
              "would hold it %.2e m off)" % (dev, spurious))
        rc, _ = run(a.exe, cdir, "shallow_rest", deck("shallow cross rest", **sc, tmax=1.0))
        check(rc == 0, "shallow_cross at-rest march runs (rc %d)" % rc)
        if rc == 0:
            drift = at_rest(cdir, "shallow", "shallow_rest")
            check(drift <= REST_TOL, "shallow_cross stays at rest from the static state (drift %.2e)" % drift)

    # --- net-buoyant cable on a flat seabed shallower than its radius, soft seabed ---
    # A 0.5 m cable of 180 kg/m floats (its displaced water is 201 kg/m), held on a seabed 0.01 m
    # deep with kBot = 1000. A node held off the floor is wholly dry and one sunk under the dry
    # load wholly wet, so the full Newton step of the reference's dry load jumps between about
    # -208 and 728 N/m; the root (70.3 N/m, a sink of 0.14 m) lies between. Checked: the
    # halved steps reach it, the static solve converges, and a march from it stays at rest.
    cdir = root / "buoyant_shallow"
    cdir.mkdir(parents=True, exist_ok=True)
    rows = ["%.1f %.1f 0.01" % (x, y) for x in range(-300, 1000, 100) for y in (-300.0, 300.0)]
    (cdir / "bathy.txt").write_text("\n".join(rows) + "\n", encoding="utf-8", newline="\n")
    bs = dict(ei=1.0e4, length=100.0, nseg=50, fair=(100.0, 0.0, -0.005), anch=(0.0, 0.0, -0.01), seabed=sb,
              types="chain 0.5 180.0 1.0e8 -1 1.0e4 1.2 0.008 1 0\n")
    rc, log = run(a.exe, cdir, "buoyant", deck("buoyant shallow", **bs).replace("100000.0 kBot", "1000.0 kBot"))
    check(rc == 0, "buoyant_shallow converges (rc %d)%s" % (rc, "" if rc == 0 else ": " + log.strip()[-300:]))
    if rc == 0:
        rc, _ = run(a.exe, cdir, "buoyant_rest",
                    deck("buoyant shallow rest", **bs, tmax=1.0).replace("100000.0 kBot", "1000.0 kBot"))
        check(rc == 0, "buoyant_shallow at-rest march runs (rc %d)" % rc)
        if rc == 0:
            drift = at_rest(cdir, "buoyant", "buoyant_rest")
            check(drift <= REST_TOL, "buoyant_shallow stays at rest from the static state (drift %.2e)" % drift)

    # --- per-line rows, non-default azimuth and tension, anisotropic friction (EI = 0) ---
    cdir = root / "perline"
    keys = ("FairTen1", "AnchTen1", "Point1Fx", "Point2Fx", "Point1Fz")
    pl = {}
    cases = {
        "def": "",
        "g180": "180.0 layAzimuth\n",
        "g90": "90.0 layAzimuth\n",
        "p180": "90.0 layAzimuth\n180.0 layAzimuth1\n",
        "p180b": "180.0 layAzimuth1\n90.0 layAzimuth\n",
        "p90": "180.0 layAzimuth\n90.0 layAzimuth1\n",
    }
    if h_run is not None:
        cases.update({
            "gt": "%.9g asLaidTension\n" % h_run,
            "pt": "0.0 asLaidTension\n%.9g asLaidTension1\n" % h_run,
            "ptb": "%.9g asLaidTension1\n0.0 asLaidTension\n" % h_run,
            "pt0": "%.9g asLaidTension\n0.0 asLaidTension1\n" % h_run,
            "lay1": "180.0 layAzimuth1\n",
        })
    for tag, extra in cases.items():
        rc, log = run(a.exe, cdir, tag, deck("perline " + tag, **flat, extra=extra))
        check(rc == 0, "perline %s converges (rc %d)%s" % (tag, rc, "" if rc == 0 else ": " + log.strip()[-300:]))
        if rc == 0:
            pl[tag] = table(cdir / (tag + ".out"))[0]
    if {"def", "g180", "g90"} <= pl.keys():
        check(not same(pl["g180"], pl["def"], keys, 1.0e-3),
              "layAzimuth 180 changes the statics (AnchTen %.5g vs %.5g N)" % (pl["g180"]["AnchTen1"], pl["def"]["AnchTen1"]))
        check(not same(pl["g90"], pl["def"], keys, 1.0e-3) and not same(pl["g90"], pl["g180"], keys, 1.0e-3),
              "layAzimuth 90 gives its own statics (AnchTen %.5g N)" % pl["g90"]["AnchTen1"])
    if {"g180", "p180", "p180b", "g90"} <= pl.keys():
        check(same(pl["p180"], pl["g180"], keys) and same(pl["p180b"], pl["g180"], keys),
              "layAzimuth1 wins over layAzimuth, in either order (as the global 180)")
        check(not same(pl["p180"], pl["g90"], keys, 1.0e-3), "layAzimuth1 differs from the global value it overrides")
    if {"g180", "p90", "g90"} <= pl.keys():
        check(same(pl["p90"], pl["g90"], keys), "layAzimuth1 wins over layAzimuth (90 over 180)")
    if {"def", "gt", "pt", "ptb", "pt0", "lay1"} <= pl.keys():
        check(not same(pl["gt"], pl["def"], keys, 1.0e-3),
              "asLaidTension changes the statics (AnchTen %.5g vs %.5g N)" % (pl["gt"]["AnchTen1"], pl["def"]["AnchTen1"]))
        check(same(pl["pt"], pl["gt"], keys) and same(pl["ptb"], pl["gt"], keys),
              "asLaidTension1 wins over asLaidTension, in either order (as the global value)")
        check(same(pl["pt0"], pl["def"], keys), "asLaidTension1 0 wins over a global tension (as the default)")
        check(not same(pl["lay1"], pl["def"], keys, 1.0e-3), "layAzimuth1 alone takes effect")

    # two lines: a row for line 2 leaves line 1 alone
    two = {}
    for tag, extra in (("def", ""), ("g180", "180.0 layAzimuth\n"), ("l2", "180.0 layAzimuth2\n")) + (
            (("gt", "%.9g asLaidTension\n" % h_run), ("t2", "%.9g asLaidTension2\n" % h_run)) if h_run else ()):
        rc, log = run(a.exe, cdir, "two_" + tag, deck_two("two lines " + tag, extra=extra))
        check(rc == 0, "two lines %s converge (rc %d)" % (tag, rc))
        if rc == 0:
            two[tag] = table(cdir / ("two_" + tag + ".out"))[0]

    def of_line(row: dict, i: int) -> dict:
        return {"FairTen1": row["FairTen%d" % i], "AnchTen1": row["AnchTen%d" % i]}

    if {"def", "g180", "l2"} <= two.keys():
        k2 = ("FairTen1", "AnchTen1")
        check(same(of_line(two["def"], 1), of_line(two["def"], 2), k2), "two lines: identical lines give identical statics")
        check(same(of_line(two["l2"], 1), of_line(two["def"], 1), k2),
              "two lines: layAzimuth2 leaves line 1 at the default")
        check(same(of_line(two["l2"], 2), of_line(two["g180"], 2), k2) and
              not same(of_line(two["l2"], 2), of_line(two["def"], 2), k2, 1.0e-3),
              "two lines: layAzimuth2 sets line 2 alone (AnchTen2 %.5g N)" % two["l2"]["AnchTen2"])
    if {"def", "gt", "t2"} <= two.keys():
        k2 = ("FairTen1", "AnchTen1")
        check(same(of_line(two["t2"], 1), of_line(two["def"], 1), k2), "two lines: asLaidTension2 leaves line 1 alone")
        check(same(of_line(two["t2"], 2), of_line(two["gt"], 2), k2) and
              not same(of_line(two["t2"], 2), of_line(two["def"], 2), k2, 1.0e-3),
              "two lines: asLaidTension2 sets line 2 alone (AnchTen2 %.5g N)" % two["t2"]["AnchTen2"])

    # anisotropic friction: along a run laid and pulled along the chord the axial coefficient rules
    cdir = root / "aniso"
    an = {}
    for tag, mu_iso, extra in (("iso05", 0.5, ""), ("iso02", 0.2, ""),
                               ("ax05_lat02", 0.5, "0.2 frictionMuLateral\n"),
                               ("ax02_lat05", 0.2, "0.5 frictionMuLateral\n")):
        fa = dict(flat, mu=mu_iso)
        rc, log = run(a.exe, cdir, tag, deck("aniso " + tag, **fa, extra=extra))
        check(rc == 0, "aniso %s converges (rc %d)%s" % (tag, rc, "" if rc == 0 else ": " + log.strip()[-300:]))
        if rc == 0:
            an[tag] = table(cdir / (tag + ".out"))[0]
    if len(an) == 4:
        k1 = ("FairTen1", "AnchTen1")
        check(not same(an["iso05"], an["iso02"], k1, 1.0e-2), "aniso: the coefficient changes the anchor tension")
        check(same(an["ax05_lat02"], an["iso05"], k1, 2.0e-3),
              "aniso: axial 0.5 / lateral 0.2 acts as the isotropic 0.5 along the chord (AnchTen %.5g vs %.5g N)"
              % (an["ax05_lat02"]["AnchTen1"], an["iso05"]["AnchTen1"]))
        check(same(an["ax02_lat05"], an["iso02"], k1, 2.0e-3),
              "aniso: axial 0.2 / lateral 0.5 acts as the isotropic 0.2 along the chord (AnchTen %.5g vs %.5g N)"
              % (an["ax02_lat05"]["AnchTen1"], an["iso02"]["AnchTen1"]))

    # --- a line of three sections of different weights: friction within mu N everywhere ---
    cdir = root / "multi"
    light = (0.1, 40.0, 5.0e8)  # diameter [m], mass [kg/m], EA [N]
    wl = (light[1] - RHO * math.pi / 4.0 * light[0] ** 2) * G
    mtypes = (f"chain {d} {m} {ea} -1 0 1.37 0.64 1 0\n"
              f"light {light[0]} {light[1]} {light[2]} -1 0 1.2 0.6 1 0\n")
    msecs = "1 chain 300 60\n1 light 300 60\n1 chain 250 50\n"
    rc, log = run(a.exe, cdir, "multi", deck("multi", ei=0.0, length=850.0, nseg=170, fair=(-58, 0, -14),
                                             anch=(-837.6, 0, -200), seabed="200.0 WtrDpth", mu=0.5,
                                             types=mtypes, sections=msecs))
    check(rc == 0, "multi converges (rc %d)%s" % (rc, "" if rc == 0 else ": " + log.strip()[-300:]))
    if rc == 0:
        msec = ((d, w, 5.0, 60), (light[0], wl, 5.0, 60), (d, w, 5.0, 50))
        util, ngr, _, by_sec = plateau_utilisation(cdir, "multi", 0.5, -200.0, kbot, msec)
        check(by_sec[1][1] > 5 and by_sec[2][1] > 5,
              "multi: the grounded run spans the light (%d nodes) and the heavy (%d) section" % (by_sec[1][1], by_sec[2][1]))
        check(util <= 1.01, "multi: friction within mu N at every grounded node (max %.4f)" % util)
        check(by_sec[1][0] > 0.9 and by_sec[2][0] > 0.5,
              "multi: friction mobilised to mu N in the light section and beyond in the heavy (%.3f, %.3f)"
              % (by_sec[1][0], by_sec[2][0]))

    # --- a refined mesh is laid as its own deck would be ---
    # A finite-EI line of two sections (the light one grounded at the anchor end) laid at a
    # tension on a seabed curved along the line and sloping across it, on a 20 m deck mesh that
    # the adaptive refinement takes to 1.25 m (16x). The friction reference of the refined solve
    # is laid on the refined mesh itself (path, sink under each node's lumped weight over its
    # seabed stiffness, turning force of the laid tension), so the run reaches the equilibrium
    # of its twin declared on that 1.25 m mesh to solver precision. A reference interpolated
    # from the 20 m deck nodes misplaces the sink of the refined nodes next to the section
    # change (about 1 mm across the slope) and the turning force along the curved floor, which
    # moves the run (the lateral anchor force changes sign, AnchTen moves by about 8 N). The
    # refined run marched for 1 s stays at rest.
    cdir = root / "refined"
    cdir.mkdir(parents=True, exist_ok=True)
    rows = ["%.1f %.1f %.12g" % (x, y, 200.0 + 1.0e-4 * x * x + 0.05 * y)
            for x in range(-300, 1000, 10) for y in (-300.0, 300.0)]
    (cdir / "bathy.txt").write_text("\n".join(rows) + "\n", encoding="utf-8", newline="\n")
    rtypes = (f"chain {d} {m} {ea} -1 1.0e4 1.37 0.64 1 0\n"
              f"light {light[0]} {light[1]} {light[2]} -1 1.0e4 1.2 0.6 1 0\n")
    rpos = {}
    for tag, nseg, extra in (("coarse", 20, "True adaptive_mesh\n"), ("fine", 320, "")):
        rd = dict(ei=1.0e4, length=400.0, nseg=nseg, fair=(300, 0, -10), anch=(0, 0, -200), seabed=sb, mu=0.5,
                  types=rtypes, sections="1 chain 300 %d\n1 light 100 %d\n" % (nseg * 3 // 4, nseg // 4))
        ex = extra + "50000 asLaidTension\n"
        rc, log = run(a.exe, cdir, tag, deck("refined " + tag, **rd, extra=ex))
        check(rc == 0, "refined %s converges (rc %d)%s" % (tag, rc, "" if rc == 0 else ": " + log.strip()[-300:]))
        if rc != 0:
            continue
        p = first_row(cdir / (tag + ".Line1.p.out"))
        rpos[tag] = ([p[3 * i:3 * i + 3] for i in range(len(p) // 3)], table(cdir / (tag + ".out"))[0])
        if tag == "coarse":
            check(len(rpos[tag][0]) == 321, "refined: the 20-element deck mesh is refined to 320 elements (%d nodes)"
                  % len(rpos[tag][0]))
            rc, _ = run(a.exe, cdir, "coarse_rest", deck("refined rest", **rd, extra=ex, tmax=1.0))
            check(rc == 0, "refined at-rest march runs (rc %d)" % rc)
            if rc == 0:
                drift = at_rest(cdir, "coarse", "coarse_rest")
                check(drift <= REST_TOL, "refined stays at rest from the static state (drift %.2e)" % drift)
    if len(rpos) == 2 and len(rpos["coarse"][0]) == len(rpos["fine"][0]):
        dpos = max(abs(u[k] - v[k]) for u, v in zip(rpos["coarse"][0], rpos["fine"][0]) for k in range(3))
        check(dpos < 1.0e-6, "refined: the refined run rests where its twin on the refined mesh does (%.1e m)" % dpos)
        rc_, rf_ = rpos["coarse"][1], rpos["fine"][1]
        check(same(rc_, rf_, ("FairTen1", "AnchTen1", "Point2Fx"), 1.0e-7) and abs(rc_["Point2Fy"] - rf_["Point2Fy"]) < 0.1,
              "refined: end forces as on the refined mesh (AnchTen %.6g / %.6g N, anchor Fy %.4g / %.4g N)"
              % (rc_["AnchTen1"], rf_["AnchTen1"], rc_["Point2Fy"], rf_["Point2Fy"]))

    # --- input checks ---
    cdir = root / "inputs"
    rc, log = run(a.exe, cdir, "badid", deck("bad id", **flat, extra="30.0 layAzimuth9\n"))
    check(rc != 0 and "names no LINE" in log, "layAzimuth9 without a line 9 is rejected")
    rc, log = run(a.exe, cdir, "badpolicy", deck("bad policy", **flat, extra="restart staticsFriction\n"))
    check(rc != 0 and "asLaid or none" in log, "an unknown staticsFriction policy is rejected")
    rc, log = run(a.exe, cdir, "goodid", deck("good id", **flat, extra="180.0 layAzimuth1\n0 asLaidTension1\n"))
    check(rc == 0, "layAzimuth1 / asLaidTension1 rows are accepted")
    if rc == 0 and "g180" in pl:
        # the rows are not only accepted: line 1 is laid at 180 degrees (as the global row does)
        check(same(table(cdir / "goodid.out")[0], pl["g180"], keys),
              "layAzimuth1 180 / asLaidTension1 0 act as the global 180 degree lay")
    if h_run is not None:
        rc, log = run(a.exe, cdir, "goodid_t", deck("good id t", **flat, extra="%.9g asLaidTension1\n" % h_run))
        check(rc == 0, "asLaidTension1 row is accepted")
        if rc == 0 and "gt" in pl and "def" in pl:
            row = table(cdir / "goodid_t.out")[0]
            check(same(row, pl["gt"], keys) and not same(row, pl["def"], keys, 1.0e-3),
                  "asLaidTension1 takes effect (AnchTen %.5g vs %.5g N laid slack)" % (row["AnchTen1"], pl["def"]["AnchTen1"]))
    rc, log = run(a.exe, cdir, "hugeid", deck("huge id", **flat, extra="30.0 layAzimuth99999999999\n"))
    check(rc != 0 and "names no LINE" in log, "layAzimuth with an integer suffix too large for a line ID is rejected")
    rc, log = run(a.exe, cdir, "hugeidt", deck("huge id t", **flat, extra="1.0 asLaidTension99999999999999999999\n"))
    check(rc != 0 and "names no LINE" in log, "asLaidTension with an integer suffix too large for a line ID is rejected")
    rc, log = run(a.exe, cdir, "badsuffix", deck("bad suffix", **flat, extra="30.0 layAzimuth1x\n"))
    check(rc != 0 and "unknown OPTION keyword" in log, "layAzimuth1x is an unknown keyword")
    rc, log = run(a.exe, cdir, "badtension", deck("bad tension", **flat, extra="-1.0 asLaidTension1\n"))
    check(rc != 0 and "asLaidTension1" in log, "a negative asLaidTension1 is rejected")
    rc, log = run(a.exe, cdir, "hugetension", deck("huge tension", **flat, extra="1.0e30 asLaidTension\n"))
    check(rc != 0 and "more than 100 %" in log, "an asLaidTension above EA fails closed instead of overflowing")
    # every row is validated, also one a later row for the same line overrides
    rc, log = run(a.exe, cdir, "shadowt", deck("shadowed tension", **flat,
                                             extra="-1.0 asLaidTension1\n0.0 asLaidTension1\n"))
    check(rc != 0 and "asLaidTension1" in log, "a negative asLaidTension1 shadowed by a valid row is rejected")
    rc, log = run(a.exe, cdir, "shadowaz", deck("shadowed azimuth", **flat,
                                              extra="nan layAzimuth1\n30.0 layAzimuth1\n"))
    check(rc != 0 and "layAzimuth1" in log, "a NaN layAzimuth1 shadowed by a valid row is rejected")

    # a finite-EI line shared between two turbines (both ends moving) has no anchored end to lay it
    # from: asLaid fails closed by name, none runs
    shared = dict(ei=1.0e4, length=600.0, nseg=60, fair=(0, 0, -10), anch=(0, 0, -10), seabed="200.0 WtrDpth", mu=0.5)
    for tag, extra in (("shared", ""), ("shared_none", "none staticsFriction\n")):
        txt = deck("shared " + tag, **shared, extra=extra, tmax=0.2)
        txt = txt.replace("1 Coupled", "1 Turbine1").replace("2 Fixed", "2 Turbine2")
        txt = txt.replace("--------------------- LINES ---",
                          "--------------------- TURBINES ---\nJ X0 Y0 Z0\n(-) (m) (m) (m)\n1 0 0 0\n2 300 0 0\n"
                          "--------------------- LINES ---")
        txt = txt.replace('"Point1Fx"\n"Point1Fy"\n"Point1Fz"\n"Point2Fx"\n"Point2Fy"\n"Point2Fz"\n', "")
        rc, log = run(a.exe, cdir, tag, txt)
        if tag == "shared":
            check(rc != 0 and "moving End B" in log, "asLaid on a line with a moving End B (shared line) is rejected")
        else:
            check(rc == 0, "the shared line runs with staticsFriction none (rc %d)" % rc)

    print("static friction as laid: %d failure(s)" % len(FAILURES))
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
