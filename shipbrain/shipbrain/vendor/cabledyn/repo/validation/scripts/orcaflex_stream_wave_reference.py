# File: validation/scripts/orcaflex_stream_wave_reference.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""OrcaFlex reference for the stream-function (Dean) regular wave of ``test_stream_wave``.

Builds an empty OrcaFlex model whose environment carries a single "Dean stream" wave
(H = 8 m, T = 10 s, d = 50 m, direction 0, stream-function order 20) and samples the wave
kinematics at the origin, where a crest passes at t = 0: the crest and trough elevations,
the horizontal particle velocity under the crest (at the surface and at z = 0, -10 m and
-30 m from the mean level), and the celerity from the crest arrival at x = 0 and x = 20 m
(crest times refined by a parabola through the logged samples). The printed numbers are
committed as the OrcaFlex constants of the Fortran gate (tests/test_stream_wave.f90).
Requires OrcFxAPI (OrcaFlex 11.6d) with a licence.
"""

import numpy as np
import OrcFxAPI as ofx

H, T, D = 8.0, 10.0, 50.0
ORDER = 20


def build_model():
    m = ofx.Model()
    env = m.environment
    env.WaterDepth = D
    env.WaveType = "Dean stream"
    env.WaveDirection = 0.0
    env.WaveHeight = H
    env.WavePeriod = T
    env.WaveStreamFunctionOrder = ORDER
    m.general.StageDuration = (T, 2.0 * T)
    return m


def main():
    m = build_model()
    m.RunSimulation()
    env = m.environment
    period = ofx.SpecifiedPeriod(0.0, 2.0 * T)
    t = np.asarray(env.SampleTimes(period))
    eta0 = np.asarray(env.TimeHistory("Elevation", period, ofx.oeEnvironment(0.0, 0.0, 0.0)))
    eta20 = np.asarray(env.TimeHistory("Elevation", period, ofx.oeEnvironment(20.0, 0.0, 0.0)))

    def refine(y, i):
        # parabolic crest time from the three samples around the peak (actual log spacing)
        a, b, c = y[i - 1], y[i], y[i + 1]
        return t[i] + (t[i + 1] - t[i]) * 0.5 * (a - c) / (a - 2.0 * b + c)

    i_crest = 1 + int(np.argmax(eta0[1:-1]))
    t0 = refine(eta0, i_crest)
    later = np.where((t > t0) & (t < t0 + 0.5 * T))[0]
    i20 = int(later[np.argmax(eta20[later])])
    t20 = refine(eta20, i20)
    print(f"log sample spacing   = {t[1] - t[0]:.6f} s")
    celerity = 20.0 / (t20 - t0)
    print(f"OrcFxAPI {ofx.DLLVersion()}")
    print(f"crest elevation      = {eta0.max():.6f} m")
    print(f"trough elevation     = {eta0.min():.6f} m")
    print(f"celerity             = {celerity:.6f} m/s  (wavelength {celerity * T:.4f} m)")
    for z in (0.0, -10.0, -30.0):
        zz = min(z, eta0.max() - 1.0e-6)
        u = np.asarray(env.TimeHistory("X velocity", period, ofx.oeEnvironment(0.0, 0.0, zz)))
        print(f"u at crest, z = {z:6.1f} m = {u[i_crest]:.6f} m/s  (max {u.max():.6f})")
    u_surf = np.asarray(
        env.TimeHistory("X velocity", period, ofx.oeEnvironment(0.0, 0.0, eta0.max() - 1e-6))
    )
    print(f"u at the crest surface = {u_surf.max():.6f} m/s  (crest at t = {t0:.4f} s)")


if __name__ == "__main__":
    main()
