"""
Flow (CFD) with OpenFOAM (https://www.openfoam.com, GPL-3, OpenCFD / ESI; on Ubuntu: apt install openfoam).

OpenFOAM is the solver (simpleFoam, steady incompressible RANS or laminar); ShipBrain writes everything around it with its own code:
  case_mesh      a block-structured grid made by ShipBrain (no gmsh, no snappyHexMesh, no blockMesh): graded spacing, a body (a box, or any part from a
                 STEP / STL file) cut out of it cell by cell; written directly as an OpenFOAM polyMesh (points, faces, owner, neighbour, boundary)
  case files     0/U p k omega nut, constant/ transportProperties turbulenceProperties, system/ controlDict fvSchemes fvSolution (+ the forces function object)
  results        the fields read straight from OpenFOAM's ASCII output: velocity and pressure in every cell, pressure on every face of the body,
                 force on the body (pressure + viscous) from the forces function object; pictures through viz.render_slice
The body's wall is stair-stepped (cells are cut out whole): fine for blocky parts and plates, rough for curved surfaces - the answer says so.
"""
import glob, math, os, re, shutil, subprocess

import numpy as np

from .elmer import Mesh, axis_from_segments, FLUIDS


def installed():
    return shutil.which('simpleFoam') is not None


def _env():
    """the packaged OpenFOAM (Debian / Ubuntu) needs these set; a normal install that sourced its bashrc already has them"""
    env = dict(os.environ)
    if 'WM_PROJECT_DIR' not in env and os.path.isdir('/usr/share/openfoam/etc'):
        env.update({'WM_PROJECT_DIR': '/usr/share/openfoam', 'WM_PROJECT': 'OpenFOAM', 'FOAM_ETC': '/usr/share/openfoam/etc'})
    return env


def _run(cmd, cwd, timeout=7200):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=_env())
    return r.returncode, (r.stdout or '') + (r.stderr or '')


