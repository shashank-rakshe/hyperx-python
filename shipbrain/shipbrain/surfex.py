"""
Surface extraction and pipe recognition from a solid CAD model (STEP / BREP), on OpenCascade (OCP). No gmsh.

  recognize(face)        the true surface of a face whatever it was saved as: many exporters (SpaceClaim, ...) write every
                         face as a B-spline; GeomConvert_SurfToAnaSurf turns them back into plane / cylinder / cone /
                         sphere / torus within 0.05 mm, so the rules below judge the real geometry.
  mid_surface(shape)     thin solids -> mid-surface faces + thickness. Every face of a solid is tested: rays shot from
                         points on the face into the material must all hit an opposite face at (nearly) the same distance t,
                         and t must be small compared with the face. Works for flat, bent and curved plates and for pipe
                         walls (the mid-surface of a hollow pipe is the cylinder at the mean radius). A solid can give
                         several mid faces (a bent plate: flat + rounded part). Thickness is rounded (default 0.5 mm).
  outer_surface(shape)   the outer skin of every thin solid (the face of each skin pair that faces away from the model's
                         centre, or from the solid's own centre with reference='solid').
  pipes(shape)           piping: straight pipes (outward cylinders that go all the way round, grouped by axis + radius) and
                         bends (outward tori), solid or hollow (an inward bore on the same axis gives the wall); wall from
                         the bore, else from the pipe schedule table; centre lines joined into runs; 1D FE model
                         (pipe-section bars, bends split every 15 deg).
Each function returns plain data + a shape that can be written to STEP (names: Mid_Surface_10T, Outer_Surface_8T, ...).
"""
import math
from collections import defaultdict

import numpy as np

# ------------------------------------------------------------------ pipe schedules: OD (mm) -> wall (mm), ASME B36.10
SCHEDULE = {
    'SCH10': {10.287: 1.245, 13.716: 1.651, 17.145: 1.651, 21.336: 2.108, 26.670: 2.108, 33.401: 2.769, 42.164: 2.769,
              48.260: 2.769, 60.325: 2.769, 73.025: 3.048, 88.900: 3.048, 101.600: 3.048, 114.300: 3.048, 141.300: 3.404,
              168.275: 3.404, 219.075: 3.760, 273.050: 4.191, 323.850: 4.572},
    'SCH40': {10.287: 1.727, 13.716: 2.235, 17.145: 2.311, 21.336: 2.769, 26.670: 2.870, 33.401: 3.378, 42.164: 3.556,
              48.260: 3.683, 60.325: 3.912, 73.025: 5.156, 88.900: 5.486, 101.600: 5.740, 114.300: 6.020, 141.300: 6.553,
              168.275: 7.112, 219.075: 8.179, 273.050: 9.271, 323.850: 10.312},
    'SCH80': {10.287: 2.413, 13.716: 3.023, 17.145: 3.200, 21.336: 3.734, 26.670: 3.912, 33.401: 4.547, 42.164: 4.851,
              48.260: 5.080, 60.325: 5.537, 73.025: 7.010, 88.900: 7.620, 101.600: 8.077, 114.300: 8.560, 141.300: 9.525,
              168.275: 10.973, 219.075: 12.700, 273.050: 15.088, 323.850: 17.475},
    'SCH160': {21.336: 4.775, 26.670: 5.563, 33.401: 6.350, 42.164: 6.350, 48.260: 7.137, 60.325: 8.738, 73.025: 9.525,
               88.900: 11.125, 114.300: 13.487, 141.300: 15.875, 168.275: 18.237, 219.075: 23.012, 273.050: 28.575,
               323.850: 33.325},
}


def schedule_wall(od, schedule='SCH40'):
    """wall thickness for an outside diameter: nearest table OD within 3 %, else None"""
    tab = SCHEDULE.get(str(schedule).upper().replace(' ', ''), SCHEDULE['SCH40'])
    best = min(tab, key=lambda d: abs(d - od))
    return tab[best] if abs(best - od) <= 0.03 * od else None


# ------------------------------------------------------------------ face geometry
_ANA = None


