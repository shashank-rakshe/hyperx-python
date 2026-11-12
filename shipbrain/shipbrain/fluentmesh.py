"""
Fluent mesh file (.msh, ASCII) written by ShipBrain from its own grid - for ANSYS Fluent, and for programs that read Fluent meshes (OpenFOAM's fluentMeshToFoam,
STAR-CCM+ import, Ansys Meshing / Workbench). Written in Fluent's documented format: sections 2 (dimension), 10 (nodes), 12 (cells), 13 (faces), 45 (zones), hex numbers.

The writer is checked without Fluent: OpenFOAM's fluentMeshToFoam reads the file back and checkMesh must pass (tests/test_cfd_export.py).
"""
import os

import numpy as np

# Fluent boundary type ids (section 13)
BC = {'interior': 2, 'wall': 3, 'pressure-inlet': 4, 'pressure-outlet': 5, 'symmetry': 7, 'velocity-inlet': 10, 'outflow': 36}


def write_msh(topo, zone_types, path, dim=3, title='ShipBrain mesh'):
    """topo = openfoam.write_polymesh(...)['topology']; zone_types = {patch name: fluent bc name} (default wall)"""
    pts, faces, owner, neigh, patches = topo['points'], topo['faces'], topo['owner'], topo['neighbour'], topo['patches']
    n_pts, n_faces, n_cells, n_int = len(pts), len(faces), topo['n_cells'], len(neigh)
    h = lambda v: format(v, 'x')
    out = [f'(0 "{title}")', '(0 "Dimensions:")', f'(2 {dim})', '(0 "Grid:")',
           f'(10 (0 1 {h(n_pts)} 0 {dim}))', f'(12 (0 1 {h(n_cells)} 0 0))', f'(13 (0 1 {h(n_faces)} 0 0))']
    out.append(f'(10 (1 1 {h(n_pts)} 1 {dim})(')
    out += [' '.join(f'{v:.10g}' for v in p[:dim]) for p in pts]
    out.append('))')
    out.append(f'(12 (2 1 {h(n_cells)} 1 4))')                              # cell zone 2: fluid, all hexahedra (element type 4)
    zid = 3
    first = 1
    zones = []

    def face_zone(name, bc, rows):
        nonlocal zid, first
        last = first + len(rows) - 1
        out.append(f'(13 ({h(zid)} {h(first)} {h(last)} {h(bc)} 4)(')
        out.extend(rows)
        out.append('))')
        zones.append((zid, 'interior' if bc == BC['interior'] else None, name, bc))
        zid += 1
        first = last + 1
    # Fluent orients a face so that its normal (right-hand rule of the node order) points away from c0, the first cell; OpenFOAM's points from the owner to the
    # neighbour, so the node order is reversed here and the owner is c0 (a boundary face has c1 = 0). Checked by reading the file back with OpenFOAM's importer.
    rows = [' '.join(h(v + 1) for v in faces[i][::-1]) + f' {h(owner[i] + 1)} {h(neigh[i] + 1)}' for i in range(n_int)]
    face_zone('interior-1', BC['interior'], rows)
    for name, start, n in patches:
        bc = BC[zone_types.get(name, 'wall')]
        rows = [' '.join(h(v + 1) for v in faces[start + i][::-1]) + f' {h(owner[start + i] + 1)} 0' for i in range(n)]
        face_zone(name, bc, rows)
    out.append('(0 "Zone sections:")')
    out.append('(45 (2 fluid fluid-zone)())')
    for z, kind, name, bc in zones:
        tname = {v: k for k, v in BC.items()}[bc]
        out.append(f'(45 ({h(z)} {tname} {name})())')
    open(path, 'w').write('\n'.join(out) + '\n')
    return path
