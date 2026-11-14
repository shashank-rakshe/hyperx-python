"""R-S9 / R-S10  group the scan vectoriser's loose segments into PATHS like a vector PDF has, and fit arcs.

R-S9 grouping: end points that meet (within 0.6 pt) at a node where exactly TWO solid segments end are joined; chains of such segments are one path (a polyline / an outline);
junctions of three or more (T, cross) and dashed lines end a path.  A chain whose last point meets its first is closed.
R-S10 arc fitting: inside a chain a run of >= 3 short edges (<= 8 pt) that turn the same way (each turn <= 45 deg) and lie on a circle (rms <= 0.3 pt, radius >= 1.2 pt) is one arc,
written as cubic Bezier pieces (kind 'c', 4 points, <= 90 deg each) exactly like the curves of a vector PDF.
"""
import math
import numpy as np
from scipy.spatial import cKDTree

TOL = 0.6
MAXE = 30.0          # longest edge inside an arc run (pt)
SAG = 0.6
MINTURN = math.radians(6)   # an arc must bend by at least this much in total


def _chains(segs):
    solid = [i for i, s in enumerate(segs) if not s.get('dash')]
    pts = []
    for i in solid:
        pts.append(segs[i]['a']); pts.append(segs[i]['b'])
    if not pts:
        return [], list(range(len(segs)))
    P = np.array(pts, float)
    tree = cKDTree(P)
    # node id by union of points closer than TOL
    parent = list(range(len(P)))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]; x = parent[x]
        return x
    for a, b in tree.query_pairs(TOL):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[ra] = rb
    node = np.array([find(i) for i in range(len(P))])
    ends = {}
    for k, i in enumerate(solid):
        for e in (0, 1):
            ends.setdefault(int(node[2 * k + e]), []).append((k, e))
    used = [False] * len(solid)
    chains = []
    # open chains start at nodes of degree != 2
    def walk(k, e_from):
        """start at segment k entering from end e_from; returns list of points"""
        pts_ = []
        cur, e = k, e_from
        while True:
            used[cur] = True
            s = segs[solid[cur]]
            p0, p1 = (s['a'], s['b']) if e == 0 else (s['b'], s['a'])
            if not pts_:
                pts_.append(p0)
            pts_.append(p1)
            nd = int(node[2 * cur + (1 - e)])
            lst = ends[nd]
            if len(lst) != 2:
                return pts_, False
            nxt = [q for q in lst if q[0] != cur]
            if not nxt:
                return pts_, False
            nk, ne = nxt[0]
            if used[nk]:
                return pts_, nk == k and ne == e_from
            cur, e = nk, ne
    for nd, lst in ends.items():
        if len(lst) != 2:
            for k, e in lst:
                if not used[k]:
                    pts_, closed = walk(k, e)
                    chains.append((pts_, closed, k))
    for k in range(len(solid)):                          # remaining = closed loops of degree-2 nodes
        if not used[k]:
            pts_, closed = walk(k, 0)
            chains.append((pts_, True, k))
    loose = [i for i in range(len(segs)) if segs[i].get('dash')]
    return [(c, cl, solid[k]) for c, cl, k in chains], loose


def _fit_circle(P):
    A = np.c_[2 * P[:, 0], 2 * P[:, 1], np.ones(len(P))]
    b = (P ** 2).sum(1)
    try:
        sol, *_ = np.linalg.lstsq(A, b, rcond=None)
    except Exception:
        return None
    cx, cy = sol[0], sol[1]
    r2 = sol[2] + cx * cx + cy * cy
    if r2 <= 0:
        return None
    r = math.sqrt(r2)
    rms = float(np.sqrt(np.mean((np.hypot(P[:, 0] - cx, P[:, 1] - cy) - r) ** 2)))
    return cx, cy, r, rms


def _bez_arc(cx, cy, r, a0, a1):
    """cubic Bezier for the circle arc a0 -> a1 (rad, a1 - a0 <= pi/2)"""
    k = 4.0 / 3.0 * math.tan((a1 - a0) / 4.0)
    p0 = (cx + r * math.cos(a0), cy + r * math.sin(a0)); p3 = (cx + r * math.cos(a1), cy + r * math.sin(a1))
    p1 = (p0[0] - k * r * math.sin(a0), p0[1] + k * r * math.cos(a0)); p2 = (p3[0] + k * r * math.sin(a1), p3[1] - k * r * math.cos(a1))
    return [p0, p1, p2, p3]


