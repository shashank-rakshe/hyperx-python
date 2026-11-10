"""
Own shell mesher for assemblies of flat plates (deck, girders, webs, brackets, floors, bulkheads, with openings).
No gmsh. Conforming by construction: no free nodes, no duplicate nodes, plates share nodes along every joint.

Pipeline
  1. each plate = planar polygon (outline + holes) in 3D, thickness t
  1b. bracket ties: a plate in a 1D stiffener's web plane with an edge along the web toe is pulled onto the beam
     line (tie_brackets) - 1D stiffeners have no web for the bracket to sit on
  2. gap closing: a plate edge lying within ~half the thicknesses of another plate's plane is snapped onto it
     (mid-surfaces of CAD solids stop t/2 short of the plate they sit on -> would be disconnected); also moulded-line
     offsets (edge drawn to the far face of the other plate: up to t_other + t/2)
  3. all plate-plate intersection lines are computed and clipped to both plates
  4. every boundary edge, joint line and beam line becomes a global segment; segments are split at every crossing /
     T-joint and de-duplicated; each knows the plates / beams it belongs to (SegGraph)
  4b. line clean-up on that one global graph (so every plate sees the same change): end points closer than snap_tol are
     welded, a point within snap_tol of another line is moved onto it (or the line bent through it) so near-collinear /
     overlapping lines become one, lines shorter than min_seg collapse to a point when all plates stay flat;
     then every line is discretised ONCE -> all plates of a joint get the very same nodes
  5. per plate: constrained Delaunay triangulation in the plate plane (fixed joint/boundary nodes + hex-grid interior points,
     constraint edges recovered by edge flips), Delaunay flips, smoothing
  6. triangles paired into quads, then every element split into quads (all-quad mesh, element size h);
     edge mid-nodes are shared through the global node registry
  6b. repair: nodes closer than snap_tol / 2 merged, elements with a corner < 5 deg / no area removed by collapsing
     their shortest side (global, never moving plate corners further than snap_tol, never inverting a neighbour)
  7. checks (free nodes, duplicates, connectivity, quality) - see meshcheck.py

Units mm. Plate dict: {"id": "DECK", "outline": [[x,y,z], ...], "holes": [[[x,y,z], ...]], "t": 12, "group": "deck"}
"""
import math
import numpy as np

from .mesh import Mesh


# ====================================================================== small geometry helpers
def _unit(v):
    n = np.linalg.norm(v)
    return v / n if n > 0 else v


def _newell(P):
    n = np.zeros(3)
    for i in range(len(P)):
        a, b = P[i], P[(i + 1) % len(P)]
        n += [(a[1] - b[1]) * (a[2] + b[2]), (a[2] - b[2]) * (a[0] + b[0]), (a[0] - b[0]) * (a[1] + b[1])]
    return _unit(n)


def _orient(a, b, c):
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])


def _seg_dist2d(P, a, b):
    """distance from points P (n,2) to segment ab"""
    ab = b - a
    L2 = float(ab @ ab) or 1e-30
    t = np.clip(((P - a) @ ab) / L2, 0, 1)
    return np.linalg.norm(P - (a + t[:, None] * ab), axis=1)


def _inside(P, loops):
    """even-odd ray casting for points P (n,2) against loops (outer + holes)"""
    P = np.atleast_2d(P)
    ins = np.zeros(len(P), bool)
    for L in loops:
        x0, y0 = L[:, 0], L[:, 1]
        x1, y1 = np.roll(x0, -1), np.roll(y0, -1)
        for i in range(len(L)):
            c = ((y0[i] > P[:, 1]) != (y1[i] > P[:, 1]))
            with np.errstate(divide='ignore', invalid='ignore'):
                xi = x0[i] + (P[:, 1] - y0[i]) * (x1[i] - x0[i]) / (y1[i] - y0[i])
            ins ^= c & (P[:, 0] < xi)
    return ins


class Registry:
    """global node registry: points closer than tol are the same node"""
    def __init__(self, tol):
        self.tol, self.cell = tol, tol * 4
        self.xyz, self.grid = [], {}

    def get(self, p):
        p = np.asarray(p, float)
        k = tuple(np.floor(p / self.cell).astype(int))
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for dz in (-1, 0, 1):
                    for i in self.grid.get((k[0] + dx, k[1] + dy, k[2] + dz), ()):
                        if np.linalg.norm(self.xyz[i] - p) <= self.tol:
                            return i
        self.xyz.append(p)
        self.grid.setdefault(k, []).append(len(self.xyz) - 1)
        return len(self.xyz) - 1


# ====================================================================== plates
class Plate:
    def __init__(self, d, tol):
        self.id = str(d.get('id', 'P'))
        self.group = str(d.get('group', self.id))
        self.t = float(d.get('t', 10.0))
        # round away float noise (2899.9999999999995 -> 2900): it would otherwise create near-duplicate nodes
        self.loops3 = [np.round(np.array(d['outline'], float), 6)] + [np.round(np.array(h, float), 6) for h in d.get('holes', []) or []]
        for L in self.loops3:
            if len(L) < 3:
                raise ValueError(f'plate {self.id}: a loop needs at least 3 points')
        self.frame(tol)

    def frame(self, tol):
        P = self.loops3[0]
        self.n = _newell(P)
        if not np.any(self.n):
            raise ValueError(f'plate {self.id}: degenerate outline')
        self.o = P[0].copy()
        e = P[1] - P[0]
        self.u = _unit(e - (e @ self.n) * self.n)
        self.v = np.cross(self.n, self.u)
        off = max(abs((Q - self.o) @ self.n).max() for Q in self.loops3)
        if off > max(tol * 5, 1e-3 * self.size()):
            raise ValueError(f'plate {self.id}: points are not in one plane (off by {off:.3g} mm)')
        self.loops2 = [np.c_[(L - self.o) @ self.u, (L - self.o) @ self.v] for L in self.loops3]
        self.bb = (np.min(np.vstack(self.loops3), 0) - tol, np.max(np.vstack(self.loops3), 0) + tol)

    def size(self):
        P = self.loops3[0]
        return float(np.linalg.norm(P.max(0) - P.min(0)))

    def to2(self, p):
        p = np.asarray(p) - self.o
        return np.array([p @ self.u, p @ self.v])

    def to3(self, q):
        return self.o + q[0] * self.u + q[1] * self.v

    def plane_dist(self, p):
        return float((np.asarray(p) - self.o) @ self.n)

    def in_or_on(self, q, tol):
        q = np.atleast_2d(q)
        ins = _inside(q, self.loops2)
        on = np.zeros(len(q), bool)
        for L in self.loops2:
            for i in range(len(L)):
                on |= _seg_dist2d(q, L[i], L[(i + 1) % len(L)]) <= tol
        return ins | on

    def edges3(self):
        for L in self.loops3:
            for i in range(len(L)):
                yield L[i], L[(i + 1) % len(L)]


