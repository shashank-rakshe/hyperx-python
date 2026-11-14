# File: validation/scripts/orcaflex_longduration_mooring.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""OrcaFlex 1-hour long-duration reference for the VolturnUS-S mooring fairlead tension.

Provenance tool (NOT built by CMake): generates the OrcaFlex column of the L3 long-duration gate
(`l3_longduration_mooring`). The case: one IEA-15MW VolturnUS-S all-chain catenary line (R4
studless, volume-equivalent OD 0.333 m, 685 kg/m, EA 3.27e9 N, 850 m; fairlead at (0, 0, -14),
anchor on the seabed at (779.6, 0, -200), water depth 200 m), the fairlead driven for ONE HOUR by
a two-component harmonic representative of slow-drift + wave-frequency platform motion:

    surge  x(t) = 5.0 sin(2 pi t / 90)   [m]
    heave  z(t) = 2.0 sin(2 pi t / 12)   [m]

Still water FORCED (env.WaveHeight = 0 -- a fresh OrcaFlex model carries a default wave train and
default vessel RAOs that otherwise contaminate the drive; the actual End B motion amplitudes are
probed and printed). Hydro matched to the CableDyn gate: Cdn = 1.37, Cdz = 0.64 (skin pi*d
convention), Can = 1.0, axial added mass 0; no line structural damping set in OrcaFlex (the
CableDyn side carries its production BA = -1 zeta axial damping; documented config asymmetry,
the same convention the L2-2 parity used). Implicit dt = 0.1 s (the production step), 200 s
build-up + 3600 s stage 1, logged at 0.1 s.

