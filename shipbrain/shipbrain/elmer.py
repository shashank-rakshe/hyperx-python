"""
Flow (CFD) and fluid-structure interaction (FSI) with Elmer FEM (https://www.elmerfem.org, GPL-2+, CSC - IT Center for Science).

Elmer is the solver; ShipBrain writes everything around it with its own code:
  Mesh2D / Mesh3D   a block-structured grid made by ShipBrain (no gmsh, no ElmerGrid): graded spacing, cells assigned to bodies, conforming
                    fluid-structure interface; written in Elmer's own mesh format (mesh.header / nodes / elements / boundary)
  sif builders      the solver input (.sif) for incompressible laminar flow, SST k-omega turbulence, and two-way FSI (fluid + elastic structure with
                    mesh update, Elmer's "FSI BC")
  run               ElmerSolver on the PATH (or ELMER_HOME), results as VTU
  read_vtu          ASCII VTU of the result -> fields at the nodes (velocity, pressure, displacement ...)

Needs Elmer installed (ElmerSolver on the PATH): see installs.py, or let the GitHub workflow shipbrain-elmer.yml build and run it.
"""
import json, math, os, re, shutil, subprocess

import numpy as np

# Elmer element type numbers
E_LINE, E_TRI, E_QUAD, E_TET, E_HEX = 202, 303, 404, 504, 808


def _grid_axis(L, n, ratio=1.0, origin=0.0):
    """n cells from origin to origin + L; ratio = last / first cell size (geometric)"""
    if n < 1:
        raise ValueError('need at least one cell')
    if abs(ratio - 1) < 1e-9 or n == 1:
        return origin + np.linspace(0, L, n + 1)
    q = ratio ** (1.0 / (n - 1))
    w = q ** np.arange(n)
    c = np.concatenate([[0], np.cumsum(w)]) / w.sum()
    return origin + L * c


def axis_from_segments(segs):
    """segs = [(x_end, n_cells, ratio), ...] from x = first value of the list's start: [(x0,), (x1, n, ratio), ...] -> coordinates"""
    xs = [float(segs[0][0])]
    for s in segs[1:]:
        x1, n = float(s[0]), int(s[1])
        r = float(s[2]) if len(s) > 2 else 1.0
        a = _grid_axis(x1 - xs[-1], n, r, xs[-1])
        xs += list(a[1:])
    return np.array(xs)


