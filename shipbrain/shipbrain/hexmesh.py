"""
ShipBrain's own hexahedral mesher for solid parts (castings, foundations, shaft brackets, lugs, thick plates). Own code,
numpy only; no Gmsh. Written from the published idea of voxel / octree hex meshing with feature-preserving snapping
(Gao et al., "Feature-preserving octree-based hexahedral mesh generation", 2019) - none of that paper's code is used.

How it works
  1. surface   a triangle surface: STEP / BREP / any CadQuery shape (tessellated finely) or an STL file.
  2. voxels    a regular grid whose cell size per axis divides the bounding box exactly (so axis-aligned faces are
               reproduced exactly); a cell is solid when its centre is inside (ray parity down every grid column).
  3. hex mesh  the solid cells are the hexahedra: one conforming mesh, no hanging nodes (a uniform grid, not an octree).
  4. snapping  boundary nodes move onto the true surface (closest point on the triangle mesh); nodes near a sharp edge
               (dihedral angle above `feature_angle`) go onto that edge, nodes near a corner onto the corner. Interior
               nodes are smoothed. Every move is backed off wherever it would make a brick poor (scaled Jacobian below
               `min_sj`), so the result is always valid.
  5. report    elements, nodes, volume against the exact volume, scaled Jacobian (min / mean), how many nodes were
               snapped to the surface / to edges / to corners.
Limits (said in the answers): a uniform grid - thin walls need a size of about a third of the wall, and a grid cell
cannot follow a curved surface as smoothly as a boundary-fitted mesh; very small features vanish below the cell size.
Units: whatever the part uses (ShipBrain: mm).
"""
import math, os
import numpy as np

HEX_FACES = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]      # outward


# ====================================================================== surface
def read_stl(path):
    data = open(path, 'rb').read()
    if data[:5].lower() == b'solid' and b'facet' in data[:600]:                   # ASCII
        import re
        v = np.array([[float(x) for x in m] for m in re.findall(
            rb'vertex\s+([-+0-9.eE]+)\s+([-+0-9.eE]+)\s+([-+0-9.eE]+)', data)])
        return v.reshape(-1, 3, 3)
    n = int(np.frombuffer(data[80:84], np.uint32)[0])
    rec = np.frombuffer(data[84:84 + 50 * n], dtype=np.dtype([('n', '<f4', 3), ('v', '<f4', (3, 3)), ('a', '<u2')]))
    return rec['v'].astype(float)


def surface_from_shape(shape, tol):
    v, t = shape.tessellate(tol, 0.15)
    V = np.array([[p.x, p.y, p.z] for p in v], float)
    return V[np.array(t, int)]


def surface(src, size):
    """triangles (n, 3, 3) from a file (.step .stp .brep .stl) or a CadQuery shape; exact volume if the shape is known"""
    if isinstance(src, np.ndarray):
        return src, None
    if isinstance(src, str):
        if src.lower().endswith('.stl'):
            return read_stl(src), None
        from .cadplates import import_cad
        src = import_cad(src)
    from .rhino import volume
    solids = src.Solids() if hasattr(src, 'Solids') else []
    exact = sum(volume(s) for s in solids) if solids else None
    return surface_from_shape(src, size / 12.0), exact