def close_gaps(plates, tol, factor=0.75, moulded=True):
    """snap plate vertices that sit just off another plate's plane onto that plane.
    gap reached: factor * (tP + tQ) / 2 (mid-surfaces of CAD solids stop t/2 short) and, with moulded=True, also
    tQ + tP / 2 (moulded-line offsets: the plate was drawn to the far face of the plate it sits on). A vertex is only moved
    when its plate reaches well away from Q (so a small plate lying flat near Q is not squashed onto it)."""
    moved = 0
    for P in plates:
        allv = np.vstack(P.loops3)
        for Q in plates:
            if P is Q or abs(P.n @ Q.n) > 0.98:
                continue
            if np.any(P.bb[1] + 50 + Q.t < Q.bb[0]) or np.any(Q.bb[1] + 50 + Q.t < P.bb[0]):
                continue
            gap = factor * (P.t + Q.t) / 2 + tol
            if moulded:
                gap = max(gap, 1.05 * Q.t + P.t / 2 + tol)
            d = Q.n - (Q.n @ P.n) * P.n                     # direction inside P's plane that changes distance to Q
            if np.linalg.norm(d) < 1e-6:
                continue
            d = _unit(d)
            far = np.abs((allv - Q.o) @ Q.n).max()
            if far <= 2 * gap:
                continue
            for L in P.loops3:
                for i in range(len(L)):
                    s = Q.plane_dist(L[i])
                    if tol < abs(s) <= gap:
                        p2 = L[i] - s / (d @ Q.n) * d
                        if Q.in_or_on(Q.to2(p2), gap)[0]:
                            L[i] = p2
                            moved += 1
        P.frame(tol)
    return moved


def tie_brackets(plates, beams, tol, reach=1.15):
    """1D stiffeners have no web, so a bracket welded to a stiffener web (same plane as the web, one edge along the web
    toe / flange) would float. Such an edge - parallel to the beam, in the web plane, at most reach * profile height (+ flange)
    from the beam line and on the side the web hangs to - is moved onto the beam line (projected into the bracket's plane).
    The bracket then meets the plate under the stiffener along the beam line and shares its nodes with plate and beam
    (the bracket area over the web depth stands in for the web there). Edges touching another plate are never moved.
    Returns [(plate id, beam id, distance mm)]."""
    out = []
    if not beams:
        return out
    BL = []
    for bm in beams:
        a, b = np.array(bm['a'], float), np.array(bm['b'], float)
        L = np.linalg.norm(b - a)
        if L <= tol:
            continue
        nrm = _unit(np.array(bm.get('normal', [0, 0, -1]), float))
        pr = bm.get('profile') or {}
        reach_mm = reach * float(pr.get('h', 0) or 0) + float(pr.get('tf', 0) or 0) + 10 * tol
        BL.append((a, (b - a) / L, L, nrm, reach_mm, str(bm.get('id', ''))))
    if not BL:
        return out

    def touches(p, P):
        for Q in plates:
            if Q is P or np.any(p < Q.bb[0] - Q.t) or np.any(p > Q.bb[1] + Q.t):
                continue
            if abs(Q.plane_dist(p)) <= Q.t / 2 + P.t / 2 + tol and Q.in_or_on(Q.to2(p), Q.t + tol)[0]:
                return True
        return False
    for P in plates:
        lo, hi = P.bb
        cand = []
        for a, dv, Lb, nrm, rch, bid in BL:
            if abs(P.n @ dv) > 0.035:                          # bracket plane must contain the beam direction
                continue
            if abs(P.n @ nrm) > 0.26:                          # ... and (roughly) the web direction
                continue
            off = P.plane_dist(a)
            if abs(off) > P.t + 30 + tol:                       # web plane = bracket plane (lapped: a few mm off)
                continue
            if np.any(np.minimum(a, a + dv * Lb) > hi + rch) or np.any(np.maximum(a, a + dv * Lb) < lo - rch):
                continue
            a_in = a - off * P.n                                  # beam line projected into the bracket plane
            w = _unit(nrm - (nrm @ P.n) * P.n - (nrm @ dv) * dv)  # web direction inside the bracket plane
            cand.append((a_in, dv, Lb, w, rch, bid))
        if not cand:
            continue
        n = len(P.loops3[0])
        for k in range(n):
            L3 = P.loops3[0]
            p, q = L3[k], L3[(k + 1) % n]
            e = q - p
            le = np.linalg.norm(e)
            if le <= 10 * tol:
                continue
            for a_in, dv, Lb, w, rch, bid in cand:
                if abs(e @ dv) / le < 0.985:
                    continue
                sp, sq = (p - a_in) @ w, (q - a_in) @ w
                tp, tq = (p - a_in) @ dv, (q - a_in) @ dv
                if not (5 * tol < sp <= rch and 5 * tol < sq <= rch):
                    continue
                ov = min(max(tp, tq), Lb) - max(min(tp, tq), 0)
                if ov < 0.5 * le:
                    continue
                if touches(p, P) or touches(q, P):
                    continue
                new = L3.copy()
                new[k] = p - sp * w
                new[(k + 1) % n] = q - sq * w
                old2 = P.loops2[0]
                q2 = np.c_[(new - P.o) @ P.u, (new - P.o) @ P.v]
                if abs(_area2(q2)) < 1e-3 * abs(_area2(old2)) or not _simple(q2) or np.sign(_area2(q2)) != np.sign(_area2(old2)):
                    continue
                P.loops3[0] = new
                P.frame(tol)
                out.append((P.id, bid, round(float(max(sp, sq)), 1)))
                break
    return out


def _area2(Q):
    x, y = Q[:, 0], Q[:, 1]
    return 0.5 * float(x @ np.roll(y, -1) - y @ np.roll(x, -1))


def _simple(Q):
    """polygon without self-crossings (2D)"""
    n = len(Q)
    for i in range(n):
        a, b = Q[i], Q[(i + 1) % n]
        for j in range(i + 2, n):
            if i == 0 and j == n - 1:
                continue
            c, d = Q[j], Q[(j + 1) % n]
            if (_orient(a, b, c) * _orient(a, b, d) < 0) and (_orient(c, d, a) * _orient(c, d, b) < 0):
                return False
    return True