# ====================================================================== polyMesh writer
def write_polymesh(m, tag, case_dir, patch_types=None):
    """m = elmer.Mesh with one body; tag(face centre, axis, side) -> patch name. Writes constant/polyMesh. Returns the cells and the boundary faces
    {patch: [(centre, normal, area)]} in file order."""
    cells = sorted(m.cells)
    cid = {c: n for n, c in enumerate(cells)}
    pid, pts = {}, []

    def P(ix):
        if ix not in pid:
            pid[ix] = len(pts)
            pts.append([m.axes[d][i] for d, i in enumerate(ix)])
        return pid[ix]

    def face(idx, ax, lo):
        i, j, k = idx
        if ax == 0:
            q = [(lo, j, k), (lo, j + 1, k), (lo, j + 1, k + 1), (lo, j, k + 1)]
        elif ax == 1:
            q = [(i, lo, k), (i, lo, k + 1), (i + 1, lo, k + 1), (i + 1, lo, k)]
        else:
            q = [(i, j, lo), (i + 1, j, lo), (i + 1, j + 1, lo), (i, j + 1, lo)]
        return q                                                      # normal = +axis
    for c in cells:                                                   # points in cell order
        i, j, k = c
        for dk in (0, 1):
            for dj in (0, 1):
                for di in (0, 1):
                    P((i + di, j + dj, k + dk))
    faces, owner, neigh = [], [], []
    for c in cells:
        for ax in (2, 1, 0):
            nb = list(c)
            nb[ax] += 1
            nb = tuple(nb)
            if nb in cid:
                faces.append([P(x) for x in face(c, ax, c[ax] + 1)])
                owner.append(cid[c])
                neigh.append(cid[nb])
    n_int = len(faces)
    by_patch = {}
    for c in cells:
        for ax in range(3):
            for side in (-1, 1):
                nb = list(c)
                nb[ax] += side
                if tuple(nb) in cid:
                    continue
                lo = c[ax] + (1 if side > 0 else 0)
                q = face(c, ax, lo)
                if side < 0:
                    q = q[::-1]
                ctr = [(m.axes[d][c[d]] + m.axes[d][c[d] + 1]) / 2 for d in range(3)]
                ctr[ax] = m.axes[ax][lo]
                name = tag(tuple(ctr), ax, side)
                if name is None:
                    raise ValueError(f'untagged boundary face at {ctr}')
                dims = [m.axes[d][c[d] + 1] - m.axes[d][c[d]] for d in range(3)]
                area = float(np.prod([dims[d] for d in range(3) if d != ax]))
                nrm = [0, 0, 0]
                nrm[ax] = side
                by_patch.setdefault(name, []).append(([P(x) for x in q], cid[c], tuple(ctr), tuple(nrm), area))
    order = list(by_patch)
    start = n_int
    pat_info = []
    for name in order:
        for q, o, ctr, nrm, area in by_patch[name]:
            faces.append(q)
            owner.append(o)
        pat_info.append((name, start, len(by_patch[name])))
        start += len(by_patch[name])
    d = os.path.join(case_dir, 'constant', 'polyMesh')
    os.makedirs(d, exist_ok=True)
    hdr = lambda cls, obj, note='': ('FoamFile\n{\n    version     2.0;\n    format      ascii;\n    class       %s;\n' % cls + (f'    note        "{note}";\n' if note else '')
                                     + '    location    "constant/polyMesh";\n    object      %s;\n}\n\n' % obj)
    note = f'nPoints:{len(pts)}  nCells:{len(cells)}  nFaces:{len(faces)}  nInternalFaces:{n_int}'
    with open(os.path.join(d, 'points'), 'w') as f:
        f.write(hdr('vectorField', 'points') + f'{len(pts)}\n(\n' + ''.join(f'({x[0]:.10g} {x[1]:.10g} {x[2]:.10g})\n' for x in pts) + ')\n')
    with open(os.path.join(d, 'faces'), 'w') as f:
        f.write(hdr('faceList', 'faces') + f'{len(faces)}\n(\n' + ''.join(f'4({q[0]} {q[1]} {q[2]} {q[3]})\n' for q in faces) + ')\n')
    with open(os.path.join(d, 'owner'), 'w') as f:
        f.write(hdr('labelList', 'owner', note) + f'{len(owner)}\n(\n' + '\n'.join(map(str, owner)) + '\n)\n')
    with open(os.path.join(d, 'neighbour'), 'w') as f:
        f.write(hdr('labelList', 'neighbour', note) + f'{len(neigh)}\n(\n' + '\n'.join(map(str, neigh)) + '\n)\n')
    types = patch_types or {}
    with open(os.path.join(d, 'boundary'), 'w') as f:
        f.write(hdr('polyBoundaryMesh', 'boundary') + f'{len(pat_info)}\n(\n')
        for name, st, n in pat_info:
            t = types.get(name, 'patch')
            f.write(f'    {name}\n    {{\n        type {t};\n' + ('        inGroups List<word> 1(wall);\n' if t == 'wall' else '')
                    + f'        nFaces {n};\n        startFace {st};\n    }}\n')
        f.write(')\n')
    return {'axes': m.axes, 'cells': cells, 'cell_centres': np.array([[(m.axes[d][c[d]] + m.axes[d][c[d] + 1]) / 2 for d in range(3)] for c in cells]),
            'patches': {name: by_patch[name] for name in order}, 'n_points': len(pts), 'n_faces': len(faces), 'n_internal': n_int}


# ====================================================================== case
def _hdr(cls, obj, loc=''):
    return ('/*--------------------------------*- C++ -*----------------------------------*\\\n'
            '  ShipBrain case for OpenFOAM\n\\*---------------------------------------------------------------------------*/\n'
            f'FoamFile\n{{\n    version     2.0;\n    format      ascii;\n    class       {cls};\n' + (f'    location    "{loc}";\n' if loc else '')
            + f'    object      {obj};\n}}\n\n')


def _voxel_body(path, units='mm'):
    """STEP / STL part (ShipBrain's CAD files are in mm) -> (solid in metres, bounding box in metres)"""
    import cadquery as cq
    from .cadplates import import_cad
    shp = import_cad(path)
    f = {'mm': 1e-3, 'm': 1.0, 'cm': 1e-2}[units]
    if f != 1.0:
        shp = shp.scale(f)
    bb = shp.BoundingBox()
    solid = shp.Solids()[0] if shp.Solids() else shp
    return solid, (bb.xmin, bb.ymin, bb.zmin, bb.xmax, bb.ymax, bb.zmax)


