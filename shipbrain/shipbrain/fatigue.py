"""
Fatigue (hot-spot stress) local models, after the usual t x t shell approach (e.g. DNV-RP-C203 / IIW):

  fatigue_mesh(plates, hotspot, ...)   cut a box around the hot spot out of the plate assembly, mesh it with
                                        t x t elements (t = thickness of the plate the stress is read in),
                                        clamp the cut faces (or give your own boundary), return read-out points
  hotspot_stress(frd, points, ...)      after the CalculiX run: surface stress perpendicular to the weld at 0.5t and
                                        1.5t, extrapolated to the weld toe: s_hs = 1.5 s(0.5t) - 0.5 s(1.5t)

A local model with clamped cut faces is a screening model. For a class submission, drive the cut boundary with the
global model's displacements (sub-modelling) - planned next.
"""
import numpy as np

from .platemesh import Plate, intersections, build_plates


def _clip_poly(P, lo, hi):
    """Sutherland-Hodgman clip of a 3D planar polygon against an axis-aligned box"""
    out = [np.asarray(p, float) for p in P]
    for k in range(3):
        for side, lim in ((1, lo[k]), (-1, hi[k])):
            if not out:
                return []
            inp, out = out, []
            for i in range(len(inp)):
                a, b = inp[i - 1], inp[i]
                da, db = side * (a[k] - lim), side * (b[k] - lim)
                if db >= 0:
                    if da < 0:
                        out.append(a + (b - a) * (da / (da - db)))
                    out.append(b)
                elif da >= 0:
                    out.append(a + (b - a) * (da / (da - db)))
    clean = []
    for p in out:
        if not clean or np.linalg.norm(p - clean[-1]) > 1e-6:
            clean.append(p)
    if len(clean) > 1 and np.linalg.norm(clean[0] - clean[-1]) < 1e-6:
        clean.pop()
    return clean


def _area(P):
    n = np.zeros(3)
    for i in range(len(P)):
        n += np.cross(P[i], P[(i + 1) % len(P)])
    return np.linalg.norm(n) / 2


def fatigue_mesh(plates, hotspot, size=None, t=None, out_dir='.', name='hotspot', loads=None, material=None):
    hs = np.asarray(hotspot, float)
    tol = 1e-3
    P = [Plate(d, tol) for d in plates]
    if t is None:                                   # thinnest plate through the hot spot
        through = [p.t for p in P if abs(p.plane_dist(hs)) < 1.0 and p.in_or_on(p.to2(hs), 1.0)[0]]
        t = min(through) if through else min(p.t for p in P)
    t = float(t)
    size = float(size or 10 * t)                    # box edge: ~10 t around the hot spot
    lo, hi = hs - size / 2, hs + size / 2
    local, kept = [], []
    for d, p in zip(plates, P):
        out = _clip_poly(d['outline'], lo, hi)
        if len(out) < 3 or _area(out) < (t * t) / 4:
            continue
        holes = []
        for h in d.get('holes') or []:
            hc = _clip_poly(h, lo, hi)
            if len(hc) >= 3 and _area(hc) > t * t / 10:
                holes.append([list(x) for x in hc])
        local.append({**d, 'outline': [list(x) for x in out], 'holes': holes})
        kept.append(d.get('id'))
    if not local:
        raise ValueError('no plate passes through the hot-spot box: check the hot-spot coordinates')
    fix = [{'x': float(lo[0])}, {'x': float(hi[0])}, {'y': float(lo[1])}, {'y': float(hi[1])}, {'z': float(lo[2])}, {'z': float(hi[2])}]
    m, info = build_plates({'name': name, 'plates': local, 'element_size': t, 'loads': loads or [], 'fix': fix,
                            **({'material': material} if material else {})}, out_dir)
    # read-out points: from the hot spot, in each plate that has the hot spot on one of its joint lines, perpendicular
    # to that joint line, at 0.5t and 1.5t
    LP = [Plate(d, tol) for d in local]
    segs = intersections(LP, tol)
    pts = []
    for (a, b) in segs:
        d = b - a
        L = np.linalg.norm(d)
        if L < 1e-9:
            continue
        d /= L
        s = (hs - a) @ d
        if not (-1e-3 <= s <= L + 1e-3) or np.linalg.norm(a + s * d - hs) > 1.0:
            continue                                   # this joint does not pass through the hot spot
        for p in LP:
            if abs(p.plane_dist(a)) > 1e-3 or abs(p.plane_dist(b)) > 1e-3:
                continue
            perp = np.cross(p.n, d)
            for sgn in (1, -1):
                v = sgn * perp
                q = hs + v * 0.5 * t
                if p.in_or_on(p.to2(q), 1e-3)[0] and p.in_or_on(p.to2(hs + v * 1.5 * t), 1e-3)[0]:
                    pts.append({'plate': p.id, 'weld_line': d.round(4).tolist(), 'direction': v.round(4).tolist(),
                                'normal': p.n.round(4).tolist(), 't': p.t,
                                'p05': (hs + v * 0.5 * p.t).round(3).tolist(), 'p15': (hs + v * 1.5 * p.t).round(3).tolist()})
    info.update({'t_ref': t, 'box_mm': size, 'plates_in_box': kept, 'readout_points': pts,
                 'note': f'element size = t = {t:g} mm; cut faces of the {size:g} mm box are clamped (screening model)'})
    return m, info


def hotspot_stress(frd, readout_points):
    """surface stress perpendicular to the weld at 0.5t and 1.5t on both plate surfaces -> hot-spot stress"""
    from .solver import read_frd_full
    xyz, S, _ = read_frd_full(frd)
    ids = np.array([k for k in S if k in xyz])
    X = np.array([xyz[k][:3] for k in ids])
    out = []
    for rp in readout_points:
        d = np.array(rp['direction'])
        n = np.array(rp['normal'])
        res = {'plate': rp['plate'], 'direction': rp['direction']}
        for face, sgn in (('top', 1), ('bottom', -1)):
            vals = []
            for key in ('p05', 'p15'):
                q = np.array(rp[key]) + sgn * n * rp['t'] / 2
                dist = np.linalg.norm(X - q, axis=1)
                near = np.argsort(dist)[:4]                     # inverse-distance average of the 4 nearest surface nodes
                w = 1 / (dist[near] + 1e-6)
                sig = 0.0
                for wi, i in zip(w, near):
                    s = S[ids[i]]
                    T = np.array([[s[0], s[3], s[5]], [s[3], s[1], s[4]], [s[5], s[4], s[2]]])
                    sig += wi * (d @ T @ d)
                vals.append(sig / w.sum())
            res[face] = {'s_0.5t': round(vals[0], 2), 's_1.5t': round(vals[1], 2), 'hot_spot': round(1.5 * vals[0] - 0.5 * vals[1], 2)}
        res['hot_spot_max_abs'] = max((res['top']['hot_spot'], res['bottom']['hot_spot']), key=abs)
        out.append(res)
    worst = max(out, key=lambda r: abs(r['hot_spot_max_abs'])) if out else None
    return {'points': out, 'worst': worst,
            'method': 's_hs = 1.5 s(0.5t) - 0.5 s(1.5t), stress component perpendicular to the weld line, plate surfaces'}
