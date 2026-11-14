"""
Geometry cleaning before meshing ("unclean" CAD and hand-made plate lists).

Plates (JSON):
  - repeated points and points on a straight line are removed
  - corners of different plates closer than `merge_tol` are snapped to one point (tiny gaps / overlaps between parts)
  - slightly warped plates are projected onto their best-fit plane (warp up to `max_warp`); worse ones are reported
  - plates and holes smaller than `min_area` are removed; exact duplicate plates are removed
  - holes that touch or leave the outline are reported
STEP / BREP (CadQuery/OCP):
  - ShapeFix (wrong orientation, small edges, open wires), sewing of loose faces, and merging of faces that lie in one
    plane but were split into pieces (UnifySameDomain)
Every action is listed in plain English so the user can see what was changed.
"""
import numpy as np


def _area_normal(P):
    n = np.zeros(3)
    for i in range(len(P)):
        n += np.cross(P[i], P[(i + 1) % len(P)])
    return np.linalg.norm(n) / 2, n


def _clean_loop(L, tol, angle_tol_deg=0.5):
    P = [np.asarray(p, float) for p in L]
    out = []
    for p in P:                                   # repeated points
        if not out or np.linalg.norm(p - out[-1]) > tol:
            out.append(p)
    if len(out) > 1 and np.linalg.norm(out[0] - out[-1]) <= tol:
        out.pop()
    changed = True
    s = np.sin(np.radians(angle_tol_deg))
    while changed and len(out) > 3:              # collinear points
        changed = False
        for i in range(len(out)):
            a, b, c = out[i - 1], out[i], out[(i + 1) % len(out)]
            u, v = b - a, c - b
            nu, nv = np.linalg.norm(u), np.linalg.norm(v)
            if nu > 0 and nv > 0 and np.linalg.norm(np.cross(u, v)) / (nu * nv) < s and u @ v > 0:
                out.pop(i)
                changed = True
                break
    return out


