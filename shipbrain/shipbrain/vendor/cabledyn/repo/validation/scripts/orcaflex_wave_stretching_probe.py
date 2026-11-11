# File: validation/scripts/orcaflex_wave_stretching_probe.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""L3-2 reference check: sensitivity of the OrcaFlex regular-wave reference to wave stretching.

The L3-2 regular-wave reference (`l3_orcaflex_wave_dynamic`) depends on the near-surface wave
kinematics. OrcaFlex's default `KinematicStretchingMethod` for a single Airy wave is vertical
stretching, while CableDyn's Airy field uses Wheeler stretching. This probe runs the case
once per stretching method, with the wave and line data set explicitly rather than taken from
a fresh model's defaults, and compares each run with an OrcaFlex run at the default step and
stretching (mean 998163.66 N, swing 8770.94 N, OrcFxAPI 11.6d). The mean is set by the static
weight and should not move. It then prints the step-converged vertical-stretching values that
the L3-2 test uses (implicit dt 0.01 and 0.005 s).

Model and protocol: WD0050 chain 410 m / 41 segments, anchor (400, 0, -50), fairlead held at
the origin, OD 0.252 m / 390 kg/m / EA 1.674e9 N, Cdn 1.37 / Cdt 0.64 / Can 1 / Cat 0
(generic drag/added-mass data names, set and verified by read-back), seabed friction zeroed,
WaveType "Single Airy" H = 3 m / T = 8 s / direction 180 deg, 16 s build-up + 6 wave periods,
OrcaFlex default dynamics settings (implicit solver, default step and log sampling). The
output is the fairlead effective tension over the last wave period: its mean and
peak-to-peak swing, printed in N to match the Fortran test. OrcaFlex units are SI (m, te, kN).
"""

import OrcFxAPI as ofx

EA0, MASS0, DIAM0 = 1.674e9, 390.0, 0.252
DEPTH = 50.0
ANCHOR = (400.0, 0.0, -50.0)
FAIR = (0.0, 0.0, 0.0)
TOTAL_LEN, NSEG = 410.0, 41
WAVE_H, WAVE_T, WAVE_DIR = 3.0, 8.0, 180.0
BUILD_UP, N_PERIODS = 16.0, 6
REF_MEAN_N, REF_SWING_N = 998163.6578595197, 8770.93505859375


def _set_verified(obj, name, value):
    obj.SetData(name, -1, value)
    got = obj.GetData(name, -1)
    if abs(got - value) > 1e-12 * max(1.0, abs(value)):
        raise RuntimeError(f"{name} read-back {got} != {value}")


def build_model(stretching=None, dt=None):
    m = ofx.Model()
    env = m.environment
    env.WaterDepth = DEPTH
    env.WaveType = "Single Airy"
    env.WaveDirection = WAVE_DIR
    env.WaveHeight = WAVE_H
    env.WavePeriod = WAVE_T
    if stretching is not None:
        env.KinematicStretchingMethod = stretching

    lt = m.CreateObject(ofx.ObjectType.LineType, "chain")
    lt.OD = DIAM0
    lt.MassPerUnitLength = MASS0 / 1000.0
    lt.EA = EA0 / 1000.0
    _set_verified(lt, "NormalDragCoefficient", 1.37)
    _set_verified(lt, "AxialDragCoefficient", 0.64)
    _set_verified(lt, "NormalAddedMassCoefficient", 1.0)
    _set_verified(lt, "AxialAddedMassCoefficient", 0.0)
    # frictionless reference convention
    for name in ("SeabedNormalFrictionCoefficient", "SeabedAxialFrictionCoefficient"):
        if lt.DataNameValid(name):
            lt.SetData(name, -1, 0.0)
    env_names = [n for n in ("SeabedNormalFrictionCoefficient",) if m.environment.DataNameValid(n)]
    for name in env_names:
        m.environment.SetData(name, -1, 0.0)

    line = m.CreateObject(ofx.ObjectType.Line, "leg")
    line.LineType = ("chain",)
    line.Length = (TOTAL_LEN,)
    line.TargetSegmentLength = (TOTAL_LEN / NSEG,)
    line.EndAConnection = "Fixed"
    line.EndAX, line.EndAY, line.EndAZ = ANCHOR
    line.EndBConnection = "Fixed"
    line.EndBX, line.EndBY, line.EndBZ = FAIR

    gen = m.general
    gen.StageDuration = BUILD_UP, N_PERIODS * WAVE_T
    if dt is not None:
        gen.ImplicitUseVariableTimeStep = "No"
        gen.ImplicitConstantTimeStep = dt
        gen.TargetLogSampleInterval = dt
    return m, line


def run_case(stretching, dt=None):
    m, line = build_model(stretching, dt)
    m.RunSimulation()
    te = list(line.TimeHistory("Effective tension", ofx.PeriodNum.LatestWave, ofx.oeEndB))
    mean = sum(te) / len(te) * 1e3
    swing = (max(te) - min(te)) * 1e3
    return mean, swing


def main():
    fresh = ofx.Model()
    print(f"OrcFxAPI {ofx.DLLVersion()}; fresh-model defaults: "
          f"WaveType={fresh.environment.WaveType!r} H={fresh.environment.WaveHeight} m")
    m, _ = build_model(None)
    default_method = m.environment.KinematicStretchingMethod
    print(f"Single Airy default KinematicStretchingMethod = {default_method!r}")
    print(f"default-step reference: mean = {REF_MEAN_N:.3f} N, swing = {REF_SWING_N:.3f} N\n")

    results = {}
    for method in (None, "Wheeler stretching", "Extrapolation stretching"):
        label = f"(default: {default_method})" if method is None else method
        try:
            mean, swing = run_case(method)
        except Exception as exc:
            print(f"  {label:34s}: <failed: {exc}>")
            continue
        results[label] = (mean, swing)
        dm = 100.0 * (mean - REF_MEAN_N) / REF_MEAN_N
        ds = 100.0 * (swing - REF_SWING_N) / REF_SWING_N
        print(f"  {label:34s}: mean = {mean:12.3f} N ({dm:+6.3f}%)   "
              f"swing = {swing:10.3f} N ({ds:+7.2f}% vs default-step reference)")

    # --- the pinned reference that l3_orcaflex_wave_dynamic embeds ---
    # Default (vertical) stretching, implicit dt = log interval pinned; the test's
    # scalars are the dt = 0.005 s row (dt-converged: 0.01 -> 0.005 moves the swing 0.019 %).
    print("\nPinned dt-converged reference (vertical stretching, dt = log pinned):")
    for dt in (0.01, 0.005):
        mean, swing = run_case(None, dt=dt)
        print(f"  dt = {dt:5.3f} s: mean = {mean!r} N   swing = {swing!r} N")


if __name__ == "__main__":
    main()
