"""
Own shell mesher for assemblies of flat plates (deck, girders, webs, brackets, floors, bulkheads, with openings).
No gmsh. Conforming by construction: no free nodes, no duplicate nodes, plates share nodes along every joint.

Pipeline
  1. each plate = planar polygon (outline + holes) in 3D, thickness t
  2. gap closing: a plate edge lying within ~half the thicknesses of another plate's plane is snapped onto it
     (mid-surfaces of CAD solids stop t/2 short of the plate they sit on -> would be disconnected)
  3. all plate-plate intersection lines are computed and clipped to both plates
  4. every boundary edge and joint line becomes a global segment; segments are split at every crossing / T-joint,
     de-duplicated, then discretised ONCE -> both plates of a joint get the very same nodes
  5. per plate: constrained Delaunay triangulation in the plate plane (fixed joint/boundary nodes + hex-grid interior points,
     constraint edges recovered by edge flips), Delaunay flips, smoothing
  6. triangles paired into quads, then every element split into quads (all-quad mesh, element size h);
     edge mid-nodes are shared through the global node registry
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


def close_gaps(plates, tol, factor=0.75):
    """snap plate vertices that sit just off another plate's plane (mid-surface gap) onto that plane"""
    moved = 0
    for P in plates:
        for Q in plates:
            if P is Q or abs(P.n @ Q.n) > 0.98:
                continue
            gap = factor * (P.t + Q.t) / 2 + tol
            d = Q.n - (Q.n @ P.n) * P.n                     # direction inside P's plane that changes distance to Q
            if np.linalg.norm(d) < 1e-6:
                continue
            d = _unit(d)
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


