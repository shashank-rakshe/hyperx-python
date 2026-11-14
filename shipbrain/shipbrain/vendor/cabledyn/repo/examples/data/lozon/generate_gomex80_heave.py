#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Generate the smooth-start GoM 80 m prescribed-heave example."""

from __future__ import annotations

import math
from pathlib import Path


DT = 0.05
T_MAX = 36.0
AMPLITUDE = 3.0
PERIOD = 12.0
RAMP_DURATION = 12.0
BASE_POSITION = (5.0, 0.0, -14.0)
POINT_ID = 1


def ramp(time: float) -> tuple[float, float, float]:
    """Return a C2 quintic ramp and its first two time derivatives."""
    if time >= RAMP_DURATION:
        return 1.0, 0.0, 0.0
    tau = time / RAMP_DURATION
    value = 10.0 * tau**3 - 15.0 * tau**4 + 6.0 * tau**5
    rate = (30.0 * tau**2 - 60.0 * tau**3 + 30.0 * tau**4) / RAMP_DURATION
    acceleration = (60.0 * tau - 180.0 * tau**2 + 120.0 * tau**3) / RAMP_DURATION**2
    return value, rate, acceleration


def heave(time: float) -> tuple[float, float, float]:
    omega = 2.0 * math.pi / PERIOD
    value, rate, acceleration = ramp(time)
    sine = math.sin(omega * time)
    cosine = math.cos(omega * time)
    displacement = AMPLITUDE * value * sine
    velocity = AMPLITUDE * (rate * sine + value * omega * cosine)
    linear_acceleration = AMPLITUDE * (
        acceleration * sine + 2.0 * rate * omega * cosine - value * omega**2 * sine
    )
    return displacement, velocity, linear_acceleration


def main() -> None:
    output = Path(__file__).with_name("gomex80_heave_3m_12s_dt005.txt")
    lines = [
        "# File: examples/data/lozon/gomex80_heave_3m_12s_dt005.txt",
        "# Lozon 80 m cable demonstration motion with a C2 smooth start.",
        "# The 3 m, 12 s harmonic heave reaches full amplitude after a 12 s quintic ramp.",
        "# Columns: time(s) point_id x(m) y(m) z(m) vx(m/s) vy(m/s) vz(m/s) ax(m/s2) ay(m/s2) az(m/s2)",
    ]
    for index in range(round(T_MAX / DT) + 1):
        time = index * DT
        displacement, velocity, acceleration = heave(time)
        lines.append(
            f"{time:.2f}  {POINT_ID:d}  {BASE_POSITION[0]:.10e}  {BASE_POSITION[1]:.10e}  "
            f"{BASE_POSITION[2] + displacement:.10e}  0.0000000000e+00  0.0000000000e+00  "
            f"{velocity:.10e}  0.0000000000e+00  0.0000000000e+00  {acceleration:.10e}"
        )
    output.write_text("\n".join(lines) + "\n", encoding="ascii")


if __name__ == "__main__":
    main()
