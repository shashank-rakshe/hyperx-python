"""
Piping pulsation and vibration with OpenPulse (https://github.com/MOPT-UFSC/OpenPulse, GPL-3.0, Federal University of Santa Catarina
MOPT group; copied in vendor/openpulse, Python code only, unchanged).

From plain words to OpenPulse: a pipe route (legs or waypoints in mm, as pipe_route), outside diameter and wall, fluid, material,
supports and pipe end conditions -> acoustic natural frequencies of the fluid column (pulsation resonances, OpenPulse's 1D acoustic
FEM including the pipe wall flexibility, Lin & Morgan) and structural natural frequencies of the pipe (OpenPulse's Timoshenko pipe
elements with the fluid mass), and a check of both against the excitation frequencies of a pump or compressor.

How OpenPulse is run: its model, preprocessor, assembly and solvers are used as written. Two things are ShipBrain's own:
  * the mesh - OpenPulse meshes with gmsh; ShipBrain never uses gmsh, so own_mesh() builds the same mesh data (node coordinates,
    line connectivity, line maps) from the route with a uniform element size;
  * the imports - OpenPulse loads its desktop interface (Qt, VTK) at package level; openpulse_shim answers those imports with
    placeholders. Both run in a separate process, so the ShipBrain app is untouched.
Corners are sharp joints between straight lines (OpenPulse's bends come from its CAD geometry, which is not used here).
"""
import json, math, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, 'vendor', 'openpulse', 'repo')

# name: density kg/m3, speed of sound m/s, isentropic exponent, thermal conductivity W/mK, Cp J/kgK, dynamic viscosity Pa s, molar mass g/mol, T K, p Pa
FLUIDS = {
    'air': (1.204263, 343.395034, 1.401985, 0.025503, 1006.400178, 1.8247e-5, 28.958601, 293.15, 101325.0),   # OpenPulse's own test fluid
    'water': (998.2, 1482.3, 1.0, 0.598, 4182.0, 1.002e-3, 18.015, 293.15, 101325.0),                         # 20 C
    'seawater': (1024.8, 1521.5, 1.0, 0.596, 3993.0, 1.08e-3, 18.0, 293.15, 101325.0),                       # 20 C, 35 g/kg
}
# name: density, E (Pa), Poisson, thermal expansion
MATERIALS = {
    'steel': (7850.0, 210e9, 0.3, 1.2e-5),
    'stainless': (7900.0, 193e9, 0.3, 1.6e-5),
    'copper_nickel': (8940.0, 150e9, 0.33, 1.7e-5),
}


# ====================================================================== the mesh (ShipBrain's own, in OpenPulse's format)
def own_mesh(mesh, lines, h, tol=1e-6):
    """lines = {line_id: (start_xyz_m, end_xyz_m)} -> nodes every h (m or less) on every line, shared at the line ends"""
    import numpy as np
    from pulse.model.mesh_utils import ElementConnectivityData, get_connectivity
    mesh.reset_variables()
    coords, conn = [], {}

    def node(p):
        for i, q in enumerate(coords):
            if math.dist(q, p) < tol:
                return i
        coords.append(tuple(float(v) for v in p))
        return len(coords) - 1
    gid = 1
    for lid, (a, b) in lines.items():
        a, b = np.array(a, float), np.array(b, float)
        n = max(1, int(math.ceil(float(np.linalg.norm(b - a)) / h - 1e-9)))
        ids = [node(a + (b - a) * k / n) for k in range(n + 1)]
        cc = np.array([[ids[k], ids[k + 1]] for k in range(n)], int)
        conn[(1, lid)] = {1: ElementConnectivityData(np.arange(gid, gid + n), cc)}
        gid += n
    mesh.nodal_coordinates = np.zeros((len(coords), 4))
    mesh.nodal_coordinates[:, 0] = np.arange(len(coords))
    mesh.nodal_coordinates[:, 1:] = np.array(coords)
    mesh.lines_connectivity, mesh.map_line_elements = get_connectivity(conn)
    mesh.lines_mapping = {lid: lid for lid in lines}
    mesh.curve_length, mesh.valve_internal_lines = {}, {}
    mesh.map_elements_to_lines()
    mesh.map_nodes_to_lines()
    mesh.geometry_points = sorted({node(np.array(p, float)) for ab in lines.values() for p in ab})


