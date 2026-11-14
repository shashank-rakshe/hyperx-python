# File: validation/scripts/orcaflex_bend_stiffener.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""OrcaFlex static reference for a hang-off clamped through a tapered bend stiffener.

Provenance tool (NOT built by CMake): regenerates
`tests/data/orcaflex_bend_stiffener_curvature.csv`, the OrcaFlex column of the
`driver_bend_stiffener` check (tests/check_bend_stiffener.py) and of the L3-7 row of
VALIDATION.md. The problem is the check's deck: a 60 m power cable (OD 0.20 m, 60 kg/m,
EA 500 MN, EI 20 kN.m^2) clamped horizontal at (0, 0, -20) m and fixed (pinned) at
(51.9, 0, -50) m, in still water 100 m deep, through a 5 m polyurethane stiffener at End A: a
0.5 m cylinder of 0.60 m outer diameter and a 4.5 m cone to 0.22 m, bored to 0.20 m
(E 50 MPa, 1150 kg/m^3).

In OrcaFlex the stiffener is a line attachment (Stiffener type) whose line type is a
homogeneous pipe of that material, with its outer diameter given as a line-type-diameter
profile; the attachment and the cable bend together. The cable is meshed at 0.05 m over its
first 8 m and 1 m beyond, as in the check. The CSV holds the static curvature of the cable
along its first 8 m (arc from End A, curvature in 1/m).

Result (OrcFxAPI 11.6d): root curvature 0.4522 /m (CableDyn 0.4528), cable bend moment at the
root 9.04 kN.m; CableDyn's curvature follows the profile within 0.5 % of the root curvature.
OrcaFlex SI (m, te, kN).

Usage: python validation/scripts/orcaflex_bend_stiffener.py [output.csv]
"""

import pathlib
import sys

import OrcFxAPI as ofx

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "tests" / "data" / "orcaflex_bend_stiffener_curvature.csv"
WINDOW = 8.0


def build() -> tuple[ofx.Model, ofx.OrcaFlexObject]:
    m = ofx.Model()
    m.environment.WaterDepth = 100.0
    m.environment.Density = 1.025
    profile = m.CreateObject(ofx.otLineTypeDiameter, "StiffenerOD")
    profile.SetDataRowCount("IndependentValue", 3)
    for i, (arc, od) in enumerate([(0.0, 0.60), (0.5, 0.60), (5.0, 0.22)]):
        profile.SetData("IndependentValue", i, arc)
        profile.SetData("DependentValue", i, od)
    cable = m.CreateObject(ofx.otLineType, "cable")
    cable.OD, cable.ID = 0.20, 0.0
    cable.MassPerUnitLength = 0.060
    cable.EIx = 20.0
    cable.EA = 5.0e5
    sleeve = m.CreateObject(ofx.otLineType, "stiffener material")
    sleeve.Category = "Homogeneous pipe"
    sleeve.OD = "StiffenerOD"
    sleeve.ID = 0.20
    sleeve.E = 5.0e4  # kPa
    sleeve.MaterialDensity = 1.15
    stiffener = m.CreateObject(ofx.otStiffenerType, "stiffener")
    stiffener.LineType = "stiffener material"  # its length (5 m) follows the diameter profile
    line = m.CreateObject(ofx.otLine, "hangoff")
    line.EndAConnection, line.EndBConnection = "Fixed", "Fixed"
    line.EndAX, line.EndAY, line.EndAZ = 0.0, 0.0, -20.0
    line.EndBX, line.EndBY, line.EndBZ = 51.90, 0.0, -50.0
    line.EndAAzimuth, line.EndADeclination = 0.0, 90.0
    line.EndAxBendingStiffness = ofx.OrcinaInfinity()
    line.EndBxBendingStiffness = 0.0
    line.NumberOfSections = 2
    line.LineType = ("cable", "cable")
    line.Length = (8.0, 52.0)
    line.TargetSegmentLength = (0.05, 1.0)
    line.NumberOfAttachments = 1
    line.AttachmentType = ("stiffener",)
    line.Attachmentz = (0.0,)
    line.AttachmentzRelativeTo = ("End A",)
    return m, line


def main() -> int:
    output = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else OUTPUT
    m, line = build()
    m.CalculateStatics()
    curvature = line.RangeGraph("Curvature", ofx.pnStaticState)
    moment = line.RangeGraph("Bend moment", ofx.pnStaticState)
    rows = [
        (arc, k)
        for arc, k in zip(curvature.X, curvature.Mean)
        if arc <= WINDOW + 1.0e-9
    ]
    with output.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write("# OrcFxAPI 11.6d static curvature along the hang-off (validation/scripts/"
                     "orcaflex_bend_stiffener.py)\n")
        handle.write("arc_m,curvature_per_m\n")
        for arc, k in rows:
            handle.write(f"{arc:.6f},{k:.8e}\n")
    print(f"root curvature {curvature.Mean[0]:.5f} /m, cable bend moment {moment.Mean[0]:.3f} kN.m")
    print(f"wrote {len(rows)} rows to {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
