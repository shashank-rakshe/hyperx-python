# File: validation/scripts/orcaflex_lazywave_dynamic_reference.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""OrcaFlex DYNAMIC references for the Lozon (2025) lazy-wave cables under hang-off heave.

Provenance tool (NOT built by CMake): generates the OrcaFlex column of the dynamic lazy-wave
parity gate (`l3_lazywave_dynamic`) at all THREE Lozon depths (80 m Gulf of Mexico, 200 m Gulf of
Maine, 800 m Humboldt), one protocol. The model is the MATCHED SUSPENDED-SPAN problem the CableDyn
Hermite dynamic gate solves -- a deliberate solver-to-solver parity of the same mathematical
problem, not a re-idealisation of the full installed cable:

  * the suspended span only (arc length from the committed analytic shooter seed
    `tests/data/<site>_lazywave_seed.xyz`), End A FIXED at the static touchdown point and
    End B (hang-off, (0, 0, -14)) on a driver vessel;
  * NO seabed contact (water depth set deep) -- the touchdown node is pinned, exactly like the
    CableDyn gate; the free surface is at z = 0 so the whole span stays submerged under the heave;
  * sections along arc hang-off -> touchdown per Lozon Tables 3/4/11/16/21 (bare 0.16 m /
    36.7 kg/m / EA 469 MN / EI 19.9 kN.m^2, with the per-site buoyant sections below);
  * hydro matched to the CableDyn gate: Cdn = 1.2, Cdz = 0.1 (axial, skin-area pi*d convention),
    Can = 1.0, axial added mass 0; still water, no waves, no current;
  * drive: End B harmonic heave, amplitude 3.0 m, period 12.0 s -- the SAME protocol at every
    depth (the multi-depth comparison is the point, not per-site re-tuning);
  * integration: implicit, constant dt = 0.05 s (the CableDyn step), 12 s build-up + 48 s stage 1;
    scored on the steady window t in [24, 60] s (the last three heave periods).

Scored quantities (interior arc, 3%..97% of the span, excluding the clamped-end boundary layers):
  static peak curvature, dynamic max/min peak curvature over the window, the dynamic
  amplification (dyn max / static peak), and the End B (hang-off) effective-tension mean/min/max.
  No bend stiffener or other local hang-off accessory is included.

Result (OrcFxAPI 11.6d, this file, dt 0.05 s, seg 0.75 m):
  run `python validation/scripts/orcaflex_lazywave_dynamic_reference.py [site ...]` (default: all three) --
  values are committed in the gate `tests/test_l3_lazywave_dynamic.f90` with this tool as
  provenance. OrcaFlex SI (m, te, kN).