# ====================================================================== mesher
def mesh_plates(plates_in, h, tol=None, close_gap=True, all_quad=True, smooth=3, beams=None):
    """beams: 1D stiffeners [{"id", "a": [x,y,z], "b": [x,y,z], "profile": {...}, "normal": [0,0,-1]}] - their lines are
    put into the plates' meshes so the CBARs share the plate nodes; offset = normal * (t_plate/2 + profile centroid)"""
    h = float(h)
    beams = beams or []
    tol = tol or max(1e-3, h * 1e-3)
    plates = [Plate(d, tol) for d in plates_in]
    ids = [p.id for p in plates]
    if len(set(ids)) != len(ids):
        raise ValueError('plate ids must be unique')
    moved = close_gaps(plates, tol) if close_gap else 0
    H = 2 * h if all_quad else h                                   # triangles at 2h -> split -> quads at h
    beam_lines = [(np.array(b['a'], float), np.array(b['b'], float)) for b in beams]
    segs = [e for P in plates for e in P.edges3()] + intersections(plates, tol) + beam_lines
    segs = split_segments(segs, tol)
    reg = Registry(tol)
    seg_nodes = []
    for a, b in segs:
        n = max(1, int(math.ceil(np.linalg.norm(b - a) / H - 1e-9)))
        seg_nodes.append([reg.get(a + (b - a) * k / n) for k in range(n + 1)])
    m = Mesh()
    m.plate_of_node = {}
    node_xyz = reg.xyz
    elems = []                                                     # (plate index, [global ids])
    on_seg = set(i for s in seg_nodes for i in s)
    report = {'plates': len(plates), 'joint_segments': len(segs), 'gap_snaps': moved, 'skipped': []}
    for pi, P in enumerate(plates):
        mine = []
        for (a, b), ns in zip(segs, seg_nodes):
            if abs(P.plane_dist(a)) <= tol * 2 and abs(P.plane_dist(b)) <= tol * 2 and P.in_or_on(P.to2((a + b) / 2), tol * 2)[0]:
                mine.append(ns)
        fixed_ids = sorted(set(i for ns in mine for i in ns))
        loc = {g: k for k, g in enumerate(fixed_ids)}
        pts = [P.to2(node_xyz[g]) for g in fixed_ids]
        cons = set(tuple(sorted((loc[ns[k]], loc[ns[k + 1]]))) for ns in mine for k in range(len(ns) - 1))
        # interior points on a hex grid, kept away from constraints
        allp = np.vstack(P.loops2)
        lo, hi = allp.min(0), allp.max(0)
        dy = H * math.sqrt(3) / 2
        ys = np.arange(lo[1] + dy / 2, hi[1], dy)
        grid = [(x + (H / 2 if r % 2 else 0), y) for r, y in enumerate(ys) for x in np.arange(lo[0] + H / 2, hi[0], H)]
        G = np.array(grid) if grid else np.zeros((0, 2))
        if len(G):
            G = G[_inside(G, P.loops2)]
            F = np.array(pts)
            dmin = np.full(len(G), np.inf)
            for (i, j) in cons:
                dmin = np.minimum(dmin, _seg_dist2d(G, F[i], F[j]))
            G = G[dmin > 0.6 * H]
        P2 = np.vstack([np.array(pts), G]) if len(G) else np.array(pts)
        if len(P2) < 3:
            report['skipped'].append(P.id)
            continue
        T = Tri2D(P2, _delaunay(P2))
        lost = [c for c in cons if not T.recover(*c)]
        if lost:
            raise RuntimeError(f'plate {P.id}: {len(lost)} joint/boundary edges could not be recovered - try a smaller element size')
        T.incircle_flips(cons)
        # keep triangles inside the plate (outside outline / inside holes removed)
        keep = []
        for t in T.T:
            c = P2[t].mean(0)
            if _inside(c[None], P.loops2)[0]:
                keep.append(t)
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
    # 1D beams along their (split, discretised) segments, through the same mid-nodes as the shells
    from .mesh import profile_props
    bar_elems = []
    for bi, bm in enumerate(beams):
        a, b = beam_lines[bi]
        d = b - a
        L2 = d @ d
        pts = []
        for (p, q), ns in zip(segs, seg_nodes):
            # sub-segment lies on this beam line?
            if all(np.linalg.norm(np.cross(x - a, d)) / math.sqrt(L2) <= tol and -tol <= (x - a) @ d / math.sqrt(L2) <= math.sqrt(L2) + tol for x in (p, q)):
                chain = ns
                if all_quad:
                    chain = []
                    for k in range(len(ns) - 1):
                        chain += [ns[k], reg.get((node_xyz[ns[k]] + node_xyz[ns[k + 1]]) / 2)]
                    chain.append(ns[-1])
                for k in range(len(chain) - 1):
                    bar_elems.append((bi, chain[k], chain[k + 1]))
                    on_seg.update((chain[k], chain[k + 1]))
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
    for bi, bm in enumerate(beams):
        sp = profile_props(bm['profile'])
        nrm = _unit(np.array(bm.get('normal', [0, 0, -1]), float))
        mid_pt = (beam_lines[bi][0] + beam_lines[bi][1]) / 2
        host = [P for P in plates if abs(P.plane_dist(mid_pt)) <= 2 * tol and P.in_or_on(P.to2(mid_pt), 2 * tol)[0]]
        tp = max((P.t for P in host), default=0.0)
        off = nrm * (tp / 2 + sp['zc'])
        pid = 1000 + bi
        m.props[pid] = {'kind': 'bar', 'A': sp['A'], 'I1': sp['I_vert'], 'I2': sp['I_lat'], 'J': sp['J'], 'offset': float(-(tp / 2 + sp['zc'])),
                        'name': str(bm.get('id', f'BEAM{bi + 1}'))}
        for b_i, n1, n2 in bar_elems:
            if b_i == bi:
                m.add('bar', [new[n1], new[n2]], pid, str(bm.get('id', f'BEAM{bi + 1}')), orient=tuple(-nrm), offset=tuple(off))
    if all_quad and smooth:
        _smooth3d(m, plates, set(new[g] for g in on_seg if g in new))
    m.plates = plates
    m.report = report
    return m


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
            X[i - 1] = X[[j - 1 for j in nb[i]]].mean(0)
            X[i - 1] -= P.plane_dist(X[i - 1]) * P.n
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
              "fix": [{"x"|"y"|"z": value, "dof": "123456"}], "all_quad": true}"""
    import json, os
    from . import mesh as M, meshcheck
    s = dict(spec)
    s.setdefault('name', 'assembly')
    s.setdefault('material', M.DEFAULT_SPEC['material'])
    h = float(s.get('element_size', 100))
    m = mesh_plates(s['plates'], h, all_quad=s.get('all_quad', True), beams=s.get('beams'))
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
