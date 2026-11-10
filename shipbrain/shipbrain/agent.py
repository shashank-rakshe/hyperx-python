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

from . import mesh as _mesh, fea as _fea, solver as _solver

TOOL_RE = re.compile(r'```tool\s*\n(.*?)\n?```', re.S)
MAX_STEPS = 6


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
    def __init__(self, workdir, kb=None, allow_code=False):
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
                      'Search the rule book / notes / standards in the knowledge folder. Use before answering rule or method questions; cite the ids.',
                      {'type': 'object', 'properties': {'query': {'type': 'string'}, 'k': {'type': 'integer'}}, 'required': ['query']})
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
        self.register('cad_mesh', self.cad_mesh, 'Mesh a CAD file in the workspace (STEP/IGES/BREP/STL) with gmsh: dim 2 = shell surface mesh, 3 = solid tets.',
                      {'type': 'object', 'properties': {'file': {'type': 'string'}, 'element_size': num, 'dim': {'type': 'integer'},
                                                         'quads': {'type': 'boolean'}}, 'required': ['file']})
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
        self.register('list_files', self.list_files, 'List the files in the workspace (uploads and results).', {'type': 'object', 'properties': {}})
        if self.allow_code:
            self.register('cadquery_build', self.cadquery_build,
                          'Run a CadQuery script that sets `result` (a cq.Workplane) and export STEP + STL into the workspace. Then use cad_mesh.',
                          {'type': 'object', 'properties': {'code': {'type': 'string'}, 'name': {'type': 'string'}}, 'required': ['code']})

    # ------------------------------------------------------------------ implementations
    def knowledge_search(self, query, k=5):
        if not self.kb or not len(self.kb):
            return {'results': [], 'note': 'knowledge folder is empty - start the app with --knowledge DIR'}
        return {'results': [{'id': h['id'], 'source': h['source'], 'title': h['title'], 'text': h['text'][:700], 'score': h['score']}
                            for h in self.kb.search(query, int(k))]}

    def panel_mesh(self, **spec):
        spec.setdefault('name', 'panel_%s' % time.strftime('%H%M%S'))
        spec['name'] = re.sub(r'[^A-Za-z0-9_\-]', '_', str(spec['name']))[:40]
        m, info = _mesh.build_panel(spec, self.workdir)
        self.last_mesh = _mesh.viewer_data(m)
        info['files'] = {k: os.path.basename(v) for k, v in info['files'].items()}
        info['viewer'] = 'mesh shown in the 3D view'
        return info

    def cad_mesh(self, file, element_size=50.0, dim=2, quads=True):
        info = _mesh.mesh_cad_file(self._path(file), element_size, int(dim), quads=quads, out_dir=self.workdir)
        info['files'] = {k: os.path.basename(v) for k, v in info['files'].items()}
        return info

    def solve_calculix(self, inp):
        r = _solver.run_calculix(self._path(inp))
        r['frd'] = os.path.basename(r['frd'])
        return r

    def list_files(self):
        return {'files': sorted(f for f in os.listdir(self.workdir) if not f.startswith('.'))}

    def cadquery_build(self, code, name='part'):
        name = re.sub(r'[^A-Za-z0-9_\-]', '_', name)[:40]
        script = textwrap.dedent(code) + textwrap.dedent(f'''
            import cadquery as _cq
            _r = result if 'result' in dir() else None
            assert _r is not None, 'the script must set result = <cq.Workplane>'
            _cq.exporters.export(_r, {name + '.step'!r})
            _cq.exporters.export(_r, {name + '.stl'!r})
            _s = _r.val()
            _b = _s.BoundingBox()
            print('__INFO__', {{'volume': _s.Volume(), 'bbox': [_b.xlen, _b.ylen, _b.zlen], 'solids': len(_r.solids().vals())}})
        ''')
        path = os.path.join(self.workdir, name + '_script.py')
        open(path, 'w').write('import cadquery as cq\n' + script)
        r = subprocess.run([sys.executable, '-I', path], cwd=self.workdir, capture_output=True, text=True, timeout=300)
        info = [l for l in r.stdout.splitlines() if l.startswith('__INFO__')]
        if r.returncode or not info:
            raise RuntimeError((r.stderr or r.stdout)[-1500:])
        out = ast.literal_eval(info[-1][9:])
        out['files'] = [name + '.step', name + '.stl', name + '_script.py']
        return out

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


def system_prompt(tools):
    return SYSTEM.format(tools=tools.describe())


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
        body = {'model': self.model, 'messages': messages, 'temperature': self.temperature, 'max_tokens': self.max_tokens, 'stream': True}
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


def run(llm, tools, history, max_steps=MAX_STEPS):
    """history: [{'role','content'}] of the chat so far (user last). Yields UI events (dicts)."""
    msgs = [{'role': 'system', 'content': system_prompt(tools)}] + list(history)
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
            yield {'type': 'tool_call', 'name': call['name'], 'args': call['args']}
            res = tools.call(call['name'], call['args'])
        ev = {'type': 'tool_result', 'name': call['name'], 'result': res}
        if call['name'] == 'panel_mesh' and 'error' not in res and tools.last_mesh:
            ev['mesh'] = tools.last_mesh
        yield ev
        msgs.append({'role': 'user', 'content': f"TOOL_RESULT {call['name']}: " + json.dumps(res, default=str)[:6000]})
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
        if name == 'panel_mesh' and 'error' not in res:
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
