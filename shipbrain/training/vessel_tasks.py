"""
Hydrostatics training samples from real runs of the ship_hydrostatics tool (Vessel.js): barge and Wigley hulls with weights, a loading change, an unstable case, missing weights asked
for, and what the tool does not do (GZ curve, damage stability).

    python training/vessel_tasks.py --n 40 --out training/data/vessel_train.jsonl.gz      (needs Node.js)
"""
import argparse, gzip, json, os, random, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=40)
    ap.add_argument('--out', default=os.path.join(HERE, 'data', 'vessel_train.jsonl.gz'))
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    from shipbrain import agent, knowledge
    from make_dataset import tool_block, result_msg
    r = random.Random(a.seed)
    work = tempfile.mkdtemp(prefix='sb_vs_')
    T = agent.Tools(work, knowledge.load(None))
    U = lambda t: {'role': 'user', 'content': t}
    A = lambda t: {'role': 'assistant', 'content': t}

    def call(q, args, pre=''):
        res = T.call('ship_hydrostatics', args)
        if 'error' in res:
            return None
        return [U(q), A(pre + tool_block('ship_hydrostatics', args)), result_msg('ship_hydrostatics', res), A(res['plain_english'])]

    def barge():
        L, B, D = r.choice([(24, 8, 3), (30, 8, 4), (40, 12, 4), (60, 16, 5), (80, 20, 6)])
        ls, cargo = r.choice([200, 300, 500, 800, 1200]), r.choice([100, 300, 600, 1000])
        kg_l, kg_c = round(r.uniform(0.45, 0.6) * D, 2), round(r.uniform(0.2, 0.4) * D, 2)
        q = (f'Box barge {L} m x {B} m x {D} m deep. Lightship {ls} t with KG {kg_l} m, cargo {cargo} t with KG {kg_c} m, both amidships. Draft and GM in sea water?')
        args = {'hull': 'box', 'length': L, 'beam': B, 'depth': D,
                'weights': [{'name': 'lightship', 'mass_t': ls, 'cg': [L / 2, 0, kg_l]}, {'name': 'cargo', 'mass_t': cargo, 'cg': [L / 2, 0, kg_c]}]}
        if (ls + cargo) * 1.0 / 1.025 / (L * B) >= D * 0.95:
            return None
        return call(q, args)

    def fresh():
        L, B, D = r.choice([(30, 8, 4), (40, 12, 4)])
        m = r.choice([300, 500, 700])
        q = f'A {L} x {B} x {D} m pontoon weighs {m} t, KG {round(D * 0.4, 2)} m, in a fresh water lake. How deep does it float and what is its GM?'
        if m / 1.0 / (L * B) >= D * 0.95:
            return None
        return call(q, {'hull': 'box', 'length': L, 'beam': B, 'depth': D, 'density': 1000, 'weights': [{'mass_t': m, 'cg': [L / 2, 0, round(D * 0.4, 2)]}]})

    def wigley():
        L, B, D = 30, r.choice([4, 5, 6]), 4.0
        Td = r.choice([2.0, 2.4])
        m = round(4 / 9 * L * B * Td * 1.025, 1)
        kg = round(r.uniform(1.4, 2.2), 2)
        q = f'Wigley hull {L} m long, {B} m beam, {D} m deep, designed for a {Td} m draft, displacement about {m} t with KG {kg} m. Hydrostatics please.'
        return call(q, {'hull': 'wigley', 'length': L, 'beam': B, 'depth': D, 'design_draft': Td, 'weights': [{'mass_t': m, 'cg': [L / 2, 0, kg]}]})

    def unstable():
        L, B, D = 30, 6, 4
        m = 450
        q = f'Barge {L} x {B} x {D} m, total weight {m} t, but the cargo is stacked high so the combined KG is 4.5 m. Is it stable?'
        return call(q, {'hull': 'box', 'length': L, 'beam': B, 'depth': D, 'weights': [{'mass_t': m, 'cg': [L / 2, 0, 4.5]}]})

    def ask():
        q = r.choice(['What is the GM of my barge?', 'Will my pontoon be stable with this load?', 'Give me the draft of the hull for 500 tonnes'])
        return [U(q), A('Sure. I need the hull (length, beam and depth in metres, box shape or its lines), the water (sea 1025 or fresh 1000 kg/m3) and every weight on board as mass in tonnes and centre of gravity '
                        '- x from the aft end, y off the centre line, z above the keel in metres: lightship, cargo, ballast, fuel. Then I get the draft, trim, KB, BM and GM.')]

    def limits():
        q = r.choice(['Give me the full GZ curve and check the IMO intact stability criteria', 'Can you do damage stability with a flooded compartment?'])
        return [U(q), A('Not with this tool. The hydrostatics tool (Vessel.js) gives the draft, trim, KB, BM and GM at small angles. The IMO intact criteria need the complete GZ curve (area under it, '
                        'maximum righting arm and its angle, wind heel) and damage stability needs the flooded compartments modelled - neither is in ShipBrain yet. I can give the initial GM and '
                        'tell you whether it passes the usual 0.15 m minimum, and a hydrostatic table to start a stability booklet.')]

    gens = [(barge, 5), (fresh, 2), (wigley, 2), (unstable, 1), (ask, 1), (limits, 2)]
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
        rows.append({'task': 'vessel_' + g.__name__, 'messages': m})
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