def _types():
    global _ANA
    if _ANA is None:
        from OCP.GeomAbs import GeomAbs_Plane, GeomAbs_Cylinder, GeomAbs_Cone, GeomAbs_Sphere, GeomAbs_Torus
        _ANA = {GeomAbs_Plane: 'PLANE', GeomAbs_Cylinder: 'CYLINDER', GeomAbs_Cone: 'CONE', GeomAbs_Sphere: 'SPHERE',
                GeomAbs_Torus: 'TORUS'}
    return _ANA


def recognize(face, tol=0.05):
    """(type name, GeomAdaptor_Surface) of the face's true surface in world coordinates; type 'OTHER' if not analytic"""
    from OCP.BRep import BRep_Tool
    from OCP.GeomAdaptor import GeomAdaptor_Surface
    w = face.wrapped if hasattr(face, 'wrapped') else face
    s = BRep_Tool.Surface_s(w)
    ad = GeomAdaptor_Surface(s)
    t = _types().get(ad.GetType())
    if t:
        return t, ad
    try:
        from OCP.GeomConvert import GeomConvert_SurfToAnaSurf
        a = GeomConvert_SurfToAnaSurf(s).ConvertToAnalytical(tol)
        if a is not None:
            ad2 = GeomAdaptor_Surface(a)
            t2 = _types().get(ad2.GetType())
            if t2:
                return t2, ad2
    except Exception:
        pass
    return 'OTHER', ad


def _mesh(shape, size):
    from OCP.BRepMesh import BRepMesh_IncrementalMesh
    w = shape.wrapped if hasattr(shape, 'wrapped') else shape
    BRepMesh_IncrementalMesh(w, max(0.05, size), False, 0.35, True)


def _samples(face, n=12):
    """[(point, outward normal)] on a UV grid strictly inside the face (trimmed faces: points outside are dropped)"""
    from OCP.BRepTools import BRepTools
    from OCP.BRepGProp import BRepGProp_Face
    from OCP.BRepTopAdaptor import BRepTopAdaptor_FClass2d
    from OCP.TopAbs import TopAbs_IN
    from OCP.gp import gp_Pnt, gp_Vec, gp_Pnt2d
    w = face.wrapped if hasattr(face, 'wrapped') else face
    u0, u1, v0, v1 = BRepTools.UVBounds_s(w)
    cls = BRepTopAdaptor_FClass2d(w, 1e-7)
    gf = BRepGProp_Face(w)
    k = max(3, int(math.ceil(math.sqrt(n))) + 1)
    out = []
    for i in range(k):
        for j in range(k):
            u = u0 + (u1 - u0) * (i + 0.5) / k
            v = v0 + (v1 - v0) * (j + 0.5) / k
            if cls.Perform(gp_Pnt2d(u, v)) != TopAbs_IN:
                continue
            p, nv = gp_Pnt(), gp_Vec()
            gf.Normal(u, v, p, nv)
            L = nv.Magnitude()
            if L < 1e-12:
                continue
            out.append((np.array(p.Coord()), np.array(nv.Coord()) / L))
    return out


def _edge_points(face, n=25):
    """points along the face's edges (true extent of a trimmed face)"""
    pts = []
    for e in face.Edges():
        try:
            for t in np.linspace(0, 1, n):
                pts.append(np.array(e.positionAt(float(t)).toTuple()))
        except Exception:
            pass
    return np.array(pts) if pts else np.zeros((0, 3))


def _area(face):
    return face.Area()


# ------------------------------------------------------------------ mid / outer surface
def _offset_face(face, dist, kind):
    """face moved dist along its outward normal (negative = into the material)"""
    import cadquery as cq
    if kind == 'PLANE':
        n = np.array(face.normalAt().toTuple())
        return face.translate(cq.Vector(*(n * dist)))
    from OCP.BRepOffsetAPI import BRepOffsetAPI_MakeOffsetShape
    mk = BRepOffsetAPI_MakeOffsetShape()
    mk.PerformBySimple(face.wrapped, dist)
    if not mk.IsDone():
        return None
    out = cq.Shape.cast(mk.Shape())
    fs = out.Faces()
    return fs[0] if len(fs) == 1 else out