def intersections(plates, tol):
    """joint segments between every pair of non-parallel plates"""
    segs = []
    for i, A in enumerate(plates):
        for B in plates[i + 1:]:
            if np.any(A.bb[1] < B.bb[0]) or np.any(B.bb[1] < A.bb[0]):
                continue
            d = np.cross(A.n, B.n)
            if np.linalg.norm(d) < 1e-6:
                continue
            d = _unit(d)
            M = np.array([A.n, B.n, d])
            p0 = np.linalg.solve(M, [A.n @ A.o, B.n @ B.o, d @ A.o])
            ss = []
            for X in (A, B):                              # break points: line x every edge of both plates
                q0, qd = X.to2(p0), np.array([d @ X.u, d @ X.v])
                for L in X.loops2:
                    for k in range(len(L)):
                        a, b = L[k], L[(k + 1) % len(L)]
                        e = b - a
                        den = qd[0] * (-e[1]) - qd[1] * (-e[0])
                        if abs(den) < 1e-12:              # parallel: take endpoints if collinear
                            for c in (a, b):
                                if abs(_orient(q0, q0 + qd, c)) < tol:
                                    ss.append(float((c - q0) @ qd))
                            continue
                        r = a - q0
                        s = (r[0] * (-e[1]) - r[1] * (-e[0])) / den
                        w = (qd[0] * r[1] - qd[1] * r[0]) / den
                        if -1e-9 <= w <= 1 + 1e-9:
                            ss.append(s)
            ss = sorted(set(round(s, 6) for s in ss))
            runs = []
            for s0, s1 in zip(ss[:-1], ss[1:]):
                if s1 - s0 < tol:
                    continue
                m = p0 + d * (s0 + s1) / 2
                if A.in_or_on(A.to2(m), tol)[0] and B.in_or_on(B.to2(m), tol)[0]:
                    if runs and abs(runs[-1][1] - s0) < tol:
                        runs[-1][1] = s1
                    else:
                        runs.append([s0, s1])
            segs += [(p0 + d * r0, p0 + d * r1) for r0, r1 in runs]
    return segs


def split_segments(segs, tol):
    """split every segment at the end points of others lying on it and at proper crossings; de-duplicate"""
    segs = [(np.asarray(a, float), np.asarray(b, float)) for a, b in segs if np.linalg.norm(np.subtract(b, a)) > tol]
    cuts = [[0.0, 1.0] for _ in segs]
    lo = np.array([np.minimum(a, b) for a, b in segs]) - tol
    hi = np.array([np.maximum(a, b) for a, b in segs]) + tol
    for i, (a, b) in enumerate(segs):
        ab = b - a
        L2 = ab @ ab
        near = np.where(np.all(lo <= hi[i], 1) & np.all(hi >= lo[i], 1))[0]
        for j in near:
            if j == i:
                continue
            c, e = segs[j]
            for p in (c, e):                                    # T-joint: an end point of j on i
                t = ((p - a) @ ab) / L2
                if 1e-9 < t < 1 - 1e-9 and np.linalg.norm(a + t * ab - p) <= tol:
                    cuts[i].append(t)
            ce = e - c                                          # crossing
            w0 = a - c
            A_, B_, C_ = ab @ ab, ab @ ce, ce @ ce
            D_, E_ = ab @ w0, ce @ w0
            den = A_ * C_ - B_ * B_
            if den > 1e-12 * A_ * C_:
                s = (B_ * E_ - C_ * D_) / den
                u = (A_ * E_ - B_ * D_) / den
                if 1e-9 < s < 1 - 1e-9 and -1e-9 <= u <= 1 + 1e-9 and np.linalg.norm((a + s * ab) - (c + u * ce)) <= tol:
                    cuts[i].append(s)
    out, seen = [], set()
    for (a, b), cs in zip(segs, cuts):
        cs = sorted(cs)
        for s0, s1 in zip(cs[:-1], cs[1:]):
            p, q = a + s0 * (b - a), a + s1 * (b - a)
            if np.linalg.norm(q - p) <= tol:
                continue
            k = tuple(sorted([tuple(np.round(p / tol).astype(int)), tuple(np.round(q / tol).astype(int))]))
            if k not in seen:
                seen.add(k)
                out.append((p, q))
    return out


# ====================================================================== 2D constrained triangulation
def _delaunay(P):
    try:
        from scipy.spatial import Delaunay
        tri = Delaunay(P)
        return [list(t) for t in tri.simplices]
    except ImportError:
        return _bowyer_watson(P)


def _bowyer_watson(P):
    n = len(P)
    c, r = P.mean(0), np.ptp(P, 0).max() * 10 + 1
    pts = np.vstack([P, [c + [-r, -r], c + [r, -r], c + [0, r]]])
    tris = [(n, n + 1, n + 2)]

    def circ(t):
        a, b, cc = pts[list(t)]
        d = 2 * (a[0] * (b[1] - cc[1]) + b[0] * (cc[1] - a[1]) + cc[0] * (a[1] - b[1]))
        ux = ((a @ a) * (b[1] - cc[1]) + (b @ b) * (cc[1] - a[1]) + (cc @ cc) * (a[1] - b[1])) / d
        uy = ((a @ a) * (cc[0] - b[0]) + (b @ b) * (a[0] - cc[0]) + (cc @ cc) * (b[0] - a[0])) / d
        return np.array([ux, uy]), (a[0] - ux) ** 2 + (a[1] - uy) ** 2
    cache = {tris[0]: circ(tris[0])}
    for i in range(n):
        p = pts[i]
        bad = [t for t in tris if ((p - cache[t][0]) ** 2).sum() < cache[t][1]]
        edges = {}
        for t in bad:
            for e in ((t[0], t[1]), (t[1], t[2]), (t[2], t[0])):
                k = tuple(sorted(e))
                edges[k] = None if k in edges else e
        tris = [t for t in tris if t not in bad]
        for e in edges.values():
            if e:
                t = (e[0], e[1], i)
                if _orient(pts[t[0]], pts[t[1]], pts[t[2]]) < 0:
                    t = (e[1], e[0], i)
                tris.append(t)
                cache[t] = circ(t)
    return [list(t) for t in tris if max(t) < n]