# ====================================================================== voxelise
def voxelise(tri, h, pad=0.0):
    """grid (origin, steps, shape) and a boolean array of solid cells (ray parity down z through every column)"""
    lo, hi = tri.reshape(-1, 3).min(0) - pad, tri.reshape(-1, 3).max(0) + pad
    n = np.maximum(1, np.round((hi - lo) / h).astype(int))
    d = (hi - lo) / n
    cx = lo[0] + (np.arange(n[0]) + 0.5) * d[0]
    cy = lo[1] + (np.arange(n[1]) + 0.5) * d[1]
    cz = lo[2] + (np.arange(n[2]) + 0.5) * d[2]
    jit = np.array([0.3730, 0.2713]) * 1e-4 * d[:2]                         # keeps rays off shared triangle edges
    hits = [[[] for _ in range(n[1])] for _ in range(n[0])]
    A, B, C = tri[:, 0], tri[:, 1], tri[:, 2]
    for k in range(len(tri)):
        a, b, c = A[k], B[k], C[k]
        den = (b[1] - c[1]) * (a[0] - c[0]) + (c[0] - b[0]) * (a[1] - c[1])
        if abs(den) < 1e-14 * max(1.0, d[0] * d[1]):                         # vertical triangle: no column crossing
            continue
        x0, x1 = min(a[0], b[0], c[0]), max(a[0], b[0], c[0])
        y0, y1 = min(a[1], b[1], c[1]), max(a[1], b[1], c[1])
        i0, i1 = max(0, int(np.searchsorted(cx, x0 - jit[0]))), min(n[0], int(np.searchsorted(cx, x1 - jit[0], 'right')))
        j0, j1 = max(0, int(np.searchsorted(cy, y0 - jit[1]))), min(n[1], int(np.searchsorted(cy, y1 - jit[1], 'right')))
        if i0 >= i1 or j0 >= j1:
            continue
        X = (cx[i0:i1] + jit[0])[:, None]
        Y = (cy[j0:j1] + jit[1])[None, :]
        l1 = ((b[1] - c[1]) * (X - c[0]) + (c[0] - b[0]) * (Y - c[1])) / den
        l2 = ((c[1] - a[1]) * (X - c[0]) + (a[0] - c[0]) * (Y - c[1])) / den
        l3 = 1 - l1 - l2
        inside = (l1 >= 0) & (l2 >= 0) & (l3 >= 0)
        z = l1 * a[2] + l2 * b[2] + l3 * c[2]
        for i, j in zip(*np.nonzero(inside)):
            hits[i0 + i][j0 + j].append(z[i, j])
    solid = np.zeros(tuple(n), bool)
    for i in range(n[0]):
        for j in range(n[1]):
            zs = sorted(hits[i][j])
            if len(zs) % 2:                                                    # an odd count: drop the last (open / noisy mesh)
                zs = zs[:-1]
            for a, b in zip(zs[0::2], zs[1::2]):
                solid[i, j] |= (cz > a) & (cz < b)
    return lo, d, solid


# ====================================================================== grid -> hex mesh
def hex_mesh(solid, lo, d):
    ni, nj, nk = solid.shape
    idx = np.argwhere(solid)
    if not len(idx):
        raise ValueError('no solid cell: the cell size is larger than the part, or the surface is not closed')
    nid = -np.ones((ni + 1, nj + 1, nk + 1), np.int64)
    corners = [(0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0), (0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1)]
    for (di, dj, dk) in corners:
        nid[idx[:, 0] + di, idx[:, 1] + dj, idx[:, 2] + dk] = 0
    used = np.argwhere(nid == 0)
    nid[tuple(used.T)] = np.arange(len(used))
    X = lo + used * d
    H = np.stack([nid[idx[:, 0] + di, idx[:, 1] + dj, idx[:, 2] + dk] for di, dj, dk in corners], 1)
    return X, H


def boundary_nodes(H):
    """node indices on the boundary (on a face used by one hexahedron only)"""
    f = H[:, HEX_FACES].reshape(-1, 4)
    key = np.sort(f, 1)
    _, inv, cnt = np.unique(key, axis=0, return_inverse=True, return_counts=True)
    inv = inv.reshape(-1)
    on = cnt[inv] == 1
    return np.unique(f[on]), f[on]


def scaled_jacobian(X, H):
    """per hexahedron: the smallest scaled Jacobian over its 8 corners (1 = a perfect brick, <= 0 = inverted)"""
    P = X[H]                                                                  # (n, 8, 3)
    nb = [(1, 3, 4), (2, 0, 5), (3, 1, 6), (0, 2, 7), (7, 5, 0), (4, 6, 1), (5, 7, 2), (6, 4, 3)]
    out = np.full(len(H), np.inf)
    for c, (a, b, e) in enumerate(nb):
        e1, e2, e3 = P[:, a] - P[:, c], P[:, b] - P[:, c], P[:, e] - P[:, c]
        det = np.einsum('ij,ij->i', e1, np.cross(e2, e3))
        den = np.linalg.norm(e1, axis=1) * np.linalg.norm(e2, axis=1) * np.linalg.norm(e3, axis=1)
        out = np.minimum(out, det / np.maximum(den, 1e-300))
    return out


def hex_volume(X, H):
    """exact volume of trilinear hexahedra by 2x2x2 Gauss points"""
    g = 1 / math.sqrt(3)
    P = X[H]
    tot = np.zeros(len(H))
    sg = [(-1, -1, -1), (1, -1, -1), (1, 1, -1), (-1, 1, -1), (-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1)]
    for xi in (-g, g):
        for eta in (-g, g):
            for ze in (-g, g):
                dN = np.array([[s[0] * (1 + s[1] * eta) * (1 + s[2] * ze), s[1] * (1 + s[0] * xi) * (1 + s[2] * ze),
                                s[2] * (1 + s[0] * xi) * (1 + s[1] * eta)] for s in sg]) / 8.0       # (8, 3)
                J = np.einsum('kc,nkj->ncj', dN, P)
                tot += np.linalg.det(J)
    return float(tot.sum())


