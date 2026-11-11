# File: validation/scripts/orcaflex_torsion_reference.py
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""OrcaFlex references for the CableDyn torsion validation (provenance tool, not built by CMake).

    python validation/scripts/orcaflex_torsion_reference.py [a] [b] [c] [--out DIR] [--refs FILE]
    python validation/scripts/orcaflex_torsion_reference.py --summary JSON --refs FILE

Runs with OrcaFlex 11.6d through OrcFxAPI 11.6d (about 5 min for all three cases). The run
writes only DIR/orcaflex_torsion_summary.json (default DIR: build/validation): the OrcaFlex
version, every data item the script sets together with the value OrcaFlex reads back, the
SHA-256 of this script and the summary values of each case. No OrcaFlex model, simulation or
raw result file is written. ``--refs FILE`` turns that summary (or, with ``--summary``, an
existing one, without running OrcaFlex) into the compact table that
``tests/test_torsion_orcaflex.f90`` checks, ``tests/data/torsion_orcaflex_refs.txt`` (SI units).
The pure-torsion case of that test runs the deck with a larger EI than case a (see the test):
the straight-branch torque does not depend on EI.

OrcaFlex units: m, te, kN, s; torque kN.m.

Conventions established with the API:
  * Line data names: IncludeTorsion, StaticsStep1/2, End{A,B}{Azimuth,Declination,Gamma},
    End{A,B}{x,y}BendingStiffness, End{A,B}TwistingStiffness; line type GJ, TensionTorqueCoupling.
  * With torsion included an end must be either encastre (every end stiffness Infinity) or have
    every stiffness finite; a bending-free end with an infinite twisting stiffness is rejected.
  * Imposed end twist = End B gamma (right-handed about the end Ez axis). A fresh statics run
    maps gamma_B - gamma_A into (-180, 180] deg; multi-turn twist is reached by continuation in
    steps below 180 deg with UseCalculatedPositions(SetLinesToUserSpecifiedStartingShape=True).
  * 'Torque' is + GJ (phi_B - phi_A) / L for a right-handed rotation phi about the A->B
    tangent; 'Twist' is the twist rate in deg/m; end stiffnesses are in kN.m/deg.
  * A full modal analysis raises 'static position is an unstable equilibrium' past a buckling
    onset; that flag is the bisection detector of case b.

Cases:
  a  pure torsion of a straight clamped-clamped neutrally buoyant line (L 10 m, GJ 10 kN.m^2).
  b  Greenhill onset, clamped-clamped, dead-tension prestress by end separation, found by
     bisection on the modal stability flag and cross-checked by extrapolating the lowest lateral
     f^2 to zero; 25 to 400 segments; compared with van der Heijden et al. (2003) eq. (33) at the
     measured tension. Also bending-free ends with a finite twisting spring (semi-tangential).
  c  Lozon et al. (2025) Gulf of Mexico 80 m lazy-wave cable with an illustrative
     GJ = 50 kN.m^2, both ends clamped in their untwisted static orientation; hang-off gamma
     0 -> 5 turns in quarter turns by continuation; segments 0.75 m and 0.375 m.