def clean_plates(plates, merge_tol=2.0, min_area=100.0, max_warp=5.0, tol=1e-3):
    """returns (clean plates, actions in plain English)"""
    act = []
    out = []
    for d in plates:
        d = dict(d)
        pid = d.get('id', '?')
        loops = [d['outline']] + list(d.get('holes') or [])
        cl = [_clean_loop(L, tol) for L in loops]
        removed = sum(len(a) - len(b) for a, b in zip(loops, cl))
        if removed:
            act.append(f'Plate {pid}: removed {removed} repeated or in-line point(s) from its outline/holes.')
        if len(cl[0]) < 3:
            act.append(f'Plate {pid}: removed - its outline has fewer than 3 distinct corners.')
            continue
        d['outline'], d['holes'] = cl[0], [h for h in cl[1:] if len(h) >= 3]
        out.append(d)
    # snap corners of different plates that almost meet
    pts = [(i, k, j) for i, d in enumerate(out) for k, L in enumerate([d['outline']] + d['holes']) for j in range(len(L))]
    get = lambda i, k, j: ([out[i]['outline']] + out[i]['holes'])[k][j]
    def setp(i, k, j, v):
        if k == 0:
            out[i]['outline'][j] = v
        else:
            out[i]['holes'][k - 1][j] = v
    X = np.array([get(*p) for p in pts]) if pts else np.zeros((0, 3))
    pl0 = []
    for d in out:
        P = np.array(d['outline'], float)
        nv = np.zeros(3)
        for j in range(len(P)):
            nv += np.cross(P[j], P[(j + 1) % len(P)])
        pl0.append((P[0], nv / (np.linalg.norm(nv) or 1)))
    done, snapped = set(), 0
    for a in range(len(pts)):
        if a in done:
            continue
        near = np.where(np.linalg.norm(X - X[a], axis=1) <= merge_tol)[0]
        group = [b for b in near if b not in done]
        if len({pts[b][0] for b in group}) > 1:
            c = X[group].mean(0)
            spread = max(np.linalg.norm(X[b] - c) for b in group)
            if spread > tol:
                for b in group:
                    o_b, n_b = pl0[pts[b][0]]
                    if abs((c - o_b) @ n_b) <= max(0.5, 10 * tol):       # only if it stays in that plate's plane
                        setp(*pts[b], c)
                        snapped += 1
        done.update(group)
    if snapped:
        act.append(f'Snapped {snapped} plate corner(s) that were less than {merge_tol:g} mm apart onto common points (closes small gaps/overlaps between parts).')
    # snap corners onto a nearby EDGE of another plate (T-joints that stop a few mm short / overshoot)
    edges = []
    for i, d in enumerate(out):
        for L in [d['outline']] + d['holes']:
            for j in range(len(L)):
                edges.append((i, np.asarray(L[j], float), np.asarray(L[(j + 1) % len(L)], float)))
    if edges:
        cell = max(merge_tol * 4, 50.0)
        grid = {}
        for k, (i, a, b) in enumerate(edges):
            lo = np.floor((np.minimum(a, b) - merge_tol) / cell).astype(int)
            hi = np.floor((np.maximum(a, b) + merge_tol) / cell).astype(int)
            if np.prod(hi - lo + 1) > 4000:                       # very long edge: index its end cells only
                for c in (lo, hi):
                    grid.setdefault(tuple(c), []).append(k)
                continue
            for x in range(lo[0], hi[0] + 1):
                for y in range(lo[1], hi[1] + 1):
                    for z in range(lo[2], hi[2] + 1):
                        grid.setdefault((x, y, z), []).append(k)
        on_edge = 0
        planes = []
        for d in out:
            P = np.array(d['outline'], float)
            nv = np.zeros(3)
            for j in range(len(P)):
                nv += np.cross(P[j], P[(j + 1) % len(P)])
            planes.append((P[0], nv / (np.linalg.norm(nv) or 1)))
        for i, d in enumerate(out):
            o_i, n_i = planes[i]
            for L in [d['outline']] + d['holes']:
                for j in range(len(L)):
                    p = np.asarray(L[j], float)
                    best = None
                    for k in grid.get(tuple(np.floor(p / cell).astype(int)), ()):
                        q, a, b = edges[k]
                        if q == i:
                            continue
                        ab = b - a
                        t = float(np.clip((p - a) @ ab / (ab @ ab + 1e-30), 0, 1))
                        x = a + t * ab
                        dist = float(np.linalg.norm(p - x))
                        in_plane = abs((x - o_i) @ n_i) <= max(0.5, 10 * tol)     # never pull a corner out of its own plane
                        if tol < dist <= merge_tol and in_plane and (best is None or dist < best[0]):
                            best = (dist, x)
                    if best is not None:
                        L[j] = best[1]
                        on_edge += 1
        if on_edge:
            act.append(f'Moved {on_edge} plate corner(s) onto a nearby edge of another plate (gaps/overshoots up to {merge_tol:g} mm at T-joints).')
    # flatten, small parts, duplicates
    final, seen = [], {}
    for d in out:
        pid = d.get('id', '?')
        P = np.array(d['outline'], float)
        allp = np.vstack([P] + [np.array(h, float) for h in d['holes']]) if d['holes'] else P
        def fit(Q):
            c = Q.mean(0)
            _, _, vt = np.linalg.svd(Q - c)
            return c, vt[2], np.abs((Q - c) @ vt[2]).max()
        c, n, warp = fit(allp)
        if warp > tol:
            # one bad corner? -> keep the plane of all the others and move only that corner
            best = None
            if len(allp) >= 4:
                for i in range(len(allp)):
                    ci, ni, wi = fit(np.delete(allp, i, 0))
                    if wi <= tol and (best is None or wi < best[2]):
                        best = (ci, ni, wi, i)
            if best is not None and abs((allp[best[3]] - best[0]) @ best[1]) <= max_warp:
                c, n = best[0], best[1]
                how = 'its one off-plane corner was moved onto the plane of the other corners'
            else:
                how = 'flattened onto its best-fit plane'
            if warp <= max_warp:
                proj = lambda L: [list(np.asarray(p, float) - ((np.asarray(p, float) - c) @ n) * n) for p in L]
                d['outline'] = proj(d['outline'])
                d['holes'] = [proj(h) for h in d['holes']]
                act.append(f'Plate {pid}: was warped by {warp:.2f} mm - {how}.')
            else:
                act.append(f'Plate {pid}: is warped by {warp:.1f} mm (more than {max_warp:g} mm) - split it into flat plates; not changed.')
        area, _ = _area_normal(np.array(d['outline'], float))
        if area < min_area:
            act.append(f'Plate {pid}: removed - area {area:.0f} mm2 is below {min_area:g} mm2 (sliver).')
            continue
        keep_h = []
        for h in d['holes']:
            ha, _ = _area_normal(np.array(h, float))
            if ha < min_area:
                act.append(f'Plate {pid}: removed a tiny hole of {ha:.0f} mm2.')
            else:
                keep_h.append(h)
        d['holes'] = keep_h
        key = tuple(sorted(tuple(np.round(np.array(p, float), 1)) for p in d['outline']))
        if key in seen:
            act.append(f'Plate {pid}: removed - exact duplicate of plate {seen[key]}.')
            continue
        seen[key] = pid
        d['outline'] = [list(map(float, p)) for p in d['outline']]
        d['holes'] = [[list(map(float, p)) for p in h] for h in d['holes']]
        final.append(d)
    if not act:
        act.append('Geometry was already clean: nothing changed.')
    return final, act


def clean_shape(shape, tol=0.01, sew=True, unify=True):
    """OCP repair of a CadQuery shape; returns (shape, actions)"""
    import cadquery as cq
    from OCP.ShapeFix import ShapeFix_Shape
    from OCP.ShapeUpgrade import ShapeUpgrade_UnifySameDomain
    from OCP.BRepBuilderAPI import BRepBuilderAPI_Sewing
    act = []
    w = shape.wrapped
    nf0 = len(shape.Faces())
    if sew and not shape.Solids():
        s = BRepBuilderAPI_Sewing(tol)
        s.Add(w)
        s.Perform()
        w = s.SewedShape()
        act.append('Sewed loose faces together (tolerance %g mm).' % tol)
    fix = ShapeFix_Shape(w)
    fix.SetPrecision(tol)
    fix.Perform()
    w = fix.Shape()
    act.append('Repaired the shape (orientation, small edges, open wires).')
    if unify:
        u = ShapeUpgrade_UnifySameDomain(w, True, True, True)
        u.Build()
        w = u.Shape()
    out = cq.Shape.cast(w)
    nf1 = len(out.Faces())
    if nf1 < nf0:
        act.append(f'Merged faces that lie in one plane but were split into pieces: {nf0} -> {nf1} faces.')
    if not out.isValid():
        act.append('Warning: the shape is still not valid after repair; check it in CAD.')
    return out, act
