"""
Pictures of ShipBrain's models and results (own code; matplotlib, no GUI, no other renderer):

    render('part.step' | 'part.stl' | 'mesh.inp' | 'mesh.bdf', 'out.png')                      the geometry / mesh, shaded
    render('mesh.inp', 'out.png', frd='mesh.frd', field='von_mises')                          nodal von Mises stress on the mesh
    render('mesh.inp', 'out.png', frd='mesh.frd', field='displacement', scale=50)             displacement, drawn deformed x scale
    export_vtu('mesh.inp', 'out.vtu', frd='mesh.frd')                                         ParaView file (ASCII VTU, own writer)

Results come from CalculiX's .frd. CalculiX expands shells to solid elements and renumbers the nodes, so the value at a shell node is
taken from the expanded nodes around it: displacement = their mean (mid-surface), von Mises = their largest (outer fibre).
"""
import math, os, struct, tempfile

import numpy as np

FIELDS = ('von_mises', 'displacement')
VIEWS = {'iso': (25, -60), 'front': (0, -90), 'back': (0, 90), 'top': (90, -90), 'side': (0, 0), 'iso2': (25, 120)}


# ====================================================================== geometry
def _read_stl(path):
    data = open(path, 'rb').read()
    if data[:5] == b'solid' and b'facet' in data[:400]:
        V = []
        for ln in data.decode('ascii', 'replace').splitlines():
            ln = ln.strip()
            if ln.startswith('vertex'):
                V.append([float(x) for x in ln.split()[1:4]])
        V = np.array(V)
    else:
        n = struct.unpack('<I', data[80:84])[0]
        rec = np.frombuffer(data[84:84 + 50 * n], dtype=np.dtype([('n', '<f4', 3), ('v', '<f4', (3, 3)), ('a', '<u2')]))
        V = rec['v'].reshape(-1, 3).astype(float)
    # merge identical vertices
    key = np.round(V, 5)
    uniq, inv = np.unique(key, axis=0, return_inverse=True)
    return uniq, [list(f) for f in np.asarray(inv).reshape(-1, 3)], None


def _boundary_faces(elems):
    """outer faces of solid elements (faces used by one element)"""
    FA = {'tetra': [(0, 2, 1), (0, 1, 3), (1, 2, 3), (0, 3, 2)], 'penta': [(0, 2, 1), (3, 4, 5), (0, 1, 4, 3), (1, 2, 5, 4), (2, 0, 3, 5)],
          'hexa': [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]}
    cnt = {}
    for e in elems:
        for f in FA.get(e['type'], []):
            ids = [e['nodes'][i] for i in f]
            cnt.setdefault(tuple(sorted(ids)), []).append(ids)
    return [v[0] for v in cnt.values() if len(v) == 1]


def load_geometry(path):
    """-> (ids, X n x 3, faces [index lists into X], bars [(i, j)], model-or-None)"""
    low = path.lower()
    if low.endswith('.stl'):
        X, F, _ = _read_stl(path)
        return np.arange(len(X)), X, F, [], None
    if low.endswith(('.step', '.stp', '.brep')):
        import cadquery as cq
        from .cadplates import import_cad
        shp = import_cad(path)
        tmp = os.path.join(tempfile.mkdtemp(prefix='sb_viz_'), 'm.stl')
        cq.exporters.export(cq.Workplane(obj=shp) if not hasattr(shp, 'wrapped') else cq.Workplane(obj=shp), tmp, tolerance=0.2, angularTolerance=0.1)
        X, F, _ = _read_stl(tmp)
        return np.arange(len(X)), X, F, [], None
    from .femodel import FEModel
    m = FEModel.read(path)
    ids = np.array(sorted(m.nodes))
    pos = {n: k for k, n in enumerate(ids)}
    X = np.array([m.nodes[n] for n in ids], float)
    faces, bars = [], []
    solids = []
    for e in m.elems.values():
        t = e['type']
        if t in ('tria', 'quad'):
            faces.append([pos[n] for n in e['nodes']])
        elif t == 'bar':
            bars.append((pos[e['nodes'][0]], pos[e['nodes'][1]]))
        else:
            solids.append(e)
    for f in _boundary_faces(solids):
        faces.append([pos[n] for n in f])
    return ids, X, faces, bars, m


