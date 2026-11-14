#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Generate the 6-DOF vessel-motion record of the lazy_wave_vessel_motion.dat example.

The vessel reference point (the deck ``vesselRef``, here the origin) surges, heaves and
pitches harmonically with one 12 s period. A C2 quintic ramp over the first 12 s starts the
motion from rest, and every velocity and acceleration is the exact time derivative of the
position or angle. With roll and yaw zero the global angular velocity is (0, pitch rate, 0).
"""

from __future__ import annotations

import math
from pathlib import Path


DT = 0.05
T_MAX = 36.0
PERIOD = 12.0
RAMP_DURATION = 12.0
SURGE = (1.5, 90.0)  # amplitude (m), phase lead (deg)
HEAVE = (2.0, 0.0)  # amplitude (m), phase lead (deg)
PITCH = (3.0, -90.0)  # amplitude (deg), phase lead (deg)
OUTPUT = "vessel_surge_heave_pitch_12s_dt005.txt"


def ramp(time: float) -> tuple[float, float, float]:
    """Return a C2 quintic ramp and its first two time derivatives."""
    if time >= RAMP_DURATION:
        return 1.0, 0.0, 0.0
    tau = time / RAMP_DURATION
    value = 10.0 * tau**3 - 15.0 * tau**4 + 6.0 * tau**5
    rate = (30.0 * tau**2 - 60.0 * tau**3 + 30.0 * tau**4) / RAMP_DURATION
    acceleration = (60.0 * tau - 180.0 * tau**2 + 120.0 * tau**3) / RAMP_DURATION**2
    return value, rate, acceleration


def ramped_harmonic(time: float, amplitude: float, phase_deg: float) -> tuple[float, float, float]:
    """Return ramp(t) * A sin(w t + phase) and its first two exact time derivatives."""
    omega = 2.0 * math.pi / PERIOD
    arg = omega * time + math.radians(phase_deg)
    value, rate, acceleration = ramp(time)
    sine, cosine = math.sin(arg), math.cos(arg)
    position = amplitude * value * sine
    velocity = amplitude * (rate * sine + value * omega * cosine)
    accel = amplitude * (acceleration * sine + 2.0 * rate * omega * cosine - value * omega**2 * sine)
    return position, velocity, accel


def main() -> None:
    output = Path(__file__).with_name(OUTPUT)
    lines = [
        f"# File: examples/data/vessel/{OUTPUT}",
        "# 6-DOF vessel record for lazy_wave_vessel_motion.dat, written by generate_vessel_motion.py.",
        "# Surge 1.5 m, heave 2.0 m and pitch 3.0 deg at a 12 s period about the reference point,",
        "# reaching full amplitude after a 12 s C2 quintic ramp; roll, sway and yaw are zero.",
        "# Columns: time(s) x y z(m) roll pitch yaw(deg) vx vy vz(m/s) wx wy wz(rad/s)"
        " ax ay az(m/s2) alx aly alz(rad/s2)",
    ]
    for index in range(round(T_MAX / DT) + 1):
        time = index * DT
        x, vx, ax = ramped_harmonic(time, *SURGE)
        z, vz, az = ramped_harmonic(time, *HEAVE)
        pitch, pitch_rate, pitch_acc = ramped_harmonic(time, *PITCH)
        values = [
            x, 0.0, z,
            0.0, pitch, 0.0,
            vx, 0.0, vz,
            0.0, math.radians(pitch_rate), 0.0,
            ax, 0.0, az,
            0.0, math.radians(pitch_acc), 0.0,
        ]
        lines.append(f"{time:.2f} " + " ".join(f"{v + 0.0:.9e}" for v in values))
    output.write_text("\n".join(lines) + "\n", encoding="ascii")


if __name__ == "__main__":
    main()
