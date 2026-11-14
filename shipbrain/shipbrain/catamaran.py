"""
Slender-catamaran demihulls with the FAST-SHIPS hull generator (NTNU, GPL-3; copied unchanged in vendor/fastships): a demihull from L/B, B/T and Tt/T (transom to maximum draft) and either the
displacement volume or the waterline length; the library's own mesh (waterlines, sections) is turned into a closed STL in the hullgen frame (x aft -> bow, y across, z up, keel at z = 0),
mirrored to the full demihull, and two demihulls can be placed at a separation to make the catamaran (a STL for stl_stability / hull_flow). Needs numba and meshio.
"""
import os, sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
VENDOR = os.path.join(HERE, 'vendor', 'fastships')


def _import():
    for p in (VENDOR, os.path.join(VENDOR, 'fastships_hull_generator')):
        if p not in sys.path:
            sys.path.insert(0, p)
    try:
        import fastships_hull_generator.hull_generator.high_level_hull as hl
    except ImportError as e:
        raise RuntimeError('the FAST-SHIPS hull generator needs numba (pip install numba): ' + str(e))
    return hl


def demihull(l_to_b, b_to_t, tt_to_t, volume_m3=None, lwl=None, work=None):
    """-> dict(points, faces (full demihull, closed), lwl, b, t, volume, cb, lcb)"""
    import contextlib, io, tempfile
    hl = _import()
    if (volume_m3 is None) == (lwl is None):
        raise ValueError('give either the displacement volume (m3) or the waterline length (m)')
    with contextlib.redirect_stdout(io.StringIO()):
        if volume_m3 is not None:
            h = hl.HighLevelHull2(float(volume_m3), float(l_to_b), float(b_to_t), float(tt_to_t))
            h.scale_to_displacement()
        else:
            h = hl.HighLevelHull1(float(lwl), float(l_to_b), float(b_to_t), float(tt_to_t))
        d = work or tempfile.mkdtemp(prefix='sb_fs_')
        obj = os.path.join(d, 'h.obj')
        h.export_obj(obj)
    import meshio
    m = meshio.read(obj)
    P = np.asarray(m.points, float)
    F = np.vstack([c.data for c in m.cells if c.type == 'triangle'])
    # the generator meshes one half (centre plane at y = 0): mirror it and weld the seam
    Pm = P * np.array([1.0, -1.0, 1.0])
    P2 = np.vstack([P, Pm])
    F2 = np.vstack([F, F[:, [0, 2, 1]] + len(P)])
    key = np.round(P2, 6)
    uniq, inv = np.unique(key, axis=0, return_inverse=True)
    F2 = np.asarray(inv).reshape(-1)[F2.reshape(-1)].reshape(-1, 3)
    ok = (F2[:, 0] != F2[:, 1]) & (F2[:, 1] != F2[:, 2]) & (F2[:, 0] != F2[:, 2])
    F2 = F2[ok]
    T = float(h.draft_max)
    uniq[:, 2] += T                                                           # keel at z = 0, waterline at z = T
    A, B, C = uniq[F2[:, 0]], uniq[F2[:, 1]], uniq[F2[:, 2]]
    if np.einsum('ij,ij->i', A, np.cross(B, C)).sum() < 0:
        F2 = F2[:, [0, 2, 1]]
    g = lambda a, default=None: float(getattr(h, a)) if hasattr(h, a) and not callable(getattr(h, a)) else default
    return {'points': uniq, 'faces': F2, 'lwl': g('l_wl'), 'b': g('l_wl') / float(l_to_b), 'T': T, 'volume_m3': g('volume_displacement', volume_m3), 'cb': g('cb'), 'lcb_m': g('lcb_absolute')}


def write_stl(points, faces, path):
    with open(path, 'w') as f:
        f.write('solid hull\n')
        for t in faces:
            a, b, c = points[t[0]], points[t[1]], points[t[2]]
            n = np.cross(b - a, c - a)
            n = n / (np.linalg.norm(n) or 1.0)
            f.write(f'facet normal {n[0]:.6g} {n[1]:.6g} {n[2]:.6g}\n outer loop\n')
            for q in (a, b, c):
                f.write(f'  vertex {q[0]:.6g} {q[1]:.6g} {q[2]:.6g}\n')
            f.write(' endloop\nendfacet\n')
        f.write('endsolid hull\n')
    return path


def catamaran(points, faces, separation):
    """two demihulls with their centre planes `separation` metres apart: (points, faces)"""
    P1 = points + np.array([0.0, separation / 2, 0.0])
    P2 = points - np.array([0.0, separation / 2, 0.0])
    return np.vstack([P1, P2]), np.vstack([faces, faces + len(points)])