class Mesh:
    """tensor-product grid (2D: quads, 3D: hexahedra) whose cells belong to bodies (0 = no cell); boundary faces get ids from a tagger"""

    def __init__(self, axes, body):
        self.axes = [np.asarray(a, float) for a in axes]
        self.dim = len(self.axes)
        if self.dim not in (2, 3):
            raise ValueError('2D or 3D')
        self.shape = tuple(len(a) - 1 for a in self.axes)
        self.cells = {}                                   # index tuple -> body
        for idx in np.ndindex(*self.shape):
            c = [(self.axes[d][i] + self.axes[d][i + 1]) / 2 for d, i in enumerate(idx)]
            b = int(body(*c))
            if b > 0:
                self.cells[idx] = b

    # --------------------------------------------------------------
    def build(self, tag):
        """tag(centre of the face, axis, side(+1/-1 = the face looks towards +/- axis), body_here, body_other) -> boundary id or None.
        Exterior faces and faces between different bodies are offered to tag; faces it returns None for are left free (natural BC)."""
        nid = {}
        nodes = []

        def node(ix):
            if ix not in nid:
                nid[ix] = len(nodes) + 1
                nodes.append([self.axes[d][i] for d, i in enumerate(ix)])
            return nid[ix]
        elems = []
        eid = {}
        for idx, b in sorted(self.cells.items()):
            if self.dim == 2:
                i, j = idx
                ns = [node((i, j)), node((i + 1, j)), node((i + 1, j + 1)), node((i, j + 1))]
            else:
                i, j, k = idx
                ns = [node((i, j, k)), node((i + 1, j, k)), node((i + 1, j + 1, k)), node((i, j + 1, k)),
                      node((i, j, k + 1)), node((i + 1, j, k + 1)), node((i + 1, j + 1, k + 1)), node((i, j + 1, k + 1))]
            elems.append((b, E_QUAD if self.dim == 2 else E_HEX, ns))
            eid[idx] = len(elems)
        bnd = []
        for idx, b in sorted(self.cells.items()):
            for ax in range(self.dim):
                for side in (-1, 1):
                    nb = list(idx)
                    nb[ax] += side
                    nb = tuple(nb)
                    other = self.cells.get(nb, 0)
                    if other == b:
                        continue
                    if other and side < 0:                      # an interface between two bodies is written once (from the lower cell)
                        continue
                    c = [(self.axes[d][i] + self.axes[d][i + 1]) / 2 for d, i in enumerate(idx)]
                    c[ax] = self.axes[ax][idx[ax] + (1 if side > 0 else 0)]
                    bid = tag(tuple(c), ax, side, b, other)
                    if not bid:
                        continue
                    lo = idx[ax] + (1 if side > 0 else 0)
                    fnodes = self._face_nodes(idx, ax, lo, node)
                    bnd.append((int(bid), eid[idx], eid.get(nb, 0), E_LINE if self.dim == 2 else E_QUAD, fnodes))
        return {'nodes': np.array(nodes), 'elements': elems, 'boundary': bnd}

    def _face_nodes(self, idx, ax, lo, node):
        if self.dim == 2:
            i, j = idx
            if ax == 0:
                return [node((lo, j)), node((lo, j + 1))]
            return [node((i, lo)), node((i + 1, lo))]
        i, j, k = idx
        if ax == 0:
            return [node((lo, j, k)), node((lo, j + 1, k)), node((lo, j + 1, k + 1)), node((lo, j, k + 1))]
        if ax == 1:
            return [node((i, lo, k)), node((i + 1, lo, k)), node((i + 1, lo, k + 1)), node((i, lo, k + 1))]
        return [node((i, j, lo)), node((i + 1, j, lo)), node((i + 1, j + 1, lo)), node((i, j + 1, lo))]


def write_mesh(m, folder):
    """Elmer mesh files from Mesh.build() output"""
    os.makedirs(folder, exist_ok=True)
    nodes, elems, bnd = m['nodes'], m['elements'], m['boundary']
    dim3 = nodes.shape[1] == 3
    with open(os.path.join(folder, 'mesh.nodes'), 'w') as f:
        for i, x in enumerate(nodes, 1):
            f.write(f"{i} -1 {x[0]:.12g} {x[1]:.12g} {x[2] if dim3 else 0.0:.12g}\n")
    with open(os.path.join(folder, 'mesh.elements'), 'w') as f:
        for i, (b, t, ns) in enumerate(elems, 1):
            f.write(f"{i} {b} {t} {' '.join(map(str, ns))}\n")
    with open(os.path.join(folder, 'mesh.boundary'), 'w') as f:
        for i, (bid, p1, p2, t, ns) in enumerate(bnd, 1):
            f.write(f"{i} {bid} {p1} {p2} {t} {' '.join(map(str, ns))}\n")
    types = {}
    for _, t, _ in elems:
        types[t] = types.get(t, 0) + 1
    for _, _, _, t, _ in bnd:
        types[t] = types.get(t, 0) + 1
    with open(os.path.join(folder, 'mesh.header'), 'w') as f:
        f.write(f"{len(nodes)} {len(elems)} {len(bnd)}\n{len(types)}\n")
        for t, c in sorted(types.items()):
            f.write(f"{t} {c}\n")
    return folder


# ====================================================================== running Elmer
def exe():
    home = os.environ.get('ELMER_HOME')
    for c in ([os.path.join(home, 'bin', 'ElmerSolver')] if home else []) + [shutil.which('ElmerSolver')]:
        if c and os.path.isfile(c):
            return c
    return None


