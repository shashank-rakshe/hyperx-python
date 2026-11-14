"""
Parametric ship hull generator - ShipBrain's own code (written from scratch; it is not derived from the Ship-D code, which has no licence).

A hull is a small set of numbers (lengths in metres, angles in degrees):

  principal      L   length between perpendiculars (the hull proper),  B   beam,  D   depth,  T   design draft
  midship        r_bilge  radius of the bilge,  deadrise  rise of the bottom towards the sides,  flare  slope of the sides above the design waterline (0 = vertical)
  plan form      ent  length of the entrance (fraction of L),  run  length of the run (fraction of L),  n_ent, n_run  fullness exponents (1 = straight, large = full shoulders),
                 transom  half-breadth of the stern at the waterline as a fraction of B / 2 (0 = pointed stern)
  ends           vee  how much finer the ends are at the keel than at the waterline (0 = same section all along, larger = V-shaped ends, lower block coefficient)
  bulb           bulb_len  how far the bulb reaches ahead of the stem,  bulb_b  its breadth,  bulb_h  its height,  bulb_z  height of its centre (0 length = no bulb)

The surface is  y(x, z) = plan(x) * section(z)  (half-breadth at distance x from the aft end and height z above the keel), plus the bulb, a tapered ellipsoid that is merged with
max(). From it come: coefficients (Cb, Cp, Cm, Cwp, LCB), the half-breadth table that Vessel.js reads (hydrostatics and stability through ship_hydrostatics), a watertight STL, the
section area curve, and a constrained random sampler / target solver (designs that meet a given Cb). Checked in tests/test_hullgen.py against closed-form results.
"""
import math, os, random

import numpy as np

DEFAULTS = dict(L=100.0, B=16.0, D=9.0, T=6.0, r_bilge=1.5, deadrise=0.0, flare=0.0, ent=0.30, run=0.25, n_ent=2.0, n_run=2.0, transom=0.45,
                bulb_len=0.0, bulb_b=0.0, bulb_h=0.0, bulb_z=0.0, vee=0.0)
BOUNDS = dict(L=(10, 400), B=(2, 60), D=(1, 40), T=(0.5, 30), r_bilge=(0, 20), deadrise=(0, 30), flare=(0, 30), ent=(0.02, 0.6), run=(0.02, 0.6), n_ent=(1, 8), n_run=(1, 8),
              transom=(0, 1), bulb_len=(0, 20), bulb_b=(0, 20), bulb_h=(0, 20), bulb_z=(0, 20), vee=(0, 4))


def check(p):
    """list of reasons why a parameter set is not a valid hull (empty = fine)"""
    bad = []
    for k, (lo, hi) in BOUNDS.items():
        if k in p and not (lo <= p[k] <= hi):
            bad.append(f'{k} = {p[k]} is outside {lo} .. {hi}')
    if p['T'] > p['D']:
        bad.append('the design draft T is deeper than the hull D')
    if p['ent'] + p['run'] > 1.0:
        bad.append('entrance + run is longer than the hull (ent + run must be <= 1)')
    if p['r_bilge'] > min(p['B'] / 2, p['T']) + 1e-9:
        bad.append('the bilge radius is larger than half the beam or the draft')
    if p['bulb_len'] > 0:
        if p['bulb_b'] <= 0 or p['bulb_h'] <= 0:
            bad.append('a bulb needs bulb_b and bulb_h')
        if p['bulb_b'] >= p['B']:
            bad.append('the bulb is as wide as the hull')
        if p['bulb_z'] + p['bulb_h'] / 2 > p['T'] + 1e-9 or p['bulb_z'] - p['bulb_h'] / 2 < 0:
            bad.append('the bulb must sit between the keel and the design waterline')
    return bad


def params(**kw):
    p = dict(DEFAULTS)
    for k, v in kw.items():
        if k not in DEFAULTS:
            raise ValueError(f'unknown hull parameter {k}; known: ' + ', '.join(DEFAULTS))
        p[k] = float(v)
    bad = check(p)
    if bad:
        raise ValueError('not a valid hull: ' + '; '.join(bad))
    return p


