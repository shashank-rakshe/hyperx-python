# File: validation/scripts/orcaflex_lazywave_3d_reference.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""OrcaFlex OUT-OF-PLANE (3D) dynamic reference for the lazy-wave cable (L3-6e).

Provenance tool (NOT built by CMake): every committed dynamic lazy-wave gate is planar
(x-z). This reference breaks the plane: the SAME matched suspended-span 80 m problem as
`l3_lazywave_dynamic` (End A pinned at the static touchdown, End B on a driver vessel,
still water, matched hydro), but the hang-off describes an ELLIPTICAL WHIRL:

    z(t) = -14 + 3.0 sin(2 pi t / 12)      (the committed heave)
    y(t) =   0 + 1.5 cos(2 pi t / 12)      (half-amplitude sway, 90 deg ahead)

so the drive sweeps the full 3D response: out-of-plane bending of the arch, transverse
drag, and the y-restoring stiffness of the span. Static remains the planar equilibrium
(y = 0 everywhere): the whole out-of-plane response is dynamic.

Scored (steady window, stage-1 t in [12, 48] = global [24, 60], dt 0.05 s, seg 0.75 m):
  static peak curvature (planar; equals the committed heave-only reference by
  construction); dynamic max curvature (3D magnitude, interior 3-97% arc); max
  out-of-plane excursion |Y| over the interior + its arc; hang-off tension mean/min/max.
  Checks: the applied End-B Y/Z are read back and fitted against the commanded whirl
  (amplitude + phase; < 1 mm / < 0.1 deg), and a dt-halved variant re-runs the scored
  channels for the reference's own dt-convergence.

Usage: python validation/scripts/orcaflex_lazywave_3d_reference.py [--dt 0.05]
Values are committed in the CableDyn gate with this tool as provenance. OrcaFlex SI
(m, te, kN).
"""

import math
import sys

import OrcFxAPI as ofx

SEG = 0.75
HEAVE_AMP = 3.0
SWAY_AMP = 1.5
PERIOD = 12.0
BUILDUP = 12.0
STAGE1 = 48.0
WINDOW = (12.0, 48.0)   # stage-1 time; global [24, 60]

HANGOFF = (0.0, 0.0, -14.0)
BARE = dict(od=0.16, mass=36.7, ea=4.69e8, ei=1.99e4)
SITE = dict(
    touchdown=(83.875401, 0.0, -80.0),
    lsus=134.10728,
    sections=[("bare", 68.114), ("buoy", 50.0), ("bare", 134.10728 - 118.114)],
    buoy=dict(od=0.29, mass=59.53, ea=4.69e8, ei=1.99e4),
)


def build(dt):
    m = ofx.Model()
    env = m.environment
    env.WaterDepth = abs(SITE["touchdown"][2]) + 200.0   # deep: touchdown pinned, no seabed
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
        return o

    lt("bare", **BARE)
    lt("buoy", **SITE["buoy"])

    v = m.CreateObject(ofx.ObjectType.Vessel, "driver")
    v.IncludedInStatics = "None"
    v.InitialX = v.InitialY = v.InitialZ = 0.0
    v.SuperimposedMotion = "RAOs + harmonics"
    v.SetData("NumberOfHarmonicMotions", -1, 1)
    v.SetData("HarmonicMotionPeriod", 0, PERIOD)
    v.SetData("HarmonicMotionHeaveAmplitude", 0, HEAVE_AMP)
    # y(t) = SWAY_AMP * cos(omega t) = SWAY_AMP * sin(omega t + 90 deg): phase LEAD 90 deg
    # on the same-period harmonic. The applied convention is verified by read-back below.
    v.SetData("HarmonicMotionSwayAmplitude", 0, SWAY_AMP)
    v.SetData("HarmonicMotionSwayPhase", 0, -90.0)

    line = m.CreateObject(ofx.otLine, "cable")
    secs = list(reversed(SITE["sections"]))  # End A = touchdown, End B = hang-off
    line.NumberOfSections = len(secs)
    line.LineType = [x[0] for x in secs]
    line.Length = [x[1] for x in secs]
    line.TargetSegmentLength = [SEG] * len(secs)
    line.EndAConnection = "Fixed"
    line.EndAX, line.EndAY, line.EndAZ = SITE["touchdown"]
    line.EndBConnection = "driver"
    line.EndBX, line.EndBY, line.EndBZ = HANGOFF

    gen = m.general
    gen.StageDuration = [BUILDUP, STAGE1]
    gen.DynamicsSolutionMethod = "Implicit time domain"
    gen.ImplicitConstantTimeStep = dt
    return m, line


def interior_extreme(rg, total, attr):
    arc = list(rg.X)
    vals = list(getattr(rg, attr))
    lo, hi = 0.03 * total, 0.97 * total
    sel = [(abs(vals[i]), arc[i]) for i in range(len(vals)) if lo <= arc[i] <= hi]
    return max(sel)


def envelope_at(rg, arc_from_hangoff, total):
    """(min, max) of the range-graph envelope at the sample nearest the probe arc.

    Probe arcs are specified from the HANG-OFF (the CableDyn gate convention); this
    build's End A is the touchdown, so the range-graph arc is total - probe."""
    arc = list(rg.X)
    target = total - arc_from_hangoff
    i = min(range(len(arc)), key=lambda k: abs(arc[k] - target))
    return rg.Min[i], rg.Max[i]