def skin_pairs(solid, max_t=60.0, max_ratio=0.25, min_share=0.02, n_rays=12):
    """[(face, partner, t, kind)] for the thin parts of one solid (see module doc)"""
    from OCP.IntCurvesFace import IntCurvesFace_ShapeIntersector
    from OCP.gp import gp_Lin, gp_Pnt, gp_Dir
    faces = solid.Faces()
    tot = sum(_area(f) for f in faces) or 1.0
    hit = IntCurvesFace_ShapeIntersector()
    hit.Load(solid.wrapped, 1e-6)
    skins = {}
    for i, f in enumerate(faces):
        A = _area(f)
        if A < min_share * tot:
            continue
        S = _samples(f, n_rays)
        if len(S) < 3:
            continue
        ds, partners = [], defaultdict(int)
        for p, nv in S:
            d = -nv
            hit.Perform(gp_Lin(gp_Pnt(*(p + d * 1e-4)), gp_Dir(*d)), 0.0, 10 * max_t)
            best = None
            for k in range(1, hit.NbPnt() + 1):
                w = hit.WParameter(k)
                if w > 1e-3 and (best is None or w < best[0]):
                    best = (w, hit.Face(k))
            if best is None:
                continue
            ds.append(best[0] + 1e-4)                 # the ray started 1e-4 inside the face
            g = best[1]
            j = next((jj for jj, ff in enumerate(faces) if ff.wrapped.IsSame(g)), None)
            if j is not None and j != i:
                partners[j] += 1
        if len(ds) < 0.8 * len(S) or not partners:
            continue
        t = float(np.median(ds))
        spread = max(abs(x - t) for x in ds)
        if t > max_t or spread > max(0.25, 0.1 * t) or t > max_ratio * math.sqrt(A):
            continue
        j = max(partners, key=partners.get)
        skins[i] = (j, t)
    pairs, used = [], set()
    for i, (j, t) in sorted(skins.items(), key=lambda kv: -_area(faces[kv[0]])):
        if i in used:
            continue
        used.add(i)
        if j in skins and skins[j][0] == i:
            used.add(j)
        kind = recognize(faces[i])[0]
        pairs.append((faces[i], faces[j], t, kind))
    return pairs


def _round(t, step):
    return round(round(t / step) * step, 3) if step else round(t, 3)


def extract(shape, kind='mid', max_t=60.0, round_to=0.5, reference='model', solids=None):
    """mid or outer surfaces of all thin solids -> (groups {thickness: [faces]}, report)"""
    sol = solids if solids is not None else shape.Solids()
    if reference == 'model':
        try:
            ref = np.array(shape.Center().toTuple())
        except Exception:
            ref = None
    groups, rep = defaultdict(list), {'solids': len(sol), 'thin_solids': 0, 'surfaces': 0, 'not_thin': [], 'failed': 0}
    for si, s in enumerate(sol):
        try:
            pairs = skin_pairs(s, max_t=max_t)
        except Exception:
            pairs = []
        if not pairs:
            bb = s.BoundingBox()
            rep['not_thin'].append(f'solid {si + 1} ({bb.xlen:.0f} x {bb.ylen:.0f} x {bb.zlen:.0f} mm)')
            continue
        rep['thin_solids'] += 1
        c_sol = np.array(s.Center().toTuple())
        for f, g, t, k in pairs:
            if kind == 'mid':
                out = _offset_face(f, -t / 2, k)
            else:
                c0 = ref if (reference == 'model' and ref is not None) else c_sol
                out = f if np.linalg.norm(np.array(f.Center().toTuple()) - c0) >= np.linalg.norm(np.array(g.Center().toTuple()) - c0) else g
            if out is None:
                rep['failed'] += 1
                continue
            groups[_round(t, round_to)].append(out)
            rep['surfaces'] += 1
    rep['thickness_groups'] = {f'{t:g} mm': len(v) for t, v in sorted(groups.items())}
    return dict(groups), rep


