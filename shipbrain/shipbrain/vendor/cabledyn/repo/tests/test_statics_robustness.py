#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
"""Static-initialization robustness matrix for tension-only (EI=0) mooring lines.

A deterministic sample of the regimes a mooring designer meets -- grounded catenary, semi-taut,
taut, fully suspended, multi-section composite, nearly taut, slack (the H -> 0 limit), vertical,
anchors just off the seabed, sloped seabed, gridded seabeds with a trench or 2D roughness (their
creases rounded as in the solver), fine meshes, soft seabed, steady current, one- and two-segment
lines, and Free/Connect points -- is written as cabledyn decks and solved by the production
executable. Every case must converge with no compressed element and an independent nodal force
balance (tensions, lumped weight, penalty seabed along the local normal, or in a rounded crease
the gradient of its penalty potential, Morison drag); a trench deep enough to hold the excess
length slack at its bottom must show it, with the anchor tension of the run rising from there. Cases with a continuous elastic-catenary solution also match it (element tensions and the
line-end forces FairTen/AnchTen); a subset is run through both the static-only and the dynamic
(TMax = 0) route, which must report the same end tensions; an anchor genuinely below the seabed
must be rejected with a clear message.

usage: test_statics_robustness.py --exe <cabledyn> --output <work dir>
"""
from __future__ import annotations

import argparse
import math
import os
import random
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

import numpy as np
from scipy.optimize import brentq, least_squares

G, RHO = 9.80665, 1025.0
TEN_TOL = 0.03          # element / end tension against the continuous catenary
BALANCE_TOL = 1.0e-2    # nodal force residual / nodal load (8-digit text output)
FAILURES: list[str] = []


def check(cond, msg):
    if not cond:
        FAILURES.append(msg)
        print("MISMATCH:", msg)


# ------------------------------------------------------------------ materials
def material(kind, dn):
    """(hydro diameter, mass per length, EA, Cdn, Cdt) for a nominal diameter dn [m]."""
    return {"chain": (1.8 * dn, 19.9e3 * dn ** 2, 0.854e11 * dn ** 2, 1.37, 0.64),
            "wire": (dn, 5.0e3 * dn ** 2, 9.0e10 * dn ** 2, 1.2, 0.008),
            "polyester": (0.86 * dn, 0.7979e3 * dn ** 2, 5.0e9 * dn ** 2, 1.2, 0.008),
            "nylon": (0.85 * dn, 0.6476e3 * dn ** 2, 5.0e8 * dn ** 2, 1.2, 0.008)}[kind]


def line_type(name, kind, dn):
    d, m, ea, cdn, cdt = material(kind, dn)
    return dict(name=name, d=d, m=m, ea=ea, cdn=cdn, cdt=cdt, w=(m - RHO * math.pi / 4 * d * d) * G)


# ------------------------------------------------------------------ elastic catenary oracle
def _piece(H, V0, ln, w, EA):
    V1 = V0 + w * ln
    if abs(w) * ln < 1e-12 * max(H, 1.0):
        T = math.hypot(H, V0)
        return H / T * ln + H * ln / EA, V0 / T * ln + V0 * ln / EA, V1
    dx = H / w * (math.asinh(V1 / H) - math.asinh(V0 / H)) + H * ln / EA
    dz = H / w * (math.sqrt(1 + (V1 / H) ** 2) - math.sqrt(1 + (V0 / H) ** 2)) + ln * (V0 + V1) / (2 * EA)
    return dx, dz, V1


def profile(H, u, pieces, seabed, slope=0.0, sample=()):
    """Integrate from the anchor; u >= 0 grounded length (frictionless planar seabed of angle
    slope, rising toward the fairlead), u < 0 anchor uplift -u*w0 (or, without seabed, V_A = u)."""
    if seabed:
        lg, va = max(u, 0.0), -min(u, 0.0) * pieces[0][1]
    else:
        lg, va = 0.0, u
    ct, st = math.cos(slope), math.sin(slope)
    x = z = s = 0.0
    out, si, samp = [], 0, list(sample)
    tg, hs, v = H, H, va
    grounded = lg > 0
    if grounded:
        hs, v = H * ct, H * st
    for ln, w, ea in pieces:
        pos = 0.0
        while pos < ln - 1e-12:
            if grounded and s < lg:
                g = min(ln - pos, lg - s)
                while si < len(samp) and samp[si] <= s + g + 1e-9:
                    d = samp[si] - s
                    out.append(tg + w * st * d)
                    si += 1
                e = (tg * g + 0.5 * w * st * g * g) / ea
                x += (g + e) * ct
                z += (g + e) * st
                tg += w * st * g
                s += g
                pos += g
                if s >= lg - 1e-12:
                    hs, v, grounded = tg * ct, tg * st, False
            else:
                g = ln - pos
                while si < len(samp) and samp[si] <= s + g + 1e-9:
                    out.append(math.hypot(hs, _piece(hs, v, samp[si] - s, w, ea)[2]))
                    si += 1
                dx, dz, v = _piece(hs, v, g, w, ea)
                x, z, s, pos = x + dx, z + dz, s + g, pos + g
    return x, z, hs, v, out


