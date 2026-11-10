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
        self.register('fe_convert', self.fe_convert, 'Convert an FE model between Nastran .bdf, Abaqus/CalculiX .inp and ANSYS APDL .mac '
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
        self.register('fatigue_mesh', self.fatigue_mesh, 'Fatigue hot-spot local model: cut a box around the hot spot from a plate assembly, '
                      'mesh it t x t, give the read-out points at 0.5t / 1.5t; with solve=true also run CalculiX and return the '
                      'extrapolated hot-spot stress (1.5 s(0.5t) - 0.5 s(1.5t)).',
                      {'type': 'object', 'properties': {'plates': {'type': 'array'}, 'hotspot': {'type': 'array'}, 'size': {'type': 'number'},
                                                         't': {'type': 'number'}, 'loads': {'type': 'array'}, 'solve': {'type': 'boolean'},
                                                         'name': {'type': 'string'}}, 'required': ['plates', 'hotspot']})
        self.register('compare_drawings', self.compare_drawings, 'Compare two drawings (PDF page, PNG/JPG, DXF): aligned overlay, '
                      'what was removed (red) / added (green), similarity in %, changed areas.',
                      {'type': 'object', 'properties': {'a': {'type': 'string'}, 'b': {'type': 'string'}, 'page_a': {'type': 'integer'},
                                                         'page_b': {'type': 'integer'}}, 'required': ['a', 'b']})
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
                      'Reads structure JSON or ship XML.',
                      {'type': 'object', 'properties': {'a': {'type': 'string'}, 'b': {'type': 'string'}, 'tol': {'type': 'number'},
                                                         'move_tol': {'type': 'number'}}, 'required': ['a', 'b']})
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

    def compare_drawings(self, a, b, page_a=0, page_b=0):
        from . import drawings
        out = os.path.join(self.workdir, f'compare_{os.path.splitext(os.path.basename(a))[0]}_vs_{os.path.splitext(os.path.basename(b))[0]}.png')
        r = drawings.compare_drawings(self._path(a), self._path(b), out, page_a, page_b)
        r['overlay'] = os.path.basename(out)
        try:                                                # vector drawings: also say WHAT changed (lines, styles, numbers)
            from .drawdiff import compare_vector
            v = compare_vector(self._path(a), self._path(b), page_a, page_b)
            if v['lines']['removed'] + v['lines']['added'] + len(v['details']) or (v['texts']['changed'] + v['texts']['added']):
                r['semantic'] = {k: v[k] for k in ('lines', 'texts', 'details')}
                r['plain_english'] += ' ' + v['plain_english']
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
        from . import engines
        return engines.choose(question)

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
            return fn(**args)
        except Exception as e:
            return {'error': f'{type(e).__name__}: {e}'}

    def describe(self):
        return '\n'.join(f'- {n}: {d}\n  args: {json.dumps(s.get("properties", {}), separators=(",", ":"))}'
                         for n, (_, d, s) in self.t.items())


# ====================================================================== prompt
SYSTEM = """You are ShipBrain, an engineering assistant for ship structures: CAD, FE meshing, FEA and CFD set-up.
Units: mm, N, MPa, tonne (1 m sea-water head = 0.01005 MPa).

Rules:
0. Write in plain, simple English: short sentences, everyday words, explain an engineering term the first time you use it,
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

Tools:
{tools}
"""


SYSTEM_COMPACT = """You are ShipBrain, an assistant for ship structure CAD, FE meshing, FEA and drawings. Units mm, N, MPa.
Write plain simple English, explain terms, give units; use a result's plain_english text. Ask file_info first about uploaded files.
Numbers/meshes/files only from tools; use calc for arithmetic; cite [ids] of retrieved knowledge or memory.
Call a tool with ONLY:
```tool
{{"name": "<tool>", "args": {{...}}}}
```
then wait for TOOL_RESULT. Missing value: assume a sensible one and say so. End with a short answer: done, key numbers, files, warnings.
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
def _strip_think(t):
    return re.sub(r'<think>.*?</think>', '', t, flags=re.S)


CAD_WORDS = re.compile(r'\b(cad|cadquery|step|stl|solid|3d|3-d|part|extrude)\b|model of|make a model|3d model', re.I)


def retrieve(tools, question, k=3, min_score=3.0):
    """RAG: best rule-book / notes chunks and (for CAD requests) verified CadQuery examples, as one context message"""
    parts, used = [], []
    if tools.memory is not None:
        for m in tools.memory.recall(question, 3):
            parts.append(f"[memory {m['id']}] (taught by the user) {m['text']}")
            used.append('memory:' + m['id'])
    if tools.kb is not None and len(tools.kb):
        for h in tools.kb.search(question, k):
            if h['score'] >= min_score or getattr(tools.kb, 'embedder', None):
                parts.append(f"[{h['id']}] ({h['source']}) {h['text'][:600]}")
                used.append(h['id'])
    rk = getattr(tools, 'repo_kb', None)
    names = [str(n.get('name', '') if isinstance(n, dict) else n).lower() for n in (getattr(rk, 'packs', None) or [])]
    if rk is not None and len(rk) and (CAD_WORDS.search(question) or any(n in question.lower() for n in names)):
        for h in rk.search(question, 2):
            if h['score'] >= 3 * min_score:                       # repo text only when clearly relevant
                parts.append(f"[{h['id']}] ({h['source']}) {h['text'][:500]}")
                used.append(h['id'])
    if tools.examples is not None and CAD_WORDS.search(question) and not re.search(r'\bmesh', question, re.I):
        for e in tools.examples.search(question, 2):
            parts.append(f"[example {e['name']}] verified {e.get('metrics', {})}\n```python\n{e['code'][:1500]}\n```")
            used.append('example:' + e['name'])
    if not parts:
        return None, []
    return ('Retrieved context (use it if relevant, cite the [ids]; it may be incomplete):\n\n' + '\n\n'.join(parts)), used


def run(llm, tools, history, max_steps=MAX_STEPS):
    """history: [{'role','content'}] of the chat so far (user last). Yields UI events (dicts)."""
    msgs = [{'role': 'system', 'content': system_prompt(tools, PROMPT_COMPACT)}]
    ctx, used = retrieve(tools, history[-1]['content'])
    if ctx:
        msgs.append({'role': 'system', 'content': ctx})
        yield {'type': 'context', 'sources': used}
    msgs += list(history)
    seen = set()
    for step in range(max_steps):
        text = ''
        for piece in llm.stream(msgs):
            text += piece
            yield {'type': 'text', 'delta': piece}
        text = _strip_think(text)
        call = parse_tool_call(text)
        msgs.append({'role': 'assistant', 'content': text})
        if not call:
            yield {'type': 'done', 'content': text}
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
        msgs.append({'role': 'user', 'content': f"TOOL_RESULT {call['name']}: " + compact_result(res)})
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
        yield {'type': 'done', 'content': ''}
        return
    res = tools.knowledge_search(q)
    txt = '**No model connected** - showing the best matches from the knowledge folder. ' \
          'Run tools directly with `/panel_mesh {"length": 4800, "width": 3200}` etc.\n\n'
    txt += '\n\n'.join(f"**{r['id']}** ({r['source']}): {r['text'][:400]}" for r in res['results']) or res.get('note', 'nothing found')
    yield {'type': 'text', 'delta': txt}
    yield {'type': 'done', 'content': txt}
