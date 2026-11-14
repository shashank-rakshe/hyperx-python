# File: validation/scripts/orcaflex_lazywave_irregular_reference.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""OrcaFlex IRREGULAR-SEA (JONSWAP) dynamic reference for the lazy-wave cable (L3-6c).

Provenance tool (NOT built by CMake): the component-matched deterministic irregular-sea
protocol. The sea is CableDyn's own reproducible JONSWAP realisation: the seeded synthesis
of the deck's jonswap waves row (CD_JONSWAP_Random_Components in src/CableDyn_Hydro.f90),
which the gate (tests/test_l3_lazywave_irregular.f90) calls directly and components() here
reproduces step for step: Hs 2.0 m, Tp 12.0 s, gamma 3.3, WaveSeed 12345, 80 components, one
at a random frequency inside each of 80 equal bins over 0.2-5 omega_p with a random phase,
amplitudes sqrt(2 S(omega_i) d_omega) scaled so that 4 sqrt(sum a_i^2 / 2) = Hs exactly; the
random stream is MINSTD (multiplier 48271, modulus 2^31 - 1) started from the seed scrambled
by three 31-bit xorshift rounds and one MINSTD step. OrcaFlex receives the table as
user-specified wave components (eta = sum a_i cos(k_i x - omega_i t + phi_i)); the
tool checks that OrcaFlex realised exactly these components (model.waveComponents) and
reconstructs OrcaFlex's own surface elevation from the table --

    eta(x, t) = sum_i a_i cos(k_i x - omega_i t + phi_i),  phi_i in DEGREES from
    PhaseLagWrtSimulationTime

-- so the gate's component wave path (CD_HermiteCable_Dyn_Set_Irregular_Waves, the same
expression with total-eta Wheeler stretching) and OrcaFlex see one sea. The OrcaFlex side
is committed only as the summary values the gate scores (REF_* in the test).

Model: the matched 80 m suspended span (End A pinned at the static touchdown, End B
FIXED at the hang-off (0, 0, -14) -- no vessel: the response is PURELY wave-driven,
separating the irregular-sea physics from the committed heave-driven rows), still-water
statics, matched hydro (Cdn 1.2 / Cdz 0.1 / Can 1.0), Wheeler stretching in BOTH codes.
Water depth 81 m: the REAL wave-kinematics depth must be shared by both codes, and 1 m
of clearance keeps the pinned touchdown node off the OrcaFlex seabed (the depth change
moves 12 s kinematics by ~0.05%, far below the gates; CableDyn runs no seabed).

Sea state: the realisation above, direction 0 (in-plane). Simulation: 12 s build-up +
144 s; scored on t in [24, 144] (120 s = 10 Tp, opening 24 s after the un-ramped
CableDyn start -- two ramp lengths, the committed settle rule) at dt = 0.05 s.

Scored: static peak curvature; dynamic max curvature (interior 3-97% arc); hang-off
effective-tension mean/min/max. Checks: the component-table elevation reconstruction
(< 1e-6 m at two probe points), the Wheeler stretching setting read back, and a
dt-halved rerun of the scored channels.

Usage: python validation/scripts/orcaflex_lazywave_irregular_reference.py [--dt 0.05]
Prints the table check sums the gate asserts and the scored summary values (the gate's
REF_KSTAT, REF_KDYN, REF_TMEAN, REF_TMIN, REF_TMAX). OrcaFlex SI (m, te, kN).