def build_case(case_dir, velocity=1.0, fluid='water', length=2.0, height=1.0, width=None, plate_x=0.5, plate_t=0.02, plate_h=0.4, plate_w=None,
               body_file=None, body_units='mm', turbulence='laminar', cell=0.02, side_walls='slip', intensity=0.05, nu=None, end_iter=None):
    """Write a complete steady simpleFoam case: a channel (x flow, y up) with a body standing on the floor.
    body = a box plate (plate_t thick, plate_h high, plate_w wide - the full width if width is None / 2D) or the part in body_file.
    width None -> 2D (one cell thick, 'empty' front and back). Returns the info dict the post-processing needs."""
    rho, mu = FLUIDS[fluid] if isinstance(fluid, str) else fluid
    nu_ = nu or mu / rho
    U = float(velocity)
    two_d = width is None
    zw = float(width) if width else cell
    solid = None
    if body_file:
        solid, (bx0, by0, bz0, bx1, by1, bz1) = _voxel_body(body_file, body_units)
        px0, px1, ph = plate_x, plate_x + (bx1 - bx0), by1 - by0
        pw = (bz1 - bz0)
    else:
        px0, px1, ph = plate_x, plate_x + plate_t, plate_h
        pw = plate_w if plate_w else zw
    zc = zw / 2
    nbx = max(3, int(round((px1 - px0) / cell)))
    nby = max(4, int(round(ph / cell)))
    xs = axis_from_segments([(0.0,), (px0, max(4, int(round(px0 / (cell * 2.5)))), 1 / 8.0), (px1, nbx), (length, max(6, int(round((length - px1) / (cell * 2.5)))), 8.0)])
    if ph > 0:
        ys = axis_from_segments([(0.0,), (ph, nby), (height, max(5, int(round((height - ph) / (cell * 2.0)))), 6.0)])
    else:                                                            # no body: a plain channel
        ys = axis_from_segments([(0.0,), (height, max(8, int(round(height / cell))))])
    if two_d:
        zs = np.array([0.0, zw])
    else:
        z0, z1 = zc - pw / 2, zc + pw / 2
        nbz = max(3, int(round(pw / cell)))
        segs = [(0.0,)]
        if z0 > 1e-9:
            segs.append((z0, max(3, int(round(z0 / (cell * 2.0)))), 1 / 4.0))
        segs.append((z1, nbz))
        if zw - z1 > 1e-9:
            segs.append((zw, max(3, int(round((zw - z1) / (cell * 2.0)))), 4.0))
        zs = axis_from_segments(segs)
    ox, oy, oz = (px0 - bx0, 0.0 - by0, zc - (bz0 + bz1) / 2) if body_file else (0, 0, 0)
    if body_file:
        import cadquery as cq

        def body(x, y, z):
            return 0 if solid.isInside(cq.Vector(x - ox, y - oy, z - oz), 1e-6) else 1
    else:
        z0b, z1b = (0.0, zw) if two_d else (zc - pw / 2, zc + pw / 2)

        def body(x, y, z):
            return 0 if (px0 < x < px1 and y < ph and z0b < z < z1b) else 1
    m = Mesh([xs, ys, zs], body)
    if not m.cells:
        raise ValueError('the channel is empty')
    eps = 1e-9 * max(length, height)

    def tag(c, ax, side):
        x, y, z = c
        if ax == 0 and abs(x) < eps:
            return 'inlet'
        if ax == 0 and abs(x - length) < eps:
            return 'outlet'
        if ax == 1 and abs(y) < eps:
            return 'floor'
        if ax == 1 and abs(y - height) < eps:
            return 'top'
        if ax == 2 and (abs(z) < eps or abs(z - zw) < eps):
            return 'frontAndBack' if two_d else 'sides'
        return 'body'
    types = {'floor': 'wall', 'body': 'wall', 'top': 'wall' if side_walls == 'wall' else 'symmetry',
             'sides': 'wall' if side_walls == 'wall' else 'symmetry', 'frontAndBack': 'empty'}
    os.makedirs(case_dir, exist_ok=True)
    g = write_polymesh(m, tag, case_dir, types)
    A_ref = ph * pw if not two_d else ph * zw
    if body_file:                                                   # frontal area from the voxels that were cut out
        cut = [c for c in np.ndindex(*m.shape) if c not in m.cells]
        yz = {(c[1], c[2]) for c in cut}
        A_ref = sum((ys[j + 1] - ys[j]) * (zs[k + 1] - zs[k]) for j, k in yz) or A_ref
    info = {'rho': rho, 'nu': nu_, 'U': U, 'cells': len(g['cells']), 'points': g['n_points'], 'two_d': two_d, 'turbulence': turbulence,
            'A_ref': float(A_ref), 'offset': (ox, oy, oz), 'body_faces': len(g['patches'].get('body', [])), 'grid': g}
    _write_files(case_dir, info, turbulence, intensity, side_walls, end_iter, cell)
    np.save(os.path.join(case_dir, 'sb_centres.npy'), g['cell_centres'])
    import json
    json.dump({'rho': rho, 'nu': nu_, 'U': U}, open(os.path.join(case_dir, 'sb_info.json'), 'w'))
    return info