def design(pieces, h, u, seabed=True, slope=0.0):
    """Horizontal tension and span for a profile rising h with grounded/uplift parameter u."""
    L = sum(p[0] for p in pieces)
    wbar = sum(p[0] * p[1] for p in pieces) / L

    def f(lh):
        return profile(math.exp(lh), u, pieces, seabed, slope)[1] - h
    grid = np.linspace(math.log(wbar * L * 1e-5), math.log(wbar * L * 1e5), 121)
    vals = []
    for g in grid:
        try:
            vals.append(f(g))
        except (OverflowError, ValueError, ZeroDivisionError):
            vals.append(float("nan"))
    for i in range(len(grid) - 1):
        if np.isfinite(vals[i]) and np.isfinite(vals[i + 1]) and vals[i] * vals[i + 1] < 0:
            H = math.exp(brentq(f, grid[i], grid[i + 1], xtol=1e-14))
            return H, profile(H, u, pieces, seabed, slope)[0]
    return None


def solve_oracle(pieces, X, Z, seabed, slope=0.0, guess=None):
    L = sum(p[0] for p in pieces)
    wbar = sum(p[0] * p[1] for p in pieces) / L
    if guess is not None:
        # the design point that generated the case, polished to this geometry
        def Fg(p):
            x, z, *_ = profile(math.exp(p[0]), p[1], pieces, seabed, slope)
            return [(x - X) / L, (z - Z) / L]
        r = least_squares(Fg, (math.log(guess[0]), guess[1]), xtol=1e-15, ftol=1e-15, gtol=1e-15, max_nfev=400)
        if max(abs(v) for v in r.fun) < 1e-10:
            return math.exp(r.x[0]), r.x[1]

    def F(p):
        x, z, *_ = profile(math.exp(p[0]), p[1], pieces, seabed, slope)
        return [(x - X) / L, (z - Z) / L]
    for hs in [wbar * L * f for f in (0.01, 0.05, 0.2, 0.5, 1.0, 3.0, 10.0, 50.0, 300.0, 3000.0)]:
        for u in ((0.0, 0.3 * L, 0.6 * L, 0.75 * L, 0.9 * L, -0.2 * L, -1.0 * L) if seabed
                  else (-wbar * L, 0.0, wbar * L)):
            try:
                r = least_squares(F, (math.log(hs), u), xtol=1e-15, ftol=1e-15, gtol=1e-15, max_nfev=400)
            except (OverflowError, ValueError, ZeroDivisionError):
                continue
            if max(abs(v) for v in r.fun) < 1e-10 and not (seabed and r.x[1] > L):
                return math.exp(r.x[0]), r.x[1]
    return None


# ------------------------------------------------------------------ decks
def fmt(v):
    return "%.10e" % v


def write_deck(path, types, points, lines, opts, outputs, bathy=None):
    L = ["--------------------- CableDyn Input File ---", "statics robustness case",
         "--------------------- LINE TYPES ---",
         "TypeName Diam MassDenInAir EA BA/-zeta EI Cd_n Cd_t Ca_n Ca_t",
         "(-) (m) (kg/m) (N) (-) (Nm2) (-) (-) (-) (-)"]
    for t in types:
        L.append(" ".join([t["name"], fmt(t["d"]), fmt(t["m"]), fmt(t["ea"]), "-1.0", "0.0", fmt(t["cdn"]),
                           fmt(t["cdt"]), "1.0", "0.0"]))
    L += ["--------------------- POINTS ---", "ID Type X Y Z Mass Vol CdA Ca", "(-) (-) (m) (m) (m) (kg) (m3) (m2) (-)"]
    for p in points:
        L.append(" ".join([str(p["id"]), p["type"]] + [fmt(v) for v in p["x"]] +
                          [fmt(p.get("mass", 0.0)), fmt(p.get("vol", 0.0)), "0.0", "0.0"]))
    L += ["--------------------- LINES ---", "ID NodeA NodeB Outputs", "(-) (-) (-) (-)"]
    for ln in lines:
        L.append("%d %d %d pt" % (ln["id"], ln["A"], ln["B"]))
    L += ["--------------------- SECTIONS ---", "LineID LineType Length NumSegs", "(-) (-) (m) (-)"]
    for ln in lines:
        for tn, length, n in ln["sections"]:
            L.append("%d %s %s %d" % (ln["id"], tn, fmt(length), n))
    L += ["--------------------- OPTIONS ---", "9.80665 g", "1025.0 rhoW"] + list(opts)
    L += ["--------------------- OUTPUTS ---"] + ['"%s"' % o for o in outputs]
    L += ["--------------------- need this line ---"]
    with open(path, "w", newline="\n") as f:
        f.write("\n".join(L) + "\n")
    if bathy is not None:
        with open(os.path.join(os.path.dirname(path), "bathy_%s.txt" % os.path.basename(path)[:-4]), "w") as f:
            for x, y, z in bathy:
                f.write("%r %r %r\n" % (x, y, z))


def read_row(path):
    rows = [ln for ln in open(path).read().splitlines() if ln.strip() and not ln.startswith("#")]
    hdr = rows[0].split()
    return dict(zip(hdr, [float(v) for v in rows[1].split()]))


def read_nodes(path):
    rows = [ln for ln in open(path).read().splitlines() if ln.strip() and not ln.startswith("#")]
    if rows[0].startswith("Node"):
        return np.array([[float(v) for v in r.split()[1:4]] for r in rows[1:]])
    return np.array([float(v) for v in rows[1].split()[1:]]).reshape(-1, 3)


def read_tensions(path):
    rows = [ln for ln in open(path).read().splitlines() if ln.strip() and not ln.startswith("#")]
    if rows[0].startswith("Segment"):
        return np.array([float(r.split()[1]) for r in rows[1:]])
    return np.array([float(v) for v in rows[1].split()[1:]])


