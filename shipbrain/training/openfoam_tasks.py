"""
OpenFOAM flow training samples from real runs of openfoam_flow and flow_load_stress: plates in water / oil / air, SST turbulence, a STEP part loaded by the flow and
the stress that results, a non-converging laminar request, missing supports asked for, and what is not covered.

    python training/openfoam_tasks.py --n 24 --out training/data/openfoam_train.jsonl.gz      (needs OpenFOAM and CadQuery)
"""
import argparse, gzip, json, os, random, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=24)
    ap.add_argument('--out', default=os.path.join(HERE, 'data', 'openfoam_train.jsonl.gz'))
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    import cadquery as cq
    from shipbrain import agent, knowledge
    from make_dataset import tool_block, result_msg
    r = random.Random(a.seed)
    work = tempfile.mkdtemp(prefix='sb_of_')
    T = agent.Tools(work, knowledge.load(None))
    U = lambda t: {'role': 'user', 'content': t}
    A = lambda t: {'role': 'assistant', 'content': t}

    def call(name, q, args, pre=''):
        res = T.call(name, args)
        if 'error' in res:
            return None
        return [U(q), A(pre + tool_block(name, args)), result_msg(name, res), A(res['plain_english'])]

    def plate_2d():
        h, v = r.choice([0.3, 0.4, 0.5]), r.choice([0.005, 0.01])
        return call('openfoam_flow', f'Oil at {v} m/s past a plate {h * 1000:g} mm high in a 1 m channel - OpenFOAM, drag please',
                    {'velocity': v, 'fluid': 'oil', 'plate_h': h, 'plate_t': 0.04, 'cell': 0.04, 'name': 'plate2d'})

    def part_flow():
        w, d, hh = r.choice([(300, 20, 200), (400, 30, 300)])
        cq.exporters.export(cq.Workplane('XY').box(w, d, hh, centered=(False, False, False)), os.path.join(work, 'part.step'))
        v = r.choice([0.5, 1.0, 2.0])
        q = f'Water at {v} m/s hits part.step (a {w} x {d} x {hh} mm plate). What force does the flow put on it? Use turbulence.'
        return call('openfoam_flow', q, {'velocity': v, 'fluid': 'water', 'body_file': 'part.step', 'length': 4.0, 'height': 1.5, 'width': 2.0, 'plate_x': 1.0,
                                         'turbulence': 'sst', 'cell': 0.05, 'name': 'part'})

    def flow_stress():
        w, d, hh = r.choice([(400, 20, 300), (500, 25, 300)])
        cq.exporters.export(cq.Workplane('XY').box(w, d, hh, centered=(False, False, False)), os.path.join(work, 'blade.step'))
        v = r.choice([0.5, 1.0])
        fix = [{'y': 0, 'dof': '123456'}]
        q = (f'Apply the flow of water at {v} m/s on blade.step ({w} x {d} x {hh} mm, steel, {d} mm thick), fixed at its foot (y = 0), and show me displacement and stress. Make pictures.')
        return call('flow_load_stress', q, {'file': 'blade.step', 'velocity': v, 'fluid': 'water', 'fix': fix, 'thickness_mm': d, 'element_size': 50, 'turbulence': 'sst',
                                           'cell': 0.05, 'name': 'fls'})

    def ask_supports():
        q = r.choice(['Put 1 m/s water on my plate and tell me the stress', 'Flow load on the bent plate, then stress please'])
        return [U(q), A('Sure. I need three things to chain the flow and the structure: the STEP file of the part, how it is supported (for example fixed at one end: which end, '
                        'in the part\'s mm), and its plate thickness. I also take the fluid (water, seawater, air or oil) and the speed. The part stands on the channel floor with the flow '
                        'along +x - tell me if it should be turned. Then I run OpenFOAM, load the shell model with the face forces and solve it with CalculiX.')]

    def laminar_diverges():
        q = 'Laminar steady OpenFOAM flow of water at 1 m/s past a 0.4 m plate'
        args = {'velocity': 1.0, 'fluid': 'water', 'plate_h': 0.4, 'plate_t': 0.04, 'turbulence': 'laminar', 'cell': 0.05, 'name': 'lam'}
        res = T.call('openfoam_flow', args)
        if 'error' not in res:
            return None
        a2 = dict(args, turbulence='sst', length=4.0, plate_x=1.0)
        r2 = T.call('openfoam_flow', a2)
        if 'error' in r2:
            return None
        return [U(q), A(tool_block('openfoam_flow', args)), result_msg('openfoam_flow', res),
                A('The steady laminar solution diverged: at this speed the Reynolds number is about 400 000 and a steady laminar flow does not exist. I rerun it with the SST k-omega turbulence model.\n'
                  + tool_block('openfoam_flow', a2)), result_msg('openfoam_flow', r2), A(r2['plain_english'])]

    def limits():
        q = r.choice(['Can OpenFOAM simulate waves hitting the hull and the ship motions?', 'Do a free surface CFD of the plate going through water'])
        return [U(q), A('Not yet. The OpenFOAM tools here are steady single-phase flow (simpleFoam, laminar or SST k-omega) past a plate or a part standing in a channel. A free water surface, '
                        'waves and ship motions need a two-phase solver (interFoam) and a moving-mesh set-up that I have not built. What I can do: steady flow loads on a part, or an '
                        'estimate from the dynamic pressure 0.5 x density x speed squared.')]

    gens = [(plate_2d, 3), (part_flow, 3), (flow_stress, 4), (ask_supports, 1), (laminar_diverges, 1), (limits, 2)]
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
        rows.append({'task': 'openfoam_' + g.__name__, 'messages': m})
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
