"""
Propeller blade geometry with BladeX (https://github.com/mathLab/BladeX, MIT, mathLab SISSA; copied unchanged in vendor/bladex): a blade from radial distributions of chord, pitch, rake and skew and one
section profile per radius (NACA 4-digit or a custom profile), turned into the 3D surface points of the suction and pressure faces.

BladeX imports pythonocc (IGES / STEP export) and smithers (STL / OBJ readers) at the top of its modules; they are not needed for the geometry and are not installed here: placeholder modules answer
those imports, and ShipBrain writes the STL itself (closed blade surface, tip and root capped; index 0 is the root). Export to IGES needs pythonocc-core (conda).
"""
import importlib.machinery as _m
import os, sys, types

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
VENDOR = os.path.join(HERE, 'vendor', 'bladex')
_PREFIX = ('OCC', 'smithers')


class _Any:
    def __init__(self, *a, **k):
        pass

    def __call__(self, *a, **k):
        return _Any()

    def __getattr__(self, n):
        if n.startswith('__'):
            raise AttributeError(n)
        return _Any()


class _Mod(types.ModuleType):
    def __getattr__(self, n):
        if n.startswith('__'):
            raise AttributeError(n)
        return _Any()


class _Finder:
    def find_spec(self, name, path=None, target=None):
        if name.split('.')[0] in _PREFIX:
            return _m.ModuleSpec(name, self)
        return None

    def create_module(self, spec):
        m = _Mod(spec.name)
        m.__path__ = []
        return m

    def exec_module(self, module):
        pass


def _import():
    try:
        import OCC  # noqa: F401  (the real one, if the user has it)
    except ImportError:
        if not any(isinstance(f, _Finder) for f in sys.meta_path):
            sys.meta_path.append(_Finder())
    if VENDOR not in sys.path:
        sys.path.insert(0, VENDOR)
    import bladex
    return bladex


def blade(radii, chord_lengths, pitch, rake, skew_angles, naca='0012', nacas=None, n_points=60):
    """-> (up, down): arrays (n_radii, n_points, 3) of the suction and pressure faces; lengths in the unit given (radius, chord, pitch, rake) and skew in degrees"""
    bx = _import()
    radii = np.asarray(radii, float)
    n = len(radii)
    for nm, v in (('chord_lengths', chord_lengths), ('pitch', pitch), ('rake', rake), ('skew_angles', skew_angles)):
        if len(v) != n:
            raise ValueError(f'{nm} must have one value per radius ({n})')
    digs = nacas or [naca] * n
    sections = np.asarray([bx.NacaProfile(digits=d, n_points=int(n_points)) for d in digs])
    b = bx.Blade(sections=sections, radii=radii, chord_lengths=np.asarray(chord_lengths, float), pitch=np.asarray(pitch, float), rake=np.asarray(rake, float), skew_angles=np.asarray(skew_angles, float))
    b.apply_transformations(reflect=False)
    return np.asarray(b.blade_coordinates_up).transpose(0, 2, 1)[::-1], np.asarray(b.blade_coordinates_down).transpose(0, 2, 1)[::-1]


def write_stl(up, down, path, name='blade'):
    """closed triangle surface from the two faces: up and down meet at the leading and trailing edges; the tip and root sections are capped"""
    n_r, n_p, _ = up.shape
    V, F = [], []
    idx_up = np.arange(n_r * n_p).reshape(n_r, n_p)
    idx_dn = idx_up + n_r * n_p
    V = np.vstack([up.reshape(-1, 3), down.reshape(-1, 3)])
    for i in range(n_r - 1):
        for j in range(n_p - 1):
            for idx, flip in ((idx_up, True), (idx_dn, False)):
                a, b, c, d = idx[i, j], idx[i, j + 1], idx[i + 1, j + 1], idx[i + 1, j]
                F += [[a, c, b], [a, d, c]] if flip else [[a, b, c], [a, c, d]]
    for i in (0, n_r - 1):                                                  # cap the root and the tip: a fan around the section centroid
        ring = np.concatenate([idx_up[i], idx_dn[i][::-1]])
        c = len(V)
        V = np.vstack([V, V[ring].mean(axis=0)])
        for k in range(len(ring)):
            F.append([c, ring[k], ring[(k + 1) % len(ring)]] if i == 0 else [c, ring[(k + 1) % len(ring)], ring[k]])
    V = np.asarray(V)
    F = np.asarray(F)
    key = np.round(V, 7)
    uniq, inv = np.unique(key, axis=0, return_inverse=True)
    F = np.asarray(inv).reshape(-1)[F.reshape(-1)].reshape(-1, 3)
    ok = (F[:, 0] != F[:, 1]) & (F[:, 1] != F[:, 2]) & (F[:, 0] != F[:, 2])
    F = F[ok]
    with open(path, 'w') as f:
        f.write(f'solid {name}\n')
        for t in F:
            a, b, c = uniq[t[0]], uniq[t[1]], uniq[t[2]]
            nrm = np.cross(b - a, c - a)
            nrm = nrm / (np.linalg.norm(nrm) or 1.0)
            f.write(f'facet normal {nrm[0]:.6g} {nrm[1]:.6g} {nrm[2]:.6g}\n outer loop\n')
            for q in (a, b, c):
                f.write(f'  vertex {q[0]:.7g} {q[1]:.7g} {q[2]:.7g}\n')
            f.write(' endloop\nendfacet\n')
        f.write(f'endsolid {name}\n')
    return path