def run(sif, workdir, timeout=7200):
    x = exe()
    if not x:
        raise RuntimeError('Elmer is not installed (ElmerSolver not on the PATH): install Elmer FEM (free, https://www.elmerfem.org) or use the '
                           'GitHub workflow shipbrain-elmer.yml, then ask again.')
    env = dict(os.environ)
    home = os.environ.get('ELMER_HOME') or os.path.dirname(os.path.dirname(x))
    env['ELMER_HOME'] = home
    env['ELMER_LIB'] = os.path.join(home, 'share', 'elmersolver', 'lib')
    env['LD_LIBRARY_PATH'] = os.pathsep.join([os.path.join(home, 'lib'), os.path.join(home, 'lib', 'elmersolver'), env.get('LD_LIBRARY_PATH', '')])
    r = subprocess.run([x, os.path.basename(sif)], cwd=workdir, capture_output=True, text=True, timeout=timeout, env=env)
    log = r.stdout + r.stderr
    open(os.path.join(workdir, 'elmer.log'), 'w').write(log)
    if r.returncode or 'ERROR' in log.upper().split('SOLVER TOTAL TIME')[0][-4000:] and 'ELMER SOLVER FINISHED' not in log.upper():
        errs = [l for l in log.splitlines() if 'ERROR' in l.upper() or 'FATAL' in l.upper()][:6]
        raise RuntimeError('ElmerSolver failed: ' + ('; '.join(errs) or log[-600:]))
    return log


def read_vtu(path):
    """ASCII VTU written by Elmer: points, cells (connectivity, types) and point data -> dict"""
    import xml.etree.ElementTree as ET
    root = ET.parse(path).getroot()
    piece = root.find('.//Piece')
    out = {}

    def arr(el, dtype=float):
        return np.array(el.text.split(), dtype=dtype)
    pts = piece.find('Points/DataArray')
    out['points'] = arr(pts).reshape(-1, int(pts.get('NumberOfComponents', 3)))
    cells = piece.find('Cells')
    for da in cells.findall('DataArray'):
        out[da.get('Name')] = arr(da, int)
    out['fields'] = {}
    pd = piece.find('PointData')
    if pd is not None:
        for da in pd.findall('DataArray'):
            a = arr(da)
            nc = int(da.get('NumberOfComponents', 1))
            out['fields'][da.get('Name')] = a.reshape(-1, nc) if nc > 1 else a
    return out


# ====================================================================== cases
FLUIDS = {'water': (998.2, 1.002e-3), 'seawater': (1025.0, 1.08e-3), 'air': (1.204, 1.825e-5), 'oil': (870.0, 0.05)}   # density kg/m3, dynamic viscosity Pa s
MATERIALS = {'steel': (206e9, 0.30, 7850.0), 'aluminium': (70e9, 0.33, 2700.0), 'rubber': (1e7, 0.49, 1100.0), 'plastic': (2.5e9, 0.38, 1200.0)}


