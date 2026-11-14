# File: validation/scripts/analytical_catenary.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Closed-form elastic grounded catenary: the reference for L2 mooring statics.

The closed-form solution is the common reference for the static cases of the three solvers
(CableDyn, MoorDyn-C, OrcaFlex): when they differ, each is compared with catenary(w) for the
agreed submerged weight per length w.

The submerged weight per length ``w`` [N/m] is an EXPLICIT argument. This routine
does NOT compute buoyancy itself -- the caller states the dry-or-buoyant
convention, so the reference does not assume one.

Model: a line of unstretched length L and axial stiffness EA hangs from a fairlead
to an anchor that sits on a flat, frictionless seabed at water depth ``depth``
below the fairlead, with horizontal fairlead->anchor span ``h_span``. Part of the
line rests on the seabed. Standard elastic grounded-catenary equations
(Jonkman 2007 / MAP++): with HF, VF the horizontal/vertical fairlead tension
components, suspended length Ls = VF/w, grounded length lb = L - Ls,

    XF = lb + (HF/w)*asinh(VF/HF) + HF*L/EA
    ZF = (HF/w)*(sqrt(1 + (VF/HF)^2) - 1) + VF^2 / (2*EA*w)

Fairlead tension T_F = hypot(HF, VF); anchor tension T_A = HF (frictionless
horizontal grounded run).
"""
from __future__ import annotations

import sys

import numpy as np
from scipy.optimize import fsolve


def grounded_catenary(depth, L, EA, w, h_span):
    """Return (T_fairlead_N, T_anchor_N, suspended_len_m, grounded_len_m, ok).

    All inputs SI. ``w`` is submerged weight per unstretched length [N/m],
    supplied explicitly (no buoyancy is computed here).
    """
    XF, ZF = float(h_span), float(depth)

    def eqs(p):
        HF, VF = p
        HF = max(HF, 1.0e-6)
        VF = max(VF, 1.0e-6)
        Z = (HF / w) * (np.sqrt(1.0 + (VF / HF) ** 2) - 1.0) + VF ** 2 / (2.0 * EA * w)
        X = (L - VF / w) + (HF / w) * np.arcsinh(VF / HF) + HF * L / EA
        return [X - XF, Z - ZF]

    # Inextensible seed: suspended length ~ sqrt(depth*(depth+2a)); pick a from span.
    VF0 = w * depth * 1.3
    HF0 = max(w * h_span * 0.08, 1.0e3)
    p, _info, ier, _msg = fsolve(eqs, [HF0, VF0], full_output=True)
    HF, VF = p
    Ls = VF / w
    return float(np.hypot(HF, VF)), float(HF), float(Ls), float(L - Ls), ier == 1


def _validate_volturnus():
    """Gate: reproduce the IEA-15MW / UMaine VolturnUS-S catenary-mooring tensions the L2
    static gate validates. R4 studless chain (volume-equivalent diameter 0.333 m, dry mass
    685 kg/m, EA 3.270e9 N, 850 m) at 200 m depth: fairlead radius 58 m / z = -14 m, anchor
    on the seabed at radius 837.6 m / z = -200 m -> horizontal span 779.6 m, height 186 m.
    Reference fairlead tension: OrcaFlex 11.6d 2427 kN; anchor = T_f - w*h (catenary)."""
    G, RHO = 9.80665, 1025.0
    EA, mass, diam, L = 3.270e9, 685.0, 0.333, 850.0
    w = (mass - RHO * np.pi / 4.0 * diam ** 2) * G  # net submerged weight (volume-equivalent diam)
    ref_f = 2427.0                                   # OrcaFlex 11.6d fairlead tension (kN)
    ref_a = ref_f - w * 186.0 / 1e3                  # anchor = fairlead - w*height (kN)
    cases = [("VolturnUS-S", 779.6, 186.0, ref_f, ref_a)]
    print(f"# closed-form catenary vs VolturnUS-S refs (w = {w:.2f} N/m = {w/G:.2f} kg/m, net-buoyant)")
    print(f"{'case':12} {'Tf_cat':>9} {'Tf_ref':>9} {'errF%':>7} {'Ta_cat':>9} {'Ta_ref':>9} {'errA%':>7}")
    worst = 0.0
    all_converged = True
    for name, h_span, depth, rf, ra in cases:
        Tf, Ta, Ls, lb, ok = grounded_catenary(depth, L, EA, w, h_span)
        all_converged = all_converged and ok
        Tf_kn, Ta_kn = Tf / 1e3, Ta / 1e3
        ef, ea = 100 * abs(Tf_kn - rf) / rf, 100 * abs(Ta_kn - ra) / ra
        worst = max(worst, ef, ea)
        print(f"{name:12} {Tf_kn:9.1f} {rf:9.1f} {ef:7.2f} {Ta_kn:9.1f} {ra:9.1f} {ea:7.2f}  ok={ok}")
    passed = all_converged and worst < 2.0
    if not all_converged:
        print("# a catenary solve FAILED to converge")
    print(f"# worst catenary-vs-VolturnUS-S error: {worst:.2f}%  -> {'PASS (<2%)' if passed else 'FAIL (>=2%)'}")
    return passed


if __name__ == "__main__":
    # Exit non-zero when the 2 % check fails or a solve does not converge, because every
    # downstream static comparison relies on this reference.
    sys.exit(0 if _validate_volturnus() else 1)