def _write_files(d, info, turbulence, I, side_walls, end_iter, cell):
    U, nu = info['U'], info['nu']
    for s in ('0', 'constant', 'system'):
        os.makedirs(os.path.join(d, s), exist_ok=True)
    pats = list(info['grid']['patches'])
    k_in = 1.5 * (I * U) ** 2
    om_in = k_in ** 0.5 / (0.09 ** 0.25 * 0.07 * max(cell * 10, 0.01))          # turbulent length scale ~ 7 % of a coarse length
    sym = 'symmetry'

    def bf(field, rules):
        out = ''
        for p in pats:
            r = rules.get(p, rules.get('*'))
            if p == 'frontAndBack':
                r = 'type empty;'
            if p in ('top', 'sides') and side_walls != 'wall':
                r = f'type {sym};'
            out += f'    {p}\n    {{\n        ' + r.replace('\n', '\n        ') + '\n    }\n'
        return out

    def field(name, cls, dims, internal, rules):
        open(os.path.join(d, '0', name), 'w').write(_hdr(cls, name, '0') + f'dimensions      {dims};\n\ninternalField   {internal};\n\nboundaryField\n{{\n' + bf(name, rules) + '}\n')
    field('U', 'volVectorField', '[0 1 -1 0 0 0 0]', f'uniform ({U} 0 0)',
          {'inlet': f'type fixedValue;\nvalue uniform ({U} 0 0);', 'outlet': 'type zeroGradient;', '*': 'type noSlip;'})
    field('p', 'volScalarField', '[0 2 -2 0 0 0 0]', 'uniform 0',
          {'outlet': 'type fixedValue;\nvalue uniform 0;', '*': 'type zeroGradient;'})
    sst = turbulence == 'sst'
    if sst:
        field('k', 'volScalarField', '[0 2 -2 0 0 0 0]', f'uniform {k_in}',
              {'inlet': f'type fixedValue;\nvalue uniform {k_in};', 'outlet': 'type zeroGradient;', '*': f'type kqRWallFunction;\nvalue uniform {k_in};'})
        field('omega', 'volScalarField', '[0 0 -1 0 0 0 0]', f'uniform {om_in}',
              {'inlet': f'type fixedValue;\nvalue uniform {om_in};', 'outlet': 'type zeroGradient;', '*': f'type omegaWallFunction;\nvalue uniform {om_in};'})
        field('nut', 'volScalarField', '[0 2 -1 0 0 0 0]', 'uniform 0',
              {'inlet': 'type calculated;\nvalue uniform 0;', 'outlet': 'type calculated;\nvalue uniform 0;', '*': 'type nutkWallFunction;\nvalue uniform 0;'})
    open(os.path.join(d, 'constant', 'transportProperties'), 'w').write(_hdr('dictionary', 'transportProperties', 'constant') + f'transportModel  Newtonian;\nnu              {nu};\n')
    open(os.path.join(d, 'constant', 'turbulenceProperties'), 'w').write(_hdr('dictionary', 'turbulenceProperties', 'constant')
          + ('simulationType RAS;\nRAS\n{\n    RASModel        kOmegaSST;\n    turbulence      on;\n    printCoeffs     on;\n}\n' if sst else 'simulationType laminar;\n'))
    n_end = end_iter or (1500 if sst else 800)
    open(os.path.join(d, 'system', 'controlDict'), 'w').write(_hdr('dictionary', 'controlDict', 'system') + f"""application     simpleFoam;
startFrom       startTime;
startTime       0;
stopAt          endTime;
endTime         {n_end};
deltaT          1;
writeControl    timeStep;
writeInterval   {n_end};
purgeWrite      1;
writeFormat     ascii;
writePrecision  8;
writeCompression off;
timeFormat      general;
timePrecision   6;
runTimeModifiable false;

""")
    open(os.path.join(d, 'system', 'fvSchemes'), 'w').write(_hdr('dictionary', 'fvSchemes', 'system') + """ddtSchemes      {{ default steadyState; }}
gradSchemes     {{ default Gauss linear; }}
divSchemes
{{
    default         none;
    div(phi,U)      bounded Gauss linearUpwind grad(U);
    div(phi,k)      bounded Gauss upwind;
    div(phi,omega)  bounded Gauss upwind;
    div((nuEff*dev2(T(grad(U))))) Gauss linear;
}}
laplacianSchemes {{ default Gauss linear corrected; }}
interpolationSchemes {{ default linear; }}
snGradSchemes   {{ default corrected; }}
wallDist        {{ method meshWave; }}
""".replace('{{', '{').replace('}}', '}'))
    open(os.path.join(d, 'system', 'fvSolution'), 'w').write(_hdr('dictionary', 'fvSolution', 'system') + """solvers
{
    p { solver GAMG; smoother GaussSeidel; tolerance 1e-7; relTol 0.05; }
    "(U|k|omega)" { solver smoothSolver; smoother symGaussSeidel; tolerance 1e-8; relTol 0.1; }
}
SIMPLE
{
    nNonOrthogonalCorrectors 0;
    consistent      yes;
    residualControl { p 1e-5; U 1e-6; "(k|omega)" 1e-5; }
}
relaxationFactors
{
    equations { U 0.9; ".*" 0.9; }
}
""")


