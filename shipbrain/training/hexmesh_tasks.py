"""
Hex-mesher training samples from real runs: solid parts (blocks, plates with holes, flanges, L brackets, shafts, bosses,
lugs) are written as STEP files, then meshed through the hex_mesh tool. Some requests give the cell size, some do not (the
model reads the part size with file_info and proposes about 1/25 of the largest dimension, saying so). Each question ->
tool call(s) -> result -> plain answer is written.

    python training/hexmesh_tasks.py --n 60 --out training/data/hexmesh_train.jsonl.gz
"""
import argparse, gzip, json, os, random, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)


def part(r, path):
    import cadquery as cq
    kind = r.choice(['block', 'plate_holes', 'flange', 'lbracket', 'shaft', 'boss', 'lug'])
    if kind == 'block':
        w = cq.Workplane().box(r.choice([80, 120, 160]), r.choice([40, 60]), r.choice([30, 40]))
    elif kind == 'plate_holes':
        L, B, t = r.choice([100, 150, 200]), r.choice([60, 80]), r.choice([12, 20, 25])
        w = cq.Workplane().box(L, B, t).faces('>Z').workplane().pushPoints([(-L / 4, 0), (L / 4, 0)]).hole(r.choice([16, 20, 24]))
    elif kind == 'flange':
        w = cq.Workplane().circle(r.choice([60, 80])).circle(r.choice([20, 25])).extrude(r.choice([15, 20])).faces('>Z').workplane() \
            .polarArray(r.choice([45, 60]), 0, 360, r.choice([4, 6])).hole(r.choice([10, 12]))
    elif kind == 'lbracket':
        a, t, w_ = r.choice([70, 90]), r.choice([14, 18]), r.choice([40, 50])
        w = cq.Workplane('XZ').polyline([(0, 0), (a, 0), (a, t), (t, t), (t, a), (0, a)]).close().extrude(w_)
    elif kind == 'shaft':
        w = cq.Workplane().cylinder(r.choice([120, 160]), r.choice([15, 20])).faces('>Z').workplane().cylinder(r.choice([20, 30]), r.choice([25, 30]), combine='a') \
            if False else cq.Workplane().cylinder(r.choice([120, 160]), r.choice([15, 20]))
    elif kind == 'boss':
        w = cq.Workplane().box(80, 80, 15).faces('>Z').workplane().circle(r.choice([20, 25])).extrude(r.choice([20, 30])).faces('>Z').workplane().hole(r.choice([12, 16]))
    else:
        w = cq.Workplane('XZ').rect(r.choice([80, 100]), r.choice([40, 50])).extrude(r.choice([15, 20])).faces('>Y').workplane().hole(r.choice([20, 24]))
    cq.exporters.export(w, path)
    return kind


ASK_SIZE = ['Hex mesh {f} with {s:g} mm cells', 'Make a brick mesh of {f}, cell size {s:g} mm', '{f}: hexahedral mesh, {s:g} mm please',
            '{f} ka hex mesh banao, {s:g} mm element size']
NO_SIZE = ['Hex mesh {f} for FEA', 'I need a hexahedral mesh of the casting {f}', 'Brick mesh for {f}, you choose the size',
           '{f} ko hex mesh karo']


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=60)
    ap.add_argument('--out', default=os.path.join(HERE, 'data', 'hexmesh_train.jsonl.gz'))
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    from shipbrain import agent, knowledge
    from make_dataset import tool_block, result_msg
    r = random.Random(a.seed)
    work = tempfile.mkdtemp(prefix='sb_hx_')
    T = agent.Tools(work, knowledge.load(None))
    rows = []
    try:
        for i in range(a.n):
            f = r.choice(['casting', 'foundation_block', 'bracket', 'flange_part', 'lug', 'shaft_seat']) + f'_{i:03d}.step'
            kind = part(r, os.path.join(work, f))
            info = T.call('file_info', {'file': f})
            if 'error' in info:
                continue
            big = max(info['bbox'])
            to = r.choice(['inp', 'inp', 'bdf', 'fem'])
            if r.random() < 0.5:
                s = r.choice([x for x in (2, 2.5, 3, 4, 5, 6, 8, 10) if big / x <= 60] or [big / 30])
                q = r.choice(ASK_SIZE).format(f=f, s=s)
                msgs = [{'role': 'user', 'content': q}]
            else:
                s = max(1.0, round(big / 25 * 2) / 2)
                q = r.choice(NO_SIZE).format(f=f)
                fi = {'file': f}
                msgs = [{'role': 'user', 'content': q}, {'role': 'assistant', 'content': tool_block('file_info', fi)}, result_msg('file_info', info)]
            args = {'file': f, 'size': s}
            if to != 'inp':
                args['to'] = to
                q += f' ({to})'
                msgs[0]['content'] = q
            out = T.call('hex_mesh', args)
            if 'error' in out:
                print('skip', out['error'][:150])
                continue
            pre = '' if len(msgs) == 1 else f'The part is {info["bbox"][0]} x {info["bbox"][1]} x {info["bbox"][2]} mm; I take a cell size of {s:g} mm (about 1/25 of the largest dimension) - tell me if you want it finer. '
            msgs += [{'role': 'assistant', 'content': (pre + '\n' if pre else '') + tool_block('hex_mesh', args)}, result_msg('hex_mesh', out),
                     {'role': 'assistant', 'content': out['plain_english']}]
            rows.append({'task': 'hex_mesh', 'messages': msgs})
    finally:
        shutil.rmtree(work, ignore_errors=True)
    for x in rows:
        roles = [m['role'] for m in x['messages']]
        assert all(p != q for p, q in zip(roles, roles[1:])), roles
    s = json.dumps(rows)
    assert '/tmp/' not in s and '/home/' not in s, 'local paths leaked'
    with gzip.open(a.out, 'wt', encoding='utf-8') as fh:
        for x in rows:
            fh.write(json.dumps(x) + '\n')
    print(a.out, len(rows), 'samples')


if __name__ == '__main__':
    main()
