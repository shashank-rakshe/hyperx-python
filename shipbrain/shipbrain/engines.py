"""
Engine registry and router: which engine answers which engineering question, whether it is installed on THIS PC, and
which ShipBrain tool runs it. The model calls choose_engine first for analysis questions, then the tool it names.

support levels:
  runs      ShipBrain writes the input, runs the engine and reads the results back (plain-English answer)
  writes    ShipBrain writes the input deck; you run it in the engine (licence / install on your PC)
  knowledge ShipBrain answers from the engine's documentation / tutorials (knowledge pack) and guides the set-up
"""
import os, re, shutil

ANALYSES = {   # analysis type -> words that point to it
    'static': r'frame|portal|truss|cantilever|beam|column|pipe support|surrogate|reduced.order|\brom\b|parametric study|design space|stress|deflect|displace|strength|static|yield|load case|utili[sz]ation|safety factor|deform',
    'modal': r'frequenc|natural|vibrat|resonan|eigen|\bmodes?\b|propeller excitation|hz\b',
    'buckling': r'buckl|stability|critical (load|stress)|elastic buckling',
    'ultimate': r'plastic|ultimate|nonlinear|non-linear|collapse|large deformation|residual strength',
    'contact': r'contact|friction|gap|clearance',
    'bolt': r'\bbolts?\b|preload|tightening torque|fastener|screw joint|bolted joint|vdi 2230',
    'impact': r'impact|crash|collision|grounding|dropped object|drop test|explicit|slamming|blast',
    'fatigue': r'fatigue|hot.?spot|s-n|weld toe|cycles to failure|damage ratio',
    'fracture': r'crack|fracture|j-integral|stress intensity',
    'cfd': r'\bcfd\b|flow|resistance|drag|wind load|current|wave load|sloshing|hydrodynamic|propulsion|wake|airfoil|wing|shock',
    'heat': r'thermal|temperature|heat|fire|insulation',
    'cad': r'sldprt|solidworks|catpart|catia|inventor|\.ipt\b|\.f3d\b|fusion 360|rhino|\.3dm\b|fcstd|freecad|\.sat\b|iges|\.igs\b|3d model|\bcad\b|step file|solid model|drawing to|make a model|cadquery|mid.?surface|outer surface|piping|pipes?\b',
    'mesh': r'\bmesh|elements?\b|bdf|\.inp|nastran deck|shell model',
    'hydraulics': r'pressure drop|head loss|pump (power|head|size|sizing)|pipe siz|hydraulic|ballast (line|pump|system)|bilge (line|pump|system)|cooling water|sea ?water (line|system|pump)|fire main|fuel (oil )?(line|transfer)|lube oil (line|system)|flow velocity in (the )?pipe|cooling (line|system)|(sea|fresh) ?water cooling|what pump|which pump|\bm3/h\b|npsh',
    'topology': r'topology|lightening hole|material layout|where (to put|is) material|lighten|weight saving|optimi[sz]e (the )?(shape|bracket|web|layout)',
    'mooring': r'mooring|anchor (line|chain)|catenary|fairlead|chain grade|\bR3S?\b|\bR4S?\b|power cable|umbilical|riser|lazy.?wave|touchdown',
    'reverse': r'\bstl\b|scan(ned)? (part|mesh)|reverse.?engineer|mesh to (step|cad|solid)|3d.?print(ed)? (part|file)',
    'rc': r'reinforced concrete|\brebar\b|concrete (section|beam|slab|column|wall)|eurocode ?[23]|\bEC[23]\b|\bEHE\b|ACI ?318|AISC ?360|\bSIA ?26[23]\b|code check|limit state|fibre? section|interaction diagram|construction phase|steel member (check|design)|member (check|design)',
    'process': r'process simulat|flowsheet|\bflash\b|distillation|column|vapou?r fraction|heat and mass balance|property package|'
               r'thermodynamic|dew point|bubble point|absorber|stripper|reactor|dwsim|phase envelope',
}

