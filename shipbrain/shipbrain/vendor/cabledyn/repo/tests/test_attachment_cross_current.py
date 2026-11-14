#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Discrete buoyancy modules on a lazy wave in a cross current, against the smeared section.

The lazy-wave power cable of ``tests/data/lazy_wave_touchdown_planar_{refined,coarse}_att.dat``
(25 discrete buoyancy modules at a 4 m pitch, rigid end connections, seabed friction 0.35) is
put in a uniform current across its vertical plane. The static solve reaches the discrete
equilibrium from the smeared one by a homotopy in the module loads and drag.

Every deck must solve (exit 0), and its line-end tensions must agree with the deck that
replaces the modules by the equivalent smeared section (the same submerged weight, displaced
volume and normal drag per metre over the stretch the modules cover): FairTen within 1 % and
AnchTen within 2 % of the smeared values. The static solve reaches the discrete state without a
fallback: in a current across the line's plane the smeared start carries the modules' drag as well
as their weight, so the polish only moves both to the nodes (with the drag left out of the smeared
start, the refined deck in 0.3 m/s reached it only through the pseudo-transient and line-search
repetitions).

usage: test_attachment_cross_current.py --exe <cabledyn> --data <tests/data> --output <dir>
"""

from __future__ import annotations

import argparse
import math
import re
import subprocess
import sys
from pathlib import Path

# 25 modules at a 4 m pitch from 80 m to 176 m: the smeared stretch runs from 78 m to 178 m.
MODULES, PITCH, M_MOD, V_MOD, CDA_MOD = 25, 4.0, 91.32, 0.18378, 1.392
BARE_D, BARE_M, BARE_CDN, BARE_CDT = 0.16, 36.70, 1.2, 0.1
FAIR_TOL, ANCH_TOL = 0.01, 0.02
CASES = [("refined", 0.3), ("refined", 0.6), ("coarse", 0.3), ("coarse", 0.6)]
# Notes of a static solve that reached its state through a fallback.
FALLBACK_NOTES = ("reached after a failed Newton solve", "stalled", "looser tolerance")


def with_current(text: str, speed: float) -> str:
    """The deck in a uniform current of the given speed across its plane, with AnchTen output."""
    text = re.sub(r"^(0\.0 TMax)$", r"\1\nuniform 0.0 %g 0.0 current" % speed, text, count=1, flags=re.M)
    return re.sub(r"^FairTen4$", "FairTen4\nAnchTen4", text, count=1, flags=re.M)


def smeared(text: str) -> str:
    """The deck with the modules replaced by the equivalent smeared section over 78-178 m."""
    span = MODULES * PITCH
    area = math.pi / 4.0 * BARE_D**2 + MODULES * V_MOD / span
    d_eq = math.sqrt(4.0 * area / math.pi)
    m_eq = BARE_M + MODULES * M_MOD / span
    cdn = (BARE_CDN * BARE_D + MODULES * CDA_MOD / span) / d_eq
    cdt = BARE_CDT * BARE_D / d_eq
    text = re.sub(r"^-+ ATTACHMENTS -+\n(?:(?!-{10}).*\n)*", "", text, count=1, flags=re.M)
    bare = re.search(r"^bare .*$", text, re.M).group(0)
    f = bare.split()
    buoy = " ".join(["buoy", "%.6f" % d_eq, "%.4f" % m_eq] + f[3:10] + ["%.6f" % cdn, "%.6f" % cdt] + f[12:])
    text = text.replace(bare, bare + "\n" + buoy, 1)
    rows = re.findall(r"^4 bare \S+ \d+$", text, re.M)
    h = [float(r.split()[2]) / int(r.split()[3]) for r in rows]
    new = ["4 bare 78.0 %d" % round(78.0 / h[0]), "4 buoy 100.0 %d" % round(100.0 / h[1]),
           "4 bare 422.0 %d" % round(422.0 / h[2])]
    for old, row in zip(rows, new):
        text = text.replace(old, row, 1)
    return text


def run(exe: str, deck: Path) -> tuple[int, dict, str]:
    p = subprocess.run([exe, deck.name, "o"], cwd=deck.parent, capture_output=True, text=True, timeout=600)
    row = {}
    out = deck.parent / "o.out"
    if p.returncode == 0 and out.exists():
        lines = [ln for ln in out.read_text().splitlines() if not ln.startswith("#")]
        row = dict(zip(lines[0].split(), (float(v) for v in lines[1].split())))
    return p.returncode, row, p.stdout + p.stderr


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--data", required=True)
    ap.add_argument("--output", required=True)
    a = ap.parse_args()
    exe = str(Path(a.exe).resolve())
    failures = []
    for mesh, speed in CASES:
        base = (Path(a.data) / ("lazy_wave_touchdown_planar_%s_att.dat" % mesh)).read_text()
        name = "%s_%g" % (mesh, speed)
        results = {}
        for kind, text in (("discrete", with_current(base, speed)), ("smeared", smeared(with_current(base, speed)))):
            d = Path(a.output) / name / kind
            d.mkdir(parents=True, exist_ok=True)
            (d / "deck.dat").write_text(text)
            rc, row, log = run(exe, d / "deck.dat")
            if rc != 0 or "FairTen4" not in row:
                failures.append("%s %s: exit %d\n%s" % (name, kind, rc, log[-2000:]))
            notes = [n for n in FALLBACK_NOTES if n in log]
            if notes:
                failures.append("%s %s: the static solve needed a fallback (%s)" % (name, kind, ", ".join(notes)))
            results[kind] = row
        if all("FairTen4" in r for r in results.values()):
            disc, smr = results["discrete"], results["smeared"]
            dfair = abs(disc["FairTen4"] - smr["FairTen4"]) / smr["FairTen4"]
            danch = abs(disc["AnchTen4"] - smr["AnchTen4"]) / smr["AnchTen4"]
            print("%-12s FairTen %10.1f / %10.1f N (%.2e)  AnchTen %8.1f / %8.1f N (%.2e)" %
                  (name, disc["FairTen4"], smr["FairTen4"], dfair, disc["AnchTen4"], smr["AnchTen4"], danch))
            if dfair > FAIR_TOL or danch > ANCH_TOL:
                failures.append("%s: discrete and smeared tensions differ by %.2e (FairTen) / %.2e (AnchTen)" %
                                (name, dfair, danch))
    for f in failures:
        print("FAIL: " + f)
    if failures:
        return 1
    print("PASS: discrete buoyancy modules in a cross current match the smeared section")
    return 0


if __name__ == "__main__":
    sys.exit(main())
