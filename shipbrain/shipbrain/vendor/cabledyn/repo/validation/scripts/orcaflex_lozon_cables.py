# File: validation/scripts/orcaflex_lozon_cables.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""OrcaFlex static reference for the three Lozon et al. (2025) lazy-wave dynamic power cables.

Provenance tool (NOT built by CMake): regenerates the OrcaFlex column of the L3-5
`l3_lazywave_curvature` gate and the "Reference platform" cable table in VALIDATION.md --
the mesh-converged peak sag-bend curvature and the hang-off effective tension for each of the
three cables (80 / 200 / 800 m), solved statically with the fairlead fixed at (5, 0, -14) m and
the seabed anchor at the design end point.

Cable properties follow Lozon et al. (2025, Tables 3/4/11/16/21; Ocean Engineering
322:120473): bare 0.16 m / 36.7 kg/m, EA 469 MN, EI 19.9 kN.m^2 and the per-site equivalent
distributed buoyancy-section diameter and mass. No bend stiffener or local hang-off accessory is
represented. Curvature is mesh-sensitive at the sag bend; the reference is taken at a converged
segment length after a 3.0 / 1.5 / 0.75 m sweep.

Result (OrcFxAPI 11.6d, mesh-converged peak curvature / static hang-off tension):
  Gulf of Mexico  80 m : 0.0968 /m , 9.32 kN
  Gulf of Maine  200 m : 0.0831 /m , 25.16 kN
  Humboldt       800 m : 0.0280 /m , 56.53 kN
(These are the CableDyn L3-5 gate references; the paper's DYNAMIC max curvatures under the DLC/SLC
extremes -- 0.130 / 0.118 / 0.0325 /m -- bound them from above.) OrcaFlex SI (m, te, kN).
"""

import OrcFxAPI

BARE = dict(od=0.16, mass=36.7, ea=4.69e8, ei=1.99e4)

# (name, depth, hangoff(x,z), anchor(x,z), sections[(linetype,length)] hangoff->anchor, buoy_od, buoy_mass)
SITES = [
    (
        "GoMex 80m",
        80.0,
        (5.0, -14.0),
        (125.0, -80.0),
        [("bare", 68.114), ("buoy", 50.0), ("bare", 52.101)],
        0.29,
        59.53,
    ),
    (
        "GoMaine 200m",
        200.0,
        (5.0, -14.0),
        (205.0, -200.0),
        [("bare", 171.978), ("buoy", 60.0), ("bare", 121.527)],
        0.30,
        60.85,
    ),
    (
        "Humboldt 800m",
        800.0,
        (5.0, -14.0),
        (805.0, -800.0),
        [("bare", 372.449), ("buoy", 400.0), ("bare", 597.981)],
        0.29,
        59.17,
    ),
]
SEG = 0.75  # mesh-converged segment length


def run(name, depth, ho, anc, sections, buoy_od, buoy_mass, seg):
    m = OrcFxAPI.Model()
    env = m.environment
    env.WaterDepth = depth
    env.Density = 1.025

    def lt(n, od, mass, ea, ei):
        o = m.CreateObject(OrcFxAPI.otLineType, n)
        o.OD = od
        o.ID = 0.0
        o.MassPerUnitLength = mass / 1000.0
        o.EA = ea / 1000.0
        o.EIx = ei / 1000.0
        o.EIy = ei / 1000.0
        o.Cdn = 1.2
        o.Cdz = 0.0

    lt("bare", **BARE)
    lt("buoy", buoy_od, buoy_mass, 4.69e8, 1.99e4)
    line = m.CreateObject(OrcFxAPI.otLine, "cable")
    secs = list(reversed(sections))  # OrcaFlex End A = anchor, End B = hang-off
    line.NumberOfSections = len(secs)
    line.LineType = [s[0] for s in secs]
    line.Length = [s[1] for s in secs]
    line.TargetSegmentLength = [seg] * len(secs)
    line.EndAConnection = "Fixed"
    line.EndBConnection = "Fixed"
    line.EndAX, line.EndAY, line.EndAZ = anc[0], 0.0, anc[1]
    line.EndBX, line.EndBY, line.EndBZ = ho[0], 0.0, ho[1]
    m.CalculateStatics()
    tenB = line.StaticResult("Effective Tension", OrcFxAPI.oeEndB)  # hang-off
    rgK = line.RangeGraph("Curvature")
    arc = list(rgK.X)
    K = list(rgK.Mean)
    total = sum(s[1] for s in secs)
    lo, hi = (
        0.03 * total,
        0.97 * total,
    )  # exclude the fixed-end / touchdown boundary layers
    kmax = max(
        abs(K[i]) for i in range(len(K)) if lo <= arc[i] <= hi and abs(K[i]) < 1e2
    )
    return kmax, tenB


def main():
    print(f"{'site':16s} {'max curv /m':>12s} {'hang-off kN':>12s}")
    for site in SITES:
        kmax, ten = run(*site, SEG)
        print(f"{site[0]:16s} {kmax:12.5f} {ten:12.3f}")


if __name__ == "__main__":
    main()