# ====================================================================== results
def nodal_results(model, ids, X, frd):
    """displacement vectors (n x 3) and von Mises (n,) at the model's nodes from a CalculiX .frd"""
    from scipy.spatial import cKDTree
    from .solver import read_frd_full
    xyz, S, U = read_frd_full(frd)
    if not xyz:
        raise ValueError('no results in ' + os.path.basename(frd))
    fid = np.array(sorted(xyz))
    P = np.array([xyz[i] for i in fid])
    tmax = max([p.get('t', 0.0) for p in model.props.values()] or [0.0]) if model is not None else 0.0
    r = 0.62 * tmax if tmax > 0 else 1e-6 * max(1.0, float(np.ptp(X, axis=0).max()))
    tree = cKDTree(P)
    u = np.zeros((len(X), 3))
    vm = np.zeros(len(X))
    sx = {i: S.get(i) for i in fid}
    for k, x in enumerate(X):
        near = tree.query_ball_point(x, max(r, 1e-9))
        if not near:
            near = [tree.query(x)[1]]
        nid = fid[near]
        uu = [U[i][:3] for i in nid if i in U]
        if uu:
            u[k] = np.mean(uu, axis=0)
        vs = []
        for i in nid:
            s = sx.get(i)
            if s:
                sxx, syy, szz, sxy, syz, szx = s[:6]
                vs.append(math.sqrt(0.5 * ((sxx - syy) ** 2 + (syy - szz) ** 2 + (szz - sxx) ** 2) + 3 * (sxy ** 2 + syz ** 2 + szx ** 2)))
        vm[k] = max(vs) if vs else 0.0
    return u, vm


# ====================================================================== picture
def render(src, out_png, frd=None, field=None, view='iso', scale=None, title=None, size=(9, 6.5), dpi=130, cmap='turbo', edges=None):
    """draw the model (and a result field) to a PNG; returns a dict with the value range"""
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    from mpl_toolkits.mplot3d.art3d import Poly3DCollection, Line3DCollection
    if field and field not in FIELDS:
        raise ValueError('field must be one of ' + ', '.join(FIELDS))
    ids, X, faces, bars, model = load_geometry(src)
    if not len(faces) and not bars:
        raise ValueError('nothing to draw in ' + os.path.basename(src))
    info = {'nodes': int(len(X)), 'faces': len(faces)}
    vals, Xd = None, X
    if field:
        if not frd:
            raise ValueError('a result field needs the CalculiX .frd file (run the analysis first)')
        u, vm = nodal_results(model, ids, X, frd)
        umag = np.linalg.norm(u, axis=1)
        vals = vm if field == 'von_mises' else umag
        size_model = float(np.ptp(X, axis=0).max())
        if scale is None:
            scale = 1.0 if umag.max() <= 0 else min(max(1.0, 0.1 * size_model / umag.max()), 1000.0) if field == 'displacement' else 1.0
        Xd = X + u * scale if scale else X
        info.update({'field': field, 'min': float(vals.min()), 'max': float(vals.max()), 'deformation_scale': float(scale) if field == 'displacement' else 1.0,
                     'units': 'MPa' if field == 'von_mises' else 'mm'})
    fig = plt.figure(figsize=size)
    ax = fig.add_subplot(111, projection='3d')
    polys = [Xd[f] for f in faces]
    if vals is not None:
        fv = np.array([vals[f].mean() for f in faces])
        lo, hi = float(vals.min()), float(vals.max())
        norm = plt.Normalize(lo, hi if hi > lo else lo + 1e-12)
        col = plt.get_cmap(cmap)(norm(fv))
    else:                                         # shaded grey from the face normal against a fixed light
        nrm = []
        for p in polys:
            n = np.cross(p[1] - p[0], p[2] - p[0])
            nl = np.linalg.norm(n)
            nrm.append(n / nl if nl > 0 else n)
        nrm = np.array(nrm)
        light = np.array([0.4, -0.5, 0.75]); light /= np.linalg.norm(light)
        sh = 0.35 + 0.65 * np.abs(nrm @ light)
        col = np.stack([0.45 * sh + 0.1, 0.55 * sh + 0.1, 0.7 * sh + 0.1, np.ones_like(sh)], axis=1)
    show_edges = edges if edges is not None else (model is not None and len(faces) <= 4000)
    pc = Poly3DCollection(polys, facecolors=col, edgecolors=(0, 0, 0, 0.35) if show_edges else 'none', linewidths=0.3)
    ax.add_collection3d(pc)
    if bars:
        ax.add_collection3d(Line3DCollection([Xd[list(b)] for b in bars], colors='k', linewidths=1.5))
    lo_, hi_ = Xd.min(axis=0), Xd.max(axis=0)
    c, half = (lo_ + hi_) / 2, max(float(np.ptp(Xd, axis=0).max()) / 2, 1e-9)
    ax.set_xlim(c[0] - half, c[0] + half); ax.set_ylim(c[1] - half, c[1] + half); ax.set_zlim(c[2] - half, c[2] + half)
    ax.set_box_aspect((1, 1, 1))
    el, az = VIEWS.get(view, VIEWS['iso'])
    ax.view_init(elev=el, azim=az)
    ax.set_xlabel('x [mm]'); ax.set_ylabel('y [mm]'); ax.set_zlabel('z [mm]')
    if vals is not None:
        sm = plt.cm.ScalarMappable(norm=norm, cmap=cmap)
        cb = fig.colorbar(sm, ax=ax, shrink=0.7, pad=0.08)
        cb.set_label({'von_mises': 'von Mises stress [MPa]', 'displacement': 'displacement [mm]'}[field])
    ax.set_title(title or (f"{os.path.basename(src)}" + (f" - {field.replace('_', ' ')}" if field else '')))
    fig.tight_layout()
    fig.savefig(out_png, dpi=dpi)
    plt.close(fig)
    info['png'] = out_png
    return info


