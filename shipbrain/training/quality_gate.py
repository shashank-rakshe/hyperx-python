"""
Quality gate: one command that says, in plain English, whether ShipBrain is good enough to ship / train.

    python training/quality_gate.py                    # code + data checks (CPU, ~2-4 min)
    python training/quality_gate.py --real plates.json # + your private structure model (local only, never committed)
    python training/quality_gate.py --server http://127.0.0.1:8081 --eval data/eval.jsonl   # + the trained model

Checks
  1. unit tests                      all must pass
  2. accuracy                        unstructured mesher vs Roark (clamped + simply supported) within 2 %
  3. CAD example library             every example builds and matches its recorded bbox / volume
  4. training data                   N samples: every tool call parses, every tool result is real (no "error"), the
                                     final answers contain the numbers of the tool results, no duplicates
  5. real structure (optional)       connected share, degenerate elements, near-duplicate nodes
  6. trained model (optional)        right tool %, exact arguments %, average answer length
Exit code 0 = all required checks passed.
"""
import argparse, json, os, re, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)


def check(name, ok, detail, required=True):
    mark = 'PASS' if ok else ('FAIL' if required else 'WARN')
    print(f'[{mark}] {name}: {detail}', flush=True)
    return ok or not required


def tests():
    r = subprocess.run([sys.executable, '-m', 'pytest', 'tests', '-q', '-p', 'no:warnings'], cwd=ROOT, capture_output=True, text=True)
    last = (r.stdout.strip().splitlines() or ['no output'])[-1]
    return check('unit tests', r.returncode == 0, last)


def accuracy():
    from shipbrain import platemesh, solver, fea
    if not solver.ccx_path():
        return check('accuracy vs Roark', True, 'skipped (CalculiX not installed)', required=False)
    out, ok = [], True
    with tempfile.TemporaryDirectory() as d:
        for bc, fx in (('clamped', [{'x': 0}, {'x': 2000}, {'y': 0}, {'y': 1000}]),
                       ('simply', [{'x': 0, 'dof': '3'}, {'x': 2000, 'dof': '3'}, {'y': 0, 'dof': '3'}, {'y': 1000, 'dof': '3'},
                                   {'x': 0, 'y': 0, 'dof': '12'}, {'x': 2000, 'y': 0, 'dof': '2'}])):
            spec = {'name': bc, 'element_size': 25, 'fix': fx, 'loads': [{'plates': ['P'], 'pressure': 0.05}],
                    'plates': [{'id': 'P', 't': 20, 'outline': [[0, 0, 0], [2000, 0, 0], [2000, 1000, 0], [0, 1000, 0]]}]}
            _, info = platemesh.build_plates(spec, d, formats=('inp',))
            w = solver.run_calculix(info['files']['inp'])['max_displacement_mm']
            ref = fea.plate_pressure(2000, 1000, 20, 0.05, bc)['w_max_mm']
            err = 100 * (w / ref - 1)
            ok &= abs(err) < 2
            out.append(f'{bc} {err:+.1f} %')
    return check('accuracy vs Roark (plate deflection)', ok, ', '.join(out))


def examples():
    try:
        import cadquery  # noqa: F401
    except ImportError:
        return check('CAD example library', True, 'skipped (CadQuery not installed)', required=False)
    from shipbrain.examples import verify_all, Examples
    rep = verify_all()
    bad = [r for r in rep if not r.split(': ', 1)[1].startswith('ok')]
    return check('CAD example library', not bad, f'{len(rep) - len(bad)}/{len(rep)} build and match their record' +
                 (f'; problems: {bad[:3]}' if bad else '') + f'; {len(Examples().items)} served to the model')


