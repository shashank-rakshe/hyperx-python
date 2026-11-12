"""
Nastran files with pyNastran (https://github.com/SteveDoyle2/pyNastran, BSD-3, installed with `pip install pyNastran`): read a bulk data deck (.bdf / .nas / .dat) into a summary with mass and bounding box,
read an OP2 result file (largest displacement, largest von Mises stress, per subcase), and write a plain cantilever plate deck (CQUAD4, PSHELL, MAT1, SPC1, FORCE) that can be run in any Nastran-format
solver (Nastran, MYSTRAN, OptiStruct, Simcenter) or checked with ShipBrain's own FE tools.
"""
import os

import numpy as np


def _need():
    if not hasattr(np, 'in1d'):                                              # pyNastran 1.4 still calls np.in1d, removed in NumPy 2.4
        np.in1d = np.isin
    try:
        import pyNastran  # noqa: F401
    except ImportError as e:
        raise RuntimeError('pyNastran is not installed: pip install pyNastran') from e


def read_bdf(path):
    _need()
    from pyNastran.bdf.bdf import BDF
    from pyNastran.bdf.mesh_utils.mass_properties import mass_properties
    m = BDF(debug=False)
    m.read_bdf(path, punch=False, validate=False)
    xyz = np.array([n.get_position() for n in m.nodes.values()]) if m.nodes else np.zeros((0, 3))
    try:
        mass, cg, _ = mass_properties(m)
        mass, cg = float(mass), [round(float(c), 6) for c in cg]
    except Exception:
        mass, cg = None, None
    cards = dict(sorted(m.card_count.items(), key=lambda kv: -kv[1]))
    return {'nodes': len(m.nodes), 'elements': len(m.elements), 'properties': len(m.properties), 'materials': len(m.materials), 'loads': sum(len(v) for v in m.loads.values()),
            'spcs': sum(len(v) for v in m.spcs.values()), 'subcases': sorted(k for k in m.subcases if k != 0),
            'sol': m.sol, 'bbox_min': xyz.min(axis=0).round(6).tolist() if len(xyz) else None, 'bbox_max': xyz.max(axis=0).round(6).tolist() if len(xyz) else None,
            'mass': mass, 'centre_of_mass': cg, 'cards': dict(list(cards.items())[:15]), 'element_types': sorted({e.type for e in m.elements.values()})}


def read_op2(path):
    _need()
    from pyNastran.op2.op2 import read_op2 as _r
    m = _r(path, debug=False, build_dataframe=False)
    out = {'displacement': {}, 'von_mises': {}}
    for sub, t in m.displacements.items():
        d = t.data[0, :, :3]
        mag = np.linalg.norm(d, axis=1)
        k = int(np.argmax(mag))
        out['displacement'][int(sub)] = {'max': float(mag[k]), 'node': int(t.node_gridtype[k, 0]), 'components_at_max': [float(x) for x in d[k]]}
    st = m.op2_results.stress
    for name in ('cquad4_stress', 'ctria3_stress', 'cquad8_stress', 'ctria6_stress', 'cquad4_composite_stress', 'ctria3_composite_stress'):
        for sub, t in (getattr(st, name, None) or {}).items():
            h = t.get_headers()
            if 'von_mises' in h:
                vm = t.data[:, :, h.index('von_mises')]
                out['von_mises'].setdefault(int(sub), {})[name] = float(np.nanmax(vm))
    for sub in out['von_mises']:
        out['von_mises'][sub]['max'] = max(out['von_mises'][sub].values())
    return out


def write_plate(path, L, W, t, nx=20, ny=10, E=210e9, nu=0.3, rho=7850.0, force_N=1000.0, direction=3):
    """cantilever plate in the xy plane: x = 0 clamped, a total force_N at x = L spread over the free edge (SI units: m, N, Pa, kg/m3)"""
    _need()
    from pyNastran.bdf.bdf import BDF
    m = BDF(debug=False)
    nid = lambda i, j: j * (nx + 1) + i + 1
    for j in range(ny + 1):
        for i in range(nx + 1):
            m.add_grid(nid(i, j), [L * i / nx, W * j / ny, 0.0])
    m.add_mat1(1, E, None, nu, rho=rho)
    m.add_pshell(1, mid1=1, t=t)
    eid = 1
    for j in range(ny):
        for i in range(nx):
            m.add_cquad4(eid, 1, [nid(i, j), nid(i + 1, j), nid(i + 1, j + 1), nid(i, j + 1)])
            eid += 1
    m.add_spc1(1, '123456', [nid(0, j) for j in range(ny + 1)])
    edge = [nid(nx, j) for j in range(ny + 1)]
    for k, n in enumerate(edge):
        share = 0.5 if k in (0, ny) else 1.0                                  # trapezoid weights: the edge nodes at the corners carry half
        vec = [0.0, 0.0, 0.0]
        vec[int(direction) - 1] = 1.0
        m.add_force(2, n, force_N * share / ny, vec)
    m.sol = 101
    from pyNastran.bdf.case_control_deck import CaseControlDeck
    m.case_control_deck = CaseControlDeck(['SUBCASE 1', 'SPC = 1', 'LOAD = 2', 'DISPLACEMENT(SORT1,REAL)=ALL', 'STRESS(SORT1,REAL,VONMISES,BILIN)=ALL'])
    m.write_bdf(path, size=8, is_double=False)
    return path
