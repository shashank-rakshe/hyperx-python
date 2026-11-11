"""
MOOSE (https://github.com/idaholab/moose, LGPL-2.1, Idaho National Laboratory): fully-coupled implicit multiphysics finite
elements - solid mechanics (shells, beams, solids, plasticity, creep, large strain), contact, XFEM fracture, heat transfer,
Navier-Stokes, porous flow, thermal hydraulics, phase field, stochastic tools. Not copied here (48 000 files); ShipBrain
runs the user's installed MOOSE as written:
  * `moose-opt` on the PATH (conda / source build, or inside the Docker image), or MOOSE_EXE
  * Docker: the official image idaholab/moose (all modules compiled, program moose-opt) - ShipBrain runs it with the
    work folder mounted
Input files follow MOOSE's own tests (shell inputs from modules/solid_mechanics/test/tests/shell/static, e.g.
clamped_plate_flat.i, which matches Timoshenko's Navier series). Meshes come from ShipBrain's own mesher, written in the
.msh (version 2 ASCII) file format by ShipBrain's own code - the Gmsh program is never used.

  plate_input(...)   shell plate / panel under lateral pressure, supports by coordinate boxes
  run(input)         runs MOOSE, reads the CSV of postprocessors
  plate(...)         both + a check against the Navier series (simply supported) for rectangular plates
Units: any consistent set (ShipBrain: mm, N, MPa).
"""
import csv, math, os, re, shutil, subprocess

IMAGE = 'idaholab/moose:latest'


# ====================================================================== the program
def exe():
    for c in (os.environ.get('MOOSE_EXE'), shutil.which('moose-opt'), shutil.which('moose-opt.exe'), '/opt/moose/bin/moose-opt'):
        if c and os.path.isfile(c):
            return [c]
    d = shutil.which('docker')
    if d and os.environ.get('SHIPBRAIN_MOOSE_DOCKER', '1') != '0':
        try:
            p = subprocess.run([d, 'image', 'inspect', IMAGE], capture_output=True, timeout=30)
            if p.returncode == 0:
                return [d, IMAGE]
        except Exception:
            pass
    return None


def _need():
    x = exe()
    if not x:
        raise RuntimeError('MOOSE is not installed: easiest is Docker - docker pull idaholab/moose (all modules, program '
                           'moose-opt); or conda / source build: https://mooseframework.inl.gov/getting_started/installation/ '
                           '(Windows: inside WSL2).')
    return x


def run(inp, timeout=7200, threads=2):
    """run MOOSE on an input file; returns the postprocessor table (CSV) and the log"""
    inp = os.path.abspath(inp)
    wd, name = os.path.dirname(inp), os.path.basename(inp)
    x = _need()
    if len(x) == 2:                                                  # docker
        cmd = [x[0], 'run', '--rm', '-v', f'{wd}:/work', '-w', '/work', x[1], 'moose-opt', '-i', name]
    else:
        cmd = x + ['-i', name]
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=wd)
    log = p.stdout + p.stderr
    out = {'exit_code': p.returncode, 'log': log[-4000:]}
    csvf = os.path.join(wd, os.path.splitext(name)[0] + '_out.csv')
    if os.path.exists(csvf):
        rows = list(csv.DictReader(open(csvf)))
        out['csv'] = os.path.basename(csvf)
        out['postprocessors'] = {k: float(v) for k, v in rows[-1].items()} if rows else {}
    if p.returncode != 0:
        msg = ''
        m = re.search(r'\*\*\* ERROR \*\*\*\s*(.*?)(?:\n\s*Stack frames|\n\s*\d+: |\Z)', log, re.S)
        if m:
            msg = ' '.join(m.group(1).split())[:800]
        if not msg:
            msg = '; '.join(l.strip() for l in log.splitlines() if re.search(r'did not converge|failed|ERROR', l))[-800:]
        raise RuntimeError('MOOSE stopped: ' + (msg or log[-1500:]))
    return out


