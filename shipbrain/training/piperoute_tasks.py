"""
Pipe-route training samples from real runs (pipe_route, and pipe_route -> pipe_flow chains): plain-words routes with
directions and lengths (metres, mm, feet converted), long / short radius bends, hollow pipe with wall thickness, legs that
are too short for their bends (explained and fixed), and "what pump do I need for this route".

    python training/piperoute_tasks.py --n 90 --out training/data/piperoute_train.jsonl.gz
"""
import argparse, gzip, json, os, random, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

WORD = {'east': ['east', 'forward', 'to starboard-aft'], 'west': ['west'], 'north': ['north', 'to port'], 'south': ['south'], 'up': ['up', 'upwards'], 'down': ['down']}
# standard pipe: OD, wall (mm)
PIPES = [(60.3, 3.9), (88.9, 5.5), (114.3, 6.0), (139.7, 6.6), (168.3, 7.1), (219.1, 8.2), (273.0, 9.3)]
FLUID = {'seawater': 'seawater', 'ballast': 'seawater', 'fresh water': 'fresh water', 'fuel oil': 'mgo', 'lube oil': 'lube oil'}


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=90)
    ap.add_argument('--out', default=os.path.join(HERE, 'data', 'piperoute_train.jsonl.gz'))
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    from shipbrain import agent, knowledge
    from make_dataset import tool_block, result_msg
    r = random.Random(a.seed)
    work = tempfile.mkdtemp(prefix='sb_pr_')
    T = agent.Tools(work, knowledge.load(None))
    U = lambda t: {'role': 'user', 'content': t}
    A = lambda t: {'role': 'assistant', 'content': t}

    def legs_text(legs, unit):
        out = []
        for l in legs:
            L = l['length']
            v = f'{L / 1000:g} m' if unit == 'm' else (f'{L:g} mm' if unit == 'mm' else f'{L / 304.8:.1f} ft')
            out.append(f"{v} {r.choice(WORD[l['dir']])}")
        return ', then '.join(out)

    def make_legs():
        n = r.choice([2, 3, 3, 4])
        dirs, prev, legs = ['east', 'north', 'up'], None, []
        for _ in range(n):
            d = r.choice([x for x in ['east', 'west', 'north', 'south', 'up', 'down'] if prev is None or (x != prev and x not in {'east': 'west', 'west': 'east', 'north': 'south', 'south': 'north', 'up': 'down', 'down': 'up'}[prev])])
            legs.append({'dir': d, 'length': r.choice([1500, 2000, 2500, 3000, 4000, 5000])})
            prev = d
        return legs

    def simple():
        od, wall = r.choice(PIPES)
        legs = make_legs()
        unit = r.choice(['m', 'm', 'mm', 'ft'])
        if unit == 'ft':
            legs = [dict(l, length=round(l['length'] / 304.8) * 304.8) for l in legs]
        bend = r.choice(['LR', 'LR', 'SR'])
        q = r.choice([f'Route a {od:g} mm pipe ({wall:g} mm wall): {legs_text(legs, unit)}',
                      f'{od:g} OD x {wall:g} pipe goes {legs_text(legs, unit)}. Make the 3D pipe' + (' with short radius bends' if bend == 'SR' else ''),
                      f'Pipe run, OD {od:g}, wall {wall:g}: {legs_text(legs, unit)}'])
        args = {'od': od, 'wall': wall, 'legs': [{'dir': l['dir'], 'length': round(l['length'], 1)} for l in legs], 'name': 'pipe_run'}
        if bend == 'SR':
            args['bend'] = 'SR'
        res = T.call('pipe_route', args)
        if 'error' in res:
            return None
        pre = '' if unit == 'mm' else f'(Converting the lengths to mm.) '
        return [U(q), A(pre + tool_block('pipe_route', args)), result_msg('pipe_route', res), A(res['plain_english'])]

    def chain():
        od, wall = r.choice(PIPES)
        legs = make_legs()
        name, fl = r.choice(list(FLUID.items()))
        Q = r.choice([20, 40, 60, 100, 150, 250])
        q = r.choice([f'{name.capitalize()} line, {od:g} x {wall:g} pipe, {legs_text(legs, "m")}. {Q} m3/h - what pressure drop and pump power?',
                      f'Route {od:g} OD ({wall:g} wall) {name} pipe: {legs_text(legs, "m")}. Flow {Q} m3/h. Pump head needed?'])
        a1 = {'od': od, 'wall': wall, 'legs': legs, 'name': 'line'}
        r1 = T.call('pipe_route', a1)
        if 'error' in r1:
            return None
        a2 = {'flow_m3h': Q, 'segments': r1['pipe_flow_input']['segments'], 'fluid': fl}
        r2 = T.call('pipe_flow', a2)
        if 'error' in r2:
            return None
        seg = r1['pipe_flow_input']['segments'][0]
        return [U(q), A(tool_block('pipe_route', a1)), result_msg('pipe_route', r1),
                A(f"The route is {seg['length_m']:g} m long with {sum(seg['fittings'].values())} bends and a net rise of {seg['rise_m']:+g} m, bore {seg['d_mm']:g} mm. Now the hydraulics.\n" + tool_block('pipe_flow', a2)),
                result_msg('pipe_flow', r2), A(r1['plain_english'].split(' For the pressure')[0] + ' ' + r2['plain_english'])]

    def too_short():
        od, wall = r.choice(PIPES[2:])
        short = r.choice([150, 200, 250])
        legs = [{'dir': 'east', 'length': 3000}, {'dir': 'up', 'length': short}, {'dir': 'north', 'length': 3000}]
        q = f'{od:g} mm pipe: 3 m east, {short} mm up, then 3 m north'
        a1 = {'od': od, 'wall': wall, 'legs': legs, 'name': 'tight'}
        e1 = T.call('pipe_route', a1)
        if 'error' not in e1:
            return None
        a2 = dict(a1, bend='SR')
        r2 = T.call('pipe_route', a2)
        if 'error' in r2:
            a3 = dict(a1, legs=[legs[0], dict(legs[1], length=round(od * 3 / 50) * 50 + 50), legs[2]])
            r3 = T.call('pipe_route', a3)
            need = a3['legs'][1]['length']
            return [U(q), A(tool_block('pipe_route', a1)), result_msg('pipe_route', e1),
                    A(f'The {short} mm riser is too short for two long-radius bends in a {od:g} mm pipe (each needs about {1.5 * od:.0f} mm), and a short-radius bend does not fit either. '
                      f'I lengthen the riser to {need} mm - tell me if the height is fixed and I use other bends.\n' + tool_block('pipe_route', a3)),
                    result_msg('pipe_route', r3), A(r3['plain_english'])]
        return [U(q), A(tool_block('pipe_route', a1)), result_msg('pipe_route', e1),
                A(f'The {short} mm riser is too short for two long-radius bends in a {od:g} mm pipe (they need about {1.5 * od:.0f} mm each). With short-radius bends (1.0 x OD) it fits - I use those.\n' + tool_block('pipe_route', a2)),
                result_msg('pipe_route', r2), A(r2['plain_english'])]

    def ask():
        od, wall = r.choice(PIPES)
        legs = make_legs()
        q1 = r.choice(['I need a pipe route model', 'Make a 3D pipe from the pump to the tank', 'Pipe routing karna hai'])
        ask = 'Sure. I need the pipe outside diameter (and wall thickness if you want the mass), and the route as legs: direction (east / west / north / south / up / down) and length for each. Long radius bends are my default.'
        a2 = f'OD {od:g}, wall {wall:g}: {legs_text(legs, "m")}'
        args = {'od': od, 'wall': wall, 'legs': legs, 'name': 'route'}
        res = T.call('pipe_route', args)
        if 'error' in res:
            return None
        return [U(q1), A(ask), U(a2), A(tool_block('pipe_route', args)), result_msg('pipe_route', res), A(res['plain_english'])]

    gens = [(simple, 6), (chain, 5), (too_short, 3), (ask, 2)]
    pool = [g for g, w in gens for _ in range(w)]
    rows, kinds = [], {}
    while len(rows) < a.n:
        g = r.choice(pool)
        try:
            m = g()
        except Exception as e:
            print('skip', g.__name__, type(e).__name__, str(e)[:120])
            continue
        if not m:
            continue
        kinds[g.__name__] = kinds.get(g.__name__, 0) + 1
        rows.append({'task': 'pipe_route_' + g.__name__, 'messages': m})
    for x in rows:
        roles = [m['role'] for m in x['messages']]
        assert all(p != q for p, q in zip(roles, roles[1:])), roles
    s = json.dumps(rows)
    assert '/tmp/' not in s and '/home/' not in s
    with gzip.open(a.out, 'wt', encoding='utf-8') as fh:
        for x in rows:
            fh.write(json.dumps(x) + '\n')
    shutil.rmtree(work, ignore_errors=True)
    print(a.out, len(rows), kinds)


if __name__ == '__main__':
    main()