Article mode: python validation/scripts/orcaflex_lazywave_irregular_reference.py
--orcaflex-jonswap TABLE.dat runs the sea the journal article used instead, OrcaFlex's own
JONSWAP synthesis (Hs 2.0 m, Tp 12.0 s, gamma 3.3, seed 12345, 60 components requested,
78 realised), and writes its realised component table (count, then amplitude_m period_s
phase_deg rows). The gate runs that sea with
``test_l3_lazywave_irregular <out> TABLE.dat`` and scores the article's OrcaFlex values.
"""

import math
import sys
from pathlib import Path

import OrcFxAPI as ofx

REPO = Path(__file__).resolve().parents[2]
SEG = 0.75
HS, TP, GAMMA, SEED = 2.0, 12.0, 3.3, 12345
NCOMP = 80
NCOMP_ORCAFLEX = 60     # article mode: components requested from OrcaFlex's synthesis
G = 9.80665
DEPTH = 81.0            # shared wave-kinematics depth (1 m under the pinned touchdown)
BUILDUP = 12.0
STAGE1 = 144.0
# The scored window is [24, 144] in SIMULATION time (t = 0 at the end of the build-up).
# UNLIKE the periodic heave gates, an irregular sea is NOT window-shift-invariant, and
# the component phases are defined w.r.t. simulation time -- so the CableDyn gate runs
# its own clock as the SAME t (cold start at t = 0 where OrcaFlex finishes its wave
# ramp-in; both codes then get 24 s of settle before the window opens) and scores the
# identical [24, 144] interval of the identical wave realisation.
WINDOW = (24.0, 144.0)

HANGOFF = (0.0, 0.0, -14.0)
BARE = dict(od=0.16, mass=36.7, ea=4.69e8, ei=1.99e4)
SITE = dict(
    touchdown=(83.875401, 0.0, -80.0),
    lsus=134.10728,
    sections=[("bare", 68.114), ("buoy", 50.0), ("bare", 134.10728 - 118.114)],
    buoy=dict(od=0.29, mass=59.53, ea=4.69e8, ei=1.99e4),
)


def components():
    """CableDyn's seeded JONSWAP realisation: [(amplitude_m, period_s, phase_deg)].

    Reproduces CD_JONSWAP_Random_Components (src/CableDyn_Hydro.f90) step for step.
    """
    m31, a_minstd = 2147483647, 48271
    state = SEED & m31
    for _ in range(3):
        state ^= (state << 13) & m31
        state ^= state >> 17
        state ^= (state << 5) & m31
    state %= m31
    if state == 0:
        state = 1
    state = (a_minstd * state) % m31

    def uniform():
        nonlocal state
        state = (a_minstd * state) % m31
        return state / m31

    omega_p = 2.0 * math.pi / TP
    omega_min, omega_max = 0.2 * omega_p, 5.0 * omega_p
    d_omega = (omega_max - omega_min) / NCOMP
    gamma_norm = 1.0 - 0.287 * math.log(GAMMA)
    comps = []
    for i in range(NCOMP):
        omega = omega_min + (i + uniform()) * d_omega
        phase = 2.0 * math.pi * uniform()
        sigma = 0.07 if omega <= omega_p else 0.09
        expo = math.exp(-0.5 * ((omega / omega_p - 1.0) / sigma) ** 2)
        s = gamma_norm * G**2 * omega**-5 * math.exp(-1.25 * (omega_p / omega) ** 4) * GAMMA**expo
        comps.append((omega, phase, s))
    scale = (HS * HS / 16.0) / sum(s * d_omega for _, _, s in comps)
    return [(math.sqrt(2.0 * s * scale * d_omega), 2.0 * math.pi / omega, math.degrees(phase))
            for omega, phase, s in comps]


def table_checksums(table):
    """The two sums the gate asserts: sum a cos(phase) and sum a sin(phase)."""
    return (sum(a * math.cos(math.radians(p)) for a, _, p in table),
            sum(a * math.sin(math.radians(p)) for a, _, p in table))


def build(dt, article=False):
    m = ofx.Model()
    env = m.environment
    env.WaterDepth = DEPTH
    env.Density = 1.025
    env.WaveDirection = 0.0
    if article:  # OrcaFlex's own JONSWAP synthesis (the journal article's sea)
        env.WaveType = "JONSWAP"
        env.WaveHs = HS
        env.WaveGamma = GAMMA
        env.WaveTp = TP
        env.UserSpecifiedRandomWaveSeeds = "Yes"
        env.WaveSeed = SEED
        env.WaveNumberOfComponents = NCOMP_ORCAFLEX
    else:
        env.WaveType = "User specified components"
        env.WaveOriginX = env.WaveOriginY = 0.0
        env.WaveTimeOrigin = 0.0
        table = components()
        env.WaveNumberOfUserSpecifiedComponents = len(table)
        for i, (a, per, ph) in enumerate(table):
            env.SetData("WaveUserSpecifiedComponentPeriod", i, per)
            env.SetData("WaveUserSpecifiedComponentAmplitude", i, a)
            env.SetData("WaveUserSpecifiedComponentPhaseLag", i, ph)
    env.KinematicStretchingMethod = "Wheeler stretching"   # match CableDyn's stretching

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

    line = m.CreateObject(ofx.otLine, "cable")
    secs = list(reversed(SITE["sections"]))  # End A = touchdown, End B = hang-off
    line.NumberOfSections = len(secs)
    line.LineType = [x[0] for x in secs]
    line.Length = [x[1] for x in secs]
    line.TargetSegmentLength = [SEG] * len(secs)
    line.EndAConnection = "Fixed"
    line.EndAX, line.EndAY, line.EndAZ = SITE["touchdown"]
    line.EndBConnection = "Fixed"
    line.EndBX, line.EndBY, line.EndBZ = HANGOFF

    gen = m.general
    gen.StageDuration = [BUILDUP, STAGE1]
    gen.DynamicsSolutionMethod = "Implicit time domain"
    gen.ImplicitConstantTimeStep = dt
    return m, line


def interior_max(rg, total, attr):
    arc = list(rg.X)
    vals = list(getattr(rg, attr))
    lo, hi = 0.03 * total, 0.97 * total
    return max(abs(vals[i]) for i in range(len(vals)) if lo <= arc[i] <= hi)


def verify_components(m, comps):
    """Reconstruct OrcaFlex's own elevation from the table at two probe points."""
    period = ofx.SpecifiedPeriod(*WINDOW)
    t = list(m.general.TimeHistory("Time", period))
    worst = 0.0
    for x in (0.0, 37.0):
        eta = list(m.environment.TimeHistory("Elevation", period, ofx.oeEnvironment(x, 0.0, 0.0)))
        for j, tt in enumerate(t):
            s = 0.0
            for c in comps:
                om = 2.0 * math.pi * c.Frequency
                ph = math.radians(c.PhaseLagWrtSimulationTime)
                s += c.Amplitude * math.cos(c.WaveNumber * x - om * tt + ph)
            worst = max(worst, abs(s - eta[j]))
    return worst


