"""
Standard-part training samples from real runs of the standard_part tool (BOLTS tables): bolt, nut, washer, rolled section, pipe questions
in plain words, sizes missing or not in the table, and what the tables do not contain.

    python training/parts_tasks.py --n 50 --out training/data/parts_train.jsonl.gz
"""
import argparse, gzip, json, os, random, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=50)
    ap.add_argument('--out', default=os.path.join(HERE, 'data', 'parts_train.jsonl.gz'))
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    from shipbrain import agent, knowledge
    from make_dataset import tool_block, result_msg
    r = random.Random(a.seed)
    work = tempfile.mkdtemp(prefix='sb_pt_')
    T = agent.Tools(work, knowledge.load(None))
    U = lambda t: {'role': 'user', 'content': t}
    A = lambda t: {'role': 'assistant', 'content': t}

    def one(q, args):
        res = T.call('standard_part', args)
        if 'error' in res:
            return None
        return [U(q), A(tool_block('standard_part', args)), result_msg('standard_part', res), A(res['plain_english'])]

    def bolt():
        d, l = r.choice([8, 10, 12, 16, 20, 24, 30]), r.choice([30, 40, 50, 60, 80, 100])
        std = r.choice(['ISO 4017', 'DIN 933', 'ISO 4014', 'DIN 931'])
        q = r.choice([f'What is the head size and height of an {std} M{d} x {l} bolt?', f'Spanner size for M{d} hex bolt {std} length {l}',
                      f'Dimensions of hexagon screw {std} M{d} length {l} mm'])
        return one(q, {'query': f'hex bolt {std} M{d} length {l}'})

    def nut():
        d = r.choice([12, 16, 20, 24, 30])
        return one(r.choice([f'Nut height and across flats for M{d} hex nut ISO 4032?', f'M{d} nut dimensions ISO 4032']), {'query': f'hex nut ISO 4032 M{d}'})

    def washer():
        d = r.choice([10, 12, 16, 20, 24])
        return one(r.choice([f'Outer diameter and thickness of an M{d} plain washer ISO 7089', f'M{d} washer size']), {'query': f'plain washer ISO 7089 M{d}'})

    def section():
        s = r.choice(['IPE200', 'IPE240', 'IPE300', 'IPE400', 'IPE500', 'HEA200', 'HEA300', 'HEB200', 'HEB300', 'HEB400', 'HEM300'])
        q = r.choice([f'Dimensions of {s}', f'{s} flange and web thickness?', f'Give me the section properties of {s}', f'What is the depth and width of an {s[:3]} {s[3:]}?'])
        return one(q, {'query': s})

    def pipe():
        n = r.choice(['NPS 2', 'NPS 3', 'NPS 4', 'NPS 6', 'NPS 8', 'NPS 10'])
        return one(r.choice([f'Outside diameter and wall of {n} schedule 40 pipe', f'{n} pipe size ASME B36.10']), {'query': 'ASME B36.10M nominal pipe', 'size': n})

    def ask_size():
        std = r.choice(['ISO 4017 hex bolt', 'ISO 4032 hex nut', 'ISO 7089 washer', 'IPE section'])
        q = f'Give me the dimensions of the {std}'
        res = T.call('standard_part', {'query': std})
        if 'matches' not in res:
            return None
        return [U(q), A(tool_block('standard_part', {'query': std})), result_msg('standard_part', res), A(res['plain_english'])]

    def not_in_table():
        q = 'Dimensions of an ISO 4017 M99 bolt'
        args = {'query': 'hex bolt ISO 4017 M99'}
        res = T.call('standard_part', args)
        if 'error' not in res:
            return None
        return [U(q), A(tool_block('standard_part', args)), result_msg('standard_part', res),
                A(res['error'] + '. I will not guess a value: tell me the nearest standard size you want, or give me the dimensions from your own drawing.')]

    def limits():
        q = r.choice(['What is the tensile strength of a grade 8.8 M20 bolt?', 'Is IPE300 enough for a 6 m span?'])
        return [U(q), A('The standard-part tables give dimensions only (head size, section depth, wall thickness), not strength or loading. For bolt resistance use the '
                        'connection check (steel_connection) with the bolt class; for a beam I need the span, the load and the support conditions and then use the frame or '
                        'beam check - I will take the section dimensions from the tables.')]

    gens = [(bolt, 4), (nut, 2), (washer, 2), (section, 4), (pipe, 2), (ask_size, 1), (not_in_table, 1), (limits, 1)]
    pool = [g for g, w in gens for _ in range(w)]
    rows, kinds, tries = [], {}, 0
    while len(rows) < a.n and tries < a.n * 6:
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
        rows.append({'task': 'parts_' + g.__name__, 'messages': m})
    for x in rows:
        roles = [m['role'] for m in x['messages']]
        assert all(p != q for p, q in zip(roles, roles[1:])), roles
    s = json.dumps(rows)
    assert '/tmp/' not in s and '/home/' not in s
    shutil.rmtree(work, ignore_errors=True)
    with gzip.open(a.out, 'wt', encoding='utf-8') as fh:
        for x in rows:
            fh.write(json.dumps(x) + '\n')
    print(a.out, len(rows), kinds)


if __name__ == '__main__':
    main()