# ====================================================================== snapping
def closest_on_triangles(Q, tri, chunk=256):
    """closest point on the triangle mesh for every query point (Ericson, vectorised, with a centroid-distance prefilter)"""
    A, B, C = tri[:, 0], tri[:, 1], tri[:, 2]
    cen = tri.mean(1)
    rad = np.linalg.norm(tri - cen[:, None, :], axis=2).max(1)
    best = np.full(len(Q), np.inf)
    out = np.zeros_like(Q)
    for s in range(0, len(Q), chunk):
        q = Q[s:s + chunk]
        dc = np.linalg.norm(q[:, None, :] - cen[None], axis=2) - rad[None]
        r = np.partition(dc, min(8, dc.shape[1] - 1), axis=1)[:, min(8, dc.shape[1] - 1)]       # a safe search radius
        pi, ti = np.nonzero(dc <= np.maximum(r, 0)[:, None] + 1e-12)
        P = q[pi]
        a, b, c = A[ti], B[ti], C[ti]
        ab, ac, ap = b - a, c - a, P - a
        d1, d2 = (ab * ap).sum(1), (ac * ap).sum(1)
        bp = P - b
        d3, d4 = (ab * bp).sum(1), (ac * bp).sum(1)
        cp = P - c
        d5, d6 = (ab * cp).sum(1), (ac * cp).sum(1)
        vc, vb, va = d1 * d4 - d3 * d2, d5 * d2 - d1 * d6, d3 * d6 - d5 * d4
        res = np.zeros_like(P)
        done = np.zeros(len(P), bool)

        def put(mask, val):
            m = mask & ~done
            res[m] = val[m]
            done[m] = True
        put((d1 <= 0) & (d2 <= 0), a)
        put((d3 >= 0) & (d4 <= d3), b)
        put((d6 >= 0) & (d5 <= d6), c)
        put((vc <= 0) & (d1 >= 0) & (d3 <= 0), a + (d1 / np.where(d1 - d3 == 0, 1, d1 - d3))[:, None] * ab)
        put((vb <= 0) & (d2 >= 0) & (d6 <= 0), a + (d2 / np.where(d2 - d6 == 0, 1, d2 - d6))[:, None] * ac)
        w = (d4 - d3) / np.where((d4 - d3) + (d5 - d6) == 0, 1, (d4 - d3) + (d5 - d6))
        put((va <= 0) & ((d4 - d3) >= 0) & ((d5 - d6) >= 0), b + w[:, None] * (c - b))
        den = 1 / np.where(va + vb + vc == 0, 1, va + vb + vc)
        v, w2 = vb * den, vc * den
        put(np.ones(len(P), bool), a + ab * v[:, None] + ac * w2[:, None])
        dist = np.linalg.norm(P - res, axis=1)
        for k in range(len(q)):
            m = pi == k
            if m.any():
                j = np.argmin(dist[m])
                best[s + k] = dist[m][j]
                out[s + k] = res[m][j]
    return out, best


def feature_edges(tri, angle_deg, weld):
    """sharp edges of the surface: (segments (m, 2, 3), vertices where >= 3 sharp edges meet)"""
    key = np.round(tri.reshape(-1, 3) / weld).astype(np.int64)
    uniq, inv = np.unique(key, axis=0, return_inverse=True)
    inv = inv.reshape(-1, 3)
    P = np.zeros((len(uniq), 3))
    P[inv.reshape(-1)] = tri.reshape(-1, 3)
    nrm = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])
    ln = np.linalg.norm(nrm, axis=1)
    nrm = nrm / np.maximum(ln, 1e-300)[:, None]
    edges = {}
    for t, (a, b, c) in enumerate(inv):
        for u, v in ((a, b), (b, c), (c, a)):
            if u != v and ln[t] > 0:
                edges.setdefault((min(u, v), max(u, v)), []).append(t)
    cos_lim = math.cos(math.radians(angle_deg))
    seg, deg = [], {}
    for (u, v), ts in edges.items():
        sharp = len(ts) == 1 or len(ts) > 2 or (nrm[ts[0]] @ nrm[ts[1]] < cos_lim)
        if sharp:
            seg.append((P[u], P[v]))
            deg[u] = deg.get(u, 0) + 1
            deg[v] = deg.get(v, 0) + 1
    corners = np.array([P[u] for u, k in deg.items() if k >= 3]) if deg else np.zeros((0, 3))
    return (np.array(seg) if seg else np.zeros((0, 2, 3))), corners