# ------------------------------------------------------------------ independent force balance
def nodal_balance(case, root):
    """Largest interior nodal force residual / largest nodal load, End A -> End B output order."""
    worst = 0.0
    for ln in case["lines"]:
        P = read_nodes(os.path.join(case["dir"], "%s.Line%d.p.out" % (root, ln["id"])))
        T = np.maximum(read_tensions(os.path.join(case["dir"], "%s.Line%d.t.out" % (root, ln["id"]))), 0.0)
        segs = []
        for tn, length, n in ln["sections"]:
            segs += [(case["types"][tn], length / n)] * n
        F = np.zeros_like(P)
        load = 0.0
        kn = np.zeros(len(P))
        for e, ((t, l0), te) in enumerate(zip(segs, T)):
            u = (P[e + 1] - P[e]) / np.linalg.norm(P[e + 1] - P[e])
            F[e] += te * u
            F[e + 1] -= te * u
            F[e, 2] -= 0.5 * t["w"] * l0
            F[e + 1, 2] -= 0.5 * t["w"] * l0
            load = max(load, abs(t["w"]) * l0)
            kn[e] += 0.5 * case.get("kbot", 0.0) * t["d"] * l0
            kn[e + 1] += 0.5 * case.get("kbot", 0.0) * t["d"] * l0
        if "floor" in case:
            for i in range(len(P)):
                zf, gx, gy = case["floor"](P[i, 0], P[i, 1])
                s = math.sqrt(1 + gx * gx + gy * gy)
                pen = (zf - P[i, 2]) / s
                if pen > 0:
                    hess = case["floor_hess"](P[i, 0], P[i, 1]) if "floor_hess" in case else None
                    if hess is None:
                        F[i] += kn[i] * pen * np.array([-gx, -gy, 1.0]) / s
                    else:
                        # in a rounded crease: the gradient of the penalty potential of the
                        # normal penetration g = (zf - z)/s, force = -k g dg/dq
                        fxx, fxy, fyy = hess
                        ds = np.array([gx * fxx + gy * fxy, gx * fxy + gy * fyy, 0.0]) / s
                        dg = np.array([gx, gy, -1.0]) / s - (zf - P[i, 2]) * ds / s**2
                        F[i] -= kn[i] * pen * dg
        if "current" in case:
            # a depth profile is sampled at each node's own elevation (as the dynamics do)
            vel = [case["current"](z) for z in P[:, 2]]
            for e, (t, l0) in enumerate(segs):
                u = (P[e + 1] - P[e]) / np.linalg.norm(P[e + 1] - P[e])
                rel = 0.5 * (vel[e] + vel[e + 1])
                a = rel @ u
                nrm = rel - a * u
                f = 0.5 * l0 * (0.5 * RHO * t["d"] * t["cdn"] * np.linalg.norm(nrm) * nrm +
                                0.5 * RHO * math.pi * t["d"] * t["cdt"] * abs(a) * a * u)
                F[e] += f
                F[e + 1] += f
        if n_int := len(P) - 2:
            res = np.linalg.norm(F[1:-1], axis=1).max()
            lmin = min(l0 for _, l0 in segs)
            floor = 4.0 * T.max() * 1e-7 * np.abs(P).max() / lmin + 1e-6 * T.max() + 4.0 * kn.max() * 1e-7 * \
                np.abs(P).max()
            worst = max(worst, res / (load + 100.0 * floor)) if n_int > 0 else worst
    return worst


# ------------------------------------------------------------------ rounded bathymetry
class RoundedGrid:
    """The solver's seabed of a structured grid, written independently in basis form.

    z(x, y) = sum_ij z_ij phi_i(x) psi_j(y), with phi_i the hat functions of the x grid whose
    kinks at the interior grid lines are rounded by the cubic fillet J (d - |u|)^3 / (6 d^2)
    (J the slope jump of the hat there, d = 5 % of the smaller spacing next to the line);
    likewise psi_j. Gradient and curvature by central differences of z. Data creases that
    would move the surface by less than 1 micrometre are not rounded in the solver; the
    grids used here have none.
    """

    def __init__(self, xs, ys, z):
        self.xs, self.ys, self.z = np.asarray(xs, float), np.asarray(ys, float), np.asarray(z, float)

    @staticmethod
    def _basis(axis, q):
        n = axis.size
        q = min(max(q, axis[0]), axis[-1])
        phi = np.zeros(n)
        i = min(max(int(np.searchsorted(axis, q, side="right")) - 1, 0), n - 2)
        t = (q - axis[i]) / (axis[i + 1] - axis[i])
        phi[i], phi[i + 1] = 1.0 - t, t
        for k in range(1, n - 1):
            d = 0.05 * min(axis[k] - axis[k - 1], axis[k + 1] - axis[k])
            u = abs(q - axis[k])
            if u >= d:
                continue
            h = (d - u) ** 3 / (6.0 * d * d)
            # slope jumps of the hats at line k: hat k-1, k and k+1
            phi[k - 1] += h * (1.0 / (axis[k] - axis[k - 1]))
            phi[k] += h * (-1.0 / (axis[k] - axis[k - 1]) - 1.0 / (axis[k + 1] - axis[k]))
            phi[k + 1] += h * (1.0 / (axis[k + 1] - axis[k]))
        return phi

    def height(self, x, y):
        return float(self._basis(self.xs, x) @ self.z @ self._basis(self.ys, y))

    def floor(self, x, y, h=1.0e-5):
        gx = (self.height(x + h, y) - self.height(x - h, y)) / (2 * h)
        gy = (self.height(x, y + h) - self.height(x, y - h)) / (2 * h)
        return self.height(x, y), gx, gy

    def hess(self, x, y, h=1.0e-4):
        z0 = self.height(x, y)
        fxx = (self.height(x + h, y) - 2 * z0 + self.height(x - h, y)) / h**2
        fyy = (self.height(x, y + h) - 2 * z0 + self.height(x, y - h)) / h**2
        fxy = (self.height(x + h, y + h) - self.height(x + h, y - h) - self.height(x - h, y + h)
               + self.height(x - h, y - h)) / (4 * h * h)
        # a bilinear cell has no z_xx or z_yy: the contact there is the normal force
        return (fxx, fxy, fyy) if abs(fxx) > 1e-3 or abs(fyy) > 1e-3 else None

    def rows(self):
        return [(float(x), float(y), float(-self.z[i, j])) for i, x in enumerate(self.xs) for j, y in enumerate(self.ys)]