def save_groups(groups, path, kind='mid'):
    """one named part per thickness group: Mid_Surface_10T ... (STEP keeps the names)"""
    import cadquery as cq
    assy = cq.Assembly(name=f'{kind.capitalize()}_Surfaces')
    for t, faces in sorted(groups.items()):
        nm = f'{kind.capitalize()}_Surface_{t:g}T'.replace('.', 'p')
        assy.add(cq.Compound.makeCompound(faces), name=nm)
    assy.export(path)
    return path


def groups_to_plates(groups, h=100.0):
    """planar mid faces -> plate list for the own mesher (thickness from the group)"""
    from .cadplates import _face_loops
    plates, k = [], 0
    for t, faces in groups.items():
        for f in faces:
            if not hasattr(f, 'geomType') or recognize(f)[0] != 'PLANE':
                continue
            loops = _face_loops(f, h)
            k += 1
            plates.append({'id': f'M{k}', 'group': f'T{t:g}', 't': float(t), 'outline': [list(map(float, p)) for p in loops[0]],
                           'holes': [[list(map(float, p)) for p in L] for L in loops[1:]]})
    return plates


# ------------------------------------------------------------------ pipes
def _span(a):
    """angle actually covered by a set of angles (2 pi minus the largest gap) and the start angle of the covered arc"""
    if len(a) < 2:
        return 0.0, 0.0
    a = sorted(x % (2 * math.pi) for x in a)
    gaps = [(a[0] + 2 * math.pi - a[-1], a[0])] + [(a[k] - a[k - 1], a[k]) for k in range(1, len(a))]
    g, start = max(gaps)
    return 2 * math.pi - g, start


def _frame(ax3):
    o = np.array(ax3.Location().Coord())
    return o, np.array(ax3.XDirection().Coord()), np.array(ax3.YDirection().Coord()), np.array(ax3.Direction().Coord())


