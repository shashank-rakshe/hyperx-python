# File: validation/scripts/orcaflex_lazywave_coupled_reference.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""OrcaFlex reference for L4-1c: the Lozon (2025) lazy-wave power cables under a realistic
COUPLED FOWT hang-off motion, all three depths (80 m Gulf of Mexico, 200 m Gulf of Maine, 800 m
Humboldt), one protocol.

Provenance tool (NOT built by CMake). This is the L3-6 dynamic reference
(validation/scripts/orcaflex_lazywave_dynamic_reference.py) with the single 3 m / 12 s heave replaced by the
multi-frequency surge+heave motion the cable hang-off experiences in a coupled floating-wind
simulation. The motion is a shared N-harmonic table extracted from an OpenFAST coupled run
(validation/scripts/openfast_hangoff_harmonics.py -> tests/data/lozon_coupled_harmonics.dat); BOTH CableDyn (the
`l4_lazywave_coupled` gate) and OrcaFlex (this tool) are driven by the IDENTICAL table so the
comparison isolates the cable model under a shared, realistic excitation. The suspended-span model,
sections, hydro, window and scoring are the L3-6 dynamic reference's, verbatim.

PHASE CONVENTION (important). The shared table uses ``disp = mean + sum_k A_k cos(2*pi*t/T_k +
phi_k)`` -- the FFT convention CableDyn's gate uses. OrcaFlex's HarmonicMotion phase is a LAG
(``disp = A cos(2*pi*t/T - phase)``), so the per-harmonic phases are NEGATED when set on the driver
vessel below; with the sign corrected the two codes' hang-off trajectories are bit-identical
(surge/heave cross-correlation 1.0000). The L3-6 single-heave reference never exposed this because
its one harmonic has phase 0.