def channel_plate(length=2.0, height=1.0, plate_x=0.5, plate_t=0.02, plate_h=0.4, velocity=1.0, fluid='water', cell=0.02, plate='rigid',
                  structure='steel', turbulence='laminar', steady=True, dt=None, steps=None, three_d_width=None, name='case', workdir='.'):
    """A plate (height plate_h, thickness plate_t) standing on the bottom wall of a channel; flow from the left at `velocity` m/s.
    plate = 'rigid' (a wall) or 'elastic' (FSI: the plate is an elastic body clamped at its foot and bent by the flow).
    All lengths in metres. Returns the file names and the numbers the post-processing needs."""
    rho, mu = FLUIDS[fluid] if isinstance(fluid, str) else fluid
    if plate not in ('rigid', 'elastic'):
        raise ValueError("plate must be 'rigid' or 'elastic'")
    cx = max(cell, plate_t / 3)
    nup = max(4, int(round(plate_x / (cell * 2.5))))
    ndn = max(6, int(round((length - plate_x - plate_t) / (cell * 2.5))))
    xs = axis_from_segments([(0.0,), (plate_x, nup, 1 / 8.0), (plate_x + plate_t, max(3, int(round(plate_t / cx)))), (length, ndn, 8.0)])
    nh = max(6, int(round(plate_h / cell)))
    nr = max(6, int(round((height - plate_h) / (cell * 2.0))))
    ys = axis_from_segments([(0.0,), (plate_h, nh), (height, nr, 6.0)])
    x0, x1 = plate_x, plate_x + plate_t

    def body(x, y):
        inside = x0 < x < x1 and y < plate_h
        return (2 if plate == 'elastic' else 0) if inside else 1
    m = Mesh([xs, ys], body)
    eps = 1e-9 * max(length, height)

    def tag(c, ax, side, b, other):
        x, y = c
        if b == 2 and not other:
            return 6 if abs(y) < eps else None                    # clamped foot of the plate
        if b == 1 and other == 2 or b == 2 and other == 1:
            return 5                                              # fluid - structure interface
        if b == 1 and not other:
            if ax == 0 and abs(x) < eps:
                return 1                                          # inlet
            if ax == 0 and abs(x - length) < eps:
                return 2                                          # outlet
            if ax == 1 and abs(y) < eps:
                return 3                                          # bottom wall
            if ax == 1 and abs(y - height) < eps:
                return 4                                          # top wall
            return 5                                              # wall of the rigid plate
        return None
    mesh = m.build(tag)
    mdir = os.path.join(workdir, name)
    write_mesh(mesh, mdir)
    info = {'mesh_dir': name, 'nodes': int(len(mesh['nodes'])), 'cells': len(mesh['elements']), 'rho': rho, 'mu': mu,
            'reynolds_plate_height': rho * velocity * plate_h / mu, 'reynolds_channel_height': rho * velocity * height / mu}
    sif = os.path.join(workdir, name + '.sif')
    open(sif, 'w').write(_sif(name, rho, mu, velocity, plate, structure, turbulence, steady, dt, steps, height))
    info['sif'] = os.path.basename(sif)
    return info


