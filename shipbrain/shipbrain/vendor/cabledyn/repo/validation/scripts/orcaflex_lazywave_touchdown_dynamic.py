# File: validation/scripts/orcaflex_lazywave_touchdown_dynamic.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""OrcaFlex DYNAMIC reference for the MOVING-TOUCHDOWN lazy-wave case (L3-6d).

Provenance tool (NOT built by CMake): the unpinned successor to the pinned-touchdown
L3-6 protocol. The model is the INSTALLED Lozon (2025) 80 m Gulf-of-Mexico cable --
hang-off (5, 0, -14) on a driver vessel, lazy-wave arch, touchdown on the REAL elastic
seabed at 80 m depth, grounded run, anchor fixed at (125, 0, -80) -- under the same
3 m / 12 s hang-off heave, still water, matched hydro (Cdn 1.2 / Cdz 0.1 / Can 1.0).
The touchdown point migrates along the bed each cycle: the dynamic contact regime the
pinned protocol excludes.

Like-for-like contact model: the CableDyn Hermite dynamic path carries a frictionless
penalty seabed (normal stiffness kn = 1e5*d N/m per unit length = 100 kN/m/m^2 * OD --
exactly OrcaFlex's default elastic seabed normal stiffness times the contact width), so
the reference zeroes the line-type seabed FRICTION coefficients (statics are measurably
friction-insensitive here per the installed-cable probe; a MOVING touchdown slides, so
friction would otherwise enter the dynamic reference as un-modelled physics).

Scored (steady window, stage-1 t in [12, 48] = global t in [24, 60], dt 0.05 implicit,
seg 0.75 m):
  static peak curvature (interior) + static hang-off tension + static TDP arc;
  dynamic max curvature over the interior; TDP-REGION dynamic curvature max (arc window
  +/- 25 m around the static TDP); hang-off tension mean/min/max; TDP arc excursion
  (min/max over the window, from z-probe time histories on an arc grid about the static
  TDP).  A dt-halved (0.025 s) variant re-runs the scored channels for the reference's
  own dt-convergence check.

Usage: python validation/scripts/orcaflex_lazywave_touchdown_dynamic.py [--dt 0.05]
Values are committed in the CableDyn gate with this tool as provenance. OrcaFlex SI
(m, te, kN).
"""

import sys

import OrcFxAPI as ofx

SEG = 0.75
HEAVE_AMP = 3.0
HEAVE_PERIOD = 12.0
BUILDUP = 12.0
STAGE1 = 48.0
WINDOW = (12.0, 48.0)   # stage-1 time; build-up occupies [-12, 0]

HANGOFF = (5.0, 0.0, -14.0)
BARE = dict(od=0.16, mass=36.7, ea=4.69e8, ei=1.99e4)

SITES = {
    "80m": dict(
        depth=80.0, anchor=(125.0, 0.0, -80.0),
        sections=[("bare", 68.114), ("buoy", 50.0), ("bare", 52.101)],
        buoy=dict(od=0.29, mass=59.53, ea=4.69e8, ei=1.99e4),
    ),
    "200m": dict(
        depth=200.0, anchor=(205.0, 0.0, -200.0),
        sections=[("bare", 171.978), ("buoy", 60.0), ("bare", 121.527)],
        buoy=dict(od=0.30, mass=60.85, ea=4.69e8, ei=1.99e4),
    ),
    "800m": dict(
        depth=800.0, anchor=(805.0, 0.0, -800.0),
        sections=[("bare", 372.449), ("buoy", 400.0), ("bare", 597.981)],
        buoy=dict(od=0.29, mass=59.17, ea=4.69e8, ei=1.99e4),
    ),
}

TDP_PROBE_HALFSPAN = 40.0   # m of arc probed either side of the static TDP
TDP_PROBE_STEP = 1.0        # arc probe spacing (m)
# OrcaFlex grounds the line CENTRELINE at bed + OD/2 (minus the ~1 cm elastic
# penetration), so contact is detected against the lying-flat level, not the bed plane.
CONTACT_TOL = 0.02          # m above the lying-flat level counted as contact
BOTTOM_OD = 0.16            # bottom (bare) section diameter: sets the lying-flat level
TDP_KWINDOW = 25.0          # curvature report window about the static TDP (m)


def build(site, dt):
    cfg = SITES[site]
    m = ofx.Model()
    env = m.environment
    env.WaterDepth = cfg["depth"]
    env.Density = 1.025
    env.WaveHeight = 0.0    # STILL WATER (fresh models carry a default wave train)

    def lt(name, od, mass, ea, ei):
        o = m.CreateObject(ofx.otLineType, name)
        o.OD = od
        o.ID = 0.0
        o.MassPerUnitLength = mass / 1000.0
        o.EA = ea / 1000.0
        o.EIx = ei / 1000.0
        o.EIy = ei / 1000.0
        o.Cdn = 1.2
        o.Cdz = 0.1
        o.Can = 1.0
        # frictionless contact parity with the CableDyn penalty seabed
        o.SeabedNormalFrictionCoefficient = 0.0
        o.SeabedAxialFrictionCoefficient = 0.0
        return o

    lt("bare", **BARE)
    lt("buoy", **cfg["buoy"])

    v = m.CreateObject(ofx.ObjectType.Vessel, "driver")
    v.IncludedInStatics = "None"
    v.InitialX = v.InitialY = v.InitialZ = 0.0
    v.SuperimposedMotion = "RAOs + harmonics"
    v.SetData("NumberOfHarmonicMotions", -1, 1)
    v.SetData("HarmonicMotionPeriod", 0, HEAVE_PERIOD)
    v.SetData("HarmonicMotionHeaveAmplitude", 0, HEAVE_AMP)

    line = m.CreateObject(ofx.otLine, "cable")
    secs = list(reversed(cfg["sections"]))  # End A = anchor, End B = hang-off
    line.NumberOfSections = len(secs)
    line.LineType = [x[0] for x in secs]
    line.Length = [x[1] for x in secs]
    line.TargetSegmentLength = [SEG] * len(secs)
    line.EndAConnection = "Fixed"
    line.EndAX, line.EndAY, line.EndAZ = cfg["anchor"]
    line.EndBConnection = "driver"
    line.EndBX, line.EndBY, line.EndBZ = HANGOFF

    gen = m.general
    gen.StageDuration = [BUILDUP, STAGE1]
    gen.DynamicsSolutionMethod = "Implicit time domain"
    gen.ImplicitConstantTimeStep = dt
    return m, line


def interior_max(rg, total, frac_lo=0.03, frac_hi=0.97, attr="Max"):
    arc = list(rg.X)
    vals = list(getattr(rg, attr))
    lo, hi = frac_lo * total, frac_hi * total
    return max(abs(vals[i]) for i in range(len(vals)) if lo <= arc[i] <= hi)


def window_max_from_hangoff(rg, total, lo, hi, attr="Max"):
    """Max |value| where arc-from-END-B (hang-off) lies in [lo, hi]."""
    arc = list(rg.X)
    vals = list(getattr(rg, attr))
    return max(abs(vals[i]) for i in range(len(vals)) if lo <= total - arc[i] <= hi)


def static_tdp_from_hangoff(line, total, depth):
    """Arc (from the hang-off) of the first grounded point in the static state."""
    rgz = line.RangeGraph("Z")
    arc = list(rgz.X)
    z = list(rgz.Mean)
    lie = -depth + BOTTOM_OD / 2.0 + CONTACT_TOL
    grounded = [total - arc[i] for i in range(len(arc)) if z[i] <= lie]
    return min(grounded)


def tdp_excursion(line, total, tdp_static, period, depth):
    """TDP arc (from the hang-off) min/max over the window from z-probe time histories."""
    lo = max(0.0, tdp_static - TDP_PROBE_HALFSPAN)
    hi = min(total, tdp_static + TDP_PROBE_HALFSPAN)
    arcs = []
    a = lo
    while a <= hi + 1e-9:
        arcs.append(a)
        a += TDP_PROBE_STEP
    zs = [line.TimeHistory("Z", period, ofx.oeArcLength(total - a)) for a in arcs]
    n = len(zs[0])
    tdp_min, tdp_max = float("inf"), -float("inf")
    for k in range(n):
        lie = -depth + BOTTOM_OD / 2.0 + CONTACT_TOL
        contact = [arcs[i] for i in range(len(arcs)) if zs[i][k] <= lie]
        if not contact:
            continue
        tdp = min(contact)
        tdp_min = min(tdp_min, tdp)
        tdp_max = max(tdp_max, tdp)
    return tdp_min, tdp_max


def run(site, dt):
    cfg = SITES[site]
    m, line = build(site, dt)
    m.CalculateStatics()
    total = sum(s[1] for s in cfg["sections"])
    k_static = interior_max(line.RangeGraph("Curvature"), total, attr="Mean")
    t_static = line.StaticResult("Effective Tension", ofx.oeEndB)
    tdp_static = static_tdp_from_hangoff(line, total, cfg["depth"])

    m.RunSimulation()
    period = ofx.SpecifiedPeriod(*WINDOW)
    rg = line.RangeGraph("Curvature", period)
    k_dyn = interior_max(rg, total, attr="Max")
    k_tdp = window_max_from_hangoff(rg, total, tdp_static - TDP_KWINDOW,
                                    tdp_static + TDP_KWINDOW, attr="Max")
    ten = line.TimeHistory("Effective tension", period, ofx.oeEndB)
    tdp_lo, tdp_hi = tdp_excursion(line, total, tdp_static, period, cfg["depth"])

    print(f"=== L3-6d installed {site}, dt = {dt} s ===")
    print(f"  static peak curvature      : {k_static:.5f} 1/m")
    print(f"  static hang-off tension    : {t_static:.4f} kN")
    print(f"  static TDP arc (hang-off)  : {tdp_static:.2f} m")
    print(f"  dynamic max curvature      : {k_dyn:.5f} 1/m")
    print(f"  TDP-region dyn curvature   : {k_tdp:.5f} 1/m   (+/- {TDP_KWINDOW:.0f} m about static TDP)")
    print(f"  hang-off tension mean      : {sum(ten)/len(ten):.4f} kN")
    print(f"  hang-off tension min/max   : {min(ten):.4f} / {max(ten):.4f} kN")
    print(f"  TDP excursion (window)     : {tdp_lo:.2f} .. {tdp_hi:.2f} m  (range {tdp_hi - tdp_lo:.2f} m)")
    sys.stdout.flush()
    return dict(k_static=k_static, t_static=t_static, k_dyn=k_dyn, k_tdp=k_tdp,
                tmean=sum(ten) / len(ten), tmin=min(ten), tmax=max(ten),
                tdp_lo=tdp_lo, tdp_hi=tdp_hi)


def main():
    argv = sys.argv[1:]
    dt = 0.05
    if "--dt" in argv:
        i = argv.index("--dt")
        dt = float(argv[i + 1])
        del argv[i:i + 2]      # drop the flag AND its value from the site list
    args = [a for a in argv if not a.startswith("--")]
    for site in (args or list(SITES)):
        r1 = run(site, dt)
        r2 = run(site, dt / 2)
        keys = ("k_dyn", "k_tdp", "tmean", "tmin", "tmax")
        worst = max(abs(r1[k] - r2[k]) / max(abs(r2[k]), 1e-12) for k in keys)
        print(f"[check] {site} dt convergence ({dt} vs {dt/2}): worst scored-channel move {100*worst:.3f}%")


if __name__ == "__main__":
    main()
