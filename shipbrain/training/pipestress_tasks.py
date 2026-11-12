"""
Pipe stress training samples from real runs of the pipe_stress tool (psi, ASME B31.1): routes in plain words with size, temperature,
pressure and supports; pipe_route followed by pipe_stress on the same route; an expansion failure fixed by adding flexibility (a longer
offset leg) and run again; a sustained failure fixed by rests; missing inputs asked for; psi's limits said plainly.

    python training/pipestress_tasks.py --n 60 --out training/data/pipestress_train.jsonl.gz
"""
import argparse, gzip, json, os, random, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)
WORD = {'east': ['east', 'forward'], 'west': ['west', 'aft'], 'north': ['north', 'to port'], 'south': ['south', 'to starboard'], 'up': ['up'], 'down': ['down']}
OPP = {'east': 'west', 'west': 'east', 'north': 'south', 'south': 'north', 'up': 'down', 'down': 'up'}
SIZES = [(2, 60.3), (3, 88.9), (4, 114.3), (6, 168.3), (8, 219.1), (10, 273.0)]


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=60)
    ap.add_argument('--out', default=os.path.join(HERE, 'data', 'pipestress_train.jsonl.gz'))
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    from shipbrain import agent, knowledge
    from make_dataset import tool_block, result_msg
    r = random.Random(a.seed)
    work = tempfile.mkdtemp(prefix='sb_ps_')
    T = agent.Tools(work, knowledge.load(None))
    U = lambda t: {'role': 'user', 'content': t}
    A = lambda t: {'role': 'assistant', 'content': t}

    def slim(res):
        out = {k: v for k, v in res.items() if k not in ('nodes',)}
        out['cases'] = {c: {k: v for k, v in d.items() if k != 'displacement_mm'} for c, d in res['cases'].items()}
        return out

    def legs_words(legs):
        return ', then '.join(f"{l['length'] / 1000:g} m {r.choice(WORD[l['dir']])}" for l in legs)

    def make_legs(n):
        legs, prev = [], None
        for _ in range(n):
            d = r.choice([x for x in WORD if x != prev and (prev is None or x != OPP[prev])])
            legs.append({'dir': d, 'length': r.choice([2000, 3000, 4000, 5000, 6000])})
            prev = d
        return legs

    def run(args):
        res = T.call('pipe_stress', args)
        return None if 'error' in res else res

    def plain():
        nps, od = r.choice(SIZES)
        legs = make_legs(r.choice([2, 3, 3]))
        t, p, water = r.choice([60, 90, 120, 150, 180]), r.choice([0, 5, 10, 16]), r.choice([True, True, False])
        sp = r.choice([None, 3.0, 4.0])
        q = r.choice([f'Pipe stress check: NPS {nps} sch 40, {legs_words(legs)}, anchored at both ends, {t} deg C, {p} bar' + (', water filled' if water else ', gas (empty)') + (f', rests every {sp:g} m' if sp else ''),
                      f'{od} mm pipe {legs_words(legs)}. Operating {t} C, {p} bar{", full of water" if water else ""}. Anchors at the ends' + (f' and supports every {sp:g} m' if sp else '') + '. B31.1 ok?'])
        args = {'legs': legs, ('nps' if 'NPS' in q else 'od_mm'): (nps if 'NPS' in q else od), 'schedule': '40', 't_oper_c': float(t), 'pressure_bar': float(p), 'water': water}
        if sp:
            args['rest_spacing_m'] = sp
        res = run(args)
        return None if res is None else [U(q), A(tool_block('pipe_stress', args)), result_msg('pipe_stress', slim(res)), A(res['plain_english'])]

    def chain():
        nps, od = r.choice(SIZES[1:])
        legs = make_legs(3)
        t = r.choice([80, 120, 160])
        q = f'Route a {od} mm pipe {legs_words(legs)}, then check its stresses at {t} deg C with water, anchors at both ends'
        a1 = {'od': od, 'wall': 7.0, 'legs': legs, 'name': 'line'}
        r1 = T.call('pipe_route', a1)
        if 'error' in r1:
            return None
        a2 = {'waypoints': r1['waypoints'], 'od_mm': od, 'schedule': '40', 't_oper_c': float(t), 'water': True}
        r2 = run(a2)
        if r2 is None:
            return None
        return [U(q), A(tool_block('pipe_route', a1)), result_msg('pipe_route', r1),
                A('The 3D pipe is built. Now the stress check on the same route.\n' + tool_block('pipe_stress', a2)),
                result_msg('pipe_stress', slim(r2)), A(r1['plain_english'].split(' For the pressure')[0] + ' ' + r2['plain_english'])]

    def fix_expansion():
        nps, od = r.choice(SIZES[2:])
        L1 = r.choice([15000, 20000, 25000])
        short = r.choice([600, 800, 1000])
        t = r.choice([200, 250])
        legs = [{'dir': 'east', 'length': L1}, {'dir': 'north', 'length': short}]
        args = {'legs': legs, 'nps': nps, 'schedule': '40', 't_oper_c': float(t), 'water': False}
        res = run(args)
        if res is None or res['passes'] or res['cases']['exp']['code_stress']['passes']:
            return None
        for off in (3000, 4000, 5000, 6000, 8000):
            a2 = dict(args, legs=[legs[0], {'dir': 'north', 'length': off}])
            r2 = run(a2)
            if r2 and r2['cases']['exp']['code_stress']['passes']:
                break
        else:
            return None
        q = f'NPS {nps} steam line, {L1 / 1000:g} m east then {short} mm north, anchored at both ends, {t} deg C. Stress check'
        return [U(q), A(tool_block('pipe_stress', args)), result_msg('pipe_stress', slim(res)),
                A(res['plain_english'] + f' The {short} mm leg is too short to absorb the growth of the {L1 / 1000:g} m leg. I try a longer offset of {off / 1000:g} m (or an expansion loop of the same size).\n' + tool_block('pipe_stress', a2)),
                result_msg('pipe_stress', slim(r2)), A(r2['plain_english'])]

    def fix_sustained():
        nps, od = r.choice(SIZES[:3])
        L = r.choice([18000, 24000, 30000])
        args = {'legs': [{'dir': 'east', 'length': L}], 'nps': nps, 'schedule': '40', 't_oper_c': 40.0, 'water': True}
        res = run(args)
        if res is None or res['cases']['sus']['code_stress']['passes']:
            return None
        for sp in (6.0, 4.0, 3.0, 2.0):
            a2 = dict(args, rest_spacing_m=sp)
            r2 = run(a2)
            if r2 and r2['cases']['sus']['code_stress']['passes']:
                break
        else:
            return None
        q = f'Water line NPS {nps}, straight {L / 1000:g} m between two anchors, 40 deg C. Is it ok?'
        return [U(q), A(tool_block('pipe_stress', args)), result_msg('pipe_stress', slim(res)),
                A(res['plain_english'] + f' One span of {L / 1000:g} m is far too long for this pipe full of water. I add rests every {sp:g} m.\n' + tool_block('pipe_stress', a2)),
                result_msg('pipe_stress', slim(r2)), A(r2['plain_english'])]

    def ask():
        q = r.choice(['Do a pipe stress analysis', 'Check my piping for thermal expansion', 'Do I need an expansion loop?'])
        return [U(q), A('Sure. I need the route (for example 6 m east, then 3 m north, then 2 m up - or the pipe_route you made), the pipe size (NPS and schedule, '
                        'or the outside diameter), the operating temperature and the installation temperature, the pressure, whether it is full of water, and the supports '
                        '(anchors at the ends by default; rests every so many metres, guides). I check it to ASME B31.1 with psi.')]

    def limits():
        q = r.choice(['Are elbows modelled in the pipe stress check?', 'Can I use the pipe stress tool for stainless steel to B31.3?'])
        return [U(q), A('Not yet. The pipe stress tool runs psi, which today models corners as sharp joints (its bend element is not finished), so the extra '
                        'flexibility of a real elbow and its stress intensification factor are not included; it has one material (A53 grade A carbon steel) and the '
                        'B31.1 (1967) code only. Results are good for early sizing - straight runs, supports, anchor loads, whether a loop is needed - but a final design '
                        'needs a full pipe stress program with bends, your material and your code.')]

    gens = [(plain, 8), (chain, 4), (fix_expansion, 3), (fix_sustained, 2), (ask, 1), (limits, 1)]
    pool = [g for g, w in gens for _ in range(w)]
    rows, kinds, tries = [], {}, 0
    while len(rows) < a.n and tries < a.n * 8:
        tries += 1
        g = r.choice(pool)
        try:
            m = g()
        except Exception as e:
            print('skip', g.__name__, type(e).__name__, str(e)[:100])
            continue
        if not m:
            continue
        kinds[g.__name__] = kinds.get(g.__name__, 0) + 1
        rows.append({'task': 'pipestress_' + g.__name__, 'messages': m})
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