"""

from __future__ import annotations

import argparse
import cmath
import hashlib
import json
import math
import os
import time
import traceback

# OrcFxAPI is imported only to run OrcaFlex (_load_orcaflex), so --summary works without it
ofx = None

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SUMMARY_NAME = "orcaflex_torsion_summary.json"
RHO_W = 1.025  # te/m^3 (OrcaFlex default sea water density)
STATICS_TOL = {"a": 1e-9, "b": 1e-8, "c": 1e-8}  # General.StaticsTolerance (default 1e-6);
# the tightest value each case converges with (b: 1e-9 fails with EA/EI = 1e5)
STATICS_MAXIT = 2000  # General.StaticsMaxIterations (default 400)
SETTINGS: dict = {}  # "case/object.dataname" -> {"set": v, "readback": v}


def inf():
    return ofx.OrcinaInfinity()


def setv(case, obj, name, value):
    """Set a data item, read it back, fail if it did not take effect, record it."""
    setattr(obj, name, value)
    rb = getattr(obj, name)
    if not isinstance(rb, (str, int, float)):
        rb = list(rb)  # IndexedDataItem (per-section data)
    if isinstance(value, (list, tuple)):
        ok = len(rb) == len(value) and all(_same(a, b) for a, b in zip(value, rb))
    else:
        ok = _same(value, rb)
    if not ok:
        raise RuntimeError(f"{obj.name}.{name}: set {value!r} but read back {rb!r}")
    key = f"{case}/{obj.name}.{name}"
    entry = {"set": _js(value), "readback": _js(rb)}
    prev = SETTINGS.setdefault(key, [])
    if entry not in prev:
        prev.append(entry)
    return rb


def _same(a, b):
    if isinstance(a, str) or isinstance(b, str):
        return str(a) == str(b)
    if a >= 1e306 and b >= 1e306:  # OrcaFlex 'Infinity'
        return True
    return abs(a - b) <= 1e-12 * max(1.0, abs(a))


def _js(v):
    if isinstance(v, (list, tuple)):
        return [_js(x) for x in v]
    if isinstance(v, float) and v >= 1e306:
        return "Infinity"
    return v


def new_model(case, depth):
    m = ofx.Model()
    setv(case, m.general, "StaticsTolerance", STATICS_TOL[case])
    setv(case, m.general, "StaticsMaxIterations", STATICS_MAXIT)
    setv(case, m.environment, "WaterDepth", depth)
    setv(case, m.environment, "Density", RHO_W)
    return m


def line_type(case, m, name, od, mass_te_per_m, ea_kN, ei_kNm2, gj_kNm2):
    lt = m.CreateObject(ofx.ObjectType.LineType, name)
    setv(case, lt, "OD", od)
    setv(case, lt, "ID", 0.0)
    setv(case, lt, "MassPerUnitLength", mass_te_per_m)
    setv(case, lt, "EA", ea_kN)
    setv(case, lt, "EIx", ei_kNm2)  # EIy left '~' (= EIx, isotropic)
    setv(case, lt, "GJ", gj_kNm2)
    setv(case, lt, "TensionTorqueCoupling", 0.0)
    setv(case, lt, "SeabedLateralFrictionCoefficient", 0.0)  # axial '~' = lateral
    return lt


def end_conn(case, line, ab, *, x, y, z, azimuth, declination, gamma=0.0, conn="Fixed", clamped=True):
    setv(case, line, f"End{ab}Connection", conn)
    setv(case, line, f"End{ab}X", x)
    setv(case, line, f"End{ab}Y", y)
    setv(case, line, f"End{ab}Z", z)
    setv(case, line, f"End{ab}Azimuth", azimuth)
    setv(case, line, f"End{ab}Declination", declination)
    setv(case, line, f"End{ab}Gamma", gamma)
    if clamped:  # encastre: every connection stiffness Infinity (y '~' follows x)
        setv(case, line, f"End{ab}xBendingStiffness", inf())
        setv(case, line, f"End{ab}TwistingStiffness", inf())


def straight_model(case, L, n_seg, ei, gj, ea, od=0.1, depth=100.0, sep_extra=0.0, sections=None):
    """Neutrally buoyant straight line along global X at mid-depth: weightless in water.

    sections: optional [(GJ, length)], each a separate line type, for the series check."""
    m = new_model(case, depth)
    mass = RHO_W * math.pi / 4 * od**2  # neutral buoyancy
    line = m.CreateObject(ofx.ObjectType.Line, "rod")
    if sections is None:
        line_type(case, m, "lt0", od, mass, ea, ei, gj)
        sections = [("lt0", L)]
    else:
        names = []
        for i, (g, ln_) in enumerate(sections):
            line_type(case, m, f"lt{i}", od, mass, ea, ei, g)
            names.append((f"lt{i}", ln_))
        sections = names
    setv(case, line, "IncludeTorsion", "Yes")
    setv(case, line, "StaticsStep1", "Catenary")
    setv(case, line, "StaticsStep2", "Full statics")
    setv(case, line, "NumberOfSections", len(sections))
    setv(case, line, "LineType", [s[0] for s in sections])
    setv(case, line, "Length", [s[1] for s in sections])
    setv(case, line, "TargetSegmentLength", [L / n_seg] * len(sections))
    zc = -depth / 2
    # Ez of both end fittings along +X (A -> B): azimuth 0, declination 90.
    end_conn(case, line, "A", x=0.0, y=0.0, z=zc, azimuth=0.0, declination=90.0)
    end_conn(case, line, "B", x=L + sep_extra, y=0.0, z=zc, azimuth=0.0, declination=90.0)
    return m, line


def rg(line, var):
    r = line.RangeGraph(var)
    return list(r.X), list(r.Mean)


def statics(m):
    m.CalculateStatics()


def commit(m):
    """Make the converged static state the starting shape of the next solve (this keeps the
    multi-turn twist; it resets the model, so read results before calling it)."""
    if m.state == ofx.ModelState.InStaticState:
        m.UseCalculatedPositions(True)


def set_gamma_continued(m, line, ab, target, step=90.0):
    """Walk End gamma to target in steps <= step deg, each started from the previous state."""
    commit(m)
    cur = getattr(line, f"End{ab}Gamma")
    n = max(1, math.ceil(abs(target - cur) / step))
    for k in range(1, n + 1):
        commit(m)
        line.SetData(f"End{ab}Gamma", -1, cur + (target - cur) * k / n)
        statics(m)


# ------------------------------------------------------------------------------------------
def case_a():
    L, gj, ei, ea, n = 10.0, 10.0, 1.0, 1.0e5, 20
    rows = []
    m, line = straight_model("a", L, n, ei, gj, ea)
    # gamma_B values reached by continuation from 0 (steps <= 90 deg)
    for gam in (90.0, 450.0, 1800.0, -90.0):
        set_gamma_continued(m, line, "B", gam)
        s, tq = rg(line, "Torque")
        _, tw = rg(line, "Twist")
        _, yy = rg(line, "Y")
        _, zz = rg(line, "Z")
        exp = gj * math.radians(gam) / L
        rows.append(
            {
                "gamma_A_deg": 0.0,
                "gamma_B_deg": gam,
                "expected_GJ_Phi_over_L_kNm": exp,
                "torque_min_kNm": min(tq),
                "torque_max_kNm": max(tq),
                "torque_rel_err_max": max(abs(t / exp - 1) for t in tq),
                "twist_rate_deg_per_m_min": min(tw),
                "twist_rate_deg_per_m_max": max(tw),
                "Gamma_result_endB_deg": line.StaticResult("Gamma", ofx.oeEndB),
                "max_lateral_m": max(math.hypot(a, b + 50.0) for a, b in zip(yy, zz)),
                "bend_moment_endB_kNm": line.StaticResult("Bend moment", ofx.oeEndB),
            }
        )
        print("case a", rows[-1], flush=True)
    # fresh statics (no continuation) at 450 deg: OrcaFlex takes the twist modulo one turn
    m2, line2 = straight_model("a", L, n, ei, gj, ea)
    setv("a", line2, "EndBGamma", 450.0)
    m2.CalculateStatics()
    fresh450 = rg(line2, "Torque")[1][n // 2]
    # only the end gamma difference matters
    m3, line3 = straight_model("a", L, n, ei, gj, ea)
    setv("a", line3, "EndAGamma", 30.0)
    setv("a", line3, "EndBGamma", 120.0)
    m3.CalculateStatics()
    diff90 = rg(line3, "Torque")[1][n // 2]
    # series compliance: two sections GJ 10 / 25 kN.m^2, 4 m + 6 m, gamma_B = 90 deg
    secs = [(10.0, 4.0), (25.0, 6.0)]
    m4, line4 = straight_model("a", L, n, ei, gj, ea, sections=secs)
    setv("a", line4, "EndBGamma", 90.0)
    m4.CalculateStatics()
    _, tq4 = rg(line4, "Torque")
    _, tw4 = rg(line4, "Twist")
    exp4 = math.radians(90.0) / sum(l_ / g for g, l_ in secs)
    return {
        "L_m": L,
        "GJ_kNm2": gj,
        "EI_kNm2": ei,
        "EA_kN": ea,
        "segments": n,
        "continuation_rows": rows,
        "fresh_statics_gamma450": {
            "torque_kNm": fresh450,
            "note": "fresh statics returns the 90 deg solution: gamma is taken modulo one turn unless continued",
        },
        "gammaA30_gammaB120": {"torque_kNm": diff90, "expected_kNm": gj * math.radians(90.0) / L},
        "series_two_sections": {
            "sections_GJ_len": secs,
            "gamma_B_deg": 90.0,
            "expected_kNm": exp4,
            "torque_min_kNm": min(tq4),
            "torque_max_kNm": max(tq4),
            "twist_rate_deg_per_m_range": [min(tw4), max(tw4)],
        },
    }


# ------------------------------------------------------------------------------------------
def eq33(M, T, B=1.0, L=1.0):
    """van der Heijden et al. (2003) eq. (33) residual, clamped-clamped, m = ML/(2 pi B),
    t = TL^2/(4 pi^2 B)."""
    m = M * L / (2 * math.pi * B)
    t = T * L * L / (4 * math.pi**2 * B)
    a = cmath.sqrt(m * m - 4 * t)
    if abs(a) < 1e-12:
        sinc = math.pi
    else:
        sinc = cmath.sin(math.pi * a) / a
    return (cmath.cos(math.pi * a) - math.cos(math.pi * m) - 2 * math.pi * t * sinc).real


def eq33_root(T, B, L, guess):
    """Root of eq. (33) in M bracketed around guess (first critical torque)."""
    t = T * L * L / (4 * math.pi**2 * B)
    if abs(t) < 1e-9:  # eq. (33) degenerates at t = 0 to tan(pi m) = pi m (paper, p. 172)
        lo, hi = 4.4, 4.6
        for _ in range(200):
            mid = 0.5 * (lo + hi)
            if math.tan(mid) - mid < 0:
                lo = mid
            else:
                hi = mid
        return 2 * B / L * 0.5 * (lo + hi)
    # first sign change of the residual nearest the guess
    xs = [guess * (0.8 + 0.4 * i / 4000) for i in range(4001)]
    fs = [eq33(x, T, B, L) for x in xs]
    cands = [i for i in range(4000) if fs[i] * fs[i + 1] <= 0]
    if not cands:
        raise RuntimeError("eq33 bracket failed")
    i = min(cands, key=lambda j: abs(xs[j] - guess))
    lo, hi, flo = xs[i], xs[i + 1], fs[i]
    for _ in range(200):
        mid = 0.5 * (lo + hi)
        fm = eq33(mid, T, B, L)
        if flo * fm <= 0:
            hi = mid
        else:
            lo, flo = mid, fm
        if hi - lo < 1e-14 * guess:
            break
    return 0.5 * (lo + hi)


def lowest_period(line):
    """(stable, lowest period). Unstable equilibrium -> (False, None)."""
    try:
        md = ofx.Modes(line, ofx.ModalAnalysisSpecification(calculateShapes=False))
        return True, float(list(md.period)[0])
    except ofx.DLLError as exc:
        if "unstable equilibrium" in str(exc):
            return False, None
        raise


def onset_one(n, Tn, gj=10.0, L=10.0, ei=1.0, ea=1.0e5, rel_tol=2e-7):
    ref_nom = {0: 8.98681892, 10: 10.42885644, 50: 15.58932393, 200: 28.98273785}[Tn]
    T = Tn * ei / L**2
    sep = T * L / ea
    m, line = straight_model("b", L, n, ei, gj, ea, sep_extra=sep)
    phi_ref = ref_nom * ei / L * L / gj  # rad
    t0 = time.time()

    def at(gdeg):
        set_gamma_continued(m, line, "B", gdeg, step=60.0)
        st, per = lowest_period(line)
        tq = rg(line, "Torque")[1]
        return st, per, tq[len(tq) // 2]

    # bracket: walk up from 0.9 phi_ref in 1 % steps
    g_lo = math.degrees(0.9 * phi_ref)
    st, per, _ = at(g_lo)
    if not st:
        raise RuntimeError(f"n={n} T={Tn}: unstable already at 0.9 x closed form")
    g_hi = None
    g = g_lo
    while g_hi is None:
        g += math.degrees(0.01 * phi_ref)
        st, per, _ = at(g)
        if st:
            g_lo = g
        else:
            g_hi = g
        if g > math.degrees(1.2 * phi_ref):
            raise RuntimeError("no instability found up to 1.2 x closed form")
    # bisection on the modal stability flag
    while (g_hi - g_lo) > rel_tol * g_hi:
        gm = 0.5 * (g_lo + g_hi)
        st, per, _ = at(gm)
        if st:
            g_lo = gm
        else:
            g_hi = gm
    st, per, M_lo = at(g_lo)
    _, te = rg(line, "Effective tension")
    T_meas = te[len(te) // 2]
    # cross-check: quadratic extrapolation of f1^2 = 1/P1^2 to zero from the stable side
    pts = []
    for frac in (0.97, 0.98, 0.99):
        st2, per2, M2 = at(g_lo * frac)
        pts.append((M2, 1.0 / per2**2))
    M_extrap = _quad_root(pts)
    M_eq33 = eq33_root(T_meas, ei, L, ref_nom * ei / L)
    return {
        "segments": n,
        "T_nominal_kN": T,
        "T_measured_mid_kN": T_meas,
        "TL2_over_EI_measured": T_meas * L * L / ei,
        "gamma_onset_deg": [g_lo, g_hi],
        "M_onset_kNm": M_lo,
        "M_onset_L_over_EI": M_lo * L / ei,
        "M_onset_f2_extrapolated_kNm": M_extrap,
        "eq33_at_measured_T_kNm": M_eq33,
        "eq33_at_nominal_T_kNm": ref_nom * ei / L,
        "rel_err_vs_eq33": M_lo / M_eq33 - 1,
        "lowest_period_at_onset_s": per,
        "seconds": round(time.time() - t0, 1),
    }


PINNED_REF = {  # analytic_refs.json B_greenhill.pinned (M_cr L/EI)
    0: {"semi_tangential": 4.91128772575888, "axial_greenhill": 6.283185307179586},
    10: {"semi_tangential": 7.269274206916713, "axial_greenhill": 8.915066887262116},
}


def onset_pinned(n, Tn, kt_deg, gj=10.0, L=10.0, ei=1.0, ea=1.0e5, rel_tol=2e-7):
    """Bending-free ends (x/y bending stiffness 0) with a FINITE twisting spring kt_deg
    [kN.m/deg] -- the only torsionally restrained 'pinned' end OrcaFlex accepts with torsion on.
    Onset by bisection on the modal stability flag, in applied torque M (gamma_B is set from the
    series compliance L/GJ + 2/kt)."""
    T = Tn * ei / L**2
    m, line = straight_model("b", L, n, ei, gj, ea, sep_extra=T * L / ea)
    for ab in "AB":
        setv("b", line, f"End{ab}xBendingStiffness", 0.0)
        setv("b", line, f"End{ab}TwistingStiffness", kt_deg)
    comp = L / gj + 2.0 / math.degrees(kt_deg)  # kt_deg * 180/pi = kN.m/rad
    t0 = time.time()

    def at(Mk):
        set_gamma_continued(m, line, "B", math.degrees(Mk * comp), step=30.0)
        st, _ = lowest_period(line)
        return st, rg(line, "Torque")[1][n // 2]

    lo, hi, Mk = 0.3 * ei / L, None, 0.3 * ei / L
    while hi is None:
        Mk += 0.1 * ei / L
        st, _ = at(Mk)
        if st:
            lo = Mk
        else:
            hi = Mk
        if Mk > 2.0 * PINNED_REF[Tn]["axial_greenhill"] * ei / L:
            raise RuntimeError("no instability found")
    while hi - lo > rel_tol * hi:
        mid = 0.5 * (lo + hi)
        st, _ = at(mid)
        if st:
            lo = mid
        else:
            hi = mid
    _, Mt = at(lo)
    ref = PINNED_REF[Tn]
    return {
        "segments": n,
        "TL2_over_EI": Tn,
        "twisting_stiffness_kNm_per_deg": kt_deg,
        "M_onset_kNm": Mt,
        "M_onset_L_over_EI": Mt * L / ei,
        "rel_err_vs_semi_tangential": Mt * L / ei / ref["semi_tangential"] - 1,
        "rel_err_vs_axial_greenhill": Mt * L / ei / ref["axial_greenhill"] - 1,
        "seconds": round(time.time() - t0, 1),
    }


def _quad_root(pts):
    """Root of the quadratic through 3 points (x, y) nearest the last x."""
    (x0, y0), (x1, y1), (x2, y2) = pts
    d01 = (y1 - y0) / (x1 - x0)
    d12 = (y2 - y1) / (x2 - x1)
    a = (d12 - d01) / (x2 - x0)
    b = d12 - a * (x1 + x2)  # y = a x^2 + b x + c
    c = y2 - a * x2 * x2 - b * x2
    if abs(a) < 1e-300:
        return -c / b
    disc = b * b - 4 * a * c
    r = [(-b + s * math.sqrt(max(disc, 0.0))) / (2 * a) for s in (1, -1)]
    return min(r, key=lambda z: abs(z - x2))


def _richardson(rows):
    """Observed order and extrapolation from the three finest meshes (h ~ 1/n)."""
    r = sorted(rows, key=lambda q: q["segments"])[-3:]
    f1, f2, f3 = (q["M_onset_kNm"] for q in r)
    ratio = r[1]["segments"] / r[0]["segments"]
    if (f2 - f3) == 0 or (f1 - f2) / (f2 - f3) <= 0:
        return {"order": None, "extrapolated_kNm": f3}
    p = math.log((f1 - f2) / (f2 - f3)) / math.log(ratio)
    ext = f3 + (f3 - f2) / (ratio**p - 1)
    return {"order": p, "extrapolated_kNm": ext, "from_segments": [q["segments"] for q in r]}


def case_b():
    out = {
        "L_m": 10.0,
        "EI_kNm2": 1.0,
        "EA_kN": 1.0e5,
        "detector": "bisection on OrcaFlex full modal analysis stability flag ('static position "
        "is an unstable equilibrium'); cross-check by quadratic extrapolation of "
        "the lowest f^2 from 97/98/99 % of onset",
        "no_imperfection": "straight line; OrcaFlex statics stays on the straight branch past "
        "onset, so stability is read from the modal analysis",
        "tensions": {},
    }
    plan = {0: (25, 50, 100, 200), 10: (25, 50, 100, 200, 400), 50: (25, 50, 100, 200), 200: (25, 50, 100, 200)}
    for Tn, meshes in plan.items():
        rows = []
        for n in meshes:
            r = onset_one(n, Tn)
            rows.append(r)
            print("case b", Tn, r, flush=True)
        rich = _richardson(rows)
        Mext = rich["extrapolated_kNm"]
        rich["rel_err_vs_eq33"] = Mext / rows[-1]["eq33_at_measured_T_kNm"] - 1
        out["tensions"][f"TL2_over_EI={Tn}"] = {"GJ_kNm2": 10.0, "rows": rows, "richardson": rich}
    # bending-free ends with a finite twisting spring: which pinned-end torque does OrcaFlex apply?
    pin = {
        "note": "End x/y bending stiffness 0, twisting stiffness finite (kN.m/deg); OrcaFlex "
        "rejects bending-free + torsionally rigid when torsion is included",
        "closed_forms_M_L_over_EI": PINNED_REF,
        "tensions": {},
    }
    for Tn in (0, 10):
        rows = [onset_pinned(n, Tn, 1.0e4) for n in (50, 100, 200)]
        for r in rows:
            print("case b pinned", r, flush=True)
        rich = _richardson(rows)
        rich["rel_err_vs_semi_tangential"] = rich["extrapolated_kNm"] * 10.0 / PINNED_REF[Tn]["semi_tangential"] - 1
        pin["tensions"][f"TL2_over_EI={Tn}"] = {"rows": rows, "richardson": rich}
    r = onset_pinned(100, 0, 1.0e2)
    print("case b pinned kt=1e2", r, flush=True)
    pin["spring_independence_T0_n100_kt=1e2"] = r
    out["pinned_bendfree_finite_twist"] = pin
    # GJ independence: GJ = EI = 1 (onset twist 10.4 rad, needs multi-turn continuation)
    r = onset_one(100, 10, gj=1.0)
    out["GJ_independence_TL2_over_EI=10_GJ=1_n100"] = r
    print("case b GJ=1", r, flush=True)
    return out


# ------------------------------------------------------------------------------------------
def lazy_wave(seg):
    case = "c"
    depth, ho, anc = 80.0, (5.0, -14.0), (125.0, -80.0)
    sections = [("bare", 68.114), ("buoy", 50.0), ("bare", 52.101)]  # hang-off -> anchor
    gj = 50.0  # kN.m^2, ILLUSTRATIVE
    m = new_model(case, depth)
    line_type(case, m, "bare", 0.16, 36.7e-3, 4.69e5, 19.9, gj)
    line_type(case, m, "buoy", 0.29, 59.53e-3, 4.69e5, 19.9, gj)
    line = m.CreateObject(ofx.ObjectType.Line, "cable")
    secs = list(reversed(sections))  # End A = anchor, End B = hang-off
    setv(case, line, "NumberOfSections", len(secs))
    setv(case, line, "LineType", [s[0] for s in secs])
    setv(case, line, "Length", [s[1] for s in secs])
    setv(case, line, "TargetSegmentLength", [seg] * len(secs))
    setv(case, line, "StaticsStep1", "Catenary")
    setv(case, line, "StaticsStep2", "Full statics")
    # pass 1: no torsion, default pinned ends (bending stiffness 0) -> natural end orientations
    setv(case, line, "IncludeTorsion", "No")
    setv(case, line, "EndAConnection", "Fixed")
    setv(case, line, "EndBConnection", "Fixed")
    for ab, xyz in (("A", anc), ("B", ho)):
        setv(case, line, f"End{ab}X", xyz[0])
        setv(case, line, f"End{ab}Y", 0.0)
        setv(case, line, f"End{ab}Z", xyz[1])
    m.CalculateStatics()
    pass1 = {
        "tension_hangoff_kN": line.StaticResult("Effective tension", ofx.oeEndB),
        "max_curvature_per_m": max(rg(line, "Curvature")[1]),
    }
    m.UseStaticLineEndOrientations()
    orient = {ab: {k: getattr(line, f"End{ab}{k}") for k in ("Azimuth", "Declination", "Gamma")} for ab in "AB"}
    # pass 2: torsion on, both ends encastre at the untwisted static orientation
    setv(case, line, "IncludeTorsion", "Yes")
    for ab in "AB":
        setv(case, line, f"End{ab}xBendingStiffness", inf())
        setv(case, line, f"End{ab}TwistingStiffness", inf())
    Ltot = sum(s[1] for s in secs)
    rows = []
    for k in range(0, 21):
        turns = 0.25 * k
        target = orient["B"]["Gamma"] + 360.0 * turns
        try:
            set_gamma_continued(m, line, "B", target, step=90.0)
        except Exception as exc:  # noqa: BLE001
            rows.append({"turns_at_hangoff": turns, "statics_ok": False, "msg": str(exc)[:300]})
            print("case c", seg, rows[-1], flush=True)
            break
        s, tq = rg(line, "Torque")
        _, tw = rg(line, "Twist")
        _, kk = rg(line, "Curvature")
        _, yy = rg(line, "Y")
        _, zz = rg(line, "Z")
        _, te = rg(line, "Effective tension")
        MB = line.StaticResult("Torque", ofx.oeEndB)
        phi = math.radians(360.0 * turns)
        lo, hi = 0.03 * Ltot, 0.97 * Ltot
        kin = [abs(kk[i]) for i in range(len(kk)) if lo <= s[i] <= hi]
        ipk = max(range(len(kk)), key=lambda i: abs(kk[i]))
        row = {
            "turns_at_hangoff": turns,
            "statics_ok": True,
            "torque_hangoff_kNm": MB,
            "torque_anchor_kNm": line.StaticResult("Torque", ofx.oeEndA),
            "torque_min_kNm": min(tq),
            "torque_max_kNm": max(tq),
            "twist_rate_deg_per_m_min": min(tw),
            "twist_rate_deg_per_m_max": max(tw),
            "GJ_Phi_over_L_kNm": gj * phi / Ltot,
            "geometric_twist_turns": (phi - MB * Ltot / gj) / (2 * math.pi),
            "eff_tension_hangoff_kN": line.StaticResult("Effective tension", ofx.oeEndB),
            "eff_tension_anchor_kN": line.StaticResult("Effective tension", ofx.oeEndA),
            "eff_tension_min_kN": min(te),
            "max_curvature_per_m": abs(kk[ipk]),
            "arc_of_max_curvature_m": s[ipk],
            "max_curvature_interior_per_m": max(kin),
            "max_abs_Y_m": max(abs(v) for v in yy),
            "min_Z_m": min(zz),
            "bend_moment_hangoff_kNm": line.StaticResult("Bend moment", ofx.oeEndB),
            "bend_moment_anchor_kNm": line.StaticResult("Bend moment", ofx.oeEndA),
        }
        rows.append(row)
        print("case c", seg, row, flush=True)
    return {
        "segment_m": seg,
        "pass1_no_torsion_pinned": pass1,
        "untwisted_end_orientation_deg": orient,
        "line_length_m": Ltot,
        "rows": rows,
    }


def case_c():
    res = {
        "site": "Lozon et al. (2025) GoMex 80 m (geometry as CableDyn validation/scripts/orcaflex_lozon_cables.py)",
        "GJ_kNm2_illustrative": 50.0,
        "EI_kNm2": 19.9,
        "seabed_friction": 0.0,
        "end_A": "anchor (125, 0, -80)",
        "end_B": "hang-off (5, 0, -14)",
        "meshes": {},
    }
    for seg in (0.75, 0.375):
        res["meshes"][str(seg)] = lazy_wave(seg)
    a, b = (res["meshes"][k]["rows"] for k in ("0.75", "0.375"))
    conv = []
    for ra, rb in zip(a, b):
        if ra.get("statics_ok") and rb.get("statics_ok"):
            conv.append(
                {
                    "turns": ra["turns_at_hangoff"],
                    "torque_rel_diff": (ra["torque_hangoff_kNm"] - rb["torque_hangoff_kNm"])
                    / (abs(rb["torque_hangoff_kNm"]) + 1e-30),
                    "peak_curv_rel_diff": ra["max_curvature_interior_per_m"] / rb["max_curvature_interior_per_m"] - 1,
                }
            )
    res["mesh_0.75_vs_0.375"] = conv
    return res


def _load_orcaflex() -> None:
    """Import OrcFxAPI as the module-level ofx (needed only to run OrcaFlex)."""
    global ofx
    if ofx is None:
        import OrcFxAPI

        ofx = OrcFxAPI


def run(cases: list[str], out_dir: str) -> str:
    """Run the OrcaFlex cases and write (update) the JSON summary; return its path."""
    _load_orcaflex()
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, SUMMARY_NAME)
    with open(os.path.abspath(__file__), "rb") as fh:
        sha = hashlib.sha256(fh.read()).hexdigest()
    summary: dict = {}
    if os.path.exists(out):  # keep cases not rerun in this invocation
        with open(out, encoding="utf-8") as fh:
            summary = json.load(fh)
    summary.update(
        {
            "OrcaFlex_version": ofx.DLLVersion(),
            "script": os.path.basename(__file__),
            "script_sha256": sha,
            "units": "m, te, kN, s; torque kN.m",
            "statics": f"Line IncludeTorsion=Yes, StaticsStep1=Catenary, StaticsStep2=Full "
            f"statics; General StaticsTolerance={STATICS_TOL}, "
            f"StaticsMaxIterations={STATICS_MAXIT}",
            "density_te_m3": RHO_W,
        }
    )
    for c in cases:
        SETTINGS.clear()
        t0 = time.time()
        try:
            summary["case_" + c] = {"a": case_a, "b": case_b, "c": case_c}[c]()
        except Exception:  # noqa: BLE001
            summary["case_" + c] = {"error": traceback.format_exc()}
            print(summary["case_" + c]["error"], flush=True)
        summary["case_" + c]["settings_set_and_read_back"] = dict(SETTINGS)
        summary["case_" + c]["script_sha256"] = sha
        summary["case_" + c]["wall_seconds"] = round(time.time() - t0, 1)
        with open(out, "w", encoding="utf-8") as fh:
            json.dump(summary, fh, indent=1)
    print("wrote", out)
    return out


def write_refs(summary_path: str, refs_path: str) -> None:
    """The compact SI reference table of tests/test_torsion_orcaflex.f90 from a JSON summary."""
    with open(summary_path, encoding="utf-8") as fh:
        s = json.load(fh)
    a, b, c = s["case_a"], s["case_b"], s["case_c"]
    lines = [
        "# OrcaFlex torsion reference values (summary values only) for tests/test_torsion_orcaflex.f90.",
        f"# OrcaFlex {s['OrcaFlex_version']} through OrcFxAPI; written by",
        "# validation/scripts/orcaflex_torsion_reference.py --refs from its JSON summary",
        f"# (script SHA-256 {s['script_sha256'][:16]}...). Line IncludeTorsion Yes, statics Catenary then",
        f"# Full statics; StaticsTolerance {STATICS_TOL['a']:g} (pure), {STATICS_TOL['b']:g} (onsets, lazy wave);",
        f"# StaticsMaxIterations {STATICS_MAXIT}; TensionTorqueCoupling 0; seabed friction 0.",
        "# Units SI (N, m, N.m); OrcaFlex kN and kN.m are converted. See VALIDATION.md (torsion).",
        "#",
        f"# pure: straight neutrally buoyant line, L {a['L_m']} m, {a['segments']} segments, EI {a['EI_kNm2']} kN.m^2,",
        f"#   GJ {a['GJ_kNm2']} kN.m^2, both ends encastre; gamma reached by continuation.",
        "# tag  gamma_A_deg  gamma_B_deg  torque_N.m",
    ]
    for r in a["continuation_rows"]:
        lines.append(
            f"pure  {r['gamma_A_deg']:.1f}  {r['gamma_B_deg']:.1f}  "
            f"{1e3 * 0.5 * (r['torque_min_kNm'] + r['torque_max_kNm']):.12e}"
        )
    lines.append(f"pure  30.0  120.0  {1e3 * a['gammaA30_gammaB120']['torque_kNm']:.12e}")
    ser = a["series_two_sections"]
    lines += [
        "# series: GJ 10 kN.m^2 over 4 m then 25 kN.m^2 over 6 m, gamma_B 90 deg",
        "# tag  torque_N.m",
        f"series  {1e3 * 0.5 * (ser['torque_min_kNm'] + ser['torque_max_kNm']):.12e}",
    ]
    lines += [
        "# clamped: Greenhill onset of the clamped-clamped line (case b, L 10 m, EI 1 kN.m^2), M_cr L/EI:",
        "#   OrcaFlex at 200 segments and the Richardson extrapolation of its three finest meshes",
        "# tag  T_L^2/EI  n200  extrapolated",
    ]
    for key, v in b["tensions"].items():
        tn = float(key.split("=")[1])
        n200 = [r for r in v["rows"] if r["segments"] == 200][0]["M_onset_L_over_EI"]
        lines.append(f"clamped  {tn:.1f}  {n200:.10f}  {10.0 * v['richardson']['extrapolated_kNm']:.10f}")
    pin = b["pinned_bendfree_finite_twist"]
    lines += [
        "# pinned: bending-free ends with a finite twisting spring (1e4 kN.m/deg), M_cr L/EI as above",
        "# tag  T_L^2/EI  n200  extrapolated",
    ]
    for key, v in pin["tensions"].items():
        tn = float(key.split("=")[1])
        n200 = [r for r in v["rows"] if r["segments"] == 200][0]["M_onset_L_over_EI"]
        lines.append(f"pinned  {tn:.1f}  {n200:.10f}  {10.0 * v['richardson']['extrapolated_kNm']:.10f}")
    m = c["meshes"]["0.375"]
    orient = m["untwisted_end_orientation_deg"]
    lines += [
        f"# lazywave: {c['site']}, GJ {c['GJ_kNm2_illustrative']} kN.m^2 (illustrative),",
        "#   anchor End A, hang-off End B, segment 0.375 m, both ends encastre at the untwisted static",
        "#   orientation; the declinations (deg) of that orientation at the anchor and the hang-off:",
        f"orientation  {orient['A']['Declination']:.10f}  {orient['B']['Declination']:.10f}",
        "# tag  turns  torque_hangoff_N.m  geometric_twist_turns  peak_interior_curvature_1/m  max_abs_Y_m"
        "  T_hangoff_N",
    ]
    for r in m["rows"]:
        if not r.get("statics_ok") or abs(r["turns_at_hangoff"] - round(r["turns_at_hangoff"])) > 1e-9:
            continue
        lines.append(
            f"lazywave  {r['turns_at_hangoff']:.1f}  {1e3 * r['torque_hangoff_kNm']:.9e}  "
            f"{r['geometric_twist_turns']:.9e}  {r['max_curvature_interior_per_m']:.9e}  "
            f"{r['max_abs_Y_m']:.9e}  {1e3 * r['eff_tension_hangoff_kN']:.9e}"
        )
    with open(refs_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")
    print("wrote", refs_path)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("cases", nargs="*", help="cases to run: a, b and/or c (default: all)")
    parser.add_argument(
        "--out", default=os.path.join(REPO, "build", "validation"), help="directory of the JSON summary"
    )
    parser.add_argument("--refs", help="write the compact reference table to this path")
    parser.add_argument("--summary", help="write --refs from this existing JSON summary instead of running OrcaFlex")
    args = parser.parse_args()
    if any(c not in ("a", "b", "c") for c in args.cases):
        parser.error("cases are a, b and c")
    summary = args.summary
    if summary is None:
        summary = run(args.cases or ["a", "b", "c"], args.out)
    if args.refs:
        write_refs(summary, args.refs)


if __name__ == "__main__":
    main()
