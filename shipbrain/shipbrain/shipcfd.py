"""
Flow around a ship hull from its STL with OpenFOAM, in the "double-body" way ordinary for hull viscous-resistance work: the hull below the waterline in an unbounded stream, the waterline
plane a symmetry plane (a rigid lid: no waves), the centre plane a symmetry plane (half the hull is meshed), deep water below. Wave making is therefore NOT in the answer - the force is
the viscous resistance: friction plus viscous pressure (form) resistance.

Meshing: ShipBrain writes the background grid itself (its own polyMesh writer) and OpenFOAM's snappyHexMesh refines it around the hull and snaps it to the STL surface (body-fitted cells).
A first version cut the hull out of the grid cell by cell (stair steps); that was dropped: every step facing the stream carries the full stagnation pressure and the drag came out 6 times
too high. gmsh is never used.

The hull STL is in the frame of hullgen: x from the stern to the bow, y across the beam, z up, metres; the draft T is the height of the waterline above the keel.
"""
import json, math, os, re, shutil, subprocess

import numpy as np

from . import openfoam as OF
from .elmer import Mesh, axis_from_segments, FLUIDS
from .intake import read_stl


def stl_triangles(path):
    return read_stl(path)                                                  # (n, 3, 3)


def hull_to_channel(tri, T, x_stern, height):
    """hull frame (x aft->bow, y beam, z up) -> channel frame (x flow, y up, z across): the bow looks upstream, the waterline is at y = height, the centre plane at z = 0.
    The stern of the hull (hull x = 0) goes to channel x = x_stern + L, the bow to x_stern."""
    L = float(tri[..., 0].max())
    out = np.empty_like(tri)
    out[..., 0] = x_stern + L - tri[..., 0]
    out[..., 1] = tri[..., 2] - T + height
    out[..., 2] = tri[..., 1]
    return out


def write_stl_ascii(tri, path):
    with open(path, 'w') as f:
        f.write('solid body\n')
        for t in tri:
            n = np.cross(t[1] - t[0], t[2] - t[0])
            n = n / (np.linalg.norm(n) or 1.0)
            f.write(f'facet normal {n[0]:.6g} {n[1]:.6g} {n[2]:.6g}\n outer loop\n')
            for q in t:
                f.write(f'  vertex {q[0]:.8g} {q[1]:.8g} {q[2]:.8g}\n')
            f.write(' endloop\nendfacet\n')
        f.write('endsolid body\n')


def _snappy_dict(Lx, H, W, hull_box, level, region_level, loc):
    x0, y0, z0, x1, y1, z1 = hull_box
    return f"""FoamFile {{ version 2.0; format ascii; class dictionary; object snappyHexMeshDict; }}
castellatedMesh true;
snap            true;
addLayers       false;
geometry
{{
    body.stl {{ type triSurfaceMesh; name body; }}
    refBox {{ type searchableBox; min ({x0 - 0.15 * (x1 - x0):.6g} {y0 - 0.5 * (y1 - y0):.6g} {0.0:.6g}); max ({x1 + 0.25 * (x1 - x0):.6g} {H:.6g} {z1 + 0.5 * (z1 - z0 + 1e-9):.6g}); }}
}}
castellatedMeshControls
{{
    maxLocalCells 4000000;
    maxGlobalCells 6000000;
    minRefinementCells 0;
    maxLoadUnbalance 0.2;
    nCellsBetweenLevels 2;
    features ();
    refinementSurfaces {{ body {{ level ({level} {level}); patchInfo {{ type wall; }} }} }}
    resolveFeatureAngle 30;
    refinementRegions {{ refBox {{ mode inside; levels ((1e15 {region_level})); }} }}
    locationInMesh ({loc[0]:.6g} {loc[1]:.6g} {loc[2]:.6g});
    allowFreeStandingZoneFaces true;
}}
snapControls
{{
    nSmoothPatch 3;
    tolerance 2.0;
    nSolveIter 50;
    nRelaxIter 5;
    nFeatureSnapIter 10;
    implicitFeatureSnap true;
    explicitFeatureSnap false;
    multiRegionFeatureSnap false;
}}
addLayersControls {{ relativeSizes true; layers {{}}; expansionRatio 1.0; finalLayerThickness 0.3; minThickness 0.1; nGrow 0; featureAngle 60; nRelaxIter 3; nSmoothSurfaceNormals 1; nSmoothNormals 3; nSmoothThickness 10; maxFaceThicknessRatio 0.5; maxThicknessToMedialRatio 0.3; minMedialAxisAngle 90; nBufferCellsNoExtrude 0; nLayerIter 50; }}
meshQualityControls
{{
    maxNonOrtho 65;
    maxBoundarySkewness 20;
    maxInternalSkewness 4;
    maxConcave 80;
    minVol 1e-13;
    minTetQuality 1e-30;
    minArea -1;
    minTwist 0.02;
    minDeterminant 0.001;
    minFaceWeight 0.02;
    minVolRatio 0.01;
    minTriangleTwist -1;
    nSmoothScale 4;
    errorReduction 0.75;
}}
mergeTolerance 1e-6;
"""