class Tri2D:
    def __init__(self, P, tris):
        self.P = P
        self.T = [list(t) if _orient(P[t[0]], P[t[1]], P[t[2]]) > 0 else [t[0], t[2], t[1]] for t in tris]
        self.rebuild()

    def rebuild(self):
        self.E = {}
        for i, t in enumerate(self.T):
            if t is None:
                continue
            for k in range(3):
                self.E.setdefault(tuple(sorted((t[k], t[(k + 1) % 3]))), []).append(i)

    def _third(self, ti, a, b):
        return next(v for v in self.T[ti] if v != a and v != b)

    def flip(self, a, b):
        """flip edge ab shared by two triangles if the quad is strictly convex; returns new edge or None"""
        ts = self.E.get(tuple(sorted((a, b))), [])
        if len(ts) != 2:
            return None
        r, s = self._third(ts[0], a, b), self._third(ts[1], a, b)
        P = self.P
        o1, o2 = _orient(P[r], P[s], P[a]), _orient(P[r], P[s], P[b])
        o3, o4 = _orient(P[a], P[b], P[r]), _orient(P[a], P[b], P[s])
        if not (o1 * o2 < 0 and o3 * o4 < 0):
            return None
        t1, t2 = [r, s, a], [s, r, b]
        for t in (t1, t2):
            if _orient(P[t[0]], P[t[1]], P[t[2]]) < 0:
                t[1], t[2] = t[2], t[1]
        i, j = ts
        for k in (tuple(sorted((a, b))),):
            del self.E[k]
        for ti, old in ((i, self.T[i]), (j, self.T[j])):
            for m in range(3):
                e = tuple(sorted((old[m], old[(m + 1) % 3])))
                if e in self.E and ti in self.E[e]:
                    self.E[e].remove(ti)
        self.T[i], self.T[j] = t1, t2
        for ti in (i, j):
            t = self.T[ti]
            for m in range(3):
                self.E.setdefault(tuple(sorted((t[m], t[(m + 1) % 3]))), []).append(ti)
        return (r, s)

    def recover(self, a, b, max_iter=5000):
        P = self.P
        if tuple(sorted((a, b))) in self.E:
            return True

        def crosses(e):
            p, q = e
            if len({p, q, a, b}) < 4:
                return False
            return _orient(P[a], P[b], P[p]) * _orient(P[a], P[b], P[q]) < 0 and _orient(P[p], P[q], P[a]) * _orient(P[p], P[q], P[b]) < 0
        queue = [e for e in self.E if crosses(e)]
        it = 0
        while queue and it < max_iter:
            it += 1
            e = queue.pop(0)
            if e not in self.E:
                continue
            ne = self.flip(*e)
            if ne is None:
                queue.append(e)
            elif crosses(ne):
                queue.append(tuple(sorted(ne)))
        return tuple(sorted((a, b))) in self.E

    def incircle_flips(self, fixed, max_pass=20):
        P = self.P
        for _ in range(max_pass):
            n = 0
            for e in list(self.E):
                if e in fixed or e not in self.E or len(self.E[e]) != 2:
                    continue
                a, b = e
                r, s = self._third(self.E[e][0], a, b), self._third(self.E[e][1], a, b)
                A, B, C, D = P[a], P[b], P[r], P[s]
                t = [a, b, r] if _orient(A, B, C) > 0 else [b, a, r]
                pa, pb, pc = P[t[0]] - D, P[t[1]] - D, P[t[2]] - D
                det = ((pa @ pa) * (pb[0] * pc[1] - pb[1] * pc[0]) - (pb @ pb) * (pa[0] * pc[1] - pa[1] * pc[0])
                       + (pc @ pc) * (pa[0] * pb[1] - pa[1] * pb[0]))
                if det > 1e-9 * (np.ptp(P, 0).max() ** 4 + 1) and self.flip(a, b):
                    n += 1
            if not n:
                break


def _quad_score(Q):
    """1 = perfect square corners, 0 = a 180 / 0 degree corner; negative = not convex"""
    worst = 1.0
    for k in range(4):
        a, b, c = Q[k - 1], Q[k], Q[(k + 1) % 4]
        if _orient(a, b, c) <= 0:
            return -1
        u, v = a - b, c - b
        ang = math.degrees(math.acos(max(-1, min(1, (u @ v) / (np.linalg.norm(u) * np.linalg.norm(v) + 1e-30)))))
        worst = min(worst, 1 - abs(ang - 90) / 90)
    return worst


# ====================================================================== global segment graph (joint + boundary lines)
def _close_pairs(X, r):
    """index pairs (i < j) of points closer than r (spatial hash)"""
    X = np.asarray(X, float)
    if len(X) < 2 or r <= 0:
        return []
    cell, grid, out = r, {}, []
    keys = np.floor(X / cell).astype(int)
    for i, k in enumerate(map(tuple, keys)):
        grid.setdefault(k, []).append(i)
    for k, mem in grid.items():
        near = [j for dx in (-1, 0, 1) for dy in (-1, 0, 1) for dz in (-1, 0, 1) for j in grid.get((k[0] + dx, k[1] + dy, k[2] + dz), ())]
        near = np.array(near)
        for i in mem:
            js = near[near > i]
            if len(js):
                d = np.linalg.norm(X[js] - X[i], axis=1)
                out += [(i, int(j)) for j in js[d <= r]]
    return out


class _UF:
    def __init__(self, n):
        self.p = list(range(n))

    def find(self, a):
        while self.p[a] != a:
            self.p[a] = self.p[self.p[a]]
            a = self.p[a]
        return a

    def union(self, a, b):
        self.p[self.find(b)] = self.find(a)


def _seg_owners(plates, segs, beam_lines, tol):
    """which plates (and beams) each split segment belongs to: lies in the plate plane and inside / on the plate"""
    A = np.array([s[0] for s in segs], float).reshape(-1, 3)
    B = np.array([s[1] for s in segs], float).reshape(-1, 3)
    M = (A + B) / 2
    lo, hi = np.minimum(A, B), np.maximum(A, B)
    own_p = [set() for _ in segs]
    own_b = [set() for _ in segs]
    for pi, P in enumerate(plates):
        c = np.all(hi >= P.bb[0] - tol, 1) & np.all(lo <= P.bb[1] + tol, 1)
        c &= (np.abs((A - P.o) @ P.n) <= 2 * tol) & (np.abs((B - P.o) @ P.n) <= 2 * tol)
        idx = np.where(c)[0]
        if len(idx):
            q = np.c_[(M[idx] - P.o) @ P.u, (M[idx] - P.o) @ P.v]
            for k in idx[P.in_or_on(q, 2 * tol)]:
                own_p[k].add(pi)
    for bi, (a, b) in enumerate(beam_lines):
        d = b - a
        L = float(np.linalg.norm(d))
        if L <= tol:
            continue
        d = d / L
        ok = np.ones(len(segs), bool)
        for X in (A, B):
            s = (X - a) @ d
            r = np.linalg.norm(X - a - s[:, None] * d, axis=1)
            ok &= (r <= tol) & (s >= -tol) & (s <= L + tol)
        for k in np.where(ok)[0]:
            own_b[k].add(bi)
    return own_p, own_b


