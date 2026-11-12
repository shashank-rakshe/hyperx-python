"""
Piping pulsation / vibration training samples from real runs of the pipe_pulsation tool (OpenPulse): pump discharge and suction lines in plain
words, the excitation frequency worked out from the pump (reciprocating: rpm / 60 x plungers and multiples; centrifugal: rpm / 60 and vane passing),
a resonance found and removed by changing a length (acoustic) or adding a support (structural), missing inputs asked for, and what it does not do.

    python training/pulsation_tasks.py --n 40 --out training/data/pulsation_train.jsonl.gz
"""
import argparse, gzip, json, os, random, shutil, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)
WORD = {'east': ['east', 'forward'], 'west': ['west', 'aft'], 'north': ['north', 'to port'], 'south': ['south', 'to starboard'], 'up': ['up'], 'down': ['down']}
OPP = {'east': 'west', 'west': 'east', 'north': 'south', 'south': 'north', 'up': 'down', 'down': 'up'}
PIPES = [(60.3, 3.9), (88.9, 5.5), (114.3, 6.0), (168.3, 7.1)]


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=40)
    ap.add_argument('--out', default=os.path.join(HERE, 'data', 'pulsation_train.jsonl.gz'))
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    from shipbrain import agent, knowledge
    from make_dataset import tool_block, result_msg
    r = random.Random(a.seed)
    work = tempfile.mkdtemp(prefix='sb_pu_')
    T = agent.Tools(work, knowledge.load(None))
    U = lambda t: {'role': 'user', 'content': t}
    A = lambda t: {'role': 'assistant', 'content': t}

    def words(legs):
        return ', then '.join(f"{l['length'] / 1000:g} m {r.choice(WORD[l['dir']])}" for l in legs)

    def make_legs(n):
        legs, prev = [], None
        for _ in range(n):
            d = r.choice([x for x in WORD if x != prev and (prev is None or x != OPP[prev])])
            legs.append({'dir': d, 'length': r.choice([1500, 2000, 3000, 4000, 5000])})
            prev = d
        return legs

    def sup(legs):
        n = len(legs)
        return [{'at': 0, 'type': 'anchor'}] + [{'at': i, 'type': 'pinned'} for i in range(1, n)] + [{'at': -1, 'type': 'anchor'}]

    def run(args):
        args.setdefault('supports', sup(args['legs']))
        res = T.call('pipe_pulsation', args)
        return None if 'error' in res else res

    def recip():
        od, t = r.choice(PIPES[:3])
        rpm, npl = r.choice([200, 250, 300, 350, 400]), r.choice([1, 2, 3, 5])
        f1 = rpm / 60 * npl
        exc = [round(f1 * k, 2) for k in (1, 2, 3)]
        legs = make_legs(r.choice([2, 3]))
        fluid = r.choice(['water', 'seawater'])
        q = (f"{'Triplex' if npl == 3 else str(npl) + '-plunger'} reciprocating pump at {rpm} rpm, discharge line {od} x {t} mm, {words(legs)} "
             f"into a {r.choice(['tank', 'header', 'vessel'])}, {fluid}, supported at every bend. Any pulsation or vibration resonance?")
        args = {'legs': legs, 'od_mm': od, 'wall_mm': t, 'fluid': fluid, 'open_ends': [-1], 'excitation_hz': exc, 'modes': 8}
        res = run(args)
        if res is None:
            return None
        pre = f'Excitation: {rpm} rpm / 60 x {npl} plunger(s) = {f1:g} Hz, and its multiples {exc[1]:g} and {exc[2]:g} Hz.\n'
        return [U(q), A(pre + tool_block('pipe_pulsation', args)), result_msg('pipe_pulsation', res), A(res['plain_english'])]

    def centrifugal():
        od, t = r.choice(PIPES[1:])
        rpm, vanes = r.choice([1450, 1750, 2900, 3550]), r.choice([5, 6, 7])
        exc = [round(rpm / 60, 2), round(rpm / 60 * vanes, 2)]
        legs = make_legs(2)
        q = f"Centrifugal pump {rpm} rpm with {vanes} vanes, line {od} x {t} mm {words(legs)}, sea water, open to the sea at the end, supported at the bends. Check natural frequencies"
        args = {'legs': legs, 'od_mm': od, 'wall_mm': t, 'fluid': 'seawater', 'open_ends': [-1], 'excitation_hz': exc, 'modes': 8}
        res = run(args)
        if res is None:
            return None
        pre = f'Excitation: running speed {rpm} / 60 = {exc[0]:g} Hz and vane passing {exc[0]:g} x {vanes} = {exc[1]:g} Hz.\n'
        return [U(q), A(pre + tool_block('pipe_pulsation', args)), result_msg('pipe_pulsation', res), A(res['plain_english'])]

    def fix_acoustic():
        od, t = r.choice(PIPES[:3])
        for _ in range(12):
            legs = make_legs(2)
            res = run({'legs': legs, 'od_mm': od, 'wall_mm': t, 'fluid': 'water', 'open_ends': [-1], 'modes': 6})
            if not res or not res.get('acoustic_natural_frequencies_hz'):
                continue
            f = res['acoustic_natural_frequencies_hz'][0]
            exc = [round(f * r.choice([0.95, 1.03, 1.06]), 2)]
            args = {'legs': legs, 'od_mm': od, 'wall_mm': t, 'fluid': 'water', 'open_ends': [-1], 'excitation_hz': exc, 'modes': 6}
            r1 = run(args)
            if not r1 or not any(n['mode'] == 'acoustic' for n in r1['resonances']):
                continue
            for fac in (1.3, 1.4, 1.5, 0.7):
                legs2 = [dict(legs[0], length=int(legs[0]['length'] * fac)), legs[1]]
                a2 = dict(args, legs=legs2, supports=sup(legs2))
                r2 = run(a2)
                if r2 and not r2['resonances']:
                    q = f"Pump excitation {exc[0]:g} Hz, water line {od} x {t} mm, {words(legs)} into a tank, supported at the bend. Pulsation ok?"
                    return [U(q), A(tool_block('pipe_pulsation', args)), result_msg('pipe_pulsation', r1),
                            A(r1['plain_english'] + f" I change the first leg from {legs[0]['length'] / 1000:g} m to {legs2[0]['length'] / 1000:g} m to move the "
                              "acoustic mode away (a pulsation damper or an orifice plate are the other ways) and check again.\n" + tool_block('pipe_pulsation', a2)),
                            result_msg('pipe_pulsation', r2), A(r2['plain_english'])]
        return None

    def ask():
        q = r.choice(['Check my pump line for pulsation', 'Will the discharge pipe vibrate?', 'Pulsation study of the cooling line please'])
        return [U(q), A('Sure. I need the route of the line (for example 4 m east then 2 m up, or the pipe_route you made), the pipe outside diameter and wall, '
                        'the fluid, where the line opens into a tank or header, the supports, and the pump: type (reciprocating or centrifugal), speed in rpm and '
                        'number of plungers or vanes - from that I work out the excitation frequencies and check the acoustic and structural natural frequencies against them.')]

    def limits():
        q = r.choice(['Can it calculate water hammer when the valve closes?', 'Does the pulsation check include the pressure surge?'])
        return [U(q), A('No. The pulsation tool (OpenPulse) works in the frequency domain: natural frequencies of the fluid column and of the pipe, and resonance '
                        'with periodic pump excitation. A water hammer is a transient pressure surge after a fast valve closure or pump trip - it needs a transient '
                        '(method of characteristics) calculation, which ShipBrain does not have yet. The Joukowsky estimate dp = rho c dv gives a first idea of the surge.')]

    gens = [(recip, 5), (centrifugal, 3), (fix_acoustic, 2), (ask, 1), (limits, 1)]
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
        rows.append({'task': 'pulsation_' + g.__name__, 'messages': m})
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