def pipes(shape, schedule='SCH40', min_cover=0.9, tol=0.05, min_od=15.0):
    """straight pipes and bends of a model (see module doc) -> dict with 'straights', 'bends', 'runs', 'report'"""
    faces = shape.Faces()
    bb = shape.BoundingBox()
    cyl_out, cyl_in, tor = [], [], []
    for f in faces:
        t, ad = recognize(f, tol)
        if t not in ('CYLINDER', 'TORUS'):
            continue
        S = _samples(f, 16)
        if len(S) < 2:
            continue
        E = _edge_points(f)
        if t == 'CYLINDER':
            c = ad.Cylinder()
            o, X, Y, Z = _frame(c.Position())
            R = c.Radius()
            pts = np.array([p for p, _ in S])
            w = pts - o
            radial = w - np.outer(w @ Z, Z)
            outward = float(np.mean(np.sum(radial * np.array([nv for _, nv in S]), 1))) > 0
            w = np.vstack([pts, E]) - o
            h = w @ Z
            az = np.arctan2(w @ Y, w @ X)
            rec = {'o': o, 'Z': Z, 'X': X, 'Y': Y, 'R': R, 'h0': float(h.min()), 'h1': float(h.max()), 'span': _span(az)[0],
                   'face': f}
            (cyl_out if outward else cyl_in).append(rec)
        else:
            tr = ad.Torus()
            o, X, Y, Z = _frame(tr.Position())
            Rm, rm = tr.MajorRadius(), tr.MinorRadius()
            pts = np.array([p for p, _ in S])
            w = pts - o
            x, y, hh = w @ X, w @ Y, w @ Z
            rho = np.hypot(x, y)
            ring = np.outer(x / np.maximum(rho, 1e-9), X) + np.outer(y / np.maximum(rho, 1e-9), Y)
            centre = o + ring * Rm
            outward = float(np.mean(np.sum((pts - centre) * np.array([nv for _, nv in S]), 1))) > 0
            if not outward:
                continue
            w = np.vstack([pts, E]) - o
            x, y, hh = w @ X, w @ Y, w @ Z
            rho = np.hypot(x, y)
            du, u0 = _span(np.arctan2(y, x))
            dv, _ = _span(np.arctan2(hh, rho - Rm))
            tor.append({'o': o, 'Z': Z, 'X': X, 'Y': Y, 'R': Rm, 'r': rm, 'du': du, 'u0': u0, 'dv': dv, 'face': f})

    def same_axis(a, b, rt):
        if abs(abs(a['Z'] @ b['Z']) - 1) > 1e-4 or abs(a['R'] - b['R']) > rt:
            return False
        w = b['o'] - a['o']
        return np.linalg.norm(w - (w @ a['Z']) * a['Z']) <= max(0.2, a['R'] * 0.002)

    def group(recs, rt):
        gs = []
        for r in recs:
            for g in gs:
                if same_axis(g[0], r, rt(r)):
                    g.append(r)
                    break
            else:
                gs.append([r])
        return gs
    straights = []
    bores = group(cyl_in, lambda r: max(0.05, r['R'] * 0.001))
    for g in group(cyl_out, lambda r: max(0.05, r['R'] * 0.001)):
        g0 = g[0]
        cover = sum(r['span'] for r in g)
        if cover < min_cover * 2 * math.pi:
            continue                                   # a rounded plate edge: only part of a circle
        # one group can hold several pipes on the same axis (a straight run with a gap): split along the axis
        segs = []
        for r in g:                                    # axial extent of every face, measured along g0's axis
            e = [float((r['o'] + h * r['Z'] - g0['o']) @ g0['Z']) for h in (r['h0'], r['h1'])]
            segs.append((min(e), max(e)))
        segs.sort()
        runs = [list(segs[0])]
        for a, b in segs[1:]:
            if a <= runs[-1][1] + 0.5:
                runs[-1][1] = max(runs[-1][1], b)
            else:
                runs.append([a, b])
        od = 2 * g0['R']
        bore = next((b for b in bores if same_axis(g0, b[0], 10 * g0['R'])), None)
        if bore and bore[0]['R'] < g0['R']:
            wall, src = g0['R'] - bore[0]['R'], 'model (hollow pipe)'
        else:
            wall, src = schedule_wall(od, schedule), f'{schedule} table (solid pipe in the model)'
        for a, b in runs:
            if b - a < 1e-3:
                continue
            hollow = src.startswith('model')
            straights.append({'od': round(od, 3), 'wall': round(wall, 3) if wall else None, 'wall_from': src if wall else 'unknown',
                              'hollow': hollow, 'std_od': schedule_wall(od, schedule) is not None,
                              'length': round(b - a, 2), 'p0': (g0['o'] + a * g0['Z']).round(3).tolist(),
                              'p1': (g0['o'] + b * g0['Z']).round(3).tolist(), 'faces': len(g)})
    bends = []
    tg = []
    for r in tor:
        for g in tg:
            q = g[0]
            if (np.linalg.norm(q['o'] - r['o']) <= 0.5 and abs(abs(q['Z'] @ r['Z']) - 1) < 1e-4 and abs(q['R'] - r['R']) <= 0.1
                    and abs(q['r'] - r['r']) <= 0.05):
                g.append(r)
                break
        else:
            tg.append([r])
    for g in tg:
        q = g[0]
        angs = []
        for r in g:                                    # points along every face's major arc, as angles in q's frame
            for k in range(5):
                u = r['u0'] + r['du'] * k / 4
                w = r['o'] + r['R'] * (math.cos(u) * r['X'] + math.sin(u) * r['Y']) - q['o']
                angs.append(math.atan2(w @ q['Y'], w @ q['X']))
        sweep, u0 = _span(angs)
        cover = sum(r['dv'] * r['du'] for r in g) / max(sweep, 1e-9)
        if cover < min_cover * 2 * math.pi or sweep < math.radians(3):
            continue                                   # a rounded corner of a plate, not a pipe bend
        od = 2 * q['r']
        wall = schedule_wall(od, schedule)
        pts = [(q['o'] + q['R'] * (math.cos(u0 + sweep * k / 8) * q['X'] + math.sin(u0 + sweep * k / 8) * q['Y'])).round(3).tolist()
               for k in range(9)]
        bends.append({'od': round(od, 3), 'wall': wall, 'bend_radius': round(q['R'], 2), 'angle_deg': round(math.degrees(sweep), 1),
                      'centre': q['o'].round(3).tolist(), 'axis': q['Z'].round(5).tolist(), 'p0': pts[0], 'p1': pts[-1], 'arc': pts})
    # pipe or not: hollow, or a standard pipe OD (not shorter than its diameter), or joined to a bend of the same size.
    # Everything else round and solid (bolts, pins, studs, threads, round bars) is listed as rods and left out.
    bends = [b for b in bends if b['od'] >= min_od and b['angle_deg'] <= 180.5 and b['wall'] is not None]   # U-bolt bows, coils out
    bend_ods = {round(b['od'], 1) for b in bends}
    keep, rods = [], []
    for st in straights:
        ok = st['od'] >= min_od and (st['hollow'] or (st['std_od'] and st['length'] >= st['od']) or round(st['od'], 1) in bend_ods)
        (keep if ok else rods).append(st)
    straights = keep
    runs = _runs(straights, bends)
    rep = {'faces': len(faces), 'straight_pipes': len(straights), 'bends': len(bends), 'runs': len(runs),
           'sizes': sorted({s['od'] for s in straights} | {b['od'] for b in bends}),
           'total_length_m': round((sum(s['length'] for s in straights) +
                                    sum(math.radians(b['angle_deg']) * b['bend_radius'] for b in bends)) / 1000, 3)}
    rep['rods_bolts_left_out'] = len(rods)
    return {'straights': straights, 'bends': bends, 'runs': runs, 'rods': rods, 'report': rep}


