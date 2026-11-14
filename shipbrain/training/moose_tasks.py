"""
MOOSE check + training samples, made on GitHub (the official MOOSE Docker image runs there; see
.github/workflows/shipbrain-moose.yml):

  --run      inside idaholab/moose: solve plate fields with MOOSE's shell element through shipbrain.moose.plate -
             the published reference (50 m plate of clamped_plate_flat.i, Navier 2.9985e-3 m) and ship plate fields
             (stiffener spacing x span, thickness, sea / tank pressure, simply supported and clamped) - and write
             results.json (every result with its comparison to the Navier series / Roark's clamped coefficients)
  --samples  anywhere: results.json -> question / tool call / result / plain answer conversations (moose_train.jsonl.gz)

Only the standard library is used in --run (the MOOSE image has no extra Python packages).
"""
import argparse, gzip, json, math, os, random, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

# Roark (Table 11.4, case 8a): clamped rectangular plate, uniform q: w_max = alpha q b^4 / (E t^3), b = short side
ROARK_CLAMPED = [(1.0, 0.0138), (1.2, 0.0188), (1.4, 0.0226), (1.6, 0.0251), (1.8, 0.0267), (2.0, 0.0277), (1e9, 0.0284)]


def roark_clamped(a, b, t, E, q):
    a, b = max(a, b), min(a, b)
    r = a / b
    pts = ROARK_CLAMPED[:-1]
    if r >= 2.0:                                         # towards the long-plate limit: linear in b / a
        c = 0.0284 - (0.0284 - 0.0277) * (2.0 / r)
    else:
        c = next(c0 + (c1 - c0) * (r - r0) / (r1 - r0) for (r0, c0), (r1, c1) in zip(pts, pts[1:]) if r <= r1)
    return c * q * b ** 4 / (E * t ** 3)


def cases(n, seed):
    r = random.Random(seed)
    out = [dict(a=50.0, b=50.0, t=1.0, q=10.816, E=1e9, nu=0.3, clamped=False, n=20, ref='MOOSE test clamped_plate_flat.i')]
    for _ in range(n):
        s = r.choice([600, 650, 700, 750, 800, 850, 900])                 # stiffener spacing (short side), mm
        span = r.choice([1600, 2000, 2400, 2800, 3200, 3600])               # frame / web spacing, mm
        t = r.choice([8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 20])
        q = r.choice([0.02, 0.03, 0.05, 0.08, 0.1, 0.15, 0.2])              # MPa (2-20 m of water head)
        out.append(dict(a=float(span), b=float(s), t=float(t), q=q, E=206000.0, nu=0.3, clamped=r.random() < 0.4))
    return out


def do_run(n, seed, out):
    from shipbrain import moose
    work = os.path.abspath('moose_runs')
    os.makedirs(work, exist_ok=True)
    res = []
    for k, c in enumerate(cases(n, seed)):
        t0 = time.time()
        try:
            r = moose.plate(c['a'], c['b'], c['t'], c['q'], E=c['E'], nu=c['nu'], clamped=c['clamped'], n=c.get('n'),
                            workdir=work, name=f'plate_{k:03d}')
            r = {k2: v for k2, v in r.items() if k2 not in ('input', 'mesh')}
            if c['clamped']:
                w_r = roark_clamped(c['a'], c['b'], c['t'], c['E'], c['q'])
                r['roark_clamped'] = w_r
                r['difference_percent'] = round(100 * (r['max_deflection'] - w_r) / w_r, 2)
                r['plain_english'] += (f" Roark's clamped-plate coefficient gives {w_r:.4g}: difference "
                                       f"{r['difference_percent']:+.2f} %.")
        except Exception as e:
            r = {'error': f'{type(e).__name__}: {e}'[-1500:]}
        r['case'] = c
        r['seconds'] = round(time.time() - t0, 1)
        res.append(r)
        print(k, c, r.get('max_deflection'), r.get('difference_percent'), r.get('error', '')[:300], flush=True)
    json.dump(res, open(out, 'w'), indent=1)
    ok = [x for x in res if 'difference_percent' in x]
    print(f'{len(ok)}/{len(res)} solved; differences (%):', [x['difference_percent'] for x in ok])
    if not ok:
        sys.exit('no case solved - see the errors above')


ASK = ['Deflection of a {t:g} mm plate, stiffeners at {b:g} mm, frames at {a:g} mm, under {q:g} MPa ({edge})?',
       'Plate field {a:g} x {b:g} x {t:g} mm, lateral pressure {q:g} MPa, {edge} edges - solve it with MOOSE shells',
       '{q:g} MPa on a {t:g} mm panel between stiffeners {b:g} mm apart, span {a:g} mm. How much does it bend? ({edge})',
       'MOOSE se {a:g} x {b:g} mm plate ({t:g} mm) ka deflection nikalo, pressure {q:g} MPa, {edge}']


def do_samples(src, out, seed):
    sys.path.insert(0, HERE)
    from make_dataset import tool_block, result_msg
    r = random.Random(seed)
    rows = []
    for x in json.load(open(src)):
        if 'error' in x or 'ref' in x['case']:
            continue
        c = x['case']
        edge = 'clamped' if c['clamped'] else 'simply supported'
        args = {'a': c['a'], 'b': c['b'], 't': c['t'], 'q': c['q'], 'clamped': c['clamped']}
        res = {k: v for k, v in x.items() if k not in ('case', 'seconds', 'postprocessors')}
        q = r.choice(ASK).format(edge=edge, **c)
        ans = x['plain_english'] + (' (MOOSE shell element, linear elastic; check the stresses and the class rule thickness '
                                    'requirement as well - plate_check / class_rule.)')
        rows.append({'task': 'moose', 'messages': [{'role': 'user', 'content': q},
                                                   {'role': 'assistant', 'content': tool_block('moose_plate', args)},
                                                   result_msg('moose_plate', res), {'role': 'assistant', 'content': ans}]})
    with gzip.open(out, 'wt', encoding='utf-8') as fh:
        for row in rows:
            fh.write(json.dumps(row) + '\n')
    print(out, len(rows), 'samples')


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--run', action='store_true')
    ap.add_argument('--samples', action='store_true')
    ap.add_argument('--n', type=int, default=40)
    ap.add_argument('--seed', type=int, default=0)
    ap.add_argument('--results', default='results.json')
    ap.add_argument('--out', default='moose_train.jsonl.gz')
    a = ap.parse_args()
    if a.run:
        do_run(a.n, a.seed, a.results)
    if a.samples:
        do_samples(a.results, a.out, a.seed)