def build_ship_case(case_dir, stl, draft, speed_kn=12.0, fluid='seawater', level=3, turbulence='sst', up=1.0, down=2.0, depth=0.5, half_width=0.6, end_iter=None, intensity=0.01,
                    base_cells_per_length=20, log=None, scheme='second'):
    """double-body OpenFOAM case from a hull STL (metres): own background grid, snappyHexMesh to the hull, simpleFoam files. Domain: `up` hull lengths upstream, `down` downstream
    of the stern, `depth` and `half_width` in hull lengths; `level` = surface refinement levels (each halves the background cell)."""
    tri = stl_triangles(stl).astype(float)
    flat = tri.reshape(-1, 3)
    tri[..., 0] -= float(flat[:, 0].min())
    L = float(tri[..., 0].max())
    B = float(2 * flat[:, 1].max())
    T = float(draft)
    rho, mu = FLUIDS[fluid] if isinstance(fluid, str) else fluid
    U = speed_kn * 0.514444
    c0 = L / base_cells_per_length
    xs0 = up * L
    Lx = (up + 1 + down) * L
    H = depth * L + T
    W = max(half_width * L, 1.6 * B / 2)
    ch = hull_to_channel(tri, T, xs0, H)
    os.makedirs(os.path.join(case_dir, 'constant', 'triSurface'), exist_ok=True)
    write_stl_ascii(ch, os.path.join(case_dir, 'constant', 'triSurface', 'body.stl'))
    axes = [axis_from_segments([(0.0,), (xs0 - 0.2 * L, max(4, int(round((xs0 - 0.2 * L) / (c0 * 2)))), 1 / 3.0), (xs0 + 1.3 * L, int(round(1.5 * L / c0))), (Lx, max(6, int(round((Lx - xs0 - 1.3 * L) / (c0 * 3)))), 3.0)]),
            axis_from_segments([(0.0,), (H - 1.3 * T - 0.4 * L, max(3, int(round(0.5 * L / (c0 * 2)))), 3.0), (H, max(4, int(round((1.3 * T + 0.4 * L) / c0))))]),
            axis_from_segments([(0.0,), (B / 2 + 0.3 * L, max(5, int(round((B / 2 + 0.3 * L) / c0)))), (W, max(3, int(round((W - B / 2 - 0.3 * L) / (c0 * 3)))), 2.0)])]
    m = Mesh(axes, lambda x, y, z: 1)
    eps = 1e-9 * Lx

    def tag(c, ax, side):
        x, y, z = c
        if ax == 0 and abs(x) < eps:
            return 'inlet'
        if ax == 0 and abs(x - Lx) < eps:
            return 'outlet'
        if ax == 1 and abs(y) < eps:
            return 'floor'
        if ax == 1 and abs(y - H) < eps:
            return 'top'
        return 'sides'
    types = {'floor': 'symmetry', 'top': 'symmetry', 'sides': 'symmetry'}
    g = OF.write_polymesh(m, tag, case_dir, types)
    box = (xs0, H - T, 0.0, xs0 + L, H, B / 2)
    loc = (0.35 * xs0, H - 0.5 * T, 0.5 * W)                                  # a point in the water, upstream of the hull
    os.makedirs(os.path.join(case_dir, 'system'), exist_ok=True)
    open(os.path.join(case_dir, 'system', 'snappyHexMeshDict'), 'w').write(_snappy_dict(Lx, H, W, box, level, max(1, level - 1), loc))
    # controlDict / fvSchemes / fvSolution are needed by snappyHexMesh already
    info0 = {'rho': rho, 'nu': mu / rho, 'U': U, 'grid': {'patches': {p: [] for p in ('inlet', 'outlet', 'floor', 'top', 'sides', 'body')}}}
    OF._write_files(case_dir, info0, turbulence, intensity, 'slip', end_iter or 1500, c0 / 2 ** level, floor_sym=True, robust=(True if scheme == 'first' else 'second'))
    rc, out = OF._run(['snappyHexMesh', '-overwrite'], case_dir, 3600)
    open(os.path.join(case_dir, 'log.snappyHexMesh'), 'w').write(out)
    if rc != 0 or 'Finished meshing' not in out:
        raise RuntimeError('snappyHexMesh failed: ' + ' | '.join([l for l in out.splitlines() if 'ERROR' in l or 'FOAM' in l][-3:] or out.splitlines()[-3:]))
    n = re.findall(r'Mesh has (\d+) cells', out) or re.findall(r'cells:\s+(\d+)', out)
    rc2, chk = OF._run(['checkMesh'], case_dir, 900)
    ncells = int(re.search(r'cells:\s+(\d+)', chk).group(1)) if re.search(r'cells:\s+(\d+)', chk) else None
    if 'Mesh OK' not in chk:
        bad = [l.strip() for l in chk.splitlines() if '***' in l][:3]
        raise RuntimeError('the snapped mesh failed checkMesh: ' + ' | '.join(bad))
    json.dump({'rho': rho, 'nu': mu / rho, 'U': U, 'L': L, 'B': B, 'T': T, 'half': True}, open(os.path.join(case_dir, 'sb_info.json'), 'w'))
    return {'rho': rho, 'nu': mu / rho, 'U': U, 'L': L, 'B': B, 'T': T, 'cells': ncells, 'turbulence': turbulence, 'case': case_dir, 'level': level, 'background_cell_m': c0, 'domain': (Lx, H, W)}


