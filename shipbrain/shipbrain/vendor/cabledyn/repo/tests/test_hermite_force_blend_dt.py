#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Time-step convergence of the finite-EI generalised-alpha blends.

The GoM 80 m lazy-wave cable deck is driven at its hang-off by a 3 m, 12 s surge that
starts from rest (a quintic ramp over the first period). The mean hang-off tension over
12-36 s is compared between dtM = 0.1 s and dtM = 0.025 s:

* the force blend (``alpha_force_blend``, the default) must agree to 2 %;
* the configuration blend (``False alpha_force_blend``) must show its rotation-driven
  bias, above 20 % at dtM = 0.1 s, so the switch is known to select it;
* the dtM = 0.1 s runs must print the time-step note, the dtM = 0.025 s force-blend run
  must not.

usage: test_hermite_force_blend_dt.py --exe <cabledyn> --deck <lozon_gomex80_power_cable_motion.dat> --output <dir>
"""

from __future__ import annotations

import argparse
import math
import os
import re
import subprocess
import sys
from pathlib import Path


def motion(path: Path, dt: float) -> None:
    rows = ["# time id x y z vx vy vz ax ay az"]
    om = 2.0 * math.pi / 12.0
    for i in range(int(round(36.0 / dt)) + 1):
        t = i * dt
        if t >= 12.0:
            v, r, a = 1.0, 0.0, 0.0
        else:
            tau = t / 12.0
            v = 10 * tau**3 - 15 * tau**4 + 6 * tau**5
            r = (30 * tau**2 - 60 * tau**3 + 30 * tau**4) / 12.0
            a = (60 * tau - 180 * tau**2 + 120 * tau**3) / 144.0
        s, c = math.sin(om * t), math.cos(om * t)
        x = 5.0 + 3.0 * v * s
        vx = 3.0 * (r * s + v * om * c)
        ax = 3.0 * (a * s + 2 * r * om * c - v * om * om * s)
        rows.append("%.4f 1 %.10e 0 -14 %.10e 0 0 %.10e 0 0" % (t, x, vx, ax))
    path.write_text("\n".join(rows) + "\n", encoding="utf-8", newline="\n")


def run(exe: str, src: str, out: Path, dt: float, blend: str) -> tuple:
    mp = out / ("surge_%g.txt" % dt)
    motion(mp, dt)
    # each rewrite must hit exactly one OPTIONS row, or the comparison silently runs the deck's own values
    deck, n_dt = re.subn(r"^0\.05\s+dtM\b.*$", "%g     dtM" % dt, src, flags=re.M)
    deck, n_mf = re.subn(r"^(\S+\s+motionFile\b.*)$", '"%s" motionFile' % mp.as_posix(), deck, count=1, flags=re.M)
    deck, n_bl = re.subn(
        r"^%s\s+dtM$" % re.escape("%g" % dt), lambda m: m.group(0) + "\n" + blend + " alpha_force_blend", deck,
        flags=re.M)
    if (n_dt, n_mf, n_bl) != (1, 1, 1):
        raise RuntimeError(
            "deck rewrite matched the dtM/motionFile/blend rows %d/%d/%d times, expected once each"
            % (n_dt, n_mf, n_bl))
    path = out / ("surge_%s_%g.dat" % (blend, dt))
    path.write_text(deck, encoding="utf-8", newline="\n")
    root = out / ("surge_%s_%g" % (blend, dt))
    env = dict(os.environ)
    env.setdefault("OPENBLAS_NUM_THREADS", "1")
    p = subprocess.run([exe, str(path), str(root)], capture_output=True, text=True, env=env, cwd=str(out))
    if p.returncode != 0:
        raise RuntimeError("run %s dt=%g failed: %s" % (blend, dt, (p.stdout + p.stderr)[-500:]))
    rows = Path(str(root) + ".out").read_text(encoding="utf-8").splitlines()
    names = rows[1].split()
    k = names.index("FairTen1")
    vals = [[float(v) for v in r.split()] for r in rows[2:] if r.strip()]
    tail = [v[k] for v in vals if v[0] >= 12.0]
    noted = "a nodal tangent turned up to" in p.stdout + p.stderr
    return sum(tail) / len(tail), noted


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--deck", required=True)
    ap.add_argument("--output", required=True)
    a = ap.parse_args()
    out = Path(a.output)
    out.mkdir(parents=True, exist_ok=True)
    src = Path(a.deck).read_text(encoding="utf-8")
    if "motionFile" not in src:
        print("deck has no motionFile row")
        return 1
    fb_coarse, fb_coarse_note = run(a.exe, src, out, 0.1, "True")
    fb_fine, fb_fine_note = run(a.exe, src, out, 0.025, "True")
    cb_coarse, cb_coarse_note = run(a.exe, src, out, 0.1, "False")
    errors = []
    fb_rel = abs(fb_coarse - fb_fine) / fb_fine
    cb_rel = abs(cb_coarse - fb_fine) / fb_fine
    print("mean FairTen 12-36 s: force blend dt 0.1 = %.1f N, dt 0.025 = %.1f N (%.2f %%); "
          "configuration blend dt 0.1 = %.1f N (%.1f %%)" % (fb_coarse, fb_fine, 100 * fb_rel, cb_coarse,
                                                            100 * cb_rel))
    if fb_rel > 0.02:
        errors.append("force blend is not dt-converged to 2 %% (%.2f %%)" % (100 * fb_rel))
    if cb_rel < 0.20:
        errors.append("configuration blend does not show its large-dt bias (%.1f %%)" % (100 * cb_rel))
    if not (fb_coarse_note and cb_coarse_note):
        errors.append("the dtM = 0.1 s runs did not print the time-step note")
    if fb_fine_note:
        errors.append("the resolved dtM = 0.025 s force-blend run printed the time-step note")
    for e in errors:
        print("FAIL:", e)
    print("PASS" if not errors else "FAILED")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