ENGINES = [
    # name, analyses, support, how ShipBrain uses it, detect (executables), knowledge pack, note
    ('ShipBrain bolt check (VDI 2230)', {'bolt'}, 'runs', 'bolt(d, cls, mu_G, F_A, Phi)', [], None,
     'stress area, preload, tightening torque, scatter, bolt stress, fatigue and clamp force (VDI 2230 / ISO 898-1)'),
    ('ShipBrain hand checks', {'static', 'buckling'}, 'runs', 'plate_check / stiffener_check / plate_buckling / section_props',
     [], None, 'Roark / beam theory / Johnson-Ostenfeld: instant first answers and a cross-check for FE'),
    ('CalculiX', {'static': 'runs', 'modal': 'runs', 'buckling': 'runs', 'heat': 'knowledge', 'ultimate': 'knowledge', 'contact': 'knowledge'}, 'runs', 'mesh tool -> analysis_run(file, analysis)',
     ['ccx', 'ccx_static', 'ccx.exe'], None, 'free FE solver (GPL, separate program); static, natural frequencies and buckling '
                                              'validated against handbook values (0.0-0.6 %)'),
    ('ShipBrain fatigue', {'fatigue'}, 'runs', 'fatigue_mesh(..., solve=true)', ['ccx', 'ccx.exe'], None,
     't x t hot-spot model, read-out at 0.5t / 1.5t, extrapolated hot-spot stress (CalculiX underneath)'),
    ('MYSTRAN (free Nastran-compatible)', {'static': 'runs', 'modal': 'runs', 'buckling': 'runs'}, 'runs',
     'solve(file, solver="mystran", analysis)', ['@mystran'], None,
     'free (MIT) Nastran-style solver for the .bdf ShipBrain writes; checked against CalculiX and hand formulas (0.2-0.8 %)'),
    ('Nastran (MSC / NX / Simcenter)', {'static': 'writes', 'modal': 'writes', 'buckling': 'writes', 'ultimate': 'knowledge'}, 'writes', 'fe_convert(file, to=["bdf"])',
     ['nastran', 'nx_nastran'], None, 'BDF written by ShipBrain; needs a Nastran licence'),
    ('ANSYS MAPDL / PyMAPDL', {'static': 'writes', 'modal': 'writes', 'buckling': 'writes', 'ultimate': 'knowledge', 'contact': 'knowledge', 'heat': 'knowledge'}, 'writes',
     'fe_convert(file, to=["mac"]) (+ PyMAPDL script)', ['ansys', 'mapdl', 'ansys241', 'ansys242'], None, 'needs an ANSYS licence'),
    ('Siemens NX / Simcenter 3D (NX Open journals)', {'static': 'writes', 'modal': 'writes', 'buckling': 'writes', 'cad': 'writes'},
     'writes', 'nx_open(op="journal", calls=[...]) with nxopentse; nx_rename for renaming with links', ['run_journal', 'run_journal.exe'],
     'nxopentse', 'paid; ShipBrain writes the journals (nxopentse, AGPL) and runs them when NX is installed'),
    ('Siemens NX / Rhino (RhinoInside.NX)', {'cad'}, 'knowledge', 'native_cad(file) reads NX .prt partly and Rhino .3dm geometry; '
     'STEP to and from NX', ['ugraf', 'ugraf.exe', 'rhino', 'Rhino.exe'], None,
     'paid programs; RhinoInside.NX (no open licence, early beta) links them - ShipBrain gives its download link only'),
    ('cadmpeg (native CAD reader)', {'cad'}, 'runs', 'native_cad(file, op="convert"|"inspect"|"measure"|"diff")', ['@cadmpeg'], 'cadmpeg',
     'opens SolidWorks / CATIA / Inventor / Fusion / Rhino / FreeCAD / ACIS / IGES files and writes STEP (Apache-2.0)'),
    ('ShipBrain hex mesher', {'mesh': 'runs', 'static': 'runs'}, 'runs', 'hex_mesh(file, size, to)', [], None,
     'own code (voxel grid, boundary snapped to the surface, edges and corners, Jacobian-checked); checked against Peterson Kt and beam theory'),
    ('ProcessPi (pipe hydraulics)', {'hydraulics'}, 'runs', 'pipe_flow(flow_m3h, segments, fluid, branches)', [], 'processpi',
     'MIT; Darcy-Weisbach / Colebrook, valve and bend K / Le-D tables, elevation, parallel branches; fluids set by ShipBrain'),
    ('TensorMesh (differentiable FE on PyTorch)', {'topology': 'runs', 'static': 'runs'}, 'runs',
     'topology(L, H, fixed, load_at, force, volfrac) / tensor_fem(file, fixed, loads)', ['@torch'], 'TensorMesh',
     'Apache-2.0, ETH Zurich; GPU when present; meshes from ShipBrain\'s own mesher (no Gmsh)'),
    ('CableDyn (mooring lines and cables)', {'mooring'}, 'runs', 'mooring(depth, length, radius, d_mm, grade) / cable_run(deck)',
     ['@cabledyn'], 'CableDyn', 'free FE solver (Apache-2.0): statics and dynamics of mooring lines and power cables, '
                                 'validated against OrcaFlex (0.06-0.6 %) and model tests'),
    ('ReverseCAD (STL -> STEP)', {'reverse'}, 'runs', 'reverse_cad(file, material)', ['@reversecad'], 'reverse-cad',
     'mesh to STEP solid + holes, threads, fillets, mass, verification (PolyForm Noncommercial: non-commercial use only)'),
    ('HyperMesh / OptiStruct (Altair)', {'static': 'writes', 'modal': 'writes', 'buckling': 'writes', 'ultimate': 'knowledge'}, 'writes',
     'fe_convert(file, to=["fem"]); fe_quality(file) does the same element checks in ShipBrain', ['hm', 'hmopengl', 'hw', 'optistruct'],
     None, 'Altair pre-processor and solver (paid licence); ShipBrain writes the .fem/.bdf/.inp HyperMesh imports, and its own '
           'mesher, fe_edit, repair_model and fe_quality cover meshing, cleanup and quality checks for free'),
    ('Abaqus', {'static': 'writes', 'modal': 'writes', 'buckling': 'writes', 'ultimate': 'knowledge', 'contact': 'knowledge', 'impact': 'knowledge'}, 'writes', 'fe_convert(file, to=["inp"]) (+ Abaqus script)',
     ['abaqus'], None, 'needs an Abaqus licence'),
    ('MoFEM', {'contact', 'ultimate', 'fracture', 'heat'}, 'knowledge', 'knowledge_search(query, scope="mofem")',
     ['mofem_part', 'contact_3d', 'plastic_3d'], 'mofem-cephas', 'open-source C++ FE library (MIT): contact, plasticity, '
                                                                 'thermo-elasticity, adaptive meshing; install via its Docker image / Spack'),
    ('OpenCourant / OpenRadioss', {'impact'}, 'knowledge', 'knowledge_search(query, scope="OpenCourantRP")',
     ['starter_linux64_gf', 'starter_win64.exe', 'engine_linux64_gf'], 'OpenCourantRP',
     'explicit dynamics (collision, grounding, drop, sloshing); Radioss input decks'),
    ('OpenFOAM', {'cfd', 'heat'}, 'runs', 'openfoam_flow(velocity, fluid, body_file ...) steady laminar / SST flow past a plate or a STEP part; flow_load_stress(file, velocity, fix) = flow -> forces -> stress',
     ['simpleFoam', 'blockMesh', 'interFoam'], None, 'free CFD (GPL): resistance, wind loads, sloshing (interFoam)'),
    ('Elmer', {'heat', 'cfd', 'static', 'modal'}, 'runs', 'elmer_flow(velocity, fluid, plate_h, plate = rigid | elastic ...) - 2D plate in a channel, laminar / SST, FSI',
     ['ElmerSolver', 'ElmerGrid'], None, 'free multiphysics FE (heat, flow, FSI)'),
    ('Code_Aster', {'static', 'modal', 'buckling', 'ultimate', 'contact', 'fatigue', 'fracture', 'heat'}, 'knowledge', 'guided set-up',
     ['run_aster', 'as_run'], None, 'free FE (GPL), very complete; reads MED meshes'),
    ('CadQuery', {'cad'}, 'runs', 'cadquery_build(code, expect) / build_structure(program)', [], None,
     'parts from text with size checks; ship structures from building-block programs'),
    ('Ship drawing reader', {'cad'}, 'runs', 'drawing_to_model(file) -> compare_structures', [], None,
     'ship structural drawings (PDF) -> member model XML'),
    ('ShipBrain surfaces + piping', {'cad', 'mesh'}, 'runs', 'surface_extract(file, kind="mid"|"outer") / pipe_extract(file)', [], None,
     'mid / outer surfaces of thin solids, pipe runs and 1D pipe models from STEP (OpenCascade)'),
    ('ShipBrain AI surrogate', {'static'}, 'runs', 'surrogate_build(ranges) -> surrogate_predict(name, params); result_insight(file.frd)',
     ['ccx', 'ccx.exe'], None, 'POD + RBF reduced-order model trained on CalculiX runs: ~1 ms per answer, error estimate, '
                                'falls back to the real solve when unsure; hotspots / refinement / report from any result'),
    ('Awatif frame solver (built in)', {'static'}, 'runs', 'frame_solve(nodes, members, supports, loads)', [], None,
     'linear static 3D frames, beams and pipe supports; load cases + ULS combinations; Awatif C++ solver (MIT) via wasmtime'),
    ('OpenPhysicsAI (built in)', {'cfd': 'runs', 'heat': 'runs', 'fracture': 'runs', 'impact': 'runs', 'modal': 'runs', 'static': 'runs'},
     'runs', 'physics_lab(action="list" / "run") ; mcp_tools / mcp_call(server="openphysics")', ['@openphysics'], None,
     'C solvers checked against closed forms / measurements: flow up to shocks, heat, fire, water / sloshing, sound, '
     'radar, magnetics, fracture, impact, gears, 3D printing, topology optimisation (Apache-2.0, copied whole)'),
    ('SolidCraft (parametric CAD)', {'cad'}, 'runs', 'mcp_tools / mcp_call(server="solidcraft") with its modelling skills', ['@solidcraft'], None,
     'free (MIT / Apache) parametric CAD in Rust: sketch, constrain, features, sheet metal, assemblies, STEP; its own MCP server'),
    ('DWSIM process simulator (built in)', {'process'}, 'runs', 'process_sim(action="run" / "flash") ; mcp_call(server="dwsim")', ['@dwsim'], None,
     'free (GPL) chemical process simulator: property packages, flashes, unit operations, columns, reactors, dynamics; '
     'its own MCP server (58 operations); all 22 of its sample plants solved through ShipBrain'),
    ('ShipBrain mesher', {'mesh'}, 'runs', 'build_structure / plates_mesh / panel_mesh / cad_mesh / structure_to_mesh', [], None,
     'own conforming 1D + 2D mesher; no free nodes'),
    ('MOOSE (INL multiphysics)', {'static': 'runs', 'heat': 'knowledge', 'contact': 'knowledge', 'fracture': 'knowledge',
                                  'cfd': 'knowledge', 'ultimate': 'knowledge'}, 'runs',
     'moose_plate(a, b, t, q, clamped) / moose_run(input.i)', ['@moose'], 'moose',
     'LGPL-2.1; shells, solids, contact, XFEM, heat transfer, Navier-Stokes, porous flow; run from the Docker image idaholab/moose'),
    ('XC (finite elements + structural codes)', {'rc': 'runs', 'ultimate': 'runs'}, 'runs',
     'knowledge_search (xc pack: worked verification examples) -> xc_run(script)', ['@xc'], 'xc',
     'GPL-3; reinforced concrete (EC2, ACI 318, EHE, SIA 262) and steel (EC3, AISC 360, EAE) code checks, fibre sections, non-linear '
     'static / dynamic, construction phases; run from the Docker image engthiago/xcfem or a local install'),
]


