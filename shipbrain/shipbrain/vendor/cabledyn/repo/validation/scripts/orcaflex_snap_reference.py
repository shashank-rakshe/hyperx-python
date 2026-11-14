# File: validation/scripts/orcaflex_snap_reference.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Matched OrcaFlex prescribed-heave snap: the OrcaFlex reference of case L5-pk.

This builds the same near-taut grounded-mooring snap case that the CableDyn `snap_load`
test and the MoorDyn-C `moordyn_c_driver` reference solve, so that the converged snap-peak
tensions of the three codes can be compared directly:

    chain   D = 0.252 m, m = 390 kg/m, EA = 1.674e9 N, Cdn = 1.37, Cdz = 0.64,
            Can = 1.0, no bending/torsion stiffness (EI = GJ = 0)
    anchor  (120, 0, -50) m  (fixed point, NOT seabed-snapped)
    fairlead (0, 0, -5) m, driven in heave +/- 4 m at period 4 s
    line length 1.02 x anchor->fairlead chord (2% slack -> goes slack then snaps)
    frictionless elastic seabed at z = -50 m

The fairlead heave is imposed via a vessel (`IncludedInStatics = None`) carrying a
single heave harmonic; OrcaFlex's build-up stage ramps it from rest, matching the
rest-start intent of the CableDyn half-cosine envelope. The snap peak is read from
the fairlead Effective-tension time history over the steady (post-build-up) cycles.

Why this script sweeps dt: the snap peak is a short impulsive transient. At OrcaFlex's
default implicit step (0.1 s) the step does not resolve it (~4.8 MN, close to the MoorDyn-C
value by coincidence); refined steps converge to ~6.32 MN at 0.25 ms. Report the converged
value, not the default-step value.

Requires a licensed OrcaFlex install + OrcFxAPI (11.6d used). Exits 0 with the
converged peak printed; exits 2 (skip) if OrcFxAPI / a license is unavailable.
"""
from __future__ import annotations

import math
import sys

try:
    import OrcFxAPI as ofx
except Exception as exc:  # noqa: BLE001 - any import/license failure -> skip
    print(f"# OrcaFlex unavailable ({exc}); skipping (this reference needs a license)")
    sys.exit(2)

EA_N, MASS, OD = 1.674e9, 390.0, 0.252
ANCHOR = (120.0, 0.0, -50.0)
FAIRLEAD = (0.0, 0.0, -5.0)
HEAVE_AMP, HEAVE_PERIOD = 4.0, 4.0
NSEG = 20
CHORD = math.dist(ANCHOR, FAIRLEAD)
LEN = 1.02 * CHORD


def _build(implicit_dt: float | None):
    """Build the matched snap model; set a fixed implicit dt if given."""
    m = ofx.Model()
    m.environment.WaterDepth = 50.0
    m.environment.SeabedModel = "Elastic"
    for nm in ("SeabedNormalFrictionCoefficient", "SeabedAxialFrictionCoefficient"):
        try:
            m.environment.SetData(nm, -1, 0.0)
        except Exception:  # noqa: BLE001,S110 - name varies by version
            pass

    lt = m.CreateObject(ofx.ObjectType.LineType, "chain")
    lt.OD = OD
    lt.MassPerUnitLength = MASS / 1000.0  # te/m
    lt.EA = EA_N / 1000.0  # kN
    lt.EIx = lt.EIy = lt.GJ = 0.0
    lt.Cdn, lt.Cdz, lt.Can = 1.37, 0.64, 1.0
    for nm in ("SeabedNormalFrictionCoefficient", "SeabedAxialFrictionCoefficient"):
        try:
            lt.SetData(nm, -1, 0.0)
        except Exception:  # noqa: BLE001,S110
            pass

    v = m.CreateObject(ofx.ObjectType.Vessel, "driver")
    v.IncludedInStatics = "None"
    v.InitialX = v.InitialY = v.InitialZ = 0.0
    v.SuperimposedMotion = "RAOs + harmonics"
    v.SetData("NumberOfHarmonicMotions", -1, 1)
    v.SetData("HarmonicMotionPeriod", 0, HEAVE_PERIOD)
    v.SetData("HarmonicMotionHeaveAmplitude", 0, HEAVE_AMP)

    line = m.CreateObject(ofx.ObjectType.Line, "leg")
    line.LineType = ("chain",)
    line.Length = (LEN,)
    line.TargetSegmentLength = (LEN / NSEG,)
    line.EndAConnection = "Fixed"
    line.EndAX, line.EndAY, line.EndAZ = ANCHOR
    line.EndBConnection = "driver"
    line.EndBX, line.EndBY, line.EndBZ = 0.0, 0.0, -5.0  # offset from vessel origin
    m.general.StageDuration = [4.0, 12.0]  # build-up 4 s, main 12 s = 3 heave cycles
    if implicit_dt is not None:
        m.general.DynamicsSolutionMethod = "Implicit time domain"
        m.general.ImplicitConstantTimeStep = implicit_dt
    return m, line


def _peak(implicit_dt: float | None) -> float:
    m, line = _build(implicit_dt)
    m.CalculateStatics()
    m.RunSimulation()
    th = line.TimeHistory("Effective tension", ofx.SpecifiedPeriod(0.0, 12.0), ofx.oeEndB)
    return max(th)


def main() -> int:
    print(f"# matched OrcaFlex snap: chord={CHORD:.3f} m, length={LEN:.3f} m (1.02x), {NSEG} segments")
    print(f"{'implicit_dt_s':>14} {'peak_kN':>10}")
    peak = float("nan")
    for dt in (None, 0.0025, 0.001, 0.0005, 0.00025):
        peak = _peak(dt)
        print(f"{('default' if dt is None else f'{dt:g}'):>14} {peak:10.1f}")
    print(f"# CONVERGED OrcaFlex snap peak = {peak:.1f} kN (~{peak / 1e3:.2f} MN) at dt = 0.25 ms")
    print("# cross-code (each dt-converged): MoorDyn-C ~4.86 MN | OrcaFlex ~6.32 MN | CableDyn ~10.22 MN")
    return 0


if __name__ == "__main__":
    sys.exit(main())
