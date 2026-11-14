#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Finite-EI cable statics robustness matrix.

A deterministic sample of finite-EI (cubic-Hermite) cable decks drawn from a seeded
robustness study: lazy waves (single and modular buoyancy, some floating at the
surface), steep and lazy-S waves, heavy catenaries, lines hung in mid-water, sloped
and rough structured seabeds, azimuthal layouts, rotationally restrained hang-offs, current and
friction options, mixed mooring + cable decks, refined meshes, and metamorphic twins
(translated, rotated, anchor-first, split sections, constant-depth grid). Every deck is
run through the standalone driver and checked against its committed expectation:

* ``admissible`` decks (an EI = 0 catenary root exists) must converge (exit 0) within the
  per-deck CPU-time limit, to a state whose nodal polyline does not cross itself, with a
  fairlead end force within 15 % of an EI = 0 root when the bending length is under 5 % of
  the line, and with no nodal compression beyond a tenth of the peak tension unless the
  log reports it (a mesh or a bending-supported compression note); a line with a recorded
  ``reference_tfair`` (an independent solver's fairlead force, e.g. a bow held by its bending
  stiffness where no EI = 0 root exists) must match it to 1 %;
* ``inadmissible`` decks (too long for their span to hang as a catenary, and no
  equilibrium held by the bending stiffness either) must fail closed with the named
  geometric reason;
* ``tensile_reject`` decks (tensile_safety True, genuine compression) must fail closed
  naming the axial compression;
* ``current_compression`` decks (a current pushing the grounded run along the frictionless
  seabed into compression: no tension-only equilibrium) must fail closed with that diagnosis;
* ``current_friction_compression`` decks (on a frictional seabed the current pushes the
  suspended span into the friction-held touchdown before any tension-only equilibrium is
  reached from the still-water layout) must fail closed with that diagnosis; a deck's ``why``
  records the evidence;
* an admissible deck with a ``note`` must print it: a very strong current on a frictionless
  seabed folds the line back past its anchor (a hairpin), a stable equilibrium the driver
  keeps and names;
* ``fine_mesh`` decks (a finite-EI mesh far below sqrt(EI/EA), where the static Newton
  system loses its precision) must fail closed naming the mesh, within their own CPU bound;
* metamorphic twins must reproduce the line-end forces of their parent deck to 1e-6;
* mesh twins (the parent deck with every NumSegs multiplied) must reach the same
  equilibrium: FairTen within 0.5 % and every node within 1e-3 of the line length of the
  parent profile at the same unstretched arc length;
* at-rest twins (the parent deck marched in time with nothing moving) must report the
  line-end forces of the static solution at every output step: FairTen/AnchTen are the
  end forces of the committed state, identical for the static and the dynamic run.

