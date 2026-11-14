"""
ReverseCAD training samples: real conversions, not invented answers. Random parts are modelled with CadQuery (plates
with holes, fillets, flanges, brackets, bosses, tubes), exported as STL, converted by ReverseCAD (vendor/reverse-cad,
PolyForm Noncommercial - ShipBrain is non-commercial), and the question -> reverse_cad tool call -> result ->
plain answer conversation is written. Needs Node.js (run where it is installed; the result is committed).

    python training/reversecad_tasks.py --n 80 --out training/data/reversecad_train.jsonl.gz
"""
import argparse, gzip, json, os, random, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

ASK = ['Convert {f} to STEP', 'I have a scanned part {f} - make a CAD solid from it', 'Reverse engineer {f}',
       '{f} is a 3D-print file. Give me a STEP and its holes and fillets', 'What features are in {f}? Also make a STEP.',
       '{f} ko STEP me convert karo', 'Turn the mesh {f} into a solid model and check it']
MAT_ASK = [' It is {m}.', ' Material {m}, what does it weigh?', ' Made of {m}.']


def part(r):
    import cadquery as cq
    kind = r.choice(['plate', 'bracket', 'flange', 'boss', 'tube', 'block'])
    if kind == 'plate':
        L, B, t = r.choice([80, 100, 120, 150]), r.choice([40, 60, 80]), r.choice([6, 8, 10, 12])
        w = cq.Workplane().box(L, B, t)
        n = r.choice([2, 4])
        pts = [(-L / 2 + 15, -B / 2 + 12), (L / 2 - 15, B / 2 - 12)] if n == 2 else \
              [(x, y) for x in (-L / 2 + 15, L / 2 - 15) for y in (-B / 2 + 12, B / 2 - 12)]
        w = w.faces('>Z').workplane().pushPoints(pts).hole(r.choice([6.6, 9, 11, 13.5]))
        if r.random() < 0.6:
            w = w.edges('|Z').fillet(r.choice([3, 5, 8]))
    elif kind == 'bracket':
        a, t, w_ = r.choice([40, 50, 60]), r.choice([5, 6, 8]), r.choice([30, 40])
        w = cq.Workplane('XZ').polyline([(0, 0), (a, 0), (a, t), (t, t), (t, a), (0, a)]).close().extrude(w_)
        w = w.faces('<Z').workplane().center(a / 2, -w_ / 2).hole(r.choice([6.6, 9]))
    elif kind == 'flange':
        D, t, d = r.choice([80, 100, 120]), r.choice([10, 12, 16]), r.choice([30, 40, 50])
        w = cq.Workplane().circle(D / 2).circle(d / 2).extrude(t)
        w = w.faces('>Z').workplane().polarArray(D / 2 - 10, 0, 360, r.choice([4, 6, 8])).hole(r.choice([9, 11]))
    elif kind == 'boss':
        w = cq.Workplane().box(60, 60, 10).faces('>Z').workplane().circle(r.choice([10, 12, 15])).extrude(r.choice([10, 15, 20]))
        w = w.faces('>Z').workplane().hole(r.choice([6, 8, 10]))
    elif kind == 'tube':
        D, t, L = r.choice([30, 40, 60]), r.choice([3, 4, 5]), r.choice([60, 100, 150])
        w = cq.Workplane().circle(D / 2).circle(D / 2 - t).extrude(L)
    else:
        w = cq.Workplane().box(r.choice([50, 70]), r.choice([40, 50]), r.choice([20, 30]))
        if r.random() < 0.5:
            w = w.edges().chamfer(r.choice([1, 2]))
        w = w.faces('>Z').workplane().rect(20, 10).cutBlind(-8)
    return kind, w


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=80)
    ap.add_argument('--out', default=os.path.join(HERE, 'data', 'reversecad_train.jsonl.gz'))
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    import cadquery as cq
    from shipbrain import agent, knowledge
    from make_dataset import tool_block, result_msg
    r = random.Random(a.seed)
    work = tempfile.mkdtemp(prefix='sb_rc_')
    T = agent.Tools(work, knowledge.load(None))
    rows = []
    try:
        for k in range(a.n):
            kind, w = part(r)
            f = f'{kind}_{k:03d}.stl'
            cq.exporters.export(w, os.path.join(work, f), tolerance=r.choice([0.02, 0.05, 0.1]), angularTolerance=0.1)
            args = {'file': f}
            q = r.choice(ASK).format(f=f)
            if r.random() < 0.5:
                m = r.choice(['steel', 'aluminum', 'pla', 'petg', 'abs'])
                args['material'] = m
                q = q.rstrip('.?') + '.' if not q.endswith(('.', '?')) else q
                q += r.choice(MAT_ASK).format(m={'aluminum': 'aluminium'}.get(m, m))
            out = T.call('reverse_cad', args)
            if 'error' in out:
                print('skip', f, out['error'][:200])
                continue
            rows.append({'task': 'reverse_cad', 'messages': [
                {'role': 'user', 'content': q}, {'role': 'assistant', 'content': tool_block('reverse_cad', args)},
                result_msg('reverse_cad', out), {'role': 'assistant', 'content': out['plain_english']}]})
    finally:
        shutil.rmtree(work, ignore_errors=True)
    s = json.dumps(rows)
    assert '/tmp/' not in s and work not in s, 'local paths leaked into the samples'
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with gzip.open(a.out, 'wt', encoding='utf-8') as fh:
        for x in rows:
            fh.write(json.dumps(x) + '\n')
    print(a.out, len(rows), 'samples')


if __name__ == '__main__':
    main()
