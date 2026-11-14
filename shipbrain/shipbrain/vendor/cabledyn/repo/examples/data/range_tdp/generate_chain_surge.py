#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Generate the smooth-start fairlead surge of the chain range-graph example."""

from __future__ import annotations

import math
from pathlib import Path


DT = 0.05
T_MAX = 120.0
AMPLITUDE = 5.0
PERIOD = 30.0
RAMP_DURATION = 15.0
BASE_POSITION = (0.0, 0.0, 0.0)
POINT_ID = 2


def ramp(time: float) -> tuple[float, float, float]:
    """Return a C2 quintic ramp and its first two time derivatives."""
    if time >= RAMP_DURATION:
        return 1.0, 0.0, 0.0
    tau = time / RAMP_DURATION
    value = 10.0 * tau**3 - 15.0 * tau**4 + 6.0 * tau**5
    rate = (30.0 * tau**2 - 60.0 * tau**3 + 30.0 * tau**4) / RAMP_DURATION
    acceleration = (60.0 * tau - 180.0 * tau**2 + 120.0 * tau**3) / RAMP_DURATION**2
    return value, rate, acceleration


def surge(time: float) -> tuple[float, float, float]:
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
    output = Path(__file__).with_name("chain_surge_5m_30s_dt005.txt")
    lines = [
        "# File: examples/data/range_tdp/chain_surge_5m_30s_dt005.txt",
        "# Fairlead surge of chain_range_tdp.dat with a C2 smooth start.",
        "# The 5 m, 30 s harmonic surge reaches full amplitude after a 15 s quintic ramp.",
        "# Columns: time(s) point_id x(m) y(m) z(m) vx(m/s) vy(m/s) vz(m/s) "
        "ax(m/s2) ay(m/s2) az(m/s2)",
    ]
    for index in range(round(T_MAX / DT) + 1):
        time = index * DT
        displacement, velocity, acceleration = surge(time)
        lines.append(
            f"{time:.2f}  {POINT_ID:d}  {BASE_POSITION[0] + displacement:.10e}  "
            f"{BASE_POSITION[1]:.10e}  {BASE_POSITION[2]:.10e}  {velocity:.10e}  "
            f"0.0000000000e+00  0.0000000000e+00  {acceleration:.10e}  "
            "0.0000000000e+00  0.0000000000e+00"
        )
    output.write_text("\n".join(lines) + "\n", encoding="ascii")


if __name__ == "__main__":
    main()