"""

import argparse
import sys

import OrcFxAPI as ofx

SEG = 0.75  # mesh-converged segment length (same as the static L3-5 reference)
DT = 0.05
HEAVE_AMP = 3.0
HEAVE_PERIOD = 12.0
BUILDUP = 12.0
STAGE1 = 48.0
WINDOW = (12.0, 48.0)  # stage-1 time (build-up runs t in [-12, 0]); the last three heave periods

HANGOFF = (0.0, 0.0, -14.0)
BARE = dict(od=0.16, mass=36.7, ea=4.69e8, ei=1.99e4)

# Per-site geometry: touchdown = last node of the committed shooter seed shifted to the site
# frame (hang-off z = -14); sections along arc hang-off -> touchdown; buoyant properties per
# Lozon. Section extents are the l3_lazywave_curvature gate constants.
SITES = {
    "80m": dict(
        touchdown=(83.875401, 0.0, -80.0),
        lsus=134.10728,
        sections=[("bare", 68.114), ("buoy", 50.0), ("bare", 134.10728 - 118.114)],
        buoy=dict(od=0.29, mass=59.53, ea=4.69e8, ei=1.99e4),
        hang_off_window=None,
    ),
    "200m": dict(
        touchdown=(108.969530, 0.0, -199.999951),
        lsus=262.50768,
        sections=[("bare", 171.978), ("buoy", 60.0), ("bare", 262.50768 - 231.978)],
        buoy=dict(od=0.30, mass=60.85, ea=4.69e8, ei=1.99e4),
        hang_off_window=None,
    ),
    "800m": dict(
        touchdown=(349.884466, 0.0, -799.999769),
        lsus=920.43387,
        sections=[("bare", 372.449), ("buoy", 400.0), ("bare", 920.43387 - 772.449)],
        buoy=dict(od=0.29, mass=59.17, ea=4.69e8, ei=1.99e4),
        hang_off_window=None,
    ),
}


def build(site):
    s = SITES[site]
    m = ofx.Model()
    env = m.environment
    # deep: NO seabed contact -- the touchdown end is pinned instead
    env.WaterDepth = abs(s["touchdown"][2]) + 200.0
    env.Density = 1.025
    env.WaveHeight = 0.0  # STILL WATER: a fresh OrcaFlex model carries a default wave train;
    # without this the default vessel RAOs inflate the commanded heave (~3.5 m for 3.0) and
    # the wave loads the line directly (caught by the closed-form axial-drag arbiter)

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
        return o

    lt("bare", **BARE)
    lt("buoy", **s["buoy"])

    # Driver vessel: statics = None (line statics solve with End B held at the offset), dynamics =
    # a single harmonic heave about the initial position.
    v = m.CreateObject(ofx.ObjectType.Vessel, "driver")
    v.IncludedInStatics = "None"
    v.InitialX = v.InitialY = v.InitialZ = 0.0
    v.SuperimposedMotion = "RAOs + harmonics"
    v.SetData("NumberOfHarmonicMotions", -1, 1)
    v.SetData("HarmonicMotionPeriod", 0, HEAVE_PERIOD)
    v.SetData("HarmonicMotionHeaveAmplitude", 0, HEAVE_AMP)

    line = m.CreateObject(ofx.otLine, "cable")
    secs = list(reversed(s["sections"]))  # OrcaFlex End A = touchdown, End B = hang-off
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


def interior_max(rg, frac_lo=0.03, frac_hi=0.97, attr="Max"):
    arc = list(rg.X)
    vals = list(getattr(rg, attr))
    total = arc[-1]
    lo, hi = frac_lo * total, frac_hi * total
    return max(abs(vals[i]) for i in range(len(vals)) if lo <= arc[i] <= hi)


def arc_window_max(rg, lo, hi, attr="Max"):
    """Max |value| over the arc window [lo, hi] m measured FROM THE DRIVEN HANG-OFF.

    This build connects End A = touchdown (Fixed) and End B = hang-off (driver vessel), and
    OrcaFlex range graphs report arc from End A -- so arc = total at the hang-off. The window
    is therefore evaluated on (total - arc), i.e. distance from the End-B hang-off end."""
    arc = list(rg.X)
    vals = list(getattr(rg, attr))
    total = arc[-1]
    return max(abs(vals[i]) for i in range(len(vals)) if lo <= total - arc[i] <= hi)


def run_site(site):
    s = SITES[site]
    m, line = build(site)
    m.CalculateStatics()
    k_static = interior_max(line.RangeGraph("Curvature"), attr="Mean")
    t_static = line.StaticResult("Effective Tension", ofx.oeEndB)

    # Optional end-region diagnostic. It is disabled for the present no-accessory comparison.
    how = s["hang_off_window"]
    k_static_ho = arc_window_max(line.RangeGraph("Curvature"), 0.0, how, attr="Mean") if how else None

    m.RunSimulation()
    period = ofx.SpecifiedPeriod(*WINDOW)
    rg = line.RangeGraph("Curvature", period)
    k_dyn_max = interior_max(rg, attr="Max")
    k_dyn_ho = arc_window_max(rg, 0.0, how, attr="Max") if how else None
    # the curvature trough at the sag bend: the minimum over the window at the arc of the static peak
    arc = list(rg.X)
    kmin = list(rg.Min)
    kmax = list(rg.Max)
    total = arc[-1]
    i_peak = max(
        (i for i in range(len(arc)) if 0.03 * total <= arc[i] <= 0.97 * total),
        key=lambda i: abs(kmax[i]),
    )
    k_dyn_min_at_peak = abs(kmin[i_peak])
    ten = line.TimeHistory("Effective tension", period, ofx.oeEndB)
    print(f"=== {site} (span {s['lsus']:.5f} m, touchdown z {s['touchdown'][2]:.1f} m) ===")
    print(f"  static peak curvature      : {k_static:.5f} 1/m")
    if k_static_ho is not None:
        print(f"  static hang-off curvature  : {k_static_ho:.5f} 1/m   (last {how:.0f} m of arc at End B)")
    print(f"  static hang-off tension    : {t_static:.4f} kN")
    print(f"  dynamic max curvature      : {k_dyn_max:.5f} 1/m   (window {WINDOW})")
    if k_dyn_ho is not None:
        print(f"  dynamic hang-off curvature : {k_dyn_ho:.5f} 1/m   (last {how:.0f} m, window max)")
    print(f"  dynamic min at peak arc    : {k_dyn_min_at_peak:.5f} 1/m (arc {arc[i_peak]:.2f} m)")
    print(f"  dynamic amplification      : {k_dyn_max / k_static:.4f}")
    print(f"  hang-off tension mean      : {sum(ten)/len(ten):.4f} kN")
    print(f"  hang-off tension min/max   : {min(ten):.4f} / {max(ten):.4f} kN")
    sys.stdout.flush()


def main():
    global SEG
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sites", nargs="*", choices=tuple(SITES), default=list(SITES))
    parser.add_argument(
        "--segment-lengths", nargs="+", type=float, metavar="M",
        help="repeat each selected site for these target segment lengths",
    )
    args = parser.parse_args()
    sites = args.sites or list(SITES)
    segment_lengths = args.segment_lengths or [SEG]
    print("OrcaFlex 11.6d dynamic lazy-wave references (matched suspended span, heave-only)")
    for segment_length in segment_lengths:
        if segment_length <= 0.0:
            parser.error("target segment lengths must be positive")
        SEG = segment_length
        print(f"Target segment length: {SEG:g} m")
        for site in sites:
            run_site(site)


if __name__ == "__main__":
    main()
