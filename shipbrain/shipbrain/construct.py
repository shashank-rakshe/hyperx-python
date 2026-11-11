"""
ConstructDrawingAI (https://github.com/A-SHOJAEI/ConstructDrawingAI, PolyForm Noncommercial 1.0.0 - used because
ShipBrain is declared non-commercial, see licence_mode.json), copied whole into vendor/ and run as written, in its own
Python process (its top-level packages are named agent / datasets / engines, which would clash in ShipBrain's process).

It reads 2D construction drawings into one schema, the CIR (Canonical Intermediate Representation: sheets, views,
entities with labels, IFC class, MasterFormat / UniFormat codes, connections, confidence and evidence):
  takeoff(cir)          quantity takeoff: counts per item (EA) with MasterFormat / IFC codes, items to review,
                        connections, lengths / areas when a scale is known
  qa(cir, question)     deterministic answers from the CIR with evidence (counts, presence, lists, sheets, panels)
  rfi(cir)              RFI drafts for unclear / low-confidence items
  generate(...)         its synthetic drawing engine: electrical plan + single-line + panel schedule pictures with an
                        exact CIR answer key and question / answer pairs (used for training the vision model)
Needs Python 3.11+ and: pydantic, msgpack, pyyaml (+ numpy, pillow for the drawing engine).
"""
import json, os, subprocess, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'vendor', 'ConstructDrawingAI', 'repo')

_RUN = r'''
import json, sys
sys.path.insert(0, '.')
import cir
from cir import DrawingSet
op, path = sys.argv[1], sys.argv[2]
ds = cir.load(DrawingSet, path)
if op == 'takeoff':
    from engines.takeoff import compute_takeoff
    t = compute_takeoff(ds, min_confidence=float(sys.argv[3]), review_threshold=float(sys.argv[4]))
    out = t.to_dict()
    out['markdown'] = t.to_markdown()
    out['by_sheet'] = t.by_sheet
elif op == 'qa':
    from agent.qa import answer
    a = answer(ds, sys.argv[3])
    out = {'question': a.question, 'answer': a.text, 'value': a.value if isinstance(a.value, (int, float, str, list, type(None))) else str(a.value),
           'evidence': [list(e) for e in a.evidence][:50], 'evidence_count': len(a.evidence)}
elif op == 'rfi':
    from agent.rfi import generate_rfis
    rf = generate_rfis(ds, review_threshold=float(sys.argv[3]))
    out = {'rfis': [{k: (v if isinstance(v, (int, float, str, list, dict, type(None))) else str(v)) for k, v in vars(r).items()} for r in rf]}
elif op == 'info':
    out = {'name': ds.name, 'sheets': [{'number': s.sheet_number, 'title': getattr(s, 'title', None),
                                        'discipline': s.discipline.value if s.discipline else None,
                                        'entities': sum(len(v.entities) for v in s.views),
                                        'connections': sum(len(v.connections) for v in s.views)} for s in ds.sheets],
           'qa_pairs': (ds.metadata or {}).get('qa_pairs', []),
           'metadata': {k: v for k, v in (ds.metadata or {}).items() if k != 'qa_pairs' and isinstance(v, (str, int, float, bool))}}
print('@@JSON@@' + json.dumps(out, default=str))
'''


def available():
    return os.path.isdir(ROOT)


def _python():
    """a Python 3.11+ for its code (this one if new enough)"""
    if sys.version_info >= (3, 11):
        return sys.executable
    import shutil
    for n in ('python3.13', 'python3.12', 'python3.11'):
        if shutil.which(n):
            return shutil.which(n)
    raise RuntimeError('ConstructDrawingAI needs Python 3.11 or newer (python.org/downloads)')


