"""
CableDyn training samples from real runs: random chain mooring lines (depth, length, anchor radius, chain size, grade,
studless / studlink, current, intact / damaged) solved by CableDyn through the mooring tool, and CableDyn's own example
decks (Apache-2.0, vendor/cabledyn/repo/examples) run through cable_run. Each question -> tool call -> result -> plain
answer is written. Needs the CableDyn driver (CABLEDYN_DRIVER); the result is committed.

    python training/cabledyn_tasks.py --n 120 --out training/data/cabledyn_train.jsonl.gz
"""
import argparse, gzip, json, math, os, random, shutil, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)

ASK = ['Check a {d} mm {g} {k} anchor chain, {L} m long, in {h} m water depth, anchor {R} m away',
       'Mooring line: water depth {h} m, chain {d} mm grade {g}, length {L} m, anchor radius {R} m. Fairlead tension?',
       'What is the fairlead tension and touchdown point of a {L} m {d} mm {g} chain at {h} m depth (anchor at {R} m)?',
       '{h} m paani me {d} mm {g} chain, {L} m lambi, anchor {R} m door - tension kitna hoga?',
       'Is a {d} mm {g} {k} chain OK for a {h} m deep mooring, {L} m line, anchor radius {R} m?']


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=120)
    ap.add_argument('--decks', type=int, default=40)
    ap.add_argument('--out', default=os.path.join(HERE, 'data', 'cabledyn_train.jsonl.gz'))
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args(argv)
    from shipbrain import agent, knowledge, cabledyn
    from make_dataset import tool_block, result_msg
    r = random.Random(a.seed)
    work = tempfile.mkdtemp(prefix='sb_cd_')
    T = agent.Tools(work, knowledge.load(None))
    rows = []

    def add(q, name, args, out, ans):
        rows.append({'task': 'cabledyn', 'messages': [{'role': 'user', 'content': q},
                                                      {'role': 'assistant', 'content': tool_block(name, args)},
                                                      result_msg(name, out), {'role': 'assistant', 'content': ans}]})
    try:
        for i in range(a.n):
            h = r.choice([30, 50, 80, 100, 150, 200, 300, 500, 800])
            d = r.choice([52, 64, 76, 84, 95, 102, 114, 127, 142, 157])
            g = r.choice(['R3', 'R3', 'R3S', 'R4', 'R4', 'R5'])
            k = r.choice(['studless', 'studless', 'studlink'])
            L = round(h * r.uniform(3.5, 9.0), -1)
            slack = r.uniform(0.80, 0.99)
            R = round(math.sqrt(max(1.0, (L * slack) ** 2 - h ** 2)) + r.uniform(-0.15, 0.08) * h, -1)
            args = {'depth': h, 'length': L, 'radius': R, 'd_mm': d, 'grade': g, 'kind': k}
            q = r.choice(ASK).format(d=d, g=g, k=k, L=int(L), h=h, R=int(R))
            if r.random() < 0.25:
                args['current'] = r.choice([0.5, 1.0, 1.5])
                q += f", current {args['current']} m/s"
            if r.random() < 0.2:
                args['condition'] = 'damaged'
                q += ' (one line broken - damaged condition)'
            out = T.call('mooring', args)
            if 'error' in out:
                ans = 'That line cannot hang as given: ' + out['error'].split(': ', 1)[-1]
                add(q, 'mooring', args, out, ans)
                continue
            add(q, 'mooring', args, out, out['plain_english'])
        ex = os.path.join(cabledyn.ROOT, 'examples')
        decks = sorted(f for f in os.listdir(ex) if f.endswith('.dat') and 'options_reference' not in f)
        r.shuffle(decks)
        n = 0
        for f in decks:
            if n >= a.decks:
                break
            shutil.copy(os.path.join(ex, f), os.path.join(work, f))
            t0 = time.time()
            out = T.call('cable_run', {'deck': f})
            if 'error' in out or time.time() - t0 > 120:
                continue
            q = r.choice([f'Run the CableDyn deck {f}', f'Solve {f} and give me the line tensions', f'What tensions does {f} give?'])
            add(q, 'cable_run', {'deck': f}, {k: v for k, v in out.items() if k != 'log'}, out['plain_english'])
            n += 1
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