# ====================================================================== mesh file (own writer, .msh v2 format)
def write_msh(nodes, quads, path, block='shell'):
    """nodes: list of (x, y, z); quads: lists of 4 node indices (0-based). One physical surface `block`."""
    L = ['$MeshFormat', '2.2 0 8', '$EndMeshFormat', '$PhysicalNames', '1', f'2 1 "{block}"', '$EndPhysicalNames',
         '$Nodes', str(len(nodes))]
    L += [f'{i + 1} {x:.10g} {y:.10g} {z:.10g}' for i, (x, y, z) in enumerate(nodes)]
    L += ['$EndNodes', '$Elements', str(len(quads))]
    L += [f'{k + 1} 3 2 1 1 ' + ' '.join(str(n + 1) for n in q) for k, q in enumerate(quads)]
    L += ['$EndElements']
    open(path, 'w').write('\n'.join(L) + '\n')
    return path


def plate_mesh(a, b, na, nb):
    nodes = [(a * i / na, b * j / nb, 0.0) for j in range(nb + 1) for i in range(na + 1)]
    quads = [[j * (na + 1) + i, j * (na + 1) + i + 1, (j + 1) * (na + 1) + i + 1, (j + 1) * (na + 1) + i]
             for j in range(nb) for i in range(na)]
    return nodes, quads


# ====================================================================== inputs (patterned on MOOSE's own shell tests)
def plate_input(mesh_file, t, E, nu, q, edges, a, b, out='plate.i', clamped=False):
    """shell plate in the x-y plane, pressure q (+ = towards -z), edges: dict name -> (bottom_left, top_right) boxes"""
    eps = 1e-6 * max(a, b)
    gens = []
    prev = 'gmg'
    for name, (bl, tr) in edges.items():
        gens.append(f"""  [{name}]
    type = BoundingBoxNodeSetGenerator
    input = {prev}
    new_boundary = '{name}'
    bottom_left = '{bl[0] - eps:.12g} {bl[1] - eps:.12g} {-eps:.12g}'
    top_right = '{tr[0] + eps:.12g} {tr[1] + eps:.12g} {eps:.12g}'
  []""")
        prev = name
    names = ' '.join(edges)
    bcs = []
    for v in ('disp_x', 'disp_y', 'disp_z') + (('rot_x', 'rot_y') if clamped else ()):
        bcs.append(f"""  [fix_{v}]
    type = DirichletBC
    variable = {v}
    boundary = '{names}'
    value = 0.0
  []""")
    kern = '\n'.join(f"""  [solid_{v}]
    type = ADStressDivergenceShell
    component = {c}
    variable = {v}
    through_thickness_order = SECOND
  []""" for c, v in enumerate(('disp_x', 'disp_y', 'disp_z', 'rot_x', 'rot_y')))
    var = '\n'.join(f"""  [{v}]
    order = FIRST
    family = LAGRANGE
  []""" for v in ('disp_x', 'disp_y', 'disp_z', 'rot_x', 'rot_y'))
    text = f"""# ShipBrain: shell plate {a:g} x {b:g}, t = {t:g}, pressure {q:g}, {'clamped' if clamped else 'simply supported'} edges
# Patterned on MOOSE's modules/solid_mechanics/test/tests/shell/static/clamped_plate_flat.i
[Mesh]
  [gmg]
    type = FileMeshGenerator
    file = {os.path.basename(mesh_file)}
  []
{chr(10).join(gens)}
[]

[Variables]
{var}
[]

[BCs]
{chr(10).join(bcs)}
[]

[Preconditioning]
  [smp]
    type = SMP
    full = true
  []
[]

[Executioner]
  type = Transient
  solve_type = NEWTON
  petsc_options_iname = '-pc_type'
  petsc_options_value = 'lu'
  line_search = 'none'
  nl_rel_tol = 1e-10
  nl_abs_tol = 1e-10
  dt = 1
  dtmin = 0.001
  end_time = 1.
[]

[Kernels]
{kern}
  [load_z]
    type = ADDistributedLoadShell
    function = '{q:.10g}'
    variable = disp_z
    displacements = 'disp_x disp_y disp_z'
  []
[]

[Materials]
  [elasticity]
    type = ADComputeIsotropicElasticityTensorShell
    youngs_modulus = {E:.10g}
    poissons_ratio = {nu:g}
    through_thickness_order = SECOND
    block = 'shell'
  []
  [strain]
    type = ADComputeIncrementalShellStrain
    displacements = 'disp_x disp_y disp_z'
    rotations = 'rot_x rot_y'
    thickness = {t:.10g}
    through_thickness_order = SECOND
    block = 'shell'
  []
  [stress]
    type = ADComputeShellStress
    through_thickness_order = SECOND
    block = 'shell'
  []
[]

[Postprocessors]
  [w_min]
    type = NodalExtremeValue
    variable = disp_z
    value_type = min
  []
  [w_max]
    type = NodalExtremeValue
    variable = disp_z
    value_type = max
  []
  [w_centre]
    type = PointValue
    variable = disp_z
    point = '{a / 2:g} {b / 2:g} 0'
  []
[]

[Outputs]
  csv = true
  exodus = true
[]
"""
    open(out, 'w').write(text)
    return out