class SegGraph:
    """joint / boundary / beam lines of the whole assembly as one graph: vertices V, edges {(i, j): [plates, beams]}.
    Every rule here acts on the global graph, so all plates sharing a line see the very same change (nodes stay shared)."""

    def __init__(self, segs, own_p, own_b, tol):
        reg = Registry(tol)
        self.E = {}
        for (a, b), op, ob in zip(segs, own_p, own_b):
            if not op and not ob:
                continue
            i, j = reg.get(a), reg.get(b)
            if i != j:
                self._add(self.E, i, j, op, ob)
        self.V = [np.array(p, float) for p in reg.xyz]
        self.stats = {'welded_points': 0, 'split_at_points': 0, 'collapsed_short': 0}

    @staticmethod
    def _add(E, i, j, op, ob):
        k = (i, j) if i < j else (j, i)
        if k in E:
            E[k][0] |= op
            E[k][1] |= ob
        else:
            E[k] = [set(op), set(ob)]

    def _rekey(self, mp):
        E2 = {}
        for (i, j), (op, ob) in self.E.items():
            i2, j2 = mp.get(i, i), mp.get(j, j)
            if i2 != j2:
                self._add(E2, i2, j2, op, ob)
        self.E = E2

    def incident(self):
        ip, ib = {}, {}
        for (i, j), (op, ob) in self.E.items():
            for v in (i, j):
                ip.setdefault(v, set()).update(op)
                ib.setdefault(v, set()).update(ob)
        return ip, ib

    def used(self):
        return sorted({v for k in self.E for v in k})

    def weld(self, r):
        """points closer than r become one point; the point fixed by the most plates / beams is kept"""
        used = self.used()
        pairs = _close_pairs([self.V[v] for v in used], r)
        if not pairs:
            return 0
        uf = _UF(len(used))
        for a, b in pairs:
            uf.union(a, b)
        ip, ib = self.incident()
        cl = {}
        for k, v in enumerate(used):
            cl.setdefault(uf.find(k), []).append(v)
        mp = {}
        for mem in cl.values():
            if len(mem) > 1:
                keep = max(mem, key=lambda v: (len(ip.get(v, ())), len(ib.get(v, ())), -v))
                mp.update({v: keep for v in mem if v != keep})
        self._rekey(mp)
        self.stats['welded_points'] += len(mp)
        return len(mp)

    def _can_move(self, v, p, r, plates, beam_lines, ip, ib):
        """point v may go to p: p stays within r of the plane of every plate and of every beam line using v"""
        for k in ip.get(v, ()):
            if abs(plates[k].plane_dist(p)) > r:
                return False
        for k in ib.get(v, ()):
            a, b = beam_lines[k]
            d = _unit(b - a)
            w = p - a
            if np.linalg.norm(w - (w @ d) * d) > r:
                return False
        return True

    def split_near(self, r, plates, beam_lines):
        """a point lying within r of another line (end point a few mm off a joint line, near-collinear overlapping lines):
        the point is moved onto that line when it stays in the planes of its own plates (the line stays straight),
        otherwise - for small offsets only - the line is bent through the point. Either way both share the point and
        overlapping parts become one line."""
        used = self.used()
        if not used:
            return 0
        X = np.array([self.V[v] for v in used])
        ua = np.array(used)
        best = {}
        for (i, j) in self.E:
            a, b = self.V[i], self.V[j]
            d = b - a
            L2 = float(d @ d)
            lo, hi = np.minimum(a, b) - r, np.maximum(a, b) + r
            c = np.where(np.all(X >= lo, 1) & np.all(X <= hi, 1))[0]
            if not len(c):
                continue
            W = X[c] - a
            t = (W @ d) / L2
            dist = np.linalg.norm(W - t[:, None] * d, axis=1)
            for k in np.where((t > 1e-9) & (t < 1 - 1e-9) & (dist <= r))[0]:
                v = int(ua[c[k]])
                if v != i and v != j and (v not in best or dist[k] < best[v][0]):
                    best[v] = (float(dist[k]), (i, j), float(t[k]))
        if not best:
            return 0
        ip, ib = self.incident()
        tight = max(r * 0.1, 1e-9)
        on_edge = {}
        for v, (dist, k, t) in sorted(best.items(), key=lambda x: x[1][0]):
            i, j = k
            x = self.V[i] + t * (self.V[j] - self.V[i])
            if self._can_move(v, x, tight, plates, beam_lines, ip, ib):
                self.V[v] = x
            elif dist > r / 2:
                continue
            on_edge.setdefault(k, []).append((t, v))
        new, n = {}, 0
        for (i, j), (op, ob) in self.E.items():
            ts = on_edge.get((i, j))
            if ts:
                chain = [i] + [v for _, v in sorted(ts)] + [j]
                n += len(ts)
                for p, q in zip(chain[:-1], chain[1:]):
                    if p != q:
                        self._add(new, p, q, op, ob)
            else:
                self._add(new, i, j, op, ob)
        self.E = new
        self.stats['split_at_points'] += n
        return n

    def collapse_short(self, min_len, r, plates, beam_lines):
        """lines shorter than min_len become a point - only when the moved point stays (within r) in the plane of every
        plate and on every beam line that uses it"""
        total = 0
        for _ in range(20):
            ip, ib = self.incident()
            short = sorted((float(np.linalg.norm(self.V[i] - self.V[j])), i, j) for i, j in self.E)
            short = [s for s in short if s[0] < min_len]
            if not short:
                break
            touched, mp = set(), {}

            def ok(src, dst):
                p = self.V[dst]
                for k in ip.get(src, ()):
                    if abs(plates[k].plane_dist(p)) > r:
                        return False
                for k in ib.get(src, ()):
                    a, b = beam_lines[k]
                    d = _unit(b - a)
                    w = p - a
                    if np.linalg.norm(w - (w @ d) * d) > r:
                        return False
                return True
            for _, i, j in short:
                if i in touched or j in touched:
                    continue
                order = sorted([(j, i), (i, j)], key=lambda sd: (len(ip.get(sd[0], ())), len(ib.get(sd[0], ()))))
                for src, dst in order:
                    if ok(src, dst):
                        mp[src] = dst
                        touched.update((src, dst))
                        break
            if not mp:
                break
            self._rekey(mp)
            total += len(mp)
        self.stats['collapsed_short'] += total
        return total


# ====================================================================== mesher
def _keep_regions(T, P2, cons, loops2):
    """triangles inside the plate: regions bounded by joint / boundary lines are kept or dropped as a whole
    (robust when a boundary was snapped a few mm); a region that leaks (open boundary) falls back to the centroid test"""
    tris = [t for t in T.T if t is not None]
    if not tris:
        return []
    C = np.array([P2[t].mean(0) for t in tris])
    ins = _inside(C, loops2)
    area = np.array([abs(_orient(*P2[t])) for t in tris]) + 1e-30
    uf = _UF(len(tris))
    tri_of = {}
    for k, t in enumerate(tris):
        for m in range(3):
            tri_of.setdefault(tuple(sorted((t[m], t[(m + 1) % 3]))), []).append(k)
    for e, ts in tri_of.items():
        if len(ts) == 2 and e not in cons:
            uf.union(ts[0], ts[1])
    reg = {}
    for k in range(len(tris)):
        reg.setdefault(uf.find(k), []).append(k)
    keep = []
    for mem in reg.values():
        mem = np.array(mem)
        f = float(area[mem][ins[mem]].sum() / area[mem].sum())
        if f >= 0.95:
            keep += list(mem)
        elif f > 0.05:
            keep += list(mem[ins[mem]])
    return [tris[k] for k in sorted(keep)]


