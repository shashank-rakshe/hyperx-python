#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Generate the MoorDyn-C kinematics files of the decks in this folder.

* wave_elevation.txt (WaveKin 3): 280 s of a bimodal swell at x = 0, a 1.0 m amplitude at 10 s
  and 0.6 m at 14 s, sampled every 0.1 s. 280 s holds a whole number of both periods, so the
  Fourier reduction of the record recovers the two components exactly.
* current_profile_dynamic.txt (Currents 2): a depth profile in time, sheared from 30 % of the
  surface speed at the seabed to the full speed at the surface, which turns from +X (along the
  line) to +Y (across it) and grows from 0.5 to 1.0 m/s over 120 s.
* current_profile_4d.txt (Currents 5): a grid in x, y, z and time, a current along +Y (across
  the line) that grows from 0.4 m/s at the fairlead (x = 0) to 1.2 m/s at the anchor
  (x = 400 m), sheared in depth as above and ramped in over the first 30 s.
"""

from __future__ import annotations

import math
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEPTH = 50.0
SWELL = ((1.0, 10.0), (0.6, 14.0))  # amplitude (m), period (s)


def shear(z: float) -> float:
    """Fraction of the surface speed at elevation z: 0.3 at the seabed, 1 at the surface."""
    return 0.3 + 0.7 * (z + DEPTH) / DEPTH


def wave_elevation() -> str:
    rows = []
    for index in range(2801):
        t = 0.1 * index
        eta = sum(a * math.cos(2.0 * math.pi * t / period) for a, period in SWELL)
        rows.append(f"{t:.1f} {eta:.10f}")
    return "\n".join(rows) + "\n"


def current_dynamic() -> str:
    depths = (-50.0, -40.0, -30.0, -20.0, -10.0, 0.0)
    lines = [
        "--------------------- MoorDyn dynamic currents File ----------------------------------",
        "a sheared current that turns from +X to +Y and grows from 0.5 to 1.0 m/s over 120 s",
        "line 5 lists the depths (m); each later row is t ux(z1..zn) uy(z1..zn)",
        "--------------------------------------------------------------------------------------",
        "  ".join(f"{z:.1f}" for z in depths),
        "time ux... uy...",
    ]
    for t in (0.0, 30.0, 60.0, 90.0, 120.0):
        speed = 0.5 + 0.5 * t / 120.0
        heading = 0.5 * math.pi * t / 120.0
        ux = [speed * shear(z) * math.cos(heading) for z in depths]
        uy = [speed * shear(z) * math.sin(heading) for z in depths]
        lines.append(f"{t:.1f}  " + "  ".join(f"{u:.6f}" for u in ux + uy))
    return "\n".join(lines) + "\n"


def current_4d() -> str:
    xs = (0.0, 400.0)
    ys = (-50.0, 50.0)
    zs = (-50.0, -25.0, 0.0)
    ts = (0.0, 30.0, 120.0)
    lines = [
        f"{len(xs)} {len(ys)} {len(zs)} {len(ts)}",
        " ".join(f"{x:.1f}" for x in xs),
        " ".join(f"{y:.1f}" for y in ys),
        " ".join(f"{z:.1f}" for z in zs),
        " ".join(f"{t:.1f}" for t in ts),
        "x y z t ux uy uz",
    ]
    for t in ts:
        ramp = min(t / 30.0, 1.0)
        for x in xs:
            surface = 0.4 + 0.8 * (x - xs[0]) / (xs[1] - xs[0])
            for y in ys:
                for z in zs:
                    uy = ramp * surface * shear(z)
                    lines.append(f"{x:.1f} {y:.1f} {z:.1f} {t:.1f} 0.000000 {uy:.6f} 0.000000")
    return "\n".join(lines) + "\n"


def main() -> None:
    (HERE / "wave_elevation.txt").write_text(wave_elevation(), encoding="ascii", newline="\n")
    (HERE / "current_profile_dynamic.txt").write_text(
        current_dynamic(), encoding="ascii", newline="\n"
    )
    (HERE / "current_profile_4d.txt").write_text(current_4d(), encoding="ascii", newline="\n")


if __name__ == "__main__":
    main()