def closest_on_segments(Q, seg):
    a, b = seg[:, 0], seg[:, 1]
    ab = b - a
    L2 = np.maximum((ab * ab).sum(1), 1e-300)
    best = np.full(len(Q), np.inf)
    out = np.zeros_like(Q)
    for s in range(0, len(Q), 512):
        q = Q[s:s + 512]
        t = np.clip(((q[:, None, :] - a[None]) * ab[None]).sum(2) / L2[None], 0, 1)
        p = a[None] + t[..., None] * ab[None]
        d = np.linalg.norm(q[:, None, :] - p, axis=2)
        j = np.argmin(d, axis=1)
        best[s:s + 512] = d[np.arange(len(q)), j]
        out[s:s + 512] = p[np.arange(len(q)), j]
    return out, best


def smooth_interior(X, H, fixed, iters=8, w=0.5):
    n = len(X)
    ed = np.array([(0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7)])
    e = np.concatenate([H[:, ed[:, 0]].reshape(-1, 1), H[:, ed[:, 1]].reshape(-1, 1)], 1)
    e = np.concatenate([e, e[:, ::-1]])
    free = np.ones(n, bool)
    free[fixed] = False
    for _ in range(iters):
        s = np.zeros_like(X)
        c = np.zeros(n)
        np.add.at(s, e[:, 0], X[e[:, 1]])
        np.add.at(c, e[:, 0], 1)
        avg = s / np.maximum(c, 1)[:, None]
        X = np.where(free[:, None], (1 - w) * X + w * avg, X)
    return X


def snap(X0, H, tri, h, feature_angle=35.0, min_sj=0.3, edge_reach=0.55, smooth=8):
    """move the boundary nodes onto the surface (and sharp edges, corners); keep every brick valid"""
    bnodes, bfaces = boundary_nodes(H)
    Q = X0[bnodes]
    surf, ds = closest_on_triangles(Q, tri)
    target = surf.copy()
    kind = np.zeros(len(Q), np.int8)                                           # 0 surface, 1 edge, 2 corner
    seg, corners = feature_edges(tri, feature_angle, weld=1e-5 * float(np.ptp(tri.reshape(-1, 3), 0).max()))
    hmin = float(np.min(h))
    if len(seg):
        pe, de = closest_on_segments(Q, seg)
        near = de < edge_reach * hmin
        target[near] = pe[near]
        kind[near] = 1
    if len(corners):
        dc = np.linalg.norm(Q[:, None, :] - corners[None], axis=2)
        j = np.argmin(dc, 1)
        near = dc[np.arange(len(Q)), j] < edge_reach * hmin * 1.2
        target[near] = corners[j[near]]
        kind[near] = 2
    # incremental snapping: the moves grow in 10 steps; a node stops growing (is frozen) only when going further would make
    # a brick poor - so every node gets as close to the surface as the bricks allow, never past it
    alpha = np.zeros(len(Q))
    frozen = np.zeros(len(Q), bool)
    pos_of = -np.ones(len(X0), np.int64)
    pos_of[bnodes] = np.arange(len(bnodes))

    def build(a):
        Xt = X0.copy()
        Xt[bnodes] = Q + a[:, None] * (target - Q)
        return smooth_interior(Xt, H, bnodes, smooth)
    X = build(alpha)
    for step in range(1, 11):
        trial = np.where(frozen, alpha, np.minimum(1.0, step / 10.0))
        for _ in range(4):
            Xt = build(trial)
            bad = np.nonzero(scaled_jacobian(Xt, H) < min_sj)[0]
            if not len(bad):
                break
            badn = np.unique(H[bad])
            p = pos_of[badn]
            p = p[p >= 0]
            hold = p[trial[p] > alpha[p]]
            if not len(hold):                                                  # nothing left to hold back: smooth harder
                smooth += 4
                continue
            trial[hold] = alpha[hold]
            frozen[hold] = True
        alpha = trial
        X = build(alpha)
    sj = scaled_jacobian(X, H)
    moved = np.linalg.norm(X[bnodes] - Q, axis=1)
    return X, {'snapped_to_surface': int((kind == 0).sum()), 'snapped_to_edges': int((kind == 1).sum()),
               'snapped_to_corners': int((kind == 2).sum()), 'boundary_nodes': int(len(bnodes)),
               'max_move': float(moved.max()), 'fully_snapped': int((alpha == 1).sum()), 'min_sj': float(sj.min()),
               'bad_elements': int((sj < min_sj).sum())}