def mesh_plates(plates_in, h, tol=None, close_gap=True, all_quad=True, smooth=3, beams=None, snap_tol=None, min_seg=None,
                bracket_ties=True, repair=True):
    """beams: 1D stiffeners [{"id", "a": [x,y,z], "b": [x,y,z], "profile": {...}, "normal": [0,0,-1]}] - their lines are
    put into the plates' meshes so the CBARs share the plate nodes; offset = normal * (t_plate/2 + profile centroid)
    snap_tol   (default 5 % of h): joint / boundary line end points closer than this are one point; a point this close to
               another line splits it (near-collinear, overlapping or slightly offset lines become one line)
    min_seg    (default h / 10): shorter joint / boundary lines are collapsed to a point (when that keeps every plate flat)
    bracket_ties: plates (brackets) lying in a 1D stiffener's web plane with an edge along the web toe are pulled onto the
               beam line so they share nodes with beam and plate (see tie_brackets); report['bracket_ties'] lists them
    repair:    after meshing, nodes closer than snap_tol / 2 are merged and elements with a corner < 5 deg or ~no area are
               removed by collapsing their shortest side (globally, so nodes stay shared)"""
    h = float(h)
    beams = beams or []
    tol = tol or max(1e-3, h * 1e-3)
    snap = max(tol, 0.05 * h if snap_tol is None else float(snap_tol))
    min_len = h / 10 if min_seg is None else float(min_seg)
    plates, bad = [], []
    for d in plates_in:
        try:
            plates.append(Plate(d, tol))
        except ValueError as e:                       # one bad plate must not stop a whole ship model
            bad.append(str(e))
    if not plates:
        raise ValueError('no usable plates: ' + '; '.join(bad[:5]))
    ids = [p.id for p in plates]
    if len(set(ids)) != len(ids):
        raise ValueError('plate ids must be unique')
    ties = tie_brackets(plates, beams, tol) if bracket_ties and beams else []
    moved = close_gaps(plates, tol) if close_gap else 0
    H = 2 * h if all_quad else h                                   # triangles at 2h -> split -> quads at h
    beam_lines = [(np.array(b['a'], float), np.array(b['b'], float)) for b in beams]
    segs = [e for P in plates for e in P.edges3()] + intersections(plates, tol) + beam_lines
    segs = split_segments(segs, tol)
    own_p, own_b = _seg_owners(plates, segs, beam_lines, tol)
    G = SegGraph(segs, own_p, own_b, tol)
    if snap > tol:
        for _ in range(4):
            n = G.weld(snap) + G.split_near(snap, plates, beam_lines)
            if min_len > tol:
                n += G.collapse_short(min_len, snap, plates, beam_lines)
            if not n:
                break
    edges = list(G.E.items())
    reg = Registry(tol)
    vid = {}
    seg_nodes = []
    for (i, j), _ in edges:
        a, b = G.V[i], G.V[j]
        n = max(1, int(math.ceil(np.linalg.norm(b - a) / H - 1e-9)))
        seg_nodes.append([reg.get(a + (b - a) * k / n) for k in range(n + 1)])
    m = Mesh()
    m.plate_of_node = {}
    node_xyz = reg.xyz
    elems = []                                                     # (plate index, [global ids])
    on_seg = set(i for s in seg_nodes for i in s)
    report = {'plates': len(plates), 'joint_segments': len(edges), 'gap_snaps': moved, 'skipped': list(bad),
              'line_clean_up': dict(G.stats), 'bracket_ties': [list(t) for t in ties]}
    mine_of = [[] for _ in plates]
    for ((i, j), (op, ob)), ns in zip(edges, seg_nodes):
        for pi in op:
            mine_of[pi].append(ns)
    for pi, P in enumerate(plates):
        mine = [ns for ns in mine_of[pi] if len(set(ns)) > 1]
        fixed_ids = sorted(set(i for ns in mine for i in ns))
        loc = {g: k for k, g in enumerate(fixed_ids)}
        pts = [P.to2(node_xyz[g]) for g in fixed_ids]
        cons = set(tuple(sorted((loc[ns[k]], loc[ns[k + 1]]))) for ns in mine for k in range(len(ns) - 1) if ns[k] != ns[k + 1])
        # interior points on a hex grid, kept away from constraints
        allp = np.vstack(P.loops2)
        lo, hi = allp.min(0), allp.max(0)
        dy = H * math.sqrt(3) / 2
        ys = np.arange(lo[1] + dy / 2, hi[1], dy)
        grid = [(x + (H / 2 if r % 2 else 0), y) for r, y in enumerate(ys) for x in np.arange(lo[0] + H / 2, hi[0], H)]
        Gp = np.array(grid) if grid else np.zeros((0, 2))
        if len(Gp) and pts:
            Gp = Gp[_inside(Gp, P.loops2)]
            F = np.array(pts)
            dmin = np.full(len(Gp), np.inf)
            for (i, j) in cons:
                dmin = np.minimum(dmin, _seg_dist2d(Gp, F[i], F[j]))
            Gp = Gp[dmin > 0.6 * H]
        P2 = np.vstack([np.array(pts).reshape(-1, 2), Gp]) if len(Gp) else np.array(pts).reshape(-1, 2)
        if len(P2) < 3:
            report['skipped'].append(P.id)
            continue
        try:
            T = Tri2D(P2, _delaunay(P2))
        except Exception as ex:                       # degenerate plate (all points in a line): skip, report
            report['skipped'].append(f'{P.id}: could not be triangulated ({type(ex).__name__})')
            continue
        lost = [c for c in cons if not T.recover(*c)]
        if lost:
            report['skipped'].append(f'{P.id}: {len(lost)} joint/boundary edges could not be kept - try a smaller element size')
            continue
        T.incircle_flips(cons)
        keep = _keep_regions(T, P2, cons, P.loops2)
        # Laplacian smoothing of interior points (never inverts a triangle)
        nfix = len(pts)
        if smooth and len(P2) > nfix:
            nb = {}
            for t in keep:
                for k in range(3):
                    nb.setdefault(t[k], set()).update((t[k - 1], t[(k + 1) % 3]))
            for _ in range(smooth):
                for i in range(nfix, len(P2)):
                    if i not in nb:
                        continue
                    old = P2[i].copy()
                    P2[i] = P2[list(nb[i])].mean(0)
                    if any(_orient(*P2[t]) <= 0 for t in keep if i in t):
                        P2[i] = old
        # pair triangles into quads (never across a joint/boundary edge)
        cand = []
        tri_of = {}
        for ti, t in enumerate(keep):
            for k in range(3):
                tri_of.setdefault(tuple(sorted((t[k], t[(k + 1) % 3]))), []).append(ti)
        for e, ts in tri_of.items():
            if len(ts) == 2 and e not in cons:
                a, b = e
                t1 = keep[ts[0]]
                k = t1.index(a)
                p, q = (a, b) if t1[(k + 1) % 3] == b else (b, a)            # p->q is CCW in t1
                r = next(v for v in t1 if v not in e)
                s = next(v for v in keep[ts[1]] if v not in e)
                quad = [p, s, q, r]
                sc = _quad_score(P2[quad])
                if sc > 0.35:
                    cand.append((sc, ts[0], ts[1], quad))
        cand.sort(key=lambda x: -x[0])
        used, faces = set(), []
        for sc, i, j, quad in cand:
            if i not in used and j not in used:
                used.update((i, j))
                faces.append(quad)
        faces += [t for ti, t in enumerate(keep) if ti not in used]
        gid = {}
        for k in range(len(P2)):
            gid[k] = fixed_ids[k] if k < nfix else reg.get(P.to3(P2[k]))

        for f in faces:
            G_ = [gid[i] for i in f]
            if not all_quad:
                elems.append((pi, G_))
                continue
            X = [node_xyz[g] for g in G_]
            c = reg.get(np.mean(X, 0))
            mids = [reg.get((X[k] + X[(k + 1) % len(X)]) / 2) for k in range(len(X))]
            for k in range(len(X)):                                  # mid-nodes on boundary / joint lines stay put
                if tuple(sorted((f[k], f[(k + 1) % len(f)]))) in cons:
                    on_seg.add(mids[k])
            for k in range(len(X)):
                elems.append((pi, [G_[k], mids[k], c, mids[k - 1]]))
    # 1D beams along their (split, cleaned, discretised) lines, through the same mid-nodes as the shells
    from .mesh import profile_props
    bar_elems = []
    for ((i, j), (op, ob)), ns in zip(edges, seg_nodes):
        for bi in ob:
            chain = ns
            if all_quad:
                chain = []
                for k in range(len(ns) - 1):
                    chain += [ns[k], reg.get((node_xyz[ns[k]] + node_xyz[ns[k + 1]]) / 2)]
                chain.append(ns[-1])
            for k in range(len(chain) - 1):
                if chain[k] != chain[k + 1]:
                    bar_elems.append((bi, chain[k], chain[k + 1]))
                    on_seg.update((chain[k], chain[k + 1]))
    if repair:
        corners = set(ns[0] for ns in seg_nodes) | set(ns[-1] for ns in seg_nodes)
        line_of = {}
        for k, ns in enumerate(seg_nodes):
            for g in ns:
                line_of.setdefault(g, set()).add(k)
            for a_, b_ in zip(ns[:-1], ns[1:]):
                g = reg.get((node_xyz[a_] + node_xyz[b_]) / 2)
                if g in on_seg:
                    line_of.setdefault(g, set()).add(k)
        elems, bar_elems, rep = _repair(node_xyz, elems, bar_elems, plates, on_seg, max(tol, snap / 2), corners, line_of, corner_move=snap)
        report['repair'] = rep
    # renumber only used nodes (no free nodes by construction)
    used_nodes = sorted(set(g for _, e in elems for g in e) | set(g for _, a_, b_ in bar_elems for g in (a_, b_)))
    new = {g: k + 1 for k, g in enumerate(used_nodes)}
    m.xyz = [tuple(round(float(c), 4) for c in node_xyz[g]) for g in used_nodes]
    m.nodes = {p: i + 1 for i, p in enumerate(m.xyz)}
    pid_of = {}
    for pi, P in enumerate(plates):
        key = (P.group, P.t)
        if key not in pid_of:
            pid_of[key] = len(pid_of) + 1
            m.props[pid_of[key]] = {'kind': 'shell', 't': P.t, 'name': P.group}
    for pi, e in elems:
        P = plates[pi]
        m.add('quad' if len(e) == 4 else 'tri', [new[g] for g in e], pid_of[(P.group, P.t)], P.id)
    by_beam = {}
    for b_i, n1, n2 in bar_elems:
        by_beam.setdefault(b_i, []).append((n1, n2))
    for bi, bm in enumerate(beams):
        sp = profile_props(bm['profile'])
        nrm = _unit(np.array(bm.get('normal', [0, 0, -1]), float))
        mid_pt = (beam_lines[bi][0] + beam_lines[bi][1]) / 2
        host = [P for P in plates if abs(P.plane_dist(mid_pt)) <= 2 * snap and P.in_or_on(P.to2(mid_pt), 2 * tol)[0]]
        tp = max((P.t for P in host), default=0.0)
        off = nrm * (tp / 2 + sp['zc'])
        pid = 1000 + bi
        m.props[pid] = {'kind': 'bar', 'A': sp['A'], 'I1': sp['I_vert'], 'I2': sp['I_lat'], 'J': sp['J'], 'offset': float(-(tp / 2 + sp['zc'])),
                        'name': str(bm.get('id', f'BEAM{bi + 1}'))}
        for n1, n2 in by_beam.get(bi, ()):
            m.add('bar', [new[n1], new[n2]], pid, str(bm.get('id', f'BEAM{bi + 1}')), orient=tuple(-nrm), offset=tuple(off))
    if all_quad and smooth:
        _smooth3d(m, plates, set(new[g] for g in on_seg if g in new))
    m.plates = plates
    m.report = report
    return m


