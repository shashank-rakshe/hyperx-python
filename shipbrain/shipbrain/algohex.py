"""
Frame-field hexahedral meshing with AlgoHex (https://github.com/cgg-bern/AlgoHex, AGPL-3.0, David Bommes, Heng Liu et al.;
"Locally Meshable Frame Fields", ACM TOG 2023). AlgoHex turns a tetrahedral mesh into a hexahedral mesh whose cells follow a
smooth frame field (aligned with the surface and sharp features) - better shaped than a voxel grid on curved parts.

AlgoHex is a C++ program with several research libraries (OpenVolumeMesh, CoMISo, libHexEx, QGP3D, IPOPT, Bonmin). Two of them are
hosted only on RWTH Aachen's GitLab, which ShipBrain's cloud sandbox cannot reach, so AlgoHex is NOT built inside the sandbox:
  * on GitHub's computers the workflow .github/workflows/shipbrain-algohex.yml builds it from its sources as written and runs it on
    its own demo and on parts meshed by ShipBrain; the results (meshes + quality) are published as the release "algohex-latest";
  * on the user's computer ShipBrain runs an AlgoHex the user built (HexMeshing on the PATH, ALGOHEX_EXE) or its Docker / Podman
    image (the repository's Dockerfile, image name "algohex").

ShipBrain's own parts (no AlgoHex code):
  tets_from_hexes / write_vtk   the tetrahedral input, made from ShipBrain's own hex mesher (each hex split into 6 tets along one
                                diagonal - conforming on a structured grid), VTK 2.0 ASCII as AlgoHex reads it; AlgoHex finds the
                                sharp features itself by dihedral angle
  read_ovm / hexes_from_ovm     AlgoHex writes OpenVolumeMesh ASCII (.ovm); this reads vertices, edges, faces and cells and puts each
                                hexahedron into C3D8 node order (positive volume)
  report                        cell count, volume, scaled Jacobian (the same check as hex_mesh)
"""
import json, math, os, re, shutil, subprocess

import numpy as np

# 6 tetrahedra around the main diagonal 0-6 of a C3D8 hexahedron (bottom 0-3, top 4-7)
_SIX = [(0, 1, 2, 6), (0, 2, 3, 6), (0, 3, 7, 6), (0, 7, 4, 6), (0, 4, 5, 6), (0, 5, 1, 6)]


def tet_volumes(X, T):
    X = np.asarray(X, float)
    T = np.asarray(T, int)
    a, b, c, d = (X[T[:, i]] for i in range(4))
    return np.einsum('ij,ij->i', np.cross(b - a, c - a), d - a) / 6.0


def tets_from_hexes(X, H):
    """split every hexahedron into 6 tetrahedra; all tets get a positive volume (orientation fixed if needed)"""
    T = np.array([[h[i] for i in t] for h in H for t in _SIX], int)
    v = tet_volumes(X, T)
    if np.sum(v) < 0:
        T[:, [1, 2]] = T[:, [2, 1]]
        v = -v
    bad = int(np.sum(v <= 0))
    return T, v, bad


def write_vtk(X, T, path, title='ShipBrain tetrahedral mesh for AlgoHex'):
    """VTK 2.0 ASCII unstructured grid of tetrahedra (cell type 10)"""
    X = np.asarray(X, float)
    with open(path, 'w') as f:
        f.write(f'# vtk DataFile Version 2.0\n{title}\nASCII\nDATASET UNSTRUCTURED_GRID\nPOINTS {len(X)} double\n')
        for x in X:
            f.write(f'{x[0]:.9g} {x[1]:.9g} {x[2]:.9g}\n')
        f.write(f'CELLS {len(T)} {5 * len(T)}\n')
        for t in T:
            f.write(f'4 {t[0]} {t[1]} {t[2]} {t[3]}\n')
        f.write(f'CELL_TYPES {len(T)}\n')
        f.write('10\n' * len(T))
    return path


def prepare(src, size, out, feature_angle=35.0):
    """part (STEP / STL ...) -> ShipBrain hex mesh -> tetrahedra -> AlgoHex input (.vtk); returns a report"""
    from . import hexmesh
    X, H, rep = hexmesh.mesh(src, float(size), feature_angle=feature_angle)
    T, v, bad = tets_from_hexes(X, H)
    if bad:
        raise ValueError(f'{bad} tetrahedra with zero or negative volume after splitting the hex mesh: use a smaller cell size')
    write_vtk(X, T, out)
    return {'tet_file': out, 'nodes': int(len(X)), 'tets': int(len(T)), 'volume': float(np.sum(v)),
            'exact_volume': rep.get('exact_volume'), 'hex_cell_size': rep.get('cell_size')}


# ====================================================================== AlgoHex's output (OpenVolumeMesh ASCII)
def read_ovm(path):
    """OpenVolumeMesh ASCII -> vertices (n x 3), edges (m x 2), faces [halfedge lists], cells [halfface lists]"""
    tok = open(path).read().split()
    i = 0

    def nxt():
        nonlocal i
        i += 1
        return tok[i - 1]
    if nxt() != 'OVM' or nxt().upper() != 'ASCII':
        raise ValueError('not an OpenVolumeMesh ASCII file')
    data = {}
    while i < len(tok):
        key = nxt()
        low = key.lower()
        if low == 'vertices':
            n = int(nxt())
            data['V'] = np.array([[float(nxt()) for _ in range(3)] for _ in range(n)])
        elif low == 'edges':
            n = int(nxt())
            data['E'] = np.array([[int(nxt()), int(nxt())] for _ in range(n)], int)
        elif low == 'faces':
            n = int(nxt())
            F = []
            for _ in range(n):
                k = int(nxt())
                F.append([int(nxt()) for _ in range(k)])
            data['F'] = F
        elif low in ('polyhedra', 'cells'):
            n = int(nxt())
            C = []
            for _ in range(n):
                k = int(nxt())
                C.append([int(nxt()) for _ in range(k)])
            data['C'] = C
            break                                            # properties follow; not needed
    if 'V' not in data or 'C' not in data:
        raise ValueError('the .ovm file has no vertices or no cells')
    return data