# ====================================================================== the surface
def _section_curve(p, n=400):
    """midship half-breadth as a function of height: (z array, y array), y(0) at the keel; bottom rises with deadrise, rounded bilge, flared side above the waterline"""
    B2, r, beta = p['B'] / 2, p['r_bilge'], math.radians(p['deadrise'])
    T, D, fl = p['T'], p['D'], math.radians(p['flare'])
    pts = []
    if r < 1e-9:
        y_ch = B2
        z_ch = y_ch * math.tan(beta)
        pts += [(0.0, 0.0), (y_ch, z_ch)]
        z_side = z_ch
    else:
        # straight bottom (slope beta) from the keel, then a circular bilge of radius r, tangent to the bottom line and to the vertical side
        cy, cz = B2 - r, r + (B2 - r) * 0.0
        # circle centre (B2 - r, zc) with tangency to the sloped bottom line z = y tan(beta): distance from centre to the line = r
        cy = B2 - r
        zc = r / math.cos(beta) + cy * math.tan(beta)
        # tangent point on the bottom line
        ty = cy + r * math.sin(beta)
        tz = zc - r * math.cos(beta)
        pts += [(0.0, 0.0), (max(ty, 0.0), tz if ty > 0 else 0.0)]
        for a in np.linspace(-(math.pi / 2 - beta), 0.0, 40)[1:]:        # arc from the bottom tangent point to the vertical side
            pts.append((cy + r * math.cos(a + 0.0) if False else cy + r * math.cos(a), zc + r * math.sin(a)))
        z_side = zc
    pts.append((B2, z_side))
    # side: vertical up to the design waterline, then flared
    if T > z_side:
        pts.append((B2, T))
    z0 = max(T, z_side)
    pts.append((B2 + (D - z0) * math.tan(fl), D))
    P = np.array(pts)
    P = P[np.argsort(P[:, 1], kind='stable')]
    # make z strictly increasing for interpolation
    z = P[:, 1] + np.arange(len(P)) * 1e-12
    return z, P[:, 0]


def make_surface(p):
    """returns f(x, z) -> half-breadth (arrays), with x from the aft end over LOA and z above the keel"""
    z_s, y_s = _section_curve(p)
    L, ent, run, ne, nr, tr = p['L'], p['ent'], p['run'], p['n_ent'], p['n_run'], p['transom']
    bl, bb, bh, bz = p['bulb_len'], p['bulb_b'], p['bulb_h'], p['bulb_z']

    def plan(x):
        s = x / L
        out = np.ones_like(s)
        a = s < run
        t = np.clip(s[a] / max(run, 1e-12), 0, 1)                         # 0 at the transom, 1 at the end of the run
        out[a] = tr + (1 - tr) * (1 - (1 - t) ** nr)
        f = s > 1 - ent
        u = np.clip((s[f] - (1 - ent)) / max(ent, 1e-12), 0, 1)           # 0 at the start of the entrance, 1 at the stem
        out[f] = 1 - u ** ne
        out[s > 1.0] = 0.0
        out[s < 0.0] = 0.0
        return out

    def hull(x, z):
        x, z = np.broadcast_arrays(np.asarray(x, float), np.asarray(z, float))
        T = p['T']
        expo = 1.0 + p['vee'] * (1.0 - np.minimum(z, T) / T)                 # V-shaped ends: the keel region narrows faster towards the stem and stern
        y = np.interp(z, z_s, y_s) * np.power(np.clip(plan(x), 0.0, 1.0), expo)
        if bl > 0:                                                         # bulb: an ellipsoid ending at the stem, reaching bl ahead of it
            lx = 1.5 * bl                                                  # its length: part inside the hull, part in front
            xc = L + bl - lx / 2
            q = 1 - ((x - xc) / (lx / 2)) ** 2 - ((z - bz) / (bh / 2)) ** 2
            yb = np.where(q > 0, (bb / 2) * np.sqrt(np.clip(q, 0, None)), 0.0)
            y = np.maximum(y, yb)
        return y
    return hull


def loa(p):
    return p['L'] + p['bulb_len']


