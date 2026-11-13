"""
Real-run samples for drawing_to_3d (a DXF structural plan with layers DECK / OPENING / GIRDER / FRAME / STIFF -> 3D STEP + FE mesh) and drawing_check (the sums and products written on a DXF drawing: 24 x 101.6 = 2438.4,
6 @ 800 = 4800 ... with one deliberately wrong). The DXF files are written here with ezdxf, so the answer keys are exact.

    python training/missing_tools3_tasks.py --n 50 --out training/data/missing_tools3_train.jsonl.gz
"""
import argparse, gzip, json, os, random, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=50)
    ap.add_argument('--out', default=os.path.join(HERE, 'data', 'missing_tools3_train.jsonl.gz'))
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    import ezdxf
    from shipbrain import agent, knowledge
    from make_dataset import tool_block, result_msg
    r = random.Random(a.seed)
    work = tempfile.mkdtemp(prefix='sb_m3_')
    T = agent.Tools(work, knowledge.load(None), allow_code=True)
    U = lambda t: {'role': 'user', 'content': t}
    A = lambda t: {'role': 'assistant', 'content': t}

    def step(tool, args):
        res = T.call(tool, json.loads(json.dumps(args)))
        if 'error' in res:
            raise ValueError(res['error'])
        return res, [A(tool_block(tool, args)), result_msg(tool, res)]

    def plan():
        L, B = r.choice([4000, 5000, 6000]), r.choice([2400, 3000])
        n_gir, n_stf = r.choice([1, 2]), r.choice([2, 3, 4])
        opening = r.random() < 0.5
        doc = ezdxf.new('R2010')
        msp = doc.modelspace()
        for lay in ('DECK', 'OPENING', 'GIRDER', 'FRAME', 'STIFF'):
            doc.layers.add(lay)
        msp.add_lwpolyline([(0, 0), (L, 0), (L, B), (0, B)], close=True, dxfattribs={'layer': 'DECK'})
        if opening:
            msp.add_lwpolyline([(L * 0.6, B * 0.35), (L * 0.6 + 700, B * 0.35), (L * 0.6 + 700, B * 0.35 + 500), (L * 0.6, B * 0.35 + 500)], close=True, dxfattribs={'layer': 'OPENING'})
        for k in range(n_gir):
            y = B * (k + 1) / (n_gir + 1)
            msp.add_line((0, y), (L, y), dxfattribs={'layer': 'GIRDER'})
        for k in range(n_stf):
            x = L * (k + 1) / (n_stf + 1)
            msp.add_line((x, 0), (x, B), dxfattribs={'layer': 'STIFF'})
        fn = r.choice(['deck_plan.dxf', 'plan.dxf', 'structure_plan.dxf'])
        doc.saveas(os.path.join(work, fn))
        t = r.choice([10, 12, 14])
        size = r.choice([200, 250, 300])
        m, c = step('drawing_to_3d', {'file': fn, 'z': 0.0, 't_plate': t, 'mesh': True, 'element_size': size})
        rep = m['report']
        mm = m.get('mesh') or {}
        ans = (f"From {fn}: {rep['outlines']} outline, {rep['openings']} opening(s), {rep['webs']} girder web(s) and {rep['stiffeners']} stiffener(s) -> {m['plates']} plates and {m['beams']} beams, plate thickness {t} mm. "
               f"STEP: {m.get('step')}." + (f" FE mesh: {mm.get('nodes')} nodes, {mm.get('elements')} elements, element size {size} mm." if mm else '') + f" Layers read: DECK (outline), OPENING, GIRDER and FRAME (webs), STIFF (stiffeners).")
        return [U(f'Make a 3D model and an FE mesh from the structural plan {fn}: deck plate {t} mm, element size {size} mm.')] + c + [A(ans)]

    def dims():
        doc = ezdxf.new('R2010')
        msp = doc.modelspace()
        n, p = r.choice([6, 8, 12, 24]), r.choice([100.0, 101.6, 150.0, 200.0])
        good = [f'{n} x {p} = {n * p:g}', f'{r.choice([4, 5, 6])} @ 800 = {r.choice([4, 5, 6]) * 800}', '1200 + 800 = 2000']
        # make the second one consistent: recompute with the same count
        k = r.choice([4, 5, 6])
        good[1] = f'{k} @ 800 = {k * 800}'
        bad = r.choice([f'{k} @ 600 = {k * 600 + 100}', f'900 + 450 = 1250', f'{n} x {p} = {n * p + 10:g}'])
        texts = good + [bad]
        r.shuffle(texts)
        for i, t_ in enumerate(texts):
            msp.add_text(t_, dxfattribs={'height': 25, 'insert': (100, 100 + i * 80)})
        fn = r.choice(['frame_spacing.dxf', 'dimensions.dxf'])
        doc.saveas(os.path.join(work, fn))
        m, c = step('drawing_check', {'file': fn})
        return [U(f'Check the dimension arithmetic written on {fn}.')] + c + [A(f"Checked {fn}: {m.get('plain_english') or json.dumps({k: v for k, v in m.items() if k in ('checked', 'wrong')})[:400]}")]

    gens = [(plan, 4), (dims, 3)]
    pool = [g for g, w in gens for _ in range(w)]
    rows, kinds, tries = [], {}, 0
    while len(rows) < a.n and tries < a.n * 4:
        tries += 1
        g = r.choice(pool)
        try:
            m = g()
        except Exception as e:
            print('skip', g.__name__, type(e).__name__, str(e)[:140])
            continue
        if not m:
            continue
        kinds[g.__name__] = kinds.get(g.__name__, 0) + 1
        rows.append({'task': 'missing3_' + g.__name__, 'messages': m})
    s = json.dumps(rows).replace(work, 'C:/work')
    rows = json.loads(s)
    for x in rows:
        roles = [m['role'] for m in x['messages']]
        assert all(p != q for p, q in zip(roles, roles[1:])), (x['task'], roles)
    assert '/tmp/' not in s and '/home/' not in s and '/root/' not in s and 'sb_m3_' not in s
    shutil.rmtree(work, ignore_errors=True)
    with gzip.open(a.out, 'wt', encoding='utf-8') as fh:
        for x in rows:
            fh.write(json.dumps(x) + '\n')
    print(a.out, len(rows), kinds)


if __name__ == '__main__':
    main()