def _caps(caps, default):
    return caps if isinstance(caps, dict) else {k: default for k in caps}


def installed(names):
    if not names:
        return True
    if names == ['@mystran']:                          # found on PATH, in a usual folder, remembered, or built by ShipBrain
        from . import solvers
        return any(x['solver'] == 'mystran' for x in solvers.find())
    if names == ['@solidcraft']:
        from .mcp_client import solidcraft_cli
        return solidcraft_cli() is not None
    if names == ['@moose']:
        from . import moose
        return moose.exe() is not None
    if names == ['@xc']:
        from . import xcfem
        return xcfem.exe() is not None
    if names == ['@torch']:
        import importlib.util
        return importlib.util.find_spec('torch') is not None
    if names == ['@cabledyn']:
        from . import cabledyn
        return cabledyn.driver() is not None
    if names == ['@cadmpeg']:
        from . import cadmpeg
        return cadmpeg.exe() is not None
    if names == ['@reversecad']:                       # copied in vendor/, built on first use with Node.js
        from . import reversecad
        return reversecad.available() and reversecad.node() is not None
    if names == ['@dwsim']:
        from . import dwsim
        return dwsim.exe() is not None
    if names == ['@openphysics']:                       # built in: compiled once from shipbrain/vendor (Linux / macOS / WSL)
        from . import openphysics
        return openphysics.available() and (openphysics.built() or os.name != 'nt')
    env = {'ccx': os.environ.get('CCX')}
    return any(shutil.which(n) or env.get(n) for n in names)