# ====================================================================== numbers from the surface
def coefficients(p, T=None, nx=801, nz=301):
    """Cb, Cp, Cm, Cwp, LCB, LCF, KB, Awp, volume, wetted area at draft T (default design draft) - own numerical integration of the surface"""
    T = T or p['T']
    f = make_surface(p)
    x = np.linspace(0, loa(p), nx)
    z = T * np.linspace(0, 1, nz) ** 2                                      # finer near the keel, where the bilge curve is steep
    Y = f(x[:, None], z[None, :])
    area = 2 * np.trapezoid(Y, z, axis=1)                                  # section areas
    V = np.trapezoid(area, x)
    wp = 2 * Y[:, -1]
    Awp = np.trapezoid(wp, x)
    LCB = np.trapezoid(area * x, x) / V
    LCF = np.trapezoid(wp * x, x) / Awp
    KB = np.trapezoid(np.trapezoid(2 * Y * z[None, :], z, axis=1), x) / V
    Am = float(area.max())
    # wetted surface (sides + bottom, no deck, no end caps) from the triangles of the hull truncated at the draft
    Vm, Fm = _hull_shell(dict(p, D=T, T=T, flare=0.0, bulb_len=0.0), 241, 61)
    A_, B_, C_ = Vm[Fm[:, 0]], Vm[Fm[:, 1]], Vm[Fm[:, 2]]
    ar = 0.5 * np.linalg.norm(np.cross(B_ - A_, C_ - A_), axis=1)
    on = lambda ax, v: (np.abs(A_[:, ax] - v) < 1e-9) & (np.abs(B_[:, ax] - v) < 1e-9) & (np.abs(C_[:, ax] - v) < 1e-9)
    side = float(ar[~(on(2, T) | on(0, 0.0) | on(0, Vm[:, 0].max()))].sum())
    return {'draft_m': T, 'volume_m3': float(V), 'Awp_m2': float(Awp), 'Cb': float(V / (p['L'] * p['B'] * T)), 'Cp': float(V / (Am * p['L'])), 'Cm': float(Am / (p['B'] * T)),
            'Cwp': float(Awp / (p['L'] * p['B'])), 'LCB_m': float(LCB), 'LCB_percent_L': float(100 * (LCB - p['L'] / 2) / p['L']), 'LCF_m': float(LCF), 'KB_m': float(KB),
            'wetted_area_m2': float(side), 'section_area_curve': {'x_m': [round(float(v), 3) for v in x[::40]], 'area_m2': [round(float(v), 4) for v in area[::40]]}}


def vessel_table(p, n_st=41, n_wl=25):
    """the half-breadth table in Vessel.js format: stations as fractions of LOA, waterlines as fractions of the depth, half-breadths as fractions of the largest half-beam"""
    f = make_surface(p)
    La = loa(p)
    st = np.linspace(0, 1, n_st)
    wl = np.linspace(0, 1, n_wl)
    Y = f((st * La)[None, :], (wl * p['D'])[:, None])
    ymax = max(p['B'] / 2, float(Y.max()))
    tab = np.clip(Y / ymax, 0, 1)
    tab[0, :] = 0.0 if p['deadrise'] == 0 and p['r_bilge'] == 0 else tab[0, :]
    return {'waterlines': [round(float(w), 6) for w in wl], 'stations': [round(float(s), 6) for s in st], 'table': [[round(float(v), 6) for v in row] for row in tab]}, ymax * 2


