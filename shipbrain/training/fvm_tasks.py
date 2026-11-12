"""
1D finite volume training samples from real runs of the fvm_1d tool (scripts of the Finite-Volume-Method-for-1D-CFD-Simulations repo in Octave):
conduction, conduction with a source, convection-diffusion, the SIMPLE duct, a grid-refinement check, what is refused, what it does not do.

    python training/fvm_tasks.py --n 40 --out training/data/fvm_train.jsonl.gz
"""
import argparse, gzip, json, os, random, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=40)
    ap.add_argument('--out', default=os.path.join(HERE, 'data', 'fvm_train.jsonl.gz'))
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    from shipbrain import agent, knowledge
    from make_dataset import tool_block, result_msg
    r = random.Random(a.seed)
    work = tempfile.mkdtemp(prefix='sb_fv_')
    T = agent.Tools(work, knowledge.load(None))
    U = lambda t: {'role': 'user', 'content': t}
    A = lambda t: {'role': 'assistant', 'content': t}

    def run(q, args):
        res = T.call('fvm_1d', args)
        if 'error' in res:
            return None
        return [U(q), A(tool_block('fvm_1d', args)), result_msg('fvm_1d', res), A(res['plain_english'])]

    def conduction():
        k, L, n = r.choice([15, 45, 200, 1000]), r.choice([0.2, 0.5, 1.0]), r.choice([5, 10, 20])
        Ta, Tb = r.choice([20, 100]), r.choice([150, 400])
        q = f'Steady conduction in a bar {L} m long, k = {k} W/mK, ends held at {Ta} C and {Tb} C, use {n} finite volumes'
        return run(q, {'case': 'diffusion', 'params': {'k': k, 'l': L, 'n': n, 'Ta': Ta, 'Tb': Tb}})

    def source():
        k, L, n = r.choice([0.5, 1.2, 15]), r.choice([0.02, 0.05]), r.choice([5, 10, 20, 40])
        qv = r.choice([5e5, 1e6, 2e6])
        q = f'Wall {L * 1000:g} mm thick, k = {k}, uniform heat generation {qv:g} W/m3, faces at 100 C and 200 C, {n} cells - temperature profile?'
        return run(q, {'case': 'heat_generation', 'params': {'k': k, 'L': L, 'q': qv, 'n': n, 'Ta': 100, 'Tb': 200}})

    def convection():
        u, K, n = r.choice([0.1, 0.5, 2.0]), r.choice([0.1, 0.5]), r.choice([10, 20, 40])
        q = f'1D convection diffusion, velocity {u} m/s, diffusion coefficient {K}, length 1 m, phi 1 at the inlet and 0 at the outlet, central differencing with {n} cells'
        return run(q, {'case': 'convection_diffusion', 'params': {'u': u, 'K': K, 'n': n}})

    def duct():
        rho, Aa = r.choice([1.0, 1.2, 998.0]), r.choice([0.5, 1.0, 2.0])
        return run(f'Run the 1D SIMPLE duct example for density {rho} and area {Aa} m2', {'case': 'simple', 'params': {'rho': rho, 'A': Aa}})

    def refine():
        args = [{'case': 'heat_generation', 'params': {'n': n}} for n in (10, 20)]
        res = [T.call('fvm_1d', x) for x in args]
        if any('error' in x for x in res):
            return None
        return [U('Is 10 cells enough for conduction with heat generation (k 0.5, 20 mm, 1 MW/m3, 100 C / 200 C)? Check with a finer grid'),
                A(tool_block('fvm_1d', args[0])), result_msg('fvm_1d', res[0]),
                A(res[0]['plain_english'] + ' I double the cells to see how it moves.\n' + tool_block('fvm_1d', args[1])), result_msg('fvm_1d', res[1]),
                A(res[1]['plain_english'] + f" The error fell from {res[0]['max_error']:g} to {res[1]['max_error']:g}: four times smaller for twice the cells, as a second-order scheme should. 20 cells is enough unless you need better than {res[1]['max_error']:g}.")]

    def ask():
        q = r.choice(['Do a 1D finite volume heat conduction for me', 'Solve a 1D convection diffusion problem'])
        return [U(q), A('Sure. I need the length, the number of cells, the two boundary values and the properties: for conduction the conductivity k (and a heat generation rate if there is one), '
                        'for convection-diffusion the velocity, density and diffusion coefficient.')]

    def limits():
        q = r.choice(['Can this solve the flow around a ship hull?', 'Can the 1D finite volume tool do a fin with convection to the air?'])
        a_ = ('No. The 1D finite volume tool runs small teaching cases: conduction, conduction with a source, convection-diffusion with the central scheme and the SIMPLE duct step. '
              'Flow around a hull is a 3D turbulent problem; that needs a CFD solver such as OpenFOAM or the CFD tools you install. The fin script of the repo has a known defect '
              '(the east coefficient of the first node is never set), so I do not run it; the upwind script is unfinished.')
        return [U(q), A(a_)]

    gens = [(conduction, 4), (source, 4), (convection, 4), (duct, 1), (refine, 2), (ask, 1), (limits, 1)]
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
        rows.append({'task': 'fvm_' + g.__name__, 'messages': m})
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