def fit_harmonic(t, x, omega):
    """True LSQ fit x(t) ~ m + a sin(wt) + b cos(wt) -> (amplitude, phase_deg, mean).

    Solves the 3x3 normal equations exactly (the orthogonality shortcut biases the
    amplitude ~0.3% on a sample grid that includes both endpoints of an integer number
    of periods)."""
    import numpy as np
    s = np.sin(omega * np.asarray(t))
    c = np.cos(omega * np.asarray(t))
    A = np.column_stack([np.ones_like(s), s, c])
    m, a, b = np.linalg.lstsq(A, np.asarray(x), rcond=None)[0]
    return math.hypot(a, b), math.degrees(math.atan2(b, a)), m


def run(dt):
    m, line = build(dt)
    m.CalculateStatics()
    total = SITE["lsus"]
    k_static = interior_extreme(line.RangeGraph("Curvature"), total, "Mean")[0]
    t_static = line.StaticResult("Effective Tension", ofx.oeEndB)
    y_static = interior_extreme(line.RangeGraph("Y"), total, "Mean")[0]

    m.RunSimulation()
    period = ofx.SpecifiedPeriod(*WINDOW)
    k_dyn, k_arc = interior_extreme(line.RangeGraph("Curvature", period), total, "Max")
    rgy = line.RangeGraph("Y", period)
    y_hi, y_hi_arc = interior_extreme(rgy, total, "Max")
    y_lo, y_lo_arc = interior_extreme(rgy, total, "Min")
    # named probes (arc from the HANG-OFF): the buoyant-arch crest and the sag bend --
    # response locations away from the drive-dominated top of the span
    yc_lo, yc_hi = envelope_at(rgy, 93.1, total)
    ys_lo, ys_hi = envelope_at(rgy, 50.0, total)
    ten = line.TimeHistory("Effective tension", period, ofx.oeEndB)

    # drive read-back: End B applied Y and Z fitted against the commanded whirl
    tg = m.general.TimeHistory("Time", period)
    yb = line.TimeHistory("Y", period, ofx.oeArcLength(total))
    zb = line.TimeHistory("Z", period, ofx.oeArcLength(total))
    om = 2.0 * math.pi / PERIOD
    ay, py, my = fit_harmonic(list(tg), list(yb), om)
    az, pz, mz = fit_harmonic(list(tg), list(zb), om)
    # The COMMON phase of the applied harmonics is protocol-benign (every scored channel
    # is an extremum/mean over an exact whole number of steady periods, hence
    # phase-shift-invariant -- the same convention as the committed heave-only and
    # MoorDyn read-backs). What defines the 3D protocol is the RELATIVE y-z phase:
    # the commanded whirl has y leading z by 90 deg.
    rel = (py - pz) % 360.0

    print(f"=== L3-6e 3D whirl 80 m, dt = {dt} s ===")
    print(f"  static peak curvature      : {k_static:.5f} 1/m   (planar; |Y|_static {y_static:.2e} m)")
    print(f"  static hang-off tension    : {t_static:.4f} kN")
    print(f"  dynamic max curvature      : {k_dyn:.5f} 1/m   (arc {k_arc:.2f} m from touchdown)")
    print(f"  out-of-plane max Y         : {y_hi:.4f} m at arc {y_hi_arc:.2f} / "
          f"min Y -{y_lo:.4f} m at arc {y_lo_arc:.2f} (from touchdown)")
    print(f"  Y @ arch crest (93.1 m)    : {yc_lo:.4f} .. {yc_hi:.4f} m   (arc from hang-off)")
    print(f"  Y @ sag bend  (50.0 m)     : {ys_lo:.4f} .. {ys_hi:.4f} m")
    print(f"  hang-off tension mean      : {sum(ten)/len(ten):.4f} kN")
    print(f"  hang-off tension min/max   : {min(ten):.4f} / {max(ten):.4f} kN")
    print(f"  [check] drive read-back  : Z amp {az:.6f} m phase {pz:8.3f} deg mean {mz:.4f} | "
          f"Y amp {ay:.6f} m phase {py:8.3f} deg mean {my:.2e} | rel phase {rel:.3f} deg")
    ok = (abs(az - HEAVE_AMP) < 1e-3 and abs(ay - SWAY_AMP) < 1e-3
          and abs(rel - 90.0) < 0.1 and abs(mz + 14.0) < 2e-3 and abs(my) < 1e-3)
    print(f"  [check] drive verdict    : {'OK' if ok else 'MISMATCH - ABORT'}")
    if not ok:
        sys.exit(1)
    sys.stdout.flush()
    return dict(k_dyn=k_dyn, y_hi=y_hi, y_lo=y_lo,
                yc_lo=yc_lo, yc_hi=yc_hi, ys_lo=ys_lo, ys_hi=ys_hi,
                tmean=sum(ten) / len(ten), tmin=min(ten), tmax=max(ten))


def main():
    dt = 0.05
    if "--dt" in sys.argv:
        dt = float(sys.argv[sys.argv.index("--dt") + 1])
    r1 = run(dt)
    r2 = run(dt / 2)
    worst = max(abs(r1[k] - r2[k]) / max(abs(r2[k]), 1e-12) for k in r1)
    print(f"[check] dt convergence ({dt} vs {dt/2}): worst scored-channel move {100*worst:.3f}%")


if __name__ == "__main__":
    main()