# ====================================================================== STL
def _ellipsoid(c, a, b, h, nu=40, nv=24):
    V, F = [[c[0], c[1], c[2] + h], [c[0], c[1], c[2] - h]], []
    ids = []
    for j in range(1, nv):
        th = math.pi * j / nv
        row = []
        for i in range(nu):
            ph = 2 * math.pi * i / nu
            V.append([c[0] + a * math.sin(th) * math.cos(ph), c[1] + b * math.sin(th) * math.sin(ph), c[2] + h * math.cos(th)])
            row.append(len(V) - 1)
        ids.append(row)
    for i in range(nu):
        F.append([0, ids[0][i], ids[0][(i + 1) % nu]])
        F.append([1, ids[-1][(i + 1) % nu], ids[-1][i]])
    for j in range(len(ids) - 1):
        for i in range(nu):
            a0, a1, b0, b1 = ids[j][i], ids[j][(i + 1) % nu], ids[j + 1][i], ids[j + 1][(i + 1) % nu]
            F += [[a0, b0, a1], [a1, b0, b1]]
    V, F = np.array(V), np.array(F)
    if np.einsum('ij,ij->i', V[F[:, 0]], np.cross(V[F[:, 1]], V[F[:, 2]])).sum() < 0:
        F = F[:, [0, 2, 1]]
    return V, F


def stl_mesh(p, nx=121, nz=41):
    """watertight mesh of the hull up to the deck. A bulb is a second closed shell (an ellipsoid) overlapping the hull at the stem - two closed shells in one file"""
    if p['bulb_len'] > 0:
        V1, F1 = _hull_shell(dict(p, bulb_len=0.0), nx, nz)
        lx = 1.5 * p['bulb_len']
        V2, F2 = _ellipsoid((p['L'] + p['bulb_len'] - lx / 2, 0.0, p['bulb_z']), lx / 2, p['bulb_b'] / 2, p['bulb_h'] / 2)
        return np.vstack([V1, V2]), np.vstack([F1, F2 + len(V1)])
    return _hull_shell(p, nx, nz)


def _hull_shell(p, nx=121, nz=41):
    """watertight triangle mesh of the hull up to the deck: (vertices, triangles). Stations run from the transom to the stem; sections are closed by the deck line"""
    f = make_surface(p)
    La = loa(p)
    xs = np.linspace(0, La, nx)
    zs = np.linspace(0, p['D'], nz)
    Y = f(xs[:, None], zs[None, :])
    V, F = [], []
    ring = lambda i: list(range(i * (2 * nz), (i + 1) * (2 * nz)))
    for i in range(nx):                                                    # starboard from keel up (y > 0), then port from deck down
        for k in range(nz):
            V.append([xs[i], Y[i, k], zs[k]])
        for k in range(nz - 1, -1, -1):
            V.append([xs[i], -Y[i, k], zs[k]])
    m = 2 * nz
    for i in range(nx - 1):
        for k in range(m):
            a, b = i * m + k, i * m + (k + 1) % m
            c, d = (i + 1) * m + k, (i + 1) * m + (k + 1) % m
            F += [[a, c, b], [b, c, d]]
    for i, flip in ((0, True), (nx - 1, False)):                           # end caps: fans around the centroid of the ring
        c = len(V)
        ring_pts = np.array(V[i * m:(i + 1) * m])
        V.append(ring_pts.mean(axis=0).tolist())
        for k in range(m):
            a, b = i * m + k, i * m + (k + 1) % m
            F.append([c, b, a] if not flip else [c, a, b])
    V = np.array(V)
    F = np.array(F)
    # weld the vertices that coincide (keel line, deck centre line, tips): degenerate triangles are dropped
    key = np.round(V, 7)
    uniq, inv = np.unique(key, axis=0, return_inverse=True)
    F = np.asarray(inv).reshape(-1)[F.reshape(-1)].reshape(-1, 3)
    ok = (F[:, 0] != F[:, 1]) & (F[:, 1] != F[:, 2]) & (F[:, 0] != F[:, 2])
    F = F[ok]
    A, Bv, C = uniq[F[:, 0]], uniq[F[:, 1]], uniq[F[:, 2]]
    area = 0.5 * np.linalg.norm(np.cross(Bv - A, C - A), axis=1)
    F = F[area > 1e-12]
    # orient the outside normals outward (positive volume)
    A, Bv, C = uniq[F[:, 0]], uniq[F[:, 1]], uniq[F[:, 2]]
    vol = np.einsum('ij,ij->i', A, np.cross(Bv, C)).sum() / 6
    if vol < 0:
        F = F[:, [0, 2, 1]]
    return uniq, F