def _elem_quality(X, e, plate):
    """(min corner angle deg, area, inverted?) of a shell element in its plate's plane"""
    Q = np.array([plate.to2(X[g]) for g in e])
    n = len(Q)
    area = _area2(Q)
    amin, inv = 180.0, False
    for k in range(n):
        a, b, c = Q[k - 1], Q[k], Q[(k + 1) % n]
        if _orient(a, b, c) <= 0:
            inv = True
        u, v = a - b, c - b
        nu, nv = np.linalg.norm(u), np.linalg.norm(v)
        if nu == 0 or nv == 0:
            return 0.0, 0.0, True
        amin = min(amin, math.degrees(math.acos(max(-1, min(1, (u @ v) / (nu * nv))))))
    return amin, area, inv


def _repair(X, elems, bars, plates, fixed, weld_tol, corners=(), line_of=None, min_angle=5.0, rounds=6, corner_move=0.0):
    """global clean-up of the finished mesh: merge nodes closer than weld_tol, then remove elements with a corner below
    min_angle / no area by collapsing their shortest side. Every merge renames a node in ALL elements (and beams), so
    plates stay joined; a merge is undone if it would turn a neighbouring element inside out. Joint / boundary line end
    points (corners) never move; other nodes on a line only slide along that same line."""
    line_of = line_of or {}

    def movable(src, dst):
        if src in corners:                       # a corner only moves as far as the line clean-up may move it
            return dst in fixed and np.linalg.norm(X[src] - X[dst]) <= corner_move
        if src not in fixed:
            return True
        return bool(line_of.get(src, set()) & line_of.get(dst, set()))
    rep = {'merged_close_nodes': 0, 'collapsed_bad_elements': 0, 'removed_elements': 0}
    alias = {}

    def root(g):
        while g in alias:
            g = alias[g]
        return g

    def clean(e):
        out = []
        for g in e:
            g = root(g)
            if not out or out[-1] != g:
                out.append(g)
        while len(out) > 1 and out[0] == out[-1]:
            out.pop()
        return out
    used = sorted(set(g for _, e in elems for g in e) | set(g for _, a, b in bars for g in (a, b)))
    pairs = _close_pairs([X[g] for g in used], weld_tol)
    uf = _UF(len(used))
    for a, b in pairs:
        uf.union(a, b)
    cl = {}
    for k, g in enumerate(used):
        cl.setdefault(uf.find(k), []).append(g)
    for mem in cl.values():
        if len(mem) > 1:
            keep = min(mem, key=lambda g: (g not in corners, g not in fixed, g))
            for g in mem:
                if g != keep and (g not in corners or np.linalg.norm(X[g] - X[keep]) <= weld_tol / 4):
                    alias[g] = keep
                    rep['merged_close_nodes'] += 1
    for _ in range(rounds):
        cur = []
        for pi, e in elems:
            e2 = clean(e)
            if len(e2) >= 3:
                cur.append((pi, e2))
            else:
                rep['removed_elements'] += 1
        elems = cur
        of_node = {}
        for k, (pi, e) in enumerate(elems):
            for g in e:
                of_node.setdefault(g, []).append(k)
        n_fix = 0
        dead = set()
        for k, (pi, e) in enumerate(elems):
            if k in dead or any(g in alias for g in e):
                continue
            amin, area, inv = _elem_quality(X, e, plates[pi])
            L = [np.linalg.norm(X[e[(m + 1) % len(e)]] - X[e[m]]) for m in range(len(e))]
            if amin >= min_angle and not inv and abs(area) > 1e-6 * max(L) ** 2:
                continue
            for m in np.argsort(L):
                a, b = e[m], e[(m + 1) % len(e)]
                for src, dst in ((b, a), (a, b)) if (a in fixed) >= (b in fixed) else ((a, b), (b, a)):
                    if not movable(src, dst):
                        continue
                    ok = True
                    for kk in of_node.get(src, ()):
                        if kk == k:
                            continue
                        pj, ej = elems[kk]
                        ej0 = clean(ej)
                        ej2 = clean([dst if root(g) == src else g for g in ej])
                        if len(ej2) < 3:
                            continue                         # vanishes
                        L2 = max(np.linalg.norm(X[ej2[(m2 + 1) % len(ej2)]] - X[ej2[m2]]) for m2 in range(len(ej2)))
                        a2, ar2, inv2 = _elem_quality(X, ej2, plates[pj])
                        bad2 = inv2 or abs(ar2) <= 1e-6 * L2 ** 2
                        if bad2 and len(ej0) >= 3:
                            a0, ar0, inv0 = _elem_quality(X, ej0, plates[pj])
                            bad2 = not inv0                  # only refuse to make a good neighbour bad
                        if bad2:
                            ok = False
                            break
                    if ok:
                        alias[src] = dst
                        dead.update(of_node.get(src, ()))
                        n_fix += 1
                        break
                else:
                    continue
                break
        rep['collapsed_bad_elements'] += n_fix
        if not n_fix:
            break
    cur = []
    for pi, e in elems:
        e2 = clean(e)
        if len(e2) >= 3:
            L = max(np.linalg.norm(X[e2[(m + 1) % len(e2)]] - X[e2[m]]) for m in range(len(e2)))
            if abs(_elem_quality(X, e2, plates[pi])[1]) > 1e-4 * L ** 2:
                cur.append((pi, e2))
                continue
            rep['dropped_zero_area'] = rep.get('dropped_zero_area', 0) + 1     # flat sliver: no area, nothing lost
        rep['removed_elements'] += 1
    nb = []
    for bi, a, b in bars:
        a, b = root(a), root(b)
        if a != b:
            nb.append((bi, a, b))
    return cur, nb, rep