# ====================================================================== ParaView
_VTK = {'bar': (3, 2), 'tria': (5, 3), 'quad': (9, 4), 'tetra': (10, 4), 'penta': (13, 6), 'hexa': (12, 8)}


def export_vtu(src, out, frd=None):
    """ASCII VTU (VTK XML unstructured grid) of a ShipBrain mesh with displacement and von Mises when a .frd is given"""
    ids, X, faces, bars, model = load_geometry(src)
    if model is None:
        raise ValueError('export_vtu needs a mesh (.inp / .bdf)')
    pos = {int(n): k for k, n in enumerate(ids)}
    cells = [(e['type'], [pos[n] for n in e['nodes']]) for e in model.elems.values() if e['type'] in _VTK]
    w = ['<?xml version="1.0"?>', '<VTKFile type="UnstructuredGrid" version="0.1" byte_order="LittleEndian">', '<UnstructuredGrid>',
         f'<Piece NumberOfPoints="{len(X)}" NumberOfCells="{len(cells)}">', '<Points><DataArray type="Float64" NumberOfComponents="3" format="ascii">']
    w += [' '.join(f'{v:.9g}' for v in x) for x in X]
    w += ['</DataArray></Points>', '<Cells><DataArray type="Int64" Name="connectivity" format="ascii">']
    w += [' '.join(map(str, c)) for _, c in cells]
    off, o = [], 0
    for _, c in cells:
        o += len(c)
        off.append(o)
    w += ['</DataArray><DataArray type="Int64" Name="offsets" format="ascii">', ' '.join(map(str, off)),
          '</DataArray><DataArray type="UInt8" Name="types" format="ascii">', ' '.join(str(_VTK[t][0]) for t, _ in cells), '</DataArray></Cells>']
    if frd:
        u, vm = nodal_results(model, ids, X, frd)
        w += ['<PointData>', '<DataArray type="Float64" Name="displacement_mm" NumberOfComponents="3" format="ascii">']
        w += [' '.join(f'{v:.9g}' for v in r) for r in u]
        w += ['</DataArray><DataArray type="Float64" Name="von_mises_MPa" format="ascii">', ' '.join(f'{v:.9g}' for v in vm), '</DataArray>', '</PointData>']
    w += ['</Piece>', '</UnstructuredGrid>', '</VTKFile>']
    open(out, 'w').write('\n'.join(w))
    return out


# ====================================================================== flow results (Elmer VTU)
FLOW_FIELDS = {'velocity': 'velocity magnitude [m/s]', 'pressure': 'pressure [Pa]', 'displacement': 'displacement [m]', 'vonmises': 'von Mises stress [Pa]'}