usage: test_cable_statics_matrix.py --exe <cabledyn> --cases <cases.json> --output <dir>
"""

from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

# The per-deck bound is on the solver's CPU time, which does not grow with machine load; the
# wall-clock limit only stops a hung process and is scaled far above any loaded-machine run:
# at least DECK_WALL_LIMIT and WALL_PER_CPU times the configuration's CPU bound (--cpu-limit),
# so a Debug build, whose CPU bound is ten times larger, is not stopped as hung while it is
# still inside that bound.
DECK_CPU_LIMIT = 60.0
DECK_WALL_LIMIT = 600.0
WALL_PER_CPU = 4.0


def _windows_cpu_seconds(handle) -> float:
    import ctypes
    from ctypes import wintypes

    times = [wintypes.FILETIME() for _ in range(4)]
    ok = ctypes.windll.kernel32.GetProcessTimes(
        wintypes.HANDLE(int(handle)), *[ctypes.byref(t) for t in times]
    )
    if not ok:
        return float("nan")

    def seconds(ft) -> float:
        return ((ft.dwHighDateTime << 32) | ft.dwLowDateTime) * 1.0e-7

    return seconds(times[2]) + seconds(times[3])


def run_measured(cmd: list, cwd: str, env: dict, wall_limit: float):
    """Run ``cmd`` and return (returncode or "TIMEOUT", combined output, CPU seconds).

    The CPU time is the child's own user + kernel time, read from the reaped process
    (os.wait4 on POSIX, GetProcessTimes on Windows), so it is per process and thread-safe."""
    with tempfile.TemporaryFile() as out:
        p = subprocess.Popen(cmd, stdout=out, stderr=subprocess.STDOUT, cwd=cwd, env=env)
        deadline = time.monotonic() + wall_limit
        cpu = float("nan")
        rc = None
        if os.name == "nt":
            try:
                rc = p.wait(timeout=wall_limit)
                cpu = _windows_cpu_seconds(p._handle)  # the handle stays open until p is freed
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()
        else:
            while True:
                pid, status, usage = os.wait4(p.pid, os.WNOHANG)
                if pid:
                    rc = os.waitstatus_to_exitcode(status)
                    p.returncode = rc
                    cpu = usage.ru_utime + usage.ru_stime
                    break
                if time.monotonic() > deadline:
                    p.kill()
                    os.wait4(p.pid, 0)
                    p.returncode = -9
                    break
                time.sleep(0.02)
        out.seek(0)
        log = out.read().decode("utf-8", errors="replace")
    return ("TIMEOUT" if rc is None else rc), log, cpu


def read_static(path: Path) -> dict:
    """Node rows of the static profile per line: [s, x, y, z, T, curvature, bend moment]."""
    out: dict = {}
    for ln in path.read_text(encoding="utf-8").splitlines()[3:]:
        f = ln.split()
        if len(f) < 9:
            continue
        out.setdefault(int(f[0]), []).append([float(v) for v in f[2:9]])
    return out


def material_axial_force(row: list) -> float:
    """Material axial force EA (|r'| - 1) at a profile node.

    Why: the Tension column is the effective tension N = F . t recovered from nodal
    equilibrium. The cubic-Hermite bending energy EI/2 |r''|^2 makes the material axial force
    EA (|r'| - 1) = N + EI kappa^2 = Tension + BendMoment * Curvature, and the compression
    notes judge material strain (element-mean EA (|r'| - 1)), so the matrix holds the notes to
    the same quantity. At a tight bend N alone can be compressive while the material is in
    tension (SW_1003: an end clamped into the seabed, kappa = 1.12 1/m).
    """
    return row[4] + row[6] * row[5]


def read_end_forces(path: Path, every_row: bool = False):
    """FairTen/AnchTen channels of the first output row (t = 0), or of every row."""
    rows = path.read_text(encoding="utf-8").splitlines()
    names = rows[1].split()
    keep = [k for k, n in enumerate(names) if n.startswith(("FairTen", "AnchTen"))]
    table = [[float(v) for v in r.split()] for r in rows[2:] if r.strip()]
    if every_row:
        return [{names[k]: t[k] for k in keep} for t in table]
    return {names[k]: table[0][k] for k in keep}


def segments_cross(p, q, r, s) -> bool:
    def orient(a, b, c):
        return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
    return orient(p, q, r) * orient(p, q, s) < 0.0 and orient(r, s, p) * orient(r, s, q) < 0.0


def segment_distance(p1, q1, p2, q2) -> float:
    """Smallest distance between the 3D segments p1-q1 and p2-q2."""
    d1 = [q1[k] - p1[k] for k in range(3)]
    d2 = [q2[k] - p2[k] for k in range(3)]
    r = [p1[k] - p2[k] for k in range(3)]

    def dot(u, v):
        return u[0] * v[0] + u[1] * v[1] + u[2] * v[2]

    a, e, f, c, b = dot(d1, d1), dot(d2, d2), dot(d2, r), dot(d1, r), dot(d1, d2)
    den = a * e - b * b
    s = min(1.0, max(0.0, (b * f - c * e) / den)) if den > 1e-15 * a * e else 0.0
    t = (b * s + f) / e
    if t < 0.0:
        t, s = 0.0, min(1.0, max(0.0, -c / a))
    elif t > 1.0:
        t, s = 1.0, min(1.0, max(0.0, (b - c) / a))
    return math.sqrt(sum((p1[k] + d1[k] * s - p2[k] - d2[k] * t) ** 2 for k in range(3)))


def self_intersects(xyz: list) -> bool:
    """Self-intersection of the nodal polyline: proper crossing in the vertical plane of its
    chord for a planar line; for a line that leaves that plane (an in-plane current past a
    symmetry-breaking pitchfork), two non-adjacent segments meeting in 3D."""
    x0, y0 = xyz[0][0], xyz[0][1]
    dx, dy = xyz[-1][0] - x0, xyz[-1][1] - y0
    h = math.hypot(dx, dy)
    ex, ey = (dx / h, dy / h) if h > 1e-9 else (1.0, 0.0)
    length = sum(math.dist(xyz[i], xyz[i + 1]) for i in range(len(xyz) - 1))
    lateral = max(abs(-(p[0] - x0) * ey + (p[1] - y0) * ex) for p in xyz)
    if lateral > 1e-6 * length:
        for i in range(len(xyz) - 1):
            for j in range(i + 2, len(xyz) - 1):
                if segment_distance(xyz[i], xyz[i + 1], xyz[j], xyz[j + 1]) < 1e-3:
                    return True
        return False
    pts = [((p[0] - x0) * ex + (p[1] - y0) * ey, p[2]) for p in xyz]
    n = len(pts)
    for i in range(n - 1):
        for j in range(i + 2, n - 1):
            if segments_cross(pts[i], pts[i + 1], pts[j], pts[j + 1]):
                return True
    return False


def run_case(exe: str, root: Path, case: dict, wall_limit: float = DECK_WALL_LIMIT) -> dict:
    cdir = root / case["id"]
    cdir.mkdir(parents=True, exist_ok=True)
    if case.get("bathy"):
        (cdir / "bathy.txt").write_text(case["bathy"], encoding="utf-8", newline="\n")
    (cdir / "deck.dat").write_text(case["deck"], encoding="utf-8", newline="\n")
    env = dict(os.environ)
    env.setdefault("OPENBLAS_NUM_THREADS", "1")
    env.setdefault("OMP_NUM_THREADS", "1")
    t0 = time.time()
    rc, log, cpu = run_measured([exe, str(cdir / "deck.dat"), str(cdir / "out")], str(cdir), env,
                                wall_limit)
    return {"id": case["id"], "rc": rc, "log": log, "time": time.time() - t0, "cpu": cpu, "dir": cdir}


def check_case(case: dict, res: dict) -> list:
    errs = []
    exp = case["expect"]
    log = res["log"]
    if exp == "inadmissible":
        if res["rc"] == 0 or "too long for its span" not in log:
            errs.append("expected a named inadmissibility failure, rc=%s" % res["rc"])
        return errs
    if exp == "tensile_reject":
        if res["rc"] == 0 or "compressive axial resultant" not in log:
            errs.append("expected a tensile_safety rejection, rc=%s" % res["rc"])
        return errs
    if exp == "fine_mesh":
        if res["rc"] == 0 or "below sqrt(EI/EA)" not in log:
            errs.append("expected the fine-mesh failure naming sqrt(EI/EA), rc=%s" % res["rc"])
        return errs
    if exp == "current_compression":
        if res["rc"] == 0 or "run on the seabed is in axial compression" not in log:
            errs.append("expected the grounded-run compression diagnosis, rc=%s" % res["rc"])
        return errs
    if exp == "current_friction_compression":
        if res["rc"] == 0 or "the friction holds the grounded run" not in log:
            errs.append("expected the friction-held touchdown compression diagnosis, rc=%s" % res["rc"])
        return errs
    if res["rc"] != 0:
        tail = [ln for ln in log.splitlines() if "CableDyn_DeckDriver" in ln]
        errs.append("admissible deck failed rc=%s: %s" % (res["rc"], (tail[-1] if tail else "")[:300]))
        return errs
    if case.get("note") and case["note"] not in " ".join(log.split()):
        errs.append("the log lacks the note %r" % case["note"])
    st = read_static(res["dir"] / "out.static.out")
    res["static"] = st
    res["forces"] = read_end_forces(res["dir"] / "out.out")
    for lid, info in case["lines"].items():
        rows = st.get(int(lid))
        if rows is None:
            errs.append("line %s missing from the static profile" % lid)
            continue
        if self_intersects([r[1:4] for r in rows]):
            errs.append("line %s crosses itself" % lid)
        tmin = min(material_axial_force(r) for r in rows)
        tmax = max(material_axial_force(r) for r in rows)
        # only the compression notes waive nodal compression ("line N carries element-mean axial
        # compression ..." and the "line N: mesh too coarse for its bends" variant)
        noted = ("Note: line %s carries element-mean axial compression" % lid) in log or (
            "Note: line %s: mesh too coarse for its bends" % lid) in log
        if tmin < -0.1 * tmax and not noted:
            errs.append("line %s unreported nodal compression %.3g N (peak %.3g N)" % (lid, tmin, tmax))
        roots = info.get("oracle_tfair") or []
        tf = res["forces"].get("FairTen%s" % lid)
        if roots and info["lambda_over_length"] < 0.05 and tf is not None:
            rel = min(abs(tf - r) / r for r in roots)
            ROOT_GAPS.append(rel)
            if rel > ROOT_RTOL:
                errs.append("line %s fairlead force %.4g N is %.0f%% from every EI=0 root %s" %
                            (lid, tf, 100 * rel, roots))
        ref = info.get("reference_tfair")
        if ref is not None and (tf is None or abs(tf - ref) > 0.01 * ref):
            errs.append("line %s fairlead force %s N is not within 1%% of the reference %.6g N (%s)" %
                        (lid, tf, ref, info.get("reference", "")))
    return errs


def mesh_twin_errors(res: dict, pr: dict, parent: str) -> list:
    """The same equilibrium on a refined mesh: FairTen within 0.5 %, every node within 1e-3 of
    the line length of the parent profile interpolated at its unstretched arc length."""
    errs = []
    for name, v in res["forces"].items():
        vp = pr["forces"].get(name)
        if name.startswith("FairTen") and (vp is None or abs(v - vp) > 5e-3 * max(abs(vp), 1.0)):
            errs.append("%s %.6g differs from the deck-mesh %s (%s) beyond 0.5%%" % (name, v, parent, vp))
    for lid, rows in res["static"].items():
        prow = pr["static"].get(lid)
        if not prow:
            errs.append("line %s missing from the parent profile" % lid)
            continue
        s_p = [r[0] for r in prow]
        length = s_p[-1] - s_p[0]
        dev = 0.0
        for r in rows:
            k = min(max(1, next((i for i, v in enumerate(s_p) if v >= r[0]), len(s_p) - 1)), len(s_p) - 1)
            t = (r[0] - s_p[k - 1]) / max(s_p[k] - s_p[k - 1], 1e-300)
            p = [prow[k - 1][j] + t * (prow[k][j] - prow[k - 1][j]) for j in (1, 2, 3)]
            dev = max(dev, math.dist(p, r[1:4]))
        if dev > 1e-3 * length:
            errs.append("line %s profile departs %.3g m from the deck-mesh %s" % (lid, dev, parent))
    return errs


# Largest relative distance of a short-bending-length line's fairlead force from its nearest
# EI = 0 catenary root. A bending length under 5 % of the line still moves the fairlead force
# of the stiffer decks by up to 13.3 % (the largest of the 78 scored lines); the bound sits just
# above that. ROOT_GAPS records every scored line so each run reports the worst.
ROOT_RTOL = 0.15
ROOT_GAPS: list = []


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--cases", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--workers", type=int, default=4)
    # The bound is set for an optimised build; the CMake Debug configuration raises it.
    ap.add_argument("--cpu-limit", type=float, default=DECK_CPU_LIMIT)
    a = ap.parse_args()
    cases = json.loads(Path(a.cases).read_text(encoding="utf-8"))
    root = Path(a.output)
    root.mkdir(parents=True, exist_ok=True)
    wall_limit = max(DECK_WALL_LIMIT, WALL_PER_CPU * a.cpu_limit)
    t0 = time.time()
    with ThreadPoolExecutor(a.workers) as ex:
        results = list(ex.map(lambda c: run_case(a.exe, root, c, wall_limit), cases))
    byid = {r["id"]: r for r in results}
    failures = 0
    for case in cases:
        res = byid[case["id"]]
        errs = check_case(case, res)
        if res["rc"] == "TIMEOUT":
            errs.append("no exit within the %.0f s wall-clock hang guard" % wall_limit)
        # a deck's own bound (a fast failure) scales with the configuration's bound
        elif not res["cpu"] <= case.get("cpu_limit", DECK_CPU_LIMIT) * a.cpu_limit / DECK_CPU_LIMIT:
            errs.append("CPU time %.1f s beyond the %.0f s per-deck bound" % (
                res["cpu"], case.get("cpu_limit", DECK_CPU_LIMIT) * a.cpu_limit / DECK_CPU_LIMIT))
        rest = case.get("rest_of")
        # an at-rest twin of a deck expected to fail closed fails closed itself (checked above)
        if rest and not errs and case["expect"] == "admissible":
            pr = byid.get(rest)
            if pr is None or pr["rc"] != 0 or "forces" not in pr:
                errs.append("static parent %s did not converge" % rest)
            else:
                for k, row in enumerate(read_end_forces(res["dir"] / "out.out", every_row=True)):
                    for name, v in row.items():
                        vp = pr["forces"][name]
                        if abs(v - vp) > 1e-5 * max(abs(vp), 1.0):
                            errs.append("row %d %s %.9g at rest differs from the static %.9g" % (k, name, v, vp))
                            break
        parent = case.get("twin_of")
        if parent and not errs:
            pr = byid.get(parent)
            if pr is None or pr["rc"] != 0 or "forces" not in pr:
                errs.append("twin parent %s did not converge" % parent)
            else:
                for name, v in res["forces"].items():
                    vp = pr["forces"].get(name)
                    if vp is None or abs(v - vp) > 1e-6 * max(abs(vp), 1.0):
                        errs.append("%s %.9g differs from twin %s (%s)" % (name, v, parent, vp))
        mesh = case.get("mesh_of")
        if mesh and not errs:
            pr = byid.get(mesh)
            if pr is None or pr["rc"] != 0 or "forces" not in pr:
                errs.append("mesh parent %s did not converge" % mesh)
            else:
                errs += mesh_twin_errors(res, pr, mesh)
        status = "FAIL" if errs else "ok"
        print("%-4s %-18s %-14s rc=%-7s %6.2fs wall %6.2fs cpu %s" % (
            status, case["id"], case["expect"], res["rc"], res["time"], res["cpu"], "; ".join(errs)[:400]))
        failures += bool(errs)
    print("cable statics matrix: %d/%d decks as expected in %.1f s" % (len(cases) - failures, len(cases),
                                                                      time.time() - t0))
    if ROOT_GAPS:
        print("EI = 0 root check: %d lines, largest fairlead-force distance %.3g (bound %.3g)"
              % (len(ROOT_GAPS), max(ROOT_GAPS), ROOT_RTOL))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