# ====================================================================== the OpenPulse run (separate process)
def _worker(spec_path, out_path):
    sys.path.insert(0, ROOT)
    from shipbrain import openpulse_shim
    openpulse_shim.install()
    import numpy as np
    from pulse.project.project import Project
    from pulse.model import AnalysisID
    from pulse.model.data_classes.project_setup_data_classes import ImportType, MesherSetup, ProjectSetup
    from pulse.model.cross_section import CrossSection
    from pulse.model.cross_sections.pipe_cross_section import PipeCrossSection
    from pulse.model.properties.fluid import Fluid
    from pulse.model.properties.material import Material
    sys.path.insert(0, os.path.join(ROOT, 'tests'))
    from helpers import create_temporary_fluid_library, create_temporary_material_library
    S = json.load(open(spec_path))
    out = {}
    for analysis in S['analyses']:
        d = tempfile.mkdtemp(prefix='sb_pulse_')
        project = Project()
        project.initialize_pulse_file_and_loader(dir_path=d)
        model, pre = project.model, project.model.preprocessor
        project.reset(reset_all=True)
        project.set_project_setup(ProjectSetup(import_type=ImportType.BUILT_IN, mesher_setup=MesherSetup(S['h'], 1e-6, 'meter')))
        lines = {i + 1: (tuple(S['pts'][i]), tuple(S['pts'][i + 1])) for i in range(len(S['pts']) - 1)}
        model.mesh.generate = lambda import_type, geometry_path='': own_mesh(model.mesh, lines, S['h'])
        model.process_geometry_and_mesh()
        L = list(lines)
        rho, c, gam, k, cp, mu, M, T, p = S['fluid']
        fl = Fluid(name=S['fluid_name'], identifier=1, temperature=T, pressure=p, density=rho, speed_of_sound=c, isentropic_exponent=gam,
                   thermal_conductivity=k, specific_heat_Cp=cp, dynamic_viscosity=mu, molar_mass=M, color=[0, 170, 255])
        create_temporary_fluid_library(project, {1: fl})
        pre.set_fluid_by_lines(L, fl)
        model.properties._set_line_property('fluid_id', 1, L)
        model.properties._set_line_property('fluid', fl, L)
        mr, E, nu, al = S['material']
        mat = Material(name=S['material_name'], identifier=1, density=mr, elasticity_modulus=E, poisson_ratio=nu,
                       thermal_expansion_coefficient=al, color=[253, 152, 145])
        create_temporary_material_library(project, {1: mat})
        pre.set_material_by_lines(L, mat)
        model.properties._set_line_property('material_id', 1, L)
        model.properties._set_line_property('material', mat, L)
        sec = PipeCrossSection(S['od'], S['wall'], 0, 0, 0, 0)
        cs = CrossSection(pipe_section_info=sec)
        model.properties._set_line_property('structure_name', sec.section_type_label, L)
        model.properties._set_multiple_line_properties(sec.as_dict(), L)
        model.properties._set_line_property('cross_section', cs, L)
        model.properties._set_line_property('structural_element_type', 'pipe_1', L)
        pre.set_cross_section_by_lines(L, cs)
        pre.set_structural_element_type_by_lines(L, 'pipe_1')
        if analysis == 'acoustic':
            for xyz in S['open_points']:
                nid = pre.get_node_id_by_coordinates(np.array(xyz))
                model.properties._set_nodal_property('acoustic_pressure', {'coords': list(xyz), 'values': [0j], 'real_values': [0.0],
                                                                           'imag_values': [0.0]}, nid)
            setup = {'analysis_id': AnalysisID.ACOUSTIC_MODAL, 'number_of_modes': S['modes'], 'sigma_factor': 1e-2}
        else:
            for xyz, dofs in S['supports']:
                nid = pre.get_node_id_by_coordinates(np.array(xyz))
                v = [0j if f else None for f in dofs]
                model.properties._set_nodal_property('prescribed_dofs', {'coords': list(xyz), 'values': v,
                                                                         'real_values': [0.0 if f else None for f in dofs],
                                                                         'imag_values': [0.0 if f else None for f in dofs]}, nid)
            setup = {'analysis_id': AnalysisID.STRUCTURAL_MODAL, 'number_of_modes': S['modes'], 'sigma_factor': 1e-2}
        model.set_analysis_setup(analysis_setup=setup)
        project.file.write_line_properties_in_file()
        project.file.write_nodal_properties_in_file()
        project.file.write_project_setup_in_file(model.project_setup.as_dict())
        project.file.write_analysis_setup_in_file(setup)
        project.build_model_and_solve(running_by_script=True)
        solver = project.acoustic_solver if analysis == 'acoustic' else project.structural_solver
        f = np.sort(np.real(np.asarray(solver.natural_frequencies, dtype=complex)))
        out[analysis] = {'frequencies_hz': [round(float(x), 4) for x in f], 'nodes': len(pre.nodes)}
    json.dump(out, open(out_path, 'w'))


