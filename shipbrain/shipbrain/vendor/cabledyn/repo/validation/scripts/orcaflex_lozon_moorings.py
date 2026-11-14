# File: validation/scripts/orcaflex_lozon_moorings.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""OrcaFlex static-pretension reference for the three Lozon et al. (2025) mooring designs.

Provenance tool (NOT built by CMake): regenerates the OrcaFlex column of the
"Reference platform -- Lozon et al. (2025) multi-depth cases" mooring table in VALIDATION.md.
Each Lozon mooring line is solved as a single line with the fairlead fixed at its neutral
platform position (radius 58 m / depth 14 m) and the anchor on the seabed at the design
anchoring radius; the fairlead effective tension at the neutral position IS the pretension.

Designs (Lozon et al. 2025, Tables 8/9, 13/14, 18/19; Ocean Engineering 322:120473):
  Gulf of Mexico  80 m  catenary : 160 mm chain, 364.5 m; anchor R 400 m; paper pretension 748 kN
  Gulf of Maine  200 m  semitaut : 181.8 mm polyester 199.8 m + 155 mm chain 497.7 m; R 700 m; 1205 kN
  Humboldt       800 m  taut     : 120 mm chain 80 m + 184 mm polyester 1378.9 m + 120 mm chain 80 m;
                                   R 1400 m; 1704 kN
Polyester uses the paper's STATIC EA. Result (OrcFxAPI 11.6d): 747.4 / 1199.2 / 1881.5 kN
(<0.5 % of the paper at 80/200 m; the 800 m taut-polyester pretension is EA-sensitive, ~10 %,
and matches the 1881.5 kN `FairTen` of the CableDyn example deck). OrcaFlex SI (m, te, kN).
"""

import OrcFxAPI

# material: (name, volume-equivalent OD [m], linear mass [kg/m], static EA [N])
CH120 = ("ch120", 0.216, 288.0, 1232e6)
PO184 = ("po184", 0.145, 23.0, 145e6)  # Humboldt polyester (static EA)
CH155 = ("ch155", 0.2791, 480.93, 2058e6)
PO182 = ("po182", 0.1438, 22.42, 142e6)  # Gulf of Maine polyester (static EA)
CH160 = ("ch160", 0.288, 512.0, 2191e6)

# (name, depth, anchor_radius, fairlead_radius, fairlead_depth, sections[(mat, length)] anchor->fairlead, paper)
SITES = [
    ("GoMex 80m", 80.0, 400.0, 58.0, 14.0, [(CH160, 364.5)], 748.0),
    (
        "GoMaine 200m",
        200.0,
        700.0,
        58.0,
        14.0,
        [(CH155, 497.7), (PO182, 199.8)],
        1205.0,
    ),
    (
        "Humboldt 800m",
        800.0,
        1400.0,
        58.0,
        14.0,
        [(CH120, 80.0), (PO184, 1378.9), (CH120, 80.0)],
        1704.0,
    ),
]


def run(name, depth, ar, fr, fd, secs, paper):
    m = OrcFxAPI.Model()
    m.environment.WaterDepth = depth
    seen = set()
    for mat, _length in secs:
        n, od, mass, ea = mat
        if n in seen:
            continue
        seen.add(n)
        o = m.CreateObject(OrcFxAPI.otLineType, n)
        o.OD = od
        o.ID = 0.0
        o.MassPerUnitLength = mass / 1000.0
        o.EA = ea / 1000.0
        o.EIx = 0.0
        o.EIy = 0.0
        o.Cdn = 1.0
        o.Cdz = 0.0
    line = m.CreateObject(OrcFxAPI.otLine, "moor")
    line.NumberOfSections = len(secs)
    line.LineType = [s[0][0] for s in secs]
    line.Length = [s[1] for s in secs]
    line.TargetSegmentLength = [max(2.0, s[1] / 40.0) for s in secs]
    line.EndAConnection = "Fixed"
    line.EndBConnection = "Fixed"
    line.EndAX, line.EndAY, line.EndAZ = ar, 0.0, -depth  # anchor on the seabed
    line.EndBX, line.EndBY, line.EndBZ = (
        fr,
        0.0,
        -fd,
    )  # fairlead (neutral platform position)
    m.CalculateStatics()
    pretension = line.StaticResult("Effective Tension", OrcFxAPI.oeEndB)
    anchor = line.StaticResult("Effective Tension", OrcFxAPI.oeEndA)
    return pretension, anchor


def main():
    print(
        f"{'site':16s} {'OrcaFlex pre kN':>16s} {'paper kN':>10s} {'err%':>7s} {'anchor kN':>10s}"
    )
    for site in SITES:
        pre, anch = run(*site)
        print(
            f"{site[0]:16s} {pre:16.1f} {site[-1]:10.1f} {100 * abs(pre - site[-1]) / site[-1]:7.2f} {anch:10.1f}"
        )


if __name__ == "__main__":
    main()