def write_stl(p, path, **kw):
    V, F = stl_mesh(p, **kw)
    with open(path, 'w') as fh:
        fh.write('solid hull\n')
        for t in F:
            a, b, c = V[t[0]], V[t[1]], V[t[2]]
            n = np.cross(b - a, c - a)
            n = n / (np.linalg.norm(n) or 1.0)
            fh.write(f'facet normal {n[0]:.6g} {n[1]:.6g} {n[2]:.6g}\n outer loop\n')
            for q in (a, b, c):
                fh.write(f'  vertex {q[0]:.6g} {q[1]:.6g} {q[2]:.6g}\n')
            fh.write(' endloop\nendfacet\n')
        fh.write('endsolid hull\n')
    return path


# ====================================================================== design: targets and random hulls
def solve_cb(p, target_cb, T=None):
    """vary the fullness exponents (both ends together, 1 .. 8) and, if that is not enough, the V-shape of the ends (vee), until the block coefficient at the design draft is
    target_cb; returns new parameters"""
    p = dict(p)

    def cb(n, vee):
        return coefficients(dict(p, n_ent=n, n_run=n, vee=vee), T, nx=401, nz=121)['Cb']

    def bis(f, lo, hi, target):
        a = f(lo) - target
        for _ in range(40):
            m = 0.5 * (lo + hi)
            if (f(m) - target) * a > 0:
                lo = m
            else:
                hi = m
        return 0.5 * (lo + hi)
    v0 = p['vee']
    c_lo, c_hi = cb(1.0, v0), cb(8.0, v0)                                   # fullness 1 (straight) .. 8 (full shoulders)
    if min(c_lo, c_hi) - 1e-6 <= target_cb <= max(c_lo, c_hi) + 1e-6:
        n = bis(lambda n: cb(n, v0), 1.0, 8.0, target_cb)
        return dict(p, n_ent=round(n, 4), n_run=round(n, 4))
    if target_cb < min(c_lo, c_hi):                                         # finer than straight ends: make the ends V-shaped
        lo_c = cb(1.0, 4.0)
        if target_cb >= lo_c - 1e-6:
            vee = bis(lambda v: cb(1.0, v), v0, 4.0, target_cb)
            return dict(p, n_ent=1.0, n_run=1.0, vee=round(vee, 4))
        lo = lo_c
    else:
        lo = c_hi
    raise ValueError(f'Cb {target_cb} cannot be reached with this midship section and plan form (it spans about {min(c_lo, lo):.3f} .. {max(c_hi, c_lo):.3f}): '
                     'change the entrance / run lengths, the bilge radius or the transom')


def random_hull(rng, kind='ship'):
    """a random valid hull, in the range of ships (kind 'ship') or small craft ('boat')"""
    for _ in range(200):
        L = rng.uniform(60, 250) if kind == 'ship' else rng.uniform(8, 40)
        B = L * rng.uniform(0.11, 0.2) if kind == 'ship' else L * rng.uniform(0.2, 0.35)
        T = B * rng.uniform(0.3, 0.5)
        D = T * rng.uniform(1.25, 1.6)
        p = dict(DEFAULTS, L=L, B=B, T=T, D=D, r_bilge=rng.uniform(0, 0.15) * B, deadrise=rng.choice([0.0, rng.uniform(0, 15)]), flare=rng.choice([0.0, rng.uniform(0, 12)]),
                 ent=rng.uniform(0.12, 0.4), run=rng.uniform(0.1, 0.3), n_ent=rng.uniform(1.2, 4.5), n_run=rng.uniform(1.2, 4.5), transom=rng.choice([0.0, rng.uniform(0.2, 0.7)]), vee=rng.choice([0.0, rng.uniform(0, 2.5)]))
        if kind == 'ship' and rng.random() < 0.5:
            p.update(bulb_len=rng.uniform(0.01, 0.04) * L, bulb_b=rng.uniform(0.25, 0.45) * B, bulb_h=rng.uniform(0.3, 0.6) * T, bulb_z=rng.uniform(0.35, 0.55) * T)
        if not check(p):
            return {k: round(float(v), 4) for k, v in p.items()}
    raise RuntimeError('could not draw a valid hull')
