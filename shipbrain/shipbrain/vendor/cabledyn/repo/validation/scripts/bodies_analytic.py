# File: validation/scripts/bodies_analytic.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Closed-form references of the bodies validation suite.

* Surface-piercing spars (V-SP-heave, V-SP-pitch, V-SPW): equilibrium draft, heave period,
  surge-pitch free-floating pitch period, static heel, for the exact waterplane second moment
  ``I_wp = pi d^4/64`` and for MoorDyn's rod waterplane term ``pi d^4/16 * rho g sin(phi) cos(phi)``.
* Dry pinned-rod pendulum (V-P1a..c): elliptic-integral period and the exact angle history.

Run:  python validation/scripts/bodies_analytic.py
Writes references/<ID>/analytic.json (+ analytic.csv series for the pendulum).
"""

from __future__ import annotations

import datetime
import json
import math

import numpy as np
from scipy.special import ellipj, ellipk

from bodies_cases import PEND, SPAR, SQUAT, pend_period, squat_ballast
from bodies_common import REFS, write_reference
from bodies_decks import G, RHO

PROV = dict(version="closed form", settings="see method", dt=None, commit="")


def spar_properties(p: dict) -> dict:
    """Linear hydrostatics and rigid-body/added-mass data of a body-ballasted surface spar."""
    d, top, bottom = p["d"], p["top"], p["bottom"]
    L = top - bottom
    area = math.pi * d * d / 4.0
    if p["mbody"] is None:
        mb, zcb, ib = squat_ballast()
    else:
        mb, zcb = p["mbody"], p["zcg"]
        ib = float(p["Ib"].split("|")[0])
    mr = p["mrod"] * L
    zr = 0.5 * (top + bottom)
    m = mb + mr
    draft = m / (RHO * area)                     # rho A draft = m (vertical, end-cap buoyancy)
    z_eq = -(bottom + draft)                     # body offset so that the waterline is at z = 0
    vol = area * draft
    # equilibrium frame: body reference at z_eq
    zcb_e, zr_e, zbot = zcb + z_eq, zr + z_eq, bottom + z_eq
    zg = (mb * zcb_e + mr * zr_e) / m
    zb = zbot / 2.0
    i_wp = math.pi * d ** 4 / 64.0
    bm = i_wp / vol
    gm = zb + bm - zg
    ig = ib + mb * (zcb_e - zg) ** 2 + mr * (L * L / 12.0 + d * d / 16.0) + mr * (zr_e - zg) ** 2
    a = RHO * p["Ca"] * area                     # transverse added mass per length (submerged part)
    z0, z1 = zbot, 0.0
    a11 = a * (z1 - z0)
    a15 = a * ((z1 - zg) ** 2 - (z0 - zg) ** 2) / 2.0
    a55 = a * ((z1 - zg) ** 3 - (z0 - zg) ** 3) / 3.0
    i55 = ig + a55 - a15 * a15 / (m + a11)       # surge condensed out (no surge stiffness)
    v_end = 2.0 / 3.0 * math.pi * (d / 2.0) ** 3
    a33 = RHO * p["CaEnd"] * v_end
    c33 = RHO * G * area
    c55 = RHO * G * vol * gm
    extra = {"exact (pi d^4/64)": 0.0,
             "MoorDyn, cap moments exact (+pi d^4/16)": RHO * G * math.pi * d ** 4 / 16.0,
             "MoorDyn, bottom-cap moment sign reversed (+pi d^4/32)": RHO * G * math.pi * d ** 4 / 32.0}
    periods = {k: 2.0 * math.pi * math.sqrt(i55 / (c55 + v)) for k, v in extra.items()}
    return dict(
        d=d, L=L, mass_body=mb, mass_rod=mr, mass=m, draft=draft, z_eq=z_eq, volume=vol,
        z_B=zb, z_G=zg, BM=bm, GM=gm, I_wp=i_wp, I_G=ig, A11=a11, A15=a15, A55=a55,
        I55_eff=i55, a33=a33, C33=c33, C55_exact=c55,
        GM_equivalent={k: gm + v / (RHO * G * vol) for k, v in extra.items()},
        T_heave=2.0 * math.pi * math.sqrt((m + a33) / c33),
        T_pitch=periods,
        T_pitch_exact=periods["exact (pi d^4/64)"],
        heel_1MNm_deg={k: math.degrees(1.0e6 / (c55 + v)) for k, v in extra.items()},
        heel_1MNm_wallsided_deg=math.degrees(_wall_sided_heel(1.0e6, RHO * G * vol, gm, bm)),
    )


def _wall_sided_heel(moment, weight, gm, bm):
    """Solve M = W sin(t) (GM + BM tan^2(t)/2) (wall-sided, waterline off the end caps)."""
    t = moment / (weight * gm)
    for _ in range(50):
        f = weight * math.sin(t) * (gm + 0.5 * bm * math.tan(t) ** 2) - moment
        df = weight * (math.cos(t) * (gm + 0.5 * bm * math.tan(t) ** 2)
                       + math.sin(t) * bm * math.tan(t) / math.cos(t) ** 2)
        t -= f / df
    return t


def pendulum(theta0_deg: float) -> tuple[dict, np.ndarray]:
    L, d = PEND["L"], PEND["d"]
    m = PEND["m"] * L
    ia = m * (L * L / 3.0 + d * d / 16.0)
    w0 = math.sqrt(m * G * L / 2.0 / ia)
    k = math.sin(math.radians(theta0_deg) / 2.0)
    kk = ellipk(k * k)
    T = pend_period(theta0_deg)
    t = np.linspace(0.0, 5.0 * T, 1001)
    sn, _, _, _ = ellipj(kk - w0 * t, k * k)
    theta = np.degrees(2.0 * np.arcsin(np.clip(k * sn, -1.0, 1.0)))
    vals = dict(theta0_deg=theta0_deg, I_A=ia, omega0=w0, T=T, T_small_amplitude=2 * math.pi / w0,
                energy=-m * G * L / 2.0 * math.cos(math.radians(theta0_deg)),
                formula="T = 4 sqrt(I_A/(m g L/2)) K(sin(theta0/2)), I_A = m (L^2/3 + d^2/16)")
    return vals, np.column_stack([t, theta])


def main() -> None:
    for cid, p in (("V-SP-heave", SPAR), ("V-SP-pitch", SPAR), ("V-SPW", SQUAT)):
        vals = spar_properties(p)
        out = REFS / cid
        out.mkdir(parents=True, exist_ok=True)
        rec = dict(case=cid, code="analytic", date=datetime.date.today().isoformat(), **PROV,
                   method=("linear hydrostatics of a wall-sided cylinder; free-floating surge-pitch "
                           "eigenproblem with surge condensed; transverse added mass rho Ca A over the "
                           "wetted length; end added mass rho CaEnd (2/3) pi r^3 in heave"),
                   values=vals)
        (out / "analytic.json").write_text(json.dumps(rec, indent=1) + "\n", newline="\n")
        print(cid, {k: vals[k] for k in ("draft", "z_eq", "GM", "BM", "T_heave", "T_pitch")})
    for cid, th in (("V-P1a", 10.0), ("V-P1b", 60.0), ("V-P1c", 120.0)):
        vals, series = pendulum(th)
        write_reference(cid, "analytic", ["Time", "theta"], series,
                        dict(version="closed form (Jacobi elliptic)", settings=vals, dt=None),
                        fmt="%.10e")
        print(cid, vals["T"])


if __name__ == "__main__":
    main()
