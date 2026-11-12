"""
Flow / FSI training samples from real runs of the elmer_flow tool (Elmer FEM): rigid and flexible plates in a channel, laminar and SST turbulence,
unconverged steady runs, missing inputs, and what it does not cover.

    python training/elmer_tasks.py --n 30 --out training/data/elmer_train.jsonl.gz      (needs ElmerSolver; ELMER_HOME or PATH)
"""
import argparse, gzip, json, os, random, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=30)
    ap.add_argument('--out', default=os.path.join(HERE, 'data', 'elmer_train.jsonl.gz'))
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    from shipbrain import agent, knowledge
    from make_dataset import tool_block, result_msg
    r = random.Random(a.seed)
    work = tempfile.mkdtemp(prefix='sb_el_')
    T = agent.Tools(work, knowledge.load(None))
    U = lambda t: {'role': 'user', 'content': t}
    A = lambda t: {'role': 'assistant', 'content': t}

    def run(q, args, pre=''):
        res = T.call('elmer_flow', args)
        if 'error' in res:
            return None
        return [U(q), A(pre + tool_block('elmer_flow', args)), result_msg('elmer_flow', res), A(res['plain_english'])]

    def rigid():
        h, v = r.choice([0.3, 0.4, 0.5]), r.choice([0.005, 0.01, 0.015])
        q = f'Oil flows at {v} m/s past a rigid plate {h * 1000:g} mm high standing in a 1 m deep channel. What pressure and drag does the plate get?'
        return run(q, {'velocity': v, 'fluid': 'oil', 'plate_h': h, 'plate': 'rigid', 'cell': 0.04, 'name': 'rigid'})

    def elastic():
        mat, v = r.choice(['rubber', 'plastic']), r.choice([0.01, 0.02])
        q = f'Show me what the flow does to a flexible {mat} plate: oil at {v} m/s in a 1 m channel, plate 400 mm high and 40 mm thick, clamped at the bottom. Stress and deflection please'
        return run(q, {'velocity': v, 'fluid': 'oil', 'plate_h': 0.4, 'plate_t': 0.04, 'plate': 'elastic', 'material': mat, 'cell': 0.05, 'name': 'fsi'})

    def turbulent():
        q = 'Water at 1 m/s hits a plate 0.4 m high in a 1 m channel. Pressure distribution and drag with turbulence'
        return run(q, {'velocity': 1.0, 'fluid': 'water', 'plate_h': 0.4, 'plate_t': 0.04, 'length': 4.0, 'plate_x': 1.0, 'turbulence': 'sst', 'cell': 0.05, 'name': 'turb'})

    def ask():
        q = r.choice(['Run a CFD on my plate', 'Do an FSI analysis of the plate in the current', 'What does the flow do to the plate?'])
        return [U(q), A('Sure. I need the fluid (water, seawater, air or oil) and the speed in m/s, the plate height and thickness, the channel height and length, and whether '
                        'the plate is rigid or flexible - for a flexible one its material (steel, aluminium, rubber, plastic) or Young\'s modulus. I draw the plate as a section in '
                        'a 2D channel; I can then show pressure, velocity, and for a flexible plate the deflection and stress.')]

    def limits():
        q = r.choice(['Can you run the flow around my ship hull in waves?', 'Do a 3D CFD of the bent plate in 1 m/s water and give me the stress', 'Simulate the free surface and wave loads on the plate'])
        return [U(q), A('Not with this tool. ShipBrain\'s flow solver (Elmer) is set up for a plate standing in a 2D channel: laminar or SST k-omega flow, rigid or flexible plate (two-way FSI). '
                        '3D flow around a part from a STEP file, a free water surface, waves and ship hulls with seakeeping are not covered yet. What I can do now: the 2D section '
                        'of the plate in the flow, or a pressure load from the dynamic pressure (0.5 x density x speed squared) put on the plate in the structural model - an estimate, not CFD.')]

    gens = [(rigid, 4), (elastic, 4), (turbulent, 1), (ask, 1), (limits, 2)]
    pool = [g for g, w in gens for _ in range(w)]
    rows, kinds, tries = [], {}, 0
    while len(rows) < a.n and tries < a.n * 5:
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
        rows.append({'task': 'elmer_' + g.__name__, 'messages': m})
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