def run_case(case_dir, timeout=7200):
    """checkMesh + simpleFoam; returns the log text"""
    if not installed():
        raise RuntimeError('OpenFOAM is not installed (simpleFoam not on the PATH): install it (Ubuntu: apt install openfoam; or https://www.openfoam.com) and ask again.')
    rc, chk = _run(['checkMesh'], case_dir, 600)
    if 'Mesh OK' not in chk:
        raise RuntimeError('checkMesh failed: ' + ' | '.join([l.strip() for l in chk.splitlines() if '***' in l or 'Failed' in l][:4]))
    rc, log = _run(['simpleFoam'], case_dir, timeout)
    open(os.path.join(case_dir, 'log.simpleFoam'), 'w').write(log)
    if rc != 0 and ('Floating point exception' in log or 'sigFpe' in log or 'FOAM_SIGFPE' in log and '#0' in log):
        raise RuntimeError('simpleFoam diverged (floating point exception): a steady laminar solution only exists at low Reynolds numbers - use turbulence "sst", '
                           'a lower velocity, or a finer grid near the body')
    if rc != 0 or 'End' not in log[-300:]:
        raise RuntimeError('simpleFoam failed: ' + ' | '.join([l for l in log.splitlines() if l.strip()][-4:]))
    return log


# ====================================================================== results
def last_time(case_dir):
    ts = [(float(t), t) for t in os.listdir(case_dir) if re.fullmatch(r'[0-9.eE+-]+', t) and t != '0' and os.path.isdir(os.path.join(case_dir, t))]
    return max(ts)[1] if ts else None


def _read_list(text, start, vec):
    """parse 'nonuniform List<..> N ( ... )' or 'uniform v' starting at the text index of the keyword; returns (values, end)"""
    m = re.compile(r'\s*(uniform|nonuniform)\s+(?:List<\w+>\s*)?').match(text, start)
    kind = m.group(1)
    i = m.end()
    if kind == 'uniform':
        e = text.index(';', i)
        v = text[i:e].strip()
        return ('uniform', [float(x) for x in re.findall(r'[-+0-9.eE]+', v)]), e
    mm = re.compile(r'(\d+)\s*\(').match(text, i)
    if not mm:
        return ('uniform', [0.0]), i
    n = int(mm.group(1))
    body = text[mm.end():]
    nums = re.findall(r'[-+]?\d*\.?\d+(?:[eE][-+]?\d+)?|nan|inf', body[: body.index('\n)\n') if '\n)\n' in body else len(body)])
    a = np.array([float(x) for x in nums])
    a = a.reshape(n, 3) if vec else a[:n]
    return ('list', a), mm.end()


def read_field(path, patch=None, vec=False):
    text = open(path).read()
    if patch is None:
        k = text.index('internalField')
        (kind, v), _ = _read_list(text, k + len('internalField'), vec)
        return np.asarray(v)
    k = text.index(f'\n    {patch}\n')
    k = text.index('value', k)
    (kind, v), _ = _read_list(text, k + len('value'), vec)
    return np.asarray(v)


