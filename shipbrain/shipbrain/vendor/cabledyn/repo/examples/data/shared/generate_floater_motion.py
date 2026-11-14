#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Generate the hang-off motions of the two floaters of shared_cable_two_floaters.dat.

Floater 1 (point 1, at x = 0) and floater 2 (point 2, at x = 300 m) each surge 2 m and
heave 1.5 m at a 12 s period. Floater 2 surges in antiphase with floater 1, so the span between
the hang-offs opens and closes by 4 m, and heaves a quarter period behind it. Both motions start
smoothly through a 12 s C2 quintic ramp of their amplitude.
"""

from __future__ import annotations

import math
from pathlib import Path

DT = 0.025
T_MAX = 36.0
PERIOD = 12.0
RAMP_DURATION = 12.0
# point id, deck position (m), surge amplitude (m), surge phase (rad), heave amplitude (m),
# heave phase (rad)
FLOATERS = (
    (1, (0.0, 0.0, -14.0), 2.0, 0.0, 1.5, 0.0),
    (2, (300.0, 0.0, -14.0), 2.0, math.pi, 1.5, -0.5 * math.pi),
)


def ramp(time: float) -> tuple[float, float, float]:
    """A C2 quintic ramp from 0 to 1 and its first two time derivatives."""
    if time >= RAMP_DURATION:
        return 1.0, 0.0, 0.0
    tau = time / RAMP_DURATION
    value = 10.0 * tau**3 - 15.0 * tau**4 + 6.0 * tau**5
    rate = (30.0 * tau**2 - 60.0 * tau**3 + 30.0 * tau**4) / RAMP_DURATION
    acceleration = (60.0 * tau - 180.0 * tau**2 + 120.0 * tau**3) / RAMP_DURATION**2
    return value, rate, acceleration


def ramped_sine(time: float, amplitude: float, phase: float) -> tuple[float, float, float]:
    """amplitude r(t) sin(omega t + phase) and its first two time derivatives."""
    omega = 2.0 * math.pi / PERIOD
    value, rate, acceleration = ramp(time)
    sine = math.sin(omega * time + phase)
    cosine = math.cos(omega * time + phase)
    position = amplitude * value * sine
    velocity = amplitude * (rate * sine + value * omega * cosine)
    accel = amplitude * (acceleration * sine + 2.0 * rate * omega * cosine - value * omega**2 * sine)
    return position, velocity, accel


def main() -> None:
    output = Path(__file__).with_name("floaters_surge_heave_12s_dt0025.txt")
    lines = [
        "# File: examples/data/shared/floaters_surge_heave_12s_dt0025.txt",
        "# Hang-off motions of the two floaters of shared_cable_two_floaters.dat (motionFile).",
        "# Each surges 2 m and heaves 1.5 m at 12 s; floater 2 surges in antiphase and heaves a",
        "# quarter period behind floater 1. A 12 s C2 quintic ramp starts both smoothly.",
        "# Columns: time(s) point_id x(m) y(m) z(m) vx(m/s) vy(m/s) vz(m/s) "
        "ax(m/s2) ay(m/s2) az(m/s2)",
    ]
    for index in range(round(T_MAX / DT) + 1):
        time = index * DT
        for point, (x0, y0, z0), surge_a, surge_p, heave_a, heave_p in FLOATERS:
            sx, sv, sa = ramped_sine(time, surge_a, surge_p)
            hz, hv, ha = ramped_sine(time, heave_a, heave_p)
            lines.append(
                f"{time:.3f} {point:d} {x0 + sx:.10g} {y0:.10g} {z0 + hz:.10g} "
                f"{sv:.10g} 0 {hv:.10g} {sa:.10g} 0 {ha:.10g}"
            )
    output.write_text("\n".join(lines) + "\n", encoding="ascii", newline="\n")


if __name__ == "__main__":
    main()
