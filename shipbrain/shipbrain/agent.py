"""
The assistant loop: model <-> tools.

Tool-call format (same in the training data, so a small fine-tuned model learns exactly this):
    ```tool
    {"name": "panel_mesh", "args": {"length": 4800, ...}}
    ```
The app runs the tool and sends back a message that starts with  TOOL_RESULT <name>:  followed by JSON.
The model then answers (or calls another tool). Numbers, meshes and files always come from tools, never from the model.
"""
import ast, importlib.util, json, math, operator, os, re, subprocess, sys, textwrap, time, urllib.request

from . import mesh as _mesh, fea as _fea, solver as _solver, platemesh as _pm, meshcheck as _mc

TOOL_RE = re.compile(r'```tool\s*\n(.*?)\n?```', re.S)
MAX_STEPS = 6
PROMPT_COMPACT = True          # set False (app: --full-prompt) for an untrained base model
MESH_TOOLS = ('panel_mesh', 'plates_mesh', 'cad_mesh', 'fatigue_mesh', 'drawing_to_3d')


# ====================================================================== safe calculator
_OPS = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul, ast.Div: operator.truediv, ast.Pow: operator.pow,
        ast.USub: operator.neg, ast.UAdd: operator.pos, ast.Mod: operator.mod, ast.FloorDiv: operator.floordiv}
_FN = {k: getattr(math, k) for k in ('sqrt', 'sin', 'cos', 'tan', 'asin', 'acos', 'atan', 'atan2', 'log', 'log10', 'exp', 'radians',
                                     'degrees', 'hypot', 'floor', 'ceil')}
_FN.update(abs=abs, min=min, max=max, round=round, pi=math.pi, e=math.e)


def calc(expression):
    def ev(n):
        if isinstance(n, ast.Expression):
            return ev(n.body)
        if isinstance(n, ast.Constant) and isinstance(n.value, (int, float)):
            return n.value
        if isinstance(n, ast.BinOp) and type(n.op) in _OPS:
            return _OPS[type(n.op)](ev(n.left), ev(n.right))
        if isinstance(n, ast.UnaryOp) and type(n.op) in _OPS:
            return _OPS[type(n.op)](ev(n.operand))
        if isinstance(n, ast.Name) and n.id in _FN:
            return _FN[n.id]
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id in _FN:
            return _FN[n.func.id](*[ev(a) for a in n.args])
        raise ValueError('not allowed in calc: ' + ast.dump(n)[:60])
    return {'expression': expression, 'value': ev(ast.parse(str(expression).replace('^', '**'), mode='eval'))}