def _sif(name, rho, mu, U, plate, structure, turbulence, steady, dt, steps, H):
    E, nu, rhos = MATERIALS[structure] if isinstance(structure, str) else structure
    fsi = plate == 'elastic'
    trans = not steady
    L = []
    a = L.append
    a(f'Header\n  Mesh DB "." "{name}"\nEnd\n')
    a('Simulation\n  Max Output Level = 4\n  Coordinate System = Cartesian 2D')
    if trans:
        a(f'  Simulation Type = Transient\n  Timestepping Method = BDF\n  BDF Order = 2\n  Timestep Sizes = {dt}\n  Timestep Intervals = {steps}\n  Steady State Max Iterations = {20 if fsi else 1}')
    else:
        a(f'  Simulation Type = Steady State\n  Steady State Max Iterations = {60 if fsi else 40}\n  Steady State Min Iterations = 1')
    a('  Output Intervals = 0\nEnd\n')
    a('Body 1\n  Name = "Fluid"\n  Equation = 1\n  Material = 1\n  Initial Condition = 1\nEnd')
    if fsi:
        a('Body 2\n  Name = "Plate"\n  Equation = 2\n  Material = 2\n  Initial Condition = 1\nEnd')
    a(f'\nInitial Condition 1\n  Velocity 1 = {U}\n  Velocity 2 = 0\n  Pressure = 0\n' + ('  Displacement 1 = 0\n  Displacement 2 = 0\n' if fsi else '') + 'End\n')
    a(f'Material 1\n  Name = "Fluid"\n  Density = {rho}\n  Viscosity = {mu}\n' + ('  Viscosity Model = sst k-omega\n' if turbulence == 'sst' else '') + 'End')
    if fsi:
        a(f'Material 2\n  Name = "Plate"\n  Density = {rhos}\n  Youngs Modulus = {E}\n  Poisson Ratio = {nu}\nEnd')
    n = 1
    ns = None
    a(f'\nSolver {n}\n  Equation = Navier-Stokes\n  Stabilization Method = Stabilized\n  Calculate Loads = Logical True\n'
      '  Linear System Solver = Direct\n  Linear System Direct Method = UMFPACK\n'
      f'  Nonlinear System Max Iterations = {1 if (fsi or trans) else 30}\n  Nonlinear System Convergence Tolerance = 1.0e-6\n'
      '  Nonlinear System Newton After Iterations = 3\n  Nonlinear System Newton After Tolerance = 1.0e-3\n  Nonlinear System Relaxation Factor = 1.0\n'
      '  Steady State Convergence Tolerance = 1.0e-6\nEnd')
    act = [1]
    if fsi:
        a('\nSolver 2\n  Equation = Elasticity Solver\n  Variable = Displacement\n  Variable DOFs = 2\n  Procedure = File "ElasticSolve" "ElasticSolver"\n'
          '  Linear System Solver = Direct\n  Linear System Direct Method = UMFPACK\n  Calculate Stresses = Logical True\n'
          '  Nonlinear System Max Iterations = 1\n  Steady State Convergence Tolerance = 1.0e-6\nEnd')
        a('\nSolver 3\n  Equation = Mesh Update\n  Linear System Solver = Direct\n  Linear System Direct Method = UMFPACK\n  Steady State Convergence Tolerance = 1.0e-6\nEnd')
    nout = 4 if fsi else 2
    a(f'\nSolver {nout}\n  Exec Solver = After Saving\n  Equation = ResultOutput\n  Procedure = "ResultOutputSolve" "ResultOutputSolver"\n  Output File Name = {name}\n'
      '  Output Format = String vtu\n  Ascii Output = Logical True\n  Vtu Format = Logical True\n  Save Geometry Ids = Logical False\nEnd')
    a('\nEquation 1\n  Active Solvers(' + ('2' if fsi else '1') + ') = ' + ('1 3' if fsi else '1') + '\nEnd')
    if fsi:
        a('Equation 2\n  Active Solvers(1) = 2\n  Plane Stress = Logical True\nEnd')
    a(f'\nBoundary Condition 1\n  Name = "Inlet"\n  Target Boundaries(1) = 1\n  Velocity 1 = {U}\n  Velocity 2 = 0\n' + ('  Mesh Update 1 = 0\n  Mesh Update 2 = 0\n' if fsi else '') + 'End')
    a('Boundary Condition 2\n  Name = "Outlet"\n  Target Boundaries(1) = 2\n  Pressure = 0\n' + ('  Mesh Update 1 = 0\n  Mesh Update 2 = 0\n' if fsi else '') + 'End')
    a('Boundary Condition 3\n  Name = "Bottom"\n  Target Boundaries(1) = 3\n  Velocity 1 = 0\n  Velocity 2 = 0\n' + ('  Mesh Update 1 = 0\n  Mesh Update 2 = 0\n' if fsi else '') + 'End')
    a('Boundary Condition 4\n  Name = "Top"\n  Target Boundaries(1) = 4\n  Velocity 1 = 0\n  Velocity 2 = 0\n' + ('  Mesh Update 1 = 0\n  Mesh Update 2 = 0\n' if fsi else '') + 'End')
    if fsi:
        a('Boundary Condition 5\n  Name = "Interface"\n  Target Boundaries(1) = 5\n  FSI BC = Logical True\n  Mesh Update 1 = Equals Displacement 1\n'
          '  Mesh Update 2 = Equals Displacement 2\n  Velocity 1 = Equals Mesh Velocity 1\n  Velocity 2 = Equals Mesh Velocity 2\nEnd')
        a('Boundary Condition 6\n  Name = "Clamp"\n  Target Boundaries(1) = 6\n  Displacement 1 = 0\n  Displacement 2 = 0\nEnd')
    else:
        a('Boundary Condition 5\n  Name = "Plate wall"\n  Target Boundaries(1) = 5\n  Velocity 1 = 0\n  Velocity 2 = 0\nEnd')
    return '\n'.join(L) + '\n'