def results(case_dir, info):
    """velocity and pressure per cell, pressure on the body faces, force on the body"""
    t = last_time(case_dir)
    if t is None:
        raise RuntimeError('no result written')
    rho, nu, U = info['rho'], info['nu'], info['U']
    g = info['grid']
    Uc = read_field(os.path.join(case_dir, t, 'U'), vec=True)
    pc = read_field(os.path.join(case_dir, t, 'p'))
    n = len(g['cells'])
    Uc = np.tile(Uc, (n, 1)) if Uc.ndim == 1 else Uc
    pc = np.full(n, float(pc[0])) if len(pc) != n else pc
    out = {'time': t, 'U_cells': Uc, 'p_cells': pc * rho, 'centres': g['cell_centres'], 'cells': g['cells']}
    body = g['patches'].get('body', [])
    if body:
        pb = np.array([out['p_cells'][b[1]] for b in body])             # the wall has a zero-gradient pressure: the face value is the cell value
        F = np.zeros(3)
        Fp = np.zeros(3)
        rows = []
        for (q, o, ctr, nrm, area), p_f in zip(body, pb):
            nrm = np.array(nrm, float)
            # force of the fluid on the body: pressure acts against the outward normal of the FLUID cell (= into the body)
            Fp += p_f * nrm * area
            ctr_c = g['cell_centres'][o]
            d = abs(np.dot(np.array(ctr) - ctr_c, nrm))
            ut = Uc[o] - np.dot(Uc[o], nrm) * nrm                          # tangential velocity of the wall cell
            tau = rho * nu * ut / max(d, 1e-12)                           # wall shear on the body (force by the fluid, along the flow)
            F += p_f * nrm * area + tau * area
            rows.append((ctr, nrm, p_f, p_f * nrm * area + tau * area))
        out['force_n'] = F
        out['pressure_force_n'] = Fp
        out['body_faces'] = rows
    return out


def solve(workdir, name, **kw):
    """build_case + simpleFoam + results; returns (summary dict, results, info)"""
    d = os.path.join(workdir, name)
    shutil.rmtree(d, ignore_errors=True)
    info = build_case(d, **kw)
    log = run_case(d)
    r = results(d, info)
    rho, U = info['rho'], info['U']
    q = 0.5 * rho * U * U
    F = r.get('force_n', np.zeros(3))
    its = re.findall(r'^Time = (\d+)', log, re.M)
    conv = 'solution converged' in log
    res_p = re.findall(r'Solving for p, Initial residual = ([0-9.eE+-]+)', log)
    out = {'case': name, 'cells': info['cells'], 'two_d': info['two_d'], 'turbulence': info['turbulence'], 'iterations': int(its[-1]) if its else None,
           'converged': conv, 'last_pressure_residual': float(res_p[-1]) if res_p else None,
           'reynolds_ref': round(U * math.sqrt(info['A_ref']) / info['nu']), 'frontal_area_m2': round(info['A_ref'], 5),
           'drag_n': float(F[0]), 'side_force_y_n': float(F[1]), 'side_force_z_n': float(F[2]),
           'drag_coefficient': round(float(F[0] / (q * info['A_ref'])), 4) if q > 0 and info['A_ref'] > 0 else None,
           'max_velocity_m_s': round(float(np.linalg.norm(r['U_cells'], axis=1).max()), 4),
           'pressure_min_pa': round(float(r['p_cells'].min()), 4), 'pressure_max_pa': round(float(r['p_cells'].max()), 4)}
    if info['two_d']:
        out['note_2d'] = 'forces are for the depth of one cell (2D case)'
    return out, r, info


def probe(case_dir, x, y, z):
    """velocity and pressure at a place of a finished ShipBrain OpenFOAM case (the cell containing / nearest to (x, y, z) in metres)"""
    import json
    c = np.load(os.path.join(case_dir, 'sb_centres.npy'))
    meta = json.load(open(os.path.join(case_dir, 'sb_info.json')))
    t = last_time(case_dir)
    if t is None:
        raise RuntimeError('this case has no result yet')
    U = read_field(os.path.join(case_dir, t, 'U'), vec=True)
    p = read_field(os.path.join(case_dir, t, 'p'))
    U = np.tile(U, (len(c), 1)) if U.ndim == 1 else U
    p = np.full(len(c), float(p[0])) if len(p) != len(c) else p
    d = np.linalg.norm(c - np.array([x, y, z], float), axis=1)
    j = int(np.argmin(d))
    return {'x': float(c[j][0]), 'y': float(c[j][1]), 'z': float(c[j][2]), 'distance_m': round(float(d[j]), 4), 'velocity_m_s': [round(float(v), 5) for v in U[j]],
            'speed_m_s': round(float(np.linalg.norm(U[j])), 5), 'pressure_pa': round(float(p[j] * meta['rho']), 4)}