# ------------------------------------------------------------------ case builders
CASES: list[dict] = []
# The matrix is seeded, so the designs the oracle can close are fixed: a change in the
# oracle, the seed or the case table that drops cases must fail, not shrink the matrix.
EXPECTED_CASES = 74


def single(name, t, L, nseg, fair, anch, depth=None, kbot=1.0e5, extra=(), oracle=True, slope=None,
           current=None, floor=None, bathy=None, expect_reject=False, route_pair=False, fair_ref=None):
    c = dict(name=name, types={t["name"]: t}, lines=[dict(id=1, A=1, B=2, sections=[(t["name"], L, nseg)])],
             points=[dict(id=1, type="Coupled", x=fair), dict(id=2, type="Fixed", x=anch)],
             opts=[], oracle=oracle, expect_reject=expect_reject, route_pair=route_pair, fair_ref=fair_ref)
    if depth is not None:
        c["opts"] += ["%r WtrDpth" % depth, "%r kBot" % kbot, "1.0e4 cBot"]
        c["kbot"] = kbot
        c["floor"] = lambda x, y, d=depth: (-d, 0.0, 0.0)
    if bathy is not None:
        c["opts"] += ["bathy_%s.txt bathymetryFile" % name, "%r kBot" % kbot, "1.0e4 cBot"]
        c["kbot"], c["bathy"], c["floor"] = kbot, bathy, floor
    if current is not None:
        c["opts"] += [current[0]]
        c["current"] = current[1]
    c["opts"] += list(extra)
    c["slope"] = slope
    CASES.append(c)
    return c


