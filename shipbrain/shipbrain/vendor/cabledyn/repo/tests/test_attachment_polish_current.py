#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Discrete buoyancy modules in an oblique or cross current: the attachment polish converges cleanly.

The static solve of a line with ATTACHMENTS first finds the equilibrium with the modules smeared
over the elements beside their nodes, then carries it to the lumped loads by a homotopy (the
attachment polish). The smeared start carried the modules' weight but not their current drag, so
the polish applied the whole module drag to it: on the frictional seabed of
``tests/data/lazy_wave_touchdown_planar_coarse_att.dat`` (friction 0.35) in a current across the
line's plane, its damped Newton solves diverged as the grounded run slid metres sideways, and the
discrete state was reached only through the pseudo-transient and line-search fallbacks (25
modules, 2 m elements, 0.3 m/s at 90 deg: the first load step of 1/8 failed). In a current
across the line's plane the smeared start now carries the module drag too, and the polish moves it
to the nodes with the weight (a current along the plane keeps the former path: the in-plane
control below).

Gates:

1. Robustness, on the frictional lazy wave with its 96 m buoyant stretch rebuilt from 10, 25 or 40
   modules (the same total mass, volume and drag area), on the deck's 4 m / 10 m grading with the
   buoyant section at 1, 2 or 4 times its node density, or on 2 m elements throughout with that
   section refined again, in a uniform current of 0.1 to 0.5 m/s at 45 or 90 deg to the line's
   plane (and two controls: still water and an in-plane current): every deck solves (exit 0)
   without a fallback note ("reached after a failed Newton solve", "stalled", "looser
   tolerance"), and the line's mean out-of-plane offset has the sign of the current's cross
   component.
2. Physics, on the lazy wave of ``examples/lazy_wave_buoyancy_modules.dat`` hung in mid-water (the
   seabed lowered to 300 m, so no contact force enters the balance) with 25 or 40 modules in 0.3 or
   0.5 m/s at 45 or 90 deg: the end forces the line puts on its two points (C API, double
   precision) balance its weight and buoyancy, the modules' net weight and the current drag of
   cable (three-point Gauss on the Hermite centreline rebuilt from the node positions and
   tangents) and modules (at their nodes) to 1e-6 of the largest load, and the line deflects
   toward the current's cross component. The C API's declination and azimuth are a central
   difference of the node positions, which is not the tangent at a module node (the curvature
   jumps there), so a module's tangent is the mean of the one-sided fourth-order differences.
3. Torsion, on ``tests/data/lazy_wave_torsion_attachments.dat`` (the frictional lazy wave restrained
   in torsion with one turn of pretwist) in 0.3 m/s at 45 deg: the deck solves without a fallback
   note and its torsion stage reports the twist solved (it stopped before in the smeared stage).

usage: test_attachment_polish_current.py --exe <cabledyn> --library <libcabledyn> --source <repo>
                                         --output <dir>
"""

from __future__ import annotations

import argparse
import math
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np

FALLBACK_NOTES = ("reached after a failed Newton solve", "stalled", "looser tolerance")
BALANCE_TOL = 1.0e-6

# (mesh, speed m/s, heading deg from the line's plane, modules, buoyant-section refinement).
# mesh "deck": the deck's 4 m / 10 m grading; "fine": 2 m elements throughout. Every case but the
# two controls reached its discrete state only through the polish's fallbacks before.
ROBUST_CASES = [
    ("fine", 0.3, 90, 25, 1),
    ("fine", 0.3, 90, 25, 4),
    ("fine", 0.3, 90, 40, 2),
    ("fine", 0.3, 45, 40, 4),
    ("fine", 0.1, 90, 10, 4),
    ("fine", 0.1, 45, 25, 1),
    ("fine", 0.2, 45, 10, 2),
    ("fine", 0.2, 90, 40, 4),
    ("fine", 0.5, 45, 40, 2),
    ("fine", 0.5, 45, 25, 1),
    ("deck", 0.2, 90, 25, 4),
    ("deck", 0.5, 45, 10, 2),
    ("deck", 0.5, 45, 40, 4),
    ("deck", 0.5, 45, 25, 1),
    ("fine", 0.0, 0, 25, 2),
    ("fine", 0.3, 0, 25, 2),
]
# (speed, heading, modules, refinement) on the mid-water lazy wave
BALANCE_CASES = [(0.3, 90, 25, 2), (0.5, 90, 40, 4), (0.3, 45, 25, 4), (0.5, 90, 25, 4)]
# (speed, heading) on the lazy wave restrained in torsion
TORSION_CASES = [(0.3, 45)]

RHO, G = 1025.0, 9.80665
# examples/lazy_wave_buoyancy_modules.dat: the bare cable and its ten modules over 70.614-115.614 m
GOMEX_D, GOMEX_M, GOMEX_EA, GOMEX_CDN, GOMEX_CDT = 0.16, 36.70, 4.69e8, 1.2, 0.1
GOMEX_MOD = (114.15, 0.2297, 0.78, 0.2042)


def current_row(speed: float, heading: float) -> str:
    th = math.radians(heading)
    ux, uy = round(speed * math.cos(th), 12) + 0.0, round(speed * math.sin(th), 12) + 0.0
    return "uniform %.12g %.12g 0.0 current" % (ux, uy)


def touchdown_deck(source: Path, mesh: str, speed: float, heading: float, n_mod: int, refine: int) -> str:
    """The frictional lazy wave with n_mod modules over 80-176 m (25 at 4 m in the deck)."""
    text = (source / "tests" / "data" / "lazy_wave_touchdown_planar_coarse_att.dat").read_text()
    pitch = 96.0 / (n_mod - 1)
    per_pitch = max(1, round(pitch / 4.0))
    g = 2 if mesh == "fine" else 1
    rows = "4 bare 80.0 %d\n4 bare 96.0 %d\n4 bare 424.0 %d\n" % (
        20 * g, (n_mod - 1) * per_pitch * refine * g, 170 if mesh == "fine" else 42)
    text = re.sub(r"(-+ SECTIONS -+\n.*\n.*\n)(?:4 .*\n)+", lambda m: m.group(1) + rows, text)
    s = 25.0 / n_mod
    att = "4 80.0:%.10g:176.0 %.6g %.6g %.6g 1.0 0.0\n" % (pitch, 91.32 * s, 0.18378 * s, 1.392 * s)
    text = re.sub(r"(-+ ATTACHMENTS -+\n.*\n.*\n)(?:4 .*\n)+", lambda m: m.group(1) + att, text)
    if speed:
        text = re.sub(r"^(0\.0 TMax)$", lambda m: m.group(1) + "\n" + current_row(speed, heading), text,
                      count=1, flags=re.M)
    return text


def torsion_deck(source: Path, speed: float, heading: float) -> str:
    """tests/data/lazy_wave_torsion_attachments.dat, static only, in a uniform current."""
    text = (source / "tests" / "data" / "lazy_wave_torsion_attachments.dat").read_text()
    text, n = re.subn(r"^\S+(\s+TMax)$", lambda m: "0.0" + m.group(1) + "\n" + current_row(speed, heading), text,
                      count=1, flags=re.M)
    if n != 1:
        raise RuntimeError("the torsion deck has no TMax row")
    return text


def gomex_sections(n_mod: int, refine: int) -> list[tuple[float, int]]:
    return [(70.614, 71), (45.0, (n_mod - 1) * max(1, round(45.0 / (n_mod - 1))) * refine), (54.601, 55)]


def midwater_deck(source: Path, speed: float, heading: float, n_mod: int, refine: int) -> str:
    """examples/lazy_wave_buoyancy_modules.dat with n_mod modules (the same totals), seabed at 300 m."""
    text = (source / "examples" / "lazy_wave_buoyancy_modules.dat").read_text()
    rows = "".join("1 bare %.3f %d\n" % sec for sec in gomex_sections(n_mod, refine))
    text = re.sub(r"(-+ SECTIONS -+\n.*\n.*\n)(?:1 .*\n)+", lambda m: m.group(1) + rows, text)
    s = 10.0 / n_mod
    m, v, cda, cdax = (x * s for x in GOMEX_MOD)
    att = "1 70.614:%.10g:115.614 %.6g %.6g %.6g 1.0 %.6g\n" % (45.0 / (n_mod - 1), m, v, cda, cdax)
    text = re.sub(r"(-+ ATTACHMENTS -+\n.*\n.*\n)(?:1 .*\n)+", lambda m_: m_.group(1) + att, text)
    text = re.sub(r"^uniform 0\.5 0\.0 0\.0 .*$", current_row(speed, heading), text, count=1, flags=re.M)
    text = re.sub(r"^80\.0(\s+WtrDpth)", r"300.0\1", text, count=1, flags=re.M)
    text = re.sub(r'^"TDP1[sx]"\n', "", text, flags=re.M)
    return text


def run(exe: str, d: Path, text: str) -> tuple[int, str]:
    d.mkdir(parents=True, exist_ok=True)
    (d / "deck.dat").write_text(text, newline="\n")
    p = subprocess.run([exe, "deck.dat", "o"], cwd=d, capture_output=True, text=True, timeout=1200)
    return p.returncode, p.stdout + p.stderr


def static_y(d: Path) -> np.ndarray:
    lines = (d / "o.static.out").read_text().splitlines()[3:]
    return np.array([float(ln.split()[4]) for ln in lines if ln.strip()])


def morison(u: np.ndarray, t: np.ndarray, d: float, cdn: float, cdt: float) -> np.ndarray:
    t = t / np.linalg.norm(t)
    ut = np.dot(u, t) * t
    un = u - ut
    return 0.5 * RHO * d * (cdn * np.linalg.norm(un) * un + math.pi * cdt * np.linalg.norm(ut) * ut)


def balance(deck: Path, speed: float, heading: float, n_mod: int, refine: int) -> tuple[float, float]:
    """(|end forces - loads| / largest load, mean y offset) of the static state through the C API."""
    from cabledyn import CableDyn

    with CableDyn(deck) as model:
        line = model.line(1)
        x = np.array(line.node_positions())
        ten = np.array(line.node_tensions())
        dec, azi = np.radians(line.declination()), np.radians(line.azimuth())
        ends = np.array([model.channel("Point1F" + c) + model.channel("Point2F" + c) for c in "xyz"])
        largest = max(abs(model.channel("FairTen1")), abs(model.channel("AnchTen1")))
    l0 = np.concatenate([np.full(n, length / n) for length, n in gomex_sections(n_mod, refine)])
    if len(x) != len(l0) + 1:
        raise RuntimeError("the static solve refined the mesh (%d nodes)" % len(x))
    tan = np.stack([np.sin(dec) * np.cos(azi), np.sin(dec) * np.sin(azi), np.cos(dec)], 1)
    m = tan * (1.0 + ten / GOMEX_EA)[:, None]   # dr/ds, the stretch from the tension
    th = math.radians(heading)
    u = np.array([round(speed * math.cos(th), 12), round(speed * math.sin(th), 12), 0.0])
    w_bare = (GOMEX_M - RHO * math.pi / 4.0 * GOMEX_D**2) * G
    load = np.array([0.0, 0.0, -w_bare * l0.sum()])
    gx = [0.5 - 0.5 * math.sqrt(0.6), 0.5, 0.5 + 0.5 * math.sqrt(0.6)]
    gw = [5.0 / 18.0, 8.0 / 18.0, 5.0 / 18.0]
    for e, le in enumerate(l0):
        for xi, wgt in zip(gx, gw):
            dh = [(-6 * xi + 6 * xi**2) / le, 1 - 4 * xi + 3 * xi**2, (6 * xi - 6 * xi**2) / le, -2 * xi + 3 * xi**2]
            rp = dh[0] * x[e] + dh[1] * m[e] + dh[2] * x[e + 1] + dh[3] * m[e + 1]
            load += wgt * le * np.linalg.norm(rp) * morison(u, rp, GOMEX_D, GOMEX_CDN, GOMEX_CDT)
    s = 10.0 / n_mod
    mass, vol, cda, cdax = (v * s for v in GOMEX_MOD)
    cum = np.concatenate([[0.0], np.cumsum(l0)])
    for k in range(n_mod):
        j = int(np.argmin(np.abs(cum - (70.614 + k * 45.0 / (n_mod - 1)))))
        load[2] -= (mass - RHO * vol) * G
        tl = 25 * x[j] - 48 * x[j - 1] + 36 * x[j - 2] - 16 * x[j - 3] + 3 * x[j - 4]
        tr = -25 * x[j] + 48 * x[j + 1] - 36 * x[j + 2] + 16 * x[j + 3] - 3 * x[j + 4]
        t = tl / np.linalg.norm(tl) + tr / np.linalg.norm(tr)
        t /= np.linalg.norm(t)
        ut = np.dot(u, t) * t
        un = u - ut
        load += 0.5 * RHO * (cda * np.linalg.norm(un) * un + cdax * np.linalg.norm(ut) * ut)
    largest = max(largest, abs(load[2]))
    return float(np.abs(ends - load).max() / largest), float(x[:, 1].mean())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--library", required=True)
    ap.add_argument("--source", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--jobs", type=int, default=4)
    a = ap.parse_args()
    exe = str(Path(a.exe).resolve())
    source = Path(a.source)
    out = Path(a.output)
    failures: list[str] = []

    def robust(case):
        mesh, speed, heading, n_mod, refine = case
        name = "%s_U%.1f_h%d_N%d_r%d" % case
        rc, log = run(exe, out / name, touchdown_deck(source, mesh, speed, heading, n_mod, refine))
        return name, case, rc, log

    def solve_balance(case):
        speed, heading, n_mod, refine = case
        name = "midwater_U%.1f_h%d_N%d_r%d" % case
        rc, log = run(exe, out / name, midwater_deck(source, speed, heading, n_mod, refine))
        return name, case, rc, log

    def torsion(case):
        speed, heading = case
        name = "torsion_U%.1f_h%d" % case
        rc, log = run(exe, out / name, torsion_deck(source, speed, heading))
        return name, rc, log

    with ThreadPoolExecutor(a.jobs) as pool:
        torsion_runs = pool.map(torsion, TORSION_CASES)
        robust_runs = list(pool.map(robust, ROBUST_CASES))
        balance_runs = list(pool.map(solve_balance, BALANCE_CASES))
        torsion_runs = list(torsion_runs)

    for name, (mesh, speed, heading, n_mod, refine), rc, log in robust_runs:
        notes = [n for n in FALLBACK_NOTES if n in log]
        y = static_y(out / name).mean() if rc == 0 else float("nan")
        uy = speed * math.sin(math.radians(heading))
        print("%-26s exit %d  fallback notes %s  mean y %+.4f m" % (name, rc, notes or "none", y))
        if rc != 0:
            failures.append("%s: exit %d\n%s" % (name, rc, log[-1500:]))
        elif notes:
            failures.append("%s: the static solve needed a fallback (%s)" % (name, ", ".join(notes)))
        elif (uy > 0.0 and not y > 0.0) or (uy == 0.0 and abs(y) > 1.0e-9):
            failures.append("%s: mean out-of-plane offset %.3e m against a cross current %.3f m/s" % (name, y, uy))

    for name, rc, log in torsion_runs:
        notes = [n for n in FALLBACK_NOTES if n in log]
        solved = "torsion solved" in log
        print("%-26s exit %d  fallback notes %s  torsion solved %s" % (name, rc, notes or "none", solved))
        if rc != 0 or notes or not solved:
            failures.append("%s: exit %d, fallback notes %s, torsion solved %s\n%s" % (name, rc, notes, solved,
                                                                                    log[-1500:]))

    os.environ["CABLEDYN_LIBRARY"] = str(Path(a.library).resolve())
    sys.path.insert(0, str(source / "python"))
    for name, (speed, heading, n_mod, refine), rc, log in balance_runs:
        notes = [n for n in FALLBACK_NOTES if n in log]
        if rc != 0 or notes:
            failures.append("%s: exit %d, fallback notes %s\n%s" % (name, rc, notes, log[-1500:]))
            continue
        err, y = balance(out / name / "deck.dat", speed, heading, n_mod, refine)
        print("%-26s force balance %.2e of the largest load  mean y %+.4f m" % (name, err, y))
        if not err <= BALANCE_TOL:
            failures.append("%s: the end forces miss the line's loads by %.2e of the largest load" % (name, err))
        if not y > 0.0:
            failures.append("%s: mean out-of-plane offset %.3e m against the current" % (name, y))

    for f in failures:
        print("FAIL: " + f)
    if failures:
        return 1
    print("PASS: the attachment polish converges cleanly in oblique and cross currents, in force balance")
    return 0


if __name__ == "__main__":
    sys.exit(main())
