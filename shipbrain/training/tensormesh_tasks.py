"""
TensorMesh training samples from real runs: ship-style topology problems (tripping brackets, end brackets, web-frame
panels, floors with a support, gussets) solved by TensorMesh through the topology tool, and solid cantilevers / blocks
built with ShipBrain's own FEModel solved through tensor_fem. Each question -> tool call -> result -> plain answer is
written. Needs torch + torch-sla + meshio; the result is committed.

    python training/tensormesh_tasks.py --n 40 --solids 15 --out training/data/tensormesh_train.jsonl.gz
"""
import argparse, gzip, json, os, random, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)


def problems(r):
    a = r.choice([300, 400, 500, 600, 800])
    b = r.choice([300, 400, 500, 600])
    F = r.choice([5000, 10000, 20000, 50000])
    vf = r.choice([0.3, 0.4, 0.5, 0.6])
    return r.choice([
        (f'Where should the material be in a {a} x {b} mm bracket welded along its left edge with {F / 1000:g} kN down at the '
         f'bottom-right corner? Keep {vf * 100:.0f} %.', dict(L=a, H=b, fixed=['left'], load_at=[a, 0], force=[0, -F], volfrac=vf)),
        (f'Optimise a {a} x {b} mm end bracket: welded to the bulkhead on the left, {F / 1000:g} kN acting down at the top-right '
         f'tip, use {vf * 100:.0f} % of the plate', dict(L=a, H=b, fixed=['left'], load_at=[a, b], force=[0, -F], volfrac=vf)),
        (f'Lightening holes in a {2 * a} x {b} mm web frame panel supported at both ends, {F / 1000:g} kN in the middle of the '
         f'top edge - where can I cut?', dict(L=2 * a, H=b, fixed=['left', 'right'], load_at=[a, b], force=[0, -F], volfrac=vf)),
        (f'Floor plate {2 * a} x {b} mm on the bottom shell (bottom edge fixed), side load {F / 1000:g} kN at the top-left '
         f'corner - topology with {vf * 100:.0f} % material', dict(L=2 * a, H=b, fixed=['bottom'], load_at=[0, b], force=[F, 0], volfrac=vf)),
        (f'{a} x {b} mm gusset, left edge welded, {F / 1000:g} kN pulling right at the middle of the right edge. Best shape '
         f'with {vf * 100:.0f} % material?', dict(L=a, H=b, fixed=['left'], load_at=[a, b / 2], force=[F, 0], volfrac=vf)),
    ])


def solid(r, path):
    import numpy as np
    from shipbrain.femodel import FEModel
    L, B, H = r.choice([1000, 2000, 3000]), r.choice([100, 200, 300]), r.choice([100, 200, 400])
    nx, ny, nz = 40, max(2, int(B / 50)), max(4, int(H / 25))
    m = FEModel()
    xs, ys, zs = np.linspace(0, L, nx + 1), np.linspace(0, B, ny + 1), np.linspace(0, H, nz + 1)
    idx = lambda i, j, k: 1 + k * (ny + 1) * (nx + 1) + j * (nx + 1) + i
    for k in range(nz + 1):
        for j in range(ny + 1):
            for i in range(nx + 1):
                m.nodes[idx(i, j, k)] = np.array([xs[i], ys[j], zs[k]])
    e = 1
    for k in range(nz):
        for j in range(ny):
            for i in range(nx):
                m.elems[e] = {'type': 'hexa', 'pid': 1, 'group': '1', 'nodes': [idx(i, j, k), idx(i + 1, j, k), idx(i + 1, j + 1, k),
                              idx(i, j + 1, k), idx(i, j, k + 1), idx(i + 1, j, k + 1), idx(i + 1, j + 1, k + 1), idx(i, j + 1, k + 1)]}
                e += 1
    m.props[1] = {'kind': 'solid', 'mid': 1}
    m.mats[1] = {'E': 206000.0, 'nu': 0.3, 'rho': 7.85e-9}
    m.write(path)
    return L, B, H


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=40)
    ap.add_argument('--solids', type=int, default=15)
    ap.add_argument('--out', default=os.path.join(HERE, 'data', 'tensormesh_train.jsonl.gz'))
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    from shipbrain import agent, knowledge
    from make_dataset import tool_block, result_msg
    r = random.Random(a.seed)
    work = tempfile.mkdtemp(prefix='sb_tm_')
    T = agent.Tools(work, knowledge.load(None))
    rows = []

    def add(q, name, args, out, ans):
        rows.append({'task': 'tensormesh', 'messages': [{'role': 'user', 'content': q},
                                                        {'role': 'assistant', 'content': tool_block(name, args)},
                                                        result_msg(name, out), {'role': 'assistant', 'content': ans}]})
    try:
        for i in range(a.n):
            q, args = problems(r)
            args['name'] = f'topology_{i:03d}'
            out = T.call('topology', args)
            if 'error' in out:
                print('skip', out['error'][:200])
                continue
            add(q, 'topology', args, out, out['plain_english'] + f" Picture: {out['png']}.")
        for i in range(a.solids):
            f = f'solid_{i:03d}.inp'
            L, B, H = solid(r, os.path.join(work, f))
            F = r.choice([1e4, 5e4, 1e5])
            q = r.choice([f'Fix the end x = 0 of {f} and push {F / 1000:g} kN down on the far end. How much does it deflect?',
                          f'{f}: cantilever, clamped at x=0, {F / 1000:g} kN in -z at x={L}. Solve it on the GPU if there is one.'])
            args = {'file': f, 'fixed': [{'x': 0}], 'loads': [{'at': {'x': L}, 'force': [0, 0, -F]}]}
            out = T.call('tensor_fem', args)
            if 'error' in out:
                continue
            I = B * H ** 3 / 12
            theory = F * L ** 3 / (3 * 206000 * I) + F * L / (5 / 6 * B * H * 206000 / 2.6)
            d = out['max_displacement']
            ans = out['plain_english'] + (f" Hand check (Euler-Bernoulli + shear): {theory:.3g} mm, so the solid model is "
                                          f"{abs(1 - d / theory) * 100:.0f} % {'stiffer' if d < theory else 'softer'}"
                                          + (' - plain 8-node hexahedra are too stiff in bending on a coarse mesh: refine '
                                             'through the depth or use more elements along the length.' if d < 0.95 * theory else '.'))
            add(q, 'tensor_fem', args, out, ans)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    s = json.dumps(rows)
    assert '/tmp/' not in s and '/home/' not in s, 'local paths leaked into the samples'
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with gzip.open(a.out, 'wt', encoding='utf-8') as fh:
        for x in rows:
            fh.write(json.dumps(x) + '\n')
    print(a.out, len(rows), 'samples')


if __name__ == '__main__':
    main()