def build_cases():
    r = random.Random(20260925)
    chain12, wire10, poly20 = line_type("chain", "chain", 0.12), line_type("wire", "wire", 0.10), \
        line_type("poly", "polyester", 0.20)
    # --- seeded families: catenary, semitaut, taut, suspended ---
    for i in range(30):
        kind = ["chain", "wire", "polyester", "nylon"][i % 4]
        t = line_type("T%d" % i, kind, r.uniform(*{"chain": (0.06, 0.18), "wire": (0.06, 0.16),
                                                   "polyester": (0.10, 0.30), "nylon": (0.10, 0.30)}[kind]))
        depth = math.exp(r.uniform(math.log(20.0), math.log(1500.0)))
        fd = r.uniform(0.0, min(30.0, 0.4 * depth))
        h = depth - fd
        L = h * math.exp(r.uniform(math.log(1.2), math.log(min(6.0, 5000.0 / h))))
        semitaut = i >= 20
        u = -L * r.uniform(0.02, 1.0) if semitaut else r.uniform(0.05, 0.9) * (L - h) * 0.999
        delta = t["w"] / (1.0e5 * t["d"])
        des = design([(L, t["w"], t["ea"])], h + (0.0 if semitaut else delta), u)
        if des is None:
            continue
        az = r.uniform(0, 2 * math.pi)
        nseg = int(math.exp(r.uniform(math.log(20), math.log(200))))
        single("%s_%02d" % ("semitaut" if semitaut else "catenary", i), t, L, nseg, (0.0, 0.0, -fd),
               (des[1] * math.cos(az), des[1] * math.sin(az), -depth), depth=depth, route_pair=(i % 5 == 0))
    for i in range(5):
        t = line_type("T%d" % i, ["polyester", "wire", "chain", "nylon", "polyester"][i], 0.12)
        depth = [60.0, 300.0, 900.0, 150.0, 2000.0][i]
        h = depth - 10.0
        L = h * [1.1, 1.4, 1.8, 1.2, 1.3][i]
        eps = [0.01, 0.002, 0.002, 0.05, 0.02][i]
        u = -max(eps * t["ea"] / t["w"] * 0.5, 0.01 * L)
        des = design([(L, t["w"], t["ea"])], h, u)
        if des is not None:
            single("taut_%02d" % i, t, L, 60, (0.0, 0.0, -10.0), (des[1], 0.0, -depth), depth=depth)
    for i in range(5):
        t = line_type("S%d" % i, ["chain", "wire", "polyester", "chain", "wire"][i], 0.1)
        L = [80.0, 300.0, 700.0, 1500.0, 50.0][i]
        h = [0.0, 0.3, 0.6, 0.2, 0.0][i] * L
        va = [0.5, -0.3, 1.2, 0.0, -0.2][i] * t["w"] * L
        des = design([(L, t["w"], t["ea"])], h, va, seabed=False)
        if des is not None:
            single("suspended_%02d" % i, t, L, 80, (0.0, 0.0, -20.0), (des[1], 0.0, -20.0 - h))
    # --- composites (chain-rope-chain, chain-wire), grounded and semitaut ---
    for i, (kinds, frac, semi) in enumerate([(("chain", "polyester", "chain"), (0.3, 0.5, 0.2), False),
                                             (("chain", "wire"), (0.5, 0.5), False),
                                             (("chain", "polyester"), (0.2, 0.8), True),
                                             (("chain", "nylon", "chain"), (0.4, 0.4, 0.2), True)]):
        types = [line_type("C%d%d" % (i, k), kind, 0.12 if kind != "polyester" else 0.2)
                 for k, kind in enumerate(kinds)]
        depth, fd = [200.0, 80.0, 600.0, 120.0][i], 15.0
        h = depth - fd
        Lt = h * [3.0, 4.0, 1.4, 1.8][i]
        secs = [(t, f * Lt) for t, f in zip(types, frac)]
        pieces = [(ln, t["w"], t["ea"]) for t, ln in secs]
        u = -0.1 * Lt if semi else 0.5 * min(secs[0][1], Lt - h)
        delta = types[0]["w"] / (1.0e5 * types[0]["d"])
        des = design(pieces, h + (0.0 if semi else delta), u)
        if des is None:
            continue
        c = single("composite_%02d" % i, types[-1], Lt, 1, (0.0, 0.0, -fd), (des[1], 0.0, -depth), depth=depth,
                   route_pair=True)
        c["types"] = {t["name"]: t for t in types}
        c["lines"][0]["sections"] = [(t["name"], ln, max(4, int(round(150 * ln / Lt)))) for t, ln in reversed(secs)]
        c["pieces"] = pieces
    # --- nearly taut and slack (H -> 0), vertical, one/two segments ---
    chord = math.hypot(450.0, 90.0)
    for f in (1.001, 1.01):
        single("near_taut_%g" % f, chain12, chord * f, 46, (0.0, 0.0, -10.0), (450.0, 0.0, -100.0), depth=100.0,
               route_pair=True)
    single("slack_h0_10m", chain12, 70.0, 35, (0.0, 0.0, -2.0), (50.0, 0.0, -10.0), depth=10.0, oracle=False,
           fair_ref=chain12["w"] * 8.0)
    single("vertical_slack", chain12, 120.0, 24, (0.0, 0.0, -10.0), (0.0, 0.0, -100.0), depth=100.0, oracle=False,
           fair_ref=chain12["w"] * 90.0)
    single("nseg1_slack", chain12, 520.0, 1, (0.0, 0.0, -10.0), (450.0, 0.0, -100.0), depth=100.0, oracle=False,
           fair_ref=chain12["w"] * 260.0)
    single("nseg2_slack", chain12, 520.0, 2, (0.0, 0.0, -10.0), (450.0, 0.0, -100.0), depth=100.0, oracle=False)
    # --- anchor just off the seabed ---
    for tag, za in (("1mm_below", -100.001), ("1mm_above", -99.999), ("1m_above", -99.0), ("20m_above", -80.0)):
        single("anchor_" + tag, chain12, 520.0, 52, (0.0, 0.0, -10.0), (450.0, 0.0, za), depth=100.0,
               oracle=tag.endswith("mm_below") or tag.endswith("mm_above"))
    single("anchor_30mm_below", chain12, 520.0, 52, (0.0, 0.0, -10.0), (450.0, 0.0, -100.03), depth=100.0,
           oracle=False, expect_reject=True)
    # --- sloped seabed (planar grid; slope rising toward the fairlead) ---
    for deg, nseg in ((-2.0, 104), (-0.5, 104), (0.5, 104), (2.0, 104), (5.0, 104), (7.0, 40)):
        th = math.radians(deg)
        # 350 m grounded of 520 m: a moderate catenary (fairlead tension ~2-3 w h); the 7 deg
        # up-slope case on 40 segments (13 m elements) checks a coarse mesh on a steeper slope
        des = design([(520.0, chain12["w"], chain12["ea"])], 90.0 + chain12["w"] / (1e5 * chain12["d"]),
                     350.0, True, th)
        if des is None:
            continue
        X = des[1]

        def floor(x, y, th=th):
            return -100.0 + math.tan(th) * x, math.tan(th), 0.0
        grid = [(x, y, 100.0 - math.tan(th) * x) for x in (-200.0, X + 50.0) for y in (-300.0, 300.0)]
        # a seabed falling toward the fairlead lifts the line off steeply downhill; its oracle
        # closure is ill-posed there, so those cases rest on the independent force balance
        c = single("slope_%+.1fdeg_n%d" % (deg, nseg), chain12, 520.0, nseg, (X, 0.0, -10.0), (0.0, 0.0, -100.0),
                   bathy=grid, floor=floor, slope=th, oracle=deg > 0.0)
        c["guess"] = (des[0], 350.0)
    # --- a line too long for its span on a seabed falling toward the fairlead: on the
    # frictionless slope the excess slides down past the fairlead and folds back (zero
    # tension at the fold); continental-slope decks at -1.7 .. -7.8 deg ---
    for deg, length, nseg in ((-1.7, 180.0, 90), (-5.2, 330.0, 126), (-7.8, 160.0, 160)):
        th = math.radians(deg)

        def floor(x, y, th=th):
            return -70.0 + math.tan(th) * x, math.tan(th), 0.0
        grid = [(x, y, 70.0 - math.tan(th) * x) for x in (-200.0, 900.0) for y in (-300.0, 300.0)]
        single("slope_fold_%+.1fdeg" % deg, chain12, length, nseg, (97.0, 0.0, -1.0), (0.0, 0.0, -70.0), bathy=grid,
               floor=floor, slope=th, oracle=False)
    # --- a gridded seabed with valleys (the creases of the bilinear grid rounded by the
    # solver): a 30 m Gaussian trench under the touchdown, and in the grounded run, deep
    # enough that the frictionless run's tension T = T0 + w (z - z0) falls to zero inside it
    # and the excess length rests slack at the bottom (the anchor tension is then w times the
    # trench depth below the anchor); and a +-0.5 m random seabed on a 10 m grid in both
    # directions, whose valleys the frictionless grounded run slides sideways into ---
    xs = [-100.0 + 5.0 * k for k in range(141)]
    for tag, xc, n_seg in (("touchdown", 200.0, 104), ("grounded_run", 350.0, 104)):
        trench = RoundedGrid(xs, [-100.0, 100.0],
                             [[-100.0 - 30.0 * math.exp(-((x - xc) / 40.0) ** 2)] * 2 for x in xs])
        za = trench.height(450.0, 0.0)
        c = single("trench_%s_pile" % tag, chain12, 520.0, n_seg, (0.0, 0.0, -10.0), (450.0, 0.0, za),
                   bathy=trench.rows(), floor=trench.floor, oracle=False)
        c["floor_hess"] = trench.hess
        c["pile_dz"] = za - trench.height(xc, 0.0)
    rr = random.Random(20261015)
    xs = [-100.0 + 10.0 * k for k in range(71)]
    ys = [-100.0 + 10.0 * k for k in range(21)]
    rough = RoundedGrid(xs, ys, [[-100.0 if x == 450.0 else -100.0 + rr.uniform(-0.5, 0.5) for _ in ys] for x in xs])
    c = single("rough2d_seabed", chain12, 520.0, 104, (0.0, 0.0, -10.0), (450.0, 0.0, -100.0), bathy=rough.rows(),
               floor=rough.floor, oracle=False)
    c["floor_hess"] = rough.hess
    # --- a soft seabed (kBot = 1e3): the grounded run sinks ~4 m, and the line only fits its
    # span because of that penetration ---
    wire_soft = line_type("wiresoft", "wire", 0.10)
    delta_soft = wire_soft["w"] / (1.0e3 * wire_soft["d"])
    des = design([(30.0, wire_soft["w"], wire_soft["ea"])], 18.0 + delta_soft, 4.0)
    if des is not None:
        # (the anchor is held on the undeformed surface 4 m above the sunk run, which the
        # shifted-seabed catenary cannot represent: checked by the nodal force balance)
        single("soft_kbot_1e3", wire_soft, 30.0, 120, (0.0, 0.0, -4.0), (des[1], 0.0, -22.0), depth=22.0,
               kbot=1.0e3, oracle=False)
    # --- fine meshes and a soft seabed ---
    for n in (1000, 5000):
        single("fine_mesh_%d" % n, chain12, 520.0, n, (0.0, 0.0, -10.0), (450.0, 0.0, -100.0), depth=100.0)
    single("soft_kbot_1e4", chain12, 520.0, 200, (0.0, 0.0, -10.0), (450.0, 0.0, -100.0), depth=100.0, kbot=1.0e4,
           oracle=False)
    # --- steady current (uniform cross, inline, and a depth profile) ---
    for tag, spec in (("cross", ("uniform 0.0 1.5 0.0 current", lambda z: np.array([0.0, 1.5, 0.0]))),
                      ("inline", ("uniform 1.0 0.0 0.0 current", lambda z: np.array([1.0, 0.0, 0.0]))),
                      ("profile", ("profile 0.0 0.0 1.2 0.0 -100.0 0.0 0.3 0.0 current",
                                   lambda z: np.array([0.0, 1.2 + (0.3 - 1.2) * min(max(-z / 100.0, 0.0), 1.0),
                                                       0.0])))):
        # a steady current belongs to a dynamic deck (dtM/TMax); TMax = 0 writes the static IC
        single("current_" + tag, wire10, 520.0, 60, (0.0, 0.0, -10.0), (450.0, 0.0, -100.0), depth=100.0,
               current=spec, oracle=False, extra=("0.01 dtM", "0.0 TMax"))
    # --- Free/Connect points (dynamic-deck route, TMax = 0) ---
    CASES.append(dict(name="connect_clump", point_case=True, types={"chain": chain12, "poly": poly20},
                      points=[dict(id=1, type="Coupled", x=(0.0, 0.0, -10.0)),
                              dict(id=2, type="Fixed", x=(800.0, 0.0, -200.0)),
                              dict(id=3, type="Connect", x=(450.0, 0.0, -150.0), mass=5.0e3, vol=1.0)],
                      lines=[dict(id=1, A=1, B=3, sections=[("poly", 500.0, 50)]),
                             dict(id=2, A=3, B=2, sections=[("chain", 400.0, 40)])],
                      opts=["200.0 WtrDpth", "1.0e5 kBot", "0.01 dtM", "0.0 TMax"],
                      kbot=1.0e5, floor=lambda x, y: (-200.0, 0.0, 0.0), oracle=False))
    CASES.append(dict(name="free_buoy", point_case=True, types={"wire": wire10},
                      points=[dict(id=1, type="Fixed", x=(0.0, 0.0, -300.0)),
                              dict(id=2, type="Free", x=(6.0, -4.0, -100.0), mass=2000.0, vol=8.0)],
                      lines=[dict(id=1, A=1, B=2, sections=[("wire", 180.0, 40)])],
                      opts=["300.0 WtrDpth", "1.0e5 kBot", "0.01 dtM", "0.0 TMax"],
                      kbot=1.0e5, floor=lambda x, y: (-300.0, 0.0, 0.0), oracle=False))