def check_table(comps):
    """OrcaFlex must realise exactly CableDyn's components (order-independent)."""
    want = sorted(components(), key=lambda c: c[1])
    got = sorted(((c.Amplitude, 1.0 / c.Frequency, c.PhaseLagWrtSimulationTime % 360.0) for c in comps),
                 key=lambda c: c[1])
    if len(got) != len(want):
        return float("inf")
    worst = 0.0
    for (a, p, ph), (ga, gp, gph) in zip(want, got):
        dph = abs((ph - gph + 180.0) % 360.0 - 180.0)
        worst = max(worst, abs(a - ga) / a, abs(p - gp) / p, dph / 360.0)
    return worst


def run(dt, article_table=None):
    m, line = build(dt, article=article_table is not None)
    m.CalculateStatics()
    total = SITE["lsus"]
    k_static = interior_max(line.RangeGraph("Curvature"), total, "Mean")
    t_static = line.StaticResult("Effective Tension", ofx.oeEndB)
    comps = m.waveComponents
    stretch = m.environment.KinematicStretchingMethod

    m.RunSimulation()
    period = ofx.SpecifiedPeriod(*WINDOW)
    k_dyn = interior_max(line.RangeGraph("Curvature", period), total, "Max")
    ten = line.TimeHistory("Effective tension", period, ofx.oeEndB)
    err = verify_components(m, comps)

    print(f"=== L3-6c irregular sea 80 m, dt = {dt} s ===")
    table_err = 0.0 if article_table is not None else check_table(comps)
    sea = "OrcaFlex JONSWAP synthesis" if article_table else f"CableDyn table {NCOMP}"
    print(f"  components realised        : {len(comps)} ({sea}), "
          f"stretching read back: {stretch}")
    if article_table is None:
        print(f"  [check] realised vs CableDyn table: worst relative difference {table_err:.1e} "
              f"-> {'OK' if table_err < 1e-9 else 'MISMATCH - ABORT'}")
    print(f"  static peak curvature      : {k_static:.5f} 1/m   static tension {t_static:.4f} kN")
    print(f"  dynamic max curvature      : {k_dyn:.5f} 1/m   (window {WINDOW}, stage-1 time)")
    print(f"  hang-off tension mean      : {sum(ten)/len(ten):.4f} kN")
    print(f"  hang-off tension min/max   : {min(ten):.4f} / {max(ten):.4f} kN")
    print(f"  [check] table elevation reconstruction max err {err:.2e} m "
          f"-> {'OK' if err < 1e-6 else 'MISMATCH - ABORT'}")
    if err >= 1e-6 or table_err >= 1e-9 or "Wheeler" not in str(stretch):
        sys.exit(1)
    sys.stdout.flush()
    if article_table is not None:
        rows = [f"{len(comps)}"]
        rows += [f"{c.Amplitude:.16e}  {1.0 / c.Frequency:.16e}  "
                 f"{c.PhaseLagWrtSimulationTime:.16e}" for c in comps]
        Path(article_table).write_text("\n".join(rows) + "\n")
        table = [(c.Amplitude, 1.0 / c.Frequency, c.PhaseLagWrtSimulationTime) for c in comps]
        cs, ss = table_checksums(table)
        print(f"  article table written      : {article_table} ({len(comps)} rows), "
              f"check sums {cs:.12f} / {ss:.12f}")
    return dict(k_static=k_static, k_dyn=k_dyn, tmean=sum(ten) / len(ten), tmin=min(ten), tmax=max(ten))