def _items(pts, closed):
    """polyline points -> items [('l', [p, q]) | ('c', [4 pts])] with arcs fitted"""
    n = len(pts)
    if n < 4:
        return [('l', [pts[i], pts[i + 1]]) for i in range(n - 1)] + ([('l', [pts[-1], pts[0]])] if closed and n > 2 else []), 0
    P = np.array(pts, float)
    E = np.diff(P, axis=0)
    L = np.hypot(E[:, 0], E[:, 1])
    ang = np.arctan2(E[:, 1], E[:, 0])
    turn = (np.diff(ang) + np.pi) % (2 * np.pi) - np.pi
    items, i, narc = [], 0, 0
    ne = len(E)
    while i < ne:
        j = i
        # grow a run of short, same-sign, gently turning edges
        best = None
        if L[i] <= MAXE:
            j = i + 1
            sign = 0
            while j < ne and L[j] <= MAXE:
                t = turn[j - 1]
                if abs(t) > math.radians(45) or abs(t) < 1e-3:
                    break
                sg = 1 if t > 0 else -1
                if sign and sg != sign:
                    break
                sign = sg
                j += 1
                if j - i >= 3:
                    fc = _fit_circle(P[i:j + 1])
                    # an edge of a traced arc is a chord: its sagitta L^2 / 8r must stay within the tracing tolerance (a long straight edge between two points on a circle is no arc)
                    if fc and fc[3] <= 0.3 and 1.2 <= fc[2] <= 3000 and abs(np.sum(turn[i:j - 1])) >= MINTURN and float((L[i:j] ** 2 / (8 * fc[2])).max()) <= SAG:
                        best = (j, fc)
                    elif best:
                        break
        if best:
            j, (cx, cy, r, rms) = best
            Q = P[i:j + 1]
            a_start = math.atan2(Q[0, 1] - cy, Q[0, 0] - cx); a_end = math.atan2(Q[-1, 1] - cy, Q[-1, 0] - cx)
            ccw = np.sum(turn[i:j - 1]) > 0
            d = (a_end - a_start) % (2 * math.pi)
            if not ccw:
                d = d - 2 * math.pi
            nseg = max(1, int(math.ceil(abs(d) / (math.pi / 2))))
            bz = [_bez_arc(cx, cy, r, a_start + d * q / nseg, a_start + d * (q + 1) / nseg) for q in range(nseg)]
            # self-check: every traced vertex of the run must lie within 0.5 pt of the fitted curve, else keep the polyline (wrong turning sense / full circle)
            rad = np.hypot(Q[:, 0] - cx, Q[:, 1] - cy)
            ang_q = np.arctan2(Q[:, 1] - cy, Q[:, 0] - cx)
            sweep = ((ang_q - a_start) * (1 if d > 0 else -1)) % (2 * math.pi)             # angle travelled in the sweep direction
            mono = bool(np.all(np.diff(sweep) > -1e-6)) and sweep[-1] <= abs(d) + 1e-3
            dist = np.where(mono, np.abs(rad - r), 99.0)
            if dist.max() <= 0.5:
                items.extend(('c', b_) for b_ in bz)
                narc += 1
            else:
                items.extend(('l', [tuple(P[q]), tuple(P[q + 1])]) for q in range(i, j))
            i = j
        else:
            items.append(('l', [tuple(P[i]), tuple(P[i + 1])]))
            i += 1
    if closed and n > 2 and math.dist(pts[0], pts[-1]) > 0.05:
        items.append(('l', [pts[-1], pts[0]]))
    return items, narc


def group(segs):
    """-> list of dict(items=[(kind, pts)], closed, w, kind(source), dash) ; also stats.  Closed contours (rings / filled outlines) of the vectoriser are written as they were
    traced (closed paths, arcs fitted on their polygon BEFORE the collinear merge); the loose strokes are chained."""
    contours = getattr(segs, 'contours', ())
    out = []
    narc = 0
    if contours:
        for pts, w, src in contours:
            it, na = _items([tuple(q) for q in pts], True)
            narc += na
            out.append(dict(items=it, closed=True, w=w, src=src, dash=''))
        segs = [q for q in segs if q['kind'] not in ('ring', 'blob')]
    ch, loose = _chains(segs)
    for pts, closed, k0 in ch:
        s = segs[k0]
        it, na = _items(pts, closed)
        narc += na
        out.append(dict(items=it, closed=closed, w=s['w'], src=s['kind'], dash=''))
    for i in loose:
        s = segs[i]
        out.append(dict(items=[('l', [tuple(s['a']), tuple(s['b'])])], closed=False, w=s['w'], src=s['kind'], dash=s['dash']))
    return out, dict(segments=len(segs) + sum(len(c[0]) for c in contours), paths=len(out), arcs=narc)


def flatten(paths, n=6):
    """paths -> flat segment list (for the mask benchmark): arcs as n chords"""
    out = []
    for p in paths:
        for kind, q in p['items']:
            if kind == 'l':
                out.append(dict(a=q[0], b=q[1], w=p['w'], dash=p['dash'], kind=p['src']))
            else:
                P = np.array(q, float)
                pts = [tuple((1 - t) ** 3 * P[0] + 3 * (1 - t) ** 2 * t * P[1] + 3 * (1 - t) * t * t * P[2] + t ** 3 * P[3]) for t in np.linspace(0, 1, n + 1)]
                for a, b in zip(pts, pts[1:]):
                    out.append(dict(a=a, b=b, w=p['w'], dash=p['dash'], kind=p['src']))
    return out