def data(n):
    from shipbrain import agent
    with tempfile.TemporaryDirectory() as d:
        out, ev = os.path.join(d, 't.jsonl'), os.path.join(d, 'e.jsonl')
        subprocess.run([sys.executable, os.path.join(HERE, 'make_dataset.py'), '--n', str(n), '--eval-n', '5', '--no-cad',
                        '--out', out, '--eval-out', ev], cwd=ROOT, capture_output=True, text=True, check=True)
        rows = [json.loads(l) for l in open(out)]
    bad_call = err = unsupported = 0
    seen = set()
    dup = 0
    for r in rows:
        m = r['messages']
        key = json.dumps([x['content'] for x in m if x['role'] != 'system'])
        dup += key in seen
        seen.add(key)
        for i, x in enumerate(m):
            if x['role'] == 'assistant' and '```tool' in x['content']:
                c = agent.parse_tool_call(x['content'])
                bad_call += (c is None or c['name'] == '__bad__')
            if x['role'] == 'user' and x['content'].startswith('TOOL_RESULT') and '"error"' in x['content'] and r['task'] not in ('mesh_fix', 'install'):
                err += 1
        final = m[-1]['content']
        res = [x['content'] for x in m if x['role'] == 'user' and x['content'].startswith('TOOL_RESULT')]
        for num in re.findall(r'\*\*([-\d.]+)', final):          # bold numbers in the answer must come from a tool result
            if res and not any(num.rstrip('.') in t for t in res):
                unsupported += 1
    ok = bad_call == 0 and err == 0 and unsupported == 0 and dup <= 0.05 * len(rows)
    return check('training data', ok, f'{len(rows)} samples: {bad_call} unparsable tool calls, {err} unexpected tool errors, '
                                      f'{unsupported} answer numbers not found in tool results, {dup} duplicates')


def real(path, h=400.0, tol=15.0):
    from shipbrain import geoclean, platemesh
    d = json.load(open(path))
    t = time.time()
    plates, _ = geoclean.clean_plates(d['plates'], merge_tol=tol)
    with tempfile.TemporaryDirectory() as w:
        m, info = platemesh.build_plates({'name': 'real', 'plates': plates, 'beams': d.get('beams', []), 'element_size': h}, w, formats=())
    c = info['check']
    main = c['part_sizes'][0] / max(1, c['elements']) * 100
    q = c['quality']
    ok = main >= 99 and q['inverted_or_degenerate'] == 0
    return check('real structure model', ok, f"{c['elements']} elements in {time.time() - t:.0f} s; largest connected piece {main:.1f} %, "
                                             f"{c['parts']} pieces, {c['duplicate_nodes']} near-duplicate nodes, "
                                             f"{q['inverted_or_degenerate']} bad elements, min angle {q['min_angle']} deg", required=False)


def model(server, eval_path, limit):
    from shipbrain import agent
    sys.path.insert(0, HERE)
    from evaluate import args_match
    llm = agent.LLM(server, temperature=0.0, max_tokens=500)
    rows = [json.loads(l) for l in open(eval_path)][:limit]
    tool_ok = args_ok = n = 0
    chars = 0
    t = time.time()
    for d in rows:
        m = d['messages']
        idx = max((j for j, x in enumerate(m) if x['role'] == 'assistant' and '```tool' in x['content']), default=None)
        if idx is None:
            continue
        got = ''.join(llm.stream(m[:idx]))
        chars += len(got)
        ref, gc = agent.parse_tool_call(m[idx]['content']), agent.parse_tool_call(got)
        n += 1
        if gc and gc['name'] == ref['name']:
            tool_ok += 1
            args_ok += args_match(ref['args'], gc['args'])[0]
    ok = n and tool_ok / n >= 0.9 and args_ok / n >= 0.7
    return check('trained model', bool(ok), f'{n} requests: right tool {100 * tool_ok / max(1, n):.0f} %, exact arguments '
                                            f'{100 * args_ok / max(1, n):.0f} %, {chars / max(1, n):.0f} characters per reply, '
                                            f'{(time.time() - t) / max(1, n):.1f} s per request (targets: 90 % / 70 %)')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=150, help='training samples to generate and inspect')
    ap.add_argument('--real', help='private plates/beams JSON of a real structure (local only)')
    ap.add_argument('--server')
    ap.add_argument('--eval', default='data/eval.jsonl')
    ap.add_argument('--limit', type=int, default=40)
    ap.add_argument('--skip-tests', action='store_true')
    a = ap.parse_args()
    os.chdir(ROOT)
    ok = True
    if not a.skip_tests:
        ok &= tests()
    ok &= accuracy()
    ok &= examples()
    ok &= data(a.n)
    if a.real:
        ok &= real(a.real)
    if a.server:
        ok &= model(a.server, a.eval, a.limit)
    print('\nRESULT:', 'all required checks passed - good to ship / train.' if ok else 'NOT ready - fix the FAIL lines above.')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
