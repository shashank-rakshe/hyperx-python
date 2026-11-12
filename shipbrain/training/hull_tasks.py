"""
Hull design training samples from real runs of hull_generate: a hull from the principal dimensions, a target block coefficient, a bulb, a V-shaped bow, GM with a KG, an unreachable target
explained, an invalid hull refused, a random hull dataset, and what the generator is not.

    python training/hull_tasks.py --n 40 --out training/data/hull_train.jsonl.gz
"""
import argparse, gzip, json, os, random, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=40)
    ap.add_argument('--out', default=os.path.join(HERE, 'data', 'hull_train.jsonl.gz'))
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    from shipbrain import agent, knowledge
    from make_dataset import tool_block, result_msg
    r = random.Random(a.seed)
    work = tempfile.mkdtemp(prefix='sb_hu_')
    T = agent.Tools(work, knowledge.load(None))
    U = lambda t: {'role': 'user', 'content': t}
    A = lambda t: {'role': 'assistant', 'content': t}

    def call(q, args, pre=''):
        res = T.call('hull_generate', args)
        if 'error' in res:
            return None
        return [U(q), A(pre + tool_block('hull_generate', args)), result_msg('hull_generate', res), A(res['plain_english'])]

    def dims():
        L = r.choice([80, 100, 120, 150, 180])
        B = round(L * r.uniform(0.14, 0.19), 1)
        Tt = round(B * r.uniform(0.33, 0.45), 1)
        D = round(Tt * r.uniform(1.3, 1.5), 1)
        return L, B, D, Tt

    def plain():
        L, B, D, Tt = dims()
        return call(f'Make a hull {L} m long, {B} m beam, {D} m deep, {Tt} m draft. Give me the coefficients.', {'L': L, 'B': B, 'D': D, 'T': Tt, 'name': 'hull'})

    def with_cb():
        L, B, D, Tt = dims()
        cb = r.choice([0.65, 0.7, 0.75, 0.8, 0.85])
        return call(f'Design a hull {L} x {B} x {D} m, draft {Tt} m, block coefficient {cb}. Long entrance, 0.3 of the length.',
                    {'L': L, 'B': B, 'D': D, 'T': Tt, 'ent': 0.3, 'run': 0.25, 'target_cb': cb, 'name': 'hull'})

    def bulb():
        L, B, D, Tt = dims()
        return call(f'Same kind of hull, {L} x {B} x {D} m at {Tt} m draft, with a bulbous bow {round(0.03 * L, 1)} m long, {round(0.3 * B, 1)} m wide and {round(0.5 * Tt, 1)} m high. What does it do to the numbers?',
                    {'L': L, 'B': B, 'D': D, 'T': Tt, 'bulb_len': round(0.03 * L, 1), 'bulb_b': round(0.3 * B, 1), 'bulb_h': round(0.5 * Tt, 1), 'bulb_z': round(0.45 * Tt, 1), 'name': 'hull'})

    def gm():
        L, B, D, Tt = dims()
        kg = round(D * r.uniform(0.6, 0.8), 1)
        return call(f'Hull {L} x {B} x {D} m, draft {Tt} m, Cb 0.72, KG {kg} m: what is the GM?', {'L': L, 'B': B, 'D': D, 'T': Tt, 'ent': 0.33, 'run': 0.25, 'target_cb': 0.72, 'kg': kg, 'name': 'hull'})

    def too_low():
        L, B, D, Tt = dims()
        args = {'L': L, 'B': B, 'D': D, 'T': Tt, 'ent': 0.2, 'run': 0.15, 'target_cb': 0.45, 'name': 'hull'}
        res = T.call('hull_generate', args)
        if 'error' not in res:
            return None
        return [U(f'Hull {L} x {B} x {D} m, draft {Tt} m with Cb 0.45 please, entrance 0.2 L and run 0.15 L'), A(tool_block('hull_generate', args)), result_msg('hull_generate', res),
                A('A block coefficient of 0.45 is not possible with these short ends: the tool says what this plan form can reach. A lower Cb needs longer entrance and run (the ends are what tapers the hull), '
                  'a smaller transom, or V-shaped ends. Tell me which you prefer, or what Cb range is realistic for your ship type (0.55 to 0.85 for most cargo ships).')]

    def invalid():
        L, B, D, Tt = dims()
        args = {'L': L, 'B': B, 'D': D, 'T': round(D * 1.3, 1), 'name': 'hull'}
        res = T.call('hull_generate', args)
        if 'error' not in res:
            return None
        return [U(f'Hull {L} x {B} x {D} m with a draft of {args["T"]} m'), A(tool_block('hull_generate', args)), result_msg('hull_generate', res),
                A(f'The draft {args["T"]} m is deeper than the hull ({D} m), so it would sink: the depth must be larger than the draft (add freeboard, usually 20 to 40 % of the draft). Which depth should I use?')]

    def dataset():
        n = r.choice([20, 50, 100])
        return call(f'Make me {n} random ship hulls with their coefficients', {'samples': n, 'name': 'hulls', 'seed': r.randint(1, 99)})

    def limits():
        q = r.choice(['Can you give me a fair lines plan with offsets for the yard?', 'Will this hull meet the class resistance requirement?'])
        return [U(q), A('Not from this tool. The hull generator makes concept hulls: a midship section with tapered ends, bulb and transom, with coefficients, hydrostatics and a surface for flow runs. It is not a faired '
                        'lines plan, so there are no yard offsets, and it makes no resistance or class judgement - for resistance I can run the flow (OpenFOAM) on the surface, or you give me the lines and I check them.')]

    gens = [(plain, 3), (with_cb, 4), (bulb, 3), (gm, 4), (too_low, 1), (invalid, 1), (dataset, 1), (limits, 2)]
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
        rows.append({'task': 'hull_' + g.__name__, 'messages': m})
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