# ====================================================================== results
def _read_poly(case_dir):
    d = os.path.join(case_dir, 'constant', 'polyMesh')

    def body_of(name):
        t = open(os.path.join(d, name)).read()
        return t[t.index('(\n', t.index('FoamFile')):]
    pts = np.array([[float(v) for v in l.strip('()\n').split()] for l in body_of('points').split('\n')[1:] if l.startswith('(')])
    faces = []
    for l in body_of('faces').split('\n')[1:]:
        m = re.match(r'(\d+)\(([\d ]+)\)', l)
        if m:
            faces.append([int(v) for v in m.group(2).split()])
    own = np.array([int(l) for l in body_of('owner').split('\n')[1:] if l.strip().isdigit()])
    nei = np.array([int(l) for l in body_of('neighbour').split('\n')[1:] if l.strip().isdigit()])
    b = open(os.path.join(d, 'boundary')).read()
    m = re.search(r'\n\s*body\s*\{[^}]*?nFaces\s+(\d+);\s*startFace\s+(\d+);', b)
    if not m:
        raise RuntimeError('no patch "body" in the snapped mesh')
    return pts, faces, own, nei, int(m.group(2)), int(m.group(1))


def _face_geometry(pts, f):
    P = pts[f]
    c = P.mean(axis=0)
    Sf = np.zeros(3)
    for a in range(len(f)):
        Sf += 0.5 * np.cross(P[a] - c, P[(a + 1) % len(f)] - c)
    return c, Sf


