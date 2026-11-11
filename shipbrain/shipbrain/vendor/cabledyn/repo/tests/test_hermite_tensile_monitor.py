#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Dynamic tensile monitor of the finite-EI (cubic-Hermite) cable on coarse and fine meshes.

The GoM 80 m lazy-wave cable deck is driven at its hang-off by a smooth-start harmonic heave.
The monitor judges the element-mean axial force (three-point Gauss mean of the signed axial
resultant, averaged over an element and its two neighbours), not the pointwise trace, whose
oscillation about that mean grows with the element length:

* the 3 m, 12 s heave keeps the cable tensile (minimum segment tension about 1 kN on a
  1024-element mesh): with ``tensile_safety True`` a 48-element mesh, on which the fairlead
  tension and the peak curvature are converged to 1 %, must complete, and ``warn`` must record
  no event;
* the 3 m, 7 s heave slackens the top of the cable (segment tension down to about -1.6 kN, a
  genuine compression on every mesh): ``tensile_safety True`` must reject it on the 48- and the
  256-element mesh, naming the axial compression, and ``warn`` must record events.

usage: test_hermite_tensile_monitor.py --exe <cabledyn> --deck <lozon_gomex80_power_cable_motion.dat> --output <dir>
"""

from __future__ import annotations

import argparse
import math
import os
import re
import subprocess
import sys
from pathlib import Path

DT = 0.05
T_MAX = 36.0
# Section-aligned element counts of the three sections (bare, buoyant, bare).
COARSE = (21, 15, 12)
FINE = (112, 80, 64)


def motion(path: Path, amplitude: float, period: float) -> None:
    """Harmonic heave about the deck hang-off with a C2 quintic ramp over max(period, 12 s)."""
    ramp = max(period, 12.0)
    om = 2.0 * math.pi / period
    rows = ["# time id x y z vx vy vz ax ay az"]
    for i in range(int(round(T_MAX / DT)) + 1):
        t = i * DT
        if t >= ramp:
            v, r, a = 1.0, 0.0, 0.0
        else:
            tau = t / ramp
            v = 10 * tau**3 - 15 * tau**4 + 6 * tau**5
            r = (30 * tau**2 - 60 * tau**3 + 30 * tau**4) / ramp
            a = (60 * tau - 180 * tau**2 + 120 * tau**3) / ramp**2
        s, c = math.sin(om * t), math.cos(om * t)
        z = -14.0 + amplitude * v * s
        vz = amplitude * (r * s + v * om * c)
        az = amplitude * (a * s + 2 * r * om * c - v * om * om * s)
        rows.append("%.4f 1 5.0 0 %.10e 0 0 %.10e 0 0 %.10e" % (t, z, vz, az))
    path.write_text("\n".join(rows) + "\n", encoding="utf-8", newline="\n")


def deck(src: str, segs: tuple, mode: str, motion_path: Path) -> str:
    lines = src.splitlines()
    k = 0
    for i, ln in enumerate(lines):
        f = ln.split()
        if len(f) == 4 and f[0] == "1" and f[1] in ("bare", "buoy") and f[3].isdigit():
            lines[i] = "1 %s %s %d" % (f[1], f[2], segs[k])
            k += 1
    if k != 3:
        raise RuntimeError("expected three cable sections in the deck, found %d" % k)
    # Node channels of the deck mesh do not exist on the others.
    lines = [ln for ln in lines if not re.match(r'^"\w+N\d+"', ln.strip())]
    out = "\n".join(lines) + "\n"
    for pattern, row in ((r"^\S+\s+tensile_safety\b.*$", "%s tensile_safety" % mode),
                         (r"^\S+\s+motionFile\b.*$", '"%s" motionFile' % motion_path.as_posix()),
                         (r"^\S+\s+dtM\b.*$", "%g dtM" % DT),
                         (r"^\S+\s+TMax\b.*$", "%g TMax" % T_MAX)):
        out, n = re.subn(pattern, lambda _m, row=row: row, out, count=1, flags=re.M)
        if n != 1:
            raise RuntimeError("the deck has no OPTIONS row for %r" % row.split()[-1])
    return out


def run(exe: str, text: str, out: Path, name: str) -> tuple:
    path = out / (name + ".dat")
    path.write_text(text, encoding="utf-8", newline="\n")
    env = dict(os.environ)
    env.setdefault("OPENBLAS_NUM_THREADS", "1")
    p = subprocess.run([exe, str(path), str(out / name)], capture_output=True, text=True, env=env, cwd=str(out))
    return p.returncode, p.stdout + p.stderr


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--deck", required=True)
    ap.add_argument("--output", required=True)
    a = ap.parse_args()
    out = Path(a.output)
    out.mkdir(parents=True, exist_ok=True)
    src = Path(a.deck).read_text(encoding="utf-8")
    benign = out / "heave_3m_12s.txt"
    harsh = out / "heave_3m_7s.txt"
    motion(benign, 3.0, 12.0)
    motion(harsh, 3.0, 7.0)
    errors = []

    rc, log = run(a.exe, deck(src, COARSE, "True", benign), out, "benign_coarse_true")
    print("3 m / 12 s, 48 elements, tensile_safety True: exit %d" % rc)
    if rc != 0:
        errors.append("the tensile cable on the 48-element mesh was rejected: %s" % log[-400:])
    rc, log = run(a.exe, deck(src, COARSE, "warn", benign), out, "benign_coarse_warn")
    print("3 m / 12 s, 48 elements, tensile_safety warn: exit %d" % rc)
    if rc != 0 or "recorded no compression events" not in log:
        errors.append("warn on the tensile cable recorded compression or failed: %s" % log[-400:])

    for segs, label in ((COARSE, "48"), (FINE, "256")):
        rc, log = run(a.exe, deck(src, segs, "True", harsh), out, "harsh_%s_true" % label)
        print("3 m / 7 s, %s elements, tensile_safety True: exit %d" % (label, rc))
        if rc == 0 or "axial compression" not in log:
            errors.append("the genuine compression on the %s-element mesh was not rejected by name (exit %d)" %
                          (label, rc))
    rc, log = run(a.exe, deck(src, COARSE, "warn", harsh), out, "harsh_coarse_warn")
    m = re.search(r"Tensile monitor: line 1 recorded (\d+) accepted", log)
    print("3 m / 7 s, 48 elements, tensile_safety warn: exit %d, events %s" % (rc, m.group(1) if m else "none"))
    if rc != 0 or not m or int(m.group(1)) == 0:
        errors.append("warn did not record the genuine compression events: %s" % log[-400:])

    for e in errors:
        print("FAIL:", e)
    print("PASS" if not errors else "FAILED")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
