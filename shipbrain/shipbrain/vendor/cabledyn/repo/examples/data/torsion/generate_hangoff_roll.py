#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Generate the hang-off roll history of torsion_lazy_wave_hangoff_twist.dat.

The hang-off point stays at its deck position; the 12th column rolls the line's End A frame
about its director from 0 to -720 deg (two turns of imposed twist, Phi = +720 deg) along a C2
quintic ramp over the first 60 s, then holds it.
"""

from __future__ import annotations

from pathlib import Path

DT = 0.1
T_MAX = 90.0
RAMP_DURATION = 60.0
ROLL_END = -720.0
POSITION = (5.0, 0.0, -14.0)
POINT_ID = 1


def roll(time: float) -> float:
    """C2 quintic ramp from 0 to ROLL_END over RAMP_DURATION [deg]."""
    if time >= RAMP_DURATION:
        return ROLL_END
    tau = time / RAMP_DURATION
    return ROLL_END * (10.0 * tau**3 - 15.0 * tau**4 + 6.0 * tau**5)


def main() -> None:
    output = Path(__file__).with_name("hangoff_roll_2turns_60s_dt01.txt")
    lines = [
        "# File: examples/data/torsion/hangoff_roll_2turns_60s_dt01.txt",
        "# Hang-off roll for torsion_lazy_wave_hangoff_twist.dat (generate_hangoff_roll.py).",
        "# The point is held; the roll ramps from 0 to -720 deg over 60 s (C2 quintic) and holds.",
        "# Columns: time(s) point_id x(m) y(m) z(m) vx vy vz(m/s) ax ay az(m/s2) roll(deg)",
    ]
    x, y, z = POSITION
    for index in range(round(T_MAX / DT) + 1):
        time = index * DT
        lines.append(f"{time:.1f}  {POINT_ID:d}  {x:.4f}  {y:.4f}  {z:.4f}  0 0 0  0 0 0  {roll(time) + 0.0:.10e}")
    output.write_text("\n".join(lines) + "\n", encoding="ascii", newline="\n")


if __name__ == "__main__":
    main()