def _face_loop(data, hf):
    """vertex loop of a halfface (halfface 2f = face as stored, 2f + 1 = reversed); halfedge 2e = edge as stored"""
    E, F = data['E'], data['F']
    f, rev = divmod(hf, 2)
    loop = []
    for he in F[f]:
        e, r = divmod(he, 2)
        loop.append(int(E[e][1] if r else E[e][0]))
    return loop[::-1] if rev else loop


def cells_from_ovm(data):
    """tetrahedra and hexahedra (C3D8 node order, positive volume) from the cells"""
    V = data['V']
    tets, hexes, other = [], [], 0
    for cell in data['C']:
        loops = [_face_loop(data, hf) for hf in cell]
        verts = sorted({v for l in loops for v in l})
        if len(cell) == 4 and len(verts) == 4:
            t = list(verts)
            if tet_volumes(V, [t])[0] < 0:
                t[1], t[2] = t[2], t[1]
            tets.append(t)
        elif len(cell) == 6 and len(verts) == 8 and all(len(l) == 4 for l in loops):
            bot = loops[0]
            edges = {frozenset((l[k], l[(k + 1) % 4])) for l in loops for k in range(4)}
            top = []
            for b in bot:
                up = [v for v in verts if v not in bot and frozenset((b, v)) in edges]
                if len(up) != 1:
                    break
                top.append(up[0])
            if len(top) != 4:
                other += 1
                continue
            h = bot + top
            from .hexmesh import scaled_jacobian
            if float(np.min(scaled_jacobian(V, [h]))) < 0:
                h = bot[::-1] + top[::-1]
            hexes.append(h)
        else:
            other += 1
    return np.array(tets, int).reshape(-1, 4), np.array(hexes, int).reshape(-1, 8), other


def hex_volume(X, H):
    """sum of the 6-tet split volumes (exact for planar faces)"""
    if len(H) == 0:
        return 0.0
    T = np.array([[h[i] for i in t] for h in H for t in _SIX], int)
    return float(np.sum(tet_volumes(X, T)))


def report(ovm_path, exact_volume=None):
    from .hexmesh import scaled_jacobian
    data = read_ovm(ovm_path)
    V = data['V']
    T, H, other = cells_from_ovm(data)
    out = {'file': os.path.basename(ovm_path), 'vertices': int(len(V)), 'hexahedra': int(len(H)), 'tetrahedra': int(len(T)),
           'other_cells': int(other)}
    if len(H):
        sj = scaled_jacobian(V, H)
        out.update({'min_scaled_jacobian': round(float(np.min(sj)), 4), 'mean_scaled_jacobian': round(float(np.mean(sj)), 4),
                    'inverted': int(np.sum(sj <= 0)), 'volume': hex_volume(V, H)})
    elif len(T):
        out['volume'] = float(np.sum(tet_volumes(V, T)))
    if exact_volume and out.get('volume'):
        out['volume_error_percent'] = round((out['volume'] / exact_volume - 1) * 100, 3)
    return out


def to_inp(ovm_path, out, E=206000.0, nu=0.3):
    """AlgoHex hex mesh -> CalculiX / Abaqus input (C3D8)"""
    from .hexmesh import to_model
    data = read_ovm(ovm_path)
    _, H, _ = cells_from_ovm(data)
    if not len(H):
        raise ValueError('no hexahedra in ' + os.path.basename(ovm_path))
    m = to_model(data['V'], H, os.path.splitext(os.path.basename(out))[0], E, nu)
    m.write(out)
    return out


# ====================================================================== running AlgoHex where it is installed
def exe():
    for c in (os.environ.get('ALGOHEX_EXE'), shutil.which('HexMeshing')):
        if c and os.path.isfile(c):
            return [c]
    for tool in ('podman', 'docker'):
        t = shutil.which(tool)
        if t:
            try:
                if subprocess.run([t, 'image', 'inspect', 'algohex'], capture_output=True, timeout=30).returncode == 0:
                    return [t, 'algohex']
            except Exception:
                pass
    return None


def run(tet_file, out_file, timeout=7200, extra=()):
    x = exe()
    if not x:
        raise RuntimeError('AlgoHex is not installed: build it from https://github.com/cgg-bern/AlgoHex (needs IPOPT, Bonmin, '
                           'SuiteSparse) or build its container image "algohex" (lots of memory), then ask again. '
                           'Results of AlgoHex runs on GitHub are in the release algohex-latest.')
    wd = os.path.dirname(os.path.abspath(tet_file))
    if len(x) == 2:
        cmd = [x[0], 'run', '--rm', '-v', f'{wd}:/work', x[1], 'HexMeshing', '-i', '/work/' + os.path.basename(tet_file),
               '-o', '/work/' + os.path.basename(out_file)] + list(extra)
    else:
        cmd = x + ['-i', tet_file, '-o', out_file] + list(extra)
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=wd)
    if r.returncode or not os.path.exists(out_file):
        raise RuntimeError('AlgoHex failed: ' + ' | '.join([l for l in (r.stdout + r.stderr).splitlines() if l.strip()][-4:]))
    return out_file