Usage: python validation/scripts/orcaflex_lazywave_coupled_reference.py <harmonics.dat> [site ...]  (default all).
OrcaFlex SI (m, te, kN).
"""

import sys

import OrcFxAPI as ofx

SEG = 0.75
DT = 0.05
HANGOFF = (0.0, 0.0, -14.0)
BARE = dict(od=0.16, mass=36.7, ea=4.69e8, ei=1.99e4)

# build-up lets the startup transient decay; score the settled tail. Must match the CableDyn gate's
# T_RAMP / T_END / T_SCORE (60 / 200 / 100 s). The wave/response-band cable response settles in a
# few periods; the committed table is capped to that band (the slow surge drift is quasi-static).
BUILDUP = 60.0
STAGE1 = 200.0
WINDOW = (100.0, 200.0)

SITES = {
    "80m": dict(
        touchdown=(83.875401, 0.0, -80.0),
        lsus=134.10728,
        sections=[
            ("bare", 68.114),
            ("buoy", 50.0),
            ("bare", 134.10728 - 118.114),
        ],
        buoy=dict(od=0.29, mass=59.53, ea=4.69e8, ei=1.99e4),
    ),
    "200m": dict(
        touchdown=(108.969530, 0.0, -199.999951),
        lsus=262.50768,
        sections=[("bare", 171.978), ("buoy", 60.0), ("bare", 262.50768 - 231.978)],
        buoy=dict(od=0.30, mass=60.85, ea=4.69e8, ei=1.99e4),
    ),
    "800m": dict(
        touchdown=(349.884466, 0.0, -799.999769),
        lsus=920.43387,
        sections=[("bare", 372.449), ("buoy", 400.0), ("bare", 920.43387 - 772.449)],
        buoy=dict(od=0.29, mass=59.17, ea=4.69e8, ei=1.99e4),
    ),
}


def read_harmonics(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        lines = [ln.strip() for ln in f if ln.strip() and not ln.startswith("#")]
    n = int(lines[0].split()[0])
    for ln in lines[1 : 1 + n]:
        per, sa, sp, ha, hp = (float(x) for x in ln.split()[:5])
        rows.append((per, sa, sp, ha, hp))
    return rows


def build(site, harmonics):
    s = SITES[site]
    m = ofx.Model()
    env = m.environment
    env.WaterDepth = abs(s["touchdown"][2]) + 200.0
    env.Density = 1.025
    env.WaveHeight = 0.0  # still water: the driver vessel's default RAOs would otherwise inflate the drive

    def lt(name, od, mass, ea, ei):
        o = m.CreateObject(ofx.otLineType, name)
        o.OD, o.ID = od, 0.0
        o.MassPerUnitLength = mass / 1000.0
        o.EA = ea / 1000.0
        o.EIx = o.EIy = ei / 1000.0
        o.Cdn, o.Cdz, o.Can = 1.2, 0.1, 1.0
        return o

    lt("bare", **BARE)
    lt("buoy", **s["buoy"])

    v = m.CreateObject(ofx.ObjectType.Vessel, "driver")
    v.IncludedInStatics = "None"
    v.InitialX = v.InitialY = v.InitialZ = 0.0
    v.SuperimposedMotion = "RAOs + harmonics"
    v.SetData("NumberOfHarmonicMotions", -1, len(harmonics))
    for i, (per, sa, sp, ha, hp) in enumerate(harmonics):
        v.SetData("HarmonicMotionPeriod", i, per)
        v.SetData("HarmonicMotionSurgeAmplitude", i, sa)
        v.SetData(
            "HarmonicMotionSurgePhase", i, -sp
        )  # OrcaFlex phase is a LAG -> negate
        v.SetData("HarmonicMotionHeaveAmplitude", i, ha)
        v.SetData("HarmonicMotionHeavePhase", i, -hp)

    line = m.CreateObject(ofx.otLine, "cable")
    secs = list(reversed(s["sections"]))  # End A = touchdown, End B = hang-off
    line.NumberOfSections = len(secs)
    line.LineType = [x[0] for x in secs]
    line.Length = [x[1] for x in secs]
    line.TargetSegmentLength = [SEG] * len(secs)
    line.EndAConnection = "Fixed"
    line.EndAX, line.EndAY, line.EndAZ = s["touchdown"]
    line.EndBConnection = "driver"
    line.EndBX, line.EndBY, line.EndBZ = HANGOFF

    gen = m.general
    gen.StageDuration = [BUILDUP, STAGE1]
    gen.DynamicsSolutionMethod = "Implicit time domain"
    gen.ImplicitConstantTimeStep = DT
    return m, line


def interior_max(rg, lo=0.03, hi=0.97, attr="Max"):
    arc = list(rg.X)
    vals = list(getattr(rg, attr))
    total = arc[-1]
    return max(
        abs(vals[i]) for i in range(len(vals)) if lo * total <= arc[i] <= hi * total
    )


def run_site(site, harmonics):
    s = SITES[site]
    m, line = build(site, harmonics)
    m.CalculateStatics()
    k_static = interior_max(line.RangeGraph("Curvature"), attr="Mean")
    m.RunSimulation()
    period = ofx.SpecifiedPeriod(*WINDOW)
    k_dyn_max = interior_max(line.RangeGraph("Curvature", period), attr="Max")
    ten = line.TimeHistory("Effective tension", period, ofx.oeEndB)
    print(
        f"=== {site} (span {s['lsus']:.3f} m) : COUPLED motion, {len(harmonics)} harmonics ==="
    )
    print(f"  static peak curvature : {k_static:.5f} 1/m")
    print(f"  dynamic max curvature : {k_dyn_max:.5f} 1/m   (window {WINDOW})")
    print(f"  dynamic amplification : {k_dyn_max / k_static:.4f}")
    print(f"  hang-off tension mean : {sum(ten) / len(ten):.4f} kN")
    print(f"  hang-off tension min/max: {min(ten):.4f} / {max(ten):.4f} kN")
    sys.stdout.flush()


def main():
    harmonics = read_harmonics(sys.argv[1])
    sites = sys.argv[2:] or list(SITES)
    print(
        f"OrcaFlex 11.6d L4-1c coupled-motion references ({len(harmonics)} harmonics from {sys.argv[1]})"
    )
    for site in sites:
        run_site(site, harmonics)


if __name__ == "__main__":
    main()