def _runs(straights, bends):
    """join pieces whose end points meet (within 2 % of the diameter, at least 1 mm) -> list of runs (piece indices)"""
    items = [('S', i, s) for i, s in enumerate(straights)] + [('B', i, b) for i, b in enumerate(bends)]
    parent = list(range(len(items)))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a
    ends = []
    for k, (_, _, it) in enumerate(items):
        for p in (it['p0'], it['p1']):
            ends.append((np.array(p), k, max(1.0, 0.02 * it['od'])))
    for i in range(len(ends)):
        for j in range(i + 1, len(ends)):
            if ends[i][1] != ends[j][1] and np.linalg.norm(ends[i][0] - ends[j][0]) <= max(ends[i][2], ends[j][2]):
                parent[find(ends[i][1])] = find(ends[j][1])
    groups = defaultdict(list)
    for k, (typ, i, _) in enumerate(items):
        groups[find(k)].append(f'{typ}{i + 1}')
    return sorted(groups.values(), key=len, reverse=True)


def pipe_fe_model(found, element_size=200.0, material=None, bend_step_deg=15.0):
    """1D FE model of the piping: bars with pipe sections (A, I, J from OD and wall), bends split every bend_step_deg"""
    from .femodel import FEModel
    m = FEModel()
    mat = material or {'E': 206000.0, 'nu': 0.3, 'rho': 7.85e-9, 'name': 'STEEL'}
    m.mats[1] = dict(mat)
    m.name = 'piping'
    pid_of = {}

    def pid(od, wall):
        wall = wall or od / 20
        key = (round(od, 2), round(wall, 2))
        if key not in pid_of:
            d = max(od - 2 * wall, 0.0)
            I = math.pi / 64 * (od ** 4 - d ** 4)
            pid_of[key] = len(pid_of) + 1
            m.props[pid_of[key]] = {'kind': 'bar', 'mid': 1, 'A': math.pi / 4 * (od ** 2 - d ** 2), 'I1': I, 'I2': I, 'J': 2 * I,
                                    'name': f'PIPE OD{od:g}x{wall:g}', 'od': od, 'wall': wall}
        return pid_of[key]
    tol = 0.5
    nodes = {}

    def node(p):
        k = tuple(np.round(np.asarray(p) / tol).astype(int))
        if k not in nodes:
            nodes[k] = m.add_node(p)
        return nodes[k]
    S = found['straights']
    ends = [(np.array(st['p0']), np.array(st['p1'])) for st in S]
    axis = [(e1 - e0) / (np.linalg.norm(e1 - e0) or 1) for e0, e1 in ends]
    cuts = defaultdict(list)                 # extra nodes on a pipe: where a branch meets it (tee)
    links = []                               # (point a, point b, od, wall, group)
    free = []
    for i, st in enumerate(S):
        for e in ends[i]:
            free.append((i, e))
    if S:
        A0 = np.array([e0 for e0, _ in ends])
        AX = np.array(axis)
        LEN = np.array([np.linalg.norm(e1 - e0) for e0, e1 in ends])
        OD = np.array([st['od'] for st in S])
        for i, e in free:
            w = e - A0
            a_ = np.sum(w * AX, 1)
            off = np.linalg.norm(w - a_[:, None] * AX, axis=1)
            ok = ((a_ > 1.0) & (a_ < LEN - 1.0) & (off > 1.0) & (off <= OD / 2 + 0.05 * OD + 1.0)
                  & (np.abs(AX @ axis[i]) < 0.9))
            ok[i] = False
            js = np.nonzero(ok)[0]
            if len(js):
                j = js[np.argmin(off[js])]                     # branch end on the wall of pipe j: tee
                cuts[j].append(float(a_[j]))
                links.append((e, A0[j] + a_[j] * AX[j], S[i]['od'], S[i]['wall'], 'TEE'))
    # collinear gaps (valves, flanges, fittings between two pipe ends): bridge them when shorter than 3 x OD
    if free:
        FP = np.array([e for _, e in free])
        FI = np.array([i for i, _ in free])
        for a_i, (i, e) in enumerate(free):
            d = FP - e
            gap = np.linalg.norm(d, axis=1)
            par = np.abs(np.abs(AX[FI] @ axis[i]) - 1) <= 1e-3
            lat = np.linalg.norm(d - (d @ axis[i])[:, None] * axis[i], axis=1)
            ok = ((np.arange(len(free)) > a_i) & (FI != i) & par & (np.abs(OD[FI] - S[i]['od']) <= 0.5) & (gap > 1.0)
                  & (gap <= 3 * S[i]['od']) & (lat <= 0.02 * S[i]['od'] + 0.5))
            for b_i in np.nonzero(ok)[0]:
                links.append((e, FP[b_i], S[i]['od'], S[i]['wall'], 'GAP'))
    for i, st in enumerate(S):
        P0, P1 = ends[i]
        L = np.linalg.norm(P1 - P0)
        n = max(1, int(math.ceil(L / element_size)))
        stations = sorted(set([L * k / n for k in range(n + 1)] + [c for c in cuts[i] if 1.0 < c < L - 1.0]))
        ids = [node(P0 + axis[i] * x) for x in stations]
        for a, b in zip(ids, ids[1:]):
            if a != b:
                m.add_elem('bar', [a, b], pid(st['od'], st['wall']), f"PIPE_{st['od']:g}")
    for a, b, od, wall, grp in links:
        na, nb = node(a), node(b)
        if na != nb:
            m.add_elem('bar', [na, nb], pid(od, wall), grp)
    for b in found['bends']:
        n = max(2, int(math.ceil(b['angle_deg'] / bend_step_deg)))
        C, Z = np.array(b['centre']), np.array(b['axis'])
        A = np.array(b['p0']) - C
        ids = []
        for k in range(n + 1):
            th = math.radians(b['angle_deg']) * k / n
            rot = A * math.cos(th) + np.cross(Z, A) * math.sin(th) + Z * (Z @ A) * (1 - math.cos(th))
            ids.append(node(C + rot))
        if np.linalg.norm(m.nodes[ids[-1]] - np.array(b['p1'])) > 1.0:          # arc ran the other way round
            ids = [ids[0]] + [node(C + (A * math.cos(-math.radians(b['angle_deg']) * k / n) + np.cross(Z, A) *
                                        math.sin(-math.radians(b['angle_deg']) * k / n))) for k in range(1, n + 1)]
        for a, c in zip(ids, ids[1:]):
            m.add_elem('bar', [a, c], pid(b['od'], b['wall']), f"BEND_{b['od']:g}")
    m.equivalence(max(1.0, tol))
    return m
