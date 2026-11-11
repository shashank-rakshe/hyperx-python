# File: validation/scripts/bodies_spar_release_check.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Independent check of the V-D2c large-amplitude spar release (dx = 2 m).

A planar rigid-rod model with the same Morison data as the MoorDyn-C twin (transverse Cd and
Ca over the rod length, exact buoyancy, no end effects) and four elastic, tension-only,
linearly damped lines. The lines are massless (``--line-mass`` lumps half of each attached
line's dry and added mass at the rod end instead). The rod starts vertical and at rest with
the anchors shifted by -2 m in x, exactly as ``cases/V-D2c``. Prints the first extreme of the
bottom-end surge and compares it with the stored MoorDyn-C reference.

Run:  python validation/scripts/bodies_spar_release_check.py [--line-mass]
"""

from __future__ import annotations

import argparse
import math

import numpy as np
from scipy.integrate import solve_ivp

from bodies_common import load_reference
from bodies_decks import G, RHO
from bodies_metrics import first_extreme

D, L, MP, CD_ROD, CA_ROD = 1.0, 10.0, 300.0, 0.8, 1.0
LINE = dict(d=0.10, m=10.0, EA=2.0e7, zeta=1.0)
DX = 2.0
# (anchor x, anchor z, rod end ('A' top | 'B' bottom), unstretched length, segments, multiplicity)
LINES = [(25.0 - DX, -50.0, "B", 31.95, 16, 1), (-25.0 - DX, -50.0, "B", 31.95, 16, 1),
         (-DX, -50.0, "A", 42.40, 20, 2)]  # the two y-symmetric top legs act as one (x-z) pair
Y_TOP = 30.0


def rhs_factory(line_mass: bool):
    area = math.pi * D * D / 4.0
    m = MP * L
    ic = m * (L * L / 12.0 + D * D / 16.0)
    a = RHO * CA_ROD * area
    wsub = (LINE["m"] - RHO * math.pi * LINE["d"] ** 2 / 4.0) * G
    s_g, w_g = np.polynomial.legendre.leggauss(64)
    s_g, w_g = 0.5 * L * s_g, 0.5 * L * w_g
    end_mass = {"A": 0.0, "B": 0.0}
    if line_mass:
        for _, _, end, l0, _, k in LINES:
            # half the dry mass plus half the transverse added mass of each attached line
            end_mass[end] += k * 0.5 * l0 * (LINE["m"] + RHO * math.pi * LINE["d"] ** 2 / 4.0)

    def rhs(_t, y):
        x, z, psi, vx, vz, w = y
        q = np.array([math.sin(psi), math.cos(psi)])       # axis, bottom (B) -> top (A)
        n = np.array([math.cos(psi), -math.sin(psi)])      # dq/dpsi
        c = np.array([x, z])
        vc = np.array([vx, vz])
        F = np.array([0.0, (RHO * area * L - m) * G])
        M = 0.0
        # transverse drag (still water)
        vn = vc @ n + s_g * w
        f = -0.5 * RHO * CD_ROD * D * np.abs(vn) * vn
        F += np.sum(w_g * f) * n
        M += np.sum(w_g * f * s_g)
        ends = {"A": (c + 0.5 * L * q, vc + 0.5 * L * w * n, 0.5 * L),
                "B": (c - 0.5 * L * q, vc - 0.5 * L * w * n, -0.5 * L)}
        for ax, az, end, l0, nseg, k in LINES:
            p, v, s = ends[end]
            dy = Y_TOP if end == "A" else 0.0
            d3 = np.array([ax - p[0], dy, az - p[1]])
            ell = float(np.linalg.norm(d3))
            u3 = d3 / ell
            ldot = -(v[0] * u3[0] + v[1] * u3[2])
            eps, epsd = (ell - l0) / l0, ldot / l0
            ba = LINE["zeta"] * (l0 / nseg) * math.sqrt(LINE["EA"] * LINE["m"])
            T = LINE["EA"] * eps + ba * epsd if eps > 0 else 0.0
            T = max(T, 0.0)
            fe = k * T * np.array([u3[0], u3[2]])
            if line_mass:
                fe = fe + np.array([0.0, -k * 0.5 * l0 * wsub])
            F += fe
            M += s * (fe @ n)
        # mass matrix with transverse added mass (instantaneous, as both codes) and end masses
        Mt = m * np.eye(2) + a * L * np.outer(n, n)
        J = ic + a * L ** 3 / 12.0
        Mc = np.zeros((3, 3))
        Mc[:2, :2] = Mt
        Mc[2, 2] = J
        for end, me in end_mass.items():
            if me:
                s = 0.5 * L if end == "A" else -0.5 * L
                Mc[:2, :2] += me * np.eye(2)
                Mc[:2, 2] += me * s * n
                Mc[2, :2] += me * s * n
                Mc[2, 2] += me * s * s
        rhs_f = np.array([F[0], F[1], M])
        for end, me in end_mass.items():
            # centripetal part of the end-mass acceleration a_c + s w' n - s w^2 q
            s = 0.5 * L if end == "A" else -0.5 * L
            rhs_f[:2] += me * s * w * w * q
        acc = np.linalg.solve(Mc, rhs_f)
        return [vx, vz, w, *acc]

    return rhs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--line-mass", action="store_true")
    a = ap.parse_args()
    out = {}
    for lm in ([False, True] if a.line_mass else [False]):
        sol = solve_ivp(rhs_factory(lm), (0.0, 8.0), [0.0, -25.0, 0.0, 0.0, 0.0, 0.0], method="DOP853",
                        rtol=1e-10, atol=1e-12, max_step=1e-3, dense_output=True)
        t = np.linspace(0.0, 8.0, 8001)
        x, z, psi = sol.sol(t)[:3]
        xb = x - 0.5 * L * np.sin(psi)
        k = int(np.argmin(xb[:2000]))
        out[lm] = (t[k], xb[k])
        print(f"planar model ({'lumped line mass' if lm else 'massless lines'}): bottom-end x first "
              f"minimum {xb[k]:+.4f} m at t = {t[k]:.3f} s")
    try:
        ref, prov = load_reference("V-D2c", "moordyn_c")
        tr, xr = ref["Time"], ref["Rod1N20Px"]
        k = int(np.argmin(xr[tr < 2.0]))
        print(f"MoorDyn-C {prov['version'].get('describe')} dt {prov['dt']:g}: bottom-end x first minimum "
              f"{xr[k]:+.4f} m at t = {tr[k]:.3f} s")
    except FileNotFoundError:
        print("MoorDyn-C reference V-D2c not generated yet")


if __name__ == "__main__":
    main()