def _smooth3d(m, plates, fixed, iters=3):
    """Laplacian smoothing of nodes interior to one plate, done in that plate's plane"""
    owner, nb = {}, {}
    for e in m.elems:
        n = e['nodes']
        for k in range(len(n)):
            owner.setdefault(n[k], set()).add(e['group'])
            nb.setdefault(n[k], set()).update((n[k - 1], n[(k + 1) % len(n)]))
    pl = {P.id: P for P in plates}
    X = np.array(m.xyz, float)
    free = [i for i in nb if i not in fixed and len(owner[i]) == 1]
    elems_of = {}
    for e in m.elems:
        for i in e['nodes']:
            elems_of.setdefault(i, []).append(e)
    for _ in range(iters):
        for i in free:
            P = pl[next(iter(owner[i]))]
            old = X[i - 1].copy()
            Y = X[[j - 1 for j in nb[i]]]
            X[i - 1] = Y.mean(0)
            X[i - 1] -= P.plane_dist(X[i - 1]) * P.n
            if np.linalg.norm(Y - X[i - 1], axis=1).min() < 0.5 * np.linalg.norm(Y - old, axis=1).min():
                X[i - 1] = old                                  # never pull a node onto a neighbour
                continue
            for e in elems_of[i]:
                Q = np.array([P.to2(X[j - 1]) for j in e['nodes']])
                if any(_orient(Q[k - 1], Q[k], Q[(k + 1) % len(Q)]) <= 0 for k in range(len(Q))):
                    X[i - 1] = old
                    break
    m.xyz = [tuple(round(float(c), 4) for c in p) for p in X]
    m.nodes = {p: i + 1 for i, p in enumerate(m.xyz)}


# ====================================================================== spec -> files
def build_plates(spec, out_dir='.', formats=('bdf', 'inp')):
    """spec: {"name", "plates": [...], "element_size", "material", "loads": [{"plates": [ids], "pressure": MPa}],
              "fix": [{"x"|"y"|"z": value, "dof": "123456"}], "all_quad": true,
              optional mesher settings (see mesh_plates): "snap_tol", "min_seg", "bracket_ties" (true), "repair" (true)}"""
    import json, os
    from . import mesh as M, meshcheck
    s = dict(spec)
    s.setdefault('name', 'assembly')
    s.setdefault('material', M.DEFAULT_SPEC['material'])
    h = float(s.get('element_size', 100))
    m = mesh_plates(s['plates'], h, all_quad=s.get('all_quad', True), beams=s.get('beams'), snap_tol=s.get('snap_tol'),
                    min_seg=s.get('min_seg'), bracket_ties=s.get('bracket_ties', True), repair=s.get('repair', True))
    m.spec = {'name': s['name'], 'material': s['material'], 'pressure': 0}
    m.loads = []
    for ld in s.get('loads', []) or []:
        ids = [e['id'] for e in m.elems if e['group'] in set(map(str, ld.get('plates', [])))]
        m.loads.append((ids, float(ld['pressure'])))
    m.spc = {}
    X = np.array(m.xyz)
    for f in s.get('fix', []) or []:                       # all given coordinates must match (x and y -> the corner line)
        sel = np.ones(len(X), bool)
        for ax, k in (('x', 0), ('y', 1), ('z', 2)):
            if ax in f:
                sel &= abs(X[:, k] - float(f[ax])) <= 1e-3 * max(h, 1)
        for i in np.where(sel)[0]:
            old = m.spc.get(int(i) + 1, '')
            m.spc[int(i) + 1] = ''.join(sorted(set(old + str(f.get('dof', '123456')))))
    os.makedirs(out_dir, exist_ok=True)
    base = os.path.join(out_dir, s['name'])
    files = {}
    if 'bdf' in formats:
        files['bdf'] = M.write_bdf(m, base + '.bdf')
    if 'inp' in formats:
        files['inp'] = M.write_inp(m, base + '.inp')
    json.dump(s, open(base + '.spec.json', 'w'), indent=1)
    files['spec'] = base + '.spec.json'
    chk = meshcheck.check(m.xyz, [e['nodes'] for e in m.elems], [e['group'] for e in m.elems])
    info = {'name': s['name'], 'nodes': len(m.xyz), 'elements': len(m.elems),
            'quads': sum(e['type'] == 'quad' for e in m.elems), 'trias': sum(e['type'] == 'tri' for e in m.elems),
            'bars': sum(e['type'] == 'bar' for e in m.elems),
            **m.report, 'check': chk, 'files': files}
    return m, info
