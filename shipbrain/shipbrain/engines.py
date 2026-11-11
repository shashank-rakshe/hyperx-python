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
    'contact': r'contact|friction|bolt preload|gap|clearance',
    'impact': r'impact|crash|collision|grounding|dropped object|drop test|explicit|slamming|blast',
    'fatigue': r'fatigue|hot.?spot|s-n|weld toe|cycles to failure|damage ratio',
    'fracture': r'crack|fracture|j-integral|stress intensity',
    'cfd': r'\bcfd\b|flow|resistance|drag|wind load|current|wave load|sloshing|hydrodynamic|propulsion|wake|airfoil|wing|shock',
    'heat': r'thermal|temperature|heat|fire|insulation',
    'cad': r'3d model|\bcad\b|step file|solid model|drawing to|make a model|cadquery|mid.?surface|outer surface|piping|pipes?\b',
    'mesh': r'\bmesh|elements?\b|bdf|\.inp|nastran deck|shell model',
}

ENGINES = [
    # name, analyses, support, how ShipBrain uses it, detect (executables), knowledge pack, note
    ('ShipBrain hand checks', {'static', 'buckling'}, 'runs', 'plate_check / stiffener_check / plate_buckling / section_props',
     [], None, 'Roark / beam theory / Johnson-Ostenfeld: instant first answers and a cross-check for FE'),
    ('CalculiX', {'static': 'runs', 'modal': 'runs', 'buckling': 'runs', 'heat': 'knowledge', 'ultimate': 'knowledge', 'contact': 'knowledge'}, 'runs', 'mesh tool -> analysis_run(file, analysis)',
     ['ccx', 'ccx_static', 'ccx.exe'], None, 'free FE solver (GPL, separate program); static, natural frequencies and buckling '
                                              'validated against handbook values (0.0-0.6 %)'),
    ('ShipBrain fatigue', {'fatigue'}, 'runs', 'fatigue_mesh(..., solve=true)', ['ccx', 'ccx.exe'], None,
     't x t hot-spot model, read-out at 0.5t / 1.5t, extrapolated hot-spot stress (CalculiX underneath)'),
    ('Nastran (MSC / NX / Simcenter, MYSTRAN)', {'static': 'writes', 'modal': 'writes', 'buckling': 'writes', 'ultimate': 'knowledge'}, 'writes', 'fe_convert(file, to=["bdf"])',
     ['nastran', 'mystran', 'nx_nastran'], None, 'BDF written by ShipBrain; MYSTRAN is a free Nastran-like solver'),
    ('ANSYS MAPDL / PyMAPDL', {'static': 'writes', 'modal': 'writes', 'buckling': 'writes', 'ultimate': 'knowledge', 'contact': 'knowledge', 'heat': 'knowledge'}, 'writes',
     'fe_convert(file, to=["mac"]) (+ PyMAPDL script)', ['ansys', 'mapdl', 'ansys241', 'ansys242'], None, 'needs an ANSYS licence'),
    ('Abaqus', {'static': 'writes', 'modal': 'writes', 'buckling': 'writes', 'ultimate': 'knowledge', 'contact': 'knowledge', 'impact': 'knowledge'}, 'writes', 'fe_convert(file, to=["inp"]) (+ Abaqus script)',
     ['abaqus'], None, 'needs an Abaqus licence'),
    ('MoFEM', {'contact', 'ultimate', 'fracture', 'heat'}, 'knowledge', 'knowledge_search(query, scope="mofem")',
     ['mofem_part', 'contact_3d', 'plastic_3d'], 'mofem-cephas', 'open-source C++ FE library (MIT): contact, plasticity, '
                                                                 'thermo-elasticity, adaptive meshing; install via its Docker image / Spack'),
    ('OpenCourant / OpenRadioss', {'impact'}, 'knowledge', 'knowledge_search(query, scope="OpenCourantRP")',
     ['starter_linux64_gf', 'starter_win64.exe', 'engine_linux64_gf'], 'OpenCourantRP',
     'explicit dynamics (collision, grounding, drop, sloshing); Radioss input decks'),
    ('OpenFOAM', {'cfd', 'heat'}, 'knowledge', 'knowledge_search + guided case set-up',
     ['simpleFoam', 'blockMesh', 'interFoam'], None, 'free CFD (GPL): resistance, wind loads, sloshing (interFoam)'),
    ('Elmer', {'heat', 'cfd', 'static', 'modal'}, 'knowledge', 'guided set-up', ['ElmerSolver', 'ElmerGrid'], None,
     'free multiphysics FE (heat, flow, FSI)'),
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
    ('ShipBrain mesher', {'mesh'}, 'runs', 'build_structure / plates_mesh / panel_mesh / cad_mesh / structure_to_mesh', [], None,
     'own conforming 1D + 2D mesher; no free nodes'),
]


def _caps(caps, default):
    return caps if isinstance(caps, dict) else {k: default for k in caps}


def installed(names):
    if not names:
        return True
    if names == ['@openphysics']:                       # built in: compiled once from shipbrain/vendor (Linux / macOS / WSL)
        from . import openphysics
        return openphysics.available() and (openphysics.built() or os.name != 'nt')
    env = {'ccx': os.environ.get('CCX')}
    return any(shutil.which(n) or env.get(n) for n in names)


def classify(question):
    q = question.lower()
    hits = [a for a, rx in ANALYSES.items() if re.search(rx, q)]
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