# ====================================================================== from plain words
SUPPORT_DOFS = {'anchor': [1, 1, 1, 1, 1, 1], 'pinned': [1, 1, 1, 0, 0, 0], 'rest': [0, 0, 1, 0, 0, 0], 'hold': [0, 0, 1, 0, 0, 0],
                'guide': None, 'x': [1, 0, 0, 0, 0, 0], 'y': [0, 1, 0, 0, 0, 0], 'z': [0, 0, 1, 0, 0, 0]}


def analyse(legs=None, waypoints=None, od_mm=None, wall_mm=None, fluid='water', fluid_density=None, fluid_speed_of_sound=None,
            material='steel', supports=None, open_ends=None, modes=10, excitation_hz=None, margin=0.1, element_mm=None,
            analyses=('acoustic', 'structural'), start=(0, 0, 0), workdir='.', name='pulsation', timeout=1800):
    """open_ends: waypoint indexes (0 start, -1 end) where the pipe opens into a large volume (tank, vessel, sea): acoustic pressure 0.
    The other ends are closed (a closed valve, a blind). supports as pipe_stress (anchor | pinned | rest | x | y | z), default anchors at
    both ends; a rest acts both ways here (a modal analysis is linear)."""
    import numpy as np
    from .piperoute import waypoints_from_legs
    pts = np.array(waypoints, float) if waypoints else (waypoints_from_legs(legs, start) if legs else None)
    if pts is None or len(pts) < 2:
        raise ValueError('give the route as legs [{"dir": "east", "length": 3000}, ...] or waypoints [[x, y, z], ...] in mm')
    if not od_mm or not wall_mm:
        raise ValueError('give the pipe outside diameter od_mm and wall thickness wall_mm')
    if wall_mm >= od_mm / 2:
        raise ValueError('the wall must be thinner than half the outside diameter')
    fname = str(fluid).lower().replace(' ', '')
    if fluid_density and fluid_speed_of_sound:
        base = list(FLUIDS['water'] if float(fluid_density) > 100 else FLUIDS['air'])
        base[0], base[1] = float(fluid_density), float(fluid_speed_of_sound)
        fl, fname = tuple(base), 'user fluid'
    elif fname in FLUIDS:
        fl = FLUIDS[fname]
    else:
        raise ValueError(f'fluid {fluid!r}: use {", ".join(FLUIDS)} or give fluid_density (kg/m3) and fluid_speed_of_sound (m/s)')
    mname = str(material).lower().replace(' ', '_')
    if mname not in MATERIALS:
        raise ValueError(f'material {material!r}: use {", ".join(MATERIALS)}')
    total = float(sum(np.linalg.norm(pts[i + 1] - pts[i]) for i in range(len(pts) - 1)))
    h = float(element_mm) / 1000 if element_mm else max(0.01, min(0.05, total / 1000 / 200))
    P = pts / 1000.0
    supports = supports or [{'at': 0, 'type': 'anchor'}, {'at': -1, 'type': 'anchor'}]
    sup = []
    for s in supports:
        kind = str(s.get('type', 'anchor')).lower()
        dofs = SUPPORT_DOFS.get(kind)
        if dofs is None:
            raise ValueError(f'support type {kind!r} for a vibration analysis: anchor, pinned, rest, x, y, z')
        at = s.get('at', 0)
        xyz = np.array(at, float) / 1000.0 if isinstance(at, (list, tuple)) else P[int(at)]
        sup.append([[round(float(v), 9) for v in xyz], dofs])
    opens = [[float(v) for v in P[int(i)]] for i in (open_ends or [])]
    spec = {'pts': P.tolist(), 'h': h, 'od': od_mm / 1000.0, 'wall': wall_mm / 1000.0, 'fluid': list(fl), 'fluid_name': fname,
            'material': list(MATERIALS[mname]), 'material_name': mname, 'supports': sup, 'open_points': opens, 'modes': int(modes),
            'analyses': list(analyses)}
    os.makedirs(workdir, exist_ok=True)
    sp = os.path.join(workdir, name + '_openpulse_spec.json')
    op = os.path.join(workdir, name + '_openpulse.json')
    json.dump(spec, open(sp, 'w'))
    if os.path.exists(op):
        os.remove(op)
    env = dict(os.environ, PYTHONPATH=os.path.dirname(HERE) + os.pathsep + os.environ.get('PYTHONPATH', ''))
    code = f'from shipbrain.pulsation import _worker; _worker({sp!r}, {op!r})'
    r = subprocess.run([sys.executable, '-W', 'ignore', '-c', code], capture_output=True, text=True, timeout=timeout, cwd=workdir, env=env)
    if r.returncode or not os.path.exists(op):
        msg = [l for l in (r.stderr or r.stdout).splitlines() if l.strip()][-4:]
        if "No module named 'h5py'" in (r.stderr or '') or "No module named 'ordered_set'" in (r.stderr or ''):
            raise RuntimeError("No module named 'h5py' / 'ordered_set' - OpenPulse needs them: pip install h5py ordered-set")
        raise RuntimeError('OpenPulse failed: ' + ' | '.join(msg))
    res = json.load(open(op))
    return _summary(res, pts, od_mm, wall_mm, fname, fl, mname, sup, opens, open_ends, excitation_hz, margin, h, total)


