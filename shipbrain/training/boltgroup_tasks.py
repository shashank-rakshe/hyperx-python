"""
Bolt-group training samples from real runs of the bolt_group tool (EZbolt): bolts as a grid or a list, loads in kN / tonnes / kip with an
eccentricity, bolt given by size and class or by its resistance, concentric loads (no torsion), missing inputs asked for, and
overloaded groups explained.

    python training/boltgroup_tasks.py --n 60 --out training/data/boltgroup_train.jsonl.gz
"""
import argparse, gzip, json, os, random, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=60)
    ap.add_argument('--out', default=os.path.join(HERE, 'data', 'boltgroup_train.jsonl.gz'))
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    from shipbrain import agent, knowledge
    from make_dataset import tool_block, result_msg
    import tempfile
    r = random.Random(a.seed)
    T = agent.Tools(tempfile.mkdtemp(prefix='sb_bg_'), knowledge.load(None))
    U = lambda t: {'role': 'user', 'content': t}
    A = lambda t: {'role': 'assistant', 'content': t}
    rows, kinds = [], {}

    def layout():
        nx, ny = r.choice([1, 2, 2, 3]), r.choice([2, 3, 3, 4, 5])
        pitch = r.choice([60, 70, 75, 80, 90, 100])
        gauge = r.choice([60, 80, 90, 100, 120])
        grid = {'width': gauge * (nx - 1) if nx > 1 else 0.0, 'height': pitch * (ny - 1), 'nx': nx, 'ny': ny}
        if nx == 1:
            bolts = [[0, k * pitch] for k in range(ny)]
            return None, bolts, f'{ny} bolts in one vertical line at {pitch} mm pitch'
        return grid, None, f'{nx} columns x {ny} rows of bolts, gauge {gauge} mm, pitch {pitch} mm'

    def build(args, q, ans_prefix=''):
        res = T.call('bolt_group', args)
        if 'error' in res:
            return None
        return [U(q), A(ans_prefix + tool_block('bolt_group', args)), result_msg('bolt_group', res), A(res['plain_english'])]

    def eccentric():
        grid, bolts, desc = layout()
        P = r.choice([40, 60, 80, 100, 150, 200])
        e = r.choice([80, 100, 120, 150, 200, 250])
        d, cls = r.choice([16, 20, 20, 24]), r.choice(['8.8', '8.8', '10.9'])
        q = r.choice([f'Bracket with {desc}, M{d} {cls}. Load {P} kN downward at {e} mm from the bolt group centre. Does it hold?',
                      f'{desc.capitalize()} - M{d}-{cls}. {P} kN vertical, eccentricity {e} mm. Bolt group check',
                      f'Eccentric load {P} kN, arm {e} mm on {desc} (M{d} {cls}): bolt forces?'])
        args = {'vy': -float(P), 'ex': float(e), 'd': d, 'cls': cls}
        args.update({'grid': grid} if grid else {'bolts': bolts})
        return build(args, q)

    def concentric():
        grid, bolts, desc = layout()
        P = r.choice([30, 50, 90, 140])
        q = f'{desc.capitalize()}, M20 8.8. A pure shear of {P} kN through the centre of the group. Bolt check?'
        args = {'vy': -float(P), 'd': 20, 'cls': '8.8'}
        args.update({'grid': grid} if grid else {'bolts': bolts})
        return build(args, q)

    def units():
        grid, bolts, desc = layout()
        kip = r.choice([10, 20, 30, 45])
        ein = r.choice([4, 6, 8])
        kn, emm = round(kip * 4.4482216, 1), round(ein * 25.4, 1)
        q = f'{desc.capitalize()}. Load {kip} kip at {ein} inch eccentricity, bolt shear capacity 17.9 kip each'
        args = {'vy': -kn, 'ex': emm, 'capacity_kn': round(17.9 * 4.4482216, 1)}
        args.update({'grid': grid} if grid else {'bolts': bolts})
        return build(args, q, '(Converting: 1 kip = 4.448 kN, 1 in = 25.4 mm.) ')

    def horizontal():
        grid, bolts, desc = layout()
        P, e = r.choice([40, 80, 120]), r.choice([100, 150, 200])
        q = f'{desc.capitalize()}, M20 8.8. A horizontal force of {P} kN acts {e} mm above the centre of the group. Check'
        args = {'vx': float(P), 'ey': float(e), 'd': 20, 'cls': '8.8'}
        args.update({'grid': grid} if grid else {'bolts': bolts})
        return build(args, q)

    def tonnes():
        grid, bolts, desc = layout()
        t, e = r.choice([5, 8, 12, 20]), r.choice([100, 150, 200])
        q = f'{desc.capitalize()}, M24 8.8. Hanging load {t} tonnes, {e} mm eccentric. Bolts ok?'
        args = {'vy': -round(t * 9.80665, 1), 'ex': float(e), 'd': 24, 'cls': '8.8'}
        args.update({'grid': grid} if grid else {'bolts': bolts})
        return build(args, q, f'(Converting: {t} t x 9.807 = {t * 9.80665:.1f} kN.) ')

    def ask():
        q = r.choice(['Check my bolt group', 'Eccentric bolted bracket, is it OK?', 'How much load can my 6 bolt connection take?'])
        return [U(q), A('Sure. Please give me: the bolt layout (for example 2 columns x 3 rows with gauge 80 mm and pitch 70 mm, or the bolt positions), the bolt '
                        'size and class (for example M20 8.8) or the shear resistance of one bolt, the load in kN, and how far from the centre of the bolt group '
                        'it acts (the eccentricity in mm). I check bolt shear with the elastic and the AISC instant-centre method.')]

    gens = [(eccentric, 8), (concentric, 2), (units, 3), (horizontal, 2), (tonnes, 2), (ask, 1)]
    pool = [g for g, w in gens for _ in range(w)]
    while len(rows) < a.n:
        g = r.choice(pool)
        try:
            m = g()
        except Exception as e:
            print('skip', g.__name__, type(e).__name__, str(e)[:100])
            continue
        if not m:
            continue
        kinds[g.__name__] = kinds.get(g.__name__, 0) + 1
        rows.append({'task': 'boltgroup_' + g.__name__, 'messages': m})
    s = json.dumps(rows)
    assert '/tmp/' not in s and '/home/' not in s
    with gzip.open(a.out, 'wt', encoding='utf-8') as fh:
        for x in rows:
            fh.write(json.dumps(x) + '\n')
    print(a.out, len(rows), kinds)


if __name__ == '__main__':
    main()