# ====================================================================== tool registry
class Tools:
    def __init__(self, workdir, kb=None, allow_code=False, examples=None, memory=None, repo_kb=None):
        self.repo_kb = repo_kb        # knowledge packs of shared git repos (separate, so they never crowd ship knowledge)
        self.examples = examples
        self.memory = memory
        self.converters = []          # e.g. xml_to_members from your private plugin
        self.workdir = os.path.abspath(workdir)
        os.makedirs(self.workdir, exist_ok=True)
        self.kb = kb
        self.allow_code = allow_code
        self.t = {}           # name -> (fn, description, schema)
        self.last_mesh = None
        self._builtin()

    def register(self, name, fn, description, schema=None):
        self.t[name] = (fn, description, schema or {'type': 'object', 'properties': {}})

    def _path(self, p):
        p = p if os.path.isabs(p) else os.path.join(self.workdir, p)
        return os.path.abspath(p)

    # ------------------------------------------------------------------ built-in tools
    def _builtin(self):
        num = {'type': 'number'}
        prof = {'type': 'object', 'description': 'profile: {"type": "FlatBar"|"TBar"|"LBar"|"HP", "h": web height mm, "t": web mm, '
                                                 '"bf": flange width mm, "tf": flange mm}'}
        self.register('knowledge_search', self.knowledge_search,
                      'Search the rule book / notes / standards in the knowledge folder (keyword + meaning). Use before answering rule or '
                      'method questions; cite the ids. scope = part of a folder/file name to search only that project.',
                      {'type': 'object', 'properties': {'query': {'type': 'string'}, 'k': {'type': 'integer'}, 'scope': {'type': 'string'}},
                       'required': ['query']})
        self.register('remember', self.remember, 'Store a fact, yard practice or correction the user teaches, so it is used in later answers.',
                      {'type': 'object', 'properties': {'text': {'type': 'string'}, 'tags': {'type': 'array'}}, 'required': ['text']})
        self.register('recall', self.recall, 'Search the assistant memory (facts and corrections taught by the user).',
                      {'type': 'object', 'properties': {'query': {'type': 'string'}}, 'required': ['query']})
        self.register('set_profile', self.set_profile, 'Save how THIS user works, used in every later answer: units (mm-N-MPa | m-kN-kPa | '
                      'in-lbf-psi | ft-kip-ksi | mm-kN-MPa), material, yield_MPa, E_MPa, design_code, field, language, notes.',
                      {'type': 'object', 'properties': {k: ({'type': 'number'} if k in ('yield_MPa', 'E_MPa') else {'type': 'string'})
                                                         for k in ('units', 'material', 'yield_MPa', 'E_MPa', 'design_code', 'field',
                                                                   'language', 'notes')}})
        self.register('convert_units', self.convert_units, 'Convert values between units (tools use mm, N, MPa, t): values = '
                      '[{"value", "from", "to"}], e.g. in->mm, psi->MPa, kN.m->N.mm, cm4->mm4, msw->MPa.',
                      {'type': 'object', 'properties': {'values': {'type': 'array'}}, 'required': ['values']})
        self.register('add_skill', self.add_skill, 'Save a workflow the user teaches ("whenever I ask X, do A then B") as a skill: '
                      'name, description, steps (list or text), when (optional regex of trigger words). Used from then on.',
                      {'type': 'object', 'properties': {'name': {'type': 'string'}, 'description': {'type': 'string'},
                                                         'steps': {'type': 'array'}, 'when': {'type': 'string'}},
                       'required': ['name', 'description', 'steps']})
        self.register('list_skills', self.list_skills, 'List the skills (saved workflows) ShipBrain knows: built-in and the user\'s own.',
                      {'type': 'object', 'properties': {}})
        self.register('memory_feedback', self.memory_feedback, 'Like (good=true) or dislike a memory by id; forget=true deletes it.',
                      {'type': 'object', 'properties': {'id': {'type': 'string'}, 'good': {'type': 'boolean'}, 'forget': {'type': 'boolean'}},
                       'required': ['id']})
        self.register('panel_mesh', self.panel_mesh,
                      'Build a stiffened ship panel FE mesh (plate + stiffeners + frames) and write Nastran .bdf and CalculiX/Abaqus .inp. '
                      'Units mm, MPa. Stiffeners run along X by default; frames cross them.',
                      {'type': 'object', 'properties': {
                          'name': {'type': 'string'}, 'length': num, 'width': num, 'thickness': num, 'element_size': num,
                          'stiffeners': {'type': 'object', 'description': '{"direction": "x"|"y", "spacing": mm (or "count": n), "profile": profile} or null'},
                          'frames': {'type': 'object', 'description': '{"spacing": mm (or "count": n), "profile": profile} or null'},
                          'stiffener_model': {'type': 'string', 'enum': ['shell', 'beam']}, 'web_elements': {'type': 'integer'},
                          'pressure': {'type': 'number', 'description': 'MPa (1 m water head = 0.01 MPa)'},
                          'boundary': {'type': 'string', 'enum': ['simply', 'clamped', 'free']},
                          'material': {'type': 'object', 'description': '{"E": MPa, "nu": -, "rho": t/mm3}'}}})
        self.register('plates_mesh', self.plates_mesh,
                      'Mesh ANY assembly of flat plates (deck, girders, webs, brackets, floors, bulkheads, openings) with the own '
                      'conforming all-quad mesher: joints share nodes, no free nodes. Each plate: {"id", "t", "outline": [[x,y,z],...], '
                      '"holes": [[[x,y,z],...]]}. Units mm, MPa.',
                      {'type': 'object', 'properties': {
                          'name': {'type': 'string'}, 'element_size': num, 'plates': {'type': 'array'},
                          'loads': {'type': 'array', 'description': '[{"plates": [ids], "pressure": MPa}]'},
                          'fix': {'type': 'array', 'description': '[{"x": 0, "dof": "123456"}] all given coordinates must match'},
                          'beams': {'type': 'array', 'description': '1D stiffeners sharing plate nodes: [{"id", "a": [x,y,z], "b": [x,y,z], "profile": profile, "normal": [0,0,-1]}]'},
                          'clean': {'type': 'boolean', 'description': 'clean the geometry first (default true)'}},
                       'required': ['plates']})
        self.register('cad_mesh', self.cad_mesh, 'Mesh a STEP/BREP file in the workspace with the own mesher: thin solids -> mid-surface plates, '
                      'planar sheet faces -> plates; gaps closed, joints conforming. Curved faces are reported, not meshed.',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}, 'element_size': num, 'default_t': num,
                                                         'loads': {'type': 'array'}, 'fix': {'type': 'array'}}, 'required': ['file']})
        self.register('mesh_check', self.mesh_check, 'Check any shell mesh file (.bdf/.inp, from any mesher): free nodes, duplicate nodes, '
                      'unconnected parts, free edges, element quality.',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}}, 'required': ['file']})
        self.register('fe_quality', self.fe_quality, 'Pre-processor quality check of an FE model (.bdf/.fem/.inp), as HyperMesh / ANSA do: '
                      'per shell element aspect, warpage, skew, taper, Jacobian, corner angles, shortest edge, share of triangles '
                      'against pass/warn/fail limits (criteria: {check: [warn, fail]} overrides; mesh_size sets the shortest-edge '
                      'limit), plus a model check (missing properties/materials, zero thickness, duplicate elements, loads on '
                      'missing nodes, no constraints). Failing elements are saved as named sets.',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}, 'criteria': {'type': 'object'},
                                                         'mesh_size': {'type': 'number'}}, 'required': ['file']})
        self.register('solve_calculix', self.solve_calculix, 'Run CalculiX on an .inp in the workspace (linear static) and return max displacement and von Mises stress.',
                      {'type': 'object', 'properties': {'inp': {'type': 'string'}}, 'required': ['inp']})
        self.register('plate_check', _fea.plate_pressure, 'Hand check (Roark): plate field a x b x t under lateral pressure q -> max stress, deflection.',
                      {'type': 'object', 'properties': {'a': num, 'b': num, 't': num, 'q': num, 'boundary': {'type': 'string', 'enum': ['simply', 'clamped']},
                                                         'yield_MPa': num}, 'required': ['a', 'b', 't', 'q']})
        self.register('stiffener_check', _fea.stiffener_check, 'Hand check: stiffener + attached plate as a beam under pressure q -> section modulus, stress, deflection.',
                      {'type': 'object', 'properties': {'span': num, 'spacing': num, 't_plate': num, 'profile': prof, 'q': num,
                                                         'end': {'type': 'string', 'enum': ['clamped', 'simply']}, 'yield_MPa': num},
                       'required': ['span', 'spacing', 't_plate', 'profile', 'q']})
        self.register('plate_buckling', _fea.plate_buckling, 'Elastic + Johnson-Ostenfeld buckling stress of a plate field a x b x t in compression along a.',
                      {'type': 'object', 'properties': {'a': num, 'b': num, 't': num, 'k': num, 'yield_MPa': num}, 'required': ['a', 'b', 't']})
        self.register('section_props', _fea.section, 'Section properties of a profile (A, centroid, I), optionally with attached plating t_plate x b_eff.',
                      {'type': 'object', 'properties': {'profile': prof, 't_plate': num, 'b_eff': num}, 'required': ['profile']})
        self.register('calc', calc, 'Exact arithmetic (sqrt, sin, pi, ^ ...). Use it instead of mental arithmetic.',
                      {'type': 'object', 'properties': {'expression': {'type': 'string'}}, 'required': ['expression']})
        path_arg = lambda d: {'type': 'object', 'properties': {'file': {'type': 'string', 'description': d}}, 'required': ['file']}
        self.register('file_info', self.file_info, 'Describe any file in the workspace in plain English (FE model, STEP, DXF, PDF, image, JSON, XML, text): '
                      'what it is, what is inside, problems found. Call this first when the user asks about an uploaded file.',
                      path_arg('file name in the workspace'))
        self.register('fe_convert', self.fe_convert, '(to: bdf Nastran | fem OptiStruct/HyperMesh | inp Abaqus/CalculiX | mac ANSYS) Convert an FE model between Nastran .bdf, Abaqus/CalculiX .inp and ANSYS APDL .mac '
                      '(+ PyMAPDL and Abaqus driver scripts). 1D/2D/3D elements, properties, materials, supports and loads are kept.',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}, 'to': {'type': 'array', 'description': '["bdf","inp","mac"]'}},
                       'required': ['file']})
        self.register('fe_edit', self.fe_edit, 'Edit or convert an FE model file step by step and save it. ops (in order), each {"op": name, ...}: '
                      'equivalence{tol} | delete{group|box|ids|types} | remove_free_nodes | translate{d:[x,y,z]} | mirror{axis,value} | '
                      'refine | split_quads | renumber{node_start,elem_start} | merge{file} | set_thickness{pid,t} | '
                      'shell_to_solid{layers} (2D->3D) | solid_skin{t} (3D->2D) | edges_to_beams{which:"free"|"joints"} (2D->1D) | '
                      'beams_to_shells{height,t} (1D->2D) | remove_degenerate | orient_normals{ref?} | remove_small_parts{min_elements} | repair (all fixes)',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}, 'ops': {'type': 'array'}, 'out': {'type': 'string'}},
                       'required': ['file', 'ops']})
        self.register('geometry_clean', self.geometry_clean, 'Clean unclean geometry before meshing: a plate list (repeated/in-line points, '
                      'corners that almost meet, warped plates, slivers, duplicates, tiny holes) or a STEP file (repair, sew, merge split faces).',
                      {'type': 'object', 'properties': {'plates': {'type': 'array'}, 'file': {'type': 'string'}, 'merge_tol': {'type': 'number'}}})
        num_ = {'type': 'number'}
        self.register('repair_model', self.repair_model, 'Repair / clean up an uploaded model for FEA, as the user asks. CAD (STEP/BREP): '
                      'remove holes, fillets, chamfers, bosses or small faces up to a size (mm, mm2), then sew and fix; '
                      'FE mesh (bdf/inp): merge nodes, remove degenerate/duplicate elements, fix normals, delete loose bits. '
                      'request = the user\'s words (sizes are read from it); explicit sizes win. mesh_size meshes the result.',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}, 'request': {'type': 'string'}, 'holes_below': num_,
                                                         'fillets_below': num_, 'chamfers_below': num_, 'faces_below': num_,
                                                         'bosses_below': num_, 'sew': {'type': 'boolean'}, 'mesh_size': num_},
                       'required': ['file']})
        self.register('surface_extract', self.surface_extract, 'Mid-surface or outer-surface extraction from a solid CAD model (STEP/BREP): '
                      'every thin solid (flat, bent or curved plate, pipe wall) gives its mid (or outer) surface and thickness, '
                      'grouped by thickness (Mid_Surface_10T ...) in a STEP file; faces saved as B-splines are recognised first. '
                      'mesh_size meshes the flat mid-surfaces with the own mesher.',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}, 'kind': {'type': 'string', 'description': 'mid | outer'},
                                                         'max_thickness': num_, 'round_to': num_, 'mesh_size': num_}, 'required': ['file']})
        self.register('pipe_extract', self.pipe_extract, 'Piping from a CAD model (STEP/BREP): straight pipes and bends (OD, wall, '
                      'bend radius and angle, length), joined into runs; wall from the model (hollow pipe) or the pipe schedule; '
                      'writes a 1D FE model of the piping (pipe-section beams, bends split every 15 deg).',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}, 'schedule': {'type': 'string', 'description': 'SCH10|SCH40|SCH80|SCH160'},
                                                         'element_size': num_, 'to': {'type': 'array', 'description': '["bdf","inp"]'}},
                       'required': ['file']})
        self.register('surrogate_build', self.surrogate_build, 'AI surrogate (POD + RBF reduced-order model) of a parametric FE problem: '
                      'runs a study (own mesher + CalculiX), adds runs where it is least accurate, measures its accuracy by '
                      'leave-one-out; then predicts stress/displacement fields in ~1 ms. Writes the model (.npz) and a C++ header. '
                      'problem "plate": ranges for L, B, t (mm), p (MPa); edge clamped|simply.',
                      {'type': 'object', 'properties': {'name': {'type': 'string'}, 'ranges': {'type': 'object'}, 'n': {'type': 'integer'},
                                                         'max_runs': {'type': 'integer'}, 'edge': {'type': 'string'},
                                                         'template': {'type': 'object'}}, 'required': ['ranges']})
        self.register('surrogate_predict', self.surrogate_predict, 'Predict with a trained surrogate: peak von Mises, peak displacement, full '
                      'field (ParaView .vtk) and an error estimate; if it is not confident (or outside the trained range) the real '
                      'solver is run instead and the run is added to the model.',
                      {'type': 'object', 'properties': {'name': {'type': 'string'}, 'params': {'type': 'object'}, 'tol_pct': num_,
                                                         'fallback': {'type': 'boolean'}}, 'required': ['name', 'params']})
        self.register('result_insight', self.result_insight, 'Post-process a CalculiX result (.frd): peak stress and where, utilisation vs '
                      'yield with PASS/FAIL, hotspot areas, elements that need refinement, change against a baseline run, '
                      'a report draft and a ParaView .vtk of the fields.',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}, 'yield_MPa': num_, 'safety_factor': num_,
                                                         'baseline': {'type': 'string'}}, 'required': ['file']})
        self.register('frame_solve', self.frame_solve, 'Linear static 3D frame / beam / pipe-support check with Awatif\'s solver (built in, '
                      'no install): nodes, members (section: pipe [OD,t] | rect [b,h] | I [h,b,tw,tf] | box [h,b,t] | A,Iy,Iz,J; '
                      'release start|end|both), supports (fixed|pinned|roller|dof list), loads per case G/Q/W (node F [Fx,Fy,Fz,Mx,My,Mz] '
                      '| member w [wx,wy,wz] N/mm | self_weight), combinations (default ULS-1, ULS-2, SLS). Or file = a 1D model '
                      '(e.g. from pipe_extract) with supports/loads given at coordinates "at": [x,y,z]. Writes a report.',
                      {'type': 'object', 'properties': {'nodes': {'type': 'object'}, 'members': {'type': 'array'},
                                                         'supports': {'type': ['object', 'array']}, 'loads': {'type': 'object'},
                                                         'combinations': {'type': 'object'}, 'file': {'type': 'string'},
                                                         'name': {'type': 'string'}, 'divisions': {'type': 'integer'}}})
        self.register('code_functions', self.code_functions, 'Functions in the open-source repos copied whole into ShipBrain (Python, '
                      'TypeScript, JavaScript, C++, Rust...): repo (e.g. awatif, diff3d; empty = list the repos), query = words of '
                      'the file or function name. Shows file, language, signature and whether it can be called.',
                      {'type': 'object', 'properties': {'repo': {'type': 'string'}, 'query': {'type': 'string'}}})
        self.register('code_folder', self.code_folder, 'Use a package the user downloaded to this PC (e.g. the Vibrationdata MATLAB '
                      'package) like a copied repo: name + folder. Then code_functions / code_call work on it (.m runs in GNU Octave).',
                      {'type': 'object', 'properties': {'name': {'type': 'string'}, 'folder': {'type': 'string'}},
                       'required': ['name', 'folder']})
        self.register('code_call', self.code_call, 'Run a function of a copied repo IN ITS OWN LANGUAGE (Python directly, TypeScript / '
                      'JavaScript through Node.js): repo, file, function, args (JSON list; JS Map = {"__map__": [[key, value], ...]}).',
                      {'type': 'object', 'properties': {'repo': {'type': 'string'}, 'file': {'type': 'string'}, 'function': {'type': 'string'},
                                                         'args': {'type': ['array', 'object']}}, 'required': ['repo', 'file', 'function']})
        self.register('pid_kg', self.pid_kg, 'P&ID / PFD drawings (PDF) -> process knowledge graph, with the pid-to-kg scripts as written '
                      '(copied repo). action: probe {pdf, pages, plant_name} | render | hints | status | build | query {command: stats | '
                      'describe | upstream | downstream | path | loops | loop | instruments | sql, args: [...], equipment, variable, on} | '
                      'export {format: graphml | neo4j} | tags {pages} | read {pages} (the vision model reads each sheet into extract/page_NN.json, '
                      'checked against the pid-to-kg format; then build).',
                      {'type': 'object', 'properties': {'action': {'type': 'string'}, 'pdf': {'type': 'string'}, 'pages': {'type': 'string'},
                                                         'plant_name': {'type': 'string'}, 'work': {'type': 'string'},
                                                         'command': {'type': 'string'}, 'args': {'type': 'array'},
                                                         'equipment': {'type': 'boolean'}, 'variable': {'type': 'string'},
                                                         'on': {'type': 'string'}, 'format': {'type': 'string'}}, 'required': ['action']})
        self.register('look', self.look, 'Look at a picture or a PDF page with the model\'s own eyes (vision): file (png / jpg / pdf), page '
                      '(PDF page, 1 = first), question. Use it for drawings, scans, sketches, screenshots.',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}, 'question': {'type': 'string'}, 'page': {'type': 'integer'}},
                       'required': ['file']})
        self.register('physics_lab', self.physics_lab, 'OpenPhysicsAI\'s physics lab, used as written (C solvers, each checked against a '
                      'closed form or a measurement): flow / CFD (incl. shocks, wings, cylinders), heat, fire, water and sloshing, '
                      'sound, radar, magnetics and motors, fracture, impact, gears and mechanisms, metal / plastic 3D printing. '
                      'action: list {query} | get {scenario} | run {scenario = example name or a full scenario dict, changes = '
                      'values to override}. Every number in a scenario carries its unit in its key (length_m, pressure_pa).',
                      {'type': 'object', 'properties': {'action': {'type': 'string'}, 'scenario': {'type': ['string', 'object']},
                                                         'changes': {'type': 'object'}, 'query': {'type': 'string'}}, 'required': ['action']})
        self.register('mcp_tools', self.mcp_tools, 'Operations of an MCP server ShipBrain can use as written: server "openphysics" (88: '
                      'geometry, meshing, materials, structural / thermal analysis, topology optimisation, mechanisms, 3D printing, lab) '
                      'or one listed in mcp_servers.json; query filters by name.',
                      {'type': 'object', 'properties': {'server': {'type': 'string'}, 'query': {'type': 'string'}}})
        self.register('mcp_call', self.mcp_call, 'Call one operation of an MCP server (see mcp_tools): server, tool, arguments.',
                      {'type': 'object', 'properties': {'server': {'type': 'string'}, 'tool': {'type': 'string'}, 'arguments': {'type': 'object'}},
                       'required': ['tool']})
        self.register('stl_to_step', self.stl_to_step, 'Mesh (STL: scans, 3D-print files, mesh exports) -> exact STEP solid with next.BREP.io\'s '
                      'stl2step: planes, cylinders, cones, spheres, tori recognised. unit of the STL: mm | cm | m | inch | foot. '
                      '(The CAD tools also accept .stl directly.)',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}, 'unit': {'type': 'string'}}, 'required': ['file']})
        self.register('native_cad', self.native_cad, 'Native CAD files without the CAD program, with cadmpeg (free): SolidWorks .sldprt, '
                      'CATIA .CATPart, Inventor .ipt/.iam, Fusion .f3d, Rhino .3dm, FreeCAD .FCStd, ACIS .sat, IGES, NX/Creo .prt '
                      '(partly). op: convert (to STEP, or to=iges) | inspect (what is inside) | check (errors) | measure (bodies, '
                      'faces, mass with density kg/m3) | diff (geometry of file vs other). Every other CAD tool also accepts '
                      'these files directly (they are converted on the way in).',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}, 'op': {'type': 'string', 'enum': [
                          'convert', 'inspect', 'check', 'measure', 'diff']}, 'to': {'type': 'string'}, 'other': {'type': 'string'},
                          'density': {'type': 'number'}}, 'required': ['file']})
        self.register('nx_open', self.nx_open, 'Siemens NX / Simcenter 3D automation with NX Open Python journals, using nxopentse '
                      '(149 ready functions: CAD bodies / faces / features / datums / assemblies / mass properties; CAE mesh '
                      'collectors, loads and constraints on groups, solutions, subcases, solving, results export / combine / '
                      'envelope, screenshots). op: find (query words) | syntax (name) | journal (calls=[{fn, args, as, '
                      'for_each:"$name"}], part; NX constants as {"nx": "NXOpen.CAE.CaeSetGroupFilterType.GeomFace"}) -> writes the journal and runs it when NX is installed. Use only functions '
                      'that find / syntax return.',
                      {'type': 'object', 'properties': {'op': {'type': 'string', 'enum': ['find', 'syntax', 'journal']},
                                                         'query': {'type': 'string'}, 'name': {'type': 'string'},
                                                         'calls': {'type': 'array'}, 'part': {'type': 'string'},
                                                         'out': {'type': 'string'}}, 'required': ['op']})
        self.register('nx_rename', self.nx_rename, 'Rename a Siemens NX .prt file and update the assemblies / drawings in the same '
                      'folder that use it (NX File Renamer with NX\'s ug_edit_part_names; Windows with NX installed).',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}, 'new_name': {'type': 'string'}},
                       'required': ['file', 'new_name']})
        self.register('mooring', self.mooring, 'Mooring line / chain catenary with CableDyn (free FE solver for mooring lines and '
                      'power cables, validated against OrcaFlex): depth (m), length (m), anchor radius (horizontal distance '
                      'fairlead-anchor, m), chain d_mm + grade (R3, R3S, R4, R4S, R5) + kind (studless | studlink), '
                      'fairlead_z (m, 0 = at the surface, negative below), current (m/s). Gives fairlead / anchor tension, '
                      'angle, touchdown, grounded length, MBL and the API RP 2SK check (condition intact | damaged | transient).',
                      {'type': 'object', 'properties': {'depth': num, 'length': num, 'radius': num, 'd_mm': num, 'grade': {'type': 'string'},
                                                         'kind': {'type': 'string'}, 'fairlead_z': num, 'current': num,
                                                         'condition': {'type': 'string'}}, 'required': ['depth', 'length', 'radius']})
        self.register('cable_run', self.cable_run, 'Run any CableDyn or MoorDyn v2 deck (mooring lines, dynamic power cables, lazy '
                      'waves, bend stiffeners, waves / current / vessel motion): tensions, angles, maxima over time, static profile.',
                      {'type': 'object', 'properties': {'deck': {'type': 'string'}}, 'required': ['deck']})
        self.register('topology', self.topology, 'Topology optimisation of a 2D plate region with TensorMesh (differentiable FE on '
                      'PyTorch, SIMP + MMA): where material carries the load - bracket shapes, web frame / floor lightening '
                      'holes, gusset layouts. L, H (size), nx, ny (elements), fixed edges [left|right|bottom|top], load_at [x, y], '
                      'force [Fx, Fy] (total), volfrac (share of material kept, 0.3-0.6), iters. Gives a picture and the stiffness kept.',
                      {'type': 'object', 'properties': {'L': num, 'H': num, 'nx': num, 'ny': num, 'fixed': {'type': 'array'},
                                                         'load_at': {'type': 'array'}, 'force': {'type': 'array'}, 'volfrac': num,
                                                         'iters': num, 'E': num, 'name': {'type': 'string'}}, 'required': ['L', 'H']})
        self.register('tensor_fem', self.tensor_fem, 'Linear-elastic static solve of a SOLID mesh (.inp/.bdf with tetra / hexa / '
                      'wedge, e.g. from cad_mesh or fe_edit shell_to_solid) with TensorMesh on PyTorch (GPU when present). '
                      'fixed: list of selectors like {"x": 0} or {"x": [0, 10], "z": 0}; loads: [{"at": selector, "force": [Fx, Fy, Fz]}] '
                      '(total force spread over the selected nodes); E, nu.',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}, 'fixed': {'type': 'array'}, 'loads': {'type': 'array'},
                                                         'E': num, 'nu': num}, 'required': ['file', 'fixed', 'loads']})
        self.register('moose_plate', self.moose_plate, 'Plate field (between stiffeners and frames) under lateral pressure with '
                      'MOOSE\'s shell element (Idaho National Laboratory, free): a = span, b = stiffener spacing, t = thickness '
                      '(mm), q = pressure (MPa), clamped or simply supported edges. Gives the deflection and the comparison '
                      'with the Navier series. Needs MOOSE (Docker image idaholab/moose or moose-opt).',
                      {'type': 'object', 'properties': {'a': num, 'b': num, 't': num, 'q': num, 'E': num, 'nu': num,
                                                         'clamped': {'type': 'boolean'}}, 'required': ['a', 'b', 't', 'q']})
        self.register('moose_run', self.moose_run, 'Run any MOOSE input file (.i) - solid mechanics, contact, heat transfer, '
                      'XFEM fracture, Navier-Stokes, porous flow, thermal hydraulics - and read its postprocessors (CSV).',
                      {'type': 'object', 'properties': {'input': {'type': 'string'}}, 'required': ['input']})
        self.register('trace_drawing', self.trace_drawing, 'Scanned drawing (PNG / JPG / TIFF, or a scanned PDF page) -> vectors with '
                      'VTracer: DXF (layer TRACE) + SVG, scan noise removed. scale = drawing units per pixel (optional). Every pen '
                      'stroke becomes its outline (good for a clean vector copy / overlay; for comparing two scans use compare_drawings, '
                      'which overlays the pictures).',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}, 'page': {'type': 'integer'}, 'scale': num,
                                                         'dpi': num}, 'required': ['file']})
        self.register('pipe_flow', self.pipe_flow, 'Pipe hydraulics for ship systems (seawater cooling, ballast, bilge, fire main, fuel, '
                      'lube oil, fresh water) with ProcessPi: pressure drop, head, velocity, Reynolds, pump power. flow_m3h; '
                      'segments in series [{d_mm (inner), length_m, rise_m, material CS|SS|Copper|PVC, fittings {type: count}}]; '
                      'branches: parallel pipes at the end [[{d_mm, length_m, fittings}], ...]; fluid seawater | fresh water | mgo | '
                      'hfo | lube oil | hydraulic oil, or density + viscosity_cst; pump_efficiency. Fitting types: '
                      'standard_elbow_90_deg, standard_elbow_45_deg, long_radius_90_deg, gate_valve, globe_valve, ball_valve, '
                      'angle_valve, swing_check_valve, lift_check_valve, plug_valve_straightway, standard_tee_through_flow, '
                      'standard_tee_through_branch, entrance_sharp, entrance_rounded, exit, sudden_expansion, sudden_contraction.',
                      {'type': 'object', 'properties': {'flow_m3h': num, 'segments': {'type': 'array'}, 'branches': {'type': 'array'},
                                                         'fluid': {'type': 'string'}, 'density': num, 'viscosity_cst': num,
                                                         'pump_efficiency': num}, 'required': ['flow_m3h', 'segments']})
        self.register('reverse_cad', self.reverse_cad, 'Mesh (STL scan / 3D-print / mesh export) -> STEP AP242 solid with ReverseCAD '
                      '(non-commercial licence): watertight B-Rep, volume, area, centre of mass, inertia, mass for a material, '
                      'recognised holes / ISO threads / fillets / chamfers / slots / cavities, and its own verification of the STEP '
                      'against the mesh (Hausdorff distance, 5 gates). material: steel | aluminum | pla | petg | abs | glass. '
                      'Use it when the user wants the features or the verification; stl_to_step fits exact curved faces.',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}, 'material': {'type': 'string'},
                                                         'heatmap': {'type': 'boolean'}}, 'required': ['file']})
        self.register('fatigue_mesh', self.fatigue_mesh, 'Fatigue hot-spot local model: cut a box around the hot spot from a plate assembly, '
                      'mesh it t x t, give the read-out points at 0.5t / 1.5t; with solve=true also run CalculiX and return the '
                      'extrapolated hot-spot stress (1.5 s(0.5t) - 0.5 s(1.5t)).',
                      {'type': 'object', 'properties': {'plates': {'type': 'array'}, 'hotspot': {'type': 'array'}, 'size': {'type': 'number'},
                                                         't': {'type': 'number'}, 'loads': {'type': 'array'}, 'solve': {'type': 'boolean'},
                                                         'name': {'type': 'string'}}, 'required': ['plates', 'hotspot']})
        self.register('compare_drawings', self.compare_drawings, 'Compare two drawings (PDF page, PNG/JPG, DXF, DWG via the free ODA '
                      'File Converter): overlay, then for vector drawings every change numbered (lines, texts by meaning, blocks + '
                      'attributes, dimensions, hatches, circles, layers) in revision clouds, written as <a>_vs_<b>_changes.dxf '
                      '(open in AutoCAD) + .csv. ignore: ["text", "dimensions", "hatches", "blocks", "attributes", "circles", '
                      '"layers", "lines"]; ignore_layers: names or patterns; tolerance in drawing units.',
                      {'type': 'object', 'properties': {'a': {'type': 'string'}, 'b': {'type': 'string'}, 'page_a': {'type': 'integer'},
                                                         'page_b': {'type': 'integer'}, 'ignore': {'type': 'array'},
                                                         'ignore_layers': {'type': 'array'}, 'tolerance': {'type': 'number'}},
                       'required': ['a', 'b']})
        self.register('compare_mesh_drawing', self.compare_mesh_drawing, 'Check an FE mesh against a drawing (plan view at a height): share of '
                      'mesh lines on drawn lines, coverage, best shift (calibration error), overlay image. box = ship mm window the drawing shows.',
                      {'type': 'object', 'properties': {'mesh': {'type': 'string'}, 'drawing': {'type': 'string'},
                                                         'box': {'type': 'array', 'description': '[x0, x1, y0, y1] mm'}, 'level': {'type': 'number'},
                                                         'axis': {'type': 'string'}, 'page': {'type': 'integer'}}, 'required': ['mesh', 'drawing', 'box']})
        self.register('drawing_to_3d', self.drawing_to_3d, 'Turn a DXF structural plan into a 3D model: outline/opening layers -> plate, '
                      'girder/web layers -> vertical plates, stiffener layers -> 1D beams. Writes a STEP and (mesh=true) a 1D+2D FE mesh.',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}, 'z': {'type': 'number'}, 't_plate': {'type': 'number'},
                                                         'layers': {'type': 'object'}, 'mesh': {'type': 'boolean'}, 'element_size': {'type': 'number'}},
                       'required': ['file']})
        self.register('drawing_check', self.drawing_check, 'Check the arithmetic written on a drawing (PDF, DXF, image with OCR): '
                      'products and sums like "24 x 101.6 = 2438.4", "6 @ 800 = 4800", "1200 + 800 = 2000"; lists the ones that do '
                      'not add up and counts numbers by class (plate thickness, weld size, section size ...).',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}, 'page': {'type': 'integer'}}, 'required': ['file']})
        self.register('cad_view_check', self.cad_view_check, 'Check a 3D model (STEP in the workspace) against a 2D drawing view: '
                      'projects the model (front / top / side ...), compares lines both ways and proportions -> PASS / WARN / FAIL '
                      'with hints (missing hole, extra feature, wrong size) and an overlay. crop = [x0,y0,x1,y1] pixels of the view.',
                      {'type': 'object', 'properties': {'model': {'type': 'string'}, 'drawing': {'type': 'string'},
                                                         'views': {'type': 'array', 'description': '["front","top","side"]'},
                                                         'page': {'type': 'integer'}, 'crops': {'type': 'object', 'description': '{"front": [x0,y0,x1,y1]}'}},
                       'required': ['model', 'drawing']})
        self.register('build_structure', self.build_structure, 'Build a ship structure from a SHORT program of building blocks (preferred '
                      'over plates_mesh: far fewer numbers to write). One line per block, "name key=value": deck L B t; opening x y w h; '
                      'girder y h t; web x h t; bulkhead x h t; lbulkhead y h t; stiffeners spacing profile(FB150x12|HP200x10|'
                      'T400x10/150x15|L250x90x10/12) dir; bracket x y size t; load p; fix x=0|x=L|y=0|y=B|edges. Makes the 1D+2D mesh '
                      '(and STEP with step=true).',
                      {'type': 'object', 'properties': {'program': {'type': 'string'}, 'name': {'type': 'string'}, 'element_size': {'type': 'number'},
                                                         'step': {'type': 'boolean'}}, 'required': ['program']})
        self.register('choose_engine', self.choose_engine, 'FIRST step for any analysis question: classifies it (static, natural '
                      'frequencies, buckling, ultimate/plastic, contact, impact/collision, fatigue, fracture, CFD, heat, CAD, mesh) and '
                      'names the best engine installed on this PC (CalculiX, Nastran/ANSYS/Abaqus decks, MoFEM, OpenCourant, OpenFOAM, '
                      'Code_Aster, Elmer, CadQuery ...) and the ShipBrain tool to call next.',
                      {'type': 'object', 'properties': {'question': {'type': 'string'}}, 'required': ['question']})
        self.register('setup_check', self.setup_check, 'What free software ShipBrain can use on THIS PC (solvers, DWG converter, '
                      'Node.js, Rust, OCR, Python packages ...): installed or not, why it is needed and the download link. Use when '
                      'the user asks what to install or how to set up a PC.',
                      {'type': 'object', 'properties': {'only_missing': {'type': 'boolean'}}})
        self.register('find_solvers', self.find_solvers, 'List the FE / CFD solvers installed on THIS workstation (CalculiX, MSC / NX '
                      'Nastran, MYSTRAN, ANSYS, Abaqus, OpenFOAM, Code_Aster) with their paths, so the user can choose one.',
                      {'type': 'object', 'properties': {}})
        self.register('remember_solver', self.remember_solver, 'Add a solver installed in an unusual folder: name (calculix | nastran | '
                      'mystran | ansys | abaqus | openfoam) and the full path of its executable.',
                      {'type': 'object', 'properties': {'name': {'type': 'string'}, 'path': {'type': 'string'}}, 'required': ['name', 'path']})
        self.register('solve', self.solve, 'Run an analysis of a ShipBrain model (.inp / .bdf in the workspace) with the solver the user '
                      'chose (found on this PC): writes that solver\'s input, runs it in batch, reads the results back. '
                      'analysis: static | modal | buckling.',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}, 'solver': {'type': 'string'},
                                                         'analysis': {'type': 'string', 'enum': ['static', 'modal', 'buckling']},
                                                         'n_modes': {'type': 'integer'}}, 'required': ['file', 'solver']})
        self.register('analysis_run', self.analysis_run, 'Run an analysis of a mesh file in the workspace (.inp written by ShipBrain) '
                      'with CalculiX: "static" (displacement, von Mises), "modal" (natural frequencies in Hz), "buckling" (load '
                      'factors for the loads in the model).',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}, 'analysis': {'type': 'string', 'enum': ['static', 'modal', 'buckling']},
                                                         'n_modes': {'type': 'integer'}}, 'required': ['file', 'analysis']})
        self.register('drawing_to_model', self.drawing_to_model, 'Read a SHIP structural drawing (PDF deck plans / elevations / sections) '
                      'into a member model XML with the ship drawing reader (frame / OFF C.L / deck-height calibration, line-style and '
                      'label rules); optional coverage score against a reference XML. Takes minutes.',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}, 'reference': {'type': 'string'}, 'settings': {'type': 'string'},
                                                         'pages': {'type': 'string'}, 'raster': {'type': 'boolean'}}, 'required': ['file']})
        self.register('compare_structures', self.compare_structures, 'Compare two structure models. method "coverage" (default): '
                      'stiffener length and plate area found in the other model with the same section / thickness, both ways, and where '
                      'the gaps are - works when members are split differently (drawing-read vs yard model). method "members": '
                      'one-to-one changes between two versions of one model (same / changed / moved / added / removed). '
                      'Reads structure JSON, OCX (.3docx) or ship XML.',
                      {'type': 'object', 'properties': {'a': {'type': 'string'}, 'b': {'type': 'string'}, 'tol': {'type': 'number'},
                                                         'move_tol': {'type': 'number'}}, 'required': ['a', 'b']})
        self.register('ocx_syntax', self.ocx_syntax, 'OCX (open 3D class exchange, .3docx ship structure standard) library: the exact '
                      'syntax of any OCX element / type / enumeration in any schema version 2.8.6 ... 3.2.0 (attributes, required '
                      'children in order, allowed values, where used, which versions have it, XML example). name = an element '
                      '(Plate, Stiffener, BarSection, FunctionTypeValue ...) or words to search ("bulb", "watertight"). '
                      'changes_from = an older version: what changed from it to version.',
                      {'type': 'object', 'properties': {'name': {'type': 'string'}, 'version': {'type': 'string'},
                                                         'changes_from': {'type': 'string'}}})
        self.register('ocx_read', self.ocx_read, 'Read an OCX ship model (.3docx, any schema version): panels, plates (thickness), '
                      'stiffeners (sections), brackets, pillars, seams, holes, frame tables, catalogues; saves it as a structure '
                      'JSON for compare_structures / structure_to_mesh.',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}}, 'required': ['file']})
        self.register('ocx_query', self.ocx_query, 'Find members in an OCX model: by name (part of it), kind (panel / plate / '
                      'stiffener / bracket), panel function (DECK, BULKHEAD, SHELL ...) or plate thickness range (mm); each with '
                      'thickness, material, section, size, weight. No filter = the list of panels.',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}, 'name': {'type': 'string'}, 'kind': {'type': 'string'},
                                                         'function': {'type': 'string'}, 'min_thk': {'type': 'number'},
                                                         'max_thk': {'type': 'number'}}, 'required': ['file']})
        self.register('ocx_validate', self.ocx_validate, 'Check an OCX file against the official schema of its version (XSD) and '
                      'the OCX library: valid or the list of problems with their place in the file.',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}}, 'required': ['file']})
        self.register('ocx_write', self.ocx_write, 'Write a structure model (structure JSON, OCX or ship XML) as an OCX 3.2.0 '
                      'file made with the official OCX classes, then check it against the official XSD.',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}, 'out': {'type': 'string'},
                                                         'name': {'type': 'string'}}, 'required': ['file']})
        self.register('ocx_to_step', self.ocx_to_step, 'OCX model -> STEP 3D CAD (OCXReader when built, else ShipBrain plates + stiffeners).',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}}, 'required': ['file']})
        self.register('class_rule', self.class_rule, 'Class society rules (ships and offshore). action "longitudinal": IACS UR S11 / S7 hull '
                      'girder strength from L, B (m), Cb [Ms_hog, Ms_sag kN m, yield MPa, x/L, Z_deck, Z_bottom cm3, I cm4] - wave '
                      'moments, minimum Z and I, permissible stress, required Z, PASS/FAIL; "k": material factor; "search": the '
                      'rule texts of IACS / DNV / ABS / BV / LR / ClassNK / KR / CCS ... (query, society) with document, section '
                      'and page; "societies": which rule books are on this PC and how to get the others.',
                      {'type': 'object', 'properties': {'action': {'type': 'string', 'enum': ['longitudinal', 'k', 'search', 'societies']},
                                                         'query': {'type': 'string'}, 'society': {'type': 'string'},
                                                         'L': {'type': 'number'}, 'B': {'type': 'number'}, 'Cb': {'type': 'number'},
                                                         'Ms_hog': {'type': 'number'}, 'Ms_sag': {'type': 'number'}, 'yield_mpa': {'type': 'number'},
                                                         'x': {'type': 'number'}, 'Z_deck': {'type': 'number'}, 'Z_bottom': {'type': 'number'},
                                                         'I': {'type': 'number'}}, 'required': ['action']})
        self.register('drawing_to_step', self.drawing_to_step, 'A 2D CAD drawing (picture or PDF) of a PART -> 3D STEP with cad3dify\'s '
                      'loop on ShipBrain\'s own model: write CadQuery code from the drawing, run it, render the 3D result, compare '
                      'with the drawing and correct the code (refinements rounds). For machine parts and simple brackets / plates.',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}, 'refinements': {'type': 'integer'},
                                                         'out': {'type': 'string'}}, 'required': ['file']})
        self.register('process_sim', self.process_sim, 'Chemical / process simulation with DWSIM (free, built in): action "run": load and '
                      'solve a DWSIM flowsheet (.dwxml / .dwxmz) -> every stream (T, P, flow, phases, composition) and unit operation; '
                      '"flash": compounds + mass fractions + T (C) + P (bar) [+ flow kg/h, property package] -> phases, densities, '
                      'composition; "packages": the property packages. For building whole flowsheets use mcp_call server "dwsim".',
                      {'type': 'object', 'properties': {'action': {'type': 'string', 'enum': ['run', 'flash', 'packages']},
                                                         'file': {'type': 'string'}, 'compounds': {'type': 'array', 'items': {'type': 'string'}},
                                                         'mass_fractions': {'type': 'array', 'items': {'type': 'number'}}, 'T_C': {'type': 'number'},
                                                         'P_bar': {'type': 'number'}, 'flow_kg_h': {'type': 'number'}, 'package': {'type': 'string'}},
                       'required': ['action']})
        self.register('dexpi', self.dexpi, 'DEXPI P&ID files (DEXPI 2.0 XML/JSON, Proteus XML) with pyDEXPI: action "summary" (equipment '
                      'with tags, instruments, piping), "validate" (every DEXPI rule), "tables" (equipment / line / instrument / valve '
                      'lists, xlsx or csv), "drawing" (PNG + SVG), "diff" (file vs other: what changed).',
                      {'type': 'object', 'properties': {'action': {'type': 'string', 'enum': ['summary', 'validate', 'tables', 'drawing', 'diff']},
                                                         'file': {'type': 'string'}, 'other': {'type': 'string'}, 'format': {'type': 'string'}},
                       'required': ['action', 'file']})
        self.register('serving_sim', self.serving_sim, 'How fast an LLM server answers many users at once (Simthesizer, no GPU needed): users, '
                      'requests per second, prompt and answer length (tokens) -> time to first word, tokens/s per user, answer time, '
                      'total throughput, for its measured model + GPU set-ups (list them with action "scenarios").',
                      {'type': 'object', 'properties': {'action': {'type': 'string', 'enum': ['simulate', 'scenarios']},
                                                         'users': {'type': 'integer'}, 'rate_per_s': {'type': 'number'},
                                                         'input_tokens': {'type': 'integer'}, 'output_tokens': {'type': 'integer'},
                                                         'scenario': {'type': 'string'}}})
        self.register('parse_document', self.parse_document, 'Read a document (PDF, Word, Excel, PowerPoint, picture) into markdown with '
                      'LiteParse (local, fast): headings, tables, reading order; says which pages are scanned / need OCR; ocr=true '
                      'reads those too (Tesseract). Saves <name>.md for knowledge_search / the chat.',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}, 'ocr': {'type': 'boolean'},
                                                         'pages': {'type': 'string'}}, 'required': ['file']})
        self.register('bolt', self.bolt, 'Bolted joint (metric ISO thread, VDI 2230 / ISO 898-1): size d (mm), property class (4.6 5.6 8.8 '
                      '10.9 12.9 A2-70 A4-80), friction mu_G / mu_K -> stress area, assembly preload, tightening torque, preload '
                      'scatter of the tightening method; with an axial working load F_A (N) and load factor Phi: bolt stress, '
                      'fatigue (alternating stress vs endurance limit) and the clamping force left. Inch bolts: d as "1/2", "#10" ..., '
                      'thread UNC / UNF, cls = SAE grade 2 / 5 / 8 or A325 / A490 -> stress area, preload, nut-factor torque.',
                      {'type': 'object', 'properties': {'d': {'type': ['number', 'string']}, 'thread': {'type': 'string'},
                                                         'nut_factor': {'type': 'number'}, 'c': {'type': 'number'}, 'cls': {'type': 'string'}, 'mu_G': {'type': 'number'},
                                                         'mu_K': {'type': 'number'}, 'pitch': {'type': 'number'}, 'method': {'type': 'string'},
                                                         'F_A': {'type': 'number'}, 'Phi': {'type': 'number'}, 'F_Kerf': {'type': 'number'}},
                       'required': ['d']})
        self.register('drawing_takeoff', self.drawing_takeoff, 'Construction drawings (electrical / architectural / P&ID) read into '
                      'a CIR file (.cir / .json): quantity takeoff - counts per item with MasterFormat / IFC codes, items to '
                      'review, connections (conductors, home runs, feeders), lengths / areas when a scale is known. '
                      'ConstructDrawingAI engine (non-commercial licence).',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}, 'min_confidence': {'type': 'number'}},
                       'required': ['file']})
        self.register('drawing_detect', self.drawing_detect, 'Electrical drawing PICTURE (png / jpg / pdf page) -> symbols found by '
                      'ConstructDrawingAI\'s trained detector -> a CIR file (for drawing_takeoff / drawing_qa) and the takeoff.',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}, 'discipline': {'type': 'string'},
                                                         'min_confidence': {'type': 'number'}}, 'required': ['file']})
        self.register('drawing_qa', self.drawing_qa, 'Ask a question about a construction drawing set (CIR file): counts '
                      '("how many receptacles on E-101"), lists ("list the panels"), sheets, disciplines - answered from the '
                      'data with evidence. action "rfi" drafts RFIs for unclear / low-confidence items.',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}, 'question': {'type': 'string'},
                                                         'action': {'type': 'string', 'enum': ['qa', 'rfi']}}, 'required': ['file']})
        self.register('structure_to_mesh', self.structure_to_mesh, 'Make a global 1D+2D FE mesh from a structure model (structure JSON or '
                      'ship XML through your plugin): plates with thickness and openings -> shells, stiffeners -> beams with their sections. '
                      'Also writes the plates/beams JSON and (if CadQuery is installed) a STEP.',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}, 'element_size': {'type': 'number'},
                                                         'merge_tol': {'type': 'number', 'description': 'snap tolerance for near-misses, mm (default 10)'},
                                                         'step': {'type': 'boolean'}}, 'required': ['file']})
        self.register('list_files', self.list_files, 'List the files in the workspace (uploads and results).', {'type': 'object', 'properties': {}})
        if self.allow_code:
            self.register('cadquery_build', self.cadquery_build,
                          'Run a CadQuery script that sets `result` (a cq.Workplane); exports STEP + STL. Returns bbox, volume, n_solids, valid '
                          'and PASS/FAIL against expect (put the user\'s sizes there). Then cad_mesh the .step for FE.',
                          {'type': 'object', 'properties': {'code': {'type': 'string'}, 'name': {'type': 'string'},
                                                             'expect': {'type': 'object', 'description': '{"bbox": [x,y,z] mm, "volume": mm3, "n_solids": n, "tol": 0.01}'}},
                           'required': ['code']})

    # ------------------------------------------------------------------ implementations
    def knowledge_search(self, query, k=5, scope=None):
        k = int(k)
        bases = [b for b in (self.kb, self.repo_kb) if b is not None and len(b)]
        if scope and self.repo_kb is not None and ('repo' in scope.lower() or any(scope.lower() in str(s_.get('name', '') if isinstance(s_, dict) else s_).lower() for s_ in getattr(self.repo_kb, 'packs', []) or [])):
            bases = [self.repo_kb]
        if not bases:
            return {'results': [], 'note': 'knowledge folder is empty - start the app with --knowledge DIR'}
        hits = sorted((h for b in bases for h in b.search(query, k, scope=scope)), key=lambda h: -h['score'])[:k]
        return {'results': [{'id': h['id'], 'source': h['source'], 'title': h['title'], 'text': h['text'][:700], 'score': h['score']}
                            for h in hits]}

    def _mem(self):
        if self.memory is None:
            from .memory import Memory
            self.memory = Memory(os.path.join(self.workdir, '.memory'))
        return self.memory

    def remember(self, text, tags=None):
        return self._mem().remember(text, tags)

    def recall(self, query):
        return {'memories': [{'id': m['id'], 'text': m['text'], 'likes': m.get('likes', 0)} for m in self._mem().recall(query, 5, 0.5)]}

    def memory_feedback(self, id, good=True, forget=False):
        return self._mem().forget(id) if forget else self._mem().feedback(id, good)

    def panel_mesh(self, **spec):
        spec.setdefault('name', 'panel_%s' % time.strftime('%H%M%S'))
        spec['name'] = re.sub(r'[^A-Za-z0-9_\-]', '_', str(spec['name']))[:40]
        m, info = _mesh.build_panel(spec, self.workdir)
        self.last_mesh = _mesh.viewer_data(m)
        info['files'] = {k: os.path.basename(v) for k, v in info['files'].items()}
        info['viewer'] = 'mesh shown in the 3D view'
        return info

    def _mesh_result(self, m, info):
        self.last_mesh = _mesh.viewer_data(m)
        info['files'] = {k: os.path.basename(v) for k, v in info['files'].items()}
        info['viewer'] = 'mesh shown in the 3D view'
        return info

    def plates_mesh(self, plates, name=None, element_size=100.0, loads=None, fix=None, material=None, beams=None, clean=True):
        from . import geoclean
        actions = []
        if clean:
            plates, actions = geoclean.clean_plates(plates, merge_tol=max(1.0, float(element_size) / 50))
        spec = {'name': re.sub(r'[^A-Za-z0-9_\-]', '_', str(name or 'assembly_%s' % time.strftime('%H%M%S')))[:40],
                'plates': plates, 'element_size': element_size, 'loads': loads or [], 'fix': fix or [], 'beams': beams or []}
        if material:
            spec['material'] = material
        out = self._mesh_result(*_pm.build_plates(spec, self.workdir))
        out['cleaning'] = actions
        return out

    def cad_mesh(self, file, element_size=100.0, default_t=10.0, loads=None, fix=None):
        from . import cadplates
        return self._mesh_result(*cadplates.mesh_cad(self._path(file), element_size, default_t, self.workdir, loads=loads, fix=fix))

    def file_info(self, file):
        from .fileinfo import file_info
        return file_info(self._path(file))

    def fe_convert(self, file, to=('bdf', 'inp', 'mac')):
        from .femodel import FEModel
        m = FEModel.read(self._path(file))
        base = os.path.join(self.workdir, os.path.splitext(os.path.basename(file))[0] + '_conv')
        files = [os.path.basename(m.write(base + '.' + ext)) for ext in to]
        if 'mac' in to:
            files += [os.path.basename(x) for x in m.write_drivers(base)]
        s = m.summary()
        return {'files': files, 'model': s, 'plain_english': f"Converted {file} ({s['nodes']} nodes, {s['elements']} elements) to " + ', '.join(files) + '.'}

    def fe_edit(self, file, ops, out=None):
        from .femodel import FEModel
        m = FEModel.read(self._path(file))
        log = []
        for o in ops:
            o = dict(o)
            name = o.pop('op')
            if name == 'merge':
                o = {'other': FEModel.read(self._path(o.pop('file'))), **o}
            if name == 'delete' and 'types' in o and isinstance(o['types'], str):
                o['types'] = [o['types']]
            fn = getattr(m, name, None)
            if name.startswith('_') or not callable(fn) or name in ('read', 'write', 'copy', 'summary', 'check'):
                raise ValueError(f'unknown edit op {name}')
            log.append({name: fn(**o)})
        out = out or os.path.splitext(os.path.basename(file))[0] + '_edited' + os.path.splitext(file)[1]
        m.write(self._path(out))
        c = m.check()
        return {'file': out, 'steps': log, 'model': m.summary(), 'check': c.get('verdict', 'n/a'),
                'parts': c.get('all_elements_parts')}

    def repair_model(self, file, request=None, holes_below=None, fillets_below=None, chamfers_below=None, faces_below=None,
                     bosses_below=None, sew=None, mesh_size=None, min_elements=5):
        """CAD defeaturing / repair or FE mesh repair, driven by the user's words and/or explicit sizes"""
        base, ext = os.path.splitext(os.path.basename(file))
        ext = ext.lower()
        if ext in ('.bdf', '.dat', '.nas', '.inp'):
            from .femodel import FEModel
            m = FEModel.read(self._path(file))
            before = m.summary()
            steps = m.repair(min_elements=min_elements)
            out = base + '_repaired' + ext
            m.write(self._path(out))
            c = m.check()
            s = m.summary()
            pe = (f"Repaired {file}: merged {steps['equivalence']['merged_nodes']} coincident nodes, removed "
                  f"{steps['degenerate']['degenerate_or_duplicate_removed']} bad/duplicate elements, turned "
                  f"{steps['degenerate']['inverted_solids_fixed']} inside-out solids, flipped {steps['normals']['shells_flipped']} shell "
                  f"normals, deleted {steps['small_parts'].get('elements_removed', 0)} element(s) in small loose parts. "
                  f"{before['elements']} -> {s['elements']} elements, {c.get('all_elements_parts')} connected part(s). Saved {out}.")
            return {'file': out, 'steps': steps, 'model': s, 'check': c.get('verdict', 'n/a'), 'plain_english': pe}
        from . import geofix
        from .cadplates import import_cad
        import cadquery as cq
        args, assumed = geofix.args_from_text(request) if request else ({}, [])
        for k, v in (('holes_below', holes_below), ('fillets_below', fillets_below), ('chamfers_below', chamfers_below),
                     ('faces_below', faces_below), ('bosses_below', bosses_below), ('sew', sew)):
            if v is not None:
                args[k] = v
        shp, actions, summ = geofix.repair(import_cad(self._path(file)), **args)
        out = base + '_repaired.step'
        cq.exporters.export(cq.Workplane().add(shp), self._path(out))
        res = {'file': out, 'settings': args, 'actions': actions, 'summary': summ,
               'plain_english': ' '.join(actions) + f" Faces {summ['faces_before']} -> {summ['faces_after']}, volume change "
                                f"{summ['volume_change_pct']} %, valid solid: {'yes' if summ['valid'] else 'NO'}. Saved {out}."
                                + (f" Assumed: {', '.join(assumed)} mm." if assumed else '')}
        if mesh_size:
            res['mesh'] = self.cad_mesh(out, element_size=mesh_size)
        return res

    def surface_extract(self, file, kind='mid', max_thickness=60.0, round_to=0.5, mesh_size=None):
        from . import surfex
        from .cadplates import import_cad
        kind = 'outer' if str(kind).lower().startswith('out') else 'mid'
        groups, rep = surfex.extract(import_cad(self._path(file)), kind, max_t=float(max_thickness), round_to=float(round_to))
        if not groups:
            raise ValueError('no thin solids found (no face pairs closer than max_thickness): ' + '; '.join(rep['not_thin'][:5]))
        out = os.path.splitext(os.path.basename(file))[0] + f'_{kind}_surface.step'
        surfex.save_groups(groups, self._path(out), kind)
        nt = len(rep['not_thin'])
        rep['not_thin'] = rep['not_thin'][:10]
        res = {'file': out, 'report': rep,
               'plain_english': f"Extracted {rep['surfaces']} {kind} surface(s) from {rep['thin_solids']} of {rep['solids']} solids, "
                                f"grouped by thickness: " + ', '.join(f'{k}: {v}' for k, v in rep['thickness_groups'].items()) + '. '
                                + (f'{nt} solid(s) are not thin (blocks, castings) and were left out. ' if nt else '') + f'Saved {out}.'}
        if mesh_size:
            plates = surfex.groups_to_plates(groups, float(mesh_size))
            if plates:
                res['mesh'] = self.plates_mesh(plates, name=os.path.splitext(out)[0], element_size=float(mesh_size))
        return res

    def pipe_extract(self, file, schedule='SCH40', element_size=200.0, to=('bdf', 'inp')):
        from . import surfex
        from .cadplates import import_cad
        found = surfex.pipes(import_cad(self._path(file)), schedule=schedule)
        r = found['report']
        if not (found['straights'] or found['bends']):
            raise ValueError('no pipes found (no outward cylinders or tori that go all the way round)')
        m = surfex.pipe_fe_model(found, float(element_size))
        base = os.path.splitext(os.path.basename(file))[0] + '_piping'
        files = [os.path.basename(m.write(self._path(base + '.' + e))) for e in to]
        with open(self._path(base + '.json'), 'w') as fh:
            json.dump({k: v for k, v in found.items()}, fh, indent=1)
        sizes = ', '.join(f'{d:g}' for d in r['sizes'][:10])
        c = m.check()
        return {'files': files + [base + '.json'], 'report': r, 'straights': found['straights'][:12], 'bends': found['bends'][:8],
                'runs': [len(x) for x in found['runs'][:12]],
                'plain_english': f"Found {r['straight_pipes']} straight pipe(s) and {r['bends']} bend(s) in {r['runs']} connected run(s), "
                                 f"total {r['total_length_m']} m; outside diameters {sizes} mm. 1D FE model: {m.summary()['elements']} pipe "
                                 f"beams in {c.get('all_elements_parts')} part(s), saved as {', '.join(files)}."}

    def surrogate_build(self, ranges, name='plate_surrogate', n=30, max_runs=None, edge='clamped', template=None):
        from . import cae_ai
        name = re.sub(r'[^A-Za-z0-9_\-]', '_', str(name))[:40]
        ranges = {k: [float(v[0]), float(v[1])] for k, v in ranges.items()}
        tpl = template or cae_ai.plate_template(edge)
        if not template:
            miss = [k for k in ('L', 'B', 't', 'p') if k not in ranges]
            if miss:
                raise ValueError('plate surrogate needs ranges for L, B, t, p; missing: ' + ', '.join(miss))
        t0 = time.time()
        s = cae_ai.build(tpl, ranges, int(n), self.workdir, name, log=None, max_runs=int(max_runs) if max_runs else None)
        s.save(self._path(name + '.npz'))
        s.export_cpp(self._path(name + '.hpp'))
        loo = s.meta['loo']
        return {'files': [name + '.npz', name + '.hpp'], 'runs': len(s.runs), 'adaptive_runs': s.meta['adaptive_runs'],
                'accuracy_leave_one_out': loo, 'pod_modes': {f: m['n_modes'] for f, m in s.models.items()},
                'seconds_per_solve': s.meta['seconds_per_solve'],
                'plain_english': f"Trained a surrogate on {len(s.runs)} real CalculiX runs ({s.meta['adaptive_runs']} added where it was least "
                                 f"accurate) in {time.time() - t0:.0f} s. Checked by leaving each run out: peak stress within "
                                 f"{loo['vm_peak']['mean_pct']} % on average (worst {loo['vm_peak']['max_pct']} %), peak displacement within "
                                 f"{loo['umag_peak']['mean_pct']} %. A prediction takes about 1 ms instead of {s.meta['seconds_per_solve']} s. "
                                 f"Saved {name}.npz and the C++ header {name}.hpp."}

    def surrogate_predict(self, name, params, tol_pct=5.0, fallback=True):
        from . import cae_ai
        from .solver import ccx_path
        path = self._path(re.sub(r'\.npz$', '', str(name)) + '.npz')
        s = cae_ai.Surrogate.load(path)
        miss = [k for k in s.keys if k not in params]
        if miss:
            raise ValueError('missing parameter(s): ' + ', '.join(miss))
        p = {k: float(params[k]) for k in s.keys}
        pr = s.predict(p, float(tol_pct))
        base = os.path.splitext(os.path.basename(path))[0]
        if not pr['confident'] and fallback and ccx_path() and s.meta.get('template'):
            res = cae_ai.solve_case(s.meta['template'], p, os.path.join(self.workdir, base + '_runs'), f'{base}_{len(s.runs):03d}')
            s.add(p, res)
            if pr['inside_range']:
                s.fit()
                s.save(path)
                s.export_cpp(path[:-4] + '.hpp')
            vtk = cae_ai.write_vtk(self._path(base + '_check.vtk'), res['xyz'], {'von_mises_MPa': res['vm'], 'displacement_mm': res['umag']})
            why = 'outside the trained range' if not pr['inside_range'] else f"estimated error {pr['error_estimate_pct']} % > {tol_pct} %"
            return {'source': 'real solver (CalculiX)', 'max_von_mises_MPa': round(float(res['vm'].max()), 2),
                    'max_displacement_mm': round(float(res['umag'].max()), 4), 'surrogate_said': {'vm': round(pr['vm_max'], 2),
                    'umag': round(pr['umag_max'], 4)}, 'files': [os.path.basename(vtk)],
                    'plain_english': f"The surrogate was not sure here ({why}), so I ran the real solver: max von Mises "
                                     f"{float(res['vm'].max()):.2f} MPa, max displacement {float(res['umag'].max()):.4f} mm (surrogate guess "
                                     f"{pr['vm_max']:.2f} MPa)." + (' The run was added to the surrogate, so it is better here next time.'
                                                                    if pr['inside_range'] else '')}
        X = s.runs[0]['xyz']
        vtk = cae_ai.write_vtk(self._path(base + '_prediction.vtk'), X, {'von_mises_MPa': pr['vm'], 'displacement_mm': pr['umag']})
        return {'source': 'surrogate', 'max_von_mises_MPa': round(pr['vm_max'], 2), 'max_displacement_mm': round(pr['umag_max'], 4),
                'error_estimate_pct': pr['error_estimate_pct'], 'inside_range': pr['inside_range'], 'confident': pr['confident'],
                'files': [os.path.basename(vtk)],
                'plain_english': f"Surrogate prediction: max von Mises {pr['vm_max']:.2f} MPa, max displacement {pr['umag_max']:.4f} mm "
                                 f"(estimated error {pr['error_estimate_pct']} %"
                                 + ('' if pr['confident'] else ', NOT confident: check with the real solver') + '). '
                                 f"Field saved as {os.path.basename(vtk)} for ParaView."}

    def result_insight(self, file, yield_MPa=235.0, safety_factor=1.0, baseline=None):
        from . import cae_ai
        r = cae_ai.insight(self._path(file), float(yield_MPa), float(safety_factor), self._path(baseline) if baseline else None)
        r['vtk'] = os.path.basename(r['vtk'])
        r['plain_english'] = r.pop('report_draft') + f" Fields saved as {r['vtk']} for ParaView."
        return r

    @property
    def skills(self):
        from .skills import Skills
        folder = os.path.join(self.workdir, 'skills')
        if getattr(self, '_skills', None) is None or self._skills_folder != folder:
            self._skills, self._skills_folder = Skills([folder] + list(getattr(self, 'skill_dirs', []))), folder
        return self._skills

    def add_skill(self, name, description, steps, when=''):
        path = self.skills.add(os.path.join(self.workdir, 'skills'), name, description, steps, when)
        nm = os.path.splitext(os.path.basename(path))[0]
        return {'skill': nm, 'file': os.path.relpath(path, self.workdir),
                'plain_english': f'Saved the skill "{nm}". When a question matches it, I will follow these steps. '
                                 f'You can edit {os.path.relpath(path, self.workdir)} at any time.'}

    def list_skills(self):
        items = [{'name': k, 'description': v['description'], 'own': not v['source'].startswith(
            os.path.dirname(os.path.abspath(__file__)))} for k, v in sorted(self.skills.items.items())]
        return {'skills': items, 'plain_english': f"{len(items)} skills: " + '; '.join(
            f"{i['name']} ({'yours' if i['own'] else 'built in'}): {i['description']}" for i in items)}

    def hook(self, event, *args):
        """run the plugins' hooks for an event -> list of notes (text) for the model"""
        out = []
        for fn in getattr(self, 'hooks', {}).get(event, []):
            try:
                r = fn(*args)
                if r:
                    out.append(str(r)[:1500])
            except Exception as e:
                out.append(f'(hook {getattr(fn, "__name__", "?")} failed: {type(e).__name__}: {e})')
        return out

    @property
    def profile(self):
        from .userprofile import Profile
        if getattr(self, '_profile', None) is None or self._profile.path != os.path.join(self.workdir, 'profile.json'):
            self._profile = Profile(self.workdir)
        return self._profile

    def set_profile(self, **kw):
        ch = self.profile.update(**kw)
        return {'saved': ch, 'profile': dict(self.profile.data),
                'plain_english': 'Saved: ' + ', '.join(f'{k} = {v}' for k, v in ch.items()) + '. I will use this in every answer from now on.'}

    def convert_units(self, values):
        from .userprofile import convert_many
        out = convert_many(values)
        return {'converted': out, 'plain_english': '; '.join(f"{v['value']:g} {v['from']} = {v['result']:g} {v['to']}" for v in out)}

    def frame_solve(self, nodes=None, members=None, supports=None, loads=None, combinations=None, file=None, name=None,
                    divisions=10):
        from . import awatif, frame3d
        if file:
            from .femodel import FEModel
            sup = supports if isinstance(supports, list) else [{'node': k, 'type': v} for k, v in (supports or {}).items()]
            model = frame3d.from_femodel(FEModel.read(self._path(file)), sup, loads or {}, combinations)
            divisions = 1
        else:
            if not (nodes and members):
                raise ValueError('give nodes + members (+ supports, loads), or file = a 1D beam / pipe model')
            model = {'nodes': nodes, 'members': members, 'supports': supports or {}, 'loads': loads or {},
                     **({'combinations': combinations} if combinations else {})}
        if not model.get('supports'):
            raise ValueError('no supports given: the frame would fly away')
        out = awatif.analyse(model, divisions=int(divisions))
        base = re.sub(r'[^A-Za-z0-9_\-]', '_', str(name or (os.path.splitext(os.path.basename(file))[0] if file else 'frame')))[:40]
        rep = base + '_frame_report.md'
        with open(self._path(rep), 'w', encoding='utf-8') as fh:
            fh.write(frame3d.report(out, f'{base}: frame check') + f"\n\nSolver: {out.get('solver', '')}\n")
        short = {k: {'max_displacement_mm': v['max_displacement_mm'], 'at_node': v['at_node'], 'sum_reactions': v['sum_reactions'],
                     'members': dict(list(v['members'].items())[:8])} for k, v in out['combinations'].items()}
        return {'governing': out['governing'], 'combinations': short, 'combination_factors': out['combination_factors'],
                'solver': out.get('solver'), 'files': [rep], 'plain_english': out['plain_english'] + f' Report: {rep}.'}

    def code_functions(self, repo=None, query=None):
        from . import polyglot
        if not repo:
            rs = polyglot.repos()
            more = [n for n in polyglot.DOWNLOADABLE if n not in rs]
            return {'repos': rs, 'downloadable': more, 'plain_english': 'Copied repos (whole, unchanged): ' + ', '.join(rs) + '.'
                    + (f" Also usable once you download them: {', '.join(more)}." if more else '')}
        fs = polyglot.list_functions(repo, query, limit=60)
        langs = sorted({f['language'] for f in fs})
        return {'functions': fs[:40], 'count': len(fs),
                'plain_english': f"{len(fs)} function(s) in {repo}" + (f" matching '{query}'" if query else '') + f" ({', '.join(langs)})."}

    def code_folder(self, name, folder):
        from . import polyglot
        d = polyglot.remember_repo(name, folder)
        fs = polyglot.list_functions(name, None, limit=100000)
        langs = sorted({f['language'] for f in fs})
        need = ' MATLAB-language files run in GNU Octave (free: https://octave.org/download) - not found on this PC yet.' \
            if 'octave' in langs and not polyglot.octave_exe() else ''
        return {'repo': name, 'folder': d, 'functions': len(fs),
                'plain_english': f"Using {d} as '{name}': {len(fs)} functions ({', '.join(langs)}). Ask for a calculation and I "
                                 f"will find and run the right function.{need}"}

    def code_call(self, repo, file, function, args=None):
        from . import polyglot
        t0 = time.time()
        res = polyglot.call(repo, file, function, args if args is not None else [])
        txt = json.dumps(res, default=str)
        return {'result': res if len(txt) < 20000 else txt[:20000] + ' ...(cut)', 'seconds': round(time.time() - t0, 2),
                'plain_english': f'Ran {function} from {repo}/{file} in its own language ({time.time() - t0:.1f} s).'}

    def pid_kg(self, action, pdf=None, pages=None, plant_name=None, work=None, command='stats', args=None, equipment=False,
               variable=None, on=None, format='graphml'):
        from . import polyglot
        repo, sk = 'PID-to-Knowledge-Graph', 'skills/pid-to-kg/scripts/'
        name = plant_name or (os.path.splitext(os.path.basename(pdf))[0] if pdf else None)
        work = work or ('work/' + re.sub(r'[^A-Za-z0-9_\-]+', '_', name).strip('_').lower() if name else None)
        if not work:
            raise ValueError('give work (the plant work folder, e.g. work/plant_a) or pdf / plant_name')
        wd = self._path(work)

        def run(script, *a):
            r = polyglot.run_script(repo, sk + script, list(a), cwd=self.workdir)
            if r['returncode']:
                raise RuntimeError((r['stderr'] or r['stdout']).strip()[-1500:])
            return r['stdout'].strip()
        if action == 'probe':
            if not pdf:
                raise ValueError('probe needs the pdf')
            out = run('probe_pdf.py', self._path(pdf), '--work', wd, '--plant-name', name, *(['--pages', pages] if pages else []))
        elif action == 'render':
            out = run('render_pages.py', wd, *(['--pages', pages] if pages else []))
        elif action == 'hints':
            out = run('make_hints.py', wd, *(['--pages', pages] if pages else []))
        elif action == 'build':
            out = run('build_kg.py', wd, *(['--plant-name', plant_name] if plant_name else []))
        elif action == 'query':
            flags = (['--equipment'] if equipment else []) + (['--variable', variable] if variable else []) + (['--on', on] if on else [])
            out = run('kg_query.py', os.path.join(wd, 'kg'), command, *[str(x) for x in (args or [])], *flags)
        elif action == 'export':
            out = run('export.py', os.path.join(wd, 'kg'), format)
        elif action == 'tags':                                   # tags found on each sheet (hints), read with pid-to-kg's ISA parser
            import glob
            sys.path.insert(0, os.path.join(polyglot.repo_dir(repo), 'skills', 'pid-to-kg', 'scripts'))
            from pidkg.isa import parse_isa_tag
            lines = []
            for f in sorted(glob.glob(os.path.join(wd, 'hints', 'page_*.json'))):
                h = json.load(open(f, encoding='utf-8'))
                if pages and str(h.get('page')) not in re.split(r'[,\s]+', str(pages)):
                    continue
                eq, ins = [], []
                for t in h.get('tag_candidates', []):
                    p_ = parse_isa_tag(t['text'])
                    if p_ is not None and not t.get('equipment_like'):
                        ins.append(f"{t['text']} ({getattr(p_, 'variable', '') or '?'} {getattr(p_, 'role', '') or ''})".replace('  ', ' '))
                    else:
                        eq.append(t['text'])
                lines.append(f"page {h.get('page')} ({h.get('page_class')}, text from {h.get('source')}): "
                             f"equipment / lines: {', '.join(sorted(set(eq))) or '-'}; read as ISA instruments (check on the drawing): {', '.join(sorted(set(ins))) or '-'}")
            out = '\n'.join(lines) or 'no hints yet: run probe, render and hints first'
        elif action == 'read':                                   # the model reads each sheet into extract/page_NN.json
            out = self._pid_read(repo, wd, pages)
        elif action == 'status':
            pages_dir, ext = os.path.join(wd, 'pages'), os.path.join(wd, 'extract')
            rendered = sorted(os.listdir(pages_dir)) if os.path.isdir(pages_dir) else []
            extracted = sorted(os.listdir(ext)) if os.path.isdir(ext) else []
            kg = os.path.exists(os.path.join(wd, 'kg', 'graph.json'))
            out = (f'{len(rendered)} page(s) rendered, {len(extracted)} sheet extraction(s) written, graph built: {"yes" if kg else "no"}.'
                   + ('' if extracted or not rendered else ' Next: read each sheet (pages/page_NN/ tiles) and write extract/page_NN.json '
                      '- pid_kg action read does it with the model\'s vision (or Claude); the format is in '
                      'vendor/PID-to-Knowledge-Graph/repo/skills/pid-to-kg/references/extraction_procedure.md.'))
        else:
            raise ValueError('action: probe | render | hints | status | build | query | export')
        files = []
        if action == 'build':
            files = [os.path.relpath(os.path.join(wd, 'kg', f), self.workdir) for f in ('summary.md', 'qa_report.md', 'graph.json', 'graph.duckdb')
                     if os.path.exists(os.path.join(wd, 'kg', f))]
        return {'work': work, 'output': out[-6000:], 'files': files,
                'plain_english': (out.splitlines()[0] if action == 'build' and out else f'pid-to-kg {action} done.') +
                                 ('' if action != 'query' else ' Answer from the graph: ' + out[:600])}

    def _pid_read(self, repo, wd, pages=None):
        """read rendered sheets with the vision model; each result is checked with pid-to-kg's own PageExtraction model"""
        import glob
        from . import polyglot
        root = polyglot.repo_dir(repo)
        sys.path.insert(0, os.path.join(root, 'skills', 'pid-to-kg', 'scripts'))
        from pidkg.models import PageExtraction
        example = open(os.path.join(root, 'tests', 'fixtures', 'mini_plant', 'extract', 'page_01.json'), encoding='utf-8').read()
        want = {int(x) for x in re.findall(r'\d+', str(pages))} if pages else None
        os.makedirs(os.path.join(wd, 'extract'), exist_ok=True)
        done = []
        for pdir in sorted(glob.glob(os.path.join(wd, 'pages', 'page_*'))):
            n = int(re.findall(r'\d+', os.path.basename(pdir))[-1])
            if want and n not in want:
                continue
            img = os.path.join(pdir, 'overview.png') if os.path.exists(os.path.join(pdir, 'overview.png')) else os.path.join(pdir, 'page.png')
            hints = os.path.join(wd, 'hints', f'page_{n:02d}.json')
            tags = ''
            if os.path.exists(hints):
                tags = ', '.join(t['text'] for t in json.load(open(hints, encoding='utf-8')).get('tag_candidates', []))[:1500]
            prompt = pid_read_prompt(n, tags, example)
            err, data = None, None
            for attempt in range(2):
                txt = _strip_think(self.ask_vision([img], prompt + (f'\nYour last answer was invalid: {err}. Fix it.' if err else ''),
                                                   max_tokens=6000))
                m = re.search(r'\{.*\}', txt, re.S)
                try:
                    data = json.loads(m.group(0) if m else txt)
                    data['page'] = n
                    PageExtraction.model_validate(data)
                    err = None
                    break
                except Exception as e:
                    err = str(e)[:600]
            if err:
                done.append(f'page {n}: could not read a valid sheet ({err[:200]})')
                continue
            with open(os.path.join(wd, 'extract', f'page_{n:02d}.json'), 'w', encoding='utf-8') as fh:
                json.dump(data, fh, indent=1)
            done.append(f"page {n}: {len(data.get('equipment', []))} equipment, {len(data.get('components', []))} components, "
                        f"{len(data.get('instruments', []))} instruments, {len(data.get('lines', []))} lines (draft: check with build QA)")
        return '\n'.join(done) or 'no rendered pages: run probe and render first'

    def _image_url(self, path, page=None, max_px=1280):
        """picture or PDF page -> data URL (PNG), long edge max_px"""
        import base64, io
        from PIL import Image
        if path.lower().endswith('.pdf'):
            import pypdfium2
            pdf = pypdfium2.PdfDocument(path)
            pg = pdf[max(0, int(page or 1) - 1)]
            w, h = pg.get_size()
            im = pg.render(scale=max_px / max(w, h)).to_pil()
            pdf.close()
        else:
            im = Image.open(path)
        im = im.convert('RGB')
        im.thumbnail((max_px, max_px))
        buf = io.BytesIO()
        im.save(buf, 'PNG')
        return 'data:image/png;base64,' + base64.b64encode(buf.getvalue()).decode()

    def ask_vision(self, image_paths, prompt, max_tokens=3000, page=None):
        """one question with pictures to the running model -> its answer text"""
        llm = getattr(self, 'llm', None)
        if llm is None:
            raise RuntimeError('no model is running to look at the picture (start ShipBrain with the model)')
        content = [{'type': 'image_url', 'image_url': {'url': self._image_url(p, page)}} for p in image_paths]
        content.append({'type': 'text', 'text': prompt})
        old = getattr(llm, 'max_tokens', None)
        try:
            if old is not None:
                llm.max_tokens = max_tokens
            return ''.join(llm.stream([{'role': 'user', 'content': content}]))
        except Exception as e:
            if 'image' in str(e).lower() or '400' in str(e) or '500' in str(e):
                raise RuntimeError('the running model cannot see pictures: start ShipBrain with the vision model and its '
                                   'image part (the shipbrain-mmproj-*.gguf file next to the model)') from e
            raise
        finally:
            if old is not None:
                llm.max_tokens = old

    def look(self, file, question='Describe this drawing: what it shows, the main items and their labels.', page=None):
        ans = _strip_think(self.ask_vision([self._path(file)], question, page=page)).strip()
        return {'answer': ans, 'plain_english': ans}

    def physics_lab(self, action, scenario=None, changes=None, query=None):
        from . import openphysics
        if action == 'list':
            sc = openphysics.scenarios(query)
            return {'scenarios': sc[:60], 'count': len(sc),
                    'plain_english': f"{len(sc)} example scenario(s)" + (f" for '{query}'" if query else '') + ': ' +
                                     '; '.join(f"{x['name']} ({x['domain']})" for x in sc[:25])}
        if action == 'get':
            d = openphysics.scenario(scenario)
            return {'scenario': d, 'plain_english': f"{scenario}: {d.get('title', '')} (domain {d.get('domain')})."}
        if action != 'run':
            raise ValueError('action: list | get | run')
        if not scenario:
            raise ValueError('run needs a scenario (example name or a scenario dict)')
        t0 = time.time()
        rec = openphysics.run(scenario, changes, out_dir=os.path.join(self.workdir, 'physics'))
        diag = rec.get('diagnostics', {})
        last = {k: (v[-1] if isinstance(v, list) and v and not isinstance(v[-1], (list, dict)) else v) for k, v in diag.items()
                if not isinstance(v, (dict,)) and not (isinstance(v, list) and v and isinstance(v[-1], (list, dict)))}
        shown = ', '.join(f'{k} = {v}' for k, v in list(last.items())[:10])
        files = [os.path.relpath(p, self.workdir) for p in (rec.get('result'), rec.get('scenario_file')) if p and os.path.exists(p)]
        return {'domain': rec.get('domain'), 'diagnostics': diag, 'report': rec.get('report', '')[-1500:], 'files': files,
                'wall_s': rec.get('wall_s'),
                'plain_english': f"Ran {scenario if isinstance(scenario, str) else 'the scenario'} ({rec.get('domain')}) with "
                                 f"OpenPhysicsAI in {time.time() - t0:.1f} s. Results (last step): {shown}."}

    def mcp_tools(self, server='openphysics', query=None):
        from . import mcp_client
        ts = mcp_client.client(server, self.workdir).tools()
        if query:
            ts = [t for t in ts if any(w in (t['name'] + ' ' + t.get('description', '')).lower() for w in query.lower().split())]
        return {'server': server, 'tools': [{'name': t['name'], 'description': t.get('description', '')[:200],
                                             'arguments': list((t.get('inputSchema') or {}).get('properties', {}))} for t in ts[:40]],
                'count': len(ts), 'plain_english': f"{len(ts)} operation(s) on {server}: " + ', '.join(t['name'] for t in ts[:40])}

    def mcp_call(self, tool, arguments=None, server='openphysics'):
        from . import mcp_client
        r = mcp_client.client(server, self.workdir).call(tool, arguments or {})
        if r['is_error']:
            raise RuntimeError(f'{server}.{tool}: ' + json.dumps(r['result'], default=str)[:1500])
        return {'result': r['result'], 'plain_english': f'{server}.{tool} done.'}     # the agent shortens it for the model

    def stl_to_step(self, file, unit='mm'):
        import collections
        from . import brep
        import cadquery as cq
        step, report = brep.stl_to_step(self._path(file), unit=unit)
        s = cq.importers.importStep(step).val()
        kinds = collections.Counter(f.geomType() for f in s.Faces())
        out = os.path.relpath(step, self.workdir)
        return {'file': out, 'solids': len(s.Solids()), 'faces': dict(kinds), 'volume_mm3': round(s.Volume(), 1), 'valid': s.isValid(),
                'report': report[-1500:],
                'plain_english': f"Converted {file} to {out}: {len(s.Solids())} solid(s), {len(s.Faces())} faces ("
                                 + ', '.join(f'{v} {k.lower()}' for k, v in kinds.most_common()) + f"), volume {s.Volume():.0f} mm3, "
                                 f"valid: {'yes' if s.isValid() else 'NO'}."}

    def native_cad(self, file, op='convert', to='step', other=None, density=None):
        r = self._native_cad(file, op, to, other, density)
        w = os.path.abspath(self.workdir)                  # results name files as the user sees them, never local folders
        return json.loads(json.dumps(r).replace(w + os.sep, '').replace(w, '.'))

    def _native_cad(self, file, op, to, other, density):
        from . import cadmpeg
        src = self._path(file)
        if op == 'convert' and src.lower().endswith('.3dm') and not str(to).lower().startswith('ig'):
            from . import rhino                         # Rhino: exact NURBS with McNeel's rhino3dm, layers and blocks kept
            try:
                r = rhino.to_step(src)
                r['file'] = os.path.relpath(r['file'], self.workdir)
                return r
            except RuntimeError:
                pass                                    # rhino3dm missing: cadmpeg below
        if op == 'convert':
            out = os.path.splitext(src)[0] + ('.igs' if str(to).lower().startswith('ig') else '.step')
            if os.path.abspath(out) == os.path.abspath(src):
                out = os.path.splitext(src)[0] + '_cadmpeg' + os.path.splitext(out)[1]
            r = cadmpeg.to_step(src, out)
            r['file'] = os.path.relpath(r['file'], self.workdir)
            return r
        if op == 'inspect':
            return cadmpeg.inspect(src)
        if op == 'check':
            return cadmpeg.check(src)
        if op == 'measure':
            return cadmpeg.measure(src, density=density)
        if op == 'diff':
            if not other:
                raise ValueError('diff needs other=<second file>')
            return cadmpeg.diff(src, self._path(other))
        raise ValueError('op: convert | inspect | check | measure | diff')

    def nx_open(self, op, query=None, name=None, calls=None, part=None, out=None):
        from . import nxopen
        if op == 'find':
            hits = nxopen.find(query or name or '')
            return {'functions': hits, 'plain_english': (f"{len(hits)} nxopentse functions match: " + '; '.join(
                f"{h['call']} - {h['what']}" for h in hits[:6])) if hits else 'No nxopentse function matches; say so.'}
        if op == 'syntax':
            return nxopen.syntax(name or query)
        if op == 'journal':
            out = re.sub(r'[^A-Za-z0-9_.\-]', '_', out or 'shipbrain_journal.py')
            path = nxopen.journal(calls or [], part=part, out=self._path(out))
            r = nxopen.run(path, self._path(part) if part and os.path.exists(self._path(part)) else part)
            text = open(path, encoding='utf-8').read()
            body = text[text.index('def main'):] if 'def main' in text else text
            return {'journal': out, 'ran': r['ran'], 'output': r.get('output'), 'code': body[:4000],
                    'plain_english': f"Wrote the NX Open journal {out} ({len(calls or [])} step(s)). " + r['plain_english']}
        raise ValueError('op: find | syntax | journal')

    def nx_rename(self, file, new_name):
        from . import nxopen
        r = nxopen.rename(self._path(file), new_name)
        r['file'] = os.path.relpath(r['file'], self.workdir)
        return r

    def mooring(self, depth, length, radius, d_mm=84, grade='R3', kind='studless', fairlead_z=0.0, current=None,
                condition='intact'):
        from . import cabledyn
        name = f'mooring_{int(depth)}m_{int(length)}m'
        r = cabledyn.mooring(depth, length, radius, d_mm=d_mm, grade=grade, kind=kind, fairlead_z=fairlead_z, current=current,
                             condition=condition, workdir=self.workdir, name=name)
        w = os.path.abspath(self.workdir)
        return json.loads(json.dumps(r).replace(w + os.sep, '').replace(w, '.'))

    def cable_run(self, deck):
        from . import cabledyn
        r = cabledyn.run(self._path(deck))
        r.pop('static_profile', None)
        last, mx = r.get('last', {}), r.get('max', {})
        ten = {k: v for k, v in (mx or last).items() if 'Ten' in k}
        r['plain_english'] = (f"CableDyn ran {os.path.basename(deck)} ({r['steps']} output step(s)). "
                              + ('; '.join(f"{'max ' if mx else ''}{k} = {v / 1e3:,.1f} kN" for k, v in ten.items())
                                 or 'Channels: ' + ', '.join(r['channels'][1:12])) + '.')
        w = os.path.abspath(self.workdir)
        return json.loads(json.dumps(r).replace(w + os.sep, '').replace(w, '.'))

    def topology(self, L, H, nx=None, ny=None, fixed=('left',), load_at=None, force=(0.0, -1000.0), volfrac=0.5, iters=40,
                 E=206000.0, name='topology'):
        from . import tensorfem
        nx = int(nx or max(20, min(120, round(60 * L / max(L, H)))))
        ny = int(ny or max(10, min(120, round(nx * H / L))))
        png = re.sub(r'[^A-Za-z0-9_\-]', '_', name)[:40] + '.png'
        r = tensorfem.topology(L, H, nx, ny, fixed=tuple(fixed), load_at=load_at, force=tuple(force), volfrac=volfrac,
                               iters=int(iters), E=E, png=self._path(png))
        r['png'] = png
        r.pop('density', None)
        r['history'] = r['history'][::max(1, len(r['history']) // 10)]
        return r

    def tensor_fem(self, file, fixed, loads, E=206000.0, nu=0.3):
        from . import tensorfem
        return tensorfem.solid_static(self._path(file), fixed, loads, E=E, nu=nu)

    def moose_plate(self, a, b, t, q, E=206000.0, nu=0.3, clamped=False):
        from . import moose
        r = moose.plate(a, b, t, q, E=E, nu=nu, clamped=clamped, workdir=self.workdir, name=f'moose_plate_{int(a)}x{int(b)}x{t:g}')
        r['input'], r['mesh'] = os.path.basename(r['input']), os.path.basename(r['mesh'])
        return r

    def moose_run(self, input):
        from . import moose
        r = moose.run(self._path(input))
        pp = r.get('postprocessors', {})
        r['plain_english'] = (f"MOOSE ran {os.path.basename(input)}" + (': ' + ', '.join(f'{k} = {v:.5g}' for k, v in pp.items() if k != 'time')
                                                                       if pp else ' (no postprocessor CSV: add [Outputs] csv = true)') + '.')
        return r

    def trace_drawing(self, file, page=0, scale=None, dpi=200):
        from . import vectorize
        r = vectorize.trace(self._path(file), page=int(page), scale=scale, dpi=dpi)
        r['svg'], r['dxf'] = os.path.basename(r['svg']), os.path.basename(r['dxf'])
        return r

    def pipe_flow(self, flow_m3h, segments, branches=None, fluid='seawater', density=None, viscosity_cst=None, pump_efficiency=0.7):
        from . import pipeflow
        return pipeflow.line(flow_m3h, segments, fluid=fluid, density=density, viscosity_cst=viscosity_cst,
                             pump_efficiency=pump_efficiency, branches=branches)

    def reverse_cad(self, file, material=None, heatmap=False):
        from . import reversecad
        src = self._path(file)
        out_dir = os.path.join(self.workdir, os.path.splitext(os.path.basename(file))[0] + '_reversecad')
        r = reversecad.convert(src, out_dir, emit='step,summary,report' + (',heatmap' if heatmap else ''), material=material)
        r['files'] = {k: os.path.relpath(v, self.workdir) for k, v in r['files'].items()}
        return r

    def geometry_clean(self, plates=None, file=None, merge_tol=2.0):
        from . import geoclean
        if file:
            from .cadplates import import_cad
            import cadquery as cq
            shp, act = geoclean.clean_shape(import_cad(self._path(file)))
            out = os.path.splitext(os.path.basename(file))[0] + '_clean.step'
            cq.exporters.export(cq.Workplane().add(shp), self._path(out))
            return {'file': out, 'actions': act}
        clean, act = geoclean.clean_plates(plates or [], merge_tol=merge_tol)
        return {'plates': clean, 'actions': act}

    def fatigue_mesh(self, plates, hotspot, size=None, t=None, loads=None, solve=False, name='hotspot'):
        from . import fatigue
        m, info = fatigue.fatigue_mesh(plates, hotspot, size, t, self.workdir, re.sub(r'[^A-Za-z0-9_\-]', '_', name)[:40], loads)
        out = self._mesh_result(m, info)
        if solve:
            r = _solver.run_calculix(os.path.join(self.workdir, out['files']['inp']))
            out['hot_spot'] = fatigue.hotspot_stress(r['frd'], info['readout_points'])
        return out

    def compare_drawings(self, a, b, page_a=0, page_b=0, ignore=None, ignore_layers=None, tolerance=None):
        from . import drawings
        from .dwg import drawing_file
        base = os.path.join(self.workdir, f'compare_{os.path.splitext(os.path.basename(a))[0]}_vs_{os.path.splitext(os.path.basename(b))[0]}')
        A, B = drawing_file(self._path(a)), drawing_file(self._path(b))          # DWG -> DXF with the free ODA converter
        r = drawings.compare_drawings(A, B, base + '.png', page_a, page_b)
        r['overlay'] = os.path.basename(base + '.png')
        try:                                                # vector drawings: also say WHAT changed, numbered, with clouds
            from .drawdiff import compare_full
            ign = [ignore] if isinstance(ignore, str) else ignore
            ilay = [ignore_layers] if isinstance(ignore_layers, str) else ignore_layers
            v = compare_full(A, B, page_a, page_b, tol=tolerance, ignore=ign or (), ignore_layers=ilay or (), out_base=base)
            if v['changes']:
                r['semantic'] = {k: v[k] for k in ('lines', 'texts', 'by_kind', 'clouds')}
                r['changes'] = v['changes'][:40]
                r['files'] = [os.path.basename(f) for f in v['files']]
                r['plain_english'] += ' ' + v['plain_english'] + (f" Open {os.path.basename(v['files'][0])} in AutoCAD: red = "
                                                                   'removed, green = added, yellow = changed, magenta clouds numbered as in '
                                                                   f"{os.path.basename(v['files'][1])}." if v['files'] else '')
        except Exception as ex:
            r['semantic'] = f'not available ({type(ex).__name__}: scanned drawing or unreadable vector content)'
        return r

    def compare_mesh_drawing(self, mesh, drawing, box, level=0.0, axis='z', page=0):
        from . import drawings
        out = os.path.join(self.workdir, f'mesh_vs_{os.path.splitext(os.path.basename(drawing))[0]}.png')
        r = drawings.compare_mesh_drawing(self._path(mesh), self._path(drawing), box, level, axis, out, page)
        r['overlay'] = os.path.basename(out)
        return r

    def drawing_to_3d(self, file, z=0.0, t_plate=12.0, layers=None, mesh=True, element_size=200.0):
        from . import drawings
        r = drawings.dxf_to_plates(self._path(file), z, t_plate, layers)
        base = os.path.splitext(os.path.basename(file))[0]
        out = {'report': r['report'], 'plates': len(r['plates']), 'beams': len(r['beams'])}
        try:
            out['step'] = os.path.basename(drawings.plates_to_step(r['plates'], self._path(base + '_3d.step'), r['beams'])['step'])
        except ImportError:
            out['step'] = 'not written (CadQuery not installed)'
        json.dump({'plates': r['plates'], 'beams': r['beams']}, open(self._path(base + '_plates.json'), 'w'), indent=1)
        out['spec'] = base + '_plates.json'
        if mesh:
            out['mesh'] = self.plates_mesh(r['plates'], base + '_mesh', element_size, beams=r['beams'])
        return out

    def drawing_check(self, file, page=0):
        from .drawdiff import check_dimensions
        fix = self.t.get('ocr_fix')                      # ship plugin: repair misread labels before checking numbers
        return check_dimensions(self._path(file), int(page), fix=(lambda t: fix[0](t).get('text', t)) if fix else None)

    def load_ship_tools(self):
        """the built-in ship tools (shiptools/): rule search, member checks, XML read/write, OCR label fixes ..."""
        d = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'shiptools')
        return self.load_plugin(d) if os.path.exists(os.path.join(d, 'ship_mcp.py')) else 0

    def cad_view_check(self, model, drawing, views=('front',), page=0, crops=None):
        from .cadview import compare_view
        out, crops = [], crops or {}
        for v in views:
            png = os.path.join(self.workdir, f'view_{os.path.splitext(os.path.basename(model))[0]}_{v}.png')
            r = compare_view(self._path(model), self._path(drawing), v, int(page), crops.get(v), png)
            r['overlay'] = os.path.basename(png)
            out.append(r)
        worst = min(out, key=lambda r: r['score'])
        return {'views': out, 'verdict': worst['verdict'] if all(r['verdict'] != 'FAIL' for r in out) else 'FAIL',
                'overlay': worst['overlay'], 'plain_english': ' '.join(r['plain_english'] for r in out)}

    def class_rule(self, action, query=None, society=None, L=None, B=None, Cb=None, Ms_hog=None, Ms_sag=None, yield_mpa=235, x=0.5,
                   Z_deck=None, Z_bottom=None, I=None):
        from . import classrules
        if action == 'longitudinal':
            if not (L and B and Cb):
                return {'error': 'longitudinal needs L, B (m) and Cb'}
            return classrules.ur_s11(float(L), float(B), float(Cb), Ms_hog, Ms_sag, float(yield_mpa or 235), float(x or 0.5), Z_deck, Z_bottom, I)
        if action == 'k':
            k = classrules.k_factor(float(yield_mpa or 235))
            return {'k': round(k, 3), 'plain_english': f'The material factor k for steel with a minimum yield stress of {float(yield_mpa or 235):g} '
                                                        f'N/mm2 is {k:.2f} (IACS UR S4); scantling formulas multiply by k or use 235/k.'}
        packs = [p_ for p_ in (getattr(self.repo_kb, 'packs', None) or []) if str(p_.get('name', '') if isinstance(p_, dict) else p_).startswith('class_rules_')]
        names = sorted({(p_.get('name') if isinstance(p_, dict) else str(p_)).replace('class_rules_', '') for p_ in packs})
        how = ('Get the rule books once: python -m shipbrain.classrules download --out <folder> (free rule pages of IACS, DNV, ABS, '
               'BV, LR, ClassNK, KR, CCS, RINA, IRS, PRS, CRS, TL; some need a free login - save those PDFs into <folder>/<society>), '
               'then python -m shipbrain.classrules build --pdfs <folder> and restart ShipBrain.')
        if action == 'societies':
            allsoc = [s_[0] for s_ in classrules.SOURCES]
            return {'installed': names, 'known': allsoc, 'plain_english': (f"Rule books on this PC: {', '.join(names)}. " if names else
                                                                            'No class rule books on this PC yet. ') + how}
        if not query:
            return {'error': 'search needs a query'}
        if not names:
            return {'results': [], 'plain_english': 'No class rule books are loaded yet, so I cannot quote the rules. ' + how}
        scope = 'class_rules_' + society if society and society.upper() in [n.upper() for n in names] else 'class_rules_'
        res = self.knowledge_search(query, 5, scope=scope)
        hits = res.get('results', [])
        if not hits:
            return {'results': [], 'plain_english': f"Nothing about '{query}' found in the {society or 'class'} rules on this PC."}
        top = hits[0]
        return {'results': hits, 'plain_english': f"The closest rule text is {top['title']}: " + re.sub(r'\s+', ' ', top['text'])[:600]
                + ' ...' + (f" Also see: {'; '.join(h['title'] for h in hits[1:4])}." if len(hits) > 1 else '')}

    def drawing_to_step(self, file, refinements=2, out=None):
        from . import cad3dify
        llm = getattr(self, 'llm', None)
        if llm is None or not getattr(llm, 'base', None):
            return {'error': 'drawing_to_step needs the ShipBrain model running (start the app with --model or --url)'}
        out = out or os.path.splitext(os.path.basename(file))[0] + '.step'
        r = cad3dify.run(self._path(file), self._path(out), llm.base, refinements, model=getattr(llm, 'model', 'local'),
                         api_key=getattr(llm, 'key', None))
        import cadquery as cq
        s = cq.importers.importStep(r['step']).val()
        bb = s.BoundingBox()
        return {'step': os.path.basename(r['step']), 'rounds': r['rounds'], 'volume_mm3': round(s.Volume(), 1),
                'size_mm': [round(bb.xlen, 1), round(bb.ylen, 1), round(bb.zlen, 1)],
                'plain_english': f"Made {os.path.basename(r['step'])} from the drawing in {r['rounds']} round(s) (cad3dify): "
                                 f"{bb.xlen:.0f} x {bb.ylen:.0f} x {bb.zlen:.0f} mm, volume {s.Volume() / 1000:.1f} cm3. "
                                 'Check it against the drawing (cad_view_check) before use.'}

    def drawing_takeoff(self, file, min_confidence=0.0):
        from . import construct
        return construct.takeoff(self._path(file), min_confidence)

    def bolt(self, d, cls='8.8', mu_G=0.12, mu_K=None, pitch=None, method='torque wrench', F_A=None, Phi=0.2, F_Kerf=None,
             thread=None, nut_factor=None, c=None):
        from . import bolts
        if isinstance(d, str) and (d.strip().replace('"', '') in bolts.INCH or thread):
            return bolts.inch_joint(d, thread or 'UNC', cls if cls != '8.8' else '5', float(c or 0.75), float(nut_factor or 0.20),
                                    F_ext_lbf=F_A)
        return bolts.joint(float(d), str(cls), float(mu_G), float(mu_K if mu_K is not None else mu_G), pitch=pitch, method=method,
                           F_A=F_A, Phi=float(Phi or 0.2), F_Kerf=F_Kerf)

    def parse_document(self, file, ocr=False, pages=None):
        try:
            import liteparse
        except ImportError:
            raise ModuleNotFoundError("No module named 'liteparse'")
        src = self._path(file)
        kw = dict(output_format='markdown', ocr_enabled=bool(ocr), quiet=True, include_complexity=True)
        if pages:
            kw['target_pages'] = str(pages)
        try:
            r = liteparse.LiteParse(**kw).parse(src)
        except Exception as e:
            if 'tessdata' in str(e):
                return {'error': 'OCR needs its language data from the internet once (Tesseract eng.traineddata); try again online, '
                                 'or read without ocr'}
            if 'LibreOffice' in str(e) or 'soffice' in str(e):
                return {'error': 'Word / Excel / PowerPoint files need LibreOffice (free, https://www.libreoffice.org/download/) '
                                 'to be converted first'}
            raise
        md = '\n\n'.join(f'<!-- page {i} -->\n' + re.sub(r'!\[[^\]]*\]\([^)]*\)\s*', '', pg.markdown or '').strip()
                         for i, pg in enumerate(r.pages, 1))
        out = os.path.splitext(os.path.basename(file))[0] + '.md'
        open(self._path(out), 'w', encoding='utf-8').write(md)
        need = [pg.page_num if hasattr(pg, 'page_num') else i for i, pg in enumerate(r.pages, 1)
                if getattr(getattr(pg, 'complexity', None), 'needs_ocr', False)]
        tables = md.count('\n|---') + md.count('\n| ---')
        heads = [ln.lstrip('# ').strip() for ln in md.splitlines() if re.match(r'#{1,3} ', ln)][:8]
        pe = (f"Read {os.path.basename(file)}: {len(r.pages)} page(s) -> {out} ({len(md):,} characters"
              + (f', {tables} table(s)' if tables else '') + ')' + (f"; headings: {'; '.join(heads)}" if heads else '') + '.'
              + (f" Pages {', '.join(map(str, need[:15]))} look scanned or mostly pictures"
                 + (' and were read with OCR.' if ocr else ': ask again with ocr=true to read them.') if need else ''))
        return {'markdown_file': out, 'pages': len(r.pages), 'needs_ocr_pages': need, 'tables': tables,
                'preview': md[:1500], 'plain_english': pe}

    def serving_sim(self, action='simulate', users=50, rate_per_s=2.0, input_tokens=600, output_tokens=300, scenario=None):
        from . import serving
        if action == 'scenarios':
            sc = serving.scenarios()
            return {'scenarios': sc, 'plain_english': 'Measured set-ups (GPU--model--workload): ' + ', '.join(sc) + '.'}
        return serving.simulate(scenario, None, int(users or 50), float(rate_per_s or 2), int(input_tokens or 600), int(output_tokens or 300))

    def process_sim(self, action, file=None, compounds=None, mass_fractions=None, T_C=None, P_bar=None, flow_kg_h=1000.0,
                    package='Peng-Robinson (PR)'):
        from . import dwsim
        if action == 'run':
            if not file:
                return {'error': 'run needs a DWSIM flowsheet file'}
            return dwsim.run(self._path(file))
        if action == 'packages':
            fid = dwsim._call('dwsim_flowsheet_create', {'name': 'list'})['flowsheet_id']
            pp = dwsim._call('dwsim_thermo_list_property_packages', {'flowsheet_id': fid}).get('property_packages', [])
            dwsim._call('dwsim_flowsheet_close', {'flowsheet_id': fid})
            return {'packages': pp, 'plain_english': f"DWSIM has {len(pp)} property packages, e.g. {', '.join(pp[:12])}."}
        if not (compounds and mass_fractions and T_C is not None and P_bar is not None):
            return {'error': 'flash needs compounds, mass_fractions, T_C and P_bar'}
        return dwsim.flash(compounds, mass_fractions, float(T_C), float(P_bar), float(flow_kg_h or 1000), package or 'Peng-Robinson (PR)')

    def dexpi(self, action, file, other=None, format='xlsx'):
        from . import dexpi as dx
        src = self._path(file)
        base = os.path.splitext(os.path.basename(file))[0]
        if action == 'summary':
            return dx.summary(src)
        if action == 'validate':
            return dx.validate(src)
        if action == 'tables':
            r = dx.tables(src, self._path(base + '_lists'), fmt=format if format in ('xlsx', 'csv', 'json') else 'xlsx')
            r['files'] = [os.path.basename(f) for f in r['files']]
            return r
        if action == 'drawing':
            png = dx.png(src, self._path(base + '.png'), scale=3.0)
            return {'png': os.path.basename(png), 'svg': base + '.svg', 'overlay': os.path.basename(png),
                    'plain_english': f'Drew the P&ID: {os.path.basename(png)} (and {base}.svg).'}
        if action == 'diff':
            if not other:
                return {'error': 'diff needs other (the second revision)'}
            return dx.diff(src, self._path(other))
        return {'error': f'unknown action {action}'}

    def drawing_detect(self, file, discipline='electrical', min_confidence=0.25):
        from . import construct
        src = self._path(file)
        if src.lower().endswith('.pdf'):
            from .drawings import load_image
            from PIL import Image
            png = os.path.splitext(src)[0] + '_page1.png'
            Image.fromarray(load_image(src, 0, dpi=150).clip(0, 255).astype('uint8')).convert('RGB').save(png)
            src = png
        t = construct.detect(src, discipline, float(min_confidence))
        items = '; '.join(f"{ln['item']} {ln['qty']}" for ln in t['lines'][:15])
        return {'cir': os.path.basename(t['cir']), 'total': t['total_count'], 'lines': t['lines'],
                'plain_english': f"Found {t['total_count']} symbols on the drawing: {items or 'none'}. "
                                 + (f"{t['total_needs_review']} of them are uncertain (below confidence 0.5) - please check those. " if t['total_needs_review'] else '')
                                 + f"Saved as {os.path.basename(t['cir'])}: ask drawing_takeoff or drawing_qa about it."}

    def drawing_qa(self, file, question=None, action='qa'):
        from . import construct
        if action == 'rfi':
            return construct.rfi(self._path(file))
        if not question:
            i = construct.info(self._path(file))
            return {'sheets': i['sheets'], 'plain_english': 'Sheets: ' + '; '.join(f"{x['number']} {x['title'] or ''} ({x['discipline']}, "
                                                                                 f"{x['entities']} items)" for x in i['sheets']) + '.'}
        return construct.qa(self._path(file), question)

    def ocx_syntax(self, name=None, version=None, changes_from=None):
        from . import ocx
        if changes_from:
            return ocx.changes(changes_from, version or ocx.LATEST)
        if not name:
            vs = ocx.versions()
            return {'versions': vs, 'plain_english': f"OCX schema versions I know: {', '.join(vs)} (newest {vs[-1]}). Ask for any "
                                                     f"element, e.g. Plate, Stiffener, BarSection."}
        out = ocx.syntax(name, version)
        if 'error' in out:
            hits = ocx.find(name, version)
            return {'matches': hits, 'plain_english': f"OCX {ocx._resolve(version)} classes for '{name}': "
                                                      + '; '.join(f"{h['name']} ({h['doc'][:80]})" for h in hits[:8])}
        return out

    def ocx_read(self, file):
        from . import ocx
        r = ocx.read(self._path(file))
        base = re.sub(r'[^A-Za-z0-9_\-]', '_', os.path.splitext(os.path.basename(file))[0])[:40]
        out = self._path(base + '_structure.json')
        json.dump(r['model'], open(out, 'w', encoding='utf-8'))
        return {'summary': r['summary'], 'structure_json': os.path.basename(out),
                'plain_english': r['plain_english'] + f' Saved as {os.path.basename(out)} for comparing and meshing.'}

    def ocx_query(self, file, name=None, kind=None, function=None, min_thk=None, max_thk=None):
        from . import ocx
        return ocx.query(self._path(file), name, kind, function, min_thk, max_thk)

    def ocx_validate(self, file):
        from . import ocx
        return ocx.validate(self._path(file))

    def ocx_write(self, file, out=None, name=None):
        from . import ocx, members
        model = members.load(self._path(file), self.converters)
        out = out or os.path.splitext(os.path.basename(file))[0] + '.3docx'
        res = ocx.write(model, self._path(out), name=name or 'ShipBrain model')
        v = ocx.validate(self._path(out))
        res.update(file=os.path.basename(out), valid=v['valid'], problems=v['errors'][:5],
                   plain_english=f"Wrote {os.path.basename(out)} (OCX {res['version']}): {res['panels']} panels, {res['plates']} plates, "
                                 f"{res['stiffeners']} stiffeners, {res['sections']} sections, {res['materials']} materials. " + v['plain_english'])
        return res

    def ocx_to_step(self, file):
        from . import ocx
        r = ocx.to_step(self._path(file))
        return {'step': os.path.basename(r['step']), 'by': r['by'],
                'plain_english': f"STEP written: {os.path.basename(r['step'])} (made by {r['by']})." + (f" {r['note']}." if r.get('note') else '')}

    def compare_structures(self, a, b, tol=None, move_tol=300.0, method='coverage'):
        """coverage (default): stiffener length / plate area found in the other model - works when the two models split
        members differently (drawing-read vs yard model). members: one-to-one member matching (two versions of ONE model)."""
        from . import members
        A, B = members.load(self._path(a), self.converters), members.load(self._path(b), self.converters)
        if method == 'members':
            return members.compare(A, B, tol or 5.0, move_tol)
        return members.coverage(A, B, tol or 50.0)

    def build_structure(self, program, name='structure', element_size=None, step=False):
        from . import shipprog
        name = re.sub(r'[^A-Za-z0-9_\-]', '_', str(name))[:40]
        spec, desc = shipprog.build(program, name, element_size)
        out = self.plates_mesh(spec['plates'], name, spec['element_size'], spec['loads'], spec['fix'], beams=spec['beams'])
        if step and 'error' not in out:
            from .drawings import plates_to_step
            out['step'] = os.path.basename(plates_to_step(spec['plates'], self._path(name + '.step'), spec['beams'])['step'])
        c = out.get('check', {})
        out['plain_english'] = (f"Built {desc}. Mesh: {out.get('nodes')} nodes, {out.get('elements')} elements "
                                f"({out.get('quads')} shells, {out.get('bars')} beams), {c.get('parts')} connected piece(s); "
                                f"check: {c.get('verdict')}.")
        return out

    def choose_engine(self, question):
        from . import engines, installs
        out = engines.choose(question)
        for p in out['plan']:
            best = p['engines'][0] if p['engines'] else None
            if best and not best['installed']:
                i = installs.for_engine(best['engine'])
                if i:
                    i['message'] = installs.message(i)
                    out.setdefault('install', i)
                    out['plain_english'] += f" To run it here, install {i['name']}: {i['link']}"
        return out

    def setup_check(self, only_missing=False):
        from . import installs
        return installs.setup_check(only_missing)

    def find_solvers(self):
        from . import solvers
        f = solvers.find()
        txt = ('Solvers on this PC: ' + '; '.join(f"{x['solver']} ({x['path']})" for x in f) + '.') if f else \
              'No solver was found on this PC. Tell me where one is installed (remember_solver), or install CalculiX (free).'
        return {'solvers': f, 'plain_english': txt}

    def remember_solver(self, name, path):
        from . import solvers
        return solvers.remember(name, path)

    def solve(self, file, solver, analysis='static', n_modes=10):
        from . import solvers
        r = solvers.run(self._path(file), solver.lower(), analysis, int(n_modes))
        for k in ('frd', 'f06'):
            if k in r:
                r[k] = os.path.basename(r[k])
        return r

    def analysis_run(self, file, analysis='static', n_modes=10):
        r = _solver.run_analysis(self._path(file), analysis, int(n_modes))
        if 'frd' in r:
            r['frd'] = os.path.basename(r['frd'])
        return r

    def drawing_to_model(self, file, settings=None, reference=None, pages=None, raster=False):
        """ship drawing (PDF) -> member model XML with the ship drawing reader (its rules + calibration); optional coverage
        score against a reference XML. Takes minutes for a full drawing."""
        import subprocess, glob as _g
        d = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'shiptools', 'deckrules_tool')
        out = os.path.join(self.workdir, os.path.splitext(os.path.basename(file))[0] + '_read')
        cmd = [sys.executable, '-m', 'deckrules.build_ship', self._path(file), '--out', out, '--no-verify',
               '--settings', self._path(settings) if settings else os.path.join(d, 'settings_new_drawing.json')]
        if pages:
            cmd += ['--pages', str(pages)]
        if raster:
            cmd.append('--raster')
        r = subprocess.run(cmd, cwd=d, capture_output=True, text=True, timeout=7200)
        xmls = sorted(_g.glob(os.path.join(out, '*_moulded.xml')), key=os.path.getsize)
        if not xmls:
            raise RuntimeError('the drawing reader made no model: ' + (r.stderr or r.stdout)[-600:])
        questions = [l[10:] for l in r.stdout.splitlines() if l.startswith('QUESTION:')]
        res = {'model_xml': os.path.relpath(xmls[-1], self.workdir), 'report': os.path.relpath(os.path.join(out, 'BUILD_REPORT.md'), self.workdir),
               'open_questions': questions[:30],
               'plain_english': f'Read the drawing into a member model ({os.path.basename(xmls[-1])}). The reader left '
                                f'{len(questions)} open question(s) for an engineer instead of guessing.'}
        if reference:
            c = self.compare_structures(reference, res['model_xml'])
            res['vs_reference'] = c
            res['plain_english'] += ' Against the reference (A = reference, B = from the drawing): ' + c['plain_english']
        return res

    def structure_to_mesh(self, file, element_size=300.0, merge_tol=10.0, step=False):
        from . import members, geoclean
        r = members.to_plates(members.load(self._path(file), self.converters))
        base = os.path.splitext(os.path.basename(file))[0]
        json.dump(r, open(self._path(base + '_plates.json'), 'w'))
        plates, act = geoclean.clean_plates(r['plates'], merge_tol=merge_tol)
        spec = {'name': base + '_fem', 'plates': plates, 'beams': r['beams'], 'element_size': element_size}
        out = self._mesh_result(*_pm.build_plates(spec, self.workdir))
        out['cleaning'] = act[:30] + ([f'... and {len(act) - 30} more'] if len(act) > 30 else [])
        out['notes'] = r['notes']
        if step:
            from .drawings import plates_to_step
            out['step'] = os.path.basename(plates_to_step(plates, self._path(base + '.step'), r['beams'])['step'])
        c = out['check']
        out['plain_english'] = (f"Made a global mesh of {base}: {out['nodes']} nodes, {out['elements']} elements "
                                f"({out['quads']} shells, {out['bars']} beams). {c['parts']} connected piece(s)"
                                + (f", the largest has {c['part_sizes'][0]} elements" if c['parts'] > 1 else '') + '. '
                                + ('Mesh check: ok.' if c['verdict'] == 'ok' else 'Mesh check found: ' + c['verdict'] + '.'))
        return out

    def mesh_check(self, file):
        return _mc.check_file(self._path(file))

    def fe_quality(self, file, criteria=None, mesh_size=None):
        from . import elemquality
        r = elemquality.check_file(self._path(file), criteria, mesh_size)
        if r.get('failed_sets_file'):
            r['failed_sets_file'] = os.path.basename(r['failed_sets_file'])
        r['quality'].pop('failed_ids', None)
        return r

    def solve_calculix(self, inp):
        r = _solver.run_calculix(self._path(inp))
        r['frd'] = os.path.basename(r['frd'])
        return r

    def list_files(self):
        return {'files': sorted(f for f in os.listdir(self.workdir) if not f.startswith('.'))}

    def cadquery_build(self, code, name='part', expect=None):
        from . import cadrun
        name = re.sub(r'[^A-Za-z0-9_\-]', '_', name)[:40]
        return cadrun.run(code, self.workdir, name, expect)

    # ------------------------------------------------------------------ plugins (e.g. your private ship_mcp.py)
    def load_plugin(self, path):
        """a Python file (or folder with ship_mcp.py) exposing TOOLS = {name: (fn, description, schema)}"""
        if os.path.isdir(path):
            path = os.path.join(path, 'ship_mcp.py')
        sys.path.insert(0, os.path.dirname(os.path.abspath(path)))
        spec = importlib.util.spec_from_file_location(os.path.splitext(os.path.basename(path))[0], path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        n = 0
        conv = getattr(mod, 'xml_to_members', None)
        if conv is None:                                  # plugin folder that also holds an XML kit module
            for cand in ('ship_xml_kit',):
                if os.path.exists(os.path.join(os.path.dirname(os.path.abspath(path)), cand + '.py')):
                    try:
                        conv = getattr(importlib.import_module(cand), 'xml_to_members', None)
                    except Exception:
                        conv = None
        if conv:
            self.converters.append(conv)
        if not hasattr(self, 'hooks'):
            self.hooks = {}
        for ev, fn in getattr(mod, 'HOOKS', {}).items():            # question | tool_result | compact
            self.hooks.setdefault(ev, []).append(fn)
        for name, (fn, desc, schema) in getattr(mod, 'TOOLS', {}).items():
            if name not in self.t:
                self.register(name, fn, desc, schema)
                n += 1
        return n

    # ------------------------------------------------------------------ dispatch
    def call(self, name, args):
        if name not in self.t:
            return {'error': f'unknown tool {name}; tools: {", ".join(self.t)}'}
        fn = self.t[name][0]
        try:
            args = args if isinstance(args, dict) else json.loads(args or '{}')
            res = fn(**args)
        except Exception as e:
            res = {'error': f'{type(e).__name__}: {e}'}
        from . import installs                               # missing program / package -> what to install + link
        return installs.attach(res)

    def describe(self):
        return '\n'.join(f'- {n}: {d}\n  args: {json.dumps(s.get("properties", {}), separators=(",", ":"))}'
                         for n, (_, d, s) in self.t.items())


# ====================================================================== prompt
SYSTEM = """You are ShipBrain, an engineering assistant for CAD, FE meshing, FEA, CFD set-up and drawings, for any field
(ships and offshore are a specialty). Tools work in mm, N, MPa, tonne (1 m sea-water head = 0.01005 MPa); if the user
works in other units (see the user profile or the question), convert with convert_units before and after the tools.

Rules:
0. Write in plain, simple words, in the user's language (English unless the profile or the question says otherwise): short sentences, everyday words, explain an engineering term the first time you use it,
   always give units. When a tool result has a "plain_english" text, use it. If the user asks about an uploaded file,
   call file_info first and explain what you found.
1. Numbers, meshes and files come from tools, never from memory. Use calc for arithmetic.
2. For rules, methods or yard practice, call knowledge_search first and cite the ids/sources you used.
3. To call a tool, reply with ONLY one block:
```tool
{{"name": "<tool>", "args": {{...}}}}
```
   You will get back a message starting with TOOL_RESULT. Then answer, or call the next tool.
4. If a needed value is missing, choose a sensible default, say which one you assumed, and continue.
5. Finish with a short answer: what was done, key numbers, files written, checks/warnings.
6. Answer every technical question in natural language: explain in sentences what the result means, give the value with
   units and where it comes from (the formula, the class society rule and section), then the numbers. Never answer with
   only JSON, code or a bare number unless the user asks for that.
7. Class rules and their formulas: use class_rule (calculators) or knowledge_search (the rule texts) and cite the rule
   and section; never quote a class rule from memory.
8. If a tool result has "install", something is not installed: tell the user what to install, why, and give the
   download link and the steps exactly as written there. Never guess another link.

Tools:
{tools}
"""


SYSTEM_COMPACT = """You are ShipBrain, an engineering assistant for CAD, meshing, FEA, CFD set-up and drawings (any field; ships a specialty).
Tools use mm, N, MPa; other units: convert_units in and out, answer in the user\'s units. Follow the user profile.
Write plain simple words (the user's language), explain terms, give units; use a result's plain_english text. Ask file_info first about uploaded files.
Numbers/meshes/files only from tools; use calc for arithmetic; cite [ids] of retrieved knowledge or memory.
Call a tool with ONLY:
```tool
{{"name": "<tool>", "args": {{...}}}}
```
then wait for TOOL_RESULT. Missing value: assume a sensible one and say so. End with a short answer: done, key numbers, files, warnings.
Result with "install": tell the user what to install and give its link and steps exactly as written.
Every technical answer in natural language: what it means in sentences, the result with units, where it comes from (formula,
class society rule + section), then the numbers. Never only JSON, code or a bare number unless asked.
Class rules / formulas: class_rule (calculators) or knowledge_search (rule texts); never quote a rule from memory.
Tools: {tools}
"""


def system_prompt(tools, compact=True):
    """compact (default): tool names + argument names only (~4x fewer tokens -> much faster first answer on a CPU);
    the fine-tuned model learns the details from the training data. compact=False: full descriptions (untrained models)."""
    if not compact:
        return SYSTEM.format(tools=tools.describe())
    items = []
    for n, (_, d, sch) in tools.t.items():
        req = set(sch.get('required', []))
        args = ','.join(k if k in req else k + '?' for k in sch.get('properties', {}))
        first = re.split(r'(?<=[.:])\s', d, 1)[0][:70].rstrip('.:')
        items.append(f'{n}({args}) {first}')
    return SYSTEM_COMPACT.format(tools='; '.join(items))


def compact_result(res, limit=2500):
    """shorter tool results for the model (CPU prompt time): lists cut to 12 items, floats rounded, total capped"""
    def c(x, depth=0):
        if isinstance(x, float):
            return float(f'{x:.5g}')
        if isinstance(x, dict):
            return {k: c(v, depth + 1) for k, v in x.items() if k not in ('xyz', 'edges')}
        if isinstance(x, (list, tuple)):
            out = [c(v, depth + 1) for v in x[:12]]
            if len(x) > 12:
                out.append(f'... {len(x) - 12} more')
            return out
        return x
    txt = json.dumps(c(res), default=str, separators=(',', ':'))
    return txt if len(txt) <= limit else txt[:limit] + '...(cut)'



def parse_tool_call(text):
    m = TOOL_RE.search(text or '')
    if not m:
        return None
    raw = m.group(1).strip()
    try:
        d = json.loads(raw)
    except json.JSONDecodeError:
        try:
            d = ast.literal_eval(raw)                         # small models sometimes write python dicts
        except Exception:
            return {'name': '__bad__', 'args': {}, 'raw': raw}
    if not isinstance(d, dict):
        return {'name': '__bad__', 'args': {}, 'raw': raw}
    return {'name': d.get('name') or d.get('tool'), 'args': d.get('args') or d.get('arguments') or {}}


# ====================================================================== LLM client (OpenAI-compatible)
class LLM:
    def __init__(self, base_url, model='local', temperature=0.2, max_tokens=1500, api_key=None, timeout=900):
        self.base = base_url.rstrip('/')
        if self.base.endswith('/v1'):
            self.base = self.base[:-3]
        self.model, self.temperature, self.max_tokens, self.key, self.timeout = model, temperature, max_tokens, api_key, timeout

    def _req(self, path, body=None):
        h = {'Content-Type': 'application/json'}
        if self.key:
            h['Authorization'] = 'Bearer ' + self.key
        return urllib.request.Request(self.base + path, data=json.dumps(body).encode() if body is not None else None, headers=h)

    def count_tokens(self, text):
        """exact number of tokens with the model's own tokenizer (llama-server /tokenize; raises if not supported)"""
        with urllib.request.urlopen(self._req('/tokenize', {'content': text}), timeout=20) as r:
            return len(json.loads(r.read())['tokens'])

    def ok(self):
        try:
            with urllib.request.urlopen(self._req('/v1/models'), timeout=3) as r:
                return r.status == 200
        except Exception:
            return False

    def stream(self, messages):
        """yield text pieces"""
        body = {'model': self.model, 'messages': messages, 'temperature': self.temperature, 'max_tokens': self.max_tokens, 'stream': True,
                'cache_prompt': True}          # llama.cpp: re-use the already-read system prompt (others ignore it)
        with urllib.request.urlopen(self._req('/v1/chat/completions', body), timeout=self.timeout) as r:
            for raw in r:
                line = raw.decode('utf-8', 'replace').strip()
                if not line.startswith('data:'):
                    continue
                data = line[5:].strip()
                if data == '[DONE]':
                    break
                try:
                    ch = json.loads(data)['choices'][0]
                except (ValueError, KeyError, IndexError):
                    continue
                piece = (ch.get('delta') or {}).get('content') or (ch.get('message') or {}).get('content')
                if piece:
                    yield piece


# ====================================================================== the loop
def pid_read_prompt(n, tags, example):
    """the one question used to read a P&ID sheet - at run time (pid_kg read) and in the training data (synth_pid)"""
    return (f'You read P&ID sheet (page {n}). Write ONE JSON object in exactly the format of the example: schema_version, page, '
            'sheet, equipment, components, instruments, lines (with from/to and the components in order), signals '
            '(from -> to, type, purpose), off_page_connectors, boundaries, unreadable. Record only what is drawn; give each item '
            'a bbox [x0, y0, x1, y1] as fractions of the sheet (0,0 = top left) and a confidence when unsure; never invent tags. '
            + (f'Tags found by text / OCR on this sheet: {tags}. ' if tags else '')
            + f'Example of the format (another plant):\n{example}\nAnswer with the JSON only. page = {n}.')


def _strip_think(t):
    return re.sub(r'<think>.*?</think>', '', t, flags=re.S)


CAD_WORDS = re.compile(r'\b(cad|cadquery|step|stl|solid|3d|3-d|part|extrude)\b|model of|make a model|3d model', re.I)


RAG_BUDGET_CHARS = 1800      # retrieved text per question (~500 tokens). On a CPU every retrieved token is READ before the
                             # first word (~20-60 tokens/s for a 4B model), so this budget is the main lever on waiting time


def retrieve(tools, question, k=3, min_score=3.0, budget=None):
    """RAG within a budget: the most personal and most reliable parts first, each cut to its share -
    profile, matching skill, the user's memory, one verified CAD example (CAD requests), rule book / notes, repo text"""
    budget = RAG_BUDGET_CHARS if budget is None else budget
    cands = []                                                  # (priority group, text, id, max chars)
    prof = getattr(tools, 'profile', None)
    if prof is not None and prof.context():
        cands.append((prof.context(), 'profile', 300))
    sk = getattr(tools, 'skills', None)
    if sk is not None:
        from .skills import context as _skill_ctx
        for x in sk.match(question, 1):
            cands.append((_skill_ctx(x), 'skill:' + x['name'], 700))
    if tools.memory is not None:
        for m in tools.memory.recall(question, 2):
            cands.append((f"[memory {m['id']}] (taught by the user) {m['text']}", 'memory:' + m['id'], 300))
    cad = CAD_WORDS.search(question) and not re.search(r'\bmesh', question, re.I)
    if tools.examples is not None and cad:
        for e in tools.examples.search(question, 1):
            cands.append((f"[example {e['name']}] verified {e.get('metrics', {})}\n```python\n{e['code'][:1100]}\n```",
                          'example:' + e['name'], 1300))
    if tools.kb is not None and len(tools.kb):
        for h in tools.kb.search(question, k):
            if h['score'] >= min_score or getattr(tools.kb, 'embedder', None):
                cands.append((f"[{h['id']}] ({h['source']}) {h['text']}", h['id'], 450))
    rk = getattr(tools, 'repo_kb', None)
    names = [str(n.get('name', '') if isinstance(n, dict) else n).lower() for n in (getattr(rk, 'packs', None) or [])]
    if rk is not None and len(rk) and (CAD_WORDS.search(question) or any(n in question.lower() for n in names)):
        for h in rk.search(question, 1):
            if h['score'] >= 3 * min_score:                       # repo text only when clearly relevant
                cands.append((f"[{h['id']}] ({h['source']}) {h['text']}", h['id'], 400))
    parts, used, left = [], [], budget
    for text, cid, cap in cands:
        if left < 120:
            break
        piece = text[:min(cap, left)]
        if len(piece) < len(text):
            piece = piece.rsplit(' ', 1)[0] + ' ...'
        parts.append(piece)
        used.append(cid)
        left -= len(piece) + 2
    if not parts:
        return None, []
    return ('Retrieved context (use it if relevant, cite the [ids]; it may be incomplete):\n\n' + '\n\n'.join(parts)), used


def attach_context(msgs, ctx, index=-1):
    """put the retrieved knowledge INTO the newest user message (at the end of the prompt), not in a system message
    before the chat: the system prompt and the earlier turns then stay one fixed prefix that llama.cpp's prompt cache
    reuses, so each turn only reads its new tokens (much faster on a CPU). Used at run time AND in the training data."""
    if not ctx:
        return msgs
    msgs = list(msgs)
    users = [i for i, m in enumerate(msgs) if m['role'] == 'user' and not str(m['content']).startswith('TOOL_RESULT')]
    if not users:
        return msgs
    i = users[index]
    msgs[i] = dict(msgs[i], content=f"{ctx}\n\n---\nQuestion: {msgs[i]['content']}")
    return msgs


def _install_note(text, shown):
    """the model must give the download link; if a small model forgot it, add it under its answer"""
    miss = [i for link, i in shown.items() if link not in text]
    return ''.join('\n\n**Install needed:** ' + i['message'] for i in miss)


def run(llm, tools, history, max_steps=MAX_STEPS):
    """history: [{'role','content'}] of the chat so far (user last). Yields UI events (dicts)."""
    tools.llm = llm                                          # look / pid_kg read show pictures to this same model
    msgs = [{'role': 'system', 'content': system_prompt(tools, PROMPT_COMPACT)}]
    ctx, used = retrieve(tools, history[-1]['content'])
    for h in tools.hook('question', history[-1]['content']) if hasattr(tools, 'hook') else []:
        ctx = (ctx + '\n\n' if ctx else '') + '[hook] ' + h
        used.append('hook')
    if ctx:
        yield {'type': 'context', 'sources': used}
    from . import chatstate                                  # long chat: oldest turns -> notes made by code (never lost)
    if chatstate.COUNTER is None and not getattr(llm, '_count_tried', False) and hasattr(llm, 'count_tokens'):
        llm._count_tried = True                              # exact token counts from the model's own tokenizer, once set up
        chatstate.use_counter(llm.count_tokens, msgs[0]['content'])
    fixed = sum(chatstate.tokens(m['content']) for m in msgs)
    history, note = chatstate.compact(list(history), getattr(tools, 'workdir', None), fixed_tokens=fixed)
    if note:
        for h in tools.hook('compact', note) if hasattr(tools, 'hook') else []:
            note += '\n\n[hook] ' + h
        msgs.append({'role': 'system', 'content': note})
        yield {'type': 'context', 'sources': ['chat notes']}
    msgs += attach_context(list(history), ctx)           # knowledge at the end: the chat so far stays a cached prefix
    seen, shown = set(), {}                                  # shown: install notices (link -> block) in this turn
    for step in range(max_steps):
        text = ''
        for piece in llm.stream(msgs):
            text += piece
            yield {'type': 'text', 'delta': piece}
        text = _strip_think(text)
        call = parse_tool_call(text)
        msgs.append({'role': 'assistant', 'content': text})
        if not call:
            yield {'type': 'done', 'content': text + _install_note(text, shown)}
            return
        if call['name'] == '__bad__':
            res = {'error': 'the tool block is not valid JSON: ' + call['raw'][:200] + ' - write it again as JSON'}
        else:
            key = call['name'] + json.dumps(call['args'], sort_keys=True, default=str)
            if key in seen:                                   # stall guard: same call again -> stop looping
                res = {'error': 'this exact call was already made; change the arguments or answer with what you have'}
                if step >= 2:
                    yield {'type': 'done', 'content': text + '\n\n(stopped: the model repeated the same tool call)'}
                    return
            else:
                seen.add(key)
                yield {'type': 'tool_call', 'name': call['name'], 'args': call['args']}
                res = tools.call(call['name'], call['args'])
        ev = {'type': 'tool_result', 'name': call['name'], 'result': res}
        if call['name'] in MESH_TOOLS and 'error' not in res and tools.last_mesh:
            ev['mesh'] = tools.last_mesh
        yield ev
        if isinstance(res, dict) and res.get('install') and res['install']['link'] not in shown:
            shown[res['install']['link']] = res['install']
            yield {'type': 'install', **res['install']}
        extra = tools.hook('tool_result', call['name'], call['args'], res) if hasattr(tools, 'hook') else []
        msgs.append({'role': 'user', 'content': f"TOOL_RESULT {call['name']}: " + compact_result(res)
                     + ''.join('\n[hook] ' + h for h in extra)})
    yield {'type': 'done', 'content': '(stopped after %d tool steps)' % max_steps}


def run_offline(tools, history):
    """no model connected: '/tool name {json}' runs a tool; anything else searches the knowledge base"""
    q = history[-1]['content'].strip()
    m = re.match(r'/(?:tool\s+)?(\w+)\s*(\{.*\})?\s*$', q, re.S)
    if m and m.group(1) in tools.t:
        name, args = m.group(1), json.loads(m.group(2) or '{}')
        yield {'type': 'tool_call', 'name': name, 'args': args}
        res = tools.call(name, args)
        ev = {'type': 'tool_result', 'name': name, 'result': res}
        if name in MESH_TOOLS and 'error' not in res:
            ev['mesh'] = tools.last_mesh
        yield ev
        if isinstance(res, dict) and res.get('install'):
            yield {'type': 'install', **res['install']}
        yield {'type': 'done', 'content': ''}
        return
    res = tools.knowledge_search(q)
    txt = '**No model connected** - showing the best matches from the knowledge folder. ' \
          'Run tools directly with `/panel_mesh {"length": 4800, "width": 3200}` etc.\n\n'
    txt += '\n\n'.join(f"**{r['id']}** ({r['source']}): {r['text'][:400]}" for r in res['results']) or res.get('note', 'nothing found')
    yield {'type': 'text', 'delta': txt}
    yield {'type': 'done', 'content': txt}
