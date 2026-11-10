"""
Run a CadQuery script in a separate process and return a short, checkable result (one JSON line), never a raw traceback dump:
  ok, n_solids, valid, bbox [x, y, z], volume, area, center_of_mass, files
  error_type, error_line, message                                  (on failure)
  checks: PASS/FAIL per expected value (expect = {"bbox": [x,y,z], "volume": V, "n_solids": n, "tol": 0.01})
Numbers asked by the user are checked against the built solid, not taken from the model's words.
"""
import json, os, subprocess, sys, textwrap

RUNNER = r'''
import json, sys, traceback
ns = {}
try:
    src = open(sys.argv[1]).read()
    exec(compile(src, "model.py", "exec"), ns)
    r = ns.get("result")
    if r is None:
        raise NameError("the script must set result = <cq.Workplane or Shape>")
    import cadquery as cq
    shp = r.val() if isinstance(r, cq.Workplane) and len(r.vals()) == 1 else (
        cq.Compound.makeCompound([v for v in r.vals() if isinstance(v, cq.Shape)]) if isinstance(r, cq.Workplane) else r)
    bb = shp.BoundingBox()
    out = {"ok": True, "n_solids": len(shp.Solids()), "valid": bool(shp.isValid()),
           "bbox": [round(bb.xlen, 3), round(bb.ylen, 3), round(bb.zlen, 3)],
           "bbox_min": [round(bb.xmin, 3), round(bb.ymin, 3), round(bb.zmin, 3)],
           "volume": round(shp.Volume(), 1), "area": round(shp.Area(), 1)}
    try:
        c = cq.Shape.centerOfMass(shp)
        out["center_of_mass"] = [round(c.x, 2), round(c.y, 2), round(c.z, 2)]
    except Exception:
        pass
    if len(sys.argv) > 2:
        base = sys.argv[2]
        cq.exporters.export(shp, base + ".step")
        cq.exporters.export(shp, base + ".stl")
        out["files"] = [base.split("/")[-1].split(chr(92))[-1] + e for e in (".step", ".stl")]
except Exception as e:
    tb = traceback.extract_tb(e.__traceback__)
    line = next((f.lineno for f in reversed(tb) if f.filename == "model.py"), None)
    out = {"ok": False, "error_type": type(e).__name__, "error_line": line, "message": str(e)[:400]}
print("__RESULT__" + json.dumps(out))
'''


def run(code, workdir, name=None, expect=None, timeout=300):
    os.makedirs(workdir, exist_ok=True)
    src = textwrap.dedent(code)
    if 'import cadquery' not in src:
        src = 'import cadquery as cq\n' + src
    tag = name or 'model'
    script = os.path.join(workdir, tag + '_script.py')
    open(script, 'w').write(src)
    runner = os.path.join(workdir, '.cq_runner.py')
    open(runner, 'w').write(RUNNER)
    if getattr(sys, 'frozen', False):                 # inside the single-file exe: the exe runs the script itself
        args = [sys.executable, '--cq-run', script] + ([os.path.join(workdir, tag)] if name else [])
    else:
        args = [sys.executable, runner, script] + ([os.path.join(workdir, tag)] if name else [])
    try:
        p = subprocess.run(args, cwd=workdir, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {'ok': False, 'error_type': 'Timeout', 'message': f'script ran longer than {timeout} s'}
    line = [l for l in p.stdout.splitlines() if l.startswith('__RESULT__')]
    if not line:
        return {'ok': False, 'error_type': 'Crash', 'message': (p.stderr or p.stdout)[-400:]}
    out = json.loads(line[-1][10:])
    if out.get('ok'):
        if name:
            out['files'] = out.get('files', []) + [tag + '_script.py']
        out['checks'] = verify(out, expect or {})
        if out['n_solids'] == 0:
            out['checks'].append('FAIL n_solids: no solid was produced')
        if not out['valid']:
            out['checks'].append('FAIL valid: the shape is not a valid solid (self-intersecting or open)')
        out['pass'] = not any(c.startswith('FAIL') for c in out['checks'])
    return out


def verify(res, expect):
    tol = float(expect.get('tol', 0.01))
    out = []
    if expect.get('bbox'):
        got, want = sorted(res['bbox']), sorted(float(x) for x in expect['bbox'])     # orientation-free
        bad = [f'{w:g}' for g, w in zip(got, want) if abs(g - w) > tol * max(abs(w), 1)]
        out.append(('FAIL' if bad else 'PASS') + f" bbox {res['bbox']} vs expected {expect['bbox']}")
    if expect.get('volume'):
        w = float(expect['volume'])
        ok = abs(res['volume'] - w) <= tol * abs(w)
        out.append(('PASS' if ok else 'FAIL') + f" volume {res['volume']:g} vs expected {w:g}")
    if expect.get('n_solids'):
        ok = res['n_solids'] == int(expect['n_solids'])
        out.append(('PASS' if ok else 'FAIL') + f" n_solids {res['n_solids']} vs expected {expect['n_solids']}")
    return out