def classify(question):
    q = question.lower()
    hits = [a for a, rx in ANALYSES.items() if re.search(rx, q)]
    if 'modal' in hits and not re.search(ANALYSES['modal'], re.sub(r'natural gas', '', q)):
        hits.remove('modal')                                  # "natural gas" is not a natural frequency
    special = {'impact', 'ultimate', 'modal', 'buckling', 'cfd', 'fatigue', 'fracture', 'contact'}
    if 'static' in hits and set(hits) & special:          # a specific analysis wins over the generic 'stress / deformation'
        hits.remove('static')
    if 'mesh' in hits and len(hits) > 1:
        hits.remove('mesh')
    return hits or ['static']


def choose(question):
    kinds = classify(question)
    rank = {'runs': 0, 'writes': 1, 'knowledge': 2}
    plan = []
    for k in kinds:
        cands = []
        for name, caps, sup, how, exe, pack, note in ENGINES:
            c = _caps(caps, sup)
            if k in c:
                ok = installed(exe)
                eff = c[k] if (ok or c[k] != 'runs') else 'knowledge'       # a deck can be written without the program
                use = how if eff != 'knowledge' else (f'knowledge_search(query, scope="{pack}")' if pack else 'guided set-up')
                cands.append({'engine': name, 'support': eff, 'installed': ok, 'use': use, 'knowledge_pack': pack, 'note': note})
        # run/write level: installed first; guide-only level: engines with a knowledge pack (tutorials) first
        cands.sort(key=lambda c: (rank[c['support']], (not c['installed']) if c['support'] != 'knowledge' else (c['knowledge_pack'] is None),
                                  not c['installed']))
        plan.append({'analysis': k, 'engines': cands[:4]})
    lines = []
    for p in plan:
        best = p['engines'][0] if p['engines'] else None
        if not best:
            lines.append(f"{p['analysis']}: no engine known yet.")
            continue
        verb = {'runs': 'ShipBrain runs it with', 'writes': 'ShipBrain writes the input for', 'knowledge': 'ShipBrain guides you with'}[best['support']]
        lines.append(f"{p['analysis']}: {verb} {best['engine']} ({best['use']})"
                     + ('' if best['installed'] else (' - run it on a PC that has it' if best['support'] == 'writes' else ' - not installed on this PC')))
        alt = [e['engine'] + ('' if e['installed'] else ' (not installed)') for e in p['engines'][1:3]]
        if alt:
            lines[-1] += '; alternatives: ' + ', '.join(alt)
    return {'analyses': kinds, 'plan': plan, 'plain_english': 'Analysis type: ' + ', '.join(kinds) + '. ' + ' '.join(lines)}


def inventory():
    return [{'engine': n, 'analyses': _caps(c, s), 'installed': installed(e), 'note': note} for n, c, s, h, e, p, note in ENGINES]
