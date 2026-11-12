"""
Pipe hydraulics training samples from real runs: random ship piping lines (seawater cooling, ballast, bilge, fire main,
fuel transfer, lube oil, fresh water) solved by ProcessPi through the pipe_flow tool. Each question -> tool call -> result
-> plain answer is written. The result is committed.

    python training/pipeflow_tasks.py --n 60 --out training/data/pipeflow_train.jsonl.gz
"""
import argparse, gzip, json, os, random, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

SYSTEMS = [('seawater cooling line', 'seawater', (60, 400), (100, 250)), ('ballast line', 'seawater', (100, 600), (150, 300)),
           ('bilge line', 'seawater', (30, 150), (80, 150)), ('fire main', 'seawater', (50, 250), (100, 200)),
           ('fuel transfer line', 'mgo', (5, 60), (40, 100)), ('HFO transfer line', 'hfo', (5, 40), (50, 125)),
           ('lube oil line', 'lube oil', (5, 40), (40, 100)), ('fresh water line', 'fresh water', (5, 40), (32, 80))]
ASK = ['Pressure drop and pump power for a {Q:g} m3/h {sys}: {desc}', 'Check the {sys}, {Q:g} m3/h. {desc}. What head does the pump need?',
       '{sys}: {Q:g} m3/h, {desc}. Velocity and pressure loss?', '{Q:g} m3/h {sys} - {desc}. Pump kitna power lega?']


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=60)
    ap.add_argument('--out', default=os.path.join(HERE, 'data', 'pipeflow_train.jsonl.gz'))
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    from shipbrain import agent, knowledge
    from make_dataset import tool_block, result_msg
    import tempfile
    r = random.Random(a.seed)
    T = agent.Tools(tempfile.mkdtemp(prefix='sb_pf_'), knowledge.load(None))
    rows = []
    for i in range(a.n):
        name, fluid, (q0, q1), (d0, d1) = r.choice(SYSTEMS)
        Q = round(r.uniform(q0, q1), -1 if q1 > 100 else 0)
        segs, desc = [], []
        for k in range(r.choice([1, 2, 2, 3])):
            vt = r.uniform(0.6, 2.0) if fluid not in ('seawater', 'fresh water') else r.uniform(1.0, 3.0)
            if r.random() < 0.15:
                vt *= 1.8                                           # some undersized lines, so the warning is learned too
            need = (4 * Q / 3600 / 3.14159 / vt) ** 0.5 * 1000          # bore for the target velocity
            d = min((32, 40, 50, 65, 80, 100, 125, 150, 200, 250, 300, 350, 400), key=lambda x: abs(x - need))
            L = r.choice([5, 10, 15, 20, 30, 40, 60])
            rise = r.choice([0, 0, 2, 4, 6, 10, -3])
            fit = {f: r.randint(1, n) for f, n in [('standard_elbow_90_deg', 6), ('gate_valve', 2), ('swing_check_valve', 1),
                                                     ('globe_valve', 1), ('standard_tee_through_flow', 2)] if r.random() < 0.5}
            segs.append({'d_mm': d, 'length_m': L, 'rise_m': rise, 'fittings': fit})
            desc.append(f"{L} m of {d} mm bore" + (f" rising {rise} m" if rise > 0 else (f" falling {-rise} m" if rise < 0 else '')) +
                        (' with ' + ', '.join(f"{n} {f.replace('_', ' ')}" for f, n in fit.items()) if fit else ''))
        args = {'flow_m3h': Q, 'segments': segs, 'fluid': fluid}
        q = r.choice(ASK).format(Q=Q, sys=name, desc='; then '.join(desc))
        out = T.call('pipe_flow', args)
        if 'error' in out:
            continue
        note = ''
        rows.append({'task': 'pipe_flow', 'messages': [{'role': 'user', 'content': q},
                                                       {'role': 'assistant', 'content': tool_block('pipe_flow', args)},
                                                       result_msg('pipe_flow', out), {'role': 'assistant', 'content': out['plain_english'] + note}]})
    with gzip.open(a.out, 'wt', encoding='utf-8') as fh:
        for x in rows:
            fh.write(json.dumps(x) + '\n')
    print(a.out, len(rows), 'samples')


if __name__ == '__main__':
    main()