# ====================================================================== the mesher
def mesh(src, size, feature_angle=35.0, min_sj=0.3, do_snap=True):
    """src: STEP / BREP / STL path, CadQuery shape or (n,3,3) triangles; size: cell size. Returns (X, H, report)."""
    if not size or size <= 0:
        raise ValueError('give a cell size (same unit as the part, e.g. mm)')
    tri, exact = surface(src, size)
    ext = tri.reshape(-1, 3).max(0) - tri.reshape(-1, 3).min(0)
    grid = float(np.prod(np.maximum(1, np.round(ext / size))))
    if grid > 4e6:
        raise ValueError(f'a cell size of {size:g} makes a grid of {grid / 1e6:.1f} million cells for this part: use a larger size '
                         f'(the part is {ext[0]:g} x {ext[1]:g} x {ext[2]:g}); try {max(ext) / 120:.3g} first')
    lo, d, solid = voxelise(tri, size)
    X0, H = hex_mesh(solid, lo, d)
    rep = {'cell_size': [round(float(x), 4) for x in d], 'cells': int(solid.sum()), 'triangles': int(len(tri))}
    vox_vol = hex_volume(X0, H)
    if do_snap:
        X, info = snap(X0, H, tri, d, feature_angle, min_sj)
        rep.update(info)
    else:
        X = X0
        rep['min_sj'] = float(scaled_jacobian(X, H).min())
    sj = scaled_jacobian(X, H)
    rep.update(nodes=int(len(X)), elements=int(len(H)), volume=hex_volume(X, H), voxel_volume=vox_vol,
               min_sj=float(sj.min()), mean_sj=float(sj.mean()), inverted=int((sj <= 0).sum()))
    if exact:
        rep['exact_volume'] = float(exact)
        rep['volume_error_percent'] = round(100 * (rep['volume'] - exact) / exact, 2)
        rep['voxel_volume_error_percent'] = round(100 * (vox_vol - exact) / exact, 2)
    return X, H, rep


def to_model(X, H, name='hexmesh', E=206000.0, nu=0.3, rho=7.85e-9):
    from .femodel import FEModel
    m = FEModel()
    m.name = name
    for i, x in enumerate(X, 1):
        m.nodes[i] = np.array(x, float)
    for k, h in enumerate(H, 1):
        m.elems[k] = {'type': 'hexa', 'nodes': [int(i) + 1 for i in h], 'pid': 1, 'group': '1'}
    m.props[1] = {'kind': 'solid', 'mid': 1, 'name': 'SOLID'}
    m.mats[1] = {'E': E, 'nu': nu, 'rho': rho, 'name': 'STEEL'}
    return m


def write(src, size, out, E=206000.0, nu=0.3, **kw):
    """mesh a solid and write it (.inp CalculiX / Abaqus, .bdf Nastran, .fem OptiStruct); returns the report"""
    X, H, rep = mesh(src, size, **kw)
    m = to_model(X, H, os.path.splitext(os.path.basename(out))[0], E, nu)
    m.write(out)
    rep['file'] = out
    ratio = 'about {:.1f} cells across the smallest dimension'.format(min(np.ptp(X, 0)) / max(rep['cell_size']))
    bad = 'no inverted element' if not rep['inverted'] else f"{rep['inverted']} INVERTED elements"
    pe = (f"Meshed the solid with {rep['elements']:,} hexahedra and {rep['nodes']:,} nodes (cell size {max(rep['cell_size']):g}; {ratio}) "
          f"and wrote {os.path.basename(out)}. Quality: smallest scaled Jacobian {rep['min_sj']:.2f}, mean {rep['mean_sj']:.2f}, {bad}.")
    if 'exact_volume' in rep:
        pe += (f" Volume {rep['volume']:.5g} against the exact {rep['exact_volume']:.5g} ({rep['volume_error_percent']:+.2f} %; "
               f"the plain voxel mesh had {rep['voxel_volume_error_percent']:+.2f} %).")
    if 'snapped_to_surface' in rep:
        pe += (f" {rep['snapped_to_surface']} boundary nodes were snapped onto the surface, {rep['snapped_to_edges']} onto sharp edges "
               f"and {rep['snapped_to_corners']} onto corners.")
    pe += (' This is a uniform-grid hex mesh: refine it (smaller cell size) where curved surfaces or small features matter, and '
           'check stresses at fillets and holes against a finer run.')
    rep['plain_english'] = pe
    return rep