def navier(a, b, t, E, nu, q, terms=40):
    """centre deflection of a simply supported rectangular plate under uniform q (Navier double series, Timoshenko)"""
    D = E * t ** 3 / (12 * (1 - nu * nu))
    s = 0.0
    for m in range(1, 2 * terms, 2):
        for n in range(1, 2 * terms, 2):
            s += (-1) ** ((m + n) // 2 - 1) / (m * n * ((m / a) ** 2 + (n / b) ** 2) ** 2)
    return 16 * q / (math.pi ** 6 * D) * s


def plate(a, b, t, q, E=206000.0, nu=0.3, clamped=False, n=None, workdir='.', name='plate'):
    """rectangular plate field (stiffener spacing b, span a) under lateral pressure q, with MOOSE's shell element"""
    na = n or max(8, min(60, int(round(20 * a / min(a, b)))))
    nb = max(8, int(round(na * b / a)))
    os.makedirs(workdir, exist_ok=True)
    nodes, quads = plate_mesh(float(a), float(b), na, nb)
    msh = write_msh(nodes, quads, os.path.join(workdir, f'{name}.msh'))
    edges = {'edge_bottom': ((0, 0), (a, 0)), 'edge_top': ((0, b), (a, b)), 'edge_left': ((0, 0), (0, b)), 'edge_right': ((a, 0), (a, b))}
    inp = plate_input(msh, float(t), float(E), float(nu), float(q), edges, float(a), float(b),
                      out=os.path.join(workdir, f'{name}.i'), clamped=clamped)
    r = run(inp)
    pp = r.get('postprocessors', {})
    w = max(abs(pp.get('w_min', 0.0)), abs(pp.get('w_max', 0.0)))
    res = {'input': inp, 'mesh': msh, 'elements': len(quads), 'max_deflection': w, 'centre_deflection': pp.get('w_centre'),
           'postprocessors': pp}
    pe = (f"MOOSE (shell elements, {len(quads)} quads) solved the {a:g} x {b:g} plate, t = {t:g}, under {q:g} with "
          f"{'clamped' if clamped else 'simply supported'} edges: largest deflection {w:.4g}.")
    if w > 0.5 * t:
        pe += (f" The deflection is {w / t:.1f} times the thickness: membrane action carries part of the load, so a linear "
               "calculation (and linear theory) overestimates it - run a large-deflection analysis for the real value.")
    if not clamped:
        wn = navier(a, b, t, E, nu, q)
        res['navier'] = wn
        res['difference_percent'] = round(100 * (w - wn) / wn, 2)
        pe += f" The Navier series (Timoshenko) gives {wn:.4g}: difference {res['difference_percent']:+.2f} %."
    res['plain_english'] = pe
    return res
