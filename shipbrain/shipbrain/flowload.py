"""
Flow load on a structure (one-way fluid-structure coupling): the pressure and wall shear that OpenFOAM computed on the faces of a body become nodal forces on the
shell mesh of the same part, which CalculiX then solves for displacement and stress.

  The body in the flow is the part voxelised on ShipBrain's grid (openfoam.build_case with body_file), the shell mesh is the mid-surface of the same part
  (cadplates / platemesh, in mm). Every body face carries its force vector (pressure x area x normal + shear x area, in N); each goes to the nearest shell element
  (centroid), which shares it equally between its nodes. The sum of the nodal forces equals the force OpenFOAM reports on the body - checked in the tests.

  One-way: the bending of the part does not change the flow (it is small for stiff parts). For a flexible plate with strong coupling use elmer_flow (two-way FSI).
"""
import numpy as np


def shell_elements(model):
    """(element id, node ids, centroid mm, unit normal, area mm2) of every quad / tria of an FEModel"""
    out = []
    for eid, e in model.elems.items():
        if e['type'] not in ('quad', 'tria'):
            continue
        P = np.array([model.nodes[n] for n in e['nodes']], float)
        c = P.mean(axis=0)
        n = np.cross(P[2] - P[0], P[3 % len(P)] - P[1]) if len(P) == 4 else np.cross(P[1] - P[0], P[2] - P[0])
        a = 0.5 * np.linalg.norm(n) if len(P) == 4 else 0.5 * np.linalg.norm(n)
        out.append((eid, e['nodes'], c, n / max(np.linalg.norm(n), 1e-30), a))
    return out


def nodal_forces(model, rows, offset):
    """rows = openfoam.results()['body_faces']; offset = info['offset'] (metres, model -> flow frame). Returns {node id: force vector N} in the model frame"""
    from scipy.spatial import cKDTree
    els = shell_elements(model)
    if not els:
        raise ValueError('the structure mesh has no shell elements')
    cen = np.array([e[2] for e in els]) * 1e-3 + np.array(offset)            # element centroids in the flow frame (m)
    tree = cKDTree(cen)
    F = {}
    for ctr, nrm, p, fvec in rows:
        _, k = tree.query(np.array(ctr))
        nodes = els[k][1]
        for n in nodes:
            F[n] = F.get(n, np.zeros(3)) + np.asarray(fvec, float) / len(nodes)
    return F


def write_cload(inp, forces):
    """add *CLOAD lines for the nodal forces (N) to the first *STATIC step of a ShipBrain .inp"""
    s = open(inp).read()
    block = '*CLOAD\n' + ''.join(f'{n}, {d + 1}, {f[d]:.8g}\n' for n, f in sorted(forces.items()) for d in range(3))
    if '*STATIC' not in s:
        raise ValueError('no static step in ' + inp)
    s = s.replace('*STATIC\n', '*STATIC\n' + block, 1)
    open(inp, 'w').write(s)
    return inp