def _summary(res, pts, od, wall, fname, fl, mname, sup, opens, open_ends, excitation, margin, h, total):
    rho, c = fl[0], fl[1]
    E = MATERIALS[mname][1]
    K = rho * c * c
    din = (od - 2 * wall) / 1000.0
    c_eff = c / math.sqrt(1 + din * K / (E * wall / 1000.0))
    out = {'route_length_m': round(total / 1000, 3), 'element_size_m': round(h, 4), 'fluid': fname,
           'speed_of_sound_m_s': round(c, 1), 'speed_of_sound_in_pipe_m_s': round(c_eff, 1), 'material': mname,
           'open_ends': open_ends or [], 'supports': len(sup)}
    ac = [f for f in res.get('acoustic', {}).get('frequencies_hz', []) if f > 0.5]
    st = [f for f in res.get('structural', {}).get('frequencies_hz', []) if f > 0.01]
    if 'acoustic' in res:
        out['acoustic_natural_frequencies_hz'] = [round(f, 2) for f in ac]
    if 'structural' in res:
        out['structural_natural_frequencies_hz'] = [round(f, 2) for f in st]
    near = []
    for ex in (excitation or []):
        for kind, fs in (('acoustic', ac), ('structural', st)):
            for f in fs:
                if abs(f - ex) <= margin * ex:
                    near.append({'excitation_hz': ex, 'mode': kind, 'natural_hz': round(f, 2), 'separation_percent': round((f / ex - 1) * 100, 1)})
    out['resonances'] = near
    s = f"OpenPulse pulsation / vibration: {out['route_length_m']} m of {od:g} x {wall:g} mm {mname.replace('_', '-')} pipe with {fname} "
    s += (f"(speed of sound {c:.0f} m/s, {c_eff:.0f} m/s inside this pipe because the wall flexes). " if c_eff < 0.99 * c else f"(speed of sound {c:.0f} m/s). ")
    if ac:
        s += f"Acoustic natural frequencies (pulsation): {', '.join(f'{f:.1f}' for f in ac[:6])} Hz. "
    if st:
        s += f"Structural natural frequencies (pipe vibration): {', '.join(f'{f:.1f}' for f in st[:6])} Hz. "
    if excitation:
        if near:
            s += ('RESONANCE RISK: ' + '; '.join(f"{n['mode']} mode {n['natural_hz']} Hz is within {abs(n['separation_percent']):.0f} % of the "
                                                    f"{n['excitation_hz']:g} Hz excitation" for n in near[:5]) +
                  f'. Keep at least {margin * 100:.0f} % separation: move a support (structural), change a length or add a volume / orifice (acoustic). ')
        else:
            s += f"No natural frequency within {margin * 100:.0f} % of the excitation ({', '.join(f'{e:g}' for e in excitation)} Hz). "
    s += 'Corners are modelled as sharp joints; the ends ' + ('open into a large volume at ' + ', '.join(map(str, open_ends)) if open_ends else 'are closed') + '.'
    out['plain_english'] = s
    return out
