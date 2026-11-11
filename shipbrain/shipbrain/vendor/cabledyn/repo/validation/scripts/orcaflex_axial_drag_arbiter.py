# File: validation/scripts/orcaflex_axial_drag_arbiter.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""OrcaFlex twin of the axial-drag closed-form arbiter (test_hermite_axial_drag_arbiter.f90).

The arbiter problem: a straight vertical Lozon bare cable (d 0.16 m, m 36.7 kg/m, EA 469 MN,
EI 19.9 kN m^2), length 60 m, END A FREE (bottom), END B (top, initial z = -20 m) on a driver
vessel with a harmonic heave A = 1.5 m, T = 12 s; still water, fully submerged, no seabed.
The bottom-free hanging line translates rigidly, so the top tension has the exact closed form

    T_top(t) = L * [ w + m a(t) + 0.5 rho pi d Cd_t |v(t)| v(t) ]

(w = 166.36 N/m submerged weight; axial added mass zero, Cat = 0; normal drag inactive, v_n = 0).
Same numeric coefficients as CableDyn: Cdn = 1.2 (inactive), Cdz = 0.1, Can = 1.0.

Run this headless to arbitrate WHICH axial-drag convention OrcaFlex's Cdz uses: compare its
End B effective-tension max/min over the steady window t in [12, 36] s against the closed form's
max/min on the same drive (phase-free comparison). CableDyn matches the closed form pointwise to
0.031% of the dynamic swing (the committed `hermite_axial_drag_arbiter` gate). The verdict from
this tool is recorded in VALIDATION.md next to the L3-6 gate.
"""

import math

import OrcFxAPI as ofx

RHOW, GACC = 1025.0, 9.80665
D, MLIN, EA, EI = 0.16, 36.7, 4.69e8, 1.99e4
L, ZTOP = 60.0, -20.0
AMP, PER, DT = 1.5, 12.0, 0.05
SEG = 1.5


def main():
    m = ofx.Model()
    env = m.environment
    env.WaterDepth = 500.0
    env.Density = 1.025
    env.WaveHeight = 0.0  # STILL WATER (a fresh model carries a default wave train)

    lt = m.CreateObject(ofx.otLineType, "bare")
    lt.OD = D
    lt.ID = 0.0
    lt.MassPerUnitLength = MLIN / 1000.0
    lt.EA = EA / 1000.0
    lt.EIx = EI / 1000.0
    lt.EIy = EI / 1000.0
    lt.Cdn = 1.2
    lt.Cdz = 0.1
    lt.Can = 1.0

    v = m.CreateObject(ofx.ObjectType.Vessel, "driver")
    v.IncludedInStatics = "None"
    v.InitialX = v.InitialY = v.InitialZ = 0.0
    v.SuperimposedMotion = "RAOs + harmonics"
    v.SetData("NumberOfHarmonicMotions", -1, 1)
    v.SetData("HarmonicMotionPeriod", 0, PER)
    v.SetData("HarmonicMotionHeaveAmplitude", 0, AMP)

    line = m.CreateObject(ofx.otLine, "cable")
    line.LineType = ("bare",)
    line.Length = (L,)
    line.TargetSegmentLength = (SEG,)
    line.EndAConnection = "Free"                      # bottom end hangs free
    line.EndAX, line.EndAY, line.EndAZ = 0.0, 0.0, ZTOP - L
    line.EndBConnection = "driver"
    line.EndBX, line.EndBY, line.EndBZ = 0.0, 0.0, ZTOP

    gen = m.general
    gen.StageDuration = [12.0, 36.0]
    gen.DynamicsSolutionMethod = "Implicit time domain"
    gen.ImplicitConstantTimeStep = DT

    m.CalculateStatics()
    m.RunSimulation()
    ten = line.TimeHistory("Effective tension", ofx.SpecifiedPeriod(12.0, 36.0), ofx.oeEndB)
    ten_n = [x * 1000.0 for x in ten]                 # kN -> N

    # closed form max/min over a cycle (phase-free)
    w_sub = (MLIN - RHOW * 0.25 * math.pi * D**2) * GACC
    ct = 0.5 * RHOW * math.pi * D * 0.1
    om = 2.0 * math.pi / PER
    vals = []
    for i in range(2400):
        t = i * PER / 2400.0
        vt = AMP * om * math.cos(om * t)
        at = -AMP * om * om * math.sin(om * t)
        vals.append(L * (w_sub + MLIN * at + ct * abs(vt) * vt))
    swing_cf = max(vals) - min(vals)
    print("OrcaFlex axial-drag arbiter (End B effective tension, steady window):")
    print(f"  OrcaFlex   max/min : {max(ten_n):10.2f} / {min(ten_n):10.2f} N   swing {max(ten_n)-min(ten_n):8.2f} N")
    print(f"  closed form max/min: {max(vals):10.2f} / {min(vals):10.2f} N   swing {swing_cf:8.2f} N")
    print(f"  swing ratio OrcaFlex/closed-form = {(max(ten_n)-min(ten_n))/swing_cf:.4f}")


if __name__ == "__main__":
    main()