def render_flow(vtu, out_png, field='velocity', scale=None, arrows=True, title=None, size=(11, 5.5), dpi=130, cmap='turbo'):
    """2D Elmer result (VTU) as a colour plot; the structure of an FSI case is drawn deformed (scale = exaggeration, default 1; 'auto' = 10 % of the
    plate height). Returns the value range."""
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    from matplotlib.collections import PolyCollection
    from .elmer import read_vtu
    v = read_vtu(vtu)
    X, fl = v['points'][:, :2], v['fields']
    if field not in FLOW_FIELDS or field not in fl:
        raise ValueError(f"field must be one of {[f for f in FLOW_FIELDS if f in fl]}")
    val = fl[field]
    val = np.linalg.norm(val[:, :2], axis=1) if val.ndim == 2 else val
    conn, off, typ = v['connectivity'], v['offsets'], v['types']
    cells, start = [], 0
    for o, t in zip(off, typ):
        if t in (5, 9):
            cells.append(conn[start:o])
        start = o
    d = fl.get('displacement')
    Xd = X.copy()
    sc = 1.0
    if d is not None and np.abs(d).max() > 0:
        if scale == 'auto' or scale is None and False:
            sc = 0.1 * float(np.ptp(X[:, 1])) / float(np.abs(d).max()) * 0.4
        elif scale is not None:
            sc = float(scale)
        Xd = X + d[:, :2] * sc
    lo, hi = float(val.min()), float(val.max())
    norm = plt.Normalize(lo, hi if hi > lo else lo + 1e-12)
    polys = [Xd[c] for c in cells]
    fv = np.array([val[c].mean() for c in cells])
    fig, ax = plt.subplots(figsize=size)
    pc = PolyCollection(polys, array=fv, cmap=cmap, norm=norm, edgecolors='none')
    ax.add_collection(pc)
    if arrows and 'velocity' in fl:
        step = max(1, len(Xd) // 400)
        ax.quiver(Xd[::step, 0], Xd[::step, 1], fl['velocity'][::step, 0], fl['velocity'][::step, 1], color='k', width=0.0012, alpha=0.6)
    ax.set_xlim(Xd[:, 0].min(), Xd[:, 0].max()); ax.set_ylim(Xd[:, 1].min(), Xd[:, 1].max())
    ax.set_aspect('equal')
    ax.set_xlabel('x [m]'); ax.set_ylabel('y [m]')
    cb = fig.colorbar(pc, ax=ax, shrink=0.8)
    cb.set_label(FLOW_FIELDS[field])
    ax.set_title(title or os.path.basename(vtu) + ' - ' + field)
    fig.tight_layout(); fig.savefig(out_png, dpi=dpi); plt.close(fig)
    return {'png': out_png, 'field': field, 'min': lo, 'max': hi, 'deformation_scale': sc}


def render_slice(res, grid, out_png, field='velocity', plane='xy', at=None, title=None, size=(11, 5.5), dpi=130, cmap='turbo', arrows=True):
    """a slice through an OpenFOAM result (openfoam.results) on ShipBrain's own grid: plane 'xy' (side view, at z = `at`, default mid) or 'xz'
    (plan view, at y = `at`, default 10 % of the height). Cells of the body are left white."""
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    from matplotlib.collections import PolyCollection
    axes = grid['axes']
    ia, ib, ic = (0, 1, 2) if plane == 'xy' else (0, 2, 1)
    cut = axes[ic]
    if at is None:
        at = 0.5 * (cut[0] + cut[-1]) if plane == 'xy' else cut[0] + 0.1 * (cut[-1] - cut[0])
    kc = int(np.clip(np.searchsorted(cut, at) - 1, 0, len(cut) - 2))
    U, p, cells = res['U_cells'], res['p_cells'], res['cells']
    val = np.linalg.norm(U, axis=1) if field == 'velocity' else p
    polys, fv, vecs, ctr = [], [], [], []
    for n, c in enumerate(cells):
        if c[ic] != kc:
            continue
        a0, a1, b0, b1 = axes[ia][c[ia]], axes[ia][c[ia] + 1], axes[ib][c[ib]], axes[ib][c[ib] + 1]
        polys.append([(a0, b0), (a1, b0), (a1, b1), (a0, b1)])
        fv.append(val[n])
        vecs.append((U[n][ia], U[n][ib]))
        ctr.append(((a0 + a1) / 2, (b0 + b1) / 2))
    if not polys:
        raise ValueError('nothing in that slice')
    fv = np.array(fv)
    fig, ax = plt.subplots(figsize=size)
    pc = PolyCollection(polys, array=fv, cmap=cmap, edgecolors='none')
    ax.add_collection(pc)
    if arrows:
        step = max(1, len(ctr) // 350)
        ctr, vecs = np.array(ctr), np.array(vecs)
        ax.quiver(ctr[::step, 0], ctr[::step, 1], vecs[::step, 0], vecs[::step, 1], color='k', width=0.0012, alpha=0.6)
    ax.set_xlim(axes[ia][0], axes[ia][-1]); ax.set_ylim(axes[ib][0], axes[ib][-1]); ax.set_aspect('equal')
    ax.set_xlabel('xyz'[ia] + ' [m]'); ax.set_ylabel('xyz'[ib] + ' [m]')
    cb = fig.colorbar(pc, ax=ax, shrink=0.8)
    cb.set_label('velocity magnitude [m/s]' if field == 'velocity' else 'pressure [Pa]')
    ax.set_title(title or f'{field}, slice {plane} at {"xyz"[ic]} = {(cut[kc] + cut[kc + 1]) / 2:.3g} m')
    fig.tight_layout(); fig.savefig(out_png, dpi=dpi); plt.close(fig)
    return {'png': out_png, 'field': field, 'min': float(fv.min()), 'max': float(fv.max())}