def forces(case_dir, info):
    """force on the hull patch (half hull, doubled): pressure from the owner-cell pressure on each face's area vector; friction from the wall-function shear
    tau = rho (nu + nut_wall) U_tangential / d  (d = distance of the cell centre from the face) - OpenFOAM's postProcess crashes in this build, so it is computed here"""
    t = OF.last_time(case_dir)
    pts, faces, own, nei, start, n = _read_poly(case_dir)
    rho, nu = info['rho'], info['nu']
    p = np.asarray(OF.read_field(os.path.join(case_dir, t, 'p')))
    U = np.asarray(OF.read_field(os.path.join(case_dir, t, 'U'), vec=True))
    txt = open(os.path.join(case_dir, t, 'nut')).read()
    k = txt.index('\n    body\n')
    k = txt.index('value', k)
    (kind, v), _ = OF._read_list(txt, k + 5, False)
    nut_w = np.asarray(v)
    ncell = len(p)
    # cell centres: area-weighted mean of the centres of the cell's faces
    acc, wsum = np.zeros((ncell, 3)), np.zeros(ncell)
    fc, fa = [], []
    for fi, f in enumerate(faces):
        c, Sf = _face_geometry(pts, f)
        a = np.linalg.norm(Sf)
        fc.append(c)
        fa.append(a)
        acc[own[fi]] += a * c
        wsum[own[fi]] += a
        if fi < len(nei):
            acc[nei[fi]] += a * c
            wsum[nei[fi]] += a
    cc = acc / wsum[:, None]
    Fp, Fs, area = np.zeros(3), np.zeros(3), 0.0
    for i in range(n):
        fi = start + i
        c, Sf = _face_geometry(pts, faces[fi])
        a = np.linalg.norm(Sf)
        o = own[fi]
        Fp += p[o] * rho * Sf                                               # Sf points out of the fluid into the hull: pressure pushes the hull along it
        nn = -Sf / a                                                        # unit normal into the fluid
        d = max(float(np.dot(cc[o] - c, nn)), 1e-6)
        ut = U[o] - np.dot(U[o], nn) * nn
        Fs += rho * (nu + (nut_w[i] if np.ndim(nut_w) else nut_w)) * ut / d * a      # the fluid drags the hull along its own velocity direction
        area += a
    return 2 * Fp, 2 * Fs, 2 * area


def solve_ship(workdir, name, stl, draft, speed_kn=12.0, **kw):
    d = os.path.join(workdir, name)
    shutil.rmtree(d, ignore_errors=True)
    info = build_ship_case(d, stl, draft, speed_kn, **kw)
    # fields now that the mesh exists (patch list from the snapped mesh)
    b = open(os.path.join(d, 'constant', 'polyMesh', 'boundary')).read()
    pats = re.findall(r'\n\s{4}(\w+)\s*\n\s*\{', b)
    OF._write_files(d, {'rho': info['rho'], 'nu': info['nu'], 'U': info['U'], 'grid': {'patches': {p: [] for p in pats}}}, info['turbulence'], 0.01, 'slip', kw.get('end_iter') or 1500,
                    info['background_cell_m'] / 2 ** info['level'], floor_sym=True, robust=(True if kw.get('scheme', 'second') == 'first' else 'second'))
    log = OF.run_case(d)
    Fp, Fs, area = forces(d, info)
    its = re.findall(r'^Time = (\d+)', log, re.M)
    Rp = float(Fp[0])
    Rf = abs(float(Fs[0]))
    return {'case': name, 'cells': info['cells'], 'iterations': int(its[-1]) if its else None, 'converged': 'solution converged' in log, 'pressure_resistance_N': Rp,
            'friction_resistance_N': Rf, 'Rv_N': Rp + Rf, 'lift_N': float(Fp[1] + Fs[1]), 'wetted_area_m2': area, 'speed_m_s': info['U'], 'L': info['L'], 'B': info['B'], 'T': info['T'],
            'Fn': info['U'] / math.sqrt(9.81 * info['L'])}, info
