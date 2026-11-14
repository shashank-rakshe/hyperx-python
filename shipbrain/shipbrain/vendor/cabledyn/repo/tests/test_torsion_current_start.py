#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""A lazy wave restrained in torsion starts in an in-plane current.

The lazy wave of ``tests/data/lazy_wave_torsion_attachments.dat`` (25 buoyancy modules, Rigid in
torsion at both ends) in a 0.5 m/s current along its plane: its untwisted static state, solved in
the vertical plane, is unstable out of that plane on its mesh (one negative stiffness mode), which
the same deck without torsion accepts with a note. The twist stage added no instability, yet the
torsion stage refused it: at pretwist 0 "torsion continuation stalled at Phi = 0 (target 0): the
twisted equilibrium is unstable", at 360 deg an unstable equilibrium after a failed Newton solve.
Two causes made the start depend on the pretwist and on the round-off of the BLAS kernel: the
coarse branch-selection build twisted its line, and that twisted state seeded the untwisted solve
on the deck mesh (180 deg stopped in the attachment polish; 360 deg needed its fallbacks, and
stopped under OPENBLAS_CORETYPE=Prescott); and every pass of the attachment fixed point after the
first applied the drag of the last twisted shape in full at the untwisted start (270 deg and more
stopped before any twist).

Gate, on the driver's own output: at pretwist 0, 180, 360 and 720 deg the deck starts and runs,
the torsion note reports the twist solved, the instability is named as the untwisted state's own,
the attachment polish converges without its fallbacks, and the end torque is proportional to the
pretwist (to 1 % of the torque at 720 deg).

usage: test_torsion_current_start.py --exe <cabledyn> --data <tests/data> --output <dir>
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


def deck_text(base: str, pretwist: str) -> str:
    lines = base.split("\n")
    out = []
    for line in lines:
        f = line.split()
        if f and f[0] == "bare" and len(f) == 14:
            f[9] = "0.12"
            line = " ".join(f)
        elif f[:3] == ["4", "B", "Rigid"]:
            line = " ".join(f[:-1] + [pretwist])
        elif f[1:] == ["dtM"]:
            line = "0.05 dtM"
        elif f[1:] == ["TMax"]:
            line = "0.5 TMax\nuniform 0.5 0 0 current"
        out.append(line)
    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--data", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)
    base = (Path(args.data) / "lazy_wave_torsion_attachments.dat").read_text(
        encoding="utf-8"
    )
    failures = []
    torques = {}
    pretwists = ("0", "180", "360", "720")
    for pretwist in pretwists:
        deck = out / f"lw_current_twist{pretwist}.dat"
        deck.write_text(deck_text(base, pretwist), encoding="utf-8", newline="\n")
        if "uniform 0.5 0 0 current" not in deck.read_text(encoding="utf-8"):
            print("FAIL: the deck edit did not place the current")
            return 1

    def run(pretwist: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [args.exe, str(out / f"lw_current_twist{pretwist}.dat"), str(out / f"lw_current_twist{pretwist}")],
            capture_output=True,
            text=True,
            check=False,
        )

    # the four runs are independent: concurrently, so a Debug build stays within the test's timeout
    with ThreadPoolExecutor(max_workers=len(pretwists)) as pool:
        runs = dict(zip(pretwists, pool.map(run, pretwists)))
    for pretwist in pretwists:
        p = runs[pretwist]
        log = p.stdout + p.stderr
        solved = "torsion solved" in log
        named = "keeps the instability of its untwisted state" in log
        fell_back = "reached after a failed Newton solve" in log
        m = re.search(r"torsion solved, imposed twist\s+\S+ deg, torque\s+(\S+) N m", log)
        if m:
            torques[pretwist] = float(m.group(1))
        print(
            f"pretwist {pretwist}: exit {p.returncode}, solved {solved}, untwisted instability named {named}, "
            f"polish fallbacks {fell_back}, torque {torques.get(pretwist)}"
        )
        if fell_back:
            failures.append(f"pretwist {pretwist}: the attachment polish needed its fallbacks")
        if p.returncode != 0:
            failures.append(f"pretwist {pretwist}: the deck stopped: {log[-400:]}")
        if not solved:
            failures.append(f"pretwist {pretwist}: no 'torsion solved' note")
        if not named:
            failures.append(
                f"pretwist {pretwist}: the untwisted state's instability is not named"
            )
        if "stalled" in log:
            failures.append(
                f"pretwist {pretwist}: a stalled torsion continuation is reported"
            )
    if len(torques) == 4:
        rate = torques["720"] / 720.0
        for pt, tq in torques.items():
            if abs(tq - rate * float(pt)) > 0.01 * abs(torques["720"]):
                failures.append(
                    f"pretwist {pt}: torque {tq} N m not proportional to the pretwist "
                    f"({rate * float(pt)} N m from 720 deg)"
                )
    for f in failures:
        print("FAIL: " + f)
    if not failures:
        print("PASS: a lazy wave restrained in torsion starts in an in-plane current")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