Scored statistics of End B (fairlead) effective tension over the steady window t in [200, 3600] s:
mean, standard deviation, min, max, and the Fourier amplitudes at the two drive frequencies
(projected over integer-multiple windows: 35 x 90 s = [450, 3600]; 283 x 12 s = [204, 3600]).
Wall-clock of RunSimulation is reported informationally. OrcaFlex SI (m, te, kN).
"""

import math
import time

import OrcFxAPI as ofx

OD, MPL, EA, LEN = 0.333, 685.0, 3.27e9, 850.0
DEPTH = 200.0
FAIR = (0.0, 0.0, -14.0)
ANCH = (779.6, 0.0, -200.0)
NSEG = 50
AX, T1 = 5.0, 90.0
AZ, T2 = 2.0, 12.0
DT = 0.1
BUILDUP, STAGE1 = 200.0, 3600.0
WINDOW = (200.0, 3600.0)


def fourier_amp(ts, vals, period, t_hi):
    """Amplitude of the `period` component over the largest integer-multiple window ending at t_hi."""
    n_per = int((t_hi - WINDOW[0]) / period)
    t_lo = t_hi - n_per * period
    om = 2.0 * math.pi / period
    c = s = 0.0
    n = 0
    for t, x in zip(ts, vals):
        if t_lo <= t <= t_hi:
            c += x * math.cos(om * t)
            s += x * math.sin(om * t)
            n += 1
    return 2.0 * math.hypot(c, s) / max(n, 1), t_lo, t_hi


def build_model():
    """Return the reference model and its mooring line (also timed by performance_records.py)."""
    m = ofx.Model()
    env = m.environment
    env.WaterDepth = DEPTH
    env.Density = 1.025
    env.WaveHeight = 0.0  # STILL WATER (default wave train otherwise contaminates the drive)

    lt = m.CreateObject(ofx.otLineType, "chain")
    lt.OD = OD
    lt.ID = 0.0
    lt.MassPerUnitLength = MPL / 1000.0
    lt.EA = EA / 1000.0
    lt.EIx = 0.0
    lt.EIy = 0.0
    lt.Cdn = 1.37
    lt.Cdz = 0.64
    lt.Can = 1.0

    v = m.CreateObject(ofx.ObjectType.Vessel, "driver")
    v.IncludedInStatics = "None"
    v.InitialX = v.InitialY = v.InitialZ = 0.0
    v.SuperimposedMotion = "RAOs + harmonics"
    v.SetData("NumberOfHarmonicMotions", -1, 2)
    v.SetData("HarmonicMotionPeriod", 0, T1)
    v.SetData("HarmonicMotionSurgeAmplitude", 0, AX)
    v.SetData("HarmonicMotionSurgePhase", 0, 90.0)   # OrcaFlex harmonics are cosine-like at zero
    v.SetData("HarmonicMotionPeriod", 1, T2)         # phase (max at t=0); a 90 deg lag gives the
    v.SetData("HarmonicMotionHeaveAmplitude", 1, AZ) # sin(omega t) drive the CableDyn gate uses.
    v.SetData("HarmonicMotionHeavePhase", 1, 90.0)   # The drive PHASE is probed below, not assumed.

    line = m.CreateObject(ofx.otLine, "mooring")
    line.LineType = ("chain",)
    line.Length = (LEN,)
    line.TargetSegmentLength = (LEN / NSEG,)
    line.EndAConnection = "Fixed"
    line.EndAX, line.EndAY, line.EndAZ = ANCH
    line.EndBConnection = "driver"
    line.EndBX, line.EndBY, line.EndBZ = FAIR

    gen = m.general
    gen.StageDuration = [BUILDUP, STAGE1]
    gen.DynamicsSolutionMethod = "Implicit time domain"
    gen.ImplicitConstantTimeStep = DT
    gen.TargetLogSampleInterval = DT
    return m, line


def main():
    m, line = build_model()
    m.CalculateStatics()
    t_static = line.StaticResult("Effective Tension", ofx.oeEndB)
    t0 = time.time()
    m.RunSimulation()
    wall = time.time() - t0

    period = ofx.SpecifiedPeriod(*WINDOW)
    ten = list(line.TimeHistory("Effective tension", period, ofx.oeEndB))
    ts = [WINDOW[0] + i * DT for i in range(len(ten))]
    # probe the ACTUAL drive delivered at End B: amplitude AND phase (fit vs sin/cos)
    xb = list(line.TimeHistory("X", period, ofx.oeEndB))
    zb = list(line.TimeHistory("Z", period, ofx.oeEndB))
    def phase_of(vals, period_s):
        om = 2.0 * math.pi / period_s
        vmean = sum(vals) / len(vals)
        cs = sum((v - vmean) * math.cos(om * t) for t, v in zip(ts, vals))
        sn = sum((v - vmean) * math.sin(om * t) for t, v in zip(ts, vals))
        return math.degrees(math.atan2(cs, sn))   # 0 deg == pure sin(omega t)

    n = len(ten)
    mean = sum(ten) / n
    std = math.sqrt(sum((x - mean) ** 2 for x in ten) / n)
    a1, lo1, hi1 = fourier_amp(ts, ten, T1, WINDOW[1])
    a2, lo2, hi2 = fourier_amp(ts, ten, T2, WINDOW[1])
    print("OrcaFlex 11.6d long-duration VolturnUS-S mooring reference (still water, 1 h):")
    print(f"  wall-clock RunSimulation   : {wall:8.1f} s")
    print(f"  probed End B surge/heave   : x [{min(xb):8.3f}, {max(xb):8.3f}]  z [{min(zb):8.3f}, {max(zb):8.3f}]")
    print(f"  probed drive phase (0 = sin): surge {phase_of(xb, T1):7.2f} deg   heave {phase_of(zb, T2):7.2f} deg")
    print(f"  static fairlead tension    : {t_static:10.3f} kN")
    print(f"  tension mean / std         : {mean:10.3f} / {std:8.3f} kN")
    print(f"  tension min / max          : {min(ten):10.3f} / {max(ten):10.3f} kN")
    print(f"  Fourier amp @ {T1:.0f} s window [{lo1:.0f},{hi1:.0f}] : {a1:8.3f} kN")
    print(f"  Fourier amp @ {T2:.0f} s window [{lo2:.0f},{hi2:.0f}] : {a2:8.3f} kN")


if __name__ == "__main__":
    main()