# ------------------------------------------------------------------ run + checks
def run(exe, deck, root, cwd):
    t0 = time.perf_counter()
    # the wall-clock limit only stops a hung process; it is far above a loaded-machine run
    p = subprocess.run([exe, os.path.basename(deck), root], cwd=cwd, capture_output=True, text=True, timeout=900)
    return p.returncode, (p.stdout or "") + (p.stderr or ""), time.perf_counter() - t0


def outputs_of(case):
    out = []
    for ln in case["lines"]:
        out += ["FairTen%d" % ln["id"], "AnchTen%d" % ln["id"]]
    for p in case["points"]:
        if p["type"] in ("Free", "Connect"):
            out += ["Point%dp%s" % (p["id"], c) for c in "xyz"]
    return out


def evaluate(case, exe):
    d = case["dir"]
    deck = os.path.join(d, "deck.dat")
    write_deck(deck, case["types"].values(), case["points"], case["lines"], case["opts"], outputs_of(case),
               case.get("bathy"))
    if case.get("bathy") is not None:
        os.replace(os.path.join(d, "bathy_deck.txt"), os.path.join(d, "bathy_%s.txt" % case["name"]))
    rc, log, dt = run(exe, deck, "o", d)
    name = case["name"]
    if case.get("expect_reject"):
        check(rc == 1 and "below the seabed" in log, "%s: an anchor below the seabed tolerance is rejected" % name)
        return
    check(rc == 0, "%s: converges (rc=%d): %s" % (name, rc, log.strip().splitlines()[-1] if log.strip() else ""))
    if rc != 0:
        return
    row = read_row(os.path.join(d, "o.out"))
    for ln in case["lines"]:
        T = read_tensions(os.path.join(d, "o.Line%d.t.out" % ln["id"]))
        check(T.min() >= 0.0, "%s: no compressed element (min %.4g N)" % (name, T.min()))
    bal = nodal_balance(case, "o")
    check(bal < BALANCE_TOL, "%s: nodal force balance %.3g" % (name, bal))
    if case.get("point_case"):
        check_points(case, row)
    if case.get("pile_dz"):
        # a slack element at the bottom of the trench, and the anchor tension of the grounded
        # run that rises from a zero tension there: w times the trench depth below the anchor
        T = read_tensions(os.path.join(d, "o.Line1.t.out"))
        w = next(iter(case["types"].values()))["w"]
        check(T.min() <= 0.0, "%s: the excess length rests slack at the bottom of the trench" % name)
        check(abs(row["AnchTen1"] - w * case["pile_dz"]) < 0.02 * w * case["pile_dz"],
              "%s: AnchTen %.6g vs w*depth %.6g" % (name, row["AnchTen1"], w * case["pile_dz"]))
    if case.get("fair_ref"):
        # slack line: the hanging leg carries about its own weight w*h (the discrete grounded
        # run keeps a small horizontal tension), never a compressed strut or zero
        check(abs(row["FairTen1"] - case["fair_ref"]) < 0.15 * case["fair_ref"],
              "%s: slack-line FairTen %.6g vs w*h %.6g" % (name, row["FairTen1"], case["fair_ref"]))
    if "current" in case and name.endswith("cross"):
        P = read_nodes(os.path.join(d, "o.Line1.p.out"))
        check(P[len(P) // 2, 1] > 0.1, "%s: a cross current displaces the line downstream" % name)
    if case.get("oracle"):
        check_oracle(case, row)
    if case.get("route_pair"):
        deck0 = os.path.join(d, "deck_t0.dat")
        with open(deck, encoding="utf-8") as f:
            txt = f.read().replace(
                "--------------------- OUTPUTS ---", "0.01 dtM\n0.0 TMax\n--------------------- OUTPUTS ---"
            )
        with open(deck0, "w", newline="\n") as f:
            f.write(txt)
        rc0, log0, _ = run(exe, deck0, "t0", d)
        check(rc0 == 0, "%s: dynamic (TMax=0) route converges" % name)
        if rc0 == 0:
            row0 = read_row(os.path.join(d, "t0.out"))
            for k in ("FairTen1", "AnchTen1"):
                check(abs(row0[k] - row[k]) <= 1e-6 * max(abs(row[k]), 1.0),
                      "%s: %s identical on the static and TMax=0 routes (%.9g vs %.9g)" % (name, k, row[k], row0[k]))


def check_points(case, row):
    """Every Free/Connect point is at rest: the line-end forces and its own seabed contact balance its
    weight/buoyancy."""
    for p in case["points"]:
        if p["type"] not in ("Free", "Connect"):
            continue
        pos = np.array([row["Point%dp%s" % (p["id"], c)] for c in "xyz"])
        net = np.array([0.0, 0.0, (RHO * p.get("vol", 0.0) - p.get("mass", 0.0)) * G])
        scale = abs(net[2])
        for ln in case["lines"]:
            if p["id"] not in (ln["A"], ln["B"]):
                continue
            P = read_nodes(os.path.join(case["dir"], "o.Line%d.p.out" % ln["id"]))
            T = read_tensions(os.path.join(case["dir"], "o.Line%d.t.out" % ln["id"]))
            segs = []
            for tn, length, n in ln["sections"]:
                segs += [(case["types"][tn], length / n)] * n
            end = 0 if np.linalg.norm(P[0] - pos) < np.linalg.norm(P[-1] - pos) else -1
            nb, te, (t, l0) = (P[1], T[0], segs[0]) if end == 0 else (P[-2], T[-1], segs[-1])
            check(np.linalg.norm(P[end] - pos) < 1e-3,
                  "%s: line %d ends on point %d" % (case["name"], ln["id"], p["id"]))
            net += te * (nb - P[end]) / np.linalg.norm(nb - P[end])
            net[2] -= 0.5 * t["w"] * l0
            # a point resting on the seabed is carried by its line-end nodes' penalty contact
            zf = case["floor"](*P[end][:2])[0]
            if P[end][2] < zf:
                net[2] += 0.5 * case["kbot"] * t["d"] * l0 * (zf - P[end][2])
            scale = max(scale, te)
        # ... and by its own contact over its footprint A = V^(2/3) (V = Vol, or Mass/7850 kg/m^3),
        # the line law along the floor normal
        vol = p.get("vol", 0.0) if p.get("vol", 0.0) > 0.0 else p.get("mass", 0.0) / 7850.0
        zf, gx, gy = case["floor"](*pos[:2])
        if vol > 0.0 and pos[2] < zf:
            s = math.sqrt(1.0 + gx * gx + gy * gy)
            net += case["kbot"] * vol ** (2.0 / 3.0) * (zf - pos[2]) / s * np.array([-gx, -gy, 1.0]) / s
        check(np.linalg.norm(net) < 1e-3 * scale,
              "%s: point %d force balance %.3g of %.3g N" % (case["name"], p["id"], np.linalg.norm(net), scale))


def check_oracle(case, row):
    pieces = case.get("pieces")
    if pieces is None:
        t = list(case["types"].values())[0]
        pieces = [(case["lines"][0]["sections"][0][1], t["w"], t["ea"])]
    A = np.array(case["points"][1]["x"])
    F = np.array(case["points"][0]["x"])
    X = float(np.hypot(*(F[:2] - A[:2])))
    Z = float(F[2] - A[2])
    seabed = "floor" in case
    slope = case.get("slope") or 0.0
    sol = solve_oracle(pieces, X, Z, seabed, slope, case.get("guess"))
    if seabed and sol is not None and sol[1] > 0.0:
        # a grounded run sinks by its penalty depth w/(kBot d): re-close the oracle for it
        t0 = case["types"][case["lines"][0]["sections"][-1][0]]
        sol2 = solve_oracle(pieces, X, Z + t0["w"] / (case["kbot"] * t0["d"]), seabed, slope, sol)
        if sol2 is not None and sol2[1] > 0.0:
            sol = sol2
    check(sol is not None, "%s: oracle solves" % case["name"])
    if sol is None:
        return
    H, u = sol
    L = sum(p[0] for p in pieces)
    _, _, hs, vf, _ = profile(H, u, pieces, seabed, slope)
    tf = math.hypot(hs, vf)
    check(abs(row["FairTen1"] - tf) < TEN_TOL * tf,
          "%s: FairTen %.6g vs elastic catenary end tension %.6g" % (case["name"], row["FairTen1"], tf))
    # element tensions at mid-segments, arc from the anchor (output order is End A -> End B)
    T = read_tensions(os.path.join(case["dir"], "o.Line1.t.out"))
    segs = []
    for tn, length, n in case["lines"][0]["sections"]:
        segs += [length / n] * n
    arcs_a = np.cumsum([0.0] + segs)
    mids = L - 0.5 * (arcs_a[:-1] + arcs_a[1:])
    order = np.argsort(mids)
    tor = np.empty(len(mids))
    tor[order] = profile(H, u, pieces, seabed, slope, sample=sorted(mids))[4]
    err = np.max(np.abs(T - tor)) / max(tor.max(), tf)
    check(err < TEN_TOL, "%s: element tensions within %.0f%% of the catenary (max err %.3g)" %
          (case["name"], 100 * TEN_TOL, err))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--jobs", type=int, default=4)
    a = ap.parse_args()
    build_cases()
    if len(CASES) != EXPECTED_CASES:
        print("FAIL: the matrix built %d cases, expected %d" % (len(CASES), EXPECTED_CASES))
        return 1
    for c in CASES:
        c["dir"] = os.path.join(a.output, c["name"])
        os.makedirs(c["dir"], exist_ok=True)
    t0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=a.jobs) as ex:
        list(ex.map(lambda c: evaluate(c, os.path.abspath(a.exe)), CASES))
    print("statics robustness matrix: %d cases in %.1f s" % (len(CASES), time.perf_counter() - t0))
    if FAILURES:
        print("FAIL: %d assertion(s) failed" % len(FAILURES))
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