def main():
    argv = sys.argv[1:]
    dt = 0.05
    if "--dt" in argv:
        i = argv.index("--dt")
        dt = float(argv[i + 1])
        del argv[i:i + 2]
    article_table = None
    if "--orcaflex-jonswap" in argv:
        i = argv.index("--orcaflex-jonswap")
        article_table = argv[i + 1]
        del argv[i:i + 2]
        r1 = run(dt, article_table)
        print(f"ART_KDYN = {r1['k_dyn']:.5f}, ART_TMEAN = {r1['tmean']:.4f}, "
              f"ART_TMIN = {r1['tmin']:.4f}, ART_TMAX = {r1['tmax']:.4f}")
        return
    table = components()
    c, s = table_checksums(table)
    hs = 4.0 * math.sqrt(sum(a * a / 2 for a, _, _ in table))
    print(f"CableDyn JONSWAP table: {len(table)} components, Hs {hs:.12f} m, check sums {c:.12f} / {s:.12f}")
    r1 = run(dt)
    r2 = run(dt / 2)
    worst = max(abs(r1[k] - r2[k]) / max(abs(r2[k]), 1e-12) for k in r1)
    print(f"[check] dt convergence ({dt} vs {dt/2}): worst scored-channel move {100*worst:.3f}%")
    print(f"REF_KSTAT = {r1['k_static']:.5f}, REF_KDYN = {r1['k_dyn']:.5f}, REF_TMEAN = {r1['tmean']:.4f}, "
          f"REF_TMIN = {r1['tmin']:.4f}, REF_TMAX = {r1['tmax']:.4f}")


if __name__ == "__main__":
    main()