def _call(op, path, *extra, timeout=600):
    if not available():
        raise RuntimeError('ConstructDrawingAI is not in shipbrain/vendor')
    r = subprocess.run([_python(), '-c', _RUN, op, os.path.abspath(path)] + [str(x) for x in extra], cwd=ROOT,
                       capture_output=True, text=True, timeout=timeout)
    for line in r.stdout.splitlines():
        if line.startswith('@@JSON@@'):
            return json.loads(line[8:])
    err = (r.stderr or r.stdout).strip()
    if 'No module named' in err:
        import re
        m = re.search(r"No module named '([\w.]+)'", err)
        raise ModuleNotFoundError(f"No module named '{m.group(1) if m else 'pydantic'}'")
    raise RuntimeError('ConstructDrawingAI failed: ' + err[-800:])


def takeoff(path, min_confidence=0.0, review_threshold=0.5):
    t = _call('takeoff', path, min_confidence, review_threshold)
    items = '; '.join(f"{ln['item']} {ln['qty']} {ln['unit']}" + (f" (MasterFormat {ln['masterformat']})" if ln.get('masterformat') else '')
                      + (f", {ln['needs_review']} to review" if ln['needs_review'] else '') for ln in t['lines'][:20])
    conn = ', '.join(f'{k} {v}' for k, v in sorted(t.get('connections', {}).items()))
    t['plain_english'] = (f"Quantity takeoff of {t['drawing_set']}: {t['total_count']} items in {len(t['lines'])} line(s): {items}."
                          + (f" Connections: {conn}." if conn else '')
                          + (f" {t['total_needs_review']} item(s) below confidence {t['review_threshold']:g} need a human check."
                             if t['total_needs_review'] else ' Nothing below the review threshold.')
                          + ('' if t.get('scale_known') else ' No drawing scale found, so no real lengths / areas.'))
    t.pop('markdown', None) if len(t.get('markdown', '')) > 6000 else None
    return t


def qa(path, question):
    a = _call('qa', path, question)
    a['plain_english'] = a['answer'] + (f" (evidence: {a['evidence_count']} item(s) on sheet(s) "
                                        f"{', '.join(sorted({e[0] for e in a['evidence']}))})" if a['evidence_count'] else '')
    return a


def rfi(path, review_threshold=0.5):
    r = _call('rfi', path, review_threshold)
    r['plain_english'] = (f"{len(r['rfis'])} RFI draft(s): " + '; '.join(str(x.get('subject') or x.get('question') or x)[:120] for x in r['rfis'][:8])
                          if r['rfis'] else 'No RFI needed: nothing unclear or below the confidence threshold.')
    return r


def info(path):
    return _call('info', path)


def convert_pid2graph(raw_root, out_dir, cap=None, timeout=7200):
    """its PID2Graph converter (GraphML + image -> CIR with symbols, line nodes and connections), run as written"""
    cmd = [_python(), '-m', 'datasets.preparers.graphml_cir', '--raw', os.path.abspath(raw_root), '--out', os.path.abspath(out_dir)]
    if cap:
        cmd += ['--cap', str(cap)]
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    if r.returncode:
        raise RuntimeError('PID2Graph conversion failed: ' + (r.stderr or r.stdout)[-800:])
    return sorted(os.path.join(out_dir, f) for f in os.listdir(out_dir) if f.endswith('.cir'))


def generate(out_dir, n=10, kind='electrical', seed=0, degradation='0..3', qa_pairs=True, timeout=7200):
    """its synthetic drawing engine -> out_dir/sample_XXXXX/{plan,single_line,schedule}[.deg].png + ground_truth.cir"""
    cmd = [_python(), '-m', 'synthetic.generate', '--type', kind, '--n', str(n), '--degradation-range', degradation,
           '--out', os.path.abspath(out_dir), '--seed', str(seed), '--style-seed', str(seed)] + (['--qa-pairs'] if qa_pairs else [])
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    if r.returncode:
        raise RuntimeError('ConstructDrawingAI synthetic engine failed: ' + (r.stderr or r.stdout)[-800:])
    return sorted(os.path.join(out_dir, d) for d in os.listdir(out_dir) if d.startswith('sample_'))
