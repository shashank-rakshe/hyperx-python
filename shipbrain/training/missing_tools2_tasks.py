"""
More real-run samples for tools without training data: structure_to_mesh (structure model -> FE mesh), ocx_write then ocx_to_step, code_folder -> code_functions -> code_call (your own Python folder),
and parse_document (a PDF with a table of design values). Results are real tool output; the temporary folder name is replaced by C:/work.

    python training/missing_tools2_tasks.py --n 60 --out training/data/missing_tools2_train.jsonl.gz
"""
import argparse, copy, gzip, json, os, random, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)
sys.path.insert(0, HERE)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=60)
    ap.add_argument('--out', default=os.path.join(HERE, 'data', 'missing_tools2_train.jsonl.gz'))
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    from shipbrain import agent, knowledge
    from make_dataset import tool_block, result_msg
    r = random.Random(a.seed)
    work = tempfile.mkdtemp(prefix='sb_m2_')
    T = agent.Tools(work, knowledge.load(None), allow_code=True)
    U = lambda t: {'role': 'user', 'content': t}
    A = lambda t: {'role': 'assistant', 'content': t}
    src = open(os.path.join(ROOT, 'tests', 'test_shipbrain.py')).read()
    ns = {}
    exec(src[src.index('def _structure'):src.index('def test_compare_structures')], ns)

    def step(tool, args):
        res = T.call(tool, json.loads(json.dumps(args)))
        if 'error' in res:
            raise ValueError(res['error'])
        return res, [A(tool_block(tool, args)), result_msg(tool, res)]

    def structure():
        S = ns['_structure']()
        L, B = r.choice([4000, 6000, 8000]), r.choice([3000, 4000])
        panel = S['blocks'][0]['panels'][0]
        panel['plates'][0]['contour'] = [[0, 0], [L, 0], [L, B], [0, B], [0, 0]]
        panel['plates'][0]['thk'] = float(r.choice([10, 12, 14]))
        step_ = B / 5
        panel['stiffeners'] = [{'name': f'L{k}', 'sec': 'FB150', 'grade': 'A', 'trace': [[0, round(step_ * (k + 1))], [L, round(step_ * (k + 1))]], 'incl': [0, 0, -1]} for k in range(4)]
        S['blocks'][0]['panels'][1]['plates'][0]['contour'] = [[0, 0], [L, 0], [L, -600], [0, -600]]
        fn = r.choice(['structure.json', 'deck_model.json', 's.json'])
        json.dump(S, open(os.path.join(work, fn), 'w'))
        size = r.choice([200, 250, 300])
        m, c = step('structure_to_mesh', {'file': fn, 'element_size': size})
        ck = m['check']
        ans = (f"Made the global FE mesh from {fn}: {m['plates']} plates as shells and the stiffeners as beams: {m['nodes']} nodes, {m['elements']} elements ({m['quads']} quads, {m['bars']} beam elements), "
               f"{ck['free_nodes']} free nodes, {ck['duplicate_nodes']} duplicate nodes, {ck['parts']} connected part, verdict {ck['verdict']}. Files: {', '.join(m['files'].values())}.")
        return [U(f'Make the FE mesh of the structure model {fn}, element size {size} mm.')] + c + [A(ans)]

    def ocx_chain():
        S = ns['_structure']()
        fn = 'model.json'
        json.dump(S, open(os.path.join(work, fn), 'w'))
        m1, c1 = step('ocx_write', {'file': fn, 'name': 'panel'})
        m2, c2 = step('ocx_to_step', {'file': m1['file']})
        c2[0]['content'] = f"OCX file written and valid. Now the STEP.\n" + c2[0]['content']
        return [U(f'Write {fn} as an OCX file and then make a STEP 3D model of it.')] + c1 + c2 + [A(f"{m1['plain_english'].split('.')[0]}. {m2['plain_english']}")]

    def code_chain():
        name = r.choice(['mytools', 'yardcalc', 'platelib'])
        os.makedirs(os.path.join(work, name), exist_ok=True)
        rho = r.choice([7850.0, 7800.0])
        open(os.path.join(work, name, 'plates.py'), 'w').write(
            f'def plate_weight(L, B, t, rho={rho}):\n    """weight in kg of a steel plate, L and B in m, t in mm"""\n    return rho * L * B * t / 1000.0\n\n'
            'def head_pressure(h, rho=1025.0):\n    """pressure in kPa of a water head h in m"""\n    return rho * 9.81 * h / 1000.0\n')
        m1, c1 = step('code_folder', {'name': name, 'folder': os.path.join(work, name)})
        m2, c2 = step('code_functions', {'repo': name, 'query': 'weight'})
        fn = next((f for f in (m2.get('functions') or []) if 'plate_weight' in str(f)), None)
        if not fn:
            return None
        f_file = fn.get('file') if isinstance(fn, dict) else 'plates.py'
        L, B, t = r.choice([2.0, 3.0]), r.choice([1.0, 1.5]), r.choice([8, 10, 12, 16])
        m3, c3 = step('code_call', {'repo': name, 'file': f_file, 'function': 'plate_weight', 'args': {'L': L, 'B': B, 't': t}})
        return ([U(f'I have my own Python folder {name} with my calculations. Use it to get the weight of a {L} x {B} m plate, {t} mm thick.')] + c1 + c2 + c3 + [A(f"plate_weight({L}, {B}, {t}) from {name}/plates.py = {m3['result']:.1f} kg (L and B in m, t in mm). " + m3['plain_english'])])

    def pdf_parse():
        from reportlab.pdfgen import canvas
        fn = r.choice(['design_basis.pdf', 'spec.pdf'])
        c = canvas.Canvas(os.path.join(work, fn))
        y = 800
        p_, t_ = r.choice([0.02, 0.03, 0.05]), r.choice([10, 12, 14])
        lines = ['Design basis for the deck structure', ''] + [f'{i}. The {w} shall comply with the class rules and the owner specification, and the calculation shall state its assumptions.'
                                                           for i, w in enumerate(['deck plating', 'longitudinal stiffeners', 'transverse web frames', 'brackets', 'welding'] * 5, 1)] + [
            f'Design pressure {p_} MPa. Plate thickness {t_} mm. Steel grade AH36, yield 355 MPa.', 'The corrosion addition is 1.5 mm on all plates.']
        for ln in lines:
            c.drawString(60, y, ln[:110])
            y -= 18
        c.save()
        m, cs = step('parse_document', {'file': fn})
        if m.get('needs_ocr_pages'):
            return None
        ans = f"{m['plain_english']} The first lines: " + m['preview'][:160].replace('\n', ' ')
        return [U(f'Read {fn} and give it to me as text.')] + cs + [A(ans)]

    gens = [(structure, 4), (ocx_chain, 2), (code_chain, 3), (pdf_parse, 2)]
    pool = [g for g, w in gens for _ in range(w)]
    rows, kinds, tries = [], {}, 0
    while len(rows) < a.n and tries < a.n * 4:
        tries += 1
        g = r.choice(pool)
        try:
            m = g()
        except Exception as e:
            print('skip', g.__name__, type(e).__name__, str(e)[:120])
            continue
        if not m:
            continue
        kinds[g.__name__] = kinds.get(g.__name__, 0) + 1
        rows.append({'task': 'missing2_' + g.__name__, 'messages': m})
    s = json.dumps(rows).replace(work, 'C:/work').replace(work.replace('/', '\\/'), 'C:/work')
    rows = json.loads(s)
    for x in rows:
        roles = [m['role'] for m in x['messages']]
        assert all(p != q for p, q in zip(roles, roles[1:])), (x['task'], roles)
    assert '/tmp/' not in s and '/home/' not in s and 'sb_m2_' not in s and '/root/' not in s, [t for t in ('/tmp/', '/home/', 'sb_m2_', '/root/') if t in s]
    shutil.rmtree(work, ignore_errors=True)
    with gzip.open(a.out, 'wt', encoding='utf-8') as fh:
        for x in rows:
            fh.write(json.dumps(x) + '\n')
    print(a.out, len(rows), kinds)


if __name__ == '__main__':
    main()
