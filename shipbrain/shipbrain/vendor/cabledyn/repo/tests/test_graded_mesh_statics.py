#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""A finite-EI lazy wave on a strongly graded deck mesh solves in an oblique or cross current.

The frictional lazy wave of ``tests/data/lazy_wave_touchdown_planar_coarse_att.dat`` keeps the
deck's 4 m elements at its sag bend and 10 m elements at its touchdown, longer than half its
bending length (EI/|w|)^(1/3) = 2.5 m, while its buoyant section (10 or 25 modules over 96 m) is
refined r times. With r = 4 (0.9 m and 1 m elements beside the 4 m and 10 m ones) the static solve
in 0.2 to 0.5 m/s at 45 or 90 deg to the line's plane failed with "the line is already in axial
compression without the current": every route stopped on the deck mesh, and its uniform refinement
by the largest factor (8x, which keeps the grading and refines the short elements as well) stalled
at the start of its stiffness continuation, although the same layout solves on 2 m elements. The
route is now repeated on the mesh refined element by element to the bending-length rule.

Gates, on the driver's own output: every deck (grading ratios from r = 2 to r = 8, the six r = 4
decks that failed) exits 0 without a fallback note ("reached after a failed Newton solve",
"stalled", "looser tolerance"), its mean out-of-plane offset has the sign of the current's cross
component, and two of the r = 4 decks agree with the same deck on 2 m elements throughout to
2e-3 of the fairlead tension in every end-force channel.

usage: test_graded_mesh_statics.py --exe <cabledyn> --data <tests/data> --output <dir>
"""

from __future__ import annotations

import argparse
import math
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

FALLBACK_NOTES = ("reached after a failed Newton solve", "stalled", "looser tolerance")
REFERENCE_TOL = 2.0e-3
# (speed m/s, heading deg from the line's plane, modules, buoyant-section refinement)
CASES = [
    (0.2, 45, 10, 4),
    (0.3, 45, 10, 4),
    (0.2, 90, 10, 4),
    (0.5, 45, 10, 4),
    (0.2, 45, 25, 4),
    (0.3, 45, 25, 4),
    (0.3, 45, 10, 2),
    (0.3, 45, 10, 8),
]
# cases compared with the same deck on 2 m elements throughout
REFERENCED = [(0.3, 45, 10, 4), (0.2, 45, 25, 4)]


def deck(data: Path, speed: float, heading: float, n_mod: int, refine: int, fine: bool) -> str:
    """The frictional lazy wave with n_mod modules over 80-176 m (the deck's totals)."""
    text = (data / "lazy_wave_touchdown_planar_coarse_att.dat").read_text()
    pitch = 96.0 / (n_mod - 1)
    per_pitch = max(1, round(pitch / 4.0))
    g = 2 if fine else 1
    rows = "4 bare 80.0 %d\n4 bare 96.0 %d\n4 bare 424.0 %d\n" % (
        20 * g, (n_mod - 1) * per_pitch * refine * g, 170 if fine else 42)
    text = re.sub(r"(-+ SECTIONS -+\n.*\n.*\n)(?:4 .*\n)+", lambda m: m.group(1) + rows, text)
    s = 25.0 / n_mod
    att = "4 80.0:%.10g:176.0 %.6g %.6g %.6g 1.0 0.0\n" % (pitch, 91.32 * s, 0.18378 * s, 1.392 * s)
    text = re.sub(r"(-+ ATTACHMENTS -+\n.*\n.*\n)(?:4 .*\n)+", lambda m: m.group(1) + att, text)
    th = math.radians(heading)
    ux, uy = round(speed * math.cos(th), 12) + 0.0, round(speed * math.sin(th), 12) + 0.0
    text = re.sub(r"^(0\.0 TMax)$", lambda m: m.group(1) + "\nuniform %.12g %.12g 0.0 current" % (ux, uy),
                  text, count=1, flags=re.M)
    text = text.replace("FairTen4\n", "FairTen4\nAnchTen4\n" + "".join(
        "Point%d%s\n" % (p, c) for p in (7, 8) for c in ("Fx", "Fy", "Fz")))
    return text


def run(exe: str, d: Path, text: str) -> tuple[int, str, dict, float]:
    d.mkdir(parents=True, exist_ok=True)
    (d / "deck.dat").write_text(text, newline="\n")
    p = subprocess.run([exe, "deck.dat", "o"], cwd=d, capture_output=True, text=True, timeout=1800)
    row, y = {}, float("nan")
    if p.returncode == 0:
        lines = [ln for ln in (d / "o.out").read_text().splitlines() if not ln.startswith("#")]
        row = dict(zip(lines[0].split(), (float(v) for v in lines[1].split())))
        prof = (d / "o.static.out").read_text().splitlines()[3:]
        ys = [float(ln.split()[4]) for ln in prof if ln.strip()]
        y = sum(ys) / len(ys)
    return p.returncode, p.stdout + p.stderr, row, y


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--data", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--jobs", type=int, default=4)
    a = ap.parse_args()
    exe = str(Path(a.exe).resolve())
    data, out = Path(a.data), Path(a.output)
    jobs = [(c, False) for c in CASES] + [(c, True) for c in REFERENCED]

    def one(job):
        (speed, heading, n_mod, refine), fine = job
        name = "%s_U%.1f_h%d_N%d_r%d" % (("fine" if fine else "graded"), speed, heading, n_mod, refine)
        return job, name, run(exe, out / name, deck(data, speed, heading, n_mod, refine, fine))

    with ThreadPoolExecutor(a.jobs) as pool:
        results = list(pool.map(one, jobs))
    rows = {}
    failures = []
    for (case, fine), name, (rc, log, row, y) in results:
        notes = [n for n in FALLBACK_NOTES if n in log]
        print("%-24s exit %d  fallback notes %s  FairTen %s  mean y %+.4f m" %
              (name, rc, notes or "none", "%.1f N" % row["FairTen4"] if row else "-", y))
        rows[(case, fine)] = row
        if rc != 0:
            failures.append("%s: exit %d\n%s" % (name, rc, log[-1500:]))
        elif notes:
            failures.append("%s: the static solve needed a fallback (%s)" % (name, ", ".join(notes)))
        elif not y > 0.0:
            failures.append("%s: mean out-of-plane offset %.3e m against the cross current" % (name, y))
    for case in REFERENCED:
        g, f = rows.get((case, False)), rows.get((case, True))
        if not g or not f:
            continue
        err = max(abs(g[c] - f[c]) for c in f if c != "Time(s)") / f["FairTen4"]
        print("U %.1f h %d N %d r %d: graded against 2 m mesh, largest end-force difference %.2e of FairTen" %
              (case + (err,)))
        if not err <= REFERENCE_TOL:
            failures.append("U %.1f h %d N %d r %d: the graded deck misses the 2 m mesh by %.2e of FairTen" %
                            (case + (err,)))
    for f in failures:
        print("FAIL: " + f)
    if failures:
        return 1
    print("PASS: the lazy wave on a graded deck mesh solves in oblique and cross currents")
    return 0


if __name__ == "__main__":
    sys.exit(main())
